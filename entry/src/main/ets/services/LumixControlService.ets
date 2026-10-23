import { connection, http, socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';
import { LumixCameraService } from './LumixCameraService';
import { DtlsClient } from './DtlsClient';
import { LumixImportPrototype } from './LumixImportPrototype';
import { AppDiagnostics } from './AppDiagnostics';
import { LumixLutSlot } from './LumixLutService';

/**
 * LUMIX remote-shooting client (Wi-Fi AP mode, https://<gateway>/remote/*).
 *
 * Independent protocol line next to the image-transfer and LUT clients: it
 * keeps its own session token and persisted client UUID and never touches
 * the state of the other adapters. Only the read-only Wi-Fi link helpers of
 * LumixCameraService are shared.
 *
 * Wire shape (protocol report 2026-09-18, dex + raw-frame verified):
 * - POST /remote/camcmd        {"Command":"<cmd>"}                 -> {Data:{Result}}
 * - POST /remote/set-setting   {"Type","Value","Value2"?}          -> {Data:{Result}}
 * - POST /remote/get-setting   {"Type":"<key>"}                    -> {Data:{DataList:[...]}}
 * - POST /remote/get-state     {}                                  -> {Data:{...33 fields}}
 * - POST /remote/camctrl       {"Type":"touch","Value":"x/y","Value2":"on|off"}
 * - POST /remote/start-stream  {"UDPPortNumber":<local udp port>}  -> {Data:{Result}}
 * - POST /remote/get-lvport    {}                                  -> {Data:{LvPort}}
 * - POST /remote/stop-stream   {}                                  -> 403 err_critical when idle
 * - POST /lut/info             {}                                  -> {Data:{DataList:[41 slots]}}
 * - POST /lut/set-display-setting {"LutId","Visibility":0|1}       -> {Data:{Result}}
 *
 * The liveview stream is DTLS 1.2 over UDP; each decrypted application-data
 * record IS one Panasonic fragment (32-byte big-endian header + metadata +
 * JPEG slice, no RTP layer — verified against live decrypts 2026-09-19:
 * header[0..1] = fragment total length = record size, magic at offset 9).
 * Fragments are
 * reassembled (seq 0..N, reset marker 0xffffffff is self-contained) and the
 * Q0 metadata block is walked with a cursor parser whose offsets were verified
 * byte-by-byte against real captured frames (iso is a 4-byte word at settings
 * block offset 4; the block is 75 bytes although numSettingValue only counts
 * 73 — focusStacking/cropZoom sit beyond the count).
 */

/** An authenticated remote-control session on the camera access point. */
export interface LumixControlSession {
  host: string;
  ssid: string;
  token: string;
  /**
   * Optional persistent HTTP client for the streaming-critical calls
   * (start-stream/get-lvport/get-state). Official keeps ONE keep-alive TCP
   * connection alive across these; if the start-stream TCP closes, the camera
   * may tear the liveview stream down with it.
   */
  controlClient?: http.HttpRequest;
}

/** Stage of a control-session failure, used by the UI for classification. */
export type LumixControlErrorKind = 'wifi' | 'ssid' | 'gateway' | 'auth' | 'http';

/** A control-protocol failure tagged with the stage where it happened. */
export class LumixControlError extends Error {
  readonly kind: LumixControlErrorKind;
  /** Camera business code from the response envelope when available (e.g. 403). */
  readonly code: number;

  constructor(kind: LumixControlErrorKind, message: string, code: number = 0) {
    super(message);
    this.kind = kind;
    this.code = code;
  }
}

/** One selectable option shown in a dropdown panel. */
export interface LumixSettingOption {
  /** Wire value exactly as it must be sent back via set-setting. */
  value: string;
  label: string;
}

/** Subset of the 33-field /remote/get-state heartbeat the UI reacts to. */
export class LumixCameraState {
  cammode: string = '';
  sdAccess: boolean = false;
  sd2Access: boolean = false;
  sdFull: boolean = false;
  sd2Full: boolean = false;
  currentSd: string = '';
  cameraOperating: boolean = false;
}

/** One decoded liveview frame handed to the UI. */
export interface LumixLiveviewFrame {
  jpeg: ArrayBuffer;
  width: number;
  height: number;
  info: LumixLiveviewInfo;
}

/**
 * Realtime display state parsed from the Q0 metadata block of a liveview
 * frame. Labels are pre-formatted; raw numbers are kept for option matching.
 * @Observed/@Track：Sync 线轮询（getsetting）直接给字段赋值，普通类
 * 属性赋值不触发 UI 刷新——2026-09-28 ISO/WB 恒显 '--' 的根因。
 * 注意：@Observed 类的全部字段都必须是 @Track——UI 上下文访问未
 * @Track 属性会抛 "Illegal usage of not @Track'ed property"（2026-09-28
 * Lab 相机控制页卡死/点参数闪退的真凶，dtls decrypt fail #500）。
 */
@Observed
export class LumixLiveviewInfo {
  @Track modeLabel: string = '--';
  @Track evLabel: string = '0.0';
  @Track shutterLabel: string = '--';
  @Track apertureLabel: string = '--';
  @Track isoLabel: string = '--';
  @Track wbLabel: string = '--';
  @Track qualityLabel: string = '--';
  @Track aspectLabel: string = '--';
  @Track meteringLabel: string = '--';
  @Track lvQualityLabel: string = '--';
  @Track photoStyleLabel: string = '--';
  @Track pictureFormatLabel: string = '--';
  @Track operateRemote: boolean = false;
  // Raw values (camera encoding) for dropdown highlight matching.
  @Track modeValue: number = -1;
  @Track evThirds: number = 0;
  @Track tvCur256: number = -1;
  @Track avCur256: number = -1;
  @Track isoValue: number = -1;
  @Track wbValue: number = -1;
  @Track qualityValue: number = -1;
  @Track aspectValue: number = -1;
  @Track meteringValue: number = -1;
  @Track lvQualityValue: number = -1;
  @Track photoStyleValue: number = -1;
  @Track pictureFormatValue: number = -1;
  @Track zoomPos: number = -1;
  @Track focusDistance: number = -1;

  /** True when every displayed field matches, so the UI can skip re-render. */
  sameAs(other: LumixLiveviewInfo): boolean {
    return this.modeLabel === other.modeLabel && this.evLabel === other.evLabel &&
      this.shutterLabel === other.shutterLabel && this.apertureLabel === other.apertureLabel &&
      this.isoLabel === other.isoLabel && this.wbLabel === other.wbLabel &&
      this.qualityLabel === other.qualityLabel && this.aspectLabel === other.aspectLabel &&
      this.meteringLabel === other.meteringLabel && this.lvQualityLabel === other.lvQualityLabel &&
      this.photoStyleLabel === other.photoStyleLabel &&
      this.pictureFormatLabel === other.pictureFormatLabel &&
      this.operateRemote === other.operateRemote;
  }
}

// ---------------------------------------------------------------------------
// Value tables (official assets/*_list.json, report section 10)
// ---------------------------------------------------------------------------

/** "0x" + at least 4 lowercase hex digits. */
export function hexWord(v: number): string {
  let s = (v >>> 0).toString(16);
  while (s.length < 4) {
    s = '0' + s;
  }
  return '0x' + s;
}

/** "0x" + 2 lowercase hex digits (byte-width values like liveviewsize). */
export function hexByte(v: number): string {
  let s = (v >>> 0).toString(16);
  while (s.length < 2) {
    s = '0' + s;
  }
  return '0x' + s;
}

/** Parse a camera option string like "0x0640"; NaN when not hex-encoded. */
export function parseHexValue(raw: string): number {
  const t = raw.trim().toLowerCase();
  if (t.length < 3 || t.charAt(0) !== '0' || t.charAt(1) !== 'x') {
    return Number.NaN;
  }
  const n = Number.parseInt(t.substring(2), 16);
  return Number.isFinite(n) ? n : Number.NaN;
}

/** Numerator of a "N/256" fixed-point option, 16-bit sign extended. */
export function shutterNumerator(raw: string): number {
  const parts = raw.split('/');
  if (parts.length !== 2) {
    return Number.NaN;
  }
  let n = Number.parseInt(parts[0], 10);
  if (!Number.isFinite(n)) {
    return Number.NaN;
  }
  if (n >= 0x8000 && n <= 0xffff) {
    n -= 0x10000;
  }
  return n;
}

const SHUTTER_DENS: number[] =
  [1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6.4, 8, 10, 13, 16, 20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200,
    250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000];
const SHUTTER_SECS: number[] =
  [0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6.4, 8, 10, 13, 16, 20, 25, 32, 40, 50, 64];
const APERTURES: number[] =
  [1, 1.1, 1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.8, 3.2, 3.5, 4, 4.5, 5, 5.6, 6.3, 7.1, 8, 9, 10, 11,
    13, 14, 16, 18, 20, 22, 25, 29, 32];

function nearestIndex(x: number, values: number[]): number {
  let best = 0;
  let bestDist = Number.MAX_VALUE;
  for (let i = 0; i < values.length; i++) {
    const dist = Math.abs(Math.log(x / values[i]));
    if (dist < bestDist) {
      bestDist = dist;
      best = i;
    }
  }
  return best;
}

function trimNumber(v: number): string {
  const s = v.toFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/** APEX Tv x256 (signed; negative = slow shutter) -> "1/250" or "1.3\"" label. */
export function formatShutter(tv256: number): string {
  if (!Number.isFinite(tv256)) {
    return '--';
  }
  const tv = tv256 / 256;
  const seconds = Math.pow(2, -tv);
  if (seconds <= 0.35) {
    const den = SHUTTER_DENS[nearestIndex(1 / seconds, SHUTTER_DENS)];
    return `1/${trimNumber(den)}`;
  }
  const sec = SHUTTER_SECS[nearestIndex(seconds, SHUTTER_SECS)];
  return `${trimNumber(sec)}"`;
}

/** Label for a "N/256" shtrspeed option (N is APEX Tv x256, 16-bit signed). */
export function shutterOptionLabel(raw: string): string {
  const n = shutterNumerator(raw);
  if (!Number.isNaN(n)) {
    return formatShutter(n);
  }
  const hex = parseHexValue(raw);
  if (!Number.isNaN(hex)) {
    return formatShutterWord(hex);
  }
  return raw;
}

/** tethr / libgphoto2 里 `ShutterSpeed` 的自动哨兵（读值 0x0FFFFFFF、写值 0x0FFFFFFE）。 */
const SHUTTER_WORD_BULB = 0xFFFFFFFF;
const SHUTTER_WORD_AUTO_R = 0x0FFFFFFF;
const SHUTTER_WORD_AUTO_W = 0x0FFFFFFE;

/**
 * Panasonic 的 32 位快门编码（**毫秒**，不是微秒）。
 *
 * 依据：Tethr（MIT）`TethrPanasonic.ts` 与 libgphoto2 的 `ShutterSpeed`
 * 属性说明，两份独立的公开实现一致：
 *   - `0xFFFFFFFF` → B 门
 *   - `0x0FFFFFFF`(读) / `0x0FFFFFFE`(写) → 自动
 *   - bit31 = 0 → 分数档，分母 = 值 / 1000（`0x0001F4`=500 → 1/500）
 *   - bit31 = 1 → 秒，秒数 = (值 & 0x7FFFFFFF) / 1000（`0x800009C4` → 2.5"）
 *
 * 所以 S1RM2 实测的 `0x00001F40` 是 **1/8"**、`0x007A1200` 是 1/8000"。
 * 注意 bit31 不是"可掩掉的标志位"：`0x00000640`(1/1.6") 与 `0x80000640`(1.6")
 * 是两个**不同的**快门档，掩掉就会把秒档错算成分数档。
 */
export function formatShutterWord(word: number): string {
  if (!Number.isFinite(word)) {
    return '--';
  }
  const v = word >>> 0;
  if (v === SHUTTER_WORD_BULB) {
    return 'B';
  }
  if (v === SHUTTER_WORD_AUTO_R || v === SHUTTER_WORD_AUTO_W) {
    return '自动';
  }
  const milli = v & 0x7FFFFFFF;
  if (milli === 0) {
    return '--';
  }
  const seconds = milli / 1000;
  if ((v & 0x80000000) !== 0) {
    return `${trimNumber(seconds)}"`;
  }
  // 分数档：值 = 分母 × 1000，分母可能是 2.5 / 1.6 这类非整数
  return `1/${trimNumber(seconds)}`;
}

/** APEX Av x256 -> "F4.5" style label. */
export function formatAperture(av256: number): string {
  if (av256 < 0 || !Number.isFinite(av256)) {
    return '--';
  }
  const f = Math.pow(2, (av256 / 256) / 2);
  const snapped = APERTURES[nearestIndex(f, APERTURES)];
  return 'F' + trimNumber(snapped);
}

/** Number of stops in the standard 1/3-stop aperture display list. */
export const APERTURE_STOP_COUNT: number = APERTURES.length;

/** Index of an APEX Av x256 value in the aperture display list; -1 when unknown. */
export function apertureIndexOf(av256: number): number {
  if (av256 < 0 || !Number.isFinite(av256)) {
    return -1;
  }
  const f = Math.pow(2, (av256 / 256) / 2);
  return nearestIndex(f, APERTURES);
}

/** Exposure compensation in 1/3 EV steps -> "+0.7" style label. */
export function formatEv(thirds: number): string {
  if (thirds === 0) {
    return '0.0';
  }
  const sign = thirds < 0 ? '-' : '+';
  return sign + (Math.abs(thirds) / 3).toFixed(1);
}

/** Wire value for an exposure compensation of `thirds` 1/3-EV steps. */
export function evOptionValue(thirds: number): string {
  return hexWord(thirds < 0 ? (0x8000 | (-thirds)) : thirds);
}

/** Thirds value decoded back from an exposure option word. */
export function evThirdsOf(value: number): number {
  if (value === 0xffff) {
    return 0;
  }
  return (value & 0x8000) !== 0 ? -(value & 0x7fff) : value;
}

/** ISO word (0xffffffff = AUTO) -> label. */
export function isoLabelOf(v: number): string {
  if (v === 0xffffffff) {
    return 'AUTO';
  }
  if (v <= 0) {
    return '--';
  }
  return String(v);
}

export function qualityLabelOf(v: number): string {
  switch (v) {
    case 0x0000: return 'JPG FINE';
    case 0x0001: return 'JPG STD.';
    case 0x0003: return 'RAW';
    case 0x0004: return 'RAW+FINE';
    case 0x0005: return 'RAW+STD.';
    default: return v === 0xffff ? '--' : hexWord(v);
  }
}

/** S1RM2 pictureformat（存储格式）标签：官方 get-setting 值域
 *  （协议文档 §11/§18：0x0000=JPEG/HEIF、0x0001=RAW+JPEG/HEIF、0x0002=RAW）。 */
export function pictureFormatLabelOf(v: number): string {
  switch (v) {
    case 0x0000: return 'JPEG/HEIF';
    case 0x0001: return 'RAW+JPEG/HEIF';
    case 0x0002: return 'RAW';
    default: return v === 0xffff ? '--' : hexWord(v);
  }
}

/** /lut/info 槽位 PhotoStyle 名 → photostyle 设置值（协议文档 §11 36 项表
 *  + §18 S1RM2 实测）。S1RM2 无 /lut/set-display-setting，官方对内置风格
 *  LUT（LutType=1）改走 set-setting photostyle（VIVID=0x0001 实证）。 */
export function photoStyleValueOf(name: string): string {
  const key = name.trim().toUpperCase();
  switch (key) {
    case 'STD':
    case 'STANDARD': return '0x0000';
    case 'VIVID': return '0x0001';
    case 'NAT':
    case 'NATURAL': return '0x0002';
    case 'FLT':
    case 'FLAT': return '0x0012';
    case 'CNEV2': return '0x002c';
    case 'MONOL': return '0x0032';
    case 'VLOG':
    case 'V-LOG': return '0x0028';
    default: return '';
  }
}

/** photostyle 值 → 面板标签。取值总数/顺序由 get-setting 值域动态决定
 *  （S1RM2 实测 22 值，2026-09-29 18:52 抓包）；标签按机身中文菜单
 *  （2026-09-29 用户对照机身逐项给定），其余机型值沿用 §11 36 项表。 */
export function photoStyleLabelOf(v: number): string {
  switch (v) {
    case 0x0000: return '标准';
    case 0x0001: return '生动';
    case 0x0002: return '自然';
    case 0x002c: return 'L.新经典';
    case 0x0012: return '平直';
    case 0x0004: return '风景画';
    case 0x0005: return '人像';
    case 0x0003: return '单色';
    case 0x000f: return 'L.单色';
    case 0x0011: return 'L.单色D';
    case 0x002d: return 'L.单色S';
    case 0x0032: return 'LEICA 单色';
    case 0x0034: return 'Cinelike A2';
    case 0x0029: return '电影动态范围2';
    case 0x002a: return '电影模式视频2';
    case 0x000e: return 'Like709';
    case 0x0028: return 'V-Log';
    case 0x0031: return '实时LUT';
    case 0x0010: return 'HLG2100';
    case 0x001d: return 'HLG 标准';
    case 0x0023: return 'HLG 单色';
    case 0x002b: return 'HLG';
    case 0x0030: return 'HLG2100 Full';
    case 0x0033: return 'ARRI LogC3';
    case 0x0036: return 'L.经典';
    case 0x0037: return 'L.经典金';
    default:
      return v >= 0x0013 && v <= 0x001c ? `MY PHOTO STYLE ${v - 0x0012}` : hexWord(v);
  }
}

export function aspectLabelOf(v: number): string {
  switch (v) {
    case 0x0001: return '4:3';
    case 0x0002: return '3:2';
    case 0x0003: return '16:9';
    case 0x0004: return '1:1';
    case 0x000a: return '65:24';
    case 0x000b: return '2:1';
    default: return v === 0xffff ? '--' : hexWord(v);
  }
}

export function meteringLabelOf(v: number): string {
  switch (v) {
    case 0x0001: return '多重';
    case 0x0002: return '中央';
    case 0x0000: return '点';
    case 0x0003: return '高光';
    default: return v === 0xffff ? '--' : hexWord(v);
  }
}

export function lvQualityLabelOf(v: number): string {
  switch (v) {
    case 0x00: return '流畅';
    case 0x01: return '标准';
    case 0x02: return '精细';
    default: return v === 0xff ? '--' : hexWord(v);
  }
}

export function wbLabelOf(v: number): string {
  switch (v) {
    case 0x0002: return '自动';
    case 0x8014: return '自动·冷';
    case 0x8015: return '自动·暖';
    case 0x0004: return '日光';
    case 0x8008: return '阴天';
    case 0x800f: return '阴影';
    case 0x0006: return '卤素灯';
    case 0x0007: return '闪光';
    case 0x800b: return '白设置1';
    case 0x800c: return '白设置2';
    case 0x800d: return '白设置3';
    case 0x800e: return '白设置4';
    case 0x8010: return '色温1';
    case 0x8011: return '色温2';
    case 0x8012: return '色温3';
    case 0x8013: return '色温4';
    default: return v === 0xffff ? '--' : hexWord(v);
  }
}

export function modeLabelOf(v: number): string {
  switch (v) {
    case 0x0000: return 'P';
    case 0x0001: return 'A';
    case 0x0002: return 'S';
    case 0x0003: return 'M';
    case 0x0005: return 'CM';
    case 0x0007: return 'iA';
    case 0x0008: return 'C1';
    case 0x0009: return 'C2';
    case 0x000a: return 'C3';
    case 0x000c: return 'S&Q';
    default: return v === 0xffff ? '--' : hexWord(v);
  }
}

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

interface ControlHeader {
  ResponseCode?: number;
  Messages?: string;
}

interface ControlData {
  Result?: number;
  DataList?: string[];
  LvPort?: number;
  AuthToken?: string;
  cammode?: string;
  operate?: string;
  temperature?: string;
  lens?: string;
  sdcardstatus?: string;
  sd_memory?: string;
  sd_access?: string;
  sd_full?: string;
  sd2_cardstatus?: string;
  sd2_memory?: string;
  sd2_access?: string;
  sd2_full?: string;
  current_sd?: string;
  camera_operating?: string;
  video_priority_disp?: string;
  progress_time?: string;
}

interface ControlEnvelope {
  Data?: ControlData;
  Header?: ControlHeader;
  LvPort?: number;
}

interface ControlLutRecord {
  LutId?: number;
  LutName?: string;
  LutType?: number;
  PhotoStyle?: string;
}

interface ControlLutData {
  DataList?: ControlLutRecord[];
}

interface ControlLutEnvelope {
  Data?: ControlLutData;
}

interface AuthRequest {
  AppInfo: string;
  FriendlyName: string;
  Uuid: string;
}

interface SettingRequest {
  Type: string;
  Value?: string;
  Value2?: string;
}

/** S1RM2 get-setting 值域元素原始形状：{"item":"0x0000","subitem":["1/125",""]}（§20 实证）。 */
interface SettingItemRecord {
  item?: string;
  /**
   * 官方 N5.X 模型的 `subitem`：与 `item` 一一对应的**显示串**（角度表
   * `shtrspeed_angle_list.json` 就是 `{"key":"0x044C","value":["11°",""]}`）。
   * 之前只取 `item` 把它丢了，快门就只能显示成 `0x00001F40`。
   */
  subitem?: string[];
}

/** 值域条目：相机给的原始值 + 相机自己给的显示串（可能为空）。 */
export interface SettingOptionEntry {
  value: string;
  label: string;
}

/** S1RM2 get-setting 响应原始形状：值域挂在 Type 同名键下而非 DataList。 */
interface TypedSettingEnvelope {
  Header?: ControlHeader;
  Data?: Record<string, Array<SettingItemRecord | string>>;
}

interface CamCmdRequest {
  Command: string;
}

interface StartStreamRequest {
  UDPPortNumber: number;
}

interface LutDisplayRequest {
  LutId: number;
  Visibility: number;
}

/** Camera link base for a session (gateway host + AP SSID). */
interface CameraNetworkBase {
  host: string;
  ssid: string;
}

// Exact AppInfo string of the official client used in the 2026-09-17/18
// captures. /auth accepts any AppInfo; the official profile is kept for
// maximal parity with the BLE registration path this service reuses.
const CONTROL_APP_INFO = 'LUMIX LUT Creators APP 3.0.1';
// FriendlyName 只是客户端自报的手机设备名（官方 "WEB-W00" 即其安装机名），
// 相机不做校验；沿用本机身份即可。
const CONTROL_FRIENDLY_NAME = 'Pixelshop HarmonyOS';
const CONTROL_STORE = 'vivid_camera_control';

export class LumixControlService {
  /**
   * Authenticate a control session against the currently linked camera AP.
   * Registers this client's identity over BLE first (official app behavior,
   * best-effort) because the camera gates its remote endpoints on that
   * registration record. Throws a LumixControlError with a user-facing
   * Chinese message on failure.
   */
  static async openSession(context: common.UIAbilityContext): Promise<LumixControlSession> {
    const base = await LumixControlService.networkBase();
    const uuid = await LumixControlService.clientUuid(context);
    await LumixControlService.registerIdentityOverBle(uuid, CONTROL_APP_INFO, CONTROL_FRIENDLY_NAME);
    LumixControlService.log('auth request host=present uuid=present identity=own');
    let token = '';
    try {
      token = await LumixControlService.authOnceWith(base.host, uuid);
    } catch (firstError) {
      // Retry once: either the camera refused the identity or the first TLS
      // handshake to a just-joined camera AP failed.
      LumixControlService.log('auth retry');
      await LumixControlService.delay(800);
      try {
        token = await LumixControlService.authOnceWith(base.host, uuid);
      } catch (secondError) {
        const message = secondError instanceof Error ? secondError.message :
          (firstError instanceof Error ? firstError.message : '相机拒绝连接');
        throw new LumixControlError('auth', message, LumixControlService.businessCodeOf(message));
      }
    }
    LumixControlService.log('auth ok token=received value=redacted');
    const session: LumixControlSession = { host: base.host, ssid: base.ssid, token: token };
    return session;
  }

  /**
   * Re-authenticate with the already persisted identity, skipping the BLE
   * registration round (used when a mid-session 401 invalidated the token).
   */
  static async reopenSession(context: common.UIAbilityContext): Promise<LumixControlSession> {
    const base = await LumixControlService.networkBase();
    const uuid = await LumixControlService.clientUuid(context);
    let token = '';
    try {
      token = await LumixControlService.authOnceWith(base.host, uuid);
    } catch (error) {
      const message = error instanceof Error ? error.message : '相机拒绝连接';
      throw new LumixControlError('auth', message, LumixControlService.businessCodeOf(message));
    }
    const session: LumixControlSession = { host: base.host, ssid: base.ssid, token: token };
    return session;
  }

  /**
   * Open the persistent keep-alive control client for a session. All
   * streaming-critical calls (start-stream/get-lvport/get-state/stop-stream)
   * then share one TCP connection, matching the official client's OkHttp
   * connection pool behavior.
   */
  static openControlClient(session: LumixControlSession): void {
    if (session.controlClient !== undefined) {
      return;
    }
    session.controlClient = http.createHttp();
    LumixControlService.log('control client opened (keep-alive)');
  }

  /** Close the persistent control client (session teardown / reconnect). */
  static closeControlClient(session: LumixControlSession): void {
    if (session.controlClient !== undefined) {
      try {
        session.controlClient.destroy();
      } catch (_error) {
      }
      session.controlClient = undefined;
      LumixControlService.log('control client closed');
    }
  }

  /** Read the 1Hz heartbeat (subset the UI reacts to). */
  static async fetchState(session: LumixControlSession): Promise<LumixCameraState> {
    const raw = await LumixControlService.postJson(session.host, '/remote/get-state', '{}', session.token,
      '读取相机状态', session.controlClient);
    const data = LumixControlService.parseData(raw, '读取相机状态');
    const state = new LumixCameraState();
    state.cammode = LumixControlService.strOf(data.cammode, '');
    state.sdAccess = data.sd_access === 'on';
    state.sd2Access = data.sd2_access === 'on';
    state.sdFull = data.sd_full === 'true';
    state.sd2Full = data.sd2_full === 'true';
    state.currentSd = LumixControlService.strOf(data.current_sd, '');
    state.cameraOperating = data.camera_operating === 'true';
    return state;
  }

  /** All legal values of one setting key (set-setting value domain). */
  static async fetchSettingOptions(session: LumixControlSession, key: string): Promise<string[]> {
    const entries = await LumixControlService.fetchSettingOptionEntries(session, key);
    const out: string[] = [];
    for (const entry of entries) {
      out.push(entry.value);
    }
    return out;
  }

  /** 取相机给的显示串里第一个非空项（`subitem: ["1/125",""]` → `1/125`）。 */
  private static firstSubitem(record: SettingItemRecord): string {
    const subs = record.subitem;
    if (subs === undefined || subs === null || subs.length === 0) {
      return '';
    }
    for (const s of subs) {
      if (typeof s === 'string' && s.trim().length > 0) {
        return s.trim();
      }
    }
    return '';
  }

  /**
   * 值域 + 相机自带显示串。
   *
   * S1RM2 的 `shtrspeed` 值域是十六进制（`0x00001F40`），人眼不可读；相机在
   * 每个条目的 `subitem` 里其实给了显示串。只取 `item` 丢掉 `subitem`，就只剩
   * 一串十六进制可显示——这是「快门速度显示错误」的根因。
   */
  static async fetchSettingOptionEntries(session: LumixControlSession,
    key: string): Promise<SettingOptionEntry[]> {
    const body: SettingRequest = { Type: key };
    const raw = await LumixControlService.postJson(session.host, '/remote/get-setting', JSON.stringify(body),
      session.token, `读取 ${key} 能力表`);
    const data = LumixControlService.parseData(raw, `读取 ${key} 能力表`);
    const list: SettingOptionEntry[] = [];
    if (data.DataList !== undefined && data.DataList !== null) {
      for (const v of data.DataList) {
        list.push({ value: v, label: '' });
      }
    }
    if (list.length > 0) {
      return list;
    }
    // S1RM2 把值域挂在 Type 同名键下：{"Result":0,"photostyle":[{"item":
    // "0x0000"}…]}（2026-09-29 18:52 抓包实证）——DataList 为空时按类型键
    // 提取，否则 S1RM2 全部能力表解析为空（此前一直落在静态兜底表上，
    // pictureformat 探测也因此从未生效）。
    const typed = JSON.parse(raw) as TypedSettingEnvelope;
    if (typed.Data !== undefined && typed.Data !== null) {
      const arr = typed.Data[key];
      if (arr !== undefined && arr !== null) {
        for (const el of arr) {
          if (typeof el === 'string') {
            list.push({ value: el, label: '' });
          } else if (el.item !== undefined && el.item !== null) {
            list.push({ value: el.item, label: LumixControlService.firstSubitem(el) });
          }
        }
      }
    }
    if (key === 'shtrspeed' && list.length > 0) {
      // 值域本身要留痕：上一轮上传的日志里 get-setting 响应被头部 JSON 吃掉了
      // 长度预算，快门到底给了哪些值完全看不到。
      let labelled = 0;
      let sample = '';
      const limit = Math.min(list.length, 6);
      for (let i = 0; i < list.length; i++) {
        if (list[i].label.length > 0) labelled += 1;
      }
      for (let i = 0; i < limit; i++) {
        sample += ` ${list[i].value}=${list[i].label.length > 0 ? list[i].label : '?'}`;
      }
      LumixControlService.log(`shtrspeed domain=${list.length} labelled=${labelled}${sample}`);
    }
    return list;
  }

  /** Push one setting value ("0xXXXX" or "N/256"; optional subitem Value2). */
  static async applySetting(session: LumixControlSession, type: string, value: string,
    value2?: string): Promise<void> {
    const body: SettingRequest = value2 !== undefined ?
      { Type: type, Value: value, Value2: value2 } : { Type: type, Value: value };
    // 2026-09-29 14:48 教训：S1RM2 对未知 set 键回 200/Result=0 但不生效，
    // hilog 又截断响应体——请求体必须留痕才能对账。
    LumixControlService.log(`set-setting req ${type}=${value}` +
      (value2 !== undefined ? ` value2=${value2}` : ''));
    const raw = await LumixControlService.postJson(session.host, '/remote/set-setting', JSON.stringify(body),
      session.token, `设置 ${type}`);
    const data = LumixControlService.parseData(raw, `设置 ${type}`);
    LumixControlService.requireResult(data, `设置 ${type}`);
  }

  /**
   * Send a camcmd word (recmode/playmode/capture/capture_cancel/
   * touchafrelease/video_recstart/video_recstop). `retries` > 0 re-sends on
   * camera business errors (mode switching takes ~0.9s on the body).
   */
  static async sendCamCmd(session: LumixControlSession, command: string, retries: number = 0): Promise<void> {
    let attempt = 0;
    while (true) {
      const body: CamCmdRequest = { Command: command };
      try {
        const raw = await LumixControlService.postJson(session.host, '/remote/camcmd', JSON.stringify(body),
          session.token, `指令 ${command}`);
        const data = LumixControlService.parseData(raw, `指令 ${command}`);
        LumixControlService.requireResult(data, `指令 ${command}`);
        return;
      } catch (error) {
        if (attempt >= retries || !(error instanceof LumixControlError) || error.kind !== 'http') {
          throw error instanceof Error ? error : new LumixControlError('http', `指令 ${command}失败`);
        }
        attempt++;
        LumixControlService.log(`camcmd ${command} retry ${attempt}`);
        await LumixControlService.delay(1000);
      }
    }
  }

  /** One touch-AF event (liveview pixel coordinates, on = press, off = lift). */
  static async sendTouchAf(session: LumixControlSession, x: number, y: number, on: boolean): Promise<void> {
    const body: SettingRequest = { Type: 'touch', Value: `${x}/${y}`, Value2: on ? 'on' : 'off' };
    const raw = await LumixControlService.postJson(session.host, '/remote/camctrl', JSON.stringify(body),
      session.token, '触屏对焦');
    const data = LumixControlService.parseData(raw, '触屏对焦');
    LumixControlService.requireResult(data, '触屏对焦');
  }

  /** Tell the camera to push the liveview stream to our local UDP port. */
  static async startStream(session: LumixControlSession, udpPort: number): Promise<void> {
    const body: StartStreamRequest = { UDPPortNumber: udpPort };
    const raw = await LumixControlService.postJson(session.host, '/remote/start-stream', JSON.stringify(body),
      session.token, '启动取景', session.controlClient);
    const data = LumixControlService.parseData(raw, '启动取景');
    LumixControlService.requireResult(data, '启动取景');
  }

  /**
   * Stop the liveview stream. Never throws: with no stream running the
   * camera answers 403 err_critical, which the official app ignores.
   */
  static async stopStream(session: LumixControlSession): Promise<void> {
    try {
      // h2 插桩实锤：官方 stop-stream / get-lvport 请求体为空（非 "{}"）。
      await LumixControlService.postJson(session.host, '/remote/stop-stream', '{}', session.token, '停止取景',
        session.controlClient);
    } catch (error) {
      LumixControlService.log(`stop-stream ignored code=${error instanceof Error ? error.message : 'unknown'}`);
    }
  }

  /**
   * Camera-side UDP source port of the liveview stream. The camera answers
   * 403 err_busy for a moment right after start-stream, so 403 is retried.
   */
  static async fetchLvPort(session: LumixControlSession): Promise<number> {
    let lastCode = 0;
    for (let attempt = 0; attempt < 25; attempt++) {
      try {
        const raw = await LumixControlService.postJson(session.host, '/remote/get-lvport', '{}', session.token,
          '读取取景端口', session.controlClient);
        const data = LumixControlService.parseData(raw, '读取取景端口');
        const port = data.LvPort !== undefined && data.LvPort !== null ? Number(data.LvPort) : 0;
        if (!Number.isFinite(port) || port <= 0) {
          throw new LumixControlError('http', '相机未返回取景端口');
        }
        LumixControlService.log(`lvport=${port} after ${attempt + 1} tries`);
        return port;
      } catch (error) {
        if (error instanceof LumixControlError && error.code === 403) {
          lastCode = 403;
          await LumixControlService.delay(100);
          continue;
        }
        throw error instanceof Error ? error : new LumixControlError('http', '读取取景端口失败');
      }
    }
    throw new LumixControlError('http', lastCode === 403 ? '相机取景端口未就绪' : '读取取景端口失败', lastCode);
  }

  /** Read the camera LUT slot list (same response shape as the LUT client). */
  static async fetchLutSlots(session: LumixControlSession): Promise<LumixLutSlot[]> {
    const raw = await LumixControlService.postJson(session.host, '/lut/info', '{}', session.token,
      '读取相机 LUT 列表');
    let envelope: ControlLutEnvelope;
    try {
      envelope = JSON.parse(raw) as ControlLutEnvelope;
    } catch (_error) {
      throw new LumixControlError('http', '读取相机 LUT 列表：相机响应无法解析');
    }
    const records = envelope.Data !== undefined && envelope.Data !== null &&
      envelope.Data.DataList !== undefined && envelope.Data.DataList !== null ? envelope.Data.DataList : [];
    const slots: LumixLutSlot[] = [];
    for (const record of records) {
      const lutId = record.LutId !== undefined && record.LutId !== null ? Number(record.LutId) : -1;
      if (!Number.isFinite(lutId) || lutId < 0) {
        continue;
      }
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
    LumixControlService.log(`lut/info slots=${slots.length}`);
    return slots;
  }

  /** Select which camera LUT is the display LUT ({LutId, Visibility}). */
  static async applyLutDisplay(session: LumixControlSession, lutId: number, visible: boolean): Promise<void> {
    const body: LutDisplayRequest = { LutId: lutId, Visibility: visible ? 1 : 0 };
    const raw = await LumixControlService.postJson(session.host, '/lut/set-display-setting',
      JSON.stringify(body), session.token, '切换显示 LUT');
    const data = LumixControlService.parseData(raw, '切换显示 LUT');
    LumixControlService.requireResult(data, '切换显示 LUT');
  }

  // -------------------------------------------------------------------------
  // Session helpers
  // -------------------------------------------------------------------------

  private static async networkBase(): Promise<CameraNetworkBase> {
    const ssid = await LumixCameraService.linkedSsid();
    if (ssid.length === 0) {
      throw new LumixControlError('wifi', '手机未连接相机 Wi‑Fi');
    }
    if (LumixCameraService.identifyWifiSsid(ssid) === null) {
      throw new LumixControlError('ssid', `当前 Wi‑Fi「${ssid}」不是松下相机热点`);
    }
    const host = await LumixCameraService.linkedGateway();
    if (host.length === 0) {
      throw new LumixControlError('gateway', '未获取到相机网络网关，请重新连接相机 Wi‑Fi');
    }
    const base: CameraNetworkBase = { host: host, ssid: ssid };
    return base;
  }

  private static async authOnceWith(host: string, uuid: string): Promise<string> {
    const body: AuthRequest = { AppInfo: CONTROL_APP_INFO, FriendlyName: CONTROL_FRIENDLY_NAME, Uuid: uuid };
    const raw = await LumixControlService.postJson(host, '/auth', JSON.stringify(body), '', '连接相机');
    const data = LumixControlService.parseData(raw, '连接相机');
    const token = data.AuthToken !== undefined && data.AuthToken !== null ? String(data.AuthToken) : '';
    if (token.length === 0) {
      throw new Error('相机未返回会话凭证');
    }
    return token;
  }

  private static strOf(value: string | undefined, fallback: string): string {
    return value !== undefined && value !== null ? String(value) : fallback;
  }

  /**
   * Parse and validate a camera JSON envelope, returning its Data object.
   * A Header is only a rejection when ResponseCode is explicitly present and
   * not 200 (successful lut/info responses omit Header entirely). A bare
   * {"LvPort":N} body (observed shape for get-lvport) is accepted too.
   */
  private static parseData(body: string, phase: string): ControlData {
    let envelope: ControlEnvelope;
    try {
      envelope = JSON.parse(body) as ControlEnvelope;
    } catch (_error) {
      throw new LumixControlError('http', `${phase}：相机响应无法解析`);
    }
    const header = envelope.Header;
    if (header !== undefined && header !== null && header.ResponseCode !== undefined) {
      const code = Number(header.ResponseCode);
      if (code !== 200) {
        const messages = header.Messages !== undefined && header.Messages !== null ?
          String(header.Messages) : '';
        throw new LumixControlError('http', `${phase}：相机返回错误码 ${code}${messages.length > 0 ?
          `（${messages}）` : ''}`, code);
      }
    }
    if (envelope.Data !== undefined && envelope.Data !== null) {
      return envelope.Data;
    }
    if (envelope.LvPort !== undefined) {
      const bare: ControlData = { LvPort: envelope.LvPort };
      return bare;
    }
    throw new LumixControlError('http', `${phase}：相机响应缺少数据`);
  }

  private static requireResult(data: ControlData, phase: string): void {
    if (data.Result !== undefined && data.Result !== null && Number(data.Result) !== 0) {
      throw new LumixControlError('http', `${phase}被拒绝（Result=${data.Result}）`);
    }
  }

  private static async postJson(host: string, path: string, body: string, token: string,
    phase: string, keepClient?: http.HttpRequest): Promise<string> {
    const client = keepClient ?? http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      if (token.length > 0) {
        // 2026-09-19 g 版插桩实锤：官方 Authorization 头字面值含单引号
        // （'Bearer <token>'），相机侧按引号格式匹配。
        headers['Authorization'] = `'Bearer ${token}'`;
      }
      // Empty body: send '' so the stack emits Content-Length: 0 (an empty
      // ArrayBuffer made the camera answer HTTP 411, and TextEncoder.encode('')
      // returns undefined on this runtime).
      let bodyData: string | ArrayBuffer = '';
      if (body.length > 0) {
        const encoded = util.TextEncoder.create('utf-8').encode(body);
        // The underlying ArrayBuffer may be larger than the encoded bytes
        // (faqs-arkts-137); slice to the exact region in that case.
        bodyData = encoded.byteOffset === 0 && encoded.byteLength === encoded.buffer.byteLength ?
          encoded.buffer as ArrayBuffer : encoded.slice().buffer as ArrayBuffer;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        body: bodyData,
        connectTimeout: 15000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING,
        // The camera AP presents a self-signed certificate on a private
        // point-to-point network, so the peer certificate is accepted as-is.
        remoteValidation: (_validation: http.ValidationContext): Promise<boolean> => Promise.resolve(true),
      };
      const response = await client.request(`https://${host}${path}`, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        // Body carries the camera's Messages field (err_busy/err_critical...),
        // which distinguishes "port not ready yet" from "no stream at all".
        const errBody = typeof response.result === 'string' ? response.result : '';
        LumixControlService.log(`${path} http=${response.responseCode} body=${errBody.substring(0, 120)}`);
        throw new LumixControlError('http', `${phase}失败：HTTP ${response.responseCode}`,
          response.responseCode);
      }
      const resultText = typeof response.result === 'string' ? response.result : '';
      // 2026-09-19：响应体直接入日志（/auth 除外，防 token 泄漏）。此前只有
      // 字节数指纹（120B/124B/85B），err_busy 与 ok 的真实内容只能靠猜。
      const preview = path === '/auth' ? '(redacted)' : resultText.substring(0, 110);
      LumixControlService.log(`${path} http=${response.responseCode} rspBytes=${resultText.length} body=${preview}`);
      return resultText;
    } catch (error) {
      if (error instanceof LumixControlError) {
        LumixControlService.log(`${path} rejected code=${error.code}`);
        throw error;
      }
      if (error instanceof Error) {
        LumixControlService.log(`${path} failed code=${error.message}`);
        throw new Error(`${phase}失败：${error.message}`);
      }
      throw new Error(`${phase}失败`);
    } finally {
      if (keepClient === undefined) {
        client.destroy();
      }
    }
  }

  /** Stable per-install control identity (separate from image/LUT lines). */
  private static async clientUuid(context: common.UIAbilityContext): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, CONTROL_STORE);
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
        return 'vividctrl00000000000000000000000';
      }
    }
  }

  /** Pull the camera business code back out of a message for callers. */
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
   * Best-effort BLE registration of the client identity before the HTTPS
   * session (official app behavior). The pairing commit can make the camera
   * restart its Wi-Fi AP, so wait for the network to come back.
   */
  private static async registerIdentityOverBle(uuid: string, appInfo: string,
    friendlyName: string): Promise<void> {
    try {
      const ok = await LumixImportPrototype.registerLutIdentity(uuid, appInfo, friendlyName);
      LumixControlService.log(`ble identity registration ${ok ? 'complete' : 'unavailable'}`);
      if (ok) {
        await LumixControlService.waitForCameraNetwork(30000);
      }
    } catch (error) {
      LumixControlService.log(`ble identity registration failed code=${error instanceof Error ?
        error.message : 'unknown'}`);
    }
  }

  private static async waitForCameraNetwork(timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const ssid = await LumixCameraService.linkedSsid();
        if (ssid.length > 0 && LumixCameraService.identifyWifiSsid(ssid) !== null) {
          const host = await LumixCameraService.linkedGateway();
          if (host.length > 0) {
            LumixControlService.log('camera network ready after registration reset');
            return;
          }
        }
      } catch (_error) {
      }
      await LumixControlService.delay(1000);
    }
    LumixControlService.log('camera network not ready after registration reset');
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** Short non-sensitive runtime marker; tokens never enter logs. */
  static log(message: string): void {
    AppDiagnostics.event('VIVID_CTRL', message);
    try {
      hilog.info(0x0001, 'VIVID_CTRL', '%{public}s', message);
      AppLogSink.emit('CTL', message);
    } catch (_error) {
    }
  }
}

// ---------------------------------------------------------------------------
// Liveview receiver: UDP + RTP + fragment reassembly + Q0 metadata parser
// ---------------------------------------------------------------------------

/** 9-byte fragment magic of the Lab (DTLS) line (fc 84 a7 d0 ba 76 00 21 ff).
 * The Sync plaintext line shares the fragment layout but NOT this magic
 * (2026-09-27 field test: every packet rejected on magic while all length
 * fields stayed sane), so handleFragment also accepts magic-less packets
 * that pass the structural checks (JPEG SOI / in-order continuation). */
const FRAG_MAGIC: number[] = [0xfc, 0x84, 0xa7, 0xd0, 0xba, 0x76, 0x00, 0x21, 0xff];
/** No complete frame for this long -> stall callback (official uses 8s). */
const STALL_AFTER_MS = 8000;
/** Reassembly rejects JPEGs beyond this size as corrupt. */
const MAX_JPEG_BYTES = 8 * 1024 * 1024;

/**
 * Receives the camera liveview UDP stream on a local port, strips RTP,
 * reassembles Panasonic fragments into complete frames and parses the Q0
 * metadata block for display state. One receiver owns one bound UDP socket;
 * call stop() when the page goes away.
 */
export class LumixLiveviewReceiver {
  private sock: socket.UDPSocket | null = null;
  private boundPort: number = 0;
  private watchdogId: number = -1;
  private lastFrameAt: number = 0;
  private watching: boolean = false;
  private closed: boolean = false;
  // Fragment assembly state.
  private assembling: boolean = false;
  private expectedSeq: number = 0;
  private jpegBuf: Uint8Array | null = null;
  private jpegFilled: number = 0;
  private lastPrefix: Uint8Array | null = null;
  // Stream bring-up diagnostics: rejection counters flushed to hilog every 2s.
  private pktCount: number = 0;
  private frameCount: number = 0;
  private rejRtp: number = 0;
  private rejShort: number = 0;
  private rejLen: number = 0;
  private rejMagic: number = 0;
  private rejSeq: number = 0;
  private firstPacketsLogged: number = 0;
  private firstFrameLogged: boolean = false;
  // DTLS engine once startDtls() succeeds; null = plaintext receive path.
  private dtls: DtlsClient | null = null;
  // Callbacks installed by the owner before bind().
  public frameHandler: ((frame: LumixLiveviewFrame) => void) | null = null;
  public stallHandler: (() => void) | null = null;

  /** Local UDP port after a successful bind (camera sends to this port). */
  get port(): number {
    return this.boundPort;
  }

  /**
   * Bind the local UDP socket. Official client behavior per 2026-09-19 h2
   * instrumentation: liveview stream uses port 1235 (earlier captures showed
   * 1234/1236, so the value is picked client-side; on conflict retry port+2).
   */
  async bind(preferredPort: number): Promise<number> {
    let port = preferredPort;
    for (let attempt = 0; attempt < 8; attempt++) {
      const sock = socket.constructUDPSocketInstance();
      try {
        await sock.bind({ address: '0.0.0.0', port: port });
        this.sock = sock;
        this.boundPort = port;
        this.closed = false;
        sock.on('message', (info: socket.SocketMessageInfo) => {
          this.handlePacket(info.message);
        });
        sock.on('error', (err: Error) => {
          LumixLiveviewReceiver.log(`udp error code=${err.message}`);
        });
        this.watchdogId = setInterval(() => {
          this.checkWatchdog();
          this.logStats();
        }, 2000);
        LumixLiveviewReceiver.log(`udp bound port=${port}`);
        this.bindToWifi(sock);
        this.selfTest(port);
        return port;
      } catch (error) {
        LumixLiveviewReceiver.log(`udp bind ${port} failed code=${error instanceof Error ?
          error.message : 'unknown'}`);
        try {
          await sock.close();
        } catch (_closeError) {
        }
        port += 2;
      }
    }
    throw new Error('取景端口绑定失败');
  }

  /** (Re)arm the 8s no-frame watchdog after (re)starting the stream. */
  resume(): void {
    this.lastFrameAt = Date.now();
    this.watching = true;
  }

  /**
   * Bind the UDP socket to the Wi-Fi bearer (faqs-network-96): without this,
   * sockets send/receive via the DEFAULT network, which is cellular when a SIM
   * is active — the camera's RTP stream then never reaches the socket.
   */
  private bindToWifi(sock: socket.UDPSocket): void {
    try {
      const nets = connection.getAllNetsSync();
      let wifiNet: connection.NetHandle | null = null;
      for (const net of nets) {
        try {
          const caps = connection.getNetCapabilitiesSync(net);
          const bearers = caps.bearerTypes.join(',');
          LumixLiveviewReceiver.log(`net id=${net.netId} bearers=${bearers}`);
          if (caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)) {
            wifiNet = net;
          }
        } catch (capError) {
          LumixLiveviewReceiver.log(
            `net caps failed code=${capError instanceof Error ? capError.message : 'unknown'}`);
        }
      }
      if (wifiNet === null) {
        LumixLiveviewReceiver.log('wifi net not found; socket stays on default net');
        return;
      }
      wifiNet.bindSocket(sock).then(() => {
        LumixLiveviewReceiver.log(`socket bound to wifi net id=${wifiNet!.netId}`);
        connection.getConnectionProperties(wifiNet!).then((props: connection.ConnectionProperties) => {
          const addrs: string[] = [];
          for (const la of props.linkAddresses) {
            addrs.push(`${la.address.address}/${la.prefixLength}`);
          }
          LumixLiveviewReceiver.log(`wifi ifName=${props.interfaceName} addrs=${addrs.join(' ')}`);
        }).catch((err: Error) => {
          LumixLiveviewReceiver.log(`getConnectionProperties failed code=${err.message}`);
        });
      }).catch((err: Error) => {
        LumixLiveviewReceiver.log(`bindSocket wifi failed code=${err.message}`);
      });
    } catch (error) {
      LumixLiveviewReceiver.log(`bindToWifi error ${error instanceof Error ? error.message : 'unknown'}`);
    }
  }

  /**
   * Loopback machinery check: a helper socket sends a datagram to
   * 127.0.0.1:<port>; if on('message') never fires, the receive path itself
   * is broken (not the camera).
   */
  private selfTest(port: number): void {
    try {
      const helper = socket.constructUDPSocketInstance();
      helper.bind({ address: '0.0.0.0', port: 0 }).then(() => {
        helper.send({ address: { address: '127.0.0.1', port: port }, data: 'VIVID_PING' }).then(() => {
          LumixLiveviewReceiver.log(`selftest sent to 127.0.0.1:${port}`);
        }).catch((err: Error) => {
          LumixLiveviewReceiver.log(`selftest send failed code=${err.message}`);
        });
      }).catch((err: Error) => {
        LumixLiveviewReceiver.log(`selftest bind failed code=${err.message}`);
      });
      setTimeout(() => {
        try {
          helper.close();
        } catch (_e) {
        }
      }, 3000);
    } catch (error) {
      LumixLiveviewReceiver.log(`selftest error ${error instanceof Error ? error.message : 'unknown'}`);
    }
  }

  /**
   * Send a small datagram from the MAIN bound socket to the camera's liveview
   * port. The camera may use the first incoming UDP packet's source address
   * as the stream destination; this also punches any local stateful filter.
   * (HarmonyOS UDPSocket has no connect(): the official DatagramSocket.connect
   * peer filter cannot be replicated; reception needs no connect anyway.)
   */
  async probe(host: string, camPort: number): Promise<void> {
    if (this.sock === null) {
      return;
    }
    try {
      await this.sock.send({ address: { address: host, port: camPort }, data: 'VIVID_PROBE' });
      LumixLiveviewReceiver.log(`probe sent ${host}:${camPort} from port=${this.boundPort}`);
    } catch (error) {
      LumixLiveviewReceiver.log(`probe failed code=${error instanceof Error ? error.message : 'unknown'}`);
    }
  }

  /**
   * Run the DTLS 1.2 handshake from the bound socket against the camera's
   * liveview port. 2026-09-19 official-APK instrumentation: the stream is
   * DTLS 1.2 (RSA + AES-128-GCM) and the camera sends NOTHING before the
   * handshake completes — the plaintext probe could never work. On success
   * every datagram is decrypted and fed through the normal RTP path.
   */
  async startDtls(host: string, camPort: number): Promise<void> {
    const sock = this.sock;
    if (sock === null) {
      throw new Error('DTLS 握手失败：socket 未绑定');
    }
    if (this.dtls !== null) {
      this.dtls.close();
      this.dtls = null;
    }
    const client = new DtlsClient(sock, host, camPort);
    client.plainHandler = (plain: Uint8Array): void => {
      this.handlePlain(plain);
    };
    this.dtls = client;
    try {
      await client.handshake();
    } catch (error) {
      client.close();
      this.dtls = null;
      // The page only surfaces the error via statusText; hilog needs it too,
      // otherwise a failed handshake is a black box in field logs.
      LumixLiveviewReceiver.log(`dtls failed: ${error instanceof Error ? error.message : 'unknown'}`);
      if (error instanceof Error) {
        throw error;
      }
      throw new Error('DTLS 握手失败');
    }
  }

  /** Stop the watchdog only (keep socket) while the stream is being rebuilt. */
  pause(): void {
    this.watching = false;
  }

  /** Release the UDP socket and the watchdog; the receiver cannot restart. */
  stop(): void {
    this.closed = true;
    this.watching = false;
    if (this.dtls !== null) {
      this.dtls.close();
      this.dtls = null;
    }
    if (this.watchdogId >= 0) {
      clearInterval(this.watchdogId);
      this.watchdogId = -1;
    }
    const sock = this.sock;
    this.sock = null;
    this.resetAssembly();
    if (sock !== null) {
      try {
        sock.off('message');
        sock.off('error');
        sock.close();
      } catch (_error) {
      }
    }
  }

  /** Flush per-interval packet/rejection counters so a dead or malformed
   *  stream is visible in hilog (one line every 2s while bound). */
  private logStats(): void {
    if (this.closed || this.sock === null) {
      return;
    }
    LumixLiveviewReceiver.log(`udp stats pkts=${this.pktCount} frames=${this.frameCount} ` +
      `rej(rtp=${this.rejRtp},short=${this.rejShort},len=${this.rejLen},` +
      `magic=${this.rejMagic},seq=${this.rejSeq})`);
    this.logKernUdp();
    this.pktCount = 0;
    this.frameCount = 0;
    this.rejRtp = 0;
    this.rejShort = 0;
    this.rejLen = 0;
    this.rejMagic = 0;
    this.rejSeq = 0;
  }

  /** Set once /proc/net proves unreadable in this sandbox; stops retry spam. */
  private static kernProcUnavailable = false;

  /** Read a whole /proc file (procfs reports size 0, so read in a loop). */
  private static readProcText(path: string): string {
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const chunks: Uint8Array[] = [];
        let total = 0;
        for (let i = 0; i < 16 && total < 1024 * 1024; i++) {
          const buf = new ArrayBuffer(65536);
          const n = fileIo.readSync(file.fd, buf);
          if (n <= 0) {
            break;
          }
          chunks.push(new Uint8Array(buf, 0, n));
          total += n;
        }
        const all = new Uint8Array(total);
        let off = 0;
        for (const chunk of chunks) {
          all.set(chunk, off);
          off += chunk.length;
        }
        return util.TextDecoder.create('utf-8').decodeWithStream(all);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_error) {
      return '';
    }
  }

  /**
   * Kernel-level UDP truth (2026-09-19 pkts=0 diagnosis): /proc/net/snmp
   * counters show whether the kernel receives ANY UDP at all, and the
   * /proc/net/udp row for our port shows rx_queue backlog plus per-socket
   * drops. Discriminates "camera never sends" vs "kernel drops" vs "JS
   * callback never fires" — the loopback selftest cannot see external drops.
   */
  private logKernUdp(): void {
    if (LumixLiveviewReceiver.kernProcUnavailable) {
      return;
    }
    const snmp = LumixLiveviewReceiver.readProcText('/proc/net/snmp');
    if (snmp.length === 0) {
      LumixLiveviewReceiver.kernProcUnavailable = true;
      LumixLiveviewReceiver.log('kern /proc/net/snmp unavailable (use hdc shell)');
      return;
    }
    let inDatagrams = '-1';
    let inErrors = '-1';
    const lines = snmp.split('\n');
    for (let i = 0; i + 1 < lines.length; i++) {
      if (!lines[i].startsWith('Udp: ') || !lines[i + 1].startsWith('Udp: ')) {
        continue;
      }
      const header = lines[i].substring(5).trim().split(/\s+/);
      const values = lines[i + 1].substring(5).trim().split(/\s+/);
      for (let c = 0; c < header.length && c < values.length; c++) {
        if (header[c] === 'InDatagrams') {
          inDatagrams = values[c];
        } else if (header[c] === 'InErrors') {
          inErrors = values[c];
        }
      }
      break;
    }
    const portHex = this.boundPort.toString(16).toUpperCase().padStart(4, '0');
    let sockInfo = 'row-missing';
    const table = LumixLiveviewReceiver.readProcText('/proc/net/udp');
    if (table.length > 0) {
      const rows = table.split('\n');
      for (const row of rows) {
        const cols = row.trim().split(/\s+/);
        if (cols.length > 5 && cols[1].endsWith(`:${portHex}`)) {
          sockInfo = `txrx=${cols[4]} drops=${cols[cols.length - 1]}`;
          break;
        }
      }
    }
    LumixLiveviewReceiver.log(`kern udp in=${inDatagrams} inErr=${inErrors} sock(${portHex}) ${sockInfo}`);
  }

  private checkWatchdog(): void {
    if (!this.watching || this.closed || this.stallHandler === null) {
      return;
    }
    if (Date.now() - this.lastFrameAt > STALL_AFTER_MS) {
      this.watching = false;
      LumixLiveviewReceiver.log('watchdog stall');
      this.stallHandler();
    }
  }

  private handlePacket(buffer: ArrayBuffer): void {
    if (this.closed) {
      return;
    }
    if (this.dtls !== null) {
      this.dtls.feedDatagram(buffer);
      return;
    }
    this.handlePlain(new Uint8Array(buffer));
  }

  private handlePlain(pkt: Uint8Array): void {
    // Loopback selftest payload (utf-8 "VIVID_PING"): do not burn the
    // first-packet diagnostic or the stats on our own ping.
    if (pkt.length === 10 && pkt[0] === 0x56 && pkt[4] === 0x44 && pkt[9] === 0x47) {
      return;
    }
    this.pktCount++;
    if (this.firstPacketsLogged < 3) {
      this.firstPacketsLogged++;
      LumixLiveviewReceiver.log(`udp pkt#${this.firstPacketsLogged} bytes=${pkt.length} ` +
        `head=${LumixLiveviewReceiver.hexHead(pkt, 96)}`);
    }
    // 2026-09-19 live decrypt: the DTLS application-data payload IS the
    // Panasonic fragment itself (2B total length at [0..1] equals the record
    // size, magic at [9]) — there is NO RTP layer inside DTLS. The old
    // stripRtp path was a pre-DTLS assumption that never matched reality.
    this.handleFragment(pkt);
  }

  /** Hex dump of the first `max` bytes, for one-shot packet diagnostics. */
  private static hexHead(bytes: Uint8Array, max: number): string {
    const n = Math.min(bytes.length, max);
    let s = '';
    for (let i = 0; i < n; i++) {
      const h = bytes[i].toString(16);
      s += h.length < 2 ? `0${h}` : h;
    }
    return s;
  }

  private handleFragment(frag: Uint8Array): void {
    if (frag.length < 32) {
      this.rejShort++;
      return;
    }
    const fragLen = (frag[0] << 8) | frag[1];
    let g = frag;
    if (fragLen < 32 || fragLen > frag.length) {
      this.rejLen++;
      return;
    }
    if (fragLen < frag.length) {
      g = frag.subarray(0, fragLen);
    }
    const seq = ((g[4] << 24) | (g[5] << 16) | (g[6] << 8) | g[7]) >>> 0;
    const flags = g[8];
    const metaLen = (g[30] << 8) | g[31];
    const dataStart = 32 + metaLen;
    if (dataStart > g.length) {
      this.rejLen++;
      return;
    }
    // Strong validation: 9-byte magic at offset 9. The Sync-line plaintext
    // stream (2026-09-27 field test) shares this layout but does not carry
    // the Lab-line magic, so a magic mismatch falls back to structural
    // checks: frame heads must start a JPEG right at dataStart, continuations
    // must extend the frame being assembled (bounds validated later).
    let magicOk = true;
    for (let i = 0; i < FRAG_MAGIC.length; i++) {
      if (g[9 + i] !== FRAG_MAGIC[i]) {
        magicOk = false;
        break;
      }
    }
    if (!magicOk) {
      const isHead = seq === 0 || seq === 0xffffffff;
      const headOk = isHead && dataStart + 1 < g.length &&
        g[dataStart] === 0xff && g[dataStart + 1] === 0xd8;
      const contOk = !isHead && this.assembling && seq === this.expectedSeq;
      if (!headOk && !contOk) {
        this.rejMagic++;
        return;
      }
    }
    if (seq === 0xffffffff) {
      // Reset marker: self-contained complete frame; drop any partial frame.
      this.resetAssembly();
      this.emitFrame(g.subarray(0, dataStart), g.subarray(dataStart));
      return;
    }
    if (seq === 0) {
      this.resetAssembly();
      const jpegTotal = (((g[22] << 24) | (g[23] << 16) | (g[24] << 8) | g[25]) >>> 0);
      if (jpegTotal === 0 || jpegTotal > MAX_JPEG_BYTES) {
        this.rejLen++;
        return;
      }
      this.jpegBuf = new Uint8Array(jpegTotal);
      this.jpegFilled = 0;
      this.assembling = true;
      this.expectedSeq = 1;
      this.appendFragment(g, dataStart);
      if ((flags & 1) === 0) {
        this.finalizeFrame();
      }
      return;
    }
    if (!this.assembling || this.jpegBuf === null) {
      this.rejSeq++;
      return;
    }
    if (seq !== this.expectedSeq) {
      // Sequence break: official drops the whole frame and starts over.
      this.rejSeq++;
      this.resetAssembly();
      return;
    }
    this.expectedSeq = (seq + 1) >>> 0;
    this.appendFragment(g, dataStart);
    if ((flags & 1) === 0) {
      this.finalizeFrame();
    }
  }

  private appendFragment(g: Uint8Array, dataStart: number): void {
    const buf = this.jpegBuf;
    if (buf === null) {
      return;
    }
    const jpegOff = (((g[26] << 24) | (g[27] << 16) | (g[28] << 8) | g[29]) >>> 0);
    const dataLen = g.length - dataStart;
    if (jpegOff > buf.length || dataLen < 0 || jpegOff + dataLen > buf.length) {
      this.resetAssembly();
      return;
    }
    if (dataLen > 0) {
      buf.set(g.subarray(dataStart), jpegOff);
    }
    this.jpegFilled += dataLen;
    // The complete frame prefix (32B header + metadata) comes from the LAST
    // fragment; every fragment carries an identical copy.
    this.lastPrefix = g.slice(0, dataStart);
  }

  private finalizeFrame(): void {
    const buf = this.jpegBuf;
    if (!this.assembling || buf === null) {
      this.resetAssembly();
      return;
    }
    const prefix = this.lastPrefix;
    this.assembling = false;
    this.jpegBuf = null;
    this.lastPrefix = null;
    if (prefix === null || this.jpegFilled !== buf.length) {
      return;
    }
    this.emitFrame(prefix, buf);
  }

  private resetAssembly(): void {
    this.assembling = false;
    this.jpegBuf = null;
    this.jpegFilled = 0;
    this.lastPrefix = null;
  }

  private emitFrame(prefix: Uint8Array, jpeg: Uint8Array): void {
    if (jpeg.length < 4 || jpeg[0] !== 0xff || jpeg[1] !== 0xd8 ||
      jpeg[jpeg.length - 2] !== 0xff || jpeg[jpeg.length - 1] !== 0xd9) {
      return;
    }
    const info = LumixLiveviewReceiver.parseMeta(prefix);
    const size = LumixLiveviewReceiver.jpegSize(jpeg);
    let buffer: ArrayBuffer;
    if (jpeg.byteOffset === 0 && jpeg.byteLength === jpeg.buffer.byteLength) {
      buffer = jpeg.buffer as ArrayBuffer;
    } else {
      buffer = jpeg.slice().buffer as ArrayBuffer;
    }
    const frame: LumixLiveviewFrame = {
      jpeg: buffer,
      width: size[0],
      height: size[1],
      info: info,
    };
    this.frameCount++;
    if (!this.firstFrameLogged) {
      this.firstFrameLogged = true;
      LumixLiveviewReceiver.log(`udp first frame jpeg=${jpeg.length}B ${size[0]}x${size[1]}`);
    }
    this.lastFrameAt = Date.now();
    if (this.frameHandler !== null) {
      this.frameHandler(frame);
    }
  }

  /**
   * Cursor walk of the Q0 metadata block, offsets verified byte-by-byte
   * against captured frames (parse_frame.ps1). Every read is bounds-guarded;
   * a truncated block returns the fields decoded so far.
   */
  private static parseMeta(prefix: Uint8Array): LumixLiveviewInfo {
    const info = new LumixLiveviewInfo();
    const end = prefix.length;
    if (end <= 32) {
      return info;
    }
    const dv = new DataView(prefix.buffer, prefix.byteOffset, prefix.byteLength);
    // Fixed 16-byte header through numfocusframe.
    let c = 32;
    if (c + 16 > end) {
      return info;
    }
    info.zoomPos = dv.getUint8(c + 4);
    const nff = dv.getUint8(c + 15);
    c += 16;
    let frames = nff;
    if (c + frames * 16 > end) {
      frames = Math.max(0, Math.floor((end - c) / 16));
    }
    c += frames * 16;
    // Av/Tv/Sv blocks: max/min/current, each a 16-bit x256 APEX pair.
    if (c + 36 > end) {
      return info;
    }
    const avCur = dv.getUint16(c + 8, false);
    const tvCur = dv.getInt16(c + 20, false);
    c += 36;
    if (c + 5 > end) {
      return info;
    }
    const currentExposure = dv.getInt8(c);
    info.focusDistance = dv.getUint16(c + 1, false);
    c += 5;
    if (c + 1 > end) {
      return info;
    }
    const nic = dv.getUint8(c);
    const iconBytes = Math.min(nic, end - (c + 1));
    c += 1 + (iconBytes > 0 ? iconBytes : 0);
    if (c + 28 > end) {
      return info;
    }
    c += 28;
    if (c + 1 > end) {
      return info;
    }
    const nsv = dv.getUint8(c);
    c += 1;
    info.tvCur256 = tvCur;
    info.avCur256 = avCur;
    info.shutterLabel = formatShutter(tvCur);
    info.apertureLabel = formatAperture(avCur);
    // Settings block: 75 bytes total; numSettingValue (0x49=73) only counts
    // through EVStep. Fixed offsets relative to the block start (verified).
    const bs = c;
    if (nsv >= 40 && bs + 40 <= end) {
      const exposureWord = dv.getUint16(bs, false);
      const iso = (dv.getUint32(bs + 4, false)) >>> 0;
      const wb = dv.getUint16(bs + 10, false);
      const recmode2 = dv.getUint16(bs + 14, false);
      const quality = dv.getUint16(bs + 22, false);
      const aspect = dv.getUint16(bs + 28, false);
      const metering = dv.getUint16(bs + 34, false);
      const lvSize = dv.getUint8(bs + 36);
      const operate = dv.getUint8(bs + 38);
      info.evThirds = exposureWord === 0xffff ? currentExposure : evThirdsOf(exposureWord);
      info.evLabel = formatEv(info.evThirds);
      info.isoValue = iso === 0xffffffff || iso === 0 ? -1 : iso;
      info.isoLabel = isoLabelOf(iso);
      info.wbValue = wb;
      info.wbLabel = wbLabelOf(wb);
      info.modeValue = recmode2;
      info.modeLabel = modeLabelOf(recmode2);
      info.qualityValue = quality;
      info.qualityLabel = qualityLabelOf(quality);
      info.aspectValue = aspect;
      info.aspectLabel = aspectLabelOf(aspect);
      info.meteringValue = metering;
      info.meteringLabel = meteringLabelOf(metering);
      info.lvQualityValue = lvSize;
      info.lvQualityLabel = lvQualityLabelOf(lvSize);
      // 官方 Q0 字段表（jadx N5/v0 settings 块，2026-09-29 核对）：exposure
      // bs+0、ss_angle bs+2、iso bs+4、db bs+8、whitebalance bs+10、recmode1
      // bs+12、recmode2 bs+14、recmode2value2 bs+16、photostyle bs+18、
      // focusmode bs+20、quality bs+22、…、photoFormat bs+54 —— 我方既有 9 个
      // 偏移与该表逐字吻合，据此补 photostyle/photoFormat。
      if (nsv >= 20) {
        const photoStyle = dv.getUint16(bs + 18, false);
        info.photoStyleValue = photoStyle;
        info.photoStyleLabel = photoStyleLabelOf(photoStyle);
      }
      if (nsv >= 56) {
        const pictureFormat = dv.getUint16(bs + 54, false);
        info.pictureFormatValue = pictureFormat;
        info.pictureFormatLabel = pictureFormatLabelOf(pictureFormat);
      }
      info.operateRemote = operate === 1;
    } else if (nsv > 0 && bs + 2 <= end) {
      // Degenerate block: fall back to the header exposure byte.
      info.evThirds = currentExposure;
      info.evLabel = formatEv(currentExposure);
    }
    return info;
  }

  /** JPEG SOF scan -> [width, height]; falls back to 640x432. */
  private static jpegSize(j: Uint8Array): number[] {
    let i = 2;
    while (i + 9 < j.length) {
      if (j[i] !== 0xff) {
        i++;
        continue;
      }
      const m = j[i + 1];
      if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7)) {
        i += 2;
        continue;
      }
      if (m === 0xd9) {
        break;
      }
      const segLen = (j[i + 2] << 8) | j[i + 3];
      if (segLen < 2) {
        break;
      }
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
        return [(j[i + 7] << 8) | j[i + 8], (j[i + 5] << 8) | j[i + 6]];
      }
      i += 2 + segLen;
    }
    return [640, 432];
  }

  private static log(message: string): void {
    AppDiagnostics.event('VIVID_CTRL', message);
    try {
      hilog.info(0x0001, 'VIVID_CTRL', '%{public}s', message);
      AppLogSink.emit('CTL', message);
    } catch (_error) {
    }
  }
}
