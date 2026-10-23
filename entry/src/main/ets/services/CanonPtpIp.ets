/**
 * 佳能 EOS 的 PTP/IP 传输层（ISO 15740 / CIPA DC-X005）。
 *
 * 证据链（契约 §3 的全部条目都能在这里找到落点）：
 *  - 双 TCP 15740 + Init_Command/Event 握手：`report 03 §1.1`、libgphoto2 `ptpip.c`
 *    （`ptpip_cmd_write` / `ptpip_evt_read` 的包类型 1/2/3/4/6/7/8/9/10/11）；
 *  - OpenSession → SetRemoteMode(0x9114) → SetEventMode(0x9115) → KeepDeviceOn(0x911D)：
 *    `report 02 §7` ①，opcode 见 `ptp.h:0x9114/0x9115/0x911D`；
 *  - EOS 事件 blob 结构：`ptp-pack.c:1861` 的 `ptp_unpack_EOS_events`
 *    （`[size u32][code u32][payload]`，属性值 @0x0c、可选值列表 @0x14）。
 *
 * 设计取舍：
 *  - 传输层只做「一个事务一个响应」，不解析业务数据集；图传/控制各自解析，
 *    这样任一方的数据集误读都不会拖垮另一方；
 *  - 所有读都有 deadline；socket 断链后挂起事务统一 reject（契约 §3.2）；
 *  - `DeviceBusy(0x2019)` 自动重试一次（契约 §3.2）；
 *  - 事件通道常驻读循环，只做「收包 → 回调」，不在这里轮询 `GetEvent`
 *    （EOS 的 GetEvent(0x9116) 由控制服务按自己的节奏调用）。
 */
import { socket } from '@kit.NetworkKit';
import { AppLogSink } from './AppLogSink';

const TAG: string = 'CANON_PTP';

/** PTP-IP 包类型（CIPA DC-X005 §4）。 */
export class CanonPacketType {
  static readonly INIT_COMMAND_REQUEST: number = 1;
  static readonly INIT_COMMAND_ACK: number = 2;
  static readonly INIT_EVENT_REQUEST: number = 3;
  static readonly INIT_EVENT_ACK: number = 4;
  static readonly INIT_FAIL: number = 5;
  static readonly OPERATION_REQUEST: number = 6;
  static readonly OPERATION_RESPONSE: number = 7;
  static readonly EVENT: number = 8;
  static readonly START_DATA: number = 9;
  static readonly DATA: number = 10;
  static readonly END_DATA: number = 11;
  static readonly CANCEL_TRANSACTION: number = 12;
}

/** DataPhaseInfo（CIPA 口径：1=无数据、2=DataIn、3=DataOut）。 */
export class CanonDataPhase {
  static readonly NONE: number = 1;
  static readonly IN: number = 2;
  static readonly OUT: number = 3;
}

/** PTP 通用响应码（只列本文件用到的）。 */
export class CanonPtpResponse {
  static readonly OK: number = 0x2001;
  static readonly GENERAL_ERROR: number = 0x2002;
  static readonly SESSION_NOT_OPEN: number = 0x2003;
  static readonly OPERATION_NOT_SUPPORTED: number = 0x2005;
  static readonly PARAMETER_NOT_SUPPORTED: number = 0x2006;
  static readonly DEVICE_BUSY: number = 0x2019;
  static readonly INCOMPLETE_TRANSFER: number = 0x2007;
  static readonly INVALID_TRANSACTION_ID: number = 0x200C;
  static readonly NO_VALID_OBJECT_INFO: number = 0x2009;
}

/** EOS 操作码（libgphoto2 `ptp2/ptp.h`，行号见各常量）。 */
export class CanonEosOp {
  static readonly GET_DEVICE_INFO: number = 0x1001;
  static readonly OPEN_SESSION: number = 0x1002;
  static readonly CLOSE_SESSION: number = 0x1003;
  static readonly GET_STORAGE_IDS: number = 0x9101;
  static readonly GET_STORAGE_IDS_STD: number = 0x1004;
  static readonly GET_STORAGE_INFO: number = 0x9102;
  static readonly GET_STORAGE_INFO_STD: number = 0x1005;
  static readonly GET_OBJECT_HANDLES: number = 0x1007;
  static readonly GET_OBJECT_INFO: number = 0x1008;
  static readonly GET_OBJECT: number = 0x1009;
  static readonly GET_THUMB: number = 0x100A;
  static readonly SET_DEVICE_PROP_VALUE_EX: number = 0x9110;
  static readonly GET_DEVICE_PROP_VALUE: number = 0x1015;
  static readonly REQUEST_DEVICE_PROP_VALUE: number = 0x9127;
  static readonly GET_EVENT: number = 0x9116;
  static readonly SET_REMOTE_MODE: number = 0x9114;
  static readonly SET_EVENT_MODE: number = 0x9115;
  static readonly KEEP_DEVICE_ON: number = 0x911D;
  static readonly REMOTE_RELEASE_ON: number = 0x9128;
  static readonly REMOTE_RELEASE_OFF: number = 0x9129;
  static readonly INITIATE_VIEWFINDER: number = 0x9151;
  static readonly TERMINATE_VIEWFINDER: number = 0x9152;
  static readonly GET_VIEWFINDER_DATA: number = 0x9153;
  static readonly DO_AF: number = 0x9154;
  static readonly DRIVE_LENS: number = 0x9155;
  static readonly DRIVE_POWER_ZOOM: number = 0x914D;
  static readonly ZOOM: number = 0x9158;
  static readonly SET_LIVE_AF_FRAME: number = 0x915A;
  static readonly AF_CANCEL: number = 0x9160;
  static readonly GET_PARTIAL_OBJECT: number = 0x912C;
  static readonly END_GET_PARTIAL_OBJECT: number = 0x9132;
  static readonly UPDATE_FIRMWARE: number = 0x911F;
  static readonly SEND_OBJECT_INFO: number = 0x100C;
  static readonly SEND_OBJECT: number = 0x100D;
}

/** EOS 事件码（`ptp.h` / 报告 02 §1.3）。 */
export class CanonEosEventCode {
  static readonly PROP_VALUE_CHANGED: number = 0xC189;
  static readonly AVAIL_LIST_CHANGED: number = 0xC18A;
  static readonly OBJECT_ADDED_EX: number = 0xC181;
  static readonly OBJECT_INFO_CHANGED_EX: number = 0xC187;
  static readonly STORAGE_STATUS_CHANGED: number = 0xC184;
  static readonly STORE_ADDED: number = 0xC192;
  static readonly STORE_REMOVED: number = 0xC193;
}

/** 相机设备信息（GetDeviceInfo 数据集的子集）。 */
export interface CanonDeviceInfo {
  manufacturer: string;
  model: string;
  deviceVersion: string;
  serialNumber: string;
  standardOps: number[];
  vendorOps: number[];
  vendorExtId: number;
}

export interface CanonPtpReply {
  code: number;
  params: number[];
}

export interface CanonPtpDataReply {
  reply: CanonPtpReply;
  data: Uint8Array;
}

/** 一条 EOS 事件（来自 0x9116 的 blob 或异步 Event 包）。 */
export interface CanonEosEvent {
  code: number;
  params: number[];
  data: Uint8Array;
}

/** 传输层错误：带 PTP 码与 opcode，便于页面显示与日志定位。 */
export class CanonPtpError extends Error {
  readonly code: number;
  readonly opcode: number;
  readonly detail: string;

  constructor(code: number, opcode: number, detail: string) {
    super(detail);
    this.name = 'CanonPtpError';
    this.code = code;
    this.opcode = opcode;
    this.detail = detail;
  }
}

/** 超时标记（与富士线同法：用 Error.name 打标，避免子类在 ArkTS 里的边界问题）。 */
class CanonTimeoutMarker {
  static readonly NAME: string = 'CanonPtpTimeout';

  static create(message: string): Error {
    const error = new Error(message);
    error.name = CanonTimeoutMarker.NAME;
    return error;
  }

  static is(error: Error): boolean {
    return error.name === CanonTimeoutMarker.NAME;
  }
}

/**
 * 一条 PTP-IP TCP 通道：把任意切分的字节流拼成「8 字节包头 + 载荷」。
 *
 * 包头 = length(u32 LE，含头) + type(u32 LE)；只有单读者（事务串行、事件循环
 * 单线程），所以不需要多路唤醒。
 */
class CanonTcpChannel {
  private tcp: socket.TCPSocket | null = null;
  private chunk: Uint8Array = new Uint8Array(0);
  private wake: (() => void) | null = null;
  private waitTimer: number = -1;
  private failure: Error | null = null;
  private closing: boolean = false;
  private messageCallback: ((info: socket.SocketMessageInfo) => void) | null = null;
  private errorCallback: ((error: Error) => void) | null = null;

  isClosed(): boolean {
    return this.closing || this.failure !== null;
  }

  async connect(host: string, port: number, timeoutMs: number): Promise<void> {
    const tcp = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    this.messageCallback = (info: socket.SocketMessageInfo): void => {
      if (this.closing) return;
      if (info === undefined || info === null || info.message === undefined) return;
      this.append(new Uint8Array(info.message));
      this.notifyReader();
    };
    this.errorCallback = (error: Error): void => {
      this.fail(error instanceof Error ? error : new Error('PTP-IP socket error'));
    };
    tcp.on('message', this.messageCallback);
    tcp.on('error', this.errorCallback);
    try {
      await tcp.connect({ address: { address: host, family: 1, port: port }, timeout: timeoutMs });
    } catch (error) {
      const typed = error instanceof Error ? error : new Error(String(error));
      this.fail(typed);
      throw typed;
    }
    try {
      await tcp.setExtraOptions({ keepAlive: true, TCPNoDelay: true });
    } catch (_error) {
      CanonPtpIp.log('TCP 额外选项不可用（不影响协议）');
    }
  }

  async send(bytes: Uint8Array): Promise<void> {
    const failure = this.failure;
    if (failure !== null) throw failure;
    if (this.closing || this.tcp === null) throw new Error('PTP-IP 通道已关闭');
    const exact = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    await this.tcp.send({ data: exact });
  }

  async readExactly(size: number, timeoutMs: number): Promise<Uint8Array> {
    const deadline = Date.now() + timeoutMs;
    while (this.chunk.length < size) {
      const failure = this.failure;
      if (failure !== null) throw failure;
      if (this.closing) throw new Error('PTP-IP 通道已关闭');
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        throw CanonTimeoutMarker.create(`PTP-IP 读取超时（需要 ${size}，已有 ${this.chunk.length}）`);
      }
      await this.waitForReader(remaining);
    }
    const out = this.chunk.slice(0, size);
    this.chunk = this.chunk.slice(size);
    return out;
  }

  /** 读一个完整包，返回 {type, payload}。 */
  async readPacket(timeoutMs: number, maxLength: number): Promise<CanonPacket> {
    const header = await this.readExactly(8, timeoutMs);
    const view = new DataView(header.buffer, header.byteOffset, header.byteLength);
    const length = view.getUint32(0, true);
    const type = view.getUint32(4, true);
    if (length < 8 || length > maxLength) {
      throw new Error(`PTP-IP 包长度非法：${length}（type=${type}）`);
    }
    const payload = length > 8 ? await this.readExactly(length - 8, timeoutMs) : new Uint8Array(0);
    return { type: type, payload: payload };
  }

  close(): void {
    const pending = this.shutdown();
    if (pending !== null) pending.then((): void => {}, (): void => {});
  }

  async closeAndWait(): Promise<void> {
    const pending = this.shutdown();
    if (pending === null) return;
    try {
      await pending;
    } catch (_error) {
      // 平台侧可能已经因 Wi‑Fi 掉线关掉了 socket。
    }
  }

  fail(error: Error): void {
    if (this.failure !== null || this.closing) return;
    this.failure = error;
    this.shutdown();
  }

  private shutdown(): Promise<void> | null {
    if (this.closing) return null;
    this.closing = true;
    this.chunk = new Uint8Array(0);
    const reader = this.wake;
    this.wake = null;
    if (reader !== null) reader();
    const tcp = this.tcp;
    const messageCallback = this.messageCallback;
    const errorCallback = this.errorCallback;
    this.tcp = null;
    this.messageCallback = null;
    this.errorCallback = null;
    if (tcp === null) return null;
    try {
      if (messageCallback !== null) tcp.off('message', messageCallback);
      if (errorCallback !== null) tcp.off('error', errorCallback);
      return tcp.close();
    } catch (_error) {
      return null;
    }
  }

  private append(value: Uint8Array): void {
    if (value.length === 0) return;
    const next = new Uint8Array(this.chunk.length + value.length);
    next.set(this.chunk, 0);
    next.set(value, this.chunk.length);
    this.chunk = next;
  }

  private notifyReader(): void {
    const reader = this.wake;
    this.wake = null;
    if (reader !== null) reader();
  }

  private waitForReader(timeoutMs: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      let finished = false;
      const settle = (): void => {
        if (finished) return;
        finished = true;
        if (this.waitTimer !== -1) {
          clearTimeout(this.waitTimer);
          this.waitTimer = -1;
        }
        this.wake = null;
        resolve();
      };
      this.wake = settle;
      this.waitTimer = setTimeout(settle, timeoutMs) as number;
    });
  }
}

interface CanonPacket {
  type: number;
  payload: Uint8Array;
}

/** runExclusive 的释放句柄容器（见该方法注释）。 */
interface CanonReleaseHolder {
  release: (() => void) | null;
}

/** 小工具：小端读写 + 字节拼接。 */
export class CanonBytes {
  static buildPacket(type: number, payload: Uint8Array): Uint8Array {
    const out = new Uint8Array(8 + payload.length);
    const view = new DataView(out.buffer);
    view.setUint32(0, out.length, true);
    view.setUint32(4, type, true);
    out.set(payload, 8);
    return out;
  }

  static u32(value: number): Uint8Array {
    const out = new Uint8Array(4);
    new DataView(out.buffer).setUint32(0, value >>> 0, true);
    return out;
  }

  static u64(value: number): Uint8Array {
    const out = new Uint8Array(8);
    new DataView(out.buffer).setBigUint64(0, BigInt(Math.max(0, Math.floor(value))), true);
    return out;
  }

  static u16(value: number): Uint8Array {
    const out = new Uint8Array(2);
    new DataView(out.buffer).setUint16(0, value & 0xFFFF, true);
    return out;
  }

  static concat(parts: Uint8Array[]): Uint8Array {
    let total = 0;
    for (const part of parts) total += part.length;
    const out = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      out.set(part, offset);
      offset += part.length;
    }
    return out;
  }

  static readU32(data: Uint8Array, offset: number): number {
    if (offset + 4 > data.length) return 0;
    return new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(offset, true);
  }

  static readU16(data: Uint8Array, offset: number): number {
    if (offset + 2 > data.length) return 0;
    return new DataView(data.buffer, data.byteOffset, data.byteLength).getUint16(offset, true);
  }

  /** PTP 字符串：u8 长度（含结尾 NUL）+ ASCII/UTF-8 字节。 */
  static readString(data: Uint8Array, offset: number): CanonStringResult {
    if (offset >= data.length) return { value: '', next: offset };
    const length = data[offset];
    const start = offset + 1;
    const end = Math.min(start + length, data.length);
    let stop = end;
    for (let i = start; i < end; i++) {
      if (data[i] === 0) { stop = i; break; }
    }
    return { value: CanonBytes.decodeUtf8(data, start, stop), next: end };
  }

  static decodeUtf8(data: Uint8Array, start: number, end: number): string {
    let out = '';
    let i = start;
    while (i < end) {
      const byte = data[i];
      if (byte < 0x80) { out += String.fromCharCode(byte); i += 1; continue; }
      if (byte >= 0xC0 && byte < 0xE0 && i + 1 < end) {
        out += String.fromCharCode(((byte & 0x1F) << 6) | (data[i + 1] & 0x3F));
        i += 2; continue;
      }
      if (byte >= 0xE0 && byte < 0xF0 && i + 2 < end) {
        out += String.fromCharCode(((byte & 0x0F) << 12) | ((data[i + 1] & 0x3F) << 6) |
          (data[i + 2] & 0x3F));
        i += 3; continue;
      }
      if (byte >= 0xF0 && i + 3 < end) {
        const code = ((byte & 0x07) << 18) | ((data[i + 1] & 0x3F) << 12) |
          ((data[i + 2] & 0x3F) << 6) | (data[i + 3] & 0x3F);
        out += String.fromCodePoint(code);
        i += 4; continue;
      }
      out += String.fromCharCode(byte);
      i += 1;
    }
    return out;
  }

  static utf16le(text: string): Uint8Array {
    const out = new Uint8Array(text.length * 2);
    const view = new DataView(out.buffer);
    for (let i = 0; i < text.length; i++) view.setUint16(i * 2, text.charCodeAt(i), true);
    return out;
  }

  static asciiZ(text: string): Uint8Array {
    const out = new Uint8Array(text.length + 1);
    for (let i = 0; i < text.length; i++) out[i] = text.charCodeAt(i) & 0xFF;
    out[text.length] = 0;
    return out;
  }
}

interface CanonStringResult {
  value: string;
  next: number;
}

export class CanonPtpIp {
  private static cmd: CanonTcpChannel | null = null;
  private static evt: CanonTcpChannel | null = null;
  private static host: string = '';
  private static transactionId: number = 0;
  private static sessionId: number = 1;
  private static connectionNumber: number = 1;
  private static connectTask: Promise<CanonDeviceInfo> | null = null;
  private static queue: Promise<void> = Promise.resolve();
  private static eventToken: number = 0;
  private static listeners: ((event: CanonEosEvent) => void)[] = [];
  private static deviceInfo: CanonDeviceInfo | null = null;
  private static closing: boolean = false;

  private static readonly PORT: number = 15740;
  private static readonly PTPIP_VERSION: number = 0x00010000;
  /** 控制通道单包上限：GetObject 数据包可能到 MB 级。 */
  private static readonly MAX_CONTROL_FRAME: number = 64 * 1024 * 1024;
  /** 事件通道单包上限：事件只有几十字节，给足余量。 */
  private static readonly MAX_EVENT_FRAME: number = 256 * 1024;
  /** 握手超时。 */
  private static readonly HANDSHAKE_TIMEOUT_MS: number = 6000;
  /** 默认命令超时（契约 §3.2：命令 10 s）。 */
  static readonly DEFAULT_TIMEOUT_MS: number = 10000;
  /** 取图/取帧超时（契约 §3.2：15 s）。 */
  static readonly DATA_TIMEOUT_MS: number = 15000;
  /** 单次 Data 包载荷上限：1 MiB，避免单包过大被相机拒绝。 */
  private static readonly DATA_CHUNK: number = 1024 * 1024;
  /**
   * Init_Command_Request 的 FriendlyName。
   * PTP/IP 规定载荷 = GUID(16) + UTF-16LE 名称（含 NUL）+ 版本 u32；
   * 名字长度不敏感（`ptpip.c` 只按 NUL 截断）。
   */
  private static readonly INIT_NAME: string = 'VIVID';
  /**
   * 初始化 GUID：取固定的 16 字节（PTP/IP 要求每次会话稳定即可，不要求唯一）。
   * 与 libgphoto2 `ptpip.c` 的 `ptpip_guid` 同法：固定值即可被相机接受。
   */
  private static readonly INIT_GUID: number[] = [
    0x08, 0x70, 0xB0, 0x61, 0x0A, 0x8B, 0x45, 0x93,
    0xB2, 0xE7, 0x93, 0x57, 0xDD, 0x36, 0xE0, 0x50,
  ];

  static log(message: string): void {
    AppLogSink.emit(TAG, message);
  }

  static isOpen(): boolean {
    return CanonPtpIp.cmd !== null && !CanonPtpIp.cmd.isClosed();
  }

  static hostAddress(): string {
    return CanonPtpIp.host;
  }

  static onEvent(listener: (event: CanonEosEvent) => void): void {
    CanonPtpIp.listeners.push(listener);
  }

  static offEvent(): void {
    CanonPtpIp.listeners = [];
  }

  /**
   * 建立会话（幂等）。已完成且 host 相同时直接返回缓存的设备信息。
   *
   * 步骤：命令通道握手 → 事件通道握手 → OpenSession → SetRemoteMode →
   * SetEventMode → KeepDeviceOn（失败不阻断）→ GetDeviceInfo。
   */
  static async connect(host: string, name: string, timeoutMs: number = CanonPtpIp.DEFAULT_TIMEOUT_MS):
    Promise<CanonDeviceInfo> {
    if (CanonPtpIp.isOpen() && CanonPtpIp.host === host) {
      const cached = CanonPtpIp.deviceInfo;
      if (cached !== null) return cached;
    }
    const running = CanonPtpIp.connectTask;
    if (running !== null) return running;
    const task = CanonPtpIp.openSession(host, name, timeoutMs);
    CanonPtpIp.connectTask = task;
    try {
      return await task;
    } finally {
      CanonPtpIp.connectTask = null;
    }
  }

  private static async openSession(host: string, name: string,
    timeoutMs: number): Promise<CanonDeviceInfo> {
    await CanonPtpIp.close();
    CanonPtpIp.closing = false;
    const cmd = new CanonTcpChannel();
    const evt = new CanonTcpChannel();
    CanonPtpIp.cmd = cmd;
    CanonPtpIp.evt = evt;
    CanonPtpIp.host = host;
    CanonPtpIp.transactionId = 0;
    CanonPtpIp.sessionId = 1;
    try {
      await cmd.connect(host, CanonPtpIp.PORT, timeoutMs);
      // Init_Command_Request：GUID + UTF-16LE 名称 + 版本
      const identity = CanonBytes.concat([
        new Uint8Array(CanonPtpIp.INIT_GUID),
        CanonBytes.utf16le(name),
        new Uint8Array(2),
        CanonBytes.u32(CanonPtpIp.PTPIP_VERSION),
      ]);
      await cmd.send(CanonBytes.buildPacket(CanonPacketType.INIT_COMMAND_REQUEST, identity));
      const ack = await cmd.readPacket(CanonPtpIp.HANDSHAKE_TIMEOUT_MS, CanonPtpIp.MAX_EVENT_FRAME);
      if (ack.type === CanonPacketType.INIT_FAIL) {
        throw new CanonPtpError(0, 0, '相机拒绝 PTP/IP 会话（Init_Fail）');
      }
      if (ack.type !== CanonPacketType.INIT_COMMAND_ACK) {
        throw new CanonPtpError(0, 0, `握手应答类型异常：${ack.type}`);
      }
      CanonPtpIp.connectionNumber = ack.payload.length >= 4 ? CanonBytes.readU32(ack.payload, 0) : 1;
      CanonPtpIp.log(`命令通道已建立 connection=${CanonPtpIp.connectionNumber}`);
      // 事件通道
      try {
        await evt.connect(host, CanonPtpIp.PORT, timeoutMs);
        await evt.send(CanonBytes.buildPacket(CanonPacketType.INIT_EVENT_REQUEST,
          CanonBytes.u32(CanonPtpIp.connectionNumber)));
        const eventAck = await evt.readPacket(CanonPtpIp.HANDSHAKE_TIMEOUT_MS, CanonPtpIp.MAX_EVENT_FRAME);
        if (eventAck.type !== CanonPacketType.INIT_EVENT_ACK &&
          eventAck.type !== CanonPacketType.INIT_FAIL) {
          CanonPtpIp.log(`事件通道应答类型 ${eventAck.type}（继续）`);
        }
        CanonPtpIp.startEventLoop(evt);
      } catch (error) {
        CanonPtpIp.log(`事件通道不可用：${(error as Error).message}`);
        evt.close();
        CanonPtpIp.evt = null;
      }
      await CanonPtpIp.op(CanonEosOp.OPEN_SESSION, [CanonPtpIp.sessionId], timeoutMs);
      // 进入遥控 + 事件模式（报告 02 §7 ①）。失败不阻断：部分机身只支持其中一项。
      try {
        await CanonPtpIp.op(CanonEosOp.SET_REMOTE_MODE, [1], timeoutMs);
      } catch (error) {
        CanonPtpIp.log(`SetRemoteMode 失败：${(error as Error).message}`);
      }
      try {
        await CanonPtpIp.op(CanonEosOp.SET_EVENT_MODE, [1], timeoutMs);
      } catch (error) {
        CanonPtpIp.log(`SetEventMode 失败：${(error as Error).message}`);
      }
      try {
        await CanonPtpIp.op(CanonEosOp.KEEP_DEVICE_ON, [], timeoutMs);
      } catch (error) {
        CanonPtpIp.log(`KeepDeviceOn 失败：${(error as Error).message}`);
      }
      const info = await CanonPtpIp.getDeviceInfo(timeoutMs);
      CanonPtpIp.deviceInfo = info;
      CanonPtpIp.log(`会话就绪 model=${info.model} fw=${info.deviceVersion}`);
      return info;
    } catch (error) {
      await CanonPtpIp.close();
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  static async close(): Promise<void> {
    CanonPtpIp.closing = true;
    CanonPtpIp.eventToken += 1;
    const listeners: ((event: CanonEosEvent) => void)[] = [];
    CanonPtpIp.listeners = listeners;
    const cmd = CanonPtpIp.cmd;
    const evt = CanonPtpIp.evt;
    if (cmd !== null && !cmd.isClosed()) {
      // cmd 仍然挂在静态字段上，这样 op() 能正常走事务队列。
      try {
        await CanonPtpIp.op(CanonEosOp.CLOSE_SESSION, [], 3000);
      } catch (_error) {
        // 相机可能已经断开；关闭会话失败不影响本地清理。
      }
    }
    CanonPtpIp.cmd = null;
    CanonPtpIp.evt = null;
    CanonPtpIp.deviceInfo = null;
    CanonPtpIp.host = '';
    if (cmd !== null) cmd.close();
    if (evt !== null) await evt.closeAndWait();
    CanonPtpIp.log('会话已关闭');
  }

  // -------------------------------------------------------------------------
  // 事务原语
  // -------------------------------------------------------------------------

  static async op(opcode: number, params: number[] = [],
    timeoutMs: number = CanonPtpIp.DEFAULT_TIMEOUT_MS): Promise<CanonPtpReply> {
    return CanonPtpIp.transact(opcode, params, CanonDataPhase.NONE, timeoutMs);
  }

  static async opIn(opcode: number, params: number[] = [],
    timeoutMs: number = CanonPtpIp.DATA_TIMEOUT_MS): Promise<CanonPtpDataReply> {
    return CanonPtpIp.transactIn(opcode, params, timeoutMs);
  }

  static async opOut(opcode: number, params: number[], data: Uint8Array,
    timeoutMs: number = CanonPtpIp.DATA_TIMEOUT_MS): Promise<CanonPtpReply> {
    return CanonPtpIp.transactOut(opcode, params, data, timeoutMs);
  }

  private static async runExclusive<T>(body: () => Promise<T>, timeoutMs: number): Promise<T> {
    // 用对象字段而不是局部变量：闭包里赋值后，TS 的控制流分析会把局部变量
    // 窄化成 null（进而报 "never has no call signatures"）。
    const holder: CanonReleaseHolder = { release: null };
    const previous = CanonPtpIp.queue;
    const gate = new Promise<void>((resolve: () => void): void => {
      holder.release = resolve;
    });
    CanonPtpIp.queue = previous.then((): Promise<void> => gate);
    await previous;
    try {
      return await body();
    } finally {
      const release = holder.release;
      if (release !== null) release();
    }
  }

  private static nextTransactionId(): number {
    CanonPtpIp.transactionId = (CanonPtpIp.transactionId + 1) & 0xFFFFFFFF;
    if (CanonPtpIp.transactionId === 0) CanonPtpIp.transactionId = 1;
    return CanonPtpIp.transactionId;
  }

  private static buildOperationRequest(opcode: number, transactionId: number, params: number[],
    phase: number): Uint8Array {
    const parts: Uint8Array[] = [CanonBytes.u32(phase), CanonBytes.u16(opcode),
      CanonBytes.u32(transactionId)];
    for (const param of params) parts.push(CanonBytes.u32(param));
    return CanonBytes.buildPacket(CanonPacketType.OPERATION_REQUEST, CanonBytes.concat(parts));
  }

  private static parseResponse(payload: Uint8Array): CanonPtpReply {
    const code = CanonBytes.readU16(payload, 0);
    const params: number[] = [];
    // 应答载荷 = code(u16) + transactionId(u32) + 参数；参数从偏移 6 开始。
    let offset = 6;
    while (offset + 4 <= payload.length) {
      params.push(CanonBytes.readU32(payload, offset));
      offset += 4;
    }
    return { code: code, params: params };
  }

  private static requireCommand(): CanonTcpChannel {
    const cmd = CanonPtpIp.cmd;
    if (cmd === null || cmd.isClosed()) throw new CanonPtpError(0, 0, 'PTP/IP 未连接');
    return cmd;
  }

  private static async transact(opcode: number, params: number[], phase: number,
    timeoutMs: number): Promise<CanonPtpReply> {
    const result = await CanonPtpIp.runExclusive(async (): Promise<CanonPtpReply> => {
      const cmd = CanonPtpIp.requireCommand();
      const transactionId = CanonPtpIp.nextTransactionId();
      await cmd.send(CanonPtpIp.buildOperationRequest(opcode, transactionId, params, phase));
      const reply = await CanonPtpIp.awaitResponse(cmd, transactionId, opcode, timeoutMs);
      return reply;
    }, timeoutMs);
    return result;
  }

  private static async transactIn(opcode: number, params: number[],
    timeoutMs: number): Promise<CanonPtpDataReply> {
    return CanonPtpIp.runExclusive(async (): Promise<CanonPtpDataReply> => {
      const cmd = CanonPtpIp.requireCommand();
      const transactionId = CanonPtpIp.nextTransactionId();
      await cmd.send(CanonPtpIp.buildOperationRequest(opcode, transactionId, params,
        CanonDataPhase.IN));
      const chunks: Uint8Array[] = [];
      let total: number = -1;
      while (true) {
        const packet = await cmd.readPacket(timeoutMs, CanonPtpIp.MAX_CONTROL_FRAME);
        if (packet.type === CanonPacketType.START_DATA) {
          const size = packet.payload.length >= 12 ?
            Number(new DataView(packet.payload.buffer, packet.payload.byteOffset, packet.payload.byteLength)
              .getBigUint64(4, true)) : 0;
          total = size;
          continue;
        }
        if (packet.type === CanonPacketType.DATA) {
          chunks.push(packet.payload.length > 4 ? packet.payload.slice(4) : new Uint8Array(0));
          continue;
        }
        if (packet.type === CanonPacketType.END_DATA) {
          if (packet.payload.length > 4) chunks.push(packet.payload.slice(4));
          continue;
        }
        if (packet.type === CanonPacketType.OPERATION_RESPONSE) {
          const reply = CanonPtpIp.parseResponse(packet.payload);
          const data = chunks.length === 0 ? new Uint8Array(0) :
            CanonBytes.concat(chunks);
          if (total > 0 && data.length !== total) {
            CanonPtpIp.log(`数据长度不一致 op=0x${opcode.toString(16)} got=${data.length} want=${total}`);
          }
          return { reply: reply, data: data };
        }
        CanonPtpIp.log(`忽略未预期包 type=${packet.type}（op=0x${opcode.toString(16)}）`);
      }
    }, timeoutMs);
  }

  private static async transactOut(opcode: number, params: number[], data: Uint8Array,
    timeoutMs: number): Promise<CanonPtpReply> {
    return CanonPtpIp.runExclusive(async (): Promise<CanonPtpReply> => {
      const cmd = CanonPtpIp.requireCommand();
      const transactionId = CanonPtpIp.nextTransactionId();
      await cmd.send(CanonPtpIp.buildOperationRequest(opcode, transactionId, params,
        CanonDataPhase.OUT));
      // Start_Data：transactionId(u32) + 总长度(u64)
      await cmd.send(CanonBytes.buildPacket(CanonPacketType.START_DATA,
        CanonBytes.concat([CanonBytes.u32(transactionId), CanonBytes.u64(data.length)])));
      let offset = 0;
      while (offset < data.length) {
        const end = Math.min(offset + CanonPtpIp.DATA_CHUNK, data.length);
        const slice = data.slice(offset, end);
        await cmd.send(CanonBytes.buildPacket(CanonPacketType.DATA,
          CanonBytes.concat([CanonBytes.u32(transactionId), slice])));
        offset = end;
      }
      await cmd.send(CanonBytes.buildPacket(CanonPacketType.END_DATA,
        CanonBytes.u32(transactionId)));
      return await CanonPtpIp.awaitResponse(cmd, transactionId, opcode, timeoutMs);
    }, timeoutMs);
  }

  /** 读包直到本事务的 Operation_Response；顺带处理 DeviceBusy 重试一次。 */
  private static async awaitResponse(cmd: CanonTcpChannel, transactionId: number,
    opcode: number, timeoutMs: number): Promise<CanonPtpReply> {
    while (true) {
      const packet = await cmd.readPacket(timeoutMs, CanonPtpIp.MAX_CONTROL_FRAME);
      if (packet.type === CanonPacketType.OPERATION_RESPONSE) {
        const reply = CanonPtpIp.parseResponse(packet.payload);
        if (reply.code === CanonPtpResponse.DEVICE_BUSY) {
          // 忙：等 120 ms 重发一次（契约 §3.2）。
          await new Promise<void>((resolve: () => void): void => {
            setTimeout(resolve, 120);
          });
          await cmd.send(CanonPtpIp.buildOperationRequest(opcode, transactionId, [], CanonDataPhase.NONE));
          continue;
        }
        return reply;
      }
      if (packet.type === CanonPacketType.EVENT) {
        CanonPtpIp.deliverEvent(packet.payload);
        continue;
      }
      if (packet.type === CanonPacketType.START_DATA || packet.type === CanonPacketType.DATA ||
        packet.type === CanonPacketType.END_DATA) {
        // 无数据阶段却收到数据包：丢弃（相机异常）。
        CanonPtpIp.log(`无数据阶段收到数据包 type=${packet.type}`);
        continue;
      }
      CanonPtpIp.log(`忽略包 type=${packet.type}（等待事务 ${transactionId}）`);
    }
  }

  // -------------------------------------------------------------------------
  // 事件
  // -------------------------------------------------------------------------

  private static startEventLoop(evt: CanonTcpChannel): void {
    CanonPtpIp.eventToken += 1;
    const token = CanonPtpIp.eventToken;
    const loop = async (): Promise<void> => {
      while (!evt.isClosed() && token === CanonPtpIp.eventToken) {
        try {
          const packet = await evt.readPacket(4000, CanonPtpIp.MAX_EVENT_FRAME);
          if (packet.type === CanonPacketType.EVENT) CanonPtpIp.deliverEvent(packet.payload);
        } catch (error) {
          const typed = error instanceof Error ? error : new Error(String(error));
          if (CanonTimeoutMarker.is(typed)) continue;
          CanonPtpIp.log(`事件通道结束：${typed.message}`);
          break;
        }
      }
    };
    loop().then((): void => {}, (): void => {});
  }

  /** 异步 Event 包载荷 = EventCode(u16) + TransactionId(u32) + 参数。 */
  private static deliverEvent(payload: Uint8Array): void {
    const code = CanonBytes.readU16(payload, 0);
    const params: number[] = [];
    let offset = 6;
    while (offset + 4 <= payload.length) {
      params.push(CanonBytes.readU32(payload, offset));
      offset += 4;
    }
    const event: CanonEosEvent = { code: code, params: params, data: new Uint8Array(0) };
    for (const listener of CanonPtpIp.listeners) {
      try {
        listener(event);
      } catch (_error) {
        // 监听器异常不能中断读循环。
      }
    }
  }

  /**
   * 轮询 EOS 事件（0x9116）。
   *
   * 返回 `ptp-pack.c:1861` 的 blob 解析结果；无事件时相机回 OK + 0 字节。
   */
  static async getEvent(timeoutMs: number = 1000): Promise<CanonEosEvent[]> {
    if (!CanonPtpIp.isOpen()) return [];
    let reply: CanonPtpDataReply;
    try {
      reply = await CanonPtpIp.opIn(CanonEosOp.GET_EVENT, [], Math.max(1000, timeoutMs));
    } catch (error) {
      const typed = error instanceof Error ? error : new Error(String(error));
      if (!CanonTimeoutMarker.is(typed)) CanonPtpIp.log(`GetEvent 失败：${typed.message}`);
      return [];
    }
    if (reply.reply.code !== CanonPtpResponse.OK && reply.reply.code !== 0x2005) return [];
    return CanonPtpIp.parseEventBlob(reply.data);
  }

  /** `[size u32][code u32][payload]` 循环；偏移见契约 §3.4。 */
  static parseEventBlob(data: Uint8Array): CanonEosEvent[] {
    const events: CanonEosEvent[] = [];
    let offset = 0;
    while (offset + 8 <= data.length) {
      const size = CanonBytes.readU32(data, offset);
      const code = CanonBytes.readU32(data, offset + 4);
      if (size < 8 || offset + size > data.length) break;
      if (size === 8 && code === 0) break;
      const payload = data.slice(offset + 8, offset + size);
      const params: number[] = [];
      if (code === CanonEosEventCode.PROP_VALUE_CHANGED && payload.length >= 4) {
        params.push(CanonBytes.readU32(payload, 0));
      } else if (code === CanonEosEventCode.AVAIL_LIST_CHANGED && payload.length >= 12) {
        params.push(CanonBytes.readU32(payload, 0));
        params.push(CanonBytes.readU32(payload, 4));
        params.push(CanonBytes.readU32(payload, 8));
      }
      events.push({ code: code, params: params, data: payload });
      offset += size;
    }
    return events;
  }

  // -------------------------------------------------------------------------
  // 设备信息
  // -------------------------------------------------------------------------

  static async getDeviceInfo(timeoutMs: number = CanonPtpIp.DEFAULT_TIMEOUT_MS): Promise<CanonDeviceInfo> {
    const reply = await CanonPtpIp.opIn(CanonEosOp.GET_DEVICE_INFO, [], timeoutMs);
    return CanonPtpIp.parseDeviceInfo(reply.data);
  }

  /** 标准 DeviceInfo 数据集顺序（ISO 15740 §13.2）。 */
  static parseDeviceInfo(data: Uint8Array): CanonDeviceInfo {
    const info: CanonDeviceInfo = {
      manufacturer: '', model: '', deviceVersion: '', serialNumber: '',
      standardOps: [], vendorOps: [], vendorExtId: 0,
    };
    if (data.length < 8) return info;
    let offset = 0;
    offset += 2;                                   // StandardVersion
    info.vendorExtId = CanonBytes.readU32(data, offset); offset += 4;
    offset += 2;                                   // VendorExtensionVersion
    const extDesc = CanonBytes.readString(data, offset); offset = extDesc.next;
    offset += 2;                                   // FunctionalMode
    offset = CanonPtpIp.readU16Array(data, offset, info.standardOps);
    offset = CanonPtpIp.readU16Array(data, offset, []);   // EventsSupported
    offset = CanonPtpIp.readU16Array(data, offset, []);   // DevicePropertiesSupported
    offset = CanonPtpIp.readU16Array(data, offset, []);   // CaptureFormats
    offset = CanonPtpIp.readU16Array(data, offset, []);   // ImageFormats
    const manufacturer = CanonBytes.readString(data, offset); offset = manufacturer.next;
    const model = CanonBytes.readString(data, offset); offset = model.next;
    const version = CanonBytes.readString(data, offset); offset = version.next;
    const serial = CanonBytes.readString(data, offset);
    info.manufacturer = manufacturer.value;
    info.model = model.value;
    info.deviceVersion = version.value;
    info.serialNumber = serial.value;
    return info;
  }

  private static readU16Array(data: Uint8Array, offset: number, out: number[]): number {
    if (offset + 4 > data.length) return data.length;
    const count = CanonBytes.readU32(data, offset);
    let cursor = offset + 4;
    for (let i = 0; i < count && cursor + 2 <= data.length; i++) {
      out.push(CanonBytes.readU16(data, cursor));
      cursor += 2;
    }
    return cursor;
  }

  // -------------------------------------------------------------------------
  // EOS 业务封装（图传/控制/固件共用）
  // -------------------------------------------------------------------------

  static async getStorageIds(): Promise<number[]> {
    let reply: CanonPtpDataReply;
    try {
      reply = await CanonPtpIp.opIn(CanonEosOp.GET_STORAGE_IDS, []);
    } catch (_error) {
      reply = await CanonPtpIp.opIn(CanonEosOp.GET_STORAGE_IDS_STD, []);
    }
    return CanonPtpIp.readU32Array(reply.data);
  }

  static readU32Array(data: Uint8Array): number[] {
    const values: number[] = [];
    if (data.length < 4) return values;
    const count = CanonBytes.readU32(data, 0);
    const limit = Math.min(count, Math.floor((data.length - 4) / 4));
    for (let i = 0; i < limit; i++) values.push(CanonBytes.readU32(data, 4 + i * 4));
    return values;
  }

  static async setDevicePropValueEx(dpc: number, value: number): Promise<void> {
    const payload = CanonBytes.concat([CanonBytes.u32(dpc), CanonBytes.u32(value)]);
    const reply = await CanonPtpIp.opOut(CanonEosOp.SET_DEVICE_PROP_VALUE_EX, [], payload);
    if (reply.code !== CanonPtpResponse.OK) {
      throw new CanonPtpError(reply.code, CanonEosOp.SET_DEVICE_PROP_VALUE_EX,
        `SetDevicePropValueEx 0x${dpc.toString(16)} 失败`);
    }
  }

  static async getDevicePropValue(dpc: number): Promise<Uint8Array> {
    const reply = await CanonPtpIp.opIn(CanonEosOp.GET_DEVICE_PROP_VALUE, [dpc]);
    if (reply.reply.code !== CanonPtpResponse.OK) {
      throw new CanonPtpError(reply.reply.code, CanonEosOp.GET_DEVICE_PROP_VALUE,
        `GetDevicePropValue 0x${dpc.toString(16)} 失败`);
    }
    return reply.data;
  }

  static async getViewFinderData(): Promise<Uint8Array> {
    const reply = await CanonPtpIp.opIn(CanonEosOp.GET_VIEWFINDER_DATA, [0x00200000],
      CanonPtpIp.DATA_TIMEOUT_MS);
    if (reply.reply.code !== CanonPtpResponse.OK) return new Uint8Array(0);
    return reply.data;
  }
}
