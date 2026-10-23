import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { RawPreviewLoader } from './RawPreviewLoader';

/** EXIF 方向的原始像素尺寸与解码尺寸比较结果。 */
interface OrientationSizePair {
  rawWidth: number;
  rawHeight: number;
  decodedWidth: number;
  decodedHeight: number;
}

/**
 * EXIF 方向归一化（目前只对 JPEG 生效，其余格式保守不动）。
 *
 * 背景：`image.createPixelMap()` 在多数情况下会按 EXIF Orientation 自动转正，
 * 但**不是所有路径都这样**——带 `desiredSize` 的缩放解码、媒体库刚创建的资产
 * （EPERM 前后）、个别 ROM 的解码器都可能拿不到方向。后果就是竖拍照片在
 * 「最近作品」里被当成横图：卡片是 3:2 横框、内容横置。
 *
 * 判断方法：JPEG 的**存储像素尺寸**从 SOF 段直接读（与解码器无关），再和解码后的
 * 宽高比比较：
 *   - 方向 5/6/7/8 会交换宽高 → 解码宽高比 ≈ 1/存储宽高比，说明解码器已经转过；
 *   - 解码宽高比 ≈ 存储宽高比，说明没转，此时才补一次旋转（避免二次旋转）。
 * 方向 2/3/4 不改变宽高比，无法从尺寸判断，按"解码器已处理"对待；
 * 非 JPEG（HEIC 等）拿不到可信的存储尺寸，同样不动。
 */
export class ExifOrientation {
  /** 读取文件里的 EXIF Orientation（1–8）。失败返回 1（Top-left，不旋转）。
   *
   *  两条路都试：**先按文件描述符读**（沙箱文件、大多数媒体库 URI 都行），再退到
   *  `image.createImageSource(uri)` 直接解 URI。尼康线下载的原图存在媒体库里，
   *  某些 ROM 上 `fileIo.openSync(媒体库 URI)` 会被拒（EPERM），只走第一条路就会
   *  恒返回 1，于是竖拍图在「最近作品」和打开后的编辑页里都是横着的——这正是
   *  「尼康线竖图横置」的直接原因。 */
  static async read(uri: string): Promise<number> {
    const byFile: number = await ExifOrientation.readByFd(uri);
    if (byFile > 1) return byFile;
    return await ExifOrientation.readBySource(uri);
  }

  private static async readByFd(uri: string): Promise<number> {
    let file: fileIo.File | null = null;
    let source: image.ImageSource | null = null;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      if (!source) return 1;
      // 不同 ROM 返回 "1"/"Top-left" 两种写法，统一解析。
      const raw: string = await source.getImageProperty(image.PropertyKey.ORIENTATION);
      return ExifOrientation.parseValue(raw);
    } catch (_error) {
      return 1;
    } finally {
      if (source !== null) {
        try {
          await source.release();
        } catch (_releaseError) {
        }
      }
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
        }
      }
    }
  }

  /** 直接拿 URI 建 ImageSource 读方向（媒体库 URI 的兜底）。 */
  private static async readBySource(uri: string): Promise<number> {
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(uri);
      if (!source) return 1;
      const raw: string = await source.getImageProperty(image.PropertyKey.ORIENTATION);
      return ExifOrientation.parseValue(raw);
    } catch (_error) {
      return 1;
    } finally {
      if (source !== null) {
        try {
          await source.release();
        } catch (_releaseError) {
        }
      }
    }
  }

  /** JPEG 的存储像素尺寸（未应用 EXIF 旋转的宽高）；非 JPEG 返回 null。 */
  private static rawSize(uri: string): OrientationSizePair | null {
    // JPEG 直接从 SOF 段读"存储像素尺寸"：这是唯一不受解码器是否应用 EXIF 影响的
    // 权威值（部分 ROM 的 ImageSource.getImageInfo() 本身就会返回旋转后的尺寸）。
    return ExifOrientation.jpegPixelSize(uri);
  }

  /**
   * 只读 JPEG 头部，从 SOF 段取存储像素的宽高（不是旋转后的显示尺寸）。
   * 非 JPEG / 读失败返回 null；最多读 512 KB，够覆盖带大 EXIF/ICC 的头。
   */
  private static jpegPixelSize(uri: string): OrientationSizePair | null {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(524288);
      const read: number = fileIo.readSync(file.fd, buffer);
      if (read <= 4) return null;
      const bytes = new Uint8Array(buffer, 0, read);
      if (bytes[0] !== 0xFF || bytes[1] !== 0xD8) return null;
      const be16 = (at: number): number => (bytes[at] << 8) | bytes[at + 1];
      let offset = 2;
      while (offset + 9 < bytes.length) {
        if (bytes[offset] !== 0xFF) {
          offset += 1;
          continue;
        }
        const marker = bytes[offset + 1];
        if (marker === 0xD8 || marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
          offset += 2;
          continue;
        }
        if (marker === 0xD9 || marker === 0xDA) break; // EOI / SOS 前没有 SOF
        const length = be16(offset + 2);
        if (length < 2) break;
        // SOF0–SOF15，除 DHT(C4)/JPG(C8)/DAC(CC)。
        if (marker >= 0xC0 && marker <= 0xCF && marker !== 0xC4 && marker !== 0xC8 && marker !== 0xCC) {
          const height = be16(offset + 5);
          const width = be16(offset + 7);
          if (width > 0 && height > 0) {
            return { rawWidth: width, rawHeight: height, decodedWidth: 0, decodedHeight: 0 };
          }
          return null;
        }
        offset += 2 + length;
      }
      return null;
    } catch (_error) {
      return null;
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
        }
      }
    }
  }

  /**
   * 只在「解码器没应用 EXIF」时补旋转，返回本次实际应用的方向（1 表示没动）。
   *
   * @param pixelMap 已经解码好的缩略图（会被就地旋转）
   * @param uri 原始文件/媒体库 URI，用来读方向与原始尺寸
   * @param fallbackOrientation 文件里读不到方向时的兜底（下载阶段从沙箱临时文件
   *        读到的值，尼康线就是靠它；0/1 表示没有兜底）
   */
  static async normalize(pixelMap: image.PixelMap, uri: string,
    fallbackOrientation: number = 0): Promise<number> {
    try {
      let orientation: number = await ExifOrientation.read(uri);
      if (orientation <= 1 && fallbackOrientation >= 2 && fallbackOrientation <= 8) {
        orientation = fallbackOrientation;
      }
      if (orientation <= 1) return 1;
      if (orientation === 2 || orientation === 3 || orientation === 4) {
        // 不改变宽高比，无法从尺寸判断是否已转；按解码器已处理对待。
        return 1;
      }
      const decoded: image.ImageInfo = await pixelMap.getImageInfo();
      const decodedWidth: number = decoded.size.width;
      const decodedHeight: number = decoded.size.height;
      if (decodedWidth <= 0 || decodedHeight <= 0) return 1;
      const raw: OrientationSizePair | null = ExifOrientation.rawSize(uri);
      if (raw === null) {
        // 拿不到**存储**像素尺寸（媒体库 URI 常见：`fileIo` 打不开就只读不到 SOF）。
        // 但方向 5–8 有一个可靠的不变量：**显示出来必然是竖的**（它们描述的是
        // "存储的横图要转成竖图"）。所以只需看解码结果——已经是竖的就说明解码器
        // 转过了，不用再转；还是横的就补一次。这条判断不依赖读文件，正好覆盖
        // 尼康线下载到媒体库后的情形。
        if (decodedWidth > decodedHeight) {
          await RawPreviewLoader.applyOrientation(pixelMap, orientation);
          return orientation;
        }
        return 1;
      }
      const rawAspect: number = raw.rawWidth / raw.rawHeight;
      const decodedAspect: number = decodedWidth / decodedHeight;
      const rotatedAspect: number = 1 / rawAspect;
      const asIs: number = Math.abs(decodedAspect - rawAspect);
      const swapped: number = Math.abs(decodedAspect - rotatedAspect);
      // 解码器已经转过：解码宽高比贴近旋转后的比例，就不要再转一次。
      if (swapped <= asIs) return 1;
      await RawPreviewLoader.applyOrientation(pixelMap, orientation);
      return orientation;
    } catch (_error) {
      return 1;
    }
  }

  /** "6" / "Top-left" / "Right-top" 等写法统一映射到 1–8。 */
  private static parseValue(raw: string): number {
    if (typeof raw !== 'string') return 1;
    const text: string = raw.trim();
    if (text.length === 0) return 1;
    const numeric: number = Number.parseInt(text, 10);
    if (!Number.isNaN(numeric) && numeric >= 1 && numeric <= 8) return numeric;
    const lower: string = text.toLowerCase();
    if (lower.indexOf('top-left') >= 0) return 1;
    if (lower.indexOf('top-right') >= 0) return 2;
    if (lower.indexOf('bottom-right') >= 0) return 3;
    if (lower.indexOf('bottom-left') >= 0) return 4;
    if (lower.indexOf('left-top') >= 0) return 5;
    if (lower.indexOf('right-top') >= 0) return 6;
    if (lower.indexOf('right-bottom') >= 0) return 7;
    if (lower.indexOf('left-bottom') >= 0) return 8;
    return 1;
  }
}
