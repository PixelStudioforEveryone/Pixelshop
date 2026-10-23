import { http } from '@kit.NetworkKit';
import { ble, connection, constant } from '@kit.ConnectivityKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import wifiManager from '@ohos.wifiManager';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NikonCameraService } from './NikonCameraService';
import { SonyCameraService } from './SonyCameraService';
import { AppDiagnostics } from './AppDiagnostics';
import { AppLogStore } from '../pages/home/HomeShared';
import { AppLogSink } from './AppLogSink';

/**
 * Minimal, independent LUMIX Lab import path.
 *
 * This adapter deliberately keeps the app identity separate from LUMIX Lab.
 * The camera decides whether that identity is acceptable at runtime; no
 * Panasonic app id, UUID, token or certificate is copied into the project.
 */
export interface LumixImportResult {
  ok: boolean;
  phase: string;
  message: string;
  deviceId: string;
  clientUuid: string;
  imageId: string;
  imageType: number;
  thumbnailUri: string;
  httpStatus: number;
  businessResponseCode: number;
  trace: string[];
  bleConnected: boolean;
  wifiConnected: boolean;
  sessionEstablished: boolean;
  wifiSsid: string;
  gateway: string;
  galleryItems?: LumixGalleryItem[];
  galleryTotal?: number;
}

export interface LumixGalleryItem {
  imageId: string;
  imageType: number;
  thumbnailUri: string;
  size?: number;
  rawSize?: number;
  originalFileName?: string;
  /**
   * `gallery/info` 的 `Orientation`：1 = 正常，6 = 顺时针 90°，8 = 逆时针 90°，
   * 3 = 180°（官方 `C1746u.java:198` 用 6/8 交换宽高，`X0.java:67` 用
   * `C1746u.s1(matrix, orientation)` 旋转缩略图）。0 / 缺省 = 相机未给。
   *
   * **相机返回的缩略图 JPEG 本身不带 EXIF 方向**，所以这条字段是 Lab 线上
   * 唯一能判断横竖的凭据；丢掉它，竖拍照片在作品卡里就是躺倒的。
   */
  orientation?: number;
  /** 该条目所属的存储卡（尼康多卡的卡号）。Lumix/Sony 线不设。
   *
   * 由 `NikonPtpIpService` 扫描出来的尼康条目一定带它：两张卡的句柄空间相互
   * 独立，只有句柄无法区分是哪张卡。界面按它做「卡 1 / 卡 2」切换。 */
  storageId?: number;
}

export interface DownloadAttemptResult {
  received: number;
  path: string;
}

export interface LumixGalleryRefresh {
  ok: boolean;
  items: LumixGalleryItem[];
  total: number;
  message: string;
}

/** 'writing' = body is flashing, 'done' = body reported completion. */
export type LumixFirmwareWriteState = 'writing' | 'done';

export interface LumixFirmwareWriteWatcher {
  detach: () => void;
}

/** Snapshot of the authenticated Wi-Fi session (host/token/certificate pin). */
export interface LumixSessionSnapshot {
  host: string;
  token: string;
  fingerprint: string;
}

/** Model/firmware snapshot read over BLE for the firmware-update flow. */
export interface LumixFirmwareIdentity {
  modelName: string;
  cameraFirmware: string;
  lensName: string;
  lensFirmware: string;
  deviceId: string;
  trace: string[];
}

interface JsonResponse {
  httpStatus: number;
  body: string;
  headers: Object;
}

interface DownloadProgressInfo {
  receiveSize: number;
  totalSize: number;
}

interface JsonRequestHeaders {
  'Accept': string;
  'Content-Type': string;
  'Authorization'?: string;
  'Content-Length'?: string;
}

interface CameraHeader {
  ResponseCode?: number;
}

interface AuthData {
  AuthToken?: string;
}

interface GalleryImage {
  ImageId?: string;
  Type?: number;
  Size?: number;
  RawSize?: number;
  OriginalFileName?: string;
  /** `gallery/info` 的方向字段（1/3/6/8），见 `LumixGalleryItem.orientation`。 */
  Orientation?: number;
  // Set only on a RAW entry that findImages split out of the RAW+JPEG record
  // immediately before it. The transfer page windows the gallery by record, so
  // the split companion has to stay attached to its JPEG.
  GroupedWithPrevious?: boolean;
}

interface GalleryData {
  DataList?: Array<GalleryImage>;
}

interface GalleryCountData {
  Count?: number;
}

interface GalleryCountEnvelope {
  Data?: GalleryCountData;
}

interface AuthEnvelope {
  Header?: CameraHeader;
  Data?: AuthData;
}

interface CameraHeaderEnvelope {
  Header?: CameraHeader;
}

interface GalleryEnvelope {
  Header?: CameraHeader;
  Data?: GalleryData;
}

interface GattCharacteristicSet {
  appUuid?: ble.BLECharacteristic;
  appInfo?: ble.BLECharacteristic;
  friendlyName?: ble.BLECharacteristic;
  pairingInit?: ble.BLECharacteristic;
  wifiPassword?: ble.BLECharacteristic;
  initialInform?: ble.BLECharacteristic;
  wifiSsid?: ble.BLECharacteristic;
  actionMode?: ble.BLECharacteristic;
  /** Manual gallery-transfer trigger used by S5M2/S9/S1 bodies. */
  imageTransferAction?: ble.BLECharacteristic;
  apState?: ble.BLECharacteristic;
  actionModeResult?: ble.BLECharacteristic;
  certFingerprint?: ble.BLECharacteristic;
  serverUrl?: ble.BLECharacteristic;
  /** Body model ("DC-S1RM2") and firmware version, read over BLE. */
  cameraModelName?: ble.BLECharacteristic;
  cameraFirmwareVersion?: ble.BLECharacteristic;
  lensName?: ble.BLECharacteristic;
  lensFirmwareVersion?: ble.BLECharacteristic;
  /** Storage-slot inventory ("SSD,1" / "SD1,1,SD2,0"). See UUID_SD_SLOT_INFO. */
  sdSlotInfo?: ble.BLECharacteristic;
}

export interface LumixImportPhaseUpdate {
  phase: LumixPhase;
  message: string;
  bleConnected: boolean;
  wifiConnected: boolean;
  sessionEstablished: boolean;
  wifiSsid: string;
  gateway: string;
}

/** One storage slot as the camera reports it over BLE. */
export interface LumixSlot {
  /** 相机原样上报的名字：CFe / SD / SSD（也可能已合成 SD1/SD2）。 */
  name: string;
  /**
   * 发给 /media/gallery/current-sd 的值。官方客户端在图库侧并不发送清单里的
   * 原始名字，而是按**标签序号**命名（CameraGalleryActivity.java:967-975）：
   *   SSD 那一路 → "SSD"
   *   非 SSD 的第 0 个 → "SD1"
   *   非 SSD 的第 1 个 → "SD2"
   * 所以 S1RM2 的 CFe 槽发送值是 SD1、SD 槽是 SD2；S9 单槽是 SD1。
   */
  wire: string;
  /** 界面上显示的文字：CFe → "CFexpress"，SD → "SD"（C5/L4.java:455-472）。 */
  display: string;
  present: boolean;
}

/**
 * Storage-slot inventory read from SLOT_INFO over BLE.
 *
 * Single-slot bodies (S9 among them) report only `SSD`; two-slot bodies report
 * `SD1,SD2`; CFexpress bodies report `CFe` and/or `SD`. These names are the
 * valid `/media/gallery/current-sd` values, so the gallery cannot be opened
 * without knowing them — see resolveCurrentSd().
 */
export interface LumixSlotInfo {
  ok: boolean;
  slots: LumixSlot[];
  /** Raw characteristic text, kept for diagnostics. */
  raw: string;
  message: string;
}

export interface LumixBleCameraCandidate {
  deviceId: string;
  deviceName: string;
  model: string;
  imageKey: string;
  /** Brand-specific protocol route.  Panasonic remains the default for
   * candidates created by older callers. */
  brand?: string;
  rssi: number;
  connectable: boolean;
  /** Monotonic wall-clock marker assigned by the page when this advertisement
   * was received. It is optional so persisted/synthetic candidates remain
   * compatible with older callers. */
  lastSeenAt?: number;
  /** Radio-specific evidence for retained/offline camera cards. Never persisted. */
  bleLastSeenAt?: number;
  wifiLastSeenAt?: number;
  wifiSsid?: string;
  /** Stable identity carried by the LUMIX advertisement itself: the 4-byte
   * public Bluetooth address from manufacturer-specific data (company ID 58).
   * The body's local name is user-editable, so it can never be the stable key;
   * this address survives a rename. Empty/absent for Wi-Fi-only and non-LUMIX
   * candidates, which keep the name-alias fallback. */
  btAddress?: string;
}

interface LumixCameraIdentity {
  brand: string;
  model: string;
  imageKey: string;
}

/** Protocol fields a LUMIX advertisement carries independently of the
 * user-editable local name. */
interface LumixAdvertisement {
  /** Local name with the trailing 0x0A + model-code bytes removed. */
  displayName: string;
  /** Local name decoded byte-exact, control bytes preserved. */
  rawName: string;
  /** 1..9 model code; 0 when the name carries no protocol suffix. */
  modelCode: number;
  /** Uppercase 8-hex-digit public Bluetooth address; '' when absent. */
  btAddress: string;
  /** True when the advertisement lists the LUMIX control service UUID. */
  hasLumixService: boolean;
}

export interface LumixPairingResult {
  requested: boolean;
  bonded: boolean;
  state: number;
}

type LumixPhase = 'ble' | 'wifi' | 'session' | 'failed' | 'complete';

export interface WifiConnection {
  connected: boolean;
  ssid: string;
  gateway: string;
  ipAddress: string;
}

interface ErrorWithCode {
  code?: number;
}

const APP_ID = 'vivid_diary';
const APP_VERSION = '1.0.0-preview';
// BLE 注册槽每个相机远程模式周期只开放一次。官方抓包（LUT 协议文档）确认
// /lut 端点认可的 AppInfo 为 'LUMIX LUT Creators APP 3.0.1'（28 字符 + NUL
// 填充至 32B，与抓包一致）。图传线的 /media 端点对 AppInfo 不校验（自造
// 字符串也 200），所以用官方 LUT AppInfo 占用注册槽可同时服务两条业务线。
const APP_INFO_VALUE = 'LUMIX LUT Creators APP 3.0.1';
const FRIENDLY_NAME_VALUE = 'Pixelshop HarmonyOS';
const BLE_SCAN_SERVICE = '054ac620-3214-11e6-ac0d-0002a5d5c51b';
// LUMIX identity lives in the advertisement, not in the user-editable local
// name. The official app (K5/j.java, K5/g.java) filters scans on
// BLE_SCAN_SERVICE, then requires a local name whose last two bytes are
// 0x0A + a 1..9 model code, and takes the body's stable identity from
// manufacturer-specific data under company ID 58: six bytes whose bytes 2..5
// are the 4-byte public Bluetooth address. A camera rename changes only the
// name, so parsing these protocol fields keeps discovery working exactly
// where a name heuristic stops matching.
//
// Verified against K5/g.java: the address offset is 2 in BOTH status branches
// (i14 is initialised to 2 at line 58 and never reassigned; the status byte
// itself is found by scanning the six bytes for the first 0 or 3 at lines
// 86-97, so its position is not fixed). Reading a fixed offset 2 is therefore
// stable across status values, which matters because a varying offset would
// make one camera produce two different keys.
//
// Deliberate deviations from the official gate, both in the permissive
// direction so a real body is never hidden: the presence of the service UUID
// and the "some byte is 0 or 3" status check are recorded as diagnostics
// rather than required. The strong, rename-independent signal is the
// company-58 six-byte payload plus the 1..9 model code, and company ID 58
// cannot collide with Nikon (135) or Sony (301).
const BLE_MANUFACTURER_ID_LUMIX = 58;
const BLE_MANUFACTURER_DATA_LENGTH = 6;
const BLE_MANUFACTURER_ADDRESS_OFFSET = 2;
const BLE_MANUFACTURER_ADDRESS_LENGTH = 4;
const BLE_NAME_MODEL_MARKER = 0x0a;
/** Official model-code byte (the last byte of a LUMIX local name) to model
 * token, taken from the LUMIX Lab app's own lookup table. */
const PANASONIC_MODEL_CODE_TOKENS: string[] =
  ['', 'S9', 'GH7', 'S5M2', 'S5M2X', 'G9M2', 'S1M2E', 'S1M2', 'S1RM2', 'L10'];
const BLE_SERVICE = '1fe71b85-8344-4e6a-bf1a-ac7acdb3f8af';
const UUID_WIFI_PASSWORD = '42d509f7-f122-4816-92d1-5e402d9453cb';
const UUID_INITIAL_INFORM = '239c7203-922f-43e9-bdf1-6d1fedf6f43f';
const UUID_APP_INFO = 'ed8b1352-5aa7-4155-b7c9-521292dd1932';
const UUID_FRIENDLY_NAME = '05a797b6-9c2f-4d18-99a7-fa61a3880bfe';
const UUID_PAIRING_INIT = '36f99090-e79b-4060-9ac7-89f3f8bf88d5';
const UUID_WIFI_SSID = '657edba2-5bc8-42dd-974f-21871d7dbcd1';
const UUID_APP_UUID = 'bff12e7f-5944-4eb6-a90f-48d8786157ea';
const UUID_ACTION_MODE = '7644371c-1ddc-4b16-832f-f07c322e311b';
const UUID_IMAGE_TRANSFER_ACTION = '72ef8930-887b-47b2-bab0-a2cbbd657300';
const UUID_AP_STATE = 'dcba3a74-80bc-4919-8ef4-0c9f99cc20dd';
const UUID_ACTION_MODE_RESULT = '6c875728-7636-425e-818a-f1d93a39e075';
const UUID_CERT_FINGERPRINT = '1be8a9e3-178b-46c4-b6b3-43d4a5311fc1';
const UUID_SERVER_URL = '5c565e17-8fba-4aec-b863-32b9b318bfbd';
// Identity/version characteristics the firmware-update flow needs. Taken from
// the official name table K5/a.java (CAMERA_MODEL_NAME / CAMERA_FM_VERSION /
// LENS_NAME / LENS_FM_VERSION): the official client reads them on every
// connect (handshake report §4.1, §13.1) and FirmwareUpdateDetailFragment
// compares those versions against the cloud catalogue before it will send a
// firmware file, so a firmware update cannot be decided without them.
const UUID_CAMERA_MODEL_NAME = 'c623f9bd-beae-443b-b5e6-af4652b81343';
const UUID_CAMERA_FM_VERSION = 'd2a2a363-16a4-43df-89f4-7817be9f0cde';
const UUID_LENS_NAME = 'e416bfbd-2716-4976-be32-1bc28c5b6192';
const UUID_LENS_FM_VERSION = '799b5d87-e680-4ddf-bfd7-7b075830aff3';
// SLOT_INFO. The official client reads this as a plain UTF-8 string over BLE
// (K5/d.java:1076-1081, decoded at C5/C0202g.java:325) and parses it into the
// slot inventory (C5/L4.java:365-401). It is the only place a body says which
// slots it has, and those names are exactly what /media/gallery/current-sd
// accepts — so sending a name the body does not have breaks the whole gallery.
const UUID_SD_SLOT_INFO = 'd6bbd828-eb91-4b00-acfc-b2c5821ff0f7';
// CAMERA_OPERATE_NOTIFICATION (K5/a.java:33). value[0]==1 puts the body into
// the firmware-update state, value[0]==2 is the update-finished signal the
// official watches (K5/d.java:730-737).
const UUID_CAMERA_OPERATE_NOTIFICATION = '16726c35-52ef-4d00-868d-099549a90d9b';
const CCCD_UUID = '00002902-0000-1000-8000-00805f9b34fb';
const DEFAULT_SD = 'SSD';
const FIRST_PAGE_LIMIT = 6;
const THUMBNAIL_CATEGORY = 1;
// /media/gallery/info Type values, measured against a live RAW+JPEG body on
// 2026-10-11. The gallery Type describes the record; the /media/image request
// Type selects the representation. 64-byte ranged probes on one ImageId gave:
// Type=1/3/7 -> RW2 bytes (little-endian TIFF, magic 49495500), Type=2 -> JPEG
// bytes (magic ffd8ff). Official corroboration: C5/C0377w.java:163 sizes a
// record with getType() == 1 ? getRawSize() : getSize(), and
// C1746u.f1(t) = (t == 4 || t == 5) keeps 1/2/3/6/7 in the still-image family.
const LUMIX_TYPE_RAW = 1;
const LUMIX_TYPE_JPEG = 2;
const LUMIX_TYPE_RAW_JPEG = 3;
const LUMIX_TYPE_RAW_ALT = 7;
// Official per-request window on the Wi-Fi media leg: 16777215 bytes
// (LlcService.java:980-983; the USB leg uses a different, larger window).
// The official client walks successive Range windows until the file is
// complete — handshake report §13.3 records bytes=0-16777215 followed by
// bytes=16777216-27996159 for the same original.
const LUMIX_MEDIA_WINDOW = 16777215;

/**
 * This is a proof path, rather than a production transfer queue. It stops
 * after one gallery item and one thumbnail so that failures remain attributable
 * to a single protocol phase.
 */
export class LumixImportPrototype {
  private static storedUuid: string = '';
  private static store: preferences.Preferences | null = null;
  /** Monotonic request id used to correlate high-level HTTP diagnostics. */
  private static httpRequestSequence: number = 0;
  private static discoveryCallback: ((results: Array<ble.ScanResult>) => void) | null = null;
  // Ambient BLE traffic can produce hundreds of callbacks per second in a
  // crowded 2.4GHz environment. Per-result logging rotated the hilog buffer
  // within seconds and destroyed every other diagnostic (PTP transactions,
  // downloads, imports), so scan output is throttled to a heartbeat and only
  // camera-candidate lines are kept.
  private static lastScanLogAtMs: number = 0;
  private static scanResultCount: number = 0;
  // One advertisement diagnostic per distinct identity. The protocol fields
  // decide routing, so a body whose model code is not in the official table
  // (the LUMIX Sync generation) must be identifiable from the device log
  // without emitting one line per scan callback.
  private static loggedAdvertisementKeys: Set<string> = new Set<string>();
  private static sessionHost: string = '';
  private static sessionToken: string = '';
  private static sessionFingerprint: string = '';
  private static sessionGalleryTotal: number = 0;

  private static gallerySessionGeneration: number = 0;
  // Keep the successful BLE link alive while the camera is in its Wi‑Fi
  // transfer/remote-control state. Closing it immediately after the gallery
  // page makes the camera report “application disconnected”.
  private static activeGatt: ble.GattClientDevice | null = null;
  // The pairing button and the Wi‑Fi transfer button are two UI steps, but
  // LUMIX keeps the application registration bound to one GATT connection.
  // Retain the device id together with the live client so the transfer step
  // can continue that session instead of silently creating a second one.
  private static activeGattDeviceId: string = '';
  // Keep the notification subscription alive with the retained GATT link. A
  // few LUMIX bodies leave Wi-Fi mode when the AP_STATE/ACTION_MODE_RESULT
  // subscription is removed immediately after the first gallery response.
  private static activeGattNotificationHandler: ((changed: ble.BLECharacteristic) => void) | null = null;
  // Background GATT prewarm state. The camera page opens the LUMIX GATT link
  // and completes the app-level registration while the user is still reading
  // the card, so the Wi-Fi transfer click no longer pays the ~10s
  // connect/discover/register cost observed on the S5M2.
  private static prewarmInFlight: Promise<boolean> | null = null;
  private static prewarmLastAttemptAt: number = 0;
  // True while run() owns the BLE/Wi-Fi flow; blocks a concurrent prewarm
  // from opening a second GATT client to the same body.
  private static runInProgress: boolean = false;
  private static diagnosticFlowSequence: number = 0;
  // True while the LUT transfer page owns the camera: its BLE registration
  // carries the LUT client identity and its HTTPS session depends on the
  // camera staying in the LUT-registered mode. A background prewarm here
  // would re-register the image identity and commit 36f99090 without the
  // following ACTION_MODE, leaving the camera in its "await mode" state
  // (device log 22:34: the camera then reports "no application connected"
  // and shuts its Wi-Fi AP down).
  private static lutSessionActive: boolean = false;
  // A LUT BLE registration in flight; prewarm/run must not open a second
  // GATT client to the same body while it runs.
  private static lutRegistrationInFlight: Promise<boolean> | null = null;

  /** Mark the camera as owned by the LUT transfer page. While active, the
   * background image-line prewarm is suppressed so it cannot overwrite the
   * LUT client identity registered over BLE. */
  static setLutSessionActive(active: boolean): void {
    LumixImportPrototype.lutSessionActive = active;
    hilog.info(0x0001, 'VIVID_LUT', 'lut session active=%{public}d', active ? 1 : 0);
  }

  // While a LUMIX Sync pairing owns the BLE link the unfiltered
  // SCAN_MODE_LOW_LATENCY scan must stay down: the 2026-09-24 trace ran the
  // whole pairing under an active scan and the original S5 answered the
  // connect but never answered MTU or a single service-discovery round. The
  // real app never scans while connecting either.
  private static discoverySuspended: boolean = false;

  /** Suspend/resume the camera-page BLE scan around GATT-sensitive flows. */
  static setDiscoverySuspended(suspended: boolean): void {
    LumixImportPrototype.discoverySuspended = suspended;
    LumixImportPrototype.runtimeInfo(`camera discovery suspension=${suspended ? 1 : 0}`);
  }

  /** Start the camera-page BLE listener. Panasonic and Nikon names are
   * surfaced through separate identity functions; the connection still
   * discovers services and characteristics instead of using handles. */
  static startCameraDiscovery(onCandidate: (candidate: LumixBleCameraCandidate) => void): void {
    if (LumixImportPrototype.discoverySuspended) {
      LumixImportPrototype.runtimeInfo('camera discovery skipped: pairing in flight');
      return;
    }
    LumixImportPrototype.stopCameraDiscovery();
    LumixImportPrototype.runtimeInfo('camera discovery start');
    const callback = (results: Array<ble.ScanResult>): void => {
      if (!results || results.length === 0) return;
      const now = Date.now();
      if (now - LumixImportPrototype.lastScanLogAtMs > 10000) {
        LumixImportPrototype.lastScanLogAtMs = now;
        LumixImportPrototype.runtimeInfo(
          `scan heartbeat batch=${results.length} total=${LumixImportPrototype.scanResultCount}`);
      }
      for (const result of results) {
        LumixImportPrototype.scanResultCount += 1;
        const candidate = LumixImportPrototype.cameraCandidate(result);
        if (candidate) {
          LumixImportPrototype.runtimeInfo(`camera candidate brand=${candidate.brand || 'Panasonic'} model=${candidate.model} rssi=${candidate.rssi}`);
          onCandidate(candidate);
        }
      }
    };
    LumixImportPrototype.discoveryCallback = callback;
    try {
      ble.on('BLEDeviceFind', callback);
      LumixImportPrototype.runtimeInfo('scan callback registered');
      // Nikon bodies do not advertise the Panasonic service UUID. Harmony's
      // API documents null (rather than an empty array) for an unrestricted
      // scan; let the two brand-specific identity functions filter names.
      ble.startBLEScan(null, {
        interval: 0,
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
      });
      LumixImportPrototype.runtimeInfo('scan started filter=none');
    } catch (error) {
      LumixImportPrototype.logError('camera discovery', error);
    }
  }

  static stopCameraDiscovery(): void {
    try { ble.stopBLEScan(); } catch (_error) { }
    if (LumixImportPrototype.discoveryCallback) {
      try { ble.off('BLEDeviceFind', LumixImportPrototype.discoveryCallback); } catch (_error) { }
      LumixImportPrototype.discoveryCallback = null;
    }
  }

  /** Read the OS bond state for evidence. LUMIX's pairing request is an
   * application-level GATT registration; a generic OS PIN exchange is not
   * accepted by the camera and causes AUTH_FAILURE on the real device. */
  static async requestCameraPairing(deviceId: string): Promise<LumixPairingResult> {
    let state = connection.BondState.BOND_STATE_INVALID as number;
    try {
      state = connection.getPairState(deviceId) as number;
    } catch (error) {
      LumixImportPrototype.logError('camera pairing request', error);
    }
    return { requested: true, bonded: state === connection.BondState.BOND_STATE_BONDED, state: state };
  }

  /**
   * Request removal of an OS bond.
   *
   * The API 26 public ConnectivityKit surface exposes pairDevice() and
   * getPairState(), but no unpair/removePair/cancelPairing operation. Keep
   * this explicit result instead of calling an undocumented namespace member:
   * The caller keeps removal local and reports this limitation without
   * redirecting the user into a network settings page.
   */
  static async removeSystemPairing(deviceId: string): Promise<boolean> {
    if (deviceId.length > 0) {
      hilog.info(0xA00001, 'VIVID_BLE', 'system unpair unavailable: API 26 has no public cancellation method');
    }
    return false;
  }

  static clearHttpSession(): void {
    LumixImportPrototype.sessionHost = '';
    LumixImportPrototype.sessionToken = '';
    LumixImportPrototype.sessionFingerprint = '';
    LumixImportPrototype.sessionGalleryTotal = 0;
  }

  static endGallerySession(): void {
    LumixImportPrototype.gallerySessionGeneration += 1;
    LumixImportPrototype.sessionHost = '';
    LumixImportPrototype.sessionToken = '';
    LumixImportPrototype.sessionGalleryTotal = 0;
  }

  static galleryTotal(): number {
    return LumixImportPrototype.sessionGalleryTotal;
  }

  /**
   * Observe the camera's firmware-write notifications.
   *
   * `16726c35` is CAMERA_OPERATE_NOTIFICATION (official name table K5/a.java:33,
   * handled in K5/d.java:724-744): value[0]==1 means the body entered the
   * firmware-update state / started writing, value[0]==2 is the finished
   * signal (it sets the LiveData the official UI watches). This is the only
   * real completion report the camera gives — the HTTP leg has no finalize
   * request — so the firmware screen waits on it instead of guessing.
   *
   * Uses the retained GATT link when one exists; returns null when no link is
   * open (the caller then falls back to a plain message without a callback).
   */
  static observeFirmwareWriteProgress(trace: string[],
    onEvent: (state: LumixFirmwareWriteState, raw: number) => void): LumixFirmwareWriteWatcher | null {
    const gatt = LumixImportPrototype.activeGatt;
    if (gatt === null) {
      trace.push('firmware write observer skipped: no active GATT link');
      return null;
    }
    const handler = (changed: ble.BLECharacteristic): void => {
      if (changed.characteristicUuid.toLowerCase() !== UUID_CAMERA_OPERATE_NOTIFICATION) return;
      const bytes = new Uint8Array(changed.characteristicValue);
      if (bytes.length === 0) return;
      const raw = bytes[0];
      // 1 = entered update mode / writing, 2 = finished. Other values belong
      // to other CAMERA_OPERATE flows (3 = shooting, 6 = live streaming) and
      // are not firmware progress.
      if (raw !== 1 && raw !== 2) return;
      const state: LumixFirmwareWriteState = raw === 2 ? 'done' : 'writing';
      trace.push(`firmware notify 16726c35 raw=${raw} state=${state}`);
      hilog.info(0x0001, 'VIVID_FIRMWARE', 'camera firmware notify raw=%{public}d state=%{public}s', raw, state);
      onEvent(state, raw);
    };
    try {
      gatt.on('BLECharacteristicChange', handler);
      trace.push('firmware write observer attached to retained GATT link');
    } catch (error) {
      trace.push(`firmware write observer attach failed code=${LumixImportPrototype.errorCode(error)}`);
      return null;
    }
    return { detach: (): void => {
      try {
        gatt.off('BLECharacteristicChange', handler);
        trace.push('firmware write observer detached');
      } catch (_error) {
      }
    } };
  }

  static async closeActiveGatt(): Promise<void> {
    const gatt = LumixImportPrototype.activeGatt;
    const notificationHandler = LumixImportPrototype.activeGattNotificationHandler;
    LumixImportPrototype.activeGatt = null;
    LumixImportPrototype.activeGattNotificationHandler = null;
    LumixImportPrototype.activeGattDeviceId = '';
    if (!gatt) return;
    if (notificationHandler) {
      try { gatt.off('BLECharacteristicChange', notificationHandler); } catch (_error) { }
    }
    try { gatt.disconnect(); } catch (_error) { }
    try { gatt.close(); } catch (_error) { }
  }

  /** Close the local camera Wi-Fi route without sending another camera command. */
  static async disconnectCameraWifi(): Promise<void> {
    try { wifiManager.disconnect(); } catch (_error) { }
    LumixImportPrototype.clearHttpSession();
  }

  /**
   * Open the LUMIX GATT link and complete the app-level registration in the
   * background while the user is still reading the camera card. The retained
   * link is consumed by run() as a reusable session, so the Wi-Fi transfer
   * click skips the connect/discover/register sequence.
   *
   * Guards: never runs concurrently with run() or another prewarm, keeps a
   * cooldown after a failed attempt so an absent camera cannot trigger a
   * connect retry storm, and never churns a retained link that belongs to a
   * different body.
   */
  static prewarmGatt(context: common.UIAbilityContext, deviceId: string): Promise<boolean> {
    if (deviceId.length === 0) return Promise.resolve(false);
    if (LumixImportPrototype.runInProgress) return Promise.resolve(false);
    if (LumixImportPrototype.lutSessionActive) return Promise.resolve(false);
    if (LumixImportPrototype.lutRegistrationInFlight !== null) return Promise.resolve(false);
    if (LumixImportPrototype.prewarmInFlight !== null) return Promise.resolve(false);
    if (LumixImportPrototype.activeGatt !== null) {
      // A retained link is already warm for its body; do not churn it.
      return Promise.resolve(LumixImportPrototype.activeGattDeviceId === deviceId);
    }
    if (Date.now() - LumixImportPrototype.prewarmLastAttemptAt < 45000) return Promise.resolve(false);
    LumixImportPrototype.prewarmLastAttemptAt = Date.now();
    const attempt = LumixImportPrototype.prewarmGattOnce(context, deviceId);
    LumixImportPrototype.prewarmInFlight = attempt;
    return attempt.then((warm: boolean): boolean => {
      LumixImportPrototype.prewarmInFlight = null;
      return warm;
    }, (_reason: Object): boolean => {
      LumixImportPrototype.prewarmInFlight = null;
      return false;
    });
  }

  private static async prewarmGattOnce(context: common.UIAbilityContext, deviceId: string): Promise<boolean> {
    const trace: string[] = [];
    let gatt: ble.GattClientDevice | null = null;
    try {
      hilog.info(0xA00001, 'VIVID_BLE', 'GATT prewarm start device=%{public}s', LumixImportPrototype.shortId(deviceId));
      const clientUuid = await LumixImportPrototype.getClientUuid(context);
      gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
      try {
        const mtu = await gatt.setBLEMtu(64);
        trace.push(`GATT MTU negotiated=${mtu}`);
      } catch (_error) {
        trace.push('GATT MTU negotiation=UNRESOLVED; using platform default');
      }
      const services = await gatt.getServices();
      const chars = LumixImportPrototype.indexCharacteristics(services);
      if (!chars.actionMode || !chars.initialInform || !chars.wifiSsid || !chars.wifiPassword || !chars.pairingInit) {
        trace.push('GATT prewarm rejected; LUMIX provisioning characteristics missing');
        throw new Error('LUMIX provisioning characteristics missing');
      }
      // AP-ready signal: AP_STATE=03 (network ready) or ACTION_MODE_RESULT=00
      // (action finished) after the ACTION_MODE write below.
      let signalApReady: (() => void) | null = null;
      const apReady = new Promise<void>((resolve: () => void) => {
        signalApReady = resolve;
      });
      const notificationHandler = (changed: ble.BLECharacteristic): void => {
        const bytes = new Uint8Array(changed.characteristicValue);
        const uuid = changed.characteristicUuid.toLowerCase();
        if (uuid === UUID_AP_STATE || uuid === UUID_ACTION_MODE_RESULT) {
          hilog.info(0x0001, 'VIVID_BLE', 'LUMIX notify uuid=%{public}s len=%{public}d raw=%{public}s', changed.characteristicUuid, bytes.length, LumixImportPrototype.safeHex(bytes));
          const value = bytes.length > 0 ? bytes[0] : -1;
          if (signalApReady !== null &&
            ((uuid === UUID_AP_STATE && value === 0x03) ||
              (uuid === UUID_ACTION_MODE_RESULT && value === 0x00))) {
            signalApReady();
          }
        }
      };
      gatt.on('BLECharacteristicChange', notificationHandler);
      await LumixImportPrototype.enableNotification(gatt, chars.actionModeResult, trace);
      await LumixImportPrototype.enableNotification(gatt, chars.apState, trace);
      const initialInform = await LumixImportPrototype.readGatt(gatt, chars.initialInform, trace);
      if (chars.appUuid) await LumixImportPrototype.writeGatt(gatt, chars.appUuid, LumixImportPrototype.xorReverseWithInitial(
        initialInform,
        LumixImportPrototype.encodeProtocolString(LumixImportPrototype.uuidBytes(clientUuid)),
      ), trace);
      if (chars.appInfo) await LumixImportPrototype.writeGatt(gatt, chars.appInfo, LumixImportPrototype.paddedUtf8(APP_INFO_VALUE, 32), trace);
      if (chars.friendlyName) await LumixImportPrototype.writeGatt(gatt, chars.friendlyName, LumixImportPrototype.xorReverseWithInitial(
        initialInform,
        LumixImportPrototype.encodeProtocolString(util.TextEncoder.create('utf-8').encode(FRIENDLY_NAME_VALUE)),
      ), trace);
      try {
        await LumixImportPrototype.writeGatt(gatt, chars.pairingInit, new Uint8Array([0x02]), trace);
        trace.push('Pixelshop app-level pairing registration=complete (prewarm)');
      } catch (pairingError) {
        // A body that has already registered this client can reject the
        // duplicate 36f99090 write while still accepting the active transfer
        // commands on the same link.
        trace.push(`Pixelshop app-level pairing registration rejected code=${LumixImportPrototype.errorCode(pairingError)}; treating link as already registered`);
      }
      // The 36f99090 commit makes the camera leave its current mode and wait
      // for ACTION_MODE (handshake doc §13.1). Stopping after the commit
      // leaves the body in that "await mode" state: its HTTP server stops
      // answering and it exits remote control after a timeout ("no
      // application connected", device logs 22:18/22:34). Complete the
      // official sequence so a background prewarm always ends with the
      // camera healthy in AP mode instead of dead. ACTION_MODE=01 is
      // repeatable (§13.6), so the later transfer click just writes it again.
      await LumixImportPrototype.writeGatt(gatt, chars.actionMode, new Uint8Array([0x01]), trace);
      const apReadySignaled = await Promise.race([
        apReady.then((): boolean => true),
        new Promise<boolean>((resolve: (value: boolean) => void) => {
          setTimeout(() => {
            resolve(false);
          }, 10000);
        }),
      ]);
      trace.push(`prewarm ACTION_MODE ap-ready=${apReadySignaled ? 'signaled' : 'timeout'}`);
      LumixImportPrototype.activeGatt = gatt;
      LumixImportPrototype.activeGattDeviceId = deviceId;
      LumixImportPrototype.activeGattNotificationHandler = notificationHandler;
      LumixImportPrototype.emitTrace(trace);
      hilog.info(0xA00001, 'VIVID_BLE', 'GATT prewarm complete device=%{public}s', LumixImportPrototype.shortId(deviceId));
      return true;
    } catch (error) {
      if (gatt) {
        try { gatt.disconnect(); } catch (_error) { }
        try { gatt.close(); } catch (_error) { }
      }
      trace.push(`GATT prewarm failed code=${LumixImportPrototype.errorCode(error)}`);
      LumixImportPrototype.emitTrace(trace);
      hilog.info(0xA00001, 'VIVID_BLE', 'GATT prewarm failed device=%{public}s code=%{public}s', LumixImportPrototype.shortId(deviceId), LumixImportPrototype.errorCode(error));
      return false;
    }
  }

  /**
   * Register a LUT client identity with the camera over BLE before the HTTPS
   * /lut session. The camera hands out /auth tokens to any identity but gates
   * the /lut/* endpoints on the app-level BLE registration (bff12e7f UUID
   * challenge response / ed8b1352 app name / 05a797b6 friendly name /
   * 36f99090 = [02]), which the official "LUMIX LUT Creators APP" performs on
   * every connect. The image-transfer line registers its own identity with
   * this same sequence (prewarmGattOnce); this runs it with the LUT app's
   * name and UUID. Best-effort: returns false on BLE failure and lets the
   * caller continue with the plain HTTP attempt.
   */
  static async registerLutIdentity(lutUuid: string, appInfo: string, friendlyName: string): Promise<boolean> {
    if (lutUuid.length === 0) return false;
    if (LumixImportPrototype.runInProgress) return false;
    // Serialize against the other GATT owners of the same body: an image-line
    // prewarm (or a previous LUT registration) must finish before a second
    // client is opened.
    if (LumixImportPrototype.lutRegistrationInFlight !== null) {
      try { await LumixImportPrototype.lutRegistrationInFlight; } catch (_error) { }
    }
    if (LumixImportPrototype.prewarmInFlight !== null) {
      try { await LumixImportPrototype.prewarmInFlight; } catch (_error) { }
    }
    // An image-line run may still own the camera (its BLE registration plus
    // the ACTION_MODE mode reset). Poll for it to finish instead of bailing
    // instantly (device log 23:19: candidates 1-2 were rejected while a
    // gallery run was winding down and never got another chance). The run
    // takes up to ~30s when it reconnects Wi-Fi.
    const runDeadline = Date.now() + 45000;
    while (LumixImportPrototype.runInProgress && Date.now() < runDeadline) {
      await LumixImportPrototype.delay(500);
    }
    if (LumixImportPrototype.runInProgress) return false;
    // 官方行为（23:35 真机证据 + 用户对 LUMIX Lab 的观察）：注册槽每个
    // 远程模式周期只开放一次，图传线的保留链路已经持有注册身份。此时再走
    // BLE 注册必然被 2900099 拒绝，而为了注册先断开保留链路会让相机认为
    // 控制应用已离开并退出受控模式。跳过 BLE，直接让 LUT 线用已注册身份
    // 走 HTTP /auth。只有相机上还没有任何注册（无保留链路）时才真正注册。
    if (LumixImportPrototype.activeGatt !== null) {
      hilog.info(0x0001, 'VIVID_LUT', 'ble lut registration skipped; retained registered link present');
      return false;
    }
    const attempt = LumixImportPrototype.registerLutIdentityOnce(lutUuid, appInfo, friendlyName);
    LumixImportPrototype.lutRegistrationInFlight = attempt;
    try {
      return await attempt;
    } finally {
      if (LumixImportPrototype.lutRegistrationInFlight === attempt) {
        LumixImportPrototype.lutRegistrationInFlight = null;
      }
    }
  }

  private static async registerLutIdentityOnce(lutUuid: string, appInfo: string, friendlyName: string): Promise<boolean> {
    const trace: string[] = [];
    let gatt: ble.GattClientDevice | null = null;
    try {
      // Never reuse the image line's retained link: it already carries the
      // image client identity, and the camera rejects both a second 36f99090
      // commit and the following ACTION_MODE write on an already-registered
      // link (device log 22:34: code 2900099 on both). Release it and start
      // from a fresh link; the image line re-registers its own identity on
      // its next run.
      if (LumixImportPrototype.activeGatt !== null) {
        hilog.info(0x0001, 'VIVID_LUT', 'ble lut registration start link=retained-release');
        try { await LumixImportPrototype.closeActiveGatt(); } catch (_error) { }
      }
      const deviceId = await LumixImportPrototype.scanBle(trace, '', true);
      if (deviceId.length === 0) {
        hilog.info(0x0001, 'VIVID_LUT', 'ble lut registration scan=no-camera');
        return false;
      }
      const paired = await LumixImportPrototype.ensurePaired(deviceId, trace);
      if (!paired) {
        // 与 run() 同款容忍式：模式重置后 BLE 随机地址轮换，系统 bond 往往
        // 失效（pair state=0），但 23:19 真机实证此时 GATT 连接与注册写入
        // 依然成功。配对状态只作为证据记录，不作为硬门禁。
        trace.push('BLE pairing evidence=UNRESOLVED; attempting LUT GATT without completed bond');
        hilog.info(0x0001, 'VIVID_LUT', 'ble lut registration pairing=unresolved; attempting gatt anyway');
      }
      gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
      const services = await gatt.getServices();
      const chars = LumixImportPrototype.indexCharacteristics(services);
      if (!chars.initialInform || !chars.appUuid || !chars.actionMode) {
        hilog.info(0x0001, 'VIVID_LUT', 'ble lut registration rejected; registration characteristics missing');
        return false;
      }
      // AP 就绪信号：官方序列里 ACTION_MODE 之后 AP_STATE=03（网络就绪）
      // 或 ACTION_MODE_RESULT=00（动作完成）表示相机可以接受 HTTP。
      let signalApReady: (() => void) | null = null;
      const apReady = new Promise<void>((resolve: () => void) => {
        signalApReady = resolve;
      });
      const handler = (changed: ble.BLECharacteristic): void => {
        const bytes = new Uint8Array(changed.characteristicValue);
        const uuid = changed.characteristicUuid.toLowerCase();
        if (uuid === UUID_AP_STATE || uuid === UUID_ACTION_MODE_RESULT) {
          hilog.info(0x0001, 'VIVID_LUT', 'ble lut notify uuid=%{public}s raw=%{public}s',
            changed.characteristicUuid, LumixImportPrototype.safeHex(bytes));
          const value = bytes.length > 0 ? bytes[0] : -1;
          if ((uuid === UUID_AP_STATE && value === 0x03) ||
            (uuid === UUID_ACTION_MODE_RESULT && value === 0x00)) {
            if (signalApReady !== null) signalApReady();
          }
        }
      };
      gatt.on('BLECharacteristicChange', handler);
      try {
        await LumixImportPrototype.enableNotification(gatt, chars.actionModeResult, trace);
        await LumixImportPrototype.enableNotification(gatt, chars.apState, trace);
        const initialInform = await LumixImportPrototype.readGatt(gatt, chars.initialInform, trace);
        await LumixImportPrototype.writeGatt(gatt, chars.appUuid, LumixImportPrototype.xorReverseWithInitial(
          initialInform,
          LumixImportPrototype.encodeProtocolString(LumixImportPrototype.uuidBytes(lutUuid)),
        ), trace);
        if (chars.appInfo) {
          await LumixImportPrototype.writeGatt(gatt, chars.appInfo, LumixImportPrototype.paddedUtf8(appInfo, 32), trace);
        }
        if (chars.friendlyName) {
          await LumixImportPrototype.writeGatt(gatt, chars.friendlyName, LumixImportPrototype.xorReverseWithInitial(
            initialInform,
            LumixImportPrototype.encodeProtocolString(util.TextEncoder.create('utf-8').encode(friendlyName)),
          ), trace);
        }
        if (chars.pairingInit) {
          try {
            await LumixImportPrototype.writeGatt(gatt, chars.pairingInit, new Uint8Array([0x02]), trace);
            trace.push('LUT app-level pairing registration=complete');
          } catch (pairingError) {
            // Same tolerance as the image line: a body that has already
            // registered a client can reject the duplicate 36f99090 write.
            trace.push(`LUT app-level pairing registration rejected code=${LumixImportPrototype.errorCode(pairingError)}; treating link as already registered`);
          }
        }
        // 官方序列（握手文档 §13.1）：36f99090 提交后相机离开当前模式等待
        // ACTION_MODE；不写这一步相机会停在模式重置态，HTTP 服务器不会
        // 回来（22:18 真机：注册四写全过但 /auth 无响应、相机退出远程
        // 控制模式）。ACTION_MODE=01 可重复写（§13.6），恒定安全。
        await LumixImportPrototype.writeGatt(gatt, chars.actionMode, new Uint8Array([0x01]), trace);
        const signaled = await Promise.race([
          apReady.then((): boolean => true),
          new Promise<boolean>((resolve: (value: boolean) => void) => {
            setTimeout(() => {
              resolve(false);
            }, 15000);
          }),
        ]);
        hilog.info(0x0001, 'VIVID_LUT', 'ble lut ap-ready signal=%{public}d', signaled ? 1 : 0);
      } finally {
        try { gatt.off('BLECharacteristicChange', handler); } catch (_error) { }
      }
      hilog.info(0x0001, 'VIVID_LUT', 'ble lut registration complete');
      LumixImportPrototype.emitTrace(trace);
      return true;
    } catch (error) {
      trace.push(`LUT BLE registration failed code=${LumixImportPrototype.errorCode(error)}`);
      LumixImportPrototype.emitTrace(trace);
      hilog.info(0x0001, 'VIVID_LUT', 'ble lut registration failed code=%{public}s', LumixImportPrototype.errorCode(error));
      return false;
    } finally {
      // Do not retain this link: it now carries the LUT identity, and the
      // image-transfer flow must re-register its own identity on its next
      // run instead of silently reusing a foreign registration.
      if (gatt !== null) {
        try { gatt.disconnect(); } catch (_error) { }
        try { gatt.close(); } catch (_error) { }
      }
    }
  }

  /** Persist the camera identity after the app-level LUMIX registration has
   * completed. The BLE address is intentionally not stored because camera LE
   * addresses may rotate; the advertised model/name is the stable identity
   * used by the camera page listener. */
  static async rememberCameraPairing(context: common.UIAbilityContext, deviceName: string): Promise<void> {
    const normalizedName = deviceName.replace(/[\u0000-\u001F\u007F]/g, '').trim();
    if (normalizedName.length === 0) return;
    const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
    await store.put('pairedCameraName', normalizedName);
    await store.flush();
  }

  /** Resolve the current advertised name for a device id returned by GATT.
   *  Some API 26 scan callbacks omit deviceName; keeping this lookup public
   *  lets the UI commit the physical camera identity after a successful GATT
   *  connection instead of falling back to the generic LUMIX card. */
  static remoteDeviceName(deviceId: string): string {
    if (deviceId.length === 0) return '';
    try {
      return (connection.getRemoteDeviceName(deviceId) || '')
        .replace(/[\u0000-\u001F\u007F]/g, '').trim();
    } catch (_error) {
      return '';
    }
  }

  static async rememberedCameraName(context: common.UIAbilityContext): Promise<string> {
    const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
    const saved = await store.get('pairedCameraName', '');
    return typeof saved === 'string' ? saved : '';
  }

  static async clearRememberedCamera(context: common.UIAbilityContext): Promise<void> {
    const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
    await store.delete('pairedCameraName');
    await store.flush();
  }

  /** Fetch the next gallery page over the authenticated Wi-Fi session. This
   * path does not touch BLE and never re-sends ACTION_MODE. */
  static async fetchGalleryPage(context: common.UIAbilityContext, startIndex: number): Promise<LumixGalleryItem[]> {
    if (LumixImportPrototype.sessionHost.length === 0 || LumixImportPrototype.sessionToken.length === 0) return [];
    const trace: string[] = [];
    try {
      // Field-level capture of the real LUMIX Lab client (2026-09-13,
      // analysis/lumixlab-fields-capture-20260913.md) confirmed the info body
      // {"StartIndex":…,"Limit":50,"Rating":null}; the Rating key must be
      // present or the camera answers a business 403. Request the wide page
      // once and slice the requested window out of it.
      const info = await LumixImportPrototype.postJson(
        LumixImportPrototype.sessionHost,
        '/media/gallery/info',
        JSON.stringify({ StartIndex: startIndex, Limit: 50, Rating: null }),
        LumixImportPrototype.sessionToken,
        LumixImportPrototype.sessionFingerprint,
        trace,
      );
      if (!LumixImportPrototype.checkBusinessCode(info, 'gallery/info/page', trace)) return [];
      const pageImages: GalleryImage[] = LumixImportPrototype.findImages(info.body);
      LumixImportPrototype.probeGalleryInfo(info.body);
      LumixImportPrototype.probeGalleryItems(`fetch start=${startIndex} page`, pageImages);
      const images: GalleryImage[] = LumixImportPrototype.takeOldestRecords(pageImages, FIRST_PAGE_LIMIT);
      LumixImportPrototype.probeGalleryItems(`fetch start=${startIndex} slice`, images);
      if (images.length === 0) return [];
      const items: LumixGalleryItem[] = [];
      // 窗口已按记录收敛，这里不能再按 FIRST_PAGE_LIMIT 截断：条目数大于记录
      // 数时会把后半张照片的缩略图全部跳过，卡片随即被 if (thumb.length > 0)
      // 静默丢掉，界面上就是「怎么滑都只有几张」。
      for (let index = 0; index < images.length; index++) {
        const imageId = images[index].ImageId || '';
        const imageType = Number(images[index].Type);
        if (imageId.length === 0 || !Number.isFinite(imageType)) continue;
        const thumb = await LumixImportPrototype.postThumbnail(
          LumixImportPrototype.sessionHost,
          imageId,
          LumixImportPrototype.sessionToken,
          LumixImportPrototype.sessionFingerprint,
          context,
          trace,
          startIndex + index,
        );
        if (thumb.length > 0) items.push({
          imageId: imageId,
          imageType: imageType,
          thumbnailUri: thumb,
          size: Number(images[index].Size) || 0,
          rawSize: Number(images[index].RawSize) || 0,
          originalFileName: images[index].OriginalFileName || '',
          orientation: Number(images[index].Orientation) || 0,
        });
      }
      // The camera's gallery ordinal is oldest-to-newest. The UI starts at
      // the tail and appends older pages as the user scrolls down, so expose
      // each page in newest-first order without changing ImageId values.
      items.reverse();
      LumixImportPrototype.httpInfo(`VIVID_RAWDBG fetch-return start=${startIndex} count=${items.length}`);
      LumixImportPrototype.emitTrace(trace);
      return items;
    } catch (error) {
      LumixImportPrototype.logError('gallery page', error);
      return [];
    }
  }

  static async refreshGallerySession(context: common.UIAbilityContext, sdCard: string): Promise<LumixGalleryRefresh> {
    const trace: string[] = [];
    const fail = (message: string): LumixGalleryRefresh => {
      LumixImportPrototype.emitTrace(trace);
      LumixImportPrototype.runtimeInfo(`gallery refresh result=failed sd=${sdCard} reason=${message}`);
      return { ok: false, items: [], total: LumixImportPrototype.sessionGalleryTotal, message: message };
    };
    try {
      LumixImportPrototype.runtimeInfo(`gallery refresh start sd=${sdCard}`);
      if (LumixImportPrototype.runInProgress) return fail('相机连接流程正在进行中');
      if (LumixImportPrototype.sessionFingerprint.length === 0) {
        const remembered = await LumixImportPrototype.rememberedCameraFingerprint(context);
        if (remembered.length === 0) return fail('缺少相机证书指纹，需要重新完整连接');
        LumixImportPrototype.sessionFingerprint = remembered;
      }
    let linkedSsid = '';
    let gateway = '';
    try {
      const linked = await wifiManager.getLinkedInfo();
      linkedSsid = (linked.ssid || '').replace(/^"|"$/g, '').trim();
      gateway = LumixImportPrototype.ipv4(wifiManager.getIpInfo().gateway);
    } catch (_error) {
    }
    // Do not classify the camera by a Wi-Fi name prefix. Official LUMIX Lab
    // admits a body from its Bluetooth advertisement (the public BT address in
    // the manufacturer-specific payload) and the LUMIX Sync generation from the
    // six-byte manufacturer value, so neither generation uses the Wi-Fi name as
    // identity. The authoritative SSID for this session is the one the camera
    // returned over BLE, which connectWifi matches exactly; a prefix test here
    // only risks rejecting a legitimately renamed camera. The DHCP gateway the
    // camera serves is the real reachability evidence.
    if (gateway.length === 0) return fail('手机未连接相机 Wi‑Fi');
    trace.push(`Wi-Fi linked ssid=${linkedSsid} gateway=${gateway}`);
    const host = LumixImportPrototype.selectHost(LumixImportPrototype.sessionHost, gateway, trace);
    if (host.length === 0) return fail('未取得相机网络网关');
    const fingerprint = LumixImportPrototype.sessionFingerprint;
    const generation = LumixImportPrototype.gallerySessionGeneration;
    const authenticate = async (): Promise<string> => {
      const clientUuid = await LumixImportPrototype.getClientUuid(context);
      const authBody = JSON.stringify({
        AppInfo: `Pixelshop Studio ${APP_ID}/${APP_VERSION}`,
        FriendlyName: FRIENDLY_NAME_VALUE,
        Uuid: clientUuid,
      });
      const auth = await LumixImportPrototype.postJson(host, '/auth', authBody, '', fingerprint, trace);
      return LumixImportPrototype.requireBusinessSuccess(auth, '认证', trace);
    };
    let token = LumixImportPrototype.sessionToken;
    const tokenWasRetained = token.length > 0;
    if (!tokenWasRetained) {
      token = await authenticate();
      if (token.length === 0) return fail('相机会话认证未通过，请重新建立连接');
      if (generation !== LumixImportPrototype.gallerySessionGeneration) return fail('会话已在刷新过程中被结束');
      LumixImportPrototype.sessionHost = host;
      LumixImportPrototype.sessionToken = token;
    }
    let currentSd = LumixImportPrototype.resolveCurrentSd(sdCard);
    if (currentSd !== sdCard) {
      trace.push(`current-sd resolved ${sdCard}->${currentSd} from camera slot inventory`);
    }
    let current = await LumixImportPrototype.postJson(host, '/media/gallery/current-sd', JSON.stringify({ CurrentSd: currentSd }), token, fingerprint, trace);
    if (!LumixImportPrototype.checkBusinessCode(current, 'current-sd', trace)
      && currentSd.toUpperCase() !== 'SSD') {
      // Official forgiveness: CameraGalleryActivity.java:2536-2541 forces
      // resultSuccess=true when CurrentSd is SSD, i.e. SSD is a safe last resort
      // on a body whose slot inventory could not be read. Without this a
      // single-slot camera answers "current-sd 被拒绝" and the gallery stays
      // empty forever — no thumbnails, nothing downloadable.
      trace.push('current-sd rejected; retrying once with the single-slot sentinel SSD');
      currentSd = 'SSD';
      current = await LumixImportPrototype.postJson(host, '/media/gallery/current-sd', JSON.stringify({ CurrentSd: currentSd }), token, fingerprint, trace);
    }
    if (!LumixImportPrototype.checkBusinessCode(current, 'current-sd', trace)) {
      if (!tokenWasRetained) return fail('相机会话已认证，但 current-sd 被拒绝');
      trace.push('current-sd rejected with retained token; re-authenticating once');
      token = await authenticate();
      if (token.length === 0) {
        LumixImportPrototype.endGallerySession();
        return fail('相机会话已过期且重新认证失败');
      }
      if (generation !== LumixImportPrototype.gallerySessionGeneration) return fail('会话已在刷新过程中被结束');
      LumixImportPrototype.sessionHost = host;
      LumixImportPrototype.sessionToken = token;
      current = await LumixImportPrototype.postJson(host, '/media/gallery/current-sd', JSON.stringify({ CurrentSd: currentSd }), token, fingerprint, trace);
      if (!LumixImportPrototype.checkBusinessCode(current, 'current-sd', trace)) return fail('相机会话已认证，但 current-sd 被拒绝');
    }
    let galleryTotal = 0;
    let countAccepted = false;
    try {
      const count = await LumixImportPrototype.postJson(host, '/media/gallery/count', '', token, fingerprint, trace);
      if (LumixImportPrototype.checkBusinessCode(count, 'gallery/count', trace)) {
        galleryTotal = LumixImportPrototype.galleryCount(count.body);
        countAccepted = true;
        trace.push(`gallery/count parsed total=${galleryTotal}`);
      } else {
        trace.push(`gallery/count rejected http=${count.httpStatus}; continue gallery/info startIndex=0`);
      }
    } catch (countError) {
      trace.push(`gallery/count exception code=${LumixImportPrototype.errorCode(countError)}; continue gallery/info startIndex=0`);
    }
    // 相机权威报告当前卡 0 张照片（count 200/Count=0）：空卡时 gallery/info
    // 必答业务 403（索引越界），不能按瞬态重试（4×1.5 秒白等且提示误导）。
    // 会话按成功收尾、返回空图库，由 UI 提示切换另一张卡（双卡槽机型）。
    const cardIsEmpty = countAccepted && galleryTotal === 0;
    const emptyCardRefresh = (): LumixGalleryRefresh => {
      LumixImportPrototype.sessionHost = host;
      LumixImportPrototype.sessionToken = token;
      LumixImportPrototype.sessionGalleryTotal = 0;
      LumixImportPrototype.emitTrace(trace);
      LumixImportPrototype.runtimeInfo(`gallery refresh result=empty sd=${sdCard}`);
      return { ok: true, items: [], total: 0, message: `${sdCard} 上没有照片（0 张），可切换另一张存储卡后重试` };
    };
    const requestedLimit = 50;
    const firstStartIndex = galleryTotal > requestedLimit ? galleryTotal - requestedLimit : 0;
    trace.push(`gallery/info start=${firstStartIndex} limit=${requestedLimit} rating=null total=${galleryTotal}`);
    let images: GalleryImage[] = [];
    let info = await LumixImportPrototype.postJson(host, '/media/gallery/info', JSON.stringify({ StartIndex: firstStartIndex, Limit: requestedLimit, Rating: null }), token, fingerprint, trace);
    let accepted = LumixImportPrototype.checkBusinessCode(info, 'gallery/info', trace);
    const maxInfoAttempt = cardIsEmpty ? 1 : 4;
    for (let infoAttempt = 2; !accepted && infoAttempt <= maxInfoAttempt; infoAttempt++) {
      trace.push(`gallery/info transient retry attempt=${infoAttempt}`);
      await LumixImportPrototype.delay(1500);
      info = await LumixImportPrototype.postJson(host, '/media/gallery/info', JSON.stringify({ StartIndex: firstStartIndex, Limit: requestedLimit, Rating: null }), token, fingerprint, trace);
      accepted = LumixImportPrototype.checkBusinessCode(info, 'gallery/info', trace);
    }
    if (!accepted) {
      if (cardIsEmpty) return emptyCardRefresh();
      return fail('相机会话已认证，但 gallery/info 被拒绝');
    }
    images = LumixImportPrototype.findImages(info.body);
    LumixImportPrototype.probeGalleryInfo(info.body);
    LumixImportPrototype.probeGalleryItems('parsed', images);
    // galleryTotal 是「记录数」，images 是「条目数」（RAW+JPEG 会拆成 JPEG +
    // RAW 两条），按 galleryTotal 截断会把拆出来的 RAW 条目直接砍掉——这正是
    // RW2 卡片消失的直接原因。请求本身已用 Limit 限定页大小，这里不再截断。
    if (images.length === 0) {
      if (cardIsEmpty) return emptyCardRefresh();
      return fail('图库响应没有可下载的 ImageId');
    }
    images = LumixImportPrototype.takeNewestRecords(images, FIRST_PAGE_LIMIT);
    LumixImportPrototype.probeGalleryItems('window', images);
    const galleryItems: LumixGalleryItem[] = [];
    // 同上：按记录收敛之后不再按 FIRST_PAGE_LIMIT 截断条目循环。
    for (let index = 0; index < images.length; index++) {
      const image = images[index];
      const imageId = image.ImageId || '';
      const imageType = Number(image.Type);
      if (imageId.length === 0 || !Number.isFinite(imageType)) continue;
      const thumb = await LumixImportPrototype.postThumbnail(host, imageId, token, fingerprint, context, trace, firstStartIndex + index);
      if (thumb.length > 0) galleryItems.push({
        imageId: imageId,
        imageType: imageType,
        thumbnailUri: thumb,
        size: Number(image.Size) || 0,
        rawSize: Number(image.RawSize) || 0,
        originalFileName: image.OriginalFileName || '',
        orientation: Number(image.Orientation) || 0,
      });
    }
    if (galleryItems.length === 0) return fail('缩略图 HTTP 传输失败或返回空数据');
    if (generation !== LumixImportPrototype.gallerySessionGeneration) return fail('会话已在刷新过程中被结束');
    galleryItems.reverse();
    LumixImportPrototype.sessionHost = host;
    LumixImportPrototype.sessionToken = token;
    LumixImportPrototype.sessionGalleryTotal = galleryTotal;
    LumixImportPrototype.emitTrace(trace);
    LumixImportPrototype.runtimeInfo(`gallery refresh result=ok sd=${sdCard} items=${galleryItems.length} total=${galleryTotal}`);
    return { ok: true, items: galleryItems, total: galleryTotal, message: `已加载 ${galleryItems.length} 张缩略图` };
    } catch (error) {
      LumixImportPrototype.logError('gallery refresh', error);
      return fail('相机图库请求异常，请重试');
    }
  }

  private static result(trace: string[], phase: string, message: string, clientUuid: string = '', deviceId: string = '', imageId: string = '', imageType: number = 0, thumbnailUri: string = '', httpStatus: number = 0, businessResponseCode: number = 0, bleConnected: boolean = false, wifiConnected: boolean = false, sessionEstablished: boolean = false, wifiSsid: string = '', gateway: string = ''): LumixImportResult {
    AppDiagnostics.event('VIVID_BLE', `RESULT result=failed http=${httpStatus} business=${businessResponseCode} ble=${bleConnected ? 1 : 0} wifi=${wifiConnected ? 1 : 0} session=${sessionEstablished ? 1 : 0}`);
    LumixImportPrototype.emitTrace(trace);
    AppDiagnostics.flush();
    return {
      ok: false,
      phase: phase,
      message: message,
      deviceId: deviceId,
      clientUuid: clientUuid,
      imageId: imageId,
      imageType: imageType,
      thumbnailUri: thumbnailUri,
      httpStatus: httpStatus,
      businessResponseCode: businessResponseCode,
      trace: trace,
      bleConnected: bleConnected,
      wifiConnected: wifiConnected,
      sessionEstablished: sessionEstablished,
      wifiSsid: wifiSsid,
      gateway: gateway,
    };
  }

  static async run(context: common.UIAbilityContext, hostOverride: string = '', onPhase?: (update: LumixImportPhaseUpdate) => void, preferredDeviceId: string = '', requestSystemPairing: boolean = false, startWifi: boolean = true, sdCard: string = DEFAULT_SD, connectOnly: boolean = false): Promise<LumixImportResult> {
    const trace: string[] = [];
    const diagnosticFlow = ++LumixImportPrototype.diagnosticFlowSequence;
    const diagnosticStartedAt = Date.now();
    let diagnosticPhase: LumixPhase = 'ble';
    let bleConnected = false;
    let wifiConnected = false;
    let sessionEstablished = false;
    // ACTION_MODE starts the camera AP before the HTTP/gallery leg. Keep the
    // GATT link alive from that point onward, even when a later read or HTTP
    // request fails; otherwise Panasonic can interpret the early disconnect as
    // the controlling app leaving Wi-Fi mode.
    let keepGattAlive = false;
    let connectedSsid = '';
    let gateway = '';
    const update = (phase: LumixPhase, message: string): void => {
      diagnosticPhase = phase;
      AppDiagnostics.event('VIVID_BLE', `FLOW_PHASE flow=${diagnosticFlow} phase=${phase} ble=${bleConnected ? 1 : 0} wifi=${wifiConnected ? 1 : 0} session=${sessionEstablished ? 1 : 0} elapsedMs=${Date.now() - diagnosticStartedAt}`);
      const state: LumixImportPhaseUpdate = {
        phase: phase,
        message: message,
        bleConnected: bleConnected,
        wifiConnected: wifiConnected,
        sessionEstablished: sessionEstablished,
        wifiSsid: connectedSsid,
        gateway: gateway,
      };
      if (onPhase) onPhase(state);
    };
    try {
      LumixImportPrototype.runInProgress = true;
      // Keep the pairing-session GATT for the following Wi‑Fi button (and for
      // the background prewarm). Closing it between the two UI steps makes
      // some Panasonic bodies stay on their “waiting for Wi‑Fi/application”
      // screen even though the phone joined the AP. Harmony can silently tear
      // that link down while the camera changes into Wi-Fi transfer mode, so
      // keep the reference only as an optimistic fast path; the service
      // discovery below validates it before any active transfer command is
      // sent. A retained link that belongs to a different body than the
      // explicitly selected camera is released instead of reused.
      let reusableGatt = LumixImportPrototype.activeGatt;
      if (reusableGatt && preferredDeviceId.length > 0 &&
        LumixImportPrototype.activeGattDeviceId.length > 0 &&
        LumixImportPrototype.activeGattDeviceId !== preferredDeviceId) {
        trace.push(`GATT retained link is another camera retained=${LumixImportPrototype.shortId(LumixImportPrototype.activeGattDeviceId)} selected=${LumixImportPrototype.shortId(preferredDeviceId)}; reconnecting fresh`);
        reusableGatt = null;
      }
      if (!reusableGatt && LumixImportPrototype.prewarmInFlight !== null) {
        // A background prewarm (or its teardown) may still be running. Wait
        // for it so this click never opens a second concurrent GATT client
        // to the same body.
        trace.push('GATT prewarm in flight; awaiting before BLE scan');
        const prewarm = LumixImportPrototype.prewarmInFlight;
        try { await prewarm; } catch (_error) { }
        reusableGatt = LumixImportPrototype.activeGatt;
        if (reusableGatt && preferredDeviceId.length > 0 &&
          LumixImportPrototype.activeGattDeviceId.length > 0 &&
          LumixImportPrototype.activeGattDeviceId !== preferredDeviceId) {
          reusableGatt = null;
        }
      }
      if (LumixImportPrototype.lutRegistrationInFlight !== null) {
        // A LUT BLE registration may still be committing the LUT identity and
        // walking the camera through its ACTION_MODE reset. Wait for it so
        // run() does not interleave a second registration on the same body.
        trace.push('LUT BLE registration in flight; awaiting before BLE scan');
        const lutRegistration = LumixImportPrototype.lutRegistrationInFlight;
        try { await lutRegistration; } catch (_error) { }
      }
      const reusableDeviceId = LumixImportPrototype.activeGattDeviceId.length > 0
        ? LumixImportPrototype.activeGattDeviceId : preferredDeviceId;
      if (!reusableGatt) await LumixImportPrototype.closeActiveGatt();
      if (reusableGatt && LumixImportPrototype.activeGattNotificationHandler) {
        try { reusableGatt.off('BLECharacteristicChange', LumixImportPrototype.activeGattNotificationHandler); } catch (_error) { }
        LumixImportPrototype.activeGattNotificationHandler = null;
      }
      const clientUuid = await LumixImportPrototype.getClientUuid(context);
      trace.push(`clientUuid persisted len=${clientUuid.length}`);
      update('ble', reusableGatt ? '正在继续已注册的相机 BLE 会话…' : '正在扫描相机 BLE 广播…');
      let deviceId = reusableGatt ? reusableDeviceId : await LumixImportPrototype.scanBle(trace, preferredDeviceId, true);
      if (!reusableGatt && deviceId.length === 0) {
        update('failed', '未发现 LUMIX BLE 广播；请确认相机已配对并打开蓝牙');
        return LumixImportPrototype.result(trace, 'BLE 扫描', '未发现 LUMIX BLE 广播；请确认相机已配对并打开蓝牙', clientUuid);
      }
      trace.push(`BLE device=${LumixImportPrototype.shortId(deviceId)}`);
      if (!reusableGatt && requestSystemPairing) {
        update('ble', '正在由 Pixelshop 发起相机应用级配对握手…');
        const pairing = await LumixImportPrototype.requestCameraPairing(deviceId);
        trace.push(`Pixelshop pairing request=app-level; OS bond=${pairing.bonded ? 'bonded' : 'not-bonded'} state=${pairing.state}`);
        update('ble', pairing.bonded
          ? '已有系统配对，正在连接相机应用 BLE…'
          : '相机不接受通用 PIN 配对，正在连接应用 BLE 通道…');
      }
      const paired = reusableGatt ? true : await LumixImportPrototype.ensurePaired(deviceId, trace);
      if (!paired) {
        // Some HarmonyOS builds refuse to complete the system bond for a
        // camera that exposes an LE GATT service. Keep the pairing evidence,
        // but test the protocol's actual requirement by attempting one GATT
        // connection without a completed OS bond. Encrypted characteristics
        // will still fail at the first protected operation if a bond is
        // genuinely required.
        trace.push('BLE pairing evidence=UNRESOLVED; attempting GATT without completed bond');
      }

      let gatt: ble.GattClientDevice;
      if (reusableGatt) {
        gatt = reusableGatt;
        bleConnected = true;
        trace.push('GATT session reuse=pairing-registration; no reconnect');
      } else try {
        gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
      } catch (connectError) {
        const connectionFailure = connectError instanceof Error ? connectError : new Error(String(connectError));
        // A LUMIX LE address can rotate between the page advertisement and the
        // button click. Keep the normal path direct, but recover once with a
        // fresh advertisement instead of making the user pair again.
        if (preferredDeviceId.length === 0) throw connectionFailure;
        trace.push('GATT preferred address failed; rescanning current LUMIX advertisement');
        const refreshedDeviceId = await LumixImportPrototype.scanBle(trace, '', true);
        if (refreshedDeviceId.length === 0 || refreshedDeviceId === deviceId) throw connectionFailure;
        deviceId = refreshedDeviceId;
        gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
      }
      bleConnected = true;
      update('ble', '蓝牙已连接，正在发现相机服务…');
      try {
        const mtu = await gatt.setBLEMtu(64);
        trace.push(`GATT MTU negotiated=${mtu}`);
      } catch (_error) {
        trace.push('GATT MTU negotiation=UNRESOLVED; using platform default');
      }
      let services: Array<ble.GattService>;
      try {
        services = await gatt.getServices();
      } catch (reuseError) {
        if (!reusableGatt) {
          throw new Error(`GATT service discovery failed (${LumixImportPrototype.errorCode(reuseError)})`);
        }
        // The cached client is stale (the common 2900099 failure seen after
        // pairing). Reconnect a fresh client and repeat registration before
        // ACTION_MODE. This is still the non-S5 active request route; it does
        // not send anything to the camera push receiver used by original S5.
        trace.push(`GATT retained session stale; reconnecting fresh client code=${LumixImportPrototype.errorCode(reuseError)}`);
        try { await LumixImportPrototype.closeActiveGatt(); } catch (_error) { }
        reusableGatt = null;
        let freshDeviceId = deviceId;
        try {
          gatt = await LumixImportPrototype.connectGatt(freshDeviceId, trace);
        } catch (_connectError) {
          freshDeviceId = await LumixImportPrototype.scanBle(trace, '', true);
          if (freshDeviceId.length === 0) throw new Error('LUMIX BLE 广播已离开，无法重建传输通道');
          gatt = await LumixImportPrototype.connectGatt(freshDeviceId, trace);
        }
        deviceId = freshDeviceId;
        bleConnected = true;
        trace.push('GATT fresh session connected; active gallery request will continue');
        services = await gatt.getServices();
      }
      for (const service of services) {
        trace.push(`service ${service.serviceUuid}`);
        for (const characteristic of service.characteristics) {
          trace.push(`characteristic ${characteristic.characteristicUuid}`);
          for (const descriptor of characteristic.descriptors || []) trace.push(`descriptor ${descriptor.descriptorUuid}`);
        }
      }
      const chars = LumixImportPrototype.indexCharacteristics(services);
      if (!chars.actionMode || !chars.initialInform || !chars.wifiSsid || !chars.wifiPassword) {
        update('failed', '相机缺少 LUMIX 配网特征，未继续发送数据');
        return LumixImportPrototype.result(trace, 'GATT 服务发现', '相机缺少 LUMIX 配网特征，未继续发送数据', clientUuid, deviceId, '', 0, '', 0, 0, bleConnected);
      }
      trace.push(`GATT service=${BLE_SERVICE}; required=INITIAL_INFORM,WIFI_SSID,WIFI_PASSWORD,ACTION_MODE`);

      const notificationHandler = (changed: ble.BLECharacteristic): void => {
        const bytes = new Uint8Array(changed.characteristicValue);
        const uuid = changed.characteristicUuid.toLowerCase();
        const evidence = uuid === UUID_AP_STATE || uuid === UUID_ACTION_MODE_RESULT ? 'raw=' + LumixImportPrototype.safeHex(bytes) : 'value=redacted';
        AppDiagnostics.event('VIVID_BLE', `notify ${uuid} len=${bytes.length} ${evidence}`);
        trace.push(`notify ${changed.characteristicUuid} len=${bytes.length} ${evidence}`);
        if (uuid === UUID_AP_STATE || uuid === UUID_ACTION_MODE_RESULT) {
          hilog.info(0x0001, 'VIVID_BLE', 'LUMIX notify uuid=%{public}s len=%{public}d raw=%{public}s', changed.characteristicUuid, bytes.length, LumixImportPrototype.safeHex(bytes));
        }
      };
      gatt.on('BLECharacteristicChange', notificationHandler);
      try {
        await LumixImportPrototype.enableNotification(gatt, chars.actionModeResult, trace);
        await LumixImportPrototype.enableNotification(gatt, chars.apState, trace);

        const initialInform = await LumixImportPrototype.readGatt(gatt, chars.initialInform, trace);
        trace.push(`INITIAL_INFORM len=${initialInform.byteLength} evidence=key_for_password_decoder`);

        // Registration is required when a new GATT session is opened. If the
        // user has just completed the pairing button, reuse that same link
        // and go directly to the transfer command; repeating the registration
        // writes can reset the camera's Wi-Fi transition state.
        if (!reusableGatt) {
          if (chars.appUuid) await LumixImportPrototype.writeGatt(gatt, chars.appUuid, LumixImportPrototype.xorReverseWithInitial(
            initialInform,
            LumixImportPrototype.encodeProtocolString(LumixImportPrototype.uuidBytes(clientUuid)),
          ), trace);
          if (chars.appInfo) await LumixImportPrototype.writeGatt(gatt, chars.appInfo, LumixImportPrototype.paddedUtf8(APP_INFO_VALUE, 32), trace);
          if (chars.friendlyName) await LumixImportPrototype.writeGatt(gatt, chars.friendlyName, LumixImportPrototype.xorReverseWithInitial(
            initialInform,
            LumixImportPrototype.encodeProtocolString(util.TextEncoder.create('utf-8').encode(FRIENDLY_NAME_VALUE)),
          ), trace);
          if (chars.pairingInit) {
            try {
              await LumixImportPrototype.writeGatt(gatt, chars.pairingInit, new Uint8Array([0x02]), trace);
              trace.push('Pixelshop app-level pairing registration=complete');
            } catch (pairingError) {
              const pairingCode = LumixImportPrototype.errorCode(pairingError);
              trace.push(`Pixelshop app-level pairing registration rejected code=${pairingCode}`);
              // A camera that has already registered this client can reject a
              // duplicate 36f99090 write while still accepting the active
              // transfer command. The pairing-button route remains strict;
              // only the active non-S5 gallery route may continue.
              if (!startWifi) throw new Error(`app-level pairing registration failed (${pairingCode})`);
              trace.push('active gallery route continuing after already-registered pairing response');
            }
          } else {
            trace.push(`Pixelshop app-level pairing registration=UNRESOLVED missing=${UUID_PAIRING_INIT}`);
          }
        } else {
          trace.push('Pixelshop app-level pairing registration=reused');
        }

        if (!startWifi) {
          // Preserve this exact GATT registration for the subsequent transfer
          // button. The camera may reject ACTION_MODE on a newly opened link
          // immediately after pairing, while the same link is accepted.
          // Retain only a fully registered link. A half-initialized client
          // must not be reused by the next Wi-Fi button press.
          keepGattAlive = chars.pairingInit !== undefined;
          const message = chars.pairingInit
            ? '相机应用级配对已完成，请点击“图片传输（Wi‑Fi）”启动相机 Wi‑Fi'
            : '已发送相机应用级配对信息，但初始化特征未确认';
          update('complete', message);
          LumixImportPrototype.emitTrace(trace);
          return {
            ok: chars.pairingInit !== undefined,
            phase: 'BLE 配对',
            message: message,
            deviceId: deviceId,
            clientUuid: clientUuid,
            imageId: '',
            imageType: 0,
            thumbnailUri: '',
            httpStatus: 0,
            businessResponseCode: 0,
            trace: trace,
            bleConnected: true,
            wifiConnected: false,
            sessionEstablished: false,
            wifiSsid: '',
            gateway: '',
          };
        }

        const passwordRaw = await LumixImportPrototype.readGatt(gatt, chars.wifiPassword, trace);
        const password = LumixImportPrototype.decodeWifiPassword(initialInform, passwordRaw);
        const wifiSsid = LumixImportPrototype.decodeGatt(await LumixImportPrototype.readGatt(gatt, chars.wifiSsid, trace));
        trace.push(`Wi-Fi credentials decoded ssidLen=${wifiSsid.length} passwordLen=${password.length}`);
        const fingerprint = chars.certFingerprint ? LumixImportPrototype.normalizeFingerprint(
          await LumixImportPrototype.readGatt(gatt, chars.certFingerprint, trace)) : '';
        // Slot inventory, read here so it is known before any gallery leg runs.
        // current-sd only accepts slot names the body actually has, and a
        // single-slot body (S9) reports just `SSD` — sending `SD1` to it is
        // rejected and blanks the entire gallery. Best-effort on purpose: a body
        // that does not expose the characteristic must still connect, and
        // fetchGallery/run fall back to an SSD retry.
        try {
          if (chars.sdSlotInfo) {
            const slotRaw = LumixImportPrototype.decodeGatt(
              await LumixImportPrototype.readGatt(gatt, chars.sdSlotInfo, trace));
            const slots = LumixImportPrototype.parseSlotInfo(slotRaw);
            LumixImportPrototype.slotInfo = {
              ok: slots.length > 0,
              slots: slots,
              raw: slotRaw,
              message: slots.length > 0 ? '' : '未读到相机槽位清单',
            };
            let slotNames = '';
            for (const slot of slots) {
              slotNames = slotNames.length === 0 ? slot.name : `${slotNames}/${slot.name}`;
            }
            trace.push(`SLOT_INFO slots=${slots.length} names=${slotNames}`);
            AppDiagnostics.event('VIVID_BLE', `SLOT_INFO slots=${slots.length} names=${slotNames}`);
            // AppDiagnostics 会按已知键裁剪消息体，SLOT_INFO 这种自定义文本活不
            // 下来（2026-10-17 真机日志里只剩 stage=gatt）。原文必须走
            // AppLogStore，那里是逐字落盘的。
            let slotCodes = '';
            for (let index = 0; index < slotRaw.length && index < 64; index++) {
              slotCodes = slotCodes.length === 0 ? `${slotRaw.charCodeAt(index)}`
                : `${slotCodes},${slotRaw.charCodeAt(index)}`;
            }
            AppLogStore.add(`BLE 槽位原文 len=${slotRaw.length} text=[${slotRaw}] codes=${slotCodes}`);
          } else {
            trace.push('SLOT_INFO characteristic missing; current-sd will fall back to SSD');
            AppDiagnostics.event('VIVID_BLE', 'SLOT_INFO characteristic missing');
          }
        } catch (slotError) {
          trace.push(`SLOT_INFO read error code=${LumixImportPrototype.errorCode(slotError)}; current-sd will fall back to SSD`);
          AppDiagnostics.event('VIVID_BLE', `SLOT_INFO read error code=${LumixImportPrototype.errorCode(slotError)}`);
        }
        // SERVER_URL is a write-side characteristic in the captured LUMIX
        // flow. Harmony reports an error when it is treated as readable, and
        // that used to abort the sequence before ACTION_MODE was sent.
        if (chars.serverUrl) trace.push('SERVER_URL discovered; read skipped (write-side characteristic)');
        if (wifiSsid.length === 0 || password.length === 0) {
          update('failed', 'BLE 已连接，但未解析出 Wi‑Fi 凭据');
          return LumixImportPrototype.result(trace, 'BLE 读取 Wi‑Fi', 'BLE 已连接，但未解析出 Wi‑Fi 凭据', clientUuid, deviceId, '', 0, '', 0, 0, bleConnected);
        }
        if (fingerprint.length === 0) {
          update('failed', '未读到 CER_FINGER_PRINT；为避免未固定 TLS，停止认证');
          return LumixImportPrototype.result(trace, '证书指纹', '未读到 CER_FINGER_PRINT；为避免未固定 TLS，停止认证', clientUuid, deviceId, '', 0, '', 0, 0, bleConnected);
        }
        try {
          await LumixImportPrototype.rememberCameraFingerprint(context, fingerprint);
        } catch (_error) {
        }

        // Ordinary phone gallery entry in the Android app defaults to ACTION_MODE 0x01.
        // The write is one byte and uses Harmony's no-response equivalent.
        // Skip it when the phone is already associated with THIS body's AP: a
        // repeated ACTION_MODE resets the camera's Wi-Fi state (observed
        // AP_STATE raw=03 -> raw=01 on a retry) and turns a live transfer
        // session into a persistent 403 loop.
        let linkedSsidNow = '';
        try {
          const linkedNow = await wifiManager.getLinkedInfo();
          linkedSsidNow = (linkedNow.ssid || '').replace(/^"|"$/g, '').trim();
        } catch (_error) { }
        const targetApSsid = wifiSsid.replace(/^"|"$/g, '').trim();
        if (linkedSsidNow.length > 0 && linkedSsidNow === targetApSsid) {
          trace.push('ACTION_MODE skipped; phone already linked to this camera SSID relation=CONFIRMED');
        } else {
          await LumixImportPrototype.writeGatt(gatt, chars.actionMode, new Uint8Array([0x01]), trace);
          trace.push('ACTION_MODE=0x01');
        }
        // The captured LUMIX Lab flow writes only ACTION_MODE on this path.
        // The previously added IMAGE_TRANSFER_ACTION write is not part of the
        // verified protocol: the real characteristic table has no such UUID,
        // and while that write is present the S5M2 pops its connection-failed
        // screen and answers the gallery requests with a persistent 403. Keep
        // the write out; the characteristic stays discovered so the trace can
        // still report whether the body exposes it.
        if (chars.imageTransferAction) {
          trace.push('IMAGE_TRANSFER_ACTION discovered; write skipped (not in verified protocol)');
        }
        keepGattAlive = true;
        connectedSsid = wifiSsid;
        update('wifi', `相机 Wi‑Fi 已开启，正在请求系统连接 ${wifiSsid}…`);
        const wifi = await LumixImportPrototype.connectWifi(wifiSsid, password, trace);
        connectedSsid = wifi.ssid;
        gateway = wifi.gateway;
        wifiConnected = wifi.connected;
        if (!wifi.connected) {
          update('failed', '系统未连接相机 Wi‑Fi；请在系统 Wi‑Fi 设置中选择相机热点后重试');
          return LumixImportPrototype.result(trace, '相机 Wi‑Fi', '系统未连接相机 Wi‑Fi；请在系统 Wi‑Fi 设置中选择相机热点后重试', clientUuid, deviceId, '', 0, '', 0, 0, bleConnected, false, false, connectedSsid, gateway);
        }

        const host = LumixImportPrototype.selectHost(hostOverride, gateway, trace);
        if (host.length === 0) {
          update('failed', '未取得相机网络网关，未发起 HTTPS 请求');
          return LumixImportPrototype.result(trace, '相机网络', '未取得相机网络网关，未发起 HTTPS 请求', clientUuid, deviceId, '', 0, '', 0, 0, bleConnected, wifiConnected, false, connectedSsid, gateway);
        }
        update('session', `Wi‑Fi 已连接（${connectedSsid}），正在校验证书并认证会话…`);
        const authBody = JSON.stringify({
          AppInfo: `Pixelshop Studio ${APP_ID}/${APP_VERSION}`,
          FriendlyName: FRIENDLY_NAME_VALUE,
          Uuid: clientUuid,
        });
         const auth = await LumixImportPrototype.postJson(host, '/auth', authBody, '', fingerprint, trace);
          const token = LumixImportPrototype.requireBusinessSuccess(auth, '认证', trace);
         if (token.length === 0) {
          update('failed', '认证未通过：请检查 HTTP 状态及 Header.ResponseCode');
           return LumixImportPrototype.result(trace, '认证', '认证未通过：请检查 HTTP 状态及 Header.ResponseCode', clientUuid, deviceId, '', 0, '', auth.httpStatus, LumixImportPrototype.businessCode(auth.body), bleConnected, wifiConnected, false, connectedSsid, gateway);
         }
         // Retain the authenticated session as soon as /auth succeeds. The
         // gallery request can fail independently (for example a transient
         // 403 while the camera changes transfer state), and the transfer
         // page must be able to retry without repeating authentication.
          LumixImportPrototype.sessionHost = host;
          LumixImportPrototype.sessionToken = token;
          LumixImportPrototype.sessionFingerprint = fingerprint;
          // Connect-only callers (LUT transfer / camera control entry) only
          // need the Wi-Fi session: the first mode transition leaves the
          // camera's HTTP business layer briefly rejecting gallery reads
          // (403/401), and both LUT and control pages run their own session
          // legs anyway. Skip current-sd/count/info/thumbnails entirely.
          if (connectOnly) {
            sessionEstablished = true;
            update('complete', '相机 Wi‑Fi 会话已建立');
            LumixImportPrototype.emitTrace(trace);
            return { ok: true, phase: '完成', message: '相机 Wi‑Fi 会话已建立', deviceId: deviceId, clientUuid: clientUuid, imageId: '', imageType: 0, thumbnailUri: '', httpStatus: 200, businessResponseCode: 200, trace: trace, bleConnected: bleConnected, wifiConnected: wifiConnected, sessionEstablished: sessionEstablished, wifiSsid: connectedSsid, gateway: gateway, galleryItems: [], galleryTotal: 0 };
          }

         let currentSd = LumixImportPrototype.resolveCurrentSd(sdCard);
         if (currentSd !== sdCard) {
           trace.push(`current-sd resolved ${sdCard}->${currentSd} from camera slot inventory`);
         }
         let current = await LumixImportPrototype.postJson(host, '/media/gallery/current-sd', JSON.stringify({ CurrentSd: currentSd }), token, fingerprint, trace);
         if (!LumixImportPrototype.checkBusinessCode(current, 'current-sd', trace)
           && currentSd.toUpperCase() !== 'SSD') {
           // Official forgiveness for the single-slot sentinel — see the same
           // note in fetchGallery. Without it a single-slot body (S9) fails here
           // and the whole gallery never loads.
           trace.push('current-sd rejected; retrying once with the single-slot sentinel SSD');
           currentSd = 'SSD';
           current = await LumixImportPrototype.postJson(host, '/media/gallery/current-sd', JSON.stringify({ CurrentSd: currentSd }), token, fingerprint, trace);
         }
        if (!LumixImportPrototype.checkBusinessCode(current, 'current-sd', trace)) {
          update('failed', '相机会话已认证，但 current-sd 被拒绝');
          return LumixImportPrototype.result(trace, 'current-sd', '相机会话已认证，但 current-sd 被拒绝', clientUuid, deviceId, '', 0, '', current.httpStatus, LumixImportPrototype.businessCode(current.body), bleConnected, wifiConnected, false, connectedSsid, gateway);
        }
        // LUMIX Lab's unfiltered count declaration has no @Body. Preserve that
        // wire shape: do not send an invented `{}` payload. The camera answers
        // 411 when the body is omitted entirely, and a zero-length ArrayBuffer
        // makes Harmony's stack throw, so postJson passes an empty string body
        // which the stack frames with Content-Length: 0.
        let galleryTotal = 0;
        let countAccepted = false;
        let count: JsonResponse | null = null;
        try {
          count = await LumixImportPrototype.postJson(host, '/media/gallery/count', '', token, fingerprint, trace);
          if (LumixImportPrototype.checkBusinessCode(count, 'gallery/count', trace)) {
            galleryTotal = LumixImportPrototype.galleryCount(count.body);
            countAccepted = true;
            trace.push(`gallery/count parsed total=${galleryTotal}`);
          } else {
            // A few S5M2 firmware revisions require a different empty-body
            // framing and answer 411/400 here.  The gallery/info endpoint is
            // independently readable, so do not abort the whole transfer and
            // do not send another BLE command; read the first six entries.
            trace.push(`gallery/count rejected http=${count.httpStatus}; continue gallery/info startIndex=0`);
          }
        } catch (countError) {
          trace.push(`gallery/count exception code=${LumixImportPrototype.errorCode(countError)}; continue gallery/info startIndex=0`);
        }
        // 空卡（count 200 且 Count=0）：gallery/info 必答业务 403（索引越界），
        // 不再按瞬态重试；会话按成功收尾并返回空图库，由 UI 提示切换另一张卡。
        const cardIsEmpty = countAccepted && galleryTotal === 0;
        const emptyCardReturn = (): LumixImportResult => {
          sessionEstablished = true;
          LumixImportPrototype.sessionHost = host;
          LumixImportPrototype.sessionToken = token;
          LumixImportPrototype.sessionFingerprint = fingerprint;
          LumixImportPrototype.sessionGalleryTotal = 0;
          update('complete', `${sdCard} 上没有照片（0 张）`);
          LumixImportPrototype.emitTrace(trace);
          return { ok: true, phase: '完成', message: `${sdCard} 上没有照片（0 张），可切换另一张存储卡后重试`, deviceId: deviceId, clientUuid: clientUuid, imageId: '', imageType: 0, thumbnailUri: '', httpStatus: 200, businessResponseCode: 200, trace: trace, bleConnected: bleConnected, wifiConnected: wifiConnected, sessionEstablished: sessionEstablished, wifiSsid: connectedSsid, gateway: gateway, galleryItems: [], galleryTotal: 0 };
        };
        // Field-level capture of the real LUMIX Lab client on S5M2
        // (2026-09-13, analysis/lumixlab-fields-capture-20260913.md) confirmed
        // the gallery page body {"StartIndex":19,"Limit":50,"Rating":null}:
        // the Rating key is always present with a null value and the page size
        // is 50. Vivid's earlier requests omitted Rating and were answered with
        // a persistent business 403 for both Limit=1 and Limit=50, so replicate
        // the captured body exactly and ask for the newest tail page.
        const requestedLimit = 50;
        const firstStartIndex = galleryTotal > requestedLimit ? galleryTotal - requestedLimit : 0;
        trace.push(`gallery/info start=${firstStartIndex} limit=${requestedLimit} rating=null total=${galleryTotal}`);
        let images: GalleryImage[] = [];
        let infoHttpStatus = 0;
        let infoBusinessCode = 0;
        let infoRejected = false;
        let info = await LumixImportPrototype.postJson(host, '/media/gallery/info', JSON.stringify({ StartIndex: firstStartIndex, Limit: requestedLimit, Rating: null }), token, fingerprint, trace);
        infoHttpStatus = info.httpStatus;
        infoBusinessCode = LumixImportPrototype.businessCode(info.body);
        let accepted = LumixImportPrototype.checkBusinessCode(info, 'gallery/info', trace);
        // Right after ACTION_MODE the body can still be switching into its
        // transfer state and answer a transient 403 on the first request.
        // Retry briefly instead of failing the transfer (空卡除外：空图库的
        // 403 是确定性业务码，重试无意义）。
        const maxInfoAttempt = cardIsEmpty ? 1 : 4;
        for (let infoAttempt = 2; !accepted && infoAttempt <= maxInfoAttempt; infoAttempt++) {
          trace.push(`gallery/info transient retry attempt=${infoAttempt}`);
          update('session', `相机会话已认证，正在重新请求图库（${infoAttempt}/4）…`);
          await LumixImportPrototype.delay(1500);
          info = await LumixImportPrototype.postJson(host, '/media/gallery/info', JSON.stringify({ StartIndex: firstStartIndex, Limit: requestedLimit, Rating: null }), token, fingerprint, trace);
          infoHttpStatus = info.httpStatus;
          infoBusinessCode = LumixImportPrototype.businessCode(info.body);
          accepted = LumixImportPrototype.checkBusinessCode(info, 'gallery/info', trace);
        }
        if (accepted) {
          images = LumixImportPrototype.findImages(info.body);
          LumixImportPrototype.probeGalleryInfo(info.body);
          LumixImportPrototype.probeGalleryItems('fullflow parsed', images);
          // 同上：galleryTotal 是记录数，不能用来截断条目数组，否则 RAW 条目
          // 会被砍掉。
        } else {
          infoRejected = true;
        }
        if (infoRejected) {
          if (cardIsEmpty) return emptyCardReturn();
          update('failed', '相机会话已认证，但 gallery/info 被拒绝');
          return LumixImportPrototype.result(trace, 'gallery/info', '相机会话已认证，但 gallery/info 被拒绝', clientUuid, deviceId, '', 0, '', infoHttpStatus, infoBusinessCode, bleConnected, wifiConnected, false, connectedSsid, gateway);
        }
        if (images.length === 0) {
          if (cardIsEmpty) return emptyCardReturn();
          update('failed', '图库响应没有可下载的 ImageId');
          return LumixImportPrototype.result(trace, 'gallery/info', '图库响应没有可下载的 ImageId', clientUuid, deviceId, '', 0, '', infoHttpStatus, infoBusinessCode, bleConnected, wifiConnected, false, connectedSsid, gateway);
        }
        // The captured page is the newest tail of the gallery; keep only the
        // newest FIRST_PAGE_LIMIT records (each with its RAW companion entry)
        // for the prototype transfer page.
        images = LumixImportPrototype.takeNewestRecords(images, FIRST_PAGE_LIMIT);
        LumixImportPrototype.probeGalleryItems('fullflow window', images);
         LumixImportPrototype.sessionHost = host;
         LumixImportPrototype.sessionToken = token;
         LumixImportPrototype.sessionFingerprint = fingerprint;
         const galleryItems: LumixGalleryItem[] = [];
          for (let index = 0; index < images.length; index++) {
           const image = images[index];
           const imageId = image.ImageId || '';
           const imageType = Number(image.Type);
           if (imageId.length === 0 || !Number.isFinite(imageType)) continue;
            const thumb = await LumixImportPrototype.postThumbnail(host, imageId, token, fingerprint, context, trace, firstStartIndex + index);
           if (thumb.length > 0) galleryItems.push({
             imageId: imageId,
             imageType: imageType,
             thumbnailUri: thumb,
             size: Number(image.Size) || 0,
             rawSize: Number(image.RawSize) || 0,
             originalFileName: image.OriginalFileName || '',
             orientation: Number(image.Orientation) || 0,
           });
         }
         if (galleryItems.length === 0) {
           update('failed', '缩略图 HTTP 传输失败或返回空数据');
           return LumixImportPrototype.result(trace, 'gallery/thumbnail', '缩略图 HTTP 传输失败或返回空数据', clientUuid, deviceId, '', 0, '', 0, 0, bleConnected, wifiConnected, false, connectedSsid, gateway);
         }
          // Keep the newest item first in the transfer page. The API response
          // itself is ordinal ascending within the requested tail page.
          galleryItems.reverse();
          const imageId = galleryItems[0].imageId;
          LumixImportPrototype.probeMediaTypes(host, token, fingerprint, imageId).catch(() => { });
         const imageType = galleryItems[0].imageType;
         const thumb = galleryItems[0].thumbnailUri;
         sessionEstablished = true;
         LumixImportPrototype.sessionGalleryTotal = galleryTotal;
         update('complete', `已完成证书校验、认证并读取 ${galleryItems.length} 张缩略图`);
         LumixImportPrototype.emitTrace(trace);
         return { ok: true, phase: '完成', message: `已从相机下载 ${galleryItems.length} 张缩略图`, deviceId: deviceId, clientUuid: clientUuid, imageId: imageId, imageType: imageType, thumbnailUri: thumb, httpStatus: 200, businessResponseCode: 200, trace: trace, bleConnected: bleConnected, wifiConnected: wifiConnected, sessionEstablished: sessionEstablished, wifiSsid: connectedSsid, gateway: gateway, galleryItems: galleryItems, galleryTotal: galleryTotal };
      } finally {
        LumixImportPrototype.runInProgress = false;
        if (sessionEstablished || keepGattAlive) {
          // The camera keeps its application session tied to this GATT link.
          // Leave both the link and notification subscription open until the
          // user removes the connection; removing CCCD here can make the AP
          // leave Wi-Fi mode on Panasonic bodies. This also applies when the
          // subsequent HTTP/gallery step failed after ACTION_MODE succeeded.
          LumixImportPrototype.activeGatt = gatt;
          LumixImportPrototype.activeGattNotificationHandler = notificationHandler;
          LumixImportPrototype.activeGattDeviceId = deviceId;
          trace.push(sessionEstablished
            ? 'GATT retained after successful gallery session'
            : 'GATT retained after ACTION_MODE while gallery/session is pending');
          hilog.info(0xA00001, 'VIVID_BLE', sessionEstablished
            ? 'GATT retained after successful gallery session'
            : 'GATT retained after ACTION_MODE while gallery/session is pending');
        } else {
          // A reused link can fail before ACTION_MODE (for example after an
          // address rotation). Clear the static reference before closing it,
          // otherwise the next click would reuse a closed GATT client.
          if (reusableGatt) {
            LumixImportPrototype.activeGatt = null;
            LumixImportPrototype.activeGattNotificationHandler = null;
            LumixImportPrototype.activeGattDeviceId = '';
          }
          try { gatt.off('BLECharacteristicChange', notificationHandler); } catch (_error) { }
          try { gatt.disconnect(); } catch (_error) { }
          try { gatt.close(); } catch (_error) { }
        }
      }
    } catch (error) {
      AppDiagnostics.event('VIVID_BLE', `FLOW_ERR flow=${diagnosticFlow} phase=${diagnosticPhase} elapsedMs=${Date.now() - diagnosticStartedAt}`);
      update('failed', '流程异常，请在「我的 → 问题反馈」发送日志');
      LumixImportPrototype.logError('flow exception', error);
      trace.push(`flow exception phase=${trace.length > 0 ? trace[trace.length - 1] : 'unknown'}`);
      LumixImportPrototype.emitTrace(trace);
      return LumixImportPrototype.result(trace, '异常', '流程异常，请在「我的 → 问题反馈」发送日志', '', '', '', 0, '', 0, 0, bleConnected, wifiConnected, sessionEstablished, connectedSsid, gateway);
    }
  }

  /**
   * Nikon's BLE leg is intentionally separate from the Panasonic flow.  The
   * public NikonLink implementation connects directly with TRANSPORT_LE and
   * discovers the GATT service without opening Android's generic PIN dialog.
   * We follow that safe, observable part here: connect, discover the service
   * tree and subscribe to the status characteristic when it is present.  The
   * proprietary pairing command and PTP/IP activation packet are not guessed
   * from a name or UUID; they remain explicitly pending a Nikon capture.
   */
  static async runNikon(context: common.UIAbilityContext, onPhase?: (update: LumixImportPhaseUpdate) => void, preferredDeviceId: string = ''): Promise<LumixImportResult> {
    const trace: string[] = [];
    let bleConnected = false;
    let retained = false;
    const update = (phase: LumixPhase, message: string): void => {
      if (onPhase) onPhase({ phase: phase, message: message, bleConnected: bleConnected, wifiConnected: false, sessionEstablished: false, wifiSsid: '', gateway: '' });
    };
    try {
      await LumixImportPrototype.closeActiveGatt();
      const clientUuid = await LumixImportPrototype.getClientUuid(context);
      update('ble', '正在扫描尼康 BLE 广播…');
      let deviceId = await LumixImportPrototype.scanBle(trace, preferredDeviceId);
      if (deviceId.length === 0) {
        update('failed', '未发现尼康 BLE 广播；请打开相机蓝牙并保持在配对窗口');
        return LumixImportPrototype.result(trace, 'Nikon BLE 扫描', '未发现尼康 BLE 广播；请打开相机蓝牙并保持在配对窗口', clientUuid);
      }
      trace.push(`Nikon BLE device=${LumixImportPrototype.shortId(deviceId)}; OS PIN pairing=skipped`);
      let gatt: ble.GattClientDevice;
      try {
        gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
      } catch (connectError) {
        const connectionFailure = connectError instanceof Error ? connectError : new Error(String(connectError));
        if (preferredDeviceId.length === 0) throw connectionFailure;
        trace.push('Nikon preferred BLE address failed; rescanning current advertisement');
        const refreshed = await LumixImportPrototype.scanBle(trace, '');
        if (refreshed.length === 0) throw connectionFailure;
        deviceId = refreshed;
        gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
      }
      bleConnected = true;
      update('ble', '尼康 BLE 已连接，正在发现服务…');
      try {
        try { trace.push(`Nikon GATT MTU negotiated=${await gatt.setBLEMtu(64)}`); } catch (_error) { trace.push('Nikon GATT MTU=platform default'); }
        const services = await gatt.getServices();
        let snapBridgeFound = false;
        let statusCharacteristic: ble.BLECharacteristic | undefined;
        for (const service of services) {
          const serviceUuid = service.serviceUuid.toLowerCase();
          trace.push(`Nikon service ${service.serviceUuid}`);
          if (serviceUuid === NikonCameraService.SNAPBRIDGE_SERVICE.toLowerCase()) snapBridgeFound = true;
          for (const characteristic of service.characteristics) {
            trace.push(`Nikon characteristic ${characteristic.characteristicUuid}`);
            if (serviceUuid === NikonCameraService.SNAPBRIDGE_SERVICE.toLowerCase() &&
              characteristic.characteristicUuid.toLowerCase() === NikonCameraService.STATUS_CHARACTERISTIC.toLowerCase()) {
              statusCharacteristic = characteristic;
            }
            for (const descriptor of characteristic.descriptors || []) trace.push(`Nikon descriptor ${descriptor.descriptorUuid}`);
          }
        }
        const notificationHandler = (changed: ble.BLECharacteristic): void => {
          const bytes = new Uint8Array(changed.characteristicValue);
          trace.push(`Nikon notify uuid=${changed.characteristicUuid} len=${bytes.length} raw=${LumixImportPrototype.safeHex(bytes)}`);
        };
        gatt.on('BLECharacteristicChange', notificationHandler);
        if (statusCharacteristic) await LumixImportPrototype.enableNotification(gatt, statusCharacteristic, trace);
        retained = snapBridgeFound;
        const message = snapBridgeFound
          ? '尼康 BLE 已连接并发现 SnapBridge 服务；PTP/IP 激活指令等待真机协议确认'
          : '尼康 BLE 已连接，但未发现 SnapBridge 服务；未发送猜测指令';
        trace.push(`Nikon pairing evidence=${snapBridgeFound ? 'GATT_SERVICE_DISCOVERED' : 'SERVICE_UNRESOLVED'}`);
        update(snapBridgeFound ? 'complete' : 'failed', message);
        return {
          ok: snapBridgeFound,
          phase: 'Nikon BLE',
          message: message,
          deviceId: deviceId,
          clientUuid: clientUuid,
          imageId: '',
          imageType: 0,
          thumbnailUri: '',
          httpStatus: 0,
          businessResponseCode: 0,
          trace: trace,
          bleConnected: true,
          wifiConnected: false,
          sessionEstablished: false,
          wifiSsid: '',
          gateway: '',
        };
      } finally {
        if (retained) {
          LumixImportPrototype.activeGatt = gatt;
          trace.push('Nikon GATT retained after service discovery');
        } else {
          try { gatt.disconnect(); } catch (_error) { }
          try { gatt.close(); } catch (_error) { }
        }
      }
    } catch (error) {
      LumixImportPrototype.logError('Nikon BLE flow exception', error);
      update('failed', '尼康 BLE 握手异常，请查看本地脱敏 HiLog');
      return LumixImportPrototype.result(trace, 'Nikon BLE 异常', '尼康 BLE 握手异常，请查看本地脱敏 HiLog', '', '', '', 0, '', 0, 0, bleConnected);
    }
  }

  private static async getClientUuid(context: common.UIAbilityContext): Promise<string> {
    if (LumixImportPrototype.storedUuid.length > 0) return LumixImportPrototype.storedUuid;
    const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
    LumixImportPrototype.store = store;
    const saved = await store.get('clientUuid', '');
    if (typeof saved === 'string' && saved.length > 0) {
      LumixImportPrototype.storedUuid = saved;
      return saved;
    }
    const bytes = new Uint8Array(16);
    for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = Array.from(bytes).map((value: number) => value.toString(16).padStart(2, '0'));
    const uuid = `${hex.slice(0, 4).join('')}-${hex.slice(4, 6).join('')}-${hex.slice(6, 8).join('')}-${hex.slice(8, 10).join('')}-${hex.slice(10, 16).join('')}`;
    await LumixImportPrototype.store.put('clientUuid', uuid);
    await LumixImportPrototype.store.flush();
    LumixImportPrototype.storedUuid = uuid;
    return uuid;
  }

  /** Return Vivid's own persisted client identifier for non-BLE adapters. */
  static async persistentClientUuid(context: common.UIAbilityContext): Promise<string> {
    return LumixImportPrototype.getClientUuid(context);
  }

  static async rememberCameraFingerprint(context: common.UIAbilityContext, fingerprint: string): Promise<void> {
    if (fingerprint.length === 0) return;
    const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
    await store.put('cameraCertFingerprint', fingerprint);
    await store.flush();
  }

  static async rememberedCameraFingerprint(context: common.UIAbilityContext): Promise<string> {
    const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
    const saved = await store.get('cameraCertFingerprint', '');
    return typeof saved === 'string' ? saved : '';
  }

  /**
   * Stable DMS identifier used by the original Panasonic S5 push workflow.
   * LUMIX Sync keeps a 12-hex seed and prefixes it with the Media Equipment
   * Identifier UUID namespace. Keep this key separate from the BLE/REST UUID
   * used by the other camera families.
   */
  static async persistentS5DmsUuid(context: common.UIAbilityContext): Promise<string> {
    const store = await preferences.getPreferences(context, 'vivid_lumix_protocol');
    const saved = await store.get('s5DmsUuid', '');
    if (typeof saved === 'string' && /^4D454930-0100-1000-8001-[0-9A-Fa-f]{12}$/.test(saved)) {
      return saved.toUpperCase();
    }
    const bytes = new Uint8Array(6);
    for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
    const suffix = Array.from(bytes).map((value: number) => value.toString(16).padStart(2, '0')).join('').toUpperCase();
    const uuid = `4D454930-0100-1000-8001-${suffix}`;
    await store.put('s5DmsUuid', uuid);
    await store.flush();
    return uuid;
  }

  private static async scanBle(trace: string[], preferredDeviceId: string = '', panasonicOnly: boolean = false): Promise<string> {
    if (preferredDeviceId.length > 0) {
      trace.push(`BLE using established camera address=${LumixImportPrototype.shortId(preferredDeviceId)}; discovery skipped`);
      return preferredDeviceId;
    }
    // A LUMIX LE address can rotate between the page listener and the
    // connection attempt, so re-scan after the button click. Bodies that are
    // already advertising answer within the first one or two scan callbacks:
    // exit as soon as a connectable candidate is seen instead of holding the
    // click inside a fixed 10s window, which removes most of the observed
    // click-to-Wi-Fi delay. The original S5 is served by the dedicated
    // passive Wi-Fi push route, so its advertisements are never selected
    // here; a non-connectable advertisement is only a last-resort fallback.
    let found = '';
    let fallback = '';
    let s5SkippedLogged = false;
    const callback = (results: Array<ble.ScanResult>): void => {
      for (const result of results) {
        const candidate = LumixImportPrototype.cameraCandidate(result);
        if (!candidate || !result.deviceId) continue;
        if (candidate.imageKey === 'panasonic_s5') {
          if (!s5SkippedLogged) {
            s5SkippedLogged = true;
            trace.push(`BLE skipped original-S5 advertisement name=${candidate.deviceName}`);
          }
          continue;
        }
        if (panasonicOnly && (candidate.brand || 'Panasonic') !== 'Panasonic') continue;
        if (!candidate.connectable) {
          if (fallback.length === 0) fallback = result.deviceId;
          continue;
        }
        if (found.length === 0) {
          found = result.deviceId;
          trace.push(`BLE camera name=${candidate.deviceName} model=${candidate.model} connectable=yes rssi=${candidate.rssi}`);
        }
      }
    };
    ble.on('BLEDeviceFind', callback);
    const scanStartedAt = Date.now();
    try {
      ble.startBLEScan(null, {
        interval: 0,
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
      });
      trace.push(`BLE scan filter=none; early exit on first connectable camera panasonicOnly=${panasonicOnly ? 'yes' : 'no'}`);
      while (found.length === 0 && Date.now() - scanStartedAt < 10000) {
        await LumixImportPrototype.delay(200);
      }
    } finally {
      try { ble.stopBLEScan(); } catch (_error) { }
      ble.off('BLEDeviceFind', callback);
    }
    const selected = found.length > 0 ? found : fallback;
    if (selected.length > 0 && found.length === 0) {
      trace.push(`BLE using non-connectable fallback advertisement=${LumixImportPrototype.shortId(selected)}`);
    }
    return selected;
  }

  private static cameraCandidate(result: ble.ScanResult): LumixBleCameraCandidate | undefined {
    // Identity comes from the advertisement, never from the local name: the
    // name is user-editable, so keying on it hides the body the moment the
    // owner renames the camera. The official app keys on the manufacturer-data
    // Bluetooth address and reads the model from the name's trailing code
    // byte; both survive a rename.
    const advertised = LumixImportPrototype.parseLumixAdvertisement(result.data);
    LumixImportPrototype.logAdvertisement(result.deviceId, advertised);
    const protocolIdentity = advertised.btAddress.length > 0
      ? LumixImportPrototype.panasonicIdentityFromModelCode(advertised.modelCode) : undefined;
    if (protocolIdentity) {
      return {
        deviceId: result.deviceId,
        deviceName: advertised.displayName.length > 0 ? advertised.displayName : advertised.rawName,
        model: protocolIdentity.model,
        imageKey: protocolIdentity.imageKey,
        brand: protocolIdentity.brand,
        btAddress: advertised.btAddress,
        rssi: result.rssi,
        connectable: result.connectable !== false,
      };
    }
    // Sony bodies carry no LUMIX manufacturer data. Their own payload proves
    // "this is a Sony camera" independently of the local name, so a renamed body
    // is still admitted; the model then comes from the name table below, and a
    // body whose name is unknown falls back to the generic Sony card.
    const sonyAdvertised = SonyCameraService.parseSonyAdvertisement(result.data);
    if (sonyAdvertised.isSonyCamera) {
      const sonyName = advertised.displayName.length > 0 ? advertised.displayName : advertised.rawName;
      const sonyIdentity = sonyName.length > 0 ? SonyCameraService.identifyBluetoothName(sonyName) : null;
      return {
        deviceId: result.deviceId,
        deviceName: sonyName.length > 0 ? sonyName : 'SONY',
        model: sonyIdentity ? sonyIdentity.model : 'SONY',
        // A Sony body whose exact model is unknown still needs a renderable
        // card. 'sony' has no media asset, so fall back to the generic Alpha
        // image rather than a key that resolves to nothing.
        imageKey: sonyIdentity ? sonyIdentity.imageKey : 'sony_a7m4',
        brand: 'Sony',
        rssi: result.rssi,
        connectable: result.connectable !== false,
      };
    }
    // Some API 26 devices leave ScanResult.deviceName empty (or expose a
    // generic cached name), while the camera's model identifier is still in
    // the BLE advertising payload. Try every available name and only accept a
    // complete Panasonic/Nikon identity; never infer a model from an address.
    // This stays as the fallback for bodies that advertise no LUMIX
    // manufacturer data: Nikon, and older Panasonic bodies.
    const names: string[] = [];
    const addName = (value: string): void => {
      const cleaned = value.replace(/[\u0000-\u001F\u007F]/g, '').trim();
      if (cleaned.length === 0 || names.indexOf(cleaned) >= 0) return;
      names.push(cleaned);
    };
    addName(result.deviceName || '');
    addName(advertised.displayName);
    addName(LumixImportPrototype.advertisedLocalName(result.data));
    if (result.deviceId.length > 0) {
      try { addName(connection.getRemoteDeviceName(result.deviceId)); } catch (_error) { }
    }
    let bestName = '';
    let bestIdentity: LumixCameraIdentity | undefined = undefined;
    let bestScore = -1;
    for (const name of names) {
      const identity = LumixImportPrototype.cameraIdentity(name);
      if (!identity) continue;
      // Harmony can expose a cached generic name (for example "LUMIX S5")
      // alongside the complete local name from the current advertisement
      // ("S5M2-xxxx"). Prefer the most specific model token so an S5M2 body
      // cannot be routed into the original S5 Wi-Fi-only receiver branch.
      const upper = name.toUpperCase();
      let score = name.length;
      if (upper.indexOf('S5M2X') >= 0) score += 10000;
      else if (upper.indexOf('S5M2') >= 0) score += 9000;
      else if (upper.indexOf('S1RM2') >= 0 || upper.indexOf('S1RII') >= 0) score += 8000;
      else if (upper.indexOf('S1M2E') >= 0 || upper.indexOf('S1IIE') >= 0) score += 7900;
      else if (upper.indexOf('S1M2') >= 0 || upper.indexOf('S1II') >= 0) score += 7800;
      else if (upper.indexOf('S1R') >= 0 || upper.indexOf('S1H') >= 0 || upper.indexOf('S9') >= 0) score += 7000;
      else if (upper.indexOf('GH7') >= 0) score += 6900;
      else if (upper.indexOf('G9M2') >= 0 || upper.indexOf('G9II') >= 0) score += 6800;
      else if (upper.indexOf('G100D') >= 0) score += 6700;
      else if (upper.indexOf('GH5S') >= 0 || upper.indexOf('GH5') >= 0 ||
        upper.indexOf('GH6') >= 0 || upper.indexOf('G9') >= 0) score += 6600;
      if (score > bestScore) {
        bestScore = score;
        bestName = name;
        bestIdentity = identity;
      }
    }
    if (!bestIdentity || bestName.length === 0) {
      // Family layer: the advertisement proves this is a LUMIX camera (the
      // shared scan service or Panasonic's manufacturer data), but no model
      // token could be resolved. Keep a generic card so the body is visible;
      // the model arrives later from a name or the Wi-Fi SSID.
      const hasLumixMarker = advertised.hasLumixService || advertised.btAddress.length > 0;
      if (!hasLumixMarker) return undefined;
      const fallbackName = advertised.displayName.length > 0
        ? advertised.displayName
        : (advertised.rawName.length > 0 ? advertised.rawName : 'LUMIX');
      const generic: LumixBleCameraCandidate = {
        deviceId: result.deviceId,
        deviceName: fallbackName,
        model: '',
        imageKey: '',
        brand: 'Panasonic',
        rssi: result.rssi,
        connectable: result.connectable !== false,
      };
      if (advertised.btAddress.length > 0) generic.btAddress = advertised.btAddress;
      return generic;
    }
    const candidate: LumixBleCameraCandidate = {
      deviceId: result.deviceId,
      deviceName: bestName,
      model: bestIdentity.model,
      imageKey: bestIdentity.imageKey,
      brand: bestIdentity.brand,
      rssi: result.rssi,
      connectable: result.connectable !== false,
    };
    // A body that advertises the address but an unrecognised model code still
    // receives the stable key, so renaming cannot split its card in two.
    if (advertised.btAddress.length > 0) candidate.btAddress = advertised.btAddress;
    return candidate;
  }

  /** Render a BLE local name for diagnostics: strip control characters and
   * cap the length so a malformed payload cannot flood the log. */
  private static safeScanName(value: string): string {
    const cleaned = value.replace(/[\u0000-\u001F\u007F]/g, '').trim();
    if (cleaned.length === 0) return '-';
    return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
  }

  /** Log each distinct advertisement identity once. This is the on-device
   * evidence for the one thing the APK cannot tell us: which model-code byte
   * a LUMIX Sync generation body advertises (if any). A code outside 1..9
   * means the body keeps the name-based fallback and its route is unchanged. */
  private static logAdvertisement(deviceId: string, advertised: LumixAdvertisement): void {
    // Only advertisements carrying at least one LUMIX protocol field, so
    // unrelated nearby Bluetooth devices never reach this log.
    if (advertised.btAddress.length === 0 && advertised.modelCode === 0 && !advertised.hasLumixService) {
      return;
    }
    const key = `${deviceId}|${advertised.btAddress}|${advertised.modelCode}`;
    if (LumixImportPrototype.loggedAdvertisementKeys.has(key)) return;
    LumixImportPrototype.loggedAdvertisementKeys.add(key);
    LumixImportPrototype.runtimeInfo(
      `adv id=${LumixImportPrototype.shortId(deviceId)} bt=${advertised.btAddress || '-'} ` +
      `code=${advertised.modelCode} lumixSvc=${advertised.hasLumixService ? 1 : 0} ` +
      `display=${advertised.displayName || '-'} rawLen=${advertised.rawName.length}`);
  }

  /** Parse the raw AD structures once and return every LUMIX protocol field.
   * The local name is kept byte-exact here: its trailing 0x0A + model code are
   * control bytes that a display-oriented sanitizer would strip, and those two
   * bytes are the only model evidence a renamed body still advertises. */
  private static parseLumixAdvertisement(data: ArrayBuffer): LumixAdvertisement {
    const parsed: LumixAdvertisement = {
      displayName: '', rawName: '', modelCode: 0, btAddress: '', hasLumixService: false,
    };
    if (!data || data.byteLength < 3) return parsed;
    const bytes = new Uint8Array(data);
    let offset = 0;
    while (offset < bytes.length) {
      const fieldLength = bytes[offset];
      if (fieldLength === 0) break;
      const fieldEnd = offset + 1 + fieldLength;
      if (fieldEnd > bytes.length || fieldLength < 1) break;
      const fieldType = bytes[offset + 1];
      const valueStart = offset + 2;
      // 0x08 = shortened local name, 0x09 = complete local name.
      if ((fieldType === 0x08 || fieldType === 0x09) && parsed.rawName.length === 0) {
        let raw = '';
        for (let index = valueStart; index < fieldEnd; index++) {
          const value = bytes[index];
          if (value === 0) break;
          raw += String.fromCharCode(value);
        }
        parsed.rawName = raw;
        const nameLength = raw.length;
        if (nameLength > 1 && raw.charCodeAt(nameLength - 2) === BLE_NAME_MODEL_MARKER) {
          const code = raw.charCodeAt(nameLength - 1);
          if (code >= 1 && code <= PANASONIC_MODEL_CODE_TOKENS.length - 1) {
            parsed.modelCode = code;
            parsed.displayName = raw.substring(0, nameLength - 2);
          }
        }
        if (parsed.displayName.length === 0) {
          parsed.displayName = raw.replace(/[\u0000-\u001F\u007F]/g, '').trim();
        }
      } else if (fieldType === 0xff) {
        // Manufacturer-specific data: a 2-byte company identifier (little
        // endian) followed by the payload. The official app accepts only
        // company 58 with exactly six payload bytes.
        if (fieldLength - 3 === BLE_MANUFACTURER_DATA_LENGTH &&
          (bytes[valueStart] | (bytes[valueStart + 1] << 8)) === BLE_MANUFACTURER_ID_LUMIX) {
          let address = '';
          for (let index = 0; index < BLE_MANUFACTURER_ADDRESS_LENGTH; index++) {
            const value = bytes[valueStart + 2 + BLE_MANUFACTURER_ADDRESS_OFFSET + index];
            address += (value < 16 ? '0' : '') + value.toString(16).toUpperCase();
          }
          parsed.btAddress = address;
        }
      } else if ((fieldType === 0x06 || fieldType === 0x07) && !parsed.hasLumixService &&
        fieldLength - 1 === 16) {
        // 128-bit service class UUIDs are little-endian on the wire.
        let uuid = '';
        for (let index = 15; index >= 0; index--) {
          const value = bytes[valueStart + index];
          uuid += (value < 16 ? '0' : '') + value.toString(16);
        }
        if (uuid === BLE_SCAN_SERVICE.replace(/-/g, '')) parsed.hasLumixService = true;
      }
      offset = fieldEnd;
    }
    return parsed;
  }

  /** Map the advertisement's trailing model-code byte to a body identity.
   * Reusing panasonicCameraIdentity keeps one imageKey vocabulary instead of a
   * second hand-maintained table. */
  private static panasonicIdentityFromModelCode(code: number): LumixCameraIdentity | undefined {
    const token = code >= 1 && code < PANASONIC_MODEL_CODE_TOKENS.length
      ? PANASONIC_MODEL_CODE_TOKENS[code] : '';
    if (token.length === 0) return undefined;
    return LumixImportPrototype.panasonicCameraIdentity(`${token}-000000`);
  }

  /** Extract the complete/short local name from a raw BLE AD payload. */
  private static advertisedLocalName(data: ArrayBuffer): string {
    if (!data || data.byteLength < 3) return '';
    const bytes = new Uint8Array(data);
    let offset = 0;
    while (offset < bytes.length) {
      const fieldLength = bytes[offset];
      if (fieldLength === 0) break;
      const fieldEnd = offset + 1 + fieldLength;
      if (fieldEnd > bytes.length || fieldLength < 1) break;
      const fieldType = bytes[offset + 1];
      // 0x08 = shortened local name, 0x09 = complete local name.
      if (fieldType === 0x08 || fieldType === 0x09) {
        let name = '';
        for (let index = offset + 2; index < fieldEnd; index++) {
          const value = bytes[index];
          if (value === 0) break;
          // A local name is ASCII for LUMIX/Nikon advertisements. Reject a
          // binary field instead of turning arbitrary bytes into a model name.
          if (value < 0x20 || value > 0x7e) {
            name = '';
            break;
          }
          name += String.fromCharCode(value);
        }
        if (name.length > 0) return name;
      }
      offset = fieldEnd;
    }
    return '';
  }

  private static cameraIdentity(name: string): LumixCameraIdentity | undefined {
    const panasonic = LumixImportPrototype.panasonicCameraIdentity(name);
    if (panasonic) return panasonic;
    const nikon = NikonCameraService.identifyBluetoothName(name);
    if (nikon) return {
      brand: nikon.brand,
      model: nikon.model,
      imageKey: nikon.imageKey,
    };
    // Sony is appended last so the Panasonic and Nikon orders above are
    // untouched. Sony bodies advertise their model token (ILCE-7M4, ZV-E1, ...)
    // as the local name, which never collides with a LUMIX or Nikon prefix.
    const sony = SonyCameraService.identifyBluetoothName(name);
    if (sony) return {
      brand: sony.brand,
      model: sony.model,
      imageKey: sony.imageKey,
    };
    return undefined;
  }

  /** Panasonic matching is kept in its own function so adding another brand
   * cannot change the existing LUMIX recognition order or aliases. */
  private static panasonicCameraIdentity(name: string): LumixCameraIdentity | undefined {
    // Panasonic advertisements are model-prefixed identifiers.  Match the
    // whole name (directly or with one known vendor prefix) and require the
    // model/instance separator.  A substring such as xxxxS9_xxxx must never
    // become a camera candidate.
    const upper = name.toUpperCase().trim();
    const matches = (token: string): boolean => {
      const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const suffix = '[-_][A-Z0-9]{3,}(?:[-_][A-Z0-9]+)*';
      return new RegExp(`^${escaped}${suffix}$`).test(upper) ||
        new RegExp(`^(?:LUMIX|PANASONIC|PANA|DC|DMC|CAMERA)[-_ ]+${escaped}${suffix}$`).test(upper);
    };
    if (matches('S5M2X')) {
      return { brand: 'Panasonic', model: 'LUMIX S5M2X', imageKey: 'panasonic_s5m2x' };
    }
    if (matches('S5M2')) {
      return { brand: 'Panasonic', model: 'LUMIX S5M2', imageKey: 'panasonic_s5m2' };
    }
    if (matches('S5')) {
      return { brand: 'Panasonic', model: 'LUMIX S5', imageKey: 'panasonic_s5' };
    }
    if (matches('S1M2E') || matches('S1IIE')) return { brand: 'Panasonic', model: 'LUMIX S1M2E', imageKey: 'panasonic_s1iie' };
    if (matches('S1RM2') || matches('S1RII')) return { brand: 'Panasonic', model: 'LUMIX S1RM2', imageKey: 'panasonic_s1rii' };
    if (matches('S1M2') || matches('S1II')) return { brand: 'Panasonic', model: 'LUMIX S1M2', imageKey: 'panasonic_s1ii' };
    if (matches('S1R')) return { brand: 'Panasonic', model: 'LUMIX S1R', imageKey: 'panasonic_s1rii' };
    if (matches('S1H')) return { brand: 'Panasonic', model: 'LUMIX S1H', imageKey: 'panasonic_s1ii' };
    if (matches('S9')) return { brand: 'Panasonic', model: 'LUMIX S9', imageKey: 'panasonic_s9' };
    if (matches('GH7')) return { brand: 'Panasonic', model: 'LUMIX GH7', imageKey: 'panasonic_gh7' };
    if (matches('G9M2') || matches('G9II')) return { brand: 'Panasonic', model: 'LUMIX G9M2', imageKey: 'panasonic_g9m2' };
    if (matches('G100D')) return { brand: 'Panasonic', model: 'LUMIX G100D', imageKey: 'panasonic_g100d' };
    if (matches('GH6')) return { brand: 'Panasonic', model: 'LUMIX GH6', imageKey: 'panasonic_gh6' };
    if (matches('GH5S')) return { brand: 'Panasonic', model: 'LUMIX GH5S', imageKey: 'panasonic_gh5s' };
    if (matches('GH5')) return { brand: 'Panasonic', model: 'LUMIX GH5', imageKey: 'panasonic_gh5' };
    if (matches('G9')) return { brand: 'Panasonic', model: 'LUMIX G9', imageKey: 'panasonic_g9' };
    // Official model code 9. This used to fall back to the generic waiting icon
    // because no DC-L10 product shot existed; a dedicated image is now shipped as
    // panasonic_l10, matching LumixCameraService.imageKeyForModel and
    // identifyWifiSsid so the BLE path, the Wi-Fi path and the card chain agree.
    if (matches('L10')) return { brand: 'Panasonic', model: 'LUMIX L10', imageKey: 'panasonic_l10' };
    return undefined;
  }

  private static async ensurePaired(deviceId: string, trace: string[]): Promise<boolean> {
    try {
      const state = connection.getPairState(deviceId);
      trace.push(`BLE pair state=${String(state)}`);
      if (state === connection.BondState.BOND_STATE_BONDED) return true;
      // Panasonic's documented LUMIX flow performs application-level BLE
      // registration. Calling the generic OS pairDevice() here opens a PIN
      // dialog that the camera does not accept, so leave the OS bond alone
      // and let GATT/security decide whether a bond is actually required.
      trace.push(`BLE pair state=${String(state)}; OS PIN pairing skipped; using app-level GATT probe`);
      return false;
    } catch (error) {
      LumixImportPrototype.logError('pairing', error);
      trace.push('BLE pairing state unavailable; continuing with GATT fallback');
      return false;
    }
  }

  static async connectGatt(deviceId: string, trace: string[]): Promise<ble.GattClientDevice> {
    let lastError: Error | undefined;
    let gatt = ble.createGattClientDevice(deviceId);
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        await LumixImportPrototype.connectGattOnce(gatt, deviceId, trace, attempt);
        return gatt;
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(String(error));
        trace.push(`GATT retry=${attempt}/2`);
        try { gatt.disconnect(); } catch (_error) { }
        try { gatt.close(); } catch (_error) { }
        await LumixImportPrototype.delay(350);
        if (attempt < 2) gatt = ble.createGattClientDevice(deviceId);
      }
    }
    throw lastError || new Error('GATT connection failed');
  }

  private static async connectGattOnce(gatt: ble.GattClientDevice, deviceId: string, trace: string[], attempt: number): Promise<void> {
    await new Promise<void>((resolve: () => void, reject: (reason?: Object) => void) => {
      let finished = false;
      let timer: number = -1;
      const state = (change: ble.BLEConnectionChangeState): void => {
        trace.push(`GATT attempt=${attempt} state=${change.state} device=${LumixImportPrototype.shortId(change.deviceId)}`);
        // HarmonyOS may report the RPA-resolved address in the callback while
        // the scan returned the public device id. This GATT client has only
        // one outstanding connection, so state is sufficient to match it.
        if (finished) return;
        if (change.state === constant.ProfileConnectionState.STATE_CONNECTED) {
          finished = true;
          if (timer >= 0) clearTimeout(timer);
          gatt.off('BLEConnectionStateChange', state);
          resolve();
        } else if (change.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
          finished = true;
          if (timer >= 0) clearTimeout(timer);
          gatt.off('BLEConnectionStateChange', state);
          reject(new Error('GATT disconnected before connection completed'));
        }
      };
      gatt.on('BLEConnectionStateChange', state);
      gatt.connect();
      timer = setTimeout(() => {
        if (finished) return;
        finished = true;
        gatt.off('BLEConnectionStateChange', state);
        reject(new Error('GATT connection timeout'));
      }, 10000);
    });
  }

  private static indexCharacteristics(services: Array<ble.GattService>): GattCharacteristicSet {
    const result: GattCharacteristicSet = {};
    for (const service of services) {
      if (service.serviceUuid.toLowerCase() !== BLE_SERVICE.toLowerCase()) continue;
      for (const characteristic of service.characteristics) {
        const uuid = characteristic.characteristicUuid.toLowerCase();
        if (uuid === UUID_APP_UUID) result.appUuid = characteristic;
        else if (uuid === UUID_APP_INFO) result.appInfo = characteristic;
        else if (uuid === UUID_FRIENDLY_NAME) result.friendlyName = characteristic;
        else if (uuid === UUID_PAIRING_INIT) result.pairingInit = characteristic;
        else if (uuid === UUID_WIFI_PASSWORD) result.wifiPassword = characteristic;
        else if (uuid === UUID_INITIAL_INFORM) result.initialInform = characteristic;
         else if (uuid === UUID_WIFI_SSID) result.wifiSsid = characteristic;
         else if (uuid === UUID_ACTION_MODE) result.actionMode = characteristic;
         else if (uuid === UUID_IMAGE_TRANSFER_ACTION) result.imageTransferAction = characteristic;
         else if (uuid === UUID_AP_STATE) result.apState = characteristic;
        else if (uuid === UUID_ACTION_MODE_RESULT) result.actionModeResult = characteristic;
        else if (uuid === UUID_CERT_FINGERPRINT) result.certFingerprint = characteristic;
        else if (uuid === UUID_SERVER_URL) result.serverUrl = characteristic;
        else if (uuid === UUID_CAMERA_MODEL_NAME) result.cameraModelName = characteristic;
        else if (uuid === UUID_CAMERA_FM_VERSION) result.cameraFirmwareVersion = characteristic;
        else if (uuid === UUID_LENS_NAME) result.lensName = characteristic;
        else if (uuid === UUID_LENS_FM_VERSION) result.lensFirmwareVersion = characteristic;
        else if (uuid === UUID_SD_SLOT_INFO) result.sdSlotInfo = characteristic;
      }
    }
    return result;
  }

  static asCharacteristic(characteristic: ble.BLECharacteristic | undefined): ble.BLECharacteristic {
    if (!characteristic) throw new Error('GATT characteristic is missing');
    return {
      serviceUuid: characteristic.serviceUuid,
      characteristicUuid: characteristic.characteristicUuid,
      characteristicValue: new ArrayBuffer(0),
      descriptors: characteristic.descriptors || [],
      properties: characteristic.properties,
    };
  }

  static async enableNotification(gatt: ble.GattClientDevice, characteristic: ble.BLECharacteristic | undefined, trace: string[]): Promise<void> {
    if (!characteristic) return;
    const item = LumixImportPrototype.asCharacteristic(characteristic);
    await gatt.setCharacteristicChangeNotification(item, true);
    trace.push(`notify enabled ${item.characteristicUuid}; CCCD=${CCCD_UUID}; descriptor write=platform-managed`);
  }

  static async readGatt(gatt: ble.GattClientDevice, characteristic: ble.BLECharacteristic | undefined, trace: string[]): Promise<ArrayBuffer> {
    const item = LumixImportPrototype.asCharacteristic(characteristic);
    const result = await gatt.readCharacteristicValue(item);
    const copied = new Uint8Array(result.characteristicValue);
    trace.push(`read ${item.characteristicUuid} len=${copied.length} value=${LumixImportPrototype.redactGattValue(item.characteristicUuid, copied)}`);
    return copied.slice().buffer;
  }

  /** `readGatt` with retries.
   *
   *  尼康配网读 `0x2004`（Wi-Fi 凭据）时，真机上出现过单次读取失败：认证三个阶段
   *  全部成功、BTC 配对码都拿到了，紧接着这次读被平台拒掉（`Inner error.`
   *  `code 2900007`，约 10 秒后抛），整轮配网就此中断。
   *
   *  单次 GATT 读失败在 BLE 上很常见——相机上一轮连接还没完全释放、协议栈一时忙，
   *  都会这样。这类失败重试一次多半就过去了，而代价只是几百毫秒；不重试的代价是
   *  用户必须重新走一遍扫描、连接、认证。
   *
   *  重试之间有间隔：立刻重发往往撞在同一个瞬时状态上，等于白试。 */
  static async readGattRetry(gatt: ble.GattClientDevice, characteristic: ble.BLECharacteristic | undefined,
    trace: string[], attempts: number = 3): Promise<ArrayBuffer> {
    let lastError: Object | null = null;
    for (let attempt = 1; attempt <= attempts; attempt++) {
      try {
        return await LumixImportPrototype.readGatt(gatt, characteristic, trace);
      } catch (error) {
        lastError = error as Object;
        trace.push(`read-retry attempt=${attempt}/${attempts} code=${LumixImportPrototype.errorCode(error)}`);
        if (attempt < attempts) {
          await new Promise<void>((resolve: () => void): void => {
            setTimeout((): void => {
              resolve();
            }, 400 * attempt);
          });
        }
      }
    }
    throw new Error(`GATT 读取失败（重试 ${attempts} 次）：${String(lastError)}`);
  }

  static async writeGatt(gatt: ble.GattClientDevice, characteristic: ble.BLECharacteristic | undefined, bytes: Uint8Array, trace: string[]): Promise<void> {
    const item = LumixImportPrototype.asCharacteristic(characteristic);
    item.characteristicValue = bytes.buffer as ArrayBuffer;
    // Android's WRITE_TYPE_DEFAULT (what the official apps use, they never
    // call setWriteType) maps to WRITE whenever the characteristic supports
    // write-with-response, regardless of a simultaneous writeNoResponse bit.
    const writeType = item.properties && item.properties.write === true
      ? ble.GattWriteType.WRITE : ble.GattWriteType.WRITE_NO_RESPONSE;
    const typeLabel = writeType === ble.GattWriteType.WRITE ? 'WRITE' : 'WRITE_NO_RESPONSE';
    trace.push(`write-before ${item.characteristicUuid} type=${typeLabel} len=${bytes.length} value=${LumixImportPrototype.redactGattValue(item.characteristicUuid, bytes)}`);
    try {
      await gatt.writeCharacteristicValue(item, writeType);
      trace.push(`write-result ${item.characteristicUuid} type=${typeLabel} status=success len=${bytes.length}`);
      if (item.characteristicUuid.toLowerCase() === UUID_ACTION_MODE) {
        hilog.info(0x0001, 'VIVID_BLE', 'ACTION_MODE write type=%{public}s value=%{public}s', typeLabel, LumixImportPrototype.safeHex(bytes));
      }
    } catch (error) {
      trace.push(`write-result ${item.characteristicUuid} type=${typeLabel} status=error code=${LumixImportPrototype.errorCode(error)}`);
      throw new Error('GATT characteristic write failed');
    }
  }

  private static decodeGatt(value: ArrayBuffer): string {
    try { return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(value)).replace(/\0/g, '').trim(); } catch (_error) { return ''; }
  }

  /** Exact decoder observed in C5/I2.e + C5/g.1: reverse each 4-byte block,
   * XOR with INITIAL_INFORM, then use the first decoded byte as the length. */
  private static decodeWifiPassword(initialInform: ArrayBuffer, encrypted: ArrayBuffer): string {
    const key = new Uint8Array(initialInform);
    const input = new Uint8Array(encrypted);
    if (key.length < 4 || input.length === 0) return '';
    const output = new Uint8Array(input.length + (input.length % 4));
    const groups = Math.floor(input.length / 4);
    for (let group = 0; group < groups; group++) {
      const source = group * 4;
      const target = source;
      // C5/g.1 reverses each four-byte block and applies the key in reverse
      // order: output[0] uses key[3], output[1] uses key[2], etc. The earlier
      // implementation used key[0..3] in forward order, producing a plausible
      // length but an invalid WPA password.
      output[target] = input[source + 3] ^ key[3];
      output[target + 1] = input[source + 2] ^ key[2];
      output[target + 2] = input[source + 1] ^ key[1];
      output[target + 3] = input[source] ^ key[0];
    }
    const declaredLength = output[0];
    if (declaredLength <= 0 || declaredLength > output.length - 1) return '';
    try {
      return util.TextDecoder.create('utf-8').decodeToString(output.slice(1, declaredLength + 1)).trim();
    } catch (_error) {
      return '';
    }
  }

  private static normalizeFingerprint(value: ArrayBuffer): string {
    const decoded = LumixImportPrototype.decodeGatt(value).replace(/:/g, '').replace(/\s/g, '');
    let bytes: Uint8Array;
    if (/^[0-9a-f]{64}$/i.test(decoded)) {
      bytes = new Uint8Array(32);
      for (let index = 0; index < bytes.length; index++) {
        bytes[index] = parseInt(decoded.substring(index * 2, index * 2 + 2), 16);
      }
    } else {
      bytes = new Uint8Array(value);
      if (bytes.length !== 32) return '';
    }
    // Android compares the raw 32-byte SHA-256 digest. Harmony's dynamic
    // certificatePinning API takes the same digest encoded as standard Base64.
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  /**
   * The camera's pairing-wait screen starts counting down the moment the user
   * puts the body into pairing mode, so radio warm-up on the join path eats
   * its budget. Kick the Wi-Fi enable + first scan cycles off in parallel
   * with the BLE handshake; connectWifi's scan loop then sees a warm result
   * list instead of waiting for the radio to come up.
   */
  static async warmWifiRadio(): Promise<void> {
    try {
      if (!wifiManager.isWifiActive()) {
        await wifiManager.enableWifi();
      }
      await LumixImportPrototype.waitForWifiScan(true);
      await LumixImportPrototype.waitForWifiScan(true);
    } catch (_error) { }
  }

  // networkId of the most recent camera-AP candidate config added by
  // connectWifi. Exposed so the Sync line can drop the candidate when the
  // user disconnects: a third-party app cannot force a STA disconnect, but
  // removing the candidate stops the system from re-joining the camera AP
  // after the camera shuts its hotspot down.
  static lastCameraCandidateNetworkId: number = -1;

  /** Remove the camera-AP candidate config added by the last connectWifi. */
  static async removeCameraCandidateConfig(): Promise<void> {
    const networkId = LumixImportPrototype.lastCameraCandidateNetworkId;
    LumixImportPrototype.lastCameraCandidateNetworkId = -1;
    if (networkId < 0) return;
    try {
      await wifiManager.removeCandidateConfig(networkId);
    } catch (_error) {
      // Already-gone configs (camera reset, system cleanup) are fine.
    }
  }

  /**
   * Bounded wait for the phone to actually leave the camera SoftAP. The
   * control-mode entry writes recycle the camera's SoftAP, but the
   * disassociation lands several seconds after the writes; a rejoin that
   * runs ahead of the drop short-circuits on the dying link and returns a
   * stale gateway (2026-09-27 19:52: rejoin skipped after 6 ms, every
   * refresh poll then hit a dead IP until the pairing failed). Returns true
   * once the link is gone (or was never up); false when still linked at
   * the timeout, which is legitimate when the camera did not recycle.
   */
  static async waitCameraLinkDrop(ssid: string, timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      let linkedSsid = '';
      try {
        const linked = await wifiManager.getLinkedInfo();
        linkedSsid = linked ? (linked.ssid || '') : '';
      } catch (_error) {
        return true;
      }
      const normalized = linkedSsid.replace(/^"|"$/g, '').trim();
      if (normalized.length === 0 || normalized !== ssid) return true;
      if (Date.now() >= deadline) return false;
      await LumixImportPrototype.delay(500);
    }
  }

  /** 安全类型对应的密钥：**开放网络必须留空**。
   *
   * 传 `securityType = WIFI_SEC_TYPE_OPEN` 的同时给非空 `preSharedKey`，系统会判为
   * 非法组合，`addCandidateConfig` 直接抛 `401`。实测尼康那条链路就撞在这里：
   * 相机热点是全部开放的，`0x2004` 里那 8 字节（`WNIKONZ5`）属于 PTP/IP 层的凭据，
   * 不是 Wi-Fi 密码，却被当成密码塞进了配置。 */
  private static keyForNetwork(securityType: number, password: string): string {
    if (securityType === wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN) {
      return '';
    }
    return password;
  }

  /** 等系统真正挂到 `ssid` 上，最多 30 秒。
   *
   * 隐藏热点（尼康相机起来时广播空 SSID）关联上以后不会再出现在扫描结果里，
   * 所以判据只能是 `getLinkedInfo()` 的当前链路，不能是扫描列表。 */
  private static async awaitWifiJoin(ssid: string, trace: string[]): Promise<WifiConnection> {
    const deadline = Date.now() + 30000;
    const target = ssid.trim();
    while (Date.now() < deadline) {
      try {
        const linked = await wifiManager.getLinkedInfo();
        if (linked && linked.ssid && linked.ssid.trim() === target) {
          let gateway = '';
          try {
            gateway = LumixImportPrototype.ipv4(linked.ipAddress);
          } catch (_error) {
            gateway = '';
          }
          trace.push(`Wi-Fi hidden join succeeded ssid=${linked.ssid} gateway=${gateway}`);
          return { connected: true, ssid: linked.ssid, gateway: gateway, ipAddress: gateway };
        }
      } catch (_error) {
        // Keep polling: the link is mid-handshake for a while.
      }
      await LumixImportPrototype.delay(1000);
    }
    trace.push(`Wi-Fi hidden join timed out after 30 s (ssid=${ssid})`);
    return { connected: false, ssid: '', gateway: '', ipAddress: '' };
  }

  static async connectWifi(ssid: string, password: string, trace: string[], joinAttempts: number = 1,
    onPrompt: (attempt: number) => void = (_attempt: number): void => {},
    scanWindowMs: number = 75000,
    skipScanWhenLinked: boolean = false,
    onStatus: (text: string) => void = (_text: string): void => {}): Promise<WifiConnection> {
    let actualSsid = '';
    let gateway = '';
    let ipAddress = '';
    try {
      // The camera AP is unreachable while the phone radio is off. Harmony
      // never auto-enables Wi-Fi for a scan or candidate connect, so turn it
      // on before polling the scan results.
      try {
        if (!wifiManager.isWifiActive()) await wifiManager.enableWifi();
      } catch (_error) { }
      const normalized = (value: string): string => value.replace(/^"|"$/g, '').trim();
      let match: wifiManager.WifiScanInfo | undefined = undefined;
      // The camera advertises its AP only after ACTION_MODE and may take a few
      // scan intervals to appear. The captured Android session tolerated this
      // startup window before DHCP completed, so keep polling for 30 seconds.
      // 2026-09-27 11:52 and 13:33: right after a camera reboot / registration
      // reset the SoftAP stays invisible to a full 30 s scan round (0
      // candidates while the camera sits on its Wi-Fi-wait screen), while a
      // retry two minutes later finds it in 28 s. Scan up to three rounds
      // (75 s) with cool-down pauses to also ride out Wi-Fi scan throttling.
      // Callers on the Sync line widen the window (150 s): a registered
      // camera woken from auto-sleep by BLE can show its occupancy screen
      // yet bring the SoftAP up only after a minute or more (2026-09-27
      // 16:51: dance done, 79 s of zero-beacon scan, camera recovered on
      // its own ~4 min later).
      // A scan issued on the interface that already carries the camera link
      // stalls that link's in-flight traffic: the discovery loop below fires a
      // startScan() every 2.5 s, and running that on top of a live PTP/IP
      // session cost the session its handshake - the transaction timed out,
      // the session was poisoned, the LiveViewUrl read then failed and live
      // view never started. The caller only reaches here to *obtain* a link,
      // so when the requested AP is already the live one there is nothing to
      // discover. Some builds also omit the associated AP from scan results
      // altogether, which leaves the loop below spinning its whole window
      // without ever matching. Opt-in so the Panasonic/Nikon/Sync lines keep
      // their existing discovery behaviour.
      if (skipScanWhenLinked) {
        try {
          const linkedNow = await wifiManager.getLinkedInfo();
          const linkedSsidNow = normalized(linkedNow.ssid || '');
          if (linkedSsidNow.length > 0 && linkedSsidNow === normalized(ssid)) {
            const ipNow = wifiManager.getIpInfo();
            const gatewayNow = LumixImportPrototype.ipv4(ipNow.gateway);
            if (gatewayNow.length > 0) {
              trace.push(`Wi-Fi already linked ssid=${linkedSsidNow} gateway=${gatewayNow}; scan skipped`);
              return {
                connected: true,
                ssid: linkedSsidNow,
                gateway: gatewayNow,
                ipAddress: LumixImportPrototype.ipv4(ipNow.ipAddress),
              };
            }
          }
        } catch (_error) {
          // An unreadable link just falls through to normal discovery.
        }
      }
      const scanStarted = Date.now();
      const scanDeadline = scanStarted + scanWindowMs;
      let nextScanAt = 0;
      let emptyScanRounds = 0;
      // **扫描阶段要报进度。**
      //
      // 尼康线实测：从弹窗显示"正在连接相机 Wi-Fi"到真的扫到热点，中间有 19 秒
      // 一个字都不变（23:25:13.800 → 23:25:32.305），用户看着就像卡死了。而这段
      // 时间不是 bug——相机拉起 SoftAP 本来就要十几秒，扫描窗口最长 75 秒。
      //
      // 所以这里每轮扫描都把"已等待多少秒"报出去，让人能看出是在正常推进而不是
      // 卡住。节流到 2 秒一次，避免高频刷新弹窗。
      let lastStatusAt = 0;
      while (!match && Date.now() < scanDeadline) {
        // Read existing results first: do not delay a known AP behind another scan.
        const scans = wifiManager.getScanInfoList();
        match = scans.find((item: wifiManager.WifiScanInfo) => normalized(item.ssid || '') === ssid);
        if (match) {
          trace.push(`Wi-Fi SSID relation=CONFIRMED ${ssid}`);
          onStatus(`已找到相机热点 ${ssid}，正在连接…`);
          break;
        }
        if (Date.now() - lastStatusAt >= 2000) {
          lastStatusAt = Date.now();
          const waited = Math.max(0, Math.round((Date.now() - scanStarted) / 1000));
          onStatus(`正在扫描相机热点…已等待 ${waited} 秒（相机拉起热点通常需要十几秒）`);
        }
        // The capture shows the BLE logical name and the visible AP SSID can
        // differ (S1RM2-F2B179 versus S1A0EAA4BD), but the expected SSID passed
        // into this method is the value the camera returned over the BLE
        // UUID_WIFI_SSID characteristic — that is the beacon SSID itself, not the
        // logical name, so an exact comparison is correct. The former "only one
        // S1*/S5*/S9* AP is visible" inference is deliberately removed: it
        // guessed identity from a Wi-Fi name prefix, which no official LUMIX
        // generation does, and it could bind the session to an unrelated
        // Panasonic body. Keep polling while the camera AP finishes starting
        // after ACTION_MODE.
        await LumixImportPrototype.waitForWifiScan(Date.now() >= nextScanAt);
        if (Date.now() >= nextScanAt) {
          nextScanAt = Date.now() + 2500;
          emptyScanRounds += 1;
          if (emptyScanRounds % 8 === 0) {
            // **把"到底扫到了什么"记下来。**
            //
            // 之前这里只报 `still empty after N scans`，而那个计数统计的是**轮次**、
            // 不是扫描结果——于是下面两种截然不同的情况在日志里长得一模一样，
            // 但修法完全相反：
            //   entries === 0            → 扫描本身没返回结果（系统节流 / 权限），
            //                              要修的是我们的调用方式
            //   entries > 0 但没有目标   → 热点确实不在空中，要修的是相机那一侧
            //
            // 实测就卡在这个歧义上：相机屏幕显示它正在起 Wi-Fi，我们却什么都看不到，
            // 无法判断该往哪边使劲。
            const seen = wifiManager.getScanInfoList();
            let seenNames = '';
            for (let seenIndex = 0; seenIndex < seen.length && seenIndex < 10; seenIndex++) {
              seenNames += (seenIndex === 0 ? '' : ', ')
                + (seen[seenIndex].ssid && seen[seenIndex].ssid.length > 0
                  ? seen[seenIndex].ssid : '<hidden>');
            }
            trace.push(`Wi-Fi scan returned ${seen.length} entries: [${seenNames}]`
              + ` (looking for ${ssid})`);
            trace.push(`Wi-Fi discovery still empty after ${emptyScanRounds} scans, cooling down 8 s`);
            await LumixImportPrototype.delay(8000);
          }
        }
      }
      trace.push(`Wi-Fi discovery elapsedMs=${Date.now() - scanStarted} found=${match !== undefined}`);
      if (!match) {
        // **扫描里没有，就直接按已知 SSID 连。**
        //
        // 用户实测：蓝牙握手之后系统 Wi-Fi 列表里确实多出一个**无名字**的热点，
        // 而官方 App 是**把已经拿到的 SSID 直接赋给连接配置**就连上了——它不等
        // 这个热点被广播出名字，也不要求扫描能匹配到它。
        //
        // SSID 本来就不需要靠扫描得到：它是我们从相机 `0x2004` 里解出来的。
        // 隐藏热点只要配置里明确给出 SSID 就能关联，所以"扫不到"从来不是失败
        // 条件，之前把它当失败条件才是错的。
        trace.push(`Wi-Fi SSID relation=UNRESOLVED ${ssid}; joining it directly by the `
          + `SSID the camera already gave us instead of waiting for it to be advertised`);
        const hiddenConfig: wifiManager.WifiDeviceConfig = {
          ssid: ssid,
          bssid: '',
          // 尼康热点是**开放**的：`WNIKONZ5` 是 PTP/IP 层的凭据，不是 Wi-Fi 密码。
          // 给它配 preSharedKey 会被系统判为非法组合（实测 addCandidateConfig
          // 直接抛 401），所以开放网络必须不带密钥。
          preSharedKey: '',
          securityType: wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN
          // 这里不设 `isHidden`：`WifiDeviceConfig` 没有这个字段，而且也不需要——
          // 配置里给出明确的 SSID 之后，系统会主动探测隐藏网络并关联。
        };
        try {
          const hiddenId = await wifiManager.addCandidateConfig(hiddenConfig);
          trace.push(`Wi-Fi hidden candidate added id=${hiddenId} ssid=${ssid}`);
          await wifiManager.connectToNetwork(hiddenId);
          const hiddenJoin = await LumixImportPrototype.awaitWifiJoin(ssid, trace);
          if (hiddenJoin.connected) {
            return hiddenJoin;
          }
          trace.push('Wi-Fi hidden join did not come up');
        } catch (error) {
          trace.push('Wi-Fi hidden join failed: ' + String(error));
        }
        return { connected: false, ssid: '', gateway: '', ipAddress: '' };
      }
      // A retry after a partially successful transfer can arrive while the
      // phone is already associated with the camera AP. Re-issuing the system
      // candidate connect tears that link down and waits for another trust
      // confirmation, which the camera reads as a lost client and answers
      // with its own connection-failed screen. Return the live link instead.
      // The pre-prompt link is also what the wait loop below uses to reject a
      // stale association: wifiManager.disconnect() is not available to
      // third-party apps, so switching bodies leaves the old camera AP linked
      // while the system confirmation for the new one is still in flight.
      // The SDK caps userActionTimeout at 30 seconds, so a user watching the
      // camera instead of the phone can let the trust dialog expire. Each
      // attempt re-checks the live link first (a late tap that joined after
      // the previous wait expired is picked up here) and re-issues the system
      // prompt, giving the user another confirmation window.
      let savedNetworkId = -1;
      for (let joinAttempt = 1; joinAttempt <= joinAttempts; joinAttempt++) {
        let prePromptSsid = '';
        let staleLinkLogged = false;
        try {
          const linkedNow = await wifiManager.getLinkedInfo();
          const linkedSsidNow = normalized(linkedNow.ssid || '');
          prePromptSsid = linkedSsidNow;
          if (linkedSsidNow.length > 0 && linkedSsidNow === normalized(match.ssid || '')) {
            const ipNow = wifiManager.getIpInfo();
            const gatewayNow = LumixImportPrototype.ipv4(ipNow.gateway);
            if (gatewayNow.length > 0) {
              // The live link may have no saved config behind it (an earlier
              // disconnect removed the candidate, or the user forgot the
              // network in system settings). Re-register the candidate so
              // the system can auto-rejoin when the camera recycles its
              // SoftAP - without it the 2026-09-27 19:52 entry-write restart
              // stranded the phone off the camera network with no way back.
              try {
                const keepConfig: wifiManager.WifiDeviceConfig = {
                  ssid: normalized(match.ssid || ''),
                  bssid: match.bssid,
                  // 开放网络不能带密钥：`securityType = OPEN` + 非空 `preSharedKey`
                  // 是非法组合，`addCandidateConfig` 会直接抛 401。尼康热点就是
                  // 开放网络（`WNIKONZ5` 属于 PTP/IP 层，不是 Wi-Fi 密码）。
                  preSharedKey: LumixImportPrototype.keyForNetwork(match.securityType, password),
                  securityType: match.securityType as wifiManager.WifiSecurityType,
                  showNoInternetDialog: true,
                };
                const keepId = await wifiManager.addCandidateConfig(keepConfig);
                if (keepId >= 0) {
                  LumixImportPrototype.lastCameraCandidateNetworkId = keepId;
                  trace.push(`Wi-Fi candidate re-registered while linked networkId=${keepId}`);
                }
              } catch (_error) { }
              trace.push(`Wi-Fi already linked ssid=${linkedSsidNow} gateway=${gatewayNow}; system connect skipped`);
              return { connected: true, ssid: linkedSsidNow, gateway: gatewayNow, ipAddress: LumixImportPrototype.ipv4(ipNow.ipAddress) };
            }
          }
        } catch (_error) { }
        const config: wifiManager.WifiDeviceConfig = {
          ssid: normalized(match.ssid || ''),
          bssid: match.bssid,
          // 同上：开放网络必须留空密钥，否则 addCandidateConfig 抛 401。
          preSharedKey: LumixImportPrototype.keyForNetwork(match.securityType, password),
          securityType: match.securityType as wifiManager.WifiSecurityType,
          // Panasonic APs intentionally have no Internet. Keep the system's
          // no-Internet confirmation enabled so Harmony can make this Wi-Fi the
          // active/default route, which is the API-26 equivalent of Android's
          // requestNetwork + bindProcessToNetwork path used by LUMIX Lab.
          showNoInternetDialog: true,
        };
        let networkId = savedNetworkId;
        // **必须包住：这里原本没有 try。**
        //
        // `addCandidateConfig` 抛异常时（权限不足、平台限制等）既不写 trace、也没有
        // 返回值，整个流程被直接掀翻——用户只看到一句转瞬即逝的报错，连原因都留不下
        // （实测发生过：通知栏没弹授权框、日志里连一行都没有）。包住之后原因会进
        // trace，并且以"未连接"这个明确的结论返回，调用方能据此不进图库。
        let candidateId = -1;
        try {
          candidateId = await wifiManager.addCandidateConfig(config);
        } catch (candidateError) {
          trace.push(`Wi-Fi candidate config EXCEPTION code=${LumixImportPrototype.errorCode(candidateError)} ${String(candidateError)}`);
          return { connected: false, ssid: '', gateway: '', ipAddress: '' };
        }
        if (candidateId >= 0) {
          savedNetworkId = candidateId;
          LumixImportPrototype.lastCameraCandidateNetworkId = candidateId;
          networkId = candidateId;
        } else if (networkId < 0) {
          trace.push(`Wi-Fi candidate config rejected code=${candidateId}`);
          return { connected: false, ssid: '', gateway: '', ipAddress: '' };
        } else {
          trace.push(`Wi-Fi candidate re-add rejected code=${candidateId}; reusing networkId=${networkId}`);
        }
        if (joinAttempt > 1) {
          trace.push(`Wi-Fi join retry attempt=${joinAttempt}`);
        }
        onPrompt(joinAttempt);
        trace.push(`Wi-Fi system prompt requested elapsedMs=${Date.now() - scanStarted} attempt=${joinAttempt}`);
        // This is the single user-facing system confirmation for a third-party
        // Wi-Fi network. The API-26 settings overload also asks the system to
        // retain the candidate and make it the active route, matching the
        // Android requestNetwork/bindProcessToNetwork behavior in the capture.
        let promptAborted = false;
        try {
          await wifiManager.connectToCandidateConfig({
            networkId: networkId,
            withUserAction: true,
            userActionTimeout: 30,
            addNetworkToSystem: true,
          });
          trace.push('Wi-Fi system user-action request=sent addNetworkToSystem=true');
        } catch (error) {
          const promptCode = LumixImportPrototype.errorCode(error);
          trace.push(`Wi-Fi system user-action request=error code=${promptCode}`);
          // 2501005: the 30 s trust dialog expired unanswered; 2501006: the
          // user tapped cancel. No association can follow either verdict, so
          // skip the wait loop and surface a fresh dialog on the next attempt
          // instead of burning the whole link budget on a dead join.
          if (promptCode === '2501005' || promptCode === '2501006') {
            promptAborted = true;
          } else {
            try {
              // Some device builds accept the candidate silently after the system
              // prompt has already been handled. This fallback never opens another
              // confirmation dialog.
              wifiManager.connectToCandidateConfig(networkId);
              trace.push('Wi-Fi automatic fallback request=sent');
            } catch (fallbackError) {
              trace.push(`Wi-Fi automatic fallback request=error code=${LumixImportPrototype.errorCode(fallbackError)}`);
            }
          }
        }
        if (promptAborted) {
          await LumixImportPrototype.delay(1500);
          continue;
        }
        const deadline = Date.now() + 40000;
        while (Date.now() < deadline) {
          const linked = await wifiManager.getLinkedInfo();
          actualSsid = normalized(linked.ssid || '');
          const ip = wifiManager.getIpInfo();
          ipAddress = LumixImportPrototype.ipv4(ip.ipAddress);
          gateway = LumixImportPrototype.ipv4(ip.gateway);
          const ssidMatches = actualSsid.length > 0 && actualSsid === normalized(match.ssid || '');
          // The BLE logical name (for example S1RM2-F2B179) can differ from the
          // beacon SSID (for example S1A0EAA4BD), but match.ssid holds the exact
          // SSID discovered by the scan above, so an exact comparison is the only
          // relation that may accept the link. The previous S1*/S5*/S9* prefix
          // fallback is removed: it inferred the camera's identity from its Wi-Fi
          // name, which no official LUMIX generation does, and it could accept an
          // unrelated Panasonic body's AP whenever the link changed. The
          // association that was already live before the system prompt therefore
          // stays rejected, because accepting it would send the HTTP leg to the
          // previous camera's gateway.
          if (ssidMatches && gateway.length > 0) {
            trace.push(`Wi-Fi linked ssid=${actualSsid} ip=${ipAddress} gateway=${gateway} internet=not-required`);
            return { connected: true, ssid: actualSsid, gateway: gateway, ipAddress: ipAddress };
          }
          // Diagnostics only: the association still points at the network that was
          // already live before the system prompt, so the join has not taken
          // effect yet. This never accepts the link; it only explains the wait.
          if (!staleLinkLogged && !ssidMatches && prePromptSsid.length > 0 && actualSsid === prePromptSsid) {
            staleLinkLogged = true;
            trace.push(`Wi-Fi link wait skipped stale pre-prompt ssid=${actualSsid}; target=${normalized(match.ssid || '')}`);
          }
          await LumixImportPrototype.delay(700);
        }
        trace.push(`Wi-Fi link timeout actual=${actualSsid.length > 0 ? 'present' : 'none'} attempt=${joinAttempt}`);
      }
      trace.push(`Wi-Fi join exhausted attempts=${joinAttempts}`);
      return { connected: false, ssid: actualSsid, gateway: gateway, ipAddress: ipAddress };
    } catch (error) {
      LumixImportPrototype.logError('wifi', error);
      return { connected: false, ssid: actualSsid, gateway: gateway, ipAddress: ipAddress };
    }
  }

  private static async postJson(host: string, path: string, body: string | undefined, token: string, fingerprint: string, trace: string[]): Promise<JsonResponse> {
    const request = http.createHttp();
    const requestSequence = LumixImportPrototype.nextHttpRequestSequence();
    // Declared outside `try` so the failure marker can carry the elapsed time.
    // A full connect budget means the camera's HTTPS endpoint answered nothing
    // yet — the difference a bare error code cannot express.
    let requestStartedAt = 0;
    try {
      // A zero-length ArrayBuffer body makes Harmony's stack throw, and an
      // empty string body goes out without Content-Length, which the camera
      // answers with 411. For the body-less count endpoint set the header by
      // hand next to the empty string body; non-empty bodies get their
      // Content-Length from the stack itself.
      let headers: JsonRequestHeaders;
      if (token.length > 0) {
        headers = body === ''
          ? { 'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': LumixImportPrototype.authorizationHeader(token), 'Content-Length': '0' }
          : { 'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': LumixImportPrototype.authorizationHeader(token) };
      } else {
        headers = body === ''
          ? { 'Accept': 'application/json', 'Content-Type': 'application/json', 'Content-Length': '0' }
          : { 'Accept': 'application/json', 'Content-Type': 'application/json' };
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        connectTimeout: 15000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING,
        remoteValidation: (validation: http.ValidationContext): Promise<boolean> => LumixImportPrototype.validateCertificate(validation, fingerprint, trace),
      };
      if (body !== undefined) {
        // An empty ArrayBuffer body makes Harmony's stack throw, and omitting
        // the body gets a 411 from the camera. An empty STRING body is framed
        // by the stack with Content-Length: 0, which is what the camera asks
        // for on the body-less count endpoint.
        options.body = body.length === 0 ? '' : util.TextEncoder.create('utf-8').encode(body).buffer as ArrayBuffer;
      }
      const requestHeaderSummary = LumixImportPrototype.summarizeHeaders(headers);
      const requestBodySummary = LumixImportPrototype.summarizeJsonBody(body);
      const requestMarker = `HTTP_REQ seq=${requestSequence} method=POST path=${path} host=${LumixImportPrototype.redactHost(LumixImportPrototype.cleanHost(host))} headers=${requestHeaderSummary} body=${requestBodySummary}`;
      trace.push(requestMarker);
      LumixImportPrototype.httpInfo(requestMarker);
      trace.push(`HTTPS request start path=${path} host=${LumixImportPrototype.redactHost(LumixImportPrototype.cleanHost(host))}`);
      requestStartedAt = Date.now();
      const response = await request.request(`https://${LumixImportPrototype.cleanHost(host)}${path}`, options);
      const result = typeof response.result === 'string' ? response.result : util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(response.result as ArrayBuffer));
      const responseMarker = `HTTP_RES seq=${requestSequence} path=${path} http=${response.responseCode} business=${LumixImportPrototype.businessCode(result)} elapsedMs=${Date.now() - requestStartedAt} bytes=${LumixImportPrototype.utf8Length(result)} headers=${LumixImportPrototype.summarizeHeaders(response.header)} body=${LumixImportPrototype.summarizeJsonResponse(result)}`;
      trace.push(responseMarker);
      LumixImportPrototype.httpInfo(responseMarker);
      trace.push(`POST ${path} http=${response.responseCode} business=${LumixImportPrototype.businessCode(result)} auth=${token.length > 0 ? 'bearer-redacted' : 'none'} body=${body === undefined ? 'none' : (body.length === 0 ? 'empty' : 'json-redacted')}`);
      return { httpStatus: response.responseCode, body: result, headers: response.header };
    } catch (error) {
      // `phase=timeout` marks the camera-not-ready signature: the whole connect
      // budget was burned without a reply. A fast failure stays unlabelled.
      const failureElapsedMs = requestStartedAt === 0 ? -1 : Date.now() - requestStartedAt;
      const failurePhase = failureElapsedMs >= 14000 ? ' phase=timeout' : '';
      const errorMarker = `HTTP_ERR seq=${requestSequence} path=${path} code=${LumixImportPrototype.errorCode(error)} elapsedMs=${failureElapsedMs}${failurePhase}`;
      trace.push(errorMarker);
      LumixImportPrototype.httpInfo(errorMarker);
      if (error instanceof Error) throw error;
      throw new Error(`HTTP request failed (${LumixImportPrototype.errorCode(error)})`);
    } finally { request.destroy(); }
  }

  private static async postThumbnail(host: string, imageId: string, token: string, fingerprint: string, context: common.UIAbilityContext, trace: string[], index: number): Promise<string> {
    const request = http.createHttp();
    const requestSequence = LumixImportPrototype.nextHttpRequestSequence();
    let requestStartedAt = 0;
    try {
      const body = JSON.stringify({ ImageId: imageId, ThumbnailCategory: THUMBNAIL_CATEGORY });
      const headers: JsonRequestHeaders = {
        'Authorization': LumixImportPrototype.authorizationHeader(token),
        // Official annotation is @k({"Content-Type": "application/json",
        // "Accept": "binary/octet-stream"}) — p107j6/a.java:212-215. This was
        // the only media request asking for application/octet-stream.
        'Accept': 'binary/octet-stream',
        'Content-Type': 'application/json',
      };
      const requestMarker = `HTTP_REQ seq=${requestSequence} method=POST path=/media/gallery/thumbnail host=${LumixImportPrototype.redactHost(LumixImportPrototype.cleanHost(host))} headers=${LumixImportPrototype.summarizeHeaders(headers)} body=${LumixImportPrototype.summarizeJsonBody(body)}`;
      trace.push(requestMarker);
      LumixImportPrototype.httpInfo(requestMarker);
      requestStartedAt = Date.now();
      const response = await request.request(`https://${LumixImportPrototype.cleanHost(host)}/media/gallery/thumbnail`, {
        method: http.RequestMethod.POST,
        header: headers,
        body: util.TextEncoder.create('utf-8').encode(body).buffer as ArrayBuffer,
        connectTimeout: 15000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        remoteValidation: (validation: http.ValidationContext): Promise<boolean> => LumixImportPrototype.validateCertificate(validation, fingerprint, trace),
      });
      const resultBytes = response.result as ArrayBuffer;
      const responseMarker = `HTTP_RES seq=${requestSequence} path=/media/gallery/thumbnail http=${response.responseCode} business=${LumixImportPrototype.businessCodeFromHeader(response.header)} elapsedMs=${Date.now() - requestStartedAt} bytes=${resultBytes && resultBytes.byteLength ? resultBytes.byteLength : 0} headers=${LumixImportPrototype.summarizeHeaders(response.header)} body=binary`;
      trace.push(responseMarker);
      LumixImportPrototype.httpInfo(responseMarker);
      trace.push(`POST /media/gallery/thumbnail http=${response.responseCode} bytes=${resultBytes && resultBytes.byteLength ? resultBytes.byteLength : 0} auth=bearer-redacted body=json-redacted`);
      if (response.responseCode < 200 || response.responseCode >= 300) return '';
      // A positional filename (index only) is reused across sessions and SD
      // cards, and the Image component caches by URI - the grid then shows
      // stale thumbnails from a previous session. Key the file by the stable
      // imageId as well so every fetch writes a unique URI.
      const safeId = imageId.replace(/[^0-9A-Za-z]/g, '_');
      const path = `${context.filesDir}/lumix_thumbnail_${index}_${safeId}.jpg`;
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, resultBytes);
      fileIo.closeSync(file);
      return `file://${path}`;
    } catch (error) {
      const failureElapsedMs = requestStartedAt === 0 ? -1 : Date.now() - requestStartedAt;
      const failurePhase = failureElapsedMs >= 14000 ? ' phase=timeout' : '';
      const errorMarker = `HTTP_ERR seq=${requestSequence} path=/media/gallery/thumbnail code=${LumixImportPrototype.errorCode(error)} elapsedMs=${failureElapsedMs}${failurePhase}`;
      trace.push(errorMarker);
      LumixImportPrototype.httpInfo(errorMarker);
      if (error instanceof Error) throw error;
      throw new Error(`Thumbnail request failed (${LumixImportPrototype.errorCode(error)})`);
    } finally { request.destroy(); }
  }

  /** Download the camera original through the same media/image protocol used
   * by LUMIX Lab. The request body is JSON encoded as UTF-8 even though the
   * endpoint advertises application/octet-stream. ImageSize follows the
   * Android client: JPEG (Type 2) uses 2; RAW/other still types use 1 and a
   * Range header. No thumbnail bytes are reused for this path.
   * The body is consumed through requestInStream and appended chunk by chunk
   * to the sandbox file: request() buffers the entire payload and rejects
   * with 2300023 once it exceeds the default maxLimit, which S1RII RW2
   * originals (~50-90MB) do; the streaming path has no size cap and keeps
   * memory usage at a single chunk instead of the whole file. */
  /**
   * Snapshot of the authenticated Wi-Fi session, for callers that speak to the
   * camera outside this class (the firmware-update flow). Empty host/token
   * means no session is established.
   */
  static currentSession(): LumixSessionSnapshot {
    return {
      host: LumixImportPrototype.sessionHost,
      token: LumixImportPrototype.sessionToken,
      fingerprint: LumixImportPrototype.sessionFingerprint,
    };
  }

  /**
   * Read the body's model name and firmware versions over BLE. The official
   * client reads these on every connect and the firmware flow compares them
   * against the cloud catalogue before sending anything, so the update screen
   * needs them rather than the Wi-Fi name or a stored string. Best effort:
   * returns whatever was readable (empty strings for missing characteristics).
   */
  static emptyFirmwareIdentity(trace: string[]): LumixFirmwareIdentity {
    return {
      modelName: '', cameraFirmware: '', lensName: '', lensFirmware: '', deviceId: '', trace: trace,
    };
  }

  /**
   * True when a GATT link from a completed BLE pairing/registration is still
   * held. Firmware version reads must run on such a link: against a bare
   * connect + getServices link the platform rejects every read immediately
   * (measured 2026-10-16 on S1RM2: 2900099 / -1028 / 2900007 / 2901003 within
   * 1 ms), while the same characteristics read fine inside the registered
   * session that also reads INITIAL_INFORM.
   */
  static hasRegisteredBleSession(): boolean {
    return LumixImportPrototype.activeGatt !== null
      && LumixImportPrototype.activeGattDeviceId.length > 0;
  }

  /** Latest slot inventory read from the camera; ok=false until a read lands. */
  private static slotInfo: LumixSlotInfo = { ok: false, slots: [], raw: '', message: '' };

  /** Slot inventory from the most recent identity read. */
  static currentSlotInfo(): LumixSlotInfo {
    return LumixImportPrototype.slotInfo;
  }

  /**
   * Parse the SLOT_INFO string. Mirrors C5/L4.java:365-401.
   *
   * Wire format is "NAME,present,NAME,present" — `SSD,1` for a single-slot body
   * (S9), `SD1,1,SD2,0` for a two-slot body, `CFe,1,SD,1` for a CFexpress body.
   * A non-numeric token is a slot name; the numeric token following it is its
   * presence flag (1 = card present).
   */
  static parseSlotInfo(raw: string): LumixSlot[] {
    const slots: LumixSlot[] = [];
    const tokens = raw.replace(/\s/g, '').split(',');
    // 官方 map 会把 SSD 挪到末尾，SD1/SD2 的序号只数非 SSD 槽位。
    let nonSsd = 0;
    for (let index = 0; index < tokens.length; index++) {
      const token = tokens[index];
      if (token.length === 0) continue;
      if (/^[0-9]+$/.test(token)) {
        if (index > 0 && slots.length > 0) {
          slots[slots.length - 1].present = token === '1';
        }
        continue;
      }
      const name = token.toUpperCase();
      slots.push({
        name: name,
        wire: LumixImportPrototype.slotWireName(name, nonSsd),
        display: name === 'CFe' ? 'CFexpress' : name,
        present: false,
      });
      if (name !== 'SSD') nonSsd += 1;
    }
    return slots;
  }

  /**
   * 槽位名 → current-sd 值。规则取自 CameraGalleryActivity.java:967-975：
   * SSD 单独命名，其余按出现序号 SD1/SD2。注意这里用的是**已计入 SSD 的序号**
   * 之外的非 SSD 计数，与官方 `i10`（标签下标，SSD 被挪到末尾）等价。
   */
  private static slotWireName(name: string, nonSsdIndex: number): string {
    if (name === 'SSD') return 'SSD';
    if (name === 'SD1') return 'SD1';
    if (name === 'SD2') return 'SD2';
    // 非 SSD 槽位按出现顺序命名；CFe 与 SD 都走这条。
    return nonSsdIndex === 0 ? 'SD1' : 'SD2';
  }

  /**
   * Resolve the CurrentSd value to send, from the camera's own inventory.
   *
   * The camera rejects a slot name it does not have. A single-slot body (S9)
   * reports only `SSD`, so the `SD1` this app used to send is rejected — and
   * because every gallery leg sits behind current-sd, that rejection left the
   * gallery permanently empty: no thumbnails, nothing downloadable, with only
   * "current-sd 被拒绝" in the log. Correct order: the requested slot when the
   * camera reports it, else the single-slot sentinel `SSD`, else whatever the
   * camera does report. Returns the request untouched when the inventory was
   * never read, so behaviour is unchanged for bodies we cannot interrogate.
   */
  private static resolveCurrentSd(requested: string): string {
    const info = LumixImportPrototype.slotInfo;
    if (!info.ok || info.slots.length === 0) return requested;
    const wanted = requested.trim().toUpperCase();
    // 1. 精确命中合法的 current-sd 值（SD1 / SD2 / SSD）。
    for (const slot of info.slots) {
      if (slot.wire === wanted) return slot.wire;
    }
    // 2. 调用方也可能直接传清单里的原始名（CFe / SD），映射到对应的 wire 值。
    for (const slot of info.slots) {
      if (slot.name === wanted) return slot.wire;
    }
    // 3. 兜底：优先挑一张确实有卡的槽位。S1RM2 的清单是
    //    `CFe,1,SD,0,SSD,0`，盲取第一个/取 SSD 都会指向空槽。
    for (const slot of info.slots) {
      if (slot.present) return slot.wire;
    }
    return info.slots[0].wire;
  }

  static async readFirmwareIdentity(context: common.UIAbilityContext,
    preferredDeviceId: string = ''): Promise<LumixFirmwareIdentity> {
    const trace: string[] = [];
    let gatt: ble.GattClientDevice | null = null;
    // connectGatt() always builds a fresh client, so a link opened here must be
    // closed here. Tracking "did we open it" (rather than "was an id passed")
    // is what keeps the retained link from being double-opened or leaked.
    let openedHere = false;
    try {
      const retained = LumixImportPrototype.activeGatt;
      const retainedId = LumixImportPrototype.activeGattDeviceId;
      let deviceId = preferredDeviceId;
      if (deviceId.length === 0) {
        deviceId = (retained !== null && retainedId.length > 0)
          ? retainedId : await LumixImportPrototype.scanBle(trace, '', true);
      }
      if (deviceId.length === 0) {
        trace.push('firmware identity scan=no-camera');
        return LumixImportPrototype.emptyFirmwareIdentity(trace);
      }
      if (retained !== null && retainedId.length > 0
        && (retainedId === deviceId || preferredDeviceId.length === 0)) {
        // A retained link is a session the registration writes already
        // completed in, and that is the only kind of link where these
        // characteristic reads are known to work (see the 2901003 note in
        // observeFirmwareWriteProgress). Prefer it over opening a second
        // client, which is also what triggers the 2900099 stale-session case.
        gatt = retained;
        trace.push('firmware identity reusing retained GATT link');
      } else {
        await LumixImportPrototype.ensurePaired(deviceId, trace);
        gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
        openedHere = true;
      }
      const client: ble.GattClientDevice = gatt;
      // Bounded service discovery. The platform can hand back an empty or
      // incomplete GATT table on the first call after connecting (the same
      // behaviour LumixSyncControlService.discoverSyncServices works around);
      // this read used to take a single answer and then report "0 length",
      // which is indistinguishable from a genuinely missing characteristic.
      let services: Array<ble.GattService> = [];
      for (let attempt = 1; attempt <= 10; attempt++) {
        try {
          services = await client.getServices();
        } catch (error) {
          trace.push(`firmware getServices#${attempt} error code=${LumixImportPrototype.errorCode(error)}`);
          services = [];
        }
        if (services.length > 0) {
          trace.push(`firmware getServices attempt=${attempt} services=${services.length}`);
          break;
        }
        trace.push(`firmware getServices attempt=${attempt} empty`);
        await LumixImportPrototype.delay(500);
      }
      // Dump what the camera actually exposed so a failed read pinpoints the
      // cause (wrong service, missing characteristic, or a rejected read)
      // instead of a bare "not read" verdict.
      for (const service of services) {
        const isTarget = service.serviceUuid.toLowerCase() === BLE_SERVICE.toLowerCase();
        trace.push(`firmware service ${service.serviceUuid} chars=${service.characteristics.length}${isTarget ? ' TARGET' : ''}`);
      }
      const chars = LumixImportPrototype.indexCharacteristics(services);
      trace.push(`firmware char-index model=${chars.cameraModelName ? 1 : 0}`
        + ` fw=${chars.cameraFirmwareVersion ? 1 : 0}`
        + ` lens=${chars.lensName ? 1 : 0} lensFw=${chars.lensFirmwareVersion ? 1 : 0}`
        + ` slots=${chars.sdSlotInfo ? 1 : 0}`);
      // Property flags decide whether a read is even legal locally: the
      // platform rejects reads on non-readable characteristics before any
      // over-the-air traffic, with a different code per characteristic.
      const describe = (label: string, c: ble.BLECharacteristic | undefined): void => {
        if (!c) {
          trace.push(`firmware prop ${label} missing`);
          return;
        }
        const props = c.properties;
        const canRead = props !== undefined && props !== null && props.read === true;
        const canWrite = props !== undefined && props !== null && props.write === true;
        const canNotify = props !== undefined && props !== null && props.notify === true;
        trace.push(`firmware prop ${label} read=${canRead ? 1 : 0} write=${canWrite ? 1 : 0} notify=${canNotify ? 1 : 0}`);
      };
      describe('model', chars.cameraModelName);
      describe('cameraFw', chars.cameraFirmwareVersion);
      describe('lens', chars.lensName);
      describe('lensFw', chars.lensFirmwareVersion);
      describe('slotInfo', chars.sdSlotInfo);
      const read = async (label: string, characteristic: ble.BLECharacteristic | undefined): Promise<string> => {
        if (!characteristic) {
          trace.push(`firmware read ${label} missing-characteristic`);
          return '';
        }
        try {
          const raw = await LumixImportPrototype.readGatt(client, characteristic, trace);
          const text = LumixImportPrototype.decodeGatt(raw);
          trace.push(`firmware read ${label} len=${text.length}`);
          return text;
        } catch (error) {
          trace.push(`firmware read ${label} error code=${LumixImportPrototype.errorCode(error)}`);
          return '';
        }
      };
      const modelName = await read('model', chars.cameraModelName);
      const cameraFirmware = await read('cameraFw', chars.cameraFirmwareVersion);
      const lensName = await read('lens', chars.lensName);
      const lensFirmware = await read('lensFw', chars.lensFirmwareVersion);
      // Slot inventory, same session, same read rules. Stored statically so the
      // gallery legs can pick a legal CurrentSd instead of assuming SD1.
      const slotRaw = await read('slotInfo', chars.sdSlotInfo);
      const slots = LumixImportPrototype.parseSlotInfo(slotRaw);
      LumixImportPrototype.slotInfo = {
        ok: slots.length > 0,
        slots: slots,
        raw: slotRaw,
        message: slots.length > 0 ? '' : '未读到相机槽位清单',
      };
      let slotNames = '';
      for (const slot of slots) {
        slotNames = slotNames.length === 0 ? slot.name : `${slotNames}/${slot.name}`;
      }
      trace.push(`firmware slots count=${slots.length} names=${slotNames}`);
      trace.push(`firmware identity model=${modelName.length} cameraFw=${cameraFirmware.length} lens=${lensName.length} lensFw=${lensFirmware.length}`);
      return {
        modelName: modelName,
        cameraFirmware: cameraFirmware,
        lensName: lensName,
        lensFirmware: lensFirmware,
        deviceId: deviceId,
        trace: trace,
      };
    } catch (error) {
      trace.push(`firmware identity failed code=${LumixImportPrototype.errorCode(error)}`);
      return LumixImportPrototype.emptyFirmwareIdentity(trace);
    } finally {
      if (openedHere && gatt !== null) {
        // Close only a link this call opened; the retained link belongs to the
        // session flow and must survive the read.
        try { gatt.disconnect(); } catch (_error) { }
        try { gatt.close(); } catch (_error) { }
      }
    }
  }

  /**
   * 选择与去重键。一次 RAW+JPEG 拍摄会被拆成 JPG 与 RW2 两张卡片，两者共用
   * 相机的 ImageId，所以单靠 ImageId 无法区分：点击 JPG 卡会连带选中并下载
   * 同一次拍摄的 RW2，界面也会两张一起打勾。带上 imageType 才能一张卡一个
   * 文件。
   */
  static galleryItemKey(item: LumixGalleryItem): string {
    return `${item.imageId}:${item.imageType}`;
  }

  static originalFileNameFor(item: LumixGalleryItem, rawVariant: boolean): string {
    const supplied = (item.originalFileName || '').trim();
    const dot = supplied.lastIndexOf('.');
    const base = dot > 0 ? supplied.substring(0, dot) : supplied;
    const fallbackBase = base.length > 0 ? base : `VIVID_LUMIX_${item.imageId || Date.now()}`;
    const suffix = dot >= 0 ? supplied.substring(dot + 1).toLowerCase() : '';
    if (rawVariant) {
      return suffix === 'rw2' ? supplied : `${fallbackBase}.RW2`;
    }
    return suffix === 'jpg' || suffix === 'jpeg' ? supplied : `${fallbackBase}.JPG`;
  }

  static async downloadOriginal(context: common.UIAbilityContext, item: LumixGalleryItem, index: number,
    onProgress?: (progress: number, received: number, total: number) => void, forceRaw: boolean = false): Promise<string> {
    if (LumixImportPrototype.sessionHost.length === 0 || LumixImportPrototype.sessionToken.length === 0) return '';
    const requestType = forceRaw ? 1 : item.imageType;
    const rawVariant = requestType !== 2;
    if (rawVariant) {
      // RAW: Type=1 + ImageSize=1, walked in the official 16 MiB windows.
      // When the info response omits RawSize the request must stay open-ended:
      // falling back to the JPEG Size capped the Range below the real RAW
      // length, so the camera returned only the leading slice of the file.
      const expectedSize = item.rawSize !== undefined && item.rawSize > 0 ? item.rawSize : 0;
      const attempt = await LumixImportPrototype.downloadRanged(context, item, index,
        requestType, 1, expectedSize, onProgress, 0);
      return attempt.received > 0 && attempt.path.length > 0 ? attempt.path : '';
    }
    // JPEG 原图：先请求 Type=2 + ImageSize=2（无 Range）。部分固件此时仍
    // 返回缩略图——实收字节明显小于声明尺寸时，回退 Type=2 + ImageSize=1
    // + Range 再试一次，保留两个响应中较大的文件。
    const expectedSize = item.size || 0;
    const first = await LumixImportPrototype.downloadAttempt(context, item, index,
      requestType, 2, expectedSize, false, onProgress, 0);
    if (first.received <= 0) return '';
    if (expectedSize <= 0 || first.received >= expectedSize * 0.85) {
      LumixImportPrototype.httpInfo('VIVID_HTTP original ok type=2 imageSize=2 bytes=' + first.received + ' expected=' + expectedSize);
      return first.path;
    }
    LumixImportPrototype.httpInfo('VIVID_HTTP original small bytes=' + first.received + ' expected=' + expectedSize + '; retry imageSize=1+Range');
    const second = await LumixImportPrototype.downloadRanged(context, item, index,
      requestType, 1, expectedSize, onProgress, 1);
    if (second.path.length > 0 && second.received > first.received) {
      try { fileIo.unlinkSync(first.path.replace(/^file:\/\//, '')); } catch (_error) { }
      LumixImportPrototype.httpInfo('VIVID_HTTP original retry larger bytes=' + second.received + ' kept=alt');
      return second.path;
    }
    if (second.received > 0 && second.path.length > 0) {
      try { fileIo.unlinkSync(second.path.replace(/^file:\/\//, '')); } catch (_error) { }
    }
    return first.path;
  }

  /**
   * Ranged original download that walks the official 16 MiB windows.
   *
   * Each window's Range begins at the number of bytes already on disk, so both
   * camera behaviours terminate correctly: one that honours the header returns
   * a full window and the loop continues, and one that ignores it returns the
   * whole remainder, which already satisfies the target and ends the loop.
   *
   * expectedSize == 0 means the info response never reported a length; the
   * windows then stay open-ended (bytes=<start>-) and the loop stops at the
   * first window that is not exactly filled. The file is kept only when it
   * reached the declared size, so a short transfer can no longer be recorded
   * as a successful original.
   */
  private static async downloadRanged(context: common.UIAbilityContext, item: LumixGalleryItem, index: number,
    requestType: number, imageSize: number, expectedSize: number,
    onProgress?: (progress: number, received: number, total: number) => void,
    attemptIndex: number = 0): Promise<DownloadAttemptResult> {
    let total = 0;
    let sandboxPath = '';
    for (let guard = 0; guard < 1024; guard++) {
      const requested = expectedSize > 0
        ? Math.min(LUMIX_MEDIA_WINDOW, expectedSize - total)
        : LUMIX_MEDIA_WINDOW;
      if (expectedSize > 0 && requested <= 0) break;
      const base = total;
      const windowProgress = (progress: number, received: number, totalBytes: number): void => {
        if (onProgress === undefined) return;
        const overallTotal = expectedSize > 0 ? expectedSize : totalBytes;
        const value = overallTotal > 0
          ? Math.max(0, Math.min(100, Math.round((base + received) * 100 / overallTotal)))
          : 0;
        onProgress(value, base + received, overallTotal);
      };
      const window = await LumixImportPrototype.downloadAttempt(context, item, index, requestType,
        imageSize, expectedSize, true, windowProgress, attemptIndex, total, sandboxPath);
      if (window.received <= 0) break;
      total += window.received;
      sandboxPath = window.path.replace(/^file:\/\//, '');
      if (expectedSize > 0 && total >= expectedSize) break;
      // Unknown total: a window that was not exactly filled means the camera is
      // out of data. A larger reply means it ignored Range and sent everything.
      if (expectedSize <= 0 && window.received !== requested) break;
    }
    if (expectedSize > 0 && total < expectedSize) {
      if (sandboxPath.length > 0) {
        try { fileIo.unlinkSync(sandboxPath); } catch (_error) { }
      }
      LumixImportPrototype.httpInfo(`VIVID_HTTP original incomplete received=${total} expected=${expectedSize}; dropped`);
      return { received: total, path: '' };
    }
    if (total <= 0 || sandboxPath.length === 0) {
      return { received: 0, path: '' };
    }
    LumixImportPrototype.httpInfo(`VIVID_HTTP original complete bytes=${total} expected=${expectedSize} windows=${Math.ceil(total / LUMIX_MEDIA_WINDOW)}`);
    return { received: total, path: `file://${sandboxPath}` };
  }

  /** 单次 /media/image 流式下载。返回实收字节数与沙箱文件路径。 */
  private static async downloadAttempt(context: common.UIAbilityContext, item: LumixGalleryItem, index: number,
    requestType: number, imageSize: number, expectedSize: number, rangeMode: boolean,
    onProgress?: (progress: number, received: number, total: number) => void,
    attemptIndex: number = 0, rangeStart: number = 0, resumePath: string = ''): Promise<DownloadAttemptResult> {
    const trace: string[] = [];
    const request = http.createHttp();
    const rawVariant = requestType !== 2;
    const body = JSON.stringify({ ImageId: item.imageId, Type: requestType, ImageSize: imageSize });
    const requestSequence = LumixImportPrototype.nextHttpRequestSequence();
    const headers: Record<string, string> = {
      'Authorization': LumixImportPrototype.authorizationHeader(LumixImportPrototype.sessionToken),
      'Accept': 'binary/octet-stream',
      'Content-Type': 'application/octet-stream',
    };
    if (rangeMode) {
      // One official window per request. An unknown total stays open-ended
      // (bytes=<start>-) rather than borrowing the JPEG size.
      const end = expectedSize > 0
        ? Math.min(rangeStart + LUMIX_MEDIA_WINDOW, expectedSize) - 1
        : '';
      headers['Range'] = `bytes=${rangeStart}-${end}`;
    }
    const requestMarker = `HTTP_REQ seq=${requestSequence} method=POST path=/media/image host=${LumixImportPrototype.redactHost(LumixImportPrototype.cleanHost(LumixImportPrototype.sessionHost))} headers=${LumixImportPrototype.summarizeHeaders(headers)} body=${LumixImportPrototype.summarizeJsonBody(body)}`;
    trace.push(requestMarker);
    LumixImportPrototype.httpInfo(requestMarker);
    const progressHandler = (info: DownloadProgressInfo): void => {
      const total = Number(info && info.totalSize) || expectedSize || 0;
      const received = Number(info && info.receiveSize) || 0;
      const value = total > 0 ? Math.max(0, Math.min(100, Math.round(received * 100 / total))) : 0;
      if (onProgress) onProgress(value, received, total);
    };
    const sourceName = LumixImportPrototype.originalFileNameFor(item, rawVariant) ||
      `VIVID_LUMIX_${index}_${Date.now()}.${rawVariant ? 'rw2' : 'jpg'}`;
    const safeName = sourceName.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_');
    const attemptPrefix = attemptIndex > 0 ? `v${attemptIndex}_` : '';
    const path = resumePath.length > 0
      ? resumePath
      : `${context.filesDir}/lumix_original_${index}_${attemptPrefix}${safeName}`;
    if (onProgress) onProgress(0, 0, expectedSize);
    // Streaming state shared with the request callbacks. The sandbox file is
    // opened lazily on the first received chunk so an error or empty response
    // never leaves a partial original behind; failed runs delete it again.
    let file: fileIo.File | null = null;
    let received: number = 0;
    let statusCode: number = 0;
    let dataEnded: boolean = false;
    let failure: Object | null = null;
    let settled: boolean = false;
    let resolveDone: (ok: boolean) => void = (_ok: boolean) => { };
    const streamDone = new Promise<boolean>((resolve: (ok: boolean) => void) => {
      resolveDone = resolve;
    });
    // requestInStream resolves as soon as the response headers are handled,
    // which can happen before or after the body events; only a 2xx status
    // plus dataEnd (with bytes actually written) counts as success.
    const settle = (): void => {
      if (settled) return;
      if (failure !== null) {
        settled = true;
        resolveDone(false);
        return;
      }
      if (statusCode > 0 && dataEnded) {
        settled = true;
        resolveDone(statusCode >= 200 && statusCode < 300 && received > 0);
      }
    };
    const fail = (error: Object): void => {
      if (failure === null) failure = error;
      settle();
    };
    const discardFile = (): void => {
      if (file !== null) {
        try { fileIo.closeSync(file); } catch (_error) { }
        file = null;
      }
      try { fileIo.unlinkSync(path); } catch (_error) { }
    };
    try {
      // Subscribe every callback before the request is dispatched.
      request.on('dataReceive', (chunk: ArrayBuffer) => {
        if (settled || chunk.byteLength === 0) return;
        try {
          if (file === null) {
            // A resumed window appends to the bytes already on disk; the first
            // window truncates so a stale file from an earlier run is replaced.
            file = fileIo.openSync(path, resumePath.length > 0
              ? fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND
              : fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
          }
          fileIo.writeSync(file.fd, chunk);
          received += chunk.byteLength;
        } catch (error) {
          fail(error);
        }
      });
      request.on('dataEnd', () => {
        dataEnded = true;
        settle();
      });
      request.on('dataReceiveProgress', progressHandler);
      const requestStartedAt = Date.now();
      request.requestInStream(
        `https://${LumixImportPrototype.cleanHost(LumixImportPrototype.sessionHost)}/media/image`,
        {
          method: http.RequestMethod.POST,
          header: headers,
          body: util.TextEncoder.create('utf-8').encode(body).buffer as ArrayBuffer,
          connectTimeout: 15000,
          readTimeout: 60000,
          remoteValidation: (validation: http.ValidationContext): Promise<boolean> => LumixImportPrototype.validateCertificate(validation, LumixImportPrototype.sessionFingerprint, trace),
        },
      ).then((code: number) => {
        statusCode = code;
        settle();
      }).catch((error: BusinessError) => {
        fail(error);
      });
      const ok = await streamDone;
      if (failure !== null) LumixImportPrototype.logError('media/image', failure);
      const responseMarker = `HTTP_RES seq=${requestSequence} path=/media/image http=${statusCode} business=unavailable elapsedMs=${Date.now() - requestStartedAt} bytes=${received} headers=stream-callback body=binary ok=${ok ? 1 : 0}`;
      trace.push(responseMarker);
      LumixImportPrototype.httpInfo(responseMarker);
      trace.push(`POST /media/image http=${statusCode} bytes=${received} type=${requestType} imageSize=${imageSize} range=${rangeMode ? 'present' : 'absent'} body=json-redacted`);
      LumixImportPrototype.emitTrace(trace);
      if (!ok) {
        discardFile();
        const empty: DownloadAttemptResult = { received: 0, path: '' };
        return empty;
      }
      if (file !== null) {
        fileIo.closeSync(file);
        file = null;
      }
      if (onProgress) onProgress(100, received, expectedSize || received);
      const done: DownloadAttemptResult = { received: received, path: `file://${path}` };
      return done;
    } catch (error) {
      LumixImportPrototype.logError('media/image', error);
      const errorMarker = `HTTP_ERR seq=${requestSequence} path=/media/image code=${LumixImportPrototype.errorCode(error)} status=${statusCode} bytes=${received}`;
      trace.push(errorMarker);
      LumixImportPrototype.httpInfo(errorMarker);
      discardFile();
      const emptyCatch: DownloadAttemptResult = { received: 0, path: '' };
      return emptyCatch;
    } finally {
      if (file !== null) {
        try { fileIo.closeSync(file); } catch (_error) { }
        file = null;
      }
      try { request.off('dataReceive'); } catch (_error) { }
      try { request.off('dataEnd'); } catch (_error) { }
      try { request.off('dataReceiveProgress', progressHandler); } catch (_error) { }
      request.destroy();
    }
  }

  private static requireBusinessSuccess(response: JsonResponse, phase: string, trace: string[]): string {
    if (response.httpStatus < 200 || response.httpStatus >= 300) return '';
    const code = LumixImportPrototype.businessCode(response.body);
    trace.push(`${phase} HTTP=${response.httpStatus}; Header.ResponseCode=${code}`);
    if (code !== 200) return '';
    try {
      const root = JSON.parse(response.body) as AuthEnvelope;
      const data = root.Data;
      const token = data && data.AuthToken ? data.AuthToken : '';
      if (token.length > 0) trace.push(`${phase} token=received length=${token.length} value=redacted`);
      return token;
    } catch (_error) { return ''; }
  }

  private static checkBusinessCode(response: JsonResponse, phase: string, trace: string[]): boolean {
    if (response.httpStatus < 200 || response.httpStatus >= 300) return false;
    const code = LumixImportPrototype.businessCode(response.body);
    trace.push(`${phase} HTTP=${response.httpStatus}; Header.ResponseCode=${code}`);
    return code === 200;
  }

  private static businessCode(body: string): number {
    try {
      const root = JSON.parse(body) as CameraHeaderEnvelope;
      return root.Header && root.Header.ResponseCode !== undefined ? Number(root.Header.ResponseCode) : 0;
    } catch (_error) { return 0; }
  }

  /**
   * High-level HTTP instrumentation.  This deliberately reports shape and
   * size instead of values: the camera token, client UUID, image identifiers,
   * credentials and raw image data never enter HiLog or the returned trace.
   */
  private static nextHttpRequestSequence(): number {
    LumixImportPrototype.httpRequestSequence += 1;
    return LumixImportPrototype.httpRequestSequence;
  }

  private static utf8Length(value: string): number {
    try { return util.TextEncoder.create('utf-8').encode(value).length; } catch (_error) { return value.length; }
  }

  private static summarizeHeaders(headers: Object | undefined): string {
    if (!headers) return 'none';
    try {
      const record = headers as Record<string, Object>;
      const names = Object.keys(record).sort();
      if (names.length === 0) return 'none';
      const parts: string[] = [];
      for (const name of names) {
        const raw = record[name];
        const value = raw === undefined || raw === null ? '' : String(raw);
        const lower = name.toLowerCase();
        if (lower === 'authorization') {
          const quoted = value.length >= 2 && value.charAt(0) === "'" && value.charAt(value.length - 1) === "'" ? 1 : 0;
          parts.push(`${name}=present(len=${value.length},quoted=${quoted})`);
        } else if (lower === 'transid' || lower === 'trans-id' || lower === 'transaction-id') {
          parts.push(`${name}=present(len=${value.length})`);
        } else if (lower === 'accept' || lower === 'content-type' || lower === 'content-length' || lower === 'range') {
          // These framing headers are safe to expose and distinguish JSON,
          // octet-stream and range requests without exposing credentials.
          parts.push(`${name}=${value}`);
        } else {
          parts.push(`${name}=len(${value.length})`);
        }
      }
      return parts.join(',');
    } catch (_error) { return 'unavailable'; }
  }

  private static isSafeRequestField(name: string): boolean {
    const lower = name.toLowerCase();
    return lower === 'currentsd' || lower === 'type' || lower === 'thumbnailcategory' ||
      lower === 'imagesize' || lower === 'startindex' || lower === 'limit';
  }

  private static summarizeJsonBody(body: string | undefined): string {
    if (body === undefined) return 'none';
    if (body.length === 0) return 'empty(len=0)';
    const byteLength = LumixImportPrototype.utf8Length(body);
    try {
      const parsed = JSON.parse(body) as Object;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return `json(len=${byteLength},shape=${Array.isArray(parsed) ? 'array' : 'scalar'})`;
      const record = parsed as Record<string, Object>;
      const fields: string[] = [];
      for (const name of Object.keys(record).sort()) {
        const value = record[name];
        if (LumixImportPrototype.isSafeRequestField(name)) {
          fields.push(`${name}=${String(value)}`);
        } else if (Array.isArray(value)) {
          fields.push(`${name}=array(count=${value.length})`);
        } else if (value !== null && typeof value === 'object') {
          fields.push(`${name}=object`);
        } else {
          fields.push(`${name}=redacted(len=${value === undefined || value === null ? 0 : String(value).length})`);
        }
      }
      return `json(len=${byteLength},fields=${fields.join('|')})`;
    } catch (_error) {
      return `non-json(len=${byteLength})`;
    }
  }

  private static summarizeJsonResponse(body: string): string {
    if (body.length === 0) return 'empty';
    try {
      const parsed = JSON.parse(body) as Object;
      if (parsed === null || typeof parsed !== 'object') return `json(len=${LumixImportPrototype.utf8Length(body)},shape=scalar)`;
      const root = parsed as Record<string, Object>;
      const fields: string[] = [];
      for (const name of Object.keys(root).sort()) {
        const value = root[name];
        if (name === 'Header' && value !== null && typeof value === 'object') {
          const header = value as Record<string, Object>;
          fields.push(`Header{keys=${Object.keys(header).sort().join('|') || 'none'}}`);
        } else if (name === 'Data' && value !== null && typeof value === 'object') {
          const data = value as Record<string, Object>;
          const list = data['DataList'];
          const listCount = Array.isArray(list) ? list.length : -1;
          const token = data['AuthToken'];
          if (token !== undefined) fields.push(`Data{keys=${Object.keys(data).sort().join('|')};AuthToken=present(len=${String(token).length})}`);
          else if (listCount >= 0) fields.push(`Data{keys=${Object.keys(data).sort().join('|')};DataList=count(${listCount})}`);
          else fields.push(`Data{keys=${Object.keys(data).sort().join('|') || 'none'}}`);
        } else if (Array.isArray(value)) {
          fields.push(`${name}=array(count=${value.length})`);
        } else {
          fields.push(`${name}=present`);
        }
      }
      return `json(len=${LumixImportPrototype.utf8Length(body)},fields=${fields.join('|')})`;
    } catch (_error) {
      return `non-json(len=${LumixImportPrototype.utf8Length(body)})`;
    }
  }

  private static businessCodeFromHeader(headers: Object | undefined): string {
    if (!headers) return 'unavailable';
    try {
      const record = headers as Record<string, Object>;
      for (const name of Object.keys(record)) {
        const lower = name.toLowerCase();
        if (lower === 'responsecode' || lower === 'x-response-code') return 'header-present';
      }
    } catch (_error) { }
    return 'unavailable';
  }

  private static httpInfo(message: string): void {
    AppDiagnostics.event('VIVID_HTTP', message);
    try { hilog.info(0x0001, 'VIVID_HTTP', '%{public}s', message); } catch (_error) { }
  }

  /**
   * TEMPORARY diagnostic (2026-10-11). The transfer page shows JPEG cards only
   * while `findImages` is supposed to surface one card per RAW/JPEG record.
   * `summarizeJsonResponse` records only `DataList=count(N)`, which cannot say
   * whether the camera reports RAW at all, so log the schema-level composition
   * of the gallery/info payload: record count, the Type histogram, how many
   * records carry RawSize and how many of those are positive, the union of
   * record key names, and the first few Type:RawSize tokens. Field values other
   * than Type/RawSize and file names are not logged.
   */
  /**
   * TEMPORARY diagnostic (2026-10-11). The tested body answers /media/gallery/info
   * with Type=3 for a RAW+JPEG shot (Size = JPEG bytes, RawSize = RAW bytes),
   * while this client only understands Type=1 (RAW record) and Type=2 (JPEG
   * record). Ask the camera for the first 64 bytes of one ImageId under every
   * candidate Type so the Type to format mapping is measured rather than
   * guessed. Requests are ranged and tiny, so no large transfer can stall the
   * gallery. The first four response bytes identify the container:
   * ffd8ff = JPEG, 49492a00 / 49495500 = little-endian TIFF (RW2).
   */
  private static async probeMediaTypes(host: string, token: string, fingerprint: string, imageId: string): Promise<void> {
    const candidates: number[] = [1, 2, 3, 7];
    for (const candidate of candidates) {
      const request = http.createHttp();
      try {
        const headers: Record<string, string> = {
          'Accept': 'binary/octet-stream',
          'Content-Type': 'application/json',
          'Authorization': LumixImportPrototype.authorizationHeader(token),
          'Range': 'bytes=0-63',
        };
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.POST,
          header: headers,
          connectTimeout: 8000,
          readTimeout: 8000,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          remoteValidation: (validation: http.ValidationContext): Promise<boolean> => LumixImportPrototype.validateCertificate(validation, fingerprint, []),
        };
        const body = JSON.stringify({ ImageId: imageId, Type: candidate, ImageSize: 1 });
        options.body = util.TextEncoder.create('utf-8').encode(body).buffer as ArrayBuffer;
        const response = await request.request(`https://${LumixImportPrototype.cleanHost(host)}/media/image`, options);
        let bytes = 0;
        let magic = '';
        if (typeof response.result !== 'string') {
          const view = new Uint8Array(response.result as ArrayBuffer);
          bytes = view.byteLength;
          const parts: string[] = [];
          for (let offset = 0; offset < view.byteLength && offset < 4; offset++) {
            parts.push((view[offset] < 16 ? '0' : '') + view[offset].toString(16));
          }
          magic = parts.join('');
        }
        LumixImportPrototype.httpInfo(`VIVID_RAWMAP type=${candidate} http=${response.responseCode} bytes=${bytes} magic=${magic}`);
      } catch (error) {
        LumixImportPrototype.httpInfo(`VIVID_RAWMAP type=${candidate} error=${LumixImportPrototype.errorCode(error)}`);
      } finally {
        request.destroy();
      }
    }
  }

  private static probeGalleryInfo(body: string): void {
    try {
      const root = JSON.parse(body) as Object;
      let records = 0;
      let type1 = 0;
      let type2 = 0;
      let typeOther = 0;
      let rawSizeKeyed = 0;
      let rawSizePositive = 0;
      const keys: string[] = [];
      const tokens: string[] = [];
      const names: string[] = [];
      const visit = (value: Object | Array<Object> | string | number | boolean | null): void => {
        if (value === null || value === undefined) return;
        if (Array.isArray(value)) {
          const list = value as Array<Object>;
          for (let index = 0; index < list.length; index++) visit(list[index]);
          return;
        }
        if (typeof value !== 'object') return;
        const item = value as Record<string, Object>;
        const id = item['ImageId'];
        if (typeof id === 'string' && id.length > 0) {
          records += 1;
          const type = Number(item['Type']);
          if (type === 1) {
            type1 += 1;
          } else if (type === 2) {
            type2 += 1;
          } else {
            typeOther += 1;
          }
          const rawValue = item['RawSize'];
          const hasRawKey = rawValue !== undefined && rawValue !== null;
          const rawNumber = Number(rawValue);
          if (hasRawKey) rawSizeKeyed += 1;
          if (hasRawKey && Number.isFinite(rawNumber) && rawNumber > 0) rawSizePositive += 1;
          for (const name of Object.keys(item)) {
            if (keys.indexOf(name) < 0) keys.push(name);
          }
          if (tokens.length < 12) {
            tokens.push(`${Number.isFinite(type) ? type : 'NaN'}:${hasRawKey ? rawNumber : 'absent'}`);
          }
          if (names.length < 3) {
            const fileName = item['OriginalFileName'];
            names.push(typeof fileName === 'string' ? fileName : '(none)');
          }
        }
        for (const name of Object.keys(item)) visit(item[name] as Object);
      };
      visit(root);
      LumixImportPrototype.httpInfo(`VIVID_RAWDBG gallery-info records=${records} type1=${type1} type2=${type2} typeOther=${typeOther} rawSizeKeyed=${rawSizeKeyed} rawSizePositive=${rawSizePositive} keys=${keys.sort().join('|')} tokens=${tokens.join(',')} names=${names.join(',')}`);
    } catch (error) {
      LumixImportPrototype.httpInfo(`VIVID_RAWDBG gallery-info parse-failed code=${LumixImportPrototype.errorCode(error)}`);
    }
  }

  /** TEMPORARY diagnostic (2026-10-11): Type histogram of a parsed page. */
  private static probeGalleryItems(stage: string, images: GalleryImage[]): void {
    let type1 = 0;
    let type2 = 0;
    let typeOther = 0;
    for (const image of images) {
      if (image.Type === 1) {
        type1 += 1;
      } else if (image.Type === 2) {
        type2 += 1;
      } else {
        typeOther += 1;
      }
    }
    LumixImportPrototype.httpInfo(`VIVID_RAWDBG page stage=${stage} total=${images.length} type1=${type1} type2=${type2} typeOther=${typeOther}`);
  }

  /**
   * 记录起点下标。findImages 会把 RAW+JPEG 一条记录拆成 JPEG 条目 + 紧跟其
   * 后的 RAW 条目，所以条目数不再等于记录数，而相机的 StartIndex 游标是按
   * 记录走的。分窗必须按记录，否则「6 条」会变成 3 张照片，翻页游标与窗口
   * 也会错位。
   */
  private static recordStartIndices(images: GalleryImage[]): number[] {
    const starts: number[] = [];
    for (let index = 0; index < images.length; index++) {
      if (images[index].GroupedWithPrevious !== true) starts.push(index);
    }
    return starts;
  }

  /** 保留最新的 limit 条记录（含各自的 RAW 伴随条目）。 */
  private static takeNewestRecords(images: GalleryImage[], limit: number): GalleryImage[] {
    const starts = LumixImportPrototype.recordStartIndices(images);
    if (starts.length <= limit) return images;
    return images.slice(starts[starts.length - limit]);
  }

  /** 保留最旧的 limit 条记录（含各自的 RAW 伴随条目）。 */
  private static takeOldestRecords(images: GalleryImage[], limit: number): GalleryImage[] {
    const starts = LumixImportPrototype.recordStartIndices(images);
    if (starts.length <= limit) return images;
    return images.slice(0, starts[limit]);
  }

  private static findImages(body: string): GalleryImage[] {
    try {
      const root = JSON.parse(body) as Object;
      // Key: ImageId + ':' + Type. RAW+JPEG 双记录不再合并——同一次拍摄的
      // Type=2（JPEG）与 Type=1（RW2）各自成为独立图库条目，传输页才能
      // 同时显示 JPG 与 RW2 卡片。仅完全相同的记录（同 Id 同 Type）去重。
      const dedup = new Map<string, GalleryImage>();
      const visit = (value: Object | Array<Object> | string | number | boolean | null): void => {
        if (value === null || value === undefined) return;
        if (Array.isArray(value)) {
          const list = value as Array<Object>;
          for (let index = 0; index < list.length; index++) visit(list[index]);
          return;
        }
        if (typeof value !== 'object') return;
        const item = value as Record<string, Object>;
        const rawId = item['ImageId'];
        if (typeof rawId === 'string' && rawId.length > 0) {
          const rawType = item['Type'];
          const rawSize = item['Size'];
          const rawRawSize = item['RawSize'];
          const rawName = item['OriginalFileName'];
          const type = typeof rawType === 'number' ? rawType : Number(rawType);
          const size = typeof rawSize === 'number' ? rawSize : Number(rawSize);
          const declaredRawSize = typeof rawRawSize === 'number' ? rawRawSize : Number(rawRawSize);
          const name = typeof rawName === 'string' ? rawName : '';
          const key = `${rawId}:${type}`;
          const existing = dedup.get(key);
          if (existing) {
            // 同 Id 同 Type 的重复视图：补齐缺失字段即可。
            if ((existing.Size ?? 0) <= 0 && size > 0) existing.Size = size;
            if ((existing.RawSize ?? 0) < declaredRawSize) existing.RawSize = declaredRawSize;
            if ((existing.OriginalFileName ?? '').length === 0 && name.length > 0) {
              existing.OriginalFileName = name;
            }
          } else {
            dedup.set(key, {
              ImageId: rawId,
              Type: type,
              Size: size,
              RawSize: declaredRawSize,
              OriginalFileName: name,
            });
          }
        }
        for (const key of Object.keys(item)) visit(item[key] as Object);
      };
      visit(root);
      const parsed: GalleryImage[] = [];
      dedup.forEach((image: GalleryImage) => parsed.push(image));

      // 归一化相机的 Type，并就地拆出 RAW 条目。
      //
      // 现场实测（DC-S1RM2，2026-10-11）：一次 RAW+JPEG 拍摄只回一条记录，
      // Type=3，OriginalFileName 是 JPEG 名（P2216521.JPG），Size 是 JPEG 字节
      // 数，RawSize 是 RAW 字节数（约 51-54 MB）。而 VIVID 原先全链路只认
      // 「Type=2 是 JPEG、其余当 RAW」，于是 Type=3 被当成 RAW：卡片命名成
      // .RW2、请求发 Type=3（相机对 1/3/7 一律返回 RAW）、按 RawSize 期望 53 MB
      // 而实收正好就是 RAW 本身——用户点 JPG 卡拿到的就是 RW2，且 JPEG 一次
      // 都没有被请求。
      //
      // 这里一次性收敛：Type=3 判为「这张拍摄的 JPEG」，Type=7 是 RAW 的另一
      // 种写法，随后把 RAW 拆成独立条目紧跟在它的 JPEG 之后，让传输页同时看到
      // JPG 与 RW2 卡片。归一化之后下游所有既有的 imageType === 2 / !== 2 判断
      // 自然成立，downloadOriginal 也不用改：JPEG 卡发 Type=2，RAW 卡发 Type=1。
      const rawIds = new Set<string>();
      for (const image of parsed) {
        if (image.Type === LUMIX_TYPE_RAW || image.Type === LUMIX_TYPE_RAW_ALT) {
          rawIds.add(image.ImageId ?? '');
        }
      }
      const result: GalleryImage[] = [];
      for (const image of parsed) {
        const imageId = image.ImageId ?? '';
        if (image.Type === LUMIX_TYPE_RAW_ALT) {
          // 7 是 RAW 的另一种写法，下游统一按 1 处理。
          result.push({
            ImageId: imageId,
            Type: LUMIX_TYPE_RAW,
            Size: image.Size ?? 0,
            RawSize: image.RawSize ?? 0,
            OriginalFileName: image.OriginalFileName,
          });
          continue;
        }
        if (image.Type !== LUMIX_TYPE_JPEG && image.Type !== LUMIX_TYPE_RAW_JPEG) {
          // 其它类型（例如 6=HEIF）原样透传。
          result.push(image);
          continue;
        }
        const rawSize = image.RawSize ?? 0;
        // RAW 已经作为单独记录出现时不再拆，否则这条 JPEG 自己带 RawSize。
        const needsSplit = rawSize > 0 && !rawIds.has(imageId);
        result.push({
          ImageId: imageId,
          Type: LUMIX_TYPE_JPEG,
          Size: image.Size ?? 0,
          // RawSize 归零：JPG 卡只下载 JPEG，RAW 由它自己那张卡负责。原先
          // RawSize>0 会让 JPG 卡顺带下载 RAW，一次点击落两个文件，正是用户
          // 反馈过的那种意外。
          RawSize: 0,
          OriginalFileName: image.OriginalFileName,
        });
        if (!needsSplit) continue;
        const baseName = (image.OriginalFileName ?? '').trim();
        const dot = baseName.lastIndexOf('.');
        const stem = dot > 0 ? baseName.substring(0, dot) : baseName;
        result.push({
          ImageId: imageId,
          Type: LUMIX_TYPE_RAW,
          Size: rawSize,
          // 保留真实 RAW 长度：downloadRanged 用它做精确分窗与完整性断言。
          RawSize: rawSize,
          OriginalFileName: stem.length > 0 ? `${stem}.RW2` : '',
          GroupedWithPrevious: true,
        });
      }
      return result;
    } catch (_error) { return []; }
  }
  private static galleryCount(body: string): number {
    try {
      const root = JSON.parse(body) as Object;
      let count = 0;
      const visit = (value: Object | Array<Object> | string | number | boolean | null): void => {
        if (value === null || value === undefined || count > 0) return;
        if (Array.isArray(value)) {
          const list = value as Array<Object>;
          for (let index = 0; index < list.length; index++) visit(list[index]);
          return;
        }
        if (typeof value !== 'object') return;
        const item = value as Record<string, Object>;
        for (const key of ['Count', 'TotalCount', 'ImageCount', 'FileCount']) {
          const raw = item[key];
          const parsed = typeof raw === 'number' ? raw : Number(raw);
          if (Number.isFinite(parsed) && parsed > 0) {
            count = Math.floor(parsed);
            return;
          }
        }
        for (const key of Object.keys(item)) visit(item[key] as Object);
      };
      visit(root);
      return count;
    } catch (_error) {
      return 0;
    }
  }

  private static cleanHost(host: string): string {
    return host.trim().replace(/^https?:\/\//, '').replace(/\/$/, '');
  }

  /**
   * LUMIX Lab's local Retrofit request builder includes literal single quotes
   * around the Bearer value (`'Bearer <token>'`).  Keep this separate from the
   * auth response parsing so every camera-local endpoint uses the same wire
   * representation and the unauthenticated /auth request remains unchanged.
   */
  private static authorizationHeader(token: string): string {
    return `'Bearer ${token}'`;
  }

  private static selectHost(hostOverride: string, gateway: string, trace: string[]): string {
    // The gateway is read after DHCP on the current camera AP. Prefer it over
    // the UI's last value so a stale address cannot send HTTPS to a previous
    // network after the user accepts the system Wi-Fi prompt.
    if (gateway.length > 0) {
      trace.push(`HTTPS host source=Wi-Fi gateway value=${LumixImportPrototype.redactHost(gateway)}`);
      return gateway;
    }
    const override = LumixImportPrototype.cleanHost(hostOverride);
    if (override.length > 0) {
      trace.push(`HTTPS host source=explicit override value=${LumixImportPrototype.redactHost(override)}`);
      return override;
    }
    return '';
  }

  private static uuidBytes(uuid: string): Uint8Array {
    const hex = uuid.replace(/-/g, '');
    const bytes = new Uint8Array(16);
    for (let index = 0; index < bytes.length; index++) bytes[index] = parseInt(hex.substring(index * 2, index * 2 + 2), 16) || 0;
    return bytes;
  }

  /** C5/I2.d: one-byte UTF-8 length prefix, zero padding to a 4-byte block,
   * and 0xff fill for the final block padding. */
  private static encodeProtocolString(value: Uint8Array): Uint8Array {
    const length = value.length;
    const blockPad = length % 4 === 0 ? 0 : 4 - (length % 4);
    let total = length + blockPad + 1;
    const finalPad = total % 4 === 0 ? 0 : 4 - (total % 4);
    total += finalPad;
    const output = new Uint8Array(total);
    output.fill(0xff);
    output[0] = length & 0xff;
    output.set(value, 1);
    for (let index = 0; index < blockPad; index++) output[1 + length + index] = 0;
    return output;
  }

  /** C5/I2.e: reverse every 4-byte block and XOR with INITIAL_INFORM[0..3]. */
  private static xorReverseWithInitial(initialInform: ArrayBuffer, encoded: Uint8Array): Uint8Array {
    const key = new Uint8Array(initialInform);
    if (key.length < 4 || encoded.length % 4 !== 0) throw new Error('INITIAL_INFORM is too short for app registration');
    const output = new Uint8Array(encoded.length);
    for (let offset = 0; offset < encoded.length; offset += 4) {
      output[offset] = encoded[offset + 3] ^ key[0];
      output[offset + 1] = encoded[offset + 2] ^ key[1];
      output[offset + 2] = encoded[offset + 1] ^ key[2];
      output[offset + 3] = encoded[offset] ^ key[3];
    }
    return output;
  }

  private static paddedUtf8(value: string, length: number): Uint8Array {
    const encoded = util.TextEncoder.create('utf-8').encode(value);
    const output = new Uint8Array(length);
    output.set(encoded.slice(0, length));
    return output;
  }

  private static ipv4(value: number): string {
    if (!Number.isFinite(value) || value <= 0) return '';
    // Harmony's WifiIpInfo exposes the IPv4 integer in the platform's
    // network-order representation. The previous low-byte-first conversion
    // reversed DHCP values (192.168.54.10 became 10.54.168.192), which then
    // made HTTPS target the wrong host and allowed the no-internet route to
    // be torn down before the camera request completed.
    return `${(value >>> 24) & 0xff}.${(value >>> 16) & 0xff}.${(value >>> 8) & 0xff}.${value & 0xff}`;
  }

  private static shortId(value: string): string {
    if (value.length <= 6) return value;
    return `…${value.substring(value.length - 6)}`;
  }

  private static redactHost(value: string): string {
    return value.replace(/(\d+\.\d+\.\d+)\.\d+$/, '$1.x');
  }

  private static safeHex(bytes: Uint8Array): string {
    return Array.from(bytes).map((value: number) => value.toString(16).padStart(2, '0')).join('');
  }

  public static errorCode(error: Object): string {
    try {
      const code = (error as ErrorWithCode).code;
      return code === undefined ? 'unknown' : String(code);
    } catch (_error) {
      return 'unknown';
    }
  }

  private static redactGattValue(uuid: string, bytes: Uint8Array): string {
    const lower = uuid.toLowerCase();
    if (lower === UUID_ACTION_MODE || lower === UUID_AP_STATE || lower === UUID_ACTION_MODE_RESULT) return LumixImportPrototype.safeHex(bytes);
    // LUT 401 排查（官方逐字节 diff）：种子、注册三写的明文 hex 临时入日志，
    // 与 WEB-W00 插桩 dump 对照后恢复脱敏。Wi-Fi 密码与证书指纹保持脱敏。
    if (lower === UUID_INITIAL_INFORM || lower === UUID_APP_UUID || lower === UUID_APP_INFO || lower === UUID_FRIENDLY_NAME) {
      return `clear=${LumixImportPrototype.safeHex(bytes)}`;
    }
    if (lower === UUID_WIFI_PASSWORD || lower === UUID_CERT_FINGERPRINT) return 'redacted-sensitive';
    // Nikon LSS 特征（服务 UUID 以 3dd4-4255-8d62-6dc7b9bd5561 结尾）和设备信息服务
    // （0000180a）的读取值原样入日志。
    //
    // 官方日志已经证明：配对是一次**经典（BR/EDR）**绑定——`BTM_SecBond ...
    // transport 1` → `WAIT_NUM_CONFIRM`（数字比对），对象是相机的经典地址
    // `A0:CD:F3:44:xx:AD`，而相机广播的 BLE 地址是 `D3:D1:C9:84:xx:8F`，两者毫无
    // 关系（同一时刻 BLE 侧记录明确写着 is_bonded:false）。我们几十轮一直拿 BLE
    // 地址调 pairDevice，相机没有对应的经典链路，于是退化成 just-works
    // （passkey=0）、不出码、直接回滚 NONE(0)。
    //
    // 相机的经典地址只能由它自己告诉我们，而这几条 LSS 读取（0x2003 设备名 32B、
    // 0x200B 序列号 8B）一直是被下面那行 `<=4 ? hex : redacted` 盖住的。现在有
    // 了明确的搜索目标：OUI `A0:CD:F3`，且要注意它可能倒序存放（`F3:CD:A0`）。
    if (lower.endsWith('-3dd4-4255-8d62-6dc7b9bd5561') || lower.startsWith('0000180a-')) {
      return LumixImportPrototype.safeHex(bytes);
    }
    return bytes.length <= 4 ? LumixImportPrototype.safeHex(bytes) : 'redacted';
  }

  /** Android's verifier hashes the DER encoding of the leaf certificate.
   * Harmony's publicKeyHash pinning option hashes a different object, so the
   * API-26 validation callback performs the same DER/SHA-256 comparison. */
  private static async validateCertificate(validation: http.ValidationContext, expectedBase64: string, trace: string[]): Promise<boolean> {
    try {
      const x509Certs = validation.x509Certs || [];
      const pemCerts = validation.pemCerts || [];
      trace.push(`TLS validation context x509=${x509Certs.length} pem=${pemCerts.length}`);
      let derBytes: Uint8Array;
      if (x509Certs.length > 0) {
        const encoded = await x509Certs[0].getEncoded();
        derBytes = encoded.data;
      } else if (pemCerts.length > 0) {
        // API-26 devices may expose the peer chain as PEM without materializing
        // X509Cert objects. Decode the first (leaf) PEM certificate locally.
        const pemBody = pemCerts[0].replace(/-----BEGIN CERTIFICATE-----/g, '')
          .replace(/-----END CERTIFICATE-----/g, '').replace(/\s/g, '');
        derBytes = new util.Base64Helper().decodeSync(pemBody);
      } else {
        trace.push('TLS certificate validation result=no-peer-certificate');
        return false;
      }
      const md = cryptoFramework.createMd('SHA256');
      await md.update({ data: derBytes });
      const digest = await md.digest();
      const expected = new util.Base64Helper().decodeSync(expectedBase64);
      if (digest.data.length !== expected.length) {
        trace.push(`TLS certificate validation result=length-mismatch digest=${digest.data.length} expected=${expected.length}`);
        return false;
      }
      let matched = true;
      for (let index = 0; index < digest.data.length; index++) {
        if (digest.data[index] !== expected[index]) {
          matched = false;
          break;
        }
      }
      trace.push(`TLS certificate validation result=${matched ? 'match' : 'mismatch'} digest=${digest.data.length} expected=${expected.length}`);
      return matched;
    } catch (error) {
      LumixImportPrototype.logError('certificate validation', error);
      return false;
    }
  }

  private static logError(scope: string, error: Object): void {
    AppDiagnostics.exception('VIVID_BLE', scope, error);
    // 原始文本另进应用日志：AppDiagnostics 只留结构化枚举，真机复现时看不出
    // 是哪一步断的。「问题反馈 → 发送日志」上传的是 AppLogStore 的落盘文件，
    // hilog 用户读不到也传不上来。
    AppLogSink.emit('CTL_ERR', `${scope} code=${LumixImportPrototype.errorCode(error)}`);
    try {
      // Error codes are needed to distinguish a malformed candidate config from
      // a user refusal, but never include the exception text or credentials.
      hilog.error(0x0001, 'VIVID_BLE', '%{public}s code=%{public}s', scope, LumixImportPrototype.errorCode(error));
    } catch (_ignored) { }
  }

  /** Emit a short, non-sensitive runtime marker for on-device diagnosis. */
  private static runtimeInfo(message: string): void {
    AppDiagnostics.event('VIVID_BLE', message);
    // AppDiagnostics 会把认不出的 message 整条丢弃（stage==='unknown'），
    // 所以这里同时原文进应用日志，保证反馈上传里能看到这一行。
    AppLogSink.emit('CTL', message);
    try {
      // Keep the domain in the documented application range.  The previous
      // diagnostic domain was outside the range accepted by some API 26
      // builds, which made a working scan look silent in HiLog.
      hilog.info(0x0001, 'VIVID_BLE', '%{public}s', message);
    } catch (_ignored) { }
  }

  private static emitTrace(trace: string[]): void {
    for (const entry of trace) {
      AppDiagnostics.event('VIVID_BLE', entry);
      AppLogSink.emit('CTL', entry);
    }
    try {
      for (const entry of trace) hilog.info(0x0001, 'VIVID_BLE', '%{public}s', entry);
    } catch (_ignored) { }
  }

  private static waitForWifiScan(requestScan: boolean): Promise<void> {
    return new Promise<void>((resolve) => {
      let finished = false;
      let timer = -1;
      const onScan = (_state: number): void => { finish(); };
      const finish = (): void => {
        if (finished) return;
        finished = true;
        if (timer !== -1) clearTimeout(timer);
        try { wifiManager.off('wifiScanStateChange', onScan); } catch (_error) { }
        resolve();
      };
      try { wifiManager.on('wifiScanStateChange', onScan); } catch (_error) { }
      timer = setTimeout(finish, 250);
      if (requestScan) {
        try { wifiManager.startScan(); } catch (_error) {
          try { wifiManager.scan(); } catch (_ignored) { }
        }
      }
    });
  }

  static delay(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => setTimeout(resolve, milliseconds));
  }
}
