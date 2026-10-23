# Panasonic LUMIX Lab Line Technical Report: Wi-Fi AP + /remote/* REST + DTLS Live View

**English** | [简体中文](../01-panasonic-lumix-lab.md)

> Translated from the Chinese original at baseline `18466be`; identifiers are kept as-is.

> Scope: the Lumix services under `entry/src/main/ets/services/` and the related control pages, at baseline commit `18466be`. Code and comments were read only; no source was modified. Line numbers refer to that commit of this repository; all facts come from code, and inferences are marked separately.

## 1. Line placement

### 1.1 Partitioning of the three lines

| Line | Body token set | Control protocol | Wi-Fi credential source | Implementation in this repo |
|---|---|---|---|---|
| Lab (this report) | `S5M2X S5M2 S1RM2 S1RII S1M2E S1IIE S1M2 S1II S9 GH7 G9M2 G9II L10` | `/remote/*` + `/lut/*`, DTLS live view | BLE GATT registration + SSID/password issued by the camera (carried in by the shared BLE flow) | `LumixControlService.ets` |
| Sync | `S1H S1R G100D G100 GH5M2 GH6 GH1` (Lab already subtracted) | `cam.cgi` + `X-SESSION_ID` | LUMIX Sync–style BLE pairing | `LumixSyncControlService.ets` |
| Image App | `TZ99 ZS99 G90 … GH5S G9 GH5 G97 GH3` | `cam.cgi` + DLNA/DMS | Manual hotspot selection / QR code / NFC | `LumixCameraService.ets`, `PanasonicS5Receiver.ets` |

The provenance of the Lab table is stated explicitly: these are the marketing body names from the "byte → model" table (`M0`, code values 1..9) in the official LUMIX Lab APK, that is, the bodies that carry a compact model code in the advertisement and that Lab reads. The aliases `S1RII / G9II / S1II / S1IIE` are kept alongside the marketing names because the camera or an API reply may return either spelling (`LumixCameraService.ets:293`).

The Sync table is not guesswork: in `T5/d.java` of LUMIX Sync 2.0.17, `b(String)` explicitly assigns `DC-S5M2 / DC-S5M2X / DC-S9 / DC-GH7 / DC-G9M2` to Lab (used for the `ON_LUMIX_LAB_INSTALL_DIALOG / ON_LUMIX_LAB_LAUNCH_DIALOG` copy), so S9 belongs to Lab (`LumixCameraService.ets:305`). The Sync table subtracts the Lab table at its definition, which keeps the two lines mutually exclusive; the subtraction only tests exact token equality, so Sync's `S1R` can coexist with Lab's `S1RM2 / S1RII` (`LumixCameraService.ets:319`, `LumixCameraService.ets:336`).

The basis for the Image App table is that the source of Image App 1.9.0 (Lumix Link 2.0) has zero hits for `BluetoothAdapter/BluetoothGatt/BLE`, i.e. that generation has no Bluetooth and provisioning relies on a manual hotspot, a QR code (`MDL/SSID/PW/CRYPT/DeviceID`) or NFC, followed by SSDP + `cam.cgi` + DLNA (`LumixCameraService.ets:340`). GH5/GH5S/G9 were moved out of the Sync table onto this line on 2026-10-11 because all three have official Image App support records, none of them has Bluetooth, and the entry to the Sync line is BLE-gated (`LumixCameraService.ets:326`).

### 1.2 Route order and invariants

The decision order in `panasonicRouteForModel()` is: Lab token → first-generation S5 → `fromBle` fallback to Sync → `isWifiOnlyModel()` → Sync token → Image App fallback (`LumixCameraService.ets:1766`). On the UI side, `CameraSessionStore.panasonicLine()` concatenates the three identity segments and calls that function, and decides `fromBle` from the BLE state (`CameraSessionStore.ets:101`); the control page enters the Lab branch via `AppStorage['controlProtocol'] = 'lab'` (`CameraPage.ets:1667`). Two easy pitfalls are written down in the comments:

- Lab identity takes precedence over the "Wi-Fi only" test. Callers pass a concatenation of "model + BLE candidate model + BLE advertised name", which may still contain the model string from the previous pairing, and `isWifiOnlyModel()` returns true as soon as any token sees S5/ZS300; if Wi-Fi-only were tested first, S1RM2/S9 would be routed to Sync entirely (`LumixCameraService.ets:1759`).
- The three sets are subtracted level by level at their definitions, so "no future reordering or addition will let a body be claimed by two lines" (`LumixCameraService.ets:1755`).

**Differences from the task list (recorded as found)**: the Lab token in code is `L10`, not `G10`; the only `G10` literal in the whole repository is the camera profile for the Canon PowerShot G10 and is unrelated to LUMIX. The G10 in the task description has no corresponding implementation in this repository; covering it would first require confirming the real model string (`LumixCameraService.ets:302`, `LumixImportPrototype.ets:342`).

### 1.3 Boundaries with Sync / Image App

- Control plane: Lab uses only `/remote/*` and `/lut/*`; `cam.cgi` belongs to Sync and Image App. In this repository the getstate/getinfo probes in `probe()` are the cam.cgi family handshake, and response bodies containing `err_` are explicitly discarded so that error XML is not taken for a model name (`LumixCameraService.ets:2136`). Lab's first HTTP request is `/auth` (`LumixControlService.ets:957`).
- Live view: Lab is UDP + DTLS 1.2; Sync is plaintext, but both share the same Panasonic fragment layout. The code distinguishes them by a 9-byte magic and also accepts packets without magic whose structure is self-consistent, for compatibility with the Sync plaintext stream (`LumixControlService.ets:1171`).
- UI: `isCamCgiRoute(route)` merges `sync` and `lumix_image` into the "cam.cgi family"; Lab is not part of it (`LumixCameraService.ets:1862`); the Image App line provides no camera control page (`CameraPage.ets:1633`).

## 2. Bluetooth: implemented, but not inside the Lab control service

Conclusion: this repository **does implement** BLE pairing/registration for the Lab generation, in the shared `LumixImportPrototype.ets`, not in `LumixControlService.ets`. The control plane performs one best-effort registration when opening a session, and a failure does not block HTTPS (`LumixControlService.ets:1117`).

### 2.1 Scanning and advertisement parsing

Scanning sets no `ScanFilter`; the `BLEDeviceFind` callback parses the AD structures itself, and the first connectable Panasonic candidate causes an early exit, at most 10 s (`LumixImportPrototype.ets:2005`). Advertisement identity is taken from protocol fields rather than from the changeable local name:

| Field | Value / rule | Source |
|---|---|---|
| Scan service UUID | `054ac620-3214-11e6-ac0d-0002a5d5c51b` (the official app filters on it; this repository records it as a diagnostic item) | `LumixImportPrototype.ets:312` |
| Manufacturer ID | 58, manufacturer data exactly 6 bytes | `LumixImportPrototype.ets:335` |
| Bluetooth address | bytes 2..5 of the manufacturer data (big-endian hex string) | `LumixImportPrototype.ets:337`, `:2262` |
| Model code | last two bytes of the local name are `0x0A` + code value 1..9 | `LumixImportPrototype.ets:339`, `:2248` |

Model code table (index 0 empty): 1=`S9`, 2=`GH7`, 3=`S5M2`, 4=`S5M2X`, 5=`G9M2`, 6=`S1M2E`, 7=`S1M2`, 8=`S1RM2`, 9=`L10` (`LumixImportPrototype.ets:342`). When parsing, the last two bytes are stripped from the display name to obtain a presentable name; if the code value is out of range, matching falls back to the name (`LumixImportPrototype.ets:2252`). This explains what `LumixCameraService.ets:293` calls "a compact model code in the advertisement".

### 2.2 GATT services and characteristics

Primary service `1fe71b85-8344-4e6a-bf1a-ac7acdb3f8af` (`LumixImportPrototype.ets:344`). The control line requires only the presence of `INITIAL_INFORM / APP_UUID / ACTION_MODE` (`LumixImportPrototype.ets:868`); the image transfer line additionally requires `WIFI_SSID / WIFI_PASSWORD` (`LumixImportPrototype.ets:1423`).

| Name | UUID | Direction / purpose |
|---|---|---|
| `INITIAL_INFORM` | `239c7203-922f-43e9-bdf1-6d1fedf6f43f` | read, the 4-byte seed for the registration encoding |
| `APP_UUID` | `bff12e7f-5944-4eb6-a90f-48d8786157ea` | write, client 16-byte UUID (encoded) |
| `APP_INFO` | `ed8b1352-5aa7-4155-b7c9-521292dd1932` | write, UTF-8 plaintext padded with NUL to 32 B |
| `FRIENDLY_NAME` | `05a797b6-9c2f-4d18-99a7-fa61a3880bfe` | write, device name (encoded) |
| `PAIRING_INIT` | `36f99090-e79b-4060-9ac7-89f3f8bf88d5` | write, `0x02` commits application-level registration |
| `ACTION_MODE` | `7644371c-1ddc-4b16-832f-f07c322e311b` | write, `0x01`, may be written repeatedly |
| `AP_STATE` | `dcba3a74-80bc-4919-8ef4-0c9f99cc20dd` | notify, `0x03` = AP ready |
| `ACTION_MODE_RESULT` | `6c875728-7636-425e-818a-f1d93a39e075` | notify, `0x00` = action complete |
| `WIFI_SSID` / `WIFI_PASSWORD` | `657edba2-5bc8-42dd-974f-21871d7dbcd1` / `42d509f7-f122-4816-92d1-5e402d9453cb` | read, provisioning credentials |
| `CERT_FINGERPRINT` / `SERVER_URL` / `SD_SLOT_INFO` | `1be8a9e3-178b-46c4-b6b3-43d4a5311fc1` / `5c565e17-8fba-4aec-b863-32b9b318bfbd` / `d6bbd828-eb91-4b00-acfc-b2c5821ff0f7` | read: certificate fingerprint, service URL, slot list |
| `CAMERA_OPERATE_NOTIFICATION` | `16726c35-52ef-4d00-868d-099549a90d9b` | notify, firmware write progress |

(All of the above in `LumixImportPrototype.ets:344`–`:378`; the index is at `LumixImportPrototype.ets:2463`.)

### 2.3 Registration sequence

Registration of the LUT/control identity goes through `registerLutIdentityOnce()` (`LumixImportPrototype.ets:838`):

1. If a GATT link retained by the image transfer line exists, release it first, to avoid submitting again on an already-registered link (`LumixImportPrototype.ets:848`; note that the wrapper already returns early while a retained link exists, see §2.5).
2. Scan for `deviceId`; read the system bond state, but **do not call** `pairDevice()` (`LumixImportPrototype.ets:857`, `:2393`).
3. `connectGatt()`, retried once on failure (`LumixImportPrototype.ets:865`, `:2411`).
4. `getServices()`, index the characteristics; a missing `INITIAL_INFORM/APP_UUID/ACTION_MODE` fails immediately (`LumixImportPrototype.ets:866`).
5. Enable the `ACTION_MODE_RESULT` and `AP_STATE` notifications and read `INITIAL_INFORM` (`LumixImportPrototype.ets:893`, `:895`).
6. Write `APP_UUID`: 16-byte UUID → protocol string encoding → XOR with the seed (`LumixImportPrototype.ets:896`).
7. Write `APP_INFO` (plaintext UTF-8, truncated/zero-padded to 32 B) and then `FRIENDLY_NAME` (UTF-8 → protocol string encoding → XOR) (`LumixImportPrototype.ets:901`, `:904`).
8. Write `PAIRING_INIT = 0x02`; the camera rejects this if it is already registered, tolerated as "already registered" (`LumixImportPrototype.ets:911`).
9. Write `ACTION_MODE = 0x01`, then wait at most 15 s; either notification `AP_STATE=0x03` or `ACTION_MODE_RESULT=0x00` means the AP is considered ready (`LumixImportPrototype.ets:923`).

Encoding details: `encodeProtocolString` is "1-byte length + data + 0 padding to a 4-byte block + `0xff` padding for the last block" (`LumixImportPrototype.ets:4246`); `xorReverseWithInitial` reverses each 4-byte block and XORs it with `INITIAL_INFORM[0..3]` (`LumixImportPrototype.ets:4262`). `APP_INFO` is the only registration write that bypasses the encoding and is directly fixed at 32 bytes (`:901`, `:4276`).

### 2.4 System pairing and failure semantics

`ensurePaired()` only reads `connection.getPairState()`: if already bonded it returns true, otherwise it records "OS PIN pairing skipped" and continues with GATT (`LumixImportPrototype.ets:2393`). The comment explains that the generic `pairDevice()` pops up a PIN dialog the camera does not accept, so application-level GATT registration is this line's "pairing".

Registration failure code `2900099` appears on hardware in the scenario "writing `36f99090` or `ACTION_MODE` repeatedly on an already-registered link" (`LumixImportPrototype.ets:842`, `:914`). Registration on the control line is best-effort: `registerIdentityOverBle()` catches all exceptions and only logs (`LumixControlService.ets:1125`); on success it waits for the camera network to come back, at most 30 s, because committing the registration may restart the camera AP (`LumixControlService.ets:1112`, `:1131`).

### 2.5 BLE boundaries of the control line (important)

- The control line uses its own UUID: the `clientUuid` of the `preferences` store `vivid_camera_control`, whose value is 32 hex digits without hyphens; if generation fails it falls back to the constant `vividctrl00000000000000000000000` (`LumixControlService.ets:1078`).
- At registration this UUID is passed to `registerLutIdentity()` together with the official `AppInfo='LUMIX LUT Creators APP 3.0.1'` and `FriendlyName='Pixelshop HarmonyOS'` (`LumixControlService.ets:613`, `:1120`).
- However, `registerLutIdentity()` **returns false directly and registers nothing** when it detects a link retained by the image transfer line (`LumixImportPrototype.ets:823`). The link is retained after a successful image transfer handshake (`LumixImportPrototype.ets:1808`), so the common path in practice is "skip control UUID registration and go straight to `/auth`". This is in tension with the comment that "the camera gates remote endpoints by registration record", and is listed as a risk in §8.
- The control line **does not read** `WIFI_SSID/WIFI_PASSWORD`; Wi-Fi association is performed by the BLE flow of the image transfer line (read both characteristics, decode the password with `INITIAL_INFORM`, `LumixImportPrototype.ets:1514`, `:2576`). `LumixControlService.networkBase()` reads only the currently associated SSID and the DHCP gateway (`LumixControlService.ets:941`).

## 3. Wi-Fi transport

### 3.1 AP shape

- The SSID must pass `identifyWifiSsid()`: `matchesPanasonicName()` requires `^TOKEN[-_][A-Z0-9]{3,}…$`, optionally preceded by a `LUMIX/PANASONIC/PANA/DC/DMC/CAMERA` prefix (`LumixCameraService.ets:523`, `:2088`). Note that the comment records a visible AP SSID `S1A0EAA4BD` without a separator (`LumixImportPrototype.ets:2816`), which the current regex cannot match; if the hardware really presents this shape, control stops at the `ssid` stage (inferred, to be verified).
- The host address is not hard-coded: it takes the DHCP gateway of the current Wi-Fi and assembles it into a dotted IPv4 in network order (`LumixCameraService.ets:1959`). The comment records that the camera AP is an isolated subnet `192.168.54.1/24` with no uplink (`CameraPage.ets:1800`), so a firmware download must first disconnect from the camera Wi-Fi (`CameraPage.ets:1828`). The password comes from the BLE characteristics, `securityType` from the scan result, and open networks get an empty key (`LumixImportPrototype.ets:1515`, `:2951`).

### 3.2 HTTPS and self-signed certificates

All requests are fixed to `https://${host}${path}` with no port written, i.e. 443 by default (`LumixControlService.ets:1046`). The control line treats the camera as a self-signed device on a dedicated point-to-point network; `remoteValidation` always returns true and **no certificate chain validation and no fingerprint pinning are performed** (`LumixControlService.ets:1044`). By contrast, the image transfer line normalizes the `CERT_FINGERPRINT` read over BLE and uses it for `validateCertificate()` (`LumixImportPrototype.ets:1518`, `:3097`). This is a substantive difference in TLS trust model between the two lines.

### 3.3 Session and identity

| Item | Value | Source |
|---|---|---|
| `AppInfo` | `LUMIX LUT Creators APP 3.0.1` | `LumixControlService.ets:613` |
| `FriendlyName` | `Pixelshop HarmonyOS` | `LumixControlService.ets:616` |
| Client UUID | persisted per installation, 32-digit hex, independent of the image transfer / LUT lines | `LumixControlService.ets:1078` |
| Token / header | `Data.AuthToken` from `/auth`; sent as the literal `'Bearer <token>'` (**including the single quotes**, empirically established from the official instrumentation) | `LumixControlService.ets:957`, `:1020` |
| Session reopen | on 401, re-`/auth` with the same UUID, skipping BLE registration | `LumixControlService.ets:653` |

### 3.4 Request and response envelope

Uniformly `POST` + JSON, with the response `{Data:{…},Header:{ResponseCode,Messages}}`:

| Endpoint | Request body | Response data | Source |
|---|---|---|---|
| `/auth` | `{AppInfo,FriendlyName,Uuid}` | `Data.AuthToken` | `LumixControlService.ets:556` |
| `/remote/camcmd` | `{Command}` | `Data.Result` | `LumixControlService.ets:591` |
| `/remote/set-setting` | `{Type,Value,Value2?}` | `Data.Result` | `LumixControlService.ets:562` |
| `/remote/get-setting` | `{Type}` | `Data.DataList` or `Data[Type]` | `LumixControlService.ets:744` |
| `/remote/get-state` | `{}` | the 33 fields of `Data` (per comment) | `LumixControlService.ets:698` |
| `/remote/camctrl` | `{Type:"touch",Value:"x/y",Value2:"on" or "off"}` | `Data.Result` | `LumixControlService.ets:834` |
| `/remote/start-stream` | `{UDPPortNumber}` | `Data.Result` | `LumixControlService.ets:843` |
| `/remote/get-lvport` | `{}` | `Data.LvPort` or bare `{LvPort}` | `LumixControlService.ets:866` |
| `/remote/stop-stream` | `'{}'` (see §8) | none (403 when idle) | `LumixControlService.ets:856` |
| `/lut/info` | `{}` | `Data.DataList` (41 slots) | `LumixControlService.ets:895` |
| `/lut/set-display-setting` | `{LutId,Visibility}` | `Data.Result` | `LumixControlService.ets:928` |

Tolerance rules in `parseData()`: `Header.ResponseCode` is treated as a rejection only if it is present and not 200 (a successful `/lut/info` omits the Header entirely); a bare `{LvPort:N}` is also accepted; `Result` raises an error only if present and non-zero (`LumixControlService.ets:978`, `:1005`).

### 3.5 HTTP details

- An empty request body must be passed as `''` so that the stack emits `Content-Length: 0`; an empty `ArrayBuffer` makes the camera return 411, and in this runtime `TextEncoder.encode('')` returns undefined (`LumixControlService.ets:1024`). `connectTimeout/readTimeout` are both 15 s (`:1039`).
- The stream-related calls (start-stream/get-lvport/get-state/stop-stream) share one keep-alive `HttpRequest`; the official app also uses a single TCP connection. If start-stream's TCP connection is closed, the camera may tear down the live view stream along with it (`LumixControlService.ets:51`, `:677`). Ordinary calls create a new one each time and destroy it in `finally` (`:1071`).

## 4. Live view: UDP + DTLS 1.2

### 4.1 Startup order

The actual order in the control page (`CameraControlPage.ets:478`):

| Step | Action | Key point |
|---|---|---|
| 1 | `openSession` | BLE registration (best-effort) → `/auth`; one retry 800 ms after failure |
| 2 | `openControlClient` | a single keep-alive connection |
| 3 | `stopStream` | clears any residual stream; 403 `err_critical` is ignored |
| 4 | `camcmd recmode` | 3 retries, 1 s apart (a mode switch takes about 0.9 s) |
| 5 | `primePipeline` | 19 `get-setting` calls; without this step `get-lvport` returns 403 `err_busy` permanently |
| 6 | UDP `bind(1235)` | on conflict the port is +2, at most 8 attempts; bound to the Wi-Fi network |
| 7 | `start-stream` | reports the local UDP port |
| 8 | `get-lvport` | camera-side source port; 403 retried every 100 ms, 25 times in total |
| 9 | `primePostLvport` | 8 capability keys (including duplicates), matching the official golden session |
| 10 | `startDtls(host, lvPort)` | 12 s handshake timeout |
| 11 | `resume()` | 8 s no-frame watchdog; then 1 Hz `get-state` |

Local port 1235 comes from the official h2 instrumentation; the earlier 1234 produced a permanent `err_busy` on hardware (`CameraControlPage.ets:505`, `LumixControlService.ets:1222`). The UDP socket must `bindSocket()` to the Wi-Fi bearer; otherwise, when a SIM is present, traffic goes over cellular and the camera stream never reaches the socket (`LumixControlService.ets:1269`). After binding there is also a 127.0.0.1 loopback self-check, used to distinguish "the receive path is broken" from "the camera is not sending" (`LumixControlService.ets:1319`). `probe()` is still kept, but on the DTLS line the camera sends nothing before the handshake completes, so plaintext probing is ineffective (`LumixControlService.ets:1361`).

### 4.2 DTLS 1.2 parameters

`DtlsClient.ets` is a minimal client replicated from the UDP traffic of the official APK (`DtlsClient.ets:6`):

| Item | Value | Source |
|---|---|---|
| Version / suite | DTLS 1.2, `TLS_RSA_WITH_AES_128_GCM_SHA256` (`0x009c`) | `DtlsClient.ets:43` |
| Server certificate | self-signed; DER-parsed only to obtain the SPKI, **no chain or hostname validation** | `DtlsClient.ets:10`, `:668` |
| Client certificate | empty certificate (3-byte `000000` body), identical to the official app | `DtlsClient.ets:233` |
| Cookie | after HelloVerifyRequest, ClientHello is resent (msg_seq=1); the CH record version is `fe ff`, thereafter `fe fd` | `DtlsClient.ets:139`, `:183` |
| Key block | 40 B: client_key 16 + server_key 16 + client_iv 4 + server_iv 4 | `DtlsClient.ets:249` |
| Record header | 13 B: type(1) ver(2) epoch(2) seq(6) len(2) | `DtlsClient.ets:12` |
| AEAD | explicit nonce 8 B + ciphertext + tag 16 B; AAD 13 B | `DtlsClient.ets:14` |
| RSA | `RSA2048` first, falling back to `RSA1024`, PKCS#1 v1.5 | `DtlsClient.ets:724` |
| Timeout | total handshake 12 s; packet wait 1.5 s/4 s/5 s, ClientHello resent at most 6 times | `DtlsClient.ets:134` |
| Replay | accepts only epoch-1 application data with `seq > lastServerSeq` | `DtlsClient.ets:350` |

The cipher/extension tail of ClientHello is copied byte for byte from the official capture, with only random and cookie changed (`DtlsClient.ets:57`); only then does the camera answer this exact byte sequence.

### 4.3 Record = one Panasonic fragment

The decrypted application data **is** the fragment itself; there is no RTP layer; the fragment total length in `header[0..1]` equals the record length, and the magic is at offset 9 (`LumixControlService.ets:34`, `:1565`). The 32-byte header is interpreted big-endian:

| Offset | Length | Meaning | Read at |
|---|---|---|---|
| 0..1 | 2 | fragment total length (used to trim trailing padding) | `LumixControlService.ets:1588` |
| 4..7 | 4 | fragment sequence number `seq` (`0xffffffff` is a reset marker) | `LumixControlService.ets:1597` |
| 8 | 1 | flags; bit0=1 means more fragments follow, 0 means the last fragment | `LumixControlService.ets:1598`, `:1645` |
| 9..17 | 9 | magic `fc 84 a7 d0 ba 76 00 21 ff` | `LumixControlService.ets:1176` |
| 22..25 | 4 | total length of the whole JPEG frame | `LumixControlService.ets:1635` |
| 26..29 | 4 | offset of this fragment's data within the JPEG | `LumixControlService.ets:1672` |
| 30..31 | 2 | metadata length | `LumixControlService.ets:1599` |

The remaining bytes are not read by the code and are not inferred. JPEG data starts at `32 + metaLen` (`LumixControlService.ets:1600`).

### 4.4 Reassembly rules

- `seq == 0xffffffff`: a self-contained complete frame; discard the partial assembly first, then emit the frame directly (`LumixControlService.ets:1627`).
- `seq == 0`: frame header. Read the total length (`0` or more than 8 MiB is treated as corruption), allocate the buffer, `expectedSeq=1`; every fragment carries the full prefix (32 B header + metadata), and the last fragment is taken as the prefix of the whole frame (`LumixControlService.ets:1633`, `:1682`).
- Each subsequent fragment must be `expectedSeq`; a break drops the whole frame (`LumixControlService.ets:1654`); when the magic does not match, structural checks take over (the frame header is immediately followed by the JPEG SOI, continuation fragments carry the expected sequence number, `LumixControlService.ets:1617`). The frame is emitted only when all fragments are collected and `jpegFilled == total length`, and then the JPEG header and tail are validated; dimensions are obtained by scanning the SOF, defaulting to 640×432 (`LumixControlService.ets:1697`, `:1710`, `:1850`).

### 4.5 Q0 metadata

`parseMeta()` parses from offset 32 in cursor style; every read is bounds-checked, and on truncation it returns the fields decoded so far (`LumixControlService.ets:1740`):

| Field | Offset / condition | Decoding |
|---|---|---|
| `zoomPos` | fixed header +4 | u8 |
| AF frame count | fixed header +15 | 16 B per frame, the whole block is skipped |
| `avCur256` / `tvCur256` | Av/Tv/Sv block +8 / +20 | u16 / **i16**, APEX×256 |
| `focusDistance` | exposure byte +1 | u16 |
| Icons | `nic` byte + icon area | the whole block is skipped |
| `nsv` | after the fixed 28 B | u8, entry to the settings block |
| `exposure` | settings block +0 | u16 (when `0xffff`, the header exposure byte is used) |
| `iso` | +4 | **u32** (`0xffffffff`=AUTO) |
| `whitebalance` | +10 | u16 |
| `recmode2` | +14 | u16 |
| `photostyle` | +18, `nsv>=20` | u16 |
| `quality` | +22 | u16 |
| `aspect` | +28 | u16 |
| `metering` | +34 | u16 |
| `liveviewsize` | +36 | u8 |
| `operate` | +38 | u8, `1`=phone priority |
| `pictureFormat` | +54, `nsv>=56` | u16 |

The settings block is actually 75 B, while `numSettingValue` only counts up to 73 (`0x49`); `focusStacking/cropZoom` lie outside that count; `iso` is a 4-byte word (`LumixControlService.ets:40`, `:1797`). Every field of `LumixLiveviewInfo` must be `@Track`, otherwise UI access throws `Illegal usage of not @Track'ed property`, which historically manifested as the control page hanging or a crash when a parameter was tapped (`LumixControlService.ets:102`).

## 5. Control

### 5.1 `camcmd`

The service comment declares support for `recmode/playmode/capture/capture_cancel/touchafrelease/video_recstart/video_recstop` (`LumixControlService.ets:808`). Actual Lab call sites:

| Command | Call site | Note |
|---|---|---|
| `recmode` | `CameraControlPage.ets:490` | `retries=3`, retried only on HTTP-class errors, 1 s apart |
| `capture` | `CameraControlPage.ets:2425` | `capture_cancel` is sent 280 ms after success |
| `capture_cancel` | `CameraControlPage.ets:2430` | releases the shutter state |
| `video_recstart` | `CameraControlPage.ets:2468` | recording start |
| `video_recstop` | `CameraControlPage.ets:2460` | recording stop |
| `playmode` / `touchafrelease` | no Lab call site | `playmode` is used by the Sync line; touch focus goes through `camctrl` |

### 5.2 `set-setting`

| `Type` | Value range / get value | Call site |
|---|---|---|
| `exposure` | `0x0000` is center, bit15 is negative, unit 1/3 EV | `CameraControlPage.ets:2594` |
| `iso` | `0xffffffff`=AUTO, otherwise the ISO value | `CameraControlPage.ets:2591` |
| `shtrspeed` | `N/256` or 32-bit millisecond encoding (B bulb/AUTO have sentinel values) | `CameraControlPage.ets:2597` |
| `whitebalance` | 16-bit encoding (e.g. `0x0002` auto, `0x8014` auto cool) | `CameraControlPage.ets:2588` |
| `recmode2` | exposure mode (P/A/S/M/C1…) | `CameraControlPage.ets:2585` |
| `aspectratio` | `0x0001..0x000b` | `CameraControlPage.ets:2582` |
| `quality` / `pictureformat` | S5M2 uses `quality`; the key is switched once the `pictureformat` value range has been probed | `CameraControlPage.ets:2579`, `:1088` |
| `liveviewsize` | `0x00/0x01/0x02` smooth/standard/fine | `CameraControlPage.ets:2574` |
| `lightmetering` | metering mode | `CameraControlPage.ets:2571` |
| `photostyle` | PhotoStyle value (including LUT styles) | `CameraControlPage.ets:2567` |
| `operatepriority` | `0x00` body / `0x01` phone; currently no UI call site | `CameraControlPage.ets:2385` |

`applySetting()` logs the request body first, because S1RM2 replies `200/Result=0` for unknown keys without applying them, while hilog truncates the response body (`LumixControlService.ets:798`).

### 5.3 `get-state`

The comment says the heartbeat has 33 fields (`LumixControlService.ets:26`, `:83`), but `ControlData` declares only 16 status fields (`:517`–`:532`), and `fetchState()` maps 7 of them: `cammode`, `sd_access`, `sd2_access`, `sd_full`, `sd2_full`, `current_sd`, `camera_operating` (`:698`). The UI actually consumes only `sd_access/sd2_access`: if during recording both cards show no activity for more than 4 s, the body is judged to have stopped recording (`CameraControlPage.ets:1029`). The other status displays come from Q0 metadata, not from `get-state`.

### 5.4 `camctrl` touch focus

The request body is `{"Type":"touch","Value":"x/y"}` plus `Value2` as `"on"` or `"off"`; the coordinates are live view image pixel coordinates (`LumixControlService.ets:834`). The UI sends four frames at the official cadence: down→60 ms→up→60 ms→down→60 ms→up, with failures silent (`CameraControlPage.ets:2347`).

## 6. LUT channel

- `/lut/info`: `{}` → `Data.DataList`, the comment records 41 slots (`LumixControlService.ets:31`). Each record takes `LutId/LutName/LutType/PhotoStyle`; `LutType` is treated as 3 when absent, an empty name is marked `empty`, and the list is finally sorted ascending by `LutId` (`LumixControlService.ets:895`). `LutType` semantics: 1=VLog_709 built-in, 2=ARRI 709 built-in, 3=user slot (`LumixLutService.ets:31`).
- `/lut/set-display-setting`: `{LutId,Visibility}`, with `Visibility` 1/0 (`LumixControlService.ets:928`).
- S1RM2 exception: this body has no `/lut/set-display-setting`; built-in style LUTs (`LutType=1`) go through `set-setting photostyle` instead, measured as `VIVID=0x0001` (`LumixControlService.ets:377`).
- The control line's LUT calls reuse the control session token; the standalone `LumixLutService` has its own `/auth` and its own UUID store `vivid_lut_transfer` (`LumixLutService.ets:122`, `:610`), and the two identities must not be mixed.

Only the boundaries of the firmware channel are noted here: it likewise goes over camera HTTPS (`/firmware/send-prepare`, `/firmware/send`, `/firmware/abort-send`), progress comes from the BLE notify `16726c35` (value 1=writing, 2=done), and the firmware directory comes from `panasonic.jp` and requires Basic credentials (`LumixFirmwareService.ets:1`, `:36`). The camera AP has no uplink, so the camera Wi-Fi must be disconnected before downloading (`CameraPage.ets:1800`).

## 7. Implementation cross-reference

| File | Responsibility | Key constants / entry points |
|---|---|---|
| `LumixControlService.ets` | Lab control plane, HTTP envelope, LUT slots, UDP/DTLS live view reception and Q0 parsing | `CONTROL_APP_INFO`, `FRAG_MAGIC`, `STALL_AFTER_MS=8000`, `MAX_JPEG_BYTES=8 MiB` |
| `DtlsClient.ets` | DTLS 1.2 client: cookie, RSA key exchange, AES-128-GCM, Finished verification | `CIPHER_RSA_AES128_GCM=0x009c`, 12 s handshake budget |
| `LumixCameraService.ets` | three-line model partitioning, SSID/gateway reads, cam.cgi probing, BLE capability predicates | `PANASONIC_*_MODEL_TOKENS`, `isCamCgiRoute(route)`, `needsBlePairing(route)` |
| `LumixImportPrototype.ets` | shared BLE scanning/registration/provisioning, image transfer session, firmware characteristic reads | `BLE_SCAN_SERVICE`, `BLE_SERVICE`, `UUID_*`, model code table |
| `LumixLutService.ets` | standalone LUT transfer line (`/auth`, `/lut/send*`, delete/rename/file) | `LUT_APP_INFO`, `vivid_lut_transfer` |
| `LumixFirmwareService.ets` | firmware directory/download/chunked upload | `SHARE_BASE`, `/firmware/send-prepare`, `WRITE_DONE_TIMEOUT_MS` |
| `CameraControlPage.ets` | Lab control page state machine: session, capability table, live view, capture, touch | port 1235, 1 Hz heartbeat, AUTO reconnect |
| `CameraSessionStore.ets` | three-line decision and UI selection state | `panasonicLine()`, `isCamCgiLineSelected()` |

## 8. Limitations and risks

1. **The control line does not validate certificates**: `remoteValidation` is always true (`LumixControlService.ets:1044`), while the image transfer line pins the fingerprint (`LumixImportPrototype.ets:3097`). The trust strength of the two lines on the same camera is inconsistent, so a man-in-the-middle can be accepted on the control line.
2. **UUID registration may be skipped**: while a retained link exists, `registerLutIdentity()` returns false directly (`LumixImportPrototype.ets:823`), whereas `/remote/*` uses the control line's own UUID (`LumixControlService.ets:958`). If the camera gates strictly by registration record, the combined failure "image transfer works, control returns 401/403" will occur. This is inferred and needs to be confirmed against logs on hardware.
3. **403 has two meanings**: `stop-stream` returns 403 `err_critical` when there is no stream, and the code ignores it (`LumixControlService.ets:854`); `get-lvport` briefly returns 403 `err_busy` after start-stream, and the code retries every 100 ms, 25 times (`:866`). Both reach `LumixControlError.code` as an HTTP status code, so callers must distinguish by endpoint and must not look at 403 alone.
4. **The `stop-stream` comment contradicts the code**: the comment says the official request body is empty (not `"{}"`), while the code actually sends `'{}'` (`LumixControlService.ets:859`). This currently relies on the camera being lenient; if some firmware distinguishes strictly, it must be changed to match the capture.
5. **`Result=0` does not mean the setting took effect**: S1RM2 replies 200/Result=0 to unknown `set-setting` keys without changing the setting (`LumixControlService.ets:798`); `quality` returns all 200 on S1RM2 with no effect, so `pictureformat` must be used instead (`CameraControlPage.ets:1080`). Panel values should be taken from the Q0 readback.
6. **`get-state` modelling is incomplete**: the comment says 33 fields, the code declares only 16 and maps 7 (`LumixControlService.ets:517`, `:698`). Features that depend on unmodelled fields do not exist.
7. **DTLS has no retransmission and no buffering**: application data accepts only strictly increasing epoch-1 sequence numbers (`DtlsClient.ets:350`), so out-of-order or late records are discarded permanently; at the fragment layer a single sequence break drops the whole frame (`LumixControlService.ets:1654`). On weak Wi-Fi this shows up as artefacts/stalls rather than recovery by retransmission.
8. **Only the RSA suite is implemented**: if the server selects an ECDSA suite, the client reports "unknown suite" directly (`DtlsClient.ets:226`). All current hardware selects `0x009c`, but this is a potential break point with firmware differences.
9. **Ports and network binding**: on a conflict, UDP port 1235 becomes +2 (`LumixControlService.ets:1227`); if the system occupies the whole range, binding fails. Without binding to the Wi-Fi bearer the camera stream never reaches the socket (`:1269`), which is the common cause of "pkts=0" in the field.
10. **The model table differs from the task list**: the Lab table has `L10`, not `G10` (`LumixCameraService.ets:302`). `identifyWifiSsid()` has no G10 entry either (`:2095`), so even if the body existed it would currently fall through to the Image App fallback.
11. **Exclusive use of BLE by firmware/provisioning**: committing a registration may restart the camera AP, and the control line waits up to 30 s (`LumixControlService.ets:1112`); firmware writing depends on the same BLE notification path (`LumixFirmwareService.ets:14`), so it risks interrupting and being interrupted when concurrent with a control session.

## 9. To be confirmed on hardware (all marked as inferred)

- Whether `/remote/*` is still usable when the control UUID is not registered; compare the `/auth` and `camcmd` responses of "image transfer first, then control" against "control only" on the same body.
- The complete key names and types of the 33-field `get-state`; currently they can only be back-derived from the 16 declared fields.
- Which bodies return a bare `{LvPort}` from `get-lvport`; the code accepts both shapes (`LumixControlService.ets:976`).
- The semantics of fragment header offsets 2..3 and 18..21; the code does not read them and they cannot be inferred from the existing implementation.
- How readily different firmware accepts an empty `stop-stream` body versus `'{}'`.
