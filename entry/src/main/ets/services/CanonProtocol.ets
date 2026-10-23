/**
 * Canon（EOS / Canon Camera Connect）BLE 协议常量与纯字节解析（唯一事实来源）。
 *
 * 事实来源
 * --------
 *  - `docs/canon-route-design.md` §2（本文件的契约：UUID 表、广播解析、应用层帧、
 *    WAP 命令/TLV、能力位、错误码）。
 *  - 报告 `01-首次配对-BLE扫描配对与WiFi交接.md`：
 *      §1.1 扫描过滤与 LOW_LATENCY、§1.2 厂商数据 425 的两种形态、
 *      §2.2 服务/特征全表、§3.1 帧结构、§3.2 `0001000a` 命令字、
 *      §3.3 能力位图、§3.4 `0001000c` 事件类型、§5.1 WAP 命令、
 *      §5.2 WAP TLV、§5.3 WAP 状态。
 *  - 反编译（`documents/Canon/decompile/jadx_src/sources/com/canon/eos`）：
 *      `C0243d.java:36-83`   广播解析 / 短格式补位
 *      `C0251f.java:198-223` 唯一 ScanFilter + SCAN_MODE_LOW_LATENCY
 *      `C0251f.java:90-98`   `d()` 就地反转（“小端”= 反转后按大端读）
 *      `C0251f.java:115-147` flags -> 配对/电源状态
 *      `C0251f.java:166-188` bondState 10/11/12 与 connectGatt
 *      `C0291p.java:236-241` 注册帧 `01`+昵称（US-ASCII）
 *      `C0291p.java:345-357` PROHIBIT_AUTO_POWER_OFF = `0A`+`01/02`
 *      `V.java:149-197`      `0001000a` 命令字（UUID/昵称/TYPE）
 *      `V.java:134-147`      `00010005` 电源状态 0/1/2
 *      `C0235b.java:832-841` 能力位图（反转后 getInt 的位 0x08…0x100）
 *      `C0235b.java:95-123`  `0001000c` type 1..4 解析
 *      `C0235b.java:353-428` WAP TLV（跳过 2 字节 / tag-len-value）
 *      `C0235b.java:429-470` `00020003` [Code][SubCode] 分类
 *      `C.java:83-95`        WAP 命令字节
 *      `C.java:97-113`       handover READY 位掩码
 *      `C.java:115-146`      START_WITH_SECURITY_TYPE 构造（int 9 小端）
 *      `C0235b.java:993-1053` 服务发现与特征表
 *
 * 约定
 * ----
 *  - 本文件只放「逆向得到的事实」与纯函数解析，不依赖 `ble`/`connection`，
 *    因此可被页面、服务、测试自由引用。
 *  - 所有 UUID 常量写成大写 128-bit 全串；比较时统一转小写（鸿蒙回包大小写不定）。
 *  - “小端”一律指 `C0251f.d()` 的就地反转后按大端读；这里用显式反转实现，
 *    不做隐式字节序假设。
 */

import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

// ---------------------------------------------------------------------------
// 字节工具
// ---------------------------------------------------------------------------

/** 小端读写、十六进制、文本解码（ArkTS 没有 DataView 的便捷封装，统一放这里）。 */
export class CanonBytes {
  /** 2 字节小端。 */
  static u16(value: number): Uint8Array {
    const out = new Uint8Array(2);
    out[0] = value & 0xFF;
    out[1] = (value >>> 8) & 0xFF;
    return out;
  }

  /** 4 字节小端。 */
  static u32(value: number): Uint8Array {
    const out = new Uint8Array(4);
    out[0] = value & 0xFF;
    out[1] = (value >>> 8) & 0xFF;
    out[2] = (value >>> 16) & 0xFF;
    out[3] = (value >>> 24) & 0xFF;
    return out;
  }

  /** 小端 u16（等价 `C0251f.d()` + `getShort()`，`C0243d.java:52-55`）。 */
  static readU16(data: Uint8Array, offset: number): number {
    if (offset < 0 || offset + 2 > data.length) return 0;
    return (data[offset] | (data[offset + 1] << 8)) & 0xFFFF;
  }

  /** 小端 u32（等价反转后 `getInt()`）。 */
  static readU32(data: Uint8Array, offset: number): number {
    if (offset < 0 || offset + 4 > data.length) return 0;
    return (data[offset] | (data[offset + 1] << 8) |
      (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
  }

  /** 返回反转后的新数组；`C0251f.d()` 是就地反转，为了不留副作用这里不修改入参。 */
  static reverse(data: Uint8Array): Uint8Array {
    const out = new Uint8Array(data.length);
    for (let index = 0; index < data.length; index++) {
      out[index] = data[data.length - 1 - index];
    }
    return out;
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

  /** `0x` + 定宽大写十六进制（日志用）。 */
  static hex(value: number, width: number = 4): string {
    let text = value.toString(16).toUpperCase();
    while (text.length < width) text = '0' + text;
    return '0x' + text;
  }

  /** `AA BB CC`，最多 `limit` 字节，超出补省略号（日志用）。 */
  static hexBytes(data: Uint8Array, limit: number = 32): string {
    const parts: string[] = [];
    const count = Math.min(data.length, limit);
    for (let index = 0; index < count; index++) {
      parts.push(CanonBytes.hex(data[index], 2).substring(2));
    }
    return parts.join(' ') + (data.length > limit ? ' …' : '');
  }

  /** 无分隔大写十六进制（身份串用）。 */
  static hexPlain(data: Uint8Array): string {
    let text = '';
    for (let index = 0; index < data.length; index++) {
      text += CanonBytes.hex(data[index], 2).substring(2);
    }
    return text;
  }

  /** 十六进制串 -> 字节；接受 32 位 hex 或带 `-` 的 UUID 写法，非法返回空数组。 */
  static bytesFromHex(hex: string): Uint8Array {
    const cleaned = hex.replace(/-/g, '').toUpperCase();
    if (cleaned.length === 0 || cleaned.length % 2 !== 0) return new Uint8Array(0);
    const out = new Uint8Array(cleaned.length / 2);
    for (let index = 0; index < out.length; index++) {
      const pair = cleaned.substring(index * 2, index * 2 + 2);
      const value = Number.parseInt(pair, 16);
      if (Number.isNaN(value)) return new Uint8Array(0);
      out[index] = value;
    }
    return out;
  }

  /** US-ASCII 编码（报告 01 §3：应用层字符串一律 US-ASCII）。 */
  static ascii(value: string): Uint8Array {
    const out = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index);
      out[index] = code > 0x7F ? 0x3F : code; // 非 ASCII 用 '?' 兜底，绝不写多字节
    }
    return out;
  }

  /**
   * 读到首个 `0x00` 为止的文本，按 UTF-8 解码（SSID/密码可能含非 ASCII）。
   * 解码失败时逐字节退化为 Latin-1，保证不抛异常。
   */
  static textUntilNul(data: Uint8Array): string {
    if (data.length === 0) return '';
    let end = data.length;
    for (let index = 0; index < data.length; index++) {
      if (data[index] === 0) {
        end = index;
        break;
      }
    }
    if (end === 0) return '';
    const slice = data.subarray(0, end);
    try {
      return util.TextDecoder.create('utf-8').decodeToString(slice).trim();
    } catch (_error) {
      let text = '';
      for (let index = 0; index < slice.length; index++) {
        text += String.fromCharCode(slice[index]);
      }
      return text.trim();
    }
  }

  /** 从 `start` 到串尾（或首个 NUL）的文本。 */
  static textFrom(data: Uint8Array, start: number): string {
    if (start >= data.length) return '';
    return CanonBytes.textUntilNul(data.subarray(start));
  }
}

// ---------------------------------------------------------------------------
// UUID（报告 01 §2.1/§2.2，契约 §2.1）
// ---------------------------------------------------------------------------

export class CanonBleUuids {
  /** 私有 128-bit 基址的低 96 位（报告 01 §2.2 头）。 */
  static readonly BASE_SUFFIX: string = '-0000-1000-0000-D8492FFFA821';

  /** 主服务，同时是**唯一** ScanFilter（`C0251f.java:217`）。 */
  static readonly SERVICE_SESSION: string = '00010000-0000-1000-0000-D8492FFFA821';
  /** 会话状态 read+notify（`V.java:134-147`）。 */
  static readonly CHAR_SESSION_STATE: string = '00010005-0000-1000-0000-D8492FFFA821';
  /** 配对注册 write `01`+昵称，indicate `02`=OK（`C0291p.java:236-241`）。 */
  static readonly CHAR_REGISTRATION: string = '00010006-0000-1000-0000-D8492FFFA821';
  /** 会话命令通道（`V.java:149-197`）。 */
  static readonly CHAR_SESSION_COMMAND: string = '0001000A-0000-1000-0000-D8492FFFA821';
  /** 能力位图 read 4B 小端（`C0235b.java:832-841`）。 */
  static readonly CHAR_CAPABILITY: string = '0001000B-0000-1000-0000-D8492FFFA821';
  /** WiFi 事件 indicate（`C0235b.java:95-123`）。 */
  static readonly CHAR_WIFI_EVENT: string = '0001000C-0000-1000-0000-D8492FFFA821';

  /** WAP 服务（`C0235b.java:1014-1023`）。 */
  static readonly SERVICE_WAP: string = '00020000-0000-1000-0000-D8492FFFA821';
  /** WAP 能力位图 read。 */
  static readonly CHAR_WAP_CAPABILITY: string = '00020001-0000-1000-0000-D8492FFFA821';
  /** WAP 命令 write / TLV 响应 notify（`C0235b.java:353-428`）。 */
  static readonly CHAR_WAP_COMMAND: string = '00020002-0000-1000-0000-D8492FFFA821';
  /** WAP 状态 indicate `[Code][SubCode]`（`C0235b.java:429-470`）。 */
  static readonly CHAR_WAP_STATUS: string = '00020003-0000-1000-0000-D8492FFFA821';
  /** 交接 SSID（read，`C0235b.java:426-428`）。 */
  static readonly CHAR_WAP_SSID: string = '00020004-0000-1000-0000-D8492FFFA821';
  /** 交接 password（read，绝不落库/打全串）。 */
  static readonly CHAR_WAP_PASSWORD: string = '00020005-0000-1000-0000-D8492FFFA821';
  /** 交接安全类型列表（read，int32 小端数组）。 */
  static readonly CHAR_WAP_SECURITY: string = '00020006-0000-1000-0000-D8492FFFA821';

  /** 标准 Device Information 服务（`C0235b.java:993-1001`）。 */
  static readonly SERVICE_DEVICE_INFO: string = '0000180A-0000-1000-8000-00805F9B34FB';
  static readonly CHAR_MANUFACTURER: string = '00002A29-0000-1000-8000-00805F9B34FB';
  /** Model Number（机型）。 */
  static readonly CHAR_MODEL_NUMBER: string = '00002A24-0000-1000-8000-00805F9B34FB';
  /** Firmware Revision（`C0235b.java:799-811`，仅当能力位 0x80 时采信）。 */
  static readonly CHAR_FIRMWARE: string = '00002A26-0000-1000-8000-00805F9B34FB';
  static readonly CHAR_SOFTWARE: string = '00002A28-0000-1000-8000-00805F9B34FB';
  /** Serial Number（`C0235b.java:818-825`）。 */
  static readonly CHAR_SERIAL: string = '00002A25-0000-1000-8000-00805F9B34FB';

  /** CCCD：notify=`01 00`、indicate=`02 00`（`C0291p.java:417-438`）。 */
  static readonly CCCD: string = '00002902-0000-1000-8000-00805F9B34FB';

  /**
   * 扫描过滤 UUID 列表。
   *
   * 报告 01 §1.1【观察】：官方只有这一个 `ScanFilter`，没有名字/厂商数据/服务数据
   * 过滤；契约 §2.1 同样要求「唯一 ScanFilter」。**不要**往这里加第二项。
   */
  static readonly SCAN_SERVICE_UUIDS: string[] = ['00010000-0000-1000-0000-D8492FFFA821'];

  /** 4 位短 UUID -> 128-bit 全串。 */
  static full(short: string): string {
    return short.toUpperCase() + CanonBleUuids.BASE_SUFFIX;
  }

  /** 日志里只打印前 8 位（契约 §0.6：不得打印 UUID 全串）。 */
  static shortLabel(uuid: string): string {
    const text = uuid.length > 8 ? uuid.substring(0, 8) : uuid;
    return text.toUpperCase();
  }

  /** 128-bit 全等（忽略大小写与连字符）；平台只回 4 位短 UUID 时按 BT 短格式换算。 */
  static same(actual: string, expected: string): boolean {
    const left = CanonBleUuids.normalize(actual);
    const right = CanonBleUuids.normalize(expected);
    if (left.length === 0 || right.length === 0) return false;
    if (left === right) return true;
    // 16-bit 短 UUID 落在 128-bit 的第一个 32 位组的后 4 位（BT 基址规则）。
    if (left.length === 4 && right.length === 32) return right.substring(4, 8) === left;
    if (right.length === 4 && left.length === 32) return left.substring(4, 8) === right;
    return false;
  }

  /** 去连字符 + 小写（广播里的 UUID 是无连字符的 32 位 hex，平台回包带连字符）。 */
  static normalize(uuid: string): string {
    const source = (uuid === undefined || uuid === null) ? '' : uuid;
    return source.replace(/-/g, '').toLowerCase();
  }

  /**
   * 32 位 hex -> `8-4-4-4-12` 大写（契约 §2.2 的展示口径）。
   * 身份键（`cameraUuid` / `btAddress`）仍用不含连字符的 32 位形式，这里只给
   * 界面/日志排版用；长度不对时原样返回。
   */
  static dashed(identity: string): string {
    const hex = CanonBleUuids.normalize(identity).toUpperCase();
    if (hex.length !== 32) return identity;
    return `${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-` +
      `${hex.substring(16, 20)}-${hex.substring(20)}`;
  }
}

// ---------------------------------------------------------------------------
// 广播解析（报告 01 §1.2，C0243d.java:31-107）
// ---------------------------------------------------------------------------

/** 广播里解析出的机型身份与状态。 */
export interface CanonAdvInfo {
  /** 厂商数据首字节，必须为 1（`C0243d.java:51`）。 */
  organize: number;
  /** USB Product ID = 素材表/固件清单的产品号；0 表示未给出。 */
  pid: number;
  /** 相机 128-bit UUID，32 位大写 hex（稳定身份，契约 §0.3）。 */
  cameraUuid: string;
  /** flags bit0（`C0243d.java:81`）。 */
  paired: boolean;
  /** flags bit1-2：0/1/2（`C0243d.java:82`、`C0251f.java:115-147`）。 */
  powerState: number;
  /** true = 19 字节长格式（含完整 UUID），false = 6 字节短格式。 */
  longForm: boolean;
}

/** 一条完整广播的解析结果（含本地名与是否带会话服务）。 */
export interface CanonAdRecord {
  info: CanonAdvInfo;
  /** AD type 0x08/0x09 的本地名（原样，未清理）。 */
  name: string;
  /** 广播里是否含 `00010000` 服务 UUID（二次校验，不作为入列条件）。 */
  hasSessionService: boolean;
}

/** 厂商数据（Company ID 425 = 0x01A9 = Canon）的偏移与掩码。 */
export class CanonAdv {
  /** `getManufacturerSpecificData(425)`（`C0243d.java:36`）。 */
  static readonly COMPANY_ID: number = 425;
  /** `[0]` 数据类型，只有 1 才是 Canon BLE 相机（`C0243d.java:51`）。 */
  static readonly ORGANIZE_VALID: number = 1;
  /** 长格式总长（`C0243d.java:56`）。 */
  static readonly LENGTH_LONG: number = 19;
  /** 短格式总长（`C0243d.java:65`）。 */
  static readonly LENGTH_SHORT: number = 6;
  /** `[1..2]` usbId（小端，`C0243d.java:52-55`）。 */
  static readonly OFFSET_PID: number = 1;
  /** `[3..18]` 16 字节相机 UUID（小端，`C0243d.java:59-60`）。 */
  static readonly OFFSET_UUID_LONG: number = 3;
  /** 短格式 `[3..4]` = UUID 低 2 字节（`C0243d.java:69`）。 */
  static readonly OFFSET_UUID_SHORT: number = 3;
  /** 短格式 `[5]` = flags（`C0243d.java:79`）。 */
  static readonly OFFSET_FLAGS_SHORT: number = 5;
  static readonly UUID_BYTES: number = 16;
  /** bit0 = 已配对（`C0243d.java:81`）。 */
  static readonly FLAG_PAIRED: number = 1;
  /** bit1-2 = 配对/电源状态（`C0243d.java:82`）。 */
  static readonly POWER_SHIFT: number = 1;
  static readonly POWER_MASK: number = 3;
  /** 电源状态取值（`V.java:134-147`）。 */
  static readonly POWER_AUTO_OFF: number = 0;
  static readonly POWER_ON: number = 1;
  static readonly POWER_SWITCH_OFF: number = 2;
}

export class CanonAdvParser {
  /**
   * 解析厂商数据载荷（**不含** 2 字节 Company ID）。
   *
   * 严格照 `C0243d.java:47-83`：organize != 1 直接否定；长度只认 19 / 6；
   * 其余长度（含截断）一律返回 null，不猜。
   */
  static parseManufacturerData(payload: Uint8Array): CanonAdvInfo | null {
    if (payload.length < 3) return null;
    const organize = payload[0];
    if (organize !== CanonAdv.ORGANIZE_VALID) return null;
    // `[1..2]` 小端 usbId：jadx 先反转再 getShort，等价于直接小端读。
    const pid = CanonBytes.readU16(payload, CanonAdv.OFFSET_PID);
    if (payload.length === CanonAdv.LENGTH_LONG) {
      const uuidBytes = payload.subarray(CanonAdv.OFFSET_UUID_LONG,
        CanonAdv.OFFSET_UUID_LONG + CanonAdv.UUID_BYTES);
      const info: CanonAdvInfo = {
        organize: organize,
        pid: pid,
        cameraUuid: CanonAdvParser.uuidHexFromLittleEndian(uuidBytes),
        // 长格式不带 flags（`C0243d.java:63-64`：f5825e=0、f=1）。
        paired: false,
        powerState: 1,
        longForm: true,
      };
      return info;
    }
    if (payload.length === CanonAdv.LENGTH_SHORT) {
      // `C0243d.java:67-77`：把 `[3..4]` 反转后放进 16 字节数组的 [15][14]。
      const out = new Uint8Array(CanonAdv.UUID_BYTES);
      out[15] = payload[CanonAdv.OFFSET_UUID_SHORT + 1];
      out[14] = payload[CanonAdv.OFFSET_UUID_SHORT];
      const flags = payload[CanonAdv.OFFSET_FLAGS_SHORT];
      const info: CanonAdvInfo = {
        organize: organize,
        pid: pid,
        cameraUuid: CanonBytes.hexPlain(out),
        paired: (flags & CanonAdv.FLAG_PAIRED) !== 0,
        powerState: (flags >> CanonAdv.POWER_SHIFT) & CanonAdv.POWER_MASK,
        longForm: false,
      };
      return info;
    }
    return null;
  }

  /**
   * 解析一整条广播（AD 结构串）。
   *
   * 报告 01 §1.1：官方只按服务 UUID 过滤，因此入列判定看厂商数据 425 的
   * `organize==1`；服务 UUID 只用来补充 `hasSessionService`（部分机型广播被
   * 系统截断时，服务 UUID 仍在）。
   */
  static parseAdvert(data: ArrayBuffer): CanonAdRecord | null {
    if (data === undefined || data === null || data.byteLength === 0) return null;
    const bytes = new Uint8Array(data);
    let offset = 0;
    let name = '';
    let manufacturer: Uint8Array = new Uint8Array(0);
    let hasSessionService = false;
    while (offset + 1 < bytes.length) {
      const length = bytes[offset];
      if (length === 0) break;
      const type = bytes[offset + 1];
      const bodyStart = offset + 2;
      const bodyEnd = Math.min(offset + 1 + length, bytes.length);
      if (bodyEnd <= bodyStart) {
        offset += 1 + length;
        continue;
      }
      const body = bytes.subarray(bodyStart, bodyEnd);
      if (type === 0x08 || type === 0x09) {
        name = CanonBytes.textUntilNul(body);
      } else if (type === 0xFF && body.length >= 3) {
        const companyId = CanonBytes.readU16(body, 0);
        if (companyId === CanonAdv.COMPANY_ID && manufacturer.length === 0) {
          manufacturer = body.subarray(2);
        }
      } else if (type === 0x06 || type === 0x07) {
        for (let at = 0; at + 16 <= body.length; at += 16) {
          const uuid = CanonAdvParser.uuidHexFromLittleEndian(body.subarray(at, at + 16));
          if (CanonBleUuids.same(uuid, CanonBleUuids.SERVICE_SESSION)) hasSessionService = true;
        }
      }
      offset += 1 + length;
    }
    if (manufacturer.length === 0) return null;
    const info = CanonAdvParser.parseManufacturerData(manufacturer);
    if (info === null) return null;
    const record: CanonAdRecord = {
      info: info,
      name: name,
      hasSessionService: hasSessionService,
    };
    return record;
  }

  /**
   * 16 字节小端 UUID -> 32 位大写 hex。
   *
   * 对应 `C0243d.java:58-62`：先 `C0251f.d()` 反转，再按大端读两个 long 组成
   * `java.util.UUID`。这里直接按反转后的字节序输出 hex，与
   * `C0291p.v()`（`uuid.toString().substring(32,36)`）取尾 4 位一致。
   */
  static uuidHexFromLittleEndian(bytes: Uint8Array): string {
    const out = new Uint8Array(CanonAdv.UUID_BYTES);
    const count = Math.min(bytes.length, CanonAdv.UUID_BYTES);
    // 反转：最低字节在前 -> 最高字节在前。
    for (let index = 0; index < count; index++) {
      out[CanonAdv.UUID_BYTES - 1 - index] = bytes[index];
    }
    return CanonBytes.hexPlain(out);
  }
}

// ---------------------------------------------------------------------------
// 应用层帧（报告 01 §3.1/§3.2/§5.1）
// ---------------------------------------------------------------------------

/**
 * 应用层帧：`[1 字节命令][裸 payload]`，无长度/头/CRC，
 * 字符串 US-ASCII，多字节整数小端，全部 Write Without Response
 * （报告 01 §3.1 / `C0291p.java:399-405`）。
 */
export class CanonFrames {
  // ---- 注册通道 00010006（C0291p.java:236-241）----
  static readonly CMD_REGISTER: number = 0x01;
  /** 相机 indicate 的首字节 = 2 表示注册成功（`C0235b.java:71-84`）。 */
  static readonly ACK_REGISTER_OK: number = 0x02;
  /** 昵称上限：契约 §2.3 取 20 字节（实际长度以相机能力为准）。 */
  static readonly NICKNAME_MAX_BYTES: number = 20;

  // ---- 会话命令 0001000a（T.java / V.java:149-197）----
  static readonly CMD_SESSION_UUID: number = 0x03;
  static readonly CMD_SESSION_NICKNAME: number = 0x04;
  static readonly CMD_SESSION_TYPE: number = 0x05;
  /** TYPE 的载荷固定 `02`（`V.java:181` + `V.f5692z = {05,02}`）。 */
  static readonly SESSION_TYPE_VALUE: number = 0x02;
  static readonly CMD_MODEL_NAME_FIRST: number = 0x06;
  static readonly CMD_MODEL_NAME_SECOND: number = 0x07;
  static readonly CMD_WIFI_BAND: number = 0x08;
  static readonly CMD_PROHIBIT_AUTO_POWER_OFF: number = 0x0A;
  /** `0A 01` = 禁止自动关机（`C0291p.java:353-354`）。 */
  static readonly PROHIBIT_ON: number = 0x01;
  /** `0A 02` = 允许自动关机。 */
  static readonly PROHIBIT_OFF: number = 0x02;

  // ---- WAP 00020002（C.java:83-95 / C.java:120-146）----
  static readonly WAP_START: number = 0x01;
  static readonly WAP_STOP: number = 0x02;
  static readonly WAP_REQUEST_CANCEL: number = 0x03;
  static readonly WAP_START_WITH_SECURITY: number = 0x04;
  static readonly WAP_REQUEST_AP_CONFIG: number = 0x0A;
  /** 未使用（`B.GET_RESPONCE_DATA`，报告 01 §5.1）。 */
  static readonly WAP_GET_RESPONSE_DATA: number = 0x7F;

  /** `01`（`C.f5030v`）。 */
  static wapStart(): Uint8Array {
    return new Uint8Array([CanonFrames.WAP_START]);
  }

  /** `02`（`C.f5031w`）。 */
  static wapStop(): Uint8Array {
    return new Uint8Array([CanonFrames.WAP_STOP]);
  }

  /** `03`（`C.f5032x`）。 */
  static wapCancel(): Uint8Array {
    return new Uint8Array([CanonFrames.WAP_REQUEST_CANCEL]);
  }

  /** `0A`（`C.f5034z`）。 */
  static wapRequestApConfig(): Uint8Array {
    return new Uint8Array([CanonFrames.WAP_REQUEST_AP_CONFIG]);
  }

  /**
   * `04` + int32 小端（`C.java:132-144`：`ByteBuffer.putInt(9)` 后 `d()` 反转
   * → `04 09 00 00 00`）。调用方必须先确认 `00020001` bit4 且安全列表含该值。
   */
  static wapStartWithSecurity(securityType: number): Uint8Array {
    const out = new Uint8Array(5);
    out[0] = CanonFrames.WAP_START_WITH_SECURITY;
    out.set(CanonBytes.u32(securityType), 1);
    return out;
  }

  /** 注册帧 `01` + 昵称 ASCII，昵称截断到 20 字节（`C0291p.java:236-241`）。 */
  static registration(nickname: string): Uint8Array {
    const nameBytes = CanonBytes.ascii(nickname);
    const count = Math.min(nameBytes.length, CanonFrames.NICKNAME_MAX_BYTES);
    const out = new Uint8Array(count + 1);
    out[0] = CanonFrames.CMD_REGISTER;
    out.set(nameBytes.subarray(0, count), 1);
    return out;
  }

  /**
   * `03` + 16 字节 UUID（小端）。
   *
   * `V.java:164-170`：`EOSCore.f(uuid)` 先按大端取出 16 字节，再 `C0251f.d()`
   * 反转写入，所以线上是 UUID 的逆序。
   */
  static sessionUuid(uuidHex: string): Uint8Array {
    const raw = CanonBytes.bytesFromHex(uuidHex);
    if (raw.length !== CanonAdv.UUID_BYTES) {
      return new Uint8Array(0);
    }
    const out = new Uint8Array(17);
    out[0] = CanonFrames.CMD_SESSION_UUID;
    out.set(CanonBytes.reverse(raw), 1);
    return out;
  }

  /** `04` + 昵称 ASCII（`V.java:172-179`）。 */
  static sessionNickname(nickname: string): Uint8Array {
    const nameBytes = CanonBytes.ascii(nickname);
    const out = new Uint8Array(nameBytes.length + 1);
    out[0] = CanonFrames.CMD_SESSION_NICKNAME;
    out.set(nameBytes, 1);
    return out;
  }

  /** `05 02`（`V.java:180-182` + `V.f5692z`）。 */
  static sessionType(): Uint8Array {
    return new Uint8Array([CanonFrames.CMD_SESSION_TYPE, CanonFrames.SESSION_TYPE_VALUE]);
  }

  /** `0A 01` 禁止 / `0A 02` 允许自动关机（`C0291p.java:351-355`）。 */
  static prohibitAutoPowerOff(prohibit: boolean): Uint8Array {
    return new Uint8Array([CanonFrames.CMD_PROHIBIT_AUTO_POWER_OFF,
      prohibit ? CanonFrames.PROHIBIT_ON : CanonFrames.PROHIBIT_OFF]);
  }
}

// ---------------------------------------------------------------------------
// 0001000c WiFi 事件（报告 01 §3.4，C0235b.java:95-123）
// ---------------------------------------------------------------------------

export class CanonWifiEvent {
  /** `[1][SSID ASCII…]`。 */
  static readonly TYPE_SSID: number = 1;
  /** `[2][password ASCII…]`。 */
  static readonly TYPE_PASSWORD: number = 2;
  /** `[3][security]`。 */
  static readonly TYPE_SECURITY: number = 3;
  /** `[4][result]`。 */
  static readonly TYPE_RESULT: number = 4;
  /** `[5]` WiFi 扫描列表（16 字节分片；本实现不使用，见报告 01 §2.2 末注）。 */
  static readonly TYPE_SCAN_LIST: number = 5;
  /** `[6]` 安全类型列表（本实现不使用）。 */
  static readonly TYPE_SECURITY_LIST: number = 6;
  /** `04 01` = 成功（`C0235b.java:115-123`）。 */
  static readonly RESULT_OK: number = 1;
  /** 结果 2 -> 错误码 268436498。 */
  static readonly RESULT_FAILED: number = 2;
  /** 结果 3 -> 错误码 268436499。 */
  static readonly RESULT_CANCELLED: number = 3;
}

// ---------------------------------------------------------------------------
// 能力位（报告 01 §3.3，C0235b.java:832-841）
// ---------------------------------------------------------------------------

export class CanonCapability {
  /** 支持 `0001000c` type1/2（SSID + 密码）。 */
  static readonly SSID_PASSWORD: number = 0x08;
  /** 支持安全类型协商。 */
  static readonly SECURITY_NEGOTIATION: number = 0x10;
  /** 【未知】（报告 01 §3.3 表）。 */
  static readonly RESERVED_0X20: number = 0x20;
  /** 支持 PROHIBIT_AUTO_POWER_OFF。 */
  static readonly PROHIBIT_AUTO_POWER_OFF: number = 0x40;
  /** 支持读 2a26 固件版本。 */
  static readonly FIRMWARE_REVISION: number = 0x80;
  /** 【未知】。 */
  static readonly RESERVED_0X100: number = 0x100;

  static has(bitmap: number, mask: number): boolean {
    return (bitmap & mask) === mask;
  }

  static describe(bitmap: number): string {
    if (bitmap === 0) return '0x00000000(未知)';
    const parts: string[] = [];
    if (CanonCapability.has(bitmap, CanonCapability.SSID_PASSWORD)) parts.push('ssid+pass');
    if (CanonCapability.has(bitmap, CanonCapability.SECURITY_NEGOTIATION)) parts.push('security');
    if (CanonCapability.has(bitmap, CanonCapability.PROHIBIT_AUTO_POWER_OFF)) parts.push('no-sleep');
    if (CanonCapability.has(bitmap, CanonCapability.FIRMWARE_REVISION)) parts.push('firmware');
    return CanonBytes.hex(bitmap, 8) + '[' + parts.join(',') + ']';
  }
}

/** WAP 能力位（`C.java:97-117`）。 */
export class CanonWapCapability {
  /** handover READY 的固定位（`C.java:99`）。 */
  static readonly READY_BASE: number = 0x1;
  /** bit4：支持带安全类型 START（`C.java:117`）。 */
  static readonly SECURITY_TYPE: number = 0x10;
  /** TLV 收到 IP 后置位（`C0235b.java:409`）。 */
  static readonly SET_IP: number = 0x100;
  /** TLV 收到 BSSID 后置位（`C0235b.java:417`）。 */
  static readonly SET_BSSID: number = 0x1000;
  /** TLV 收到 WTIME 后置位（`C0235b.java:423`）。 */
  static readonly SET_WTIME: number = 0x10000;
  /**
   * `C.a()` 判定 READY 时用的最后一位是 `0x100000`（`C.java:103`），而 TLV 解析
   * 只置 `0x10000`（`C0235b.java:423`）。两者不一致，说明该判据在当前版本不可达
   * （或另有来源置 `0x100000`）。我们**不以位图判 READY**，只看 `00020003`
   * 状态 + TLV，这里保留常量仅用于日志对照。
   */
  static readonly READY_MASK_LEGACY: number = 0x100000;

  static has(bitmap: number, mask: number): boolean {
    return (bitmap & mask) === mask;
  }
}

// ---------------------------------------------------------------------------
// WAP 状态与 TLV（报告 01 §5.2/§5.3）
// ---------------------------------------------------------------------------

/** `00020003` 的 `[Code][SubCode]` 分类结果。 */
export interface CanonWapStatusInfo {
  code: number;
  subCode: number;
  /** START 被受理（Code=1/SubCode=3，或 Code=2/SubCode=3）。 */
  accepted: boolean;
  /** START 被拒（Code=1，SubCode=4..9）。 */
  rejected: boolean;
  /** 日志用描述。 */
  label: string;
}

export class CanonWapStatus {
  static readonly CODE_START: number = 1;
  /** Code=2 SubCode=3 在报告里被推断为 CANCEL 的应答（§5.3）。 */
  static readonly CODE_CANCEL_ACK: number = 2;
  /** START_ACCEPTED（`C0235b.java:437-440`）。 */
  static readonly SUB_START_ACCEPTED: number = 3;
  /** START_REJECTED 区间起点（`C0235b.java:441-462`）。 */
  static readonly SUB_START_REJECTED_MIN: number = 4;
  /** START_REJECTED 区间终点。 */
  static readonly SUB_START_REJECTED_MAX: number = 9;
  /** Code=1 SubCode=2：请求事件（post(6)）。 */
  static readonly SUB_REQUEST_EVENT: number = 2;
  /** Code=1 SubCode=10：取消事件（post(7)）。 */
  static readonly SUB_CANCEL_EVENT: number = 10;

  /** 解析 `[Code][SubCode]`；字节不足返回全 0。 */
  static decode(value: Uint8Array): CanonWapStatusInfo {
    const code = value.length >= 1 ? value[0] : 0;
    const subCode = value.length >= 2 ? value[1] : 0;
    let accepted = false;
    let rejected = false;
    let label = 'UNKNOWN';
    if (code === CanonWapStatus.CODE_START) {
      if (subCode === CanonWapStatus.SUB_START_ACCEPTED) {
        accepted = true;
        label = 'START_ACCEPTED';
      } else if (subCode >= CanonWapStatus.SUB_START_REJECTED_MIN &&
        subCode <= CanonWapStatus.SUB_START_REJECTED_MAX) {
        rejected = true;
        label = 'START_REJECTED';
      } else if (subCode === CanonWapStatus.SUB_REQUEST_EVENT) {
        label = 'REQUEST_EVENT';
      } else if (subCode === CanonWapStatus.SUB_CANCEL_EVENT) {
        label = 'CANCEL_EVENT';
      }
    } else if (code === CanonWapStatus.CODE_CANCEL_ACK) {
      if (subCode === CanonWapStatus.SUB_START_ACCEPTED) {
        // 报告 01 §5.3【推断】：Code=2/SubCode=3 是 CANCEL 的应答，但日志文案
        // 同样是 START_ACCEPTED，这里按「受理」处理。
        accepted = true;
        label = 'START_ACCEPTED(Code2)';
      }
    }
    const info: CanonWapStatusInfo = {
      code: code,
      subCode: subCode,
      accepted: accepted,
      rejected: rejected,
      label: label,
    };
    return info;
  }
}

/** `00020002` notify 的 TLV 解析结果。 */
export interface CanonWapTlvInfo {
  ip: string;
  bssid: string;
  /** 毫秒。报告 01 §5.2 的 `%d00` = 100 ms 计数 × 100。 */
  wtime: number;
  hasIp: boolean;
  hasBssid: boolean;
  hasWtime: boolean;
  /** 实际解析到的 TLV 个数（诊断用）。 */
  tagCount: number;
}

/**
 * WAP TLV：`tag(1)+len(1)+value(len)`。
 *
 * 报告 01 §5.2 与 `C0235b.java:363-365`：**无条件**跳过前 2 字节
 * （`value[0]==0x10` 时官方只打一行 “Receive WAP CP Response” 日志）。
 */
export class CanonWapTlv {
  static readonly TAG_IP: number = 0x10;
  static readonly TAG_BSSID: number = 0x02;
  static readonly TAG_WTIME: number = 0x30;
  /** 前 2 字节为响应头（`C0235b.java:363-365`）。 */
  static readonly HEADER_BYTES: number = 2;

  /**
   * 解析一条 notify。
   *
   * 主路径照 `C0235b.java:363-365` 无条件跳过前 2 字节；主路径解析出 0 个 TLV
   * 时再按「无响应头」重试一次（【推断】：老固件可能直接给 TLV；只有主路径
   * 完全失败才走这条路，不会把带头的报文误读成 TLV）。
   */
  static parse(raw: Uint8Array): CanonWapTlvInfo {
    const withHeader = CanonWapTlv.scan(raw, CanonWapTlv.HEADER_BYTES);
    if (CanonWapTlv.hasKnownTag(withHeader)) return withHeader;
    if (raw.length >= 3) {
      const withoutHeader = CanonWapTlv.scan(raw, 0);
      if (CanonWapTlv.hasKnownTag(withoutHeader)) return withoutHeader;
    }
    return withHeader;
  }

  /** 至少解析到一个已知 tag（IP/BSSID/WTIME）才算「报文形状对」。 */
  private static hasKnownTag(info: CanonWapTlvInfo): boolean {
    return info.hasIp || info.hasBssid || info.hasWtime;
  }

  private static scan(raw: Uint8Array, start: number): CanonWapTlvInfo {
    let ip = '';
    let bssid = '';
    let wtime = 0;
    let hasIp = false;
    let hasBssid = false;
    let hasWtime = false;
    let tagCount = 0;
    let offset = start;
    while (offset + 2 <= raw.length) {
      const tag = raw[offset];
      const length = raw[offset + 1];
      const valueStart = offset + 2;
      const valueEnd = valueStart + length;
      if (valueEnd > raw.length) break; // 截断的 TLV：停止，不越界
      const value = raw.subarray(valueStart, valueEnd);
      tagCount += 1;
      if (tag === CanonWapTlv.TAG_IP && value.length >= 4) {
        // 4B 小端：反转后按 `%d.%d.%d.%d` 输出（`C0235b.java:396-411`）。
        const ordered = CanonBytes.reverse(value.subarray(0, 4));
        ip = `${ordered[0]}.${ordered[1]}.${ordered[2]}.${ordered[3]}`;
        hasIp = true;
      } else if (tag === CanonWapTlv.TAG_BSSID && value.length >= 6) {
        // 6B 小端：反转后 12 位大写 hex，无分隔（`C0235b.java:415-419`）。
        bssid = CanonBytes.hexPlain(CanonBytes.reverse(value.subarray(0, 6)));
        hasBssid = true;
      } else if (tag === CanonWapTlv.TAG_WTIME && value.length >= 1) {
        // 官方只读 1 字节且**不反转**，再 `%d00`（`C0235b.java:421-424`）。
        // 契约 §2.3 记作 4B：这里两种都接受——>=4 按小端 u32 读，单位仍是
        // 100 ms（推断：1 字节是同一计数器的截断）。
        const ticks = value.length >= 4 ? CanonBytes.readU32(value, 0) : value[0];
        wtime = ticks * 100;
        hasWtime = true;
      }
      offset = valueEnd;
    }
    const info: CanonWapTlvInfo = {
      ip: ip,
      bssid: bssid,
      wtime: wtime,
      hasIp: hasIp,
      hasBssid: hasBssid,
      hasWtime: hasWtime,
      tagCount: tagCount,
    };
    return info;
  }
}

/** 安全类型（报告 01 §3.4 末段，按 `V0` ordinal 推断，枚举名未经真机确认）。 */
export class CanonSecurityType {
  static readonly OPEN: number = 1;
  static readonly WPA_PSK: number = 3;
  static readonly WPA2_PSK: number = 6;
  static readonly WPA_WPA2_PSK: number = 7;
  static readonly WPA3_SAE: number = 11;
  static readonly WPA2_WPA3_SAE: number = 12;
  static readonly WPA2_WPA3_SAE_ALT: number = 13;
  /**
   * 带安全类型 START 的固定值 9（`C.java:140` 硬编码 `putInt(9)`；
   * 报告 01 §9.4 明确该枚举名未取得）。
   */
  static readonly PREFERRED_START_TYPE: number = 9;

  static label(value: number): string {
    if (value === CanonSecurityType.OPEN) return 'OPEN';
    if (value === CanonSecurityType.WPA_PSK) return 'WPA_PSK';
    if (value === CanonSecurityType.WPA2_PSK) return 'WPA2_PSK';
    if (value === CanonSecurityType.WPA_WPA2_PSK) return 'WPA_WPA2_PSK';
    if (value === CanonSecurityType.WPA3_SAE) return 'WPA3_SAE';
    if (value === CanonSecurityType.WPA2_WPA3_SAE ||
      value === CanonSecurityType.WPA2_WPA3_SAE_ALT) return 'WPA2_WPA3_SAE';
    return 'SECURITY_' + value.toString();
  }
}

// ---------------------------------------------------------------------------
// 错误
// ---------------------------------------------------------------------------

/** `CanonBleError.code` 取值（0 保留给「本地/未知」）。 */
export class CanonBleErrorCode {
  static readonly LOCAL: number = 0;
  static readonly NOT_CONNECTED: number = 1;
  static readonly CHARACTERISTIC_MISSING: number = 2;
  static readonly WRITE_FAILED: number = 3;
  static readonly READ_FAILED: number = 4;
  static readonly TIMEOUT: number = 5;
  static readonly BOND_FAILED: number = 6;
  static readonly REGISTER_REJECTED: number = 7;
  static readonly WAP_REJECTED: number = 8;
  static readonly INVALID_ARGUMENT: number = 9;
  static readonly CREDENTIAL_UNAVAILABLE: number = 10;
}

/**
 * Canon BLE 唯一异常类型。
 *
 * `detail` 保留「哪一步/哪个特征/相机回了什么」的可读细节（用短 UUID，不含密码）；
 * `code` 见 `CanonBleErrorCode`。所有对外方法的异常都必须是本类型
 * （契约 §0.7：禁止裸 `Error` 泄漏给页面）。
 */
export class CanonBleError extends Error {
  readonly code: number;
  readonly detail: string;

  constructor(code: number, message: string, detail: string) {
    super(message.length > 0 ? message : detail);
    this.name = 'CanonBleError';
    this.code = code;
    this.detail = detail.length > 0 ? detail : message;
  }

  /** 把任意系统异常包成 `CanonBleError`，保留 HarmonyOS 的 `code`（如 2900099）。 */
  static wrap(error: Object, code: number, context: string): CanonBleError {
    const described = CanonBleError.describe(error);
    return new CanonBleError(code, `${context}：${described}`,
      `context=${context}; error=${described}`);
  }

  /** 渲染 `message（code N）`；系统错误码是唯一可诊断字段（同尼康线注释）。 */
  static describe(error: Object): string {
    const typed = error as BusinessError;
    const message = typed !== null && typed !== undefined && typed.message !== undefined &&
      typed.message.length > 0 ? typed.message : String(error);
    const code = typed !== null && typed !== undefined ? typed.code : undefined;
    return code !== undefined ? `${message}（code ${code}）` : message;
  }
}
