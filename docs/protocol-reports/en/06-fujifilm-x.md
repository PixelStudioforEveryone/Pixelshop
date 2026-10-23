# FUJIFILM X Series · BLE + Proprietary PTP-IP Technical Report

**English** | [简体中文](../06-fujifilm-x.md)

> Translated from the Chinese original at baseline `18466be`; all identifiers (UUIDs, opcodes, property codes, ports, byte offsets, `file:line` references) are kept verbatim.

> Baseline commit `18466be`. Only read `entry/src/main/ets/services/Fujifilm*.ets` and `docs/fujifilm/`; no camera was attached and no code was changed. Every value can be traced to `FujifilmProtocol.ets` or `docs/fujifilm/NOTES_*.md`; whatever comments and NOTES mark as 【inferred】/【unknown】 is marked the same way here. The original reverse-engineering reports (`Fujifilm\apk\reports\00–04`, `data\*.csv`) are not in this workspace, so this document only restates what NOTES already records and does not fill in details on their behalf.

## 1. Line positioning

### 1.1 Position when the five lines are placed side by side

| Line | Transport | Port | Degree of structure |
|---|---|---|---|
| Panasonic LUMIX | SSDP discovery + `cam.cgi` HTTP + DLNA | 80 | Public HTTP interface (`LumixCameraService.ets:348,406`) |
| Nikon | Standard PTP-IP (ISO 15740) | 15740 | Standard frames + proprietary LSS provisioning (`NikonPtpIpService.ets:492`) |
| Sony | Reuses Nikon's 15740 transport, adds a proprietary SDIO settings/content layer | 15740 | Proprietary codes layered on standard frames (`SonyPtpIpContent.ets:1166`) |
| Canon | Standard PTP-IP (ISO 15740 / CIPA DC-X005) | 15740 | Standard frames + EOS proprietary codes (`CanonPtpIp.ets:466`) |
| **Fujifilm** | **BLE provisioning + proprietary three-channel PTP-IP** | **55740 / 55741 / 55742** | 12-byte header follows CIPA; ports, init payload, and control codes are all proprietary (`FujifilmProtocol.ets:102-104`) |

The most substantive difference between Fujifilm and the other four lines is not the frame format but the split of endpoints: control and events each own a socket, live view takes a third one on 55741, and live view is a resident "blocking read of one whole frame" rather than "send a command, receive one frame" (`FujifilmPtpIp.ets:1-20`). The three paths do not block one another, and the live-view channel can be closed on its own at any time.

### 1.2 Model identification (`FujifilmModels.ets`)

The model name takes a different shape on each of the three paths: over BLE the legacy protocol uses "first 4 characters as a short serial number + model" (`FujifilmBleService.ets:316-328`), RED uses the whole string as the model with the short serial number in `mf[1..5]` (`:294-298`), the Wi-Fi SSID is `FUJIFILM-<model>-<suffix>` (`FujifilmModels.ets:41-42`), and PTP DeviceInfo/0x2A24 carries the official spelling (`:8-11`).

Matching is "exact → longest containment", not the asset table's loose matching: the latter would let `GFX100II 6A0123` hit the earlier-listed `GFX 100` first (`FujifilmModels.ets:14-20,110-141`). The result is `imageKey='fujifilm_<slug>'`, and the brand is always `'FUJIFILM'` (`:34-38`). The asset table holds 85 entries: 46 X series, 6 GFX, 31 instax, and one each for the `Other` and `Unknown` fallbacks; anything not listed falls back to `fujifilm/generic.png` (`:186-198`).

## 2. BLE advertising and identification

### 2.1 Manufacturer data layout

The Company ID is fixed at `0x04D8` and serves only as a secondary check; the generation marker is byte 0 of the manufacturer-specific data (`FujifilmProtocol.ets:18,95-96`; `FujifilmBleService.ets:288-304`):

| Byte | Legacy protocol (`mf[0]=2`) | RED (`mf[0]=1`) |
|---|---|---|
| `mf[0]` | `0x02` | `0x01` |
| `mf[1..4]` | pairing key (4 B, written back verbatim during pairing) | short serial number bytes 1–4 |
| `mf[5]` | power-button state | short serial number byte 5 |
| `mf[6]` | — | power-button state |
| Advertising name | first 4 characters = short serial number, remainder = model | whole string = model |

Short serial number: RED takes the ASCII of `mf[1..5]`, the legacy protocol takes the first 4 characters of the advertising name (`FujifilmBleService.ets:316-321`). The power-button state is parsed into `powerKey`, but no decision currently reads it (same file, `:70-74`).

### 2.2 The 7 scan service UUIDs

| UUID | Constant | Meaning |
|---|---|---|
| `AF854C2E-B214-458E-97E2-912C4ECF2CB8` | `SCAN_UUID_ALWAYS` | Resident in every mode; primary identification basis |
| `462426E1-D712-4A28-BE62-61A786DAA866` | — | Scan table only; not named in the constant table |
| `731893F9-744E-4899-B7E3-174106FF2B82` | `SERVICE_CAMERA_STARTUP_INFO` | Startup info |
| `A9D2B304-E8D6-4902-8336-352B772D7597` | `SERVICE_CAMERA_INFORMATION_RED` | RED information service |
| `123D8F06-62A1-4935-9322-833C531EE225` | `SERVICE_CONNECTED_DEVICE_INFO_RED` | RED connected-device info |
| `804DAA8E-FFEB-4AB3-8E75-6EDD7303208D` | `SERVICE_CAMERA_STARTUP_INFO_RED` | RED startup info |
| `CC74BD26-4ABB-4911-AE72-9CD93109A772` | — | Scan table only; not named in the constant table |

(`FujifilmProtocol.ets:21-32`.) 128-bit UUIDs in advertising are little-endian and are restored by reversing the 16 bytes (`FujifilmBleService.ets:330-339`). Recognition is any one of three conditions — manufacturer ID = 0x04D8 / hit on the resident service / hit on a RED service — and **is not decided by a name containing FUJIFILM**, so that peripherals such as printers are not pulled into the camera list (`:246-252,288-289`).

### 2.3 Scan strategy

HarmonyOS allows only one scan at a time, so there are three levels of degradation (`FujifilmBleService.ets:130-211`): start with a filter on the 7 `serviceUuid`s → if rejected, scan everything and filter in the callback → if still rejected, reuse the callback of a scan the page already runs and only `off` our own listener, never `stopBLEScan()` and interrupt a Panasonic scan.

A round is restarted after 60 s, and only the round we own is restarted (`:79-91,152-157`); duplicate reports from the same body within 3 s are dropped (`:84,230-232`).

## 3. GATT table

### 3.1 Services

| Service | UUID | Description |
|---|---|---|
| `SERVICE_CAMERA_CONTROL` | `6514EB81-4E8F-458D-AA2A-E691336CDFAC` | Camera control |
| `SERVICE_CAMERA_STATE` | `4C0020FE-F3B6-40DE-ACC9-77D129067B14` | State |
| `SERVICE_CAMERA_SETTING` | `4E941240-D01D-46B9-A5EA-67636806830B` | Settings |
| `SERVICE_CAMERA_INFORMATION` | `117C4142-EDD4-4C77-8696-DD18EEBB770A` | Identity information |
| `SERVICE_CAMERA_INFORMATION_RED` | `A9D2B304-E8D6-4902-8336-352B772D7597` | RED variant; also a scan UUID |
| `SERVICE_CONNECTED_DEVICE_INFO` | `91F1DE68-DFF6-466E-8B65-FF13B0F16FB8` | Connected devices |
| `SERVICE_CONNECTED_DEVICE_INFO_RED` | `123D8F06-62A1-4935-9322-833C531EE225` | RED variant; also a scan UUID |
| `SERVICE_CAMERA_STARTUP_INFO` | `731893F9-744E-4899-B7E3-174106FF2B82` | Startup info |
| `SERVICE_CAMERA_STARTUP_INFO_RED` | `804DAA8E-FFEB-4AB3-8E75-6EDD7303208D` | RED variant |

(`FujifilmProtocol.ets:35-43`.) The parent-child relationship between services and characteristics is not hard-coded: `findCharacteristic()` walks every discovered service and looks the characteristic up by UUID (`FujifilmBleService.ets:459-468`). Neither the constants in this workspace nor the documentation contain that mapping, so this document does not supply it.

### 3.2 Characteristics

| Purpose | UUID | Direction | Call site / current state |
|---|---|---|---|
| Pairing key write-back | `ABA356EB-9633-4E60-B73F-F52516DBD671` | write | `pair()`: 4 B for the legacy protocol / 5 B for RED (`:487-529`) |
| Wi-Fi SSID | `BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4` | read | `readWifiCredentials()` (`:578-605`) |
| Wi-Fi password | `E809256A-915C-4967-92E8-53B7D4CAD213` | read | Same as above; only the length of the sensitive value is logged |
| Feature launch | `600655E6-3637-42F1-8FB2-44EFC5C63B13` | write u16 LE | `launch()`, values 3/4/5 only (`:612-629`) |
| AP state | `A68E3F66-0FCC-4395-8D4C-AA980B5877FA` | notify | The only subscription made on connect (`:385,431-440`) |
| Wi-Fi MAC | `49A12959-DFAA-4EB2-89CE-62548AD948F3` | read | `readIdentity()` (`:544`) |
| Serial number | `E8E40D50-A625-4F1D-96ED-8CEC034F5690` | read | Falls back to 0x2A25 on failure (`:538-541`) |
| Y number | `27870478-94A9-4345-849B-EFA3BF37887F` | read | Constant already added; the implementation still uses a local constant of the same value (`:116-124,545`) |
| RED app info | `8B5ECF55-FC6B-40D0-B4C1-76F64E5453C7` | write `80 01 01` | RED only (`:517-522`) |
| RED device identification number | `F557D96B-8284-4667-8793-B971C1DECA2A` | read + write `0x20000000` | RED only; skipped when the value read back already matches (`:498-513`) |
| Firmware version | `00002A26-0000-1000-8000-00805F9B34FB` | read | `readFirmwareVersion()` (`:560-570`) |
| Serial number / model (standard) | `00002A25…` / `00002A24…` | read | Fallbacks for serial number and model (`:540,542-543`) |
| Firmware request, 92 B | `B1307521-7AC5-4199-AAEE-9D094781CE69` | write | Injected by the firmware page (`FujifilmFirmwarePage.ets:27,99`) |
| Firmware file info, 29 B | `20EA1FAC-19D8-48A8-A80C-535D34300958` | read | Same as above (`FujifilmFirmwarePage.ets:31`) |
| UTC + time zone / firmware state / lens firmware | `C52EDBCE-…` / `049EC406-…` / `621A98D8-…` | — | Protocol constants only; no read/write call site |

(Full UUID table `FujifilmProtocol.ets:45-79`; the UTC comment mentions that "legacy firmware degrades to a 7 B DATE_TIME".) GATT connection order: connect → MTU 185 → `getServices()` → subscribe to `AP_STATE` (`FujifilmBleService.ets:345-386`). `AP_STATE` notifications are parsed as LE u16 (`:431-440`), and a dropped link clears both the connection state and the last value (`:373-379`).

## 4. Pairing sequence

Fujifilm has no PIN, no system bonding, and no encryption: pairing = writing back verbatim the bytes the camera advertised (`NOTES_A.md §5.3`; `FujifilmBleService.ets:482-529`). The Fujifilm line has no `createBond()` call; that word appears only in a comment at `FujifilmBleService.ets:15`.

| Step | Action | Failure semantics |
|---|---|---|
| S1 | `connect()`: GATT + MTU 185 + subscribe `AP_STATE` | returns false, does not throw |
| S2 | Take the cached `pairingKey` from advertising | no cache → false, prompt to scan again |
| S3 | RED: read `F557D96B`, write only if ≠ `0x20000000` | a failed read is treated as "not bound" and execution continues |
| S4 | Write `ABA356EB` = the advertised key (for RED, the five bytes `mf[1..5]`) | write failure → false |
| S5 | RED: write `8B5ECF55` = `80 01 01` | write failure → false |
| S6 | Read `BF6DC9CF` (SSID) | empty/exception → **disconnect** and throw |
| S7 | Read `E809256A` (password) | empty/exception → **disconnect** and throw; only the length is logged |
| S8 | Write `600655E6` = u16 LE 3/4/5 | invalid value rejected; not connected → false directly |
| S9 | Poll `AP_STATE` until `0x8001` | timeout → false, log carries the last value |

- `launch()` sets `apStateValue` to -1 before writing, so a leftover value from the previous round is never read (`:624`).
- `waitApReady` is millisecond-based in 250 ms steps; the page allows 20 s (`FujifilmBleService.ets:631-644`, `CameraPage.ets:50,6023`). `0x8002` only means "starting up".
- A pairing failure **does not block** credential reads: some firmware refuses a repeated key write, but the credentials are unrelated to the key (`CameraPage.ets:6007-6013`).
- The password is only a local variable handed to the system association; it is written neither to preferences nor to session storage (`NOTES_A.md §5.4`). The firmware's 92 B / 29 B reads and writes share the same GATT serial lock (`FujifilmBleService.ets:650-730`).
- Hotspot association uses `securityType: 3` (WPA2-PSK); `cameraHost` comes from the DHCP gateway, and only when that is unavailable is `FujifilmNet.HOST` used (`CameraPage.ets:6041-6077`).

## 5. PTP-IP transport

### 5.1 Roles of the three ports

| Port | Constant | Role | Lifetime |
|---|---|---|---|
| 55740 | `PORT_CONTROL` | Init handshake, OpenSession, all PTP transactions | Established with `connect()` |
| 55741 | `PORT_LIVEVIEW` | Live-view whole-frame stream | Opened only on entering preview; closed when switching to remote control |
| 55742 | `PORT_EVENT` | Resident event reads after `Init_Event_Request` | Background loop; control is unaffected if it fails to start |

(`FujifilmProtocol.ets:102-104`; `FujifilmPtpIp.ets:353-384,629-661,715-743`.)

### 5.2 The 12-byte packet header

Every packet goes through the same `frame(type, field, payload)`: `Length` includes the header, `Type` takes 1–12, and the third field is reused according to packet type (`FujifilmPtpIp.ets:818-836`):

| Offset | Field | Value |
|---|---|---|
| 0..3 | Length | whole-packet length, LE32 |
| 4..7 | Type | 1 Init_Command_Request / 2 Init_Command_Ack / 3 Init_Event_Request / 4 Init_Event_Ack / 5 Init_Fail / 6 Operation_Request / 7 Operation_Response / 8 Event / 9 Start_Data / 10 Data / 11 End_Data / 12 Cancel |
| 8..11 | Third field | Operation_Request = DataPhaseInfo; Start/Data/End_Data = TransactionID; Init packets = 0 or connectionNumber |

(Type constants `FujifilmProtocol.ets:141-158`.) `Operation_Request` payload = `u16 opcode + u32 transactionId + u32 params[]` (`FujifilmPtpIp.ets:827-836`).

### 5.3 Initialization

The `Init_Command_Request` payload is a fixed 68 bytes (`FujifilmPtpIp.ets:265-286,387-394`): offsets 0..15 are the GUID `08 70 B0 61 0A 8B 45 93 B2 E7 93 57 DD 36 E0 50`; 16..63 are UTF-16LE `VIVID Camera Remote App` (23 characters + `0x0000`); 64..67 are the PTP-IP version `0x00010000` (LE32).

The 68 comes from `cmp w1,#68` in native `MngPTP::Open`; the 23 characters make "fixed length 68" and "GUID + variable-length UTF-16LE name + u32 version" resolve to the same byte string — **inference 1** as marked in the code (`FujifilmPtpIp.ets:16-19,265-274`; `NOTES_A.md §3.2`). An `Init_Fail` (type 5) reply takes the first 4 payload bytes as the error code and does not retry. `Init_Command_Ack` skips over "GUID + name + version" and then reads the u32 `connectionNumber` (default 1) for the event and live-view channels (`:415-431`).

### 5.4 Session and transactions

- `OpenSession(0x1002, sessionID=1)`; `0x201E` (session already open) is treated as success and does not reconnect (`FujifilmPtpIp.ets:364-372`).
- Transactions are strictly serialized (an internal `queue`); TransactionID increments and wraps from `0xFFFFFFFE` to 1 (`:505-511,609-613`). The `Operation_Response` payload is `u16 code + u32 tid + params[]`; tid is read at offset 2 first, and if that does not fit, at offset 4 (some firmware adds two bytes of alignment), with the parameter start moving accordingly (`:583-607`).
- Timeouts: connect 5 s, OpenSession 5 s, a single transaction 10 s, `InitiateOpenCapture` Phase1 30 s (`FujifilmProtocol.ets:106-114`). `OPEN_ATTEMPTS=6` exists only as a constant and a comment; no retry loop is implemented.

### 5.5 Data phase (512-byte blocks)

Phone → camera: `Start_Data` (payload is the u64 total length) → several `Data` packets (512 B each, the last may be short, and the final packet reuses `End_Data`) → wait for `Operation_Response` (`FujifilmPtpIp.ets:561-581`). Camera → phone: a `Start_Data` arriving before `Operation_Response` only has its payload discarded (the first 8 bytes are the u64 total length), `Data` packets are concatenated one by one, and `End_Data` terminates (`:526-542`). The block size is `FujifilmNet.DATA_BLOCK = 512` (`FujifilmProtocol.ets:115-116`).

`DataPhaseInfo` is **inference 2**: the CIPA convention is 1 = no data / 2 = DataIn / 3 = DataOut, while the protocol constant table gives 0/1/2, off by one. The implementation defaults to the CIPA convention and, at the end of `connect()`, probes once with `GetDeviceInfo(0x1001)`: data present → correct; response with no data → also counted as correct (the command may simply carry no data); no response → reconnect with the other encoding and probe again; if neither works, only log it and do not declare the session dead (`FujifilmPtpIp.ets:288-302,433-478`; `NOTES_A.md §3.4`).

### 5.6 Event channel

The `Init_Event_Request` payload is `connectionNumber` as LE32, with up to 1.5 s to wait for the Ack; on timeout, or if the first packet is already an event, reading continues and this is not treated as a failure (【inferred】 some firmware does not send an Ack, `FujifilmPtpIp.ets:643-660`). The event payload is `u16 code + 4 B tid + u32 params[]`, with parameters starting at offset 6 (`:685-701`). An idle read timeout of 4 s is normal polling; only an error that is not a timeout marks the session unavailable (`:663-683`).

### 5.7 Live view

After connecting to 55741, one `Init_Event_Request` is sent in the same shape as on the event channel: an Ack counts as success; a frame received is buffered and handed to the first `readLiveViewFrame`; on timeout the channel is still used (【inferred】 `FujifilmPtpIp.ets:707-743`; `NOTES_A.md §4.1`). Frame read: read the 12-byte header, and if `Length` falls within `[12, 204800]` read that many bytes, otherwise fall back to the fixed `LIVEVIEW_FRAME_BYTES=204800` (`:749-776`). The JPEG start is `LE32@12 + 18`, i.e. the u32 at in-frame offset 12 plus `LIVEVIEW_JPEG_HEADER_BIAS=18` (`:778-790`; `FujifilmProtocol.ets:126-130`). Both the frame-integrity criterion and the 18 offset are listed as 【unknown】 in `NOTES_A.md §4.2`.

### 5.8 Disconnect semantics

A failed read on any channel, a transaction timeout, or an event interruption → `markUnavailable()` → `close()`; afterwards every `op*` throws "PTP-IP session not established" and the page calls `connect()` again to rebuild the whole chain (`FujifilmPtpIp.ets:846-851`; `ROUTE_SPEC.md §2.1`). `close()` does not clear `onEvent` listeners (the firmware service reuses them across phases).

## 6. Control

### 6.1 Mode negotiation (`FujifilmControlService.connect()`)

| Step | Action | Timeout/retry | Failure handling |
|---|---|---|---|
| S01 | `FujifilmPtpIp.connect()` | 5 s | throw |
| S05 | `GetDeviceInfo(0x1001)` parses Model/Serial | 8 s | fall back to the BLE model |
| S11 | Wait for event 11 | 12 s | **timeout degrades**: record `degradedReason` and continue |
| S13 | `SetFunctionMode(20, 0xDF28, ≤3)` | 4102/0x2019 ×5 ×100 ms | throw |
| S14 | `SetCameraFunctionMode(6)` → `0x1016 [0xDF00]` | same as above | throw |
| S15 | `SetFunctionMode(22, 0xDF2A, ≤4)` | same as above | throw |
| S20 | `GetDevicePropDescAll(0x902B)` | 20 s | degrade; does not block shooting |
| S23 | `InitiateOpenCapture` Phase1 `0x101C` | 30 s | throw |
| S24 | Phase2 = open 55741 (no second PTP op) | 30 s | throw |
| S29 | Wait for event 11 again | 4 s | continue without it |
| S30 | `SetFunctionMode(5)` + `GetFunctionVersion(0xDF25)` + `SetFunctionVersion(0xDF24, 131083)` | 10 s | degrade only |

(`FujifilmControlService.ets:560-634,668-723,1401-1416`; `NOTES_B.md §3`.) `SetFunctionMode` writes `0x1016 [0xDF01] + u16`, not the standard PTP `0x5002` (`FujifilmProtocol.ets:249-261`; `NOTES_C.md §2.1` holds native immediate-value evidence).

### 6.2 Opcodes

| Code | Name | Purpose |
|---|---|---|
| `0x1001/0x1002` | GetDeviceInfo / OpenSession | camera model and serial; open a session (`0x201E` tolerated) |
| `0x1004-0x1008` | Storage/Object enumeration | object count, handles, object info fallback |
| `0x1009/0x100A/0x101B` | GetObject / GetThumb / GetPartialObject | whole object, thumbnail, chunked download fallback |
| `0x100E/0x1018/0x101C/0x9030` | Capture lifecycle | shutter, finish, prepare, cancel |
| `0x1014/0x1015/0x1016` | PropDesc / Get / Set | property read/write and version negotiation |
| `0x9020/0x9021/0x9022` | Movie / Postview | movie start/stop, postview |
| `0x9023/0x9024/0x9025` | Zoom trio | zoom (mapping conflict, see section 9 item 4) |
| `0x9026/0x9027` | Lock/UnlockS1 | S1 focus |
| `0x902B` | GetDevicePropDescAll | full property descriptors |
| `0x902C/0x902D/0x902E` | StepShutter/Aperture/EV | stepping |
| `0x9040/0x9042` + `0x9053-0x9056` | Firmware / image-transfer extensions | push; day counting, object info, thumbnails, chunked download |

(`FujifilmProtocol.ets:160-204`; `FujifilmControlService.ets:44-66`.)

### 6.3 Property codes

The control page's parameter catalogue holds 53 entries (`FujifilmControlService.ets:298-379`); the main ones:

| Group | Properties (codes) |
|---|---|
| Exposure | exposure mode `0x500E`, exposure compensation `0x5010` (step `0x902E`), shutter `0xD240` (`0x902C`), aperture `0x5007` (`0x902D`), ISO `0xD02A`, movie ISO `0xD02B`, metering `0x500B`, shutter standard `0x500D`, exposure index `0x500F` |
| Color | film simulation `0xD001` (1–20), white balance `0x5005` (12 values), image quality `0x5004`, RGB gain `0x5006`, exposure text color `0xD028` |
| Quality/size | pixel size `0x5003`, size code `0xD241` (1–34), contrast `0x5014`, sharpness `0x5015`, effect `0x5017`, digital zoom `0x5016` |
| Shooting | flash `0x500C`, self-timer `0x5012` (0/2/4), focus mode `0x500A` (1/32769/32770), drive `0xD246` (0/1), macro `0xD01D`, continuous/interval `0x5018-0x501B`, AF metering `0x501C`, movie enable `0xD019` |
| Focus | AF area `0xD245` (0–7), S1 AF frame `0xD17C`, AF in-focus `0xD209` |
| Status | battery `0x5001`, battery level segments `0xD242`, remaining shots `0xD229`, remaining recording time `0xD22A`, camera state `0xD21B` (0–17), zoom position `0xD170`, shutter type `0xD243`, CCD mode `0xD018` |
| System | function mode `0x5002`, focal length `0x5008`, focus distance `0x5009`, date/time `0x5011`, upload address `0x501D`, artist `0x501E`, copyright `0x501F`, property list `0xD212`, requested object `0xD220`, movie remaining frames `0xD2B7` |

Value ranges are hard-coded only where disassembly/CSV makes them explicit: the `shutterType` and `quality` enums are left empty and delegated to the descriptors, and `afSelect` carries only an index without inventing names (`FujifilmControlService.ets:286-296`; `NOTES_B.md §5.1`). The 8-byte record header of `0x902B` (`code u16 | getSet | rsv | type u16 | size u16` + payload) is confirmed by disassembly, but the position of `getSet` has three possible layouts; the parser tries all three and takes the table with the most entries; when `getSet` is all zeros it degrades to the catalogue's known writable items (`:818-899`; `NOTES_B.md §2.1-2.3`).

### 6.4 Writing values, stepping, and actions

- `setValue(code, value)`: `0x1016 [code] + an LE scalar of the property's dataType width`; on success the local value is updated and read back after 250 ms (`FujifilmControlService.ets:1191-1227,1296-1312`).
- `step(code, dir)`: shutter/aperture/EV go through `0x902C/0x902D/0x902E` (parameter `[dir]`); everything else moves one step through the descriptor enum and then calls `setValue` (`:1229-1278`).
- Actions: shutter `0x100E`, movie `0x9020/0x9021`, Postview `0x9022`, zoom `0x9023/0x9024/0x9025`, S1 `0x9026/0x9027`, cancel `0x9030` (`:1331-1399`).
- Busy retries recognize only `4102` and `0x2019`, 5 times × 100 ms; exit rollback: UnlockS1 → StopZoom → TerminateMovie → CancelCapture → close live view → TerminateOpenCapture → close, each step in its own try with 1.2 s (`:1717-1747,1946-1959`).

### 6.5 Events

What the event channel throws up is the **raw PTP event code**; the control layer first maps it to an SDK code using `CCameraEvent::ThreadProc` and then dispatches (`FujifilmControlService.ets:1434-1538`; `NOTES_B.md §3.1`):

| Raw | SDK | Handling |
|---|---|---|
| `0x4002` | 1 ADD_IMAGE | record |
| `0x4006` | 40 PROP_VALUE | apply directly if it carries a parameter, otherwise read back with `0x1015` |
| `0x4008` | 41 DEVICE_INFO_CHANGED | tell the page to refetch properties |
| `0xC004` / `0x400D` / `0xC001` | 30 / 31 / 32 | capture start / complete / Postview ready |
| `0xC005` | 43 AF_COMPLETE | callback |

Event 11 (camera requests a mode) and 40 have **no** branch in the native mapping table, so their origin is undetermined; the implementation therefore accepts both SDK codes and the raw codes in the table above, and degrades on timeout for event 11 (`NOTES_B.md §3.1`).

## 7. Image transfer

### 7.1 Session preparation

`connect()` → wait for event 11 (6 s, may time out) → `SetFunctionMode(20)` (on failure, retry one standard `OpenSession(1)` and continue) → read the `0xDF28` version (camera version > 3: log only, no write-back) → read the dual slot → enumerate the current slot (`FujifilmImportService.ets:384-415,506-571`; `NOTES_C.md §2.2-2.3`). The image-transfer page does not call `clearEventListeners()`, so the control and firmware listeners are not hit by mistake.

### 7.2 Dual slot (SD cards)

`0xD244` is a UINT8 property of `Get/SetDevicePropValue` with values 0–7 (`FujifilmProtocol.ets:279-280`; `NOTES_C.md §2.1`):

| status | current slot | slot count | switch mapping |
|---|---|---|---|
| 1 | 1 | 2 | →2 = 2 |
| 2 | 2 | 2 | →1 = 1 |
| 3 | 1 | 2 | →2 = 4 |
| 4 | 2 | 2 | →1 = 3 |
| 5 | 1 | 3 | →2 = 6, →3 = 7 |
| 6 | 2 | 3 | →1 = 5, →3 = 7 |
| 7 | 3 | 3 | →1 = 5, →2 = 6 |

`status=0` means no slot information: single-card models (X100 / X-E / X-Txx / X-S10 etc.) show one slot, everything else falls back to 2, and an empty card is greyed out but not hidden (`FujifilmImportService.ets:248-322`; `NOTES_C.md §3.3`). Switching slots first clears the list and thumbnail state → writes `0xD244` → re-reads storage → re-enumerates (`:729-792`).

### 7.3 Object enumeration

```
0x1015 [0xD22B] current handle → 0x1015 [0xD620] object count (fallback 0x1006) → 0x9053 [0, 30000] day-group counts (diagnostics only)
→ 0x1015 [0xD621] all handles (fallback 0x1007) → 0x9054 [handle] per-object info (fallback 0x1008)
```

(`FujifilmImportService.ets:798-1012`; `NOTES_C.md §4.1`.) Handles are fetched in one shot, without paging; both the bare-array and the `count + array` layouts are accepted; `0x9053` only logs and does not feed the UI. **No sorting**: camera order is preserved and `handles[0]` is the newest (`NOTES_C.md §4.2,§4.5,§8`).

`0x9054` object info = standard PTP ObjectInfo plus a proprietary `realFileFormat u32` at offset 48, and the filename is usually at 52 (UTF-16LE, NUL-terminated); parsing tries 48/52/44 in turn with sanity checking (`FujifilmImportService.ets:1014-1083`; `NOTES_C.md §4.3`). Format codes cover JPEG/JFIF/HEIF/RAF/MOV/MP4/PNG/TIFF; folders `0x3001` are skipped (`:848,1240-1300`).

### 7.4 Thumbnails

`0x9055 [handle]` (20 s), falling back to `0x100A` on failure; serial worker, queue limit 50, in-memory cache of 24, file cache `filesDir/fujifilm/thumbs/s<slot>_<handle>.jpg` (HEIC thumbnails are written as `.heic`) (`FujifilmImportService.ets:1373-1452`; `NOTES_C.md §5`). Camera thumbnails are **not orientation-corrected** raw pixels; before caching they are decoded → rotated → re-encoded according to `Orientation:<1–8>` in `0x9054`; the orientation is obtained by scanning the whole payload for the marker rather than relying on a fixed offset (`:1085-1148,1454-1493`; `NOTES_F.md §2-§4`).

### 7.5 Original download and persistence

| Condition | Path |
|---|---|
| `size ≤ 20 MiB` | `0x1009 [handle]` whole object; the length must equal size |
| larger, or whole-object failure | `0x9056 [handle, offset, ask]`, `ask = min(12582880, remain)` |
| `0x9056` throws | fall back to `0x101B [handle, offset, ask]` |
| verification | success only once `size` bytes have been received; on failure delete the `.part`, at most 2 attempts |

(`FujifilmImportService.ets:1653-1758`; `NOTES_C.md §6.1`.) Persistence: temporary file under `filesDir/fujifilm/` → `createAsset` + 8 MiB chunked copy → delete the copy on success; if the gallery refuses (common for RAF/HEIC), keep the app-directory copy and distinguish it in the wording (`:1760-1801`). Each image is also written to `RecentPhotoStore` with the orientation parameter fixed at 1 (thumbnails are already upright and the original's EXIF is normalized downstream); the camera thumbnail also serves as the fallback image (RAW/HEIC depend on it in particular) (`:1607-1630`; `README.md §3.1`). RAW and JPEG take the same enumeration/download path and differ only in format code (`0xB103`), extension/mime, and preview source; dual slot means SD1/SD2(/SD3), and there is no "JPEG slot / RAW slot" distinction.

## 8. Implementation cross-reference

| Area | Implementation | Basis | Status |
|---|---|---|---|
| Advertising identification | `parseAdvertisement()` | `01 §4.1/§4.4` | implemented, RED/legacy split |
| Scanning | 7 UUIDs, three-level degradation | `01 §2/§4.3` | implemented |
| GATT | MTU 185, `AP_STATE` subscription | `01 §7.2` | implemented |
| Pairing | key write-back + two RED steps | `01 §6/§7.2` | no PIN/bonding/encryption |
| Credentials | SSID/password read on demand | `01 §8` | password never persisted; abort on failure |
| Launch | `600655E6` 3/4/5 + `0x8001` | `01 §9` | implemented, 20 s cap |
| PTP-IP | 12 B header, 512 B blocks | `02 §3` | implemented |
| Init/data phase | GUID + 23-character name; CIPA 1/2/3 self-calibration | `native_ptp.md §4.2`, `02 §3` | **inferred** (68 B assumption, convention conflict) |
| Events/live view | resident reads on 55742; whole frames on 55741 + `LE32@12+18` | `02 §4`, `02 §7.1` | Ack timeout does not drop the link; channel initialization **inferred** |
| Control | mode negotiation 20/6/22 → 5 | `02 §4` | implemented, with degradation |
| Parameters | 53-entry catalogue + `0x902B` | `02 §5` | value ranges not invented |
| Image transfer | dual slot + `0xD22B/0xD620/0xD621` | `03 §3-§7` | implemented |
| Thumbnails/download | `0x9055`→`0x100A`; `0x1009`/`0x9056`/`0x101B` | `03 §6-§7` | implemented, with upright conversion and 2 retries |

## 9. Limitations and risks

1. **Inferred items**: the file header declares only two inferred values — the 23-character Init name (to make up 68 B) and the `DataPhaseInfo` convention (`FujifilmPtpIp.ets:16-19`); the live-view channel initialize is separately marked 【inferred】 in the function comment (`:707-714`). NOTES adds: live-view frame integrity (`NOTES_A.md §4.2`), the `AP_STATE` notification shape (§4.3), and the first 4 characters of the legacy-protocol name (§4.4).
2. **RED differs from the legacy protocol only on the BLE side**: advertising fields, the source of the short serial number, and two extra writes. The PTP-IP, control, and image-transfer layers contain no `red` branch at all; RED's Wi-Fi flow follows exactly the same path as the legacy protocol. This is a fact about the implementation; its correctness still needs confirmation on hardware.
3. **Firmware version differences**: `AP_STATE` is parsed only as LE u16, so if the firmware adds a length prefix, `0x8001` is never seen (`NOTES_A.md §4.3`); `0x201E` from `OpenSession` is treated as success; version negotiation skips the write when the camera version is greater than what the app supports (`NOTES_C.md §2.2`); during identity reads, a serial-number failure falls back to 0x2A25, a model failure falls back to 0x2A24 or the advertising name, and the firmware version (0x2A26) has no fallback value.
4. **Conflict 1 (zoom)**: `FujifilmProtocol.ets:192-194` records `0x9023=STEP / 0x9024=START / 0x9025=STOP`; `FujifilmControlService.ets:57-59` records `0x9023=START / 0x9024=STOP / 0x9025=STEP`. The control service sends commands according to the latter, so one of the two must be wrong.
5. **Conflict 2 (0x501F)**: the protocol table says `IMAGE_ASPECT = 0x501F` (`FujifilmProtocol.ets:275`), while the control catalogue says "copyright = 0x501F" (`FujifilmControlService.ets:373`).
6. **Documentation drift**: the control service header still states that the protocol file has `FILM_SIMULATION=0xD245` and `IMAGE_QUALITY=0xD244` (`FujifilmControlService.ets:37-42`), whereas the protocol file has moved to `0xD001`/`0x5004` and notes AF area `0xD245` and dual slot `0xD244` (`FujifilmProtocol.ets:277-282`).
7. **Host address is fixed**: `FujifilmPtpIp.connect()` only uses `FujifilmNet.HOST = 192.168.0.1` and does not accept `cameraHost`; the DHCP gateway computed by the page is only written into the session and never consumed by the PTP layer (`FujifilmProtocol.ets:101`; `FujifilmPtpIp.ets:359`; `CameraPage.ets:6071-6075`).
8. **Unwired constants**: `CHAR_UTC_AND_TIMEZONE`, `CHAR_LENS_FIRMWARE_VERSION`, and `CHAR_FW_UPDATE_STATE` are defined but have no read/write call site; `CURRENT_OBJECT_HANDLE_PARAM = 0x10000001` is likewise unused. The firmware service has a Chinese mapping of camera admission states but never reads `049EC406`; `OPEN_ATTEMPTS = 6` is also only a constant plus a comment, and a connection failure is thrown straight to the page.
9. **Origin of events 11/40 is undetermined**: they are absent from the raw-code mapping table, so the implementation stays compatible by "passing SDK codes through + degrading on timeout"; the degradation is written to `degradedReason` and shown on the page (`NOTES_B.md §3.1`).
10. **All three `0x902B` record-header layouts are tried**: a wrong choice does not return half a table (each payload must be consumed exactly), but the actual landing point on hardware is unconfirmed (`NOTES_B.md §2.2`).
11. **Undecoded parts of image transfer**: the `0x9053` response layout (`NOTES_C.md §8`), whether `0xD621` carries a count prefix, and whether the `0x9054` filename carries a PTP length prefix — all take compatibility branches or serve diagnostics only.
12. **Serialization and slot inference**: all PTP transactions share one queue, so thumbnails and downloads queue behind each other; live view sits on its own socket, but decoding loops on the main thread, and remote-control mode actively closes 55741 so the camera does not pour frames into nothing (`FujifilmControlService.ets:1576-1711`). With `status=0`, the slot count is guessed from the model prefix, which may show one extra greyed-out button (`FujifilmImportService.ets:266-286`; `NOTES_C.md §3.3`).
13. **Pairing failure is tolerated**: credentials are still read after a failed key write; if the camera really is unauthorized at that point, the failure only surfaces later, at the credential read or the hotspot association step (`CameraPage.ets:6007-6013`).

## 10. References

- Constants and implementation: `FujifilmProtocol.ets` (UUIDs/ports/opcodes/property codes/timeouts), `FujifilmPtpIp.ets`, `FujifilmBleService.ets`, `FujifilmModels.ets`, `FujifilmControlService.ets`, `FujifilmImportService.ets`, `FujifilmFirmwareService.ets`.
- Decision records: `docs/fujifilm/NOTES_A.md` (identification/BLE/PTP-IP), `NOTES_B.md` (control), `NOTES_C.md` (image transfer), `NOTES_D.md` (firmware), `NOTES_F.md` (orientation).
- Contract and overview: `docs/fujifilm/ROUTE_SPEC.md`, `docs/fujifilm/README.md`.
