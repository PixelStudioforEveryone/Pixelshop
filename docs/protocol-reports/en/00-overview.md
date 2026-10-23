# 00 Overview: Bluetooth pairing / Wi-Fi transport / camera control across five brands and seven lines

**English** | [简体中文](../00-overview.md)

> Translated from the Chinese original at baseline commit `18466be`. UUIDs, opcodes, ports and `file:line` references are kept verbatim; 「推断」 is rendered as "inferred".

The reports in this directory are organised by **protocol line**, not by brand: one Panasonic body belongs to exactly one of three Panasonic lines, while Sony, Canon, Nikon and Fujifilm have one line each. This file is only the cross-line comparison and index; details live in the individual reports.

| # | Line | Body coverage (as coded) | Role of Bluetooth in the chain | Wi-Fi transport | Control plane |
|---|------|--------------------------|-------------------------------|-----------------|---------------|
| 1 | [Panasonic LUMIX Lab](01-panasonic-lumix-lab.md) | `S5M2X S5M2 S1RM2 S1RII S1M2E S1IIE S1M2 S1II S9 GH7 G9M2 G9II L10` | GATT registration + AP credentials (shared `LumixImportPrototype`, primary service `1fe71b85`) | HTTPS `/remote/*` + `/lut/*`; live view over UDP + DTLS 1.2 | `camcmd` / `set-setting` / `get-state` / `camctrl` |
| 2 | [Panasonic LUMIX Sync](02-panasonic-lumix-sync.md) | `S1H S1R G100D G100 GH5M2 GH6 GH1` | GATT registration hands over credentials (service `054ac620`), ten notifying characteristics | HTTP `cam.cgi`; images via the body's DLNA/DMS on :60606 | `cam.cgi` + `X-SESSION_ID`; `startstream` plaintext UDP (phone side 1210) |
| 3 | [Panasonic Image App](03-panasonic-image-app.md) | GH5/GH5S/G9, GX/TZ/FZ/LX/GM and other older bodies | **No Bluetooth**: manual AP selection (the official app also offers QR/NFC) | HTTP `cam.cgi` + DLNA/SSDP | Mostly read-only probing plus legacy commands |
| 4 | [Sony Alpha](04-sony-alpha.md) | 26 model tokens across Alpha / Cinema Line / ZV / RX | Private pairing service `8000EE00`, control service `8000CC00` for SSID/password | ISO 15740 PTP/IP, TCP :15740 (transport layer shared with Nikon) | `0x9209` reads body-declared properties, `0x9205` writes them; live view and shutter both on `0x9207`, frames arrive over HTTP :60152 |
| 5 | [Canon EOS](05-canon-eos.md) | 95-pid model table (R5/R6 II/R1 …) | Private GATT `0001xxxx-…-D8492FFFA821`: bond → register → WAP handover | ISO 15740 PTP/IP, two TCP :15740 channels | EOS properties `0x1015`/`0x9110`, `0x1014` descriptors, `0x9128` shutter; **CCAPI is not used** |
| 6 | [Fujifilm X](06-fujifilm-x.md) | X series (legacy and RED generations) | XApp private GATT: write the advertised key back, read SSID/password, launch the function | **Private PTP-IP**: TCP :55740 control / :55741 live view / :55742 events, 12-byte header | PTP opcodes + private property codes; live-view JPEG offset `LE32@12 + 18` |
| 7 | [Nikon Z](07-nikon-z.md) | 14-model Z table | SnapBridge `0000DE00-3DD4-4255-8D62-6DC7B9BD5561` + four-stage LSS authentication | ISO 15740 PTP/IP, TCP :15740 | `0x90C2` takeover, `0x9201/0x9202/0x9203` live view, `0x9207` shutter, properties `0x1014/0x1015/0x1016` |

## 1. Three rules shared by all seven lines

### 1.1 Bluetooth gets you in the door; it never carries data

Apart from Fujifilm, whose live view and control still ride TCP, BLE on all lines does exactly three things: identify the body, register the client identity, and hand the SSID/password to the phone. Pixels, thumbnails and live view all travel over Wi-Fi. This is a firmware constraint rather than a design preference: the Canon BLE table contains no media characteristic at all (`CanonProtocol.ets:189-233`), Nikon's BLE only writes one connection-configuration block (`NikonLssProtocol.ets:23-30`), and Panasonic's SSID/password characteristics are both reads (`LumixImportPrototype.ets:344-378`).

Two implementation rules follow:

- **BLE failure does not mean the camera is unusable.** BLE registration on all three Panasonic lines is best-effort; the Lab line continues to `/auth` even when registration fails (`LumixControlService.ets:1125`), and a failed Canon scan only affects the Canon card (`CanonBleService.ets:276-296`).
- **Credentials are valid only for the session that fetched them.** Panasonic passwords change when the AP restarts, Fujifilm disconnects immediately when the password read fails and never persists it (`FujifilmBleService.ets`), and Nikon's LSS session key is never stored (`NikonLssSession.ets`).

### 1.2 Only two transport families exist over Wi-Fi

| Family | Lines | Shape | Transaction model |
|--------|-------|-------|-------------------|
| HTTP | the three Panasonic lines | `cam.cgi` query strings / `/remote/*` JSON envelopes / DLNA SOAP | Request-response with a session token or `X-SESSION_ID` |
| PTP/IP | Sony, Canon, Nikon (standard 15740) and Fujifilm (private 5574x) | Binary header + opcode + data phase | Transaction IDs, plus a persistent event channel |

The PTP/IP family branches internally: Sony and Nikon share a single `NikonPtpIpService`, Canon has its own (`CanonPtpIp.ets`, two channels plus `SetRemoteMode`/`SetEventMode`), and Fujifilm changed even the port numbers and header length. Treating "PTP/IP" as one protocol is a trap — `CameraControlBrand.isPtpIpProtocol()` deliberately excludes Fujifilm (`CameraControlBrand.ets:101-108`).

### 1.3 What you can control is declared by the body

- Sony: values, option lists and writability all come from `0x9209` `formFlag-2` records; the code keeps no mapping table (`SonyPtpIpControl.ets`). On a real ILCE-7M4 the exposure mode is `opt0:ro`, so the panel displays the current mode but cannot change it.
- Canon: `0x1014` descriptors are probed first, then the code decides which of the 14 EDSDK properties are readable and writable (`CanonControlService.ets`).
- Nikon: descriptor probing via `0x1014` covers six panels; the older "12 Nikon panels unavailable" list in `CameraControlBrand` no longer applies on that path (see the comment/implementation conflict list in report 07 §9).
- Panasonic: the Lab line has a `get-setting` parameter domain and a 33-field `get-state` read-back; the Sync and Image App lines rely on `cam.cgi` `getsetting`/`getstate`, and capabilities vary with firmware.

## 2. Pairing quick reference

| Line | Advertisement identification | Pairing action | Credential read |
|------|------------------------------|----------------|-----------------|
| Panasonic Lab | Manufacturer ID 58 (6 bytes carrying the Bluetooth address) + model code in the last two bytes of the local name (`0x0A`+1..9) | Write `APP_UUID` (XOR-encoded) → `APP_INFO` → `FRIENDLY_NAME` → `PAIRING_INIT=0x02` → `ACTION_MODE=0x01` | Two read characteristics: `WIFI_SSID` / `WIFI_PASSWORD` |
| Panasonic Sync | Service `054ac620`; model code likewise in the last two bytes of the name | 16-byte MEI0 identity (APS bodies read `INITIAL_INFORM` first for the session key) → name → wait for the AP | `e206a5c0` SSID list / `c97cf1a5` password (length byte first, XOR) |
| Panasonic Image App | No BLE | None (the user joins manually) | None (the body displays the password) |
| Sony | Company ID `0x012D` + `03 00` marker + capability tags 33/34/35 | System bond, then write `EE01 = {6,8,1,0,0,0,0}` and wait for `EE03` state | Write `CC08={1}` to enable Wi-Fi, read `CC06/CC07/CC0C` (3-byte header) |
| Canon | Company ID 425, `[0]==1`, 19-byte or 6-byte manufacturer data | Bond (states 10/11/12 normalised) → registration frame `01`+nickname → `0A 01/02` | WAP handover: `04 09…` + TLV (`0x10` IP / `0x02` BSSID) |
| Fujifilm | Company ID `0x04D8`, `mf[0]=1` (RED) / `2` (legacy) | Write the advertised key back to `ABA356EB` verbatim; RED also writes `F557D96B` and `8B5ECF55` | `BF6DC9CF` SSID / `E809256A` password (UTF-8 up to `0x00`) |
| Nikon | Three admission paths: SnapBridge service UUID, Z model table, name regex | Four LSS stages: `[stage][nonce8][deviceId8]`, Blowfish-decrypted credential block | Connection-configuration block: flag + SSID 32 + password 64 + security + sppMaxDataLength |

Three details that are easy to get wrong:

1. On Panasonic Sync, `req_acc` is the registration commit. The first answer is `ok_under_research`; a resend about 1 s later returns `ok`, and a quiet period of roughly 10+ seconds must follow (the official captures show 19 s / 34 s). This implementation once used 2 s and was rejected immediately (`LumixSyncControlService.ets:31-52`).
2. Sony pairing success is defined by the **system bond state**, not by `EE03` notifications — on an ILCE-7M4 the body reports pairing success while `EE03` never fires (`SonyBleProvisioning.ets:596-621`).
3. After Nikon writes `0x2005=[1]`, Bluetooth must be fully released (RFCOMM client and server, discoverability, GATT) before the camera's hotspot appears (`NikonBleProvisioning.ets`; see report 07 §6).

## 3. Evidence levels

All seven reports use the same labels:

- **Fact**: traceable to a `file:line` in code/constants/comments, or to an existing capture or decompilation record in the repository.
- **Inferred**: reasoned from code but not verified on hardware, with the basis and fallback stated per item.
- **Not annotated in code**: the UUID or field exists in the source but the comments do not explain it; recorded as-is rather than guessed.

Two limitations apply to the method:

1. The reverse-engineering conclusions in this repository come from decompiling official clients and capturing real hardware sessions. The reports only restate facts already baked into the code; no new captures or decompilations were performed while writing them.
2. "Official" in the reports means the official app versions recorded in the code comments (LUMIX Lab / LUMIX Sync / Image App / Creators' App / Camera Connect / XApp / SnapBridge), not versions re-acquired for this writing.

## 4. Security and privacy boundary

- This repository is the public build: it does not contain `server/` (signalling, log receiver, LUT market backend) or the server-side scripts, and every service endpoint in the code was replaced with the placeholder `https://your-server.example.com`.
- Camera Wi-Fi passwords, LSS session keys and client UUIDs are runtime data. The "Limitations and risks" section of each report marks, item by item, where the **current implementation contradicts what the comments promise** — for example the Panasonic Sync line persisting the plaintext password (`LumixSyncControlService.ets:1769-1782`) and logging the session key to hilog (`:1857-1859`). These are defects to be fixed, not intended design.

## 5. Suggested reading order

Start here, then jump by need:

- If you only care about "how does the phone connect to the camera": read §2 (pairing) and §3 (transport) of each report.
- If you are building a cross-brand control layer: read 04 (Sony) §6 and 05 (Canon) §7; their "body-declared capability" models are the most complete.
- If you want to reproduce a specific handshake: every report ends with an implementation map and a list of items pending hardware confirmation; the class names lead straight to the source.
