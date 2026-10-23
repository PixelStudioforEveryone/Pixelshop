# 富士 FUJIFILM X 系列 · BLE + 私有 PTP-IP 技术报告

> [English](en/06-fujifilm-x.md) | 简体中文

> 基线提交 `18466be`。只读 `entry/src/main/ets/services/Fujifilm*.ets` 与 `docs/fujifilm/`，未接相机、未改代码。数值均可在 `FujifilmProtocol.ets` 或 `docs/fujifilm/NOTES_*.md` 找到出处；注释与 NOTES 标为【推断】/【未知】的，本文同样标注。逆向报告原件（`Fujifilm\apk\reports\00–04`、`data\*.csv`）不在本工作区，本文只转述 NOTES 已记录的部分，不替它补细节。

## 1. 线路定位

### 1.1 五条线并列时的位置

| 线路 | 传输 | 端口 | 结构化程度 |
|---|---|---|---|
| 松下 LUMIX | SSDP 发现 + `cam.cgi` HTTP + DLNA | 80 | 公开 HTTP 接口（`LumixCameraService.ets:348,406`） |
| 尼康 | 标准 PTP-IP（ISO 15740） | 15740 | 标准帧 + 私有 LSS 配网（`NikonPtpIpService.ets:492`） |
| 索尼 | 复用尼康 15740 传输层，加 SDIO 私有设置/内容层 | 15740 | 私有码叠在标准帧上（`SonyPtpIpContent.ets:1166`） |
| 佳能 | 标准 PTP-IP（ISO 15740 / CIPA DC-X005） | 15740 | 标准帧 + EOS 私有码（`CanonPtpIp.ets:466`） |
| **富士** | **BLE 配网 + 私有 PTP-IP 三通道** | **55740 / 55741 / 55742** | 12 字节头沿用 CIPA，端口、初始化载荷、控制码全部私有（`FujifilmProtocol.ets:102-104`） |

富士与其他四条线最实质的差别不在帧格式，而在端点切分：控制与事件各占一条 socket，实时取景再占 55741，且取景是常驻"整帧阻塞读"而不是"发命令取一帧"（`FujifilmPtpIp.ets:1-20`）。三路互不阻塞，取景通道随时可单独关掉。

### 1.2 机型识别（`FujifilmModels.ets`）

机型名在三条链路上形态不同：BLE 老协议是"前 4 字符短序列号 + 机型"（`FujifilmBleService.ets:316-328`），RED 是整串机型、短序列号在 `mf[1..5]`（`:294-298`），Wi-Fi SSID 是 `FUJIFILM-<机型>-<后缀>`（`FujifilmModels.ets:41-42`），PTP DeviceInfo/0x2A24 是官方写法（`:8-11`）。

匹配用"精确 → 最长包含"，而非素材表的宽松匹配：后者会让 `GFX100II 6A0123` 抢先命中排在前面的 `GFX 100`（`FujifilmModels.ets:14-20,110-141`）。产出 `imageKey='fujifilm_<slug>'`，品牌恒为 `'FUJIFILM'`（`:34-38`）。素材表 85 条：X 系列 46、GFX 6、instax 31、`Other` 与 `Unknown` 兜底各 1；未收录落 `fujifilm/generic.png`（`:186-198`）。

## 2. BLE 广播与识别

### 2.1 厂商数据布局

Company ID 固定 `0x04D8`，只作二次校验；代际标记是厂商自定义数据的第 0 字节（`FujifilmProtocol.ets:18,95-96`；`FujifilmBleService.ets:288-304`）：

| 字节 | 老协议（`mf[0]=2`） | RED（`mf[0]=1`） |
|---|---|---|
| `mf[0]` | `0x02` | `0x01` |
| `mf[1..4]` | pairing key（4 B，配对原样回写） | 短序列号第 1–4 字节 |
| `mf[5]` | 电源键状态 | 短序列号第 5 字节 |
| `mf[6]` | — | 电源键状态 |
| 广播名 | 前 4 字符 = 短序列号，其余 = 机型 | 整串 = 机型 |

短序列号：RED 取 `mf[1..5]` 的 ASCII，老协议取广播名前 4 字符（`FujifilmBleService.ets:316-321`）。电源键被解析进 `powerKey`，但当前没有任何判定读取它（同文件 `:70-74`）。

### 2.2 7 个扫描服务 UUID

| UUID | 常量 | 语义 |
|---|---|---|
| `AF854C2E-B214-458E-97E2-912C4ECF2CB8` | `SCAN_UUID_ALWAYS` | 任何模式常驻，识别主依据 |
| `462426E1-D712-4A28-BE62-61A786DAA866` | — | 仅在扫描表，常量表未命名 |
| `731893F9-744E-4899-B7E3-174106FF2B82` | `SERVICE_CAMERA_STARTUP_INFO` | 启动信息 |
| `A9D2B304-E8D6-4902-8336-352B772D7597` | `SERVICE_CAMERA_INFORMATION_RED` | RED 信息服务 |
| `123D8F06-62A1-4935-9322-833C531EE225` | `SERVICE_CONNECTED_DEVICE_INFO_RED` | RED 连接设备信息 |
| `804DAA8E-FFEB-4AB3-8E75-6EDD7303208D` | `SERVICE_CAMERA_STARTUP_INFO_RED` | RED 启动信息 |
| `CC74BD26-4ABB-4911-AE72-9CD93109A772` | — | 仅在扫描表，常量表未命名 |

（`FujifilmProtocol.ets:21-32`。）广播里的 128-bit UUID 是小端序，按 16 字节逆序还原（`FujifilmBleService.ets:330-339`）。识别条件是"厂商 ID = 0x04D8 / 命中常驻服务 / 命中 RED 服务"三选一，**不按名字含 FUJIFILM 判定**，避免把打印机等外设拉进相机列表（`:246-252,288-289`）。

### 2.3 扫描策略

HarmonyOS 同一时刻只允许一轮扫描，因此分三级降级（`FujifilmBleService.ets:130-211`）：带 7 个 `serviceUuid` 过滤启动 → 被拒则全量扫描并在回调里自行过滤 → 仍被拒则复用页面已有扫描的回调，只 `off` 自己的监听，绝不 `stopBLEScan()` 打断松下扫描。

单轮 60 s 后重启，只重启自己拥有的那一轮（`:79-91,152-157`）；同一机身 3 s 内重复上报被丢弃（`:84,230-232`）。

## 3. GATT 表

### 3.1 服务

| 服务 | UUID | 说明 |
|---|---|---|
| `SERVICE_CAMERA_CONTROL` | `6514EB81-4E8F-458D-AA2A-E691336CDFAC` | 相机控制 |
| `SERVICE_CAMERA_STATE` | `4C0020FE-F3B6-40DE-ACC9-77D129067B14` | 状态 |
| `SERVICE_CAMERA_SETTING` | `4E941240-D01D-46B9-A5EA-67636806830B` | 设置 |
| `SERVICE_CAMERA_INFORMATION` | `117C4142-EDD4-4C77-8696-DD18EEBB770A` | 身份信息 |
| `SERVICE_CAMERA_INFORMATION_RED` | `A9D2B304-E8D6-4902-8336-352B772D7597` | RED 变体，同时是扫描 UUID |
| `SERVICE_CONNECTED_DEVICE_INFO` | `91F1DE68-DFF6-466E-8B65-FF13B0F16FB8` | 已连接设备 |
| `SERVICE_CONNECTED_DEVICE_INFO_RED` | `123D8F06-62A1-4935-9322-833C531EE225` | RED 变体，同时是扫描 UUID |
| `SERVICE_CAMERA_STARTUP_INFO` | `731893F9-744E-4899-B7E3-174106FF2B82` | 启动信息 |
| `SERVICE_CAMERA_STARTUP_INFO_RED` | `804DAA8E-FFEB-4AB3-8E75-6EDD7303208D` | RED 变体 |

（`FujifilmProtocol.ets:35-43`。）服务与特征的父子关系没有被固化：`findCharacteristic()` 遍历全部已发现服务按 UUID 查特征（`FujifilmBleService.ets:459-468`）。本工作区的常量与文档都没有这张映射，本文不补。

### 3.2 特征

| 用途 | UUID | 方向 | 使用点 / 现状 |
|---|---|---|---|
| 配对密钥回写 | `ABA356EB-9633-4E60-B73F-F52516DBD671` | 写 | `pair()`：老协议 4 B / RED 5 B（`:487-529`） |
| Wi-Fi SSID | `BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4` | 读 | `readWifiCredentials()`（`:578-605`） |
| Wi-Fi 密码 | `E809256A-915C-4967-92E8-53B7D4CAD213` | 读 | 同上，敏感值只记长度 |
| 功能拉起 | `600655E6-3637-42F1-8FB2-44EFC5C63B13` | 写 u16 LE | `launch()`，仅 3/4/5（`:612-629`） |
| AP 状态 | `A68E3F66-0FCC-4395-8D4C-AA980B5877FA` | 通知 | 连接时唯一订阅（`:385,431-440`） |
| Wi-Fi MAC | `49A12959-DFAA-4EB2-89CE-62548AD948F3` | 读 | `readIdentity()`（`:544`） |
| 序列号 | `E8E40D50-A625-4F1D-96ED-8CEC034F5690` | 读 | 失败回退 0x2A25（`:538-541`） |
| Y 号 | `27870478-94A9-4345-849B-EFA3BF37887F` | 读 | 常量已补；实现仍用同值本地常量（`:116-124,545`） |
| RED App 信息 | `8B5ECF55-FC6B-40D0-B4C1-76F64E5453C7` | 写 `80 01 01` | 仅 RED（`:517-522`） |
| RED 设备识别号 | `F557D96B-8284-4667-8793-B971C1DECA2A` | 读 + 写 `0x20000000` | 仅 RED，读回已是该值则跳过（`:498-513`） |
| 固件版本 | `00002A26-0000-1000-8000-00805F9B34FB` | 读 | `readFirmwareVersion()`（`:560-570`） |
| 序列号 / 机型（标准） | `00002A25…` / `00002A24…` | 读 | 序列号与机型兜底（`:540,542-543`） |
| 固件请求 92 B | `B1307521-7AC5-4199-AAEE-9D094781CE69` | 写 | 固件页注入（`FujifilmFirmwarePage.ets:27,99`） |
| 固件文件信息 29 B | `20EA1FAC-19D8-48A8-A80C-535D34300958` | 读 | 同上（`FujifilmFirmwarePage.ets:31`） |
| UTC+时区 / 固件状态 / 镜头固件 | `C52EDBCE-…` / `049EC406-…` / `621A98D8-…` | — | 仅协议常量，无读写调用点 |

（UUID 全表 `FujifilmProtocol.ets:45-79`；UTC 注释提到"老固件退化为 7 B DATE_TIME"。）GATT 连接顺序：连接 → MTU 185 → `getServices()` → 订阅 `AP_STATE`（`FujifilmBleService.ets:345-386`）。`AP_STATE` 通知按 LE u16 解析（`:431-440`），链路断开时清连接态与最后值（`:373-379`）。

## 4. 配对时序

富士没有 PIN、没有系统绑定、没有加密：配对 = 把相机在广播里给出的字节原样写回（`NOTES_A.md §5.3`；`FujifilmBleService.ets:482-529`）。富士线没有 `createBond()` 调用，该词只出现在 `FujifilmBleService.ets:15` 的注释里。

| 步 | 动作 | 失败语义 |
|---|---|---|
| S1 | `connect()`：GATT + MTU 185 + 订阅 `AP_STATE` | 返回 false，不抛 |
| S2 | 取缓存广播里的 `pairingKey` | 无缓存 → false，提示重新扫描 |
| S3 | RED：读 `F557D96B`，≠ `0x20000000` 才写 | 读失败按"未绑定"处理并继续 |
| S4 | 写 `ABA356EB` = 广播 key（RED 即 `mf[1..5]` 五字节） | 写失败 → false |
| S5 | RED：写 `8B5ECF55` = `80 01 01` | 写失败 → false |
| S6 | 读 `BF6DC9CF`（SSID） | 空/异常 → **断开**并抛错 |
| S7 | 读 `E809256A`（密码） | 空/异常 → **断开**并抛错，日志只记长度 |
| S8 | 写 `600655E6` = u16 LE 3/4/5 | 非法值拒绝；未连接直接 false |
| S9 | 轮询 `AP_STATE` 到 `0x8001` | 超时 false，日志带最后值 |

- `launch()` 先把 `apStateValue` 置 -1 再写，避免读到上一轮残留（`:624`）。
- `waitApReady` 是毫秒语义、250 ms 一步；页面给 20 s（`FujifilmBleService.ets:631-644`、`CameraPage.ets:50,6023`）。`0x8002` 只表示"正在启动"。
- 配对失败**不阻断**凭据读取：部分固件拒绝重复写 key，但凭据与 key 无关（`CameraPage.ets:6007-6013`）。
- 密码只作局部变量交给系统关联，不写 preferences、不写会话存储（`NOTES_A.md §5.4`）。固件的 92 B / 29 B 读写走同一把 GATT 串行锁（`FujifilmBleService.ets:650-730`）。
- 热点关联 `securityType: 3`（WPA2-PSK）；`cameraHost` 取 DHCP 网关，取不到才用 `FujifilmNet.HOST`（`CameraPage.ets:6041-6077`）。

## 5. PTP-IP 传输

### 5.1 三端口职责

| 端口 | 常量 | 职责 | 生命周期 |
|---|---|---|---|
| 55740 | `PORT_CONTROL` | Init 握手、OpenSession、全部 PTP 事务 | 随 `connect()` 建立 |
| 55741 | `PORT_LIVEVIEW` | 取景整帧流 | 进预览态才开，切遥控即关 |
| 55742 | `PORT_EVENT` | `Init_Event_Request` 后常驻读事件 | 后台循环，起不来不影响控制 |

（`FujifilmProtocol.ets:102-104`；`FujifilmPtpIp.ets:353-384,629-661,715-743`。）

### 5.2 12 字节包头

所有包统一 `frame(type, field, payload)`：`Length` 含头、`Type` 取 1–12、第三字段随包类型复用（`FujifilmPtpIp.ets:818-836`）：

| 偏移 | 字段 | 取值 |
|---|---|---|
| 0..3 | Length | 整包长度 LE32 |
| 4..7 | Type | 1 Init_Command_Request / 2 Init_Command_Ack / 3 Init_Event_Request / 4 Init_Event_Ack / 5 Init_Fail / 6 Operation_Request / 7 Operation_Response / 8 Event / 9 Start_Data / 10 Data / 11 End_Data / 12 Cancel |
| 8..11 | 第三字段 | Operation_Request = DataPhaseInfo；Start/Data/End_Data = TransactionID；Init 包 = 0 或 connectionNumber |

（Type 常量 `FujifilmProtocol.ets:141-158`。）`Operation_Request` 载荷 = `u16 opcode + u32 transactionId + u32 参数[]`（`FujifilmPtpIp.ets:827-836`）。

### 5.3 初始化

`Init_Command_Request` 载荷固定 68 字节（`FujifilmPtpIp.ets:265-286,387-394`）：偏移 0..15 是 GUID `08 70 B0 61 0A 8B 45 93 B2 E7 93 57 DD 36 E0 50`；16..63 是 UTF-16LE `VIVID Camera Remote App`（23 字符 + `0x0000`）；64..67 是 PTP-IP 版本 `0x00010000`（LE32）。

68 来自 native `MngPTP::Open` 的 `cmp w1,#68`；23 字符让"定长 68"与"GUID + 变长 UTF-16LE 名 + u32 版本"两种解析落到同一串字节——代码里标注的**第 1 处推断**（`FujifilmPtpIp.ets:16-19,265-274`；`NOTES_A.md §3.2`）。回 `Init_Fail`（type 5）取载荷前 4 字节作错误码，不重试。`Init_Command_Ack` 按 "GUID + 名 + 版本" 跳过后读 u32 `connectionNumber`（缺省 1），供事件/取景通道使用（`:415-431`）。

### 5.4 会话与事务

- `OpenSession(0x1002, sessionID=1)`；`0x201E`（会话已开）按成功处理，不重连（`FujifilmPtpIp.ets:364-372`）。
- 事务严格串行（内部 `queue`），TransactionID 自增、`0xFFFFFFFE` 回绕到 1（`:505-511,609-613`）；`Operation_Response` 载荷 `u16 code + u32 tid + 参数[]`，tid 先按偏移 2 读，不符再试偏移 4（个别固件补两位对齐），参数起点随之移动（`:583-607`）。
- 超时：连接 5 s、OpenSession 5 s、单事务 10 s、`InitiateOpenCapture` Phase1 30 s（`FujifilmProtocol.ets:106-114`）。`OPEN_ATTEMPTS=6` 只有常量与注释，未实现重试循环。

### 5.5 数据阶段（512 字节块）

手机→相机：`Start_Data`（载荷 u64 总长）→ 若干 `Data`（每块 512 B，末块可短，最后一包复用 `End_Data`）→ 等 `Operation_Response`（`FujifilmPtpIp.ets:561-581`）。相机→手机：`Operation_Response` 之前的 `Start_Data` 只丢弃载荷（前 8 字节是 u64 总长），`Data` 逐包拼接，`End_Data` 结束（`:526-542`）。块大小 `FujifilmNet.DATA_BLOCK = 512`（`FujifilmProtocol.ets:115-116`）。

`DataPhaseInfo` 是**第 2 处推断**：CIPA 口径 1=无数据 / 2=DataIn / 3=DataOut，协议常量表给的是 0/1/2，差 1。实现默认 CIPA 口径，并在 `connect()` 末尾用 `GetDeviceInfo(0x1001)` 探一次：有数据 → 正确；有应答无数据 → 也算正确（该命令可能本就不带数据）；无应答 → 换另一套编码重连再探；两套都不通只记日志、不判死会话（`FujifilmPtpIp.ets:288-302,433-478`；`NOTES_A.md §3.4`）。

### 5.6 事件通道

`Init_Event_Request` 载荷 = `connectionNumber` LE32，等 Ack 上限 1.5 s；超时或首包即事件都继续读，不判失败（【推断】部分固件不回 Ack，`FujifilmPtpIp.ets:643-660`）。事件载荷 `u16 code + 4 B tid + u32 参数[]`，参数从偏移 6 开始（`:685-701`）。空闲读超时 4 s 属正常轮询，非超时错误才把会话置为不可用（`:663-683`）。

### 5.7 取景

连 55741 后按事件通道同形发一次 `Init_Event_Request`：收到 Ack 记成功；收到帧则暂存后交给首次 `readLiveViewFrame`；超时也继续用该通道（【推断】`FujifilmPtpIp.ets:707-743`；`NOTES_A.md §4.1`）。读帧：读 12 字节头，`Length` 落在 `[12, 204800]` 就按它读，否则按固定 `LIVEVIEW_FRAME_BYTES=204800` 兜底（`:749-776`）。JPEG 起点 = `LE32@12 + 18`，即帧内偏移 12 的 u32 再加 `LIVEVIEW_JPEG_HEADER_BIAS=18`（`:778-790`；`FujifilmProtocol.ets:126-130`）。帧完整性判据与 18 这个偏置均列在 `NOTES_A.md §4.2`【未知】。

### 5.8 断连语义

任一通道读失败、事务超时、事件中断 → `markUnavailable()` → `close()`，之后 `op*` 一律抛"PTP-IP 会话未建立"，由页面重新 `connect()` 重建全链路（`FujifilmPtpIp.ets:846-851`；`ROUTE_SPEC.md §2.1`）。`close()` 不清 `onEvent` 监听器（固件服务跨阶段复用）。

## 6. 控制

### 6.1 模式协商（`FujifilmControlService.connect()`）

| 步 | 动作 | 超时/重试 | 失败处理 |
|---|---|---|---|
| S01 | `FujifilmPtpIp.connect()` | 5 s | 抛错 |
| S05 | `GetDeviceInfo(0x1001)` 解析 Model/Serial | 8 s | 用 BLE 型号兜底 |
| S11 | 等事件 11 | 12 s | **超时降级**，记 `degradedReason` 后继续 |
| S13 | `SetFunctionMode(20, 0xDF28, ≤3)` | 4102/0x2019 ×5 ×100 ms | 抛错 |
| S14 | `SetCameraFunctionMode(6)` → `0x1016 [0xDF00]` | 同上 | 抛错 |
| S15 | `SetFunctionMode(22, 0xDF2A, ≤4)` | 同上 | 抛错 |
| S20 | `GetDevicePropDescAll(0x902B)` | 20 s | 降级，不阻断拍摄 |
| S23 | `InitiateOpenCapture` Phase1 `0x101C` | 30 s | 抛错 |
| S24 | Phase2 = 打开 55741（无第二条 PTP op） | 30 s | 抛错 |
| S29 | 再等事件 11 | 4 s | 没有也继续 |
| S30 | `SetFunctionMode(5)` + `GetFunctionVersion(0xDF25)` + `SetFunctionVersion(0xDF24, 131083)` | 10 s | 只降级 |

（`FujifilmControlService.ets:560-634,668-723,1401-1416`；`NOTES_B.md §3`。）`SetFunctionMode` 写 `0x1016 [0xDF01] + u16`，不是标准 PTP 的 `0x5002`（`FujifilmProtocol.ets:249-261`；`NOTES_C.md §2.1` 有 native 立即数证据）。

### 6.2 操作码

| 码 | 名称 | 用途 |
|---|---|---|
| `0x1001/0x1002` | GetDeviceInfo / OpenSession | 机型序列号；开会话（`0x201E` 容忍） |
| `0x1004-0x1008` | Storage/Object 枚举 | 张数、句柄、对象信息兜底 |
| `0x1009/0x100A/0x101B` | GetObject / GetThumb / GetPartialObject | 整包、缩略图、分块兜底 |
| `0x100E/0x1018/0x101C/0x9030` | 拍摄生命周期 | 快门、结束、准备、取消 |
| `0x1014/0x1015/0x1016` | PropDesc / Get / Set | 属性读写与版本协商 |
| `0x9020/0x9021/0x9022` | Movie / Postview | 录像起停、回看 |
| `0x9023/0x9024/0x9025` | Zoom 三件套 | 变焦（映射冲突见第 9 节第 4 条） |
| `0x9026/0x9027` | Lock/UnlockS1 | S1 对焦 |
| `0x902B` | GetDevicePropDescAll | 全量属性描述符 |
| `0x902C/0x902D/0x902E` | StepShutter/Aperture/EV | 步进 |
| `0x9040/0x9042` + `0x9053-0x9056` | 固件 / 图传扩展 | 推送；日期计数、对象信息、缩略图、分块 |

（`FujifilmProtocol.ets:160-204`；`FujifilmControlService.ets:44-66`。）

### 6.3 属性码

控制页参数目录共 53 条（`FujifilmControlService.ets:298-379`），主要项：

| 组 | 属性（码） |
|---|---|
| 曝光 | 曝光模式 `0x500E`、曝光补偿 `0x5010`（步进 `0x902E`）、快门 `0xD240`（`0x902C`）、光圈 `0x5007`（`0x902D`）、ISO `0xD02A`、动画 ISO `0xD02B`、测光 `0x500B`、快门标准 `0x500D`、曝光指数 `0x500F` |
| 色彩 | 胶片模拟 `0xD001`（1–20）、白平衡 `0x5005`（12 值）、画质 `0x5004`、RGB 增益 `0x5006`、曝光文字颜色 `0xD028` |
| 画质/尺寸 | 像素尺寸 `0x5003`、尺寸代码 `0xD241`（1–34）、对比 `0x5014`、锐度 `0x5015`、效果 `0x5017`、数码变焦 `0x5016` |
| 拍摄 | 闪光 `0x500C`、自拍 `0x5012`（0/2/4）、对焦模式 `0x500A`（1/32769/32770）、驱动 `0xD246`（0/1）、微距 `0xD01D`、连拍/间隔 `0x5018-0x501B`、AF 测光 `0x501C`、录像使能 `0xD019` |
| 对焦 | AF 区域 `0xD245`（0–7）、S1 AF 框 `0xD17C`、AF 合焦 `0xD209` |
| 状态 | 电量 `0x5001`、电量分段 `0xD242`、剩余张数 `0xD229`、剩余录制时间 `0xD22A`、相机状态 `0xD21B`（0–17）、变焦位置 `0xD170`、快门类型 `0xD243`、CCD 模式 `0xD018` |
| 系统 | 功能模式 `0x5002`、焦距 `0x5008`、对焦距离 `0x5009`、日期时间 `0x5011`、上传地址 `0x501D`、作者 `0x501E`、版权 `0x501F`、属性列表 `0xD212`、请求对象 `0xD220`、动画剩余框 `0xD2B7` |

值域只在反汇编/CSV 明确时才写死：`shutterType`、`quality` 枚举留空交给描述符，`afSelect` 只标序号不编名称（`FujifilmControlService.ets:286-296`；`NOTES_B.md §5.1`）。`0x902B` 的 8 字节记录头（`code u16 | getSet | rsv | type u16 | size u16` + payload）由反汇编确认，但 `getSet` 位置有三种可能排布，解析器三种都试、取条数最多的一张；`getSet` 全 0 时按目录的已知可写项降级（`:818-899`；`NOTES_B.md §2.1-2.3`）。

### 6.4 写值、步进与动作

- `setValue(code, value)`：`0x1016 [code] + 该属性 dataType 宽度的 LE 标量`；成功即更新本地值，250 ms 后回读（`FujifilmControlService.ets:1191-1227,1296-1312`）。
- `step(code, dir)`：快门/光圈/EV 走 `0x902C/0x902D/0x902E`（参数 `[dir]`），其余按描述符枚举前后移动再 `setValue`（`:1229-1278`）。
- 动作：快门 `0x100E`、录像 `0x9020/0x9021`、Postview `0x9022`、变焦 `0x9023/0x9024/0x9025`、S1 `0x9026/0x9027`、取消 `0x9030`（`:1331-1399`）。
- 忙重试只认 `4102` 与 `0x2019`，5 次 × 100 ms；退出回滚：UnlockS1 → StopZoom → TerminateMovie → CancelCapture → 关取景 → TerminateOpenCapture → close，每步 1.2 s 独立 try（`:1717-1747,1946-1959`）。

### 6.5 事件

事件通道抛上来的是**原始 PTP 事件码**，控制层先按 `CCameraEvent::ThreadProc` 映射成 SDK 码再分发（`FujifilmControlService.ets:1434-1538`；`NOTES_B.md §3.1`）：

| 原始 | SDK | 处理 |
|---|---|---|
| `0x4002` | 1 ADD_IMAGE | 记录 |
| `0x4006` | 40 PROP_VALUE | 有参数直接应用，否则 `0x1015` 回读 |
| `0x4008` | 41 DEVICE_INFO_CHANGED | 通知页面重拉属性 |
| `0xC004` / `0x400D` / `0xC001` | 30 / 31 / 32 | 拍摄开始 / 完成 / Postview 就绪 |
| `0xC005` | 43 AF_COMPLETE | 回调 |

事件 11（相机请求模式）与 40 在原生映射表里**没有**分支，来源未定，因此实现同时接受 SDK 码与上表原始码，并对 11 做超时降级（`NOTES_B.md §3.1`）。

## 7. 图传

### 7.1 会话准备

`connect()` → 等事件 11（6 s，可超时）→ `SetFunctionMode(20)`（失败补一次标准 `OpenSession(1)` 后继续）→ 读 `0xDF28` 版本（相机版本 > 3 只记日志、不写回）→ 读双槽 → 枚举当前槽（`FujifilmImportService.ets:384-415,506-571`；`NOTES_C.md §2.2-2.3`）。图传页不调 `clearEventListeners()`，避免误伤控制/固件监听器。

### 7.2 双槽（SD 卡）

`0xD244` 是 `Get/SetDevicePropValue` 的 UINT8 属性，值 0–7（`FujifilmProtocol.ets:279-280`；`NOTES_C.md §2.1`）：

| status | 当前槽 | 槽位数 | 切槽映射 |
|---|---|---|---|
| 1 | 1 | 2 | →2 = 2 |
| 2 | 2 | 2 | →1 = 1 |
| 3 | 1 | 2 | →2 = 4 |
| 4 | 2 | 2 | →1 = 3 |
| 5 | 1 | 3 | →2 = 6，→3 = 7 |
| 6 | 2 | 3 | →1 = 5，→3 = 7 |
| 7 | 3 | 3 | →1 = 5，→2 = 6 |

`status=0` 表示没有槽位信息：单卡机型（X100 / X-E / X-Txx / X-S10 等）显示 1 个槽，其余按 2 兜底，空卡置灰但不隐藏（`FujifilmImportService.ets:248-322`；`NOTES_C.md §3.3`）。切槽先清列表与缩略图状态 → 写 `0xD244` → 重读存储 → 重新枚举（`:729-792`）。

### 7.3 对象枚举

```
0x1015 [0xD22B] 当前句柄 → 0x1015 [0xD620] 张数（回退 0x1006）→ 0x9053 [0, 30000] 日期分组计数（只诊断）
→ 0x1015 [0xD621] 全部句柄（回退 0x1007）→ 0x9054 [handle] 逐条对象信息（回退 0x1008）
```

（`FujifilmImportService.ets:798-1012`；`NOTES_C.md §4.1`。）句柄一次取全、不分页；裸数组与 `count + 数组` 两种布局都兼容；`0x9053` 只打日志、不参与 UI。**不排序**，保持相机顺序，`handles[0]` 最新（`NOTES_C.md §4.2,§4.5,§8`）。

`0x9054` 的对象信息 = 标准 PTP ObjectInfo + 偏移 48 的私有 `realFileFormat u32`，文件名通常在 52（UTF-16LE，NUL 结尾）；解析按 48/52/44 依次尝试并做合理性校验（`FujifilmImportService.ets:1014-1083`；`NOTES_C.md §4.3`）。格式码覆盖 JPEG/JFIF/HEIF/RAF/MOV/MP4/PNG/TIFF，文件夹 `0x3001` 跳过（`:848,1240-1300`）。

### 7.4 缩略图

`0x9055 [handle]`（20 s），失败回退 `0x100A`；串行 worker、队列上限 50、内存缓存 24 张、文件缓存 `filesDir/fujifilm/thumbs/s<slot>_<handle>.jpg`（HEIC 缩略图写 `.heic`）（`FujifilmImportService.ets:1373-1452`；`NOTES_C.md §5`）。相机缩略图是**未转正**的裸像素，缓存前按 `0x9054` 里的 `Orientation:<1–8>` 解码→旋转→重编码；方向靠整包标记扫描取得，不依赖固定偏移（`:1085-1148,1454-1493`；`NOTES_F.md §2-§4`）。

### 7.5 原图下载与落地

| 条件 | 路径 |
|---|---|
| `size ≤ 20 MiB` | `0x1009 [handle]` 整包，长度必须等于 size |
| 更大或整包失败 | `0x9056 [handle, offset, ask]`，`ask = min(12582880, remain)` |
| `0x9056` 抛错 | `0x101B [handle, offset, ask]` 兜底 |
| 校验 | 收满 `size` 才算成功；失败删 `.part`，最多 2 次尝试 |

（`FujifilmImportService.ets:1653-1758`；`NOTES_C.md §6.1`。）落地：`filesDir/fujifilm/` 临时文件 → `createAsset` + 8 MiB 分块拷贝 → 成功后删副本；相册拒绝（RAF/HEIC 常见）则保留应用目录副本并在文案区分（`:1760-1801`）。每张同时写 `RecentPhotoStore`，方向参数固定 1（缩略图已转正、原图 EXIF 由下游归一化），相机缩略图同时作为兜底图（RAW/HEIC 尤其依赖它）（`:1607-1630`；`README.md §3.1`）。RAW 与 JPEG 走同一条枚举/下载路径，差别只在格式码（`0xB103`）、扩展名/mime 与预览来源；双槽指 SD1/SD2(/SD3)，不存在"JPEG 槽/RAW 槽"的区分。

## 8. 实现对照表

| 环节 | 实现 | 依据 | 状态 |
|---|---|---|---|
| 广播识别 | `parseAdvertisement()` | `01 §4.1/§4.4` | 已实现，RED/老协议分流 |
| 扫描 | 7 UUID 三级降级 | `01 §2/§4.3` | 已实现 |
| GATT | MTU 185、订阅 AP_STATE | `01 §7.2` | 已实现 |
| 配对 | key 回写 + RED 两步 | `01 §6/§7.2` | 无 PIN/绑定/加密 |
| 凭据 | SSID/密码现读 | `01 §8` | 密码不落库，失败即断 |
| 拉起 | `600655E6` 3/4/5 + `0x8001` | `01 §9` | 已实现，20 s 上限 |
| PTP-IP | 12 B 头、512 B 块 | `02 §3` | 已实现 |
| 初始化/数据阶段 | GUID + 23 字符名；CIPA 1/2/3 自校准 | `native_ptp.md §4.2`，`02 §3` | **推断**（68 B 假设、口径冲突） |
| 事件/取景 | 55742 常驻读；55741 整帧 + `LE32@12+18` | `02 §4`，`02 §7.1` | Ack 超时不断链、通道初始化**推断** |
| 控制 | 模式协商 20/6/22 → 5 | `02 §4` | 已实现，含降级 |
| 参数 | 53 条目录 + `0x902B` | `02 §5` | 值域不编造 |
| 图传 | 双槽 + `0xD22B/0xD620/0xD621` | `03 §3-§7` | 已实现 |
| 缩略图/下载 | `0x9055`→`0x100A`；`0x1009`/`0x9056`/`0x101B` | `03 §6-§7` | 已实现，含转正与 2 次重试 |

## 9. 限制与风险

1. **推断项**：代码头部声明只引入 2 处推断值——Init 名称 23 字符（凑 68 B）与 `DataPhaseInfo` 口径（`FujifilmPtpIp.ets:16-19`）；取景通道 initialize 在函数注释里另标【推断】（`:707-714`）。NOTES 里还有：取景帧完整性（`NOTES_A.md §4.2`）、`AP_STATE` 通知形态（§4.3）、老协议名前 4 字符（§4.4）。
2. **RED 与老协议的差异只在 BLE 侧**：广播字段、短序列号来源、额外两次写。PTP-IP、控制、图传三层没有任何 `red` 分支，RED 的 Wi-Fi 流程与老协议完全同路径；这是实现事实，正确性需真机确认。
3. **固件版本差异**：`AP_STATE` 只按 LE u16 解析，若固件带长度前缀会一直等不到 `0x8001`（`NOTES_A.md §4.3`）；`OpenSession` 的 `0x201E` 按成功处理；版本协商在相机版本 > App 支持值时跳过写入（`NOTES_C.md §2.2`）；身份读取中序列号失败回退 0x2A25、机型失败回退 0x2A24 或广播名，固件版本（0x2A26）没有回退值。
4. **冲突 1（变焦）**：`FujifilmProtocol.ets:192-194` 记 `0x9023=STEP / 0x9024=START / 0x9025=STOP`；`FujifilmControlService.ets:57-59` 记 `0x9023=START / 0x9024=STOP / 0x9025=STEP`。控制服务按后者发命令，两者必有一处错。
5. **冲突 2（0x501F）**：协议表写 `IMAGE_ASPECT = 0x501F`（`FujifilmProtocol.ets:275`），控制目录写"版权 = 0x501F"（`FujifilmControlService.ets:373`）。
6. **文档漂移**：控制服务头部仍称协议文件里 `FILM_SIMULATION=0xD245`、`IMAGE_QUALITY=0xD244`（`FujifilmControlService.ets:37-42`），而协议文件已改为 `0xD001`/`0x5004`，并注明 AF 区域 `0xD245`、双槽 `0xD244`（`FujifilmProtocol.ets:277-282`）。
7. **主机地址固定**：`FujifilmPtpIp.connect()` 只用 `FujifilmNet.HOST = 192.168.0.1`，不接受 `cameraHost`；页面算出的 DHCP 网关只写进会话，PTP 层未消费（`FujifilmProtocol.ets:101`；`FujifilmPtpIp.ets:359`；`CameraPage.ets:6071-6075`）。
8. **未接线常量**：`CHAR_UTC_AND_TIMEZONE`、`CHAR_LENS_FIRMWARE_VERSION`、`CHAR_FW_UPDATE_STATE` 只有定义、无读写调用点；`CURRENT_OBJECT_HANDLE_PARAM = 0x10000001` 同样未使用。固件服务有相机准入状态的中文映射，但没有读 `049EC406`；`OPEN_ATTEMPTS = 6` 也只有常量与注释，连接失败即抛给页面。
9. **事件 11/40 来源未定**：原始码映射表里没有它们，实现靠"直通 SDK 码 + 超时降级"兼容，降级写入 `degradedReason` 并在页面显示（`NOTES_B.md §3.1`）。
10. **`0x902B` 三种记录头排布都试**：选错不会返回半张表（每条 payload 必须恰好消费完），但真机落点未确认（`NOTES_B.md §2.2`）。
11. **图传未解码部分**：`0x9053` 响应布局（`NOTES_C.md §8`）、`0xD621` 是否带 count 前缀、`0x9054` 文件名是否带 PTP 长度前缀，均走兼容分支或仅作诊断。
12. **串行化与槽位推断**：所有 PTP 事务共用一条队列，缩略图与下载互相排队；取景在独立 socket 上，但解码在主线程循环，遥控态会主动关 55741 以免相机空灌帧（`FujifilmControlService.ets:1576-1711`）。`status=0` 时按机型前缀猜槽位数，可能多显示一个灰按钮（`FujifilmImportService.ets:266-286`；`NOTES_C.md §3.3`）。
13. **配对失败被容忍**：key 写失败仍继续读凭据，若相机此时确实未授权，失败会推迟到凭据读取或热点关联阶段才暴露（`CameraPage.ets:6007-6013`）。

## 10. 引用

- 常量与实现：`FujifilmProtocol.ets`（UUID/端口/操作码/属性码/超时）、`FujifilmPtpIp.ets`、`FujifilmBleService.ets`、`FujifilmModels.ets`、`FujifilmControlService.ets`、`FujifilmImportService.ets`、`FujifilmFirmwareService.ets`。
- 决策记录：`docs/fujifilm/NOTES_A.md`（识别/BLE/PTP-IP）、`NOTES_B.md`（控制）、`NOTES_C.md`（图传）、`NOTES_D.md`（固件）、`NOTES_F.md`（方向）。
- 契约与总览：`docs/fujifilm/ROUTE_SPEC.md`、`docs/fujifilm/README.md`。
