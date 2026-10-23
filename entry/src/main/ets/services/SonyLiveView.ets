/*
 * Sony live view + remote shutter.
 *
 * Sony has NO live-view operation in its private PTP opcode set. Live view is
 * three steps across two protocols, and this module implements exactly those.
 * Every constant below is quoted from the decompiled Sony Creator's App under
 * `Sony_CreatorApp/_rea_work/src/jp/co/sony/ips/portalapp/`; nothing is a
 * PTP-spec guess.
 *
 * ---------------------------------------------------------------------------
 * STEP 1 - ENABLE: `SDIO_ControlDevice` (opcode 0x9207 = 37383)
 * ---------------------------------------------------------------------------
 * `ptpip/base/packet/EnumOperationCode.java:26`  SDIO_ControlDevice(37383)
 * `ptpip/base/transaction/SDIO_ControlDevice.java:10-17`
 *
 *     super(EnumDataPhaseInfo.DataOutPhase, EnumOperationCode.SDIO_ControlDevice,
 *           iArr, bArr, callback);
 *
 *     create(code, flagOption, controlValue, callback) =
 *       flagOption == ENABLE
 *         ? new SDIO_ControlDevice({code.mCode, flagOption.value},
 *                                  code.getData(controlValue), callback)
 *         : new SDIO_ControlDevice({code.mCode},
 *                                  code.getData(controlValue), callback)
 *
 * So the parameter array is `{controlCode, 1}` when the body's vendor code
 * version is at least 310 and `{controlCode}` below that
 * (`ptpip/base/transaction/EnumFlagOfDevicePropertyOption.java:21-30`:
 * `NONE(0)`, `ENABLE(1)`, `Companion.valueOf(v) = v >= 310 ? ENABLE : NONE`;
 * the caller passes `BasePtpManager.vendorCodeVersion1`).
 *
 * The data-phase payload is `EnumControlCode.getData(controlValue)`, whose
 * length is decided by the enum ORDINAL
 * (`ptpip/base/transaction/EnumControlCode.java:54-102`):
 *
 *   - `SetLiveViewEnable(54035)` is ordinal 37 (`:46`), which the `case 37` at
 *     `:83` sends to the two-byte branch at `:98-101` - a little-endian short.
 *   - `RequestOneShooting(53959)` is ordinal 5 (`:14`). Ordinal 5 appears in NO
 *     case of that method (the cases are 1,2,3,4,6,7,12 / 16-19 / 21,24 /
 *     22,25,27-37 / 23,26), so it reaches the `default` branch at `:91-93`:
 *
 *         AdbAssert.shouldNeverReachHere(this + " is undefined.");
 *         return new byte[0];
 *
 *     THE SHUTTER'S DATA PAYLOAD IS THEREFORE ZERO BYTES, and its control value
 *     is never read. See `requestOneShooting()` below.
 *
 * The control VALUE for `SetLiveViewEnable` comes from which of Sony's two
 * button entry points ran (`ptpip/BasePtpManager.java`):
 *
 *   pressButton   case 41, `:1578-1579`, uses `enumControlValue3` =
 *                 `EnumControlValue.Down` = 2 (`:1406`, `:6-14`)
 *   releaseButton case 41, `:1737-1738`, uses `enumControlValue2` =
 *                 `EnumControlValue.Up` = 1 (`:1592`)
 *
 * and `BaseCamera.sendControlCode(..., z, ...)` maps `z == true` to
 * `pressButton` (`camera/BaseCamera.java:248-249`). `BaseCamera.java:471` and
 * `:477` call it with `true`; `camera/CameraConnector.java:938` calls it with
 * `false`. Hence:
 *
 *     enable  = 0x9207 {54035, flag} + payload 02 00   (LE short 2)
 *     disable = 0x9207 {54035, flag} + payload 01 00   (LE short 1)
 *     shutter = 0x9207 {53959, flag} + payload <empty>
 *
 * Sony's own PTP/IP transport downgrades a zero-length data-out to a plain
 * operation request with NO data frames at all
 * (`ptpip/ptpip/base/transaction/TransactionExecutor.java:133-139`), which is
 * what `NikonPtpIpService.sendControlData` reproduces.
 *
 * ---------------------------------------------------------------------------
 * STEP 2 - URL: device property `LiveViewUrl` (53880 = 0xD278), a STRING
 * ---------------------------------------------------------------------------
 * `ptpip/base/transaction/EnumDevicePropCode.java:109`
 *     LiveViewUrl(53880, "LiveView URL")
 * `camera/PtpIpCamera.java:705-721` takes it as `mCurrentStringValue` into
 * `mLiveviewUrl`. Fallback: `X_ScalarWebAPI_LiveView_URL` in the DD document
 * (`common/device/DeviceDescription.java:91-94`). Both live in
 * `SonyPtpIpContent.readLiveViewUrl`.
 *
 * ---------------------------------------------------------------------------
 * STEP 3 - STREAM: one HTTP GET on port 60152, frames delimited in-band
 * ---------------------------------------------------------------------------
 * `ptpip/liveview/http/AbstractEeImageDownloader.java:151-198` opens
 * `(HttpURLConnection) NetworkUtil.openConnection(P2P, new URL(mUrl))`, sets
 * connect/read timeouts of 10 s and the single header `Connection: close`
 * (`:164-166`), requires response code 200 (`:167-168`) and then reads
 * `getInputStream()` through a BufferedInputStream (`:178`). The method is not
 * overridden anywhere, so it is a plain GET.
 *
 * Port 60152 is `camera/PtpIpCamera.java:195` (`this.mStreamingPort = 60152`).
 * Note `:711` uses the property URL verbatim and `:715` rewrites only its port
 * to `mStreamingPort`; see `resolveTarget` for which branch this port takes.
 *
 * THE FRAME BOUNDARY (the crux). Despite the class name
 * `ChunkedPermanentEeImageDownloader`, this is NOT HTTP
 * `Transfer-Encoding: chunked`; it is a never-ending 200 response whose body is
 * a back-to-back sequence of frames, each introduced by an explicit 16-byte
 * little-endian header (`AbstractEeImageDownloader.java:50-149`):
 *
 *     bytes  0.. 3  OffsetToLiveViewImage      (`:88`, `ByteUtil.getUINT32`)
 *     bytes  4.. 7  LiveViewImageSize          (`:89`)
 *     bytes  8..11  OffsetToFocalFrameInfo     (`:90`)
 *     bytes 12..15  FocalFrameInfoSize         (`:91`)
 *     ReservedSize = min(OffsetToFocalFrameInfo, OffsetToLiveViewImage) - 16
 *                                              (`:92-98`)
 *     one frame    = 16 + ReservedSize + LiveViewImageSize + FocalFrameInfoSize
 *                                              (:102 reads exactly that many
 *                                               more bytes; :127 asserts the
 *                                               total landed exactly)
 *
 * The JPEG is `frame[OffsetToLiveViewImage .. + LiveViewImageSize)`, which is
 * precisely what `ptpip/liveview/dataset/LiveViewDataset.java:91-95` decodes:
 * `getInt()` offset, `getInt()` size, then
 * `BitmapFactory.decodeByteArray(byteBuffer.array(), i6, i7)`. The AF / face /
 * tracking / level overlay lives in the focal-frame-info block and is discarded
 * here on purpose.
 *
 * A private protocol still has to be robust, so a header whose length fields do
 * not add up terminates the stream instead of desynchronising it.
 *
 * ---------------------------------------------------------------------------
 * LIFECYCLE
 * ---------------------------------------------------------------------------
 * `camera/BaseCamera.java:461-482` `startLiveView` sends
 * `SetLiveViewEnable(true)` and only from its callback
 * (`BaseCamera.AnonymousClass4`, `:62-77`) calls `setLiveViewStreamCallback()`,
 * which is what opens the HTTP GET (`ptpip/PtpIpClient.java:861-940`, the
 * downloader is built at `:937`). Line `:69` starts the stream even when the
 * 0x9207 was REFUSED, so a refusal is logged and not treated as fatal here
 * either. Teardown is the mirror image: `camera/PtpIpCamera.java:939-946`
 * closes the stream first (`setLiveViewStreamCallback(null, ...)`), and only
 * then `camera/CameraConnector.java:937-938` sends `SetLiveViewEnable(false)`.
 *
 * The support gate is `camera/PtpIpCamera.java:214-217` `canGetLiveView`,
 * which requires property `LiveViewStatus` to read
 * `EnumLiveViewStatus.LiveViewSupportAndEnable` (value 2,
 * `ptpip/property/value/EnumLiveViewStatus.java:10`).
 *
 * This module does not drive Nikon's live-view path in any way: it never
 * issues 0x9201/0x9202/0x9203, and it never touches the shared transport's
 * live-view calls.
 */

import socket from '@ohos.net.socket';
import { NikonPtpIpService, NikonPtpSession, PtpTransport } from './NikonPtpIpService';
import { SonyPtpIpContent } from './SonyPtpIpContent';
import { SonyUsbPtp } from './SonyUsbPtp';

/** Outcome of starting the Sony live-view line. */
export interface SonyLiveViewStart {
  ok: boolean;
  /** The URL the HTTP GET was aimed at, '' when none was found. */
  url: string;
  /** Response code of the 0x9207 enable, -1 when it never ran. */
  enableCode: number;
  /** Human-readable reason when `ok` is false. */
  reason: string;
}

/** One parsed HTTP target. */
interface SonyLiveViewTarget {
  host: string;
  port: number;
  /** Request-URI: path plus query. */
  requestUri: string;
  /** Where the port came from, for the log line. */
  portSource: string;
}

/**
 * Sony's live-view line: the two 0x9207 control operations on the shared
 * PTP/IP session, and the separate HTTP stream that carries the JPEGs.
 */
export class SonyLiveView {
  // --- Step 1: SDIO_ControlDevice (0x9207) ---------------------------------
  /** `EnumOperationCode.SDIO_ControlDevice(37383)`,
   * `ptpip/base/packet/EnumOperationCode.java:26`. */
  static readonly OP_SDIO_CONTROL_DEVICE = 0x9207;
  /** `EnumControlCode.SetLiveViewEnable(54035)`,
   * `ptpip/base/transaction/EnumControlCode.java:46`. */
  static readonly CONTROL_CODE_SET_LIVE_VIEW_ENABLE = 54035;
  /** `EnumControlCode.RequestOneShooting(53959)`,
   * `ptpip/base/transaction/EnumControlCode.java:14`. */
  static readonly CONTROL_CODE_REQUEST_ONE_SHOOTING = 53959;
  /** `EnumControlValue.Down` = 2, the value `pressButton` passes for
   * SetLiveViewEnable (`ptpip/BasePtpManager.java:1406`, `:1579`), i.e. the
   * value that ENABLES live view. */
  static readonly CONTROL_VALUE_SET_LIVE_VIEW_ENABLE = 2;
  /** `EnumControlValue.Up` = 1, the value `releaseButton` passes for
   * SetLiveViewEnable (`ptpip/BasePtpManager.java:1592`, `:1738`), i.e. the
   * value that DISABLES live view. */
  static readonly CONTROL_VALUE_SET_LIVE_VIEW_DISABLE = 1;
  /** The threshold `EnumFlagOfDevicePropertyOption.Companion.valueOf` uses to
   * decide between NONE and ENABLE
   * (`ptpip/base/transaction/EnumFlagOfDevicePropertyOption.java:30`). */
  static readonly VENDOR_CODE_VERSION_FOR_PROPERTY_FLAG = 310;

  // --- Step 1b: the AF half-press and touch control codes -------------------
  /** `EnumControlCode.S1Button(53953)`, `EnumControlCode.java:10`. Its ordinal
   * is 1, so `getData` takes the 2-byte little-endian branch
   * (`EnumControlCode.java:56`, `:98-101`) — the same payload shape as
   * `SetLiveViewEnable` above. `BasePtpManager.pressButton` case 0 builds it
   * with `EnumControlValue.Down` (`BasePtpManager.java:1406`, `:1420-1421`) and
   * `releaseButton` with `EnumControlValue.Up` (`BasePtpManager.java:1592`). */
  static readonly CONTROL_CODE_S1_BUTTON = 53953;
  /** `EnumControlCode.S2Button(53954)`, `EnumControlCode.java:11` — the actual
   * shutter. Sony's still sequence presses this, NOT `RequestOneShooting`;
   * ordinal 2, so it shares S1's 2-byte little-endian payload
   * (`EnumControlCode.java:56`, `:98-101`). */
  static readonly CONTROL_CODE_S2_BUTTON = 53954;
  /** `EnumControlCode.MovieRecButton(53960)`, `EnumControlCode.java:15` — the
   * movie record button. Ordinal **6**, which is in the same first branch as S1
   * and S2, so it also takes a 2-byte little-endian `EnumControlValue`
   * (`EnumControlCode.java:56`, `:98-101`). */
  static readonly CONTROL_CODE_MOVIE_REC_BUTTON = 53960;
  /** `EnumControlCode.RemoteTouchOperation(53988)`, `EnumControlCode.java:35`. */
  static readonly CONTROL_CODE_REMOTE_TOUCH_OPERATION = 53988;
  /** `EnumControlCode.CancelRemoteTouchOperation(53989)`,
   * `EnumControlCode.java:36`. */
  static readonly CONTROL_CODE_CANCEL_REMOTE_TOUCH = 53989;
  /** `EnumControlValue.Down` = 2, the press value (`EnumControlValue.java:8`). */
  static readonly CONTROL_VALUE_DOWN = 2;
  /** `EnumControlValue.Up` = 1, the release value (`EnumControlValue.java:7`). */
  static readonly CONTROL_VALUE_UP = 1;
  /**
   * The grid a touch position is expressed in. This is NOT the live view frame
   * size: `RangePosition` asserts `x <= 639` and `y <= 479`
   * (`ptpip/button/RangePosition.java:18-19`), and
   * `TouchOperationController` maps the view point onto it with `640 / width`
   * and `480 / height` (`.../liveview/TouchOperationController.java:190-192`,
   * `:196-197`, `:225`).
   */
  static readonly AF_GRID_WIDTH = 640;
  static readonly AF_GRID_HEIGHT = 480;

  // --- Step 3: the HTTP stream ---------------------------------------------
  /** `PtpIpCamera.mStreamingPort` (`camera/PtpIpCamera.java:195`). Used ONLY
   * when the URL from property 0xD278 carries no port of its own; `:711` uses
   * that URL verbatim and `:715` substitutes this port. */
  static readonly STREAMING_PORT = 60152;
  /** This port's own sanity bound on a single frame. The camera's live-view
   * JPEGs are tens of kilobytes; the bound exists so a desynchronised stream
   * (a corrupt 16-byte header) is rejected instead of buffering forever. It is
   * NOT a value read from Sony's sources. */
  static readonly MAX_FRAME_BYTES = 8 * 1024 * 1024;
  /** Same rationale: a header block that never terminates is a broken
   * response, not a slow camera. */
  static readonly MAX_HEADER_BYTES = 16 * 1024;

  private static stream: SonyLiveViewStream | null = null;
  /**
   * USB 取帧源。USB 上没有 HTTP 流可读，帧来自 `GetObject(0xFFFFC002)`，
   * 所以另起一个同形的帧源，`nextFrame()` 只多一个分支，取帧循环与页面都不用改。
   */
  private static usbStream: SonyLiveViewUsbStream | null = null;
  private static lastEnableCode: number = -1;
  private static lastShutterCode: number = -1;
  /** Response code of the most recent 0x9207 S1 half-press, -1 if none. */
  private static lastS1Code: number = -1;
  /** Response code of the most recent 0x9207 touch, -1 if none. */
  private static lastTouchCode: number = -1;
  private static cachedVendorCodeVersion: number = -2;

  /** Response code of the most recent 0x9207 enable/disable, -1 if none. */
  static enableCode(): number {
    return SonyLiveView.lastEnableCode;
  }

  /** Response code of the most recent 0x9207 shutter, -1 if none. */
  static shutterCode(): number {
    return SonyLiveView.lastShutterCode;
  }

  static isStreaming(): boolean {
    const usb = SonyLiveView.usbStream;
    if (usb !== null) return usb.isStreaming();
    const stream = SonyLiveView.stream;
    return stream !== null && stream.isStreaming();
  }

  /**
   * Why the stream stopped, '' while it is healthy. The page uses this for its
   * status text so "stream ended because the camera closed the socket" is not
   * indistinguishable from "no frames yet".
   */
  static streamReason(): string {
    const usb = SonyLiveView.usbStream;
    if (usb !== null) return usb.reason();
    const stream = SonyLiveView.stream;
    return stream === null ? '' : stream.reason();
  }

  /** Frames delivered since the stream opened. */
  static framesReceived(): number {
    const usb = SonyLiveView.usbStream;
    if (usb !== null) return usb.framesReceived();
    const stream = SonyLiveView.stream;
    return stream === null ? 0 : stream.framesReceived();
  }

  /**
   * `EnumFlagOfDevicePropertyOption` for this body, as the second element of a
   * vendor operation's parameter array: `1` when the vendor code version is at
   * least 310, otherwise the parameter is omitted entirely.
   *
   * The version itself is `SDIO_GetVendorCodeVersion` (0x9216)'s first response
   * parameter, read once per run and cached. A refusal yields -1, which maps to
   * NONE exactly as Sony's `Companion.valueOf` does.
   *
   * Shared with the property setters (`SonyPtpIpControl`), whose 0x9205
   * parameter array uses the same rule.
   */
  static async propertyFlag(session: PtpTransport): Promise<number> {
    // Prefer the version the browse's six-step setup ALREADY read. On a
    // remote-control session a second `SDIO_GetVendorCodeVersion` answers
    // 0x2005, and treating that as "unknown" is not harmless: the flag becomes
    // 0, `SDIO_ControlDevice` is then sent ONE parameter (`params=[54035]`)
    // where this body wants `[54035,1]`, the body refuses that with 0x2005, and
    // because live view was never enabled the stream answers 503 instead of
    // 200. Observed on the ILCE-7M4 as `sony setup vendor-code-version
    // version=310 propertyFlag=1` in the same session as `sony property-flag
    // vendorCodeVersion=unknown flag=0`.
    if (SonyLiveView.cachedVendorCodeVersion === -2) {
      const known = SonyPtpIpContent.vendorVersion();
      if (known >= 0) {
        SonyLiveView.cachedVendorCodeVersion = known;
      }
    }
    if (SonyLiveView.cachedVendorCodeVersion === -2) {
      try {
        SonyLiveView.cachedVendorCodeVersion =
          await SonyPtpIpContent.readVendorCodeVersion(session);
      } catch (error) {
        // 读版本号失败不能把整条按键序列一起带走（否则一次读超时就让快门失灵）：
        // 退回「不带 flag」的老参数形状，再由机身决定受不受理。
        SonyLiveView.cachedVendorCodeVersion = 0;
        NikonPtpIpService.log('sony property-flag read failed: ' +
          SonyLiveView.errorText(error as Error));
      }
    }
    const version = SonyLiveView.cachedVendorCodeVersion;
    const enable = version >= SonyLiveView.VENDOR_CODE_VERSION_FOR_PROPERTY_FLAG;
    NikonPtpIpService.log(`sony property-flag` +
      ` vendorCodeVersion=${version < 0 ? 'unknown' : version}` +
      ` flag=${enable ? 1 : 0}`);
    return enable ? 1 : 0;
  }

  /** `SDIO_ControlDevice.create`'s parameter array for one control code. */
  private static controlParams(code: number, flag: number): number[] {
    return flag > 0 ? [code, flag] : [code];
  }

  /** Little-endian u16, the payload `EnumControlCode.getData` builds for
   * `SetLiveViewEnable` (`EnumControlCode.java:98-101`). */
  private static controlValuePayload(value: number): Uint8Array {
    const payload = new Uint8Array(2);
    payload[0] = value & 0xFF;
    payload[1] = (value >> 8) & 0xFF;
    return payload;
  }

  /** Little-endian u32, the payload `getData` builds for the two 4-byte
   * ordinals — `AFAreaPosition`(23) and `RemoteTouchOperation`(26)
   * (`EnumControlCode.java:85-90` allocates 4 bytes, orders LITTLE_ENDIAN and
   * puts the whole `IControlValue.getValue()` as one int). */
  private static controlIntPayload(value: number): Uint8Array {
    const payload = new Uint8Array(4);
    payload[0] = value & 0xFF;
    payload[1] = (value >>> 8) & 0xFF;
    payload[2] = (value >>> 16) & 0xFF;
    payload[3] = (value >>> 24) & 0xFF;
    return payload;
  }

  /**
   * `RangePosition`'s packed value: x in the HIGH 16 bits, y in the LOW 16 —
   * `this.mValue = ((i << 16) & 0xFFFF0000) + (i2 & 0xFFFF)`
   * (`ptpip/button/RangePosition.java:20`).
   *
   * The arguments are already grid coordinates (`AF_GRID_WIDTH` x
   * `AF_GRID_HEIGHT`); they are clamped, not rescaled, because the class
   * asserts on the range and a caller mapping a view point onto the grid can
   * land one past the edge on a rounding boundary.
   */
  static packAfPosition(gridX: number, gridY: number): number {
    const x = Math.max(0, Math.min(SonyLiveView.AF_GRID_WIDTH - 1, Math.round(gridX)));
    const y = Math.max(0, Math.min(SonyLiveView.AF_GRID_HEIGHT - 1, Math.round(gridY)));
    return (((x << 16) >>> 0) | (y & 0xFFFF)) >>> 0;
  }

  /**
   * S1 half-press: `0x9207 {53953, flag}` with a 2-byte little-endian
   * `EnumControlValue` — `Down`(2) to press, `Up`(1) to release
   * (`BasePtpManager.java:1406`, `:1420-1421` for the press, `:1592` for the
   * release). S1 is what starts autofocus; the shutter is a separate
   * `RequestOneShooting` and S1 must be released again (see `captureWithAf`).
   *
   * Returns the raw response code, -1 when there is no session.
   */
  /**
   * A press/release button: `0x9207 {code, flag}` with a 2-byte little-endian
   * `EnumControlValue` — `Down`(2) to press, `Up`(1) to release
   * (`BasePtpManager.java:1406`/`:1421` and `:1425` for the press, `:1592`/
   * `:1607` and `:1611` for the release).
   *
   * Returns the raw response code, -1 when there is no session.
   */
  private static async setButton(code: number, name: string,
    pressed: boolean): Promise<number> {
    const session = NikonPtpIpService.activeControlTransport();
    if (session === null) {
      NikonPtpIpService.log(`sony ${name} skipped: no control transport`);
      return -1;
    }
    const flag = await SonyLiveView.propertyFlag(session);
    const value = pressed ? SonyLiveView.CONTROL_VALUE_DOWN : SonyLiveView.CONTROL_VALUE_UP;
    const params = SonyLiveView.controlParams(code, flag);
    const result = await NikonPtpIpService.sendControlData(
      SonyLiveView.OP_SDIO_CONTROL_DEVICE, params,
      SonyLiveView.controlValuePayload(value));
    NikonPtpIpService.log(`sony ${name} button=${pressed ? 'down' : 'up'}` +
      ` op=0x9207 params=[${params.join(',')}]` +
      ` payload=[${value & 0xFF},${(value >>> 8) & 0xFF}]` +
      ` code=${SonyLiveView.hex(result)}`);
    return result;
  }

  /**
   * S1 half-press — what starts autofocus, and what must be held while the
   * shutter fires. See `captureStill` for the sequence that uses it.
   */
  static async setS1Button(pressed: boolean): Promise<number> {
    const code = await SonyLiveView.setButton(
      SonyLiveView.CONTROL_CODE_S1_BUTTON, 's1', pressed);
    SonyLiveView.lastS1Code = code;
    return code;
  }

  /**
   * S2 — the actual shutter release, pressed and released as a pair for one
   * still. Sony's app never sends `RequestOneShooting` (53959) for this.
   */
  static async setS2Button(pressed: boolean): Promise<number> {
    return SonyLiveView.setButton(
      SonyLiveView.CONTROL_CODE_S2_BUTTON, 's2', pressed);
  }

  /**
   * Start movie recording. Sony's own app sends **only the press** here:
   * `iPtpClient.pressButton(EnumButton.MovieRec, ...)`
   * (`.../shoot/mode/MovieRecMode.java:45`, inside `State.NotRecording`). There is
   * deliberately no `releaseButton` on this path.
   */
  static async startMovieRecording(): Promise<number> {
    return SonyLiveView.setButton(
      SonyLiveView.CONTROL_CODE_MOVIE_REC_BUTTON, 'movierec-down', true);
  }

  /**
   * Stop movie recording. Sony's own app sends a press **and then a release**:
   * `pressButton(...)` followed by `releaseButton(...)`
   * (`.../shoot/mode/MovieRecMode.java:142-143`, inside `State.Recording`). The
   * asymmetry with the start path is Sony's, not ours — reproduced verbatim.
   */
  static async stopMovieRecording(): Promise<number> {
    const down = await SonyLiveView.setButton(
      SonyLiveView.CONTROL_CODE_MOVIE_REC_BUTTON, 'movierec-down', true);
    await SonyLiveView.setButton(
      SonyLiveView.CONTROL_CODE_MOVIE_REC_BUTTON, 'movierec-up', false);
    return down;
  }

  /**
   * One still, the way Sony's own app does it.
   *
   * Official sequence (`.../controller/shoot/mode/StillShootMode.java:26-41`):
   * finger-down sends **S1 down**; finger-up sends **S2 down, S2 up, S1 up**
   * back-to-back. So the shutter is S2, and `RequestOneShooting` (53959) — the
   * code this app used to send — has no caller anywhere in Sony's tree and is
   * in fact a 0-byte data-phase request, because ordinal 5 has no case in
   * `EnumControlCode.getData` (`EnumControlCode.java:91-93`).
   *
   * There is deliberately **no focus wait**. Sony's shutter is not gated on
   * `FocusIndication` (53779) at all — that property feeds a status icon and
   * nothing in the shoot path reads it (`.../controller/status/FocusStatusController.java`).
   * Holding S1 is what makes the camera autofocus; the full press then fires.
   * Inserting a poll here would not be more correct, only slower.
   *
   * The four transactions are sent strictly one at a time, awaiting each
   * response, which is Sony's own executor policy (`TransactionExecutor.java:52-58`,
   * `:165-169`).
   *
   * S1 is released on every path, including failure — Sony releases it
   * unconditionally (`StillShootMode.java:41`) and has separate safety releases
   * elsewhere (`ShootingController.java:153-159`). Leaving it down would hold the
   * camera half-pressed.
   *
   * @param withAf send the S1 half-press first. Without it this is a bare
   *   S2 press/release, which is exactly an "instant" still.
   * @returns the response code that decides the shot: S2's release, or S2's
   *   press when the release never happened. S1's own code is reported only in
   *   the log, because Sony does not check the responses before firing.
   */
  static async captureStill(withAf: boolean): Promise<number> {
    if (withAf) {
      const s1Down = await SonyLiveView.setS1Button(true);
      if (s1Down !== SonyPtpIpContent.RESPONSE_OK) {
        NikonPtpIpService.log(`sony capture s1 down not accepted code=${SonyLiveView.hex(s1Down)}` +
          ' — firing anyway, as Sony does');
      }
    }
    let s2Down = -1;
    let s2Up = -1;
    try {
      s2Down = await SonyLiveView.setS2Button(true);
      s2Up = await SonyLiveView.setS2Button(false);
    } finally {
      if (withAf) {
        try {
          await SonyLiveView.setS1Button(false);
        } catch (error) {
          NikonPtpIpService.log(`sony capture s1 release threw: ${String(error)}`);
        }
      }
    }
    return s2Down === SonyPtpIpContent.RESPONSE_OK ? s2Up : s2Down;
  }

  /**
   * Touch AF: `0x9207 {53988, flag}` with the packed grid position as 4 bytes.
   *
   * ONE send per touch event, with no Down/Up pair: `RemoteTouchOperation.mValue`
   * IS the `RangePosition` itself (`ptpip/button/RemoteTouchOperation.java:11`,
   * `:17`) and `BasePtpManager.pressButton(RangePosition, ...)` passes it
   * straight into the transaction (`BasePtpManager.java:2190-2191`) — unlike the
   * on/off buttons, this operation carries no `EnumControlValue`.
   *
   * Returns the raw response code, -1 when there is no session.
   */
  static async remoteTouch(gridX: number, gridY: number): Promise<number> {
    const session = NikonPtpIpService.activeControlTransport();
    if (session === null) {
      NikonPtpIpService.log('sony touch skipped: no control transport');
      return -1;
    }
    const flag = await SonyLiveView.propertyFlag(session);
    const params = SonyLiveView.controlParams(
      SonyLiveView.CONTROL_CODE_REMOTE_TOUCH_OPERATION, flag);
    const packed = SonyLiveView.packAfPosition(gridX, gridY);
    const code = await NikonPtpIpService.sendControlData(
      SonyLiveView.OP_SDIO_CONTROL_DEVICE, params,
      SonyLiveView.controlIntPayload(packed));
    SonyLiveView.lastTouchCode = code;
    NikonPtpIpService.log(`sony touch remote-touch-operation` +
      ` op=0x9207 params=[${params.join(',')}]` +
      ` grid=${gridX},${gridY}` +
      ` packed=0x${packed.toString(16).padStart(8, '0').toUpperCase()}` +
      ` code=${SonyLiveView.hex(code)}`);
    return code;
  }

  /**
   * Ends a touch operation: `0x9207 {53989, flag}` with the 2-byte
   * `EnumControlValue` (`CancelRemoteTouchOperation` is ordinal 27, so it takes
   * the 2-byte branch; `EnumControlCode.java:73`, `:98-101`).
   *
   * Sony sends it as a normal press/release pair of that button
   * (`TouchOperationController.java:364` presses and `:374` releases), so this
   * exposes the same `pressed` flag rather than inventing a single value.
   */
  static async cancelRemoteTouch(pressed: boolean): Promise<number> {
    const session = NikonPtpIpService.activeControlTransport();
    if (session === null) {
      NikonPtpIpService.log('sony touch-cancel skipped: no control transport');
      return -1;
    }
    const flag = await SonyLiveView.propertyFlag(session);
    const value = pressed ? SonyLiveView.CONTROL_VALUE_DOWN : SonyLiveView.CONTROL_VALUE_UP;
    const params = SonyLiveView.controlParams(
      SonyLiveView.CONTROL_CODE_CANCEL_REMOTE_TOUCH, flag);
    const code = await NikonPtpIpService.sendControlData(
      SonyLiveView.OP_SDIO_CONTROL_DEVICE, params,
      SonyLiveView.controlValuePayload(value));
    NikonPtpIpService.log(`sony touch-cancel button=${pressed ? 'down' : 'up'}` +
      ` op=0x9207 params=[${params.join(',')}]` +
      ` payload=[${value & 0xFF},${(value >>> 8) & 0xFF}]` +
      ` code=${SonyLiveView.hex(code)}`);
    return code;
  }

  /**
   * Step 1, the enable half: `0x9207 {54035, flag}` with payload `02 00`.
   * Returns the raw response code, -1 when there is no session.
   */
  static async setLiveViewEnable(enable: boolean): Promise<number> {
    const session = NikonPtpIpService.activeControlTransport();
    if (session === null) {
      NikonPtpIpService.log('sony liveview enable skipped: no control transport');
      return -1;
    }
    const flag = await SonyLiveView.propertyFlag(session);
    const value = enable
      ? SonyLiveView.CONTROL_VALUE_SET_LIVE_VIEW_ENABLE
      : SonyLiveView.CONTROL_VALUE_SET_LIVE_VIEW_DISABLE;
    const params = SonyLiveView.controlParams(
      SonyLiveView.CONTROL_CODE_SET_LIVE_VIEW_ENABLE, flag);
    const code = await NikonPtpIpService.sendControlData(
      SonyLiveView.OP_SDIO_CONTROL_DEVICE, params,
      SonyLiveView.controlValuePayload(value));
    SonyLiveView.lastEnableCode = code;
    NikonPtpIpService.log(`sony liveview enable=${enable ? 1 : 0}` +
      ` op=0x9207 params=[${params.join(',')}]` +
      ` payload=[${value & 0xFF},${(value >> 8) & 0xFF}]` +
      ` code=${SonyLiveView.hex(code)}`);
    return code;
  }

  /**
   * SUPERSEDED — kept only because it is the path this app shipped first and it
   * remains a useful diagnostic. Do not use it for a still: Sony's own app never
   * sends this code (it has no caller anywhere in the tree) and its ordinal 5 has
   * no case in `EnumControlCode.getData`, so the payload is `new byte[0]` and the
   * transport sends no data frames at all (`EnumControlCode.java:91-93`,
   * `TransactionExecutor.java:133-134`). `captureStill` is the real thing.
   *
   * `0x9207 {53959, flag}` with that zero-length payload.
   *
   * Returns the raw response code, -1 when there is no session.
   */
  static async requestOneShooting(): Promise<number> {
    const session = NikonPtpIpService.activeControlTransport();
    if (session === null) {
      NikonPtpIpService.log('sony shutter skipped: no control transport');
      return -1;
    }
    const flag = await SonyLiveView.propertyFlag(session);
    const params = SonyLiveView.controlParams(
      SonyLiveView.CONTROL_CODE_REQUEST_ONE_SHOOTING, flag);
    const code = await NikonPtpIpService.sendControlData(
      SonyLiveView.OP_SDIO_CONTROL_DEVICE, params, new Uint8Array(0));
    SonyLiveView.lastShutterCode = code;
    NikonPtpIpService.log(`sony shutter request-one-shooting` +
      ` op=0x9207 params=[${params.join(',')}] payload=<empty>` +
      ` code=${SonyLiveView.hex(code)}`);
    return code;
  }

  /**
   * Makes sure the live session is the one remote control needs.
   *
   * `SDIO_ControlDevice` (0x9207) is a button operation, and Sony's own client
   * only ever issues it on the session `SDIO_OpenSession` (0x9210) established
   * with `REMOTE_CONTROL_WITH_TRANSFER_MODE`: `BasePtpManager.pressButton`
   * bails out unless that session is connected (`ptpip/BasePtpManager.java:1409`),
   * and the session's function mode is a property of the OPEN operation, not
   * something a later request can change (`initialization/Initializer.java:83-96`
   * makes `SDIO_OpenSession [1, functionMode]` and the standard
   * `OpenSession [1]` the two branches of one if/else).
   *
   * So the session the camera page raised with a plain `OpenSession` is
   * replaced by the vendor one here, with the same retry policy the contents
   * line uses. Returns false when no vendor session could be obtained; the page
   * then reports "session not ready" instead of sending an operation the body
   * would refuse.
   */
  static async ensureRemoteControlSession(): Promise<boolean> {
    const existing = NikonPtpIpService.currentSession();
    if (existing === null) {
      // USB：会话由 `SonyUsbPtp` 用 `SDIO_OpenSession`(0x9210) 建立，六步 setup
      // 也已由 `SonyPtpIpContent.openViaTransport()` 跑完，没有「升级会话」这一步。
      const transport = NikonPtpIpService.activeControlTransport();
      if (transport !== null) {
        NikonPtpIpService.log(`sony liveview session=usb` +
          ` openOpcode=${SonyLiveView.hex(transport.openOpcode)}`);
        return true;
      }
      NikonPtpIpService.log('sony liveview session-missing');
      return false;
    }
    const session = existing;
    if (session.openOpcode === SonyPtpIpContent.OP_SDIO_OPEN_SESSION) {
      NikonPtpIpService.log(`sony liveview session=remote-control` +
        ` openOpcode=${SonyLiveView.hex(session.openOpcode)}`);
      await SonyLiveView.ensurePropertyTable(session);
      return true;
    }
    NikonPtpIpService.log(`sony liveview session-upgrade` +
      ` openOpcode=${SonyLiveView.hex(session.openOpcode)}` +
      ` asked=${SonyLiveView.hex(SonyPtpIpContent.OP_SDIO_OPEN_SESSION)}` +
      ` params=[${SonyPtpIpContent.SESSION_ID},` +
      `${SonyPtpIpContent.FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER}]`);
    try {
      await NikonPtpIpService.acquireSession(session.host,
        SonyPtpIpContent.OP_SDIO_OPEN_SESSION,
        [SonyPtpIpContent.SESSION_ID,
          SonyPtpIpContent.FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER],
        false, SonyPtpIpContent.SESSION_OPEN_ATTEMPTS);
    } catch (error) {
      NikonPtpIpService.log(`sony liveview session-upgrade failed` +
        ` error=${SonyLiveView.errorText(error as Error)}`);
      NikonPtpIpService.logError('sony liveview session-upgrade', error as Object);
      return false;
    }
    const upgraded = NikonPtpIpService.currentSession();
    if (upgraded === null) {
      return false;
    }
    const ok = upgraded.openOpcode === SonyPtpIpContent.OP_SDIO_OPEN_SESSION;
    NikonPtpIpService.log(`sony liveview session=remote-control ok=${ok ? 1 : 0}` +
      ` openOpcode=${SonyLiveView.hex(upgraded.openOpcode)}`);
    if (ok) {
      // `SDIO_OpenSession` on its own only establishes
      // REMOTE_CONTROL_WITH_TRANSFER_MODE. The six setup steps are what make the
      // body ANSWER vendor operations at all: on a session that went straight
      // from 0x1002 to 0x9210 without them, `SDIO_GetAllExtDevicePropInfo`
      // answered `code=0x2005 bytes=0` (OperationNotSupported) and so did the
      // live-view enable, which left the stream at 503 while the browse's own
      // session — which DID run the steps — was reading 351 properties
      // successfully two seconds earlier. So a session created by upgrading must
      // be initialized exactly like the one the browse creates.
      const raised = await SonyPtpIpContent.setupSonySession(upgraded);
      NikonPtpIpService.log(`sony liveview session-upgrade setup=${raised ? 'ok' : 'refused'}` +
        ` vendorCodeVersion=${SonyPtpIpContent.vendorVersion()}`);
      await SonyLiveView.ensurePropertyTable(upgraded);
    }
    return ok;
  }

  /**
   * Makes sure the accumulated Sony device-property table covers this session,
   * dumping it when it does not.
   *
   * Everything the control page needs is read out of that one table: the
   * live-view URL (`LiveViewUrl`, 53880), the four parameter rows, and the two
   * touch gates. But the table belongs to a browse attempt —
   * `SonyPtpIpContent.close()` drops it, and the camera page runs that when you
   * navigate away from it, which is precisely the navigation that lands you
   * here. Depending on it therefore made the control page fail in a way that
   * looked like a camera fault: a session whose browse had just parsed 351
   * records reported `aperture=-- … writable=0/4` and `strings=0`, searched an
   * empty table for the URL, fell back to the description document's
   * `X_ScalarWebAPI_LiveView_URL` (which belongs to the SSH/WebAPI path) and got
   * 404. One `SDIO_GetAllExtDevicePropInfo` (0x9209) round trip restores it, and
   * it is skipped whenever a table is already there.
   */
  private static async ensurePropertyTable(session: NikonPtpSession): Promise<void> {
    if (SonyPtpIpContent.hasPropertyTable()) {
      return;
    }
    NikonPtpIpService.log('sony liveview property-table empty dumping op=0x9209');
    const values = await SonyPtpIpContent.readAllExtDeviceProperties(session, 'control-page');
    NikonPtpIpService.log(`sony liveview property-table dumped` +
      ` values=${values === null ? 'none' : values.size}` +
      ` hasTable=${SonyPtpIpContent.hasPropertyTable() ? 1 : 0}`);
  }

  /**
   * The whole Sony sequence, in Sony's own order:
   *
   *   1. make sure the session is the remote-control one (see above);
   *   2. read the URL (property 0xD278, DD-document fallback);
   *   3. `0x9207 {54035, flag}` enable - a refusal is logged, not fatal
   *      (`camera/BaseCamera.java:69` starts the stream from the FAILURE
   *      callback too);
   *   4. open the HTTP GET and start delivering frames.
   */
  static async start(): Promise<SonyLiveViewStart> {
    await SonyLiveView.stop();
    if (SonyLiveView.isUsbControl()) {
      return await SonyLiveView.startUsb();
    }
    const session = NikonPtpIpService.currentSession();
    if (session === null) {
      return { ok: false, url: '', enableCode: -1, reason: 'no-session' };
    }
    const url = await SonyPtpIpContent.readLiveViewUrl(session);
    NikonPtpIpService.log(`sony liveview url=${url.length > 0 ? url : 'none'}`);
    const target = SonyLiveView.resolveTarget(url, session.host);
    if (target === null) {
      // Sony never opens the stream without a URL; `PtpIpClient.java:932-934`
      // asserts on exactly this.
      return { ok: false, url: url, enableCode: -1, reason: 'no-url' };
    }
    const enableCode = await SonyLiveView.setLiveViewEnable(true);
    const stream = new SonyLiveViewStream(target);
    SonyLiveView.stream = stream;
    const opened = await stream.start();
    if (!opened) {
      const reason = stream.reason();
      SonyLiveView.stream = null;
      stream.close();
      return { ok: false, url: url, enableCode: enableCode, reason: reason };
    }
    NikonPtpIpService.log(`sony liveview start` +
      ` url=${url}` +
      ` target=${target.host}:${target.port}${target.requestUri}` +
      ` portSource=${target.portSource}` +
      ` enableCode=${SonyLiveView.hex(enableCode)}`);
    return { ok: true, url: url, enableCode: enableCode, reason: '' };
  }

  /**
   * Closes the HTTP stream and then disables live view - the order
   * `camera/PtpIpCamera.java:939-946` then `camera/CameraConnector.java:937-938`
   * use. Safe to call when nothing is running.
   */
  static async stop(): Promise<void> {
    const usb = SonyLiveView.usbStream;
    SonyLiveView.usbStream = null;
    if (usb !== null) {
      NikonPtpIpService.log(`sony liveview usb stop frames=${usb.framesReceived()}` +
        ` reason=${usb.reason().length > 0 ? usb.reason() : 'user'}`);
      usb.close();
      if (NikonPtpIpService.isControlReady()) {
        await SonyLiveView.setLiveViewEnable(false);
      }
      // 控制权最后归还：顺序与官方一致（先关取景、再放开 host priority）。
      await SonyLiveView.setUsbPriority(0);
    }
    const stream = SonyLiveView.stream;
    SonyLiveView.stream = null;
    if (stream !== null) {
      NikonPtpIpService.log(`sony liveview stop frames=${stream.framesReceived()}` +
        ` reason=${stream.reason().length > 0 ? stream.reason() : 'user'}`);
      stream.close();
      if (NikonPtpIpService.isControlReady()) {
        await SonyLiveView.setLiveViewEnable(false);
      }
    }
  }

  /** The newest JPEG frame, or null. Keeps at most one frame, which is what
   * Sony's own pool does: `ChunkedPermanentEeImageDownloader.fetch` drains
   * `mProcessedImageData` before putting the new frame
   * (`ptpip/liveview/http/ChunkedPermanentEeImageDownloader.java:76-84`). */
  static nextFrame(): Uint8Array | null {
    const usb = SonyLiveView.usbStream;
    if (usb !== null) return usb.nextFrame();
    const stream = SonyLiveView.stream;
    if (stream === null) return null;
    return stream.nextFrame();
  }

  /** 当前控制是否走 USB（没有 PTP/IP 会话、但挂上了外部传输）。 */
  private static isUsbControl(): boolean {
    return NikonPtpIpService.currentSession() === null &&
      NikonPtpIpService.activeControlTransport() !== null;
  }

  /**
   * USB 上启动实时取景。
   *
   * 与 Wi‑Fi 分支的区别只在「帧从哪来」：USB 没有 HTTP 流，帧由
   * `GetObject(0xFFFFC002)` 逐帧取回（`SonyLiveViewUsbStream` 的泵循环）。
   * 开关取景仍然是同一条 `0x9207 SDIO_ControlDevice`，所以相机侧行为一致。
   */
  /**
   * 写 USB 主机控制权（`0xD25A`）。只在「确实走 USB」时发：PTP/IP 会话下
   * 机身的控制权由 `0x90C2` 管，不走这条。
   *
   * flag 必须由 `propertyFlag` 给出（`[code, flag]` 是 0x9205 的既有编码形状，
   * 见 `SonyPtpIpControl.applySetting`），少发 flag 会被机身当参数错误拒绝。
   */
  private static async setUsbPriority(value: number): Promise<number> {
    if (NikonPtpIpService.currentSession() !== null) return -1;
    const transport = NikonPtpIpService.activeControlTransport();
    if (transport === null) return -1;
    const flag = await SonyLiveView.propertyFlag(transport);
    return await SonyUsbPtp.setPriorityMode(value, flag);
  }
  static async startUsb(): Promise<SonyLiveViewStart> {
    const transport = NikonPtpIpService.activeControlTransport();
    if (transport === null) {
      return { ok: false, url: '', enableCode: -1, reason: 'no-session' };
    }
    // 夺取 USB 主机控制权（0xD25A=1）。失败不致命，只记录。
    await SonyLiveView.setUsbPriority(1);
    const enableCode = await SonyLiveView.setLiveViewEnable(true);
    const stream = new SonyLiveViewUsbStream();
    SonyLiveView.usbStream = stream;
    const opened = await stream.start();
    if (!opened) {
      const reason = stream.reason();
      SonyLiveView.usbStream = null;
      stream.close();
      return { ok: false, url: 'usb', enableCode: enableCode, reason: reason };
    }
    NikonPtpIpService.log(`sony liveview usb start enableCode=${SonyLiveView.hex(enableCode)}`);
    return { ok: true, url: 'usb', enableCode: enableCode, reason: '' };
  }

  /**
   * Reconnects ONLY the live-view HTTP stream, leaving the remote-control PTP/IP
   * session untouched.
   *
   * The camera pauses a long-lived live-view connection: on the ILCE-7M4, after
   * 1744 frames (~68 s) the socket stayed open, no terminating chunk and no
   * error arrived, and `nextFrame()` simply returned null from then on.
   * Tearing the whole session down for that was wrong twice over — it aborted
   * the control channel (the `enable=0` that `stop()` sends was never answered,
   * and ten seconds later the transport poisoned the session on transaction
   * timeout) and it turned a recoverable pause into a dead page.
   *
   * The GET is re-issued as-is first: the camera paused the connection without
   * disabling live view, so a fresh GET normally resumes frames immediately, and
   * re-enabling would spend a control round trip on the very session we are
   * trying not to disturb. Only a refused GET re-asserts the enable.
   */
  static async restartStream(): Promise<boolean> {
    const usb = SonyLiveView.usbStream;
    if (usb !== null) {
      NikonPtpIpService.log(`sony liveview usb restart streaming=${usb.isStreaming() ? 1 : 0}` +
        ` frames=${usb.framesReceived()} reason=${usb.reason().length > 0 ? usb.reason() : '-'}`);
      if (usb.isStreaming()) return true;
      // 泵已停（连续取不到帧 / 相机切过回放）但控制通道还活着：重开一个泵，
      // 等价于 Wi‑Fi 分支里重发一次 HTTP GET。泵自己不会复活，不重建就一直
      // 返回失败，页面会把一次可恢复的暂停当成断线。
      usb.close();
      const revived = new SonyLiveViewUsbStream();
      SonyLiveView.usbStream = revived;
      const ok = await revived.start();
      NikonPtpIpService.log(`sony liveview usb restart revived=${ok ? 1 : 0}`);
      return ok;
    }
    const previous = SonyLiveView.stream;
    SonyLiveView.stream = null;
    if (previous !== null) {
      previous.close();
    }
    const session = NikonPtpIpService.currentSession();
    if (session === null) {
      NikonPtpIpService.log('sony liveview stream-restart no-session');
      return false;
    }
    const url = await SonyPtpIpContent.readLiveViewUrl(session);
    const target = SonyLiveView.resolveTarget(url, session.host);
    if (target === null) {
      NikonPtpIpService.log('sony liveview stream-restart no-url');
      return false;
    }
    let stream = new SonyLiveViewStream(target);
    SonyLiveView.stream = stream;
    let opened = await stream.start();
    let enableCode = -1;
    if (!opened) {
      stream.close();
      SonyLiveView.stream = null;
      enableCode = await SonyLiveView.setLiveViewEnable(true);
      stream = new SonyLiveViewStream(target);
      SonyLiveView.stream = stream;
      opened = await stream.start();
    }
    NikonPtpIpService.log(`sony liveview stream-restart opened=${opened ? 1 : 0}` +
      ` enableCode=${SonyLiveView.hex(enableCode)}` +
      ` reason=${opened ? '-' : stream.reason()}`);
    if (!opened) {
      SonyLiveView.stream = null;
      stream.close();
      return false;
    }
    return true;
  }

  /**
   * A cheap probe on the CONTROL channel, used to notice the camera going quiet
   * while it is still willing to answer.
   *
   * Why this exists: measured on an ILCE-7M4, the body stops writing on the
   * live-view TCP socket after tens of seconds of no control traffic (3594
   * frames once, 1744 another time — not a fixed count), and from then on it
   * refuses vendor operations altogether:
   *
   *   22:08:58.232 sony liveview http-status=503              (new GET refused)
   *   22:09:08.236 ptpip session poisoned ... PTP/IP transaction timeout
   *   22:09:08.237 sony liveview enable=1 ... code=none       (0x9207 unanswered)
   *
   * So a stream restart CANNOT recover that state — the enable needed to make a
   * new GET succeed is itself what times out. The only lever left is to keep the
   * session warm, and to notice the drift early enough to restart while 0x9207
   * is still answered.
   *
   * `SetLiveViewEnable(true)` is idempotent and already proven on this body
   * (`enable=1 op=0x9207 params=[54035,1] payload=[2,0] code=0x2001`), which
   * makes it the cheapest probe that is also directly on topic.
   *
   * Returns 0x2001 when the body answered normally.
   */
  static async keepAlive(): Promise<number> {
    const usb = SonyLiveView.usbStream;
    if (usb !== null) {
      // 探的是**控制通道**，不是取帧泵。泵停了（相机切过回放等）不代表相机
      // 失联，这里若跟着返回 -1，页面会误报「相机已停止响应控制通道」并把一次
      // 可恢复的暂停当断线；泵的存活由 `restartStream()` 自己重建。
      return await SonyLiveView.setLiveViewEnable(true);
    }
    if (SonyLiveView.stream === null || !SonyLiveView.stream.isStreaming()) {
      return -1;
    }
    return SonyLiveView.setLiveViewEnable(true);
  }

  /**
   * One HTTP target from the property URL.
   *
   * Parsed by hand rather than with `URL`, because the port rule is the point:
   * `camera/PtpIpCamera.java:711` uses the string verbatim (plain-AP path) and
   * `:715` rebuilds it as
   * `new URL(url.getProtocol(), url.getHost(), mStreamingPort, url.getFile())`
   * (SSH-forwarded path). A URL that names no port gets 60152; a URL that names
   * one keeps it. `fallbackHost` covers a scheme-relative or path-only value.
   */
  private static resolveTarget(url: string, fallbackHost: string): SonyLiveViewTarget | null {
    const trimmed = url.trim();
    // Sony never opens the stream without a URL: `PtpIpClient.java:932-934`
    // asserts on exactly that, and a host alone does not name a request target.
    if (trimmed.length === 0) return null;
    let rest = trimmed;
    let scheme = '';
    const schemeEnd = rest.indexOf('://');
    if (schemeEnd >= 0) {
      scheme = rest.substring(0, schemeEnd);
      rest = rest.substring(schemeEnd + 3);
    }
    if (scheme.length > 0 && scheme.toLowerCase() !== 'http') {
      NikonPtpIpService.log(`sony liveview url scheme=${scheme} unsupported`);
      return null;
    }
    let authority = rest;
    let requestUri = '/';
    const slash = rest.indexOf('/');
    const query = rest.indexOf('?');
    let cut = -1;
    if (slash >= 0 && query >= 0) cut = slash < query ? slash : query;
    else if (slash >= 0) cut = slash;
    else if (query >= 0) cut = query;
    if (cut >= 0) {
      authority = rest.substring(0, cut);
      requestUri = rest.substring(cut);
      if (requestUri.startsWith('?')) requestUri = '/' + requestUri;
    }
    let host = authority;
    let port = 0;
    let portSource = 'url';
    const colon = authority.lastIndexOf(':');
    if (colon >= 0) {
      host = authority.substring(0, colon);
      const portText = authority.substring(colon + 1);
      const parsed = Number.parseInt(portText, 10);
      if (Number.isFinite(parsed) && parsed > 0 && parsed <= 65535) {
        port = parsed;
      }
    }
    if (host.length === 0) {
      host = fallbackHost.trim();
    }
    if (host.length === 0) return null;
    if (port <= 0) {
      port = SonyLiveView.STREAMING_PORT;
      portSource = 'default-60152';
    }
    if (requestUri.length === 0) requestUri = '/';
    return { host: host, port: port, requestUri: requestUri, portSource: portSource };
  }

  private static hex(value: number): string {
    if (value < 0) return 'none';
    return '0x' + value.toString(16).toUpperCase().padStart(4, '0');
  }

  private static errorText(error: Error): string {
    const message: string = error.message;
    return message.length > 0 ? message : String(error);
  }
}

/**
 * The Sony live-view HTTP connection: one GET, one never-ending 200 response,
 * frames reassembled from the in-band 16-byte headers described in the file
 * header.
 *
 * Raw TCP rather than `@ohos.net.http`, for a hard reason: the response body
 * has no end, so a request/response client would either buffer forever or hand
 * back nothing until the socket dies. This mirrors `NikonPtpIpChannel`'s use of
 * `socket.constructTCPSocketInstance` - the same transport API the repo already
 * uses - but it is a SEPARATE connection from the PTP/IP socket pair, never a
 * multiplex over it.
 */
class SonyLiveViewStream {
  private readonly target: SonyLiveViewTarget;
  private tcp: socket.TCPSocket | null = null;
  private messageCallback: ((info: socket.SocketMessageInfo) => void) | null = null;
  private errorCallback: ((error: Error) => void) | null = null;
  private closed: boolean = false;
  /** Bytes received from the socket, before any HTTP framing is removed. */
  private wire: Uint8Array = new Uint8Array(0);
  /** Decoded body bytes, before frame reassembly. */
  private body: Uint8Array = new Uint8Array(0);
  private headerDone: boolean = false;
  private statusCode: number = 0;
  private chunked: boolean = false;
  private chunkRemaining: number = 0;
  private chunkState: string = 'size';
  private latest: Uint8Array | null = null;
  private frames: number = 0;
  private bytes: number = 0;
  private failure: string = '';

  constructor(target: SonyLiveViewTarget) {
    this.target = target;
  }

  isStreaming(): boolean {
    return this.headerDone && !this.closed && this.failure.length === 0
      && this.chunkState !== 'done';
  }

  reason(): string {
    return this.failure;
  }

  framesReceived(): number {
    return this.frames;
  }

  bytesReceived(): number {
    return this.bytes;
  }

  /** Opens the connection and sends the GET. Resolves false with `reason()`
   * set when the response is not a usable 200. */
  async start(): Promise<boolean> {
    const tcp = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    this.messageCallback = (info: socket.SocketMessageInfo): void => {
      if (this.closed) return;
      if (!info || !info.message) return;
      this.onWire(new Uint8Array(info.message));
    };
    this.errorCallback = (error: Error): void => {
      // A closed socket at teardown is expected, not a failure.
      if (this.closed) return;
      this.fail(`socket-error: ${SonyLiveViewStream.errorText(error)}`);
    };
    tcp.on('message', this.messageCallback);
    tcp.on('error', this.errorCallback);
    try {
      await tcp.connect({
        address: { address: this.target.host, family: 1, port: this.target.port },
        timeout: 5000,
      });
    } catch (error) {
      this.fail(`connect-failed: ${SonyLiveViewStream.errorText(error as Error)}`);
      return false;
    }
    try {
      await tcp.setExtraOptions({ keepAlive: true, TCPNoDelay: true });
    } catch (_error) {
      NikonPtpIpService.log('sony liveview tcp extra options unavailable (non-fatal)');
    }
    const request = SonyLiveViewStream.buildRequest(this.target);
    NikonPtpIpService.log(`sony liveview http-request` +
      ` ${SonyLiveViewStream.oneLine(request)}`);
    try {
      await tcp.send({ data: SonyLiveViewStream.toArrayBuffer(request) });
    } catch (error) {
      this.fail(`send-failed: ${SonyLiveViewStream.errorText(error as Error)}`);
      return false;
    }
    // The response arrives asynchronously; wait for the header so the caller
    // learns immediately whether the camera accepted the request.
    const status = await this.awaitHeader();
    if (status !== 200) {
      if (this.failure.length === 0) {
        this.fail(`http-status=${status}`);
      }
      NikonPtpIpService.log(`sony liveview http-status=${status}`);
      return false;
    }
    NikonPtpIpService.log(`sony liveview http-status=200` +
      ` transferEncoding=${this.chunked ? 'chunked' : 'close-delimited'}`);
    return true;
  }

  /**
   * The request `AbstractEeImageDownloader.startup` produces: a plain GET with
   * `Connection: close` as its only explicitly set header
   * (`ptpip/liveview/http/AbstractEeImageDownloader.java:164-167`).
   * `HttpURLConnection` adds `Host` itself; it is sent explicitly here because
   * this port writes the request by hand.
   */
  private static buildRequest(target: SonyLiveViewTarget): string {
    return `GET ${target.requestUri} HTTP/1.1\r\n`
      + `Host: ${target.host}:${target.port}\r\n`
      + `Connection: close\r\n`
      + `\r\n`;
  }

  private static toArrayBuffer(text: string): ArrayBuffer {
    const bytes = SonyLiveViewStream.ascii(text);
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  }

  /** The request on one log line: CRLF becomes ` | `. */
  private static oneLine(text: string): string {
    let result = '';
    for (let index = 0; index < text.length; index++) {
      const character = text.charAt(index);
      if (character === '\r') continue;
      result += character === '\n' ? ' | ' : character;
    }
    return result;
  }

  private static ascii(text: string): Uint8Array {
    const bytes = new Uint8Array(text.length);
    for (let index = 0; index < text.length; index++) {
      bytes[index] = text.charCodeAt(index) & 0xFF;
    }
    return bytes;
  }

  private static errorText(error: Error): string {
    const message: string = error.message;
    return message.length > 0 ? message : String(error);
  }

  /** Resolves with the HTTP status, or 0 when the header never arrived. */
  private async awaitHeader(): Promise<number> {
    for (let attempt = 0; attempt < 100; attempt++) {
      if (this.headerDone) return this.statusCode;
      if (this.failure.length > 0 || this.closed) return 0;
      await SonyLiveViewStream.sleep(50);
    }
    this.fail('http-header-timeout');
    return 0;
  }

  private static async sleep(milliseconds: number): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, milliseconds);
    });
  }

  /** The newest frame, consumed once. */
  nextFrame(): Uint8Array | null {
    const frame = this.latest;
    this.latest = null;
    return frame;
  }

  /** Idempotent teardown. The platform close is started and remembered, never
   * awaited by the caller (mirrors `NikonPtpIpChannel.shutdown`). */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    const tcp = this.tcp;
    const messageCallback = this.messageCallback;
    const errorCallback = this.errorCallback;
    this.tcp = null;
    this.messageCallback = null;
    this.errorCallback = null;
    this.wire = new Uint8Array(0);
    this.body = new Uint8Array(0);
    this.latest = null;
    if (tcp === null) {
      return;
    }
    try {
      if (messageCallback !== null) tcp.off('message', messageCallback);
      if (errorCallback !== null) tcp.off('error', errorCallback);
      tcp.close().then((): void => {}, (): void => {});
    } catch (_error) {
      // The platform may already have torn the socket down after a Wi-Fi roam.
    }
  }

  private fail(reason: string): void {
    if (this.failure.length === 0) {
      this.failure = reason;
      NikonPtpIpService.log(`sony liveview stream-failed reason=${reason}` +
        ` frames=${this.frames}`);
    }
  }

  private append(value: Uint8Array): void {
    if (value.length === 0) return;
    const next = new Uint8Array(this.wire.length + value.length);
    next.set(this.wire, 0);
    next.set(value, this.wire.length);
    this.wire = next;
  }

  private onWire(chunk: Uint8Array): void {
    if (this.failure.length > 0) return;
    this.bytes += chunk.length;
    this.append(chunk);
    try {
      if (!this.headerDone) {
        this.takeHeader();
      }
      if (!this.headerDone || this.failure.length > 0) return;
      if (this.chunked) {
        this.decodeChunks();
      } else {
        this.moveWireToBody();
      }
      if (this.failure.length > 0) return;
      this.takeFrames();
    } catch (error) {
      this.fail(`parse-error: ${SonyLiveViewStream.errorText(error as Error)}`);
    }
  }

  /** Splits the response head off the front of `wire` and reads the status line
   * plus the one header that changes how the body must be read. */
  private takeHeader(): void {
    const end = SonyLiveViewStream.indexOfHeaderEnd(this.wire);
    if (end < 0) {
      if (this.wire.length > SonyLiveView.MAX_HEADER_BYTES) {
        this.fail('http-header-too-long');
      }
      return;
    }
    const head = SonyLiveViewStream.decodeAscii(this.wire, 0, end);
    this.wire = this.wire.slice(end + 4);
    const lines = head.split('\r\n');
    const statusLine = lines.length > 0 ? lines[0] : '';
    const parts = statusLine.split(' ');
    if (parts.length < 2 || !parts[0].startsWith('HTTP/')) {
      this.fail(`http-status-line-invalid: ${statusLine}`);
      return;
    }
    const code = Number.parseInt(parts[1], 10);
    if (!Number.isFinite(code) || code <= 0) {
      this.fail(`http-status-line-invalid: ${statusLine}`);
      return;
    }
    this.statusCode = code;
    for (let index = 1; index < lines.length; index++) {
      const lower = lines[index].toLowerCase();
      if (lower.startsWith('transfer-encoding:') && lower.indexOf('chunked') >= 0) {
        // Java's HttpURLConnection hides this framing from its InputStream, so
        // Sony's reader sees the de-chunked body. Reconstructed here.
        this.chunked = true;
      }
    }
    this.headerDone = true;
  }

  private moveWireToBody(): void {
    if (this.wire.length === 0) return;
    this.appendBody(this.wire);
    this.wire = new Uint8Array(0);
  }

  private appendBody(value: Uint8Array): void {
    if (value.length === 0) return;
    const next = new Uint8Array(this.body.length + value.length);
    next.set(this.body, 0);
    next.set(value, this.body.length);
    this.body = next;
  }

  /** HTTP/1.1 chunk de-framing, used only when the response announced
   * `Transfer-Encoding: chunked`. */
  private decodeChunks(): void {
    while (this.failure.length === 0) {
      if (this.chunkState === 'done') return;
      if (this.chunkRemaining > 0) {
        const take = Math.min(this.chunkRemaining, this.wire.length);
        if (take === 0) return;
        this.appendBody(this.wire.subarray(0, take));
        this.wire = this.wire.slice(take);
        this.chunkRemaining -= take;
        if (this.chunkRemaining === 0) this.chunkState = 'crlf';
        continue;
      }
      if (this.chunkState === 'crlf') {
        const lineEnd = SonyLiveViewStream.indexOfCrlf(this.wire);
        if (lineEnd.start < 0) return;
        this.wire = this.wire.slice(lineEnd.next);
        this.chunkState = 'size';
        continue;
      }
      const lineEnd = SonyLiveViewStream.indexOfCrlf(this.wire);
      if (lineEnd.start < 0) return;
      const line = SonyLiveViewStream.decodeAscii(this.wire, 0, lineEnd.start).trim();
      this.wire = this.wire.slice(lineEnd.next);
      const semicolon = line.indexOf(';');
      const sizeText = semicolon >= 0 ? line.substring(0, semicolon) : line;
      const size = Number.parseInt(sizeText.trim(), 16);
      if (!Number.isFinite(size) || size < 0) {
        this.fail(`chunk-size-invalid: ${line}`);
        return;
      }
      if (size === 0) {
        this.chunkState = 'done';
        NikonPtpIpService.log(`sony liveview stream-ended by camera` +
          ` frames=${this.frames}`);
        return;
      }
      this.chunkRemaining = size;
    }
  }

  /**
   * One frame per iteration, exactly as `AbstractEeImageDownloader.readImageData`
   * reads it: 16 header bytes, then
   * `ReservedSize + LiveViewImageSize + FocalFrameInfoSize` more, with
   * `ReservedSize = min(OffsetToFocalFrameInfo, OffsetToLiveViewImage) - 16`.
   * The JPEG is the `LiveViewImageSize` bytes at `OffsetToLiveViewImage`; the
   * focal-frame-info block (AF / face / tracking / level) is discarded.
   */
  private takeFrames(): void {
    while (this.failure.length === 0) {
      if (this.body.length < 16) return;
      const offsetToImage = SonyLiveViewStream.readU32(this.body, 0);
      const imageSize = SonyLiveViewStream.readU32(this.body, 4);
      const offsetToFocal = SonyLiveViewStream.readU32(this.body, 8);
      const focalSize = SonyLiveViewStream.readU32(this.body, 12);
      const first = offsetToFocal < offsetToImage ? offsetToFocal : offsetToImage;
      if (first < 16) {
        this.fail(`frame-header-invalid offsetImage=${offsetToImage}` +
          ` offsetFocal=${offsetToFocal}`);
        return;
      }
      const reserved = first - 16;
      const total = 16 + reserved + imageSize + focalSize;
      if (imageSize <= 0 || imageSize > SonyLiveView.MAX_FRAME_BYTES
        || total > SonyLiveView.MAX_FRAME_BYTES) {
        this.fail(`frame-header-invalid imageSize=${imageSize}` +
          ` focalSize=${focalSize} reserved=${reserved} total=${total}`);
        return;
      }
      if (this.body.length < total) return;
      const jpeg = this.body.slice(offsetToImage, offsetToImage + imageSize);
      this.body = this.body.slice(total);
      this.frames += 1;
      // Only the newest frame is kept, which is what Sony's pool does.
      this.latest = jpeg;
    }
  }

  private static readU32(bytes: Uint8Array, offset: number): number {
    return (bytes[offset]
      | (bytes[offset + 1] << 8)
      | (bytes[offset + 2] << 16)
      | (bytes[offset + 3] << 24)) >>> 0;
  }

  /** Byte index of CRLFCRLF, or -1. */
  private static indexOfHeaderEnd(bytes: Uint8Array): number {
    for (let index = 0; index + 3 < bytes.length; index++) {
      if (bytes[index] === 13 && bytes[index + 1] === 10
        && bytes[index + 2] === 13 && bytes[index + 3] === 10) {
        return index;
      }
    }
    return -1;
  }

  /** The CRLF that ends the line starting at 0, with the index just past it.
   * Accepts a bare LF as well, which is legal in chunk framing. */
  private static indexOfCrlf(bytes: Uint8Array): SonyLiveViewCrlf {
    for (let index = 0; index < bytes.length; index++) {
      if (bytes[index] === 10) {
        const start = index > 0 && bytes[index - 1] === 13 ? index - 1 : index;
        return { start: start, next: index + 1 };
      }
    }
    return { start: -1, next: -1 };
  }

  private static decodeAscii(bytes: Uint8Array, from: number, to: number): string {
    let text = '';
    for (let index = from; index < to && index < bytes.length; index++) {
      text += String.fromCharCode(bytes[index]);
    }
    return text;
  }
}

/** A CRLF position pair; an interface because ArkTS has no tuple type. */
interface SonyLiveViewCrlf {
  start: number;
  next: number;
}

/**
 * USB 实时取景帧源。
 *
 * USB 上没有可以读的 HTTP 分块流：索尼用 `GetObject(0x1009)` + 魔数句柄
 * `0xFFFFC002` 逐帧返回 JPEG（公开实现 argallo/sony-camera-android 在 ILCE-6600
 * 实测，libgphoto2 同款句柄）。这里用一个「只保留最新一帧」的泵循环，语义与
 * `SonyLiveViewStream` 对齐：`nextFrame()` 取走即清，最多一帧。
 *
 * 为什么不在页面里直接取帧：取帧与快门共用同一条 bulk 管道，必须走
 * `SonyUsbPtp` 的串行队列，否则会串帧；泵循环每轮只挂一个事务，快门请求永远
 * 能在两帧之间插进来。
 */
class SonyLiveViewUsbStream {
  /** 第一帧等待上限：相机 enable 后不一定立刻出图。 */
  private static readonly FIRST_FRAME_TIMEOUT_MS: number = 6000;
  private static readonly POLL_IDLE_MS: number = 30;
  private static readonly POLL_BACKOFF_MS: number = 120;
  /** 连续取不到帧的上限：约 5–12 秒（退避后）。超了就当取景已停。 */
  private static readonly MAX_MISSES: number = 100;

  private latest: Uint8Array | null = null;
  private pumping: boolean = false;
  private frames: number = 0;
  private misses: number = 0;
  private failure: string = '';

  async start(): Promise<boolean> {
    if (!NikonPtpIpService.isControlReady()) {
      this.failure = 'no-session';
      return false;
    }
    this.pumping = true;
    this.pump();
    const deadline = Date.now() + SonyLiveViewUsbStream.FIRST_FRAME_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (this.latest !== null) return true;
      if (this.failure.length > 0) break;
      await SonyLiveViewUsbStream.sleep(SonyLiveViewUsbStream.POLL_IDLE_MS);
    }
    if (this.latest !== null) return true;
    this.failure = this.failure.length > 0 ? this.failure : 'no-frame';
    return false;
  }

  private async pump(): Promise<void> {
    while (this.pumping) {
      // 通道没了就自停：否则拔线后这个循环会对着死管道一直空转。
      if (!NikonPtpIpService.isControlReady()) {
        this.failure = 'no-session';
        this.pumping = false;
        break;
      }
      const frame = await SonyUsbPtp.fetchLiveViewFrame();
      if (!this.pumping) break;
      if (frame !== null && frame.length > 0) {
        this.latest = frame;
        this.frames += 1;
        if (this.frames === 1) {
          NikonPtpIpService.log(`sony liveview usb first-frame bytes=${frame.length}`);
        }
        this.misses = 0;
        continue;
      }
      this.misses += 1;
      // 连续取不到帧到一定次数就判定取景已停（相机切到回放、或机身不再回
      // GetObject）。**必须自停**：否则 `restartStream()` 会因为「泵还在跑」
      // 一直回报成功，控制页的重连计数就永远不增长，页面卡在「重连中」不报错。
      if (this.misses >= SonyLiveViewUsbStream.MAX_MISSES) {
        this.failure = 'stalled';
        this.pumping = false;
        NikonPtpIpService.log(`sony liveview usb stalled after ${this.misses} misses` +
          ` frames=${this.frames}`);
        break;
      }
      // 连续取不到帧就退避：不能让泵把 bulk 管道刷满，否则快门排不上队。
      await SonyLiveViewUsbStream.sleep(this.misses > 20
        ? SonyLiveViewUsbStream.POLL_BACKOFF_MS
        : SonyLiveViewUsbStream.POLL_IDLE_MS);
    }
  }

  nextFrame(): Uint8Array | null {
    const frame = this.latest;
    this.latest = null;
    return frame;
  }

  isStreaming(): boolean {
    return this.pumping;
  }

  framesReceived(): number {
    return this.frames;
  }

  reason(): string {
    return this.failure;
  }

  close(): void {
    this.pumping = false;
    this.latest = null;
  }

  private static sleep(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout((): void => {
        resolve();
      }, milliseconds);
    });
  }
}
