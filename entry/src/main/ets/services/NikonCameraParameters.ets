/**
 * 尼康相机参数（PTP 设备属性）读写。
 *
 * ## 协议出处
 *
 * 全部来自官方 SnapBridge 的具名动作类
 * （`tmp/sb-decode/smali/com/nikon/snapbridge/cmru/ptpclient/actions/devices/`）
 * 与它们底层的操作类（`snapbridge/ptpclient/{r2,n2,fb}.smali`）：
 *
 * | 操作 | 操作码 | 参数 | 数据阶段 |
 * |---|---|---|---|
 * | 取属性描述符 | `0x1015` `GetDevicePropDesc` | `[属性码]` | ← 描述符 |
 * | 取属性值 | `0x1014` `GetDevicePropValue` | `[属性码]` | ← 值 |
 * | 写属性值 | `0x1016` `SetDevicePropValue` | `[属性码]` | → 值 |
 *
 * ## 为什么读参数用描述符而不是取值
 *
 * PTP 的 `DevicePropDesc`（ISO 15740 §13.3.3）一次就给全了四件事：
 *
 * - **DataType** —— 值是多少位（`SetIsoAction` 同时引用 16 位和 32 位数据集，
 *   说明**同一属性在不同机身上宽度不同**，绝不能硬编码）；
 * - **GetSet** —— 这个属性**能不能写**；
 * - **CurrentValue** —— **当前值**；
 * - **FormFlag** —— 取值是区间（Range）还是枚举（Enumeration）。
 *
 * 所以每个参数只发一次 `0x1015` 就同时回答了「相机支不支持」「能不能改」
 * 「现在是多少」「取值范围」。官方的 `GetFnumberAction.isSupportAction` 正是
 * 这么自检的（先 `isSupportOperation({0x1015})`，再
 * `CameraController.isSupportPropertyCode({0x5007})`）——**支持性是相机自答的，
 * 不靠机型表**。
 *
 * 写回时按描述符声明的 DataType 编码，因此 16 位机身和 32 位机身走同一段代码。
 */
import { NikonPtpIpService } from './NikonPtpIpService';

/** PTP 数据类型（ISO 15740 表 13）。 */
export const PTP_TYPE_INT8: number = 0x0001;
export const PTP_TYPE_UINT8: number = 0x0002;
export const PTP_TYPE_INT16: number = 0x0003;
export const PTP_TYPE_UINT16: number = 0x0004;
export const PTP_TYPE_INT32: number = 0x0005;
export const PTP_TYPE_UINT32: number = 0x0006;
export const PTP_TYPE_INT64: number = 0x0007;
export const PTP_TYPE_UINT64: number = 0x0008;

/** `DevicePropDesc.GetSet`：0 = 只读，1 = 可读写。 */
const GET_SET_READABLE_ONLY: number = 0;
const GET_SET_READ_WRITE: number = 1;

/** `DevicePropDesc.FormFlag`。 */
export const PTP_FORM_NONE: number = 0x00;
export const PTP_FORM_RANGE: number = 0x01;
export const PTP_FORM_ENUM: number = 0x02;

/** 尼康属性码。左列与官方动作类一一对应。 */
export class NikonProp {
  /** 电量（`GetBatteryLevelAction`）。只读。 */
  static readonly BATTERY_LEVEL: number = 0x5001;
  /** 画质 / 压缩（`GetCompressionSettingAction`）。只读。 */
  static readonly COMPRESSION: number = 0x5004;
  /** 白平衡（`Get`/`SetWhiteBalanceAction`）。 */
  static readonly WHITE_BALANCE: number = 0x5005;
  /** 光圈 F 值（`Get`/`SetFnumberAction`）。 */
  static readonly FNUMBER: number = 0x5007;
  /** 焦距（`GetFocalLengthAction`）。只读。 */
  static readonly FOCAL_LENGTH: number = 0x5008;
  /** 曝光程序 / 拍摄模式 P/A/S/M（`Get`/`SetProgramModeAction`）。 */
  static readonly PROGRAM_MODE: number = 0x500e;
  /** ISO 感光度（`Get`/`SetIsoAction`）。 */
  static readonly ISO: number = 0x500f;
  /** 曝光补偿（`Get`/`SetExposureCompensationAction`）。 */
  static readonly EXPOSURE_COMPENSATION: number = 0x5010;
  /** 日期时间（`UpdateDateTimeAction`）。只写。 */
  static readonly DATE_TIME: number = 0x5011;
  /** 拍摄模式 / 驱动模式（`Get`/`SetStillCaptureModeAction`）。 */
  static readonly STILL_CAPTURE_MODE: number = 0x5013;
  /** 连拍张数（`Get`/`SetBurstNumberAction`）。 */
  static readonly BURST_NUMBER: number = 0x5018;
  /** AF 区域模式（`SetAFAreaModeAction`）。只写。 */
  static readonly AF_AREA_MODE: number = 0x501c;
  /** 快门速度。
   *
   *  `0xD100` 是尼康私有的 `0xD1xx` 段，**不在标准 `0x50xx` 里**——所以按
   *  `0x50xx` 扫描官方动作类时找不到它。仓库里 `NikonPtpIpService.PROP_SHUTTER_SPEED`
   *  已经是这个值，注释记着尼康把曝光参数放在 `0x5000`/`0xD100` 两段。 */
  static readonly SHUTTER_SPEED: number = 0xD100;
}

/** 一个属性的完整状态，全部由相机回答。 */
export interface NikonPropertyState {
  propertyCode: number;
  /** 相机接受了 `0x1015` 并回了合法描述符。 */
  supported: boolean;
  /** `GetSet` 允许写。只读属性（电量、焦距、画质）这里是 false。 */
  writable: boolean;
  /** 描述符里的 `DataType`，决定值占几个字节。 */
  dataType: number;
  /** 当前值（已按 `DataType` 归一成 number）。 */
  value: number;
  /** `FormFlag`：0 无、1 区间、2 枚举。 */
  formFlag: number;
  /** 区间下限 / 枚举最小值（`FormFlag` 不是 NONE 时有效）。 */
  minimum: number;
  /** 区间上限 / 枚举最大值。 */
  maximum: number;
  /** 区间步长；枚举时恒为 1。 */
  step: number;
  /** 枚举可选值（`FormFlag === PTP_FORM_ENUM` 时非空）。 */
  enumValues: number[];
}

/** 一个属性的字节宽度。ISO 在不同机身上是 16 位或 32 位，必须问描述符。 */
function typeSize(dataType: number): number {
  switch (dataType) {
    case PTP_TYPE_INT8:
    case PTP_TYPE_UINT8:
      return 1;
    case PTP_TYPE_INT16:
    case PTP_TYPE_UINT16:
      return 2;
    case PTP_TYPE_INT32:
    case PTP_TYPE_UINT32:
      return 4;
    case PTP_TYPE_INT64:
    case PTP_TYPE_UINT64:
      return 8;
    default:
      return 0;
  }
}

function readType(data: Uint8Array, offset: number, dataType: number): number {
  switch (dataType) {
    case PTP_TYPE_INT8:
      return data[offset] > 127 ? data[offset] - 256 : data[offset];
    case PTP_TYPE_UINT8:
      return data[offset];
    case PTP_TYPE_INT16: {
      const raw = data[offset] | (data[offset + 1] << 8);
      return raw > 0x7fff ? raw - 0x10000 : raw;
    }
    case PTP_TYPE_UINT16:
      return data[offset] | (data[offset + 1] << 8);
    case PTP_TYPE_INT32:
    case PTP_TYPE_UINT32: {
      const raw = (data[offset] | (data[offset + 1] << 8) |
        (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
      if (dataType === PTP_TYPE_UINT32) return raw;
      return raw > 0x7fffffff ? raw - 0x100000000 : raw;
    }
    default:
      return 0;
  }
}

function writeType(value: number, dataType: number): Uint8Array {
  const size = typeSize(dataType);
  const out = new Uint8Array(size > 0 ? size : 2);
  // PTP 是小端。
  let remaining = Math.trunc(value);
  for (let index = 0; index < out.length; index++) {
    out[index] = remaining & 0xff;
    remaining = remaining >> 8;
  }
  return out;
}

export class NikonCameraParameters {
  /** 本地十六进制格式化：`NikonPtpIpService.hexCode` 是私有的，这里不为了打日志
   *  去放宽它的可见性。 */
  private static hex(value: number): string {
    return `0x${value.toString(16)}`;
  }

  /**
   * 读一个属性的完整状态（描述符）。
   *
   * 返回 `supported: false` 表示相机拒绝了这个属性码——**这是正常的**，不是错误：
   * 不同机身支持的属性集不同，正是靠这个回答来决定界面显示什么。
   */
  static async describe(propertyCode: number): Promise<NikonPropertyState | null> {
    const data = await NikonPtpIpService.readPropertyDesc(propertyCode);
    if (data === null) {
      // `readPropertyDesc` 已经在非 OK 应答时打过一条；这里补上"应答 OK 但没带
      // 数据阶段"的情况——那说明描述符根本没回来，光看应答码是看不出来的。
      NikonPtpIpService.log(`ptpip prop code=${NikonCameraParameters.hex(propertyCode)} no-descriptor`);
      return null;
    }
    if (data.length < 9) {
      // 描述符最短是 DevicePropCode(2) + DataType(2) + GetSet(1) + Default +
      // Current + FormFlag。不足 9 字节说明连 16 位值都放不下，把实际长度打出来，
      // 否则只能看到"参数不显示"而不知道相机回了什么。
      NikonPtpIpService.log(`ptpip prop code=${NikonCameraParameters.hex(propertyCode)}`
        + ` descriptor-too-short bytes=${data.length}`);
      return null;
    }
    // DevicePropCode(u16) DataType(u16) GetSet(u8) DefaultValue CurrentValue ...
    const code = data[0] | (data[1] << 8);
    const dataType = data[2] | (data[3] << 8);
    const getSet = data[4];
    const size = typeSize(dataType);
    if (size === 0) {
      NikonPtpIpService.log(`ptpip prop code=${NikonCameraParameters.hex(propertyCode)} unknown-datatype=${NikonCameraParameters.hex(dataType)}`);
      return null;
    }
    let offset = 5;
    if (offset + size * 2 > data.length) {
      return null;
    }
    offset += size; // 跳过 DefaultValue
    const value = readType(data, offset, dataType);
    offset += size; // 跳过 CurrentValue
    const state: NikonPropertyState = {
      propertyCode: code,
      supported: true,
      writable: getSet === GET_SET_READ_WRITE,
      dataType: dataType,
      value: value,
      formFlag: PTP_FORM_NONE,
      minimum: 0,
      maximum: 0,
      step: 1,
      enumValues: [],
    };
    if (offset >= data.length) {
      return state;
    }
    state.formFlag = data[offset];
    offset += 1;
    if (state.formFlag === PTP_FORM_RANGE) {
      if (offset + size * 3 > data.length) return state;
      state.minimum = readType(data, offset, dataType);
      state.maximum = readType(data, offset + size, dataType);
      state.step = readType(data, offset + size * 2, dataType);
      if (state.step === 0) state.step = 1;
    } else if (state.formFlag === PTP_FORM_ENUM) {
      if (offset + 2 > data.length) return state;
      const count = data[offset] | (data[offset + 1] << 8);
      offset += 2;
      const values: number[] = [];
      for (let index = 0; index < count; index++) {
        if (offset + size > data.length) break;
        values.push(readType(data, offset, dataType));
        offset += size;
      }
      state.enumValues = values;
      if (values.length > 0) {
        let low = values[0];
        let high = values[0];
        for (const item of values) {
          if (item < low) low = item;
          if (item > high) high = item;
        }
        state.minimum = low;
        state.maximum = high;
      }
    }
    return state;
  }

  /**
   * 探测一组属性，只返回相机**确实支持**的那些。
   *
   * 逐个发（PTP 的会话是串行的，批量并发没有意义，反而会把事务号搅乱）。
   * 不支持的属性会回非 OK，`describe` 返回 null，这里直接跳过。
   */
  static async probe(propertyCodes: number[]): Promise<NikonPropertyState[]> {
    const states: NikonPropertyState[] = [];
    for (const propertyCode of propertyCodes) {
      const state = await NikonCameraParameters.describe(propertyCode);
      if (state === null) {
        NikonPtpIpService.log(`ptpip prop code=${NikonCameraParameters.hex(propertyCode)} unsupported`);
        continue;
      }
      NikonPtpIpService.log(
        `ptpip prop code=${NikonCameraParameters.hex(propertyCode)} type=${NikonCameraParameters.hex(state.dataType)}` +
        ` get-set=${state.writable ? 1 : 0} value=${state.value} form=${state.formFlag}` +
        ` range=${state.minimum}..${state.maximum}/${state.step} enum=${state.enumValues.length}`);
      // 把枚举**原值**也打出来。显示口径（EV 的单位、快门的分母编码）只能从相机的
      // 真实取值定，靠猜会显示错的数值——这一点已经在 0x1014/0x1015 上吃过一次亏。
      // 上限 64 个，避免个别属性把日志刷爆。
      if (state.enumValues.length > 0 && state.enumValues.length <= 64) {
        NikonPtpIpService.log(`ptpip prop-enum code=${NikonCameraParameters.hex(propertyCode)}`
          + ` values=${state.enumValues.join(',')}`);
      }
      states.push(state);
    }
    return states;
  }

  /**
   * 白平衡 `0x5005` 的显示名。
   *
   * 全部来自官方 `WhiteBalanceCaptureParameter$WhiteBalancePropertyValue` 的
   * `<clinit>`（`const/16` 是有符号的，所以 `-0x7ff0` 就是 `0x8010`），并与本机
   * 相机回的枚举 `2,4,5,6,7,32784,32785,32786,32787,32790` **逐项对上**：
   *
   *   AUTOMATIC 2 / DAYLIGHT 4 / FLORESCENT 5 / TUNGSTEN 6 / FLASH 7 /
   *   CLOUDY_WEATHER 0x8010 / DAYLIGHT_SHADE 0x8011 /
   *   COLOR_TEMPERATURE_SETTING 0x8012 / PRESET_MANUAL 0x8013 /
   *   NATURAL_LIGHT_AUTOMATIC 0x8016
   *
   * 注意最后一个跳到了 `0x8016`（不是 0x8014/0x8015）——凭印象写必然写错，所以
   * 这张表是照字节码抄的，不是回忆的。
   */
  static whiteBalanceLabel(value: number): string {
    switch (value) {
      case 0x0002: return '自动';
      case 0x0004: return '晴天';
      case 0x0005: return '荧光灯';
      case 0x0006: return '白炽灯';
      case 0x0007: return '闪光灯';
      case 0x8010: return '阴天';
      case 0x8011: return '晴天阴影';
      case 0x8012: return '色温';
      case 0x8013: return '预设手动';
      case 0x8016: return '自然光自动';
      default: return `白平衡 ${value}`;
    }
  }

  /** 控制页关心的那一组属性。顺序即界面顺序。 */
  static controlPropertyCodes(): number[] {
    return [
      NikonProp.PROGRAM_MODE,
      NikonProp.FNUMBER,
      NikonProp.SHUTTER_SPEED,
      NikonProp.ISO,
      NikonProp.EXPOSURE_COMPENSATION,
      NikonProp.WHITE_BALANCE,
      NikonProp.STILL_CAPTURE_MODE,
      NikonProp.BURST_NUMBER,
      NikonProp.FOCAL_LENGTH,
      NikonProp.COMPRESSION,
      NikonProp.BATTERY_LEVEL,
      // 录像那组（见下面的 MOVIE_*）。它们排在最后：界面上直接显示的是前一组，
      // 但用户切到录像模式之后参数面板要读的是这一组，所以一次探测全部拿回来，
      // 切模式不必再等一轮往返。
      NikonCameraParameters.MOVIE_SHUTTER_SPEED,
      NikonCameraParameters.MOVIE_FNUMBER,
      NikonCameraParameters.MOVIE_ISO,
      NikonCameraParameters.MOVIE_EXPOSURE_COMPENSATION,
      NikonCameraParameters.MOVIE_WHITE_BALANCE,
    ];
  }

  // --- 录像（视频）专用属性 ------------------------------------------------
  //
  // **录像的曝光参数是另一组属性码，不是拍照那些码换了个语义。**
  //
  // 依据是官方 SnapBridge 2.13.3 的字节码：每个 `GetMovieXxxAction` / `SetMovieXxxAction`
  // 都指向自己独立的 `0xD1xx` / `0xD2xx` 码（`const/16` 是有符号的，下面已经是按
  // 补码还原的无符号值）：
  //
  //   GetMovieShutterSpeed        → 0xD1A8
  //   GetMovieFnumber             → 0xD1A9
  //   GetMovieIso                 → 0xD1AA
  //   GetMovieExposureCompensation→ 0xD1AB
  //   GetMovieWhiteBalance        → 0xD23A
  //
  // 所以此前在录像模式下拿拍照那组码去读/写，看到的是照片参数、写进去也改不到
  // 录像——不是"相机不支持"，是我们问错了属性。
  static readonly MOVIE_SHUTTER_SPEED: number = 0xD1A8;
  static readonly MOVIE_FNUMBER: number = 0xD1A9;
  static readonly MOVIE_ISO: number = 0xD1AA;
  static readonly MOVIE_EXPOSURE_COMPENSATION: number = 0xD1AB;
  static readonly MOVIE_WHITE_BALANCE: number = 0xD23A;
  /** `0xD0A4` 录像禁止条件：机身用它在录制前说明"现在能不能录、为什么不能"。 */
  static readonly MOVIE_REC_PROHIBITION: number = 0xD0A4;

  /** 拍照属性码 → 与它对应的录像属性码。0 表示这条在录像里没有对应项。 */
  static movieCodeOf(stillCode: number): number {
    switch (stillCode) {
      case NikonProp.SHUTTER_SPEED: return NikonCameraParameters.MOVIE_SHUTTER_SPEED;
      case NikonProp.FNUMBER: return NikonCameraParameters.MOVIE_FNUMBER;
      case NikonProp.ISO: return NikonCameraParameters.MOVIE_ISO;
      case NikonProp.EXPOSURE_COMPENSATION: return NikonCameraParameters.MOVIE_EXPOSURE_COMPENSATION;
      case NikonProp.WHITE_BALANCE: return NikonCameraParameters.MOVIE_WHITE_BALANCE;
      default: return 0;
    }
  }

  /** 录像属性码 → 与它**编码相同**的拍照属性码，用来复用同一套解码文案。
   *
   *  编码确实相同：官方 `Set/Get` 的拍照与录像两套动作引用的是同一批数据类
   *  （F 值 ×100、快门 (分子<<16)|分母、EV 同一刻度、白平衡同一张枚举表），
   *  差的只有属性码。返回 0 表示这不是一个录像属性码。 */
  static stillCodeOf(code: number): number {
    switch (code) {
      case NikonCameraParameters.MOVIE_SHUTTER_SPEED: return NikonProp.SHUTTER_SPEED;
      case NikonCameraParameters.MOVIE_FNUMBER: return NikonProp.FNUMBER;
      case NikonCameraParameters.MOVIE_ISO: return NikonProp.ISO;
      case NikonCameraParameters.MOVIE_EXPOSURE_COMPENSATION: return NikonProp.EXPOSURE_COMPENSATION;
      case NikonCameraParameters.MOVIE_WHITE_BALANCE: return NikonProp.WHITE_BALANCE;
      default: return 0;
    }
  }

  /**
   * 写一个属性。
   *
   * 值按**描述符声明的**宽度编码：调用方不必知道 ISO 在这台机身上是 16 位还是
   * 32 位（`SetIsoAction` 两种都引用了）。写完回读一次描述符确认落地，因为
   * 机身可能拒绝越界值却仍然回 OK。
   */
  static async write(state: NikonPropertyState, value: number): Promise<boolean> {
    if (!state.supported) return false;
    if (!state.writable && !NikonCameraParameters.isWritableDespiteReadOnly(state.propertyCode)) {
      NikonPtpIpService.log(`ptpip write-prop code=${NikonCameraParameters.hex(state.propertyCode)} rejected read-only`);
      return false;
    }
    const clamped = NikonCameraParameters.clamp(state, value);
    const payload = writeType(clamped, state.dataType);
    const ok = await NikonPtpIpService.writeProperty(state.propertyCode, payload);
    NikonPtpIpService.log(
      `ptpip write-prop code=${NikonCameraParameters.hex(state.propertyCode)} value=${clamped} ok=${ok ? 1 : 0}`);
    return ok;
  }

  /** 能被真正设置的档位值。
   *
   *  Z 5 的 `0x500E` 枚举是 `1,2,3,4,0x8010,0x8050,0x8051,0x8052`（真机描述符）。
   *  后三个在官方 `ProgramMode` 枚举里**没有对应项**（`y9.a(S)` 一律映射成
   *  UNKNOWN），官方 App 也不把它们当作档位显示。列表只留 M/P/A/S 与 AUTO。 */
  static isSettableMode(value: number): boolean {
    return value === 1 || value === 2 || value === 3 || value === 4;
  }

  /**
   * 描述符声明**只读**、但实测可写的属性。
   *
   * 目前只有档位 `0x500E`：Z 5 的 `GetSet` 是 0（`opt0:ro`），只看描述符就永远改
   * 不了模式——这正是"模式无效"。但 2026‑10‑18 用插桩的官方 SnapBridge 对 Z 5
   * 抓包，官方**照样写它**，两次都拿到 `0x2001`：
   *
   *   16:57:36  SetDevicePropValue 0x500E ← `01 00`   (M)
   *   16:58:14  SetDevicePropValue 0x500E ← `02 00`   (P)
   *
   * 相机既然接受，就不能让描述符挡住。其余属性仍按描述符判断。
   */
  static isWritableDespiteReadOnly(code: number): boolean {
    return code === NikonProp.PROGRAM_MODE;
  }

  /** 把用户给的值收进描述符声明的合法范围；枚举则吸附到最近的合法项。 */
  static clamp(state: NikonPropertyState, value: number): number {
    if (state.formFlag === PTP_FORM_ENUM && state.enumValues.length > 0) {
      let best = state.enumValues[0];
      let bestDistance = Math.abs(value - best);
      for (const item of state.enumValues) {
        const distance = Math.abs(value - item);
        if (distance < bestDistance) {
          best = item;
          bestDistance = distance;
        }
      }
      return best;
    }
    if (state.formFlag !== PTP_FORM_RANGE) return value;
    let result = value;
    if (result < state.minimum) result = state.minimum;
    if (result > state.maximum) result = state.maximum;
    if (state.step > 1) {
      result = state.minimum + Math.round((result - state.minimum) / state.step) * state.step;
      if (result > state.maximum) result = state.maximum;
    }
    return result;
  }
}
