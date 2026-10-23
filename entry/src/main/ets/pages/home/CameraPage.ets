import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { statfs, fileIo } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import usbManager from '@ohos.usbManager';
import { ExifOrientation } from '../../edit/utils/ExifOrientation';
import { LumixCameraService,
  LumixProbeResult,
  LumixWifiCandidate,
  LumixWifiConnectionResult,
  LumixUsbConnectionResult,
} from '../../services/LumixCameraService';
import { LumixImportPrototype, LumixImportResult, LumixImportPhaseUpdate, LumixBleCameraCandidate, LumixGalleryItem, LumixGalleryRefresh } from '../../services/LumixImportPrototype';
import { LumixFirmwareService, LumixFirmwareProgress, FirmwareCatalogEntry, LumixFirmwareVersionState, LumixFirmwareDetail } from '../../services/LumixFirmwareService';
import { LumixWebFirmware } from '../../services/LumixFirmwareWebSource';
import { LumixSyncControlService } from '../../services/LumixSyncControlService';
import { LumixSyncGalleryDriver, LumixSyncImageTransfer } from '../../services/LumixSyncImageTransfer';
import { AppDiagnostics } from '../../services/AppDiagnostics';
import { NikonCameraService } from '../../services/NikonCameraService';
import { SonyCameraService } from '../../services/SonyCameraService';
import { NikonPtpIpService, NikonPtpCatalogResult, NikonPtpGalleryItem, NikonPtpGalleryPage } from '../../services/NikonPtpIpService';
import { SonyPtpIpContent, SonyCatalogResult, SonyContentEntry } from '../../services/SonyPtpIpContent';
import { SonyUsbPtp, SonyUsbProbe } from '../../services/SonyUsbPtp';
import { NikonBleProvisioning, NikonProvisionResult } from '../../services/NikonBleProvisioning';
import { NikonUsbPtp, NikonUsbProbe } from '../../services/NikonUsbPtp';
import { SonyBleProvisioning, SonyProvisionResult } from '../../services/SonyBleProvisioning';
import { SonyConnectionDiagnostics, SonyDiagContext, SonyDiagReport } from '../../services/SonyConnectionDiagnostics';
import { PanasonicS5Receiver, PanasonicS5ReceivedFile } from '../../services/PanasonicS5Receiver';
import { CameraSessionStore, CameraSessionDriver } from '../../services/CameraSessionStore';
import { CameraCardRegistry } from '../../services/CameraCardRegistry';
import wifiManager from '@ohos.wifiManager';
import bluetoothAccess from '@ohos.bluetooth.access';
import { VividMaterial } from '../../components/VividMaterial';
import { CameraWifiPasswordDialog, CameraWifiPasswordDialogOptions } from '../../components/CameraWifiPasswordDialog';
import { CameraWifiPasswordPolicy } from '../../services/CameraWifiPasswordPolicy';
import { NikonGallerySection } from './NikonGallerySection';
import { FujifilmBleService, FujifilmBleCamera, FujifilmWifiCredential } from '../../services/FujifilmBleService';
import { FujifilmModels } from '../../services/FujifilmModels';
import { FujifilmBleIds, FujifilmNet } from '../../services/FujifilmProtocol';
import { CanonBleService, CanonBleCamera, CanonWifiCredential, CanonWapResult } from '../../services/CanonBleService';
import { CanonModels, CanonIdentity } from '../../services/CanonModels';
import { PhotoItem, AppLogStore, NavColorService, WorksBridge, CameraBridge,
  extensionFromName as sharedExtensionFromName } from './HomeShared';

/** 富士线的品牌字符串（ROUTE_SPEC §3.1：统一 `'FUJIFILM'`）。 */
const FUJIFILM_BRAND: string = 'FUJIFILM';
/** 富士拉起热点后等 `AP_STATE = 0x8001` 的上限（01 §9.4：通常 2–8 s）。 */
const FUJIFILM_AP_READY_TIMEOUT_MS: number = 20000;
/** 佳能线的品牌字符串（与 `CanonModels.BRAND` 一致，页面内只用于分支）。 */
const CANON_BRAND: string = 'Canon';
/** 佳能 WAP 交接（00020002 → TLV + 00020003）通常 3–10 s，给 25 s 上限。 */
const CANON_WAP_TIMEOUT_MS: number = 25000;
/** 佳能 BLE 注册（00010006 indicate 0x02）的重试上限。 */
const CANON_REGISTER_ATTEMPTS: number = 3;

interface TransferItem {
  name: string;
  detail: string;
  progress: number;
  color: string;
}

/** 相机素材 @Builder 的参数：ArkUI 只有对象字面量传参支持随状态刷新，
 *  简单类型参数初始化后不会再更新，所以这里统一包一层。 */
interface CameraImageKeyParam {
  imageKey: string;
}

/** 索尼「确认连接」开始前的 BLE 身份快照。
 *
 * 配对握手要十几秒，期间 500ms 扫描定时器与发现回调都会重排相机卡片；如果
 * 注册时才去读 cameraBleCandidate* 字段，可能已经指向另一台相机。 */
interface SonyPairingIdentity {
  deviceId: string;
  deviceName: string;
  model: string;
  imageKey: string;
  btAddress: string;
}

/** 尼康配对进度弹窗。
 *
 * 配对整条链路实测 60 秒以上（光是经典搜索一轮就 12 秒），只靠消息区一行小字时
 * 用户会以为卡死。这个弹窗在配对全程显示当前步骤、进度条和说明文字。
 *
 * 说明文字里有用户明确要求的那句话：首次连接用于注册配对；之后连接要保证**两侧都
 * 保留**该配对记录，任一侧清掉了就得两侧都清掉再重新配对——否则会出现"手机侧有
 * 记录、相机侧已不认"的单向状态，表现为点了没反应。
 *
 * 不提供取消按钮：中途取消会留下"手机侧已删/相机侧还在"的半成品状态，比等它跑完
 * 更麻烦；流程本身有超时兜底，不会永久卡住。 */
@CustomDialog
struct NikonPairingProgressDialog {
  controller?: CustomDialogController;
  // **必须走 `@StorageLink`，不能用 `@Link` / `@Prop`。**
  //
  // `@CustomDialog` 挂载在独立的弹窗上下文里，`@Link` 无法与页面建立双向绑定
  // （本文件末尾的 SyncPairProgressDialog 已经踩过同一个坑并留了注释）。
  // `@Prop` 也不行——它在创建时拿到的是一份拷贝，而弹窗内容由控制器一次性创建、
  // 不在页面 `build()` 那棵树里，父状态变了没有任何东西去重新渲染它。
  //
  // 实测后果：服务端 `Nikon step 6/9`、`7/9`、`9/9` 都正常发出来了（日志可见），
  // 弹窗里的进度条和文字却纹丝不动。
  //
  // `@StorageLink` 经 AppStorage 全局键同步，弹窗与页面各挂一份即可实时刷新。
  @StorageLink('nikonPairStepIndex') stepIndex: number = 0;
  @StorageLink('nikonPairStepTotal') stepTotal: number = 0;
  @StorageLink('nikonPairStatus') status: string = '正在准备…';
  /** 相机通过 BLE 通知送来的配对码；空串表示这一轮还没收到。 */
  @StorageLink('nikonPairCode') pairCode: string = '';
  /** 是否已进入"等待系统配对"的阶段——此时才显示「配对相机」按钮。
   *
   *  真机反馈（用户原话）：「我们的 App 始终没显示配对相机」「弹窗配对相机啊哥」。
   *  之前配对是应用自己在后台等，界面从头到尾没有任何可点的东西，用户最后只能去
   *  手机「设置 → 蓝牙」里手动配对。这个按钮就是补上那个缺口：点它，应用会重新
   *  对相机的经典地址发起一次 `pairDevice`，系统配对界面随即弹出。 */
  @StorageLink('nikonPairActionable') pairActionable: boolean = false;

  build() {
    Column({ space: 14 }) {
      Text('尼康相机配对')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
      Progress({
        value: this.stepIndex,
        total: this.stepTotal > 0 ? this.stepTotal : 1,
        type: ProgressType.Linear
      })
        .width('100%')
        .height(6)
        .color('#3B7CFF')
        .backgroundColor('#E4E6EB')
      Text(this.stepTotal > 0 ? `第 ${this.stepIndex}/${this.stepTotal} 步` : '准备中…')
        .fontSize(12)
        .fontColor('#8A8A8E')
      Text(this.status)
        .fontSize(13)
        .fontColor('#1C1C1E')
        .textAlign(TextAlign.Center)
      // **相机送来的配对码，我们自己显示。**
      //
      // 这个码是相机通过 BLE 通知发过来的，拿到它**不依赖**经典配对是否发起。而
      // 系统的配对弹窗只在 `pairDevice` 成功后才出现——真机上它会被拒（2900099），
      // 于是用户完全看不到这个码，尽管我们已经有了。
      //
      // 相机屏幕上显示的是同一个码，所以把它摆出来，用户自己就能比对。
      if (this.pairCode.length > 0) {
        Column({ space: 4 }) {
          Text('系统配对码')
            .fontSize(12)
            .fontColor('#8A8A8E')
          Text(this.pairCode)
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1C1C1E')
            .letterSpacing(4)
          Text('相机屏幕上应显示同一个码；请在相机上点 OK 确认')
            .fontSize(11)
            .fontColor('#8A8A8E')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
      }
      // **用户自己点「配对相机」。**
      //
      // 服务端在等待绑定期间会把 `nikonPairActionable` 置为 true；点一下就把一个
      // 时间戳写进 `nikonPairRequest`，服务端轮询到这个变化会重新发起 `pairDevice`，
      // 系统的配对界面随之弹出，相机屏幕上出现配对码，用户在相机上点 OK 即完成。
      if (this.pairActionable) {
        Column({ space: 8 }) {
          Button('配对相机')
            .width('100%')
            .height(44)
            .backgroundColor('#3B7CFF')
            .fontColor(Color.White)
            .fontSize(16)
            .onClick(() => {
              AppStorage.setOrCreate('nikonPairRequest', Date.now());
            })
          Text('点上面的按钮会立即向相机发起一次系统配对；相机屏幕上出现配对码后，请在相机上点 OK。')
            .fontSize(11)
            .fontColor('#8A8A8E')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
      }
      Divider()
      // 这句是**可操作的引导**，不是中性说明。
      //
      // 根本原因：`removePairedDevice` 在鸿蒙公开 API 里不存在（只有 pairDevice /
      // getPairedDevices / getPairState / setDevicePairingConfirmation），官方能
      // removeBond 是因为它是系统签名应用。所以"手机侧还留着记录、相机侧已经删了"
      // 这种单向状态，App 自己清不掉——只能引导用户去清，而且**必须两侧都清**，
      // 只清一侧会留下同一个单向状态。
      Text('首次连接用于注册配对。若连接失败或相机无响应，说明两侧的配对记录不一致：'
        + '请到手机「设置 → 蓝牙」删除本相机，并在相机上也删除本手机的配对记录，'
        + '然后重新连接。只清一侧无效。')
        .fontSize(11)
        .fontColor('#8A8A8E')
    }
    .width('86%')
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

/** 首页「相机」页：Lumix/Nikon/Sony 连接发现、Wi-Fi/USB 图传与相机文件管理。 */
@Component
export struct CameraPage {
  @State private cameraHost: string = '';
  // 尼康配对的步骤进度，来自 trace 里的 `Nikon step N/M ...`。
  //
  // 整条配对链路实测要 60 秒以上（光是经典搜索那一轮就可能 36 秒），界面只有一行
  // 文字时用户分不清"在跑"还是"卡死"——实测就出现过用户以为卡住的情况。所以把
  // 服务推来的步骤标记解析出来，额外驱动一个进度条。
  @State private nikonStepIndex: number = 0;
  @State private nikonStepTotal: number = 0;
  @State private nikonPairingMessage: string = '正在准备…';
  /** 尼康配对进度弹窗。
   *
   * 按 ArkUI 的推荐写法**在成员初始化处创建**（而不是在异步方法里 `new` 出来）。
   * 之前放在 `connectNikonViaBleProvisioning()` 里动态创建并 `open()`，结果弹窗
   * 不出现——而且我那个 `catch` 是空的，把失败原因全吞了，连日志都没有。 */
  private nikonProgressDialog: CustomDialogController = new CustomDialogController({
    builder: NikonPairingProgressDialog(),
    autoCancel: false,
    customStyle: true
  });
  /** 弹窗当前是否开着，避免对同一个弹窗重复 open/close。 */
  private nikonDialogOpen: boolean = false;
  // 相机会话的共享状态：图片传输页面与首页持有同一实例。
  @State private cam: CameraSessionStore = CameraSessionStore.instance;
  @State private cameraThumbnailUri: string = '';
  @State private cameraGalleryPage: number = 1;
  // Panasonic gallery/info uses a zero-based ordinal. Keep the next older
  // page boundary explicitly so loading never jumps back to the beginning
  // after the initial newest page.
  @State private cameraGalleryNextStartIndex: number = 0;
  @State private cameraGalleryScrollOffset: number = 0;
  private cameraGalleryLastScrollY: number = 0;
  @State private cameraBleCandidateDeviceId: string = '';
  @State private cameraBleCandidateBrand: string = 'Panasonic';
  @State private cameraBleCandidateImageKey: string = '';
  @State private cameraBleCandidateConnectable: boolean = false;
  /** Stable identity advertised by the selected body; '' for bodies that
   * advertise none (Wi-Fi-only, legacy, Nikon/Sony). The card key prefers it,
   * so renaming the camera no longer creates a second card. */
  @State private cameraBleCandidateBtAddress: string = '';
  // Keep every supported advertisement seen while the camera page is open.
  // The selected entry drives the connection target; the list is rendered as
  // a horizontal strip so a nearby second body never replaces the first one.
  @State private cameraBleCandidates: LumixBleCameraCandidate[] = [];
  @State private cameraBleSelectedIndex: number = 0;
  @State private cameraCarouselPageWidth: number = 1;
  private cameraCarouselOffset: number = 0;
  private cameraCarouselAlignTimer: number = -1;
  private cameraCarouselRealigning: boolean = false;
  private cameraCards: CameraCardRegistry = CameraCardRegistry.instance;
  private cameraCarouselScroller: Scroller = new Scroller();
  private cameraGalleryScroller: Scroller = new Scroller();
  // The camera section embeds the gallery grid inside its own page scroll.
  // Pagination triggers there need an independent scroller and watermark:
  // the two containers measure offsets from different origins, so sharing
  // the transfer-center watermark would fire at the wrong thresholds after
  // a section switch.
  private cameraSectionScroller: Scroller = new Scroller();
  // 用户显式点击「关闭WIFI传输」后抑制自动图传重连；任何新的连接动作清零。
  private cameraWifiCloseRequested: boolean = false;
  // 防止 Wi-Fi 链路事件与注册完成钩子并发触发两次自动图传。
  /** One pull-down gallery start per Wi-Fi session; reset on teardown. */
  private cameraGalleryScrollFetched: boolean = false;
  private lutControlConnectInFlight: boolean = false;
  /** 索尼线：按需拉起相机 Wi‑Fi 的进行中标记（同一时刻只允许一次）。 */
  private sonyWifiRaiseInFlight: boolean = false;
  /** 尼康线按需拉起 Wi‑Fi 的重入标记（与索尼同构，见 ensureNikonWifiForAction）。 */
  private nikonWifiRaiseInFlight: boolean = false;
  /** 富士线：扫描命中的机身（配对/拉起要用它的 deviceId 与广播里的 pairing key）。 */
  private fujifilmCamera: FujifilmBleCamera | null = null;
  /** 富士线「拉起 AP → 关联 Wi‑Fi」的重入标记：同一时刻只允许一次。 */
  private fujifilmWifiRaiseInFlight: boolean = false;
  /** 富士线最近一次从相机读到的机型名（用于卡片与日志）。 */
  @State private fujifilmModel: string = '';
  /** 佳能线：扫描命中的机身（BLE 连接/WAP 交接要用它的 deviceId 与相机 UUID）。 */
  private canonCamera: CanonBleCamera | null = null;
  /** 佳能线「拉起 AP → 关联 Wi‑Fi」的重入标记：同一时刻只允许一次。 */
  private canonWifiRaiseInFlight: boolean = false;
  /** 佳能线最近一次读到的 PTP/素材机型名（卡片与页面展示）。 */
  @State private canonModel: string = '';
  // LUMIX Sync 连接进度弹窗：握手含相机 SoftAP 重启，全程可达一两分钟，
  // 用模态弹窗持续显示当前步骤与已等待时间，避免用户误以为卡死而放弃。
  // 弹窗是独立上下文，状态经 AppStorage 键同步（@StorageLink）。
  @StorageLink('syncPairDialogStatus') private syncPairDialogStatus: string = '';
  private syncPairDialogController: CustomDialogController | null = null;
  // 固件更新进度弹窗。写入机身固件不可逆，且全程要经历蓝牙读版本、联网拉包、
  // 解压、重连相机 Wi-Fi、分块传输五个阶段（可达十几分钟），把进度留在页面
  // 底部小字里既看不见也拦不住误触。这里用不可取消的模态弹窗全程锁定界面。
  // 同样是独立上下文，状态经 AppStorage 同步；百分比 -1 表示不确定进度。
  @StorageLink('firmwareDialogStatus') private firmwareDialogStatus: string = '';
  @StorageLink('firmwareDialogPercent') private firmwareDialogPercent: number = -1;
  private firmwareDialogController: CustomDialogController | null = null;
  @State private cameraPairingAttempted: boolean = false;
  @State private cameraUsbHandshakeComplete: boolean = false;
  // The original S5 joins its camera AP directly and does not keep the
  // application-level BLE registration link used by newer S bodies. Keep a
  // separate ready flag so the Wi-Fi action remains a transfer entry point
  // after association instead of being mislabeled as a close action.
  @State private cameraWifiOnlyReady: boolean = false;
  // Original Panasonic S5 is discovered exclusively through its Wi‑Fi AP.
  // This flag is deliberately independent from the BLE candidate carousel so
  // an S5 can never be treated as a Bluetooth-paired camera.
  @State private syncWifiDetected: boolean = false;
  private s5LastReceivedJpegUri: string = '';
  @State private cameraTransport: number = 0; // 0 = Wi-Fi, 1 = USB PTP
  // WiFi 候选与扫描状态由壳页面的底部弹层共享，经 AppStorage 双向同步。
  @StorageLink('homeWifiCandidates') private wifiCandidates: LumixWifiCandidate[] = [];
  @StorageLink('homeWifiScanState') private wifiScanState: number = 0;
  @StorageLink('homeShowWifiPicker') private showWifiPicker: boolean = false;
  @StorageLink('homeWifiConnecting') private wifiConnecting: boolean = false;
  private cameraWifiJoinSequence: number = 0;
  private cameraWifiPasswordCancel: (() => void) | null = null;
  @State private transfers: TransferItem[] = [];
  @State private freeSpaceText: string = '—';
  // 相机页「支持的相机类型」提示：进程生命周期内只弹一次。
  private cameraHintShownThisLaunch: boolean = false;
  private cameraBleDiscoveryActive: boolean = false;
  private cameraBleLastSeenAt: number = 0;
  private cameraBleStatusTimer: number = -1;
  private cameraWifiPresenceTimer: number = -1;
  private cameraWifiPresenceInFlight: boolean = false;
  // Nikon PTP/IP pagination is cursor-based: the service returns the handle
  // position to resume from, which advances even for handles that yield no
  // thumbnail. The request sequence guards late async results so a stale
  // load can never clear the flags of a newer one.
  private cameraGalleryNikonCursor: number = 0;
  private cameraGalleryRequestSeq: number = 0;
  // Sony cannot use the object-handle thumbnail scan Nikon does: its thumbnails
  // come from a separate contents-data operation, so the grid is filled in by a
  // background pump that fetches one thumbnail at a time and patches the gallery
  // item in place. `sonyThumbnailPumpSeq` invalidates a pump whose session was
  // replaced underneath it.
  private sonyThumbnailPumpRunning: boolean = false;
  private sonyThumbnailPumpSeq: number = 0;
  private sonyThumbnailFailedKeys: Set<string> = new Set<string>();
  private wifiConnectionChangeCallback: ((state: number) => void) | null = null;
  private cameraRadioRequestInFlight: boolean = false;
  @StorageLink('vividNightMode') private isNightMode: boolean = false;
  @StorageProp('windowWidth') private windowWidth: number = 390;
  @StorageProp('homeSection') private selectedSection: number = 0;
  @StorageProp('homeSectionTick') @Watch('onSectionChanged') private sectionTick: number = 0;
  @StorageLink('homeNavCollapsed') private navCollapsed: boolean = false;
  private lastSection: number = 0;
  // 「发现新相机」卡片：蓝牙扫描发现「未注册」的相机时出现，四个品牌共用。
  // 卡片里的 SSID 行永远占同一个槽位（固定高度）：真实 SSID 一般要连上/
  // 配对后才知道，未知时先用 BLE 广播名占位，之后就地替换，布局不跳。
  @State private newCameraCardKey: string = '';
  @State private newCameraCardName: string = '';
  @State private newCameraCardSsid: string = '';
  @State private newCameraCardModel: string = '';
  @State private newCameraCardImageKey: string = '';
  @State private newCameraCardBrand: string = 'Panasonic';
  @State private newCameraCardDeviceId: string = '';
  @State private newCameraCardBtAddress: string = '';
  @State private newCameraCardConnectable: boolean = true;
  // 每台相机只提示一次：弹过（或用户点掉/选择过）的 key 记录在这里。列表
  // 只在本次启动内有效，所以重新进相机页不会为同一台相机反复弹卡片。
  private newCameraCardSeenKeys: string[] = [];

  aboutToAppear(): void {
    // 常驻挂载：把相机动作注册给壳页面的 WiFi 候选弹层。
    CameraBridge.isPtpIpCamera = (): boolean => this.isPtpIpCamera();
    CameraBridge.scanCameraWifi = (): void => {
      this.scanCameraWifi();
    };
    CameraBridge.confirmCameraWifi = (candidate: LumixWifiCandidate): void => {
      this.confirmCameraWifi(candidate);
    };
    this.startWifiStatusListener();
    this.registerCameraSessionDriver();
    setTimeout(() => {
      this.loadFreeSpace();
    }, 320);
  }

  aboutToDisappear(): void {
    this.cancelCameraWifiPasswordRequest();
    CameraBridge.isPtpIpCamera = null;
    CameraBridge.scanCameraWifi = null;
    CameraBridge.confirmCameraWifi = null;
    this.stopCameraBleDiscovery();
    if (this.cameraCarouselAlignTimer !== -1) clearTimeout(this.cameraCarouselAlignTimer);
    this.stopWifiStatusListener();
    void PanasonicS5Receiver.stop();
  }

  /** 壳页面 switchSection 的页签进入/离开回放（原 switchSection 相机分支）。 */
  private onSectionChanged(): void {
    if (this.lastSection === 1 && this.selectedSection !== 1) {
      if (this.cameraWifiPasswordCancel) this.cancelCameraWifiPasswordRequest();
      this.stopCameraBleDiscovery();
    }
    if (this.selectedSection === 1) {
      this.prepareCameraRadioAccess();
      if (this.lastSection !== 1 && !this.cameraHintShownThisLaunch) {
        this.cameraHintShownThisLaunch = true;
        this.showSupportedCameraHint();
      }
    }
    this.lastSection = this.selectedSection;
  }

  private scheduleNavColorRefresh(): void {
    NavColorService.schedule(this.getUIContext());
  }

  private isDesktop(): boolean {
    return this.windowWidth >= 840;
  }

  /** 任一主页面下滑时导航栏收缩为右侧「我的」小胶囊，上滑或点击胶囊恢复完整导航。 */
  private updateNavCollapse(yOffset: number): void {
    if (yOffset > 4) {
      if (!this.navCollapsed) {
        // geometryTransition 形变必须由 animateTo 驱动，时长曲线跟随此处配置。
        this.getUIContext().animateTo({ duration: 500, curve: Curve.EaseOut }, () => {
          this.navCollapsed = true;
        });
      }
    } else if (yOffset < -4) {
      if (this.navCollapsed) {
        this.getUIContext().animateTo({ duration: 500, curve: Curve.EaseOut }, () => {
          this.navCollapsed = false;
        });
      }
    }
  }

  private showMessage(message: string): void {
    AppLogStore.add('ui ' + message);
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      console.info(message);
    }
  }

  private extensionFromName(name: string): string {
    return sharedExtensionFromName(name);
  }

  /** 相机页历史代码直接调用作品页的导入/缩略图修复方法；经 WorksBridge 桥接。 */
  private async addImportedPhoto(uri: string, displayNameOverride: string = '',
    fallbackThumbUri: string = '', orientation: number = 0): Promise<PhotoItem | null> {
    return WorksBridge.addImportedPhoto ?
      WorksBridge.addImportedPhoto(uri, displayNameOverride, fallbackThumbUri, orientation)
      : Promise.resolve(null);
  }

  private repairMissingThumbnails(): void {
    if (WorksBridge.repairMissingThumbnails) WorksBridge.repairMissingThumbnails();
  }

  private pageTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#172033';
  }

  private cardMaterial(): VividMaterial {
    return this.isNightMode ? VividMaterial.cardNight : VividMaterial.card;
  }

  private panelTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#1B2536';
  }

  private secondaryTextColor(): string {
    return this.isNightMode ? '#D1D9E8' : '#526078';
  }

  private mutedTextColor(): string {
    return this.isNightMode ? '#B7C3D6' : '#7B8798';
  }

  /** 相机页会话按钮的玻璃质感：半透明填充 + backdropBlur + 亮色描边 +
   * 投影。纯白填充会和玻璃卡片背景融为一体，用户难以辨认可点击区域。 */
  private sessionButtonFill(): string {
    return this.isNightMode ? 'rgba(18,28,48,0.42)' : 'rgba(255,255,255,0.30)';
  }

  private sessionButtonFillMuted(): string {
    return this.isNightMode ? 'rgba(18,28,48,0.22)' : 'rgba(255,255,255,0.14)';
  }

  private sessionButtonTextColor(): string {
    return this.isNightMode ? '#FFFFFF' : '#000000';
  }

  private sessionButtonTextColorMuted(): string {
    return this.isNightMode ? '#8E99AB' : '#A6AFBC';
  }

  private sessionButtonBlur(): number {
    return this.isNightMode ? 8 : 14;
  }

  private sessionButtonShadow(): ShadowOptions {
    return {
      radius: 8,
      color: this.isNightMode ? 'rgba(0,0,0,0.45)' : 'rgba(40,55,82,0.22)',
      offsetY: 3,
    };
  }

  /** Keep the Wi‑Fi indicator tied to the actual linked SSID, including a
   * camera turning its AP off or the user roaming back to another network. */
  private startWifiStatusListener(): void {
    if (this.wifiConnectionChangeCallback) return;
    this.wifiConnectionChangeCallback = (_state: number): void => {
      // The callback can arrive before DHCP/SSID state settles. Read it on the
      // next turn so the UI does not briefly show a stale camera connection.
      // The gallery is deliberately NOT auto-started here: for non-S5 LUMIX
      // bodies the image transfer loads only on the user's pull-down.
      setTimeout(() => {
        this.refreshCameraWifiState().catch(() => {
        });
      }, 350);
    };
    try { wifiManager.on('wifiConnectionChange', this.wifiConnectionChangeCallback); } catch (_error) {
      this.wifiConnectionChangeCallback = null;
    }
  }

  private stopWifiStatusListener(): void {
    if (!this.wifiConnectionChangeCallback) return;
    try { wifiManager.off('wifiConnectionChange', this.wifiConnectionChangeCallback); } catch (_error) { }
    this.wifiConnectionChangeCallback = null;
  }

  private async refreshCameraWifiState(): Promise<void> {
    // A disconnect callback must be able to invalidate the UI while a gallery
    // request is still unwinding. Otherwise the old session label keeps the
    // transfer action enabled until the request timeout completes.
    if (this.wifiConnecting) return;
    if (this.cam.cameraWifiSsid.length === 0 && this.cam.cameraWifiStatus !== '已连接' &&
      this.cam.cameraSessionStatus !== '已建立') return;
    const linkedSsid = await LumixCameraService.linkedSsid();
    // Only the exact SSID of the associated camera AP proves the link still
    // belongs to the current session. A different Nikon AP (for example a
    // second body nearby) must tear the old session down instead of
    // silently keeping the old host, gallery and socket state.
    const stillCameraWifi = linkedSsid.length > 0 && linkedSsid === this.cam.cameraWifiSsid;
    // 取证：这一行比较式决定会话是否被拆掉。SSID 本身按隐私策略不落日志，只记
    // 长度与「去掉标点后是否相等」—— 若 normalizedMatch=1 而 match=0，说明只是
    // 引号/大小写之类的格式差异，却足以让每次 wifiConnectionChange 都误判漫游。
    const normalizedLinked = linkedSsid.replace(/[^A-Za-z0-9]/g, '').toLowerCase();
    const normalizedRecorded = this.cam.cameraWifiSsid.replace(/[^A-Za-z0-9]/g, '').toLowerCase();
    const normalizedMatch = normalizedLinked.length > 0 && normalizedLinked === normalizedRecorded;
    AppLogStore.add(`wifi link-check match=${stillCameraWifi ? 1 : 0} normalizedMatch=${normalizedMatch ? 1 : 0} ` +
      `lenLinked=${linkedSsid.length} lenRecorded=${this.cam.cameraWifiSsid.length}`);
    if (stillCameraWifi) return;
    if (linkedSsid.length === 0) {
      // Right after a roam the platform can report an empty SSID while the
      // link is still healthy. Re-check once before tearing down so a
      // transient read does not drop an established hidden-network session.
      await new Promise<void>((resolve) => setTimeout(resolve, 1200));
      if (this.wifiConnecting) return;
      const recheckedSsid = await LumixCameraService.linkedSsid();
      if (recheckedSsid.length > 0 && recheckedSsid === this.cam.cameraWifiSsid) return;
    }
    NikonPtpIpService.close();
    this.stopSonyThumbnailPump();
    SonyPtpIpContent.close();
    LumixImportPrototype.clearHttpSession();
    this.cam.cameraWifiStatus = '未连接';
    this.cameraWifiOnlyReady = false;
    this.cam.cameraSessionStatus = '未建立';
    this.cameraHost = '';
    this.cam.cameraGalleryItems = [];
    this.cam.cameraGalleryTotal = 0;
    this.cam.cameraGalleryHasMore = false;
    this.cameraGalleryNikonCursor = 0;
    this.cameraGalleryRequestSeq += 1;
    this.cam.cameraGalleryLoading = false;
    this.cam.cameraTransferInProgress = false;
    this.cameraGalleryScrollFetched = false;
    // A previous Wi‑Fi scan is not proof that a camera AP is still nearby.
    // Drop those candidates with the link so the connection action cannot stay
    // enabled after roaming to another network or turning the camera off.
    this.wifiCandidates = [];
    this.wifiScanState = 0;
    this.cameraCards.setConnected(null);
    this.refreshCameraCards();
    this.cam.cameraMessage = '相机 Wi‑Fi 已断开，等待重新连接';
  }

  @Builder
  CameraContent() {
    // 图库浏览、勾选与下载原图已迁往「图片传输」页面；本页只保留连接
    // 状态与入口按钮，滚动不再承担分页/首次加载职责。
    Scroll(this.cameraSectionScroller) {
      Column() {
        this.SectionIntro('直接连接', '连接你的相机', '通过相机 Wi‑Fi 或 USB PTP，浏览、导入并进入无损编辑。');
        if (this.isDesktop()) {
          Row() {
            this.CameraDeviceCard();
            this.CameraSessionCard();
          }
          .width('100%')
          .alignItems(VerticalAlign.Top);
        } else {
          Column() {
            this.CameraDeviceCard();
            this.CameraSessionCard();
          }
          .width('100%');
        }
      }
      .width('100%')
      .padding({ left: this.isDesktop() ? 28 : 14, right: this.isDesktop() ? 28 : 14, bottom: this.isDesktop() ? 36 : 96 });
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScroll((_xOffset: number, yOffset: number) => {
      this.scheduleNavColorRefresh();
      this.updateNavCollapse(yOffset);
    });
  }

  @Builder
  CameraDeviceCard() {
    Column() {
      Text('相机')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.panelTextColor())
        .width('100%')
        .margin({ bottom: 10 });
      Row() {
        Text(this.cameraConnectionLabel())
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.cameraConnectionLabel() === '已连接' ? '#37B27B' : this.mutedTextColor())
          .letterSpacing(1.1);
        Blank();
        Text(this.cameraIsReachable() ? '● 在线' : '○ 离线')
          .fontSize(11)
          .fontColor(this.cameraIsReachable() ? '#37B27B' : this.mutedTextColor());
      }
      .width('100%');
      if (this.cameraBleCandidates.length > 1) {
        // A real horizontal pager: every identity card occupies the same
        // viewport, and scrollSnap settles on the nearest card when the
        // finger is released. This prevents a second row from being inserted.
        Scroll(this.cameraCarouselScroller) {
          Row() {
            ForEach(this.cameraBleCandidates, (candidate: LumixBleCameraCandidate, index: number) => {
              this.CameraCandidateTile(candidate, index);
            }, (candidate: LumixBleCameraCandidate) => this.cameraCardRenderKey(candidate));
          }
          // Give the scroll content one full viewport per candidate. A fixed
          // 100% Row would constrain the second child and could make a second
          // camera appear as a wrapped row instead of a pager page.
          .width(`${Math.max(1, this.cameraBleCandidates.length) * 100}%`)
          .height(220)
        }
        .width('100%')
        .height(220)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .scrollSnap({ snapAlign: ScrollSnapAlign.START, snapPagination: '100%' })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.cameraCarouselPageWidth = Math.max(1, newArea.width as number);
          this.alignSelectedCameraCard();
        })
        .onScroll((xOffset: number, _yOffset: number) => {
          this.cameraCarouselOffset = Math.max(0, xOffset);
        })
        .onScrollStop(() => {
          if (this.cameraCarouselRealigning) return;
          const pageWidth = Math.max(1, this.cameraCarouselPageWidth);
          // Read the settled offset from the bound Scroller after scroll-snap
          // completes. Deprecated callback offsets can describe the last drag
          // frame rather than the snapped page.
          let settledOffset = this.cameraCarouselScroller.currentOffset().xOffset;
          if (settledOffset < 0) settledOffset = 0;
          this.cameraCarouselOffset = settledOffset;
          const index = Math.max(0, Math.min(this.cameraBleCandidates.length - 1,
            Math.round(settledOffset / pageWidth)));
          // Always apply the nearest settled card so the visible card,
          // highlight and connection target stay in sync.
          // align=false：手指刚把卡片滑到这里，再对齐会打断吸附动画。
          this.selectCameraCandidate(index, false);
        });
      } else {
        // 相机图片独立放在白色圆角卡片中，下载图库时只更新缩略图列表，
        // 不会把已连接相机的识别图替换掉。
        Column() {
        // During the pairing/GATT handshake keep the waiting illustration in
        // place. The model image is committed only after the connection is
        // successful, so the card does not flash an identity image for a
        // camera that has not finished connecting yet.
        if (this.cam.cameraState === 1) {
          Image($r('app.media.panasonic_waiting'))
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain)
            .borderRadius(16);
        } else if (this.cam.cameraState !== 2 && this.cameraThumbnailUri.length > 0) {
          Image(this.cameraThumbnailUri)
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain)
            .borderRadius(16);
        } else if (this.cam.cameraState !== 2 && this.cam.cameraBleCandidateName.length === 0) {
          // Supplied Panasonic waiting illustration before a model is found.
          Image($r('app.media.panasonic_waiting'))
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain)
            .borderRadius(16);
        } else if (this.cameraDisplayImageKey() === 'panasonic_s1ii') {
          Image($r('app.media.panasonic_s1ii'))
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_s1iie') {
          Image($r('app.media.panasonic_s1iie'))
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_s1rii') {
          Image($r('app.media.panasonic_s1rii'))
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_s5m2') {
          Image($r('app.media.panasonic_s5m2'))
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_s5') {
          // Dedicated DC-S5 asset. The semantic key stays separate from
          // panasonic_s5m2 so the original S5 never enters S5M2 matching or the
          // Lab BLE path.
          Image($r('app.media.panasonic_s5'))
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_zs300') {
          Image($r('app.media.panasonic_zs300'))
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_s5m2x') {
          Image($r('app.media.panasonic_s5m2x'))
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_s9') {
          Image($r('app.media.panasonic_s9'))
            .width(250)
            .height(150)
            .objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_gh7') {
          Image($r('app.media.panasonic_gh7')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_gh6') {
          Image($r('app.media.panasonic_gh6')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_gh5') {
          Image($r('app.media.panasonic_gh5')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_gh5m2') {
          Image($r('app.media.panasonic_gh5m2')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_gh5s') {
          Image($r('app.media.panasonic_gh5s')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_g9') {
          Image($r('app.media.panasonic_g9')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_g9m2') {
          Image($r('app.media.panasonic_g9m2')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_g100d') {
          Image($r('app.media.panasonic_g100d')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_g97') {
          Image($r('app.media.panasonic_g97')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_gx9') {
          Image($r('app.media.panasonic_gx9')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_gf10') {
          Image($r('app.media.panasonic_gf10')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_zs99') {
          Image($r('app.media.panasonic_zs99')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'panasonic_l10') {
          Image($r('app.media.panasonic_l10')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z30') {
          Image($r('app.media.nikon_z30')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z50') {
          Image($r('app.media.nikon_z50')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z50ii') {
          Image($r('app.media.nikon_z50ii')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z5') {
          Image($r('app.media.nikon_z5')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z5ii') {
          Image($r('app.media.nikon_z5ii')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z6ii') {
          Image($r('app.media.nikon_z6ii')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z6iii') {
          Image($r('app.media.nikon_z6iii')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z6') {
          Image($r('app.media.nikon_z6')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z7ii') {
          Image($r('app.media.nikon_z7ii')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z7') {
          Image($r('app.media.nikon_z7')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z8') {
          Image($r('app.media.nikon_z8')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_z9') {
          Image($r('app.media.nikon_z9')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_zf') {
          Image($r('app.media.nikon_zf')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'nikon_zfc') {
          Image($r('app.media.nikon_zfc')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a1') {
          Image($r('app.media.sony_a1')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a1m2') {
          Image($r('app.media.sony_a1m2')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a9m3') {
          Image($r('app.media.sony_a9m3')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a7m5') {
          Image($r('app.media.sony_a7m5')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a7m4') {
          Image($r('app.media.sony_a7m4')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a7m3') {
          Image($r('app.media.sony_a7m3')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a7r6') {
          Image($r('app.media.sony_a7r6')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a7r5') {
          Image($r('app.media.sony_a7r5')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a7s3') {
          Image($r('app.media.sony_a7s3')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a7cr') {
          Image($r('app.media.sony_a7cr')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a7c2') {
          Image($r('app.media.sony_a7c2')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a7c') {
          Image($r('app.media.sony_a7c')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a6700') {
          Image($r('app.media.sony_a6700')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a6600') {
          Image($r('app.media.sony_a6600')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_a6400') {
          Image($r('app.media.sony_a6400')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_zve10ii') {
          Image($r('app.media.sony_zve10ii')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_zve10') {
          Image($r('app.media.sony_zve10')).width(250).height(150).objectFit(ImageFit.Contain);
        } else if (this.cameraDisplayImageKey() === 'sony_zve1') {
          Image($r('app.media.sony_zve1')).width(250).height(150).objectFit(ImageFit.Contain);
        } else {
          // Minimal premium line-art camera while no model has been detected.
          // It intentionally carries no brand wordmark so the waiting state
          // stays neutral until a real camera identity is available.
          Stack() {
            Row()
              .width(176)
              .height(94)
              .borderRadius(18)
              .backgroundColor($r('app.color.vivid_surface_ffffff'))
              .border({ width: 2, color: '#111111' });
            Row()
              .width(42)
              .height(10)
              .borderRadius(5)
              .backgroundColor($r('app.color.vivid_surface_ffffff'))
              .border({ width: 2, color: '#111111' })
              .position({ x: 24, y: 8 });
            Circle()
              .width(68)
              .height(68)
              .backgroundColor($r('app.color.vivid_surface_ffffff'))
              .border({ width: 2, color: '#111111' });
            Circle()
              .width(48)
              .height(48)
              .backgroundColor($r('app.color.vivid_surface_ffffff'))
              .border({ width: 2, color: '#111111' });
            Circle()
              .width(12)
              .height(12)
              .backgroundColor($r('app.color.vivid_surface_ffffff'))
              .border({ width: 2, color: '#111111' });
          }
          .width(190)
          .height(112);
        }
        Text(this.cam.cameraState === 2
          ? (this.cam.cameraBleCandidateName.length > 0 ? this.cam.cameraBleCandidateName : this.cam.cameraModel)
          : (this.cam.cameraBleCandidateName.length > 0 ? this.cam.cameraBleCandidateName : '等待相机'))
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          // The image area intentionally stays a white card in both themes;
          // keep its title dark so it remains readable in night mode too.
          .fontColor($r('app.color.vivid_text_1b2536'))
          .width('92%')
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 10 });
        }
        .width('100%')
        .height(220)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.vivid_surface_ffffff'))
        .borderRadius(22)
        .shadow({ radius: 14, color: 'rgba(36,47,68,0.16)', offsetY: 6 })
        .padding({ top: 12, bottom: 12 });
      }
    }
    .width(this.isDesktop() ? '48.8%' : '100%')
    // The identity card already contains the complete camera image and name;
    // keep only a small outer buffer so the connection card follows directly.
    .height(300)
    .padding(20)
    .borderRadius(28)
    .attributeModifier(this.cardMaterial());
  }

  /** imageKey -> 本地相机素材：相机卡片与「发现新相机」卡片共用同一张表。
   *  只按 key 取已有素材，不新增图片资源，也不在调用处写死资源 id。 */
  @Builder
  CameraModelImage(params: CameraImageKeyParam) {
    if (params.imageKey.length > 0 && CanonModels.isCanonImageKey(params.imageKey)) {
      // 佳能 95 款机身素材来自官方 APK 的 drawable-nodpi/camera_<PID>.png，
      // 已统一处理为透明背景（tools/build_canon_art.py），放在 rawfile/canon/。
      Image($rawfile(CanonModels.rawfileForImageKey(params.imageKey)))
        .width(250)
        .height(150)
        .objectFit(ImageFit.Contain);
    } else if (params.imageKey.length > 0 && FujifilmModels.isFujifilmImageKey(params.imageKey)) {
      // 富士 85 款机身素材是 rawfile（`fujifilm/<slug>.png`，透明背景），
      // 与松下/尼康/索尼的 media 资源分开存放，避免动摇既有资源表。
      Image($rawfile(FujifilmModels.rawfileForImageKey(params.imageKey)))
        .width(250)
        .height(150)
        .objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_s1rii') {
      Image($r('app.media.panasonic_s1rii')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_s1ii') {
      Image($r('app.media.panasonic_s1ii')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_s1iie') {
      Image($r('app.media.panasonic_s1iie')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_s5m2') {
      Image($r('app.media.panasonic_s5m2')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_s5') {
      Image($r('app.media.panasonic_s5')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_zs300') {
      Image($r('app.media.panasonic_zs300')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_s5m2x') {
      Image($r('app.media.panasonic_s5m2x')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_s9') {
      Image($r('app.media.panasonic_s9')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_gh7') {
      Image($r('app.media.panasonic_gh7')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_gh6') {
      Image($r('app.media.panasonic_gh6')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_gh5') {
      Image($r('app.media.panasonic_gh5')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_gh5m2') {
      Image($r('app.media.panasonic_gh5m2')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_gh5s') {
      Image($r('app.media.panasonic_gh5s')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_g9') {
      Image($r('app.media.panasonic_g9')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_g9m2') {
      Image($r('app.media.panasonic_g9m2')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_g100d') {
      Image($r('app.media.panasonic_g100d')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_g97') {
      Image($r('app.media.panasonic_g97')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_gx9') {
      Image($r('app.media.panasonic_gx9')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_gf10') {
      Image($r('app.media.panasonic_gf10')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_zs99') {
      Image($r('app.media.panasonic_zs99')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'panasonic_l10') {
      Image($r('app.media.panasonic_l10')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z30') {
      Image($r('app.media.nikon_z30')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z50') {
      Image($r('app.media.nikon_z50')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z50ii') {
      Image($r('app.media.nikon_z50ii')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z5') {
      Image($r('app.media.nikon_z5')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z5ii') {
      Image($r('app.media.nikon_z5ii')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z6ii') {
      Image($r('app.media.nikon_z6ii')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z6iii') {
      Image($r('app.media.nikon_z6iii')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z6') {
      Image($r('app.media.nikon_z6')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z7ii') {
      Image($r('app.media.nikon_z7ii')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z7') {
      Image($r('app.media.nikon_z7')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z8') {
      Image($r('app.media.nikon_z8')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_z9') {
      Image($r('app.media.nikon_z9')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_zf') {
      Image($r('app.media.nikon_zf')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'nikon_zfc') {
      Image($r('app.media.nikon_zfc')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a1') {
      Image($r('app.media.sony_a1')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a1m2') {
      Image($r('app.media.sony_a1m2')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a9m3') {
      Image($r('app.media.sony_a9m3')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a7m5') {
      Image($r('app.media.sony_a7m5')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a7m4') {
      Image($r('app.media.sony_a7m4')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a7m3') {
      Image($r('app.media.sony_a7m3')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a7r6') {
      Image($r('app.media.sony_a7r6')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a7r5') {
      Image($r('app.media.sony_a7r5')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a7s3') {
      Image($r('app.media.sony_a7s3')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a7cr') {
      Image($r('app.media.sony_a7cr')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a7c2') {
      Image($r('app.media.sony_a7c2')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a7c') {
      Image($r('app.media.sony_a7c')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a6700') {
      Image($r('app.media.sony_a6700')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a6600') {
      Image($r('app.media.sony_a6600')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_a6400') {
      Image($r('app.media.sony_a6400')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_zve10ii') {
      Image($r('app.media.sony_zve10ii')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_zve10') {
      Image($r('app.media.sony_zve10')).width(250).height(150).objectFit(ImageFit.Contain);
    } else if (params.imageKey === 'sony_zve1') {
      Image($r('app.media.sony_zve1')).width(250).height(150).objectFit(ImageFit.Contain);
    } else {
      Text('相机').fontSize(24).fontColor($r('app.color.vivid_text_64748b'));
    }
  }

  /** Full-width identity page used by the horizontal camera carousel. */
  @Builder
  CameraCandidateTile(candidate: LumixBleCameraCandidate, index: number) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        this.CameraModelImage({ imageKey: candidate.imageKey });
      }
      .width('100%')
      .height(162)
      .backgroundColor($r('app.color.vivid_surface_ffffff'))
      .borderRadius(22);
      Text(candidate.deviceName.length > 0 ? candidate.deviceName : candidate.model)
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.panelTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('92%')
        .textAlign(TextAlign.Center)
        .margin({ top: 6 });
      Text(`${this.cameraCards.isOnline(candidate) ? '在线' : '离线'} · ${this.cameraCardIsSelected(candidate) ? '当前对象' : '点击切换'}`)
        .fontSize(10)
        .fontColor(this.cameraCardIsSelected(candidate) ? $r('app.color.vivid_text_1e8e5a') : this.mutedTextColor())
        .margin({ top: 2 });
    }
    .width(`${100 / Math.max(1, this.cameraBleCandidates.length)}%`)
    .height(220)
    .padding(8)
    .borderRadius(22)
    .border({ width: this.cameraCardIsSelected(candidate) ? 2 : 1, color: this.cameraCardIsSelected(candidate) ? '#316CF4' : 'rgba(203,213,228,0.70)' })
    .backgroundColor(this.cameraCardIsSelected(candidate) ? 'rgba(49,108,244,0.10)' : 'rgba(255,255,255,0.68)')
    .onClick(() => { this.selectCameraCardByKey(this.cameraCandidateKey(candidate)); });
  }

  /**
   * 「发现新相机」卡片（全品牌共用）：蓝牙扫描发现一台还没注册的相机时出现。
   *
   * 视觉（按要求）：玻璃材质 + 灰色填充。
   * - 玻璃：backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: SYSTEM })
   *   组件级「厚」模糊；圆角靠 .clip(true) 裁切，模糊才读起来是一张卡片。
   * - 灰色填充：半透明中性灰，日夜各一档（浅色 rgba(169,176,188,0.45)、
   *   深色 rgba(60,68,83,0.55)），文字用面板/次级文字色，两种模式下都清楚。
   * - 必须是覆盖层而不是 showAlertDialog：玻璃要有身后的页面内容可取样，
   *   而且 showAlertDialog 带不了自定义玻璃布局和相机图片。
   *
   * 结构固定为四段（标题 / 图片 / SSID / 按钮），SSID 行高度固定，真实 SSID
   * 后到时就地替换占位名，卡片不会跳版。
   */
  @Builder
  NewCameraDiscoveredCard() {
    Stack({ alignContent: Alignment.Center }) {
      // 遮罩：点空白处收起卡片，同时给玻璃提供一层可取样、可衬托的底色。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isNightMode ? 'rgba(0,0,0,0.34)' : 'rgba(18,26,40,0.18)')
        .onClick(() => { this.dismissNewCameraCard(); });
      Column() {
        // 1. 标题
        Text('发现新相机')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.panelTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        // 2. 相机图片：与相机卡片同一套 imageKey 素材，不新增图片资源
        Stack({ alignContent: Alignment.Center }) {
          this.CameraModelImage({ imageKey: this.newCameraCardImageKey });
        }
        .width('100%')
        .height(150)
        .margin({ top: 10 });
        // 3. SSID：真实 SSID 未知时是 BLE 广播名占位；固定高度，替换时不跳版
        Text(this.newCameraCardSsid)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.secondaryTextColor())
          .width('100%')
          .height(22)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        // 4. 确认按钮：把该相机设为当前卡片（与在列表里选中它同效）
        Button('选择此相机')
          .id('newCameraDiscoveredConfirm')
          .type(ButtonType.Capsule)
          .width('100%')
          .height(44)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.vivid_text_ffffff'))
          .backgroundColor('#316CF4')
          .margin({ top: 16 })
          .onClick(() => {
            this.confirmNewCameraCard().catch((error: Error): void => {
              AppLogStore.add(`ui 发现新相机卡片选择失败: ${error.message}`);
            });
          });
      }
      .width(this.isDesktop() ? 340 : 286)
      .padding({ left: 20, right: 20, top: 20, bottom: 20 })
      .borderRadius(26)
      .clip(true)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM })
      .backgroundColor(this.isNightMode ? 'rgba(60,68,83,0.55)' : 'rgba(169,176,188,0.45)')
      .border({ width: 1, color: this.isNightMode ? 'rgba(255,255,255,0.18)' : 'rgba(255,255,255,0.55)' })
      .shadow({ radius: 28, color: 'rgba(15,23,42,0.30)', offsetY: 12 });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  CameraSessionCard() {
    Column() {
      Text('本地连接').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor()).width('100%');
      Text('Wi‑Fi 使用相机网络握手，USB 执行标准 PTP 会话授权。')
        .fontSize(12)
        .fontColor(this.mutedTextColor())
        .width('100%')
        .margin({ top: 5, bottom: 18 });
      Row() {
        Button('Wi‑Fi')
          .type(ButtonType.Capsule)
          .height(30)
          .layoutWeight(1)
          .fontSize(11)
          .fontColor(this.cameraTransport === 0 ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_536176'))
          .backgroundColor(this.cameraTransport === 0 ? '#316CF4' : 'rgba(225,232,243,0.86)')
          .onClick(() => { this.cameraTransport = 0; });
        Button('USB')
          .type(ButtonType.Capsule)
          .height(30)
          .layoutWeight(1)
          .fontSize(11)
          .fontColor(this.cameraTransport === 1 ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_536176'))
          .backgroundColor(this.cameraTransport === 1 ? '#316CF4' : 'rgba(225,232,243,0.86)')
          .margin({ left: 8 })
          .onClick(() => { this.cameraTransport = 1; });
      }
      .width('100%')
      .margin({ bottom: 10 });
      if (this.cameraTransport === 0) {
        Text('图片传输时自动识别相机 Wi‑Fi')
          .fontSize(10)
          .fontColor(this.mutedTextColor())
          .width('100%')
          .margin({ bottom: 10 });
      } else {
        Row() {
          Text('⌘').fontSize(18).fontColor($r('app.color.vivid_text_66758b'));
          Column() {
            Text('USB PTP 相机')
              .fontSize(12)
              .fontColor(this.panelTextColor())
              .fontWeight(FontWeight.Medium);
            Text('先完成蓝牙配对并设为 LUMIX Lab，再允许 USB 访问')
              .fontSize(10)
              .fontColor(this.mutedTextColor())
              .margin({ top: 3 });
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 10 });
        }
        .width('100%')
        .height(46)
        .padding({ left: 14, right: 8 })
        .borderRadius(15)
        .backgroundColor('rgba(233,238,246,0.90)')
        .border({ width: 1, color: 'rgba(203,213,228,0.80)' });
      }
      Button(this.cameraTransport === 0 && this.cam.cameraState === 2 ? '删除连接' :
        (this.cam.cameraState === 1 ? '连接中…' : (this.cameraTransport === 1 ? '连接 USB 相机' :
          (this.cameraPairingAttempted ? '已注册' : '确认连接'))))
        .width('100%')
        .height(44)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryCameraActionEnabled() ? $r('app.color.vivid_text_ffffff') : '#7B8798')
        .type(ButtonType.Capsule)
        .backgroundColor(this.primaryCameraActionEnabled() ? '#202A3B' : '#D1D5DB')
        .margin({ top: 12 })
        .enabled(this.primaryCameraActionEnabled())
        .onClick(() => {
          if (this.cameraTransport === 0 && this.cam.cameraState === 2) {
            this.removeCameraConnection();
          } else {
            this.connectCameraByTransport();
          }
        });
      // 索尼线与尼康线都不再渲染这个「连接 Wi-Fi」：同一状态下下方的会话按钮
      // 已经给出「WIFI 连接」，两个入口并列属于重复。松下 Sync（camCgiRouteSelected）
      // 保持原样，不受影响。
      if (this.cameraTransport === 0 && this.selectedCameraRemembered() &&
        this.cam.cameraBrand !== 'Sony' && this.cam.cameraBrand !== 'Nikon' &&
        (this.camCgiRouteSelected() || this.isPtpIpCamera()) && !this.cameraWifiConnected()) {
        Button('连接 Wi-Fi')
          .width('100%')
          .height(36)
          .fontSize(12)
          .type(ButtonType.Capsule)
          .fontColor(this.connectWifiActionEnabled() ? this.sessionButtonTextColor() : this.sessionButtonTextColorMuted())
          .backgroundColor(this.connectWifiActionEnabled() ? this.sessionButtonFill() : this.sessionButtonFillMuted())
          .enabled(this.connectWifiActionEnabled())
          .margin({ top: 8 })
          .onClick(() => { this.connectCameraByTransportConfirmed(); });
      }
      if (this.cameraTransport === 0) {
        // 按品牌切换这一行的按钮组合。「LUT 传输」与「相机控制」是松下专属
        // 入口（cam.cgi / Lab REST），对 Nikon/Sony 恒不可用，因此对这两条
        // PTP/IP 线隐藏，避免出现一排点不动的死按钮。
        Row() {
          Button('图片传输')
            .layoutWeight(1)
            .height(36)
            .fontSize(11)
            .fontColor(this.imageTransferActionEnabled() ? this.sessionButtonTextColor() : this.sessionButtonTextColorMuted())
            .type(ButtonType.Capsule)
            .backgroundColor(this.imageTransferActionEnabled() ? this.sessionButtonFill() : this.sessionButtonFillMuted())
            .backdropBlur(this.imageTransferActionEnabled() ? this.sessionButtonBlur() : 6)
            .shadow(this.sessionButtonShadow())
            .enabled(this.imageTransferActionEnabled())
            .onClick(() => {
              AppLogStore.add('ui 打开图片传输页');
              // 佳能线：BLE 注册 → WAP 拉起相机 AP → 关联 Wi‑Fi → 进图传页。
              if (this.cam.cameraBrand === CANON_BRAND) {
                this.openCanonEntry('image').catch((error: Error): void => {
                  AppLogStore.add(`[CANON] 打开图片传输失败: ${error.message}`);
                });
                return;
              }
              // 富士线：先蓝牙拉起相机 AP + 关联 Wi‑Fi，再进图片传输页（§3.4）。
              if (this.cam.cameraBrand === FUJIFILM_BRAND) {
                this.openFujifilmEntry('image').catch((error: Error): void => {
                  AppLogStore.add(`[FUJI] 打开图片传输失败: ${error.message}`);
                });
                return;
              }
              // 索尼线：「确认连接」只配对蓝牙，相机 Wi‑Fi 直到用户真正点
              // 「图片传输」时才由蓝牙取凭据并关联，随后才进入 PTP/IP 内容
              // 枚举。见 openSonyImageTransfer / ensureSonyWifiForAction。
              if (this.cam.cameraBrand === 'Sony') {
                this.openSonyImageTransfer();
                return;
              }
              // Sync 路线：点击图片传输触发相机控制的握手（已连接时跳过
              // Wi-Fi 段），随后进入 DMS 主动拉取模式（对齐相机控制页），
              // 每次进入重新拉取相机图库。被动推送仅由「确认连接」触发。
              // Sync 线：先蓝牙握手（相机经 BLE 下发 SSID/密码拉起 Wi-Fi），
              // 再进入主动拉取的 DMS 模式。
              if (this.cam.cameraBrand === 'Panasonic' && this.syncRouteSelected()) {
                this.openSyncImageTransferFromHome();
                return;
              }
              // Image App 线完全没有蓝牙，不能进上面的蓝牙握手，改为手动接入
              // 相机热点后走被动接收/cam.cgi 浏览（传输协议与 Sync 线相同）。
              if (this.cam.cameraBrand === 'Panasonic' && this.imageAppSelected()) {
                this.openImageAppImageTransfer();
                return;
              }
              if (this.cam.cameraBrand === 'Nikon') {
                // 尼康线显式入口：与下面的通用兜底行为一致，但保留独立日志，
                // 便于把尼康线的进入路径与「其它品牌落到兜底」区分开。
                this.openNikonImageTransfer();
                return;
              }
              // 控制页（Sync 线）可能覆盖过 store.driver，从首页进入前
              // 重新注册本页 driver，并复位主动拉取标记。
              this.cam.syncPullActive = false;
              this.registerCameraSessionDriver();
              this.getUIContext().getRouter().pushUrl({ url: 'pages/LumixImageTransferPage' });
            });
          // 松下专属：LUT 传输 + 相机控制。Image App 线只保留图片传输。
          if (this.cam.cameraBrand === 'Panasonic' && !this.imageAppSelected()) {
            Button('LUT 传输')
              .layoutWeight(1)
              .height(36)
              .fontSize(11)
              .margin({ left: 8 })
              .fontColor(this.lutTransferActionEnabled() ? this.sessionButtonTextColor() : this.sessionButtonTextColorMuted())
              .type(ButtonType.Capsule)
              .backgroundColor(this.lutTransferActionEnabled() ? this.sessionButtonFill() : this.sessionButtonFillMuted())
              .backdropBlur(this.lutTransferActionEnabled() ? this.sessionButtonBlur() : 6)
              .shadow(this.sessionButtonShadow())
              .enabled(this.lutTransferActionEnabled())
              .onClick(() => { this.openLutTransfer(); });
            Button('相机控制')
              .layoutWeight(1)
              .height(36)
              .fontSize(11)
              .margin({ left: 8 })
              .fontColor(this.cameraControlActionEnabled() ? this.sessionButtonTextColor() : this.sessionButtonTextColorMuted())
              .type(ButtonType.Capsule)
              .backgroundColor(this.cameraControlActionEnabled() ? this.sessionButtonFill() : this.sessionButtonFillMuted())
              .backdropBlur(this.cameraControlActionEnabled() ? this.sessionButtonBlur() : 6)
              .shadow(this.sessionButtonShadow())
              .enabled(this.cameraControlActionEnabled())
              .onClick(() => { this.openCameraControl(); });
          }
          // Nikon 线（PTP/IP）独立控制页。
          if (this.cam.cameraBrand === 'Nikon') {
            Button('相机控制')
              .layoutWeight(1)
              .height(36)
              .fontSize(11)
              .margin({ left: 8 })
              .fontColor(this.nikonControlActionEnabled() ? this.sessionButtonTextColor() : this.sessionButtonTextColorMuted())
              .type(ButtonType.Capsule)
              .backgroundColor(this.nikonControlActionEnabled() ? this.sessionButtonFill() : this.sessionButtonFillMuted())
              .backdropBlur(this.nikonControlActionEnabled() ? this.sessionButtonBlur() : 6)
              .shadow(this.sessionButtonShadow())
              .enabled(this.nikonControlActionEnabled())
              .onClick(() => { this.openNikonCameraControl(); });
          }
          // 索尼线（PTP/IP）独立控制页：索尼与尼康同为 ISO 15740 标准
          // PTP/IP，共用同一传输服务。
          if (this.cam.cameraBrand === 'Sony') {
            Button('索尼控制')
              .layoutWeight(1)
              .height(36)
              .fontSize(11)
              .margin({ left: 8 })
              .fontColor(this.sonyControlActionEnabled() ? this.sessionButtonTextColor() : this.sessionButtonTextColorMuted())
              .type(ButtonType.Capsule)
              .backgroundColor(this.sonyControlActionEnabled() ? this.sessionButtonFill() : this.sessionButtonFillMuted())
              .backdropBlur(this.sonyControlActionEnabled() ? this.sessionButtonBlur() : 6)
              .shadow(this.sessionButtonShadow())
              .enabled(this.sonyControlActionEnabled())
              .onClick(() => { this.openSonyCameraControl(); });
          }
          // 富士线（PTP-IP）独立控制页。布局与松下 LAB 同构：第一行
          // [图片传输][相机控制]，第二行 [WIFI 连接][固件更新]，没有 LUT 传输。
          if (this.cam.cameraBrand === FUJIFILM_BRAND) {
            Button('相机控制')
              .layoutWeight(1)
              .height(36)
              .fontSize(11)
              .margin({ left: 8 })
              .fontColor(this.imageTransferActionEnabled() ? this.sessionButtonTextColor() : this.sessionButtonTextColorMuted())
              .type(ButtonType.Capsule)
              .backgroundColor(this.imageTransferActionEnabled() ? this.sessionButtonFill() : this.sessionButtonFillMuted())
              .backdropBlur(this.imageTransferActionEnabled() ? this.sessionButtonBlur() : 6)
              .shadow(this.sessionButtonShadow())
              .enabled(this.imageTransferActionEnabled())
              .onClick(() => {
                AppLogStore.add('ui 打开相机控制页（FUJIFILM）');
                this.openFujifilmEntry('control').catch((error: Error): void => {
                  AppLogStore.add(`[FUJI] 打开相机控制失败: ${error.message}`);
                });
              });
          }
          // 佳能线独立控制页。按钮布局照松下 LAB：第一行 [图片传输][相机控制]，
          // 第二行 [WIFI 连接][固件更新]，**没有 LUT 传输**。
          if (this.cam.cameraBrand === CANON_BRAND) {
            Button('相机控制')
              .id('canonCameraControlEntry')
              .layoutWeight(1)
              .height(36)
              .fontSize(11)
              .margin({ left: 8 })
              .fontColor(this.imageTransferActionEnabled() ? this.sessionButtonTextColor() : this.sessionButtonTextColorMuted())
              .type(ButtonType.Capsule)
              .backgroundColor(this.imageTransferActionEnabled() ? this.sessionButtonFill() : this.sessionButtonFillMuted())
              .backdropBlur(this.imageTransferActionEnabled() ? this.sessionButtonBlur() : 6)
              .shadow(this.sessionButtonShadow())
              .enabled(this.imageTransferActionEnabled())
              .onClick(() => {
                AppLogStore.add('ui 打开相机控制页（Canon）');
                this.openCanonEntry('control').catch((error: Error): void => {
                  AppLogStore.add(`[CANON] 打开相机控制失败: ${error.message}`);
                });
              });
          }
        }
        .width('100%')
        .margin({ top: 8 });
        // Wi‑Fi 会话按钮：接管原「图片传输」的会话发起/关闭职责。Sync 线在
        // 已连接时提供「断开 Wi-Fi」（官方无会话退出命令，靠相机轮询空闲
        // 超时自动收摊，此处只清会话并移除候选配置）。
        // 松下线额外并列一个「固件更新」入口（见 openFirmwareUpdate）。
        Row() {
          Button(this.cam.cameraTransferInProgress ? '正在建立 Wi‑Fi 会话…' :
            (this.camCgiRouteSelected() ? (this.cameraWifiConnected() ? '断开 Wi-Fi' : '由相机端推送') :
              (this.cameraWifiConnected() ? '关闭 WIFI' : 'WIFI 连接')))
            .layoutWeight(1)
            .height(40)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.wifiSessionActionMuted() ? this.sessionButtonTextColorMuted() : this.sessionButtonTextColor())
            .type(ButtonType.Capsule)
            .backgroundColor(this.wifiSessionActionMuted() ? this.sessionButtonFillMuted() : this.sessionButtonFill())
            .backdropBlur(this.wifiSessionActionMuted() ? 6 : this.sessionButtonBlur())
            .shadow(this.sessionButtonShadow())
            .enabled(this.wifiSessionActionEnabled())
            .onClick(() => {
              // 佳能线：WIFI 连接 = 只做「拉起 AP + 关联热点」，留在本页。
              if (this.cam.cameraBrand === CANON_BRAND) {
                if (this.cameraWifiConnected()) {
                  this.closeCanonWifi().catch((error: Error): void => {
                    AppLogStore.add(`[CANON] 关闭 Wi‑Fi 失败: ${error.message}`);
                  });
                } else {
                  this.openCanonEntry('wifi').catch((error: Error): void => {
                    AppLogStore.add(`[CANON] WIFI 连接失败: ${error.message}`);
                  });
                }
                return;
              }
              // 富士线：WIFI 连接 = 只做「拉起 AP + 关联热点」，留在本页。
              if (this.cam.cameraBrand === FUJIFILM_BRAND) {
                if (this.cameraWifiConnected()) {
                  this.closeFujifilmWifi().catch((error: Error): void => {
                    AppLogStore.add(`[FUJI] 关闭 Wi‑Fi 失败: ${error.message}`);
                  });
                } else {
                  this.openFujifilmEntry('wifi').catch((error: Error): void => {
                    AppLogStore.add(`[FUJI] WIFI 连接失败: ${error.message}`);
                  });
                }
                return;
              }
              if (this.camCgiRouteSelected()) {
                if (this.cameraWifiConnected()) this.closeSyncCameraWifi();
                return;
              }
              if (this.cameraWifiConnected()) {
                this.closeCameraWifiTransfer();
              } else if (this.cam.cameraBrand === 'Panasonic' && this.cam.cameraState === 2) {
                this.runLumixImportPrototype(true);
              } else {
                this.runCameraImportPrototype(true);
              }
            });
          // 固件更新：松下线专属入口（Image App 线没有 Lab GATT，隐藏）；
          // 富士线由固件服务自己走 BLE 0x2A26 + PTP，页面只负责展示。
          if ((this.cam.cameraBrand === 'Panasonic' && !this.imageAppSelected()) ||
            this.cam.cameraBrand === FUJIFILM_BRAND || this.cam.cameraBrand === CANON_BRAND) {
            Button('固件更新')
              .layoutWeight(1)
              .height(40)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .margin({ left: 8 })
              .fontColor(this.firmwareUpdateActionEnabled() ? this.sessionButtonTextColor() : this.sessionButtonTextColorMuted())
              .type(ButtonType.Capsule)
              .backgroundColor(this.firmwareUpdateActionEnabled() ? this.sessionButtonFill() : this.sessionButtonFillMuted())
              .backdropBlur(this.firmwareUpdateActionEnabled() ? this.sessionButtonBlur() : 6)
              .shadow(this.sessionButtonShadow())
              .enabled(this.firmwareUpdateActionEnabled())
              .onClick(() => {
                if (this.cam.cameraBrand === FUJIFILM_BRAND) {
                  this.openFujifilmFirmware();
                  return;
                }
                if (this.cam.cameraBrand === CANON_BRAND) {
                  this.openCanonFirmware();
                  return;
                }
                this.openFirmwareUpdate();
              });
          }
        }
        .width('100%')
        .margin({ top: 8 });
        Text('图片浏览、勾选与下载原图请进入「图片传输」')
          .fontSize(10)
          .fontColor(this.mutedTextColor())
          .width('100%')
          .margin({ top: 8 });
      }
      Row() {
        Text(`蓝牙 ${this.cam.cameraBleStatus}`).fontSize(10).fontColor(this.cam.cameraBleStatus === '已连接' ? $r('app.color.vivid_text_1e8e5a') : this.mutedTextColor()).layoutWeight(1);
        Text(`Wi‑Fi ${this.cam.cameraWifiStatus}`).fontSize(10).fontColor(this.cam.cameraWifiStatus === '已连接' ? $r('app.color.vivid_text_1e8e5a') : this.mutedTextColor()).layoutWeight(1);
        Text(`会话 ${this.cam.cameraSessionStatus}`).fontSize(10).fontColor(this.cam.cameraSessionStatus === '已建立' ? $r('app.color.vivid_text_1e8e5a') : this.mutedTextColor());
      }
      .width('100%')
      .margin({ top: 10 });
      // 进度条**只在弹窗里出现**。相机页面这边不再重复画一条——同一件事显示两遍
      // 反而让人以为在看两个不同的进度（用户明确反馈过这一点）。
      Text(this.cam.cameraMessage)
        .fontSize(10)
        .fontColor(this.mutedTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 7 });
      Text(this.cameraTransport === 1 ? '仅使用系统 USB 授权，不上传设备数据' : '仅在局域网内访问相机，不上传设备数据')
        .fontSize(10)
        .fontColor(this.mutedTextColor())
        .margin({ top: 12 });
    }
    .width(this.isDesktop() ? '48.8%' : '100%')
    .height(348)
    .padding(20)
    .borderRadius(28)
    .attributeModifier(this.cardMaterial())
    .margin({ left: this.isDesktop() ? 16 : 0, top: 0 });
  }

  @Builder
  CapabilityCard(icon: string, title: string, subtitle: string) {
    Column() {
      Text(icon).fontSize(24).fontColor(this.isNightMode ? $r('app.color.vivid_text_c9d7f2') : $r('app.color.vivid_text_4b5e78')).width('100%');
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.panelTextColor())
        .width('100%')
        .margin({ top: 17 });
      Text(subtitle).fontSize(10).fontColor(this.mutedTextColor()).width('100%').margin({ top: 3 });
    }
    .height(128)
    .padding(16)
    .borderRadius(22)
    .attributeModifier(this.cardMaterial());
  }

  /** LUT transfer is exclusive to LUMIX Lab bodies over their camera AP.
   * Both entries start a connect-only Wi-Fi session first when the body is
   * registered but not yet linked, then route into their own page; each
   * route owns a session independent from the image-transfer line. */
  private lutControlActionReady(): boolean {
    return this.cam.cameraState === 2 && this.cam.cameraBrand === 'Panasonic' && !this.camCgiRouteSelected();
  }

  /** True when the selected body belongs to the cam.cgi family — the LUMIX Sync
   *  generation (original S5 plus GH5/GH5S/G9/GH6/G100D) or the LUMIX Image App
   *  line (G97/GX9/GF10/ZS99 and the other pre-Bluetooth bodies). Both drive the
   *  camera through cam.cgi instead of Lab's REST-over-AP, so most UI branches
   *  ask this question. Lab bodies are excluded. Code that specifically means one
   *  of the two lines must use syncRouteSelected() / imageAppSelected(). */
  private camCgiRouteSelected(): boolean {
    return this.cam.isCamCgiLineSelected();
  }

  /** The LUMIX Sync line proper: Bluetooth pairing first, Wi-Fi on demand. */
  private syncRouteSelected(): boolean {
    return this.cam.isSyncRouteSelected();
  }

  /** The LUMIX Image App line: no Bluetooth, manual Wi-Fi, passive receive. */
  private imageAppSelected(): boolean {
    return this.cam.isImageAppSelected();
  }

  /** Sync control needs either a live Wi-Fi link or a BLE candidate address. */
  private camCgiControlReady(): boolean {
    if (!this.camCgiRouteSelected()) return false;
    return this.cameraWifiConnected() || this.cameraBleCandidateDeviceId.length > 0;
  }

  private cameraControlActionReady(): boolean {
    // Image App 线只有图片传输入口，不提供相机控制。
    if (this.imageAppSelected()) return false;
    return this.lutControlActionReady() || this.camCgiControlReady();
  }

  private async openLutTransfer(): Promise<void> {
    if (!this.lutControlActionReady() || this.lutControlConnectInFlight) return;
    if (!this.cameraWifiConnected()) {
      this.lutControlConnectInFlight = true;
      try {
        await this.runLumixImportPrototype(true, true);
      } finally {
        this.lutControlConnectInFlight = false;
      }
      if (!this.cameraWifiConnected()) return;
    }
    AppLogStore.add('ui 打开 LUT 传输页');
    this.getUIContext().getRouter().pushUrl({ url: 'pages/LutTransferPage' });
  }

  private async openCameraControl(): Promise<void> {
    // Image App 线只提供图片传输：没有蓝牙配对，也不进遥控页。
    if (this.imageAppSelected()) {
      this.showMessage('Image App 线仅支持图片传输');
      return;
    }
    // Sync 线：蓝牙配对后由 BLE 下发 SSID/密码拉起相机 Wi-Fi，再进 cam.cgi
    // 控制页。
    if (this.syncRouteSelected() && this.camCgiControlReady()) {
      await this.openLumixSyncControl();
      return;
    }
    // Image App 线没有蓝牙：先按相机热点接入，再进同一个 cam.cgi 控制页
    // （控制协议与 Sync 线一致，只有 Wi-Fi 凭据来源不同）。
    if (this.imageAppSelected()) {
      if (!this.cameraWifiConnected()) await this.runPanasonicWifiOnlyImport(true);
      const linkedGateway = await LumixCameraService.linkedGateway();
      if (linkedGateway.length > 0) this.cameraHost = linkedGateway;
      if (this.cameraHost.length > 0) {
        AppStorage.setOrCreate('syncControlHost', this.cameraHost);
        AppStorage.setOrCreate('controlProtocol', 'sync');
        AppLogStore.add('ui 打开相机控制页（LUMIX Image App）');
        this.getUIContext().getRouter().pushUrl({ url: 'pages/LumixCameraControlPage' });
      }
      return;
    }
    if (!this.lutControlActionReady() || this.lutControlConnectInFlight) return;
    if (!this.cameraWifiConnected()) {
      this.lutControlConnectInFlight = true;
      try {
        await this.runLumixImportPrototype(true, true);
      } finally {
        this.lutControlConnectInFlight = false;
      }
      if (!this.cameraWifiConnected()) return;
    }
    AppStorage.setOrCreate('controlProtocol', 'lab');
    AppLogStore.add('ui 打开相机控制页');
    this.getUIContext().getRouter().pushUrl({ url: 'pages/LumixCameraControlPage' });
  }

  /** Nikon 线（PTP/IP）：蓝牙已配对（或已在相机 Wi‑Fi 上）即可点击。
   *
   * 与索尼线同构：不再要求 PTP/IP 会话先行建立——会话会在点击时按需拉起
   * （见 openNikonCameraControl）。尼康与索尼共用 NikonPtpIpService 的传输层
   * （同为 ISO 15740 标准 PTP/IP）。 */
  private nikonControlActionReady(): boolean {
    if (this.cam.cameraBrand !== 'Nikon') return false;
    if (this.cam.cameraTransferInProgress) return false;
    // 已有控制会话：直接进管线，不再发任何握手。
    if (NikonPtpIpService.isControlReady()) return true;
    // 已在相机 Wi-Fi 上：直接建 PTP/IP 会话（那是会话，不是蓝牙握手），
    // 不需要再走一次「蓝牙 → 拉起热点」。
    if (this.cameraWifiConnected()) return true;
    // 蓝牙还在：可以就地拉起。
    if (this.cam.cameraBleStatus === '已连接') return true;
    // **与「图片传输」同级。**
    //
    // 原来这里到上一行就结束了，于是配网完成后按钮必然发灰：**拉起热点必须断开
    // 蓝牙**（相机同一时刻只能跑一路无线，这是实测结论），所以热点起来时
    // `cameraBleStatus` 一定是断开的，而 `cameraWifiConnected()` 在用户还没接入
    // 时也是 false —— 两个条件同时不成立，按钮就永远点不动。
    //
    // 但「相机控制」与「图片传输」是同级入口：未连接 Wi-Fi 时都应当由自己把
    // Wi-Fi 拉起来。所以这里放宽到「这台相机是已保存 / 已注册的」——点下去会重新
    // 建立蓝牙并按需拉起热点，而不是把按钮置灰。真正的拦截在
    // `cameraOfflineLocked()`：相机确实不可达时依旧置灰。
    return this.selectedCameraRemembered() || this.cam.cameraState === 2;
  }

  /** 尼康线控制页入口：先按需拉起相机 Wi‑Fi，再建立控制会话，最后进入控制页。
   *
   * 控制页只消费会话、不自己连接，所以会话必须在这里就绪：Wi‑Fi 拉起失败时
   * 只报告失败并停在首页，绝不进入控制步骤。
   *
   * 尼康使用独立的 NikonCameraControlPage 入口；页面内部复用
   * CameraControlView，由 AppStorage 'controlProtocol' = 'nikon' 选中尼康分支
   * （布局复用松下 Lab 线，按钮面复用索尼线：实时取景 0x9201/0x9203/0x9202 +
   * 快门 0x9207）；没有读取通道的参数面板经 CameraControlBrand 显示为「不可用」。 */
  private async openNikonCameraControl(): Promise<void> {
    if (!this.nikonControlActionReady()) return;
    AppLogStore.add('ui 打开尼康相机控制页');
    try {
      const wifiReady = await this.ensureNikonWifiForAction('相机控制');
      if (!wifiReady) return;
      if (!NikonPtpIpService.isControlReady()) {
        // 与图片传输共用同一个 PTP/IP 会话；这里只建立会话，不下发任何
        // 内容传输模式指令。
        await NikonPtpIpService.acquireSession(this.cameraHost);
      }
      if (!NikonPtpIpService.isControlReady()) {
        this.cam.cameraSessionStatus = '未建立';
        this.cam.cameraMessage = '尼康相机控制会话未建立，请重新连接后再试';
        return;
      }
      this.cam.cameraSessionStatus = '已建立';
      AppStorage.setOrCreate('controlProtocol', 'nikon');
      this.getUIContext().getRouter().pushUrl({ url: 'pages/NikonCameraControlPage' });
    } catch (error) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = `尼康相机控制未启动：${(error as Error).message}`;
      AppLogStore.add(`nikon-control failed: ${String(error)}`);
    }
  }

  /** 索尼线（PTP/IP）：蓝牙已配对（或已在相机 Wi‑Fi 上）即可点击。
   *
   * 不再要求 PTP/IP 会话先行建立——「确认连接」现在只配对蓝牙，会话会在点击
   * 时按需拉起（见 openSonyCameraControl）。索尼与尼康共用 NikonPtpIpService
   * 的传输层（同为 ISO 15740 标准 PTP/IP）。 */
  private sonyControlActionReady(): boolean {
    if (this.cam.cameraBrand !== 'Sony') return false;
    if (this.cam.cameraTransferInProgress) return false;
    if (NikonPtpIpService.isControlReady()) return true;
    // 插着 USB 时不必先连蓝牙/Wi‑Fi：控制页会走 PTP over USB。
    if (!this.cameraWifiConnected() && SonyUsbPtp.hasDevice()) return true;
    return this.cam.cameraBleStatus === '已连接' || this.cameraWifiConnected();
  }

  /** 索尼线控制页入口：先按需拉起相机 Wi‑Fi，再建立控制会话，最后进入控制页。
   *
   * 控制页只消费会话、不自己连接，所以会话必须在这里就绪：Wi‑Fi 拉起失败时
   * 只报告失败并停在首页，绝不进入控制步骤。 */
  private async openSonyCameraControl(): Promise<void> {
    if (!this.sonyControlActionReady()) return;
    AppLogStore.add('ui 打开索尼相机控制页');
    try {
      // 没有 Wi‑Fi、但插着 USB：直接走 USB 通道（含授权与 SDIO 会话），
      // 成功后 connectSonyUsb 会回到这里并进入控制页。
      if (!this.cameraWifiConnected() && !SonyPtpIpContent.isUsbSession() &&
        SonyUsbPtp.hasDevice()) {
        await this.connectSonyUsb(SonyUsbPtp.MODE_REMOTE_CONTROL);
        return;
      }
      const wifiReady = await this.ensureSonyWifiForAction('相机控制');
      if (!wifiReady) return;
      if (!NikonPtpIpService.isControlReady()) {
        // 与图片传输共用同一个 PTP/IP 会话；这里只建立会话，不下发任何
        // 内容传输模式指令。
        await NikonPtpIpService.acquireSession(this.cameraHost);
      }
      if (!NikonPtpIpService.isControlReady()) {
        this.cam.cameraSessionStatus = '未建立';
        this.cam.cameraMessage = '索尼相机控制会话未建立，请重新连接后再试';
        this.showSonyFailure('control', '索尼相机控制会话未建立，请重新连接后再试', '', '索尼相机控制未启动');
        return;
      }
      this.cam.cameraSessionStatus = '已建立';
      // 索尼使用独立的 SonyCameraControlPage 入口；页面内部复用 CameraControlView，
      // 由 AppStorage 'controlProtocol' = 'sony' 选中索尼分支（实时取景 + 快门；
      // 没有读取通道的参数面板经 CameraControlBrand 显示为「不可用」）。
      AppStorage.setOrCreate('controlProtocol', 'sony');
      this.getUIContext().getRouter().pushUrl({ url: 'pages/SonyCameraControlPage' });
    } catch (error) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = `索尼相机控制未启动：${(error as Error).message}`;
      AppLogStore.add(`sony-control failed: ${String(error)}`);
      this.showSonyFailure('control', `索尼相机控制未启动：${(error as Error).message}`, '', '索尼相机控制未启动');
    }
  }

  // -------------------------------------------------------------------------
  // 固件更新（松下线入口，见 openFirmwareUpdate）
  // -------------------------------------------------------------------------

  /**
   * 固件更新入口的可用性。
   *
   * **只看蓝牙，不看 Wi‑Fi**——这是被相机网络拓扑决定的，不是取巧：
   * 相机 AP 是隔离网段（192.168.54.1/24，无上行）。一旦手机连上相机
   * Wi‑Fi，就同时失去了访问 panasonic.jp 的能力，而固件目录与固件包恰恰
   * 只能从那里取。所以"必须先连 Wi‑Fi 才亮按钮"等于把功能锁死。
   *
   * 官方同样是这个顺序：机型与机身版本经 BLE 读取，下载阶段反而要求
   * **断开**相机 Wi‑Fi（报告 §2.5：弹 K9「断开相机 Wi‑Fi？」，确认后断开），
   * 传完再连回去。
   */
  private firmwareUpdateActionReady(): boolean {
    // 富士线：固件页自己走 BLE 0x2A26 + PTP，只要有目标机身（或已在相机热点上）
    // 就允许进入；读不到版本时页面自己会提示，不应该在首页把入口锁死。
    if (this.cam.cameraBrand === FUJIFILM_BRAND) {
      return this.fujifilmTargetReady() || this.cam.cameraBleStatus === '已连接' ||
        this.cameraWifiConnected();
    }
    // 佳能线：固件页自己走 BLE 2A26 + PTP/IP；有目标机身或已在相机热点上就
    // 允许进入，读不到版本时页面自己提示（与富士同样的取舍）。
    if (this.cam.cameraBrand === CANON_BRAND) {
      return this.canonTargetReady() || this.cam.cameraBleStatus === '已连接' ||
        this.cameraWifiConnected();
    }
    if (this.cam.cameraBrand !== 'Panasonic') return false;
    // BLE 链路是读机型/版本的唯一通道。已连 Wi‑Fi 也算就绪：此时按钮仍可
    // 点击，流程会先引导用户临时断开相机 Wi‑Fi 以取回互联网。
    return this.cam.cameraBleStatus === '已连接' || this.cameraWifiConnected();
  }

  /** 断开相机 Wi‑Fi 前的确认：因为要临时交出互联网通路。 */
  private confirmReleaseCameraWifi(): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      try {
        this.getUIContext().showAlertDialog({
          title: '需要临时断开相机 Wi-Fi',
          message: '固件要从松下官网下载，而相机 Wi-Fi 无法上网。\n'
            + '将临时断开相机 Wi-Fi 以便手机联网下载固件，下载完成后再重新连接相机 Wi-Fi 进行传输。',
          autoCancel: true,
          alignment: DialogAlignment.Center,
          buttons: [
            { value: '取消', action: (): void => { resolve(false); } },
            { value: '断开并下载', action: (): void => { resolve(true); } },
          ],
        });
      } catch (_error) {
        resolve(false);
      }
    });
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }

  /**
   * 固件更新的二次确认。
   *
   * 官方在下载前有两道 UI：EULA 确认弹窗（C5/C0415z4）与升级警告页
   * （assets/fup-warning-notice/，11 语言 HTML），核心警告是"写入过程中
   * 不得断电或拔卡"。这里合并为一个确认框，把机型、版本变化、以及该风险
   * 讲清楚；用户取消则不发起任何下载与传输。
   */
  private confirmFirmwareUpdate(entry: FirmwareCatalogEntry, state: LumixFirmwareVersionState,
    detail: LumixFirmwareDetail, eulaUrl: string = ''): Promise<boolean> {
    const lines: string[] = [
      `机型：${entry.name}${state.modelName.length > 0 && state.modelName !== entry.name ? `（${state.modelName}）` : ''}`,
      `当前版本：${state.cameraFirmware.length > 0 ? state.cameraFirmware : '未知'}`,
      `更新版本：${entry.version}`,
    ];
    if (detail.date.length > 0) lines.push(`发布日期：${detail.date}`);
    lines.push('');
    lines.push('更新过程中请勿关闭相机电源、断开连接或取出存储卡，否则可能导致相机无法启动。');
    if (eulaUrl.length > 0) {
      // 官网的下载受 EULA 表单把关（download_*.cgi 的 "Accepted"）。这里如实
      // 告知用户"继续即接受"，不代替他静默接受。
      lines.push('');
      lines.push('继续即表示接受松下官方的固件使用许可协议。');
      AppLogStore.add(`firmware eula ${eulaUrl}`);
    }
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      try {
        this.getUIContext().showAlertDialog({
          title: '更新相机固件',
          message: lines.join('\n'),
          autoCancel: true,
          alignment: DialogAlignment.Center,
          buttons: [
            {
              value: '取消',
              action: (): void => {
                resolve(false);
              },
            },
            {
              value: '开始更新',
              action: (): void => {
                resolve(true);
              },
            },
          ],
        });
      } catch (_error) {
        // 弹窗不可用时宁可不更新，也不能静默开始写入。
        resolve(false);
      }
    });
  }

  /** 打开固件更新模态进度窗；已开着就只刷新内容。 */
  private openFirmwareProgress(status: string, percent: number): void {
    this.reportFirmwareProgress(status, percent);
    if (!this.firmwareDialogController) {
      this.firmwareDialogController = new CustomDialogController({
        builder: FirmwareUpdateProgressDialog(),
        autoCancel: false,
        alignment: DialogAlignment.Center,
        customStyle: true,
      });
      this.firmwareDialogController.open();
    }
  }

  /** 刷新进度窗文字与百分比（-1 = 不确定进度），同时同步底部小字。 */
  private reportFirmwareProgress(status: string, percent: number = -1): void {
    this.cam.cameraMessage = status;
    this.firmwareDialogStatus = status;
    this.firmwareDialogPercent = percent;
  }

  /**
   * 收起进度窗。需要让位给**要用户点击**的对话框时必须先收：确认弹窗和系统
   * 权限框都会和它抢层级，遮住就等于把流程卡死。Sync 流程为系统「信任此
   * Wi-Fi」框让位是同一个道理（见 pairAndConnect 回调里的注释）。
   */
  private hideFirmwareProgress(): void {
    if (this.firmwareDialogController) {
      this.firmwareDialogController.close();
      this.firmwareDialogController = null;
    }
  }

  /**
   * 固件更新入口。
   *
   * 顺序由相机网络拓扑决定，四段各有自己的前置条件：
   *   1. **蓝牙读机型/版本**——不需要 Wi‑Fi，也不需要互联网。按钮在这一步
   *      之前就已可用（`firmwareUpdateActionReady` 只看 BLE）。
   *   2. **取回互联网**——相机 AP 无上行，若当前连着相机 Wi‑Fi 必须先断开
   *      （官方 §2.5 同做法），否则第 3 步必然失败。
   *   3. **拉目录 + 下载解压到手机**——需要互联网，且必须在重连相机 Wi‑Fi 前
   *      完成，否则固件根本拿不到。
   *   4. **重连相机 Wi‑Fi 建立会话 → 送入机身**——`/firmware/send-prepare` +
   *      分块 `/firmware/send`，全程复用一条连接；相机没有 finalize 请求，
   *      写入完成由 BLE `16726c35` 上报。
   */
  private async openFirmwareUpdate(): Promise<void> {
    if (!this.firmwareUpdateActionReady()) return;
    if (this.cam.cameraTransferInProgress) {
      this.showMessage('相机连接流程正在进行中，请稍后重试');
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!context) {
      this.showMessage('无法获取应用上下文');
      return;
    }
    this.cam.cameraTransferInProgress = true;
    try {
      AppLogStore.add('ui 点击固件更新');
      // 全程锁定界面：写入机身固件不可逆，五个阶段（蓝牙读版本 / 联网拉包 /
      // 解压 / 重连相机 Wi-Fi / 分块传输）加起来可达十几分钟。只把进度写在
      // 页面底部小字里，用户既看不清进展，也拦不住误触其它入口。
      this.openFirmwareProgress('正在准备固件更新…', -1);

      // ── 1. 蓝牙读机型与固件版本（无需 Wi‑Fi / 互联网）────────────────
      // 四个版本特征必须在**已完成应用层注册**的 GATT 会话里读。实测（2026-10-16
      // S1RM2）：裸连接（connect + getServices 后直接读）四次读在同一毫秒内全部
      // 被本地协议栈拒绝——2900099 / -1028 / 2900007 / 2901003（后者官方释义
      // "The connection is not established"）；而注册过的会话里同特征可读。
      // 所以先补一次 BLE-only 配对注册，再从保留链路读版本。
      if (!LumixImportPrototype.hasRegisteredBleSession()) {
        this.reportFirmwareProgress('正在建立相机蓝牙会话…');
        AppLogStore.add('firmware 无已注册蓝牙会话，先执行 BLE-only 注册');
        const atManager = abilityAccessCtrl.createAtManager();
        await atManager.requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
        const registered = await LumixImportPrototype.run(context, '',
          (update: LumixImportPhaseUpdate): void => {
            if (update.message.length > 0) this.reportFirmwareProgress(update.message);
          }, this.cameraBleCandidateDeviceId, true, false, this.cam.selectedSd, true);
        // AppLogStore 的内存缓冲只有 300 行，注册 trace 含整张特征清单（49+ 条），
        // 成功时只记结论；失败时才把完整 trace 落下来供定位。
        if (!registered.ok) {
          for (const line of registered.trace) AppLogStore.add(`firmware ble ${line}`);
        }
        AppLogStore.add(`firmware ble register ok=${registered.ok ? 'yes' : 'no'}`
          + ` session=${LumixImportPrototype.hasRegisteredBleSession() ? 'retained' : 'none'}`);
        // run() 正常路径会保留链路；没有链路就读不到版本，直接给出结论。
        if (!LumixImportPrototype.hasRegisteredBleSession()) {
          const message = '未能建立相机蓝牙会话，无法读取固件版本，请确认相机蓝牙已开启并已配对';
          this.reportFirmwareProgress(message);
          this.showMessage(message);
          return;
        }
      }
      this.reportFirmwareProgress('正在通过蓝牙读取相机机型与固件版本…');
      const identity = await LumixImportPrototype.readFirmwareIdentity(context,
        this.cameraBleCandidateDeviceId);
      for (const line of identity.trace) AppLogStore.add(`firmware ${line}`);
      if (identity.modelName.length === 0) {
        const message = '未能通过蓝牙读取机型与固件版本，请确认相机已在蓝牙范围内并已配对';
        this.reportFirmwareProgress(message);
        AppLogStore.add(`firmware ${message}`);
        this.showMessage(message);
        return;
      }
      AppLogStore.add(`firmware identity model=${identity.modelName} fw=${identity.cameraFirmware}`);

      // ── 2. 腾出互联网：相机 AP 无法访问松下官网 ──────────────────────
      if (this.cameraWifiConnected()) {
        // 确认框需要用户点击，模态进度窗必须先让位，否则两者抢层级会挡住它。
        this.hideFirmwareProgress();
        const approvedRelease = await this.confirmReleaseCameraWifi();
        if (!approvedRelease) {
          this.reportFirmwareProgress('已取消固件更新');
          AppLogStore.add('ui 取消固件更新（未断开相机 Wi-Fi）');
          return;
        }
        this.openFirmwareProgress('正在断开相机 Wi-Fi 以获取互联网…', -1);
        await LumixImportPrototype.disconnectCameraWifi();
        this.cam.cameraWifiStatus = '未连接';
        this.cam.cameraSessionStatus = '未建立';
        // 系统切换网络需要时间，立刻发请求会打在旧路由上。
        await this.delay(1500);
        AppLogStore.add('firmware 已断开相机 Wi-Fi 以获取互联网');
      }

      // ── 3. 官网比对 + 下载到手机（需要互联网）───────────────────────
      this.reportFirmwareProgress(`相机 ${identity.modelName} · 当前固件 ${identity.cameraFirmware}，正在检查更新…`);
      // 官网下载页是唯一仍在更新的渠道：App 自己的 firmware_list.json 自
      // 2026-06-10 起就是空壳（2026-10-16 实测仍返回 {"dsc":[],"lens":[]}），
      // 而官网已发布 S1RM2 Ver.1.6。官方目录接口保留为兜底。
      const webUpdate = await LumixFirmwareService.resolveWebUpdate(identity);
      for (const line of webUpdate.trace) AppLogStore.add(`firmware ${line}`);
      AppLogStore.add(`firmware inspect ${webUpdate.state.message}`);
      let entry: FirmwareCatalogEntry | null = null;
      let detail: LumixFirmwareDetail | null = null;
      let web: LumixWebFirmware | null = null;
      let notice = webUpdate.state.message;
      if (webUpdate.web !== null) {
        // 官网给出了权威答案：有更新就用官网包，已是最新就到此为止，不再
        // 去问那个空壳目录。
        if (webUpdate.state.entry !== null && !webUpdate.state.upToDate) {
          web = webUpdate.web;
          entry = webUpdate.state.entry;
        }
      } else {
        // 官网够不到（无网 / 页面改版）时退回官方目录接口兜底。
        const fallback = await LumixFirmwareService.resolveUpdate(identity);
        AppLogStore.add(`firmware catalog fallback ${fallback.message}`);
        if (fallback.entry !== null && !fallback.upToDate && !fallback.blockedByBody) {
          entry = fallback.entry;
          notice = fallback.message;
        } else if (fallback.message.length > 0) {
          notice = fallback.message;
        }
      }
      if (entry === null) {
        // 无可用更新（官网无该机型 / 已是最新 / 目录为空）都只是告知，
        // 不发起任何固件请求。
        this.reportFirmwareProgress(notice);
        this.showMessage(notice);
        return;
      }
      const update = entry;
      if (web !== null) {
        // 官网路径自带 zip 地址，不需要目录那套元数据接口。
        detail = {
          ok: true, name: identity.modelName, version: web.version, date: '',
          size: web.fileBytes > 0 ? String(web.fileBytes) : '',
          basePath: '', firmUrl: web.fileUrl, message: '',
        };
      } else {
        const fetched = await LumixFirmwareService.fetchDetail(update, []);
        if (!fetched.ok) {
          this.reportFirmwareProgress(fetched.message);
          this.showMessage(fetched.message);
          return;
        }
        detail = fetched;
      }
      const confirmedDetail = detail;
      const eulaUrl = web !== null ? web.eulaUrl : '';
      // 固件写入不可逆且失败会变砖，官方在下载前也有 EULA 确认与 11 语言
      // 警告页（assets/fup-warning-notice/）。这里必须先让用户确认，不能
      // 静默开始下载和传输。确认框要读要选，先收起进度窗让它显示在最上层。
      this.hideFirmwareProgress();
      const approved = await this.confirmFirmwareUpdate(update, webUpdate.state, confirmedDetail, eulaUrl);
      if (!approved) {
        this.reportFirmwareProgress('已取消固件更新');
        AppLogStore.add('ui 取消固件更新');
        return;
      }
      // 用户已确认：从这里开始写入不可逆，重新锁定界面并给出确定进度。
      this.openFirmwareProgress(`正在下载固件 ${update.version}…`, 0);
      this.cam.cameraMessage = `正在下载固件 ${update.version}…`;
      // 这条链路的诊断只在 trace 里，之前这里传空数组，导致下载失败时日志
      // 只剩一句"固件下载失败"、看不到任何错误码。必须回写。
      const downloadTrace: string[] = [];
      const pack = web !== null
        ? await LumixFirmwareService.downloadWebPackage(context, web, identity.modelName, downloadTrace,
          (percent: number): void => {
            this.cam.cameraMessage = `正在下载固件 ${update.version}… ${percent}%`;
          })
        : await LumixFirmwareService.downloadPackage(context, confirmedDetail, downloadTrace,
          (percent: number): void => {
            this.reportFirmwareProgress(`正在下载固件 ${update.version}… ${percent}%`, percent);
          });
      for (const line of downloadTrace) AppLogStore.add(`firmware ${line}`);
      if (!pack.ok) {
        this.reportFirmwareProgress(pack.message);
        this.showMessage(pack.message);
        return;
      }
      AppLogStore.add(`firmware package ready file=${pack.fileName} bytes=${pack.bytes}`);
      // ── 4. 重连相机 Wi-Fi 建立会话，再把固件送入机身 ────────────────
      // 固件已经在手机上，这一步不再需要互联网。相机传输必须走相机 AP 的
      // /firmware/* 端点，所以现在把 Wi-Fi 连回去并重新认证。
      if (!this.cameraWifiConnected()) {
        // 关联相机热点这段没有可报的百分比（系统侧不暴露），退回转圈。
        this.reportFirmwareProgress('正在连接相机 Wi-Fi 以传输固件…', -1);
        AppLogStore.add('firmware 重新连接相机 Wi-Fi');
        await this.runLumixImportPrototype(true, true);
        // runLumixImportPrototype 会在 finally 里清掉这个标志，传输期间必须重新按住。
        this.cam.cameraTransferInProgress = true;
        if (this.cam.cameraSessionStatus !== '已建立') {
          const message = '无法建立相机会话，固件未传输。请重新连接相机 Wi-Fi 后重试。';
          this.reportFirmwareProgress(message);
          AppLogStore.add(`firmware ${message}`);
          this.showMessage(message);
          return;
        }
      }
      this.reportFirmwareProgress(`正在向相机传输固件 ${update.version}…`, 0);
      // 卡槽：双卡/LAB 机型按当前选择的卡写入；报告记载空串由相机自行
      // 决定，这里沿用 UI 上已选的槽位，避免写错卡。
      const slot = this.cam.selectedSd === 'SD2' ? 'SD2' : 'SD1';
      const result = await LumixFirmwareService.sendToCamera(context, update, confirmedDetail, pack, slot,
        (progress: LumixFirmwareProgress): void => {
          this.reportFirmwareProgress(progress.message, progress.percent);
        });
      for (const line of result.trace) AppLogStore.add(`firmware ${line}`);
      AppLogStore.add(`firmware result stage=${result.stage} ok=${result.ok ? 'yes' : 'no'}`);
      // 传输成功就没有再留着包的理由：解压出来的 .bin 有 162 MB。失败则刻意
      // 保留，让用户补电后直接重试而不必再下 143 MB。
      if (result.ok) LumixFirmwareService.discardPackage(pack);
      this.reportFirmwareProgress(result.message, result.ok ? 100 : -1);
      this.showMessage(result.message);
    } catch (error) {
      const message = `固件更新失败：${error instanceof Error ? error.message : String(error)}`;
      AppLogStore.add(message);
      this.reportFirmwareProgress(message);
      this.showMessage(message);
    } finally {
      // 无论成功、失败还是提前返回，都必须收起模态锁，否则整页按钮会一直被
      // 盖住点不动（这和 cameraTransferInProgress 卡住是同一类事故）。
      this.hideFirmwareProgress();
      this.cam.cameraTransferInProgress = false;
      // 据实同步一次链路状态再放行 UI：固件流程结束时通常仍握有 BLE 链路，
      // 但 cameraBleStatus 在"注册被跳过"或"注册失败"这两条路径上不会刷新，
      // 标签一旦停在'未连接'，cameraOfflineLocked() 就会把整页按钮一起锁死。
      const retained = LumixImportPrototype.hasRegisteredBleSession();
      if (retained) {
        this.cam.cameraBleStatus = '已连接';
        if (this.cam.cameraState !== 1) this.cam.cameraState = 2;
      }
      AppLogStore.add(`firmware state ble=${this.cam.cameraBleStatus} wifi=${this.cam.cameraWifiStatus}`
        + ` session=${this.cam.cameraSessionStatus} state=${this.cam.cameraState}`
        + ` retained=${retained ? 'yes' : 'no'}`
        + ` reachable=${this.cameraIsReachable() ? 'yes' : 'no'}`
        + ` locked=${this.cameraOfflineLocked() ? 'yes' : 'no'}`);
    }
  }

  /**
   * Sync 控制握手：BLE 配对 + 相机 Wi-Fi 关联 + 网关解析。相机控制与
   * 图片传输两个入口共用；已注册相机走本地固化的 SoftAP 凭据「高速起動」
   * 直连（跳过凭据读取，Wi-Fi 与 GATT 握手并行）。手机已关联相机热点时
   * 直接返回 true（握手 Wi-Fi 段跳过）。负责开启/收起配对进度弹窗；
   * 失败写入相机状态并返回 false，成功返回 true（cameraHost 已就绪）。
   */
  private async runSyncControlHandshake(): Promise<boolean> {
    if (this.cameraWifiConnected()) {
      await this.rememberCameraCard();
      return true;
    }
    let context: common.UIAbilityContext;
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (_error) {
      this.cam.cameraMessage = '无法取得应用上下文，不能发起 LUMIX Sync 连接';
      return false;
    }
    if (this.cameraBleCandidateDeviceId.length === 0) {
      this.cam.cameraMessage = '未发现相机蓝牙，请保持相机蓝牙开启后重试';
      return false;
    }
    const direct = await LumixSyncControlService.storedDirectCredentials(context, this.cameraBleCandidateDeviceId);
    this.cam.cameraBleStatus = '连接中';
    this.cam.cameraWifiStatus = '连接中';
    this.cam.cameraMessage = '正在通过 LUMIX Sync 蓝牙握手连接相机…';
    this.syncPairDialogStatus = '正在通过 LUMIX Sync 蓝牙握手连接相机…';
    this.syncPairDialogController = new CustomDialogController({
      builder: SyncPairProgressDialog(),
      autoCancel: false,
      alignment: DialogAlignment.Center,
      customStyle: true,
    });
    this.syncPairDialogController.open();
    const pair = await LumixSyncControlService.pairAndConnect(context, this.cameraBleCandidateDeviceId,
      (status: string): void => {
        this.cam.cameraMessage = status;
        this.syncPairDialogStatus = status;
        // 系统「信任此 Wi-Fi 连接」确认框即将弹出：先收起 App 的模态进度框，
        // 避免遮挡系统框导致 30 秒超时后用户仍未点击。
        if (status.indexOf('信任') >= 0 || status.indexOf('确认框') >= 0) {
          if (this.syncPairDialogController) {
            this.syncPairDialogController.close();
            this.syncPairDialogController = null;
          }
          return;
        }
        // 系统弹窗阶段结束后的后续步骤（请求授权、准备相机控制模式约
        // 20 秒等）重新以配对进度弹窗呈现，而非只留在页面小字里。
        if (!this.syncPairDialogController) {
          this.syncPairDialogController = new CustomDialogController({
            builder: SyncPairProgressDialog(),
            autoCancel: false,
            alignment: DialogAlignment.Center,
            customStyle: true,
          });
          this.syncPairDialogController.open();
        }
      }, false, direct.ssid, direct.password);
    if (this.syncPairDialogController) {
      this.syncPairDialogController.close();
      this.syncPairDialogController = null;
    }
    if (!pair.ok) {
      this.cam.cameraBleStatus = '未连接';
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraMessage = pair.message;
      return false;
    }
    this.cameraHost = pair.gateway;
    this.cam.cameraWifiSsid = pair.ssid;
    this.cam.cameraWifiStatus = '已连接';
    this.cam.cameraBleStatus = '已连接';
    this.cam.cameraState = 2;
    this.cameraPairingAttempted = true;
    await this.rememberCameraCard(true);
    return true;
  }

  /**
   * LUMIX Image App 线（`lumix_image`）图片传输入口。该线完全没有蓝牙，所以
   * 不能走 Sync 的蓝牙握手：先按相机热点（手动选择或已记住的网络）拉起 Wi-Fi，
   * 再进入被动接收 + cam.cgi/DLNA 浏览。与 Sync 线的唯一差别是 Wi-Fi 凭据
   * 来源（手动/二维码 vs BLE 下发），传输协议完全相同。
   */
  private async openImageAppImageTransfer(): Promise<void> {
    this.cam.syncPullActive = false;
    this.registerCameraSessionDriver();
    if (!this.cameraWifiConnected()) {
      await this.runPanasonicWifiOnlyImport(true);
    }
    const linkedGateway = await LumixCameraService.linkedGateway();
    if (linkedGateway.length > 0) this.cameraHost = linkedGateway;
    AppLogStore.add('ui 打开图片传输页（LUMIX Image App）');
    this.getUIContext().getRouter().pushUrl({ url: 'pages/LumixImageTransferPage' });
  }

  /**
   * Sync-generation control entry: BLE pairing handshake -> camera Wi-Fi ->
   * accctrl session -> shared CameraControlPage in Sync protocol mode. The
   * Wi-Fi leg is skipped when the phone is already associated with the
   * body's access point.
   */
  private async openLumixSyncControl(): Promise<void> {
    if (this.lutControlConnectInFlight) return;
    this.lutControlConnectInFlight = true;
    this.cam.cameraTransferInProgress = true;
    try {
      if (!(await this.runSyncControlHandshake())) return;
      this.cam.cameraMessage = '相机 Wi-Fi 已连接，正在建立控制会话…';
      if (this.cameraHost.length === 0) {
        // Wi-Fi already associated by an earlier flow: resolve the DHCP
        // gateway so the cam.cgi page always receives a usable host.
        const linkedGateway = await LumixCameraService.linkedGateway();
        if (linkedGateway.length > 0) this.cameraHost = linkedGateway;
      }
      if (this.cameraHost.length === 0) {
        this.cam.cameraMessage = '相机网关不可用，请重新连接相机 Wi-Fi';
        return;
      }
      AppStorage.setOrCreate('syncControlHost', this.cameraHost);
      AppStorage.setOrCreate('controlProtocol', 'sync');
      AppLogStore.add('ui 打开相机控制页（LUMIX Sync）');
      this.getUIContext().getRouter().pushUrl({ url: 'pages/LumixCameraControlPage' });
    } finally {
      if (this.syncPairDialogController) {
        this.syncPairDialogController.close();
        this.syncPairDialogController = null;
      }
      this.lutControlConnectInFlight = false;
      this.cam.cameraTransferInProgress = false;
    }
  }

  /**
   * Sync 路线图片传输入口（首页「图片传输」按钮）：与相机控制共用握手
   * 逻辑（BLE 配对 + 相机 Wi-Fi，已连接时跳过 Wi-Fi 段），随后进入
   * DMS 主动拉取模式——与相机控制页的图片传输打通（同一个
   * LumixSyncGalleryDriver 形态），且每次进入都清空网格 + 新建 driver
   * 重新拉取相机图库。被动 wifi/PTP（相机端推送）仅由「确认连接」触发，
   * 不再从此入口拉起。
   */
  private async openSyncImageTransferFromHome(): Promise<void> {
    if (this.lutControlConnectInFlight || this.cam.cameraTransferInProgress) return;
    this.lutControlConnectInFlight = true;
    this.cam.cameraTransferInProgress = true;
    try {
      if (!(await this.runSyncControlHandshake())) return;
      if (this.cameraHost.length === 0) {
        const linkedGateway = await LumixCameraService.linkedGateway();
        if (linkedGateway.length > 0) this.cameraHost = linkedGateway;
      }
      if (this.cameraHost.length === 0) {
        this.cam.cameraMessage = '相机网关不可用，请重新连接相机 Wi-Fi';
        return;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // 每次进入都重新拉取：清空网格 + 新建 driver（驱动内部 DIDL 缓存
      // 一并作废），图片传输页 aboutToAppear 即触发全新 Browse。
      this.cam.cameraGalleryItems = [];
      this.cam.cameraGalleryTotal = 0;
      this.cam.cameraGalleryHasMore = false;
      this.cam.driver = new LumixSyncGalleryDriver(context, this.cameraHost);
      this.cam.cameraState = 2;
      this.cam.cameraWifiStatus = '已连接';
      this.cam.syncPullActive = true;
      AppStorage.setOrCreate('syncControlHost', this.cameraHost);
      AppLogStore.add('ui 打开图片传输页（Sync 主动拉取）');
      this.getUIContext().getRouter().pushUrl({ url: 'pages/LumixImageTransferPage' });
    } finally {
      if (this.syncPairDialogController) {
        this.syncPairDialogController.close();
        this.syncPairDialogController = null;
      }
      this.lutControlConnectInFlight = false;
      this.cam.cameraTransferInProgress = false;
    }
  }

  /** The LUMIX gallery no longer auto-starts: tapping 图片传输 only brings up
   * the Wi-Fi session, and the first real fetch happens when the user
   * scrolls the camera page. One shot per session; teardown re-arms it. */
  private async maybeTriggerLumixGalleryOnScroll(): Promise<void> {
    if (this.cam.cameraBrand !== 'Panasonic') return;
    if (this.camCgiRouteSelected()) return;
    if (this.cam.cameraState !== 2 || !this.cameraPairingAttempted) return;
    if (this.cam.cameraGalleryItems.length > 0) return;
    if (this.cam.cameraGalleryLoading || this.cam.cameraTransferInProgress || this.wifiConnecting) return;
    if (!this.cameraWifiConnected() || this.cam.cameraSessionStatus !== '已建立') return;
    if (this.cameraWifiCloseRequested) return;
    if (this.cameraGalleryScrollFetched) return;
    this.cameraGalleryScrollFetched = true;
    AppLogStore.add('ui 下滑触发松下图库加载');
    try {
      await this.runLumixImportPrototype(true);
    } catch (_error) {
    }
  }

  @Builder
  TransferContent() {
    Stack() {
      Scroll(this.cameraGalleryScroller) {
      Column() {
        this.SectionIntro('后台流程', '传输中心', '连接相机后，拍摄的照片将自动进入导入队列。');
        Column() {
          Row() {
            Column() {
              Text('本次会话').fontSize(12).fontColor(this.mutedTextColor());
              Text(this.cam.cameraGalleryItems.length > 0 ? `${this.cam.cameraGalleryItems.length} 张图片` :
                (this.transfers.length > 0 ? `${this.transfers.length} 个文件` : '0 个文件'))
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.panelTextColor())
                .margin({ top: 4 });
            }
            .alignItems(HorizontalAlign.Start);
            Blank();
            Text(this.cam.cameraState === 2 ? '已连接' : '未连接')
              .fontSize(12)
              .fontColor(this.cam.cameraState === 2 ? $r('app.color.vivid_text_19885a') : $r('app.color.vivid_text_8894a5'));
          }
          .width('100%');
          if (this.cam.cameraGalleryItems.length > 0) {
            // 图库网格、缩略图角标、多卡切换全部在独立组件里（见文件头注释：
            // 本页已经近 7000 行，图库不该再摊在这里）。页面只提供两个回调。
            NikonGallerySection({
              onOpen: (item: LumixGalleryItem): void => {
                this.openCameraImage(item);
              },
              onToggleSelect: (key: string): void => {
                this.toggleCameraGallerySelection(key);
              },
              panelTextColor: this.panelTextColor(),
              mutedTextColor: this.mutedTextColor(),
            })
          } else if (this.transfers.length > 0) {
            Progress({ value: this.transferProgress(), total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(8)
              .color('#5262EC')
              .backgroundColor($r('app.color.vivid_surface_dce2ec'))
              .borderRadius(4)
              .margin({ top: 18, bottom: 18 });
            ForEach(this.transfers, (item: TransferItem) => {
              Row() {
                Stack() {
                  Text('▧').fontSize(20).fontColor('rgba(255,255,255,0.86)');
                }
                .width(48)
                .height(48)
                .borderRadius(15)
                .backgroundColor(item.color);
                Column() {
                  Text(item.name).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor());
                  Text(item.detail).fontSize(10).fontColor(this.mutedTextColor()).margin({ top: 4 });
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 12 });
                Blank();
                if (item.progress >= 1) {
                  Text('✓').fontSize(16).fontColor($r('app.color.vivid_text_249567'));
                } else {
                  Text(`${Math.round(item.progress * 100)}%`).fontSize(12).fontColor(this.secondaryTextColor());
                }
              }
              .width('100%')
              .height(66)
              .border({ width: { bottom: 1 }, color: 'rgba(190,199,212,0.42)' });
            }, (item: TransferItem) => item.name);
          } else {
            Column() {
              Text('⇣').fontSize(40).fontColor($r('app.color.vivid_text_b3bccb'));
              Text('尚未导入图片')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.secondaryTextColor())
                .margin({ top: 10 });
              Text(this.cam.cameraState === 2 ?
                (this.camCgiRouteSelected()
                  ? `已与 ${this.cam.cameraModel} 建立接收通道，等待相机推送素材`
                  : (this.cameraWifiConnected()
                    ? `已与 ${this.cam.cameraModel} 连接，下滑开始加载相机图库`
                    : `已与 ${this.cam.cameraModel} 建立 BLE 会话，等待 Wi‑Fi 图库请求`)) :
                '连接相机后，素材会自动出现在这里')
                .fontSize(11)
                .fontColor(this.mutedTextColor())
                .textAlign(TextAlign.Center)
                .margin({ top: 6 });
              Button(this.cam.cameraTransferInProgress ? '正在建立 Wi‑Fi 会话…' :
                (this.cameraWifiConnected() && !this.camCgiRouteSelected()
                  ? (this.cam.cameraGalleryItems.length === 0 ? '重新请求相机图库' : '已读取相机图库') :
                  (this.cam.cameraState === 1 ? '正在查找…' :
                    (this.cameraTransport === 1 ? '连接 USB 相机' : '连接相机'))))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(!this.cam.cameraTransferInProgress &&
                  (this.cameraTransport === 1 ||
                    (this.cam.cameraWifiStatus === '已连接' && !this.camCgiRouteSelected() && this.cam.cameraGalleryItems.length === 0))
                  ? '#FFFFFF' : '#6B7280')
                .type(ButtonType.Capsule)
                .height(38)
                .padding({ left: 18, right: 18 })
                .backgroundColor(!this.cam.cameraTransferInProgress &&
                  (this.cameraTransport === 1 ||
                    (this.cam.cameraWifiStatus === '已连接' && !this.camCgiRouteSelected() && this.cam.cameraGalleryItems.length === 0))
                  ? '#202A3B' : '#D1D5DB')
                .margin({ top: 16 })
                .enabled(!this.cam.cameraTransferInProgress && this.cam.cameraState !== 1 &&
                  (this.cameraTransport === 1 ||
                    (!this.camCgiRouteSelected() && this.cam.cameraWifiStatus === '已连接' && this.cam.cameraGalleryItems.length === 0)))
                .onClick(() => {
                  if (this.cameraTransport === 1) this.connectCameraByTransport();
                  else if (!this.camCgiRouteSelected() && this.cameraWifiConnected()) this.runCameraImportPrototype(true);
                });
            }
            .width('100%')
            .padding({ top: 28, bottom: 28 })
            .justifyContent(FlexAlign.Center);
          }
        }
        .width('100%')
        .padding(this.isDesktop() ? 26 : 18)
        .borderRadius(28)
        .attributeModifier(this.cardMaterial());
        Row() {
          this.StatCard('0', '今日导入', '#5064ED', false);
          this.StatCard(this.freeSpaceText, '可用空间', '#7659C7', false);
          this.StatCard('原始', '命名规则', '#3A8B76', true);
        }
        .width('100%')
        .margin({ top: 14 });
      }
      .width('100%')
      .padding({ left: this.isDesktop() ? 28 : 14, right: this.isDesktop() ? 28 : 14, bottom: this.isDesktop() ? 36 : 96 });
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .onReachEnd(() => {
      // Anchoring at the bottom means the user is actively waiting for more:
      // after a page lands, keep loading until they scroll back up. Without
      // this, a user resting at the end of the list could never trigger the
      // next page (no scrollable content below, so no scroll event fires).
      this.cam.cameraGalleryAtBottomEdge = true;
      this.fetchMoreCameraGallery();
    })
      .onScroll((_xOffset: number, _yOffset: number) => {
        this.scheduleNavColorRefresh();
        // onScroll reports the per-frame delta, not the absolute position, so
        // comparing it with a stored watermark effectively disabled the
        // trigger after one fast fling frame. Use the scroller's cumulative
        // offset instead: every ~220px of additional scrolling loads one more
        // page, and onReachEnd stays as the end-of-list backstop.
        const currentOffset = this.cameraGalleryScroller.currentOffset().yOffset;
        if (currentOffset < this.cameraGalleryLastScrollY) {
          // Scrolling back up cancels bottom-anchored auto-loading.
          this.cam.cameraGalleryAtBottomEdge = false;
        }
        this.cameraGalleryLastScrollY = currentOffset;
        if (currentOffset > this.cameraGalleryScrollOffset + 220) {
          this.cameraGalleryScrollOffset = currentOffset;
          this.fetchMoreCameraGallery();
        }
      });
      // Keep the download action in the viewport. It is deliberately outside
      // the Scroll so a long gallery cannot push it below the fold.
      if (this.cam.cameraGalleryItems.length > 0) {
        Row() {
          Button({ type: ButtonType.Circle }) {
            Text('↓')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.vivid_text_ffffff'));
          }
          .width(54)
          .height(54)
          .padding(0)
          .backgroundColor(this.cam.selectedCameraImageIds.length > 0 ? '#202A3B' : '#AAB4C2')
          .shadow({ radius: 12, color: 'rgba(24,35,53,0.26)', offsetY: 5 })
          .enabled(this.cam.selectedCameraImageIds.length > 0)
          .accessibilityText(`下载${this.cam.selectedCameraImageIds.length > 0 ? `（${this.cam.selectedCameraImageIds.length}）` : ''}`)
          .onClick(() => { this.downloadSelectedCameraPhotos(); });
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
        .padding({ right: 4 })
        .hitTestBehavior(HitTestMode.Transparent);
      }
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  StatCard(value: string, label: string, color: string, isLast: boolean) {
    Column() {
      Text(value)
        .fontSize(this.isDesktop() ? 20 : 15)
        .fontWeight(FontWeight.Bold)
        .fontColor(color);
      Text(label).fontSize(10).fontColor($r('app.color.vivid_text_8390a2')).margin({ top: 5 });
    }
    .layoutWeight(1)
    .height(88)
    .justifyContent(FlexAlign.Center)
    .borderRadius(22)
    .attributeModifier(this.cardMaterial())
    .margin({ right: isLast ? 0 : 8 });
  }

  @Builder
  SectionIntro(eyebrow: string, title: string, subtitle: string) {
    Column() {
      Text(eyebrow)
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.mutedTextColor())
        .letterSpacing(1.2)
        .width('100%');
      Text(title)
        .fontSize(this.isDesktop() ? 30 : 25)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pageTextColor())
        .width('100%')
        .margin({ top: 5 });
      Text(subtitle)
        .fontSize(12)
        .fontColor(this.mutedTextColor())
        .width('100%')
        .margin({ top: 7, bottom: 22 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  /** 进入相机页时提示当前支持的相机型号范围（每次启动仅一次）。 */
  private showSupportedCameraHint(): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '支持的相机类型',
        message: '尼康：Z 系列全部\n松下：全画幅全系、ZS300（LUMIX Sync 线，蓝牙配对）\n索尼：微单全系（未测试）',
        autoCancel: true,
        alignment: DialogAlignment.Center,
        buttons: [
          {
            value: '我知道了',
            action: () => {
            },
          },
        ],
      });
    } catch (_error) {
      // 弹窗在窗口重建等时机不可用时静默跳过，不影响进入相机页。
    }
  }

  private async startCameraBleDiscovery(): Promise<void> {
    this.stopCameraBleDiscovery();
    this.cameraBleDiscoveryActive = true;
    this.cameraBleLastSeenAt = 0;
    this.cameraBleStatusTimer = setInterval(() => {
      if (!this.cameraBleDiscoveryActive || this.selectedSection !== 1) return;
      this.refreshCameraCards();
      // SSID 行就地补齐 + 卡片自动收起（已注册/已开始配对）；不改状态行。
      this.syncNewCameraCard();
      if (this.cameraBleLastSeenAt <= 0) return;
      if (Date.now() - this.cameraBleLastSeenAt > 6000 &&
        (this.cam.cameraBleStatus === '已连接' || this.cam.cameraBleStatus === '已发现')) {
        this.cam.cameraBleStatus = '未连接';
        // Keep a Wi-Fi session visible when it is already established; only
        // the BLE indicator is stale in that case.
        if (!this.cameraWifiConnected() && this.cam.cameraState === 2) {
          this.cam.cameraMessage = '相机蓝牙已离开或关闭；请回到附近后再传输';
        }
      }
    }, 500) as number;
    if (this.cameraWifiPresenceTimer !== -1) clearInterval(this.cameraWifiPresenceTimer);
    this.cameraWifiPresenceTimer = setInterval(() => {
      if (!this.cameraBleDiscoveryActive || this.selectedSection !== 1 ||
        this.cameraWifiPresenceInFlight) return;
      this.refreshPanasonicWifiPresence();
      // 2s is the practical floor: each tick drives a full Wi-Fi radio scan
      // that itself takes 2-4s, so a shorter interval only queues
      // back-to-back scans and drains the battery without finding cameras
      // any faster.
    }, 2000) as number;
    this.cameraCards.clearRadioObservations();
    this.syncWifiDetected = false;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.cameraCards.load(context);
      const legacyName = (await LumixImportPrototype.rememberedCameraName(context))
        .replace(/[\u0000-\u001F\u007F]/g, '').trim();
      const legacyImage = this.cameraImageKeyForName(legacyName);
      const legacyBrand = this.brandForImageKey(legacyImage);
      const legacyCandidate: LumixBleCameraCandidate | null = legacyName.length > 0 ? {
        deviceId: '', deviceName: legacyName, model: legacyName, imageKey: legacyImage,
        brand: legacyBrand, rssi: 0, connectable: false,
      } : null;
      await this.cameraCards.migrateLegacy(context, legacyCandidate);
      if (!this.cameraBleDiscoveryActive || this.selectedSection !== 1) return;
      this.refreshCameraCards();
      if (this.cameraBleCandidates.length === 0) this.cam.cameraMessage = '正在监听相机 BLE 并扫描相机 Wi‑Fi…';
      const manager = abilityAccessCtrl.createAtManager();
      let bluetoothPermissionGranted = true;
      try {
        await manager.requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
      } catch (_error) {
        // S5 discovery is Wi‑Fi-only and must keep working when the user has
        // declined the optional BLE permission needed by other bodies.
        bluetoothPermissionGranted = false;
      }
      if (!this.cameraBleDiscoveryActive || this.selectedSection !== 1) return;
      if (bluetoothPermissionGranted) LumixImportPrototype.startCameraDiscovery((candidate: LumixBleCameraCandidate): void => {
        if (!this.cameraBleDiscoveryActive || this.selectedSection !== 1) return;
        // Sync-generation advertisements (original S5 included) back the
        // camera-control entry: a visible BLE address enables the Sync
        // pairing route, while the Wi-Fi presence tile keeps driving the
        // passive image-transfer route.
        const observedAt = Date.now();
        const observedCandidate: LumixBleCameraCandidate = {
          deviceId: candidate.deviceId,
          deviceName: candidate.deviceName,
          model: candidate.model,
          imageKey: candidate.imageKey,
          brand: candidate.brand,
          rssi: candidate.rssi,
          connectable: candidate.connectable,
          // Carries the stable advertised identity into the card registry;
          // dropping it here would re-key every card back to the name.
          btAddress: candidate.btAddress,
          lastSeenAt: observedAt,
        };
        this.cameraCards.observeBle(observedCandidate, observedAt);
        this.refreshCameraCards();
        // 新发现（尚未注册）的相机先给一张「发现新相机」卡片。这一步刻意
        // 放在「选中项是否就是它」的早退之前：卡片就是给还没选中的新相机用的。
        this.maybeShowNewCameraCard(observedCandidate);
        const selected = this.selectedCameraCard();
        if (this.cameraCandidateKey(selected) !== this.cameraCandidateKey(observedCandidate)) return;
        this.cameraBleLastSeenAt = observedAt;
        this.applyCameraCandidate(selected);
        // 不在扫描回调里自动预热 GATT：prewarmGattOnce 的握手包含 36f99090
        // 提交 + ACTION_MODE=01，会让相机立刻退出当前模式并打开 AP——用户
        // 未点任何按钮相机就弹"等待 Wi-Fi 连接"画面（2026-09-19 用户报障）。
        // 连接+注册只在用户点击图片传输后的 run() 流程中完成。
        const remembered = this.cameraCards.isBlePaired(observedCandidate) && observedCandidate.connectable;
        const syncPanasonic = this.cameraBleCandidateBrand === 'Panasonic' &&
          LumixCameraService.panasonicRouteForModel(
            `${this.cam.cameraBleCandidateModel} ${this.cam.cameraBleCandidateName}`, true) === 'sync';
        if (remembered && !syncPanasonic) {
          // A previously registered Lab camera only needs to advertise nearby.
          // Do not invoke pairDevice or show the first-time pairing flow again.
          this.cam.cameraState = 2;
          this.cameraPairingAttempted = true;
            // A scan result proves only that the camera is advertising nearby.
            // Nikon and the original S5 use Wi‑Fi for image transfer and do not
            // open the LUMIX Lab GATT registration link here.
            const directWifiPanasonic = this.cameraBleCandidateBrand === 'Panasonic' &&
              LumixCameraService.isWifiOnlyModel(`${observedCandidate.model} ${observedCandidate.deviceName}`);
            this.cam.cameraBleStatus = this.cameraBleCandidateBrand === 'Nikon' || directWifiPanasonic
              ? '已发现' : '已连接';
            // Re-entering the camera page must not erase an active Wi-Fi
            // session; only initialise the Wi-Fi fields when no session is up.
            if (!this.cameraWifiConnected()) {
              this.cam.cameraWifiStatus = '未连接';
              this.cam.cameraSessionStatus = '未建立';
            }
           this.cam.cameraImageKey = this.cameraBleCandidateImageKey;
           this.cam.cameraModel = observedCandidate.model.length > 0 ? observedCandidate.model : (this.cameraBleCandidateBrand === 'Nikon' ? 'NIKON' : 'LUMIX');
           this.cam.cameraBrand = this.cameraBleCandidateBrand;
            this.cam.cameraMessage = this.cameraBleCandidateBrand === 'Nikon' || directWifiPanasonic
              ? `${observedCandidate.deviceName} 已发现，可点击“图片传输（Wi‑Fi）”自动连接`
              : `${observedCandidate.deviceName} 已配对并在附近，可点击“图片传输（Wi‑Fi）”`;
        } else if (syncPanasonic && observedCandidate.connectable) {
          // Sync-generation bodies never went through Lab GATT registration.
          // Their advertisement is the control-route proximity signal: light
          // the Bluetooth indicator and leave the connect state untouched.
          this.cam.cameraBleStatus = '已发现';
          if (this.cam.cameraState !== 1 && this.cam.cameraState !== 2) this.cam.cameraState = 0;
          this.cam.cameraImageKey = this.cameraBleCandidateImageKey;
          this.cam.cameraModel = observedCandidate.model.length > 0 ? observedCandidate.model : 'LUMIX';
          this.cam.cameraBrand = this.cameraBleCandidateBrand;
          this.cam.cameraMessage = `${observedCandidate.deviceName} 蓝牙已发现，可进入相机控制；图传请连接相机 Wi‑Fi`;
        } else if (this.cam.cameraState !== 1 && this.cam.cameraState !== 2) {
          this.cam.cameraState = 0;
          this.cam.cameraBleStatus = observedCandidate.connectable ? '已发现' : '未连接';
          this.cam.cameraImageKey = this.cameraBleCandidateImageKey;
          this.cam.cameraModel = observedCandidate.model.length > 0 ? observedCandidate.model : (this.cameraBleCandidateBrand === 'Nikon' ? 'NIKON' : 'LUMIX');
          this.cam.cameraBrand = this.cameraBleCandidateBrand;
           const directWifiPanasonic = this.cameraBleCandidateBrand === 'Panasonic' &&
             LumixCameraService.isWifiOnlyModel(`${observedCandidate.model} ${observedCandidate.deviceName}`);
           this.cam.cameraMessage = this.cameraBleCandidateBrand === 'Nikon' || directWifiPanasonic
             ? `${observedCandidate.deviceName} 已发现，确认后自动连接 Wi‑Fi`
              : `${observedCandidate.deviceName} 已发现，可由 Pixelshop 发起配对`;
        } else if (observedCandidate.connectable && this.cam.cameraBleStatus !== '已连接') {
          // A scan advertisement proves proximity, not a GATT link. Keep this
          // distinct from the registered-camera status so a Z5 with Bluetooth
          // disabled cannot remain falsely green while Wi‑Fi is still up.
          this.cam.cameraBleStatus = '已发现';
        }
      });
      if (!bluetoothPermissionGranted) this.cam.cameraMessage = '蓝牙权限未开启，仍继续扫描相机 Wi‑Fi…';
      // Sync-route bodies are discovered by this independent AP scan.
      this.refreshPanasonicWifiPresence();
      // 富士线：与松下扫描**并列**运行。两套扫描各自持一个 BLEDeviceFind
      // 回调、各自过滤广播；富士命中后只入卡，不碰松下的候选与状态字段。
      this.startFujifilmBleDiscovery();
      // 佳能线：同样与松下扫描并列（独立回调 + 独立 Service UUID 过滤）。
      this.startCanonBleDiscovery();
    } catch (_error) {
      this.cameraBleDiscoveryActive = false;
      this.cam.cameraMessage = '蓝牙权限未开启，无法监听相机 BLE';
    }
  }

  /**
   * 富士线扫描（ROUTE_SPEC §3.2）。
   *
   * 与松下扫描的关系：HarmonyOS 同一时刻只允许一轮 BLE 扫描。若松下的扫描已经
   * 在跑，`FujifilmBleService.startScan` 里启动那一轮会被拒，但**已有的扫描结果
   * 仍会送到富士自己的回调**，所以两条线天然并列、互不影响；反过来，富士先起
   * 扫描时松下那条也同样成立（它挂的是无过滤回调）。
   */
  private startFujifilmBleDiscovery(): void {
    const onFound = (camera: FujifilmBleCamera): void => {
      if (!this.cameraBleDiscoveryActive || this.selectedSection !== 1) return;
      const observedAt = Date.now();
      // 广播里的机型在老协议里是「4 字符序列号 + 机型」，RED 是整串；统一归一化。
      const rawModel = camera.model.length > 0 ? camera.model : camera.name;
      const model = FujifilmModels.displayNameOf(rawModel);
      const candidate: LumixBleCameraCandidate = {
        deviceId: camera.deviceId,
        deviceName: camera.name.length > 0 ? camera.name : model,
        model: model,
        imageKey: FujifilmModels.imageKeyOf(model),
        brand: FUJIFILM_BRAND,
        rssi: camera.rssi,
        connectable: true,
        lastSeenAt: observedAt,
      };
      this.fujifilmCamera = camera;
      this.fujifilmModel = model;
      this.cameraCards.observeBle(candidate, observedAt);
      this.refreshCameraCards();
      this.maybeShowNewCameraCard(candidate);
      const selected = this.selectedCameraCard();
      if (this.cameraCandidateKey(selected) !== this.cameraCandidateKey(candidate)) return;
      this.cameraBleLastSeenAt = observedAt;
      this.applyCameraCandidate(selected);
      this.cam.cameraBrand = FUJIFILM_BRAND;
      this.cam.cameraModel = model;
      this.cam.cameraImageKey = candidate.imageKey;
      // 广播只能证明「在附近」，GATT 链路要等用户点入口时才建（01 §9.4：
      // 相机 AP 起来后 BLE 不断开，AP_STATE 才是切 Wi‑Fi 的开关）。
      if (this.cam.cameraBleStatus !== '已连接') this.cam.cameraBleStatus = '已发现';
      if (this.cam.cameraState !== 1 && this.cam.cameraState !== 2) this.cam.cameraState = 0;
      this.cam.cameraMessage = `${camera.name} 已发现，点「图片传输」或「相机控制」拉起相机 Wi‑Fi`;
      AppLogStore.add(`[FUJI] 扫描命中 ${model} serial=${camera.serial} red=${camera.red ? 1 : 0}`);
    };
    FujifilmBleService.startScan(onFound).catch((error: Error): void => {
      AppLogStore.add(`[FUJI] 扫描启动失败: ${error.message}`);
    });
  }

  /**
   * 佳能线扫描（报告 01 §1.2 / §2）。
   *
   * 与松下/富士并列：同一时刻系统只允许一轮 BLE 扫描，但各家服务各自挂
   * `BLEDeviceFind` 回调并按自己的 Service UUID 过滤，因此互不阻塞。
   *
   * 身份用相机广播里的 128-bit UUID（`cameraUuid`），写进候选的 `btAddress`：
   * 佳能的 BLE 地址会轮换（RPA），地址不能当身份，UUID 才是官方口径的稳定 ID。
   */
  private startCanonBleDiscovery(): void {
    const onFound = (camera: CanonBleCamera): void => {
      if (!this.cameraBleDiscoveryActive || this.selectedSection !== 1) return;
      const observedAt = Date.now();
      const identity: CanonIdentity = CanonModels.identityFromPid(camera.pid,
        camera.model.length > 0 ? camera.model : camera.name);
      this.canonCamera = camera;
      this.canonModel = identity.model;
      const candidate: LumixBleCameraCandidate = {
        deviceId: camera.deviceId,
        deviceName: camera.name.length > 0 ? camera.name : identity.model,
        model: identity.model,
        imageKey: identity.imageKey,
        brand: CANON_BRAND,
        rssi: camera.rssi,
        connectable: camera.connectable,
        lastSeenAt: observedAt,
        btAddress: camera.cameraUuid,
      };
      this.cameraCards.observeBle(candidate, observedAt);
      this.refreshCameraCards();
      this.maybeShowNewCameraCard(candidate);
      const selected = this.selectedCameraCard();
      if (this.cameraCandidateKey(selected) !== this.cameraCandidateKey(candidate)) return;
      this.cameraBleLastSeenAt = observedAt;
      this.applyCameraCandidate(selected);
      this.cam.cameraBrand = CANON_BRAND;
      this.cam.cameraModel = identity.model;
      this.cam.cameraImageKey = identity.imageKey;
      // 广播只能证明「在附近」：GATT 连接、注册与 WAP 交接都在用户点入口时
      // 才建立（与富士同一取舍），避免在首页常驻一条 BLE 链路耗电。
      if (this.cam.cameraBleStatus !== '已连接') this.cam.cameraBleStatus = '已发现';
      if (this.cam.cameraState !== 1 && this.cam.cameraState !== 2) this.cam.cameraState = 0;
      this.cam.cameraMessage = `${candidate.deviceName} 已发现，点「图片传输」或「相机控制」建立相机 Wi‑Fi`;
      AppLogStore.add(`[CANON] 扫描命中 ${identity.model} pid=0x${CanonModels.pidHex(camera.pid)} ` +
        `uuid=${camera.cameraUuid.substring(0, 8)}`);
    };
    CanonBleService.startScan(onFound).catch((error: Error): void => {
      AppLogStore.add(`[CANON] 扫描启动失败: ${error.message}`);
    });
  }

  /** 佳能线是否已有可用目标：扫描命中过，或当前卡片是佳能素材。 */
  private canonTargetReady(): boolean {
    return this.canonCamera !== null || CanonModels.isCanonImageKey(this.cam.cameraImageKey);
  }

  /**
   * 由卡片/会话字段还原一台佳能机身（应用重启或扫描停掉后 `canonCamera` 为空）。
   *
   * 代价是拿不到广播里的 `pid`（用机型名反查素材表），但 `deviceId` 仍可重建
   * GATT；已注册过的机身不需要重新写 00010006 的昵称。
   */
  private canonCameraFromCard(): CanonBleCamera | null {
    if (this.canonCamera !== null) return this.canonCamera;
    const deviceId = this.cameraBleCandidateDeviceId;
    if (deviceId.length === 0) return null;
    const model = this.cam.cameraModel.length > 0 ? this.cam.cameraModel
      : this.cam.cameraBleCandidateModel;
    const identity = CanonModels.identityFromName(model);
    return {
      deviceId: deviceId,
      name: this.cam.cameraBleCandidateName.length > 0 ? this.cam.cameraBleCandidateName : model,
      model: identity !== null ? identity.model : model,
      imageKey: identity !== null ? identity.imageKey : this.cam.cameraImageKey,
      pid: identity !== null ? identity.pid : 0,
      cameraUuid: this.cameraBleCandidateBtAddress,
      paired: false,
      powerState: 0,
      connectable: true,
      rssi: 0,
    };
  }

  /**
   * 佳能入口总闸：先按需拉起相机 Wi‑Fi，成功后再进对应页面。
   *
   *  - 图片传输 → WAP 交接 → 关联热点 → `pages/CanonImageTransferPage`
   *  - 相机控制 → 同上 → `pages/CanonCameraControlPage`
   *  - WIFI 连接 → 只做「拉起 + 关联」，留在本页
   *
   * 从不 reject：入口由 onClick 调用，未处理的 rejection 会中止应用。
   */
  private async openCanonEntry(purpose: string): Promise<void> {
    const label = purpose === 'control' ? '相机控制' : (purpose === 'wifi' ? 'WIFI 连接' : '图片传输');
    AppLogStore.add(`[CANON] 打开${label}`);
    if (this.canonWifiRaiseInFlight) {
      this.cam.cameraMessage = '正在建立与相机的 Wi‑Fi 链路，请稍候…';
      return;
    }
    try {
      const ready = await this.ensureCanonWifi(label);
      if (!ready) return;
      if (purpose === 'wifi') {
        this.cam.cameraMessage = '佳能相机 Wi‑Fi 已连接，可继续图片传输或相机控制';
        return;
      }
      this.cam.syncPullActive = false;
      this.registerCameraSessionDriver();
      const url = purpose === 'control'
        ? 'pages/CanonCameraControlPage' : 'pages/CanonImageTransferPage';
      AppStorage.setOrCreate('controlProtocol', 'canon');
      AppStorage.setOrCreate('canonHost', this.cameraHost);
      this.getUIContext().getRouter().pushUrl({ url: url });
      AppLogStore.add(`[CANON] 已进入 ${url}`);
    } catch (error) {
      this.cam.cameraMessage = `佳能相机连接失败：${(error as Error).message}`;
      AppLogStore.add(`[CANON] 入口异常: ${String(error)}`);
    }
  }

  /** 佳能「固件更新」：登记路由直接进页面（版本/清单由固件服务自己取）。 */
  private openCanonFirmware(): void {
    AppLogStore.add('[CANON] 打开固件更新页');
    try {
      AppStorage.setOrCreate('canonHost', this.cameraHost);
      this.getUIContext().getRouter().pushUrl({ url: 'pages/CanonFirmwarePage' });
    } catch (error) {
      AppLogStore.add(`[CANON] 打开固件更新页失败: ${String(error)}`);
    }
  }

  /**
   * 佳能：注册 → WAP 交接 → 关联热点（报告 01 §3/§4、02 §7）。
   *
   *  1. GATT 连接（幂等）+ 首次注册（必要时系统绑定，00010006 写 01+昵称）；
   *  2. 写 00020002 让相机拉起热点（带安全类型 `04 09 00 00 00`）；
   *  3. 读 0001000c/00020004-06 的 SSID/密码，读 00020003 + TLV 拿 IP/BSSID；
   *  4. 用系统候选配置关联热点（复用松下已验证的关联/密码策略）。
   *
   * 密码只在本函数栈上活一次，不写状态、不落库、不进日志。
   */
  private async ensureCanonWifi(label: string): Promise<boolean> {
    if (this.cameraWifiConnected() && this.cam.cameraWifiSsid.length > 0) {
      if (this.cameraHost.length === 0) {
        try {
          this.cameraHost = await LumixCameraService.linkedGateway();
        } catch (_error) {
          this.cameraHost = '';
        }
      }
      AppLogStore.add(`[CANON] 已在相机 Wi‑Fi 上（${label}）`);
      return this.cameraHost.length > 0;
    }
    const camera = this.canonCamera !== null ? this.canonCamera : this.canonCameraFromCard();
    if (camera === null) {
      this.cam.cameraMessage = '没有可用的佳能相机，请回到相机页重新扫描';
      AppLogStore.add('[CANON] 拉起失败：没有扫描命中的机身');
      return false;
    }
    this.canonWifiRaiseInFlight = true;
    this.cam.cameraTransferInProgress = true;
    this.cam.cameraSessionStatus = '蓝牙配网中';
    this.cam.cameraMessage = '正在通过蓝牙拉起相机 Wi‑Fi…';
    try {
      if (!CanonBleService.isConnected()) {
        const linked = await CanonBleService.connect(camera.deviceId);
        if (!linked) {
          this.cam.cameraMessage = '佳能相机蓝牙连接失败，请靠近相机后重试';
          this.cam.cameraSessionStatus = '未建立';
          return false;
        }
      }
      // 首次连接要绑定 + 注册昵称。注册帧只在相机 UUID 非全 0 时才被接受，
      // 全新机身可能永远不回 02：返回 false 只记日志，后续凭据/WAP 照常
      // （BLE 线实测结论，见 CanonBleService.register 注释）。
      const registered = await CanonBleService.register(camera, 'VIVID');
      if (!registered) AppLogStore.add('[CANON] 注册未确认，继续尝试 WAP 交接');
      this.cam.cameraBleStatus = '已连接';
      const capabilities = await CanonBleService.readCapabilities();
      AppLogStore.add(`[CANON] 能力位图=0x${capabilities.toString(16)}`);

      // 凭据有两条来源：AP 尚未拉起时相机也可能已经把 SSID/密码放在
      // 0001000c 的缓存/读特征里；读不到就拉起 AP 后再读。
      let credential: CanonWifiCredential | null = null;
      try {
        credential = await CanonBleService.readWifiCredential(8000);
        AppLogStore.add('[CANON] 已在 WAP 启动前读到凭据');
      } catch (error) {
        AppLogStore.add(`[CANON] 启动前凭据未到：${(error as Error).message}`);
      }

      this.cam.cameraMessage = '相机正在启动热点…';
      // 官方写 `04 09 00 00 00`（带安全类型 9）；相机不支持时服务内部会退回
      // 不带安全类型的 `01`（报告 01 §4.1 + C.java 的前置条件判断）。
      const wap: CanonWapResult = await CanonBleService.startWap(9, CANON_WAP_TIMEOUT_MS);
      if (!wap.ok) {
        AppLogStore.add(`[CANON] WAP 返回 code=${wap.code} sub=${wap.subCode} ${wap.message}`);
      }
      let resolved: CanonWifiCredential | null = credential;
      if (resolved === null || resolved.ssid.length === 0) {
        try {
          resolved = await CanonBleService.readWifiCredential(15000);
        } catch (error) {
          AppLogStore.add(`[CANON] 0001000c 凭据未到，改读 00020004/05: ${(error as Error).message}`);
          try {
            resolved = await CanonBleService.readWapCredentials();
          } catch (inner) {
            AppLogStore.add(`[CANON] 00020004/05 也失败: ${(inner as Error).message}`);
            resolved = null;
          }
        }
      }
      if (resolved === null || resolved.ssid.length === 0) {
        this.cam.cameraMessage = '相机没有给出 SSID，请确认相机 Wi‑Fi 未被关闭后重试';
        return false;
      }
      this.cam.cameraWifiSsid = resolved.ssid;
      return await this.joinCanonWifi(resolved, wap);
    } catch (error) {
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = `佳能相机 Wi‑Fi 拉起失败：${(error as Error).message}`;
      AppLogStore.add(`[CANON] 拉起失败: ${String(error)}`);
      return false;
    } finally {
      this.canonWifiRaiseInFlight = false;
      this.cam.cameraTransferInProgress = false;
    }
  }

  /** 用 BLE 读到的 SSID/密码关联相机热点（与松下共用同一套关联实现）。 */
  private async joinCanonWifi(credential: CanonWifiCredential, wap: CanonWapResult): Promise<boolean> {
    const candidate: LumixWifiCandidate = {
      ssid: credential.ssid,
      bssid: wap.bssid,
      rssi: 0,
      // 佳能相机 AP 是 WPA2‑PSK；HarmonyOS 的 PSK = 3（`01 §4.3`）。
      securityType: 3,
      model: this.cam.cameraModel,
      family: 'EOS',
      imageKey: this.cam.cameraImageKey,
      brand: CANON_BRAND,
    };
    this.cam.cameraMessage = `正在连接相机 Wi‑Fi（${credential.ssid}）…`;
    const result = await LumixCameraService.connectToCameraWifi(candidate, true,
      { password: credential.password });
    if (!result.connected) {
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraMessage = result.message;
      AppLogStore.add(`[CANON] 关联失败: ${result.message}`);
      return false;
    }
    this.cam.cameraWifiSsid = result.ssid.length > 0 ? result.ssid : credential.ssid;
    this.cam.cameraWifiStatus = '已连接';
    this.cam.cameraBleStatus = '已连接';
    this.cam.cameraBrand = CANON_BRAND;
    this.cam.cameraState = 2;
    this.cam.cameraSessionStatus = '未建立';
    this.cameraWifiCloseRequested = false;
    // WAP TLV 的 0x10 是相机在 AP 内的 IP；拿不到时退回默认网关（相机是 DHCP
    // 服务端，网关即相机），最后才用 Canon 文档里的固定地址兜底。
    let host = wap.ip;
    if (host.length === 0) {
      try {
        host = await LumixCameraService.linkedGateway();
      } catch (_error) {
        host = '';
      }
    }
    if (host.length === 0) host = '192.168.1.2';
    this.cameraHost = host;
    AppStorage.setOrCreate('canonHost', host);
    await this.rememberCameraCard(true);
    AppLogStore.add(`[CANON] 相机 Wi‑Fi 已连接 ssid=${this.cam.cameraWifiSsid} host=${host}`);
    return true;
  }

  /** 佳能：关闭相机 Wi‑Fi 会话（停 WAP → 断 BLE → 复位状态）。 */
  private async closeCanonWifi(): Promise<void> {
    if (this.cam.cameraTransferInProgress) return;
    this.cameraWifiCloseRequested = true;
    this.cam.cameraMessage = '正在关闭相机 Wi‑Fi…';
    try {
      await CanonBleService.stopWap();
      await CanonBleService.disconnect();
      this.cameraCards.setConnected(null);
      this.cam.cameraBleStatus = '未连接';
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraState = 0;
      this.cam.cameraMessage = '相机 Wi‑Fi 已关闭，相机热点会自动断开';
      AppLogStore.add('[CANON] 已断开蓝牙链路并复位会话');
    } catch (error) {
      this.cam.cameraMessage = `关闭相机 Wi‑Fi 失败：${(error as Error).message}`;
      AppLogStore.add(`[CANON] 关闭 Wi‑Fi 异常: ${String(error)}`);
    }
  }

  private cameraCandidateKey(candidate: LumixBleCameraCandidate): string {
    return this.cameraCards.key(candidate);
  }

  private cameraCardIsSelected(candidate: LumixBleCameraCandidate): boolean {
    return this.cameraCandidateKey(candidate) === this.cameraCandidateKey(this.selectedCameraCard());
  }

  /** Material radio/name changes refresh the tile; repeated scan timestamps do not. */
  private cameraCardRenderKey(candidate: LumixBleCameraCandidate): string {
    return `${this.cameraCandidateKey(candidate)}:${candidate.deviceName}:${candidate.imageKey}:` +
      `${this.cameraCards.isOnline(candidate)}:${this.cameraCardIsSelected(candidate)}`;
  }

  /** Key lookup avoids a stale ForEach index after online/offline reordering. */
  private selectCameraCardByKey(key: string): void {
    const index = this.cameraBleCandidates.findIndex((candidate: LumixBleCameraCandidate): boolean =>
      this.cameraCandidateKey(candidate) === key);
    this.selectCameraCandidate(index);
  }

  private selectedCameraCard(): LumixBleCameraCandidate {
    return { deviceId: this.cameraBleCandidateDeviceId, deviceName: this.cam.cameraBleCandidateName,
      model: this.cam.cameraBleCandidateModel || this.cam.cameraModel,
      imageKey: this.cameraBleCandidateImageKey || this.cam.cameraImageKey,
      brand: this.cameraBleCandidateBrand, rssi: 0, connectable: this.cameraBleCandidateConnectable,
      btAddress: this.cameraBleCandidateBtAddress };
  }

  private selectedCameraRemembered(): boolean {
    return this.cameraCards.isSaved(this.selectedCameraCard());
  }

  /** Reorder by identity, keeping the visible card and connection target together. */
  private refreshCameraCards(): void {
    const previous = this.selectedCameraCard();
    const previousKey = this.cameraCandidateKey(previous);
    const previousIndex = this.cameraBleSelectedIndex;
    const previousCount = this.cameraBleCandidates.length;
    const next = this.cameraCards.cards();
    let index = next.findIndex((candidate: LumixBleCameraCandidate): boolean =>
      this.cameraCandidateKey(candidate) === previousKey);
    // An in-flight handshake retains its target even if advertising stops.
    if (index < 0 && (this.cam.cameraState === 1 || this.cam.cameraTransferInProgress) &&
      previous.deviceName.length > 0) { next.push(previous); index = next.length - 1; }
    if (index < 0) index = 0;
    this.cameraBleCandidates = next;
    this.cameraBleSelectedIndex = index;
    // align=false：下面的条件对齐负责“重排后索引变了才滚”，不要无条件滚。
    if (next.length > 0) this.selectCameraCandidate(index, false);
    else {
      this.cam.cameraBleCandidateName = '';
      this.cameraBleCandidateDeviceId = '';
      this.cam.cameraBleCandidateModel = '';
      this.cameraBleCandidateImageKey = '';
      this.cameraBleCandidateConnectable = false;
      this.cameraBleCandidateBtAddress = '';
      if (this.cam.cameraState !== 1 && !this.cameraWifiConnected()) {
        this.cam.cameraState = 0;
        this.cam.cameraImageKey = '';
        this.cam.cameraBleStatus = '未连接';
      }
    }
    if (index !== previousIndex || next.length !== previousCount) this.alignSelectedCameraCard();
  }

  private alignSelectedCameraCard(): void {
    if (this.cameraCarouselAlignTimer !== -1) clearTimeout(this.cameraCarouselAlignTimer);
    this.cameraCarouselRealigning = true;
    this.cameraCarouselAlignTimer = setTimeout((): void => {
      try {
        this.cameraCarouselOffset = this.cameraBleSelectedIndex * this.cameraCarouselPageWidth;
        this.cameraCarouselScroller.scrollTo({ xOffset: this.cameraCarouselOffset, yOffset: 0, animation: false });
      } catch (_error) { }
      this.cameraCarouselAlignTimer = setTimeout((): void => {
        this.cameraCarouselRealigning = false;
        this.cameraCarouselAlignTimer = -1;
      }, 100) as number;
    }, 0) as number;
  }

  /** Called only after a successful association/registration, never from scanning. */
  private async rememberCameraCard(blePaired: boolean = false, wifi: LumixWifiCandidate | null = null): Promise<void> {
    const selected = this.selectedCameraCard();
    let candidate = selected;
    if (wifi && !this.cameraWifiMatchesSelectedIdentity(wifi)) {
      candidate = { deviceId: '', deviceName: wifi.ssid, model: wifi.model, imageKey: wifi.imageKey,
        brand: wifi.brand || this.brandForImageKey(wifi.imageKey), rssi: wifi.rssi, connectable: false };
    }
    if (candidate.deviceName.length === 0) return;
    const ssid = wifi ? wifi.ssid : (this.cameraWifiConnected() ? this.cam.cameraWifiSsid : '');
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.cameraCards.remember(context, candidate, ssid, blePaired);
      if (this.cameraWifiConnected()) {
        candidate.wifiSsid = ssid;
        this.cameraCards.setConnected(candidate);
      }
      this.applyCameraCandidate(candidate);
      this.refreshCameraCards();
    } catch (_error) {
      this.showMessage('连接成功，但相机记录保存失败，请稍后重试');
    }
  }

  private applyCameraCandidate(candidate: LumixBleCameraCandidate): void {
    this.cam.cameraBleCandidateName = candidate.deviceName;
    this.cameraBleCandidateDeviceId = candidate.deviceId;
    this.cam.cameraBleCandidateModel = candidate.model;
    this.cameraBleCandidateBrand = candidate.brand || this.brandForImageKey(candidate.imageKey);
    this.cameraBleCandidateImageKey = candidate.imageKey.length > 0
      ? candidate.imageKey
      : this.cameraImageKeyForName(`${candidate.model} ${candidate.deviceName}`);
    this.cameraBleCandidateConnectable = candidate.connectable;
    this.cameraBleCandidateBtAddress = candidate.btAddress || '';
  }

  /**
   * 选中某张相机卡片。
   *
   * align=true（默认）会把横向轮播滚到这张卡片上。程序化选中必须带走视图：
   * 「发现新相机」卡片点「选择此相机」后，若只改索引不滚动，就会出现
   * 「程序里已经选中新相机、卡片行却仍停在旧相机」的错位。
   *
   * 两类调用方要显式传 false：
   * - 手指滑动结束的 onScrollStop：轮播本来就停在目标页，再滚会打断吸附；
   * - refreshCameraCards：它自己按「索引/数量是否变化」决定要不要对齐，
   *   统一在这里对齐会把那段条件判断架空。
   */
  private selectCameraCandidate(index: number, align: boolean = true): void {
    if (index < 0 || index >= this.cameraBleCandidates.length) return;
    const candidate = this.cameraBleCandidates[index];
    const same = this.cameraCandidateKey(candidate) === this.cameraCandidateKey({
      deviceId: this.cameraBleCandidateDeviceId,
      deviceName: this.cam.cameraBleCandidateName,
      model: this.cam.cameraBleCandidateModel,
      imageKey: this.cameraBleCandidateImageKey,
      brand: this.cameraBleCandidateBrand,
      rssi: 0,
      connectable: true,
      btAddress: this.cameraBleCandidateBtAddress,
    });
    if (!same && (this.cam.cameraState === 1 || this.cam.cameraTransferInProgress || this.wifiConnecting)) return;
    this.cameraBleSelectedIndex = index;
    this.applyCameraCandidate(candidate);
    const bleFresh = candidate.bleLastSeenAt !== undefined && Date.now() - candidate.bleLastSeenAt <= 6000;
    this.cameraBleLastSeenAt = candidate.bleLastSeenAt || 0;
    this.cam.cameraBleStatus = bleFresh
      ? (this.cameraCards.isBlePaired(candidate) && !this.isPtpIpCamera() && !this.camCgiRouteSelected() ? '已连接' : '已发现')
      : '未连接';
    if (this.cam.cameraState === 2 && !same) {
      // Selecting another nearby body changes the pending target. Require a
      // fresh confirmation while keeping the registered identity in storage.
      this.cam.cameraState = 0;
      this.cameraPairingAttempted = false;
      this.cam.cameraBleStatus = '未连接';
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = `${candidate.deviceName} 已选择`;
    }
    this.cam.cameraBrand = this.cameraBleCandidateBrand;
    this.cam.cameraImageKey = this.cameraBleCandidateImageKey;
    this.cam.cameraModel = candidate.model.length > 0 ? candidate.model :
      (this.cam.cameraBrand === 'Nikon' ? 'NIKON' : (this.cam.cameraBrand === 'Sony' ? 'SONY' : 'LUMIX'));
    this.syncWifiDetected = this.camCgiRouteSelected() &&
      ((candidate.wifiLastSeenAt !== undefined && Date.now() - candidate.wifiLastSeenAt <= 12000) || this.cameraWifiConnected());
    if (this.cam.cameraState !== 1 && !this.cam.cameraTransferInProgress && !this.cameraWifiConnected()) {
      this.cam.cameraState = this.cameraCards.isSaved(candidate) ? 2 : 0;
      this.cameraPairingAttempted = this.cameraCards.isSaved(candidate);
    }
    // Resetting an old selection must not overwrite the new body's live BLE evidence.
    this.cam.cameraBleStatus = bleFresh
      ? (this.cameraCards.isBlePaired(candidate) && !this.isPtpIpCamera() && !this.camCgiRouteSelected() ? '已连接' : '已发现')
      : '未连接';
    if (align) this.alignSelectedCameraCard();
  }

  /**
   * 「发现新相机」卡片（全品牌共用）：蓝牙扫描发现一台「还没注册」的相机时弹一次。
   *
   * 触发纪律：
   * - 已在 CameraCardRegistry 里注册过的相机不再提示；
   * - 本次启动每台相机只提示一次（newCameraCardSeenKeys）。扫描回调每次收到
   *   广播都会进来（索尼等机型按扫描间隔反复上报），没有这层去重就会连弹；
   * - 同一时刻只留一张卡片；配对/图传进行中不弹（已弹出的由 syncNewCameraCard 收起）。
   *
   * 只读扫描结果，不改状态行、不动任何品牌的既有流程。
   */
  private maybeShowNewCameraCard(candidate: LumixBleCameraCandidate): void {
    if (!this.cameraBleDiscoveryActive || this.selectedSection !== 1) return;
    if (this.newCameraCardKey.length > 0) return;
    if (this.cam.cameraState === 1 || this.cam.cameraTransferInProgress) return;
    if (candidate.deviceName.length === 0) return;
    if (this.cameraCards.isSaved(candidate)) return;
    const key = this.cameraCandidateKey(candidate);
    if (this.newCameraCardSeenKeys.indexOf(key) >= 0) return;
    this.newCameraCardSeenKeys.push(key);
    const brand = candidate.brand !== undefined ? candidate.brand : '';
    this.newCameraCardKey = key;
    this.newCameraCardName = candidate.deviceName;
    this.newCameraCardModel = candidate.model;
    this.newCameraCardBrand = brand.length > 0 ? brand : this.brandForImageKey(candidate.imageKey);
    // 复用既有 imageKey 机制：广播里的 key 优先，其次按型号/名字反查；只有当
    // 卡片就是当前选中项时才退回 cameraDisplayImageKey()。
    let imageKey = candidate.imageKey.length > 0 ? candidate.imageKey : '';
    if (imageKey.length === 0) imageKey = this.cameraImageKeyForName(`${candidate.model} ${candidate.deviceName}`);
    if (imageKey.length === 0 && this.cameraCardIsSelected(candidate)) imageKey = this.cameraDisplayImageKey();
    this.newCameraCardImageKey = imageKey;
    this.newCameraCardDeviceId = candidate.deviceId;
    this.newCameraCardBtAddress = candidate.btAddress !== undefined ? candidate.btAddress : '';
    this.newCameraCardConnectable = candidate.connectable;
    // 纯 BLE 发现阶段真实 SSID 通常还不知道（索尼的 SSID 在 CC06 里，要连上
    // 才读得到），先用 BLE 广播名占位，这一行永远占同一个槽位。
    this.newCameraCardSsid = this.knownCameraSsid(candidate, candidate.deviceName);
    AppLogStore.add(`ui 发现新相机 ${this.newCameraCardBrand} ${candidate.deviceName}，卡片等待用户确认`);
  }

  /** 卡片当前代表的相机：从 @State 快照还原，避免扫描回调改写字段后错位。 */
  private newCameraCardCandidate(): LumixBleCameraCandidate {
    return {
      deviceId: this.newCameraCardDeviceId,
      deviceName: this.newCameraCardName,
      model: this.newCameraCardModel,
      imageKey: this.newCameraCardImageKey,
      brand: this.newCameraCardBrand,
      rssi: 0,
      connectable: this.newCameraCardConnectable,
      btAddress: this.newCameraCardBtAddress,
    };
  }

  /**
   * 已知的真实 SSID（上一次会话的连接记录 / 当前会话）；没有就返回占位值。
   *
   * Registry 记录本身只存身份，SSID 来自「Wi‑Fi 扫描到的相机热点」与这张卡片
   * 合并后的 wifiSsid（CameraCardRegistry.cards() 会把两者并到同一个 key），
   * 所以这里查的是合并后的相机列表，而不是注册表本身。
   */
  private knownCameraSsid(candidate: LumixBleCameraCandidate, fallback: string): string {
    const key = this.cameraCandidateKey(candidate);
    for (const card of this.cameraBleCandidates) {
      if (this.cameraCandidateKey(card) !== key) continue;
      if (card.wifiSsid !== undefined && card.wifiSsid.length > 0) return card.wifiSsid;
    }
    if (this.cameraWifiConnected() && this.cam.cameraWifiSsid.length > 0 &&
      this.cameraCandidateKey(this.selectedCameraCard()) === key) return this.cam.cameraWifiSsid;
    return fallback;
  }

  /**
   * 500ms 扫描定时器钩子：补齐真实 SSID，并在卡片已经不需要时收起。
   *
   * 真实 SSID 一旦已知（配对/关联完成、Wi‑Fi 扫描合并进来）就替换占位名——
   * 同一个 Text 槽位，布局不跳。已注册/已开始配对的相机不再需要这张卡片。
   */
  private syncNewCameraCard(): void {
    if (this.newCameraCardKey.length === 0) return;
    // 配对/图传已经开始：卡片带遮罩，必须让位给下面的页面。
    if (this.cam.cameraState === 1 || this.cam.cameraTransferInProgress) {
      this.dismissNewCameraCard();
      return;
    }
    const candidate = this.newCameraCardCandidate();
    // 相机已经注册（例如索尼「确认连接」配对成功后就地注册）后，卡片过期。
    if (this.cameraCards.isSaved(candidate)) {
      this.dismissNewCameraCard();
      return;
    }
    const resolved = this.knownCameraSsid(candidate, '');
    if (resolved.length > 0 && resolved !== this.newCameraCardSsid) {
      this.newCameraCardSsid = resolved;
      AppLogStore.add(`ui 发现新相机卡片 SSID 就地更新为 ${resolved}`);
    }
  }

  private dismissNewCameraCard(): void {
    this.newCameraCardKey = '';
    this.newCameraCardName = '';
    this.newCameraCardSsid = '';
    this.newCameraCardModel = '';
    this.newCameraCardImageKey = '';
    this.newCameraCardDeviceId = '';
    this.newCameraCardBtAddress = '';
    this.newCameraCardConnectable = true;
  }

  /**
   * 卡片底部「选择此相机」：与在相机列表里选中它同效——应用候选身份 + 设为当前
   * 卡片，然后收起卡片。
   *
   * 这里刻意不写 CameraCardRegistry：此刻还没有发生任何蓝牙注册/配网，把它记成
   * 「已保存」会让 selectCameraCandidate() 把 cameraState 推到 2、按钮变成
   * 「已注册」，从而跳过尼康等品牌首次配对的引导弹窗（那条引导是尼康蓝牙配网
   * 的唯一入口），等于改了其他品牌的既有行为。落盘交给各品牌真正的注册路径：
   * 松下/尼康/Sync 连接成功时的 rememberCameraCard()，以及索尼「确认连接」配对
   * 成功后的 rememberSonyCameraAfterPairing()。
   */
  private async confirmNewCameraCard(): Promise<void> {
    if (this.newCameraCardKey.length === 0) return;
    const candidate = this.newCameraCardCandidate();
    const key = this.newCameraCardKey;
    AppLogStore.add(`ui 发现新相机卡片：选择 ${this.newCameraCardBrand} ${candidate.deviceName}`);
    this.applyCameraCandidate(candidate);
    this.cam.cameraBrand = this.newCameraCardBrand;
    if (candidate.imageKey.length > 0) this.cam.cameraImageKey = candidate.imageKey;
    if (candidate.model.length > 0) this.cam.cameraModel = candidate.model;
    const index = this.cameraBleCandidates.findIndex((item: LumixBleCameraCandidate): boolean =>
      this.cameraCandidateKey(item) === key);
    this.dismissNewCameraCard();
    if (index >= 0) {
      this.selectCameraCandidate(index);
    } else {
      // 广播已经过期、卡片不在当前列表里：至少按新身份重排一次列表。
      this.refreshCameraCards();
    }
    this.showMessage(`${candidate.deviceName} 已选择，点击「确认连接」继续`);
  }

  private stopCameraBleDiscovery(): void {
    this.cameraBleDiscoveryActive = false;
    if (this.cameraBleStatusTimer !== -1) {
      clearInterval(this.cameraBleStatusTimer);
      this.cameraBleStatusTimer = -1;
    }
    if (this.cameraWifiPresenceTimer !== -1) {
      clearInterval(this.cameraWifiPresenceTimer);
      this.cameraWifiPresenceTimer = -1;
    }
    LumixImportPrototype.stopCameraDiscovery();
    // 富士只摘掉自己的回调；扫描轮次若不是它启动的，stopScan 不会去停（§扫描注释）。
    FujifilmBleService.stopScan();
    // 佳能同样只摘自己的回调，不动已经在跑的那一轮扫描。
    CanonBleService.stopScan();
    this.fujifilmWifiRaiseInFlight = false;
    this.canonWifiRaiseInFlight = false;
  }

  /** A complete successful scan replaces observations, never saved cards. */
  private mergeWifiCameraCandidates(candidates: LumixWifiCandidate[]): void {
    this.cameraCards.replaceWifi(candidates);
    this.refreshCameraCards();
  }

  private async refreshPanasonicWifiPresence(): Promise<void> {
    if (!this.cameraBleDiscoveryActive || this.selectedSection !== 1 ||
      this.cameraWifiPresenceInFlight) return;
    this.cameraWifiPresenceInFlight = true;
    try {
      const candidates = await LumixCameraService.scanForCameras();
      if (!this.cameraBleDiscoveryActive || this.selectedSection !== 1) return;
      const linkedSsid = await LumixCameraService.linkedSsid();
      const identity = LumixCameraService.identifyWifiSsid(linkedSsid) ||
        NikonCameraService.identifyWifiSsid(linkedSsid) || SonyCameraService.identifyWifiSsid(linkedSsid);
      if (identity && candidates.every((candidate: LumixWifiCandidate): boolean => candidate.ssid !== linkedSsid)) {
        candidates.push({ ssid: linkedSsid, bssid: '', rssi: 0, securityType: 0,
          model: identity.model, family: identity.family, imageKey: identity.imageKey,
          brand: this.brandForImageKey(identity.imageKey) });
      }
      this.mergeWifiCameraCandidates(candidates);
      this.wifiCandidates = candidates;
    } catch (_error) {
      // Failed scans expire naturally; they never remove successful connection history.
    } finally { this.cameraWifiPresenceInFlight = false; }
  }

  private cameraDisplayImageKey(): string {
    // Once a connection has been established, the persisted identity of that
    // camera wins over a later nearby advertisement or a downloaded thumbnail.
    if (this.cam.cameraState === 2 && this.cam.cameraImageKey.length > 0) return this.cam.cameraImageKey;
    if (this.cameraBleCandidateImageKey.length > 0) return this.cameraBleCandidateImageKey;
    if (this.cam.cameraImageKey.length > 0) return this.cam.cameraImageKey;
    // Some API 26 advertisements expose only the remote name. Derive the
    // local asset from that name as a final fallback so a connected S1RM2
    // never regresses to the generic line-art camera.
    const advertised = this.cameraImageKeyForName(this.cam.cameraBleCandidateName);
    if (advertised.length > 0) return advertised;
    return this.cameraImageKeyForName(this.cam.cameraModel);
  }

  /** Dispatch model-to-asset lookup by brand without changing Panasonic's
   * existing registry. */
  private cameraImageKeyForName(name: string): string {
    const nikon = NikonCameraService.imageKeyForModel(name);
    if (nikon.length > 0) return nikon;
    const sony = SonyCameraService.imageKeyForModel(name);
    if (sony.length > 0) return sony;
    // 佳能：素材表 95 款机身（`canon_<slug>`），未收录返回空串，交给后面兜底。
    const canon = CanonModels.identityFromName(name);
    if (canon !== null) return canon.imageKey;
    // 富士：素材表 85 款机身，统一 `fujifilm_<slug>`；未收录返回空串，
    // 交给松下那条兜底（它同样只返回已收录机型）。
    const fujifilm = FujifilmModels.find(name);
    if (fujifilm !== null) return FujifilmModels.imageKeyOf(name);
    return LumixCameraService.imageKeyForModel(name);
  }

  /** Resolve the owning brand from a persisted image key. */
  private brandForImageKey(imageKey: string): string {
    if (CanonModels.isCanonImageKey(imageKey)) return CANON_BRAND;
    if (FujifilmModels.isFujifilmImageKey(imageKey)) return FUJIFILM_BRAND;
    if (NikonCameraService.isNikonImageKey(imageKey)) return 'Nikon';
    if (SonyCameraService.isSonyImageKey(imageKey)) return 'Sony';
    return 'Panasonic';
  }

  /** True when the selected body speaks standard PTP/IP (Nikon and Sony). */
  private isPtpIpCamera(): boolean {
    return this.cam.cameraBrand === 'Nikon' || this.cam.cameraBrand === 'Sony';
  }

  private cameraWifiConnected(): boolean {
    // Session establishment alone is not proof that the phone is still on the
    // camera AP. The connection-change listener clears this state when the
    // linked SSID disappears, so buttons remain disabled immediately.
    return this.cam.cameraWifiStatus === '已连接';
  }

  /** Whether the selected target exposes a currently usable BLE/Wi-Fi path. */
  private cameraConnectionAvailable(): boolean {
    // Sync-generation transfer is Wi-Fi-gated: BLE proximity alone never
    // lights 确认连接 (it lights 相机控制 instead).
    if (this.camCgiRouteSelected()) return this.syncWifiDetected || this.cameraWifiConnected();
    const selected = this.cameraBleCandidates[this.cameraBleSelectedIndex];
    if (selected && selected.wifiLastSeenAt !== undefined && Date.now() - selected.wifiLastSeenAt <= 12000 && this.isPtpIpCamera()) return true;
    if (this.cameraTransport === 1) return true;
    if (this.cameraWifiConnected()) return true;
    if (this.cam.cameraBleStatus === '已连接') return true;
    if (this.cam.cameraBleStatus === '已发现' && this.cameraBleLastSeenAt > 0 &&
      Date.now() - this.cameraBleLastSeenAt <= 6000) return true;
    if (this.cameraBleCandidateConnectable && this.cam.cameraBleCandidateName.length > 0 &&
      this.cameraBleLastSeenAt > 0 && Date.now() - this.cameraBleLastSeenAt <= 6000) return true;
    // Wi‑Fi scan results are intentionally not used here: they have no live
    // presence timestamp and can outlive the camera AP. A linked camera Wi‑Fi
    // is represented by cameraWifiConnected() above.
    return false;
  }

  /** True only for the original S5 push-transfer route. */
  private isOriginalS5Selected(): boolean {
    return this.cam.isOriginalS5Selected();
  }

  /**
   * BLE discovery is a proximity signal. It is deliberately kept separate
   * from a live GATT link: Nikon Z5 uses BLE for discovery/remote control and
   * its photo transfer is PTP/IP over the camera Wi‑Fi. A fresh Nikon
   * advertisement therefore enables the transfer action without falsely
   * painting the Bluetooth indicator green as if a GATT connection existed.
   */
  private cameraBleTransferReady(): boolean {
    // Sync-generation bodies gate the transfer leg on Wi-Fi presence; BLE
    // proximity belongs to the control route only.
    if (this.camCgiRouteSelected()) return false;
    if (this.cam.cameraBleStatus === '已连接') return true;
    const directWifiPanasonic = this.cam.cameraBrand === 'Panasonic' &&
      LumixCameraService.isWifiOnlyModel(`${this.cam.cameraModel} ${this.cam.cameraBleCandidateModel}`);
    if (!this.isPtpIpCamera() && !directWifiPanasonic) return false;
    // A healthy Nikon/Sony Wi‑Fi/PTP session is sufficient for transfer on
    // its own: the BLE six-second proximity window is only a discovery hint
    // and must not disable the action while the camera AP link and the
    // session are alive.
    if (this.isPtpIpCamera() && this.cameraWifiConnected() &&
      this.cam.cameraSessionStatus === '已建立') return true;
    if (this.cam.cameraBleStatus !== '已发现') return false;
    return this.cameraBleLastSeenAt > 0 && Date.now() - this.cameraBleLastSeenAt <= 6000;
  }

  /** 扫描是否正在运行（相机页在前台时由 startCameraBleDiscovery 打开）。 */
  private cameraDiscoveryRunning(): boolean {
    return this.cameraBleDiscoveryActive && this.selectedSection === 1;
  }

  /**
   * 相机是否在线——以扫描状态为准（用户 2026-10-15 需求）。
   *
   * 判据顺序：
   * 1. 已经连上相机 Wi‑Fi / 蓝牙链路 → 在线；
   * 2. 采信扫描自己的结论：蓝牙状态为「已发现 / 已连接」→ 在线。这一条不看
   *    时间戳，扫描说在附近就算在线；
   * 3. 其余情况退回注册表的发现记录（扫描没跑时的兜底），避免把「还没开始扫」
   *    显示成离线。
   */
  private cameraIsReachable(): boolean {
    if (this.cameraWifiConnected()) return true;
    if (this.cam.cameraBleStatus === '已发现' || this.cam.cameraBleStatus === '已连接') return true;
    // 已注册的 GATT 会话是一条活链路，比 cameraBleStatus 这个标签更权威。
    // 固件更新流程**刻意**在结束时仍持有它（版本就是这么读出来的），而 BLE-only
    // 注册失败、或注册被跳过时这个标签不会刷新，于是 cameraOfflineLocked() 会
    // 把图片传输 / LUT / 相机控制 / Wi-Fi / 固件更新五个入口一起置灰，用户再
    // 也点不动。持有链路即视为在线。
    if (LumixImportPrototype.hasRegisteredBleSession()) return true;
    // 尼康/索尼线：配对记录本身就是「可达」的依据。这两条线的相机一旦配对成功
    // 就会停止广播（实测：释放 GATT 后扫描到 1657／3846 个设备，相机一个都没有），
    // 所以「没出现在扫描结果里」并不等于离线。少了这一条，配对成功后 6 秒，
    // 上面的保活定时器会把 cameraBleStatus 降级为未连接，cameraOfflineLocked()
    // 随即把图片传输、相机控制全部置灰，用户只剩「删除连接」可点——而相机其实
    // 好好地在待机，正等着被拉起 Wi‑Fi。
    if (this.isPtpIpCamera() && this.cameraCards.isBlePaired(this.selectedCameraCard())) return true;
    const selected = this.cameraBleCandidates[this.cameraBleSelectedIndex];
    return selected !== undefined && this.cameraCards.isOnline(selected);
  }

  /** History keeps the card, while a fresh advertisement enables Lab transfer. */
  private cameraRegisteredTransferAvailable(): boolean {
    // Sync-generation bodies are never Lab-registered.
    if (this.camCgiRouteSelected()) return false;
    if (this.cam.cameraBrand !== 'Panasonic') return false;
    if (this.cameraWifiOnlyReady || this.cameraWifiConnected()) return false;
    return this.cam.cameraState === 2 && this.cam.cameraBleCandidateName.length > 0 &&
      this.cameraBleTransferReady() && !this.cam.cameraTransferInProgress;
  }

  /** Combined enable state of the Wi-Fi transfer action button. */
  private cameraBleTransferActionReady(): boolean {
    return this.cameraRegisteredTransferAvailable() ||
      (this.cam.cameraState === 2 && this.cameraBleTransferReady() && !this.cam.cameraTransferInProgress);
  }

  /** Enable state of the primary camera action button. In the registered
   * state the action is a local delete and must not require the camera to
   * be nearby; otherwise fall back to the proximity-gated availability. */
  private primaryCameraActionAvailable(): boolean {
    if (this.cam.cameraState === 1 || this.cam.cameraTransferInProgress) return false;
    if (this.cameraTransport === 0 && (this.selectedCameraRemembered() || this.cam.cameraState === 2)) return true;
    return this.cameraConnectionAvailable();
  }

  private cameraConnectionLabel(): string {
    if (this.cameraWifiConnected() || this.cam.cameraBleStatus === '已连接') return '已连接';
    if (this.cam.cameraState === 2 && this.cam.cameraBleStatus === '已发现') return '已发现';
    if (this.cam.cameraState === 2) return this.cameraCards.isBlePaired(this.selectedCameraCard()) ? '已注册' : '已保存';
    return 'CAMERA';
  }

  /**
   * 相机离线锁定：已保存 / 已注册的相机当前不可达时，除「删除连接」以外的
   * 所有相机操作一律置灰不可点——离线状态下点它们只会超时或报错。LUMIX Sync
   * 线与 LUMIX Lab 线共用本判断，在线与否以扫描状态为准。
   *
   * 三个例外，都是刻意的：
   * · USB 线（cameraTransport !== 0）完全不参与本判断——USB 侧按钮逻辑保持原样；
   * · 只有「已保存或已注册」的相机才上锁：全新配对没有保存记录，本来就要靠
   *   主按钮建立第一条记录，不能被挡；
   * · 扫描没在跑时不上锁（见 cameraDiscoveryRunning）：只有扫描确实跑过、
   *   而且这一轮没看到这台相机，才判定为离线，避免"还没扫到"被当成离线。
   */
  private cameraOfflineLocked(): boolean {
    if (this.cameraTransport !== 0) return false;
    if (this.cam.cameraState === 1 || this.cam.cameraTransferInProgress) return false;
    if (!(this.selectedCameraRemembered() || this.cam.cameraState === 2)) return false;
    if (this.cameraIsReachable()) return false;
    return this.cameraDiscoveryRunning();
  }

  /** 主操作此刻是否是「删除连接」：离线时唯一保留可点的操作。 */
  private primaryActionDeletesConnection(): boolean {
    return this.cameraTransport === 0 && this.cam.cameraState === 2;
  }

  /** 主操作按钮可用态：离线时只有「删除连接」还亮着。 */
  private primaryCameraActionEnabled(): boolean {
    if (!this.primaryCameraActionAvailable()) return false;
    return !this.cameraOfflineLocked() || this.primaryActionDeletesConnection();
  }

  /** 「连接 Wi-Fi」按钮：离线时置灰。 */
  private connectWifiActionEnabled(): boolean {
    return this.cameraConnectionAvailable() && !this.cam.cameraTransferInProgress &&
      !this.cameraOfflineLocked();
  }

  /** 「图片传输」按钮：原本无条件可点，离线时置灰。 */
  private imageTransferActionEnabled(): boolean {
    return !this.cameraOfflineLocked();
  }

  /** 「LUT 传输」按钮（Lab 线专属）：离线时置灰。 */
  private lutTransferActionEnabled(): boolean {
    return this.lutControlActionReady() && !this.cameraOfflineLocked();
  }

  /** 「相机控制」按钮：cam.cgi（Sync）与 Lab 两条线都要挡住离线相机。 */
  private cameraControlActionEnabled(): boolean {
    return this.cameraControlActionReady() && !this.cameraOfflineLocked();
  }

  /** 「尼康控制」按钮：离线时置灰。 */
  private nikonControlActionEnabled(): boolean {
    return this.nikonControlActionReady() && !this.cameraOfflineLocked();
  }

  /** 「索尼控制」按钮：离线时置灰。 */
  private sonyControlActionEnabled(): boolean {
    return this.sonyControlActionReady() && !this.cameraOfflineLocked();
  }

  /** 「固件更新」按钮：离线时置灰（固件清单要从官网取，相机不可达时无意义）。 */
  private firmwareUpdateActionEnabled(): boolean {
    return this.firmwareUpdateActionReady() && !this.cameraOfflineLocked();
  }

  /** Wi‑Fi 会话按钮可用态：原有的会话条件叠加离线锁。 */
  private wifiSessionActionEnabled(): boolean {
    if (this.cam.cameraTransferInProgress) return false;
    if (this.cameraOfflineLocked()) return false;
    // 富士线：有目标机身就能拉起（BLE 广播只是近距离证据，GATT 在点击时才建）。
    if (this.cam.cameraBrand === FUJIFILM_BRAND) {
      return this.cameraWifiConnected() || this.fujifilmTargetReady();
    }
    // 佳能线同理：卡片即目标，GATT/注册/WAP 都在点击时按需建立。
    if (this.cam.cameraBrand === CANON_BRAND) {
      return this.cameraWifiConnected() || this.canonTargetReady();
    }
    if (this.camCgiRouteSelected()) return this.cameraWifiConnected();
    return this.cameraWifiConnected() || this.cameraBleTransferActionReady();
  }

  /** Wi‑Fi 会话按钮的置灰态：原条件命中，或已被离线锁 / 其他条件禁用。 */
  private wifiSessionActionMuted(): boolean {
    if (this.cam.cameraBrand === FUJIFILM_BRAND || this.cam.cameraBrand === CANON_BRAND) {
      return this.cam.cameraTransferInProgress || !this.wifiSessionActionEnabled();
    }
    return this.cam.cameraTransferInProgress ||
      (this.camCgiRouteSelected() && !this.cameraWifiConnected()) ||
      !this.wifiSessionActionEnabled();
  }

  /**
   * 富士：关闭相机 Wi‑Fi 会话。
   *
   * 与松下不同，富士没有可写的「关热点」命令：相机的 SoftAP 由功能模式决定，
   * 释放 GATT 链路后相机会自己收摊（`01 §9.4`：AP 起来后 BLE 不断开，断开即
   * 表示控制端离开）。第三方 App 调不到 `wifiManager.disconnect()`，所以这里
   * 只断 BLE 并复位本页状态。
   */
  private async closeFujifilmWifi(): Promise<void> {
    if (this.cam.cameraTransferInProgress) return;
    this.cameraWifiCloseRequested = true;
    this.cam.cameraMessage = '正在关闭相机 Wi‑Fi…';
    try {
      await FujifilmBleService.disconnect();
      this.cameraCards.setConnected(null);
      this.cam.cameraBleStatus = '未连接';
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraState = 0;
      this.cam.cameraMessage = '相机 Wi‑Fi 已关闭，相机热点会自动断开';
      AppLogStore.add('[FUJI] 已断开蓝牙链路并复位会话');
    } catch (error) {
      this.cam.cameraMessage = `关闭相机 Wi‑Fi 失败：${(error as Error).message}`;
      AppLogStore.add(`[FUJI] 关闭 Wi‑Fi 异常: ${String(error)}`);
    }
  }

  private async closeCameraWifiTransfer(): Promise<void> {
    if (this.cam.cameraTransferInProgress) return;
    // The user explicitly closed the transfer; a later system re-association
    // with the camera AP must not silently restart the gallery session.
    this.cameraWifiCloseRequested = true;
    this.cam.cameraMessage = '正在关闭相机 Wi‑Fi…';
    try {
      await this.teardownActiveCameraWifiSession();
      this.cameraCards.setConnected(null);
      // wifiManager.disconnect() is not callable by a third-party app, so the
      // only effective way to drop the camera AP is closing the retained GATT
      // link: the Panasonic body interprets it as the controlling app leaving
      // Wi-Fi mode, shuts its hotspot down, and the phone leaves the network
      // on its own shortly after.
      await LumixImportPrototype.closeActiveGatt();
      this.cam.cameraBleStatus = '未连接';
      this.cam.cameraMessage = '相机 Wi‑Fi 已关闭，相机热点将自动断开';
    } catch (_error) {
      this.cam.cameraMessage = '关闭相机 Wi‑Fi 失败，请稍后重试';
    }
  }

  /**
   * Sync-line disconnect. The GATT link was already released at pair time,
   * so unlike the Lab line there is no retained link whose closure would
   * tell the camera to shut its hotspot down. Clear the accctrl session and
   * let the camera's own polling-idle timeout (~2 min) close the SoftAP;
   * the phone then re-associates with its usual network on its own. The
   * saved candidate config is deliberately KEPT: removing it (2026-09-27
   * 19:51) never disconnects the live link but leaves the phone unable to
   * auto-rejoin when the camera recycles its SoftAP, which stranded the
   * next pairing on a dead gateway.
   */
  private async closeSyncCameraWifi(): Promise<void> {
    if (this.cam.cameraTransferInProgress) return;
    this.cameraWifiCloseRequested = true;
    this.cam.cameraMessage = '正在断开相机 Wi-Fi…';
    LumixSyncControlService.clearControlSession();
    this.cameraCards.setConnected(null);
    this.cam.cameraSessionStatus = '未建立';
    this.cam.cameraWifiStatus = '未连接';
    this.cam.cameraBleStatus = '未连接';
    this.cam.cameraMessage = '已断开相机控制：相机热点将在 1-2 分钟内自动关闭，手机随后自动恢复原网络';
  }

  /** 把会话编排能力注册到共享 store，图片传输页面通过 driver 回调触发。 */
  private registerCameraSessionDriver(): void {
    const driver: CameraSessionDriver = {
      fetchMoreGallery: (): Promise<void> => this.fetchMoreCameraGallery(),
      triggerScrollLoad: (): Promise<void> => this.maybeTriggerLumixGalleryOnScroll(),
      startImageTransfer: (): Promise<void> => this.startImageTransferFromPage(),
      endSession: (): Promise<void> => this.endCameraGallerySession(),
      closeWifi: (): Promise<void> => this.closeCameraWifiTransfer(),
      closePreview: (): void => {
        this.closeCameraPreview();
      },
      openPreview: (item: LumixGalleryItem): Promise<void> => this.openCameraImage(item),
      toggleSelection: (itemKey: string): void => {
        this.toggleCameraGallerySelection(itemKey);
      },
      downloadSelected: (): Promise<void> => this.downloadSelectedCameraPhotos(),
      switchSd: (sd: string): Promise<void> => this.switchLumixSdCard(sd),
    };
    this.cam.driver = driver;
  }

  /** 图片传输页面的连接入口：手机已关联相机热点时优先在现有 Wi‑Fi 链路上
   * 直接重建图库会话（不重跑 BLE/ACTION_MODE），失败再回退全量连接流程；
   * Sync 世代的被动推送机身则重新拉起被动接收会话。 */
  private async startImageTransferFromPage(): Promise<void> {
    if (this.cam.cameraTransferInProgress || this.cam.cameraGalleryLoading) return;
    this.cameraWifiCloseRequested = false;
    if (this.cam.cameraBrand === 'Sony') {
      // 索尼线：图片传输页的连接/重建也走同一条按需路径——先由蓝牙取凭据并
      // 关联相机 Wi‑Fi（已在热点上时立即返回），成功后才枚举相机内容。
      try {
        const wifiReady = await this.ensureSonyWifiForAction('图片传输');
        if (!wifiReady) return;
        if (this.cam.cameraGalleryItems.length > 0) return;
        await this.runNikonPtpGallery(true);
      } catch (error) {
        this.cam.cameraSessionStatus = '未建立';
        this.cam.cameraMessage = `索尼相机图库读取失败：${(error as Error).message}`;
        AppLogStore.add(`sony-wifi gallery failed: ${String(error)}`);
      }
      return;
    }
    if (this.cam.cameraBrand === 'Nikon') {
      // 尼康线：与索尼线同构——先按需拉起相机 Wi‑Fi（已配网则立即返回），再建立
      // PTP/IP 会话并枚举图库。尼康没有「只配对蓝牙」的中间态，所以这一步是冷
      // 启动（应用重启，或离开图片传输后会话已关）时唯一的重建入口；否则会落到
      // 下面的 runCameraImportPrototype，那条路要求 BLE 候选在线并会重置会话状态。
      try {
        const wifiReady = await this.ensureNikonWifiForAction('图片传输');
        if (!wifiReady) return;
        if (this.cam.cameraGalleryItems.length > 0) return;
        await this.runNikonPtpGallery(true);
      } catch (error) {
        this.cam.cameraSessionStatus = '未建立';
        this.cam.cameraMessage = `尼康相机图库读取失败：${(error as Error).message}`;
        AppLogStore.add(`nikon-wifi gallery failed: ${String(error)}`);
      }
      return;
    }
    if (this.cam.cameraBrand === 'Panasonic') {
      // The LUMIX Image App line has no HTTP gallery to rebuild: entering the
      // page re-arms the passive camera-push Wi-Fi session directly, unless a
      // session is already alive (a restart would interrupt an in-flight push
      // transfer). Sync-line bodies instead rebuild their gallery over
      // cam.cgi/DLNA like Lab does.
      if (this.camCgiRouteSelected()) {
        if (this.cam.cameraState !== 2 || !this.cameraWifiConnected()) {
          await this.runPanasonicWifiOnlyImport(true);
        }
        return;
      }
      if (this.cam.cameraGalleryItems.length > 0) return;
      if (this.cam.cameraState === 2) {
        await this.refreshGalleryFromLiveLinkOrFallback();
        return;
      }
      // 相机可能仍停留在远程控制模式（BLE 广播已停止、手机已保存热点并
      // 自动回连）。此时全量连接流程无法完成，只要手机关联的是非 Wi‑Fi
      // 直连款的松下相机热点，就直接走纯 HTTP 快速重建。
      let linkedSsid = '';
      try {
        linkedSsid = await LumixCameraService.linkedSsid();
      } catch (_error) {
      }
      const linkedIdentity = LumixCameraService.identifyWifiSsid(linkedSsid);
      if (linkedIdentity !== null &&
        LumixCameraService.panasonicRouteForModel(linkedIdentity.model) !== 'sync') {
        await this.refreshGalleryFromLiveLinkOrFallback();
        return;
      }
    }
    await this.runCameraImportPrototype(true);
  }

  private async refreshGalleryFromLiveLinkOrFallback(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.cam.cameraSessionStatus = '认证中';
    this.cam.cameraMessage = '正在通过相机 Wi‑Fi 重建图库会话…';
    this.cam.cameraGalleryLoading = true;
    let refresh: LumixGalleryRefresh = { ok: false, items: [], total: 0, message: '' };
    try {
      // No watchdog here means a half-open AP link can leave the page stuck
      // on "正在重建图库会话" forever with cameraGalleryLoading = true, which
      // also blocks every later fetchMore. Race the refresh against a hard
      // timeout and fall through to the full reconnect flow.
      const timeoutMs = 45000;
      refresh = await Promise.race([
        LumixImportPrototype.refreshGallerySession(context, this.cam.selectedSd),
        new Promise<LumixGalleryRefresh>((resolve: (value: LumixGalleryRefresh) => void) => {
          setTimeout(() => {
            resolve({ ok: false, items: [], total: 0, message: `重建超时（${timeoutMs / 1000} 秒）` });
          }, timeoutMs);
        }),
      ]);
    } finally {
      this.cam.cameraGalleryLoading = false;
    }
    if (refresh.ok) {
      this.commitRefreshedGallery(refresh.items, refresh.total);
      if (this.cam.cameraState !== 2) this.cam.cameraState = 2;
      this.cam.cameraWifiStatus = '已连接';
      await this.rememberCameraCard();
      // 空卡等场景 message 自带提示（如“SD1 上没有照片，可切换另一张存储卡”）。
      this.cam.cameraMessage = refresh.message.length > 0
        ? refresh.message : `已从相机加载 ${refresh.items.length} 张缩略图`;
      return;
    }
    AppLogStore.add(`图片传输快速重建失败：${refresh.message}，回退完整连接流程`);
    this.cam.cameraMessage = `快速重建未完成（${refresh.message}），正在重新建立完整连接…`;
    try {
      await this.runLumixImportPrototype(true);
    } catch (_error) {
    }
  }

  /**
   * 把 BLE SLOT_INFO 的槽位清单落成"在位"状态。
   *
   * `current-sd` 只回答"这个槽位存在"，**不回答"槽里有卡"**：对一张空卡、甚至
   * 完全没插卡的槽位，它同样回 HTTP 200 / business 200。之前正是把它的成功应答
   * 当成在位判据（sdSource=lab-current-sd），于是用户手上根本没有的那张卡也能
   * 点亮、也能点切换（2026-10-17 真机现象）。
   *
   * SLOT_INFO 是唯一逐槽报告有无卡的数据源，优先级最高：相机没报的槽位就是
   * 不存在，报了的按它的 present 标志来。
   */
  private applyBleSlotPresence(): void {
    const info = LumixImportPrototype.currentSlotInfo();
    if (!info.ok || info.slots.length === 0) return;
    let names = '';
    for (let index = 0; index < info.slots.length; index++) {
      const slot = info.slots[index];
      names = names.length === 0 ? `${slot.name}:${slot.present ? 1 : 0}`
        : `${names},${slot.name}:${slot.present ? 1 : 0}`;
      // 相机报的是槽位**类型**（S1RM2 的 CFe/SD/SSD 不是物理槽号），所以这里
      // 只按上报顺序落到两个旧标志上，供日志与回退路径使用；真正的按钮状态由
      // ImageTransferPage 直接读槽位清单，不经这两个标志。
      if (index === 0) this.cam.cameraSd1Present = slot.present;
      if (index === 1) this.cam.cameraSd2Present = slot.present;
    }
    if (info.slots.length === 1) this.cam.cameraSd2Present = false;
    this.cam.cameraSdPresenceSource = 'ble-slot';
    AppLogStore.add(`BLE 槽位 ${names} → sd1=${this.cam.cameraSd1Present ? 1 : 0}`
      + ` sd2=${this.cam.cameraSd2Present ? 1 : 0}`);
  }

  private commitRefreshedGallery(items: LumixGalleryItem[], total: number): void {
    // 图库每次落地都刷新一次槽位在位状态：这是唯一同时掌握"图上加载了哪张卡"
    // 与"机身到底有几个槽"的时机。
    this.applyBleSlotPresence();
    // 只有在**读不到** BLE 槽位清单时，才用"刚从这个槽位读出照片"反推它在位。
    // 能读到清单时一律以相机为准：用户点了空的 SD 槽，current-sd 并不会真切换，
    // 图库会把 CFE 卡的照片返回，此时若拿"有照片"反推，就会把相机明确报告为
    // 空的槽位重新标成有卡——等于把刚修掉的谎话又加回去。
    if (!LumixImportPrototype.currentSlotInfo().ok && items.length > 0) {
      const active = this.cam.selectedSd;
      if (active === 'SD2') this.cam.cameraSd2Present = true;
      else this.cam.cameraSd1Present = true;
    }
    this.cam.cameraGalleryItems = items;
    this.cam.cameraGalleryTotal = total > 0 ? total : items.length;
    this.cameraGalleryNextStartIndex = Math.max(0, this.cam.cameraGalleryTotal - 12);
    this.cam.cameraGalleryHasMore = this.cam.cameraGalleryTotal > 6 ||
      (this.cam.cameraGalleryTotal === 0 && items.length >= 6);
    this.cameraGalleryPage = 1;
    this.cameraGalleryScrollFetched = false;
    this.cam.selectedCameraImageIds = [];
    this.cam.cameraSessionStatus = '已建立';
    // 松下首屏只有 6 条记录（可能展开成 12 个文件），一屏放得下，用户没得滑，
    // onScrollEdge 永远不触发 → 分页会死锁。所以保留一次后台预取，但阈值必须
    // 是"刚好填满一屏"，不能是原来的 24：一页就已经 12 个文件，`< 24` 会立刻再拉
    // 一页，用户一进图库就看到剩余照片被自动加载完（2026-10-17 反馈）。
    // 取 12 ——补满一页即停，之后交给用户下滑。
    if (this.cam.cameraBrand === 'Panasonic' && this.cam.cameraGalleryHasMore &&
      this.cam.cameraGalleryItems.length < 12) {
      setTimeout(() => { this.fetchMoreCameraGallery(); }, 0);
    }
  }

  /**
   * 退出图片传输页面时的轻量会话结束：只释放会话与图库状态，保留手机与
   * 相机热点的关联、BLE/GATT 链路和已注册身份，重新进入页面时通过
   * refreshGallerySession 在现有链路上快速重建会话。
   */
  private async endCameraGallerySession(): Promise<void> {
    if (this.cam.cameraDownloadInProgress || this.cam.s5Receiving) return;
    if (this.cam.isCamCgiLineSelected()) return;
    if (this.cam.cameraPreviewVisible) this.closeCameraPreview();
    if (this.isPtpIpCamera()) {
      if (this.cam.cameraBrand === 'Sony') {
        // 索尼线保持原样：它有自己的内容服务与缩略图泵，收尾方式不变。
        NikonPtpIpService.close();
        this.stopSonyThumbnailPump();
        SonyPtpIpContent.close();
      } else {
        // **尼康线：退出页面不关 PTP/IP 会话。**
        //
        // 原来这里调 `close()`（上一轮改成 `closeGracefully()`，一样没用），两者
        // 都会把 `session.failed` 置真并关掉 TCP。后果有两层：
        //
        //  1. `ensureSession` 的复用条件是 `!existing.failed`，所以下一次进图传必然
        //     重新握手，而不是复用；
        //  2. 更严重的是**相机会因此撤掉热点**——尼康的「连接至智能设备」跟这条
        //     PTP/IP 链路绑在一起，链路一断，手机连着的 Wi-Fi 就没了，只能重新用
        //     蓝牙拉起 AP。这正是「控制页退出 → 图传页退出 → Wi-Fi 断联」的原因。
        //
        // 控制页的收尾早就是「会话归相机页所有，不在这里关」，图传页多关了一次，
        // 两边策略不一致。现在统一：**退出页面只清界面状态，会话留到用户真正断开
        // 连接或相机不可达时再收**（见本页 Wi-Fi 丢失分支）。
        this.stopSonyThumbnailPump();
      }
    } else {
      LumixImportPrototype.endGallerySession();
    }
    this.cam.cameraSessionStatus = '未建立';
    this.cam.cameraGalleryItems = [];
    this.cam.cameraGalleryTotal = 0;
    this.cam.cameraGalleryHasMore = false;
    this.cameraGalleryPage = 1;
    this.cameraGalleryNextStartIndex = 0;
    this.cameraGalleryNikonCursor = 0;
    this.cameraGalleryRequestSeq += 1;
    this.cam.cameraGalleryLoading = false;
    this.cameraGalleryScrollFetched = false;
    this.cameraGalleryScrollOffset = 0;
    this.cam.selectedCameraImageIds = [];
    this.cam.cameraMessage = '图片传输会话已结束，重新进入后自动重建';
  }

  /**
   * 松下机型切换存储卡。槽位名一律取相机 BLE 上报的那一套（CFe/SD/SSD 或
   * SD1/SD2），手机仍关联相机热点时通过活会话直接重写 current-sd 并重新读取
   * 图库（官方 App 的卡内切换行为），点击立即生效；会话不可用时仅记住选择，
   * 连接后再次点击生效。
   */
  /** 存储卡按钮诊断：点击被拒时不留其它痕迹，因此把原因与在位状态一起记账。
   *  在位判据按可信度排序：BLE SLOT_INFO（sdSource=ble-slot，唯一逐槽报告有无卡
   *  的来源）> Sync 线探针（sync-probe）> 都拿不到时的不确定态。current-sd 的
   *  成功应答**不是**在位证据，它只表示该槽位存在。 */
  private logSdCardEvent(detail: string): void {
    AppDiagnostics.event('APP', `card slot ${detail}` +
      ` sd1Present=${this.cam.cameraSd1Present ? 1 : 0}` +
      ` sd2Present=${this.cam.cameraSd2Present ? 1 : 0}` +
      ` sdSource=${this.cam.cameraSdPresenceSource}`);
  }

  private async switchLumixSdCard(sd: string): Promise<void> {
    // 合法值必须取自相机上报的槽位清单：S1RM2 的槽位名是 CFe/SD/SSD，只放行
    // SD1/SD2 会把它的 SD 卡直接挡在门外（这正是"只看得到 CFexpress 卡照片"
    // 的成因）。清单读不到时才退回 SD1/SD2。
    const slotInfo = LumixImportPrototype.currentSlotInfo();
    let knownSlot = sd === 'SD1' || sd === 'SD2';
    if (slotInfo.ok) {
      for (const slot of slotInfo.slots) {
        if (slot.wire === sd || slot.name === sd) knownSlot = true;
      }
    }
    if (!knownSlot) {
      this.logSdCardEvent('sdBlocked=invalid-slot');
      return;
    }
    if (this.cam.selectedSd === sd) {
      this.logSdCardEvent(`sdSwitch=${sd} sdBlocked=same-slot`);
      return;
    }
    this.cam.selectedSd = sd;
    if (this.cam.cameraBrand === 'Sony') {
      // 索尼的卡槽不是一条"当前卡"命令，而是 0x923B/0x923C 的**请求参数**：
      // 切换只能靠重新枚举。所以记住选择后重跑一遍图库会话（runNikonPtpGallery
      // 本身就是"重建会话 + 重启图库"的入口，分页会话丢失时也走它）。
      if (this.cam.cameraState !== 2 || !this.cameraWifiConnected()) {
        this.logSdCardEvent(`sdSwitch=${sd} sdBlocked=camera-not-ready state=${this.cam.cameraState}`);
        this.cam.cameraMessage = `已选择 ${sd} 存储卡，连接后自动生效`;
        return;
      }
      if (this.cam.cameraTransferInProgress || this.cam.cameraGalleryLoading) {
        this.logSdCardEvent(`sdSwitch=${sd} sdBlocked=gallery-busy`);
        this.cam.cameraMessage = `连接完成后请再次点击 ${sd} 完成切换`;
        return;
      }
      this.logSdCardEvent(`sdSwitch=${sd} sdBlocked=none sony=reenumerate`);
      AppLogStore.add(`ui 切换索尼存储卡 ${sd}`);
      this.cam.cameraMessage = `正在切换到 ${sd} 并重新读取图库…`;
      SonyPtpIpContent.setPreferredSlot(sd === 'SD2'
        ? SonyPtpIpContent.SLOT_2 : SonyPtpIpContent.SLOT_1);
      this.stopSonyThumbnailPump();
      this.cam.cameraGalleryItems = [];
      await this.runNikonPtpGallery(true);
      return;
    }
    if (this.cam.cameraBrand !== 'Panasonic' || this.camCgiRouteSelected() || this.cam.cameraState !== 2) {
      this.logSdCardEvent(`sdSwitch=${sd} sdBlocked=camera-not-ready state=${this.cam.cameraState}`);
      this.cam.cameraMessage = `已选择 ${sd} 存储卡，连接后自动生效`;
      return;
    }
    if (this.cam.cameraTransferInProgress || this.cam.cameraGalleryLoading) {
      this.logSdCardEvent(`sdSwitch=${sd} sdBlocked=gallery-busy`);
      this.cam.cameraMessage = `连接完成后请再次点击 ${sd} 完成切换`;
      return;
    }
    this.logSdCardEvent(`sdSwitch=${sd} sdBlocked=none`);
    AppLogStore.add(`ui 切换松下存储卡 ${sd}`);
    this.cam.cameraMessage = `正在切换到 ${sd} 并重新读取图库…`;
    this.cam.cameraGalleryLoading = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let refresh: LumixGalleryRefresh = { ok: false, items: [], total: 0, message: '' };
    try {
      refresh = await LumixImportPrototype.refreshGallerySession(context, sd);
    } finally {
      this.cam.cameraGalleryLoading = false;
    }
    if (!refresh.ok) {
      // 失败**不当作**"该槽无卡"的证据：原因可能是令牌/网络，也可能是这个线上的
      // 槽位值不被相机接受。据此禁用会重演同一个 bug，所以只记账。
      this.logSdCardEvent(`sdSwitch=${sd} sdBlocked=none sdResult=rejected`);
      AppLogStore.add(`切换 ${sd} 失败：${refresh.message}`);
      this.cam.cameraMessage = `切换到 ${sd} 失败：${refresh.message}`;
      return;
    }
    // current-sd 只确认"槽位存在"，不确认"槽里有卡"（见 applyBleSlotPresence）。
    // 有 BLE 槽位清单时一律以它为准；只有完全读不到清单时才退回旧行为，免得把
    // "点得动"误当成"有卡"。
    if (slotInfo.ok && slotInfo.slots.length > 0) {
      this.applyBleSlotPresence();
    } else if (this.cam.cameraSdPresenceSource !== 'sync-probe') {
      if (sd === 'SD1') this.cam.cameraSd1Present = true;
      else this.cam.cameraSd2Present = true;
      this.cam.cameraSdPresenceSource = 'lab-current-sd';
    }
    this.logSdCardEvent(`sdSwitch=${sd} sdResult=ok`);
    this.commitRefreshedGallery(refresh.items, refresh.total);
    this.cam.cameraMessage = refresh.message.length > 0
      ? `已切换到 ${sd}，${refresh.message}` : `已切换到 ${sd}，已加载 ${refresh.items.length} 张缩略图`;
  }

  /**
   * Stop any live camera Wi-Fi session and clear its page state. Used by the
   * close button and whenever the user confirms a DIFFERENT body while an old
   * session (for example an original-S5 passive receiver) is still linked:
   * the receiver must be stopped unconditionally because the selected card
   * has already moved on to the new camera, even though the S5 identity is
   * no longer the one on screen.
   */
  private async teardownActiveCameraWifiSession(): Promise<void> {
    this.cameraCards.setConnected(null);
    await PanasonicS5Receiver.stop();
    await LumixImportPrototype.disconnectCameraWifi();
    NikonPtpIpService.close();
    this.stopSonyThumbnailPump();
    SonyPtpIpContent.close();
    this.showWifiPicker = false;
    this.wifiCandidates = [];
    this.wifiConnecting = false;
    this.cam.cameraWifiStatus = '未连接';
    this.cameraWifiOnlyReady = false;
    this.cam.cameraSessionStatus = '未建立';
    this.cam.cameraWifiSsid = '';
    this.cameraHost = '';
    this.cam.cameraGalleryItems = [];
    this.cam.cameraGalleryTotal = 0;
    this.cam.cameraGalleryHasMore = false;
    this.cameraGalleryPage = 1;
    this.cameraGalleryNextStartIndex = 0;
    this.cameraGalleryNikonCursor = 0;
    this.cameraGalleryRequestSeq += 1;
    this.cam.cameraGalleryLoading = false;
    this.cam.cameraTransferInProgress = false;
    this.cameraGalleryScrollFetched = false;
    this.cam.selectedCameraImageIds = [];
    this.cam.s5Receiving = false;
    this.cam.s5ReceiveProgress = 0;
    this.cam.s5ReceiveStatus = '';
    this.cam.s5ReceiveFiles = 0;
    this.syncS5ReceiveOverlayState();
    this.s5LastReceivedJpegUri = '';
  }

  private async requestWifiPermissions(): Promise<boolean> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const manager = abilityAccessCtrl.createAtManager();
      await manager.requestPermissionsFromUser(context, [
        'ohos.permission.GET_WIFI_INFO',
        'ohos.permission.SET_WIFI_INFO',
        'ohos.permission.LOCATION',
        'ohos.permission.APPROXIMATELY_LOCATION',
      ]);
      return true;
    } catch (_error) {
      return false;
    }
  }

  /**
   * Prepare the local radios when the camera page is opened. HarmonyOS may
   * reject programmatic Wi‑Fi enablement for a third-party app; in that case
   * the request is still attempted and the existing scan flow reports the
   * concrete permission/system state instead of pretending the camera is
   * reachable. Bluetooth has an async user-confirmed API on API 26.
   */
  private async prepareCameraRadioAccess(): Promise<void> {
    if (this.cameraRadioRequestInFlight) return;
    this.cameraRadioRequestInFlight = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const manager = abilityAccessCtrl.createAtManager();
      try {
        await manager.requestPermissionsFromUser(context, [
          'ohos.permission.ACCESS_BLUETOOTH',
          'ohos.permission.GET_WIFI_INFO',
          'ohos.permission.SET_WIFI_INFO',
          'ohos.permission.LOCATION',
          'ohos.permission.APPROXIMATELY_LOCATION',
        ]);
      } catch (_error) {
        // startCameraBleDiscovery/requestWifiPermissions will surface the
        // permission failure in the page while still allowing a retry.
      }

      let bluetoothReady = false;
      try {
        bluetoothReady = bluetoothAccess.getState() !== bluetoothAccess.BluetoothState.STATE_OFF;
      } catch (_error) {
        bluetoothReady = false;
      }
      if (!bluetoothReady) {
        try {
          await bluetoothAccess.enableBluetoothAsync();
        } catch (_error) {
          // API 26 devices may expose only the synchronous compatibility call.
          try { bluetoothAccess.enableBluetooth(); } catch (_fallbackError) { }
        }
      }

      try {
        if (!wifiManager.isWifiActive()) wifiManager.enableWifi();
      } catch (_error) {
        // MANAGE_WIFI_CONNECTION is system-controlled on some builds. The
        // later camera Wi‑Fi flow will continue with a system connection
        // sheet when enableWifi is unavailable to this application.
      }
      if (this.selectedSection === 1) await this.startCameraBleDiscovery();
    } finally {
      this.cameraRadioRequestInFlight = false;
    }
  }

  /**
   * Match a scanned access point to the camera identity selected in the
   * carousel. A phone can see multiple Nikon APs at once; model-only or
   * strongest-RSSI fallback is unsafe when two bodies are powered on.
   */
  private cameraWifiMatchesSelectedIdentity(candidate: LumixWifiCandidate): boolean {
    const selectedBrand = this.cameraBleCandidateBrand.length > 0 ? this.cameraBleCandidateBrand : this.cam.cameraBrand;
    if (selectedBrand.length > 0 && candidate.brand && selectedBrand !== candidate.brand) return false;
    const selectedModel = (this.cam.cameraBleCandidateModel.length > 0 ? this.cam.cameraBleCandidateModel : this.cam.cameraModel)
      .toUpperCase().replace(/[^A-Z0-9]+/g, '');
    const candidateModel = candidate.model.toUpperCase().replace(/[^A-Z0-9]+/g, '');
    const genericModel = selectedModel === '' || selectedModel === 'NIKON' || selectedModel === 'LUMIX' || selectedModel === 'PANASONIC';
    if (!genericModel && candidateModel.length > 0 && selectedModel !== candidateModel) return false;
    const selectedImage = this.cameraBleCandidateImageKey.length > 0 ? this.cameraBleCandidateImageKey : this.cam.cameraImageKey;
    if (selectedImage.length > 0 && candidate.imageKey.length > 0 && selectedImage !== candidate.imageKey) return false;
    // The instance suffix is shared by the BLE name and the camera AP on the
    // bodies tested (for example Z_5_8073573). Use it when available so two
    // cameras of the same model are still kept separate.
    const instanceToken = (value: string): string => {
      const upper = value.toUpperCase();
      // Nikon instance ids are numeric. Prefer the final numeric run so an AP
      // suffix such as "_1234567_5G" still binds to the same body.
      const numeric = upper.match(/[0-9]{4,}/g);
      if (numeric && numeric.length > 0) return numeric[numeric.length - 1];
      const parts = upper.replace(/[^A-Z0-9]+/g, '_').split('_');
      const last = parts.length > 0 ? parts[parts.length - 1] : '';
      return /^[A-Z0-9]{4,}$/.test(last) ? last : '';
    };
    const selectedToken = instanceToken(this.cam.cameraBleCandidateName);
    const candidateToken = instanceToken(candidate.ssid);
    if (selectedToken.length > 0 && candidateToken.length > 0 && selectedToken !== candidateToken) return false;
    return true;
  }

  private async scanCameraWifi(autoConnectSingle: boolean = false): Promise<void> {
    if (this.wifiScanState === 1) return;
    this.wifiScanState = 1;
    this.cam.cameraMessage = '正在扫描附近相机 Wi-Fi…';
    const permissionGranted = await this.requestWifiPermissions();
    if (!permissionGranted) {
      this.wifiScanState = 0;
      this.cam.cameraMessage = '需要允许附近网络权限，才能识别相机 Wi-Fi';
      return;
    }
    // If the user already joined the Nikon AP outside Vivid, the scan list may
    // not contain that hidden/low-power SSID. Resolve the linked SSID first
    // and enter the same PTP/IP path without showing a picker or asking for a
    // second manual action.
    const directWifiPanasonic = this.cam.cameraBrand === 'Panasonic' &&
      (LumixCameraService.isWifiOnlyModel(`${this.cam.cameraModel} ${this.cam.cameraBleCandidateModel} ${this.cam.cameraBleCandidateName}`) ||
        this.camCgiRouteSelected());
    if (autoConnectSingle && (this.isPtpIpCamera() || directWifiPanasonic)) {
      const linkedSsid = await LumixCameraService.linkedSsid();
      const linkedIdentity = this.cam.cameraBrand === 'Nikon'
        ? NikonCameraService.identifyWifiSsid(linkedSsid)
        : (this.cam.cameraBrand === 'Sony'
          ? SonyCameraService.identifyWifiSsid(linkedSsid)
          : LumixCameraService.identifyWifiSsid(linkedSsid));
      if (linkedIdentity) {
        const linkedCandidate: LumixWifiCandidate = {
          ssid: linkedSsid,
          bssid: '',
          rssi: 0,
          securityType: 0,
          model: linkedIdentity.model,
          family: linkedIdentity.family,
          imageKey: linkedIdentity.imageKey,
          brand: this.cam.cameraBrand,
        };
        // Only reuse the already linked network when it belongs to the
        // selected card. If Z8 is linked while Z5 is selected, continue to the
        // scan and select Z5 instead of silently reusing Z8.
        if (this.cameraWifiMatchesSelectedIdentity(linkedCandidate)) {
          this.wifiCandidates = [linkedCandidate];
          this.cam.cameraMessage = this.cam.cameraBrand === 'Nikon'
            ? `已检测到所选尼康 Wi‑Fi ${linkedSsid}，直接开始 PTP/IP 读取…`
            : (this.cam.cameraBrand === 'Sony'
              ? `已检测到所选索尼 Wi‑Fi ${linkedSsid}，直接开始 PTP/IP 读取…`
              : `已检测到所选松下相机 Wi‑Fi ${linkedSsid}，直接开始图像读取…`);
          this.wifiScanState = 0;
          await this.connectCameraWifi(linkedCandidate);
          return;
        }
      }
    }
    const candidates = await LumixCameraService.scanForCameras();
    this.wifiCandidates = candidates;
    this.wifiScanState = 0;
    if (candidates.length > 0) {
      this.cam.cameraMessage = `发现 ${candidates.length} 个相机 Wi-Fi`;
      let autoCandidate: LumixWifiCandidate | null = null;
      if (autoConnectSingle && (this.isPtpIpCamera() || directWifiPanasonic)) {
        // Prefer the AP belonging to the selected body. Never fall back to
        // candidates[0] when the card carries a concrete model/instance: that
        // was the source of Z5 -> Z8 cross-connection when both APs were open.
        for (const candidate of candidates) {
          if (this.cameraWifiMatchesSelectedIdentity(candidate)) {
            autoCandidate = candidate;
            break;
          }
        }
        const hasExplicitTarget = this.cam.cameraBleCandidateName.length > 0 ||
          this.cam.cameraBleCandidateModel.length > 0 || this.cameraBleCandidateImageKey.length > 0;
        if (!autoCandidate && !hasExplicitTarget && candidates.length > 0) autoCandidate = candidates[0];
      } else if (autoConnectSingle && candidates.length === 1) {
        autoCandidate = candidates[0];
      }
      if (autoCandidate) {
        // Nikon bodies do not use the generic Bluetooth bond flow. When the
        // camera exposes one matching AP, continue directly to the system
        // Wi-Fi connection sheet and avoid a second in-app choice dialog.
        await this.connectCameraWifi(autoCandidate);
      } else {
        this.showWifiPicker = true;
      }
    } else {
      this.cam.cameraMessage = '未发现相机 Wi-Fi，请打开相机无线功能';
    }
  }

  private confirmCameraWifi(candidate: LumixWifiCandidate): void {
    if (this.wifiConnecting) return;
    this.getUIContext().getPromptAction().showDialog({
      title: '连接相机 Wi-Fi',
      message: `检测到 ${candidate.ssid}\n${candidate.model} · ${candidate.family}\n是否允许系统切换到该网络并开始握手？`,
      buttons: [
        { text: '取消', color: '#657286' },
        { text: '连接', color: '#316CF4' },
      ],
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.connectCameraWifi(candidate);
      }
    }).catch(() => {});
  }

  @Builder
  CameraWifiPasswordContent($$: CameraWifiPasswordDialogOptions) {
    CameraWifiPasswordDialog({
      wifiSsid: $$.ssid, wifiSecurityType: $$.securityType, promptMessage: $$.message,
      onConfirm: $$.onConfirm, onCancel: $$.onCancel,
    });
  }

  private cancelCameraWifiPasswordRequest(): void {
    this.cameraWifiJoinSequence += 1;
    const cancel = this.cameraWifiPasswordCancel;
    this.cameraWifiPasswordCancel = null;
    if (cancel) cancel();
    this.wifiConnecting = false;
  }

  private requestCameraWifiPassword(candidate: LumixWifiCandidate, message: string,
    sequence: number): Promise<string | null> {
    if (sequence !== this.cameraWifiJoinSequence) return Promise.resolve<string | null>(null);
    this.showWifiPicker = false;
    this.cam.cameraMessage = '请输入所选相机 Wi-Fi 的密码';
    return new Promise<string | null>((resolve: (password: string | null) => void): void => {
      let dialogId = -1;
      let settled = false;
      let closing = false;
      let enteredPassword: string | null = null;
      const finish = (): void => {
        if (settled) return;
        settled = true;
        if (this.cameraWifiPasswordCancel === cancel) this.cameraWifiPasswordCancel = null;
        const result = enteredPassword;
        enteredPassword = null;
        resolve(sequence === this.cameraWifiJoinSequence ? result : null);
      };
      const close = (password: string | null): void => {
        if (settled || closing) return;
        closing = true;
        enteredPassword = password;
        if (dialogId >= 0) {
          try { this.getUIContext().getPromptAction().closeCustomDialog(dialogId); }
          catch (_error) { enteredPassword = null; finish(); }
        }
      };
      const cancel = (): void => {
        enteredPassword = null;
        if (!closing) close(null);
        // Navigation may interrupt onDidDisappear. Always release the pending join.
        finish();
      };
      this.cameraWifiPasswordCancel = cancel;
      const dialogOptions: CameraWifiPasswordDialogOptions = {
        ssid: candidate.ssid, securityType: candidate.securityType, message: message,
        onConfirm: (password: string): void => { close(password); },
        onCancel: (): void => { close(null); },
      };
      try {
        const options: promptAction.CustomDialogOptions = {
          builder: (): void => { this.CameraWifiPasswordContent(dialogOptions); },
          autoCancel: true, alignment: DialogAlignment.Center, backgroundColor: Color.Transparent,
          onWillDismiss: (action: DismissDialogAction): void => {
            closing = true;
            enteredPassword = null;
            action.dismiss();
          },
          // Wait until the input dialog is gone before requesting system trust.
          onDidDisappear: (): void => { finish(); },
        };
        this.getUIContext().getPromptAction().openCustomDialog(options).then((id: number): void => {
          dialogId = id;
          if (closing || settled || sequence !== this.cameraWifiJoinSequence) {
            try { this.getUIContext().getPromptAction().closeCustomDialog(id); }
            catch (_error) { enteredPassword = null; finish(); }
          }
        }).catch((): void => { enteredPassword = null; finish(); });
      } catch (_error) { enteredPassword = null; finish(); }
    });
  }

  private async connectCameraWifi(candidate: LumixWifiCandidate): Promise<void> {
    if (this.wifiConnecting) return;
    const joinSequence = ++this.cameraWifiJoinSequence;
    this.cameraWifiCloseRequested = false;
    this.wifiConnecting = true;
    this.cam.cameraMessage = `正在连接 ${candidate.ssid}…`;
    const directWifiSync = this.isSyncWifiCandidate(candidate);
    this.cameraWifiOnlyReady = false;
    // S5M2-class bodies secure their AP with a WPA key that is only handed
    // out over the BLE GATT link. The generic candidate connect below uses
    // cannot replace that protocol with a user-entered key, which can never
    // associate with this AP and leaves the camera waiting forever on its
    // own "connecting to Wi-Fi" screen. Re-enter the BLE flow instead: it
    // re-registers over GATT, turns the AP on through ACTION_MODE, reads the
    // real SSID/password and performs the association itself.
    const bleCredentialPanasonic = (candidate.brand || this.cam.cameraBrand) === 'Panasonic' &&
      !directWifiSync;
    // Enter the BLE credential flow not only when no camera Wi-Fi is up, but
    // also when the phone is associated with a DIFFERENT camera's AP (for
    // example still linked to an original S5 while confirming an S5M2). The
    // generic empty-PSK connect below can never associate with a WPA camera
    // AP, so keeping the old session would leave the new body waiting forever
    // on its own "connecting to Wi-Fi" screen.
    let currentlyLinkedSsid = '';
    try { currentlyLinkedSsid = await LumixCameraService.linkedSsid(); } catch (_error) { }
    const normalizeSsid = (value: string): string => value.replace(/^"|"$/g, '').trim();
    const linkedToOtherCamera = currentlyLinkedSsid.length > 0 &&
      normalizeSsid(currentlyLinkedSsid) !== normalizeSsid(candidate.ssid);
    if (bleCredentialPanasonic && (!this.cameraWifiConnected() || linkedToOtherCamera)) {
      if (linkedToOtherCamera) {
        // Release the previous camera's system link and stop its passive
        // receiver before the BLE flow switches the phone to the new body.
        await this.teardownActiveCameraWifiSession();
        this.cam.cameraMessage = `已断开 ${normalizeSsid(currentlyLinkedSsid)}，正在经蓝牙连接 ${candidate.ssid}…`;
      }
      this.cam.cameraBrand = 'Panasonic';
      if (this.cam.cameraBleCandidateName.length === 0) {
        this.cam.cameraBleCandidateName = candidate.ssid;
        this.cam.cameraBleCandidateModel = candidate.model;
        this.cameraBleCandidateImageKey = candidate.imageKey;
        this.cameraBleCandidateBrand = 'Panasonic';
      }
      this.cam.cameraMessage = `${candidate.ssid} 的 Wi‑Fi 密码需经蓝牙获取，正在建立 BLE 连接…`;
      this.wifiConnecting = false;
      await this.runCameraImportPrototype(true);
      return;
    }
    let result: LumixWifiConnectionResult;
    try {
      // Sync BLE credentials already belong to this registered body. Reuse them
      // for direct AP entry only when the entire SSID also matches.
      let protocolPassword = '';
      if (directWifiSync && this.cameraBleCandidateDeviceId.length > 0) {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const stored = await LumixSyncControlService.storedDirectCredentials(context, this.cameraBleCandidateDeviceId);
        if (CameraWifiPasswordPolicy.sameSsid(stored.ssid, candidate.ssid)) protocolPassword = stored.password;
      }
      result = await LumixCameraService.connectToCameraWifi(candidate, true, {
        password: protocolPassword,
        requestPassword: (target: LumixWifiCandidate, message: string): Promise<string | null> =>
          this.requestCameraWifiPassword(target, message, joinSequence),
        isCancelled: (): boolean => joinSequence !== this.cameraWifiJoinSequence,
      });
    } catch (_error) {
      result = { connected: false, message: '相机 Wi-Fi 连接未完成，请重试', ssid: candidate.ssid };
    } finally {
      if (joinSequence === this.cameraWifiJoinSequence) this.wifiConnecting = false;
    }
    if (joinSequence !== this.cameraWifiJoinSequence) return;
    if (!result.connected) {
      // A failed Wi-Fi association does not invalidate a nearby Nikon/Sony
      // identity. Keep the BLE-discovered body selected so the user can retry
      // without another confirmation or scan.
      const keepPtpIpIdentity = this.isPtpIpCamera() && this.cam.cameraBleCandidateName.length > 0;
      this.cam.cameraState = keepPtpIpIdentity ? 2 : 0;
      if (keepPtpIpIdentity) {
        this.cam.cameraBleStatus = this.cameraBleCandidateConnectable && this.cameraBleLastSeenAt > 0 &&
          Date.now() - this.cameraBleLastSeenAt <= 6000 ? '已发现' : '未连接';
      }
      this.cam.cameraMessage = result.message;
      this.showMessage(result.message);
      return;
    }
    this.cam.cameraWifiSsid = result.ssid;
    if (result.networkId !== undefined) LumixImportPrototype.lastCameraCandidateNetworkId = result.networkId;
    // Association has completed before the HTTP probe. Keep the state honest
    // even when the camera API needs a moment to answer.
    this.cam.cameraWifiStatus = '已连接';
    this.cam.cameraImageKey = candidate.imageKey;
    this.cam.cameraBrand = candidate.brand || this.brandForImageKey(candidate.imageKey);
    await this.rememberCameraCard(false, candidate);
    // The protocol verifier resolves the HTTP host from the active Wi-Fi
    // gateway. The field remains an explicit override for routed/LAN setups.
    this.showWifiPicker = false;
    if (this.isPtpIpCamera()) {
      // Nikon and Sony use standard PTP/IP on the camera AP. Resolve the
      // current DHCP gateway and immediately issue the read-only
      // storage/count/handles sequence; Panasonic's HTTP /auth path remains
      // untouched.
      this.cam.cameraState = 2;
      this.cam.cameraWifiStatus = '已连接';
      this.cam.cameraSessionStatus = '认证中';
      let gateway = await LumixCameraService.linkedGateway();
      if (gateway.length === 0) {
        // The gateway can lag behind association on some stacks. Poll for a
        // few seconds instead of hanging forever in "authenticating".
        for (let attempt = 0; attempt < 5; attempt++) {
          await new Promise<void>((resolve) => setTimeout(resolve, 1000));
          gateway = await LumixCameraService.linkedGateway();
          if (gateway.length > 0) break;
        }
      }
      this.cameraHost = gateway;
      const brandLabel = this.cam.cameraBrand === 'Sony' ? '索尼' : '尼康';
      this.cam.cameraMessage = gateway.length > 0
        ? `${brandLabel}相机 Wi‑Fi 已连接，正在读取 PTP/IP 图库…`
        : `${brandLabel}相机 Wi‑Fi 已连接，但未取得网关地址`;
      if (gateway.length > 0) {
        await this.runNikonPtpGallery(true);
      } else {
        this.cam.cameraSessionStatus = '未建立';
      }
      return;
    }
    // Passive camera-push receive belongs to the LUMIX Image App line, which has
    // no Bluetooth and reaches the body through the camera access point: the
    // observed order is req_acc first, then local DMS/SSDP discovery. The LUMIX
    // Sync line no longer uses this route — like LUMIX Lab it pairs over
    // Bluetooth first, joins the camera access point with the SSID and password
    // the body returned over BLE, and then pulls images actively over
    // cam.cgi/DLNA. A Sync body must therefore fall through to connectCamera().
    if (directWifiSync && this.imageAppSelected()) {
      this.cam.cameraState = 2;
      this.cam.cameraSessionStatus = '认证中';
      this.cameraHost = await LumixCameraService.linkedGateway();
      this.cam.cameraMessage = '相机 Wi‑Fi 已连接，正在建立被动接收会话…';
      await this.preparePanasonicS5PassiveSession();
      return;
    }
    // Other Panasonic direct AP models do not provide a BLE-delivered
    // host. Resolve the active DHCP gateway before probing the local camera API
    // so the automatic Wi-Fi path never falls back to an empty address.
    const linkedGateway = await LumixCameraService.linkedGateway();
    if (linkedGateway.length > 0) this.cameraHost = linkedGateway;
    await this.connectCamera();
    this.cameraWifiOnlyReady = directWifiSync && this.cam.cameraState === 2 && this.cameraWifiConnected();
  }

  private isSyncWifiCandidate(candidate: LumixWifiCandidate): boolean {
    if ((candidate.brand || this.cam.cameraBrand) !== 'Panasonic') return false;
    if (LumixCameraService.isOriginalS5WifiSsid(candidate.ssid) ||
      (candidate.model === 'S5' && candidate.imageKey === 'panasonic_s5')) return true;
    return LumixCameraService.isCamCgiRoute(
      LumixCameraService.panasonicRouteForModel(candidate.model));
  }

  private async connectCameraByTransport(): Promise<void> {
    // Entry log. Without it a tap that never reached the handler and a
    // provision that stalled are indistinguishable from the log: both leave
    // the app apparently doing nothing and produce no output at all.
    try {
      hilog.info(0x0001, 'VIVID_PAIR',
        'confirm tapped transport=%{public}d state=%{public}d brand=%{public}s',
        this.cameraTransport, this.cam.cameraState, this.cam.cameraBrand);
    } catch (_error) {
    }
    // USB 连接：松下那条路仍是「基本不可用」（握手里有松下专用授权），但索尼
    // 走的是标准 PTP over USB，官方 App 也这么做，所以索尼单独走一条通道，
    // 不再弹「USB 暂不可用」。
    if (this.cameraTransport === 1) {
      if (this.cam.cameraBrand === 'Sony') {
        await this.connectSonyUsb(SonyUsbPtp.MODE_CONTENTS_TRANSFER);
        return;
      }
      this.showUsbUnavailableHint();
      return;
    }
    // The Wi-Fi confirm action needs camera-side preparation first (Nikon
    // direct Wi-Fi mode, LUMIX pairing / transfer trust). Show the
    // model-specific steps and only continue into the connector after the
    // user acknowledges them. USB and delete-connection actions pass through.
    if (this.cameraTransport === 0 && this.cam.cameraState !== 2) {
      this.showCameraPreconnectHint();
      return;
    }
    // Sony cards can carry cameraState 2 from an earlier Wi-Fi-only association:
    // CameraCardRegistry predates the Sony Bluetooth route and marks Sony tiles
    // directly connectable, so a remembered card is treated as already paired and
    // the branch above is skipped. A retry then went silently to the Wi-Fi
    // connector and never re-offered pairing. While no session is actually up,
    // the pairing hint must still be offered.
    if (this.cameraTransport === 0 && this.cam.cameraBrand === 'Sony' &&
      !this.cameraWifiConnected() && !this.cameraUsbHandshakeComplete) {
      this.showCameraPreconnectHint();
      return;
    }
    await this.connectCameraByTransportConfirmed();
  }

  /**
   * 索尼 USB（PTP over USB）连接。
   *
   * 流程照搬官方 `Initializer` 的顺序（见 `SonyUsbPtp.probe`）：枚举 → 权限 →
   * Still Image/PTP 接口 → `GetDeviceInfo` → 读 DID 里的 `X_ServerVersion` →
   * 依用户意图与自报版本定 functionMode → `SDIO_OpenSession(0x9210)`。
   * 之后把这条通道交给 `SonyPtpIpContent`，由它跑与 Wi‑Fi 完全相同的六步 setup。
   *
   * `requestedMode` 就是**用户意图**：0 = 相机控制，1 = 图片传输。页面由意图
   * 决定，相机自报只负责把 0/1 升级成 2（`X_ServerVersion >= 4.0`）。
   */
  private async connectSonyUsb(requestedMode: number): Promise<void> {
    AppLogStore.add(`ui USB 连接索尼（意图 mode=${requestedMode}）`);
    this.cam.cameraMessage = '正在通过 USB 连接相机…';
    try {
      const devices = SonyUsbPtp.listDevices();
      AppLogStore.add(`sony-usb 发现 USB 设备数=${devices.length}`);
      if (devices.length === 0) {
        this.cam.cameraMessage = '未发现 USB 相机：请确认已用数据线连接，并在相机「USB 连接」里选择「PC遥控」或「电脑」';
        this.showSonyFailure('usb', this.cam.cameraMessage, '', 'USB 相机未发现');
        return;
      }
      // 会话已开但**模式不匹配**时必须先关掉：`0x9207` 只被 REMOTE_CONTROL /
      // REMOTE_CONTROL_WITH_TRANSFER 会话受理，先用「图片传输」建立的 mode 1 会话
      // 直接点「相机控制」会被机身拒绝（且 `ServerVersion < 4.0` 时无法升级到 2）。
      if (SonyUsbPtp.isOpen() && requestedMode === SonyUsbPtp.MODE_REMOTE_CONTROL &&
        !SonyUsbPtp.controlCapable()) {
        AppLogStore.add(`sony-usb 会话 mode=${SonyUsbPtp.currentFunctionMode()} 不受理控制操作，重开会话`);
        await SonyUsbPtp.close();
      }
      // 会话已经开着就不再 probe：重开一次 0x9210 会被相机以「会话已存在」拒绝，
      // 而控制页 ↔ 传输页之间切换只需要换协议流程，不需要重连 USB。
      if (!SonyUsbPtp.isOpen()) {
        const probe: SonyUsbProbe = await SonyUsbPtp.probe(devices[0], requestedMode);
        AppLogStore.add(`sony-usb probe ok=${probe.ok} route=${probe.route} ` +
          `mode=${probe.functionMode} serverVersion=${probe.serverVersion.toFixed(2)}`);
        if (!probe.ok) {
          this.cam.cameraSessionStatus = '未建立';
          this.cam.cameraMessage = probe.message;
          this.showSonyFailure('usb', probe.message, '', 'USB 连接失败');
          return;
        }
      } else {
        AppLogStore.add(`sony-usb 会话已存在，跳过 probe（意图 mode=${requestedMode}）`);
      }
      this.cam.cameraSessionStatus = 'USB 已连接';
      this.cam.cameraMessage = 'USB 已连接，正在建立索尼会话…';
      // 把 USB 通道交给协议层：图片传输跑完整的六步 setup + 内容枚举；
      // 相机控制只跑六步 setup，不进内容枚举（见 openControlViaTransport）。
      const opened = requestedMode === SonyUsbPtp.MODE_REMOTE_CONTROL
        ? await SonyPtpIpContent.openControlViaTransport(SonyUsbPtp.transport())
        : await SonyPtpIpContent.openViaTransport(SonyUsbPtp.transport());
      if (!opened.ok) {
        this.cam.cameraSessionStatus = '未建立';
        this.cam.cameraMessage = opened.message;
        this.showSonyFailure('usb', opened.message, '', 'USB 会话未建立');
        return;
      }
      this.cam.cameraSessionStatus = '已建立';
      // 控制类操作（0x9207 按键、实时取景开关）改走这条 USB 通道。
      NikonPtpIpService.attachTransport(SonyUsbPtp.transport());
      if (requestedMode === SonyUsbPtp.MODE_REMOTE_CONTROL) {
        AppLogStore.add('sony-usb 会话就绪，进入相机控制页');
        await this.openSonyCameraControl();
      } else {
        AppLogStore.add('sony-usb 会话就绪，进入图片传输页');
        await this.openSonyImageTransfer();
      }
    } catch (error) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = `USB 连接异常：${(error as Error).message}`;
      AppLogStore.add(`sony-usb failed: ${String(error)}`);
      this.showSonyFailure('usb', this.cam.cameraMessage, '', 'USB 连接异常');
    }
  }

  /** USB 连接目前基本不可用的提示弹窗。用户点「仍然尝试」才继续原 USB 流程，
   * 点「取消」返回；两个按钮都不改变任何状态。 */
  private showUsbUnavailableHint(): void {
    AppLogStore.add('ui USB 连接提示弹窗（当前基本不可用）');
    try {
      this.getUIContext().showAlertDialog({
        title: 'USB 连接暂不可用',
        message: 'USB 连接相机目前存在兼容性问题，基本无法完成连接，建议改用 Wi‑Fi 方式连接相机。仍要继续尝试吗？',
        primaryButton: {
          value: '取消',
          action: (): void => {
          },
        },
        secondaryButton: {
          value: '仍然尝试',
          action: (): void => {
            this.connectCameraByTransportConfirmed();
          },
        },
        cancel: (): void => {
        },
      });
    } catch (_error) {
      // 弹窗不可用（极端环境）时退化为消息提示，至少把状况告诉用户。
      this.showMessage('USB 连接相机目前基本不可用，建议改用 Wi‑Fi 方式');
    }
  }

  /** Brand-specific camera-side steps shown right after 确认连接 is tapped. */
  private showCameraPreconnectHint(): void {    try {
      hilog.info(0x0001, 'VIVID_PAIR', 'preconnect hint shown brand=%{public}s',
        this.cam.cameraBrand);
    } catch (_error) {
    }
    const isNikon = this.cam.cameraBrand === 'Nikon';
    const isSony = this.cam.cameraBrand === 'Sony';
    const isImageApp = !isNikon && !isSony && this.imageAppSelected();
    const isSync = !isNikon && !isSony && !isImageApp && this.syncRouteSelected();
    const title = isNikon ? '尼康蓝牙配网'
      : (isSony ? '索尼相机操作指引'
        : (isSync ? 'LUMIX Sync 机型操作指引'
          : (isImageApp ? 'LUMIX Image App 操作指引' : '松下相机操作指引')));
    const message = isNikon
      ? 'VIVID 会先通过蓝牙与相机配对，认证完成后由相机把 Wi‑Fi 名称与密码直接下发，再自动加入相机 Wi‑Fi 并读取照片——不需要在相机上删除 Wi‑Fi 密码。请确认相机蓝牙已开启并停留在配对窗口，然后点击「开始配对」。'
      : (isSony
        ? 'VIVID 会先通过蓝牙与相机配对，配对成功后由相机把 Wi‑Fi 名称与密码直接下发并自动加入相机 Wi‑Fi——不需要在相机屏幕上查看密码。请在相机上打开蓝牙并进入配对窗口（设置 → 手机连接/配对），然后点击「开始配对」。配对过程中系统会弹出蓝牙配对请求，请点「配对/允许」，并在相机上确认。若相机已开启「PC 远程功能」并创建了热点，也可点击「继续连接」直接加入。'
        : (isSync
          ? 'VIVID 会先通过蓝牙与相机配对，配对完成后由相机下发 Wi‑Fi 名称与密码并自动入网——不需要在相机屏幕上查看密码。请确认相机蓝牙已开启并停留在配对窗口，然后点击「继续连接」。若相机没有蓝牙广播，也可先在相机上打开 Wi‑Fi 直连热点，再回来点击「继续连接」手动入网。'
          : (isImageApp
            ? '请在相机上打开 Wi‑Fi 并选择「连接新手机（直连）」或等效的直连模式，等待相机创建热点；然后回到手机点击「继续连接」。若弹出密码输入框，请填写相机屏幕显示的 Wi‑Fi 密码，再确认系统信任。Image App 线只提供图片传输。'
            : '请先在相机上打开「蓝牙配对」并选择新对象，等待配对完成；配对完成后在相机上点击「图片传输」按钮并信任手机 Wi‑Fi，进入图传模式。完成后回到手机点击「继续连接」。')));
    AppLogStore.add(`ui 确认连接前置指引 ${isNikon ? 'Nikon' : (isSony ? 'Sony' : (isSync ? 'Sync' : (isImageApp ? 'ImageApp' : 'Panasonic')))}`);
    const pairAction = (): void => {
      if (isNikon) {
        try {
          hilog.info(0x0001, 'VIVID_PAIR', 'pair button tapped; entering Nikon BLE provisioning');
        } catch (_error) {
        }
        // Same reasoning as the Sony branch below: fired from a dialog button,
        // so the promise is never awaited and any rejection that escapes the
        // method would otherwise surface as a raw, unexplained failure.
        this.connectNikonViaBleProvisioning().catch((error: Error): void => {
          AppLogStore.add(`nikon-provision unhandled: ${error.message}`);
          this.cam.cameraSessionStatus = '未建立';
          this.cam.cameraMessage = `尼康蓝牙配网异常：${error.message}`;
        });
      } else if (isSony) {
        // Fired from a dialog button, so the promise is never awaited. Any
        // rejection that still escapes the method must be swallowed here rather
        // than becoming an unhandled rejection that aborts the app.
        this.connectSonyViaBleProvisioning().catch((error: Error): void => {
          AppLogStore.add(`sony-provision unhandled: ${error.message}`);
          this.cam.cameraSessionStatus = '未建立';
          this.cam.cameraMessage = `索尼蓝牙配网异常：${error.message}`;
        });
      } else {
        this.connectCameraByTransportConfirmed();
      }
    };
    // Sony bodies can also be joined through the PC Remote AP the user starts
    // on the camera, so they get a second button. Every other brand keeps the
    // single-button layout it had before.
    const joinOnlyAction = (): void => {
      this.connectCameraByTransportConfirmed();
    };
    try {
      if (isSony) {
        this.getUIContext().showAlertDialog({
          title,
          message,
          autoCancel: true,
          alignment: DialogAlignment.Center,
          buttons: [
            {
              value: '开始配对',
              action: pairAction,
            },
            {
              value: '继续连接（已开热点）',
              action: joinOnlyAction,
            },
          ],
        });
        return;
      }
      this.getUIContext().showAlertDialog({
        title,
        message,
        autoCancel: true,
        alignment: DialogAlignment.Center,
        buttons: [
          {
            value: isNikon ? '开始配对' : '继续连接',
            action: pairAction,
          },
        ],
      });
    } catch (_error) {
      // The dialog is unavailable (for example during teardown); fall back to
      // starting the connector immediately so the button never dead-ends.
      pairAction();
    }
  }

  /**
   * Nikon route: pair over Bluetooth, take the Wi-Fi credentials the body hands
   * back, and go straight into the PTP/IP session.
   *
   * This replaces the manual "delete the camera's Wi-Fi password" step — the
   * credentials now come from the camera instead of from the user. The network
   * is already joined by the time provisioning returns, so no second
   * association is attempted: LumixWifiCandidate carries no password field, and
   * re-joining would only risk tearing down a working link.
   */
  /**
   * 把 provision 写进 trace 的英文诊断行翻成一句用户能看懂的进展。
   *
   * 只做关键词映射，不解析内容：trace 是给 hilog 排障用的，措辞会随诊断需要
   * 变化，所以这里宁可粗一点，也不要因为某一行改了措辞就让进度提示卡住不动。
   * 顺序有讲究——「LSS characteristic」属于服务枚举，应落在「建立蓝牙连接」而
   * 不是「认证」，所以特征／MTU 的判断必须排在 LSS 前面。
   */
  /** 解析 `Nikon step N/M 描述` 并更新进度条；不是步骤标记就返回 false。
   *
   * 格式由 `NikonBleProvisioning.step()` 产出。刻意做成固定前缀 + 数字，界面不必
   * 解析技术日志——措辞随时可以改，进度条不会因此失灵。 */
  private nikonApplyStep(line: string): boolean {
    const prefix = 'Nikon step ';
    if (!line.startsWith(prefix)) {
      return false;
    }
    const rest = line.substring(prefix.length);
    const slash = rest.indexOf('/');
    const space = rest.indexOf(' ');
    if (slash <= 0 || space <= slash) {
      return false;
    }
    const index = Number.parseInt(rest.substring(0, slash), 10);
    const total = Number.parseInt(rest.substring(slash + 1, space), 10);
    if (Number.isNaN(index) || Number.isNaN(total) || total <= 0) {
      return false;
    }
    this.nikonStepIndex = index;
    this.nikonStepTotal = total;
    // 页面上的消息**不带"第 N/M 步"前缀**——步骤号和进度条只属于弹窗。同一条
    // 信息在两处各显示一遍，看起来像两个不同的进度（用户反馈过）。这里只留一句
    // 当前在做什么，够用即可。
    this.cam.cameraMessage = rest.substring(space + 1);
    this.nikonPairingMessage = this.cam.cameraMessage;
    // **写进 AppStorage**——弹窗通过 `@StorageLink` 读这三个键。`@Link`/`@Prop`
    // 都传不进去（原因见 NikonPairingProgressDialog 上的注释），这是进度条能动
    // 的唯一通路。
    AppStorage.setOrCreate('nikonPairStepIndex', index);
    AppStorage.setOrCreate('nikonPairStepTotal', total);
    AppStorage.setOrCreate('nikonPairStatus', this.nikonPairingMessage);
    return true;
  }

  private nikonProgressText(line: string): string {
    if (line.includes('pairing-only')) return '配对完成';
    // 收尾的系统级配对：相机给码、手机确认、相机再确认。这几条必须排在通用分支
    // 前面，否则会被"正在通过蓝牙与相机通信…"吞掉，用户在机身上比对码时看不到
    // 任何提示。
    if (line.includes('passkey from the camera')) return '相机给出了配对码，请在系统弹窗上确认（应用无权代确认）…';
    if (line.includes('confirmation must be done')) return '请在系统配对弹窗上确认，相机也在等你…';
    if (line.includes('pairing requested') || line.includes('pairDevice')) return '正在等待相机显示配对码…';
    if (line.includes('BTC bonded')) return '系统蓝牙配对已完成';
    if (line.includes('BTC')) return '正在完成系统蓝牙配对（相机可能要求确认）…';
    if (line.includes('0x2005')) return '正在通知相机完成配对…';
    if (line.includes('credential')) return '正在获取相机 Wi-Fi 凭据…';
    if (line.includes('indication') || line.includes('auth')) return '正在进行 LSS 认证…';
    if (line.includes('characteristic') || line.includes('MTU') || line.includes('connected') ||
      line.includes('services')) return '正在建立蓝牙连接…';
    if (line.includes('advertisement') || line.includes('scan')) return '正在扫描附近的尼康相机…';
    return '正在通过蓝牙与相机通信…';
  }

  /**
   * 尼康的 **USB 直连**路线（对应索尼线 `connectSonyUsb`）。
   *
   * 插着 USB 线时完全不需要蓝牙、不需要相机热点：PTP 会话直接在 USB 上开，
   * 之后把这条传输挂到 `NikonPtpIpService` 上，控制页与图片传输页的操作码/
   * 属性编码与 PTP/IP 完全一致（这点由 `PtpTransport` 保证，见 SonyUsbPtp）。
   *
   * 返回值表示「已经处理过」：true 时调用方不要再落到蓝牙配网那条十几秒的路径。
   * 没插线时返回 false，行为与改动前一致。
   */
  private async connectNikonViaUsb(): Promise<boolean> {
    let devices: Array<Readonly<usbManager.USBDevice>> = [];
    try {
      devices = NikonUsbPtp.listDevices();
    } catch (_error) {
      return false;
    }
    if (devices.length === 0) return false;
    AppLogStore.add(`nikon-usb 发现 ${devices.length} 台 USB 相机，优先走 USB`);
    this.cam.cameraBrand = 'Nikon';
    this.cam.cameraSessionStatus = 'USB 连接中';
    this.cam.cameraMessage = '检测到 USB 连接的尼康相机，正在建立 PTP 会话…';
    let probe: NikonUsbProbe;
    try {
      probe = await NikonUsbPtp.probe(devices[0]);
    } catch (error) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = `尼康 USB 连接异常：${(error as Error).message}`;
      return true;
    }
    AppLogStore.add(`nikon-usb probe ok=${probe.ok ? 'yes' : 'no'} model=${probe.model} ` +
      `open=${NikonUsbPtp.hex16(probe.openCode)} ops=${probe.operationsHex.length}`);
    if (!probe.ok) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = probe.message;
      try {
        this.getUIContext().getPromptAction().showDialog({
          title: '尼康 USB 连接未完成',
          message: probe.message,
          buttons: [{ text: '知道了', color: '#316CF4' }],
        }).catch(() => {
        });
      } catch (_dialogError) {
      }
      return true;
    }
    // 把 USB 传输挂上去：档位/EV/光圈/快门/录像/取景全部复用同一套尼康逻辑。
    NikonPtpIpService.attachTransport(NikonUsbPtp.transport());
    this.cam.cameraWifiStatus = 'USB 直连（无需 Wi‑Fi）';
    this.cam.cameraSessionStatus = '已连接';
    this.cam.cameraMessage = `已通过 USB 连接 ${probe.model.length > 0 ? probe.model : '尼康相机'}，`
      + '可直接使用相机控制与图片传输。';
    AppLogStore.add(`nikon-usb 会话已建立 model=${probe.model}`);
    return true;
  }

  private async connectNikonViaBleProvisioning(): Promise<void> {
    // **先看 USB。** 插着线就不该再走蓝牙配对 + 拉起热点那条十几秒的路。
    if (await this.connectNikonViaUsb()) {
      return;
    }
    try {
      hilog.info(0x0001, 'VIVID_PAIR', 'Nikon BLE provisioning entered');
    } catch (_error) {
    }
    this.cam.cameraMessage = '正在通过蓝牙为尼康相机配网…';
    this.cam.cameraSessionStatus = '蓝牙配网中';
    let context: common.UIAbilityContext | null = null;
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (_error) {
      context = null;
    }
    if (context === null) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = '无法取得应用上下文，尼康蓝牙配网未开始';
      return;
    }
    const trace: string[] = [];
    let outcome: NikonProvisionResult;
    // 配对要走扫描 → GATT → LSS 认证 → 读凭据 → 通知相机完成，前后十几秒。此前
    // 这段时间界面只有一句静止的「正在配网」，用户分不清"在跑"还是"卡死"，点完
    // 确认连接看起来像什么都没发生。provision 每一步都写进 trace，这里按时序把
    // 最新一行翻成中文镜像到消息区，同时把按钮区置为进行中。
    this.cam.cameraTransferInProgress = true;
    this.nikonStepIndex = 0;
    this.nikonStepTotal = 0;
    this.nikonPairingMessage = '正在通过蓝牙为尼康相机配网…';
    // 每次开始都把进度重置到 0，否则上一次的残值会先显示出来。
    AppStorage.setOrCreate('nikonPairStepIndex', 0);
    AppStorage.setOrCreate('nikonPairStepTotal', 0);
    AppStorage.setOrCreate('nikonPairStatus', this.nikonPairingMessage);
    // 清掉上一轮留下的配对码，避免这次还没收到就显示一个旧的数字。
    AppStorage.setOrCreate('nikonPairCode', '');
    // 「配对相机」按钮在进入等待阶段前不显示；点击计数清零，服务端只认"变了"。
    AppStorage.setOrCreate('nikonPairActionable', false);
    AppStorage.setOrCreate('nikonPairRequest', 0);
    // 弹窗从流程一开始就出现，全程显示步骤与进度条——只靠消息区一行小字时用户
    // 会以为卡死，这是用户明确反馈过的问题。
    //
    // 失败**必须打日志**：之前这里是个空 catch，弹窗没出来却查不到任何原因。
    try {
      this.nikonProgressDialog.open();
      this.nikonDialogOpen = true;
    } catch (dialogError) {
      try {
        hilog.error(0x0001, 'VIVID_PAIR',
          'Nikon progress dialog open failed: ' + (dialogError as Error).message);
      } catch (_logError) {
      }
    }
    const progressTimer = setInterval(() => {
      const latest = trace.length > 0 ? trace[trace.length - 1] : '';
      if (latest.length > 0) {
        // `Nikon step N/M 描述` 是服务端为进度条准备的固定格式：序号喂给进度条，
        // 描述直接当提示。剩下的技术日志仍走 nikonProgressText 的中文翻译。
        if (!this.nikonApplyStep(latest)) {
          const text = `尼康蓝牙配对：${this.nikonProgressText(latest)}`;
          this.cam.cameraMessage = text;
          this.nikonPairingMessage = text;
          AppStorage.setOrCreate('nikonPairStatus', text);
        }
        // 弹窗的关闭统一放在流程的 `finally` 里（见 connectNikonViaBleProvisioning），
        // 不在这里嗅探日志行——那样太脆弱，用户实测出现过"完成后窗口不退出"。
      }
    }, 400) as number;
    try {
      outcome = await NikonBleProvisioning.provision(context, trace, '', [], true);
    } catch (error) {
      outcome = {
        ok: false,
        stage: 'exception',
        message: `尼康蓝牙配网异常：${(error as Error).message}`,
        ssid: '',
        password: '',
        security: -1,
        gateway: '',
        ipAddress: '',
      };
    } finally {
      clearInterval(progressTimer);
      // **在流程真正结束时关弹窗**，而不是去嗅探日志里有没有 `pairing-only` 那一行。
      // 用户实测"完成后窗口不退出"，就是因为那种判断太脆弱——`provision` 明明返回
      // 了，最后一行却未必是那一句。这里是唯一的收口点，放这里一定关得掉。
      this.nikonPairingMessage = this.cam.cameraMessage;
      if (this.nikonDialogOpen) {
        try {
          this.nikonProgressDialog.close();
        } catch (closeError) {
          try {
            hilog.error(0x0001, 'VIVID_PAIR',
              'Nikon progress dialog close failed: ' + (closeError as Error).message);
          } catch (_logError) {
          }
        }
        this.nikonDialogOpen = false;
      }
      this.nikonStepIndex = 0;
      this.nikonStepTotal = 0;
      this.cam.cameraTransferInProgress = false;
    }
    for (const line of trace) AppLogStore.add(`nikon-provision ${line}`);
    AppLogStore.add(`nikon-provision stage=${outcome.stage} ok=${outcome.ok ? 'yes' : 'no'}`);
    // The pairing run takes the BLE scan away from the nearby-camera list (it
    // stops the shared scan and owns one of its own), which is why the camera
    // card used to disappear the instant 确认连接 was tapped. Hand discovery
    // back before reporting either outcome.
    try {
      this.startCameraBleDiscovery();
    } catch (error) {
      AppLogStore.add(`nikon-provision 恢复蓝牙发现失败: ${(error as Error).message}`);
    }
    if (!outcome.ok) {
      this.cam.cameraSessionStatus = '未建立';
      // Surface the stage that stalled and the last trace line. The platform
      // message alone ("Operation failed") does not say where it failed, and
      // the status line is the only thing the user can report back.
      const tail = trace.length > 0 ? trace[trace.length - 1] : '';
      const detail = tail.length > 96 ? `${tail.substring(0, 96)}…` : tail;
      // **给可操作的出路，但不给已被证伪的说法。**
      //
      // 这里原来写的是"请在手机和相机上同时删除配对记录，只清一侧无效"。真机
      // 实测推翻了它：用户在手机系统蓝牙里手动配对相机是**可以成功**的（Z 5 那次
      // 就是手动配对后接通）。所以真正有用的指引是"手动配对这条路能走"，而不是
      // 让用户去两个地方删记录。
      //
      // 配对段（stage=bond）失败时，`outcome.message` 已经说明了原因和做法，这里
      // 不再叠加第二套建议，避免两条指引互相打架。
      const hint = outcome.stage === 'bond'
        ? ''
        : '；若反复失败，可以在手机「设置 → 蓝牙」里手动配对这台相机，成功后回到这里重新连接';
      const where = detail.length > 0
        ? `（停在 ${outcome.stage}：${detail}）` : `（停在 ${outcome.stage}）`;
      this.cam.cameraMessage = `${outcome.message}${where}${hint}`;
      // **失败必须让用户看见。**
      //
      // 进度弹窗在 `finally` 里无条件关掉了（它没有取消按钮、`autoCancel` 也是
      // false，留着只会把用户卡住），于是一个失败的配对在界面上表现为"弹窗自己
      // 消失，什么都没发生"——用户完全不知道是配对没成，只会以为点漏了。
      //
      // 这里补一个可关闭的失败提示。`finally` 已经跑完、进度弹窗已关，所以不会
      // 两个弹窗叠在一起。
      try {
        this.getUIContext().getPromptAction().showDialog({
          title: '尼康相机配对未完成',
          message: this.cam.cameraMessage,
          buttons: [{ text: '知道了', color: '#316CF4' }],
        }).catch(() => {});
      } catch (_dialogError) {
      }
      return;
    }

    if (outcome.stage === 'paired') {
      // 确认连接 只完成蓝牙配对：拿到 Wi‑Fi 名称与密码即算成功，热点留到
      // 图片传输/相机控制 时再由 ensureNikonWifiForAction 通过蓝牙拉起。
      // 这里必须如实把 Wi‑Fi 标为未连接——配对完成不等于已入网。
      // cameraState 刻意保持 0（未建立会话）。置 2 会让主按钮变成「删除连接」
      // 并把其余按钮全部置灰——而配对成功并不等于会话已建立，相机此刻还只是
      // 待机。索尼线的收尾同样不动 cameraState。
      this.cam.cameraWifiSsid = outcome.ssid;
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraBleStatus = '已连接';
      this.cam.cameraBrand = 'Nikon';
      this.cam.cameraSessionStatus = '已配对';
      this.cam.cameraMessage = `尼康相机蓝牙配对完成，已取得 Wi-Fi「${outcome.ssid}」；`
        + '点「图片传输」或「相机控制」时会再通过蓝牙拉起相机热点。';
      AppLogStore.add(`nikon-provision 配对完成 ssid=${outcome.ssid}`);
      // 与索尼路线共用同一套收尾：写进 CameraCardRegistry（blePaired=true）。
      // 这一步不能省。实测：配对完成后相机会停止广播——释放 GATT 后扫描拿到
      // 1657 / 3846 个设备，尼康相机一个都没有——所以附近列表里再也找不到它，
      // 卡片就"消失"了。只有已注册卡片这条路能让它继续留在列表里。
      this.cameraBleCandidateBrand = 'Nikon';
      // 刻意不覆盖 imageKey：卡片示例图按机型 key 取（如 nikon_z5），发现阶段
      // 已经填好；覆盖成通用 'nikon' 会让卡片的示例图变成空白。
      const selectedBrand = this.selectedCameraCard().brand;
      if (selectedBrand !== 'Nikon') {
        // 配对期间扫描回调可能换过选中项；rememberCameraCard 取的是当前选中项，
        // 不切回去就会把另一台相机记成已配对。
        const cards = this.cameraCards.cards();
        let nikonCard: LumixBleCameraCandidate | null = null;
        for (const card of cards) {
          if (card.brand === 'Nikon') {
            nikonCard = card;
            break;
          }
        }
        if (nikonCard !== null) {
          AppLogStore.add('nikon-provision 当前选中项不是尼康相机，先切回再注册');
          this.applyCameraCandidate(nikonCard);
        }
      }
      await this.rememberCameraCard(true);
      AppLogStore.add('nikon-provision 已注册尼康相机卡片 blePaired=true');
      return;
    }

    this.cam.cameraWifiSsid = outcome.ssid;
    this.cam.cameraWifiStatus = '已连接';
    this.cam.cameraBrand = 'Nikon';
    this.cam.cameraImageKey = 'nikon';
    this.cam.cameraState = 2;
    this.cam.cameraSessionStatus = '认证中';
    let gateway = outcome.gateway;
    if (gateway.length === 0) gateway = await LumixCameraService.linkedGateway();
    this.cameraHost = gateway;
    if (gateway.length === 0) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = '尼康相机 Wi‑Fi 已连接，但未取得网关地址';
      return;
    }
    this.cam.cameraMessage = '尼康相机 Wi‑Fi 已连接，正在读取 PTP/IP 图库…';
    await this.runNikonPtpGallery(true);
  }

  /**
   * Report a Sony failure in a dialog.
   *
   * The status line cannot be used for this: the camera keeps advertising, so
   * the BLE discovery callback rewrites `cameraMessage` every scan interval and
   * any failure reason is erased within a few seconds. A dialog is not
   * overwritten, so the stage that stalled stays on screen until dismissed.
   *
   * `title` distinguishes the two Sony legs: pairing at 确认连接 and the
   * on-demand Wi-Fi raise from 「图片传输」/「索尼控制」.
   */
  /**
   * 索尼连接失败取证（只读）。返回一句给人看的结论，写不进日志的部分靠它。
   *
   * 顺序有讲究：CC0D 能力位必须在 GATT 还活着时读，所以先读 BLE，再跑网络探针
   * （SSDP 找相机真实地址、15740/22/8080 端口探测、GET dd.xml 看 X_SSH_Support
   * 与 X_PTP_PairingNecessity），期间每 500ms 采样状态标签统计「跳变」次数。
   *
   * 结论写进反馈日志的 `SONY_DIAG_REPORT` 一行，用户测一轮即可定位。
   */
  private async runSonyDiagnostics(stage: string): Promise<string> {
    if (SonyConnectionDiagnostics.isRunning()) return '';
    try {
      this.cam.cameraMessage = '正在采集诊断信息（约 20 秒）…';
      const caps = await SonyBleProvisioning.readCameraCapabilities([]);
      const context: SonyDiagContext = {
        host: this.cameraHost,
        expectedSsid: this.cam.cameraWifiSsid,
        stage: stage,
        bleStatus: this.cam.cameraBleStatus,
        wifiStatus: this.cam.cameraWifiStatus,
        sessionStatus: this.cam.cameraSessionStatus,
        bleCaps: caps,
      };
      const report = await SonyConnectionDiagnostics.run(context,
        (): string[] => [this.cam.cameraBleStatus, this.cam.cameraWifiStatus, this.cam.cameraSessionStatus]);
      return this.sonyDiagnosisHint(report);
    } catch (_error) {
      return '';
    }
  }

  /** 把探针结果翻成一句人话，让测试者不读日志也能准确描述现象。 */
  private sonyDiagnosisHint(report: SonyDiagReport): string {
    if (report.sshSupport !== 'absent' && report.sshSupport !== 'not-probed') {
      return '相机声明支持 SSH，PTP/IP 可能只走 22 端口隧道';
    }
    if (report.pairingNecessity === 'Necessary') {
      return '相机要求先做一次 Wi-Fi 配对';
    }
    if (report.ssidMatch === 'no') {
      return '当前 Wi-Fi 不是记录里的相机热点';
    }
    if (report.statusJumps > 4) {
      return `状态标签跳变 ${report.statusJumps} 次（显示层在抖）`;
    }
    return '诊断已写入日志，请在问题反馈里发送';
  }

  private showSonyFailure(stage: string, message: string, detail: string,
    title: string = '索尼相机配对未完成'): void {
    AppLogStore.add(`sony-provision failed stage=${stage} detail=${detail}`);
    const body = detail.length > 0
      ? `停放阶段：${stage}\n最后一步：${detail}`
      : `停放阶段：${stage}`;
    try {
      this.getUIContext().showAlertDialog({
        title: title,
        message: `${message}\n\n${body}`,
        autoCancel: true,
        alignment: DialogAlignment.Center,
        buttons: [
          {
            value: '运行诊断',
            action: (): void => {
              // 只读探针，失败也不影响提示本身，所以不 await。
              this.runSonyDiagnostics('manual').then((hint: string): void => {
                if (hint.length > 0) this.showMessage(hint);
              }).catch((): void => { });
            },
          },
          {
            value: '知道了',
            action: (): void => {
            },
          },
        ],
      });
    } catch (_error) {
      // Dialog unavailable (for example during teardown): a toast still beats
      // losing the reason entirely.
      this.showMessage(`${message}（${stage}）`);
    }
  }

  /**
   * 索尼「确认连接」：只建立蓝牙链路。
   *
   * 相机 Wi‑Fi 不在这里拉起——CC08 打开 Wi‑Fi、CC06/CC07 读取 SSID/密码、关联
   * 热点、进入内容传输模式全部推迟到用户点击「图片传输」或「索尼控制」时
   * （见 ensureSonyWifiForAction）。所以确认连接之后相机会保持待机，不会立刻
   * 向用户宣告开始导入图片。
   */
  private async connectSonyViaBleProvisioning(): Promise<void> {
    this.cam.cameraMessage = '正在通过蓝牙为索尼相机配对…';
    this.cam.cameraSessionStatus = '蓝牙配对中';
    this.cam.cameraTransferInProgress = true;
    // 配对握手十几秒，期间 500ms 扫描定时器与发现回调都可能重排相机卡片。
    // 先冻结这台相机的 BLE 身份，配对成功后按快照注册，避免把结果写进另一台
    // 相机（尼康路线同样是"配完就用当前选中项注册"，这里补上防错位）。
    const pairing: SonyPairingIdentity = {
      deviceId: this.cameraBleCandidateDeviceId,
      deviceName: this.cam.cameraBleCandidateName,
      model: this.cam.cameraBleCandidateModel,
      imageKey: this.cameraBleCandidateImageKey,
      btAddress: this.cameraBleCandidateBtAddress,
    };
    const trace: string[] = [];
    let outcome: SonyProvisionResult;
    try {
      outcome = await SonyBleProvisioning.pairOnly(trace, this.cameraBleCandidateDeviceId);
    } catch (error) {
      outcome = {
        ok: false,
        stage: 'exception',
        message: `索尼蓝牙配对异常：${(error as Error).message}`,
        ssid: '',
        password: '',
        bssid: '',
        gateway: '',
        ipAddress: '',
        model: '',
        firmware: '',
      };
    } finally {
      this.cam.cameraTransferInProgress = false;
    }
    for (const line of trace) AppLogStore.add(`sony-pair ${line}`);
    AppLogStore.add(`sony-pair stage=${outcome.stage} ok=${outcome.ok ? 'yes' : 'no'}`);

    // A discovered identity is worth keeping even when pairing failed: the user
    // can retry, or fall back to the PC Remote AP, without another scan.
    if (outcome.model.length > 0) {
      this.cam.cameraBleCandidateModel = outcome.model;
      this.cam.cameraModel = outcome.model;
      const imageKey = SonyCameraService.imageKeyForModel(outcome.model);
      if (imageKey.length > 0) {
        this.cameraBleCandidateImageKey = imageKey;
        this.cam.cameraImageKey = imageKey;
      }
    }
    if (!outcome.ok) {
      this.cam.cameraSessionStatus = '未建立';
      // Surface the stage and the last trace line on screen, so the failure
      // reports where it stopped instead of only saying that it did.
      const tail = trace.length > 0 ? trace[trace.length - 1] : '';
      const detail = tail.length > 96 ? `${tail.substring(0, 96)}…` : tail;
      this.cam.cameraMessage = detail.length > 0
        ? `${outcome.message}（停在 ${outcome.stage}：${detail}）`
        : `${outcome.message}（停在 ${outcome.stage}）`;
      // A failed attempt must not leave the card looking already-registered:
      // cameraState 2 makes 确认连接 skip the pairing hint entirely, which is
      // exactly why a second tap appeared to do nothing. Drop back to the
      // unpaired state so pairing can be retried straight away.
      this.cam.cameraState = 0;
      this.cameraPairingAttempted = false;
      // The camera keeps advertising, so the discovery callback keeps rewriting
      // the status line and this reason would be wiped within a few seconds -
      // which is exactly why the screen appeared to fall back to "newly
      // discovered" with no explanation. Report it in a dialog instead.
      this.showSonyFailure(outcome.stage, outcome.message, detail);
      return;
    }

    // ---- Bluetooth is up. Wi-Fi is deliberately left down here: the body must
    // not be told to start importing until the user asks for transfer/control.
    this.cam.cameraBleStatus = '已连接';
    this.cam.cameraBrand = 'Sony';
    this.cameraBleCandidateBrand = 'Sony';
    this.cameraPairingAttempted = true;
    this.cam.cameraState = 2;
    this.cam.cameraWifiStatus = '未连接';
    this.cam.cameraWifiSsid = '';
    this.cam.cameraSessionStatus = '已配对';
    this.cameraHost = '';
    this.cam.cameraMessage = '索尼相机蓝牙配对完成；点击「图片传输」或「索尼控制」时才会连接相机 Wi‑Fi';
    AppLogStore.add('sony-pair 蓝牙配对完成，Wi‑Fi 留待「图片传输」/「索尼控制」按需拉起');
    // ---- 配对成功即入库（与尼康 connectNikonViaBleProvisioning 的收尾一致）。
    // 这里以前只改内存里的 UI 状态、从不写 CameraCardRegistry，所以重启后索尼
    // 相机就从相机列表里消失了。blePaired=true：蓝牙链路确实已经建立。
    await this.rememberSonyCameraAfterPairing(pairing);
  }

  /**
   * 索尼「确认连接」配对成功后，把相机写进 CameraCardRegistry 并设为当前卡片。
   *
   * 与尼康路线共用同一套收尾：rememberCameraCard(true) 负责持久化（blePaired
   * = true）+ 选中 + 刷新列表。配对期间扫描回调可能换过选择，所以身份取自配对
   * 前冻结的 {@link SonyPairingIdentity}；若当前选中项已经不是这台相机，先
   * applyCameraCandidate() 切回去，否则 rememberCameraCard() 会保存成另一台。
   */
  private async rememberSonyCameraAfterPairing(pairing: SonyPairingIdentity): Promise<void> {
    const name = pairing.deviceName.length > 0
      ? pairing.deviceName
      : (this.cam.cameraBleCandidateModel.length > 0 ? this.cam.cameraBleCandidateModel : this.cam.cameraModel);
    if (name.length === 0) {
      // 没有名字 remember() / upsert() 只会跳过，这里说明原因而不是静默失败。
      AppLogStore.add('sony-pair 配对成功但未取得相机名称，跳过注册');
      return;
    }
    const model = pairing.model.length > 0
      ? pairing.model
      : (this.cam.cameraBleCandidateModel.length > 0 ? this.cam.cameraBleCandidateModel : this.cam.cameraModel);
    let imageKey = pairing.imageKey.length > 0 ? pairing.imageKey : this.cameraBleCandidateImageKey;
    if (imageKey.length === 0) imageKey = this.cameraImageKeyForName(`${model} ${name}`);
    const sony: LumixBleCameraCandidate = {
      deviceId: pairing.deviceId,
      deviceName: name,
      model: model,
      imageKey: imageKey,
      brand: 'Sony',
      rssi: 0,
      connectable: true,
      btAddress: pairing.btAddress,
    };
    this.cam.cameraBrand = 'Sony';
    this.cameraBleCandidateBrand = 'Sony';
    if (imageKey.length > 0) {
      this.cameraBleCandidateImageKey = imageKey;
      this.cam.cameraImageKey = imageKey;
    }
    if (model.length > 0) this.cam.cameraModel = model;
    if (this.cameraCandidateKey(this.selectedCameraCard()) !== this.cameraCandidateKey(sony)) {
      AppLogStore.add(`sony-pair 当前选中项不是 ${name}，先切回该相机再注册`);
      this.applyCameraCandidate(sony);
    }
    await this.rememberCameraCard(true);
    AppLogStore.add(`sony-pair 已在相机列表注册 ${name}（blePaired=true）`);
  }

  /**
   * 按需拉起索尼相机 Wi‑Fi：只有用户点「图片传输」或「索尼控制」时才调用。
   *
   * 蓝牙侧在「确认连接」时已经配对完成，这里只做 Wi‑Fi 那一段——重新连上
   * GATT、写入打开 Wi‑Fi 的指令、读取相机下发的 SSID/密码并关联热点。
   * SonyBleProvisioning.startWifi 自身幂等：手机已在相机热点上时立即成功，
   * 不会重复走蓝牙。失败时用索尼失败弹窗报告并返回 false，调用方据此不再
   * 进入枚举/控制步骤。
   */
  private async ensureSonyWifiForAction(purpose: string): Promise<boolean> {
    // USB 会话已建立时不需要相机 Wi‑Fi：图像数据走 USB bulk 管道。
    if (SonyPtpIpContent.isUsbSession()) {
      AppLogStore.add(`sony-usb 已建立 USB 会话，跳过 Wi‑Fi（${purpose}）`);
      return true;
    }
    // 已经在相机热点上（例如手动接入 PC 远程热点）时无需再动蓝牙。
    if (this.cameraWifiConnected() && this.cameraHost.length > 0) {
      AppLogStore.add(`sony-wifi 已在相机 Wi‑Fi 上，跳过拉起（${purpose}）`);
      return true;
    }
    if (this.sonyWifiRaiseInFlight) {
      this.cam.cameraMessage = '正在通过蓝牙获取相机 Wi‑Fi 并连接…';
      AppLogStore.add(`sony-wifi 拉起已在进行中（${purpose}）`);
      return false;
    }
    this.sonyWifiRaiseInFlight = true;
    this.cam.cameraTransferInProgress = true;
    this.cam.cameraSessionStatus = '蓝牙配网中';
    // 这一段要走蓝牙 + 系统 Wi‑Fi 关联，可能十几秒：必须让用户看到进度。
    this.cam.cameraMessage = '正在通过蓝牙获取相机 Wi‑Fi 并连接…';
    AppLogStore.add(`sony-wifi 拉起相机 Wi‑Fi（${purpose}）`);
    const trace: string[] = [];
    let outcome: SonyProvisionResult;
    try {
      outcome = await SonyBleProvisioning.startWifi(trace, this.cameraBleCandidateDeviceId);
    } catch (error) {
      outcome = {
        ok: false,
        stage: 'exception',
        message: `索尼相机 Wi‑Fi 连接异常：${(error as Error).message}`,
        ssid: '',
        password: '',
        bssid: '',
        gateway: '',
        ipAddress: '',
        model: '',
        firmware: '',
      };
    } finally {
      this.sonyWifiRaiseInFlight = false;
      this.cam.cameraTransferInProgress = false;
    }
    for (const line of trace) AppLogStore.add(`sony-wifi ${line}`);
    AppLogStore.add(`sony-wifi stage=${outcome.stage} ok=${outcome.ok ? 'yes' : 'no'}`);

    if (!outcome.ok) {
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '已配对';
      const tail = trace.length > 0 ? trace[trace.length - 1] : '';
      const detail = tail.length > 96 ? `${tail.substring(0, 96)}…` : tail;
      this.cam.cameraMessage = detail.length > 0
        ? `${outcome.message}（停在 ${outcome.stage}：${detail}）`
        : `${outcome.message}（停在 ${outcome.stage}）`;
      // 「确认连接」时配对已经成功，所以这里不是配对失败：标题要说明是
      // 按需拉起 Wi‑Fi 失败，否则用户会以为自己要重新配对。
      this.showSonyFailure(outcome.stage, outcome.message, detail, '索尼相机 Wi‑Fi 连接未完成');
      return false;
    }

    this.cam.cameraWifiSsid = outcome.ssid;
    this.cam.cameraWifiStatus = '已连接';
    this.cam.cameraBleStatus = '已连接';
    this.cam.cameraBrand = 'Sony';
    this.cameraBleCandidateBrand = 'Sony';
    this.cameraPairingAttempted = true;
    this.cam.cameraState = 2;
    this.cam.cameraSessionStatus = '未建立';
    let gateway = outcome.gateway;
    if (gateway.length === 0) {
      // Reached from a floating (un-awaited) call, so a rejection here would be
      // unhandled and could abort the app.
      try {
        gateway = await LumixCameraService.linkedGateway();
      } catch (error) {
        AppLogStore.add(`sony-wifi gateway lookup failed: ${String(error)}`);
        gateway = '';
      }
    }
    this.cameraHost = gateway;
    if (gateway.length === 0) {
      this.cam.cameraMessage = '索尼相机 Wi‑Fi 已连接，但未取得网关地址';
      this.showSonyFailure('wifi-gateway', '索尼相机 Wi‑Fi 已连接，但未取得网关地址', '',
        '索尼相机 Wi‑Fi 连接未完成');
      return false;
    }
    AppLogStore.add(`sony-wifi gateway=${gateway}，继续 ${purpose}`);
    return true;
  }

  /**
   * 尼康按需拉起 Wi‑Fi：与索尼线同构，但尼康没有「只配对蓝牙」这一步——
   * `NikonBleProvisioning.provision` 一次走完 扫描 → GATT → LSS 认证 → 读取
   * Wi‑Fi 凭据 → 关联热点，所以这里直接复用整条配网流程，成功即已在相机热点上。
   *
   * 因为 `provision` 不幂等（会重新走一遍蓝牙，十几秒），先用「已在相机热点上」
   * 短路，避免用户每次进控制页/图片传输页都重跑一遍配网。
   *
   * 从不 reject：入口是浮动的 onClick 调用，未处理的 rejection 会中止应用。
   */
  private async ensureNikonWifiForAction(purpose: string): Promise<boolean> {
    // **USB 一线通就不碰 Wi‑Fi。** 插着线的时候相机热点和蓝牙凭据都不需要：
    // `NikonPtpIpService` 的控制/图传操作已经挂在 USB 传输上（见 attachTransport）。
    if (NikonUsbPtp.isOpen()) {
      AppLogStore.add(`nikon-usb 已连接，跳过 Wi‑Fi 拉起（${purpose}）`);
      return true;
    }    // 已经在相机热点上时无需再动蓝牙。
    if (this.cameraWifiConnected()) {
      if (this.cameraHost.length > 0) {
        AppLogStore.add(`nikon-wifi 已在相机 Wi‑Fi 上，跳过拉起（${purpose}）`);
        return true;
      }
      // 已在相机热点上但没记住网关（cameraHost 是 @State，应用重启后不保留）：
      // 取一次系统网关就够，不必为此重跑十几秒的蓝牙配网。
      try {
        const linked = await LumixCameraService.linkedGateway();
        if (linked.length > 0) {
          this.cameraHost = linked;
          AppLogStore.add(`nikon-wifi 已在相机 Wi‑Fi 上，网关=${linked}（${purpose}）`);
          return true;
        }
      } catch (error) {
        AppLogStore.add(`nikon-wifi gateway lookup failed: ${String(error)}`);
      }
    }
    if (this.nikonWifiRaiseInFlight) {
      this.cam.cameraMessage = '正在通过蓝牙获取相机 Wi‑Fi 并连接…';
      AppLogStore.add(`nikon-wifi 拉起已在进行中（${purpose}）`);
      return false;
    }
    let context: common.UIAbilityContext | null = null;
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (_error) {
      context = null;
    }
    if (context === null) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = '无法取得应用上下文，尼康相机 Wi‑Fi 未拉起';
      return false;
    }
    this.nikonWifiRaiseInFlight = true;
    this.cam.cameraTransferInProgress = true;
    this.cam.cameraSessionStatus = '蓝牙配网中';
    // 这一段要走蓝牙 + 系统 Wi‑Fi 关联，可能十几秒：必须让用户看到进度。
    this.cam.cameraMessage = '正在通过蓝牙获取相机 Wi‑Fi 并连接…';
    AppLogStore.add(`nikon-wifi 拉起相机 Wi‑Fi（${purpose}）`);
    const trace: string[] = [];
    let outcome: NikonProvisionResult;
    try {
      // **`startWifi` 而不是 `provision`。** 配对已经在「确认连接」时做完了，这里
      // 只需要拉起热点并关联。`provision` 会把整段配对再跑一遍（40 秒以上），
      // 而且实测卡在经典搜索上，后面的 Wi-Fi 关联根本执行不到——用户看到的就是
      // "又配对了一次，却没连 Wi-Fi"。这也正是索尼那条线的形状
      // （`SonyBleProvisioning.startWifi`）。
      outcome = await NikonBleProvisioning.startWifi(context, trace);
    } catch (error) {
      // **把异常打进日志。** 之前这里只把它写进 `cameraMessage`，屏幕一闪就没了，
      // 用户复述不出原文（实测就发生了）。现在它同时落到 AppLogStore 和 hilog，
      // 下次直接从日志里读原因，不用靠用户回忆。
      const wifiErrorDetail = String(error);
      AppLogStore.add(`nikon-wifi EXCEPTION ${wifiErrorDetail}`);
      try {
        hilog.error(0x0001, 'VIVID_PAIR', 'nikon-wifi EXCEPTION ' + wifiErrorDetail);
      } catch (_logError) {
      }
      outcome = {
        ok: false,
        stage: 'exception',
        message: `尼康相机 Wi‑Fi 连接异常：${(error as Error).message}`,
        ssid: '',
        password: '',
        security: -1,
        gateway: '',
        ipAddress: '',
      };
    } finally {
      this.nikonWifiRaiseInFlight = false;
      this.cam.cameraTransferInProgress = false;
    }
    // **陈旧配对密钥自愈：双方都留着配对记录时，只能重新走一遍握手。**
    //
    // 实测：手机侧和相机侧**都**有配对记录时，BLE 链路能连上、CCCD 能订阅成功，
    // 但相机**拒绝接受 LSS 写入**——`0x2002`（客户端名）和 `0x2000`（认证）都返回
    // `2900099`，认证因此根本开始不了。用户点图片传输看到的就是**立刻报错**
    // （`尼康蓝牙配网异常：GATT characteristic write failed（阶段 auth）`）。
    //
    // 判断：链路上带着一份两边已经不一致的陈旧配对密钥。用户已确认这个判断，并
    // 指出"两边都没清理时，相机侧和手机侧需要重新走一遍握手获取 Wi-Fi 和密码"。
    //
    // 所以这里做一次自愈：认证阶段失败就先跑完整配对，让系统在**轮换过的 BLE 广播
    // 地址**上把密钥重新谈一遍（`bondWithPasskey` 做的正是这件事），然后再试一次
    // 拉起 Wi-Fi。**只重试一次**，避免失败时反复弹配对码。
    // **把判定依据无条件打出来。**
    //
    // 自愈加了之后实测没有触发，而日志里只能看到 `nikon-trace Nikon exception
    // stage=auth`（那是 provision 内部打的），看不到 `ensureNikonWifiForAction`
    // 这边拿到的 `outcome` 到底是什么。两者可能不一致，所以这里把
    // `ok` / `stage` / `message` 原样记下来，并且**同时走 hilog**——之前自愈的
    // 日志走 AppLogStore，实测在 hilog 里找不到，无法确认它有没有跑。
    AppLogStore.add(`nikon-wifi outcome ok=${outcome.ok} stage=${outcome.stage}`
      + ` message=${outcome.message}`);
    try {
      hilog.error(0x0001, 'VIVID_PAIR',
        'nikon-wifi outcome ok=' + outcome.ok + ' stage=' + outcome.stage);
    } catch (_logError) {
    }
    if (!outcome.ok && outcome.stage === 'auth') {
      AppLogStore.add('nikon-wifi 认证阶段失败（陈旧配对密钥），先重新握手再重试一次');
      try {
        hilog.error(0x0001, 'VIVID_PAIR', 'nikon-repair START (stale key)');
      } catch (_logError) {
      }
      this.cam.cameraMessage = '配对记录已失效，正在重新与相机握手…';
      this.cam.cameraTransferInProgress = true;
      try {
        const repairTrace: string[] = [];
        const repair = await NikonBleProvisioning.provision(context, repairTrace, '', [], true);
        for (const line of repairTrace) AppLogStore.add(`nikon-repair ${line}`);
        AppLogStore.add(`nikon-repair 重新握手结果 ok=${repair.ok} stage=${repair.stage}`);
        try {
          hilog.error(0x0001, 'VIVID_PAIR',
            'nikon-repair DONE ok=' + repair.ok + ' stage=' + repair.stage);
        } catch (_logError) {
        }
        if (repair.ok) {
          const retriedTrace: string[] = [];
          const retried = await NikonBleProvisioning.startWifi(context, retriedTrace);
          for (const line of retriedTrace) AppLogStore.add(`nikon-wifi-retry ${line}`);
          AppLogStore.add(`nikon-wifi-retry 结果 ok=${retried.ok} stage=${retried.stage}`);
          try {
            hilog.error(0x0001, 'VIVID_PAIR',
              'nikon-wifi-retry ok=' + retried.ok + ' stage=' + retried.stage);
          } catch (_logError) {
          }
          outcome = retried;
        }
        // **重新握手也没用的话，就是系统绑定层的陈旧密钥，必须用户手动清。**
        //
        // 实测：认证阶段失败 → 自愈跑完整配对 → 仍然失败在认证，而且只用了 2.6 秒
        // （`bondWithPasskey` 光开头的 3 秒延时都不到），说明它根本没走到配对那一步。
        // 相机在这条链路上**拒绝一切写入**（0x2002 和 0x2000 都是 2900099），
        // LSS 会话开不了头。
        //
        // 原因：两边都存着绑定，但相机在"相机侧删除后重新注册"那一轮换过密钥，
        // 手机手里还是旧的 → 手机按旧密钥加密 → 相机对不上 → 拒收所有写入。
        // 而 `pairDevice` 对**已绑定**的设备会直接返回，系统认为"已经配过了"，
        // **不会重新协商密钥**——所以 App 层面无解。
        //
        // 鸿蒙没有给第三方 App 解除配对的 API（`removePairedDevice` 不存在，已实测），
        // 所以只能明确让用户去系统里删。**这句话必须同时说"两侧都要清"**：
        // 只清手机侧，相机的旧记录还在，重新配对时会再次错位。
        if (!outcome.ok && outcome.stage === 'auth') {
          outcome.message = '相机与手机的配对密钥已不一致（相机在重新注册时换过密钥，'
            + '手机手里还是旧的），因此相机拒绝本次蓝牙会话，也无法自动修复。'
            + '请在手机「设置 → 蓝牙」中删除 Z_5_8073573（本相机），'
            + '并同时在相机上删除本手机的配对记录，然后重新点「确认连接」。'
            + '只清一侧无效。';
          AppLogStore.add('nikon-wifi 判定为系统绑定层陈旧密钥，已给出可操作提示');
        }
      } catch (repairError) {
        AppLogStore.add(`nikon-repair EXCEPTION ${String(repairError)}`);
      } finally {
        this.cam.cameraTransferInProgress = false;
      }
    }
    for (const line of trace) AppLogStore.add(`nikon-wifi ${line}`);
    AppLogStore.add(`nikon-wifi stage=${outcome.stage} ok=${outcome.ok ? 'yes' : 'no'}`);

    if (!outcome.ok) {
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '已配对';
      const tail = trace.length > 0 ? trace[trace.length - 1] : '';
      const detail = tail.length > 96 ? `${tail.substring(0, 96)}…` : tail;
      this.cam.cameraMessage = detail.length > 0
        ? `${outcome.message}（停在 ${outcome.stage}：${detail}）`
        : `${outcome.message}（停在 ${outcome.stage}）`;
      return false;
    }

    this.cam.cameraWifiSsid = outcome.ssid;
    this.cam.cameraWifiStatus = '已连接';
    this.cam.cameraBleStatus = '已连接';
    this.cam.cameraBrand = 'Nikon';
    this.cam.cameraImageKey = 'nikon';
    this.cam.cameraState = 2;
    this.cam.cameraSessionStatus = '未建立';
    let gateway = outcome.gateway;
    if (gateway.length === 0) {
      try {
        gateway = await LumixCameraService.linkedGateway();
      } catch (error) {
        AppLogStore.add(`nikon-wifi gateway lookup failed: ${String(error)}`);
        gateway = '';
      }
    }
    this.cameraHost = gateway;
    if (gateway.length === 0) {
      this.cam.cameraMessage = '尼康相机 Wi‑Fi 已连接，但未取得网关地址';
      return false;
    }
    AppLogStore.add(`nikon-wifi gateway=${gateway}，继续 ${purpose}`);
    return true;
  }

  /**
   * 索尼「图片传输」：先按需拉起相机 Wi‑Fi，成功后才建立 PTP/IP 会话并枚举
   * 相机内容，最后进入图片传输页。Wi‑Fi 拉起失败则只报告失败，不再往下走。
   *
   * 从不 reject：入口是浮动的 onClick 调用，未处理的 rejection 会中止应用。
   */
  private async openSonyImageTransfer(): Promise<void> {
    if (this.cam.cameraTransferInProgress) return;
    // 没有 Wi‑Fi、但插着 USB：走 USB 通道，成功后回到这里进图片传输页。
    // 已经有一个「只建了控制通道」的 USB 会话时也要重走一遍：那条会话没进
    // 内容枚举模式，直接拿去列文件会在 0x923B 上失败。
    const usbNeedsBrowse = SonyPtpIpContent.isUsbSession()
      ? SonyPtpIpContent.isControlOnlySession()
      : SonyUsbPtp.hasDevice();
    if (this.cam.cameraBrand === 'Sony' && !this.cameraWifiConnected() && usbNeedsBrowse) {
      AppLogStore.add('ui 打开图片传输页（Sony，USB）');
      await this.connectSonyUsb(SonyUsbPtp.MODE_CONTENTS_TRANSFER);
      return;
    }
    AppLogStore.add('ui 打开图片传输页（Sony）');
    this.cam.syncPullActive = false;
    this.registerCameraSessionDriver();
    try {
      const wifiReady = await this.ensureSonyWifiForAction('图片传输');
      if (!wifiReady) return;
      this.cam.cameraMessage = SonyPtpIpContent.isUsbSession()
        ? '相机 USB 已连接，正在读取图库…'
        : '索尼相机 Wi‑Fi 已连接，正在读取 PTP/IP 图库…';
      await this.runNikonPtpGallery(true);
    } catch (error) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = `索尼相机图库读取失败：${(error as Error).message}`;
      AppLogStore.add(`sony-wifi gallery failed: ${String(error)}`);
    }
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/SonyImageTransferPage' });
    } catch (error) {
      AppLogStore.add(`sony-wifi 打开图片传输页失败: ${String(error)}`);
    }
  }

  /**
   * 尼康「图片传输」：只负责注册 driver 并进入共享的图片传输页，真正的取图交给
   * 页面的 startImageTransfer 回调（startImageTransferFromPage 的尼康分支）。
   *
   * 这样「首次进入」与「冷启动重建」走同一条路径，而不是在导航前先取一遍、进了
   * 页面再取一遍。图片传输页本身对品牌中立：它只渲染 store 并通过 driver 回调
   * 触发动作，所以尼康线与松下 Lab 线共用同一套页面。
   */
  private openNikonImageTransfer(): void {
    AppLogStore.add('ui 打开图片传输页（Nikon）');
    this.cam.syncPullActive = false;
    this.registerCameraSessionDriver();
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/NikonImageTransferPage' });
    } catch (error) {
      AppLogStore.add(`nikon 打开图片传输页失败: ${String(error)}`);
    }
  }

  // -------------------------------------------------------------------------
  // 富士线入口（图片传输 / 相机控制 / WIFI 连接 / 固件更新）
  // -------------------------------------------------------------------------

  /** 富士线是否有可操作的目标：刚扫描命中，或卡片本身就是富士机型。 */
  private fujifilmTargetReady(): boolean {
    return this.fujifilmCamera !== null || FujifilmModels.isFujifilmImageKey(this.cam.cameraImageKey);
  }

  /**
   * 由卡片/会话字段还原一台富士机身。
   *
   * 应用重启或扫描停掉后 `fujifilmCamera` 为空，但卡片还在；这时用 deviceId
   * 仍可重建 GATT 链路。代价是**拿不到广播里的 pairing key**：`pair()` 会返回
   * false（已记录日志），随后照常读凭据——`01 §7.3` 说明 key 以首次配对为准，
   * 已配对的机身不需要重写。
   */
  private fujifilmCameraFromCard(): FujifilmBleCamera | null {
    const deviceId = this.cameraBleCandidateDeviceId;
    if (deviceId.length === 0) return null;
    const model = this.cam.cameraModel.length > 0 ? this.cam.cameraModel
      : this.cam.cameraBleCandidateModel;
    return {
      deviceId: deviceId,
      name: this.cam.cameraBleCandidateName,
      serial: '',
      model: model,
      red: this.fujifilmCamera !== null ? this.fujifilmCamera.red : false,
      rssi: 0,
    };
  }

  /**
   * 富士入口总闸（ROUTE_SPEC §3.4）：先按需拉起相机 Wi‑Fi，成功后再进对应页面。
   *
   *  - 图片传输 → `launch(3)` → `waitApReady` → 连相机 Wi‑Fi → 图片传输页
   *  - 相机控制 → `launch(4)` → 同上 → 控制页
   *  - WIFI 连接 → 只做「拉起 + 关联」，留在本页
   *
   * 从不 reject：入口是 onClick 调用，未处理的 rejection 会中止应用。
   */
  private async openFujifilmEntry(purpose: string): Promise<void> {
    const label = purpose === 'control' ? '相机控制' : (purpose === 'wifi' ? 'WIFI 连接' : '图片传输');
    AppLogStore.add(`[FUJI] 打开${label}`);
    if (this.fujifilmWifiRaiseInFlight) {
      this.cam.cameraMessage = '正在建立与相机的 Wi‑Fi 链路，请稍候…';
      return;
    }
    try {
      const ready = await this.ensureFujifilmWifi(label, purpose);
      if (!ready) return;
      if (purpose === 'wifi') {
        this.cam.cameraMessage = '富士相机 Wi‑Fi 已连接，可继续图片传输或相机控制';
        return;
      }
      this.cam.syncPullActive = false;
      this.registerCameraSessionDriver();
      const url = purpose === 'control'
        ? 'pages/FujifilmCameraControlPage' : 'pages/FujifilmImageTransferPage';
      this.getUIContext().getRouter().pushUrl({ url: url });
      AppLogStore.add(`[FUJI] 已进入 ${url}`);
    } catch (error) {
      this.cam.cameraMessage = `富士相机连接失败：${(error as Error).message}`;
      AppLogStore.add(`[FUJI] 入口异常: ${String(error)}`);
    }
  }

  /** 富士「固件更新」：只登记路由直接进页面（版本/清单由固件服务自己取）。 */
  private openFujifilmFirmware(): void {
    AppLogStore.add('[FUJI] 打开固件更新页');
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/FujifilmFirmwarePage' });
    } catch (error) {
      AppLogStore.add(`[FUJI] 打开固件更新页失败: ${String(error)}`);
    }
  }

  /**
   * 富士：拉起相机 AP 并关联（`01 §9`）。
   *
   *  1. GATT 连接（幂等）+ 回写广播里的 pairing key —— 没有 PIN/绑定/加密（§7.5）；
   *  2. 现场读 SSID/密码；密码读失败立即断开（§8.4），密码不落库；
   *  3. 写功能启动 3/4/5，等 `AP_STATE = 0x8001`（§9.2/§9.4）；
   *  4. 用系统候选配置关联热点（复用松下已验证的关联/密码策略）。
   */
  private async ensureFujifilmWifi(label: string, purpose: string): Promise<boolean> {
    if (this.cameraWifiConnected() && this.cam.cameraWifiSsid.length > 0) {
      if (this.cameraHost.length === 0) {
        try {
          this.cameraHost = await LumixCameraService.linkedGateway();
        } catch (_error) {
          this.cameraHost = '';
        }
      }
      AppLogStore.add(`[FUJI] 已在相机 Wi‑Fi 上（${label}）`);
      return this.cameraHost.length > 0;
    }
    const camera = this.fujifilmCamera !== null ? this.fujifilmCamera : this.fujifilmCameraFromCard();
    if (camera === null) {
      this.cam.cameraMessage = '没有可用的富士相机，请回到相机页重新扫描';
      AppLogStore.add('[FUJI] 拉起失败：没有扫描命中的机身');
      return false;
    }
    this.fujifilmWifiRaiseInFlight = true;
    this.cam.cameraTransferInProgress = true;
    this.cam.cameraSessionStatus = '蓝牙配网中';
    this.cam.cameraMessage = '正在通过蓝牙拉起相机 Wi‑Fi…';
    try {
      if (!FujifilmBleService.isConnected()) {
        const linked = await FujifilmBleService.connect(camera.deviceId);
        if (!linked) {
          this.cam.cameraMessage = '富士相机蓝牙连接失败，请靠近相机后重试';
          this.cam.cameraSessionStatus = '未建立';
          return false;
        }
      }
      // 配对失败也不阻断：部分固件对已配对的机身会拒绝再次写入 key，
      // 但凭据照样读得到（`01 §7.3`：key 以首次配对为准）。
      const paired = await FujifilmBleService.pair(camera);
      if (!paired) AppLogStore.add('[FUJI] 配对 key 回写未成功，继续读凭据');
      this.cam.cameraBleStatus = '已连接';

      const credential: FujifilmWifiCredential = await FujifilmBleService.readWifiCredentials();
      this.cam.cameraWifiSsid = credential.ssid;
      const kind = purpose === 'control'
        ? FujifilmBleIds.LAUNCH_REMOTE_SHOOTING : FujifilmBleIds.LAUNCH_IN_CAMERA_VIEWING;
      const launched = await FujifilmBleService.launch(kind);
      if (!launched) {
        this.cam.cameraMessage = '富士相机未接受功能启动请求，请重试';
        return false;
      }
      this.cam.cameraMessage = '相机正在启动热点，等待 AP 就绪…';
      const apReady = await FujifilmBleService.waitApReady(FUJIFILM_AP_READY_TIMEOUT_MS);
      if (!apReady) {
        this.cam.cameraMessage = '等待相机热点超时，请确认相机未休眠后重试';
        return false;
      }
      return await this.joinFujifilmWifi(credential);
    } catch (error) {
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = `富士相机 Wi‑Fi 拉起失败：${(error as Error).message}`;
      AppLogStore.add(`[FUJI] 拉起失败: ${String(error)}`);
      return false;
    } finally {
      this.fujifilmWifiRaiseInFlight = false;
      this.cam.cameraTransferInProgress = false;
    }
  }

  /** 用 BLE 读到的 SSID/密码关联相机热点（与松下共用同一套关联实现）。 */
  private async joinFujifilmWifi(credential: FujifilmWifiCredential): Promise<boolean> {
    const candidate: LumixWifiCandidate = {
      ssid: credential.ssid,
      bssid: '',
      rssi: 0,
      // `01 §9.6`：相机 AP 是 WPA2-PSK；HarmonyOS 的 PSK = 3。
      securityType: 3,
      model: this.cam.cameraModel,
      family: 'X 系列',
      imageKey: this.cam.cameraImageKey,
      brand: FUJIFILM_BRAND,
    };
    this.cam.cameraMessage = `正在连接相机 Wi‑Fi（${credential.ssid}）…`;
    const result = await LumixCameraService.connectToCameraWifi(candidate, true,
      { password: credential.passphrase });
    if (!result.connected) {
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraMessage = result.message;
      AppLogStore.add(`[FUJI] 关联失败: ${result.message}`);
      return false;
    }
    this.cam.cameraWifiSsid = result.ssid.length > 0 ? result.ssid : credential.ssid;
    this.cam.cameraWifiStatus = '已连接';
    this.cam.cameraBleStatus = '已连接';
    this.cam.cameraBrand = FUJIFILM_BRAND;
    this.cam.cameraState = 2;
    this.cam.cameraSessionStatus = '未建立';
    this.cameraWifiCloseRequested = false;
    try {
      this.cameraHost = await LumixCameraService.linkedGateway();
    } catch (_error) {
      this.cameraHost = '';
    }
    if (this.cameraHost.length === 0) this.cameraHost = FujifilmNet.HOST;
    await this.rememberCameraCard(true);
    AppLogStore.add(`[FUJI] 相机 Wi‑Fi 已连接 ssid=${this.cam.cameraWifiSsid} host=${this.cameraHost}`);
    return true;
  }

  private async connectCameraByTransportConfirmed(): Promise<void> {
    if (this.cameraTransport === 0) {
      // Sync-generation bodies (original S5 plus GH5/G9-class siblings) do
      // not use the newer LUMIX Lab BLE registration route. If their AP is
      // already linked, or the selected identity belongs to the Sync
      // generation, enter the dedicated passive Wi-Fi flow directly instead
      // of waiting forever in the generic BLE connector.
      const linkedSsid = await LumixCameraService.linkedSsid();
      const linkedIdentity = LumixCameraService.identifyWifiSsid(linkedSsid);
      const linkedIsSync = linkedIdentity !== null &&
        (LumixCameraService.isOriginalS5WifiSsid(linkedSsid) ||
          LumixCameraService.panasonicRouteForModel(linkedIdentity.model) === 'sync');
      // A leftover association with a Sync body's AP must not hijack the
      // confirm action when a different body is explicitly selected in the
      // carousel (for example an S1RII card). Only take the linked-SSID
      // shortcut when the selected identity is the same generation or
      // nothing is selected.
      const selectedCandidateIsSync = this.camCgiRouteSelected() ||
        LumixCameraService.isOriginalS5WifiSsid(this.cam.cameraBleCandidateName) ||
        LumixCameraService.isOriginalS5WifiSsid(this.cam.cameraBleCandidateModel) ||
        LumixCameraService.panasonicRouteForModel(
          `${this.cam.cameraBleCandidateModel} ${this.cam.cameraBleCandidateName}`) === 'sync';
      const selectedOtherCamera = this.cam.cameraBleCandidateName.length > 0 && !selectedCandidateIsSync;
      if (linkedIsSync && !selectedOtherCamera && linkedIdentity !== null) {
        const linkedCandidate: LumixWifiCandidate = {
          ssid: linkedSsid,
          bssid: '',
          rssi: 0,
          securityType: 0,
          model: linkedIdentity.model,
          family: linkedIdentity.family,
          imageKey: linkedIdentity.imageKey,
          brand: 'Panasonic',
        };
        this.cam.cameraBrand = 'Panasonic';
        this.cam.cameraModel = linkedIdentity.model;
        this.cam.cameraImageKey = linkedIdentity.imageKey;
        await this.connectCameraWifi(linkedCandidate);
        return;
      }
      if (linkedIsSync && selectedOtherCamera) {
        // The phone is still associated with a Sync body's AP while another
        // body is explicitly selected. Confirming the new camera must first
        // release the old system link and stop its passive receiver;
        // otherwise the new body's flow inherits a stale Wi-Fi route and the
        // camera keeps its push session open against a receiver that is no
        // longer reading.
        await this.teardownActiveCameraWifiSession();
        this.cam.cameraMessage = `已断开 ${linkedSsid}，正在连接所选相机…`;
      }
      if (this.syncRouteSelected() && this.cameraBleCandidateDeviceId.length > 0) {
        // Sync 线：确认连接也走配对。req_acc 是配对提交，协议上必须在加入
        // 相机 AP 之后发送，所以这里必然包含一次入网；配对完成后主按钮变
        // 「删除连接」，图片传输 / 相机控制再复用或按需重拉热点。
        this.cam.cameraState = 1;
        this.cam.cameraTransferInProgress = true;
        this.cam.cameraMessage = '正在通过 LUMIX Sync 蓝牙配对…';
        try {
          const paired = await this.runSyncControlHandshake();
          if (paired) {
            this.cam.cameraState = 2;
            this.cam.cameraBleStatus = '已连接';
            this.cam.cameraWifiStatus = '已连接';
            this.cam.cameraSessionStatus = '已建立';
            this.cam.cameraMessage = 'LUMIX Sync 配对完成；点「图片传输」或「相机控制」继续';
          } else if (this.cam.cameraState === 1) {
            this.cam.cameraState = 0;
          }
        } finally {
          if (this.syncPairDialogController) {
            this.syncPairDialogController.close();
            this.syncPairDialogController = null;
          }
          this.cam.cameraTransferInProgress = false;
        }
        return;
      }
      if (this.camCgiRouteSelected()) {
        // Enter the visible busy state before starting the asynchronous scan
        // and system Wi‑Fi confirmation. Without this transition the button
        // remains labelled "确认连接" and appears unresponsive while the
        // HarmonyOS trust sheet is already in flight.
        this.cam.cameraState = 1;
        this.cam.cameraTransferInProgress = true;
        this.cam.cameraMessage = '正在扫描相机 Wi‑Fi…';
        try {
          await this.scanCameraWifi(true);
        } finally {
          // connectCameraWifi() moves a successful Sync-route session to
          // state 2; retain that state and only clear the busy marker here.
          this.cam.cameraTransferInProgress = false;
          if (this.cam.cameraState === 1 && this.wifiScanState === 0 && !this.wifiConnecting) {
            this.cam.cameraState = 0;
          }
        }
        return;
      }
      this.cameraUsbHandshakeComplete = false;
      await this.runCameraImportPrototype(false);
      return;
    }
    this.cam.cameraState = 1;
    this.cam.cameraMessage = '正在请求 USB 相机授权…';
    const result: LumixUsbConnectionResult = await LumixCameraService.connectUsbCamera();
    if (result.connected) {
      this.cam.cameraState = 2;
      this.cam.cameraModel = result.model;
      this.cam.cameraImageKey = result.imageKey;
      this.cameraThumbnailUri = '';
      this.cam.cameraWifiSsid = '';
      this.cam.cameraBleStatus = '未连接';
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '未建立';
      this.cameraUsbHandshakeComplete = true;
      // USB PTP is the authorization leg. Continue with the same BLE/Wi-Fi
      // gallery path used by the normal camera button, then keep the camera page visible.
      this.cameraTransport = 0;
      this.selectedSection = 1;
      this.cam.cameraMessage = result.message;
      this.showMessage(`已连接 ${result.model}（USB PTP）`);
      await this.runLumixImportPrototype(true);
      if (!this.cameraWifiConnected()) {
        this.cam.cameraMessage = `USB PTP 握手成功，但 Wi‑Fi 图库会话未建立；${this.cam.cameraMessage}`;
      }
    } else {
      this.cam.cameraState = 0;
      this.cameraUsbHandshakeComplete = false;
      this.cam.cameraMessage = result.message;
      this.showMessage(result.message);
    }
  }

  private async removeCameraConnection(): Promise<void> {
    const removed = this.selectedCameraCard();
    const deletingAnotherCamera = this.cameraCards.hasOtherConnection(removed);
    const wasSyncRoute = this.camCgiRouteSelected();
    const wasNikon = this.cam.cameraBrand === 'Nikon';
    const wasSony = this.cam.cameraBrand === 'Sony';
    const deviceId = this.cameraBleCandidateDeviceId;
    let context: common.UIAbilityContext | null = null;
    try { context = this.getUIContext().getHostContext() as common.UIAbilityContext; } catch (_error) { }
    if (!context) { this.showMessage('无法保存删除操作，请稍后重试'); return; }
    if (context) {
      try {
        const legacyName = await LumixImportPrototype.rememberedCameraName(context);
        const legacy: LumixBleCameraCandidate = { deviceId: '', deviceName: legacyName, model: '',
          imageKey: '', brand: removed.brand, rssi: 0, connectable: false };
        const deletingLegacyKey = legacyName.replace(/[\u0000-\u001F\u007F]/g, '').trim();
        // The legacy store holds only a name, so an address-keyed card cannot
        // match it by key alone; compare the display names as well.
        const deletingLegacy = this.cameraCandidateKey(legacy) === this.cameraCandidateKey(removed) ||
          (deletingLegacyKey.length > 0 && deletingLegacyKey === this.cam.cameraBleCandidateName);
        await this.cameraCards.forget(context, removed);
        if (deletingLegacy) await LumixImportPrototype.clearRememberedCamera(context);
      } catch (_error) { this.showMessage('相机记录删除失败，请重试'); return; }
    }
    // Deleting an offline card must not stop another body's receiver/GATT/session.
    if (deletingAnotherCamera) {
      await LumixImportPrototype.removeSystemPairing(deviceId);
      this.refreshCameraCards();
      this.showMessage('已删除所选相机连接');
      return;
    }
    this.stopCameraBleDiscovery();
    this.cameraCards.setConnected(null);
    await PanasonicS5Receiver.stop();
    if (wasSyncRoute) await LumixImportPrototype.disconnectCameraWifi();
    await LumixImportPrototype.closeActiveGatt();
    const systemUnpaired = await LumixImportPrototype.removeSystemPairing(deviceId);
    LumixImportPrototype.clearHttpSession();
    this.cam.cameraState = 0;
    this.cameraUsbHandshakeComplete = false;
    this.cameraWifiOnlyReady = false;
    this.syncWifiDetected = false;
    this.cameraPairingAttempted = false;
    this.cam.cameraBleStatus = '未连接';
    this.cam.cameraWifiStatus = '未连接';
    this.cam.cameraSessionStatus = '未建立';
    this.cam.cameraWifiSsid = '';
    this.cameraHost = '';
    this.cameraThumbnailUri = '';
    this.cam.cameraGalleryItems = [];
    this.cam.cameraGalleryTotal = 0;
    this.cam.selectedCameraImageIds = [];
    this.cam.cameraGalleryHasMore = false;
    this.cam.cameraGalleryLoading = false;
    this.cameraGalleryPage = 1;
    this.cameraGalleryNextStartIndex = 0;
    this.cameraGalleryScrollOffset = 0;
    this.cam.cameraImageKey = '';
    this.cam.cameraModel = 'LUMIX';
    this.cam.cameraBrand = 'Panasonic';
    this.cam.cameraMessage = systemUnpaired
      ? '已删除 Pixelshop 连接并请求系统取消配对，可重新确认连接'
      : '已删除 Pixelshop 连接；当前系统 API 不提供自动取消配对，可重新确认连接';
    this.cam.cameraBleCandidateName = '';
    this.cameraBleCandidateDeviceId = '';
    this.cam.cameraBleCandidateModel = '';
    this.cameraBleCandidateBrand = 'Panasonic';
    this.cameraBleCandidateImageKey = '';
    this.cameraBleCandidateConnectable = false;
    this.cameraBleCandidateBtAddress = '';
    this.refreshCameraCards();
    this.cam.s5Receiving = false;
    this.cam.s5ReceiveProgress = 0;
    this.cam.s5ReceiveStatus = '';
    this.cam.s5ReceiveFiles = 0;
    this.syncS5ReceiveOverlayState();
    this.s5LastReceivedJpegUri = '';
    if (this.selectedSection === 1) this.startCameraBleDiscovery();
    // Lab-registration LUMIX bodies keep the pairing record on the camera
    // side. A fresh registration is rejected while that record exists, so the
    // user must delete it in the camera menu before pairing again.
    if (!wasSyncRoute && !wasNikon && !wasSony) {
      AppLogStore.add('ui 删除连接提示 相机端删除配对');
      try {
        this.getUIContext().showAlertDialog({
          title: '连接已删除',
          message: '请在相机端的蓝牙设置中删除本机（手机）的配对信息，再重新配对，否则相机可能拒绝新的连接请求。',
          autoCancel: true,
          alignment: DialogAlignment.Center,
          buttons: [
            {
              value: '知道了',
              action: () => {
              },
            },
          ],
        });
      } catch (_error) {
        this.showMessage('请在相机端删除配对信息后重新配对');
      }
    }
  }

  private async connectCamera(): Promise<void> {
    this.cam.cameraState = 1;
    this.cam.cameraMessage = '正在查找相机…';
    const result: LumixProbeResult = await LumixCameraService.probe(this.cameraHost);
    if (result.connected) {
      this.cam.cameraState = 2;
      this.cam.cameraModel = result.model;
      if (this.cam.cameraImageKey.length === 0) {
        this.cam.cameraImageKey = LumixCameraService.imageKeyForModel(result.model);
      }
      if (this.cam.cameraWifiSsid.length === 0) {
        this.cam.cameraWifiSsid = await LumixCameraService.linkedSsid();
      }
      const rawNote = result.supportsRaw ? '支持 RAW 传输' : '仅 JPEG 传输';
      this.cam.cameraMessage = `${result.family} · ${rawNote} · ${result.message}`;
      this.showMessage(`已连接 ${result.model}（${result.family}）`);
    } else {
      this.cam.cameraState = 0;
      this.cam.cameraMessage = result.message;
      this.showMessage(result.message);
    }
  }

  /**
   * A Nikon body may expose its access point before the BLE advertisement is
   * visible. Probe Wi-Fi once when no BLE candidate exists so the confirmation
   * action still works for a Wi-Fi-only discovery. Panasonic falls through to
   * its existing BLE protocol unchanged when no Nikon AP is found.
   */
  private async tryDirectNikonWifi(): Promise<boolean> {
    if (this.cameraBleCandidates.length > 0) return false;
    const granted = await this.requestWifiPermissions();
    if (!granted) return false;
    let candidates: LumixWifiCandidate[] = [];
    try { candidates = await LumixCameraService.scanForCameras(); } catch (_error) { return false; }
    let nikon: LumixWifiCandidate | null = null;
    // Prefer the network already linked to the phone. It can be absent from a
    // fresh scan while still being a valid Nikon camera AP.
    try {
      const linkedSsid = await LumixCameraService.linkedSsid();
      const linkedIdentity = NikonCameraService.identifyWifiSsid(linkedSsid);
      if (linkedIdentity) {
        nikon = {
          ssid: linkedSsid,
          bssid: '',
          rssi: 0,
          securityType: 0,
          model: linkedIdentity.model,
          family: linkedIdentity.family,
          imageKey: linkedIdentity.imageKey,
          brand: 'Nikon',
        };
      }
    } catch (_error) { }
    for (const candidate of candidates) {
      if (nikon) break;
      if (candidate.brand === 'Nikon' || NikonCameraService.isNikonImageKey(candidate.imageKey)) {
        nikon = candidate;
        break;
      }
    }
    if (!nikon) return false;
    this.wifiCandidates = candidates;
    this.cam.cameraBrand = 'Nikon';
    this.cameraBleCandidateBrand = 'Nikon';
    this.cam.cameraBleCandidateName = nikon.ssid;
    this.cameraBleCandidateDeviceId = '';
    this.cam.cameraBleCandidateModel = nikon.model;
    this.cameraBleCandidateImageKey = nikon.imageKey;
    this.cameraBleCandidateConnectable = true;
    this.cameraBleCandidateBtAddress = '';
    this.cam.cameraImageKey = nikon.imageKey;
    this.cam.cameraModel = nikon.model;
    this.mergeWifiCameraCandidates(candidates.indexOf(nikon) >= 0 ? candidates : candidates.concat([nikon]));
    this.cameraPairingAttempted = true;
    this.cam.cameraState = 2;
    this.cam.cameraBleStatus = '已发现';
    this.cam.cameraMessage = `${nikon.ssid} 已识别，正在连接相机 Wi‑Fi…`;
    await this.connectCameraWifi(nikon);
    return true;
  }

  /**
   * A Sony body exposes its PC Remote access point before any BLE identity is
   * usable in this flow. Probe Wi-Fi once when no candidate exists so the
   * confirmation action still works for a Wi-Fi-only discovery, mirroring the
   * Nikon direct path. Panasonic falls through unchanged.
   */
  private async tryDirectSonyWifi(): Promise<boolean> {
    if (this.cameraBleCandidates.length > 0) return false;
    const granted = await this.requestWifiPermissions();
    if (!granted) return false;
    let candidates: LumixWifiCandidate[] = [];
    try { candidates = await LumixCameraService.scanForCameras(); } catch (_error) { return false; }
    let sony: LumixWifiCandidate | null = null;
    // Prefer the network already linked to the phone. It can be absent from a
    // fresh scan while still being a valid Sony camera AP.
    try {
      const linkedSsid = await LumixCameraService.linkedSsid();
      const linkedIdentity = SonyCameraService.identifyWifiSsid(linkedSsid);
      if (linkedIdentity) {
        sony = {
          ssid: linkedSsid,
          bssid: '',
          rssi: 0,
          securityType: 0,
          model: linkedIdentity.model,
          family: linkedIdentity.family,
          imageKey: linkedIdentity.imageKey,
          brand: 'Sony',
        };
      }
    } catch (_error) { }
    for (const candidate of candidates) {
      if (sony) break;
      if (candidate.brand === 'Sony' || SonyCameraService.isSonyImageKey(candidate.imageKey)) {
        sony = candidate;
        break;
      }
    }
    if (!sony) return false;
    this.wifiCandidates = candidates;
    this.cam.cameraBrand = 'Sony';
    this.cameraBleCandidateBrand = 'Sony';
    this.cam.cameraBleCandidateName = sony.ssid;
    this.cameraBleCandidateDeviceId = '';
    this.cam.cameraBleCandidateModel = sony.model;
    this.cameraBleCandidateImageKey = sony.imageKey;
    this.cameraBleCandidateConnectable = true;
    this.cameraBleCandidateBtAddress = '';
    this.cam.cameraImageKey = sony.imageKey;
    this.cam.cameraModel = sony.model;
    this.mergeWifiCameraCandidates(candidates.indexOf(sony) >= 0 ? candidates : candidates.concat([sony]));
    this.cameraPairingAttempted = true;
    this.cam.cameraState = 2;
    this.cam.cameraBleStatus = '已发现';
    this.cam.cameraMessage = `${sony.ssid} 已识别，正在连接相机 Wi‑Fi…`;
    await this.connectCameraWifi(sony);
    return true;
  }

  /** Route the transport through the brand-specific protocol adapter. */
  private async runCameraImportPrototype(startWifi: boolean = true): Promise<void> {
    this.cameraWifiCloseRequested = false;
    if (this.cameraBleCandidates.length === 0 && this.cam.cameraBleCandidateName.length === 0 &&
      this.cameraBleCandidateImageKey.length === 0) {
      if (await this.tryDirectNikonWifi()) return;
      if (await this.tryDirectSonyWifi()) return;
      if (await this.tryDirectPanasonicWifiOnly()) return;
    }
    if (this.cam.cameraBrand === 'Nikon' || NikonCameraService.isNikonImageKey(this.cameraBleCandidateImageKey) ||
      NikonCameraService.isNikonImageKey(this.cam.cameraImageKey)) {
      await this.ensureNikonWifiForAction('图片传输');
      return;
    }
    if (this.cam.cameraBrand === 'Sony' || SonyCameraService.isSonyImageKey(this.cameraBleCandidateImageKey) ||
      SonyCameraService.isSonyImageKey(this.cam.cameraImageKey)) {
      await this.runSonyImportPrototype(startWifi);
      return;
    }
    // Sync-generation bodies (original S5 plus GH5/GH5S/G9/GH6/G100D and
    // siblings) and the LUMIX Image App line both keep the camera access point
    // for image transfer and must never enter the Lab BLE registration flow.
    // They differ only in how the access point is reached: the Sync line takes
    // the SSID/password the body returned over BLE, the Image App line has no
    // Bluetooth at all.
    if (LumixCameraService.isWifiOnlyModel(`${this.cam.cameraModel} ${this.cam.cameraBleCandidateModel} ${this.cam.cameraBleCandidateName}`) ||
      this.camCgiRouteSelected()) {
      await this.runPanasonicWifiOnlyImport(startWifi);
      return;
    }
    await this.runLumixImportPrototype(startWifi);
  }

  /** Wi‑Fi-only Panasonic discovery for the cam.cgi family when no BLE
   * advertisement is visible (Bluetooth off, or an Image App body with no radio). */
  private async tryDirectPanasonicWifiOnly(): Promise<boolean> {
    let candidates: LumixWifiCandidate[] = [];
    try {
      const granted = await this.requestWifiPermissions();
      if (!granted) return false;
      candidates = await LumixCameraService.scanForCameras();
    } catch (_error) {
      return false;
    }
    let direct: LumixWifiCandidate | null = null;
    let linkedOtherPanasonic = false;
    try {
      const linkedSsid = await LumixCameraService.linkedSsid();
      const linkedIdentity = LumixCameraService.identifyWifiSsid(linkedSsid);
      if (linkedIdentity && LumixCameraService.isCamCgiRoute(
        LumixCameraService.panasonicRouteForModel(linkedIdentity.model))) {
        direct = {
          ssid: linkedSsid, bssid: '', rssi: 0, securityType: 0,
          model: linkedIdentity.model, family: linkedIdentity.family,
          imageKey: linkedIdentity.imageKey, brand: 'Panasonic',
        };
      } else if (linkedIdentity) {
        // The phone is already associated with a different Panasonic body
        // (for example an S1RII access point). Do not steal a visible
        // Sync body's AP.
        linkedOtherPanasonic = true;
      }
    } catch (_error) { }
    if (!direct && !linkedOtherPanasonic) {
      for (const candidate of candidates) {
        if (candidate.brand === 'Panasonic' &&
          LumixCameraService.isCamCgiRoute(LumixCameraService.panasonicRouteForModel(candidate.model))) {
          direct = candidate;
          break;
        }
      }
    }
    if (!direct) return false;
    this.wifiCandidates = [direct];
    this.cam.cameraBrand = 'Panasonic';
    this.cameraBleCandidateBrand = 'Panasonic';
    this.cam.cameraBleCandidateName = direct.ssid;
    this.cameraBleCandidateDeviceId = '';
    this.cam.cameraBleCandidateModel = direct.model;
    this.cameraBleCandidateImageKey = direct.imageKey;
    this.cameraBleCandidateConnectable = false;
    this.cameraBleCandidateBtAddress = '';
    this.cam.cameraImageKey = direct.imageKey;
    this.cam.cameraModel = direct.model;
    this.mergeWifiCameraCandidates(candidates.indexOf(direct) >= 0 ? candidates : candidates.concat([direct]));
    this.syncWifiDetected = true;
    this.cameraPairingAttempted = false;
    this.cam.cameraState = 0;
    this.cam.cameraBleStatus = '未连接';
    this.cam.cameraMessage = `${direct.ssid} 已识别，确认后连接相机 Wi‑Fi`;
    return true;
  }

  /**
   * The cam.cgi family (Sync-generation bodies and the Image App line).
   * Image transfer starts from the camera access point and must not invoke
   * the newer S-body BLE registration flow.
   */
  private async runPanasonicWifiOnlyImport(_startWifi: boolean = true): Promise<void> {
    this.cameraWifiOnlyReady = false;
    this.cam.cameraTransferInProgress = true;
    this.cam.cameraState = 1;
    // The Image App line has no Bluetooth leg at all, so keep the indicator
    // neutral while the dedicated Wi‑Fi scan runs. A Sync-line body reaches this
    // point already paired over Bluetooth — its Wi‑Fi is brought up on demand
    // from the BLE-delivered SSID/password — so its pairing status is preserved.
    if (!this.syncRouteSelected()) this.cam.cameraBleStatus = '未连接';
    this.cam.cameraWifiStatus = '连接中';
    this.cam.cameraSessionStatus = '未建立';
    this.cam.cameraMessage = this.cam.cameraBleCandidateName.length > 0
      ? `${this.cam.cameraBleCandidateName} 已识别，正在扫描相机 Wi‑Fi…`
      : '正在扫描松下相机 Wi‑Fi…';
    try {
      await this.scanCameraWifi(true);
    } finally {
      this.cam.cameraTransferInProgress = false;
    }
  }

  /** 被动接收状态镜像到 AppStorage，供窗口级全局浮层 S5ReceiveOverlay
   *  在主页与任意页面非阻塞显示推送进度。所有 s5* 字段写入后调用。 */
  private syncS5ReceiveOverlayState(): void {
    AppStorage.setOrCreate('vividS5Receiving', this.cam.s5Receiving);
    AppStorage.setOrCreate('vividS5Progress', this.cam.s5ReceiveProgress);
    AppStorage.setOrCreate('vividS5Status', this.cam.s5ReceiveStatus);
    AppStorage.setOrCreate('vividS5Files', this.cam.s5ReceiveFiles);
  }

  /** Establish the LUMIX Image App line's passive DMS/DLNA session without
   *  navigation. The Sync line no longer starts this session: it pulls images
   *  actively after joining the camera access point with the BLE-delivered
   *  SSID and password. */
  private async preparePanasonicS5PassiveSession(): Promise<void> {
    let context: common.UIAbilityContext;
    let failureMessage = '相机握手失败，请重试';
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (_error) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = '无法取得应用上下文，不能开启接收监听';
      return;
    }
    try {
      // Keep one Vivid-owned identity for both req_acc and the local DMS
      // advertisement. LUMIX Sync uses the same logical client identity across
      // these two stages of the S5 handshake.
      const clientId = await LumixImportPrototype.persistentS5DmsUuid(context);
      // Match the observed S5 order: request camera access first, then expose
      // the local DMS endpoint. Advertising a DMS before req_acc leaves the
      // body on its "LUMIX Sync" waiting page even though Wi-Fi is linked.
      // The S5 will only leave its "Wi‑Fi connected / start LUMIX Sync"
      // screen after the camera-side access request succeeds.  Do not start a
      // local DMS listener when the gateway is unknown: the camera can then
      // discover the listener and trigger a false "waiting for pictures"
      // state without having accepted Vivid as the client.
      if (this.cameraHost.length === 0) throw new Error('S5 gateway unavailable');
        // DMP discovery is a best-effort descriptor probe.  The official
        // client still proceeds to req_acc when a body omits this description;
        // only a rejected access-control request means the camera has not
        // accepted Vivid as its client.
        const browseGranted = await LumixCameraService.requestS5DmpBrowse(this.cameraHost);
        if (!browseGranted) {
          try { hilog.warn(0x0001, 'VIVID_S5', 'dmp descriptor unavailable; continue req_acc'); } catch (_error) { }
        }
        const accessGranted = await LumixCameraService.requestS5Access(this.cameraHost, clientId);
      if (!accessGranted) {
        failureMessage = '相机访问授权被相机拒绝';
        throw new Error(failureMessage);
      }
      await PanasonicS5Receiver.start(context, {
        onSessionStart: (remote: string): void => {
          // A DMS/SSDP discovery connection is not a file transfer.  The S5
          // opens the DMS socket while it is still on its Wi‑Fi-complete
          // screen, so showing the modal here falsely locks the page before
          // any image bytes have arrived.  Keep this as a non-blocking status
          // update; the modal is entered by onProgress/onFile after payload
          // bytes have been parsed.
          this.cam.s5ReceiveProgress = 0;
          this.cam.s5ReceiveStatus = `接收通道已连接，等待文件（${remote}）`;
          this.cam.cameraMessage = '接收通道已就绪，等待相机发送图片';
          this.syncS5ReceiveOverlayState();
        },
        onProgress: (received: number, total: number): void => {
          // onProgress is emitted only after the file framing parser accepts
          // a payload.  Guard against zero-length/control callbacks so a
          // discovery exchange can never open the receiving modal.
          if (received <= 0) return;
          this.cam.s5Receiving = true;
          this.cam.s5ReceiveProgress = total > 0 ? Math.min(100, received * 100 / total) : 0;
          this.cam.s5ReceiveStatus = total > 0
            ? `正在接收 ${(received / 1048576).toFixed(1)} / ${(total / 1048576).toFixed(1)} MB`
            : `正在接收 ${(received / 1048576).toFixed(1)} MB`;
          this.syncS5ReceiveOverlayState();
        },
        onFile: (file: PanasonicS5ReceivedFile): void => {
          this.cam.s5Receiving = true;
          this.cam.s5ReceiveFiles += 1;
          this.cam.s5ReceiveProgress = 100;
          this.cam.s5ReceiveStatus = `${file.name} 已接收，正在写入图库…`;
          this.syncS5ReceiveOverlayState();
          this.importS5ReceivedFile(file);
        },
        onSessionEnd: (): void => {
          this.cam.s5ReceiveStatus = this.cam.s5ReceiveFiles > 0 ? '传输完成，图片已加入最近作品' : '等待相机发送图片';
          if (this.cam.s5ReceiveFiles > 0) {
            this.syncS5ReceiveOverlayState();
            setTimeout((): void => {
              this.cam.s5Receiving = false;
              this.cam.s5ReceiveProgress = 0;
              this.syncS5ReceiveOverlayState();
            }, 900);
          } else {
            this.syncS5ReceiveOverlayState();
          }
        },
        onError: (message: string): void => {
          this.cam.cameraMessage = message;
          this.cam.s5ReceiveStatus = message;
          this.syncS5ReceiveOverlayState();
        },
      }, { clientUuid: clientId, peerHost: this.cameraHost });
      // The original S5 push-transfer trace contains no camcmd/pictmode
      // request. That command belongs to the shooting/live-view service and
      // returns err_param on S5; sending it here leaves the camera on the
      // "start Lumix Sync" page. req_acc followed by DMS/SSDP discovery is
      // the complete app-side handshake for this route.
      try { hilog.info(0x0001, 'VIVID_S5', 'DMS advertisement active; waiting for camera push'); } catch (_error) { }
      // The S5 fetches the local DMS description on its own 8-15 second
      // processing cycle after req_acc. Repeat the DMP discovery probe in the
      // background so the body can run its Wi-Fi-complete -> transfer screen
      // transition on an earlier cycle instead of waiting for the next one.
      void LumixCameraService.nudgeS5DmpDiscovery(this.cameraHost);
      // Do not append the generic cam.cgi getstate/getinfo probe here. Those
      // endpoints belong to the LUMIX Lab gallery path and are absent from the
      // S5 push trace; issuing them after req_acc can make the camera keep its
      // "Wi-Fi connection complete" page even though the DMS listener is live.
      this.cam.cameraModel = this.cam.cameraBleCandidateModel.length > 0 ? this.cam.cameraBleCandidateModel : 'LUMIX';
      this.cam.cameraState = 2;
      this.cam.cameraSessionStatus = '已建立';
      this.cameraWifiOnlyReady = false;
      this.cam.cameraTransferInProgress = false;
      this.cam.cameraMessage = '接收通道已就绪，相机将在约 10-20 秒内进入传输模式';
      // 被动 wifi/PTP 仅由「确认连接」触发：提示用户在相机上主动推送，
      // 图片到达后经全局浮层显示下载进度并写入最近作品。
      try {
        this.getUIContext().showAlertDialog({
          title: '接收通道已就绪',
          message: '请在相机上选择照片并点击「发送」进行推送；图片将自动下载到「最近作品」，接收进度显示在页面顶部。',
          autoCancel: true,
          alignment: DialogAlignment.Center,
          buttons: [
            {
              value: '知道了',
              action: (): void => {
              },
            },
          ],
        });
      } catch (_error) {
      }
    } catch (_error) {
      await PanasonicS5Receiver.stop();
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraState = 0;
      this.cam.cameraMessage = failureMessage;
      this.showMessage(this.cam.cameraMessage);
    }
  }

  /**
   * Nikon uses BLE advertisements for identity/discovery in this import flow;
   * confirmation goes straight to the camera Wi-Fi AP. Keep this route separate
   * from the Panasonic HTTP/gallery path so Nikon never triggers LUMIX /auth or
   * ACTION_MODE requests. Z8 (NIKON_Z_8_xxxxx) intentionally follows the same
   * direct Wi-Fi/PTP route as Z5; only the identity artwork/model label differs.
   */
  private async runNikonImportPrototype(_startWifi: boolean = true): Promise<void> {
    this.cameraWifiOnlyReady = false;
    // **图片传输也必须走尼康蓝牙流程——只有它才能读到相机的 Wi-Fi 凭据。**
    //
    // 凭据就在 `0x2004` 里（实测：SSID `Z_5_8073573_SnapBridge`、密码 `WNIKONZ5`），
    // 是相机通过蓝牙主动告诉我们的，**不需要用户手输**。按用户选定的方式：App 读到
    // 密码后自动加入，鸿蒙若要授权就由系统弹框，用户不参与输密码。
    //
    // 之前这里只调 `scanCameraWifi(true)` 去扫附近热点——扫到了也连不上，因为密码
    // 从来没被读出来过。用户看到的就是"相机 Wi-Fi 都拉起来了，App 却毫无反应"。
    //
    // 顺带修掉那个更严重的问题：蓝牙流程**每次都会重新向相机确认配对**，所以
    // "手机侧还留着记录、相机侧已经删了"这种单向状态不会再被误判成配对成功。
    if (this.cam.cameraBleCandidateName.length === 0 && this.cameraBleCandidateImageKey.length === 0) {
      this.cam.cameraMessage = '未发现尼康相机，请打开相机 Wi‑Fi 或蓝牙后重试';
      return;
    }
    let context: common.UIAbilityContext | null = null;
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (_error) {
      context = null;
    }
    if (context === null) {
      this.cam.cameraMessage = '无法取得应用上下文，尼康图传未开始';
      return;
    }
    this.cameraPairingAttempted = true;
    this.cam.cameraBrand = 'Nikon';
    if (this.cameraBleCandidateImageKey.length > 0) {
      this.cam.cameraImageKey = this.cameraBleCandidateImageKey;
    }
    this.cam.cameraModel = this.cam.cameraBleCandidateModel.length > 0 ?
      this.cam.cameraBleCandidateModel : 'NIKON';
    this.cam.cameraTransferInProgress = true;
    const trace: string[] = [];
    this.nikonStepIndex = 0;
    this.nikonStepTotal = 0;
    this.nikonPairingMessage = '正在通过蓝牙获取相机 Wi‑Fi 凭据…';
    AppStorage.setOrCreate('nikonPairStepIndex', 0);
    AppStorage.setOrCreate('nikonPairStepTotal', 0);
    AppStorage.setOrCreate('nikonPairStatus', this.nikonPairingMessage);
    try {
      this.nikonProgressDialog.open();
      this.nikonDialogOpen = true;
    } catch (dialogError) {
      try {
        hilog.error(0x0001, 'VIVID_PAIR',
          'Nikon import dialog open failed: ' + (dialogError as Error).message);
      } catch (_logError) {
      }
    }
    // 和配对走同一套进度：`Nikon step N/M ...` 驱动进度条，其余技术日志翻成中文。
    const progressTimer = setInterval(() => {
      const latest = trace.length > 0 ? trace[trace.length - 1] : '';
      if (latest.length > 0 && !this.nikonApplyStep(latest)) {
        const text = `尼康图传：${this.nikonProgressText(latest)}`;
        this.cam.cameraMessage = text;
        this.nikonPairingMessage = text;
        AppStorage.setOrCreate('nikonPairStatus', text);
      }
    }, 400) as number;
    try {
      const outcome = await NikonBleProvisioning.provision(context, trace);
      this.cam.cameraMessage = outcome.message;
      if (outcome.ok) {
        this.cam.cameraWifiStatus = '已连接';
        this.cam.cameraSessionStatus = '已建立';
        // **连上相机 Wi-Fi 之后才进入图库。**
        //
        // 顺序反了的话，用户会先看到图库在空转、中途才被系统的 Wi-Fi 授权框打断，
        // 体感上是"没连上就进去了"（用户反馈过）。这里严格等 `provision` 返回成功
        // ——那代表凭据已经读到、并且手机已经真的加入相机的热点。
        this.selectedSection = 1;
      } else {
        this.cam.cameraWifiStatus = '未连接';
        this.cam.cameraSessionStatus = '未建立';
      }
    } catch (error) {
      this.cam.cameraMessage = `尼康图传异常：${(error as Error).message}`;
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '未建立';
    } finally {
      clearInterval(progressTimer);
      this.nikonPairingMessage = this.cam.cameraMessage;
      if (this.nikonDialogOpen) {
        try {
          this.nikonProgressDialog.close();
        } catch (closeError) {
          try {
            hilog.error(0x0001, 'VIVID_PAIR',
              'Nikon import dialog close failed: ' + (closeError as Error).message);
          } catch (_logError) {
          }
        }
        this.nikonDialogOpen = false;
      }
      this.nikonStepIndex = 0;
      this.nikonStepTotal = 0;
      this.cam.cameraTransferInProgress = false;
    }
  }

  /**
   * Sony confirmation mirrors the Nikon route: record the nearby identity and
   * go straight to the PC Remote camera Wi‑Fi AP, whose photo transport is the
   * same standard PTP/IP stack (shared NikonPtpIpService transport). Sony
   * never triggers LUMIX /auth or ACTION_MODE requests.
   */
  private async runSonyImportPrototype(_startWifi: boolean = true): Promise<void> {
    this.cameraWifiOnlyReady = false;
    if (this.cam.cameraBleCandidateName.length === 0 && this.cameraBleCandidateImageKey.length === 0) {
      this.cam.cameraMessage = '未发现索尼相机，请打开相机 Wi‑Fi 或蓝牙后重试';
      return;
    }
    this.cameraPairingAttempted = true;
    this.cam.cameraState = 2;
    this.cam.cameraBleStatus = this.cameraBleCandidateConnectable &&
      this.cameraBleLastSeenAt > 0 && Date.now() - this.cameraBleLastSeenAt <= 6000 ?
      '已发现' : '未连接';
    this.cam.cameraWifiStatus = '未连接';
    this.cam.cameraSessionStatus = '未建立';
    this.cam.cameraTransferInProgress = true;
    this.cam.cameraBrand = 'Sony';
    if (this.cameraBleCandidateImageKey.length > 0) this.cam.cameraImageKey = this.cameraBleCandidateImageKey;
    this.cam.cameraModel = this.cam.cameraBleCandidateModel.length > 0 ? this.cam.cameraBleCandidateModel : 'SONY';
    this.cam.cameraMessage = `${this.cam.cameraBleCandidateName} 已识别，正在扫描相机 Wi‑Fi…`;
    try {
      await this.scanCameraWifi(true);
    } finally {
      this.cam.cameraTransferInProgress = false;
    }
  }

  private async runLumixImportPrototype(startWifi: boolean = true, connectOnly: boolean = false): Promise<void> {
    this.cameraWifiOnlyReady = false;
    const preferredDeviceId = this.cameraBleCandidateDeviceId;
    const preferredDeviceName = this.cam.cameraBleCandidateName;
    this.cameraPairingAttempted = true;
    if (!startWifi) {
      this.stopCameraBleDiscovery();
      this.cam.cameraState = 1;
    } else {
      this.cam.cameraTransferInProgress = true;
    }
    if (!startWifi) this.cameraThumbnailUri = '';
    this.cam.cameraGalleryItems = [];
    this.cam.cameraGalleryTotal = 0;
    this.cam.selectedCameraImageIds = [];
    this.cam.cameraGalleryHasMore = false;
    this.cameraGalleryPage = 1;
    this.cameraGalleryNextStartIndex = 0;
    this.cameraGalleryScrollOffset = 0;
    if (!startWifi) {
      this.cam.cameraBleStatus = '连接中';
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '未建立';
    } else {
      this.showWifiPicker = false;
      this.wifiCandidates = [];
      this.cam.cameraWifiStatus = '连接中';
      this.cam.cameraSessionStatus = '未建立';
    }
    this.cam.cameraMessage = preferredDeviceName.length > 0
      ? (startWifi ? `正在由 Pixelshop 向 ${preferredDeviceName} 发起图片传输握手…` : `正在由 Pixelshop 向 ${preferredDeviceName} 发起配对请求…`)
      : (startWifi ? '未找到已确认的蓝牙相机连接' : '正在监听相机并由 Pixelshop 发起配对请求…');
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const atManager = abilityAccessCtrl.createAtManager();
      if (startWifi) {
        await atManager.requestPermissionsFromUser(context, [
          'ohos.permission.ACCESS_BLUETOOTH',
          'ohos.permission.GET_WIFI_INFO',
          'ohos.permission.SET_WIFI_INFO',
          'ohos.permission.LOCATION',
          'ohos.permission.APPROXIMATELY_LOCATION',
        ]);
      } else {
        await atManager.requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
      }
      const result: LumixImportResult = await LumixImportPrototype.run(context, this.cameraHost, (update: LumixImportPhaseUpdate): void => {
        this.cam.cameraBleStatus = update.bleConnected ? '已连接' : (update.phase === 'ble' ? '连接中' : '未连接');
        this.cam.cameraWifiStatus = update.wifiConnected ? '已连接' : (update.phase === 'wifi' ? '连接中' : '未连接');
        this.cam.cameraSessionStatus = update.sessionEstablished ? '已建立' : (update.phase === 'session' ? '认证中' : '未建立');
        if (update.wifiSsid.length > 0) {
          this.cam.cameraWifiSsid = update.wifiSsid;
        }
        if (update.gateway.length > 0) this.cameraHost = update.gateway;
        this.cam.cameraMessage = update.message;
        if (startWifi && !connectOnly && update.wifiConnected) this.selectedSection = 1;
      }, preferredDeviceId, !startWifi, startWifi, this.cam.selectedSd, connectOnly);
      // The scan callback can be missing the friendly name even though GATT
      // returns a concrete device id. Resolve that name after the connection
      // and commit the matching local asset before the card re-renders.
      const resolvedDeviceName = preferredDeviceName.length > 0
        ? preferredDeviceName
        : LumixImportPrototype.remoteDeviceName(result.deviceId);
      if (resolvedDeviceName.length > 0) {
        const resolvedImageKey = this.cameraImageKeyForName(resolvedDeviceName);
        this.cam.cameraBleCandidateName = resolvedDeviceName;
        this.cameraBleCandidateImageKey = resolvedImageKey;
        this.cameraBleCandidateBrand = NikonCameraService.isNikonImageKey(resolvedImageKey) ? 'Nikon' : 'Panasonic';
        this.cam.cameraBrand = this.cameraBleCandidateBrand;
        if (resolvedImageKey.length > 0) this.cam.cameraImageKey = resolvedImageKey;
      }
      this.cam.cameraMessage = result.message;
      this.cam.cameraBleStatus = result.bleConnected ? '已连接' : (startWifi && this.cam.cameraState === 2 ? '已连接' : '未连接');
      this.cam.cameraWifiStatus = result.wifiConnected ? '已连接' : '未连接';
      this.cam.cameraSessionStatus = result.sessionEstablished ? '已建立' : '未建立';
      if (result.wifiSsid.length > 0) this.cam.cameraWifiSsid = result.wifiSsid;
      if (result.gateway.length > 0) this.cameraHost = result.gateway;
      if (result.deviceId.length > 0) this.cameraBleCandidateDeviceId = result.deviceId;
      // A connect-only run (LUT/相机控制/图片传输 entry) brings up the Wi-Fi
      // session but leaves the gallery untouched: the first fetch happens on
      // the user's scroll instead.
      if (!connectOnly) {
        this.cam.cameraGalleryItems = result.galleryItems || [];
        this.cam.cameraGalleryTotal = result.galleryTotal || this.cam.cameraGalleryItems.length;
        // The first page was requested at total-6; the next older page starts
        // one page before that boundary.
        this.cameraGalleryNextStartIndex = Math.max(0, this.cam.cameraGalleryTotal - 12);
        this.cam.cameraGalleryHasMore = this.cam.cameraGalleryTotal > 6 ||
          (this.cam.cameraGalleryTotal === 0 && this.cam.cameraGalleryItems.length >= 6);
      }
      if (result.ok || result.wifiConnected) await this.rememberCameraCard(result.ok && result.bleConnected);
      if (result.ok) {
        this.cam.cameraState = 2;
        // Keep the physical camera identity selected by BLE or USB. The first
        // downloaded thumbnail belongs to the gallery, never to this card.
        if (!startWifi && this.cam.cameraModel.length === 0) this.cam.cameraModel = 'LUMIX';
        if (!startWifi && result.thumbnailUri.length > 0 && this.cameraThumbnailUri.length === 0) {
          this.cameraThumbnailUri = result.thumbnailUri;
        }
        if (!startWifi && preferredDeviceName.length > 0) {
          try { await LumixImportPrototype.rememberCameraPairing(context, preferredDeviceName); } catch (_error) { }
          // Keep listening after the first registration so a later address
          // rotation is picked up without asking the user to pair again.
          this.startCameraBleDiscovery();
        }
        if (startWifi && !connectOnly && result.wifiConnected) this.selectedSection = 1;
      } else if (!startWifi || !result.bleConnected) {
        this.cam.cameraState = result.bleConnected || this.cameraUsbHandshakeComplete ? 2 : 0;
        if (!startWifi) this.cameraPairingAttempted = false;
        console.info('Lumix import trace: ' + result.trace.join(' | '));
      }
    } catch (_error) {
      if (!startWifi) {
        this.cam.cameraState = 0;
        this.cam.cameraBleStatus = '未连接';
      } else if (this.cam.cameraState !== 2) {
        this.cam.cameraBleStatus = '未连接';
      }
      this.cam.cameraWifiStatus = '未连接';
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = '验证原型异常，请查看 HiLog';
    } finally {
      if (startWifi) this.cam.cameraTransferInProgress = false;
    }
  }

  private transferProgress(): number {
    if (this.transfers.length === 0) return 0;
    let total = 0;
    for (let index = 0; index < this.transfers.length; index++) {
      total += this.transfers[index].progress;
    }
    return Math.round((total / this.transfers.length) * 100);
  }

  private videoFileExtensions: string[] = [
    'mov', 'mp4', 'm4v', 'avi', 'mpg', 'mpeg', 'mts', 'm2ts', '3gp', 'wmv', 'asf',
  ];

  private isVideoGalleryItem(item: LumixGalleryItem): boolean {
    const name = (item.originalFileName || '').toLowerCase();
    for (const extension of this.videoFileExtensions) {
      if (name.endsWith('.' + extension)) return true;
    }
    return false;
  }

  private showVideoNotSupported(fileName: string): void {
    const displayName = fileName && fileName.length > 0 ? fileName : '该文件';
    AppLogStore.add(`ui 视频调色不支持提示 ${displayName}`);
    try {
      this.getUIContext().showAlertDialog({
        title: '暂不支持视频预览',
        message: `${displayName} 是视频文件（MOV/MP4）。视频暂不支持在线预览与调色，可在列表勾选后下载保存到系统图库。`,
        autoCancel: true,
        alignment: DialogAlignment.Center,
        buttons: [
          {
            value: '知道了',
            action: () => {
            },
          },
        ],
      });
    } catch (_error) {
      this.showMessage(`${displayName} 是视频文件，勾选后可下载保存到图库`);
    }
  }

  private async openCameraImage(item: LumixGalleryItem): Promise<void> {
    if (this.cam.cameraPreviewLoading) return;
    if (this.isVideoGalleryItem(item)) {
      // Opening a movie must not download the full clip only to fail the
      // image decoder; explain the limitation up front.
      this.showVideoNotSupported(item.originalFileName || '');
      return;
    }
    this.cam.cameraPreviewVisible = true;
    this.cam.cameraPreviewLoading = true;
    this.cam.cameraPreviewUri = '';
    this.cam.cameraPreviewScale = 1;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let previewUri = '';
      if (this.isPtpIpCamera()) {
        if (this.cam.cameraBrand === 'Sony') {
          // Sony reaches its originals through SDIO_GetContentsData (0x923D),
          // not through the standard object-handle read NikonPtpIpService uses.
          previewUri = await SonyPtpIpContent.downloadOriginal(context, item.imageId,
            item.originalFileName || '', item.size || 0,
            (_progress: number, _received: number, _total: number): void => {});
        } else {
          previewUri = await NikonPtpIpService.downloadOriginal(context, {
            imageId: item.imageId,
            imageType: item.imageType,
            thumbnailUri: item.thumbnailUri,
            size: item.size,
            rawSize: item.rawSize,
            originalFileName: item.originalFileName,
            handle: NikonPtpIpService.handleOf(item.imageId),
          }, 9000, (_progress: number, _received: number, _total: number): void => {});
        }
      } else {
        previewUri = await LumixImportPrototype.downloadOriginal(context, item, 9000,
          (_progress: number, _received: number, _total: number): void => {});
      }
      this.cam.cameraPreviewUri = previewUri;
    } finally {
      this.cam.cameraPreviewLoading = false;
    }
  }

  private closeCameraPreview(): void {
    this.cam.cameraPreviewVisible = false;
    this.cam.cameraPreviewLoading = false;
    this.cam.cameraPreviewUri = '';
    this.cam.cameraPreviewScale = 1;
  }

  /**
   * itemKey 是 LumixImportPrototype.galleryItemKey(item)，即 imageId:imageType。
   * 同一次 RAW+JPEG 拍摄的 JPG 卡与 RW2 卡共用一个 ImageId，只用 ImageId 会
   * 让两张卡一起被选中、一起下载。
   */
  private toggleCameraGallerySelection(itemKey: string): void {
    const index = this.cam.selectedCameraImageIds.indexOf(itemKey);
    if (index >= 0) {
      this.cam.selectedCameraImageIds = this.cam.selectedCameraImageIds.filter((id: string) => id !== itemKey);
    } else {
      this.cam.selectedCameraImageIds = this.cam.selectedCameraImageIds.concat([itemKey]);
    }
  }

  /**
   * 合并两批图库条目并按 galleryItemKey 去重，保留先出现的那个。
   *
   * ForEach 的 id 生成函数就是 galleryItemKey，**id 重复会让 ArkUI 拒绝更新
   * 那些网格节点**——表现是缩略图"取回来了却不显示"，并伴随持续的
   * `Ids generated by the ForEach id gen function must be unique` 报错与卡顿。
   *
   * 旧的合并方式是「新页 filter 掉已有 key」，它有一个缺口：只看新页 vs 已有，
   * **从不检查新页自身内部的重复**。而 imageTypeOf 把 RAW/HEIF 都映射为 1，
   * 同一个 contentId 的多个文件（RAW+JPEG 等）会生成完全相同的 key，它们都不在
   * 已有列表里，于是全部通过 → 数组里出现重复 key。改成对合并结果整体去重，
   * 这一类重复（无论来自页内还是跨页）都无法再进入数组。
   */
  private mergeGalleryItems(
    current: LumixGalleryItem[], incoming: LumixGalleryItem[]): LumixGalleryItem[] {
    const merged: LumixGalleryItem[] = [];
    const seen = new Set<string>();
    for (const item of current.concat(incoming)) {
      const key = LumixImportPrototype.galleryItemKey(item);
      if (seen.has(key)) continue;
      seen.add(key);
      merged.push(item);
    }
    return merged;
  }

  private async fetchMoreCameraGallery(): Promise<void> {
    if (this.cam.cameraGalleryLoading || !this.cam.cameraGalleryHasMore || this.cam.cameraState !== 2) {
      hilog.info(0x0001, 'VIVID_RAWDBG', 'fetchMore skipped loading=%{public}d hasMore=%{public}d state=%{public}d',
        this.cam.cameraGalleryLoading ? 1 : 0, this.cam.cameraGalleryHasMore ? 1 : 0, this.cam.cameraState);
      return;
    }
    this.cam.cameraGalleryLoading = true;
    const seq = ++this.cameraGalleryRequestSeq;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (this.isPtpIpCamera()) {
        const fetchStartedAt = Date.now();
        if (this.cam.cameraBrand === 'Sony') {
          // Sony pages by creation time inside SonyPtpIpContent, which keeps
          // the current 100-entry contents page buffered and hands out slices.
          // The cursor is therefore not a handle index and this branch never
          // touches cameraGalleryNikonCursor.
          const sonyPage: SonyCatalogResult = await SonyPtpIpContent.next(6);
          if (seq !== this.cameraGalleryRequestSeq) return;
          if (!sonyPage.ok) {
            this.cam.cameraGalleryHasMore = false;
            this.cam.cameraMessage = sonyPage.message;
            return;
          }
          const sonyMapped: LumixGalleryItem[] = sonyPage.items.map((item: SonyContentEntry): LumixGalleryItem => ({
            imageId: item.contentId.toString(),
            imageType: SonyPtpIpContent.imageTypeOf(item),
            thumbnailUri: '',
            size: item.fileSize,
            rawSize: 0,
            originalFileName: SonyPtpIpContent.fileNameOf(item),
          }));
          const sonyMerged = this.mergeGalleryItems(this.cam.cameraGalleryItems, sonyMapped);
          const sonyAdded = sonyMerged.length - this.cam.cameraGalleryItems.length;
          if (sonyAdded > 0) {
            this.cam.cameraGalleryItems = sonyMerged;
            this.cameraGalleryPage += 1;
          }
          this.cam.cameraGalleryHasMore = sonyPage.hasMore;
          if (sonyAdded === 0 && sonyPage.items.length > 0) {
            // 整页都是已加载过的条目，说明游标没有真正前进。继续拉只会在同一页上
            // 空转（并触发持续的 ForEach 重渲染卡顿），就此收尾。
            this.cam.cameraGalleryHasMore = false;
          }
          NikonPtpIpService.log(`sony page result items=${sonyMapped.length} unique=${sonyAdded}` +
            ` loaded=${this.cam.cameraGalleryItems.length}` +
            ` discovered=${sonyPage.total} more=${this.cam.cameraGalleryHasMore ? 1 : 0} ms=${Date.now() - fetchStartedAt}`);
          this.startSonyThumbnailPump();
          if (this.cam.cameraGalleryHasMore &&
            (this.cam.cameraGalleryItems.length < 24 || this.cam.cameraGalleryAtBottomEdge)) {
            setTimeout(() => { this.fetchMoreCameraGallery(); }, 0);
          }
          return;
        }
        NikonPtpIpService.log(`ptpip page fetch cursor=${this.cameraGalleryNikonCursor} loaded=${this.cam.cameraGalleryItems.length} atEdge=${this.cam.cameraGalleryAtBottomEdge ? 1 : 0}`);
        const page: NikonPtpGalleryPage = await this.fetchNikonGalleryPage(context, this.cameraGalleryNikonCursor);
        if (seq !== this.cameraGalleryRequestSeq) return;
        NikonPtpIpService.log(`ptpip page result items=${page.items.length} next=${page.nextHandleIndex} remaining=${page.remaining} ms=${Date.now() - fetchStartedAt}`);
        const mapped: LumixGalleryItem[] = page.items.map((item: NikonPtpGalleryItem): LumixGalleryItem => ({
          imageId: item.imageId,
          imageType: item.imageType,
          thumbnailUri: item.thumbnailUri,
          size: item.size,
          rawSize: item.rawSize,
          originalFileName: item.originalFileName,
        }));
        const merged = this.mergeGalleryItems(this.cam.cameraGalleryItems, mapped);
        if (merged.length > this.cam.cameraGalleryItems.length) {
          this.cam.cameraGalleryItems = merged;
          this.cameraGalleryPage += 1;
        }
        // The cursor advances past classified-but-skipped handles, and only
        // unscanned handles decide hasMore - the previous items.length vs
        // total comparison stalled whenever a thumbnail failed.
        this.cameraGalleryNikonCursor = page.nextHandleIndex;
        this.cam.cameraGalleryHasMore = page.remaining > 0;
        // Two continuation reasons: (1) keep the gallery scrollable - a page
        // whose content fits the viewport can never fire onReachEnd or the
        // scroll watermark; (2) the user is resting at the bottom edge and
        // has no scrollable content below, so pagination must pull itself
        // forward until they scroll back up.
        if (this.cam.cameraGalleryHasMore &&
          (this.cam.cameraGalleryItems.length < 24 || this.cam.cameraGalleryAtBottomEdge)) {
          setTimeout(() => { this.fetchMoreCameraGallery(); }, 0);
        }
      } else {
        const requestStart = this.cameraGalleryNextStartIndex;
        hilog.info(0x0001, 'VIVID_RAWDBG', 'panasonic page request start=%{public}d loaded=%{public}d total=%{public}d',
          requestStart, this.cam.cameraGalleryItems.length, this.cam.cameraGalleryTotal);
        const next = await LumixImportPrototype.fetchGalleryPage(context, requestStart);
        if (seq !== this.cameraGalleryRequestSeq) return;
        if (next.length === 0) {
          hilog.info(0x0001, 'VIVID_RAWDBG', 'panasonic page empty start=%{public}d -> hasMore=false', requestStart);
          this.cam.cameraGalleryHasMore = false;
        } else {
          const merged = this.mergeGalleryItems(this.cam.cameraGalleryItems, next);
          const uniqueCount = merged.length - this.cam.cameraGalleryItems.length;
          this.cam.cameraGalleryItems = merged;
          // 这里**绝对不能**用已加载条目数去抬 cameraGalleryTotal。它是相机的
          // 「记录数」，RAW+JPEG 会把一条记录拆成两个条目，条目数天然大于记录
          // 数；而且倒序分页靠 nextStartIndex = total - 12 定位，抬高 total 会让
          // 下一次刷新从中间开始，直接跳过一半记录。单位不同，不可混用。
          this.cameraGalleryPage += 1;
          this.cameraGalleryNextStartIndex = Math.max(0, requestStart - 6);
          this.cam.cameraGalleryHasMore = requestStart > 0;
          // 落到文件而不只是 hilog：分页把 total 拖成 24/12 的那次，只有 hilog
          // 有记录，缓冲区一滚就查不到了。
          AppLogStore.add(`图库分页 起始=${requestStart} 本页=${next.length}`
            + ` 新增=${uniqueCount} 已加载=${this.cam.cameraGalleryItems.length}`
            + ` 总数=${this.cam.cameraGalleryTotal} 下次起始=${this.cameraGalleryNextStartIndex}`);
          hilog.info(0x0001, 'VIVID_RAWDBG', 'panasonic page next=%{public}d unique=%{public}d loaded=%{public}d cursor=%{public}d hasMore=%{public}d',
            next.length, uniqueCount, this.cam.cameraGalleryItems.length, this.cameraGalleryNextStartIndex,
            this.cam.cameraGalleryHasMore ? 1 : 0);
          // 同上：只在"一屏都填不满"时补一页；用户已经滑到底边时不问数量直接续拉。
          // 阈值 12 = 一页的量，不用 24，避免一进图库就把剩余照片全拉完。
          if (this.cam.cameraGalleryHasMore &&
            (this.cam.cameraGalleryItems.length < 12 || this.cam.cameraGalleryAtBottomEdge)) {
            setTimeout(() => { this.fetchMoreCameraGallery(); }, 0);
          }
        }
      }
    } catch (_error) {
      if (seq === this.cameraGalleryRequestSeq) {
        if (this.isPtpIpCamera() && !NikonPtpIpService.isSessionAlive() &&
          this.cameraWifiConnected()) {
          // The body can drop an idle command link between pages. Rebuild the
          // session and restart the gallery instead of stranding the user on
          // a dead end that keeps claiming "all photos loaded".
          NikonPtpIpService.log('ptpip session lost during pagination; reconnecting');
          this.cam.cameraMessage = '相机连接中断，正在重新建立会话…';
          await this.runNikonPtpGallery(false);
          return;
        }
        this.cam.cameraGalleryHasMore = false;
        if (this.isPtpIpCamera()) {
          this.cam.cameraMessage = this.cam.cameraBrand === 'Sony'
            ? '索尼图库分页读取失败，请重新连接后再试'
            : '尼康图库分页读取失败，请重新连接后再试';
        }
      }
    } finally {
      if (seq === this.cameraGalleryRequestSeq) this.cam.cameraGalleryLoading = false;
    }
  }

  /** Open the Nikon/Sony PTP/IP session and load the first six objects. */
  private async runNikonPtpGallery(openTransfer: boolean): Promise<void> {
    if (this.cameraHost.length === 0) {
      this.cam.cameraSessionStatus = '未建立';
      this.cam.cameraMessage = this.cam.cameraBrand === 'Sony'
        ? '已连接索尼 Wi‑Fi，但没有可用网关地址'
        : '已连接尼康 Wi‑Fi，但没有可用网关地址';
      return;
    }
    const seq = ++this.cameraGalleryRequestSeq;
    this.cam.cameraTransferInProgress = true;
    this.cam.cameraSessionStatus = '认证中';
    this.cam.cameraGalleryLoading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (this.cam.cameraBrand === 'Sony') {
        // Sony bodies reject the standard storage/object-handle browse (the app
        // saw a vendor 0x2013 from GetStorageIDs), so the Sony route switches
        // the body into contents-transfer mode and reads Sony's private
        // contents list. Enumeration only: no thumbnail and no file bytes yet,
        // which is why every item carries an empty thumbnailUri.
        const opened = await SonyPtpIpContent.open(this.cameraHost);
        if (seq !== this.cameraGalleryRequestSeq) return;
        if (!opened.ok) {
          this.cam.cameraSessionStatus = '未建立';
          this.cam.cameraMessage = opened.message;
          // 失败现场立刻取证：此刻手机多半还挂在相机热点上，过了这一刻证据就没了。
          const hint = await this.runSonyDiagnostics('browse');
          this.cam.cameraMessage = hint.length > 0 ? `${opened.message}｜${hint}` : opened.message;
          return;
        }
        // 双卡槽：只有在 open() 的属性转储之后才读得到索尼自己的
        // `MediaSLOT1Status` (0xD248) / `MediaSLOT2Status` (0xD256)。未知时把
        // source 置 'none'，选择器便不禁用任何槽——失败/未知不等于"无卡"。
        this.cam.cameraSd1Present = SonyPtpIpContent.slotUsable(SonyPtpIpContent.SLOT_1);
        this.cam.cameraSd2Present = SonyPtpIpContent.slotUsable(SonyPtpIpContent.SLOT_2);
        this.cam.cameraSdPresenceSource = SonyPtpIpContent.slotPresenceKnown()
          ? 'sony-property' : 'none';
        this.cam.selectedSd = SonyPtpIpContent.currentSlot() === SonyPtpIpContent.SLOT_2
          ? 'SD2' : 'SD1';
        const first: SonyCatalogResult = await SonyPtpIpContent.next(6);
        if (seq !== this.cameraGalleryRequestSeq) return;
        if (!first.ok) {
          this.cam.cameraSessionStatus = '未建立';
          this.cam.cameraMessage = first.message;
          return;
        }
        const sonyFirst: LumixGalleryItem[] = first.items.map((item: SonyContentEntry): LumixGalleryItem => ({
          imageId: item.contentId.toString(),
          imageType: SonyPtpIpContent.imageTypeOf(item),
          thumbnailUri: '',
          size: item.fileSize,
          rawSize: 0,
          originalFileName: SonyPtpIpContent.fileNameOf(item),
        }));
        this.cam.cameraGalleryItems = this.mergeGalleryItems([], sonyFirst);
        this.cam.cameraGalleryTotal = first.total;
        this.cameraGalleryPage = 1;
        this.cameraGalleryNextStartIndex = 0;
        this.cameraGalleryNikonCursor = 0;
        this.cam.cameraGalleryHasMore = first.hasMore;
        this.cameraGalleryScrollOffset = 0;
        this.cameraGalleryLastScrollY = 0;
        this.cam.cameraGalleryAtBottomEdge = false;
        this.cam.selectedCameraImageIds = [];
        this.cam.cameraSessionStatus = '已建立';
        this.cam.cameraMessage = first.message;
        if (openTransfer) this.selectedSection = 1;
        // Fill the grid's thumbnails in the background; enumeration only handed
        // us content ids, file ids and names.
        this.startSonyThumbnailPump();
        if (this.cam.cameraGalleryHasMore && this.cam.cameraGalleryItems.length < 24) {
          setTimeout(() => { this.fetchMoreCameraGallery(); }, 0);
        }
        return;
      }
      // USB 会话在用时走 USB 枚举（操作码与 PTP/IP 完全一致，结果同形）。
      const result: NikonPtpCatalogResult = NikonUsbPtp.isOpen()
        ? await NikonUsbPtp.listGallery(context, 6)
        : await NikonPtpIpService.listGallery(context, this.cameraHost, 6);
      if (seq !== this.cameraGalleryRequestSeq) return;
      if (!result.ok) {
        this.cam.cameraSessionStatus = '未建立';
        this.cam.cameraMessage = result.message;
        return;
      }
      this.cam.cameraGalleryItems = result.items.map((item: NikonPtpGalleryItem): LumixGalleryItem => ({
        imageId: item.imageId,
        imageType: item.imageType,
        thumbnailUri: item.thumbnailUri,
        size: item.size,
        rawSize: item.rawSize,
        originalFileName: item.originalFileName,
        // 卡号必须一路带到界面：切卡就是按它过滤。丢掉它的话，卡 1 / 卡 2 的
        // 照片会混在一个列表里，而两张卡的句柄空间独立、同号句柄连缩略图都会
        // 互相覆盖。
        storageId: item.storageId,
      }));
      this.cam.cameraGalleryTotal = result.total;
      // 卡槽列表由相机上报，**含空卡**——界面据此决定显示几个切换按钮。
      this.cam.nikonStorageIds = result.storageIds === undefined ? [] : result.storageIds;
      this.cameraGalleryPage = 1;
      this.cameraGalleryNextStartIndex = 0;
      this.cameraGalleryNikonCursor = result.nextHandleIndex;
      this.cam.cameraGalleryHasMore = result.remaining > 0;
      this.cameraGalleryScrollOffset = 0;
      this.cameraGalleryLastScrollY = 0;
      this.cam.cameraGalleryAtBottomEdge = false;
      this.cam.selectedCameraImageIds = [];
      this.cam.cameraSessionStatus = '已建立';
      this.cam.cameraMessage = result.message;
      if (openTransfer) this.selectedSection = 1;
    } finally {
      if (seq === this.cameraGalleryRequestSeq) {
        this.cam.cameraGalleryLoading = false;
        this.cam.cameraTransferInProgress = false;
      }
    }
    // Only the success path reaches here (every failure returns inside try).
    // A six-item first page can be shorter than the viewport, which would
    // leave the gallery with no scrollable content and therefore no way to
    // trigger pagination. Prefetch in the background until it overflows.
    if (this.cam.cameraGalleryHasMore && this.cam.cameraGalleryItems.length < 24) {
      setTimeout(() => { this.fetchMoreCameraGallery(); }, 0);
    }
  }

  private async fetchNikonGalleryPage(context: common.UIAbilityContext, fromHandleIndex: number): Promise<NikonPtpGalleryPage> {
    // USB 会话在用时按 USB 的游标翻页；两者返回同一种 page，界面无感。
    const useUsb = NikonUsbPtp.isOpen();
    let page: NikonPtpGalleryPage = useUsb
      ? await NikonUsbPtp.fetchPageAfter(context, fromHandleIndex, 6)
      : await NikonPtpIpService.fetchPageAfter(context, fromHandleIndex, 6);
    let guard = 0;
    // A scan page can legitimately come back empty when its whole budget was
    // spent on directories or unusable objects. Keep advancing the cursor
    // until at least one item is found or the handle list is exhausted.
    while (page.items.length === 0 && page.remaining > 0 && guard < 12) {
      page = useUsb
        ? await NikonUsbPtp.fetchPageAfter(context, page.nextHandleIndex, 6)
        : await NikonPtpIpService.fetchPageAfter(context, page.nextHandleIndex, 6);
      guard += 1;
    }
    return page;
  }

  /**
   * Sony thumbnail pump.
   *
   * The enumeration hands the gallery items with an empty `thumbnailUri`; the
   * Nikon path fills that field during its handle scan, and Sony has no handle
   * scan. `SDIO_GetContentsCompressedData` (0x923E) is a separate operation per
   * file, so the pump walks the gallery one item at a time, writes each image to
   * the sandbox and patches the item's URI. Requests go through the same
   * serialised command queue as paging, so a page fetch and a thumbnail can
   * never interleave on the wire.
   *
   * The pump stops on its own when the gallery has no un-filled item left, when
   * the contents session closes, or when a download starts (the download's own
   * `startSonyThumbnailPump` call resumes it afterwards). A file the camera
   * refuses is remembered so the pump does not retry it forever.
   */
  private startSonyThumbnailPump(): void {
    if (this.cam.cameraBrand !== 'Sony') return;
    if (this.sonyThumbnailPumpRunning) return;
    this.sonyThumbnailPumpRunning = true;
    const seq = ++this.sonyThumbnailPumpSeq;
    this.runSonyThumbnailPump(seq);
  }

  private runSonyThumbnailPump(seq: number): void {
    const loop = async (): Promise<void> => {
      while (seq === this.sonyThumbnailPumpSeq && SonyPtpIpContent.isOpen()) {
        // A download must not queue behind a long thumbnail walk.
        if (this.cam.cameraDownloadInProgress) return;
        // Pick the next un-filled item as plain values, so nothing has to be
        // re-resolved after the await below.
        let wantedImageId = '';
        let wantedImageType = 0;
        let wantedName = '';
        for (const item of this.cam.cameraGalleryItems) {
          if (item.thumbnailUri.length > 0) continue;
          if (this.sonyThumbnailFailedKeys.has(LumixImportPrototype.galleryItemKey(item))) continue;
          wantedImageId = item.imageId;
          wantedImageType = item.imageType;
          wantedName = item.originalFileName || '';
          break;
        }
        if (wantedImageId.length === 0) return;
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const uri = await SonyPtpIpContent.fetchThumbnailFile(context, wantedImageId, wantedName);
        if (seq !== this.sonyThumbnailPumpSeq) return;
        if (uri.length === 0) {
          // Remember the refusal so one unusable file cannot stall the queue.
          this.sonyThumbnailFailedKeys.add(`${wantedImageId}:${wantedImageType}`);
        } else {
          this.applySonyThumbnail(wantedImageId, wantedImageType, uri);
        }
      }
    };
    const settled = (): void => {
      if (seq === this.sonyThumbnailPumpSeq) this.sonyThumbnailPumpRunning = false;
    };
    loop().then(settled, settled);
  }

  /** Stops the pump and invalidates any thumbnail still in flight. */
  private stopSonyThumbnailPump(): void {
    if (this.cam.cameraBrand === 'Sony') {
      // Logged before the Sony session state (and its counters) is dropped.
      NikonPtpIpService.log(SonyPtpIpContent.transferSummary());
    }
    this.sonyThumbnailPumpSeq += 1;
    this.sonyThumbnailPumpRunning = false;
    this.sonyThumbnailFailedKeys = new Set<string>();
  }

  /** Replaces the exact grid item, which is what re-renders its `Image`. */
  private applySonyThumbnail(imageId: string, imageType: number, uri: string): void {
    this.cam.cameraGalleryItems = this.cam.cameraGalleryItems.map(
      (item: LumixGalleryItem): LumixGalleryItem => {
        if (item.imageId !== imageId || item.imageType !== imageType) return item;
        return {
          imageId: item.imageId,
          imageType: item.imageType,
          thumbnailUri: uri,
          size: item.size,
          rawSize: item.rawSize,
          originalFileName: item.originalFileName,
        };
      });
  }

  private async downloadSelectedCameraPhotos(): Promise<void> {
    if (this.cam.selectedCameraImageIds.length === 0) return;
    if (this.cam.cameraDownloadInProgress) return;
    this.cam.cameraDownloadInProgress = true;
    this.cam.cameraDownloadProgress = 0;
    this.cam.cameraDownloadStatus = '准备下载原始文件…';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const manager = abilityAccessCtrl.createAtManager();
      const permissionResult = await manager.requestPermissionsFromUser(context, ['ohos.permission.WRITE_IMAGEVIDEO']);
      if (permissionResult.authResults.length === 0 || permissionResult.authResults[0] !== 0) {
        this.showMessage('需要「保存到相册」权限才能下载');
        return;
      }
      let saved = 0;
      let savedVideos = 0;
      let failed = 0;
      let index = 0;
      const selectedCount = this.cam.selectedCameraImageIds.length;
      let totalDownloadCount = selectedCount;
      // One gallery item can describe a JPEG+RW2 pair. The Lab endpoint uses
      // the same ImageId for both representations, so count the companion RAW
      // as a separate download task and preserve its progress accurately.
      if (!this.isPtpIpCamera()) {
        for (const candidate of this.cam.cameraGalleryItems) {
          const selected = this.cam.selectedCameraImageIds.indexOf(LumixImportPrototype.galleryItemKey(candidate)) >= 0;
          const pairedRaw = candidate.imageType === 2 && candidate.rawSize !== undefined && candidate.rawSize > 0;
          if (selected && pairedRaw && !this.isVideoGalleryItem(candidate)) totalDownloadCount++;
        }
      }
      const nikonEpoch = NikonPtpIpService.epoch();
      for (const item of this.cam.cameraGalleryItems) {
        if (this.cam.selectedCameraImageIds.indexOf(LumixImportPrototype.galleryItemKey(item)) < 0) continue;
        const isVideo = this.isVideoGalleryItem(item);
        const pairedRaw = !this.isPtpIpCamera() && !isVideo && item.imageType === 2 &&
          item.rawSize !== undefined && item.rawSize > 0;
        // A Nikon/Sony session teardown or reconnect during the batch must
        // stop the loop instead of hammering a dead session for the rest of
        // the selection.
        if (this.isPtpIpCamera() && NikonPtpIpService.epoch() !== nikonEpoch) break;
        const current = index;
        this.cam.cameraDownloadStatus = `正在下载 ${current + 1}/${totalDownloadCount} · ${this.cameraFileName(item)}`;
        let originalUri = '';
        if (this.isPtpIpCamera()) {
          if (this.cam.cameraBrand === 'Sony') {
            // Sony: SDIO_GetContentsData (0x923D), addressed by the
            // (slot, fileId, contentId) unique id Sony builds in
            // transfer/ptp/PtpPullItem.java:392-393.
            originalUri = await SonyPtpIpContent.downloadOriginal(context, item.imageId,
              item.originalFileName || '', item.size || 0,
              (progress: number): void => {
                this.cam.cameraDownloadProgress = Math.min(100, Math.round(((current + progress / 100) / totalDownloadCount) * 100));
              });
          } else {
            // USB 直连时用 USB 传输下载（同一套操作码，只是外层走 bulk 容器）。
            originalUri = NikonUsbPtp.isOpen()
              ? await NikonUsbPtp.downloadOriginal(context, item.imageId,
                item.originalFileName ?? '', current,
                (progress: number): void => {
                  this.cam.cameraDownloadProgress = Math.min(100, Math.round(((current + progress / 100) / totalDownloadCount) * 100));
                })
              : await NikonPtpIpService.downloadOriginal(context, {
              imageId: item.imageId,
              imageType: item.imageType,
              thumbnailUri: item.thumbnailUri,
              size: item.size,
              rawSize: item.rawSize,
              originalFileName: item.originalFileName,
              handle: NikonPtpIpService.handleOf(item.imageId),
            }, current,
              (progress: number): void => {
                this.cam.cameraDownloadProgress = Math.min(100, Math.round(((current + progress / 100) / totalDownloadCount) * 100));
              });
          }
        } else {
          originalUri = await LumixImportPrototype.downloadOriginal(context, item, current,
            (progress: number): void => {
              this.cam.cameraDownloadProgress = Math.min(100, Math.round(((current + progress / 100) / totalDownloadCount) * 100));
            });
        }
        index++;
        if (originalUri.length === 0) {
          failed++;
          // If the JPEG representation is temporarily unavailable, still try
          // its separately addressable RW2 companion instead of dropping it.
          if (pairedRaw) {
            const rawCurrent = index;
            index++;
            const rawSaved = await this.downloadAndImportLumixRaw(context, item, rawCurrent, totalDownloadCount);
            if (rawSaved) saved++;
            else failed++;
          }
          continue;
        }
        try {
          const sourcePath = originalUri.replace(/^file:\/\//, '');
          const extension = isVideo ? this.videoFileExtension(item) : this.cameraFileExtension(item);
          const helper = photoAccessHelper.getPhotoAccessHelper(context);
          const uri = await helper.createAsset(
            isVideo ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE,
            extension, { title: this.cameraFileTitle(item, current) });
          let writtenBytes = 0;
          // 视频和相机直接返回的 RAW 都可能很大，统一分块写入媒体库，
          // 避免把完整原片读入 ArrayBuffer 而导致内存峰值或下载失败。
          // Sony ARW originals routinely exceed 50 MB, so the Sony line streams
          // as well; Nikon NEF originals are the same size class over the same
          // PTP/IP transport, so it streams too. The Panasonic conditions are
          // unchanged.
          const streamingImport = isVideo || this.cam.cameraBrand === 'Sony' ||
            this.cam.cameraBrand === 'Nikon' ||
            (!this.isPtpIpCamera() && item.imageType !== 2);
          if (streamingImport) {
            writtenBytes = await this.copyFileChunked(sourcePath, uri);
          } else {
            const source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
            const buffer = new ArrayBuffer(fileIo.statSync(sourcePath).size);
            fileIo.readSync(source.fd, buffer);
            fileIo.closeSync(source);
            const output = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
            fileIo.writeSync(output.fd, buffer);
            fileIo.closeSync(output);
            writtenBytes = buffer.byteLength;
          }
          // The media provider may still be flushing a freshly created asset;
          // guard the verification stat so a logging miss never fails an
          // otherwise successful import.
          try { writtenBytes = fileIo.statSync(uri).size; } catch (_statError) {
          }
          hilog.info(0x0001, 'VIVID_IMPORT', 'import asset name=%{public}s ext=%{public}s video=%{public}d written=%{public}d',
            this.cameraFileName(item), extension, isVideo ? 1 : 0, writtenBytes);
          // 媒体库落盘成功后清掉沙箱下载中间文件，避免每张原图残留一份副本。
          // **在删之前先读一次 EXIF 方向**：沙箱文件一定能读，媒体库 URI 在部分
          // ROM 上读不到 EXIF；抓到这个方向后往下传，竖拍图才不会在「最近作品」
          // 和打开后的编辑页里横置（尼康线下载的原图走的就是这条路）。
          let exifOrientation = 0;
          if (!isVideo) {
            try {
              exifOrientation = await ExifOrientation.read(`file://${sourcePath}`);
            } catch (_orientationError) {
              exifOrientation = 0;
            }
          }
          // 方向诊断：沙箱文件**一定能读**，所以这里读到的就是「文件里到底有没有
          // 方向」。之后卡片/编辑页读的是媒体库 URI，读不到时全靠这个值兜底；
          // 一旦这里是 1 而画面明明是竖的，说明相机根本没写 EXIF，得另找来源。
          hilog.info(0x0001, 'VIVID_IMPORT',
            'import orientation name=%{public}s exif=%{public}d item=%{public}d',
            this.cameraFileName(item), exifOrientation, item.orientation ?? 0);
          try { fileIo.unlinkSync(sourcePath); } catch (_unlinkError) {
          }
           // The downloaded camera original is now also a recent-work item.
           // Keep the gallery URI as the durable source and use the camera's
           // filename so the home card preserves its extension.
            // A completed JPEG original must generate its card from the saved
            // gallery asset. Passing the camera thumbnail here could make a
            // successful full-size download look like a thumbnail-only import.
            // RAW keeps the camera JPEG as a temporary preview while its own
            // embedded preview is decoded in the background.
            const fallbackThumbUri = !this.isPtpIpCamera() && item.imageType !== 2 ? item.thumbnailUri : '';
            await this.addImportedPhoto(uri, this.cameraFileName(item), fallbackThumbUri,
              exifOrientation > 1 ? exifOrientation : (item.orientation ?? 0));
            if (isVideo) {
              savedVideos++;
            } else {
              saved++;
            }
         } catch (_error) {
           hilog.error(0x0001, 'VIVID_IMPORT', 'import asset failed name=%{public}s code=%{public}s',
             this.cameraFileName(item), String(_error));
           failed++;
         }
        // A Type=2 gallery entry with RawSize carries a separately addressable
        // RW2 companion. JPEG is imported first so its thumbnail can be used
        // immediately by the RAW recent-work card.
        if (pairedRaw) {
          const rawCurrent = index;
          index++;
          const rawSaved = await this.downloadAndImportLumixRaw(context, item, rawCurrent, totalDownloadCount);
          if (rawSaved) saved++;
          else failed++;
        }
      }
      const summary: string[] = [];
      if (saved > 0) summary.push(`已保存 ${saved} 张原图`);
      if (savedVideos > 0) summary.push(`${savedVideos} 个视频`);
      if (failed > 0) summary.push(`${failed} 个失败`);
      this.showMessage(summary.length > 0 ? summary.join('，') : '没有可下载的文件');
      this.cam.selectedCameraImageIds = [];
      if (this.cam.cameraBrand === 'Sony') {
        NikonPtpIpService.log(SonyPtpIpContent.transferSummary());
      }
      // The media provider can reject reads on a just-created asset for a
      // moment (EPERM), so both NEF and JPG first-decode attempts may fail.
      // Retry any missing recent-work thumbnails through the background
      // repair pass once the asset records are committed.
      setTimeout(() => { this.repairMissingThumbnails(); }, 600);
    } catch (_error) {
      this.showMessage('图片保存失败，请检查图库权限');
    } finally {
      this.cam.cameraDownloadProgress = 100;
      this.cam.cameraDownloadStatus = '下载完成';
      setTimeout(() => {
        this.cam.cameraDownloadInProgress = false;
        // The pump yields to a download; hand the grid back to it.
        this.startSonyThumbnailPump();
        if (this.cam.cameraBrand === 'Sony') {
          NikonPtpIpService.log(SonyPtpIpContent.transferSummary());
        }
      }, 350);
    }
  }

  private async downloadAndImportLumixRaw(context: common.UIAbilityContext, item: LumixGalleryItem,
    current: number, total: number): Promise<boolean> {
    const rawName = LumixImportPrototype.originalFileNameFor(item, true);
    this.cam.cameraDownloadStatus = `正在下载 ${current + 1}/${total} · ${rawName}`;
    const originalUri = await LumixImportPrototype.downloadOriginal(context, item, current,
      (progress: number): void => {
        this.cam.cameraDownloadProgress = Math.min(100, Math.round(((current + progress / 100) / total) * 100));
      }, true);
    if (originalUri.length === 0) return false;
    try {
      const sourcePath = originalUri.replace(/^file:\/\//, '');
      const dot = rawName.lastIndexOf('.');
      const title = dot > 0 ? rawName.substring(0, dot) : rawName;
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'rw2', {
        title: title.length > 0 ? title : `VIVID_LUMIX_${current + 1}`,
      });
      const writtenBytes = await this.copyFileChunked(sourcePath, uri);
      hilog.info(0x0001, 'VIVID_IMPORT', 'import raw asset name=%{public}s bytes=%{public}d', rawName, writtenBytes);
      try { fileIo.unlinkSync(sourcePath); } catch (_unlinkError) {
      }
      // The pairing JPEG thumbnail remains the immediate card preview while
      // the raw decoder prepares the embedded preview in the background.
      await this.addImportedPhoto(uri, rawName, item.thumbnailUri, item.orientation ?? 0);
      return true;
    } catch (_error) {
      hilog.error(0x0001, 'VIVID_IMPORT', 'import raw asset failed name=%{public}s code=%{public}s', rawName, String(_error));
      return false;
    }
  }
  private cameraFileName(item: LumixGalleryItem): string {
    if (!this.isPtpIpCamera() && item.imageType !== 2) {
      return LumixImportPrototype.originalFileNameFor(item, true);
    }
    return item.originalFileName && item.originalFileName.length > 0 ? item.originalFileName : `相机图片 ${item.imageType}`;
  }

  private cameraFileExtension(item: LumixGalleryItem): string {
    if (!this.isPtpIpCamera() && item.imageType !== 2) return 'rw2';
    const name = item.originalFileName || '';
    const extension = this.extensionFromName(name);
    // OriginalFileName is supplied by the camera gallery API and is the
    // authoritative format for Sony/Canon/Nikon/Panasonic files. Only accept
    // a safe extension so a malformed response cannot become a path suffix.
    const knownImageExtensions: string[] = [
      'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'tif', 'tiff',
      'raw', 'rw2', 'rwl', 'raf', 'crw', 'cr2', 'cr3', 'nef', 'nrw', 'arw', 'srf', 'sr2',
      'orf', 'srw', 'dng', 'pef', 'r3d', '3fr', 'iiq', 'x3f', 'erf', 'kdc', 'mrw', 'bay',
      'cap', 'eip', 'mef', 'mos', 'ptx', 'pxn', 'qtk', 'ari',
    ];
    if (knownImageExtensions.indexOf(extension) >= 0) return extension;
    if (item.imageType === 1) return 'rw2';
    if (item.imageType === 6) return 'heif';
    if (item.imageType === 7) return 'rw2';
    return 'jpg';
  }

  private cameraFileTitle(item: LumixGalleryItem, index: number): string {
    const name = this.cameraFileName(item);
    const dot = name.lastIndexOf('.');
    const base = dot > 0 ? name.substring(0, dot) : name;
    return base.length > 0 ? base : `VIVID_LUMIX_${index + 1}`;
  }

  /** 视频资产扩展名：OriginalFileName 缺失或不可识别时按 MP4 落库。 */
  private videoFileExtension(item: LumixGalleryItem): string {
    const extension = this.extensionFromName(item.originalFileName || '');
    if (this.videoFileExtensions.indexOf(extension) >= 0) return extension;
    return 'mp4';
  }

  /** 大文件（视频原片）分块写入媒体库资产，避免整文件 ArrayBuffer 撑爆内存。 */
  private async copyFileChunked(sourcePath: string, targetUri: string): Promise<number> {
    const source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
    const output = fileIo.openSync(targetUri, fileIo.OpenMode.WRITE_ONLY);
    const chunk = new ArrayBuffer(8 * 1024 * 1024);
    let copied = 0;
    try {
      while (true) {
        const read = fileIo.readSync(source.fd, chunk);
        if (read <= 0) break;
        fileIo.writeSync(output.fd, read === chunk.byteLength ? chunk : chunk.slice(0, read));
        copied += read;
        // 让出主线程，避免长时间同步拷贝卡住下载进度 UI。
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
    } finally {
      fileIo.closeSync(source);
      fileIo.closeSync(output);
    }
    return copied;
  }

  private async loadFreeSpace(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const freeBytes = await statfs.getFreeSize(context.filesDir);
      this.freeSpaceText = `${(freeBytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
    } catch (_error) {
      this.freeSpaceText = '—';
    }
  }

  /** S5 被动接收的文件先写入系统媒体库（图库可见、卸载不丢），沙箱临时
   * 文件仅在媒体库写入失败时作为最近作品的兜底来源。RAW 卡片沿用配对
   * JPEG 作缩略图（媒体库 URI 不可用时由内嵌预览路径接管）。 */
  private async importS5ReceivedFile(file: PanasonicS5ReceivedFile): Promise<void> {
    const extension = file.extension.toLowerCase();
    // 推送线此前把视频也建成 IMAGE 资产（图库里是损坏占位）；按扩展名分流。
    const isVideo = this.videoFileExtensions.indexOf(extension) >= 0;
    const fallbackThumbFor = (uri: string): string => {
      if (extension === 'jpg' || extension === 'jpeg') this.s5LastReceivedJpegUri = uri;
      return (extension === 'rw2' || extension === 'raw' || extension === 'nef' || extension === 'arw')
        ? this.s5LastReceivedJpegUri : '';
    };
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const dot = file.name.lastIndexOf('.');
      const title = dot > 0 ? file.name.substring(0, dot) : file.name;
      // 被动推送的文件是相机原始字节：扫描镜头信息作为对照基准——
      // 与 DMS 拉取（DO*）的字节比对，判断拉取侧是否被精简 EXIF。
      LumixSyncImageTransfer.scanLensEvidence(file.path);
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const uri = await helper.createAsset(
        isVideo ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE,
        extension, { title: title });
      let writtenBytes = 0;
      if (isVideo) {
        writtenBytes = await this.copyFileChunked(file.path, uri);
      } else {
        const size = fileIo.statSync(file.path).size;
        const source = fileIo.openSync(file.path, fileIo.OpenMode.READ_ONLY);
        const buffer = new ArrayBuffer(size);
        fileIo.readSync(source.fd, buffer);
        fileIo.closeSync(source);
        const output = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
        fileIo.writeSync(output.fd, buffer);
        fileIo.closeSync(output);
        writtenBytes = buffer.byteLength;
      }
      hilog.info(0x0001, 'VIVID_IMPORT', 's5 import asset name=%{public}s ext=%{public}s video=%{public}d bytes=%{public}d',
        file.name, extension, isVideo ? 1 : 0, writtenBytes);
      const fallback = fallbackThumbFor(uri);
      await this.addImportedPhoto(uri, file.name, fallback);
      try { fileIo.unlinkSync(file.path); } catch (_unlinkError) {
      }
    } catch (_error) {
      hilog.error(0x0001, 'VIVID_IMPORT', 's5 import asset failed name=%{public}s code=%{public}s',
        file.name, String(_error));
      const uri = `file://${file.path}`;
      const fallback = fallbackThumbFor(uri);
      await this.addImportedPhoto(uri, file.name, fallback);
    }
    // 与下载路线一致：媒体库刚建 asset 可能短暂拒绝读取，延迟重试补缩略图。
    setTimeout(() => { this.repairMissingThumbnails(); }, 600);
  }

  build() {
    // 「发现新相机」卡片是页面内覆盖层：玻璃模糊需要身后有页面内容可取样，
    // 所以放在相机页自己的 Stack 里，而不是另开一个弹窗子窗口。
    Stack() {
      this.CameraContent();
      if (this.newCameraCardKey.length > 0) {
        this.NewCameraDiscoveredCard();
      }
    }
    .width('100%')
    .height('100%');
  }
}

/** LUMIX Sync 连接进度弹窗：模态不可取消，实时显示当前步骤与已等待秒数。
 *  相机在配对确认后会重启自身 Wi-Fi（约 40 秒），没有持续反馈用户极易
 *  误判为连接失败而中途放弃。 */
@CustomDialog
struct SyncPairProgressDialog {
  controller?: CustomDialogController;
  // @CustomDialog 挂载在独立弹窗上下文，@Link 无法与页面建立双向绑定
  // （SynchedPropertyTwoWayPU 抛 TypeError 直接杀进程，2026-09-25 线索：
  // CameraPage.ets:3971）。@StorageLink 经 AppStorage 全局键同步，弹窗
  // 与页面各挂一份即可实时刷新。
  @StorageLink('syncPairDialogStatus') status: string = '';
  @State private elapsedSeconds: number = 0;
  private timerId: number = -1;

  aboutToAppear(): void {
    this.timerId = setInterval((): void => {
      this.elapsedSeconds += 1;
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  build() {
    Column() {
      Text('正在连接相机')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.vivid_text_1b2536'))
        .fontFamily('HarmonyOS Sans')
        .width('100%')
        .textAlign(TextAlign.Center);
      LoadingProgress()
        .width(44)
        .height(44)
        .color('#5262EC')
        .margin({ top: 18 });
      Text(this.status)
        .fontSize(14)
        .fontColor($r('app.color.vivid_text_334158'))
        .fontFamily('HarmonyOS Sans')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 14 });
      Text(`已等待 ${this.elapsedSeconds} 秒 · 全程约 1-2 分钟，期间相机会重启 Wi-Fi，请保持相机开机`)
        .fontSize(11)
        .fontColor($r('app.color.vivid_text_8a95a5'))
        .fontFamily('HarmonyOS Sans')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 10 });
    }
    .width(300)
    .padding(24)
    .backgroundColor($r('app.color.vivid_surface_ffffff'))
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center);
  }
}

/**
 * 固件更新进度弹窗：模态、不可取消，全程锁定界面。
 *
 * 为什么必须锁：固件写入不可逆，中途断开连接、关相机电源或取卡都可能让相机
 * 无法启动；而整个流程要跨五个阶段（蓝牙读版本 → 联网拉包 → 解压 → 重连相机
 * Wi-Fi → 分块传输），既有十几秒的空窗也有 143 MB 的下载，进度只写在页面底部
 * 小字里时用户看不到进展，也照样能点到别的入口，把正在进行的传输打断。
 *
 * 因此：不给取消按钮（`autoCancel: false` + 无按钮），点击遮罩不关闭。
 * 百分比 -1 表示该阶段没有有意义的进度（如系统 Wi-Fi 关联），退回转圈。
 * 状态经 AppStorage 键同步——@CustomDialog 是独立上下文，@Link 无法与页面
 * 双向绑定（见 SyncPairProgressDialog 上方注释）。
 */
@CustomDialog
struct FirmwareUpdateProgressDialog {
  controller?: CustomDialogController;
  @StorageLink('firmwareDialogStatus') status: string = '';
  @StorageLink('firmwareDialogPercent') percent: number = -1;

  build() {
    Column() {
      Text('正在更新相机固件')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.vivid_text_1b2536'))
        .fontFamily('HarmonyOS Sans')
        .width('100%')
        .textAlign(TextAlign.Center);
      if (this.percent >= 0) {
        Progress({ value: this.percent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .margin({ top: 18 });
        Text(`${this.percent}%`)
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .fontFamily('HarmonyOS Sans')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 8 });
      } else {
        LoadingProgress()
          .width(44)
          .height(44)
          .color('#5262EC')
          .margin({ top: 18 });
      }
      Text(this.status)
        .fontSize(14)
        .fontColor($r('app.color.vivid_text_334158'))
        .fontFamily('HarmonyOS Sans')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 14 });
      Text('过程中请勿关闭相机电源、断开连接或取出存储卡，否则可能导致相机无法启动')
        .fontSize(11)
        .fontColor($r('app.color.vivid_text_8a95a5'))
        .fontFamily('HarmonyOS Sans')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 12 });
    }
    .width(300)
    .padding(24)
    .backgroundColor($r('app.color.vivid_surface_ffffff'))
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center);
  }
}
