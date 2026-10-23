import { UIContext } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { CustomLut } from '../../edit/models/LutLibrary';
import { LumixWifiCandidate } from '../../services/LumixCameraService';
import { AppLogPolicy } from '../../services/AppLogPolicy';

// Recent-work cards use the same 3:2 frame as the camera thumbnail and fill
// the card width.  Keeping this ratio in one place prevents a RAW preview
// decoder's letterbox from becoming visible as top/bottom black bars.
export const RECENT_THUMBNAIL_ASPECT_RATIO: number = 3 / 2;
// v5：缩略图生成时按 EXIF 方向归一化（`ExifOrientation`），此前竖拍图可能被
// 存成横置卡片；版本号一变，最近作品会在后台重建一次卡片（视频除外）。
// v6：方向判断多了两条兜底（媒体库 URI 读不到 EXIF 时用下载阶段抓到的方向；
// 读不到 JPEG SOF 存储尺寸时按"方向 5–8 显示必然是竖"判断）。此前尼康线下载的
// 竖拍图会被存成横置卡片，所以版本号再涨一次，让「最近作品」后台重建一遍。
export const RECENT_THUMBNAIL_VERSION: number = 6;

export interface PhotoItem {
  uri: string;
  // 首页只绑定这个低分辨率缩略图，不能把图库原图 URI 直接交给 Image。
  // 原图仍保留在 uri 中，进入编辑器时再按需加载。
  thumbUri: string;
  displayName: string;
  // Allows one-time migration of NEF cards created before the fixed-ratio
  // crop was introduced.
  thumbnailVersion?: number;
  rating?: number;
  /**
   * 这张卡片是竖构图（高 > 宽）。
   *
   * 让「最近作品」卡片按图定向：竖拍图不再被塞进固定 3:2 横框里裁成横构图。
   * 取值来自缩略图生成时**已经转过方向**的像素尺寸，不是猜的；老记录缺这个
   * 字段时按横图处理（与历史行为一致）。
   */
  portrait?: boolean;
}

/** 读取碰一碰 LUT 分享包中的字符串字段，缺失或非字符串时返回空串。 */
export function knockPackageField(pkg: Record<string, Object>, key: string): string {
  const value = pkg[key];
  return typeof value === 'string' ? value : '';
}

export function extensionFromName(name: string): string {
  const dot = name.lastIndexOf('.');
  return dot >= 0 && dot < name.length - 1 ? name.substring(dot + 1).toLowerCase() : '';
}

/** RAW families used by current Sony, Canon, Nikon, Panasonic and other
 * camera bodies. The extension is kept when saving so the camera's filename
 * and format remain visible to the user's gallery. */
export function isRawExtension(extension: string): boolean {
  const rawExtensions: string[] = [
    'raw', 'rw2', 'rwl', 'raf', 'crw', 'cr2', 'cr3', 'nef', 'nrw', 'arw', 'srf', 'sr2',
    'orf', 'srw', 'dng', 'pef', 'r3d', '3fr', 'iiq', 'x3f', 'erf', 'kdc', 'mrw', 'bay',
    'cap', 'eip', 'mef', 'mos', 'ptx', 'pxn', 'qtk', 'ari',
  ];
  return rawExtensions.indexOf(extension) >= 0;
}

/** Common camera movie containers. Videos are imported as VIDEO assets; the
 * editor never opens them — cards hand the file to the system player instead. */
export function isVideoExtension(extension: string): boolean {
  const videoExtensions: string[] = [
    'mov', 'mp4', 'm4v', 'avi', 'mpg', 'mpeg', 'mts', 'm2ts', '3gp', 'wmv', 'asf',
  ];
  return videoExtensions.indexOf(extension) >= 0;
}

/** 应用诊断日志：内存环形缓冲（页面即时查看）+ 每日落盘文件（问题反馈
 * 发送）。落盘按天命名，启动时一日一清，防沙箱体积增长；单日文件超过
 * 上限时轮转一次，避免异常刷屏占满磁盘。 */
export class AppLogStore {
  private static entries: string[] = [];
  private static logDir: string = '';
  private static pending: string[] = [];
  private static flushTimer: number = -1;
  private static readonly MAX_MEMORY_LINES: number = 300;
  private static readonly MAX_DAY_FILE_BYTES: number = 4 * 1024 * 1024;

  /** 由 EntryAbility 在 onCreate 调用；filesDir 确定后开启落盘与清理。 */
  static init(filesDir: string): void {
    AppLogStore.logDir = filesDir + '/logs';
    try {
      fileIo.mkdirSync(AppLogStore.logDir, true);
    } catch (_error) {
      // 已存在或沙箱异常时忽略，后续写盘各自容错。
    }
    AppLogStore.cleanOldDays();
  }

  static add(message: string): void {
    // 换行折叠成单行：服务端按「每行 ISO 时间戳开头」严格校验日志格式，
    // js_error 等多行异常栈必须压平，否则整包被拒。
    const safe = AppLogPolicy.sanitize(message);
    if (safe.length === 0) return;
    const line = new Date().toISOString() + ' ' + safe;
    AppLogStore.entries.push(line);
    if (AppLogStore.entries.length > AppLogStore.MAX_MEMORY_LINES) {
      AppLogStore.entries.splice(0, AppLogStore.entries.length - AppLogStore.MAX_MEMORY_LINES);
    }
    if (AppLogStore.logDir.length > 0) {
      AppLogStore.pending.push(line);
      AppLogStore.scheduleFlush();
    }
  }

  static recent(windowMs: number): string[] {
    const cutoff = Date.now() - windowMs;
    return AppLogStore.entries.filter((line: string) => {
      const time = Date.parse(line.substring(0, 24));
      return Number.isNaN(time) || time >= cutoff;
    });
  }

  /** 立即写盘（异常栈捕获后调用，崩溃前的最后几行不丢）。 */
  static flushNow(): void {
    if (AppLogStore.flushTimer >= 0) {
      clearTimeout(AppLogStore.flushTimer);
      AppLogStore.flushTimer = -1;
    }
    if (AppLogStore.pending.length === 0 || AppLogStore.logDir.length === 0) return;
    const text = AppLogStore.pending.join('\n') + '\n';
    AppLogStore.pending = [];
    const path = AppLogStore.dayFilePath();
    try {
      try {
        if (fileIo.statSync(path).size > AppLogStore.MAX_DAY_FILE_BYTES) {
          try { fileIo.unlinkSync(AppLogStore.rotatedFilePath()); } catch (_missing) { }
          fileIo.moveFileSync(path, AppLogStore.rotatedFilePath());
        }
      } catch (_statError) {
        // 首次写入没有旧文件。
      }
      // WRITE_ONLY 不可省：CREATE|APPEND 缺少访问模式时句柄为只读，
      // writeSync 会静默失败导致日志永远为空。
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
      try {
        const bytes = util.TextEncoder.create('utf-8').encode(text);
        fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_error) {
      // 写盘失败不影响内存日志与页面功能。
    }
  }

  /** 今天的完整落盘日志（含轮转文件），供问题反馈预览与发送。 */
  static todayLogText(): string {
    AppLogStore.flushNow();
    let text = '';
    if (AppLogStore.logDir.length > 0) {
      text += AppLogStore.readFileText(AppLogStore.rotatedFilePath());
      text += AppLogStore.readFileText(AppLogStore.dayFilePath());
    }
    // 落盘不可用（写盘失败/文件缺失）时回退内存缓冲，保证功能可用。
    if (text.trim().length === 0) {
      return AppLogStore.entries.join('\n');
    }
    return text;
  }

  /** 上传按 UTF-8 字节数限额，保留完整的最新日志行。 */
  static uploadLogText(): string {
    return AppLogPolicy.prepareUpload(AppLogStore.todayLogText());
  }

  /** 一日一清：删除非当天的日志文件，防止占用持续增长。 */
  static cleanOldDays(): void {
    if (AppLogStore.logDir.length === 0) return;
    try {
      const today = 'applog-' + AppLogStore.dateStamp(new Date());
      const names = fileIo.listFileSync(AppLogStore.logDir);
      for (const name of names) {
        if (name.indexOf('applog-') !== 0 || name.indexOf(today) === 0) continue;
        try {
          fileIo.unlinkSync(AppLogStore.logDir + '/' + name);
        } catch (_error) {
        }
      }
    } catch (_error) {
    }
  }

  private static scheduleFlush(): void {
    if (AppLogStore.flushTimer >= 0) return;
    AppLogStore.flushTimer = setTimeout(() => {
      AppLogStore.flushTimer = -1;
      AppLogStore.flushNow();
    }, 1500) as number;
  }

  private static dateStamp(date: Date): string {
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    return date.getFullYear().toString() + month + day;
  }

  private static dayFilePath(): string {
    return AppLogStore.logDir + '/applog-' + AppLogStore.dateStamp(new Date()) + '.txt';
  }

  private static rotatedFilePath(): string {
    return AppLogStore.logDir + '/applog-' + AppLogStore.dateStamp(new Date()) + '-prev.txt';
  }

  private static readFileText(path: string): string {
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const size = fileIo.statSync(file.fd).size;
        if (size <= 0) return '';
        const buffer = new ArrayBuffer(size);
        fileIo.readSync(file.fd, buffer);
        return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_error) {
      return '';
    }
  }
}

/**
 * 首页拆分为四个常驻子页面后，导航文字的自适应颜色计算不再依赖单一
 * struct 的状态。快照目标 id（homeContentStack）仍由壳页面持有，因此
 * 这里通过传入的 UIContext 读取官方 componentSnapshot 快照。
 */
export class NavColorService {
  private static navContentColor: string = '#000000';
  private static navLuminance: number = 200;
  private static timer: number = -1;
  private static pending: boolean = false;
  private static running: boolean = false;

  /** 节流：滚动中每约 100ms 最多刷新一次，保证实时跟手又不堆积快照任务。 */
  static schedule(uiContext: UIContext): void {
    if (NavColorService.pending) return;
    NavColorService.pending = true;
    NavColorService.timer = setTimeout(() => {
      NavColorService.pending = false;
      NavColorService.timer = -1;
      NavColorService.refresh(uiContext);
    }, 100);
  }

  /**
   * 用官方 componentSnapshot 快照 API 读取菜单栏遮挡区域的渲染像素，按平均
   * 亮度自适应导航文字颜色：背景以深色为主 → 纯白，以浅色为主 → 纯黑。
   */
  private static async refresh(uiContext: UIContext): Promise<void> {
    if (NavColorService.running) return;
    NavColorService.running = true;
    try {
      const snapshot = uiContext.getComponentSnapshot();
      const pixelMap = await snapshot.get('homeContentStack', { scale: 0.2 });
      const info = await pixelMap.getImageInfo();
      const width = info.size.width;
      const height = info.size.height;
      const buffer = new ArrayBuffer(width * height * 4);
      await pixelMap.readPixelsToBuffer(buffer);
      const pixels = new Uint8Array(buffer);

      // 采样底部菜单栏遮挡区域（约底部 15% 行）。
      let luminance = 0;
      let count = 0;
      const startY = Math.max(0, height - Math.max(3, Math.floor(height * 0.15)));
      for (let y = startY; y < height; y += 2) {
        for (let x = 0; x < width; x += 2) {
          const idx = (y * width + x) * 4;
          luminance += 0.2126 * pixels[idx] + 0.7152 * pixels[idx + 1] + 0.0722 * pixels[idx + 2];
          count++;
        }
      }
      pixelMap.release();
      if (count === 0) return;
      const average = luminance / count;
      // EMA 平滑 + 迟滞阈值：中色调背景（如传输页彩色统计卡片）不会误判为
      // 深色，且在阈值附近来回滑动也不会频繁跳变。
      NavColorService.navLuminance = NavColorService.navLuminance * 0.4 + average * 0.6;
      if (NavColorService.navContentColor === '#000000' && NavColorService.navLuminance < 105) {
        NavColorService.navContentColor = '#FFFFFF';
      } else if (NavColorService.navContentColor === '#FFFFFF' && NavColorService.navLuminance > 150) {
        NavColorService.navContentColor = '#000000';
      }
    } catch (_error) {
      // 保持当前颜色
    } finally {
      NavColorService.running = false;
    }
  }
}

/**
 * 四个常驻子页面之间的跨页调用走函数桥：子页面在 aboutToAppear 注册、
 * aboutToDisappear 注销，调用方通过可空函数指针访问，避免页面间持有
 * 组件实例。常驻挂载保证注册先于任何跨页动作。
 */
export class WorksBridge {
  static importPhotos: ((uris: string[]) => Promise<void>) | null = null;
  static addImportedPhoto:
    ((uri: string, displayNameOverride: string, fallbackThumbUri: string, orientation: number)
      => Promise<PhotoItem | null>) | null = null;
  static repairMissingThumbnails: (() => void) | null = null;
  static shareSelectedPhotos: (() => void) | null = null;
}

export class LutBridge {
  static ensureLutsLoaded: (() => Promise<void>) | null = null;
  static findAnyLut: ((name: string) => CustomLut | undefined) | null = null;
  static loadBundledLut: ((name: string) => Promise<CustomLut | null>) | null = null;
  // 云同步（ProfileSection 下载 → LutPage 落库）：LutPage 注册实现，
  // 返回 false 表示本地已有同名 LUT（跳过）。
  static listCustomLutNames: (() => string[]) | null = null;
  static importCloudLut: ((lut: CustomLut) => Promise<boolean>) | null = null;
}

export class CameraBridge {
  static isPtpIpCamera: (() => boolean) | null = null;
  static scanCameraWifi: (() => void) | null = null;
  static confirmCameraWifi: ((candidate: LumixWifiCandidate) => void) | null = null;
}
