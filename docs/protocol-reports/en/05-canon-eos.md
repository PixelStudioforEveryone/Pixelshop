# 05 · Canon EOS: BLE pairing, WAP network join, and PTP/IP transfer/remote control

**English** | [简体中文](../05-canon-eos.md)

> English translation of the Chinese original at baseline `18466be`; identifiers, UUIDs, opcodes, DPCs, ports, and `file:line` references are kept verbatim.

> Code baseline `18466be`. Read-only review of: `CanonProtocol.ets`, `CanonBleService.ets`, `CanonPtpIp.ets`,
> `CanonControlService.ets`, `CanonProperties.ets`, `CanonImportService.ets`, `CanonModels.ets`,
> `CanonModelImages.ets`, plus the Canon branch of `pages/home/CameraPage.ets`; the documents are
> `docs/canon-route-design.md` (hereafter "the contract") and `docs/canon-route-verification.md` (hereafter "the verification table").
> Line numbers are actual line numbers in the current workspace. **Fact** = directly checkable against code/contract; **Inferred** = evidence-backed, not confirmed on hardware (verification table §I.1).

## 1. Route positioning and boundaries

**Conclusion: BLE (Canon Camera Connect private GATT, limited to pairing/credentials/fetching the AP) + joining the camera AP + PTP/IP (TCP 15740) for transfer and remote control. CCAPI is not used.**

- A repository-wide search for `CCAPI|ccapi` returns no hits; the only HTTP client in the Canon services is at
  `CanonFirmwareService.ets:241`, `:599`, and it only downloads the official firmware manifest, taking no part in camera control; the only
  network channel to the camera is the TCP socket at `CanonPtpIp.ets:189`.
- The BLE table has only two groups, 0001 (session/registration/capabilities/events) and 0002 (WAP), plus the standard 180a, with **no** media/viewfinder
  characteristics (`CanonProtocol.ets:189-233`), so BLE carries neither parameters nor image transfer.
- All EOS parameter, shutter, viewfinder, directory, thumbnail, and original-image capabilities live in the PTP opcode set
  (`CanonPtpIp.ets:62-97`, `CanonImportService.ets:71-131`); the 8-byte packet header with types 1–12, the
  two TCP 15740 channels, and `Init_Command/Event` agree with ISO 15740 / CIPA DC-X005 (contract §3.1, cf. libgphoto2 `ptpip.c`).
- Inferred (scope): CCAPI requires the camera to open an additional HTTP service (commonly 8080); this project neither implements nor probes it,
  so "no CCAPI" is a current-state tradeoff, not a denial of CCAPI availability.

| Boundary | Approach | Source |
|---|---|---|
| BLE scan | Append one round, filter only the Canon primary service; failure does **not** degrade to a full scan; stops only its own round | `CanonBleService.ets:276-296`, `:254-260` |
| Identity | Camera 128-bit UUID (32-digit uppercase hex) written into `btAddress`; the BLE address can rotate and is not used as identity | contract §0.3, `CanonBleService.ets:57-58` |
| Routing/protocol values | `AppStorage['controlProtocol']='canon'`, `canonHost` | `CameraPage.ets:2962-2963`, `:3123` |
| Hotspot association | Reuses Panasonic's `LumixCameraService.connectToCameraWifi` | `CameraPage.ets:3096-3097` |
| Page cleanup | Image transfer `dispose()` does **not** close PTP/IP; only control page `shutdown()` does | `CanonImportService.ets:474-489`, `CanonControlService.ets:681-706` |

| Stage | Trigger point | Implementation | Artifact |
|---|---|---|---|
| Identification | camera page `startCanonBleDiscovery` | `startScan` + `CanonAdvParser` | `CanonBleCamera` (pid/UUID/rssi/power bits) |
| Pairing and registration | `ensureCanonWifi` | `connect` → `ensureBond` → `register` | bonding 12 (best effort) + `02` acknowledgement (may be absent) |
| Network join | same as above | read credentials → `startWap(9)` → `joinCanonWifi` | in-memory SSID/password + host (TLV IP) |
| Transfer/remote control | image transfer page/control page | `CanonPtpIp` + Import/Control | gallery, download, parameters, viewfinder |

(Entry points at `CameraPage.ets:2861`, `:2944`, `:2993`; failure of any stage only affects the Canon card.)

## 2. BLE advertising and identification

Service UUID form `0001xxxx-0000-1000-0000-D8492FFFA821`: the low 96 bits are fixed in `BASE_SUFFIX`
(`CanonProtocol.ets:191`), the first 8 digits distinguish channels (`00010000` primary service, `00010005` status…),
and the 0002 group is WAP. Note that `full()` (`:244-246`) only holds for 4-digit short UUIDs, whereas the Canon first segment is 8 digits;
that method currently has no callers (repository-wide search is empty), so it is not a runtime problem.

Advertising (manufacturer data Company ID 425 = 0x01A9, `CanonProtocol.ets:317`):

- `[0]` must be `== 1` (`organize`), otherwise it is not a Canon BLE camera (`:319`, `:352-354`);
- `[1..2]` little-endian = `usbId` (product ID), which is also the product number in the asset table and firmware manifest (`:325`, `:356`);
- Only two lengths are recognized (`:321-323`, `:351-388`): the 19-byte long format carries the 16B camera UUID (little-endian) in `[3..18]`
  and **no flags** (fixed `paired=false`, `powerState=1`, `:357-369`); the 6-byte short format puts `[3][4]`
  into `[14][15]` of a 16-byte array (the rest zero-filled), with `[5]` as flags (`:371-386`), so only the last 4 digits of the identity string are valid;
- flags: bit0 = paired, bit1-2 = power/pairing state 0/1/2 (`:334-337`); 0=AUTO_POWER_OFF,
  1=POWER_ON, 2=POWER_SWITCH_OFF (`:339-341`, `00010005` is runtime-synonymous, `CanonBleService.ets:1199-1207`);
- Enqueueing looks only at manufacturer data `organize==1`; the service UUID merely supplements `hasSessionService` (`:397-439`);
- Identity string = 16 bytes reversed, then emitted as 32-digit uppercase hex in big-endian order (`:448-456`), matching the official practice of taking the last 4 digits of the UUID.

Scanning (`CanonBleService.ets:205-296`): the only `ScanFilter` is the primary service (`:277-281`,
`SCAN_SERVICE_UUIDS` has a single entry, `CanonProtocol.ets:241`); `SCAN_MODE_LOW_LATENCY` +
`MATCH_MODE_AGGRESSIVE`, `interval: 0` (`:282-286`); a 60 s round expires with stop→start (`:226-236`);
if already scanning, only the callback is swapped (`:207-210`); a failed filtered scan is only logged, and the system round is reused with
425 filtering applied in the callback (`:276-296`, `:298-305`); repeated callbacks for the same device are rate-limited to 3 s in logs, not in callbacks (`:320-338`).

Model table (`CanonModels.ets` + `CanonModelImages.ets`): 95 entries, `pid` being the advertising `usbId`
(`CanonModelImages.ets:16`), e.g. `0x3250 EOS 6D`, `0x3281 EOS 5D Mark IV`, `0x32d2 EOS M50`,
`0x32da EOS R`, `0x32f4 EOS R5`, `0x32f5 EOS R6`, `0x32fc EOS R3`, `0x330b EOS R6 Mark II`,
`0x3313 EOS R1`; anything unlisted takes the form `Canon 0x32FB`. `identityFromPid` matches in three tiers (pid → advertised name →
fallback, `CanonModels.ets:100-126`), `imageKey='canon_'+slug`, empty string when unlisted;
`cleanAdvertisedName` strips the `CANON` prefix/separators, fixes spacing when the asset table matches, and caps length at 40 (`:41-64`).

## 3. GATT table (based on the UUIDs actually present in the code)

The attribute column is the code-side expectation; at runtime the camera-reported `properties` prevail (`CanonBleService.ets:447-481`);
when the registration/capability/event characteristics are missing, `requireSessionChannels()` throws `CHARACTERISTIC_MISSING` (`:408-424`).

| UUID (first segment) | Owner | Code-expected properties | Code usage | Source |
|---|---|---|---|---|
| `00010000` | service 0001 | primary service | sole ScanFilter + session service | `CanonProtocol.ets:194`, `:241` |
| `00010005` | 0001 | read + notify | session/power state 0/1/2 | `:196`; subscribe `CanonBleService.ets:435`; parse `:1199` |
| `00010006` | 0001 | write(no rsp) + indicate | registration `01`+nickname; replies `02`=OK | `:198`; write `:643`; ack `:1128-1135` |
| `0001000a` | 0001 | write(no rsp) | session commands `03`/`04`/`05`/`0A` | `:200`, `:477-489`; write `:1039`, `:1066`, `:1081` |
| `0001000b` | 0001 | read | 4-byte capability bitmap | `:202`; read `:695-708` |
| `0001000c` | 0001 | indicate | WiFi event type 1–6 | `:204`, `:583-601`; parse `:1138-1196` |
| `00020000` | service 0002 | — | WAP service container | `:207` |
| `00020001` | 0002 | read | WAP capability bits (bit4 = START with security type supported) | `:209`; read `:902-915` |
| `00020002` | 0002 | write + notify | WAP command; TLV response | `:211`; write `:946`; TLV `:1210-1221` |
| `00020003` | 0002 | indicate | `[code][subCode]` status | `:213`; subscribe `:443`; parse `:1224-1233` |
| `00020004` | 0002 | read | handover SSID | `:215`; read `:812` |
| `00020005` | 0002 | read | handover password (never persisted/never logged) | `:217`; read `:813` |
| `00020006` | 0002 | read | security type list (int32 little-endian array) | `:219`; `:832-842`, `:918-930` |
| `0000180a` | standard DIS | read | 2a29/2a24/2a26/2a28/2a25 | `:222-230`; `:711-723` |
| `00002902` | CCCD | write | notify=`01 00`, indicate=`02 00` (written by the platform API) | `:233` |

Read/write details: reads time out at 5 s, writes at 4 s (`CanonBleService.ets:92-94`); writes prefer `WRITE_NO_RESPONSE` and
only fall back to `WRITE`, with a log line, when rejected (`:1336-1359`); GATT operations are serialized by the `ioBusy` lock, queuing across pages as well
(`:1402-1411`). The WAP service may be missing on older firmware: a failed subscription is only logged and the link continues (`:436-441`).

## 4. First-time pairing sequence

1. **Connect**: `connect(deviceId)` → reuse `LumixImportPrototype.connectGatt` (handles RPA address write-back)
   → `getServices()` → attach `BLECharacteristicChange`/`BLEConnectionStateChange` → record `bondState`
   → `requireSessionChannels()` → `armChannels()` (`CanonBleService.ets:362-405`).
2. **Subscribe**: 00010006 (indicate preferred), 0001000c (indicate), 00010005 (notify),
   00020002 (notify), 00020003 (indicate), degrading to actual support (`:432-481`).
3. **Bonding**: `bondState()` normalizes HarmonyOS `getPairState` 0/1/2 with the Android 10/11/12 convention (`:534-556`).
   `ensureBond`: 12 passes straight through, 11 is not re-initiated, otherwise `pairDevice(address)` (`2900099` treated as "already bonded"),
   polling every 400 ms for at most 8 s waiting for 12; on timeout it only logs and continues (`:571-610`).
4. **Registration frame**: `00010006 = 01 + nickname`, US-ASCII, nickname truncated to 20 bytes (`CanonProtocol.ets:532-539`);
   written 3 times (each round waits 6 s for indicate `02`), a write failure immediately cancels the waiter; 3 attempts without acknowledgement return `false` **without throwing**
   (`CanonBleService.ets:623-662`). When the camera UUID is all zeros the official app sends no registration frame at all, and a brand-new body may never reply
   `02` (`:329-331`, `:616-621`; contract §10.1).
5. **Sleep prohibition**: `0001000a = 0A 01`/`0A 02`, written only when capability bit 0x40 is set, otherwise only logged
   (`:1027-1047`, `CanonProtocol.ets:573-576`); `prohibitSleep()` is a synonymous alias.
6. **WAP commands**: `01`=START, `04`+int32 little-endian 9=`04 09 00 00 00`, `0A`=REQUEST_AP_CONFIG,
   `02`=STOP, `03`=CANCEL (`CanonProtocol.ets:492-529`). `startWap(9)` first reads `00020001` bit4 and
   the `00020006` list; only when both are satisfied does it send `04 09 …`, otherwise it falls back to `01` (`CanonBleService.ets:863-884`).
7. **Handover criteria**: consume both the `00020002` TLV and the `00020003` `[code][subCode]`; `Code=1/Sub=3`
   (or `Code=2/Sub=3`) counts as accepted, `Code=1/Sub=4..9` as rejected; after acceptance it still waits for the full IP
   (`:995-1020`, `CanonProtocol.ets:694-729`). The READY bit `0x100000` is kept only as a constant and **takes no part in the decision**:
   the TLV only sets `0x10000`, so the two contradict each other inside the APK (`CanonProtocol.ets:638-660`; contract §10.3).
8. **TLV**: the main path unconditionally skips the first 2 bytes (`:751-773`); if no known tag parses, it retries once as "headless"
   (inferred: older firmware may deliver bare TLV). `0x10` IP 4B little-endian→dotted decimal; `0x02` BSSID 6B little-endian→12-digit
   uppercase hex; `0x30` WTIME — the official app reads only 1 byte, does not reverse it, and interprets it as `%d00`, whereas the code uses u32 when ≥4B and 1B otherwise,
   uniformly ×100 to get milliseconds (`:797-812`; contract §10.2).
9. **Remaining session words**: `03`+16B reversed UUID, `04`+nickname, `05 02` (`CanonProtocol.ets:547-570`);
   `writeSessionUuid` accepts only 32-digit hex / 8-4-4-4-12 and throws `INVALID_ARGUMENT` on a wrong length
   (`CanonBleService.ets:1055-1073`).
10. **Cleanup**: `disconnect()` stops the scan round, cancels registration/credential/WAP waiters, clears one-shot timers, unsubscribes, and
    `disconnect()`+`close()`s GATT (`:489-527`).

Error codes (`CanonBleError.code`, `CanonProtocol.ets:861-873`): 0 LOCAL, 1 NOT_CONNECTED,
2 CHARACTERISTIC_MISSING, 3 WRITE_FAILED, 4 READ_FAILED, 5 TIMEOUT, 9 INVALID_ARGUMENT,
10 CREDENTIAL_UNAVAILABLE are all in use; **6 BOND_FAILED / 7 REGISTER_REJECTED / 8 WAP_REJECTED
are never thrown** — bonding failure, registration without acknowledgement, and WAP rejection all degrade to `false` / `ok=false` (repository-wide hits are the definitions only).

## 5. Wi-Fi

- Form: the camera runs its own AP and the phone associates as a STA; inside the AP the camera is the gateway (corroborated by the comments at `CameraPage.ets:3111-3112` and
  "fall back to `linkedGateway()` when there is no IP"). The DHCP server role is **inferred**.
- SSID rules: **the code does not construct an SSID**, nor does it derive prefixes/suffixes — the SSID appears only in "read the value pushed by the camera" and in the
  log/association paths (`CanonBleService.ets:736-829`, `:1138-1166`). The AP name is decided by the camera body (inferred).
- Two sources of credentials: ① `0001000c` indicate (type1=SSID, 2=password, 3=security, 4=result,
  `CanonProtocol.ets:583-601`), with received credentials reusable for 30 s (`CanonBleService.ets:742-755`, `:108-109`);
  ② fallback to direct reads of `00020004/05/06` (`:807-842`). Criterion: SSID non-empty and (password non-empty or OPEN), otherwise throw
  `CREDENTIAL_UNAVAILABLE` (`:784-801`). The password lives only in memory and on the function stack, never persisted and never logged (`:1156-1157`).
- Association: `securityType` is fixed at 3 (HarmonyOS WPA2-PSK), and association is delegated wholesale to the Panasonic implementation
  (`CameraPage.ets:3084-3097`); this is a constant rather than a camera-reported value, an implementation tradeoff.
- Address and port: host = IP from WAP TLV `0x10` → `linkedGateway()` → fallback `192.168.1.2`, written to
  `AppStorage['canonHost']` (`:3113-3123`). The port is fixed at **15740** (`CanonPtpIp.ets:466`).
  Control/image transfer pages obtain the host via `AppStorage['canonHost']` → `linkedGateway()`
  (`CanonControlService.ets:189-197`, `CanonImportService.ets:1285-1298`).

## 6. PTP/IP transport layer

- Two TCP channels: command + event, both 15740 (`CanonPtpIp.ets:466`, `:550`, `:570`).
- Framing: 8-byte header = length u32 (including header) + type u32, both little-endian; a length `<8` or above the cap is illegal
  (`CanonTcpChannel.readPacket`, `:242-252`). Per-packet cap: 64 MiB on the control channel, 256 KiB on the event channel (`:469-471`).
- Handshake: `Init_Command_Request`(1) payload = 16B fixed GUID + UTF-16LE name + 2B NUL + version
  `0x00010000` (`:551-558`, `:485-493`); read `Init_Command_Ack`(2), take `connectionNumber` from the first 4B of the payload
  (default 1), and `Init_Fail`(5) throws (`:559-567`). The event channel sends `Init_Event_Request`(3) with payload =
  connectionNumber, reads `Init_Event_Ack`(4), then starts the resident read loop; event channel failure only degrades (`:568-583`).
- Session sequence: `OpenSession(0x1002, session=1)` → `SetRemoteMode(0x9114, 1)` →
  `SetEventMode(0x9115, 1)` → `KeepDeviceOn(0x911D)` → `GetDeviceInfo(0x1001)`; failure of the last three steps is only
  logged (`:584-604`). Close: `CloseSession(0x1003)` (3 s) then close both sockets (`:611-633`).

| Type | Name | Use in this project |
|---|---|---|
| 1/2 | Init_Command_Request / Ack | handshake (`:558`, `:559`) |
| 3/4 | Init_Event_Request / Ack | event channel handshake (`:571-577`) |
| 5 | Init_Fail | command channel treats it as failure (`:560-562`); event channel only logs |
| 6/7 | Operation_Request / Response | all transactions (`:678-696`) |
| 8 | Event | asynchronous events, handled on both channels (`:797-799`, `:822`) |
| 9/10/11 | Start_Data / Data / End_Data | receive/send data phase (`:727-741`, `:764-775`) |
| 12 | Cancel_Transaction | **defined but unused** (`:38`, no second reference) |

- Request: `dataPhase(u32) + opcode(u16) + transactionId(u32) + parameters(u32 little-endian)` (`:678-684`).
  dataPhase takes `NONE=1 / IN=2 / OUT=3` (`:42-46`), which disagrees with the wording "no data/receive data = 1, send data = 2" in contract §3.1;
  the code follows the CIPA convention (inferred: the standard says so, and the code is more likely correct).
- Response: `code(u16) + transactionId(u32) + parameters`, with parameters starting at offset 6 (`:686-696`); transaction IDs auto-increment and
  skip 0 (`:672-676`); all transactions are serialized through the single `runExclusive` queue, and the event pump does not jump it (`:654-670`).
- Data phase: in the receive direction `Start_Data` reads the total length (u64 @4), and `Data`/`End_Data` each strip 4 bytes of transactionId
  before reassembly (`:716-754`); in the send direction data is sliced by 1 MiB, `Start_Data(txid+u64 length)` first, then `Data`, and finally
  `End_Data` (`:756-778`).
- Timeouts: handshake 6 s, command 10 s, data fetch 15 s (`:473-477`); a 4 s timeout in the event read loop is treated as "no event" and the loop continues
  (`:821-827`); `GetEvent` has a 1 s minimum and returns an empty array on timeout (`:858-870`).
- DeviceBusy: on `0x2019`, wait 120 ms and resend once (`:787-793`). **Defect**: the resend uses
  `buildOperationRequest(opcode, transactionId, [], NONE)` and the original parameters are dropped (`:792`), so commands with parameters
  (property reads, chunked image fetch) are retried with empty parameters and most likely come back as `0x2006`.
- Event blob: `[size u32][code u32][payload]` loop, stopping at `size<8`, out of bounds, or `size==8 && code==0`
  (`:873-894`). `0xC189`: dpc@0, value@+4 (i.e. `0x0c` relative to the blob), read by the control layer as `data.subarray(4)`
  (`CanonControlService.ets:369-383`); `0xC18A`: dpc@0, type@+4, count@+8, values@+12 (absolute
  `0x14`), read as one u32 per count (`:384-402`).
- Asynchronous Event packet = `code(u16) + txid(u32) + parameters`, with parameters from offset 6 (`:835-851`); listener exceptions are swallowed.
- Device information is parsed in ISO 15740 §13.2 order (`:906-932`), taking only vendor name/model/version/serial number/standard opcodes.

EOS opcode usage (constant table `CanonPtpIp.ets:62-97`, `CanonImportService.ets:71-131`):

| Purpose | Opcode | Call site |
|---|---|---|
| Session/events | `0x1001` `0x1002` `0x1003` `0x9114` `0x9115` `0x9116` `0x911D` | `CanonPtpIp.ets:584-621`, `:862` |
| Properties | `0x1015` read, `0x9110` write, `0x1014` descriptor | `:977`, `:968`, `CanonControlService.ets:244` |
| Shutter/AF/zoom | `0x9128` `0x9129` `0x9154` `0x9160` `0x9158` `0x915A` | `CanonControlService.ets:578-653` |
| Viewfinder | `0x9151` `0x9152` `0x9153` | `:471-497`, `CanonPtpIp.ets:986` |
| Storage/directories | `0x9101`/`0x1004`, `0x9102`/`0x1005`, `0x1007`, `0x1008` | `CanonImportService.ets:527-689` |
| Image transfer | `0x910A`/`0x100A`, `0x9104`/`0x1009`, `0x912C`, `0x9132` | `:786-1020` |
| Firmware | `0x100C` `0x100D` `0x911F` | `CanonFirmwareService.ets:412-464` |
| Defined, unused | `0x9127` RequestDevicePropValue, `0x9155` DriveLens, `0x914D` DrivePowerZoom | `CanonPtpIp.ets:76`, `:87-88` (no callers) |
| Undefined | `0x9109` GetObjectInfoEx | neither constant nor implementation (verification table C5) |

## 7. Control and transfer

### 7.1 Property get/set

`get = GetDevicePropValue(0x1015, [dpc])` (`CanonPtpIp.ets:977-984`);
`set = SetDevicePropValueEx(0x9110)`, payload `[dpc u32][value u32]` (`:968-975`).
Descriptor read is `0x1014`: `getSet` bit0 decides writability, and enumerations are parsed only when `formFlag==2` (`CanonControlService.ets:241-276`).
The 14-entry property table (`CanonProperties.ets:62-139`; the EDSDK column is copied from contract §4.1, the DPC column comes from libgphoto2):

| key | Chinese label | EDSDK | PTP DPC | Encoding | Writable without descriptor |
|---|---|---|---|---|---|
| `mode` | 曝光模式 (exposure mode) | 0x0400 | 0xD105 | u32 | No |
| `shutter` | 快门 (shutter) | 0x0406 | 0xD102 | APEX×8 | Yes (local candidates, marked inferred) |
| `aperture` | 光圈 (aperture) | 0x0405 | 0xD101 | APEX×8 | Yes (same as above) |
| `iso` | ISO | 0x0402 | 0xD103 | u32 | Yes (same as above) |
| `ev` | 曝光补偿 (exposure compensation) | 0x0407 | 0xD104 | i32 1/8 EV | Yes (same as above) |
| `quality` | 画质 (image quality) | 0x0100 | 0xD120 | u32 | No |
| `wb` | 白平衡 (white balance) | 0x0106 | 0xD109 | u32 | No |
| `drive` | 驱动模式 (drive mode) | 0x0401 | 0xD106 | u32 | No |
| `bracket` | 包围曝光 (exposure bracketing) | 0x040A | 0xD11D | u32 | No |
| `focus` | 对焦模式 (focus mode) | 0x0404 | 0xD108 | u32 | No |
| `metering` | 测光 (metering) | 0x0403 | 0xD107 | u32 | No |
| `zoomSpeed` | 变焦速度 (zoom speed) | 0x0444 | 0xD149 | u32 | Yes |
| `lvOutput` | 取景输出 (viewfinder output) | 0x0500 | 0xD1B0 | bitmask | Yes (internal) |
| `lvMode` | 取景模式 (viewfinder mode) | 0x0501 | 0xD1B1 | u32 | Yes (internal) |

Option source priority: `0x1014` descriptor → `0xC18A` event → local candidates for continuous quantities (`inferred`); for enumerations without a camera-provided
list a static text table is used but with `writable=false` (`CanonControlService.ets:200-234`, `:369-402`). Writes are
debounced 500 ms and overwritten per key (`:314-334`, `:336-351`), and failures only prompt, never throw. The event pump runs a round every 400 ms
(`:357-367`), and `0xC181`/`0xC187` trigger the capture-complete and device-changed callbacks (`:403-407`). Value formatting: aperture
`2^(apex/2)`, shutter `2^(-apex)`, with 0/`0xFFFFFFFF` displayed as `--` (`CanonProperties.ets:281-302`).

### 7.2 Shutter / movie / viewfinder / focus / zoom

- Shutter five-parameter form: `switch=(param>>16)&0xFFFF`, `action=param&0xFFFF`, calling `RemoteReleaseOn(0x9128)`
  with two parameters (`CanonControlService.ets:589-602`); a full press uses param 3 (with AF) or `0x10003` (without),
  held for 220 ms and then released (`:546-562`); a half press uses 1 / `0x10001` (`:565-573`); param 0 is equivalent to firing
  `RemoteReleaseOff(0x9129,[1])` and `[2]` back to back (`:576-587`). The mapping is derived (contract §4.2); logs print the actual values.
- Movie recording: PTP has no verified recording command, so `toggleMovie()` returns `false` and prompts for the camera button (`:666-669`);
  `isMovieMode()` only looks at exposure mode value 11 (`:672-675`).
- Viewfinder: `0xD1B0 |= 2` → `InitiateViewfinder(0x9151)` → loop `GetViewFinderData(0x9153,[0x00200000])`
  → `TerminateViewfinder(0x9152)`; an empty frame waits 60 ms, and 5 consecutive failures stop the stream (`:458-533`, `:30-34`);
  stopping clears bit1 of `0xD1B0` (`:501-506`).
- Focus: `DoAf(0x9154)` / `AfCancel(0x9160)` (`:604-611`); tap-to-focus first sends `SetLiveAfFrame(0x915A)` with
  a 4×u32 rectangle (`x1,y1,x2,y2`, half-width 40 px) and then `DoAf`; the layout is unverified and degrades when rejected (`:613-637`).
- Zoom: write `0xD149` speed first (when writable), then send `Zoom(0x9158)`, with direction clamped to 0..2 (`:639-660`);
  `0x914D` DrivePowerZoom exists only in the constant table (`CanonPtpIp.ets:88`, verification table C5).

### 7.3 Volumes, directories, thumbnails, downloads (`CanonImportService.ets`)

- Volumes: `0x9101` falls back to `0x1004` on failure (`:527-545`); **storageId=0 is filtered out** (in PTP, 0 means all volumes,
  `:539-543`); per volume `0x9102` → `0x1005` (`:547-575`), with the label taken from `VolumeLabel`, else
  `StorageDescription`, else `卡 N` (card N) (`:505`, `:1113-1117`); the sizes must be self-consistent (capacity>0 and free≤capacity)
  to be valid (`:1119`), and when unparseable the volume is still listed with values of 0 (`:568-571`).
- Directories: BFS recursing from `parent=0`, preserving the original `GetObjectHandles` order with no client-side sorting; defensive caps of
  2048 directories/depth 12/200000 objects (`:604-660`, `:63-66`). `0x1007` first sends 3 parameters
  `(storage, 0, parent)`, falls back to 2 parameters on `0x2005/0x2006`, and treats any other non-OK as an empty directory (`:662-680`).
- Entries: `0x1008` datasets <53B are discarded; offsets `storage@0`, `format@4(u16)`, `size@8`, `parent@38`,
  filename from `@52` as a PTP string (`:682-689`, `:1080-1099`). Filtered out: directories `0x3001` and
  Text/DPOF/WAV/MP3/XML; video covers MP4 `0xB982`, AVI/MPEG/ASF/QT; RAW covers CRW/CRW3/CR3
  (`:108-131`, `:1158-1204`). `imageId=storageId+':'+handle`, `groupId` is the directory number (`:638-650`).
- Thumbnails: `0x910A` → `0x910A[handle,0]` → `0x100A`, leaving an empty placeholder on failure (`:786-797`); cached at
  `filesDir/canon_thumb/<storageId>_<handle>.jpg`, serial, 6 requests per round at 160 ms spacing, yielding during downloads
  (`:724-783`, `:44-52`).
- Downloads: one image at a time, 1 MiB chunks via `0x912C`; the 4-parameter form `(handle, offset, len, 0)` is rejected and switched to 3 parameters and remembered
  (`:969-991`); if the first chunk fails, the whole object falls back to `0x9104`→`0x1009` (64 MiB cap, abandoned when exceeded, `:994-1007`);
  success/cancel/failure all send `0x9132` in `finally` (`:1010-1020`); data is written to `.part`, verified byte-count against
  `ObjectInfo.size`, then renamed (`:893-966`), and `createAsset` adds it to the gallery, logging only on failure (`:1022-1040`).
- Cancellation: sets a flag, exits between chunks, stops at the current entry and keeps already-downloaded files (`:804-810`, `:873-875`).

## 8. Implementation cross-check table

| Capability | Contract/verification table requirement | Code fact | Verdict |
|---|---|---|---|
| Control protocol | No CCAPI | No trace of CCAPI, no camera HTTP channel | Consistent |
| BLE scan | Single ScanFilter + LOW_LATENCY, restart every 60 s | `CanonBleService.ets:277-290`, `:226-236` | Consistent |
| Advertising parsing | 425, `[0]==1`, 19/6 bytes | `CanonProtocol.ets:351-439` | Consistent |
| GATT table | 0001/0002/180a/CCCD | `CanonProtocol.ets:189-233` + `armChannels` (`CanonBleService.ets:432-444`) | Consistent |
| Bonding | bond only at 10, wait for 12, 2900099 counts as bonded | `CanonBleService.ets:571-610` | Consistent |
| Registration | `01`+nickname, 3 attempts waiting for `02` | `CanonBleService.ets:623-662` | Consistent (no throw on failure) |
| WAP command/preconditions | `04 09 …` requires bit4 and a list containing 9 | `CanonBleService.ets:863-884` | Consistent |
| TLV/status | skip 2 bytes, 1B WTIME, code/subcode | `CanonBleService.ets:751-827`, `CanonProtocol.ets:694-729` | Deviation (dual-parse fallback) |
| PTP/IP handshake | dual 15740 + Init 1/2/3/4 | `CanonPtpIp.ets:538-583` | Consistent |
| Session sequence | 0x1002→0x9114→0x9115→0x911D | `CanonPtpIp.ets:584-600` | Consistent (last three may fail) |
| Transactions/retry | 6/7/9/10/11, Busy retry | `CanonPtpIp.ets:704-809` | Deviation (retry drops parameters) |
| Event blob | `[size][code][payload]`, value `@0x0c`, list `@0x14` | `CanonPtpIp.ets:873-894` | Consistent |
| Property table | 14 EDSDK↔DPC entries | `CanonProperties.ets:62-139` | Consistent |
| Shutter five parameters | 0/1/0x10001/3/0x10003 | `CanonControlService.ets:546-602` | Inferred (high/low word split) |
| Viewfinder | Initiate→loop→Terminate | `CanonControlService.ets:458-533` | Consistent |
| Movie recording | no PTP command | `CanonControlService.ets:666-669` returns false | Consistent (explicit failure) |
| Volumes/directories | volume as the unit, no sorting, recursive | `CanonImportService.ets:495-680` | Consistent |
| Thumbnails/downloads | 0x910A cache, 0x912C chunks + 0x9132 | `CanonImportService.ets:786-1020` | Consistent |
| Contract §3.4 wrapper API | `getObjectHandles`/`getThumb`/`getPartialObject` etc. | **Not implemented**: `CanonPtpIp.ets:949-991` has only `getStorageIds`/`setDevicePropValueEx`/`getDevicePropValue`/`getViewFinderData`; the rest is done by Import/Control calling `op/opIn/opOut` directly | Deviation (functionally equivalent) |
| Contract §3.3 signature | `connect(host, name)` | `connect(host, name, timeoutMs=10s)` | Deviation (extra optional parameter) |

## 9. Limitations and risks

1. **No hardware validation**: BLE advertising, WAP handover, PTP/IP, viewfinder, shutter, image transfer, and firmware are cross-checked statically only
   (verification table §I.1); items marked "inferred" are reflected in the table above.
2. **Model differences**: older firmware may lack the 0002 group (WAP unavailable, credentials can only be read directly); `0x9101/0x9102/0x910A/0x912C`
   all have fallback branches (contract §3.4), but which bodies return `0x2005/0x2006` is unverified; empty or read-only cards may report no sizes
   (shown as 0). None of these branches has on-hardware coverage.
3. **BLE address rotation**: identity uses the camera UUID, but the short format keeps only the last 4 valid digits and a brand-new body has an all-zero UUID, at which point identity
   is not unique and only UI order helps (`CanonBleService.ets:329-331`); `getPairState` may return 0 for a BLE address
   (not a BR/EDR address), degrading bonding to "try `pairDevice` once and then wait 8 s" (`:581-584`).
4. **Retry after registration failure**: 3 attempts × 6 s without `02` return `false` and continue; if the camera requires a successful registration before handing out credentials, the flow
   ends at the WAP stage with "no SSID", and the user sees a Wi-Fi failure rather than a registration failure.
5. **WAP READY bit unreachable**: `0x100000` conflicts with the `0x10000` that the TLV alone sets, so the implementation switched to "status code + TLV IP";
   if the camera sends only status and no TLV, ok can only be decided by the timeout branch (`:954-962`).
6. **TLV header assumption**: skipping 2 bytes comes from the APK, and headless parsing is an inferred fallback; when a 2-byte header is present but the first tag is unknown, both
   parses may fail → no IP → fall back to the gateway address.
7. **DeviceBusy retry drops parameters** (`CanonPtpIp.ets:792`): a command with parameters may become a parameter error because of the retry; keeping the original request body is recommended.
8. **APEX×8 assumption**: aperture and shutter both use APEX×8 (1/125 s≈56, f/4≈32), consistent with "APEX fixed point" in contract §4.1
   but not verified on hardware; a different value range only requires changing `CanonFormat` (verification table §I.4).
9. **Enumeration text localization**: when the camera provides no list, the EDSDK-convention Chinese table is used, and unknown values display as `#decimal`; continuous-quantity candidates are marked
   `inferred` and may not match the specific body's steps. The 4×u32 layout for tap-to-focus is equally unverified, and `0x914D` is not wrapped.
10. **Movie recording unavailable**: there is no PTP command, so the button necessarily fails; recording exists only in the BLE remote service `00030030` (not implemented).
11. **Permissions**: requires `ACCESS_BLUETOOTH`, `LOCATION`/`APPROXIMATELY_LOCATION` (a system requirement for BLE scanning),
    `GET_WIFI_INFO`/`SET_WIFI_INFO`, `GET_NETWORK_INFO`, `INTERNET`, `WRITE_IMAGEVIDEO` (gallery save),
    see `entry/src/main/module.json5`; without permission the scan/association/TCP/gallery steps fail, writing only logs and page text.
12. **Session sharing**: image transfer `dispose()` does not close PTP/IP, while control page `shutdown()` does; when both pages are alive, whichever control page exits first
    cuts off the image transfer page's session (the tradeoff is declared in the comment at `CanonImportService.ets:474-489`).
