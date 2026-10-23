/**
 * FUJIFILM PTP-IP 传输层（三条 TCP 通道）。
 *
 * 事实来源
 * --------
 *  - 端口：控制 55740 / 取景 55741 / 事件 55742 —— 不是标准 PTP-IP 的 15740。
 *    `00 §4.1`、`02 §3.2`；`J:ControlFFIR.java:347-350`。
 *  - 12 字节包头 `u32 Length + u32 Type + u32 参数/DataPhaseInfo`：
 *    `N:MngPTP::Open` 有 `cmp w1,#12`，`ExecPTPDataPhaseTop` 里反复 `movz #0x0c`。
 *  - 数据阶段按 512 字节块处理（`movz #0x200`，`00 §4.2`）。
 *  - 初始化 GUID `08 70 B0 61 0A 8B 45 93 B2 E7 93 57 DD 36 E0 50`
 *    （`N:MngPTP::Open+0x2D0`，见 `tmp/findings/native_ptp.md §4.2`）。
 *  - 取景帧 204800 字节，JPEG 偏移 = `LE32@12 + 18`（`02 §7.1`，
 *    `J:FinderView.java:340,359-360`）。
 *
 * 所有协议常量取自 `FujifilmProtocol.ets`。本文件只出现两处【推断】值，
 * 都在 `NOTES_A.md` 里写明依据与回退方案：
 *  1. Init 帧的 FriendlyName 字段长度（取 23 字符，使载荷恰好 68 字节）；
 *  2. DataPhaseInfo 的取值（CIPA 的 1/2/3 与常量表的 0/1/2 冲突，运行时自校准）。
 */

import socket from '@ohos.net.socket';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';
import {
  FujifilmBytes,
  FujifilmNet,
  FujifilmOp,
  FujifilmPacketType,
  FujifilmResponse,
} from './FujifilmProtocol';

/** 事件通道推给上层的帧（`FujifilmEvent` 段的事件码 + 参数）。 */
export interface FujifilmEventFrame {
  code: number;
  params: number[];
}

/** 一次 PTP 事务的结果。`code` 是 PTP 响应码，0x2001 = OK。 */
export interface FujifilmReply {
  /** PTP 响应码，0x2001 = OK。 */
  code: number;
  /** 响应参数。 */
  params: number[];
  /** 数据阶段字节（无数据时为 0 长）。 */
  data: Uint8Array;
}

/** 超时标记：用 Error.name 打标，ArkTS 里比自定义 Error 子类稳定。 */
class FujifilmPtpTimeoutMarker {
  static readonly NAME: string = 'FujifilmPtpTimeout';

  static create(message: string): Error {
    const error = new Error(message);
    error.name = FujifilmPtpTimeoutMarker.NAME;
    return error;
  }

  static is(error: Error): boolean {
    return error !== null && error !== undefined && error.name === FujifilmPtpTimeoutMarker.NAME;
  }
}

/**
 * 一条 PTP-IP TCP 通道：把任意切分的 TCP 字节流重新拼成「12 字节包头 + 载荷」。
 *
 * 只支持**一个**消费者（本文件的用法全部是顺序消费：事务队列串行、事件循环单
 * 线程、取景单读者），所以读等待不需要多路唤醒。
 */
class FujifilmTcpChannel {
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
      await tcp.connect({
        address: { address: host, family: 1, port: port },
        timeout: timeoutMs,
      });
    } catch (error) {
      const typed = error instanceof Error ? error : new Error(String(error));
      this.fail(typed);
      throw typed;
    }
    // 控制帧很小，Nagle 会让每个事务多等一个 delayed-ACK；取景流更需要低延迟。
    try {
      await tcp.setExtraOptions({ keepAlive: true, TCPNoDelay: true });
    } catch (_error) {
      FujifilmPtpIp.log('TCP 额外选项不可用（不影响协议）');
    }
  }

  async send(bytes: Uint8Array): Promise<void> {
    const failure = this.failure;
    if (failure !== null) throw failure;
    if (this.closing || this.tcp === null) throw new Error('PTP-IP 通道已关闭');
    const exact = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    await this.tcp.send({ data: exact });
  }

  /** 读恰好 `size` 字节；超时抛 `FujifilmPtpTimeoutMarker`。 */
  async readExactly(size: number, timeoutMs: number): Promise<Uint8Array> {
    const deadline = Date.now() + timeoutMs;
    while (this.chunk.length < size) {
      const failure = this.failure;
      if (failure !== null) throw failure;
      if (this.closing) throw new Error('PTP-IP 通道已关闭');
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        throw FujifilmPtpTimeoutMarker.create(`PTP-IP 读取超时（需要 ${size} 字节，已有 ${this.chunk.length}）`);
      }
      await this.waitForReader(remaining);
    }
    const out = this.chunk.slice(0, size);
    this.chunk = this.chunk.slice(size);
    return out;
  }

  /** 读一个完整 PTP-IP 包（12 字节头 + 载荷），返回原始字节（头也在内）。 */
  async readPacket(timeoutMs: number, maxLength: number): Promise<Uint8Array> {
    const header = await this.readExactly(12, timeoutMs);
    const length = FujifilmBytes.readU32(header, 0);
    if (length < 12 || length > maxLength) {
      throw new Error(`PTP-IP 包长度非法：${length}`);
    }
    const body = length > 12 ? await this.readExactly(length - 12, timeoutMs) : new Uint8Array(0);
    return FujifilmBytes.concat([header, body]);
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
    if (tcp === null) {
      return null;
    }
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

  /** 等到有数据到达、通道结束或超时（超时由调用方按 deadline 判定）。 */
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

export class FujifilmPtpIp {
  /** 控制通道 55740。 */
  private static control: FujifilmTcpChannel | null = null;
  /** 事件通道 55742（常驻读循环）。 */
  private static event: FujifilmTcpChannel | null = null;
  /** 取景通道 55741。 */
  private static liveView: FujifilmTcpChannel | null = null;
  /** 取景通道初始化时可能已收到一帧，留给 readLiveViewFrame 用。 */
  private static liveStash: Uint8Array | null = null;

  private static usable: boolean = false;
  private static transactionId: number = 0;
  private static sessionId: number = 1;
  private static connectionNumber: number = 1;
  private static eventToken: number = 0;
  private static connectTask: Promise<void> | null = null;
  private static queue: Promise<void> = Promise.resolve();
  private static listeners: ((frame: FujifilmEventFrame) => void)[] = [];

  /** 控制通道单包上限：GetObject 的数据包可能到 MB 级。 */
  private static readonly MAX_CONTROL_FRAME: number = 32 * 1024 * 1024;
  /** 事件通道单包上限（事件包只有几十字节）。 */
  private static readonly MAX_EVENT_FRAME: number = 64 * 1024;
  /** 事件通道读超时：只是空闲轮询间隔，不是错误。 */
  private static readonly EVENT_READ_TIMEOUT_MS: number = 4000;
  /** Init_Event_Request 等 Ack 的上限，拿不到也继续读事件。 */
  private static readonly EVENT_INIT_TIMEOUT_MS: number = 1500;
  /** 取景通道 initialize 等回应的上限；超时按「直接推流」处理。 */
  private static readonly LIVEVIEW_INIT_TIMEOUT_MS: number = 1200;
  /** 数据阶段自校准的探测超时（够短，失败也能快速换编码重来）。 */
  private static readonly DATA_PHASE_PROBE_TIMEOUT_MS: number = 3000;

  /**
   * Init_Command_Request 的 FriendlyName。
   *
   * 取 23 个字符，使载荷恰好 `16(GUID) + 24×2(名称含结尾 0x0000) + 4(版本) = 68`
   * 字节 —— 与 native `MngPTP::Open` 里的 `cmp w1,#68` 完全一致（`01`/`native_ptp.md
   * §4.2）。同时满足 CIPA DC-X005 的「GUID + NUL 结尾 UTF-16LE 名 + u32 版本」
   * 布局，版本字段落在偏移 64，所以「定长 68 字节」与「变长 + 68 总长」两种解析
   * 方式下字节序列完全相同。详见 `NOTES_A.md §2.3`。
   */
  private static readonly INIT_NAME: string = 'VIVID Camera Remote App';
  /**
   * PTP-IP 协议版本 1.0（CIPA DC-X005）。
   *
   * 【缺常量】`FujifilmProtocol.ets` 没有版本字段常量，已列入 `NOTES_A.md §6`
   * 的待补清单（建议 `FujifilmNet.PTPIP_VERSION = 0x00010000`）。补齐后删掉本行。
   */
  private static readonly PTPIP_VERSION: number = 0x00010000;
  /** 初始化 GUID（`08 70 B0 61 … E0 50`，`N:MngPTP::Open+0x2D0`）。 */
  private static readonly INIT_GUID: number[] = [
    0x08, 0x70, 0xB0, 0x61, 0x0A, 0x8B, 0x45, 0x93,
    0xB2, 0xE7, 0x93, 0x57, 0xDD, 0x36, 0xE0, 0x50,
  ];

  /**
   * DataPhaseInfo 的 CIPA DC-X005 取值。
   *
   * `NikonPtpIpService.operationRequest` 上有一条真机验证过的注释：
   * **1 = 无数据阶段，2 = DataIn（响应方→发起方），3 = DataOut（发起方→响应方）**。
   * `FujifilmProtocol.FujifilmPacketType` 写的是 0/1/2（USB PTP 容器的口径），
   * 二者相差 1。常量补齐前这里只在**一个**函数里换算，业务代码不出现字面量；
   * 并且 `connect()` 会用 GetDeviceInfo 自校准，两种口径都能落到能用的那一套。
   * 详见 `NOTES_A.md §3.2`。
   */
  private static readonly CIPA_PHASE_NONE: number = 1;
  private static readonly CIPA_PHASE_IN: number = 2;
  private static readonly CIPA_PHASE_OUT: number = 3;
  /** 0 = CIPA(1/2/3) 口径，1 = 常量表(0/1/2) 口径。 */
  private static phaseEncoding: number = 0;

  // -------------------------------------------------------------------------
  // 连接 / 断开
  // -------------------------------------------------------------------------

  /**
   * 连 55740 → Init_Command_Request/Ack → OpenSession(1)。幂等，可重复调用。
   * 失败抛 `Error`；调用方决定是否重试。
   */
  static async connect(): Promise<void> {
    if (FujifilmPtpIp.isConnected()) return;
    const running = FujifilmPtpIp.connectTask;
    if (running !== null) {
      await running;
      return;
    }
    const task = FujifilmPtpIp.openSession(true);
    FujifilmPtpIp.connectTask = task;
    try {
      await task;
    } finally {
      if (FujifilmPtpIp.connectTask === task) FujifilmPtpIp.connectTask = null;
    }
  }

  static isConnected(): boolean {
    const control = FujifilmPtpIp.control;
    return FujifilmPtpIp.usable && control !== null && !control.isClosed();
  }

  static async close(): Promise<void> {
    FujifilmPtpIp.usable = false;
    FujifilmPtpIp.eventToken += 1;
    FujifilmPtpIp.liveStash = null;
    const event = FujifilmPtpIp.event;
    const live = FujifilmPtpIp.liveView;
    const control = FujifilmPtpIp.control;
    FujifilmPtpIp.event = null;
    FujifilmPtpIp.liveView = null;
    FujifilmPtpIp.control = null;
    if (event !== null) await event.closeAndWait();
    if (live !== null) await live.closeAndWait();
    if (control !== null) await control.closeAndWait();
  }

  /**
   * @param calibrate 是否在 OpenSession 之后自校准数据阶段编码。
   *        自校准会多发一次 GetDeviceInfo，失败时还会重连一次；对外部调用
   *        永远为 true，只有自校准内部的重连才关掉它，避免递归。
   */
  private static async openSession(calibrate: boolean): Promise<void> {
    await FujifilmPtpIp.close();
    FujifilmPtpIp.usable = false;
    const channel = new FujifilmTcpChannel();
    FujifilmPtpIp.control = channel;
    try {
      await channel.connect(FujifilmNet.HOST, FujifilmNet.PORT_CONTROL, FujifilmNet.CONNECT_TIMEOUT_MS);
      FujifilmPtpIp.log(`控制通道已连 ${FujifilmNet.HOST}:${FujifilmNet.PORT_CONTROL}`);
      await FujifilmPtpIp.handshake(channel);
      FujifilmPtpIp.transactionId = 0;
      FujifilmPtpIp.usable = true;
      const reply = await FujifilmPtpIp.transact(FujifilmOp.OPEN_SESSION, [FujifilmPtpIp.sessionId],
        FujifilmPtpIp.phaseNone(), FujifilmNet.OPEN_TIMEOUT_MS, null);
      // 0x201E：会话已经开着。相机重启前不会自己关，按成功处理。
      if (reply.code !== FujifilmResponse.OK && reply.code !== FujifilmResponse.SESSION_ALREADY_OPEN) {
        throw new Error(`OpenSession 失败：${FujifilmBytes.hex(reply.code)}`);
      }
      FujifilmPtpIp.log(reply.code === FujifilmResponse.SESSION_ALREADY_OPEN
        ? 'OpenSession：会话已开（0x201E），按成功处理'
        : `OpenSession 成功（session=${FujifilmPtpIp.sessionId}）`);
    } catch (error) {
      FujifilmPtpIp.log(`连接失败：${FujifilmPtpIp.describe(error)}`);
      await FujifilmPtpIp.close();
      throw error instanceof Error ? error : new Error(String(error));
    }
    // 事件通道与取景通道互不阻塞：事件通道起不来，控制通道仍然可用。
    void FujifilmPtpIp.startEventChannel();
    if (calibrate) await FujifilmPtpIp.calibrateDataPhase();
    if (!FujifilmPtpIp.isConnected()) {
      throw new Error('PTP-IP 会话在数据阶段校准后不可用');
    }
  }

  /** Init_Command_Request → Init_Command_Ack。 */
  private static async handshake(channel: FujifilmTcpChannel): Promise<void> {
    const payload = new Uint8Array(16 + 24 * 2 + 4);
    payload.set(new Uint8Array(FujifilmPtpIp.INIT_GUID), 0);
    payload.set(FujifilmBytes.utf16z(FujifilmPtpIp.INIT_NAME), 16);
    payload.set(FujifilmBytes.u32(FujifilmPtpIp.PTPIP_VERSION), 64);
    await channel.send(FujifilmPtpIp.frame(FujifilmPacketType.INIT_COMMAND_REQUEST,
      FujifilmPacketType.DATA_PHASE_NONE, payload));
    FujifilmPtpIp.log(`Init_Command_Request 已发送（payload=${payload.length}）`);
    const deadline = Date.now() + FujifilmNet.OPEN_TIMEOUT_MS;
    while (true) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error('Init_Command_Ack 超时');
      const raw = await channel.readPacket(remaining, FujifilmPtpIp.MAX_CONTROL_FRAME);
      const type = FujifilmBytes.readU32(raw, 4);
      if (type === FujifilmPacketType.INIT_COMMAND_ACK) {
        FujifilmPtpIp.connectionNumber = FujifilmPtpIp.parseInitAck(raw);
        FujifilmPtpIp.log(`Init_Command_Ack 收到（connection=${FujifilmPtpIp.connectionNumber}）`);
        return;
      }
      if (type === FujifilmPacketType.INIT_FAIL) {
        const code = FujifilmBytes.readU32(raw, 12);
        throw new Error(`相机返回 Init_Fail（${FujifilmBytes.hex(code, 8)}）`);
      }
      // 0x08 事件/未知包：握手期不该出现，但记录后继续等 Ack。
      FujifilmPtpIp.log(`握手期收到非 Ack 包 type=${FujifilmBytes.hex(type)}，继续等待`);
    }
  }

  /** Ack 载荷：GUID(16) + UTF-16LE 名（NUL 结尾）+ u32 版本 [+ u32 连接号]。 */
  private static parseInitAck(raw: Uint8Array): number {
    const payload = raw.subarray(12);
    if (payload.length < 22) return 1;
    let offset = 16;
    while (offset + 1 < payload.length) {
      const code = FujifilmBytes.readU16(payload, offset);
      offset += 2;
      if (code === 0) break;
    }
    offset += 4; // protocol version
    if (offset + 4 <= payload.length) {
      const connection = FujifilmBytes.readU32(payload, offset);
      if (connection > 0) return connection;
    }
    return 1;
  }

  /**
   * 数据阶段编码自校准。
   *
   * 用 GetDeviceInfo（0x1001，必然带数据阶段）探一次：拿到非空数据就说明当前
   * 编码正确；超时/无数据则换另一套编码重连再探。两条都不通时保留原编码并记
   * 日志，不把连接判死（控制面可能仍可用）。
   */
  private static async calibrateDataPhase(): Promise<void> {
    const first = await FujifilmPtpIp.probeDataPhase();
    if (first > 0) {
      // 1 = 有应答但没数据：说明编码能被相机接受，只是这条命令不带数据。
      // 这种情况下**不能**换编码，否则会让后续真正带数据的命令全部失配。
      FujifilmPtpIp.log(`数据阶段编码自校准通过：encoding=${FujifilmPtpIp.phaseEncoding}（探测=${first}）`);
      return;
    }
    FujifilmPtpIp.phaseEncoding = FujifilmPtpIp.phaseEncoding === 0 ? 1 : 0;
    FujifilmPtpIp.log(`数据阶段探测无应答，改用 encoding=${FujifilmPtpIp.phaseEncoding} 重连探测`);
    try {
      await FujifilmPtpIp.openSession(false);
    } catch (error) {
      FujifilmPtpIp.log(`自校准重连失败：${FujifilmPtpIp.describe(error)}`);
      return;
    }
    const second = await FujifilmPtpIp.probeDataPhase();
    if (second > 0) {
      FujifilmPtpIp.log(`数据阶段编码自校准通过：encoding=${FujifilmPtpIp.phaseEncoding}（探测=${second}）`);
      return;
    }
    FujifilmPtpIp.log('数据阶段两种编码都没有应答，保留当前编码（相机可能不支持 GetDeviceInfo）');
  }

  /**
   * 探测一次数据阶段编码；返回 2 = 有数据、1 = 有应答无数据、0 = 无应答。
   * 无应答会把会话置为不可用，由调用方重连。
   */
  private static async probeDataPhase(): Promise<number> {
    try {
      const reply = await FujifilmPtpIp.transact(FujifilmOp.GET_DEVICE_INFO, [],
        FujifilmPtpIp.phaseIn(), FujifilmPtpIp.DATA_PHASE_PROBE_TIMEOUT_MS, null);
      FujifilmPtpIp.log(`数据阶段探测 code=${FujifilmBytes.hex(reply.code)} data=${reply.data.length}`);
      return reply.data.length > 0 ? 2 : 1;
    } catch (error) {
      FujifilmPtpIp.log(`数据阶段探测失败：${FujifilmPtpIp.describe(error)}`);
      return 0;
    }
  }

  // -------------------------------------------------------------------------
  // 事务
  // -------------------------------------------------------------------------

  /** 无数据阶段。超时默认 10000ms。 */
  static async op(opcode: number, params: number[] = [],
    timeoutMs: number = FujifilmNet.TRANSACTION_TIMEOUT_MS): Promise<FujifilmReply> {
    return FujifilmPtpIp.enqueue((): Promise<FujifilmReply> =>
      FujifilmPtpIp.transact(opcode, params, FujifilmPtpIp.phaseNone(), timeoutMs, null));
  }

  /** 数据入（相机→手机）。 */
  static async opDataIn(opcode: number, params: number[] = [],
    timeoutMs: number = FujifilmNet.TRANSACTION_TIMEOUT_MS): Promise<FujifilmReply> {
    return FujifilmPtpIp.enqueue((): Promise<FujifilmReply> =>
      FujifilmPtpIp.transact(opcode, params, FujifilmPtpIp.phaseIn(), timeoutMs, null));
  }

  /** 数据出（手机→相机），如固件 0x9040/0x9042。 */
  static async opDataOut(opcode: number, params: number[], data: Uint8Array,
    timeoutMs: number = FujifilmNet.TRANSACTION_TIMEOUT_MS): Promise<FujifilmReply> {
    return FujifilmPtpIp.enqueue((): Promise<FujifilmReply> =>
      FujifilmPtpIp.transact(opcode, params, FujifilmPtpIp.phaseOut(), timeoutMs, data));
  }

  /** 事务串行队列：并发调用安全，任一失败不影响后续任务入队。 */
  private static enqueue(task: () => Promise<FujifilmReply>): Promise<FujifilmReply> {
    const run: Promise<FujifilmReply> = FujifilmPtpIp.queue.then(
      (): Promise<FujifilmReply> => task());
    FujifilmPtpIp.queue = run.then((): void => {}, (): void => {});
    return run;
  }

  private static async transact(opcode: number, params: number[], phase: number,
    timeoutMs: number, outgoing: Uint8Array | null): Promise<FujifilmReply> {
    const control = FujifilmPtpIp.control;
    if (!FujifilmPtpIp.usable || control === null || control.isClosed()) {
      throw new Error('PTP-IP 会话未建立');
    }
    const transactionId = FujifilmPtpIp.nextTransactionId();
    const deadline = Date.now() + timeoutMs;
    try {
      await control.send(FujifilmPtpIp.operationRequest(opcode, transactionId, params, phase));
      if (outgoing !== null) {
        await FujifilmPtpIp.sendDataPhase(control, transactionId, outgoing);
      }
      const parts: Uint8Array[] = [];
      while (true) {
        const remaining = deadline - Date.now();
        if (remaining <= 0) {
          throw FujifilmPtpTimeoutMarker.create(`PTP-IP 事务超时（op=${FujifilmBytes.hex(opcode)}）`);
        }
        const raw = await control.readPacket(remaining, FujifilmPtpIp.MAX_CONTROL_FRAME);
        const type = FujifilmBytes.readU32(raw, 4);
        if (type === FujifilmPacketType.START_DATA || type === FujifilmPacketType.DATA ||
          type === FujifilmPacketType.END_DATA) {
          const body = raw.subarray(12);
          if (type !== FujifilmPacketType.START_DATA && body.length > 0) parts.push(body);
          continue;
        }
        if (type === FujifilmPacketType.OPERATION_RESPONSE) {
          return FujifilmPtpIp.parseResponse(raw, transactionId, parts);
        }
        if (type === FujifilmPacketType.EVENT) {
          // 正常走事件通道；控制通道上收到也按事件分发，不打断事务。
          FujifilmPtpIp.dispatchEvent(raw);
          continue;
        }
        if (type === FujifilmPacketType.INIT_FAIL) {
          throw new Error('相机返回 Init_Fail');
        }
        FujifilmPtpIp.log(`事务期忽略未知包 type=${FujifilmBytes.hex(type)} len=${raw.length}`);
      }
    } catch (error) {
      const typed = error instanceof Error ? error : new Error(String(error));
      // 契约：任何通道出错都把会话置为不可用，下一次 connect() 重建全链路。
      FujifilmPtpIp.markUnavailable(`op=${FujifilmBytes.hex(opcode)} ${typed.message}`);
      throw typed;
    }
  }

  /** 数据出：Start_Data(u64 总长) + 512B Data 包 + 最后一包 End_Data。 */
  private static async sendDataPhase(channel: FujifilmTcpChannel, transactionId: number,
    data: Uint8Array): Promise<void> {
    const start = new Uint8Array(8);
    start.set(FujifilmBytes.u64(data.length), 0);
    await channel.send(FujifilmPtpIp.frame(FujifilmPacketType.START_DATA, transactionId, start));
    const block = FujifilmNet.DATA_BLOCK;
    if (data.length === 0) {
      await channel.send(FujifilmPtpIp.frame(FujifilmPacketType.END_DATA, transactionId, new Uint8Array(0)));
      return;
    }
    let offset = 0;
    while (offset < data.length) {
      const length = Math.min(block, data.length - offset);
      const isLast = offset + length >= data.length;
      const slice = data.subarray(offset, offset + length);
      await channel.send(FujifilmPtpIp.frame(isLast ? FujifilmPacketType.END_DATA
        : FujifilmPacketType.DATA, transactionId, slice));
      offset += length;
    }
  }

  /**
   * Operation_Response 载荷：`u16 ResponseCode + u32 TransactionID + 参数`。
   *
   * 事务号偏移在 CIPA 里是 2（无填充），但个别实现会按 4 字节对齐补两位；
   * 这里两个偏移都试，优先取与本次事务号一致的那个，参数起点随之确定。
   */
  private static parseResponse(raw: Uint8Array, transactionId: number,
    parts: Uint8Array[]): FujifilmReply {
    const payload = raw.subarray(12);
    const code = FujifilmBytes.readU16(payload, 0);
    let tidOffset = 2;
    if (payload.length >= 8) {
      const atTwo = FujifilmBytes.readU32(payload, 2);
      const atFour = FujifilmBytes.readU32(payload, 4);
      if (atTwo !== transactionId && atFour === transactionId) tidOffset = 4;
    }
    const params: number[] = [];
    for (let offset = tidOffset + 4; offset + 4 <= payload.length; offset += 4) {
      params.push(FujifilmBytes.readU32(payload, offset));
    }
    const data = parts.length > 0 ? FujifilmBytes.concat(parts) : new Uint8Array(0);
    FujifilmPtpIp.log(`响应 op-tid=${transactionId} code=${FujifilmBytes.hex(code)} ` +
      `params=${params.length} data=${data.length}`);
    return { code: code, params: params, data: data };
  }

  private static nextTransactionId(): number {
    FujifilmPtpIp.transactionId += 1;
    if (FujifilmPtpIp.transactionId >= 0xFFFFFFFE) FujifilmPtpIp.transactionId = 1;
    return FujifilmPtpIp.transactionId;
  }

  // -------------------------------------------------------------------------
  // 事件通道
  // -------------------------------------------------------------------------

  static onEvent(listener: (frame: FujifilmEventFrame) => void): void {
    if (FujifilmPtpIp.listeners.indexOf(listener) >= 0) return;
    FujifilmPtpIp.listeners.push(listener);
  }

  static clearEventListeners(): void {
    FujifilmPtpIp.listeners = [];
  }

  /** 事件通道起不来不影响控制面：失败只记日志。 */
  private static async startEventChannel(): Promise<void> {
    if (FujifilmPtpIp.event !== null) return;
    const channel = new FujifilmTcpChannel();
    try {
      await channel.connect(FujifilmNet.HOST, FujifilmNet.PORT_EVENT, FujifilmNet.CONNECT_TIMEOUT_MS);
    } catch (error) {
      FujifilmPtpIp.log(`事件通道连接失败（不影响控制）：${FujifilmPtpIp.describe(error)}`);
      channel.close();
      return;
    }
    FujifilmPtpIp.event = channel;
    const token = FujifilmPtpIp.eventToken;
    FujifilmPtpIp.log(`事件通道已连 ${FujifilmNet.HOST}:${FujifilmNet.PORT_EVENT}`);
    try {
      await channel.send(FujifilmPtpIp.frame(FujifilmPacketType.INIT_EVENT_REQUEST,
        FujifilmPacketType.DATA_PHASE_NONE, FujifilmBytes.u32(FujifilmPtpIp.connectionNumber)));
      const ack = await channel.readPacket(FujifilmPtpIp.EVENT_INIT_TIMEOUT_MS, FujifilmPtpIp.MAX_EVENT_FRAME);
      const type = FujifilmBytes.readU32(ack, 4);
      if (type === FujifilmPacketType.INIT_EVENT_ACK) {
        FujifilmPtpIp.log('Init_Event_Ack 收到');
      } else if (type === FujifilmPacketType.EVENT) {
        // 首包就是事件：不能丢弃，先分发给监听者再进循环。
        FujifilmPtpIp.log('事件通道首包即事件（无 Init_Event_Ack）');
        FujifilmPtpIp.dispatchEvent(ack);
      } else {
        FujifilmPtpIp.log(`事件通道首包 type=${FujifilmBytes.hex(type)}`);
      }
    } catch (error) {
      // 【推断】部分固件不回应 Init_Event_Request 而直接推事件，所以不断开。
      FujifilmPtpIp.log(`Init_Event_Ack 未收到（继续读事件）：${FujifilmPtpIp.describe(error)}`);
    }
    void FujifilmPtpIp.runEventLoop(channel, token);
  }

  private static async runEventLoop(channel: FujifilmTcpChannel, token: number): Promise<void> {
    while (FujifilmPtpIp.eventToken === token && !channel.isClosed()) {
      try {
        const raw = await channel.readPacket(FujifilmPtpIp.EVENT_READ_TIMEOUT_MS, FujifilmPtpIp.MAX_EVENT_FRAME);
        const type = FujifilmBytes.readU32(raw, 4);
        if (type === FujifilmPacketType.EVENT) {
          FujifilmPtpIp.dispatchEvent(raw);
        } else if (type === FujifilmPacketType.INIT_EVENT_ACK) {
          continue;
        } else {
          FujifilmPtpIp.log(`事件通道忽略包 type=${FujifilmBytes.hex(type)}`);
        }
      } catch (error) {
        const typed = error instanceof Error ? error : new Error(String(error));
        if (FujifilmPtpTimeoutMarker.is(typed)) continue; // 空闲轮询
        FujifilmPtpIp.log(`事件通道中断：${typed.message}`);
        FujifilmPtpIp.markUnavailable('事件通道中断');
        return;
      }
    }
  }

  private static dispatchEvent(raw: Uint8Array): void {
    const payload = raw.subarray(12);
    const code = FujifilmBytes.readU16(payload, 0);
    const params: number[] = [];
    for (let offset = 6; offset + 4 <= payload.length; offset += 4) {
      params.push(FujifilmBytes.readU32(payload, offset));
    }
    const frame: FujifilmEventFrame = { code: code, params: params };
    FujifilmPtpIp.log(`事件 code=${FujifilmBytes.hex(code)} params=${params.join(',')}`);
    for (const listener of FujifilmPtpIp.listeners) {
      try {
        listener(frame);
      } catch (error) {
        FujifilmPtpIp.log(`事件回调异常：${FujifilmPtpIp.describe(error)}`);
      }
    }
  }

  // -------------------------------------------------------------------------
  // 取景通道
  // -------------------------------------------------------------------------

  /**
   * 连 55741 并做该通道的 initialize。
   *
   * 【推断】报告只说明 Phase1 之后由 Java 建 55741/55742 两条 socket 并把 fd 交给
   * native（`02 §4.1 S21b`），没有写取景通道的握手包。这里按事件通道的方式发
   * 一次 Init_Event_Request：拿到 Ack 或任意一帧都算成功；超时也继续（部分固件
   * 在 open 之后直接推帧）。回退方案与证据见 `NOTES_A.md §4`。
   */
  static async openLiveView(): Promise<void> {
    if (FujifilmPtpIp.liveView !== null) return;
    if (!FujifilmPtpIp.isConnected()) throw new Error('PTP-IP 会话未建立，无法打开取景通道');
    const channel = new FujifilmTcpChannel();
    try {
      await channel.connect(FujifilmNet.HOST, FujifilmNet.PORT_LIVEVIEW, FujifilmNet.CONNECT_TIMEOUT_MS);
    } catch (error) {
      channel.close();
      throw error instanceof Error ? error : new Error(String(error));
    }
    FujifilmPtpIp.log(`取景通道已连 ${FujifilmNet.HOST}:${FujifilmNet.PORT_LIVEVIEW}`);
    try {
      await channel.send(FujifilmPtpIp.frame(FujifilmPacketType.INIT_EVENT_REQUEST,
        FujifilmPacketType.DATA_PHASE_NONE, FujifilmBytes.u32(FujifilmPtpIp.connectionNumber)));
      const first = await channel.readPacket(FujifilmPtpIp.LIVEVIEW_INIT_TIMEOUT_MS,
        FujifilmNet.LIVEVIEW_FRAME_BYTES);
      const type = FujifilmBytes.readU32(first, 4);
      if (type === FujifilmPacketType.INIT_EVENT_ACK) {
        FujifilmPtpIp.log('取景通道 initialize 成功（Init_Event_Ack）');
      } else {
        // 已经是取景帧了：暂存，交给 readLiveViewFrame。
        FujifilmPtpIp.liveStash = first;
        FujifilmPtpIp.log(`取景通道初始化前已收到帧 type=${FujifilmBytes.hex(type)} len=${first.length}`);
      }
    } catch (error) {
      FujifilmPtpIp.log(`取景通道 initialize 无应答（按直接推流处理）：${FujifilmPtpIp.describe(error)}`);
    }
    FujifilmPtpIp.liveView = channel;
  }

  /**
   * 读一帧。返回**相机声明的整包字节**（含 12 字节帧头和帧内 JPEG 前的头）；
   * 超时返回 null。JPEG 起点用 `jpegOfFrame()` 取（= LE32@12 + 18）。
   */
  static async readLiveViewFrame(timeoutMs: number = 10000): Promise<Uint8Array | null> {
    const channel = FujifilmPtpIp.liveView;
    if (channel === null) return null;
    const stashed = FujifilmPtpIp.liveStash;
    if (stashed !== null) {
      FujifilmPtpIp.liveStash = null;
      return stashed;
    }
    try {
      const header = await channel.readExactly(12, timeoutMs);
      const declared = FujifilmBytes.readU32(header, 0);
      if (declared >= 12 && declared <= FujifilmNet.LIVEVIEW_FRAME_BYTES) {
        const body = declared > 12 ? await channel.readExactly(declared - 12, timeoutMs) : new Uint8Array(0);
        return FujifilmBytes.concat([header, body]);
      }
      // 长度字段不可信时退回 native 的固定读法：一次 204800 字节。
      FujifilmPtpIp.log(`取景帧长度字段=${declared} 不可信，按固定 ${FujifilmNet.LIVEVIEW_FRAME_BYTES} 字节读`);
      const body = await channel.readExactly(FujifilmNet.LIVEVIEW_FRAME_BYTES - 12, timeoutMs);
      return FujifilmBytes.concat([header, body]);
    } catch (error) {
      const typed = error instanceof Error ? error : new Error(String(error));
      if (!FujifilmPtpTimeoutMarker.is(typed)) {
        FujifilmPtpIp.log(`取景读失败，关闭取景通道：${typed.message}`);
        FujifilmPtpIp.closeLiveView();
      }
      return null;
    }
  }

  /** 帧内 JPEG 起点 = `LE32@12 + 18`（`02 §7.1`）。 */
  static jpegOffsetOf(frame: Uint8Array): number {
    if (frame.length < FujifilmNet.LIVEVIEW_JPEG_PTR_OFFSET + 4) return 0;
    const pointer = FujifilmBytes.readU32(frame, FujifilmNet.LIVEVIEW_JPEG_PTR_OFFSET);
    return pointer + FujifilmNet.LIVEVIEW_JPEG_HEADER_BIAS;
  }

  /** 从取景帧里切出 JPEG；偏移非法时返回 0 长。 */
  static jpegOfFrame(frame: Uint8Array): Uint8Array {
    const offset = FujifilmPtpIp.jpegOffsetOf(frame);
    if (offset <= 0 || offset >= frame.length) return new Uint8Array(0);
    return frame.subarray(offset);
  }

  static closeLiveView(): void {
    const channel = FujifilmPtpIp.liveView;
    FujifilmPtpIp.liveView = null;
    FujifilmPtpIp.liveStash = null;
    if (channel !== null) channel.close();
  }

  // -------------------------------------------------------------------------
  // 内部工具
  // -------------------------------------------------------------------------

  private static phaseNone(): number {
    return FujifilmPtpIp.phaseEncoding === 0
      ? FujifilmPtpIp.CIPA_PHASE_NONE : FujifilmPacketType.DATA_PHASE_NONE;
  }

  private static phaseIn(): number {
    return FujifilmPtpIp.phaseEncoding === 0
      ? FujifilmPtpIp.CIPA_PHASE_IN : FujifilmPacketType.DATA_PHASE_IN;
  }

  private static phaseOut(): number {
    return FujifilmPtpIp.phaseEncoding === 0
      ? FujifilmPtpIp.CIPA_PHASE_OUT : FujifilmPacketType.DATA_PHASE_OUT;
  }

  private static frame(type: number, field: number, payload: Uint8Array): Uint8Array {
    const packet = new Uint8Array(12 + payload.length);
    FujifilmPtpIp.putU32(packet, 0, packet.length);
    FujifilmPtpIp.putU32(packet, 4, type);
    FujifilmPtpIp.putU32(packet, 8, field);
    packet.set(payload, 12);
    return packet;
  }

  private static operationRequest(opcode: number, transactionId: number, params: number[],
    phase: number): Uint8Array {
    const payload = new Uint8Array(2 + 4 + params.length * 4);
    FujifilmPtpIp.putU16(payload, 0, opcode);
    FujifilmPtpIp.putU32(payload, 2, transactionId);
    for (let index = 0; index < params.length; index++) {
      FujifilmPtpIp.putU32(payload, 6 + index * 4, params[index]);
    }
    return FujifilmPtpIp.frame(FujifilmPacketType.OPERATION_REQUEST, phase, payload);
  }

  private static putU16(target: Uint8Array, offset: number, value: number): void {
    target.set(FujifilmBytes.u16(value), offset);
  }

  private static putU32(target: Uint8Array, offset: number, value: number): void {
    target.set(FujifilmBytes.u32(value), offset);
  }

  /** 通道出错 → 会话不可用，下一次 connect() 重建全链路（契约 §2.1）。 */
  private static markUnavailable(reason: string): void {
    if (!FujifilmPtpIp.usable) return;
    FujifilmPtpIp.log(`会话置为不可用：${reason}`);
    void FujifilmPtpIp.close();
  }

  private static describe(error: Object): string {
    const typed = error as Error;
    return typed !== null && typed !== undefined && typed.message !== undefined ? typed.message : String(error);
  }

  static log(message: string): void {
    try {
      hilog.info(0x0001, 'VIVID_FUJI', '%{public}s', message);
    } catch (_error) {
    }
    AppLogSink.emit('[FUJI]', message);
  }
}
