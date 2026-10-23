import socket from '@ohos.net.socket';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NikonLssSession } from './NikonLssSession';
import { NikonLssConnectionConfiguration, parseLssConnectionConfiguration } from './NikonLssProtocol';
import { AppLogSink } from './AppLogSink';

/** A gallery item represented by standard Nikon PTP/IP ObjectInfo metadata. */
export interface NikonPtpGalleryItem {
  imageId: string;
  imageType: number;
  thumbnailUri: string;
  size?: number;
  rawSize?: number;
  originalFileName?: string;
  handle: number;
  /** 这一项来自哪张存储卡。界面按它区分「卡 1 / 卡 2」，并且缩略图文件名和
   * 选择键都带上它——两张卡的句柄空间独立，同号句柄会互相覆盖。
   *
   * 由 `NikonPtpIpService` 扫描出来的条目一定带这个字段；调用方从缓存或旧状态
   * 里重建条目时允许缺省（老数据没有卡号），所以是可选。 */
  storageId?: number;
}

export interface NikonPtpCatalogResult {
  ok: boolean;
  message: string;
  host: string;
  total: number;
  items: NikonPtpGalleryItem[];
  nextHandleIndex: number;
  remaining: number;
  /** 相机上报的存储卡槽号，**按卡槽顺序**，**包含空卡**。
   *
   * 必须单独传出来，不能让界面从 `items` 里反推：空卡一张照片都没有，反推就会
   * 把它漏掉，于是「卡 2」按钮根本不出现，用户以为 App 没读到那张卡。界面据此
   * 决定显示几个切换按钮，空卡按钮置灰（与 Lab 线 SD1/SD2 的表现一致）。 */
  storageIds?: number[];
}

/**
 * One cursor-based scan page. `nextHandleIndex` is the handle-array position
 * the next page must resume from - it advances past every handle that was
 * classified (including directories and thumbnail failures), so pagination
 * can never stall. `remaining` counts handles not scanned yet and is the only
 * source for hasMore.
 */
export interface NikonPtpGalleryPage {
  items: NikonPtpGalleryItem[];
  nextHandleIndex: number;
  remaining: number;
}

interface NikonPtpObjectInfo {
  handle: number;
  storageId: number;
  format: number;
  size: number;
  thumbSize: number;
  width: number;
  height: number;
  filename: string;
}

export interface NikonPtpResponse {
  code: number;
  transaction: number;
  params: number[];
  data: Uint8Array;
}

/**
 * PTP 事务层的传输边界（与索尼官方 `ITransactionExecutor{ add,
 * addUniqueOperation }` 同层）。
 *
 * 索尼官方没有为 USB 另写一套协议：`PtpIpManager` 与 `PtpUsbManager` 都继承同一个
 * `BasePtpManager`，`Initializer` 只依赖这个接口，因此 0x9201/0x9202/0x9207/0x9209/
 * 0x9216/0x923A~0x923E 这些操作码在两条传输上是同一套。把我们的 `enqueue` /
 * `enqueueDataOut` 抽象出来，`SonyPtpIpContent` 就能原样跑在 USB 通道上。
 *
 * 传输**专属**的东西不放进这个接口：PTP/IP 的 12 字节初始化握手
 * （InitCommand/InitEvent）、探活、事件通道，都只属于各自实现。
 */
export interface PtpTransport {
  enqueue(op: number, params: number[], expectsData: boolean,
    tolerateTimeout?: boolean): Promise<NikonPtpResponse>;
  enqueueDataOut(op: number, params: number[], payload: Uint8Array): Promise<NikonPtpResponse>;
  /** 建立会话时实际生效的开启操作码（0x1002 或 0x9210），供上层判断是否需要补发。 */
  openOpcode: number;
  /** 该开启操作的响应码，-1 表示从未执行。 */
  openCode: number;
  /** 事务层是否已失效；失效后 `enqueue` 直接抛错而不是等待超时。 */
  failed: boolean;
}

interface NikonPtpPacket {
  type: number;
  payload: Uint8Array;
}

interface NikonPtpStringRead {
  value: string;
  next: number;
}

interface NikonPtpU16ListRead {
  values: number[];
  next: number;
}

interface NikonPtpDeviceInfo {
  standardVersion: number;
  vendorExtensionId: number;
  mtpVersion: number;
  functionalMode: number;
  manufacturer: string;
  model: string;
  deviceVersion: string;
  serialNumber: string;
  operationsSupported: number[];
  eventsSupported: number[];
  devicePropertiesSupported: number[];
  captureFormats: number[];
  playbackFormats: number[];
}

interface NikonPtpErrorShape {
  code?: number;
}

interface PendingPacket {
  resolve: (packet: NikonPtpPacket) => void;
  reject: (error: Error) => void;
  timer: number;
}

/** Outcome of a data phase: the assembled bytes plus, when the camera sent a
 * complete non-OK response instead of an EndData, that early rejection. */
interface NikonPtpDataPhaseResult {
  data: Uint8Array;
  earlyResponse: NikonPtpPacket | null;
}

/** Timeout rejection marker: the passive event loop must treat these as idle
 * waits, not as a dead line. Implemented as an Error name tag because ArkTS
 * does not support user subclasses of the built-in Error in this position. */
class NikonPtpTimeout {
  static readonly NAME = 'PtpIpTimeout';

  static create(): Error {
    const error = new Error('PTP/IP response timeout');
    error.name = NikonPtpTimeout.NAME;
    return error;
  }

  static is(error: Error): boolean {
    return error.name === NikonPtpTimeout.NAME;
  }
}

/**
 * Small framed TCP reader for CIPA DC-005 PTP/IP. The Harmony socket API
 * delivers arbitrary TCP chunks, so packet boundaries are reconstructed from
 * the little-endian length field before protocol parsing. A channel keeps a
 * terminal state: once closed or failed, send/next reject immediately and all
 * queued waiters are released with the same terminal error.
 */
class NikonPtpIpChannel {
  private tcp: socket.TCPSocket | null = null;
  private buffer: Uint8Array = new Uint8Array(0);
  private pending: PendingPacket[] = [];
  private messageCallback: ((info: socket.SocketMessageInfo) => void) | null = null;
  private errorCallback: ((error: Error) => void) | null = null;
  private closed: boolean = false;
  private terminalError: Error | null = null;

  isClosed(): boolean {
    return this.closed || this.terminalError !== null;
  }

  async connect(host: string, port: number): Promise<void> {
    if (this.isClosed()) throw new Error('PTP/IP socket is closed');
    const tcp = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    this.messageCallback = (info: socket.SocketMessageInfo): void => {
      if (this.closed) return;
      if (!info || !info.message) return;
      this.append(new Uint8Array(info.message));
      this.pump();
    };
    this.errorCallback = (error: Error): void => {
      this.fail(error);
    };
    tcp.on('message', this.messageCallback);
    tcp.on('error', this.errorCallback);
    try {
      await tcp.connect({
        address: { address: host, family: 1, port: port },
        timeout: 5000,
      });
    } catch (error) {
      const typed = error as Error;
      this.fail(typed);
      throw typed;
    }
    // PTP command frames are tiny. With Nagle enabled (the default) each
    // request-response round trip absorbs a delayed-ACK stall on camera
    // Wi-Fi, which multiplies across the 12+ transactions of every gallery
    // page. Disabling it is transport-level only - the handshake bytes stay
    // exactly as before. keepAlive lets the OS notice a silently dropped
    // camera link instead of waiting for a transaction timeout.
    try {
      await tcp.setExtraOptions({ keepAlive: true, TCPNoDelay: true });
    } catch (_error) {
      NikonPtpIpService.log('ptpip tcp extra options unavailable (non-fatal)');
    }
  }

  async send(bytes: Uint8Array): Promise<void> {
    const terminal = this.terminalError;
    if (terminal !== null) throw terminal;
    if (this.closed || this.tcp === null) throw new Error('PTP/IP socket is closed');
    const exact = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    await this.tcp.send({ data: exact });
  }

  async next(timeoutMs: number = 10000): Promise<NikonPtpPacket> {
    let packet: NikonPtpPacket | null = null;
    try {
      packet = this.takePacket();
    } catch (error) {
      const typed = error as Error;
      this.fail(typed);
      throw typed;
    }
    if (packet !== null) return packet;
    const terminal = this.terminalError;
    if (terminal !== null) throw terminal;
    if (this.closed) throw new Error('PTP/IP socket closed');
    return new Promise<NikonPtpPacket>((resolve: (packet: NikonPtpPacket) => void,
      reject: (error: Error) => void): void => {
      const timer = setTimeout((): void => {
        const index = this.pending.findIndex((item: PendingPacket) => item.resolve === resolve);
        if (index >= 0) this.pending.splice(index, 1);
        reject(NikonPtpTimeout.create());
      }, timeoutMs) as number;
      this.pending.push({ resolve: resolve, reject: reject, timer: timer });
    });
  }

  /** Record a terminal error and release every waiter. Idempotent. */
  fail(error: Error): void {
    if (this.terminalError !== null || this.closed) return;
    this.terminalError = error;
    this.close();
  }

  /** Releases the channel. Kept synchronous because the public teardown is
   * synchronous and every existing caller relies on it: the channel becomes
   * unusable immediately and the platform's socket close is started here, its
   * promise deliberately left unattached. A caller that must not dial again
   * before this connection is really gone uses `closeAndWait` instead. */
  close(): void {
    const closing = this.shutdown();
    if (closing !== null) {
      closing.then((): void => {}, (): void => {});
    }
  }

  /**
   * Same teardown as `close()`, but resolves only once the platform reports the
   * TCP socket closed.
   *
   * This is what makes a reconnect safe. A PTP/IP camera keeps its session until
   * it has seen the connection that carried it go away, so dialling again while
   * the old socket is still being torn down makes the camera answer the new
   * `InitCommand` with a frame that is not an `InitCommandAck`, or the new
   * session open with `SessionAlreadyOpen` (0x201E) — both observed on an
   * ILCE-7M4 in two consecutive device runs. Awaiting this close before the next
   * connection removes that race instead of retrying around it.
   */
  async closeAndWait(): Promise<void> {
    const closing = this.shutdown();
    if (closing === null) return;
    try {
      await NikonPtpIpChannel.settled(closing, NikonPtpIpChannel.RELEASE_TIMEOUT_MS);
    } catch (_error) {
      // A socket the platform already dropped (Wi-Fi roam) cannot be closed a
      // second time; the connection is gone either way.
    }
  }

  /** Upper bound on how long `closeAndWait` waits for the platform's socket
   * close. A close that never settles must not be able to block every later
   * reconnect for the rest of the run. */
  private static readonly RELEASE_TIMEOUT_MS = 2000;

  /** `promise`, but never longer than `timeoutMs`; the loser is neutralised so a
   * late rejection is not reported as unhandled. */
  private static async settled(promise: Promise<void>, timeoutMs: number): Promise<void> {
    let timer = 0;
    const guard = new Promise<void>((resolve: () => void): void => {
      timer = setTimeout((): void => {
        resolve();
      }, timeoutMs) as number;
    });
    const safe = promise.then((): void => {}, (): void => {});
    try {
      await Promise.race([safe, guard]);
    } finally {
      clearTimeout(timer);
    }
  }

  /** Idempotent teardown shared by `close()` and `closeAndWait()`. Returns the
   * platform close promise, or null when there was no socket to close. */
  private shutdown(): Promise<void> | null {
    if (this.closed) return null;
    this.closed = true;
    const error = this.terminalError !== null ? this.terminalError : new Error('PTP/IP socket closed');
    const waiting = this.pending.slice();
    this.pending = [];
    for (const item of waiting) {
      clearTimeout(item.timer);
      item.reject(error);
    }
    const tcp = this.tcp;
    const messageCallback = this.messageCallback;
    const errorCallback = this.errorCallback;
    this.tcp = null;
    this.messageCallback = null;
    this.errorCallback = null;
    this.buffer = new Uint8Array(0);
    if (tcp === null) return null;
    try {
      if (messageCallback !== null) tcp.off('message', messageCallback);
      if (errorCallback !== null) tcp.off('error', errorCallback);
      return tcp.close();
    } catch (_error) {
      // The platform may already have closed the socket after a Wi-Fi roam.
      return null;
    }
  }

  private append(value: Uint8Array): void {
    if (value.length === 0) return;
    const next = new Uint8Array(this.buffer.length + value.length);
    next.set(this.buffer, 0);
    next.set(value, this.buffer.length);
    this.buffer = next;
  }

  private pump(): void {
    try {
      while (this.pending.length > 0) {
        const packet = this.takePacket();
        if (!packet) return;
        const item = this.pending.shift();
        if (!item) return;
        clearTimeout(item.timer);
        item.resolve(packet);
      }
    } catch (error) {
      // A malformed frame must terminate the channel: continuing to read a
      // polluted stream would misattribute late bytes to the next operation.
      NikonPtpIpService.logError('ptpip frame', error as Object);
      this.fail(error as Error);
    }
  }

  private takePacket(): NikonPtpPacket | null {
    if (this.buffer.length < 8) return null;
    const length = NikonPtpIpService.readU32(this.buffer, 0);
    if (length < 8 || length > 128 * 1024 * 1024) throw new Error('Invalid PTP/IP frame length');
    if (this.buffer.length < length) return null;
    const type = NikonPtpIpService.readU32(this.buffer, 4);
    const payload = this.buffer.slice(8, length);
    this.buffer = this.buffer.slice(length);
    // Bulk data frames (64KB GetPartialObject chunks) would flood the hilog
    // app buffer and evict the very import diagnostics this trace exists to
    // capture; log control frames only.
    if (payload.length < 4096) {
      NikonPtpIpService.log(`ptpip frame type=${type} payload=${payload.length}`);
    }
    return { type: type, payload: payload };
  }
}

/**
 * One PTP/IP connection to one camera. The session owns both channels, the
 * transaction counter, the handle/object caches and a command queue that
 * serializes request/response exchanges. `failed` marks a session that can no
 * longer be reused (timeout, frame error, transaction mismatch, close).
 */
export class NikonPtpSession implements PtpTransport {
  command: NikonPtpIpChannel;
  event: NikonPtpIpChannel;
  host: string;
  connectionNumber: number;
  epoch: number;
  failed: boolean = false;
  /** Which session-open operation actually established this session: 0x1002
   * `OpenSession` (the default, and the fallback) or a vendor one such as Sony's
   * 0x9210 `SDIO_OpenSession`. Callers that need a vendor session can tell from
   * it whether the camera honoured the request or the transport had to fall
   * back, instead of sending a second session-open blindly. */
  openOpcode: number = 0;
  /** Response code of that session-open operation, -1 when it never ran. */
  openCode: number = -1;
  storageId: number = 0;
  handles: number[] = [];
  /** 每个对象句柄属于哪张存储卡。卡 1 / 卡 2 的句柄空间相互独立，同一个句柄号
   * 可能在两张卡上各出现一次，所以**只靠句柄无法区分是哪张卡**——缩略图落盘路径
   * 和选择键都必须带上这个卡号，否则两张卡会互相覆盖。 */
  storageOf: Map<number, number> = new Map();
  objects: Map<number, NikonPtpObjectInfo> = new Map();
  private queueTail: Promise<void> = Promise.resolve();
  private nextTransactionIdValue: number = 1;

  constructor(command: NikonPtpIpChannel, event: NikonPtpIpChannel, host: string,
    connectionNumber: number, epoch: number) {
    this.command = command;
    this.event = event;
    this.host = host;
    this.connectionNumber = connectionNumber;
    this.epoch = epoch;
  }

  nextTransactionId(): number {
    const id = this.nextTransactionIdValue;
    this.nextTransactionIdValue += 1;
    return id;
  }

  /** Serialize command transactions: exactly one request/response exchange
   * owns the command channel at a time, including its full data phase, so
   * concurrent callers can never receive each other's frames.
   *
   * `tolerateTimeout` makes **this** transaction treat a silent camera as "no
   * answer this time" instead of a dead line: the timeout is re-thrown to the
   * caller without poisoning the session, and a frame that arrives later (the
   * body waking up mid-transaction) is dropped by its transaction number
   * instead of being mistaken for the next reply. Live view is the caller that
   * needs it — a sleeping camera must never cost us the connection. */
  enqueue(op: number, params: number[], expectsData: boolean,
    tolerateTimeout: boolean = false): Promise<NikonPtpResponse> {
    const task: Promise<NikonPtpResponse> = this.queueTail.then(async (): Promise<NikonPtpResponse> => {
      if (this.failed) throw new Error('PTP/IP session is unavailable');
      return NikonPtpIpService.executeTransaction(this, op, params, expectsData, -1, tolerateTimeout);
    });
    this.queueTail = task.then((): void => {}, (): void => {});
    return task;
  }

  /**
   * Same queue, same serialisation, but the operation's data phase flows
   * phone -> camera instead of the other way round.
   *
   * Purely additive sibling of `enqueue`, added for Sony's
   * `SDIO_ControlDevice` (0x9207), whose data phase is a 0- or 2-byte control
   * value. Nikon's `enqueue` and every Nikon call site are untouched: nothing
   * outside the Sony line calls this.
   */
  enqueueDataOut(op: number, params: number[], payload: Uint8Array): Promise<NikonPtpResponse> {
    const task: Promise<NikonPtpResponse> = this.queueTail.then(async (): Promise<NikonPtpResponse> => {
      if (this.failed) throw new Error('PTP/IP session is unavailable');
      return NikonPtpIpService.executeTransactionDataOut(this, op, params, payload, -1);
    });
    this.queueTail = task.then((): void => {}, (): void => {});
    return task;
  }
}

/**
 * Nikon's ordinary image-transfer path is PTP/IP over TCP, not the Panasonic
 * HTTP /auth and /media/gallery endpoints. This adapter implements the
 * standard read-only sequence needed by the transfer page:
 * InitCommand, InitEvent, OpenSession, GetStorageIDs, GetNumObjects,
 * GetObjectHandles, GetObjectInfo and GetThumb/GetObject.
 *
 * Protocol freeze: InitCommand (GUID strategy, name "Pixelshop Camera", UTF-16,
 * version 0x00010000), InitEvent connectionNumber, OpenSession sessionId=1
 * with transactionId=0, DataPhaseInfo=1 and the operationRequest encoding are
 * byte-for-byte identical to the previous implementation. No new commands
 * (probe/keepalive/CloseSession/GetDeviceInfo) are introduced.
 */
export class NikonPtpIpService {
  /** PTP/IP TCP port. Public so the control page's brand layer can show it in
   * the identity line without duplicating the literal (SonyCameraService.
   * PTPIP_PORT is the same number and the same convention). */
  static readonly PORT = 15740;
  private static readonly SESSION_ID = 1;
  private static readonly TYPE_INIT_COMMAND = 1;
  private static readonly TYPE_INIT_ACK = 2;
  private static readonly TYPE_INIT_EVENT = 3;
  private static readonly TYPE_INIT_EVENT_ACK = 4;
  private static readonly TYPE_OPERATION_REQUEST = 6;
  private static readonly TYPE_OPERATION_RESPONSE = 7;
  private static readonly TYPE_START_DATA = 9;
  private static readonly TYPE_DATA = 10;
  /** PTP/IP `EndData` —— **12，这是相机实测在用的值**。
   *
   *  CIPA DC-005 的类型表里 11 才是 EndData、12 是 Ping，所以这里一度被"改正"成
   *  11。**那次改动是错的，真机日志已经否掉**：
   *
   *    改成 12（原状）：
   *      ptpip data-out tx=48 typeStart=9 typeData=10 typeEnd=12
   *      ptpip response op=SetDevicePropValue tx=48 code=0x201F   ← 相机立刻应答
   *
   *    改成 11（我的"修正"）：
   *      ptpip data-out tx=59 typeStart=9 typeData=10 typeEnd=11
   *      （没有任何 response）
   *      ptpip write-prop code=unknown message=PTP/IP transaction timeout  ← 挂 10 秒
   *      ptpip session poisoned
   *
   *  也就是说相机认 12 作数据结束、对 11 完全不理。改成 11 把一次"快速拒绝"变成了
   *  "十秒挂死 + 会话毒化"，比原来更坏。**以实测为准，不以规范表为准。**
   *
   *  而 `0x201F` 并不是结束帧造成的：相机收到数据、答了 `0x201F`
   *  （TRANSACTION_CANCELLED）——它是在**读完数据之后**取消事务的，所以原因在值
   *  或相机当前状态上，不在封装上。 */
  private static readonly TYPE_END_DATA = 12;
  /** 规范值 11。接收端一并认下，发送端不用。 */
  private static readonly TYPE_END_DATA_LEGACY = 11;
  private static readonly OP_OPEN_SESSION = 0x1002;
  private static readonly OP_CLOSE_SESSION = 0x1003;
  private static readonly OP_GET_STORAGE_IDS = 0x1004;
  private static readonly OP_GET_NUM_OBJECTS = 0x1006;
  private static readonly OP_GET_OBJECT_HANDLES = 0x1007;
  private static readonly OP_GET_OBJECT_INFO = 0x1008;
  private static readonly OP_GET_OBJECT = 0x1009;
  private static readonly OP_GET_THUMB = 0x100A;
  private static readonly OP_GET_PARTIAL_OBJECT = 0x101B;
  private static readonly RESPONSE_OK = 0x2001;
  private static readonly RESPONSE_OPERATION_NOT_SUPPORTED = 0x2005;
  /** `SessionAlreadyOpen`. A camera answers a session-open with it while the
   * session of a previous connection is still held, which is exactly what a
   * reconnect that races the previous TCP teardown produces. */
  private static readonly RESPONSE_SESSION_ALREADY_OPEN = 0x201E;

  // --- Camera control -----------------------------------------------------
  // Every opcode and property code below was read out of the official
  // SnapBridge 2.13.3 (com.nikon.snapbridge.cmru) `classes.dex`, from the
  // command classes under `cmru.ptpclient.actions` (one class per opcode, with
  // the numeric code in its `c()`/`c()S` accessor and the parameter list in its
  // `b()[I`).  They are shipped-artifact facts, not PTP-spec guesses.
  //
  // Nikon keeps its camera-control operations in the vendor range 0x9xxx and
  // its device properties in 0x5000/0xD100, so none of this overlaps the
  // file-transfer opcodes above.
  private static readonly OP_GET_DEVICE_INFO = 0x1001;
  /** ISO 15740 `GetDevicePropDesc`：带 **一个参数（属性码）**，数据阶段回
   *  **描述符**（DevicePropCode / DataType / GetSet / 默认值 / 当前值 / 取值形式）。
   *
   *  ⚠️ 这两个操作码曾经被改反过：注释一度声称「0x1015 是 Desc，所以取值应该写
   *  0x1014」，于是取值和取描述符被对调。真机日志直接否掉了它——用 0x1015 去问
   *  `0x5007`，相机回的是 **2 字节**，问 `0xd100` 回 **4 字节**，问 `0x5001`（电量）
   *  回 **1 字节**：那是**属性值**，且宽度跟官方动作类用的数据类
   *  （`SetFnumberAction` 用 16 位、`SetShutterSpeedAction` 用 32 位）一一吻合，
   *  描述符不可能只有 1~4 字节（最短也要 9 字节）。
   *
   *  所以 `0x1014 = Desc`、`0x1015 = Value` 是标准编号，也是本机实测口径。 */
  private static readonly OP_GET_DEVICE_PROP_DESC = 0x1014;
  /** ISO 15740 `GetDevicePropValue`：带 **一个参数（属性码）**，值的字节从相机发回。 */
  private static readonly OP_GET_DEVICE_PROP_VALUE = 0x1015;
  private static readonly OP_SET_DEVICE_PROP_VALUE = 0x1016;
  /** Nikon "is the body ready?" poll.  Also the documented precondition probe
   * before a capture and the completion signal after it. */
  private static readonly OP_NIKON_DEVICE_READY = 0x90C8;
  private static readonly OP_NIKON_START_LIVE_VIEW = 0x9201;
  private static readonly OP_NIKON_END_LIVE_VIEW = 0x9202;
  private static readonly OP_NIKON_GET_LIVE_VIEW_IMAGE = 0x9203;
  private static readonly OP_NIKON_GET_LIVE_VIEW_IMAGE_EX = 0x9428;
  /** Shutter release.  Takes two int parameters derived from the capture sort
   * (drive-then-shoot versus shoot). */
  private static readonly OP_NIKON_INITIATE_CAPTURE = 0x9207;
  /** Switches the body between still and remote application modes. */
  private static readonly OP_NIKON_CHANGE_APPLICATION_MODE = 0x9435;
  /** `ChangeCameraMode` —— 机身控制权交还给谁。`0` = CAMERA，`1` = HOST（遥控端）。 */
  private static readonly OP_NIKON_CHANGE_CAMERA_MODE = 0x90C2;
  /** 遥控录像的「开始」/「停止」。
   *
   *  这两个操作码是从官方 SnapBridge 2.13.3 的代码里读出来的，不是猜的：
   *
   *    StartMovieRecAction → `snapbridge.ptpclient.rd`
   *        c()S  = -0x6df6 = 0x920A，b()[I = 空数组（无参数）
   *    EndMovieRecAction   → `snapbridge.ptpclient.g1` → `h1`
   *        c()S  = -0x6df5 = 0x920B，同样无参数
   *
   *  官方 `StartMovieRecAction.isSupportAction` 还要求机身同时支持事件
   *  0xC105 / 0xC108 / 0xC10A——也就是说录像的**状态**是机身用事件回报的，
   *  不是靠轮询某个属性。所以这里只发命令、用应答判断是否接受，不去读属性。 */
  private static readonly OP_NIKON_START_MOVIE_REC = 0x920A;
  private static readonly OP_NIKON_END_MOVIE_REC = 0x920B;

  /** Response codes a ready-poll can return while the body is still working.
   * Any of these means "retry", not "failed". */
  private static readonly CAPTURE_BUSY_CODES: number[] = [0x2019, 0xA200, 0xA201, 0xA207];
  private static readonly CAPTURE_POLL_INTERVAL_MS = 100;
  private static readonly CAPTURE_POLL_TIMEOUT_MS = 30000;

  // --- Arguments for 0x9207 InitiateCapture --------------------------------
  //
  // The operation takes two ints: a release mode and a storage medium. Both come
  // from Nikon enums whose wire values are NOT their ordinals, and the
  // `CaptureAction$1.b[...]` table in the decompiled output is a compiler switch
  // map rather than these values. The numbers below were recovered by replaying
  // each enum's static initialiser register flow; that replay reproduced the
  // ordinal column as a strict 0..8 ascending run, which is what makes the
  // mapping trustworthy. In DEX, `const/4` is a four-bit SIGNED literal, so the
  // `#14` printed for the autofocus case is really -2.
  /** Release mode: drive autofocus, then release. */
  static readonly RELEASE_AF_FOCUS = -2;
  /** Release mode: release immediately. */
  static readonly RELEASE_NORMAL = -1;
  static readonly RELEASE_PRESET_1 = 1;
  static readonly RELEASE_PRESET_2 = 2;
  static readonly RELEASE_PRESET_3 = 3;
  static readonly RELEASE_PRESET_4 = 4;
  static readonly RELEASE_PRESET_5 = 5;
  static readonly RELEASE_PRESET_6 = 6;
  /** Release mode: dust reference image. */
  static readonly RELEASE_DUST_REFERENCE = 16;
  /** Storage medium: card only. */
  static readonly STORAGE_CARD = 0;
  /** Storage medium: the camera's SDRAM buffer only. */
  static readonly STORAGE_SDRAM = 1;
  /** Storage medium: card and SDRAM. */
  static readonly STORAGE_CARD_AND_SDRAM = 2;

  /** Live-view frames arrive in the PTP data phase as a fixed 384-byte
   * little-endian header followed by the JPEG payload; the header carries the
   * JPEG size and the whole-frame size but no transport-level length. */
  private static readonly LIVE_VIEW_HEADER_BYTES = 384;
  /** Byte offset of the u32 big-endian image length inside a live-view frame. */
  private static readonly LIVE_VIEW_IMAGE_LENGTH_OFFSET = 4;
  /** When the body last reported a finished capture, or 0. */
  private static lastCaptureCompleteAt = 0;

  /** PTP device-property codes for the exposure parameters the remote panel
   * drives.  Read with GetDevicePropValue, written with SetDevicePropValue. */
  static readonly PROP_SHUTTER_SPEED = 0xD100;
  static readonly PROP_APERTURE = 0x5007;
  static readonly PROP_WHITE_BALANCE = 0x5005;
  static readonly PROP_EXPOSURE_MODE = 0x500E;
  static readonly PROP_ISO = 0x500F;
  static readonly PROP_EXPOSURE_COMPENSATION = 0x5010;
  static readonly PROP_APPLICATION_MODE = 0xD1F0;

  /** PTP event: a capture finished.  Payload is the transaction id. */
  static readonly EVENT_CAPTURE_COMPLETE = 0x400D;
  static readonly EVENT_DEVICE_PROP_CHANGED = 0x4006;
  /** 官方 `StartMovieRecAction` 明确要求机身支持这三个事件，录像状态由它们回报。
   *  `0xC10A` 是开始录制，`0xC108` 是录制完成，`0xC105` 是录制被打断。 */
  static readonly EVENT_MOVIE_REC_START = 0xC10A;
  static readonly EVENT_MOVIE_REC_COMPLETE = 0xC108;
  static readonly EVENT_MOVIE_REC_INTERRUPTED = 0xC105;
  /**
   * LSS connection-configuration mirror over PTP.
   *
   * Reads the same Wi-Fi credential block the BLE `2004` characteristic
   * returns, so a body already on Wi-Fi can hand its credentials to a second
   * device without a fresh Bluetooth pairing.
   */
  static readonly OP_NIKON_GET_LSS_CONNECTION_CONFIGURATION = 0x9532;
  private static readonly TRANSACTION_TIMEOUT_MS = 10000;
  private static readonly EVENT_IDLE_TIMEOUT_MS = 60000;
  /** How many times a vendor session open is attempted on a FRESH connection.
   * A vendor session open is the operation that establishes the camera's
   * function mode, so it cannot be retried on the same session; each retry is a
   * new TCP connection, separated by the camera-side release window below. */
  private static readonly VENDOR_OPEN_ATTEMPTS = 3;
  /** Wait after a teardown and between vendor session-open attempts. The TCP
   * close is already awaited by then; this covers the camera releasing the PTP
   * session a moment later, which is what the 0x201E answers come from. */
  private static readonly VENDOR_OPEN_SETTLE_MS = 500;
  /** Unexpected control frames tolerated while the handshake waits for the
   * `InitCommandAck` / `InitEventAck`, and the window each tolerated read gets.
   * One is enough for a camera that emits a spurious frame before the real ack;
   * a camera that refuses the initiator outright fails fast instead of burning a
   * full transaction timeout per unexpected frame. */
  private static readonly INIT_SKIP_FRAMES = 1;
  private static readonly INIT_SKIP_TIMEOUT_MS = 1200;
  // Handles examined per scan page. A page may consume its whole budget on
  // directories or unusable objects and still return zero items; the cursor
  // has advanced, so the next page continues instead of stalling.
  private static readonly SCAN_BUDGET = 48;
  private static readonly MAX_WHOLE_OBJECT_BYTES = 64 * 1024 * 1024;
  private static readonly MAX_U32 = 0xFFFFFFFF;
  private static readonly RAW_EXTENSIONS: string[] = [
    'nef', 'nrw', 'raw', 'dng', 'arw', 'srf', 'sr2', 'crw', 'cr2', 'cr3',
    'raf', 'orf', 'pef', 'srw', 'rw2', 'rwl', 'iiq', '3fr', 'x3f', 'tif', 'tiff',
  ];

  private static session: NikonPtpSession | null = null;
  private static connecting: Promise<NikonPtpSession> | null = null;
  private static connectingHost: string = '';
  /** The session-open opcode the in-flight handshake is using, so a second
   * caller asking for a different one cannot be handed the wrong session. */
  private static connectingOpcode: number = 0;
  private static epochCounter: number = 0;
  /** In-flight TCP teardown of the last closed session. `close()` stays
   * synchronous, so the platform's socket close cannot be awaited there; this is
   * where its promise lives for `release()`, which a reconnect awaits so a new
   * connection can never overlap the previous one. */
  private static teardown: Promise<void> | null = null;
  /** How many fresh connections the LAST session open needed; 1 means the first
   * attempt was accepted. Diagnostic only, reported on the browse line so a
   * retry that succeeded is visible as `2`/`3` instead of being invisible. */
  static sessionOpenAttempts: number = 0;

  /** Monotonic session generation. UI tasks capture it before an async camera
   * operation and drop results when the value changed, so a teardown or a new
   * connect can never be overwritten by a late response. */
  static epoch(): number {
    return NikonPtpIpService.epochCounter;
  }

  /** Whether a PTP/IP session is currently established and not poisoned. The
   * UI uses this to distinguish "session lost, reconnect" from other page
   * failures that a reconnect cannot fix. */
  static isSessionAlive(): boolean {
    const session = NikonPtpIpService.session;
    return session !== null && !session.failed;
  }

  /**
   * Opens (or reuses) the shared PTP/IP session for `host`.
   *
   * Purely additive accessor for a brand-specific protocol layer: Sony's
   * contents-transfer enumeration runs its own private operations over the very
   * same socket pair, handshake and command queue. Nothing in the Nikon paths
   * below changes because of this method.
   *
   * `openOpcode`/`openParams` exist because the session-open operation is itself
   * a protocol choice, not a constant. Sony's vendor branch opens the session
   * with `SDIO_OpenSession` (0x9210) `[1, functionMode]` and the standard
   * `OpenSession` (0x1002) `[1]` is the OTHER branch of the same if/else
   * (`initialization/Initializer.java:83-96`); a camera whose contents-transfer
   * browse requires the vendor branch never sees it if the connection always
   * starts with 0x1002. Omitting both arguments keeps the standard open exactly
   * as before.
   *
   * `allowStandardFallback` (default true) is what that fallback now answers to.
   * A vendor open is retried on fresh connections first; if the camera refuses
   * it anyway, the standard open is still attempted when this is true, and the
   * caller can tell the two apart from `session.openOpcode` — the operation that
   * REALLY established the session. A caller that must not be handed a
   * differently-moded session passes false and gets a distinct error instead.
   *
   * `attempts` (default: decided by the operation — 3 for a vendor open, 1 for
   * the standard one) is how many FRESH connections the caller allows. It exists
   * because a camera that still holds the previous PTP session refuses the new
   * open, and the only cure is to let it go and dial again; a caller that needs
   * its own session established can therefore spend retries on either operation.
   * Every Nikon path keeps the default: one attempt, unchanged error.
   */
  static async acquireSession(host: string, openOpcode?: number,
    openParams?: number[], allowStandardFallback?: boolean,
    attempts?: number): Promise<NikonPtpSession> {
    const safeHost = NikonPtpIpService.cleanHost(host);
    if (safeHost.length === 0) {
      throw new Error('PTP/IP host is empty');
    }
    const opcode = openOpcode === undefined ? NikonPtpIpService.OP_OPEN_SESSION : openOpcode;
    const params = openParams === undefined
      ? [NikonPtpIpService.SESSION_ID]
      : openParams;
    const fallback = allowStandardFallback === undefined ? true : allowStandardFallback;
    const tries = attempts === undefined ? 0 : attempts;
    return await NikonPtpIpService.ensureSession(safeHost, opcode, params, fallback, tries);
  }

  static async listGallery(context: common.UIAbilityContext, host: string, limit: number = 6): Promise<NikonPtpCatalogResult> {
    const safeHost = NikonPtpIpService.cleanHost(host);
    if (safeHost.length === 0) {
      return { ok: false, message: '未取得相机 Wi‑Fi 网关', host: '', total: 0, items: [], nextHandleIndex: 0, remaining: 0 };
    }
    try {
      const session = await NikonPtpIpService.ensureSession(safeHost);
      const storageResponse = await session.enqueue(NikonPtpIpService.OP_GET_STORAGE_IDS, [], true);
      if (storageResponse.code !== NikonPtpIpService.RESPONSE_OK) {
        return {
          ok: false, message: `PTP/IP GetStorageIDs 响应 ${NikonPtpIpService.hexCode(storageResponse.code)}`,
          host: safeHost, total: 0, items: [], nextHandleIndex: 0, remaining: 0,
        };
      }
      const storageIds = NikonPtpIpService.parseU32List(storageResponse.data);
      NikonPtpIpService.log(`ptpip storages=${storageIds.length}`);
      if (storageIds.length === 0) {
        return { ok: false, message: 'PTP/IP 未返回存储卡', host: safeHost, total: 0, items: [], nextHandleIndex: 0, remaining: 0 };
      }
      // **两张卡都要读，但不能混成一张。**
      //
      // Z 系列等机身可以同时挂两张卡。旧实现只选"对象最多的那张"，另一张卡上的
      // 照片在 App 里完全看不到；而直接把两边的句柄合到一起再全局排序也不行——
      // 两张卡的句柄空间是**各自独立**的，同一个句柄号可能在两张卡上各出现一次，
      // 混在一起既会串序，也会让缩略图互相覆盖。
      //
      // 所以按卡分组：每张卡内部各自按句柄升序（= 拍摄时间序），取图时倒序，
      // 最新在前；每一项都带着自己的 `storageId`，界面据此区分「卡 1 / 卡 2」。
      const cardHandles: number[][] = [];
      const cardIds: number[] = [];
      for (const candidateStorageId of storageIds) {
        const countResponse = await session.enqueue(
          NikonPtpIpService.OP_GET_NUM_OBJECTS, [candidateStorageId, 0, 0], false);
        if (countResponse.code !== NikonPtpIpService.RESPONSE_OK) {
          NikonPtpIpService.log(`ptpip storage=${candidateStorageId} count-code=${NikonPtpIpService.hexCode(countResponse.code)}`);
          continue;
        }
        const candidateTotal = countResponse.params.length > 0
          ? countResponse.params[0]
          : NikonPtpIpService.parseFirstU32(countResponse.data);
        const handlesResponse = await session.enqueue(
          NikonPtpIpService.OP_GET_OBJECT_HANDLES, [candidateStorageId, 0, 0], true);
        if (handlesResponse.code !== NikonPtpIpService.RESPONSE_OK) {
          NikonPtpIpService.log(`ptpip storage=${candidateStorageId} handles-code=${NikonPtpIpService.hexCode(handlesResponse.code)}`);
          continue;
        }
        const candidateHandles = NikonPtpIpService.parseU32List(handlesResponse.data)
          .filter((value: number) => value !== 0);
        // 空卡（objects=0）是正常情况，算这张卡可用，不能因此判定"没有可读存储卡"。
        NikonPtpIpService.log(`ptpip card storage=${candidateStorageId} objects=${candidateTotal} handles=${candidateHandles.length}`);
        candidateHandles.sort((left: number, right: number): number => left - right);
        cardIds.push(candidateStorageId);
        cardHandles.push(candidateHandles);
      }
      if (cardIds.length === 0) {
        return { ok: false, message: 'PTP/IP 未返回可读存储卡', host: safeHost, total: 0, items: [], nextHandleIndex: 0, remaining: 0 };
      }
      // 每张卡内部倒序（最新在前），卡与卡之间保持卡槽顺序，互不交错。
      const orderedHandles: number[] = [];
      session.storageOf = new Map();
      for (let cardIndex = 0; cardIndex < cardIds.length; cardIndex++) {
        const cardStorageId = cardIds[cardIndex];
        const descending = cardHandles[cardIndex].slice().reverse();
        for (const cardHandle of descending) {
          orderedHandles.push(cardHandle);
          session.storageOf.set(cardHandle, cardStorageId);
        }
        NikonPtpIpService.log(`ptpip card storage=${cardStorageId} listed=${descending.length} (newest first)`);
      }
      const totalObjects = orderedHandles.length;
      session.storageId = cardIds[0];
      session.handles = orderedHandles;
      session.objects = new Map();
      NikonPtpIpService.log(`ptpip cards=${cardIds.length} total=${totalObjects}`);
      NikonPtpIpService.log('ptpip gallery direction=backward (newest first, per card)');
      NikonPtpIpService.log(`ptpip handles=${session.handles.length}`);
      const firstPage = await NikonPtpIpService.scanPage(context, session, 0,
        Math.min(limit, session.handles.length));
      return {
        ok: true,
        message: `PTP/IP 会话已建立，${cardIds.length} 张存储卡共 ${totalObjects} 个对象，已读取 ${firstPage.items.length} 张缩略图`,
        host: safeHost,
        total: totalObjects,
        items: firstPage.items,
        nextHandleIndex: firstPage.nextHandleIndex,
        remaining: firstPage.remaining,
        storageIds: cardIds,
      };
    } catch (error) {
      NikonPtpIpService.logError('list gallery', error);
      NikonPtpIpService.close();
      return {
        ok: false,
        message: 'PTP/IP 会话未建立，请确认相机 Wi‑Fi 已连接并允许远程控制',
        host: safeHost, total: 0, items: [], nextHandleIndex: 0, remaining: 0,
      };
    }
  }

  /** Cursor-based continuation of listGallery. `fromHandleIndex` must be the
   * nextHandleIndex of the previous page; the result carries the next cursor
   * and the number of unscanned handles. */
  static async fetchPageAfter(context: common.UIAbilityContext, fromHandleIndex: number,
    limit: number = 6): Promise<NikonPtpGalleryPage> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) {
      // A continuation without a live session is abnormal: silently returning
      // an empty page would make the UI claim "all photos loaded" while the
      // command link is actually dead. Fail loudly so the UI can reconnect.
      throw new Error('PTP/IP 会话已中断，无法继续读取图库分页');
    }
    if (session.handles.length === 0) {
      return { items: [], nextHandleIndex: Math.max(0, fromHandleIndex), remaining: 0 };
    }
    const start = Math.max(0, Math.min(Math.floor(fromHandleIndex), session.handles.length));
    return NikonPtpIpService.scanPage(context, session, start, Math.max(1, limit));
  }

  /** 从 `imageId` 里取出对象句柄。
   *
   * `imageId` 的格式是 `卡号:句柄`（`scanPage` 生成），因为两张卡的句柄空间相互
   * 独立，只有句柄无法区分是哪张卡。**不能再写 `Number(imageId)`**——对
   * `"1:42"` 那样的字符串它会直接得到 `NaN`，预览和下载就会带着坏句柄去请求。
   *
   * 兼容没有卡号前缀的旧值（纯数字），这样缓存或旧状态里的条目仍可下载。 */
  static handleOf(imageId: string): number {
    const text = (imageId || '').trim();
    const colon = text.lastIndexOf(':');
    const digits = colon >= 0 ? text.substring(colon + 1) : text;
    const parsed = Number(digits);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  /** 从 `imageId` 里取出卡号；没有前缀时返回 0。 */
  static storageOfImageId(imageId: string): number {
    const text = (imageId || '').trim();
    const colon = text.lastIndexOf(':');
    if (colon <= 0) {
      return 0;
    }
    const parsed = Number(text.substring(0, colon));
    return Number.isFinite(parsed) ? parsed : 0;
  }

  static async downloadOriginal(context: common.UIAbilityContext, item: NikonPtpGalleryItem, index: number,
    onProgress?: (progress: number, received: number, total: number) => void): Promise<string> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed || item.handle <= 0) return '';
    const total = item.size || 0;
    // GetPartialObject encodes offset/length as u32; larger objects need a
    // protocol change that is out of scope for this local-only fix.
    if (total > NikonPtpIpService.MAX_U32) {
      NikonPtpIpService.log(`ptpip download-rejected handle=${item.handle} size=${total} exceeds-u32`);
      return '';
    }
    if (onProgress) onProgress(0, 0, total);
    const extension = NikonPtpIpService.extension(item.originalFileName || '') || 'jpg';
    const safeName = (item.originalFileName || `NIKON_${index + 1}.${extension}`)
      .replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_');
    const finalPath = `${context.filesDir}/nikon_original_${index}_${safeName}`;
    const partPath = `${finalPath}.part`;
    let fd: number = -1;
    const startedAt = Date.now();
    try {
      NikonPtpIpService.removeFile(partPath);
      const part = fileIo.openSync(partPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fd = part.fd;
      let written = 0;
      if (total > 0) {
        written = await NikonPtpIpService.writePartialObject(session, item.handle, total, fd, onProgress);
      } else {
        written = await NikonPtpIpService.readWholeObject(session, item.handle, fd, onProgress);
      }
      if (written <= 0) return '';
      fileIo.closeSync(part);
      fd = -1;
      // Commit atomically: the .part file only becomes the real file after
      // the full object was received and written, so an interrupted download
      // can never leave a truncated file that looks complete.
      NikonPtpIpService.removeFile(finalPath);
      fileIo.renameSync(partPath, finalPath);
      // Real throughput on camera Wi-Fi is the number to compare against
      // SnapBridge: if the app and SnapBridge land at the same MB/s the
      // ceiling is the body's radio, not the transfer stack.
      const seconds = Math.max((Date.now() - startedAt) / 1000, 0.001);
      NikonPtpIpService.log(`ptpip download complete file=${safeName} bytes=${written} seconds=${seconds.toFixed(1)} rate=${(written / 1024 / 1024 / seconds).toFixed(2)}MB/s`);
      if (onProgress) onProgress(100, written, total || written);
      return `file://${finalPath}`;
    } catch (error) {
      NikonPtpIpService.logError('download original', error as Object);
      return '';
    } finally {
      if (fd >= 0) {
        try { fileIo.closeSync(fd); } catch (_error) { }
      }
      NikonPtpIpService.removeFile(partPath);
    }
  }

  // --- Camera control -----------------------------------------------------
  //
  // Every opcode and property code used here was read out of the official
  // SnapBridge 2.13.3 DEX (see the constants at the top of this class). The
  // transport primitives are shared with image transfer; only two things are
  // new, and both are marked below: a send-data phase, and the readiness poll.

  /** True while a session is open and still usable for control operations. */
  static isControlReady(): boolean {
    return NikonPtpIpService.activeControlTransport() !== null;
  }

  /**
   * 外部传输层（当前只有索尼 USB 会挂上来）。
   *
   * 为什么放在这里而不是再建一套控制服务：索尼的控制操作（`0x9207`
   * `SDIO_ControlDevice`）在官方代码里只依赖 `ITransactionExecutor`，USB 与
   * PTP/IP 共用同一个操作码与同一段属性读取逻辑。把「当前用哪条传输」做成一个
   * 可替换的指针，控制页与 `SonyLiveView` 的按键序列一行都不用改。
   */
  private static externalTransport: PtpTransport | null = null;

  /** 挂上/摘掉外部传输。传 null 回到 PTP/IP。 */
  static attachTransport(transport: PtpTransport | null): void {
    NikonPtpIpService.externalTransport = transport;
    NikonPtpIpService.log(`control transport=${transport === null ? 'ptpip' : 'usb'}`);
  }

  /** 控制类操作实际使用的传输：外部（USB）优先，否则退回 PTP/IP 会话。 */
  static activeControlTransport(): PtpTransport | null {
    const external = NikonPtpIpService.externalTransport;
    if (external !== null && !external.failed) return external;
    return NikonPtpIpService.currentSession();
  }

  /**
   * The live session, or null. Purely additive read-only accessor for
   * brand-specific protocol layers (Sony's live-view line) that need the
   * session's own fields - `host` and, above all, `openOpcode`, which is the
   * only record of whether the camera granted a standard or a vendor session.
   * No Nikon path reads this.
   */
  static currentSession(): NikonPtpSession | null {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) return null;
    return session;
  }

  /**
   * Sends one control operation whose data phase flows phone -> camera and
   * returns its raw response code (-1 when there is no usable session).
   *
   * Additive: the body is the generalisation of `writeProperty` below onto the
   * session queue, and the encoding is Sony's own
   * (`ptpip/ptpip/base/transaction/TransactionExecutor.java:133-139`):
   *
   *   - a ZERO-length payload is sent as a plain `OperationRequest` with
   *     DataPhaseInfo 1 and NO data frames at all - that file's
   *     `if (bArr.length == 0)` branch sends
   *     `new OperationRequestPacket(NoDataOrDataInPhase, ...)` and nothing else.
   *     This is exactly the shape of `RequestOneShooting` (control code 53959),
   *     whose `EnumControlCode.getData` returns `new byte[0]`;
   *   - a non-zero payload is announced with DataPhaseInfo 2 and pushed as
   *     StartData(total) followed by the bytes, which is that same file's
   *     `else` branch (`StartDataPacket(i2, bArr.length)` then
   *     `EndDataPacket(i2, bArr)`).
   *
   * Every Nikon call site keeps using `enqueue`; nothing here is reachable from
   * a Nikon path.
   */
  static async sendControlData(op: number, params: number[], payload: Uint8Array): Promise<number> {
    // USB 会话优先：控制页在 USB 上用的就是这条路径。
    const session = NikonPtpIpService.activeControlTransport();
    if (session === null) {
      return -1;
    }
    try {
      const response = await session.enqueueDataOut(op, params, payload);
      NikonPtpIpService.log(`ptpip control-data op=${NikonPtpIpService.operationName(op)}` +
        ` params=[${params.join(',')}] bytes=${payload.length}` +
        ` code=${NikonPtpIpService.hexCode(response.code)}`);
      return response.code;
    } catch (error) {
      NikonPtpIpService.logError('ptpip control-data', error as Object);
      return -1;
    }
  }

  /**
   * Issues one Nikon readiness poll and returns the raw response code.
   *
   * 0x2001 means ready; the busy codes mean "still working"; -1 means there is
   * no usable session. Exposed because the very same poll both precedes a
   * capture and reports when it finished.
   */
  static async deviceReady(): Promise<number> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) {
      return -1;
    }
    try {
      const response = await session.enqueue(NikonPtpIpService.OP_NIKON_DEVICE_READY, [], false);
      NikonPtpIpService.log(`ptpip device-ready code=${NikonPtpIpService.hexCode(response.code)}`);
      return response.code;
    } catch (error) {
      NikonPtpIpService.logError('ptpip device-ready', error as Object);
      return -1;
    }
  }

  /** Whether a readiness response means "the body is still working". */
  static isBusyCode(code: number): boolean {
    return NikonPtpIpService.CAPTURE_BUSY_CODES.indexOf(code) >= 0;
  }

  /**
   * Issues `0x9207 InitiateCapture`.
   *
   * The operation takes exactly two parameters — a release mode and a storage
   * medium — so this stays a raw two-argument call; `capture()` is the
   * convenience wrapper that supplies the usual pair.
   */
  static async initiateCapture(releaseMode: number, storage: number): Promise<number> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) {
      return -1;
    }
    try {
      const response = await session.enqueue(NikonPtpIpService.OP_NIKON_INITIATE_CAPTURE, [releaseMode, storage], false);
      NikonPtpIpService.log(`ptpip initiate-capture release=${releaseMode} storage=${storage} ` +
        `code=${NikonPtpIpService.hexCode(response.code)}`);
      return response.code;
    } catch (error) {
      NikonPtpIpService.logError('ptpip initiate-capture', error as Object);
      return -1;
    }
  }

  /**
   * Releases the shutter the way the official client does.
   *
   * Waits for the body to report ready, issues the capture, then polls until the
   * body reports it is done. `afDrive` selects autofocus-then-release instead of
   * an immediate release; the medium defaults to the card.
   *
   * Returns true only when the capture was accepted AND the body finished.
   */
  static async capture(afDrive: boolean = false,
    storage: number = NikonPtpIpService.STORAGE_CARD): Promise<boolean> {
    if (!await NikonPtpIpService.waitUntilReady()) {
      NikonPtpIpService.log('ptpip capture aborted: camera never reported ready');
      return false;
    }
    const releaseMode = afDrive ? NikonPtpIpService.RELEASE_AF_FOCUS : NikonPtpIpService.RELEASE_NORMAL;
    const code = await NikonPtpIpService.initiateCapture(releaseMode, storage);
    if (code < 0) {
      return false;
    }
    if (code !== NikonPtpIpService.RESPONSE_OK && !NikonPtpIpService.isBusyCode(code)) {
      NikonPtpIpService.log(`ptpip capture rejected code=${NikonPtpIpService.hexCode(code)}`);
      return false;
    }
    return await NikonPtpIpService.waitUntilReady();
  }

  /**
   * Polls readiness until the body reports it is done.
   *
   * The official client waits out a capture exactly this way: poll every 100 ms
   * and treat the busy codes as "keep going". The capture-complete event is a
   * second, passive confirmation of the same fact.
   */
  static async waitUntilReady(timeoutMs: number = NikonPtpIpService.CAPTURE_POLL_TIMEOUT_MS): Promise<boolean> {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      const code = await NikonPtpIpService.deviceReady();
      if (code === NikonPtpIpService.RESPONSE_OK) {
        return true;
      }
      if (code < 0) {
        return false;
      }
      if (!NikonPtpIpService.isBusyCode(code)) {
        NikonPtpIpService.log(`ptpip capture poll aborted code=${NikonPtpIpService.hexCode(code)}`);
        return false;
      }
      await NikonPtpIpService.delay(NikonPtpIpService.CAPTURE_POLL_INTERVAL_MS);
    }
    NikonPtpIpService.log('ptpip capture poll timeout');
    return false;
  }

  /**
   * Reads one property descriptor (`0x1014`, one parameter = the property code).
   *
   * Two uses: learn the legal range / enum for a parameter, and — the one that
   * matters for camera compatibility — ask the body whether it supports the
   * property at all. The official client gates every parameter on exactly this
   * (`GetFnumberAction.isSupportAction` → `CameraController.isSupportPropertyCode`
   * after `isSupportOperation`), so feature detection comes from the camera
   * instead of a per-model table.
   *
   * A real descriptor is at least 9 bytes (DevicePropCode 2 + DataType 2 +
   * GetSet 1 + Default + Current + FormFlag). Anything shorter is the property
   * *value*, not a descriptor — which is exactly how the 0x1014/0x1015 swap was
   * caught on hardware: 0x1015 answered with 1-4 bytes whose widths matched the
   * official data classes.
   */
  static async readPropertyDesc(propertyCode: number): Promise<Uint8Array | null> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) {
      return null;
    }
    try {
      const response = await session.enqueue(NikonPtpIpService.OP_GET_DEVICE_PROP_DESC, [propertyCode], true, true);
      if (response.code !== NikonPtpIpService.RESPONSE_OK) {
        NikonPtpIpService.log(`ptpip read-prop-desc code=${NikonPtpIpService.hexCode(propertyCode)} response=${NikonPtpIpService.hexCode(response.code)}`);
        return null;
      }
      return response.data;
    } catch (error) {
      NikonPtpIpService.logError('ptpip read-prop-desc', error as Object);
      return null;
    }
  }

  /** Reads one device property; null when there is no session or the body refuses. */
  static async readProperty(propertyCode: number): Promise<Uint8Array | null> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) {
      return null;
    }
    try {
      const response = await session.enqueue(NikonPtpIpService.OP_GET_DEVICE_PROP_VALUE, [propertyCode], true, true);
      if (response.code !== NikonPtpIpService.RESPONSE_OK) {
        NikonPtpIpService.log(`ptpip read-prop code=${NikonPtpIpService.hexCode(propertyCode)} response=${NikonPtpIpService.hexCode(response.code)}`);
        return null;
      }
      return response.data;
    } catch (error) {
      NikonPtpIpService.logError('ptpip read-prop', error as Object);
      return null;
    }
  }

  /**
   * Writes one device property.
   *
   * This is the one operation in the adapter whose data phase flows the other
   * way: SetDevicePropValue carries its value from the phone to the camera, so
   * the request must announce **DataPhaseInfo 3 (Data Out, initiator →
   * responder)** and the value is pushed as StartData/Data/EndData before the
   * response comes back. (An earlier revision of this comment said 2, and the
   * code below it announced 2 as well; 2 means Data In, i.e. the opposite
   * direction, which is why the body cancelled every write with 0x201F.)
   *
   * It also runs through `session.enqueueDataOut` so it shares the command
   * queue with live view: a data-out exchange and a frame fetch must never be
   * waiting on the same channel at once. The previous revision sent and read
   * the channel directly, which let the two steal each other's packets.
   */
  static async writeProperty(propertyCode: number, value: Uint8Array): Promise<boolean> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed || value.length === 0) {
      return false;
    }
    // **必须走 `enqueueDataOut`，不能自己摸通道。**
    //
    // 这个函数以前自己取事务号、自己 `channel.send`、自己 `receivePacket`，完全
    // 绕过 `session` 那条队列。取景循环走的是 `enqueue`（在队列里），于是写命令和
    // 取帧请求会**同时**在命令通道上等应答——谁先 `receivePacket` 谁就把对方的包
    // 吃掉。Z 8 真机日志把这场抢答记得清清楚楚：
    //
    //   ptpip write-prop code=0x5010 bytes=2 tx=55
    //   ptpip session poisoned  message=PTP/IP write-prop response missing
    //   ptpip live-view        message=PTP/IP data length mismatch
    //                                  expected=69093 received=3405
    //
    // 写命令抢到了一个 69 KB 的取景帧（所以"response missing"），取景那边则捡到了
    // 写的应答（所以长度对不上）。一次抢答就把会话读毒化，取景随即中断。
    //
    // 另外这里原来宣告的是 `DataPhaseInfo = 2`（= Data In，相机 → 手机），而写属性
    // 是手机 → 相机，**必须是 3**。这正是"四个不同属性全部被回 0x201F"的原因：
    // 相机被告知数据往它这边流，收到的却是往外的数据阶段，只能取消事务。
    // `executeTransactionDataOut` 里的 `dataPhase` 早已修正为 3，只是这个函数从来
    // 没有走过它——所以修了那么多次写入，始终没修到真正在用的那条路径上。
    NikonPtpIpService.log(`ptpip write-prop code=${NikonPtpIpService.hexCode(propertyCode)} bytes=${value.length}`);
    try {
      const response = await session.enqueueDataOut(
        NikonPtpIpService.OP_SET_DEVICE_PROP_VALUE, [propertyCode], value);
      NikonPtpIpService.log(`ptpip write-prop result code=${NikonPtpIpService.hexCode(response.code)}`);
      return response.code === NikonPtpIpService.RESPONSE_OK;
    } catch (error) {
      NikonPtpIpService.logError('ptpip write-prop', error as Object);
      return false;
    }
  }

  /** 取帧是否走 `0x9428 GetLiveViewImageEx`。官方全程用它；某台机身不认时自动
   *  降级到 `0x9203` 并把这个标记置 false。
   *
   *  **默认关闭（已回滚）。** 2026‑10‑18 在 Z 5 上试过打开：帧请求本身被接受
   *  （回 `0x2001`），但拿到的数据不是 `0x9203` 那种「384 字节头 + JPEG」的布局，
   * 照原样切出来的不是可解码的 JPEG，**页面直接没画面**。而且这种"成功但格式不同"
   *  的失败不会触发下面的降级判断（码是 OK、长度也够），所以不能靠 fallback 兜住。
   *
   *  要再启用，先把 `0x9428` 的返回数据抓一段下来，把它的头布局解出来，再改
   *  `liveViewFrame` 里的切分逻辑——不是换个操作码就能拿到更高画质。 */
  private static liveViewUsesEx: boolean = false;

  /** Starts live view; frames then arrive through liveViewFrame(). */
  static async startLiveView(): Promise<boolean> {
    // **先接管控制权，再开流。** 官方 SnapBridge 建链后第一件事之一就是发这条
    // （Z 5 抓包 16:57:22.451，紧跟在 GetDeviceInfo 之后、属性轮询之前）。
    // 不接管的话机身仍然"自己说了算"，档位与录像按钮会直接拒绝——见
    // `takeHostControl` 的注释。
    await NikonPtpIpService.takeHostControl();
    return await NikonPtpIpService.simpleControl(NikonPtpIpService.OP_NIKON_START_LIVE_VIEW);
  }

  /** 已经发出过 `0x90C2` 的那个会话的 epoch。用 epoch 而不是布尔量，是为了让
   *  重连后的新会话自动重发一次，又不必去改 `close()` 的重置逻辑。 */
  private static hostControlEpoch: number = -1;

  /**
   * `ChangeCameraMode` `0x90C2`：参数 `0` = CAMERA（机身控制），`1` = HOST（遥控端控制）。
   *
   * 依据是官方 SnapBridge 2.13.3 对 Z 5 的抓包：`0x90C2` 只发一次，参数就是 `[1]`，
   * 位置在建链之后、属性轮询与开流之前。
   *
   * 不发它的后果是我们在真机上实测到的两个"没反应"：
   *
   *   SetDevicePropValue 0x500E（档位）→ **0x200F Access Denied**
   *   StartMovieRec      0x920A        → **0xA004**
   *
   * 这两样都是机身自己掌管的控件（拨盘档位、录制键），遥控端没拿到控制权就不让
   * 改；而 EV / 光圈 / ISO / 快门属于"可调参数"，不受影响——所以之前只有档位和
   * 录像坏，其他参数能改。
   */
  static async takeHostControl(): Promise<boolean> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) return false;
    if (NikonPtpIpService.hostControlEpoch === session.epoch) return true;
    try {
      const response = await session.enqueue(
        NikonPtpIpService.OP_NIKON_CHANGE_CAMERA_MODE, [1], false, true);
      NikonPtpIpService.log(`ptpip host-control code=${NikonPtpIpService.hexCode(response.code)}`);
      if (response.code === NikonPtpIpService.RESPONSE_OK) {
        NikonPtpIpService.hostControlEpoch = session.epoch;
        return true;
      }
      return false;
    } catch (error) {
      NikonPtpIpService.logError('ptpip host-control', error as Object);
      return false;
    }
  }

  /** Stops live view. */
  static async endLiveView(): Promise<boolean> {
    return await NikonPtpIpService.simpleControl(NikonPtpIpService.OP_NIKON_END_LIVE_VIEW);
  }

  /** Starts a movie recording on the body (the remote record button).
   *
   *  Runs on the same command queue and stays tolerant of a silent camera, so a
   *  body that is mid-wake answers "not now" (`false`) instead of poisoning the
   *  session. Live view may keep streaming: recording does not need it stopped. */
  /** 把机身控制权交回相机（`0x90C2 [0]`）。
   *
   *  接管（`[1]`）之后，档位拨盘与录制键是"让位"给遥控端的；离开控制页时如果不
   *  交还，用户回到机身操作会觉得相机还被人拽着。没人接管过就不发这条。 */
  static async releaseHostControl(): Promise<boolean> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) return false;
    if (NikonPtpIpService.hostControlEpoch !== session.epoch) return true;
    try {
      const response = await session.enqueue(
        NikonPtpIpService.OP_NIKON_CHANGE_CAMERA_MODE, [0], false, true);
      NikonPtpIpService.log(`ptpip host-control release code=${NikonPtpIpService.hexCode(response.code)}`);
      NikonPtpIpService.hostControlEpoch = -1;
      return response.code === NikonPtpIpService.RESPONSE_OK;
    } catch (error) {
      NikonPtpIpService.logError('ptpip host-control release', error as Object);
      return false;
    }
  }

  static async startMovieRecording(): Promise<boolean> {
    const started = await NikonPtpIpService.simpleControl(NikonPtpIpService.OP_NIKON_START_MOVIE_REC);
    if (!started) {
      // 失败时把 `0xD0A4`（MovieRecProhibitionCondition，录像禁止条件）读出来打一行。
      // 机身拒绝录制的码 `0xA004` 在官方 `ResponseCodes` 里就是 **INVALID_STATUS**
      // ——"当前状态不接受这个操作"，它不会告诉我们是哪个条件没满足；`0xD0A4` 才是
      // 机身自己的说明（拨杆不在录像位、没有可写卡、正在写卡……）。
      let raw = -1;
      try {
        const prohibit = await NikonPtpIpService.readProperty(0xD0A4);
        if (prohibit !== null && prohibit.length >= 4) {
          raw = NikonPtpIpService.readU32(prohibit, 0);
        } else if (prohibit !== null && prohibit.length > 0) {
          raw = prohibit[0];
        }
      } catch (_error) {
        raw = -2;
      }
      NikonPtpIpService.log(`ptpip movie-rec refused; recProhibition=${raw}`);
    }
    return started;
  }

  /** Stops the movie recording started by `startMovieRecording`. */
  static async endMovieRecording(): Promise<boolean> {
    return await NikonPtpIpService.simpleControl(NikonPtpIpService.OP_NIKON_END_MOVIE_REC);
  }

  /**
   * Fetches one live-view frame and strips the transport header.
   *
   * The frame arrives in the PTP data phase as a fixed 384-byte little-endian
   * header followed by the JPEG. Only the JPEG is returned, because that is
   * what a decoder wants; the header's geometry fields are not needed to
   * display a frame.
   */
  static async liveViewFrame(): Promise<Uint8Array | null> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) {
      return null;
    }
    try {
      // **取帧走 `0x9428 GetLiveViewImageEx`，和官方一致。**
      //
      // 官方 SnapBridge 2.13.3 对 Z 5 的整段会话里，取帧**全部**是 0x9428（1629 次，
      // 无参数），一次 0x9203 都没发；而 0x9203 是"标准清晰度"那条通道，画质明显
      // 低一档。我们一直用 0x9203，所以串流画面比官方糊。
      //
      // 万一某台机身不认 0x9428（回非 0x2001 或者数据太短），就自动退回 0x9203 并
      // 记住，不在每帧上反复试。
      const op = NikonPtpIpService.liveViewUsesEx
        ? NikonPtpIpService.OP_NIKON_GET_LIVE_VIEW_IMAGE_EX
        : NikonPtpIpService.OP_NIKON_GET_LIVE_VIEW_IMAGE;
      let response = await session.enqueue(op, [], true, true);
      if (op === NikonPtpIpService.OP_NIKON_GET_LIVE_VIEW_IMAGE_EX
        && (response.code !== NikonPtpIpService.RESPONSE_OK
          || response.data.length <= NikonPtpIpService.LIVE_VIEW_HEADER_BYTES)) {
        NikonPtpIpService.log(`ptpip live-view ex code=${NikonPtpIpService.hexCode(response.code)}`
          + ' -> fall back to 0x9203');
        NikonPtpIpService.liveViewUsesEx = false;
        response = await session.enqueue(NikonPtpIpService.OP_NIKON_GET_LIVE_VIEW_IMAGE, [], true, true);
      }
      const data = response.data;
      if (response.code !== NikonPtpIpService.RESPONSE_OK ||
        data.length <= NikonPtpIpService.LIVE_VIEW_HEADER_BYTES) {
        return null;
      }
      // The 384-byte header is BIG-endian, unlike the PTP/IP framing around it,
      // and the image byte count sits at offset 4 as a u32. Bytes 8 and 10 are a
      // u16 *pixel* width and height, not a length, so they must never be used
      // for slicing. A length field that exceeds what actually arrived is treated
      // as absent rather than trusted, so a malformed frame yields the whole tail
      // instead of a truncated JPEG.
      const imageLength = NikonPtpIpService.readU32BigEndian(data,
        NikonPtpIpService.LIVE_VIEW_IMAGE_LENGTH_OFFSET);
      const available = data.length - NikonPtpIpService.LIVE_VIEW_HEADER_BYTES;
      const plausible = imageLength > 0 && imageLength <= available;
      if (!plausible) {
        NikonPtpIpService.log(`ptpip live-view length field implausible field=${imageLength} available=${available}`);
      }
      const end = plausible ? NikonPtpIpService.LIVE_VIEW_HEADER_BYTES + imageLength : data.length;
      const jpeg = data.slice(NikonPtpIpService.LIVE_VIEW_HEADER_BYTES, end);
      NikonPtpIpService.log(`ptpip live-view frame bytes=${jpeg.length}`);
      return jpeg;
    } catch (error) {
      NikonPtpIpService.logError('ptpip live-view', error as Object);
      return null;
    }
  }

  /** Switches the body into remote application mode; some bodies require it
   * before live view or a remote shutter is accepted. */
  static async changeApplicationMode(on: boolean): Promise<boolean> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) {
      return false;
    }
    try {
      const response = await session.enqueue(NikonPtpIpService.OP_NIKON_CHANGE_APPLICATION_MODE, [on ? 1 : 0], false);
      NikonPtpIpService.log(`ptpip app-mode on=${on ? 1 : 0} code=${NikonPtpIpService.hexCode(response.code)}`);
      return response.code === NikonPtpIpService.RESPONSE_OK;
    } catch (error) {
      NikonPtpIpService.logError('ptpip app-mode', error as Object);
      return false;
    }
  }

  /**
   * Reads and parses `0x1001 GetDeviceInfo`.
   *
   * The payload is LITTLE-endian — again unlike the live-view header, whose own
   * encoding is big-endian. Its fourth field is a variable-length PTP string, so
   * the fields after it cannot be reached by fixed offsets and must be walked in
   * order. The supported-operation list is what the official client consults
   * before offering a feature (it probes `0x9435` exactly this way), so a control
   * screen can avoid issuing operations the body will reject.
   */
  static async deviceInfo(): Promise<NikonPtpDeviceInfo | null> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) {
      return null;
    }
    try {
      const response = await session.enqueue(NikonPtpIpService.OP_GET_DEVICE_INFO, [], true);
      if (response.code !== NikonPtpIpService.RESPONSE_OK) {
        NikonPtpIpService.log(`ptpip device-info response=${NikonPtpIpService.hexCode(response.code)}`);
        return null;
      }
      const parsed = NikonPtpIpService.parseDeviceInfo(response.data);
      if (parsed !== null) {
        NikonPtpIpService.log(`ptpip device-info model=${parsed.model}` +
          ` operations=${parsed.operationsSupported.length}` +
          ` properties=${parsed.devicePropertiesSupported.length}` +
          ` events=${parsed.eventsSupported.length}`);
      }
      return parsed;
    } catch (error) {
      NikonPtpIpService.logError('ptpip device-info', error as Object);
      return null;
    }
  }

  /** Whether the body advertises support for one operation code. */
  static async supportsOperation(op: number): Promise<boolean> {
    const info = await NikonPtpIpService.deviceInfo();
    return info !== null && info.operationsSupported.indexOf(op) >= 0;
  }

  private static parseDeviceInfo(data: Uint8Array): NikonPtpDeviceInfo | null {
    if (data.length < 9) {
      return null;
    }
    try {
      let offset = 0;
      const standardVersion = NikonPtpIpService.readU16(data, offset); offset += 2;
      const vendorExtensionId = NikonPtpIpService.readU32(data, offset); offset += 4;
      const mtpVersion = NikonPtpIpService.readU16(data, offset); offset += 2;
      const extensions = NikonPtpIpService.readPtpString(data, offset); offset = extensions.next;
      const functionalMode = NikonPtpIpService.readU16(data, offset); offset += 2;
      const operations = NikonPtpIpService.readU16List(data, offset); offset = operations.next;
      const events = NikonPtpIpService.readU16List(data, offset); offset = events.next;
      const properties = NikonPtpIpService.readU16List(data, offset); offset = properties.next;
      const captureFormats = NikonPtpIpService.readU16List(data, offset); offset = captureFormats.next;
      const playbackFormats = NikonPtpIpService.readU16List(data, offset); offset = playbackFormats.next;
      const manufacturer = NikonPtpIpService.readPtpString(data, offset); offset = manufacturer.next;
      const model = NikonPtpIpService.readPtpString(data, offset); offset = model.next;
      const deviceVersion = NikonPtpIpService.readPtpString(data, offset); offset = deviceVersion.next;
      const serialNumber = NikonPtpIpService.readPtpString(data, offset);
      return {
        standardVersion: standardVersion,
        vendorExtensionId: vendorExtensionId,
        mtpVersion: mtpVersion,
        functionalMode: functionalMode,
        manufacturer: manufacturer.value,
        model: model.value,
        deviceVersion: deviceVersion.value,
        serialNumber: serialNumber.value,
        operationsSupported: operations.values,
        eventsSupported: events.values,
        devicePropertiesSupported: properties.values,
        captureFormats: captureFormats.values,
        playbackFormats: playbackFormats.values,
      };
    } catch (_error) {
      return null;
    }
  }

  /** Reads a `u32 count` followed by `count` little-endian u16 values. */
  private static readU16List(data: Uint8Array, offset: number): NikonPtpU16ListRead {
    if (offset + 4 > data.length) {
      return { values: [], next: data.length };
    }
    const declared = NikonPtpIpService.readU32(data, offset);
    const start = offset + 4;
    const available = Math.floor((data.length - start) / 2);
    const count = Math.min(declared, available);
    const values: number[] = [];
    for (let index = 0; index < count; index++) {
      values.push(NikonPtpIpService.readU16(data, start + index * 2));
    }
    return { values: values, next: start + count * 2 };
  }

  /**
   * Reads the Wi-Fi credential block over PTP via `0x9532`.
   *
   * This is the exact mirror of the BLE `2004` characteristic: the response
   * data phase is the same `flag(1) + ssid(32, encrypted) + password(64,
   * encrypted) + security(1)` block, decrypted with the same session key. The
   * key must be supplied by the caller — it comes from the Bluetooth
   * provisioning that established it (`NikonBleProvisioning.takeSessionKey()`).
   * Returns null when there is no session, the body refuses, or the key cannot
   * decrypt the block.
   */
  static async readLssConnectionConfiguration(sessionKey: Uint8Array): Promise<NikonLssConnectionConfiguration | null> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed || sessionKey.length < 8) {
      return null;
    }
    try {
      const response = await session.enqueue(
        NikonPtpIpService.OP_NIKON_GET_LSS_CONNECTION_CONFIGURATION, [], true);
      if (response.code !== NikonPtpIpService.RESPONSE_OK || response.data.length === 0) {
        NikonPtpIpService.log(`ptpip lss-config response=${NikonPtpIpService.hexCode(response.code)} bytes=${response.data.length}`);
        return null;
      }
      const parsed = parseLssConnectionConfiguration(response.data,
        (encrypted: Uint8Array): Uint8Array | null => NikonLssSession.decipherWithKey(sessionKey, encrypted));
      if (parsed !== null && parsed.hasWifiSetting) {
        NikonPtpIpService.log(`ptpip lss-config ssid=${parsed.ssid} security=${parsed.security}`);
      }
      return parsed;
    } catch (error) {
      NikonPtpIpService.logError('ptpip lss-config', error as Object);
      return null;
    }
  }

  /** Runs a parameterless control operation and reports whether it succeeded.
   *
   *  Tolerant on purpose: these are `StartLiveView`/`EndLiveView`, the two
   *  operations the live-view loop fires while the body may be asleep. A silent
   *  body must make the restart report "not yet" (`false`), not poison the
   *  session — poisoning here is what used to escalate a short pause into a
   *  dropped Wi-Fi link. */
  private static async simpleControl(op: number): Promise<boolean> {
    const session = NikonPtpIpService.session;
    if (session === null || session.failed) {
      return false;
    }
    try {
      const response = await session.enqueue(op, [], false, true);
      NikonPtpIpService.log(`ptpip control op=${NikonPtpIpService.operationName(op)} code=${NikonPtpIpService.hexCode(response.code)}`);
      return response.code === NikonPtpIpService.RESPONSE_OK;
    } catch (error) {
      NikonPtpIpService.logError('ptpip control', error as Object);
      return false;
    }
  }

  /**
   * Pushes an initiator-to-responder data phase.
   *
   * Mirrors the receive path: StartData carries the transaction and the total
   * length as a u64, then each data frame carries the transaction and a slice,
   * and EndData closes the phase.
   */
  private static async sendDataPhase(session: NikonPtpSession, channel: NikonPtpIpChannel,
    transaction: number, payload: Uint8Array): Promise<void> {
    // 官方（插桩实测）的数据阶段只有两帧，没有 Data(10) 帧：
    //
    //   StartData [20 字节] = 头(8) + txid(4) + 总长度(4) + 00 00 00 00
    //   EndData   [10+N]    = 头(8) + txid(4) + **实际值 N 字节**
    //
    // 光圈 F2.8 的实例：EndData = 14,0,0,0 | 12,0,0,0 | 95,1,0,0 | 24,1
    // 其中 0x0118 = 280 = F2.8×100。我们原来把值放在 Data(10) 帧、EndData 只留
    // 事务号，机身那边等于收到一个空的收尾 → 0x201F。
    //
    // 属性值都只有 1~4 字节，一律单帧收尾；只有超大负载（当前没有调用方）才退回
    // 分片 Data 帧。
    const chunkSize = 64 * 1024;
    const singleFrame = payload.length <= chunkSize;
    const startPayload = new Uint8Array(12);
    NikonPtpIpService.writeU32(startPayload, 0, transaction);
    NikonPtpIpService.writeU32(startPayload, 4, payload.length);
    NikonPtpIpService.writeU32(startPayload, 8, 0);
    await channel.send(NikonPtpIpService.frame(NikonPtpIpService.TYPE_START_DATA, startPayload));
    if (!singleFrame) {
      let offset = 0;
      while (offset < payload.length) {
        const end = Math.min(offset + chunkSize, payload.length);
        const slice = payload.slice(offset, end);
        const dataPayload = new Uint8Array(4 + slice.length);
        NikonPtpIpService.writeU32(dataPayload, 0, transaction);
        dataPayload.set(slice, 4);
        await channel.send(NikonPtpIpService.frame(NikonPtpIpService.TYPE_DATA, dataPayload));
        offset = end;
      }
    }
    const endPayload = new Uint8Array(4 + (singleFrame ? payload.length : 0));
    NikonPtpIpService.writeU32(endPayload, 0, transaction);
    if (singleFrame && payload.length > 0) {
      endPayload.set(payload, 4);
    }
    await channel.send(NikonPtpIpService.frame(NikonPtpIpService.TYPE_END_DATA, endPayload));
    // 数据阶段的三帧也记下来：StartData 的长度字段是 u64，EndData 才是"数据到此
    // 为止"的信号——相机收不到 EndData 就会一直等，最后按事务取消回 0x201F。
    NikonPtpIpService.log(`ptpip data-out tx=${transaction} typeStart=${NikonPtpIpService.TYPE_START_DATA}` +
      ` typeData=${NikonPtpIpService.TYPE_DATA} typeEnd=${NikonPtpIpService.TYPE_END_DATA}` +
      ` totalLen=${payload.length} chunks=${payload.length === 0 ? 0 : Math.ceil(payload.length / chunkSize)}`);
  }

  private static async delay(milliseconds: number): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, milliseconds);
    });
  }

  static close(): void {
    NikonPtpIpService.epochCounter += 1;
    NikonPtpIpService.connecting = null;
    NikonPtpIpService.connectingHost = '';
    const session = NikonPtpIpService.session;
    NikonPtpIpService.session = null;
    if (session !== null) {
      session.failed = true;
      // Both teardowns are started here, but their promise is remembered rather
      // than awaited: `close()` must stay synchronous for its existing callers.
      // `release()` is the awaitable form and is what a reconnect uses, so a new
      // connection can never overlap the old one's TCP close.
      const command = session.command.closeAndWait();
      const event = session.event.closeAndWait();
      NikonPtpIpService.teardown = Promise.all([command, event])
        .then((): void => {}, (): void => {});
    }
  }

  /**
   * Tears the shared session down and resolves only once the previous TCP
   * connection is fully closed, then optionally waits `settleMs` longer for the
   * camera to release the PTP session that connection carried.
   *
   * This is the fix for the reconnect race: the camera holds its session until
   * it sees the old connection disappear, so dialling a new one while that close
   * is still in flight is what produced a non-`InitCommandAck` first frame and
   * `SessionAlreadyOpen` (0x201E) on the vendor session open.
   */
  static async release(settleMs: number = 0): Promise<void> {
    const hadSession = NikonPtpIpService.session !== null;
    NikonPtpIpService.close();
    const closing = NikonPtpIpService.teardown;
    if (closing !== null) {
      try {
        await closing;
      } catch (_error) {
        // The stored teardown already swallows platform close failures; this is
        // belt and braces so a reconnect can never be blocked by one.
      }
    }
    // Only a session that actually existed can leave one open on the camera, so
    // the very first connection of a run does not pay the release window.
    if (settleMs > 0 && hadSession) {
      await NikonPtpIpService.delay(settleMs);
    }
  }

  /**
   * Graceful teardown: send `CloseSession` (0x1003) **before** dropping the TCP
   * connections, then fall back to `release()`.
   *
   * `close()` alone just marks the session failed and closes both sockets. The
   * body reacts badly to that: it treats an abruptly vanished PTP/IP link as a
   * broken connection and **ends the camera's "connect to smart device" mode,
   * taking the access point down with it**. The visible symptom is the one
   * reported on hardware: control page → transfer page → control page again,
   * and the phone's Wi-Fi to the camera is gone.
   *
   * `0x1003` was defined but never actually sent (it only appeared in the
   * opcode-name table), so every teardown until now was the abrupt kind.
   *
   * The close opcode is best-effort: if the body has already stopped answering,
   * the transaction times out and we still tear the sockets down, because
   * leaving them open is worse.
   */
  static async closeGracefully(settleMs: number = 0): Promise<void> {
    const session = NikonPtpIpService.session;
    if (session !== null && !session.failed) {
      try {
        const response = await session.enqueue(NikonPtpIpService.OP_CLOSE_SESSION, [], false);
        NikonPtpIpService.log(`ptpip CloseSession result=${NikonPtpIpService.hexCode(response.code)}`);
      } catch (error) {
        // Already gone, or it refused: the sockets still have to go.
        NikonPtpIpService.log(`ptpip CloseSession failed: ${String(error)}`);
      }
    }
    await NikonPtpIpService.release(settleMs);
  }

  /** Single-flight connect: concurrent callers for the same host AND the same
   * session-open operation share one handshake; a different host or a different
   * session-open opcode invalidates the old epoch first, and an in-flight
   * handshake that was superseded cleans up its own channels and never
   * publishes. */
  private static async ensureSession(host: string,
    openOpcode: number = NikonPtpIpService.OP_OPEN_SESSION,
    openParams: number[] = [NikonPtpIpService.SESSION_ID],
    allowStandardFallback: boolean = true,
    attempts: number = 0): Promise<NikonPtpSession> {
    const existing = NikonPtpIpService.session;
    if (existing !== null && !existing.failed && existing.host === host &&
      existing.openOpcode === openOpcode) {
      return existing;
    }
    const pending = NikonPtpIpService.connecting;
    if (pending !== null && NikonPtpIpService.connectingHost === host &&
      NikonPtpIpService.connectingOpcode === openOpcode) {
      return pending;
    }
    // A session opened by a DIFFERENT operation must be gone before the new
    // connection exists. The function mode is a property of the session the
    // camera opened, so a live 0x1002 session cannot be upgraded into the vendor
    // one: the camera answers the new open with SessionAlreadyOpen while it
    // still holds the old session. The teardown is therefore awaited, and a
    // retried/vendor open additionally waits out the short camera-side release
    // window.
    //
    // The release and the epoch capture stay in this synchronous block on
    // purpose: `release` runs its `close()` (and its epoch bump) before its
    // first await, and the connect promise below is published to `connecting`
    // without awaiting anything, so a second caller can never slip into the
    // window and start a competing dial — the single-flight lock keeps exactly
    // the atomicity it had when `close()` was called inline here.
    const vendorOpen = openOpcode !== NikonPtpIpService.OP_OPEN_SESSION;
    const retried = attempts > 1 || (attempts <= 0 && vendorOpen);
    const releasePromise = NikonPtpIpService.release(
      retried ? NikonPtpIpService.VENDOR_OPEN_SETTLE_MS : 0);
    const epoch = NikonPtpIpService.epochCounter;
    const connectPromise: Promise<NikonPtpSession> = releasePromise.then(
      async (): Promise<NikonPtpSession> => {
        return await NikonPtpIpService.openSession(host, epoch, openOpcode, openParams,
          allowStandardFallback, attempts);
      });
    NikonPtpIpService.connecting = connectPromise;
    NikonPtpIpService.connectingHost = host;
    NikonPtpIpService.connectingOpcode = openOpcode;
    try {
      return await connectPromise;
    } finally {
      if (NikonPtpIpService.connecting === connectPromise) {
        NikonPtpIpService.connecting = null;
        NikonPtpIpService.connectingHost = '';
        NikonPtpIpService.connectingOpcode = 0;
      }
    }
  }

  /**
   * Opens a session, retrying the session open on a FRESH connection when the
   * camera was not ready to hand the previous one over.
   *
   * The session-open operation is `openOpcode`/`openParams`, which default to
   * `OpenSession` (0x1002) `[1]` — the sequence the Nikon paths have always
   * used, with one attempt and no fallback, exactly as before. A caller may ask
   * for a vendor alternative (Sony's `SDIO_OpenSession` 0x9210
   * `[1, functionMode]`), which is retried `VENDOR_OPEN_ATTEMPTS` times by
   * default.
   *
   * A retry is always a new connection, never a second open on the same session:
   * the operation is what establishes the session's mode, and a camera that
   * still holds the previous session refuses the new open. Each failed attempt
   * has already awaited its own TCP teardown (`openSessionAttempt`) and the
   * retry waits out the camera-side release window before dialling.
   *
   * After the last attempt, a vendor open falls back to the standard one when
   * `allowStandardFallback` is true (the historical behaviour, so a camera that
   * does not implement the vendor open is never worse off); a caller that must
   * not be handed a differently-moded session passes false and gets a distinct
   * error instead of a session it would mistake for the requested mode.
   * `session.openOpcode` always records the operation that really established
   * the session, whichever branch won.
   */
  private static async openSession(host: string, epoch: number, openOpcode: number,
    openParams: number[], allowStandardFallback: boolean, attempts: number): Promise<NikonPtpSession> {
    const vendorOpen = openOpcode !== NikonPtpIpService.OP_OPEN_SESSION;
    const tries = attempts > 0
      ? attempts
      : (vendorOpen ? NikonPtpIpService.VENDOR_OPEN_ATTEMPTS : 1);
    NikonPtpIpService.sessionOpenAttempts = 0;
    let lastError: Error | null = null;
    for (let attempt = 1; attempt <= tries; attempt++) {
      if (epoch !== NikonPtpIpService.epochCounter) {
        throw new Error('PTP/IP connect was superseded before it started');
      }
      NikonPtpIpService.sessionOpenAttempts = attempt;
      try {
        return await NikonPtpIpService.openSessionAttempt(host, epoch, openOpcode, openParams);
      } catch (error) {
        const typed = error as Error;
        // A single-attempt open is every Nikon path: its handshake error
        // propagates exactly as it did before, with no extra log line.
        if (tries === 1) throw typed;
        // A retried open must not continue across a superseded epoch: that
        // connection belongs to a newer caller now.
        if (epoch !== NikonPtpIpService.epochCounter) throw typed;
        lastError = typed;
        NikonPtpIpService.log(`ptpip session open attempt=${attempt}/${tries}` +
          ` op=${NikonPtpIpService.hexCode(openOpcode)}` +
          ` params=[${openParams.join(',')}] error=${typed.message}`);
      }
      if (attempt < tries) {
        const settle = NikonPtpIpService.VENDOR_OPEN_SETTLE_MS * attempt;
        NikonPtpIpService.log(`ptpip session open retry-in=${settle}ms` +
          ` reason=camera-session-not-released`);
        await NikonPtpIpService.delay(settle);
      }
    }
    if (!vendorOpen) {
      throw lastError !== null ? lastError : new Error('PTP/IP session open failed');
    }
    if (!allowStandardFallback) {
      // Distinct and terminal: the caller asked for the vendor session and must
      // not be handed a standard one it would take for the requested mode.
      throw new Error('PTP/IP vendor session open unavailable' +
        ` op=${NikonPtpIpService.hexCode(openOpcode)}` +
        ` attempts=${tries}` +
        ` last=${lastError === null ? 'none' : lastError.message}`);
    }
    NikonPtpIpService.log(`ptpip vendor session open unavailable after ${tries} attempt(s)` +
      ` op=${NikonPtpIpService.hexCode(openOpcode)}` +
      ` last=${lastError === null ? 'none' : lastError.message}` +
      ` falling back to op=${NikonPtpIpService.hexCode(NikonPtpIpService.OP_OPEN_SESSION)}` +
      ` (session.openOpcode will record 0x1002)`);
    return await NikonPtpIpService.openSessionAttempt(host, epoch,
      NikonPtpIpService.OP_OPEN_SESSION, [NikonPtpIpService.SESSION_ID]);
  }

  /** One connection attempt: both channels and the frozen handshake, opened with
   * exactly the operation it is given. Every resource is local until that
   * operation succeeded AND the epoch is still current; only then is the session
   * published. The failure path closes its own channels and AWAITS that teardown
   * before rethrowing, because the retry loop above dials again immediately
   * afterwards. */
  private static async openSessionAttempt(host: string, epoch: number, openOpcode: number,
    openParams: number[]): Promise<NikonPtpSession> {
    const command = new NikonPtpIpChannel();
    const event = new NikonPtpIpChannel();
    try {
      if (epoch !== NikonPtpIpService.epochCounter) {
        throw new Error('PTP/IP connect was superseded before it started');
      }
      NikonPtpIpService.log(`ptpip tcp command connect host=${NikonPtpIpService.redactHost(host)} port=${NikonPtpIpService.PORT}`);
      await command.connect(host, NikonPtpIpService.PORT);
      const guid = NikonPtpIpService.newGuid();
      const init = NikonPtpIpService.initCommand(guid, 'Pixelshop Camera');
      await command.send(init);
      // The first frame is validated, never consumed blindly as the ack: a
      // camera that has not released the previous initiator session answers with
      // a different frame, and treating that as the ack used to surface as a
      // bare "InitCommandAck missing" (or worse, as a connection number that
      // came from nowhere).
      const ack = await NikonPtpIpService.awaitControlFrame(command,
        NikonPtpIpService.TYPE_INIT_ACK, 'InitCommandAck');
      if (ack.payload.length < 4) {
        throw new Error(`PTP/IP InitCommandAck missing (payload=${ack.payload.length})`);
      }
      const connectionNumber = NikonPtpIpService.readU32(ack.payload, 0);
      NikonPtpIpService.log(`ptpip tcp event connect host=${NikonPtpIpService.redactHost(host)} port=${NikonPtpIpService.PORT}`);
      await event.connect(host, NikonPtpIpService.PORT);
      await event.send(NikonPtpIpService.frame(NikonPtpIpService.TYPE_INIT_EVENT, NikonPtpIpService.u32(connectionNumber)));
      await NikonPtpIpService.awaitControlFrame(event,
        NikonPtpIpService.TYPE_INIT_EVENT_ACK, 'InitEventAck');
      const session = new NikonPtpSession(command, event, host, connectionNumber, epoch);
      // The session-open runs directly on the not-yet-published local session so
      // the command queue and the single-flight lock can never re-enter. The
      // transaction number is 0 for every branch, exactly as before.
      const opened = await NikonPtpIpService.executeTransaction(
        session, openOpcode, openParams, false, 0);
      if (opened.code !== NikonPtpIpService.RESPONSE_OK) {
        const named = opened.code === NikonPtpIpService.RESPONSE_SESSION_ALREADY_OPEN
          ? ' (SessionAlreadyOpen)' : '';
        throw new Error(`PTP/IP OpenSession response 0x${opened.code.toString(16)}${named}` +
          ` op=${NikonPtpIpService.hexCode(openOpcode)} params=[${openParams.join(',')}]`);
      }
      session.openOpcode = openOpcode;
      session.openCode = opened.code;
      NikonPtpIpService.log(`ptpip session open op=${NikonPtpIpService.hexCode(openOpcode)}` +
        ` params=${openParams.join(',')} code=${NikonPtpIpService.hexCode(opened.code)}`);
      if (epoch !== NikonPtpIpService.epochCounter) {
        throw new Error('PTP/IP connect was superseded during handshake');
      }
      NikonPtpIpService.session = session;
      // 真实的 PTP/IP 会话优先。它一建立就摘掉可能残留的 USB 外部传输，否则用户
      // 从索尼 USB 切到尼康/松下 Wi‑Fi 之后，控制类操作还会往那台（可能已拔线的）
      // 索尼通道上发，`isControlReady()` 也会给出一个假的 true。
      NikonPtpIpService.externalTransport = null;
      NikonPtpIpService.startEventLoop(session);
      NikonPtpIpService.log(`session established host=${NikonPtpIpService.redactHost(host)} connection=${connectionNumber} epoch=${epoch} open=${NikonPtpIpService.hexCode(openOpcode)}`);
      return session;
    } catch (error) {
      // Only the channels created by THIS attempt are cleaned up here; a newer
      // attempt owns its own sockets. The teardown is awaited so the next
      // attempt (or the next caller) cannot dial while this connection is still
      // closing.
      const typed = error as Error;
      await command.closeAndWait();
      await event.closeAndWait();
      throw typed;
    }
  }

  /**
   * Reads one control frame of `expectedType` from a handshake channel.
   *
   * The first frame read is NOT blindly accepted as the ack: a camera that has
   * not released the previous PTP/IP session can answer the new `InitCommand`
   * with a different frame, and consuming it as the ack both loses the real ack
   * and hides why the handshake failed. One unexpected frame is therefore
   * tolerated and logged — with a short window, so a camera that refuses the
   * initiator outright fails fast instead of waiting a full transaction timeout
   * per unexpected frame — and anything after that is a stale-connection error
   * the caller's retry loop can act on. Existing callers keep the original
   * timeout on the first frame and the original message prefix
   * (`PTP/IP InitCommandAck missing`), with the offending frame type appended
   * when an unexpected frame is what arrived.
   */
  private static async awaitControlFrame(channel: NikonPtpIpChannel, expectedType: number,
    label: string): Promise<NikonPtpPacket> {
    let first: NikonPtpPacket | null = null;
    for (let index = 0; index <= NikonPtpIpService.INIT_SKIP_FRAMES; index++) {
      let packet: NikonPtpPacket | null = null;
      try {
        if (index === 0) {
          packet = await channel.next();
        } else {
          packet = await channel.next(NikonPtpIpService.INIT_SKIP_TIMEOUT_MS);
        }
      } catch (error) {
        const typed = error as Error;
        if (first === null) throw typed;
        // The tolerated frame was a spurious one and no ack followed it: the
        // wait ends here instead of at the next full timeout.
        break;
      }
      if (packet === null) break;
      if (packet.type === expectedType) {
        if (index > 0) {
          NikonPtpIpService.log(`ptpip ${label} accepted after ${index} unexpected frame(s)`);
        }
        return packet;
      }
      if (first === null) first = packet;
      NikonPtpIpService.log(`ptpip ${label} unexpected frame type=${packet.type}` +
        ` payload=${packet.payload.length} index=${index}`);
    }
    throw new Error(`PTP/IP ${label} missing (stale connection: first frame type=${first === null ? -1 : first.type})`);
  }

  /** One full command transaction: request -> optional data phase -> final
   * response, with transaction-number and length validation on every frame.
   * Public for NikonPtpSession.enqueue only; callers must go through the
   * session queue (the handshake is the one direct caller). */
  static async executeTransaction(session: NikonPtpSession, op: number, params: number[],
    expectsData: boolean, transactionOverride: number,
    tolerateTimeout: boolean = false): Promise<NikonPtpResponse> {
    const channel = session.command;
    if (session.failed) throw new Error('PTP/IP session is unavailable');
    if (channel.isClosed()) {
      throw NikonPtpIpService.poisonSession(session, new Error('PTP/IP command channel is closed'));
    }
    const transaction = transactionOverride >= 0 ? transactionOverride : session.nextTransactionId();
    NikonPtpIpService.log(`ptpip request op=${NikonPtpIpService.operationName(op)} tx=${transaction} data=${expectsData ? 1 : 0} params=${params.join(',')}`);
    try {
      await channel.send(NikonPtpIpService.operationRequest(op, transaction, params));
    } catch (error) {
      const typed = error as Error;
      NikonPtpIpService.poisonSession(session, typed);
      throw typed;
    }
    let packet = await NikonPtpIpService.receivePacket(session, channel, transaction, tolerateTimeout);
    let data = new Uint8Array(0);
    if (packet.type === NikonPtpIpService.TYPE_START_DATA) {
      if (!expectsData) {
        throw NikonPtpIpService.poisonSession(session,
          new Error(`PTP/IP unexpected data phase op=${NikonPtpIpService.operationName(op)}`));
      }
      const phase = await NikonPtpIpService.receiveDataPhase(session, channel, transaction, packet,
        tolerateTimeout);
      data = phase.data;
      if (phase.earlyResponse !== null) {
        packet = phase.earlyResponse;
      } else {
        packet = await NikonPtpIpService.receivePacket(session, channel, transaction, tolerateTimeout);
      }
    }
    if (packet.type !== NikonPtpIpService.TYPE_OPERATION_RESPONSE || packet.payload.length < 6) {
      throw NikonPtpIpService.poisonSession(session,
        new Error(`PTP/IP operation response missing op=${NikonPtpIpService.operationName(op)}`));
    }
    const code = NikonPtpIpService.readU16(packet.payload, 0);
    const responseTransaction = NikonPtpIpService.readU32(packet.payload, 2);
    if (responseTransaction !== transaction) {
      throw NikonPtpIpService.poisonSession(session,
        new Error(`PTP/IP response transaction mismatch op=${NikonPtpIpService.operationName(op)} expected=${transaction} received=${responseTransaction}`));
    }
    const paramsOut: number[] = [];
    for (let offset = 6; offset + 4 <= packet.payload.length; offset += 4) {
      paramsOut.push(NikonPtpIpService.readU32(packet.payload, offset));
    }
    NikonPtpIpService.log(`ptpip response op=${NikonPtpIpService.operationName(op)} tx=${responseTransaction} code=${NikonPtpIpService.hexCode(code)} bytes=${data.length}`);
    return { code: code, transaction: responseTransaction, params: paramsOut, data: data };
  }

  /**
   * One full command transaction whose data phase flows phone -> camera.
   *
   * The mirror image of `executeTransaction` above, and the only shape Sony's
   * `SDIO_ControlDevice` (0x9207) needs. The wire encoding is transcribed from
   * Sony's own PTP/IP transaction executor,
   * `ptpip/ptpip/base/transaction/TransactionExecutor.java:133-139`:
   *
   *   if (bArr.length == 0) {
   *       send(new OperationRequestPacket(NoDataOrDataInPhase, op, tx, params));
   *   } else {
   *       send(new OperationRequestPacket(DataOutPhase, op, tx, params));
   *       send(new StartDataPacket(tx, bArr.length));
   *       send(new EndDataPacket(tx, bArr));
   *   }
   *
   * So `RequestOneShooting` (53959), whose payload is `new byte[0]`
   * (`EnumControlCode.java:91-93`), goes out as a bare operation request with
   * DataPhaseInfo 1 and no data frames; `SetLiveViewEnable` (54035), whose
   * payload is a 2-byte little-endian short (`:98-101` via `case 37` at `:83`),
   * goes out with DataPhaseInfo 2.
   *
   * After the data phase the responder's OperationResponse is awaited and
   * validated exactly as in `executeTransaction`, so a poisoned session is
   * reported the same way on both paths.
   *
   * Public for `NikonPtpSession.enqueueDataOut`, the same visibility rule
   * `executeTransaction` follows.
   */
  static async executeTransactionDataOut(session: NikonPtpSession, op: number,
    params: number[], payload: Uint8Array, transactionOverride: number): Promise<NikonPtpResponse> {
    const channel = session.command;
    if (session.failed) throw new Error('PTP/IP session is unavailable');
    if (channel.isClosed()) {
      throw NikonPtpIpService.poisonSession(session, new Error('PTP/IP command channel is closed'));
    }
    const transaction = transactionOverride >= 0 ? transactionOverride : session.nextTransactionId();
    // PTP/IP 的 `DataPhaseInfo` 在**尼康的实现里不是 CIPA 那套编号**。
    //
    // 2026-10-18 用插桩过的官方 SnapBridge 2.13.3 + Z 8 抓到真实字节：
    //   读属性 0x1014 / 0x1015 → dataPhase = 1
    //   写属性 0x1016         → dataPhase = **2**，不是 3
    // 三笔实测写入（快门 0xD100、光圈 0x5007、曝光补偿 0x5010）全部是 2，
    // 相机都回 0x2001，界面数值随之改变；我们发 3 时相机一律回 0x201F
    // （TRANSACTION_CANCELLED）——这就是"所有参数都被拒"的根因。
    const dataPhase = payload.length === 0 ? 1 : 2;
    // **把真正发到线上的东西打出来。**
    //
    // 参数写入这条路已经改过好几轮（数据阶段、队列化、编码宽度），每次都靠推断，
    // 而每次推断都被下一次真机日志否掉。所以现在不再推断：把 `DataPhaseInfo`、
    // 操作码、事务号、参数、数据阶段长度和**逐字节的负载**全部记下来，让线上字节
    // 自己说话。负载都很小（属性值 1~4 字节），打印它们不影响性能。
    let payloadHex = '';
    for (let index = 0; index < payload.length; index++) {
      payloadHex += (payload[index] < 16 ? '0' : '') + payload[index].toString(16);
    }
    NikonPtpIpService.log(`ptpip request op=${NikonPtpIpService.operationName(op)} tx=${transaction}` +
      ` dataPhase=${dataPhase} params=[${params.join(',')}]` +
      ` payloadLen=${payload.length} payload=${payloadHex}`);
    try {
      await channel.send(NikonPtpIpService.operationRequest(op, transaction, params, dataPhase));
      if (payload.length > 0) {
        await NikonPtpIpService.sendDataPhase(session, channel, transaction, payload);
      }
    } catch (error) {
      const typed = error as Error;
      NikonPtpIpService.poisonSession(session, typed);
      throw typed;
    }
    const packet = await NikonPtpIpService.receivePacket(session, channel, transaction, false);
    if (packet.type !== NikonPtpIpService.TYPE_OPERATION_RESPONSE || packet.payload.length < 6) {
      throw NikonPtpIpService.poisonSession(session,
        new Error(`PTP/IP operation response missing op=${NikonPtpIpService.operationName(op)}`));
    }
    const code = NikonPtpIpService.readU16(packet.payload, 0);
    const responseTransaction = NikonPtpIpService.readU32(packet.payload, 2);
    if (responseTransaction !== transaction) {
      throw NikonPtpIpService.poisonSession(session,
        new Error(`PTP/IP response transaction mismatch op=${NikonPtpIpService.operationName(op)}` +
          ` expected=${transaction} received=${responseTransaction}`));
    }
    const paramsOut: number[] = [];
    for (let offset = 6; offset + 4 <= packet.payload.length; offset += 4) {
      paramsOut.push(NikonPtpIpService.readU32(packet.payload, offset));
    }
    NikonPtpIpService.log(`ptpip response op=${NikonPtpIpService.operationName(op)}` +
      ` tx=${responseTransaction} code=${NikonPtpIpService.hexCode(code)}` +
      ` paramsOut=[${paramsOut.join(',')}]`);
    return { code: code, transaction: responseTransaction, params: paramsOut, data: new Uint8Array(0) };
  }

  /** How many frames belonging to an already-timed-out transaction we are
   * willing to drop before deciding the stream itself is unusable.
   *
   *  A body that wakes up mid-transaction answers the request it was sitting on,
   *  and one live-view frame can itself be split over several `Data` frames, so
   *  the burst after a stall is a handful of frames, not one. 256 is far above
   *  any plausible burst while still bounding a genuinely desynchronised line. */
  private static readonly STALE_FRAME_SKIP_LIMIT = 256;

  /** Transaction number carried by a frame, or -1 when the frame type has none.
   *  Every PTP/IP packet that belongs to a transaction carries it at a fixed
   *  offset; `Event` (8) does not, and never arrives on the command channel. */
  private static packetTransaction(packet: NikonPtpPacket): number {
    const payload = packet.payload;
    if (packet.type === NikonPtpIpService.TYPE_OPERATION_RESPONSE) {
      return payload.length >= 6 ? NikonPtpIpService.readU32(payload, 2) : -1;
    }
    if (packet.type === NikonPtpIpService.TYPE_START_DATA
      || packet.type === NikonPtpIpService.TYPE_DATA
      || packet.type === NikonPtpIpService.TYPE_END_DATA
      || packet.type === NikonPtpIpService.TYPE_END_DATA_LEGACY) {
      return payload.length >= 4 ? NikonPtpIpService.readU32(payload, 0) : -1;
    }
    return -1;
  }

  /** Read one packet of transaction `transaction`.
   *
   *  Two things keep a sleeping body from costing us the connection:
   *
   *  1. **A timeout only poisons when the caller did not ask to tolerate it.**
   *     Live view does tolerate it: the camera pausing its command processing is
   *     not a broken line, and the old behaviour — poison + close both sockets —
   *     is exactly what made the Wi-Fi drop and the page die. A tolerated
   *     timeout is re-thrown as `NikonPtpTimeout` so the caller can turn it into
   *     "no frame this time".
   *  2. **A frame whose transaction number is not ours is dropped, not fatal.**
   *     After a tolerated timeout the body still owes us that transaction's
   *     reply, and it will deliver it late. Validating the number and skipping
   *     is what keeps the stream usable; the previous code poisoned the session
   *     on the first mismatch, which turned one late frame into a dead session.
   *     The skip count is bounded so a truly desynchronised line still fails. */
  private static async receivePacket(session: NikonPtpSession, channel: NikonPtpIpChannel,
    transaction: number = -1, tolerateTimeout: boolean = false): Promise<NikonPtpPacket> {
    let skipped = 0;
    while (true) {
      let packet: NikonPtpPacket;
      try {
        packet = await channel.next(NikonPtpIpService.TRANSACTION_TIMEOUT_MS);
      } catch (error) {
        const typed = error as Error;
        if (NikonPtpTimeout.is(typed)) {
          if (tolerateTimeout) {
            NikonPtpIpService.log('ptpip read timeout tolerated (session kept alive)');
            throw typed;
          }
          throw NikonPtpIpService.poisonSession(session, new Error('PTP/IP transaction timeout'));
        }
        NikonPtpIpService.poisonSession(session, typed);
        throw typed;
      }
      if (transaction >= 0) {
        const arrived = NikonPtpIpService.packetTransaction(packet);
        if (arrived >= 0 && arrived !== transaction) {
          skipped += 1;
          if (skipped <= 4 || skipped % 32 === 0) {
            NikonPtpIpService.log(`ptpip stale frame dropped type=${packet.type}` +
              ` tx=${arrived} expected=${transaction} skipped=${skipped}`);
          }
          if (skipped > NikonPtpIpService.STALE_FRAME_SKIP_LIMIT) {
            throw NikonPtpIpService.poisonSession(session,
              new Error(`PTP/IP too many stale frames expected=${transaction} skipped=${skipped}`));
          }
          continue;
        }
      }
      return packet;
    }
  }

  /**
   * Strict data phase: consume frames until EndData, validating the
   * transaction number on every frame and the declared total length. The
   * previous parser broke out as soon as received >= expected and mistook the
   * empty EndData for the final response. A complete non-OK response arriving
   * inside the data phase is returned as a business rejection (the stream
   * stays clean); an OK response without EndData is a protocol violation and
   * poisons the session.
   */
  private static async receiveDataPhase(session: NikonPtpSession, channel: NikonPtpIpChannel,
    transaction: number, start: NikonPtpPacket,
    tolerateTimeout: boolean = false): Promise<NikonPtpDataPhaseResult> {
    if (start.payload.length < 12) {
      throw NikonPtpIpService.poisonSession(session, new Error('PTP/IP StartData payload too short'));
    }
    const startTransaction = NikonPtpIpService.readU32(start.payload, 0);
    if (startTransaction !== transaction) {
      throw NikonPtpIpService.poisonSession(session,
        new Error(`PTP/IP StartData transaction mismatch expected=${transaction} received=${startTransaction}`));
    }
    let expected = 0;
    try {
      expected = NikonPtpIpService.readU64Checked(start.payload, 4);
    } catch (error) {
      throw NikonPtpIpService.poisonSession(session, error as Error);
    }
    const chunks: Uint8Array[] = [];
    let received = 0;
    if (start.payload.length > 12) {
      // Some stacks append the first payload bytes to StartData itself. This
      // is not assumed by the normal path; the bytes are kept and the
      // anomaly is logged for offline review.
      const inline = start.payload.slice(12);
      NikonPtpIpService.log(`ptpip start-data inline bytes=${inline.length}`);
      chunks.push(inline);
      received += inline.length;
    }
    while (true) {
      const packet = await NikonPtpIpService.receivePacket(session, channel, transaction, tolerateTimeout);
      if (packet.type !== NikonPtpIpService.TYPE_DATA
        && packet.type !== NikonPtpIpService.TYPE_END_DATA
        && packet.type !== NikonPtpIpService.TYPE_END_DATA_LEGACY) {
        if (packet.type === NikonPtpIpService.TYPE_OPERATION_RESPONSE && packet.payload.length >= 6) {
          const earlyCode = NikonPtpIpService.readU16(packet.payload, 0);
          const earlyTransaction = NikonPtpIpService.readU32(packet.payload, 2);
          if (earlyTransaction !== transaction) {
            throw NikonPtpIpService.poisonSession(session,
              new Error(`PTP/IP response transaction mismatch in data phase expected=${transaction} received=${earlyTransaction}`));
          }
          if (earlyCode === NikonPtpIpService.RESPONSE_OK) {
            throw NikonPtpIpService.poisonSession(session, new Error('PTP/IP data phase ended without EndData'));
          }
          return { data: new Uint8Array(0), earlyResponse: packet };
        }
        throw NikonPtpIpService.poisonSession(session,
          new Error(`PTP/IP data phase packet missing got type=${packet.type}`));
      }
      if (packet.payload.length < 4) {
        throw NikonPtpIpService.poisonSession(session, new Error('PTP/IP data payload too short'));
      }
      const dataTransaction = NikonPtpIpService.readU32(packet.payload, 0);
      if (dataTransaction !== transaction) {
        throw NikonPtpIpService.poisonSession(session,
          new Error(`PTP/IP data transaction mismatch expected=${transaction} received=${dataTransaction}`));
      }
      const chunk = packet.payload.slice(4);
      if (chunk.length > 0) {
        chunks.push(chunk);
        received += chunk.length;
      }
      if (expected > 0 && received > expected) {
        throw NikonPtpIpService.poisonSession(session,
          new Error(`PTP/IP data overflow expected=${expected} received=${received}`));
      }
      // 收得宽松：标准的 11 和相机实测在用的 12 都当作数据阶段结束。
      //
      // 发送端已经改成只用 11（12 是 Ping，发出去相机永远等不到结束，写属性会被
      // 回 0x201F）。接收端如果跟着一起收紧，读路径会立刻坏掉——因为相机收尾用的
      // 就是 12。所以这里两个都认。
      if (packet.type === NikonPtpIpService.TYPE_END_DATA
        || packet.type === NikonPtpIpService.TYPE_END_DATA_LEGACY) {
        if (expected > 0 && received !== expected) {
          throw NikonPtpIpService.poisonSession(session,
            new Error(`PTP/IP data length mismatch expected=${expected} received=${received}`));
        }
        return { data: NikonPtpIpService.concat(chunks, received), earlyResponse: null };
      }
    }
  }

  /** Mark a session unusable **without touching the sockets**. Idempotent; the
   * epoch bump makes in-flight UI tasks drop their results.
   *
   * The sockets deliberately stay open. A body treats an abruptly vanished
   * PTP/IP link as a broken connection and ends its "connect to smart device"
   * mode, taking the access point — and the phone's Wi-Fi to it — down with it.
   * `closeGracefully` documents the same reaction for the user-initiated
   * teardown; poisoning used to do the abrupt version on every timeout, which
   * is why a sleeping camera ended as "Wi-Fi 断了" instead of a short freeze.
   *
   * Recovery is explicit: `recoverSession()` reopens the session (the camera's
   * own session is released when the old socket is closed there, in order, by
   * `release`), so nothing here has to tear the link down as a side effect. */
  private static poisonSession(session: NikonPtpSession, error: Error): Error {
    if (!session.failed) {
      session.failed = true;
      NikonPtpIpService.logError('ptpip session poisoned', error as Object);
    }
    NikonPtpIpService.epochCounter += 1;
    return error;
  }

  /** In-flight recovery, so concurrent callers share one reopen. */
  private static recovery: Promise<void> | null = null;
  /** 两次重连之间的最小间隔。 */
  private static readonly RECOVERY_SETTLE_MS = 400;

  /** True while a background reopen is running (the UI can show "恢复中" instead
   * of an error, which is what the official app's silence amounts to). */
  static isRecovering(): boolean {
    return NikonPtpIpService.recovery !== null;
  }

  /**
   * Reopens the session after it was poisoned, **once**, and reports whether it
   * is usable again. The live-view state is not touched here: the page keeps its
   * loop and its last frame, and the next frame of the new session simply
   * arrives.
   *
   * Returns true immediately when the session is still fine, so a caller may
   * call it unconditionally.
   */
  static async recoverSession(): Promise<boolean> {
    const session = NikonPtpIpService.session;
    if (session === null) return false;
    if (!session.failed) return true;
    const running = NikonPtpIpService.recovery;
    if (running !== null) {
      await running;
      return NikonPtpIpService.isSessionAlive();
    }
    const host = session.host;
    const openOpcode = session.openOpcode > 0 ? session.openOpcode : NikonPtpIpService.OP_OPEN_SESSION;
    const redacted = NikonPtpIpService.redactHost(host);
    const task: Promise<void> = (async (): Promise<void> => {
      NikonPtpIpService.log(`ptpip recovery start host=${redacted}`);
      await NikonPtpIpService.delay(NikonPtpIpService.RECOVERY_SETTLE_MS);
      try {
        await NikonPtpIpService.acquireSession(host, openOpcode, [NikonPtpIpService.SESSION_ID], true, 1);
        NikonPtpIpService.log(`ptpip recovery ok host=${redacted}`);
      } catch (error) {
        NikonPtpIpService.logError('ptpip recovery failed', error as Object);
      }
    })();
    const settled = task.then((): void => {}, (): void => {});
    NikonPtpIpService.recovery = settled;
    await settled;
    if (NikonPtpIpService.recovery === settled) {
      NikonPtpIpService.recovery = null;
    }
    return NikonPtpIpService.isSessionAlive();
  }

  /** Passive event consumption: one loop per session drains event frames so
   * the channel buffer stays bounded. Long silent periods are normal idle,
   * not a dead line; only a real channel failure ends the loop. */
  private static startEventLoop(session: NikonPtpSession): void {
    const event = session.event;
    const loop = async (): Promise<void> => {
      while (!event.isClosed() && !session.failed) {
        try {
          const packet = await event.next(NikonPtpIpService.EVENT_IDLE_TIMEOUT_MS);
          NikonPtpIpService.handleEventPacket(packet);
        } catch (error) {
          const typed = error as Error;
          if (NikonPtpTimeout.is(typed)) continue;
          if (event.isClosed() || session.failed) return;
          // An event-channel failure alone does not poison the command
          // session; transfer operations remain usable.
          NikonPtpIpService.logError('ptpip event loop', error as Object);
          return;
        }
      }
    };
    void loop();
  }

  private static handleEventPacket(packet: NikonPtpPacket): void {
    const payload = packet.payload;
    if (payload.length < 2) {
      NikonPtpIpService.log(`ptpip event frame type=${packet.type} bytes=${payload.length}`);
      return;
    }
    const code = NikonPtpIpService.readU16(payload, 0);
    const params: number[] = [];
    for (let offset = 2; offset + 4 <= payload.length; offset += 4) {
      params.push(NikonPtpIpService.readU32(payload, offset));
    }
    NikonPtpIpService.log(`ptpip event ${NikonPtpIpService.eventName(code)} ` +
      `code=${NikonPtpIpService.hexCode(code)} params=[${params.join(',')}]`);
    if (code === NikonPtpIpService.EVENT_CAPTURE_COMPLETE) {
      // The payload carries the transaction id of the capture that finished, so
      // this is the body's own confirmation that the shutter cycle is over —
      // independent of, and a useful cross-check on, the readiness poll.
      NikonPtpIpService.lastCaptureCompleteAt = Date.now();
      return;
    }
    if (code === NikonPtpIpService.EVENT_MOVIE_REC_COMPLETE
      || code === NikonPtpIpService.EVENT_MOVIE_REC_INTERRUPTED) {
      // 机身自己收尾了（卡满 / 过热 / 机身按键 / 待机）。记下时刻，控制页据此把
      // "录制中"收回，不必等一条永远不会来的 0x920B 应答。
      NikonPtpIpService.lastMovieStopAt = Date.now();
      return;
    }
    if (code === NikonPtpIpService.EVENT_DEVICE_PROP_CHANGED) {
      // `params[0]` is 0xFFFFFFFF and `params[1]` is the property code that moved
      // (`20487` = 0x5007 aperture, seen on hardware).
      //
      // **只登记，不立刻回读。** 机身一旦挂起取景流就不再处理命令（写参数被回
      // 0x201F、EV 直接超时，都是这么来的），这时候发一条 0x1014 只会超时、把
      // 会话毒化、连带把 Wi-Fi 一起拖掉——比不刷新糟得多。
      //
      // 所以只把代码记进待刷新集合，由控制页在**下一次主动复流、流已经停掉**的
      // 窗口里统一读回来。机身主动上报 + 在安全窗口回读，两边都不违反协议约束。
      if (params.length >= 2 && params[1] !== 0xFFFFFFFF) {
        NikonPtpIpService.pendingPropChanges.add(params[1]);
      }
    }
  }

  /** 相机上报过变化、但还没回读的属性码。 */
  private static pendingPropChanges: Set<number> = new Set<number>();

  /** 是否有相机上报过、还没回读的变化。控制页据此决定要不要提前复流去读。 */
  static hasPendingPropChanges(): boolean {
    return NikonPtpIpService.pendingPropChanges.size > 0;
  }

  /** 取出并清空待回读的属性码。没有变化时返回空数组。 */
  static takePendingPropChanges(): number[] {    if (NikonPtpIpService.pendingPropChanges.size === 0) {
      return [];
    }
    const codes: number[] = [];
    NikonPtpIpService.pendingPropChanges.forEach((code: number): void => {
      codes.push(code);
    });
    NikonPtpIpService.pendingPropChanges.clear();
    return codes;
  }

  /** Timestamp of the most recent CaptureComplete event, or 0 when none arrived. */
  static captureCompletedAt(): number {
    return NikonPtpIpService.lastCaptureCompleteAt;
  }

  /** Whether a CaptureComplete event arrived within the last `windowMs`. */
  static capturedWithin(windowMs: number): boolean {
    return NikonPtpIpService.lastCaptureCompleteAt > 0 &&
      Date.now() - NikonPtpIpService.lastCaptureCompleteAt <= windowMs;
  }

  /** 机身自己结束了录像的时刻（0xC108 录制完成 / 0xC105 录制被打断）。
   *
   *  录像可能不是我们停的：卡满、过热、机身按键、待机定时器都会让机身自己收尾。
   *  那种情况下 `0x920B` 永远不会被调用，界面上的"录制中"就会一直挂着。所以机身
   *  推的这两个事件记一个时间戳，控制页拿它和自己记的开始时间比一比就知道该收回
   *  状态了。0（没收到过）永远小于任何开始时间，所以不会误判。 */
  private static lastMovieStopAt: number = 0;

  /** 机身是否在 `startedAt` 之后报告过录像结束。 */
  static movieStoppedSince(startedAt: number): boolean {
    return NikonPtpIpService.lastMovieStopAt >= startedAt;
  }

  private static eventName(code: number): string {
    switch (code) {
      case NikonPtpIpService.EVENT_CAPTURE_COMPLETE: return 'CaptureComplete';
      case NikonPtpIpService.EVENT_DEVICE_PROP_CHANGED: return 'DevicePropChanged';
      case 0x4002: return 'ObjectAdded';
      case 0x4005: return 'StoreRemove';
      case 0x400A: return 'StoreFull';
      case 0xC105: return 'RecordingInterrupted';
      case 0xC108: return 'MovieRecordComplete';
      case 0xC10A: return 'StartMovieRecord';
      case 0xC700: return 'LssInstruction';
      case 0xC702: return 'CancelNCSendFWFile';
      default: return 'Event';
    }
  }

  /**
   * Scan handles from a cursor and build at most `limit` gallery entries.
   * Every examined handle advances the cursor exactly once - directories,
   * unsupported formats, missing ObjectInfo and missing thumbnails are
   * classified and skipped, while transport exceptions propagate and fail
   * the page instead of masquerading as an empty page.
   */
  private static async scanPage(context: common.UIAbilityContext, session: NikonPtpSession,
    fromIndex: number, limit: number): Promise<NikonPtpGalleryPage> {
    const result: NikonPtpGalleryItem[] = [];
    const handles = session.handles;
    let cursor = Math.max(0, Math.min(fromIndex, handles.length));
    let examined = 0;
    while (cursor < handles.length && result.length < limit && examined < NikonPtpIpService.SCAN_BUDGET) {
      const handle = handles[cursor];
      cursor += 1;
      examined += 1;
      // 这一项属于哪张卡。句柄空间按卡独立，所以选择键与缩略图文件名都必须
      // 带上卡号——否则卡 1 和卡 2 上同号的两个对象会共用一份缩略图、并且
      // 在选择集合里互相顶掉。取不到时回落到会话的默认卡号。
      const itemStorageId = session.storageOf.has(handle)
        ? session.storageOf.get(handle) as number
        : session.storageId;
      let object: NikonPtpObjectInfo | undefined = session.objects.get(handle);
      if (object === undefined) {
        const info = await session.enqueue(NikonPtpIpService.OP_GET_OBJECT_INFO, [handle], true);
        if (info.code !== NikonPtpIpService.RESPONSE_OK || info.data.length === 0) continue;
        const parsedObject = NikonPtpIpService.parseObjectInfo(handle, info.data);
        if (parsedObject === null) continue;
        session.objects.set(handle, parsedObject);
        object = parsedObject;
      }
      // GetObjectHandles includes directory/association entries. They have no
      // image bytes and asking GetThumb for one can make Nikon return a vendor
      // error instead of advancing to the first photo.
      if (object.size <= 0 || object.format === 0x3001) {
        NikonPtpIpService.log(`ptpip skip non-image handle=${handle} format=${NikonPtpIpService.hexCode(object.format)}`);
        continue;
      }
      NikonPtpIpService.log(`ptpip object handle=${handle} format=${NikonPtpIpService.hexCode(object.format)} size=${object.size}`);
      // Movies are listed so the user can see them and be told video grading
      // is unsupported, but they never produce a usable gallery preview.
      const isVideo = NikonPtpIpService.isVideoFormat(object.format) ||
        NikonPtpIpService.isVideoName(object.filename);
      const thumbResponse = await session.enqueue(NikonPtpIpService.OP_GET_THUMB, [handle], true);
      if (thumbResponse.code !== NikonPtpIpService.RESPONSE_OK || thumbResponse.data.length === 0) {
        NikonPtpIpService.log(`ptpip thumb-missing handle=${handle} code=${NikonPtpIpService.hexCode(thumbResponse.code)}`);
        if (!isVideo) continue;
        // Keep the video listed without a poster frame; the UI badge and the
        // tap dialog explain the limitation instead of the item vanishing.
        result.push({
          imageId: `${itemStorageId}:${handle}`,
          imageType: NikonPtpIpService.imageType(object.filename, object.format),
          thumbnailUri: '',
          size: object.size,
          rawSize: 0,
          originalFileName: object.filename,
          handle: handle,
          storageId: itemStorageId,
        });
        continue;
      }
      const path = `${context.filesDir}/nikon_thumbnail_${itemStorageId}_${handle}.jpg`;
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      NikonPtpIpService.writeAll(file.fd, thumbResponse.data);
      fileIo.closeSync(file);
      result.push({
        imageId: `${itemStorageId}:${handle}`,
        imageType: NikonPtpIpService.imageType(object.filename, object.format),
        thumbnailUri: `file://${path}`,
        size: object.size,
        rawSize: NikonPtpIpService.isRaw(object.filename) ? object.size : 0,
        originalFileName: object.filename,
        handle: handle,
        storageId: itemStorageId,
      });
    }
    return { items: result, nextHandleIndex: cursor, remaining: Math.max(0, handles.length - cursor) };
  }

  /** Chunked GetPartialObject download straight into `fd`. A short or empty
   * chunk is a failure - the previous implementation accepted truncated
   * files and reported 100%. */
  private static async writePartialObject(session: NikonPtpSession, handle: number, total: number,
    fd: number, onProgress?: (progress: number, received: number, total: number) => void): Promise<number> {
    const chunkSize = 1024 * 1024;
    let offset = 0;
    while (offset < total) {
      const length = Math.min(chunkSize, total - offset);
      const result = await session.enqueue(NikonPtpIpService.OP_GET_PARTIAL_OBJECT,
        [handle, offset, length], true);
      if (result.code === NikonPtpIpService.RESPONSE_OPERATION_NOT_SUPPORTED && offset === 0) {
        // Only a fully-consumed, explicit "operation not supported" response
        // may fall back to GetObject; timeouts, disconnects and frame errors
        // must fail instead of re-reading on a possibly polluted stream.
        NikonPtpIpService.log(`ptpip partial-unsupported handle=${handle} fallback=GetObject`);
        return NikonPtpIpService.readWholeObject(session, handle, fd, onProgress);
      }
      if (result.code !== NikonPtpIpService.RESPONSE_OK) {
        throw new Error(`PTP/IP GetPartialObject response ${NikonPtpIpService.hexCode(result.code)}`);
      }
      if (result.data.length === 0) {
        throw new Error('PTP/IP GetPartialObject returned an empty chunk');
      }
      if (result.data.length > length) {
        throw new Error(`PTP/IP chunk overflow requested=${length} received=${result.data.length}`);
      }
      if (result.params.length > 0 && result.params[0] !== result.data.length) {
        throw new Error(`PTP/IP chunk length mismatch param=${result.params[0]} data=${result.data.length}`);
      }
      NikonPtpIpService.writeAll(fd, result.data);
      offset += result.data.length;
      if (onProgress) onProgress(Math.min(99, Math.round(offset * 100 / total)), offset, total);
      if (result.data.length < length) {
        throw new Error(`PTP/IP short chunk at ${offset}/${total}`);
      }
    }
    return offset;
  }

  /** Whole-object GetObject fallback with an explicit memory bound and size
   * verification. Used only for the 0x2005 business rejection and for
   * objects whose size is unknown. */
  private static async readWholeObject(session: NikonPtpSession, handle: number, fd: number,
    onProgress?: (progress: number, received: number, total: number) => void): Promise<number> {
    let expected = 0;
    const infoResponse = await session.enqueue(NikonPtpIpService.OP_GET_OBJECT_INFO, [handle], true);
    if (infoResponse.code === NikonPtpIpService.RESPONSE_OK && infoResponse.data.length >= 52) {
      const info = NikonPtpIpService.parseObjectInfo(handle, infoResponse.data);
      if (info !== null) expected = info.size;
    }
    if (expected > NikonPtpIpService.MAX_WHOLE_OBJECT_BYTES) {
      throw new Error(`PTP/IP object too large for whole-object read (${expected} bytes)`);
    }
    const result = await session.enqueue(NikonPtpIpService.OP_GET_OBJECT, [handle], true);
    if (result.code !== NikonPtpIpService.RESPONSE_OK || result.data.length === 0) {
      throw new Error(`PTP/IP GetObject response ${NikonPtpIpService.hexCode(result.code)}`);
    }
    if (expected > 0 && result.data.length !== expected) {
      throw new Error(`PTP/IP object size mismatch expected=${expected} received=${result.data.length}`);
    }
    NikonPtpIpService.writeAll(fd, result.data);
    if (onProgress) onProgress(100, result.data.length, expected || result.data.length);
    return result.data.length;
  }

  private static writeAll(fd: number, data: Uint8Array): void {
    const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
    const written = fileIo.writeSync(fd, buffer);
    if (written !== data.length) {
      throw new Error(`file write incomplete expected=${data.length} written=${written}`);
    }
  }

  private static removeFile(path: string): void {
    try { fileIo.unlinkSync(path); } catch (_error) { }
  }

  private static initCommand(guid: Uint8Array, name: string): Uint8Array {
    const nameBytes = NikonPtpIpService.utf16(name + '\u0000');
    const payload = new Uint8Array(guid.length + nameBytes.length + 4);
    payload.set(guid, 0);
    payload.set(nameBytes, guid.length);
    NikonPtpIpService.writeU32(payload, guid.length + nameBytes.length, 0x00010000);
    return NikonPtpIpService.frame(NikonPtpIpService.TYPE_INIT_COMMAND, payload);
  }

  private static operationRequest(op: number, transaction: number, params: number[],
    dataPhase: number = 1): Uint8Array {
    const payloadLength = 4 + 2 + 4 + params.length * 4;
    const packet = new Uint8Array(8 + payloadLength);
    NikonPtpIpService.writeU32(packet, 0, packet.length);
    NikonPtpIpService.writeU32(packet, 4, NikonPtpIpService.TYPE_OPERATION_REQUEST);
    // PTP/IP DataPhaseInfo (CIPA DC-005): **1 = No Data, 2 = Data In
    // (responder -> initiator), 3 = Data Out (initiator -> responder)**.
    //
    // This adapter shipped with a hardcoded 1 because every original operation was
    // a read, and the body answers a read's data phase without being told. A write
    // has to announce **3**; announcing 2 (which this comment used to claim was
    // "initiator-to-responder") makes the body discard the following data frames
    // as protocol noise and never answer the operation at all.
    NikonPtpIpService.writeU32(packet, 8, dataPhase);
    NikonPtpIpService.writeU16(packet, 12, op);
    NikonPtpIpService.writeU32(packet, 14, transaction);
    for (let index = 0; index < params.length; index++) NikonPtpIpService.writeU32(packet, 18 + index * 4, params[index]);
    return packet;
  }

  private static frame(type: number, payload: Uint8Array): Uint8Array {
    const packet = new Uint8Array(8 + payload.length);
    NikonPtpIpService.writeU32(packet, 0, packet.length);
    NikonPtpIpService.writeU32(packet, 4, type);
    packet.set(payload, 8);
    return packet;
  }

  private static parseObjectInfo(handle: number, data: Uint8Array): NikonPtpObjectInfo | null {
    if (data.length < 52) return null;
    let offset = 0;
    const storageId = NikonPtpIpService.readU32(data, offset); offset += 4;
    const format = NikonPtpIpService.readU16(data, offset); offset += 2;
    offset += 2; // protection status
    const size = NikonPtpIpService.readU32(data, offset); offset += 4;
    const thumbFormat = NikonPtpIpService.readU16(data, offset); offset += 2;
    const thumbSize = NikonPtpIpService.readU32(data, offset); offset += 4;
    const thumbWidth = NikonPtpIpService.readU32(data, offset); offset += 4;
    const thumbHeight = NikonPtpIpService.readU32(data, offset); offset += 4;
    const width = NikonPtpIpService.readU32(data, offset); offset += 4;
    const height = NikonPtpIpService.readU32(data, offset); offset += 4;
    offset += 4 + 4 + 2 + 4 + 4; // bit depth, parent, association type/desc, sequence
    const filename = NikonPtpIpService.readPtpString(data, offset);
    return {
      handle: handle,
      storageId: storageId,
      format: format || thumbFormat,
      size: size,
      thumbSize: thumbSize,
      width: width || thumbWidth,
      height: height || thumbHeight,
      filename: filename.value,
    };
  }

  private static readPtpString(data: Uint8Array, offset: number): NikonPtpStringRead {
    if (offset >= data.length) return { value: '', next: data.length };
    const count = data[offset];
    const end = Math.min(data.length, offset + 1 + count * 2);
    let value = '';
    for (let index = 0; index + 1 < count && offset + 1 + index * 2 + 1 < end; index++) {
      value += String.fromCharCode(data[offset + 1 + index * 2] | (data[offset + 2 + index * 2] << 8));
    }
    return { value: value, next: end };
  }

  private static parseU32List(data: Uint8Array): number[] {
    if (data.length < 4) return [];
    const count = Math.min(NikonPtpIpService.readU32(data, 0), Math.floor((data.length - 4) / 4));
    const values: number[] = [];
    for (let index = 0; index < count; index++) values.push(NikonPtpIpService.readU32(data, 4 + index * 4));
    return values;
  }

  private static parseFirstU32(data: Uint8Array): number {
    return data.length >= 4 ? NikonPtpIpService.readU32(data, 0) : 0;
  }

  private static imageType(filename: string, format: number): number {
    return NikonPtpIpService.isRaw(filename) || format === 0x3802 ? 1 : 2;
  }

  private static isRaw(filename: string): boolean {
    return NikonPtpIpService.RAW_EXTENSIONS.indexOf(NikonPtpIpService.extension(filename)) >= 0;
  }

  private static extension(filename: string): string {
    const dot = filename.lastIndexOf('.');
    return dot >= 0 ? filename.substring(dot + 1).toLowerCase() : '';
  }

  /** PTP object formats for movie containers: AVI, MPEG, ASF, QuickTime.
   * Nikon records MOV (0x300D) and MP4-era clips under these codes. */
  private static readonly VIDEO_EXTENSIONS: string[] = [
    'mov', 'mp4', 'm4v', 'avi', 'mpg', 'mpeg', 'mts', 'm2ts', '3gp', 'wmv', 'asf',
  ];

  static isVideoFormat(format: number): boolean {
    return format >= 0x300A && format <= 0x300D;
  }

  static isVideoName(filename: string): boolean {
    return NikonPtpIpService.VIDEO_EXTENSIONS.indexOf(NikonPtpIpService.extension(filename)) >= 0;
  }

  private static concat(chunks: Uint8Array[], total: number): Uint8Array {
    const result = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      result.set(chunk.slice(0, Math.min(chunk.length, total - offset)), offset);
      offset += Math.min(chunk.length, total - offset);
      if (offset >= total) break;
    }
    return result;
  }

  private static utf16(value: string): Uint8Array {
    const result = new Uint8Array(value.length * 2);
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index);
      result[index * 2] = code & 0xff;
      result[index * 2 + 1] = (code >>> 8) & 0xff;
    }
    return result;
  }

  private static u32(value: number): Uint8Array {
    const result = new Uint8Array(4);
    NikonPtpIpService.writeU32(result, 0, value);
    return result;
  }

  private static newGuid(): Uint8Array {
    const result = new Uint8Array(16);
    for (let index = 0; index < result.length; index++) result[index] = Math.floor(Math.random() * 256);
    result[6] = (result[6] & 0x0f) | 0x40;
    result[8] = (result[8] & 0x3f) | 0x80;
    return result;
  }

  private static cleanHost(host: string): string {
    return host.trim().replace(/^https?:\/\//, '').replace(/\/$/, '');
  }

  private static redactHost(host: string): string {
    return host.replace(/(\d+\.\d+\.\d+)\.\d+$/, '$1.x');
  }

  private static hexCode(value: number): string {
    return '0x' + value.toString(16).padStart(4, '0').toUpperCase();
  }

  private static readU16(data: Uint8Array, offset: number): number {
    return data[offset] | (data[offset + 1] << 8);
  }

  static readU32(data: Uint8Array, offset: number): number {
    return (data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
  }

  /**
   * Reads a u32 big-endian.
   *
   * Needed because a payload's own encoding is not always the transport's: the
   * PTP/IP framing is little-endian, while the live-view header is big-endian.
   */
  static readU32BigEndian(data: Uint8Array, offset: number): number {
    return ((data[offset] << 24) | (data[offset + 1] << 16) |
      (data[offset + 2] << 8) | data[offset + 3]) >>> 0;
  }

  /** 64-bit little-endian length with a safe-integer guard; a value beyond
   * Number's exact range is rejected instead of silently wrapping. */
  private static readU64Checked(data: Uint8Array, offset: number): number {
    const low = NikonPtpIpService.readU32(data, offset);
    const high = NikonPtpIpService.readU32(data, offset + 4);
    if (high === 0) return low;
    const value = high * 0x100000000 + low;
    if (!Number.isSafeInteger(value)) {
      throw new Error('PTP/IP data length exceeds the safe integer range');
    }
    return value;
  }

  private static writeU16(data: Uint8Array, offset: number, value: number): void {
    data[offset] = value & 0xff;
    data[offset + 1] = (value >>> 8) & 0xff;
  }

  private static writeU32(data: Uint8Array, offset: number, value: number): void {
    data[offset] = value & 0xff;
    data[offset + 1] = (value >>> 8) & 0xff;
    data[offset + 2] = (value >>> 16) & 0xff;
    data[offset + 3] = (value >>> 24) & 0xff;
  }

  static log(message: string): void {
    try { hilog.info(0x0001, 'VIVID_BLE', '%{public}s', message); } catch (_error) { }
    // 同一行再进应用日志：用户无法读取 hilog，而「问题反馈 → 发送日志」上传的是
    // AppLogStore 的落盘文件。只写 hilog 的日志，在真机复现时等于不存在。
    AppLogSink.emit('CTL', message);
  }

  private static operationName(op: number): string {
    switch (op) {
      case NikonPtpIpService.OP_OPEN_SESSION: return 'OpenSession';
      case NikonPtpIpService.OP_CLOSE_SESSION: return 'CloseSession';
      case NikonPtpIpService.OP_GET_STORAGE_IDS: return 'GetStorageIDs';
      case NikonPtpIpService.OP_GET_NUM_OBJECTS: return 'GetNumObjects';
      case NikonPtpIpService.OP_GET_OBJECT_HANDLES: return 'GetObjectHandles';
      case NikonPtpIpService.OP_GET_OBJECT_INFO: return 'GetObjectInfo';
      case NikonPtpIpService.OP_GET_OBJECT: return 'GetObject';
      case NikonPtpIpService.OP_GET_THUMB: return 'GetThumb';
      case NikonPtpIpService.OP_GET_PARTIAL_OBJECT: return 'GetPartialObject';
      case NikonPtpIpService.OP_GET_DEVICE_INFO: return 'GetDeviceInfo';
      case NikonPtpIpService.OP_GET_DEVICE_PROP_VALUE: return 'GetDevicePropValue';
      case NikonPtpIpService.OP_SET_DEVICE_PROP_VALUE: return 'SetDevicePropValue';
      case NikonPtpIpService.OP_NIKON_DEVICE_READY: return 'NikonDeviceReady';
      case NikonPtpIpService.OP_NIKON_START_LIVE_VIEW: return 'NikonStartLiveView';
      case NikonPtpIpService.OP_NIKON_END_LIVE_VIEW: return 'NikonEndLiveView';
      case NikonPtpIpService.OP_NIKON_GET_LIVE_VIEW_IMAGE: return 'NikonGetLiveViewImage';
      case NikonPtpIpService.OP_NIKON_GET_LIVE_VIEW_IMAGE_EX: return 'NikonGetLiveViewImageEx';
      case NikonPtpIpService.OP_NIKON_INITIATE_CAPTURE: return 'NikonInitiateCapture';
      case NikonPtpIpService.OP_NIKON_START_MOVIE_REC: return 'NikonStartMovieRec';
      case NikonPtpIpService.OP_NIKON_END_MOVIE_REC: return 'NikonEndMovieRec';
      case NikonPtpIpService.OP_NIKON_CHANGE_APPLICATION_MODE: return 'NikonChangeApplicationMode';
      case NikonPtpIpService.OP_NIKON_GET_LSS_CONNECTION_CONFIGURATION: return 'NikonGetLssConnectionConfiguration';
      default: return `0x${op.toString(16).toUpperCase()}`;
    }
  }

  static logError(scope: string, error: Object): void {
    try {
      const code = (error as NikonPtpErrorShape).code;
      const message = (((error as Error).message || String(error) || '') as string)
        .replace(/[\u0000-\u001F\u007F]/g, ' ').substring(0, 120);
      hilog.error(0x0001, 'VIVID_BLE', '%{public}s code=%{public}s message=%{public}s', scope,
        code === undefined ? 'unknown' : String(code), message);
      AppLogSink.emit('CTL_ERR', `${scope} code=${code === undefined ? 'unknown' : String(code)} ${message}`);
    } catch (_error) { }
  }
}
