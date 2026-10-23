# Pixelshop · Vivid for HarmonyOS

**English** | [简体中文](README.zh-CN.md)

Vivid ("像素工坊", vendor `Pixelshop`) is a HarmonyOS imaging workspace built with ArkTS + ArkUI: photo library, camera connectivity (Bluetooth pairing + Wi-Fi transfer + remote control), background transfer, LUT style library and lossless parameter editing.

## Camera protocol lines

Five brands, seven protocol lines. Each line has its own implementation under `entry/src/main/ets/services/` and its own report under `docs/protocol-reports/` (Chinese; English translations in `docs/protocol-reports/en/`):

| # | Line | Pairing | Transport | Control | Report |
|---|------|---------|-----------|---------|--------|
| 1 | Panasonic LUMIX Lab | BLE GATT registration (shared `LumixImportPrototype`) + AP credentials | `/remote/*` REST + DTLS live view | `camcmd` / `set-setting` / `get-state` | [01](docs/protocol-reports/en/01-panasonic-lumix-lab.md) |
| 2 | Panasonic LUMIX Sync | BLE GATT registration hands over credentials | `cam.cgi` + DLNA/DMS | `cam.cgi` + `X-SESSION_ID` | [02](docs/protocol-reports/en/02-panasonic-lumix-sync.md) |
| 3 | Panasonic Image App | No Bluetooth (manual / QR / NFC join) | `cam.cgi` + DLNA/DMS | Read-only probing + legacy commands | [03](docs/protocol-reports/en/03-panasonic-image-app.md) |
| 4 | Sony Alpha | BLE `8000EE00` pairing + credentials | ISO 15740 PTP/IP :15740 | `0x9209` / `0x9205` / `0x9207` | [04](docs/protocol-reports/en/04-sony-alpha.md) |
| 5 | Canon EOS | BLE `0001xxxx-d8492fffa821` | ISO 15740 PTP/IP :15740 | EOS property codes + `0x9114`/`0x9115` | [05](docs/protocol-reports/en/05-canon-eos.md) |
| 6 | Fujifilm X | BLE XApp GATT (legacy / RED) | Private PTP-IP :55740/55741/55742 | PTP opcodes + property codes | [06](docs/protocol-reports/en/06-fujifilm-x.md) |
| 7 | Nikon Z | BLE SnapBridge + LSS authentication | ISO 15740 PTP/IP :15740 | Live view `0x9201` / shutter `0x9207` | [07](docs/protocol-reports/en/07-nikon-z.md) |

Cross-line comparison: [English](docs/protocol-reports/en/00-overview.md) · [中文](docs/protocol-reports/00-overview.md).

> This is the public build: **`server/` is not included** (signalling, log receiver, LUT market backend) and neither are the server-side scripts. Every service endpoint was replaced with the placeholder `https://your-server.example.com`; the donation QR images and the page fragments that rendered them were removed; signing material was stripped from `build-profile.json5`, so configure your own signature in DevEco Studio before running. The camera protocol code (BLE / PTP-IP / HTTP) does not depend on any self-hosted service.

## Implemented

- Responsive home: floating bottom navigation in narrow windows; side rail and multi-column content above `840vp`.
- Library: authorised gallery access, system photo picker, sample projects and editor entry points.
- LUMIX link: after joining the camera Wi-Fi, probes Panasonic's `cam.cgi` status endpoint over the LAN.
- Transfer centre: RAW + JPEG queue, progress and background-task information.
- LUT library: built-in LUMIX looks and generic grading presets; imports `.cube/.3dl/.look` through the HarmonyOS document picker, parses them into reusable lossless presets, supports deletion and persistence via Preferences.
- Professional editor: light and colour basics, RGB/master curves with add/remove/drag anchors, temperature/tint/saturation/vibrance sliders with triangular pointers, eight-channel HSL, camera-native colour matching, true-pixel crop/rotate/flip, brush/linear/radial masks that keep strokes within the session, stacked adjustment layers, histogram, before/after, full undo/redo and JPEG export.
- Desktop workspace: asset filmstrip, central canvas, floating toolbar and right-side develop inspector.
- Phone workspace: unobstructed top/bottom canvas split, capsule-shaped liquid-glass dock and scrollable tool cards.
- Native motion: the main workspace uses ArkUI's `Particle` system for low-distraction ambient light.

## Running

1. Open this directory in DevEco Studio.
2. Wait for the project sync to finish.
3. Select the `entry` module and a signed local device/emulator.
4. Click Run. Grant gallery access on first launch, or decline and use the built-in demo assets.

The project targets HarmonyOS 26.0.0 / API 26 with a minimum of API 23. The home screen and editor dock use native Tabs floating material where supported, and the generic adjustment sliders use the system immersive light effect with particle animation; older devices or devices without material support fall back to frosted glass. Ordinary content cards sit outside the system-material region and use `backgroundBlurStyle` uniformly, so an ineffective `systemMaterial` is never mistaken for native refraction. Background particles stop when the app is backgrounded.

## Camera connectivity notes

Before opening the "Camera" page, join the Wi-Fi network created by the camera in system settings. The default address is `192.168.54.1` and can be edited in the UI. Control capabilities differ per body and firmware: the adapter performs read-only status probing first and only extends to remote shooting, thumbnail indexing and original-file download once probing succeeds.

USB follows the sequence of Panasonic's Lumix Remote Control Library sample: enumerate and filter the Still Image/PTP interface, call the system `requestRight` for USB access, set the configuration and claim the interface, send the standard `OpenSession` (session 1), then Panasonic's `LumixOpenSession` (opcode `0x9102`, parameter `0x00010001`) to authorise the SDK session, read the `GetDeviceInfo` transaction containing DATA and RESPONSE, and on close send `LumixCloseSession` (`0x9103`) before `CloseSession` and releasing the interface. Complete Bluetooth pairing on the camera before the first USB connection and set `[USB > USB mode]` to `LUMIX Lab`. The official `Lmxptpif.dll` is a Windows library; the HarmonyOS build transfers PTP containers directly through `usbManager`.

Key entry points:

- `entry/src/main/ets/pages/Index.ets`: product shell and the four workspaces.
- `entry/src/main/ets/pages/EditorPage.ets`: editing session, export and responsive chrome.
- `entry/src/main/ets/views/TabletLayout.ets`: desktop/2-in-1 three-column workspace.
- `entry/src/main/ets/views/PhoneLayout.ets`: phone and narrow-window editor.
- `entry/src/main/ets/services/LumixCameraService.ets`: Panasonic LAN connection adapter.
- `entry/src/main/ets/edit/`: image processing, adjustments, presets, layers and mask engine.
