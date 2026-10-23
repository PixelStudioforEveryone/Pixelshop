# Panasonic, line 2 of 3: the LUMIX Sync generation (BLE GATT pairing + cam.cgi + DMS pull)

**English** | [简体中文](../02-panasonic-lumix-sync.md)

> Translated from the Chinese original at baseline `18466be` (`docs/protocol-reports/02-panasonic-lumix-sync.md`). UUIDs, opcodes, ports, byte offsets, `file:line` references and code identifiers are kept exactly as written in the original; text inside code spans is not translated.

- Baseline commit: `18466be` (workspace `C:\Users\HQ\DevEcoStudioProjects\VIVID`, ArkTS project Vivid)
- Evidence source: read-only code. Main files `LumixSyncControlService.ets` (2052 lines), `LumixSyncImageTransfer.ets` (1684 lines), `LumixImportPrototype.ets` (4450 lines), `LumixCameraService.ets`, `CameraSessionStore.ets`, `pages/home/CameraPage.ets`, `pages/CameraControlPage.ets`
- "Official" in this document means the LUMIX Sync official APK (jadx) and the on-hardware capture findings recorded in code comments (the comments carry dates); it is not a re-decompile or a re-capture performed for this report
- Anything the code cannot prove is marked "inferred" together with its basis; a UUID whose purpose the comments do not state is marked "not annotated in code"

## 0. Summary

The LUMIX Sync line is the connection method for Panasonic bodies predating Lab: BLE GATT registers the phone identity into the camera and retrieves the hotspot credentials → the phone joins the camera SoftAP → HTTP `cam.cgi` authorises and controls → the body's built-in DLNA MediaServer (DMS) actively pulls images. The three protocol layers sit in three places: BLE pairing and cam.cgi in `LumixSyncControlService.ets`, DMS browse/download in `LumixSyncImageTransfer.ets`, and generic capabilities such as GATT read/write and Wi-Fi join in `LumixImportPrototype.ets`. The two most critical facts are that **`req_acc` is the registration commit** (the first call returns `ok_under_research`, only the resend returns `ok`) and that **a quiet period of a dozen-plus seconds must follow the commit** (19 s / 34 s officially, whereas this implementation was rejected immediately with 2 s); both are backed by capture timestamps in the header comment at `LumixSyncControlService.ets:31-52`.

## 1. Line assignment and model mutual exclusion

### 1.1 The three lines

`panasonicRouteForModel()` returns `'lab'` / `'sync'` / `'lumix_image'` / `''` (`LumixCameraService.ets:1742-1807`):

| Line | Protocol shape | Models (code constants) |
| --- | --- | --- |
| `lab` | Lab REST (HTTPS `/auth`, `/media/...`) + BLE registration | S5M2X, S5M2, S1RII/S1RM2, S1II/S1M2, S1IIE/S1M2E, S9, GH7, G9II/G9M2, L10 (`LumixCameraService.ets:302-303`) |
| `sync` | BLE GATT pairing + `cam.cgi` + DMS | S1H, S1R, G100, G100D, GH5M2, GH6, GH1 (`LumixCameraService.ets:336-338`), plus the first-generation S5 and the ZS300/TZ300 admitted through `isWifiOnlyModel` |
| `lumix_image` | No Bluetooth; manual/QR-code hotspot join + SSDP + `cam.cgi` + DLNA, retaining camera-side passive push | TZ99, ZS99, G90/G91/G95/G95D, TZ95~TZ97, ZS80, GH5, GH5S, G9 and others (`LumixCameraService.ets:372-401`) |

### 1.2 Mutual exclusion with the Lab line

Mutual exclusion is an explicit invariant, not a side effect of "whichever check happens to run first". The definition site of the Sync table says so outright: routing a Lab body onto the Sync line would let the same camera be claimed by two lines at once, so `PANASONIC_SYNC_MODEL_TOKENS` subtracts the Lab table from the candidates directly, and subtracts only on exact token equality (`LumixCameraService.ets:305-338`). The same place also records: **GH5 / GH5S / G9 were moved from the Sync line to the Image App line on 2026-10-11** — in the Sync source these three appear only in legacy UI/menu special cases (`g5/a.java:84`, `x5/C3066j.java:330`, `N5/l.java:1378`), while the official Image App support table explicitly lists DC-GH5/GH5S/G9, and none of the three has Bluetooth, so keeping them on this BLE-gated line would mean they can never connect.

None of the seven Sync tokens overlaps the Lab table, so all are kept; Sync's `S1R` and Lab's `S1RM2`/`S1RII` are different strings and do not swallow each other. The decision order is Lab table → first-generation S5 → "seen over BLE but not Lab" (`fromBle`, 2026-10-18 rule) → `isWifiOnlyModel` → Sync token table → Image App fallback (`LumixCameraService.ets:1766-1806`). Lab must come first: callers pass a three-part concatenation of "model + BLE candidate model + BLE advertised name", and running `isWifiOnlyModel` first would let residual S5/ZS300 tokens misroute a whole S1RM2/S9 onto Sync (on hardware, 2026-10-11: an S1RM2 image transfer wrongly took the sync line).

### 1.3 The S5 / ZS300 special case

The comment on `isWifiOnlyModel()` first corrects a mistake: the name **does not mean there is no Bluetooth** — every body in the set has Bluetooth, with credentials handed over by Sync's BLE pairing, and the predicate only answers "should the Lab GATT registration be used" (`LumixCameraService.ets:449-460`). The implementation splits on whitespace and judges token by token; as soon as `S5M2`/`S5M2X` appears, the whole thing is rejected (`461-496`). ZS300 and TZ300 are two regional names for the same body, and all three forms — bare model string, vendor-prefixed, and model plus instance suffix — are recognised, using anchored regular expressions; `endsWith`/`indexOf` partial matching is not allowed (`498-520`). S5 additionally has a separate `requestS5Access()`: `value` carries the client identifier and `value2` carries the DMS network name (default `WEB-W00`, and the comment states plainly that it is neither the camera SSID nor its password); this differs from the main path's `value2=Pixelshop` and is not inside the `pairAndConnect` flow (`2208-2235`).

## 2. BLE pairing

### 2.1 Advertisement identification

Scanning is filtered by the Sync service UUID `054ac620-3214-11e6-ac0d-0002a5d5c51b` (`LumixImportPrototype.ets:312`). Identification uses the protocol fields in the advertisement rather than the freely changeable display name (`313-343`, `2220-2284`):

1. **Manufacturer data (AD type 0xFF)**: company ID 58 (little-endian, 2 bytes) + exactly 6 bytes of payload; payload bytes 2..5 are the 4-byte public Bluetooth address, i.e. `btAddress` in the code (8 hex digits). The address offset is fixed at 2 in both official state branches; the state byte is found by scanning the 6 bytes for the first 0 or 3, and its position is not fixed.
2. **Last two bytes of the local name**: the second-to-last byte is the `0x0A` marker and the last byte is the model code 1..9, mapped by the table `['', 'S9', 'GH7', 'S5M2', 'S5M2X', 'G9M2', 'S1M2E', 'S1M2', 'S1RM2', 'L10']` (`339-343`). This table is **the Lab APK's table**; whether Sync bodies fall within 1..9 has no answer in the code. `logAdvertisement()` lists "what code a given Sync body actually advertises" as a question the APK cannot answer and that only device logs can settle; when a code is out of range, that body keeps the name fallback and its routing is unchanged (`2201-2218`).
3. When the service UUID appears (128-bit, little-endian) in AD type 0x06/0x07, `hasLumixService` is set; this is diagnostics only (`2271-2280`).

This corrects a common claim: **the manufacturer data contains no model code**; it supplies only the 4-byte Bluetooth address, a "short identity", while the model code sits in the last byte of the local name; only the combination of the two is this line's stable identifier (renaming the camera affects only the latter, changing the address only the former). The comments state two deliberate "relaxations": the service UUID and the "some byte is 0 or 3" state check are logged only and not enforced; the strong signals are company 58 six bytes + a 1..9 code value; 58 does not collide with Nikon's 135 or Sony's 301.

### 2.2 Service and characteristic UUIDs

Primary service `054ac620-3214-11e6-ac0d-0002a5d5c51b` (`LumixSyncControlService.ets:135`). Purposes are copied from the comments of `indexSyncCharacteristics()` (`1798-1828`); anything the comments do not state is marked "not annotated in code":

| UUID | Service | Code purpose |
| --- | --- | --- |
| `03e23a31-a54c-40fa-a668-de9acdc910bb` | 054ac620 | `INITIAL_INFORM`, reads the session key (first 4 bytes) |
| `bb5d2a8c-5d3b-43ad-bfc3-470cad55c1ca` | 054ac620 | APS body DLNA UUID write (o.d encoding) |
| `7b61774f-efb4-44c6-a66d-c69e3b384c4a` | 054ac620 | APS body friendly-name write (o.c encoding) |
| `e206a5c0-3214-11e6-afe4-0002a5d5c51b` | 054ac620 | Wi-Fi SSID read (semicolon-separated list) |
| `c97cf1a5-3c03-4290-8c1b-9e74b9500f54` | 054ac620 | Wi-Fi password read (XOR encoding, length byte first) |
| `8d08a420-3213-11e6-8aca-0002a5d5c51b` | 054ac620 | Legacy body plaintext 16-byte identity write |
| `cd7a71a0-3213-11e6-8f56-0002a5d5c51b` | 054ac620 | Legacy body friendly name (ASCII) write |
| `e182ec40-3213-11e6-ab07-0002a5d5c51b` | 054ac620 | action mode write (`{0x03}`) |
| `0d6f1880-3217-11e6-a4cb-0002a5d5c51b` | 5ae57260 (full UUID not annotated in code) | Wi-Fi connection type write (`{0x01}`/`{0x02}`/`{0x03}`) |
| `18345be0-3217-11e6-b56c-0002a5d5c51b` | 5ae57260 (full UUID not annotated in code) | STA SSID confirmation, 32-byte NUL-padded ASCII |
| `18345be1-3217-11e6-b56c-0002a5d5c51b` | Not annotated in code (the comment groups it only under the 18345be* family) | Push: `value[0]=1` means the SoftAP link is in effect |
| `e182ec43-3213-11e6-ab07-0002a5d5c51b` | Not annotated in code | Push: `3`=pairing ready, `1`/`4`=request connection type |
| `e182ec41-3213-11e6-ab07-0002a5d5c51b` | Not annotated in code | Push: `1`=control mode refused, `0`=control session in effect |

`0d6f1880` and `18345be0` are not on the primary service: the indexing function recognises these two by UUID first (regardless of service) and only afterwards restricts the remaining characteristics with `serviceUuid !== SYNC_BLE_SERVICE` (`1804-1816`).

### 2.3 The ten notification characteristics

`SYNC_NOTIFY_UUIDS` holds exactly ten entries, registered in order, and registration happens before the identity write (2026-09-25 capture: the ten CCCD writes precede `writeUuid` by about 600 ms, `LumixSyncControlService.ets:184-200`):

| # | UUID | Code annotation |
| --- | --- | --- |
| 1 | `4cf487c0-32a7-11e6-a50d-0002a5d5c51b` | Not annotated in code |
| 2 | `37701b80-32a7-11e6-bb83-0002a5d5c51b` | Not annotated in code |
| 3 | `18345be1-3217-11e6-b56c-0002a5d5c51b` | SoftAP-in-effect push |
| 4 | `48669da0-3217-11e6-b08d-0002a5d5c51b` | Not annotated in code |
| 5 | `e182ec43-3213-11e6-ab07-0002a5d5c51b` | Pairing state / connection-type request |
| 6 | `da534d0a-63a3-447c-a889-aab701906af2` | Not annotated in code |
| 7 | `d611b4a0-3217-11e6-8d98-0002a5d5c51b` | Not annotated in code |
| 8 | `e182ec41-3213-11e6-ab07-0002a5d5c51b` | Control-mode result |
| 9 | `e182ec42-3213-11e6-ab07-0002a5d5c51b` | Not annotated in code (inferred to be in the same family as e182ec41/43, based on the UUID prefix alone) |
| 10 | `7be5fe6e-475b-11e7-a919-92ebcb67fe33` | Not annotated in code |

Registration uses `setCharacteristicChangeNotification(true)`, with the CCCD write managed by the platform (`1341-1377`; CCCD constant `00002902-0000-1000-8000-00805f9b34fb`). Here is one fact that runs contrary to the official behaviour: all ten official notification registrations **failed with `No_Descriptor`**, not a single CCCD write for a fresh registration succeeded, and the camera carried on regardless; HarmonyOS-managed CCCD writes are tolerated by the camera (the successful 2026-09-25 pairing carried exactly these writes). Local subscription is therefore kept, but the flow no longer gates on `pairReady`, and the value of `e182ec43` is diagnostic only (`149-152`, `328-331`).

### 2.4 Identity frame (MEI0 / o.d / o.c)

16 bytes = fixed prefix + a 12-hex-digit seed (`LumixSyncControlService.ets:1687-1727`):

- Wire form: `4D454930010010008001` + 12-digit seed = 32 characters (16 bytes); `4D 45 49 30` is ASCII `MEI0`
- Dotted form (for `cam.cgi`): `4D454930-0100-1000-8001-XXXXXXXXXXXX`, 5 segments with a 12-digit final segment, not a standard UUID shape

Seed precedence: first 12 hex digits of the OAID → stored `syncDlnaSeed` → 6 random bytes. The comment explains why a fresh random value each time will not do: once a reinstall clears preferences, every reinstall turns the phone into a new device in the camera's eyes (on 2026-09-26, pairing after a reinstall failed at the "trust Wi-Fi" moment, while the same flow succeeded every time before the reinstall); the official seed is likewise device-derived, and an injected APK re-signed and reinstalled four times still presented the same `MEI0...02C30003AF62`. The meaning of the prefix segment is not annotated in code (inferred to be a version/device-class field, on the sole basis that the official samples are constant).

There are two write branches, decided by whether the APS characteristics are complete (`dlnaUuidAps` and `friendlyNameAps` both present, `471`):

- **Legacy body**: write the 16-byte plaintext identity to `8d08a420`, then 300 ms later the ASCII friendly name `Pixelshop` to `cd7a71a0` (`493-511`)
- **APS body**: first read `INITIAL_INFORM` for the key, then write `bb5d2a8c` (identity, `uuidLayout=true`) and `7b61774f` (name, `uuidLayout=false`), again 300 ms apart

Both share `encodeApsBlock()` (`1873-1900`): the plaintext is laid out as 20 bytes `[len][data≤16][padding]`, the last three bytes are always `0xFF`, and the padding is `0xFF` in the uuidLayout branch and `0x00` in the name branch; every 4-byte group is then "reversed + XORed against the key in forward order":

```
encoded[i+0] = plain[i+3] ^ key[0]
encoded[i+1] = plain[i+2] ^ key[1]
encoded[i+2] = plain[i+1] ^ key[2]
encoded[i+3] = plain[i+0] ^ key[3]
```

### 2.5 The INITIAL_INFORM session key

`readSessionKey()` reads the whole value of `03e23a31` and takes the first 4 bytes (the comment calls them big-endian); when the value is shorter than 4 bytes or the first 4 bytes are all zero, the default key `0x9032782C` is used (bytes `90 32 78 2C`, `143-146`, `1848-1871`). The all-zero case means "the camera has not yet paired with any client"; the jadx source is quoted in the constant's comment (`N5/o.java`: `j9 = j7 == 0 ? -1875740628L : j7`, where -1875740628 is 0x9032782C). A read failure or a missing characteristic is not fatal — the default value is used directly; reads have a 5 s timeout (`stepWithTimeout`, `1269-1297`). The current implementation writes the key in plaintext to hilog, which the comment acknowledges as a temporary state awaiting redaction (`1857-1859`).

### 2.6 Wi-Fi connection-type negotiation

The meaning of the values in both directions comes from jadx `i5/g.java`:

- The camera pushes `e182ec43`: `value[0]=1|4` asks for the connection type, `value[0]=3` means pairing ready (`149-153`, `364-372`)
- The phone writes `0d6f1880`: `{0x01}` SoftAP, `{0x02}` STA, `{0x03}` request restart/switch (`154-159`, `638-651`, `731-744`, `804-808`)
- The phone writes `e182ec40` action mode: `{0x03}` (the comment corrects the earlier static-analysis guess of `{0x01}`; the capture confirms `{0x03}`, `160-164`)

The full official confirmation chain is replicated only in the optional branch behind `withControlDance=true`: write `18345be0` (32-byte NUL-padded ASCII of the currently connected SSID) → write `0d6f1880 {0x03}` → wait for the `18345be1` push → answer according to the first byte with `{0x01}` (non-zero) or `{0x02}` (zero, i.e. STA) → write `e182ec40 {0x03}` → 1.5 s later check whether `e182ec41` is `b0=1` (`710-752`). `{0x03}` makes the camera restart its SoftAP, with about 41 s of beacon interruption in the capture, after which Wi-Fi must be re-joined and `req_acc` refreshed. The default path (2026-09-26/09-27 captures) does not write `18345be0`, does not write `{0x03}` and does not wait for `18345be1`; it writes only `{0x01}` + `e182ec40 {0x03}`, which the camera accepts silently (`769-775`) — a freshly registered camera rejects that confirmation dance.

### 2.7 AP readiness and credential read

The order is copied from the official e-layer `z#35 → z#5 → z#6`: session key → SSID → password, immediately after the friendly-name write, with a 5 s timeout on each of the three steps (`513-516`, `530-553`):

- **SSID** (`e206a5c0`): read UTF-8, then split on `;` and take the first non-empty segment (`firstSsidEntry()`, `1939-1946`); this characteristic returns a list rather than a single name
- **Password** (`c97cf1a5`): each 4-byte group is "reversed + XORed against the key in reverse order", **skipping the first byte** (the declared length, which the official decoder never validates), truncated at the first `0xFF`, and the remainder is UTF-8 decoded with NULs stripped (`1902-1937`). An empty result is a legitimate value: the S5's SoftAP is open, and in the capture that "key-repeated" ciphertext decrypts to exactly the empty string, after which the official app joins without a key
- A length that is not a multiple of 4 fails outright; the log records only the length

This decoder and `encodeApsBlock` from 2.4 **are not inverse functions** (applying both to the same key does not recover the original text); they are separate replicas of two different official routines (writing via `o.d/o.c`, reading via `N5.o.a`) and must not be used as a codec pair.

## 3. Timing

### 3.1 Full pairing sequence (default path)

In the execution order of `pairAndConnect()` (`LumixSyncControlService.ets:308-903`):

1. Stop scanning, suspend discovery, pre-warm the Wi-Fi radio in parallel (`423-428`); a failed GATT connection is retried at most once, and disconnections have their own listener (`326-356`, `430-449`)
2. Poll `getServices()` up to 10 times × 2.5 s; if the table is empty and the link is still up, retry once with a brand-new client (`434-446`, `1310-1338`)
3. After registering the ten notifications, `delay(600)` (`458-460`) → identity write → 300 ms → friendly-name write → 300 ms (the APS branch performs one extra key read before the identity write)
4. Read credentials (the legacy body's key is read here) → persist SSID/password/BLE address; GATT stays connected throughout (`593-597`)
5. Wi-Fi join: direct fast path (stored credentials, 2 × 15 s) → otherwise a short window of 1 × 20 s → BLE wake-up when the AP cannot be found (up to 3 rounds, 10 s apart) → long window of 3 × 150 s (`554-685`)
6. `req_acc` commit (`pairingCommit=true`, up to 40 polls)
7. 20 s quiet period → entry writes (up to 3 rounds) → `waitCameraLinkDrop(ssid, 12000)` → re-join Wi-Fi → clear session → `req_acc` refresh (40 polls, cap of 12 consecutive empty responses, `entryRefresh=true`) → `setsetting device_name` → wait for `e182ec41 b0=0` for 3 s
8. `setsetting raw_img_send=enable` (failure is not fatal, `873-880`) → disconnect GATT → write preferences `syncCameraSsid` / `syncCameraBleDeviceId`

### 3.2 The two answers of `req_acc`

`ensureControlSession()` GETs `req_acc` repeatedly and branches on the response body (`911-1035`):

| Response | Handling |
| --- | --- |
| `ok_under_research...` (including `_no_msg`) | Record `sawUnderResearch`, resend after `delay(1000)` → usually the second call returns `ok,...` |
| `err_busy` | Up to 5 times, 1 s apart |
| `err_user_refused` (ordinary) | Up to 6 times × 2 s, prompting the user to tap "Allow" on the camera screen; once exceeded, prompting to press MENU to leave the previous control screen |
| `err_user_refused` (`entryRefresh`) | Up to 3 times × 2 s, then abandon the session refresh but **continue activation** (`989-998`) |
| `err_others_requesting` | Fail immediately |
| Other `err_` / `ret_empty` | Fail immediately, with the error code before the first comma carried in the message |
| Starting with `ok` / `upload_bt` / `transfer` | Establish the session, record `accessGrantAt`, take the fifth field as sessionId |

If the network drops immediately after `ok_under_research` (timeout or empty body) and the caller is the pairing commit, the code treats **the disconnect itself as the registration-success signal**: the camera restarts its SoftAP as soon as it has received the commit and kicks the phone off the network, and the subsequent quiet period / BLE entry / re-join / refresh rebuild the real session (`948-960`).

### 3.3 Quiet period: official 19 s / 34 s versus 2 s rejected

The same comparison appears in the header and in the entry-section comments (`41-44`, `785-790`): the two official captures paused **19 s** and **34 s** respectively between the commit and the entry writes (that is user-operation tempo, but they are the only intervals accepted in the record); VIVID on 2026-09-27 10:54 used **2 s**, and `e182ec41` returned `b0=1` just **24 ms** after the action-mode write — the camera's BLE side had not yet digested the registration just submitted. The default path therefore hardcodes `delay(20000)`, with the UI string "Preparing camera control mode (about 20 seconds)" (`791-792`). Related point: after entry the camera drops Wi-Fi a few seconds later, and reconnecting before it drops short-circuits onto a dying link within 6 ms and obtains a stale gateway (2026-09-27 19:52), so the scan waits until the link has actually disappeared (`826-838`, `LumixImportPrototype.ets:2668-2683`).

### 3.4 Write sequence for entering control mode

Default path, per round (`793-823`): re-read credentials (official `R0#35/R0#5/R0#6`) → write `0d6f1880 {0x01}` (SoftAP answer) → write `e182ec40 {0x03}` (action mode) → after `delay(1500)` check `e182ec41 b0=1` (on refusal, retry the next round 10 s later, 3 rounds in total). On success it re-joins, refreshes and finishes with `device_name` as in step 7 of 3.1, and finally waits for the `e182ec41 {0x00}` activation push that follows about 200 ms later (3 s timeout; if it never arrives only a warning is logged — the official app likewise continues without seeing the push).

### 3.5 Authorisation lifetime

`accessGrantAt` records the most recently accepted `req_acc`; `hasControlSession()` judges it expired after **50 s** and then allows a resend (`233-245`, `289-301`). Basis: the official app resends roughly every 60 s; measured on a ZS300, thumbnails worked 3 s after `req_acc`, an original-image GET was disconnected after 75 s (`http=0`), and Browse returned 403 after 95 s. On download/preview failure the code calls `refreshAccessGrant()` first (single attempt, no polling, no throw on failure) and then retries once, rather than blindly retrying the same image.

## 4. The cam.cgi command layer

### 4.1 URLs and request headers

Authorisation: `GET /cam.cgi?mode=accctrl&type=req_acc&value={dotted}&value2={name}`, where `value` is the dotted identity from 2.4 (`encodeURIComponent`) and `value2` is `Pixelshop` (`926`; the refresh version has the same shape at `1055-1056`). The HTTP layer uniformly uses `http://{host}{path}`, GET, `User-Agent: LUMIX Sync`, 5 s connect and read timeouts, and adds `X-SESSION_ID` only when sessionId is non-empty (`1994-2019`); the host has its scheme prefix and slashes stripped (`1990-1992`). Read paths additionally have the official retry `httpGetRetry`: `err_busy` up to 5 times × 1 s (`2021-2043`, corresponding to official `B5/a.F(str,5,1000)`).

### 4.2 X-SESSION_ID is the fifth CSV element

`sessionIdFromResponse()` splits on `,`, takes `parts[4]` (the fifth element) and strips CR/LF; fewer than 5 segments yields an empty string (`1984-1988`). An empty sessionId does not mean failure: a ZS300 returns only 4 fields and never sends X-SESSION_ID, its authorisation being maintained by IP (`274-280`, `1037-1047`). sessionId is used only for sending requests; callers must not log or persist it (`257-264`).

### 4.3 Table of commands actually sent

| mode | type / value | Source | Purpose |
| --- | --- | --- | --- |
| `accctrl` | `type=req_acc`, `value=<dotted>`, `value2=Pixelshop` | `LumixSyncControlService.ets:926`, `1055` | Registration commit / session renewal |
| `camcmd` | `value=playmode` | `LumixSyncImageTransfer.ets:1084`, `1157`, `1276`, `1304`, `1439`; `CameraControlPage.ets:677` etc. | Switch to playback (precondition for Browse) |
| `camcmd` | `value=recmode` | `LumixSyncImageTransfer.ets:1234`, `1547`; `CameraControlPage.ets:720` | Return to shooting mode |
| `camcmd` | `value=capture` / `capture_cancel` / `video_recstart` / `video_recstop` / `oneshot_af` | `CameraControlPage.ets:978-1014` | Shutter / recording / single autofocus |
| `camcmd` | `value=pictmode` | `LumixCameraService.ets:2254` | S5 picture-selection mode; the comment notes there is currently no caller |
| `camctrl` | `type=touch`, `value=x/y` (0-1000 normalised), `value2=on` | `LumixSyncControlService.ets:1151-1189`; `CameraControlPage.ets:2318` | Touch-to-focus |
| `setsetting` | `type=device_name`, `value=Pixelshop` | `LumixSyncControlService.ets:1085` | Registration finishing step |
| `setsetting` | `type=raw_img_send`, `value=enable` | `877`; `CameraControlPage.ets:770` | Make the camera deliver full RAW |
| `setsetting` | `type=current_sd`, `value=sd1` or `sd2` | `LumixSyncImageTransfer.ets:1642` | Switch storage card |
| `setsetting` | `type` ∈ iso, shtrspeed, focal, exposure, whitebalance, photostyle, quality, aspectratio, lightmetering, recmode | `CameraControlPage.ets:2705-2719` → `LumixSyncControlService.ets:1439` | Dial parameter write |
| `getsetting` | `type=<any of the above>` | `LumixSyncControlService.ets:1500` | Read the current value of one item (`<settingvalue type="...">`) |
| `getstate` | `type=keep_alive` | `1402`, `1474` | Heartbeat / state |
| `getinfo` | `type=curmenu` / `type=lens` | `1572`, `1598` | Menu snapshot / lens information |
| `startstream` | `value=<port>` | `1210`; `CameraControlPage.ets:687` | Plaintext UDP live view |
| `stopstream` | — | `1239` | Close live view |

Two encoding conventions must be observed: a `camcmd` verb may only go in `value=` — adding `type=` returns `<result>err_param</result>` (`1093-1101`); and `setsetting`'s `value` is **not URL-encoded** (the camera fails to parse `%2F`/`%2B`), only `type` is (`1434-1439`). Aperture `focal` is converted at the protocol boundary into an AV×256 rational (`AV = 2·log2(F)`, F3.6 → `940/256`), while native values that already carry `/` are passed through unchanged (`1421-1433`).

Extra constraints on `playmode`/`recmode`: do not switch modes within 2.5 s after `stopstream` (otherwise `err_busy` locks for a minute); an `err_reject` returned when the camera is already in the target mode is treated as already in place; only a successful switch records `lastAcceptedMode`, and a continued pull that is already in `playmode` does not resend (`1112-1140`, `210-218`). `replyVerdict()` first looks for `<result>...</result>` (camrply XML) and only falls back to the CSV segment before the first comma when that is absent (`1246-1259`) — testing `startsWith('ok')` alone would judge every XML response a failure.

## 5. Wi-Fi image transfer (DMS pull)

### 5.1 Endpoint and prerequisites

The image channel does not go through `cam.cgi` but through the body's built-in DLNA MediaServer: `http://{gateway}:60606/Server0/CDS_control`, browsing `ObjectID="0"` and downloading the `res` URL (`LumixSyncImageTransfer.ets:13-26`). Before entry there must be ① an available control session ② a successful `camcmd playmode` ③ an 800 ms settling window (`1072-1093`); a Browse only 440 ms after `playmode` is treated as a concurrent request and answered with 403 (`1392-1394`).

### 5.2 SOAP envelope

`browseEnvelope()` (`102-114`) matches the official `B5.m.a` word for word: SOAP 1.1 Envelope, `u:Browse` namespace `urn:schemas-upnp-org:service:ContentDirectory:1`, `pana` namespace `urn:schemas-panasonic-com:pana`, fixed `ObjectID=0`, `BrowseFlag=BrowseDirectChildren`, `Filter=*`, empty `SortCriteria`, `pana:X_FromCP=LumixLink2.0`. Request headers (`120-132`): `Accept-Charset: UTF-8`, `Content-Type: text/xml; charset="utf-8"`, `SOAPAction: urn:schemas-upnp-org:service:ContentDirectory:1#Browse`, `User-Agent: Panasonic MIL DLNA CP UPnP/1.0`, plus `X-SESSION_ID` when a session exists; 15 s connect, 30 s read.

### 5.3 Page size 12 and the cursor

`SYNC_DMS_PAGE_SIZE = 12` (`25`). The first page uses `StartingIndex=0`, `RequestedCount=12`, and retries once after 1.5 s on failure; continuation uses `nextStartIndex`, advanced by **the number of physical entries the camera returned** (`NumberReturned`, or the count of parsed `<item>` elements when absent), decoupled from the de-duplicated card count (`1113`, `1180`). `TotalMatches` determines `hasMore` (`cursor < total`); a fully duplicated page does not permanently disable loading but stays retryable (`1181-1196`); a failure triggers a 5 s cooldown so that scrolling cannot overwhelm the camera (`1045-1052`, `1141-1144`).

### 5.4 DIDL-Lite parsing

First unescape `&lt; &gt; &amp; &quot;` in the order of the official `C3142a.l`, then cut out `<DIDL-Lite ...>...</DIDL-Lite>` (`152-164`). For each `<item>`, take `id` and `<dc:title>`, then classify across all `<res>` entries:

- Thumbnail: `protocolInfo` matches `jpeg_tn`/`jpeg_sm`/`cam_tn`/`cam_sm`/`cam_lrgtn`; take the first only
- Video: `video/` or `cam_avc`, or extension `mov`/`mp4`/`m4v`
- JPEG original: `cam_raw_jpg`/`cam_hsp_raw_jpg` must be tested **before** `cam_raw` (Panasonic tags both files of a JPEG+RAW pair with `application/octet-stream`, and the wrong order writes JPEG bytes as `.RW2`), plus `cam_org`/`cam_hsp_jpg`, extension `jpg`/`jpeg`, `image/*`
- RAW: `cam_raw`/`cam_hsp_raw` or extension `rw2`/`rwl`/`raw`/`dng`
- Display name: `OriginalFileName` (single-quoted attribute) preferred, falling back to the last segment of `id`

The download address is the text content of `<res>` (used verbatim; usually an absolute URL self-reported by the camera), and the `size` attribute is that resource's exact byte count.

### 5.5 Download

`downloadToFile()` streams into the sandbox with `requestInStream` (`332-491`), using the same UA as Browse plus `X-SESSION_ID`. Inside `dataReceive` it calls `writeSync` directly; progress is reported through `dataReceiveProgress`, with a 250 ms throttle inside `dataReceive` as a fallback on hardware where that callback is not delivered. Completion requires both "status code received" and `dataEnd`, after which the byte count is validated: when DIDL declares a size and the received count differs, **the file is discarded** (a short body is usually just a preview image). Timeouts are 120 s (JPEG original), 180 s (video/RAW) and 15 s (thumbnail).

### 5.6 JPEG + RAW dual resources: implementation disagrees with the comments

Protocol layer: one `<item>` can carry two original-image `<res>` entries, and the type comment states that "a JPEG+RAW pair has a second RAW source that can be addressed independently" (`38-43`, `1506-1507`). Implementation layer: `parseItem()` **does not fill** `rawDownloadUrl`; instead it splits the RAW into a second card (with `::raw` appended to `imageId`, sharing the thumbnail and dimensions, `286-299`). That field is therefore read but never written anywhere in the file (`41`, `283`, `291`, `298`, `1371`, `1508`), and both the "second resource of the same item" branch of `downloadSelected()` (`1508-1528`) and the `+1` in `planFileCount()` (`1371`) are unreachable.

The actual behaviour is that JPEG and RAW become two independent cards in the grid, each downloaded from its own `res`; the selection key is `imageId:imageType` (RAW=1, JPEG=2), so the two cards with the same number are not selected together (`1341-1356`, `507-512`, `1659-1683`). The side effect is that the two no longer present themselves as "the same photo" and the pairing is invisible in the UI — this is a simplification of "one DIDL item, two resources" into "two cards", not a difference in camera behaviour.

### 5.7 Storage cards and RAW delivery

In `getstate`, `<sd_memory>`/`<sd2_memory>` set to `set` means the card is present, and `<current_sd>` being `sd1`/`sd2` determines the current card; when missing, the fallback is "use SD1 if present, otherwise SD2" (`1602-1633`). Card switching uses `setsetting current_sd=sd1` or `sd2`, after which the grid and the DIDL cache are cleared and the full start flow is re-run (`1635-1656`). `raw_img_send=enable` is sent at the end of every connection: without it DMS may deliver a reduced RW2 (the RW2 downloaded on hardware on 2026-09-28 lacked lens information), while with it the full EXIF including lens information is delivered; refilling the EXIF lens tags has been shelved (self-built IFD injection made the gallery unable to read shooting parameters), replaced by storing the raw bytes directly (`1556-1566`).

## 6. Implementation comparison table

| Stage | Official behaviour (code comment / source) | VIVID implementation | Difference and impact |
| --- | --- | --- | --- |
| Advertisement filter | Service UUID + manufacturer data 58 + name model-code gating (`LumixImportPrototype.ets:313-343`) | Service UUID and state byte are logged only; the strong signals are company 58 six bytes + model code (`2201-2284`) | Relaxed direction: would rather over-recognise than wrongly hide; may admit non-camera LUMIX devices as candidates |
| Notification registration | All ten CCCD writes fail with `No_Descriptor` and the flow continues (`LumixSyncControlService.ets:36-39`) | Platform-managed CCCD; registers 10 and checks for missing ones (`1347-1377`) | Push availability is higher than official; steps that depend on push are still treated as "may be absent" |
| Identity and name | Legacy plaintext 16 bytes + ASCII name; APS uses o.d/o.c (`18-29`) | Branch selected automatically by characteristic completeness (`471-511`) | Same; the APS branch performs one extra key read |
| Registration commit | First call `ok_under_research`, resend about 1 s later returns `ok` (`31-40`) | Resend after 1 s, and "network drop after commit" judged a success (`948-972`) | Same, and more robust to a SoftAP restart |
| Quiet period | 19 s / 34 s (`41-44`) | Hardcoded `delay(20000)` (`791-792`) | Takes the official lower bound; below that value `b0=1` is returned, above 34 s unverified |
| Entering control mode | `{0x01}` + `{0x03}`, no `{0x03}` restart (`769-775`) | Same by default; full confirmation chain behind `withControlDance` | The default path does not restart the SoftAP, saving about 40 s of interruption |
| Authorisation renewal | Resend `req_acc` roughly every 60 s (`289-292`) | Expire after 50 s + a single refresh after failure (`233-245`, `1048-1072`) | More conservative; a ZS300 that relies on IP still expires |
| Command encoding | Verb in `value=`, `setsetting` values not encoded (`1093-1101`, `1434-1439`) | Same | Same |
| DMS paging | Browse `ObjectID=0`, `X_FromCP=LumixLink2.0` (`LumixSyncImageTransfer.ets:102-114`) | Page size 12, cursor advanced by `NumberReturned` | Page size taken from a constant; whether the official client also uses 12 is not annotated in code |
| JPEG+RAW | One item with two original-image `res` (`38-43`) | Split into two cards; the second-resource branch is unreachable (`286-299`, `1508`) | Functionally equivalent, but the pairing relation is lost and there is dead code |
| Credential persistence | Official stores `CurrentConnectedSSID`/`CurrentConnectedAddress` (`882-891`) | Preferences `syncCameraSsid`/`syncCameraBleDeviceId`/`syncCameraPassword` (`1769-1782`) | See 7.4: the password is written to disk as well |

## 7. Limitations and risks

### 7.1 Model and firmware differences

- **Two characteristic sets**: only `wifiSsid` and `wifiPassword` are hard prerequisites; the pair `dlnaUuidAps`/`friendlyNameAps` and the pair `8d08a420`/`cd7a71a0` each suffice on their own, and when both are missing it reports "pairing identity characteristics not exposed" (`462-467`). When the entry characteristics `0d6f1880`/`e182ec40` are missing, entry is skipped with a warning only and registration still counts as successful (`780-784`)
- **ZS300**: `req_acc` returns only 4 fields and no X-SESSION_ID, the grant expires by time, and repeating `playmode` makes the DMS session re-enter (Browse returns 403 from page 3 onwards), so mode switching is protected for idempotence (`LumixSyncControlService.ets:210-218`, `LumixSyncImageTransfer.ets:1151-1166`)
- **S5**: the SoftAP can be open (an empty password is legitimate), and `requestS5Access` (`value2=WEB-W00`) plus the legacy `pictmode` branch coexist with the main path; the comment acknowledges that S5 passive push has been disabled
- **Sync model codes unknown**: the 1..9 code table comes from the Lab APK; outside its range only the name fallback remains, and `logAdvertisement` is left as an item awaiting device logs

### 7.2 BLE notifications and `No_Descriptor`

That all ten official notification registrations fail with `No_Descriptor` and the flow still continues is the most counter-intuitive point on this line. This implementation obtains subscriptions through HarmonyOS-managed CCCD writes (pairing succeeded on 2026-09-25), but the code is designed throughout for "push may not arrive": `pairReady` is not used as a gate, a missing activation push only produces a warning, and only the optional `withControlDance` treats `18345be1` as a hard wait (failing on the 5 s timeout). If some body requires genuine CCCD writes and the platform does not manage them, that branch is bound to fail; the default path is unaffected.

### 7.3 Timing windows

- The 20 s quiet period is hardcoded: if firmware needs longer (the official capture saw 34 s), the entry writes receive `b0=1` and the whole pairing fails after three rounds, leaving the user to start over
- GATT has a 5 s timeout per step and `getServices` 10 × 2.5 s; when the camera is asleep or just waking the windows are tight; any silent failure goes to `fail()` and dumps a trace
- On the Sync line the Wi-Fi window is widened to 150 s and "hotspot not found" switches to a direct connect to the hidden SSID, but the 30 s limit of the system's "Trust this Wi-Fi" dialog is decided by the SDK, so if the user does not tap it a timeout is inevitable (`CameraPage.ets:2222-2230` dismisses the app's own modal first for exactly this reason)
- The 50 s/60 s grant figures are values fitted to logs, with no public camera documentation behind them; only the refresh-after-failure fallback covers them

### 7.4 Password and session key written to disk / logged

`persistSyncCredentials()` writes the SSID, the BLE address and the **plaintext Wi-Fi password** into the app-private preference `syncCameraPassword` (`1769-1782`), and `storedDirectCredentials()` reads them back verbatim for direct connection (`1734-1767`). So "the password is never persisted" does not hold: it is persisted, it just is not written to hilog (`redactGattValue` returns `redacted-sensitive` for `c97cf1a5`, `LumixImportPrototype.ets:4320-4323`). There is also the temporary state in which the session key is written to hilog in plaintext (`1857-1859`).

### 7.5 Identity stability, plaintext transport and comment drift

When OAID is unavailable and preferences have been cleared (reinstall), a random seed is generated and the camera treats the phone as a new device requiring re-registration; a change in OAID itself (privacy settings, system upgrade) likewise causes "device identity drift". `cam.cgi` and DMS downloads are all `http://`, and live view is plaintext UDP (`startstream` only tells the camera the port, and the camera sends raw DatagramSocket packets to `phone:<port>`); this line has no TLS/DTLS, unlike the Lab line's HTTPS with certificate pinning (`LumixSyncControlService.ets:1191-1201`). At the documentation level there are two further inconsistencies: the header of `LumixSyncControlService.ets` still lists the models as "S5 / GH5 / GH5S / G9 / GH6 / G100D" (`:11-13`), although the routing table moved GH5/GH5S/G9 to the Image App line on 2026-10-11; and a `LumixSyncImageTransfer.ets.damaged` (67128 bytes) sits in the same directory, is not used by this report, and its relation to the other file is explained nowhere in the code.

## 8. Items to verify

1. **Advertised model code of Sync bodies**: the 1..9 code table comes from the Lab APK and there is no code evidence that Sync bodies fall inside it; on-hardware `adv ... code=` logs are needed (instrumentation already exists at `LumixImportPrototype.ets:2201-2218`)
2. **Semantics of `e182ec42`**: it belongs with `e182ec41`/`e182ec43` to the `e182ec4x` push family, the comment states no purpose, and it can only be confirmed to be in the ten-notification set (`LumixSyncControlService.ets:198`)
3. **Full UUID of the service hosting `18345be1`/`0d6f1880`**: comments and code give only the short form `5ae57260` (`154-159`, `169-176`)
4. **Meaning of the identity prefix `0100 1000 8001`**: constant across the official samples, not annotated in code, inferred to be a version/DLNA device-class field
5. **Camera-side grant TTL**: both the 50 s expiry threshold and "about 60 s" are values fitted to logs
6. **DMS page size**: fixed at 12 in the code; whether the official client also uses 12 has no capture evidence in the comments
7. **The `withControlDance` route**: off by default, enabled only when a `{0x03}` SoftAP restart is required; the 41 s beacon interruption and the `err_user_refused` boundary appeared only in the 2026-09-25/27 captures, and model coverage is unknown
