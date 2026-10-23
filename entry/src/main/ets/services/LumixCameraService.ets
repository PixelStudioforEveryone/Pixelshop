import { http } from '@kit.NetworkKit';
import socket from '@ohos.net.socket';
import wifiManager from '@ohos.wifiManager';
import usbManager from '@ohos.usbManager';
import deviceInfo from '@ohos.deviceInfo';
import { NikonCameraService } from './NikonCameraService';
import { SonyCameraService } from './SonyCameraService';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';
import { BusinessError } from '@kit.BasicServicesKit';
import { CameraWifiPasswordPolicy } from './CameraWifiPasswordPolicy';
import { AppDiagnostics } from './AppDiagnostics';

export interface LumixProbeResult {
  connected: boolean;
  model: string;
  family: string;
  supportsRaw: boolean;
  firmware: string;
  message: string;
}

/** A nearby Panasonic camera access point discovered by the system Wi-Fi scan. */
export interface LumixWifiCandidate {
  ssid: string;
  bssid: string;
  rssi: number;
  securityType: number;
  model: string;
  family: string;
  imageKey: string;
  brand?: string;
}

export interface LumixWifiConnectionResult {
  connected: boolean;
  message: string;
  ssid: string;
  networkId?: number;
}

export interface CameraWifiJoinOptions {
  // Only credentials obtained for this exact AP may be supplied.
  password?: string;
  requestPassword?: (candidate: LumixWifiCandidate, message: string) => Promise<string | null>;
  isCancelled?: () => boolean;
}

interface LumixHttpResponse {
  code: number;
  body: string | null;
}

interface LumixDmpDescriptorResponse {
  code: number;
  body: string;
}

export interface LumixUsbConnectionResult {
  connected: boolean;
  message: string;
  model: string;
  imageKey: string;
}

/** Metadata exposed by the official library's object APIs. */
export interface LumixPtpObject {
  handle: number;
  storageId: number;
  format: number;
  size: number;
  thumbSize: number;
  width: number;
  height: number;
  filename: string;
  captureDate: string;
}

interface LumixSsidIdentity {
  model: string;
  family: string;
  imageKey: string;
}

interface LumixSsidToken {
  token: string;
  model: string;
  family: string;
  imageKey: string;
}

interface LumixModelInfo {
  family: string;
  supportsRaw: boolean;
}

interface PtpContainer {
  length: number;
  type: number;
  code: number;
  transactionId: number;
  payload: Uint8Array;
}

interface PtpStringRead {
  value: string;
  nextOffset: number;
}

interface PtpDeviceInfo {
  manufacturer: string;
  model: string;
  version: string;
}

interface PtpTransport {
  pipe: usbManager.USBDevicePipe;
  iface: usbManager.USBInterface;
  bulkIn: usbManager.USBEndpoint;
  bulkOut: usbManager.USBEndpoint;
  sessionOpened: boolean;
  lumixSessionOpened: boolean;
}

interface PtpBufferParseResult {
  containers: PtpContainer[];
  consumed: number;
}

interface PtpInterfaceSelection {
  config: usbManager.USBConfiguration;
  iface: usbManager.USBInterface;
  bulkIn: usbManager.USBEndpoint;
  bulkOut: usbManager.USBEndpoint;
}

const USB_PANASONIC_VENDOR_ID = 0x04DA;
const USB_PTP_INTERFACE_CLASS = 0x06;
const USB_PTP_INTERFACE_SUBCLASS = 0x01;
const USB_PTP_INTERFACE_PROTOCOL = 0x01;
const PTP_CONTAINER_HEADER_SIZE = 12;
const PTP_CONTAINER_COMMAND = 1;
const PTP_CONTAINER_DATA = 2;
const PTP_CONTAINER_RESPONSE = 3;
const PTP_OPERATION_GET_DEVICE_INFO = 0x1001;
const PTP_OPERATION_OPEN_SESSION = 0x1002;
const PTP_OPERATION_CLOSE_SESSION = 0x1003;
const PTP_OPERATION_GET_STORAGE_IDS = 0x1004;
const PTP_OPERATION_GET_NUM_OBJECTS = 0x1006;
const PTP_OPERATION_GET_OBJECT_HANDLES = 0x1007;
const PTP_OPERATION_GET_OBJECT_INFO = 0x1008;
const PTP_OPERATION_GET_OBJECT = 0x1009;
const PTP_OPERATION_GET_THUMB = 0x100A;
const PTP_OPERATION_GET_PARTIAL_OBJECT = 0x101B;
// Panasonic's LUMIX Lab USB layer adds a vendor session gate after the
// standard PTP session. The Android implementation uses signed shorts
// -0x6efe/-0x6efd, which are 0x9102/0x9103 on the USB wire.
const PTP_OPERATION_LUMIX_OPEN_SESSION = 0x9102;
const PTP_OPERATION_LUMIX_CLOSE_SESSION = 0x9103;
const PTP_RESPONSE_OK = 0x2001;
const PTP_RESPONSE_SESSION_NOT_OPEN = 0x2003;
const PTP_RESPONSE_SESSION_ALREADY_OPEN = 0x201E;
const PTP_RESPONSE_INVALID_OBJECT_HANDLE = 0x2009;
const PTP_RESPONSE_INVALID_STORAGE_ID = 0x2008;
const LUMIX_CONNECT_VERSION = 0x00010001;

// ---------------------------------------------------------------------------
// Panasonic vendor PTP operations (control surface, not the storage surface).
//
// Source: public implementations that drive a LUMIX body over plain USB --
// baku89/tethr (MIT, core/src/TethrPTPUSB/TethrPanasonic.ts) and the Android
// port velkilllmer/lumix-USB-tether-monitor-android (lumix/LumixProps.kt).
// Both agree on these codes; the same numbers are documented in the report
// section 13.
// ---------------------------------------------------------------------------
const PTP_OPERATION_LUMIX_GET_PROP_DESC = 0x9108;
const PTP_OPERATION_LUMIX_GET_PROP_VALUE = 0x9402;
const PTP_OPERATION_LUMIX_SET_PROP_VALUE = 0x9403;
const PTP_OPERATION_LUMIX_CAPTURE = 0x9404;
const PTP_OPERATION_LUMIX_CTRL_LIVEVIEW = 0x9405;
const PTP_OPERATION_LUMIX_LIVEVIEW = 0x9412;
const PTP_OPERATION_LUMIX_GET_LIVEVIEW_SETTINGS = 0x9414;
const PTP_OPERATION_LUMIX_SET_LIVEVIEW_SETTINGS = 0x9415;
const PTP_OPERATION_LUMIX_MANUAL_FOCUS = 0x9416;
const PTP_OPERATION_LUMIX_LIVEVIEW_IMAGE = 0x9706;

/** Command parameters that go with the vendor operations above. */
const LUMIX_PARAM_CAPTURE = 0x03000011;
const LUMIX_PARAM_AUTOFOCUS = 0x03000024;
const LUMIX_PARAM_LIVEVIEW_START = 0x0d000010;
const LUMIX_PARAM_LIVEVIEW_STOP = 0x0d000011;
const LUMIX_PARAM_LIVEVIEW_TRANS_IMG = 0x0d800011;
const LUMIX_PARAM_LIVEVIEW_RECOM_IMG = 0x0d800012;
const LUMIX_PARAM_MANUAL_FOCUS = 0x03010011;

/** Panasonic device property codes are 32-bit, unlike standard PTP. */
const LUMIX_PROP_PHOTO_STYLE = 0x02000010;
const LUMIX_PROP_ISO = 0x02000020;
const LUMIX_PROP_ISO_PARAM = 0x02000021;
const LUMIX_PROP_SHUTTER = 0x02000030;
const LUMIX_PROP_SHUTTER_PARAM = 0x02000031;
const LUMIX_PROP_APERTURE = 0x02000040;
const LUMIX_PROP_APERTURE_PARAM = 0x02000041;
const LUMIX_PROP_WHITE_BALANCE = 0x02000050;
const LUMIX_PROP_WHITE_BALANCE_PARAM = 0x02000051;
const LUMIX_PROP_EXPOSURE = 0x02000060;
const LUMIX_PROP_EXPOSURE_PARAM = 0x02000061;
const LUMIX_PROP_MODE_POS = 0x02000082;
const LUMIX_PROP_QUALITY = 0x020000a2;
const LUMIX_PROP_ASPECT = 0x020000a3;

/** Response codes the control surface treats as "camera is busy, try later". */
const PTP_RESPONSE_DEVICE_BUSY = 0x2019;
const PTP_RESPONSE_ACCESS_DENIED = 0x200F;
const PTP_RESPONSE_OPERATION_NOT_SUPPORTED = 0x2005;

/** Upper bound for one liveview frame, matching the public reference. */
const LUMIX_LIVEVIEW_MAX_BYTES = 1024 * 1024;

/**
 * One vendor exchange outcome. Kept as a value instead of throwing so a probe
 * can log a per-property result table even when one property is unsupported.
 */
interface LumixPtpReply {
  code: number;
  payload: Uint8Array;
}

/** Human-readable outcome of the read-only control probe. */
export interface LumixUsbControlProbe {
  ok: boolean;
  summary: string;
  notes: string[];
}

/**
 * Known LUMIX bodies using the Panasonic Image-App Wi-Fi API.
 * Keys cover both the DC- prefix reported by cameras and the marketing names.
 */
const MODEL_REGISTRY: Map<string, LumixModelInfo> = buildModelRegistry();

function buildModelRegistry(): Map<string, LumixModelInfo> {
  const registry = new Map<string, LumixModelInfo>();
  const add = (codes: string[], family: string, supportsRaw: boolean): void => {
    for (let index = 0; index < codes.length; index++) {
      registry.set(codes[index], { family: family, supportsRaw: supportsRaw });
    }
  };
  // S full-frame mirrorless
  add(['DC-S1RII', 'S1RII', 'DC-S1RM2', 'S1RM2'], 'S 系列', true);
  add(['DC-S1R', 'S1R'], 'S 系列', true);
  add(['DC-S1', 'S1'], 'S 系列', true);
  add(['DC-S1H', 'S1H'], 'S 系列', true);
  add(['DC-S1M2E', 'S1M2E', 'DC-S1IIE', 'S1IIE'], 'S 系列', true);
  add(['DC-S1M2', 'S1M2', 'DC-S1II', 'S1II'], 'S 系列', true);
  add(['DC-S5M2X', 'S5M2X'], 'S 系列', true);
  add(['DC-S5M2', 'S5M2'], 'S 系列', true);
  add(['DC-S5', 'S5'], 'S 系列', true);
  add(['DC-BS1H', 'BS1H'], 'S 电影机', true);
  // GH hybrid flagship
  add(['DC-GH7', 'GH7'], 'GH 系列', true);
  add(['DC-GH6', 'GH6'], 'GH 系列', true);
  add(['DC-GH5II', 'DC-GH5M2', 'GH5M2'], 'GH 系列', true);
  add(['DC-GH5S', 'GH5S'], 'GH 系列', true);
  add(['DC-GH5', 'GH5'], 'GH 系列', true);
  add(['DC-GH4', 'GH4'], 'GH 系列', true);
  // G micro-four-thirds
  add(['DC-G9II', 'DC-G9M2', 'G9M2'], 'G 系列', true);
  add(['DC-G9', 'G9'], 'G 系列', true);
  add(['DC-G100', 'DC-G110', 'G100'], 'G 系列', true);
  add(['DC-G95', 'DC-G90', 'DC-G91', 'G95'], 'G 系列', true);
  add(['DC-GX9', 'GX9'], 'G 系列', true);
  add(['DC-GX850', 'DC-GX800', 'GX850'], 'G 系列', true);
  add(['DC-G85', 'DC-G80', 'G85'], 'G 系列', true);
  add(['DC-GX85', 'DC-GX80', 'GX85'], 'G 系列', true);
  // FZ bridge
  add(['DC-FZ1000II', 'DC-FZ1000M2', 'FZ1000M2'], 'FZ 长焦', true);
  add(['DC-FZ1000', 'FZ1000'], 'FZ 长焦', true);
  add(['DC-FZ2500', 'DC-FZ2000', 'FZ2500'], 'FZ 长焦', true);
  add(['DC-FZ300', 'DC-FZ330', 'FZ300'], 'FZ 长焦', false);
  // LX compact
  add(['DC-LX100II', 'DC-LX100M2', 'LX100M2'], 'LX 便携', true);
  add(['DC-LX100', 'LX100'], 'LX 便携', true);
  add(['DC-LX10', 'DC-LX15', 'LX10'], 'LX 便携', true);
  // TZ / ZS travel zooms
  add(['DC-TZ200', 'DC-TZ220', 'DC-ZS200', 'TZ220'], 'TZ 旅行', true);
  add(['DC-TZ100', 'DC-ZS100', 'TZ100'], 'TZ 旅行', true);
  add(['DC-TZ99', 'TZ99'], '便携系列', false);
  add(['DC-SZ99', 'SZ99'], '便携系列', false);
  return registry;
}

/**
 * LUMIX Lab generation model tokens.
 *
 * Provenance: these are the marketing bodies of the byte->model table in the
 * official LUMIX Lab APK (`M0`, codes 1..9), i.e. exactly the bodies whose BLE
 * advertisement carries the compact model code that Lab reads. Aliases
 * (S1RII / G9II / S1II / S1IIE) stay alongside the marketing names because a
 * camera or an API reply may report either form.
 */
const PANASONIC_LAB_MODEL_TOKENS: string[] = ['S5M2X', 'S5M2', 'S1RM2', 'S1RII',
  'S1M2E', 'S1IIE', 'S1M2', 'S1II', 'S9', 'GH7', 'G9M2', 'G9II', 'L10'];

/**
 * LUMIX Sync generation model tokens, already de-duplicated against the Lab
 * line.
 *
 * Provenance of the partition: LUMIX Sync 2.0.17 itself declares which bodies
 * it will not serve. `T5/d.java` holds
 *
 *   b(String) == DC-S5M2 || DC-S5M2X || DC-S9 || DC-GH7 || DC-G9M2
 *
 * and its only two callers (`T5.d.p`, `T5.d.q`) use it purely to choose the
 * ON_LUMIX_LAB_INSTALL_DIALOG / ON_LUMIX_LAB_LAUNCH_DIALOG wording — Sync tells
 * the user to go to LUMIX Lab for exactly those bodies. That is why S9 belongs
 * to the Lab line.
 *
 * The subtraction below is deliberate and must stay. Routing a Lab body to the
 * Sync line lets one camera be claimed by both lines. That used to hold only as
 * a by-product of evaluating the Lab list first; it is now an explicit
 * invariant that survives any future reordering or addition to either list.
 * Only exact token equality is subtracted, so Sync's S1R survives next to Lab's
 * S1RM2 / S1RII.
 *
 * 2026-10-11 — GH5, GH5S and G9 moved OFF this line onto the Image App line.
 * Sync's sources do mention all three (g5/a.java:84 drivemode menu-value
 * translation, x5/C3066j.java:330, N5/l.java:1378 G-series layout gate), but
 * every one of those is a legacy UI/menu special case inherited from the
 * pre-Sync codebase, not a supported-hardware list. The official LUMIX Image App
 * supported table lists DC-GH5 / DC-GH5S / DC-G9 outright, none of the three has
 * a Bluetooth radio, and this line's entry point below is BLE-gated — so keeping
 * them here would have left them permanently unreachable. Lab's only official
 * model gate (`T5.d.b`) does not mention them either.
 */
const PANASONIC_SYNC_MODEL_TOKENS: string[] = ['S1H', 'S1R', 'G100D', 'G100',
  'GH5M2', 'GH6', 'GH1']
  .filter((model: string) => PANASONIC_LAB_MODEL_TOKENS.indexOf(model) < 0);

/**
 * LUMIX Image App generation model tokens — bodies with no Bluetooth radio.
 *
 * Provenance: Image App 1.9.0 (Lumix Link 2.0) contains no Bluetooth code at
 * all — zero hits for BluetoothAdapter/BluetoothGatt/BLE across the Java
 * sources, smali, resources, the manifest and every native library. That
 * generation provisions Wi-Fi by hand (an unfiltered AP list the user picks
 * from), by QR code (MDL/SSID/PW/CRYPT/DeviceID) or by NFC, discovers the body
 * over SSDP and then speaks cam.cgi plus DLNA. Neither LUMIX Lab nor LUMIX Sync
 * mentions any of these tokens, which is consistent with them being served by
 * the older application.
 *
 * The candidate list below is the official LUMIX Image App supported-hardware
 * table. Contention check (2026-10-11): over the whole Lab decompiled source
 * there are ZERO literals from that table, so the Lab line contends with none of
 * it. Over the whole Sync source the only literals are DC-GH5, DC-GH5S and DC-G9
 * (g5/a.java:84, x5/C3066j.java:330, N5/l.java:1378) — all legacy UI/menu-value
 * special cases rather than a supported list — and those three are served here,
 * because the official Image App table lists them and none of the three has a
 * Bluetooth radio for the BLE-gated alternative line to use.
 *
 * ZS300/TZ300 are the one genuine subtraction: the same body under two regional
 * names, claimed by isWifiOnlyModel() on the Sync line, so leaving TZ300 in this
 * table would send identical hardware down two different routes.
 *
 * G97 and GH3 are kept even though the official table predates them: neither
 * Lab nor Sync mentions either token, so this line is their only archive.
 *
 * The subtraction keeps the three-line partition disjoint by construction, so a
 * body can never be claimed by two lines even if a later edit adds the same
 * token to more than one candidate list.
 */
const PANASONIC_IMAGE_MODEL_TOKENS: string[] = ['TZ99', 'ZS99',
  'G90', 'G91', 'G95', 'G95D', 'TZ95', 'TZ95D', 'TZ96', 'TZ96D', 'TZ97',
  'ZS80', 'ZS80D',
  'FZ1000M2', 'FZ10002',
  'LX100M2',
  'FT7', 'TS7',
  'GX9', 'TZ200', 'TZ200D', 'TZ202', 'TZ202D', 'TZ220', 'TZ220D',
  'ZS200', 'ZS200D', 'ZS220', 'ZS220D',
  'GF10',
  'GH5S', 'G9', 'GH5',
  'TZ90', 'TZ91', 'TZ92', 'TZ93', 'ZS70', 'FZ80', 'FZ82', 'GF9',
  'GX800', 'GX850',
  'FZ2000', 'FZ2500', 'LX9', 'LX10', 'LX15', 'G80', 'G81', 'G85',
  'GX80', 'GX85',
  'TZ100', 'TZ101', 'TZ110', 'ZS100', 'ZS110', 'TZ80', 'TZ81', 'ZS60',
  'FZ300', 'FZ330', 'GX8', 'G7', 'G70',
  'GF8', 'GF7', 'TZ70', 'TZ71', 'TZ57', 'TZ58', 'ZS45', 'ZS50', 'SZ10',
  'GM5', 'GM1S', 'LX100',
  'GH4',
  'TZ55', 'TZ56', 'ZS35',
  'TZ60', 'TZ61', 'ZS40', 'SZ8',
  'GM1',
  'GX7',
  'LF1',
  'G6', 'GF6',
  // 官方支持表未列、但 Lab 与 Sync 两个 APK 源码均零命中的两个机身：
  // 本线是它们唯一的归档处，删掉会让它们掉进"无归属"。
  'G97', 'GH3']
  .filter((model: string) => PANASONIC_LAB_MODEL_TOKENS.indexOf(model) < 0 &&
    PANASONIC_SYNC_MODEL_TOKENS.indexOf(model) < 0);

/**
 * Panasonic LUMIX LAN adapter.
 *
 * Compatible bodies expose the Image-App HTTP control API on port 80 once the
 * phone or computer joins the Wi-Fi network created by the camera. The
 * handshake probes every well-known endpoint, so it works across model
 * families (S / GH / G / FZ / LX / TZ) regardless of which subset of the API
 * a given body implements.
 */
export class LumixCameraService {
  /**
   * 转发到 hilog **并**写入应用日志（「问题反馈 → 发送日志」上传的是后者）。
   *
   * 签名与 `hilog.info` 一致，调用点只换了函数名。Wi-Fi 直连、S5/cam.cgi 与
   * DMP 发现这些链路以前只写 hilog，用户读不到也传不上来，真机报"连不上"时
   * 日志里只剩结构化枚举，看不出是哪一步断的。
   *
   * 落盘前仍过 `AppLogPolicy.sanitize`（SSID/MAC/URL/路径打码），并由
   * `AppLogSink` 统一限流。
   */
  static logBoth(domain: number, tag: string, format: string, ...args: Object[]): void {
    try { hilog.info(domain, tag, format, ...args); } catch (_error) { }
    AppLogSink.emit('CTL', tag + ' ' + LumixCameraService.fillTrace(format, args));
  }

  static warnBoth(domain: number, tag: string, format: string, ...args: Object[]): void {
    try { hilog.warn(domain, tag, format, ...args); } catch (_error) { }
    AppLogSink.emit('CTL', tag + ' ' + LumixCameraService.fillTrace(format, args));
  }

  static errorBoth(domain: number, tag: string, format: string, ...args: Object[]): void {
    try { hilog.error(domain, tag, format, ...args); } catch (_error) { }
    AppLogSink.emit('CTL_ERR', tag + ' ' + LumixCameraService.fillTrace(format, args));
  }

  /** 把 hilog 的 `%{public}s` / `%{public}d` 占位符按顺序替换成实参。 */
  private static fillTrace(format: string, args: Object[]): string {
    let index = 0;
    return format.replace(/%\{public\}[a-zA-Z]+/g, (): string => {
      if (index >= args.length) return '?';
      const value = args[index];
      index += 1;
      return String(value);
    });
  }

  /**
   * Bodies in this set do not use the LUMIX Lab application-level BLE
   * registration for image transfer.
   *
   * ⚠ 这不是"没有蓝牙"的判据。本集合里的机身**都有蓝牙**（初代 S5 与
   * ZS300 均经官方规格确认支持蓝牙），它们的 Wi‑Fi 凭据由 **LUMIX Sync 代
   * 的 BLE 配对**下发（`LumixSyncControlService.pairAndConnect`），只是不走
   * Lab 那套 GATT 注册。谓词只回答"要不要走 Lab 的 GATT 注册"，不要用它判断
   * 硬件能力——曾因此把 ZS300 误判为无蓝牙、进而误判 Sync 握手进不去。
   *
   * Keep this exact: S5M2 and its X variant are a separate BLE-capable family.
   */
  static isWifiOnlyModel(model: string): boolean {
    const upper = model.toUpperCase();
    // Callers pass concatenated identity strings such as "S5 S5 S5-460099"
    // (model + candidate model + candidate name). Evaluate every whitespace-
    // separated token so a complete Wi-Fi-only model is recognised anywhere
    // in the string instead of only when the whole string matches.
    const tokens = upper.split(/\s+/);
    let sawWifiOnly = false;
    for (const token of tokens) {
      const trimmed = token.trim();
      if (trimmed.length === 0) continue;
      const compact = trimmed.replace(/[\s_-]+/g, '');
      // S5M2-family tokens (including the X variant) use the BLE branch. A
      // single such token vetoes Wi-Fi-only classification for the string.
      if (compact.indexOf('S5M2X') >= 0 || compact.indexOf('S5M2') >= 0) return false;
      if (LumixCameraService.isZs300Model(trimmed)) {
        sawWifiOnly = true;
        continue;
      }
      // The original S5 is the Wi-Fi-only Panasonic branch. Its advertised
      // identity must be a complete model token followed by an instance
      // separator (S5_xxxx or S5-xxxx); names such as xxxxS9_xxxx and S_5 are
      // deliberately rejected.
      if (LumixCameraService.isOriginalS5Name(trimmed)) {
        sawWifiOnly = true;
        continue;
      }
      // Camera API responses use bare model strings such as DC-S5. Accept only
      // the known complete forms; do not use endsWith/indexOf on arbitrary names.
      if (compact === 'S5' || compact === 'DCS5' || compact === 'LUMIXS5' ||
        compact === 'PANASONICS5' || compact === 'PANAS5' || compact === 'CAMERAS5') {
        sawWifiOnly = true;
      }
    }
    return sawWifiOnly;
  }

  /**
   * User-confirmed ZS300 AP shape. Do not accept embedded or partial model
   * names. The TZ300 alternative is the same body under the European/Asian
   * marketing name (the official Image App table lists "DC-TZ300 / ZS300" on
   * one row); the leading letter is the only difference, so accepting it is an
   * anchored whole-shape match, not a partial one.
   */
  static isZs300WifiSsid(ssid: string): boolean {
    return /^(?:ZS|TZ)300-[A-Z0-9]{6}$/.test(ssid.toUpperCase());
  }

  private static isZs300Model(identity: string): boolean {
    const upper = identity.toUpperCase();
    // ZS300 (北美名) 与 TZ300 (欧亚名) 是同一台机身。三种形态都要认：裸机型串、
    // 带厂商前缀的机型串、以及"机型串 + 实例后缀"的广播名（TZ300-460099）。
    // 一律用 matchesPanasonicName 的锚定匹配，不允许 endsWith/indexOf 之类的
    // 部分匹配。
    return upper === 'ZS300' || upper === 'DC-ZS300' || upper === 'DMC-ZS300' ||
      upper === 'TZ300' || upper === 'DC-TZ300' || upper === 'DMC-TZ300' ||
      LumixCameraService.matchesPanasonicName(upper, 'ZS300') ||
      LumixCameraService.matchesPanasonicName(upper, 'TZ300') ||
      LumixCameraService.isZs300WifiSsid(identity);
  }

  /** Match a complete Panasonic model token plus dynamic instance suffix. */
  private static matchesPanasonicName(value: string, token: string): boolean {
    const upper = value.toUpperCase().trim();
    const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const suffix = '[-_][A-Z0-9]{3,}(?:[-_][A-Z0-9]+)*';
    const direct = new RegExp(`^${escaped}${suffix}$`);
    const prefixed = new RegExp(`^(?:LUMIX|PANASONIC|PANA|DC|DMC|CAMERA)[-_ ]+${escaped}${suffix}$`);
    return direct.test(upper) || prefixed.test(upper);
  }

  /** Match an original S5 AP/advertisement name, not an S5M2 model. */
  private static isOriginalS5Name(value: string): boolean {
    const upper = value.toUpperCase().trim();
    if (upper.length === 0) return false;
    return LumixCameraService.matchesPanasonicName(upper, 'S5');
  }

  /** Public identity check used by the dedicated passive S5 receiver route. */
  static isOriginalS5WifiSsid(value: string): boolean {
    return LumixCameraService.isOriginalS5Name(value);
  }

  /**
   * Enumerate USB still-image devices. Panasonic bodies normally advertise
   * vendor id 0x04DA and a USB Still Image/PTP interface (class 0x06,
   * subclass 0x01, protocol 0x01). The name fallback covers regional firmware
   * that does not expose the vendor id consistently.
   */
  static scanUsbCameras(): Array<Readonly<usbManager.USBDevice>> {
    try {
      const devices = usbManager.getDevices();
      const cameras: Array<Readonly<usbManager.USBDevice>> = [];
      for (const device of devices) {
        const name = `${device.manufacturerName} ${device.productName}`.toUpperCase();
        const selection = LumixCameraService.findPtpInterface(device);
        const isPanasonic = device.vendorId === USB_PANASONIC_VENDOR_ID ||
          name.indexOf('PANASONIC') >= 0 || name.indexOf('LUMIX') >= 0 ||
          name.indexOf('DC-') >= 0 || name.indexOf('S1R') >= 0 ||
          name.indexOf('S5') >= 0 || name.indexOf('S9') >= 0;
        // Some firmware exposes only the standard Still Image/PTP interface
        // and leaves manufacturer/product strings empty. Keep such a device
        // visible so the USB authorization dialog can identify it instead of
        // reporting a false "no USB camera" result.
        const unidentifiedPtp = name.trim().length === 0;
        // Keep Panasonic devices visible even when the camera is currently in
        // PC(Storage) mode and therefore exposes no Still Image/PTP interface.
        // connectUsbCamera() can then distinguish that mode and tell the user
        // to switch to PTP/PC(Tether), instead of losing the device at scan time.
        if (selection || isPanasonic || unidentifiedPtp) cameras.push(device);
      }
      // 扫描结果必须留痕：握手失败时第一个要回答的问题就是「系统到底有没有
      // 枚举到相机」，而旧代码在这里把异常和空结果都吞成了 []。
      let detail = '';
      for (const device of devices) {
        const vid = device.vendorId !== undefined ? device.vendorId.toString(16) : '?';
        const pid = device.productId !== undefined ? device.productId.toString(16) : '?';
        const ptp = LumixCameraService.findPtpInterface(device) !== null ? 1 : 0;
        detail += ` [0x${vid}:0x${pid} ifs=${(device.configs || []).length} ptp=${ptp}]`;
      }
      LumixCameraService.logBoth(0x0001, 'VIVID_USB',
        `scan total=${devices.length} matched=${cameras.length}${detail.substring(0, 200)}`);
      return cameras;
    } catch (error) {
      LumixCameraService.logBoth(0x0001, 'VIVID_USB', `scan failed: ${String(error).substring(0, 120)}`);
      return [];
    }
  }

  /**
   * Enumerate objects through the same PTP object sequence exposed by the
   * official SDK: storage IDs, object count/handles, then ObjectInfo. This is
   * deliberately a read-only operation; no capture or camera setting command
   * is sent here.
   */
  static async listUsbObjects(): Promise<LumixPtpObject[]> {
    const devices = LumixCameraService.scanUsbCameras();
    if (devices.length === 0) return [];
    let transport: PtpTransport | undefined;
    try {
      transport = await LumixCameraService.openPtpTransport(devices[0]);
      let transactionId = 2;
      const storageData = await LumixCameraService.ptpTransaction(
        transport.pipe, transport.bulkOut, transport.bulkIn,
        PTP_OPERATION_GET_STORAGE_IDS, transactionId++, []);
      const storageIds = LumixCameraService.parseUint32Array(
        LumixCameraService.dataPayload(storageData, PTP_OPERATION_GET_STORAGE_IDS, transactionId - 1));
      const objects: LumixPtpObject[] = [];
      for (const storageId of storageIds) {
        // Keep the count transaction explicit: it is the PTP equivalent of
        // the SDK's object-data discovery step and also guards stale handles.
        await LumixCameraService.ptpTransaction(
          transport.pipe, transport.bulkOut, transport.bulkIn,
          PTP_OPERATION_GET_NUM_OBJECTS, transactionId++, [storageId, 0, 0]);
        const handlesData = await LumixCameraService.ptpTransaction(
          transport.pipe, transport.bulkOut, transport.bulkIn,
          PTP_OPERATION_GET_OBJECT_HANDLES, transactionId++, [storageId, 0, 0]);
        const handles = LumixCameraService.parseUint32Array(
          LumixCameraService.dataPayload(handlesData, PTP_OPERATION_GET_OBJECT_HANDLES, transactionId - 1));
        for (const handle of handles) {
          const infoData = await LumixCameraService.ptpTransaction(
            transport.pipe, transport.bulkOut, transport.bulkIn,
            PTP_OPERATION_GET_OBJECT_INFO, transactionId++, [handle]);
          const payload = LumixCameraService.dataPayload(infoData, PTP_OPERATION_GET_OBJECT_INFO, transactionId - 1);
          const info = LumixCameraService.parseObjectInfo(handle, payload);
          if (info) objects.push(info);
        }
      }
      return objects;
    } finally {
      if (transport) await LumixCameraService.closePtpTransport(transport);
    }
  }

  /** Read one object using standard PTP GetPartialObject chunks. */
  static async downloadUsbObject(objectHandle: number,
    progress?: (value: number) => void): Promise<Uint8Array> {
    const devices = LumixCameraService.scanUsbCameras();
    if (devices.length === 0) throw new Error('No Panasonic PTP camera');
    let transport: PtpTransport | undefined;
    try {
      transport = await LumixCameraService.openPtpTransport(devices[0]);
      let transactionId = 2;
      const infoData = await LumixCameraService.ptpTransaction(
        transport.pipe, transport.bulkOut, transport.bulkIn,
        PTP_OPERATION_GET_OBJECT_INFO, transactionId++, [objectHandle]);
      const info = LumixCameraService.parseObjectInfo(objectHandle,
        LumixCameraService.dataPayload(infoData, PTP_OPERATION_GET_OBJECT_INFO, transactionId - 1));
      if (!info || info.size <= 0 || info.size > 0xFFFFFFFF) throw new Error('Invalid PTP object size');
      const output = new Uint8Array(info.size);
      let offset = 0;
      const chunkSize = 512 * 1024;
      while (offset < info.size) {
        const requestSize = Math.min(chunkSize, info.size - offset);
        const containers = await LumixCameraService.ptpTransaction(
          transport.pipe, transport.bulkOut, transport.bulkIn,
          PTP_OPERATION_GET_PARTIAL_OBJECT, transactionId++,
          [objectHandle, offset, requestSize]);
        const payload = LumixCameraService.dataPayload(containers,
          PTP_OPERATION_GET_PARTIAL_OBJECT, transactionId - 1);
        if (payload.length === 0) throw new Error('Empty PTP object chunk');
        output.set(payload.subarray(0, Math.min(payload.length, requestSize)), offset);
        offset += Math.min(payload.length, requestSize);
        if (progress) progress(Math.round(offset * 100 / info.size));
      }
      return output;
    } finally {
      if (transport) await LumixCameraService.closePtpTransport(transport);
    }
  }

  /** Read the camera-generated thumbnail through standard PTP GetThumb. */
  static async downloadUsbThumbnail(objectHandle: number): Promise<Uint8Array> {
    const devices = LumixCameraService.scanUsbCameras();
    if (devices.length === 0) throw new Error('No Panasonic PTP camera');
    let transport: PtpTransport | undefined;
    try {
      transport = await LumixCameraService.openPtpTransport(devices[0]);
      const containers = await LumixCameraService.ptpTransaction(
        transport.pipe, transport.bulkOut, transport.bulkIn,
        PTP_OPERATION_GET_THUMB, 2, [objectHandle]);
      return LumixCameraService.dataPayload(containers, PTP_OPERATION_GET_THUMB, 2);
    } finally {
      if (transport) await LumixCameraService.closePtpTransport(transport);
    }
  }

  // -------------------------------------------------------------------------
  // USB control surface (Panasonic vendor PTP).
  //
  // The storage surface above (storage IDs → handles → ObjectInfo → GetObject)
  // was already complete; nothing could *drive* the body. Everything below uses
  // the vendor operations and 32-bit property codes documented in report §13.
  //
  // Three wire facts shape this code:
  //  * the vendor session (0x9102) must already be open — openPtpTransport()
  //    performs standard 0x1002 first, exactly as the public reference does;
  //  * value width differs per property (ISO/shutter 4 bytes, aperture/WB/EV 2);
  //  * DeviceBusy (0x2019) is a normal answer for liveview and capture, not a
  //    transport failure, so those paths must tolerate it.
  // -------------------------------------------------------------------------

  /** command → data-out → response. SetDevicePropValue needs the data phase. */
  private static async ptpDataOut(pipe: usbManager.USBDevicePipe,
    bulkOut: usbManager.USBEndpoint, bulkIn: usbManager.USBEndpoint,
    operation: number, transactionId: number, params: number[],
    payload: Uint8Array): Promise<PtpContainer[]> {
    const command = LumixCameraService.ptpOperation(operation, transactionId, params);
    const commandSent = await usbManager.bulkTransfer(pipe, bulkOut, command, 3000);
    if (commandSent < command.length) throw new Error('PTP command transfer incomplete');
    // Data container header is the same 12 bytes as every other container:
    // length, type, code (= the operation), transaction id, then the payload.
    const data = new Uint8Array(PTP_CONTAINER_HEADER_SIZE + payload.length);
    LumixCameraService.writeLe32(data, 0, data.length);
    LumixCameraService.writeLe16(data, 4, PTP_CONTAINER_DATA);
    LumixCameraService.writeLe16(data, 6, operation);
    LumixCameraService.writeLe32(data, 8, transactionId);
    data.set(payload, PTP_CONTAINER_HEADER_SIZE);
    const dataSent = await LumixCameraService.writeBulk(pipe, bulkOut, data);
    if (dataSent < data.length) throw new Error('PTP data transfer incomplete');
    return await LumixCameraService.collectPtpTransaction(pipe, bulkIn, transactionId);
  }

  /** Read-only vendor exchange: keeps the response code instead of throwing. */
  private static async vendorRead(pipe: usbManager.USBDevicePipe,
    bulkOut: usbManager.USBEndpoint, bulkIn: usbManager.USBEndpoint,
    operation: number, transactionId: number, params: number[]): Promise<LumixPtpReply> {
    const containers = await LumixCameraService.ptpTransaction(
      pipe, bulkOut, bulkIn, operation, transactionId, params);
    const code = LumixCameraService.responseCode(containers, transactionId);
    let payload = new Uint8Array(0);
    if (code === PTP_RESPONSE_OK) {
      const found = containers.find((container: PtpContainer) =>
        container.type === PTP_CONTAINER_DATA && container.code === operation &&
        container.transactionId === transactionId);
      if (found) payload = found.payload;
    }
    return { code: code, payload: payload };
  }

  /** Vendor exchange that carries a data phase out to the camera. */
  private static async vendorWrite(pipe: usbManager.USBDevicePipe,
    bulkOut: usbManager.USBEndpoint, bulkIn: usbManager.USBEndpoint,
    operation: number, transactionId: number, params: number[],
    payload: Uint8Array): Promise<number> {
    const containers = await LumixCameraService.ptpDataOut(
      pipe, bulkOut, bulkIn, operation, transactionId, params, payload);
    return LumixCameraService.responseCode(containers, transactionId);
  }

  /**
   * Property value out of a vendor reply.
   *
   * The camera answers GetDevicePropValue with a small header (property code +
   * payload length) before the value. Accept both shapes: with the header when
   * it fits, otherwise treat the buffer as the bare value.
   */
  private static propValueOf(payload: Uint8Array, size: number): number {
    let offset = 0;
    if (payload.length >= 8 + size) {
      offset = 8;
    } else if (payload.length < size) {
      return -1;
    }
    if (size === 1) return payload[offset];
    if (size === 2) return LumixCameraService.readLe16(payload, offset);
    return LumixCameraService.readLe32(payload, offset);
  }

  /**
   * Data phase for SetDevicePropValue: property code (4) + value width (4) +
   * value, little-endian. The property code is also the command parameter.
   */
  private static propValueBytes(propCode: number, size: number, value: number): Uint8Array {
    const out = new Uint8Array(8 + size);
    LumixCameraService.writeLe32(out, 0, propCode);
    LumixCameraService.writeLe32(out, 4, size);
    if (size === 1) {
      out[8] = value & 0xFF;
    } else if (size === 2) {
      LumixCameraService.writeLe16(out, 8, value & 0xFFFF);
    } else {
      LumixCameraService.writeLe32(out, 8, value);
    }
    return out;
  }

  /**
   * Locate the JPEG inside a liveview frame.
   *
   * The frame is not a bare JPEG: it starts with a chain of metadata blocks
   * (id, dataSize, sessionId, data). Block id 0x17000001 carries the JPEG
   * offset at blockStart+12. Ported from the public reference parser, which
   * also falls back to scanning for the SOI marker when the block is absent.
   */
  private static liveviewJpeg(data: Uint8Array): Uint8Array | undefined {
    if (data.length < 4) return undefined;
    const scanLimit = 180;
    let jpegOffset = 180;
    let offset = 0;
    while (offset + 8 <= scanLimit && offset + 8 <= data.length) {
      const id = LumixCameraService.readLe32(data, offset);
      const dataSize = LumixCameraService.readLe32(data, offset + 4);
      if (dataSize < 0 || offset + 8 + dataSize > data.length) break;
      const valueAt = offset + 12;
      if (id === 0x17000001 && valueAt + 4 <= data.length) {
        jpegOffset = LumixCameraService.readLe32(data, valueAt);
      }
      offset += 8 + dataSize;
    }
    return LumixCameraService.jpegFrom(data, jpegOffset);
  }

  private static jpegFrom(data: Uint8Array, offset: number): Uint8Array | undefined {
    if (offset <= 0 || offset >= data.length) return undefined;
    if (data[offset] === 0xFF && data[offset + 1] === 0xD8) return data.subarray(offset);
    const searchEnd = Math.min(data.length - 1, offset + 64);
    for (let index = offset; index < searchEnd; index++) {
      if (data[index] === 0xFF && data[index + 1] === 0xD8) return data.subarray(index);
    }
    return undefined;
  }

  /**
   * Run the control probe on every USB handshake.
   *
   * On while the USB control path is still being validated on real bodies; it
   * costs a few seconds per connection, so switch it off once verified — photo
   * import should not pay for it.
   */
  static usbControlProbeEnabled: boolean = true;

  /**
   * Read-only probe of the control surface.
   *
   * Runs inside the USB handshake so a single connection produces the complete
   * evidence trail in the uploaded log — no UI, no extra taps. It never writes
   * a setting and never fires the shutter; it only reads properties and grabs
   * one liveview frame.
   */
  static async usbProbeControl(pipe: usbManager.USBDevicePipe,
    bulkOut: usbManager.USBEndpoint, bulkIn: usbManager.USBEndpoint,
    startId: number): Promise<LumixUsbControlProbe> {
    const notes: string[] = [];
    let transactionId = startId;
    let okCount = 0;

    const probes: string[] = ['ISO', 'shutter', 'aperture', 'whitebalance', 'exposure', 'mode'];
    const codes: number[] = [LUMIX_PROP_ISO, LUMIX_PROP_SHUTTER, LUMIX_PROP_APERTURE,
      LUMIX_PROP_WHITE_BALANCE, LUMIX_PROP_EXPOSURE, LUMIX_PROP_MODE_POS];
    const sizes: number[] = [4, 4, 2, 2, 2, 2];
    for (let index = 0; index < codes.length; index++) {
      try {
        const reply = await LumixCameraService.vendorRead(
          pipe, bulkOut, bulkIn, PTP_OPERATION_LUMIX_GET_PROP_VALUE, transactionId++, [codes[index]]);
        if (reply.code === PTP_RESPONSE_OK) {
          const value = LumixCameraService.propValueOf(reply.payload, sizes[index]);
          okCount += 1;
          notes.push(`${probes[index]}=${LumixCameraService.hexCode(value)}(${value})`);
        } else {
          notes.push(`${probes[index]}=${LumixCameraService.hexCode(reply.code)}`);
        }
      } catch (error) {
        notes.push(`${probes[index]}=ERR(${String(error).substring(0, 40)})`);
      }
    }

    let liveviewModes = 0;
    try {
      const recommended = await LumixCameraService.vendorRead(pipe, bulkOut, bulkIn,
        PTP_OPERATION_LUMIX_GET_LIVEVIEW_SETTINGS, transactionId++, [LUMIX_PARAM_LIVEVIEW_RECOM_IMG]);
      if (recommended.code === PTP_RESPONSE_OK && recommended.payload.length >= 12) {
        liveviewModes = LumixCameraService.readLe16(recommended.payload, 8);
        notes.push(`liveviewModes=${liveviewModes}`);
      } else {
        notes.push(`liveviewModes=${LumixCameraService.hexCode(recommended.code)}`);
      }
    } catch (error) {
      notes.push(`liveviewModes=ERR(${String(error).substring(0, 40)})`);
    }

    // One frame proves the streaming path without leaving the camera streaming.
    let frameBytes = -1;
    let jpegBytes = -1;
    try {
      const started = await LumixCameraService.vendorRead(pipe, bulkOut, bulkIn,
        PTP_OPERATION_LUMIX_LIVEVIEW, transactionId++, [LUMIX_PARAM_LIVEVIEW_START]);
      notes.push(`liveviewStart=${LumixCameraService.hexCode(started.code)}`);
      for (let attempt = 0; attempt < 6 && jpegBytes < 0; attempt++) {
        const frame = await LumixCameraService.vendorRead(pipe, bulkOut, bulkIn,
          PTP_OPERATION_LUMIX_LIVEVIEW_IMAGE, transactionId++, []);
        if (frame.code !== PTP_RESPONSE_OK || frame.payload.length === 0) {
          // DeviceBusy while the camera settles is expected; retry briefly.
          await LumixCameraService.delay(200);
          continue;
        }
        frameBytes = frame.payload.length;
        const jpeg = LumixCameraService.liveviewJpeg(frame.payload);
        if (jpeg !== undefined && jpeg.length > 0) jpegBytes = jpeg.length;
      }
      notes.push(`liveviewFrame=${frameBytes}B jpeg=${jpegBytes}B`);
    } catch (error) {
      notes.push(`liveviewFrame=ERR(${String(error).substring(0, 40)})`);
    } finally {
      try {
        await LumixCameraService.vendorRead(pipe, bulkOut, bulkIn,
          PTP_OPERATION_LUMIX_LIVEVIEW, transactionId++, [LUMIX_PARAM_LIVEVIEW_STOP]);
      } catch (_ignored) {
        // The cable may already be gone; the session teardown still runs.
      }
    }

    const summary = `控制面 读=${okCount}/6 · LV模式=${liveviewModes} · 帧=${jpegBytes >= 0 ? jpegBytes : 'none'}B`;
    LumixCameraService.logBoth(0x0001, 'VIVID_USB', `control probe ${summary} :: ${notes.join(' | ')}`);
    return { ok: okCount > 0, summary: summary, notes: notes };
  }

  /** Read one Panasonic device property over USB (opens its own session). */
  static async usbReadProperty(propCode: number, size: number): Promise<number> {
    const devices = LumixCameraService.scanUsbCameras();
    if (devices.length === 0) throw new Error('No Panasonic PTP camera');
    let transport: PtpTransport | undefined;
    try {
      transport = await LumixCameraService.openPtpTransport(devices[0]);
      const reply = await LumixCameraService.vendorRead(transport.pipe, transport.bulkOut,
        transport.bulkIn, PTP_OPERATION_LUMIX_GET_PROP_VALUE, 2, [propCode]);
      if (reply.code !== PTP_RESPONSE_OK) {
        throw new Error(`GetDevicePropValue ${LumixCameraService.hexCode(reply.code)}`);
      }
      return LumixCameraService.propValueOf(reply.payload, size);
    } finally {
      if (transport) await LumixCameraService.closePtpTransport(transport);
    }
  }

  /**
   * Write one Panasonic device property over USB.
   *
   * Returns the response code so callers can tell "camera said no" from
   * "transport broke". Note the known LUMIX behaviour: an unsupported or
   * out-of-range value can still answer OK (0x2001) without taking effect, so
   * callers should read the value back and compare.
   */
  static async usbWriteProperty(propCode: number, size: number, value: number): Promise<number> {
    const devices = LumixCameraService.scanUsbCameras();
    if (devices.length === 0) throw new Error('No Panasonic PTP camera');
    let transport: PtpTransport | undefined;
    try {
      transport = await LumixCameraService.openPtpTransport(devices[0]);
      const payload = LumixCameraService.propValueBytes(propCode, size, value);
      const code = await LumixCameraService.vendorWrite(transport.pipe, transport.bulkOut,
        transport.bulkIn, PTP_OPERATION_LUMIX_SET_PROP_VALUE, 2, [propCode], payload);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB',
        `set prop=${LumixCameraService.hexCode(propCode)} value=${value} -> ${LumixCameraService.hexCode(code)}`);
      return code;
    } finally {
      if (transport) await LumixCameraService.closePtpTransport(transport);
    }
  }

  /** Fire the shutter over USB. DeviceBusy means "not yet", not "failed". */
  static async usbCapture(): Promise<number> {
    const devices = LumixCameraService.scanUsbCameras();
    if (devices.length === 0) throw new Error('No Panasonic PTP camera');
    let transport: PtpTransport | undefined;
    try {
      transport = await LumixCameraService.openPtpTransport(devices[0]);
      // InitiateCapture is command-only on the wire: no data phase. Sending an
      // empty data container here made the camera reject the operation.
      const reply = await LumixCameraService.vendorRead(transport.pipe, transport.bulkOut,
        transport.bulkIn, PTP_OPERATION_LUMIX_CAPTURE, 2, [LUMIX_PARAM_CAPTURE]);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB', `capture -> ${LumixCameraService.hexCode(reply.code)}`);
      return reply.code;
    } finally {
      if (transport) await LumixCameraService.closePtpTransport(transport);
    }
  }

  /** Trigger autofocus over USB. */
  static async usbAutofocus(): Promise<number> {
    const devices = LumixCameraService.scanUsbCameras();
    if (devices.length === 0) throw new Error('No Panasonic PTP camera');
    let transport: PtpTransport | undefined;
    try {
      transport = await LumixCameraService.openPtpTransport(devices[0]);
      const reply = await LumixCameraService.vendorRead(transport.pipe, transport.bulkOut,
        transport.bulkIn, PTP_OPERATION_LUMIX_CTRL_LIVEVIEW, 2, [LUMIX_PARAM_AUTOFOCUS]);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB', `autofocus -> ${LumixCameraService.hexCode(reply.code)}`);
      return reply.code;
    } finally {
      if (transport) await LumixCameraService.closePtpTransport(transport);
    }
  }

  private static async openPtpTransport(device: Readonly<usbManager.USBDevice>): Promise<PtpTransport> {
    let pipe: usbManager.USBDevicePipe | undefined;
    let iface: usbManager.USBInterface | undefined;
    let transport: PtpTransport | undefined;
    try {
      // 取图链路（listUsbObjects / download）走的也是这里，同样需要描述符留痕。
      LumixCameraService.logBoth(0x0001, 'VIVID_USB',
        `open transport ${LumixCameraService.describeUsbDevice(device)}`);
      const granted = await LumixCameraService.ensureUsbRight(device.name);
      if (!granted) throw new Error('USB permission denied');
      pipe = usbManager.connectDevice(device as usbManager.USBDevice);
      if (!pipe) throw new Error('USB pipe unavailable');
      const selection = LumixCameraService.findPtpInterface(device);
      if (!selection) throw new Error('PTP interface unavailable');
      iface = selection.iface;
      const configResult = usbManager.setConfiguration(pipe, selection.config);
      if (configResult !== 0) throw new Error(`USB configuration ${configResult}`);
      const claimed = usbManager.claimInterface(pipe, iface, true);
      if (claimed !== 0) throw new Error(`USB claim ${claimed}`);
      const interfaceResult = usbManager.setInterface(pipe, iface);
      if (interfaceResult !== 0) throw new Error(`USB interface ${interfaceResult}`);
      transport = {
        pipe: pipe, iface: iface, bulkIn: selection.bulkIn, bulkOut: selection.bulkOut,
        sessionOpened: false, lumixSessionOpened: false,
      };
      await LumixCameraService.clearEndpointHalt(pipe, selection.bulkOut, 'out');
      await LumixCameraService.clearEndpointHalt(pipe, selection.bulkIn, 'in');
      const opened = await LumixCameraService.ptpTransaction(
        pipe, selection.bulkOut, selection.bulkIn, PTP_OPERATION_OPEN_SESSION, 0, [1]);
      const openCode = LumixCameraService.responseCode(opened, 0);
      if (openCode !== PTP_RESPONSE_OK && openCode !== PTP_RESPONSE_SESSION_ALREADY_OPEN) {
        throw new Error(`PTP OpenSession ${LumixCameraService.hexCode(openCode)}`);
      }
      transport.sessionOpened = true;
      const lumixOpened = await LumixCameraService.ptpTransaction(
        pipe, selection.bulkOut, selection.bulkIn, PTP_OPERATION_LUMIX_OPEN_SESSION, 1, [LUMIX_CONNECT_VERSION]);
      const lumixCode = LumixCameraService.responseCode(lumixOpened, 1);
      if (lumixCode !== PTP_RESPONSE_OK && lumixCode !== PTP_RESPONSE_SESSION_ALREADY_OPEN) {
        throw new Error(`LUMIX Open_Session ${LumixCameraService.hexCode(lumixCode)}`);
      }
      transport.lumixSessionOpened = true;
      return transport;
    } catch (error) {
      if (transport) await LumixCameraService.closePtpTransport(transport);
      else if (pipe && iface) {
        try { usbManager.releaseInterface(pipe, iface); } catch (_ignored) {}
        try { usbManager.closePipe(pipe); } catch (_ignored) {}
      } else if (pipe) {
        try { usbManager.closePipe(pipe); } catch (_ignored) {}
      }
      throw new Error(String(error));
    }
  }

  private static async closePtpTransport(transport: PtpTransport): Promise<void> {
    if (transport.lumixSessionOpened) {
      try {
        await LumixCameraService.ptpTransaction(transport.pipe, transport.bulkOut, transport.bulkIn,
          PTP_OPERATION_LUMIX_CLOSE_SESSION, 0xFFFFFFFE, []);
      } catch (_error) {}
    }
    if (transport.sessionOpened) {
      try {
        await LumixCameraService.ptpTransaction(transport.pipe, transport.bulkOut, transport.bulkIn,
          PTP_OPERATION_CLOSE_SESSION, 0xFFFFFFFF, []);
      } catch (_error) {}
    }
    try { usbManager.releaseInterface(transport.pipe, transport.iface); } catch (_error) {}
    try { usbManager.closePipe(transport.pipe); } catch (_error) {}
  }

  /**
   * Perform the same connection/authorization/session sequence as the
   * official Lumix Remote Control Library sample: request USB access, select
   * the Still Image interface, open the standard PTP session, perform the
   * LUMIX vendor session authorization with SDK connect version 0x00010001,
   * read DeviceInfo, then close both sessions before releasing the interface.
   * The native Panasonic DLL cannot be loaded by a HarmonyOS HAP, so its wire
   * protocol is reproduced with usbManager here.
   */
  static async connectUsbCamera(): Promise<LumixUsbConnectionResult> {
    const devices = LumixCameraService.scanUsbCameras();
    if (devices.length === 0) {
      return {
        connected: false,
        message: '未发现 USB PTP 相机，请连接并解锁相机；若相机显示 PC(Storage)，请切换到支持 PTP 的 USB 模式',
        model: '',
        imageKey: '',
      };
    }
    const device = devices[0];
    LumixCameraService.logBoth(0x0001, 'VIVID_USB',
      `handshake start devices=${devices.length} ${LumixCameraService.describeUsbDevice(device)}`);
    let pipe: usbManager.USBDevicePipe | undefined = undefined;
    let iface: usbManager.USBInterface | undefined = undefined;
    let bulkIn: usbManager.USBEndpoint | undefined = undefined;
    let bulkOut: usbManager.USBEndpoint | undefined = undefined;
    let sessionOpened = false;
    let lumixSessionOpened = false;
    try {
      const granted = await LumixCameraService.ensureUsbRight(device.name);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB', `handshake right granted=${granted ? 1 : 0}`);
      if (!granted) {
        return { connected: false, message: '未获得 USB 设备授权，请在系统弹窗中允许访问', model: '', imageKey: '' };
      }
      pipe = usbManager.connectDevice(device as usbManager.USBDevice);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB', `handshake pipe ok=${pipe !== undefined && pipe !== null ? 1 : 0}`);
      if (!pipe) {
        return { connected: false, message: '无法打开 USB 相机设备管道', model: '', imageKey: '' };
      }
      const selection = LumixCameraService.findPtpInterface(device);
      if (!selection) {
        LumixCameraService.logBoth(0x0001, 'VIVID_USB', 'handshake no PTP interface matched');
        return {
          connected: false,
          message: 'USB 设备未提供相机 PTP 接口；当前可能是 PC(Storage) 模式，请切换到 PTP/PC(Tether) 模式',
          model: '',
          imageKey: '',
        };
      }
      LumixCameraService.logBoth(0x0001, 'VIVID_USB',
        `handshake iface class=${selection.iface.clazz}/${selection.iface.subClass}/${selection.iface.protocol}` +
        ` bulkIn=0x${selection.bulkIn.address.toString(16)} bulkOut=0x${selection.bulkOut.address.toString(16)}`);
      const configResult = usbManager.setConfiguration(pipe, selection.config);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB', `handshake setConfiguration=${configResult}`);
      if (configResult !== 0) {
        return { connected: false, message: `无法设置 USB 相机配置（${configResult}）`, model: '', imageKey: '' };
      }
      iface = selection.iface;
      bulkIn = selection.bulkIn;
      bulkOut = selection.bulkOut;
      const claimed = usbManager.claimInterface(pipe, iface, true);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB', `handshake claimInterface=${claimed}`);
      if (claimed !== 0) {
        return { connected: false, message: `无法占用相机 USB 接口（${claimed}），请关闭其他相机软件后重试`, model: '', imageKey: '' };
      }
      const interfaceResult = usbManager.setInterface(pipe, iface);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB', `handshake setInterface=${interfaceResult}`);
      if (interfaceResult !== 0) {
        return { connected: false, message: `无法激活相机 PTP 接口（${interfaceResult}）`, model: '', imageKey: '' };
      }

      // 先把两端点的 halt 清掉：相机侧 stall 过之后，重新 claim 不会自动恢复，
      // 表现就是「命令写不进去、整整超时 3 秒」（2026-10-21 14:07 实测）。
      await LumixCameraService.clearEndpointHalt(pipe, selection.bulkOut, 'out');
      await LumixCameraService.clearEndpointHalt(pipe, selection.bulkIn, 'in');
      await LumixCameraService.primeInterruptEndpoint(pipe, selection.iface);
      // setInterface 之后相机需要一点时间把 PTP 端点挂上；立刻写会被 NAK 到
      // 超时（2026-10-21 06:10 实测：setInterface 后 9 ms 写入，3 s 超时）。
      await LumixCameraService.delay(200);

      // Official sample passes LMX_CONNECT_VERSION 0x00010001 to
      // LMX_func_api_Open_Session; the equivalent USB PTP operation is
      // OpenSession(session 1, transaction 0).
      let openContainers: PtpContainer[] = [];
      try {
        openContainers = await LumixCameraService.ptpTransaction(
          pipe, bulkOut, bulkIn, PTP_OPERATION_OPEN_SESSION, 0, [1]);
      } catch (firstError) {
        // 写超时基本只剩「端点/管道状态坏了」这一种自愈路径：复位端口后按原
        // 顺序重建一次，再试同一笔事务。
        LumixCameraService.logBoth(0x0001, 'VIVID_USB',
          `OpenSession attempt1 failed: ${String(firstError).substring(0, 120)}; resetting port`);
        let resetOk = false;
        try {
          resetOk = usbManager.resetUsbDevice(pipe);
        } catch (_resetError) {
          resetOk = false;
        }
        LumixCameraService.logBoth(0x0001, 'VIVID_USB', `port reset=${resetOk ? 1 : 0}`);
        // 复位失败时旧管道已经废了（实测 cfg=-17 claim=-1 alt=-1），必须整条
        // 重开：释放接口 → 关管道 → 重新 connectDevice → 重做配置/占用/激活。
        try {
          usbManager.releaseInterface(pipe, selection.iface);
        } catch (_releaseError) {
        }
        try {
          usbManager.closePipe(pipe);
        } catch (_closeError) {
        }
        const reopened = usbManager.connectDevice(device as usbManager.USBDevice);
        if (!reopened) {
          throw new Error('USB 管道重开后为空');
        }
        pipe = reopened;
        const cfg2 = usbManager.setConfiguration(pipe, selection.config);
        const claim2 = usbManager.claimInterface(pipe, selection.iface, true);
        const alt2 = usbManager.setInterface(pipe, selection.iface);
        LumixCameraService.logBoth(0x0001, 'VIVID_USB',
          `reopen cfg=${cfg2} claim=${claim2} alt=${alt2}`);
        // 给相机一点时间把 PTP 端点重新挂上：setInterface 之后立刻写，真机上
        // 会被设备 NAK 到超时。
        await LumixCameraService.delay(300);
        await LumixCameraService.clearEndpointHalt(pipe, selection.bulkOut, 'out2');
        await LumixCameraService.clearEndpointHalt(pipe, selection.bulkIn, 'in2');
        openContainers = await LumixCameraService.ptpTransaction(
          pipe, bulkOut, bulkIn, PTP_OPERATION_OPEN_SESSION, 0, [1]);
      }
      const openCode = LumixCameraService.responseCode(openContainers, 0);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB',
        `handshake OpenSession(0x1002)=${LumixCameraService.hexCode(openCode)}`);
      // 上一次连接被中断（应用被杀、线被拔）时，相机会保留半开会话并回
      // SessionAlreadyOpen。openPtpTransport() 早就把这种情况当成功，这里却
      // 只认 OK——两次实现不一致会让「重插一下就好了」变成「怎么都不行」。
      if (openCode !== PTP_RESPONSE_OK && openCode !== PTP_RESPONSE_SESSION_ALREADY_OPEN) {
        return { connected: false, message: LumixCameraService.openSessionMessage(openCode), model: '', imageKey: '' };
      }
      sessionOpened = true;

      // LUMIX Lab performs a second, Panasonic-specific session authorization
      // after PTP OpenSession. This is the wire-level counterpart of the
      // official SDK's Open_Session(0x00010001, ...), which is hidden by the
      // Windows DLL. Keep it as a separate transaction so the response can be
      // distinguished from the standard PTP session response.
      const lumixOpenContainers = await LumixCameraService.ptpTransaction(
        pipe, bulkOut, bulkIn, PTP_OPERATION_LUMIX_OPEN_SESSION, 1, [LUMIX_CONNECT_VERSION]);
      const lumixOpenCode = LumixCameraService.responseCode(lumixOpenContainers, 1);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB',
        `handshake LUMIX OpenSession(0x9102)=${LumixCameraService.hexCode(lumixOpenCode)}`);
      if (lumixOpenCode !== PTP_RESPONSE_OK &&
        lumixOpenCode !== PTP_RESPONSE_SESSION_ALREADY_OPEN) {
        return {
          connected: false,
          message: LumixCameraService.lumixSessionMessage(lumixOpenCode),
          model: '',
          imageKey: '',
        };
      }
      lumixSessionOpened = true;

      // GetDeviceInfo has a DATA container followed by a RESPONSE container;
      // consume both instead of treating the first data packet as an error.
      const infoContainers = await LumixCameraService.ptpTransaction(
        pipe, bulkOut, bulkIn, PTP_OPERATION_GET_DEVICE_INFO, 2, []);
      const infoCode = LumixCameraService.responseCode(infoContainers, 2);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB',
        `handshake GetDeviceInfo=${LumixCameraService.hexCode(infoCode)}`);
      if (infoCode !== PTP_RESPONSE_OK) {
        return { connected: false, message: `USB PTP 设备信息读取失败（${LumixCameraService.hexCode(infoCode)}）`, model: '', imageKey: '' };
      }
      const infoData = infoContainers.find((container: PtpContainer) =>
        container.type === PTP_CONTAINER_DATA &&
        container.code === PTP_OPERATION_GET_DEVICE_INFO && container.transactionId === 2);
      const deviceInfo = infoData ? LumixCameraService.parseDeviceInfo(infoData.payload) : undefined;
      const model = deviceInfo?.model || device.productName || device.manufacturerName || 'LUMIX Camera';
      const manufacturer = deviceInfo?.manufacturer || device.manufacturerName || 'Panasonic';
      // Control-surface probe: one connection is enough to prove the whole
      // control path, and every step lands in the uploaded app log. A high
      // transaction-id base keeps it clear of the teardown ids below.
      let controlNote = '';
      if (LumixCameraService.usbControlProbeEnabled) {
        try {
          const probe = await LumixCameraService.usbProbeControl(pipe, bulkOut, bulkIn, 0x00010000);
          controlNote = ` · ${probe.summary}`;
        } catch (_error) {
          controlNote = ' · 控制面探测异常';
        }
      }
      return {
        connected: true,
        message: `USB PTP 握手成功 · ${manufacturer} · SDK ${LumixCameraService.hexCode(LUMIX_CONNECT_VERSION)}${controlNote}`,
        model: model,
        imageKey: LumixCameraService.imageKeyForModel(model),
      };
    } catch (error) {
      // 旧代码在这里把异常吞掉、只回一句通用文案，日志里连「哪一步爆的」都没有。
      const reason = String(error);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB',
        `handshake failed: ${reason.substring(0, 160)}`);
      return {
        connected: false,
        message: `USB 相机握手失败（${reason.substring(0, 60)}）`,
        model: '',
        imageKey: '',
      };
    } finally {
      if (lumixSessionOpened && pipe && bulkOut && bulkIn) {
        try {
          await LumixCameraService.ptpTransaction(
            pipe, bulkOut, bulkIn, PTP_OPERATION_LUMIX_CLOSE_SESSION, 3, []);
        } catch (_error) {
          // The camera may have already dropped the vendor session with the
          // cable; the standard session and pipe still get cleaned up below.
        }
      }
      if (sessionOpened && pipe && bulkOut && bulkIn) {
        try {
          await LumixCameraService.ptpTransaction(
            pipe, bulkOut, bulkIn, PTP_OPERATION_CLOSE_SESSION, 4, []);
        } catch (_error) {
          // The pipe is still released below if the camera disconnects first.
        }
      }
      if (pipe && iface) {
        try { usbManager.releaseInterface(pipe, iface); } catch (_ignored) {}
      }
      if (pipe) {
        try { usbManager.closePipe(pipe); } catch (_ignored) {}
      }
    }
  }

  private static ptpOperation(code: number, transactionId: number, params: number[]): Uint8Array {
    const packet = new Uint8Array(PTP_CONTAINER_HEADER_SIZE + params.length * 4);
    LumixCameraService.writeLe32(packet, 0, packet.length);
    LumixCameraService.writeLe16(packet, 4, PTP_CONTAINER_COMMAND);
    LumixCameraService.writeLe16(packet, 6, code);
    LumixCameraService.writeLe32(packet, 8, transactionId);
    for (let index = 0; index < params.length; index++) {
      LumixCameraService.writeLe32(packet, PTP_CONTAINER_HEADER_SIZE + index * 4, params[index]);
    }
    return packet;
  }

  private static async ensureUsbRight(deviceName: string): Promise<boolean> {
    try {
      if (usbManager.hasRight(deviceName)) return true;
    } catch (_error) {
      // Fall through to requestRight so the system can re-authorize the device.
    }
    return await usbManager.requestRight(deviceName);
  }

  /**
   * 紧凑的 USB 描述符摘要。
   *
   * USB 握手失败时，旧代码只在页面上回一句「握手失败」，日志里一个字都没有，
   * 无法判断是没授权、没找到 PTP 接口、还是端点选错。把这个摘要打出来，就能
   * 从日志还原「相机到底暴露了哪些接口和端点」。
   */
  private static describeUsbDevice(device: Readonly<usbManager.USBDevice>): string {
    const parts: string[] = [];
    const vid = device.vendorId !== undefined ? device.vendorId.toString(16) : '?';
    const pid = device.productId !== undefined ? device.productId.toString(16) : '?';
    parts.push(`vid=0x${vid} pid=0x${pid}`);
    parts.push(`class=${device.clazz}/${device.subClass}/${device.protocol}`);
    const name = device.productName !== undefined ? device.productName : '';
    if (name.length > 0) {
      parts.push(`name=${name}`);
    }
    const configs = device.configs || [];
    for (let ci = 0; ci < configs.length; ci++) {
      const interfaces = configs[ci].interfaces || [];
      for (let ii = 0; ii < interfaces.length; ii++) {
        const candidate = interfaces[ii];
        let endpoints = '';
        const eps = candidate.endpoints || [];
        for (let ei = 0; ei < eps.length; ei++) {
          endpoints += ` ep0x${eps[ei].address.toString(16)}:t${eps[ei].type}:d${eps[ei].direction}` +
            `:m${eps[ei].maxPacketSize}`;
        }
        parts.push(`cfg${ci}/if${ii}=${candidate.clazz}/${candidate.subClass}/${candidate.protocol}${endpoints}`);
      }
    }
    return parts.join(' ');
  }

  /**
   * 选一个可用的 PTP 数据接口。
   *
   * 严格档：Still Image/PTP（class 0x06 + subclass 0x01 + protocol 0x01），或接口
   * 名里带 PTP/STILL IMAGE。这一档优先，保持既有行为不变。
   *
   * 放宽档：2026-10-21 14:05 的日志里，S1RM2 在 PC(Tether) 模式下三次都回
   * 「USB 设备未提供相机 PTP 接口」——设备枚举到了，但没有任何接口命中严格档。
   * PTP 批量传输的物理要求只是「同一接口上有一对 bulk IN/OUT」，接口类别并不
   * 参与收发，所以退回到「任意同时具备 bulk IN/OUT 的接口」，让握手用真实的
   * OpenSession 响应码去判断对错，而不是在选接口这一步就把设备判死。
   */
  private static findPtpInterface(device: Readonly<usbManager.USBDevice>): PtpInterfaceSelection | null {
    const configurations = device.configs || [];
    let relaxed: PtpInterfaceSelection | null = null;
    for (const config of configurations) {
      for (const candidate of config.interfaces) {
        const bulkIn = candidate.endpoints.find((endpoint: usbManager.USBEndpoint) =>
          endpoint.type === 2 && endpoint.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_FROM_DEVICE);
        const bulkOut = candidate.endpoints.find((endpoint: usbManager.USBEndpoint) =>
          endpoint.type === 2 && endpoint.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_TO_DEVICE);
        if (!bulkIn || !bulkOut) {
          continue;
        }
        const interfaceName = (candidate.name || '').toUpperCase();
        const classMatches = candidate.clazz === USB_PTP_INTERFACE_CLASS &&
          (candidate.subClass === USB_PTP_INTERFACE_SUBCLASS || candidate.subClass === 0) &&
          (candidate.protocol === USB_PTP_INTERFACE_PROTOCOL || candidate.protocol === 0);
        if (classMatches || interfaceName.indexOf('PTP') >= 0 ||
          interfaceName.indexOf('STILL IMAGE') >= 0) {
          return { config: config, iface: candidate, bulkIn: bulkIn, bulkOut: bulkOut };
        }
        if (relaxed === null) {
          relaxed = { config: config, iface: candidate, bulkIn: bulkIn, bulkOut: bulkOut };
        }
      }
    }
    return relaxed;
  }

  /**
   * 异步提交一次 bulk OUT（usbSubmitTransfer，API 18+）。
   *
   * 同步 `bulkTransfer()` 对这台 S1RM2 恒定返回 -1（URB 超时），而同一时刻
   * 控制传输、管道重开、清 halt 全部成功——说明链路本身是好的，失效点在旧
   * 的同步 bulk 接口上。OHOS 同时提供新旧两套接口，这里用新接口再试一次。
   */
  private static submitBulkOut(pipe: usbManager.USBDevicePipe, endpoint: usbManager.USBEndpoint,
    buffer: Uint8Array, timeoutMs: number): Promise<number> {
    return new Promise<number>((resolve: (value: number) => void) => {
      const params: usbManager.UsbDataTransferParams = {
        devPipe: pipe,
        flags: usbManager.UsbTransferFlags.USB_TRANSFER_SHORT_NOT_OK,
        endpoint: endpoint.address,
        type: usbManager.UsbEndpointTransferType.TRANSFER_TYPE_BULK,
        timeout: timeoutMs,
        length: buffer.length,
        callback: (error: BusinessError, data: usbManager.SubmitTransferCallback): void => {
          if (error !== undefined && error !== null) {
            resolve(-1);
            return;
          }
          resolve(data !== undefined && data !== null ? data.actualLength : -1);
        },
        userData: buffer,
        buffer: buffer,
        isoPacketCount: 0,
      };
      try {
        usbManager.usbSubmitTransfer(params);
      } catch (error) {
        LumixCameraService.logBoth(0x0001, 'VIVID_USB',
          `submit transfer rejected: ${String(error).substring(0, 80)}`);
        resolve(-1);
      }
    });
  }

  /** 写一段 bulk 数据：先走同步接口，失败再走异步接口，并把两次数值记下来。 */
  private static async writeBulk(pipe: usbManager.USBDevicePipe, endpoint: usbManager.USBEndpoint,
    buffer: Uint8Array): Promise<number> {
    let sent = -1;
    try {
      sent = await usbManager.bulkTransfer(pipe, endpoint, buffer, 3000);
    } catch (_error) {
      sent = -1;
    }
    if (sent >= buffer.length) {
      return sent;
    }
    const asyncSent = await LumixCameraService.submitBulkOut(pipe, endpoint, buffer, 3000);
    LumixCameraService.logBoth(0x0001, 'VIVID_USB',
      `bulk out ep=0x${endpoint.address.toString(16)} sync=${sent} async=${asyncSent} want=${buffer.length}`);
    return asyncSent;
  }

  /**
   * 在中断端点上提交一次读取，把「事件通道」打开。
   *
   * 标准 PTP 规定事件走 interrupt IN，而部分机身（含松下）要求主机先在该端点
   * 上发起读取，才会开始接受 bulk 命令；主机只做 bulk 时设备会一直 NAK。
   * 读不到数据是正常的（说明没有事件），这里只记录结果，不抛错。
   */
  private static async primeInterruptEndpoint(pipe: usbManager.USBDevicePipe,
    iface: usbManager.USBInterface): Promise<void> {
    const endpoints = iface.endpoints || [];
    for (let index = 0; index < endpoints.length; index++) {
      const endpoint = endpoints[index];
      if (endpoint.type !== 3 ||
        endpoint.direction !== usbManager.USBRequestDirection.USB_REQUEST_DIR_FROM_DEVICE) {
        continue;
      }
      try {
        const buffer = new Uint8Array(64);
        const received = await usbManager.bulkTransfer(pipe, endpoint, buffer, 120);
        LumixCameraService.logBoth(0x0001, 'VIVID_USB',
          `prime interrupt ep=0x${endpoint.address.toString(16)} ret=${received}`);
      } catch (error) {
        LumixCameraService.logBoth(0x0001, 'VIVID_USB',
          `prime interrupt ep=0x${endpoint.address.toString(16)} error: ${String(error).substring(0, 60)}`);
      }
      return;
    }
  }

  private static async ptpTransaction(pipe: usbManager.USBDevicePipe,
    bulkOut: usbManager.USBEndpoint, bulkIn: usbManager.USBEndpoint,
    operation: number, transactionId: number, params: number[]): Promise<PtpContainer[]> {
    const command = LumixCameraService.ptpOperation(operation, transactionId, params);
    const sent = await LumixCameraService.writeBulk(pipe, bulkOut, command);
    if (sent < command.length) {
      throw new Error(`PTP command transfer incomplete sent=${sent} want=${command.length} ` +
        `op=0x${operation.toString(16)} ep=0x${bulkOut.address.toString(16)}`);
    }
    return await LumixCameraService.collectPtpTransaction(pipe, bulkIn, transactionId);
  }

  /**
   * 清掉端点的 halt 状态。
   *
   * 相机侧一旦把端点 stall 住，之后所有 bulk 传输都会超时，而重新
   * claimInterface 并不会自动清掉它。标准做法是发一次
   * CLEAR_FEATURE(ENDPOINT_HALT) 控制请求。
   */
  private static async clearEndpointHalt(pipe: usbManager.USBDevicePipe,
    endpoint: usbManager.USBEndpoint, tag: string): Promise<void> {
    try {
      const params: usbManager.USBDeviceRequestParams = {
        bmRequestType: 0x02, // host→device, standard, recipient=endpoint
        bRequest: 0x01,     // CLEAR_FEATURE
        wValue: 0x0000,     // ENDPOINT_HALT
        wIndex: endpoint.address,
        wLength: 0,
        data: new Uint8Array(0),
      };
      const result = await usbManager.usbControlTransfer(pipe, params, 1000);
      LumixCameraService.logBoth(0x0001, 'VIVID_USB',
        `clear halt ${tag} ep=0x${endpoint.address.toString(16)} ret=${result}`);
    } catch (error) {
      LumixCameraService.logBoth(0x0001, 'VIVID_USB',
        `clear halt ${tag} ep=0x${endpoint.address.toString(16)} error: ${String(error).substring(0, 80)}`);
    }
  }

  private static async collectPtpTransaction(pipe: usbManager.USBDevicePipe,
    bulkIn: usbManager.USBEndpoint, transactionId: number): Promise<PtpContainer[]> {
    let pending = new Uint8Array(0);
    const containers: PtpContainer[] = [];
    // A response may be split across several USB bulk packets. Keep the
    // incomplete tail and parse only complete PTP containers; this is required
    // for ObjectInfo and partial object data on real cameras.
    for (let attempt = 0; attempt < 512; attempt++) {
      const buffer = new Uint8Array(64 * 1024);
      const received = await usbManager.bulkTransfer(pipe, bulkIn, buffer, 3000);
      if (received <= 0) throw new Error('PTP response transfer failed');
      const merged = new Uint8Array(pending.length + received);
      merged.set(pending, 0);
      merged.set(buffer.subarray(0, received), pending.length);
      const parsed = LumixCameraService.parsePtpBuffer(merged);
      for (const container of parsed.containers) containers.push(container);
      pending = merged.slice(parsed.consumed);
      if (LumixCameraService.responseCode(containers, transactionId) >= 0) return containers;
    }
    throw new Error('PTP response timeout');
  }

  private static dataPayload(containers: PtpContainer[], operation: number,
    transactionId: number): Uint8Array {
    const data = containers.find((container: PtpContainer) =>
      container.type === PTP_CONTAINER_DATA && container.code === operation &&
      container.transactionId === transactionId);
    if (!data) throw new Error(`PTP data container missing for ${LumixCameraService.hexCode(operation)}`);
    return data.payload;
  }

  private static parseUint32Array(payload: Uint8Array): number[] {
    if (payload.length < 4) throw new Error('Invalid PTP array');
    const count = LumixCameraService.readLe32(payload, 0);
    if (count > 0x10000 || 4 + count * 4 > payload.length) throw new Error('Invalid PTP array length');
    const values: number[] = [];
    for (let index = 0; index < count; index++) values.push(LumixCameraService.readLe32(payload, 4 + index * 4));
    return values;
  }

  private static parseObjectInfo(handle: number, payload: Uint8Array): LumixPtpObject | undefined {
    // ObjectInfo is the standard PTP fixed header followed by UTF-16LE PTP
    // strings. The official library exposes the same fields through its
    // format, size and filename APIs.
    if (payload.length < 52) return undefined;
    let offset = 0;
    const storageId = LumixCameraService.readLe32(payload, offset); offset += 4;
    const format = LumixCameraService.readLe16(payload, offset); offset += 2;
    offset += 2; // protection status
    const size = LumixCameraService.readLe32(payload, offset); offset += 4;
    offset += 2; // thumbnail format
    const thumbSize = LumixCameraService.readLe32(payload, offset); offset += 4;
    const thumbWidth = LumixCameraService.readLe32(payload, offset); offset += 4;
    const thumbHeight = LumixCameraService.readLe32(payload, offset); offset += 4;
    const width = LumixCameraService.readLe32(payload, offset); offset += 4;
    const height = LumixCameraService.readLe32(payload, offset); offset += 4;
    offset += 4; // image bit depth
    offset += 4; // parent object
    offset += 2; // association type
    offset += 4; // association description
    offset += 4; // sequence number
    const filename = LumixCameraService.readPtpString(payload, offset);
    offset = filename.nextOffset;
    const captureDate = LumixCameraService.readPtpString(payload, offset);
    return {
      handle: handle, storageId: storageId, format: format, size: size,
      thumbSize: thumbSize, width: width || thumbWidth, height: height || thumbHeight,
      filename: filename.value, captureDate: captureDate.value,
    };
  }

  private static parsePtpContainers(buffer: Uint8Array, received: number): PtpContainer[] {
    const parsed = LumixCameraService.parsePtpBuffer(buffer.subarray(0, received));
    if (parsed.containers.length === 0) throw new Error('Invalid PTP container');
    return parsed.containers;
  }

  private static parsePtpBuffer(buffer: Uint8Array): PtpBufferParseResult {
    const containers: PtpContainer[] = [];
    let offset = 0;
    while (offset + PTP_CONTAINER_HEADER_SIZE <= buffer.length) {
      const length = LumixCameraService.readLe32(buffer, offset);
      if (length < PTP_CONTAINER_HEADER_SIZE || length > buffer.length - offset) break;
      const type = LumixCameraService.readLe16(buffer, offset + 4);
      const code = LumixCameraService.readLe16(buffer, offset + 6);
      const transactionId = LumixCameraService.readLe32(buffer, offset + 8);
      const payload = buffer.slice(offset + PTP_CONTAINER_HEADER_SIZE, offset + length);
      containers.push({ length: length, type: type, code: code, transactionId: transactionId, payload: payload });
      offset += length;
    }
    return { containers: containers, consumed: offset };
  }

  private static responseCode(containers: PtpContainer[], transactionId: number): number {
    for (const container of containers) {
      if (container.type === PTP_CONTAINER_RESPONSE && container.transactionId === transactionId) {
        return container.code;
      }
    }
    return -1;
  }

  private static openSessionMessage(code: number): string {
    if (code === PTP_RESPONSE_SESSION_ALREADY_OPEN) return 'PTP 会话已被其他应用占用，请关闭相机连接后重试';
    if (code === PTP_RESPONSE_SESSION_NOT_OPEN) return '相机拒绝 PTP 会话，请将 USB 模式切换为文件传输';
    return `相机未接受 PTP 会话（${LumixCameraService.hexCode(code)}），请解锁相机并允许 USB 访问`;
  }

  private static lumixSessionMessage(code: number): string {
    if (code === PTP_RESPONSE_SESSION_ALREADY_OPEN) return 'LUMIX USB 会话已存在，请先断开其他相机软件';
    if (code === PTP_RESPONSE_SESSION_NOT_OPEN) return 'LUMIX USB 授权被拒绝，请先完成蓝牙配对并将 USB 模式设为 LUMIX Lab';
    return `相机未接受 LUMIX USB 授权（${LumixCameraService.hexCode(code)}），请确认已完成蓝牙配对并允许 USB 访问`;
  }

  private static parseDeviceInfo(payload: Uint8Array): PtpDeviceInfo | undefined {
    // PTP DeviceInfo fields are LE values followed by counted UTF-16LE
    // strings. The official library exposes these as maker/model metadata.
    if (payload.length < 8) return undefined;
    let offset = 8; // StandardVersion + VendorExtensionID + VendorExtensionVersion
    const extension = LumixCameraService.readPtpString(payload, offset);
    offset = extension.nextOffset;
    if (offset + 2 > payload.length) return undefined;
    offset += 2; // FunctionalMode
    for (let index = 0; index < 5; index++) {
      if (offset + 4 > payload.length) return undefined;
      const count = LumixCameraService.readLe32(payload, offset);
      offset += 4;
      const bytes = count * 2;
      if (bytes > payload.length - offset) return undefined;
      offset += bytes;
    }
    const manufacturer = LumixCameraService.readPtpString(payload, offset);
    offset = manufacturer.nextOffset;
    const model = LumixCameraService.readPtpString(payload, offset);
    offset = model.nextOffset;
    const version = LumixCameraService.readPtpString(payload, offset);
    return { manufacturer: manufacturer.value, model: model.value, version: version.value };
  }

  private static readPtpString(buffer: Uint8Array, offset: number): PtpStringRead {
    if (offset >= buffer.length) return { value: '', nextOffset: buffer.length };
    const count = buffer[offset];
    const bytes = count * 2;
    if (count === 0 || bytes > buffer.length - offset - 1) {
      return { value: '', nextOffset: buffer.length };
    }
    let value = '';
    for (let index = 0; index < count - 1; index++) {
      const codeUnit = buffer[offset + 1 + index * 2] | (buffer[offset + 2 + index * 2] << 8);
      value += String.fromCharCode(codeUnit);
    }
    return { value: value, nextOffset: offset + 1 + bytes };
  }

  private static writeLe16(buffer: Uint8Array, offset: number, value: number): void {
    buffer[offset] = value & 0xFF;
    buffer[offset + 1] = (value >> 8) & 0xFF;
  }

  private static writeLe32(buffer: Uint8Array, offset: number, value: number): void {
    buffer[offset] = value & 0xFF;
    buffer[offset + 1] = (value >> 8) & 0xFF;
    buffer[offset + 2] = (value >> 16) & 0xFF;
    buffer[offset + 3] = (value >> 24) & 0xFF;
  }

  private static readLe32(buffer: Uint8Array, offset: number): number {
    return (buffer[offset] | (buffer[offset + 1] << 8) |
      (buffer[offset + 2] << 16) | (buffer[offset + 3] << 24)) >>> 0;
  }

  private static readLe16(buffer: Uint8Array, offset: number): number {
    return buffer[offset] | (buffer[offset + 1] << 8);
  }

  private static hexCode(value: number): string {
    if (value < 0) return '0xFFFF';
    return '0x' + value.toString(16).padStart(4, '0').toUpperCase();
  }

  static imageKeyForModel(model: string): string {
    const upper = model.toUpperCase();
    if (LumixCameraService.isZs300Model(model)) return 'panasonic_zs300';
    const compact = upper.replace(/[\s_-]+/g, '');
    const bare = (value: string): boolean => compact === value;
    if (LumixCameraService.matchesPanasonicName(upper, 'S5M2X') ||
      bare('S5M2X') || bare('DCS5M2X')) return 'panasonic_s5m2x';
    if (LumixCameraService.matchesPanasonicName(upper, 'S5M2') ||
      bare('S5M2') || bare('DCS5M2')) return 'panasonic_s5m2';
    if (LumixCameraService.isOriginalS5Name(upper) || bare('S5') || bare('DCS5') ||
      bare('LUMIXS5') || bare('PANASONICS5') || bare('PANAS5') || bare('CAMERAS5')) return 'panasonic_s5';
    if (LumixCameraService.matchesPanasonicName(upper, 'S1M2E') ||
      LumixCameraService.matchesPanasonicName(upper, 'S1IIE') || bare('S1M2E') || bare('S1IIE') ||
      bare('DCS1M2E') || bare('DCS1IIE')) return 'panasonic_s1iie';
    if (LumixCameraService.matchesPanasonicName(upper, 'S1M2') ||
      LumixCameraService.matchesPanasonicName(upper, 'S1II') || bare('S1M2') || bare('S1II') ||
      bare('DCS1M2') || bare('DCS1II')) return 'panasonic_s1ii';
    if (LumixCameraService.matchesPanasonicName(upper, 'S1RM2') ||
      LumixCameraService.matchesPanasonicName(upper, 'S1RII') ||
      LumixCameraService.matchesPanasonicName(upper, 'S1R') || bare('S1RM2') || bare('S1RII') ||
      bare('S1R') || bare('DCS1RM2') || bare('DCS1RII') || bare('DCS1R')) return 'panasonic_s1rii';
    if (LumixCameraService.matchesPanasonicName(upper, 'S1H') || bare('S1H') || bare('DCS1H')) return 'panasonic_s1ii';
    if (LumixCameraService.matchesPanasonicName(upper, 'S9') || bare('S9') || bare('DCS9')) return 'panasonic_s9';
    if (LumixCameraService.matchesPanasonicName(upper, 'GH7') || bare('GH7') || bare('DCGH7')) return 'panasonic_gh7';
    if (LumixCameraService.matchesPanasonicName(upper, 'G9M2') ||
      LumixCameraService.matchesPanasonicName(upper, 'G9II') || bare('G9M2') || bare('G9II') ||
      bare('DCG9M2') || bare('DCG9II')) return 'panasonic_g9m2';
    if (LumixCameraService.matchesPanasonicName(upper, 'G100D') || bare('G100D') || bare('DCG100D')) return 'panasonic_g100d';
    if (LumixCameraService.matchesPanasonicName(upper, 'G100') || bare('G100') || bare('DCG100')) return 'panasonic_g100d';
    if (LumixCameraService.matchesPanasonicName(upper, 'GH6') || bare('GH6') || bare('DCGH6')) return 'panasonic_gh6';
    if (LumixCameraService.matchesPanasonicName(upper, 'GH5M2') || bare('GH5M2') || bare('DCGH5M2')) return 'panasonic_gh5m2';
    if (LumixCameraService.matchesPanasonicName(upper, 'GH5S') || bare('GH5S') || bare('DCGH5S')) return 'panasonic_gh5s';
    if (LumixCameraService.matchesPanasonicName(upper, 'GH5') || bare('GH5') || bare('DCGH5')) return 'panasonic_gh5';
    if (LumixCameraService.matchesPanasonicName(upper, 'GH1') || bare('GH1') || bare('DCGH1')) return 'panasonic_gh5';
    // LUMIX Image App line (no Bluetooth). Checked before G9 so the longer
    // tokens win; each archived body has its own image resource.
    if (LumixCameraService.matchesPanasonicName(upper, 'G97') || bare('G97') || bare('DCG97')) return 'panasonic_g97';
    if (LumixCameraService.matchesPanasonicName(upper, 'GX9') || bare('GX9') || bare('DCGX9')) return 'panasonic_gx9';
    if (LumixCameraService.matchesPanasonicName(upper, 'GF10') || bare('GF10') || bare('DCGF10')) return 'panasonic_gf10';
    if (LumixCameraService.matchesPanasonicName(upper, 'ZS99') || bare('ZS99') ||
      bare('DCZS99') || bare('DMCZS99')) return 'panasonic_zs99';
    if (LumixCameraService.matchesPanasonicName(upper, 'G9') || bare('G9') || bare('DCG9')) return 'panasonic_g9';
    if (LumixCameraService.matchesPanasonicName(upper, 'L10') || bare('L10') || bare('DMCL10')) return 'panasonic_l10';
    return '';
  }

  /**
   * Control-plane routing for Panasonic bodies, following the official app
   * split. The LUMIX Lab generation (S9, S5M2/S5M2X, S1M2/S1M2E/S1RM2,
   * GH7, G9M2, L10) speaks the Lab REST protocol over the camera AP; the
   * LUMIX Sync bodies (S1H, S1R, S5, GH1, G100/G100D, GH5/GH5S/GH5M2,
   * GH6, G9) keep the LUMIX Sync cam.cgi protocol. ZS300 belongs to the same
   * Sync line: cam.cgi control + BLE pairing (it does have Bluetooth, confirmed
   * by the official specification); only its model-specific handshake still
   * needs device validation.
   * Everything else that is recognisably Panasonic is archived on the
   * 'lumix_image' line — the pre-Bluetooth LUMIX Image App generation.
   * Returns 'lab', 'sync', 'lumix_image' or '' for unknown.
   *
   * The three model sets are disjoint by construction: each lower-priority set
   * is defined as its candidates minus every higher-priority set, so the
   * relative order of the loops below cannot route a body to two lines.
   *
   * 判定顺序是 **Lab 身份优先于"仅 Wi-Fi"判定**：调用方传进来的是三段身份拼接
   * （机型 + BLE 候选机型 + BLE 广播名），其中可能残留上一次配对的机型串，而
   * `isWifiOnlyModel()` 只要在整串任一 token 上看到 S5/ZS300 就返回 true——那样
   * S1RM2/S9 这类 Lab 机身会被整条路由到 Sync 线（2026-10-11 真机现象：S1RM2
   * 取图库误走 sync 线）。Lab 型号表是最具体的身份证据，与 `isWifiOnlyModel()`
   * 内部已有的 S5M2 否决是同一原则。
   */
  static panasonicRouteForModel(identity: string, fromBle: boolean = false): string {
    const upper = identity.toUpperCase();
    const compactIdentity = upper.replace(/[\s_-]+/g, '');
    // A generic LUMIX card has no model token yet. Do not guess a line from the
    // brand word alone; the line stays undecided until a name/SSID token arrives.
    if (compactIdentity.length === 0 || compactIdentity === 'LUMIX' ||
      compactIdentity === 'PANASONIC' || compactIdentity === 'PANA') return '';
    const tokens = upper.split(/\s+/);
    const matchesToken = (model: string): boolean => {
      for (const raw of tokens) {
        const trimmed = raw.trim();
        if (trimmed.length === 0) continue;
        const compact = trimmed.replace(/[\s_-]+/g, '');
        if (LumixCameraService.matchesPanasonicName(trimmed, model) ||
          compact === model || compact === `DC${model}`) return true;
      }
      return false;
    };
    // Longest aliases first so S5M2X/S5M2, S1M2E/S1M2 and S1RM2/S1R stay
    // unambiguous. The two sets are disjoint, so this is belt-and-braces
    // rather than the mechanism that prevents a Lab/Sync collision.
    for (const model of PANASONIC_LAB_MODEL_TOKENS) {
      if (matchesToken(model)) return 'lab';
    }
    // The original S5 is Sync, never Image App. Check it before the S5M2 veto
    // inside isWifiOnlyModel can hide it in a concatenated identity string.
    if (LumixCameraService.isOriginalS5Identity(identity)) return 'sync';
    // Discovery rule (2026-10-18): a Panasonic body seen over BLE that is not in
    // the Lab table belongs to the Bluetooth Sync generation. The old explicit
    // Sync token list stays below for SSID-only discovery, where a known Sync
    // model must still outrank the Image App fallback.
    if (fromBle) return 'sync';
    if (LumixCameraService.isWifiOnlyModel(identity)) return 'sync';
    for (const model of PANASONIC_SYNC_MODEL_TOKENS) {
      if (matchesToken(model)) return 'sync';
    }
    // Third line: the pre-Bluetooth LUMIX Image App generation. This is a
    // deliberate fallback, evaluated only after both Bluetooth generations, so
    // a Lab or Sync body can never be claimed by this line.
    if (LumixCameraService.isPanasonicImageModel(identity)) return 'lumix_image';
    return '';
  }

  /** True when the identity names the pre-Bluetooth LUMIX Image App line. */
  static isPanasonicImageModel(identity: string): boolean {
    // S5 belongs to the Sync line; never let the generic Panasonic fallback
    // below claim it for Image App.
    if (LumixCameraService.isOriginalS5Identity(identity)) return false;
    const upper = identity.toUpperCase().trim();
    if (upper.length === 0) return false;
    const tokens = upper.split(/\s+/);
    for (const raw of tokens) {
      const trimmed = raw.trim();
      if (trimmed.length === 0) continue;
      const compact = trimmed.replace(/[\s_-]+/g, '');
      for (const model of PANASONIC_IMAGE_MODEL_TOKENS) {
        if (LumixCameraService.matchesPanasonicName(trimmed, model) ||
          compact === model || compact === `DC${model}`) return true;
      }
      // Any remaining Panasonic-shaped body is archived here too: a body that
      // matched neither Bluetooth generation is a Lumix Link 2.0 camera, and
      // the third line is the only route that can still serve it.
      if (/^(?:DC|DMC|LUMIX|PANASONIC|PANA)[-_ ]?[A-Z0-9]+$/.test(trimmed)) return true;
    }
    return false;
  }

  /**
   * True when any token in a concatenated identity string is the original S5.
   *
   * This is deliberately separate from isWifiOnlyModel(): that predicate vetoes
   * the whole string when an S5M2 token is also present, which would let a stale
   * "S5 ... S5M2" string fall through to the Image App fallback. The original
   * S5 must always route to Sync.
   */
  private static isOriginalS5Identity(identity: string): boolean {
    const tokens = identity.toUpperCase().split(/\s+/);
    for (const raw of tokens) {
      const trimmed = raw.trim();
      if (trimmed.length === 0) continue;
      const compact = trimmed.replace(/[\s_-]+/g, '');
      if (LumixCameraService.isOriginalS5Name(trimmed)) return true;
      if (compact === 'S5' || compact === 'DCS5' || compact === 'LUMIXS5' ||
        compact === 'PANASONICS5' || compact === 'PANAS5' || compact === 'CAMERAS5') return true;
    }
    return false;
  }

  /**
   * Both camera-control lines below the Lab generation speak cam.cgi and move
   * images over the DLNA/DMS path; they differ only in who hands over the Wi-Fi
   * credentials. Call sites that ask "is this a cam.cgi body reached by joining
   * the camera AP directly?" must use this predicate rather than comparing
   * against 'sync', otherwise the Image App line is silently treated as a Lab
   * body.
   */
  static isCamCgiRoute(route: string): boolean {
    return route === 'sync' || route === 'lumix_image';
  }

  /**
   * Only the Lab and Sync generations pair over Bluetooth. The Image App
   * generation has no radio at all, so it must never be sent into a BLE pairing
   * or registration flow.
   */
  static needsBlePairing(route: string): boolean {
    return route === 'lab' || route === 'sync';
  }

  /**
   * Scan the STA interface and return APs recognised by a brand-specific
   * matcher.  Panasonic entries use identifyWifiSsid(); Nikon entries use
   * NikonCameraService.identifyWifiSsid().
   */
  /** The camera routes need the radio on; Harmony never auto-enables Wi-Fi
   * for a scan or a candidate connect. Turn it on when the user has left it
   * off so a connect tap cannot run into a silently doomed flow. */
  static async ensureWifiEnabled(): Promise<void> {
    try {
      if (!wifiManager.isWifiActive()) await wifiManager.enableWifi();
    } catch (_error) { }
  }

  static async scanForCameras(): Promise<LumixWifiCandidate[]> {
    try {
      await LumixCameraService.ensureWifiEnabled();
      // The scan API is asynchronous at the platform level. A short delay lets
      // the framework publish fresh results while keeping the page responsive.
      try {
        wifiManager.startScan();
      } catch (_error) {
        // HarmonyOS 6/older vendor builds expose the legacy alias instead.
        wifiManager.scan();
      }
      await LumixCameraService.delay(900);
    } catch (_error) {
      // Results already cached by the system can still be read below.
    }

    let results: Array<wifiManager.WifiScanInfo> = [];
    try {
      results = wifiManager.getScanInfoList();
    } catch (_error) {
      try {
        results = await wifiManager.getScanResults();
      } catch (_ignored) {
        return [];
      }
    }

    const candidates: LumixWifiCandidate[] = [];
    const seen: string[] = [];
    for (const result of results) {
      const ssid = (result.ssid || '').replace(/^\"|\"$/g, '').trim();
      // Keep the Panasonic matcher intact and dispatch Nikon AP names through
      // its own function.  A foreign SSID can therefore never be classified
      // as a LUMIX camera by a broadened regular expression.
      const identified = LumixCameraService.identifyWifiSsid(ssid);
      const nikon = identified ? null : NikonCameraService.identifyWifiSsid(ssid);
      const sony = (identified || nikon) ? null : SonyCameraService.identifyWifiSsid(ssid);
      const cameraIdentity = identified || nikon || sony;
      if (!cameraIdentity || seen.indexOf(ssid) >= 0) continue;
      seen.push(ssid);
      candidates.push({
        ssid: ssid,
        bssid: result.bssid || '',
        rssi: result.rssi || 0,
        securityType: result.securityType as number,
        model: cameraIdentity.model,
        family: cameraIdentity.family,
        imageKey: cameraIdentity.imageKey,
        brand: identified ? 'Panasonic' : (nikon ? 'Nikon' : 'Sony'),
      });
    }
    candidates.sort((a: LumixWifiCandidate, b: LumixWifiCandidate) => b.rssi - a.rssi);
    return candidates;
  }

  /** Return the currently linked SSID, used to avoid reconnecting to itself. */
  static async linkedSsid(): Promise<string> {
    try {
      const linked = await wifiManager.getLinkedInfo();
      return (linked.ssid || '').replace(/^\"|\"$/g, '').trim();
    } catch (_error) {
      return '';
    }
  }

  /**
   * Return the DHCP gateway for the currently linked Wi‑Fi network. Camera
   * access points are the default route on a direct connection, so this value
   * is the PTP/IP peer candidate; it is never a hard-coded camera address.
   */
  static async linkedGateway(): Promise<string> {
    try {
      const info = wifiManager.getIpInfo();
      const value = Number(info.gateway);
      if (!Number.isFinite(value) || value <= 0) return '';
      return `${(value >>> 24) & 0xff}.${(value >>> 16) & 0xff}.${(value >>> 8) & 0xff}.${value & 0xff}`;
    } catch (_error) {
      return '';
    }
  }

  /** Resolve credentials first. The system user-action sheet confirms trust only. */
  static async connectToCameraWifi(candidate: LumixWifiCandidate, allowUserAction: boolean = false,
    options: CameraWifiJoinOptions = {}): Promise<LumixWifiConnectionResult> {
    const cancelled = (): boolean => options.isCancelled ? options.isCancelled() : false;
    const failed = (message: string): LumixWifiConnectionResult =>
      ({ connected: false, message: message, ssid: candidate.ssid });
    try {
      if (cancelled()) return failed('已取消相机 Wi-Fi 连接');
      await LumixCameraService.ensureWifiEnabled();
      if (await LumixCameraService.cameraWifiAssociated(candidate.ssid)) {
        return cancelled() ? failed('已取消相机 Wi-Fi 连接') :
          { connected: true, message: '已连接该相机 Wi-Fi', ssid: candidate.ssid };
      }
      if (!CameraWifiPasswordPolicy.supports(candidate.securityType)) {
        return failed('该相机网络安全类型需要在系统 Wi-Fi 设置中连接');
      }
      const protectedAp = CameraWifiPasswordPolicy.needsPassword(candidate.securityType);
      let savedConfig: wifiManager.WifiDeviceConfig | null = null;
      try {
        savedConfig = wifiManager.getCandidateConfigs().find((saved: wifiManager.WifiDeviceConfig): boolean =>
          CameraWifiPasswordPolicy.sameSsid(saved.ssid, candidate.ssid) &&
          saved.securityType === candidate.securityType && saved.netId !== undefined && saved.netId >= 0) || null;
      } catch (_error) { }
      let password = options.password ?? '';
      let retryMessage = '';
      // At most one saved-key attempt and one explicit credential correction.
      for (let attempt = 0; attempt < 2; attempt++) {
        if (cancelled()) return failed('已取消相机 Wi-Fi 连接');
        const savedKeyUsable = savedConfig !== null && (!protectedAp ||
          CameraWifiPasswordPolicy.validationError(candidate.securityType, savedConfig.preSharedKey) === '');
        const reuseConfig = attempt === 0 && savedKeyUsable && (password.length === 0 ||
          (savedConfig !== null && savedConfig.preSharedKey === password));
        if (protectedAp && !reuseConfig && CameraWifiPasswordPolicy.validationError(candidate.securityType, password) !== '') {
          if (!options.requestPassword) return failed('需要输入该相机 Wi-Fi 的密码后才能连接');
          const entered = await options.requestPassword(candidate, retryMessage);
          if (cancelled() || entered === null) return failed('已取消相机 Wi-Fi 连接');
          password = entered;
          const validation = CameraWifiPasswordPolicy.validationError(candidate.securityType, password);
          if (validation.length > 0) return failed(validation);
        }
        if (cancelled()) return failed('已取消相机 Wi-Fi 连接');
        let networkId = reuseConfig && savedConfig ? (savedConfig.netId ?? -1) : -1;
        if (!reuseConfig) {
          // Replace only our exact-SSID candidate, including old empty-key records.
          if (savedConfig && savedConfig.netId !== undefined) {
            await wifiManager.removeCandidateConfig(savedConfig.netId);
            if (cancelled()) return failed('已取消相机 Wi-Fi 连接');
          }
          networkId = await wifiManager.addCandidateConfig({
            ssid: candidate.ssid, bssid: candidate.bssid,
            preSharedKey: protectedAp ? password : '',
            securityType: candidate.securityType as wifiManager.WifiSecurityType,
            showNoInternetDialog: true,
          });
        }
        if (networkId < 0) return failed('系统未接受该 Wi-Fi 配置，请检查密码和网络安全类型');
        if (cancelled()) {
          if (!reuseConfig) await wifiManager.removeCandidateConfig(networkId);
          return failed('已取消相机 Wi-Fi 连接');
        }
        const withUserAction = allowUserAction && !reuseConfig;
        AppDiagnostics.event('VIVID_WIFI', `direct join security=${candidate.securityType} reused=${reuseConfig ? 1 : 0} attempt=${attempt + 1}`);
        LumixCameraService.logBoth(0x0001, 'VIVID_WIFI', 'direct join security=%{public}d reused=%{public}d attempt=%{public}d',
          candidate.securityType, reuseConfig ? 1 : 0, attempt + 1);
        let joinCode = 0;
        try {
          if (deviceInfo.sdkApiVersion >= 26) {
            await wifiManager.connectToCandidateConfig({ networkId: networkId, withUserAction: withUserAction,
              userActionTimeout: withUserAction ? 30 : undefined, addNetworkToSystem: !reuseConfig });
          } else if (withUserAction && deviceInfo.sdkApiVersion >= 20) {
            await wifiManager.connectToCandidateConfigWithUserAction(networkId);
          } else {
            wifiManager.connectToCandidateConfig(networkId);
          }
        } catch (error) {
          joinCode = Number((error as BusinessError).code) || -1;
        }
        // A resolved trust promise does not prove association. Wait for this exact AP.
        for (let poll = 0; poll < 30 && joinCode === 0 && !cancelled(); poll++) {
          if (await LumixCameraService.cameraWifiAssociated(candidate.ssid)) {
            if (cancelled()) break;
            AppDiagnostics.event('VIVID_WIFI', `direct association result=ok attempt=${attempt + 1}`);
            LumixCameraService.logBoth(0x0001, 'VIVID_WIFI', 'direct association confirmed attempt=%{public}d', attempt + 1);
            return { connected: true, message: '已连接相机 Wi-Fi，正在握手', ssid: candidate.ssid, networkId: networkId };
          }
          await LumixCameraService.delay(500);
        }
        if (!reuseConfig) {
          try { await wifiManager.removeCandidateConfig(networkId); } catch (_removeError) { }
        }
        if (cancelled()) return failed('已取消相机 Wi-Fi 连接');
        AppDiagnostics.event('VIVID_WIFI', `direct association result=failed code=${joinCode} attempt=${attempt + 1}`);
        LumixCameraService.warnBoth(0x0001, 'VIVID_WIFI', 'direct association failed code=%{public}d attempt=%{public}d', joinCode, attempt + 1);
        if (joinCode === 2501005) return failed('系统信任确认已超时，请重新连接并及时确认');
        if (joinCode === 2501006) return failed('已取消系统 Wi-Fi 信任确认');
        if (reuseConfig && protectedAp && options.requestPassword && attempt === 0) {
          password = '';
          retryMessage = '已保存的连接未能成功，请核对相机当前显示的 Wi-Fi 密码。';
          continue;
        }
        return failed(protectedAp ? '未连接该相机 Wi-Fi，请检查密码、相机热点和系统信任确认后重试' :
          '未连接该相机 Wi-Fi，请确认热点仍开启并完成系统信任确认');
      }
      return failed('相机 Wi-Fi 连接未完成，请重试');
    } catch (_error) {
      return failed('无法切换到相机 Wi-Fi，请检查网络权限、密码和热点状态');
    }
  }

  private static async cameraWifiAssociated(ssid: string): Promise<boolean> {
    try {
      const linked = await wifiManager.getLinkedInfo();
      return linked.connState === wifiManager.ConnState.CONNECTED &&
        CameraWifiPasswordPolicy.sameSsid(linked.ssid || '', ssid);
    } catch (_error) { return false; }
  }

  /** Identify a Panasonic camera AP without exposing credentials. */
  static identifyWifiSsid(ssid: string): LumixSsidIdentity | null {
    if (LumixCameraService.isZs300WifiSsid(ssid)) {
      return { model: 'ZS300', family: 'ZS 系列·便携相机', imageKey: 'panasonic_zs300' };
    }
    const upper = ssid.toUpperCase();
    // Match only a complete model prefix with an instance suffix. Sorting the
    // longer aliases first keeps S5M2X/S5M2 and S1M2E/S1M2 unambiguous.
    const models: LumixSsidToken[] = [
      { token: 'S5M2X', model: 'S5M2X', family: 'S 系列·全画幅', imageKey: 'panasonic_s5m2x' },
      { token: 'S1IIE', model: 'S1IIE', family: 'S 系列·全画幅', imageKey: 'panasonic_s1iie' },
      { token: 'S1M2E', model: 'S1M2E', family: 'S 系列·全画幅', imageKey: 'panasonic_s1iie' },
      { token: 'S1RM2', model: 'S1RM2', family: 'S 系列·全画幅', imageKey: 'panasonic_s1rii' },
      { token: 'S1RII', model: 'S1RII', family: 'S 系列·全画幅', imageKey: 'panasonic_s1rii' },
      { token: 'S1R', model: 'S1R', family: 'S 系列·全画幅', imageKey: 'panasonic_s1rii' },
      { token: 'S1II', model: 'S1II', family: 'S 系列·全画幅', imageKey: 'panasonic_s1ii' },
      { token: 'S1M2', model: 'S1M2', family: 'S 系列·全画幅', imageKey: 'panasonic_s1ii' },
      { token: 'S5M2', model: 'S5M2', family: 'S 系列·全画幅', imageKey: 'panasonic_s5m2' },
      { token: 'S9', model: 'S9', family: 'S 系列·全画幅', imageKey: 'panasonic_s9' },
      { token: 'S1H', model: 'S1H', family: 'S 系列·全画幅', imageKey: 'panasonic_s1ii' },
      { token: 'S5', model: 'S5', family: 'S 系列·全画幅', imageKey: 'panasonic_s5' },
      { token: 'GH7', model: 'GH7', family: 'GH 系列', imageKey: 'panasonic_gh7' },
      { token: 'G9M2', model: 'G9M2', family: 'G 系列', imageKey: 'panasonic_g9m2' },
      { token: 'G9II', model: 'G9II', family: 'G 系列', imageKey: 'panasonic_g9m2' },
      { token: 'GH6', model: 'GH6', family: 'GH 系列', imageKey: 'panasonic_gh6' },
      { token: 'GH5M2', model: 'GH5M2', family: 'GH 系列', imageKey: 'panasonic_gh5m2' },
      { token: 'GH5S', model: 'GH5S', family: 'GH 系列', imageKey: 'panasonic_gh5s' },
      { token: 'GH5', model: 'GH5', family: 'GH 系列', imageKey: 'panasonic_gh5' },
      { token: 'GH1', model: 'GH1', family: 'GH 系列', imageKey: 'panasonic_gh5' },
      { token: 'G100D', model: 'G100D', family: 'G 系列', imageKey: 'panasonic_g100d' },
      { token: 'G100', model: 'G100', family: 'G 系列', imageKey: 'panasonic_g100d' },
      { token: 'G97', model: 'G97', family: 'G 系列', imageKey: 'panasonic_g97' },
      { token: 'GX9', model: 'GX9', family: 'GX 系列', imageKey: 'panasonic_gx9' },
      { token: 'GF10', model: 'GF10', family: 'GF 系列', imageKey: 'panasonic_gf10' },
      { token: 'ZS99', model: 'ZS99', family: 'ZS 系列·便携相机', imageKey: 'panasonic_zs99' },
      { token: 'G9', model: 'G9', family: 'G 系列', imageKey: 'panasonic_g9' },
      { token: 'L10', model: 'L10', family: 'L 系列', imageKey: 'panasonic_l10' },
    ];
    for (const candidate of models) {
      if (!LumixCameraService.matchesPanasonicName(upper, candidate.token)) continue;
      return { model: candidate.model, family: candidate.family, imageKey: candidate.imageKey };
    }
    return null;
  }

  private static delay(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => setTimeout(resolve, milliseconds));
  }

  static async probe(host: string): Promise<LumixProbeResult> {
    const safeHost = host.trim().replace('http://', '').replace('https://', '').replace('/', '');
    if (safeHost.length === 0) {
      return {
        connected: false,
        model: '',
        family: '',
        supportsRaw: false,
        firmware: '',
        message: '请输入相机地址',
      };
    }

    // Official getinfo types are the literal set {curmenu, lens, allmenu,
    // camsetting, capability} — B5/a.java:329/366/1516/1550/1580 — and the
    // official client never passes a variable there. A getinfo&type=model
    // probe was unattested, and because a protocol error body still counted as
    // an answer it could also become the payload extractModel() parses.
    const endpoints: string[] = [
      '/cam.cgi?mode=getstate&type=keep_alive',
      '/cam.cgi?mode=getinfo&type=capability',
      '/cam.cgi?mode=getinfo&type=allmenu',
    ];
    const answered: string[] = [];
    let payload = '';
    for (let index = 0; index < endpoints.length; index++) {
      const body = await LumixCameraService.request(safeHost, endpoints[index]);
      if (!body) continue;
      // Never let an err_* reply count as a capability answer or as the model
      // payload; the DC-XXXX scan below would otherwise read error XML.
      if (/err_/.test(body)) continue;
      answered.push(endpoints[index]);
      if (body.length > payload.length) {
        payload = body;
      }
    }

    if (answered.length === 0) {
      return {
        connected: false,
        model: '',
        family: '',
        supportsRaw: false,
        firmware: '',
        message: '未找到相机，请先连接相机创建的 Wi-Fi',
      };
    }

    const model = LumixCameraService.extractModel(payload);
    const info = model ? LumixCameraService.lookupModel(model) : undefined;
    const firmware = LumixCameraService.readField(payload, 'version') ||
      LumixCameraService.readField(payload, 'firmware');
    if (info) {
      return {
        connected: true,
        model: model,
        family: info.family,
        supportsRaw: info.supportsRaw,
        firmware: firmware || '已识别',
        message: `握手成功 · ${answered.length} 项 API 可用`,
      };
    }
    return {
      connected: true,
      model: model || 'LUMIX Camera',
      family: model ? '未收录型号' : '未知系列',
      supportsRaw: true,
      firmware: firmware || '已识别',
      message: '已建立本地 Wi-Fi 会话',
    };
  }

  /**
   * S5 access-control handshake observed in LUMIX Sync before DMS_INIT.
   * `value` carries Vivid's own persisted client identifier and `value2` is
   * the DMS profile name. The response body is intentionally not exposed.
   */
  static async requestS5Access(host: string, clientId: string, networkName: string = 'WEB-W00'): Promise<boolean> {
    const safeHost = host.trim().replace('http://', '').replace('https://', '').replace('/', '');
    if (safeHost.length === 0) {
      try { LumixCameraService.warnBoth(0x0001, 'VIVID_S5', 'req_acc skipped: gateway unavailable'); } catch (_error) { }
      return false;
    }
    const encodedClient = encodeURIComponent(clientId);
    // The S5/DLNA handshake uses the same two values as LUMIX Sync:
    // the DMS UUID in `value` and the local DMS network name in `value2`.
    // `WEB-W00` is the observed Sync profile marker, not a camera SSID or password.
    const encodedNetworkName = encodeURIComponent(networkName.length > 0 ? networkName : 'WEB-W00');
    const path = `/cam.cgi?mode=accctrl&type=req_acc&value=${encodedClient}&value2=${encodedNetworkName}`;
    try { LumixCameraService.logBoth(0x0001, 'VIVID_S5', 'req_acc GET host=present client=present profile=WEB-W00'); } catch (_error) { }
    const response = await LumixCameraService.requestWithCode(safeHost, path);
    const body = response.body === null ? '' : response.body.toLowerCase();
    const markerMatch = body.match(/err_[a-z0-9_]+|ok_[a-z0-9_]+|wifi_reset/i);
    const marker = markerMatch ? markerMatch[0] : (body.trim() === 'ok' ? 'ok' : 'unknown');
    const rejected = /err_(?:reject|busy|unsuitable_app)/i.test(body);
    try {
      LumixCameraService.logBoth(0x0001, 'VIVID_S5', `req_acc response code=${response.code} bodyBytes=${response.body === null ? -1 : response.body.length} marker=${marker}`);
    } catch (_error) { }
    return response.code >= 200 && response.code < 300 && response.body !== null && !rejected;
  }

  /**
   * Tell the original S5 that the phone client is ready for picture transfer.
   * LUMIX Sync sends this camcmd after starting its local DMS advertisement;
   * req_acc alone leaves the camera on its Wi‑Fi-complete screen.  `pictmode`
   * is the image-selection mode used by the S5 push workflow.
   */
  static async requestS5PictureMode(host: string): Promise<boolean> {
    const safeHost = host.trim().replace('http://', '').replace('https://', '').replace('/', '');
    if (safeHost.length === 0) {
      try { LumixCameraService.warnBoth(0x0001, 'VIVID_S5', 'camcmd pictmode skipped: gateway unavailable'); } catch (_error) { }
      return false;
    }
    // B5/a.java:1258 sends n(null, "pictmode", null), so the verb belongs in
    // value=; a type= parameter draws <result>err_param</result> (the same
    // finding recorded in LumixSyncControlService.sendCamCmd). This function
    // currently has no caller — the original S5 passive push is deliberately
    // disabled — but the slot is corrected so the trap is not left behind.
    const path = '/cam.cgi?mode=camcmd&value=pictmode';
    try { LumixCameraService.logBoth(0x0001, 'VIVID_S5', 'camcmd GET host=present value=pictmode'); } catch (_error) { }
    const response = await LumixCameraService.requestWithCode(safeHost, path);
    const body = response.body === null ? '' : response.body.toLowerCase();
    const shootModeChanged = body.indexOf('ok_shoot_mode_changed') >= 0;
    const wifiReset = body.indexOf('wifi_reset') >= 0;
    const genericOk = /(?:^|[,\r\n])ok(?:$|[,\r\n])/.test(body.trim());
    const accepted = response.code >= 200 && response.code < 300 &&
      response.body !== null && (shootModeChanged || wifiReset || genericOk);
    const markerMatch = body.match(/err_[a-z0-9_]+|ok_[a-z0-9_]+|wifi_reset/i);
    const marker = markerMatch ? markerMatch[0] : (body.trim() === 'ok' ? 'ok' : 'unknown');
    try {
      LumixCameraService.logBoth(0x0001, 'VIVID_S5', `camcmd pictmode response code=${response.code} bodyBytes=${response.body === null ? -1 : response.body.length} marker=${marker} result=${accepted ? 'accepted' : 'rejected'}`);
    } catch (_error) { }
    return accepted;
  }

  /**
   * Probe the camera-side DMS description used by LUMIX Sync's DMP discovery.
   *
   * The gallery Browse SOAP operation is a later, post-handshake operation;
   * sending it here makes the S5 return HTTP 500 and prevents req_acc from
   * running.  LUMIX Sync first resolves this description at /Lumix/Server0/ddd
   * and then performs the access-control request.  This probe is therefore a
   * discovery hint only: a body that does not expose the description must not
   * block the authentication step below.
   */
  static async requestS5DmpBrowse(host: string): Promise<boolean> {
    const safeHost = host.trim().replace('http://', '').replace('https://', '').replace('/', '');
    if (safeHost.length === 0) {
      try { LumixCameraService.warnBoth(0x0001, 'VIVID_S5', 'dmp descriptor skipped: gateway unavailable'); } catch (_error) { }
      return false;
    }
    // The native capture resolves the camera DMP descriptor on 60606. Keep
    // 49320 as a compatibility fallback for older S5 firmware. The search is
    // a camera-side SSDP request on the same DMP port; it occurs between two
    // descriptor reads in the official client and is required before the S5
    // changes its Wi-Fi-complete screen to the application transfer screen.
    const ports: number[] = [60606, 49320];
    for (const port of ports) {
      try {
        const first = await LumixCameraService.requestS5DmpDescriptor(safeHost, port);
        try { LumixCameraService.logBoth(0x0001, 'VIVID_S5', `dmp descriptor response code=${first.code} bodyBytes=${first.body.length}`); } catch (_error) { }
        // The official native sequence performs M-SEARCH after the first
        // descriptor read, then opens a fresh connection for the second read.
        // Do not require the UDP reply: some camera firmware answers it on a
        // connected datagram socket but still completes the state transition
        // when the request itself was received.
        await LumixCameraService.sendS5DmpSearch(safeHost, port);
        const second = await LumixCameraService.requestS5DmpDescriptor(safeHost, port);
        try { LumixCameraService.logBoth(0x0001, 'VIVID_S5', `dmp descriptor reread code=${second.code} bodyBytes=${second.body.length}`); } catch (_error) { }
        if ((second.code >= 200 && second.code < 300 && second.body.length > 0) ||
          (first.code >= 200 && first.code < 300 && first.body.length > 0)) return true;
      } catch (_error) {
        try { LumixCameraService.warnBoth(0x0001, 'VIVID_S5', `dmp descriptor request failed port=${port}`); } catch (_logError) { }
      }
    }
    return false;
  }

  private static async requestS5DmpDescriptor(host: string, port: number): Promise<LumixDmpDescriptorResponse> {
    const client = http.createHttp();
    try {
      try { LumixCameraService.logBoth(0x0001, 'VIVID_S5', `dmp descriptor GET host=present port=${port}`); } catch (_error) { }
      const response = await client.request(`http://${host}:${port}/Lumix/Server0/ddd`, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Panasonic Android/1 DM-CP',
          'Host': `${host}:${port}`,
        },
        connectTimeout: 3000,
        readTimeout: 5000,
        expectDataType: http.HttpDataType.STRING,
      });
      const body = response.result === undefined || response.result === null ? '' : String(response.result);
      return { code: response.responseCode, body: body };
    } catch (_error) {
      return { code: 0, body: '' };
    } finally {
      client.destroy();
    }
  }

  /**
   * Repeat the camera-side DMP discovery probe after the local DMS
   * advertisement is already live.  The S5 re-checks this datagram on its own
   * processing cycle before it leaves the Wi-Fi-complete screen, and the
   * observed ddd.xml fetch follows the probe by 8-15 seconds; extra probes
   * give the body more chances to run its transition earlier.  Each nudge is
   * a single best-effort UDP datagram that never blocks the handshake.
   */
  static async nudgeS5DmpDiscovery(host: string): Promise<void> {
    const safeHost = host.trim().replace('http://', '').replace('https://', '').replace('/', '');
    if (safeHost.length === 0) return;
    const waits: number[] = [2000, 3000, 5000];
    for (const waitMs of waits) {
      await LumixCameraService.delay(waitMs);
      await LumixCameraService.sendS5DmpSearch(safeHost, 60606);
      try { LumixCameraService.logBoth(0x0001, 'VIVID_S5', 'dmp discovery nudge sent host=present'); } catch (_error) { }
    }
  }

  private static async sendS5DmpSearch(host: string, port: number): Promise<void> {
    const udp = socket.constructUDPSocketInstance();
    let responseSeen = false;
    try {
      udp.on('message', (_info: socket.SocketMessageInfo): void => { responseSeen = true; });
      udp.on('error', (_error: Error): void => { });
      await udp.bind({ address: '0.0.0.0', family: 1, port: 0 });
      // The native capture sends this discovery datagram to the standard
      // SSDP multicast endpoint.  The camera answers with its DMP descriptor
      // location (the HTTP endpoint is still <camera>:60606); sending the
      // datagram directly to 60606 leaves the camera on the Wi-Fi-complete
      // screen on S5 firmware.
      const ssdpGroup = '239.255.255.250';
      const ssdpPort = 1900;
      const request = `M-SEARCH * HTTP/1.1\r\nHOST: ${ssdpGroup}:${ssdpPort}\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n`;
      await udp.send({ data: request, address: { address: ssdpGroup, family: 1, port: ssdpPort } });
      // Allow the camera's short UDP response to arrive before the socket is
      // closed, while keeping the handshake bounded on firmware that does not
      // answer M-SEARCH.
      await LumixCameraService.delay(350);
      try { LumixCameraService.logBoth(0x0001, 'VIVID_S5', `dmp M-SEARCH sent group=${ssdpGroup}:${ssdpPort} dmpPort=${port} reply=${responseSeen ? 1 : 0}`); } catch (_error) { }
    } catch (_error) {
      try { LumixCameraService.warnBoth(0x0001, 'VIVID_S5', `dmp M-SEARCH failed port=${port}`); } catch (_logError) { }
    } finally {
      try { await udp.close(); } catch (_error) { }
    }
  }

  private static async request(safeHost: string, path: string): Promise<string | null> {
    const response = await LumixCameraService.requestWithCode(safeHost, path);
    return response.code >= 200 && response.code < 300 ? response.body : null;
  }

  private static async requestWithCode(safeHost: string, path: string): Promise<LumixHttpResponse> {
    const client = http.createHttp();
    try {
      const response = await client.request(`http://${safeHost}${path}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 3000,
        readTimeout: 3000,
        expectDataType: http.HttpDataType.STRING,
      });
      const body = response.result === undefined || response.result === null ? '' : String(response.result);
      const result: LumixHttpResponse = { code: response.responseCode, body: body };
      return result;
    } catch (_error) {
      const result: LumixHttpResponse = { code: 0, body: null };
      return result;
    } finally {
      client.destroy();
    }
  }

  private static extractModel(payload: string): string {
    const fields: string[] = ['model', 'name', 'product', 'serial'];
    for (let index = 0; index < fields.length; index++) {
      const value = LumixCameraService.readField(payload, fields[index]);
      if (value.length > 0) return value;
    }
    const match = payload.match(/DC-[A-Za-z0-9]+/);
    return match ? match[0] : '';
  }

  /** Resolve a reported model string against the registry, longest key first. */
  private static lookupModel(model: string): LumixModelInfo | undefined {
    const exact = MODEL_REGISTRY.get(model);
    if (exact) return exact;
    const upper = model.toUpperCase();
    let bestKey = '';
    let best: LumixModelInfo | undefined = undefined;
    MODEL_REGISTRY.forEach((info: LumixModelInfo, key: string) => {
      if (upper.indexOf(key.toUpperCase()) >= 0 && key.length > bestKey.length) {
        bestKey = key;
        best = info;
      }
    });
    if (best) return best;
    let bestReverseKey = '';
    let bestReverse: LumixModelInfo | undefined = undefined;
    MODEL_REGISTRY.forEach((info: LumixModelInfo, key: string) => {
      if (key.toUpperCase().indexOf(upper) >= 0 && upper.length >= 3 && key.length > bestReverseKey.length) {
        bestReverseKey = key;
        bestReverse = info;
      }
    });
    return bestReverse;
  }

  private static readField(payload: string, field: string): string {
    const openTag = `<${field}>`;
    const closeTag = `</${field}>`;
    const start = payload.indexOf(openTag);
    const end = payload.indexOf(closeTag);
    if (start >= 0 && end > start) {
      return payload.substring(start + openTag.length, end).trim();
    }
    return '';
  }
}
