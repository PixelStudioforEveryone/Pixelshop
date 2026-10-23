import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';

const RAW_EXTENSIONS: string[] = [
  // Panasonic, Fuji, Sony, Nikon and Canon
  '.rw2', '.rwl', '.raw', '.dng', '.raf', '.arw', '.srf', '.sr2', '.nef', '.nrw', '.crw', '.cr2', '.cr3',
  // Olympus, Pentax, Samsung and other camera RAW containers
  '.orf', '.pef', '.srw', '.r3d', '.3fr', '.iiq', '.x3f', '.erf', '.kdc', '.mrw', '.bay', '.cap', '.eip',
  '.mef', '.mos', '.ptx', '.pxn', '.qtk', '.ari',
];

interface RawPreview {
  jpeg: ArrayBuffer;
  orientation: number;
}

/**
 * Loads RAW files the built-in decoder cannot handle by extracting the
 * embedded JPEG preview from the TIFF container. Panasonic RW2 (and most
 * other RAW dialects) ship a full-resolution preview JPEG inside the IFD
 * tree, which is exactly what camera apps and Lightroom mobile use for fast
 * preview; the editor then works on that preview non-destructively.
 */
export class RawPreviewLoader {
  static isRawFile(uri: string): boolean {
    const lower = uri.toLowerCase();
    for (let index = 0; index < RAW_EXTENSIONS.length; index++) {
      if (lower.endsWith(RAW_EXTENSIONS[index])) return true;
    }
    return false;
  }

  static async loadPreview(uri: string, maxDimension: number = 0): Promise<image.PixelMap | null> {
    const bytes = RawPreviewLoader.readFileBytes(uri);
    return RawPreviewLoader.loadPreviewFromBytes(bytes, maxDimension);
  }

  /** Panasonic RW2 容器识别：'II' + magic 0x0055（普通 TIFF/DNG 是 0x2A）。 */
  static isPanasonicRw2(data: ArrayBuffer): boolean {
    if (data.byteLength < 4) return false;
    const view = new DataView(data);
    return view.getUint8(0) === 0x49 && view.getUint8(1) === 0x49 && view.getUint8(2) === 0x55;
  }

  /** Decode an embedded RAW preview from bytes already read by the caller.
   * maxDimension 0 decodes at the preview's native size (editor full-res
   * fallback); any positive bound decodes scaled, which keeps a 45MP NEF
   * preview from allocating a ~180MB RGBA buffer for a 360px card. */
  static async loadPreviewFromBytes(bytes: ArrayBuffer | null, maxDimension: number = 0): Promise<image.PixelMap | null> {
    if (!bytes || bytes.byteLength < 8) return null;
    const preview = RawPreviewLoader.findLargestPreview(bytes);
    if (preview && preview.jpeg.byteLength > 0) {
      const pixelMap = await RawPreviewLoader.decodeJpeg(preview.jpeg, maxDimension);
      if (pixelMap) {
        // 竖拍/横拍由 EXIF Orientation 决定：容器内没有时再读内嵌 JPEG 的 EXIF。
        const orientation = preview.orientation !== 1 ?
          preview.orientation : RawPreviewLoader.readJpegOrientation(preview.jpeg);
        await RawPreviewLoader.applyOrientation(pixelMap, orientation);
        return pixelMap;
      }
    }
    // 兜底：IFD 树里没有标准预览标签时，直接扫描 JPEG SOI 标记逐个尝试解码
    // （松下 RW2 的预览引用在 MakerNote 内，标准标签找不到）。
    const candidates = RawPreviewLoader.findJpegCandidates(bytes);
    for (const candidate of candidates) {
      const pixelMap = await RawPreviewLoader.decodeJpeg(candidate, maxDimension);
      if (pixelMap) {
        const orientation = RawPreviewLoader.readOrientation(bytes);
        await RawPreviewLoader.applyOrientation(pixelMap, orientation);
        return pixelMap;
      }
    }
    return null;
  }

  private static async decodeJpeg(jpeg: ArrayBuffer, maxDimension: number = 0): Promise<image.PixelMap | null> {
    let imageSource: image.ImageSource | null = null;
    try {
      imageSource = image.createImageSource(jpeg);
      const decodingOptions: image.DecodingOptions = {
        editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      };
      if (maxDimension > 0) {
        const info = await imageSource.getImageInfo();
        const scaleValue = Math.min(1, maxDimension / Math.max(info.size.width, info.size.height));
        if (scaleValue < 1) {
          decodingOptions.desiredSize = {
            width: Math.max(1, Math.round(info.size.width * scaleValue)),
            height: Math.max(1, Math.round(info.size.height * scaleValue)),
          };
        }
      }
      const pixelMap = await imageSource.createPixelMap(decodingOptions);
      imageSource.release();
      return pixelMap;
    } catch (_error) {
      if (imageSource) {
        try { imageSource.release(); } catch (_releaseError) {
        }
      }
      return null;
    }
  }

  /** 扫描 JPEG SOI 标记，返回按 JPEG 实际长度降序排列的候选切片。 */
  private static findJpegCandidates(data: ArrayBuffer): ArrayBuffer[] {
    const view = new DataView(data);
    const candidates: ArrayBuffer[] = [];
    for (let offset = 0; offset + 2 < view.byteLength; offset++) {
      if (view.getUint8(offset) === 0xFF && view.getUint8(offset + 1) === 0xD8 &&
          offset + 3 < view.byteLength && view.getUint8(offset + 2) === 0xFF) {
        // Panasonic stores several JPEG previews inside the RW2 container.
        // Passing SOI→RAW-file-end to ImageSource is not reliable because the
        // trailing sensor data is not part of the JPEG.  JPEG entropy data
        // escapes literal FF bytes as FF00, so the first FF D9 after SOI is
        // the valid end marker for this bounded candidate.
        let end = -1;
        for (let cursor = offset + 3; cursor + 1 < view.byteLength; cursor++) {
          if (view.getUint8(cursor) === 0xFF && view.getUint8(cursor + 1) === 0xD9) {
            end = cursor + 2;
            break;
          }
        }
        if (end > offset + 2) candidates.push(data.slice(offset, end));
      }
      if (candidates.length >= 24) break;
    }
    candidates.sort((left: ArrayBuffer, right: ArrayBuffer) => right.byteLength - left.byteLength);
    return candidates;
  }

  /** 仅读取容器级 EXIF Orientation（供系统解码成功的 RAW 应用方向）。 */
  static readOrientation(data: ArrayBuffer): number {
    if (data.byteLength < 8) return 1;
    const view = new DataView(data);
    const b0 = view.getUint8(0);
    const b1 = view.getUint8(1);
    let littleEndian: boolean;
    if (b0 === 0x49 && b1 === 0x49) littleEndian = true;
    else if (b0 === 0x4D && b1 === 0x4D) littleEndian = false;
    else return 1;
    const magic = view.getUint16(2, littleEndian);
    if (magic !== 42 && magic !== 85) return 1;
    const orientationRef: number[] = [1];
    RawPreviewLoader.scanIfd(data, view, view.getUint32(4, littleEndian), littleEndian,
      [], new Set<number>(), orientationRef);
    return orientationRef[0];
  }

  /** 对已解码的 RAW 像素应用容器级方向（系统解码不处理 RAW 的 Orientation）。 */
  static async applyContainerOrientation(pixelMap: image.PixelMap, data: ArrayBuffer): Promise<void> {
    const orientation = RawPreviewLoader.readOrientation(data);
    await RawPreviewLoader.applyOrientation(pixelMap, orientation);
  }

  /** EXIF Orientation → 旋转/翻转，让竖图竖着显示、横图横着显示。 */
  static async applyOrientation(pixelMap: image.PixelMap, orientation: number): Promise<void> {
    try {
      if (orientation === 3) {
        await pixelMap.rotate(180);
      } else if (orientation === 6) {
        await pixelMap.rotate(90);
      } else if (orientation === 8) {
        await pixelMap.rotate(270);
      } else if (orientation === 2) {
        await pixelMap.flip(true, false);
      } else if (orientation === 4) {
        await pixelMap.flip(false, true);
      } else if (orientation === 5) {
        await pixelMap.rotate(90);
        await pixelMap.flip(true, false);
      } else if (orientation === 7) {
        await pixelMap.rotate(270);
        await pixelMap.flip(true, false);
      }
    } catch (_error) {
      // 方向信息缺失时保持原样
    }
  }

  /** 从内嵌 JPEG 的 APP1 Exif 段读取 Orientation（容器级缺失时的兜底）。 */
  private static readJpegOrientation(jpeg: ArrayBuffer): number {
    try {
      const view = new DataView(jpeg);
      let off = 2;
      while (off + 4 < view.byteLength) {
        if (view.getUint8(off) !== 0xFF) {
          off++;
          continue;
        }
        const marker = view.getUint8(off + 1);
        if (marker === 0xDA || marker === 0xD9) break; // SOS / EOI
        const len = view.getUint16(off + 2);
        if (marker === 0xE1 && off + 4 + 6 <= view.byteLength) {
          let isExif = true;
          const signature = 'Exif\0\0';
          for (let i = 0; i < 6; i++) {
            if (view.getUint8(off + 4 + i) !== signature.charCodeAt(i)) {
              isExif = false;
              break;
            }
          }
          if (isExif) {
            const tiffView = new DataView(jpeg, off + 4 + 6);
            const b0 = tiffView.getUint8(0);
            const b1 = tiffView.getUint8(1);
            let littleEndian: boolean;
            if (b0 === 0x49 && b1 === 0x49) littleEndian = true;
            else if (b0 === 0x4D && b1 === 0x4D) littleEndian = false;
            else break;
            if (tiffView.getUint16(2, littleEndian) === 42) {
              const orientationRef: number[] = [1];
              RawPreviewLoader.scanIfd(jpeg, tiffView, tiffView.getUint32(4, littleEndian), littleEndian,
                [], new Set<number>(), orientationRef);
              return orientationRef[0];
            }
          }
        }
        if (marker === 0xD8) {
          off += 2;
          continue;
        }
        if (marker >= 0xD0 && marker <= 0xD7) {
          off += 2;
          continue;
        }
        off += 2 + len;
      }
    } catch (_error) {
      return 1;
    }
    return 1;
  }

  private static readFileBytes(uri: string): ArrayBuffer | null {
    let file: fileIo.File | undefined;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      // A PhotoAccessHelper URI is not necessarily accepted by statSync(path),
      // while the descriptor obtained from openSync is always the exact source
      // being read.
      const size = fileIo.statSync(file.fd).size;
      const buffer = new ArrayBuffer(size);
      fileIo.readSync(file.fd, buffer);
      return buffer;
    } catch (_error) {
      return null;
    } finally {
      if (file) {
        try { fileIo.closeSync(file); } catch (_closeError) { }
      }
    }
  }

  /** Walk the TIFF IFD tree looking for embedded JPEG previews, return the largest. */
  private static findLargestPreview(data: ArrayBuffer): RawPreview | null {
    const view = new DataView(data);
    if (view.byteLength < 8) return null;
    const b0 = view.getUint8(0);
    const b1 = view.getUint8(1);
    let littleEndian: boolean;
    if (b0 === 0x49 && b1 === 0x49) littleEndian = true;
    else if (b0 === 0x4D && b1 === 0x4D) littleEndian = false;
    else return null;
    // 经典 TIFF magic 为 42；松下 RW2 使用 85。两者结构相同，都按经典解析。
    const magic = view.getUint16(2, littleEndian);
    if (magic !== 42 && magic !== 85) return null;

    const previews: ArrayBuffer[] = [];
    const visited = new Set<number>();
    const orientationRef: number[] = [1];
    RawPreviewLoader.scanIfd(data, view, view.getUint32(4, littleEndian), littleEndian, previews, visited,
      orientationRef);

    let largest: ArrayBuffer | null = null;
    for (let index = 0; index < previews.length; index++) {
      if (!largest || previews[index].byteLength > largest.byteLength) {
        largest = previews[index];
      }
    }
    if (!largest) return null;
    return { jpeg: largest, orientation: orientationRef[0] };
  }

  private static scanIfd(data: ArrayBuffer, view: DataView, offset: number, littleEndian: boolean,
    previews: ArrayBuffer[], visited: Set<number>, orientationRef: number[]): void {
    if (offset <= 0 || offset + 2 > view.byteLength || visited.has(offset)) return;
    visited.add(offset);
    const count = view.getUint16(offset, littleEndian);
    if (offset + 2 + count * 12 > view.byteLength) return;
    let jpegOffset = -1;
    let jpegLength = -1;
    let compression = 0;
    let photometric = 0;
    let stripOffsetsEntry = -1;
    let stripOffsetsType = 0;
    let stripOffsetsCount = 0;
    let stripCountsEntry = -1;
    let stripCountsType = 0;
    let stripCountsCount = 0;
    const subIfds: number[] = [];
    for (let index = 0; index < count; index++) {
      const entry = offset + 2 + index * 12;
      const tag = view.getUint16(entry, littleEndian);
      const type = view.getUint16(entry + 2, littleEndian);
      const valueCount = view.getUint32(entry + 4, littleEndian);
      const value = RawPreviewLoader.readEntryValue(view, entry + 8, type, valueCount, littleEndian);
      if (tag === 0x0201) jpegOffset = value;
      if (tag === 0x0202) jpegLength = value;
      if (tag === 0x0103) compression = value;
      if (tag === 0x0106) photometric = value;
      if (tag === 0x0112 && orientationRef[0] === 1) orientationRef[0] = value;
      if (tag === 0x0111) {
        stripOffsetsEntry = entry;
        stripOffsetsType = type;
        stripOffsetsCount = valueCount;
      }
      if (tag === 0x0117) {
        stripCountsEntry = entry;
        stripCountsType = type;
        stripCountsCount = valueCount;
      }
      if (tag === 0x8769 || tag === 0x8825) subIfds.push(value);
      if (tag === 0x014a) {
        // SubIFDs: a list of IFD offsets; a single value is inline.
        const listOffset = valueCount <= 1 ? entry + 8 : value;
        for (let sub = 0; sub < valueCount; sub++) {
          subIfds.push(view.getUint32(listOffset + sub * 4, littleEndian));
        }
      }
    }
    if (jpegOffset > 0 && jpegLength > 0 && jpegOffset + jpegLength <= data.byteLength) {
      previews.push(data.slice(jpegOffset, jpegOffset + jpegLength));
    }
    // NEF/CR2 的全尺寸 JPEG 预览由 StripOffsets/StripByteCounts(0x0111/0x0117)
    // + Compression 6/7 + YCbCr(6) 引用；IFD1 的 0x0201/0x0202 只有 160x120
    // 小图。多段 strip 按 TIFF 语义顺序拼接为一个候选。CFA 原始数据
    // (Photometric=32803) 与未压缩数据被条件排除，RW2 行为不受影响。
    if (stripOffsetsEntry >= 0 && stripCountsEntry >= 0 && photometric === 6 &&
      (compression === 6 || compression === 7)) {
      const stripOffsets = RawPreviewLoader.readU32Values(view, stripOffsetsEntry + 8,
        stripOffsetsType, stripOffsetsCount, littleEndian);
      const stripLengths = RawPreviewLoader.readU32Values(view, stripCountsEntry + 8,
        stripCountsType, stripCountsCount, littleEndian);
      const stripTotal = Math.min(stripOffsets.length, stripLengths.length);
      let mergedLength = 0;
      let stripsValid = stripTotal > 0;
      for (let strip = 0; strip < stripTotal; strip++) {
        if (stripOffsets[strip] <= 0 || stripLengths[strip] <= 0 ||
          stripOffsets[strip] + stripLengths[strip] > data.byteLength) {
          stripsValid = false;
          break;
        }
        mergedLength += stripLengths[strip];
      }
      if (stripsValid && mergedLength > 0) {
        const merged = new ArrayBuffer(mergedLength);
        const mergedView = new Uint8Array(merged);
        let mergedCursor = 0;
        for (let strip = 0; strip < stripTotal; strip++) {
          mergedView.set(new Uint8Array(data, stripOffsets[strip], stripLengths[strip]), mergedCursor);
          mergedCursor += stripLengths[strip];
        }
        previews.push(merged);
      }
    }
    for (let index = 0; index < subIfds.length; index++) {
      RawPreviewLoader.scanIfd(data, view, subIfds[index], littleEndian, previews, visited, orientationRef);
    }
    // IFD chains (IFD1 and beyond) also hold previews on some bodies.
    const next = view.getUint32(offset + 2 + count * 12, littleEndian);
    if (next > 0) {
      RawPreviewLoader.scanIfd(data, view, next, littleEndian, previews, visited, orientationRef);
    }
  }

  private static readEntryValue(view: DataView, valueOffset: number, type: number,
    count: number, littleEndian: boolean): number {
    const size = RawPreviewLoader.typeSize(type);
    if (size === 0) return 0;
    if (size * count <= 4) {
      if (size === 1) return view.getUint8(valueOffset);
      if (size === 2) return view.getUint16(valueOffset, littleEndian);
      return view.getUint32(valueOffset, littleEndian);
    }
    return view.getUint32(valueOffset, littleEndian);
  }

  /** 读取整型数组标签的全部值（StripOffsets/StripByteCounts 可能是多段）。 */
  private static readU32Values(view: DataView, valueOffset: number, type: number,
    count: number, littleEndian: boolean): number[] {
    const size = RawPreviewLoader.typeSize(type);
    const values: number[] = [];
    if (size === 0 || count <= 0) return values;
    if (size * count <= 4) {
      for (let index = 0; index < count; index++) {
        if (size === 1) values.push(view.getUint8(valueOffset + index));
        else if (size === 2) values.push(view.getUint16(valueOffset + index * 2, littleEndian));
        else values.push(view.getUint32(valueOffset + index * 4, littleEndian));
      }
      return values;
    }
    const base = view.getUint32(valueOffset, littleEndian);
    for (let index = 0; index < count; index++) {
      if (base + index * size + size > view.byteLength) break;
      if (size === 1) values.push(view.getUint8(base + index));
      else if (size === 2) values.push(view.getUint16(base + index * 2, littleEndian));
      else values.push(view.getUint32(base + index * 4, littleEndian));
    }
    return values;
  }

  private static typeSize(type: number): number {
    if (type === 1 || type === 2 || type === 6 || type === 7) return 1; // BYTE/ASCII/SBYTE/UNDEFINED
    if (type === 3 || type === 8) return 2; // SHORT/SSHORT
    if (type === 4 || type === 9 || type === 11) return 4; // LONG/SLONG/FLOAT
    if (type === 5 || type === 10 || type === 12) return 8; // RATIONAL/SRATIONAL/DOUBLE
    return 0;
  }
}
