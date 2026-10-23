/**
 * Sony private PTP/IP content enumeration (`CONTENTS_TRANSFER_MODE`).
 *
 * Why this module exists
 * ----------------------
 * `NikonPtpIpService` browses with the standard PTP object operations
 * (`GetStorageIDs`/`GetObjectHandles`/`GetObjectInfo`/`GetThumb`). Sony bodies
 * answer those with a vendor refusal — the app saw
 * `PTP/IP GetStorageIDs 响应 0x2013`, a code Sony's own app does not even know.
 * Sony's Creators' App defaults to contents-transfer mode instead and lists the
 * media with two private operations. This module speaks that protocol; the
 * transport (TCP, InitCommand/InitEvent, command queue, data phase) is the one
 * already implemented in `NikonPtpIpService`.
 *
 * Scope: enumeration only. Enter contents transfer mode, then read the contents
 * list so the app can show file path, byte size and the content handle. File
 * data, thumbnails and video/audio metadata interpretation are deliberately not
 * implemented.
 *
 * Protocol facts (all read out of Sony's Creators' App 3.5.0, package
 * `jp.co.sony.ips.portalapp`, classes3.dex)
 * ------------------------------------------------------------------
 * The order below is Sony's own: a plain 0x2001 answer to
 * `SDIO_SetContentsTransferMode` is NOT treated as "contents-transfer mode
 * established". `ContentsTransferModeSetter.onOperationRequested` checks the
 * device property `ContentsTransferEnableStatus` (53909) and, when it is not
 * yet ENABLE, waits for it with a 5 s timeout before the caller transfers
 * anything (`ptpip/mtp/ContentsTransferModeSetter.java:172-179`). Only then
 * does the browse path pick a slot, ask for the captured-date list, and start
 * pulling content pages.
 *
 * (S) SONY'S OWN SESSION SETUP — a prerequisite for (0) and for everything
 *     after it. Running only the standard PTP `OpenSession` (0x1002) is NOT
 *     enough: Sony's client performs its own vendor session establishment on
 *     top of the PTP/IP session, and every extended operation below is refused
 *     until it has run. The whole sequence is one state machine,
 *     `initialization/Initializer.java`, driven by a single call:
 *
 *       `new Initializer(transactionExecutor, ddDidAccessor).execute(functionMode,
 *        mtpEnabled, initializerCallback)`
 *       — `ptpip/BasePtpManager$$ExternalSyntheticLambda2.java:29`.
 *
 *     The order, with the decisive line for each step:
 *       (S1) GetDeviceInfo (0x1001)                       Initializer.java:111
 *       (S1b) SDIO_GetDeviceDescriptionFile (0x923A) [1] (DD XML)
 *                                                        Initializer.java:161
 *       (S1c) SDIO_GetDeviceDescriptionFile (0x923A) [2] (DID XML)
 *                                       SDIO_GetDeviceDescriptionFileState2.java:20
 *       (S2) OpenSession (0x1002, [1]) or SDIO_OpenSession (0x9210, [1, mode])
 *                                                        Initializer.java:87 / :95
 *       (S3) SDIO_Connect (0x9201) [1, 0, 0]              Initializer.java:199
 *       (S4) SDIO_Connect (0x9201) [2, 0, 0]              Initializer.java:206
 *       (S5) SDIO_GetVendorCodeVersion (0x9216) no params Initializer.java:219
 *       (S6) SDIO_GetExtDeviceInfo (0x9202) [300] / [300, 1]
 *                                                         Initializer.java:214-225
 *       (S7) SDIO_Connect (0x9201) [3, 0, 0]              Initializer.java:260
 *     (S7) is what raises `onInitialized` (Initializer.java:236); only from
 *     there does `BasePtpManager` start the property dump that issues 0x9209
 *     (`BasePtpManager.java:369`, inside `onInitialized`). That is why a
 *     simple setter such as `SDIO_SetContentsTransferMode` can be accepted
 *     while 0x9202 / 0x9209 / 0x9216 are refused: those belong to a session
 *     that was never established.
 *
 *     `onInitialized` does one more thing this port now mirrors: immediately
 *     after it queues that property dump it refreshes the device info with a
 *     SECOND `GetDeviceInfo` (`DeviceInfoUpdater.execute$2`,
 *     `BasePtpManager.java:377-380`, `base/deviceinfo/DeviceInfoUpdater.java:59-65`,
 *     which adds `new GetDeviceInfo(EnumOperationCode.GetDeviceInfo, ...)`).
 *     `probeAfterSetup` sends it after the dump, so the browse matches Sony's
 *     own order.
 *
 *     Of those steps the transport performs (S2) as part of the PTP/IP handshake
 *     — `NikonPtpIpService.openSessionAttempt` sends either `OpenSession`
 *     (0x1002) with sessionId 1 or the vendor `SDIO_OpenSession` (0x9210)
 *     `[1, mode]`, whichever the caller asked for. `setupSonySession` performs
 *     (S1), (S3), (S4), (S5), (S6) and (S7) on top of it, in that order.
 *
 *     (S2) WAS WRONG HERE BEFORE THIS REVISION, and that is what refused
 *     `SDIO_GetCapturedDateList` (0x923B). `createOpenSessionState` is a
 *     two-way branch (`Initializer.java:79-97`):
 *
 *       (!mtpEnabled && functionMode != REMOTE_CONTROL_WITH_TRANSFER_MODE)
 *            -> OpenSession         (0x1002) [1]
 *       otherwise
 *            -> SDIO_OpenSession    (0x9210) [1, functionMode.value]
 *
 *     and the function mode is NOT the caller's initial guess: `adjustFunctionMode`
 *     (Initializer.java:58-77) reads the DID document's `X_ServerVersion`
 *     (`BaseCamera.getValue` -> `DeviceInfo.mServerVersion`,
 *     `common/device/did/DeviceInfo.java:125-130`) and, when it is >= 4.0, sets
 *     `REMOTE_CONTROL_WITH_TRANSFER_MODE` (`EnumFunctionMode` value 2). Running
 *     the standard `OpenSession` (0x1002) put a CONTENTS_TRANSFER_MODE (value 1)
 *     session on the wire for an ILCE-7M4, and in that mode Sony never reads a
 *     captured-date list at all: the browse that calls
 *     `PtpContentsRoot.getContainerCount(PULL)` -> `GetCapturedDateList` ->
 *     0x923B is launched ONLY for
 *     `functionMode == REMOTE_CONTROL_WITH_TRANSFER_MODE`
 *     (`transfer/mtp/list/MtpListViewController.java:517-527`), and the slot
 *     properties that parameterise 0x923B are likewise gated on that mode
 *     (`settings/property/PlaybackMediaProperty.java:508`). So `setupSonySession`
 *     follows Sony: (S1b)/(S1c) read the DD and DID documents, the
 *     `X_ServerVersion` is logged, and the session is opened as
 *     `SDIO_OpenSession` `[1, 2]` before `SDIO_Connect`.
 *
 *     (S2) is NOT sent on top of a standard session any more. Because the mode is
 *     established BY the session-open operation, a body may reject a second open
 *     on the same session (0x201E SessionAlreadyOpen) — and a vendor open that is
 *     accepted on an already-open session need not even switch the mode. The
 *     transport's handshake (`NikonPtpIpService.acquireSession`) therefore takes
 *     the session-open operation as a parameter (default 0x1002 `[1]`, unchanged
 *     for every other brand), and `open` asks for `SDIO_OpenSession` (0x9210)
 *     `[1, 2]` on the connection it opens, so the FIRST session on the wire is
 *     already the mode-2 one. The transport releases any session it holds and
 *     waits for that TCP close (plus the camera-side release window) before it
 *     dials, and retries a refused vendor open on a fresh connection; if the
 *     body refuses it outright, `open` acquires a standard session EXPLICITLY,
 *     for the six steps' diagnostics only, and the mode-2 gate below stops the
 *     browse there instead of sending 0x923B on a session that cannot serve it.
 *     Every attempt still logs its own `sony browse attempt=` line with
 *     `sessionOpen=<what really opened it>` and `mode2=yes|no`.
 *     (S5) is the one step with NO parameter list: `SDIO_GetVendorCodeVersion`
 *     is constructed as `new SDIO_GetVendorCodeVersion(opcode, callback)` and
 *     reaches `AbstractTransaction(EnumOperationCode, callback)`, whose body is
 *     `this(NoDataOrDataInPhase, opcode, new int[0], null, callback)`
 *     (`base/transaction/AbstractTransaction.java:17-19`) — so 0x9216 goes on
 *     the wire with an empty parameter list and answers with the version as a
 *     RESPONSE parameter. The stripped constructors in the decompiled tree
 *     (jadx renders `SDIO_GetVendorCodeVersion` / `SDIO_OpenSession` /
 *     `OpenSession` as empty classes) are not missing code: such classes have no
 *     class data in classes3.dex and simply inherit that constructor.
 *
 * (0) `SDIO_SetContentsTransferMode` (0x9212), no data phase, 3 u32 parameters:
 *   [0] type = 2 (EnumContentsSelectType.REMOTE_DEVICE)
 *   [1] mode = 1 (EnumContentsTransferMode.ON)
 *   [2] info = 0 (EnumAdditionalInformation.NONE)
 * Source: `ptpip/BasePtpManager.java:1822` (setContentsTransferMode).
 * Because type is REMOTE_DEVICE (ordinal 2) and mode is ON, the property wait
 * in (1) applies — for EnumContentsSelectType.CAMERA (ordinal 1) Sony returns
 * success immediately.
 *
 * (1) `SDIO_GetVendorCodeVersion` (0x9216), then
 *     `SDIO_GetAllExtDevicePropInfo` (0x9209), data-in phase:
 *   parameters are [1], or [1, 1] when the vendor code version is >= 310.
 * The version is the first response parameter of 0x9216
 * (`initialization/Initializer.java:223-231`); 310 is the threshold in
 * `EnumFlagOfDevicePropertyOption.Companion.valueOf` (`valueOf(int)` is
 * literally `i >= 310 ? ENABLE : NONE`), and 1 is that enum's
 * ENABLE value, which `DevicePropertyGetter.execute` appends as a second
 * parameter (`DevicePropertyGetter.java:41`). Parameter [0] = 1 is the
 * `true` of that same call, i.e. the flag Sony passes when it refreshes the
 * dump on `SDIE_DevicePropChanged`
 * (`ptpip/property/DevicePropertyUpdater$$ExternalSyntheticLambda0.java:24`).
 *
 * OPCODE VALUES. `EnumOperationCode` is the sole source of truth and its
 * values are DECIMAL. The values used here are 37377 (0x9201 SDIO_Connect),
 * 37378 (0x9202 SDIO_GetExtDeviceInfo), 37385 (0x9209
 * SDIO_GetAllExtDevicePropInfo), 37392 (0x9210 SDIO_OpenSession), 37394
 * (0x9212 SDIO_SetContentsTransferMode), 37398 (0x9216
 * SDIO_GetVendorCodeVersion) and 37436 (0x923C SDIO_GetContentsInfoList).
 * Two earlier documents got 37398 wrong by writing 0x9226 (= 37414, an
 * opcode the enum does not contain at all); the wire value is 0x9216. That
 * mistake alone makes the version read fail, so 310 is never reached and the
 * dump never gets its extra flag.
 * The payload is a u64 entry count followed by that many `DevicePropInfoDataset`
 * records; field order from `ptpip/property/dataset/DevicePropInfoDataset.java`
 * `valueOf` (line 113 onwards). Reacting to a property-change event by
 * re-fetching this whole dump is exactly what Sony does, so polling this
 * operation issues the same request; see `waitContentsTransferEnabled`.
 *
 * THE WALK'S DENOMINATOR IS THE RECEIVED DATA-PHASE LENGTH, NEVER A PARSE-DERIVED
 * NUMBER. `DevicePropInfoDataset.valueOf` reads the record count at offset 0
 * (`:121 long j = byteBuffer.getLong();`) and then asserts that the walk ended on
 * the very last byte of the buffer (`:268 byteBuffer.position() ==
 * byteBuffer.capacity()`), throwing `IllegalArgumentException("DevicePropInfoDataset
 * invalid buffer")` otherwise — which `DevicePropertyGetter.onOperationRequested`
 * turns into a rejected dump (`property/DevicePropertyGetter.java:74-79`).
 * `byteBuffer.capacity()` is the length of the buffer `progressChanged` filled
 * from the data phase (`DevicePropertyGetter.java:83-91`:
 * `ByteBuffer.allocate((int) j2)` where `j2` is the data-phase length the
 * transport declared, then one `put(bArr)` per received chunk), and
 * `onOperationRequested` asserts that same position-equals-capacity condition
 * before it flips and parses (`:72-73`). So the only admissible denominator is
 * how many bytes the camera actually sent in that transaction. This port takes
 * it explicitly from the transport response — `NikonPtpResponse.data.length` as
 * built by `NikonPtpIpService.receiveDataPhase`, which returns exactly the
 * accumulated byte count and throws `PTP/IP data length mismatch` unless it
 * equals the u64 total announced by the StartData packet
 * (`NikonPtpIpService.ets:1401-1410`) — records it as `receivedBytes`, and
 * computes `clean` only when the walk consumed that many bytes. A walk over a
 * 723-byte payload can therefore never be reported as if it had covered a
 * 9437-byte one.
 *
 * THE DUMP IS NOT ALWAYS THE WHOLE PROPERTY LIST. `DevicePropertyGetter.execute`
 * sends `{z ? 1 : 0}` as parameter [0] (`DevicePropertyGetter.java:40-44`), and
 * Sony calls it both ways:
 *   z = false -> parameter [0] = 0, the initial acquisition, sent once from
 *                `BasePtpManager.onInitialized` (`BasePtpManager.java:369`)
 *   z = true  -> parameter [0] = 1, the refresh Sony sends on every
 *                `SDIE_DevicePropChanged` event
 *                (`DevicePropertyUpdater$$ExternalSyntheticLambda0.java:24`)
 * Sony then MERGES each answer into one accumulated map
 * (`DevicePropertyUpdater.onDevicePropertyAcquired`, `:58-66`: on the first
 * answer it takes the map whole, and afterwards it only overwrites the
 * properties the new answer actually contains). `DevicePropertyUpdater.get`
 * reads back from that accumulated map (`:45-47`), which is what
 * `ContentsTransferModeSetter` and `PtpContentsRoot` consult. That merge only
 * makes sense if a refresh answer may carry a SUBSET of the property list — the
 * properties that changed. THE INITIAL FORM IS `[0, flag]`, NOT `[1, flag]`:
 * `DevicePropertyGetter.execute(false, flag, cb)` — which is what
 * `BasePtpManager.onInitialized` calls (`BasePtpManager.java:369`) — builds
 * `{false ? 1 : 0}` = 0 as parameter [0] (`DevicePropertyGetter.java:40-44`),
 * and only the event-driven refresh Sony sends on `SDIE_DevicePropChanged`
 * (`DevicePropertyUpdater$$ExternalSyntheticLambda0.java:24`) uses the `true`
 * form, parameter [0] = 1. This module therefore sends `[0, flag]` for the
 * initial acquisition (`initialPropertyDumpParams`) and `[1, flag]` for every
 * enable-refresh poll (`propertyDumpParams`). Either way the FIRST dump of a
 * session is the full list (the camera declared 351 device properties in
 * `0x9202`, which is 9437 bytes at 26.9 bytes/record) and a later poll may
 * legitimately be a subset — the real-device log is exactly that shape:
 * `setupProbeDump=0x2001:9437` for the probe and, for the first enable poll, a
 * 723-byte payload whose own u64 count is 25 (28.9 bytes/record, i.e. correctly
 * sized records, just fewer of them). Therefore:
 *   - the decoded values and the `mIsEnable` octets of every dump are merged
 *     into an accumulator here too, so a delta can never erase the slot
 *     properties an earlier full dump delivered;
 *   - the walk verdict the browse line reports belongs to the LARGEST payload
 *     walked in the attempt, not to the most recent one, because only that
 *     payload can span the property list `extPropCount` names. The most recent
 *     walk is reported separately as `propLastWalk*`.
 *
 * (2) `SDIO_GetCapturedDateList` (0x923B), data-in phase, 1 u32 parameter:
 *   [0] slot (EnumSlot.SLOT1 = 1 / SLOT2 = 2)
 * Source: `ptpip/BasePtpManager.java:1020` (getCapturedDateList). Response:
 * u32 count then count x u64 dates, little-endian; layout from
 * `ptpip/contentstransfer/CapturedDateListGetter.java:57-69`. The browse path
 * runs this once per browse (`transfer/ptp/PtpContentsRoot.java:360`) and
 * builds one container per returned date, whose createTime then seeds
 * `SDIO_GetContentsInfoList` (`transfer/ptp/PtpItemList.java:165`).
 *
 * (3) `SDIO_GetContentsInfoList` (0x923C), data-in phase, 5 u32 parameters:
 *   [0] createTime low 32 bits
 *   [1] createTime high 32 bits
 *   [2] count (entries per page; Sony asks for 100, or 1 for a single probe)
 *   [3] slot (EnumSlot value: 1 = SLOT1, 2 = SLOT2 — byte in the wire field)
 *   [4] order flag / isLocalTime (Sony passes true on the normal browse path)
 * Source: `ptpip/BasePtpManager.java:1072` (getContentsInfoList). The recorded
 * call site passes `PtpItemList.slotNumber`, which is `(byte) slot.value`
 * (`transfer/ptp/PtpPullContainer.java:59`), i.e. 1 or 2 — never 0.
 *
 * Slot selection. `transfer/ptp/PtpContentsRoot.java:324-355` chooses the slot
 * from `ContentsInfoListEnableStatusSlot1` (53716) / `...Slot2` (53717), and
 * reports DeviceBusy WITHOUT sending 0x923B when neither is enabled. Enabled is
 * `isEnable$2` (`PtpContentsRoot.java:431-440`), which requires the property's
 * own `isEnable` field to be True(1) or DispOnly(2)
 * (`property/dataset/EnumIsEnable.java:7-10`) AND
 * `(currentValue & 0xFF) == 1` — the mask is Sony's own
 * (`property/value/EnumOperationEnableStatus$EnumUnboxingLocalUtility._valueOf`,
 * `getMValue(Enable) == 1`), and the same low-byte mask is why a plain `== 1`
 * comparison against the whole 32-bit value is not equivalent.
 *
 * THAT PAIR IS AN APP-PERMISSION FLAG, NOT MEDIA PRESENCE. `slot1=1/en1` only
 * means the app is allowed to list slot 1; it says nothing about whether a card
 * is in the slot. Sony's media report is `MediaSLOT1Status` (53832) /
 * `MediaSLOT2Status` (53846) — see `PROP_MEDIA_SLOT1_STATUS` — and an ILCE-7M4
 * has two slots, so requesting the slot without the card produces exactly the
 * refusal this module used to report as an unexplained `0x923B` error. The slot
 * choice is therefore media-aware, and both slots are probed with retries.
 *
 * NOTE ON THE OPCODE VALUES. A hand-written analysis report kept next to the
 * decompiled sources quotes 0x9242 for SetContentsTransferMode and 0x9264 for
 * GetContentsInfoList. That report disagrees with the enum it cites: the
 * `EnumOperationCode` static initialiser in classes3.dex emits 37394 (= 0x9212)
 * and 37436 (= 0x923C), and the same enum's standard-PTP entries are all
 * correct (0x1001 GetDeviceInfo, 0x1004 GetStorageIDs, 0x101B GetPartialObject),
 * which is what makes the vendor values trustworthy —
 * `OperationRequestPacket` writes `mOperationCode.mCode & 0xFFFF` as the wire
 * opcode, so the enum value is the opcode. The verified values are used here.
 *
 * Response payload (responder -> initiator) is LITTLE-endian:
 *   148-byte fixed header, then `contentCount` x ContentInfo.
 * Field order comes from `contentstransfer/ContentsInfoListGetter.java:65-95`
 * (header) and `contentstransfer/data/ContentInfo.java:43-131` +
 * `contentstransfer/data/ContentFile.java:38-200` (entries). Every conditional
 * block of ContentFile is reproduced exactly: a single missed field would
 * desynchronise the rest of the list.
 */

import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { NikonPtpIpService, NikonPtpResponse, PtpTransport } from './NikonPtpIpService';

/** Exact 64-bit little-endian value kept as its two 32-bit halves. Sony's
 * creation stamps are echoed straight back to the camera and do not
 * necessarily fit a JS double exactly, so they are never folded into one for
 * anything that is sent back. */
export interface SonyU64 {
  low: number;
  high: number;
}

/** One enumerated file on the camera card. */
export interface SonyContentEntry {
  /** `ContentInfo.contentId` — the content handle. */
  contentId: number;
  contentType: number;
  /** `ContentFile.filePath` as the camera reports it. */
  filePath: string;
  /** `ContentFile.fileSize` in bytes. */
  fileSize: number;
  /** Local-time stamp folded into one number for display; `creationTime` keeps
   * the exact halves that paging must pass back. */
  creationDateTimeLocalTime: number;
  creationTime: SonyU64;
  modificationTime: SonyU64;
  fileFormat: number;
  fileId: number;
  representative: boolean;
  protectionStatus: boolean;
  dummyContent: boolean;
  shotMarkCount: number;
  rating: number;
  groupId: number;
  umid: Uint8Array;
}

/**
 * One enumerated file as the transfer page received it, kept so a later
 * contents-data request can rebuild Sony's u64 unique id
 * (`transfer/ptp/PtpPullItem.java:392-393`) without re-reading the list.
 */
interface SonyServedFile {
  contentId: number;
  fileId: number;
  fileSize: number;
  /** Slot number passed as parameter [3] of the 0x923C page this file came from. */
  slot: number;
}

/** One decoded `SDIO_GetContentsInfoList` response. */
export interface SonyContentPage {  entries: SonyContentEntry[];
  /** Header field: how many ContentInfo records the camera declared. */
  declaredCount: number;
  /** How many ContentInfo records were actually consumed. */
  parsedContentCount: number;
  /** Local-time stamp of the first / last parsed ContentInfo. The last one is
   * the cursor for the next page (Sony re-queries with it verbatim). */
  firstTime: SonyU64;
  lastTime: SonyU64;
  /** `ManagementInformation.version`, the first u16 of the payload. */
  managementVersion: number;
  /** `DbInfo.dataTime` / `DbInfo.slotId`, logged to identify the media. */
  dbInfoDataTime: SonyU64;
  dbInfoSlotId: number;
  /** True when a ContentInfo carried a contentType outside Sony's known set;
   * Sony's parser returns null there and abandons the rest of the list. */
  stoppedAtUnknownContentType: boolean;
  /** True when the buffer ended before the declared structure did. */
  truncated: boolean;
  /** True when `declaredCount` was too large to be a real page. */
  implausibleCount: boolean;
}

export interface SonyEnumerateOptions {
  /** Stop after this many entries. 0 / undefined = walk every page. */
  maxEntries?: number;
  /** Entries asked of the camera per page. Sony uses 100. */
  pageSize?: number;
  /** Media slot passed as parameter [3]. Sony's browse path uses 0 here. */
  slotNumber?: number;
  /** Hard stop on the page loop, so a camera that keeps answering cannot spin. */
  maxPages?: number;
}

/** Result of opening a Sony browse session and reading the first page. */
export interface SonyBrowseState {
  ok: boolean;
  message: string;
  host: string;
}

/** One gallery slice served to the transfer page. */
export interface SonyCatalogResult {
  ok: boolean;
  message: string;
  host: string;
  /** Entries discovered so far. Sony's protocol reports no grand total. */
  total: number;
  items: SonyContentEntry[];
  hasMore: boolean;
}

/** One ContentInfo as parsed, before it is flattened into per-file entries. */
interface SonyContentInfo {
  contentId: number;
  contentType: number;
  groupId: number;
  representative: boolean;
  protectionStatus: boolean;
  dummyContent: boolean;
  rating: number;
  shotMarks: number[];
  creationTime: SonyU64;
  modificationTime: SonyU64;
  files: SonyContentFile[];
}

/** One ContentFile record. Every field is consumed in Sony's read order. */
interface SonyContentFile {
  fileId: number;
  filePath: string;
  fileFormat: number;
  fileSize: number;
  umid: Uint8Array;
}

/** One raw `SDIO_GetCapturedDateList` answer, kept whole so the browse line can
 * carry the response code, the response-parameter list, the payload size and the
 * declared count of the same round trip. `code` is -1 when the round trip threw;
 * `dates` is null when the answer was not a usable list, which includes an OK
 * answer whose payload was empty or implausible — that case keeps `bytes` and
 * `count` so the two are distinguishable in the log. */
interface SonyDateAnswer {
  code: number;
  params: number[];
  bytes: number;
  count: number;
  dates: SonyU64[] | null;
}

/**
 * Bounds-checked little-endian reader.
 *
 * Every read verifies the buffer first; a short buffer sets `truncated` and
 * yields zeroes instead of throwing, so a malformed payload degrades to a
 * partial list rather than an exception in the middle of a session.
 */
class SonyContentReader {
  private readonly data: Uint8Array;
  private offset: number = 0;
  private truncatedFlag: boolean = false;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  isTruncated(): boolean {
    return this.truncatedFlag;
  }

  /** Bytes consumed so far — Sony's `ByteBuffer.position()`, which
   * `DevicePropInfoDataset.valueOf` compares against `capacity()`
   * (`property/dataset/DevicePropInfoDataset.java:268-271`). */
  position(): number {
    return this.offset;
  }

  private require(count: number): boolean {
    if (this.truncatedFlag) return false;
    if (count < 0 || this.offset + count > this.data.length) {
      this.truncatedFlag = true;
      return false;
    }
    return true;
  }

  u8(): number {
    if (!this.require(1)) return 0;
    const value = this.data[this.offset];
    this.offset += 1;
    return value;
  }

  u16(): number {
    if (!this.require(2)) return 0;
    const value = this.data[this.offset] | (this.data[this.offset + 1] << 8);
    this.offset += 2;
    return value;
  }

  u32(): number {
    if (!this.require(4)) return 0;
    const value = NikonPtpIpService.readU32(this.data, this.offset);
    this.offset += 4;
    return value;
  }

  /** u64 held as two halves; the caller decides how to interpret it. */
  u64(): SonyU64 {
    const low = this.u32();
    const high = this.u32();
    return { low: low, high: high };
  }

  /** Skips `count` bytes (fixed-size reserved or unused fields). */
  skip(count: number): void {
    if (!this.require(count)) return;
    this.offset += count;
  }

  take(count: number): Uint8Array {
    if (!this.require(count)) return new Uint8Array(0);
    const value = this.data.slice(this.offset, this.offset + count);
    this.offset += count;
    return value;
  }

  /** UTF-8 string of `count` bytes with trailing NUL characters trimmed —
   * Sony decodes the path and then calls `trimEnd('\u0000')`. */
  utf8(count: number): string {
    const bytes = this.take(count);
    let length = bytes.length;
    while (length > 0 && bytes[length - 1] === 0) length -= 1;
    return SonyPtpIpContent.decodeUtf8(bytes, length);
  }

  /** UTF-16LE string of `characters` code units, stopping at the NUL terminator.
   * PTP strings carry their length in characters, terminator included
   * (`DeviceInfoDataset.getString`, `base/deviceinfo/DeviceInfoDataset.java:33-41`;
   * `DevicePropInfoDataset.getStrValue` decodes the same bytes as UTF_16LE). */
  utf16(characters: number): string {
    const bytes = this.take(characters * 2);
    let result = '';
    for (let index = 0; index + 1 < bytes.length; index += 2) {
      const code = bytes[index] | (bytes[index + 1] << 8);
      if (code === 0) break;
      result += String.fromCharCode(code);
    }
    return result;
  }
}

/**
 * Decodes the whole `SDIO_GetContentsInfoList` payload.
 *
 * Kept as an instance so a parse can report *why* it stopped (unknown content
 * type versus a short buffer) without out-parameters.
 */
class SonyContentListParser {
  private readonly reader: SonyContentReader;
  private unknownContentType: boolean = false;

  constructor(data: Uint8Array) {
    this.reader = new SonyContentReader(data);
  }

  parse(): SonyContentPage {
    const reader = this.reader;
    const managementVersion = reader.u16();
    reader.skip(2);                                   // ManagementInformation.reserve
    const dbInfoDataTime = reader.u64();
    reader.skip(64);                                  // DbInfo.physicalMediaId
    reader.skip(64);                                  // DbInfo.databaseId
    const dbInfoSlotId = reader.u32();
    if (reader.isTruncated()) return SonyContentListParser.emptyPage(true, false);
    const declaredCount = reader.u32();
    if (reader.isTruncated()) return SonyContentListParser.emptyPage(true, false);
    if (declaredCount > SonyPtpIpContent.MAX_ENTRIES_PER_PAGE) {
      NikonPtpIpService.log(`sony contents header count=${declaredCount} implausible; parsing abandoned`);
      return SonyContentListParser.emptyPage(false, true);
    }

    const entries: SonyContentEntry[] = [];
    let parsedContentCount = 0;
    let firstTime: SonyU64 = { low: 0, high: 0 };
    let lastTime: SonyU64 = { low: 0, high: 0 };
    for (let index = 0; index < declaredCount; index++) {
      if (reader.isTruncated()) break;
      const info = this.parseContentInfo();
      if (info === null) break;
      parsedContentCount += 1;
      if (parsedContentCount === 1) firstTime = info.creationTime;
      lastTime = info.creationTime;
      for (const file of info.files) {
        entries.push({
          contentId: info.contentId,
          contentType: info.contentType,
          filePath: file.filePath,
          fileSize: file.fileSize,
          creationDateTimeLocalTime: SonyPtpIpContent.u64ToNumber(info.creationTime),
          creationTime: info.creationTime,
          modificationTime: info.modificationTime,
          fileFormat: file.fileFormat,
          fileId: file.fileId,
          representative: info.representative,
          protectionStatus: info.protectionStatus,
          dummyContent: info.dummyContent,
          shotMarkCount: info.shotMarks.length,
          rating: info.rating,
          groupId: info.groupId,
          umid: file.umid,
        });
      }
    }
    NikonPtpIpService.log(`sony contents header version=${managementVersion}` +
      ` dbTime=${dbInfoDataTime.high}:${dbInfoDataTime.low} slot=${dbInfoSlotId}` +
      ` declared=${declaredCount} parsed=${parsedContentCount} files=${entries.length}` +
      (reader.isTruncated() ? ' truncated=1' : '') +
      (this.unknownContentType ? ' stopped=unknown-content-type' : ''));
    return {
      entries: entries,
      declaredCount: declaredCount,
      parsedContentCount: parsedContentCount,
      firstTime: firstTime,
      lastTime: lastTime,
      managementVersion: managementVersion,
      dbInfoDataTime: dbInfoDataTime,
      dbInfoSlotId: dbInfoSlotId,
      stoppedAtUnknownContentType: this.unknownContentType,
      truncated: reader.isTruncated(),
      implausibleCount: false,
    };
  }

  /**
   * Reads one ContentInfo. Returns null when the entry cannot be consumed —
   * an unmapped contentType (Sony returns null and stops), a short buffer, or
   * a ContentFile that ended early.
   */
  private parseContentInfo(): SonyContentInfo | null {
    const reader = this.reader;
    const contentType = reader.u32();
    if (reader.isTruncated()) return null;
    if (!SonyPtpIpContent.isKnownContentType(contentType)) {
      // Sony maps an unmatched value to EnumContentType.UNSPECIFIED and its
      // ContentInfo.parse returns null, which aborts the whole list.
      NikonPtpIpService.log(`sony content-info contentType=0x${contentType.toString(16).toUpperCase()}` +
        ' unmapped; list parse stopped');
      this.unknownContentType = true;
      return null;
    }
    const contentId = reader.u32();
    reader.skip(4);                                   // dirNumber
    reader.skip(4);                                   // fileNumber
    reader.skip(4);                                   // groupType (unmapped is tolerated)
    const groupId = reader.u32();
    const representative = reader.u32() !== 0;
    reader.skip(8);                                   // creationDateTime (UTC stamp)
    reader.skip(8);                                   // modificationDateTimeUtc
    const creationTimeLocal = reader.u64();
    const modificationTimeLocal = reader.u64();
    const rating = reader.u32();
    const protectionStatus = reader.u32() !== 0;
    const dummyContent = reader.u32() !== 0;
    const shotMarkCount = reader.u32();
    if (reader.isTruncated()) return null;
    if (shotMarkCount > SonyPtpIpContent.MAX_COLLECTION_ITEMS) return null;
    const shotMarks: number[] = [];
    for (let index = 0; index < shotMarkCount; index++) {
      shotMarks.push(reader.u8());
    }
    const fileCount = reader.u32();
    if (reader.isTruncated()) return null;
    if (fileCount > SonyPtpIpContent.MAX_COLLECTION_ITEMS) return null;
    const files: SonyContentFile[] = [];
    for (let index = 0; index < fileCount; index++) {
      const file = this.parseContentFile();
      if (file === null) return null;
      files.push(file);
    }
    return {
      contentId: contentId,
      contentType: contentType,
      groupId: groupId,
      representative: representative,
      protectionStatus: protectionStatus,
      dummyContent: dummyContent,
      rating: rating,
      shotMarks: shotMarks,
      creationTime: creationTimeLocal,
      modificationTime: modificationTimeLocal,
      files: files,
    };
  }

  /**
   * Reads one ContentFile in `ContentFile.parse` order. The three conditional
   * parameter blocks are fixed-size and must be consumed even though metadata
   * interpretation is out of scope: image 2 x u32, video 19 x u32 (see
   * `VideoParam`), audio 4 x u32 (see `AudioParam`).
   */
  private parseContentFile(): SonyContentFile | null {
    const reader = this.reader;
    const fileId = reader.u16();
    reader.skip(2);                                   // unused
    const filePathLength = reader.u32();
    if (reader.isTruncated()) return null;
    if (filePathLength > SonyPtpIpContent.MAX_FILE_PATH_BYTES) return null;
    const filePath = reader.utf8(filePathLength);
    const fileFormat = reader.u32();
    const fileSize = reader.u64();
    const umid = reader.take(32);
    if (reader.isTruncated()) return null;
    const hasImageParam = reader.u32() !== 0;
    if (reader.isTruncated()) return null;
    if (hasImageParam) {
      reader.skip(8);                                 // imagePixWidth, imagePixHeight
    }
    const hasVideoParam = reader.u32() !== 0;
    if (reader.isTruncated()) return null;
    if (hasVideoParam) {
      reader.skip(76);                                // 19 x u32, see VideoParam
    }
    const hasAudioParam = reader.u32() !== 0;
    if (reader.isTruncated()) return null;
    if (hasAudioParam) {
      reader.skip(16);                                // 4 x u32, see AudioParam
    }
    if (reader.isTruncated()) return null;
    return {
      fileId: fileId,
      filePath: filePath,
      fileFormat: fileFormat,
      fileSize: SonyPtpIpContent.u64ToNumber(fileSize),
      umid: umid,
    };
  }

  private static emptyPage(truncated: boolean, implausible: boolean): SonyContentPage {
    return {
      entries: [],
      declaredCount: 0,
      parsedContentCount: 0,
      firstTime: { low: 0, high: 0 },
      lastTime: { low: 0, high: 0 },
      managementVersion: 0,
      dbInfoDataTime: { low: 0, high: 0 },
      dbInfoSlotId: 0,
      stoppedAtUnknownContentType: false,
      truncated: truncated,
      implausibleCount: implausible,
    };
  }
}

/**
 * Where one `DevicePropInfoDataset.valueOf` walk ended.
 *
 * `DevicePropInfoDataset.java:268-271` is why this exists: Sony accepts the
 * dataset *only* when the walk lands on the very last byte —
 * `AdbAssert.isTrue("invalid buffer " + byteBuffer.position() + " != " +
 * byteBuffer.capacity(), byteBuffer.position() == byteBuffer.capacity())` — and
 * throws `IllegalArgumentException("DevicePropInfoDataset invalid buffer")`
 * otherwise, which `DevicePropertyGetter.onOperationRequested` turns into a
 * rejected dump (`property/DevicePropertyGetter.java:74-79`). A walk that stops
 * short is a desync in Sony's terms, never a partial success.
 *
 * This port keeps serving whatever it did decode, but records the same
 * comparison here so ONE device run can tell "the camera never sent 53716 /
 * 53717" from "our walk desynchronised and lost them".
 */
class SonyPropWalk {
  /** Records the loop completed before it stopped. */
  records: number = 0;
  /** Declared record count: the u64 at offset 0 (`DevicePropInfoDataset.java:121`). */
  declaredRecords: number = 0;
  /**
   * Data-phase length the TRANSPORT delivered for the response this walk parsed
   * — `NikonPtpResponse.data.length` as built by `receiveDataPhase`, which
   * returns exactly the accumulated byte count and throws unless it equals the
   * u64 total carried by the StartData packet
   * (`NikonPtpIpService.ets:1401-1410`). This stands in for Sony's
   * `byteBuffer.capacity()` and is the walk's denominator: it is what the camera
   * sent, never a number derived from the record count or from the parser's own
   * progress.
   */
  receivedBytes: number = 0;
  /** Bytes the walk consumed — Sony's `byteBuffer.position()`. */
  consumedBytes: number = 0;
  /** Bytes actually handed to the parser. Normally equal to `receivedBytes`;
   * kept separate so a short hand-off is detectable instead of being mistaken
   * for a complete walk. */
  handedBytes: number = 0;
  /** The round trip this walk belongs to (`probe`, `enable-poll`, ...). A verdict
   * is only meaningful against the payload it walked, so the source travels with
   * the walk instead of being inferred from whichever dump ran last. */
  source: string = '-';
  /** Parameter list of the dump this walk parsed, e.g. `[1,1]`. */
  params: string = '-';
  /** `clean` | `short` | `overrun` | `bad-type` | `count-rejected` | `not-run`.
   * `clean` requires the walk to land exactly on the RECEIVED data-phase length
   * (`DevicePropInfoDataset.java:268-271`). Only `clean` means an absent
   * property is genuinely absent. */
  result: string = 'not-run';
  /** `0xTYPE@record#byte` of the first record whose data type has no width. */
  firstBadType: string = '-';
  /** Every array-typed record seen, as `PROPCODE/0xTYPE@record`. Sony sizes
   * NONE of them (`getValue` falls through to `shouldNeverReachHere` for
   * ordinals 11..20, `DevicePropInfoDataset.java:88-95`), so one appearing at
   * all is itself a finding. */
  arrayTypes: string = '-';
  /** Whether the 53716 / 53717 record was read at all — independent of its
   * value, which is the whole point: an absent code and a present-but-not-enabled
   * code look identical in the value map. */
  slot1Seen: boolean = false;
  slot2Seen: boolean = false;
  slot1Type: string = '-';
  slot2Type: string = '-';
  /** Byte offset of that record's property code, so a desync is locatable. */
  slot1Offset: number = -1;
  slot2Offset: number = -1;
  /** `0xCODE@byte:type` of every MEDIA property record the walk actually read,
   * in the order it read them — `PROP_PLAYBACK_MEDIA`,
   * `PROP_MEDIA_SLOT1_STATUS`, `PROP_MEDIA_SLOT2_STATUS`,
   * `PROP_CONTENTS_INFO_LIST_UPDATE_TIME_SLOT1/2`. Recorded at the moment the
   * code is read, by CODE (never by byte offset), so a `clean` walk with a code
   * missing here proves the camera did not send that record while any other
   * walk verdict leaves its absence unproven — exactly the distinction
   * `slot1Seen`/`slot2Seen` make for the permission flags. `-` when the walk
   * read none of them. */
  mediaRecords: string = '-';
  /** Where the last walked record started and how long it was, so a short walk
   * names the record the walk died on. */
  lastRecordOffset: number = -1;
  lastRecordBytes: number = 0;
  lastRecordCode: number = -1;
  lastRecordType: string = '-';
}

/**
 * Decodes one `SDIO_GetAllExtDevicePropInfo` payload into
 * `devicePropCode -> current value`.
 *
 * Field order and value encoding are `DevicePropInfoDataset.valueOf` /
 * `getValue` (`ptpip/property/dataset/DevicePropInfoDataset.java:76-272`):
 *   u64 entryCount
 *   per entry:
 *     u16 devicePropCode
 *     u16 dataType
 *     u8  getSet
 *     u8  isEnable
 *     <defaultValue> <currentValue>     both encoded by dataType
 *     u8  formFlag
 *     formFlag 0 None        -> nothing more
 *     formFlag 1 Range       -> 3 more values (min, max, step)
 *     formFlag 2 Enumeration -> u16 n, n values, u16 m, m values
 *
 * `getValue` sizes exactly six scalars — INT8(1)/UINT8(2) as 1 byte, INT16(3)/
 * UINT16(4) as 2, UINT32(6) as 4, UINT64(8) as 8 — plus the `STR` length form
 * (a u8 character count then that many UTF-16LE code units,
 * `getStrValue`, `:61-74`). It reaches `AdbAssert.shouldNeverReachHere` and
 * consumes ZERO bytes for every other code, including INT32(5), INT64(7),
 * INT128(9), UINT128(10) and the array codes AINT8(16385)..AUINT128(16394)
 * (`:88-95`). The widths here are keyed off the `EnumDataType` codes instead:
 * the same six, plus the four signed/128-bit scalars, which is strictly safer
 * than consuming nothing. A type this port still cannot size aborts the walk
 * and is named in `SonyPropWalk.firstBadType` rather than desynchronising it.
 *
 * The constructor takes the RECEIVED data-phase length of the response it is
 * given, not the length of the array it was handed, so `clean` means "the walk
 * ended exactly on the last byte the camera sent" — Sony's assertion at
 * `DevicePropInfoDataset.java:268-271` — and a short hand-off is reported as
 * `short` instead of being mistaken for a complete walk.
 */
class SonyDevicePropInfoParser {
  private readonly reader: SonyContentReader;
  private readonly values: Map<number, number> = new Map<number, number>();
  /**
   * The STRING half of every `DATA_TYPE_STR` record, keyed by property code.
   *
   * Sony keeps the string beside the number in the very same accumulated map —
   * `DevicePropInfoDataset.mCurrentStringValue` next to `mCurrentValue` — and
   * reads `LiveViewUrl` out of it (`PtpIpCamera.java:705-711`). This port used
   * to consume the string bytes and drop them, which is why the 0x9209 walk
   * could not serve the live view URL and a separate request had to be sent.
   */
  private readonly strings: Map<number, string> = new Map<number, string>();
  /**
   * The ORDERED selectable values of a formFlag-2 (enumeration) record, by
   * property code — Sony's `mGetSetValues`.
   *
   * `DevicePropInfoDataset.java:253-256` builds this second list as a
   * `LinkedList` and keeps it as `mGetSetValues` (`:33`); the first list is an
   * unordered `HashSet` kept as `mSetValues` (`:37`). Every setting controller
   * offers the ordered one to the user and uses the set only as a membership
   * filter — e.g. `FNumberSettingController.java:217-218`,
   * `IsoSpeedRateSettingController.java:363-364`,
   * `ShutterSpeedSettingController.java:204-205`,
   * `ExposureCompensationSettingController.java:151-152`. So this is the list a
   * parameter panel must show, and it arrives inside the 0x9209 dump we already
   * request — no extra round trip is needed for it.
   */
  private readonly getSetValues: Map<number, number[]> = new Map<number, number[]>();
  /** The string `readEncodedValue` just consumed, when it was asked to decode. */
  private lastString: string = '';
  /** `DevicePropInfoDataset.mIsEnable` per property code, kept because Sony's
   * `isEnable$2` requires True(1)/DispOnly(2) before it looks at the value
   * (`PtpContentsRoot.java:431-440`). */
  private readonly enableFlags: Map<number, number> = new Map<number, number>();
  /**
   * `DevicePropInfoDataset.mGetSet` per property code (`EnumGetSet`
   * Get(0)/GetSet(1)/Undefined(2)). Sony's writability test needs it:
   * `canSet` is `mIsEnable == True && mGetSet == GetSet`
   * (`ptp/remotecontrol/controller/AbstractController.java:90-93`), so the
   * `isEnable` octet alone cannot answer "may I write this".
   */
  private readonly getSetFlags: Map<number, number> = new Map<number, number>();
  /**
   * `DevicePropInfoDataset.mDataType` per property code, needed to size the
   * payload of a 0x9205 set correctly: Sony serialises the value as a plain
   * little-endian scalar of the property's OWN data type, and the width varies
   * per property and per camera (`zzq.getBytes`, and `AbstractController` gates
   * every set on the record it was read from). Hard-coding 2 or 4 bytes would
   * work on one body and corrupt another.
   */
  private readonly dataTypes: Map<number, number> = new Map<number, number>();
  /** Where this walk started, ended, and which record it lost. */
  private readonly walkReport: SonyPropWalk = new SonyPropWalk();
  private failure: string = '';

  constructor(data: Uint8Array, receivedBytes: number, source: string, params: string) {
    this.reader = new SonyContentReader(data);
    // `receivedBytes` is the transport's own data-phase length for the response
    // being parsed, and `source`/`params` name that round trip. Both travel with
    // the walk so its verdict can never be compared against another dump's byte
    // count — the mistake that made a 25-record delta look like a short walk of
    // a 9437-byte property list.
    this.walkReport.receivedBytes = receivedBytes;
    this.walkReport.handedBytes = data.length;
    this.walkReport.source = source;
    this.walkReport.params = params;
  }

  /** The parsed `isEnable` octets, empty when the walk failed. */
  enableFlagMap(): Map<number, number> {
    return this.enableFlags;
  }

  /** The decoded strings of the STR records this walk carried, by property code
   * (Sony's `mCurrentStringValue`; `DevicePropInfoDataset.getStrValue`). */
  stringMap(): Map<number, string> {
    return this.strings;
  }

  /** The ordered selectable values of the enumeration records this walk carried,
   * by property code — Sony's `mGetSetValues`. */
  optionMap(): Map<number, number[]> {
    return this.getSetValues;
  }

  /** The `mGetSet` octets this walk carried, by property code. */
  getSetMap(): Map<number, number> {
    return this.getSetFlags;
  }

  /** The `mDataType` of each record this walk carried, by property code. */
  dataTypeMap(): Map<number, number> {
    return this.dataTypes;
  }

  /** The walk's own accounting, valid even when `parse()` returned null. */
  walk(): SonyPropWalk {
    return this.walkReport;
  }

  /** True once the payload could not be walked; `reason()` says why. */
  failed(): boolean {
    return this.failure.length > 0 || this.reader.isTruncated();
  }

  reason(): string {
    return this.failure.length > 0 ? this.failure : (this.reader.isTruncated() ? 'truncated' : '');
  }

  /** Records a data type this port cannot size, once, with enough context to
   * find it again: the type, the record ordinal and the byte offset. */
  private noteBadType(dataType: number, recordIndex: number, offset: number): void {
    if (this.walkReport.firstBadType === '-') {
      this.walkReport.firstBadType =
        `${SonyPtpIpContent.dataTypeText(dataType)}@record${recordIndex}#byte${offset}`;
    }
    this.walkReport.result = 'bad-type';
  }

  parse(): Map<number, number> | null {
    const reader = this.reader;
    const countLow = reader.u32();
    const countHigh = reader.u32();
    if (countHigh !== 0 || countLow > SonyPtpIpContent.MAX_DEVICE_PROPERTIES) {
      this.failure = `implausible-count=${countHigh}:${countLow}`;
      this.walkReport.result = 'count-rejected';
      this.walkReport.declaredRecords = countLow;
      this.walkReport.consumedBytes = reader.position();
      return null;
    }
    this.walkReport.declaredRecords = countLow;
    for (let index = 0; index < countLow; index++) {
      const recordOffset = reader.position();
      const code = reader.u16();
      const dataType = reader.u16();
      // The two properties Sony's slot choice turns on. Recorded here, at the
      // moment the code is read, so "never sent" stays distinguishable from
      // "sent but not enabled" and from "lost after a desync".
      if (code === SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_ENABLE_SLOT1) {
        this.walkReport.slot1Seen = true;
        this.walkReport.slot1Type = SonyPtpIpContent.dataTypeText(dataType);
        this.walkReport.slot1Offset = recordOffset;
      } else if (code === SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_ENABLE_SLOT2) {
        this.walkReport.slot2Seen = true;
        this.walkReport.slot2Type = SonyPtpIpContent.dataTypeText(dataType);
        this.walkReport.slot2Offset = recordOffset;
      }
      // The media-presence / playback-media properties, recorded BY CODE at the
      // same moment and for the same reason: `isMediaPropCode` is the only place
      // the code list lives, so a code added there is reported here for free.
      if (SonyPtpIpContent.isMediaPropCode(code)) {
        const entry = `0x${code.toString(16).toUpperCase().padStart(4, '0')}` +
          `@${recordOffset}:${SonyPtpIpContent.dataTypeText(dataType)}`;
        this.walkReport.mediaRecords = this.walkReport.mediaRecords === '-'
          ? entry : `${this.walkReport.mediaRecords},${entry}`;
      }
      // Sony's own array codes (`0x4000 | base`) are never sized by `getValue`;
      // naming every one that appears is what makes a guessed width auditable.
      if ((dataType & SonyPtpIpContent.DATA_TYPE_ARRAY_FLAG) !== 0) {
        const entry = `0x${code.toString(16).toUpperCase().padStart(4, '0')}` +
          `/${SonyPtpIpContent.dataTypeText(dataType)}@${index}`;
        this.walkReport.arrayTypes = this.walkReport.arrayTypes === '-'
          ? entry : `${this.walkReport.arrayTypes},${entry}`;
      }
      const getSetFlag = reader.u8();                 // EnumGetSet
      const isEnable = reader.u8();                   // EnumIsEnable octet
      this.readEncodedValue(dataType, false, index);  // defaultValue
      const currentValue = this.readEncodedValue(dataType, true, index);
      if (this.failed()) {
        this.walkReport.consumedBytes = reader.position();
        return null;
      }
      const formFlag = reader.u8();
      if (formFlag === 1) {
        this.readEncodedValue(dataType, false, index);
        this.readEncodedValue(dataType, false, index);
        this.readEncodedValue(dataType, false, index);
      } else if (formFlag === 2) {
        const allValues = this.readValueList(dataType, index);
        if (allValues === null) {
          this.walkReport.consumedBytes = reader.position();
          return null;
        }
        const selectable = this.readValueList(dataType, index);
        if (selectable === null) {
          this.walkReport.consumedBytes = reader.position();
          return null;
        }
        // Sony keeps the ordered one as `mGetSetValues` and it is the list every
        // setting controller shows; the unordered set is only a membership test.
        if (selectable.length > 0) {
          this.getSetValues.set(code, selectable);
        }
      }
      if (this.failed()) {
        this.walkReport.consumedBytes = reader.position();
        return null;
      }
      this.walkReport.lastRecordOffset = recordOffset;
      this.walkReport.lastRecordBytes = reader.position() - recordOffset;
      this.walkReport.lastRecordCode = code;
      this.walkReport.lastRecordType = SonyPtpIpContent.dataTypeText(dataType);
      this.walkReport.records = index + 1;
      this.values.set(code, currentValue);
      if (dataType === SonyPtpIpContent.DATA_TYPE_STR) {
        this.strings.set(code, this.lastString);
      }
      this.enableFlags.set(code, isEnable);
      this.getSetFlags.set(code, getSetFlag);
      this.dataTypes.set(code, dataType);
    }
    this.walkReport.consumedBytes = this.reader.position();
    if (this.reader.isTruncated()) {
      // Sony's walk would have thrown on the position/capacity assertion; say
      // which of the two directions it went rather than just "failed".
      if (this.walkReport.result !== 'bad-type') this.walkReport.result = 'overrun';
      return null;
    }
    // `DevicePropInfoDataset.java:268`: only an exact landing on the last byte
    // the camera SENT is a clean walk. Short means the record count, a value
    // width or a form flag consumed the wrong number of bytes; a parser handed
    // fewer bytes than the transport received can never claim `clean` either.
    this.walkReport.result =
      this.walkReport.handedBytes === this.walkReport.receivedBytes &&
      this.walkReport.consumedBytes === this.walkReport.receivedBytes
        ? 'clean' : 'short';
    return this.values;
  }

  /**
   * One `u16` count followed by that many encoded values, returned as read.
   *
   * A formFlag-2 record carries TWO of these: the first is Sony's unordered
   * `mSetValues` and the second its ORDERED `mGetSetValues`
   * (`DevicePropInfoDataset.java:248-256`, the `HashSet` then the `LinkedList`).
   * The caller keeps the second and ignores the first.
   *
   * Returns null when the walk desynced, which the caller must treat as a failed
   * walk: a list of the wrong length means every later record is misaligned.
   */
  private readValueList(dataType: number, recordIndex: number): number[] | null {
    const count = this.reader.u16();
    const values: number[] = [];
    for (let index = 0; index < count; index++) {
      values.push(this.readEncodedValue(dataType, true, recordIndex));
      if (this.failed()) return null;
    }
    return values;
  }

  /**
   * Consumes one encoded value and, when `numeric`, returns it. Strings and
   * arrays yield 0: only the numeric properties drive this module.
   */
  private readEncodedValue(dataType: number, numeric: boolean, recordIndex: number): number {
    if (this.failure.length > 0 || this.reader.isTruncated()) return 0;
    if (dataType === SonyPtpIpContent.DATA_TYPE_STR) {
      // DevicePropInfoDataset.getStrValue: a u8 character count, then that many
      // UTF-16LE characters; the string itself drops the trailing terminator.
      // The byte count consumed is the same either way — `utf16` takes exactly
      // `characters * 2` — so a decoded string cannot desync the walk.
      const characters = this.reader.u8();
      if (numeric) {
        this.lastString = this.reader.utf16(characters);
      } else {
        this.reader.skip(characters * 2);
      }
      return 0;
    }
    if ((dataType & SonyPtpIpContent.DATA_TYPE_ARRAY_FLAG) !== 0) {
      // Sony sizes no array type at all — this width is this port's own, and the
      // u8 element count matches the only variable-length count in the format
      // (`getStrValue`, and `getValue`'s STR branch). Every array record is
      // named in `SonyPropWalk.arrayTypes` so one device run shows whether this
      // guess was ever exercised.
      const base = dataType & (SonyPtpIpContent.DATA_TYPE_ARRAY_FLAG - 1);
      const width = SonyPtpIpContent.dataTypeWidth(base);
      if (width <= 0) {
        this.failure = `unknown-data-type=${SonyPtpIpContent.dataTypeText(dataType)}`;
        this.noteBadType(dataType, recordIndex, this.reader.position());
        return 0;
      }
      const items = this.reader.u8();
      this.reader.skip(items * width);
      return 0;
    }
    const width = SonyPtpIpContent.dataTypeWidth(dataType);
    if (width <= 0) {
      this.failure = `unknown-data-type=${SonyPtpIpContent.dataTypeText(dataType)}`;
      this.noteBadType(dataType, recordIndex, this.reader.position());
      return 0;
    }
    if (width === 1) return this.reader.u8();
    if (width === 2) return this.reader.u16();
    if (width === 4) return this.reader.u32();
    // 8 and 16 byte values: the properties this module reads are 32-bit or
    // smaller, so the low half is what is kept.
    const low = this.reader.u32();
    this.reader.skip(width - 4);
    return numeric ? low : 0;
  }
}

/**
 * Sony private-opcode content enumeration over the shared PTP/IP session.
 *
 * The stateful half (`open` / `next` / `close`) is the browser the
 * image-transfer page drives: it keeps the current page of up to
 * `PAGE_SIZE` entries buffered and serves slices of it, so pagination never
 * re-reads a page the app already holds.
 */
export class SonyPtpIpContent {
  /**
   * `EnumOperationCode.SDIO_SetContentsTransferMode` = 37394. The analysis
   * report beside the decompiled sources says 0x9242; see the file header —
   * 37394 is what classes3.dex actually emits.
   */
  static readonly OP_SET_CONTENTS_TRANSFER_MODE = 0x9212;
  /** `EnumOperationCode.GetDeviceInfo` = 4097 (0x1001). Step (S1) of Sony's
   * sequence (`initialization/Initializer.java:111`), sent before everything
   * else; its dataset is where Sony reads `isSupported(SDIO_*)` from. */
  static readonly OP_GET_DEVICE_INFO = 0x1001;
  /**
   * `EnumOperationCode.SDIO_Connect` = 37377 (0x9201). Sony's own session
   * connect, sent three times with parameters `[phase, 0, 0]` for phase 1, 2
   * and 3 (`SDIO_Connect.create`:
   * `new SDIO_Connect(NoDataOrDataInPhase, SDIO_Connect, new int[]{i, 0, 0},
   * null, initializer)`, `base/transaction/SDIO_Connect.java:10-14`; call
   * sites `initialization/Initializer.java:199`, `:206`, `:260`).
   */
  static readonly OP_SDIO_CONNECT = 0x9201;
  /**
   * `EnumOperationCode.SDIO_GetExtDeviceInfo` = 37378 (0x9202). Data-in; its
   * payload becomes `DataCodeUtil.mDeviceInfo` and the arguments of
   * `onInitialized` (`initialization/Initializer.java:241-256`,
   * `BasePtpManager.java:321`).
   */
  static readonly OP_GET_EXT_DEVICE_INFO = 0x9202;
  /** `EnumOperationCode.SDIO_GetContentsInfoList` = 37436. The report says
   * 0x9264; see the file header. */
  static readonly OP_GET_CONTENTS_INFO_LIST = 0x923C;
  /** `EnumOperationCode.SDIO_GetAllExtDevicePropInfo` = 37385
   * (0x9209). Step (1) of the sequence in the file header. */
  static readonly OP_GET_ALL_EXT_DEVICE_PROP_INFO = 0x9209;
  /** `EnumOperationCode.SDIO_GetCapturedDateList` = 37435
   * (0x923B). Step (2) of the sequence in the file header. */
  static readonly OP_GET_CAPTURED_DATE_LIST = 0x923B;
  /** `EnumOperationCode.SDIO_GetVendorCodeVersion` = 37398, which is **0x9216**
   * (not 0x9226 = 37414; see the file header). Sent with an EMPTY parameter
   * list — `AbstractTransaction(EnumOperationCode, callback)` hardcodes
   * `new int[0]` (`base/transaction/AbstractTransaction.java:17-19`) — and its
   * first RESPONSE parameter is the version that gates the extra parameter of
   * the property dump below (`Initializer.java:223-231`). */
  static readonly OP_GET_VENDOR_CODE_VERSION = 0x9216;
  /** `EnumOperationCode.SDIO_OpenSession` = 37392 (0x9210). Step (S2) of the
   * vendor session when the function mode is `REMOTE_CONTROL_WITH_TRANSFER_MODE`
   * (`initialization/Initializer.java:95`):
   * `new SDIO_OpenSession(NoDataOrDataInPhase, SDIO_OpenSession,
   * new int[]{1, functionMode.value}, null, this)`. The standard `OpenSession`
   * is the OTHER branch of the same if/else (`Initializer.java:83-88`), never an
   * additional step. */
  static readonly OP_SDIO_OPEN_SESSION = 0x9210;
  /** `EnumOperationCode.OpenSession` = 4098 (0x1002), the standard branch of
   * `createOpenSessionState` (`Initializer.java:87`) and the operation the
   * transport's handshake has always sent. Recorded here only so the browse line
   * can name it when no vendor open was requested. */
  static readonly OP_OPEN_SESSION_DEFAULT = 0x1002;
  /** `EnumOperationCode.SDIO_GetDeviceDescriptionFile` = 37434 (0x923A).
   * Steps (S1b)/(S1c): parameter 1 fetches the DD document
   * (`initialization/Initializer.java:161`), parameter 2 the DID document
   * (`initialization/SDIO_GetDeviceDescriptionFileState2.java:20`); both are
   * `EnumDataPhaseInfo.NoDataOrDataInPhase` and answer in the data phase. */
  static readonly OP_GET_DEVICE_DESCRIPTION_FILE = 0x923A;

  /** `EnumDevicePropCode.ContentsTransferEnableStatus` = 53909 (0xD295).
   * `ContentsTransferModeSetter` will not report success until this reads
   * ENABLE (`ptpip/mtp/ContentsTransferModeSetter.java:117-129`). */
  static readonly PROP_CONTENTS_TRANSFER_ENABLE_STATUS = 53909;
  /** `EnumDevicePropCode.ContentsInfoListEnableStatusSlot1` = 53716 (0xD1D4). */
  static readonly PROP_CONTENTS_INFO_LIST_ENABLE_SLOT1 = 53716;
  /** `EnumDevicePropCode.ContentsInfoListEnableStatusSlot2` = 53717 (0xD1D5). */
  static readonly PROP_CONTENTS_INFO_LIST_ENABLE_SLOT2 = 53717;
  /** `EnumDevicePropCode.ContentsInfoListUpdateTimeSlot1` = 53718 (0xD1D6) and
   * `...Slot2` = 53719 (0xD1D7)
   * (`base/transaction/EnumDevicePropCode.java:203-204`). Sony never reads these
   * on the browse path; they are logged because the presence and value of an
   * update time is the only property-level hint that a contents DB already
   * exists for that slot (a slot whose DB was never built has nothing to date).
   */
  static readonly PROP_CONTENTS_INFO_LIST_UPDATE_TIME_SLOT1 = 53718;
  static readonly PROP_CONTENTS_INFO_LIST_UPDATE_TIME_SLOT2 = 53719;
  /** `EnumDevicePropCode.MediaSLOT1Status` = 53832 (0xD248) and
   * `MediaSLOT2Status` = 53846 (0xD256)
   * (`base/transaction/EnumDevicePropCode.java:74`, `:86`). THESE — not the
   * `ContentsInfoListEnableStatusSlot1/2` permission flags above — are Sony's
   * media presence report. The value is an `EnumMediaSLOTStatus`, matched with
   * `255 & value` (`property/value/EnumMediaSLOTStatus$EnumUnboxingLocalUtility
   * .java:9-17`): Undefined=65535, OK=1, "No card"=2, "Card error"=3,
   * "Card recognizing/Card locked and DB error"=4 (`getMValue`/`getMString`,
   * `:19-55`). `MediaStatusController.java:104-122` is Sony's own reader. */
  static readonly PROP_MEDIA_SLOT1_STATUS = 53832;
  static readonly PROP_MEDIA_SLOT2_STATUS = 53846;
  /** `EnumDevicePropCode.PlaybackMedia` = 53314 (0xD042)
   * (`base/transaction/EnumDevicePropCode.java:125`). This is the media the
   * camera considers current and is what Sony's own UI switches on; its values
   * are `EnumPlaybackMedia` UNDEFINED(0) / SLOT1(1) / SLOT2(2), matched with
   * `255 & value` (`base/transaction/EnumPlaybackMedia.java:22-26`, `:33-41`). */
  static readonly PROP_PLAYBACK_MEDIA = 53314;

  /** `EnumMediaSLOTStatus` raw values in the enum's own order — `getMValue`:
   * Undefined(65535), OK(1), No card(2), Card error(3),
   * Card recognizing/Card locked and DB error(4)
   * (`property/value/EnumMediaSLOTStatus$EnumUnboxingLocalUtility.java:38-55`). */
  static readonly MEDIA_SLOT_STATUS_OK = 1;
  static readonly MEDIA_SLOT_STATUS_NO_CARD = 2;
  static readonly MEDIA_SLOT_STATUS_CARD_ERROR = 3;
  static readonly MEDIA_SLOT_STATUS_RECOGNIZING = 4;
  /** `EnumPlaybackMedia` values (UNDEFINED(0) / SLOT1(1) / SLOT2(2),
   * `base/transaction/EnumPlaybackMedia.java:22-26`). */
  static readonly PLAYBACK_MEDIA_UNDEFINED = 0;
  static readonly PLAYBACK_MEDIA_SLOT1 = 1;
  static readonly PLAYBACK_MEDIA_SLOT2 = 2;
  /** `EnumMediaSLOTStatus$EnumUnboxingLocalUtility._valueOf` and
   * `EnumPlaybackMedia.Companion.valueOf` both compare with `255 & value`
   * (`:11` and `:35`), so the low byte is the enum value in both cases. */
  static readonly MEDIA_VALUE_MASK = 0xFF;

  /** `EnumContentsTransferEnableStatus.ENABLE` = 1
   * (`property/value/EnumContentsTransferEnableStatus.java:24`), and also the
   * value `PtpContentsRoot.isEnable$2` requires for the slot status properties
   * (`EnumOperationEnableStatus` Enable, mValue 1, masked with 0xFF). */
  static readonly PROPERTY_VALUE_ENABLE = 1;
  /** `EnumSlot.SLOT1` / `EnumSlot.SLOT2`. */
  static readonly SLOT_1 = 1;
  static readonly SLOT_2 = 2;
  /** Parameter [0] of `SDIO_GetAllExtDevicePropInfo` on the REFRESH form: the
   * `true` `DevicePropertyGetter.execute` turns into 1, which is what Sony sends
   * when it re-reads the dump on `SDIE_DevicePropChanged`
   * (`DevicePropertyUpdater$$ExternalSyntheticLambda0.java:24`). */
  static readonly GET_ALL_EXT_DEVICE_PROP_INFO_PARAM = 1;
  /** Parameter [0] of `SDIO_GetAllExtDevicePropInfo` on the INITIAL form: the
   * `false` of `DevicePropertyGetter.execute(false, ...)`, whose body is
   * `{z ? 1 : 0}` (`DevicePropertyGetter.java:40-44`), i.e. 0. That is the form
   * `BasePtpManager.onInitialized` uses (`BasePtpManager.java:369`), and it is
   * the form the FIRST dump of a session must use. */
  static readonly GET_ALL_EXT_DEVICE_PROP_INFO_PARAM_INITIAL = 0;
  /**
   * `EnumFlagOfDevicePropertyOption.Companion.valueOf` returns ENABLE at or
   * above this vendor code version (`initialization/Initializer.java:228-231`
   * feeds it the `SDIO_GetVendorCodeVersion` answer). When the flag is ENABLE,
   * `DevicePropertyGetter.execute` sends a second parameter equal to the flag
   * value (`DevicePropertyGetter.java:40-44`); the flag's own value is
   * `EnumFlagOfDevicePropertyOption.ENABLE` = 1.
   */
  static readonly VENDOR_CODE_VERSION_FOR_PROPERTY_FLAG = 310;

  /** Parameter [0] of `SDIO_Connect`: the phase ordinal.
   * `SDIO_Connect.create(1..3, ...)` — `Initializer.java:199`, `:206`, `:260`. */
  static readonly SDIO_CONNECT_PHASE_1 = 1;
  static readonly SDIO_CONNECT_PHASE_2 = 2;
  static readonly SDIO_CONNECT_PHASE_3 = 3;
  /** Parameters [1] and [2] of `SDIO_Connect` are both literal zeros:
   * `new int[]{i, 0, 0}` (`base/transaction/SDIO_Connect.java:13`). */
  static readonly SDIO_CONNECT_PARAM_TAIL = 0;
  /** Parameter [0] of `SDIO_GetExtDeviceInfo` is always 300, with or without
   * the flag: `new int[]{300}` / `new int[]{300, flag.value}`
   * (`initialization/SDIO_GetExtDeviceInfoState.java:21`). */
  static readonly GET_EXT_DEVICE_INFO_PARAM = 300;

  /** Sony's `ThreadUtil.postDelayedOnWorkerThread(5000, timeOutRunnable)`. */
  static readonly CONTENTS_TRANSFER_ENABLE_TIMEOUT_MS = 5000;
  /** How often the property dump is re-read while waiting for ENABLE. Sony
   * re-reads it once per `SDIE_DevicePropChanged` event instead; polling is the
   * request/response equivalent and the same operation either way. */
  static readonly CONTENTS_TRANSFER_ENABLE_POLL_MS = 250;

  /** `EnumDataType.STR` mCode (`property/dataset/EnumDataType.java:47`). */
  static readonly DATA_TYPE_STR = 65535;
  /** Array data types are `0x4000 | baseType` (e.g. AINT8 = 16385). */
  static readonly DATA_TYPE_ARRAY_FLAG = 0x4000;
  /** Trust bound on the property dump's declared entry count. */
  static readonly MAX_DEVICE_PROPERTIES = 4096;
  /** Trust bound on the captured-date list's declared count. */
  private static readonly MAX_CAPTURED_DATES = 4096;

  /** `EnumContentsSelectType.REMOTE_DEVICE`. */
  static readonly CONTENTS_SELECT_TYPE_REMOTE_DEVICE = 2;
  /** `EnumContentsTransferMode.ON`. */
  static readonly CONTENTS_TRANSFER_MODE_ON = 1;
  /** `EnumAdditionalInformation.NONE`. */
  static readonly ADDITIONAL_INFORMATION_NONE = 0;

  /**
   * DIVERGENCE (a), switchable. Sony never sends `SDIO_SetContentsTransferMode`
   * (0x9212) on the `PtpContentsRoot` RCT/IP path at all: that operation belongs
   * to the standard-MTP object-browser flow, and the contents list on this path
   * is reached from `PtpContentsRoot.getContainerCount` ->
   * `SDIO_GetCapturedDateList` without it (see the file header). Of the three
   * divergences this is the only one that can change camera state, so it is the
   * one that must be switchable rather than assumed: with the constant TRUE
   * (the default, because Sony does not send it) the browse runs the six setup
   * steps, waits `RCT_SKIP_SETTLE_MS`, and goes straight to the slot probe — the
   * experiment is whether the mode-2 session alone can serve 0x923B. With it
   * FALSE the previous behaviour is restored verbatim (0x9212 `[2, 1, 0]`), and
   * either way the browse line reports which was used as
   * `setTransferMode=skipped` / `setTransferMode=0x9212:[2,1,0]`.
   */
  static readonly SKIP_SET_CONTENTS_TRANSFER_MODE_ON_RCT = true;
  /** How long to let the camera settle before the slot probe when 0x9212 is
   * skipped. With 0x9212 sent, that round trip's latency plus the enable wait is
   * what delays the probe; skipping the operation must not make the probe
   * arrive earlier than the state it replaced, so ~1 s stands in for it. */
  static readonly RCT_SKIP_SETTLE_MS = 1000;
  /** How long to wait between two `SDIO_GetCapturedDateList` (0x923B) attempts
   * on the same slot before retrying it. */
  static readonly DATE_TRY_RETRY_DELAY_MS = 1000;
  /** Attempts per slot in the systematic 0x923B sweep. A slot is retried this
   * many times before the other slot is tried, so a single transient refusal
   * cannot decide which slot the pages use. */
  static readonly DATE_TRY_ATTEMPTS = 3;

  /** Entries Sony asks for per page in its own browser (`PtpItemList`). */
  static readonly PAGE_SIZE = 100;
  /** Media slot used when neither `MediaSLOT1Status`/`MediaSLOT2Status` nor the
   * `ContentsInfoListEnableStatusSlot1/2` permission flags name a usable slot.
   * `EnumSlot.SLOT1` = 1; Sony never sends 0 as a slot. */
  static readonly DEFAULT_SLOT_NUMBER = 1;
  /** Parameter [4]: Sony passes true on the normal browse path. */
  static readonly ORDER_FLAG = 1;

  /** A page of 100 is normal; anything past this is a corrupt header. */
  static readonly MAX_ENTRIES_PER_PAGE = 1000;
  /** Guard for the shot-mark and file sub-lists. */
  static readonly MAX_COLLECTION_ITEMS = 4096;
  /** Guard for the variable-length file path. */
  static readonly MAX_FILE_PATH_BYTES = 4096;
  /** Hard stop on the page loop inside one captured date. */
  static readonly MAX_PAGES = 64;
  /** Hard stop on the total number of page requests, across every captured
   * date, so a camera that keeps answering cannot spin forever. */
  static readonly MAX_TOTAL_PAGES = 1024;

  static readonly RESPONSE_OK = 0x2001;
  /** The standard `GetDevicePropValue` operation. NOT used for the live view URL
   * - that comes out of the accumulated 0x9209 map (see `readLiveViewUrl`), and
   * a targeted read of a vendor property is not part of Sony's protocol. */
  static readonly OP_GET_DEVICE_PROP_VALUE = 0x1015;
  /** `EnumDevicePropCode.LiveViewUrl` = 53880 = 0xD278
   * (`base/transaction/EnumDevicePropCode.java:109`
   * `LiveViewUrl(53880, "LiveView URL")`), a STRING. `PtpIpCamera.java:705-711`
   * keeps it as `mLiveviewUrl` and that is the URL the live-view HTTP stream is
   * opened against. */
  static readonly PROP_LIVE_VIEW_URL = 53880;
  /** `EnumDevicePropCode.RemoteTouchOperationEnableStatus` = 53892
   * (`base/transaction/EnumDevicePropCode.java:113`).
   *
   * Touch AF needs BOTH halves of Sony's `isEnable` test — the `mIsEnable` octet
   * being True(1)/DispOnly(2) (`canGet`) AND
   * `EnumOperationEnableStatus.valueOf(mCurrentValue) == Enable`, an ordinal the
   * local utility derives from `mCurrentValue & 0xFF == 1`
   * (`.../liveview/TouchOperationController.java:436-443`,
   * `EnumOperationEnableStatus$EnumUnboxingLocalUtility.java:32-43`). It is
   * checked before anything at all is sent (`:139`). */
  static readonly PROP_REMOTE_TOUCH_ENABLE_STATUS = 53892;
  /** `EnumDevicePropCode.FunctionOfTouchOperation` = 53891
   * (`base/transaction/EnumDevicePropCode.java:112`) — the second gate: the
   * camera must say what a touch MEANS (touch focus / tracking / AE) and it must
   * not be OFF (`TouchOperationController.java:141-152`). */
  static readonly PROP_FUNCTION_OF_TOUCH_OPERATION = 53891;
  /** `EnumFunctionOfTouchOperation.OFF`, the one value that forbids the touch
   * (`TouchOperationController.java:152`). */
  static readonly FUNCTION_OF_TOUCH_OPERATION_OFF = 1;
  /** `EnumOperationEnableStatus`: Disable(0) / Enable(1), read as
   * `mCurrentValue & 0xFF` — the width the local utility unboxes at
   * (`EnumOperationEnableStatus$EnumUnboxingLocalUtility.java:32-43`). */
  static readonly ENABLE_STATUS_MASK = 255;
  static readonly ENABLE_STATUS_ENABLE = 1;
  /** `EnumDevicePropCode.CancelRemoteTouchOperationEnableStatus` = 53893
   * (`base/transaction/EnumDevicePropCode.java:114`), the gate on the separate
   * cancel button (`TouchOperationController.java:361`, `:363`). */
  static readonly PROP_CANCEL_REMOTE_TOUCH_ENABLE_STATUS = 53893;
  /** The DD document element `DeviceDescription.parse` reads into
   * `mLiveviewUrl` (`common/device/DeviceDescription.java:91-94`) - the
   * fallback source for the live-view URL when property 0xD278 answers
   * nothing. */
  static readonly DD_LIVE_VIEW_URL_TAG = 'X_ScalarWebAPI_LiveView_URL';

  // --- Session mode / device-description documents (steps (S1b)(S1c)(S2)) ---
  /** Session id of `SDIO_OpenSession`: `new int[]{1, functionMode.value}`
   * (`initialization/Initializer.java:95`) — literal 1, as in `OpenSession`'s
   * `new int[]{1}` (`Initializer.java:87`). */
  static readonly SESSION_ID = 1;
  /** `EnumFunctionMode.CONTENTS_TRANSFER_MODE` = 1 and
   * `REMOTE_CONTROL_WITH_TRANSFER_MODE` = 2 (`EnumFunctionMode` static
   * initialiser: `REMOTE_CONTROL_MODE("...",0,0)`, `CONTENTS_TRANSFER_MODE(1)`,
   * `REMOTE_CONTROL_WITH_TRANSFER_MODE(2)`, `UNDEFINED(-1)`). The captured-date
   * browse exists only in the second one — see the file header. */
  static readonly FUNCTION_MODE_CONTENTS_TRANSFER = 1;
  static readonly FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER = 2;
  /** Parameter [0] of `SDIO_GetDeviceDescriptionFile`: DD document (1) or DID
   * document (2). `Initializer.java:161` and
   * `SDIO_GetDeviceDescriptionFileState2.java:20` pass the literals 1 and 2. */
  static readonly DEVICE_DESCRIPTION_FILE_DD = 1;
  static readonly DEVICE_DESCRIPTION_FILE_DID = 2;
  /** Fresh connections each Sony session acquire may use. A body that has not
   * released the previous connection answers the new session open with
   * `SessionAlreadyOpen` (0x201E), and the only cure is to let it go and dial
   * again; the transport waits out the release window between attempts. Applied
   * to the standard acquire as well, because the camera still holding a session
   * refuses that one too. */
  static readonly SESSION_OPEN_ATTEMPTS = 3;
  /** The DID document element that `DeviceInfo.parse` stores as
   * `mServerVersion` (`common/device/did/DeviceInfo.java:125-130`), which
   * `Initializer.adjustFunctionMode` (`:58-77`) and
   * `DeviceInfo.isRemoteControlWithTransferModeSupported` (`:48-56`) compare
   * against 4.0. */
  static readonly DID_SERVER_VERSION_TAG = 'X_ServerVersion';
  static readonly DID_SERVER_VERSION_FOR_REMOTE_CONTROL_WITH_TRANSFER = 4.0;
  /** `EnumIsEnable.True`(1) / `DispOnly`(2): the two values `isEnable$2`
   * accepts before it looks at the current value
   * (`property/dataset/EnumIsEnable.java:7-10`, `PtpContentsRoot.java:431-440`). */
  static readonly IS_ENABLE_TRUE = 1;
  static readonly IS_ENABLE_DISP_ONLY = 2;
  /** `EnumGetSet.GetSet` (`base/transaction/EnumGetSet.java:7-10` is
   * `Get(0), GetSet(1), Undefined(2)`): the second half of Sony's `canSet`
   * (`AbstractController.java:90-93`). A property the camera marks `Get` is
   * readable and NOT writable, whatever its `isEnable` says. */
  static readonly ENUM_GET_SET = 1;

  /**
   * The still-image parameters the control page drives, with Sony's own codes
   * (`base/transaction/EnumDevicePropCode.java`).
   *
   * Note that these are NOT the codes of the other brands in this project, and
   * that two tempting look-alikes must be avoided: `ExposureCompensation`
   * (53796) and `ISOSensitivityAbsoluteValue` (53798) exist in the enum but have
   * no decoder and no caller — remote control uses `ExposureBiasCompensation`
   * (20496) and `ISOSensitivity` (53790).
   */
  /** `FNumber(20487)` — the aperture. Raw value is the f-number x 100. */
  static readonly PROP_F_NUMBER = 20487;
  /** `ShutterSpeed(53773)` — raw is `(numerator << 16) | denominator`, and 0 is
   * BULB (`ptpip/property/value/EnumShutterSpeed.java:23-40`). */
  static readonly PROP_SHUTTER_SPEED = 53773;
  /** `ExtendedShutterSpeed(53663)` — the same encoding, used instead of
   * `ShutterSpeed` on bodies that expose long exposures (`canSet` decides). */
  static readonly PROP_EXTENDED_SHUTTER_SPEED = 53663;
  /** `ISOSensitivity(53790)` — raw is the ISO number itself, and 0xFFFFFF means
   * AUTO (`ptpip/property/value/EnumISOSensitivity.java:283-286`). */
  static readonly PROP_ISO_SENSITIVITY = 53790;
  /** `ExposureBiasCompensation(20496)` — raw is EV x 1000 as a signed 16-bit
   * value (`ptpip/property/value/EnumExposureBiasCompensation.java:16-30`). */
  static readonly PROP_EXPOSURE_BIAS_COMPENSATION = 20496;
  /** `ExposureProgramMode(20494)` — the shooting mode (M/P/A/S and scene modes). */
  static readonly PROP_EXPOSURE_PROGRAM_MODE = 20494;
  /** `WhiteBalance(20485)` — masked to 16 bits before compare and write
   * (`WhiteBalanceSettingController.java:80`, `:269`). */
  static readonly PROP_WHITE_BALANCE = 20485;
  /** `FocusMode(20490)`. */
  static readonly PROP_FOCUS_MODE = 20490;
  /** `StillCaptureMode(20499)` — the drive mode. */
  static readonly PROP_STILL_CAPTURE_MODE = 20499;
  /**
   * `MovieRecordingState(53789)` = `0xD21D` — whether the body is recording.
   *
   * Masked to 8 bits, the values are `0` Not Recording, `1` Recording,
   * `2` Recording Failed, `3` Waiting Record, `255` Undefined
   * (`ptpip/property/value/EnumMovieRecordingState$EnumUnboxingLocalUtility.java:19-55`;
   * that file's `getMString`/`getMValue` are the authoritative value↔name pair).
   *
   * Only `1` means "actually rolling" — the others are all "not rolling", so a
   * caller should test `=== 1` rather than "non-zero".
   */
  static readonly PROP_MOVIE_RECORDING_STATE = 53789;
  /** `EnumMovieRecordingState` value that means the body is recording. */
  static readonly MOVIE_RECORDING_STATE_RECORDING = 1;
  /** `CompressionSetting(20484)` — the classic PTP compression code. Sony's app
   * never reads or writes it, and the ILCE-7M4 does not report it, so it is
   * deliberately NOT used for the 画质 panel; see `PROP_JPEG_QUALITY`. */
  static readonly PROP_COMPRESSION_SETTING = 20484;
  /** `JPEGQuality(53842)` = 0xD252 — the still-image quality property Sony's own
   * app reads and writes (`EnumCameraProperty.java:1446-1447` read,
   * `:1642-1661` write). On an ILCE-7M4 the body declares it `ro`, so the 画质
   * panel has to be able to fall back; see `SonyPtpIpControl.qualityCodeOf`. */
  static readonly PROP_JPEG_QUALITY = 53842;
  /** `CompressionFileFormat(53895)` = 0xD287 — still-record file format
   * (`EnumCompressionFileFormat`: JPEG / HEIF(4:2:2) / HEIF(4:2:0)). One of the
   * two still-image properties Sony's app reads AND writes
   * (`EnumCameraProperty.java:1440`). */
  static readonly PROP_COMPRESSION_FILE_FORMAT = 53895;
  /** `RawFileType(53896)` = 0xD288 — RAW compression flavour
   * (`EnumRawFileType`: Compression / LossLess L,M,S / UnCompression / LossLess /
   * CompressedHQ). The other one Sony's app reads and writes
   * (`EnumCameraProperty.java:1444`). */
  static readonly PROP_RAW_FILE_TYPE = 53896;
  /** `AspectRatio(53777)` — the Panasonic "比例" panel's counterpart. */
  static readonly PROP_ASPECT_RATIO = 53777;
  /** `RemoteControlRestrictionStatus(53860)`: raw 0 means "no restriction" and
   * raw 1 makes Sony dismiss every setting dialog
   * (`ptp/remotecontrol/controller/setting/AbstractSettingDialogController.java:70-84`).
   * Honoured before a set so a refused 0x9205 is not sent blind. */
  static readonly PROP_REMOTE_CONTROL_RESTRICTION_STATUS = 53860;
  /** `RemoteControlRestrictionStatus` raw value meaning "not restricted". */
  static readonly RESTRICTION_STATUS_UNRESTRICTED = 0;
  /** `EnumOperationCode.SDIO_SetExtDevicePropValue(37381)` = 0x9205 — the ONLY
   * way Sony sets a vendor property. There is no `0x1016 SetDevicePropValue` in
   * its enum at all (`base/packet/EnumOperationCode.java:25`). */
  static readonly OP_SDIO_SET_EXT_DEVICE_PROP_VALUE = 0x9205;
  /** `EnumOperationEnableStatus$EnumUnboxingLocalUtility._valueOf` masks the
   * current value with 0xFF and compares it to `getMValue(Enable)` = 1, so
   * `isEnable$2` is `(value & 0xFF) === 1`, not `value === 1`. */
  static readonly OPERATION_ENABLE_STATUS_MASK = 0xFF;
  /** `EnumContentsTransferEnableStatus.Companion.valueOf` masks with 0xFFFF
   * (`EnumContentsTransferEnableStatus.java:32-40`), ENABLE = 1 (`:24`). */
  static readonly CONTENTS_TRANSFER_ENABLE_STATUS_MASK = 0xFFFF;

  /** `EnumContentType`: UNSPECIFIED(0), DCF(1), M4STYLE(4), XDSTYLE(8), PXSTYLE(16).
   * Any other value maps to UNSPECIFIED, which aborts the list. */
  private static readonly KNOWN_CONTENT_TYPES: number[] = [1, 4, 8, 16];
  /** `EnumContentFileFormat`: RAW(45313) and HEIF(45328) are the non-JPEG stills. */
  private static readonly FORMAT_RAW = 45313;
  private static readonly FORMAT_HEIF = 45328;

  // --- Contents data phase: original download and thumbnail ----------------
  //
  // Every constant below is quoted from Sony's own client; nothing here is a
  // PTP-spec guess.
  //
  // OPCODES (`base/packet/EnumOperationCode.java`, decimal -> hex):
  //   :51  SDIO_GetContentsData(37437)           = 0x923D   original bytes
  //   :52  SDIO_GetContentsCompressedData(37438) = 0x923E   thumbnail bytes
  //   :35  SDIO_GetPartialLargeObject(37393)     = 0x9211   NOT used here, see
  //        below.
  //
  // ORIGINAL — `contentstransfer/ContentsDataGetter.java:379-390`
  // (`sendGetContentsData`), one request per chunk:
  //
  //   int i = j3 > 3145728 ? 3145728 : (int) j3;              // :384  j3 = fileSize - downloadedSize
  //   new SDIO_GetContentsData(NoDataOrDataInPhase, SDIO_GetContentsData,
  //     new int[]{ (int) j4,                                   // :388  contentId low 32
  //                (isResponseFileSize ? 65536 : 0) | ((int) (j4 >>> 32)),  // contentId high 32, flag in bit 16
  //                (int) j2, (int) (j2 >>> 32),              // offset low, offset high
  //                i & Integer.MAX_VALUE },                  // length, high bit masked off
  //     null, callback);
  //
  // So an original is read as repeated 0x923D requests of at most 3 MiB, each
  // carrying the absolute byte offset. `SDIO_GetPartialLargeObject` (0x9211) is
  // NOT part of this path: it is the MTP object-handle reader,
  // `ptpip/mtp/ObjectGetter.java:158-159` sends `{objectHandle, offsetLo,
  // offsetHigh, 3145728}` and is only reached from
  // `BasePtpManager.getMtpObject` (BasePtpManager.java:1145-1158) — standard
  // PTP object handles, which the ILCE-7M4 refuses for contents. The 3 MiB cap
  // is the same number in both paths (`ObjectGetter.java:159`).
  //
  // `isResponseFileSize` is a device capability, not a caller choice:
  // `BasePtpManager.java:1304-1308` reads device property
  // `GetContentDataCommandVersion` = 57622
  // (`base/transaction/EnumDevicePropCode.java:152`, decimal 57622 = 0xE116) and
  // returns true when it is enabled and its value is >= 101. When true, bit 16
  // of parameter [1] asks the camera to echo the content's current size in
  // response parameters [2],[3]; `ContentsDataGetter.java:197-211` uses
  // parameters [0],[1] as an update-check timestamp and [2],[3] as the size to
  // detect a content that changed mid-download. This port sends the flag
  // faithfully (so the wire form matches Sony) and logs the echoed values, but
  // does not abort on them: a false mismatch must not lose a good download.
  //
  // THUMBNAIL — `BasePtpManager.java:1041-1051`
  // (`getContentsCompressedData`), ONE request, no offset, no chunking:
  //
  //   new SDIO_GetContentsCompressedData(NoDataOrDataInPhase,
  //     SDIO_GetContentsCompressedData,
  //     new int[]{ (int) j, (int) (j >>> 32), enumContentsCompressedDataType.value },
  //     null, callback);                                       // :1051
  //
  // The selector is `EnumContentsCompressedDataType`
  // (`contentstransfer/data/EnumContentsCompressedDataType.java:21-22`):
  // THUMBNAIL(1) / SCREENNAIL(2). The gallery grid asks for THUMBNAIL:
  // `transfer/AbstractCameraItem.java:150` `getContentsBrowser().getThumb(...)`
  // -> `transfer/ptp/PtpContentsBrowser.java:317-319` -> `GetThumbnail` ->
  // `transfer/task/GetThumbnail.java:44`
  // `getContentsCompressedData(this.uniqueId, EnumContentsCompressedDataType.THUMBNAIL, this)`.
  // (SCREENNAIL is the detail view: `GetScreennail.java:37`.)
  //
  // Returned bytes are a complete image file, not a raw bitmap: Sony decodes
  // them with `BitmapFactory.decodeByteArray(bArr, 0, bArr.length)` and reads
  // EXIF out of the same buffer
  // (`transfer/AbstractCameraItem$getThumbnail$2$onImageBinaryAcquired$1.java:61-62`),
  // which is a JPEG for stills.
  //
  // THE u64 CONTENT ID IS NOT THE BARE contentId. `transfer/ptp/PtpPullItem.java:392-393`:
  //
  //   (((long)(((slotId & 255) << 24) + (contentFile.fileId & 65535))) << 32)
  //     + ((long) this.contentInfo.contentId & 4294967295L)
  //
  // low 32 = ContentInfo.contentId, high 32 = (slotId << 24) | ContentFile.fileId.
  // `slotId` is the slot number passed as parameter [3] to 0x923C and echoed back
  // by the camera (`PtpItemList.java:169` passes `this.slotNumber`; the
  // `onSuccess(long, byte, ...)` at `PtpItemList.java:141,190` feeds that same
  // byte into `PtpPullItem`), and `fileId` is the ContentFile's own u16. Sending
  // only the contentId with a zero high half addresses slot 0 / file 0, i.e. no
  // file at all.
  //
  // Response parameters of 0x923D (`ContentsDataGetter.java:197-211`): [0],[1] =
  // content update-check timestamp u64; [2],[3] = current size u64 (only when the
  // flag above was sent). 0x923E answers with no parameters of interest — the
  // whole image is the data phase (`ContentsCompressedDataGetter.java:84-92`).
  static readonly OP_GET_CONTENTS_DATA = 0x923D;
  static readonly OP_GET_CONTENTS_COMPRESSED_DATA = 0x923E;
  static readonly COMPRESSED_DATA_TYPE_THUMBNAIL = 1;
  static readonly COMPRESSED_DATA_TYPE_SCREENNAIL = 2;
  /** `ContentsDataGetter.java:384` — 3145728 = 3 MiB, the per-request cap. */
  static readonly CONTENTS_DATA_CHUNK_BYTES = 3145728;
  /** `ContentsDataGetter.java:388` `i & Integer.MAX_VALUE`. */
  static readonly CONTENTS_DATA_LENGTH_MASK = 0x7FFFFFFF;
  /** `ContentsDataGetter.java:388` `isResponseFileSize ? 65536 : 0`. */
  static readonly CONTENTS_DATA_RESPONSE_FILE_SIZE_FLAG = 65536;
  /** `EnumDevicePropCode.GetContentDataCommandVersion` (57622 = 0xE116)
   * (`base/transaction/EnumDevicePropCode.java:152`). */
  static readonly PROP_GET_CONTENTS_DATA_COMMAND_VERSION = 57622;
  /** `BasePtpManager.java:1307` — the version at which the flag becomes valid. */
  static readonly GET_CONTENTS_DATA_COMMAND_VERSION_MIN = 101;
  /** `PtpPullItem.java:393` `(contentFile.fileId & 65535)`. */
  static readonly UNIQUE_ID_FILE_ID_MASK = 0xFFFF;
  /** `PtpPullItem.java:393` `(this.slotId & 255) << 24`. */
  static readonly UNIQUE_ID_SLOT_MASK = 0xFF;
  static readonly UNIQUE_ID_SLOT_SHIFT = 24;
  /** A thumbnail that is larger than this is not an image; refuse it rather
   * than write a bogus file. Sony imposes no limit of its own. */
  static readonly THUMBNAIL_MAX_BYTES = 4 * 1024 * 1024;

  // --- Contents-data addressing, kept for the transfer page ----------------
  /**
   * Every enumerated file this session handed to the gallery, keyed by
   * `contentId|fileName`, so a later download or thumbnail request can rebuild
   * Sony's u64 unique id. `next()` consumes `buffer`, so the queue cannot be
   * used as the lookup: an entry already displayed in the gallery is gone from
   * it. Populated in `readPage` (every page, including pages the day walk later
   * rejects — harmless) and cleared with the rest of the attempt state.
   */
  private static served: Map<string, SonyServedFile> = new Map<string, SonyServedFile>();

  // --- Contents-data telemetry (appended to the existing sony logs) --------
  private static thumbRequests: number = 0;
  private static thumbOk: number = 0;
  private static thumbBytes: number = 0;
  private static thumbLastCode: number = -2;
  private static thumbLastBytes: number = 0;
  private static thumbLastId: string = '-';
  private static downloadChunks: number = 0;
  private static downloadBytes: number = 0;
  private static downloadLastCode: number = -2;
  private static downloadLastParams: string = '-';
  private static contentsDataFlag: number = -1;

  // --- Stateful browse session used by the image-transfer page ------------
  private static session: PtpTransport | null = null;
  /**
   * 外部注入的传输层（当前用于 USB）。非 null 时 `open()` 不再自己建 TCP 会话，
   * 而是直接用这个已建立好的会话跑索尼的六步 setup。
   *
   * 对应官方的做法：`Initializer` 只依赖 `ITransactionExecutor`，
   * `PtpIpManager` 与 `PtpUsbManager` 把各自的 executor 交给同一个
   * `Initializer`。所以协议层不该知道自己是 TCP 还是 USB。
   */
  private static pendingTransport: PtpTransport | null = null;
  /**
   * USB 会话是否已由 `openViaTransport()` 建立完毕。
   *
   * 一旦为真，后续 `open(host)` 直接返回成功，不再去建 TCP 会话：USB 没有
   * 「按 host 重连」这回事，重复 open 只会把已经跑完的六步 setup 再跑一遍。
   */
  private static usbSessionActive: boolean = false;
  /** USB 会话只建了控制通道（六步 setup），没进内容枚举模式。 */
  private static controlOnlySession: boolean = false;
  private static buffer: SonyContentEntry[] = [];
  private static discovered: number = 0;
  private static cursor: SonyU64 = { low: 0, high: 0 };
  private static exhausted: boolean = true;
  private static modeCode: number = 0;
  /** Slot the camera reported as usable, as sent in parameter [3]. */
  private static slotNumber: number = SonyPtpIpContent.DEFAULT_SLOT_NUMBER;
  /** `SDIO_GetCapturedDateList` answer in SONY'S CONTAINER ORDER — ascending
   * sort then reverse, i.e. MOST RECENT FIRST (`PtpContentsRoot.java:127-130`).
   * Each entry starts one day of content; Sony builds one `PtpPullContainer` per
   * entry, and the gallery opens container[0] first, so index 0 is the captured
   * date whose first page is requested first. */
  private static dayDates: SonyU64[] = [];
  /** Index into `dayDates`; `-1` means no day has been positioned yet. */
  private static dayIndex: number = -1;
  /** Upper bound of the current day: the captured date already walked — the NEXT
   * NEWER one, at `dayIndex - 1` — or null on the most recent day, which has
   * none. Content at or past it was already collected by that newer day's walk
   * and is dropped here, exactly as `PtpItemList` drops a content whose date
   * stopped matching the container's (`transfer/ptp/PtpItemList.java:183-186`). */
  private static dayStopUpper: SonyU64 | null = null;
  /** Page requests spent on the current day / in total, as spin guards. */
  private static dayPages: number = 0;
  private static totalPages: number = 0;
  /** True when a page request failed outright (as opposed to the list ending). */
  private static pageFailure: boolean = false;
  /** Last `SDIO_GetContentsInfoList` outcome, kept for the failure message. */
  private static lastPageCode: number = -1;
  private static lastPageBytes: number = 0;
  /** Last `SDIO_GetCapturedDateList` response code, kept for diagnostics.
   * `-2` = not attempted, `-1` = no response. */
  private static lastDateCode: number = -2;
  /** The same answer's response-parameter list and payload size, so a refusal
   * that carries parameters is distinguishable from one that does not. */
  private static lastDateParams: string = '-';
  private static lastDateBytes: number = 0;
  /** Declared count of the last 0x923B answer, `-1` when it had no payload. */
  private static lastDateCount: number = -1;
  /** Which slot was asked first, and which slot answered (when the second slot
   * had to be tried). `-1` = never asked. */
  private static lastDateSlot: number = -1;
  private static lastDateSlotAnswered: number = -1;
  /** Raw `ContentsInfoListEnableStatusSlot1/2` values (`-1` = absent) with the
   * property's own `isEnable` octet, plus the slot decision in words. */
  private static slot1Value: number = -1;
  private static slot2Value: number = -1;
  private static slot1EnableFlag: number = -1;
  private static slot2EnableFlag: number = -1;
  private static slotReason: string = '-';
  /** Every `SDIO_GetCapturedDateList` (0x923B) attempt of this browse as
   * `slot#attempt:code`, in the order they were sent. The single-shot
   * `lastDateCode`/`lastDateParams`/`lastDateBytes`/`lastDateCount` fields keep
   * describing the first, decisive request; this field is what makes the
   * slot-and-retry sweep readable in one glance. `-` while none was sent. */
  private static dateTries: string = '-';
  /** Which `SDIO_SetContentsTransferMode` (0x9212) form this browse used —
   * `0x9212:[2,1,0]` or `skipped` (divergence (a), see
   * `SKIP_SET_CONTENTS_TRANSFER_MODE_ON_RCT`). `-` = a browse that never got
   * that far. */
  private static setTransferMode: string = '-';
  /** Parameter list of the INITIAL `SDIO_GetAllExtDevicePropInfo` of this
   * attempt (`[0, flag]`), kept beside `propDumpParams`, which is what the
   * enable-refresh polls send (`[1, flag]`). Both are on the browse line so the
   * normalisation is visible rather than implied. */
  private static initialPropDumpParams: string = '-';
  /** The second `GetDeviceInfo` (0x1001) of the session — divergence (c),
   * `DeviceInfoUpdater.execute$2` (`BasePtpManager.java:377-380`). `-2` = not
   * attempted, `-1` = issued with no response. `deviceInfo2FunctionalMode` is
   * the camera's own `functionalMode` read AFTER the session was established,
   * which is the one evidence of the mode that does not come from the
   * operation that opened the session. `-1` = dataset absent or unparsed. */
  private static deviceInfo2Code: number = -2;
  private static deviceInfo2Bytes: number = 0;
  private static deviceInfo2FunctionalMode: number = -1;
  /** `isEnable` octet per device property, accumulated across every dump of the
   * attempt (`DevicePropInfoDataset.mIsEnable`); `pickSlotNumber` needs it
   * because Sony's `isEnable$2` checks it as well as the value. Sony keeps the
   * same data in one accumulated dataset (`DevicePropertyUpdater.java:45-66`),
   * so a later delta dump must not drop the flag an earlier full dump carried. */
  private static propEnableFlags: Map<number, number> = new Map<number, number>();
  /** Decoded current value per device property, accumulated across every dump of
   * the attempt exactly as Sony accumulates its answers
   * (`DevicePropertyUpdater.onDevicePropertyAcquired`, `:58-66`). The 0x9209
   * polls this module issues use Sony's refresh parameter form, so any poll after
   * the first may carry only the properties that changed; the slot properties
   * and `ContentsTransferEnableStatus` must survive that. */
  private static propValues: Map<number, number> = new Map<number, number>();
  /** Decoded string per STR device property, accumulated across every dump of
   * the attempt on the same rule as `propValues`: Sony's map holds the string
   * beside the number and a later delta must not drop it. This is the source of
   * `LiveViewUrl` (`PtpIpCamera.java:705` reads `mCurrentStringValue` from the
   * accumulated `mAllDevicePropInfoDatasets`), so no separate request is needed
   * — and none is sent, because a targeted `GetDevicePropValue` for a vendor
   * STR property is not something Sony's client ever issues. */
  private static propStrings: Map<number, string> = new Map<number, string>();
  /** Ordered selectable values (`mGetSetValues`) per property, accumulated on the
   * same rule as `propValues`. This is what a parameter panel must offer, and it
   * arrives inside the 0x9209 payload we already request — no extra round trip. */
  private static propOptions: Map<number, number[]> = new Map<number, number[]>();
  /** `mGetSet` octet per property, accumulated on the same rule. Together with
   * `propEnableFlags` this answers Sony's writability test. */
  private static propGetSet: Map<number, number> = new Map<number, number>();
  /** `mDataType` per property, accumulated on the same rule: the width a 0x9205
   * set must use for that property on this body. */
  private static propDataTypes: Map<number, number> = new Map<number, number>();
  /** How the LARGEST `SDIO_GetAllExtDevicePropInfo` payload of this attempt
   * walked, and whether the 53716 / 53717 records were in it at all. The largest
   * payload is the only one that can span the property list the camera declared
   * in 0x9202 (`extPropCount`), so it — not the most recent delta — is what the
   * browse line reports. Only a `clean` walk makes an absent slot property
   * genuinely absent — see `SonyPropWalk`. */
  private static propWalk: SonyPropWalk | null = null;
  /** How the MOST RECENT `SDIO_GetAllExtDevicePropInfo` payload walked, whatever
   * its size. Kept beside the reported walk so a delta dump stays visible and can
   * never be confused with the full one. */
  private static propLastWalk: SonyPropWalk | null = null;
  /** How many 0x9209 payloads were walked in this attempt. */
  private static propDumps: number = 0;
  /** `ContentsTransferEnableStatus` wait statistics, so a real-device failure
   * says whether the property was absent, unreadable, or merely not ENABLE. */
  private static enablePolls: number = 0;
  private static enableDumpFailures: number = 0;
  private static enableLastValue: number = -1;
  /** Why `SDIO_SetContentsTransferMode` produced no code: `'none'` on its own is
   * undiagnosable, so the exception text and whether a response code was ever
   * obtained are kept. A missing `ptpip request op=0x9212` line in the same log
   * means the operation never reached the wire. */
  private static lastModeError: string = '';
  private static lastModeAnswered: boolean = false;
  /** Diagnostics of the first `SDIO_GetContentsInfoList` request of an attempt:
   * this one is decisive, because a camera that leaves contents-transfer mode
   * after a bad follow-up fails here rather than mid-browse. */
  private static firstPageRequested: boolean = false;
  private static firstPageCode: number = -1;
  private static firstPageBytes: number = 0;
  private static firstPageDeclared: number = 0;
  private static firstPageParsed: number = 0;
  private static firstPageStop: string = 'none';
  private static firstPageCreateTime: SonyU64 = { low: 0, high: 0 };
  /** Browse attempts in this process, so consecutive tries in one hilog run are
   * tellable apart. */
  private static browseAttempts: number = 0;
  /** `SDIO_GetVendorCodeVersion` answer, or -1 when unknown/unavailable. Read
   * once per SESSION by step (S5) of `setupSonySession`, because it decides the
   * property dump's parameter list for the whole session. */
  private static vendorCodeVersion: number = -1;
  private static vendorCodeVersionFetched: boolean = false;

  // --- Sony session-setup telemetry (step (S) of the file header) ---------
  /** The session the vendor setup has already been attempted on. Compared by
   * identity so the setup runs once per session rather than once per page. */
  private static setupSession: PtpTransport | null = null;
  private static setupDone: boolean = false;
  private static setupOk: boolean = false;
  /** How many of the six setup steps were actually put on the wire. */
  private static setupSteps: number = 0;
  /** First refused/undelivered step, kept as text plus its opcode and response
   * code so the browse line names the step instead of collapsing everything
   * into one generic failure. `none` while nothing has failed. */
  private static setupFailedStep: string = 'none';
  private static setupFailedOpcode: number = -1;
  private static setupFailedCode: number = -1;
  /** `GetDeviceInfo` (0x1001) response size, step (S1). */
  private static deviceInfoBytes: number = 0;
  /** `SDIO_GetExtDeviceInfo` response size, and a short decoded summary of the
   * dataset, so a device run proves 0x9202 really answered rather than merely
   * not-erroring. */
  private static extDeviceInfoBytes: number = 0;
  private static extDeviceInfoSummary: string = '-';
  /**
   * Membership of the three contents-transfer properties in the CAMERA'S OWN
   * `SDIExtDeviceInfoDataset.mDevicePropCodes` list, taken from the `0x9202`
   * payload (`initialization/Initializer.java:241-254`:
   * `u16 extensionVersion`, `u32 count`, `count x u16 devicePropCodes`,
   * `u32 count`, `count x u16 controlCodes`).
   *
   * This is the decisive check for the missing 53716/53717, and it is Sony's own
   * precondition: `PtpContentsRoot.isEnable$2` returns false unless
   * `DevicePropertyOperation.isSupported(code)` — which is exactly
   * `mDeviceInfoDataset.contains(code)`, i.e. this list
   * (`ptpip/remotecontrol/operation/DevicePropertyOperation.java:58-61`,
   * `initialization/SDIExtDeviceInfoDataset.java:50-52`) — and then
   * `PtpContentsRoot.java:431-440`. So a code absent from this list is a
   * property the camera never offered, and Sony reports DeviceBusy for it
   * without ever sending `SDIO_GetCapturedDateList`.
   *
   * `-1` = the list never arrived, `1` = listed, `0` = not listed.
   */
  private static extPropCount: number = -1;
  private static extPropHasEnableStatus: number = -1;
  private static extPropHasSlot1: number = -1;
  private static extPropHasSlot2: number = -1;
  /** Membership of the MEDIA properties in the camera's own 0x9202 list, read
   * exactly like the three above. `MediaSLOT1Status`/`MediaSLOT2Status`/
   * `PlaybackMedia` are what the slot decision actually turns on, so whether the
   * camera offered them at all has to be as visible as the permission flags'
   * membership: a status absent from the dump is unreadable if it was never
   * offered, and merely missed if it was. */
  private static extPropHasMediaSlot1: number = -1;
  private static extPropHasMediaSlot2: number = -1;
  private static extPropHasPlaybackMedia: number = -1;
  /** Parameters the last `SDIO_GetAllExtDevicePropInfo` was sent with. */
  private static propDumpParams: string = '-';
  /** Post-setup probe outcome: the explicit 0x9216 retry and 0x9209 attempt
   * that run once per browse so a single device run shows whether the setup
   * fixed them. */
  private static probeVersionCode: number = -2;
  private static probeDumpCode: number = -2;
  private static probeDumpBytes: number = 0;
  private static probeDumpFallbackCode: number = -2;
  private static probeDumpFallbackBytes: number = 0;

  // --- Session-mode telemetry (steps (S1b)(S1c)(S2)) ----------------------
  /** The session-open operation the PTP/IP handshake should use: -1 = the
   * standard `OpenSession` (0x1002) `[1]`, otherwise the vendor opcode (Sony's
   * `SDIO_OpenSession` 0x9210 `[1, 2]`). Sony's own client uses the vendor one
   * whenever the DID server version is >= 4.0 and the standard one otherwise
   * (`Initializer.java:83-96`), so this is a decision about the connection, not
   * about one request. It is deliberately NOT cleared by `resetBuffer`: it is
   * remembered for the whole run, and a vendor open the body refuses falls back
   * to the standard one inside the transport. */
  private static sessionOpenOpcode: number = -1;
  /** Set when a session that WAS opened with `SDIO_OpenSession` (0x9210) could
   * not even run the six setup steps. That makes mode 2 unusable on this body for
   * this run, so the browse goes back to the standard open — which at least
   * yields the property/slot telemetry — instead of paying the vendor open's
   * retry cost on every attempt. Reset only by restarting the app. */
  private static vendorSetupFailed: boolean = false;
  /** What the transport actually used for the current session (0x1002 or
   * 0x9210), for the browse line. */
  private static sessionOpenObserved: number = -1;
  /** `SDIO_OpenSession` outcome on the current session. `-2` = not attempted,
   * `-1` = no response. When the transport opened the session with 0x9210, this
   * is that handshake's own response code. */
  private static openSessionCode: number = -2;
  /** The function mode the session was asked for
   * (`EnumFunctionMode.REMOTE_CONTROL_WITH_TRANSFER_MODE` = 2), or -1 when the
   * step was never issued. */
  private static openSessionMode: number = -1;
  private static ddXmlCode: number = -2;
  private static ddXmlBytes: number = 0;
  private static didXmlCode: number = -2;
  private static didXmlBytes: number = 0;
  /** `<X_ServerVersion>` out of the DID document, or `''` when the document
   * never arrived or holds no such element. This is the value
   * `Initializer.adjustFunctionMode` turns into the function mode. */
  private static didServerVersion: string = '';
  /** Operations the camera advertises in its `GetDeviceInfo` dataset
   * (`DeviceInfoDataset.operationsSupported`), so a run says outright whether
   * 0x923A / 0x923B / 0x923C are on the body's own list. */
  private static deviceInfoOps: number = -1;
  /** `functionalMode` out of the `GetDeviceInfo` dataset (S1), read AFTER the
   * session open, so it is the camera's own report of the mode it is in. Kept as
   * corroborating evidence for `mode2`: the mode-2 verdict itself comes from the
   * operation that established the session, never from this field, whose meaning
   * for a Sony body is not documented in the decompiled client. `-1` = the
   * dataset never arrived or did not parse. */
  private static deviceInfoFunctionalMode: number = -1;
  private static deviceInfoHasDdFile: boolean = false;
  private static deviceInfoHasCapturedDateList: boolean = false;
  private static deviceInfoHasContentsInfoList: boolean = false;
  private static deviceInfoModel: string = '-';

  // --- Sony's own session setup (step (S) of the file header) -------------

  /**
   * Runs Sony's vendor session establishment on top of the already-open
   * standard session: (S1) `GetDeviceInfo`, (S1b)/(S1c) the DD and DID device
   * description documents, (S2) `SDIO_OpenSession` for
   * `REMOTE_CONTROL_WITH_TRANSFER_MODE`, (S3)/(S4) `SDIO_Connect` phase 1 and
   * 2, (S5) `SDIO_GetVendorCodeVersion`, (S6) `SDIO_GetExtDeviceInfo`,
   * (S7) `SDIO_Connect` phase 3. The transport's handshake already opened a
   * session with the standard `OpenSession` (0x1002); Sony's own branch for this
   * function mode is `SDIO_OpenSession` (0x9210) instead, so it is sent here —
   * see the file header. Runs once per session.
   *
   * This is why 0x9202 / 0x9209 / 0x9216 can be refused while 0x9212 is
   * accepted: they belong to the session `SDIO_Connect` (0x9201) opens, and the
   * standard PTP `OpenSession` (0x1002) the transport already sent does not open
   * it. Without (S7) `onInitialized` never fires, and without `onInitialized`
   * `BasePtpManager` never issues 0x9209 at all — `BasePtpManager.java:369`
   * sits inside `initializerCallback.onInitialized`.
   *
   * Order and parameters are fixed by `initialization/Initializer.java`; the
   * file header names the exact line of every step. Idempotent: a second call on
   * the same session returns the cached result without touching the wire, so
   * paging and repeated browses cannot re-run it.
   *
   * The first refusal skips the remaining steps, which is what Sony does (a
   * refused setup transaction ends in `onInitializationFailed`,
   * `Initializer.java:117-130`); the step, its opcode and the response code are
   * recorded for `logBrowseResult` instead of being collapsed into one generic
   * failure. `probeAfterSetup` still re-tries 0x9216 and 0x9209 on the same run.
   */
  static async setupSonySession(session: PtpTransport): Promise<boolean> {
    if (SonyPtpIpContent.setupDone && SonyPtpIpContent.setupSession === session) {
      return SonyPtpIpContent.setupOk;
    }
    SonyPtpIpContent.setupDone = false;
    SonyPtpIpContent.setupOk = false;
    SonyPtpIpContent.setupSession = null;
    SonyPtpIpContent.setupSteps = 0;
    SonyPtpIpContent.setupFailedStep = 'none';
    SonyPtpIpContent.setupFailedOpcode = -1;
    SonyPtpIpContent.setupFailedCode = -1;
    SonyPtpIpContent.deviceInfoBytes = 0;
    SonyPtpIpContent.extDeviceInfoBytes = 0;
    SonyPtpIpContent.extDeviceInfoSummary = '-';
    SonyPtpIpContent.openSessionCode = -2;
    SonyPtpIpContent.openSessionMode = -1;
    SonyPtpIpContent.ddXmlCode = -2;
    SonyPtpIpContent.ddXmlBytes = 0;
    SonyPtpIpContent.didXmlCode = -2;
    SonyPtpIpContent.didXmlBytes = 0;
    SonyPtpIpContent.didServerVersion = '';
    SonyPtpIpContent.deviceInfoOps = -1;
    SonyPtpIpContent.deviceInfoFunctionalMode = -1;
    SonyPtpIpContent.deviceInfoHasDdFile = false;
    SonyPtpIpContent.deviceInfoHasCapturedDateList = false;
    SonyPtpIpContent.deviceInfoHasContentsInfoList = false;
    SonyPtpIpContent.deviceInfoModel = '-';
    // The version read is step (S5) below. Clear the cached answer so this
    // session reads it for real instead of reusing an earlier session's value.
    SonyPtpIpContent.vendorCodeVersion = -1;
    SonyPtpIpContent.vendorCodeVersionFetched = false;

    NikonPtpIpService.log('sony setup start steps=6 opcodes=' +
      `${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_DEVICE_INFO)},` +
      `${SonyPtpIpContent.hex(SonyPtpIpContent.OP_SDIO_CONNECT)},` +
      `${SonyPtpIpContent.hex(SonyPtpIpContent.OP_SDIO_CONNECT)},` +
      `${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_VENDOR_CODE_VERSION)},` +
      `${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_EXT_DEVICE_INFO)},` +
      `${SonyPtpIpContent.hex(SonyPtpIpContent.OP_SDIO_CONNECT)}`);

    if (!(await SonyPtpIpContent.setupGetDeviceInfo(session))) {
      return SonyPtpIpContent.finishSetup(session, false);
    }
    // (S1b)/(S1c) Sony reads the DD document and then the DID document before it
    // decides the function mode (`Initializer.java:146-194`). Both steps are
    // diagnostics here — a refusal does not abort the chain — but the DID
    // document's X_ServerVersion is what says whether this body needs
    // REMOTE_CONTROL_WITH_TRANSFER_MODE.
    await SonyPtpIpContent.setupDeviceDescriptionFiles(session);
    // (S2) `SDIO_OpenSession [1, REMOTE_CONTROL_WITH_TRANSFER_MODE]`. Sony sends
    // this INSTEAD of the standard `OpenSession` whenever the DID server version
    // is >= 4.0 (`Initializer.java:83-96`); the transport's handshake can only
    // send the standard one, so the vendor session open is added here. It is
    // non-fatal: the six steps below must keep working on a body that refuses a
    // second session open.
    await SonyPtpIpContent.setupOpenSession(session);
    if (!(await SonyPtpIpContent.setupConnect(session, SonyPtpIpContent.SDIO_CONNECT_PHASE_1))) {
      return SonyPtpIpContent.finishSetup(session, false);
    }
    if (!(await SonyPtpIpContent.setupConnect(session, SonyPtpIpContent.SDIO_CONNECT_PHASE_2))) {
      return SonyPtpIpContent.finishSetup(session, false);
    }
    if (!(await SonyPtpIpContent.setupVendorCodeVersion(session))) {
      return SonyPtpIpContent.finishSetup(session, false);
    }
    if (!(await SonyPtpIpContent.setupGetExtDeviceInfo(session))) {
      return SonyPtpIpContent.finishSetup(session, false);
    }
    if (!(await SonyPtpIpContent.setupConnect(session, SonyPtpIpContent.SDIO_CONNECT_PHASE_3))) {
      return SonyPtpIpContent.finishSetup(session, false);
    }
    return SonyPtpIpContent.finishSetup(session, true);
  }

  /** Records the setup outcome and caches it for this session. `setupDone`
   * means "already attempted on `setupSession`" — a refused setup is cached too,
   * so the sequence runs exactly once per session and never once per page; a new
   * session is a new object and therefore runs it again. */
  private static finishSetup(session: PtpTransport, ok: boolean): boolean {
    SonyPtpIpContent.setupOk = ok;
    SonyPtpIpContent.setupDone = true;
    SonyPtpIpContent.setupSession = session;
    // A setup that SUCCEEDS is proof this body runs the six steps, so it must
    // also clear the "prefer the standard open" latch. Without this the latch
    // was terminal: once a single 0x9210 attempt failed, every later attempt
    // asked for 0x1002, and mode 2 can only ever be established by 0x9210 — the
    // upgrade then answers 0x201E SessionAlreadyOpen, so the body sat at
    // `mode2=no`/`result=mode2-unavailable` for the rest of the process and
    // contents transfer stayed dead until the app was restarted (observed).
    if (ok) {
      SonyPtpIpContent.vendorSetupFailed = false;
    }
    NikonPtpIpService.log(`sony setup ${ok ? 'ok' : 'refused'} steps=${SonyPtpIpContent.setupSteps}/6` +
      ` failedStep=${SonyPtpIpContent.setupFailedStep}` +
      ` failedOp=${SonyPtpIpContent.hex(SonyPtpIpContent.setupFailedOpcode)}` +
      ` failedCode=${SonyPtpIpContent.hex(SonyPtpIpContent.setupFailedCode)}` +
      ` deviceInfoBytes=${SonyPtpIpContent.deviceInfoBytes}` +
      ` vendorCodeVersion=${SonyPtpIpContent.vendorCodeVersion < 0
        ? 'unknown' : SonyPtpIpContent.vendorCodeVersion}` +
      ` extDeviceInfoBytes=${SonyPtpIpContent.extDeviceInfoBytes}` +
      ` extDeviceInfo=${SonyPtpIpContent.extDeviceInfoSummary}`);
    return ok;
  }

  /**
   * One setup transaction: logs the step number, its name, its opcode in HEX,
   * its parameters and the response code, then returns the response — or null
   * when the round trip threw, which is recorded as a failed step.
   *
   * `expectsData` is true for the same reason `setContentsTransferMode` passes
   * true: the request announces no-data-phase (Sony's
   * `EnumDataPhaseInfo.NoDataOrDataInPhase`), and the tolerant flag only means
   * "a data phase, if the body does send one, is drained" instead of being left
   * on the wire to poison the session.
   */
  private static async setupTransaction(session: PtpTransport, step: string, opcode: number,
    params: number[]): Promise<NikonPtpResponse | null> {
    SonyPtpIpContent.setupSteps += 1;
    try {
      const response: NikonPtpResponse = await session.enqueue(opcode, params, true);
      NikonPtpIpService.log(`sony setup step=${SonyPtpIpContent.setupSteps} name=${step}` +
        ` op=${SonyPtpIpContent.hex(opcode)} params=[${params.join(',')}]` +
        ` code=${SonyPtpIpContent.hex(response.code)} bytes=${response.data.length}` +
        ` paramsOut=[${response.params.join(',')}]`);
      if (response.code !== SonyPtpIpContent.RESPONSE_OK) {
        SonyPtpIpContent.recordSetupFailure(step, opcode, response.code);
      }
      return response;
    } catch (error) {
      SonyPtpIpContent.recordSetupFailure(step, opcode, -1);
      NikonPtpIpService.log(`sony setup step=${SonyPtpIpContent.setupSteps} name=${step}` +
        ` op=${SonyPtpIpContent.hex(opcode)} params=[${params.join(',')}] code=none` +
        ` error=${SonyPtpIpContent.errorText(error as Object)}`);
      NikonPtpIpService.logError(`sony setup ${step}`, error as Object);
      return null;
    }
  }

  /** Keeps the FIRST refused step, so the report names the earliest thing the
   * camera rejected rather than the last. */
  private static recordSetupFailure(step: string, opcode: number, code: number): void {
    if (SonyPtpIpContent.setupFailedStep !== 'none') return;
    SonyPtpIpContent.setupFailedStep = step;
    SonyPtpIpContent.setupFailedOpcode = opcode;
    SonyPtpIpContent.setupFailedCode = code;
  }

  /** One `SDIO_Connect` (0x9201) with `[phase, 0, 0]`. */
  private static async setupConnect(session: PtpTransport, phase: number): Promise<boolean> {
    const params: number[] = [phase, SonyPtpIpContent.SDIO_CONNECT_PARAM_TAIL,
      SonyPtpIpContent.SDIO_CONNECT_PARAM_TAIL];
    const response = await SonyPtpIpContent.setupTransaction(session,
      `SDIO_Connect(phase=${phase})`, SonyPtpIpContent.OP_SDIO_CONNECT, params);
    return response !== null && response.code === SonyPtpIpContent.RESPONSE_OK;
  }

  /**
   * `GetDeviceInfo` (0x1001), step (S1) — one round trip with no parameters
   * (`Initializer.java:111`). Its dataset is where Sony reads
   * `isSupported(SDIO_GetVendorCodeVersion)` from (`Initializer.java:212-215`),
   * but the outcome is all that is logged here: the property dump carries its
   * own structure, so the dataset is not otherwise needed.
   *
   * A refused 0x1001 is a first-class finding rather than noise — Sony aborts
   * its whole initialization on it, so this chain does too, and
   * `probeAfterSetup` still re-tries 0x9216 and 0x9209 in the same run.
   */
  private static async setupGetDeviceInfo(session: PtpTransport): Promise<boolean> {
    const response = await SonyPtpIpContent.setupTransaction(session, 'GetDeviceInfo',
      SonyPtpIpContent.OP_GET_DEVICE_INFO, []);
    if (response === null || response.code !== SonyPtpIpContent.RESPONSE_OK) return false;
    SonyPtpIpContent.deviceInfoBytes = response.data.length;
    SonyPtpIpContent.describeDeviceInfo(response.data);
    NikonPtpIpService.log(`sony setup device-info bytes=${response.data.length}` +
      ` model=${SonyPtpIpContent.deviceInfoModel}` +
      ` ops=${SonyPtpIpContent.deviceInfoOps}` +
      ` functionalMode=${SonyPtpIpContent.deviceInfoFunctionalMode}` +
      ` has=${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_DEVICE_DESCRIPTION_FILE)}` +
      `:${SonyPtpIpContent.deviceInfoHasDdFile ? 1 : 0}` +
      `,${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_CAPTURED_DATE_LIST)}` +
      `:${SonyPtpIpContent.deviceInfoHasCapturedDateList ? 1 : 0}` +
      `,${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_CONTENTS_INFO_LIST)}` +
      `:${SonyPtpIpContent.deviceInfoHasContentsInfoList ? 1 : 0}` +
      ` opsSupportedReason=${SonyPtpIpContent.deviceInfoOps === -1 ? 'unparsed' : 'ok'}`);
    return true;
  }

  /**
   * Reads the operations the camera advertises in `GetDeviceInfo`, which is the
   * list Sony itself gates its branches on
   * (`DeviceInfoDataset.isSupported` -> `operationsSupported.contains(code)`,
   * `base/deviceinfo/DeviceInfoDataset.java:73-75`).
   *
   * Field order is `DeviceInfoDataset.Companion.parseDeviceInfoDataset`
   * (`:43-51`) with `getArray` (`:22-31`, u32 count then count x u16) and
   * `getString` (`:33-41`, u8 character count then that many UTF-16LE
   * characters):
   *   u16 standardVersion, u32 vendorExtensionId, u16 vendorExtensionVersion,
   *   string vendorExtensionDesc, u16 functionalMode,
   *   array operationsSupported, array eventsSupported,
   *   array devicePropertiesSupported, array captureFormats, array imageFormats,
   *   string manufacturer, string model, string deviceVersion, string serial.
   *
   * Only operationsSupported and the model are kept. Anything inconsistent
   * leaves `deviceInfoOps` at -1, which the log reports as `unparsed` rather
   * than as "the body does not support it".
   */
  private static describeDeviceInfo(data: Uint8Array): void {
    try {
      const reader = new SonyContentReader(data);
      reader.u16();                                   // standardVersion
      reader.u32();                                   // vendorExtensionId
      reader.u16();                                   // vendorExtensionVersion
      const vendorDescChars = reader.u8();            // PTP string
      reader.skip(vendorDescChars * 2);
      // Recorded before any later check can return early, so a dataset that
      // parsed this far still reports the mode the camera says it is in.
      SonyPtpIpContent.deviceInfoFunctionalMode = reader.u16();   // functionalMode
      const operationCount = reader.u32();
      if (reader.isTruncated() || operationCount > SonyPtpIpContent.MAX_DEVICE_PROPERTIES) return;
      const operations: number[] = [];
      for (let index = 0; index < operationCount; index++) {
        operations.push(reader.u16());
      }
      if (reader.isTruncated()) return;
      SonyPtpIpContent.deviceInfoOps = operations.length;
      SonyPtpIpContent.deviceInfoHasDdFile =
        operations.indexOf(SonyPtpIpContent.OP_GET_DEVICE_DESCRIPTION_FILE) >= 0;
      SonyPtpIpContent.deviceInfoHasCapturedDateList =
        operations.indexOf(SonyPtpIpContent.OP_GET_CAPTURED_DATE_LIST) >= 0;
      SonyPtpIpContent.deviceInfoHasContentsInfoList =
        operations.indexOf(SonyPtpIpContent.OP_GET_CONTENTS_INFO_LIST) >= 0;
      for (let index = 0; index < 4; index++) {       // events, properties, formats
        const count = reader.u32();
        if (reader.isTruncated()) return;
        reader.skip(count * 2);
      }
      reader.skip(reader.u8() * 2);                   // manufacturer
      const model = reader.utf16(reader.u8());
      SonyPtpIpContent.deviceInfoModel = model.length > 0 ? model : '-';
    } catch (error) {
      NikonPtpIpService.log('sony setup device-info unparsed' +
        ` error=${SonyPtpIpContent.errorText(error as Object)}`);
    }
  }

  /**
   * (S1b)/(S1c) `SDIO_GetDeviceDescriptionFile` (0x923A) with parameter 1 (DD
   * document) and then 2 (DID document): `Initializer.java:161` and
   * `SDIO_GetDeviceDescriptionFileState2.java:20`. Both are data-in phase, and
   * the DID document is where `<X_ServerVersion>` lives
   * (`common/device/did/DeviceInfo.java:125-130`) — the value
   * `Initializer.adjustFunctionMode` (`:58-77`) compares against 4.0.
   *
   * Non-fatal by design: this is evidence for the mode decision, not a gate, so
   * a refusal is logged and the chain continues.
   */
  private static async setupDeviceDescriptionFiles(session: PtpTransport): Promise<void> {
    const dd = await SonyPtpIpContent.readDeviceDescriptionFile(session,
      SonyPtpIpContent.DEVICE_DESCRIPTION_FILE_DD);
    SonyPtpIpContent.ddXmlCode = dd === null ? -1 : dd.code;
    SonyPtpIpContent.ddXmlBytes = dd === null ? 0 : dd.data.length;
    const did = await SonyPtpIpContent.readDeviceDescriptionFile(session,
      SonyPtpIpContent.DEVICE_DESCRIPTION_FILE_DID);
    SonyPtpIpContent.didXmlCode = did === null ? -1 : did.code;
    SonyPtpIpContent.didXmlBytes = did === null ? 0 : did.data.length;
    if (did !== null && did.code === SonyPtpIpContent.RESPONSE_OK && did.data.length > 0) {
      const text = SonyPtpIpContent.decodeUtf8(did.data, did.data.length);
      SonyPtpIpContent.didServerVersion =
        SonyPtpIpContent.extractXmlElement(text, SonyPtpIpContent.DID_SERVER_VERSION_TAG);
    }
    const parsed = Number.parseFloat(SonyPtpIpContent.didServerVersion);
    const versionOk = !Number.isNaN(parsed) &&
      parsed >= SonyPtpIpContent.DID_SERVER_VERSION_FOR_REMOTE_CONTROL_WITH_TRANSFER;
    NikonPtpIpService.log(`sony setup description-file dd=${SonyPtpIpContent.probeHex(SonyPtpIpContent.ddXmlCode)}` +
      `:${SonyPtpIpContent.ddXmlBytes}` +
      ` did=${SonyPtpIpContent.probeHex(SonyPtpIpContent.didXmlCode)}:${SonyPtpIpContent.didXmlBytes}` +
      ` serverVersion=${SonyPtpIpContent.didServerVersion.length > 0
        ? SonyPtpIpContent.didServerVersion : 'unknown'}` +
      ` remoteControlWithTransfer=${versionOk ? 1 : 0}` +
      ` requiredMode=${SonyPtpIpContent.FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER}`);
  }

  /** One `SDIO_GetDeviceDescriptionFile` round trip. Returns null when the round
   * trip threw. The payload is UTF-8 XML; only its size is logged here (the
   * first line of the document is up to 120 bytes of evidence). */
  private static async readDeviceDescriptionFile(session: PtpTransport,
    fileType: number): Promise<NikonPtpResponse | null> {
    try {
      const response: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_GET_DEVICE_DESCRIPTION_FILE, [fileType], true);
      const shown = Math.min(response.data.length, 120);
      NikonPtpIpService.log(`sony setup get-description-file file=${fileType}` +
        ` op=${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_DEVICE_DESCRIPTION_FILE)}` +
        ` code=${SonyPtpIpContent.hex(response.code)} bytes=${response.data.length}` +
        ` paramsOut=[${response.params.join(',')}]` +
        ` head=${shown > 0 ? JSON.stringify(SonyPtpIpContent.decodeUtf8(response.data, shown)) : '-'}`);
      return response;
    } catch (error) {
      NikonPtpIpService.log(`sony setup get-description-file file=${fileType} code=none` +
        ` error=${SonyPtpIpContent.errorText(error as Object)}`);
      NikonPtpIpService.logError('sony setup get-description-file', error as Object);
      return null;
    }
  }

  /**
   * (S2) `SDIO_OpenSession` (0x9210) with `[sessionId, functionMode.value]`,
   * `[1, 2]` for `REMOTE_CONTROL_WITH_TRANSFER_MODE`
   * (`Initializer.java:95`; the enum's value for that member is 2).
   *
   * This is now a DIAGNOSTIC fallback only. The browse asks the transport to
   * OPEN the session with 0x9210 `[1, 2]` (see the file header), so the normal
   * path takes the branch below and nothing is sent here. The remaining path is a
   * session the transport had to open with the standard `OpenSession` (0x1002)
   * after the body refused the vendor open: the mode is already fixed for that
   * session, so this request can only be refused (0x201E) — and even an accepted
   * one does NOT switch the mode. Its answer is recorded for the browse line, but
   * the mode-2 verdict is taken from the operation that really established the
   * session (`sessionOpenObserved`), never from this response.
   */
  private static async setupOpenSession(session: PtpTransport): Promise<void> {
    const mode = SonyPtpIpContent.FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER;
    SonyPtpIpContent.openSessionMode = mode;
    if (session.openOpcode === SonyPtpIpContent.OP_SDIO_OPEN_SESSION) {
      // The handshake already opened this session with 0x9210 [1, mode]; a
      // second session-open on the same session would be redundant (and is the
      // one thing a camera is most likely to refuse).
      SonyPtpIpContent.openSessionCode = session.openCode;
      NikonPtpIpService.log(`sony setup sdio-open-session already-opened-by-handshake` +
        ` op=${SonyPtpIpContent.hex(session.openOpcode)}` +
        ` code=${SonyPtpIpContent.probeHex(session.openCode)}` +
        ` params=[${SonyPtpIpContent.SESSION_ID},${mode}]` +
        ` mode2=yes source=session-open`);
      return;
    }
    try {
      const response: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_SDIO_OPEN_SESSION,
        [SonyPtpIpContent.SESSION_ID, mode],
        true);
      SonyPtpIpContent.openSessionCode = response.code;
      // `mode2=no source=session-open` on purpose: this response cannot change
      // the mode of a session that was established by 0x1002.
      NikonPtpIpService.log(`sony setup sdio-open-session` +
        ` op=${SonyPtpIpContent.hex(SonyPtpIpContent.OP_SDIO_OPEN_SESSION)}` +
        ` params=[${SonyPtpIpContent.SESSION_ID},${mode}]` +
        ` code=${SonyPtpIpContent.hex(response.code)} bytes=${response.data.length}` +
        ` paramsOut=[${response.params.join(',')}]` +
        ` mode2=no source=session-open` +
        ` establishedBy=${SonyPtpIpContent.probeHex(session.openOpcode)}`);
    } catch (error) {
      SonyPtpIpContent.openSessionCode = -1;
      NikonPtpIpService.log('sony setup sdio-open-session code=none' +
        ` params=[${SonyPtpIpContent.SESSION_ID},${mode}]` +
        ` mode2=no source=session-open` +
        ` error=${SonyPtpIpContent.errorText(error as Object)}`);
      NikonPtpIpService.logError('sony setup sdio-open-session', error as Object);
    }
  }

  /**
   * Whether the session the transport established was opened by
   * `SDIO_OpenSession` (0x9210) `[1, 2]` — the operation that puts the camera in
   * `REMOTE_CONTROL_WITH_TRANSFER_MODE`, the only state in which
   * `SDIO_GetCapturedDateList` (0x923B) is served
   * (`Initializer.java:83-96`, `MtpListViewController.java:517-527`).
   *
   * The verdict is the operation that really opened the session, taken from the
   * transport (`PtpTransport.openOpcode`): a session opened with 0x1002 on
   * which a later `SDIO_OpenSession` was merely ACCEPTED is not mode 2, because
   * the mode is fixed when the session is opened. Because the transport only
   * publishes a session whose open answered 0x2001, a session observed as 0x9210
   * is necessarily a successful one.
   */
  private static mode2Established(): boolean {
    return SonyPtpIpContent.sessionOpenObserved === SonyPtpIpContent.OP_SDIO_OPEN_SESSION;
  }

  /** Value of a simple XML element, matched by local name the way
   * `XmlPullParser.getName()` does (`DeviceInfo.parse`,
   * `common/device/did/DeviceInfo.java:125-130`): a namespace prefix in the raw
   * document must not hide the element. Returns '' when the element is absent or
   * empty. */
  private static extractXmlElement(text: string, tag: string): string {
    const openers: string[] = ['<' + tag + '>', ':' + tag + '>'];
    for (const opener of openers) {
      const start = text.indexOf(opener);
      if (start < 0) continue;
      const valueStart = start + opener.length;
      const end = text.indexOf('</', valueStart);
      if (end < 0) continue;
      const value = text.substring(valueStart, end).trim();
      if (value.length > 0) return value;
    }
    return '';
  }

  /**
   * The camera's live-view URL, for the Sony live-view line.
   *
   * Two sources, in the order Sony's own client uses them:
   *
   *  1. Device property `LiveViewUrl` (53880 = 0xD278,
   *     `base/transaction/EnumDevicePropCode.java:109`
   *     `LiveViewUrl(53880, "LiveView URL")`), taken from the accumulated 0x9209
   *     property map as a UTF-16LE PTP string — a u8 character count then that
   *     many code units, terminator included (`DevicePropInfoDataset.getStrValue`,
   *     the encoding `SonyContentReader.utf16` decodes). `PtpIpCamera.java:705-711`
   *     reads exactly this field, `mCurrentStringValue`, out of the map it was
   *     handed by `onPtpInitialized` (`PtpIpClient.java:150` passes
   *     `mPtpIpManager.getAllDevicePropInfoDatasets()`) and gated on `mIsEnable`
   *     being `True` or `DispOnly` — the same two values checked below.
   *
   *     No request is sent for it. The 0x9209 walk already carries the string;
   *     `SonyDevicePropInfoParser` decodes every `DATA_TYPE_STR` record into
   *     `SonyPtpIpContent.propStrings` instead of consuming and discarding it.
   *     A targeted `GetDevicePropValue` for this property is NOT part of Sony's
   *     protocol, and on a 0x9210 session the camera does not answer one at all:
   *     the request stalls for the full transport timeout, the peer closes the
   *     socket, and every later step fails on a poisoned session.
   *
   *  2. `X_ScalarWebAPI_LiveView_URL` in the DD document
   *     (`SDIO_GetDeviceDescriptionFile` (0x923A) parameter 1), which is where
   *     `DeviceDescription.parse` gets `mLiveviewUrl` from
   *     (`common/device/DeviceDescription.java:91-94`); the same document this
   *     module already fetches in step (S1b). Used only when (1) answers
   *     nothing usable.
   *
   * Additive: a new public reader; no existing Sony path calls it and no
   * existing line changes. Returns '' when neither source yields a URL.
   */
  static async readLiveViewUrl(session: PtpTransport): Promise<string> {
    // (1) The accumulated property map. No round trip, and none is wanted: a
    // targeted `GetDevicePropValue` for this vendor STR property is not part of
    // Sony's protocol — the URL arrives inside the 0x9209 dump and
    // `PtpIpCamera.java:705` only ever reads it back out of the map. Issuing that
    // request on a 0x9210 (remote-control) session is what the camera answers
    // with silence: a ~10 s stall, no reply, then the socket is closed by the
    // peer and the session is poisoned for every later step.
    const flag = SonyPtpIpContent.propEnableFlags.get(SonyPtpIpContent.PROP_LIVE_VIEW_URL);
    const enabled = flag === SonyPtpIpContent.IS_ENABLE_TRUE ||
      flag === SonyPtpIpContent.IS_ENABLE_DISP_ONLY;
    const accumulated = SonyPtpIpContent.propStrings.get(SonyPtpIpContent.PROP_LIVE_VIEW_URL);
    const fromProperty = enabled && accumulated !== undefined ? accumulated : '';
    NikonPtpIpService.log(`sony liveview url-prop` +
      ` source=propMap value=${fromProperty.length > 0 ? fromProperty : '-'}` +
      ` isEnable=${flag === undefined ? 'absent' : flag}` +
      ` strings=${SonyPtpIpContent.propStrings.size}`);
    if (fromProperty.length > 0) {
      return fromProperty;
    }
    // Fallback: re-read the DD document we already fetched during setup (its
    // payload is not retained, only its size), and pull the element out of it.
    const dd = await SonyPtpIpContent.readDeviceDescriptionFile(session,
      SonyPtpIpContent.DEVICE_DESCRIPTION_FILE_DD);
    let fromDd = '';
    if (dd !== null && dd.code === SonyPtpIpContent.RESPONSE_OK && dd.data.length > 0) {
      const text = SonyPtpIpContent.decodeUtf8(dd.data, dd.data.length);
      fromDd = SonyPtpIpContent.extractXmlElement(text, SonyPtpIpContent.DD_LIVE_VIEW_URL_TAG);
    }
    NikonPtpIpService.log(`sony liveview url-dd` +
      ` code=${dd === null ? 'none' : SonyPtpIpContent.hex(dd.code)}` +
      ` bytes=${dd === null ? 0 : dd.data.length}` +
      ` value=${fromDd.length > 0 ? fromDd : '-'}`);
    return fromDd;
  }

  /**
   * `SDIO_GetVendorCodeVersion` (0x9216) with an empty parameter list; the
   * version is the first RESPONSE parameter (`Initializer.java:223-231`).
   *
   * An OK answer without a parameter is NOT a failure: Sony explicitly
   * tolerates it and continues with the flag NONE (`Initializer.java:224-226`),
   * so the chain keeps going and the dump is sent without the flag.
   */
  private static async setupVendorCodeVersion(session: PtpTransport): Promise<boolean> {
    const response = await SonyPtpIpContent.setupTransaction(session, 'SDIO_GetVendorCodeVersion',
      SonyPtpIpContent.OP_GET_VENDOR_CODE_VERSION, []);
    // Mark the read as attempted either way: the only re-try in this run is the
    // explicit, separately logged one in probeAfterSetup.
    SonyPtpIpContent.vendorCodeVersionFetched = true;
    if (response === null || response.code !== SonyPtpIpContent.RESPONSE_OK) return false;
    const raw = response.params.length > 0 ? response.params[0] : undefined;
    if (raw === undefined) {
      NikonPtpIpService.log('sony setup vendor-code-version absent continuing flag=NONE');
      return true;
    }
    SonyPtpIpContent.vendorCodeVersion = raw;
    const params = SonyPtpIpContent.propertyDumpParamsFor(raw);
    NikonPtpIpService.log(`sony setup vendor-code-version version=${raw}` +
      ` propertyFlag=${raw >= SonyPtpIpContent.VENDOR_CODE_VERSION_FOR_PROPERTY_FLAG ? 1 : 0}` +
      ` propDumpParams=[${params.join(',')}]`);
    return true;
  }

  /** `SDIO_GetExtDeviceInfo` (0x9202) with `[300]`, or `[300, 1]` when (S5)
   * said the flag is ENABLE. */
  private static async setupGetExtDeviceInfo(session: PtpTransport): Promise<boolean> {
    const params = SonyPtpIpContent.extDeviceInfoParams();
    const response = await SonyPtpIpContent.setupTransaction(session, 'SDIO_GetExtDeviceInfo',
      SonyPtpIpContent.OP_GET_EXT_DEVICE_INFO, params);
    if (response === null || response.code !== SonyPtpIpContent.RESPONSE_OK) return false;
    SonyPtpIpContent.extDeviceInfoBytes = response.data.length;
    SonyPtpIpContent.extDeviceInfoSummary = SonyPtpIpContent.describeExtDeviceInfo(response.data);
    NikonPtpIpService.log(`sony setup ext-device-info bytes=${response.data.length}` +
      ` summary=${SonyPtpIpContent.extDeviceInfoSummary}`);
    return true;
  }

  /** `[300]`, or `[300, 1]` once the vendor code version says the flag is
   * ENABLE (`SDIO_GetExtDeviceInfoState.java:21`). */
  private static extDeviceInfoParams(): number[] {
    const first = SonyPtpIpContent.GET_EXT_DEVICE_INFO_PARAM;
    if (SonyPtpIpContent.vendorCodeVersion >= SonyPtpIpContent.VENDOR_CODE_VERSION_FOR_PROPERTY_FLAG) {
      return [first, SonyPtpIpContent.PROPERTY_VALUE_ENABLE];
    }
    return [first];
  }

  /** The `SDIO_GetAllExtDevicePropInfo` parameter list for a known vendor code
   * version: `[1]` below 310, `[1, 1]` at or above — `DevicePropertyGetter`
   * appends the flag's own value only for ENABLE (`DevicePropertyGetter.java:41`
   * versus `:43`). */
  private static propertyDumpParamsFor(version: number): number[] {
    const first = SonyPtpIpContent.GET_ALL_EXT_DEVICE_PROP_INFO_PARAM;
    if (version >= SonyPtpIpContent.VENDOR_CODE_VERSION_FOR_PROPERTY_FLAG) {
      return [first, SonyPtpIpContent.PROPERTY_VALUE_ENABLE];
    }
    return [first];
  }

  /**
   * The INITIAL `SDIO_GetAllExtDevicePropInfo` parameter list: `[0]`, or `[0, 1]`
   * once the vendor code version says the flag is ENABLE.
   *
   * `BasePtpManager.onInitialized` — the one place Sony acquires the dump for the
   * first time — calls `DevicePropertyGetter.execute(false, flag, cb)`
   * (`BasePtpManager.java:369`), and `execute` writes `{z ? 1 : 0}` as parameter
   * [0] and appends the flag value only for ENABLE
   * (`DevicePropertyGetter.java:40-44`). Parameter [0] is therefore 0 on the
   * initial acquisition and 1 only on the `SDIE_DevicePropChanged` refresh
   * (`DevicePropertyUpdater$$ExternalSyntheticLambda0.java:24`), which is what
   * `propertyDumpParamsFor` builds. The flag is appended in both forms.
   */
  private static initialPropertyDumpParams(): number[] {
    const first = SonyPtpIpContent.GET_ALL_EXT_DEVICE_PROP_INFO_PARAM_INITIAL;
    if (SonyPtpIpContent.vendorCodeVersion >= SonyPtpIpContent.VENDOR_CODE_VERSION_FOR_PROPERTY_FLAG) {
      return [first, SonyPtpIpContent.PROPERTY_VALUE_ENABLE];
    }
    return [first];
  }

  /**
   * Short summary of the `SDIO_GetExtDeviceInfo` dataset, so the log proves real
   * content arrived rather than just a 0x2001. Layout, little-endian:
   * `id(2) + propertyCount(4) + propertyCount x u16 + eventCount(4) +
   * eventCount x u16` (`initialization/Initializer.java:242-252`). The declared
   * counts are lengths read off the wire and are never trusted for indexing.
   */
  private static describeExtDeviceInfo(data: Uint8Array): string {
    if (data.length < 6) {
      SonyPtpIpContent.extPropCount = -1;
      return `short:${data.length}`;
    }
    const id = data[0] | (data[1] << 8);
    const propertyCount = NikonPtpIpService.readU32(data, 2);
    const afterProperties = 6 + propertyCount * 2;
    // The camera's own device-property list IS `SDIExtDeviceInfoDataset.
    // mDevicePropCodes`, and `DevicePropertyOperation.isSupported` — the first
    // half of Sony's slot test — is a membership check on it. Recorded for the
    // three contents-transfer codes so one run settles whether 53716/53717 were
    // ever offered at all.
    SonyPtpIpContent.extPropCount = propertyCount;
    SonyPtpIpContent.extPropHasEnableStatus = 0;
    SonyPtpIpContent.extPropHasSlot1 = 0;
    SonyPtpIpContent.extPropHasSlot2 = 0;
    SonyPtpIpContent.extPropHasMediaSlot1 = 0;
    SonyPtpIpContent.extPropHasMediaSlot2 = 0;
    SonyPtpIpContent.extPropHasPlaybackMedia = 0;
    const usable = Math.min(propertyCount, Math.max(0, Math.floor((data.length - 6) / 2)));
    for (let index = 0; index < usable; index++) {
      const code = data[6 + index * 2] | (data[7 + index * 2] << 8);
      if (code === SonyPtpIpContent.PROP_CONTENTS_TRANSFER_ENABLE_STATUS) {
        SonyPtpIpContent.extPropHasEnableStatus = 1;
      } else if (code === SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_ENABLE_SLOT1) {
        SonyPtpIpContent.extPropHasSlot1 = 1;
      } else if (code === SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_ENABLE_SLOT2) {
        SonyPtpIpContent.extPropHasSlot2 = 1;
      } else if (code === SonyPtpIpContent.PROP_MEDIA_SLOT1_STATUS) {
        SonyPtpIpContent.extPropHasMediaSlot1 = 1;
      } else if (code === SonyPtpIpContent.PROP_MEDIA_SLOT2_STATUS) {
        SonyPtpIpContent.extPropHasMediaSlot2 = 1;
      } else if (code === SonyPtpIpContent.PROP_PLAYBACK_MEDIA) {
        SonyPtpIpContent.extPropHasPlaybackMedia = 1;
      }
    }
    const mediaMembership = `${
      SonyPtpIpContent.PROP_MEDIA_SLOT1_STATUS}:${SonyPtpIpContent.extPropHasMediaSlot1}` +
      `,${SonyPtpIpContent.PROP_MEDIA_SLOT2_STATUS}:${SonyPtpIpContent.extPropHasMediaSlot2}` +
      `,${SonyPtpIpContent.PROP_PLAYBACK_MEDIA}:${SonyPtpIpContent.extPropHasPlaybackMedia}`;
    if (afterProperties + 4 > data.length) {
      return `id=${id} properties=${propertyCount} events=truncated` +
        ` extHas=${SonyPtpIpContent.extPropHasSlot1}` +
        `${SonyPtpIpContent.extPropHasSlot2}` +
        `${SonyPtpIpContent.extPropHasEnableStatus}` +
        ` extHasMedia=${mediaMembership}` +
        ` list=${SonyPtpIpContent.hexBytes(data, Math.min(data.length, 64))}`;
    }
    const eventCount = NikonPtpIpService.readU32(data, afterProperties);
    const afterEvents = afterProperties + 4 + eventCount * 2;
    return `id=${id} properties=${propertyCount} events=${eventCount}` +
      ` extHas=${SonyPtpIpContent.extPropHasSlot1}` +
      `${SonyPtpIpContent.extPropHasSlot2}` +
      `${SonyPtpIpContent.extPropHasEnableStatus}` +
      ` extHasMedia=${mediaMembership}` +
      (afterEvents > data.length ? '+truncated' : '');
  }

  /**
   * The single-run proof, called after `setupSonySession` on success AND on
   * failure: re-try the version read while it is still unknown, then issue
   * `SDIO_GetAllExtDevicePropInfo` once and log its response code with the byte
   * count.
   *
   * On the success path `waitContentsTransferEnabled` immediately repeats the
   * dump as its poll, which is the request Sony itself issues on every
   * `SDIE_DevicePropChanged`; this first one is the decisive one. On a refused
   * setup this is what shows whether the refusal is really the cause of the
   * earlier `dumpFail`.
   */
  static async probeAfterSetup(session: PtpTransport): Promise<void> {
    SonyPtpIpContent.probeVersionCode = -2;
    SonyPtpIpContent.probeDumpCode = -2;
    SonyPtpIpContent.probeDumpBytes = 0;
    SonyPtpIpContent.probeDumpFallbackCode = -2;
    SonyPtpIpContent.probeDumpFallbackBytes = 0;

    if (SonyPtpIpContent.vendorCodeVersion < 0) {
      try {
        const response: NikonPtpResponse = await session.enqueue(
          SonyPtpIpContent.OP_GET_VENDOR_CODE_VERSION, [], true);
        SonyPtpIpContent.probeVersionCode = response.code;
        const raw = response.params.length > 0 ? response.params[0] : undefined;
        if (response.code === SonyPtpIpContent.RESPONSE_OK && raw !== undefined) {
          SonyPtpIpContent.vendorCodeVersion = raw;
          SonyPtpIpContent.vendorCodeVersionFetched = true;
        }
        NikonPtpIpService.log('sony setup probe vendor-code-version retry=1' +
          ` op=${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_VENDOR_CODE_VERSION)} params=[]` +
          ` code=${SonyPtpIpContent.hex(response.code)}` +
          ` paramsOut=[${response.params.join(',')}]` +
          ` version=${SonyPtpIpContent.vendorCodeVersion < 0
            ? 'unknown' : SonyPtpIpContent.vendorCodeVersion}`);
      } catch (error) {
        NikonPtpIpService.log('sony setup probe vendor-code-version retry=1 code=none' +
          ` error=${SonyPtpIpContent.errorText(error as Object)}`);
        NikonPtpIpService.logError('sony setup probe vendor-code-version', error as Object);
      }
    }
    await SonyPtpIpContent.probePropertyDump(session);
    // Divergence (c): `onInitialized` starts the property dump above and then
    // immediately refreshes the device info — `DeviceInfoUpdater.execute$2()`
    // adds a SECOND `GetDeviceInfo` (`BasePtpManager.java:377-380`,
    // `base/deviceinfo/DeviceInfoUpdater.java:59-65`). Sent here, after the
    // dump, so the browse matches Sony's own order and the camera's own
    // `functionalMode` is read a second time on the live session.
    await SonyPtpIpContent.probeSecondDeviceInfo(session);
  }

  /**
   * The second `GetDeviceInfo` (0x1001) of the session — divergence (c).
   *
   * Nothing about the browse depends on it; it is sent because Sony sends it, at
   * exactly this point in the sequence, and because its dataset carries a
   * `functionalMode` read on the session that is ALREADY established — the only
   * mode evidence in this log that does not come from the operation that opened
   * the session. A refusal is recorded, never fatal.
   */
  private static async probeSecondDeviceInfo(session: PtpTransport): Promise<void> {
    try {
      const response: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_GET_DEVICE_INFO, [], true);
      SonyPtpIpContent.deviceInfo2Code = response.code;
      SonyPtpIpContent.deviceInfo2Bytes = response.data.length;
      if (response.code === SonyPtpIpContent.RESPONSE_OK && response.data.length > 0) {
        SonyPtpIpContent.deviceInfo2FunctionalMode =
          SonyPtpIpContent.deviceInfoFunctionalModeOf(response.data);
      }
      NikonPtpIpService.log('sony setup probe device-info-2 seq=after-prop-dump' +
        ` op=${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_DEVICE_INFO)} params=[]` +
        ` code=${SonyPtpIpContent.hex(response.code)} bytes=${response.data.length}` +
        ` paramsOut=[${response.params.join(',')}]` +
        ` functionalMode=${SonyPtpIpContent.deviceInfo2FunctionalMode}` +
        ` firstFunctionalMode=${SonyPtpIpContent.deviceInfoFunctionalMode}` +
        ` firstModel=${SonyPtpIpContent.deviceInfoModel}`);
    } catch (error) {
      SonyPtpIpContent.deviceInfo2Code = -1;
      SonyPtpIpContent.deviceInfo2Bytes = 0;
      NikonPtpIpService.log('sony setup probe device-info-2 seq=after-prop-dump code=none' +
        ` error=${SonyPtpIpContent.errorText(error as Object)}`);
      NikonPtpIpService.logError('sony setup probe device-info-2', error as Object);
    }
  }

  /** `functionalMode` out of a `GetDeviceInfo` dataset: the exact prefix
   * `describeDeviceInfo` walks — u16 standardVersion, u32 vendorExtensionId,
   * u16 vendorExtensionVersion, PTP string vendorExtensionDesc, u16
   * functionalMode (`base/deviceinfo/DeviceInfoDataset.java:43-51` with
   * `getString` at `:33-41`). Returns -1 when the dataset is too short to hold
   * the field, which is never the same as a mode of 0. */
  private static deviceInfoFunctionalModeOf(data: Uint8Array): number {
    const reader = new SonyContentReader(data);
    reader.u16();
    reader.u32();
    reader.u16();
    const vendorDescChars = reader.u8();
    reader.skip(vendorDescChars * 2);
    const functionalMode = reader.u16();
    return reader.isTruncated() ? -1 : functionalMode;
  }

  /** One explicitly logged `SDIO_GetAllExtDevicePropInfo`, plus — only while the
   * version is still unknown and only when the first attempt was refused — one
   * fallback with the flag form. Two labelled attempts separate "refused because
   * the flag could not be decided" from "refused for another reason". */
  private static async probePropertyDump(session: PtpTransport): Promise<void> {
    // The INITIAL form, `[0, flag]`: this is the first dump of the session and
    // `DevicePropertyGetter.execute(false, ...)` is what Sony's `onInitialized`
    // sends (`BasePtpManager.java:369`). The enable-refresh polls below use the
    // `[1, flag]` form instead (`propertyDumpParams`), and both are on the browse
    // line so the difference is visible.
    const params = SonyPtpIpContent.initialPropertyDumpParams();
    SonyPtpIpContent.propDumpParams = `[${params.join(',')}]`;
    SonyPtpIpContent.initialPropDumpParams = `[${params.join(',')}]`;
    try {
      const response: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_GET_ALL_EXT_DEVICE_PROP_INFO, params, true);
      SonyPtpIpContent.probeDumpCode = response.code;
      SonyPtpIpContent.probeDumpBytes = response.data.length;
      NikonPtpIpService.log('sony setup probe prop-dump form=initial' +
        ` op=${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_ALL_EXT_DEVICE_PROP_INFO)}` +
        ` params=[${params.join(',')}] code=${SonyPtpIpContent.hex(response.code)}` +
        ` bytes=${response.data.length}`);
      // Walk the probe's own payload as well. This is the one dump the log
      // already calls decisive, so its verdict must not wait for the enable
      // poll — and on a browse that dies before that poll it is the only verdict
      // there will be. The probe is the FIRST dump of the session and therefore
      // the full one, so its decoded values are registered too, not just its
      // walk: they are where the slot properties come from when every later poll
      // is a delta (see `registerPropDump`). Because the reported verdict belongs
      // to the largest payload, a later and smaller poll cannot overwrite it.
      if (response.code === SonyPtpIpContent.RESPONSE_OK && response.data.length > 0) {
        const probeParser = new SonyDevicePropInfoParser(response.data, response.data.length,
          'probe', SonyPtpIpContent.propDumpParams);
        const probeValues = probeParser.parse();
        SonyPtpIpContent.registerPropDump(probeParser, probeValues);
        NikonPtpIpService.log(`sony setup probe prop-dump walk=${SonyPtpIpContent.describeWalk()}` +
          ` properties=${probeValues === null ? 'none' : probeValues.size}` +
          ` accumulated=${SonyPtpIpContent.propValues.size}`);
      }
      if (response.code === SonyPtpIpContent.RESPONSE_OK) return;
      if (SonyPtpIpContent.vendorCodeVersion >= 0) return;
      const enabled: number[] = [SonyPtpIpContent.GET_ALL_EXT_DEVICE_PROP_INFO_PARAM_INITIAL,
        SonyPtpIpContent.PROPERTY_VALUE_ENABLE];
      const fallback: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_GET_ALL_EXT_DEVICE_PROP_INFO, enabled, true);
      SonyPtpIpContent.probeDumpFallbackCode = fallback.code;
      SonyPtpIpContent.probeDumpFallbackBytes = fallback.data.length;
      NikonPtpIpService.log('sony setup probe prop-dump fallback=flag form=initial' +
        ` params=[${enabled.join(',')}] code=${SonyPtpIpContent.hex(fallback.code)}` +
        ` bytes=${fallback.data.length}`);
    } catch (error) {
      NikonPtpIpService.log('sony setup probe prop-dump code=none' +
        ` error=${SonyPtpIpContent.errorText(error as Object)}`);
      NikonPtpIpService.logError('sony setup probe prop-dump', error as Object);
    }
  }

  /**
   * `SDIO_SetContentsTransferMode` with Sony's three parameters
   * (type = REMOTE_DEVICE, mode = ON, info = NONE).
   * Returns the raw PTP response code, or -1 when the round trip failed.
   *
   * The request announces DataPhaseInfo 1 (no data phase), which is what Sony
   * sends (`EnumDataPhaseInfo.NoDataOrDataInPhase`). The transport's
   * `expectsData` flag is only "may I consume a data phase", and passing true
   * here is strictly the more tolerant choice: if the body answers with the
   * response directly it is used as-is, and if it does send a data phase it is
   * drained first. Passing false would poison the whole session on a body that
   * does send one.
   */
  static async setContentsTransferMode(session: PtpTransport): Promise<number> {
    SonyPtpIpContent.lastModeError = '';
    SonyPtpIpContent.lastModeAnswered = false;
    try {
      const response: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_SET_CONTENTS_TRANSFER_MODE,
        [
          SonyPtpIpContent.CONTENTS_SELECT_TYPE_REMOTE_DEVICE,
          SonyPtpIpContent.CONTENTS_TRANSFER_MODE_ON,
          SonyPtpIpContent.ADDITIONAL_INFORMATION_NONE,
        ],
        true);
      SonyPtpIpContent.lastModeAnswered = true;
      NikonPtpIpService.log(`sony set-contents-transfer-mode type=` +
        `${SonyPtpIpContent.CONTENTS_SELECT_TYPE_REMOTE_DEVICE} mode=` +
        `${SonyPtpIpContent.CONTENTS_TRANSFER_MODE_ON} code=${SonyPtpIpContent.hex(response.code)}`);
      return response.code;
    } catch (error) {
      // Returning -1 alone renders as `mode=none`, which hid the first failed
      // attempt on a real device: keep the reason so the browse line can show it.
      SonyPtpIpContent.lastModeError = SonyPtpIpContent.errorText(error as Object);
      NikonPtpIpService.log(`sony set-contents-transfer-mode no-response` +
        ` answered=0 error=${SonyPtpIpContent.lastModeError}`);
      NikonPtpIpService.logError('sony set-contents-transfer-mode', error as Object);
      return -1;
    }
  }

  /** One-line, log-safe text for a thrown value. */
  private static errorText(error: Object): string {
    const message = (((error as Error).message || String(error) || '') as string)
      .replace(/[\u0000-\u001F\u007F]/g, ' ').substring(0, 120);
    return message.length > 0 ? message : 'unknown';
  }

  /**
   * One `SDIO_GetAllExtDevicePropInfo` round trip: one device-property dump,
   * decoded to `devicePropCode -> current value`.
   *
   * Returns the properties THIS response carried — not the accumulator, so the
   * caller can still tell "this dump failed" from "the session has values" — and
   * registers the response's walk and values through `registerPropDump`.
   * Returns null when the body refused, the data phase was empty, or the payload
   * could not be walked (the reason is logged).
   */
  static async readAllExtDeviceProperties(session: PtpTransport,
    source: string = 'enable-poll'): Promise<Map<number, number> | null> {
    try {
      const params = await SonyPtpIpContent.propertyDumpParams(session);
      const response: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_GET_ALL_EXT_DEVICE_PROP_INFO,
        params,
        true);
      NikonPtpIpService.log(`sony get-all-ext-device-prop-info params=[${params.join(',')}]` +
        ` code=${SonyPtpIpContent.hex(response.code)} bytes=${response.data.length}`);
      if (response.code !== SonyPtpIpContent.RESPONSE_OK || response.data.length === 0) {
        return null;
      }
      const parser = new SonyDevicePropInfoParser(response.data, response.data.length,
        source, `[${params.join(',')}]`);
      const values = parser.parse();
      // The walk's accounting is registered even when `values` is null: it is the
      // evidence that separates "the camera did not send the record" from "we
      // lost it".
      SonyPtpIpContent.registerPropDump(parser, values);
      if (values === null) {
        NikonPtpIpService.log(`sony get-all-ext-device-prop-info unparsed reason=${parser.reason()}` +
          ` walk=${SonyPtpIpContent.describeWalk()}`);
        return null;
      }
      NikonPtpIpService.log(`sony get-all-ext-device-prop-info properties=${values.size}` +
        ` enableFlags=${SonyPtpIpContent.propEnableFlags.size}` +
        ` accumulated=${SonyPtpIpContent.propValues.size}` +
        ` walk=${SonyPtpIpContent.describeWalk()}`);
      return values;
    } catch (error) {
      NikonPtpIpService.logError('sony get-all-ext-device-prop-info', error as Object);
      return null;
    }
  }

  /**
   * Registers one walked `SDIO_GetAllExtDevicePropInfo` payload.
   *
   * Two things happen here, and both exist because one 0x9209 answer is not
   * necessarily the whole property list (see the file header):
   *
   *   1. The walk verdict the browse line reports belongs to the LARGEST payload
   *      walked in the attempt. A later, smaller dump — the camera answering
   *      Sony's refresh parameter form with only the properties that changed —
   *      must never displace the verdict on the payload that spans the property
   *      list the camera declared in 0x9202. The most recent walk is kept
   *      separately as `propLastWalk`; nothing is discarded.
   *   2. The decoded values and `mIsEnable` octets are MERGED into the session
   *      accumulators, which is Sony's own behaviour:
   *      `DevicePropertyUpdater.onDevicePropertyAcquired` takes the first answer
   *      whole and afterwards overwrites only the properties the new answer
   *      contains (`DevicePropertyUpdater.java:58-66`), and every reader —
   *      `DevicePropertyUpdater.get`, `:45-47` — reads that accumulated map.
   *      Without this, a 25-record delta would erase the slot properties that a
   *      351-record dump had already delivered, which is exactly the false
   *      negative the `propSlot1Seen=0 propSlot2Seen=0` line used to produce.
   */
  private static registerPropDump(parser: SonyDevicePropInfoParser,
    values: Map<number, number> | null): void {
    const walk = parser.walk();
    SonyPtpIpContent.propDumps += 1;
    SonyPtpIpContent.propLastWalk = walk;
    const reported = SonyPtpIpContent.propWalk;
    if (reported === null || walk.receivedBytes > reported.receivedBytes) {
      SonyPtpIpContent.propWalk = walk;
    }
    const flags = parser.enableFlagMap();
    flags.forEach((flag: number, code: number): void => {
      SonyPtpIpContent.propEnableFlags.set(code, flag);
    });
    if (values === null) return;
    values.forEach((value: number, code: number): void => {
      SonyPtpIpContent.propValues.set(code, value);
    });
    // The strings travel on the same rule as the numbers: a delta dump that does
    // not carry a property leaves the earlier answer standing.
    parser.stringMap().forEach((text: string, code: number): void => {
      SonyPtpIpContent.propStrings.set(code, text);
    });
    // Same rule again for the option lists, the getSet octets and the data types:
    // a delta dump that omits a property must not erase what an earlier full dump
    // established, because a formFlag-2 list is only ever sent in full.
    parser.optionMap().forEach((options: number[], code: number): void => {
      SonyPtpIpContent.propOptions.set(code, options);
    });
    parser.getSetMap().forEach((octet: number, code: number): void => {
      SonyPtpIpContent.propGetSet.set(code, octet);
    });
    parser.dataTypeMap().forEach((dataType: number, code: number): void => {
      SonyPtpIpContent.propDataTypes.set(code, dataType);
    });
    // One line that settles, on the next device run, whether this body really
    // ships the selectable lists inside 0x9209 and which parameters it declares
    // writable. `opt0` means the record had no enumeration form, and `ro` means
    // `canSet` is false — both are answers, not failures.
    const paramCodes: number[] = [
      SonyPtpIpContent.PROP_F_NUMBER,
      SonyPtpIpContent.PROP_SHUTTER_SPEED,
      SonyPtpIpContent.PROP_EXTENDED_SHUTTER_SPEED,
      SonyPtpIpContent.PROP_ISO_SENSITIVITY,
      SonyPtpIpContent.PROP_EXPOSURE_BIAS_COMPENSATION,
      SonyPtpIpContent.PROP_EXPOSURE_PROGRAM_MODE,
      SonyPtpIpContent.PROP_WHITE_BALANCE,
      SonyPtpIpContent.PROP_FOCUS_MODE,
      SonyPtpIpContent.PROP_STILL_CAPTURE_MODE,
      SonyPtpIpContent.PROP_COMPRESSION_SETTING,
      SonyPtpIpContent.PROP_JPEG_QUALITY,
      SonyPtpIpContent.PROP_COMPRESSION_FILE_FORMAT,
      SonyPtpIpContent.PROP_RAW_FILE_TYPE,
      SonyPtpIpContent.PROP_ASPECT_RATIO,
      SonyPtpIpContent.PROP_MOVIE_RECORDING_STATE,
      SonyPtpIpContent.PROP_REMOTE_CONTROL_RESTRICTION_STATUS
    ];
    const parts: string[] = [];
    paramCodes.forEach((paramCode: number): void => {
      const declared = SonyPtpIpContent.propertyDataType(paramCode);
      // The current raw value is printed too: without it a record that declares
      // options but whose value never lands in the accumulator is
      // indistinguishable from one whose value is simply outside our table,
      // which is exactly the ambiguity the 画质 panel hit.
      const current = SonyPtpIpContent.propertyValue(paramCode);
      parts.push(`0x${paramCode.toString(16).toUpperCase().padStart(4, '0')}` +
        `:${declared === undefined ? 'none' : SonyPtpIpContent.dataTypeText(declared)}` +
        `:opt${SonyPtpIpContent.propertyOptions(paramCode).length}` +
        `:${SonyPtpIpContent.propertyWritable(paramCode) ? 'set' : 'ro'}` +
        `:v=${current === undefined ? '?' : `${current}`}`);
    });
    NikonPtpIpService.log(`sony params ${parts.join(' ')}`);
  }

  /**
   * Whether the camera's own `isEnable` octet for a property is one of the two
   * USABLE values — `EnumIsEnable.True`(1) or `DispOnly`(2)
   * (`property/dataset/EnumIsEnable.java:7-10`), the pair Sony itself tests
   * before it acts on a property.
   *
   * Read from the accumulated 0x9209 map, so this costs no round trip. A code
   * that appears in no dump of this attempt is NOT enabled, and that is correct
   * rather than merely convenient: the walk records the octet for every record
   * it parses, so a missing entry means the camera never sent the property.
   */
  static isPropertyEnabled(code: number): boolean {
    const flag = SonyPtpIpContent.propEnableFlags.get(code);
    return flag === SonyPtpIpContent.IS_ENABLE_TRUE ||
      flag === SonyPtpIpContent.IS_ENABLE_DISP_ONLY;
  }

  /** Last known value of a property from the accumulated 0x9209 map, or
   * undefined when no dump of this attempt carried it. The public counterpart of
   * `propValue`, for callers outside this module that must apply Sony's own
   * enable test. */
  static propertyValue(code: number): number | undefined {
    return SonyPtpIpContent.propValues.get(code);
  }

  /**
   * Whether the body reports it is recording right now.
   *
   * Returns `undefined` when the property was never dumped, which callers must
   * treat as "unknown" rather than "not recording" — guessing here would flip the
   * record button's label the wrong way.
   */
  static movieRecording(): boolean | undefined {
    const raw = SonyPtpIpContent.propValues.get(SonyPtpIpContent.PROP_MOVIE_RECORDING_STATE);
    if (raw === undefined) {
      return undefined;
    }
    return (raw & SonyPtpIpContent.ENABLE_STATUS_MASK) ===
      SonyPtpIpContent.MOVIE_RECORDING_STATE_RECORDING;
  }

  /**
   * The vendor code version the six-step setup read, or -1 when this attempt
   * never got one.
   *
   * Exposed because the control page needs the SAME answer the browse already
   * paid for. `SonyLiveView.propertyFlag` used to issue its own
   * `SDIO_GetVendorCodeVersion` and treat its refusal as "unknown", which sends
   * `SDIO_ControlDevice` one parameter where the body wants two and makes the
   * live-view stream answer 503 — see the comment there.
   */
  static vendorVersion(): number {
    return SonyPtpIpContent.vendorCodeVersion;
  }

  /**
   * Whether this attempt has accumulated ANY device-property record.
   *
   * The accumulator belongs to a browse attempt: `SonyPtpIpContent.close()` —
   * which the camera page runs when you navigate away from it — drops it. The
   * control page must therefore be able to tell "nobody has dumped yet" from
   * "the camera sent nothing", so that it can dump for itself instead of
   * rendering four empty parameter rows and searching an empty table for the
   * live-view URL (observed on the ILCE-7M4 as `aperture=-- … writable=0/4`
   * and `strings=0` in a session whose browse had just parsed 351 records).
   */
  static hasPropertyTable(): boolean {
    return SonyPtpIpContent.propValues.size > 0 || SonyPtpIpContent.propStrings.size > 0;
  }

  /**
   * Records the value a `SDIO_SetExtDevicePropValue` (0x9205) was just told to
   * take, once the camera answered OK.
   *
   * The accumulator is only otherwise filled by `SDIO_GetAllExtDevicePropInfo`
   * (0x9209), which we send once per session, so without this a successful set
   * left the panel showing the OLD value — observed as `sony set aspect …
   * result=8193` (0x2001) followed by `sony-control params … aspect=1` no matter
   * which of the four ratios had been chosen.
   *
   * Sony keeps its own dataset current from the body's
   * `SDIE_DevicePropChanged` event, which this port does not subscribe to yet.
   * Until it does, a value the camera has acknowledged is the best knowledge we
   * have, and it is strictly better than a value the camera has already
   * contradicted.
   */
  static notePropertyWritten(code: number, raw: number): void {
    SonyPtpIpContent.propValues.set(code, raw);
  }

  /** The camera's ordered selectable values for a property (`mGetSetValues`), or
   * an empty list when the camera declared no enumeration for it. Read from the
   * accumulated 0x9209 dump, so no round trip. */
  static propertyOptions(code: number): number[] {
    const options = SonyPtpIpContent.propOptions.get(code);
    return options === undefined ? [] : options;
  }

  /** The `mDataType` of a property as this body declared it, or undefined when no
   * dump carried the record. A 0x9205 set must be sized with this. */
  static propertyDataType(code: number): number | undefined {
    return SonyPtpIpContent.propDataTypes.get(code);
  }

  /**
   * Whether the camera says a property may be WRITTEN — Sony's `canSet`, which is
   * `mIsEnable == True && mGetSet == GetSet`
   * (`ptp/remotecontrol/controller/AbstractController.java:90-93`).
   *
   * Deliberately stricter than `isPropertyEnabled`: `DispOnly` (2) means the
   * camera shows the value but refuses to take it, so a panel must grey the row
   * rather than let the user send a set that will fail.
   */
  static propertyWritable(code: number): boolean {
    const flag = SonyPtpIpContent.propEnableFlags.get(code);
    const getSet = SonyPtpIpContent.propGetSet.get(code);
    return flag === SonyPtpIpContent.IS_ENABLE_TRUE &&
      getSet === SonyPtpIpContent.ENUM_GET_SET;
  }

  /**
   * Whether the camera currently accepts a touch-to-focus/AE operation, by
   * Sony's own two-part test: `isEnable(RemoteTouchOperationEnableStatus)`
   * (`.../liveview/TouchOperationController.java:436-443`, which is the
   * `mIsEnable` octet AND `value & 0xFF == Enable`) followed by
   * `canGet(FunctionOfTouchOperation)` and a value that is not OFF
   * (`:141-152`).
   *
   * A pure read of the accumulated property map, so it costs no round trip — and
   * when it returns false nothing is sent at all, which is what stops a tap on a
   * body without touch AF from becoming a refused operation.
   */
  static touchAfAvailable(): boolean {
    if (!SonyPtpIpContent.isPropertyEnabled(
      SonyPtpIpContent.PROP_REMOTE_TOUCH_ENABLE_STATUS)) {
      return false;
    }
    const status = SonyPtpIpContent.propertyValue(
      SonyPtpIpContent.PROP_REMOTE_TOUCH_ENABLE_STATUS);
    if (status === undefined ||
      (status & SonyPtpIpContent.ENABLE_STATUS_MASK) !== SonyPtpIpContent.ENABLE_STATUS_ENABLE) {
      return false;
    }
    if (!SonyPtpIpContent.isPropertyEnabled(
      SonyPtpIpContent.PROP_FUNCTION_OF_TOUCH_OPERATION)) {
      return false;
    }
    const fn = SonyPtpIpContent.propertyValue(
      SonyPtpIpContent.PROP_FUNCTION_OF_TOUCH_OPERATION);
    return fn !== undefined && fn !== SonyPtpIpContent.FUNCTION_OF_TOUCH_OPERATION_OFF;
  }

  /** Whether the separate cancel button applies
   * (`CancelRemoteTouchOperationEnableStatus`). */
  static cancelTouchAfAvailable(): boolean {
    return SonyPtpIpContent.isPropertyEnabled(
      SonyPtpIpContent.PROP_CANCEL_REMOTE_TOUCH_ENABLE_STATUS);
  }

  /**
   * Last known value of a device property, or undefined when no dump of this
   * attempt carried it: the accumulated map first — Sony's own source, the
   * accumulated `mAllDevicePropInfoDatasets` (`DevicePropertyUpdater.java:45-47`)
   * — and then the dump the caller passed, so a caller holding a fresh map for a
   * dump that was not registered still sees its values.
   */
  private static propValue(values: Map<number, number> | null,
    code: number): number | undefined {
    const accumulated = SonyPtpIpContent.propValues.get(code);
    if (accumulated !== undefined) return accumulated;
    if (values === null) return undefined;
    return values.get(code);
  }

  /**
   * `SDIO_GetVendorCodeVersion` (0x9216) once per browse; the answer decides
   * whether the property dump carries the extra option flag.
   *
   * The version is the first response parameter —
   * `Initializer.java:223-231` reads `list.get(0)` from the operation response —
   * so no data phase is involved. Returns -1 when the camera refuses the
   * operation or answers without a parameter, in which case the dump uses the
   * flag-less form that Sony's `NONE` path sends. Step (S5) of
   * `setupSonySession` normally reads this already; this is the re-try used when
   * the setup never got that far.
   */
  static async readVendorCodeVersion(session: PtpTransport): Promise<number> {
    try {
      const response: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_GET_VENDOR_CODE_VERSION, [], true);
      const version = response.code === SonyPtpIpContent.RESPONSE_OK && response.params.length > 0
        ? response.params[0]
        : -1;
      NikonPtpIpService.log(`sony get-vendor-code-version code=` +
        `${SonyPtpIpContent.hex(response.code)} params=[${response.params.join(',')}]` +
        ` version=${version}`);
      return version;
    } catch (error) {
      NikonPtpIpService.logError('sony get-vendor-code-version', error as Object);
      return -1;
    }
  }

  /**
   * Parameters for one `SDIO_GetAllExtDevicePropInfo`.
   *
   * `DevicePropertyGetter.execute(true, flagOption, ...)` builds
   * `{true ? 1 : 0}` plus the flag value when the option is ENABLE
   * (`DevicePropertyGetter.java:40-44`); the flag is ENABLE from vendor code
   * version 310 on. `true` is the flag's first parameter, which is what Sony
   * sends when it refreshes the dump after `SDIE_DevicePropChanged` — the
   * request this module polls with.
   */
  private static async propertyDumpParams(session: PtpTransport): Promise<number[]> {
    if (!SonyPtpIpContent.vendorCodeVersionFetched) {
      SonyPtpIpContent.vendorCodeVersion = await SonyPtpIpContent.readVendorCodeVersion(session);
      SonyPtpIpContent.vendorCodeVersionFetched = true;
    }
    const params = SonyPtpIpContent.propertyDumpParamsFor(SonyPtpIpContent.vendorCodeVersion);
    SonyPtpIpContent.propDumpParams = `[${params.join(',')}]`;
    return params;
  }

  /**
   * Waits for `ContentsTransferEnableStatus` (53909) to read ENABLE, honouring
   * Sony's 5 second deadline.
   *
   * `ContentsTransferModeSetter.onOperationRequested` treats a plain OK from
   * `SDIO_SetContentsTransferMode` as success only when this property is
   * already ENABLE; otherwise it registers for property changes, starts a 5 s
   * timer, and reports failure when the timer expires
   * (`ptpip/mtp/ContentsTransferModeSetter.java:168-179`, `:91-99`). The value
   * itself comes from the `SDIO_GetAllExtDevicePropInfo` dump that
   * `DevicePropertyUpdater` refreshes on every `SDIE_DevicePropChanged` event
   * (`DevicePropertyUpdater$$ExternalSyntheticLambda0.java:24`), so each attempt
   * here issues exactly the request Sony issues on a change notification.
   *
   * Returns the property snapshot the wait finished on, or null on timeout
   * (every attempt and its value is logged either way).
   */
  static async waitContentsTransferEnabled(session: PtpTransport): Promise<Map<number, number> | null> {
    const started = Date.now();
    const deadline = started + SonyPtpIpContent.CONTENTS_TRANSFER_ENABLE_TIMEOUT_MS;
    let attempt = 0;
    let lastValues: Map<number, number> | null = null;
    while (true) {
      attempt += 1;
      const values = await SonyPtpIpContent.readAllExtDeviceProperties(session);
      if (values !== null) lastValues = values;
      const raw = values === null
        ? undefined
        : values.get(SonyPtpIpContent.PROP_CONTENTS_TRANSFER_ENABLE_STATUS);
      const value = raw === undefined ? -1 : raw;
      SonyPtpIpContent.enablePolls = attempt;
      if (values === null) {
        SonyPtpIpContent.enableDumpFailures += 1;
      } else {
        SonyPtpIpContent.enableLastValue = value;
      }
      NikonPtpIpService.log(`sony contents-transfer-enable poll attempt=${attempt}` +
        ` property=0x${SonyPtpIpContent.PROP_CONTENTS_TRANSFER_ENABLE_STATUS.toString(16).toUpperCase()}` +
        ` value=${value < 0 ? 'absent' : value}` +
        ` elapsed=${Date.now() - started}ms`);
      if (SonyPtpIpContent.isContentsTransferEnabled(value)) {
        NikonPtpIpService.log(`sony contents-transfer-enable enabled attempt=${attempt}` +
          ` elapsed=${Date.now() - started}ms`);
        return values;
      }
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        NikonPtpIpService.log(`sony contents-transfer-enable timeout attempts=${attempt}` +
          ` elapsed=${Date.now() - started}ms` +
          ` last=${lastValues === null ? 'none' : lastValues.size + '-properties'}`);
        return null;
      }
      await SonyPtpIpContent.delay(Math.min(SonyPtpIpContent.CONTENTS_TRANSFER_ENABLE_POLL_MS, remaining));
    }
  }

  /**
   * Picks the media slot the camera says is usable.
   *
   * THE PRIMARY CRITERION IS MEDIA PRESENCE, BY PROPERTY CODE:
   * `MediaSLOT1Status` (53832) / `MediaSLOT2Status` (53846), whose value 1 is
   * `EnumMediaSLOTStatus.OK` (`EnumMediaSLOTStatus$EnumUnboxingLocalUtility
   * .getMValue`, matched with `255 & value`). `ContentsInfoListEnableStatusSlot1`
   * (53716) / `...Slot2` (53717) — the pair `PtpContentsRoot.getContainerCount`
   * reads (`transfer/ptp/PtpContentsRoot.java:324-355`) — is an APP-PERMISSION
   * flag, not a statement that a card is inserted: an ILCE-7M4 has two slots and
   * `slot1=1/en1` is equally true with the card in slot 2. Enabled is `isEnable$2`
   * (`:431-440`): the property's own `isEnable` octet must be True(1) or
   * DispOnly(2), and `(currentValue & 0xFF)` must equal
   * `EnumOperationEnableStatus` Enable, whose mValue is 1 — the low-byte mask is
   * part of `EnumOperationEnableStatus$EnumUnboxingLocalUtility._valueOf`, so
   * comparing the whole value against 1 is NOT the same test.
   *
   * Decision order:
   *   1. exactly one slot reports media OK        -> that slot
   *      (`media-ok-slot1` / `media-ok-slot2`)
   *   2. both report media OK                     -> SLOT1, Sony's own preference
   *      when both are usable (`media-ok-both-prefer-slot1`)
   *   3. neither status was delivered             -> the permission-flag decision
   *      below, unchanged (`slot1` / `slot2` / `both-enabled-prefer-slot1` /
   *      `neither-enabled-probe-slot1`)
   *   4. status was delivered and neither is OK   -> the same permission-flag
   *      decision, prefixed `media-none-ok-`, so a body that reports no usable
   *      card anywhere is never confused with one that reports nothing.
   * The permission flags therefore remain the precondition and the fallback they
   * always were; they are no longer the sole criterion. Both slots are probed
   * with retries immediately after this (`readCapturedDates`), so even a wrong
   * pick cannot decide the browse on its own.
   *
   * `values` is the dump the caller just read, but all four properties are
   * resolved through `propValue`, i.e. against the accumulated property map of
   * the attempt. That is Sony's own source too: `isEnable$2` tests
   * `DevicePropertyOperation.isSupported(code)` and the value out of the
   * accumulated `mAllDevicePropInfoDatasets`, never out of one particular
   * response, so a property delivered by the full dump stays usable when a later
   * refresh answer carries only the properties that changed.
   */
  static pickSlotNumber(values: Map<number, number> | null): number {
    // Read from the accumulated map first: the slot properties belong to the
    // camera's full property list, and the poll that produced `values` may be a
    // delta that does not carry them at all (`registerPropDump`).
    const slot1 = SonyPtpIpContent.propValue(values,
      SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_ENABLE_SLOT1);
    const slot2 = SonyPtpIpContent.propValue(values,
      SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_ENABLE_SLOT2);
    const slot1Flag = SonyPtpIpContent.propEnableFlag(
      SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_ENABLE_SLOT1);
    const slot2Flag = SonyPtpIpContent.propEnableFlag(
      SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_ENABLE_SLOT2);
    SonyPtpIpContent.slot1Value = slot1 === undefined ? -1 : slot1;
    SonyPtpIpContent.slot2Value = slot2 === undefined ? -1 : slot2;
    SonyPtpIpContent.slot1EnableFlag = slot1Flag;
    SonyPtpIpContent.slot2EnableFlag = slot2Flag;
    const slot1Enabled = SonyPtpIpContent.isSlotEnabled(slot1, slot1Flag);
    const slot2Enabled = SonyPtpIpContent.isSlotEnabled(slot2, slot2Flag);
    // Media presence, read BY CODE from the same accumulated map as everything
    // else. `undefined` means no dump of this attempt carried that code, which is
    // reported as `absent` rather than silently treated as "no card".
    const mediaSlot1 = SonyPtpIpContent.propValue(values,
      SonyPtpIpContent.PROP_MEDIA_SLOT1_STATUS);
    const mediaSlot2 = SonyPtpIpContent.propValue(values,
      SonyPtpIpContent.PROP_MEDIA_SLOT2_STATUS);
    const playbackMedia = SonyPtpIpContent.propValue(values,
      SonyPtpIpContent.PROP_PLAYBACK_MEDIA);
    const mediaSlot1Ok = SonyPtpIpContent.isMediaSlotOk(mediaSlot1);
    const mediaSlot2Ok = SonyPtpIpContent.isMediaSlotOk(mediaSlot2);
    let slot = SonyPtpIpContent.SLOT_1;
    let reason = 'slot1';
    if (mediaSlot1Ok && mediaSlot2Ok) {
      // Both cards usable: SLOT1 wins. This is the one case where the old
      // both-enabled preference and the media report agree by construction.
      slot = SonyPtpIpContent.SLOT_1;
      reason = 'media-ok-both-prefer-slot1';
    } else if (mediaSlot1Ok) {
      slot = SonyPtpIpContent.SLOT_1;
      reason = 'media-ok-slot1';
    } else if (mediaSlot2Ok) {
      slot = SonyPtpIpContent.SLOT_2;
      reason = 'media-ok-slot2';
    } else {
      // Neither slot reports media OK: either the camera did not deliver the
      // status properties at all (`mediaSlot1`/`mediaSlot2` both undefined) or it
      // did and no slot holds a usable card. Both cases fall back to the
      // permission flags — the precondition this module has always used — and the
      // reason keeps the two apart.
      let fallbackSlot = SonyPtpIpContent.SLOT_1;
      let fallbackReason = 'slot1';
      if (slot1Enabled && !slot2Enabled) {
        fallbackSlot = SonyPtpIpContent.SLOT_1;
      } else if (!slot1Enabled && slot2Enabled) {
        fallbackSlot = SonyPtpIpContent.SLOT_2;
        fallbackReason = 'slot2';
      } else if (slot1Enabled && slot2Enabled) {
        fallbackReason = 'both-enabled-prefer-slot1';
      } else {
        // Absence only means "the camera did not offer the slot" when the walk
        // consumed the payload exactly; otherwise the record may simply have been
        // lost after a desync, and the reason says so instead of blaming the body.
        const walk = SonyPtpIpContent.propWalk;
        const walkResult = walk === null ? 'none' : walk.result;
        fallbackReason = SonyPtpIpContent.propWalkClean()
          ? 'neither-enabled-probe-slot1'
          : `neither-enabled-walk-${walkResult}-probe-slot1`;
      }
      slot = fallbackSlot;
      reason = (mediaSlot1 === undefined && mediaSlot2 === undefined)
        ? fallbackReason
        : `media-none-ok-${fallbackReason}`;
    }
    SonyPtpIpContent.slotReason = reason;
    NikonPtpIpService.log(`sony slot slot1=${slot1 === undefined ? 'absent' : slot1}` +
      `/en${slot1Flag} slot2=${slot2 === undefined ? 'absent' : slot2}/en${slot2Flag}` +
      ` chosen=${slot} reason=${reason}` +
      ` mediaSlot1=${SonyPtpIpContent.describeMediaValue(mediaSlot1, true)}` +
      ` mediaSlot2=${SonyPtpIpContent.describeMediaValue(mediaSlot2, true)}` +
      ` playbackMedia=${SonyPtpIpContent.describeMediaValue(playbackMedia, false)}` +
      ` mediaOk=${mediaSlot1Ok ? 1 : 0}${mediaSlot2Ok ? 1 : 0}` +
      ` walk=${SonyPtpIpContent.describeWalk()}` +
      ` extPropCount=${SonyPtpIpContent.extPropCount}` +
      ` extPropHasSlot1=${SonyPtpIpContent.extPropHasSlot1}` +
      ` extPropHasSlot2=${SonyPtpIpContent.extPropHasSlot2}` +
      ` extPropHasEnable=${SonyPtpIpContent.extPropHasEnableStatus}` +
      ` extPropHasMedia=${SonyPtpIpContent.extPropHasMediaSlot1}` +
      `${SonyPtpIpContent.extPropHasMediaSlot2}` +
      `${SonyPtpIpContent.extPropHasPlaybackMedia}` +
      ` mask=0x${SonyPtpIpContent.OPERATION_ENABLE_STATUS_MASK.toString(16).toUpperCase()}`);
    return slot;
  }

  /**
   * `EnumMediaSLOTStatus` name for a raw property value, so the log carries the
   * meaning beside the number: 1 = OK, 2 = NoCard, 3 = CardError,
   * 4 = CardRecognizing/DbError, anything else the raw (masked) number.
   *
   * The names are Sony's own — `EnumMediaSLOTStatus$EnumUnboxingLocalUtility
   * .getMString` (`property/value/EnumMediaSLOTStatus$EnumUnboxingLocalUtility
   * .java:19-36`) — and the lookup is the same `255 & value` that class's
   * `_valueOf` performs (`:9-17`).
   */
  static mediaSlotStatusText(value: number): string {
    const masked = value & SonyPtpIpContent.MEDIA_VALUE_MASK;
    if (masked === SonyPtpIpContent.MEDIA_SLOT_STATUS_OK) return 'OK';
    if (masked === SonyPtpIpContent.MEDIA_SLOT_STATUS_NO_CARD) return 'NoCard';
    if (masked === SonyPtpIpContent.MEDIA_SLOT_STATUS_CARD_ERROR) return 'CardError';
    if (masked === SonyPtpIpContent.MEDIA_SLOT_STATUS_RECOGNIZING) {
      return 'CardRecognizing/DbError';
    }
    return `${masked}`;
  }

  /** `EnumPlaybackMedia` name for a raw property value: 0 = UNDEF, 1 = SLOT1,
   * 2 = SLOT2 (`base/transaction/EnumPlaybackMedia.java:22-26`; `Companion
   * .valueOf` matches with `255 & value`, `:33-41`). */
  static playbackMediaText(value: number): string {
    const masked = value & SonyPtpIpContent.MEDIA_VALUE_MASK;
    if (masked === SonyPtpIpContent.PLAYBACK_MEDIA_UNDEFINED) return 'UNDEF';
    if (masked === SonyPtpIpContent.PLAYBACK_MEDIA_SLOT1) return 'SLOT1';
    if (masked === SonyPtpIpContent.PLAYBACK_MEDIA_SLOT2) return 'SLOT2';
    return `${masked}`;
  }

  /** One media property as `<value>/<meaning>`, or `absent` when no dump of this
   * attempt carried the code. `slotStatus` picks the `EnumMediaSLOTStatus` names
   * over the `EnumPlaybackMedia` ones. */
  private static describeMediaValue(value: number | undefined, slotStatus: boolean): string {
    if (value === undefined) return 'absent';
    const text = slotStatus
      ? SonyPtpIpContent.mediaSlotStatusText(value)
      : SonyPtpIpContent.playbackMediaText(value);
    return `${value}/${text}`;
  }

  /** `EnumMediaSLOTStatus` OK (raw 1, matched with `255 & value`). `undefined`
   * — the code was in no dump of this attempt — is never OK. */
  private static isMediaSlotOk(value: number | undefined): boolean {
    if (value === undefined) return false;
    return (value & SonyPtpIpContent.MEDIA_VALUE_MASK) === SonyPtpIpContent.MEDIA_SLOT_STATUS_OK;
  }

  /** True for every property code the media report is read from, so the walk's
   * per-code record list (`SonyPropWalk.mediaRecords`) and the media-aware slot
   * decision can never disagree about which codes matter. Public because
   * `SonyDevicePropInfoParser` calls it while walking a dump. */
  static isMediaPropCode(code: number): boolean {
    return code === SonyPtpIpContent.PROP_PLAYBACK_MEDIA ||
      code === SonyPtpIpContent.PROP_MEDIA_SLOT1_STATUS ||
      code === SonyPtpIpContent.PROP_MEDIA_SLOT2_STATUS ||
      code === SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_UPDATE_TIME_SLOT1 ||
      code === SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_UPDATE_TIME_SLOT2;
  }

  /** `DevicePropInfoDataset.mIsEnable` of a property from the latest dump, or -1
   * when that property was not in it. */
  private static propEnableFlag(code: number): number {
    const flag = SonyPtpIpContent.propEnableFlags.get(code);
    return flag === undefined ? -1 : flag;
  }

  /**
   * The reported property walk's accounting as one log-safe string.
   *
   * This is the field set that settles the camera-versus-parser question in ONE
   * device run: `result=clean` together with `slot1Seen=0 slot2Seen=0` means the
   * camera genuinely did not send 53716/53717, while `result=short` (or
   * `overrun` / `bad-type`) means the walk desynchronised and their absence
   * proves nothing at all.
   *
   * `bytes` is `consumed/received`: the consumed count is the parser's own
   * progress (`DevicePropInfoDataset.java`'s `position()`) and the received count
   * is the data-phase length the transport delivered for that very response
   * (`NikonPtpIpService.ets:1401-1410`), which is the quantity Sony's
   * `byteBuffer.capacity()` stands for. `covers` is the walked record count
   * against the camera's own property count from 0x9202, so a walk over a
   * 25-record delta can never be read as a verdict on the 351-property list.
   */
  private static describeWalk(): string {
    const walk = SonyPtpIpContent.propWalk;
    if (walk === null) return 'none';
    return `result=${walk.result}` +
      ` source=${walk.source}` +
      ` params=${walk.params}` +
      ` records=${walk.records}/${walk.declaredRecords}` +
      ` bytes=${walk.consumedBytes}/${walk.receivedBytes}` +
      ` handed=${walk.handedBytes}` +
      ` covers=${walk.records}/${SonyPtpIpContent.extPropCount}` +
      ` slot1Seen=${walk.slot1Seen ? 1 : 0}@${walk.slot1Offset}:${walk.slot1Type}` +
      ` slot2Seen=${walk.slot2Seen ? 1 : 0}@${walk.slot2Offset}:${walk.slot2Type}` +
      ` mediaRecords=${walk.mediaRecords}` +
      ` badType=${walk.firstBadType}` +
      ` arrayTypes=${walk.arrayTypes}` +
      ` last=${SonyPtpIpContent.hex(walk.lastRecordCode)}/${walk.lastRecordType}` +
      `+#${walk.lastRecordOffset}:${walk.lastRecordBytes}`;
  }

  /** True only when the reported 0x9209 walk — the one over the largest payload
   * of the attempt, i.e. the payload that spans the property list the camera
   * declared in 0x9202 — landed exactly on that payload's received length, which
   * is the condition Sony itself asserts before it trusts the dataset
   * (`DevicePropInfoDataset.java:268-271`). Anything else means every property
   * missing from that walk may have been lost rather than absent. */
  private static propWalkClean(): boolean {
    const walk = SonyPtpIpContent.propWalk;
    return walk !== null && walk.result === 'clean';
  }

  /** `PtpContentsRoot.isEnable$2` (`transfer/ptp/PtpContentsRoot.java:431-440`):
   * `isEnable` must be True(1) or DispOnly(2), and the current value's LOW BYTE
   * must be `EnumOperationEnableStatus` Enable (= 1,
   * `EnumOperationEnableStatus$EnumUnboxingLocalUtility.getMValue`/`_valueOf`
   * mask with 0xFF). */
  private static isSlotEnabled(value: number | undefined, enableFlag: number): boolean {
    if (value === undefined) return false;
    if (enableFlag !== SonyPtpIpContent.IS_ENABLE_TRUE &&
      enableFlag !== SonyPtpIpContent.IS_ENABLE_DISP_ONLY) {
      return false;
    }
    return (value & SonyPtpIpContent.OPERATION_ENABLE_STATUS_MASK) ===
      SonyPtpIpContent.PROPERTY_VALUE_ENABLE;
  }

  /** `EnumContentsTransferEnableStatus.Companion.valueOf`: the low 16 bits of
   * the current value, ENABLE = 1 (`EnumContentsTransferEnableStatus.java:23-40`).
   * `value` is -1 when the property was absent, which never matches. */
  private static isContentsTransferEnabled(value: number): boolean {
    if (value < 0) return false;
    return (value & SonyPtpIpContent.CONTENTS_TRANSFER_ENABLE_STATUS_MASK) ===
      SonyPtpIpContent.PROPERTY_VALUE_ENABLE;
  }

  /**
   * The systematic `SDIO_GetCapturedDateList` (0x923B) sweep.
   *
   * Parameters are `{slot}` — one u32, nothing else: `new int[]{slot.value}`
   * (`ptpip/BasePtpManager.java:1020`), `EnumDataPhaseInfo.NoDataOrDataInPhase`,
   * and the payload is the DATA PHASE, a u32 count followed by that many u64
   * dates read little-endian
   * (`contentstransfer/CapturedDateListGetter.java:50-101`, whose only source of
   * bytes is `progressChanged`). Each date is kept as its exact two 32-bit halves
   * because it is sent straight back to the camera as the createTime of a page
   * request.
   *
   * Order: the slot `pickSlotNumber` chose first, then the other one, and EACH
   * slot gets `DATE_TRY_ATTEMPTS` attempts with `DATE_TRY_RETRY_DELAY_MS` between
   * them. Every attempt is logged as its own `dateTry slot=N attempt=M code=0x...`
   * line and recorded in `dateTries`, because the two things this step must
   * settle are exactly (i) which slot answers and (ii) whether a refusal is
   * stable or transient — a single shot cannot separate them, and the previous
   * one-shot fallback could not either.
   *
   * An OK answer with count 0 is the camera saying "this card has no captured
   * date" and is returned as such (`dates` is an empty array, not null); only a
   * non-OK code or an unusable payload counts as a failed attempt. The slot that
   * answers becomes `slotNumber`, i.e. the slot every subsequent page request
   * uses, so a pick that media status got wrong cannot poison the pages.
   *
   * Returns null when every attempt on both slots failed; an empty array means
   * the camera listed no captured date at all.
   */
  static async readCapturedDates(session: PtpTransport,
    slotNumber: number): Promise<SonyU64[] | null> {
    SonyPtpIpContent.lastDateSlot = slotNumber;
    SonyPtpIpContent.dateTries = '-';
    const other = slotNumber === SonyPtpIpContent.SLOT_1
      ? SonyPtpIpContent.SLOT_2
      : SonyPtpIpContent.SLOT_1;
    const order: number[] = [slotNumber, other];
    let decisive = true;
    for (const slot of order) {
      for (let attempt = 1; attempt <= SonyPtpIpContent.DATE_TRY_ATTEMPTS; attempt++) {
        const answer = await SonyPtpIpContent.requestCapturedDates(session, slot);
        SonyPtpIpContent.recordDateTry(slot, attempt, answer);
        NikonPtpIpService.log(`sony get-captured-date-list dateTry slot=${slot}` +
          ` attempt=${attempt}/${SonyPtpIpContent.DATE_TRY_ATTEMPTS}` +
          ` code=${SonyPtpIpContent.hex(answer.code)}` +
          ` paramsOut=[${answer.params.join(',')}] bytes=${answer.bytes}` +
          ` count=${answer.count} ok=${answer.dates !== null ? 1 : 0}` +
          ` slotReason=${SonyPtpIpContent.slotReason}`);
        if (decisive) {
          // The browse line's single-shot fields describe the DECISIVE request:
          // the first attempt on the slot the picker chose, which is what the
          // failure message quotes.
          SonyPtpIpContent.lastDateCode = answer.code;
          SonyPtpIpContent.lastDateParams = `[${answer.params.join(',')}]`;
          SonyPtpIpContent.lastDateBytes = answer.bytes;
          SonyPtpIpContent.lastDateCount = answer.count;
          decisive = false;
        }
        if (answer.dates !== null) {
          SonyPtpIpContent.lastDateSlotAnswered = slot;
          // The pages must use the slot that answered, not the one that refused.
          SonyPtpIpContent.slotNumber = slot;
          if (slot !== slotNumber || attempt > 1) {
            NikonPtpIpService.log('sony get-captured-date-list answered' +
              ` slot=${slot} attempt=${attempt} askedFirst=${slotNumber}` +
              ` switched=${slot !== slotNumber ? 1 : 0}` +
              ` count=${answer.count} reason=${SonyPtpIpContent.slotReason}`);
          }
          return answer.dates;
        }
        if (attempt < SonyPtpIpContent.DATE_TRY_ATTEMPTS) {
          NikonPtpIpService.log('sony get-captured-date-list retry' +
            ` slot=${slot} attempt=${attempt} code=${SonyPtpIpContent.hex(answer.code)}` +
            ` waitMs=${SonyPtpIpContent.DATE_TRY_RETRY_DELAY_MS}` +
            ` remaining=${SonyPtpIpContent.DATE_TRY_ATTEMPTS - attempt}`);
          await SonyPtpIpContent.delay(SonyPtpIpContent.DATE_TRY_RETRY_DELAY_MS);
        }
      }
      NikonPtpIpService.log(`sony get-captured-date-list slot-exhausted slot=${slot}` +
        ` attempts=${SonyPtpIpContent.DATE_TRY_ATTEMPTS}` +
        ` otherSlot=${slot === SonyPtpIpContent.SLOT_1
          ? SonyPtpIpContent.SLOT_2 : SonyPtpIpContent.SLOT_1}`);
    }
    NikonPtpIpService.log('sony get-captured-date-list all-slots-refused' +
      ` askedFirst=${slotNumber} tries=${SonyPtpIpContent.dateTries}` +
      ` slotReason=${SonyPtpIpContent.slotReason}` +
      ` mediaSlot1=${SonyPtpIpContent.describeMediaValue(
        SonyPtpIpContent.propValue(null, SonyPtpIpContent.PROP_MEDIA_SLOT1_STATUS), true)}` +
      ` mediaSlot2=${SonyPtpIpContent.describeMediaValue(
        SonyPtpIpContent.propValue(null, SonyPtpIpContent.PROP_MEDIA_SLOT2_STATUS), true)}`);
    return null;
  }

  /** Appends one 0x923B attempt to the per-browse sweep record as
   * `slot#attempt:code`, so `dateTries` reads like `1#1:0xA106,1#2:0xA106,...`.
   * The code is the raw response code; `hex` renders a thrown round trip as
   * `none`, which must stay distinguishable from a camera-issued code. */
  private static recordDateTry(slot: number, attempt: number, answer: SonyDateAnswer): void {
    const entry = `${slot}#${attempt}:${SonyPtpIpContent.hex(answer.code)}`;
    SonyPtpIpContent.dateTries = SonyPtpIpContent.dateTries === '-'
      ? entry : `${SonyPtpIpContent.dateTries},${entry}`;
  }

  /** One raw `SDIO_GetCapturedDateList` request. Never throws: a broken round
   * trip is reported as `code = -1` with an empty parameter list, and every
   * answer carries its response code, response-parameter list and payload size
   * so a refusal can be told apart from an answer whose payload moved elsewhere. */
  private static async requestCapturedDates(session: PtpTransport,
    slotNumber: number): Promise<SonyDateAnswer> {
    try {
      const response: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_GET_CAPTURED_DATE_LIST,
        [slotNumber],
        true);
      const data = response.data;
      const shown = Math.min(data.length, 24);
      NikonPtpIpService.log(`sony get-captured-date-list slot=${slotNumber}` +
        ` op=${SonyPtpIpContent.hex(SonyPtpIpContent.OP_GET_CAPTURED_DATE_LIST)}` +
        ` params=[${slotNumber}] code=${SonyPtpIpContent.hex(response.code)}` +
        ` paramsOut=[${response.params.join(',')}] bytes=${data.length}` +
        ` head=${shown > 0 ? SonyPtpIpContent.hexBytes(data, shown) : '-'}`);
      if (response.code !== SonyPtpIpContent.RESPONSE_OK) {
        return { code: response.code, params: response.params, bytes: data.length, count: -1, dates: null };
      }
      if (data.length < 4) {
        NikonPtpIpService.log('sony get-captured-date-list empty payload');
        return { code: response.code, params: response.params, bytes: data.length, count: -1, dates: null };
      }
      const count = NikonPtpIpService.readU32(data, 0);
      if (count > SonyPtpIpContent.MAX_CAPTURED_DATES || count * 8 + 4 > data.length) {
        NikonPtpIpService.log(`sony get-captured-date-list implausible count=${count}` +
          ` bytes=${data.length}`);
        return { code: response.code, params: response.params, bytes: data.length, count: count, dates: null };
      }
      const dates: SonyU64[] = [];
      for (let index = 0; index < count; index++) {
        const offset = 4 + index * 8;
        dates.push({
          low: NikonPtpIpService.readU32(data, offset),
          high: NikonPtpIpService.readU32(data, offset + 4),
        });
      }
      const logged = Math.min(dates.length, 12);
      for (let index = 0; index < logged; index++) {
        NikonPtpIpService.log(`sony get-captured-date-list date[${index}]=` +
          `${dates[index].high}:${dates[index].low} value=` +
          `${SonyPtpIpContent.u64ToNumber(dates[index])}`);
      }
      NikonPtpIpService.log(`sony get-captured-date-list count=${dates.length}` +
        (dates.length > logged ? ` (first ${logged} logged)` : ''));
      return { code: response.code, params: response.params, bytes: data.length, count: count, dates: dates };
    } catch (error) {
      NikonPtpIpService.log(`sony get-captured-date-list slot=${slotNumber} code=none` +
        ` error=${SonyPtpIpContent.errorText(error as Object)}`);
      NikonPtpIpService.logError('sony get-captured-date-list', error as Object);
      return { code: -1, params: [], bytes: 0, count: -1, dates: null };
    }
  }

  /**
   * One `SDIO_GetContentsInfoList` round trip. `createTime` is handed back to
   * the camera verbatim as the two 32-bit halves Sony expects.
   * Returns null when the body refused or the data phase was unusable.
   */
  static async readPage(session: PtpTransport, createTime: SonyU64, count: number,
    slotNumber: number): Promise<SonyContentPage | null> {
    try {
      const response: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_GET_CONTENTS_INFO_LIST,
        [
          createTime.low,
          createTime.high,
          count,
          slotNumber,
          SonyPtpIpContent.ORDER_FLAG,
        ],
        true);
      SonyPtpIpContent.lastPageCode = response.code;
      SonyPtpIpContent.lastPageBytes = response.data.length;
      NikonPtpIpService.log(`sony get-contents-info-list createTime=${createTime.high}:${createTime.low}` +
        ` value=${SonyPtpIpContent.u64ToNumber(createTime)}` +
        ` count=${count} slot=${slotNumber} code=${SonyPtpIpContent.hex(response.code)}` +
        ` bytes=${response.data.length}`);
      if (response.code !== SonyPtpIpContent.RESPONSE_OK || response.data.length === 0) {
        return null;
      }
      const page = new SonyContentListParser(response.data).parse();
      // Side-effect only: remember how to address each file on a later
      // contents-data request. It does not alter the page, the cursor or any
      // other part of the walk.
      SonyPtpIpContent.rememberServed(page.entries, slotNumber);
      return page;
    } catch (error) {
      SonyPtpIpContent.lastPageCode = -1;
      SonyPtpIpContent.lastPageBytes = 0;
      NikonPtpIpService.logError('sony get-contents-info-list', error as Object);
      return null;
    }
  }

  /**
   * Low-level walk of the contents list, page by page.
   *
   * NOT the browse path the image-transfer page uses: this helper performs none
   * of Sony's preconditions (no `ContentsTransferEnableStatus` wait, no
   * `SDIO_GetCapturedDateList`, no slot selection) and therefore starts from
   * createTime 0. `open`/`next` is the path that follows Sony's real sequence
   * and seeds the first page from a reported captured date; this one exists only
   * for callers that have already established contents-transfer mode and only
   * want a raw sweep.
   *
   * Paging is Sony's own: the next request carries the previous page's last
   * `creationDateTimeLocalTime`. The loop stops on an empty page, on a short
   * page (fewer than `pageSize` entries means the list ended), when a page
   * repeats the previous page's first timestamp, or when the cursor fails to
   * advance — in which case Sony bumps it by one.
   */
  static async enumerateContents(session: PtpTransport,
    options?: SonyEnumerateOptions): Promise<SonyContentEntry[]> {
    let pageSize = SonyPtpIpContent.PAGE_SIZE;
    let slotNumber = SonyPtpIpContent.DEFAULT_SLOT_NUMBER;
    let maxPages = SonyPtpIpContent.MAX_PAGES;
    let maxEntries = 0;
    if (options !== undefined) {
      if (options.pageSize !== undefined && options.pageSize > 0) pageSize = Math.floor(options.pageSize);
      if (options.slotNumber !== undefined && options.slotNumber > 0) slotNumber = Math.floor(options.slotNumber);
      if (options.maxPages !== undefined && options.maxPages > 0) maxPages = Math.floor(options.maxPages);
      if (options.maxEntries !== undefined && options.maxEntries > 0) maxEntries = Math.floor(options.maxEntries);
    }

    const collected: SonyContentEntry[] = [];
    let cursor: SonyU64 = { low: 0, high: 0 };
    let previousFirst: SonyU64 | null = null;
    for (let pageIndex = 0; pageIndex < maxPages; pageIndex++) {
      const page = await SonyPtpIpContent.readPage(session, cursor, pageSize, slotNumber);
      if (page === null) {
        NikonPtpIpService.log(`sony enumerate stopped page=${pageIndex} reason=no-page`);
        break;
      }
      if (page.entries.length === 0) {
        NikonPtpIpService.log(`sony enumerate stopped page=${pageIndex} reason=empty`);
        break;
      }
      let full = true;
      for (const entry of page.entries) {
        collected.push(entry);
        if (maxEntries > 0 && collected.length >= maxEntries) {
          full = false;
          break;
        }
      }
      if (!full) break;
      if (previousFirst !== null &&
        previousFirst.low === page.firstTime.low && previousFirst.high === page.firstTime.high) {
        NikonPtpIpService.log(`sony enumerate stopped page=${pageIndex} reason=cursor-stalled`);
        break;
      }
      previousFirst = page.firstTime;
      if (page.entries.length < pageSize) break;
      let next: SonyU64 = page.lastTime;
      if (next.low === page.firstTime.low && next.high === page.firstTime.high) {
        // A whole page stamped with one local time cannot advance on its own;
        // Sony's browser bumps the cursor by one here.
        next = SonyPtpIpContent.incrementU64(next);
      }
      if (next.low === cursor.low && next.high === cursor.high) {
        NikonPtpIpService.log(`sony enumerate stopped page=${pageIndex} reason=cursor-not-advancing`);
        break;
      }
      cursor = next;
    }
    NikonPtpIpService.log(`sony enumerate entries=${collected.length}`);
    return collected;
  }

  // --- Day / page pump shared by open() and next() -------------------------

  /**
   * Consumes one `SDIO_GetContentsInfoList` page for the current day.
   *
   * Returns false only when the request itself failed (no page at all); a page
   * that ends the day — empty, short, or crossing the day's upper bound —
   * returns true after moving on.
   *
   * The end-of-day rule is Sony's own, re-verified: `PtpItemList` stops when
   * `contents.size() != 100 || nextCreationDate <= 0`
   * (`transfer/ptp/PtpItemList.java:152`), i.e. a page that is NOT a full 100
   * ends the day — that is the `!full` branch below. The separate upper-bound
   * test reproduces the other half of Sony's rule: when a content's
   * `creationDateTimeLocalTime` stops matching the container's date, Sony stops
   * the day and drops it (`transfer/ptp/PtpItemList.java:183-186`). Because the
   * days are walked most-recent-first, the date that ends a day is the one
   * already collected at `dayStopUpper`, and the page's next cursor is the last
   * accepted content's own timestamp (`transfer/ptp/PtpItemList.java:208`),
   * with Sony's whole-page-same-timestamp bump (`:157-159`) kept below.
   */
  private static async consumePage(session: PtpTransport): Promise<boolean> {
    const page = await SonyPtpIpContent.readPage(session, SonyPtpIpContent.cursor,
      SonyPtpIpContent.PAGE_SIZE, SonyPtpIpContent.slotNumber);
    SonyPtpIpContent.dayPages += 1;
    SonyPtpIpContent.totalPages += 1;
    if (SonyPtpIpContent.totalPages === 1) {
      // The first request of the attempt is the decisive one.
      SonyPtpIpContent.firstPageRequested = true;
      SonyPtpIpContent.firstPageCode = SonyPtpIpContent.lastPageCode;
      SonyPtpIpContent.firstPageBytes = SonyPtpIpContent.lastPageBytes;
      SonyPtpIpContent.firstPageCreateTime = SonyPtpIpContent.cursor;
      if (page === null) {
        SonyPtpIpContent.firstPageStop = 'no-page';
      } else {
        SonyPtpIpContent.firstPageDeclared = page.declaredCount;
        SonyPtpIpContent.firstPageParsed = page.parsedContentCount;
        SonyPtpIpContent.firstPageStop = SonyPtpIpContent.pageStopReason(page);
      }
    }
    if (page === null) {
      NikonPtpIpService.log(`sony enumerate stopped day=${SonyPtpIpContent.dayIndex}` +
        ` reason=no-page code=${SonyPtpIpContent.hex(SonyPtpIpContent.lastPageCode)}` +
        ` bytes=${SonyPtpIpContent.lastPageBytes}`);
      SonyPtpIpContent.pageFailure = true;
      SonyPtpIpContent.exhausted = true;
      return false;
    }
    if (page.entries.length === 0) {
      NikonPtpIpService.log(`sony enumerate day=${SonyPtpIpContent.dayIndex} reason=empty-page`);
      SonyPtpIpContent.advanceDay();
      return true;
    }
    let accepted = 0;
    let reachedUpperBound = false;
    for (const entry of page.entries) {
      if (SonyPtpIpContent.dayStopUpper !== null &&
        SonyPtpIpContent.compareU64(entry.creationTime, SonyPtpIpContent.dayStopUpper) >= 0) {
        reachedUpperBound = true;
        break;
      }
      SonyPtpIpContent.buffer.push(entry);
      accepted += 1;
    }
    SonyPtpIpContent.discovered += accepted;
    NikonPtpIpService.log(`sony enumerate day=${SonyPtpIpContent.dayIndex}` +
      ` page=${SonyPtpIpContent.dayPages} received=${page.entries.length} accepted=${accepted}` +
      ` declared=${page.declaredCount} discovered=${SonyPtpIpContent.discovered}` +
      ` firstValue=${SonyPtpIpContent.u64ToNumber(page.firstTime)}` +
      ` lastValue=${SonyPtpIpContent.u64ToNumber(page.lastTime)}` +
      (reachedUpperBound ? ' boundary=upper' : '') +
      (page.truncated ? ' truncated=1' : '') +
      (page.stoppedAtUnknownContentType ? ' stopped=unknown-content-type' : '') +
      (page.implausibleCount ? ' stopped=implausible-count' : ''));
    const full = page.entries.length >= SonyPtpIpContent.PAGE_SIZE;
    if (!full || reachedUpperBound) {
      SonyPtpIpContent.advanceDay();
      return true;
    }
    let following: SonyU64 = page.lastTime;
    if (SonyPtpIpContent.sameU64(following, page.firstTime)) {
      // A whole page stamped with one local time cannot advance on its own;
      // Sony's browser bumps the cursor by one here
      // (`transfer/ptp/PtpItemList.java:157-159`).
      following = SonyPtpIpContent.incrementU64(following);
    }
    if (SonyPtpIpContent.sameU64(following, SonyPtpIpContent.cursor)) {
      NikonPtpIpService.log(`sony enumerate day=${SonyPtpIpContent.dayIndex}` +
        ' reason=cursor-not-advancing');
      SonyPtpIpContent.advanceDay();
      return true;
    }
    SonyPtpIpContent.cursor = following;
    if (SonyPtpIpContent.dayPages >= SonyPtpIpContent.MAX_PAGES) {
      NikonPtpIpService.log(`sony enumerate day=${SonyPtpIpContent.dayIndex} reason=day-page-guard`);
      SonyPtpIpContent.advanceDay();
    }
    return true;
  }

  /**
   * Moves to the next captured date, or ends the walk. Each date is used as the
   * createTime of its first page, which is what Sony's per-container browse does
   * (`PtpPullContainer` -> `PtpItemList.capturedDate` -> `getContentsInfoList`).
   *
   * This is also the ONLY place that opens the walk's "more work" latch. See the
   * comment on the assignment below: `pump` reads `exhausted` — and nothing else
   * — to decide whether `SDIO_GetContentsInfoList` (0x923C) is sent at all.
   */
  private static advanceDay(): void {
    SonyPtpIpContent.dayIndex += 1;
    SonyPtpIpContent.dayPages = 0;
    if (SonyPtpIpContent.dayIndex >= SonyPtpIpContent.dayDates.length) {
      NikonPtpIpService.log(`sony enumerate days done=${SonyPtpIpContent.dayDates.length}` +
        ` entries=${SonyPtpIpContent.discovered}`);
      SonyPtpIpContent.exhausted = true;
      return;
    }
    SonyPtpIpContent.cursor = SonyPtpIpContent.dayDates[SonyPtpIpContent.dayIndex];
    // `dayDates` is in Sony's container order (most recent first), so this day's
    // upper bound is the day already walked: the NEXT NEWER captured date at
    // `dayIndex - 1`. The most recent day has none, which is why only the first
    // day can be ended by the page length alone.
    SonyPtpIpContent.dayStopUpper = SonyPtpIpContent.dayIndex > 0
      ? SonyPtpIpContent.dayDates[SonyPtpIpContent.dayIndex - 1]
      : null;
    // THE LATCH. Being positioned on a real captured date means there IS a page
    // to fetch, and `pump` reads this flag — and nothing else — to decide whether
    // the first `SDIO_GetContentsInfoList` (0x923C) is put on the wire at all.
    // `resetBuffer` closes the latch for every attempt and this was the only
    // intended way to open it again, so omitting it made a browse that had just
    // enumerated 5 captured dates report `exhausted=1 pages=0 entries=0` while
    // `firstPageRequested` stayed 0: the date loop finished and the walk stopped
    // without ever sending 0x923C. Nothing here reads `enable`,
    // `ContentsTransferEnableStatus`, or any 0x9212-derived state.
    SonyPtpIpContent.exhausted = false;
    NikonPtpIpService.log(`sony enumerate day=${SonyPtpIpContent.dayIndex}` +
      ` start=${SonyPtpIpContent.u64ToNumber(SonyPtpIpContent.cursor)}` +
      (SonyPtpIpContent.dayStopUpper === null
        ? ' upper=end'
        : ` upper=${SonyPtpIpContent.u64ToNumber(SonyPtpIpContent.dayStopUpper)}`));
  }

  /** Fills the buffer with at least `wanted` entries, or until the walk ends. */
  private static async pump(session: PtpTransport, wanted: number): Promise<void> {
    if (SonyPtpIpContent.exhausted && SonyPtpIpContent.totalPages === 0) {
      // The only state in which the latch can be closed before a single page was
      // requested. Sending nothing at all is silent by construction, so this line
      // — not the browse summary — is what makes that failure mode readable.
      NikonPtpIpService.log('sony enumerate pump-blocked' +
        ` exhausted=1 pages=${SonyPtpIpContent.totalPages}` +
        ` days=${SonyPtpIpContent.dayDates.length}` +
        ` dayIndex=${SonyPtpIpContent.dayIndex}` +
        ` buffered=${SonyPtpIpContent.buffer.length}` +
        ' reason=walk-not-positioned-on-a-day');
    }
    while (!SonyPtpIpContent.exhausted && SonyPtpIpContent.buffer.length < wanted) {
      if (SonyPtpIpContent.totalPages >= SonyPtpIpContent.MAX_TOTAL_PAGES) {
        NikonPtpIpService.log(`sony enumerate stopped reason=total-page-guard` +
          ` pages=${SonyPtpIpContent.totalPages}`);
        SonyPtpIpContent.exhausted = true;
        break;
      }
      const ok = await SonyPtpIpContent.consumePage(session);
      if (!ok) break;
    }
  }

  /** Why a parsed page stopped short, in Sony's terms. `none` means the whole
   * declared list was consumed. */
  private static pageStopReason(page: SonyContentPage): string {
    const reasons: string[] = [];
    if (page.truncated) reasons.push('truncated');
    if (page.stoppedAtUnknownContentType) reasons.push('unknown-content-type');
    if (page.implausibleCount) reasons.push('implausible-count');
    if (reasons.length === 0) return 'none';
    return reasons.join('+');
  }

  /**
   * The one decisive line per browse attempt.
   *
   * Three different root causes are otherwise indistinguishable in a real-device
   * log — a rejected request, a list that came back empty because the start date
   * was wrong, and a parse that desynchronised — so this line carries all of the
   * evidence at once: the transfer-mode code, why it is missing when it is,
   * which slot and how many captured dates were used, the createTime actually
   * sent for the first page (both 32-bit halves), and the 0x923C response code
   * with the header's declared count, the parsed count, and the stop reason.
   */
  private static logBrowseResult(outcome: string, startedAt: number): void {
    const skipTransferMode = SonyPtpIpContent.SKIP_SET_CONTENTS_TRANSFER_MODE_ON_RCT;
    const mode = skipTransferMode
      ? 'skipped'
      : (SonyPtpIpContent.modeCode < 0 ? 'none' : SonyPtpIpContent.hex(SonyPtpIpContent.modeCode));
    // Both branches as text so the field renders identically whether Sony's
    // `SDIO_SetContentsTransferMode` was sent or skipped.
    const modeIsOk = skipTransferMode
      ? 'n/a'
      : `${SonyPtpIpContent.modeCode === SonyPtpIpContent.RESPONSE_OK ? 1 : 0}`;
    // Held in a local so the ArkTS type checker can narrow it: these fields must
    // never throw on a browse that never got as far as a property dump.
    const walk = SonyPtpIpContent.propWalk;
    const lastWalk = SonyPtpIpContent.propLastWalk;
    // The media report, read BY PROPERTY CODE out of the accumulated map (never
    // out of a byte offset). `absent` means no 0x9209 payload of this attempt
    // carried that code at all, which `propMedia` below locates on the wire.
    const mediaSlot1 = SonyPtpIpContent.propValue(null, SonyPtpIpContent.PROP_MEDIA_SLOT1_STATUS);
    const mediaSlot2 = SonyPtpIpContent.propValue(null, SonyPtpIpContent.PROP_MEDIA_SLOT2_STATUS);
    const playbackMedia = SonyPtpIpContent.propValue(null, SonyPtpIpContent.PROP_PLAYBACK_MEDIA);
    const updateTimeSlot1 = SonyPtpIpContent.propValue(null,
      SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_UPDATE_TIME_SLOT1);
    const updateTimeSlot2 = SonyPtpIpContent.propValue(null,
      SonyPtpIpContent.PROP_CONTENTS_INFO_LIST_UPDATE_TIME_SLOT2);
    NikonPtpIpService.log(`sony browse attempt=${SonyPtpIpContent.browseAttempts}` +
      ` result=${outcome} mode=${mode}` +
      ` modeIsOk=${modeIsOk}` +
      ` modeAnswered=${SonyPtpIpContent.lastModeAnswered ? 1 : 0}` +
      ` modeError=${SonyPtpIpContent.lastModeError.length > 0 ? SonyPtpIpContent.lastModeError : '-'}` +
      // DIVERGENCE (a): what was actually put on the wire for
      // `SDIO_SetContentsTransferMode`, either `0x9212:[2,1,0]` or `skipped`.
      ` setTransferMode=${SonyPtpIpContent.setTransferMode}` +
      ` setup=${SonyPtpIpContent.setupOk ? 'ok' : (SonyPtpIpContent.setupDone ? 'fail' : 'skipped')}` +
      `:${SonyPtpIpContent.setupSteps}/6` +
      ` setupFail=${SonyPtpIpContent.setupFailedStep}` +
      `@${SonyPtpIpContent.hex(SonyPtpIpContent.setupFailedOpcode)}` +
      `=${SonyPtpIpContent.hex(SonyPtpIpContent.setupFailedCode)}` +
      ` setupDeviceInfo=${SonyPtpIpContent.deviceInfoBytes}` +
      ` setupExtDeviceInfo=${SonyPtpIpContent.extDeviceInfoBytes}` +
      ` setupProbeVersion=${SonyPtpIpContent.probeHex(SonyPtpIpContent.probeVersionCode)}` +
      ` setupProbeDump=${SonyPtpIpContent.probeHex(SonyPtpIpContent.probeDumpCode)}` +
      `:${SonyPtpIpContent.probeDumpBytes}` +
      ` setupProbeDumpFlag=${SonyPtpIpContent.probeHex(SonyPtpIpContent.probeDumpFallbackCode)}` +
      `:${SonyPtpIpContent.probeDumpFallbackBytes}` +
      ` propDumpParams=${SonyPtpIpContent.propDumpParams}` +
      // The INITIAL dump's own parameter list (`[0, flag]`, Sony's
      // `execute(false, ...)`) beside the refresh form above (`[1, flag]`,
      // `execute(true, ...)`), so the normalisation is visible in the one line a
      // device run is read from. `deviceInfo2*` is divergence (c), the second
      // `GetDeviceInfo` Sony sends right after the property dump; its
      // `functionalMode` is read on the live session, not on the session-open
      // response, so it is the one independent reading of the mode.
      ` propInitialParams=${SonyPtpIpContent.initialPropDumpParams}` +
      ` deviceInfo2=${SonyPtpIpContent.probeHex(SonyPtpIpContent.deviceInfo2Code)}` +
      `:${SonyPtpIpContent.deviceInfo2Bytes}` +
      ` deviceInfo2FunctionalMode=${SonyPtpIpContent.deviceInfo2FunctionalMode}` +
      // The property-walk verdict. `propWalk` describes ONE payload — the LARGEST
      // one walked in this attempt, i.e. the payload that can span the
      // `extPropCount` properties the camera declared in 0x9202 — and
      // `propWalkSource` / `propWalkParams` / `propWalkCovers` say which payload
      // that is. `clean` with `propSlot1Seen=0 propSlot2Seen=0` means the camera
      // never sent those records; any other `propWalk` value means the walk
      // desynchronised and the absence below is unproven. `propBytes` is
      // `consumed/received` where `received` is the data-phase length the
      // transport delivered for that same response, never a parse-derived count.
      // `propLastWalk*` is the most recent dump, which is frequently a smaller
      // delta: a delta's own `clean` verdict says nothing about the full list.
      // `extPropHas*` is the camera's own 0x9202 property list, which is the
      // precondition Sony's `isEnable$2` tests before it looks at a value at all.
      ` propWalk=${walk === null ? 'none' : walk.result}` +
      ` propWalkSource=${walk === null ? 'none' : walk.source}` +
      ` propWalkParams=${walk === null ? 'none' : walk.params}` +
      ` propRecords=${walk === null ? 'none' : `${walk.records}/${walk.declaredRecords}`}` +
      ` propBytes=${walk === null ? 'none' : `${walk.consumedBytes}/${walk.receivedBytes}`}` +
      ` propHanded=${walk === null ? 'none' : walk.handedBytes}` +
      ` propWalkCovers=${walk === null ? 'none' : `${walk.records}/${SonyPtpIpContent.extPropCount}`}` +
      ` propBadType=${walk === null ? 'none' : walk.firstBadType}` +
      ` propArrayTypes=${walk === null ? 'none' : walk.arrayTypes}` +
      ` propLastRecord=${walk === null
        ? 'none'
        : `${SonyPtpIpContent.hex(walk.lastRecordCode)}/${walk.lastRecordType}` +
          `+#${walk.lastRecordOffset}:${walk.lastRecordBytes}`}` +
      ` propSlot1Seen=${walk === null ? 'none' : (walk.slot1Seen ? 1 : 0)}` +
      `@${walk === null ? 'none' : walk.slot1Offset}` +
      `:${walk === null ? 'none' : walk.slot1Type}` +
      ` propSlot2Seen=${walk === null ? 'none' : (walk.slot2Seen ? 1 : 0)}` +
      `@${walk === null ? 'none' : walk.slot2Offset}` +
      `:${walk === null ? 'none' : walk.slot2Type}` +
      // How many 0x9209 payloads this attempt walked, how many properties the
      // accumulated map holds (Sony's `mAllDevicePropInfoDatasets` equivalent),
      // and the verdict on the most recent payload — so a full dump and the
      // deltas that follow are never collapsed into one another again.
      ` propDumps=${SonyPtpIpContent.propDumps}` +
      ` propMap=${SonyPtpIpContent.propValues.size}` +
      ` propLastWalk=${lastWalk === null ? 'none' : lastWalk.result}` +
      ` propLastWalkBytes=${lastWalk === null
        ? 'none' : `${lastWalk.consumedBytes}/${lastWalk.receivedBytes}`}` +
      ` propLastWalkRecords=${lastWalk === null
        ? 'none' : `${lastWalk.records}/${lastWalk.declaredRecords}`}` +
      ` extPropCount=${SonyPtpIpContent.extPropCount}` +
      ` extPropHasSlot1=${SonyPtpIpContent.extPropHasSlot1}` +
      ` extPropHasSlot2=${SonyPtpIpContent.extPropHasSlot2}` +
      ` extPropHasEnable=${SonyPtpIpContent.extPropHasEnableStatus}` +
      ` deviceInfoModel=${SonyPtpIpContent.deviceInfoModel}` +
      ` deviceInfoOps=${SonyPtpIpContent.deviceInfoOps}` +
      ` deviceInfoFunctionalMode=${SonyPtpIpContent.deviceInfoFunctionalMode}` +
      ` deviceInfoHas=${SonyPtpIpContent.deviceInfoHasDdFile ? 1 : 0}` +
      `${SonyPtpIpContent.deviceInfoHasCapturedDateList ? 1 : 0}` +
      `${SonyPtpIpContent.deviceInfoHasContentsInfoList ? 1 : 0}` +
      ` openSession=${SonyPtpIpContent.probeHex(SonyPtpIpContent.openSessionCode)}` +
      `:mode${SonyPtpIpContent.openSessionMode}` +
      ` sessionOpen=${SonyPtpIpContent.probeHex(SonyPtpIpContent.sessionOpenObserved)}` +
      `:asked${SonyPtpIpContent.sessionOpenOpcode < 0
        ? SonyPtpIpContent.probeHex(SonyPtpIpContent.OP_OPEN_SESSION_DEFAULT)
        : SonyPtpIpContent.hex(SonyPtpIpContent.sessionOpenOpcode)}` +
      // The achieved mode, in one field, taken from the operation that REALLY
      // established the session: `yes` only when the transport opened it with
      // `SDIO_OpenSession` (0x9210) [1, 2]. `sessionOpenUpgrade` is the separate
      // 0x9210 the six setup steps may have sent on top of a standard session:
      // its code says nothing about the mode, which is why it is reported apart
      // from `mode2`. `sessionOpenAttempts` is how many fresh connections the
      // session open needed, so a retry that succeeded is visible as `2`/`3`.
      ` mode2=${SonyPtpIpContent.mode2Established() ? 'yes' : 'no'}` +
      ` mode2By=${SonyPtpIpContent.mode2Established()
        ? SonyPtpIpContent.hex(SonyPtpIpContent.OP_SDIO_OPEN_SESSION) : 'none'}` +
      ` sessionOpenAttempts=${NikonPtpIpService.sessionOpenAttempts}` +
      ` sessionOpenUpgrade=${SonyPtpIpContent.probeHex(SonyPtpIpContent.openSessionCode)}` +
      ` ddXml=${SonyPtpIpContent.probeHex(SonyPtpIpContent.ddXmlCode)}` +
      `:${SonyPtpIpContent.ddXmlBytes}` +
      ` didXml=${SonyPtpIpContent.probeHex(SonyPtpIpContent.didXmlCode)}` +
      `:${SonyPtpIpContent.didXmlBytes}` +
      ` serverVersion=${SonyPtpIpContent.didServerVersion.length > 0
        ? SonyPtpIpContent.didServerVersion : 'unknown'}` +
      ` enable=last:${SonyPtpIpContent.enableLastValue < 0 ? 'absent' : SonyPtpIpContent.enableLastValue}` +
      `/polls:${SonyPtpIpContent.enablePolls}/dumpFail:${SonyPtpIpContent.enableDumpFailures}` +
      ` vendorCodeVersion=${SonyPtpIpContent.vendorCodeVersion < 0 ? 'unknown' : SonyPtpIpContent.vendorCodeVersion}` +
      ` slot=${SonyPtpIpContent.slotNumber}` +
      ` slotReason=${SonyPtpIpContent.slotReason}` +
      ` slot1=${SonyPtpIpContent.slot1Value < 0 ? 'absent' : SonyPtpIpContent.slot1Value}` +
      `/en${SonyPtpIpContent.slot1EnableFlag}` +
      ` slot2=${SonyPtpIpContent.slot2Value < 0 ? 'absent' : SonyPtpIpContent.slot2Value}` +
      `/en${SonyPtpIpContent.slot2EnableFlag}` +
      // THE MEDIA PRESENCE REPORT, which is what the slot decision now turns on.
      // `MediaSLOT1Status`/`MediaSLOT2Status` (53832/53846) are Sony's own media
      // report — 1 is OK — and `PlaybackMedia` (53314) is the media the camera
      // considers current. The two `slot1`/`slot2` fields above are only the
      // app-permission flags and say nothing about a card being inserted.
      // `UpdateTimeSlot1/2` (53718/53719) are the only property-level hint that a
      // contents DB exists for a slot.
      ` mediaSlot1=${SonyPtpIpContent.describeMediaValue(mediaSlot1, true)}` +
      ` mediaSlot2=${SonyPtpIpContent.describeMediaValue(mediaSlot2, true)}` +
      ` playbackMedia=${SonyPtpIpContent.describeMediaValue(playbackMedia, false)}` +
      ` updateTimeSlot1=${updateTimeSlot1 === undefined ? 'absent' : updateTimeSlot1}` +
      ` updateTimeSlot2=${updateTimeSlot2 === undefined ? 'absent' : updateTimeSlot2}` +
      // Where those codes were actually read on the wire (`0xCODE@byte:type`), so
      // `absent` above can be told apart from "the walk desynchronised".
      ` propMedia=${walk === null ? 'none' : walk.mediaRecords}` +
      ` extPropHasMedia=${SonyPtpIpContent.extPropHasMediaSlot1}` +
      `${SonyPtpIpContent.extPropHasMediaSlot2}` +
      `${SonyPtpIpContent.extPropHasPlaybackMedia}` +
      ` dateSlot=${SonyPtpIpContent.lastDateSlot}` +
      ` dateSlotAnswered=${SonyPtpIpContent.lastDateSlotAnswered}` +
      ` dateCode=${SonyPtpIpContent.probeHex(SonyPtpIpContent.lastDateCode)}` +
      ` dateParams=${SonyPtpIpContent.lastDateParams}` +
      ` dateBytes=${SonyPtpIpContent.lastDateBytes}` +
      ` dateCount=${SonyPtpIpContent.lastDateCount}` +
      // Every 0x923B attempt of the sweep as `slot#attempt:code`, in order. The
      // four `date*` fields above stay the DECISIVE request (first attempt on the
      // slot the picker chose); this one is the whole sweep, which is what says
      // whether a refusal is stable or transient and which slot ever answered.
      ` dateTries=${SonyPtpIpContent.dateTries}` +
      ` days=${SonyPtpIpContent.dayDates.length}` +
      // The day walk's own state, so "listed dates but requested no page" can be
      // told apart from "requested a page and had it refused". `dayOrder` is
      // Sony's container order (most recent first); `dayIndex` is how many days
      // the walk has consumed — equal to `days` once it ran off the end, `-1`
      // while it was never positioned; `dayUpper` is the bound that ended the
      // last day (`end` = the most recent day, which has none); `dayPages` is how
      // many 0x923C requests that last day took; `firstPageCount` is the `limit`
      // parameter actually sent with the first request (Sony's own 100).
      ` dayOrder=desc` +
      ` dayIndex=${SonyPtpIpContent.dayIndex}` +
      ` dayPages=${SonyPtpIpContent.dayPages}` +
      ` dayUpper=${SonyPtpIpContent.dayStopUpper === null
        ? 'end' : SonyPtpIpContent.u64ToNumber(SonyPtpIpContent.dayStopUpper)}` +
      ` firstPageCount=${SonyPtpIpContent.PAGE_SIZE}` +
      ` firstPageRequested=${SonyPtpIpContent.firstPageRequested ? 1 : 0}` +
      ` firstPageCreateTime=${SonyPtpIpContent.firstPageCreateTime.high}:${SonyPtpIpContent.firstPageCreateTime.low}` +
      ` firstPageValue=${SonyPtpIpContent.u64ToNumber(SonyPtpIpContent.firstPageCreateTime)}` +
      ` firstPageCode=${SonyPtpIpContent.hex(SonyPtpIpContent.firstPageCode)}` +
      ` firstPageBytes=${SonyPtpIpContent.firstPageBytes}` +
      ` lastPageCode=${SonyPtpIpContent.hex(SonyPtpIpContent.lastPageCode)}` +
      ` lastPageBytes=${SonyPtpIpContent.lastPageBytes}` +
      ` declared=${SonyPtpIpContent.firstPageDeclared}` +
      ` parsed=${SonyPtpIpContent.firstPageParsed}` +
      ` stop=${SonyPtpIpContent.firstPageStop}` +
      ` pages=${SonyPtpIpContent.totalPages}` +
      ` entries=${SonyPtpIpContent.discovered}` +
      ` buffered=${SonyPtpIpContent.buffer.length}` +
      ` exhausted=${SonyPtpIpContent.exhausted ? 1 : 0}` +
      ` elapsedMs=${Date.now() - startedAt}`);
  }

  // --- Image-transfer page entry points -----------------------------------

  /**
   * Opens (or reuses) the PTP/IP session for `host`, runs Sony's full
   * contents-transfer sequence and reads the first entries.
   *
   * The sequence is (S) Sony's own session setup (`GetDeviceInfo`, the DD/DID
   * device description documents, `SDIO_OpenSession` for
   * REMOTE_CONTROL_WITH_TRANSFER_MODE, `SDIO_Connect` 1/2, 0x9216, 0x9202,
   * `SDIO_Connect` 3) plus the post-setup probe, then (0)
   * `SDIO_SetContentsTransferMode` — SKIPPED by default, because Sony never sends
   * it on this path: see `SKIP_SET_CONTENTS_TRANSFER_MODE_ON_RCT` — (1) wait for
   * `ContentsTransferEnableStatus` ENABLE within 5 s (informational when (0) was
   * skipped), (2) pick the slot `MediaSLOT1Status`/`MediaSLOT2Status` reports as
   * OK, (3) sweep `SDIO_GetCapturedDateList` over both slots with retries, then
   * (4) `SDIO_GetContentsInfoList` with a real captured date as createTime. See
   * the file header for the source of every step.
   */
  /**
   * 用外部传输层（USB）打开索尼会话。
   *
   * 与 `open(host)` 走**完全相同**的协议流程：`SDIO_OpenSession` 的 mode‑2 偏好、
   * 六步 `setupSonySession`、mode‑2 闸门、`0x923B` 之前的所有校验。唯一区别是
   * 会话从哪里来 —— 这里由传输层提供，而不是由 TCP 客户端建立。这正是官方
   * `Initializer(ITransactionExecutor, …)` 的形态：协议层不知道自己是 TCP 还是 USB。
   */
  static async openViaTransport(transport: PtpTransport): Promise<SonyBrowseState> {
    SonyPtpIpContent.pendingTransport = transport;
    // 强制真正跑一遍内容枚举流程：如果上一步只是「控制会话」，`usbSessionActive`
    // 会是 true，而 `open()` 对已建立的 USB 会话直接复用 —— 那条会跳过 0x9212
    // 与枚举准备，图片传输页拿到的就是一个没进内容模式的会话。
    SonyPtpIpContent.usbSessionActive = false;
    SonyPtpIpContent.controlOnlySession = false;
    try {
      const state = await SonyPtpIpContent.open('usb');
      SonyPtpIpContent.usbSessionActive = state.ok;
      return state;
    } finally {
      SonyPtpIpContent.pendingTransport = null;
    }
  }

  /** 当前 USB 会话是否只建了控制通道（没进内容枚举模式）。 */
  static isControlOnlySession(): boolean {
    return SonyPtpIpContent.controlOnlySession;
  }

  /** 当前图片传输会话是否走的是 USB（供 UI 判断是否需要 Wi‑Fi）。 */
  static isUsbSession(): boolean {
    return SonyPtpIpContent.usbSessionActive;
  }

  /**
   * USB **控制**通道：只做「会话已在传输层建立」+ 六步 `setupSonySession`，
   * 不进内容枚举。
   *
   * 为什么不复用 `openViaTransport()`：那条路是内容枚举的完整流程，包含
   * `0x9212 SetContentsTransferMode`、`ContentsTransferEnableStatus` 轮询、
   * mode‑2 闸门与 `0x923B` 之前的准备。相机控制一条都用不上，而且 mode‑2 闸门
   * 会把「ServerVersion < 4.0、只拿到模式 0」的机身判死 —— 那是一个与控制无关
   * 的条件，用它挡住控制页是错的。控制真正需要的只有六步 setup：厂商操作
   * （`0x9207`/`0x9209`）在没跑过 setup 的会话上会一律回 `0x2005`。
   */
  static async openControlViaTransport(transport: PtpTransport): Promise<SonyBrowseState> {
    SonyPtpIpContent.session = transport;
    SonyPtpIpContent.usbSessionActive = true;
    SonyPtpIpContent.controlOnlySession = true;
    let ok: boolean = false;
    try {
      ok = await SonyPtpIpContent.setupSonySession(transport);
    } catch (error) {
      SonyPtpIpContent.session = null;
      SonyPtpIpContent.usbSessionActive = false;
      SonyPtpIpContent.controlOnlySession = false;
      return {
        ok: false,
        message: `索尼 USB 控制初始化异常：${(error as Error).message}`,
        host: 'usb',
      };
    }
    if (!ok) {
      SonyPtpIpContent.session = null;
      SonyPtpIpContent.usbSessionActive = false;
      SonyPtpIpContent.controlOnlySession = false;
      return {
        ok: false,
        message: '索尼 USB 控制初始化未完成：相机拒绝了六步 setup'
          + `（失败步 ${SonyPtpIpContent.setupFailedStep}`
          + ` 操作码 ${SonyPtpIpContent.hex(SonyPtpIpContent.setupFailedOpcode)}`
          + ` 响应 ${SonyPtpIpContent.hex(SonyPtpIpContent.setupFailedCode)}）`,
        host: 'usb',
      };
    }
    return { ok: true, message: '', host: 'usb' };
  }

  static async open(host: string): Promise<SonyBrowseState> {
    if (SonyPtpIpContent.usbSessionActive) {
      // USB 会话已建立：复用，不再按 host 建 TCP 会话。
      return { ok: true, message: '', host: 'usb' };
    }
    const safeHost = host.trim();
    if (safeHost.length === 0) {
      return { ok: false, message: '已连接索尼 Wi‑Fi，但没有可用网关地址', host: '' };
    }
    SonyPtpIpContent.resetBuffer();
    const startedAt = Date.now();
    SonyPtpIpContent.browseAttempts += 1;
    // What the transport really used for THIS attempt. Reset first so a failed
    // acquisition can never make the browse line show the previous attempt's
    // session (which made an `open-error` look like it had opened with 0x1002).
    SonyPtpIpContent.sessionOpenObserved = -1;
    // Mode 2 is established BY the session-open operation (`Initializer.java:83-96`),
    // so the browse asks for it on the connection it opens instead of opening the
    // standard way first and trying to upgrade a session whose mode is already
    // fixed. Only a body that proved it cannot run the six setup steps under a
    // 0x9210 session goes back to the standard open (see `vendorSetupFailed`).
    if (!SonyPtpIpContent.vendorSetupFailed) {
      SonyPtpIpContent.sessionOpenOpcode = SonyPtpIpContent.OP_SDIO_OPEN_SESSION;
    }
    try {
      // The session-open operation is Sony's own choice, not a constant: when
      // `sessionOpenOpcode` is set the connection is established with
      // `SDIO_OpenSession` (0x9210) [1, REMOTE_CONTROL_WITH_TRANSFER_MODE]
      // instead of the standard OpenSession (0x1002) [1], exactly the two
      // branches of `Initializer.createOpenSessionState` (`:83-96`).
      // `allowStandardFallback=false` for the vendor branch: the transport must
      // retry/release rather than hand back a standard session the browse would
      // then have to guess the mode of. `session.openOpcode` records what really
      // established the session, and the mode-2 gate below reads only that.
      let acquired: PtpTransport | null = null;
      if (SonyPtpIpContent.pendingTransport !== null) {
        // USB 等外部传输：会话已由传输层建立（USB 没有 PTP/IP 的 12 字节初始化
        // 握手，session-open 就是传输层的第一个事务），这里不再走 acquireSession。
        // 会话的开启操作码与响应码由传输层自己记录，后面 mode-2 闸门照常生效。
        acquired = SonyPtpIpContent.pendingTransport;
      } else if (SonyPtpIpContent.sessionOpenOpcode >= 0) {
        try {
          acquired = await NikonPtpIpService.acquireSession(safeHost,
            SonyPtpIpContent.sessionOpenOpcode,
            [SonyPtpIpContent.SESSION_ID,
              SonyPtpIpContent.FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER],
            false,
            SonyPtpIpContent.SESSION_OPEN_ATTEMPTS);
        } catch (vendorError) {
          // Distinct, never silent: the body would not give the vendor session.
          // A standard session is then acquired EXPLICITLY, for the six setup
          // steps' telemetry only — the mode-2 gate below stops the browse before
          // 0x923B, so this session can never be mistaken for mode 2. It gets the
          // same retry budget: a body that refused the vendor open may still be
          // holding the session, which is exactly what makes a standard open fail
          // too.
          NikonPtpIpService.logError('sony session-open vendor-refused', vendorError as Object);
          NikonPtpIpService.log('sony session-open vendor-refused' +
            ` asked=${SonyPtpIpContent.hex(SonyPtpIpContent.OP_SDIO_OPEN_SESSION)}` +
            ` params=[${SonyPtpIpContent.SESSION_ID},` +
            `${SonyPtpIpContent.FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER}]` +
            ` error=${SonyPtpIpContent.errorText(vendorError as Object)}` +
            ` fallback=explicit-standard-session mode2=no` +
            ` reason=diagnostics-only`);
          acquired = await NikonPtpIpService.acquireSession(safeHost,
            SonyPtpIpContent.OP_OPEN_SESSION_DEFAULT, [SonyPtpIpContent.SESSION_ID], true,
            SonyPtpIpContent.SESSION_OPEN_ATTEMPTS);
        }
      } else {
        acquired = await NikonPtpIpService.acquireSession(safeHost);
      }
      if (acquired === null) {
        throw new Error('PTP/IP session was not established');
      }
      // Bound to a const so the ArkTS strict-null checker narrows it once, for
      // every later use in this method.
      const session: PtpTransport = acquired;
      SonyPtpIpContent.sessionOpenObserved = session.openOpcode;
      SonyPtpIpContent.session = session;

      // (S) Sony's own session setup, before anything else. The standard PTP
      // OpenSession the transport performed is not what 0x9202/0x9209/0x9216
      // belong to — see the file header. Runs once per session; a second
      // browse reuses the cached result.
      const setupOk = await SonyPtpIpContent.setupSonySession(session);
      // The single-run proof: re-try the version read (when still unknown) and
      // the property dump once, on success and on refusal alike.
      await SonyPtpIpContent.probeAfterSetup(session);
      if (!setupOk) {
        SonyPtpIpContent.session = null;
        SonyPtpIpContent.logBrowseResult('setup-failed', startedAt);
        // Safety net for the vendor session open: if a session established with
        // 0x9210 cannot even run the six setup steps, that open is worse than the
        // standard one the transport has always used, so the preference is
        // dropped and the next browse goes back to the proven open. Sticky, so
        // the two modes cannot flip-flop across attempts. Not retried here —
        // that would make the two attempts loop.
        if (SonyPtpIpContent.sessionOpenObserved === SonyPtpIpContent.OP_SDIO_OPEN_SESSION) {
          SonyPtpIpContent.vendorSetupFailed = true;
          SonyPtpIpContent.sessionOpenOpcode = -1;
          NikonPtpIpService.log('sony session-open preference reset reason=setup-failed' +
            ` observed=${SonyPtpIpContent.hex(SonyPtpIpContent.sessionOpenObserved)}` +
            ` next=standard-open mode2=no`);
        }
        const failedCode = SonyPtpIpContent.setupFailedCode < 0
          ? '无响应'
          : SonyPtpIpContent.hex(SonyPtpIpContent.setupFailedCode);
        return {
          ok: false,
          message: '索尼会话初始化失败：' +
            `${SonyPtpIpContent.setupFailedStep}（op=${SonyPtpIpContent.hex(SonyPtpIpContent.setupFailedOpcode)}）` +
            ` 响应 ${failedCode}，已完成 ${SonyPtpIpContent.setupSteps}/6 步；` +
            '扩展设备信息（0x9202/0x9209/0x9216）在此会话上不可用',
          host: safeHost,
        };
      }

      // (0) SetContentsTransferMode — DIVERGENCE (a), switchable. Sony's
      // `PtpContentsRoot` RCT/IP browse never sends 0x9212 at all (see
      // `SKIP_SET_CONTENTS_TRANSFER_MODE_ON_RCT`), so the default configuration
      // skips it and settles instead; the operation itself is untouched and comes
      // back verbatim when the constant is false. `setTransferMode` on the browse
      // line always says which of the two ran.
      const skipTransferMode = SonyPtpIpContent.SKIP_SET_CONTENTS_TRANSFER_MODE_ON_RCT;
      let modeOk = true;
      if (skipTransferMode) {
        SonyPtpIpContent.modeCode = -2;
        SonyPtpIpContent.setTransferMode = 'skipped';
        NikonPtpIpService.log('sony set-contents-transfer-mode skipped' +
          ` op=${SonyPtpIpContent.hex(SonyPtpIpContent.OP_SET_CONTENTS_TRANSFER_MODE)}` +
          ` params=[${SonyPtpIpContent.CONTENTS_SELECT_TYPE_REMOTE_DEVICE},` +
          `${SonyPtpIpContent.CONTENTS_TRANSFER_MODE_ON},` +
          `${SonyPtpIpContent.ADDITIONAL_INFORMATION_NONE}]` +
          ` reason=divergence-a-sony-does-not-send-on-rct` +
          ` settleMs=${SonyPtpIpContent.RCT_SKIP_SETTLE_MS}`);
        await SonyPtpIpContent.delay(SonyPtpIpContent.RCT_SKIP_SETTLE_MS);
      } else {
        SonyPtpIpContent.setTransferMode =
          `${SonyPtpIpContent.hex(SonyPtpIpContent.OP_SET_CONTENTS_TRANSFER_MODE)}` +
          `:[${SonyPtpIpContent.CONTENTS_SELECT_TYPE_REMOTE_DEVICE},` +
          `${SonyPtpIpContent.CONTENTS_TRANSFER_MODE_ON},` +
          `${SonyPtpIpContent.ADDITIONAL_INFORMATION_NONE}]`;
        SonyPtpIpContent.modeCode = await SonyPtpIpContent.setContentsTransferMode(session);
        modeOk = SonyPtpIpContent.modeCode === SonyPtpIpContent.RESPONSE_OK;
      }
      // 0x2001 is PTP OK. A successful transfer-mode response must never be
      // presented as the cause of a failure: only a non-0x2001 code is an
      // error, and the message says explicitly which of the two it saw.
      const modeText = skipTransferMode
        ? `传输模式设置已跳过（诊断配置：仅用 mode-2 会话，等待 ${SonyPtpIpContent.RCT_SKIP_SETTLE_MS}ms）`
        : (modeOk
          ? '传输模式已进入（0x2001 = PTP OK）'
          : (SonyPtpIpContent.modeCode < 0
            ? `传输模式请求未得到响应（${SonyPtpIpContent.lastModeError}）`
            : `传输模式响应 ${SonyPtpIpContent.hex(SonyPtpIpContent.modeCode)}，非 0x2001，即失败`));
      if (!modeOk) {
        SonyPtpIpContent.session = null;
        SonyPtpIpContent.logBrowseResult('mode-failed', startedAt);
        return { ok: false, message: `索尼内容枚举失败（${modeText}）`, host: safeHost };
      }

      // (1) Sony does not treat the OK above as "mode established": it waits for
      // the ContentsTransferEnableStatus property to read ENABLE, with a 5 s
      // deadline (ContentsTransferModeSetter.java:168-179), and reports failure
      // when that expires — including when the property cannot be read at all,
      // where Sony's isContentsTransferEnable$1 also returns false. Enumeration
      // is therefore not attempted on an unconfirmed transfer mode; the message
      // names exactly which of the two happened.
      //
      // When 0x9212 is SKIPPED the wait still runs and its polls still fill the
      // property accumulator the slot decision reads, but its outcome is
      // informational: `ContentsTransferEnableStatus` is set BY the operation
      // that was skipped, so failing on it would measure the diagnostic switch
      // instead of the hypothesis. Only the mode-2 gate can still stop the browse.
      const properties = await SonyPtpIpContent.waitContentsTransferEnabled(session);
      // (2) Slot the camera reports as usable. Computed before the mode-2 gate so
      // the browse line keeps the property/slot evidence even when the session
      // turns out not to be in mode 2; `pickSlotNumber` resolves the two
      // properties through the accumulated map, so it is valid on every outcome,
      // including a failed enable wait. It assigns `slotNumber` exactly once on
      // the paths that go on to read the contents list.
      SonyPtpIpContent.slotNumber = SonyPtpIpContent.pickSlotNumber(properties);
      // 用户在存储卡选择器里的显式选择优先于自动选择——但**只在该槽确实可用时**。
      // 强行拿一个无卡/异常的槽去发 0x923B 只会换回 0xA106，那正是这条线最初的症状；
      // 所以不可用时保留自动选择的结果，并把理由留在 slotReason 里。
      const preferredSlot = SonyPtpIpContent.preferredSlot;
      if ((preferredSlot === SonyPtpIpContent.SLOT_1 || preferredSlot === SonyPtpIpContent.SLOT_2) &&
        preferredSlot !== SonyPtpIpContent.slotNumber &&
        SonyPtpIpContent.slotUsable(preferredSlot)) {
        SonyPtpIpContent.slotNumber = preferredSlot;
        SonyPtpIpContent.slotReason = `user-selected-slot${preferredSlot}`;
      }

      // (2b) THE MODE-2 GATE. `SDIO_GetCapturedDateList` (0x923B) is served only
      // in REMOTE_CONTROL_WITH_TRANSFER_MODE, and that mode is established by the
      // session-open operation itself (0x9210 [1, 2]) — not by
      // `SDIO_SetContentsTransferMode`. The verdict therefore comes from the
      // transport's record of the operation that really opened this session, never
      // from the 0x9210 the setup may have sent on top of a standard session (that
      // response cannot change an already-fixed mode). Without mode 2 the browse
      // stops HERE with its own result instead of sending 0x923B and reporting the
      // camera's 0xA106 as if it were the root cause.
      if (!SonyPtpIpContent.mode2Established()) {
        SonyPtpIpContent.session = null;
        SonyPtpIpContent.logBrowseResult('mode2-unavailable', startedAt);
        return {
          ok: false,
          message: '索尼内容枚举失败：会话未进入 REMOTE_CONTROL_WITH_TRANSFER_MODE(2)' +
            `（SDIO_OpenSession 0x9210 [${SonyPtpIpContent.SESSION_ID},` +
            `${SonyPtpIpContent.FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER}] 未建立会话，` +
            `实际建立会话的操作 ${SonyPtpIpContent.probeHex(SonyPtpIpContent.sessionOpenObserved)}` +
            `；0x923B SDIO_GetCapturedDateList 在此会话上不会被相机受理，故未发送）`,
          host: safeHost,
        };
      }

      if (properties === null) {
        if (skipTransferMode) {
          // Informational only: see the comment on the wait above. The slot
          // decision reads the accumulated property map, which the post-setup
          // probe already filled, so the sweep can go ahead.
          NikonPtpIpService.log('sony contents-transfer-enable treat-as-informational' +
            ` skipped=${SonyPtpIpContent.hex(SonyPtpIpContent.OP_SET_CONTENTS_TRANSFER_MODE)}` +
            ` polls=${SonyPtpIpContent.enablePolls}` +
            ` dumpFail=${SonyPtpIpContent.enableDumpFailures}` +
            ` last=${SonyPtpIpContent.enableLastValue < 0
              ? 'absent' : SonyPtpIpContent.enableLastValue}` +
            ` propMap=${SonyPtpIpContent.propValues.size}` +
            ' continuing=1');
        } else {
          SonyPtpIpContent.session = null;
          SonyPtpIpContent.logBrowseResult('enable-timeout', startedAt);
          return {
            ok: false,
            message: '索尼内容枚举失败（' + modeText +
              '，但 ContentsTransferEnableStatus(53909) 在 5 秒内未变为 ENABLE：' +
              `轮询 ${SonyPtpIpContent.enablePolls} 次，属性转储失败 ` +
              `${SonyPtpIpContent.enableDumpFailures} 次，最后读到 ` +
              `${SonyPtpIpContent.enableLastValue < 0 ? '无此属性' : SonyPtpIpContent.enableLastValue}` +
              '，相机未真正进入传输模式）',
            host: safeHost,
          };
        }
      }

      // (3) Captured date list: the createTime of the first page is a real date
      // the camera itself reported, never 0.
      const dates = await SonyPtpIpContent.readCapturedDates(session, SonyPtpIpContent.slotNumber);
      if (dates === null) {
        SonyPtpIpContent.session = null;
        // No upgrade left to attempt here: the mode-2 gate above has already
        // proven the session was opened by 0x9210 [1, 2], and re-opening a
        // session that IS the vendor one cannot make 0x923B any more acceptable.
        // The response is reported as-is.
        SonyPtpIpContent.logBrowseResult('captured-dates-failed', startedAt);
        return {
          ok: false,
          message: `索尼获取拍摄日期列表失败（SDIO_GetCapturedDateList 响应 ` +
            `${SonyPtpIpContent.probeHex(SonyPtpIpContent.lastDateCode)}` +
            `，参数输出 ${SonyPtpIpContent.lastDateParams}，载荷 ` +
            `${SonyPtpIpContent.lastDateBytes} 字节；slot=${SonyPtpIpContent.slotNumber}` +
            `，${SonyPtpIpContent.slotReason}）`,
          host: safeHost,
        };
      }
      if (dates.length === 0) {
        SonyPtpIpContent.exhausted = true;
        SonyPtpIpContent.logBrowseResult('no-captured-dates', startedAt);
        return { ok: true, message: '索尼相机未报告任何拍摄日期（存储卡可能为空）', host: safeHost };
      }

      // (4) One day per captured date, in SONY'S CONTAINER ORDER: ascending sort
      // then reverse (`PtpContentsRoot.java:127-130`), so index 0 — the container
      // the gallery opens first — is the MOST RECENT captured date, and that date
      // is the createTime of the first `SDIO_GetContentsInfoList` (0x923C).
      // `advanceDay` positions the walk on that date and opens the `exhausted`
      // latch, which is what makes `pump` actually issue the request instead of
      // returning immediately with `pages=0`.
      SonyPtpIpContent.dayDates = SonyPtpIpContent.sortDatesDescending(dates);
      SonyPtpIpContent.dayIndex = -1;
      SonyPtpIpContent.advanceDay();
      await SonyPtpIpContent.pump(session, 1);
      if (SonyPtpIpContent.pageFailure && SonyPtpIpContent.discovered === 0) {
        SonyPtpIpContent.session = null;
        SonyPtpIpContent.logBrowseResult('contents-info-list-failed', startedAt);
        return {
          ok: false,
          message: `索尼内容枚举失败（${modeText}，enable 属性=` +
            `${SonyPtpIpContent.enableLastValue < 0
              ? '未知' : SonyPtpIpContent.enableLastValue}，slot=` +
            `${SonyPtpIpContent.slotNumber}，但 GetContentsInfoList 响应 ` +
            `${SonyPtpIpContent.hex(SonyPtpIpContent.firstPageCode)}）`,
          host: safeHost,
        };
      }
      NikonPtpIpService.log(`sony browse opened mode=${SonyPtpIpContent.hex(SonyPtpIpContent.modeCode)}` +
        ` setTransferMode=${SonyPtpIpContent.setTransferMode}` +
        ` mode2=yes sessionOpen=${SonyPtpIpContent.probeHex(SonyPtpIpContent.sessionOpenObserved)}` +
        ` slot=${SonyPtpIpContent.slotNumber} slotReason=${SonyPtpIpContent.slotReason}` +
        ` days=${SonyPtpIpContent.dayDates.length}` +
        // The decisive pair on the opened line: `firstPageRequested=0` with
        // `days>0` means the date list arrived but no 0x923C was ever sent, which
        // is the exact failure this line used to hide.
        ` dayIndex=${SonyPtpIpContent.dayIndex} dayOrder=desc` +
        ` firstPageRequested=${SonyPtpIpContent.firstPageRequested ? 1 : 0}` +
        ` firstPageCode=${SonyPtpIpContent.hex(SonyPtpIpContent.firstPageCode)}` +
        ` firstPageBytes=${SonyPtpIpContent.firstPageBytes}` +
        ` entries=${SonyPtpIpContent.buffer.length} discovered=${SonyPtpIpContent.discovered}` +
        ` more=${SonyPtpIpContent.exhausted ? 0 : 1}`);
      SonyPtpIpContent.logBrowseResult('opened', startedAt);
      return { ok: true, message: '', host: safeHost };
    } catch (error) {
      NikonPtpIpService.logError('sony browse open', error as Object);
      SonyPtpIpContent.session = null;
      SonyPtpIpContent.logBrowseResult(`open-error:${SonyPtpIpContent.errorText(error as Object)}`, startedAt);
      return {
        ok: false,
        message: '索尼 PTP/IP 会话未建立，请确认相机 Wi‑Fi 已连接并允许传输',
        host: safeHost,
      };
    }
  }

  /**
   * Serves up to `limit` entries from the buffer, pulling more pages — and more
   * captured dates — from the camera when the buffer runs dry.
   */
  /**
   * 用户在图库页显式选择的卡槽；0 = 交给 `pickSlotNumber` 自动选择。
   * 切槽必须重新走一遍枚举（槽位是 0x923B/0x923C 的参数），所以它只在
   * 下一次 `open()` 时生效。
   */
  private static preferredSlot: number = 0;

  /** 记录用户选择的卡槽。 */
  static setPreferredSlot(slot: number): void {
    SonyPtpIpContent.preferredSlot = slot === SonyPtpIpContent.SLOT_2
      ? SonyPtpIpContent.SLOT_2 : SonyPtpIpContent.SLOT_1;
  }

  /** 本次枚举实际使用的卡槽（1 或 2），供存储卡选择器回显。 */
  static currentSlot(): number {
    return SonyPtpIpContent.slotNumber === SonyPtpIpContent.SLOT_2
      ? SonyPtpIpContent.SLOT_2 : SonyPtpIpContent.SLOT_1;
  }

  /**
   * 卡槽状态是否已知。false 表示这次属性转储里 `MediaSLOT1Status` (0xD248)
   * 或 `MediaSLOT2Status` (0xD256) 缺失——此时**不替相机假设"无卡"**，
   * 让选择器保持可点（与松下的 sdPresenceKnown 同一策略：失败/未知不等于无卡）。
   */
  static slotPresenceKnown(): boolean {
    return SonyPtpIpContent.propValue(null, SonyPtpIpContent.PROP_MEDIA_SLOT1_STATUS) !== undefined
      && SonyPtpIpContent.propValue(null, SonyPtpIpContent.PROP_MEDIA_SLOT2_STATUS) !== undefined;
  }

  /** 该卡槽是否可用（1=OK；无卡/卡错/识别中都不算）。 */
  static slotUsable(slot: number): boolean {
    const code = slot === SonyPtpIpContent.SLOT_2
      ? SonyPtpIpContent.PROP_MEDIA_SLOT2_STATUS
      : SonyPtpIpContent.PROP_MEDIA_SLOT1_STATUS;
    return SonyPtpIpContent.isMediaSlotOk(SonyPtpIpContent.propValue(null, code));
  }

  static async next(limit: number): Promise<SonyCatalogResult> {
    const session = SonyPtpIpContent.session;
    if (session === null) {
      return { ok: false, message: '索尼内容枚举会话已关闭', host: '', total: 0, items: [], hasMore: false };
    }
    const wanted = Math.max(1, Math.floor(limit));
    const startedAt = Date.now();
    try {
      await SonyPtpIpContent.pump(session, wanted);
      if (SonyPtpIpContent.pageFailure) {
        // A 0x923C refusal part-way through must be as visible as the first one.
        SonyPtpIpContent.logBrowseResult('page-failed', startedAt);
      }
      const items: SonyContentEntry[] = SonyPtpIpContent.buffer.slice(0, wanted);
      SonyPtpIpContent.buffer = SonyPtpIpContent.buffer.slice(items.length);
      const hasMore = SonyPtpIpContent.buffer.length > 0 || !SonyPtpIpContent.exhausted;
      NikonPtpIpService.log(`sony browse page items=${items.length} discovered=${SonyPtpIpContent.discovered}` +
        ` buffered=${SonyPtpIpContent.buffer.length} more=${hasMore ? 1 : 0}`);
      return {
        ok: true,
        message: `已通过索尼内容枚举读取 ${SonyPtpIpContent.discovered} 个文件`,
        host: '',
        total: SonyPtpIpContent.discovered,
        items: items,
        hasMore: hasMore,
      };
    } catch (error) {
      NikonPtpIpService.logError('sony browse page', error as Object);
      SonyPtpIpContent.session = null;
      SonyPtpIpContent.logBrowseResult(`page-error:${SonyPtpIpContent.errorText(error as Object)}`, startedAt);
      return { ok: false, message: '索尼内容枚举分页失败', host: '', total: 0, items: [], hasMore: false };
    }
  }

  /** Whether the browse session is still usable. */
  static isOpen(): boolean {
    const session = SonyPtpIpContent.session;
    return session !== null && !session.failed;
  }

  /** Drops the buffered page. The PTP/IP session itself is owned by
   * `NikonPtpIpService` and is torn down by its own `close()`. */
  static close(): void {
    SonyPtpIpContent.resetBuffer();
    SonyPtpIpContent.session = null;
    // USB 会话由 USB 传输层持有，这里只解除页面与它的绑定；真正的关闭由
    // `SonyUsbPtp.close()` 完成，所以标志必须清掉，否则下一次 open() 会以为
    // 会话还在而直接返回成功。
    SonyPtpIpContent.usbSessionActive = false;
    // 控制会话的标志同理：留着会让下一次「图片传输」误以为只需要复用会话。
    SonyPtpIpContent.controlOnlySession = false;
  }

  private static resetBuffer(): void {
    SonyPtpIpContent.buffer = [];
    // The served-file map belongs to the attempt that enumerated it: a new
    // attempt re-reads the list, and a stale fileId/slot pair must never be
    // used to address a file on it.
    SonyPtpIpContent.served.clear();
    SonyPtpIpContent.thumbRequests = 0;
    SonyPtpIpContent.thumbOk = 0;
    SonyPtpIpContent.thumbBytes = 0;
    SonyPtpIpContent.thumbLastCode = -2;
    SonyPtpIpContent.thumbLastBytes = 0;
    SonyPtpIpContent.thumbLastId = '-';
    SonyPtpIpContent.downloadChunks = 0;
    SonyPtpIpContent.downloadBytes = 0;
    SonyPtpIpContent.downloadLastCode = -2;
    SonyPtpIpContent.downloadLastParams = '-';
    SonyPtpIpContent.contentsDataFlag = -1;
    SonyPtpIpContent.discovered = 0;
    SonyPtpIpContent.cursor = { low: 0, high: 0 };
    // The walk starts with nothing to fetch. `advanceDay` is the ONLY thing that
    // opens this latch again — once it has positioned the walk on a real captured
    // date — so a browse that never reaches `advanceDay` correctly reports
    // `exhausted=1` instead of sending a page request with no date to send.
    SonyPtpIpContent.exhausted = true;
    SonyPtpIpContent.modeCode = 0;
    SonyPtpIpContent.slotNumber = SonyPtpIpContent.DEFAULT_SLOT_NUMBER;
    SonyPtpIpContent.dayDates = [];
    SonyPtpIpContent.dayIndex = -1;
    SonyPtpIpContent.dayStopUpper = null;
    SonyPtpIpContent.dayPages = 0;
    SonyPtpIpContent.totalPages = 0;
    SonyPtpIpContent.pageFailure = false;
    SonyPtpIpContent.lastPageCode = -1;
    SonyPtpIpContent.lastPageBytes = 0;
    SonyPtpIpContent.lastDateCode = -2;
    SonyPtpIpContent.lastDateParams = '-';
    SonyPtpIpContent.lastDateBytes = 0;
    SonyPtpIpContent.lastDateCount = -1;
    SonyPtpIpContent.lastDateSlot = -1;
    SonyPtpIpContent.lastDateSlotAnswered = -1;
    SonyPtpIpContent.slot1Value = -1;
    SonyPtpIpContent.slot2Value = -1;
    SonyPtpIpContent.slot1EnableFlag = -1;
    SonyPtpIpContent.slot2EnableFlag = -1;
    SonyPtpIpContent.slotReason = '-';
    // The sweep record and the divergence/param telemetry belong to ONE attempt:
    // a browse that dies before any of them is reported must show `-`/`na`
    // instead of the previous attempt's values.
    SonyPtpIpContent.dateTries = '-';
    SonyPtpIpContent.setTransferMode = '-';
    SonyPtpIpContent.initialPropDumpParams = '-';
    SonyPtpIpContent.deviceInfo2Code = -2;
    SonyPtpIpContent.deviceInfo2Bytes = 0;
    SonyPtpIpContent.deviceInfo2FunctionalMode = -1;
    SonyPtpIpContent.enablePolls = 0;
    SonyPtpIpContent.enableDumpFailures = 0;
    SonyPtpIpContent.enableLastValue = -1;
    SonyPtpIpContent.lastModeError = '';
    SonyPtpIpContent.lastModeAnswered = false;
    SonyPtpIpContent.firstPageRequested = false;
    SonyPtpIpContent.firstPageCode = -1;
    SonyPtpIpContent.firstPageBytes = 0;
    SonyPtpIpContent.firstPageDeclared = 0;
    SonyPtpIpContent.firstPageParsed = 0;
    SonyPtpIpContent.firstPageStop = 'none';
    SonyPtpIpContent.firstPageCreateTime = { low: 0, high: 0 };
    // `vendorCodeVersion` is NOT reset here: it is session state produced by
    // step (S5) of `setupSonySession`, and that setup is idempotent per
    // session. Clearing it would make a second browse lose the version its
    // cached setup already read, and the property dump would silently fall back
    // to the flag-less parameter form.
    SonyPtpIpContent.probeVersionCode = -2;
    SonyPtpIpContent.probeDumpCode = -2;
    SonyPtpIpContent.probeDumpBytes = 0;
    SonyPtpIpContent.probeDumpFallbackCode = -2;
    SonyPtpIpContent.probeDumpFallbackBytes = 0;
    SonyPtpIpContent.propDumpParams = '-';
    // The walk report belongs to the dump that produced it, not to the attempt:
    // clearing it here is what makes `propWalk=none` mean "no dump was walked in
    // this attempt" rather than showing the previous attempt's verdict. The
    // accumulated property map is cleared with it, so no slot decision can be
    // made from a property an earlier attempt read on an earlier session.
    SonyPtpIpContent.propWalk = null;
    SonyPtpIpContent.propLastWalk = null;
    SonyPtpIpContent.propDumps = 0;
    SonyPtpIpContent.propValues = new Map<number, number>();
    SonyPtpIpContent.propEnableFlags = new Map<number, number>();
    SonyPtpIpContent.propStrings = new Map<number, string>();
    SonyPtpIpContent.propOptions = new Map<number, number[]>();
    SonyPtpIpContent.propGetSet = new Map<number, number>();
    SonyPtpIpContent.propDataTypes = new Map<number, number>();
  }

  // --- Gallery mapping ----------------------------------------------------

  /** True for the Sony formats that are not JPEG, used for the RAW badge. */
  static isRawEntry(entry: SonyContentEntry): boolean {
    if (entry.fileFormat === SonyPtpIpContent.FORMAT_RAW ||
      entry.fileFormat === SonyPtpIpContent.FORMAT_HEIF) {
      return true;
    }
    return SonyPtpIpContent.extension(entry.filePath) === 'arw';
  }

  /** The image type the transfer page already uses: 1 = RAW, 2 = everything
   * else (JPEG and movies). */
  static imageTypeOf(entry: SonyContentEntry): number {
    return SonyPtpIpContent.isRawEntry(entry) ? 1 : 2;
  }

  /** The file name shown in the gallery, taken from the camera path. */
  static fileNameOf(entry: SonyContentEntry): string {
    const path = entry.filePath;
    const slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const name = slash >= 0 ? path.substring(slash + 1) : path;
    return name.length > 0 ? name : `SONY_${entry.contentId}`;
  }

  private static extension(path: string): string {
    const dot = path.lastIndexOf('.');
    return dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
  }

  // ========================================================================
  // Contents-data phase: thumbnails (0x923E) and originals (0x923D)
  // ========================================================================
  //
  // Everything in this section runs ON TOP of the already working enumeration.
  // It reads no browse state except `session` and the served-file map, and it
  // never sends 0x9212, never re-opens a session and never touches the cursor.

  private static servedKey(contentId: number, fileName: string): string {
    return `${contentId}|${fileName}`;
  }

  /** Records how to address every file of one enumerated page. Called from
   * `readPage`; a pure side effect, so the walk is unaffected. */
  private static rememberServed(entries: SonyContentEntry[], slot: number): void {
    for (const entry of entries) {
      SonyPtpIpContent.served.set(
        SonyPtpIpContent.servedKey(entry.contentId, SonyPtpIpContent.fileNameOf(entry)),
        {
          contentId: entry.contentId,
          fileId: entry.fileId,
          fileSize: entry.fileSize,
          slot: slot,
        });
    }
  }

  /**
   * The (contentId, fileName) pair the transfer page carries back to us,
   * resolved to the addressing data of the page it came from.
   *
   * `fileName` separates the two files of a RAW+JPEG shot, which share one
   * contentId but have different `fileId`s. When the name does not match, a
   * unique contentId match is still accepted; an ambiguous one is refused,
   * because guessing a fileId would download the wrong file.
   */
  private static servedFileFor(contentId: number, fileName: string): SonyServedFile | null {
    const exact = SonyPtpIpContent.served.get(SonyPtpIpContent.servedKey(contentId, fileName));
    if (exact !== undefined) return exact;
    const candidates: SonyServedFile[] = [];
    SonyPtpIpContent.served.forEach((value: SonyServedFile): void => {
      if (value.contentId === contentId) candidates.push(value);
    });
    if (candidates.length === 1) return candidates[0];
    return null;
  }

  /**
   * Sony's contents unique id for one ContentFile
   * (`transfer/ptp/PtpPullItem.java:392-393`):
   *
   *   low  32 bits = contentInfo.contentId
   *   high 32 bits = ((slotId & 255) << 24) + (fileId & 65535)
   *
   * Both halves are normalised to unsigned 32-bit because that is what goes on
   * the wire (`base/transaction/AbstractTransaction.java:31` keeps the
   * parameters as `int[]`, i.e. raw u32 bit patterns).
   */
  static contentsUniqueIdFor(contentId: number, fileId: number, slot: number): SonyU64 {
    const low = (contentId & 0xFFFFFFFF) >>> 0;
    const high = ((((slot & SonyPtpIpContent.UNIQUE_ID_SLOT_MASK)
      << SonyPtpIpContent.UNIQUE_ID_SLOT_SHIFT)
      + (fileId & SonyPtpIpContent.UNIQUE_ID_FILE_ID_MASK)) & 0xFFFFFFFF) >>> 0;
    return { low: low, high: high };
  }

  /**
   * `BasePtpManager.isResponseFileSize()` (`BasePtpManager.java:1304-1308`) as
   * the device property it actually reads: `GetContentDataCommandVersion`
   * (57622) enabled and >= 101. Returns the value of parameter [1]'s flag bit
   * (`ContentsDataGetter.java:388`): 65536 when the camera will echo the
   * content size back, 0 otherwise. Absent property = Sony's own false case.
   */
  private static contentsDataSizeFlag(): number {
    const enabled = SonyPtpIpContent.propEnableFlags
      .get(SonyPtpIpContent.PROP_GET_CONTENTS_DATA_COMMAND_VERSION);
    const raw = SonyPtpIpContent.propValues
      .get(SonyPtpIpContent.PROP_GET_CONTENTS_DATA_COMMAND_VERSION);
    const version = raw === undefined ? -1 : (raw | 0);
    const ok = enabled === SonyPtpIpContent.IS_ENABLE_TRUE &&
      version >= SonyPtpIpContent.GET_CONTENTS_DATA_COMMAND_VERSION_MIN;
    SonyPtpIpContent.contentsDataFlag =
      ok ? SonyPtpIpContent.CONTENTS_DATA_RESPONSE_FILE_SIZE_FLAG : 0;
    return SonyPtpIpContent.contentsDataFlag;
  }

  /** Last known state of the flag property, for the transfer log line. */
  private static contentsDataFlagText(): string {
    const raw = SonyPtpIpContent.propValues
      .get(SonyPtpIpContent.PROP_GET_CONTENTS_DATA_COMMAND_VERSION);
    return raw === undefined ? 'absent' : String(raw | 0);
  }

  private static parseContentId(text: string): number {
    const value = Number(text);
    if (!Number.isFinite(value) || value < 0 || value > 0xFFFFFFFF) return -1;
    return Math.floor(value) >>> 0;
  }

  private static safeFileName(fileName: string, contentId: number): string {
    const cleaned = (fileName || '').replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_');
    return cleaned.length > 0 ? cleaned : `SONY_${contentId}.JPG`;
  }

  private static thumbnailCachePath(context: common.UIAbilityContext, contentId: number,
    fileId: number): string {
    return `${context.filesDir}/sony_thumb_${contentId}_${fileId}.jpg`;
  }

  /**
   * Fetches one thumbnail with `SDIO_GetContentsCompressedData` (0x923E) and
   * writes it to the app sandbox, returning a `file://` URI the grid can load.
   *
   * Parameters are `BasePtpManager.java:1051` verbatim: content id low, content
   * id high, compressed-data type. THUMBNAIL (1) is the grid's variant
   * (`transfer/task/GetThumbnail.java:44`). The image arrives in a single data
   * phase (`contentstransfer/ContentsCompressedDataGetter.java:84-92`), so
   * there is no offset, no length and no chunking.
   *
   * Returns '' on any refusal, which leaves the card's placeholder in place.
   */
  static async fetchThumbnailFile(context: common.UIAbilityContext, contentIdText: string,
    fileName: string): Promise<string> {
    const session = SonyPtpIpContent.session;
    if (session === null || session.failed) return '';
    const contentId = SonyPtpIpContent.parseContentId(contentIdText);
    if (contentId < 0) return '';
    const servedFile = SonyPtpIpContent.servedFileFor(contentId, fileName);
    if (servedFile === null) {
      NikonPtpIpService.log(`sony thumbnail contentId=${contentIdText} name=${fileName}` +
        ' ok=0 reason=not-in-served-map');
      return '';
    }
    const id = SonyPtpIpContent.contentsUniqueIdFor(servedFile.contentId, servedFile.fileId,
      servedFile.slot);
    SonyPtpIpContent.thumbRequests += 1;
    SonyPtpIpContent.thumbLastId = `${id.high}:${id.low}`;
    try {
      const response: NikonPtpResponse = await session.enqueue(
        SonyPtpIpContent.OP_GET_CONTENTS_COMPRESSED_DATA,
        [id.low, id.high, SonyPtpIpContent.COMPRESSED_DATA_TYPE_THUMBNAIL],
        true);
      SonyPtpIpContent.thumbLastCode = response.code;
      SonyPtpIpContent.thumbLastBytes = response.data.length;
      const ok = response.code === SonyPtpIpContent.RESPONSE_OK && response.data.length > 0 &&
        response.data.length <= SonyPtpIpContent.THUMBNAIL_MAX_BYTES;
      NikonPtpIpService.log(`sony thumbnail contentId=${servedFile.contentId}` +
        ` fileId=${servedFile.fileId} slot=${servedFile.slot}` +
        ` id=${id.high}:${id.low} type=${SonyPtpIpContent.COMPRESSED_DATA_TYPE_THUMBNAIL}` +
        ` code=${SonyPtpIpContent.hex(response.code)} bytes=${response.data.length}` +
        ` ok=${ok ? 1 : 0}`);
      if (!ok) return '';
      const path = SonyPtpIpContent.thumbnailCachePath(context, servedFile.contentId,
        servedFile.fileId);
      SonyPtpIpContent.writeFile(path, response.data);
      SonyPtpIpContent.thumbOk += 1;
      SonyPtpIpContent.thumbBytes += response.data.length;
      return `file://${path}`;
    } catch (error) {
      SonyPtpIpContent.thumbLastCode = -1;
      NikonPtpIpService.logError('sony thumbnail', error as Object);
      return '';
    }
  }

  /**
   * Downloads one original with `SDIO_GetContentsData` (0x923D), in 3 MiB
   * requests, into the app sandbox; returns a `file://` URI.
   *
   * Parameters per request (`contentstransfer/ContentsDataGetter.java:388`):
   * `[contentIdLow, contentIdHigh | sizeFlag, offsetLow, offsetHigh, length]`
   * with `length = min(fileSize - offset, 3145728)`
   * (`ContentsDataGetter.java:381-384`). The loop is Sony's own: keep issuing
   * requests while the received byte count is below the file size
   * (`ptpip/mtp/ObjectGetter.java:121-125` is the same rule stated plainly).
   *
   * Reaching the end writes a `.part` file and renames it, so an interrupted
   * download can never look complete.
   */
  static async downloadOriginal(context: common.UIAbilityContext, contentIdText: string,
    fileName: string, expectedSize: number,
    onProgress?: (progress: number, received: number, total: number) => void): Promise<string> {
    const session = SonyPtpIpContent.session;
    if (session === null || session.failed) {
      NikonPtpIpService.log('sony download ok=0 reason=no-session');
      return '';
    }
    const contentId = SonyPtpIpContent.parseContentId(contentIdText);
    if (contentId < 0) {
      NikonPtpIpService.log(`sony download contentId=${contentIdText} ok=0 reason=bad-id`);
      return '';
    }
    const servedFile = SonyPtpIpContent.servedFileFor(contentId, fileName);
    if (servedFile === null) {
      NikonPtpIpService.log(`sony download contentId=${contentIdText} name=${fileName}` +
        ' ok=0 reason=not-in-served-map');
      return '';
    }
    const total = expectedSize > 0 ? expectedSize : servedFile.fileSize;
    if (total <= 0) {
      NikonPtpIpService.log(`sony download contentId=${servedFile.contentId}` +
        ' ok=0 reason=unknown-size');
      return '';
    }
    const id = SonyPtpIpContent.contentsUniqueIdFor(servedFile.contentId, servedFile.fileId,
      servedFile.slot);
    const flag = SonyPtpIpContent.contentsDataSizeFlag();
    const safeName = SonyPtpIpContent.safeFileName(fileName, servedFile.contentId);
    const finalPath = `${context.filesDir}/sony_original_${servedFile.contentId}` +
      `_${servedFile.fileId}_${safeName}`;
    const partPath = `${finalPath}.part`;
    const startedAt = Date.now();
    const maxRequests = Math.ceil(total / SonyPtpIpContent.CONTENTS_DATA_CHUNK_BYTES) * 4 + 64;
    let fd = -1;
    SonyPtpIpContent.downloadChunks = 0;
    SonyPtpIpContent.downloadBytes = 0;
    SonyPtpIpContent.downloadLastParams = '-';
    if (onProgress) onProgress(0, 0, total);
    try {
      SonyPtpIpContent.removeFile(partPath);
      const part = fileIo.openSync(partPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fd = part.fd;
      let offset = 0;
      let requests = 0;
      while (offset < total) {
        if (requests >= maxRequests) {
          throw new Error(`PTP/IP GetContentsData stalled at ${offset}/${total}`);
        }
        requests += 1;
        const remaining = total - offset;
        const length = Math.min(remaining, SonyPtpIpContent.CONTENTS_DATA_CHUNK_BYTES) &
          SonyPtpIpContent.CONTENTS_DATA_LENGTH_MASK;
        const offsetLow = offset >>> 0;
        const offsetHigh = Math.floor(offset / 0x100000000) >>> 0;
        const response: NikonPtpResponse = await session.enqueue(
          SonyPtpIpContent.OP_GET_CONTENTS_DATA,
          [id.low, (id.high | flag) >>> 0, offsetLow, offsetHigh, length],
          true);
        SonyPtpIpContent.downloadLastCode = response.code;
        if (response.code !== SonyPtpIpContent.RESPONSE_OK) {
          throw new Error(`PTP/IP GetContentsData response ${SonyPtpIpContent.hex(response.code)}` +
            ` at ${offset}/${total}`);
        }
        if (response.data.length === 0) {
          throw new Error(`PTP/IP GetContentsData returned an empty chunk at ${offset}/${total}`);
        }
        if (response.data.length > length) {
          throw new Error(`PTP/IP GetContentsData overflow requested=${length}` +
            ` received=${response.data.length}`);
        }
        if (SonyPtpIpContent.downloadChunks === 0) {
          SonyPtpIpContent.downloadLastParams = SonyPtpIpContent.describeParams(response.params);
        }
        SonyPtpIpContent.writeAll(fd, response.data);
        offset += response.data.length;
        SonyPtpIpContent.downloadChunks += 1;
        SonyPtpIpContent.downloadBytes += response.data.length;
        if (onProgress) {
          onProgress(Math.min(99, Math.round(offset * 100 / total)), offset, total);
        }
      }
      fileIo.closeSync(part);
      fd = -1;
      SonyPtpIpContent.removeFile(finalPath);
      fileIo.renameSync(partPath, finalPath);
      const seconds = Math.max((Date.now() - startedAt) / 1000, 0.001);
      NikonPtpIpService.log(`sony download contentId=${servedFile.contentId}` +
        ` fileId=${servedFile.fileId} slot=${servedFile.slot}` +
        ` id=${id.high}:${id.low} flag=${SonyPtpIpContent.hex(flag)}` +
        ` propVer=${SonyPtpIpContent.contentsDataFlagText()}` +
        ` chunks=${SonyPtpIpContent.downloadChunks} bytes=${SonyPtpIpContent.downloadBytes}` +
        ` expected=${total} declared=${SonyPtpIpContent.downloadLastParams}` +
        ` seconds=${seconds.toFixed(1)}` +
        ` rate=${(SonyPtpIpContent.downloadBytes / 1024 / 1024 / seconds).toFixed(2)}MB/s ok=1`);
      if (SonyPtpIpContent.downloadBytes !== total) {
        // The camera served a different length than the contents list declared.
        // The file is still complete as far as the body is concerned, but the
        // discrepancy is exactly what the size-echo flag exists to reveal.
        NikonPtpIpService.log(`sony download size-mismatch contentId=${servedFile.contentId}` +
          ` received=${SonyPtpIpContent.downloadBytes} declared=${total}`);
      }
      if (onProgress) onProgress(100, SonyPtpIpContent.downloadBytes, total);
      return `file://${finalPath}`;
    } catch (error) {
      NikonPtpIpService.log(`sony download contentId=${contentIdText} name=${fileName}` +
        ` code=${SonyPtpIpContent.hex(SonyPtpIpContent.downloadLastCode)}` +
        ` chunks=${SonyPtpIpContent.downloadChunks}` +
        ` bytes=${SonyPtpIpContent.downloadBytes} ok=0`);
      NikonPtpIpService.logError('sony download original', error as Object);
      return '';
    } finally {
      if (fd >= 0) {
        try { fileIo.closeSync(fd); } catch (_closeError) { }
      }
      SonyPtpIpContent.removeFile(partPath);
    }
  }

  /** Response parameters of the first chunk, shown as comma-joined decimal:
   * `[0],[1]` are the content's update-check timestamp and `[2],[3]` its current
   * size when the flag was sent (`ContentsDataGetter.java:197-211`). */
  private static describeParams(params: number[]): string {
    if (params.length === 0) return 'none';
    const parts: string[] = [];
    for (const value of params) parts.push(String(value >>> 0));
    return parts.join(',');
  }

  /** Aggregate one-line summary of everything this session transferred. */
  static transferSummary(): string {
    return `sony transfer thumbs=${SonyPtpIpContent.thumbOk}/${SonyPtpIpContent.thumbRequests}` +
      ` thumbBytes=${SonyPtpIpContent.thumbBytes}` +
      ` thumbLast=${SonyPtpIpContent.hex(SonyPtpIpContent.thumbLastCode)}` +
      `:${SonyPtpIpContent.thumbLastBytes}` +
      ` id=${SonyPtpIpContent.thumbLastId}` +
      ` dlChunks=${SonyPtpIpContent.downloadChunks} dlBytes=${SonyPtpIpContent.downloadBytes}` +
      ` dlLast=${SonyPtpIpContent.hex(SonyPtpIpContent.downloadLastCode)}` +
      ` dlParams=${SonyPtpIpContent.downloadLastParams}`;
  }

  private static writeAll(fd: number, data: Uint8Array): void {
    const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
    const written = fileIo.writeSync(fd, buffer);
    if (written !== data.length) {
      throw new Error(`file write incomplete expected=${data.length} written=${written}`);
    }
  }

  private static writeFile(path: string, data: Uint8Array): void {
    SonyPtpIpContent.removeFile(path);
    const file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      SonyPtpIpContent.writeAll(file.fd, data);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static removeFile(path: string): void {
    try { fileIo.unlinkSync(path); } catch (_error) { }
  }

  // --- Helpers shared with the reader and the parser ----------------------

  /** `EnumContentType` membership test: anything else aborts Sony's parse. */
  static isKnownContentType(value: number): boolean {
    return SonyPtpIpContent.KNOWN_CONTENT_TYPES.indexOf(value) >= 0;
  }

  /** Folds the two halves into one number for display only; `SonyU64` stays
   * authoritative for anything that is sent back to the camera. */
  static u64ToNumber(value: SonyU64): number {
    return value.high * 0x100000000 + value.low;
  }

  /** Ordering that never folds a 64-bit value into a double. */
  static compareU64(left: SonyU64, right: SonyU64): number {
    if (left.high !== right.high) return left.high < right.high ? -1 : 1;
    if (left.low !== right.low) return left.low < right.low ? -1 : 1;
    return 0;
  }

  static sameU64(left: SonyU64, right: SonyU64): boolean {
    return left.low === right.low && left.high === right.high;
  }

  /** The captured dates in ascending order — the primitive `sortDatesDescending`
   * builds Sony's container order from. */
  static sortDatesAscending(dates: SonyU64[]): SonyU64[] {
    const sorted: SonyU64[] = dates.slice(0);
    sorted.sort((left: SonyU64, right: SonyU64): number => {
      return SonyPtpIpContent.compareU64(left, right);
    });
    return sorted;
  }

  /** The captured dates in SONY'S CONTAINER ORDER: ascending, then reversed
   * (`CollectionsKt___CollectionsJvmKt.sortWith(...)` followed by
   * `Collections.reverse(...)`, `PtpContentsRoot.java:127-130`), so index 0 is
   * the MOST RECENT captured date — container[0], the one the gallery opens
   * first and therefore the createTime of the first `SDIO_GetContentsInfoList`.
   * The days then walk newest to oldest, and each day's upper bound is the
   * newer date already collected (see `advanceDay`). */
  static sortDatesDescending(dates: SonyU64[]): SonyU64[] {
    return SonyPtpIpContent.sortDatesAscending(dates).reverse();
  }

  /** Byte width of one `EnumDataType` scalar code, or 0 when the code is not a
   * size this module can walk (which aborts the property parse). */
  static dataTypeWidth(code: number): number {
    switch (code) {
      case 1: return 1;    // INT8
      case 2: return 1;    // UINT8
      case 3: return 2;    // INT16
      case 4: return 2;    // UINT16
      case 5: return 4;    // INT32
      case 6: return 4;    // UINT32
      case 7: return 8;    // INT64
      case 8: return 8;    // UINT64
      case 9: return 16;   // INT128
      case 10: return 16;  // UINT128
      default: return 0;
    }
  }

  /**
   * `EnumDataType` code rendered so a log line can be read against the enum
   * without a lookup, e.g. `0x0006/UINT32`, `0xFFFF/STR`, `0x4004/AUINT16`.
   *
   * Every constant is from `property/dataset/EnumDataType.java:8-47`:
   * Undefined(0), INT8(1), UINT8(2), INT16(3), UINT16(4), INT32(5), UINT32(6),
   * INT64(7), UINT64(8), INT128(9), UINT128(10), AINT8(16385),
   * AUINT8(16386), AINT16(16387), AUINT16(16388), AINT128(16389),
   * AUINT128(16390), AINT128(16391), AUINT128(16392), AINT128(16393),
   * AUINT128(16394), STR(65535).
   */
  static dataTypeText(code: number): string {
    const names: string[] = [
      'Undefined', 'INT8', 'UINT8', 'INT16', 'UINT16', 'INT32', 'UINT32',
      'INT64', 'UINT64', 'INT128', 'UINT128',
    ];
    if (code === SonyPtpIpContent.DATA_TYPE_STR) {
      return '0xFFFF/STR';
    }
    if (code >= 1 && code < names.length) {
      return `0x${code.toString(16).toUpperCase().padStart(4, '0')}/${names[code]}`;
    }
    if ((code & SonyPtpIpContent.DATA_TYPE_ARRAY_FLAG) !== 0) {
      const base = code & (SonyPtpIpContent.DATA_TYPE_ARRAY_FLAG - 1);
      const baseName = base >= 1 && base < names.length ? names[base] : 'unknown';
      return `0x${code.toString(16).toUpperCase().padStart(4, '0')}/A${baseName}`;
    }
    return `0x${code.toString(16).toUpperCase().padStart(4, '0')}/unknown`;
  }

  private static async delay(milliseconds: number): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, milliseconds);
    });
  }

  private static incrementU64(value: SonyU64): SonyU64 {
    if (value.low === 0xFFFFFFFF) {
      return { low: 0, high: (value.high + 1) >>> 0 };
    }
    return { low: (value.low + 1) >>> 0, high: value.high };
  }

  private static hex(value: number): string {
    if (value < 0) return 'none';
    return '0x' + value.toString(16).padStart(4, '0').toUpperCase();
  }

  /** Upper-case hex of the first `count` bytes, for the head of a payload whose
   * layout is in question. */
  private static hexBytes(data: Uint8Array, count: number): string {
    const shown = Math.min(count, data.length);
    let result = '';
    for (let index = 0; index < shown; index++) {
      result += data[index].toString(16).padStart(2, '0').toUpperCase();
    }
    return result;
  }

  /** Response code of a post-setup probe. `-2` means the probe was not issued,
   * which is different from `-1` (= issued, no response) and must not read as
   * the same `none` in the browse line. */
  private static probeHex(value: number): string {
    return value === -2 ? 'na' : SonyPtpIpContent.hex(value);
  }

  /** Manual UTF-8 decoding: the payload is already in memory and the platform
   * text decoders are stream-oriented. Invalid sequences become U+FFFD rather
   * than breaking the walk. */
  static decodeUtf8(bytes: Uint8Array, length: number): string {
    let result = '';
    let index = 0;
    while (index < length) {
      const first = bytes[index];
      if (first < 0x80) {
        result += String.fromCharCode(first);
        index += 1;
      } else if ((first & 0xE0) === 0xC0 && index + 1 < length) {
        const code = ((first & 0x1F) << 6) | (bytes[index + 1] & 0x3F);
        result += String.fromCharCode(code);
        index += 2;
      } else if ((first & 0xF0) === 0xE0 && index + 2 < length) {
        const code = ((first & 0x0F) << 12) | ((bytes[index + 1] & 0x3F) << 6) |
          (bytes[index + 2] & 0x3F);
        result += String.fromCharCode(code);
        index += 3;
      } else if ((first & 0xF8) === 0xF0 && index + 3 < length) {
        const code = ((first & 0x07) << 18) | ((bytes[index + 1] & 0x3F) << 12) |
          ((bytes[index + 2] & 0x3F) << 6) | (bytes[index + 3] & 0x3F);
        const adjusted = code - 0x10000;
        result += String.fromCharCode(0xD800 + ((adjusted >> 10) & 0x3FF));
        result += String.fromCharCode(0xDC00 + (adjusted & 0x3FF));
        index += 4;
      } else {
        result += '\uFFFD';
        index += 1;
      }
    }
    return result;
  }
}
