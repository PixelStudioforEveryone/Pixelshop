# 松下 LUMIX Lab 线路技术报告：Wi-Fi AP + /remote/* REST + DTLS 取景

> [English](en/01-panasonic-lumix-lab.md) | 简体中文

> 范围：`entry/src/main/ets/services/` 下的 Lumix 服务与相关控制页，基线提交 `18466be`。只读代码与注释，未修改任何源码。文中行号对应本仓库该提交；所有事实来自代码，推断处单独标注。

## 1. 线路定位

### 1.1 三条线的分区

| 线路 | 机型 token 集合 | 控制协议 | Wi-Fi 凭据来源 | 本仓库实现 |
|---|---|---|---|---|
| Lab（本报告） | `S5M2X S5M2 S1RM2 S1RII S1M2E S1IIE S1M2 S1II S9 GH7 G9M2 G9II L10` | `/remote/*` + `/lut/*`，DTLS 取景 | BLE GATT 注册 + 相机下发的 SSID/密码（由共享 BLE 流程带入） | `LumixControlService.ets` |
| Sync | `S1H S1R G100D G100 GH5M2 GH6 GH1`（已减去 Lab） | `cam.cgi` + `X-SESSION_ID` | LUMIX Sync 式 BLE 配对 | `LumixSyncControlService.ets` |
| Image App | `TZ99 ZS99 G90 … GH5S G9 GH5 G97 GH3` | `cam.cgi` + DLNA/DMS | 手动选热点 / 二维码 / NFC | `LumixCameraService.ets`、`PanasonicS5Receiver.ets` |

Lab 表的出处写得很明确：这些是官方 LUMIX Lab APK 中「字节→机型」表（`M0`，码值 1..9）的营销机身名，也就是广播里带紧凑机型码、Lab 会读取的那批机身；别名 `S1RII / G9II / S1II / S1IIE` 与营销名并列保留，因为相机或 API 回复可能给任一种写法（`LumixCameraService.ets:293`）。

Sync 表不是猜测出来的：LUMIX Sync 2.0.17 的 `T5/d.java` 里 `b(String)` 明确把 `DC-S5M2 / DC-S5M2X / DC-S9 / DC-GH7 / DC-G9M2` 划给 Lab（用于 `ON_LUMIX_LAB_INSTALL_DIALOG / ON_LUMIX_LAB_LAUNCH_DIALOG` 文案），因此 S9 属于 Lab（`LumixCameraService.ets:305`）。Sync 表在定义处就减掉 Lab 表，保证两条线互斥；减法只做精确 token 相等，所以 Sync 的 `S1R` 与 Lab 的 `S1RM2 / S1RII` 可以共存（`LumixCameraService.ets:319`、`LumixCameraService.ets:336`）。

Image App 表的依据是 Image App 1.9.0（Lumix Link 2.0）源码里 `BluetoothAdapter/BluetoothGatt/BLE` 零命中，即该世代没有蓝牙，配网靠手动热点、二维码（`MDL/SSID/PW/CRYPT/DeviceID`）或 NFC，随后 SSDP + `cam.cgi` + DLNA（`LumixCameraService.ets:340`）。GH5/GH5S/G9 在 2026-10-11 被移出 Sync 表放到这条线，理由是三者都有官方 Image App 支持记录、都没有蓝牙，而 Sync 线入口是 BLE 门控的（`LumixCameraService.ets:326`）。

### 1.2 路由顺序与不变量

`panasonicRouteForModel()` 的判定顺序是：Lab token → 初代 S5 → `fromBle` 兜底 Sync → `isWifiOnlyModel()` → Sync token → Image App 兜底（`LumixCameraService.ets:1766`）。UI 侧 `CameraSessionStore.panasonicLine()` 把三段身份拼起来调用该函数，并按 BLE 状态决定 `fromBle`（`CameraSessionStore.ets:101`）；控制页通过 `AppStorage['controlProtocol'] = 'lab'` 进入 Lab 分支（`CameraPage.ets:1667`）。两个容易踩的点写在注释里：

- Lab 身份优先于「仅 Wi-Fi」判定。调用方传进来的是「机型 + BLE 候选机型 + BLE 广播名」三段拼接，里面可能残留上次配对的机型串，而 `isWifiOnlyModel()` 只要任一 token 看到 S5/ZS300 就返回 true；若先判 Wi-Fi-only，S1RM2/S9 会被整条路由到 Sync（`LumixCameraService.ets:1759`）。
- 三个集合在定义处逐级相减，「任何未来重排或新增都不会让一台机身被两条线认领」（`LumixCameraService.ets:1755`）。

**与任务清单的差异（如实记录）**：代码里的 Lab token 是 `L10`，没有 `G10`；全仓库唯一的 `G10` 字面量是佳能 PowerShot G10 的相机配置文件，与 LUMIX 无关。任务描述中的 G10 在本仓库没有对应实现，若要覆盖需先确认真实机型串（`LumixCameraService.ets:302`、`LumixImportPrototype.ets:342`）。

### 1.3 与 Sync / Image App 的边界

- 控制面：Lab 只走 `/remote/*` 与 `/lut/*`；`cam.cgi` 属于 Sync 与 Image App。仓库里 `probe()` 的 getstate/getinfo 探测是 cam.cgi 家族的握手，并且显式丢弃含 `err_` 的响应体，避免把错误 XML 当机型（`LumixCameraService.ets:2136`）。Lab 的第一次 HTTP 是 `/auth`（`LumixControlService.ets:957`）。
- 取景：Lab 是 UDP + DTLS 1.2；Sync 是明文，但两者共用同一套 Panasonic 分片布局。代码用 9 字节 magic 区分，同时允许无 magic 但结构自洽的包，以兼容 Sync 明文流（`LumixControlService.ets:1171`）。
- UI：`isCamCgiRoute(route)` 把 `sync` 与 `lumix_image` 合并为「cam.cgi 家族」，Lab 不在其中（`LumixCameraService.ets:1862`）；Image App 线不提供相机控制页（`CameraPage.ets:1633`）。

## 2. 蓝牙：有实现，但不在 Lab 控制服务内

结论：本仓库**实现了** Lab 世代的 BLE 配对/注册，代码在共享的 `LumixImportPrototype.ets`，不在 `LumixControlService.ets`。控制面只在开会话时做一次 best-effort 注册，失败不阻断 HTTPS（`LumixControlService.ets:1117`）。

### 2.1 扫描与广播解析

扫描不设 `ScanFilter`，用 `BLEDeviceFind` 回调自行解析 AD 结构，首个可连接的松下候选即提前退出，最长 10 s（`LumixImportPrototype.ets:2005`）。广播身份取自协议字段而非可改的本机名：

| 字段 | 值 / 规则 | 出处 |
|---|---|---|
| 扫描服务 UUID | `054ac620-3214-11e6-ac0d-0002a5d5c51b`（官方按它过滤；本仓库记为诊断项） | `LumixImportPrototype.ets:312` |
| 厂商 ID | 58，厂商数据恰好 6 字节 | `LumixImportPrototype.ets:335` |
| 蓝牙地址 | 厂商数据第 2..5 字节（大端十六进制串） | `LumixImportPrototype.ets:337`、`:2262` |
| 机型码 | 本机名最后两字节为 `0x0A` + 码值 1..9 | `LumixImportPrototype.ets:339`、`:2248` |

机型码表（索引 0 为空）：1=`S9`、2=`GH7`、3=`S5M2`、4=`S5M2X`、5=`G9M2`、6=`S1M2E`、7=`S1M2`、8=`S1RM2`、9=`L10`（`LumixImportPrototype.ets:342`）。解析时把末尾两字节从显示名中剥掉，得到可展示名称；码值越界则退回名称匹配（`LumixImportPrototype.ets:2252`）。这解释了 `LumixCameraService.ets:293` 所说的「广播里带紧凑机型码」。

### 2.2 GATT 服务与特征

主服务 `1fe71b85-8344-4e6a-bf1a-ac7acdb3f8af`（`LumixImportPrototype.ets:344`）。控制线只要求 `INITIAL_INFORM / APP_UUID / ACTION_MODE` 三者存在（`LumixImportPrototype.ets:868`），图传线还要求 `WIFI_SSID / WIFI_PASSWORD`（`LumixImportPrototype.ets:1423`）。

| 名称 | UUID | 方向/用途 |
|---|---|---|
| `INITIAL_INFORM` | `239c7203-922f-43e9-bdf1-6d1fedf6f43f` | read，注册编码的 4 字节种子 |
| `APP_UUID` | `bff12e7f-5944-4eb6-a90f-48d8786157ea` | write，客户端 16 字节 UUID（编码后） |
| `APP_INFO` | `ed8b1352-5aa7-4155-b7c9-521292dd1932` | write，UTF-8 明文补 NUL 到 32 B |
| `FRIENDLY_NAME` | `05a797b6-9c2f-4d18-99a7-fa61a3880bfe` | write，设备名（编码后） |
| `PAIRING_INIT` | `36f99090-e79b-4060-9ac7-89f3f8bf88d5` | write，`0x02` 提交应用级注册 |
| `ACTION_MODE` | `7644371c-1ddc-4b16-832f-f07c322e311b` | write，`0x01`，可重复写 |
| `AP_STATE` | `dcba3a74-80bc-4919-8ef4-0c9f99cc20dd` | notify，`0x03` = AP 就绪 |
| `ACTION_MODE_RESULT` | `6c875728-7636-425e-818a-f1d93a39e075` | notify，`0x00` = 动作完成 |
| `WIFI_SSID` / `WIFI_PASSWORD` | `657edba2-5bc8-42dd-974f-21871d7dbcd1` / `42d509f7-f122-4816-92d1-5e402d9453cb` | read，配网凭据 |
| `CERT_FINGERPRINT` / `SERVER_URL` / `SD_SLOT_INFO` | `1be8a9e3-178b-46c4-b6b3-43d4a5311fc1` / `5c565e17-8fba-4aec-b863-32b9b318bfbd` / `d6bbd828-eb91-4b00-acfc-b2c5821ff0f7` | read：证书指纹、服务 URL、槽位清单 |
| `CAMERA_OPERATE_NOTIFICATION` | `16726c35-52ef-4d00-868d-099549a90d9b` | notify，固件写入进度 |

（以上均见 `LumixImportPrototype.ets:344`–`:378`，索引在 `LumixImportPrototype.ets:2463`。）

### 2.3 注册时序

LUT/控制身份注册走 `registerLutIdentityOnce()`（`LumixImportPrototype.ets:838`）：

1. 若存在图传线保留的 GATT 链路，先释放，避免在已注册链路上重复提交（`LumixImportPrototype.ets:848`；注意 wrapper 在保留链路存在时已提前返回，见 §2.5）。
2. 扫描取 `deviceId`；读系统 bond 状态，但**不调用** `pairDevice()`（`LumixImportPrototype.ets:857`、`:2393`）。
3. `connectGatt()`，失败重试一次（`LumixImportPrototype.ets:865`、`:2411`）。
4. `getServices()`，索引特征；缺 `INITIAL_INFORM/APP_UUID/ACTION_MODE` 直接失败（`LumixImportPrototype.ets:866`）。
5. 使能 `ACTION_MODE_RESULT` 与 `AP_STATE` 通知，并读 `INITIAL_INFORM`（`LumixImportPrototype.ets:893`、`:895`）。
6. 写 `APP_UUID`：16 字节 UUID → 协议串编码 → 与种子异或（`LumixImportPrototype.ets:896`）。
7. 依次写 `APP_INFO`（明文 UTF-8，截断/补零到 32 B）与 `FRIENDLY_NAME`（UTF-8 → 协议串编码 → 异或）（`LumixImportPrototype.ets:901`、`:904`）。
8. 写 `PAIRING_INIT = 0x02`；相机若已注册会拒绝，按「已注册」容忍（`LumixImportPrototype.ets:911`）。
9. 写 `ACTION_MODE = 0x01`，随后最多等 15 s，任一通知 `AP_STATE=0x03` 或 `ACTION_MODE_RESULT=0x00` 即认为 AP 就绪（`LumixImportPrototype.ets:923`）。

编码细节：`encodeProtocolString` 为「1 字节长度 + 数据 + 0 填充到 4 字节块 + 末块 `0xff` 填充」（`LumixImportPrototype.ets:4246`）；`xorReverseWithInitial` 把每个 4 字节块反序后与 `INITIAL_INFORM[0..3]` 异或（`LumixImportPrototype.ets:4262`）。`APP_INFO` 是唯一不走编码的注册写，直接 32 字节定长（`:901`、`:4276`）。

### 2.4 系统配对与失败语义

`ensurePaired()` 只读 `connection.getPairState()`：已 bonded 返回 true，否则记录「OS PIN pairing skipped」并继续 GATT（`LumixImportPrototype.ets:2393`）。注释说明通用 `pairDevice()` 会弹相机不接受的 PIN 框，因此应用级 GATT 注册才是这条线的「配对」。

注册失败码 `2900099` 在真机上出现在「在已注册链路上重复写 `36f99090` 或 `ACTION_MODE`」的场景（`LumixImportPrototype.ets:842`、`:914`）。控制线的注册是 best-effort：`registerIdentityOverBle()` 捕获所有异常，只记日志（`LumixControlService.ets:1125`）；成功则等相机网络回来，最多 30 s，因为注册提交可能让相机重启 AP（`LumixControlService.ets:1112`、`:1131`）。

### 2.5 控制线的 BLE 边界（重要）

- 控制线使用自己的 UUID：`preferences` 库 `vivid_camera_control` 的 `clientUuid`，值为去掉连字符的 32 位十六进制；生成失败时退回常量 `vividctrl00000000000000000000000`（`LumixControlService.ets:1078`）。
- 注册时把该 UUID 与官方 `AppInfo='LUMIX LUT Creators APP 3.0.1'`、`FriendlyName='Pixelshop HarmonyOS'` 一起交给 `registerLutIdentity()`（`LumixControlService.ets:613`、`:1120`）。
- 但 `registerLutIdentity()` 在检测到图传线保留链路时**直接返回 false，不注册**（`LumixImportPrototype.ets:823`）。图传握手成功后链路会被保留（`LumixImportPrototype.ets:1808`），因此实际常见路径是「跳过控制 UUID 注册，直接 `/auth`」。这与「相机用注册记录门控 remote 端点」的注释存在张力，列入 §8 风险。
- 控制线**不读取** `WIFI_SSID/WIFI_PASSWORD`；Wi-Fi 关联由图传线的 BLE 流程完成（读两特征、用 `INITIAL_INFORM` 解码密码，`LumixImportPrototype.ets:1514`、`:2576`）。`LumixControlService.networkBase()` 只读取当前已连 SSID 与 DHCP 网关（`LumixControlService.ets:941`）。

## 3. Wi-Fi 传输

### 3.1 AP 形态

- SSID 必须通过 `identifyWifiSsid()`：`matchesPanasonicName()` 要求 `^TOKEN[-_][A-Z0-9]{3,}…$`，可带 `LUMIX/PANASONIC/PANA/DC/DMC/CAMERA` 前缀（`LumixCameraService.ets:523`、`:2088`）。注意注释记录的可见 AP SSID `S1A0EAA4BD` 不带分隔符（`LumixImportPrototype.ets:2816`），按当前正则无法通过；若真机确为这种形态，控制会停在 `ssid` 阶段（推断，待验证）。
- 主机地址不是硬编码：取当前 Wi-Fi 的 DHCP 网关，按网络序拼成点分 IPv4（`LumixCameraService.ets:1959`）。注释记录相机 AP 是隔离网段 `192.168.54.1/24`、无上行（`CameraPage.ets:1800`），因此固件下载必须先断开相机 Wi-Fi（`CameraPage.ets:1828`）。密码来自 BLE 特征，`securityType` 取自扫描结果，开放网络留空密钥（`LumixImportPrototype.ets:1515`、`:2951`）。

### 3.2 HTTPS 与自签证书

所有请求固定 `https://${host}${path}`，不写端口，即默认 443（`LumixControlService.ets:1046`）。控制线把相机当作专用点对点网络上的自签设备，`remoteValidation` 一律返回 true，**不做证书链校验、也不做指纹固定**（`LumixControlService.ets:1044`）。对照：图传线把 BLE 读到的 `CERT_FINGERPRINT` 规范化后用于 `validateCertificate()`（`LumixImportPrototype.ets:1518`、`:3097`）。这是两条线在 TLS 信任模型上的实质差异。

### 3.3 会话与身份

| 项 | 值 | 出处 |
|---|---|---|
| `AppInfo` | `LUMIX LUT Creators APP 3.0.1` | `LumixControlService.ets:613` |
| `FriendlyName` | `Pixelshop HarmonyOS` | `LumixControlService.ets:616` |
| 客户端 UUID | 每安装持久化、32 位 hex、独立于图传/LUT 线 | `LumixControlService.ets:1078` |
| 令牌/头 | `/auth` 的 `Data.AuthToken`；发送时字面量为 `'Bearer <token>'`（**含单引号**，官方插桩实证） | `LumixControlService.ets:957`、`:1020` |
| 会话重开 | 401 时用同一 UUID 重新 `/auth`，跳过 BLE 注册 | `LumixControlService.ets:653` |

### 3.4 请求与响应信封

统一为 `POST` + JSON，响应 `{Data:{…},Header:{ResponseCode,Messages}}`：

| 端点 | 请求体 | 响应数据 | 出处 |
|---|---|---|---|
| `/auth` | `{AppInfo,FriendlyName,Uuid}` | `Data.AuthToken` | `LumixControlService.ets:556` |
| `/remote/camcmd` | `{Command}` | `Data.Result` | `LumixControlService.ets:591` |
| `/remote/set-setting` | `{Type,Value,Value2?}` | `Data.Result` | `LumixControlService.ets:562` |
| `/remote/get-setting` | `{Type}` | `Data.DataList` 或 `Data[Type]` | `LumixControlService.ets:744` |
| `/remote/get-state` | `{}` | `Data` 的 33 字段（注释） | `LumixControlService.ets:698` |
| `/remote/camctrl` | `{Type:"touch",Value:"x/y",Value2:"on" 或 "off"}` | `Data.Result` | `LumixControlService.ets:834` |
| `/remote/start-stream` | `{UDPPortNumber}` | `Data.Result` | `LumixControlService.ets:843` |
| `/remote/get-lvport` | `{}` | `Data.LvPort` 或裸 `{LvPort}` | `LumixControlService.ets:866` |
| `/remote/stop-stream` | `'{}'`（见 §8） | 无（空闲时 403） | `LumixControlService.ets:856` |
| `/lut/info` | `{}` | `Data.DataList`（41 槽） | `LumixControlService.ets:895` |
| `/lut/set-display-setting` | `{LutId,Visibility}` | `Data.Result` | `LumixControlService.ets:928` |

`parseData()` 的容错规则：`Header.ResponseCode` 存在且不等于 200 才视为拒绝（成功的 `/lut/info` 会完全省略 Header）；裸 `{LvPort:N}` 也接受；`Result` 存在且非 0 才抛错（`LumixControlService.ets:978`、`:1005`）。

### 3.5 HTTP 细节

- 空请求体必须传 `''`，让协议栈发出 `Content-Length: 0`；空 `ArrayBuffer` 会被相机回 411，且该运行时 `TextEncoder.encode('')` 返回 undefined（`LumixControlService.ets:1024`）。`connectTimeout/readTimeout` 均 15 s（`:1039`）。
- 流相关调用（start-stream/get-lvport/get-state/stop-stream）共用一个 keep-alive `HttpRequest`，官方也是单条 TCP；start-stream 的 TCP 若关闭，相机可能连带拆掉取景流（`LumixControlService.ets:51`、`:677`）。普通调用每次新建并在 `finally` 销毁（`:1071`）。

## 4. 取景：UDP + DTLS 1.2

### 4.1 启动顺序

控制页的实际顺序（`CameraControlPage.ets:478`）：

| 步 | 动作 | 关键点 |
|---|---|---|
| 1 | `openSession` | BLE 注册（best-effort）→ `/auth`；失败 800 ms 后重试一次 |
| 2 | `openControlClient` | 单条 keep-alive 连接 |
| 3 | `stopStream` | 清掉残留流，403 `err_critical` 被忽略 |
| 4 | `camcmd recmode` | 重试 3 次，间隔 1 s（切模式约 0.9 s） |
| 5 | `primePipeline` | 19 个 `get-setting`，缺此步 `get-lvport` 会永久 403 `err_busy` |
| 6 | UDP `bind(1235)` | 冲突时端口 +2，最多 8 次；绑定到 Wi-Fi 网络 |
| 7 | `start-stream` | 上报本地 UDP 端口 |
| 8 | `get-lvport` | 相机侧源端口；403 每 100 ms 重试，共 25 次 |
| 9 | `primePostLvport` | 8 个能力键（含重复），对齐官方黄金会话 |
| 10 | `startDtls(host, lvPort)` | 12 s 握手超时 |
| 11 | `resume()` | 8 s 无帧看门狗；之后 1 Hz `get-state` |

本地端口 1235 来自官方 h2 插桩；早期 1234 在真机上永久 `err_busy`（`CameraControlPage.ets:505`、`LumixControlService.ets:1222`）。UDP socket 必须 `bindSocket()` 到 Wi-Fi bearer，否则有 SIM 时流量走蜂窝，相机流永远到不了 socket（`LumixControlService.ets:1269`）。绑定后还有一个 127.0.0.1 回环自检，用于区分「收包路径坏了」与「相机没发」（`LumixControlService.ets:1319`）。`probe()` 仍保留，但 DTLS 线路下相机在握手完成前不发任何数据，明文探测无效（`LumixControlService.ets:1361`）。

### 4.2 DTLS 1.2 参数

`DtlsClient.ets` 是按官方 APK 的 UDP 流量复刻的最小客户端（`DtlsClient.ets:6`）：

| 项 | 值 | 出处 |
|---|---|---|
| 版本/套件 | DTLS 1.2，`TLS_RSA_WITH_AES_128_GCM_SHA256`（`0x009c`） | `DtlsClient.ets:43` |
| 服务器证书 | 自签；只做 DER 解析取 SPKI，**不校验链/主机名** | `DtlsClient.ets:10`、`:668` |
| 客户端证书 | 空证书（3 字节 `000000` 体），与官方一致 | `DtlsClient.ets:233` |
| Cookie | 处理 HelloVerifyRequest 后重发 ClientHello（msg_seq=1）；CH 记录版本 `fe ff`，之后 `fe fd` | `DtlsClient.ets:139`、`:183` |
| 密钥块 | 40 B：client_key 16 + server_key 16 + client_iv 4 + server_iv 4 | `DtlsClient.ets:249` |
| 记录头 | 13 B：type(1) ver(2) epoch(2) seq(6) len(2) | `DtlsClient.ets:12` |
| AEAD | 显式 nonce 8 B + 密文 + tag 16 B；AAD 13 B | `DtlsClient.ets:14` |
| RSA | 先 `RSA2048`，失败退 `RSA1024`，PKCS#1 v1.5 | `DtlsClient.ets:724` |
| 超时 | 总握手 12 s；等包 1.5 s/4 s/5 s，ClientHello 最多重发 6 次 | `DtlsClient.ets:134` |
| 重放 | 仅接受 `seq > lastServerSeq` 的 epoch-1 应用数据 | `DtlsClient.ets:350` |

ClientHello 的 cipher/extension 尾部逐字节照抄官方抓包，只改 random 与 cookie（`DtlsClient.ets:57`）；这样相机才会应答这套精确字节序列。

### 4.3 记录 = 一个 Panasonic 分片

解密后的应用数据**就是**分片本身，没有 RTP 层；`header[0..1]` 的分片总长等于记录长度，magic 在偏移 9（`LumixControlService.ets:34`、`:1565`）。32 字节头按大端解释：

| 偏移 | 长度 | 含义 | 读取处 |
|---|---|---|---|
| 0..1 | 2 | 分片总长（用于截断尾部填充） | `LumixControlService.ets:1588` |
| 4..7 | 4 | 分片序号 `seq`（`0xffffffff` 为复位标记） | `LumixControlService.ets:1597` |
| 8 | 1 | 标志；bit0=1 表示还有后续分片，0 表示最后一分片 | `LumixControlService.ets:1598`、`:1645` |
| 9..17 | 9 | magic `fc 84 a7 d0 ba 76 00 21 ff` | `LumixControlService.ets:1176` |
| 22..25 | 4 | 整帧 JPEG 总长 | `LumixControlService.ets:1635` |
| 26..29 | 4 | 本分片数据在 JPEG 中的偏移 | `LumixControlService.ets:1672` |
| 30..31 | 2 | 元数据长度 | `LumixControlService.ets:1599` |

其余字节代码未读取，不做推断。JPEG 数据从 `32 + metaLen` 开始（`LumixControlService.ets:1600`）。

### 4.4 重组规则

- `seq == 0xffffffff`：自包含完整帧，先丢弃半成品再直接发帧（`LumixControlService.ets:1627`）。
- `seq == 0`：帧头。读总长（`0` 或超过 8 MiB 判损坏）、分配缓冲、`expectedSeq=1`；每片都带完整前缀（32 B 头 + 元数据），取最后一片作为整帧前缀（`LumixControlService.ets:1633`、`:1682`）。
- 后续必须是 `expectedSeq`，断裂即丢整帧（`LumixControlService.ets:1654`）；magic 不匹配时退回结构校验（帧头紧跟 JPEG SOI、续片接期望序号，`LumixControlService.ets:1617`）。收齐且 `jpegFilled == 总长` 才发帧并校验 JPEG 头尾；尺寸从 SOF 扫描，缺省 640×432（`LumixControlService.ets:1697`、`:1710`、`:1850`）。

### 4.5 Q0 元数据

`parseMeta()` 从偏移 32 开始游标式解析，所有读取都有边界检查，截断时返回已解出的字段（`LumixControlService.ets:1740`）：

| 字段 | 偏移/条件 | 解码 |
|---|---|---|
| `zoomPos` | 固定头 +4 | u8 |
| 对焦框数 | 固定头 +15 | 每框 16 B，整块跳过 |
| `avCur256` / `tvCur256` | Av/Tv/Sv 块 +8 / +20 | u16 / **i16**，APEX×256 |
| `focusDistance` | 曝光字节后 +1 | u16 |
| 图标 | `nic` 字节 + 图标区 | 整块跳过 |
| `nsv` | 固定 28 B 之后 | u8，设置块入口 |
| `exposure` | 设置块 +0 | u16（`0xffff` 时用头部曝光字节） |
| `iso` | +4 | **u32**（`0xffffffff`=AUTO） |
| `whitebalance` | +10 | u16 |
| `recmode2` | +14 | u16 |
| `photostyle` | +18，`nsv>=20` | u16 |
| `quality` | +22 | u16 |
| `aspect` | +28 | u16 |
| `metering` | +34 | u16 |
| `liveviewsize` | +36 | u8 |
| `operate` | +38 | u8，`1`=手机优先 |
| `pictureFormat` | +54，`nsv>=56` | u16 |

设置块实际 75 B，而 `numSettingValue` 只数到 73（`0x49`），`focusStacking/cropZoom` 在计数之外；`iso` 是 4 字节字（`LumixControlService.ets:40`、`:1797`）。`LumixLiveviewInfo` 所有字段必须是 `@Track`，否则 UI 访问会抛 `Illegal usage of not @Track'ed property`，历史上表现为控制页卡死/点参数闪退（`LumixControlService.ets:102`）。

## 5. 控制

### 5.1 `camcmd`

服务注释声明支持 `recmode/playmode/capture/capture_cancel/touchafrelease/video_recstart/video_recstop`（`LumixControlService.ets:808`）。实际 Lab 调用点：

| 命令 | 调用点 | 备注 |
|---|---|---|
| `recmode` | `CameraControlPage.ets:490` | `retries=3`，仅 HTTP 类错误重试，间隔 1 s |
| `capture` | `CameraControlPage.ets:2425` | 成功后 280 ms 发 `capture_cancel` |
| `capture_cancel` | `CameraControlPage.ets:2430` | 释放快门状态 |
| `video_recstart` | `CameraControlPage.ets:2468` | 录像开始 |
| `video_recstop` | `CameraControlPage.ets:2460` | 录像停止 |
| `playmode` / `touchafrelease` | 无 Lab 调用点 | `playmode` 由 Sync 线使用；触屏对焦走 `camctrl` |

### 5.2 `set-setting`

| `Type` | 值域/取值 | 调用点 |
|---|---|---|
| `exposure` | `0x0000` 为中心、bit15 为负、单位 1/3 EV | `CameraControlPage.ets:2594` |
| `iso` | `0xffffffff`=AUTO，否则 ISO 数值 | `CameraControlPage.ets:2591` |
| `shtrspeed` | `N/256` 或 32 位毫秒编码（B 门/AUTO 有哨兵值） | `CameraControlPage.ets:2597` |
| `whitebalance` | 16 位编码（如 `0x0002` 自动、`0x8014` 自动冷） | `CameraControlPage.ets:2588` |
| `recmode2` | 曝光模式（P/A/S/M/C1…） | `CameraControlPage.ets:2585` |
| `aspectratio` | `0x0001..0x000b` | `CameraControlPage.ets:2582` |
| `quality` / `pictureformat` | S5M2 用 `quality`；探测到 `pictureformat` 值域后切键 | `CameraControlPage.ets:2579`、`:1088` |
| `liveviewsize` | `0x00/0x01/0x02` 流畅/标准/精细 | `CameraControlPage.ets:2574` |
| `lightmetering` | 测光模式 | `CameraControlPage.ets:2571` |
| `photostyle` | PhotoStyle 值（含 LUT 风格） | `CameraControlPage.ets:2567` |
| `operatepriority` | `0x00` 机身 / `0x01` 手机；当前无 UI 调用 | `CameraControlPage.ets:2385` |

`applySetting()` 会先把请求体写日志，因为 S1RM2 对未知键回 `200/Result=0` 却不生效，而 hilog 会截断响应体（`LumixControlService.ets:798`）。

### 5.3 `get-state`

注释说心跳有 33 个字段（`LumixControlService.ets:26`、`:83`），`ControlData` 只声明了 16 个状态字段（`:517`–`:532`），`fetchState()` 映射其中 7 个：`cammode`、`sd_access`、`sd2_access`、`sd_full`、`sd2_full`、`current_sd`、`camera_operating`（`:698`）。UI 实际消费的只有 `sd_access/sd2_access`：录像中两张卡都无活动超过 4 s，则判定机身已停止录像（`CameraControlPage.ets:1029`）。其余状态显示来自 Q0 元数据，而不是 `get-state`。

### 5.4 `camctrl` 触屏对焦

请求体 `{"Type":"touch","Value":"x/y"}` 加 `Value2` 为 `"on"` 或 `"off"`，坐标是取景图像素坐标（`LumixControlService.ets:834`）。UI 按官方节奏发四帧：按下→60 ms→抬起→60 ms→按下→60 ms→抬起，失败静默（`CameraControlPage.ets:2347`）。

## 6. LUT 通道

- `/lut/info`：`{}` → `Data.DataList`，注释记 41 个槽位（`LumixControlService.ets:31`）。每条记录取 `LutId/LutName/LutType/PhotoStyle`，`LutType` 缺省按 3 处理，名字为空则标 `empty`，最后按 `LutId` 升序（`LumixControlService.ets:895`）。`LutType` 语义：1=VLog_709 内置、2=ARRI 709 内置、3=用户槽（`LumixLutService.ets:31`）。
- `/lut/set-display-setting`：`{LutId,Visibility}`，`Visibility` 为 1/0（`LumixControlService.ets:928`）。
- S1RM2 例外：该机身没有 `/lut/set-display-setting`，内置风格 LUT（`LutType=1`）改走 `set-setting photostyle`，实测 `VIVID=0x0001`（`LumixControlService.ets:377`）。
- 控制线的 LUT 调用复用控制会话令牌；独立的 `LumixLutService` 有自己的 `/auth`、自己的 UUID 库 `vivid_lut_transfer`（`LumixLutService.ets:122`、`:610`），两者不要混用身份。

固件通道只在此说明边界：它同样走相机 HTTPS（`/firmware/send-prepare`、`/firmware/send`、`/firmware/abort-send`），进度靠 BLE notify `16726c35`（值 1=写入、2=完成），固件目录来自 `panasonic.jp` 且需要 Basic 凭据（`LumixFirmwareService.ets:1`、`:36`）。相机 AP 无上行，下载前必须断开相机 Wi-Fi（`CameraPage.ets:1800`）。

## 7. 实现对照表

| 文件 | 职责 | 关键常量/入口 |
|---|---|---|
| `LumixControlService.ets` | Lab 控制面、HTTP 信封、LUT 槽位、UDP/DTLS 取景接收与 Q0 解析 | `CONTROL_APP_INFO`、`FRAG_MAGIC`、`STALL_AFTER_MS=8000`、`MAX_JPEG_BYTES=8 MiB` |
| `DtlsClient.ets` | DTLS 1.2 客户端：cookie、RSA 密钥交换、AES-128-GCM、Finished 校验 | `CIPHER_RSA_AES128_GCM=0x009c`、12 s 握手预算 |
| `LumixCameraService.ets` | 三线机型分区、SSID/网关读取、cam.cgi 探测、BLE 能力谓词 | `PANASONIC_*_MODEL_TOKENS`、`isCamCgiRoute(route)`、`needsBlePairing(route)` |
| `LumixImportPrototype.ets` | 共享 BLE 扫描/注册/配网、图传会话、固件特征读取 | `BLE_SCAN_SERVICE`、`BLE_SERVICE`、`UUID_*`、机型码表 |
| `LumixLutService.ets` | 独立 LUT 传输线（`/auth`、`/lut/send*`、delete/rename/file） | `LUT_APP_INFO`、`vivid_lut_transfer` |
| `LumixFirmwareService.ets` | 固件目录/下载/分块上传 | `SHARE_BASE`、`/firmware/send-prepare`、`WRITE_DONE_TIMEOUT_MS` |
| `CameraControlPage.ets` | Lab 控制页状态机：会话、能力表、取景、拍摄、触屏 | 端口 1235、1 Hz 心跳、AUTO 重连 |
| `CameraSessionStore.ets` | 三线判定与 UI 选择状态 | `panasonicLine()`、`isCamCgiLineSelected()` |

## 8. 限制与风险

1. **控制线不校验证书**：`remoteValidation` 恒为 true（`LumixControlService.ets:1044`），而图传线做了指纹固定（`LumixImportPrototype.ets:3097`）。同一台相机上两条线的信任强度不一致，中间人可在控制线被接受。
2. **UUID 注册可能被跳过**：保留链路存在时 `registerLutIdentity()` 直接返回 false（`LumixImportPrototype.ets:823`），而 `/remote/*` 使用控制线自己的 UUID（`LumixControlService.ets:958`）。若相机严格按注册记录门控，会出现「图传正常、控制 401/403」的组合故障。这是推断，需真机对照日志确认。
3. **403 有两种语义**：`stop-stream` 在无流时回 403 `err_critical`，代码忽略（`LumixControlService.ets:854`）；`get-lvport` 在 start-stream 后短暂回 403 `err_busy`，代码每 100 ms 重试 25 次（`:866`）。两者都以 HTTP 状态码进入 `LumixControlError.code`，调用方必须按端点区分，不能只看 403。
4. **`stop-stream` 注释与代码不一致**：注释说官方请求体为空（非 `"{}"`），代码实际发送 `'{}'`（`LumixControlService.ets:859`）。当前依赖相机宽容；若某固件严格区分，需要按抓包改。
5. **`Result=0` 不等于生效**：S1RM2 对未知 `set-setting` 键回 200/Result=0 但不改变设置（`LumixControlService.ets:798`）；`quality` 在 S1RM2 上全 200 无效，必须切 `pictureformat`（`CameraControlPage.ets:1080`）。面板值应以 Q0 回读为准。
6. **`get-state` 建模不完整**：注释 33 字段，代码只声明 16、映射 7（`LumixControlService.ets:517`、`:698`）。依赖未建模字段的功能不会存在。
7. **DTLS 无重传/无缓存**：应用数据只接受严格递增的 epoch-1 序号（`DtlsClient.ets:350`），乱序或迟到记录被永久丢弃；分片层一旦序号断裂就丢整帧（`LumixControlService.ets:1654`）。弱 Wi-Fi 下表现为花屏/卡顿而非重传恢复。
8. **只实现 RSA 套件**：服务器若选 ECDSA 套件会直接报「未知套件」（`DtlsClient.ets:226`）。当前真机均选 `0x009c`，但这是固件差异的潜在断点。
9. **端口与网络绑定**：UDP 端口 1235 冲突时 +2（`LumixControlService.ets:1227`），若系统占用了整段端口会绑定失败；未绑定 Wi-Fi bearer 时相机的流不会到达 socket（`:1269`），这是现场「pkts=0」的常见原因。
10. **机型表与任务清单不一致**：Lab 表是 `L10` 而非 `G10`（`LumixCameraService.ets:302`）。`identifyWifiSsid()` 也没有 G10 条目（`:2095`），因此即使真相机存在，当前也会落到 Image App 兜底。
11. **固件/配网对 BLE 的独占**：注册提交可能让相机重启 AP，控制线最多等 30 s（`LumixControlService.ets:1112`）；固件写入依赖同一条 BLE 通知链路（`LumixFirmwareService.ets:14`），与控制会话并发时存在互相打断的风险。

## 9. 待真机确认（均标注为推断）

- 控制 UUID 未注册时 `/remote/*` 是否仍可用；用同一台机对比「先图传后控制」与「只控制」的 `/auth` 与 `camcmd` 响应。
- 33 字段 `get-state` 的完整键名与类型；当前只能从 16 个声明字段反推。
- `get-lvport` 返回裸 `{LvPort}` 的机型分布；代码同时接受两种形状（`LumixControlService.ets:976`）。
- 分片头偏移 2..3、18..21 的语义；代码未读取，不能从现有实现推断。
- 不同固件对 `stop-stream` 空体与 `'{}'` 的接受度。
