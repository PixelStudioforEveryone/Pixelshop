/**
 * 佳能 EOS 相机控制服务：属性读写、实时取景、快门/AF/变焦、事件泵。
 *
 * 报文序列严格按 `report 02 §7`：
 *   OpenSession → 机型/固件/产品名 → 参数当前值（事件 0xC189 驱动）
 *   → 选项列表（事件 0xC18A 驱动）→ StartEvf → 循环取帧 → 用户操作。
 *
 * 诚实的降级：
 *  - 相机不给描述符/列表的参数，`writable=false`、`options=[]`，页面置灰；
 *  - `toggleMovie()` 在 PTP 上没有证据（报告 02 §6 的录像指令只存在于 BLE
 *    遥控服务 00030030），这里明确返回 false 并给出提示，绝不假装成功；
 *  - 快门 5 个 param 与 RemoteReleaseOn(switch, action) 的映射是「报告 param
 *    表 + DS_RemoteReleaseOn 签名」的推导（契约 §4.2），日志里会打印实际值。
 */
import { AppLogSink } from './AppLogSink';
import { CameraSessionStore } from './CameraSessionStore';
import { CanonBytes, CanonEosOp, CanonPtpDataReply, CanonPtpError, CanonPtpIp,
  CanonPtpResponse } from './CanonPtpIp';
import { CanonFormat, CanonParamOption, CanonParamSpec, CanonPropCatalog, CanonPropDef,
  CanonPropLabels } from './CanonProperties';
import { LumixCameraService } from './LumixCameraService';

// 页面从本文件单点 import 这两个类型（契约 §4.2）。
export { CanonParamOption, CanonParamSpec };

const TAG: string = 'CANON_CTL';
/** 参数写入去抖：报告 02 §3.3 的 500 ms。 */
const WRITE_DEBOUNCE_MS: number = 500;
/** 事件泵间隔：EOS 的 GetEvent 是轮询式，太快会挤占取景事务。 */
const EVENT_POLL_MS: number = 400;
/** 取景无新帧时的等待（报告 02 §4：相机以「空帧」自然限速）。 */
const LIVEVIEW_IDLE_MS: number = 60;
/** 取景连续失败多少次后停流。 */
const LIVEVIEW_MAX_FAILURES: number = 5;
/** 快门全按后保持多久自动释放（B 门由页面长按控制）。 */
const CAPTURE_HOLD_MS: number = 220;
/** 取景输出设备位（报告 02 §4：flag=2 普通 / 8 特殊）。 */
const EVF_FLAG_NORMAL: number = 2;

export interface CanonControlSnapshot {
  model: string;
  firmware: string;
  productName: string;
  serial: string;
  propsReady: boolean;
  propCount: number;
  degradedReason: string;
  driveMode: number;
  evfOutputDevice: number;
}

export interface CanonCaptureEvent {
  /** 'start' | 'complete' | 'error' */
  type: string;
  /** error 时是 PTP 码，其它情况是 0。 */
  param: number;
}

export interface CanonControlCallbacks {
  onLiveViewFrame?: (jpeg: Uint8Array) => void;
  onCapture?: (event: CanonCaptureEvent) => void;
  onPropChanged?: (key: string, value: number) => void;
  onDeviceChanged?: () => void;
  onNotice?: (message: string) => void;
}

interface CanonPropState {
  def: CanonPropDef;
  value: number;
  options: CanonParamOption[];
  writable: boolean;
  /** true = 选项是本地生成的连续量候选，不是相机给的。 */
  inferred: boolean;
}

interface CanonDescResult {
  writable: boolean;
  options: CanonParamOption[];
}

export class CanonControlService {
  private static props: Map<string, CanonPropState> = new Map<string, CanonPropState>();
  /** 参数显示顺序（Map 的迭代顺序在 ArkTS 里不保证，单独记一份）。 */
  private static order: string[] = [];
  private static callbacks: CanonControlCallbacks = {};
  private static snapshot: CanonControlSnapshot = {
    model: '', firmware: '', productName: '', serial: '',
    propsReady: false, propCount: 0, degradedReason: '', driveMode: 0, evfOutputDevice: 0,
  };
  private static eventTimer: number = -1;
  private static liveViewToken: number = 0;
  private static liveViewActive: boolean = false;
  private static liveViewFailures: number = 0;
  private static writeTimers: Map<string, number> = new Map<string, number>();
  private static pendingValues: Map<string, number> = new Map<string, number>();
  private static connected: boolean = false;

  static log(message: string): Promise<void> {
    AppLogSink.emit(TAG, message);
    return Promise.resolve();
  }

  static setCallbacks(callbacks: CanonControlCallbacks): void {
    CanonControlService.callbacks = callbacks;
  }

  static getProps(): CanonParamSpec[] {
    const out: CanonParamSpec[] = [];
    for (const key of CanonControlService.order) {
      const spec = CanonControlService.propOf(key);
      if (spec !== null) out.push(spec);
    }
    return out;
  }

  static propOf(key: string): CanonParamSpec | null {
    const state = CanonControlService.props.get(key);
    if (state === undefined) return null;
    return {
      key: state.def.key,
      panel: state.def.panel,
      label: state.def.label,
      edsPropId: state.def.edsPropId,
      ptpDpc: state.def.ptpDpc,
      value: state.value,
      display: CanonFormat.display(state.def, state.value, state.options),
      options: state.options,
      writable: state.writable,
      group: state.def.group,
    };
  }

  static isConnected(): boolean {
    return CanonControlService.connected;
  }

  static snapshotValue(): CanonControlSnapshot {
    return CanonControlService.snapshot;
  }

  /**
   * 连接相机并建立参数表。失败时抛 Error（页面显示原因）；
   * 部分参数读不到只降级，不抛。
   */
  static async connect(model: string): Promise<CanonControlSnapshot> {
    const host: string = await CanonControlService.resolveHost();
    if (host.length === 0) throw new Error('没有相机地址，请先在识别页建立 Wi‑Fi 会话');
    if (!CanonPtpIp.isOpen()) {
      await CanonPtpIp.connect(host, 'VIVID');
    }
    const store: CameraSessionStore = CameraSessionStore.instance;
    const productName: string = await CanonControlService.readPropertyString(2);
    const firmware: string = await CanonControlService.readPropertyString(7);
    const serial: string = await CanonControlService.readPropertyString(96);
    const displayModel: string = productName.length > 0 ? productName
      : (store.cameraModel.length > 0 ? store.cameraModel : model);
    CanonControlService.props.clear();
    CanonControlService.order = [];
    let available = 0;
    let writable = 0;
    for (const def of CanonPropCatalog.DEFS) {
      const state = await CanonControlService.loadProp(def);
      if (state === null) continue;
      CanonControlService.props.set(def.key, state);
      CanonControlService.order.push(def.key);
      available += 1;
      if (state.writable) writable += 1;
    }
    const drive = CanonControlService.props.get('drive');
    const lvOutput = CanonControlService.props.get('lvOutput');
    CanonControlService.snapshot = {
      model: displayModel,
      firmware: firmware,
      productName: productName,
      serial: serial,
      propsReady: available > 0,
      propCount: available,
      degradedReason: available === 0 ? '相机没有返回任何可读参数（可能未进入遥控模式）'
        : (writable === 0 ? '相机未提供可写参数，控制页只读' : ''),
      driveMode: drive === undefined ? 0 : drive.value,
      evfOutputDevice: lvOutput === undefined ? 0 : lvOutput.value,
    };
    CanonControlService.connected = true;
    CanonControlService.startEventPump();
    CanonControlService.log(`参数就绪 ${available} 项（可写 ${writable}）model=${displayModel} fw=${firmware}`);
    return CanonControlService.snapshot;
  }

  private static async resolveHost(): Promise<string> {
    const stored: string = AppStorage.get<string>('canonHost') ?? '';
    if (stored.length > 0) return stored;
    try {
      return await LumixCameraService.linkedGateway();
    } catch (_error) {
      return '';
    }
  }

  /** 读一个属性：当前值 + （尽量）描述符/列表。读不到返回 null。 */
  private static async loadProp(def: CanonPropDef): Promise<CanonPropState | null> {
    let value = 0;
    let readOk = false;
    try {
      const data = await CanonPtpIp.getDevicePropValue(def.ptpDpc);
      value = def.kind === 'i32' || def.kind === 'ev8'
        ? CanonFormat.readI32(data) : CanonFormat.readU32(data);
      readOk = data.length > 0;
    } catch (_error) {
      readOk = false;
    }
    if (!readOk) return null;
    let options: CanonParamOption[] = [];
    let writable = def.writableHint;
    let inferred = false;
    const desc = await CanonControlService.readPropDesc(def);
    if (desc !== null) {
      writable = desc.writable;
      options = desc.options;
    }
    if (options.length === 0) {
      const generated = CanonPropCatalog.generatedOptions(def);
      if (generated.length > 0) {
        options = generated;
        inferred = true;
        writable = true;
      } else {
        // 枚举类没有相机列表时，退回静态文案表：可展示、不可选。
        const table = CanonPropLabels.table(def.key);
        if (table.length > 0) options = table;
        writable = false;
      }
    }
    return { def: def, value: value, options: options, writable: writable, inferred: inferred };
  }

  /**
   * 读标准 DevicePropDesc（0x1014）。
   *
   * EOS 对部分属性不支持该命令（回 0x2005），此时返回 null，由调用方回退。
   */
  private static async readPropDesc(def: CanonPropDef): Promise<CanonDescResult | null> {
    let reply: CanonPtpDataReply;
    try {
      reply = await CanonPtpIp.opIn(0x1014, [def.ptpDpc]);
    } catch (_error) {
      return null;
    }
    if (reply.reply.code !== CanonPtpResponse.OK || reply.data.length < 9) return null;
    const data = reply.data;
    let offset = 0;
    offset += 2;                                     // DevicePropertyCode
    const type = CanonFormat.readU16(data.subarray(2, 4));
    offset += 2;                                     // DataType
    const getSet = data[offset];
    offset += 1;
    const size = CanonControlService.typeSize(type);
    if (size <= 0) return null;
    offset += size;                                  // FactoryDefault
    offset += size;                                  // CurrentValue
    if (offset >= data.length) return null;
    const formFlag = data[offset];
    offset += 1;
    const options: CanonParamOption[] = [];
    if (formFlag === 0x02 && offset + 2 <= data.length) {
      const count = CanonFormat.readU16(data.subarray(offset, offset + 2));
      offset += 2;
      for (let i = 0; i < count && offset + size <= data.length; i++) {
        const value = size === 4
          ? CanonFormat.readU32(data.subarray(offset, offset + 4))
          : CanonFormat.readU16(data.subarray(offset, offset + 2));
        options.push({ value: value, label: CanonPropLabels.labelOf(def.key, value) });
        offset += size;
      }
    }
    return { writable: (getSet & 0x01) !== 0, options: options };
  }

  private static typeSize(type: number): number {
    if (type === 0x0002 || type === 0x0003) return 1;
    if (type === 0x0004 || type === 0x0005) return 2;
    if (type === 0x0006 || type === 0x0007) return 4;
    if (type === 0x0008 || type === 0x0009) return 8;
    return 0;
  }

  static async refreshProps(): Promise<boolean> {
    if (!CanonPtpIp.isOpen()) return false;
    let changed = false;
    for (const key of CanonControlService.order) {
      const state = CanonControlService.props.get(key);
      if (state === undefined) continue;
      try {
        const data = await CanonPtpIp.getDevicePropValue(state.def.ptpDpc);
        const value = state.def.kind === 'i32' || state.def.kind === 'ev8'
          ? CanonFormat.readI32(data) : CanonFormat.readU32(data);
        if (value !== state.value) {
          state.value = value;
          changed = true;
          CanonControlService.emitPropChanged(key, value);
        }
      } catch (_error) {
        // 单项刷新失败不影响其它项。
      }
    }
    if (changed) CanonControlService.refreshSnapshot();
    return changed;
  }

  /**
   * 写参数（500 ms 去抖，报告 02 §3.3）。
   *
   * 返回 Promise：去抖结束、真正写成功后 resolve(true)；相机拒绝 resolve(false)。
   */
  static async setParam(key: string, value: number): Promise<boolean> {
    const state = CanonControlService.props.get(key);
    if (state === undefined) return false;
    if (!state.writable) {
      CanonControlService.notice(`相机未提供「${state.def.label}」的可写入口`);
      return false;
    }
    CanonControlService.pendingValues.set(key, value);
    const existing = CanonControlService.writeTimers.get(key);
    if (existing !== undefined) clearTimeout(existing);
    return new Promise<boolean>((resolve: (ok: boolean) => void): void => {
      const timer = setTimeout((): void => {
        CanonControlService.writeTimers.delete(key);
        const target = CanonControlService.pendingValues.get(key);
        CanonControlService.pendingValues.delete(key);
        const pendingValue = target === undefined ? value : target;
        CanonControlService.commitParam(key, pendingValue).then(resolve, (): void => resolve(false));
      }, WRITE_DEBOUNCE_MS) as number;
      CanonControlService.writeTimers.set(key, timer);
    });
  }

  private static async commitParam(key: string, value: number): Promise<boolean> {
    const state = CanonControlService.props.get(key);
    if (state === undefined) return false;
    try {
      await CanonPtpIp.setDevicePropValueEx(state.def.ptpDpc, value);
      state.value = value;
      CanonControlService.emitPropChanged(key, value);
      CanonControlService.refreshSnapshot();
      CanonControlService.log(`写入 ${key}=${value} (0x${state.def.ptpDpc.toString(16)}) 成功`);
      return true;
    } catch (error) {
      CanonControlService.log(`写入 ${key}=${value} 失败: ${(error as Error).message}`);
      CanonControlService.notice(`相机拒绝该值：${(error as Error).message}`);
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // 事件泵
  // -------------------------------------------------------------------------

  private static startEventPump(): void {
    if (CanonControlService.eventTimer !== -1) clearInterval(CanonControlService.eventTimer);
    CanonControlService.eventTimer = setInterval((): void => {
      if (!CanonPtpIp.isOpen()) return;
      CanonPtpIp.getEvent(800).then((events): void => {
        for (const event of events) {
          CanonControlService.handleEvent(event.code, event.params, event.data);
        }
      }, (): void => {});
    }, EVENT_POLL_MS) as number;
  }

  private static handleEvent(code: number, params: number[], data: Uint8Array): void {
    if (code === 0xC189 && params.length >= 1) {
      const def = CanonPropCatalog.defOfDpc(params[0]);
      if (def === null) return;
      const state = CanonControlService.props.get(def.key);
      if (state === undefined) return;
      const value = def.kind === 'i32' || def.kind === 'ev8'
        ? CanonFormat.readI32(data.subarray(4)) : CanonFormat.readU32(data.subarray(4));
      if (value !== state.value) {
        state.value = value;
        CanonControlService.emitPropChanged(def.key, value);
        CanonControlService.refreshSnapshot();
      }
      return;
    }
    if (code === 0xC18A && params.length >= 3) {
      const def = CanonPropCatalog.defOfDpc(params[0]);
      if (def === null) return;
      const state = CanonControlService.props.get(def.key);
      if (state === undefined) return;
      // 载荷：dpc u32 @0、type u32 @4、count u32 @8、values @12（契约 §3.4）
      const count = CanonBytes.readU32(data, 8);
      const options: CanonParamOption[] = [];
      for (let i = 0; i < count && 12 + i * 4 + 4 <= data.length; i++) {
        const value = CanonBytes.readU32(data, 12 + i * 4);
        options.push({ value: value, label: CanonPropLabels.labelOf(def.key, value) });
      }
      if (options.length > 0) {
        state.options = options;
        state.inferred = false;
        state.writable = true;
      }
      return;
    }
    if (code === 0xC181 || code === 0xC187) {
      const callback = CanonControlService.callbacks.onDeviceChanged;
      if (callback !== undefined) callback();
      if (code === 0xC181) CanonControlService.emitCapture('complete', 0);
    }
  }

  private static emitPropChanged(key: string, value: number): void {
    const callback = CanonControlService.callbacks.onPropChanged;
    if (callback === undefined) return;
    try {
      callback(key, value);
    } catch (_error) {
      // 页面回调异常不影响协议。
    }
  }

  private static emitCapture(type: string, param: number): void {
    const callback = CanonControlService.callbacks.onCapture;
    if (callback === undefined) return;
    const event: CanonCaptureEvent = { type: type, param: param };
    try {
      callback(event);
    } catch (_error) {
      // 同上。
    }
  }

  private static notice(message: string): void {
    CanonControlService.log(message);
    const callback = CanonControlService.callbacks.onNotice;
    if (callback !== undefined) {
      try {
        callback(message);
      } catch (_error) {
        // 同上。
      }
    }
  }

  private static refreshSnapshot(): void {
    const drive = CanonControlService.props.get('drive');
    const lvOutput = CanonControlService.props.get('lvOutput');
    CanonControlService.snapshot.driveMode = drive === undefined ? 0 : drive.value;
    CanonControlService.snapshot.evfOutputDevice = lvOutput === undefined ? 0 : lvOutput.value;
    CanonControlService.snapshot.propCount = CanonControlService.order.length;
  }

  // -------------------------------------------------------------------------
  // 实时取景
  // -------------------------------------------------------------------------

  /**
   * 启动取景：0xD1B0 |= 2（报告 02 §4 的 StartEvf 等价），再 InitiateViewfinder。
   */
  static async startLiveView(): Promise<boolean> {
    if (!CanonPtpIp.isOpen()) return false;
    if (CanonControlService.liveViewActive) return true;
    try {
      const current = await CanonControlService.readPropertyNumber(0xD1B0);
      const next = (current | EVF_FLAG_NORMAL) >>> 0;
      await CanonPtpIp.setDevicePropValueEx(0xD1B0, next);
      const lv = CanonControlService.props.get('lvOutput');
      if (lv !== undefined) lv.value = next;
    } catch (error) {
      CanonControlService.log(`设置取景输出失败: ${(error as Error).message}`);
    }
    try {
      const reply = await CanonPtpIp.op(CanonEosOp.INITIATE_VIEWFINDER, []);
      if (reply.code !== CanonPtpResponse.OK) {
        CanonControlService.notice(`相机拒绝启动取景（0x${reply.code.toString(16)}）`);
        return false;
      }
    } catch (error) {
      CanonControlService.notice(`启动取景失败：${(error as Error).message}`);
      return false;
    }
    CanonControlService.liveViewActive = true;
    CanonControlService.liveViewFailures = 0;
    CanonControlService.liveViewToken += 1;
    const token = CanonControlService.liveViewToken;
    CanonControlService.liveViewLoop(token).then((): void => {}, (): void => {});
    CanonControlService.log('取景已启动');
    return true;
  }

  static async stopLiveView(): Promise<void> {
    if (!CanonControlService.liveViewActive) {
      CanonControlService.liveViewToken += 1;
      return;
    }
    CanonControlService.liveViewActive = false;
    CanonControlService.liveViewToken += 1;
    try {
      await CanonPtpIp.op(CanonEosOp.TERMINATE_VIEWFINDER, []);
    } catch (error) {
      CanonControlService.log(`停止取景失败: ${(error as Error).message}`);
    }
    try {
      const current = await CanonControlService.readPropertyNumber(0xD1B0);
      await CanonPtpIp.setDevicePropValueEx(0xD1B0, (current & ~EVF_FLAG_NORMAL) >>> 0);
    } catch (_error) {
      // 相机可能已退出取景。
    }
    CanonControlService.log('取景已停止');
  }

  private static async liveViewLoop(token: number): Promise<void> {
    while (token === CanonControlService.liveViewToken && CanonPtpIp.isOpen()) {
      if (!CanonControlService.liveViewActive) return;
      try {
        const frame = await CanonPtpIp.getViewFinderData();
        if (frame.length === 0) {
          await CanonControlService.sleep(LIVEVIEW_IDLE_MS);
          continue;
        }
        CanonControlService.liveViewFailures = 0;
        const callback = CanonControlService.callbacks.onLiveViewFrame;
        if (callback !== undefined) callback(frame);
      } catch (error) {
        CanonControlService.liveViewFailures += 1;
        CanonControlService.log(`取帧失败(${CanonControlService.liveViewFailures}): ${(error as Error).message}`);
        if (CanonControlService.liveViewFailures >= LIVEVIEW_MAX_FAILURES) {
          CanonControlService.liveViewActive = false;
          CanonControlService.notice('取景中断，请重新进入预览');
          return;
        }
        await CanonControlService.sleep(200);
      }
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  // -------------------------------------------------------------------------
  // 快门 / AF / 变焦
  // -------------------------------------------------------------------------

  /** 全按（S2）。`afDrive=false` 用不带 AF 的 param 0x10003。 */
  static async capture(afDrive: boolean): Promise<boolean> {
    const param = afDrive ? 3 : 0x10003;
    CanonControlService.emitCapture('start', 0);
    try {
      await CanonControlService.releaseSwitch(param);
      await CanonControlService.sleep(CAPTURE_HOLD_MS);
      await CanonControlService.release();
      CanonControlService.emitCapture('complete', 0);
      CanonControlService.log(`快门完成 param=0x${param.toString(16)}`);
      return true;
    } catch (error) {
      const code = CanonControlService.errorCode(error as Error);
      CanonControlService.emitCapture('error', code);
      CanonControlService.log(`快门失败 param=0x${param.toString(16)} code=0x${code.toString(16)}`);
      return false;
    }
  }

  /** 半按（S1）。 */
  static async halfPress(afDrive: boolean): Promise<void> {
    const param = afDrive ? 1 : 0x10001;
    try {
      await CanonControlService.releaseSwitch(param);
      CanonControlService.log(`半按 param=0x${param.toString(16)}`);
    } catch (error) {
      CanonControlService.log(`半按失败: ${(error as Error).message}`);
    }
  }

  /** 释放（param=0 等价：两条 RemoteReleaseOff 都发）。 */
  static async release(): Promise<void> {
    try {
      await CanonPtpIp.op(CanonEosOp.REMOTE_RELEASE_OFF, [1]);
    } catch (_error) {
      // 忽略：可能本来就没按下。
    }
    try {
      await CanonPtpIp.op(CanonEosOp.REMOTE_RELEASE_OFF, [2]);
    } catch (_error) {
      // 同上。
    }
  }

  /**
   * 报告 02 §5.1 的 param 表 → DS_RemoteReleaseOn(inReleaseSwitch, inReleaseAction)。
   *
   * 0x00010001 这类 param 的高 16 位是「不带 AF」开关，低 16 位是按键动作；
   * 直接按位拆成两个参数（推导依据见契约 §4.2，日志打印实际值）。
   */
  private static async releaseSwitch(param: number): Promise<void> {
    const switchValue = (param >>> 16) & 0xFFFF;
    const action = param & 0xFFFF;
    const reply = await CanonPtpIp.op(CanonEosOp.REMOTE_RELEASE_ON, [switchValue, action]);
    if (reply.code !== CanonPtpResponse.OK) {
      throw new Error(`RemoteReleaseOn 0x${reply.code.toString(16)}`);
    }
  }

  static async af(on: boolean): Promise<void> {
    try {
      const reply = await CanonPtpIp.op(on ? CanonEosOp.DO_AF : CanonEosOp.AF_CANCEL, []);
      CanonControlService.log(`AF ${on ? 'ON' : 'OFF'} rc=0x${reply.code.toString(16)}`);
    } catch (error) {
      CanonControlService.log(`AF 失败: ${(error as Error).message}`);
    }
  }

  /**
   * 点按对焦：SetLiveAfFrame(0x915A) 传取景帧像素坐标的矩形，再 DoAf。
   *
   * 0x915A 的数据布局在报告里没有取证（libgphoto2 只写「sends data」），这里
   * 按 4 个 u32（x1,y1,x2,y2）发送；相机拒绝时退化为「只 DoAf」。
   */
  static async tapFocus(x: number, y: number): Promise<void> {
    const half = 40;
    const x1 = Math.max(0, Math.round(x) - half);
    const y1 = Math.max(0, Math.round(y) - half);
    const x2 = Math.max(x1 + 1, Math.round(x) + half);
    const y2 = Math.max(y1 + 1, Math.round(y) + half);
    try {
      const payload = CanonBytes.concat([
        CanonBytes.u32(x1), CanonBytes.u32(y1), CanonBytes.u32(x2), CanonBytes.u32(y2),
      ]);
      const reply = await CanonPtpIp.opOut(CanonEosOp.SET_LIVE_AF_FRAME, [], payload, 4000);
      if (reply.code !== CanonPtpResponse.OK) {
        CanonControlService.log(`SetLiveAfFrame 0x${reply.code.toString(16)}，退化为 DoAf`);
      }
    } catch (error) {
      CanonControlService.log(`SetLiveAfFrame 失败: ${(error as Error).message}`);
    }
    await CanonControlService.af(true);
  }

  /**
   * 变焦：`direction` 1=Tele、2=Wide、0=停止（页面约定，契约 §4.2）。
   *
   * 先写速度属性 0xD149（报告 02 §3.3 的「先 setSpeed 再发方向」），再发 0x9158。
   */
  static async zoom(direction: number, speed: number): Promise<void> {
    try {
      if (speed > 0) {
        const state = CanonControlService.props.get('zoomSpeed');
        if (state !== undefined && state.writable) {
          await CanonPtpIp.setDevicePropValueEx(0xD149, speed);
          state.value = speed;
        }
      }
      const reply = await CanonPtpIp.op(CanonEosOp.ZOOM, [Math.max(0, Math.min(2, direction))]);
      if (reply.code !== CanonPtpResponse.OK) {
        CanonControlService.log(`Zoom dir=${direction} rc=0x${reply.code.toString(16)}`);
      }
    } catch (error) {
      CanonControlService.log(`变焦失败: ${(error as Error).message}`);
    }
  }

  /**
   * 录像开关：PTP 上没有取证过的录像指令（报告 02 §6 的录像只存在于 BLE
   * 遥控服务 00030030），因此明确失败并提示，不伪造成功。
   */
  static async toggleMovie(): Promise<boolean> {
    CanonControlService.notice('PTP 通道没有录像指令，请用相机机身按键开始/停止录像');
    return false;
  }

  /** 是否处于短片模式（曝光模式值 11 = 短片，报告 02 §2 的 AEMode 表）。 */
  static isMovieMode(): boolean {
    const mode = CanonControlService.props.get('mode');
    return mode !== undefined && mode.value === 11;
  }

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  static async shutdown(): Promise<void> {
    await CanonControlService.stopLiveView();
    if (CanonControlService.eventTimer !== -1) {
      clearInterval(CanonControlService.eventTimer);
      CanonControlService.eventTimer = -1;
    }
    const timerKeys: string[] = [];
    CanonControlService.writeTimers.forEach((_value: number, key: string): void => {
      timerKeys.push(key);
    });
    for (const key of timerKeys) {
      const timer = CanonControlService.writeTimers.get(key);
      if (timer !== undefined) clearTimeout(timer);
    }
    CanonControlService.writeTimers.clear();
    CanonControlService.pendingValues.clear();
    CanonControlService.props.clear();
    CanonControlService.order = [];
    CanonControlService.connected = false;
    try {
      await CanonPtpIp.close();
    } catch (_error) {
      // 断开失败不影响页面退出。
    }
    CanonControlService.log('控制会话已关闭');
  }

  private static async readPropertyNumber(dpc: number): Promise<number> {
    try {
      const data = await CanonPtpIp.getDevicePropValue(dpc);
      return CanonFormat.readU32(data);
    } catch (_error) {
      return 0;
    }
  }

  private static async readPropertyString(dpc: number): Promise<string> {
    try {
      const data = await CanonPtpIp.getDevicePropValue(dpc);
      if (data.length === 0) return '';
      let end = data.length;
      for (let i = 0; i < data.length; i++) {
        if (data[i] === 0) { end = i; break; }
      }
      return CanonBytes.decodeUtf8(data, 0, end);
    } catch (_error) {
      return '';
    }
  }

  private static errorCode(error: Error): number {
    if (error instanceof CanonPtpError) return error.code;
    return 0;
  }
}
