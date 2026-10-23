/**
 * FUJIFILM XApp 2.7.0 逆向结论的协议常量（唯一事实来源）。
 *
 * 数据来源（都已落在 Fujifilm\apk\reports）：
 *  - 01_首次配对_蓝牙配对与WiFi凭据.md   → BLE 服务/特征、配对、SSID/密码、AP_STATE
 *  - 02_相机控制_指令与参数.md           → PTP-IP 端口、操作码、属性码、模式协商、事件
 *  - 03_图片传输_SD卡与倒序.md           → 对象枚举、缩略图、分块下载、双槽
 *  - 04_固件更新协议.md                  → 固件元数据 URL、1 MiB 分块、事件 49/50
 *
 * 约定：
 *  - 数值一律用 `number`（PTP 的 u32 用无符号语义，0xFFFFFFFF 用 4294967295 表示再转）。
 *  - 这里只放「逆向得到的事实」，不放业务逻辑；实现层不得另造协议常量。
 *  - 对逆向报告标注为【推断】的项，本文件在注释里保留该标注，实现层必须做兼容/回退。
 */

/** BLE 广播识别：Company ID（仅二次校验，真实身份看厂商自定义数据）。 */
export class FujifilmBleIds {
  static readonly COMPANY_ID: number = 0x04D8;

  /** 扫描过滤器候选（7 个服务 UUID）。AF854C2E 在任何模式都常驻。 */
  static readonly SCAN_SERVICE_UUIDS: string[] = [
    'AF854C2E-B214-458E-97E2-912C4ECF2CB8',
    '462426E1-D712-4A28-BE62-61A786DAA866',
    '731893F9-744E-4899-B7E3-174106FF2B82',
    'A9D2B304-E8D6-4902-8336-352B772D7597',
    '123D8F06-62A1-4935-9322-833C531EE225',
    '804DAA8E-FFEB-4AB3-8E75-6EDD7303208D',
    'CC74BD26-4ABB-4911-AE72-9CD93109A772',
  ];

  /** 任何模式都要挂的常驻过滤 UUID。 */
  static readonly SCAN_UUID_ALWAYS: string = 'AF854C2E-B214-458E-97E2-912C4ECF2CB8';

  // ---- 服务 ----
  static readonly SERVICE_CAMERA_CONTROL: string = '6514EB81-4E8F-458D-AA2A-E691336CDFAC';
  static readonly SERVICE_CAMERA_STATE: string = '4C0020FE-F3B6-40DE-ACC9-77D129067B14';
  static readonly SERVICE_CAMERA_SETTING: string = '4E941240-D01D-46B9-A5EA-67636806830B';
  static readonly SERVICE_CAMERA_INFORMATION: string = '117C4142-EDD4-4C77-8696-DD18EEBB770A';
  static readonly SERVICE_CAMERA_INFORMATION_RED: string = 'A9D2B304-E8D6-4902-8336-352B772D7597';
  static readonly SERVICE_CONNECTED_DEVICE_INFO: string = '91F1DE68-DFF6-466E-8B65-FF13B0F16FB8';
  static readonly SERVICE_CONNECTED_DEVICE_INFO_RED: string = '123D8F06-62A1-4935-9322-833C531EE225';
  static readonly SERVICE_CAMERA_STARTUP_INFO: string = '731893F9-744E-4899-B7E3-174106FF2B82';
  static readonly SERVICE_CAMERA_STARTUP_INFO_RED: string = '804DAA8E-FFEB-4AB3-8E75-6EDD7303208D';

  // ---- 特征（只列本路线实际要用的）----
  /** 配对密钥回写（老协议 mf[1..5] 的 4 字节原样写回）。 */
  static readonly CHAR_PAIRING_KEY: string = 'ABA356EB-9633-4E60-B73F-F52516DBD671';
  /** WiFi SSID（UTF-8，读至 0x00）。 */
  static readonly CHAR_SSID: string = 'BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4';
  /** WiFi 密码（UTF-8，读至 0x00）。每次连接现场读，不落库。 */
  static readonly CHAR_PASSPHRASE: string = 'E809256A-915C-4967-92E8-53B7D4CAD213';
  /** 功能启动请求（u16 LE）：03=浏览/图传 04=遥控 05=相机设置/固件。 */
  static readonly CHAR_FUNCTION_LAUNCH: string = '600655E6-3637-42F1-8FB2-44EFC5C63B13';
  /** AP 状态通知：0x8001 = Launched（热点已就绪），0x8002 = 正在启动。 */
  static readonly CHAR_AP_STATE: string = 'A68E3F66-0FCC-4395-8D4C-AA980B5877FA';
  static readonly CHAR_MAC_ADDRESS: string = '49A12959-DFAA-4EB2-89CE-62548AD948F3';
  static readonly CHAR_SERIAL_NUMBER: string = 'E8E40D50-A625-4F1D-96ED-8CEC034F5690';
  /** Y 号（产品序号，如 `Y-057011`），UTF-8+NUL。 */
  static readonly CHAR_Y_NUMBER: string = '27870478-94A9-4345-849B-EFA3BF37887F';
  /** RED 机型额外写 fixed 3 字节 `80 01 01`。 */
  static readonly CHAR_CONNECTED_APP_INFO: string = '8B5ECF55-FC6B-40D0-B4C1-76F64E5453C7';
  /** RED 机型额外写 XAPP_IDENTIFIER=0x20000000。 */
  static readonly CHAR_CONNECTED_DEVICE_ID: string = 'F557D96B-8284-4667-8793-B971C1DECA2A';
  /** 时间同步 12 字节（UTC + 时区）；老固件退化为 7 字节 DATE_TIME。 */
  static readonly CHAR_UTC_AND_TIMEZONE: string = 'C52EDBCE-1FE2-4ECC-9483-907E6592BE9E';
  /** 标准 GATT 固件版本字符串（0x2A26）。 */
  static readonly CHAR_FIRMWARE_REVISION: string = '00002A26-0000-1000-8000-00805F9B34FB';
  static readonly CHAR_SERIAL_NUMBER_STD: string = '00002A25-0000-1000-8000-00805F9B34FB';
  static readonly CHAR_MODEL_NUMBER_STD: string = '00002A24-0000-1000-8000-00805F9B34FB';

  // ---- 固件更新专用（04 报告 §5）----
  /** 92 B 固件请求（写）。 */
  static readonly CHAR_FW_UPDATE_REQUEST: string = 'B1307521-7AC5-4199-AAEE-9D094781CE69';
  /** 29 B 固件文件信息（读）：availability + version×100，决定 type=5 / type=6 分支。 */
  static readonly CHAR_FW_UPDATE_FILE_INFO: string = '20EA1FAC-19D8-48A8-A80C-535D34300958';
  /** 相机侧固件写入进度/错误码（读/通知）。 */
  static readonly CHAR_FW_UPDATE_STATE: string = '049EC406-EF75-4205-A390-08FE209C51F0';
  /** 镜头固件版本（本路线无镜头固件链路，仅用于展示/负结论）。 */
  static readonly CHAR_LENS_FIRMWARE_VERSION: string = '621A98D8-6314-4C3E-A683-EEA1D6166606';

  /** RED 机型的固定标识值。 */
  static readonly XAPP_IDENTIFIER: number = 0x20000000;
  static readonly RED_APP_INFO_BYTES: number[] = [0x80, 0x01, 0x01];

  /** 功能启动请求值（FunctionLaunchRequestType）。1=ImportImage 是死枚举，不要用。 */
  static readonly LAUNCH_IN_CAMERA_VIEWING: number = 3;
  static readonly LAUNCH_REMOTE_SHOOTING: number = 4;
  static readonly LAUNCH_UPDATE_FIRMWARE: number = 5;

  /** AP_STATE 取值。 */
  static readonly AP_STATE_LAUNCHED: number = 0x8001;
  static readonly AP_STATE_LAUNCHING: number = 0x8002;

  /** 广播厂商数据的协议代际标记（mf[0]）。 */
  static readonly ADV_PROTOCOL_RED: number = 1;
  static readonly ADV_PROTOCOL_LEGACY: number = 2;
}

/** WiFi / PTP-IP 端点与超时。 */
export class FujifilmNet {
  static readonly HOST: string = '192.168.0.1';
  static readonly PORT_CONTROL: number = 55740;
  static readonly PORT_LIVEVIEW: number = 55741;
  static readonly PORT_EVENT: number = 55742;

  static readonly CONNECT_TIMEOUT_MS: number = 5000;
  /** native Java_SDK_Open 的 5000ms × ≤6 次（总 30s）。 */
  static readonly OPEN_TIMEOUT_MS: number = 5000;
  static readonly OPEN_ATTEMPTS: number = 6;
  /** InitiateOpenCapture 的 Phase1 / Phase2 各自上限。 */
  static readonly OPEN_CAPTURE_TIMEOUT_MS: number = 30000;

  /** PTP-IP 单次事务超时。 */
  static readonly TRANSACTION_TIMEOUT_MS: number = 10000;
  /** 数据阶段每包 512 B（native `movz #0x200`）。 */
  static readonly DATA_BLOCK: number = 512;

  /** 固件单块 1 MiB，单块等待 5 s。 */
  static readonly FIRMWARE_CHUNK: number = 1048576;
  static readonly FIRMWARE_CHUNK_WAIT_MS: number = 5000;
  /** 固件整程上限（native CCameraCommandFirmwareVersionUp）。 */
  static readonly FIRMWARE_TOTAL_TIMEOUT_MS: number = 600000;
  /** 固件发送的重试次数（SetFunctionMode 的 RETRY_COUNT=5）。 */
  static readonly FIRMWARE_RETRY: number = 5;

  /** 取景帧：固定 204800 字节阻塞读（GetThroughPicture）。 */
  static readonly LIVEVIEW_FRAME_BYTES: number = 204800;
  /** JPEG 在取景帧内的偏移 = LE32@12 + 18。 */
  static readonly LIVEVIEW_JPEG_PTR_OFFSET: number = 12;
  static readonly LIVEVIEW_JPEG_HEADER_BIAS: number = 18;

  /** 图片下载：MOV/RAW 走 12582880 字节滚动缓冲。 */
  static readonly DOWNLOAD_ROLLING_BUFFER: number = 12582880;
  /** 句柄一次取全：count 上限 30000，分页 offset 恒 0。 */
  static readonly OBJECT_COUNT_LIMIT: number = 30000;
  /** 当前对象句柄查询参数。 */
  static readonly CURRENT_OBJECT_HANDLE_PARAM: number = 0x10000001;
}

/** PTP-IP 帧类型（CIPA DC-X005 编号；12 字节包头 Length/Type/DataPhaseInfo）。 */
export class FujifilmPacketType {
  static readonly INIT_COMMAND_REQUEST: number = 0x01;
  static readonly INIT_COMMAND_ACK: number = 0x02;
  static readonly INIT_EVENT_REQUEST: number = 0x03;
  static readonly INIT_EVENT_ACK: number = 0x04;
  static readonly INIT_FAIL: number = 0x05;
  static readonly OPERATION_REQUEST: number = 0x06;
  static readonly OPERATION_RESPONSE: number = 0x07;
  static readonly EVENT: number = 0x08;
  static readonly START_DATA: number = 0x09;
  static readonly DATA: number = 0x0A;
  static readonly END_DATA: number = 0x0B;
  static readonly CANCEL: number = 0x0C;

  static readonly DATA_PHASE_NONE: number = 0;
  static readonly DATA_PHASE_IN: number = 1;
  static readonly DATA_PHASE_OUT: number = 2;
}

/** PTP 操作码（39 条权威表的子集 + 富士扩展）。 */
export class FujifilmOp {
  static readonly GET_DEVICE_INFO: number = 0x1001;
  static readonly OPEN_SESSION: number = 0x1002;
  static readonly CLOSE_SESSION: number = 0x1003;
  static readonly GET_STORAGE_IDS: number = 0x1004;
  static readonly GET_STORAGE_INFO: number = 0x1005;
  static readonly GET_NUM_OBJECTS: number = 0x1006;
  static readonly GET_OBJECT_HANDLES: number = 0x1007;
  static readonly GET_OBJECT_INFO: number = 0x1008;
  static readonly GET_OBJECT: number = 0x1009;
  static readonly GET_THUMB: number = 0x100A;
  static readonly DELETE_OBJECT: number = 0x100B;
  static readonly SEND_OBJECT_INFO: number = 0x100C;
  static readonly SEND_OBJECT: number = 0x100D;
  static readonly INITIATE_CAPTURE: number = 0x100E;
  static readonly TERMINATE_OPEN_CAPTURE: number = 0x1018;
  static readonly GET_DEVICE_PROP_DESC: number = 0x1014;
  static readonly GET_DEVICE_PROP_VALUE: number = 0x1015;
  static readonly SET_DEVICE_PROP_VALUE: number = 0x1016;
  static readonly GET_PARTIAL_OBJECT: number = 0x101B;
  static readonly INITIATE_OPEN_CAPTURE: number = 0x101C;
  static readonly CANCEL_INITIATE_CAPTURE: number = 0x9030;

  // 富士扩展（libFTLPTPIP .data 0x5EA44）
  static readonly GET_DEVICE_PROP_DESC_ALL: number = 0x902B;
  static readonly STEP_SHUTTER_SPEED: number = 0x902C;
  static readonly STEP_FNUMBER: number = 0x902D;
  static readonly STEP_EXPOSURE_BIAS: number = 0x902E;
  static readonly INITIATE_MOVIE_CAPTURE: number = 0x9020;
  static readonly TERMINATE_MOVIE_CAPTURE: number = 0x9021;
  static readonly POSTVIEW: number = 0x9022;
  static readonly STEP_ZOOM: number = 0x9023;
  static readonly START_ZOOM: number = 0x9024;
  static readonly STOP_ZOOM: number = 0x9025;
  static readonly FM_SEND_OBJECT_INFO: number = 0x9040;
  static readonly FM_SEND_OBJECT: number = 0x9041;
  static readonly FM_SEND_PARTIAL_OBJECT: number = 0x9042;
  /** 按日期分组计数：`[offset=0, count=30000]`（图传页只做诊断，不参与 UI 判定）。 */
  static readonly COUNT_GROUP_BY_DATE: number = 0x9053;
  static readonly GET_EXTENSION_OBJECT_INFO: number = 0x9054;
  static readonly GET_EXTENSION_THUMB: number = 0x9055;
  static readonly GET_EXTENSION_PARTIAL_OBJECT: number = 0x9056;
  static readonly CANCEL_INITIATE_CAPTURE_ALT: number = 0x9030;
}

/** PTP 响应码。 */
export class FujifilmResponse {
  static readonly OK: number = 0x2001;
  static readonly GENERAL_ERROR: number = 0x2002;
  static readonly SESSION_NOT_OPEN: number = 0x2003;
  static readonly OPERATION_NOT_SUPPORTED: number = 0x2005;
  static readonly PARAMETER_NOT_SUPPORTED: number = 0x2006;
  static readonly DEVICE_BUSY: number = 0x2019;
  static readonly SESSION_ALREADY_OPEN: number = 0x201E;
  static readonly TRANSACTION_CANCELLED: number = 0x201F;
  /** 富士重试判据（控制页唯一的重试码）。 */
  static readonly INVALID_DEVICE_PROP_VALUE: number = 0x201C;
  static readonly FUJI_RETRY_CODE: number = 4102;
}

/** PTP 事件码（0x4000 段 + 富士私有事件）。 */
export class FujifilmEvent {
  static readonly OBJECT_ADDED: number = 0x4002;
  static readonly DEVICE_PROP_CHANGED: number = 0x4006;
  static readonly CAPTURE_COMPLETE: number = 0x400D;
  static readonly STORE_ADDED: number = 0x400C;
  /** 固件数据阶段：相机每次拉一块。 */
  static readonly FIRMWARE_PULL_CHUNK: number = 49;
  /** 固件数据阶段结束。 */
  static readonly FIRMWARE_DONE: number = 50;
  /** 相机模式改变（SDK_EVENTTYPE_GET_CAMERA_MODE）。 */
  static readonly GET_CAMERA_MODE: number = 11;
  /** 拍摄状态（30/31/32）。 */
  static readonly CAPTURE_START: number = 30;
  static readonly CAPTURE_FINISH: number = 31;
  /** 32 = PostView 就绪（不是拍摄错误；见 `control_event_codes.csv`）。 */
  static readonly POSTVIEW_COMPLETE: number = 32;
  /** 属性变化（arg1=propCode、arg2=value）。 */
  static readonly PROP_VALUE: number = 40;
  /** 设备信息变化 → 重拉 0x902B。 */
  static readonly DEVICE_INFO_CHANGED: number = 41;
  /** AF 完成。 */
  static readonly AF_COMPLETE: number = 43;
}

/** 富士 DevicePropCode（注意：富士私有重排，不等于标准 PTP DSC）。 */
export class FujifilmProp {
  static readonly BATTERY: number = 0x5001;
  /**
   * SDK 功能模式属性（`SDK_SetFunctionMode` → `SetDevicePropValue(0xDF01, UINT16)`）。
   *
   * 【事实】`libFFIR.so` 的 `SDK_SetFunctionMode` 构造器里 `w3=0xDF01、w4=4`（UINT16），
   * 命令码 0x4078 → `CPTPCommand::SetDeviceProperty` → PTP `0x1016`。
   * 角色 B（控制）与角色 C（图传）各自独立逆向得到同一结论，已交叉验证。
   * 注意：标准 PTP 的 `0x5002 FunctionMode` 是**相机功能模式**（拍照/回放），不是 SDK 模式。
   */
  static readonly FUNCTION_MODE: number = 0xDF01;
  /** 相机功能模式（标准 PTP 语义，非 SDK 模式）。 */
  static readonly CAMERA_FUNCTION_MODE: number = 0x5002;
  /** `SetCameraFunctionMode(mode)` 的属性（libFFIR 0x4210 构造器 `w3=0xDF00`）。 */
  static readonly SDK_CAMERA_FUNCTION_MODE: number = 0xDF00;
  static readonly IMAGE_SIZE: number = 0x5003;
  /** 画质/压缩（FINE/NORMAL…）。 */
  static readonly IMAGE_QUALITY: number = 0x5004;
  static readonly COMPRESSION: number = 0x5004;
  static readonly WHITE_BALANCE: number = 0x5005;
  static readonly F_NUMBER: number = 0x5007;
  static readonly FOCUS_MODE: number = 0x500A;
  static readonly METERING: number = 0x500B;
  static readonly FLASH: number = 0x500C;
  static readonly EXPOSURE_TIME: number = 0x500D;
  static readonly EXPOSURE_PROGRAM: number = 0x500E;
  static readonly EXPOSURE_BIAS: number = 0x5010;
  static readonly CAPTURE_DELAY: number = 0x5012;
  static readonly IMAGE_ASPECT: number = 0x501F;

  /** 胶片模拟（报告 02 §5.3：0xD001，不是 0xD245）。 */
  static readonly FILM_SIMULATION: number = 0xD001;
  /** 双槽状态（UINT8）：`SDK_Get/SetDualSlotStatus` 的 `w3=0xD244`。 */
  static readonly DUAL_SLOT_STATUS: number = 0xD244;
  /** AF 区域选择模式（0–7）。 */
  static readonly AF_SELECT_MODE: number = 0xD245;

  /** 扩展快门（富士用这个替代 0x500D）。 */
  static readonly SHUTTER_EXT: number = 0xD240;
  /** 相机错误状态码 0–17。 */
  static readonly DEVICE_ERROR: number = 0xD21B;
  /** 剩余可拍张数。 */
  static readonly REMAINING_SHOTS: number = 0xD229;
  /** 当前固件文件名（如 `X-T5_0431_026_001.DAT`）。 */
  static readonly FW_FILE_NAME: number = 0xD22F;

  /** 当前对象句柄（`GetCurrentObjectHandle` 读这个属性）。 */
  static readonly CURRENT_OBJECT_HANDLE: number = 0xD22B;
  /** 指定条件下的对象张数。 */
  static readonly SPECIFIED_OBJECT_COUNT: number = 0xD620;
  /** 指定条件下的对象句柄列表（一次取全，无分页）。 */
  static readonly SPECIFIED_OBJECT_HANDLES: number = 0xD621;
}

/** 功能模式（SDK mode）。 */
export class FujifilmMode {
  static readonly REMOTE: number = 5;
  static readonly NEUTRAL: number = 6;
  static readonly FIRMWARE_DATA_TRANSFER: number = 19;
  static readonly IMAGE_VIEW_V2: number = 20;
  static readonly RESERVED_PHOTO_RECEIVE: number = 21;
  static readonly IMAGE_LIVE_VIEW: number = 22;

  /** 模式对应的能力版本属性。 */
  static readonly VERSION_FIRMWARE: number = 0xDF27;
  static readonly VERSION_IMAGE_VIEW: number = 0xDF28;
  static readonly VERSION_RESERVED: number = 0xDF29;
  static readonly VERSION_REMOTE_EX: number = 0xDF2A;
  static readonly VERSION_REMOTE_GET: number = 0xDF25;
  static readonly VERSION_REMOTE_SET: number = 0xDF24;
  /** camera.xml 缺省 versionRemote。 */
  static readonly VERSION_REMOTE_DEFAULT: number = 131083;

  /** 各模式的最低版本门槛。 */
  static readonly MIN_VERSION_FIRMWARE: number = 1;
  static readonly MIN_VERSION_IMAGE_VIEW: number = 3;
  static readonly MIN_VERSION_RESERVED: number = 3;
  static readonly MIN_VERSION_REMOTE_EX: number = 4;
}

/** 固件更新（04 报告）。 */
export class FujifilmFirmware {
  static readonly METADATA_URL: string = 'https://privacy.xapp.net/camera_fw/camera_fw_info.json';
  static readonly APP_UPDATE_URL: string = 'https://privacy.xapp.net/xapp_update/xapp_update_android.json';
  /** 固件包后缀。 */
  static readonly PACKAGE_SUFFIX: string = '.DAT';
  /** BLE 固件请求头长度（92 B）。 */
  static readonly BLE_REQUEST_BYTES: number = 92;
  static readonly BLE_NAME_FIELD: number = 64;
  static readonly BLE_FILE_FIELD: number = 15;
  static readonly BLE_VERSION_FIELD: number = 7;
}

/** 小端读写与字节工具（ArkTS 没有 DataView 的便捷封装，统一放这里）。 */
export class FujifilmBytes {
  static u16(value: number): Uint8Array {
    const out = new Uint8Array(2);
    out[0] = value & 0xFF;
    out[1] = (value >>> 8) & 0xFF;
    return out;
  }

  static u32(value: number): Uint8Array {
    const out = new Uint8Array(4);
    out[0] = value & 0xFF;
    out[1] = (value >>> 8) & 0xFF;
    out[2] = (value >>> 16) & 0xFF;
    out[3] = (value >>> 24) & 0xFF;
    return out;
  }

  static u64(value: number): Uint8Array {
    const out = new Uint8Array(8);
    let rest = value;
    for (let i = 0; i < 8; i++) {
      out[i] = rest & 0xFF;
      rest = Math.floor(rest / 256);
    }
    return out;
  }

  static readU16(data: Uint8Array, offset: number): number {
    if (offset + 2 > data.length) return 0;
    return (data[offset] | (data[offset + 1] << 8)) & 0xFFFF;
  }

  static readU32(data: Uint8Array, offset: number): number {
    if (offset + 4 > data.length) return 0;
    return (data[offset] | (data[offset + 1] << 8) |
      (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
  }

  static readU32At(buffer: Uint8Array, offset: number): number {
    return FujifilmBytes.readU32(buffer, offset);
  }

  static concat(parts: Uint8Array[]): Uint8Array {
    let total = 0;
    for (const part of parts) total += part.length;
    const out = new Uint8Array(total);
    let at = 0;
    for (const part of parts) {
      out.set(part, at);
      at += part.length;
    }
    return out;
  }

  /** UTF-16LE（PTP 字符串常规编码），末尾补 0x0000。 */
  static utf16z(value: string): Uint8Array {
    const out = new Uint8Array((value.length + 1) * 2);
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      out[i * 2] = code & 0xFF;
      out[i * 2 + 1] = (code >>> 8) & 0xFF;
    }
    return out;
  }

  static hex(value: number, width: number = 4): string {
    let text = value.toString(16).toUpperCase();
    while (text.length < width) text = '0' + text;
    return '0x' + text;
  }

  static hexBytes(data: Uint8Array, limit: number = 32): string {
    const parts: string[] = [];
    const count = Math.min(data.length, limit);
    for (let i = 0; i < count; i++) {
      parts.push(FujifilmBytes.hex(data[i], 2).substring(2));
    }
    return parts.join(' ') + (data.length > limit ? ' …' : '');
  }
}
