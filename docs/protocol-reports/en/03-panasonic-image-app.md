# Panasonic, Third Line: LUMIX Image App / Lumix Link Generation (No Bluetooth)

**English** | [简体中文](../03-panasonic-image-app.md)

> Translated from the Chinese original at baseline `18466be`; code identifiers, paths, UUIDs, ports and `file:line` references are kept verbatim.

- Project: Vivid (ArkTS, `C:\Users\HQ\DevEcoStudioProjects\VIVID`)
- Baseline commit: `18466be` (auto/manual white balance added to the colour grading panel)
- Method: read-only review of code and documentation; no device is run and no code is changed
- Files covered: `LumixCameraService.ets`, `LumixImportPrototype.ets`, `PanasonicS5Receiver.ets`, `LumixSyncImageTransfer.ets`, `LumixSyncControlService.ets`, `CameraWifiPasswordPolicy.ets`, `CameraSessionStore.ets`, `CameraPage.ets`
- Conventions: paths omit `entry/src/main/ets/services/` (page files live under `entry/src/main/ets/pages/...`); line numbers refer to the baseline; anything recorded only in a comment and not implemented in code is marked explicitly; anything derived from code structure but not verified on hardware is marked "inferred"

## 1. Summary of conclusions

1. This is the only one of the three Panasonic lines whose generation has no Bluetooth pairing: join credentials are supplied by the user by hand (the AP password shown on the camera screen), and no QR code or NFC implementation exists in the code (`LumixCameraService.ets:340-371` records only that the official app offers those three onboarding methods).
2. Line determination is decided entirely by the model-token tables plus a fallback regular expression and does not depend on BLE advertisements: `panasonicRouteForModel()` compares the Lab table first, then the Sync table, and finally falls through to `isPanasonicImageModel()` (`LumixCameraService.ets:1766-1831`).
3. The older generation has no camera-side reverse BLE registration, so `needsBlePairing('lumix_image')` is always false (`LumixCameraService.ets:1866-1873`); once a body on this line is put through the BLE registration flow it necessarily hangs.
4. "Discovery" on the phone side has two forms: sending SSDP M-SEARCH outward as a client (MediaServer:1), and acting as a DMS that answers M-SEARCH itself and sends NOTIFY periodically (`LumixCameraService.ets:2356-2382`, `PanasonicS5Receiver.ets:736-819`).
5. The read-only probing chain of the control plane is fixed as `getstate/keep_alive` → `getinfo/capability` → `getinfo/allmenu`, with the payload chosen by response body length; a body containing `err_*` never counts as a response (`LumixCameraService.ets:2149-2206`).
6. The image channel is SOAP Browse + DIDL-Lite parsing + `res` URL GET against the body's built-in DLNA MediaServer (`:60606/Server0/CDS_control`) (`LumixSyncImageTransfer.ets:23-26`, `:103-177`).
7. The reverse channel (camera pushes to phone) is enabled only on the imageApp line: the phone listens on `50000` (required) and `49152` (optional), completes `accctrl/req_acc` first and only then advertises its own DMS, after which the camera issues `GET /dms/ddd.xml`, `X_GetDLNAUploadProfiles`, `CreateObject` and a chunked upload (`PanasonicS5Receiver.ets:80-108`, `CameraPage.ets:6589-6724`).
8. The image page on this line runs in "passive push" mode and does not start an active DMS browse: `syncPush=true`, `syncPull=false` (`CameraSessionStore.ets:141-151`, `CameraPage.ets:2269-2279`).
9. On older bodies `accctrl` authorisation may return only 4 fields and no `X-SESSION_ID`; in that case every cam.cgi request omits that header, authorisation is maintained solely by source IP, and `req_acc` is re-sent on a window of roughly 60 seconds (`LumixSyncControlService.ets:1037-1047`, `:1994-2002`).
10. Main risks: the model table and the SSID identification table have limited coverage; the "camera control" entry in the UI is effectively unreachable on this line; permission request results are not validated; and ports and background listening are subject to system constraints.

## 2. Line placement

### 2.1 How the three lines are partitioned

The three token tables are built as "higher-priority set minus lower-priority set", which guarantees mutual exclusion (`LumixCameraService.ets:240-401`):

| Line | Table | Placement |
| --- | --- | --- |
| `lab` | `PANASONIC_LAB_MODEL_TOKENS` (`:302-303`) | LUMIX Lab generation; BLE advertisements carry a compact model code |
| `sync` | `PANASONIC_SYNC_MODEL_TOKENS` (`:336-338`) | LUMIX Sync generation; Wi-Fi credentials delivered during BLE pairing |
| `lumix_image` | `PANASONIC_IMAGE_MODEL_TOKENS` (`:372-401`) | Image App / Lumix Link 2.0 generation; no Bluetooth |

The subtraction itself rests on hardware evidence: GH5/GH5S/G9 moved from the Sync line to this line on 2026-10-11 because the official Image App support table lists these three bodies, none of the three has a Bluetooth radio, and the Sync line's entry is BLE-gated (`LumixCameraService.ets:326-335`). ZS300/TZ300 is the only model deliberately taken out: one body, two regional names, claimed by the Sync line's `isWifiOnlyModel()` (`:361-363`). The official support table for the G97/GH3 predates these two bodies, but both the Lab and the Sync sources yield zero hits, so they stay on this line as the sole archive (`:365-366`).

### 2.2 Why this line has no BLE

The original conclusion at `LumixCameraService.ets:340-371` (key points quoted):

- "Image App 1.9.0 (Lumix Link 2.0) contains no Bluetooth code at all — zero hits for BluetoothAdapter/BluetoothGatt/BLE across the Java sources, smali, resources, the manifest and every native library."
- "That generation provisions Wi-Fi by hand (an unfiltered AP list the user picks from), by QR code (MDL/SSID/PW/CRYPT/DeviceID) or by NFC, discovers the body over SSDP and then speaks cam.cgi plus DLNA."
- "Neither LUMIX Lab nor LUMIX Sync mentions any of these tokens".
- Contention check (2026-10-11): the decompiled Lab sources contain zero literals from this table; the entire Sync source mentions only DC-GH5/DC-GH5S/DC-G9, and all of those are UI/menu value special cases inherited from the pre-Sync codebase rather than a support table (`:352-359`).

The conclusion lands in code: `needsBlePairing(route)` returns true only for `lab`/`sync` (`:1866-1873`), and callers use that to keep this line outside BLE pairing and GATT registration.

### 2.3 Predicate and fallback

- Generic LUMIX cards of unknown identity are not guessed: when `compactIdentity` is `LUMIX`/`PANASONIC`/`PANA` it returns `''` (`:1769-1772`).
- Any identity string that contains a Lab token resolves to `lab`; a bare S5 always resolves to `sync` (`:1787-1792`).
- Any Panasonic body observed over BLE that is not in the Lab table resolves to `sync` (`:1793-1797`).
- This line is the final fallback: the token tables are compared first, then any Panasonic-shaped string (`/^(?:DC|DMC|LUMIX|PANASONIC|PANA)[-_ ]?[A-Z0-9]+$/`) is accepted (`:1809-1831`). This means a Panasonic body missing from the model table also lands on this line instead of being reported as unknown.
- The two cam.cgi lines share one protocol; UI decisions uniformly go through `isCamCgiRoute()` (`:1854-1864`), and `isSyncRouteSelected()` / `isImageAppSelected()` are used where they must be told apart (`CameraSessionStore.ets:101-143`).

### 2.4 Three-line comparison

| Dimension | `lab` | `sync` | `lumix_image` (this report) |
| --- | --- | --- | --- |
| Source of join credentials | Delivered after BLE GATT registration | Delivered after BLE pairing | Typed in by the user (shown on the camera screen) |
| Bluetooth leg | Yes | Yes | No |
| Discovery | Camera AP + Lab REST | Camera AP + cam.cgi | SSDP + cam.cgi + DLNA |
| Control plane | Lab REST | cam.cgi | cam.cgi (entry effectively closed) |
| Image plane | Lab gallery REST | DLNA/DMS active pull | Mainly camera reverse push |
| Routing evidence | `LumixCameraService.ets:302-303` | `:336-338` | `:372-401` |
| Predicate | `needsBlePairing` true | `needsBlePairing` true | `needsBlePairing` false (`:1871-1873`) |

## 3. Onboarding methods

### 3.1 Manual AP selection

Only this path is actually implemented (`CameraPage.ets:6555-6574` → `:4350-4434`):

1. Opening the page requests Wi-Fi/location permissions and ensures the radio is on (`CameraPage.ets:4246-4260`, `LumixCameraService.ets:1883-1887`).
2. `scanForCameras()` calls `startScan()` first (falling back to `scan()` on older SDKs), waits 900 ms, then reads `getScanInfoList()` (falling back to `getScanResults()`), runs each entry through `identifyWifiSsid()`, and sorts by RSSI descending (`LumixCameraService.ets:1889-1942`).
3. If the SSID the phone is already associated with is the selected camera, that hotspot is reused directly and no scan is issued (`CameraPage.ets:4367-4399`).
4. When nothing matches automatically, a candidate list is shown for the user to choose from (`:4428-4430`), and confirmation enters `connectCameraWifi()` (`:4530-4676`).
5. Join method: existing system configurations are checked first; a reusable `netId` is reused; otherwise the old record for the same SSID is deleted, followed by `addCandidateConfig()` and `connectToCandidateConfig()` (with `withUserAction` and a 30-second timeout on SDK ≥ 26; `connectToCandidateConfigWithUserAction` on SDK 20–25) (`LumixCameraService.ets:1986-2046`).
6. Success is not judged by "the trust dialog has closed" but by polling `getLinkedInfo()` 30 times at 500 ms intervals with an exact SSID match (`:2047-2056`, `:2079-2085`). Failures are capped at two attempts — one reuse of a stored key plus one explicit entry (`:1996-2072`).

Failure semantics (each has its own Chinese message so that the user can self-diagnose):

- `2501005`: the system trust confirmation timed out (`:2063`).
- `2501006`: the user cancelled on the system dialog (`:2064`).
- Reuse of the saved key failed and entry is permitted: clear the password, set "the saved connection did not succeed, check the Wi-Fi password currently shown on the camera", and ask for re-entry (`:2065-2069`).
- Failure on an unprotected network: prompt to confirm that the hotspot is still on and that system trust confirmation was completed (`:2070-2071`).
- Any exception (permissions, system refusal): uniformly return "cannot switch to the camera Wi-Fi" (`:2074-2076`); diagnose in this case with the `security`/`reused`/`attempt` fields in the `VIVID_WIFI` log (`:2031-2033`).

### 3.2 SSID shape and default gateway

- Camera AP names take the form "model token + `-`/`_` + instance suffix": `matchesPanasonicName()` uses `^<token>[-_][A-Z0-9]{3,}(?:[-_][A-Z0-9]+)*$`, and when a vendor prefix is present the prefixes `LUMIX|PANASONIC|PANA|DC|DMC|CAMERA` are allowed (`LumixCameraService.ets:522-530`). ZS300/TZ300 additionally has the anchored form `^(?:ZS|TZ)300-[A-Z0-9]{6}$` (`:498-507`). SSIDs are case-sensitive; inner spaces and the complete suffix are preserved and only surrounding quotes are stripped (`CameraWifiPasswordPolicy.ets:31-36`).
- The host address is never hard-coded; it is always taken from the DHCP gateway: `wifiManager.getIpInfo().gateway` split into dotted decimal in network byte order (`LumixCameraService.ets:1954-1968`). The camera AP is the default route, so the gateway is the camera's HTTP endpoint. When the gateway is empty every entry point fails outright rather than falling back to a guessed address (`:2215-2218`, `:2283-2286`, `CameraPage.ets:6612`).
- `LumixImportPrototype.selectHost()` follows the same principle: gateway first, `hostOverride` only as an explicit override (`LumixImportPrototype.ets:4223-4237`).

### 3.3 Password policy

`CameraWifiPasswordPolicy` (`CameraWifiPasswordPolicy.ets:1-37`) handles personal hotspots only; enterprise/certificate networks direct the user to system settings:

- Supported types: `OPEN=1`, WEP=2, WPA/WPA2=3, WPA3=4, OWE=7; anything else is rejected with a Chinese message (`:8-14`).
- Types requiring a password: everything other than 1 and 7 (`:3-6`).
- WEP: 5 or 13 printable ASCII characters, or 10/26 hexadecimal digits (`:18-23`).
- WPA/WPA2: at least 8 characters; at most 63 characters, with a 64-digit hexadecimal PSK allowed (`:24-27`).
- Newlines and control characters are rejected (`:17`).
- Passwords shown on the screen of older-generation cameras are read in by the user: the `requestPassword` callback opens an input dialog, and on invalid input the validation text is echoed back and re-entry requested (`LumixCameraService.ets:2002-2009`, `CameraPage.ets:4468-4479`).

### 3.4 QR code and NFC

The code contains neither QR code scanning nor any NFC read/write implementation: searching the whole project for `MDL`/`CRYPT`/`nfc` hits only the single comment line at `LumixCameraService.ets:347`. In other words, the field group `MDL/SSID/PW/CRYPT/DeviceID` exists only as documentary evidence that the official Image App supports QR onboarding; the Vivid side implements neither the corresponding parsing nor NFC touch onboarding.

Conclusion: the only onboarding path currently available on this line is the manual AP list of 3.1 (or reuse of the camera hotspot already saved by the system). If QR code/NFC are to be delivered, they are capabilities still to be developed, not an existing implementation.

## 4. Device discovery (SSDP / DMP)

### 4.1 Phone sends M-SEARCH to the camera (DMP probe)

The actual packet sent by `sendS5DmpSearch()` (`LumixCameraService.ets:2356-2382`):

```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 2
ST: urn:schemas-upnp-org:device:MediaServer:1
```

- The local bind is `0.0.0.0:0` (random source port, family=1), and the packet is sent to `239.255.255.250:1900` (`:2362`, `:2368-2371`).
- A reply is not the criterion: cameras do reply in the official captures, but some firmware does not answer on an already-connected datagram socket while still completing the state transition, so the socket is closed after only 350 ms and only `reply=0/1` is recorded (`:2297-2302`, `:2372-2376`).
- A key counter-example is recorded in the code: sending this packet directly to `60606` leaves S5 firmware stuck on the "Wi-Fi connected" page, so it must go to the standard SSDP multicast address (`:2363-2367`).

### 4.2 Camera-side DMP descriptor

`requestS5DmpBrowse()` (`:2281-2312`) performs "read descriptor → M-SEARCH → read descriptor again" in the official order:

- Port order `60606` (native capture) → `49320` (older-firmware compatibility) (`:2287-2292`).
- The descriptor URL is `http://<gateway>:<port>/Lumix/Server0/ddd`, with `User-Agent: Panasonic Android/1 DM-CP` and an explicit `Host` header, 3 s connect / 5 s read (`:2314-2329`).
- Verdict: true if either of the two reads returns 2xx with a non-empty body (`:2305-2306`), and a failure of this step does not block the subsequent authorisation (`:2277-2279`, `CameraPage.ets:6617-6620`).
- Browse must not be sent here: in the captures Browse belongs to operations after the handshake, and sending it early makes the S5 return 500 and blocks `req_acc` (`:2273-2279`).
- After authorisation succeeds, M-SEARCH is re-sent three more times at 2 s / 3 s / 5 s to give the camera several more chances to run its state machine (`:2338-2354`).

### 4.3 Discovery responses with the phone acting as a DMS

`PanasonicS5Receiver.startSsdp()` (`PanasonicS5Receiver.ets:736-763`):

- It first tries to bind `1900`; if that is occupied it falls back to an ephemeral port and keeps only the ability to send (`:743-750`).
- Once ready it immediately sends `ssdp:alive` and re-sends every 1500 ms thereafter; `stop()` sends `ssdp:byebye` before closing the socket (`:753-756`, `:195-202`).
- NOTIFY target set: `uuid:<clientUuid>`, `urn:schemas-upnp-org:device:MediaServer:1`, `upnp:rootdevice`, `urn:schemas-upnp-org:service:ContentDirectory:1`, `urn:schemas-upnp-org:service:ConnectionManager:1`; alive packets carry `CACHE-CONTROL: max-age=1800`, `LOCATION: http://<localIp>:<controlPort>/dms/ddd.xml`, `SERVER: Android/1 UPnP/1.0 Panasonic-DM-SV/1`; byebye packets deliberately carry no LOCATION and no cache headers (`:765-799`). When multicast fails the same packet is unicast to the camera gateway instead (`:775-776`, `:791-796`).
- Matching rules for answering M-SEARCH (`:801-819`): `ST` must equal `ssdp:all`, `upnp:rootdevice` or `uuid:<clientUuid>`, or start with `urn:schemas-upnp-org:device:mediaserver:`, `...:service:contentdirectory:` or `...:service:connectionmanager:`; everything else is not answered. Replies include `EXT`, `BOOTID.UPNP.ORG: 1` and `CONFIGID.UPNP.ORG: 1` (`:812-814`).

### 4.4 Paths exposed by the local DMS

`xmlForPath()` decides what is returned for camera GET/HEAD (`PanasonicS5Receiver.ets:869-883`):

| Request path contains | Returned |
| --- | --- |
| `/`, `description`, `rootdesc`, `desc.xml`, `/ddd.xml` | Device description (MediaServer, with the two services ContentDirectory and ConnectionManager) |
| `/sdd_1.xml`, `/sdd_2.xml`, `connectionmanager` | ConnectionManager SCPD (`GetProtocolInfo` and two more) |
| `contentdir`, `contentdirectory`, `cds`, `scpd`, `/sdd_0.xml` | ContentDirectory SCPD (including `X_GetDLNAUploadProfiles`, `CreateObject`, `Browse`) |
| anything else | 404 (`:371-373`) |

Three supplementary points:

- On a GET/HEAD hit a DMS-specific response is used (with `CONTENT-LANGUAGE: ja` and `CONNECTION: close`); a miss returns a plain-text 404 (`:367-374`, `:836-846`).
- `POST` is not path-checked: every POST enters the same SOAP action dispatch (keyed on the action name in `SOAPAction`) (`:382-392`, `:438-476`). `/dms/control_1` and `/dms/control_0` are therefore synonymous in this implementation (inferred: the official client sends SOAP only on `control_0`, so no per-path dispatch was added).
- `SUBSCRIBE` returns `SID: uuid:<clientUuid>` + `TIMEOUT: Second-1800`, and `UNSUBSCRIBE` returns an empty 200 (`:377-381`, `:860-867`). When the first 8 bytes are not a known HTTP method the stream is written to disk raw, so that the proprietary framing of individual firmware is not lost (`:270-279`).

## 5. cam.cgi control plane

### 5.1 Read-only probing chain

`probe(host)` (`LumixCameraService.ets:2136-2206`) issues GETs in a fixed order:

| Order | endpoint | Purpose |
| --- | --- | --- |
| 1 | `/cam.cgi?mode=getstate&type=keep_alive` | liveness |
| 2 | `/cam.cgi?mode=getinfo&type=capability` | capability table |
| 3 | `/cam.cgi?mode=getinfo&type=allmenu` | menu snapshot |

- Only 2xx is accepted; a body containing `err_` neither counts as "a response" nor participates in model parsing, so that error XML is not mistaken for a payload (`:2161-2170`).
- The payload is the **longest** of the three response bodies (`:2168-2170`); the model is taken from `<model>/<name>/<product>/<serial>` in that order, finally falling back to the `DC-[A-Za-z0-9]+` regular expression (`:2409-2417`).
- Model lookup `lookupModel()` tries an exact match first, then "key contained in value", and finally the reverse match "value contained in key with length ≥ 3" (`:2419-2442`).
- No response from any endpoint → the Chinese message "camera not found, please connect to the Wi-Fi created by the camera first" (`:2173-2182`); a response arrives but the model is not listed → connected is still returned, with the family marked "model not listed" (`:2198-2205`).
- The code explicitly records that `getinfo&type=model` is not probed: the official client never passes a variable type, and protocol error bodies would also be taken as responses (`:2149-2154`).

### 5.2 Common command table

All of the following are GETs, and parameters always go through `value=` (putting the `mode=camcmd` verb into `type=` yields `err_param`, `LumixSyncControlService.ets:1094-1101`):

| Purpose | Request | Source |
| --- | --- | --- |
| Access authorisation (registration submit) | `/cam.cgi?mode=accctrl&type=req_acc&value=<uuid>&value2=<name>` | `LumixSyncControlService.ets:926`, `LumixCameraService.ets:2224` |
| Switch to playback (before browsing the gallery) | `/cam.cgi?mode=camcmd&value=playmode` | `LumixSyncImageTransfer.ets:1084` |
| Hand back remote-control rights | `/cam.cgi?mode=camcmd&value=recmode` | `LumixSyncImageTransfer.ets:1231-1236` |
| Gallery/push mode | `/cam.cgi?mode=camcmd&value=pictmode` | `LumixCameraService.ets:2237-2269` (currently no caller) |
| Touch-AF and similar control | `/cam.cgi?mode=camctrl&type=<type>&value=<value>[&value2=]` | `LumixSyncControlService.ets:1151-1189` |
| Write a single setting | `/cam.cgi?mode=setsetting&type=<type>&value=<value>` | `LumixSyncControlService.ets:1406-1439` |
| Read a single setting | `/cam.cgi?mode=getsetting&type=<type>` | `LumixSyncControlService.ets:1488-1500` |
| Current menu | `/cam.cgi?mode=getinfo&type=curmenu` | `LumixSyncControlService.ets:1559-1572` |
| Lens information | `/cam.cgi?mode=getinfo&type=lens` | `LumixSyncControlService.ets:1586-1598` |
| Start live-view streaming | `/cam.cgi?mode=startstream&value=<port>` | `LumixSyncControlService.ets:1191-1210` |
| Card slot switch | `/cam.cgi?mode=setsetting&type=current_sd&value=sd1` (or `sd2`) | `LumixSyncImageTransfer.ets:1635-1642` |
| Device name | `/cam.cgi?mode=setsetting&type=device_name&value=<name>` | `LumixSyncControlService.ets:1085` |

Responses take two shapes: a `camrply` XML wrapping `<result>ok</result>`, or the plain CSV `ok,...` of accctrl. `replyVerdict()` takes `<result>` when present and otherwise the segment before the first comma, so that an XML header is not misjudged as a failure (`LumixSyncControlService.ets:1246-1259`). `err_busy` is retried at most 5 times at 1 s intervals; `err_reject` on `playmode`/`recmode` is treated as a benign "already in place" rejection (`:1121-1141`).

The `value` of `setsetting` must be spliced into the URL verbatim and must not be `encodeURIComponent`-ed: once `-02/3` is encoded the camera returns `err_param`; shutter values such as `1/400` return `ok` from the camera without taking effect; only `type` is encoded (`LumixSyncControlService.ets:1434-1439`). The wire value of `focal` is the rational `AV×256`, not `F×256` (`:1421-1433`).

### 5.3 Authentication

- The `value` of `req_acc` is the client's own DLNA identity (dotted UUID form) and `value2` is the DMS friendly name. The S5 path fixes `value2` to the observed `WEB-W00` and notes in the log that it is "not the camera SSID or password" (`LumixCameraService.ets:2219-2225`).
- The older S5 path only checks for 2xx and the absence of `err_reject|err_busy|err_unsuitable_app` (`:2228-2234`); the Sync path polls until an `ok`/`upload_bt`/`transfer` prefix appears, where `ok_under_research` means the camera is still confirming and the request is re-sent after 1 s, and records the 5th CSV field as `X-SESSION_ID` (`LumixSyncControlService.ets:936-1035`, `:1984-1988`).
- Behaviour with no `X-SESSION_ID` (key point): the header is added only when sessionId is non-empty (`LumixSyncControlService.ets:1997-2002`), and the same applies to DMS Browse and downloads (`LumixSyncImageTransfer.ets:130-131`, `:387-388`). On bodies such as the ZS300, `req_acc` returns only 4 fields and no session number, so authorisation is maintained by source IP and expires with time: measured on hardware, 3 seconds after req_acc thumbnails work normally, after 75 seconds an original-image GET is disconnected (http=0), and after 95 seconds Browse drops to 403; therefore after a download or preview failure the first move is to re-send `req_acc` once and then retry, rather than blindly retrying under the same authorisation (`LumixSyncControlService.ets:1037-1047`, `LumixSyncImageTransfer.ets:1488-1496`).
- Session freshness has an explicit window (about 60 s) and no request is issued inside that window; the cache marker must carry an expiry, otherwise `ensureControlSession` short-circuits and not a single `req_acc` is ever sent (`LumixSyncControlService.ets:233-241`, `:274-291`).

### 5.4 req_acc response semantics

The polling implementation maps each prefix to a different follow-up action (`LumixSyncControlService.ets:936-1034`):

| Response | Handling |
| --- | --- |
| `ok_under_research` | the camera is still confirming, re-send after 1 s; in the registration-submit scenario, if the network then drops it counts as a successful submit (`:968-972`, `:957-959`) |
| `err_busy` | retry at most 5 times at 1 s each, then report "camera busy" (`:973-980`) |
| `err_user_refused` | the confirmation dialog on the camera screen was not approved; by default 6 retries with a prompt for the user to operate the camera; in the post-control-mode refresh scenario, 3 retries then continue as "already in control mode" (`:981-1015`) |
| `err_others_requesting` | another device is requesting; fail directly (`:1016-1018`) |
| other `err_*` / `ret_empty` | fail directly and return the first segment to the user (`:1019-1021`) |
| `ok` / `upload_bt` / `transfer` | success; the 5th CSV field is taken as the session number and the authorisation timestamp is recorded (`:1022-1029`) |

A single renewal (no polling, no throwing) is used for retries after download/preview failures (`:1037-1047`, `:1048-1070`).

## 6. Image transfer

### 6.1 DLNA/DMS active browse (shared by Sync and Image App)

- Endpoint: `http://<gateway>:60606/Server0/CDS_control`, page size 12 (`LumixSyncImageTransfer.ets:23-25`).
- Request: POST + `Content-Type: text/xml; charset="utf-8"` + `SOAPAction: urn:schemas-upnp-org:service:ContentDirectory:1#Browse` + `User-Agent: Panasonic MIL DLNA CP UPnP/1.0`, with `X-SESSION_ID` attached when a session exists (`:120-132`).
- SOAP body: `Browse` / `BrowseDirectChildren` / `ObjectID=0` / `Filter=*` / `StartingIndex` / `RequestedCount` / empty `SortCriteria` / `pana:X_FromCP=LumixLink2.0` (`:103-114`).
- The unescape order copies the official parser: `&lt;` → `&gt;` → `&amp;` → `&quot;` (`:152-157`).
- The paging cursor advances by `NumberReturned`, decoupled from the number of deduplicated entries; `TotalMatches` decides `hasMore` (`:158-170`, `:1113-1118`).
- Initial flow: confirm the accctrl session → verify the SD card is present → `playmode` → wait 800 ms → Browse(0,12), retrying once after 1500 ms on failure (`:1062-1101`).
- Continuation flow: `ensureAccessGrantFresh` first, then re-issue the mode switch only if not currently in `playmode` (repeating it re-enters the DMS session), wait 300 ms after switching, and back off 5 s after a failure (`:1150-1174`).

### 6.2 DIDL-Lite parsing rules

A single `<item>` may contain several `<res>` entries, classified by `protocolInfo` and file extension (`LumixSyncImageTransfer.ets:203-301`):

- Thumbnails: `jpeg_tn` / `jpeg_sm` / `cam_tn` / `cam_sm` / `cam_lrgtn` (`:232-234`).
- Video: `video/`, `cam_avc`, or a mov/mp4/m4v extension (`:235-236`).
- RAW: `cam_raw` / `cam_hsp_raw`, or rw2/rwl/raw/dng; `cam_raw_jpg` / `cam_hsp_raw_jpg` must be tested first, otherwise a JPG is written as `.RW2` (`:237-244`).
- JPEG original: `cam_org` / `cam_hsp_jpg` / `image/*` / jpg/jpeg (`:245-247`).
- The display name comes from `OriginalFileName='...'`, falling back to `dc:title` and then to the last segment of the item id; the `size` attribute is kept as the expected byte count of the original image (`:229-230`, `:269-276`).
- Paired JPG+RAW is split into two independent resources, the RAW id gets a `::raw` suffix, and it counts as a separate download (`:286-299`, `:1506-1519`).

### 6.3 Download and verification

- Streaming GET (`requestInStream` + `dataReceive` to disk) into the sandbox, with the same UA and session headers as Browse (`LumixSyncImageTransfer.ets:337-429`).
- Progress: `dataReceiveProgress` does not call back on some hardware, so progress is self-reported every 250 ms inside `dataReceive`, with the DIDL-declared size used as the total fallback (`:402-409`).
- Integrity: if `received !== expectedBytes` the partial file is deleted and an empty string returned — DIDL declares the exact original-image length, and a short response is usually a preview image that must not be saved as the original (`:452-461`).
- The failure site must retain the `BusinessError` code/message, otherwise the log holds only `http=0 bytes=0` and cannot distinguish expired authorisation, an unreachable host and a timeout (`:432-446`).
- Thumbnails are downloaded one at a time (15 s timeout), leaving an empty placeholder on failure (`:1659-1683`).
- Batch download requests `ohos.permission.WRITE_IMAGEVIDEO` first and aborts if it is not granted (`:1427-1435`).

### 6.4 Paging, deduplication and "all-duplicate pages"

- After a first-screen failure it waits 1500 ms and retries once, covering the window in which `playmode` has just been switched and the DMS is not up yet (`LumixSyncImageTransfer.ets:1095-1101`).
- The cursor advances by the camera's `NumberReturned` (`nextStartIndex = startIndex + sourceCount`), decoupled from the deduplicated card count, otherwise splitting JPG+RAW into separate cards would make paging advance only half as far (`:1180`).
- Items are deduplicated by `imageId`; when a page consists entirely of already-seen items but the cursor has still not reached `TotalMatches`, the "retryable" state is kept and continuation is not permanently disabled (`:1175-1196`; the comment records an on-hardware observation of `start=36` on 2026-09-27).
- After any page failure a 5 s cooldown applies before it can be triggered again, so that scrolling cannot wedge the camera (`:1045-1052`, `:1141-1144`, `:1170-1174`).

### 6.5 Storage card

- At session start `current_sd` / `sd_memory` / `sd2_memory` are read from `getstate`: `set` means present; a `current_sd` of `sd1`/`sd2` is adopted, otherwise when there is no SD1 but SD2 is present it falls back to SD2, and otherwise defaults to SD1 (`LumixSyncImageTransfer.ets:1602-1633`).
- Switching cards uses `setsetting current_sd=sd1|sd2`, after which the grid, `TotalMatches` and the DIDL cache are cleared and the initial flow is run again in full (`:1635-1656`).
- Passive push mode does not show a slot selector: which card the push uses is decided on the camera side (`ImageTransferPage.ets:377-384`).

### 6.6 Camera reverse push (phone as HTTP/SOAP server)

The naming follows S5, but it is bound to the imageApp line (`PanasonicS5Receiver.ets:80-91`, `CameraPage.ets:4661-4667`). Order: `req_acc` must succeed first, and only then is the local DMS advertised; advertising the DMS early leaves the camera on the "LUMIX Sync" waiting page (`CameraPage.ets:6600-6612`).

- Ports: `50000` (upload/DMS, required) and `49152` (control/discovery, optional; if it fails to bind, the control port falls back to 50000) (`PanasonicS5Receiver.ets:110`, `:156-185`). An error is thrown only when both ports fail (`:182-185`).
- Local IP: `wifiManager.getIpInfo().ipAddress` converted to dotted decimal in network byte order; when it cannot be obtained, `importUri` falls back to `127.0.0.1` and no NOTIFY is sent (`:972-986`, `:424-429`, `:765-766`).
- DMS description: `friendlyName=WEB-W00`, `modelName=LUMIX_UP_SERVER_SMP`, `UDN=uuid:<clientUuid>`, `X_DLNADOC=DMS-1.50`, `X_DLNACAP=audio-upload,image-upload,av-upload`; ContentDirectory has `controlURL=/dms/control_0` and `SCPDURL=/dms/sdd_0.xml` (`:869-926`).
- Client identity: `LumixImportPrototype.persistentS5DmsUuid()` generates and persists `4D454930-0100-1000-8001-<12 hex digits>` (a 6-byte random suffix) under the key `s5DmsUuid` (`LumixImportPrototype.ets:1984-2003`). That UUID is constructed by this project itself; no official value was copied.
- SOAP: `X_GetDLNAUploadProfiles` returns a fixed profile list (JPEG_SM/JPEG_MED/JPEG_LRG/CAM_RAW plus 6 AVC_MP4 entries, whose order must not be changed) (`PanasonicS5Receiver.ets:441-452`); `CreateObject` first registers an in-memory `PendingCreateEntry` (real file name taken from the DIDL `dc:title`, expected byte count from `res size`, RAW decided by `protocolInfo`), then replies with `CreateObjectResponse` + DIDL-Lite (`objectId` of `1-media-i`/`2-media-i`, `parentID="i"`, `upnp:class=object.item.imageItem`) (`:397-468`). Other actions receive an empty response envelope (`:469-472`).
- Upload detection: a `POST` that is not a control request and is either chunked, or has a path starting with `/MEDIA`, or carries a legacy filename header, counts as an upload (`:346-352`).
- Upload state machine: mode 0 = chunked (`<hex>\r\n` + data + `\r\n`, with one further `\r\n` consumed after the terminating chunk), 1 = Content-Length, 2 = raw stream (when the first 8 bytes are not an HTTP method the stream is written to disk raw) (`:551-637`, `:270-279`). With `Expect: 100-continue` it first returns `HTTP/1.1 100 Continue` (`:533-534`, `:849-852`); after the upload is fully received it returns `HTTP/1.1 200 OK` + `Content-Length: 0` (`:855-858`).
- RAW detection: both JPG and RW2 declare `image/jpeg`; the RAW marker lives only in `contentfeatures.dlna.org` as `PANASONIC.COM_PN=CAM_RAW` (`:479-486`); the file name is matched against the pending table by `importUri` path first, then by extension taking the first entry, with 60 s expiry cleanup (`:488-518`).
- Persistence and completion: files are written to `filesDir/s5_receive_<ts>_<n>_<name>`; if the declared size and the actual size differ the file is deleted and "received length incomplete" is reported (`:666-716`).
- DMS response headers deliberately keep the Panasonic shape: `CONTENT-LANGUAGE: ja` (descriptor), `EXT:` (ContentDirectory actions), `SERVER: Android/1 UPnP/1.0 Panasonic-DM-SV/1`, `CONNECTION: close` (`:830-846`).
- The entry point does not append `camcmd/pictmode`: that request is absent from the captures and the S5 answers it with `err_param`, which leaves the camera on the "Start Lumix Sync" page (`CameraPage.ets:6678-6683`). `requestS5PictureMode()` therefore currently has no caller (`LumixCameraService.ets:2249-2253`).

## 7. Implementation cross-reference

| Capability | Code location | Status |
| --- | --- | --- |
| Three-line partition and token tables | `LumixCameraService.ets:240-401` | implemented; mutual exclusion guaranteed by subtraction |
| No-BLE determination | `LumixCameraService.ets:1866-1873` | implemented |
| Manual AP list | `CameraPage.ets:4350-4434`, `LumixCameraService.ets:1889-1942` | implemented (recognises only tokens in the table) |
| Manual password entry and validation | `CameraWifiPasswordPolicy.ets:1-37` | implemented |
| QR code (MDL/SSID/PW/CRYPT/DeviceID) | comment only, `LumixCameraService.ets:347` | not implemented |
| NFC onboarding | comment only, `LumixCameraService.ets:347` | not implemented |
| SSDP M-SEARCH client | `LumixCameraService.ets:2356-2382` | implemented |
| DMP descriptor `/Lumix/Server0/ddd` | `LumixCameraService.ets:2314-2335` | implemented (60606 → 49320) |
| cam.cgi read-only probing | `LumixCameraService.ets:2136-2206` | implemented |
| accctrl/req_acc | `LumixCameraService.ets:2213-2235`, `LumixSyncControlService.ets:905-1035` | implemented |
| cam.cgi control page | `LumixSyncControlService.ets:1094-1213` | implemented, but the entry on this line is blocked by an early return (see 8.2) |
| DLNA/DMS Browse + DIDL | `LumixSyncImageTransfer.ets:103-301` | implemented |
| Original/RAW/video download | `LumixSyncImageTransfer.ets:1414-1519` | implemented (no RAW preview) |
| Local DMS advertisement | `PanasonicS5Receiver.ets:736-819` | implemented |
| CreateObject / upload state machine | `PanasonicS5Receiver.ets:397-716` | implemented |
| Camera passive-push UI | `CameraSessionStore.ets:141-151`, `ImageTransferPage.ets:321-347` | implemented (no SD selector) |

## 8. Limitations and risks

### 8.1 Inconsistent API subsets on older models

- Each body implements a different subset of endpoints, so the handshake walks every known endpoint and picks the payload from the longest response (`LumixCameraService.ets:403-411`, `:2149-2171`); for unlisted models the only conclusion available is the fallback "model not listed / supports RAW = true" (`:2198-2205`), which makes both the family and the RAW capability untrustworthy.
- `MODEL_REGISTRY` covers only part of S/GH/G/GX/FZ/LX/TZ (`LumixCameraService.ets:240-291`): TZ95, TZ90, GX8, GF8, G6 and LF1, for example, are present only in the Image App token table, and in neither the registry nor the SSID identification table (`:2095-2124`). The APs of those bodies are never recognised from scan results (`identifyWifiSsid()` returning null means the entry is dropped, `:1923-1927`), and they can only be reached via a hotspot already saved by the system or a card already remembered on the camera (inferred: with no other clue the only practical path is to connect to the camera hotspot in system settings first).
- The semantics of states and capabilities differ between bodies: `err_reject` is benign for a mode switch but a failure for other commands; `err_busy` can mean a lock lasting up to a minute (`LumixSyncControlService.ets:206-214`, `:1126-1141`).

### 8.2 Read-only probing only, and entry reachability

- The probing chain itself writes no settings and does not fire the shutter (`LumixCameraService.ets:834-840`); this is a design constraint, not a temporary state.
- `openCameraControl()` performs a bare `return` for this line right at the start (`CameraPage.ets:1631-1636`), so the `imageAppSelected()` branch that appears later (`:1643-1656`) can never execute — that is, the cam.cgi control page entry on this line is effectively unreachable and only image transfer is available. That branch is dead code (inferred: consistent with `cameraControlActionReady()` at `:1610-1614` returning false for this line, which shows the entry was deliberately closed but the leftover branch was not deleted).
- The image transfer page is in passive mode for this line (`syncPush=true`, `syncPull=false`, `CameraSessionStore.ets:141-151`, `CameraPage.ets:2269-2279`); within the page, `startImageTransfer` only brings Wi-Fi up again for the cam.cgi family (`CameraPage.ets:3908-3918`) and does not issue a DMS Browse. Consequently, unless the camera pushes actively, no gallery entries appear on this line (inferred: consistent with the empty-state copy at `ImageTransferPage.ets:335-342`).

### 8.3 Permissions

- Declared: `INTERNET`, `GET_NETWORK_INFO`, `WRITE_IMAGEVIDEO`, `GET_WIFI_INFO`, `SET_WIFI_INFO`, `LOCATION`, `APPROXIMATELY_LOCATION` (`entry/src/main/module.json5:23-86`).
- At runtime `GET_WIFI_INFO`/`SET_WIFI_INFO`/`LOCATION`/`APPROXIMATELY_LOCATION` are requested, but `requestWifiPermissions()` ignores `authResults` and always returns true (`CameraPage.ets:4246-4260`) — when permission is denied the flow continues into scanning and manifests as "camera not found" rather than an explicit message (inferred: both scanning and association fail for lack of permission, leaving only an empty candidate list in the log).
- Page initialisation also requests `ACCESS_BLUETOOTH` for this line (`CameraPage.ets:4269-4286`), which contradicts the fact that this line has no Bluetooth and merely adds one pointless authorisation (harmless but imprecise).
- Downloading original images requires `WRITE_IMAGEVIDEO` and the result is checked (`LumixSyncImageTransfer.ets:1427-1435`), which is stricter than the Wi-Fi permission handling.

### 8.4 Background and network constraints

- DMS listening, SSDP announcements and upload reception all depend on the app process being alive; `stop()` withdraws the announcements and closes all connections (`PanasonicS5Receiver.ets:195-233`), and navigating back does not stop it automatically (`ImageTransferPage.ets:284-294` explicitly does not block going back), but once the process is reclaimed by the system camera pushes necessarily fail (inferred).
- UDP `1900` is frequently occupied by the system; the code degrades to a random port and keeps only the ability to send announcements (`PanasonicS5Receiver.ets:743-750`). In that state the camera can still find the phone via NOTIFY, but the phone cannot receive the camera's M-SEARCH (inferred: `respondToSearch` only takes effect on a socket bound to the multicast side).
- The camera hotspot has no internet access, so joining uses `showNoInternetDialog: true` to keep the system from repeatedly interrupting with "no network" dialogs (`LumixCameraService.ets:2018-2023`).
- Many failure paths depend on "the logs getting back to us": Wi-Fi direct connect, S5/cam.cgi and DMP discovery used to write only to hilog; they now go to disk uniformly through `AppLogSink`, with SSID/MAC/URL/path redacted (`LumixCameraService.ets:413-426`, `LumixSyncImageTransfer.ets:64-88`).

### 8.5 Open items at the protocol level

- The exact effect of `pictmode` is described only in a comment, as "image selection mode", and the code does not send it (`LumixCameraService.ets:2237-2253`, `CameraPage.ets:6678-6683`).
- The 60 s `accctrl` authorisation window is a measurement from a single body (ZS300, 2026-10-21); whether it applies to all older models is unverified (`LumixSyncControlService.ets:1041-1043`).
- Of the three official onboarding paths — manual AP selection / QR code / NFC — this project implements only the first; for the other two, the prerequisites (the camera-side QR content format and the NDEF structure of NFC tags) have no sample anywhere in the code.

### 8.6 Observability and triage entry points

- Log tags: `VIVID_S5` (reverse push, DMP descriptor, req_acc), `VIVID_SYNC_DMS` (Browse, downloads), `VIVID_SYNC` (accctrl, camcmd), `VIVID_WIFI` (direct join), `VIVID_USB` (USB path) (`PanasonicS5Receiver.ets:1007-1010`, `LumixSyncImageTransfer.ets:26`, `LumixSyncControlService.ets:148`, `LumixCameraService.ets:2031-2033`).
- Raw Browse responses and the raw text of `getsetting`/`getinfo` are written to the app log in chunks of 3600 characters, at most 10 chunks, to allow the parser to be fine-tuned afterwards (`LumixSyncImageTransfer.ets:316-330`, `LumixSyncControlService.ets:1505`, `:1577`, `:1603`).
- A download failure must carry the `BusinessError` code/message; `http=0 bytes=0` appearing on its own cannot distinguish "authorisation expired / unreachable / timed out" (`LumixSyncImageTransfer.ets:432-446`).
- Before being written to disk the app log is redacted by `AppLogPolicy.sanitize` (SSID/MAC/URL/path) and throttled by `AppLogSink` (`LumixCameraService.ets:413-426`). Hosts and SSIDs in the log are therefore redacted forms, and identifying a specific model depends on the conclusion lines of `model`/`identifyWifiSsid`.
- Camera addresses and client identity are recorded in `present`/`absent` form rather than as concrete addresses (for example `req_acc GET host=present client=present profile=WEB-W00`, `LumixCameraService.ets:2225`).

## 9. Field checklist

Working through the following in order shows which layer is broken without reading the code:

1. Is the card's line `lumix_image`: the return value of `CameraSessionStore.panasonicLine()` (`CameraSessionStore.ets:101-109`).
2. Is the body present among the scan candidates: whether the `scanForCameras()` result and `identifyWifiSsid()` hit a token (`LumixCameraService.ets:1889-1942`, `:2087-2130`).
3. Is Wi-Fi actually associated with that SSID: the `direct association confirmed` line in `VIVID_WIFI` (`:2052`).
4. Is the gateway readable: an empty `linkedGateway()` means no HTTP step is ever issued (`:1959-1968`, `CameraPage.ets:6612`).
5. Was `req_acc` accepted: `req_acc response code=… marker=…` in `VIVID_S5` (`:2232`).
6. Has the local DMS been announced: `passive receiver started ports=…` and `SSDP ready ip=present` (`PanasonicS5Receiver.ets:191-192`, `:757`).
7. Does the camera come to fetch the descriptor: `DMS GET …` and `dms descriptor response code=…` (`PanasonicS5Receiver.ets:374`, `LumixCameraService.ets:2296`).
8. Is the upload being framed: `upload start … chunked=1`, `file done … bytes=…`, and on error `upload aborted: …` (`PanasonicS5Receiver.ets:535`, `:713`, `:653`).

## 10. Reference index

- Line and models: `LumixCameraService.ets:240-401`, `:1766-1831`, `:1862-1873`, `:2087-2130`
- Onboarding: `LumixCameraService.ets:1883-2077`, `:1954-1968`, `CameraWifiPasswordPolicy.ets:1-37`, `CameraPage.ets:4246-4260`, `:4350-4434`, `:4530-4676`
- Discovery: `LumixCameraService.ets:2281-2382`, `PanasonicS5Receiver.ets:736-819`
- Control plane: `LumixCameraService.ets:2136-2269`, `LumixSyncControlService.ets:905-1035`, `:1094-1259`, `:1984-2002`
- Images: `LumixSyncImageTransfer.ets:23-490`, `:1030-1221`, `:1414-1519`, `:1659-1683`, `PanasonicS5Receiver.ets:80-946`
- Entry points and sessions: `CameraSessionStore.ets:87-156`, `CameraPage.ets:1309-1318`, `:2263-2279`, `:3873-3919`, `:6482-6724`
