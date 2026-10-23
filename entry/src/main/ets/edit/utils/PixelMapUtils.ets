import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { LengthMetricsUnit } from '@kit.ArkUI';
import { RawPreviewLoader } from './RawPreviewLoader';
import { ExifOrientation } from './ExifOrientation';
import { CameraProfiles, CameraProfile } from './CameraProfiles';
import { RawNativeBridge, NativeRawDecodeResult, RawDecodeFailure, RawDecodeStatus, rawDecodeStatusLabel } from './RawNativeBridge';
import { RawDecodeDescriptor, RawSourceKind, rawDescriptorJson } from './RawSourceContract';
import { RawPreviewSettings } from '../models/RawDevelopmentSettings';
export { RawPreviewSettings } from '../models/RawDevelopmentSettings';

interface ResidentRawPreview { uri: string; key: string; model: string; orientation: number; }

export class PixelMapUtils {
  private static residentRaw: ResidentRawPreview | null = null;

  static rawPreviewSettings(): RawPreviewSettings {
    return { profile: AppStorage.get<string>('selectedCameraProfile') ?? '',
      kelvin: AppStorage.get<number>('rawWhiteBalanceKelvin') ?? 0,
      tint: AppStorage.get<number>('rawWhiteBalanceTint') ?? 0 };
  }

  private static resolveRawProfile(model: string, selected: string): CameraProfile | null {
    let profile = CameraProfiles.find(model, selected);
    if (!profile && selected === CameraProfiles.FLOG2_PROFILE_NAME) {
      profile = CameraProfiles.fixedProfile(CameraProfiles.FLOG2_PROFILE_PATH);
    }
    const candidates = CameraProfiles.matching(model);
    if (!profile && !selected && candidates.length === 1) profile = candidates[0];
    return profile;
  }

  /** A profile switch reuses linear RGB and orientation, without RAW file IO. */
  static async reprocessRawPreview(uri: string, settings: RawPreviewSettings): Promise<image.PixelMap | null> {
    const cached = PixelMapUtils.residentRaw;
    if (!cached || cached.uri !== uri || !RawNativeBridge.hasCachedPreview(cached.key)) return null;
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = fileIo.statSync(file.fd);
      if (cached.key !== uri + ':' + stat.size + ':' + stat.mtime) return null;
    } finally { fileIo.closeSync(file); }
    const profile = PixelMapUtils.resolveRawProfile(cached.model, settings.profile);
    if (profile) await CameraProfiles.loadProfileAsync(profile);
    const decoded = await RawNativeBridge.reprocessPreview(cached.key, profile?.cpuData() ?? null,
      settings.kelvin, settings.tint);
    if (!decoded) return null;
    if (decoded.status !== RawDecodeStatus.Ok) throw new Error((decoded as RawDecodeFailure).message);
    const result = await PixelMapUtils.createNativePixelMap(decoded as NativeRawDecodeResult);
    if (result) await RawPreviewLoader.applyOrientation(result, cached.orientation);
    return result;
  }
  /** File encoding has no packToData default 25 MB output-buffer ceiling. */
  static async encodeJpegToFile(pixelMap: image.PixelMap, path: string, quality: number): Promise<void> {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    const packer = image.createImagePacker();
    try {
      const options: image.PackingOption = { format: 'image/jpeg', quality: Math.max(0, Math.min(100, quality)) };
      await packer.packToFile(pixelMap, file.fd, options);
      if (fileIo.statSync(file.fd).size <= 0) throw new Error('JPEG encoder produced an empty file');
    } finally {
      packer.release();
      fileIo.closeSync(file);
    }
  }

  static async encodePngToFile(pixelMap: image.PixelMap, path: string): Promise<void> {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    const packer = image.createImagePacker();
    try {
      const options: image.PackingOption = { format: 'image/png', quality: 100 };
      await packer.packToFile(pixelMap, file.fd, options);
      if (fileIo.statSync(file.fd).size <= 0) throw new Error('PNG encoder produced an empty file');
    } finally {
      packer.release();
      fileIo.closeSync(file);
    }
  }

  /** 按导出格式分发到对应编码器：JPG/PNG 走系统 Packer，TIFF 走自研写入器。 */
  static async encodeImageToFile(pixelMap: image.PixelMap, path: string, format: string, quality: number): Promise<void> {
    if (format === 'PNG') {
      await PixelMapUtils.encodePngToFile(pixelMap, path);
      return;
    }
    if (format === 'TIFF') {
      await PixelMapUtils.encodeTiffToFile(pixelMap, path);
      return;
    }
    await PixelMapUtils.encodeJpegToFile(pixelMap, path, quality);
  }

  /**
   * Baseline TIFF（小端序、无压缩 RGB、按条带存储）。系统 ImagePacker 不支持
   * TIFF，因此直接按字节写出：头部 + IFD(13 个标签) + 附加数值 + 像素条带。
   * 逐条带从 PixelMap 读取 RGBA 并转 RGB，避免整图复制造成的内存峰值。
   */
  static async encodeTiffToFile(pixelMap: image.PixelMap, path: string): Promise<void> {
    const info = await pixelMap.getImageInfo();
    const width = info.size.width;
    const height = info.size.height;
    if (width <= 0 || height <= 0) throw new Error('TIFF encoder: empty image');
    let source = pixelMap;
    if (info.pixelFormat !== image.PixelMapFormat.RGBA_8888) {
      // 画布栅格化是把异构像素格式归一为 RGBA_8888 的通用途径。
      const canvas = new OffscreenCanvas(width, height, LengthMetricsUnit.PX);
      const ctx = canvas.getContext('2d', new RenderingContextSettings(true));
      ctx.drawImage(pixelMap, 0, 0, width, height);
      source = await ctx.getPixelMap(0, 0, width, height);
    }
    const bytesPerRow = width * 3;
    const rowsPerStrip = Math.max(1, Math.min(height, Math.floor(8 * 1024 * 1024 / Math.max(1, bytesPerRow))));
    const stripCount = Math.ceil(height / rowsPerStrip);
    const entryCount = 13;
    const ifdOffset = 8;
    const ifdSize = 2 + entryCount * 12 + 4;
    let cursor = ifdOffset + ifdSize;
    const bitsPerSampleOffset = cursor;
    cursor += 6;
    const stripOffsetsFieldOffset = cursor;
    cursor += stripCount * 4;
    const stripByteCountsFieldOffset = cursor;
    cursor += stripCount * 4;
    const resolutionOffset = cursor;
    cursor += 16;
    const stripOffsets: number[] = [];
    let dataCursor = cursor;
    for (let i = 0; i < stripCount; i++) {
      const rows = Math.min(rowsPerStrip, height - i * rowsPerStrip);
      stripOffsets.push(dataCursor);
      dataCursor += rows * bytesPerRow;
    }
    const head = new ArrayBuffer(cursor);
    const dv = new DataView(head);
    const bytes = new Uint8Array(head);
    bytes[0] = 0x49;
    bytes[1] = 0x49;
    dv.setUint16(2, 42, true);
    dv.setUint32(4, ifdOffset, true);
    let p = ifdOffset;
    dv.setUint16(p, entryCount, true);
    p += 2;
    const TYPE_SHORT = 3;
    const TYPE_LONG = 4;
    const TYPE_RATIONAL = 5;
    const writeEntry = (tag: number, type: number, count: number, value: number): void => {
      dv.setUint16(p, tag, true);
      dv.setUint16(p + 2, type, true);
      dv.setUint32(p + 4, count, true);
      if (type === TYPE_SHORT && count === 1) {
        dv.setUint16(p + 8, value, true);
        dv.setUint16(p + 10, 0, true);
      } else {
        dv.setUint32(p + 8, value, true);
      }
      p += 12;
    };
    writeEntry(256, TYPE_LONG, 1, width);
    writeEntry(257, TYPE_LONG, 1, height);
    writeEntry(258, TYPE_SHORT, 3, bitsPerSampleOffset);
    writeEntry(259, TYPE_SHORT, 1, 1);
    writeEntry(262, TYPE_SHORT, 1, 2);
    writeEntry(273, TYPE_LONG, stripCount, stripCount === 1 ? stripOffsets[0] : stripOffsetsFieldOffset);
    writeEntry(277, TYPE_SHORT, 1, 3);
    writeEntry(278, TYPE_LONG, 1, rowsPerStrip);
    writeEntry(279, TYPE_LONG, stripCount,
      stripCount === 1 ? Math.min(rowsPerStrip, height) * bytesPerRow : stripByteCountsFieldOffset);
    writeEntry(282, TYPE_RATIONAL, 1, resolutionOffset);
    writeEntry(283, TYPE_RATIONAL, 1, resolutionOffset + 8);
    writeEntry(284, TYPE_SHORT, 1, 1);
    writeEntry(296, TYPE_SHORT, 1, 2);
    dv.setUint32(p, 0, true);
    dv.setUint16(bitsPerSampleOffset, 8, true);
    dv.setUint16(bitsPerSampleOffset + 2, 8, true);
    dv.setUint16(bitsPerSampleOffset + 4, 8, true);
    if (stripCount > 1) {
      for (let i = 0; i < stripCount; i++) {
        dv.setUint32(stripOffsetsFieldOffset + i * 4, stripOffsets[i], true);
        const rows = Math.min(rowsPerStrip, height - i * rowsPerStrip);
        dv.setUint32(stripByteCountsFieldOffset + i * 4, rows * bytesPerRow, true);
      }
    }
    dv.setUint32(resolutionOffset, 72, true);
    dv.setUint32(resolutionOffset + 4, 1, true);
    dv.setUint32(resolutionOffset + 8, 72, true);
    dv.setUint32(resolutionOffset + 12, 1, true);
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, head);
      const rgbaBuffer = new ArrayBuffer(rowsPerStrip * width * 4);
      const rgba = new Uint8Array(rgbaBuffer);
      const rgb = new Uint8Array(rowsPerStrip * bytesPerRow);
      for (let strip = 0; strip < stripCount; strip++) {
        const rows = Math.min(rowsPerStrip, height - strip * rowsPerStrip);
        const area: image.PositionArea = {
          pixels: rgbaBuffer,
          offset: 0,
          stride: width * 4,
          region: { size: { width: width, height: rows }, x: 0, y: strip * rowsPerStrip },
        };
        await source.readPixels(area);
        const pixelCount = rows * width;
        for (let i = 0; i < pixelCount; i++) {
          const s = i * 4;
          const d = i * 3;
          rgb[d] = rgba[s];
          rgb[d + 1] = rgba[s + 1];
          rgb[d + 2] = rgba[s + 2];
        }
        fileIo.writeSync(file.fd, rgb.buffer as ArrayBuffer, { offset: 0, length: rows * bytesPerRow });
      }
      if (fileIo.statSync(file.fd).size <= 0) throw new Error('TIFF encoder produced an empty file');
    } finally {
      if (source !== pixelMap) source.release();
      fileIo.closeSync(file);
    }
  }

  /**
   * Load an image from a file URI into a PixelMap.
   * maxDimension 0 = decode at full resolution; otherwise the decoder scales
   * down to fit the box during decode (preview path).
   */
  static async loadFromUri(uri: string, maxDimension: number = 1920,
    onReadProgress?: (progress: number) => void,
    isCancelled?: () => boolean,
    onSourceInfo?: (width: number, height: number) => void,
    sourceNameHint: string = '',
    onDecodeInfo?: (info: RawDecodeDescriptor) => void,
    thumbnailOnly: boolean = false,
    rawSettings?: RawPreviewSettings): Promise<image.PixelMap | null> {
    // Media-library URIs do not retain the original filename suffix. Use the
    // caller's display-name hint so NEF/RW2/ARW assets still receive RAW
    // orientation handling and the embedded-JPEG fallback.
    const rawSource = RawPreviewLoader.isRawFile(sourceNameHint.length > 0 ? sourceNameHint : uri);
    let sourceBuffer: ArrayBuffer | null = null;
    let rawWidth = 0;
    let rawHeight = 0;
    // Non-RAW formats use the built-in decoder. RAW files never do: the
    // platform RAW pipeline is undocumented and degrades quality, so they go
    // through LibRaw, with the camera's embedded JPEG as the only fallback.
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const fileStat = fileIo.statSync(file.fd);
        const fileSize = fileStat.size;
        const buffer = new ArrayBuffer(fileSize);
        sourceBuffer = buffer;
        const target = new Uint8Array(buffer);
        const chunkSize = 1024 * 1024;
        let offset = 0;
        // Bounded async reads keep RAW IO off the UI event loop.
        while (offset < fileSize) {
          if (isCancelled && isCancelled()) return null;
          const requested = Math.min(chunkSize, fileSize - offset);
          const chunk = new ArrayBuffer(requested);
          const read = await fileIo.read(file.fd, chunk, { length: requested });
          const actual = Math.max(0, Math.min(requested, read as number));
          if (actual <= 0) break;
          target.set(new Uint8Array(chunk, 0, actual), offset);
          offset += actual;
          if (onReadProgress) onReadProgress(fileSize > 0 ? offset / fileSize : 1);
          await new Promise<void>((resolve) => setTimeout(resolve, 0));
        }
        if (offset !== fileSize) throw new Error('Unable to read complete image source');
        if (onReadProgress) onReadProgress(1);
        if (isCancelled && isCancelled()) return null;

        if (rawSource) {
          if (thumbnailOnly) {
            const embedded = await RawPreviewLoader.loadPreviewFromBytes(buffer, maxDimension);
            if (embedded) {
              if (maxDimension > 0) {
                const previewSize = (await embedded.getImageInfo()).size;
                const factor = Math.min(1, maxDimension / Math.max(previewSize.width, previewSize.height));
                if (factor < 1) await embedded.scale(factor, factor);
              }
              return embedded;
            }
          }
          const model = CameraProfiles.cameraModel(buffer);
          AppStorage.setOrCreate('rawCameraModel', model);
          const missing = model.length > 0 && CameraProfiles.matching(model).length === 0;
          AppStorage.setOrCreate('rawCameraProfileMissing', missing);
          // A selected matching profile opts into the controlled LibRaw CPU
          // path.  The native module never replaces the platform decoder or
          // the embedded preview fallback when it cannot decode the source.
          const settings = rawSettings ?? PixelMapUtils.rawPreviewSettings();
          const selected = settings.profile;
          // No explicit choice plus exactly one bundled profile for the model:
          // use it automatically without writing back to AppStorage, so the
          // user's picker state stays untouched.  Any other miss (multi-profile,
          // unknown camera, or a selection that does not match this model)
          // falls back to the open-source classic color so real RAW data is
          // always graded by LibRaw instead of the platform decoder.
          const candidates = CameraProfiles.matching(model);
          let profile: CameraProfile | null = CameraProfiles.find(model, selected);
          // Pixel F-log2 is a fixed cross-camera profile: resolve it by its
          // bundle path instead of the camera-model match.
          if (profile === null && selected === CameraProfiles.FLOG2_PROFILE_NAME) {
            profile = CameraProfiles.fixedProfile(CameraProfiles.FLOG2_PROFILE_PATH);
          }
          let classic = false;
          if (profile === null) {
            if (selected.length === 0 && candidates.length === 1) {
              profile = candidates[0];
            } else {
              classic = true;
            }
          }
          let nativeFailure: RawDecodeFailure | null = null;
          if (profile !== null || classic) {
            if (profile) await CameraProfiles.loadProfileAsync(profile);
            const native = await RawNativeBridge.decodeRw2(buffer, maxDimension,
              profile !== null ? profile.cpuData() : null,
              settings.kelvin, settings.tint,
              uri + ':' + fileSize + ':' + fileStat.mtime);
            // The bridge answers with a success payload, a structured failure,
            // or null when the request was cancelled (editor teardown).
            const nativeAsResult = native as NativeRawDecodeResult | null;
            const nativeOk = nativeAsResult !== null &&
              nativeAsResult.status === RawDecodeStatus.Ok && nativeAsResult.pixels !== undefined;
            nativeFailure = native !== null && !nativeOk ? native as RawDecodeFailure : null;
            const nativePixelMap = nativeOk && nativeAsResult !== null ?
              await PixelMapUtils.createNativePixelMap(nativeAsResult) : null;
            if (nativeOk && nativeAsResult !== null && nativePixelMap) {
              const orientation = RawPreviewLoader.readOrientation(buffer);
              await RawPreviewLoader.applyOrientation(nativePixelMap, orientation);
              if (maxDimension > 0) PixelMapUtils.residentRaw = {
                uri: uri, key: uri + ':' + fileSize + ':' + fileStat.mtime, model: model, orientation: orientation };
              onSourceInfo?.(nativeAsResult.sourceWidth, nativeAsResult.sourceHeight);
              const info: RawDecodeDescriptor = {
                sourceKind: RawSourceKind.NATIVE_RENDERED_RGB,
                sourceUri: uri, sourceName: sourceNameHint,
                actualWidth: nativeAsResult.sourceWidth, actualHeight: nativeAsResult.sourceHeight,
                actualDimensionsKnown: nativeAsResult.sourceWidth > 0 && nativeAsResult.sourceHeight > 0,
                dimensionNote: 'LibRaw reported the sensor/output dimensions',
                outputWidth: nativeAsResult.width, outputHeight: nativeAsResult.height,
                bitDepth: nativeAsResult.bitDepth > 0 ? nativeAsResult.bitDepth : null,
                colorSpace: profile !== null ? 'sRGB (DCP CPU: interpolated camera matrix, ProPhoto HSV tables and tone curve)' : 'sRGB (Pixel 经典 CPU: open-source dcraw camera matrix)',
                transferFunction: 'display preview transfer after CPU matrix; not an unmodified linear buffer',
                processing: profile !== null ? `LibRaw float camera RGB → DCP CPU (${profile.name}); optional fields enabled automatically` : 'LibRaw float camera RGB → Pixel 经典 CPU (open-source dcraw rgb_cam); no bundled DCP for this camera',
                dcpApplied: nativeAsResult.dcpApplied === 1,
              };
              onDecodeInfo?.(info);
              console.info('VIVID_RAW_SOURCE ' + rawDescriptorJson(info));
              return nativePixelMap;
            }
            if (nativeFailure !== null) {
              console.error(`VIVID_RAW_FAIL uri=${uri} status=${nativeFailure.status} (${rawDecodeStatusLabel(nativeFailure.status)})`);
            }
            console.warn('VIVID LibRaw decode unavailable; using the embedded JPEG preview');
          }
          // RAW bytes never reach the platform decoder: its demosaic, white
          // balance and color transform are undocumented and visibly degrade
          // quality.  When LibRaw cannot decode the source, every RAW dialect
          // falls back to the camera's own full-size embedded JPEG instead.
          const embedded = await RawPreviewLoader.loadPreviewFromBytes(buffer, maxDimension);
          if (embedded) {
            const embeddedSize = (await embedded.getImageInfo()).size;
            // The fallback stays available for every classified failure, but
            // the descriptor records exactly why real RAW data was not used.
            const fallbackReason = nativeFailure !== null
              ? `LibRaw failed: ${rawDecodeStatusLabel(nativeFailure.status)} (${nativeFailure.message})`
              : 'LibRaw or the selected DCP profile was unavailable';
            const embeddedInfo: RawDecodeDescriptor = {
              sourceKind: RawSourceKind.EMBEDDED_JPEG_PREVIEW,
              sourceUri: uri, sourceName: sourceNameHint,
              actualWidth: embeddedSize.width, actualHeight: embeddedSize.height,
              actualDimensionsKnown: true,
              dimensionNote: 'full-size JPEG embedded in the RAW container',
              outputWidth: embeddedSize.width, outputHeight: embeddedSize.height,
              bitDepth: null,
              colorSpace: 'sRGB (camera-processed embedded JPEG)',
              transferFunction: 'in-camera processing',
              processing: `embedded full-size JPEG (no demosaic); ${fallbackReason}`,
              dcpApplied: false,
            };
            if (onSourceInfo) onSourceInfo(embeddedSize.width, embeddedSize.height);
            onDecodeInfo?.(embeddedInfo);
            console.info('VIVID_RAW_SOURCE ' + rawDescriptorJson(embeddedInfo));
            return embedded;
          }
          // No LibRaw result and no embedded JPEG: fail this load rather than
          // letting the RAW fall through to the platform decoder below.
          return null;
        }
        const imageSource = image.createImageSource(buffer);
        const decodingOptions: image.DecodingOptions = {
          editable: true,
          desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        };
        if (maxDimension > 0) {
          // desiredSize 会按请求的宽高直接解码（不保持宽高比），必须按原图比例
          // 计算目标尺寸，否则非方形图片会被拉伸变形。同时解码即缩图控制内存。
          const rawInfo = await imageSource.getImageInfo();
          const rawW = rawInfo.size.width;
          const rawH = rawInfo.size.height;
          rawWidth = rawW;
          rawHeight = rawH;
          if (onSourceInfo) onSourceInfo(rawW, rawH);
          const scaleValue = Math.min(1, maxDimension / Math.max(rawW, rawH));
          decodingOptions.desiredSize = {
            width: Math.max(1, Math.round(rawW * scaleValue)),
            height: Math.max(1, Math.round(rawH * scaleValue)),
          };
        }
        const pixelMap = await imageSource.createPixelMap(decodingOptions);
        imageSource.release();
        // 系统解码器不处理 RAW 的 EXIF Orientation：对 RAW 文件补一次方向修正。
        if (rawSource) {          await RawPreviewLoader.applyContainerOrientation(pixelMap, buffer);
          const decodedInfo = await pixelMap.getImageInfo();
          const info: RawDecodeDescriptor = {
            sourceKind: RawSourceKind.SYSTEM_DECODER_RGBA,
            sourceUri: uri, sourceName: sourceNameHint,
            actualWidth: rawWidth > 0 ? rawWidth : decodedInfo.size.width,
            actualHeight: rawHeight > 0 ? rawHeight : decodedInfo.size.height,
            actualDimensionsKnown: rawWidth > 0 && rawHeight > 0,
            dimensionNote: rawWidth > 0 && rawHeight > 0 ? 'source decoder reported container dimensions' : 'source dimensions unavailable; output PixelMap dimensions only',
            outputWidth: decodedInfo.size.width, outputHeight: decodedInfo.size.height,
            bitDepth: null, colorSpace: 'unknown', transferFunction: 'unknown',
            processing: 'Harmony ImageSource RAW decoder; demosaic/white-balance/color transform are undocumented',
            dcpApplied: false,
          };
          onDecodeInfo?.(info);
          console.info('VIVID_RAW_SOURCE ' + rawDescriptorJson(info));
        } else {
          // 非 RAW：EXIF Orientation 是否被系统解码器应用，不同源/ROM 并不一致
          // （媒体库刚创建的资产、带 desiredSize 的缩放解码、富士 WiFi 下载的
          // JPEG 都可能漏掉）。这里按"JPEG SOF 存储宽高比 vs 解码宽高比"判断，
          // 只在解码器没转时补一次；已转过时不动，所以不会二次旋转。
          // 编辑器、导出、作品卡都走这里，方向因此只有一个真相源。
          const applied: number = await ExifOrientation.normalize(pixelMap, uri);
          if (applied > 1) {
            console.info(`VIVID_EXIF_ORIENTATION applied=${applied} uri=${uri}`);
          }
        }
        return pixelMap;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      console.error('Built-in decode failed for image:', uri, JSON.stringify(e));
    }
    // RAW fallback: use the embedded JPEG preview inside the TIFF container
    // (covers Panasonic RW2 and other RAW dialects the decoder rejects).
    if (rawSource) {
      try {
        const fallback = sourceBuffer ? await RawPreviewLoader.loadPreviewFromBytes(sourceBuffer, maxDimension) :
          await RawPreviewLoader.loadPreview(uri, maxDimension);
        if (fallback) {
          const previewInfo = await fallback.getImageInfo();
          const info: RawDecodeDescriptor = {
            sourceKind: RawSourceKind.EMBEDDED_JPEG_PREVIEW,
            sourceUri: uri, sourceName: sourceNameHint,
            actualWidth: 0, actualHeight: 0,
            actualDimensionsKnown: false,
            dimensionNote: 'RAW container dimensions unavailable; these are embedded JPEG preview dimensions only',
            outputWidth: previewInfo.size.width, outputHeight: previewInfo.size.height,
            bitDepth: 8, colorSpace: 'unknown (embedded JPEG ICC not inspected)',
            transferFunction: 'display-rendered JPEG; not linear camera RGB',
            processing: 'JPEG preview extracted from RAW container; no RAW export is possible from this buffer',
            dcpApplied: false,
          };
          onDecodeInfo?.(info);
          console.info('VIVID_RAW_SOURCE ' + rawDescriptorJson(info));
        }
        return fallback;
      } catch (e) {
        console.error('Failed to extract RAW preview:', uri, JSON.stringify(e));
      }
    }
    return null;
  }

  private static async createNativePixelMap(native: NativeRawDecodeResult): Promise<image.PixelMap | null> {
    try {
      const options: image.InitializationOptions = {
        editable: true,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        size: { width: native.width, height: native.height },
      };
      // Direct createPixelMap(buffer) misinterprets the RGBA byte order on
      // some devices (the wrap treats the input as BGRA, swapping R/B).
      // The empty-create + writeBufferToPixels path used by the preview
      // publisher keeps the channel order faithful.
      const pm = await image.createPixelMap(new ArrayBuffer(native.pixels.byteLength), options);
      await pm.writeBufferToPixels(native.pixels);
      return pm;
    } catch (error) {
      console.error('Failed to wrap LibRaw RGBA output:', String(error));
      return null;
    }
  }

  /**
   * Downscale a PixelMap to fit within maxDimension while maintaining aspect ratio.
   * If already smaller than maxDimension, returns a clone.
   */
  static async downscaleToFit(
    pixelMap: image.PixelMap,
    maxDimension: number,
  ): Promise<image.PixelMap | null> {
    try {
      const info = await pixelMap.getImageInfo();
      const w = info.size.width;
      const h = info.size.height;

      if (w <= maxDimension && h <= maxDimension) {
        // Already small enough, just clone
        const bufferSize = info.size.height * info.size.width * 4;
        const buffer = new ArrayBuffer(bufferSize);
        await pixelMap.readPixelsToBuffer(buffer);
        const opts: image.InitializationOptions = {
          editable: true,
          pixelFormat: image.PixelMapFormat.RGBA_8888,
          size: { width: w, height: h },
        };
        const colors = new ArrayBuffer(w * h * 4);
        const clone = await image.createPixelMap(colors, opts);
        await clone.writeBufferToPixels(buffer);
        return clone;
      }

      const scaleValue = maxDimension / Math.max(w, h);
      const newW = Math.round(w * scaleValue);
      const newH = Math.round(h * scaleValue);

      const opts: image.InitializationOptions = {
        editable: true,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        size: { width: newW, height: newH },
      };
      const scaleColors = new ArrayBuffer(newW * newH * 4);
      const scaled = await image.createPixelMap(scaleColors, opts);
      // Scale original pixelMap and read its pixels into the new scaled one
      await pixelMap.scale(scaleValue, scaleValue);
      const scaledPixels = new ArrayBuffer(newW * newH * 4);
      await pixelMap.readPixelsToBuffer(scaledPixels);
      await scaled.writeBufferToPixels(scaledPixels);
      return scaled;
    } catch (e) {
      console.error('Failed to downscale image:', JSON.stringify(e));
      return null;
    }
  }

  /**
   * Encode a PixelMap to JPEG buffer for export.
   */
  static async encodeToJpeg(pixelMap: image.PixelMap, quality: number = 90): Promise<ArrayBuffer | null> {
    try {
      const packer = image.createImagePacker();
      const opts: image.PackingOption = {
        format: 'image/jpeg',
        quality: quality,
      };
      const buffer = await packer.packToData(pixelMap, opts);
      packer.release();
      return buffer;
    } catch (e) {
      console.error('Failed to encode image:', JSON.stringify(e));
      return null;
    }
  }
}
