/*
 * 佳能（Canon / EOS PTP-IP）相机控制页 —— LAB 风格
 *
 * 出处（契约）：
 *  - docs/canon-route-design.md §0（铁律：不伪造可写 / ArkTS 严格 / CANON_CTL 日志）、
 *    §1（cameraBrand = 'Canon'、路由 pages/CanonCameraControlPage）、
 *    §4.1/§4.2（CanonParamSpec 的 edsPropId / ptpDpc 与 CanonControlService 对外 API）、
 *    §7.1（本页布局与两态要求，**不保留 LUT 传输入口**）；
 *  - 报告 02 §2（14 个可控参数的 EDSDK 属性 ID）、§3.3（500 ms 去抖由服务负责）、
 *    §4（StartEvf / DownloadLiveViewData / GetFocusInfo 对焦框）、
 *    §5.1（快门 5 个 param：0 / 1 / 0x10001 / 3 / 0x10003）、
 *    §5.2（命令 258 DoEvfAf、265/269 变焦）、§5.3（B 门 = 长按保持 S2，松手 param=0，标注【推断】）、
 *    §7（进入控制页的完整报文序列）。
 *
 * 本页只做三件事：渲染、手势、把用户意图翻译成 `CanonControlService` 调用。
 * 协议常量、参数描述符、快门 param 的 switch/action 拆分全部在服务里，
 * 页面不复制一份协议真相，也不在相机没给描述符时假装可写。
 *
 * 两种形态（用户明确要求，必须严格区分）：
 *  - 预览：整屏取景（Image PixelMap + ImageFit.Contain）+ AF 框 + 底部快门/录像；
 *    **只有这个形态**调用 `startLiveView()`；
 *  - 遥控：顶栏 + 身份行 + 快捷参数 + 冻结画面 + 参数网格 + 底栏；
 *    切到遥控的瞬间就 `stopLiveView()`，画面停在最后一帧。
 *  「预览 / 遥控」只改本页状态与推流开关，不重建服务会话。
 */
import { image } from '@kit.ImageKit';
import { CameraSessionStore } from '../services/CameraSessionStore';
import { CanonModels } from '../services/CanonModels';
import {
  CanonCaptureEvent,
  CanonControlService,
  CanonControlSnapshot,
  CanonParamOption,
  CanonParamSpec,
} from '../services/CanonControlService';

/**
 * 「参数对照」抽屉的静态行：报告 02 §2「可控参数大表」的 EDSDK 属性 ID，
 * 配上设计文档 §4.1 的 PTP DPC（该列来自 libgphoto2 `ptp.h`，报告明确说
 * native 侧未取得，属交叉核对值）。
 *
 * 为什么页面自己留一份：相机可能完全不给描述符（`getProps()` 为空），
 * 但用户仍要能逐条核对「报告里写了什么」。所以对照表恒显示 14 行，
 * 相机上报了的行用 `CanonParamSpec` 的真值覆盖静态值。
 */
interface CanonParamRef {
  key: string;
  label: string;
  edsPropId: number;
  ptpDpc: number;
}

/** 对照抽屉的一行，全部字段在 `compareRows()` 里算好，build 只做渲染。 */
interface CanonCompareRow {
  key: string;
  label: string;
  edsText: string;
  ptpText: string;
  valueText: string;
  writableText: string;
  writable: boolean;
  available: boolean;
}

/** 报告 02 §2 的 14 项（key 与设计文档 §4.1 的面板 key 一致）。 */
const CANON_PARAM_REFS: CanonParamRef[] = [
  { key: 'quality', label: '画质', edsPropId: 0x0100, ptpDpc: 0xD120 },
  { key: 'wb', label: '白平衡', edsPropId: 0x0106, ptpDpc: 0xD109 },
  { key: 'mode', label: '曝光模式', edsPropId: 0x0400, ptpDpc: 0xD105 },
  { key: 'drive', label: '驱动模式', edsPropId: 0x0401, ptpDpc: 0xD106 },
  { key: 'iso', label: 'ISO', edsPropId: 0x0402, ptpDpc: 0xD103 },
  { key: 'metering', label: '测光', edsPropId: 0x0403, ptpDpc: 0xD107 },
  { key: 'focus', label: '对焦模式', edsPropId: 0x0404, ptpDpc: 0xD108 },
  { key: 'aperture', label: '光圈', edsPropId: 0x0405, ptpDpc: 0xD101 },
  { key: 'shutter', label: '快门', edsPropId: 0x0406, ptpDpc: 0xD102 },
  { key: 'ev', label: '曝光补偿', edsPropId: 0x0407, ptpDpc: 0xD104 },
  { key: 'bracket', label: '包围曝光', edsPropId: 0x040A, ptpDpc: 0xD11D },
  { key: 'zoomSpeed', label: '变焦速度', edsPropId: 0x0444, ptpDpc: 0xD149 },
  { key: 'lvOutput', label: '取景输出', edsPropId: 0x0500, ptpDpc: 0xD1B0 },
  { key: 'lvMode', label: '取景模式', edsPropId: 0x0501, ptpDpc: 0xD1B1 },
];

/** 遥控态快捷条：与松下 LAB 的「模式 / EV / 快门 / 光圈 / ISO / 白平衡」同序。 */
const CANON_QUICK_KEYS: string[] = ['mode', 'ev', 'shutter', 'aperture', 'iso', 'wb'];

/** B 门长按阈值：超过它才把这次按下当成「保持 S2」（报告 02 §5.3【推断】）。 */
const CANON_BULB_HOLD_MS: number = 700;
/** AF 框停留时间（对焦指令已发/失败都会在这个时间内收起）。 */
const CANON_AF_BOX_MS: number = 1600;
/** 曝光完成事件的兜底解除时间，避免事件丢失时快门一直「进行中」。 */
const CANON_CAPTURE_FALLBACK_MS: number = 3000;
/** 「半按对焦」按一下保持多久：到时自动 release，绝不把相机晾在半按态。 */
const CANON_HALF_PRESS_MS: number = 900;
/** 属性变化事件的合并刷新间隔（相机可能连发多条 0xC189）。 */
const CANON_PROPS_REFRESH_MS: number = 80;
/**
 * 变焦方向约定（页面 -> 服务）：1 = 长焦（Tele）、2 = 广角（Wide）、0 = 停止。
 * 报告 02 §5.2：变焦走命令 265（DrivePowerZoom，先写属性 1092 速度）
 * 与命令 269（方向/停止）；具体 opcode 与参数映射由服务负责。
 */
const CANON_ZOOM_TELE: number = 1;
const CANON_ZOOM_WIDE: number = 2;
const CANON_ZOOM_STOP: number = 0;
/** 相机没上报 0xD149 时的兜底速度档（值域由服务解释）。 */
const CANON_DEFAULT_ZOOM_SPEED: number = 1;

@Entry
@Component
struct CanonCameraControlPage {
  // ---- 会话与状态 ---------------------------------------------------------
  @State private valid: boolean = true;
  /** 'idle' | 'connecting' | 'ready' | 'degraded' | 'error' */
  @State private phase: string = 'idle';
  @State private statusText: string = '';
  @State private model: string = '';
  @State private firmware: string = '';
  @State private serial: string = '';
  @State private propsReady: boolean = false;
  @State private degradedReason: string = '';
  @State private liveViewError: string = '';

  // ---- 形态与画面 ---------------------------------------------------------
  @State private previewMode: boolean = true;
  @State private framePm: image.PixelMap | undefined = undefined;
  @State private frameW: number = 0;
  @State private frameH: number = 0;
  @State private previewW: number = 0;
  @State private previewH: number = 0;

  // ---- 参数 ---------------------------------------------------------------
  @State private props: CanonParamSpec[] = [];
  @State private selectedKey: string = '';
  @State private showCompare: boolean = false;

  // ---- 拍摄 ---------------------------------------------------------------
  @State private shooting: boolean = false;
  @State private recording: boolean = false;
  @State private movieMode: boolean = false;
  @State private afOn: boolean = false;
  @State private afX: number = -1;
  @State private afY: number = -1;
  /** '' | 'pending' | 'sent' | 'failed' */
  @State private afState: string = '';
  @State private bulbActive: boolean = false;
  @State private bulbMs: number = 0;

  // ---- 生命周期标志 -------------------------------------------------------
  @State private leaving: boolean = false;

  private disposed: boolean = false;
  private refreshTimer: number = -1;
  private afTimer: number = -1;
  private bulbHoldTimer: number = -1;
  private bulbTicker: number = -1;
  private shootTimer: number = -1;
  private halfReleaseTimer: number = -1;
  private bulbStartMs: number = 0;
  private pressHeld: boolean = false;
  private frameBusy: boolean = false;

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  aboutToAppear(): void {
    const store = CameraSessionStore.instance;
    this.valid = store.cameraBrand === CanonModels.BRAND;
    this.model = store.cameraModel;
    if (!this.valid) {
      this.phase = 'error';
      this.statusText = `当前会话是 ${store.cameraBrand}，不是佳能相机`;
      this.log(`ui 拒绝进入：brand=${store.cameraBrand} 期望=${CanonModels.BRAND}`);
      return;
    }
    this.log(`ui 进入佳能控制页 model=${this.model}`);
    void this.begin();
  }

  aboutToDisappear(): void {
    // 兜底：onBackPress 没走到（被系统手势/多任务杀掉）时也要停流、关会话。
    this.teardown();
    if (!this.leaving) {
      void this.shutdownSafely();
    }
  }

  onBackPress(): boolean {
    this.exitPage();
    return true;
  }

  // -------------------------------------------------------------------------
  // 连接
  // -------------------------------------------------------------------------

  private async begin(): Promise<void> {
    if (this.disposed) return;
    this.phase = 'connecting';
    this.liveViewError = '';
    this.statusText = '正在建立 PTP-IP 会话（相机需处于「遥控」模式）…';
    this.installCallbacks();
    try {
      const snapshot: CanonControlSnapshot = await CanonControlService.connect(this.model);
      if (this.disposed) {
        void this.shutdownSafely();
        return;
      }
      this.applySnapshot(snapshot);
      this.phase = snapshot.propsReady ? 'ready' : 'degraded';
      this.statusText = snapshot.propsReady
        ? ''
        : '参数描述不可用：拍摄与取景仍可尝试，参数项保持置灰';
      this.movieMode = this.safeMovieMode();
      this.log(`ui 会话就绪 props=${snapshot.propCount}` +
        ` ready=${snapshot.propsReady ? 1 : 0}` +
        ` degraded=${snapshot.degradedReason.length > 0 ? snapshot.degradedReason : 'none'}`);
      // 只有预览态推流：默认进页面就是预览态。
      if (this.previewMode) {
        await this.startLiveView();
      }
    } catch (error) {
      if (this.disposed) return;
      this.phase = 'error';
      this.statusText = this.explain(error);
      this.log(`连接失败：${this.describe(error)}`);
    }
  }

  /** 注册帧/事件回调；所有回调都先看 `disposed`，页面销毁后不再触碰状态。 */
  private installCallbacks(): void {
    try {
      CanonControlService.setCallbacks({
        onLiveViewFrame: (jpeg: Uint8Array): void => {
          this.onFrame(jpeg);
        },
        onCapture: (event: CanonCaptureEvent): void => {
          this.onCaptureEvent(event);
        },
        onPropChanged: (key: string, value: number): void => {
          this.schedulePropRefresh();
          this.log(`ui 属性变化 ${key}=${value}`);
        },
        onDeviceChanged: (): void => {
          this.schedulePropRefresh();
        },
        onNotice: (message: string): void => {
          if (message.length > 0) this.toast(message);
        },
      });
    } catch (error) {
      this.log(`注册回调失败：${this.describe(error)}`);
    }
  }

  private applySnapshot(snapshot: CanonControlSnapshot): void {
    this.model = snapshot.model.length > 0 ? snapshot.model : this.model;
    this.firmware = snapshot.firmware;
    this.serial = snapshot.serial;
    this.propsReady = snapshot.propsReady;
    this.degradedReason = snapshot.degradedReason;
    this.reloadProps();
  }

  /** 参数只有一个来源：`CanonControlService.getProps()`（设计 §7.1）。 */
  private reloadProps(): void {
    try {
      const list: CanonParamSpec[] = CanonControlService.getProps();
      this.props = list.slice();
    } catch (error) {
      this.log(`读取参数列表失败：${this.describe(error)}`);
    }
  }

  /** 单个参数的安全取用：服务异常时返回 null，页面按「不可用」处理。 */
  private specOf(key: string): CanonParamSpec | null {
    try {
      return CanonControlService.propOf(key);
    } catch (error) {
      this.log(`读取参数 ${key} 失败：${this.describe(error)}`);
      return null;
    }
  }

  private safeMovieMode(): boolean {
    try {
      return CanonControlService.isMovieMode();
    } catch (error) {
      this.log(`读取短片模式失败：${this.describe(error)}`);
      return false;
    }
  }

  private schedulePropRefresh(): void {
    if (this.disposed || this.refreshTimer >= 0) return;
    this.refreshTimer = setTimeout((): void => {
      this.refreshTimer = -1;
      if (this.disposed) return;
      this.reloadProps();
    }, CANON_PROPS_REFRESH_MS);
  }

  private async refreshProps(showToast: boolean): Promise<void> {
    if (!this.isOperational()) return;
    try {
      const ok: boolean = await CanonControlService.refreshProps();
      this.reloadProps();
      if (showToast) {
        this.toast(ok ? '参数已刷新' : '参数刷新失败：相机未返回描述符');
      }
    } catch (error) {
      this.log(`刷新参数失败：${this.describe(error)}`);
      if (showToast) this.toast(`参数刷新失败：${this.describe(error)}`);
    }
  }

  private retryConnect(): void {
    if (this.leaving || this.disposed) return;
    this.phase = 'connecting';
    this.statusText = '正在重连…';
    this.log('ui 用户点重试');
    void this.begin();
  }

  // -------------------------------------------------------------------------
  // 取景（只有预览态推流）
  // -------------------------------------------------------------------------

  private async startLiveView(): Promise<void> {
    if (!this.isOperational() || this.disposed) return;
    this.liveViewError = '';
    try {
      const ok: boolean = await CanonControlService.startLiveView();
      if (this.disposed) return;
      if (!ok) {
        this.liveViewError = '取景通道未打开：相机可能不在「遥控」模式，或被其它客户端占用';
        this.toast('取景启动失败，可在遥控页继续操作');
        this.log('ui 取景启动被相机拒绝');
        return;
      }
      this.log('ui 取景已启动（预览态）');
    } catch (error) {
      if (this.disposed) return;
      this.liveViewError = `取景启动失败：${this.describe(error)}`;
      this.log(`取景启动失败：${this.describe(error)}`);
      this.toast('取景启动失败，可在遥控页继续操作');
    }
  }

  private stopLiveViewQuietly(): void {
    try {
      CanonControlService.stopLiveView().catch((error: Object): void => {
        this.log(`停止取景失败：${this.describe(error)}`);
      });
    } catch (error) {
      this.log(`停止取景异常：${this.describe(error)}`);
    }
  }

  private onFrame(jpeg: Uint8Array): void {
    if (this.disposed) return;
    // 遥控态不消费帧：即使服务端还在收尾，页面也保持冻结画面。
    if (!this.previewMode) return;
    if (jpeg.byteLength < 2) return;
    if (this.frameBusy) return;
    void this.decodeFrame(jpeg);
  }

  private async decodeFrame(jpeg: Uint8Array): Promise<void> {
    this.frameBusy = true;
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    try {
      // 服务层给的是裸 JPEG；buffer 比视图大时先复制一份，否则
      // createImageSource 会把整块取景缓冲区一起读进来
      //（与 CameraControlPage 的 PTP/IP 解码同法）。
      const buffer: ArrayBuffer = (jpeg.byteOffset === 0 && jpeg.byteLength === jpeg.buffer.byteLength)
        ? jpeg.buffer as ArrayBuffer
        : jpeg.slice().buffer as ArrayBuffer;
      source = image.createImageSource(buffer);
      pixelMap = await source.createPixelMap();
      if (pixelMap !== null) {
        try {
          const size = pixelMap.getImageInfoSync().size;
          if (size.width > 0 && size.height > 0 &&
            (size.width !== this.frameW || size.height !== this.frameH)) {
            this.frameW = size.width;
            this.frameH = size.height;
            this.log(`ui 取景帧 ${this.frameW}x${this.frameH}`);
          }
        } catch (infoError) {
          this.log(`取景帧尺寸读取失败：${this.describe(infoError)}`);
        }
      }
    } catch (error) {
      this.log(`取景帧解码失败：${this.describe(error)}`);
      pixelMap = null;
    } finally {
      if (source !== null) {
        try {
          source.release();
        } catch (releaseError) {
          this.log(`释放 ImageSource 失败：${this.describe(releaseError)}`);
        }
      }
      this.frameBusy = false;
    }
    if (pixelMap === null) return;
    this.publishFrame(pixelMap);
  }

  /** 换帧即释放旧帧：不释放会以帧率的速度泄漏 PixelMap（设计 §0.8 的清理要求）。 */
  private publishFrame(pixelMap: image.PixelMap): void {
    if (this.disposed || !this.previewMode) {
      this.releasePixelMap(pixelMap);
      return;
    }
    const previous = this.framePm;
    this.framePm = pixelMap;
    if (previous !== undefined && previous !== pixelMap) {
      this.releasePixelMap(previous);
    }
  }

  private releasePixelMap(pixelMap: image.PixelMap): void {
    try {
      pixelMap.release();
    } catch (error) {
      this.log(`释放帧失败：${this.describe(error)}`);
    }
  }

  private releaseFrame(): void {
    const previous = this.framePm;
    this.framePm = undefined;
    this.frameW = 0;
    this.frameH = 0;
    if (previous !== undefined) this.releasePixelMap(previous);
  }

  /**
   * 预览 / 遥控切换。
   *
   * 只改本页状态与推流开关：**不重连、不重建服务**（服务在 aboutToAppear 里
   * connect 一次，退出时才 shutdown）。切到遥控立刻 stopLiveView()，画面停在
   * 最后一帧当「冻结画面」用，所以不在这里 releaseFrame()。
   */
  private toggleMode(toPreview: boolean): void {
    if (this.previewMode === toPreview) return;
    this.selectedKey = '';
    this.showCompare = false;
    this.pressHeld = false;
    if (this.bulbHoldTimer >= 0) {
      clearTimeout(this.bulbHoldTimer);
      this.bulbHoldTimer = -1;
    }
    // 正在 B 门曝光时切形态：先把快门松开（param=0），否则曝光会一直持续到
    // 会话被关掉。`pressHeld` 已清空，随后的 onShutterUp 不会再发一次。
    if (this.bulbActive) {
      this.bulbActive = false;
      this.stopBulbTicker();
      void this.endBulb();
    }
    this.previewMode = toPreview;
    if (toPreview) {
      this.log('ui 切到预览：开始推流');
      void this.startLiveView();
    } else {
      // 用户要求：切到遥控立即停止取景（不等异步完成，先把状态切过去）。
      this.stopLiveViewQuietly();
      this.reloadProps();
      this.log('ui 切到遥控：已请求停止推流，画面冻结');
    }
  }

  // -------------------------------------------------------------------------
  // 快门 / 对焦 / 变焦 / 录像
  // -------------------------------------------------------------------------

  /**
   * 预览态快门：按下先 S1 半按（报告 02 §5.1 param=1，带 AF），
   * 松手 S2 全按拍一张；按住超过阈值则按 B 门处理（§5.3【推断】：保持 S2，
   * 松手 param=0 结束曝光）。
   */
  private onShutterDown(): void {
    if (this.disposed || this.pressHeld) return;
    if (!this.isOperational()) {
      this.toast('会话未就绪，无法拍摄');
      return;
    }
    if (this.shooting) return;
    this.pressHeld = true;
    this.halfPressSafely();
    if (this.bulbHoldTimer >= 0) clearTimeout(this.bulbHoldTimer);
    this.bulbHoldTimer = setTimeout((): void => {
      this.bulbHoldTimer = -1;
      if (!this.pressHeld || this.disposed) return;
      this.bulbActive = true;
      this.bulbStartMs = Date.now();
      this.bulbMs = 0;
      this.startBulbTicker();
      this.log(`ui B 门开始：按住 ≥${CANON_BULB_HOLD_MS}ms，保持 S2（报告 02 §5.3）`);
      void this.captureFrame(true);
    }, CANON_BULB_HOLD_MS);
  }

  private onShutterUp(): void {
    if (!this.pressHeld) return;
    this.pressHeld = false;
    if (this.bulbHoldTimer >= 0) {
      clearTimeout(this.bulbHoldTimer);
      this.bulbHoldTimer = -1;
    }
    if (this.bulbActive) {
      this.bulbActive = false;
      this.stopBulbTicker();
      void this.endBulb();
      return;
    }
    void this.captureFrame(true);
  }

  private async endBulb(): Promise<void> {
    const heldMs = this.bulbStartMs > 0 ? Date.now() - this.bulbStartMs : 0;
    this.bulbMs = heldMs;
    this.log(`ui B 门结束 held=${heldMs}ms → param=0（报告 02 §5.3）`);
    try {
      await CanonControlService.release();
      this.toast(`B 门结束 ${(heldMs / 1000).toFixed(1)}s`);
    } catch (error) {
      this.toast(`B 门释放失败：${this.describe(error)}`);
    }
  }

  private startBulbTicker(): void {
    this.stopBulbTicker();
    this.bulbTicker = setInterval((): void => {
      if (this.disposed || !this.bulbActive) {
        this.stopBulbTicker();
        return;
      }
      this.bulbMs = Date.now() - this.bulbStartMs;
    }, 100);
  }

  private stopBulbTicker(): void {
    if (this.bulbTicker >= 0) {
      clearInterval(this.bulbTicker);
      this.bulbTicker = -1;
    }
  }

  private halfPressSafely(): void {
    try {
      CanonControlService.halfPress(true).catch((error: Object): void => {
        this.log(`半按指令失败：${this.describe(error)}`);
      });
    } catch (error) {
      this.log(`半按指令异常：${this.describe(error)}`);
    }
  }

  private releaseQuietly(): void {
    try {
      CanonControlService.release().catch((error: Object): void => {
        this.log(`释放快门失败：${this.describe(error)}`);
      });
    } catch (error) {
      this.log(`释放快门异常：${this.describe(error)}`);
    }
  }

  /**
   * 「半按对焦」按钮：S1 保持 `CANON_HALF_PRESS_MS` 后自动 `release()`。
   * 报告 02 §5.1 的官方时序是「按下 S1/S2 → 松手 param=0」，所以半按必须有结束点，
   * 否则相机会一直停在对焦/测光状态。
   */
  private halfPressPulse(): void {
    if (!this.isOperational() || this.disposed) return;
    this.halfPressSafely();
    if (this.halfReleaseTimer >= 0) clearTimeout(this.halfReleaseTimer);
    this.halfReleaseTimer = setTimeout((): void => {
      this.halfReleaseTimer = -1;
      if (this.disposed) return;
      this.releaseQuietly();
    }, CANON_HALF_PRESS_MS);
  }

  /** 「拍摄」按钮（遥控底栏）与快门短按共用：S2 全按，带 AF。 */
  private async captureFrame(afDrive: boolean): Promise<void> {
    if (!this.isOperational() || this.disposed) return;
    if (this.shooting) return;
    // 半按脉冲的自动 release 不能落在本次曝光中间，否则会提前结束这张照片。
    if (this.halfReleaseTimer >= 0) {
      clearTimeout(this.halfReleaseTimer);
      this.halfReleaseTimer = -1;
    }
    this.shooting = true;
    try {
      const ok: boolean = await CanonControlService.capture(afDrive);
      if (this.disposed) return;
      if (!ok) {
        this.shooting = false;
        this.toast('拍摄未完成：相机拒绝或会话忙（详见 CANON_CTL 日志）');
        return;
      }
      this.scheduleShootingFallback();
    } catch (error) {
      this.shooting = false;
      this.toast(`拍摄失败：${this.describe(error)}`);
    }
  }

  /** 相机事件可能丢失：3 s 后仍未收到完成事件就解除「进行中」，但 B 门期间不解除。 */
  private scheduleShootingFallback(): void {
    if (this.shootTimer >= 0) clearTimeout(this.shootTimer);
    this.shootTimer = setTimeout((): void => {
      this.shootTimer = -1;
      if (this.disposed) return;
      if (this.shooting && !this.bulbActive) {
        this.shooting = false;
        this.log('ui 未收到曝光完成事件，兜底解除进行中标记');
      }
    }, CANON_CAPTURE_FALLBACK_MS);
  }

  private onCaptureEvent(event: CanonCaptureEvent): void {
    if (this.disposed) return;
    if (event.type === 'start') {
      this.shooting = true;
      this.log(`ui 曝光开始 param=${event.param}`);
      return;
    }
    if (event.type === 'complete') {
      this.shooting = false;
      if (this.shootTimer >= 0) {
        clearTimeout(this.shootTimer);
        this.shootTimer = -1;
      }
      if (!this.bulbActive) this.toast('拍摄完成');
      this.log(`ui 曝光完成 param=${event.param}`);
      return;
    }
    this.shooting = false;
    this.toast(`拍摄失败：相机返回 ${this.hex4(event.param)}`);
    this.log(`ui 拍摄错误 param=${this.hex4(event.param)}`);
  }

  /** AF 开/关：报告 02 §5.2 命令 258（`EdsSendCommand(h, 258, 1/0)`）。 */
  private async toggleAf(): Promise<void> {
    if (!this.isOperational()) return;
    const want = !this.afOn;
    try {
      await CanonControlService.af(want);
      if (this.disposed) return;
      this.afOn = want;
      this.toast(want ? 'AF 已开启（命令 258 = 1）' : 'AF 已关闭（命令 258 = 0）');
    } catch (error) {
      this.toast(`AF 指令失败：${this.describe(error)}`);
    }
  }

  /**
   * 点按对焦：把点按位置换算成**取景帧像素坐标**再交给服务
   * （与松下 `sendTouchAf` 同口径：ImageFit.Contain 的缩放与黑边都要扣掉）。
   * 首帧未到时不下发指令，也不猜坐标。
   */
  private tapFocusAt(event: ClickEvent): void {
    if (!this.isOperational() || !this.previewMode || this.disposed) return;
    if (this.frameW <= 0 || this.frameH <= 0) {
      this.toast('首帧还未到，稍后再点按对焦');
      return;
    }
    const viewW = this.previewW > 0 ? this.previewW : 360;
    const viewH = this.previewH > 0 ? this.previewH : 480;
    const scale = Math.min(viewW / this.frameW, viewH / this.frameH);
    const offsetX = (viewW - this.frameW * scale) / 2;
    const offsetY = (viewH - this.frameH * scale) / 2;
    const x = Math.round((event.x - offsetX) / scale);
    const y = Math.round((event.y - offsetY) / scale);
    this.afX = event.x;
    this.afY = event.y;
    this.scheduleAfBoxClear();
    if (x < 0 || y < 0 || x >= this.frameW || y >= this.frameH) {
      // 点在黑边上：只移动 AF 框，不下发对焦（不伪造一次对焦动作）。
      this.afState = '';
      return;
    }
    this.afState = 'pending';
    this.log(`ui 点按对焦 frame=${x},${y}（报告 02 §4 SetLiveAfFrame + DoAf）`);
    void this.runTapFocus(x, y);
  }

  private async runTapFocus(x: number, y: number): Promise<void> {
    try {
      await CanonControlService.tapFocus(x, y);
      if (this.disposed) return;
      this.afState = 'sent';
      this.scheduleAfBoxClear();
    } catch (error) {
      if (this.disposed) return;
      this.afState = 'failed';
      this.toast(`对焦指令失败：${this.describe(error)}`);
    }
  }

  private scheduleAfBoxClear(): void {
    if (this.afTimer >= 0) clearTimeout(this.afTimer);
    this.afTimer = setTimeout((): void => {
      this.afTimer = -1;
      this.afX = -1;
      this.afY = -1;
      this.afState = '';
    }, CANON_AF_BOX_MS);
  }

  /** 变焦：按下发方向 + 速度，松手发「停止」（zoom(0, 0)）。 */
  private async zoomStart(direction: number): Promise<void> {
    if (!this.isOperational()) return;
    try {
      await CanonControlService.zoom(direction, this.currentZoomSpeed());
    } catch (error) {
      this.toast(`变焦失败：${this.describe(error)}`);
    }
  }

  private async zoomStop(): Promise<void> {
    try {
      await CanonControlService.zoom(CANON_ZOOM_STOP, 0);
    } catch (error) {
      this.log(`变焦停止失败：${this.describe(error)}`);
    }
  }

  /** 速度优先用相机上报的 0xD149 当前值；没有就用兜底档（不伪造档位表）。 */
  private currentZoomSpeed(): number {
    const spec: CanonParamSpec | null = this.specOf('zoomSpeed');
    if (spec !== null && spec.value > 0) return spec.value;
    return CANON_DEFAULT_ZOOM_SPEED;
  }

  private async toggleVideo(): Promise<void> {
    if (!this.isOperational()) return;
    const want = !this.recording;
    try {
      const ok: boolean = await CanonControlService.toggleMovie();
      if (this.disposed) return;
      if (!ok) {
        this.toast(want ? '开始录像失败：相机拒绝或不在短片模式' : '停止录像失败：相机拒绝');
        return;
      }
      this.recording = want;
      this.movieMode = this.safeMovieMode();
      this.toast(want ? '开始录像' : '停止录像');
    } catch (error) {
      this.toast(`录像切换失败：${this.describe(error)}`);
    }
  }

  // -------------------------------------------------------------------------
  // 参数面板
  // -------------------------------------------------------------------------

  private openPanel(key: string): void {
    const spec: CanonParamSpec | null = this.specOf(key);
    if (spec === null || !spec.writable) {
      // 铁律：相机没给描述符 / 只读的属性绝不假装可写（设计 §0.5）。
      this.toast('相机未提供该参数');
      return;
    }
    this.selectedKey = key;
    this.log(`ui 打开参数 ${key}` +
      ` EDSDK=${this.hex4(spec.edsPropId)} PTP=${this.hex4(spec.ptpDpc)}`);
  }

  private closePanel(): void {
    this.selectedKey = '';
  }

  private selectedSpec(): CanonParamSpec | null {
    if (this.selectedKey.length === 0) return null;
    return this.specOf(this.selectedKey);
  }

  private optionList(): CanonParamOption[] {
    const spec = this.selectedSpec();
    return spec === null ? [] : spec.options;
  }

  private isSelectedOption(option: CanonParamOption): boolean {
    const spec = this.selectedSpec();
    return spec !== null && spec.value === option.value;
  }

  private async applyOption(option: CanonParamOption): Promise<void> {
    const spec = this.selectedSpec();
    if (spec === null) return;
    if (!spec.writable) {
      this.toast('相机未提供该参数');
      return;
    }
    const key = spec.key;
    try {
      const ok: boolean = await CanonControlService.setParam(key, option.value);
      if (this.disposed) return;
      if (ok) {
        this.toast(`${spec.label} 已设为 ${option.label}`);
        this.reloadProps();
        this.schedulePropRefresh();
      } else {
        this.toast(`${spec.label} 设置失败：相机拒绝该值或会话已降级（详见 CANON_CTL 日志）`);
      }
    } catch (error) {
      this.toast(`${spec.label} 设置失败：${this.describe(error)}`);
    }
  }

  private displayOf(key: string): string {
    const spec: CanonParamSpec | null = this.specOf(key);
    if (spec === null) return '--';
    return spec.display.length > 0 ? spec.display : '--';
  }

  private labelOf(key: string): string {
    const spec: CanonParamSpec | null = this.specOf(key);
    return spec === null ? this.refLabel(key) : spec.label;
  }

  private refLabel(key: string): string {
    for (const ref of CANON_PARAM_REFS) {
      if (ref.key === key) return ref.label;
    }
    return key;
  }

  /** 0xXXXX（大写、补足 4 位）；报告 02 §2 的写法。 */
  private hex4(value: number): string {
    let text = (value >>> 0).toString(16).toUpperCase();
    while (text.length < 4) text = '0' + text;
    return '0x' + text;
  }

  /** 对照抽屉 14 行：相机上报过的用真值，没上报的退回报告 02 §2 的静态值。 */
  private compareRows(): CanonCompareRow[] {
    const rows: CanonCompareRow[] = [];
    for (const ref of CANON_PARAM_REFS) {
      const spec: CanonParamSpec | null = this.specOf(ref.key);
      if (spec === null) {
        rows.push({
          key: ref.key,
          label: ref.label,
          edsText: this.hex4(ref.edsPropId),
          ptpText: this.hex4(ref.ptpDpc),
          valueText: '相机未提供',
          writableText: '否',
          writable: false,
          available: false,
        });
      } else {
        rows.push({
          key: ref.key,
          label: spec.label.length > 0 ? spec.label : ref.label,
          edsText: this.hex4(spec.edsPropId),
          ptpText: this.hex4(spec.ptpDpc),
          valueText: spec.display.length > 0 ? spec.display : '--',
          writableText: spec.writable ? '可写' : '只读',
          writable: spec.writable,
          available: true,
        });
      }
    }
    return rows;
  }

  // -------------------------------------------------------------------------
  // 退出与清理
  // -------------------------------------------------------------------------

  private exitPage(): void {
    if (this.leaving) return;
    this.leaving = true;
    // 顺序按设计 §7.1：先停取景再关会话，最后才返回。
    this.teardown();
    this.log('ui 退出：已停取景，正在关闭会话');
    void Promise.race([this.shutdownSafely(), this.delay(2500)])
      .then((): void => {
        this.backToPrevious();
      })
      .catch((error: Object): void => {
        this.log(`退出时关闭会话失败：${this.describe(error)}`);
        this.backToPrevious();
      });
  }

  private teardown(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.stopLiveViewQuietly();
    this.releaseFrame();
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    if (this.afTimer >= 0) {
      clearTimeout(this.afTimer);
      this.afTimer = -1;
    }
    if (this.bulbHoldTimer >= 0) {
      clearTimeout(this.bulbHoldTimer);
      this.bulbHoldTimer = -1;
    }
    if (this.shootTimer >= 0) {
      clearTimeout(this.shootTimer);
      this.shootTimer = -1;
    }
    if (this.halfReleaseTimer >= 0) {
      clearTimeout(this.halfReleaseTimer);
      this.halfReleaseTimer = -1;
    }
    this.stopBulbTicker();
    this.bulbActive = false;
    this.pressHeld = false;
    this.log('ui 清理：取景已停 / 帧已释放 / 定时器全清');
  }

  /** 关会话：同步异常与异步拒绝都在内部消化，调用方不再依赖它的结果。 */
  private shutdownSafely(): Promise<void> {
    try {
      return CanonControlService.shutdown().catch((error: Object): void => {
        this.log(`关闭会话失败：${this.describe(error)}`);
      });
    } catch (error) {
      this.log(`关闭会话异常：${this.describe(error)}`);
      return this.delay(0);
    }
  }

  private backToPrevious(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.log(`返回上级失败：${this.describe(error)}`);
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
      this.log(`提示失败：${this.describe(error)}`);
    }
  }

  private explain(error: Object): string {
    const message = this.describe(error);
    const lower = message.toLowerCase();
    if (lower.indexOf('econnrefused') >= 0 || lower.indexOf('connect') >= 0 ||
      lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0 ||
      lower.indexOf('socket closed') >= 0 ||
      message.indexOf('连接') >= 0 || message.indexOf('未建立') >= 0) {
      return '无法连接相机（PTP-IP 15740）。请先在系统 Wi-Fi 里连上相机热点，' +
        '确认相机处于「遥控」模式，然后点「重试」。原始信息：' + message;
    }
    return `连接失败：${message}`;
  }

  /** 日志：日志通道自身异常时只能咽下（再打日志会递归），其余服务调用都有保护。 */
  private log(message: string): void {
    try {
      CanonControlService.log(message);
    } catch (_error) {
      // 无路可退：日志失败不影响任何用户可见行为。
    }
  }

  private describe(error: Object): string {
    if (error instanceof Error) return error.message;
    return String(error);
  }

  private isOperational(): boolean {
    return this.phase === 'ready' || this.phase === 'degraded';
  }

  private connectColor(): string {
    if (this.phase === 'ready') return '#34D399';
    if (this.phase === 'degraded') return '#F59E0B';
    if (this.phase === 'error') return '#E5484D';
    return '#8A97AB';
  }

  private connectText(): string {
    if (this.phase === 'ready') return '已就绪';
    if (this.phase === 'degraded') return '降级';
    if (this.phase === 'error') return '未连接';
    return '连接中';
  }

  /** 页面上唯一的状态原因串：取景失败 > 参数降级 > 连接状态。 */
  private statusLine(): string {
    if (this.liveViewError.length > 0) return this.liveViewError;
    if (this.degradedReason.length > 0) return `参数降级：${this.degradedReason}`;
    return this.statusText;
  }

  private framePlaceholder(): string {
    if (this.phase === 'connecting') return '正在连接相机…';
    if (this.phase === 'degraded') return '等待取景画面（参数降级，画面仍可尝试）';
    return '等待相机画面…';
  }

  private afLabel(): string {
    if (this.afState === 'sent') return 'AF 已发送';
    if (this.afState === 'failed') return 'AF 失败';
    if (this.afState === 'pending') return 'AF 对焦中';
    return 'AF';
  }

  private shutterFill(): string {
    if (this.bulbActive) return '#E5484D';
    return this.shooting ? '#7EA6F5' : '#2563EB';
  }

  private subLine(): string {
    const parts: string[] = [];
    if (this.serial.length > 0) parts.push(`S/N ${this.serial}`);
    if (this.firmware.length > 0) parts.push(`固件 ${this.firmware}`);
    if (parts.length === 0) return 'PTP-IP · 15740';
    return parts.join(' · ');
  }

  private gridHeight(): number {
    const rows = Math.ceil(this.props.length / 2);
    return Math.max(64, rows * 64);
  }

  private sheetTitle(): string {
    const spec = this.selectedSpec();
    return spec === null ? '' : spec.label;
  }

  private sheetMeta(): string {
    const spec = this.selectedSpec();
    if (spec === null) return '';
    const mode = spec.writable ? '可写' : '只读';
    return `EDSDK ${this.hex4(spec.edsPropId)} · PTP ${this.hex4(spec.ptpDpc)} · ${mode}`;
  }

  private tryLiveViewAnyway(): void {
    if (this.phase === 'error') this.phase = 'degraded';
    this.previewMode = true;
    this.log('ui 用户选择直接尝试取景');
    void this.startLiveView();
  }

  // ---- 共享卡片材质（只含通用属性，@Styles 的约束就是这个） ---------------

  @Styles
  cardSurface() {
    .backgroundColor('#0FFFFFFF')
    .borderRadius(16)
    .border({ width: 1, color: '#1FFFFFFF' })
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (!this.valid) {
        this.fatalScreen('页面与机型线不匹配',
          `当前会话是 ${CameraSessionStore.instance.cameraBrand}，本页只接受佳能（${CanonModels.BRAND}）。` +
            '请返回相机页，从佳能卡片的「相机控制」入口进入。', false);
      } else if (this.phase === 'error') {
        this.fatalScreen('连接未建立', this.statusText, true);
      } else if (this.previewMode) {
        this.previewScreen();
      } else {
        this.remoteScreen();
      }
      if (this.selectedKey.length > 0) {
        this.paramSheet();
      }
      if (this.showCompare) {
        this.compareSheet();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1017')
  }

  @Builder
  private fatalScreen(title: string, detail: string, showRetry: boolean) {
    Column({ space: 12 }) {
      Text(title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF');
      Text(detail)
        .fontSize(12)
        .fontColor('#9AA8BD')
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 });
      Row({ space: 10 }) {
        if (showRetry) {
          Button('重试')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .height(44)
            .layoutWeight(1)
            .backgroundColor('#2563EB')
            .onClick((): void => {
              this.retryConnect();
            });
          Button('尝试取景')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .height(44)
            .layoutWeight(1)
            .backgroundColor('#1F2A44')
            .onClick((): void => {
              this.tryLiveViewAnyway();
            });
        }
        Button('返回')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .height(44)
          .layoutWeight(1)
          .backgroundColor('#232833')
          .onClick((): void => {
            this.exitPage();
          });
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 6 });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#0B1017');
  }

  // ---- 预览形态 -----------------------------------------------------------

  @Builder
  private previewScreen() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.framePm !== undefined) {
        Image(this.framePm)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .backgroundColor('#000000')
          .onAreaChange((_oldArea: Area, newArea: Area): void => {
            this.previewW = Number(newArea.width);
            this.previewH = Number(newArea.height);
          })
          .onClick((event: ClickEvent): void => {
            this.tapFocusAt(event);
          });
      } else {
        Column({ space: 10 }) {
          if (this.phase === 'connecting' || this.phase === 'idle') {
            LoadingProgress()
              .width(36)
              .height(36)
              .color('#FFFFFF');
          }
          Text(this.framePlaceholder())
            .fontSize(13)
            .fontColor('#C7D0DE')
            .textAlign(TextAlign.Center);
          if (this.statusLine().length > 0) {
            Text(this.statusLine())
              .fontSize(11)
              .fontColor('#8A97AB')
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 });
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#000000');
      }

      // AF 框：位置来自点按，颜色/文案来自对焦指令的真实结果（不假装已合焦）。
      if (this.afX >= 0) {
        Column()
          .width(64)
          .height(64)
          .border({ width: 2, color: this.afState === 'sent' ? '#34D399' : '#FFFFFF' })
          .borderRadius(6)
          .position({ x: this.afX - 32, y: this.afY - 32 });
        Text(this.afLabel())
          .fontSize(9)
          .fontColor(this.afState === 'failed' ? '#E5484D' : '#FFFFFF')
          .backgroundColor('#99000000')
          .borderRadius(4)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .position({ x: this.afX - 20, y: this.afY + 36 });
      }

      Column() {
        this.previewTopBar();
        Blank();
        this.previewChips();
        this.previewBottomBar();
      }
      .width('100%')
      .height('100%')
      .padding({ top: 26, bottom: 22 })
      .hitTestBehavior(HitTestMode.Transparent);
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000');
  }

  @Builder
  private previewTopBar() {
    Row({ space: 8 }) {
      Text('‹')
        .fontSize(28)
        .fontColor('#FFFFFF')
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .onClick((): void => {
          this.exitPage();
        });
      Column({ space: 1 }) {
        Text('相机控制')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF');
        Text(this.model.length > 0 ? this.model : 'Canon')
          .fontSize(10)
          .fontColor('#C7D0DE')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .alignItems(HorizontalAlign.Start);
      Blank();
      this.compareButton();
      this.modeToggle();
    }
    .width('100%')
    .height(52)
    .padding({ left: 10, right: 10 })
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  private compareButton() {
    Text('参数对照')
      .fontSize(11)
      .fontColor('#C7D0DE')
      .padding({ left: 9, right: 9, top: 6, bottom: 6 })
      .backgroundColor('#1FFFFFFF')
      .borderRadius(12)
      .onClick((): void => {
        this.reloadProps();
        this.showCompare = true;
      });
  }

  @Builder
  private modeToggle() {
    Row() {
      Text('预览')
        .fontSize(11)
        .fontWeight(this.previewMode ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.previewMode ? '#FFFFFF' : '#8A97AB')
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(this.previewMode ? '#2563EB' : Color.Transparent)
        .borderRadius(11)
        .onClick((): void => {
          this.toggleMode(true);
        });
      Text('遥控')
        .fontSize(11)
        .fontWeight(this.previewMode ? FontWeight.Normal : FontWeight.Medium)
        .fontColor(this.previewMode ? '#8A97AB' : '#FFFFFF')
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(this.previewMode ? Color.Transparent : '#2563EB')
        .borderRadius(11)
        .onClick((): void => {
          this.toggleMode(false);
        });
    }
    .backgroundColor('#1FFFFFFF')
    .borderRadius(14)
    .padding(2);
  }

  @Builder
  private previewChips() {
    Scroll() {
      Row({ space: 8 }) {
        this.readonlyChip('光圈', 'aperture');
        this.readonlyChip('快门', 'shutter');
        this.readonlyChip('ISO', 'iso');
        this.readonlyChip('EV', 'ev');
        this.readonlyChip('白平衡', 'wb');
      }
      .padding({ left: 12, right: 12 });
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ bottom: 10 });
  }

  @Builder
  private readonlyChip(label: string, key: string) {
    Row({ space: 5 }) {
      Text(label)
        .fontSize(10)
        .fontColor('#C7D0DE');
      Text(this.displayOf(key))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .maxLines(1);
    }
    .backgroundColor('#66000000')
    .borderRadius(12)
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .onClick((): void => {
      this.toast('预览态参数只读，切到「遥控」可调');
    });
  }

  @Builder
  private previewBottomBar() {
    Row({ space: 22 }) {
      Column({ space: 4 }) {
        Circle()
          .width(44)
          .height(44)
          .fill(this.recording ? '#E5484D' : '#661A1E27')
          .stroke('#E5484D')
          .strokeWidth(2);
        Text(this.recording ? '停止' : '录像')
          .fontSize(10)
          .fontColor('#FFFFFF');
      }
      .onClick((): void => {
        void this.toggleVideo();
      });

      Column({ space: 4 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(76)
            .height(76)
            .fill('#FFFFFF');
          Circle()
            .width(62)
            .height(62)
            .fill(this.shutterFill());
          Text(this.bulbActive ? (this.bulbMs / 1000).toFixed(1) : (this.shooting ? '…' : ''))
            .fontSize(15)
            .fontColor('#FFFFFF');
        }
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.onShutterDown();
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.onShutterUp();
          }
        });
        Text(this.bulbActive ? 'B 门曝光中 · 松手结束' : '半按对焦 · 松手拍摄 · 长按 B 门')
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor('#66000000')
          .borderRadius(8)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
      }

      Column({ space: 4 }) {
        Circle()
          .width(44)
          .height(44)
          .fill(this.afOn ? '#2563EB' : '#661A1E27')
          .stroke('#FFFFFF')
          .strokeWidth(1);
        Text(this.afOn ? 'AF 开' : 'AF 关')
          .fontSize(10)
          .fontColor('#FFFFFF');
      }
      .onClick((): void => {
        void this.toggleAf();
      });
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 10 });
  }

  // ---- 遥控形态 -----------------------------------------------------------

  @Builder
  private remoteScreen() {
    Column() {
      this.topBar();
      this.identityRow();
      Scroll() {
        Column({ space: 10 }) {
          this.quickChips();
          this.remoteFinder();
          if (this.degradedReason.length > 0) {
            this.banner(`参数降级：${this.degradedReason}。置灰项表示「相机未提供该参数」，本页不伪造可写`,
              '#F59E0B');
          }
          if (this.liveViewError.length > 0) {
            this.banner(this.liveViewError, '#E5484D');
          }
          if (this.degradedReason.length === 0 && this.liveViewError.length === 0 &&
            this.statusText.length > 0) {
            this.banner(this.statusText, '#8A97AB');
          }
          this.paramGrid();
          this.footNote();
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 10 });
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off);
      this.remoteBottomBar();
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1017');
  }

  @Builder
  private topBar() {
    Row({ space: 8 }) {
      Text('‹')
        .fontSize(28)
        .fontColor('#FFFFFF')
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .onClick((): void => {
          this.exitPage();
        });
      Text('相机控制')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF');
      Blank();
      this.compareButton();
      this.modeToggle();
    }
    .width('100%')
    .height(56)
    .padding({ left: 10, right: 10 })
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  private identityRow() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(this.model.length > 0 ? this.model : 'Canon')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Row({ space: 3 }) {
            Circle()
              .width(6)
              .height(6)
              .fill(this.connectColor());
            Text(this.connectText())
              .fontSize(9)
              .fontColor('#8A97AB');
          }
          .alignItems(VerticalAlign.Center);
        }
        .alignItems(VerticalAlign.Center);
        Text(this.subLine())
          .fontSize(10)
          .fontColor('#8A97AB')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
      Text(this.props.length > 0 ? `参数 ${this.props.length} 项` : '参数不可用')
        .fontSize(10)
        .fontColor(this.props.length > 0 ? '#34D399' : '#F59E0B')
        .backgroundColor('#1FFFFFFF')
        .borderRadius(10)
        .padding({ left: 8, right: 8, top: 4, bottom: 4 });
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 2, bottom: 8 });
  }

  @Builder
  private quickChips() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(CANON_QUICK_KEYS, (key: string) => {
          this.quickChip(key);
        }, (key: string): string => key);
      }
      .padding({ left: 2, right: 2 });
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%');
  }

  @Builder
  private quickChip(key: string) {
    Row({ space: 5 }) {
      Text(this.labelOf(key))
        .fontSize(10)
        .fontColor('#8A97AB');
      Text(this.displayOf(key))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.specOf(key) !== null ? '#FFFFFF' : '#5A6373')
        .maxLines(1);
    }
    .backgroundColor('#0FFFFFFF')
    .borderRadius(12)
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .opacity(this.specOf(key) !== null ? 1 : 0.55)
    .onClick((): void => {
      this.openPanel(key);
    });
  }

  @Builder
  private remoteFinder() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.framePm !== undefined) {
        Image(this.framePm)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .opacity(0.62);
      } else {
        Column({ space: 6 }) {
          Text('遥控模式')
            .fontSize(14)
            .fontColor('#FFFFFF');
          Text('切到「预览」查看实时画面')
            .fontSize(11)
            .fontColor('#8A97AB');
        }
        .justifyContent(FlexAlign.Center);
      }
      Row({ space: 6 }) {
        Circle()
          .width(6)
          .height(6)
          .fill('#F59E0B');
        Text('冻结画面 · 不推流')
          .fontSize(10)
          .fontColor('#FFFFFF');
      }
      .backgroundColor('#99000000')
      .borderRadius(10)
      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      .position({ x: 8, y: 8 });
    }
    .width('100%')
    .height(180)
    .backgroundColor('#000000')
    .borderRadius(16)
    .clip(true);
  }

  @Builder
  private banner(text: string, color: string) {
    Row({ space: 6 }) {
      Text('!')
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor('#0B1017')
        .width(16)
        .height(16)
        .textAlign(TextAlign.Center)
        .backgroundColor(color)
        .borderRadius(8);
      Text(text)
        .fontSize(11)
        .fontColor('#E6ECF5')
        .layoutWeight(1)
        .maxLines(3);
    }
    .width('100%')
    .backgroundColor('#0FFFFFFF')
    .borderRadius(16)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 });
  }

  @Builder
  private paramGrid() {
    Column({ space: 8 }) {
      Row() {
        Text('拍摄参数')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF');
        Blank();
        Text(`${this.props.length} 项`)
          .fontSize(10)
          .fontColor('#8A97AB');
        Text('刷新')
          .fontSize(11)
          .fontColor('#2563EB')
          .margin({ left: 12 })
          .onClick((): void => {
            void this.refreshProps(true);
          });
      }
      .width('100%');

      if (this.props.length === 0) {
        Text(this.propsReady
          ? '相机返回的描述符为空：没有可显示的参数'
          : '相机未返回属性描述符，参数网格为空（取景与拍摄仍可尝试）')
          .fontSize(11)
          .fontColor('#8A97AB')
          .width('100%')
          .padding({ top: 8, bottom: 8 });
      } else {
        Grid() {
          ForEach(this.props, (spec: CanonParamSpec) => {
            GridItem() {
              this.paramTile(spec);
            }
          }, (spec: CanonParamSpec): string => spec.key);
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(8)
        .rowsGap(8)
        .width('100%')
        .height(this.gridHeight());
      }
    }
    .width('100%')
    .padding(10)
    .cardSurface();
  }

  @Builder
  private paramTile(spec: CanonParamSpec) {
    Column({ space: 3 }) {
      Row({ space: 4 }) {
        Text(spec.label)
          .fontSize(10)
          .fontColor('#8A97AB')
          .layoutWeight(1)
          .maxLines(1);
        if (!spec.writable) {
          Text('只读')
            .fontSize(9)
            .fontColor('#5A6373');
        }
      }
      .width('100%');
      Text(spec.display.length > 0 ? spec.display : '--')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(spec.writable ? '#FFFFFF' : '#5A6373')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
    }
    .width('100%')
    .height(56)
    .padding({ left: 9, right: 9, top: 6, bottom: 6 })
    .backgroundColor('#0AFFFFFF')
    .borderRadius(12)
    .border({ width: 1, color: '#14FFFFFF' })
    .opacity(spec.writable ? 1 : 0.55)
    .onClick((): void => {
      this.openPanel(spec.key);
    });
  }

  @Builder
  private footNote() {
    Column({ space: 3 }) {
      Text('参数来源：相机 GetPropertyDesc 与属性变化事件 0xC18A；没有描述的项不会显示成可写。')
        .fontSize(10)
        .fontColor('#5F6B7F')
        .width('100%');
      Text('点顶栏「参数对照」可逐条核对报告 02 §2 的 EDSDK 属性 ID 与 PTP DPC。')
        .fontSize(10)
        .fontColor('#5F6B7F')
        .width('100%');
    }
    .width('100%')
    .padding({ left: 2, right: 2, top: 2 });
  }

  @Builder
  private remoteBottomBar() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.afOn ? 'AF 开' : 'AF 关')
          .fontSize(11)
          .fontColor(this.afOn ? '#FFFFFF' : '#C7D0DE')
          .backgroundColor(this.afOn ? '#2563EB' : '#1FFFFFFF')
          .borderRadius(11)
          .padding({ left: 11, right: 11, top: 6, bottom: 6 })
          .onClick((): void => {
            void this.toggleAf();
          });
        Text('半按对焦')
          .fontSize(11)
          .fontColor('#C7D0DE')
          .backgroundColor('#1FFFFFFF')
          .borderRadius(11)
          .padding({ left: 11, right: 11, top: 6, bottom: 6 })
          .onClick((): void => {
            this.halfPressPulse();
          });
        Text(this.recording ? '停止录像' : '开始录像')
          .fontSize(11)
          .fontColor(this.recording ? '#FFFFFF' : '#C7D0DE')
          .backgroundColor(this.recording ? '#B33B3F' : '#1FFFFFFF')
          .borderRadius(11)
          .padding({ left: 11, right: 11, top: 6, bottom: 6 })
          .onClick((): void => {
            void this.toggleVideo();
          });
        Blank();
        Text(this.movieMode ? '短片模式' : '拍照模式')
          .fontSize(10)
          .fontColor('#8A97AB');
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Row({ space: 14 }) {
        this.zoomButton('−', CANON_ZOOM_WIDE);
        Button(this.shooting ? '拍摄中…' : '拍摄')
          .fontSize(15)
          .fontColor('#FFFFFF')
          .height(56)
          .layoutWeight(1)
          .backgroundColor(this.shooting ? '#7EA6F5' : '#2563EB')
          .borderRadius(18)
          .enabled(!this.shooting)
          .onClick((): void => {
            void this.captureFrame(true);
          });
        this.zoomButton('+', CANON_ZOOM_TELE);
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 10 })
    .backgroundColor('#0AFFFFFF');
  }

  @Builder
  private zoomButton(label: string, direction: number) {
    Stack({ alignContent: Alignment.Center }) {
      Circle()
        .width(52)
        .height(52)
        .fill('#1FFFFFFF')
        .stroke('#26FFFFFF')
        .strokeWidth(1);
      Text(label)
        .fontSize(24)
        .fontColor('#FFFFFF');
    }
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        void this.zoomStart(direction);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        void this.zoomStop();
      }
    });
  }

  // ---- 参数选项面板 -------------------------------------------------------

  @Builder
  private paramSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick((): void => {
          this.closePanel();
        });
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(this.sheetTitle())
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF');
            Text(this.sheetMeta())
              .fontSize(10)
              .fontColor('#8A97AB');
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);
          Text('关闭')
            .fontSize(12)
            .fontColor('#8A97AB')
            .onClick((): void => {
              this.closePanel();
            });
        }
        .width('100%');

        if (this.optionList().length > 0) {
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.optionList(), (option: CanonParamOption) => {
                this.optionRow(option);
              }, (option: CanonParamOption): string => `${this.selectedKey}-${option.value}`);
            }
            .width('100%');
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off);
        } else {
          Text(`相机未上报该参数的候选值；当前值 ${this.displayOf(this.selectedKey)}`)
            .fontSize(12)
            .fontColor('#8A97AB')
            .width('100%')
            .padding({ top: 12, bottom: 12 });
        }
      }
      .width('100%')
      .height('62%')
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor('#12161F')
      .borderRadius({ topLeft: 20, topRight: 20 });
    }
    .width('100%')
    .height('100%')
    .zIndex(20);
  }

  @Builder
  private optionRow(option: CanonParamOption) {
    Row() {
      Text(option.label)
        .fontSize(14)
        .fontWeight(this.isSelectedOption(option) ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.isSelectedOption(option) ? '#2563EB' : '#FFFFFF')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      Text(`${this.hex4(option.value)}`)
        .fontSize(9)
        .fontColor('#5F6B7F')
        .margin({ right: 8 });
      if (this.isSelectedOption(option)) {
        Text('✓')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#2563EB');
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .backgroundColor(this.isSelectedOption(option) ? '#14233F' : '#1FFFFFFF')
    .borderRadius(12)
    .onClick((): void => {
      void this.applyOption(option);
    });
  }

  // ---- 参数对照抽屉 -------------------------------------------------------

  @Builder
  private compareSheet() {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 2 }) {
          Text('参数对照')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF');
          Text('报告 02 §2 · EDSDK propId / PTP DPC 逐条核对')
            .fontSize(10)
            .fontColor('#8A97AB');
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Text('关闭')
          .fontSize(12)
          .fontColor('#8A97AB')
          .onClick((): void => {
            this.showCompare = false;
          });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 6 });

      Row({ space: 4 }) {
        Text('中文')
          .fontSize(9)
          .fontColor('#5F6B7F')
          .layoutWeight(1.3);
        Text('EDSDK')
          .fontSize(9)
          .fontColor('#5F6B7F')
          .layoutWeight(1.1);
        Text('PTP')
          .fontSize(9)
          .fontColor('#5F6B7F')
          .layoutWeight(1.1);
        Text('当前值')
          .fontSize(9)
          .fontColor('#5F6B7F')
          .layoutWeight(1.6);
        Text('可写')
          .fontSize(9)
          .fontColor('#5F6B7F')
          .layoutWeight(0.7)
          .textAlign(TextAlign.End);
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 2 });

      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.compareRows(), (row: CanonCompareRow) => {
            this.compareRowItem(row);
          }, (row: CanonCompareRow): string => row.key);
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 });
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off);
    }
    .width('100%')
    .height('86%')
    .backgroundColor('#12161F')
    .borderRadius({ topLeft: 20, topRight: 20 })
    .zIndex(30);
  }

  @Builder
  private compareRowItem(row: CanonCompareRow) {
    Row({ space: 4 }) {
      Text(row.label)
        .fontSize(11)
        .fontColor(row.available ? '#FFFFFF' : '#5A6373')
        .layoutWeight(1.3)
        .maxLines(1);
      Text(row.edsText)
        .fontSize(9)
        .fontColor(row.available ? '#93A3BD' : '#4A5568')
        .layoutWeight(1.1)
        .maxLines(1);
      Text(row.ptpText)
        .fontSize(9)
        .fontColor(row.available ? '#93A3BD' : '#4A5568')
        .layoutWeight(1.1)
        .maxLines(1);
      Text(row.valueText)
        .fontSize(11)
        .fontColor(row.available ? '#C7D0DE' : '#4A5568')
        .layoutWeight(1.6)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      Text(row.writableText)
        .fontSize(10)
        .fontColor(row.writable ? '#34D399' : '#5A6373')
        .layoutWeight(0.7)
        .textAlign(TextAlign.End)
        .maxLines(1);
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .backgroundColor('#0FFFFFFF')
    .borderRadius(12)
    .opacity(row.available ? 1 : 0.6)
    .onClick((): void => {
      if (!row.available || !row.writable) {
        this.toast('相机未提供该参数');
        return;
      }
      this.showCompare = false;
      this.openPanel(row.key);
    });
  }
}
