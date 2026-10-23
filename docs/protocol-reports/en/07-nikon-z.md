# Nikon Z Series: SnapBridge BLE, LSS Authentication, and PTP/IP Transport

**English** | [简体中文](../07-nikon-z.md)

> Translated from the Chinese original at baseline `18466be`. Identifiers — UUIDs, opcodes, property codes, ports, `file:line` references — are kept verbatim. Chinese user-facing message literals are rendered in English with the original string retained alongside.

- Project: VIVID (ArkTS), baseline commit `18466be`
- Scope: the Z-series line alone. BLE only does "hand the Wi-Fi credentials to the phone"; all imaging and control go over ISO 15740 PTP/IP (TCP 15740)
- Basis: read-only code and repository documents. Every inference is marked "inferred" together with its basis; keys, UUIDs and opcodes are copied verbatim from the code/comments, and no value was invented

## 0. Basis and One Documentation Gap

The repository-root file `报告_尼康LSS认证与WiFi凭据解密.md` ("Report: Nikon LSS Authentication and Wi-Fi Credential Decryption") is an **empty file (0 lines)** in the workspace and is not published with the public repository, so this report cannot cite its factual entries and has to go by the code alone. The code itself contains several "comment/implementation conflicts"; section 9 lists them one by one and states which side is the current actual behaviour.

Evidence strength is graded in four levels, and this report picks by level when citing:

| Level | Meaning | Example |
|---|---|---|
| A on hardware | field logs with timestamps and error codes in code comments | on the Z 8, `0x2004` read back `2900007/2900011` (`NikonBleProvisioning.ets:1132-1137`) |
| B shipped artifacts | conclusions from decompiling the official APK's DEX/smali or `libLsSec-jni.so` | the 17-byte frame codec class `bleclient/b;` (`NikonLssProtocol.ets:15-26`) |
| C code comments/constants | comments and constants the author wrote based on A/B | the opcode and property-code tables |
| D inferred | extrapolated by this report from the facts at hand, marked case by case | the advertised pairing state is not parsed |

Main source files:

| File | Role |
|---|---|
| `NikonBleProvisioning.ets` (3265 lines) | GATT transport, advertisement identification, pairing, 0x2000 authentication, 0x2004 credential read, network join |
| `NikonCameraService.ets` | SnapBridge service/characteristic UUIDs, Z model-name parsing |
| `NikonLssProtocol.ets` | byte layout of the authentication frame and the connection configuration block, security enum |
| `NikonLssSession.ets` | 1→2→3→4 state machine, MAC, session-key derivation, CBC decryption |
| `NikonLssCrypto.ets` / `NikonLssHashTable.ets` | Blowfish and the preset schedule table |
| `NikonPtpIpService.ets` (2947 lines) | PTP/IP handshake, transaction queue, live view, shutter, properties, image transfer |
| `CameraControlBrand.ets` / `NikonCameraParameters.ets` / `CameraControlPage.ets` | parameter-panel adaptation and actual wiring for the control page |

## 1. Where This Line Sits: Why It Shares PTP/IP with Sony

`CameraControlBrand.ets:14-21` states the placement very directly: the Sony line "shares the ISO 15740 PTP/IP transport", while the Nikon line "runs the very same ISO 15740 PTP/IP transport (the same NikonPtpIpService singleton), so the control plane is isomorphic to the Sony line: live view + shutter". `isPtpIpProtocol` at `CameraControlBrand.ets:122-125` returns true only for the `sony` / `nikon` protocol values, and the page renders the same set of PTP/IP buttons for both.

This matches the division of labour in `NikonBleProvisioning.ets:4-24`: the BLE segment only does "pair → LSS authentication → read back the Wi-Fi credentials the camera provides → join that network", and then "hands over to the existing PTP/IP transport and control code". There is no "send photos over BLE" path anywhere in the code, and `NikonPtpIpService` does not reference BLE.

Additional fact: USB is a third conduit, not a fourth protocol line. `NikonUsbPtp.ets:10-25` states plainly that "USB and PTP/IP are just two 'conduits'; the opcodes, data wrapping and property encoding running on top are completely identical", and it is attached through `NikonPtpIpService.attachTransport()` (`NikonPtpIpService.ets:997-1007`).

## 2. BLE Advertising and Identification

### 2.1 Services and Characteristics

`NikonCameraService.ets:44` gives the SnapBridge (LSS) service UUID:

```
0000DE00-3DD4-4255-8D62-6DC7B9BD5561
```

The private base suffix is `3DD4-4255-8D62-6DC7B9BD5561`; the standard SIG suffix is used only for the Device Information service, battery level and CCCD (`NikonCameraService.ets:31-43`). The key characteristics used by this line (same file, `:47-69`):

| Characteristic | Purpose |
|---|---|
| `0x2000` | LSS authentication, 17-byte frame written and notification read back |
| `0x2001` | POWER_CONTROL (0=STOP, 1=WAKE_WAIT, 2=INVALID_WAKE, 3=VALID_WAKE, see `NikonBleProvisioning.ets:1863-1875`) |
| `0x2002` | CLIENT_DEVICE_NAME, fixed 32 bytes, zero-padded |
| `0x2003` | SERVER_DEVICE_NAME, the camera's self-reported name |
| `0x2004` | Connection configuration (Wi-Fi credentials) |
| `0x2005` | CONNECTION_ESTABLISHMENT |
| `0x2006` / `0x2007` | time / location |
| `0x2008`–`0x200B` | control point / feature / cable status / serial number |
| `0x2020` / `0x2021` | status and commands for control |
| `0x2080` / `0x2081` | category information / capture status |

### 2.2 Advertisement Admission

`NikonBleProvisioning.ets:362-444` parses the AD structures itself: the 16-byte UUID inside `0x06/0x07` is reversed from little-endian into big-endian byte order and compared against the SnapBridge service (`:387-397`, `:421-430`), `0x08/0x09` yields the local name (`:399-415`), and the `0xFF` manufacturer ID is only converted into a hex string **for diagnostics** (`:431-437`).

`findCamera` admits on any one of three conditions (`:480-481`): the advertisement carries the SnapBridge service, the name resolves through the model table, or the name matches Nikon body naming habits (the regex at `:593-603`, anchored on `Z_`, `Z5`, `D850` and the like, to avoid picking up things such as ZTE).

The model table is at `NikonCameraService.ets:84-99`, 14 entries in total (Z 50II, Z 6III, Z 5II, Z 7II, Z 6II, Z 6, Z 7, Z 50, Z 30, Z 5, Z 8, Z 9, Z fc, Z f). The name-parsing rules are at `:102-168`: the generation digit in `Z_6_2_xxxxxxx` means Z 6II, and the serial number is at least 4 digits.

**Pairing state in the advertisement: the code does not parse it.** Only RSSI, service-hit status, the manufacturer hex and the whole raw advertisement are recorded into the trace (`NikonBleProvisioning.ets:492-505`); there is no bit-field decoding of the manufacturer data and no read logic for a "paired/unpaired" field. This report therefore gives no bit definitions for pairing state. The scan window is 10 s (`:78`, `:539`); unconnectable results are kept as a fallback (`:506-511`); a rejected scan start is not counted as a failure (`:528-537`).

### 2.3 The Actual Action Sequence of the Pairing Segment

The order `provision` follows after the GATT link is up (`NikonBleProvisioning.ets:1123-1394`), consistent with the on-hardware finding that authentication comes first and identity is written afterwards:

1. Request MTU 512 (`:1143`), enumerate services and print every characteristic's permissions (`:1148-1163`).
2. On `0x2000`, choose notification or indication according to the camera's actual properties (the Z 5 only reports indicate, `:927-953`).
3. Subscribe to `0x2008`, `0x200A`, `0x2020`, `0x2021` (`:1789-1861`) and wait 400 ms (`:1262`).
4. LSS authentication (section 3).
5. Write `0x2002`: fixed 32 bytes, name bytes + zero padding, no length prefix (`:620-717`). The code records that writing before authentication is rejected (the same write twice returns `-41`), while the same write after authentication returns `0` (`:1350-1360`, `:3157-3169`).
6. Write `0x2005`, read `0x2003` for the camera's self-reported name (`:1377-1379`), then read the `0x200B` serial number, `0x2A19` battery level, `0x2A26` firmware, `0x2009` feature three times in a row and `0x2008` twice (`:1380-1387`, `:1926-1982`).
7. System-level classic Bluetooth pairing (`:1395-1437`): open an RFCOMM server listener, make the phone discoverable, issue one triggered `pairDevice`, then wait up to 120 s for the camera to reconnect and emit a code (`:2665-2672`).
8. Pairing-code routing (`:2369-2398`): when `pinType=2`, write the code into `AppStorage('nikonPairCode')` and hand it to the UI, where the user confirms in the system dialog; for other types try `setDevicePairingConfirmation`, falling back to `setDevicePinCode` on failure. The code notes that `setDevicePairingConfirmation` requires the system-level `MANAGE_BLUETOOTH`, which an ordinary app does not get (`:2422-2434`).

RFCOMM uses the standard SPP UUID `00001101-0000-1000-8000-00805F9B34FB` with `secure: true`, so that the protocol stack initiates pairing itself when the camera connects (`:2021-2031`, `:2161-2165`).

## 3. LSS Authentication

### 3.1 The 17-Byte Frame

The layout is fixed by `NikonLssProtocol.ets:40-57`; encoding/decoding is at `:142-174`:

| Offset | Length | Field |
|---|---|---|
| 0 | 1 | stage (1/2/3/4) |
| 1 | 8 | nonce |
| 9 | 8 | deviceId |

No length prefix, no padding. `decodeLssAuthFrame` requires a length ≥17 and returns null for short frames (`:161-163`); stage is taken from `bytes[0] & 0xff`.

### 3.2 Semantics and Order of the Four Stages

The state-machine constants and admission conditions are in `NikonLssSession.ets:242-248` (0 new → 1 init → 3 stage1 → 5 stage3 → 6 keyed), and the stage order is chained together by `authenticate` (`NikonBleProvisioning.ets:3170-3233`):

1. **stage 1 (phone→camera)**: after `init(Date.now() & 0x7fffffff)`, take an 8-byte phone nonce (`:3175-3176`). The nonce comes from `cryptoFramework.createRandom().generateRandomSync(8)` (`NikonLssSession.ets:325-337`), and the comment states explicitly that the seed does not participate in the on-wire bytes. The frame is `[1][N_B][selfDeviceId]` (`NikonBleProvisioning.ets:3194-3195`).
2. **stage 2 (camera→phone)**: must satisfy `stage === 2` (`:3203-3207`). Here `nonce` is the camera nonce `N_A`, and what the `deviceId` field carries is **MAC1** (the contract description in `NikonLssSession.ets:344-354`).
3. **stage 3 (phone→camera)**: `session.stage3(N_A, MAC1)` computes `MAC(tbl[i] || N_A || X)` for each of the 8 candidate roots and compares against MAC1; on a hit it returns `MAC2 = MAC(tbl[i] || X || N_A)` (note the swap, `:354-394`). The frame is `[3][N_B][MAC2]` (`NikonBleProvisioning.ets:3215-3216`).
4. **stage 4 (camera→phone)**: must satisfy `stage === 4` (`:3223-3227`). Its `deviceId` is used verbatim as `key1` and written into `lastCameraDeviceId` (`:3228-3231`).

The camera drives stages 2 and 4; the phone sends only frames 1 and 3 (`NikonLssProtocol.ets:258-268`: the native `Stage2nd`/`Stage4th` are never called from Java).

### 3.3 Where deviceId Comes From (Including an Unresolved Item)

The two 8-byte fields must be considered separately:

- **`deviceId` of the stage 1 frame**: the code currently uses "the phone's own persisted 8-byte identity". The basis is written in `NikonBleProvisioning.ets:128-153`: the official app decodes the Base64 string in `SharedPreferences("DeviceID")` and passes it to `BleConnection.connect`; on first run it is generated with `Random(System.currentTimeMillis()).nextBytes(new byte[8])`, and the length is asserted to be exactly 8. The implementation is `loadClientDeviceId` (`:286-332`), with storage name `nikon_lss_identity` and key `DeviceID` (`:156`, `:294-298`).
- **The field of the same name in the stage 2/4 frames**: it is not an identity. stage 2 carries MAC1 and stage 4 carries key1 (`NikonLssSession.ets:344-354`, `NikonBleProvisioning.ets:3208`, `:3231`).

**Conflict with the module header comment**: `NikonBleProvisioning.ets:26-34` still says "the source of `cameraDeviceId` is an open item, supplied by the caller and not invented". That is a stale conclusion; the current implementation (`:1103-1113`, `:3181-3193`) has switched to a persisted client identity. Following the "code first" principle, this report takes the persisted identity as authoritative and records that the comment is out of date. The old "derive candidates from the camera's Bluetooth address" logic is still present (`buildDeviceIdCandidates`, `:1714-1731`), but it is only used for logging and as a fallback (`:1111-1121`); `authenticate` does not use that parameter internally (signature `:3170-3172`).

**One item that remains unresolved**: whether the `key1` the camera returns in stage 4 equals the root `tbl[idx]` the phone matched. The code does not assume it, it only diagnoses it: `describeKey1` outputs `key1=shared-root index=N` or `key1=other index=N` (`NikonLssSession.ets:452-462`, called at `NikonBleProvisioning.ets:3228-3231`). This is the point on this line that most needs one on-hardware log to close.

### 3.4 Key Derivation and Blowfish

The session key does not come from any hardcoded constant; it is the 8-byte MAC output fed into the standard Blowfish key schedule:

- `ctx[0..7] = idx || N_A[1..3] || X[0..3]`, where idx is the index of the matched root and X is the phone nonce (`NikonLssSession.ets:376-386`).
- `K = MAC8(key1 || key2 || ctx)`, where `key2` is the persisted client identity; `new NikonBlowfish().initKey(K)` (`:428-445`).
- Fields are decrypted in CBC, **each field independently, with an all-zero IV**: the 32-byte SSID and the 64-byte password are two separate decryptions, because the library re-reads the IV on every call and never writes the terminal chain back (`:464-514`).

The MAC itself is a "fixed-schedule Blowfish-CBC-MAC": the initial chain is `01 02 03 04 05 06 07 08`, each block is XORed with the chain and then encrypted, and the chain becomes the result; a tail shorter than 8 bytes is padded with `0xFF`, and no extra block is appended when the length is exactly a multiple of 8 (`NikonLssSession.ets:174-226`).

### 3.5 The Hash Table (Preset Schedule Table)

`NikonLssHashTable.ets:1-12`: taken from `.rodata @0x2e28` of `libLsSec-jni.so`, 1042 words (18 P + 4×256 S), 8336 hex characters in total; it is **not the standard Blowfish initial values** (P[0]=`e813ec15`, the standard value is `243f6a88`); the schedule was derived by some fixed key schedule whose key is unrecoverable from the .so, so the table can only be moved wholesale and **`initKey` must not be called on it again**.

The same table is inlined a second time in `NikonLssSession.ets:67-133` (`MAC_SCHEDULE_HEX`). The currently active encryption path uses that inlined copy; `NikonLssHandshake` in `NikonLssCrypto.ets:328-457` (hash/generateKey/decipher), although fully implemented, has no caller anywhere in the repository — a duplicate implementation, see the risks in section 9.

### 3.6 Success and Failure Determination

There is no explicit "authentication succeeded" response byte. Success requires both steps: a hit among the 8 roots (`stage3` returns non-null) and successful session-key derivation (the branch at `NikonBleProvisioning.ets:1319`). Failure paths and messages (`NikonBleProvisioning.ets:3197-3213`, `3218-3227`, `1333-1335`):

| Condition | Result |
|---|---|
| no 0x2000 notification within 15 s | "round 1/2 timed out" (original: `第 1/2 轮超时`) |
| stage value is not 2 / 4 | "malformed response" (original: `响应格式异常`) |
| none of the 8 roots matches MAC1 | "could not match the camera response among the 8 shared roots" (original: `未能在 8 个共享根中匹配相机响应`) |
| key derivation fails | trace is recorded, credential decryption is skipped |
| credential decryption / sanity check fails | "Nikon Bluetooth authentication passed, but the Wi-Fi credentials could not be decrypted" (original: `尼康蓝牙认证已通过，但 Wi-Fi 凭据未能解密`) and returns |

Timing and transport details: the authentication notification waits 15 s and polls every 100 ms (`:74-76`, `:1764-1778`); after the CCCD subscription the code explicitly waits 400 ms before the first write, to avoid "subscription and write colliding on one unfinished operation" making the local stack return 2900099 directly (`:1245-1262`); the MTU request is 512 (`:1143`).

## 4. Wi-Fi Credential Parsing

A single read of `0x2004` returns the whole block (the comment at `NikonCameraService.ets:54-57` says the same). The parser `parseLssConnectionConfiguration` (`NikonLssProtocol.ets:213-256`) proceeds in the following order:

| Order | Field | Length | Notes |
|---|---|---|---|
| 1 | flag | 1 | bit0=Wi-Fi block, bit1=Bluetooth block (`:63-65`) |
| 2 | ssid | 32 | encrypted |
| 3 | password | 64 | encrypted |
| 4 | security | 1 | plaintext, read as a signed byte (`:237`) |
| 5 | sppMaxDataLength | 4 | only when bit1 is set, little-endian u32 (`:247-254`) |

The wire value of security equals the enum's `value`, not its ordinal: `UNDEFINED -1 / OPEN 0 / WPA2 1 / WPA3 2 / WPA2_WPA3 3` (`NikonLssProtocol.ets:26-30`, `:80-101`).

After decryption the bytes are UTF-8 decoded up to the first NUL and trimmed (`:183-199`), then sanity-checked: SSID length 3–32, password 0–64, every character within the printable range 32–126 (`:128-139`, called at `NikonBleProvisioning.ets:1328-1331`). An empty password is allowed, corresponding to the OPEN case. If any field decryption returns null or the length is insufficient, the parser returns null outright (`:241-243`) and never treats a half-garbled string as credentials.

**Link-drop policy**: on a parse failure or a failed sanity check, `configuration` stays null and the flow returns immediately with "authentication passed, but the Wi-Fi credentials could not be decrypted" (`NikonBleProvisioning.ets:1336-1340`), and does not proceed to join the network — because joining a hotspot with the wrong key would only produce one meaningless association failure and mask the real cause.

Joining uses only ssid and password: `connectWifi(ssid, password, ...)` has no security parameter (`:1608-1615`), and `result.security` is used only for reporting and logging (`:1343-1346`). `sppMaxDataLength` is parsed but currently has no consumer; the UUID used by the RFCOMM listener is the standard SPP `00001101-...` (`:2027`, `:2161-2165`) and has nothing to do with that field.

## 5. Wi-Fi Join and Handover to PTP/IP

The camera is the AP and the phone is the STA; both SSID and password are supplied by the camera over BLE (`NikonBleProvisioning.ets:1341-1347`), and the code hardcodes no camera hotspot address.

The key order (this is where debugging cost the most on this line, and the comments document it fully):

1. After authentication completes, read `0x2001` (`:1502-1515`; in a bound session the official app reads it first and does not write).
2. Write `0x2005 = [1]` to request connection bring-up (`:1521`). Note that the function header comment says Wi-Fi should write `0x05` (`:801-817`), but both call sites actually pass `0x01` (`:1377`, `:1521`), and `:1518-1520` records that on hardware the official app does use `[1]`.
3. Open the RFCOMM listener and wait for the camera to connect on its own (25 s at most, `:1574`), then **release Bluetooth entirely**: close the RFCOMM client/server, exit discoverable mode, stop the BLE scan, `release()` to close GATT, then wait 2 s and close once more (`:1567-1597`). The reason is that the camera can only run one radio path at a time and will not start the hotspot while the Bluetooth link is still up (`:1551-1566`, `:2259-2273`).
4. Scan and join: `connectWifi(ssid, password, trace, 1, noop, 75000, false, onStatus)` (`:1608-1615`), i.e. one attempt, a scan of up to 75 s, and a status callback that keeps refreshing progress.
5. After a successful join, take the gateway and local address from the system (`LumixImportPrototype.ets:3033-3047`, the gateway from `wifiManager.getIpInfo().gateway`); `result.gateway` is the host for the subsequent PTP/IP (`CameraPage.ets:2253`, `:5267`).

Entry-point split: `provision(..., pairOnly=true)` only pairs and does not touch the hotspot (`NikonBleProvisioning.ets:1457-1488`); `startWifi` reuses the existing pairing and only brings up the hotspot and associates (`:990-1001`), and is called by `CameraPage.ensureNikonWifiForAction` on "image transfer/camera control" (`CameraPage.ets:5626`, `:5681`). On join failure the message points explicitly at the camera side (the camera must stay on the "connect to smart device" screen), because the credentials themselves come from the camera (`NikonBleProvisioning.ets:1618-1633`).

## 6. PTP/IP Transport

Port `15740` (`NikonPtpIpService.ets:492`); two TCP connections are opened on the same port: the command channel and the event channel (`:1915-1935`).

### 6.1 Handshake

1. Command connection → `InitCommand` (type 1): 16-byte GUID + UTF-16LE device name `Pixelshop Camera` + trailing NUL + u32 version `0x00010000` (`:2696-2703`). The frame format is `[len u32][type u32][payload]` (`:2726-2732`).
2. Wait for `InitCommandAck` (type 2) and take its u32 as the connectionNumber (`:1925-1930`). The first frame is not trusted blindly: skipping 1 unexpected frame is allowed and logged (`:1990-2020`).
3. Event connection → `InitEvent` (type 3, payload is that connectionNumber) → wait for `InitEventAck` (type 4) (`:1931-1935`).
4. `OpenSession` (`0x1002`, parameter `[1]`, transactionId fixed at 0); the response must be `0x2001`; `0x201E` (SessionAlreadyOpen) is named separately (`:1936-1951`, `:540`).

### 6.2 Frame Types

The constants are defined in `NikonPtpIpService.ets:494-525`, and every frame has an 8-byte header `[len u32][type u32]`:

| type | Name | Payload |
|---|---|---|
| 1 | InitCommand | GUID16 + UTF-16LE name + version u32 |
| 2 | InitCommandAck | connectionNumber u32 |
| 3 | InitEvent | connectionNumber u32 |
| 4 | InitEventAck | empty |
| 6 | OperationRequest | dataPhase u32 + opcode u16 + tx u32 + params |
| 7 | OperationResponse | code u16 + tx u32 + params |
| 9 | StartData | tx u32 + total length u64 (+ optional inline data, see `:2276-2284`) |
| 10 | Data | tx u32 + fragment |
| 11 / 12 | EndData | tx u32 + final data segment; sending uses 12, receiving accepts both |

### 6.3 Transactions and Error Handling

All commands are serialized through a session queue: only one request/response (including the complete data phase) occupies the command channel at any time (`:436-454`). The payload of operation request type 6 is `dataPhase u32 + opcode u16 + tx u32 + params u32[]` (`:2705-2724`); response type 7 is `code u16 + tx u32 + params u32[]` (`:2059-2074`).

Data phase: `StartData`(9, tx + u64 total length), `Data`(10, tx + fragment), `EndData`. The EndData constant is **12**, because on hardware 12 is accepted by the camera and changing it to 11 as the spec says makes property writes hang for 10 s and poisons the session (`:502-525`); the receive side accepts both 11 and 12 (`:2322-2334`). Note that the comment on the receive path (`:2324`) still says "the sender has already been changed to use only 11", which contradicts the actual constant — a stale comment.

A timeout poisons the session (`session.failed`, `:2351-2358`); callers such as live view can pass `tolerateTimeout` to treat "the camera does not answer for now" as no frame this time rather than a broken link (`:2194-2246`). After poisoning, `recoverSession()` can reopen once (`:2380-2409`). A graceful shutdown sends `0x1003 CloseSession` before dropping TCP; otherwise the camera considers the link faulty, leaves "connect to smart device" mode and shuts the hotspot down with it (`:1731-1761`).

### 6.4 Event Channel

One background loop per session, with a 60 s idle timeout treated as normal (`:668`, `:2414-2433`). Events handled: `0x400D` CaptureComplete, `0x4006` DevicePropChanged (only the property code is registered, no immediate read-back), `0xC10A` recording started, `0xC108` recording finished, `0xC105` recording interrupted (`:2435-2476`, `:652-658`).

### 6.5 About KeepDeviceOn

The task brief named `KeepDeviceOn`. **The Nikon line does not have it**: across the whole repository, `KeepDeviceOn` appears only in `CanonPtpIp.ets:7` and `:599` (`0x911D`, the Canon line). Nikon's keep-alive/readiness semantics are carried by polling `0x90C8 DeviceReady` (`NikonPtpIpService.ets:568-570`, `:1069-1082`), once every 100 ms with a 30 s upper bound (`:597-601`, `:1146-1164`). This corrects the task's premise according to the code facts; the Canon opcode was not moved onto the Nikon line.

## 7. Control Plane

| Capability | Opcode | Parameters / data phase | Source |
|---|---|---|---|
| Take control | `0x90C2` | `[1]`=HOST, `[0]`=CAMERA | `:1298-1330`, `:1346-1360` |
| Start live view | `0x9201` | no parameters | `:571`, `:1285-1292` |
| End live view | `0x9202` | no parameters | `:572`, `:1333-1335` |
| Fetch one frame | `0x9203` (default) | data phase returns a 384-byte header + JPEG | `:573`, `:1398-1445` |
| Fetch one frame (high-resolution variant) | `0x9428` | same as above, but **off by default** | `:574`, `:1272-1282` |
| Shutter | `0x9207` | `[releaseMode, storage]` | `:603-630`, `:1096-1110` |
| Readiness polling | `0x90C8` | no parameters | `:570`, `:1069-1082` |
| Recording start/stop | `0x920A` / `0x920B` | no parameters | `:582-595`, `:1362-1388` |
| Switch application mode | `0x9435` | `[0/1]` | `:579`, `:1454-1467` |

Live view: before starting the stream, send `0x90C2 [1]` to take control (`:1286-1291`); without it the body rejects mode dial changes (`0x500E` → `0x200F`) and recording (`0x920A` → `0xA004`) (`:1304-1311`). The frame data is a 384-byte **big-endian** header + JPEG, with the length in the u32 at offset 4; when the length field is untrustworthy the code falls back to the whole tail, to avoid cutting out a corrupt JPEG (`:632-637`, `:1429-1443`). `0x9428` is implemented but `liveViewUsesEx=false`: tried on the Z 5 on 2026-10-18, the frame request was accepted but the header layout differs, the page showed no picture at all, and this "succeeds but with a different format" cannot be detected as a downgrade from the code (`:1272-1282`).

Shutter: `capture()` first polls readiness, then sends `0x9207` (`RELEASE_NORMAL=-1`, AF variant `-2`, memory card `0`), then polls until ready again; the busy codes `0x2019/0xA200/0xA201/0xA207` are treated as "keep waiting" (`:597-601`, `:1121-1137`). Completion can also be cross-confirmed by the `0x400D` event (`:2448-2453`).

On a recording failure, `0xD0A4` (recording prohibition conditions) is read afterwards to give the body-side reason (`:1362-1382`).

### 7.1 Why Property Read/Write "Looks Like It Is Not Wired to the UI"

The comment at `CameraControlBrand.ets:70-91` is the part the task asked to be quoted; its key points:

- `NikonPtpIpService` does have `readProperty` / `writeProperty`, with the property codes `PROP_APERTURE 0x5007`, `PROP_WHITE_BALANCE 0x5005`, `PROP_EXPOSURE_MODE 0x500E`, `PROP_ISO 0x500F`, `PROP_EXPOSURE_COMPENSATION 0x5010`, `PROP_SHUTTER_SPEED 0xD100`;
- "the value encoding of each property (is aperture f×100? is shutter a fraction or milliseconds?) and the set of allowed values have not been verified on hardware, and there is no body-reported record table such as `SDIO_GetAllExtDevicePropInfo` to rely on; and of the 28 supported models only 8 (Z 50 / Z 5 / Z fc / Z 30 / Z f / ZR / Z5II / Z50II) support BLE parameter remote control";
- therefore these 12 panels (`lut/quality/aspect/settings/mode/ev/shutter/aperture/iso/wb/metering/lvsize`) are rendered as "visible but unavailable" (`:87-91`).

The actual wire encoding of properties: `0x1014` fetches the descriptor, `0x1015` reads the value, `0x1016` writes the value (`NikonPtpIpService.ets:552-567`, which also records that "0x1014/0x1015 were once swapped and on-hardware logs rejected that", on the basis that the returned widths of 1–4 bytes match the official data classes).

**Difference from the current code (code governs)**: Nikon parameters are already wired to the UI; they merely bypass `CameraControlBrand`'s static panel table. `controlPanelEnabled` at `CameraControlPage.ets:3493-3515` returns early under `nikonMode`: whether a panel is usable depends on "whether a valid descriptor was obtained for the property code that panel maps to", and `nikonPropCodeOfPanel` covers the six panels `mode/aperture/shutter/iso/ev/wb` (`:3523-3539`). Descriptor probing and parsing are in `NikonCameraParameters.describe/probe` (`NikonCameraParameters.ets:181-289`), and write-back goes through `NikonPtpIpService.writeProperty` (`:408-417`). The display encoding also has a source: aperture is the F number ×100, per the official `FNumber` enum (`CameraControlPage.ets:3592-3594`); the white-balance value table comes from the official enum and matches the on-hardware enum item by item (`NikonCameraParameters.ets:291-319`).

So the accurate answer to "why is it not wired to the UI" is: **that comment in `CameraControlBrand` describes the state before the integration, and has since been superseded by the "body self-reported probing" approach in `CameraControlPage`; the static table no longer takes effect on the Nikon path.** The 28/8 model-capability conclusion in the comment cannot be verified anywhere in the repository (`NikonCameraService` only identifies 14 Z models), so it is recorded as the original comment states and marked unverifiable.

## 8. Image Transfer

Enumeration (`NikonPtpIpService.ets:775-872`):

1. `0x1004 GetStorageIDs` to get the card list;
2. per card, `0x1006 GetNumObjects [sid,0,0]` and `0x1007 GetObjectHandles [sid,0,0]`;
3. handles are sorted ascending and then ordered **in reverse within each card** (newest first), keeping slot order between cards; each card has an independent handle space, ownership is recorded with `storageOf`, and `imageId` has the form `card:handle` (`:832-849`, `:900-917`);
4. an empty card still counts as a usable card, and the UI shows a greyed-out "card 2" accordingly (`:823-828`, the `NikonPtpIpCatalogResult.storageIds` comment at `:34-39`).

Paging and thumbnails (`:2545-2616`): at most 48 handles are examined per page (`:688`); uncached handles first go through `0x1008 GetObjectInfo`; `size<=0` or format `0x3001` (directory) is skipped; `0x100A GetThumb` is written to disk as `nikon_thumbnail_<card>_<handle>.jpg`; videos without thumbnails are still listed, just marked as not previewable.

Original-image download (`:919-972`, `:2621-2682`):

- a size exceeding u32 is rejected outright (`:926-929`);
- with a known size it uses `0x101B GetPartialObject [handle, offset, len]`, 1 MB at a time; a short block, an empty block, an overlong block or a length that disagrees with the parameter all count as failure;
- it falls back to `0x1009 GetObject` only when the first fragment gets `0x2005` (operation not supported), with a 64 MB cap for the whole object (`:689`, `:2669-2671`);
- it writes a `.part` file and, after verification passes, `rename`s it to the final file, avoiding "a truncated file that looks complete" (`:934-955`);
- at the end it records throughput in MB/s, to make it easy to compare with SnapBridge and judge whether the bottleneck is the body's wireless or the transport stack (`:956-960`).

## 9. Implementation Map and Conflict List

| Topic | Implementation | Notes |
|---|---|---|
| Advertisement identification | `NikonBleProvisioning.ets:417-563` | three-way admission on UUID / model name / naming habit |
| GATT layout | `NikonCameraService.ets:44-69` | private base suffix |
| LSS frame | `NikonLssProtocol.ets:40-57,142-174` | 17 bytes |
| State machine | `NikonLssSession.ets:241-394` | 1→2→3→4, the phone sends only 1/3 |
| MAC/key | `NikonLssSession.ets:174-226,428-445` | preset schedule + CBC with zero IV |
| Credentials | `NikonLssProtocol.ets:213-256` | flag/SSID/PW/security/spp |
| Network join | `NikonBleProvisioning.ets:1449-1637` | 0x2005 → drop Bluetooth → associate |
| PTP/IP | `NikonPtpIpService.ets:1907-1973` | dual channel + OpenSession |
| Control | `NikonPtpIpService.ets:1096-1450` | live view/shutter/recording/properties |
| Image transfer | `NikonPtpIpService.ets:775-972,2545-2682` | enumeration/thumbnails/fragmented download |

Conflicts within the code (code behaviour governs in every case):

1. `NikonBleProvisioning.ets:26-34` says the deviceId source is unresolved; `:128-153` and `:1103-1113` already give the persisted identity and mark the old reasoning as "refuted". The header comment is out of date.
2. `NikonLssSession.ets:396-402` says `key2` is "the camera device id passed into the authentication call"; the actual call passes `clientDeviceId` (`NikonBleProvisioning.ets:1319`).
3. `NikonBleProvisioning.ets:801-817` says the Wi-Fi request writes `0x05`; the actual calls write `0x01` (`:1377`, `:1521`).
4. The comment at `NikonPtpIpService.ets:1219-1233` requires property writes to declare `DataPhaseInfo 3`; the actual `executeTransactionDataOut` computes `payload.length===0 ? 1 : 2` (`:2114-2122`, with on-hardware evidence attached that 3 yields `0x201F`).
5. `NikonPtpIpService.ets:2324` says the sender has switched to 11; the constant is still 12 (`:523`) and the send site uses 12 as well (`:1667`).
6. The table at `NikonCameraParameters.ets:10-14` writes `0x1015` as Desc and `0x1014` as Value; the file's own call to `readPropertyDesc` actually sends `0x1014` (`NikonPtpIpService.ets:1188`), the opposite of its own table.
7. The panel list in `CameraControlBrand.ets:70-91` is bypassed by the runtime probing in `CameraControlPage.ets:3493-3515` (see 7.1).
8. `NikonBleProvisioning.ets:642-649` requires the name reported to the camera to equal the phone's advertised name; but `openBtcListener` tries to set the local name to a fixed `Pixelshop` (`:1995`, `:2138`), while the `0x2002` write takes the system's current name (`:650-654`). When renaming fails (unsupported on the phone, `:2134-2145`) the two happen to agree; when renaming succeeds they disagree.

## 10. Limitations and Risks

1. **BLE parameter remote control has narrow coverage**: the comment claims that only 8 of 28 supported models support BLE parameter remote control, but the repository has no corresponding capability table, so it cannot be checked; actual availability is decided by the body's answer to `0x1014` (`CameraControlPage.ets:3494-3512`).
2. **LSS unresolved item**: whether `key1` equals the matched shared root can still only be judged from the one `describeKey1` log line (`NikonLssSession.ets:452-462`); until that is confirmed, the correctness of credential decryption depends on a "printable text" heuristic (`NikonLssProtocol.ets:116-139`), and that check can reject a wrong key but cannot prove the key right.
3. **Keys are not persisted**: the session key exists only in the static field `lastSessionKey` (`NikonBleProvisioning.ets:1734`, `:1349`), `takeSessionKey` returns a copy (`:1751-1756`), and it is lost on process restart; after a restart only the Bluetooth flow can be rerun. The only persisted item is the client identity `DeviceID` (Base64, plaintext preferences, `:316-319`), which is an identity, not a key.
4. **Duplicate algorithm implementations**: the 8336-character schedule table is stored once in `NikonLssSession.ets:67` and once in `NikonLssHashTable.ets:12`; `NikonLssHandshake` (`NikonLssCrypto.ets:328-457`) is a second, complete but uncalled implementation. Changing one and missing the other fails silently.
5. **Comment drift**: of the 8 conflicts in section 9, 4 are cases of "the comment is still stuck at the previous round's conclusion". This kind of drift has already caused misjudgements on this line (0x1014/0x1015, DataPhaseInfo, EndData); maintenance should prefer on-hardware logs and constant definitions.
6. **Camera-side state is a hard precondition**: the hotspot only appears after the camera enters "connect to smart device" and the Bluetooth link is released; a successful `0x2005` write does not mean the camera will act (`NikonBleProvisioning.ets:1541-1550`, `:1618-1633`). An automated flow cannot bypass the user's operations on the body.
7. **BLE read of 0x2004 is MTU-sensitive**: on the Z 8, `2900007` (Invalid Offset) and `2900011` (Insufficient Resources) have occurred, while the Z 5 succeeded under the same conditions; MTU 512 therefore only removes the fragmentation path, it is not a root-cause conclusion (`:1126-1146`).
8. **One-sided deletion leaves a pairing mismatch**: when the phone side is still bound and the camera side has deleted the pairing, `pairDevice` is rejected by the system (2900099) without changing state; the code can only report this truthfully and advise deleting on both sides, because the HarmonyOS public API has no unpair (`:2568-2575`, `:2705-2710`).
9. **The `cameraDeviceIds` parameter is now useless**: `authenticate` accepts it but does not use it (`:3170-3172`), and it appears only in upper-layer logging (`:1120-1121`). It is a historical leftover; misreading it makes one think multiple identities are still being tried.
10. **Property-write direction encoding is still held in place by measurement**: `DataPhaseInfo` is 2 in the Nikon implementation (not CIPA's 3), based on the 2026-10-18 packet capture (`:2114-2122`); it must be re-confirmed when changing models or firmware, otherwise it shows up as "all writes cancelled by `0x201F`".

## 11. One-Sentence Conclusion

The protocol skeleton of this line is complete: BLE identification → 17-byte LSS four stages → session key derived by MAC over the preset Blowfish schedule → `0x2004` credential decryption → drop Bluetooth and join the network → TCP 15740 dual-channel PTP/IP → live view/shutter/image transfer. The real uncertainty is concentrated in two places: the semantics of `key1` in stage 4 (needs one on-hardware log to close), and the camera-side precondition of whether it is willing to start the hotspot, which the protocol does not decide.
