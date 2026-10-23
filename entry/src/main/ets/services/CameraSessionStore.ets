import { LumixGalleryItem } from './LumixImportPrototype';
import { LumixCameraService } from './LumixCameraService';

/** 回调接口：图片传输页面只做渲染与手势，会话编排放由 Index 提供。 */
export interface CameraSessionDriver {
  fetchMoreGallery: () => Promise<void>;
  triggerScrollLoad: () => Promise<void>;
  startImageTransfer: () => Promise<void>;
  endSession: () => Promise<void>;
  closeWifi: () => Promise<void>;
  closePreview: () => void;
  openPreview: (item: LumixGalleryItem) => Promise<void>;
  toggleSelection: (imageId: string) => void;
  downloadSelected: () => Promise<void>;
  switchSd: (sd: string) => Promise<void>;
}

/**
 * 相机会话共享状态单例。Index 与图片传输页面持有同一个实例，
 * 通过 @Observed + @Track 实现跨页面响应式刷新；未被 @Track 标记的
 * 字段只作为普通共享数据使用，不参与 UI 依赖收集。
 */
@Observed
export class CameraSessionStore {
  static readonly instance: CameraSessionStore = new CameraSessionStore();

  /** 由 Index 在 aboutToAppear 中注册。 */
  driver: CameraSessionDriver | null = null;

  @Track cameraState: number = 0;
  @Track cameraModel: string = 'LUMIX';
  @Track cameraBrand: string = 'Panasonic';
  @Track cameraMessage: string = '等待连接';
  @Track cameraWifiSsid: string = '';
  @Track cameraImageKey: string = '';
  @Track cameraBleStatus: string = '未连接';
  @Track cameraWifiStatus: string = '未连接';
  @Track cameraSessionStatus: string = '未建立';
  @Track cameraBleCandidateName: string = '';
  @Track cameraBleCandidateModel: string = '';
  @Track cameraTransferInProgress: boolean = false;

  @Track cameraGalleryItems: LumixGalleryItem[] = [];
  /** 相机上报的尼康存储卡槽号（按卡槽顺序，**含空卡**）。
   *
   * 界面用它决定显示几个「卡 N」切换按钮。不能从 `cameraGalleryItems` 反推：
   * 空卡没有任何条目，反推会漏掉它，用户会以为那张卡没被读到。 */
  @Track nikonStorageIds: number[] = [];
  @Track cameraGalleryTotal: number = 0;
  @Track cameraGalleryHasMore: boolean = false;
  @Track cameraGalleryLoading: boolean = false;
  @Track selectedCameraImageIds: string[] = [];

  @Track cameraDownloadInProgress: boolean = false;
  @Track cameraDownloadProgress: number = 0;
  @Track cameraDownloadStatus: string = '';

  @Track cameraPreviewVisible: boolean = false;
  @Track cameraPreviewLoading: boolean = false;
  @Track cameraPreviewUri: string = '';
  @Track cameraPreviewScale: number = 1;
  /** 预览的是视频（Sync 线直接流式播放相机 res URL，不落盘）。 */
  @Track cameraPreviewIsVideo: boolean = false;

  @Track s5Receiving: boolean = false;
  @Track s5ReceiveProgress: number = 0;
  @Track s5ReceiveStatus: string = '';
  @Track s5ReceiveFiles: number = 0;

  /** 松下双卡槽机型当前浏览的存储卡，SD1/SD2（getstate current_sd 校准）。 */
  @Track selectedSd: string = 'SD1';
  /** 卡槽在位状态（getstate sd_memory/sd2_memory = set/unset）。 */
  @Track cameraSd1Present: boolean = true;
  @Track cameraSd2Present: boolean = false;
  /** 上述在位标志的来源：'none'（未知）/ 'sync-probe'（cam.cgi 的
   *  sd_memory/sd2_memory）/ 'lab-current-sd'（Lab 线 current-sd 成功应答）。
   *  问题反馈据此区分"卡不在位"与"这条线还没拿到在位状态"；未知时按钮不禁用。 */
  @Track cameraSdPresenceSource: string = 'none';

  /** Sync 线主动拉取路线标记：图片传输页据此显示主动读取文案与重试按钮，
   *  与被动推送（isPassivePushSelected）区分。由控制页入口置 true、首页入口复位。 */
  @Track syncPullActive: boolean = false;

  /** 底部驻留标记：分页续拉逻辑据此判断是否继续自动加载。 */
  cameraGalleryAtBottomEdge: boolean = false;

  /** 仅原版 S5 走相机主动推送的 Wi‑Fi 通道。 */
  isOriginalS5Selected(): boolean {
    if (this.cameraBrand !== 'Panasonic') return false;
    // 正在配对的 BLE 机身若明确是 Lab 机型，就不按"初代 S5（仅 Wi-Fi）"处理：
    // BLE 广播名是当下最可信的身份，机型串里可能残留上一次配对的 S5，否则
    // S1RM2 会被判成 S5 而整条落到 sync 线。
    if (LumixCameraService.panasonicRouteForModel(this.cameraBleCandidateName) === 'lab' ||
      LumixCameraService.panasonicRouteForModel(this.cameraBleCandidateModel) === 'lab') return false;
    return LumixCameraService.isOriginalS5WifiSsid(this.cameraWifiSsid) ||
      LumixCameraService.isOriginalS5WifiSsid(this.cameraBleCandidateName) ||
      LumixCameraService.isOriginalS5WifiSsid(this.cameraBleCandidateModel) ||
      (this.cameraImageKey === 'panasonic_s5' && LumixCameraService.isWifiOnlyModel(this.cameraModel));
  }

  /** 当前选中相机的松下路线：'lab' | 'sync' | 'lumix_image' | ''。 */
  panasonicLine(): string {
    if (this.cameraBrand !== 'Panasonic') return '';
    // BLE 观察到（已发现/已连接）的机身若不是 Lab 机型，按目标口径归 Sync；
    // 只有 SSID 的机身仍走机型表，未收录的落 Image App。
    const fromBle = this.cameraBleStatus === '已发现' || this.cameraBleStatus === '已连接';
    return LumixCameraService.panasonicRouteForModel(
      `${this.cameraModel} ${this.cameraBleCandidateModel} ${this.cameraBleCandidateName}`, fromBle);
  }

  /**
   * cam.cgi 家族（Sync 线 + lumix_image 线）。
   *
   * 这两条线共用同一套相机控制协议（cam.cgi）与同一套图片通道（DLNA/DMS），
   * 与 Lab 线的 REST-over-AP 不同；二者唯一的区别是 Wi‑Fi 凭据由谁下发：
   * Sync 由 BLE 下发，lumix_image 由用户手动选择（或二维码/NFC）。因此绝大多数
   * UI 分支（"是不是 Lab REST 路线"）应当用本方法，而不是单看 Sync。
   */
  isCamCgiLineSelected(): boolean {
    if (this.cameraBrand !== 'Panasonic') return false;
    if (this.isOriginalS5Selected()) return true;
    const line = this.panasonicLine();
    return line === 'sync' || line === 'lumix_image';
  }

  /**
   * Sync 线：与 Lab 相同的连接模式——先蓝牙配对，用户点击"图像传输"或
   * "相机控制"时才按 BLE 回传的 SSID/密码拉起并连接相机 Wi‑Fi，随后主动拉取。
   * 不再保留"仅连 Wi‑Fi、被动等相机推图"的模式；该模式属于 lumix_image 线。
   */
  isSyncRouteSelected(): boolean {
    if (this.cameraBrand !== 'Panasonic') return false;
    if (this.isOriginalS5Selected()) return true;
    return this.panasonicLine() === 'sync';
  }

  /**
   * lumix_image 线（旧 Image App / Lumix Link 2.0，无蓝牙）：用户手动连接相机
   * 热点，SSDP 发现 + cam.cgi 控制 + DLNA 浏览，并保留相机端被动推送。
   */
  isImageAppSelected(): boolean {
    return this.cameraBrand === 'Panasonic' && this.panasonicLine() === 'lumix_image';
  }

  /**
   * 相机端被动推送（我们只监听、等相机把图送过来）。这是 lumix_image 线的模式；
   * Sync 线已改为与 Lab 一样的主动拉取。
   */
  isPassivePushSelected(): boolean {
    return this.isImageAppSelected();
  }

  /** 兼容旧名：旧名表达的是"非 Lab 的 cam.cgi 家族 UI"，语义见 isCamCgiLineSelected。 */
  isSyncPushSelected(): boolean {
    return this.isCamCgiLineSelected();
  }

  /**
   * 富士线（XApp 2.7.0 路线）：BLE 配对/凭据 + PTP-IP（55740/55741/55742）。
   *
   * 只新增判断，不改任何松下分支：`cameraBrand` 只有富士线会写成 `'FUJIFILM'`
   * （CameraPage 的扫描/卡片统一用这个字符串）。控制页与图片传输页据此选择
   * 富士自己的服务，而不是落进松下的 Lab / Sync 分支。
   */
  isFujifilmSelected(): boolean {
    return this.cameraBrand === 'FUJIFILM';
  }
}
