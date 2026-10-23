import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LumixCameraService } from './LumixCameraService';
import { LumixImportPrototype } from './LumixImportPrototype';

/**
 * Independent LUMIX LUT transfer client (Wi-Fi AP mode, https://<gateway>).
 *
 * The LUT endpoints (/auth, /lut/info, /lut/send-prepare, /lut/send) live on
 * the same camera HTTPS server as the image-transfer endpoints but form a
 * separate protocol line: this client keeps its own session token, its own
 * persisted client UUID and never reads or writes any state owned by the
 * image-transfer adapter. Only the read-only Wi-Fi link helpers of
 * LumixCameraService are shared, so a LUT import can never disturb a running
 * image transfer session and no frozen image-transfer code is modified.
 *
 * Wire shape (captured from the official LUT app, 2026-09-17):
 * - POST /auth             {"AppInfo","FriendlyName","Uuid"} -> {Data:{AuthToken}}
 * - POST /lut/info         {}                                 -> {Data:{DataList:[41 slots]}}
 * - POST /lut/send-prepare {"FileSize","LutId","filename"}    -> {Data:{Result,bufsize}}
 * - POST /lut/send xN      raw .cube chunk, transId header = chunk index
 */

/** One camera LUT slot as reported by /lut/info. */
export interface LumixLutSlot {
  lutId: number;
  lutName: string;
  /** 1=Vlog_709 built-in, 2=ARRI 709 built-in, 3=user slot. */
  lutType: number;
  photoStyle: string;
  empty: boolean;
}

/** An authenticated LUT protocol session on the camera access point. */
export interface LumixLutSession {
  host: string;
  ssid: string;
  token: string;
}

/** Chunk progress of an in-flight /lut/send sequence. */
export interface LumixLutSendState {
  sentBytes: number;
  totalBytes: number;
  chunkIndex: number;
  totalChunks: number;
}

/** Stage of a LUT session failure, used by the UI for error classification. */
export type LumixLutErrorKind = 'wifi' | 'ssid' | 'gateway' | 'auth' | 'slots';

/** A LUT protocol failure tagged with the stage where it happened. */
export class LumixLutError extends Error {
  readonly kind: LumixLutErrorKind;
  /** Camera business code from the response envelope when available (e.g. 401). */
  readonly code: number;

  constructor(kind: LumixLutErrorKind, message: string, code: number = 0) {
    super(message);
    this.kind = kind;
    this.code = code;
  }
}

interface LutResponseData {
  Result?: number;
  bufsize?: number;
  AuthToken?: string;
  DataList?: LutSlotRecord[];
}

interface LutResponseEnvelope {
  Data?: LutResponseData;
  Header?: LutResponseHeader;
}

interface LutResponseHeader {
  ResponseCode?: number;
  Messages?: string;
}

interface LutSlotRecord {
  LutId?: number;
  LutName?: string;
  LutType?: number;
  PhotoStyle?: string;
  Selectable?: number;
}

// Exact AppInfo string captured from the official "LUMIX LUT Creators APP
// 3.0.1" client. /auth itself accepts any AppInfo (the image line proves
// it); the official value is kept for maximal parity with the captured
// client because the gate on the /lut/* endpoints is still being isolated.
const LUT_APP_INFO = 'LUMIX LUT Creators APP 3.0.1';
const LUT_FRIENDLY_NAME = 'Pixelshop HarmonyOS';

/** App profile the frozen image-transfer adapter presents at /auth. */
export const IMAGE_APP_INFO = 'Pixelshop Studio vivid_diary/1.0.0-preview';

/**
 * Device UUID the instrumented official LUT app used in the 2026-09-17
 * captures (fresh BLE pairing at 21:42, working /lut session at 22:15).
 * Diagnostic probe only: if the camera accepts it, the LUT endpoints are
 * gated on the official app's BLE registration record.
 */
export const CAPTURE_LUT_UUID = 'a529e6a25d184952a5de83ca451e41e5';
/** Phone device name from the same captures (FriendlyName of /auth). */
export const CAPTURE_LUT_FRIENDLY_NAME = 'WEB-W00';

export class LumixLutService {
  /**
   * Authenticate a LUT session against the currently linked camera AP.
   * fallbackUuid is the read-only image-transfer client identity: when the
   * camera refuses this client's own identity (for example right after an
   * image transfer established a session), /auth is retried once with it so
   * entering the LUT page after a picture fetch still connects. Throws a
   * LumixLutError with a user-facing Chinese message on failure.
   */
  static async openSession(context: common.UIAbilityContext, fallbackUuid: string): Promise<LumixLutSession> {
    const ssid = await LumixCameraService.linkedSsid();
    if (ssid.length === 0) {
      throw new LumixLutError('wifi', '手机未连接相机 Wi‑Fi');
    }
    if (LumixCameraService.identifyWifiSsid(ssid) === null) {
      throw new LumixLutError('ssid', `当前 Wi‑Fi「${ssid}」不是松下相机热点`);
    }
    const host = await LumixCameraService.linkedGateway();
    if (host.length === 0) {
      throw new LumixLutError('gateway', '未获取到相机网络网关，请重新连接相机 Wi‑Fi');
    }
    const ownUuid = await LumixLutService.clientUuid(context);
    // 相机对 /auth 来者不拒，但 /lut/* 端点校验 BLE 注册记录（21:51 真机
    // 日志：四个 HTTP 身份全部 401 err_critical，包括官方 App 抓包 UUID）。
    // 先把本客户端身份按官方 LUT App 的方式注册进相机，再走 HTTP。
    await LumixLutService.registerIdentityOverBle(ownUuid, LUT_APP_INFO, LUT_FRIENDLY_NAME);
    LumixLutService.log('auth request host=present uuid=present identity=own');
    let token = '';
    try {
      token = await LumixLutService.authOnceWith(host, ownUuid, LUT_APP_INFO, LUT_FRIENDLY_NAME);
    } catch (firstError) {
      // Either the camera refused the identity, or the first TLS handshake
      // to a just-joined camera AP failed. Retry once after a short pause,
      // preferring the image-transfer identity when it differs (exact string:
      // the camera compares against what the BLE registration sent).
      const retryUuid = fallbackUuid.length > 0 && fallbackUuid !== ownUuid ? fallbackUuid : ownUuid;
      LumixLutService.log(`auth retry identity=${retryUuid === ownUuid ? 'own' : 'image-uuid'}`);
      await LumixLutService.delay(800);
      try {
        token = await LumixLutService.authOnceWith(host, retryUuid, LUT_APP_INFO, LUT_FRIENDLY_NAME);
        if (retryUuid !== ownUuid) {
          await LumixLutService.rememberIdentity(context, retryUuid);
        }
      } catch (secondError) {
        const message = secondError instanceof Error ? secondError.message :
          (firstError instanceof Error ? firstError.message : '相机拒绝连接');
        // 透传业务码（如 401）：LutTransferPage 的身份探测循环依赖
        // code===401 触发，默认 0 会让探测永远不运行。
        throw new LumixLutError('auth', message, LumixLutService.businessCodeOf(message));
      }
    }
    LumixLutService.log('auth ok token=received value=redacted');
    const session: LumixLutSession = { host: host, ssid: ssid, token: token };
    return session;
  }

  /**
   * Authenticate with an explicit client identity, bypassing the persisted
   * LUT identity and its retry logic. An empty appInfo selects the official
   * LUT client profile; an empty friendlyName selects this app's device
   * name. Used to probe which identity the camera's LUT endpoints accept.
   */
  static async openSessionWithIdentity(context: common.UIAbilityContext, uuid: string,
    appInfo: string, friendlyName: string): Promise<LumixLutSession> {
    const ssid = await LumixCameraService.linkedSsid();
    if (ssid.length === 0) {
      throw new LumixLutError('wifi', '手机未连接相机 Wi‑Fi');
    }
    if (LumixCameraService.identifyWifiSsid(ssid) === null) {
      throw new LumixLutError('ssid', `当前 Wi‑Fi「${ssid}」不是松下相机热点`);
    }
    const host = await LumixCameraService.linkedGateway();
    if (host.length === 0) {
      throw new LumixLutError('gateway', '未获取到相机网络网关，请重新连接相机 Wi‑Fi');
    }
    const profile = appInfo.length > 0 ? appInfo : LUT_APP_INFO;
    const name = friendlyName.length > 0 ? friendlyName : LUT_FRIENDLY_NAME;
    LumixLutService.log(`auth request host=present uuid=present profile=${appInfo.length > 0 ? 'image' : 'lut'} name=${friendlyName.length > 0 ? 'capture' : 'vivid'}`);
    // 探测路径同样先注册该候选身份，否则换任何 UUID 都过不了 /lut/* 的
    // BLE 注册门槛。
    await LumixLutService.registerIdentityOverBle(uuid, profile, name);
    // 身份探测路径：同样把业务码包进 LumixLutError，否则探测循环里的
    // instanceof + code===401 判断永远不命中。
    let token = '';
    try {
      token = await LumixLutService.authOnceWith(host, uuid, profile, name);
    } catch (error) {
      const message = error instanceof Error ? error.message : '相机拒绝连接';
      throw new LumixLutError('auth', message, LumixLutService.businessCodeOf(message));
    }
    LumixLutService.log('auth ok token=received value=redacted');
    const session: LumixLutSession = { host: host, ssid: ssid, token: token };
    return session;
  }

  /** Read the camera's full LUT slot list (built-in + 39 user positions). */
  static async fetchSlots(session: LumixLutSession): Promise<LumixLutSlot[]> {
    try {
      const raw = await LumixLutService.postJson(session.host, '/lut/info', '{}', session.token, '读取相机 LUT 列表');
      const data = LumixLutService.parseData(raw, '读取相机 LUT 列表');
      const records = data.DataList !== undefined && data.DataList !== null ? data.DataList : [];
      const slots: LumixLutSlot[] = [];
      for (const record of records) {
        const lutId = record.LutId !== undefined && record.LutId !== null ? Number(record.LutId) : -1;
        if (!Number.isFinite(lutId) || lutId < 0) continue;
        const name = record.LutName !== undefined && record.LutName !== null ? String(record.LutName) : '';
        const slot: LumixLutSlot = {
          lutId: lutId,
          lutName: name,
          lutType: record.LutType !== undefined && record.LutType !== null ? Number(record.LutType) : 3,
          photoStyle: record.PhotoStyle !== undefined && record.PhotoStyle !== null ? String(record.PhotoStyle) : '',
          empty: name.trim().length === 0,
        };
        slots.push(slot);
      }
      slots.sort((a: LumixLutSlot, b: LumixLutSlot): number => a.lutId - b.lutId);
      LumixLutService.log(`lut/info slots=${slots.length}`);
      // 诊断：S1RM2 槽位布局（用户槽的 LutId 起止可能与 S5M2 不同）。
      // 逐槽输出 id:type:nameLen 一行。
      const layoutParts: string[] = [];
      for (const slot of slots) {
        layoutParts.push(`${slot.lutId}:${slot.lutType}:${slot.lutName.length}`);
      }
      LumixLutService.log(`lut/info layout=${layoutParts.join('|')}`);
      // 诊断：名称乱码——落原始响应字节（前 800B 十六进制）与解析后的
      // 名称，判断是 UTF-8 解码问题还是相机侧存储编码问题。
      try {
        const rawBytes = await LumixLutService.postJsonForBytes(session.host, '/lut/info', '{}',
          session.token, '读取相机 LUT 列表');
        const probe = new Uint8Array(rawBytes);
        const probeLen = Math.min(probe.length, 800);
        const hexDump: string[] = [];
        for (let i = 0; i < probeLen; i++) {
          hexDump.push(probe[i].toString(16).padStart(2, '0'));
        }
        LumixLutService.log(`lut/info raw hex=${hexDump.join('')}`);
      } catch (_error) {
      }
      // 逐槽名称字节转储：S1RM2 固件对名称做了变换（U+FFxx 序列），
      // 需要与真实名称对照破解。取每个非空槽名称前 48 字节十六进制。
      for (const slot of slots) {
        if (!slot.empty) {
          const nameBytes = util.TextEncoder.create('utf-8').encode(slot.lutName);
          const probe = new Uint8Array(nameBytes);
          const probeLen = Math.min(probe.length, 48);
          const hexParts: string[] = [];
          for (let i = 0; i < probeLen; i++) {
            hexParts.push(probe[i].toString(16).padStart(2, '0'));
          }
          LumixLutService.log(`lut slot hex id=${slot.lutId} name=${hexParts.join('')}`);
        }
      }
      return slots;
    } catch (error) {
      if (error instanceof LumixLutError) {
        throw error;
      }
      const message = error instanceof Error ? error.message : '读取相机 LUT 列表失败';
      throw new LumixLutError('slots', message, LumixLutService.businessCodeOf(message));
    }
  }

  /**
   * Send one .cube payload into a camera slot: send-prepare negotiates the
   * chunk size, then the payload is POSTed in bufsize chunks with the chunk
   * index in the transId header. targetSlot uses the camera's LutId space
   * (user positions are LutId 2..40 and shown to users as 位置 1..39).
   */
  static async sendLut(session: LumixLutSession, filename: string, payload: ArrayBuffer, targetSlot: number,
    onProgress?: (state: LumixLutSendState) => void): Promise<void> {
    const prepareBody = JSON.stringify({ FileSize: payload.byteLength, LutId: targetSlot, filename: filename });
    const prepareRaw = await LumixLutService.postJson(session.host, '/lut/send-prepare', prepareBody,
      session.token, 'LUT 传输准备');
    // 诊断：S1RM2 发送全 200 但不落库——落 send-prepare 完整响应报文
    // （146B，检查 Result 之外的隐藏字段）。
    LumixLutService.log(`send-prepare raw=${prepareRaw}`);
    const prepareData = LumixLutService.parseData(prepareRaw, 'LUT 传输准备');
    const result = prepareData.Result !== undefined && prepareData.Result !== null ? Number(prepareData.Result) : -1;
    const bufsize = prepareData.bufsize !== undefined && prepareData.bufsize !== null ? Number(prepareData.bufsize) : 0;
    if (result !== 0) {
      throw new Error(`相机拒绝写入位置 ${targetSlot - 1}（Result=${result}）`);
    }
    if (!Number.isFinite(bufsize) || bufsize <= 0) {
      throw new Error('相机未返回有效分块大小');
    }
    const totalBytes = payload.byteLength;
    const totalChunks = Math.ceil(totalBytes / bufsize);
    LumixLutService.log(`send-prepare ok slot=${targetSlot} bytes=${totalBytes} bufsize=${bufsize} chunks=${totalChunks}`);
    const bytes = new Uint8Array(payload);
    // 官方 App 的整条发送（prepare + 分块）走 OkHttp 连接池的同一连接；
    // 旧版每个分块新建 http client——S1RM2 可能把上传流绑定在连接上，
    // 分块落在不同连接被静默丢弃（2026-09-28 全 200 但不落库）。改为
    // 单连接顺序发送。
    const client = http.createHttp();
    try {
      for (let chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
        const start = chunkIndex * bufsize;
        const end = Math.min(totalBytes, start + bufsize);
        const chunk = bytes.slice(start, end);
        const headers: Record<string, string> = {
          'Authorization': `'Bearer ${session.token}'`,
          'Content-Type': 'application/octet-stream',
          'Accept': 'application/json',
          'transID': String(chunkIndex),
        };
        const chunkRaw = await LumixLutService.postBinaryWith(client, session.host, '/lut/send',
          chunk.buffer as ArrayBuffer, headers, chunkIndex, 'LUT 数据传输');
        // 诊断：S1RM2 发送不落库——落每块完整响应报文（120B）。
        LumixLutService.log(`send chunk raw ${chunkIndex}=${chunkRaw}`);
        const chunkData = LumixLutService.parseData(chunkRaw, 'LUT 数据传输');
        const chunkResult = chunkData.Result !== undefined && chunkData.Result !== null ? Number(chunkData.Result) : -1;
        if (chunkResult !== 0) {
          throw new Error(`第 ${chunkIndex + 1}/${totalChunks} 块被相机拒绝（Result=${chunkResult}）`);
        }
        if (onProgress) {
          const state: LumixLutSendState = {
            sentBytes: end,
            totalBytes: totalBytes,
            chunkIndex: chunkIndex + 1,
            totalChunks: totalChunks,
          };
          onProgress(state);
        }
      }
    } finally {
      client.destroy();
    }
    LumixLutService.log(`send complete slot=${targetSlot} chunks=${totalChunks}`);
  }

  /**
   * Delete the LUT stored in a camera slot. Protocol §1/§2: POST /lut/delete
   * with {"LutId":N}; the slot then reports LutName "" and keeps its number.
   */
  static async deleteSlot(session: LumixLutSession, lutId: number): Promise<void> {
    const body = JSON.stringify({ LutId: lutId });
    const raw = await LumixLutService.postJson(session.host, '/lut/delete', body,
      session.token, '删除相机 LUT');
    const data = LumixLutService.parseData(raw, '删除相机 LUT');
    const result = data.Result !== undefined && data.Result !== null ? Number(data.Result) : -1;
    if (result !== 0) {
      throw new Error(`相机拒绝删除位置 ${lutId - 1}（Result=${result}）`);
    }
    LumixLutService.log(`delete ok slot=${lutId}`);
  }

  /**
   * Rename a camera-side LUT (POST /lut/rename, endpoint confirmed in the
   * official client's 40-endpoint list; the captured docs never recorded its
   * body, so it follows the same LutCameraPostBean shape as send-prepare:
   * {"LutId":N,"filename":"NewName"} without the .cube extension).
   */
  static async renameSlot(session: LumixLutSession, lutId: number, newName: string): Promise<void> {
    const body = JSON.stringify({ LutId: lutId, filename: newName });
    const raw = await LumixLutService.postJson(session.host, '/lut/rename', body,
      session.token, '重命名相机 LUT');
    const data = LumixLutService.parseData(raw, '重命名相机 LUT');
    const result = data.Result !== undefined && data.Result !== null ? Number(data.Result) : -1;
    if (result !== 0) {
      throw new Error(`相机拒绝重命名位置 ${lutId - 1}（Result=${result}）`);
    }
    LumixLutService.log(`rename ok slot=${lutId}`);
  }

  /**
   * Download the .cube payload of a camera slot (POST /lut/file). The endpoint
   * is confirmed in the official client's 40-endpoint list but its wire format
   * was never captured; the request follows the LutCameraPostBean family
   * ({"LutId":N}) and the raw response bytes are returned for .cube parsing.
   */
  static async fetchLutFile(session: LumixLutSession, lutId: number): Promise<ArrayBuffer> {
    const body = JSON.stringify({ LutId: lutId });
    const raw = await LumixLutService.postJsonForBytes(session.host, '/lut/file', body,
      session.token, '下载相机 LUT');
    if (raw.byteLength === 0) {
      throw new Error('相机未返回 LUT 文件内容');
    }
    LumixLutService.log(`lut/file ok slot=${lutId} bytes=${raw.byteLength}`);
    return raw;
  }

  /** One /auth round trip with a fixed identity; returns the session token. */
  private static async authOnceWith(host: string, uuid: string, appInfo: string,
    friendlyName: string): Promise<string> {
    const body = JSON.stringify({ AppInfo: appInfo, FriendlyName: friendlyName, Uuid: uuid });
    // LUT 401 排查（官方逐字节 diff）：/auth 请求体临时明文入日志。
    LumixLutService.log(`auth body=${body}`);
    const raw = await LumixLutService.postJson(host, '/auth', body, '', '连接相机');
    const data = LumixLutService.parseData(raw, '连接相机');
    const token = data.AuthToken !== undefined && data.AuthToken !== null ? String(data.AuthToken) : '';
    if (token.length === 0) {
      throw new Error('相机未返回 LUT 会话凭证');
    }
    LumixLutService.log(`auth token bytes=${token.length}`);
    return token;
  }

  /** Parse and validate a camera JSON envelope, returning its Data object. */
  private static parseData(body: string, phase: string): LutResponseData {
    let envelope: LutResponseEnvelope;
    try {
      envelope = JSON.parse(body) as LutResponseEnvelope;
    } catch (_error) {
      throw new Error(`${phase}：相机响应无法解析`);
    }
    // 抓包证实：成功的 /lut/info 响应整体省略 Header（{"Data":{"DataList":…}}，
    // GSON 还原输出同样无 Header），HTTP 层已在 postJson 校验过状态码。
    // 只有显式存在的 ResponseCode 才构成拒绝（401 拒绝时 Header 仍在，
    // 身份探测依赖它）。Header 缺失 = 成功。
    const header = envelope.Header;
    if (header && header.ResponseCode !== undefined) {
      const code = Number(header.ResponseCode);
      if (code !== 200) {
        const messages = header.Messages !== undefined && header.Messages !== null ?
          String(header.Messages) : '';
        LumixLutService.log(`envelope reject code=${code} messages=${messages.length > 0 ? messages : '(empty)'}`);
        throw new Error(`${phase}：相机返回错误码 ${code}`);
      }
    }
    if (!envelope.Data) {
      throw new Error(`${phase}：相机响应缺少数据`);
    }
    return envelope.Data;
  }

  private static async postJson(host: string, path: string, body: string, token: string, phase: string): Promise<string> {
    const client = http.createHttp();
    try {
      // The captured client sets exactly Content-Type, Accept (+ Authorization
      // and transID where applicable); no extra custom headers are sent.
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        // 官方客户端的 lut/info 静态携带 Accept: application/json（dex j6/a.smali
        // 方法 W）。为最大保真补齐。
        'Accept': 'application/json',
      };
      if (token.length > 0) {
        // 2026-09-19 g 版插桩实锤：官方客户端 Authorization 头的字面值为
        // 'Bearer <token>'（含单引号，dex j6/a 与真机 FULL_HEADERS dump 双重
        // 证实）。相机侧解析按引号格式匹配，缺失引号导致 /lut/* 一律 401。
        headers['Authorization'] = `'Bearer ${token}'`;
      }
      const encoded = util.TextEncoder.create('utf-8').encode(body);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        body: encoded.byteOffset === 0 && encoded.byteLength === encoded.buffer.byteLength ?
          encoded.buffer as ArrayBuffer : encoded.slice().buffer as ArrayBuffer,
        connectTimeout: 15000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING,
        // The camera AP presents a self-signed certificate and the LUT
        // exchange carries no credentials or personal data, so the peer
        // certificate is accepted as-is on the private camera network.
        remoteValidation: (_validation: http.ValidationContext): Promise<boolean> => Promise.resolve(true),
      };
      const response = await client.request(`https://${host}${path}`, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      const resultText = typeof response.result === 'string' ? response.result : '';
      LumixLutService.log(`${path} http=${response.responseCode} reqBytes=${body.length} rspBytes=${resultText.length}`);
      return resultText;
    } catch (error) {
      if (error instanceof Error) {
        LumixLutService.log(`${path} failed code=${error.message}`);
        throw new Error(`${phase}失败：${error.message}`);
      }
      throw new Error(`${phase}失败`);
    } finally {
      client.destroy();
    }
  }

  /** Same request shape as postJson but returns the raw response bytes. */
  private static async postJsonForBytes(host: string, path: string, body: string, token: string,
    phase: string): Promise<ArrayBuffer> {
    const client = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/octet-stream',
      };
      if (token.length > 0) {
        headers['Authorization'] = `'Bearer ${token}'`;
      }
      const encoded = util.TextEncoder.create('utf-8').encode(body);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        body: encoded.byteOffset === 0 && encoded.byteLength === encoded.buffer.byteLength ?
          encoded.buffer as ArrayBuffer : encoded.slice().buffer as ArrayBuffer,
        connectTimeout: 15000,
        // A full LUT file (~1 MB) can take a while on the camera's Wi-Fi link.
        readTimeout: 60000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        // The camera AP presents a self-signed certificate; accepted as-is on
        // the private camera network (same policy as postJson/postBinary).
        remoteValidation: (_validation: http.ValidationContext): Promise<boolean> => Promise.resolve(true),
      };
      const response = await client.request(`https://${host}${path}`, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      const result = response.result instanceof ArrayBuffer ? response.result : new ArrayBuffer(0);
      LumixLutService.log(`${path} http=${response.responseCode} reqBytes=${body.length} rspBytes=${result.byteLength}`);
      return result;
    } catch (error) {
      if (error instanceof Error) {
        LumixLutService.log(`${path} failed code=${error.message}`);
        throw new Error(`${phase}失败：${error.message}`);
      }
      throw new Error(`${phase}失败`);
    } finally {
      client.destroy();
    }
  }

  /** 复用同一 http client 的分块发送：整条 /lut/send 保持单连接。 */
  private static async postBinaryWith(client: http.HttpRequest, host: string, path: string,
    body: ArrayBuffer, headers: Record<string, string>, chunkIndex: number, phase: string): Promise<string> {
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        body: body,
        connectTimeout: 15000,
        // The last chunk stalls ~1.2s while the camera flushes to disk.
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
        remoteValidation: (_validation: http.ValidationContext): Promise<boolean> => Promise.resolve(true),
      };
      const response = await client.request(`https://${host}${path}`, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      const resultText = typeof response.result === 'string' ? response.result : '';
      LumixLutService.log(`${path} chunk=${chunkIndex} http=${response.responseCode} reqBytes=${body.byteLength} rspBytes=${resultText.length}`);
      return resultText;
    } catch (error) {
      if (error instanceof Error) {
        LumixLutService.log(`${path} chunk=${chunkIndex} failed code=${error.message}`);
        throw new Error(`${phase}失败：${error.message}`);
      }
      throw new Error(`${phase}失败`);
    }
  }

  private static async postBinary(host: string, path: string, body: ArrayBuffer, token: string,
    chunkIndex: number, phase: string): Promise<string> {
    const client = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Authorization': `'Bearer ${token}'`,
        'Content-Type': 'application/octet-stream',
        // 2026-09-19 FULL_HEADERS dump：官方 /lut/send 应用层共 3 个头，
        // Accept + Authorization + transID（Content-Type 由请求体携带）。
        'Accept': 'application/json',
        // dex 实证官方只发 transID（j6/a.smali 方法 C 动态头，
        // 调用点 String.valueOf(块号)），不发 transId。去掉多余拼写。
        'transID': String(chunkIndex),
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        body: body,
        connectTimeout: 15000,
        // The last chunk stalls ~1.2s while the camera flushes to disk.
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
        remoteValidation: (_validation: http.ValidationContext): Promise<boolean> => Promise.resolve(true),
      };
      const response = await client.request(`https://${host}${path}`, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      const resultText = typeof response.result === 'string' ? response.result : '';
      LumixLutService.log(`${path} chunk=${chunkIndex} http=${response.responseCode} reqBytes=${body.byteLength} rspBytes=${resultText.length}`);
      return resultText;
    } catch (error) {
      if (error instanceof Error) {
        LumixLutService.log(`${path} chunk=${chunkIndex} failed code=${error.message}`);
        throw new Error(`${phase}失败：${error.message}`);
      }
      throw new Error(`${phase}失败`);
    } finally {
      client.destroy();
    }
  }

  /**
   * Stable per-install LUT identity, kept separate from the image-transfer
   * UUID so the camera treats this client as its own app (the official LUT
   * app also uses a different identity than the media apps).
   */
  private static async clientUuid(context: common.UIAbilityContext): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, 'vivid_lut_transfer');
      const saved = await store.get('clientUuid', '');
      if (typeof saved === 'string' && saved.length > 0) {
        return saved;
      }
      const uuid = util.generateRandomUUID(false).split('-').join('');
      await store.put('clientUuid', uuid);
      await store.flush();
      return uuid;
    } catch (_error) {
      try {
        return util.generateRandomUUID(false).split('-').join('');
      } catch (_ignored) {
        return 'vividlut000000000000000000000000';
      }
    }
  }

  /** Remember an identity the camera accepted so the next /auth succeeds first try. */
  static async rememberIdentity(context: common.UIAbilityContext, uuid: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, 'vivid_lut_transfer');
      await store.put('clientUuid', uuid);
      await store.flush();
    } catch (_error) {
    }
  }

  /** Pull the camera business code (相机返回错误码 N / HTTP N) back out of a
   * message. The HTTP form covers servers that answer 401 at the transport
   * layer instead of inside the envelope. */
  private static businessCodeOf(message: string): number {
    let match: RegExpExecArray | null = /错误码 (\d+)/.exec(message);
    if (match === null) {
      match = /HTTP (\d+)/.exec(message);
    }
    if (match !== null && match.length > 1) {
      const code = Number(match[1]);
      return Number.isFinite(code) ? code : 0;
    }
    return 0;
  }

  /**
   * Best-effort BLE registration of a client identity before the HTTPS /lut
   * session (official "LUMIX LUT Creators APP" behavior). Failures are logged
   * and swallowed: the HTTP attempt still runs, and the camera may accept an
   * identity that was registered on a previous GATT session.
   */
  private static async registerIdentityOverBle(uuid: string, appInfo: string,
    friendlyName: string): Promise<void> {
    try {
      const ok = await LumixImportPrototype.registerLutIdentity(uuid, appInfo, friendlyName);
      LumixLutService.log(`ble identity registration ${ok ? 'complete' : 'unavailable'}`);
      if (ok) {
        await LumixLutService.waitForCameraNetwork(30000);
      }
    } catch (error) {
      LumixLutService.log(`ble identity registration failed code=${error instanceof Error ? error.message : 'unknown'}`);
    }
  }

  /**
   * The 36f99090 pairing commit + ACTION_MODE write make the camera leave its
   * current mode and restart the Wi-Fi AP (22:18 device log: registration
   * complete, then /auth silence and a dropped remote-control session). The
   * phone re-associates automatically; wait until the camera SSID and gateway
   * are back before the HTTPS session starts. When the camera never reset its
   * mode (link stayed up) the first poll returns immediately.
   */
  private static async waitForCameraNetwork(timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const ssid = await LumixCameraService.linkedSsid();
        if (ssid.length > 0 && LumixCameraService.identifyWifiSsid(ssid) !== null) {
          const host = await LumixCameraService.linkedGateway();
          if (host.length > 0) {
            LumixLutService.log('camera network ready after registration reset');
            return;
          }
        }
      } catch (_error) {
      }
      await LumixLutService.delay(1000);
    }
    LumixLutService.log('camera network not ready after registration reset');
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** Short non-sensitive runtime marker; the session token never enters logs. */
  private static log(message: string): void {
    try {
      hilog.info(0x0001, 'VIVID_LUT', '%{public}s', message);
    } catch (_error) {
    }
  }
}
