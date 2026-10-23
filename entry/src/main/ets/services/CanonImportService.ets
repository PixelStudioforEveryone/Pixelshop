/**
 * 佳能（EOS 路线）图片传输服务 —— 契约见 `docs/canon-route-design.md` §5。
 *
 * 一条链（报告 03 §8 的完整序列）：
 *   PTP/IP 建链（由 `CanonPtpIp.connect` 完成 OpenSession/SetRemoteMode/SetEventMode）
 *   → `GetStorageIDs` 枚举卷（= 存储卡，含空卡）
 *   → 当前卷从根 `parent=0` 递归 `GetObjectHandles` + `GetObjectInfo`
 *   → 逐张串行 `GetThumbEx` 缓存缩略图
 *   → 勾选后 `GetPartialObjectEx` 分块下载 → 沙箱 + 相册。
 *
 * 证据（每条协议常量的出处都写在 `CanonPtpCode` 的注释里）：
 *   - 报告 03 §2.1：`GetStorageIDs`/`GetStorageInfo` 枚举卷，卷 = 存储卡；
 *   - 报告 03 §2.2 / `EOSDirectoryTreeCommand.java:120-160`：从卷根递归全树；
 *   - 报告 03 §2.3：条目字段 = ObjectHandle / FileName / Size / DateTime / Format；
 *   - 报告 03 §5：缩略图逐张串行下载并缓存（`EOSThumbImage`）；
 *   - 报告 03 §6：原图分块传输（native `DC_GetPartialObjectEX`）；
 *   - libgphoto2 `ptp2/ptp.h` 与 `ptp2/ptp.c`：opcode 数值与参数个数。
 *
 * 关键取舍（评审对照报告时看这里）：
 *   1. 卷列表**只来自相机上报**，按 `GetStorageIDs` 返回顺序编号；空卡照样入列
 *      （报告 03 §2.1：App 以卷为单位显示卡，不能从条目反推）。
 *   2. 目录枚举**不做客户端排序**（报告 03 §4：相机顺序即相机顺序，倒序是
 *      官方 App 客户端比较器的事），同一目录内保持 `GetObjectHandles` 原序。
 *   3. `imageId = storageId + ':' + handle`：多卡句柄空间独立，切卡不能串条目
 *      （报告 03 §3【未知】mGroupID 高位，因此用卷号而不是条目字段区分卡）。
 *   4. 缩略图与下载都串行（报告 03 §2.4：官方 `newSingleThreadExecutor()`）。
 *   5. `dispose()` 不停 PTP/IP：控制页/图传页可能共用同一条会话，关链由页面
 *      或 `CanonPtpIp.close()` 决定（契约 §5）。
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { CanonPtpDataReply, CanonPtpIp, CanonPtpReply } from './CanonPtpIp';
import { AppLogSink } from './AppLogSink';
import { CameraSessionStore } from './CameraSessionStore';
import { LumixCameraService } from './LumixCameraService';

/** 日志标签（契约 §0 铁律 6：图传固定 `CANON_IMG`）。 */
const CANON_IMG_TAG: string = 'CANON_IMG';
/** 原图保存目录名（报告 03 §0：官方 `EOSImage`，本实现用不冲突的 `canon`）。 */
const DIRECTORY_NAME: string = 'canon';
/** 缩略图缓存目录名（契约 §5：`filesDir/canon_thumb/<storageId>_<handle>.jpg`）。 */
const THUMB_DIRECTORY_NAME: string = 'canon_thumb';
/** 分块大小（契约 §5 指定 1 MiB；报告 03 §6 说明官方分块在 native，Java 不可见）。 */
const CHUNK_BYTES: number = 1024 * 1024;
/** 后台每轮补的缩略图张数（契约：后台每轮 6 张，页面轮询 snapshot）。 */
const THUMB_BATCH: number = 6;
/** 两轮缩略图之间的间隔；只在队列还有剩余时重排。 */
const THUMB_TICK_DELAY_MS: number = 160;
/** 缩略图单张超时（契约 §3.2：取图/取帧 15 s）。 */
const THUMB_TIMEOUT_MS: number = 15000;
/** 目录/元数据命令超时（契约 §3.2：命令 10 s）。 */
const COMMAND_TIMEOUT_MS: number = 10000;
/** 整包回退的读取超时。 */
const WHOLE_TIMEOUT_MS: number = 60000;
/** 整包回退的内存上限：超过它只走分块，避免把大 RAW/视频读进内存。 */
const WHOLE_OBJECT_LIMIT: number = 64 * 1024 * 1024;
/** 相册写入缓冲。 */
const SAVE_CHUNK_BYTES: number = 8 * 1024 * 1024;
/** `CanonPtpIp.connect` 的发起方名称（PTP/IP Init_Command_Request 的名称域）。 */
const CONNECT_NAME: string = 'VIVID';
/** 递归目录的防御上限：不是协议常量，只用来挡住相机异常导致的环/超大树。 */
const MAX_DIRECTORIES: number = 2048;
const MAX_DIRECTORY_DEPTH: number = 12;
const MAX_OBJECTS: number = 200000;

/**
 * 本服务用到的 PTP 常量。每条都标出处（契约 §0 铁律 4）。
 */
export class CanonPtpCode {
  /** 正常应答。 */
  static readonly RESPONSE_OK: number = 0x2001;
  /** Operation Not Supported：0x9102/0x910A 等厂商命令的常见回退信号。 */
  static readonly RESPONSE_OPERATION_NOT_SUPPORTED: number = 0x2005;
  /** 参数不支持：部分空目录上的 GetObjectHandles 会回这个码。 */
  static readonly RESPONSE_PARAMETER_NOT_SUPPORTED: number = 0x2006;
  /** 设备忙：由 `CanonPtpIp` 内部重试一次（契约 §3.2），这里只用于日志。 */
  static readonly RESPONSE_DEVICE_BUSY: number = 0x2019;

  /** EOS `GetStorageIDs`（报告 03 §2.1；libgphoto2 `ptp.h:367`）。 */
  static readonly OP_GET_STORAGE_IDS: number = 0x9101;
  /** 标准 `GetStorageIDs`，EOS 命令不支持时回退（契约 §3.4）。 */
  static readonly OP_GET_STORAGE_IDS_STD: number = 0x1004;
  /** EOS `GetStorageInfo`（卷标/访问模式/剩余空间；`ptp.h:376`）。 */
  static readonly OP_GET_STORAGE_INFO: number = 0x9102;
  /** 标准 `GetStorageInfo`（契约 §3.4 的回退；标准 StorageInfo 数据集）。 */
  static readonly OP_GET_STORAGE_INFO_STD: number = 0x1005;
  /** `GetObjectHandles(storage, parent)`：目录树骨架（报告 03 §2.2）。 */
  static readonly OP_GET_OBJECT_HANDLES: number = 0x1007;
  /** `GetObjectInfo(handle)`：名称/大小/时间/格式（报告 03 §2.3）。 */
  static readonly OP_GET_OBJECT_INFO: number = 0x1008;
  /** EOS `GetThumbEx`（报告 03 §5 的 DownloadThumbnailEx 对应；`ptp.h:407`）。 */
  static readonly OP_GET_THUMB_EX: number = 0x910A;
  /** 标准 `GetThumb`，EOS 命令回 0x2005 时回退（`ptp.c:2516`）。 */
  static readonly OP_GET_THUMB: number = 0x100A;
  /** `GetObject`：整包回退（契约 §3.4）。 */
  static readonly OP_GET_OBJECT_EOS: number = 0x9104;
  static readonly OP_GET_OBJECT: number = 0x1009;
  /**
   * EOS `GetPartialObjectEx`：参数为 `(handle, offset, size, 0)`，
   * 见 libgphoto2 `ptp.c:3898-3905`（4 个 u32，最后一个是 64 位尺寸占位）。
   */
  static readonly OP_GET_PARTIAL_OBJECT_EX: number = 0x912C;
  /** EOS `EndGetPartialObjectEx`：分块结束/取消（`ptp.h:463`）。 */
  static readonly OP_END_PARTIAL_OBJECT_EX: number = 0x9132;

  /** Association = 文件夹（`ptp.h:1544`；报告 03 §2.2 的 mFormat==0 同义）。 */
  static readonly FORMAT_ASSOCIATION: number = 0x3001;
  /** Text：非媒体，跳过。 */
  static readonly FORMAT_TEXT: number = 0x3004;
  /** DPOF：非媒体，跳过。 */
  static readonly FORMAT_DPOF: number = 0x3006;
  /** WAV 音频：非媒体，跳过（报告 03 §2.2 的 wav 过滤）。 */
  static readonly FORMAT_WAV: number = 0x3008;
  static readonly FORMAT_MP3: number = 0x3009;
  /*************** 视频容器（`ptp.h:1553-1556`、`ptp.h:1610`） ***************/
  static readonly FORMAT_AVI: number = 0x300A;
  static readonly FORMAT_MPEG: number = 0x300B;
  static readonly FORMAT_ASF: number = 0x300C;
  static readonly FORMAT_QT: number = 0x300D;
  static readonly FORMAT_MP4: number = 0xB982;
  /** MTP XMLDocument：非媒体，跳过（`ptp.h:1632`）。 */
  static readonly FORMAT_XML_DOCUMENT: number = 0xBA82;
  /*************** RAW（`ptp.h:1579-1583`） ***************/
  static readonly FORMAT_CANON_CRW: number = 0xB101;
  static readonly FORMAT_CANON_CRW3: number = 0xB103;
  static readonly FORMAT_CANON_CR3: number = 0xB108;
  /** EXIF JPEG，仅用于日志/诊断。 */
  static readonly FORMAT_EXIF_JPEG: number = 0x3801;
}

/** 快照阶段（页面据此决定骨架屏/错误条/进度遮罩）。 */
export class CanonImportPhase {
  static readonly IDLE: string = 'idle';
  static readonly CONNECTING: string = 'connecting';
  static readonly VOLUMES: string = 'volumes';
  static readonly ENUMERATING: string = 'enumerating';
  static readonly READY: string = 'ready';
  static readonly DOWNLOADING: string = 'downloading';
  static readonly ERROR: string = 'error';
}

/** 卷 = 存储卡（契约 §5，字段一字不差）。 */
export interface CanonVolume {
  storageId: number;
  label: string;
  access: number;
  capacityBytes: number;
  freeBytes: number;
  removable: boolean;
  sequence: number;
}

/** 图库条目（契约 §5，字段一字不差）。 */
export interface CanonGalleryItem {
  imageId: string;
  storageId: number;
  handle: number;
  name: string;
  size: number;
  dateMs: number;
  format: number;
  isVideo: boolean;
  isRaw: boolean;
  groupId: number;
  thumbUri: string;
}

/** 页面轮询的快照（契约 §5，字段一字不差）。 */
export interface CanonImportSnapshot {
  phase: string;
  message: string;
  error: string;
  model: string;
  volumes: CanonVolume[];
  activeStorageId: number;
  items: CanonGalleryItem[];
  total: number;
  selectedCount: number;
  loading: boolean;
  downloadInProgress: boolean;
  downloadProgress: number;
  downloadStatus: string;
  downloadCurrent: number;
  downloadTotal: number;
  revision: number;
}

/** 解析后的 PTP ObjectInfo（标准数据集偏移见 libgphoto2 `ptp-pack.c:401-417`）。 */
interface CanonObjectInfo {
  handle: number;
  storageId: number;
  format: number;
  size: number;
  parent: number;
  name: string;
  dateMs: number;
}

/** 待递归的目录节点。 */
interface CanonDirectoryNode {
  handle: number;
  depth: number;
  groupId: number;
}

/** 解析后的 StorageInfo（标准数据集偏移见 libgphoto2 `ptp-pack.c:367-396`）。 */
interface CanonStorageInfo {
  valid: boolean;
  storageType: number;
  access: number;
  capacityBytes: number;
  freeBytes: number;
  label: string;
}

/** PTP 字符串读取结果：值 + 下一个字段的偏移。 */
interface CanonStringField {
  value: string;
  next: number;
}

/** 视频扩展名（报告 03 §2.2 的文件类型判定；含机身直出的 crm/mov/mp4）。 */
const VIDEO_EXTENSIONS: string[] = [
  'mov', 'mp4', 'm4v', 'avi', 'mpg', 'mpeg', 'mts', 'm2ts', '3gp', 'wmv', 'asf', 'crm', 'mxf',
];

/** RAW 扩展名（契约 §5：CR2/CR3/CRW/RAF 等；配合 `ptp.h:1579-1583` 的 Canon RAW format）。 */
const RAW_EXTENSIONS: string[] = ['cr2', 'cr3', 'crw', 'raf', 'dng'];

/** 非媒体扩展名：报告 03 §2.2 明确 wav/xml 会入树但属于音频/元数据，图库要跳过。 */
const NON_MEDIA_EXTENSIONS: string[] = [
  'wav', 'xml', 'txt', 'dat', 'dmv', 'thm', 'ctg', 'dpo', 'log', 'tmp', 'bin', 'db', 'ini', 'mp3',
];

/**
 * 佳能图传服务。页面只通过本类的公开方法/快照交互。
 */
export class CanonImportService {
  private context: common.UIAbilityContext;
  private model: string = 'Canon';
  private host: string = '';
  private phase: string = CanonImportPhase.IDLE;
  private message: string = '正在准备…';
  private error: string = '';

  private volumes: CanonVolume[] = [];
  private activeStorageId: number = 0;
  private items: CanonGalleryItem[] = [];
  private selected: Set<string> = new Set<string>();
  /** 已下载到沙箱的原图：imageId → file:// 路径（`previewUriOf` 优先返回它）。 */
  private downloaded: Map<string, string> = new Map<string, string>();

  private loading: boolean = false;
  private revisionCounter: number = 0;
  /** 每次 open/refresh/selectVolume 自增，用来丢弃过期的异步结果（切卡不串条目）。 */
  private epoch: number = 0;
  private disposed: boolean = false;

  private downloadDir: string = '';
  private thumbDir: string = '';

  private thumbQueue: string[] = [];
  private thumbFailed: Set<string> = new Set<string>();
  private thumbRunning: boolean = false;
  private thumbEpoch: number = 0;
  private thumbTimerId: number = -1;

  private downloadInProgress: boolean = false;
  private downloadCancelled: boolean = false;
  private downloadProgress: number = 0;
  private downloadStatus: string = '';
  private downloadCurrent: number = 0;
  private downloadTotal: number = 0;
  private downloadSaved: number = 0;
  private downloadFailed: number = 0;
  private downloadAlbum: number = 0;
  /** `GetPartialObjectEx` 的参数个数：4（gphoto2 原样）或 3（固件拒绝 option 后降级）。 */
  private partialArgs: number = 4;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.downloadDir = `${context.filesDir}/${DIRECTORY_NAME}`;
    this.thumbDir = `${context.filesDir}/${THUMB_DIRECTORY_NAME}`;
    this.ensureDir(this.downloadDir);
    this.ensureDir(this.thumbDir);
    const sessionModel: string = CameraSessionStore.instance.cameraModel.trim();
    const brand: string = CameraSessionStore.instance.cameraBrand;
    this.model = brand === 'Canon' && sessionModel.length > 0 ? sessionModel : 'Canon';
  }

  /** 页面按 revision 变化决定是否重新拷快照，避免每 250 ms 全量重设 @State。 */
  get revision(): number {
    return this.revisionCounter;
  }

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  /**
   * 连 PTP/IP（已连则复用）→ 枚举卷 → 读当前卷目录树。
   * 所有异常在内部收敛成 snapshot.error，页面不需要 try/catch。
   */
  async open(): Promise<void> {
    if (this.disposed || this.loading || this.downloadInProgress) return;
    const epoch: number = ++this.epoch;
    this.error = '';
    this.loading = true;
    this.setPhase(CanonImportPhase.CONNECTING, '正在连接相机…');
    try {
      const host: string = await CanonImportService.resolveHost();
      if (epoch !== this.epoch || this.disposed) return;
      if (host.length > 0) this.host = host;
      const alreadyOpen: boolean = CanonPtpIp.isOpen();
      if (!alreadyOpen && this.host.length === 0) {
        throw new Error('未取得相机地址（请先连接相机 Wi-Fi，或由上一页写入 canonHost）');
      }
      this.log(`open host=${CanonImportService.maskHost(this.host)} model=${this.model} ` +
        `reuse=${alreadyOpen ? 1 : 0}`);
      if (!alreadyOpen) {
        await CanonPtpIp.connect(this.host, CONNECT_NAME);
        if (epoch !== this.epoch || this.disposed) return;
        this.log('PTP/IP 会话已建立');
      }

      this.setPhase(CanonImportPhase.VOLUMES, '正在读取存储卡…');
      await this.loadVolumes(epoch);
      if (epoch !== this.epoch || this.disposed) return;

      await this.enumerateActive(epoch);
    } catch (error) {
      if (epoch === this.epoch && !this.disposed) {
        this.fail(`连接相机失败：${String(error)}`);
      }
    } finally {
      if (epoch === this.epoch) {
        this.loading = false;
        this.revisionCounter += 1;
      }
    }
  }

  /** 重新读卷信息 + 重新枚举当前卷（不会断开/重建 PTP 会话）。 */
  async refresh(): Promise<void> {
    if (this.disposed || this.downloadInProgress) return;
    if (this.loading) return;
    // 没开会话才需要重新建链；host 只在建链时用，刷新不必依赖它（会话可能被
    // 控制页先建立，那时 host 未知也应能刷新）。
    if (!CanonPtpIp.isOpen()) {
      await this.open();
      return;
    }
    const epoch: number = ++this.epoch;
    this.error = '';
    this.loading = true;
    this.setPhase(CanonImportPhase.VOLUMES, '正在刷新存储卡…');
    try {
      await this.loadVolumes(epoch);
      if (epoch !== this.epoch || this.disposed) return;
      await this.enumerateActive(epoch);
      if (epoch === this.epoch && !this.disposed) this.log('refresh 完成');
    } catch (error) {
      if (epoch === this.epoch && !this.disposed) {
        this.fail(`刷新失败：${String(error)}`);
      }
    } finally {
      if (epoch === this.epoch) {
        this.loading = false;
        this.revisionCounter += 1;
      }
    }
  }

  /**
   * 切换存储卡：**先清空 items + 置 loading + revision 自增**，再重新递归枚举。
   * 句柄空间按卡独立，`imageId` 带 storageId，所以切换过程不会串条目。
   */
  async selectVolume(storageId: number): Promise<void> {
    if (this.disposed) return;
    if (this.downloadInProgress) {
      this.message = '下载中，暂不能切换存储卡';
      this.revisionCounter += 1;
      return;
    }
    if (this.loading && this.volumes.length === 0) return;
    if (!this.volumeKnown(storageId)) {
      this.message = '相机没有上报这张存储卡';
      this.revisionCounter += 1;
      this.log(`selectVolume 未知 storage=${storageId}`);
      return;
    }
    // 这里**不因为 loading 就 return**：初始枚举还没跑完时用户点另一张卡，
    // 直接 epoch++ 让旧枚举作废（旧循环在 epoch 检查处自行退出），立即重读新卡。
    const epoch: number = ++this.epoch;
    this.activeStorageId = storageId;
    this.items = [];
    this.selected.clear();
    this.thumbEpoch += 1;
    this.thumbQueue = [];
    this.thumbFailed.clear();
    this.clearThumbTimer();
    this.error = '';
    this.loading = true;
    this.setPhase(CanonImportPhase.ENUMERATING, '正在切换存储卡…');
    this.log(`selectVolume storage=${storageId}`);
    try {
      await this.enumerateActive(epoch);
    } catch (error) {
      if (epoch === this.epoch && !this.disposed) {
        this.fail(`读取存储卡失败：${String(error)}`);
      }
    } finally {
      if (epoch === this.epoch) {
        this.loading = false;
        this.revisionCounter += 1;
      }
    }
  }

  /** 全选 / 全不选。 */
  selectAll(selected: boolean): void {
    this.selected.clear();
    for (const item of this.items) {
      if (selected) this.selected.add(item.imageId);
    }
    this.revisionCounter += 1;
  }

  /** 勾选/取消单个条目（按 `imageId`，切卡后同号句柄不会互相顶掉）。 */
  toggle(imageId: string): void {
    const item: CanonGalleryItem | null = this.findItem(imageId);
    if (item === null) return;
    if (this.selected.has(imageId)) {
      this.selected.delete(imageId);
    } else {
      this.selected.add(imageId);
    }
    this.revisionCounter += 1;
  }

  /** 缩略图优先、否则已下载原图；都没有返回空串（页面画占位）。 */
  previewUriOf(imageId: string): string {
    const saved: string | undefined = this.downloaded.get(imageId);
    if (saved !== undefined && saved.length > 0) return saved;
    const item: CanonGalleryItem | null = this.findItem(imageId);
    if (item !== null && item.thumbUri.length > 0) return item.thumbUri;
    return '';
  }

  /** 当前状态快照；页面只在 `revision` 变化时重新取。 */
  snapshot(): CanonImportSnapshot {
    return {
      phase: this.phase,
      message: this.message,
      error: this.error,
      model: this.model,
      volumes: this.volumes.slice(),
      activeStorageId: this.activeStorageId,
      items: this.items.slice(),
      total: this.items.length,
      selectedCount: this.selected.size,
      loading: this.loading,
      downloadInProgress: this.downloadInProgress,
      downloadProgress: this.downloadProgress,
      downloadStatus: this.downloadStatus,
      downloadCurrent: this.downloadCurrent,
      downloadTotal: this.downloadTotal,
      revision: this.revisionCounter,
    };
  }

  /**
   * 页面退出清理：清定时器、停下载队列、丢弃在途缩略图。
   * **不断开 PTP/IP**（契约 §5：另一页可能复用；由页面自行 `CanonPtpIp.close()`）。
   */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.epoch += 1;
    this.thumbEpoch += 1;
    this.thumbQueue = [];
    this.clearThumbTimer();
    this.downloadCancelled = true;
    // 在途分块由 `downloadOne` 的 finally 收尾（EndGetPartialObjectEx + 删临时文件）。
    this.loading = false;
    this.log('dispose（保留 PTP/IP 会话给其它页面）');
  }

  // -------------------------------------------------------------------------
  // 卷 / 目录树
  // -------------------------------------------------------------------------

  private async loadVolumes(epoch: number): Promise<void> {
    const ids: number[] = await this.readStorageIds();
    if (epoch !== this.epoch || this.disposed) return;
    const list: CanonVolume[] = [];
    for (let index: number = 0; index < ids.length; index++) {
      const storageId: number = ids[index];
      const info: CanonStorageInfo = await this.readStorageInfo(storageId);
      if (epoch !== this.epoch || this.disposed) return;
      const volume: CanonVolume = {
        storageId: storageId,
        label: info.label.length > 0 ? info.label : `卡 ${index + 1}`,
        access: info.access,
        capacityBytes: info.capacityBytes,
        freeBytes: info.freeBytes,
        // 标准 StorageType：2=可移动 ROM、4=可移动 RAM（其余按「非可移动」记）。
        removable: info.storageType === 0 || info.storageType === 2 || info.storageType === 4,
        sequence: index + 1,
      };
      list.push(volume);
    }
    this.volumes = list;
    let kept: boolean = false;
    for (const volume of list) {
      if (volume.storageId === this.activeStorageId) kept = true;
    }
    if (!kept && list.length > 0) this.activeStorageId = list[0].storageId;
    this.revisionCounter += 1;
    this.log(`volumes=${list.length} active=${this.activeStorageId} ` +
      `labels=${list.map((volume: CanonVolume): string => volume.label).join('/')}`);
    if (list.length === 0) throw new Error('相机未上报存储卡');
  }

  private async readStorageIds(): Promise<number[]> {
    let reply: CanonPtpDataReply =
      await CanonPtpIp.opIn(CanonPtpCode.OP_GET_STORAGE_IDS, [], COMMAND_TIMEOUT_MS);
    if (reply.reply.code !== CanonPtpCode.RESPONSE_OK || reply.data.length < 4) {
      this.log(`GetStorageIDs(0x9101) code=${CanonImportService.hexCode(reply.reply.code)}，回退 0x1004`);
      reply = await CanonPtpIp.opIn(CanonPtpCode.OP_GET_STORAGE_IDS_STD, [], COMMAND_TIMEOUT_MS);
    }
    if (reply.reply.code !== CanonPtpCode.RESPONSE_OK) {
      throw new Error(`GetStorageIDs code=${CanonImportService.hexCode(reply.reply.code)}`);
    }
    const all: number[] = CanonImportService.parseU32List(reply.data);
    const ids: number[] = [];
    for (const id of all) {
      // 0 在 PTP 里表示「全部卷」，不是一张卡；不能给它建按钮。
      if (id === 0) continue;
      ids.push(id);
    }
    return ids;
  }

  private async readStorageInfo(storageId: number): Promise<CanonStorageInfo> {
    const first: CanonPtpDataReply =
      await CanonPtpIp.opIn(CanonPtpCode.OP_GET_STORAGE_INFO, [storageId], COMMAND_TIMEOUT_MS);
    let best: CanonStorageInfo = CanonImportService.emptyStorageInfo();
    if (first.reply.code === CanonPtpCode.RESPONSE_OK && first.data.length >= 26) {
      best = CanonImportService.parseStorageInfo(first.data);
    } else {
      this.log(`GetStorageInfo(0x9102) storage=${storageId} ` +
        `code=${CanonImportService.hexCode(first.reply.code)} bytes=${first.data.length}`);
    }
    if (!best.valid) {
      const second: CanonPtpDataReply =
        await CanonPtpIp.opIn(CanonPtpCode.OP_GET_STORAGE_INFO_STD, [storageId], COMMAND_TIMEOUT_MS);
      if (second.reply.code === CanonPtpCode.RESPONSE_OK && second.data.length >= 26) {
        const parsed: CanonStorageInfo = CanonImportService.parseStorageInfo(second.data);
        if (parsed.valid || best.label.length === 0) best = parsed;
      } else {
        this.log(`GetStorageInfo(0x1005) storage=${storageId} ` +
          `code=${CanonImportService.hexCode(second.reply.code)} bytes=${second.data.length}`);
      }
    }
    if (!best.valid) {
      // 相机没给可解析的体积信息：卷仍然要出现（空卡/只读卡也必须能点），只是数值为 0。
      this.log(`storage=${storageId} 体积信息不可用，按 0 显示`);
    }
    this.log(`storage=${storageId} label=${best.label} access=${best.access} ` +
      `capacity=${best.capacityBytes} free=${best.freeBytes}`);
    return best;
  }

  private async enumerateActive(epoch: number): Promise<void> {
    const storageId: number = this.activeStorageId;
    if (storageId <= 0) throw new Error('没有可用的存储卡');
    this.items = [];
    this.selected.clear();
    this.thumbEpoch += 1;
    this.thumbQueue = [];
    this.thumbFailed.clear();
    this.clearThumbTimer();
    this.revisionCounter += 1;
    this.loading = true;
    this.setPhase(CanonImportPhase.ENUMERATING, '正在读取目录…');
    const collected: CanonGalleryItem[] = await this.collectItems(storageId, epoch);
    if (epoch !== this.epoch || this.disposed) return;
    this.items = collected;
    this.loading = false;
    this.setPhase(CanonImportPhase.READY,
      collected.length > 0 ? `共 ${collected.length} 个文件` : '这张存储卡没有媒体文件');
    this.queueMissingThumbs();
    this.scheduleThumbTick();
    this.log(`enumerate storage=${storageId} items=${collected.length}`);
  }

  /**
   * 从卷根 `parent=0` 递归。用队列（BFS）而不是栈：同一目录内保持
   * `GetObjectHandles` 原序，不会因为后进先出把兄弟目录倒过来。
   */
  private async collectItems(storageId: number, epoch: number): Promise<CanonGalleryItem[]> {
    const collected: CanonGalleryItem[] = [];
    const directories: CanonDirectoryNode[] = [];
    const root: CanonDirectoryNode = { handle: 0, depth: 0, groupId: 0 };
    directories.push(root);
    let cursor: number = 0;
    let examined: number = 0;
    let skipped: number = 0;
    while (cursor < directories.length) {
      if (epoch !== this.epoch || this.disposed) return collected;
      if (directories.length > MAX_DIRECTORIES) {
        this.log(`目录数超过 ${MAX_DIRECTORIES}，停止递归（相机返回异常？）`);
        break;
      }
      const directory: CanonDirectoryNode = directories[cursor];
      cursor += 1;
      const handles: number[] = await this.readObjectHandles(storageId, directory.handle);
      for (const handle of handles) {
        if (epoch !== this.epoch || this.disposed) return collected;
        if (examined >= MAX_OBJECTS) {
          this.log(`句柄数超过 ${MAX_OBJECTS}，停止枚举`);
          return collected;
        }
        examined += 1;
        const info: CanonObjectInfo | null = await this.readObjectInfo(handle);
        if (info === null) {
          skipped += 1;
          continue;
        }
        if (CanonImportService.isFolder(info)) {
          if (directory.depth + 1 <= MAX_DIRECTORY_DEPTH) {
            const child: CanonDirectoryNode = {
              handle: handle,
              depth: directory.depth + 1,
              groupId: CanonImportService.directoryNumber(info.name),
            };
            directories.push(child);
          } else {
            this.log(`目录深度超过 ${MAX_DIRECTORY_DEPTH}，跳过 ${this.brief(info.name)}`);
          }
          continue;
        }
        if (!CanonImportService.isGalleryMedia(info)) {
          skipped += 1;
          continue;
        }
        collected.push(this.toItem(storageId, handle, info, directory.groupId));
        if (collected.length % 25 === 0) {
          this.message = `已读取 ${collected.length} 个文件…`;
          this.revisionCounter += 1;
        }
      }
    }
    this.log(`storage=${storageId} dirs=${directories.length} objects=${examined} ` +
      `items=${collected.length} skipped=${skipped}`);
    return collected;
  }

  private async readObjectHandles(storageId: number, parent: number): Promise<number[]> {
    // 标准 `GetObjectHandles` 是 3 个参数：(storage, objectFormat=0 表示全部格式, parent)，
    // 见 libgphoto2 `ptp.c:ptp_getobjecthandles` 与尼康线同法。契约 §3.4 的包装签名
    // 只列 (storage, parent)，所以这里先按 3 参数发，参数类错误再退 2 参数。
    let reply: CanonPtpDataReply = await CanonPtpIp.opIn(CanonPtpCode.OP_GET_OBJECT_HANDLES,
      [storageId, 0, parent], COMMAND_TIMEOUT_MS);
    if (reply.reply.code === CanonPtpCode.RESPONSE_PARAMETER_NOT_SUPPORTED ||
      reply.reply.code === CanonPtpCode.RESPONSE_OPERATION_NOT_SUPPORTED) {
      this.log(`GetObjectHandles 3 参数 code=${CanonImportService.hexCode(reply.reply.code)}，试 2 参数`);
      reply = await CanonPtpIp.opIn(CanonPtpCode.OP_GET_OBJECT_HANDLES,
        [storageId, parent], COMMAND_TIMEOUT_MS);
    }
    if (reply.reply.code !== CanonPtpCode.RESPONSE_OK) {
      // 空目录/根目录在某些固件上回参数错而不是空表：按空目录处理，不让整卡失败。
      this.log(`GetObjectHandles(${parent}) code=${CanonImportService.hexCode(reply.reply.code)}，按空目录处理`);
      return [];
    }
    return CanonImportService.parseU32List(reply.data);
  }

  private async readObjectInfo(handle: number): Promise<CanonObjectInfo | null> {
    const reply: CanonPtpDataReply =
      await CanonPtpIp.opIn(CanonPtpCode.OP_GET_OBJECT_INFO, [handle], COMMAND_TIMEOUT_MS);
    if (reply.reply.code !== CanonPtpCode.RESPONSE_OK || reply.data.length < 53) {
      return null;
    }
    return CanonImportService.parseObjectInfo(handle, reply.data);
  }

  // -------------------------------------------------------------------------
  // 缩略图
  // -------------------------------------------------------------------------

  private queueMissingThumbs(): void {
    for (const item of this.items) {
      if (item.thumbUri.length > 0) continue;
      if (this.thumbFailed.has(item.imageId)) continue;
      this.thumbQueue.push(item.imageId);
    }
    if (this.thumbQueue.length > 0) {
      this.log(`thumb 队列 ${this.thumbQueue.length} 张`);
    }
  }

  private scheduleThumbTick(): void {
    if (this.disposed || this.thumbQueue.length === 0) return;
    if (this.thumbTimerId >= 0) return;
    const epoch: number = this.thumbEpoch;
    this.thumbTimerId = setTimeout((): void => {
      this.thumbTimerId = -1;
      void this.thumbTick(epoch);
    }, THUMB_TICK_DELAY_MS);
  }

  private clearThumbTimer(): void {
    if (this.thumbTimerId >= 0) {
      clearTimeout(this.thumbTimerId);
      this.thumbTimerId = -1;
    }
  }

  /** 后台每轮 6 张，串行请求；不阻塞渲染，也不与下载抢带宽。 */
  private async thumbTick(epoch: number): Promise<void> {
    if (this.disposed || epoch !== this.thumbEpoch) return;
    if (this.thumbRunning) {
      this.scheduleThumbTick();
      return;
    }
    if (this.downloadInProgress) {
      // 下载优先：本轮不抢带宽，由 `downloadSelected` 结束时重新排队。
      return;
    }
    this.thumbRunning = true;
    try {
      // 「每轮 6 张」按**请求次数**算：失败也计入，否则一张卡里失败的条目
      // 会让一轮循环把整条队列跑完（每张还等一个 15 s 超时）。
      let attempts: number = 0;
      let fetched: number = 0;
      while (attempts < THUMB_BATCH && this.thumbQueue.length > 0 &&
        !this.disposed && epoch === this.thumbEpoch) {
        const imageId: string | undefined = this.thumbQueue.shift();
        if (imageId === undefined) break;
        const item: CanonGalleryItem | null = this.findItem(imageId);
        if (item === null) continue;
        if (item.thumbUri.length > 0) continue;
        const cachedPath: string = this.thumbPathOf(item);
        if (this.fileExists(cachedPath)) {
          item.thumbUri = `file://${cachedPath}`;
          this.revisionCounter += 1;
          continue;
        }
        attempts += 1;
        try {
          const bytes: Uint8Array = await CanonImportService.fetchThumb(item);
          if (epoch !== this.thumbEpoch || this.disposed) return;
          if (bytes.length === 0) {
            // 失败只占位（thumbUri 保持空），不影响其它条目继续取。
            this.thumbFailed.add(imageId);
            this.revisionCounter += 1;
            this.log(`thumb 无数据 ${this.brief(item.name)}`);
            continue;
          }
          this.writeBytes(cachedPath, bytes);
          item.thumbUri = `file://${cachedPath}`;
          this.revisionCounter += 1;
          fetched += 1;
        } catch (error) {
          this.thumbFailed.add(imageId);
          this.revisionCounter += 1;
          this.log(`thumb 失败 ${this.brief(item.name)} ${String(error)}`);
        }
      }
      if (epoch === this.thumbEpoch && !this.disposed) {
        this.log(`thumb 本轮 ${fetched}/${attempts} 张，剩余 ${this.thumbQueue.length}`);
      }
    } finally {
      this.thumbRunning = false;
    }
    if (!this.disposed && epoch === this.thumbEpoch && this.thumbQueue.length > 0) {
      this.scheduleThumbTick();
    }
  }

  /** `GetThumbEx` 优先，标准 `GetThumb` 兜底；都失败返回空数组。 */
  private static async fetchThumb(item: CanonGalleryItem): Promise<Uint8Array> {
    let reply: CanonPtpDataReply =
      await CanonPtpIp.opIn(CanonPtpCode.OP_GET_THUMB_EX, [item.handle], THUMB_TIMEOUT_MS);
    if (reply.reply.code !== CanonPtpCode.RESPONSE_OK) {
      reply = await CanonPtpIp.opIn(CanonPtpCode.OP_GET_THUMB_EX, [item.handle, 0], THUMB_TIMEOUT_MS);
    }
    if (reply.reply.code !== CanonPtpCode.RESPONSE_OK) {
      reply = await CanonPtpIp.opIn(CanonPtpCode.OP_GET_THUMB, [item.handle], THUMB_TIMEOUT_MS);
    }
    if (reply.reply.code !== CanonPtpCode.RESPONSE_OK) return new Uint8Array(0);
    return reply.data;
  }

  // -------------------------------------------------------------------------
  // 下载
  // -------------------------------------------------------------------------

  /** 取消：置标记，由 `downloadOne` 在块间收尾（`EndGetPartialObjectEx`）并停在当前条目。 */
  cancelDownload(): void {
    if (!this.downloadInProgress) return;
    this.downloadCancelled = true;
    this.downloadStatus = '正在取消…';
    this.revisionCounter += 1;
    this.log('download 取消请求');
  }

  /** 逐张下载勾选条目：分块 1 MiB → 沙箱 `filesDir/canon/<原名>` → 相册。 */
  async downloadSelected(): Promise<void> {
    if (this.disposed || this.downloadInProgress) return;
    const targets: CanonGalleryItem[] = [];
    for (const item of this.items) {
      if (this.selected.has(item.imageId)) targets.push(item);
    }
    if (targets.length === 0) {
      this.message = '请先选择要下载的照片';
      this.revisionCounter += 1;
      return;
    }
    this.downloadInProgress = true;
    this.downloadCancelled = false;
    this.downloadProgress = 0;
    this.downloadSaved = 0;
    this.downloadFailed = 0;
    this.downloadAlbum = 0;
    this.downloadCurrent = 0;
    this.downloadTotal = targets.length;
    this.downloadStatus = `准备下载 ${targets.length} 个文件…`;
    this.setPhase(CanonImportPhase.DOWNLOADING, this.downloadStatus);

    let totalBytes: number = 0;
    for (const item of targets) {
      if (item.size > 0) totalBytes += item.size;
    }
    let doneBytes: number = 0;
    this.log(`download 开始 count=${targets.length} bytes=${totalBytes}`);

    for (let index: number = 0; index < targets.length; index++) {
      if (this.downloadCancelled || this.disposed) break;
      const item: CanonGalleryItem = targets[index];
      this.downloadCurrent = index + 1;
      this.downloadStatus = `正在下载 ${index + 1}/${targets.length} · ${this.brief(item.name)}`;
      this.downloadProgress = CanonImportService.overallPercent(doneBytes, totalBytes, index,
        targets.length);
      this.revisionCounter += 1;
      try {
        const path: string = await this.downloadOne(item, (received: number): void => {
          this.downloadProgress = CanonImportService.progressPercent(doneBytes, totalBytes,
            index, targets.length, item.size, received);
          this.revisionCounter += 1;
        });
        this.downloaded.set(item.imageId, `file://${path}`);
        this.downloadSaved += 1;
        const inAlbum: boolean = await this.saveToGallery(path, item);
        if (inAlbum) {
          this.downloadAlbum += 1;
          this.log(`download 完成 ${this.brief(item.name)} 已入相册`);
        } else {
          this.log(`download 完成 ${this.brief(item.name)} 仅沙箱（相册写入失败）`);
        }
        if (item.size > 0) doneBytes += item.size;
      } catch (error) {
        if (this.downloadCancelled) break;
        this.downloadFailed += 1;
        this.log(`download 失败 ${this.brief(item.name)} ${String(error)}`);
      }
    }

    if (this.downloadCancelled) {
      this.downloadStatus = `已取消：完成 ${this.downloadSaved}，相册 ${this.downloadAlbum}，` +
        `失败 ${this.downloadFailed}（停在当前条目）`;
    } else if (this.downloadFailed > 0) {
      this.downloadStatus = `完成：成功 ${this.downloadSaved}，相册 ${this.downloadAlbum}，` +
        `失败 ${this.downloadFailed}`;
    } else {
      this.downloadStatus = `完成：成功 ${this.downloadSaved}，相册 ${this.downloadAlbum}`;
    }
    this.downloadProgress = this.downloadCancelled ? this.downloadProgress : 100;
    this.downloadInProgress = false;
    this.setPhase(CanonImportPhase.READY, this.downloadStatus);
    this.scheduleThumbTick();
    this.log(this.downloadStatus);
  }

  /**
   * 单个文件：先取首块确认分块可用；不可用时按契约 §3.4 回退整包 `GetObject`。
   * 取消/失败都会删临时文件并 `EndGetPartialObjectEx`。
   */
  private async downloadOne(item: CanonGalleryItem,
    onProgress: (received: number) => void): Promise<string> {
    const extension: string = CanonImportService.extension(item.name);
    const finalName: string = CanonImportService.safeFileName(item.name,
      extension.length > 0 ? extension : (item.isVideo ? 'mp4' : 'jpg'));
    const finalPath: string = this.uniquePath(this.downloadDir, finalName);
    const tempPath: string = `${this.downloadDir}/.${item.storageId}_${item.handle}_` +
      `${Date.now()}.part`;
    const total: number = item.size;
    let received: number = 0;
    let success: boolean = false;
    try {
      const file = fileIo.openSync(tempPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      let chunked: boolean = true;
      try {
        let head: Uint8Array = new Uint8Array(0);
        try {
          const ask: number = total > 0 ? Math.min(CHUNK_BYTES, total) : CHUNK_BYTES;
          head = await this.readPartial(item.handle, 0, ask);
        } catch (error) {
          chunked = false;
          this.log(`分块不可用 ${this.brief(item.name)}，试整包 ${String(error)}`);
        }
        if (!chunked) {
          const whole: Uint8Array = await this.readWholeObject(item.handle, total);
          if (whole.length === 0) throw new Error('整包读取也失败');
          received = this.writeChunk(file.fd, whole, total, 0);
          onProgress(received);
        } else {
          if (head.length === 0) throw new Error('分块首包无数据');
          received = this.writeChunk(file.fd, head, total, 0);
          onProgress(received);
          let chunks: number = 1;
          while (!this.downloadCancelled && !this.disposed) {
            if (total > 0 && received >= total) break;
            const remaining: number = total > 0 ? total - received : CHUNK_BYTES;
            const ask: number = Math.min(CHUNK_BYTES, remaining);
            const chunk: Uint8Array = await this.readPartial(item.handle, received, ask);
            if (chunk.length === 0) {
              if (total > 0) throw new Error(`分块空数据 ${received}/${total}`);
              break;
            }
            received = this.writeChunk(file.fd, chunk, total, received);
            chunks += 1;
            onProgress(received);
            if (chunks % 8 === 0) {
              this.log(`chunk h=${item.handle} 已收 ${received}/${total}`);
            }
          }
        }
      } finally {
        fileIo.closeSync(file);
      }
      if (this.downloadCancelled || this.disposed) throw new Error('已取消');
      if (total > 0 && received !== total) {
        throw new Error(`大小不符 ${received}/${total}`);
      }
      if (received <= 0) throw new Error('空文件');
      const stat = fileIo.statSync(tempPath);
      if (Number(stat.size) !== received) {
        throw new Error(`落盘大小不符 ${Number(stat.size)}/${received}`);
      }
      fileIo.renameSync(tempPath, finalPath);
      success = true;
      this.log(`download 落盘 ${this.brief(finalName)} bytes=${received}`);
      return finalPath;
    } finally {
      if (!success) this.deleteFile(tempPath);
      // 成功也要通知相机结束分块：libgphoto2 `ptp.c:3861` 明确「结束后需要
      // end transfer」。放在 finally 里保证取消/失败/成功三种路径都收尾。
      await this.endPartial(item.handle);
    }
  }

  /** 分块请求；4 参数（`ptp.c:3904`）被明确拒绝时改 3 参数并记住，避免每块重试两次。 */
  private async readPartial(handle: number, offset: number, length: number): Promise<Uint8Array> {
    const timeout: number = CanonImportService.chunkTimeout(length);
    let reply: CanonPtpDataReply;
    if (this.partialArgs >= 4) {
      reply = await CanonPtpIp.opIn(CanonPtpCode.OP_GET_PARTIAL_OBJECT_EX,
        [handle, offset, length, 0], timeout);
    } else {
      reply = await CanonPtpIp.opIn(CanonPtpCode.OP_GET_PARTIAL_OBJECT_EX,
        [handle, offset, length], timeout);
    }
    if (this.partialArgs >= 4 && (reply.reply.code === CanonPtpCode.RESPONSE_PARAMETER_NOT_SUPPORTED ||
      reply.reply.code === CanonPtpCode.RESPONSE_OPERATION_NOT_SUPPORTED)) {
      this.partialArgs = 3;
      this.log(`GetPartialObjectEx 4 参数 code=${CanonImportService.hexCode(reply.reply.code)}，改 3 参数`);
      reply = await CanonPtpIp.opIn(CanonPtpCode.OP_GET_PARTIAL_OBJECT_EX,
        [handle, offset, length], timeout);
    }
    if (reply.reply.code !== CanonPtpCode.RESPONSE_OK) {
      throw new Error(`GetPartialObject code=${CanonImportService.hexCode(reply.reply.code)} ` +
        `offset=${offset} len=${length}`);
    }
    return reply.data;
  }

  /** 整包回退；超过内存上限直接放弃（返回空数组，由调用方报错）。 */
  private async readWholeObject(handle: number, total: number): Promise<Uint8Array> {
    if (total > WHOLE_OBJECT_LIMIT) {
      this.log(`整包回退跳过：size=${total} 超过 ${WHOLE_OBJECT_LIMIT}`);
      return new Uint8Array(0);
    }
    let reply: CanonPtpDataReply =
      await CanonPtpIp.opIn(CanonPtpCode.OP_GET_OBJECT_EOS, [handle], WHOLE_TIMEOUT_MS);
    if (reply.reply.code !== CanonPtpCode.RESPONSE_OK || reply.data.length === 0) {
      this.log(`GetObject(0x9104) code=${CanonImportService.hexCode(reply.reply.code)}，试 0x1009`);
      reply = await CanonPtpIp.opIn(CanonPtpCode.OP_GET_OBJECT, [handle], WHOLE_TIMEOUT_MS);
    }
    if (reply.reply.code !== CanonPtpCode.RESPONSE_OK) return new Uint8Array(0);
    return reply.data;
  }

  /** 收尾/取消都通知相机结束分块传输；失败只记日志。 */
  private async endPartial(handle: number): Promise<void> {
    try {
      const reply: CanonPtpReply =
        await CanonPtpIp.op(CanonPtpCode.OP_END_PARTIAL_OBJECT_EX, [handle]);
      if (reply.code !== CanonPtpCode.RESPONSE_OK) {
        this.log(`EndGetPartialObject h=${handle} code=${CanonImportService.hexCode(reply.code)}`);
      }
    } catch (error) {
      this.log(`EndGetPartialObject h=${handle} 异常 ${String(error)}`);
    }
  }

  /** 写入系统相册；失败只记日志（契约：不影响沙箱文件保存）。 */
  private async saveToGallery(path: string, item: CanonGalleryItem): Promise<boolean> {
    try {
      const size: number = Number(fileIo.statSync(path).size);
      if (size <= 0) return false;
      const helper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const extension: string = CanonImportService.extension(item.name);
      const target: string = await helper.createAsset(
        item.isVideo ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE,
        extension.length > 0 ? extension : (item.isVideo ? 'mp4' : 'jpg'),
        { title: CanonImportService.baseName(item.name) });
      const copied: number = await CanonImportService.copyFileChunked(path, target);
      if (copied !== size) throw new Error(`相册写入 ${copied}/${size}`);
      return true;
    } catch (error) {
      this.log(`相册写入失败 ${this.brief(item.name)} ${String(error)}`);
      return false;
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
        const view: ArrayBuffer = read === chunk.byteLength ? chunk : chunk.slice(0, read);
        let written: number = 0;
        while (written < read) {
          const part: ArrayBuffer = written === 0 ? view : view.slice(written);
          const count: number = fileIo.writeSync(output.fd, part);
          if (count <= 0) throw new Error('相册写入中断');
          written += count;
        }
        copied += read;
        await CanonImportService.yieldToUi();
      }
    } finally {
      fileIo.closeSync(source);
      fileIo.closeSync(output);
    }
    return copied;
  }

  /** 让出一次事件循环（大文件写相册时页面仍在轮询）。 */
  private static yieldToUi(): Promise<void> {
    return new Promise<void>((resolve): void => {
      setTimeout(resolve, 0);
    });
  }

  // -------------------------------------------------------------------------
  // 解析 / 工具
  // -------------------------------------------------------------------------

  private static parseObjectInfo(handle: number, data: Uint8Array): CanonObjectInfo | null {
    if (data.length < 53) return null;
    // 偏移见 libgphoto2 ptp-pack.c:401-417（标准 PTP ObjectInfo 数据集）。
    const storageId: number = CanonImportService.readU32(data, 0);
    const format: number = CanonImportService.readU16(data, 4);
    const size: number = CanonImportService.readU32(data, 8);
    const parent: number = CanonImportService.readU32(data, 38);
    const filename: CanonStringField = CanonImportService.readPtpString(data, 52);
    const capture: CanonStringField = CanonImportService.readPtpString(data, filename.next);
    const parsed: CanonObjectInfo = {
      handle: handle,
      storageId: storageId,
      format: format,
      size: size,
      parent: parent,
      name: filename.value,
      dateMs: CanonImportService.parsePtpDate(capture.value),
    };
    return parsed;
  }

  /**
   * 标准 StorageInfo（`ptp-pack.c:367-396`）：
   * u16 StorageType / u16 FilesystemType / u16 AccessCapability /
   * u64 MaxCapability / u64 FreeSpaceInBytes / u32 FreeSpaceInImages / 两个字符串。
   */
  private static parseStorageInfo(data: Uint8Array): CanonStorageInfo {
    const info: CanonStorageInfo = CanonImportService.emptyStorageInfo();
    if (data.length < 26) return info;
    info.storageType = CanonImportService.readU16(data, 0);
    info.access = CanonImportService.readU16(data, 4);
    info.capacityBytes = CanonImportService.readU64(data, 6);
    info.freeBytes = CanonImportService.readU64(data, 14);
    const description: CanonStringField = CanonImportService.readPtpString(data, 26);
    const volumeLabel: CanonStringField = CanonImportService.readPtpString(data, description.next);
    const label: string = volumeLabel.value.trim();
    const fallback: string = description.value.trim();
    info.label = label.length > 0 ? label : fallback;
    // 体积必须是自洽的，否则说明这个数据集不是标准 StorageInfo（EOS 0x9102 可能自带前缀）。
    info.valid = info.capacityBytes > 0 && info.freeBytes <= info.capacityBytes;
    return info;
  }

  private static emptyStorageInfo(): CanonStorageInfo {
    return {
      valid: false,
      storageType: 0,
      access: 0,
      capacityBytes: 0,
      freeBytes: 0,
      label: '',
    };
  }

  /**
   * 建条目。`imageId` 必须带 storageId（多卡句柄空间独立）；缩略图命中缓存时
   * 直接把 `file://` 路径给页面，不再发 `GetThumbEx`（报告 03 §5 的缓存命中）。
   */
  private toItem(storageId: number, handle: number, info: CanonObjectInfo,
    groupId: number): CanonGalleryItem {
    const cachedPath: string = `${this.thumbDir}/${storageId}_${handle}.jpg`;
    const item: CanonGalleryItem = {
      imageId: `${storageId}:${handle}`,
      storageId: storageId,
      handle: handle,
      name: info.name,
      size: info.size,
      dateMs: info.dateMs,
      format: info.format,
      isVideo: CanonImportService.isVideo(info),
      isRaw: CanonImportService.isRaw(info),
      groupId: groupId,
      thumbUri: this.fileExists(cachedPath) ? `file://${cachedPath}` : '',
    };
    return item;
  }

  /** 文件夹：`0x3001` Association，或 ObjectInfo 的 format=0（报告 03 §2.2 的 mIsFolder）。 */
  private static isFolder(info: CanonObjectInfo): boolean {
    return info.format === CanonPtpCode.FORMAT_ASSOCIATION || info.format === 0;
  }

  /**
   * 条目是否进图库。依据报告 03 §2.2 的过滤：
   * - `REEL` 开头的特殊对象跳过；
   * - `mp4` 且 size=0 的占位跳过；
   * - WAV/XML/TXT/DAT 等音频/元数据不入图库（格式码或扩展名任一命中即跳过）。
   */
  private static isGalleryMedia(info: CanonObjectInfo): boolean {
    if (info.name.length === 0) return false;
    if (info.name.charAt(0) === '.') return false;
    const upper: string = info.name.toUpperCase();
    if (upper.indexOf('REEL') === 0) return false;
    const extension: string = CanonImportService.extension(info.name);
    if (extension === 'mp4' && info.size === 0) return false;
    if (NON_MEDIA_EXTENSIONS.indexOf(extension) >= 0) return false;
    if (info.format === CanonPtpCode.FORMAT_TEXT || info.format === CanonPtpCode.FORMAT_DPOF ||
      info.format === CanonPtpCode.FORMAT_WAV || info.format === CanonPtpCode.FORMAT_MP3 ||
      info.format === CanonPtpCode.FORMAT_XML_DOCUMENT) {
      return false;
    }
    return true;
  }

  private static isVideo(info: CanonObjectInfo): boolean {
    if (CanonImportService.isVideoFormat(info.format)) return true;
    return VIDEO_EXTENSIONS.indexOf(CanonImportService.extension(info.name)) >= 0;
  }

  /** 视频容器格式（`ptp.h:1552-1556` 的 MP3/AVI/MPEG/ASF/QT 与 MTP MP4）。 */
  static isVideoFormat(format: number): boolean {
    return format === CanonPtpCode.FORMAT_AVI || format === CanonPtpCode.FORMAT_MPEG ||
      format === CanonPtpCode.FORMAT_ASF || format === CanonPtpCode.FORMAT_QT ||
      format === CanonPtpCode.FORMAT_MP4;
  }

  private static isRaw(info: CanonObjectInfo): boolean {
    if (info.format === CanonPtpCode.FORMAT_CANON_CRW ||
      info.format === CanonPtpCode.FORMAT_CANON_CRW3 ||
      info.format === CanonPtpCode.FORMAT_CANON_CR3) {
      return true;
    }
    return RAW_EXTENSIONS.indexOf(CanonImportService.extension(info.name)) >= 0;
  }

  /** 目录名 `100CANON` → 100；不是这种命名就 0（只用于展示分组，不参与协议）。 */
  private static directoryNumber(name: string): number {
    if (name.length < 3) return 0;
    const head: string = name.substring(0, 3);
    if (!/^\d{3}$/.test(head)) return 0;
    const value: number = Number(head);
    return Number.isFinite(value) ? value : 0;
  }

  private static parseU32List(data: Uint8Array): number[] {
    if (data.length < 4) return [];
    const declared: number = CanonImportService.readU32(data, 0);
    const available: number = Math.floor((data.length - 4) / 4);
    const count: number = Math.min(declared, available);
    const values: number[] = [];
    for (let index: number = 0; index < count; index++) {
      values.push(CanonImportService.readU32(data, 4 + index * 4));
    }
    return values;
  }

  /** PTP 字符串：u8 字符数（含 NUL）+ UTF-16LE。 */
  private static readPtpString(data: Uint8Array, offset: number): CanonStringField {
    if (offset >= data.length) {
      return { value: '', next: data.length };
    }
    const count: number = data[offset];
    const end: number = Math.min(data.length, offset + 1 + count * 2);
    let value: string = '';
    for (let index: number = 0; index + 1 < count && offset + 1 + index * 2 + 1 < end; index++) {
      value += String.fromCharCode(data[offset + 1 + index * 2] |
        (data[offset + 2 + index * 2] << 8));
    }
    return { value: value, next: end };
  }

  /** PTP 日期 `YYYYMMDDThhmmss[.s]` → 毫秒（相机本地时间，按本地时区还原）。 */
  private static parsePtpDate(raw: string): number {
    // 少数机型给的是 `2024-01-02T03:04:05`，先抹掉分隔符再统一按紧凑格式读。
    const compact: string = raw.trim().replace(/-/g, '').replace(/:/g, '');
    if (compact.length < 15) return 0;
    const mark: string = compact.charAt(8);
    if (mark !== 'T' && mark !== 't') return 0;
    const digits: string = compact.substring(0, 8) + compact.substring(9);
    if (!/^\d{14}/.test(digits)) return 0;
    const year: number = Number(digits.substring(0, 4));
    const month: number = Number(digits.substring(4, 6));
    const day: number = Number(digits.substring(6, 8));
    const hour: number = Number(digits.substring(8, 10));
    const minute: number = Number(digits.substring(10, 12));
    const second: number = Number(digits.substring(12, 14));
    if (month < 1 || month > 12 || day < 1 || day > 31) return 0;
    const ms: number = new Date(year, month - 1, day, hour, minute, second).getTime();
    return Number.isFinite(ms) ? ms : 0;
  }

  /** 百分比：整批按字节加权；未知大小时按条目数。 */
  private static progressPercent(doneBytes: number, totalBytes: number, index: number,
    count: number, itemSize: number, received: number): number {
    if (totalBytes > 0) {
      const current: number = doneBytes + Math.min(received, itemSize > 0 ? itemSize : received);
      return Math.min(99, Math.round(current * 100 / totalBytes));
    }
    const within: number = itemSize > 0 ? Math.min(1, received / itemSize) : 0;
    return Math.min(99, Math.round((index + within) * 100 / count));
  }

  private static overallPercent(doneBytes: number, totalBytes: number, index: number,
    count: number): number {
    if (totalBytes > 0) return Math.min(99, Math.round(doneBytes * 100 / totalBytes));
    return Math.round(index * 100 / count);
  }

  /** 1 MiB 分块的超时：契约 §3.2 的 15 s 起步，按块大小线性放宽，封顶 120 s。 */
  private static chunkTimeout(bytes: number): number {
    const extra: number = Math.round(bytes / 1024) * 2;
    return Math.max(THUMB_TIMEOUT_MS, Math.min(120000, 20000 + extra));
  }

  /** `CanonPtpIp.connect` 的 host：页面/入口写入 AppStorage，取不到再问系统网关。 */
  private static async resolveHost(): Promise<string> {
    const keys: string[] = ['canonHost', 'canonCameraHost', 'syncControlHost'];
    for (const key of keys) {
      const raw: string | undefined = AppStorage.get<string>(key);
      const host: string = CanonImportService.cleanHost(raw ?? '');
      if (host.length > 0) return host;
    }
    const linked: string = await LumixCameraService.linkedGateway();
    return CanonImportService.cleanHost(linked);
  }

  private static cleanHost(raw: string): string {
    return raw.trim().replace(/^https?:\/\//, '').replace(/\/$/, '');
  }

  private static maskHost(host: string): string {
    if (host.length === 0) return '(none)';
    return host.replace(/(\d+\.\d+\.\d+)\.\d+$/, '$1.x');
  }

  private static hexCode(value: number): string {
    return '0x' + value.toString(16).padStart(4, '0').toUpperCase();
  }

  static sizeText(bytes: number): string {
    if (bytes <= 0) return '—';
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }

  private static extension(name: string): string {
    const dot: number = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  private static baseName(name: string): string {
    const dot: number = name.lastIndexOf('.');
    const base: string = dot > 0 ? name.substring(0, dot) : name;
    return base.length > 0 ? base : `CANON_${Date.now()}`;
  }

  private static safeFileName(rawName: string, extension: string): string {
    let name: string = rawName.trim();
    if (name.length === 0) name = `CANON_${Date.now()}.${extension}`;
    name = name.replace(/[\\/:*?"<>|]/g, '_');
    const dot: number = name.lastIndexOf('.');
    if (dot <= 0 || dot >= name.length - 1) {
      name = `${name}.${extension.length > 0 ? extension : 'jpg'}`;
    }
    return name;
  }

  private static readU16(data: Uint8Array, offset: number): number {
    if (offset + 1 >= data.length) return 0;
    return data[offset] | (data[offset + 1] << 8);
  }

  private static readU32(data: Uint8Array, offset: number): number {
    if (offset + 3 >= data.length) return 0;
    return (data[offset] | (data[offset + 1] << 8) |
      (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
  }

  private static readU64(data: Uint8Array, offset: number): number {
    const low: number = CanonImportService.readU32(data, offset);
    const high: number = CanonImportService.readU32(data, offset + 4);
    return high * 4294967296 + low;
  }

  private static exactBuffer(data: Uint8Array): ArrayBuffer {
    const copy: Uint8Array = new Uint8Array(data.length);
    copy.set(data);
    return copy.buffer;
  }

  private thumbPathOf(item: CanonGalleryItem): string {
    return `${this.thumbDir}/${item.storageId}_${item.handle}.jpg`;
  }

  private findItem(imageId: string): CanonGalleryItem | null {
    for (const item of this.items) {
      if (item.imageId === imageId) return item;
    }
    return null;
  }

  private volumeKnown(storageId: number): boolean {
    for (const volume of this.volumes) {
      if (volume.storageId === storageId) return true;
    }
    return false;
  }

  private writeChunk(fd: number, data: Uint8Array, total: number, received: number): number {
    let payload: Uint8Array = data;
    if (total > 0 && received + payload.length > total) {
      payload = payload.slice(0, total - received);
    }
    this.writeAll(fd, payload);
    return received + payload.length;
  }

  private writeAll(fd: number, data: Uint8Array): void {
    const buffer: ArrayBuffer = CanonImportService.exactBuffer(data);
    let written: number = 0;
    while (written < buffer.byteLength) {
      const part: ArrayBuffer = written === 0 ? buffer : buffer.slice(written);
      const count: number = fileIo.writeSync(fd, part);
      if (count <= 0) throw new Error('写入中断');
      written += count;
    }
  }

  private setPhase(phase: string, message: string): void {
    this.phase = phase;
    this.message = message;
    this.revisionCounter += 1;
  }

  private fail(message: string): void {
    this.error = message;
    this.phase = CanonImportPhase.ERROR;
    this.message = message;
    this.loading = false;
    this.revisionCounter += 1;
    this.log(message);
  }

  private ensureDir(path: string): void {
    try {
      fileIo.statSync(path);
    } catch (_error) {
      try {
        fileIo.mkdirSync(path, true);
      } catch (mkdirError) {
        this.log(`mkdir ${path} 失败 ${String(mkdirError)}`);
      }
    }
  }

  private writeBytes(path: string, data: Uint8Array): void {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      this.writeAll(file.fd, data);
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

  /** 日志里的文件名：只留前 12 个字符 + 扩展名（契约 §0 铁律 6：不打印完整文件名）。 */
  private brief(name: string): string {
    const dot: number = name.lastIndexOf('.');
    const extension: string = dot >= 0 ? name.substring(dot) : '';
    const base: string = dot >= 0 ? name.substring(0, dot) : name;
    const head: string = base.length > 12 ? `${base.substring(0, 12)}…` : base;
    return `${head}${extension}`;
  }

  private log(message: string): void {
    AppLogSink.emit(CANON_IMG_TAG, message);
  }
}
