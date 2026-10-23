# FUJIFILM 路线 · 实现与验收

> 目标：在 VIVID 里新增一条**与现有路线并行**的富士识别/控制/图传/固件链路，
> 不改动松下 LAB / SYNC / Image App、尼康、索尼的任何协议与行为。
> 协议依据：`C:\Users\HQ\Desktop\picture\documents\Fujifilm\apk\reports\00–04`（逆向报告）。

## 1. 交付物

### 1.1 新增服务（`entry/src/main/ets/services/`）

| 文件 | 行数 | 职责 |
|---|---|---|
| `FujifilmProtocol.ets` | 368 | 全部协议常量（BLE UUID/拉起值/SSID/密码、PTP-IP 端口与帧、39 条操作码、属性码、事件、超时、固件字段），**唯一事实来源** |
| `FujifilmPtpIp.ets` | 745 | PTP-IP 客户端：55740/55741/55742 三通道、12 B 包头、Initialize+OpenSession、事务串行队列、512 B 数据块、事件通道、取景帧（JPEG 偏移 `LE32@12+18`） |
| `FujifilmBleService.ets` | 731 | BLE 扫描（7 个服务 UUID，AF854C2E 常驻）、GATT 连接、配对（无 PIN/无加密）、SSID/密码读取、功能拉起（03/04/05）、`AP_STATE` 等待、固件专用特征读写 |
| `FujifilmModels.ets` | 186 | 机型名归一化 → `fujifilm_<slug>` imageKey、SSID → 机型识别 |
| `FujifilmModelImages.ets` | 128 | 85 款机身素材表（自动生成） |
| `FujifilmControlService.ets` | 1786 | 控制链路：模式协商、`GetDevicePropDescAll(0x902B)` 解析、53 条参数读写/步进、拍摄/录像/变焦/S1 锁、事件分发、取景推流 |
| `FujifilmImportService.ets` | 1556 | 图传链路：双槽探测/切槽、句柄一次取全、缩略图队列、整包/分块下载、落地相册 |
| `FujifilmFirmwareService.ets` | 1337 | 固件：版本读取、云端 JSON、92 B BLE 请求、1 MiB 推流（事件 49/50） |

### 1.2 新增页面（`entry/src/main/ets/pages/`）

| 文件 | 行数 | 说明 |
|---|---|---|
| `FujifilmCameraControlPage.ets` | 1309 | **预览**（全屏取景+AF+只读芯片）/ **遥控**（冻结最后一帧+14 主参数+6 快捷+53 项列表）两态，切遥控即停流 |
| `FujifilmImageTransferPage.ets` | 771 | N 个 SD 卡按钮（空卡灰显）、2 列网格、全选/下载、进度浮层、缩略图预览 |
| `FujifilmFirmwarePage.ets` | 547 | 当前/最新版本、更新说明、检查更新 / 开始更新 / 取消、模态进度、错误码中文解释 |

### 1.3 共享文件的**加法式**改动（只有 5 个）

`pages/home/CameraPage.ets`（+364/−4）、`services/CameraSessionStore.ets`（+11）、
`services/CameraControlBrand.ets`（+15）、`services/CameraCardRegistry.ets`（+7）、
`resources/base/profile/main_pages.json`（+3 路由）。

### 1.4 素材

`entry/src/main/resources/rawfile/fujifilm/`：85 款机身透明 PNG（700 px 宽）+ `generic.png` + `manifest.json`，共 20.6 MB。
来源：XApp 2.7.0 产品图 → 白底抠透明（`Fujifilm\apk\camera_images_png`）→ 缩放到 App 既有画幅。

## 2. 接线

```
相机页扫描（富士 7 个服务 UUID）
  → 命中：品牌 FUJIFILM、机型图 rawfile/fujifilm/<slug>.png、卡片四入口
  → [图片传输] launch(3) → AP_STATE 0x8001 → 关联热点 → pages/FujifilmImageTransferPage
  → [相机控制] launch(4) → 同上              → pages/FujifilmCameraControlPage
  → [WIFI 连接] 只拉起 AP + 关联，留在相机页
  → [固件更新]                                 → pages/FujifilmFirmwarePage
（没有 LUT 传输按钮；四入口布局与松下 LAB 同构）
```

## 3. 关键协议对照（代码 ↔ 报告）

| 环节 | 实现 | 依据 |
|---|---|---|
| 扫描 | 7 个服务 UUID，`AF854C2E` 常驻；60 s 重启；广播 `mf[0]=1`（RED）/`=2`（老协议） | 01 §2 |
| 设备名 | 前 4 字符 = 短序列号，其余 = localName | 01 §2.4 |
| 配对 | 广播 pairing key 原样回写 `ABA356EB`；RED 另写 `0x20000000`/`80 01 01`；无 PIN/加密 | 01 §6 |
| 凭据 | `BF6DC9CF`（SSID）/`E809256A`（密码），UTF-8 读到 `0x00`，密码只在内存 | 01 §8 |
| 拉起 | `600655E6` 写 u16 LE：3=浏览 4=遥控 5=固件；`A68E3F66=0x8001` 就绪 | 01 §9 |
| 传输 | PTP-IP 12 B 包头；55740 控制 / 55741 取景 / 55742 事件 | 02 §3 |
| 控制编排 | 连接 → 事件 11 → `SetFunctionMode(20,0xDF28)` → `SetCameraFunctionMode(6)` → `SetFunctionMode(22,0xDF2A)` → `0x902B` → `0x101C` → 事件 11 → `SetFunctionMode(5)`+`0xDF25`/`0xDF24` | 02 §4 |
| 参数 | 53/53 属性码进目录，取值域按 `control_property_codes.csv`；不编造值域 | 02 §5 |
| 取景 | 204800 B 阻塞读，JPEG = `LE32@12 + 18`；遥控态**不推流** | 02 §7 |
| 图传 | `SetFunctionMode(20,0xDF28)` → 双槽 `0xD244` → 当前句柄 `0xD22B` → 张数 `0xD620` → 句柄 `0xD621`（一次取全）→ `0x9054`/`0x9055` → `0x1009`/`0x9056` | 03 §3–§7 |
| 双槽 | status 1→槽2、2→槽1、3→槽2、4→槽1、5→槽2/3、6→槽1/3、7→三槽；切槽先清列表再重枚举 | 03 §4.4 |
| 排序 | **不排序**，保持相机顺序（handles[0] 最新）；无 `sort`/`reverse` | 03 §5 |
| 固件清单 | `GET https://privacy.xapp.net/camera_fw/camera_fw_info.json`，无鉴权无参数 | 04 §5.1 |
| 固件版本比较 | 十进制等价 BigDecimal（`4.30==4.3`、`1.12<1.2`、`4.9>4.31`） | 04 §5.9 |
| 固件推流 | 92 B BLE（type 2 + productName 64 + fileName 15 + size 4 + version 7）→ `0x9040` → 事件 49 逐块 1 MiB `0x9042` → 事件 50 结束 | 04 §5.4–5.5 |
| 固件收尾 | **不发断电、不回滚、不自动重试**；相机自断电重启 | 04 §5.6 |

### 3.1 下载落地与方向（竖拍不会横置）

富士线每张作品写入系统相册后**同时写入「最近作品」**（与松下/尼康线一致），走 `RecentPhotoStore.add(...)`：

| 场景 | 处理 | 依据 |
|---|---|---|
| 相机缩略图（列表/预览/RAW 兜底） | 方向来自 `0x9054` 私有 metadata 的 `Orientation:<EXIF 1–8>`（见 NOTES_F）；缓存前在 `orientThumbnail()` 里解码→旋转→重编码，**像素落地就是显示方向** | NOTES_F §2–§4 |
| JPEG / HEIC 原图 | 在 `PixelMapUtils.loadFromUri()` 里统一归一化（编辑器、导出、作品卡共用）：读 EXIF Orientation，再用 **JPEG SOF 段的存储像素尺寸**与解码尺寸的宽高比判断解码器是否已转，**只补没转的那次**（避免二次旋转） | `edit/utils/ExifOrientation.ets`；`RECENT_THUMBNAIL_VERSION=5` 触发一次性重建 |
| 原图瞬间读不出来（媒体库刚 `createAsset` 的 EPERM 窗口） | 用上面已转正的相机缩略图兜底，方向参数传 1，避免二次旋转 | 同上 |
| RAF / 其它 RAW | 相册与「最近作品」都用相机缩略图，`portrait` 由缩略图尺寸决定 | NOTES_F |
| 卡片长宽比 | `portrait` 按**转过方向后**的缩略图尺寸写入记录：竖图 2:3、横图 3:2 | `PhotoItem.portrait` |

> 官方 App 在 WiFi 侧把方向写进缓存 JPEG 的 EXIF（`CashDataManager.java:333-337`），并不转像素；
> 它在下载/预览时自己再 rotate（`ReceiveImageModel.java:1867`）。本项目选择**缓存即转正**，
> 因为 ArkUI 的 `Image.rotate()` 发生在布局之后，90°/270° 会顶出卡片格子。

下载完成的状态文案会给出「相册 N，最近作品 M，失败 K」。

**编辑链路**：作品卡点击传的是原始 URI，编辑器预览（`EditorPage:536`）和导出用的全分辨率图（`EditorPage:1002`）都走 `PixelMapUtils.loadFromUri()`，因此上面这条归一化对「点进去编辑/导出」同样生效——横图不会被转竖，竖图也不会被压回横框。

## 4. 验收结果

| 项 | 结果 |
|---|---|
| `devecocli build --modules entry` | **BUILD SUCCESSFUL**（ArkTS 0 error；产物 `entry/build/default/outputs/default/entry-default-signed.hap`，332 MB，含 88 个 fujifilm 资源条目） |
| 隔离性 | `git status` 仅富士新文件 + 5 个共享文件的加法改动；`Lumix*/Nikon*/Sony*`、`CameraControlPage.ets`、`ImageTransferPage.ets` **零改动** |
| 既有相机链路回归 | `check_camera_card_history.cjs`、`check_camera_profiles.cjs`、`check_camera_wifi_password.cjs`、`check_new_modules_smoke.cjs` 全 PASS |
| 参数覆盖 | 控制页 53/53 条（与 CSV 逐条对齐） |
| 版本比较 | 9 组用例覆盖 BigDecimal 语义（含 `1.12 < 1.2`）全部通过 |
| 素材 | 85 款机身 + 通用占位，已打进 HAP |

## 5. 遗留【未知】（真机验证清单）

各角色 NOTES 里逐条记录了证据级别与回退方案，汇总最需要真机确认的 8 条：

1. **取景通道 55741 的 initialize**（A）：报告未记录握手包；已做「按事件通道同形发送 + 三种结果都继续」。
2. **`DataPhaseInfo` 口径**（A）：协议 0/1/2 与 CIPA 1/2/3 冲突，首次 `GetDeviceInfo` 自校准。
3. **`0x902B` 响应头排布**（B）：反汇编确认 TLV，但真机需看 `[FUJI] 0x902B` 日志里的布局命中项。
4. **事件 11/40 的原始码来源**（B）：已做直通码 + 原始码映射 + 超时降级，不伪造。
5. **双槽 status 位域**（C）：只信 0–7 的查表语义；`status=0` 时按机型兜底 1/2 槽。
6. **`0x9053` 响应布局、`0xD621` 是否带 count 前缀**（C）：均有兼容解析分支。
7. **`0x9040` 数据阶段时序、`0x9042` 参数语义**（D）：按报告实现；失败由相机错误码明确回传。
8. **CDN 地域校验 / 相机侧二次 SHA-256**（D）：客户端已校验 FileSize + SHA-256。

真机建议顺序：先只做「扫描 → 配对 → 读 SSID/密码 → 拉起 AP → 连热点」，
再进图传页看双槽与首屏缩略图，最后才进控制页（避免模式协商失败影响后续）。

## 6. 相关文档

- 实施契约：`docs/fujifilm/ROUTE_SPEC.md`
- 各自决策与证据：`docs/fujifilm/NOTES_A.md`（识别/BLE/PTP-IP）、`NOTES_B.md`（控制）、`NOTES_C.md`（图传）、`NOTES_D.md`（固件）
- 逆向报告：`Fujifilm\apk\reports\00_协议总览.md` … `04_固件更新协议.md`
