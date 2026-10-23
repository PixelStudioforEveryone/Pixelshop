/**
 * FUJIFILM 图片传输服务（角色 C）。
 *
 * 一条链：PTP-IP 建链 → event 11 → SetFunctionMode(20=IMAGE_VIEW_V2)
 *        → SetFunctionVersion(0xDF28, 相机版本) → GetDualSlotStatus
 *        → 切槽（SetDualSlotStatus）→ 当前句柄 / 总张数 / 全部句柄
 *        → 逐条 GetExtensionObjectInfo → 缩略图队列 → 勾选下载。
 *
 * 关键结论（逆向证据见 docs/fujifilm/NOTES_C.md）：
 *   - FFIR 的 0x6073/0x6074 是内部命令 ID，线上是
 *     Set/GetDevicePropValue(0xD244, UINT8)；
 *   - SetFunctionMode 的属性是 0xDF01（不是 FujifilmProp.FUNCTION_MODE 的
 *     0x5002），数据类型 UINT16；
 *   - Get/SetFunctionVersion 用 0xDF28，数据类型 UINT32；
 *   - 张数 / 句柄 / 当前句柄都是 GetDevicePropValue：0xD620 / 0xD621 / 0xD22B；
 *   - 日期分组张数用 0x9053，扩展对象信息 0x9054，扩展缩略图 0x9055，
 *     扩展分块 0x9056。
 *
 * 本文件不修改协议层；0xD244/0xDF01/0xD22B/0xD620/0xD621/0x9053 暂放在
 * 本文件的 FujifilmTransferCode 里，待协调者并入 FujifilmProtocol。
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import {
  FujifilmBytes,
  FujifilmEvent,
  FujifilmMode,
  FujifilmNet,
  FujifilmOp,
  FujifilmResponse,
} from './FujifilmProtocol';
import { FujifilmEventFrame, FujifilmPtpIp, FujifilmReply } from './FujifilmPtpIp';
import { AppLogStore } from '../pages/home/HomeShared';
import { CameraSessionStore } from './CameraSessionStore';
import { RecentPhotoStore } from './RecentPhotoStore';
import { RawPreviewLoader } from '../edit/utils/RawPreviewLoader';
import { PixelMapUtils } from '../edit/utils/PixelMapUtils';

const FUJI_TAG: string = '[FUJI]';
/** 官方 App 只在相机 version <= 3 时下发 SetFunctionVersion。 */
const APP_IMAGE_VIEW_VERSION: number = 3;
/** 功能模式写入最多重试 5 次，间隔 100ms（ImportImageModel）。 */
const MODE_RETRY_COUNT: number = 5;
const RETRY_INTERVAL_MS: number = 100;
/** 等 event 11 的上限；等不到也继续，后面的模式写入才是硬门。 */
const EVENT11_WAIT_MS: number = 6000;
/** 官方 GET_OBJECT_SIZE_ONE_TIME = 20 MiB：小于它一次 GetObject 拉整文件。 */
const WHOLE_OBJECT_LIMIT: number = 20971520;
/** MOV/RAF 分块大小，等于官方滚动缓冲。 */
const PARTIAL_CHUNK: number = FujifilmNet.DOWNLOAD_ROLLING_BUFFER;
/** 单个文件最多 2 次尝试，失败即记一条，不无限重试。 */
const DOWNLOAD_MAX_ATTEMPTS: number = 2;
/** 缩略图队列上限：可见行 ×3，最多 50。 */
const THUMB_QUEUE_LIMIT: number = 50;
const THUMB_MEMORY_LIMIT: number = 24;
const SAVE_CHUNK_BYTES: number = 8 * 1024 * 1024;
const DIRECTORY_NAME: string = 'fujifilm';
const THUMB_DIRECTORY: string = 'thumbs';
const ALL_STORAGE_ID: number = 0xFFFFFFFF;
/** PTP 文件夹对象，图库里要跳过。 */
const FORMAT_ASSOCIATION: number = 0x3001;
/**
 * 0x9054 私有 metadata 里的方向键。
 *
 * 逆向结论（NOTES_F §2）：方向**不是**固定偏移的 u8/u16 数值字段，而是相机在
 * 第 4 个 PTP 字符串（filename / captureDate / modificationDate 之后）里塞的
 * 一段 ASCII `key:value` 文本，例如 `Orientation:6`。native 在
 * `_FTL_PTP_OBJECT_INFO+820` 的字符串里 `memchr` 找 "Orientation:" 后 `atoi`，
 * 所以这里也按“在整包里找标记”解析，不对 wire 偏移做硬编码。
 */
const ORIENTATION_KEY: string = 'Orientation:';

/** 本文件用到的富士私有码；待协议层收编后从这里删掉。 */
export class FujifilmTransferCode {
  /** SetFunctionMode 的属性：SDK_SetFunctionMode ctor 里 w3=0xDF01、w4=4(UINT16)。 */
  static readonly PROP_FUNCTION_MODE: number = 0xDF01;
  /** 双槽状态：SDK_Get/SetDualSlotStatus 的 w3=0xD244、UINT8。 */
  static readonly PROP_DUAL_SLOT_STATUS: number = 0xD244;
  /** 当前对象句柄。 */
  static readonly PROP_CURRENT_OBJECT_HANDLE: number = 0xD22B;
  /** 当前对象空间总张数。 */
  static readonly PROP_SPECIFIED_OBJECT_COUNT: number = 0xD620;
  /** 当前对象空间全部句柄（数组）。 */
  static readonly PROP_SPECIFIED_OBJECT_HANDLES: number = 0xD621;
  /** 按日期分组张数（offset=0, count=30000）。 */
  static readonly OP_COUNT_GROUP_BY_DATE: number = 0x9053;

  /** 富士真实文件格式（ObjectInfo 偏移 48 的 u32）。 */
  static readonly FORMAT_EXIF_JPEG: number = 0x3801;
  static readonly FORMAT_JFIF: number = 0x3808;
  static readonly FORMAT_HEIF: number = 0x3812;
  static readonly FORMAT_RAF: number = 0xB103;
  static readonly FORMAT_MOV: number = 0x300D;
  static readonly FORMAT_MP4: number = 0xB982;
  static readonly FORMAT_PNG: number = 0x380B;
  static readonly FORMAT_TIFF: number = 0x380D;
}

/** 页面阶段。 */
export class FujifilmTransferStage {
  static readonly IDLE: string = 'idle';
  static readonly CONNECTING: string = 'connecting';
  static readonly MODE: string = 'mode';
  static readonly SLOTS: string = 'slots';
  static readonly ENUMERATING: string = 'enumerating';
  static readonly READY: string = 'ready';
  static readonly DOWNLOADING: string = 'downloading';
  static readonly ERROR: string = 'error';
}

/** 缩略图状态。 */
export class FujifilmThumbStage {
  static readonly IDLE: string = 'idle';
  static readonly QUEUED: string = 'queued';
  static readonly LOADING: string = 'loading';
  static readonly READY: string = 'ready';
  static readonly FAILED: string = 'failed';
}

export interface FujifilmStringResult {
  text: string;
  next: number;
}

export interface FujifilmFormatInfo {
  extension: string;
  mime: string;
  isVideo: boolean;
}

/** 0x9054 里方向标记的解析结果（带真机核对用的原始字节）。 */
interface FujifilmOrientationHit {
  /** 合法时是 1–8；缺失/越界时回退 1。 */
  value: number;
  /** 标记起始字节偏移；-1 表示整包没找到。 */
  marker: number;
  /** 'utf16le' / 'ascii' / 'none'。 */
  encoding: string;
  /** 标记附近的原始字节（hex）。 */
  raw: string;
  /** 找到的十进制值是否在 1–8。 */
  valid: boolean;
}

export interface FujifilmObjectInfo {
  name: string;
  format: number;
  realFormat: number;
  size: number;
  thumbSize: number;
  width: number;
  height: number;
  captureDate: string;
  dateKey: string;
  extension: string;
  mime: string;
  isVideo: boolean;
  /**
   * EXIF 方向 1–8（0x9054 私有 metadata 里 `Orientation:` 的原值）。
   *
   * 注意：这里刻意保留**EXIF 语义**，不是官方 SDK 的 1/2/3/4 枚举。
   * `RawPreviewLoader.applyOrientation` / `RecentPhotoStore.add` 要的都是
   * EXIF 值；0x9054 里相机给的正是 EXIF 值（native 自己再映射成 SDK 枚举）。
   */
  orientation: number;
  /** 调试：`Orientation:` 标记在 0x9054 数据里的字节偏移，-1=整包没找到。 */
  orientationMarker: number;
  /** 调试：标记附近的原始字节（hex），真机核对方向字段用。 */
  orientationRaw: string;
  /** 调试：找到的十进制值是否落在 1–8。 */
  orientationValid: boolean;
}

export interface FujifilmGalleryItem {
  handle: number;
  name: string;
  extension: string;
  mime: string;
  isVideo: boolean;
  size: number;
  thumbSize: number;
  width: number;
  height: number;
  captureDate: string;
  dateKey: string;
  format: number;
  realFormat: number;
  orientation: number;
  thumbUri: string;
  thumbState: string;
  selected: boolean;
  current: boolean;
}

export interface FujifilmSlotView {
  slot: number;
  label: string;
  detail: string;
  available: boolean;
  current: boolean;
  status: number;
}

export interface FujifilmStorageInfo {
  id: number;
  description: string;
  volumeLabel: string;
  freeImages: number;
}

/** 页面每次轮询拿到的只读快照；items 是浅拷贝，元素仍是服务里的活对象。 */
export interface FujifilmTransferSnapshot {
  phase: string;
  model: string;
  message: string;
  error: string;
  items: FujifilmGalleryItem[];
  slots: FujifilmSlotView[];
  activeSlot: number;
  slotStatus: number;
  slotControlSupported: boolean;
  total: number;
  selectedCount: number;
  loading: boolean;
  downloadInProgress: boolean;
  downloadProgress: number;
  downloadStatus: string;
  downloadSaved: number;
  downloadFailed: number;
  downloadRecent: number;
  downloadCurrent: number;
  downloadTotal: number;
}

/**
 * 双槽策略。
 *
 * convertCardStatus 是官方 ImportImageModel 的逐字映射（status, 目标槽 → 新 status）：
 *   1: 槽2→2；2: 槽1→1；3: 槽2→4；4: 槽1→3；
 *   5: 槽2→6 / 槽3→7；6: 槽1→5 / 槽3→7；7: 槽1→5 / 槽2→6。
 *
 * 当前槽由官方 UI 的 z3/z4/z5 反推：1/3/5→槽1，2/4/6→槽2，7→槽3。
 * 张数：1–4 为双槽，5–7 为三槽；status=0 没有槽位信息，按机型兜底。
 */
export class FujifilmSlotPolicy {
  static currentSlot(status: number): number {
    switch (status) {
      case 1:
      case 3:
      case 5:
        return 1;
      case 2:
      case 4:
      case 6:
        return 2;
      case 7:
        return 3;
      default:
        return 0;
    }
  }

  static slotCount(status: number, model: string): number {
    if (status >= 5 && status <= 7) return 3;
    if (status >= 1 && status <= 4) return 2;
    return FujifilmSlotPolicy.isSingleSlotModel(model) ? 1 : 2;
  }

  /**
   * status=0 时相机没有给槽位数。富士单卡机型集中在 X100 / X-E / X-Pro /
   * X-Txx / X-S10 等紧凑系列；其余按双槽兜底，宁可多显示一个灰按钮，
   * 也不要把双卡机的第二张卡藏起来（需求：空卡也要可见）。
   */
  static isSingleSlotModel(model: string): boolean {
    const name: string = model.toUpperCase().replace('FUJIFILM', '').trim();
    if (name.length === 0) return false;
    const prefixes: string[] = ['X100', 'X-E', 'X-T10', 'X-T20', 'X-T30',
      'X-T50', 'X-T100', 'X-T200', 'X-A', 'X-M', 'X-S10', 'X-S20', 'X70', 'XQ'];
    for (const prefix of prefixes) {
      if (name.indexOf(prefix) === 0) return true;
    }
    return false;
  }

  /** 当前 status 下可点的槽位。1–7 都有卡在位；status=0 一张也没有。 */
  static availableSlots(status: number): number[] {
    if (status >= 1 && status <= 4) return [1, 2];
    if (status >= 5 && status <= 7) return [1, 2, 3];
    return [];
  }

  /** 官方 convertCardStatus：返回 -1 表示这个目标槽不可切。 */
  static convertCardStatus(status: number, slot: number): number {
    switch (status) {
      case 1:
        return slot === 2 ? 2 : -1;
      case 2:
        return slot === 1 ? 1 : -1;
      case 3:
        return slot === 2 ? 4 : -1;
      case 4:
        return slot === 1 ? 3 : -1;
      case 5:
        if (slot === 2) return 6;
        if (slot === 3) return 7;
        return -1;
      case 6:
        if (slot === 1) return 5;
        if (slot === 3) return 7;
        return -1;
      case 7:
        if (slot === 1) return 5;
        if (slot === 2) return 6;
        return -1;
      default:
        return -1;
    }
  }
}

export class FujifilmImportService {
  private context: common.UIAbilityContext;
  private model: string = 'FUJIFILM';
  private phase: string = FujifilmTransferStage.IDLE;
  private message: string = '正在准备…';
  private error: string = '';
  private items: FujifilmGalleryItem[] = [];
  private slots: FujifilmSlotView[] = [];
  private activeSlot: number = 0;
  private slotStatus: number = 0;
  private slotControlSupported: boolean = false;
  private activeStorageId: number = 0;
  private currentHandle: number = 0;
  private total: number = 0;

  /** 页面按 revision 变化决定是否拷贝快照，避免每 250ms 全量重设 @State。 */
  public revision: number = 0;
  private epoch: number = 0;
  private disposed: boolean = false;
  private event11Seen: boolean = false;
  private event11Resolve: (() => void) | null = null;
  private eventInstalled: boolean = false;

  private selected: Set<number> = new Set<number>();
  private thumbQueue: number[] = [];
  private thumbRunning: boolean = false;
  private thumbEpoch: number = 0;
  private thumbMemory: Map<number, Uint8Array> = new Map<number, Uint8Array>();
  private thumbMemoryOrder: number[] = [];
  private downloadDir: string = '';
  private thumbDir: string = '';

  private downloadInProgress: boolean = false;
  private downloadCancelled: boolean = false;
  private downloadProgress: number = 0;
  private downloadStatus: string = '';
  private downloadSaved: number = 0;
  private downloadFailed: number = 0;
  private downloadKept: number = 0;
  private downloadRecent: number = 0;
  private downloadCurrent: number = 0;
  private downloadTotal: number = 0;
  /** 方向诊断日志最多打 5 条：既够真机核对，又不会让没带 metadata 的机型刷屏。 */
  private orientationDiagnostics: number = 0;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.model = CameraSessionStore.instance.cameraModel.trim();
    if (this.model.length === 0) this.model = 'FUJIFILM';
    this.downloadDir = `${context.filesDir}/${DIRECTORY_NAME}`;
    this.thumbDir = `${this.downloadDir}/${THUMB_DIRECTORY}`;
    this.ensureDir(this.downloadDir);
    this.ensureDir(this.thumbDir);
    this.installEventListener();
  }

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  async open(): Promise<void> {
    if (this.busy()) return;
    const epoch: number = ++this.epoch;
    this.error = '';
    this.setPhase(FujifilmTransferStage.CONNECTING, '正在连接相机…');
    this.log(`open model=${this.model}`);
    try {
      this.installEventListener();
      await FujifilmPtpIp.connect();
      if (epoch !== this.epoch || this.disposed) return;
      const gotEvent: boolean = await this.waitEvent11(EVENT11_WAIT_MS);
      this.log(`event11=${gotEvent ? 1 : 0}`);
      if (epoch !== this.epoch || this.disposed) return;

      this.setPhase(FujifilmTransferStage.MODE, '正在切换到图片浏览模式…');
      const modeOk: boolean = await this.setFunctionMode(FujifilmMode.IMAGE_VIEW_V2);
      if (!modeOk) {
        this.log('SetFunctionMode(20) 失败，退回标准 OpenSession 枚举');
        await this.openSessionFallback();
      } else {
        await this.negotiateImageViewVersion();
      }
      if (epoch !== this.epoch || this.disposed) return;

      this.setPhase(FujifilmTransferStage.SLOTS, '正在读取存储卡…');
      await this.readSlots();
      if (epoch !== this.epoch || this.disposed) return;
      await this.enumerateCurrentSlot(epoch);
    } catch (error) {
      if (epoch === this.epoch && !this.disposed) this.fail(`连接相机失败：${String(error)}`);
    }
  }

  /** 页面离开：取消队列、关闭 PTP；不 clearEventListeners（会误伤 A/D 的监听）。 */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.epoch += 1;
    this.downloadCancelled = true;
    this.thumbEpoch += 1;
    this.thumbQueue = [];
    this.thumbMemory.clear();
    this.thumbMemoryOrder = [];
    FujifilmPtpIp.close().catch((error: Object): void => {
      this.log(`close error=${String(error)}`);
    });
    this.log('dispose');
  }

  async resetAndRetry(): Promise<void> {
    if (this.disposed) return;
    this.error = '';
    this.phase = FujifilmTransferStage.IDLE;
    this.items = [];
    this.selected.clear();
    this.total = 0;
    this.thumbEpoch += 1;
    this.thumbQueue = [];
    this.revision += 1;
    try {
      await FujifilmPtpIp.close();
    } catch (error) {
      this.log(`retry close error=${String(error)}`);
    }
    this.event11Seen = false;
    await this.open();
  }

  private busy(): boolean {
    return this.phase === FujifilmTransferStage.CONNECTING ||
      this.phase === FujifilmTransferStage.MODE ||
      this.phase === FujifilmTransferStage.SLOTS ||
      this.phase === FujifilmTransferStage.ENUMERATING ||
      this.downloadInProgress;
  }

  // -------------------------------------------------------------------------
  // 会话准备
  // -------------------------------------------------------------------------

  private installEventListener(): void {
    if (this.eventInstalled) return;
    this.eventInstalled = true;
    FujifilmPtpIp.onEvent((frame: FujifilmEventFrame): void => {
      if (this.disposed) return;
      if (frame.code === FujifilmEvent.GET_CAMERA_MODE) {
        this.event11Seen = true;
        const waiter: (() => void) | null = this.event11Resolve;
        this.event11Resolve = null;
        if (waiter !== null) waiter();
        return;
      }
      // 官方事件 7 = 相机主动断开；只提示，具体重连交给连接页。
      if (frame.code === 7) {
        this.error = '相机连接已断开';
        this.phase = FujifilmTransferStage.ERROR;
        this.message = '相机连接已断开';
        this.revision += 1;
        this.log('event7 camera disconnected');
      }
    });
  }

  private waitEvent11(timeoutMs: number): Promise<boolean> {
    if (this.event11Seen) return Promise.resolve(true);
    return new Promise<boolean>((resolve) => {
      let finished: boolean = false;
      const finish = (value: boolean): void => {
        if (finished) return;
        finished = true;
        resolve(value);
      };
      this.event11Resolve = (): void => {
        finish(true);
      };
      setTimeout((): void => {
        this.event11Resolve = null;
        finish(false);
      }, timeoutMs);
    });
  }

  /**
   * SDK_SetFunctionMode → SetDevicePropValue(0xDF01, UINT16 mode)。
   * 逆向证据：libFFIR.so 0x5ed28 的 CCameraParamForSetInt 立即数
   * 0x4078/0xDF01/4；0x5002 是标准 PTP 的 FunctionMode，富士图片浏览不走它。
   */
  private async setFunctionMode(mode: number): Promise<boolean> {
    for (let attempt: number = 1; attempt <= MODE_RETRY_COUNT; attempt++) {
      try {
        const reply: FujifilmReply = await FujifilmPtpIp.opDataOut(
          FujifilmOp.SET_DEVICE_PROP_VALUE,
          [FujifilmTransferCode.PROP_FUNCTION_MODE],
          FujifilmBytes.u16(mode), FujifilmNet.TRANSACTION_TIMEOUT_MS);
        this.log(`SetFunctionMode(${mode}) #${attempt} code=${FujifilmBytes.hex(reply.code)}`);
        if (reply.code === FujifilmResponse.OK) return true;
        if (!this.isRetryable(reply.code)) return false;
      } catch (error) {
        this.log(`SetFunctionMode #${attempt} error=${String(error)}`);
      }
      await this.delay(RETRY_INTERVAL_MS);
    }
    return false;
  }

  /** 兜底：标准 OpenSession(1)。A 的 connect 已带，这里再发一次只用于降级链路。 */
  private async openSessionFallback(): Promise<void> {
    try {
      const reply: FujifilmReply = await FujifilmPtpIp.op(
        FujifilmOp.OPEN_SESSION, [1], FujifilmNet.TRANSACTION_TIMEOUT_MS);
      this.log(`OpenSession fallback code=${FujifilmBytes.hex(reply.code)}`);
    } catch (error) {
      this.log(`OpenSession fallback error=${String(error)}`);
    }
  }

  /**
   * GetFunctionVersion(0xDF28) → GetDevicePropValue UINT32；
   * 相机版本 > App 的 3 时官方直接 VersionError，这里只跳过 SetFunctionVersion，
   * 继续读卡（枚举本身可能仍然可用）。
   */
  private async negotiateImageViewVersion(): Promise<void> {
    const cameraVersion: number = await this.readPropU32(FujifilmMode.VERSION_IMAGE_VIEW);
    this.log(`GetFunctionVersion(0xDF28)=${cameraVersion}`);
    if (cameraVersion <= 0) {
      this.log('版本属性读不到，跳过 SetFunctionVersion');
      return;
    }
    if (cameraVersion > APP_IMAGE_VIEW_VERSION) {
      this.log(`相机版本 ${cameraVersion} > App 支持 ${APP_IMAGE_VIEW_VERSION}，跳过 SetFunctionVersion`);
      return;
    }
    for (let attempt: number = 1; attempt <= MODE_RETRY_COUNT; attempt++) {
      try {
        const reply: FujifilmReply = await FujifilmPtpIp.opDataOut(
          FujifilmOp.SET_DEVICE_PROP_VALUE,
          [FujifilmMode.VERSION_IMAGE_VIEW],
          FujifilmBytes.u32(cameraVersion), FujifilmNet.TRANSACTION_TIMEOUT_MS);
        this.log(`SetFunctionVersion(0xDF28, ${cameraVersion}) #${attempt} ` +
          `code=${FujifilmBytes.hex(reply.code)}`);
        if (reply.code === FujifilmResponse.OK) return;
        if (!this.isRetryable(reply.code)) return;
      } catch (error) {
        this.log(`SetFunctionVersion #${attempt} error=${String(error)}`);
      }
      await this.delay(RETRY_INTERVAL_MS);
    }
  }

  private async readPropU32(prop: number): Promise<number> {
    try {
      const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
        FujifilmOp.GET_DEVICE_PROP_VALUE, [prop], FujifilmNet.TRANSACTION_TIMEOUT_MS);
      if (reply.code !== FujifilmResponse.OK) {
        this.log(`GetDevicePropValue(${FujifilmBytes.hex(prop)}) ` +
          `code=${FujifilmBytes.hex(reply.code)}`);
        return -1;
      }
      if (reply.data.length >= 4) return FujifilmBytes.readU32(reply.data, 0);
      if (reply.data.length === 2) return FujifilmBytes.readU16(reply.data, 0);
      if (reply.data.length === 1) return reply.data[0];
      return -1;
    } catch (error) {
      this.log(`GetDevicePropValue(${FujifilmBytes.hex(prop)}) error=${String(error)}`);
      return -1;
    }
  }

  // -------------------------------------------------------------------------
  // 存储卡 / 双槽
  // -------------------------------------------------------------------------

  private async readSlots(): Promise<void> {
    const status: number = await this.readDualSlotStatus();
    const storages: FujifilmStorageInfo[] = await this.readStorages();
    if (status >= 0 && status <= 7) {
      this.slotStatus = status;
      this.slotControlSupported = true;
      this.activeSlot = FujifilmSlotPolicy.currentSlot(status);
      this.buildSlotsFromStatus(status, storages);
      this.log(`dualSlotStatus=${status} active=${this.activeSlot} ` +
        `count=${this.slots.length} storages=${storages.length}`);
      return;
    }

    // 0xD244 读不到（老机型 / 模式没切成功）：按标准存储介质枚举。
    this.slotControlSupported = false;
    this.slotStatus = 0;
    this.activeSlot = storages.length > 0 ? 1 : 0;
    this.activeStorageId = storages.length > 0 ? storages[0].id : 0;
    this.buildSlotsFromStorages(storages);
    this.log(`dualSlotStatus unavailable, fallback storages=${storages.length} ` +
      `storageId=${FujifilmBytes.hex(this.activeStorageId, 8)}`);
  }

  private async readDualSlotStatus(): Promise<number> {
    try {
      const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
        FujifilmOp.GET_DEVICE_PROP_VALUE,
        [FujifilmTransferCode.PROP_DUAL_SLOT_STATUS], FujifilmNet.TRANSACTION_TIMEOUT_MS);
      this.log(`GetDualSlotStatus code=${FujifilmBytes.hex(reply.code)} ` +
        `data=${FujifilmBytes.hexBytes(reply.data, 8)}`);
      if (reply.code !== FujifilmResponse.OK || reply.data.length === 0) return -1;
      const status: number = reply.data[0] & 0xFF;
      return status <= 7 ? status : -1;
    } catch (error) {
      this.log(`GetDualSlotStatus error=${String(error)}`);
      return -1;
    }
  }

  private buildSlotsFromStatus(status: number, storages: FujifilmStorageInfo[]): void {
    const count: number = FujifilmSlotPolicy.slotCount(status, this.model);
    const available: number[] = FujifilmSlotPolicy.availableSlots(status);
    const current: number = FujifilmSlotPolicy.currentSlot(status);
    const list: FujifilmSlotView[] = [];
    for (let slot: number = 1; slot <= count; slot++) {
      let detail: string = '';
      if (slot - 1 < storages.length) {
        detail = storages[slot - 1].description;
        if (detail.length === 0) detail = storages[slot - 1].volumeLabel;
      }
      list.push({
        slot: slot,
        label: `SD${slot}`,
        detail: detail,
        available: available.indexOf(slot) >= 0,
        current: slot === current,
        status: status,
      });
    }
    this.slots = list;
    if (current > 0 && current - 1 < storages.length) {
      this.activeStorageId = storages[current - 1].id;
    }
  }

  private buildSlotsFromStorages(storages: FujifilmStorageInfo[]): void {
    if (storages.length === 0) {
      this.buildSlotsFromStatus(0, storages);
      return;
    }
    const list: FujifilmSlotView[] = [];
    for (let index: number = 0; index < storages.length; index++) {
      const storage: FujifilmStorageInfo = storages[index];
      let detail: string = storage.description;
      if (detail.length === 0) detail = storage.volumeLabel;
      list.push({
        slot: index + 1,
        label: `卡${index + 1}`,
        detail: detail,
        available: true,
        current: index === 0,
        status: 0,
      });
    }
    this.slots = list;
  }

  /** 标准 0x1004 + 0x1005；富士可能不支持，失败只当没有附加信息。 */
  private async readStorages(): Promise<FujifilmStorageInfo[]> {
    const list: FujifilmStorageInfo[] = [];
    try {
      const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
        FujifilmOp.GET_STORAGE_IDS, [], FujifilmNet.TRANSACTION_TIMEOUT_MS);
      if (reply.code !== FujifilmResponse.OK || reply.data.length < 4) return list;
      const count: number = Math.min(FujifilmBytes.readU32(reply.data, 0), 8,
        Math.floor((reply.data.length - 4) / 4));
      this.log(`GetStorageIDs code=${FujifilmBytes.hex(reply.code)} count=${count}`);
      for (let index: number = 0; index < count; index++) {
        const id: number = FujifilmBytes.readU32(reply.data, 4 + index * 4);
        list.push(await this.readStorageInfo(id));
      }
    } catch (error) {
      this.log(`readStorages error=${String(error)}`);
    }
    return list;
  }

  private async readStorageInfo(id: number): Promise<FujifilmStorageInfo> {
    const info: FujifilmStorageInfo = {
      id: id,
      description: '',
      volumeLabel: '',
      freeImages: 0,
    };
    try {
      const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
        FujifilmOp.GET_STORAGE_INFO, [id], FujifilmNet.TRANSACTION_TIMEOUT_MS);
      if (reply.code !== FujifilmResponse.OK || reply.data.length < 26) return info;
      info.freeImages = FujifilmBytes.readU32(reply.data, 22);
      const description: FujifilmStringResult =
        FujifilmImportService.decodeUtf16(reply.data, 26, 64);
      info.description = description.text;
      const volume: FujifilmStringResult =
        FujifilmImportService.decodeUtf16(reply.data, description.next, 64);
      info.volumeLabel = volume.text;
      this.log(`GetStorageInfo id=${FujifilmBytes.hex(id, 8)} desc=${info.description} ` +
        `volume=${info.volumeLabel} free=${info.freeImages}`);
    } catch (error) {
      this.log(`GetStorageInfo(${FujifilmBytes.hex(id, 8)}) error=${String(error)}`);
    }
    return info;
  }

  /**
   * 切槽：先清空列表与加载态，再 SetDualSlotStatus，最后重新枚举。
   * convertCardStatus 来自官方 ImportImageModel；-1 表示不可切。
   */
  async switchSlot(slot: number): Promise<void> {
    if (this.busy() || this.disposed) return;
    if (slot === this.activeSlot) return;
    if (!this.slotControlSupported) {
      this.error = '该机型不支持在 App 内切换卡槽';
      this.revision += 1;
      return;
    }
    const targetStatus: number = FujifilmSlotPolicy.convertCardStatus(this.slotStatus, slot);
    if (targetStatus < 0) {
      this.log(`switchSlot(${slot}) 不可切 status=${this.slotStatus}`);
      return;
    }
    const epoch: number = ++this.epoch;
    this.error = '';
    this.items = [];
    this.selected.clear();
    this.total = 0;
    this.thumbEpoch += 1;
    this.thumbQueue = [];
    this.thumbMemory.clear();
    this.thumbMemoryOrder = [];
    this.setPhase(FujifilmTransferStage.SLOTS, `正在切换到 SD${slot}…`);
    this.log(`switchSlot slot=${slot} status=${this.slotStatus}→${targetStatus}`);
    try {
      const ok: boolean = await this.writeDualSlotStatus(targetStatus);
      if (epoch !== this.epoch || this.disposed) return;
      if (!ok) {
        this.fail(`切换到 SD${slot} 失败`);
        return;
      }
      this.slotStatus = targetStatus;
      this.activeSlot = slot;
      this.buildSlotsFromStatus(targetStatus, await this.readStorages());
      this.revision += 1;
      await this.enumerateCurrentSlot(epoch);
    } catch (error) {
      if (epoch === this.epoch && !this.disposed) this.fail(`切换卡槽失败：${String(error)}`);
    }
  }

  private async writeDualSlotStatus(status: number): Promise<boolean> {
    for (let attempt: number = 1; attempt <= MODE_RETRY_COUNT; attempt++) {
      try {
        const data: Uint8Array = new Uint8Array(1);
        data[0] = status & 0xFF;
        const reply: FujifilmReply = await FujifilmPtpIp.opDataOut(
          FujifilmOp.SET_DEVICE_PROP_VALUE,
          [FujifilmTransferCode.PROP_DUAL_SLOT_STATUS],
          data, FujifilmNet.TRANSACTION_TIMEOUT_MS);
        this.log(`SetDualSlotStatus(${status}) #${attempt} code=${FujifilmBytes.hex(reply.code)}`);
        if (reply.code === FujifilmResponse.OK) return true;
        if (!this.isRetryable(reply.code)) return false;
      } catch (error) {
        this.log(`SetDualSlotStatus #${attempt} error=${String(error)}`);
      }
      await this.delay(RETRY_INTERVAL_MS);
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // 枚举
  // -------------------------------------------------------------------------

  private async enumerateCurrentSlot(epoch: number): Promise<void> {
    this.items = [];
    this.total = 0;
    this.selected.clear();
    this.currentHandle = 0;
    const slotName: string = this.activeSlot > 0 ? `SD${this.activeSlot}` : '相机';
    this.setPhase(FujifilmTransferStage.ENUMERATING, `正在读取 ${slotName} 图库…`);
    if (epoch !== this.epoch || this.disposed) return;

    if (this.slotControlSupported && this.activeSlot > 0) {
      const active: FujifilmSlotView | null = this.findSlot(this.activeSlot);
      if (active !== null && !active.available) {
        this.setPhase(FujifilmTransferStage.READY, `${slotName} 没有存储卡`);
        this.log(`${slotName} unavailable, skip enumeration`);
        return;
      }
    }

    try {
      this.currentHandle = await this.readPropU32(FujifilmTransferCode.PROP_CURRENT_OBJECT_HANDLE);
      if (epoch !== this.epoch) return;
      this.total = await this.readObjectCount();
      if (epoch !== this.epoch) return;
      await this.logDateGroups();
      if (epoch !== this.epoch) return;

      const handles: number[] = await this.readHandles(this.total);
      if (epoch !== this.epoch) return;
      this.log(`handles=${handles.length} count=${this.total} ` +
        `first=${handles.length > 0 ? FujifilmBytes.hex(handles[0], 8) : '-'}`);
      if (handles.length === 0) {
        this.setPhase(FujifilmTransferStage.READY, `${slotName} 没有照片`);
        return;
      }

      const parsed: FujifilmGalleryItem[] = [];
      let infoFailures: number = 0;
      let orientedCount: number = 0;
      let orientationUnknown: number = 0;
      for (let index: number = 0; index < handles.length; index++) {
        if (epoch !== this.epoch || this.disposed) return;
        const handle: number = handles[index];
        let info: FujifilmObjectInfo;
        try {
          info = await this.readObjectInfo(handle);
        } catch (error) {
          infoFailures += 1;
          info = FujifilmImportService.fallbackInfo(handle);
          this.log(`objectInfo fail handle=${FujifilmBytes.hex(handle, 8)} ${String(error)}`);
        }
        if (info.format === FORMAT_ASSOCIATION) continue;
        if (info.orientation > 1) orientedCount += 1;
        if (!info.orientationValid) orientationUnknown += 1;
        parsed.push(this.toGalleryItem(handle, info));
        if (index % 20 === 0) {
          this.setPhase(FujifilmTransferStage.ENUMERATING,
            `正在读取对象信息 ${index + 1}/${handles.length}…`);
          await this.delay(0);
        }
      }
      if (epoch !== this.epoch || this.disposed) return;
      this.items = parsed;
      this.total = parsed.length;
      const suffix: string = infoFailures > 0 ? `，${infoFailures} 项信息读取失败` : '';
      this.setPhase(FujifilmTransferStage.READY,
        parsed.length > 0 ? `已加载 ${parsed.length} 项${suffix}` : `${slotName} 没有照片`);
      this.log(`enumerated=${parsed.length} failures=${infoFailures} ` +
        `orientation>1=${orientedCount} orientationMissing=${orientationUnknown}`);
      this.ensureThumbnailWindow(0, 30);
    } catch (error) {
      if (epoch === this.epoch && !this.disposed) {
        this.fail(`读取图库失败：${String(error)}`);
      }
    }
  }

  private async readObjectCount(): Promise<number> {
    const count: number = await this.readPropU32(FujifilmTransferCode.PROP_SPECIFIED_OBJECT_COUNT);
    if (count >= 0) {
      this.log(`specifiedObjectCount=${count}`);
      return count;
    }
    try {
      const storage: number = this.resolveStorageId();
      const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
        FujifilmOp.GET_NUM_OBJECTS, [storage, 0, 0], FujifilmNet.TRANSACTION_TIMEOUT_MS);
      if (reply.code === FujifilmResponse.OK && reply.data.length >= 4) {
        return FujifilmBytes.readU32(reply.data, 0);
      }
    } catch (error) {
      this.log(`GetNumObjects error=${String(error)}`);
    }
    return 0;
  }

  /**
   * 0x9053 日期分组张数：官方固定 offset=0、count=30000，一次取全。
   * 页面按相机顺序直出，不需要分组；这里只做协议对齐与诊断，响应布局
   * 未完全解码（NOTES_C §8【未知】），因此不参与任何 UI 判断。
   */
  private async logDateGroups(): Promise<void> {
    try {
      const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
        FujifilmTransferCode.OP_COUNT_GROUP_BY_DATE, [0, FujifilmNet.OBJECT_COUNT_LIMIT],
        FujifilmNet.TRANSACTION_TIMEOUT_MS);
      this.log(`GetSpecifiedObjectCountGroupByDate code=${FujifilmBytes.hex(reply.code)} ` +
        `bytes=${reply.data.length} head=${FujifilmBytes.hexBytes(reply.data, 24)}`);
    } catch (error) {
      this.log(`GetSpecifiedObjectCountGroupByDate error=${String(error)}`);
    }
  }

  private async readHandles(expected: number): Promise<number[]> {
    try {
      const timeout: number = this.handleTimeout(expected);
      const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
        FujifilmOp.GET_DEVICE_PROP_VALUE,
        [FujifilmTransferCode.PROP_SPECIFIED_OBJECT_HANDLES], timeout);
      if (reply.code === FujifilmResponse.OK && reply.data.length > 0) {
        const handles: number[] = FujifilmImportService.parseHandleArray(reply.data, expected);
        this.log(`GetSpecifiedObjectHandles bytes=${reply.data.length} parsed=${handles.length}`);
        if (handles.length > 0) return handles;
      } else {
        this.log(`GetSpecifiedObjectHandles code=${FujifilmBytes.hex(reply.code)} ` +
          `bytes=${reply.data.length}`);
      }
    } catch (error) {
      this.log(`GetSpecifiedObjectHandles error=${String(error)}`);
    }

    try {
      const storage: number = this.resolveStorageId();
      const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
        FujifilmOp.GET_OBJECT_HANDLES, [storage, 0, 0], this.handleTimeout(expected));
      if (reply.code === FujifilmResponse.OK && reply.data.length >= 4) {
        const handles: number[] = FujifilmImportService.parseStandardArray(reply.data);
        this.log(`GetObjectHandles fallback bytes=${reply.data.length} parsed=${handles.length}`);
        return handles;
      }
    } catch (error) {
      this.log(`GetObjectHandles fallback error=${String(error)}`);
    }
    throw new Error('读取对象句柄失败');
  }

  /**
   * 句柄数组两种布局都兼容：
   *   - 裸数组 expected × u32；
   *   - u32 count + count × u32（标准 PTP / 设备属性数组）。
   * 不做排序，严格保持相机顺序（handles[0] 最新）。
   */
  private static parseHandleArray(data: Uint8Array, expected: number): number[] {
    const words: number = Math.floor(data.length / 4);
    if (words <= 0) return [];
    const first: number = FujifilmBytes.readU32(data, 0);
    let count: number = words;
    let offset: number = 0;
    if (expected > 0 && words === expected) {
      count = expected;
      offset = 0;
    } else if (expected > 0 && words === expected + 1 && first === expected) {
      count = expected;
      offset = 4;
    } else if (first > 0 && first + 1 === words) {
      count = first;
      offset = 4;
    } else if (first > 0 && first <= words && first * 4 + 4 === data.length) {
      count = first;
      offset = 4;
    }
    const out: number[] = [];
    const max: number = Math.min(count, Math.floor((data.length - offset) / 4),
      FujifilmNet.OBJECT_COUNT_LIMIT * 4);
    for (let index: number = 0; index < max; index++) {
      const handle: number = FujifilmBytes.readU32(data, offset + index * 4);
      if (handle > 0) out.push(handle);
    }
    return out;
  }

  private static parseStandardArray(data: Uint8Array): number[] {
    if (data.length < 4) return [];
    const count: number = Math.min(FujifilmBytes.readU32(data, 0),
      Math.floor((data.length - 4) / 4), 100000);
    const out: number[] = [];
    for (let index: number = 0; index < count; index++) {
      out.push(FujifilmBytes.readU32(data, 4 + index * 4));
    }
    return out;
  }

  private async readObjectInfo(handle: number): Promise<FujifilmObjectInfo> {
    let reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
      FujifilmOp.GET_EXTENSION_OBJECT_INFO, [handle], FujifilmNet.TRANSACTION_TIMEOUT_MS);
    if (reply.code !== FujifilmResponse.OK || reply.data.length < 52) {
      this.log(`GetExtensionObjectInfo(${FujifilmBytes.hex(handle, 8)}) ` +
        `code=${FujifilmBytes.hex(reply.code)} bytes=${reply.data.length}，试标准 0x1008`);
      reply = await FujifilmPtpIp.opDataIn(
        FujifilmOp.GET_OBJECT_INFO, [handle], FujifilmNet.TRANSACTION_TIMEOUT_MS);
    }
    if (reply.code !== FujifilmResponse.OK || reply.data.length < 48) {
      throw new Error(`ObjectInfo code=${FujifilmBytes.hex(reply.code)} bytes=${reply.data.length}`);
    }
    const info: FujifilmObjectInfo = FujifilmImportService.parseObjectInfo(reply.data);
    // 只在“非正面”或“没解析到”时打点，最多 5 条，避免几千张图把 AppLogStore 刷满。
    if ((!info.orientationValid || info.orientationMarker < 0 || info.orientation > 1)
      && this.orientationDiagnostics < 5) {
      this.orientationDiagnostics += 1;
      this.log(`objectinfo handle=${FujifilmBytes.hex(handle, 8)} ` +
        `bytes=${reply.data.length} orientation=${info.orientation} ` +
        `marker=${info.orientationMarker} valid=${info.orientationValid ? 1 : 0} ` +
        `raw=${info.orientationRaw}`);
    }
    return info;
  }

  /**
   * 富士 ObjectInfo = 标准 PTP ObjectInfo + u32 realFileFormat（偏移 48）。
   * 文件名因此从 52 开始（UTF-16LE，NUL 结尾），随后依次是拍摄时间、
   * 修改时间、关键词。兼容性：标准包文件名在 48，因此 48/52 都试。
   *
   * 方向：0x9054 的方向不在固定表头里，而是第 4 个 PTP 字符串中的
   * `Orientation:<EXIF 1–8>` 文本；这里按标记扫描，缺失/越界回退 1。
   */
  private static parseObjectInfo(data: Uint8Array): FujifilmObjectInfo {
    const format: number = FujifilmBytes.readU16(data, 4);
    const size: number = FujifilmBytes.readU32(data, 8);
    const thumbSize: number = FujifilmBytes.readU32(data, 14);
    const width: number = FujifilmBytes.readU32(data, 26);
    const height: number = FujifilmBytes.readU32(data, 30);
    let realFormat: number = FujifilmBytes.readU32(data, 48);
    if (realFormat === 0 || realFormat > 0xFFFFF) realFormat = format;
    const orientation: FujifilmOrientationHit =
      FujifilmImportService.parseOrientation(data);

    // 标准 0x1008 的文件名在 48；富士 0x9054 多一个 u32 realFileFormat，
    // 文件名后移到 52。先试 48：标准包能直接命中；富士包 48 处是
    // realFileFormat 的低字节（控制字符），会被 isPlausibleName 拒掉。
    let name: string = '';
    let nameOffset: number = 48;
    const candidates: number[] = [48, 52, 44];
    for (const candidate of candidates) {
      const decoded: FujifilmStringResult =
        FujifilmImportService.decodeUtf16(data, candidate, 240);
      if (FujifilmImportService.isPlausibleName(decoded.text)) {
        name = decoded.text;
        nameOffset = candidate;
        break;
      }
    }
    if (name.length === 0) {
      name = FujifilmImportService.decodeUtf16(data, 52, 240).text;
    }

    let captureDate: string = '';
    const dateStart: number = nameOffset + (name.length + 1) * 2;
    for (let at: number = dateStart;
      at + 4 < data.length && at < dateStart + 600; at += 2) {
      const value: string = FujifilmImportService.decodeUtf16(data, at, 48).text;
      if (FujifilmImportService.looksLikeDate(value)) {
        captureDate = value;
        break;
      }
    }

    const info: FujifilmFormatInfo =
      FujifilmImportService.formatInfo(realFormat, format, name);
    return {
      name: name,
      format: format,
      realFormat: realFormat,
      size: size,
      thumbSize: thumbSize,
      width: width,
      height: height,
      captureDate: captureDate,
      dateKey: FujifilmImportService.dateKey(captureDate),
      extension: info.extension,
      mime: info.mime,
      isVideo: info.isVideo,
      orientation: orientation.value,
      orientationMarker: orientation.marker,
      orientationRaw: orientation.raw,
      orientationValid: orientation.valid,
    };
  }

  /**
   * 从 0x9054 数据里解析 EXIF 方向（1–8）。
   *
   * 逆向依据（NOTES_F §2）：
   *   - native `FTL_PTP_CommonGetObjectInfo` 把第 4 个 PTP 字符串拷到
   *     `_FTL_PTP_OBJECT_INFO+820`（`N:libFTLTPTPIP.so 0x2c470`）；
   *   - `FFIR::CCameraCommandReadImage::ExecCommonReadImageInfo` 在
   *     `+820` 字符串里找 "Orientation:" 后 `atoi`（`N:libFFIR.so 0x74cc8`）；
   *     `Rating:` / `Option:` 同法；
   *   - 值 3–8 再经 `N:libFFIR.so 0x48900` 的 6 项表映射成 SDK 的
   *     1/2/3/4（0°/90°/180°/270°），证明输入是 **EXIF 1–8**，不是自定义枚举。
   *
   * 因此不硬编码偏移：整包里同时找 UTF-16LE 与 ASCII 两种写法。这样对
   * “文件名 52 是否带 PTP 长度前缀”这个尚未在真机确认的分歧不敏感。
   */
  private static parseOrientation(data: Uint8Array): FujifilmOrientationHit {
    const utf16: Uint8Array = FujifilmImportService.markerBytes(true);
    let marker: number = FujifilmImportService.indexOfBytes(data, utf16, 0);
    let encoding: string = 'utf16le';
    let markerLength: number = utf16.length;
    if (marker < 0) {
      const ascii: Uint8Array = FujifilmImportService.markerBytes(false);
      marker = FujifilmImportService.indexOfBytes(data, ascii, 0);
      encoding = 'ascii';
      markerLength = ascii.length;
    }
    if (marker < 0) {
      // 整包没有方向键：回退 1，并把尾部原始字节写进日志便于真机核对。
      return {
        value: 1,
        marker: -1,
        encoding: 'none',
        raw: FujifilmImportService.hexTail(data, 48),
        valid: false,
      };
    }

    // 标记之后是十进制文本；UTF-16LE 的数字高位字节是 0x00，跳过。
    // 允许 "Orientation:6" / "Orientation: 6" / "Orientation:\t6"。
    let digits: string = '';
    const end: number = Math.min(data.length, marker + markerLength + 16);
    for (let at: number = marker + markerLength; at < end; at++) {
      const byte: number = data[at];
      if (byte === 0x00) continue;
      if (byte === 0x20 || byte === 0x09) {
        if (digits.length > 0) break;
        continue;
      }
      if (byte >= 0x30 && byte <= 0x39) {
        digits += String.fromCharCode(byte);
        continue;
      }
      break;
    }
    const parsed: number = digits.length > 0 ? Number.parseInt(digits, 10) : 0;
    const valid: boolean = parsed >= 1 && parsed <= 8;
    return {
      value: valid ? parsed : 1,
      marker: marker,
      encoding: encoding,
      raw: FujifilmImportService.hexRange(data, marker, 48),
      valid: valid,
    };
  }

  /** `Orientation:` 的 UTF-16LE / ASCII 字节序列。 */
  private static markerBytes(utf16: boolean): Uint8Array {
    const out: Uint8Array = new Uint8Array(utf16 ? ORIENTATION_KEY.length * 2
      : ORIENTATION_KEY.length);
    for (let index: number = 0; index < ORIENTATION_KEY.length; index++) {
      const code: number = ORIENTATION_KEY.charCodeAt(index);
      if (utf16) {
        out[index * 2] = code & 0xFF;
        out[index * 2 + 1] = (code >>> 8) & 0xFF;
      } else {
        out[index] = code & 0xFF;
      }
    }
    return out;
  }

  /** 字节序列查找（ArkTS 的 Uint8Array 没有 indexOf，自己走一遍）。 */
  private static indexOfBytes(data: Uint8Array, pattern: Uint8Array, from: number): number {
    if (pattern.length === 0 || data.length < pattern.length) return -1;
    const last: number = data.length - pattern.length;
    for (let at: number = Math.max(0, from); at <= last; at++) {
      let matched: boolean = true;
      for (let index: number = 0; index < pattern.length; index++) {
        if (data[at + index] !== pattern[index]) {
          matched = false;
          break;
        }
      }
      if (matched) return at;
    }
    return -1;
  }

  private static hexRange(data: Uint8Array, at: number, length: number): string {
    const start: number = Math.max(0, at);
    return FujifilmBytes.hexBytes(data.subarray(start, Math.min(data.length, start + length)),
      length);
  }

  private static hexTail(data: Uint8Array, length: number): string {
    const start: number = Math.max(0, data.length - length);
    return FujifilmBytes.hexBytes(data.subarray(start), length);
  }

  private static fallbackInfo(handle: number): FujifilmObjectInfo {
    let hex: string = handle.toString(16).toUpperCase();
    while (hex.length < 8) hex = '0' + hex;
    return {
      name: `FUJI_${hex}.JPG`,
      format: 0,
      realFormat: 0,
      size: 0,
      thumbSize: 0,
      width: 0,
      height: 0,
      captureDate: '',
      dateKey: '',
      extension: 'jpg',
      mime: 'image/jpeg',
      isVideo: false,
      orientation: 1,
      orientationMarker: -1,
      orientationRaw: '',
      orientationValid: false,
    };
  }

  private toGalleryItem(handle: number, info: FujifilmObjectInfo): FujifilmGalleryItem {
    const name: string = info.name.length > 0
      ? info.name : FujifilmImportService.fallbackInfo(handle).name;
    return {
      handle: handle,
      name: name,
      extension: info.extension,
      mime: info.mime,
      isVideo: info.isVideo,
      size: info.size,
      thumbSize: info.thumbSize,
      width: info.width,
      height: info.height,
      captureDate: info.captureDate,
      dateKey: info.dateKey,
      format: info.format,
      realFormat: info.realFormat,
      orientation: info.orientation,
      thumbUri: '',
      thumbState: FujifilmThumbStage.IDLE,
      selected: false,
      current: handle === this.currentHandle,
    };
  }

  private static formatInfo(realFormat: number, format: number, name: string): FujifilmFormatInfo {
    let extension: string = 'jpg';
    let mime: string = 'image/jpeg';
    let isVideo: boolean = false;
    const code: number = realFormat > 0 ? realFormat : format;
    switch (code) {
      case FujifilmTransferCode.FORMAT_EXIF_JPEG:
      case FujifilmTransferCode.FORMAT_JFIF:
        extension = 'jpg';
        mime = 'image/jpeg';
        break;
      case FujifilmTransferCode.FORMAT_HEIF:
        extension = 'heic';
        mime = 'image/heic';
        break;
      case FujifilmTransferCode.FORMAT_RAF:
        extension = 'raf';
        mime = 'image/x-fuji-raf';
        break;
      case FujifilmTransferCode.FORMAT_MOV:
        extension = 'mov';
        mime = 'video/quicktime';
        isVideo = true;
        break;
      case FujifilmTransferCode.FORMAT_MP4:
        extension = 'mp4';
        mime = 'video/mp4';
        isVideo = true;
        break;
      case FujifilmTransferCode.FORMAT_PNG:
        extension = 'png';
        mime = 'image/png';
        break;
      case FujifilmTransferCode.FORMAT_TIFF:
        extension = 'tif';
        mime = 'image/tiff';
        break;
      default:
        break;
    }
    // 文件名后缀优先：机内文件名是用户看到的真实格式，ObjectFormat 只做兜底。
    const dot: number = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1) {
      const ext: string = name.substring(dot + 1).toLowerCase();
      const known: string[] = ['jpg', 'jpeg', 'png', 'heic', 'heif', 'raf', 'tif',
        'tiff', 'mov', 'mp4', 'm4v'];
      if (known.indexOf(ext) >= 0) {
        extension = ext === 'jpeg' ? 'jpg' : ext;
        isVideo = ext === 'mov' || ext === 'mp4' || ext === 'm4v';
        if (ext === 'mov') {
          mime = 'video/quicktime';
        } else if (ext === 'mp4' || ext === 'm4v') {
          mime = 'video/mp4';
        } else if (ext === 'heic' || ext === 'heif') {
          mime = 'image/heic';
        } else if (ext === 'raf') {
          mime = 'image/x-fuji-raf';
        } else if (ext === 'png') {
          mime = 'image/png';
        } else if (ext === 'tif' || ext === 'tiff') {
          mime = 'image/tiff';
        } else {
          mime = 'image/jpeg';
        }
      }
    }
    return { extension: extension, mime: mime, isVideo: isVideo };
  }

  private static decodeUtf16(data: Uint8Array, offset: number, limit: number): FujifilmStringResult {
    let text: string = '';
    let at: number = offset;
    while (at + 1 < data.length && text.length < limit) {
      const code: number = data[at] | (data[at + 1] << 8);
      at += 2;
      if (code === 0) break;
      text += String.fromCharCode(code);
    }
    return { text: text, next: at };
  }

  private static isPlausibleName(text: string): boolean {
    if (text.length === 0 || text.length > 200) return false;
    let hasDot: boolean = false;
    for (let index: number = 0; index < text.length; index++) {
      const code: number = text.charCodeAt(index);
      if (code < 0x20 || code === 0x7F) return false;
      if (text.charAt(index) === '.') hasDot = true;
    }
    if (hasDot) {
      const dot: number = text.lastIndexOf('.');
      return dot > 0 && dot < text.length - 1 && text.length - dot <= 6;
    }
    return text.length >= 3;
  }

  private static looksLikeDate(text: string): boolean {
    if (text.length < 8) return false;
    return /^\d{4}[-/:]?\d{2}[-/:]?\d{2}/.test(text);
  }

  private static dateKey(raw: string): string {
    const t: number = raw.indexOf('T');
    const datePart: string = t > 0 ? raw.substring(0, t) : raw;
    return datePart.replace(/[^0-9]/g, '');
  }

  /** 相机的拍摄时间常见 `2024-01-02T12:34:56` / `2024:01:02 12:34:56`。 */
  static prettyDate(raw: string): string {
    if (raw.length === 0) return '';
    const t: number = raw.indexOf('T');
    if (t > 0) return `${raw.substring(0, t).replace(/-/g, '/')} ${raw.substring(t + 1)}`;
    return raw.replace(/-/g, '/');
  }

  private resolveStorageId(): number {
    return this.activeStorageId > 0 ? this.activeStorageId : ALL_STORAGE_ID;
  }

  private handleTimeout(expected: number): number {
    return Math.max(FujifilmNet.TRANSACTION_TIMEOUT_MS,
      Math.min(60000, FujifilmNet.TRANSACTION_TIMEOUT_MS + expected * 10));
  }

  private findSlot(slot: number): FujifilmSlotView | null {
    for (const item of this.slots) {
      if (item.slot === slot) return item;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // 缩略图
  // -------------------------------------------------------------------------

  /**
   * 页面滚动时调用：只排窗口内的前 count 个，队列上限 50。
   * PTP 事务本身串行（A 的 op 队列），这里再串行化避免 30 个请求同时排队。
   */
  ensureThumbnailWindow(firstIndex: number, count: number): void {
    if (this.phase !== FujifilmTransferStage.READY || this.items.length === 0) return;
    const start: number = Math.max(0, firstIndex);
    const end: number = Math.min(this.items.length, start + count);
    for (let index: number = start; index < end; index++) {
      this.requestThumbnail(this.items[index].handle);
    }
  }

  requestThumbnail(handle: number): void {
    const item: FujifilmGalleryItem | null = this.findItem(handle);
    if (item === null) return;
    if (item.thumbState !== FujifilmThumbStage.IDLE) return;
    if (this.thumbQueue.length >= THUMB_QUEUE_LIMIT) return;
    item.thumbState = FujifilmThumbStage.QUEUED;
    this.thumbQueue.push(handle);
    void this.pumpThumbnails();
  }

  private async pumpThumbnails(): Promise<void> {
    if (this.thumbRunning || this.disposed) return;
    this.thumbRunning = true;
    const epoch: number = this.thumbEpoch;
    try {
      while (this.thumbQueue.length > 0 && !this.disposed && epoch === this.thumbEpoch) {
        const handle: number | undefined = this.thumbQueue.shift();
        if (handle === undefined) break;
        const item: FujifilmGalleryItem | null = this.findItem(handle);
        if (item === null || item.thumbState === FujifilmThumbStage.READY) continue;
        item.thumbState = FujifilmThumbStage.LOADING;
        try {
          const fetched: Uint8Array = await this.fetchThumbnail(item);
          // 相机缩略图是**未转正**的原始像素（NOTES_F §3：官方在 WiFi 侧把 SDK
          // 方向反算成 EXIF 写回，像素本身没转），所以缓存前先按方向转正：
          // 这样列表、大图预览、以及「最近作品」的兜底缩略图拿到的都是显示方向。
          const bytes: Uint8Array = await this.orientThumbnail(fetched, item.orientation);
          if (epoch !== this.thumbEpoch || this.disposed) break;
          if (bytes.length === 0) {
            item.thumbState = FujifilmThumbStage.FAILED;
            this.revision += 1;
            continue;
          }
          const path: string = this.writeThumbnail(item, bytes);
          item.thumbUri = `file://${path}`;
          item.thumbState = FujifilmThumbStage.READY;
          this.rememberThumb(item.handle, bytes);
          this.revision += 1;
        } catch (error) {
          item.thumbState = FujifilmThumbStage.FAILED;
          this.revision += 1;
          this.log(`thumb fail handle=${FujifilmBytes.hex(handle, 8)} ${String(error)}`);
        }
      }
    } finally {
      this.thumbRunning = false;
    }
  }

  private async fetchThumbnail(item: FujifilmGalleryItem): Promise<Uint8Array> {
    const cached: Uint8Array | undefined = this.thumbMemory.get(item.handle);
    if (cached !== undefined && cached.length > 0) return cached;
    let reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
      FujifilmOp.GET_EXTENSION_THUMB, [item.handle], 20000);
    if (reply.code !== FujifilmResponse.OK || reply.data.length === 0) {
      this.log(`GetExtensionThumb(${FujifilmBytes.hex(item.handle, 8)}) ` +
        `code=${FujifilmBytes.hex(reply.code)}，试 0x100A`);
      reply = await FujifilmPtpIp.opDataIn(
        FujifilmOp.GET_THUMB, [item.handle], 20000);
    }
    if (reply.code !== FujifilmResponse.OK) return new Uint8Array(0);
    return reply.data;
  }

  /**
   * 按相机给的 EXIF 方向（1–8）把缩略图 JPEG 的像素转正。
   *
   * 相机返回的缩略图不带 EXIF，像素也是未旋转的；UI 里若只是给 `Image` 加
   * `rotate`，90°/270° 会顶出卡片格子（旋转发生在布局之后），所以统一在这里
   * 解码→旋转→重新编码成缓存 JPEG。旋转失败时原样返回，宁可方向不对也不能
   * 让缩略图丢掉。
   */
  private async orientThumbnail(bytes: Uint8Array, orientation: number): Promise<Uint8Array> {
    if (orientation <= 1 || bytes.length < 4) return bytes;
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    try {
      const head: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset,
        bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      source = image.createImageSource(head);
      if (!source) return bytes;
      pixelMap = await source.createPixelMap();
      if (!pixelMap) return bytes;
      await RawPreviewLoader.applyOrientation(pixelMap, orientation);
      const jpeg: ArrayBuffer | null = await PixelMapUtils.encodeToJpeg(pixelMap, 88);
      if (jpeg === null) return bytes;
      return new Uint8Array(jpeg);
    } catch (_error) {
      return bytes;
    } finally {
      if (pixelMap !== null) {
        try {
          pixelMap.release();
        } catch (_releaseError) {
        }
      }
      if (source !== null) {
        try {
          await source.release();
        } catch (_releaseError) {
        }
      }
    }
  }

  private writeThumbnail(item: FujifilmGalleryItem, bytes: Uint8Array): string {
    const jpeg: boolean = bytes.length > 2 && bytes[0] === 0xFF && bytes[1] === 0xD8;
    const ext: string = jpeg ? 'jpg' : (item.extension === 'heic' ? 'heic' : 'jpg');
    const path: string = `${this.thumbDir}/s${this.activeSlot}_` +
      `${item.handle.toString(16)}.${ext}`;
    this.writeBytes(path, bytes);
    return path;
  }

  private rememberThumb(handle: number, bytes: Uint8Array): void {
    this.thumbMemory.set(handle, bytes);
    this.thumbMemoryOrder.push(handle);
    while (this.thumbMemoryOrder.length > THUMB_MEMORY_LIMIT) {
      const old: number | undefined = this.thumbMemoryOrder.shift();
      if (old !== undefined) this.thumbMemory.delete(old);
    }
  }

  // -------------------------------------------------------------------------
  // 选择 / 下载
  // -------------------------------------------------------------------------

  toggleSelection(handle: number): void {
    const item: FujifilmGalleryItem | null = this.findItem(handle);
    if (item === null) return;
    if (this.selected.has(handle)) {
      this.selected.delete(handle);
      item.selected = false;
    } else {
      this.selected.add(handle);
      item.selected = true;
    }
    this.revision += 1;
  }

  selectAll(value: boolean): void {
    this.selected.clear();
    for (const item of this.items) {
      item.selected = value;
      if (value) this.selected.add(item.handle);
    }
    this.revision += 1;
  }

  selectedCount(): number {
    return this.selected.size;
  }

  cancelDownload(): void {
    if (!this.downloadInProgress) return;
    this.downloadCancelled = true;
    this.downloadStatus = '正在取消…';
    this.revision += 1;
    this.log('download cancel requested');
  }

  async downloadSelected(): Promise<void> {
    if (this.downloadInProgress || this.disposed) return;
    const targets: FujifilmGalleryItem[] = [];
    for (const item of this.items) {
      if (item.selected) targets.push(item);
    }
    if (targets.length === 0) {
      this.message = '请先选择要下载的照片';
      this.revision += 1;
      return;
    }
    this.downloadInProgress = true;
    this.downloadCancelled = false;
    this.downloadProgress = 0;
    this.downloadSaved = 0;
    this.downloadFailed = 0;
    this.downloadKept = 0;
    this.downloadRecent = 0;
    this.downloadCurrent = 0;
    this.downloadTotal = targets.length;
    this.downloadStatus = `准备下载 ${targets.length} 个文件…`;
    this.setPhase(FujifilmTransferStage.DOWNLOADING, this.downloadStatus);
    this.log(`download start count=${targets.length}`);

    let totalBytes: number = 0;
    for (const item of targets) {
      if (item.size > 0) totalBytes += item.size;
    }
    let doneBytes: number = 0;
    for (let index: number = 0; index < targets.length; index++) {
      if (this.downloadCancelled || this.disposed) break;
      const item: FujifilmGalleryItem = targets[index];
      this.downloadCurrent = index + 1;
      this.downloadStatus = `正在下载 ${index + 1}/${targets.length} · ${item.name}`;
      this.downloadProgress = totalBytes > 0
        ? Math.min(99, Math.round(doneBytes * 100 / totalBytes))
        : Math.round(index * 100 / targets.length);
      this.revision += 1;
      try {
        const path: string = await this.downloadOne(item, (received: number): void => {
          const current: number = totalBytes > 0
            ? doneBytes + (item.size > 0 ? Math.min(received, item.size) : received)
            : 0;
          this.downloadProgress = totalBytes > 0
            ? Math.min(99, Math.round(current * 100 / totalBytes))
            : Math.round((index + (item.size > 0 ? received / item.size : 0)) *
              100 / targets.length);
          this.revision += 1;
        });
        const galleryUri: string = await this.saveToGallery(path, item);
        if (galleryUri.length > 0) {
          this.downloadSaved += 1;
        } else {
          this.downloadKept += 1;
          this.log(`gallery save failed, keep sandbox path=${path}`);
        }
        // 与松下/尼康线一致：下载完成的作品要进「最近作品」，否则只能在系统相册里看到。
        // 方向交给 RecentPhotoStore：原图优先走 EXIF 归一化（竖拍不会横置）；原图暂时
        // 读不出来时才回退到相机缩略图，而 Fuji 的 WiFi 缩略图是**未转正**的裸像素：
        //   - 官方 CashDataManager.bitmapConverter 解码后按 ImageInformation.orientation
        //     自己 rotate 90/180/270（J:.../CashDataManager.java:744-754）；
        //   - 官方写文件缓存时把方向写进 EXIF TAG_ORIENTATION
        //     （J:.../CashDataManager.java:333-337, 95-110）；
        //   - 下载完成后也用同一方向转收到的 JPEG（J:.../ReceiveImageModel.java:1867）。
        // 所以缓存里的缩略图像素已经在 `orientThumbnail()` 转正（NOTES_F §3），
        // 交给「最近作品」时方向传 1，避免二次旋转；原图的 EXIF 由
        // `ExifOrientation` 在解码路径上处理。
        const orientation: number =
          item.orientation >= 1 && item.orientation <= 8 ? item.orientation : 1;
        const recentUri: string = galleryUri.length > 0 ? galleryUri : ('file://' + path);
        const fallbackThumb: string = item.thumbUri.length > 0 ? item.thumbUri : '';
        this.log(`方向 handle=${FujifilmBytes.hex(item.handle, 8)} orientation=${orientation} ` +
          `thumb=${fallbackThumb.length > 0 ? 'camera' : 'none'}`);
        try {
          await RecentPhotoStore.add(this.context, recentUri, item.name, fallbackThumb, 1);
          this.downloadRecent += 1;
          this.log(`recent works add ok name=${item.name} uri=${recentUri}`);
        } catch (recentError) {
          this.log(`recent works add failed name=${item.name} ${String(recentError)}`);
        }
        if (item.size > 0) doneBytes += item.size;
      } catch (error) {
        if (this.downloadCancelled) break;
        this.downloadFailed += 1;
        this.log(`download fail handle=${FujifilmBytes.hex(item.handle, 8)} ${String(error)}`);
      }
    }

    this.downloadProgress = 100;
    if (this.downloadCancelled) {
      this.downloadStatus = `已取消：完成 ${this.downloadSaved}，最近作品 ${this.downloadRecent}，失败 ${this.downloadFailed}`;
    } else if (this.downloadKept > 0) {
      this.downloadStatus = `完成：相册 ${this.downloadSaved}，` +
        `应用目录 ${this.downloadKept}，最近作品 ${this.downloadRecent}，失败 ${this.downloadFailed}`;
    } else {
      this.downloadStatus = `完成：成功 ${this.downloadSaved}，最近作品 ${this.downloadRecent}，失败 ${this.downloadFailed}`;
    }
    this.downloadInProgress = false;
    this.setPhase(FujifilmTransferStage.READY, this.downloadStatus);
    this.log(this.downloadStatus);
  }

  /**
   * 单文件：<=20 MiB 先试 0x1009 整包，失败/过大走 0x9056 分块（0x101B 兜底）。
   * 每块回调进度；取消在块间生效；失败删 .part 后最多再试一次。
   */
  private async downloadOne(item: FujifilmGalleryItem,
    onProgress: (received: number) => void): Promise<string> {
    const finalName: string = this.safeFileName(item.name, item.extension);
    const finalPath: string = this.uniquePath(this.downloadDir, finalName);
    const tempPath: string = `${this.downloadDir}/.${item.handle.toString(16)}_` +
      `${Date.now()}.part`;
    for (let attempt: number = 1; attempt <= DOWNLOAD_MAX_ATTEMPTS; attempt++) {
      if (this.downloadCancelled || this.disposed) throw new Error('已取消');
      try {
        let wholeDone: boolean = false;
        if (item.size > 0 && item.size <= WHOLE_OBJECT_LIMIT) {
          try {
            const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
              FujifilmOp.GET_OBJECT, [item.handle], this.downloadTimeout(item.size));
            if (reply.code === FujifilmResponse.OK && reply.data.length > 0 &&
              (item.size <= 0 || reply.data.length === item.size)) {
              this.writeBytes(tempPath, reply.data);
              onProgress(reply.data.length);
              wholeDone = true;
            } else {
              this.log(`GetObject(${FujifilmBytes.hex(item.handle, 8)}) ` +
                `code=${FujifilmBytes.hex(reply.code)} bytes=${reply.data.length}，转分块`);
            }
          } catch (error) {
            this.log(`GetObject error=${String(error)}，转分块`);
          }
        }
        if (!wholeDone) await this.downloadInChunks(item, tempPath, onProgress);
        if (this.downloadCancelled || this.disposed) {
          this.deleteFile(tempPath);
          throw new Error('已取消');
        }
        const stat = fileIo.statSync(tempPath);
        if (item.size > 0 && stat.size !== item.size) {
          throw new Error(`大小不符 ${stat.size}/${item.size}`);
        }
        if (stat.size <= 0) throw new Error('空文件');
        fileIo.renameSync(tempPath, finalPath);
        return finalPath;
      } catch (error) {
        this.deleteFile(tempPath);
        if (this.downloadCancelled || this.disposed ||
          attempt >= DOWNLOAD_MAX_ATTEMPTS) {
          throw error instanceof Error ? error : new Error(String(error));
        }
        this.log(`download retry #${attempt} handle=${FujifilmBytes.hex(item.handle, 8)} ` +
          `${String(error)}`);
        await this.delay(200);
      }
    }
    throw new Error('下载失败');
  }

  private async downloadInChunks(item: FujifilmGalleryItem, path: string,
    onProgress: (received: number) => void): Promise<void> {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    let received: number = 0;
    try {
      while (!this.downloadCancelled && !this.disposed) {
        const remain: number = item.size > 0 ? item.size - received : PARTIAL_CHUNK;
        if (item.size > 0 && remain <= 0) break;
        const ask: number = Math.min(PARTIAL_CHUNK, remain);
        let reply: FujifilmReply;
        try {
          reply = await FujifilmPtpIp.opDataIn(
            FujifilmOp.GET_EXTENSION_PARTIAL_OBJECT,
            [item.handle, received, ask], this.downloadTimeout(ask));
        } catch (error) {
          this.log(`0x9056 error=${String(error)}，试 0x101B`);
          reply = await FujifilmPtpIp.opDataIn(
            FujifilmOp.GET_PARTIAL_OBJECT,
            [item.handle, received, ask], this.downloadTimeout(ask));
        }
        if (reply.code !== FujifilmResponse.OK) {
          throw new Error(`分块 code=${FujifilmBytes.hex(reply.code)} ` +
            `offset=${received} bytes=${reply.data.length}`);
        }
        if (reply.data.length === 0) {
          if (item.size <= 0) break;
          throw new Error(`分块空数据 offset=${received}/${item.size}`);
        }
        let data: Uint8Array = reply.data;
        if (item.size > 0 && received + data.length > item.size) {
          data = data.slice(0, item.size - received);
        }
        fileIo.writeSync(file.fd, FujifilmImportService.exactBuffer(data));
        received += data.length;
        onProgress(received);
        this.log(`chunk handle=${FujifilmBytes.hex(item.handle, 8)} ` +
          `offset=${received} bytes=${data.length}`);
        if (item.size > 0 && received >= item.size) break;
        await this.delay(0);
      }
    } finally {
      fileIo.closeSync(file);
    }
    if (item.size > 0 && received !== item.size) {
      throw new Error(`分块不完整 ${received}/${item.size}`);
    }
    if (received <= 0) throw new Error('分块无数据');
  }

  /** 保存到系统相册；成功返回新建资产的 URI（用于写「最近作品」），失败返回空串。 */
  private async saveToGallery(path: string, item: FujifilmGalleryItem): Promise<string> {
    try {
      const size: number = Number(fileIo.statSync(path).size);
      if (size <= 0) return '';
      const helper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const uri: string = await helper.createAsset(
        item.isVideo ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE,
        item.extension.length > 0 ? item.extension : 'jpg',
        { title: FujifilmImportService.baseName(item.name) });
      const copied: number = await FujifilmImportService.copyFileChunked(path, uri);
      if (copied !== size) throw new Error(`相册写入 ${copied}/${size}`);
      this.deleteFile(path);
      return uri;
    } catch (error) {
      this.log(`saveToGallery error=${String(error)}`);
      return '';
    }
  }

  private static async copyFileChunked(sourcePath: string, targetUri: string): Promise<number> {
    const source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
    const output = fileIo.openSync(targetUri, fileIo.OpenMode.WRITE_ONLY);
    const chunk: ArrayBuffer = new ArrayBuffer(SAVE_CHUNK_BYTES);
    let copied: number = 0;
    try {
      while (true) {
        const read: number = fileIo.readSync(source.fd, chunk);
        if (read <= 0) break;
        fileIo.writeSync(output.fd,
          read === chunk.byteLength ? chunk : chunk.slice(0, read));
        copied += read;
        await new Promise<void>((resolve) => {
          setTimeout(resolve, 0);
        });
      }
    } finally {
      fileIo.closeSync(source);
      fileIo.closeSync(output);
    }
    return copied;
  }

  // -------------------------------------------------------------------------
  // 快照 / 工具
  // -------------------------------------------------------------------------

  snapshot(): FujifilmTransferSnapshot {
    const slotViews: FujifilmSlotView[] = [];
    for (const slot of this.slots) {
      slotViews.push({
        slot: slot.slot,
        label: slot.label,
        detail: slot.detail,
        available: slot.available,
        current: slot.current,
        status: slot.status,
      });
    }
    return {
      phase: this.phase,
      model: this.model,
      message: this.message,
      error: this.error,
      items: this.items.slice(),
      slots: slotViews,
      activeSlot: this.activeSlot,
      slotStatus: this.slotStatus,
      slotControlSupported: this.slotControlSupported,
      total: this.total,
      selectedCount: this.selected.size,
      loading: this.phase === FujifilmTransferStage.CONNECTING ||
        this.phase === FujifilmTransferStage.MODE ||
        this.phase === FujifilmTransferStage.SLOTS ||
        this.phase === FujifilmTransferStage.ENUMERATING,
      downloadInProgress: this.downloadInProgress,
      downloadProgress: this.downloadProgress,
      downloadStatus: this.downloadStatus,
      downloadSaved: this.downloadSaved,
      downloadFailed: this.downloadFailed,
      downloadRecent: this.downloadRecent,
      downloadCurrent: this.downloadCurrent,
      downloadTotal: this.downloadTotal,
    };
  }

  static sizeText(bytes: number): string {
    if (bytes <= 0) return '—';
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }

  private findItem(handle: number): FujifilmGalleryItem | null {
    for (const item of this.items) {
      if (item.handle === handle) return item;
    }
    return null;
  }

  private setPhase(phase: string, message: string): void {
    this.phase = phase;
    this.message = message;
    this.revision += 1;
  }

  private fail(message: string): void {
    this.error = message;
    this.phase = FujifilmTransferStage.ERROR;
    this.message = message;
    this.revision += 1;
    this.log(message);
  }

  private isRetryable(code: number): boolean {
    return code === FujifilmResponse.DEVICE_BUSY ||
      code === FujifilmResponse.FUJI_RETRY_CODE;
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, ms);
    });
  }

  private ensureDir(path: string): void {
    try {
      fileIo.statSync(path);
    } catch (_error) {
      try {
        fileIo.mkdirSync(path, true);
      } catch (mkdirError) {
        this.log(`mkdir ${path} error=${String(mkdirError)}`);
      }
    }
  }

  private writeBytes(path: string, data: Uint8Array): void {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, FujifilmImportService.exactBuffer(data));
    } finally {
      fileIo.closeSync(file);
    }
  }

  private deleteFile(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (_error) {
      // 文件可能根本没创建，忽略。
    }
  }

  private fileExists(path: string): boolean {
    try {
      fileIo.statSync(path);
      return true;
    } catch (_error) {
      return false;
    }
  }

  private uniquePath(dir: string, name: string): string {
    let candidate: string = name;
    const dot: number = name.lastIndexOf('.');
    const base: string = dot > 0 ? name.substring(0, dot) : name;
    const suffix: string = dot > 0 ? name.substring(dot) : '';
    let index: number = 1;
    while (this.fileExists(`${dir}/${candidate}`)) {
      candidate = `${base} (${index})${suffix}`;
      index += 1;
      if (index > 999) break;
    }
    return `${dir}/${candidate}`;
  }

  private safeFileName(rawName: string, extension: string): string {
    let name: string = rawName.trim();
    if (name.length === 0) name = `FUJI_${Date.now()}.${extension}`;
    name = name.replace(/[\\/:*?"<>|]/g, '_');
    const dot: number = name.lastIndexOf('.');
    if (dot <= 0 || dot >= name.length - 1) {
      name = `${name}.${extension.length > 0 ? extension : 'jpg'}`;
    }
    return name;
  }

  private downloadTimeout(bytes: number): number {
    const extra: number = Math.round(bytes / 1024) * 2;
    return Math.max(30000, Math.min(600000, 20000 + extra));
  }

  private static exactBuffer(data: Uint8Array): ArrayBuffer {
    const copy: Uint8Array = new Uint8Array(data.length);
    copy.set(data);
    return copy.buffer;
  }

  private static baseName(name: string): string {
    const dot: number = name.lastIndexOf('.');
    const base: string = dot > 0 ? name.substring(0, dot) : name;
    return base.length > 0 ? base : `FUJI_${Date.now()}`;
  }

  private log(message: string): void {
    AppLogStore.add(`${FUJI_TAG} ${message}`);
  }
}
