# 04 Sony Alpha: BLE provisioning + ISO 15740 PTP/IP transfer and control

**English** | [简体中文](../04-sony-alpha.md)

> Translated from the Chinese original at baseline `18466be`. Identifiers — UUIDs, operation codes, property codes, ports and `file:line` references — are kept exactly as in the source.

Baseline commit `18466be`. This report relies only on the code in this repository and on the facts about the official client that this code cites; no external protocol guesswork is introduced. Conclusions that the code does not prove, but that are extrapolated from the available evidence, are marked "inferred".

## 1. Where this sits on the wire: why Sony shares one PTP/IP path with Nikon

Sony mirrorless photo transfer runs over standard PTP/IP (CIPA DC-005), TCP 15740 — the same transport as Nikon. Four places establish this:
`SonyCameraService.ets:5-11` states that the body broadcasts a Wi-Fi Direct hotspot while "PC Remote" is active, that transfer on that hotspot is standard PTP/IP, and that this is "the same transport libgphoto2 offers generically for Sony bodies", so the module only owns the identity table plus an adapter shared with Nikon;
`SonyBleProvisioning.ets:13-14` states that `NikonPtpIpService` carries image transfer and control, "shared: Sony speaks standard ISO 15740 PTP/IP like Nikon does"; `CameraControlBrand.ets:11-21` states that the Sony path "shares the ISO 15740 PTP/IP transport, see NikonPtpIpService" and that the Nikon path "runs over the same ISO 15740 PTP/IP transport (the same NikonPtpIpService singleton)";
`CameraControlBrand.ets:114-125` `isPtpIpProtocol` is true only for sony / nikon, and explains why `isSonyProtocol` does not reuse the same flag — the two pages have the same shape, but the underlying service calls differ (SonyLiveView / SonyPtpIpControl against NikonPtpIpService).

The sharing happens at the **transport layer** (TCP connection, Init handshake, transaction queue, data phase, event channel), not at the business layer: Sony-private operation codes (0x92xx), the body-declared property table (0x9209), and the live-view HTTP stream are each implemented by one of three Sony-side modules. The counterexample is the Fujifilm path in the same repository — its own PTP-IP variant, a 12-byte packet header, private ports 55740/55741/55742 — which `isPtpIpProtocol` explicitly excludes (`CameraControlBrand.ets:101-108`). The transport layer is borrowed function by function: `connectGatt` / `enableNotification` / `readGatt` / `writeGatt` / `connectWifi` carry no brand logic in `LumixImportPrototype`, and Sony uses them directly just as Nikon does; only discovery and pairing are written per brand (`SonyBleProvisioning.ets:29-34`).

## 2. Advertising and identification

### 2.1 Manufacturer data (AD type 0xFF)

`SonyCameraService.parseSonyAdvertisement` (`SonyCameraService.ets:261-334`):

| Offset | Content | Decision |
| --- | --- | --- |
| 0..1 | company ID `45 01` = 0x012D (little-endian) | mismatch means not Sony |
| 2..3 | `03 00` (the "camera" marker) | on mismatch `isSony` is true and `isSonyCamera` is false |
| 4..5 | reserved | not parsed |
| 6..7 | two ASCII characters = model code | kept verbatim, log only |
| 8.. | TLV triples `[tag][d0][d1]`, step 3, terminated by `tag == 0` | see the table below |

At least 11 bytes are needed to parse (`:287`); the AD structures are walked segment by segment using the length byte, and only the first 0xFF record is taken (`:290-303`); the company-ID constants are at `:150-153` (0x012D = 301, little-endian `45 01` on the wire).

| tag | Field | Predicate (code as written) |
| --- | --- | --- |
| 33 (0x21) | Wi-Fi credential handover | supported `(d0 & 0x20) != 0`; enabled `(d0 & 0x30) == 0x10` |
| 34 (0x22) | Pairing | supported `(d0 & 0x80) != 0`; enabled `(d0 & 0xC0) == 0x40` |
| 35 (0x23) | Remote control / image transfer | remote control supported `(d0 & 0x80)`, enabled `(d0 & 0x60) == 0x20`; transfer supported `(d0 & 0x10)`, enabled `(d0 & 0x0C) == 0x04` |

"Enabled" is a two-bit, three-state field, which is why the code compares masks instead of testing bits one by one (`:276-277`). tag 34 bits 5/4 (location service), tag 35 bits 1/0 (push), and d1 bit 7 (background) are listed in the comments but not decoded.

### 2.2 Model code, model table, and SSID shape

The two-character model code appears only in scan logs, as `modelCode=` (`SonyBleProvisioning.ets:194-202`), and takes no part in branching — identity comes from two other sources: the BLE local name (`identifyBluetoothName`, `SonyCameraService.ets:242-259`, accepting `ILCE-7M4` / `ILCE-7M4-1234567` / `SONY ILCE-7M4`, sorted by descending token length so that `ILCE-7M` does not swallow `ILCE-7M5`) and the Wi-Fi SSID. The model table has 26 entries (`:155-182`, Alpha / Cinema Line / ZV / RX / ILX), plus `ILCE-7CM2`, which appears only in BLE names (`:184-189`).

Advertising admission is deliberately narrow: the manufacturer data decodes to `isSonyCamera`, **or** the local name is in the model table — either one suffices (`SonyBleProvisioning.ets:153-160`, `:173-192`); a comment notes that "matching only the SONY prefix would also admit televisions, headphones, and speakers". Scanning lasts 15 s, using `SCAN_MODE_LOW_LATENCY` + `MATCH_MODE_AGGRESSIVE` (`:70`, `:208-213`), and only a scan that this code started itself is stopped, so the nearby list on the camera page is not cleared (`:220-230`).

SSID shape `DIRECT-<4+ uppercase alphanumerics>:<model token>`, for example `DIRECT-12AB:ILCE-7M4` (`SonyCameraService.ets:1-7`, `:191-217`): it must start with `DIRECT-`, the instance name before the colon must satisfy `^[0-9A-Z]{4,}$`, and the token after the colon must hit the model table exactly (a `SONY-` prefix is allowed). The instance name and password are generated by the body; the function only identifies the model (`:194-196`). `identifyWifiSsid` also serves as the test for "is the phone already on the camera hotspot" (`SonyBleProvisioning.ets:846-870`), so a home router is never mistaken for a camera.

## 3. BLE pairing

### 3.1 Services and characteristics (`SonyCameraService.ets:73-118`)

| Role | UUID (constants expanded) | Purpose |
| --- | --- | --- |
| Pairing service | `8000EE00-EE00-FFFF-FFFF-FFFFFFFFFFFF` | private pairing |
| Pairing command | `0000EE01-EE00-FFFF-FFFF-FFFFFFFFFFFF` | write `{6,8,1,0,0,0,0}` to start pairing |
| Pairing status | `0000EE03-EE00-FFFF-FFFF-FFFFFFFFFFFF` | notify status/result frames |
| Body identity | `0000EE04-EE00-FFFF-FFFF-FFFFFFFFFFFF` | read firmware + model |
| Control service | `8000CC00-CC00-FFFF-FFFF-FFFFFFFFFFFF` | Wi-Fi switch and credentials |
| Wi-Fi on | `0000CC08-CC00-…` | write `{1}` |
| SSID | `0000CC06-CC00-…` | read, 3-byte header + ASCII |
| Password | `0000CC07-CC00-…` | read, 3-byte header + ASCII |
| BSSID | `0000CC0C-CC00-…` | read, optional |
| Capability bits | `0000CC0D-CC00-…` | EnumSupportInfo record for diagnostics |
| SSH credentials | `0000CC17-CC00-…` | record presence and length only, never content |

The same service also exposes `CCA2` (camera UUID), `CCA7` (identifier), `CC0A` (firmware), `CC0B` (model name), and `CCAB` (Wi-Fi band); the official read order is CC0A → CC0B → CCA7 → CC0D → CCAB (`:103-115`). Characteristics are normalized by "first segment with leading zeros stripped" before comparison, because a platform may hand out the full UUID, `0000EE01`, or a bare `EE01` (`SonyBleProvisioning.ets:289-318`); the CCCD is the standard `00002902-…` (`SonyCameraService.ets:118`).

### 3.2 Pairing flow (`pairOnly`, `SonyBleProvisioning.ets:405-686`)

1. Scan for the `deviceId`, connect GATT, `setBLEMtu(64)` (the same negotiated value as Nikon; 158 is the MTU of DiRxTx frames, while the pairing/credential characteristics are all short, so there is no reason to request an MTU the controller may refuse, `:422-430`), then read the EE04 identity first so that a successful result carries the model and firmware back (`:452-470`).
2. Find EE01 / EE03; if the service or a characteristic is missing, return immediately and splice both the characteristic list the pairing service actually exposes and the whole GATT table into the message: "no speculative command was sent" (`:485-504`).
3. **Do system-level bonding first**: if `getPairState` is already BONDED, skip it; otherwise call `connection.pairDevice` and wait 1500 ms for it to settle. Rationale: the pairing write was once answered with a generic `2900099`, and "this characteristic requires an encrypted link" is exactly that kind of failure with no specific error code (`:534-564`).
4. Subscribe to EE03 and write the start frame `{6,8,1,0,0,0,0}` (`SonyCameraService.ets:122`). The write type is chosen from the characteristic properties as `WRITE` or `WRITE_NO_RESPONSE`, with the other as fallback — `2900099` does not distinguish a wrong write type from a wrong payload or an unusable link, and the write type is the one a retry can fix (`SonyBleProvisioning.ets:362-393`, `:569-585`).
5. Pairing is two-stage: the start frame only puts the body into the pairing window, and the EE03 state machine then announces the classic-Bluetooth stage — `BTC_ENABLED(4)` / `BTC_REQUEST_RECEIVED(5)`, success `BTC_PAIRING_SUCCESS(8)` (`:588-592`).
6. Wait for a terminal state, capped at 30 s (`:72`). If EE03 delivers no notification at all within 2500 ms, actively request bonding as well (`:596-621`). **The system bond state is the authoritative success signal**: on hardware, an ILCE-7M4 showed pairing success on the body while EE03 sent no notification at all, so waiting only for notifications would judge a completed pairing as a timeout (`:601-614`).
7. On success, return immediately: **do not write CC08, do not read credentials, do not join the hotspot**, and do not cache credentials (`:668-679`).

### 3.3 Status frames and result codes

EE03 frame `[len][0][0][type][v31][v23][v15][v7]`: `type` 1 = status, 2 = result, and the value is a big-endian u32 (`SonyCameraService.ets:360-375`); the parser requires at least 8 bytes so the u32 read cannot run past the end (`:366-369`). Note that the comment at `SonyBleProvisioning.ets:40` says "7 bytes" yet lists 8 fields; the parser goes by 8 bytes — the parser is authoritative.

The nine pairing states (`stateLabel`, `SonyCameraService.ets:378-391`): 1 the camera has received the pairing request, 2 Bluetooth authentication passed, 3 Bluetooth authentication rejected, 4 classic Bluetooth enabled, 5 the camera has received the classic-Bluetooth pairing request, 6 classic-Bluetooth authentication passed, 7 classic-Bluetooth authentication rejected, 8 pairing succeeded, 9 cancelled on the camera side.

The ten result codes (`resultLabel`, `:394-408`): 1 pairing succeeded, 2 Bluetooth authentication rejected, 3 Bluetooth pairing failed, 4 classic-Bluetooth authentication rejected, 5 classic-Bluetooth pairing failed, 6 cancelled by the user, 7 the camera did not enter the pairing window, 8 MFi authentication rejected, 9 random-number mismatch, 10 pairing registration failed.

States `3/7/9` and any result other than 1 fail immediately; state `8` or result `1` means success (`SonyBleProvisioning.ets:627-654`).

### 3.4 Identity read frame (EE04)

`[len][type_hi][type_lo][fwLen][firmware][modelLen][model]`: `type` must be 0 (camera information frame), when `len` is non-zero the whole frame must be long enough, and an empty model counts as failure (`SonyCameraService.ets:336-358`). Strings are taken byte by byte as ASCII, truncated at 0, and any unprintable byte invalidates the whole frame (`:410-419`).

## 4. Wi-Fi credentials and joining the network (`startWifi`, `SonyBleProvisioning.ets:698-819`)

1. Idempotent short-circuit: if the phone is already on the camera hotspot (an SSID joined by this process, or an SSID that hits DIRECT-…:model), succeed immediately, polling the gateway up to 6×1 s for the DHCP lease (`:701-712`, `:854-888`). Otherwise reconnect GATT: if the connection left over from pairing still answers `getServices()`, reuse it; if not, reconnect, and rediscover once when the remembered address does not respond — classic-Bluetooth bonding may change the BLE address (`:890-937`).
2. Write CC08 `{1}` to turn on the camera's Wi-Fi and wait 4000 ms for it to settle (`:737-751`, `:74`); if the characteristic is missing, log it and continue on the assumption that "the hotspot is up".
3. Read CC06 / CC07 / CC0C: all three are **3-byte header `[len][type_hi][type_lo]` + US-ASCII**; reading stops at 0x00 or an illegal byte, and `length <= 3` counts as empty (`:939-967`, consistent with the official `BluetoothGattUtil.getWifiInfo`). BSSID is optional, and the official code likewise only skips it when it cannot be read (`:781-784`). An empty SSID or password is a failure; nothing is guessed.
4. Joining calls the shared `connectWifi(ssid, password, trace, 1, cb, 75000, true)`: `joinAttempts=1`, a total budget of 75 s, `skipScanWhenLinked=true`. The last flag has an on-hardware rationale — the control page may already be running a PTP/IP session on this network, and a `startScan()` every 2.5 s during joining would interrupt it (on hardware, ILCE-7M4: transaction timeouts, a poisoned session, and LiveViewUrl no longer readable, `:791-798`).

### 4.1 Why DiRxTx (8000BB00) is not implemented

`SonyBleProvisioning.ets:48-53`: DiRxTx and its ECDH P-256 + AES-CTR "secure AP pouring" variant serve the **reverse** scenario — the phone opens its own hotspot and hands the **phone's** AP credentials to the camera encrypted. This app only joins the camera's AP, so it uses plaintext CC06/CC07; encrypted provisioning is not implemented and is not needed. CC17 (SSH account and password) in the same manifest is only recorded by length and presence in diagnostics, and its content never reaches the log (`:986-1021`).

## 5. PTP/IP transport layer (shared, `NikonPtpIpService.ets`)

- Port 15740, two TCP connections: command and event (`:492`, `:1909-1935`). Handshake packet types `1 Init_Command`, `2 Init_Command_Ack`, `3 Init_Event`, `4 Init_Event_Ack` (`:494-497`); the `Init_Command` payload = 16-byte GUID + UTF-16 name `"Pixelshop Camera"` + u32 version `0x00010000` (`:482-484`, `:2696-2701`), and the `Init_Event` payload is the `connectionNumber` returned by the Ack (`:1930-1935`).
- Transaction packet types `6 Operation_Request`, `7 Operation_Response`, `9 Start_Data`, `10 Data`, `12 End_Data` (`:498-523`). **12, not the 11 in the specification table**: the code keeps an on-hardware conclusion — after reverting to 11 the camera ignored the end frame entirely, and what had been a "fast rejection" became a 10 s hang plus a poisoned session; so the sender uses 12 while the receiver accepts both (`:502-525`).
- Opening a session: once the handshake completes, the session-open operation is sent on **transaction number 0** (`:1936-1951`). By default `0x1002 [1]`, but Sony requires `0x9210 [1, 2]` (see 5.1), so `acquireSession` makes the open operation a parameter; opening a session that is already open yields `0x201E SessionAlreadyOpen` (`:540`, `:1942-1947`).
- Transaction serialization: `enqueue` is a single queue, so only one request/response (including the complete data phase) occupies the command channel at a time; the data-phase length must equal the u64 declared by StartData, otherwise `PTP/IP data length mismatch` is thrown (`:436-454`, `:2257-2331`); `enqueueDataOut` lets Sony control commands send 0/2/4-byte data phases (`:456-472`).
- Event channel: one passive loop per session, and a `next(60000)` timeout is normal idleness (`:2411-2447`). `DevicePropChanged`(0x4006) is only registered, never read back — once the body suspends its live-view stream it stops processing commands, so a read-back at that moment would only time out and poison the session; the change set is left for the control page to read in one pass inside a safe window (`:2462-2476`).
- The host address comes from the Wi-Fi DHCP gateway (`CameraPage.ets:5594-5605`, `:7292`), not from SSDP's LOCATION; the official client taking the host from SSDP is recorded as diagnostic hypothesis H3 (`SonyConnectionDiagnostics.ets:14`).

### 5.1 Sony initialization sequence after OpenSession

Standard `OpenSession` is not enough: on top of the PTP/IP session Sony has its own vendor session, and until that has run to completion all extended operations are rejected (`SonyPtpIpContent.ets:32-40`). `setupSonySession` (`:2023-2095`) runs in the official `Initializer` order, once per session (cached, not re-run on page changes):

| Step | Operation | Parameters | Notes |
| --- | --- | --- | --- |
| S1 | `0x1001 GetDeviceInfo` | none | abort if rejected, recording the first failing step |
| S1b | `0x923A` DD document | `[1]` | non-fatal, evidence gathering only |
| S1c | `0x923A` DID document | `[2]` | reads `X_ServerVersion`; mode 2 is needed only at ≥4.0 |
| S2 | `0x9210 SDIO_OpenSession` | `[1, 2]` | `2 = REMOTE_CONTROL_WITH_TRANSFER_MODE` |
| S3 | `0x9201 SDIO_Connect` | `[1,0,0]` | |
| S4 | `0x9201 SDIO_Connect` | `[2,0,0]` | |
| S5 | `0x9216 GetVendorCodeVersion` | empty | returns the first response parameter; from ≥310 later calls carry a flag |
| S6 | `0x9202 GetExtDeviceInfo` | `[300]` / `[300,1]` | the body-declared property/event code table |
| S7 | `0x9201 SDIO_Connect` | `[3,0,0]` | this step triggers `onInitialized`; only after it is 0x9209 sent |

S7 is the watershed: before `onInitialized`, sending 0x9209/0x9202/0x9216 is rejected, while simple settings such as 0x9212 may still be accepted — which is exactly what produces "some operations work and the property table is always empty" (`:56-63`, `:2003-2010`). `0x9210` **replaces** `0x1002` rather than adding to it (the two official branches are one if/else, `:78-120`, `:1209-1216`), so the browsing path opens sessions directly in mode 2; only when a mode-2 session cannot get through even the six steps does it fall back to a standard session open and pin "use standard next time" (`:4395-4410`).

Image-transfer essentials: `0x923B` (one u32 slot number) and `0x923C` (five u32s: timestamp high/low, entries per page, slot number, sequence flag) enumerate media, with slot state taken from `ContentsInfoListEnableStatusSlot1/2` (53716/53717) and `MediaSLOT1Status/2Status` (53832/53846); originals go through `0x923D` at ≤3 MiB per call with an offset, thumbnails through `0x923E` in a single data phase (`SonyPtpIpContent.ets:231-267`, `:1578-1650`, `:4956-5010`). `0x9212` can be toggled and is skipped by default (`:1347-1362`).

## 6. Control: read 0x9209, write 0x9205

### 6.1 One self-describing record yields both the value and the choices

`0x9209` is a data-in phase, with parameter `[0]` (first time) or `[0,1]` (version ≥310); the official code uses `[1, flag]` when refreshing on `SDIE_DevicePropChanged` (`SonyPtpIpContent.ets:141-153`, `:2555-2574`). Payload = u64 record count + records:

```
u16 code, u16 dataType, u8 getSet, u8 isEnable,
<defaultValue> <currentValue>      encoded per dataType
u8 formFlag   0 -> none   1 -> three more values (min/max/step)   2 -> u16 n + n values, then u16 m + m values
```

(`:820-853`.) The **two** u16 count arrays of formFlag-2 live in the **same record**: the first is the official unordered `mSetValues` (a HashSet), the second the ordered `mGetSetValues` (a LinkedList). The panel must show the second, while the first serves only as a membership filter; both arrive with this single 0x9209, so no extra round trip is needed (`:867-882`, `:1032-1048`, `:1084-1103`). `DATA_TYPE_STR` records are kept as well, and `LiveViewUrl` is read from here (`:857-866`).

The parser uses `receivedBytes` (the real transport data-phase length) as the denominator, and only "bytes walked == bytes received" counts as `clean`, matching the official `position == capacity` assertion (`:170-191`, `:1073-1081`). Having only part of the records in the first round of a dump is normal: the official client merges each response into one accumulating map, a refresh response may contain only the changed items, and this port merges the same way (values, strings, choices, getSet, and dataType are not wiped by later deltas), attributing the traversal decision to the largest payload seen in the current attempt (`:193-230`).

### 6.2 Writability determination and writes

`canSet = isEnable == True && getSet == GetSet` (`SonyPtpIpContent.ets:3104-3109`; the origin of, and the rationale for, the getSet octet are in `:889-896`), and `DispOnly(2)` is display-only, not writable; on top of that comes the global `RemoteControlRestrictionStatus` (53860, which must be 0, `SonyPtpIpControl.ets:124-136`). A missing record is treated as "not disabled". Both checks run before sending; a failure produces only a log entry and no request is sent (`:496-528`).

Writes go through `SDIO_SetExtDevicePropValue` (0x9205), with parameter `[code]`, or `[code, 1]` when the vendor code version is ≥310; the data phase is a plain little-endian scalar of the `EnumDataType` the property **declares for itself**, not padded and not in array form (`SonyPtpIpControl.ets:13-19`, `:516-527`, `:539-556`). The width always comes from the 0x9209 record: a hard-coded 2 bytes may work on one body and write a wrong value on another (`:530-537`). This is not `0x1016 SetDevicePropValue` — Sony's operation-code enumeration has no 0x1016 at all (`SonyPtpIpContent.ets:1559-1562`). After a successful set the value is written back into the accumulating table, otherwise the panel keeps showing the old value (`:3061-3078`).

### 6.3 Parameter table and the ILCE-7M4 read-only case

| Panel | Property code | Formatting rule (`SonyPtpIpControl.formatValue`) |
| --- | --- | --- |
| Aperture | `FNumber` 20487 | f-number ×100, one decimal place below 10; 0/65534/65535 display `--` |
| Shutter | `ShutterSpeed` 53773 / `ExtendedShutterSpeed` 53663 | low 16 bits denominator, high 16 bits numerator; all-zero is BULB; denominator 10 means seconds |
| ISO | `ISOSensitivity` 53790 | low 24 bits are the ISO value, 0xFFFFFF is AUTO |
| EV | `ExposureBiasCompensation` 20496 | signed 16-bit milli-EV, `±0.0` means 0 |
| Mode | `ExposureProgramMode` 20494 | exact match on all 32 bits against a 62-entry table (P/A/S/M, scene, video, S&Q) |
| WB | `WhiteBalance` 20485 | exact match after masking to 16 bits (including 0x8001… fluorescent/custom/underwater) |
| Quality | fallback chain 0xD288 → 0xD287 → 0xD252 | RAW compression tier / JPEG-HEIF / JPEG level |
| Ratio | `AspectRatio` 53777 | mask the low byte: 1=3:2, 2=16:9, 3=4:3, 4=1:1 |

Shutter is the only parameter that "reads with A and writes with B": as long as the extended shutter is readable (`isEnable` is True or DispOnly), reads use the extended property, and the extended property is used for writing only when SET is allowed; otherwise everything goes through the plain `ShutterSpeed` (`SonyPtpIpControl.ets:89-122`). Read-only cases on hardware, ILCE-7M4 (all taken from on-hardware records in the code):

- `ExposureProgramMode 20494` is `opt0:ro` — controlled by the body's dial, read-only from the remote side, so the mode panel shows the current position but does not respond to taps; this is the camera's declaration, not a restriction of ours (`CameraControlBrand.ets:58-60`).
- `CompressionSetting 0x5004` is not in the 0x9209 records at all (`0x5004:none:opt0:ro`); `JPEGQuality 0xD252` declares itself read-only with current value 0 (Sony's Undefined). In the same batch of records `CompressionFileFormat 0xD287` (`opt3:set`), `RawFileType 0xD288` (`opt5:set`), and `AspectRatio 0xD211` (`opt4:set`) are writable — again UINT8 with four options, so the difference lies in the body's own declaration (`SonyPtpIpControl.ets:246-301`). The quality panel therefore falls back 0xD288 → 0xD287 → 0xD252.
- Forcing a write to the read-only quality property is blocked locally and logged as `sony set quality refused: camera does not allow a set code=53842` (`:274-283`, `:506-510`).

## 7. Live view and shutter

First, a correction to how this is documented: page-layer comments describe Sony's live-view channel as `0x9201 / 0x9203 / 0x9202` (`CameraControlBrand.ets:16`, `:83-85`, `CameraPage.ets:279`, `:1708`), but **the implementation is not like that** — `0x9201` is `SDIO_Connect` and `0x9202` is `SDIO_GetExtDeviceInfo`, both of them session-establishment steps from §5.1; `0x9203` is **Nikon's** `GetLiveViewImage` (`NikonPtpIpService.ets:573`); and `SonyLiveView.ets:139-141` states explicitly that this module "never sends 0x9201/0x9202/0x9203". Sony's live-view switch and shutter both live in `0x9207 SDIO_ControlDevice`, and frames come from a separate HTTP stream.

| Purpose | Control code | Parameters | Data phase |
| --- | --- | --- | --- |
| Live view on/off | `54035 SetLiveViewEnable` | `[54035, flag]` | 2 bytes LE: `02 00` on, `01 00` off |
| AF half-press / shutter | `53953 S1Button` / `53954 S2Button` | `[code, flag]` | 2 bytes LE `Down(2)` / `Up(1)`; shutter = S1 down → S2 down → S2 up → S1 up |
| Movie recording | `53960 MovieRecButton` | `[53960, flag]` | start is press only, stop is press + release (the official code is asymmetric) |
| Touch AF / cancel | `53988` / `53989` | `[code, flag]` | 4 bytes LE (x in the high 16 bits, y in the low 16 bits, 640×480 grid) / 2 bytes LE |
| Deprecated | `53959 RequestOneShooting` | `[53959, flag]` | **0 bytes**, see below |

`flag` comes from the `SDIO_GetVendorCodeVersion` version; only at ≥310 is the second parameter 1 appended (`SonyLiveView.ets:26-30`, `:313-347`). This is not an optional optimization: a failed version read degrades the parameters to `[54035]`, the body answers `0x2005`, and the live-view HTTP stream then returns 503 (on-hardware record at `:314-322`), so the value the six-step setup already read is reused in preference.

- Live-view URL: property `LiveViewUrl` 53880 (string) taken from the accumulated 0x9209 table; the fallback is the DD document `X_ScalarWebAPI_LiveView_URL`. **Do not send a targeted `GetDevicePropValue` for this property** — on a 0x9210 session the body simply does not answer, closes the socket after ten seconds, and the whole session is invalidated (`SonyPtpIpContent.ets:2437-2443`, `:2455-2489`).
- Stream: a single HTTP GET, default port 60152, a 200 response that never ends; frames are delimited by a 16-byte little-endian header (image offset/length, focus-frame info offset/length), only the JPEG segment is taken and the focus/AF overlay block is discarded (`SonyLiveView.ets:81-119`); this is a connection separate from PTP/IP and does not reuse the command channel (`:1078-1087`).
- Shutter: `captureStill` follows the official order — S1 down on press, then S2 down, S2 up, S1 up on release, with the four transactions strictly serialized; `FocusIndication` is not polled, and S1 is released on every path (`SonyLiveView.ets:474-528`). `requestOneShooting` is kept for diagnostics only: its control code number 5 has no branch in the official `getData`, its payload is 0 bytes, and the official code tree has no caller either (`:619-647`).
- Session prerequisite: 0x9207 can only be sent on a `0x9210` (mode 2) session that has run the six-step setup. When a 0x1002 session is upgraded directly to 0x9210 without re-running the six steps, the body answers `0x2005` to both `0x9209` and the live-view switch, the stream stays at 503, while two seconds earlier the same body returned 351 properties normally for a session that had run the six steps (`:649-728`).

## 8. Implementation matrix

| Capability | Implementation | Status |
| --- | --- | --- |
| BLE scan/admission | `SonyBleProvisioning.findCamera` | implemented, manufacturer data or model name, either one |
| GATT connect/MTU/bond | same, `:420-430`, `:534-564`, `:898-937` | implemented, rediscovers when bonding changes the address |
| Pairing handshake / identity | `:472-655`; EE04 + `parsePairingIdentity` | implemented, two-stage; EE03 may send no notification |
| Wi-Fi hotspot on + credentials | CC08 `{1}` + CC06/CC07/CC0C | implemented, BSSID optional, called on demand |
| Joining the network | shared `connectWifi`, scanning skipped | implemented |
| PTP/IP transport | `NikonPtpIpService` | shared, port 15740 |
| Sony session initialization | `setupSonySession` six steps + 0x9210 | implemented, once per session |
| Property read / write | 0x9209 records; 0x9205 `[code]` / `[code,1]` | implemented, includes choices; width from the declared type |
| Image enumeration | 0x923B / 0x923C (0x9212 skipped by default) | implemented, dual-slot probing |
| Thumbnail / original | 0x923E single call / 0x923D ≤3 MiB per call | implemented, `.part` renamed on completion |
| Live view / shutter / movie / touch AF | 0x9207 + HTTP 60152 | implemented |
| Event-driven property refresh | 0x4006 registration only | partial, relies on a read-back in a safe window |
| DiRxTx reverse provisioning / SSH tunnel | — | deliberately not implemented (the latter only records capability bits for diagnostics) |

## 9. Limits and boundaries

**Model differences.** The 26-entry model table only determines identity and artwork; it does not guarantee the same set of properties, and writability is decided entirely by the body's 0x9209 records (on ILCE-7M4 the mode and JPEG quality are read-only). On hardware an ILCE-7M5 showed "Wi-Fi connected, session not established, Bluetooth status flapping repeatedly", while the same code works on an ILCE-7M4 (`SonyConnectionDiagnostics.ets:1-20`). One candidate is the official `SshSupportCamera`: when `X_SSH_Support=Enable` the official client does not connect to 15740 at all, but SSHes to port 22 and forwards locally; deciding this requires looking at the DID document and the CC0D capability bits together (`SonyBleProvisioning.ets:979-1007`). This app builds no tunnel, so such bodies can only reach the outcome "pairs, but cannot connect PTP/IP" — this is an uncovered model branch, not a pairing failure.

**In-camera limits.** All three hard gates are rejected early on this side: the property's `ro`/`DispOnly`, the global `RemoteControlRestrictionStatus != 0`, and live view requiring a mode-2 session with initialization complete. Slots add two more layers: `ContentsInfoListEnableStatusSlot1/2` are **application permission bits**, not media-present bits — the real media state is `MediaSLOT1Status/2Status` (53832/53846, 255 mask: OK=1, no card=2, wrong card=3, recognizing=4) — so slot selection is "media-aware" and both slots retry (`SonyPtpIpContent.ets:250-267`, `:1246-1256`). With no card, 0x923B is rejected, and that is exactly the previously unexplained `0x923B` error.

**Boundary of not needing PC Remote permanently on.** On the Bluetooth side, writing CC08 `{1}` makes the body bring the hotspot up itself, so the user need not first enable "PC Remote" in the camera menu; the page keeps two entry points for this — "Start pairing" goes through Bluetooth provisioning, and "Continue connection (hotspot already on)" joins a PC Remote hotspot the user opened manually (`CameraPage.ets:4850-4908`). There are three boundaries. First, the pairing stage still requires the body's Bluetooth to be on and inside the pairing window, and the phone side must confirm the system dialog. Second, a hotspot coming up does not mean the session is usable: PTP/IP still needs 0x9210 + the six-step initialization, otherwise properties and live view all return `0x2005`. Third, if the body has chosen the SSH tunnel (see above), the PC Remote hotspot does not listen on 15740 and this app cannot proceed.

**Known uncovered.** The color-temperature property `ColorTemperature` 53775 exists but is not wired to a panel (`SonyPtpIpControl.ets:197-207`); event-driven refresh only registers and never reads back; the SCREENNAIL variant of `0x923E` is unused; the Sony path does not use `0x9211 GetPartialLargeObject` (that is the standard PTP handle read, which ILCE-7M4 refuses for contents, `SonyPtpIpContent.ets:1600-1607`); video/audio metadata parsing is out of scope.

**Inferred (explicitly marked).** No on-hardware summary exists for how the "enabled" three-state values of tag 33/34/35 are distributed across models; this report only restates the decoding rules. Whether EE03 sending no notifications on ILCE-7M4 also happens on other models is unknown; the existing code keeps only the "bond state fallback" handling, and there is no per-model evidence.
