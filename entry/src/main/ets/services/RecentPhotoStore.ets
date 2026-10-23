import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PixelMapUtils } from '../edit/utils/PixelMapUtils';
import { RawPreviewLoader } from '../edit/utils/RawPreviewLoader';
import { ExifOrientation } from '../edit/utils/ExifOrientation';

export interface RecentPhotoRecord {
  uri: string;
  thumbUri: string;
  displayName: string;
  thumbnailVersion?: number;
  rating?: number;
  /** 卡片是竖构图（高 > 宽）；由转过方向后的缩略图尺寸得出，与 WorksPage 的 PhotoItem 对齐。 */
  portrait?: boolean;
}

/** 一张缩略图连同它转正后的构图方向。 */
interface RecentThumb {
  uri: string;
  portrait: boolean;
}

/**
 * Shared persistence bridge for pages that open a photo outside Index.
 * Recent-work records keep the source URI and a local JPEG thumbnail separately.
 */
export class RecentPhotoStore {
  private static displayName(uri: string): string {
    let value = uri;
    const query = value.indexOf('?');
    if (query >= 0) value = value.substring(0, query);
    const hash = value.indexOf('#');
    if (hash >= 0) value = value.substring(0, hash);
    const slash = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
    if (slash >= 0) value = value.substring(slash + 1);
    try { value = decodeURIComponent(value); } catch (_error) { }
    return value.length > 0 ? value : '未命名照片';
  }

  private static key(uri: string): string {
    let hash = 2166136261;
    for (let index = 0; index < uri.length; index++) {
      hash ^= uri.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16);
  }

  /**
   * 生成「最近作品」卡片缩略图。
   *
   * 方向处理分两种来源（和 WorksPage.createImportedThumbnail 同一套规则）：
   *   - 原图：系统解码器可能没应用 EXIF（Fuji JPEG/HEIC、刚创建的媒体资产），
   *     用 `ExifOrientation.normalize` 判断后补一次；
   *   - 相机缩略图（`fallbackThumbUri`，仅在原图读不出来时用）：它不带 EXIF，
   *     按调用方给的 `orientation` 显式转。
   */
  private static async createThumbnail(context: common.UIAbilityContext,
    uri: string, displayName: string, fallbackThumbUri: string = '',
    orientation: number = 0): Promise<RecentThumb> {
    let pixelMap: image.PixelMap | null = null;
    try {
      pixelMap = await PixelMapUtils.loadFromUri(uri, 720, undefined, undefined,
        undefined, displayName, undefined, true);
      if (pixelMap) {
        // 补方向后再算 portrait，竖拍卡片才会用 2:3 的框。
        //
        // **必须把 orientation 兜底传进去**：媒体库 URI 刚建好时经常读不到 EXIF
        // （`fileIo` 打不开 → 读不到 SOF，`ImageSource` 也可能还没就绪），此时
        // `normalize` 只能靠调用方给的方向。此前这里只传了两个参数，兜底被丢掉，
        // 于是「下载阶段明明读到了 6/8，卡片却仍是横置」——WorksPage 那条路传了，
        // 两条路因此表现不一致。
        const applied: number = await ExifOrientation.normalize(pixelMap, uri, orientation);
        if (applied > 1) {
          hilog.info(0x0001, 'VIVID_EXIF_ORIENTATION',
            'recent thumb applied=%{public}d name=%{public}s', applied, displayName);
        }
      }
      if (!pixelMap && fallbackThumbUri.length > 0) {
        pixelMap = await PixelMapUtils.loadFromUri(fallbackThumbUri, 720);
        if (pixelMap && orientation > 1) {
          await RawPreviewLoader.applyOrientation(pixelMap, orientation);
        }
      }
      if (!pixelMap) return { uri: '', portrait: false };
      const info: image.ImageInfo = await pixelMap.getImageInfo();
      const portrait: boolean = info.size.height > info.size.width;
      const jpeg = await PixelMapUtils.encodeToJpeg(pixelMap, 82);
      if (!jpeg) return { uri: '', portrait: false };
      const path = context.filesDir + '/vivid_import_thumb_' + RecentPhotoStore.key(uri) + '.jpg';
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(file.fd, jpeg); } finally { fileIo.closeSync(file); }
      return { uri: 'file://' + path, portrait: portrait };
    } catch (_error) {
      return { uri: '', portrait: false };
    } finally {
      if (pixelMap) pixelMap.release();
    }
  }

  static async list(context: common.UIAbilityContext): Promise<RecentPhotoRecord[]> {
    try {
      const storage = await preferences.getPreferences(context, 'vivid_imported_photos');
      const raw = await storage.get('items', '[]');
      if (typeof raw !== 'string') return [];
      const parsed = JSON.parse(raw) as RecentPhotoRecord[];
      if (!(parsed instanceof Array)) return [];
      return parsed.filter((item: RecentPhotoRecord) =>
        !!item && typeof item.uri === 'string' && item.uri.length > 0);
    } catch (_error) {
      return [];
    }
  }
  /**
   * 追加一条最近作品记录（同 URI 去重，最新在前）。
   *
   * @param fallbackThumbUri 原图当前读不出来时的兜底像素源（例如相机缩略图缓存）；
   * @param orientation 兜底缩略图的 EXIF 方向（1/3/6/8…），只有兜底源不带 EXIF 时才需要。
   */
  static async add(context: common.UIAbilityContext, uri: string,
    displayNameHint: string = '', fallbackThumbUri: string = '',
    orientation: number = 0): Promise<void> {
    if (uri.length === 0) return;
    const displayName = displayNameHint.length > 0 ? displayNameHint : RecentPhotoStore.displayName(uri);
    const thumb: RecentThumb = await RecentPhotoStore.createThumbnail(context, uri, displayName,
      fallbackThumbUri, orientation);
    try {
      const storage = await preferences.getPreferences(context, 'vivid_imported_photos');
      const raw = await storage.get('items', '[]');
      let existing: RecentPhotoRecord[] = [];
      if (typeof raw === 'string') {
        try {
          const parsed = JSON.parse(raw) as RecentPhotoRecord[];
          if (parsed instanceof Array) existing = parsed.filter((item: RecentPhotoRecord) =>
            !!item && typeof item.uri === 'string' && item.uri.length > 0);
        } catch (_error) { existing = []; }
      }
      const previous = existing.find((item: RecentPhotoRecord): boolean => item.uri === uri);
      const record: RecentPhotoRecord = {
        uri: uri,
        thumbUri: thumb.uri.length > 0 ? thumb.uri : uri,
        displayName: displayName,
        thumbnailVersion: 5,
        rating: previous?.rating ?? 0,
        portrait: thumb.uri.length > 0 ? thumb.portrait : (previous?.portrait ?? false),
      };
      const next = [record].concat(existing.filter((item: RecentPhotoRecord) => item.uri !== uri));
      await storage.put('items', JSON.stringify(next));
      await storage.flush();
      AppStorage.setOrCreate('recentPhotoRevision', Date.now());
    } catch (_error) {
      // The editor can still open the scoped picker URI when preferences fail.
    }
  }

  static async rate(context: common.UIAbilityContext, uri: string, stars: number): Promise<void> {
    const records = await RecentPhotoStore.list(context);
    const record = records.find((item: RecentPhotoRecord): boolean => item.uri === uri);
    if (!record) return;
    record.rating = Math.max(0, Math.min(5, Math.round(stars)));
    const storage = await preferences.getPreferences(context, 'vivid_imported_photos');
    await storage.put('items', JSON.stringify(records));
    await storage.flush();
    AppStorage.setOrCreate('recentPhotoRevision', Date.now());
  }
}




