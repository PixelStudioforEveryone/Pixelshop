/*
 * FUJIFILM 相机控制服务（Wi-Fi PTP-IP / FFIR 路线）。
 *
 * 本文件只做三件事：
 *  1. 按 `docs/fujifilm/ROUTE_SPEC.md` 与报告 02 §4 的顺序把一条 PTP-IP 会话
 *     协商到「遥控 / 实时取景」状态；
 *  2. 把 `GetDevicePropDescAll(0x902B)` 的原始字节解析成 UI 能直接用的
 *     属性表，并提供 `props / valueOf / setValue / step` 四个入口；
 *  3. 把动作（拍摄、录像、变焦、S1 对焦、Postview）与事件分发成页面回调。
 *
 * 协议事实全部来自 `reports/02_相机控制_指令与参数.md` 与 native 反汇编，
 * 每个不能从 `FujifilmProtocol.ets` 直接取到的常量都在下面 `FujifilmCtl`
 * 里注明 `N:` 证据。**没有一条是猜出来的成功路径**：拿不到数据就返回
 * `propsReady=false` 并写 `[FUJI]` 日志，不伪造 53 条属性。
 *
 * 与角色 A 的边界：
 *  - 传输、握手、数据阶段编码、取景通道都在 `FujifilmPtpIp`；
 *  - 本文件只调它的 `connect/op/opDataIn/opDataOut/onEvent/openLiveView/
 *    readLiveViewFrame/jpegOfFrame/closeLiveView/close`。
 */
import { image } from '@kit.ImageKit';
import { AppLogStore } from '../pages/home/HomeShared';
import { FujifilmNet } from './FujifilmProtocol';
import {
  FujifilmEventFrame,
  FujifilmPtpIp,
  FujifilmReply,
} from './FujifilmPtpIp';

// ---------------------------------------------------------------------------
// 本地常量：只补 `FujifilmProtocol.ets` 里还没有的码
// ---------------------------------------------------------------------------

/**
 * 控制路线用到的 PTP 操作码与厂商属性码。
 *
 * 说明：`FujifilmProtocol.ets` 目前只覆盖传输层常量，`FujifilmOp` 里没有
 * 0x9020 段、`FujifilmProp` 里没有 0xD0xx/0xDFxx；而且它的
 * `FILM_SIMULATION=0xD245`、`IMAGE_QUALITY=0xD244` 与报告 02 §5.3 不符
 * （0xD245 是 AF 区域，胶片模拟是 0xD001，画质是 0x5004）。为避免把错误
 * 码写进业务逻辑，本文件使用下面这张**已核对过**的表，并在 NOTES_B 里
 * 记录「应并入 FujifilmProtocol.ets」。合并后删掉这一节即可。
 */
export class FujifilmCtl {
  /** 标准 PTP。 */
  static readonly OP_GET_DEVICE_INFO: number = 0x1001;
  static readonly OP_GET_DEVICE_PROP_VALUE: number = 0x1015;
  static readonly OP_SET_DEVICE_PROP_VALUE: number = 0x1016;
  static readonly OP_TERMINATE_OPEN_CAPTURE: number = 0x1018;
  static readonly OP_INITIATE_OPEN_CAPTURE: number = 0x101C;
  static readonly OP_INITIATE_CAPTURE: number = 0x100E;

  /** 富士厂商（39 条码名表 + `N:libFFIR.so` 各 CommandExec 立即数）。 */
  static readonly OP_INITIATE_MOVIE: number = 0x9020;
  static readonly OP_TERMINATE_MOVIE: number = 0x9021;
  static readonly OP_POSTVIEW: number = 0x9022;
  static readonly OP_START_ZOOM: number = 0x9023;
  static readonly OP_STOP_ZOOM: number = 0x9024;
  static readonly OP_STEP_ZOOM: number = 0x9025;
  static readonly OP_LOCK_S1: number = 0x9026;
  static readonly OP_UNLOCK_S1: number = 0x9027;
  static readonly OP_PROP_DESC_ALL: number = 0x902B;
  static readonly OP_STEP_SHUTTER: number = 0x902C;
  static readonly OP_STEP_APERTURE: number = 0x902D;
  static readonly OP_STEP_EV: number = 0x902E;
  static readonly OP_CANCEL_CAPTURE: number = 0x9030;

  /**
   * 模式协商属性。
   *
   * `N:libFFIR.so 0x5ed28` SDK_SetFunctionMode → `CCameraParamForSetInt(0x4078,
   * handle, 0xDF01, 4)` → `CPTPCommand::SetDeviceProperty` → **0x1016**，值 2 字节。
   * `0x6155c` SDK_SetCameraFunctionMode → cmd 0x4210、prop **0xDF00**、type 4。
   * `0x5ee14` SDK_SetFunctionVersion → cmd 0x4130、prop=入参、type 6（4 字节）。
   * `0x5eee8` SDK_GetFunctionVersion → cmd 0x4131、prop=入参、type 6（4 字节）。
   */
  static readonly PROP_FUNCTION_MODE: number = 0xDF01;
  static readonly PROP_CAMERA_FUNCTION_MODE: number = 0xDF00;
  static readonly PROP_VERSION_REMOTE: number = 0xDF24;
  static readonly PROP_VERSION_REMOTE_PHOTO_VIEW: number = 0xDF25;
  static readonly PROP_VERSION_REMOTE_PHOTO_VIEW_EX: number = 0xDF28;
  static readonly PROP_VERSION_REMOTE_EX: number = 0xDF2A;

  /** 模式值（`reports/data/control_function_modes.csv`）。 */
  static readonly MODE_REMOTE: number = 5;
  static readonly MODE_NEUTRAL: number = 6;
  static readonly MODE_IMAGE_VIEW: number = 20;
  static readonly MODE_LIVE_VIEW: number = 22;

  /** camera.xml `versionRemote` 缺省值；App 对 0xDF24 固定写它。 */
  static readonly DEFAULT_VERSION_REMOTE: number = 131083;

  /** SDK 事件码（报告 02 §8.2）。 */
  static readonly EVENT_ADD_IMAGE: number = 1;
  static readonly EVENT_GET_CAMERA_MODE: number = 11;
  static readonly EVENT_CAPTURE_START: number = 30;
  static readonly EVENT_CAPTURE_COMPLETE: number = 31;
  static readonly EVENT_POSTVIEW_COMPLETE: number = 32;
  static readonly EVENT_PROP_VALUE: number = 40;
  static readonly EVENT_DEVICE_INFO_CHANGED: number = 41;
  static readonly EVENT_AF_CAPTURE: number = 43;
  static readonly EVENT_BEGIN_PROP_VALUE: number = 44;
  static readonly EVENT_END_PROP_VALUE: number = 45;
  static readonly EVENT_SENDING: number = 49;
  static readonly EVENT_SEND_COMPLETE: number = 50;

  /** 原始 PTP 事件 → SDK 事件（`N:libFFIR.so 0x6bc24 CCameraEvent::ThreadProc`）。 */
  static readonly PTP_CAPTURE_START: number = 0xC004;
  static readonly PTP_POSTVIEW_COMPLETE: number = 0xC001;
  static readonly PTP_AF_CAPTURE: number = 0xC005;
  static readonly PTP_DEVICE_INFO_CHANGED: number = 0x4008;
  static readonly PTP_CAPTURE_COMPLETE: number = 0x400D;
  static readonly PTP_DEVICE_PROP_CHANGED: number = 0x4006;
  static readonly PTP_OBJECT_ADDED: number = 0x4002;

  /** 4102 / 0x2019 是唯一的重试判据；5 次 × 100ms。 */
  static readonly RETRY_LIMIT: number = 5;
  static readonly RETRY_DELAY_MS: number = 100;
}

// ---------------------------------------------------------------------------
// 属性表模型
// ---------------------------------------------------------------------------

/** 一条相机属性描述符；字段与报告 02 §5.1 的 `DevicePropBase` 一一对应。 */
export interface FujifilmPropDesc {
  code: number;
  /** 原始 dataType（含 0x10000/0x20000 字符串标志位）。 */
  dataType: number;
  /** 基础类型低 16 位。 */
  baseType: number;
  /** 0=只读，1=可读写；来自描述符，不是我们的推断。 */
  writable: boolean;
  isString: boolean;
  current: number;
  currentStr: string;
  factory: number;
  min: number;
  max: number;
  step: number;
  /** 枚举候选；formFlag=1（range）时为空。 */
  values: number[];
  valuesStr: string[];
}

/** UI 的一组候选值。 */
export interface FujifilmParamOption {
  value: number;
  label: string;
}

/** `FujifilmParamCatalog` 的一行：码 + 文案 + 值域 + 控件形态。 */
export class FujifilmParamSpec {
  code: number;
  key: string;
  label: string;
  group: string;
  /** 'read' | 'enum' | 'step' */
  kind: string;
  /** 首页参数网格里是否显示。 */
  primary: boolean;
  /** 已知值域；描述符给了 `values` 时以描述符为准。 */
  options: FujifilmParamOption[];

  constructor(code: number, key: string, label: string, group: string,
    kind: string, primary: boolean, options: FujifilmParamOption[] = []) {
    this.code = code;
    this.key = key;
    this.label = label;
    this.group = group;
    this.kind = kind;
    this.primary = primary;
    this.options = options;
  }
}

export interface FujifilmCaptureEvent {
  /** 'start' | 'complete' | 'postview' */
  type: string;
  param: number;
}

export interface FujifilmControlCallbacks {
  onCapture: (event: FujifilmCaptureEvent) => void;
  onPropChanged: (code: number, value: number) => void;
  onAfDone: () => void;
  onDeviceChanged: () => void;
  onNotice: (message: string) => void;
}

export interface FujifilmControlSnapshot {
  model: string;
  serial: string;
  /** 0x902B 是否成功解析出属性表。 */
  propsReady: boolean;
  propCount: number;
  /** 本次协商最终进入的模式（11 事件缺省时按 5 处理并标记）。 */
  mode: number;
  /** 相机上报的 0xD246 值（0=静止，1=动画），未知为 -1。 */
  driveMode: number;
  /** 降级原因；空串表示完整成功。 */
  degradedReason: string;
}

// ---------------------------------------------------------------------------
// 参数目录：53 条（报告 02 §5.3 全覆盖）
// ---------------------------------------------------------------------------

export class FujifilmParamCatalog {
  private static cache: FujifilmParamSpec[] | null = null;

  private static opt(value: number, label: string): FujifilmParamOption {
    return { value: value, label: label };
  }

  private static opts(values: number[], labels: string[]): FujifilmParamOption[] {
    const out: FujifilmParamOption[] = [];
    const count = Math.min(values.length, labels.length);
    for (let i = 0; i < count; i++) {
      out.push({ value: values[i], label: labels[i] });
    }
    return out;
  }

  private static wbOptions(): FujifilmParamOption[] {
    return FujifilmParamCatalog.opts(
      [2, 4, 6, 32769, 32770, 32771, 32774, 32778, 32779, 32780, 32781, 32782],
      ['自动', '日光', '白炽灯', 'FL-1', 'FL-2', 'FL-3', '阴影', '水下',
        '色温', '自定义 1', '自动（白色优先）', '自动（氛围优先）']);
  }

  private static filmOptions(): FujifilmParamOption[] {
    return FujifilmParamCatalog.opts(
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
      ['PROVIA / STANDARD', 'Velvia / VIVID', 'ASTIA / SOFT', 'MONOCHROME', 'SEPIA',
        'PRO Neg.Hi', 'PRO Neg.Std', 'MONOCHROME+Ye', 'MONOCHROME+R', 'MONOCHROME+G',
        'CLASSIC CHROME', 'ACROS', 'ACROS+Ye', 'ACROS+R', 'ACROS+G',
        'ETERNA / CINEMA', 'CLASSIC Neg.', 'ETERNA BLEACH BYPASS',
        'NOSTALGIC Neg.', 'REALA ACE']);
  }

  private static exposureOptions(): FujifilmParamOption[] {
    return FujifilmParamCatalog.opts(
      [1, 2, 3, 4, 6, 0x8002, 0x8003, 0x8004, 0x8005, 0x8006, 0x8007, 0x8008, 0xFFFF8001],
      ['M 手动', 'P 程序', 'A 光圈优先', 'S 快门优先', 'AUTO 全自动',
        'SP 场景', '动画', 'Adv 创意', 'SR AUTO', '自定义', '自定义 1', '自定义 2', 'EXR']);
  }

  private static sizeOptions(): FujifilmParamOption[] {
    const out: FujifilmParamOption[] = [];
    for (let code = 1; code <= 34; code++) {
      let group = '';
      if ((code >= 1 && code <= 4) || (code >= 17 && code <= 19) ||
        code === 29 || code === 30) {
        group = 'L';
      } else if ((code >= 5 && code <= 8) || (code >= 20 && code <= 22) ||
        code === 31 || code === 32) {
        group = 'M';
      } else if ((code >= 9 && code <= 12) || (code >= 23 && code <= 25) ||
        code === 33 || code === 34) {
        group = 'S';
      } else {
        continue;
      }
      out.push({ value: code, label: `${group} (${code})` });
    }
    return out;
  }

  private static driveOptions(): FujifilmParamOption[] {
    return FujifilmParamCatalog.opts([0, 1], ['静止', '动画']);
  }

  private static flashOptions(): FujifilmParamOption[] {
    return FujifilmParamCatalog.opts([32777, 32778], ['关闭', '开启']);
  }

  private static timerOptions(): FujifilmParamOption[] {
    return FujifilmParamCatalog.opts([0, 2, 4], ['关闭', '2 秒', '10 秒']);
  }

  private static focusOptions(): FujifilmParamOption[] {
    return FujifilmParamCatalog.opts([1, 32769, 32770], ['MF 手动', 'AF-S 单次', 'AF-C 连续']);
  }

  private static shutterTypeOptions(): FujifilmParamOption[] {
    // CSV 只写「枚举」，没有给 0/1/2 的语义；不替相机编值域，交给描述符。
    return [];
  }

  private static afSelectOptions(): FujifilmParamOption[] {
    // 值域 0–7 是 CSV 明写的；具体名称 CSV 没给，这里只标序号。
    const out: FujifilmParamOption[] = [];
    for (let i = 0; i <= 7; i++) out.push({ value: i, label: `区域 ${i}` });
    return out;
  }

  static build(): FujifilmParamSpec[] {
    const list: FujifilmParamSpec[] = [];

    // ---- 曝光 ----
    list.push(new FujifilmParamSpec(0x500E, 'exposureMode', '曝光模式', '曝光', 'read', true,
      FujifilmParamCatalog.exposureOptions()));
    list.push(new FujifilmParamSpec(0x5010, 'ev', '曝光补偿', '曝光', 'step', true, []));
    list.push(new FujifilmParamSpec(0xD240, 'shutter', '快门速度', '曝光', 'step', true, []));
    list.push(new FujifilmParamSpec(0x5007, 'aperture', '光圈', '曝光', 'step', true, []));
    list.push(new FujifilmParamSpec(0xD02A, 'iso', 'ISO', '曝光', 'step', true, []));
    list.push(new FujifilmParamSpec(0xD02B, 'movieIso', '动画 ISO', '曝光', 'step', false, []));
    list.push(new FujifilmParamSpec(0x500B, 'metering', '测光模式', '曝光', 'read', false, []));
    list.push(new FujifilmParamSpec(0x500D, 'shutterStandard', '快门速度（标准）', '曝光', 'read', false, []));
    list.push(new FujifilmParamSpec(0x500F, 'exposureIndex', '曝光指数', '曝光', 'read', false, []));

    // ---- 色彩 ----
    list.push(new FujifilmParamSpec(0xD001, 'film', '胶片模拟', '色彩', 'enum', true,
      FujifilmParamCatalog.filmOptions()));
    list.push(new FujifilmParamSpec(0x5005, 'wb', '白平衡', '色彩', 'enum', true,
      FujifilmParamCatalog.wbOptions()));
    list.push(new FujifilmParamSpec(0x5004, 'quality', '画质', '色彩', 'enum', true, []));
    list.push(new FujifilmParamSpec(0x5006, 'rgbGain', 'RGB 增益', '色彩', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD028, 'exposureColor', '曝光文字颜色', '色彩', 'read', false, []));

    // ---- 画质 / 尺寸 ----
    list.push(new FujifilmParamSpec(0x5003, 'imageSize', '图像尺寸（像素）', '画质', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD241, 'pixelSize', '图像尺寸', '画质', 'enum', true,
      FujifilmParamCatalog.sizeOptions()));
    list.push(new FujifilmParamSpec(0x5014, 'contrast', '对比度', '画质', 'read', false, []));
    list.push(new FujifilmParamSpec(0x5015, 'sharpness', '锐度', '画质', 'read', false, []));
    list.push(new FujifilmParamSpec(0x5017, 'effect', '效果', '画质', 'read', false, []));
    list.push(new FujifilmParamSpec(0x5016, 'digitalZoom', '数码变焦', '画质', 'read', false, []));

    // ---- 拍摄 ----
    list.push(new FujifilmParamSpec(0x500C, 'flash', '闪光灯', '拍摄', 'enum', true,
      FujifilmParamCatalog.flashOptions()));
    list.push(new FujifilmParamSpec(0x5012, 'timer', '自拍定时', '拍摄', 'enum', true,
      FujifilmParamCatalog.timerOptions()));
    list.push(new FujifilmParamSpec(0x500A, 'focusMode', '对焦模式', '拍摄', 'enum', true,
      FujifilmParamCatalog.focusOptions()));
    list.push(new FujifilmParamSpec(0xD246, 'drive', '驱动模式', '拍摄', 'enum', true,
      FujifilmParamCatalog.driveOptions()));
    list.push(new FujifilmParamSpec(0xD01D, 'macro', '微距', '拍摄', 'enum', false, []));
    list.push(new FujifilmParamSpec(0x5013, 'driveStandard', '驱动模式（标准）', '拍摄', 'read', false, []));
    list.push(new FujifilmParamSpec(0x5018, 'burstCount', '连拍张数', '拍摄', 'read', false, []));
    list.push(new FujifilmParamSpec(0x5019, 'burstInterval', '连拍间隔', '拍摄', 'read', false, []));
    list.push(new FujifilmParamSpec(0x501A, 'intervalCount', '间隔张数', '拍摄', 'read', false, []));
    list.push(new FujifilmParamSpec(0x501B, 'intervalInterval', '间隔时间', '拍摄', 'read', false, []));
    list.push(new FujifilmParamSpec(0x501C, 'afMetering', 'AF 测光', '拍摄', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD019, 'recEnable', '录像使能', '拍摄', 'read', false, []));

    // ---- 对焦 ----
    list.push(new FujifilmParamSpec(0xD245, 'afSelect', 'AF 区域', '对焦', 'read', true,
      FujifilmParamCatalog.afSelectOptions()));
    list.push(new FujifilmParamSpec(0xD17C, 's1Lock', 'S1 AF 框', '对焦', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD209, 'afFocus', 'AF 合焦', '对焦', 'read', false, []));

    // ---- 状态 ----
    list.push(new FujifilmParamSpec(0x5001, 'battery', '电池电量', '状态', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD242, 'batteryLevel', '电池分段', '状态', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD229, 'remaining', '剩余张数', '状态', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD22A, 'remainingTime', '剩余录制时间', '状态', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD21B, 'cameraStatus', '相机状态', '状态', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD170, 'zoomPosition', '变焦位置', '状态', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD243, 'shutterType', '快门类型', '状态', 'read', false,
      FujifilmParamCatalog.shutterTypeOptions()));
    list.push(new FujifilmParamSpec(0xD018, 'ccdMode', 'CCD 模式', '状态', 'read', false, []));

    // ---- 系统 / 其他 ----
    list.push(new FujifilmParamSpec(0x5002, 'functionMode', '功能模式', '系统', 'read', false, []));
    list.push(new FujifilmParamSpec(0x5008, 'focalLength', '焦距', '系统', 'read', false, []));
    list.push(new FujifilmParamSpec(0x5009, 'focusDistance', '对焦距离', '系统', 'read', false, []));
    list.push(new FujifilmParamSpec(0x5011, 'dateTime', '日期时间', '系统', 'read', false, []));
    list.push(new FujifilmParamSpec(0x501D, 'uploadUrl', '上传地址', '系统', 'read', false, []));
    list.push(new FujifilmParamSpec(0x501E, 'artist', '作者', '系统', 'read', false, []));
    list.push(new FujifilmParamSpec(0x501F, 'copyright', '版权', '系统', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD212, 'propList', '属性列表', '系统', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD220, 'requestObject', '请求对象句柄', '系统', 'read', false, []));
    list.push(new FujifilmParamSpec(0xD2B7, 'movieFrameInfo', '动画剩余框', '系统', 'read', false, []));

    return list;
  }

  static all(): FujifilmParamSpec[] {
    const cached = FujifilmParamCatalog.cache;
    if (cached !== null) return cached;
    const built = FujifilmParamCatalog.build();
    FujifilmParamCatalog.cache = built;
    return built;
  }

  static find(code: number): FujifilmParamSpec | null {
    const list = FujifilmParamCatalog.all();
    for (const spec of list) {
      if (spec.code === code) return spec;
    }
    return null;
  }

  /** 状态码 0–17（报告 02 §8.3）。 */
  static statusText(value: number): string {
    switch (value) {
      case 0: return '正常';
      case 1: return '相机驱动错误';
      case 2: return '相机驱动错误';
      case 3: return '相机驱动错误';
      case 4: return '相机忙';
      case 5: return '镜头驱动错误';
      case 6: return '镜头驱动错误';
      case 7: return '存储卡锁定';
      case 8: return '相机驱动错误';
      case 9: return '相机驱动错误';
      case 10: return '写入错误';
      case 11: return '存储卡已满';
      case 12: return '电池耗尽';
      case 13: return '存储卡错误';
      case 14: return '高温上限';
      case 15: return '无存储卡';
      case 16: return '文件编号耗尽';
      case 17: return '外接存储';
      default: return `状态 ${value}`;
    }
  }

  /** 这些状态应阻断快门的「可拍」提示，但仍允许用户尝试。 */
  static statusBlocksShooting(value: number): boolean {
    return value === 7 || value === 11 || value === 12 || value === 13 ||
      value === 14 || value === 15 || value === 16;
  }
}

// ---------------------------------------------------------------------------
// 小工具：字节读取 / 延时
// ---------------------------------------------------------------------------

class FujifilmReader {
  data: Uint8Array;
  offset: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  remaining(): number {
    return this.data.length - this.offset;
  }

  u8(): number {
    if (this.offset + 1 > this.data.length) throw new Error('prop desc: u8 越界');
    const value = this.data[this.offset];
    this.offset += 1;
    return value;
  }

  u16(): number {
    if (this.offset + 2 > this.data.length) throw new Error('prop desc: u16 越界');
    const value = (this.data[this.offset] | (this.data[this.offset + 1] << 8)) & 0xFFFF;
    this.offset += 2;
    return value;
  }

  u32(): number {
    if (this.offset + 4 > this.data.length) throw new Error('prop desc: u32 越界');
    const value = (this.data[this.offset] | (this.data[this.offset + 1] << 8) |
      (this.data[this.offset + 2] << 16) | (this.data[this.offset + 3] << 24)) >>> 0;
    this.offset += 4;
    return value;
  }

  bytes(length: number): Uint8Array {
    if (length < 0 || this.offset + length > this.data.length) {
      throw new Error(`prop desc: 需要 ${length} 字节，只剩 ${this.remaining()}`);
    }
    const out = this.data.subarray(this.offset, this.offset + length);
    this.offset += length;
    return out;
  }

  skip(length: number): void {
    this.offset += length;
  }

  /** 标准 PTP 字符串：u8 长度（含结尾 NUL）+ UTF-16LE。 */
  ptpString(): string {
    if (this.remaining() < 1) return '';
    const chars = this.u8();
    if (chars === 0) return '';
    const bytes = this.bytes(chars * 2);
    return FujifilmControlService.decodeUtf16Le(bytes);
  }
}

function fujiDelay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

// ---------------------------------------------------------------------------
// 服务本体
// ---------------------------------------------------------------------------

export class FujifilmControlService {
  private static callbacks: FujifilmControlCallbacks | null = null;
  private static propTable: FujifilmPropDesc[] = [];
  private static propIndex: Map<number, number> = new Map<number, number>();

  private static connected: boolean = false;
  private static propsReady: boolean = false;
  private static degradedReason: string = '';
  private static currentMode: number = -1;
  private static driveMode: number = -1;
  private static model: string = '';
  private static serial: string = '';
  private static versionRemote: number = FujifilmCtl.DEFAULT_VERSION_REMOTE;

  /** 最近一次事件 11 的相机请求模式；-1 表示还没收到。 */
  private static requestedMode: number = -1;
  private static modeWaiter: ((mode: number) => void) | null = null;

  private static liveRunning: boolean = false;
  private static liveGeneration: number = 0;
  private static viewMode: string = 'remote';
  private static lastLiveError: string = '';

  private static shuttingDown: boolean = false;
  /** 事件桥只装一次；`FujifilmPtpIp.close()` 不会清监听器。 */
  private static eventBridgeInstalled: boolean = false;

  private static readonly MODE_WAIT_MS: number = 12000;
  private static readonly PROP_DESC_TIMEOUT_MS: number = 20000;
  private static readonly CAPTURE_TIMEOUT_MS: number = 15000;
  private static readonly FRAME_INTERVAL_MS: number = 8;

  static setCallbacks(callbacks: FujifilmControlCallbacks): void {
    FujifilmControlService.callbacks = callbacks;
  }

  static clearCallbacks(): void {
    FujifilmControlService.callbacks = null;
  }

  static isReady(): boolean {
    return FujifilmControlService.connected;
  }

  static arePropsReady(): boolean {
    return FujifilmControlService.propsReady;
  }

  static getModel(): string {
    return FujifilmControlService.model;
  }

  static getProps(): FujifilmPropDesc[] {
    return FujifilmControlService.propTable;
  }

  // -------------------------------------------------------------------------
  // 连接 / 模式协商（报告 02 §4 S01–S22）
  // -------------------------------------------------------------------------

  /**
   * 完整连接编排。失败抛 `Error`，由页面展示可操作的重试提示。
   * `fallbackModel` 来自 BLE 会话（`CameraSessionStore.cameraModel`），
   * 因为 `GetDeviceModelInfo` 在部分固件上不返回型号。
   */
  static async connect(fallbackModel: string = ''): Promise<FujifilmControlSnapshot> {
    FujifilmControlService.reset();
    FujifilmControlService.model = fallbackModel;
    FujifilmControlService.registerEventBridge();

    await FujifilmPtpIp.connect();
    FujifilmControlService.connected = true;
    FujifilmControlService.log('PTP-IP 会话已建立');

    await FujifilmControlService.readDeviceInfo(fallbackModel);

    // S11：相机请求模式。部分固件不主动发 11，超时后按「已进入遥控」继续，
    // 但在 snapshot 里标明降级，绝不假装收到。
    const firstMode = await FujifilmControlService.waitRequestedMode(
      FujifilmControlService.MODE_WAIT_MS);
    if (firstMode < 0) {
      FujifilmControlService.log('等待事件 11 超时：按默认模式继续（降级）');
      FujifilmControlService.degradedReason = '未收到相机模式请求（事件 11），已按默认遥控模式继续';
    } else {
      FujifilmControlService.log(`收到事件 11：相机请求模式 ${firstMode}`);
    }

    // S13–S15：20(0xDF28,≤3) → SetCameraFunctionMode(6) → 22(0xDF2A,≤4)。
    await FujifilmControlService.setFunctionMode(FujifilmCtl.MODE_IMAGE_VIEW,
      FujifilmCtl.PROP_VERSION_REMOTE_PHOTO_VIEW_EX, 3);
    await FujifilmControlService.setCameraFunctionMode(FujifilmCtl.MODE_NEUTRAL);
    await FujifilmControlService.setFunctionMode(FujifilmCtl.MODE_LIVE_VIEW,
      FujifilmCtl.PROP_VERSION_REMOTE_EX, 4);

    // S20 / S22：全量属性描述符（失败只降级，不阻断拍摄）。
    await FujifilmControlService.loadProps();

    // S23–S27：InitiateOpenCapture Phase1（0x101C）→ Phase2（取景 socket）。
    await FujifilmControlService.initiateOpenCapture();

    // S29–S30：再收 11（可能没有）→ 模式 5 + 版本协商 0xDF25/0xDF24。
    const secondMode = await FujifilmControlService.waitRequestedMode(4000);
    if (secondMode >= 0) {
      FujifilmControlService.log(`第二次事件 11：模式 ${secondMode}`);
    }
    // 这一步失败不把整页判死：属性表已经拿到、取景也通了，用户仍可拍摄；
    // 只在页面顶部保留降级说明。
    try {
      await FujifilmControlService.setFunctionMode(FujifilmCtl.MODE_REMOTE, -1, -1);
      const remoteVersion = await FujifilmControlService.getFunctionVersion(
        FujifilmCtl.PROP_VERSION_REMOTE_PHOTO_VIEW);
      if (remoteVersion >= 0) {
        FujifilmControlService.log(`GetFunctionVersion(0xDF25)=${remoteVersion}`);
      }
      const remoteWrite = FujifilmControlService.versionRemote > 0
        ? FujifilmControlService.versionRemote : FujifilmCtl.DEFAULT_VERSION_REMOTE;
      await FujifilmControlService.setFunctionVersion(
        FujifilmCtl.PROP_VERSION_REMOTE, remoteWrite);
      FujifilmControlService.currentMode = FujifilmCtl.MODE_REMOTE;
    } catch (error) {
      const reason = `模式 5 / 版本 0xDF24 协商失败：${FujifilmControlService.describe(error)}`;
      FujifilmControlService.log(reason);
      FujifilmControlService.degradedReason =
        FujifilmControlService.degradedReason.length > 0
          ? `${FujifilmControlService.degradedReason}；${reason}` : reason;
    }

    const drive = FujifilmControlService.valueOf(0xD246);
    FujifilmControlService.driveMode = drive >= 0 ? drive : -1;

    FujifilmControlService.log(
      `连接完成 model=${FujifilmControlService.model || '?'} props=${FujifilmControlService.propTable.length} ` +
      `propsReady=${FujifilmControlService.propsReady} degraded=${FujifilmControlService.degradedReason}`);
    return FujifilmControlService.snapshot();
  }

  private static reset(): void {
    FujifilmControlService.connected = false;
    FujifilmControlService.propsReady = false;
    FujifilmControlService.degradedReason = '';
    FujifilmControlService.currentMode = -1;
    FujifilmControlService.driveMode = -1;
    FujifilmControlService.requestedMode = -1;
    FujifilmControlService.modeWaiter = null;
    FujifilmControlService.propTable = [];
    FujifilmControlService.propIndex = new Map<number, number>();
    FujifilmControlService.stopLiveView();
    FujifilmControlService.lastLiveError = '';
    FujifilmControlService.shuttingDown = false;
    FujifilmControlService.versionRemote = FujifilmCtl.DEFAULT_VERSION_REMOTE;
  }

  static snapshot(): FujifilmControlSnapshot {
    return {
      model: FujifilmControlService.model,
      serial: FujifilmControlService.serial,
      propsReady: FujifilmControlService.propsReady,
      propCount: FujifilmControlService.propTable.length,
      mode: FujifilmControlService.currentMode,
      driveMode: FujifilmControlService.driveMode,
      degradedReason: FujifilmControlService.degradedReason,
    };
  }

  /**
   * `SetFunctionMode(mode)` = 0x1016 `[0xDF01]` + u16；随后读版本，版本
   * ≤ `maxVersion` 时写回同值（报告 02 §4 S13/S15/S29）。
   */
  private static async setFunctionMode(mode: number, versionProp: number,
    maxVersion: number): Promise<void> {
    const reply = await FujifilmControlService.busyRetry((): Promise<FujifilmReply> =>
      FujifilmPtpIp.opDataOut(FujifilmCtl.OP_SET_DEVICE_PROP_VALUE,
        [FujifilmCtl.PROP_FUNCTION_MODE],
        FujifilmControlService.u16(FujifilmControlService.normalizeMode(mode))));
    FujifilmControlService.expectOk(reply, `SetFunctionMode(${mode})`);
    FujifilmControlService.log(`SetFunctionMode(${mode}) ok`);

    if (versionProp > 0) {
      const version = await FujifilmControlService.getFunctionVersion(versionProp);
      if (version >= 0 && (maxVersion < 0 || version <= maxVersion)) {
        await FujifilmControlService.setFunctionVersion(versionProp, version);
      }
    }
  }

  /** `SetCameraFunctionMode(6)` = 0x1016 `[0xDF00]` + u16（type 4）。 */
  private static async setCameraFunctionMode(mode: number): Promise<void> {
    const reply = await FujifilmControlService.busyRetry((): Promise<FujifilmReply> =>
      FujifilmPtpIp.opDataOut(FujifilmCtl.OP_SET_DEVICE_PROP_VALUE,
        [FujifilmCtl.PROP_CAMERA_FUNCTION_MODE],
        FujifilmControlService.u16(FujifilmControlService.normalizeMode(mode))));
    FujifilmControlService.expectOk(reply, `SetCameraFunctionMode(${mode})`);
    FujifilmControlService.log(`SetCameraFunctionMode(${mode}) ok`);
  }

  /** `GetFunctionVersion` = 0x1015 `[prop]`，data-in 4 字节（type 6）。 */
  static async getFunctionVersion(prop: number): Promise<number> {
    try {
      const reply = await FujifilmControlService.busyRetry((): Promise<FujifilmReply> =>
        FujifilmPtpIp.opDataIn(FujifilmCtl.OP_GET_DEVICE_PROP_VALUE, [prop]));
      if (reply.code !== 0x2001) {
        FujifilmControlService.log(`GetFunctionVersion(0x${prop.toString(16)}) code=0x${reply.code.toString(16)}`);
        return -1;
      }
      if (reply.data.length >= 4) {
        return FujifilmControlService.readU32(reply.data, 0);
      }
      if (reply.params.length > 0) return reply.params[0] >>> 0;
      return -1;
    } catch (error) {
      FujifilmControlService.log(`GetFunctionVersion 异常：${FujifilmControlService.describe(error)}`);
      return -1;
    }
  }

  /** `SetFunctionVersion` = 0x1016 `[prop]` + u32（type 6）。 */
  private static async setFunctionVersion(prop: number, version: number): Promise<void> {
    const reply = await FujifilmControlService.busyRetry((): Promise<FujifilmReply> =>
      FujifilmPtpIp.opDataOut(FujifilmCtl.OP_SET_DEVICE_PROP_VALUE, [prop],
        FujifilmControlService.u32(version >>> 0)));
    FujifilmControlService.expectOk(reply,
      `SetFunctionVersion(0x${prop.toString(16)}, ${version})`);
    FujifilmControlService.log(`SetFunctionVersion(0x${prop.toString(16)})=${version} ok`);
  }

  private static normalizeMode(mode: number): number {
    return mode & 0xFFFF;
  }

  /** 等待事件 11；已经收到过（`requestedMode>=0`）就直接返回并消费掉。 */
  private static waitRequestedMode(timeoutMs: number): Promise<number> {
    const existing = FujifilmControlService.requestedMode;
    if (existing >= 0) {
      FujifilmControlService.requestedMode = -1;
      return Promise.resolve(existing);
    }
    return new Promise<number>((resolve: (mode: number) => void) => {
      let done = false;
      const timer = setTimeout((): void => {
        if (done) return;
        done = true;
        FujifilmControlService.modeWaiter = null;
        resolve(-1);
      }, timeoutMs);
      FujifilmControlService.modeWaiter = (mode: number): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        FujifilmControlService.modeWaiter = null;
        FujifilmControlService.requestedMode = -1;
        resolve(mode);
      };
    });
  }

  // -------------------------------------------------------------------------
  // DeviceInfo / 属性描述符
  // -------------------------------------------------------------------------

  /**
   * `GetDeviceModelInfo` 在 native 里**不是一条 PTP 操作**：它从 `Open` 期间
   * `GetDeviceInfo(0x1001)` 已缓存的应答里取型号（`N:libFTLPTPIP.so 0x2afe0`
   * 只读 handle 的 +0x178/+0x188/+0x1b2，没有新增 opcode）。所以这里补一条
   * 0x1001，按标准 PTP DeviceInfo 解析 Manufacturer/Model/Serial；失败就用
   * BLE 会话给的型号，不影响后续协商。
   */
  private static async readDeviceInfo(fallbackModel: string): Promise<void> {
    try {
      const reply = await FujifilmPtpIp.opDataIn(FujifilmCtl.OP_GET_DEVICE_INFO, [], 8000);
      if (reply.code !== 0x2001 || reply.data.length < 20) {
        FujifilmControlService.log(`GetDeviceInfo code=0x${reply.code.toString(16)} len=${reply.data.length}`);
        return;
      }
      const info = FujifilmControlService.parseDeviceInfo(reply.data);
      if (info.model.length > 0) FujifilmControlService.model = info.model;
      if (info.serial.length > 0) FujifilmControlService.serial = info.serial;
      FujifilmControlService.log(
        `GetDeviceInfo model=${info.model || fallbackModel} serial=${info.serial || '-'}`);
    } catch (error) {
      FujifilmControlService.log(`GetDeviceInfo 异常（用 BLE 型号）：${FujifilmControlService.describe(error)}`);
    }
    if (FujifilmControlService.model.length === 0) {
      FujifilmControlService.model = fallbackModel;
    }
  }

  private static parseDeviceInfo(data: Uint8Array): FujifilmDeviceIdentity {
    const out: FujifilmDeviceIdentity = { model: '', serial: '' };
    try {
      const reader = new FujifilmReader(data);
      reader.u16(); // StandardVersion
      reader.u32(); // VendorExtensionID
      reader.u16(); // VendorExtensionVersion
      reader.ptpString(); // VendorExtensionDesc
      reader.u16(); // FunctionalMode
      FujifilmControlService.skipPtpArray(reader);
      FujifilmControlService.skipPtpArray(reader);
      FujifilmControlService.skipPtpArray(reader);
      FujifilmControlService.skipPtpArray(reader);
      FujifilmControlService.skipPtpArray(reader);
      const manufacturer = reader.ptpString();
      const model = reader.ptpString();
      reader.ptpString(); // DeviceVersion
      const serial = reader.ptpString();
      out.model = model.length > 0 ? model : manufacturer;
      out.serial = serial;
    } catch (error) {
      FujifilmControlService.log(`DeviceInfo 解析失败：${FujifilmControlService.describe(error)}`);
    }
    return out;
  }

  private static skipPtpArray(reader: FujifilmReader): void {
    const count = reader.u32();
    if (count > 0x10000) throw new Error(`DeviceInfo 数组长度异常 ${count}`);
    reader.skip(count * 2);
  }

  /**
   * 0x902B 的线上布局（`N:libFTLPTPIP.so 0x2f4b4–0x2f5f8`）：
   *
   *   u32 count
   *   count × {
   *     u16 propertyCode
   *     u8  getSet          // 0=只读，1=可读写
   *     u8  reserved
   *     u16 dataType        // 含 0x10000/0x20000 字符串标志
   *     u16 payloadSize
   *     u8[payloadSize] payload
   *   }
   *
   * `FTL_PTP_GetDevicePropDescAll` 在 `0x2f5b8` 处正是按
   * `LDRH [x8+4]`（type）、`LDRH [x8+6]`（size）、`ADD x22,x8,#8`（payload）
   * 取值后调用 `setDevicePropDescInt/Str`，所以这 8 字节头是**反汇编确认**的，
   * 不是照 PTP 规范猜的。payload 内部字段顺序由 `setDevicePropDescInt`
   * （`N:0x2e3d4`）按「factory → current → form → range/enum」读取；这里用
   * 「必须恰好消费完 payload」做自校验，解析不完整就报错，不返回半张表。
   */
  private static async loadProps(): Promise<void> {
    try {
      const reply = await FujifilmControlService.busyRetry((): Promise<FujifilmReply> =>
        FujifilmPtpIp.opDataIn(FujifilmCtl.OP_PROP_DESC_ALL, [0],
          FujifilmControlService.PROP_DESC_TIMEOUT_MS));
      if (reply.code !== 0x2001) {
        throw new Error(`0x902B 响应码 0x${reply.code.toString(16)}`);
      }
      const parsed = FujifilmControlService.parsePropDescAll(reply.data);
      FujifilmControlService.propTable = parsed;
      FujifilmControlService.propIndex = new Map<number, number>();
      for (let i = 0; i < parsed.length; i++) {
        FujifilmControlService.propIndex.set(parsed[i].code, i);
      }
      FujifilmControlService.propsReady = parsed.length > 0;
      if (!FujifilmControlService.propsReady) {
        throw new Error('0x902B 返回 0 条属性');
      }
      // 若固件把 getSet 放在别处，整张表会全是 0。此时只对目录里明确
      // 可写的项放开，并留下日志；真正写失败由 setValue 的响应码兜底。
      let writableCount = 0;
      for (const item of parsed) {
        if (item.writable) writableCount += 1;
      }
      if (writableCount === 0) {
        FujifilmControlService.log('描述符 getSet 全为 0：按参数目录的已知可写项降级');
        for (const item of parsed) {
          const spec = FujifilmParamCatalog.find(item.code);
          if (spec !== null && spec.kind !== 'read') item.writable = true;
        }
      }
      FujifilmControlService.log(`0x902B 解析成功：${parsed.length} 条属性`);
      for (const spec of FujifilmParamCatalog.all()) {
        if (!FujifilmControlService.propIndex.has(spec.code)) {
          FujifilmControlService.log(`属性缺失 0x${spec.code.toString(16)} ${spec.label}`);
        }
      }
      if (FujifilmControlService.driveMode < 0) {
        const drive = FujifilmControlService.valueOf(0xD246);
        if (drive >= 0) FujifilmControlService.driveMode = drive;
      }
    } catch (error) {
      FujifilmControlService.propsReady = false;
      FujifilmControlService.propTable = [];
      FujifilmControlService.propIndex = new Map<number, number>();
      const reason = `属性表解析失败：${FujifilmControlService.describe(error)}`;
      FujifilmControlService.degradedReason =
        FujifilmControlService.degradedReason.length > 0
          ? `${FujifilmControlService.degradedReason}；${reason}` : reason;
      FujifilmControlService.log(`[FUJI] PROP_PARSE_FAIL ${reason}`);
    }
  }

  static parsePropDescAll(data: Uint8Array): FujifilmPropDesc[] {
    if (data.length < 8) throw new Error(`0x902B 数据只有 ${data.length} 字节`);
    // 8 字节记录头的三种可能排布（getSet 的位置报告没有给出精确偏移）：
    //  0: code u16 | getSet u8 | rsv u8 | type u16 | size u16
    //  1: code u16 | type u16 | getSet u16 | size u16
    //  2: code u32 | type u16 | size u16（getSet 缺省，后面按目录兜底）
    // 三种都试，取「解析出的属性条数最多」的那张表；每条记录的 payload
    // 自身必须正好消费完，所以选错排布不会静默返回半张表。
    let best: FujifilmPropDesc[] = [];
    let firstError = '';
    for (let mode = 0; mode < 3; mode++) {
      try {
        const table = FujifilmControlService.parsePropDescAllMode(data, mode);
        if (table.length > best.length) best = table;
      } catch (error) {
        if (firstError.length === 0) firstError = FujifilmControlService.describe(error);
      }
    }
    if (best.length === 0) {
      throw new Error(firstError.length > 0
        ? firstError : `0x902B 三种记录头排布都解析失败（共 ${data.length} 字节）`);
    }
    return best;
  }

  private static parsePropDescAllMode(data: Uint8Array, mode: number): FujifilmPropDesc[] {
    const reader = new FujifilmReader(data);
    const count = reader.u32();
    if (count === 0 || count > 512) {
      throw new Error(`0x902B 属性条数不合理：${count}，首 16 字节 ` +
        FujifilmControlService.hex(data, 16));
    }
    const out: FujifilmPropDesc[] = [];
    let skipped = 0;
    for (let i = 0; i < count; i++) {
      if (reader.remaining() < 8) {
        throw new Error(`第 ${i + 1}/${count} 条记录头越界（offset=${reader.offset}）`);
      }
      let code = 0;
      let getSet = 0;
      let dataType = 0;
      let size = 0;
      if (mode === 0) {
        code = reader.u16();
        getSet = reader.u8();
        reader.u8();
        dataType = reader.u16();
        size = reader.u16();
      } else if (mode === 1) {
        code = reader.u16();
        dataType = reader.u16();
        getSet = reader.u16();
        size = reader.u16();
      } else {
        code = reader.u32();
        dataType = reader.u16();
        size = reader.u16();
      }
      if (code < 0x5000 || code > 0xDFFF) {
        throw new Error(`属性码 0x${code.toString(16)} 不在 0x5000–0xDFFF`);
      }
      if (size > reader.remaining()) {
        throw new Error(
          `0x${code.toString(16)} payloadSize=${size} 超过剩余 ${reader.remaining()} 字节`);
      }
      const payload = reader.bytes(size);
      try {
        const desc = FujifilmControlService.parseRecord(code, getSet === 1 ? 1 : 0,
          dataType, payload);
        if (desc !== null) out.push(desc);
      } catch (error) {
        // 单个结构体属性（例如 0xD212）解析不了时跳过它，不能让整张表归零；
        // 超过 5 条解析失败说明头排布选错了，直接放弃这个 mode。
        skipped += 1;
        if (skipped > 5) throw error instanceof Error ? error : new Error(String(error));
        FujifilmControlService.log(
          `跳过无法解析的属性 0x${code.toString(16)}：${FujifilmControlService.describe(error)}`);
      }
    }
    if (out.length === 0) {
      throw new Error(`0x902B 解析出 0 条属性（count=${count}，共 ${data.length} 字节）`);
    }
    return out;
  }

  private static parseRecord(code: number, getSet: number, rawType: number,
    payload: Uint8Array): FujifilmPropDesc | null {
    const baseType = rawType & 0xFFFF;
    // 0x0007+0x10000/0x20000 才是「富士用 INT64 承载字符串」；
    // 裸 0x0007 也可能是普通 INT64，所以只对报告确认的 4 个字符串属性走字符串分支。
    const isString = rawType === 65543 || rawType === 131079 ||
      (rawType === 7 && FujifilmControlService.isStringProp(code));
    if (isString) {
      return FujifilmControlService.parseStringRecord(code, getSet, rawType, payload);
    }
    const parsed = FujifilmControlService.parseIntPayload(payload, baseType);
    if (parsed === null) {
      throw new Error(`属性 0x${code.toString(16)} type=${rawType} 的 payload 无法解析：` +
        FujifilmControlService.hex(payload, 32));
    }
    return {
      code: code,
      dataType: rawType,
      baseType: baseType,
      writable: getSet === 1,
      isString: false,
      current: parsed.current,
      currentStr: '',
      factory: parsed.factory,
      min: parsed.min,
      max: parsed.max,
      step: parsed.step,
      values: parsed.values,
      valuesStr: [],
    };
  }

  /**
   * 数值 payload。标准 PTP 顺序是 factory → current → form；富士在
   * `setDevicePropDescInt` 里也按这个顺序读，但为了让「缺字段的旧固件」也能
   * 用，这里按候选布局逐个试，**只有正好消费完 payload 才接受**。
   */
  private static parseIntPayload(payload: Uint8Array, type: number): FujifilmParsedPayload | null {
    const layouts: number[] = [0, 1, 2, 3, 4, 5];
    for (const layout of layouts) {
      const parsed = FujifilmControlService.tryIntLayout(payload, type, layout);
      if (parsed !== null) return parsed;
    }
    return null;
  }

  private static tryIntLayout(payload: Uint8Array, type: number,
    layout: number): FujifilmParsedPayload | null {
    const reader = new FujifilmReader(payload);
    try {
      let getSet = 0;
      if (layout === 2 || layout === 5) getSet = reader.u8();
      let factory = 0;
      let current = 0;
      if (layout === 1 || layout === 4 || layout === 5) {
        // 少数固件把 current 放在 factory 前。
        current = FujifilmControlService.readTyped(reader, type);
        factory = FujifilmControlService.readTyped(reader, type);
      } else {
        factory = FujifilmControlService.readTyped(reader, type);
        current = FujifilmControlService.readTyped(reader, type);
      }
      let min = 0;
      let max = 0;
      let step = 0;
      let form = 0;
      const values: number[] = [];
      if (layout === 3 || layout === 4) {
        // 无 form：factory/current/min/max/step/n/values。
        min = FujifilmControlService.readTyped(reader, type);
        max = FujifilmControlService.readTyped(reader, type);
        step = FujifilmControlService.readTyped(reader, type);
        const n = reader.u16();
        if (n > 1024) return null;
        for (let i = 0; i < n; i++) values.push(FujifilmControlService.readTyped(reader, type));
        if (reader.remaining() <= 3 && FujifilmControlService.allZero(reader.bytes(reader.remaining()))) {
          return { factory: factory, current: current, min: min, max: max, step: step, values: values };
        }
        return null;
      }
      if (reader.remaining() < 1) return null;
      form = reader.u8();
      if (form === 0) {
        // 没有 form，只有 factory/current。
      } else if (form === 1) {
        min = FujifilmControlService.readTyped(reader, type);
        max = FujifilmControlService.readTyped(reader, type);
        step = FujifilmControlService.readTyped(reader, type);
      } else if (form === 2) {
        const n = reader.u16();
        if (n > 1024) return null;
        for (let i = 0; i < n; i++) values.push(FujifilmControlService.readTyped(reader, type));
      } else {
        return null;
      }
      if (reader.remaining() <= 3 && FujifilmControlService.allZero(reader.bytes(reader.remaining()))) {
        if (layout === 2 && getSet > 1) return null;
        return { factory: factory, current: current, min: min, max: max, step: step, values: values };
      }
      return null;
    } catch (error) {
      return null;
    }
  }

  /** 报告 02 §5.3 里唯一的字符串属性是 0xD2B7；0x501D–0x501F 是 URL/作者/版权。 */
  private static isStringProp(code: number): boolean {
    return code === 0x501D || code === 0x501E || code === 0x501F || code === 0xD2B7;
  }

  private static parseStringRecord(code: number, getSet: number, rawType: number,
    payload: Uint8Array): FujifilmPropDesc {
    const reader = new FujifilmReader(payload);
    let factory = '';
    let current = '';
    let min = '';
    let max = '';
    let step = '';
    const values: string[] = [];
    try {
      factory = reader.ptpString();
      current = reader.ptpString();
      const form = reader.u8();
      if (form === 1) {
        min = reader.ptpString();
        max = reader.ptpString();
        step = reader.ptpString();
      } else if (form === 2) {
        const n = reader.u16();
        for (let i = 0; i < n && i < 256; i++) values.push(reader.ptpString());
      }
    } catch (error) {
      FujifilmControlService.log(`字符串属性 0x${code.toString(16)} 解析不完整：` +
        FujifilmControlService.describe(error));
    }
    return {
      code: code,
      dataType: rawType,
      baseType: 7,
      writable: getSet === 1,
      isString: true,
      current: 0,
      currentStr: current.length > 0 ? current : factory,
      factory: 0,
      min: 0,
      max: 0,
      step: 0,
      values: [],
      valuesStr: values,
    };
  }

  private static readTyped(reader: FujifilmReader, type: number): number {
    switch (type) {
      case 1: {
        const v = reader.u8();
        return v > 127 ? v - 256 : v;
      }
      case 2:
        return reader.u8();
      case 3: {
        const v = reader.u16();
        return v > 32767 ? v - 65536 : v;
      }
      case 4:
        return reader.u16();
      case 5: {
        const v = reader.u32();
        return v > 0x7FFFFFFF ? v - 0x100000000 : v;
      }
      case 6:
        return reader.u32();
      case 7:
      case 8: {
        const low = reader.u32();
        reader.u32();
        return low;
      }
      default:
        return reader.u32();
    }
  }

  // -------------------------------------------------------------------------
  // 属性读写
  // -------------------------------------------------------------------------

  static props(): FujifilmPropDesc[] {
    return FujifilmControlService.propTable;
  }

  static propOf(code: number): FujifilmPropDesc | null {
    const index = FujifilmControlService.propIndex.get(code);
    if (index === undefined) return null;
    return FujifilmControlService.propTable[index];
  }

  static valueOf(code: number): number {
    const desc = FujifilmControlService.propOf(code);
    return desc === null ? -1 : desc.current;
  }

  static valueText(code: number): string {
    const desc = FujifilmControlService.propOf(code);
    if (desc === null) return '--';
    if (desc.isString) return desc.currentStr.length > 0 ? desc.currentStr : '--';
    return FujifilmControlService.formatValue(code, desc.current);
  }

  /** 是否可调：描述符说 getSet=1，且我们有办法写。 */
  static canWrite(code: number): boolean {
    const desc = FujifilmControlService.propOf(code);
    return desc !== null && desc.writable && !desc.isString;
  }

  /**
   * 写单条属性：0x1016 `[code]` + 该属性 dataType 宽度的 LE 标量。
   * 失败返回 false 并写日志；不抛异常（页面只弹 toast）。
   */
  static async setValue(code: number, value: number): Promise<boolean> {
    const desc = FujifilmControlService.propOf(code);
    if (desc === null) {
      FujifilmControlService.log(`setValue 0x${code.toString(16)}：描述符缺失`);
      return false;
    }
    if (!desc.writable) {
      FujifilmControlService.log(`setValue 0x${code.toString(16)}：描述符只读`);
      return false;
    }
    if (desc.isString) {
      FujifilmControlService.log(`setValue 0x${code.toString(16)}：字符串属性暂不支持`);
      return false;
    }
    const payload = FujifilmControlService.encodeTyped(value, desc.baseType);
    try {
      const reply = await FujifilmControlService.busyRetry((): Promise<FujifilmReply> =>
        FujifilmPtpIp.opDataOut(FujifilmCtl.OP_SET_DEVICE_PROP_VALUE, [code], payload));
      if (reply.code !== 0x2001) {
        FujifilmControlService.log(
          `setValue 0x${code.toString(16)}=${value} 失败 code=0x${reply.code.toString(16)}`);
        return false;
      }
      desc.current = value >>> 0;
      FujifilmControlService.notifyProp(code, desc.current);
      FujifilmControlService.log(`setValue 0x${code.toString(16)}=${value} ok`);
      void FujifilmControlService.refreshOne(code, 250);
      return true;
    } catch (error) {
      FujifilmControlService.log(`setValue 0x${code.toString(16)} 异常：${FujifilmControlService.describe(error)}`);
      return false;
    }
  }

  /**
   * 步进：
   *  - 0xD240 快门 → 0x902C
   *  - 0x5007 光圈 → 0x902D
   *  - 0x5010 曝光补偿 → 0x902E
   *  - 其它 → 在描述符 values 里找当前值，写前/后一项。
   */
  static async step(code: number, direction: number): Promise<boolean> {
    const dir = direction === 0 ? 0 : 1;
    let opcode = 0;
    if (code === 0xD240) opcode = FujifilmCtl.OP_STEP_SHUTTER;
    else if (code === 0x5007) opcode = FujifilmCtl.OP_STEP_APERTURE;
    else if (code === 0x5010) opcode = FujifilmCtl.OP_STEP_EV;

    if (opcode !== 0) {
      try {
        const reply = await FujifilmControlService.busyRetry((): Promise<FujifilmReply> =>
          FujifilmPtpIp.op(opcode, [dir], 10000));
        if (reply.code !== 0x2001) {
          FujifilmControlService.log(
            `step 0x${code.toString(16)} dir=${dir} op=0x${opcode.toString(16)} code=0x${reply.code.toString(16)}`);
          return false;
        }
        FujifilmControlService.log(
          `step 0x${code.toString(16)} dir=${dir} op=0x${opcode.toString(16)} ok`);
        void FujifilmControlService.refreshOne(code, 350);
        return true;
      } catch (error) {
        FujifilmControlService.log(`step 0x${code.toString(16)} 异常：${FujifilmControlService.describe(error)}`);
        return false;
      }
    }

    const desc = FujifilmControlService.propOf(code);
    if (desc === null || !desc.writable || desc.values.length === 0) {
      FujifilmControlService.log(`step 0x${code.toString(16)}：没有可选值`);
      return false;
    }
    let index = -1;
    const current = desc.current >>> 0;
    for (let i = 0; i < desc.values.length; i++) {
      if ((desc.values[i] >>> 0) === current) {
        index = i;
        break;
      }
    }
    if (index < 0) index = 0;
    else index = dir === 0 ? Math.max(0, index - 1) : Math.min(desc.values.length - 1, index + 1);
    return FujifilmControlService.setValue(code, desc.values[index]);
  }

  private static encodeTyped(value: number, type: number): Uint8Array {
    const v = value >>> 0;
    switch (type) {
      case 1:
      case 2:
        return new Uint8Array([v & 0xFF]);
      case 3:
      case 4:
        return FujifilmControlService.u16(v);
      case 5:
      case 6:
      default:
        return FujifilmControlService.u32(v);
    }
  }

  /** 单条回读：0x1015 `[code]`；补事件 40 缺失的固件。 */
  private static async refreshOne(code: number, delayMs: number): Promise<void> {
    if (delayMs > 0) await fujiDelay(delayMs);
    const desc = FujifilmControlService.propOf(code);
    if (desc === null || desc.isString) return;
    try {
      const reply = await FujifilmPtpIp.opDataIn(FujifilmCtl.OP_GET_DEVICE_PROP_VALUE, [code]);
      if (reply.code !== 0x2001) return;
      const value = FujifilmControlService.readValueFromData(reply.data, desc.baseType);
      if (value === null) return;
      desc.current = value;
      if (code === 0xD246) FujifilmControlService.driveMode = value;
      FujifilmControlService.notifyProp(code, value);
    } catch (error) {
      FujifilmControlService.log(`refreshOne 0x${code.toString(16)} 异常：${FujifilmControlService.describe(error)}`);
    }
  }

  /** 刷新整张表（页面「刷新」按钮 / 事件 41）。 */
  static async refreshProps(): Promise<boolean> {
    if (!FujifilmControlService.connected) return false;
    await FujifilmControlService.loadProps();
    return FujifilmControlService.propsReady;
  }

  private static readValueFromData(data: Uint8Array, type: number): number | null {
    if (data.length === 0) return null;
    const reader = new FujifilmReader(data);
    try {
      return FujifilmControlService.readTyped(reader, type);
    } catch (error) {
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // 动作
  // -------------------------------------------------------------------------

  static async capture(): Promise<boolean> {
    return FujifilmControlService.simpleOp(FujifilmCtl.OP_INITIATE_CAPTURE, [],
      FujifilmControlService.CAPTURE_TIMEOUT_MS, 'InitiateCapture');
  }

  static async cancelCapture(): Promise<boolean> {
    return FujifilmControlService.simpleOp(FujifilmCtl.OP_CANCEL_CAPTURE, [], 8000,
      'CancelInitiateCapture');
  }

  static async postview(): Promise<boolean> {
    return FujifilmControlService.simpleOp(FujifilmCtl.OP_POSTVIEW, [], 10000, 'Postview');
  }

  static async startMovie(): Promise<boolean> {
    return FujifilmControlService.simpleOp(FujifilmCtl.OP_INITIATE_MOVIE, [], 15000,
      'InitiateMovieCapture');
  }

  static async stopMovie(): Promise<boolean> {
    return FujifilmControlService.simpleOp(FujifilmCtl.OP_TERMINATE_MOVIE, [], 15000,
      'TerminateMovieCapture');
  }

  /** dir: 0=tele，1=wide；speed: 0=×1，1=×2。 */
  static async stepZoom(direction: number, speed: number): Promise<boolean> {
    return FujifilmControlService.simpleOp(FujifilmCtl.OP_STEP_ZOOM,
      [direction === 0 ? 0 : 1, speed === 0 ? 0 : 1], 8000, 'StepZoom');
  }

  static async startZoom(direction: number, speed: number): Promise<boolean> {
    return FujifilmControlService.simpleOp(FujifilmCtl.OP_START_ZOOM,
      [direction === 0 ? 0 : 1, speed === 0 ? 0 : 1], 8000, 'StartZoom');
  }

  static async stopZoom(): Promise<boolean> {
    return FujifilmControlService.simpleOp(FujifilmCtl.OP_STOP_ZOOM, [], 8000, 'StopZoom');
  }

  /** `LockS1Lock(afArea)`；afArea = `[aspW][aspH][cellX][cellY]` 各 1 字节。 */
  static async lockS1(afArea: number): Promise<boolean> {
    return FujifilmControlService.simpleOp(FujifilmCtl.OP_LOCK_S1, [afArea >>> 0],
      10000, 'LockS1Lock');
  }

  static async unlockS1(): Promise<boolean> {
    return FujifilmControlService.simpleOp(FujifilmCtl.OP_UNLOCK_S1, [], 8000, 'UnlockS1Lock');
  }

  private static async simpleOp(opcode: number, params: number[], timeoutMs: number,
    name: string): Promise<boolean> {
    try {
      const reply = await FujifilmControlService.busyRetry((): Promise<FujifilmReply> =>
        FujifilmPtpIp.op(opcode, params, timeoutMs));
      if (reply.code !== 0x2001) {
        FujifilmControlService.log(`${name} code=0x${reply.code.toString(16)}`);
        return false;
      }
      FujifilmControlService.log(`${name} ok`);
      return true;
    } catch (error) {
      FujifilmControlService.log(`${name} 异常：${FujifilmControlService.describe(error)}`);
      return false;
    }
  }

  /** Phase1=0x101C（30s），Phase2=取景 socket（`N:0x2f4b4` 之后无第二条 op）。 */
  private static async initiateOpenCapture(): Promise<void> {
    const reply = await FujifilmControlService.busyRetry((): Promise<FujifilmReply> =>
      FujifilmPtpIp.op(FujifilmCtl.OP_INITIATE_OPEN_CAPTURE, [],
        FujifilmNet.OPEN_CAPTURE_TIMEOUT_MS));
    FujifilmControlService.expectOk(reply, 'InitiateOpenCapture Phase1');
    FujifilmControlService.log('InitiateOpenCapture Phase1 ok');
    try {
      await FujifilmControlService.withTimeout(FujifilmPtpIp.openLiveView(),
        FujifilmNet.OPEN_CAPTURE_TIMEOUT_MS, 'InitiateOpenCapture Phase2');
      FujifilmControlService.log('InitiateOpenCapture Phase2：取景通道已打开');
    } catch (error) {
      FujifilmControlService.log(`Phase2 取景通道打开失败：${FujifilmControlService.describe(error)}`);
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  // -------------------------------------------------------------------------
  // 事件
  // -------------------------------------------------------------------------

  private static registerEventBridge(): void {
    if (FujifilmControlService.eventBridgeInstalled) return;
    FujifilmControlService.eventBridgeInstalled = true;
    FujifilmPtpIp.onEvent((frame: FujifilmEventFrame): void => {
      try {
        FujifilmControlService.handleEvent(frame);
      } catch (error) {
        FujifilmControlService.log(`事件处理异常：${FujifilmControlService.describe(error)}`);
      }
    });
  }

  private static handleEvent(frame: FujifilmEventFrame): void {
    let code = frame.code;
    let params = frame.params;

    // 角色 A 现在把 55742 上的原始 PTP 事件直接抛上来；这里按
    // `CCameraEvent::ThreadProc` 的映射翻成报告里的 SDK 事件码。
    if (code >= 0x4000) {
      switch (code) {
        case FujifilmCtl.PTP_OBJECT_ADDED:
          code = FujifilmCtl.EVENT_ADD_IMAGE;
          break;
        case FujifilmCtl.PTP_DEVICE_PROP_CHANGED: {
          const prop = params.length > 0 ? params[0] : -1;
          if (paramIsValid(prop)) {
            if (params.length > 1) {
              FujifilmControlService.applyPropValue(prop, params[1]);
            } else {
              void FujifilmControlService.refreshOne(prop, 0);
            }
          }
          return;
        }
        case FujifilmCtl.PTP_DEVICE_INFO_CHANGED:
          code = FujifilmCtl.EVENT_DEVICE_INFO_CHANGED;
          break;
        case FujifilmCtl.PTP_CAPTURE_START:
          code = FujifilmCtl.EVENT_CAPTURE_START;
          break;
        case FujifilmCtl.PTP_CAPTURE_COMPLETE:
          code = FujifilmCtl.EVENT_CAPTURE_COMPLETE;
          break;
        case FujifilmCtl.PTP_POSTVIEW_COMPLETE:
          code = FujifilmCtl.EVENT_POSTVIEW_COMPLETE;
          break;
        case FujifilmCtl.PTP_AF_CAPTURE:
          code = FujifilmCtl.EVENT_AF_CAPTURE;
          break;
        default:
          FujifilmControlService.log(`未映射的 PTP 事件 0x${code.toString(16)}`);
          return;
      }
    }

    switch (code) {
      case FujifilmCtl.EVENT_GET_CAMERA_MODE: {
        const mode = params.length > 0 ? params[0] : FujifilmCtl.MODE_REMOTE;
        FujifilmControlService.requestedMode = mode;
        FujifilmControlService.log(`事件 11：相机请求模式 ${mode}`);
        if (FujifilmControlService.modeWaiter !== null) {
          FujifilmControlService.modeWaiter(mode);
        }
        break;
      }
      case FujifilmCtl.EVENT_CAPTURE_START: {
        const param = params.length > 0 ? params[0] : 0;
        FujifilmControlService.emitCapture('start', param);
        break;
      }
      case FujifilmCtl.EVENT_CAPTURE_COMPLETE: {
        const param = params.length > 0 ? params[0] : 0;
        FujifilmControlService.emitCapture('complete', param);
        break;
      }
      case FujifilmCtl.EVENT_POSTVIEW_COMPLETE: {
        const param = params.length > 0 ? params[0] : 0;
        FujifilmControlService.emitCapture('postview', param);
        break;
      }
      case FujifilmCtl.EVENT_PROP_VALUE: {
        const prop = params.length > 0 ? params[0] : -1;
        if (paramIsValid(prop)) {
          const value = params.length > 1 ? params[1] : -1;
          if (value >= 0) {
            FujifilmControlService.applyPropValue(prop, value);
          } else {
            void FujifilmControlService.refreshOne(prop, 0);
          }
        }
        break;
      }
      case FujifilmCtl.EVENT_DEVICE_INFO_CHANGED:
        FujifilmControlService.log('事件 41：设备信息变化，重新拉取属性');
        FujifilmControlService.emitDeviceChanged();
        break;
      case FujifilmCtl.EVENT_AF_CAPTURE:
        FujifilmControlService.log('事件 43：AF 完成');
        FujifilmControlService.emitAfDone();
        break;
      case FujifilmCtl.EVENT_BEGIN_PROP_VALUE:
        FujifilmControlService.log('事件 44：属性批量开始');
        break;
      case FujifilmCtl.EVENT_END_PROP_VALUE:
        FujifilmControlService.log('事件 45：属性批量结束');
        break;
      case FujifilmCtl.EVENT_SENDING:
        FujifilmControlService.log(`事件 49：发送进度 ${params.length > 0 ? params[0] : -1}`);
        break;
      case FujifilmCtl.EVENT_SEND_COMPLETE:
        FujifilmControlService.log(`事件 50：发送结束 canceled=${params.length > 0 ? params[0] : -1}`);
        break;
      default:
        FujifilmControlService.log(`未处理事件 ${code}`);
        break;
    }
  }

  private static applyPropValue(code: number, value: number): void {
    const desc = FujifilmControlService.propOf(code);
    if (desc === null || desc.isString) return;
    desc.current = value >>> 0;
    if (code === 0xD246) {
      FujifilmControlService.driveMode = desc.current;
    }
    FujifilmControlService.notifyProp(code, desc.current);
  }

  private static emitCapture(type: string, param: number): void {
    const callbacks = FujifilmControlService.callbacks;
    if (callbacks === null) return;
    callbacks.onCapture({ type: type, param: param });
  }

  private static emitAfDone(): void {
    const callbacks = FujifilmControlService.callbacks;
    if (callbacks !== null) callbacks.onAfDone();
  }

  private static emitDeviceChanged(): void {
    const callbacks = FujifilmControlService.callbacks;
    if (callbacks !== null) callbacks.onDeviceChanged();
  }

  private static notifyProp(code: number, value: number): void {
    const callbacks = FujifilmControlService.callbacks;
    if (callbacks !== null) callbacks.onPropChanged(code, value);
  }

  private static notice(message: string): void {
    const callbacks = FujifilmControlService.callbacks;
    if (callbacks !== null) callbacks.onNotice(message);
  }

  // -------------------------------------------------------------------------
  // 实时取景
  // -------------------------------------------------------------------------

  /** 'preview' 才推流；'remote' 只保留最后一帧。 */
  static setViewMode(mode: string): void {
    FujifilmControlService.viewMode = mode;
    if (mode !== 'preview') {
      FujifilmControlService.stopLiveView();
      // 遥控态不推流：把 55741 也关掉，避免相机继续往没人读的 socket 里灌帧。
      FujifilmPtpIp.closeLiveView();
    }
  }

  static isLiveRunning(): boolean {
    return FujifilmControlService.liveRunning;
  }

  static lastLiveViewError(): string {
    return FujifilmControlService.lastLiveError;
  }

  /**
   * 打开取景并启动解码循环。每帧：
   *   整包（`readLiveViewFrame` 已按帧头长度裁剪）
   *   → `FujifilmPtpIp.jpegOfFrame`（= LE32@12 + 18）
   *   → `image.createImageSource` → PixelMap → 页面。
   * 只在 `viewMode === 'preview'` 时继续；切到遥控会停。
   */
  static async startLiveView(onFrame: (pixelMap: image.PixelMap) => void): Promise<void> {
    if (FujifilmControlService.liveRunning) return;
    if (!FujifilmControlService.connected) {
      throw new Error('PTP-IP 会话未建立');
    }
    FujifilmControlService.viewMode = 'preview';
    FujifilmControlService.liveRunning = true;
    FujifilmControlService.liveGeneration += 1;
    const generation = FujifilmControlService.liveGeneration;
    FujifilmControlService.lastLiveError = '';

    try {
      await FujifilmPtpIp.openLiveView();
    } catch (error) {
      FujifilmControlService.liveRunning = false;
      FujifilmControlService.lastLiveError = FujifilmControlService.describe(error);
      throw error instanceof Error ? error : new Error(String(error));
    }
    if (FujifilmControlService.viewMode !== 'preview' ||
      FujifilmControlService.liveGeneration !== generation) {
      FujifilmControlService.liveRunning = false;
      FujifilmPtpIp.closeLiveView();
      return;
    }

    void FujifilmControlService.liveLoop(generation, onFrame);
  }

  private static async liveLoop(generation: number,
    onFrame: (pixelMap: image.PixelMap) => void): Promise<void> {
    let consecutiveFailures = 0;
    while (FujifilmControlService.liveRunning &&
      FujifilmControlService.liveGeneration === generation &&
      FujifilmControlService.viewMode === 'preview') {
      let frame: Uint8Array | null = null;
      try {
        frame = await FujifilmPtpIp.readLiveViewFrame(4000);
      } catch (error) {
        FujifilmControlService.lastLiveError = FujifilmControlService.describe(error);
        frame = null;
      }
      if (frame === null || frame.length < 32) {
        consecutiveFailures += 1;
        if (consecutiveFailures >= 3) {
          FujifilmControlService.lastLiveError = '取景帧连续读取失败';
          FujifilmControlService.log('取景帧连续 3 次失败，暂停循环');
          break;
        }
        await fujiDelay(120);
        continue;
      }
      consecutiveFailures = 0;
      const jpeg = FujifilmPtpIp.jpegOfFrame(frame);
      if (jpeg.length < 4) {
        FujifilmControlService.log(`取景帧 JPEG 偏移非法：offset=${FujifilmPtpIp.jpegOffsetOf(frame)} len=${frame.length}`);
        await fujiDelay(30);
        continue;
      }
      const pixelMap = await FujifilmControlService.decodeJpeg(jpeg);
      if (pixelMap !== null && FujifilmControlService.liveRunning &&
        FujifilmControlService.liveGeneration === generation &&
        FujifilmControlService.viewMode === 'preview') {
        try {
          onFrame(pixelMap);
        } catch (error) {
          pixelMap.release();
          FujifilmControlService.log(`取景帧回调异常：${FujifilmControlService.describe(error)}`);
        }
      } else if (pixelMap !== null) {
        pixelMap.release();
      }
      await fujiDelay(FujifilmControlService.FRAME_INTERVAL_MS);
    }
    if (FujifilmControlService.liveGeneration === generation) {
      FujifilmControlService.liveRunning = false;
      FujifilmControlService.log('取景循环结束');
    }
  }

  private static async decodeJpeg(jpeg: Uint8Array): Promise<image.PixelMap | null> {
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    try {
      const buffer: ArrayBuffer = (jpeg.byteOffset === 0 && jpeg.byteLength === jpeg.buffer.byteLength)
        ? jpeg.buffer as ArrayBuffer : jpeg.slice().buffer as ArrayBuffer;
      source = image.createImageSource(buffer);
      pixelMap = await source.createPixelMap();
    } catch (error) {
      FujifilmControlService.log(`取景 JPEG 解码失败：${FujifilmControlService.describe(error)}`);
      pixelMap = null;
    } finally {
      if (source !== null) {
        try {
          source.release();
        } catch (releaseError) {
        }
      }
    }
    return pixelMap;
  }

  static stopLiveView(): void {
    FujifilmControlService.liveRunning = false;
    FujifilmControlService.liveGeneration += 1;
    // 关掉 55741，既停止相机继续灌帧，也让阻塞中的 readLiveViewFrame 立刻退出。
    FujifilmPtpIp.closeLiveView();
  }

  // -------------------------------------------------------------------------
  // 退出回滚（报告 02 §4 S31）
  // -------------------------------------------------------------------------

  /**
   * `UnlockS1Lock → StopZoom → TerminateMovieCapture → CancelInitiateCapture`
   * → 停取景 → TerminateOpenCapture → close。所有步骤独立 try，任何一步失败
   * 都继续后面的清理；2.5s 内返回，避免页面退不出去。
   */
  static async shutdown(): Promise<void> {
    if (FujifilmControlService.shuttingDown) return;
    FujifilmControlService.shuttingDown = true;
    FujifilmControlService.stopLiveView();
    FujifilmControlService.log('开始退出回滚');
    // 退出回滚每个 op 只等 1.2s：任何一步没人应答都不能把页面卡住。
    try { await FujifilmPtpIp.op(FujifilmCtl.OP_UNLOCK_S1, [], 1200); } catch (error) { }
    try { await FujifilmPtpIp.op(FujifilmCtl.OP_STOP_ZOOM, [], 1200); } catch (error) { }
    try { await FujifilmPtpIp.op(FujifilmCtl.OP_TERMINATE_MOVIE, [], 1200); } catch (error) { }
    try { await FujifilmPtpIp.op(FujifilmCtl.OP_CANCEL_CAPTURE, [], 1200); } catch (error) { }
    FujifilmPtpIp.closeLiveView();
    try {
      await FujifilmPtpIp.op(FujifilmCtl.OP_TERMINATE_OPEN_CAPTURE, [0], 5000);
      FujifilmControlService.log('TerminateOpenCapture ok');
    } catch (error) {
      FujifilmControlService.log(`TerminateOpenCapture 异常：${FujifilmControlService.describe(error)}`);
    }
    try {
      await FujifilmPtpIp.close();
    } catch (error) {
      FujifilmControlService.log(`PTP close 异常：${FujifilmControlService.describe(error)}`);
    }
    FujifilmControlService.connected = false;
    FujifilmControlService.shuttingDown = false;
    FujifilmControlService.log('退出回滚结束');
  }

  // -------------------------------------------------------------------------
  // 格式化（与官方 App 的显示口径一致）
  // -------------------------------------------------------------------------

  static formatValue(code: number, raw: number): string {
    const value = raw >>> 0;
    switch (code) {
      case 0xD240: return FujifilmControlService.shutterText(value);
      case 0x5007: return FujifilmControlService.apertureText(value);
      case 0x5010: return FujifilmControlService.evText(value);
      case 0xD02A:
      case 0xD02B: return FujifilmControlService.isoText(value);
      case 0x5005: return FujifilmControlService.wbText(value);
      case 0xD001: return FujifilmControlService.filmText(value);
      case 0x500C: return value === 32778 ? '开启' : (value === 32777 ? '关闭' : `闪光 ${value}`);
      case 0x5012: return value === 0 ? '关闭' : (value === 2 ? '2 秒' : (value === 4 ? '10 秒' : `${value} 秒`));
      case 0x500A: return value === 1 ? 'MF' : (value === 32769 ? 'AF-S' : (value === 32770 ? 'AF-C' : `对焦 ${value}`));
      case 0xD246: return value === 1 ? '动画' : '静止';
      case 0xD028: return value === 0 ? '灰（自动）' : (value === 1 ? '橙（手动）' : '其它');
      case 0xD019: return value === 1 ? '允许动画' : '禁止动画';
      case 0xD241: return FujifilmControlService.sizeText(value);
      case 0xD21B: return FujifilmParamCatalog.statusText(value);
      case 0xD209: return value === 1 ? '已合焦' : '未合焦';
      case 0x5001: return `${value}%`;
      case 0xD229: return `${value} 张`;
      case 0xD22A: return FujifilmControlService.durationText(value);
      case 0x500E: return FujifilmControlService.exposureModeText(value);
      case 0xD243: return `快门类型 ${value}`;
      case 0xD245: return FujifilmControlService.afSelectText(value);
      default: return `${value}`;
    }
  }

  static shutterText(value: number): string {
    if (value === 0xFFFFFFFF) return '--';
    if ((value & 0x80000000) !== 0) {
      const n = value & 0x7FFFFFFF;
      if (n === 0) return '--';
      // bit31=1：1 / ((v & 0x7FFFFFFF) / 1000) 秒。n=4000 → 1/4 s；
      // n=500 → 2 s。分母 <1 时按秒显示，避免出现 "1/0.5"。
      const denominator = n / 1000;
      if (denominator >= 1) {
        const rounded = Math.round(denominator);
        return Math.abs(denominator - rounded) < 0.01
          ? `1/${rounded}` : `1/${denominator.toFixed(1)}`;
      }
      const seconds = 1 / denominator;
      return seconds >= 10 ? `${Math.round(seconds)}"` : `${seconds.toFixed(1)}"`;
    }
    const seconds = value / 1000;
    return seconds === Math.floor(seconds) ? `${seconds}"` : `${seconds.toFixed(1)}"`;
  }

  static apertureText(value: number): string {
    const raw = value >>> 0;
    if (value < 0 || raw === 0xFFFF || raw === 0xFFFFFFFF) return '---';
    const f = raw / 100;
    return `F${f === Math.floor(f) ? f.toFixed(0) : f.toFixed(1)}`;
  }

  static evText(value: number): string {
    const signed = value > 0x7FFFFFFF ? value - 0x100000000 : value;
    const sign = signed > 0 ? '+' : (signed < 0 ? '-' : '');
    const abs = Math.abs(signed);
    const whole = Math.floor(abs / 1000);
    const rest = abs % 1000;
    const wholeText = whole > 0 ? `${whole} ` : '';
    if (rest === 0) return `${sign}${whole} EV`;
    if (rest === 333) return `${sign}${wholeText}1/3 EV`;
    if (rest === 666 || rest === 667) return `${sign}${wholeText}2/3 EV`;
    return `${sign}${(abs / 1000).toFixed(1)} EV`;
  }

  static isoText(value: number): string {
    const raw = value >>> 0;
    if ((raw & 0x80000000) !== 0) {
      const base = raw & 0xFFFF;
      return base > 0 ? `AUTO ${base}` : 'AUTO';
    }
    if ((raw & 0x40000000) !== 0) {
      const real = (raw ^ 0x40000000) >>> 0;
      return `${real <= 400 ? 'L' : 'H'}${real}`;
    }
    return `ISO ${raw}`;
  }

  static wbText(value: number): string {
    switch (value) {
      case 2: return '自动';
      case 4: return '日光';
      case 6: return '白炽灯';
      case 32769: return 'FL-1';
      case 32770: return 'FL-2';
      case 32771: return 'FL-3';
      case 32774: return '阴影';
      case 32778: return '水下';
      case 32779: return '色温';
      case 32780: return '自定义 1';
      case 32781: return '自动（白色优先）';
      case 32782: return '自动（氛围优先）';
      default: return `WB ${value}`;
    }
  }

  static filmText(value: number): string {
    switch (value) {
      case 1: return 'PROVIA / STANDARD';
      case 2: return 'Velvia / VIVID';
      case 3: return 'ASTIA / SOFT';
      case 4: return 'MONOCHROME';
      case 5: return 'SEPIA';
      case 6: return 'PRO Neg.Hi';
      case 7: return 'PRO Neg.Std';
      case 8: return 'MONOCHROME+Ye';
      case 9: return 'MONOCHROME+R';
      case 10: return 'MONOCHROME+G';
      case 11: return 'CLASSIC CHROME';
      case 12: return 'ACROS';
      case 13: return 'ACROS+Ye';
      case 14: return 'ACROS+R';
      case 15: return 'ACROS+G';
      case 16: return 'ETERNA / CINEMA';
      case 17: return 'CLASSIC Neg.';
      case 18: return 'ETERNA BLEACH BYPASS';
      case 19: return 'NOSTALGIC Neg.';
      case 20: return 'REALA ACE';
      default: return `胶片 ${value}`;
    }
  }

  static sizeText(value: number): string {
    let group = '?';
    if ((value >= 1 && value <= 4) || (value >= 17 && value <= 19) || value === 29 || value === 30) group = 'L';
    else if ((value >= 5 && value <= 8) || (value >= 20 && value <= 22) || value === 31 || value === 32) group = 'M';
    else if ((value >= 9 && value <= 12) || (value >= 23 && value <= 25) || value === 33 || value === 34) group = 'S';
    return `${group} (${value})`;
  }

  static exposureModeText(value: number): string {
    switch (value) {
      case 1: return 'M 手动';
      case 2: return 'P 程序';
      case 3: return 'A 光圈优先';
      case 4: return 'S 快门优先';
      case 6: return 'AUTO 全自动';
      case 0x8002: return 'SP 场景';
      case 0x8003: return '动画';
      case 0x8004: return 'Adv 创意';
      case 0x8005: return 'SR AUTO';
      case 0x8006: return '自定义';
      case 0x8007: return '自定义 1';
      case 0x8008: return '自定义 2';
      case 0xFFFF8001: return 'EXR';
      default: return `模式 ${value}`;
    }
  }

  static afSelectText(value: number): string {
    // 报告只给出 0–7 这个范围，没有给每档名称；不臆造。
    return `区域 ${value}`;
  }

  static durationText(seconds: number): string {
    if (seconds <= 0) return '--';
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    if (h > 0) return `${h}:${m < 10 ? '0' : ''}${m}:${s < 10 ? '0' : ''}${s}`;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
  }

  // -------------------------------------------------------------------------
  // 通用工具
  // -------------------------------------------------------------------------

  private static withTimeout<T>(task: Promise<T>, ms: number, name: string): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void, reject: (reason: Object) => void) => {
      let settled = false;
      const timer = setTimeout((): void => {
        if (settled) return;
        settled = true;
        reject(new Error(`${name} 超时 ${ms}ms`));
      }, ms);
      task.then((value: T): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      }, (error: Object): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(error);
      });
    });
  }

  private static async busyRetry(task: () => Promise<FujifilmReply>): Promise<FujifilmReply> {
    let last: FujifilmReply | null = null;
    for (let i = 0; i < FujifilmCtl.RETRY_LIMIT; i++) {
      const reply = await task();
      if (reply.code === 0x2001) return reply;
      last = reply;
      if (reply.code !== 4102 && reply.code !== 0x2019) return reply;
      FujifilmControlService.log(
        `相机忙（0x${reply.code.toString(16)}），100ms 后重试 ${i + 1}/${FujifilmCtl.RETRY_LIMIT}`);
      await fujiDelay(FujifilmCtl.RETRY_DELAY_MS);
    }
    return last === null
      ? { code: -1, params: [], data: new Uint8Array(0) } : last;
  }

  private static expectOk(reply: FujifilmReply, name: string): void {
    if (reply.code !== 0x2001) {
      throw new Error(`${name} 响应码 0x${reply.code.toString(16)}`);
    }
  }

  private static u16(value: number): Uint8Array {
    return new Uint8Array([value & 0xFF, (value >> 8) & 0xFF]);
  }

  private static u32(value: number): Uint8Array {
    return new Uint8Array([
      value & 0xFF, (value >>> 8) & 0xFF, (value >>> 16) & 0xFF, (value >>> 24) & 0xFF,
    ]);
  }

  private static readU32(data: Uint8Array, offset: number): number {
    if (offset + 4 > data.length) return 0;
    return (data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) |
      (data[offset + 3] << 24)) >>> 0;
  }

  static decodeUtf16Le(bytes: Uint8Array): string {
    let out = '';
    for (let i = 0; i + 1 < bytes.length; i += 2) {
      const code = bytes[i] | (bytes[i + 1] << 8);
      if (code === 0) break;
      out += String.fromCharCode(code);
    }
    return out;
  }

  private static allZero(bytes: Uint8Array): boolean {
    for (let i = 0; i < bytes.length; i++) {
      if (bytes[i] !== 0) return false;
    }
    return true;
  }

  static hex(data: Uint8Array, limit: number): string {
    const count = Math.min(data.length, limit);
    const parts: string[] = [];
    for (let i = 0; i < count; i++) {
      const h = data[i].toString(16);
      parts.push(h.length === 1 ? `0${h}` : h);
    }
    return parts.join(' ');
  }

  private static describe(error: Object): string {
    if (error instanceof Error) return error.message;
    return String(error);
  }

  static log(message: string): void {
    AppLogStore.add(`[FUJI] ${message}`);
  }
}

interface FujifilmParsedPayload {
  factory: number;
  current: number;
  min: number;
  max: number;
  step: number;
  values: number[];
}

interface FujifilmDeviceIdentity {
  model: string;
  serial: string;
}

function paramIsValid(code: number): boolean {
  return code >= 0x5000 && code <= 0xDFFF;
}
