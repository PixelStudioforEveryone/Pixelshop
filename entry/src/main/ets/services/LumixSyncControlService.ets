import { http } from '@kit.NetworkKit';
import { ble, constant } from '@kit.ConnectivityKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';
import { identifier } from '@kit.AdsKit';
import { LumixImportPrototype, WifiConnection } from './LumixImportPrototype';

/**
 * LUMIX Sync control-plane adapter for the pre-Lab Panasonic bodies
 * (S5 / GH5 / GH5S / G9 / GH6 / G100D).
 *
 * Protocol (from the official LUMIX Sync app, jadx-confirmed):
 *  1. BLE GATT pairing on service 054ac620-3214-11e6-ac0d-0002a5d5c51b:
 *     register the fixed ten-characteristic notify set (i5/e.java A()),
 *     then register the client identity. Legacy bodies (no bb5d2a8c) take
 *     the plaintext 16-byte MEI0 identity on 8d08a420 chained with the
 *     friendly name on cd7a71a0; APS bodies read INITIAL_INFORM 03e23a31
 *     for the session key first (first 4 bytes big-endian, all-zero selects
 *     the default key 0x9032782C) and write the o.d/o.c-encoded identity
 *     and name. The camera then requests the Wi-Fi connect type by pushing
 *     value[0]=1/4 on e182ec43; the app answers SoftAP {0x01} on 0d6f1880
 *     and the mode {0x01} on e182ec40 (jadx i5/g.java b10==1/4 branch).
 *     Once the access point is up the camera pushes value[0]=3 (pair-ready),
 *     after which the SSID e206a5c0 (semicolon list), the legacy session
 *     key and the password c97cf1a5 (o.a XOR encoding, length byte first)
 *     become readable.
 *  2. Join the camera Wi-Fi AP (shared LumixImportPrototype.connectWifi).
 *  3. GET /cam.cgi?mode=accctrl&type=req_acc&value={dotted-uuid}&value2={name}
 *     IS the registration commit. The 2026-09-27 official fresh-registration
 *     capture (zero-registered camera + wiped app, 57 lines end to end)
 *     shows pairing is: identity write -> name write -> z#35/z#5/z#6
 *     credential reads -> Wi-Fi join -> req_acc; the first answer is
 *     ok_under_research, the app re-sends ~1 s later and the second answer
 *     is ok. No CCCD descriptor write ever reaches the camera (its ten
 *     notify attempts all fail No_Descriptor and it proceeds anyway) and
 *     nothing else runs during registration. The fifth CSV element of the
 *     accepted response is the X-SESSION_ID.
 *  4. Control-mode entry (09-26 09:56:51 + 09-27 11:10:31 captures): the
 *     camera needs settling time between the req_acc commit and the entry
 *     writes - official gaps are 19 s / 34 s, and VIVID's 2 s gap drew an
 *     instant b0=1 rejection on e182ec41 (2026-09-27 10:54). Entry =
 *     credential re-read (R0#35/#5/#6), connect type {0x01} (stay on
 *     SoftAP - no {0x03} restart, no STA-SSID confirmation, no push
 *     wait), action mode {0x03}; the camera accepts silently. Finisher
 *     (09-27 11:11:04-09): req_acc refresh x2 (ok_under_research_no_msg
 *     -> ok), setsetting device_name, and the camera answers with the
 *     e182ec41 {0x00} activation push ~200 ms later. The 2026-09-25
 *     STA-confirm/{0x03}-restart variant stays behind the opt-in
 *     withControlDance flag.
 *  5. GET /cam.cgi?mode=camcmd&type={command} with X-SESSION_ID for control.
 */

export interface LumixSyncPairResult {
  ok: boolean;
  message: string;
  ssid: string;
  gateway: string;
  aps: boolean;
  password: string;
}

/** 直连快路径凭据：已配对相机的 SoftAP SSID 与密码。 */
export interface SyncDirectCredentials {
  ssid: string;
  password: string;
}

export interface LumixSyncSessionResult {
  ok: boolean;
  message: string;
  sessionId: string;
}

export interface LumixSyncCamCmdResult {
  ok: boolean;
  message: string;
  body: string;
}

/** Current values of the Sync-line drum parameters (getsetting 读取)。
 *  @Observed/@Track：轮询逐字段赋值需要驱动胶囊高亮与滑条刷新。 */
@Observed
export class LumixSyncStateParams {
  @Track iso: string = '';
  @Track shtrspeed: string = '';
  @Track focal: string = '';
  @Track exposure: string = '';
  @Track whitebalance: string = '';
}

/** mode=getsetting 单项读取结果（<settingvalue type="value"/>）。 */
export interface LumixSyncGetSettingResult {
  ok: boolean;
  value: string;
  body: string;
}

/** getinfo curmenu 里的一条 <item id= enable= value= option= .../>。 */
export interface SyncMenuItem {
  id: string;
  enable: string;
  value: string;
  option: string;
}

interface LumixSyncHttpResponse {
  code: number;
  body: string;
}

interface SyncGattCharacteristics {
  initialInform?: ble.BLECharacteristic;
  dlnaUuidAps?: ble.BLECharacteristic;
  friendlyNameAps?: ble.BLECharacteristic;
  wifiSsid?: ble.BLECharacteristic;
  wifiPassword?: ble.BLECharacteristic;
  dlnaUuidLegacy?: ble.BLECharacteristic;
  friendlyNameLegacy?: ble.BLECharacteristic;
  wifiConnectType?: ble.BLECharacteristic;
  actionMode?: ble.BLECharacteristic;
  staSsid?: ble.BLECharacteristic;
}

/** Vivid's persistent Panasonic DLNA identity in both wire forms. */
interface SyncClientIdentity {
  /** 32-char hex form: the 16 bytes written over BLE. */
  hex: string;
  /** Panasonic dotted DLNA UUID form used for cam.cgi accctrl. */
  dotted: string;
}

const SYNC_BLE_SERVICE = '054ac620-3214-11e6-ac0d-0002a5d5c51b';
const UUID_SYNC_INITIAL_INFORM = '03e23a31-a54c-40fa-a668-de9acdc910bb';
const UUID_SYNC_DLNA_UUID_APS = 'bb5d2a8c-5d3b-43ad-bfc3-470cad55c1ca';
const UUID_SYNC_FRIENDLY_NAME_APS = '7b61774f-efb4-44c6-a66d-c69e3b384c4a';
const UUID_SYNC_WIFI_SSID = 'e206a5c0-3214-11e6-afe4-0002a5d5c51b';
const UUID_SYNC_WIFI_PASSWORD = 'c97cf1a5-3c03-4290-8c1b-9e74b9500f54';
const UUID_SYNC_DLNA_UUID_LEGACY = '8d08a420-3213-11e6-8aca-0002a5d5c51b';
const UUID_SYNC_FRIENDLY_NAME_LEGACY = 'cd7a71a0-3213-11e6-8f56-0002a5d5c51b';
// Default session key 0x9032782C (= -1875740628 unsigned, jadx N5/o.java
// "j9 = j7 == 0 ? -1875740628L : j7") used when INITIAL_INFORM reads as zero
// (camera not yet paired with any client).
const SYNC_DEFAULT_KEY: number[] = [0x90, 0x32, 0x78, 0x2C];
const SYNC_FRIENDLY_NAME = 'Pixelshop';
const SYNC_LOG_TAG = 'VIVID_SYNC';
// e182ec43 pushes: 3 = registration accepted, 1/4 = connect-type request
// (jadx i5/g.java onCharacteristicChanged). The 2026-09-24 instrumented
// capture shows a FRESH pairing session pushes NOTHING here before the
// credential reads, so the value monitor keeps these only as diagnostics.
const UUID_SYNC_PAIR_STATUS = 'e182ec43-3213-11e6-ab07-0002a5d5c51b';
// Wi-Fi connect type (jadx i5/g.java q1(11)), service 5ae57260. The
// official pairing capture writes {0x03} first (H5.a.f2546j, fired from the
// 18345be0 SSID-confirmation write callback = "client joined the AP"),
// then answers {0x01} (H5.a.f2544h, SoftAP) after the camera pushes
// 18345be1; a push value of 0 would mean STA and take {0x02} (f2545i).
const UUID_SYNC_WIFI_CONNECT_TYPE = '0d6f1880-3217-11e6-a4cb-0002a5d5c51b';
// Action mode (jadx i5/g.java q1(4)): written with the CURRENT mode byte
// right after the connect-type answer completes (r1(4, f2731g) with
// f2731g = H5.a.f2540d = {0x03} during pairing — the capture confirms a
// {0x03} write, not the {0x01} the earlier static analysis guessed).
const UUID_SYNC_ACTION_MODE = 'e182ec40-3213-11e6-ab07-0002a5d5c51b';
// STA SSID confirmation (jadx i5/g.java q1(12) / z5.d.a + N5.l.x): the
// 32-byte NUL-padded ASCII SSID the phone is currently linked to, written
// once the camera AP has been joined. Its write callback fires the
// {0x03} connect-type write.
const UUID_SYNC_STA_SSID = '18345be0-3217-11e6-b56c-0002a5d5c51b';
// Camera push after the {0x03} connect-type write (jadx i5/g.java
// onCharacteristicChanged 18345be1): value[0]=1 means the SoftAP link is
// live; the official app then answers {0x01} on the connect type. The
// capture shows the push arriving ~50 ms after the {0x03} write; the
// push only ever arrives with the 18345be1 CCCD enabled (platform-
// managed inside setCharacteristicChangeNotification).
const UUID_SYNC_STA_RESULT = '18345be1-3217-11e6-b56c-0002a5d5c51b';
// Control-mode result push (jadx i5/g.java onCharacteristicChanged,
// e182ec4x family): value[0]=1 is the camera REJECTING the action-mode
// request from a client without an approved accctrl session — the
// 2026-09-25 capture shows it ~200 ms after the e182ec40 write — and
// value[0]=0 is the activation push sent once the control session goes
// live, 46 ms after the device_name setsetting in the same capture.
const UUID_SYNC_MODE_RESULT = 'e182ec41-3213-11e6-ab07-0002a5d5c51b';
// The fixed notify set the 2026-09-25 working-pairing trace registered as
// a ten-CCCD burst right after service discovery (registered=10
// missing=0, ~600 ms before the identity write). The confirmation dance
// depends on the 18345be1 push, and the e182ec41/e182ec43 monitors only
// ever see anything with these CCCDs enabled.
const SYNC_NOTIFY_UUIDS: string[] = [
  '4cf487c0-32a7-11e6-a50d-0002a5d5c51b',
  '37701b80-32a7-11e6-bb83-0002a5d5c51b',
  '18345be1-3217-11e6-b56c-0002a5d5c51b',
  '48669da0-3217-11e6-b08d-0002a5d5c51b',
  'e182ec43-3213-11e6-ab07-0002a5d5c51b',
  'da534d0a-63a3-447c-a889-aab701906af2',
  'd611b4a0-3217-11e6-8d98-0002a5d5c51b',
  'e182ec41-3213-11e6-ab07-0002a5d5c51b',
  'e182ec42-3213-11e6-ab07-0002a5d5c51b',
  '7be5fe6e-475b-11e7-a919-92ebcb67fe33',
];

export class LumixSyncControlService {
  private static sessionId = '';
  private static sessionHost = '';
  private static sessionActive = false;
  /** Epoch ms of the last stopstream; mode switches right after a stream
   *  stop drive the camera into a ~1 min err_busy lockup (2026-09-27
   *  15:50:54 stopstream → 15:50:55 playmode err_busy → busy until 15:53). */
  private static lastStreamStopAt = 0;
  /**
   * 最近一次**被相机接受**的模式切换（`playmode` / `recmode`），空串 = 未知。
   *
   * 2026-10-20 ZS300 实机：图库每翻一页都重发一次 `playmode`，第 3 页起
   * Browse 全部 403，随后 camcmd 也不再响应（"相机无响应"）。相机把重复的
   * 模式切换当成重入，会把 DMS 会话弄挂——所以先记住当前模式，已经在回放
   * 模式时不再重发。
   */
  private static lastAcceptedMode = '';
  /** One-shot flag: log the first full getstate body for format evidence. */
  private static stateBodyLogged = false;
  /** 已全量落过 hilog 的 getsetting 类型（每类型一次，而非全局一次——
   *  2026-09-28 首版只落了 iso，exposure/focal 证据缺失）。 */
  private static settingBodiesLogged: string[] = [];
  private static menuBodyLogged = false;
  private static lensBodyLogged = false;

  /** Whether a control session has already been established for this host. */
  static hasControlSession(host: string): boolean {
    if (!LumixSyncControlService.sessionActive ||
      LumixSyncControlService.sessionHost !== LumixSyncControlService.normalizeHost(host)) {
      return false;
    }
    // accctrl 授权是有有效期的（实测约 60 秒，见复核报告 §14）。缓存标记若不
    // 设时效，后续 ensureControlSession 会直接短路、一次 req_acc 都不发，而相机
    // 早已收回授权——表现就是 BLE 动作模式被 b0=1 拒绝。
    // 2026-10-23 11:02 日志：上一次成功授权在 02:10，02:59 配对时整段没有任何
    // req_acc 记录，三次 writeActionMode 全部收到 b0=1。
    const ageMs = LumixSyncControlService.accessGrantAt > 0
      ? Date.now() - LumixSyncControlService.accessGrantAt : Number.MAX_SAFE_INTEGER;
    if (ageMs > 50000) {
      LumixSyncControlService.logInfo(`control session stale ageMs=${ageMs}; req_acc will be re-sent`);
      return false;
    }
    return true;
  }

  /** 最近一次被相机接受的模式切换；空串表示还没成功切过（或已失效）。 */
  static currentMode(): string {
    return LumixSyncControlService.lastAcceptedMode;
  }

  /** 会话重建/断开后模式认知失效，必须清掉，否则会跳过必要的模式切换。 */
  static forgetMode(): void {
    LumixSyncControlService.lastAcceptedMode = '';
  }

  /**
   * Returns the active camera session identifier only for the camera that
   * negotiated it. Callers add it to HTTP requests but never log or persist it.
   */
  static sessionIdForHost(host: string): string {
    return LumixSyncControlService.hasControlSession(host)
      ? LumixSyncControlService.sessionId : '';
  }

  static clearControlSession(): void {
    LumixSyncControlService.sessionId = '';
    LumixSyncControlService.sessionHost = '';
    LumixSyncControlService.sessionActive = false;
    LumixSyncControlService.lastAcceptedMode = '';
  }

  /**
   * 上次 req_acc 被相机接受的时间戳。
   *
   * ZS300 只回 4 个字段、不给 X-SESSION_ID，授权靠 IP 维持且**按时间过期**：
   * 2026-10-21 10:03 日志里 req_acc 后 3 秒缩略图正常，75 秒后原图 GET 断连
   * （http=0），95 秒后 Browse 回 403。所以长会话必须提前续，而不是等失败。
   */
  private static accessGrantAt: number = 0;

  /** req_acc 结果的统一记账点，避免三处调用各写一遍时间戳。 */
  private static rememberAccessGrant(accepted: boolean): void {
    if (accepted) {
      LumixSyncControlService.accessGrantAt = Date.now();
    }
  }

  /**
   * 授权是否仍然新鲜。相机没有公开过期时间，50 秒是保守取值：公开实现记录
   * 官方应用约每 60 秒重复一次 req_acc。窗口内不发任何请求。
   */
  static async ensureAccessGrantFresh(context: common.UIAbilityContext, host: string,
    maxAgeMs: number = 50000): Promise<boolean> {
    if (LumixSyncControlService.accessGrantAt > 0 &&
      Date.now() - LumixSyncControlService.accessGrantAt < maxAgeMs) {
      return true;
    }
    const refreshed = await LumixSyncControlService.refreshAccessGrant(context, host);
    return refreshed;
  }

  /**
   * Full connect leg: BLE pairing handshake, then the camera Wi-Fi join.
   * The GATT link is released once the credentials have been read because
   * the Sync control plane only needs the Wi-Fi network afterwards.
   */
  static async pairAndConnect(context: common.UIAbilityContext, deviceId: string,
    onStatus: (message: string) => void = (_message: string): void => {},
    withControlDance: boolean = false,
    directSsid: string = '', directPassword: string = ''): Promise<LumixSyncPairResult> {
    const trace: string[] = [];
    const fail = (message: string): LumixSyncPairResult => {
      LumixSyncControlService.logWarn(`pair failed: ${message}`);
      LumixSyncControlService.dumpTrace(trace);
      return { ok: false, message: message, ssid: '', gateway: '', aps: false, password: '' };
    };
    if (deviceId.length === 0) return fail('未发现相机蓝牙，请保持相机蓝牙开启后重试');
    LumixSyncControlService.logInfo('pair start');
    onStatus('正在连接相机蓝牙…');
    let gatt: ble.GattClientDevice | undefined = undefined;
    // Keep watching the link for the whole handshake: the connect helper
    // removes its own listener once state=2 arrives, and without this
    // monitor a silent drop during discovery reads as a plain timeout
    // (2026-09-24: ten getServices timeouts with no disconnect evidence).
    let dropped = false;
    let monitor: ((change: ble.BLEConnectionChangeState) => void) | undefined = undefined;
    // e182ec43 push latches, diagnostics only: the 2026-09-24 capture
    // proves a fresh pairing session delivers no push here before the
    // credential reads, so nothing in the flow gates on pairReady anymore.
    let pairReady = false;
    // The same characteristic also pushes value[0]=1 or 4 (the Wi-Fi
    // connect-type request, jadx i5/g.java "b10 == 1 || b10 == 4"); record
    // it so the trace shows whether the camera asked before we answered.
    let modePushSeen = false;
    // 18345be1 push latch: set when the camera acknowledges the {0x03}
    // connect-type write; first byte decides the answer (1 -> {0x01}).
    let staConfirmValue = -1;
    // e182ec41 push latch: value[0]=1 means the camera rejected the
    // action-mode request (no accctrl vouch) — fatal for the pairing.
    let controlRejected = false;
    // e182ec41 push value latch (-1 = none yet): 0 = control mode granted
    // after the post-entry req_acc refresh, 1 = rejected.
    let controlModePushValue = -1;
    let valueMonitor: ((data: ble.BLECharacteristic) => void) | undefined = undefined;
    const attachMonitor = (client: ble.GattClientDevice): void => {
      const handler = (change: ble.BLEConnectionChangeState): void => {
        if (change.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
          dropped = true;
          trace.push('GATT dropped mid-pairing');
          LumixSyncControlService.logWarn(`pair GATT dropped device=${change.deviceId}`);
        }
      };
      monitor = handler;
      client.on('BLEConnectionStateChange', handler);
    };
    const attachValueMonitor = (client: ble.GattClientDevice): void => {
      const handler = (data: ble.BLECharacteristic): void => {
        const uuid = data.characteristicUuid.toLowerCase();
        const value = new Uint8Array(data.characteristicValue);
        const first = value.length > 0 ? value[0] : -1;
        trace.push(`notify-rx ${uuid} len=${value.length} b0=${first}`);
        LumixSyncControlService.logInfo(`pair notify-rx ${uuid} len=${value.length} b0=${first}`);
        if (uuid === UUID_SYNC_PAIR_STATUS && value.length > 0) {
          if (value[0] === 3) {
            pairReady = true;
            LumixSyncControlService.logInfo('pair ready signal received');
          } else if (value[0] === 1 || value[0] === 4) {
            modePushSeen = true;
            LumixSyncControlService.logInfo(`pair connect-type request b0=${value[0]}`);
          }
        }
        if (uuid === UUID_SYNC_STA_RESULT && value.length > 0) {
          staConfirmValue = value[0];
          LumixSyncControlService.logInfo(`pair sta-confirm push b0=${staConfirmValue}`);
        }
        if (uuid === UUID_SYNC_MODE_RESULT && value.length > 0) {
          controlModePushValue = value[0];
          if (value[0] === 1) {
            controlRejected = true;
            LumixSyncControlService.logWarn('pair control-mode rejected b0=1');
          } else {
            LumixSyncControlService.logInfo(`pair control-mode push b0=${value[0]}`);
          }
        }
      };
      valueMonitor = handler;
      try { client.on('BLECharacteristicChange', handler); } catch (_error) { }
    };
    // Bounded poll for a camera push latch (the sta-confirm push arrives
    // ~200 ms after the {0x03} connect-type write in the 2026-09-25
    // trace; 5 s covers a slow camera without hanging the whole pairing.
    const waitForLatch = async (label: string, probe: () => boolean, timeoutMs: number): Promise<boolean> => {
      const deadline = Date.now() + timeoutMs;
      while (!probe()) {
        if (Date.now() >= deadline) {
          trace.push(`${label} latch timeout=${timeoutMs}ms`);
          LumixSyncControlService.logWarn(`pair ${label} latch timeout`);
          return false;
        }
        await LumixImportPrototype.delay(100);
      }
      return true;
    };
    const teardown = (): void => {
      if (!gatt) return;
      if (monitor) {
        try { gatt.off('BLEConnectionStateChange', monitor); } catch (_error) { }
        monitor = undefined;
      }
      if (valueMonitor) {
        try { gatt.off('BLECharacteristicChange', valueMonitor); } catch (_error) { }
        valueMonitor = undefined;
      }
      try { gatt.disconnect(); } catch (_error) { }
      try { gatt.close(); } catch (_error) { }
      gatt = undefined;
    };
    try {
      // The unfiltered low-latency scan competes with the GATT link for
      // controller time and the real app never scans while connecting.
      // Stop it and hold it down for the whole handshake.
      LumixImportPrototype.stopCameraDiscovery();
      LumixImportPrototype.setDiscoverySuspended(true);
      // Warm the Wi-Fi radio in parallel with the GATT handshake: the camera's
      // pairing window is already ticking, and a warm scan list removes the
      // radio-enable + first-scan latency from the join leg.
      LumixImportPrototype.warmWifiRadio().catch((): void => {});
      // Direct-reconnect fast path (official 高速起動, HomeActivity: BLE
      gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
      let client: ble.GattClientDevice = gatt;
      attachMonitor(client);
      LumixSyncControlService.logInfo('pair step connect done');
      let services = await LumixSyncControlService.discoverSyncServices(client, trace);
      if (services.length === 0 && !dropped) {
        // A wedged first client can hold an empty GATT table forever; the
        // FAQ-blessed recovery is a fresh client after closing the old one.
        LumixSyncControlService.logWarn('pair services empty; retrying once on a fresh GATT client');
        trace.push('services empty; fresh reconnect');
        teardown();
        await LumixImportPrototype.delay(800);
        gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
        client = gatt;
        attachMonitor(client);
        services = await LumixSyncControlService.discoverSyncServices(client, trace);
      }
      if (services.length === 0 && dropped) {
        return fail('相机蓝牙连接已中断，请靠近相机后重试');
      }
      // Register the notify set BEFORE the identity writes (2026-09-25
      // trace: the ten-CCCD burst lands ~600 ms before writeUuid). The
      // 2026-09-27 regprobe capture settled the earlier dispute: the
      // official app's ten notify attempts ALL fail No_Descriptor and it
      // never writes a single CCCD during fresh registration — but the
      // camera tolerates HarmonyOS's platform-managed CCCD writes (the
      // 2026-09-25 pairing worked with them), so the local subscribe
      // stays for the optional dance pushes below.
      attachValueMonitor(client);
      await LumixSyncControlService.registerSyncNotifications(client, services, trace);
      await LumixImportPrototype.delay(600);
      const characteristics = LumixSyncControlService.indexSyncCharacteristics(services);
      if (!characteristics.wifiSsid || !characteristics.wifiPassword) {
        return fail('相机未暴露 LUMIX Sync 配对特征，无法获取 Wi-Fi 信息');
      }
      if (!characteristics.dlnaUuidLegacy && !characteristics.dlnaUuidAps) {
        return fail('相机未暴露 LUMIX Sync 配对标识特征');
      }
      const identity = await LumixSyncControlService.persistentSyncIdentity(context);
      trace.push(`identity=${identity.dotted}`);
      const identityBytes = LumixSyncControlService.uuidBytesFromString(identity.hex);
      const isAps = characteristics.dlnaUuidAps !== undefined && characteristics.friendlyNameAps !== undefined;
      let keyBytes = Uint8Array.from(SYNC_DEFAULT_KEY);
      if (isAps) {
        onStatus('正在读取配对密钥…');
        const apsKey = await LumixSyncControlService.stepWithTimeout<Uint8Array>('sessionKey',
          (): Promise<Uint8Array> => LumixSyncControlService.readSessionKey(client, characteristics, trace), 5000, trace);
        if (!apsKey) return fail('读取会话密钥未完成');
        keyBytes = apsKey;
        onStatus('正在注册设备标识（APS）…');
        const wroteUuid = await LumixSyncControlService.stepWithTimeout<boolean>('writeUuid', async (): Promise<boolean> => {
          await LumixImportPrototype.writeGatt(client, characteristics.dlnaUuidAps,
            LumixSyncControlService.encodeApsBlock(identityBytes, keyBytes, true), trace);
          return true;
        }, 5000, trace);
        if (wroteUuid !== true) return fail('写入设备标识未完成');
        await LumixImportPrototype.delay(300);
        const wroteName = await LumixSyncControlService.stepWithTimeout<boolean>('writeName', async (): Promise<boolean> => {
          await LumixImportPrototype.writeGatt(client, characteristics.friendlyNameAps,
            LumixSyncControlService.encodeApsBlock(LumixSyncControlService.asciiBytes(SYNC_FRIENDLY_NAME), keyBytes, false), trace);
          return true;
        }, 5000, trace);
        if (wroteName !== true) return fail('写入设备名称未完成');
      } else {
        onStatus('正在注册设备标识…');
        // Legacy bodies take the plaintext 16-byte MEI0 identity first; the
        // official app chains the friendly-name write on the identity write
        // callback (onServicesDiscovered -> q1(1, b(ctx)), then
        // onCharacteristicWrite 8d08a420 -> r1(2, c(ctx))).
        const wroteUuid = await LumixSyncControlService.stepWithTimeout<boolean>('writeUuid', async (): Promise<boolean> => {
          await LumixImportPrototype.writeGatt(client, characteristics.dlnaUuidLegacy, identityBytes, trace);
          return true;
        }, 5000, trace);
        if (wroteUuid !== true) return fail('写入设备标识未完成');
        await LumixImportPrototype.delay(300);
        const wroteName = await LumixSyncControlService.stepWithTimeout<boolean>('writeName', async (): Promise<boolean> => {
          await LumixImportPrototype.writeGatt(client, characteristics.friendlyNameLegacy,
            LumixSyncControlService.asciiBytes(SYNC_FRIENDLY_NAME), trace);
          return true;
        }, 5000, trace);
        if (wroteName !== true) return fail('写入设备名称未完成');
      }
      await LumixImportPrototype.delay(300);
      // Credential read order follows the 2026-09-25 working-pairing
      // trace and the official e-layer sequence z#35 -> z#5 -> z#6:
      // INITIAL_INFORM (session key) first, then the SSID, then the
      // password, straight after the friendly-name write.
      let ssid = '';
      let password = '';
      // Direct-reconnect fast path (official 高速起動): start only AFTER the
      // BLE handshake - the camera SoftAP broadcasts once pairing completes,
      // so a join launched earlier burns its whole scan window on an empty
      // band (the registered-camera restart symptom). Credentials are read in
      // parallel so a missed join falls through with zero extra latency, and
      // the stored password replaces the previous empty-key join.
      let directMode = false;
      let preJoinEntrySent = false;
      let wifi: WifiConnection = { connected: false, ssid: '', gateway: '', ipAddress: '' };
      let directJoin: Promise<WifiConnection> | null = null;
      let credentialsPromise: Promise<string> | null = null;
      const readCredentials = async (): Promise<string> => {
        if (!isAps) {
          onStatus('正在读取配对密钥…');
          const legacyKey = await LumixSyncControlService.stepWithTimeout<Uint8Array>('sessionKey',
            (): Promise<Uint8Array> => LumixSyncControlService.readSessionKey(client, characteristics, trace), 5000, trace);
          if (!legacyKey) return '读取会话密钥未完成';
          keyBytes = legacyKey;
        }
        const ssidValue = await LumixSyncControlService.stepWithTimeout<ArrayBuffer>('readSsid',
          (): Promise<ArrayBuffer> => LumixImportPrototype.readGatt(client, characteristics.wifiSsid, trace), 5000, trace);
        if (!ssidValue) return '读取 Wi-Fi 名称未完成';
        const candidate = LumixSyncControlService.firstSsidEntry(LumixSyncControlService.decodeUtf8(ssidValue));
        if (candidate.length === 0) return '相机未返回 Wi-Fi 名称';
        const passwordValue = await LumixSyncControlService.stepWithTimeout<ArrayBuffer>('readPassword',
          (): Promise<ArrayBuffer> => LumixImportPrototype.readGatt(client, characteristics.wifiPassword, trace), 5000, trace);
        if (!passwordValue) return '读取 Wi-Fi 密码未完成';
        // An empty decode is VALID: the S5 SoftAP is open and the official
        // app joins it without a passphrase (M5/d.z builds the specifier
        // with no key when the decoded password is "" — the capture's
        // key-repeat pattern decodes to exactly that).
        ssid = candidate;
        password = LumixSyncControlService.decodeWifiPassword(passwordValue, keyBytes);
        return '';
      };
      if (directSsid.length > 0) {
        LumixSyncControlService.logInfo(`pair direct rejoin start ssid=${directSsid}`);
        onStatus('正在直连已配对相机 Wi-Fi…');
        directJoin = LumixImportPrototype.connectWifi(directSsid, directPassword, trace, 2,
          (_attempt: number): void => {
            onStatus(_attempt <= 1
              ? '手机即将弹出「信任此 Wi-Fi 连接」确认框，请在 30 秒内点击「信任」'
              : '相机 Wi-Fi 尚未连上，将再次弹出系统确认框，请尽快点击「信任」');
          }, 15000);
        directJoin.catch((): void => {});
        // 与直连并行读取凭据：直连 miss 时下方零等待复用；直连成功时该
        // 读取结果不再使用，附加 catch 防止迟到的拒绝成为未处理异常。
        credentialsPromise = readCredentials();
        credentialsPromise.catch((): void => {});
      }
      if (directJoin !== null) {
        const directWifi = await directJoin;
        directJoin = null;
        if (directWifi.connected && directWifi.gateway.length > 0) {
          // Stored-SSID join won the race: the credential read is redundant
          // here (the entry phase below re-reads session key + SSID +
          // password before its writes anyway) and the stored SSID is by
          // definition the one this camera advertised at pairing time.
          directMode = true;
          wifi = directWifi;
          ssid = directSsid;
          password = directPassword;
          LumixSyncControlService.logInfo(`pair direct rejoin ok gateway=${directWifi.gateway}`);
        } else {
          trace.push('direct rejoin failed; falling back to credential read');
          LumixSyncControlService.logWarn('pair direct rejoin failed; falling back to full pairing');
        }
      }
      if (!directMode) {
        onStatus('正在读取相机 Wi-Fi 信息…');
        // 直连与凭据读取并行：直连 miss 时这里通常已经就绪，零等待。
        const readError = credentialsPromise ? await credentialsPromise : await readCredentials();
        if (readError.length > 0) return fail(readError);
      }
      // 持久化直连凭据（SSID + 密码），下次 direct 直连不再传空密码。
      LumixSyncControlService.persistSyncCredentials(context, deviceId, ssid, password).catch((): void => {});
      // The GATT link stays open through the Wi-Fi join and the req_acc
      // polls (plus the optional control dance below - its writes and
      // the 18345be1 push need the live link); teardown happens at the end.
      if (!directMode) {
        onStatus('正在连接相机 Wi-Fi…');
        // 1) 短窗口直连：已注册相机在握手后约 10 秒内自行拉起 SoftAP
        //    （官方抓包中 LXnetif=wlan0 就在凭据读取后数秒出现）。此段
        //    只做一次尝试，主要探测 AP 是否已经开始广播；命中即省掉
        //    后续唤醒与长扫描。
        const quickMark = trace.length;
        const quick: WifiConnection = await LumixImportPrototype.connectWifi(ssid, password, trace, 1,
          (_attempt: number): void => {
            onStatus('手机即将弹出「信任此 Wi-Fi 连接」确认框，请在 30 秒内点击「信任」');
          }, 20000);
        if (quick.connected && quick.gateway.length > 0) {
          wifi = quick;
        } else {
          // 2) 短窗口内 AP 从未被扫到（已注册相机重启症状：相机侧不
          //    自行拉起 SoftAP，2026-09-28 09:41 实机复现）：用官方控制
          //    模式入口的唤醒写入把相机拉进 SoftAP 模式（g-layer
          //    r1#11 {0x01} -> r1#4 {0x03}，09-26/09-27 官方抓包）。只有
          //    已注册相机会接受；被拒绝时静默回落到长扫描，不影响全新
          //    注册流程（全新注册走相机侧确认，不受此写入影响）。
          const apSeen = !trace.slice(quickMark).some((line: string): boolean => line.includes('relation=UNRESOLVED'));
          if (!apSeen && !withControlDance && !isAps &&
            characteristics.wifiConnectType && characteristics.actionMode) {
            onStatus('相机 Wi-Fi 尚未广播，正在通过蓝牙唤醒相机 Wi-Fi…');
            // The identity writes happened ~20 s ago (the quick scan above
            // doubles as the official 19 s / 34 s settling gap), so the
            // camera BLE side already has the registration in hand.
            for (let entryAttempt = 1; entryAttempt <= 3; entryAttempt++) {
              controlRejected = false;
              controlModePushValue = -1;
              if (entryAttempt > 1) {
                trace.push(`pre-join wake retry #${entryAttempt}`);
                onStatus(`相机未就绪，10 秒后重试唤醒（第 ${entryAttempt} 次）…`);
                await LumixImportPrototype.delay(10000);
              }
              const wakeError = await readCredentials();
              if (wakeError.length > 0) {
                trace.push(`pre-join wake credential re-read failed: ${wakeError}`);
                break;
              }
              const wakeConnect = await LumixSyncControlService.stepWithTimeout<boolean>('writeConnectTypeSoftap', async (): Promise<boolean> => {
                await LumixImportPrototype.writeGatt(client, characteristics.wifiConnectType,
                  Uint8Array.from([0x01]), trace);
                return true;
              }, 5000, trace);
              if (wakeConnect !== true) {
                trace.push('pre-join wake connect-type write failed');
                break;
              }
              const wakeMode = await LumixSyncControlService.stepWithTimeout<boolean>('writeActionMode', async (): Promise<boolean> => {
                await LumixImportPrototype.writeGatt(client, characteristics.actionMode,
                  Uint8Array.from([0x03]), trace);
                return true;
              }, 5000, trace);
              if (wakeMode !== true) {
                trace.push('pre-join wake action-mode write failed');
                break;
              }
              await LumixImportPrototype.delay(1500);
              if (!controlRejected) {
                preJoinEntrySent = true;
                onStatus('相机 Wi-Fi 已唤醒，正在扫描并连接…');
                break;
              }
              LumixSyncControlService.logWarn(`pair pre-join wake rejected attempt=${entryAttempt}`);
            }
          }
          // 3) 长窗口连接：唤醒后相机 SoftAP 启动约需 10 秒，落在窗口内。
          const traceMark = trace.length;
          const fresh: WifiConnection = await LumixImportPrototype.connectWifi(ssid, password, trace, 3,
            (attempt: number): void => {
              onStatus(attempt <= 1
                ? '手机即将弹出「信任此 Wi-Fi 连接」确认框，请在 30 秒内点击「信任」'
                : `相机 Wi-Fi 尚未连上，将再次弹出系统确认框（第 ${attempt} 次），请尽快点击「信任」`);
            }, 150000);
          if (!fresh.connected || fresh.gateway.length === 0) {
            // A scan that never saw the AP (fresh camera reboot / SoftAP not up
            // yet - 2026-09-27 13:33) needs a different hint than a missed
            // trust-dialog tap. connectWifi marks the scan-miss case in trace;
            // slice from the mark so a failed direct rejoin above cannot color
            // this verdict.
            const scanMissed = trace.slice(traceMark).some((line: string): boolean => line.includes('relation=UNRESOLVED'));
            return fail(scanMissed
              ? '相机 Wi-Fi 未响应：相机可能刚从休眠中唤醒，或上一个连接尚未释放（需 1-2 分钟）。请稍候后点「重试」；若仍失败，可半按相机快门唤醒相机后再试'
              : '相机 Wi-Fi 连接未完成：请在手机弹出「信任此 Wi-Fi」确认框时尽快点击「信任」，然后重试');
          }
          wifi = fresh;
        }
      }
      // The control-mode entry below resets the camera SoftAP; the finisher
      // re-joins and updates this so the returned gateway stays current.
      let activeWifi: WifiConnection = wifi;
      if (!isAps) {
        // req_acc IS the registration commit. The 2026-09-27 official
        // fresh-registration capture (zero-registered camera, wiped app)
        // shows the whole pairing ends right here: first answer
        // ok_under_research, re-send ~1 s later (the poll loop inside),
        // second answer ok - no credential re-read, no STA-SSID write,
        // no connect-type SoftAP restart, no action mode, no device_name
        // setsetting.
        onStatus('正在请求相机控制授权…');
        const preAcc = await LumixSyncControlService.ensureControlSession(context, wifi.gateway, onStatus,
          40, undefined, 40, true);
        if (!preAcc.ok) {
          return fail(preAcc.message);
        }
        // The 2026-09-25 confirmation dance below is the CONTROL-MODE
        // entry phase (the official app runs it ~20 s AFTER the
        // registration commit - 09-26 capture: req_acc ok 09:56:32,
        // action_mode 09:56:52). Sending it inside a fresh registration
        // is what the zero-registered camera rejected, so it only runs
        // behind the opt-in withControlDance flag now.
        if (withControlDance) {
          // The official app re-reads the credentials after the vouch and
          // before the dance (2026-09-25 trace: req_acc ok ->
          // sessionKey/readSsid/readPassword again -> dance), because the
          // STA-SSID confirmation write must carry the currently linked
          // SSID and the password decode needs the fresh session key.
          const retryError = await readCredentials();
          if (retryError.length > 0) return fail(retryError);
          if (!characteristics.staSsid || !characteristics.wifiConnectType || !characteristics.actionMode) {
            return fail('相机未暴露 LUMIX Sync 确认特征');
          }
          onStatus('正在登记注册信息…');
          const staSsidOk = await LumixSyncControlService.stepWithTimeout<boolean>('writeStaSsid', async (): Promise<boolean> => {
            await LumixImportPrototype.writeGatt(client, characteristics.staSsid,
              LumixSyncControlService.ssidConfirmBytes(ssid), trace);
            return true;
          }, 5000, trace);
          if (staSsidOk !== true) return fail('写入 Wi-Fi 确认未完成');
          // {0x03} connect-type restarts the camera SoftAP; wait for the
          // 18345be1 push (b0=1 SoftAP live, b0=0 would mean STA) before
          // answering.
          const connectStart = await LumixSyncControlService.stepWithTimeout<boolean>('writeConnectTypeStart', async (): Promise<boolean> => {
            await LumixImportPrototype.writeGatt(client, characteristics.wifiConnectType,
              Uint8Array.from([0x03]), trace);
            return true;
          }, 5000, trace);
          if (connectStart !== true) return fail('写入连接类型未完成');
          const staConfirm = await waitForLatch('staConfirm', (): boolean => staConfirmValue >= 0, 5000);
          if (!staConfirm) return fail('相机未确认 Wi-Fi 切换');
          const connectAnswer = await LumixSyncControlService.stepWithTimeout<boolean>('writeConnectTypeAnswer', async (): Promise<boolean> => {
            await LumixImportPrototype.writeGatt(client, characteristics.wifiConnectType,
              Uint8Array.from(staConfirmValue === 0 ? [0x02] : [0x01]), trace);
            return true;
          }, 5000, trace);
          if (connectAnswer !== true) return fail('写入连接类型应答未完成');
          const actionMode = await LumixSyncControlService.stepWithTimeout<boolean>('writeActionMode', async (): Promise<boolean> => {
            await LumixImportPrototype.writeGatt(client, characteristics.actionMode,
              Uint8Array.from([0x03]), trace);
            return true;
          }, 5000, trace);
          if (actionMode !== true) return fail('写入控制模式未完成');
          await LumixImportPrototype.delay(1500);
          if (controlRejected) return fail('相机已拒绝控制模式请求');
          // The SoftAP restart invalidates the accctrl session on the camera
          // side, so clear it and let the second poll re-register - the
          // 2026-09-25 trace shows req_acc ok twice, ~65 s apart, the gap
          // being the ~41 s beacon outage plus the auto-rejoin. The phone
          // reconnects to the saved network on its own; the widened 40-attempt
          // window (~150 s with connect failures) rides out the outage.
          LumixSyncControlService.clearControlSession();
          onStatus('相机正在重启 Wi-Fi，等待控制会话…');
          const postAcc = await LumixSyncControlService.ensureControlSession(context, wifi.gateway, onStatus, 40);
          if (!postAcc.ok) {
            return fail(postAcc.message);
          }
          // Registration finisher: mode=setsetting device_name, sent right
          // before the e182ec41 {0x00} activation push in the 2026-09-25
          // capture. Best effort - the session stays usable without it.
          await LumixSyncControlService.setDeviceName(wifi.gateway);
        } else if (!preJoinEntrySent) {
          // Official control-mode entry (09-26 09:56:51-53, 09-27
          // 11:10:31-33: g-layer R0#35/R0#5/R0#6 -> r1#11 {0x01} ->
          // r1#4 {0x03}): re-read the credentials, answer the connect
          // type with SoftAP {0x01} - no {0x03} SoftAP restart, no
          // STA-SSID confirmation, no 18345be1 push wait - then write
          // action mode {0x03}.
          // Skipped when the pre-join wake already sent these writes
          // (the camera is already in SoftAP + app-linked mode; a second
          // round would needlessly restart the SoftAP and force a ~40 s
          // outage, and the req_acc above already holds the session).
          if (!characteristics.wifiConnectType || !characteristics.actionMode) {
            // Registration stands alone when the entry characteristics
            // are absent - camcmd will report its own error later.
            LumixSyncControlService.logWarn('pair control entry skipped: characteristics missing');
          } else {
            // Settling gap: both official captures pause between the
            // req_acc commit and the entry writes (19 s / 34 s - user
            // navigation, but the only accepted gaps on record). VIVID's
            // 2 s gap on 2026-09-27 10:54 drew the b0=1 rejection push
            // within 24 ms of the action-mode write: the camera's BLE
            // side had not picked up the just-committed registration.
            onStatus('正在准备相机控制模式（约 20 秒）…');
            await LumixImportPrototype.delay(20000);
            let entryAccepted = false;
            for (let entryAttempt = 1; entryAttempt <= 3; entryAttempt++) {
              controlRejected = false;
              controlModePushValue = -1;
              if (entryAttempt > 1) {
                trace.push(`control entry retry #${entryAttempt}`);
                onStatus(`相机未就绪，10 秒后重试控制模式请求（第 ${entryAttempt} 次）…`);
                await LumixImportPrototype.delay(10000);
              }
              const entryError = await readCredentials();
              if (entryError.length > 0) return fail(entryError);
              const connectAnswer = await LumixSyncControlService.stepWithTimeout<boolean>('writeConnectTypeSoftap', async (): Promise<boolean> => {
                await LumixImportPrototype.writeGatt(client, characteristics.wifiConnectType,
                  Uint8Array.from([0x01]), trace);
                return true;
              }, 5000, trace);
              if (connectAnswer !== true) return fail('写入连接类型未完成');
              const actionMode = await LumixSyncControlService.stepWithTimeout<boolean>('writeActionMode', async (): Promise<boolean> => {
                await LumixImportPrototype.writeGatt(client, characteristics.actionMode,
                  Uint8Array.from([0x03]), trace);
                return true;
              }, 5000, trace);
              if (actionMode !== true) return fail('写入控制模式未完成');
              await LumixImportPrototype.delay(1500);
              if (!controlRejected) {
                entryAccepted = true;
                break;
              }
              LumixSyncControlService.logWarn(`pair control-mode rejected attempt=${entryAttempt}`);
            }
            if (!entryAccepted) return fail('相机已拒绝控制模式请求');
            // The entry writes reset the camera SoftAP link: on 2026-09-27
            // the phone left S5 within seconds of the 11:35:53 writes and
            // every refresh poll came back empty until the camera withdrew
            // the grant (b0=1 at 11:38:34, 2 m 41 s later). Official always
            // re-joins Wi-Fi after the entry (the 11:11:04 "connect Wi-Fi"
            // leg) before the req_acc refresh - do the same here. The
            // disassociation lands seconds AFTER the writes though (19:52
            // session: rejoin short-circuited on the still-linked dying AP
            // after 6 ms and returned a stale gateway), so first wait for
            // the link to actually drop before scanning again.
            const linkDropped = await LumixImportPrototype.waitCameraLinkDrop(ssid, 12000);
            if (!linkDropped) {
              trace.push('rejoin: camera link still up after entry; proceeding');
              LumixSyncControlService.logWarn('pair rejoin: camera link did not drop after entry writes');
            }
            const rejoin: WifiConnection = await LumixImportPrototype.connectWifi(ssid, password, trace, 3,
              (attempt: number): void => {
                onStatus(attempt <= 1
                  ? '相机 Wi-Fi 已切换，正在重新连接（如弹出「信任此 Wi-Fi 连接」确认框，请点击「信任」）…'
                  : `相机 Wi-Fi 尚未连上，将再次弹出系统确认框（第 ${attempt} 次），请尽快点击「信任」`);
              }, 150000);
            if (!rejoin.connected || rejoin.gateway.length === 0) {
              const scanMissed = trace.some((line: string): boolean => line.includes('relation=UNRESOLVED'));
              return fail(scanMissed
                ? '入场后未重新扫描到相机 Wi-Fi：请保持手机靠近相机，重试一次配对'
                : '相机 Wi-Fi 连接未完成：请在手机弹出「信任此 Wi-Fi」确认框时尽快点击「信任」，然后重试');
            }
            activeWifi = rejoin;
            // Official finisher (2026-09-27 11:11:04-09): refresh the
            // accctrl session (req_acc x2: ok_under_research_no_msg ->
            // ok), send setsetting device_name, and the camera answers
            // with the e182ec41 {0x00} activation push ~200 ms later.
            LumixSyncControlService.clearControlSession();
            onStatus('正在激活相机控制模式…');
            const postEntry = await LumixSyncControlService.ensureControlSession(context, activeWifi.gateway, onStatus, 40,
              (): boolean => controlRejected, 12, false, true);
            if (!postEntry.ok) {
              return fail(postEntry.message);
            }
            await LumixSyncControlService.setDeviceName(activeWifi.gateway);
            const activated = await waitForLatch('controlActive', (): boolean => controlModePushValue === 0, 3000);
            if (!activated) {
              // Official cannot see pushes at all (zero CCCD) and still
              // proceeds; treat a missing push as soft, camcmd will tell.
              LumixSyncControlService.logWarn('pair control-active push not observed');
            }
          }
        }
      }
      // Official connect-time finisher (service/a.java:456 每次连接建立后
      // L("raw_img_send","enable"))：开启后相机在传输中交付原始 RAW
      // （完整 EXIF 含镜头信息）；未开启时 DMS 拉取可能下发精简 RW2
      // （2026-09-28 实机：下载的 RW2 缺镜头信息）。失败不致命。
      const rawSend = await LumixSyncControlService.sendCamSetting(activeWifi.gateway, 'raw_img_send', 'enable');
      if (!rawSend.ok) {
        LumixSyncControlService.logWarn(`raw_img_send enable failed: ${rawSend.message}`);
      }
      teardown();
      // Persist the working SoftAP SSID + the BLE address it belongs to so
      // the next control tap can take the direct-reconnect fast path (the
      // official app stores CurrentConnectedSSID/CurrentConnectedAddress
      // the same way, BluetoothSettingActivity).
      try {
        const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
        await store.put('syncCameraSsid', activeWifi.ssid.length > 0 ? activeWifi.ssid : ssid);
        await store.put('syncCameraBleDeviceId', deviceId);
        await store.flush();
      } catch (_error) { }
      LumixSyncControlService.logInfo(`pair ok ssidLen=${ssid.length} gateway=${activeWifi.gateway} aps=${characteristics.dlnaUuidAps !== undefined}`);
      return { ok: true, message: '相机 Wi-Fi 已连接', ssid: activeWifi.ssid, gateway: activeWifi.gateway, aps: characteristics.dlnaUuidAps !== undefined, password: password };
    } catch (error) {
      const message = error instanceof Error ? error.message : 'LUMIX Sync 配对失败';
      LumixSyncControlService.logWarn(`pair failed: ${message}`);
      LumixSyncControlService.dumpTrace(trace);
      return fail(message);
    } finally {
      teardown();
      LumixImportPrototype.setDiscoverySuspended(false);
    }
  }

  /**
   * accctrl req_acc: poll until the camera leaves its confirmation screen,
   * then keep the fifth CSV element as the X-SESSION_ID for cam.cgi calls.
   * maxAttempts widens the window for the SoftAP restart after the
   * control-mode dance (~41 s beacon gap in the 2026-09-25 capture).
   */
  static async ensureControlSession(context: common.UIAbilityContext, host: string,
    onStatus: (message: string) => void = (_message: string): void => {},
    maxAttempts: number = 40,
    abortProbe?: () => boolean,
    maxEmptyStreak: number = 40,
    pairingCommit: boolean = false,
    entryRefresh: boolean = false): Promise<LumixSyncSessionResult> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0) {
      return { ok: false, message: '相机网关不可用', sessionId: '' };
    }
    if (LumixSyncControlService.hasControlSession(host)) {
      return { ok: true, message: '控制会话已建立', sessionId: LumixSyncControlService.sessionId };
    }
    const identity = await LumixSyncControlService.persistentSyncIdentity(context);
    const path = `/cam.cgi?mode=accctrl&type=req_acc&value=${encodeURIComponent(identity.dotted)}&value2=${encodeURIComponent(SYNC_FRIENDLY_NAME)}`;
    let busyRetries = 0;
    let sawUnderResearch = false;
    let refusedRetries = 0;
    // Dead-network guard: N consecutive empty/failed polls means the phone
    // left the camera AP - polling longer only burns the camera's own
    // grant timeout (2026-09-27 11:35:59-11:39:36, four empty minutes).
    // Default 40 keeps the legacy behaviour (the dance path rides out a
    // ~150 s outage window); the post-entry finisher passes 12 (~70 s).
    let emptyStreak = 0;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      if (abortProbe !== undefined && abortProbe()) {
        return { ok: false, message: '相机已收回控制模式授权', sessionId: '' };
      }
      onStatus(attempt <= 1 ? '正在请求相机控制授权…' : '等待相机确认控制请求…');
      const response = await LumixSyncControlService.httpGet(safeHost, path, '');
      const body = response.body.trim();
      // Full body on every poll: the third CSV element (remote,open/close)
      // and the ok vs ok_under_research split are the two facts the
      // 2026-09-27 rejection diagnosis could not see.
      LumixSyncControlService.logInfo(`req_acc resp=${body}`);
      if (response.code < 200 || response.code >= 300 || body.length === 0) {
        emptyStreak += 1;
        // Fresh-registration commit (2026-09-27 15:26): the camera answers
        // ok_under_research, commits the registration, and immediately
        // restarts its SoftAP - the phone is kicked off mid-poll and every
        // re-send times out. That drop IS the pairing success signal; the
        // caller's settling / BLE entry / Wi-Fi rejoin / refresh chain
        // re-establishes the real session afterwards. One empty poll
        // (a full HTTP timeout) is already proof of the network drop -
        // waiting for a second only burns 6 s.
        if (pairingCommit && sawUnderResearch && emptyStreak >= 1) {
          LumixSyncControlService.logInfo('req_acc committed: under_research then network drop (SoftAP restart)');
          return { ok: true, message: '配对已提交，相机 Wi-Fi 正在重启', sessionId: '' };
        }
        if (emptyStreak >= maxEmptyStreak) {
          return { ok: false, message: '相机网络无响应，请确认手机仍连接相机 Wi-Fi', sessionId: '' };
        }
      } else {
        emptyStreak = 0;
      }
      if (response.code >= 200 && response.code < 300) {
        if (body.startsWith('ok_under_research')) {
          sawUnderResearch = true;
          await LumixImportPrototype.delay(1000);
          continue;
        }
        if (body.startsWith('err_busy')) {
          if (busyRetries >= 5) {
            return { ok: false, message: '相机忙，请稍后重试', sessionId: '' };
          }
          busyRetries += 1;
          await LumixImportPrototype.delay(1000);
          continue;
        }
        if (body.startsWith('err_user_refused')) {
          // Post-entry (17:36:59 trace): the entry dance already succeeded,
          // the camera sits on its Wi-Fi-wait screen, and this refresh poll
          // lands on the camera's post-restart session boundary where it
          // answers err_user_refused even though the mode switch went
          // through. Aborting here strands the camera on the wait screen.
          // Retry like ok_under_research, then give up on the session
          // refresh (not on the activation) - camcmd works without it.
          if (entryRefresh) {
            refusedRetries += 1;
            if (refusedRetries <= 3) {
              LumixSyncControlService.logWarn(`req_acc refused after entry (retry ${refusedRetries}/3)`);
              await LumixImportPrototype.delay(2000);
              continue;
            }
            LumixSyncControlService.logWarn('req_acc refused after entry x3 - continuing without session refresh');
            return { ok: true, message: '已进入控制模式（会话刷新被拒，继续激活）', sessionId: '' };
          }
          // 2026-09-28 10:46 实机：握手 + Wi-Fi 全部成功，req_acc 却回
          // err_user_refused——相机屏幕上的连接确认框未点击「允许」（或
          // 相机仍停留在上一控制画面）。不要立即判死：留出相机侧确认
          // 窗口轮询，期间提示用户操作相机。
          refusedRetries += 1;
          if (refusedRetries <= 6) {
            LumixSyncControlService.logWarn(`req_acc refused by camera (retry ${refusedRetries}/6)`);
            onStatus('相机屏幕上出现连接确认，请在相机上点击「允许」…');
            await LumixImportPrototype.delay(2000);
            continue;
          }
          return {
            ok: false,
            message: '相机端已拒绝控制请求：请在相机屏幕上点击「允许」后重试；若相机停留在上一控制画面，请先按相机 MENU 键退出再试',
            sessionId: ''
          };
        }
        if (body.startsWith('err_others_requesting')) {
          return { ok: false, message: '其他设备正在请求相机，请稍后重试', sessionId: '' };
        }
        if (body.startsWith('err_') || body.startsWith('ret_empty')) {
          return { ok: false, message: `相机未接受控制请求（${body.split(',')[0]}）`, sessionId: '' };
        }
        if (body.startsWith('ok') || body.startsWith('upload_bt') || body.startsWith('transfer')) {
          const sessionId = LumixSyncControlService.sessionIdFromResponse(body);
          LumixSyncControlService.sessionId = sessionId;
          LumixSyncControlService.sessionHost = safeHost;
          LumixSyncControlService.sessionActive = true;
          LumixSyncControlService.logInfo(`req_acc ok sessionIdLen=${sessionId.length}`);
          LumixSyncControlService.rememberAccessGrant(true);
          return { ok: true, message: '控制会话已建立', sessionId: sessionId };
        }
      }
      await LumixImportPrototype.delay(1000);
    }
    return { ok: false, message: '相机控制授权超时，请在相机上确认', sessionId: '' };
  }

  /**
   * 单次 req_acc 续期（不轮询、不等确认）。
   *
   * ZS300 这类机身 req_acc 只回 4 个字段、不给 X-SESSION_ID，授权只靠 IP 维持。
   * 2026-10-21 10:03 上传的日志把窗口量出来了：req_acc 之后 3 秒缩略图正常下载，
   * 75 秒后同一台相机上的原图 GET 直接断连（http=0 bytes=0），95 秒后 Browse
   * 回落 403。这与公开实现记录的「约每 60 秒需要重新配对」一致。
   *
   * 因此下载/预览失败后重发一次 req_acc 再重试，比盲目重试有效。失败不抛错，
   * 只影响本次重试。
   */
  static async refreshAccessGrant(context: common.UIAbilityContext, host: string): Promise<boolean> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0) {
      return false;
    }
    try {
      const identity = await LumixSyncControlService.persistentSyncIdentity(context);
      const path = `/cam.cgi?mode=accctrl&type=req_acc&value=${encodeURIComponent(identity.dotted)}` +
        `&value2=${encodeURIComponent(SYNC_FRIENDLY_NAME)}`;
      const response = await LumixSyncControlService.httpGet(safeHost, path, '');
      const body = response.body.trim();
      const accepted = body.indexOf('ok') === 0;
      const sessionId = accepted ? LumixSyncControlService.sessionIdFromResponse(body) : '';
      if (accepted) {
        LumixSyncControlService.sessionId = sessionId;
      }
      LumixSyncControlService.rememberAccessGrant(accepted);
      LumixSyncControlService.logInfo(
        `req_acc refresh http=${response.code} accepted=${accepted ? 1 : 0} sessionIdLen=${sessionId.length}`);
      return accepted;
    } catch (error) {
      LumixSyncControlService.logWarn(`req_acc refresh failed: ${String(error)}`);
      return false;
    }
  }

  /**
   * mode=setsetting device_name: the registration finisher the official app
   * sends right before the e182ec41 {0x00} activation push (11:17:49.010 ->
   * activation 46 ms later). Failure is not fatal — the control session
   * stays usable, only the name shown on the camera stays stale.
   */
  static async setDeviceName(host: string): Promise<boolean> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0 || !LumixSyncControlService.hasControlSession(host)) {
      return false;
    }
    const path = `/cam.cgi?mode=setsetting&type=device_name&value=${encodeURIComponent(SYNC_FRIENDLY_NAME)}`;
    const response = await LumixSyncControlService.httpGetRetry(safeHost, path);
    const verdict = LumixSyncControlService.replyVerdict(response.body);
    const accepted = response.code >= 200 && response.code < 300 && verdict.startsWith('ok');
    LumixSyncControlService.logInfo(`setsetting device_name verdict=${verdict}`);
    return accepted;
  }

  /**
   * Send one camcmd verb with the session header and the busy retry policy.
   * The verb always travels in value=: every official call site is
   * n(null, "<verb>", null) — B5/a.java:1258 and E5/e.java:72 — so type= stays
   * absent, and a type= parameter draws <result>err_param</result>.
   * B5/n.c(mode, type, value, value2) has exactly four slots and no value3;
   * the previous build emitted &value3= for a fourth argument that no call
   * site ever supplies.
   */
  static async sendCamCmd(host: string, verb: string, value2: string = ''): Promise<LumixSyncCamCmdResult> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0) {
      return { ok: false, message: '相机网关不可用', body: '' };
    }
    if (!LumixSyncControlService.hasControlSession(host)) {
      return { ok: false, message: '控制会话未建立', body: '' };
    }
    let path = `/cam.cgi?mode=camcmd&value=${encodeURIComponent(verb)}`;
    if (value2.length > 0) path += `&value2=${encodeURIComponent(value2)}`;
    // Mode switches need a quiet window after stopstream: sending playmode
    // 1 s after a stream stop stuck the camera err_busy for a full minute
    // (2026-09-27 15:50:55-15:51:53, every camcmd rejected until re-pair).
    if (verb === 'playmode' || verb === 'recmode') {
      const quiet = Date.now() - LumixSyncControlService.lastStreamStopAt;
      if (quiet >= 0 && quiet < 2500) {
        await LumixImportPrototype.delay(2500 - quiet);
      }
    }
    for (let attempt = 0; attempt <= 5; attempt++) {
      const response = await LumixSyncControlService.httpGet(safeHost, path, LumixSyncControlService.sessionId);
      const raw = response.body.trim();
      const verdict = LumixSyncControlService.replyVerdict(raw);
      if (response.code >= 200 && response.code < 300) {
        if (verdict.startsWith('err_busy') && attempt < 5) {
          await LumixImportPrototype.delay(1000);
          continue;
        }
        // recmode/playmode 是幂等的模式切换：相机已在目标模式时回
        // err_reject（2026-09-28 实测：退出控制页走图片传输（被动会话不切
        // 模式）后返回，recmode 被拒 5 次——相机一直在 rec）。官方 App
        // 对 err_reject 不做致命处理，按已就位继续。
        const benignReject = (verb === 'recmode' || verb === 'playmode') &&
          verdict.startsWith('err_reject');
        const accepted = verdict.startsWith('ok') || verdict.indexOf('wifi_reset') >= 0 || benignReject;
        LumixSyncControlService.logInfo(`camcmd value=${verb} verdict=${verdict}`);
        if (accepted && (verb === 'playmode' || verb === 'recmode')) {
          LumixSyncControlService.lastAcceptedMode = verb;
        }
        return { ok: accepted, message: accepted ? 'ok' : `相机返回 ${verdict}`, body: raw };
      }
      if (attempt < 5) {
        await LumixImportPrototype.delay(1000);
        continue;
      }
    }
    return { ok: false, message: '相机无响应', body: '' };
  }

  /**
   * mode=camctrl: Sync 线触屏对焦等控制（官方 B5/a.o() -> n.c("camctrl",
   * type, value, value2)）。touch 用归一化坐标 "x/y"（0-1000）+ value2="on"
   * （官方 i.java 500/500 同型）；af_ae_lock 特判在官方 o() 里走独立
   * 超时通道，此处按通用 err_busy 重试即可。
   */
  static async sendCamCtrl(host: string, type: string, value: string,
    value2: string = ''): Promise<LumixSyncCamCmdResult> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0) {
      return { ok: false, message: '相机网关不可用', body: '' };
    }
    if (!LumixSyncControlService.hasControlSession(host)) {
      return { ok: false, message: '控制会话未建立', body: '' };
    }
    let path = `/cam.cgi?mode=camctrl&type=${encodeURIComponent(type)}&value=${encodeURIComponent(value)}`;
    if (value2.length > 0) {
      path += `&value2=${encodeURIComponent(value2)}`;
    }
    for (let attempt = 0; attempt <= 5; attempt++) {
      const response = await LumixSyncControlService.httpGet(safeHost, path, LumixSyncControlService.sessionId);
      const raw = response.body.trim();
      const verdict = LumixSyncControlService.replyVerdict(raw);
      if (response.code >= 200 && response.code < 300) {
        if (verdict.startsWith('err_busy') && attempt < 5) {
          await LumixImportPrototype.delay(1000);
          continue;
        }
        const accepted = verdict.startsWith('ok');
        LumixSyncControlService.logInfo(`camctrl type=${type} value=${value} verdict=${verdict}`);
        return { ok: accepted, message: accepted ? 'ok' : `相机返回 ${verdict}`, body: raw };
      }
      if (attempt < 5) {
        await LumixImportPrototype.delay(1000);
        continue;
      }
    }
    return { ok: false, message: '相机无响应', body: '' };
  }

  /**
   * mode=startstream: the Sync line's plaintext UDP liveview opener.
   * Official E5/g.c() binds 49152 (+1 on conflict) and B5/a.P() tells the
   * camera the bound port (/cam.cgi?mode=startstream&value=<port>, built by
   * B5/n.c()); the camera then streams Panasonic liveview fragments to
   * phone:<port> over a raw DatagramSocket — no DTLS on this line, and the
   * fragment layout is byte-identical to the Lab line (C2818b: total length
   * [0..1], fragment index [4..7], more-flag [8], 9-byte magic [9..17],
   * frame id [18..21], jpeg total [22..25], jpeg offset [26..29], meta len
   * [30..31], data at 32+metaLen). err_busy retried like P().
   */
  static async startStream(host: string, port: number): Promise<LumixSyncCamCmdResult> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0) {
      return { ok: false, message: '相机网关不可用', body: '' };
    }
    if (!LumixSyncControlService.hasControlSession(host)) {
      return { ok: false, message: '控制会话未建立', body: '' };
    }
    const path = `/cam.cgi?mode=startstream&value=${port}`;
    for (let attempt = 0; attempt <= 5; attempt++) {
      const response = await LumixSyncControlService.httpGet(safeHost, path, LumixSyncControlService.sessionId);
      const raw = response.body.trim();
      const verdict = LumixSyncControlService.replyVerdict(raw);
      if (response.code >= 200 && response.code < 300) {
        if (verdict.startsWith('err_busy') && attempt < 5) {
          await LumixImportPrototype.delay(1000);
          continue;
        }
        const accepted = verdict.startsWith('ok');
        LumixSyncControlService.logInfo(`startstream port=${port} verdict=${verdict}`);
        return { ok: accepted, message: accepted ? 'ok' : `相机返回 ${verdict}`, body: raw };
      }
      if (attempt < 5) {
        await LumixImportPrototype.delay(1000);
        continue;
      }
    }
    return { ok: false, message: '相机无响应', body: '' };
  }

  /** mode=stopstream: best-effort liveview closer (B5/a.R()). */
  static async stopStream(host: string): Promise<void> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0 || !LumixSyncControlService.hasControlSession(host)) {
      return;
    }
    try {
      const response = await LumixSyncControlService.httpGetRetry(safeHost, '/cam.cgi?mode=stopstream');
      LumixSyncControlService.lastStreamStopAt = Date.now();
      LumixSyncControlService.logInfo(`stopstream verdict=${LumixSyncControlService.replyVerdict(response.body)}`);
    } catch (_error) {
    }
  }

  /**
   * cam.cgi replies arrive in two shapes — camrply XML wrapping the verdict
   * (<result>ok</result>, 2026-09-25 captures) or plain CSV (ok,... from the
   * accctrl line). Judging only by body.startsWith('ok') misreads every XML
   * reply as a failure and leaks the XML header into user-visible messages.
   */
  private static replyVerdict(body: string): string {
    const lowered = body.trim().toLowerCase();
    const resultMatch = lowered.match(/<result>([^<]*)<\/result>/);
    if (resultMatch !== null) {
      return resultMatch[1].trim();
    }
    return lowered.split(',')[0].trim();
  }

  /**
   * Platform GATT promises can stall indefinitely when the peripheral never
   * completes a procedure (observed 2026-09-23: the original S5 froze the
   * whole pairing flow right after connect with both status fields stuck at
   * 连接中 and no trace lines at all). Race every step against a timer and
   * log the step name directly to hilog so the stall point is identifiable
   * even when the later trace dump has already rotated out of the buffer.
   */
  private static async stepWithTimeout<T>(label: string, action: () => Promise<T>,
    timeoutMs: number, trace: string[]): Promise<T | undefined> {
    LumixSyncControlService.logInfo(`pair step ${label} start`);
    trace.push(`${label} start`);
    return new Promise<T | undefined>((resolve: (value: T | undefined) => void) => {
      let finished = false;
      let timer: number = -1;
      const settle = (value: T | undefined, note: string): void => {
        if (finished) return;
        finished = true;
        if (timer >= 0) clearTimeout(timer);
        trace.push(note);
        LumixSyncControlService.logInfo(`pair step ${label} ${note}`);
        resolve(value);
      };
      timer = setTimeout((): void => {
        settle(undefined, `timeout=${timeoutMs}ms`);
      }, timeoutMs);
      const run = async (): Promise<void> => {
        try {
          const value = await action();
          settle(value, 'done');
        } catch (error) {
          settle(undefined, `threw code=${LumixImportPrototype.errorCode(error)}`);
        }
      };
      void run();
    });
  }

  /**
   * The real LUMIX Sync app goes straight from connect to discoverServices
   * with the default 23-byte MTU (jadx i5/e.java:487-501) and every Sync
   * payload fits 20 bytes, so no MTU exchange is requested here. The
   * 2026-09-24 trace shows an ATT_EXCHANGE_MTU as the first packet after
   * connect left the original S5 silent: mtu timeout=4000ms followed by ten
   * getServices timeouts with zero services. getServices itself is the
   * asynchronous service-discovery trigger on Harmony (FAQ
   * faqs-connectivity-43), so poll it with a bounded timer until the table
   * is non-empty or the budget expires.
   */
  private static async discoverSyncServices(client: ble.GattClientDevice,
    trace: string[]): Promise<Array<ble.GattService>> {
    let services: Array<ble.GattService> = [];
    for (let attempt = 1; attempt <= 10; attempt++) {
      const table = await LumixSyncControlService.stepWithTimeout<Array<ble.GattService>>(`getServices#${attempt}`,
        (): Promise<Array<ble.GattService>> => client.getServices(), 2500, trace);
      if (table && table.length > 0) {
        services = table;
        trace.push(`getServices attempt=${attempt} services=${services.length}`);
        break;
      }
      trace.push(`getServices attempt=${attempt} empty`);
      await LumixImportPrototype.delay(500);
    }
    // Dump the table (with property flags) so a failed pairing pinpoints
    // exactly what the camera exposed instead of a bare "missing" verdict.
    for (const service of services) {
      trace.push(`service ${service.serviceUuid}`);
      for (const characteristic of service.characteristics) {
        const props = characteristic.properties;
        // W = write-with-response, w = writeNoResponse (separate bits: the
        // Android app always uses WRITE_TYPE_DEFAULT, so the distinction
        // decides which type our writes must mirror).
        const flags = `${props && props.read ? 'R' : ''}${props && props.write ? 'W' : ''}${props && props.writeNoResponse ? 'w' : ''}` +
          `${props && props.notify ? 'N' : ''}${props && props.indicate ? 'I' : ''}`;
        trace.push(`characteristic ${characteristic.characteristicUuid} ${flags}`);
      }
    }
    return services;
  }

  /**
   * Enable the ten-characteristic notify set right after service
   * discovery (2026-09-25 trace: registered=10 missing=0). HarmonyOS
   * writes the 0x2902 CCCD inside setCharacteristicChangeNotification,
   * so each enable is logged as a platform-managed descriptor write.
   */
  private static async registerSyncNotifications(client: ble.GattClientDevice,
    services: Array<ble.GattService>, trace: string[]): Promise<void> {
    let registered = 0;
    let missing = 0;
    const missingUuids: string[] = [];
    for (const uuid of SYNC_NOTIFY_UUIDS) {
      const characteristic = LumixSyncControlService.syncCharacteristicByUuid(services, uuid);
      if (!characteristic) {
        missing += 1;
        missingUuids.push(uuid.substring(0, 8));
        continue;
      }
      const enabled = await LumixSyncControlService.stepWithTimeout<boolean>('notify', async (): Promise<boolean> => {
        await client.setCharacteristicChangeNotification(characteristic, true);
        trace.push(`notify enabled ${uuid}; CCCD=00002902-0000-1000-8000-00805f9b34fb; descriptor write=platform-managed`);
        return true;
      }, 5000, trace);
      if (enabled === true) {
        registered += 1;
      } else {
        missing += 1;
        missingUuids.push(uuid.substring(0, 8));
      }
    }
    LumixSyncControlService.logInfo(`pair notify registered=${registered} missing=${missing}`);
    if (missing > 0) {
      // 只报个数不够：18345be1（SoftAP 生效推送）若没注册上，配对确认推进不下去。
      LumixSyncControlService.logWarn(`pair notify missing uuids=${missingUuids.join(',')}`);
    }
    trace.push(`notify set registered=${registered} missing=${missing}`);
  }

  private static syncCharacteristicByUuid(services: Array<ble.GattService>,
    uuid: string): ble.BLECharacteristic | undefined {
    for (const service of services) {
      for (const characteristic of service.characteristics) {
        if (characteristic.characteristicUuid.toLowerCase() === uuid) {
          return characteristic;
        }
      }
    }
    return undefined;
  }

  /** Lightweight liveness probe for the control page heartbeat. The official
   * heartbeat is getstate with type=keep_alive — F("keep_alive", 5, 1000) in
   * liveview/i.java:3817 and ImageAppTotalService.java:733, and the Image App
   * report line 121 records the same 保活 type. Omitting the type left a bare
   * status read instead of the keep-alive the camera expects. */
  static async pingState(host: string): Promise<boolean> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0 || !LumixSyncControlService.hasControlSession(host)) {
      return false;
    }
    const response = await LumixSyncControlService.httpGetRetry(safeHost,
      '/cam.cgi?mode=getstate&type=keep_alive');
    return response.code >= 200 && response.code < 300;
  }

  /**
   * mode=setsetting: the Sync line's parameter writer (jadx B5/a.L():
   * n.c("setsetting", type, value, value2) over plain HTTP GET). Official
   * drum pickers send iso / shtrspeed / focal (aperture) / exposure (EV) /
   * whitebalance this way; err_busy retried 5 x 1 s like the official f733p
   * =5 / f735r =1000 policy.
   */
  static async sendCamSetting(host: string, type: string, value: string): Promise<LumixSyncCamCmdResult> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0) {
      return { ok: false, message: '相机网关不可用', body: '' };
    }
    if (!LumixSyncControlService.hasControlSession(host)) {
      return { ok: false, message: '控制会话未建立', body: '' };
    }
    // 光圈（focal）线上值 = AV×256 有理数：AV = 2·log2(F)。2026-09-28
    // 实测 getsetting focal = "940/256"（AV 3.672 → F3.6）与镜头
    // F3.5-5.6 吻合；此前误按 F×256 换算，F7.1 发 1818/256 被相机解释
    // 为 AV 7.1 → 实际落到 F11。裸 F 值按 AV×256 换算（F9 → AV 6.34 →
    // 1623/256）；已含 '/' 的相机原生值原样透传。
    let normalizedValue = value;
    if (type === 'focal' && value.toLowerCase() !== 'auto') {
      if (/^\d+(\.\d+)?$/.test(value)) {
        normalizedValue = `${Math.round(2 * Math.log2(parseFloat(value)) * 256)}/256`;
      } else if (!value.includes('/')) {
        normalizedValue = `F${value}`;
      }
    }
    // 2026-09-28 实机：value 必须原样拼接进 URL（官方 B5/n.c() 用
    // String.format("&value=%s")，不编码）。encodeURIComponent 把 -02/3
    // 变成 -02%2F3、+01/3 变成 %2B01%2F3，相机解析失败回 err_param——
    // 只有无特殊字符的 -1 通过；快门 1/400 相机应答 ok 但值匹配不上被
    // 静默忽略（用户侧"快门无效"）。type 保持编码（均为纯词，无差异）。
    const path = `/cam.cgi?mode=setsetting&type=${encodeURIComponent(type)}&value=${normalizedValue}`;
    for (let attempt = 0; attempt <= 5; attempt++) {
      const response = await LumixSyncControlService.httpGet(safeHost, path, LumixSyncControlService.sessionId);
      const raw = response.body.trim();
      const verdict = LumixSyncControlService.replyVerdict(raw);
      if (response.code >= 200 && response.code < 300) {
        if (verdict.startsWith('err_busy') && attempt < 5) {
          await LumixImportPrototype.delay(1000);
          continue;
        }
        const accepted = verdict.startsWith('ok');
        LumixSyncControlService.logInfo(`setsetting type=${type} value=${normalizedValue} verdict=${verdict}`);
        return { ok: accepted, message: accepted ? 'ok' : `相机返回 ${verdict}`, body: raw };
      }
      if (attempt < 5) {
        await LumixImportPrototype.delay(1000);
        continue;
      }
    }
    return { ok: false, message: '相机无响应', body: '' };
  }

  /**
   * mode=getstate with body capture: the control-page heartbeat upgrade over
   * pingState. The first successful body is logged in full so the real tag
   * set / value format of this camera lands in hilog (the 2026-09-27
   * official capture truncated every getstate body at ~170 chars).
   */
  static async fetchSyncState(host: string): Promise<LumixSyncCamCmdResult> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0 || !LumixSyncControlService.hasControlSession(host)) {
      return { ok: false, message: '控制会话未建立', body: '' };
    }
    try {
      const response = await LumixSyncControlService.httpGetRetry(safeHost,
        '/cam.cgi?mode=getstate&type=keep_alive');
      const raw = response.body.trim();
      const ok = response.code >= 200 && response.code < 300 && raw.length > 0;
      if (ok && !LumixSyncControlService.stateBodyLogged) {
        LumixSyncControlService.stateBodyLogged = true;
        LumixSyncControlService.logInfo(`getstate body first=${raw}`);
      }
      return { ok: ok, message: ok ? 'ok' : '相机无响应', body: raw };
    } catch (_error) {
      return { ok: false, message: '相机无响应', body: '' };
    }
  }

  /**
   * mode=getsetting: 官方读取单项设置当前值的通道（B5/a.E() ->
   * "getsetting", 解析对齐 x5/D.java：<settingvalue type="value"/> 以
   * 请求的 type 为属性名）。getstate 响应不含鼓轮参数（2026-09-28 实机
   * 全量 body 证实），鼓轮当前值必须走这里。
   */
  static async fetchSyncSetting(host: string, type: string): Promise<LumixSyncGetSettingResult> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0 || !LumixSyncControlService.hasControlSession(host)) {
      return { ok: false, value: '', body: '' };
    }
    try {
      const response = await LumixSyncControlService.httpGetRetry(safeHost,
        `/cam.cgi?mode=getsetting&type=${encodeURIComponent(type)}`);
      const raw = response.body.trim();
      const ok = response.code >= 200 && response.code < 300 && raw.length > 0;
      if (ok && LumixSyncControlService.settingBodiesLogged.indexOf(type) < 0) {
        LumixSyncControlService.settingBodiesLogged.push(type);
        LumixSyncControlService.logChunked(`getsetting ${type} body`, raw);
      }
      return { ok: ok, value: LumixSyncControlService.settingValueOf(raw, type), body: raw };
    } catch (_error) {
      return { ok: false, value: '', body: '' };
    }
  }

  /** <settingvalue type="..."/> 值提取。属性优先（x5/D.java:
   *  getAttributeValue(null, type)，2026-09-28 实机 iso="auto" 证实）；属性
   *  为空时回退元素文本（防相机把特殊字符值放进文本节点）。 */
  private static settingValueOf(body: string, type: string): string {
    const open = body.indexOf('<settingvalue');
    if (open < 0) {
      return '';
    }
    const end = body.indexOf('>', open);
    if (end < 0) {
      return '';
    }
    const tag = body.substring(open, end);
    const dq = tag.indexOf(`${type}="`);
    if (dq >= 0) {
      const from = dq + type.length + 2;
      const close = tag.indexOf('"', from);
      if (close >= 0) {
        const attr = tag.substring(from, close).trim();
        if (attr.length > 0) {
          return attr;
        }
      }
    }
    const sq = tag.indexOf(`${type}='`);
    if (sq >= 0) {
      const from = sq + type.length + 2;
      const close = tag.indexOf("'", from);
      if (close >= 0) {
        const attr = tag.substring(from, close).trim();
        if (attr.length > 0) {
          return attr;
        }
      }
    }
    const textEnd = body.indexOf('</settingvalue>', end);
    if (textEnd > end) {
      const text = body.substring(end + 1, textEnd).trim();
      if (text.length > 0) {
        return text;
      }
    }
    return '';
  }

  /**
   * mode=getinfo&type=curmenu：当前菜单快照（官方连接能力链
   * setsetting raw_img_send -> capability -> allmenu -> curmenu ->
   * lens）。<item id= value= option= .../> 的 option 属性即各鼓轮的
   * 相机端取值域——官方拨轮选择器直接用这份列表；首次成功全量落 hilog
   * 供校准。
   */
  static async fetchSyncMenu(host: string): Promise<LumixSyncCamCmdResult> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0 || !LumixSyncControlService.hasControlSession(host)) {
      return { ok: false, message: '控制会话未建立', body: '' };
    }
    try {
      const response = await LumixSyncControlService.httpGetRetry(safeHost,
        '/cam.cgi?mode=getinfo&type=curmenu');
      const raw = response.body.trim();
      const ok = response.code >= 200 && response.code < 300 && raw.length > 0;
      if (ok && !LumixSyncControlService.menuBodyLogged) {
        LumixSyncControlService.menuBodyLogged = true;
        LumixSyncControlService.logChunked('getinfo curmenu body', raw);
      }
      return { ok: ok, message: ok ? 'ok' : '相机无响应', body: raw };
    } catch (_error) {
      return { ok: false, message: '相机无响应', body: '' };
    }
  }

  /**
   * mode=getinfo&type=lens：镜头信息（官方能力链末段）。S5 curmenu 里
   * 光圈没有子菜单项（2026-09-28 实测 717 项无 focal 取值域），光圈
   * 档位域来自这里；响应为逗号分隔 key=value（x5/F.java 按 ,/= 拆入
   * Dictionary）。首次成功全量落 hilog 供校准。
   */
  static async fetchSyncLens(host: string): Promise<LumixSyncCamCmdResult> {
    const safeHost = LumixSyncControlService.normalizeHost(host);
    if (safeHost.length === 0 || !LumixSyncControlService.hasControlSession(host)) {
      return { ok: false, message: '控制会话未建立', body: '' };
    }
    try {
      const response = await LumixSyncControlService.httpGetRetry(safeHost,
        '/cam.cgi?mode=getinfo&type=lens');
      const raw = response.body.trim();
      const ok = response.code >= 200 && response.code < 300 && raw.length > 0;
      if (ok && !LumixSyncControlService.lensBodyLogged) {
        LumixSyncControlService.lensBodyLogged = true;
        LumixSyncControlService.logChunked('getinfo lens body', raw);
      }
      return { ok: ok, message: ok ? 'ok' : '相机无响应', body: raw };
    } catch (_error) {
      return { ok: false, message: '相机无响应', body: '' };
    }
  }

  /** 提取 curmenu 响应里的全部 <item> 标签（对齐 x5/t.java 解析器）。 */
  static parseSyncMenuItems(body: string): SyncMenuItem[] {
    const out: SyncMenuItem[] = [];
    let cursor = 0;
    while (true) {
      const start = body.indexOf('<item', cursor);
      if (start < 0) {
        break;
      }
      const end = body.indexOf('>', start);
      if (end < 0) {
        break;
      }
      const tag = body.substring(start, end);
      cursor = end + 1;
      const attrOf = (name: string): string => {
        const dq = tag.indexOf(`${name}="`);
        if (dq >= 0) {
          const from = dq + name.length + 2;
          const close = tag.indexOf('"', from);
          return close < 0 ? '' : tag.substring(from, close);
        }
        const sq = tag.indexOf(`${name}='`);
        if (sq >= 0) {
          const from = sq + name.length + 2;
          const close = tag.indexOf("'", from);
          return close < 0 ? '' : tag.substring(from, close);
        }
        return '';
      };
      const item: SyncMenuItem = { id: attrOf('id'), enable: attrOf('enable'), value: attrOf('value'), option: attrOf('option') };
      if (item.id.length > 0) {
        out.push(item);
      }
    }
    return out;
  }

  /** 长响应分块落 hilog（单行上限约 1KB，避免截断丢失格式证据）。 */
  private static logChunked(tag: string, body: string): void {
    const limit = 880;
    let offset = 0;
    while (offset < body.length) {
      LumixSyncControlService.logInfo(`${tag} [${offset}] ${body.substring(offset, Math.min(body.length, offset + limit))}`);
      offset += limit;
    }
  }

  /** Pull one <tag>text</tag> value out of a getstate <state> body. */
  private static stateTag(body: string, tag: string): string {
    const open = `<${tag}>`;
    const close = `</${tag}>`;
    const start = body.indexOf(open);
    if (start < 0) {
      return '';
    }
    const from = start + open.length;
    const end = body.indexOf(close, from);
    if (end < 0 || end <= from) {
      return '';
    }
    return body.substring(from, end).trim();
  }

  /** Parse the drum parameter current values from a getstate body. */
  static parseSyncStateParams(body: string): LumixSyncStateParams {
    const params: LumixSyncStateParams = {
      iso: LumixSyncControlService.stateTag(body, 'iso'),
      shtrspeed: LumixSyncControlService.stateTag(body, 'shtrspeed'),
      focal: LumixSyncControlService.stateTag(body, 'focal'),
      exposure: LumixSyncControlService.stateTag(body, 'exposure'),
      whitebalance: LumixSyncControlService.stateTag(body, 'whitebalance')
    };
    return params;
  }

  /**
   * Vivid's persistent Panasonic DLNA identity, mirroring the official app
   * (jadx N5/l.java A()/y(), seed persistence in D5/a.java n()): a
   * 12-hex-character seed exposed as the 32-char hex MEI0 form for the BLE
   * identity write and the dotted form for cam.cgi accctrl. The seed is
   * derived from the OAID so it survives reinstalls - the official seed is
   * device-derived the same way, the instrumented APK presented the same
   * MEI0...02C30003AF62 identity across four signature-changed reinstalls -
   * with the stored value or a random seed as fallback when the identifier
   * is unavailable. The v1 random v4 UUID did not match this format.
   */
  static async persistentSyncIdentity(context: common.UIAbilityContext): Promise<SyncClientIdentity> {
    const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
    const stored = await store.get('syncDlnaSeed', '');
    const storedText = typeof stored === 'string' ? stored : '';
    // A reinstall wipes this preference store; a fresh random seed per
    // install turns every reinstall into a brand-new device for the camera
    // (the 2026-09-26 attempts on a freshly installed build failed with
    // 配对失败 at the trust-tap moment, while the same flow paired every
    // time before the reinstall).
    let seed = await LumixSyncControlService.deriveSeedFromOaid();
    if (seed.length === 0 && /^[0-9A-Fa-f]{12}$/.test(storedText)) {
      seed = storedText;
    }
    if (seed.length === 0) {
      seed = '';
      for (let index = 0; index < 6; index++) {
        seed += Math.floor(Math.random() * 256).toString(16).padStart(2, '0');
      }
    }
    if (seed !== storedText) {
      await store.put('syncDlnaSeed', seed);
      await store.flush();
    }
    const upper = seed.toUpperCase();
    const identity: SyncClientIdentity = {
      hex: `4D454930010010008001${upper}`,
      dotted: `4D454930-0100-1000-8001-${upper}`,
    };
    return identity;
  }

  /**
   * 直连凭据：最后一次成功配对相机的 SoftAP SSID 与密码。仅当请求的 BLE
   * 设备就是那台相机时返回（官方 app 以同样的方式用存储的
   * CurrentConnectedAddress 来闸控其高速起動）。空 SSID 表示无可用的快路径凭据。
   */
  static async storedDirectCredentials(context: common.UIAbilityContext,
    deviceId: string): Promise<SyncDirectCredentials> {
    const empty: SyncDirectCredentials = { ssid: '', password: '' };
    if (deviceId.length === 0) return empty;
    try {
      const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
      const storedSsid = await store.get('syncCameraSsid', '');
      const storedDevice = await store.get('syncCameraBleDeviceId', '');
      const storedPassword = await store.get('syncCameraPassword', '');
      const ssid = typeof storedSsid === 'string' ? storedSsid : '';
      const bleDevice = typeof storedDevice === 'string' ? storedDevice : '';
      const password = typeof storedPassword === 'string' ? storedPassword : '';
      if (ssid.length === 0) return empty;
      // BLE 地址可能被系统掩码或轮换（2026-09-28 实机：偏好里有完整记录
      // 但精确比较失败，直连快路径静默失效）。全量一致或尾部 3 组
      // （如 :1C:C6:4E）一致即视为同一台已注册相机——SSID 本身带机身
      // 编号，直连时仍会按 SSID 扫描把关。
      const normalizeDeviceId = (value: string): string =>
        value.replace(/[\u0000-\u001F\u007F]/g, '').trim().toUpperCase();
      const storedNorm = normalizeDeviceId(bleDevice);
      const deviceNorm = normalizeDeviceId(deviceId);
      const deviceMatches = storedNorm === deviceNorm ||
        (storedNorm.length >= 11 && deviceNorm.length >= 11 &&
          storedNorm.substring(storedNorm.length - 11) === deviceNorm.substring(deviceNorm.length - 11));
      if (!deviceMatches) {
        LumixSyncControlService.logWarn(`pair stored credentials device mismatch storedTail=${storedNorm.length >= 5 ? storedNorm.substring(storedNorm.length - 5) : storedNorm} deviceTail=${deviceNorm.length >= 5 ? deviceNorm.substring(deviceNorm.length - 5) : deviceNorm}`);
        return empty;
      }
      const creds: SyncDirectCredentials = { ssid: ssid, password: password };
      return creds;
    } catch (_error) {
      return empty;
    }
  }

  /** 持久化 sync 直连凭据（应用私有偏好，与官方 CurrentConnectedPass 同级存储）。 */
  static async persistSyncCredentials(context: common.UIAbilityContext, deviceId: string,
    ssid: string, password: string): Promise<void> {
    if (deviceId.length === 0 || ssid.length === 0) return;
    try {
      const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
      await store.put('syncCameraSsid', ssid);
      await store.put('syncCameraBleDeviceId', deviceId);
      await store.put('syncCameraPassword', password);
      await store.flush();
    } catch (_error) {
      // 持久化失败不影响本次连接。
    }
  }

  /** First 12 hex characters of the OAID; '' when unavailable or zeroed. */
  private static async deriveSeedFromOaid(): Promise<string> {
    try {
      const oaid = await identifier.getOAID();
      const hex = oaid.replace(/[^0-9A-Fa-f]/g, '').toUpperCase();
      if (hex.length >= 12 && !/^0{12}/.test(hex)) {
        return hex.substring(0, 12);
      }
    } catch (_error) {
      // Unavailable: callers fall back to the stored or a random seed.
    }
    return '';
  }

  private static indexSyncCharacteristics(services: Array<ble.GattService>): SyncGattCharacteristics {
    const result: SyncGattCharacteristics = {};
    for (const service of services) {
      const serviceUuid = service.serviceUuid.toLowerCase();
      for (const characteristic of service.characteristics) {
        const uuid = characteristic.characteristicUuid.toLowerCase();
        if (uuid === UUID_SYNC_WIFI_CONNECT_TYPE) {
          // Lives on service 5ae57260, not on 054ac620 like the rest of
          // the set (jadx i5/g.java q1(11)).
          result.wifiConnectType = characteristic;
          continue;
        }
        if (uuid === UUID_SYNC_STA_SSID) {
          // Same 5ae57260 service as the connect type (jadx i5/g.java
          // q1(12), SSID confirmation after joining the camera AP).
          result.staSsid = characteristic;
          continue;
        }
        if (serviceUuid !== SYNC_BLE_SERVICE) continue;
        if (uuid === UUID_SYNC_INITIAL_INFORM) result.initialInform = characteristic;
        else if (uuid === UUID_SYNC_DLNA_UUID_APS) result.dlnaUuidAps = characteristic;
        else if (uuid === UUID_SYNC_FRIENDLY_NAME_APS) result.friendlyNameAps = characteristic;
        else if (uuid === UUID_SYNC_WIFI_SSID) result.wifiSsid = characteristic;
        else if (uuid === UUID_SYNC_WIFI_PASSWORD) result.wifiPassword = characteristic;
        else if (uuid === UUID_SYNC_DLNA_UUID_LEGACY) result.dlnaUuidLegacy = characteristic;
        else if (uuid === UUID_SYNC_FRIENDLY_NAME_LEGACY) result.friendlyNameLegacy = characteristic;
        else if (uuid === UUID_SYNC_ACTION_MODE) result.actionMode = characteristic;
      }
    }
    return result;
  }

  /**
   * hilog truncates long single lines (the 2026-09-24 v2 trace lost its
   * tail - including every read value - to that limit), so emit the trace
   * in bounded chunks.
   */
  private static dumpTrace(trace: string[]): void {
    if (trace.length === 0) return;
    const joined = trace.join(' | ');
    const chunks = Math.ceil(joined.length / 800);
    for (let index = 0; index < chunks; index++) {
      LumixSyncControlService.logWarn(`pair trace[${index}/${chunks}]: ${joined.substring(index * 800, (index + 1) * 800)}`);
    }
  }

  private static hexOf(bytes: Uint8Array): string {
    return Array.from(bytes).map((value: number) => value.toString(16).padStart(2, '0')).join('');
  }

  /** INITIAL_INFORM bytes; all-zero (unpaired) selects the default key. */
  private static async readSessionKey(gatt: ble.GattClientDevice, characteristics: SyncGattCharacteristics,
    trace: string[]): Promise<Uint8Array> {
    if (!characteristics.initialInform) {
      LumixSyncControlService.logInfo('session key: initial inform missing, default key');
      return Uint8Array.from(SYNC_DEFAULT_KEY);
    }
    const value = await LumixImportPrototype.readGatt(gatt, characteristics.initialInform, trace);
    const raw = new Uint8Array(value);
    // Temporarily in the clear to diff against the official-app probe dump
    // (same policy as the LUT 401 investigation); restore redaction after.
    LumixSyncControlService.logInfo(`session key: informLen=${raw.length} inform=${LumixSyncControlService.hexOf(raw)}`);
    if (raw.length < 4) return Uint8Array.from(SYNC_DEFAULT_KEY);
    if (raw[0] === 0 && raw[1] === 0 && raw[2] === 0 && raw[3] === 0) {
      LumixSyncControlService.logInfo('session key: zero inform, default key');
      return Uint8Array.from(SYNC_DEFAULT_KEY);
    }
    const key = new Uint8Array(4);
    key[0] = raw[0];
    key[1] = raw[1];
    key[2] = raw[2];
    key[3] = raw[3];
    return key;
  }

  /**
   * Shared o.c/o.d group transform: each 4-byte plaintext group is written
   * reversed and XOR-ed with the big-endian session key bytes in forward
   * order. `uuidLayout` selects the o.d padding ([len][data][0xFF to 20]);
   * the friendly-name layout zeroes the middle and keeps the trailing 0xFF.
   */
  private static encodeApsBlock(data: Uint8Array, key: Uint8Array, uuidLayout: boolean): Uint8Array {
    const plain = new Uint8Array(20);
    plain[0] = data.length & 0xFF;
    for (let index = 0; index < data.length && index < 16; index++) {
      plain[index + 1] = data[index];
    }
    for (let index = 1; index < 20; index++) {
      if (index - 1 < data.length) continue;
      plain[index] = uuidLayout ? 0xFF : 0x00;
    }
    plain[17] = 0xFF;
    plain[18] = 0xFF;
    plain[19] = 0xFF;
    const encoded = new Uint8Array(20);
    for (let offset = 0; offset < 20; offset += 4) {
      encoded[offset] = plain[offset + 3] ^ key[0];
      encoded[offset + 1] = plain[offset + 2] ^ key[1];
      encoded[offset + 2] = plain[offset + 1] ^ key[2];
      encoded[offset + 3] = plain[offset] ^ key[3];
    }
    return encoded;
  }

  /**
   * N5.o.a decoder for the Wi-Fi password read: every 4-byte group is
   * reversed and XOR-ed with the reversed key bytes; the first decoded
   * byte is skipped (declared length, never validated by the official
   * decoder) and the result is cut at the first 0xFF filler. An EMPTY
   * result is a valid open-network password: the captured S5 SoftAP
   * returns a key-repeat pattern that decodes to "" and the official
   * app joins without a passphrase.
   */
  private static decodeWifiPassword(value: ArrayBuffer, key: Uint8Array): string {
    const input = new Uint8Array(value);
    if (input.length === 0 || input.length % 4 !== 0 || key.length < 4) {
      LumixSyncControlService.logWarn(`password decode: rawLen=${input.length} not multiple of 4`);
      return '';
    }
    const output = new Uint8Array(input.length);
    for (let offset = 0; offset < input.length; offset += 4) {
      output[offset] = input[offset + 3] ^ key[3];
      output[offset + 1] = input[offset + 2] ^ key[2];
      output[offset + 2] = input[offset + 1] ^ key[1];
      output[offset + 3] = input[offset] ^ key[0];
    }
    let end = output.length;
    for (let index = 1; index < output.length; index++) {
      if (output[index] === 0xFF) {
        end = index;
        break;
      }
    }
    try {
      return util.TextDecoder.create('utf-8').decodeToString(output.slice(1, end)).replace(/\0/g, '').trim();
    } catch (_error) {
      LumixSyncControlService.logWarn('password decode: utf-8 decode threw');
      return '';
    }
  }

  private static firstSsidEntry(value: string): string {
    const parts = value.split(';');
    for (const part of parts) {
      const trimmed = part.trim();
      if (trimmed.length > 0) return trimmed;
    }
    return '';
  }

  /** 32-byte NUL-padded ASCII SSID confirmation payload (z5.d.a -> N5.l.x). */
  private static ssidConfirmBytes(ssid: string): Uint8Array {
    const plain = LumixSyncControlService.asciiBytes(ssid);
    const buffer = new Uint8Array(32);
    for (let index = 0; index < plain.length && index < 32; index++) {
      buffer[index] = plain[index];
    }
    return buffer;
  }

  private static decodeUtf8(value: ArrayBuffer): string {
    try {
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(value)).replace(/\0/g, '').trim();
    } catch (_error) {
      return '';
    }
  }

  private static asciiBytes(value: string): Uint8Array {
    const bytes = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index);
      bytes[index] = code & 0xFF;
    }
    return bytes;
  }

  private static uuidBytesFromString(uuid: string): Uint8Array {
    const hex = uuid.replace(/-/g, '');
    const bytes = new Uint8Array(hex.length / 2);
    for (let index = 0; index < bytes.length; index++) {
      bytes[index] = parseInt(hex.substring(index * 2, index * 2 + 2), 16);
    }
    return bytes;
  }

  private static sessionIdFromResponse(body: string): string {
    const parts = body.split(',');
    if (parts.length < 5) return '';
    return parts[4].replace(/\r/g, '').replace(/\n/g, '').trim();
  }

  private static normalizeHost(host: string): string {
    return host.trim().replace('http://', '').replace('https://', '').replace('/', '');
  }

  private static async httpGet(host: string, path: string, sessionId: string): Promise<LumixSyncHttpResponse> {
    const client = http.createHttp();
    try {
      const header: Record<string, string> = {
        'User-Agent': 'LUMIX Sync',
      };
      if (sessionId.length > 0) {
        header['X-SESSION_ID'] = sessionId;
      }
      const response = await client.request(`http://${host}${path}`, {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: 5000,
        readTimeout: 5000,
        expectDataType: http.HttpDataType.STRING,
      });
      const body = response.result === undefined || response.result === null ? '' : String(response.result);
      const result: LumixSyncHttpResponse = { code: response.responseCode, body: body };
      return result;
    } catch (_error) {
      const result: LumixSyncHttpResponse = { code: 0, body: '' };
      return result;
    } finally {
      client.destroy();
    }
  }

  /**
   * Read-path GET with the official retry policy. B5/a.F(str, 5, 1000) drives
   * the getstate heartbeat and retries err_busy five times with a 1 s gap
   * (callers liveview/i.java:3817 and ImageAppTotalService.java:733); report
   * §5.1 states the same default of five retries. The camcmd / camctrl /
   * setsetting writers already retried; the read and heartbeat paths did not.
   */
  private static async httpGetRetry(host: string, path: string): Promise<LumixSyncHttpResponse> {
    let last: LumixSyncHttpResponse = { code: 0, body: '' };
    for (let attempt = 0; attempt <= 5; attempt++) {
      const response = await LumixSyncControlService.httpGet(host, path, LumixSyncControlService.sessionId);
      last = response;
      const busy = response.code >= 200 && response.code < 300 &&
        LumixSyncControlService.replyVerdict(response.body).startsWith('err_busy');
      if (!busy) {
        return response;
      }
      if (attempt < 5) {
        await LumixImportPrototype.delay(1000);
      }
    }
    return last;
  }

  private static logInfo(message: string): void {
    try { hilog.info(0x0001, SYNC_LOG_TAG, '%{public}s', message); AppLogSink.emit('CTL', message); } catch (_error) { }
  }

  private static logWarn(message: string): void {
    try { hilog.warn(0x0001, SYNC_LOG_TAG, '%{public}s', message); AppLogSink.emit('CTL', message); } catch (_error) { }
  }
}
