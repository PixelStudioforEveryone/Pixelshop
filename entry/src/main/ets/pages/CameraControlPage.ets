import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { sensor } from '@kit.SensorServiceKit';
import { VividMaterial } from '../components/VividMaterial';
import { LumixImportPrototype } from '../services/LumixImportPrototype';
import { LumixSyncControlService, LumixSyncCamCmdResult, LumixSyncStateParams, SyncMenuItem } from '../services/LumixSyncControlService';
import { CameraSessionStore } from '../services/CameraSessionStore';
import { NikonPtpIpService } from '../services/NikonPtpIpService';
import { NikonCameraParameters, NikonProp, NikonPropertyState, PTP_FORM_ENUM, PTP_FORM_RANGE } from '../services/NikonCameraParameters';
import { SonyLiveView, SonyLiveViewStart } from '../services/SonyLiveView';
import { SonyPtpIpContent } from '../services/SonyPtpIpContent';
import { SonyPtpIpControl } from '../services/SonyPtpIpControl';
import { CameraControlBrand } from '../services/CameraControlBrand';
import { AppLogStore } from './home/HomeShared';
import { LumixControlService, LumixControlSession, LumixControlError, LumixSettingOption,
  LumixCameraState, LumixLiveviewFrame, LumixLiveviewInfo, LumixLiveviewReceiver,
  hexWord, parseHexValue, shutterNumerator, shutterOptionLabel, evOptionValue, evThirdsOf,
  SettingOptionEntry,
  formatEv, isoLabelOf, wbLabelOf, qualityLabelOf, aspectLabelOf, meteringLabelOf,
  lvQualityLabelOf, modeLabelOf, APERTURE_STOP_COUNT, apertureIndexOf,
  pictureFormatLabelOf, photoStyleLabelOf } from '../services/LumixControlService';

/**
 * Remote camera control for LUMIX bodies over their camera AP. Two protocol
 * lines share this page: Lab bodies (remote/* + Bearer + DTLS liveview, via
 * LumixControlService) and Sync-generation bodies (cam.cgi + X-SESSION_ID,
 * via LumixSyncControlService, selected through AppStorage
 * 'controlProtocol' = 'sync'). Liveview streaming with touch AF, realtime
 * display state, dropdown panels for LUT / quality / aspect / metering /
 * liveview quality, and capture + video recording belong to the Lab line;
 * Sync keeps capture / video / one-shot AF and greys out the unsupported
 * panels. The page owns its own control session (auth, token, UDP receiver)
 * and claims the camera line while alive, so the image-transfer background
 * prewarm cannot fight it over the BLE identity.
 *
 * A third line rides the same page: Sony bodies over the shared ISO 15740
 * PTP/IP transport (NikonPtpIpService), selected through AppStorage
 * 'controlProtocol' = 'sony'. That line has no Panasonic channel of any kind
 * - the session is raised by the camera page before navigation, liveview and
 * shutter are the shared transport's calls, and the parameter panels have no
 * data source at all, so they render greyed-out and non-interactive instead of
 * being hidden (CameraControlBrand decides which panels that applies to).
 * Panasonic's two lines are untouched: every Sony branch is entered only when
 * that AppStorage key says 'sony'.
 */

/** Capability lists fetched from get-setting at connect time. */
class CapabilityCache {
  iso: string[] = [];
  whitebalance: string[] = [];
  recmode2: string[] = [];
  shtrspeed: string[] = [];
  quality: string[] = [];
  photostyle: string[] = [];
  aspectratio: string[] = [];
  lightmetering: string[] = [];
  liveviewsize: string[] = [];
}

/** 索尼线取帧间隔（与松下取景共用同一条 UI 管线）。 */
const SONY_LIVE_VIEW_FRAME_INTERVAL_MS: number = 80;
/** 索尼线连续多少帧拿不到数据就判定实时取景已经断了。 */
const SONY_LIVE_VIEW_MAX_CONSECUTIVE_FAILURES: number = 30;
/** 尼康线取帧间隔。与索尼线取同一个值：尼康取景帧同样是裸 JPEG，走同一条 UI
 *  管线，80ms 是已实机验证过的节奏（沿用原 NikonCameraControlPage 的取值）。 */
const NIKON_LIVE_VIEW_FRAME_INTERVAL_MS: number = 80;
/** 尼康线连续多少帧拿不到数据就判定实时取景已经断了。
 *
 *  尼康没有索尼那样的保活探针与取景流重连：0x9203 取帧就是一条普通 PTP 事务，
 *  会话一旦断掉 `liveViewFrame()` 会稳定返回 null，继续空转只会耗电。所以这里
 *  只用一个失败上限把「相机暂时没有新帧」与「会话真的没了」分开，到顶即收工并
 *  明确报错，让用户回相机页重连。 */
const NIKON_LIVE_VIEW_MAX_CONSECUTIVE_FAILURES: number = 30;
/** 连续多少帧取不到就先重启取景。
 *
 *  机身会自己停流（实测约 1744 帧后不再有帧），此时 `0x9203` 一直空回。30 次
 *  上限是留给「真的断了」的判断，重启的触发点要早得多：连丢 5 帧（约 0.4 秒）
 *  就试一次 `0x9202` + `0x9201`，用户几乎察觉不到。 */
const NIKON_LIVE_VIEW_RESTART_AFTER_FAILURES: number = 5;
/** 「流真的死了」的判定改成**按时间**，不再按帧数。
 *
 *  原来用的是「连丢 5 帧」。按 130 ms 一帧算，那是 **0.65 秒**——相机打个盹、画面
 *  短暂停一下，我们立刻就开始 `0x9202` + `0x9201`。而相机正睡着的时候这两条命令
 *  会直接挂住：10 秒事务超时 → **会话被毒化** → 之后取景、参数、图库全部失败 →
 *  最后连 Wi‑Fi 一起掉。真机日志把这条链走得一清二楚：
 *
 *    23:37:56.619  ptpip live-view frame bytes=72565      ← 最后一帧
 *    23:37:57.126  nikon-control live view restart 1/3    ← 只隔了 0.5 秒
 *    23:38:07.140  ptpip session poisoned: PTP/IP transaction timeout
 *    23:38:07.141  nikon-control restart start-live-view rejected
 *    23:38:07.143  nikon-control params supported=0
 *
 *  所以判据换成"连续多久没拿到画面"。3 秒足够跨过任何正常的短暂停顿，又远早于
 *  机身 68 秒的自我停流。 */
const NIKON_LIVE_VIEW_RESTART_AFTER_MS: number = 3000;
/** 彻底放弃的判据，同样改成按时间。
 *
 *  「连续 30 帧」在 130 ms 一帧下只有 **4 秒**——比上面那个重启阈值长不了多少，
 *  等于没给相机恢复的机会。15 秒才配得上"真的断了"。 */
const NIKON_LIVE_VIEW_ABANDON_AFTER_MS: number = 15000;
/** 主动复流的触发点（毫秒）。
 *
 *  机身**自己**会结束取景流——文件里早先的实测记录是「约 1744 帧 ≈ 68 秒」，而
 *  结束之后相机紧接着把整条智能设备连接（含 Wi‑Fi 热点）一起撤掉。所以"等它断了
 *  再救"来不及：用户什么也没做，只是盯着取景看，就会看到「实时取景中断」然后
 *  Wi‑Fi 断开。
 *
 *  对策是在机身到点之前先 `0x9202` + `0x9201` 复一次流。45 秒留了足够余量（实测
 *  存活下限 68 秒），用户看到的是画面极短地顿一下。 */
const NIKON_LIVE_VIEW_PROACTIVE_RESTART_MS: number = 45000;
/** 参数变化去抖窗口（毫秒）。
 *
 *  相机推 `0x4006 DevicePropChanged` 说明值变了，但事件不带新值，必须回读一次；
 *  而回读只能在流停着的时候做（流一挂起机身就不处理命令）。所以确认有变化之后，
 *  等这个安静期过去再"停流 → 读 → 复流"，把拧拨盘产生的连串事件合成一次闪动。 */
const NIKON_LIVE_VIEW_CHANGE_DEBOUNCE_MS: number = 1500;
/** 一次进入控制页最多重启几次取景。超过就按真失败处理，让用户回相机页。 */
const NIKON_LIVE_VIEW_MAX_STREAM_RESTARTS: number = 3;
/** 取景流被相机挂起时最多重连几次，超过就按真失败处理（见 sonyStartLoop）。
 *
 * 真机实测：相机一旦挂起取景流，紧接着就不再应答任何厂商操作
 * （`http-status=503` 之后正好 10.004 秒 `ptpip session poisoned ...
 * PTP/IP transaction timeout`，而重连要发的那条 0x9207 enable 就是超时的那条）。
 * 也就是说这种状态下重连注定失败，每次只白等一个 10 秒传输层超时，所以上限压到
 * 2 次；真正能救的是保活探针（见 SONY_LIVE_VIEW_KEEPALIVE_MS）。 */
const SONY_LIVE_VIEW_MAX_STREAM_RESTARTS: number = 2;
/** 取景期间每隔多久在控制通道上探一次活。
 *
 * 相机是在控制通道长时间静默之后才停掉取景流的（实测 1744 帧 / 3594 帧，不是
 * 固定帧数），而停掉之后就再也不应答厂商操作。所以要在它还没静默之前主动说话，
 * 并且在探针失败（= 已经不再应答）时立刻认账，而不是等空帧计数和重连超时把页面
 * 拖住。20 秒远小于实测的最短存活时间（1744 帧约 68 秒）。 */
const SONY_LIVE_VIEW_KEEPALIVE_MS: number = 20000;
/** 预览里同一排相邻两项参数之间的间距。
 *
 *  横向排版时它是「项与项」的距离；早先是竖排（一列四行）时的行距，当时从 6 提到
 *  14（13px 字号下四行挤成一坨、分不清哪行是哪行）。数值沿用，只是排布换了方向。 */
const SONY_PREVIEW_LINE_GAP: number = 14;
/**
 * 参数两排距离画面上下边缘的内缩量（像素）。
 *
 *  旋转是**布局之后**的视觉变换：一行的行盒高度仍然只有字号那么大（13px），但字
 *  转 90° 之后，那一截**字宽**就变成竖直方向的占用，向上下各探出
 *  `(字宽 − 字号) / 2`。最长的标签（如「画质 RAW 未压缩」）约 120px，探出约 57px，
 *  所以内缩量必须大于 57，否则两端的字会被切在画面外。
 *
 *  取 57：按最长的标签（约 120px）算，探出约 53.5px，所以 57 刚好压着这条下界，
 *  只剩 3~4px 余量。**别再往下调**——低于 53.5 两端的字就会重新被切在画面外。
 *  注意 120px 是按 13px 字号估的，不是实测值；真出现更长的取值（例如白平衡的长
 *  名称），需要同步把这里调大。
 */
const SONY_PREVIEW_EDGE_INSET: number = 57;
/**
 * 录像起停之后，等相机把自己的状态翻过来要轮询多久。
 *
 *  刚发完 `MovieRecButton` 的那一瞬间，相机的 `MovieRecordingState` 还是**旧值**
 *  （录像要起转、要写卡，属性不会同步翻转）。所以不能读完一次就照抄：第一次探测
 *  要等 `FIRST_MS`，之后每 `STEP_MS` 再探一次，最多 `TRIES` 次。
 */
const SONY_MOVIE_REC_CONFIRM_TRIES: number = 4;
const SONY_MOVIE_REC_CONFIRM_FIRST_MS: number = 250;
const SONY_MOVIE_REC_CONFIRM_STEP_MS: number = 500;

/**
 * 把重力向量换算成「参数文字该转多少度」。
 *
 *  设备的**真实上方**就是重力的反方向，文字的上要贴着它，人才读得正。屏幕坐标
 *  x 向右、y 向下，`rotate` 正角为顺时针，于是 φ = atan2(-gx, gy)：
 *
 *  | 拿法 | 重力 (gx, gy) | φ |
 *  |---|---|---|
 *  | 竖持（正常） | (0, +g) | 0° |
 *  | 设备顺时针转 90° | (+g, 0) | −90° |
 *  | 设备逆时针转 90° | (−g, 0) | +90° |
 *
 *  再量化到 90° 的整数倍，避免手一抖文字就跟着抖；倒置（±180°）归到 0，
 *  免得出现倒着的字——真要倒着看屏幕，任何摆法都读不了。
 *
 *  **最后要取负号**：`rotate` 的正角方向与上面这套手性相反。竖持时两者都是 0，
 *  所以这个符号只有在转屏之后才看得出来（实测反馈「方向镜像 180°」正是它）。
 */
function textAngleFromGravity(gx: number, gy: number): number {
  if (Math.sqrt(gx * gx + gy * gy) < 1) {
    return 0;
  }
  const degrees = Math.atan2(-gx, gy) * 180 / Math.PI;
  const snapped = -Math.round(degrees / 90) * 90;
  return snapped === 180 || snapped === -180 ? 0 : snapped;
}
/** `EnumResponseCode.OK` — the only code either 0x9207 operation accepts as a
 *  plain success (`ptpip/base/packet/EnumResponseCode.java`). */
const SONY_PTP_RESPONSE_OK: number = 0x2001;

/** 薄壳页面把 onPageShow / onBackPress 转发给真正的视图。 */
export class CameraControlPageBridge {
  static show: (() => void) | null = null;
  static back: (() => boolean) | null = null;
}

@Component
export struct CameraControlView {
  /** 页面显式传入的品牌协议（sony / nikon / lab / sync）；为空时回落到 AppStorage。 */
  @Prop protocolOverride: string = '';
  // 'connecting' | 'live' | 'error'
  @State private phase: string = 'connecting';
  @State private statusText: string = '正在连接相机…';
  @State private framePm: image.PixelMap | undefined = undefined;
  @State private info: LumixLiveviewInfo = new LumixLiveviewInfo();
  @State private remoteOn: boolean = false;
  @State private recording: boolean = false;
  /** 拍摄模式：false = 拍照，true = 录像。由底栏左侧两个白框图标切换。
   *
   *  只切**本机**的意图，不在这里改相机模式——尼康机身的拍照/录像由物理拨杆裁定，
   *  协议侧对应哪个操作码还没从真机确认，硬发只会把会话打坏。 */
  @State private movieMode: boolean = false;
  /** 索尼遥控录像正在等相机确认（防重入，见 sonyToggleVideo）。 */
  private sonyVideoBusy: boolean = false;
  @State private shooting: boolean = false;
  @State private panel: string = '';
  /** Slider thumb index while dragging an EV/shutter/ISO strip (-1 = not dragging). */
  @State private sliderPreview: number = -1;
  @State private caps: CapabilityCache = new CapabilityCache();
  /** Lab 线当前照片格调（photostyle 原始值，reflect 驱动；Q0 块未含该字段）。 */
  @State private labPhotoStyleRaw: string = '';
  @State private afX: number = -1;
  @State private afY: number = -1;
  @State private lvW: number = 0;
  @State private lvH: number = 0;
  /** 整页实测尺寸：只用来判断横/竖屏布局，不参与任何协议逻辑。 */
  @State private pageW: number = 0;
  @State private pageH: number = 0;
  @State private frameW: number = 0;
  @State private frameH: number = 0;
  private session: LumixControlSession | null = null;
  private receiver: LumixLiveviewReceiver | null = null;
  /** Sync protocol line (cam.cgi) selected via AppStorage 'controlProtocol'. */
  @State private syncMode: boolean = false;
  /** Drum parameter current values: getstate 不含鼓轮标签（2026-09-28 实机
   *  body 证实），由 getsetting 逐项读取合并进这里。 */
  @State private syncStateRaw: LumixSyncStateParams = {
    iso: '', shtrspeed: '', focal: '', exposure: '', whitebalance: ''
  };
  /** getinfo curmenu 的 <item> 快照：鼓轮取值域以相机端为准。 */
  @State private syncMenuItems: SyncMenuItem[] = [];
  /** 当前拍摄模式原始值（menu_item_id_recmode 的 value，如 aperture_ae）。 */
  @State private syncModeRaw: string = '';
  /** 格调/画质/比例/测光的相机返回值（getsetting 逐项读取）。 */
  @State private syncPhotoStyleRaw: string = '';
  @State private syncQualityRaw: string = '';
  @State private syncAspectRaw: string = '';
  @State private syncMeteringRaw: string = '';
  private syncHost: string = '';
  private syncMisses: number = 0;
  private stateTimer: number = -1;
  private afTimer: number = -1;
  private connectSeq: number = 0;
  private stateMisses: number = 0;
  private restartBusy: boolean = false;
  private recStartedAt: number = 0;
  private decoding: boolean = false;
  private pendingFrame: LumixLiveviewFrame | null = null;
  private shuttingDown: boolean = false;
  /** Set while the image-transfer page covers this page (sync liveview off). */
  private syncStreamSuspended: boolean = false;
  /**
   * AppStorage 'controlProtocol'（'lab' | 'sync' | 'sony'）：机型线选择的唯一
   * 来源。参数面板可用性与身份回填都经 CameraControlBrand 由它派生
   */
  private protocol: string | undefined = undefined;
  /** 索尼线（共享 PTP/IP 传输）：实时取景 + 快门，参数面板显示为不可用。 */
  @State private sonyMode: boolean = false;
  /**
   * 尼康线：与索尼线共用同一条 ISO 15740 PTP/IP 传输（同一个
   * NikonPtpIpService 单例），但底层厂商操作不同。必须与 sonyMode 分开：
   * 页面形态两者相同（都由 CameraControlBrand.isPtpIpProtocol 决定按 PTP/IP
   * 线渲染按钮面），可动作语义完全不同——sonyMode 走 SonyLiveView /
   * SonyPtpIpControl 的 0x9207 按键序列，nikonMode 走 NikonPtpIpService 的
   * 0x9201 / 0x9203 / 0x9202 与 0x9207 快门。用一个标志同时表达两件事，就会在
   * 尼康机身上发出索尼的厂商操作码。
   */
  @State private nikonMode: boolean = false;
  /** 尼康参数（PTP 设备属性）探测结果。**支持性与当前值都由相机回答**，
   *  不是本地机型表——见 `nikonRefreshParams` 与 `NikonCameraParameters`。 */
  @State private nikonProps: NikonPropertyState[] = [];
  /** 探测结论，直接显示在身份行上。
   *
   *  参数面板全是「不可用」时，光看界面分不清是相机不支持、会话没就绪，还是探测
   *  压根没跑——这三种的修法完全不同，所以把话写在脸上，而不是只进 hilog。 */
  @State private nikonParamStatus: string = '';
  /** 探测重入标记：一次十条 `0x1015` 是串行的，不能被并发再插一轮。 */
  private nikonParamRefreshing: boolean = false;
  /** PTP/IP 线（索尼 / 尼康）身份回填（机型 + 传输），进入页面时快照一次。 */
  @State private ptpIdentity: string = '';
  /** 索尼实时取景是否正在推流：离开页面或用户停止必须收回（0x9207 disable + 关流）。 */
  @State private sonyLiveViewOn: boolean = false;
  /** 索尼取帧循环占有标记：同一时刻只允许一个循环存在（不自我重叠）。 */
  private sonyLoopRunning: boolean = false;
  /** 尼康实时取景是否正在推流：离开页面必须下发 0x9202 EndLiveView 收回。 */
  @State private nikonLiveViewOn: boolean = false;
  /** 尼康取帧循环占有标记（与索尼同构：不自我重叠）。 */
  private nikonLoopRunning: boolean = false;
  /** 后台重连是否正在进行。用来保证一次失效只触发一次重连。 */
  private nikonRecovering: boolean = false;
  /**
   * 索尼触屏对焦是否可用（相机属性 53892 的 isEnable 与取值，加 53891 不为
   * OFF）。纯读已累积的 0x9209 属性表，不发请求；为假时取景画面点按不发任何
   * 东西——这就是「相机没有的能力就不给」在触屏上的落点。
   */
  @State private sonyTouchOn: boolean = false;
  /** 「取消触屏对焦」按钮是否可用（属性 53893），与官方把取消做成独立按钮一致。 */
  @State private sonyTouchCancelOn: boolean = false;
  /**
   * 索尼四个可调参数的当前原始值（相机属性值），-1 表示这次没拿到。
   * 选项高亮按原始值比较，这样就不必把索尼的值翻译成松下的定点编码。
   */
  @State private sonyApertureRaw: number = -1;
  @State private sonyShutterRaw: number = -1;
  @State private sonyIsoRaw: number = -1;
  @State private sonyEvRaw: number = -1;
  // 曝光程序模式 / 白平衡 / 画质 / 比例同样走 0x9209 记录。可写性由相机自己
  // 声明决定：真机 ILCE-7M4 上 ExposureProgramMode 是只读（机身拨盘控制），
  // 白平衡是 opt15:set，所以「列出来」与「能改」是两件事。
  @State private sonyModeRaw: number = -1;
  @State private sonyWbRaw: number = -1;
  @State private sonyQualityRaw: number = -1;
  @State private sonyAspectRaw: number = -1;
  @State private sonyModeLabel: string = '';
  @State private sonyWbLabel: string = '';
  @State private sonyQualityLabel: string = '';
  @State private sonyAspectLabel: string = '';
  /** 预览模式：全屏串流 + 无填充白字数据，只留右上角的预览/控制切换。 */
  @State private previewMode: boolean = false;
  /** 预览模式下是否隐藏压在画面上的参数文字。
   *
   *  全屏看画面时那两排白字正好压在构图上，拍延时、比对取景时需要能一键收掉；
   *  状态放在页面级（而不是预览层里），退出预览再进来仍是用户上次的选择。 */
  @State private previewHideParams: boolean = false;
  /** 预览层容器的实测尺寸，用来把参数浮层对齐到画面本身而不是屏幕。 */
  @State private previewW: number = 0;
  @State private previewH: number = 0;
  /** 参数文字的旋转角（度），来自重力向量，**跟随设备实际朝向**而不是画面。
   *  画面锁 90° 是给我们看的，文字摆正是给人读的，两者目标不同。 */
  @State private previewTextAngle: number = 0;
  /** 重力订阅句柄；null 表示未订阅。 */
  private gravityListener: ((data: sensor.GravityResponse) => void) | null = null;
  /** 是否已经收到过至少一个重力样本。用来区分「传感器没数据」和「角度本来就不变」
   *  ——没有这个标记，订阅静默失败和一切正常在日志里长得一模一样。 */
  private gravitySeen: boolean = false;

  aboutToAppear(): void {
    CameraControlPageBridge.show = (): void => this.handlePageShow();
    CameraControlPageBridge.back = (): boolean => this.handleBackPress();
    const protocol = this.protocolOverride.length > 0
      ? this.protocolOverride
      : AppStorage.get<string>('controlProtocol');
    const host = AppStorage.get<string>('syncControlHost');
    this.protocol = protocol;
    this.sonyMode = CameraControlBrand.isSonyProtocol(protocol);
    this.nikonMode = CameraControlBrand.isNikonProtocol(protocol);
    if (this.sonyMode || this.nikonMode) {
      // PTP/IP 线（索尼 / 尼康）不触碰任何松下通道：不认领 LUT 会话、不开松下
      // 控制会话。会话由相机页（openSonyCameraControl / openNikonCameraControl）
      // 在进入前建立，本页只消费它。
      this.ptpIdentity = CameraControlBrand.identityLine(protocol);
      NikonPtpIpService.log(`${this.nikonMode ? 'nikon' : 'sony'}-control page appear`
        + ' (shared camera control page)');
      AppLogStore.add(this.nikonMode ? 'ui 打开尼康相机控制页' : 'ui 打开索尼相机控制页');
      this.startConnect();
      return;
    }
    this.syncMode = protocol === 'sync';
    this.syncHost = host !== undefined ? host : '';
    // Claim the camera line while this page is alive so the image-line
    // background prewarm cannot re-register its BLE identity (which would
    // reset the camera and kill the remote-control session).
    LumixImportPrototype.setLutSessionActive(true);
    this.startConnect();
  }

  aboutToDisappear(): void {
    CameraControlPageBridge.show = null;
    CameraControlPageBridge.back = null;
    this.shuttingDown = true;
    this.connectSeq++;
    if (!this.sonyMode && !this.nikonMode) {
      LumixImportPrototype.setLutSessionActive(false);
    }
    // 预览把窗口方向锁成了竖屏，离开页面时必须还给系统，否则这个全局的方向
    // 偏好会留给后面的页面。重力订阅同理，必须退掉。
    if (this.previewMode) {
      this.previewMode = false;
      this.setPreviewOrientation(false);
    }
    this.stopTextOrientation();
    this.cleanupRuntime();
    this.session = null;
  }

  handlePageShow(): void {
    if (!this.syncMode || !this.syncStreamSuspended || this.shuttingDown) {
      return;
    }
    this.syncStreamSuspended = false;
    const receiver = this.receiver;
    if (this.phase !== 'live' || receiver === null) {
      return;
    }
    // Back from the image-transfer page: its endSession switched the camera
    // back to recmode — reopen the liveview stream on the same UDP socket.
    LumixSyncControlService.startStream(this.syncHost, receiver.port)
      .then((start: LumixSyncCamCmdResult): void => {
        if (!this.shuttingDown && this.receiver === receiver && start.ok) {
          receiver.resume();
        }
      })
      .catch((): void => {
      });
  }

  handleBackPress(): boolean {
    if (this.sonyMode) {
      // 索尼线：离开页面前收回实时取景，否则相机会一直推流耗电
      this.sonyStopLiveView();
      return false;
    }
    if (this.nikonMode) {
      // 尼康线同理：收回时必须下发 0x9202 EndLiveView，否则相机持续推流耗电。
      this.nikonStopLiveView();
      return false;
    }
    if (this.recording) {
      this.toast('请先停止录像');
      return true;
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // Connection lifecycle
  // -------------------------------------------------------------------------

  private async startConnect(): Promise<void> {
    this.connectSeq++;
    const seq = this.connectSeq;
    this.shuttingDown = false;
    this.cleanupRuntime();
    this.session = null;
    this.recording = false;
    this.stateMisses = 0;
    this.labPhotoStyleRaw = '';
    if (this.framePm !== undefined) {
      const old = this.framePm;
      this.framePm = undefined;
      try {
        old.release();
      } catch (_error) {
      }
    }
    this.phase = 'connecting';
    if (this.sonyMode) {
      this.statusText = '正在连接 PTP/IP 控制会话…';
      await this.sonyStartConnect(seq);
      return;
    }
    if (this.nikonMode) {
      this.statusText = '正在连接 PTP/IP 控制会话…';
      await this.nikonStartConnect(seq);
      return;
    }
    this.statusText = this.syncMode ? '正在建立 LUMIX Sync 控制会话…' : '正在连接相机…';
    if (this.syncMode) {
      await this.syncStartConnect(seq);
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const session = await LumixControlService.openSession(context);
      if (seq !== this.connectSeq) {
        return;
      }
      this.session = session;
      // One keep-alive TCP for the streaming-critical calls (official uses a
      // pooled OkHttp connection; per-request close may kill the stream).
      LumixControlService.openControlClient(session);
      this.statusText = '正在进入拍摄模式…';
      // Official sequence stops a leftover stream first (403 err_critical ignored).
      await LumixControlService.stopStream(session);
      // recmode can take ~0.9s while the body switches modes: retry a few times.
      await LumixControlService.sendCamCmd(session, 'recmode', 3);
      if (seq !== this.connectSeq) {
        return;
      }
      await this.primePipeline(session);
      if (seq !== this.connectSeq) {
        return;
      }
      const receiver = new LumixLiveviewReceiver();
      receiver.frameHandler = (frame: LumixLiveviewFrame): void => {
        this.handleFrame(frame);
      };
      receiver.stallHandler = (): void => {
        this.handleStall();
      };
      // 2026-09-19 h2 官方插桩实锤：干净相机上官方 start-stream 发 1235
      // get-lvport 首次即 200。我方 1234 永久 err_busy，对齐官方端口
      const port = await receiver.bind(1235);
      if (seq !== this.connectSeq) {
        receiver.stop();
        return;
      }
      this.receiver = receiver;
      await LumixControlService.startStream(session, port);
      const lvPort = await LumixControlService.fetchLvPort(session);
      // 黄金会话 04:03:11.258-11.787：官方在 get-lvport 成功后、首帧前再拉
      // 8 个能力键（含重复的 focusmode/aspectratio）；逐字对齐
      await this.primePostLvport(session);
      // Liveview UDP is DTLS 1.2 (2026-09-19 official-APK instrumentation):
      // the camera sends nothing until a full handshake completes on the
      // stream port, so the handshake replaces the old plaintext probe.
      await receiver.startDtls(session.host, lvPort);
      if (seq !== this.connectSeq) {
        return;
      }
      receiver.resume();
      this.phase = 'live';
      this.statusText = '';
      this.stateTimer = setInterval(() => {
        this.pollState();
      }, 1000);
      this.loadCapabilities();
    } catch (error) {
      if (seq !== this.connectSeq) {
        return;
      }
      console.info(`VIVID_CTRL connect failed: ${this.errText(error)}`);
      this.phase = 'error';
      this.statusText = this.errText(error);
    }
  }

  /**
   * Official client runs this get-setting burst between recmode and
   * start-stream: it initializes the camera liveview pipeline, and without it
   * get-lvport stays 403 err_busy forever (verified against the official app).
   */
  private async primePipeline(session: LumixControlSession): Promise<void> {
    // 黄金会话 04:03:10.163-11.143 完整 19 键序列（含 recmode1/crop_zoom 两个
    // 400 err_param——官方也发，相机按未知键报错，属预期）
    const keys: string[] = ['photostyle', 'quality', 'aspectratio', 'drivemode', 'selftimer',
      'exposure', 'iso', 'whitebalance', 'recmode2', 'lightmetering', 'liveviewsize', 'focusmode',
      'operatepriority', 'recmode1', 'sensitivity_db', 'videoformat', 'videoquality',
      'shtrspeed_angle', 'crop_zoom'];
    let ok = 0;
    for (const key of keys) {
      if (this.shuttingDown) {
        return;
      }
      try {
        await LumixControlService.fetchSettingOptions(session, key);
        ok++;
      } catch (_error) {
        // Unsupported keys answer 400 err_param, same as in the official burst.
      }
    }
    LumixControlService.log(`pipeline primed ok=${ok}/${keys.length}`);
  }

  /** Official post-lvport capability pull (golden 04:03 session, 8 keys). */
  private async primePostLvport(session: LumixControlSession): Promise<void> {
    const keys: string[] = ['focusmode', 'aspectratio', 'drivemode', 'iso', 'whitebalance',
      'focusmode', 'videoquality', 'aspectratio'];
    let ok = 0;
    for (const key of keys) {
      if (this.shuttingDown) {
        return;
      }
      try {
        await LumixControlService.fetchSettingOptions(session, key);
        ok++;
      } catch (_error) {
      }
    }
    LumixControlService.log(`post-lvport primed ok=${ok}/${keys.length}`);
  }

  private cleanupRuntime(): void {
    if (this.sonyMode) {
      // 索尼线：断开取帧循环、关掉取景 HTTP 流并按需下发 0x9207 disable，
      // 否则相机会一直被取景推流耗干电池。会话本身归相机页所有，不在这里关。
      this.sonyLoopRunning = false;
      if (this.sonyLiveViewOn) {
        this.sonyLiveViewOn = false;
        NikonPtpIpService.log('sony-control cleanup; end live view');
        SonyLiveView.stop().catch((): void => {
        });
      }
    }
    if (this.nikonMode) {
      // 尼康线：断开取帧循环并按需下发 0x9202 EndLiveView，否则相机持续推流耗电。
      // 会话本身归相机页所有（控制页与图片传输共用同一个 NikonPtpIpService 单例），
      // 不在这里关。
      this.nikonLoopRunning = false;
      if (this.nikonLiveViewOn) {
        this.nikonLiveViewOn = false;
        NikonPtpIpService.log('nikon-control cleanup; end live view');
        NikonPtpIpService.endLiveView().catch((): void => {
        });
      }
      // **退出控制页要把机身控制权交回相机。**
      //
      // 进页面时为了能改档位、能按录制键，我们发过 `0x90C2 [1]`（HOST）。页面一关
      // 就该发 `[0]`（CAMERA）还回去，否则机身的拨盘和按键仍然"让位"给已经不在了的
      // 遥控端，用户上手机会觉得相机被人拽着。两条命令走同一条串行队列，`endLiveView`
      // 先入队，所以顺序是先停流、再交还。
      NikonPtpIpService.releaseHostControl().catch((): void => {
      });
    }
    if (this.stateTimer >= 0) {
      clearInterval(this.stateTimer);
      this.stateTimer = -1;
    }
    if (this.afTimer >= 0) {
      clearTimeout(this.afTimer);
      this.afTimer = -1;
    }
    this.syncStreamSuspended = false;
    if (this.syncMode && this.receiver !== null) {
      LumixSyncControlService.stopStream(this.syncHost).catch(() => {
      });
    }
    if (this.receiver !== null) {
      this.receiver.stop();
      this.receiver = null;
    }
    const session = this.session;
    if (session !== null) {
      LumixControlService.stopStream(session);
      LumixControlService.closeControlClient(session);
    }
  }

  private enterError(message: string): void {
    this.phase = 'error';
    this.statusText = message;
    this.cleanupRuntime();
  }

  /** Run one control call; re-auth once and retry on a stale-token 401. */
  private async control<T>(fn: (s: LumixControlSession) => Promise<T>): Promise<T> {
    const session = this.session;
    if (session === null) {
      throw new LumixControlError('auth', '相机未连接');
    }
    try {
      return await fn(session);
    } catch (error) {
      if (error instanceof LumixControlError && error.code === 401 && !this.shuttingDown) {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const fresh = await LumixControlService.reopenSession(context);
        this.session = fresh;
        return await fn(fresh);
      }
      throw error instanceof Error ? error : new LumixControlError('auth', '相机通信失败');
    }
  }

  /** 取景被拒时恢复：相机若停在回放模式（图片传输下载发过 playmode），
   *  先切回 rec（轮询 getstate cammode 确认）再重试 startstream。 */
  private async syncRecoverStream(port: number, seq: number): Promise<LumixSyncCamCmdResult> {
    let last: LumixSyncCamCmdResult = { ok: false, message: '相机返回 err_reject', body: '' };
    for (let attempt = 0; attempt < 3; attempt++) {
      const state = await LumixSyncControlService.fetchSyncState(this.syncHost);
      const inPlay = state.ok && state.body.indexOf('<cammode>play</cammode>') >= 0;
      if (inPlay) {
        this.statusText = '相机处于回放模式，正在切回拍摄模式…';
        await LumixSyncControlService.sendCamCmd(this.syncHost, 'recmode');
        for (let poll = 0; poll < 8; poll++) {
          await this.delay(1000);
          const after = await LumixSyncControlService.fetchSyncState(this.syncHost);
          if (!after.ok || after.body.indexOf('<cammode>rec</cammode>') >= 0) {
            break;
          }
        }
      }
      await this.delay(1000);
      const start = await LumixSyncControlService.startStream(this.syncHost, port);
      if (seq !== this.connectSeq) {
        return start;
      }
      last = start;
      if (start.ok) {
        return start;
      }
    }
    return last;
  }

  /**
   * Sync protocol line: accctrl req_acc session (or reuse), recmode so
   * capture / video verbs are accepted, then plaintext-UDP liveview
   * (startstream → shared LumixLiveviewReceiver, no DTLS on this line).
   */
  private async syncStartConnect(seq: number): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const session = await LumixSyncControlService.ensureControlSession(context, this.syncHost,
        (status: string): void => {
          if (seq === this.connectSeq) {
            this.statusText = status;
          }
        });
      if (seq !== this.connectSeq) {
        return;
      }
      if (!session.ok) {
        throw new LumixControlError('auth', session.message);
      }
      this.statusText = '正在进入拍摄模式…';
      const recmode = await LumixSyncControlService.sendCamCmd(this.syncHost, 'recmode');
      if (seq !== this.connectSeq) {
        return;
      }
      if (!recmode.ok) {
        throw new LumixControlError('auth', recmode.message);
      }
      // Sync-line liveview: plaintext Panasonic fragments on UDP 49152 
      // official E5/e + E5/g use a raw DatagramSocket (no DTLS on this
      // generation), and the fragment layout is identical to the Lab line,
      // so the shared receiver/parser works as-is.
      this.statusText = '正在开启实时取景…';
      const receiver = new LumixLiveviewReceiver();
      receiver.frameHandler = (frame: LumixLiveviewFrame): void => {
        this.handleFrame(frame);
      };
      receiver.stallHandler = (): void => {
        this.handleStall();
      };
      const port = await receiver.bind(49152);
      if (seq !== this.connectSeq) {
        receiver.stop();
        return;
      }
      this.receiver = receiver;
      let start = await LumixSyncControlService.startStream(this.syncHost, port);
      if (seq !== this.connectSeq) {
        return;
      }
      if (!start.ok) {
        // 相机可能停在回放模式（图片传输下载会发 playmode，2026-09-28
        // 实测返回控制页时 startstream err_reject）：切回 rec 后重试取景
        start = await this.syncRecoverStream(port, seq);
      }
      if (!start.ok) {
        receiver.stop();
        this.receiver = null;
        throw new LumixControlError('auth', start.message);
      }
      receiver.resume();
      this.syncMisses = 0;
      this.phase = 'live';
      this.statusText = '';
      // 鼓轮初始化：curmenu 取值域快照 + getsetting 当前值（getstate
      // 响应不含鼓轮标签，不能作为显示数据源）
      void this.syncLoadMenu();
      void this.syncRefreshDrums();
      // 官方连接即发送 raw_img_send=enable（service/a.java）：原始 RAW
      // 含完整 EXIF/镜头信息；未开启时下载的 RW2 可能是精简
      // （2026-09-28 实机缺镜头信息）。跳过配对的直连会话也补发一次
      LumixSyncControlService.sendCamSetting(this.syncHost, 'raw_img_send', 'enable').catch(() => {
      });
      this.stateTimer = setInterval(() => {
        this.syncPollState();
      }, 3000);
    } catch (error) {
      if (seq !== this.connectSeq) {
        return;
      }
      console.info(`VIVID_CTRL sync connect failed: ${this.errText(error)}`);
      this.phase = 'error';
      this.statusText = this.errText(error);
    }
  }

  /** Sync heartbeat: getstate reachability (misses tear the page down) plus
   *  drum parameter current values via getsetting（getstate 响应不含鼓轮
   *  标签，2026-09-28 实机全量 body 证实）。 */
  private async syncPollState(): Promise<void> {
    if (this.shuttingDown || this.phase !== 'live') {
      return;
    }
    const state = await LumixSyncControlService.fetchSyncState(this.syncHost);
    if (state.ok) {
      this.syncMisses = 0;
      await this.syncRefreshDrums();
      return;
    }
    this.syncMisses++;
    if (this.syncMisses >= 5) {
      this.enterError('与相机失去连接，请重新连接');
    }
  }

  /** 拉取 curmenu 快照：鼓轮取值域（含 EV 官方值格式）以相机端为准。 */
  private async syncLoadMenu(): Promise<void> {
    const menu = await LumixSyncControlService.fetchSyncMenu(this.syncHost);
    if (menu.ok) {
      this.syncMenuItems = LumixSyncControlService.parseSyncMenuItems(menu.body);
      // 当前拍摄模式：menu_item_id_recmode 的 value 属性（2026-09-28 实测
      // value="aperture_ae" = A 档）。作为模式行显示与高亮的初始值
      for (const item of this.syncMenuItems) {
        if (item.id === 'menu_item_id_recmode' && item.value.length > 0) {
          this.syncModeRaw = item.value;
          this.info.modeLabel = this.syncModeLabel(item.value);
          break;
        }
      }
    }
    // 光圈档位域不在 curmenu（无 focal 子项）：镜头信息 getinfo lens 里，
    // 全量落 hilog 供下一轮校准
    void LumixSyncControlService.fetchSyncLens(this.syncHost);
  }

  /** 逐项 getsetting 读取鼓轮当前值并合并进显示（官方读取通道 B5/a.E()）
   *  只覆盖非空值——设置失败或相机未就绪时保留上次已知值，不再
   *  空参数整体重置（ISO 选中高亮跳默认、WB 数值为空的根因）。 */
  private async syncRefreshDrums(): Promise<void> {
    const drums: string[][] = [['mode', 'recmode'], ['iso', 'iso'], ['shutter', 'shtrspeed'],
      ['aperture', 'focal'], ['ev', 'exposure'], ['wb', 'whitebalance'],
      ['lut', 'photostyle'], ['quality', 'quality'], ['aspect', 'aspectratio'],
      ['metering', 'lightmetering']];
    for (const pair of drums) {
      if (this.shuttingDown || this.phase !== 'live') {
        return;
      }
      const result = await LumixSyncControlService.fetchSyncSetting(this.syncHost, pair[1]);
      if (result.ok && result.value.length > 0) {
        this.reflectSyncSetting(pair[0], result.value);
      }
    }
  }

  private syncIsoLabel(value: string): string {
    return value === 'auto' ? '自动' : value.toUpperCase();
  }

  private syncShutterLabel(value: string): string {
    if (value === 'auto') {
      return '自动';
    }
    // 相机端快门 = N/256 秒（"1/256" = 1/250 显示档、"1024/256" = 4"）
    const seconds = this.shutterSeconds(value);
    if (seconds >= 1) {
      return `${seconds}"`;
    }
    if (seconds > 0) {
      const n256 = Math.round(seconds * 256);
      switch (n256) {
        case 1: return '1/250';
        case 2: return '1/125';
        case 4: return '1/60';
        case 8: return '1/30';
        case 16: return '1/15';
        case 32: return '1/8';
        case 64: return '1/4';
        case 128: return '1/2';
        default:
          return n256 > 0 ? `1/${Math.round(256 / n256)}` : value;
      }
    }
    return value;
  }

  /** 快门值（"1/250"、"1024/256"、裸秒数）→ 秒；无法解析返回 0。 */
  private shutterSeconds(value: string): number {
    const slash = value.indexOf('/');
    if (slash > 0) {
      const numerator = parseFloat(value.substring(0, slash));
      const denominator = parseFloat(value.substring(slash + 1));
      if (!Number.isNaN(numerator) && denominator > 0) {
        return numerator / denominator;
      }
      return 0;
    }
    const bare = parseFloat(value);
    return !Number.isNaN(bare) && bare > 0 ? bare : 0;
  }

  private syncFocalLabel(value: string): string {
    if (value === 'auto') {
      return '自动';
    }
    // 相机端光圈 = AV×256（如 "940/256" = AV 3.672 → F3.6）
    const numerator = this.focalNumerator(value);
    if (numerator > 0) {
      const f = Math.pow(2, numerator / 256 / 2);
      return `F${f.toFixed(1)}`;
    }
    return value.toUpperCase().startsWith('F') ? value.toUpperCase() : `F${value}`;
  }

  /** 光圈值归一为 AV×256 分子（相机端单位）：
   *  "940/256" → 940（AV×256）；"7.1"/"F7.1" → 2·log2(7.1)×256
   *  无法解析返回 0。 */
  private focalNumerator(value: string): number {
    const slash = value.indexOf('/');
    if (slash > 0) {
      const numerator = parseFloat(value.substring(0, slash));
      const denominator = parseFloat(value.substring(slash + 1));
      if (denominator > 0 && !Number.isNaN(numerator)) {
        if (denominator === 256) {
          return numerator;
        }
        return Math.round(numerator / denominator * 256);
      }
      return 0;
    }
    const bare = parseFloat(value.replace(/^F/i, ''));
    if (!Number.isNaN(bare) && bare > 0) {
      return Math.round(2 * Math.log2(bare) * 256);
    }
    return 0;
  }

  private syncExposureLabel(value: string): string {
    if (value === '0' || value.length === 0) {
      return value === '0' ? '0EV' : value;
    }
    return `${value}EV`;
  }

  private syncWbLabel(value: string): string {
    if (value === 'auto') {
      return '自动';
    }
    if (value === 'auto_cool') {
      return '自动·冷';
    }
    if (value === 'auto_warm') {
      return '自动·暖';
    }
    if (value === 'daylight') {
      return '日光';
    }
    if (value === 'cloudy') {
      return '阴天';
    }
    if (value === 'shade') {
      return '阴影';
    }
    if (value === 'halogen' || value === 'incandescent') {
      return '白炽灯';
    }
    if (value === 'flash') {
      return '闪光';
    }
    if (value === 'blackwhite') {
      return '黑白';
    }
    if (value.startsWith('white_set')) {
      return `白平衡${value.substring('white_set'.length)}`;
    }
    if (value === 'kelvin' || value === 'color_temp') {
      return '色温';
    }
    if (value.startsWith('color_temp') && value.length > 'color_temp'.length) {
      return `色温${value.substring('color_temp'.length)}`;
    }
    return value;
  }

  private async syncCapture(): Promise<void> {
    if (this.shooting) {
      return;
    }
    this.shooting = true;
    try {
      const result = await LumixSyncControlService.sendCamCmd(this.syncHost, 'capture');
      if (!result.ok) {
        this.toast(`拍摄失败：${result.message}`);
        return;
      }
      this.toast('已拍摄');
      // Official app auto-sends capture_cancel to release the shutter state.
      setTimeout(() => {
        LumixSyncControlService.sendCamCmd(this.syncHost, 'capture_cancel').catch(() => {
        });
      }, 280);
    } finally {
      this.shooting = false;
    }
  }

  private async syncToggleVideo(): Promise<void> {
    if (this.recording) {
      const stop = await LumixSyncControlService.sendCamCmd(this.syncHost, 'video_recstop');
      if (stop.ok) {
        this.recording = false;
      } else {
        this.toast(`停止失败：${stop.message}`);
      }
    } else {
      const start = await LumixSyncControlService.sendCamCmd(this.syncHost, 'video_recstart');
      if (start.ok) {
        this.recStartedAt = Date.now();
        this.recording = true;
      } else {
        this.toast(`开始失败：${start.message}`);
      }
    }
  }

  private async syncFocus(): Promise<void> {
    const result = await LumixSyncControlService.sendCamCmd(this.syncHost, 'oneshot_af');
    if (!result.ok) {
      this.toast(`对焦失败：${result.message}`);
    }
  }

  /** 1Hz heartbeat: keeps the session alive and reconciles recording state. */
  private async pollState(): Promise<void> {
    if (this.syncMode || this.session === null || this.shuttingDown) {
      return;
    }
    try {
      const state = await this.control<LumixCameraState>((s: LumixControlSession) =>
        LumixControlService.fetchState(s));
      this.stateMisses = 0;
      // While recording the camera writes to a card continuously; if both card
      // activity flags stay off past the start grace period, recording was
      // stopped on the body itself.
      if (this.recording && !state.sdAccess && !state.sd2Access &&
        Date.now() - this.recStartedAt > 4000) {
        this.recording = false;
      }
    } catch (error) {
      this.stateMisses++;
      if (this.stateMisses >= 5 && this.phase === 'live') {
        this.enterError('与相机失去连接，请重新连接');
      }
    }
  }

  /** 相机自己给的 shtrspeed 显示串（item → subitem[0]）。 */
  private shutterLabels: Map<string, string> = new Map<string, string>();

  /** get-setting burst: the dropdown value domains of this camera. */
  private async loadCapabilities(): Promise<void> {
    const keys: string[] = ['iso', 'whitebalance', 'recmode2', 'shtrspeed', 'quality',
      'photostyle', 'aspectratio', 'lightmetering', 'liveviewsize'];
    for (const key of keys) {
      if (this.shuttingDown || this.session === null) {
        return;
      }
      try {
        if (key === 'shtrspeed') {
          const entries = await this.control<SettingOptionEntry[]>((s: LumixControlSession) =>
            LumixControlService.fetchSettingOptionEntries(s, key));
          const values: string[] = [];
          for (const entry of entries) {
            values.push(entry.value);
            if (entry.label.length > 0) {
              this.shutterLabels.set(entry.value, entry.label);
            }
          }
          this.setCaps(key, values);
        } else {
          const list = await this.control<string[]>((s: LumixControlSession) =>
            LumixControlService.fetchSettingOptions(s, key));
          this.setCaps(key, list);
        }
      } catch (_error) {
        // Unsupported keys answer 400 err_param: the static fallback list covers them.
      }
      await this.delay(30);
    }
    if (this.shuttingDown || this.session === null) {
      return;
    }
    // S1RM2 把画质拆为 pictureformat + jpeg_heif(_quality)（协议 §18），
    // set-setting quality 全 200 但不生效（2026-09-29 14:48 实测）。探测到
    // pictureformat 值域即把画质面板整体切到该键；S5M2 无此键，保持 quality
    try {
      const pfList = await this.control<string[]>((s: LumixControlSession) =>
        LumixControlService.fetchSettingOptions(s, 'pictureformat'));
      if (pfList.length > 0) {
        this.caps.quality = pfList;
        this.qualityKey = 'pictureformat';
      }
    } catch (_error) {
      // S5M2 无 pictureformat 键：保持 quality 域
    }
  }

  private setCaps(key: string, list: string[]): void {
    if (key === 'iso') {
      this.caps.iso = list;
    } else if (key === 'whitebalance') {
      this.caps.whitebalance = list;
    } else if (key === 'recmode2') {
      this.caps.recmode2 = list;
    } else if (key === 'shtrspeed') {
      this.caps.shtrspeed = list;
    } else if (key === 'quality') {
      this.caps.quality = list;
    } else if (key === 'photostyle') {
      this.caps.photostyle = list;
    } else if (key === 'aspectratio') {
      this.caps.aspectratio = list;
    } else if (key === 'lightmetering') {
      this.caps.lightmetering = list;
    } else if (key === 'liveviewsize') {
      this.caps.liveviewsize = list;
    }
  }

  // -------------------------------------------------------------------------
  // Sony line (shared ISO 15740 PTP/IP transport, NikonPtpIpService)
  // -------------------------------------------------------------------------

  /**
   * 索尼线连接。会话必须已经存在：相机页 openSonyCameraControl 会先按需
   * 拉起相机 Wi-Fi，再 acquireSession，本页只消费它——没有会话时不启
   * 实时取景、不自行连接、不抛异常。
   *
   * 随后开实时取景并启动取帧循环。索尼的实时取景与快门都不走共享传输层的
   * 尼康取景路径（0x9201/0x9202/0x9203）：它们由 SonyLiveView 用索尼自己的
   * `SDIO_ControlDevice` (0x9207) 完成，取景帧走一条独立的 HTTP 连接。
   * 参数面板在索尼线上没有读取通道，由 CameraControlBrand.supportsPanel 判定为
   * 不可用，只影响面板显示，不影响取景与快门。
   */
  private async sonyStartConnect(seq: number): Promise<void> {
    if (!NikonPtpIpService.isControlReady()) {
      this.phase = 'error';
      this.statusText = SonyPtpIpContent.isUsbSession()
        ? 'USB 会话已断开：请重新插拔数据线后再点「相机控制」重试'
        : '未建立 PTP/IP 会话：请先在相机页完成蓝牙配对，再点「相机控制」重试';
      NikonPtpIpService.log('sony-control no ptpip session; live view not started');
      return;
    }
    this.statusText = '正在准备遥控会话…';
    // 0x9207 是按键类操作，只有在 SDIO_OpenSession (0x9210) 以
    // REMOTE_CONTROL_WITH_TRANSFER_MODE 建立的会话上才被相机受理
    // （ptpip/BasePtpManager.java:1409 与 initialization/Initializer.java:83-96）。
    // 相机页当初用的是标准 OpenSession，所以这里按需换成厂商会话。
    let sessionOk: boolean = false;
    try {
      sessionOk = await SonyLiveView.ensureRemoteControlSession();
    } catch (error) {
      NikonPtpIpService.log(`sony-control session prepare threw: ${String(error)}`);
      sessionOk = false;
    }
    if (seq !== this.connectSeq || this.shuttingDown) {
      return;
    }
    if (!sessionOk) {
      this.phase = 'error';
      this.statusText = '遥控会话未建立：相机未接受 0x9210 SDIO_OpenSession，无法进入实时取景';
      NikonPtpIpService.log('sony-control remote-control session unavailable');
      return;
    }
    // 触屏对焦能力随 0x9209 属性表一起来，这里快照一次即可：两个开关都只由相机
    // 自己的属性决定（53892/53891 与 53893），不再变化，也不额外发请求
    this.sonyTouchOn = SonyPtpIpContent.touchAfAvailable();
    this.sonyTouchCancelOn = SonyPtpIpContent.cancelTouchAfAvailable();
    NikonPtpIpService.log(`sony-control touch available=${this.sonyTouchOn ? 1 : 0}`
      + ` cancel=${this.sonyTouchCancelOn ? 1 : 0}`);
    // 四个参数同样从属性表回填一次；之后每次设置成功再回填一次
    this.sonyRefreshParams();
    this.statusText = '正在启动实时取景…';
    NikonPtpIpService.log('sony-control start live view');
    let started: SonyLiveViewStart = {
      ok: false, url: '', enableCode: -1, reason: 'not-run',
    };
    try {
      started = await SonyLiveView.start();
    } catch (error) {
      NikonPtpIpService.log(`sony-control start live view threw: ${String(error)}`);
      started = { ok: false, url: '', enableCode: -1, reason: 'threw' };
    }
    if (seq !== this.connectSeq || this.shuttingDown) {
      // 页面已经走了：立刻收回刚刚打开的实时取景。
      if (started.ok) {
        SonyLiveView.stop().catch((): void => {
        });
      }
      return;
    }
    if (!started.ok) {
      this.phase = 'error';
      this.statusText = this.sonyStartFailureText(started);
      NikonPtpIpService.log('sony-control start live view rejected' +
        ` reason=${started.reason} enable=${started.enableCode}`);
      return;
    }
    this.sonyLiveViewOn = true;
    this.phase = 'live';
    // 取景已经开始；0x9207 的 enable 被拒时索尼官方也照样开流
    // （camera/BaseCamera.java:69 从失败回调里继续 setLiveViewStreamCallback），
    // 所以这里只把它说出来，不当作失败。
    this.statusText = started.enableCode === SONY_PTP_RESPONSE_OK
      ? '实时取景中'
      : `实时取景中（0x9207 enable 响应 ${hexWord(started.enableCode)}，相机仍在推流）`;
    this.sonyStartLoop();
  }

  /** 索尼线启动失败时的状态文案：把「没有 URL」「enable 被拒」「流没开起来」
   *  分开说，任何一种都不是笼统的「启动失败」。 */
  private sonyStartFailureText(started: SonyLiveViewStart): string {
    if (started.reason === 'no-url') {
      return '实时取景启动失败：相机既未提供 LiveViewUrl (0xD278)，设备描述文件里也没有 '
        + 'X_ScalarWebAPI_LiveView_URL';
    }
    if (started.reason === 'no-session') {
      return '实时取景启动失败：PTP/IP 会话已断开，请返回相机页重连';
    }
    if (started.enableCode >= 0 && started.enableCode !== SONY_PTP_RESPONSE_OK) {
      return `实时取景启动失败：0x9207 enable 被拒（响应 ${hexWord(started.enableCode)}）`;
    }
    if (started.reason.startsWith('http-status=')) {
      return `实时取景启动失败：取景流 HTTP 响应 ${started.reason.substring('http-status='.length)}`;
    }
    if (started.reason === 'no-frame') {
      return '实时取景启动失败：USB 通道已建立，但相机没有返回取景帧'
        + '（请确认相机不在回放界面，且未被其他软件占用）';
    }
    return `实时取景启动失败：取景流未建立（${started.reason.length > 0
      ? started.reason : '未知原因'}）`;
  }

  /** 索尼取帧循环：sonyLoopRunning 保证不自我重叠；每轮固定 sleep 一段，
   *  所以一个慢帧只会拖慢节奏，不会变成忙等。帧由 SonyLiveView 的独立 HTTP
   *  连接按 16 字节帧头切好，这里只取最新一帧（与索尼自己的池一致）。 */
  private async sonyStartLoop(): Promise<void> {
    if (this.sonyLoopRunning || this.shuttingDown) {
      return;
    }
    this.sonyLoopRunning = true;
    let consecutiveFailures: number = 0;
    let streamRestarts: number = 0;
    let lastProbeMs: number = Date.now();
    let sessionLost: boolean = false;
    try {
      while (this.sonyLoopRunning && !this.shuttingDown) {
        // 控制通道保活探针。相机是在这条通道静默之后才停掉取景流的，而停掉之后
        // 连 enable 都不再应答，重连就没路了——所以只能在它还肯答话的时候先探，
        // 探到不应答就立刻停手，不把 2 次重连 × 10 秒超时白等掉。
        if (Date.now() - lastProbeMs >= SONY_LIVE_VIEW_KEEPALIVE_MS) {
          lastProbeMs = Date.now();
          const probe = await SonyLiveView.keepAlive();
          if (!this.sonyLoopRunning || this.shuttingDown) {
            break;
          }
          if (probe !== SONY_PTP_RESPONSE_OK) {
            sessionLost = true;
            NikonPtpIpService.log('sony-control keep-alive failed'
              + ` code=${hexWord(probe)}`
              + ` frames=${SonyLiveView.framesReceived()}`);
          }
        }
        const jpeg = SonyLiveView.nextFrame();
        if (!this.sonyLoopRunning || this.shuttingDown) {
          break;
        }
        if (jpeg === null) {
          consecutiveFailures++;
          if (consecutiveFailures >= SONY_LIVE_VIEW_MAX_CONSECUTIVE_FAILURES) {
            // 相机会把长时间存活的取景连接「挂起」——真机 ILCE-7M4 上 1744 帧
            // （约 68 秒）后 socket 不关、不发结束块、也不报错，nextFrame()
            // 从此恒为 null。以前这里直接把整个会话拆掉，代价是双向的：控制
            // 通道也一起断了（stop() 发的 enable=0 无人应答，10 秒后传输层以
            // 事务超时把会话置毒），而且把一次可恢复的暂停变成死页面。现在只
            // 重连 HTTP 取景流，不碰 PTP/IP 会话。
            consecutiveFailures = 0;
            streamRestarts++;
            if (sessionLost || streamRestarts > SONY_LIVE_VIEW_MAX_STREAM_RESTARTS) {
              this.sonyLoopRunning = false;
              const reason = SonyLiveView.streamReason();
              this.phase = 'error';
              // 探针已经证明相机不再应答厂商操作时，重连没有任何成功率可言，
              // 所以直接说清是相机的控制通道停了，而不是含糊地说「重连失败」。
              this.statusText = sessionLost
                ? '实时取景中断：相机已停止响应控制通道，需要重新连接相机'
                : `实时取景中断：连续 ${SONY_LIVE_VIEW_MAX_STREAM_RESTARTS} 次重连失败`
                  + `${reason.length > 0 ? `（${reason}）` : ''}，已停止`;
              NikonPtpIpService.log(`sony-control live view stopped after`
                + ` ${SONY_LIVE_VIEW_MAX_STREAM_RESTARTS} failed stream restarts`
                + ` sessionLost=${sessionLost ? 1 : 0}`
                + ` reason=${reason.length > 0 ? reason : '-'}`
                + ` frames=${SonyLiveView.framesReceived()}`);
              if (this.sonyLiveViewOn) {
                this.sonyLiveViewOn = false;
                SonyLiveView.stop().catch((): void => {
                });
              }
              break;
            }
            NikonPtpIpService.log(`sony-control live view stalled; restarting stream` +
              ` attempt=${streamRestarts}` +
              ` frames=${SonyLiveView.framesReceived()}`);
            this.statusText = `实时取景重连中…（第 ${streamRestarts} 次）`;
            const reopened = await SonyLiveView.restartStream();
            if (!this.sonyLoopRunning || this.shuttingDown) {
              break;
            }
            if (reopened) {
              this.statusText = '';
            }
            continue;
          }
        } else {
          consecutiveFailures = 0;
          await this.decodeJpegFrame(jpeg);
        }
        await this.delay(SONY_LIVE_VIEW_FRAME_INTERVAL_MS);
      }
    } finally {
      this.sonyLoopRunning = false;
    }
  }

  /** PTP/IP 取景帧（索尼 / 尼康）都是裸 JPEG：索尼侧由 SonyLiveView 剥掉 HTTP
   *  分块与 16 字节帧头，尼康侧由 NikonPtpIpService 剥掉 384 字节取景头。
   *  解码路径与松下帧一致：换帧前释放上一帧，任何路径下都释放 ImageSource。 */
  private async decodeJpegFrame(jpeg: Uint8Array): Promise<void> {
    let source: image.ImageSource | null = null;
    let pm: image.PixelMap | null = null;
    try {
      // 服务层返回的已经是裸 JPEG；万一它的 buffer 比视图大，先复制一份，
      // 否则 createImageSource 会读到整块取景缓冲区。
      const buffer: ArrayBuffer = (jpeg.byteOffset === 0 && jpeg.byteLength === jpeg.buffer.byteLength)
        ? jpeg.buffer as ArrayBuffer
        : jpeg.slice().buffer as ArrayBuffer;
      source = image.createImageSource(buffer);
      pm = await source.createPixelMap();
    } catch (error) {
      NikonPtpIpService.log(`ptpip-control decode failed: ${String(error)}`);
      pm = null;
    } finally {
      if (source !== null) {
        try {
          source.release();
        } catch (_releaseError) {
        }
      }
    }
    if (pm === null) {
      return;
    }
    this.publishFrame(pm);
  }

  /** 用户主动停止索尼实时取景：断循环 + 关流 + 结束取景 + 明确状态。
   *  SonyLiveView.stop 先关 HTTP 连接再下发 0x9207 disable，顺序与官方一致
   *  （camera/PtpIpCamera.java:939-946 之后 camera/CameraConnector.java:937-938）。 */
  private sonyStopLiveView(): void {
    this.sonyLoopRunning = false;
    if (this.sonyLiveViewOn) {
      this.sonyLiveViewOn = false;
      NikonPtpIpService.log('sony-control stop live view (user)');
      SonyLiveView.stop().catch((): void => {
      });
    }
    this.statusText = '已停止实时取景';
  }

  /**
   * 索尼快门：`SDIO_ControlDevice` (0x9207)，走 Sony 自己的静态拍摄序列。
   *
   * 这条路径**不用** `RequestOneShooting` (53959)：该控制码在 Sony 官方整棵树里
   * 没有任何调用方，而且它的 ordinal 5 在 `EnumControlCode.getData` 里没有 case，
   * 数据段长度是 0（`EnumControlCode.java:91-93`）。官方拍一张仍然照片是
   * `S1 按下 → S2 按下 → S2 抬起 → S1 抬起`
   * （`.../shoot/mode/StillShootMode.java:26-41`），S1 半按就是对焦，S2 才是快门；
   * 官方不在 S2 之前等对焦锁定（`FocusIndication` 53779 只喂状态图标）。序列与
   * 数值全部固化在 `SonyLiveView.captureStill`，本页不传也不猜任何数值。
   *
   * `afDrive` 决定要不要先发 S1 半按：共享底栏的「拍摄」是即时快门（裸 S2），
   * 附加底栏的「AF 半按后拍摄」是完整序列。
   */
  private async sonyCapture(afDrive: boolean): Promise<void> {
    if (this.shooting) {
      return;
    }
    if (!NikonPtpIpService.isControlReady()) {
      this.toast('未建立 PTP/IP 会话，无法释放快门');
      return;
    }
    this.shooting = true;
    this.statusText = afDrive ? '正在对焦并释放快门…' : '正在释放快门…';
    NikonPtpIpService.log(`sony-control shutter start afDrive=${afDrive}`);
    try {
      const code = await SonyLiveView.captureStill(afDrive);
      const ok = code === SONY_PTP_RESPONSE_OK;
      this.statusText = ok
        ? (afDrive ? 'AF 半按后拍摄完成' : '拍摄完成')
        : (code < 0
          ? '拍摄失败：PTP/IP 会话不可用'
          : `拍摄失败：相机拒绝 0x9207 ${afDrive ? 'S1/S2' : 'S2'}（响应 ${hexWord(code)}）`);
      AppLogStore.add(`sony-control shutter afDrive=${afDrive ? 'yes' : 'no'}`
        + ` code=${code} result=${ok ? 'ok' : 'failed'}`);
      // 同时进 hilog：快门失效时，「相机应答 0x2001 但没出片」和「相机直接拒绝」
      // 是两种完全不同的故障，只有真机日志能区分。
      NikonPtpIpService.log(`sony-control shutter done afDrive=${afDrive ? 1 : 0}`
        + ` code=${hexWord(code)} result=${ok ? 'ok' : 'failed'}`);
    } catch (error) {
      this.statusText = `拍摄异常：${String(error)}`;
      NikonPtpIpService.logError('sony-control shutter', error as Object);
    } finally {
      this.shooting = false;
    }
  }

  // -------------------------------------------------------------------------
  // 尼康线（与索尼线同构：共享同一条 PTP/IP 传输，厂商操作由
  // NikonPtpIpService 承担；页面形态、按钮面与取景管线和索尼线完全一致）
  // -------------------------------------------------------------------------

  /**
   * 尼康线连接。会话必须已经存在：相机页 openNikonCameraControl 会先按需拉起
   * 相机 Wi‑Fi 并建立 PTP/IP 会话，本页只消费它——没有会话时不启实时取景、
   * 不自行连接、不抛异常。
   *
   * 与索尼线的差别只有厂商操作本身：索尼要先用 0x9210 SDIO_OpenSession 换成
   * REMOTE_CONTROL_WITH_TRANSFER_MODE 的会话，且取景帧走一条独立的 HTTP 连接；
   * 尼康直接在既有 PTP/IP 会话上开取景（0x9201），帧由 0x9203 从 PTP 数据阶段
   * 取回，不需要第二条连接。
   */
  private async nikonStartConnect(seq: number): Promise<void> {
    if (!NikonPtpIpService.isControlReady()) {
      this.phase = 'error';
      this.statusText = '未建立 PTP/IP 会话：请先在相机页完成蓝牙配对，再点「相机控制」重试';
      NikonPtpIpService.log('nikon-control no ptpip session; live view not started');
      return;
    }
    this.statusText = '正在启动实时取景…';
    // **参数必须在开流之前探完。**
    //
    // 实测结论（见本文件顶部）：相机一旦挂起取景流，紧接着就不再应答任何厂商
    // 操作——`0x1015` 也是厂商操作，开流之后发就会一路超时。所以顺序是
    // 「先读参数 → 再开流」，而不是等界面渲染出来再补读。
    this.statusText = '正在读取相机参数…';
    await this.nikonRefreshParams();
    this.statusText = '正在启动实时取景…';
    NikonPtpIpService.log('nikon-control start live view');
    let started: boolean = false;
    try {
      started = await NikonPtpIpService.startLiveView();
    } catch (error) {
      NikonPtpIpService.log(`nikon-control start live view threw: ${String(error)}`);
      started = false;
    }
    if (seq !== this.connectSeq || this.shuttingDown) {
      // 页面已经走了：立刻收回刚刚打开的实时取景。
      if (started) {
        NikonPtpIpService.endLiveView().catch((): void => {
        });
      }
      return;
    }
    if (!started) {
      this.phase = 'error';
      this.statusText = '实时取景启动失败：相机未接受 0x9201 StartLiveView，'
        + '请确认机身已允许「连接至智能设备」的遥控取景';
      NikonPtpIpService.log('nikon-control start live view rejected');
      return;
    }
    this.nikonLiveViewOn = true;
    this.phase = 'live';
    this.statusText = '实时取景中';
    this.nikonStartLoop();
  }

  /** 尼康取帧循环：nikonLoopRunning 保证不自我重叠；每轮固定 sleep 一段，所以
   *  一个慢帧只会拖慢节奏，不会变成忙等（与索尼线同构）。 */
  /**
   * 回读"相机上报过变化"的那几个属性，并合并进 `nikonProps`。
   *
   * **只能在取景流停着的时候调用。** 流一挂起机身就不再处理命令，这时发 0x1014
   * 会超时并毒化会话（连 Wi‑Fi 一起掉）。所以调用点是复流流程里 `endLiveView`
   * 之后、`startLiveView` 之前那一小段窗口。
   *
   * 之所以要这样绕：机身会主动推 `0x4006 DevicePropChanged`（真机日志里见过
   * `params=[4294967295,20487]`，即光圈变了），**它自己告诉我们值变了**——但事件
   * 只带属性码、不带新值，所以还得回读一次。事件驱动的登记 + 安全窗口回读，是唯一
   * 既实时又不违反"流挂起不应答"约束的组合。
   */
  private async nikonRefreshChangedProps(): Promise<void> {
    const codes = NikonPtpIpService.takePendingPropChanges();
    if (codes.length === 0 || !this.nikonMode || this.shuttingDown) {
      return;
    }
    NikonPtpIpService.log(`nikon-control refresh changed props count=${codes.length}`);
    let changed = false;
    const merged: NikonPropertyState[] = this.nikonProps.slice();
    for (const code of codes) {
      const fresh = await NikonCameraParameters.describe(code);
      if (fresh === null) {
        continue;
      }
      let replaced = false;
      for (let index = 0; index < merged.length; index++) {
        if (merged[index].propertyCode === code) {
          merged[index] = fresh;
          replaced = true;
          break;
        }
      }
      if (!replaced) {
        merged.push(fresh);
      }
      changed = true;
    }
    if (changed) {
      // 整体替换而不是原地改字段：`nikonProps` 是 @State，换引用才会触发重绘。
      this.nikonProps = merged;
    }
  }

  /**
   * 重启尼康实时取景：`0x9202 EndLiveView` →（**在流停着的窗口里回读变化过的
   * 属性**）→ `0x9201 StartLiveView`。
   *
   * 机身推了一段时间会自己停流（`0x9203` 从此空回），但 PTP/IP 会话本身还是好
   * 的——重新开一次取景就能续上。只用在取帧循环里连丢几帧的时候，成功返回 true
   * 让循环继续，失败返回 false 交给原来的 30 次上限处理。
   *
   * 两个操作码都是本页已经在用的（`startLiveView` / `endLiveView`），不引入任何
   * 新协议假设。
   */
  private async nikonRestartLiveView(): Promise<boolean> {
    if (this.shuttingDown || !NikonPtpIpService.isControlReady()) {
      return false;
    }
    try {
      await NikonPtpIpService.endLiveView();
    } catch (error) {
      NikonPtpIpService.log(`nikon-control restart end-live-view threw: ${String(error)}`);
    }
    // **不要在复流窗口里读属性。**
    //
    // 试过了，代价很大：读完 5 个属性再 `startLiveView`，相机还在处理那些读，
    // 帧流被拖住 → 立刻又丢帧 → 再重启 → 最后 `startLiveView` 超时把会话毒化。
    // 日志里就是「live view restarted」紧接着「restart 1/3」再到
    // 「session poisoned ... transaction timeout」。复流要的是快，不是顺便干活。
    try {
      const started = await NikonPtpIpService.startLiveView();
      if (!started) {
        NikonPtpIpService.log('nikon-control restart start-live-view rejected');
        return false;
      }
      NikonPtpIpService.log('nikon-control live view restarted');
      return true;
    } catch (error) {
      NikonPtpIpService.log(`nikon-control restart start-live-view threw: ${String(error)}`);
      return false;
    }
  }

  private async nikonStartLoop(): Promise<void> {
    if (this.nikonLoopRunning || this.shuttingDown) {
      return;
    }
    this.nikonLoopRunning = true;
    let consecutiveFailures: number = 0;
    let streamRestarts: number = 0;
    let streamStartedAt: number = Date.now();
    /** 这一轮"没画面"是从什么时候开始的（-1 表示当前画面正常）。
     *
     *  判据用它而不是帧数：帧率会变（Z 8 约 130 ms 一帧），按帧数算阈值会随帧率
     *  飘——同一段代码在快机身上是 0.65 秒、在慢机身上是好几秒，行为不可预期。 */
    let failureSince: number = -1;
    /** 是否已经就"相机没有画面"提示过一次。只用来避免每轮都写 `statusText`，
     *  以及在有帧回来时把提示收回。 */
    let asleepNotified: boolean = false;
    try {
      while (this.nikonLoopRunning && !this.shuttingDown) {
        // **主动复流：在机身自己结束取景之前先续一次。**
        //
        // 机身到点会自行停流，紧接着连 Wi‑Fi 热点一起撤掉——那时再救已经晚了
        // （重启必然失败，因为链路都没了）。所以按时间提前复流，用户只看到画面
        // 极短地顿一下。这条不计入 `streamRestarts`：它是计划内的维护，不是故障
        // 恢复，不该吃掉故障重试的额度。
        // **不要为参数变化而复流。**
        //
        // 实测：取景时机身会**持续**推 `0x4006`（光圈 20487、焦距 20488、
        // 20492/20493、曝光程序 20494、ISO 20495 轮着来），静默期根本等不到，
        // 于是变成不停"停流→读→复流"，帧全丢、30 次上限触发、最后一次
        // `startLiveView` 超时把会话毒化，连 Wi-Fi 一起掉。
        //
        // 实时刷新在"流挂起就不应答命令"这个约束下做不到——除非哪天验证了流开着
        // 也能读。在那之前，参数值只在探测时和用户主动改参数时读（那两次是刻意
        // 停流的），不做自动刷新。
        if (NikonPtpIpService.hasPendingPropChanges()) {
          NikonPtpIpService.takePendingPropChanges();
        }
        if (Date.now() - streamStartedAt >= NIKON_LIVE_VIEW_PROACTIVE_RESTART_MS) {
          NikonPtpIpService.log('nikon-control proactive live view restart');
          const restarted = await this.nikonRestartLiveView();
          if (restarted) {
            streamStartedAt = Date.now();
            consecutiveFailures = 0;
            continue;
          }
          NikonPtpIpService.log('nikon-control proactive restart failed; falling back to failure handling');
          streamStartedAt = Date.now();
        }
        let jpeg: Uint8Array | null = null;
        try {
          jpeg = await NikonPtpIpService.liveViewFrame();
        } catch (error) {
          NikonPtpIpService.log(`nikon-control live view frame threw: ${String(error)}`);
          jpeg = null;
        }
        if (!this.nikonLoopRunning || this.shuttingDown) {
          break;
        }
        if (jpeg === null) {
          consecutiveFailures++;
          // **必须让出主线程。**
          //
          // 机身在睡眠时 `liveViewFrame()` 会**立刻**失败返回空帧。这个 while 里
          // 如果只 `await` 一个已经立即失败的 Promise，那只是在微任务队列里自旋，
          // 渲染帧永远排不进去——表现就是"相机睡眠→唤醒后页面卡死"。每次空帧
          // 显式等 120 ms 的宏任务，UI 才能重绘，也不会把 CPU 打满。
          await new Promise<void>((resolve: () => void): void => {
            setTimeout((): void => {
              resolve();
            }, 120);
          });
          // **会话真没了才重连，而且只重连一次、不放弃页面。**
          //
          // 走到这里说明 `session.failed`——也就是 socket 层真的出错了（EOF/RST）。
          // 现在 `poisonSession` 不再主动关 socket，超时也不再毒化会话，所以这条路
          // 只剩"链路真的断了"这一种情况，重连是唯一出路。
          //
          // 重连**保持取景状态**：不回到连接页、不重置参数面板，重连成功后直接补一次
          // `0x9201` 把帧流接上，用户看到的是画面顿一下再继续——和官方一样是"悄悄
          // 恢复"，而不是"弹出中断"。
          if (!NikonPtpIpService.isSessionAlive() && !this.nikonRecovering) {
            this.nikonRecovering = true;
            NikonPtpIpService.log('nikon-control session lost; recovering');
            if (this.phase !== 'error') {
              this.statusText = '画面暂停，正在自动恢复…';
            }
            const recovered = await NikonPtpIpService.recoverSession();
            this.nikonRecovering = false;
            NikonPtpIpService.log(`nikon-control session recovery result=${recovered}`);
            if (!this.nikonLoopRunning || this.shuttingDown) {
              break;
            }
            if (recovered) {
              failureSince = -1;
              consecutiveFailures = 0;
              const restarted = await this.nikonRestartLiveView();
              if (restarted) {
                streamStartedAt = Date.now();
                this.phase = 'live';
                this.statusText = '实时取景中';
                continue;
              }
            }
          }
          // **先尝试重启取景，而不是一路数到 30 次才放弃。**
          //
          // 实测：机身推了一段之后会自己停流，此后 `0x9203 GetLiveViewImage`
          // 一直空回。这不是会话断了——重新下发 `0x9201 StartLiveView` 就能续上。
          //
          // 但**触发点必须按时间算**。原来按"连丢 5 帧"，在 130 ms 一帧的节奏下就是
          // 0.65 秒——相机只是短暂停顿，我们就急着下发 `0x9202`/`0x9201`，而相机
          // 若正在睡觉，这两条会挂到 10 秒事务超时并把会话毒化，后面全线崩。改成
          // "连续 N 毫秒没画面"之后，短暂停顿会被安静地等过去。
          if (failureSince < 0) {
            failureSince = Date.now();
          }
          const stalledMs = Date.now() - failureSince;
          if (stalledMs >= NIKON_LIVE_VIEW_RESTART_AFTER_MS &&
            streamRestarts < NIKON_LIVE_VIEW_MAX_STREAM_RESTARTS) {
            streamRestarts++;
            failureSince = -1;
            consecutiveFailures = 0;
            NikonPtpIpService.log('nikon-control live view restart'
              + ` ${streamRestarts}/${NIKON_LIVE_VIEW_MAX_STREAM_RESTARTS}`
              + ` after stalledMs=${stalledMs}`);
            const restarted = await this.nikonRestartLiveView();
            if (restarted) {
              continue;
            }
          }
          if (stalledMs >= NIKON_LIVE_VIEW_ABANDON_AFTER_MS) {
            // **会话还活着就继续等，绝不因为"相机睡着了"收工。**
            //
            // 官方在机身睡眠期间**不中断**：连接一直挂着，画面停在最后一帧，用户
            // 半按快门唤醒机身之后帧流自己回来，画面随即恢复。我们以前到 15 秒就
            // 判失败、停循环、还顺手 `endLiveView`——于是"相机睡一下"就变成了用户
            // 看到的"中断了"，而且再也不会自己好。
            //
            // 所以这里只有一种情况可以认账：会话**确实失效**（`isSessionAlive()`
            // 为假，即 socket 层错误）而且上一轮重连也没救回来。只是"安静"的会话
            // 一律继续等下去，只把提示换成一行等待文案，不把 phase 打成 error。
            if (!NikonPtpIpService.isSessionAlive()) {
              this.nikonLoopRunning = false;
              this.phase = 'error';
              this.statusText = `实时取景中断：已 ${Math.round(stalledMs / 1000)} 秒没有画面，`
                + '且与相机的控制通道已断开，自动重连也未成功。'
                + '请确认相机的 Wi‑Fi 仍在广播，然后回相机页重新连接。';
              NikonPtpIpService.log('nikon-control live view stopped after'
                + ` stalledMs=${stalledMs} restarts=${streamRestarts} sessionAlive=0`);
              if (this.nikonLiveViewOn) {
                this.nikonLiveViewOn = false;
                NikonPtpIpService.endLiveView().catch((): void => {
                });
              }
              break;
            }
            if (!asleepNotified) {
              asleepNotified = true;
              this.statusText = '相机暂时没有画面（可能已进入待机）。'
                + '在相机上按一下快门即可唤醒，画面会自动恢复。';
              NikonPtpIpService.log('nikon-control waiting for sleeping camera'
                + ` stalledMs=${stalledMs}`);
            }
          }
        } else {
          consecutiveFailures = 0;
          failureSince = -1;
          if (asleepNotified) {
            // 机身醒了（或被唤醒）：把"等待"提示收回，页面回到正常状态。
            asleepNotified = false;
            this.phase = 'live';
            this.statusText = '实时取景中';
            NikonPtpIpService.log('nikon-control live view resumed after standby');
          }
          // 与索尼线共用同一条解码路径（裸 JPEG → PixelMap → publishFrame）。
          await this.decodeJpegFrame(jpeg);
        }
        await this.delay(NIKON_LIVE_VIEW_FRAME_INTERVAL_MS);
      }
    } finally {
      this.nikonLoopRunning = false;
    }
  }

  /** 用户主动停止尼康实时取景：断循环 + 下发 0x9202 EndLiveView + 明确状态。 */
  private nikonStopLiveView(): void {
    this.nikonLoopRunning = false;
    if (this.nikonLiveViewOn) {
      this.nikonLiveViewOn = false;
      NikonPtpIpService.log('nikon-control stop live view (user)');
      NikonPtpIpService.endLiveView().catch((): void => {
      });
    }
    this.statusText = '已停止实时取景';
  }

  /**
   * 尼康快门：`InitiateCapture` (0x9207) 走 NikonPtpIpService，由它负责
   * 「等机身就绪 → 下发拍摄 → 轮询到机身报告完成」的完整序列，并把 `afDrive`
   * 映射成释放模式（AF 半按后释放 / 立即释放）。本页不传也不猜任何数值。
   *
   * 返回值是布尔而不是 PTP 应答码，所以文案按「机身是否受理并出片」组织；
   * 相机应答繁忙码也按成功处理（`NikonPtpIpService.isBusyCode`），这是官方
   * 的等待语义。
   */
  private async nikonCapture(afDrive: boolean): Promise<void> {
    if (this.shooting) {
      return;
    }
    if (!NikonPtpIpService.isControlReady()) {
      this.toast('未建立 PTP/IP 会话，无法释放快门');
      return;
    }
    this.shooting = true;
    this.statusText = afDrive ? '正在对焦并释放快门…' : '正在释放快门…';
    NikonPtpIpService.log(`nikon-control shutter start afDrive=${afDrive ? 1 : 0}`);
    try {
      const ok = await NikonPtpIpService.capture(afDrive);
      this.statusText = ok
        ? (afDrive ? 'AF 半按后拍摄完成' : '拍摄完成')
        : '拍摄失败：相机未完成拍摄，请确认机身已就绪且存储卡在位';
      AppLogStore.add(`nikon-control shutter afDrive=${afDrive ? 'yes' : 'no'}`
        + ` result=${ok ? 'ok' : 'failed'}`);
      NikonPtpIpService.log(`nikon-control shutter done afDrive=${afDrive ? 1 : 0}`
        + ` result=${ok ? 'ok' : 'failed'}`);
    } catch (error) {
      this.statusText = `拍摄异常：${String(error)}`;
      NikonPtpIpService.logError('nikon-control shutter', error as Object);
    } finally {
      this.shooting = false;
    }
  }

  /**
   * 索尼遥控录像开关：`SDIO_ControlDevice` (0x9207) 控制码
   * `MovieRecButton`（53960，ordinal 6 → 2 字节小端 `EnumControlValue`）。
   *
   * **起停走不同的动作，这是官方的行为不是笔误**：
   *  - 开始 = 只发「按下」。`MovieRecMode.java:45` 在 `State.NotRecording` 里
   *    只有 `pressButton(EnumButton.MovieRec, ...)`，没有任何 release。
   *  - 停止 = 先「按下」再「抬起」。`MovieRecMode.java:142-143` 在
   *    `State.Recording` 里 `pressButton` 之后紧跟 `releaseButton`。
   *
   * 两个动作都由手指**抬起**触发（`EnumVirtualMotionEvent.ActionUp`），也就是说
   * 一次点击 = 一次切换，不需要长按。
   *
   * 当前是否在录由相机属性 `MovieRecordingState`（53789）决定，**只认值 1**——
   * 0/2/3/255 分别是未录/失败/等待/未定义，都不是「正在录」。属性缺席时退回本页
   * 的本地 `recording` 标记，宁可猜也不让按钮点不动。
   */
  private async sonyToggleVideo(): Promise<void> {
    if (this.sonyVideoBusy) {
      // 上一次起停还在等相机确认。放行的话两次按钮点击会交错，后一次的确认轮询会
      // 拿着前一次的状态去覆盖标签。
      return;
    }
    if (!NikonPtpIpService.isControlReady()) {
      this.toast('未建立 PTP/IP 会话，无法遥控录像');
      return;
    }
    this.sonyVideoBusy = true;
    try {
      const fromCamera = SonyPtpIpContent.movieRecording();
      const rolling = fromCamera === undefined ? this.recording : fromCamera;
      if (fromCamera === undefined) {
        this.statusText = '相机未上报录像状态，按本页记录推断';
      }
      const code = rolling
        ? await SonyLiveView.stopMovieRecording()
        : await SonyLiveView.startMovieRecording();
      const ok = code === SONY_PTP_RESPONSE_OK;
      if (ok) {
        // 先立刻反映到按钮上，不等相机确认——否则点击到标签变化之间有一段空窗，
        // 观感就是「点了没反应」。
        this.recording = !rolling;
        if (!rolling) {
          this.recStartedAt = Date.now();
        }
      }
      this.statusText = ok
        ? (this.recording ? '录像已开始' : '录像已停止')
        : (code < 0
          ? '录像失败：PTP/IP 会话不可用'
          : `录像失败：相机拒绝 0x9207 MovieRec（响应 ${hexWord(code)}）`);
      // hilog 而不是只进 AppLogStore：这个按钮出问题时，真机日志是唯一能看出
      // 「相机接受了但没录」与「相机拒绝了」区别的地方。
      NikonPtpIpService.log(`sony-control movie-rec rolling=${rolling ? 1 : 0}`
        + ` fromCamera=${fromCamera === undefined ? 'unknown' : (fromCamera ? 1 : 0)}`
        + ` code=${hexWord(code)}`);
      if (ok) {
        // 按**期望值**轮询确认，不能读一次就照抄——见 sonyAwaitRecordingState。
        const expected = this.recording;
        const seen = await this.sonyAwaitRecordingState(expected);
        if (seen !== undefined && seen !== expected) {
          // 窗口内相机始终没切过去：以相机为准，不用乐观值糊弄（可能没卡、可能机身
          // 拒绝了这次起录），并明确告诉用户按钮为何弹回去。
          this.recording = seen;
          this.statusText = seen ? '相机已在录像' : '相机并未开始录像';
          NikonPtpIpService.log(`sony-control movie-rec corrected to ${seen ? 1 : 0}`);
        }
      }
    } catch (error) {
      this.statusText = `录像异常：${String(error)}`;
      NikonPtpIpService.logError('sony-control movie-rec', error as Object);
    } finally {
      this.sonyVideoBusy = false;
    }
  }

  /**
   * 起停之后确认相机是否真的切到了期望状态。
   *
   * **不能只看一次**：刚发完 `MovieRecButton` 时相机的 `MovieRecordingState` 还没
   * 翻转，立刻 dump 读到的仍是**旧值**，照抄就会把按钮标签弹回原样——这正是
   * 「点了按钮没立马变成停止录像」的原因。属性表又是 0x9209 的一次性快照，写操作
   * 不会更新它，必须重新 dump 才能读到新值。
   *
   * 命中期望值就立刻返回（通常第一次就中）；窗口内一直没命中就返回相机最后报的值，
   * 由调用方以相机为准并给出提示。
   *
   * @returns 相机最后上报的状态；属性不可读时为 `undefined`。
   */
  private async sonyAwaitRecordingState(expected: boolean): Promise<boolean | undefined> {
    let last: boolean | undefined = undefined;
    for (let attempt = 0; attempt < SONY_MOVIE_REC_CONFIRM_TRIES; attempt += 1) {
      await this.delay(attempt === 0
        ? SONY_MOVIE_REC_CONFIRM_FIRST_MS
        : SONY_MOVIE_REC_CONFIRM_STEP_MS);
      if (this.shuttingDown) {
        return last;
      }
      const session = NikonPtpIpService.currentSession();
      if (session === null) {
        return last;
      }
      try {
        await SonyPtpIpContent.readAllExtDeviceProperties(session, 'movie-rec');
      } catch (error) {
        NikonPtpIpService.log(`sony-control movie-rec confirm threw: ${String(error)}`);
        return last;
      }
      last = SonyPtpIpContent.movieRecording();
      NikonPtpIpService.log(`sony-control movie-rec confirm try=${attempt + 1}`
        + ` expected=${expected ? 1 : 0}`
        + ` got=${last === undefined ? 'unknown' : (last ? 1 : 0)}`);
      if (last === expected) {
        return last;
      }
    }
    return last;
  }

  /**
   * 索尼触屏对焦/触屏 AE：`SDIO_ControlDevice` (0x9207) 控制码
   * `RemoteTouchOperation`（53988）。
   *
   * 与共享传输层上的尼康/松下路径不同，索尼这里**没有**「按下-抬起」配对，
   * 也**没有** MOVE/UP 处理：官方只在 ACTION_DOWN 上发一次，手指抬起不发任何
   * 东西（`.../liveview/TouchOperationController.java:153`，整个 onTouch 只有这
   * 一个动作分支）。取消是另一个独立按钮（同文件 :357-364），见 sonyCancelTouch。
   * 所以这里也不做「拖动重发」。
   *
   * 坐标空间是固定的 640x480 网格，不是取景帧尺寸：`RangePosition` 断言
   * x<=639、y<=479（`ptpip/button/RangePosition.java:18-19`），官方用
   * 640/视口长边、480/视口短边换算并截断取整（`TouchOperationController.java:188-192`、
   * `:225`、`:229-232`）。网格是 4:3 而取景帧是 3:2，所以换算是**各向异性**的，
   * 不能按画面比例修正——官方正是如此，不做修正。
   *
   * 可用性由相机属性 53892（Enable）与 53891（不为 OFF）决定，见
   * `SonyPtpIpContent.touchAfAvailable`；不可用时这里直接返回，一个字节都不发。
   */
  private async sonyTouchAt(viewX: number, viewY: number): Promise<void> {
    if (this.lvW <= 0 || this.lvH <= 0) {
      return;
    }
    if (!this.sonyTouchOn) {
      this.statusText = '触屏对焦不可用：相机未开启 Remote Touch Operation';
      return;
    }
    const gridX = Math.floor(viewX * SonyLiveView.AF_GRID_WIDTH / this.lvW);
    const gridY = Math.floor(viewY * SonyLiveView.AF_GRID_HEIGHT / this.lvH);
    this.afX = viewX;
    this.afY = viewY;
    if (this.afTimer >= 0) {
      clearTimeout(this.afTimer);
    }
    this.afTimer = setTimeout(() => {
      this.afX = -1;
      this.afY = -1;
      this.afTimer = -1;
    }, 1200);
    try {
      const code = await SonyLiveView.remoteTouch(gridX, gridY);
      const ok = code === SONY_PTP_RESPONSE_OK;
      AppLogStore.add(`sony-control touch grid=${gridX},${gridY}`
        + ` code=${code} result=${ok ? 'ok' : 'failed'}`);
      if (!ok) {
        this.statusText = code < 0
          ? '触屏对焦失败：PTP/IP 会话不可用'
          : `触屏对焦失败：相机拒绝 0x9207 RemoteTouchOperation（响应 ${hexWord(code)}）`;
      }
    } catch (error) {
      this.statusText = `触屏对焦异常：${String(error)}`;
      NikonPtpIpService.logError('sony-control touch', error as Object);
    }
  }

  /**
   * 「取消触屏对焦」：官方把它做成一个**按钮**而不是抬手动作，按下发
   * `CancelRemoteTouchOperation`（53989，2 字节 EnumControlValue），回调里再发
   * 一次抬起（`TouchOperationController.java:364` 与 `:374`；取值是
   * `BasePtpManager.java:1530` 的 Down 与 `:1709` 的 Up）。
   */
  private async sonyCancelTouch(): Promise<void> {
    if (!NikonPtpIpService.isControlReady()) {
      this.toast('未建立 PTP/IP 会话，无法取消触屏对焦');
      return;
    }
    try {
      const down = await SonyLiveView.cancelRemoteTouch(true);
      const up = await SonyLiveView.cancelRemoteTouch(false);
      const ok = down === SONY_PTP_RESPONSE_OK && up === SONY_PTP_RESPONSE_OK;
      AppLogStore.add(`sony-control touch-cancel down=${down} up=${up}`
        + ` result=${ok ? 'ok' : 'failed'}`);
      this.statusText = ok ? '已取消触屏对焦' : `取消失败：响应 ${hexWord(up)}`;
      this.afX = -1;
      this.afY = -1;
    } catch (error) {
      this.statusText = `取消触屏对焦异常：${String(error)}`;
      NikonPtpIpService.logError('sony-control touch-cancel', error as Object);
    }
  }

  /** 索尼参数面板要显示的参数对应的相机原始值，-1 表示没拿到。 */
  private sonyRawOf(panel: string): number {
    if (panel === 'aperture') {
      return this.sonyApertureRaw;
    }
    if (panel === 'shutter') {
      return this.sonyShutterRaw;
    }
    if (panel === 'iso') {
      return this.sonyIsoRaw;
    }
    if (panel === 'ev') {
      return this.sonyEvRaw;
    }
    if (panel === 'mode') {
      return this.sonyModeRaw;
    }
    if (panel === 'wb') {
      return this.sonyWbRaw;
    }
    if (panel === 'quality') {
      return this.sonyQualityRaw;
    }
    if (panel === 'aspect') {
      return this.sonyAspectRaw;
    }
    return -1;
  }

  /**
   * 索尼参数选项：来自相机自己声明的可选值（0x9209 记录里的 `mGetSetValues`），
   * 不是本页硬编码的松下域。`opt.value` 存相机的原始十进制值，`opt.label` 用
   * 索尼自己的格式渲染——两者都由 `SonyPtpIpControl` 从同一条记录得出。
   */
  private sonyPanelOptions(): LumixSettingOption[] {
    const out: LumixSettingOption[] = [];
    const code = SonyPtpIpControl.displayCodeOf(this.panel);
    if (code === 0) {
      return out;
    }
    const options = SonyPtpIpContent.propertyOptions(code);
    if (options.length === 0) {
      // 相机没给可选值列表（例如这个属性是 Range 形式而不是 Enumeration）。
      // 那就至少把当前值显示出来，而不是给一个空白条；点它等于重发同一个值。
      // 下一次真机运行的 `sony params` 日志会说明哪个参数是 opt0。
      const raw = this.sonyRawOf(this.panel);
      if (raw >= 0) {
        const only: LumixSettingOption = {
          value: `${raw}`,
          label: SonyPtpIpControl.formatValue(code, raw)
        };
        out.push(only);
      }
      return out;
    }
    options.forEach((raw: number): void => {
      const opt: LumixSettingOption = {
        value: `${raw}`,
        label: SonyPtpIpControl.formatValue(code, raw)
      };
      out.push(opt);
    });
    return out;
  }

  /**
   * 从已累积的 0x9209 属性表回填索尼参数：光圈 / 快门 / ISO / 曝光补偿。
   *
   * 纯读，不发任何请求：这四个值以及它们的可选值列表都在打开会话时那次
   * `SDIO_GetAllExtDevicePropInfo` 的答复里（见 `SonyPtpIpControl` 顶部）。
   * 标签写回复用共享参数行的既有 `this.info.*` 字段，所以参数行本身不需要认识
   * 索尼；索尼线上这些字段本来也没有别的写入者。
   */
  private sonyRefreshParams(): void {
    const aperture = SonyPtpIpControl.parameterOf('aperture');
    this.sonyApertureRaw = aperture.known ? aperture.raw : -1;
    this.info.apertureLabel = aperture.display;
    const shutter = SonyPtpIpControl.parameterOf('shutter');
    this.sonyShutterRaw = shutter.known ? shutter.raw : -1;
    this.info.shutterLabel = shutter.display;
    const iso = SonyPtpIpControl.parameterOf('iso');
    this.sonyIsoRaw = iso.known ? iso.raw : -1;
    this.info.isoLabel = iso.display;
    const ev = SonyPtpIpControl.parameterOf('ev');
    this.sonyEvRaw = ev.known ? ev.raw : -1;
    this.info.evLabel = ev.display;
    // 其余四个面板用同一套读取通道，只是字段放在本页自己的 @State 里：
    // `info` 的那几个字段归松下/Sync 线，索尼不共用以免互相覆盖。
    const mode = SonyPtpIpControl.parameterOf('mode');
    this.sonyModeRaw = mode.known ? mode.raw : -1;
    this.sonyModeLabel = mode.known ? mode.display : '';
    const wb = SonyPtpIpControl.parameterOf('wb');
    this.sonyWbRaw = wb.known ? wb.raw : -1;
    this.sonyWbLabel = wb.known ? wb.display : '';
    const quality = SonyPtpIpControl.parameterOf('quality');
    this.sonyQualityRaw = quality.known ? quality.raw : -1;
    this.sonyQualityLabel = quality.known ? quality.display : '';
    const aspect = SonyPtpIpControl.parameterOf('aspect');
    this.sonyAspectRaw = aspect.known ? aspect.raw : -1;
    this.sonyAspectLabel = aspect.known ? aspect.display : '';
    // 录像状态也以相机为准：进入页面或重新 dump 之后，底栏那个键的标签要立刻
    // 反映机身真实状态，而不是沿用上一次会话留下的本地标记。
    const rolling = SonyPtpIpContent.movieRecording();
    if (rolling !== undefined) {
      this.recording = rolling;
    }
    let writable = 0;
    if (aperture.writable) {
      writable += 1;
    }
    if (shutter.writable) {
      writable += 1;
    }
    if (iso.writable) {
      writable += 1;
    }
    if (ev.writable) {
      writable += 1;
    }
    NikonPtpIpService.log(`sony-control params aperture=${aperture.display}` +
      ` shutter=${shutter.display} iso=${iso.display} ev=${ev.display}` +
      ` mode=${mode.display} wb=${wb.display}` +
      ` quality=${quality.display} aspect=${aspect.display}` +
      ` writable=${writable}/4`);
  }

  /**
   * 索尼参数写回：`SDIO_SetExtDevicePropValue` (0x9205)，载荷是按该属性自己
   * 声明的 `EnumDataType` 宽度的小端标量（`SonyPtpIpControl.applySetting`）。
   *
   * 相机声明该属性只读、或 `RemoteControlRestrictionStatus` 不为 0 时，
   * `applySetting` 在发请求之前就返回失败码——这里只负责把失败说清楚，不去
   * 发一个注定被拒的操作。
   */
  private async applySonySetting(tag: string, value: string,
    keepPanel: boolean): Promise<void> {
    const raw = Number.parseInt(value, 10);
    if (Number.isNaN(raw)) {
      this.toast('该参数取值无法识别');
      return;
    }
    if (!keepPanel) {
      this.panel = '';
    }
    const code = await SonyPtpIpControl.applySetting(tag, raw);
    if (code === SONY_PTP_RESPONSE_OK) {
      // 相机已确认这个值，就把它写进累积表：否则面板会继续显示旧值
      // （真机上表现为 aspect 连点四次、`sony set` 每次都 result=8193，
      // 而 `sony-control params ... aspect=` 始终是 1）。
      const written = SonyPtpIpControl.displayCodeOf(tag);
      if (written !== 0) {
        SonyPtpIpContent.notePropertyWritten(written, raw);
      }
      this.sonyRefreshParams();
      this.statusText = '参数已更新';
      AppLogStore.add(`sony-control param ${tag}=${raw} result=ok`);
      return;
    }
    let reason: string = `响应 ${hexWord(code)}`;
    if (code === SonyPtpIpControl.FAIL_NOT_WRITABLE) {
      reason = '相机声明该参数不可写';
    } else if (code === SonyPtpIpControl.FAIL_RESTRICTED) {
      reason = '相机当前不接受参数修改（模式限制）';
    } else if (code === SonyPtpIpControl.FAIL_UNKNOWN_WIDTH) {
      reason = '相机未声明该参数的数据类型';
    } else if (code === SonyPtpIpControl.FAIL_NO_SESSION) {
      reason = 'PTP/IP 会话不可用';
    } else if (code === SonyPtpIpControl.FAIL_NO_SUCH_PARAMETER) {
      reason = '索尼没有这个参数';
    }
    this.statusText = `参数设置失败：${reason}`;
    AppLogStore.add(`sony-control param ${tag}=${raw} result=failed code=${code}`);
  }

  // -------------------------------------------------------------------------
  // Liveview stream
  // -------------------------------------------------------------------------

  private handleFrame(frame: LumixLiveviewFrame): void {
    if (this.shuttingDown || this.phase === 'error') {
      return;
    }
    if (frame.width !== this.frameW || frame.height !== this.frameH) {
      this.frameW = frame.width;
      this.frameH = frame.height;
    }
    // Sync 线不解析 C2818b 帧内元数据（与 Lab Q0 布局不同），帧 info 恒为
    // 默认 '--'——每帧整体替换会把 getsetting 轮询更新的鼓轮/芯片标签
    // 冲掉（2026-09-28 实测 ISO/WB 恒显 '--' 的根因）。Sync 线跳过帧
    // info 覆盖，标签只由 getsetting 驱动
    if (!this.syncMode && !frame.info.sameAs(this.info)) {
      this.info = frame.info;
      this.remoteOn = frame.info.operateRemote;
    }
    if (this.decoding) {
      this.pendingFrame = frame;
      return;
    }
    this.decodeFrame(frame);
  }

  private async decodeFrame(frame: LumixLiveviewFrame): Promise<void> {
    this.decoding = true;
    try {
      const source = image.createImageSource(frame.jpeg);
      const pm = await source.createPixelMap();
      source.release();
      this.publishFrame(pm);
    } catch (_error) {
    } finally {
      this.decoding = false;
      const next = this.pendingFrame;
      this.pendingFrame = null;
      if (next !== null && !this.shuttingDown) {
        this.decodeFrame(next);
      }
    }
  }

  /** 把一帧解码结果交给取景区（松下与索尼共用），换帧前释放上一帧；
   *  页面已销毁时直接释放新帧，不触碰 UI 状态。 */
  private publishFrame(pm: image.PixelMap): void {
    if (this.shuttingDown) {
      try {
        pm.release();
      } catch (_error) {
      }
      return;
    }
    // 画面尺寸以解码出来的 PixelMap 为准。**这里是唯一入口**：松下帧走
    // handleFrame 时也会带 width/height，但索尼帧不带，于是索尼线的
    // frameW/frameH 一直是 0 —— 而预览的「横流是否转 90°」正是按这两个值判断的
    // （previewRotated 首帧未到时返回 false），结果就是索尼预览永远不转。
    // 放到这里而不是索尼解码处，两条线就都有一份可信的尺寸。
    try {
      const size = pm.getImageInfoSync().size;
      if (size.width > 0 && size.height > 0 &&
        (size.width !== this.frameW || size.height !== this.frameH)) {
        this.frameW = size.width;
        this.frameH = size.height;
        NikonPtpIpService.log(`sony-control frame size ${size.width}x${size.height}`);
      }
    } catch (error) {
      NikonPtpIpService.log(`sony-control frame size failed: ${String(error)}`);
    }
    const old = this.framePm;
    this.framePm = pm;
    if (old !== undefined) {
      try {
        old.release();
      } catch (_error) {
      }
    }
  }

  /** 8s watchdog fired: rebuild the stream (official recovery path). */
  private async handleStall(): Promise<void> {
    if (this.shuttingDown || this.phase !== 'live' || this.restartBusy) {
      return;
    }
    this.restartBusy = true;
    this.statusText = '取景中断，正在恢复…';
    try {
      await this.restartStream();
      this.statusText = '';
    } catch (error) {
      this.enterError(`取景恢复失败：${this.errText(error)}`);
    } finally {
      this.restartBusy = false;
    }
  }

  private async restartStream(): Promise<void> {
    if (this.syncMode) {
      if (this.receiver === null) {
        throw new LumixControlError('auth', '相机未连接');
      }
      await LumixSyncControlService.stopStream(this.syncHost);
      const start = await LumixSyncControlService.startStream(this.syncHost, this.receiver.port);
      if (!start.ok) {
        throw new LumixControlError('auth', start.message);
      }
      this.receiver.resume();
      return;
    }
    if (this.session === null || this.receiver === null) {
      throw new LumixControlError('auth', '相机未连接');
    }
    await LumixControlService.stopStream(this.session);
    await LumixControlService.startStream(this.session, this.receiver.port);
    const lvPort = await LumixControlService.fetchLvPort(this.session);
    await this.primePostLvport(this.session);
    await this.receiver.startDtls(this.session.host, lvPort);
    this.receiver.resume();
  }

  private onLiveviewTap(event: ClickEvent): void {
    if (this.sonyMode) {
      this.sonyTouchAt(event.x, event.y);
      return;
    }
    if (this.nikonMode) {
      // 尼康线没有触屏对焦通道：NikonPtpIpService 只有取景与快门，没有
      // 点击对焦操作码。这里必须早退，否则会落进下面的松下分支，在
      // session 为 null 时按 frameW/frameH 换算坐标并发 sendTouchAf。
      return;
    }
    if (this.phase !== 'live' || this.lvW <= 0 || this.lvH <= 0) {
      return;
    }
    if (this.syncMode) {
      // Sync 线触屏对焦：camctrl touch，坐标归一化 0-1000（官
      // i.java: o("touch", "500/500", "on") 同型）
      const nx = Math.max(0, Math.min(1000, Math.round(event.x / this.lvW * 1000)));
      const ny = Math.max(0, Math.min(1000, Math.round(event.y / this.lvH * 1000)));
      this.afX = event.x;
      this.afY = event.y;
      if (this.afTimer >= 0) {
        clearTimeout(this.afTimer);
      }
      this.afTimer = setTimeout(() => {
        this.afX = -1;
        this.afY = -1;
        this.afTimer = -1;
      }, 1200);
      LumixSyncControlService.sendCamCtrl(this.syncHost, 'touch', `${nx}/${ny}`, 'on').catch(() => {
      });
      return;
    }
    if (this.frameW <= 0 || this.frameH <= 0) {
      return;
    }
    // objectFit CONTAIN: map the tap from view coordinates to liveview pixels.
    const scale = Math.min(this.lvW / this.frameW, this.lvH / this.frameH);
    const dx = (this.lvW - this.frameW * scale) / 2;
    const dy = (this.lvH - this.frameH * scale) / 2;
    const x = Math.round((event.x - dx) / scale);
    const y = Math.round((event.y - dy) / scale);
    if (x < 0 || y < 0 || x >= this.frameW || y >= this.frameH) {
      return;
    }
    this.afX = event.x;
    this.afY = event.y;
    if (this.afTimer >= 0) {
      clearTimeout(this.afTimer);
    }
    this.afTimer = setTimeout(() => {
      this.afX = -1;
      this.afY = -1;
      this.afTimer = -1;
    }, 1200);
    this.sendTouchAf(x, y);
  }

  /** Official touch AF is an on/off/on/off burst (~60ms apart). */
  private async sendTouchAf(x: number, y: number): Promise<void> {
    const fire = async (on: boolean): Promise<void> => {
      try {
        await this.control<void>((s: LumixControlSession) => LumixControlService.sendTouchAf(s, x, y, on));
      } catch (_error) {
        // Touch AF is best-effort; in camera-priority mode the body may refuse.
      }
    };
    await fire(true);
    await this.delay(60);
    await fire(false);
    await this.delay(60);
    await fire(true);
    await this.delay(60);
    await fire(false);
  }

  // -------------------------------------------------------------------------
  // Camera actions
  // -------------------------------------------------------------------------

  /**
   * 切换相机端优先权（`operatepriority` 0x00 机身 / 0x01 手机）。
   *
   * ⚠ 当前**没有 UI 调用它**：原先顶栏的「预览 / 遥控」分段控件是唯一入口，
   * 2026-10-18 按用户决定把那一位改成「预览 / 控制」(详见 `topBar` 里的注释)，
   * 因为 Lab 线更需要全屏只读预览。相机端优先权改由机身自己决定，本页只通过
   * 帧元数据 `frame.info.operateRemote` 同步显示到 `remoteOn`。
   * 保留此方法是为了协议可追溯：要恢复那个开关时不必重新反推报文。
   */
  private async togglePriority(): Promise<void> {
    if (this.syncMode || this.session === null) {
      return;
    }
    const target = this.remoteOn ? '0x00' : '0x01';
    try {
      await this.control<void>((s: LumixControlSession) =>
        LumixControlService.applySetting(s, 'operatepriority', target));
      // Under smartphone priority the body forces P; liveview reflects it within 2s.
    } catch (error) {
      this.toast(`切换失败：${this.errText(error)}`);
    }
  }

  private async capture(): Promise<void> {
    if (this.sonyMode) {
      // 走官方的**完整**序列 S1 按下 → S2 按下 → S2 抬起 → S1 抬起
      // （`StillShootMode.java:26-41`），不是裸 S2。
      //
      // 之前共享底栏用的是 afDrive=false（只发 S2 一按一放），理由是「裸 S2 就是
      // 即时快门」——那是我的推断，不是官方路径。实测该序列两帧都拿到 0x2001
      // （相机接受了），但机身上并不出片：S1 半按不只是对焦，它同时把快门置为
      // 「已武装」，缺了它 S2 只是被应答、不触发。既然「AF 半按后拍摄」按钮已删，
      // 这一个按钮就应该做官方那套完整动作。
      await this.sonyCapture(true);
      return;
    }
    if (this.nikonMode) {
      // 复用索尼线的同一个「拍摄」按钮：走 NikonPtpIpService 的完整拍摄序列
      // （等机身就绪 → InitiateCapture → 轮询到机身报告完成），afDrive 映射成
      // AF 半按后释放。
      await this.nikonCapture(true);
      return;
    }
    if (this.syncMode) {
      await this.syncCapture();
      return;
    }
    if (this.session === null) {
      this.toast('相机未连接');
      return;
    }
    if (this.shooting) {
      return;
    }
    this.shooting = true;
    try {
      await this.control<void>((s: LumixControlSession) => LumixControlService.sendCamCmd(s, 'capture'));
      this.toast('已拍摄');
      // Official app auto-sends capture_cancel to release the shutter state.
      setTimeout(() => {
        this.control<void>((s: LumixControlSession) =>
          LumixControlService.sendCamCmd(s, 'capture_cancel')).catch(() => {
        });
      }, 280);
    } catch (error) {
      this.toast(`拍摄失败：${this.errText(error)}`);
    } finally {
      this.shooting = false;
    }
  }

  private async toggleVideo(): Promise<void> {
    if (this.sonyMode) {
      await this.sonyToggleVideo();
      return;
    }
    if (this.nikonMode) {
      await this.nikonToggleVideo();
      return;
    }
    if (this.syncMode) {
      await this.syncToggleVideo();
      return;
    }
    if (this.session === null) {
      this.toast('相机未连接');
      return;
    }
    if (this.recording) {
      try {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.sendCamCmd(s, 'video_recstop'));
        this.recording = false;
      } catch (error) {
        this.toast(`停止失败：${this.errText(error)}`);
      }
    } else {
      try {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.sendCamCmd(s, 'video_recstart'));
        this.recStartedAt = Date.now();
        this.recording = true;
      } catch (error) {
        this.toast(`开始失败：${this.errText(error)}`);
      }
    }
  }

  /**
   * 尼康遥控录像：`0x920A` 开始、`0x920B` 停止。
   *
   *  **不套用 `nikonCapture` 那套序列。** 拍照是「等就绪 → InitiateCapture →
   *  轮询到完成」的一次性事务，录像不是：`0x920A` 只负责开始，停止是另一条命令，
   *  中间是一段可以长达几十分钟的连续录制，机身用 `0xC10A`/`0xC108`/`0xC105`
   *  事件回报状态。所以这里只发一条命令、拿应答判断是否被接受。
   *
   *  取景**不停**：机身录像是自己开流写着录的，和我们这边的取景是两条线；停流只会
   *  让用户看不见画面，对录制没有任何帮助。
   *
   *  状态以"机身说了算"为准：我们只在 `0x920A` 被回 `0x2001` 时点亮"录制中"，
   *  在 `0x920B` 被接受、或者机身推了结束事件（卡满/过热/机身按键）时收回。
   */
  private async nikonToggleVideo(): Promise<void> {
    if (!NikonPtpIpService.isControlReady()) {
      this.toast('相机会话未就绪，请回到控制页重新连接');
      return;
    }
    if (this.shooting) {
      return;
    }
    this.shooting = true;
    try {
      if (this.recording) {
        const stopped = await NikonPtpIpService.endMovieRecording();
        NikonPtpIpService.log(`nikon-control movie rec stop accepted=${stopped}`);
        if (stopped) {
          this.recording = false;
          this.statusText = '实时取景中';
          this.toast('已停止录像');
        } else {
          this.toast('停止录像未获相机确认，请再点一次');
        }
      } else {
        const started = await NikonPtpIpService.startMovieRecording();
        NikonPtpIpService.log(`nikon-control movie rec start accepted=${started}`);
        if (started) {
          this.recStartedAt = Date.now();
          this.recording = true;
          this.toast('开始录像');
        } else {
          // 最常见的两个原因：机身不在录像模式（拨盘在拍照侧），或者卡的写入权限/
          // 空间不允许。机身只回一个非 0x2001 的码，不会告诉我们具体是哪个。
          this.toast('开始录像未获相机确认：请确认机身拨到录像模式，且存储卡可写');
        }
      }
    } catch (error) {
      NikonPtpIpService.log(`nikon-control movie rec threw: ${String(error)}`);
      this.toast('录像命令失败，请再试一次');
    } finally {
      this.shooting = false;
    }
  }


  private async applyTagged(tag: string, value: string, keepPanel: boolean = false): Promise<void> {
    if (this.nikonMode) {
      // 尼康：写 PTP 设备属性（0x1016 SetDevicePropValue），值按描述符声明的
      // 宽度编码。`tag` 就是参数面板名，`value` 是属性值本身（选项列表按它生成）。
      if (!keepPanel) {
        this.panel = '';
      }
      const numeric = Number(value);
      if (Number.isNaN(numeric)) {
        return;
      }
      await this.nikonSetParameter(tag, numeric);
      return;
    }
    if (this.syncMode) {
      await this.applySyncSetting(tag, value, keepPanel);
      return;
    }
    if (this.sonyMode) {
      await this.applySonySetting(tag, value, keepPanel);
      return;
    }
    if (this.session === null) {
      this.toast('相机未连接');
      return;
    }
    if (!keepPanel) {
      this.panel = '';
    }
    try {
      if (tag === 'lut') {
        // 照片格调：官方对 S1RM2/S5M2 都走 set-setting photostyle
        // （2026-09-29 18:52 抓包：STD=0x0000/VIVID=0x0001/NAT=0x0002）
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.applySetting(s, 'photostyle', value));
        this.toast('已切换照片格调');
      } else if (tag === 'metering') {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.applySetting(s, 'lightmetering', value));
      } else if (tag === 'lvsize') {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.applySetting(s, 'liveviewsize', value));
        await this.restartStream();
        this.toast('已切换取景画质');
      } else if (tag === 'quality') {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.applySetting(s, this.qualityKey, value));
      } else if (tag === 'aspect') {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.applySetting(s, 'aspectratio', value));
      } else if (tag === 'mode') {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.applySetting(s, 'recmode2', value));
      } else if (tag === 'wb') {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.applySetting(s, 'whitebalance', value));
      } else if (tag === 'iso') {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.applySetting(s, 'iso', value));
      } else if (tag === 'ev') {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.applySetting(s, 'exposure', value));
      } else if (tag === 'shutter') {
        await this.control<void>((s: LumixControlSession) =>
          LumixControlService.applySetting(s, 'shtrspeed', value));
      }
      this.reflectSetting(tag, value);
    } catch (error) {
      this.toast(this.errText(error));
    }
  }

  /**
   * 画质设置键：S5M2 走 quality；S1RM2 把画质拆成 pictureformat +
   * jpeg_heif(_quality)，set-setting quality 全 200 但不生效（2026-09-29
   * 14:48 实测）。loadCapabilities 探测到 pictureformat 能力后切到此键
   */
  private qualityKey: string = 'quality';

  /**
   * Sync line parameter writer (mode=setsetting, jadx B5/a.L()): the drum
   * types are iso / shtrspeed / focal (aperture) / exposure (EV) /
   * whitebalance; the exposure MODE dial is body-side and stays read-only
   * like in the official app.
   */
  private async applySyncSetting(tag: string, value: string, keepPanel: boolean): Promise<void> {
    if (this.syncHost.length === 0) {
      this.toast('相机未连接');
      return;
    }
    if (!keepPanel) {
      this.panel = '';
    }
    const type = this.syncSettingTypeOf(tag);
    if (type.length === 0) {
      this.toast('此机型不支持参数调整');
      return;
    }
    // focal 的 N/256 换算与 F 前缀归一已由 sendCamSetting 在协议边界完成；
    // 页面不再预处理（2026-09-28 曾在此处给 "2304/256" 二次加 F 前缀
    // → F2304/256 err_param）
    const wireValue = value;
    const result = await LumixSyncControlService.sendCamSetting(this.syncHost, type, wireValue);
    if (!result.ok) {
      // Some Sync bodies apply the setting but answer this request with a
      // non-standard verdict. Treat it as successful only after getstate
      // reports the exact requested value; a transport response alone is not
      // enough to claim success.
      if (await this.readBackSyncSetting(tag, wireValue)) {
        console.info(`VIVID_CTRL setting confirmed by getstate tag=${tag}`);
        return;
      }
      this.toast(`设置失败：${result.message}`);
      return;
    }
    this.reflectSyncSetting(tag, wireValue);
  }

  private async readBackSyncSetting(tag: string, expected: string): Promise<boolean> {
    const type = this.syncSettingTypeOf(tag);
    if (type.length === 0) {
      return false;
    }
    for (let attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await LumixImportPrototype.delay(180);
      }
      // getstate 不含鼓轮参数；回读走官方 getsetting 通道
      const result = await LumixSyncControlService.fetchSyncSetting(this.syncHost, type);
      if (!result.ok || result.value.length === 0) {
        continue;
      }
      this.reflectSyncSetting(tag, result.value);
      if (this.syncSettingMatches(tag, expected, result.value)) {
        return true;
      }
    }
    return false;
  }

  private syncSettingMatches(tag: string, expected: string, actual: string): boolean {
    if (actual.length === 0) {
      return false;
    }
    let wanted = expected.trim().toLowerCase().replace(/\s/g, '');
    let seen = actual.trim().toLowerCase().replace(/\s/g, '');
    if (tag === 'iso') {
      if (wanted.startsWith('iso')) wanted = wanted.substring(3);
      if (seen.startsWith('iso')) seen = seen.substring(3);
    }
    if (tag === 'shutter') {
      // 相机 256 量化与显示档差异：按秒值相对容差比较
      const wantedS = this.shutterSeconds(wanted);
      const seenS = this.shutterSeconds(seen);
      if (wantedS > 0 && seenS > 0) {
        const rel = Math.abs(wantedS - seenS) / Math.max(wantedS, seenS);
        return rel <= 0.15 || Math.abs(wantedS - seenS) <= 0.002;
      }
    }
    if (tag === 'aperture') {
      // N/256 有理数按分子容差比较（相机内部量化差异）
      const wantedN = this.focalNumerator(wanted);
      const seenN = this.focalNumerator(seen);
      if (wantedN > 0 && seenN > 0) {
        return Math.abs(wantedN - seenN) <= 2;
      }
      if (wanted.startsWith('f')) wanted = wanted.substring(1);
      if (seen.startsWith('f')) seen = seen.substring(1);
    }
    return wanted === seen;
  }

  private syncSettingTypeOf(tag: string): string {
    switch (tag) {
      case 'mode': return 'recmode';
      case 'iso': return 'iso';
      case 'shutter': return 'shtrspeed';
      case 'aperture': return 'focal';
      case 'ev': return 'exposure';
      case 'wb': return 'whitebalance';
      case 'lut': return 'photostyle';
      case 'quality': return 'quality';
      case 'aspect': return 'aspectratio';
      case 'metering': return 'lightmetering';
      default: return '';
    }
  }

  /** Optimistically mirror an applied Sync setting into the row labels.
   *  值未变化时直接返回：3 秒轮询拿到的相机参数与已有值相同时不再赋值，
   *  避免 @State 无谓刷新造成胶囊与滑条闪动。 */
  private reflectSyncSetting(tag: string, value: string): void {
    switch (tag) {
      case 'mode':
        if (this.syncModeRaw === value) {
          return;
        }
        this.syncModeRaw = value;
        this.info.modeLabel = this.syncModeLabel(value);
        break;
      case 'iso':
        if (this.syncStateRaw.iso === value) {
          return;
        }
        this.syncStateRaw.iso = value;
        this.info.isoLabel = this.syncIsoLabel(value);
        break;
      case 'shutter':
        if (this.syncStateRaw.shtrspeed === value) {
          return;
        }
        this.syncStateRaw.shtrspeed = value;
        this.info.shutterLabel = this.syncShutterLabel(value);
        break;
      case 'aperture':
        if (this.syncStateRaw.focal === value) {
          return;
        }
        this.syncStateRaw.focal = value;
        this.info.apertureLabel = this.syncFocalLabel(value);
        break;
      case 'ev':
        if (this.syncStateRaw.exposure === value) {
          return;
        }
        this.syncStateRaw.exposure = value;
        this.info.evLabel = this.syncExposureLabel(value);
        break;
      case 'wb':
        if (this.syncStateRaw.whitebalance === value) {
          return;
        }
        this.syncStateRaw.whitebalance = value;
        this.info.wbLabel = this.syncWbLabel(value);
        break;
      case 'lut':
        if (this.syncPhotoStyleRaw === value) {
          return;
        }
        this.syncPhotoStyleRaw = value;
        break;
      case 'quality':
        if (this.syncQualityRaw === value) {
          return;
        }
        this.syncQualityRaw = value;
        break;
      case 'aspect':
        if (this.syncAspectRaw === value) {
          return;
        }
        this.syncAspectRaw = value;
        break;
      case 'metering':
        if (this.syncMeteringRaw === value) {
          return;
        }
        this.syncMeteringRaw = value;
        break;
      default:
        break;
    }
  }

  /**
   * Optimistically mirror an applied setting into the display state: without a
   * live liveview metadata feed the param row would otherwise never refresh.
   */
  private reflectSetting(tag: string, value: string): void {
    console.info(`VIVID_CTRL reflect tag=${tag} value=${value}`);
    const n = parseHexValue(value);
    switch (tag) {
      case 'lut':
        // Q0 元数据块未含 photostyle 字段：本地回显，重连后回 '--'
        this.labPhotoStyleRaw = value;
        break;
      case 'mode':
        this.info.modeValue = n;
        this.info.modeLabel = Number.isNaN(n) ? value : modeLabelOf(n);
        break;
      case 'ev': {
        const thirds = evThirdsOf(n);
        this.info.evThirds = thirds;
        this.info.evLabel = formatEv(thirds);
        break;
      }
      case 'shutter': {
        const knownShutter = this.shutterLabels.get(value);
        // Lab 线给的是 32 位毫秒编码（"0x00001F40"），shutterNumerator 只认
        // "N/256"，对它返回 NaN——NaN 顺着 tvCur256 会污染后续换算，所以只在
        // 解析成功时才覆盖。
        const tv = shutterNumerator(value);
        if (!Number.isNaN(tv)) {
          this.info.tvCur256 = tv;
        }
        this.info.shutterLabel = knownShutter !== undefined && knownShutter.length > 0
          ? knownShutter : shutterOptionLabel(value);
        break;
      }
      case 'iso':
        this.info.isoValue = n;
        this.info.isoLabel = Number.isNaN(n) ? value : isoLabelOf(n);
        break;
      case 'wb':
        this.info.wbValue = n;
        this.info.wbLabel = Number.isNaN(n) ? value : wbLabelOf(n);
        break;
      case 'quality':
        this.info.qualityValue = n;
        this.info.qualityLabel = Number.isNaN(n) ? value : this.qualityLabelFor(n);
        break;
      case 'aspect':
        this.info.aspectValue = n;
        this.info.aspectLabel = Number.isNaN(n) ? value : aspectLabelOf(n);
        break;
      case 'metering':
        this.info.meteringValue = n;
        this.info.meteringLabel = Number.isNaN(n) ? value : meteringLabelOf(n);
        break;
      case 'lvsize':
        this.info.lvQualityValue = n;
        this.info.lvQualityLabel = Number.isNaN(n) ? value : lvQualityLabelOf(n);
        break;
      default:
        break;
    }
  }

  // -------------------------------------------------------------------------
  // Panel options
  // -------------------------------------------------------------------------

  private panelTitle(): string {
    switch (this.panel) {
      case 'lut': return '照片格调';
      case 'quality': return '画质';
      case 'aspect': return '照片比例';
      case 'settings': return '拍摄设置';
      case 'mode': return '曝光模式';
      case 'ev': return '曝光补偿';
      case 'shutter': return '快门速度';
      case 'aperture': return '光圈';
      case 'iso': return 'ISO';
      case 'wb': return '白平衡';
      default: return '';
    }
  }

  private rawListOf(key: string): string[] {
    switch (key) {
      case 'iso': return this.caps.iso;
      case 'whitebalance': return this.caps.whitebalance;
      case 'recmode2': return this.caps.recmode2;
      case 'shtrspeed': return this.caps.shtrspeed;
      case 'quality': return this.caps.quality;
      case 'photostyle': return this.caps.photostyle;
      case 'aspectratio': return this.caps.aspectratio;
      case 'lightmetering': return this.caps.lightmetering;
      case 'liveviewsize': return this.caps.liveviewsize;
      default: return [];
    }
  }

  /** Static fallback lists (official value tables) for unsupported/missing keys. */
  private fallbackList(key: string): string[] {
    switch (key) {
      case 'quality': return ['0x0000', '0x0001', '0x0003', '0x0004', '0x0005'];
      case 'photostyle':
        // S1RM2 值域顺序（2026-09-29 18:52 抓包），与机身菜单一致
        return ['0x0000', '0x0001', '0x0002', '0x002c', '0x0012', '0x0004', '0x0005',
          '0x0003', '0x000f', '0x0011', '0x002d', '0x0032', '0x0034', '0x0029', '0x002a',
          '0x000e', '0x0028', '0x0031', '0x0013', '0x0014', '0x0015', '0x0016'];
      case 'aspectratio': return ['0x0001', '0x0002', '0x0003', '0x0004', '0x000a', '0x000b'];
      case 'lightmetering': return ['0x0001', '0x0002', '0x0000', '0x0003'];
      case 'liveviewsize': return ['0x00', '0x01'];
      case 'whitebalance':
        return ['0x0002', '0x8014', '0x8015', '0x0004', '0x8008', '0x800f', '0x0006', '0x0007',
          '0x800b', '0x800c', '0x800d', '0x800e', '0x8010', '0x8011', '0x8012', '0x8013'];
      case 'recmode2': return ['0x0000', '0x0001', '0x0002', '0x0003', '0x0007', '0x0008', '0x0009', '0x000a'];
      case 'iso': return this.fallbackIso();
      case 'shtrspeed': return this.fallbackShutter();
      default: return [];
    }
  }

  private fallbackIso(): string[] {
    const iso: number[] = [100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600,
      2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600];
    const out: string[] = ['0xffffffff'];
    for (const v of iso) {
      out.push(hexWord(v));
    }
    return out;
  }

  private fallbackShutter(): string[] {
    const out: string[] = [];
    for (let t = 13; t >= -2.01; t -= 1 / 3) {
      out.push(`${Math.round(t * 256)}/256`);
    }
    return out;
  }

  private qualityLabelFor(n: number): string {
    return this.qualityKey === 'pictureformat' ? pictureFormatLabelOf(n) : qualityLabelOf(n);
  }

  private labelFor(key: string, raw: string): string {
    const n = parseHexValue(raw);
    switch (key) {
      case 'iso': return Number.isNaN(n) ? raw : isoLabelOf(n);
      case 'whitebalance': return Number.isNaN(n) ? raw : wbLabelOf(n);
      case 'recmode2': return Number.isNaN(n) ? raw : modeLabelOf(n);
      case 'quality': return Number.isNaN(n) ? raw : this.qualityLabelFor(n);
      case 'photostyle': return Number.isNaN(n) ? raw : photoStyleLabelOf(n);
      case 'aspectratio': return Number.isNaN(n) ? raw : aspectLabelOf(n);
      case 'lightmetering': return Number.isNaN(n) ? raw : meteringLabelOf(n);
      case 'liveviewsize': return Number.isNaN(n) ? raw : lvQualityLabelOf(n);
      case 'shtrspeed': {
        const known = this.shutterLabels.get(raw);
        return known !== undefined && known.length > 0 ? known : shutterOptionLabel(raw);
      }
      default: return raw;
    }
  }

  private optionsFor(key: string): LumixSettingOption[] {
    const raw = this.rawListOf(key);
    const source = raw.length > 0 ? raw : this.fallbackList(key);
    const out: LumixSettingOption[] = [];
    for (const v of source) {
      const opt: LumixSettingOption = { value: v, label: this.labelFor(key, v) };
      out.push(opt);
    }
    return out;
  }

  private evOptions(): LumixSettingOption[] {
    const out: LumixSettingOption[] = [];
    for (let n = -15; n <= 15; n++) {
      const opt: LumixSettingOption = { value: evOptionValue(n), label: formatEv(n) };
      out.push(opt);
    }
    return out;
  }

  private currentPanelOptions(): LumixSettingOption[] {
    if (this.nikonMode) {
      return this.nikonPanelOptions();
    }
    if (this.syncMode) {
      return this.syncPanelOptions();
    }
    if (this.sonyMode) {
      return this.sonyPanelOptions();
    }
    switch (this.panel) {
      case 'ev': return this.evOptions();
      case 'lut': return this.optionsFor('photostyle');
      case 'quality': return this.optionsFor('quality');
      case 'aspect': return this.optionsFor('aspectratio');
      case 'mode': return this.optionsFor('recmode2');
      case 'wb': return this.optionsFor('whitebalance');
      case 'iso': return this.optionsFor('iso');
      case 'shutter': return this.optionsFor('shtrspeed');
      default: return [];
    }
  }

  /** WB 选项图标（Lumix Lab APK 官方 remote_shooting_whitebalance_* 图标
   *  xxhdpi，2026-09-29 提取）。Lab 线 hex 值与 Sync 线名称共用一套资源；
   *  未知值返回 undefined 只显示文字。 */
  private wbIconOf(value: string): Resource | undefined {
    const n = parseHexValue(value);
    if (!Number.isNaN(n)) {
      switch (n) {
        case 0x0002: return $r('app.media.wb_auto');
        case 0x8014: return $r('app.media.wb_auto_cool');
        case 0x8015: return $r('app.media.wb_auto_warm');
        case 0x0004: return $r('app.media.wb_daylight');
        case 0x8008: return $r('app.media.wb_cloudy');
        case 0x800f: return $r('app.media.wb_shade');
        case 0x0006: return $r('app.media.wb_halogen');
        case 0x0007: return $r('app.media.wb_flash');
        case 0x800b: return $r('app.media.wb_white_set1');
        case 0x800c: return $r('app.media.wb_white_set2');
        case 0x800d: return $r('app.media.wb_white_set3');
        case 0x800e: return $r('app.media.wb_white_set4');
        case 0x8010: return $r('app.media.wb_color_temp1');
        case 0x8011: return $r('app.media.wb_color_temp2');
        case 0x8012: return $r('app.media.wb_color_temp3');
        case 0x8013: return $r('app.media.wb_color_temp4');
        default: return undefined;
      }
    }
    switch (value) {
      case 'auto': return $r('app.media.wb_auto');
      case 'auto_cool': return $r('app.media.wb_auto_cool');
      case 'auto_warm': return $r('app.media.wb_auto_warm');
      case 'daylight': return $r('app.media.wb_daylight');
      case 'cloudy': return $r('app.media.wb_cloudy');
      case 'shade': return $r('app.media.wb_shade');
      case 'halogen': return $r('app.media.wb_halogen');
      case 'flash': return $r('app.media.wb_flash');
      case 'white_set1': return $r('app.media.wb_white_set1');
      case 'white_set2': return $r('app.media.wb_white_set2');
      case 'white_set3': return $r('app.media.wb_white_set3');
      case 'white_set4': return $r('app.media.wb_white_set4');
      case 'color_temp': return $r('app.media.wb_color_temp1');
      case 'color_temp1': return $r('app.media.wb_color_temp1');
      case 'color_temp2': return $r('app.media.wb_color_temp2');
      case 'color_temp3': return $r('app.media.wb_color_temp3');
      case 'color_temp4': return $r('app.media.wb_color_temp4');
      default: return undefined;
    }
  }

  /**
   * 尼康白平衡码 → 图标。
   *
   * 复用本项目已有的那套 `wb_*` 位图（松下 / Sync 线在用，语义一一对得上），没有
   * 新增任何素材。尼康的码来自相机描述符（Z 5 与 Z 8 实测是同一套）：
   *
   *   2 自动 / 4 晴天 / 5 荧光灯 / 6 白炽灯 / 7 闪光灯 /
   *   0x8010 阴天 / 0x8011 晴天阴影 / 0x8012 色温 / 0x8013 预设手动 / 0x8016 自然光自动
   *
   * 现有素材没有"荧光灯"这一枚，用 `wb_auto_cool`（冷色调）最接近；"自然光自动"用
   * `wb_auto`。返回 undefined 表示没有对应图标，调用方退回显示文字，不会留空网格。
   */
  private nikonWbIconOf(value: string): Resource | undefined {
    const n = Number(value);
    if (Number.isNaN(n)) {
      return undefined;
    }
    switch (n) {
      case 0x0002: return $r('app.media.wb_auto');
      case 0x0004: return $r('app.media.wb_daylight');
      case 0x0005: return $r('app.media.wb_auto_cool');
      case 0x0006: return $r('app.media.wb_halogen');
      case 0x0007: return $r('app.media.wb_flash');
      case 0x8010: return $r('app.media.wb_cloudy');
      case 0x8011: return $r('app.media.wb_shade');
      case 0x8012: return $r('app.media.wb_color_temp1');
      case 0x8013: return $r('app.media.wb_white_set1');
      case 0x8016: return $r('app.media.wb_auto');
      default: return undefined;
    }
  }

  /** 芯片行该用哪张白平衡图标。undefined = 显示文字。
   *  尼康走 `nikonWbIconOf`，索尼没有图标，其余（松下 / Sync）沿用 `wbIconOf`。 */
  private wbIconFor(value: string): Resource | undefined {
    if (this.nikonMode) {
      return this.nikonWbIconOf(value);
    }
    if (this.sonyMode) {
      return undefined;
    }
    return this.wbIconOf(value);
  }
  /** Sync strip highlight: compare the option against the last known value. */
  private syncCurrentOf(value: string): boolean {
    switch (this.panel) {
      case 'mode': return value === this.syncModeRaw;
      case 'lut': return value === this.syncPhotoStyleRaw;
      case 'quality': return value === this.syncQualityRaw;
      case 'aspect': return value === this.syncAspectRaw;
      case 'metering': return value === this.syncMeteringRaw;
      case 'iso': return value === this.syncStateRaw.iso;
      case 'shutter': {
        // 相机 256 量化与显示档（1/250→1/256）差异：按秒值相对容差比较
        const current = this.shutterSeconds(this.syncStateRaw.shtrspeed);
        const expected = this.shutterSeconds(value);
        if (current <= 0 || expected <= 0) {
          return false;
        }
        const rel = Math.abs(current - expected) / Math.max(current, expected);
        return rel <= 0.15 || Math.abs(current - expected) <= 0.002;
      }
      case 'aperture': {
        // N/256 有理数：相机内部量化（如 F5.6 → 1434 vs 相机存 1433），
        // 按 256 分母的分子比较并给 ±2 容差
        const current = this.focalNumerator(this.syncStateRaw.focal);
        const expected = this.focalNumerator(value);
        if (current <= 0 || expected <= 0) {
          return false;
        }
        return Math.abs(current - expected) <= 2;
      }
      case 'ev': return value === this.syncStateRaw.exposure;
      case 'wb': return value === this.syncStateRaw.whitebalance;
      default: return false;
    }
  }

  /**
   * Sync-line drum value lists (mode=setsetting value domains). 相机
   * curmenu 的 option 属性是官方拨轮的取值域（含 EV 官方值格式），优
   * 使用；解析不到时退回本地 Panasonic 风格列表兜底
   */
  private syncPanelOptions(): LumixSettingOption[] {
    // 拍摄模式：curmenu 的 recmode 子项即取值域（2026-09-28 实测）
    if (this.panel === 'mode') {
      return this.syncModeOptions();
    }
    // 格调/画质：curmenu 子项即取值域（menu_item_id_ph_sty_* /
    // menu_item_id_quality_*），只保留相机端 enable 的档位
    if (this.panel === 'lut' || this.panel === 'quality') {
      const prefix = this.panel === 'lut' ? 'menu_item_id_ph_sty_' : 'menu_item_id_quality_';
      const menu = this.syncMenuChildrenOptions(prefix);
      if (menu.length > 0) {
        return menu;
      }
    }
    const type = this.syncSettingTypeOf(this.panel);
    if (type.length > 0) {
      const menu = this.syncMenuOptionsFor(type);
      if (menu.length > 0) {
        return menu;
      }
    }
    const out: LumixSettingOption[] = [];
    const push = (v: string, label: string): void => {
      const opt: LumixSettingOption = { value: v, label: label };
      out.push(opt);
    };
    switch (this.panel) {
      case 'iso': {
        push('auto', '自动');
        const iso: string[] = ['80', '100', '125', '160', '200', '250', '320', '400', '500', '640',
          '800', '1000', '1250', '1600', '2000', '2500', '3200', '4000', '5000', '6400',
          '8000', '10000', '12800', '16000', '20000', '25600', '32000', '40000', '51200'];
        for (const v of iso) {
          push(v, v);
        }
        break;
      }
      case 'shutter': {
        push('auto', '自动');
        // 相机端快门规范 = N/256 秒（getsetting shtrspeed="1/256" 实测）
        // 慢门裸数字（"4"）与小数（"1.3"）实测 err_param → 换算 N/256
        // （4" → 1024/256、1.3" → 333/256）
        const slow: string[] = ['60', '50', '40', '30', '25', '20', '15', '13', '10', '8',
          '6', '5', '4', '3.2', '2.5', '2', '1.6', '1.3', '1'];
        for (const v of slow) {
          push(`${Math.round(parseFloat(v) * 256)}/256`, `${v}"`);
        }
        // 快门保留 1/N 显示式（相机接受并自行量化，如 1/250 → 1/256）
        const fast: string[] = ['1/2', '1/4', '1/5', '1/6',
          '1/8', '1/10', '1/13', '1/15', '1/20', '1/25', '1/30', '1/40', '1/50', '1/60',
          '1/80', '1/100', '1/125', '1/160', '1/200', '1/250', '1/320', '1/400', '1/500',
          '1/640', '1/800', '1/1000', '1/1250', '1/1600', '1/2000', '1/2500', '1/3200',
          '1/4000', '1/5000', '1/6400', '1/8000'];
        for (const v of fast) {
          push(v, v);
        }
        break;
      }
      case 'aperture': {
        // 相机端光圈 = AV×256（AV = 2·log2(F)，2026-09-28 实测：误
        // F×256 发送时 F7.1→1818/256 被相机读成 AV7.1 → 实际 F11）
        const focal: string[] = ['3.5', '4', '4.5', '5', '5.6', '6.3', '7.1', '8', '9', '10',
          '11', '13', '14', '16', '18', '20', '22'];
        for (const v of focal) {
          push(`${Math.round(2 * Math.log2(parseFloat(v)) * 256)}/256`, `F${v}`);
        }
        break;
      }
      case 'ev': {
        push('0', '0EV');
        // 相机端取值域（curmenu menu_item_id_exposure_*，2026-09-28 实测
        // 717 项重组）：-5~+5EV 的 1/3 档，假分数表示——m14_3 = -14/3
        // （-4⅔）、p10_3 = +10/3；无 '+'、无前导零、无带分数。旧列表
        // -02/3（前导零）、+3（加号）、-22/3（带分数）全部 err_param
        for (let thirds = 1; thirds <= 15; thirds++) {
          const whole = Math.floor(thirds / 3);
          const rem = thirds % 3;
          const fraction = rem === 1 ? '⅓' : (rem === 2 ? '⅔' : '');
          const abs = thirds % 3 === 0 ? `${whole}` : `${thirds}/3`;
          push(`-${abs}`, `-${whole}${fraction}EV`);
          push(abs, `+${whole}${fraction}EV`);
        }
        break;
      }
      case 'wb': {
        // 相机端取值域（curmenu menu_item_id_whitebalance_*，2026-09-28
        // 实测）：白炽灯是 halogen、色温是 color_temp——旧列表
        // incandescent/kelvin 在相机上不存在（kelvin 实测 err_param）
        const wb: string[][] = [['auto', '自动'], ['auto_cool', '自动·冷'], ['auto_warm', '自动·暖'],
          ['daylight', '日光'], ['cloudy', '阴天'], ['shade', '阴影'], ['halogen', '白炽灯'],
          ['flash', '闪光'], ['white_set1', '白平衡1'], ['white_set2', '白平衡2'],
          ['white_set3', '白平衡3'], ['white_set4', '白平衡4'],
          ['color_temp', '色温'], ['color_temp1', '色温1'], ['color_temp2', '色温2'],
          ['color_temp3', '色温3'], ['color_temp4', '色温4']];
        for (const pair of wb) {
          push(pair[0], pair[1]);
        }
        break;
      }
      case 'lut': {
        const styles: string[][] = [['standard', '标准'], ['vivid', '鲜艳'], ['natural', '自然'],
          ['bw', '单色'], ['l_bw', 'L.单色'], ['l_bw_d', 'L.单色D'], ['l_bw_s', 'L.单色S'],
          ['scenery', '风景'], ['portrait', '人像'], ['flat', '扁平'],
          ['cinelike_d', 'CineLike D'], ['cinelike_d2', 'CineLike D2'],
          ['cinelike_v', 'CineLike V'], ['cinelike_v2', 'CineLike V2'],
          ['vlog', 'V-Log'], ['vlog_l', 'V-Log L'], ['hlg', 'HLG'], ['709like', '709like']];
        for (const pair of styles) {
          push(pair[0], pair[1]);
        }
        break;
      }
      case 'quality': {
        const qualities: string[][] = [['fine', 'JPG 精细'], ['standard', 'JPG 标准'],
          ['raw_fine', 'RAW+JPG 精细'], ['raw_standard', 'RAW+JPG 标准'], ['raw', 'RAW']];
        for (const pair of qualities) {
          push(pair[0], pair[1]);
        }
        break;
      }
      case 'aspect': {
        // 相机端比例为 "3:2" 冒号格式（getsetting aspectratio="3:2"
        // 2026-09-28 实测）
        const aspects: string[] = ['3:2', '16:9', '1:1', '4:3', '2:3', '3:4', '4:5', '5:6', '65:24', '2:1'];
        for (const v of aspects) {
          push(v, v);
        }
        break;
      }
      case 'metering': {
        const meterings = this.syncMeteringOptions();
        for (const opt of meterings) {
          push(opt.value, opt.label);
        }
        break;
      }
      default:
        break;
    }
    return out;
  }

  /** 拍摄模式取值域：curmenu 的 recmode 子项（program_ae / aperture_ae /
   *  shutter_ae / manual_exposure / ia / creative_movie / c1…，2026-09-28
   *  实测 menu_item_id_recmode value="aperture_ae" = 当前 A 档）。 */
  private syncModeOptions(): LumixSettingOption[] {
    const out: LumixSettingOption[] = [];
    const prefix = 'menu_item_id_recmode_';
    for (const item of this.syncMenuItems) {
      if (item.id.length > prefix.length && item.id.startsWith(prefix)) {
        const value = item.id.substring(prefix.length);
        const opt: LumixSettingOption = { value: value, label: this.syncModeLabel(value) };
        out.push(opt);
      }
    }
    return out;
  }

  private syncModeLabel(value: string): string {
    switch (value) {
      case 'program_ae': return 'P';
      case 'aperture_ae': return 'A';
      case 'shutter_ae': return 'S';
      case 'manual_exposure': return 'M';
      case 'ia': return 'iA';
      case 'creative_movie': return '创意视频';
      case 'creative_ctrl': return '创意控制';
      case 'scene_guide': return '场景指南';
      case 'panorama': return '全景';
      default:
        if (value.length >= 2 && value[0].toUpperCase() === 'C' && value.length <= 3) {
          return value.toUpperCase();
        }
        return value;
    }
  }

  /** curmenu 子项取值域（按 id 前缀收集，如 menu_item_id_ph_sty_*）；
   *  只保留相机端 enable 的档位。 */
  private syncMenuChildrenOptions(prefix: string): LumixSettingOption[] {
    const out: LumixSettingOption[] = [];
    for (const item of this.syncMenuItems) {
      if (item.id.length <= prefix.length || !item.id.startsWith(prefix)) {
        continue;
      }
      if (item.enable === 'no') {
        continue;
      }
      const value = item.id.substring(prefix.length);
      const opt: LumixSettingOption = { value: value, label: this.syncChipOptionLabel(value) };
      out.push(opt);
    }
    return out;
  }

  /** 测光模式取值域（getsetting lightmetering="multi" 实测校准）。多
   *  测光（multi）在 Sync 线下发无效（用户实测），从下拉中移除。 */
  private syncMeteringOptions(): LumixSettingOption[] {
    const out: LumixSettingOption[] = [];
    const meterings: string[][] = [['center', '中央'], ['spot', '点测光'],
      ['highlight', '高光']];
    for (const pair of meterings) {
      const opt: LumixSettingOption = { value: pair[0], label: pair[1] };
      out.push(opt);
    }
    return out;
  }

  /** 格调/画质/比例/测光的取值标签。 */
  private syncChipOptionLabel(value: string): string {
    if (this.panel === 'lut') {
      return this.syncPhotoStyleLabel(value);
    }
    if (this.panel === 'quality') {
      return this.syncQualityLabel(value);
    }
    if (this.panel === 'aspect') {
      return this.syncAspectLabel(value);
    }
    return this.syncMeteringLabel(value);
  }

  private syncPhotoStyleLabel(value: string): string {
    switch (value) {
      case 'standard': return '标准';
      case 'vivid': return '鲜艳';
      case 'natural': return '自然';
      case 'bw': return '单色';
      case 'l_bw': return 'L.单色';
      case 'l_bw_d': return 'L.单色D';
      case 'l_bw_s': return 'L.单色S';
      case 'scenery': return '风景';
      case 'portrait': return '人像';
      case 'flat': return '扁平';
      case 'cinelike_d': return 'CineLike D';
      case 'cinelike_d2': return 'CineLike D2';
      case 'cinelike_v': return 'CineLike V';
      case 'cinelike_v2': return 'CineLike V2';
      case 'vlog': return 'V-Log';
      case 'vlog_l': return 'V-Log L';
      case 'hlg': return 'HLG';
      case 'hlg_bw': return 'HLG 单色';
      case 'hlg_standard': return 'HLG 标准';
      case '709like': return '709like';
      case 'l_cla_neo': return 'L.经典新';
      case 'custom': return '自定义';
      default:
        if (value.startsWith('custom') && value.length > 'custom'.length) {
          return `自定义 ${value.substring('custom'.length)}`;
        }
        return value;
    }
  }

  private syncQualityLabel(value: string): string {
    switch (value) {
      case 'fine': return 'JPG 精细';
      case 'standard': return 'JPG 标准';
      case 'raw_fine': return 'RAW+JPG 精细';
      case 'raw_standard': return 'RAW+JPG 标准';
      case 'raw': return 'RAW';
      case 'mpo_fine': return 'MPO 精细';
      case 'mpo_standard': return 'MPO 标准';
      default: return value;
    }
  }

  private syncAspectLabel(value: string): string {
    return value.indexOf('/') > 0 ? value.replace('/', ':') : value;
  }

  private syncMeteringLabel(value: string): string {
    switch (value) {
      case 'multi':
      case 'multiple': return '多点';
      case 'center': return '中央';
      case 'center_weighted': return '中央重点';
      case 'spot': return '点测光';
      case 'highlight': return '高光';
      default: return value;
    }
  }

  /** 从 curmenu 快照里取某设置项的取值域（option 属性，%XX 编码、逗号分隔）。 */
  private syncMenuOptionsFor(type: string): LumixSettingOption[] {
    const out: LumixSettingOption[] = [];
    for (const item of this.syncMenuItems) {
      if (item.id !== type || item.option.length === 0) {
        continue;
      }
      for (const piece of item.option.split(',')) {
        const value = this.percentDecode(piece.trim());
        if (value.length > 0) {
          const opt: LumixSettingOption = { value: value, label: value };
          out.push(opt);
        }
      }
      if (out.length > 0) {
        return out;
      }
    }
    return out;
  }

  /** %XX 解码（curmenu option 官方转义表 a2/q.java）。'+' 不转空格
   *  正 EV 值本身可能以 '+' 开头。 */
  private percentDecode(value: string): string {
    return value.replace(/%([0-9A-Fa-f]{2})/g, (_match: string, hex: string): string => {
      const code = parseInt(hex, 16);
      return String.fromCharCode(code);
    });
  }

  private isCurrentOption(opt: LumixSettingOption): boolean {
    if (this.nikonMode) {
      // 尼康线上 opt.value 就是属性值本身（十进制字符串），当前值来自相机回的
      // 描述符 `CurrentValue`。下面那套松下定点编码（evThirdsOf /
      // shutterNumerator / apertureIndexOf）对尼康无意义。
      const state = this.nikonPropOf(this.nikonPropCodeOfPanel(this.panel));
      if (state === null) return false;
      const raw = Number(opt.value);
      return !Number.isNaN(raw) && raw === state.value;
    }
    if (this.syncMode) {
      return this.syncCurrentOf(opt.value);
    }
    if (this.sonyMode) {
      // 索尼线上 opt.value 就是相机的原始值（十进制字符串），直接按原值比较。
      // 走不到下面那套松下编码（evThirdsOf / shutterNumerator / apertureIndexOf），
      // 那些是松下 C2818b 的定点表示，对索尼无意义。
      const raw = Number.parseInt(opt.value, 10);
      return !Number.isNaN(raw) && raw === this.sonyRawOf(this.panel);
    }
    const n = parseHexValue(opt.value);
    switch (this.panel) {
      case 'lut':
        if (this.info.photoStyleValue >= 0) {
          return n === this.info.photoStyleValue;
        }
        return this.labPhotoStyleRaw.length > 0 && n === parseHexValue(this.labPhotoStyleRaw);
      case 'quality':
        if (this.qualityKey === 'pictureformat' && this.info.pictureFormatValue >= 0) {
          return n === this.info.pictureFormatValue;
        }
        return n === this.info.qualityValue;
      case 'aspect': return n === this.info.aspectValue;
      case 'mode': return n === this.info.modeValue;
      case 'wb': return n === this.info.wbValue;
      case 'iso': return n === this.info.isoValue;
      case 'ev': return evThirdsOf(n) === this.info.evThirds;
      case 'shutter': return shutterNumerator(opt.value) === this.info.tvCur256;
      default: return false;
    }
  }

  /**
   * 该参数面板在当前机型线上是否有数据来源。松下两条线恒为可用（与引入
   * 索尼线之前完全一致）；索尼线上没有读取通道的面板返回 false，UI 侧按
   * 「可见但不可用」渲染（灰显 + enabled(false) + 值显示「不可用」）
   * 既不隐藏也不会在点击时走到任何协议调用
   */
  private controlPanelEnabled(panel: string): boolean {
    // 尼康线不走静态机型表：**支持性是相机自己回答的**。
    //
    // 每个参数发一次 PTP `0x1014 GetDevicePropDesc`（见 NikonCameraParameters）：
    // 回了合法描述符就是支持，描述符里的 `GetSet` 还告诉我们能不能写。官方
    // `GetFnumberAction.isSupportAction` 用的正是这条路径（先判断操作码再判断属性码），
    // 所以不同机身支持的参数集不同时，不需要维护机型清单。
    //
    // **这里故意不按 `GetSet` 置灰。**
    //
    // 曾经想过"相机说只读就把面板置灰"，但那样有真实风险：真机探测到 `0x5007` 在
    // 开流后会变成 `get-set=0 enum=1`，如果相机在取景状态下把所有属性都这么报，
    // 整个参数面板会全线置灰——**用户反而什么都改不了**，比现在更糟。
    //
    // 所以判断留在**写的那一刻**（`nikonSetParameter` 会先重读一次描述符），
    // 面板保持可用：相机允许就写成功，不允许就明确告诉用户"相机自述为只读"。
    if (this.nikonMode) {
      const code = this.nikonPropCodeOfPanel(panel);
      if (code === 0) return false;
      return this.nikonPropOf(code) !== null;
    }
    return CameraControlBrand.supportsPanel(this.protocol, panel);
  }

  /** 参数面板 → 尼康属性码。返回 0 表示这个面板在尼康线上没有对应属性。
   *
   *  **录像模式走另一组属性码。** 视频的快门/光圈/ISO/EV/白平衡在机身里是独立的
   *  属性（`0xD1A8`/`0xD1A9`/`0xD1AA`/`0xD1AB`/`0xD23A`，见
   *  `NikonCameraParameters.MOVIE_*`），和拍照那组不是同一个码。以前不区分模式，
   *  所以在录像模式下读到的、写进去的都是**照片**参数，录像本身一点没变。 */
  private nikonPropCodeOfPanel(panel: string): number {
    let still = 0;
    switch (panel) {
      case 'mode': still = NikonProp.PROGRAM_MODE; break;
      case 'aperture': still = NikonProp.FNUMBER; break;
      case 'shutter': still = NikonProp.SHUTTER_SPEED; break;
      case 'iso': still = NikonProp.ISO; break;
      case 'ev': still = NikonProp.EXPOSURE_COMPENSATION; break;
      case 'wb': still = NikonProp.WHITE_BALANCE; break;
      default: return 0;
    }
    if (this.movieMode) {
      const movie = NikonCameraParameters.movieCodeOf(still);
      if (movie !== 0) return movie;
    }
    return still;
  }

  /** 取已探测到的属性状态；没探到（或相机不支持）返回 null。 */
  private nikonPropOf(code: number): NikonPropertyState | null {
    for (const state of this.nikonProps) {
      if (state.propertyCode === code) return state;
    }
    return null;
  }

  /**
   * 把一个尼康属性的当前值渲染成界面文案。
   *
   * 编码来自属性自身的语义（与尼康机身菜单一致）：光圈是 **APEX×100**
   * （F2.8 → 280）、曝光补偿是 **1/6 EV 步**、ISO 是裸数值。这些不是猜的——
   * 官方 `SetFnumberAction` 用的就是 16 位数据集，`SetExposureCompensationAction`
   * 同理。
   */
  private nikonPropLabel(state: NikonPropertyState): string {
    return this.nikonValueLabel(state.propertyCode, state.value);
  }

  /** 把一个**任意**属性值渲染成文案（选项列表也要用，不只是当前值）。 */
  private nikonValueLabel(propertyCode: number, value: number): string {
    // 录像属性只有"码"和拍照不同，**编码完全一样**（F×100、快门高16位分子/
    // 低16位分母、EV 同刻度、白平衡同枚举）。所以先换成对应的拍照码再走下面那套
    // 解码，文案与选项列表就自动一致了，不用维护第二份表。
    const stillCode = NikonCameraParameters.stillCodeOf(propertyCode);
    if (stillCode !== 0) {
      return this.nikonValueLabel(stillCode, value);
    }
    switch (propertyCode) {
      case NikonProp.PROGRAM_MODE: {
        // 官方 `GetProgramModeAction` 把 `0x500E` 的原始值交给
        // `snapbridge.ptpclient.y9.a(S)` 解码，那张表就是真值表——**不是 PTP
        // 规范表**，两者不一样：
        //
        //   y9.a(S):  0x8010 → AUTO，1 → M，2 → P，3 → A，4 → S
        //   规范(0x500E):  1=Manual 2=Automatic 3=Aperture 4=Shutter
        //
        // 我们原来按规范写成 1→M、2→A、3→S、4→P，于是 P/A/S 整条错位一格：
        // 机身 A 档（原始值 3）显示成 S、S 档（4）显示成 P、P 档（2）显示成 A，
        // 只有 M 对得上——和真机反馈完全一致（"手机的 A 实际是机身的 P，除了 M
        // 全错"）。以官方这张表为准。
        switch (value) {
          case 1: return 'M';
          case 2: return 'P';
          case 3: return 'A';
          case 4: return 'S';
          case 0x8010: return 'AUTO';
          default: return `${value}`;
        }
      }
      case NikonProp.FNUMBER: {
        // 相机端是 **F 值 × 100**：官方 `FNumber$FNumber` 枚举写死了
        // FNUMBER_1_0=100、FNUMBER_2_8=280、FNUMBER_64=6400，并有 FNUMBER_0_95=95。
        // 所以 ×100 是实测口径，不是估计。F0.95 需要两位小数，否则会被显示成 F0.9。
        const f = value / 100;
        if (f <= 0) return `${value}`;
        return f < 1 ? `F${f.toFixed(2)}` : `F${f.toFixed(1)}`;
      }
      case NikonProp.SHUTTER_SPEED: {
        // 尼康快门 `0xD100` 是一个 u32：**高 16 位 = 分子，低 16 位 = 分母**。
        //
        // 这是官方代码里的硬证据，不是我反推的：
        //   `ptpclient/actions/devices/models/ShutterSpeed` 持有 (numerator,
        //   denominator) 两个 int，并且
        //     isBulb()      → a == 0xFFFF && b == 0xFFFF
        //     isSyncFlush() → a == 0xFFFF && b == 0xFFFE
        //   也就是说 0xFFFFFFFF 是 B 门、0xFFFFFFFE 是 X 同步——只有当高低 16 位
        //   分别就是分子和分母时，这两个判断才说得通。
        //
        // 之前这里只认 `0x0001xxxx`（= 分子 1，正确显示为 1/xxx），其余一律按十进制
        // 原样打印，于是下拉里出现了 4294967295、1310721 这类"异常大的数"——它们
        // 其实都是合法档位：0xFFFFFFFF 是 B 门，0x00140001 是 20 秒（20/1）。
        const numerator = (value >>> 16) & 0xFFFF;
        const denominator = value & 0xFFFF;
        if (numerator === 0xFFFF) {
          if (denominator === 0xFFFF) return 'B 门';
          if (denominator === 0xFFFE) return 'X 同步';
          // 0xFFFF 段里的其它取值官方没有给出名字，如实按分子/分母显示，不编造。
          return `${numerator}/${denominator}`;
        }
        if (denominator === 1) return `${numerator} 秒`;
        if (numerator === 1) return `1/${denominator}`;
        return `${numerator}/${denominator}`;
      }
      case NikonProp.WHITE_BALANCE:
        return NikonCameraParameters.whiteBalanceLabel(value);
      case NikonProp.EXPOSURE_COMPENSATION: {
        // 单位是 **1/1000 EV**，来自相机自己报的枚举：
        //   values=-5000,-4666,-4333,...,-333,0,333,...,4333,4666,5000
        // 31 个值、每档 1/3 EV、两端 ±5 EV —— 所以 -5000/1000 = -5.0 EV。
        // （早先写的 /6 是凭空猜的，会让 ±5 EV 显示成 ±833，已废弃。）
        const ev = value / 1000;
        return ev === 0 ? '±0' : `${ev > 0 ? '+' : ''}${ev.toFixed(1)}`;
      }
      default:
        return `${value}`;
    }
  }

  /**
   * 探测尼康参数并把结果落到状态里。
   *
   * 必须在 PTP/IP 控制会话就绪之后调用（描述符走控制通道）。一次探测发十条
   * `0x1015`，**串行**——PTP 的事务号是串行的，并发会搅乱配对。
   */
  private async nikonRefreshParams(): Promise<void> {
    if (!this.nikonMode || this.nikonParamRefreshing) return;
    if (!NikonPtpIpService.isControlReady()) {
      // 这条以前是静默返回，于是"参数不可用"完全看不出是没会话还是相机拒绝。
      this.nikonParamStatus = '参数不可用：PTP/IP 控制会话未就绪';
      NikonPtpIpService.log('nikon-control params skipped; control session not ready');
      return;
    }
    this.nikonParamRefreshing = true;
    this.nikonParamStatus = '正在读取相机参数…';
    try {
      const states = await NikonCameraParameters.probe(NikonCameraParameters.controlPropertyCodes());
      this.nikonProps = states;
      // **把结论摆到界面上。** 参数面板拿不到值时，用户需要一眼看出是"相机不支持"
      // 还是"探测根本没跑"，而不是只能看到一排「不可用」。
      //
      // 这里的措辞刻意不去猜原因：上一版写成"相机拒绝了全部属性查询"，结果真机
      // 日志显示相机全部回了 OK，是**我们自己**把两个操作码对调了——错怪了相机。
      // 具体到每一条为什么失败，看 hilog 里的 `ptpip prop ...` 行。
      this.nikonParamStatus = states.length > 0
        ? `相机参数：${states.length} 项可用`
        : '参数不可用：未取到任何属性描述符（详见 hilog「ptpip prop」）';
      NikonPtpIpService.log(`nikon-control params supported=${states.length}`);
    } catch (error) {
      this.nikonParamStatus = `参数读取失败：${String(error)}`;
      NikonPtpIpService.logError('nikon-control params', error as Object);
    } finally {
      this.nikonParamRefreshing = false;
    }
  }

  /**
   * 尼康参数的可选值列表。
   *
   * 两种来源，**都由相机在描述符里给出**，没有本地常量表：
   *
   * - `FormFlag = Enumeration`：直接用相机给的枚举项（ISO、白平衡、模式走这条）；
   * - `FormFlag = Range`：按 `min/step/max` 展开。只在档位不多时展开（比如曝光
   *   补偿 ±5EV / 1-6EV 步 = 61 档），档位过多就不展开，避免生成一个几百项的
   *   列表把面板撑爆。
   *
   * `value` 传的是**属性值本身**（不是显示文案），所以写回时不需要反查表。
   */
  private nikonPanelOptions(): LumixSettingOption[] {
    const code = this.nikonPropCodeOfPanel(this.panel);
    if (code === 0) return [];
    const state = this.nikonPropOf(code);
    if (state === null) return [];
    const options: LumixSettingOption[] = [];
    if (state.formFlag === PTP_FORM_ENUM) {
      for (const item of state.enumValues) {
        // 档位列表**只列真能拨的档**。Z 5 的 `0x500E` 枚举是
        // `1,2,3,4,0x8010,0x8050,0x8051,0x8052`，后三个在官方 `ProgramMode`
        // 枚举里没有对应项（`y9.a(S)` 全部映射成 UNKNOWN），以前原样列出，界面
        // 上就冒出 `32848/32849/32850` 三个无效数值。
        if (code === NikonProp.PROGRAM_MODE && !NikonCameraParameters.isSettableMode(item)) {
          continue;
        }
        options.push({ label: this.nikonValueLabel(code, item), value: `${item}` });
      }
      return options;
    }
    if (state.formFlag === PTP_FORM_RANGE) {
      const step = state.step > 0 ? state.step : 1;
      const count = Math.floor((state.maximum - state.minimum) / step) + 1;
      if (count > 0 && count <= 80) {
        for (let value = state.minimum; value <= state.maximum; value += step) {
          options.push({ label: this.nikonValueLabel(code, value), value: `${value}` });
        }
      }
      return options;
    }
    return options;
  }

  /**
   * 改一个尼康参数 —— **直接写，不停取景流**。
   *
   * 这一版去掉了之前"停流 → 写 → 复流"的做法，依据是官方代码：把整个 SnapBridge
   * 的 smali 扫一遍，**没有任何一个类同时引用属性写操作（0x1016）和取景开关
   * （0x9201/0x9202）**——也就是说官方在取景流开着的时候直接写属性，不会为一次
   * 参数调整去停流。
   *
   * 之前那套停流写法的代价在真机日志里很清楚：写 `0x5007` 被回 **`0x201F`
   * TRANSACTION_CANCELLED`**（官方 `ResponseCodes` 里的名字），EV 那次干脆超时把
   * 会话毒化。`TRANSACTION_CANCELLED` 正是"事务被打断"的含义——自己把流停掉再发
   * 命令，反而制造了冲突。
   *
   * 写成功就直接更新本地值，不回读：相机确认过写入，回读只会多一次往返。
   */
  private async nikonSetParameter(panel: string, value: number): Promise<void> {
    const code = this.nikonPropCodeOfPanel(panel);
    if (code === 0) return;
    const state = this.nikonPropOf(code);
    if (state === null) return;
    // **写之前先问相机一次：这个属性"现在"可写吗。**
    //
    // 依据是真机探测到的状态依赖：同一台 Z 8，同一个 `0x5007`，
    //   开流前 → get-set=1  range=400..2200  enum=16   （16 档光圈，可写）
    //   开流后 → get-set=0  range=400..400   enum=1    （只读，且只有一个合法值）
    // 相机**自己**会改口说"不可写"，而我们面板上的状态是进页面时探测的那一次，
    // 早就过期了。于是一个相机自述只读的属性，我们照样发 `0x1016` 过去，相机读完
    // 数据再回 `0x201F`（TRANSACTION_CANCELLED）——日志里四次写入全是这个形状。
    //
    // 描述符读取走会话队列（与取景共用），在流开着的时候读是安全的：取景本身每
    // 130 ms 就在读同一通道。所以这一步开销很小，却能消掉一整类注定失败的写入，
    // 而且给出的理由是**相机自己说的**，不是我们猜的。
    let target = state;
    try {
      const fresh = await NikonCameraParameters.describe(code);
      if (fresh !== null) {
        target = fresh;
        // 把新描述符合进 @State，界面上的可写状态随之更新。
        const merged: NikonPropertyState[] = this.nikonProps.slice();
        for (let index = 0; index < merged.length; index++) {
          if (merged[index].propertyCode === code) {
            merged[index] = fresh;
            break;
          }
        }
        this.nikonProps = merged;
      }
    } catch (error) {
      NikonPtpIpService.log(`nikon-control pre-write describe threw: ${String(error)}`);
    }
    if (!target.writable) {
      // 档位 `0x500E` 是例外：Z 5 描述符报只读，但官方 App 照写且相机回
      // `0x2001`（见 NikonCameraParameters.isWritableDespiteReadOnly）。这里
      // 必须用同一个白名单，否则前面的 write() 放行了、这道门又把它拦回去，
      // 表现就是"点档位没反应"。
      if (!NikonCameraParameters.isWritableDespiteReadOnly(code)) {
        this.toast('相机当前状态不允许调整该参数（相机自述为只读）');
        return;
      }
    }
    // 值不在相机此刻给出的合法集合里，也不发——发了同样会被取消。
    if (target.formFlag === PTP_FORM_ENUM && target.enumValues.length > 0
      && target.enumValues.indexOf(value) < 0) {
      NikonPtpIpService.log(`nikon-control value ${value} not in the current enum for`
        + ` ${code} (${target.enumValues.length} values); write skipped`);
      this.toast('相机当前状态下没有这个取值，已跳过');
      return;
    }
    // **取景流保持不断，直接写。**
    //
    // 这里原来在写之前发 `0x9202` 停流、写完再 `0x9201` 复流，依据是"相机在取景
    // 状态下会把属性标成不可写"。2026-10-18 用插桩过的官方 SnapBridge 2.13.3 + Z 8
    // 抓包推翻了这个假设：官方写快门 `0xD100`、光圈 `0x5007`、曝光补偿 `0x5010` 时，
    // 前后全是连续的取景帧，**既没有 `0x9202` 也没有 `0x9201`**，写完帧流一秒没断。
    //
    // 停流是我们自己加的动作，代价是用户每调一个参数画面黑一下——这正是"官方不断流、
    // 我们断流"的原因。真正让写入失败的是 `DataPhaseInfo` 和 `EndData` 的帧结构
    // （已在 NikonPtpIpService 里按官方字节改好），跟取景状态无关。
    let ok = false;
    try {
      ok = await NikonCameraParameters.write(target, value);
    } catch (error) {
      NikonPtpIpService.log(`nikon-control param write threw: ${String(error)}`);
    }
    if (ok) {
      target.value = value;
      const merged: NikonPropertyState[] = this.nikonProps.slice();
      for (let index = 0; index < merged.length; index++) {
        if (merged[index].propertyCode === code) {
          merged[index] = target;
          break;
        }
      }
      this.nikonProps = merged;
    }
    this.toast(ok ? '已设置' : '相机未接受该设置');
  }

  /** Chip value read inside the builder so @State mutations re-render it.
   *  Sync 线同样解析相机返回值（getsetting photostyle/quality/
   *  aspectratio/lightmetering）并实时显示。 */
  private chipValueOf(panel: string): string {
    if (!this.controlPanelEnabled(panel)) {
      return CameraControlBrand.UNAVAILABLE_VALUE;
    }
    if (this.sonyMode) {
      // 画质与比例在参数行里走的是 `chipValueOf` 而不是 `paramValueOf`（它们在
      // 松下线是「芯片行」的成员），而 `chipValueOf` 原来只有松下/Sync 两个分支
      // ——索尼线一路掉到最后一行 `this.info.meteringLabel`，那几个字段索尼从不
      // 写入，于是界面上恒为 '--'，尽管 `sony-control params` 日志里
      // `quality=HEIF(4:2:0) aspect=3:2` 早就有值。
      if (panel === 'quality') {
        return this.sonyQualityLabel.length > 0 ? this.sonyQualityLabel : '--';
      }
      if (panel === 'aspect') {
        return this.sonyAspectLabel.length > 0 ? this.sonyAspectLabel : '--';
      }
      return CameraControlBrand.UNAVAILABLE_VALUE;
    }
    if (this.syncMode) {
      if (panel === 'lut') {
        return this.syncPhotoStyleRaw.length > 0 ? this.syncPhotoStyleLabel(this.syncPhotoStyleRaw) : '--';
      }
      if (panel === 'quality') {
        return this.syncQualityRaw.length > 0 ? this.syncQualityLabel(this.syncQualityRaw) : '--';
      }
      if (panel === 'aspect') {
        return this.syncAspectRaw.length > 0 ? this.syncAspectLabel(this.syncAspectRaw) : '--';
      }
      return this.syncMeteringRaw.length > 0 ? this.syncMeteringLabel(this.syncMeteringRaw) : '--';
    }
    if (panel === 'lut') {
      // Q0 元数据含 photostyle（官方字段表 bs+18，2026-09-29）：优先取相
      // 实报值；首帧未到时退回 reflect 本地回显
      if (this.info.photoStyleValue >= 0) {
        return this.info.photoStyleLabel;
      }
      const n = parseHexValue(this.labPhotoStyleRaw);
      return this.labPhotoStyleRaw.length > 0 && !Number.isNaN(n) ? photoStyleLabelOf(n) : '--';
    }
    if (panel === 'quality') {
      if (this.qualityKey === 'pictureformat' && this.info.pictureFormatValue >= 0) {
        return this.info.pictureFormatLabel;
      }
      return this.info.qualityLabel;
    }
    if (panel === 'aspect') {
      return this.info.aspectLabel;
    }
    return this.info.meteringLabel;
  }

  /** Param row value read inside the builder so @State mutations re-render it. */
  private paramValueOf(panel: string): string {
    if (!this.controlPanelEnabled(panel)) {
      return CameraControlBrand.UNAVAILABLE_VALUE;
    }
    if (this.nikonMode) {
      // 尼康：值直接来自相机回的属性描述符（`CurrentValue`）。没有本地回显、
      // 也不借松下的 info 字段——那些字段归松下/Sync 线，共用会互相覆盖。
      const state = this.nikonPropOf(this.nikonPropCodeOfPanel(panel));
      if (state === null) {
        return CameraControlBrand.UNAVAILABLE_VALUE;
      }
      return this.nikonPropLabel(state);
    }
    if (this.sonyMode) {
      // 索尼线这四个由相机自己的 0x9209 记录填充，不借松下的 info 字段
      // （那些字段归松下/Sync 线，共用会互相覆盖）。光圈/快门/ISO/EV 仍走
      // info，见 sonyRefreshParams。
      if (panel === 'mode') {
        return this.sonyModeLabel.length > 0 ? this.sonyModeLabel : '--';
      }
      if (panel === 'wb') {
        return this.sonyWbLabel.length > 0 ? this.sonyWbLabel : '--';
      }
      if (panel === 'quality') {
        return this.sonyQualityLabel.length > 0 ? this.sonyQualityLabel : '--';
      }
      if (panel === 'aspect') {
        return this.sonyAspectLabel.length > 0 ? this.sonyAspectLabel : '--';
      }
    }
    switch (panel) {
      case 'mode':
        // Sync 线显示相机实际模式（menu_item_id_recmode value）；切换
        // setsetting recmode，相机端决定是否接受（机身拨盘可能拒绝）
        return this.syncMode
          ? (this.syncModeRaw.length > 0 ? this.syncModeLabel(this.syncModeRaw) : '读取中')
          : this.info.modeLabel;
      case 'ev': return this.info.evLabel;
      case 'shutter': return this.info.shutterLabel;
      case 'aperture': return this.info.apertureLabel;
      case 'iso': return this.info.isoLabel;
      case 'wb': return this.info.wbLabel;
      default: return '--';
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private errText(error: Object): string {
    if (error instanceof LumixControlError) {
      return error.message;
    }
    if (error instanceof Error) {
      return error.message;
    }
    return '未知错误';
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  build() {
    Stack() {
      if (this.previewMode) {
        // 预览：画面铺满全屏，顶上只叠一条与控制页同位置的迷你顶栏
        // （里面只有右上角的预览/控制切换）。
        Stack({ alignContent: Alignment.Top }) {
          this.previewLayer()
          Column() {
            this.previewTopBar()
          }
          .width('100%')
          .height('100%')
          .safeAreaPadding({ top: 24 })
          // 这层只让按钮吃触摸，其余位置放行给画面。
          .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%')
        .height('100%')
      } else if (this.isLandscapeLayout() && this.sonyMode) {
        // 只给索尼开：松下/尼康的横屏布局没有真机验过，保持原样（宁可维持现状也不
        // 引入未验证的视觉变化）。要三家都开，把 `&& this.sonyMode` 去掉即可。
        // 横屏：画面铺满整屏，控制条浮在上下两端（参考实现同构）。
        // 中间用 Blank 撑开，`hitTestBehavior(Transparent)` 让空白处的触摸
        // 落到画面上，触屏对焦照常可用。
        Stack() {
          // 包一层满高容器，让 `liveviewArea` 里的 layoutWeight(1) 生效。
          Column() {
            this.liveviewArea()
          }
          .width('100%')
          .height('100%')

          Column() {
            Column() {
              this.topBar()
              if (this.sonyMode || this.nikonMode) {
                this.ptpIdentityRow()
              }
              this.chipsRow()
            }
            .width('100%')

            Blank()

            Column() {
              if (this.sonyChipStripActive()) {
                this.chipStrip()
              }
              if (this.stripActive()) {
                this.paramStrip()
              }
              this.paramsRow()
              this.bottomBar()
            }
            .width('100%')
          }
          .width('100%')
          .height('100%')
          .safeAreaPadding({ top: 24 })
          .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%')
        .height('100%')
        if (this.overlayActive()) {
          this.panelOverlay()
        }
      } else {
        Column() {
          this.topBar()
          if (this.sonyMode || this.nikonMode) {
            this.ptpIdentityRow()
          }
          this.chipsRow()
          // 画质/比例的按钮在这一行，所以它们的子菜单必须紧跟在这里，而不是
          // 像松下那样挂到屏幕下方的参数行上方。
          if (this.sonyChipStripActive()) {
            this.chipStrip()
          }
          this.liveviewArea()
          if (this.stripActive()) {
            this.paramStrip()
          }
          this.paramsRow()
          this.bottomBar()
        }
        .width('100%')
        .height('100%')
        .safeAreaPadding({ top: 24 })
        if (this.overlayActive()) {
          this.panelOverlay()
        }
      }
    }
    .width('100%')
    .height('100%')
    // 只有横竖屏切换时才回写，避免同值回写触发多余渲染。
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      const w = Number(newArea.width);
      const h = Number(newArea.height);
      if (w > 0 && h > 0 && (w !== this.pageW || h !== this.pageH)) {
        this.pageW = w;
        this.pageH = h;
        NikonPtpIpService.log(`sony-control page ${w}x${h}`
          + ` landscape=${this.isLandscapeLayout() ? 1 : 0}`);
      }
    })
    .linearGradient({ angle: 160, colors: [['#0D1017', 0], ['#000000', 1]] })
  }

  /** PTP/IP 线（索尼 / 尼康）身份行：机型 + 传输方式，由识别阶段写入 CameraSessionStore 
   *  cameraModel 回填（见 CameraControlBrand.identityLine）。松下两条线不渲染
   *  此行，所以它们的页面布局与之前完全一致。 */
  @Builder
  private ptpIdentityRow() {
    Column({ space: 1 }) {
      Text(this.ptpIdentity)
        .fontSize(10)
        .fontColor('#93A3BD')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      // 尼康参数探测的结论。参数面板出现「不可用」时，这一行说明原因：
      // 会话未就绪 / 相机拒绝全部属性查询 / 读到了几项。
      if (this.nikonMode && this.nikonParamStatus.length > 0) {
        Text(this.nikonParamStatus)
          .fontSize(10)
          .fontColor(this.nikonProps.length > 0 ? '#6FCF97' : '#E8A33D')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .margin({ top: 2 })
  }

  /** EV/shutter/aperture/ISO/WB/mode use the inline strip above the param row.
   *
   *  索尼线上的画质与比例不在这里：它们的按钮在顶部的芯片行（`chipsRow`），
   *  而这个条渲染在参数行上方（屏幕下方），两者隔着一整个取景画面，子菜单就
   *  出现在离按钮很远的地方。它们改由 `build` 紧跟在 `chipsRow` 之后单独渲染
   *  （`sonyChipStrip`），所以这里不再包含它们。 */
  private stripActive(): boolean {
    if (this.sonyMode) {
      return this.panel === 'ev' || this.panel === 'shutter' || this.panel === 'aperture' ||
        this.panel === 'iso' || this.panel === 'wb' || this.panel === 'mode';
    }
    return this.panel === 'ev' || this.panel === 'shutter' || this.panel === 'aperture' ||
      this.panel === 'iso' || this.panel === 'wb' || this.panel === 'mode';
  }

  /** PTP/IP 线专属：画质/比例的子菜单，挂在芯片行正下方。 */
  private sonyChipStripActive(): boolean {
    return (this.sonyMode || this.nikonMode) && (this.panel === 'quality' || this.panel === 'aspect');
  }

  // -------------------------------------------------------------------------
  // 预览模式
  // -------------------------------------------------------------------------

  /**
   * 预览 / 控制切换。预览是「只看画面」的状态：
   *  - 串流卡片铺满全屏（连状态栏区域一起用），方向跟随系统；
   *  - 数据只以纯白文本压在画面之上，不带任何底色、卡片或圆角块；
   *  - 不可更改：不渲染任何参数控件，触摸对焦也不注册（那是一次对焦动作）；
   *  - 只保留右上角的这两个切换按钮，其余 UI 一律不渲染。
   * 切换本身只改本页状态与窗口方向，不向相机发任何请求。
   */
  private enterPreview(on: boolean): void {
    if (this.previewMode === on) {
      return;
    }
    this.previewMode = on;
    if (on) {
      // 收起可能正展开的参数子菜单，免得切回控制时突兀。
      this.panel = '';
    }
    this.setPreviewOrientation(on);
    // **进预览就把机身控制权交回相机。**
    //
    // 预览模式只看画面、不操作相机，而 HOST 控制权会让机身的拨盘和按键"让位"给
    // 我们 —— 用户切到预览往往正是为了腾出手去动机身。所以进预览发 `0x90C2 [0]`
    // 还回去，回控制模式再 `[1]` 拿回来（档位、录像键都要它才允许）。
    // 两条都是串行队列上的命令，和取帧互不干扰。
    if (this.nikonMode) {
      if (on) {
        NikonPtpIpService.log('nikon-control preview on; releasing host control');
        NikonPtpIpService.releaseHostControl().catch((): void => {
        });
      } else {
        NikonPtpIpService.log('nikon-control preview off; taking host control');
        NikonPtpIpService.takeHostControl().catch((): void => {
        });
      }
    }
    // 文字方向只在预览期间需要跟随设备，控制页不订阅，省电。
    if (on) {
      this.startTextOrientation();
    } else {
      this.stopTextOrientation();
    }
    NikonPtpIpService.log(`sony-control preview=${on ? 1 : 0}`);
  }

  /** 预览里的一行数据。取值与页面上完全同源：画质/比例在芯片行，其余在参数行。 */
  private previewLineOf(label: string, panel: string): string {
    const value = panel === 'quality' || panel === 'aspect'
      ? this.chipValueOf(panel) : this.paramValueOf(panel);
    return `${label} ${value}`;
  }

  /** 横屏画面左侧：曝光三要素 + 曝光补偿。 */
  private previewLeftLines(): string[] {
    return [
      this.previewLineOf('光圈', 'aperture'),
      this.previewLineOf('快门', 'shutter'),
      this.previewLineOf('ISO', 'iso'),
      this.previewLineOf('EV', 'ev')
    ];
  }

  /** 横屏画面右侧：拍摄模式与成像/格式。 */
  private previewRightLines(): string[] {
    return [
      this.previewLineOf('模式', 'mode'),
      this.previewLineOf('白平衡', 'wb'),
      this.previewLineOf('画质', 'quality'),
      this.previewLineOf('比例', 'aspect')
    ];
  }

  /**
   * 预览锁竖屏，离开时把方向还给系统。
   *
   *  **必须锁**：预览的「视频流转 90°」是按竖屏容器算的（见 `previewRotated`），
   *  窗口一旦被系统转成横屏，容器与流就同向了，那 90° 立刻变成多余的一转、
   *  画面反而歪掉。锁住之后预览的画面方向只由我们决定，不再跟随系统。
   *
   *  离开时恢复 `AUTO_ROTATION`（本 ability 在 `module.json5:116` 声明的就是它），
   *  **不是**锁成别的具体方向——窗口方向是全局的，锁死会把这个偏好留给后面的
   *  页面。拿不到窗口时只记日志、不阻断切换。
   */
  private setPreviewOrientation(locked: boolean): void {
    try {
      window.getLastWindow(getContext(this))
        .then((win: window.Window): void => {
          win.setPreferredOrientation(locked
            ? window.Orientation.PORTRAIT
            : window.Orientation.AUTO_ROTATION);
        })
        .catch((error: Object): void => {
          NikonPtpIpService.logError('sony-control orientation', error);
        });
    } catch (error) {
      NikonPtpIpService.logError('sony-control orientation', error as Object);
    }
  }

  /**
   * 订阅重力，让参数文字跟着**设备实际朝向**摆正。
   *
   *  画面是我们主动转 90° 的（预览锁竖屏 + 转流），文字却不能跟着画面转——文字是
   *  给人读的，人怎么拿设备，字就该朝着哪边。所以这里取重力算真实上方，与画面
   *  的固定 90° 完全独立。
   *
   *  只在预览期间订阅：控制页不需要，白耗电。拿不到传感器（无权限/无器件）时只
   *  记日志并退化为不旋转——方向至少是确定的，不会乱抖。
   */
  private startTextOrientation(): void {
    if (this.gravityListener !== null) {
      return;
    }
    const listener = (data: sensor.GravityResponse): void => {
      const angle = textAngleFromGravity(data.x, data.y);
      if (!this.gravitySeen) {
        this.gravitySeen = true;
        NikonPtpIpService.log(`sony-control gravity first`
          + ` x=${data.x.toFixed(2)} y=${data.y.toFixed(2)} z=${data.z.toFixed(2)}`
          + ` angle=${angle}`);
      }
      if (angle !== this.previewTextAngle) {
        this.previewTextAngle = angle;
        NikonPtpIpService.log(`sony-control text angle=${angle}`);
      }
    };
    try {
      // 200ms 足够跟上手动翻屏，又不会让状态频繁抖动。
      sensor.on(sensor.SensorId.GRAVITY, listener, { interval: 200000000 });
      this.gravityListener = listener;
    } catch (error) {
      NikonPtpIpService.logError('sony-control gravity on', error as Object);
    }
  }

  private stopTextOrientation(): void {
    const listener = this.gravityListener;
    if (listener === null) {
      return;
    }
    this.gravityListener = null;
    this.gravitySeen = false;
    this.previewTextAngle = 0;
    try {
      sensor.off(sensor.SensorId.GRAVITY, listener);
    } catch (error) {
      NikonPtpIpService.logError('sony-control gravity off', error as Object);
    }
  }

  /** 画面的宽高比：取帧宽高（`frameW`/`frameH`），首帧未到时退回 3:2 这一常见
   *  传感器比例。 */
  private previewAspect(): number {
    if (this.frameW > 0 && this.frameH > 0) {
      return this.frameW / this.frameH;
    }
    return 3 / 2;
  }

  /**
   * 视频流是否需要旋转 90°。**只看流自己的形状，不看屏幕当前怎么摆。**
   *
   *  本方法只回答"要不要转"；**转多少度由调用点决定**，且实参是 **-90**
   *  （`previewLayer` 里的 `.rotate()`，真机确认过符号——+90 会转成倒置画面）。
   *
   *  之前这里比的是「流的方向 ≠ 容器的方向」，于是系统一转屏条件就翻转、画面
   *  跟着系统转——那正是要去掉的。现在旋转只由预览决定：横流转 90°，竖流不转，
   *  锁死不变。
   *
   *  这条规则成立的前提是容器恒为竖屏，所以 `enterPreview` 进预览时会把窗口方向
   *  锁成 `PORTRAIT`（离开时还给系统的 `auto_rotation`）。**两半是一套机制，不能
   *  只留一半**：锁方向 + 转流 = 竖屏容器里显示一个正立且铺满的横流画面。
   *
   *  **但控制模式不锁方向**（`setPreviewOrientation(false)` 把 `AUTO_ROTATION`
   *  还给系统），用户横置设备时容器就变成横屏，前提不再成立：横流再转 90° 等于
   *  把一个 4:3 的画面塞进 9:16 的框，`previewBoxW/H` 被较紧的一边限死，画面只剩
   *  屏幕中间一小块（真机反馈的「横置后画面非常小」）。所以这里补上容器方向：
   *  **横流 + 横屏容器 → 不转**，让画面按原比例铺满。
   *
   *  这不等于回到「跟着系统转」的老行为：竖屏容器下判定仍只由流决定（镜头是横
   *  是竖就转不转），只有容器自己变横时才放弃那一转——那一转在横屏里纯属有害。
   *
   *  首帧未到（没有宽高）时不转。
   */
  /**
   * 是否用「横屏布局」：画面铺满整屏，控制条浮在上下两端。
   *
   *  竖屏那套是 `Column`：`topBar` + 身份行 + `chipsRow` + 参数行 + `bottomBar`
   *  都是固定高度，`liveviewArea` 只吃 `layoutWeight(1)` 的剩余空间。横屏时屏幕
   *  高度本来就只有 400dp 上下，前四行吃掉一半以上，画面只剩中间一条——这就是
   *  「横置后画面非常小」的真因，与旋转无关（控制态根本不调 `previewRotated`）。
   *
   *  参考实现（argallo/sony-camera-android 的 `CameraScreen.kt`）用的是
   *  `Box { Image(fillMaxSize, ContentScale.Fit); 控件.align(TopCenter/BottomCenter) }`：
   *  画面永远占满，控制条浮在上面。横屏分支照此办理，竖屏保持原样。
   */
  private isLandscapeLayout(): boolean {
    return this.pageW > 0 && this.pageH > 0 && this.pageW > this.pageH;
  }
  private previewRotated(): boolean {
    if (this.frameW <= 0 || this.frameH <= 0) {
      return false;
    }
    // 竖流：任何方向都不转。
    if (this.frameW <= this.frameH) {
      return false;
    }
    // 横流：容器已是横屏就不再转（转了只会把画面缩小）；容器竖屏才立起来。
    if (this.previewW > 0 && this.previewH > 0 && this.previewW > this.previewH) {
      return false;
    }
    return true;
  }

  /** 画面**在屏幕上**的宽高比：旋转 90° 之后就是原比例的倒数。
   *  下面所有「画面占多大、黑边留多少」的算法都用它，所以旋转之后文字与黑边
   *  的几何会自动跟着走，不需要单独处理。 */
  private previewDisplayAspect(): number {
    const aspect = this.previewAspect();
    return this.previewRotated() ? 1 / aspect : aspect;
  }

  /** 画面在预览层里实际占的宽：Contain 会按容器较紧的一边缩放，
   *  所以要么受高度限制，要么受宽度限制，取小的那个。 */
  private previewBoxW(): number {
    if (this.previewW <= 0 || this.previewH <= 0) {
      return this.previewW;
    }
    const byHeight = this.previewH * this.previewDisplayAspect();
    return byHeight <= this.previewW ? byHeight : this.previewW;
  }

  private previewBoxH(): number {
    if (this.previewW <= 0 || this.previewH <= 0) {
      return this.previewH;
    }
    const byWidth = this.previewW / this.previewDisplayAspect();
    return byWidth <= this.previewH ? byWidth : this.previewH;
  }

  /** 旋转**之前**的布局盒。
   *
   *  ArkUI 的 `.rotate()` 是布局之后叠加的视觉变换：盒子本身不变，只是转着画。
   *  所以要让「转完正好贴合容器」，就得先把盒子按转置后的尺寸摆好——否则会拿
   *  一个已经按错误比例缩小的画面去转，转完仍然小。 */
  private previewImageW(): number {
    return this.previewRotated() ? this.previewBoxH() : this.previewBoxW();
  }

  private previewImageH(): number {
    return this.previewRotated() ? this.previewBoxW() : this.previewBoxH();
  }

  /** 一行纯白参数文字。
   *
   *  旋转角来自重力（`previewTextAngle`），**不是**画面的那个固定 90°：文字要跟着
   *  设备实际朝向摆正，人怎么拿设备就怎么读。 */
  @Builder
  private previewLineText(line: string) {
    Text(line)
      .fontSize(13)
      .fontColor('#FFFFFF')
      .rotate({ angle: this.previewTextAngle })
  }

  /**
   * 参数压在**画面之上**，但排布沿用上一版的**上下两排**。
   *
   *  和上一版唯一的区别是定位基准：上一版把两排放进上下**黑边**（高度 = 黑边
   *  高度），这里改成放进**画面自身的矩形**（高度 = 画面高度）。排布本身没动——
   *  仍是成像组一排在上、曝光组一排在下，**不是**左右两列。
   *
   *  换基准是为了避免被切：黑边只有几百像素、上下又被状态栏和屏幕边缘夹着，
   *  文字跟着设备旋转后处在边上那几行会缺一部分。
   *
   *  上下内缩 `SONY_PREVIEW_EDGE_INSET`：旋转后字宽会变成竖直方向的占用，贴着画面
   *  上下边缘摆的话，两端的字会探到画面外去。
   */
  @Builder
  private previewParamsOnImage() {
    Column() {
      Row({ space: SONY_PREVIEW_LINE_GAP }) {
        ForEach(this.previewRightLines(), (line: string) => {
          this.previewLineText(line);
        }, (line: string) => line)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Blank()

      Row({ space: SONY_PREVIEW_LINE_GAP }) {
        ForEach(this.previewLeftLines(), (line: string) => {
          this.previewLineText(line);
        }, (line: string) => line)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
    }
    .width(this.previewBoxW())
    .height(this.previewBoxH())
    .justifyContent(FlexAlign.SpaceBetween)
    .padding({
      left: 12,
      right: 12,
      top: SONY_PREVIEW_EDGE_INSET,
      bottom: SONY_PREVIEW_EDGE_INSET
    })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 右上角的预览 / 控制切换。
   *
   *  位置与外观**直接复用松下 Lab 线的「预览 / 遥控」分段控件**（就在下面的
   *  `topBar` 里）：同一条顶栏、同一个位置（返回键之后的右端），同样的
   *  `#232833` 底槽 + `borderRadius(15)` + `padding(3)`，选中段白字压 `#2563EB`、
   *  未选中段 `#8A97AB` 透明底。索尼线只是把「遥控」换成「控制」，尺寸与间距
   *  一字未改，两条线的顶栏因此长得一样。
   */
  @Builder
  private previewToggle() {
    Row() {
      Text('预览')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.previewMode ? '#FFFFFF' : '#8A97AB')
        .backgroundColor(this.previewMode ? '#2563EB' : 'transparent')
        .borderRadius(12)
        .padding({ left: 11, right: 11, top: 6, bottom: 6 })
        .onClick(() => {
          this.enterPreview(true);
        })
      Text('控制')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.previewMode ? '#8A97AB' : '#FFFFFF')
        .backgroundColor(this.previewMode ? 'transparent' : '#2563EB')
        .borderRadius(12)
        .padding({ left: 11, right: 11, top: 6, bottom: 6 })
        .onClick(() => {
          this.enterPreview(false);
        })
    }
    .backgroundColor('#232833')
    .borderRadius(15)
    .padding(3)
  }

  /** 预览模式下的迷你顶栏：高 62、左右 14、内容垂直居中，与控制页 `topBar`
   *  的量法完全一致；只是去掉返回键与标题，只留右上角的「隐藏参数」与
   *  「预览 / 控制」切换按钮。 */
  @Builder
  private previewTopBar() {
    Row({ space: 8 }) {
      Blank()
      this.previewParamToggle()
      this.previewToggle()
    }
    .width('100%')
    .height(62)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
  }

  /** 预览模式下的「隐藏参数 / 显示参数」开关。
   *
   *  外观与右边的「预览 / 控制」分段控件同源（同样的 `#232833` 底、同样的圆角与
   *  字号），放在它的左边，两个控件一排。文案直接用动词，比一枚含义模糊的图标
   *  更省事——这里只有这一个开关，不存在认错的问题。 */
  @Builder
  private previewParamToggle() {
    Row() {
      Text(this.previewHideParams ? '显示参数' : '隐藏参数')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.previewHideParams ? '#8A97AB' : '#FFFFFF')
    }
    .backgroundColor('#232833')
    .borderRadius(15)
    .padding({ left: 11, right: 11, top: 9, bottom: 9 })
    .accessibilityText(this.previewHideParams ? '显示参数' : '隐藏参数')
    .onClick(() => {
      this.previewHideParams = !this.previewHideParams;
      AppLogStore.add(this.previewHideParams ? 'ui 预览隐藏参数' : 'ui 预览显示参数');
    })
  }

  /** 预览层：全屏画面（保比例，黑边留着）+ 纯白文本参数。
   *
   *  画面用 `ImageFit.Contain` 保完整比例、不裁剪，屏幕与画面的比例差就是黑边，
   *  而**黑边正好用来放参数**：黑边够宽就放进黑边（完全不挡画面），只有黑边窄到
   *  放不下一行字时才退回压在画面上。
   *
   *  流与可用区域不同向时把**视频流本身旋转 90°**（见 `previewRotated`），否则横流
   *  在竖屏上只能缩到「长边 = 屏宽」，中间一条、上下大片黑边。
   *
   *  文字**不**跟画面转：画面转 90° 是给我们看的，文字是给人读的，所以文字吃的是
   *  重力算出来的设备实际朝向（见 `previewLineText` / `startTextOrientation`），
   *  与画面那个固定 90° 完全独立。
   *
   *  文字不需要任何反向旋转：本 ability 声明的是 `auto_rotation`
   *  （`module.json5:116`），用户转动设备时整个界面连同画面与文字一起被系统转过去，
   *  方向天然一致。 */
  @Builder
  private previewLayer() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.framePm !== undefined && this.phase !== 'error') {
        if (this.previewW > 0 && this.previewH > 0) {
          // 已量到容器尺寸：按「先转置布局、再旋转 -90°」的方式摆放，
          // 转完正好贴合容器，画面利用率最高。
          //
          // **角度是 -90，不是 +90**（真机实测确认）：ArkUI 的 `.rotate()` 正角
          // 在数学意义上是顺时针，但 LUMIX 这套 liveview 帧本身带的方向与屏幕
          // 坐标系相反，用 +90 会把画面转成**倒置**的横流。写 -90 才是用户看到的
          // 「顺时针转 90° 后正立」。改这个符号前请先在真机上看一次，别按字面推。
          Image(this.framePm)
            .objectFit(ImageFit.Contain)
            .width(this.previewImageW())
            .height(this.previewImageH())
            .rotate({ angle: this.previewRotated() ? -90 : 0 })
        } else {
          // 首帧还没量到容器：先按容器铺开，量到之后自动精确定位。
          Image(this.framePm)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')
        }
        // 上下两排参数压在画面上（见 previewParamsOnImage）：排布与上一版黑边版
        // 完全一致，只是把定位基准从黑边换成画面矩形，免得边上那几行被切掉。
        // 「隐藏参数」打开时整排不渲染，画面回到干净的取景。
        if (!this.previewHideParams) {
          this.previewParamsOnImage()
        }
      } else {
        Text(this.phase === 'error' ? this.statusText : '等待相机画面…')
          .fontSize(13)
          .fontColor('#FFFFFF')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    // 铺满全屏：连状态栏/导航栏占的那一条也一起用，否则「全屏」会缺两个边。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 容器实测尺寸：浮层的宽高由它推出来，才能和 Contain 之后的画面严丝合缝。
    // 赋值前比对一次，避免同值回写把自己再触发一轮渲染。
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      const w = Number(newValue.width);
      const h = Number(newValue.height);
      if (!Number.isNaN(w) && !Number.isNaN(h) && w > 0 && h > 0 &&
        (w !== this.previewW || h !== this.previewH)) {
        this.previewW = w;
        this.previewH = h;
        // 只在尺寸变化时打一行，便于真机核对旋转判定。
        NikonPtpIpService.log(`sony-control preview box ${w}x${h}`
          + ` frame=${this.frameW}x${this.frameH}`
          + ` rotate=${this.previewRotated() ? 1 : 0}`);
      }
    })
  }

  /** LUT/quality/aspect/settings keep the centered overlay panel. PTP/IP 线
   *  （索尼 / 尼康）上只有照片风格与设置走这里没有取值通道，其余都已改走
   *  `chipStrip`。 */
  private overlayActive(): boolean {
    if (this.sonyMode || this.nikonMode) {
      return this.panel === 'lut' || this.panel === 'settings';
    }
    return this.panel === 'lut' || this.panel === 'quality' || this.panel === 'aspect' ||
      this.panel === 'settings';
  }

  @Builder
  private topBar() {
    Stack() {
      Text('相机控制')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
      Row() {
        Text('‹')
          .fontSize(34)
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
        Blank()
        // 预览 / 控制 分段控件。
        //
        // 索尼/尼康一直用它切本页的只读预览。松下 Lab 线原先在**同一个位置**放的
        // 是「预览 / 遥控」——那个切的是**相机端优先权**（`operatepriority`），跟
        // 本页取景无关。按用户 2026-10-18 决定移除它，Lab 线也改成「预览 / 控制」，
        // 这样三条线共用一套：全屏只读预览 + 视频转 90° + 隐藏参数监看。
        //
        // 移除优先权开关是安全的：`remoteOn` 只被该控件自身用于着色，
        // 拍摄/取景/参数链路都不读它（CameraControlPage:2159 仅从帧元数据同步显示，
        // togglePriority 也只由这个控件调用）。
        // Sync 线（cam.cgi）不提供该控件。
        if (!this.syncMode) {
          this.previewToggle()
        }
        // 图片传输入口已移至主页面（仅保留主页面入口，2026-09-28）
      }
      .width('100%')
    }
    .alignContent(Alignment.Center)
    .width('100%')
    .height(62)
    .padding({ left: 14, right: 14 })
  }

  @Builder
  private chip(title: string, panel: string) {
    Column({ space: 3 }) {
      // 没有数据的面板去掉下拉箭头（点不开），但仍然显示、灰显、不可点
      Text(this.controlPanelEnabled(panel) ? `${title} ▾` : title)
        .fontSize(10)
        .fontColor(this.controlPanelEnabled(panel) ? '#8A97AB' : '#4A5872')
      Text(this.chipValueOf(panel))
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.controlPanelEnabled(panel) ? '#FFFFFF' : '#5A6478')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '90%' })
    }
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(48)
    .padding({ left: 6, right: 6 })
    .backgroundColor('#1A1E27')
    .borderRadius(16)
    .opacity(this.controlPanelEnabled(panel) ? 1 : 0.55)
    .enabled(this.controlPanelEnabled(panel))
    .onClick(() => {
      this.panel = this.panel === panel ? '' : panel;
    })
  }

  @Builder
  private chipsRow() {
    Row({ space: 8 }) {
      this.chip(this.syncMode ? '格调' : 'LUT', 'lut')
      this.chip('画质', 'quality')
      this.chip('比例', 'aspect')
      this.chip('设置', 'settings')
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .margin({ top: 2 })
  }

  @Builder
  private liveviewArea() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        if (this.framePm !== undefined && this.phase !== 'error') {
          Image(this.framePm)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')
        } else {
          Column({ space: 10 }) {
            Text('◎')
              .fontSize(42)
              .fontColor('#4A5872')
            Text(this.phase === 'connecting' || this.phase === 'error' ? this.statusText :
              '等待相机画面…')
              .fontSize(13)
              .fontColor('#93A3BD')
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 })
            if (this.phase === 'error') {
              Text('重新连接')
                .fontSize(13)
                .fontColor('#FFFFFF')
                .backgroundColor('#2563EB')
                .borderRadius(15)
                .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                .onClick(() => {
                  this.startConnect();
                })
            }
          }
        }
        if (this.recording) {
          Row({ space: 5 }) {
            Text('●')
              .fontSize(10)
              .fontColor('#E5484D')
            Text('REC')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor('#66000000')
          .borderRadius(12)
          .position({ x: 12, y: 12 })
        }
        if (this.phase === 'live' && this.statusText !== '') {
          Text(this.statusText)
            .fontSize(11)
            .fontColor('#FFFFFF')
            .backgroundColor('#66000000')
            .borderRadius(12)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .position({ x: '50%', y: '94%' })
            .markAnchor({ x: '50%', y: '50%' })
        }
        if (this.afX >= 0) {
          Column()
            .width(30)
            .height(30)
            .borderRadius(15)
            .border({ width: 1.5, color: '#FFFFFF' })
            .position({ x: this.afX - 15, y: this.afY - 15 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0D1420')
      .borderRadius(22)
      .clip(true)
      .onClick((event: ClickEvent) => {
        this.onLiveviewTap(event);
      })
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        this.lvW = Number(newArea.width);
        this.lvH = Number(newArea.height);
      })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 14, right: 14, top: 10 })
  }

  /** 六个参数胶囊等宽：总宽（含 5 个 6vp 间距）与取景画面宽度一
   *  （取景区左右 14 内边距与参数行一致）。 */
  private paramCapsuleWidth(): number {
    if (this.lvW <= 0) {
      return 62;
    }
    return Math.max(46, (this.lvW - 30) / 6);
  }

  @Builder
  private param(title: string, panel: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(10)
        .fontColor(this.controlPanelEnabled(panel)
          ? (this.panel === panel ? '#6EA8FE' : '#8A97AB')
          : '#4A5872')
      Text(this.paramValueOf(panel))
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.controlPanelEnabled(panel)
          ? (this.panel === panel ? '#6EA8FE' : '#FFFFFF')
          : '#5A6478')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(this.paramCapsuleWidth())
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor(this.panel === panel ? '#12233F' : '#1A1E27')
    .borderRadius(14)
    .opacity(this.controlPanelEnabled(panel) ? 1 : 0.55)
    .enabled(this.controlPanelEnabled(panel))
    .onClick(() => {
      // Sync 线的模式切换（setsetting recmode）由相机端裁定：机身拨盘
      // 位置决定相机是否接受；拒绝时返回 err_param 并 toast 展示
      this.sliderPreview = -1;
      this.panel = this.panel === panel ? '' : panel;
    })
  }

  @Builder
  private paramsRow() {
    Scroll() {
      Row({ space: 6 }) {
        this.param('模式', 'mode')
        this.param('EV', 'ev')
        this.param('快门', 'shutter')
        this.param('光圈', 'aperture')
        this.param('ISO', 'iso')
        this.param('白平衡', 'wb')
      }
      .padding({ left: 14, right: 14 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: 10, bottom: 10 })
  }

  /** 拍照 / 录像的两个白框图标，用来切换底栏主按钮的意图。
   *
   *  两个都是 34×34 的方框、1px 边框：选中的那个边框和图标是纯白并带一层淡白底，
   *  未选中的降到灰边灰图标——两个都亮的话看不出当前是哪个模式。 */
  @Builder
  private modeSwitchIcons() {
    Row({ space: 8 }) {
      this.modeIcon(false, $r('sys.symbol.camera'), '拍照')
      this.modeIcon(true, $r('sys.symbol.film'), '录像')
    }
  }

  @Builder
  private modeIcon(movie: boolean, symbol: Resource, tip: string) {
    Column() {
      SymbolGlyph(symbol)
        .fontSize(17)
        .fontColor([this.movieMode === movie ? '#FFFFFF' : '#7C8798'])
    }
    .width(34)
    .height(34)
    .justifyContent(FlexAlign.Center)
    .borderRadius(11)
    .borderWidth(1)
    .borderColor(this.movieMode === movie ? '#FFFFFF' : '#4A5568')
    .backgroundColor(this.movieMode === movie ? '#FFFFFF1A' : Color.Transparent)
    // 正在拍 / 正在录的时候不许切模式：主按钮是按模式决定动作的，中途切过去会
    // 出现"按钮显示相机图标、机身在录像"这种对不上的状态。
    .opacity(this.shooting || this.recording ? 0.4 : 1)
    .accessibilityText(tip)
    .onClick(() => {
      if (this.shooting || this.recording) {
        AppLogStore.add('ui 拍摄/录像进行中，忽略模式切换');
        return;
      }
      if (this.movieMode === movie) return;
      this.movieMode = movie;
      AppLogStore.add(movie ? 'ui 切到录像模式' : 'ui 切到拍照模式');
      // 两套参数是两组属性码，切换之后面板要显示的是另一组的值。探测本身幂等
      // （`nikonParamRefreshing` 挡重入），失败也只是面板显示旧值，不影响取景。
      if (this.nikonMode) {
        void this.nikonRefreshParams();
      }
    })
  }

  /** 底栏主按钮的底色。
   *
   *  拍照模式是蓝色，录像模式是红色——颜色本身就说明"这一下会拍照片还是开始录像"，
   *  和里面那枚图标一起读，比原来"拍摄 / 开始录像"两行文字更直接。进行中（
   *  `shooting` / `recording`）用浅一档的同色，仍然能看出当前是什么状态。 */
  private shutterBackground(): string {
    if (this.movieMode) {
      return this.shooting || this.recording ? '#F08A8E' : '#E5484D';
    }
    return this.shooting ? '#7EA6F5' : '#2563EB';
  }

  @Builder
  private bottomBar() {
    Row({ space: 12 }) {
      this.modeSwitchIcons()
      // 主按钮：**只有图标，没有文字**。
      //
      // 模式由左边两个白框图标决定，按钮用同一套原生图标把"按下去会发生什么"再
      // 说一遍：拍照模式是相机图标，录像模式是胶片图标。原来这里写的是"拍摄 /
      // 开始录像"两行字，右边还另有一个"开始录像"按钮——同一个动作两个入口、
      // 两种说法，模式切换之后按钮文字也跟着变，反而更难读。
      Column() {
        SymbolGlyph(this.movieMode ? $r('sys.symbol.film') : $r('sys.symbol.camera'))
          .fontSize(26)
          .fontColor([this.shooting ? '#0D1017' : '#FFFFFF'])
      }
      .layoutWeight(1)
      .height(52)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.shutterBackground())
      .borderRadius(20)
      .accessibilityText(this.movieMode ? (this.recording ? '停止录像' : '开始录像') : '拍摄')
      .onClick(() => {
        if (this.movieMode) {
          this.toggleVideo();
        } else {
          this.capture();
        }
      })
      // 对焦按钮已移除（Sync 线触屏对焦走取景画面点按）。录像入口也不再单独
      // 占一个按钮：切到录像模式之后，这个主按钮就是开始/停止录像。
    }
    .width('100%')
    .padding({ left: 14, right: 14, bottom: 12 })
  }

  // -------------------------------------------------------------------------
  // Inline parameter strip (shown above the param row)
  // -------------------------------------------------------------------------

  @Builder
  private paramStrip() {
    Column() {
      Column() {
        if (this.panel === 'mode' || this.panel === 'wb' || this.sonyMode || this.nikonMode) {
          this.chipStrip()
        } else {
          this.sliderStrip()
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 8 })
      .backgroundColor('#1A1E27')
      .borderRadius(18)
      .attributeModifier(VividMaterial.cardNight)
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .margin({ top: 10 })
  }

  /** 模式/白平衡：水平点击选择。 */
  @Builder
  private chipStrip() {
    Column({ space: 8 }) {
      Text(this.panelTitle())
        .fontSize(11)
        .fontColor('#8A97AB')
        .width('100%')
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.currentPanelOptions(), (opt: LumixSettingOption) => {
            Row({ space: 5 }) {
              // 白平衡图标是松下那套域的画法（wbIconOf 按松下的 raw 取值）。
              // 索尼的 raw 是另一个域，套上去只会显示错误的图标，所以索尼线
              // 一律走文字标签。
              if (this.panel === 'wb' && this.wbIconFor(opt.value) !== undefined) {
                Image(this.wbIconFor(opt.value))
                  .width(this.nikonMode ? 24 : 18)
                  .height(this.nikonMode ? 24 : 18)
                  .objectFit(ImageFit.Contain)
              }
              // **尼康白平衡只用图标，不写字。** 一排天气/色温图标比"晴天/阴天/白炽灯"
              // 更快读懂，和机身菜单也是一套；图标找不到时仍退回文字。松下/Sync 保持
              // 图标 + 文字的原样。
              if (!(this.nikonMode && this.panel === 'wb' && this.wbIconFor(opt.value) !== undefined)) {
                Text(opt.label)
                  .fontSize(12)
                  .fontWeight(this.isCurrentOption(opt) ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor('#FFFFFF')
                  .maxLines(1)
              }
            }
            .backgroundColor(this.isCurrentOption(opt) ? '#2563EB' : '#2A2F3B')
            .borderRadius(14)
            .padding({ left: 13, right: 13, top: 7, bottom: 7 })
            .onClick(() => {
              this.applyTagged(this.panel, opt.value);
            })
          }, (opt: LumixSettingOption) => `${this.panel}#${opt.value}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
  }

  /** EV/快门/ISO：滑动选择；光圈：只读显示（镜头控制，协议无光圈设置键）。 */
  @Builder
  private sliderStrip() {
    Column({ space: 4 }) {
      Row() {
        Text(this.panelTitle())
          .fontSize(11)
          .fontColor('#8A97AB')
        Blank()
        Text(this.stripValueLabel())
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#2563EB')
      }
      .width('100%')
      if (this.panel === 'aperture' && !this.syncMode) {
        Text('光圈由镜头光圈环控制，此处仅显示当前值')
          .fontSize(10)
          .fontColor('#93A3BD')
          .width('100%')
      }
      if (this.syncMode && this.syncAutoHint().length > 0) {
        Text(this.syncAutoHint())
          .fontSize(10)
          .fontColor('#E8B93C')
          .width('100%')
      }
      Slider({
        // 值域钳制：相机返回值与选项表不匹配时索引可能越界，
        // Slider 值域违规会抛 BusinessError 直接杀进程
        value: Math.max(0, Math.min(this.stripSliderIndex(), this.stripMaxIndex())),
        min: 0,
        max: this.stripMaxIndex(),
        step: 1,
        style: SliderStyle.OutSet
      })
        .selectedColor('#2563EB')
        .blockColor('#2563EB')
        .trackColor('#2A2F3B')
        .width('100%')
        .enabled(this.panel !== 'aperture' || this.syncMode)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.onStripSlide(value, mode);
        })
      Row() {
        Text(this.stripEdgeLabel(false))
          .fontSize(10)
          .fontColor('#93A3BD')
        Blank()
        Text(this.stripEdgeLabel(true))
          .fontSize(10)
          .fontColor('#93A3BD')
      }
      .width('100%')
    }
    .width('100%')
  }

  /** 当前档位下由相机自动控制的鼓轮提示（A 档快门自动等）。 */
  private syncAutoHint(): string {
    switch (this.panel) {
      case 'shutter':
        if (this.syncModeRaw === 'aperture_ae') {
          return '当前 A 档：快门由相机自动控制，设置值不生效';
        }
        if (this.syncModeRaw === 'program_ae') {
          return '当前 P 档：快门由相机自动控制，设置值不生效';
        }
        break;
      case 'aperture':
        if (this.syncModeRaw === 'shutter_ae') {
          return '当前 S 档：光圈由相机自动控制，设置值不生效';
        }
        if (this.syncModeRaw === 'program_ae') {
          return '当前 P 档：光圈由相机自动控制，设置值不生效';
        }
        break;
      case 'ev':
        if (this.syncModeRaw === 'manual_exposure') {
          return '当前 M 档：EV 不可用';
        }
        break;
      default:
        break;
    }
    return '';
  }

  private stripOptionList(): LumixSettingOption[] {
    if (this.panel === 'aperture' && !this.syncMode) {
      return [];
    }
    return this.currentPanelOptions();
  }

  private stripMaxIndex(): number {
    if (this.panel === 'aperture' && !this.syncMode) {
      return APERTURE_STOP_COUNT - 1;
    }
    return Math.max(this.stripOptionList().length - 1, 1);
  }

  private stripSliderIndex(): number {
    if (this.panel === 'aperture' && !this.syncMode) {
      const idx = apertureIndexOf(this.info.avCur256);
      return idx >= 0 ? idx : 0;
    }
    const list = this.stripOptionList();
    if (list.length === 0) {
      return 0;
    }
    if (this.sliderPreview >= 0 && this.sliderPreview < list.length) {
      return this.sliderPreview;
    }
    for (let i = 0; i < list.length; i++) {
      if (this.isCurrentOption(list[i])) {
        return i;
      }
    }
    return 0;
  }

  private stripValueLabel(): string {
    if (this.panel === 'aperture' && !this.syncMode) {
      return this.info.apertureLabel;
    }
    const list = this.stripOptionList();
    const idx = this.stripSliderIndex();
    return idx >= 0 && idx < list.length ? list[idx].label : '--';
  }

  private stripEdgeLabel(last: boolean): string {
    if (this.panel === 'aperture' && !this.syncMode) {
      return last ? 'F32' : 'F1';
    }
    const list = this.stripOptionList();
    if (list.length === 0) {
      return '';
    }
    return last ? list[list.length - 1].label : list[0].label;
  }

  private onStripSlide(value: number, mode: SliderChangeMode): void {
    if (this.panel === 'aperture' && !this.syncMode) {
      return;
    }
    if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
      this.sliderPreview = value;
      return;
    }
    this.sliderPreview = -1;
    const list = this.stripOptionList();
    if (value >= 0 && value < list.length) {
      // Keep the strip open so the value can be fine-tuned repeatedly.
      this.applyTagged(this.panel, list[value].value, true);
    }
  }

  @Builder
  private panelOverlay() {
    Column() {
      Column()
        .height(122)
      if (this.panel === 'settings') {
        this.settingsPanel()
      } else {
        this.optionPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#40000000')
    .padding({ left: 14, right: 14 })
    .onClick(() => {
      this.panel = '';
    })
  }

  @Builder
  private optionPanel() {
    Column() {
      Text(this.panelTitle())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 6 })
      Scroll() {
        Column() {
          ForEach(this.currentPanelOptions(), (opt: LumixSettingOption) => {
            this.checkRow(opt.label, this.isCurrentOption(opt), this.panel, opt.value)
          }, (opt: LumixSettingOption) => opt.value)
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 320 })
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .backgroundColor('#1A1E27')
    .borderRadius(20)
    .attributeModifier(VividMaterial.cardNight)
  }

  @Builder
  private settingsPanel() {
    Column() {
      Text(this.panelTitle())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 6 })
      Scroll() {
        Column() {
          Text('测光模式')
            .fontSize(11)
            .fontColor('#8A97AB')
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 4 })
          if (this.syncMode) {
            ForEach(this.syncMeteringOptions(), (opt: LumixSettingOption) => {
              this.checkRow(opt.label, opt.value === this.syncMeteringRaw,
                'metering', opt.value)
            }, (opt: LumixSettingOption) => `sm${opt.value}`)
          } else {
            ForEach(this.optionsFor('lightmetering'), (opt: LumixSettingOption) => {
              this.checkRow(opt.label, parseHexValue(opt.value) === this.info.meteringValue,
                'metering', opt.value)
            }, (opt: LumixSettingOption) => `m${opt.value}`)
          }
          if (!this.syncMode) {
            Text('取景画质')
              .fontSize(11)
              .fontColor('#8A97AB')
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 4 })
            ForEach(this.optionsFor('liveviewsize'), (opt: LumixSettingOption) => {
              this.checkRow(opt.label, parseHexValue(opt.value) === this.info.lvQualityValue,
                'lvsize', opt.value)
            }, (opt: LumixSettingOption) => `l${opt.value}`)
          }
        }
        .width('100%')
        .padding({ bottom: 8 })
      }
      .constraintSize({ maxHeight: 360 })
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .backgroundColor('#1A1E27')
    .borderRadius(20)
    .attributeModifier(VividMaterial.cardNight)
  }

  @Builder
  private checkRow(label: string, selected: boolean, tag: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight(selected ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(selected ? '#2563EB' : '#FFFFFF')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (selected) {
        Text('✓')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#2563EB')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      this.applyTagged(tag, value);
    })
  }
}
