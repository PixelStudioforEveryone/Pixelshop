# 尼康 Z 系列：SnapBridge BLE、LSS 认证与 PTP/IP 传输

- 工程：VIVID（ArkTS），基线提交 `18466be`
- 范围：Z 系列一条线。BLE 只承担“把 Wi-Fi 凭据交到手机”，图像与控制全部走 ISO 15740 PTP/IP（TCP 15740）
- 依据：只读代码与仓库文档。凡推断均标“推断”并给出依据；密钥、UUID、操作码一律照代码/注释抄录，未新造任何值

## 0. 依据与一处文档缺口

根目录 `报告_尼康LSS认证与WiFi凭据解密.md` 在工作区中是**空文件（0 行）**，且不随公开仓库发布，因此本文无法引用它的事实条目，只能以代码为准。代码内部本身存在若干“注释与实现不一致”，第 9 节逐条列出，并说明哪一侧是当前实际行为。

证据强度分四级，本文引用时按级别取舍：

| 级别 | 含义 | 例 |
|---|---|---|
| A 真机实测 | 代码注释里带时间戳与错误码的现场日志 | Z 8 上 `0x2004` 读到 `2900007/2900011`（`NikonBleProvisioning.ets:1132-1137`） |
| B 随包产物 | 官方 APK 的 DEX/smali 或 `libLsSec-jni.so` 反编译结论 | 17 字节帧编解码类 `bleclient/b;`（`NikonLssProtocol.ets:15-26`） |
| C 代码注释/常量 | 作者基于 A/B 写下的注释与常量 | 操作码、属性码表 |
| D 推断 | 本文据现有事实外推，已逐处标注 | 广播配对状态未被解析 |

主要依据文件：

| 文件 | 作用 |
|---|---|
| `NikonBleProvisioning.ets`（3265 行） | GATT 传输、广播识别、配对、0x2000 认证、0x2004 凭据读取、入网 |
| `NikonCameraService.ets` | SnapBridge 服务/特征 UUID、Z 机型名解析 |
| `NikonLssProtocol.ets` | 认证帧与连接配置块的字节布局、security 枚举 |
| `NikonLssSession.ets` | 1→2→3→4 状态机、MAC、会话密钥派生、CBC 解密 |
| `NikonLssCrypto.ets` / `NikonLssHashTable.ets` | Blowfish 与预置调度表 |
| `NikonPtpIpService.ets`（2947 行） | PTP/IP 握手、事务队列、实时取景、快门、属性、图传 |
| `CameraControlBrand.ets` / `NikonCameraParameters.ets` / `CameraControlPage.ets` | 控制页的参数面板适配与实际接线 |

## 1. 线路定位：为什么和索尼共用 PTP/IP

`CameraControlBrand.ets:14-21` 把定位写得很直接：索尼线“共享 ISO 15740 PTP/IP 传输”，而尼康线“走的是同一条 ISO 15740 PTP/IP 传输（同一个 NikonPtpIpService 单例），因此控制面与索尼线同构：实时取景 + 快门”。`CameraControlBrand.ets:122-125` 的 `isPtpIpProtocol` 只在 `sony` / `nikon` 两个协议值上返回 true，页面按同一套 PTP/IP 按钮面渲染。

这与 `NikonBleProvisioning.ets:4-24` 的分工一致：BLE 段只做“配对 → LSS 认证 → 读回相机给出的 Wi-Fi 凭据 → 加入该网络”，然后“让已有的 PTP/IP 传输与控制代码接手”。代码里没有任何“通过 BLE 传照片”的路径，`NikonPtpIpService` 也不引用 BLE。

补充事实：USB 是第三种管道，不是第四条协议线。`NikonUsbPtp.ets:10-25` 明确“USB 和 PTP/IP 只是两种‘管道’，上面跑的操作码、数据封装、属性编码完全一样”，并通过 `NikonPtpIpService.attachTransport()` 挂上去（`NikonPtpIpService.ets:997-1007`）。

## 2. BLE 广播与识别

### 2.1 服务与特征

`NikonCameraService.ets:44` 给出 SnapBridge（LSS）服务 UUID：

```
0000DE00-3DD4-4255-8D62-6DC7B9BD5561
```

私有基址后缀为 `3DD4-4255-8D62-6DC7B9BD5561`，标准 SIG 后缀只用于设备信息服务、电量与 CCCD（`NikonCameraService.ets:31-43`）。本线用到的关键特征（同文件 `:47-69`）：

| 特征 | 用途 |
|---|---|
| `0x2000` | LSS 认证，17 字节帧写入并回读通知 |
| `0x2001` | POWER_CONTROL（0=STOP、1=WAKE_WAIT、2=INVALID_WAKE、3=VALID_WAKE，见 `NikonBleProvisioning.ets:1863-1875`） |
| `0x2002` | CLIENT_DEVICE_NAME，固定 32 字节、零填充 |
| `0x2003` | SERVER_DEVICE_NAME，相机自报名 |
| `0x2004` | 连接配置（Wi-Fi 凭据） |
| `0x2005` | CONNECTION_ESTABLISHMENT |
| `0x2006` / `0x2007` | 时间 / 位置 |
| `0x2008`–`0x200B` | 控制点 / feature / 线缆状态 / 序列号 |
| `0x2020` / `0x2021` | 控制用状态与命令 |
| `0x2080` / `0x2081` | 分类信息 / 捕获状态 |

### 2.2 广播准入

`NikonBleProvisioning.ets:362-444` 自行解析 AD 结构：`0x06/0x07` 里的 16 字节 UUID 按小端反转后与 SnapBridge 服务比对（`:387-397`、`:421-430`），`0x08/0x09` 取本地名（`:399-415`），`0xFF` 制造商标识只转成十六进制字符串**用于诊断**（`:431-437`）。

`findCamera` 的准入条件是三条任一（`:480-481`）：广播带 SnapBridge 服务、名字能经机型表识别、或名字符合尼康机身命名习惯（`:593-603` 的正则，锚定 `Z_`、`Z5`、`D850` 等，避免误收 ZTE 之类）。

机型表在 `NikonCameraService.ets:84-99`，共 14 项（Z 50II、Z 6III、Z 5II、Z 7II、Z 6II、Z 6、Z 7、Z 50、Z 30、Z 5、Z 8、Z 9、Z fc、Z f）。名字解析规则见 `:102-168`：`Z_6_2_xxxxxxx` 的世代位表示 Z 6II，序列号至少 4 位数字。

**广播里的配对状态：代码不解析。** 只把 RSSI、服务命中情况、manufacturer 十六进制与整段原始广播字节记进 trace（`NikonBleProvisioning.ets:492-505`）；没有对厂商数据做位域解码，也没有“已配对/未配对”字段的读取逻辑。因此本报告不给出配对状态的位定义。扫描窗口 10 s（`:78`、`:539`），不可连接的结果留作兜底（`:506-511`），启动扫描被拒不算失败（`:528-537`）。

### 2.3 配对段实际动作序列

`provision` 在 GATT 建链后的顺序（`NikonBleProvisioning.ets:1123-1394`），与“先认证、再写身份”这一实测结论一致：

1. 请求 MTU 512（`:1143`），枚举服务并逐个打印特征权限（`:1148-1163`）。
2. 在 `0x2000` 上按相机实际属性选择 notification 或 indication（Z 5 只报 indicate，`:927-953`）。
3. 订阅 `0x2008`、`0x200A`、`0x2020`、`0x2021`（`:1789-1861`），等 400 ms（`:1262`）。
4. LSS 认证（第 3 节）。
5. 写 `0x2002`：固定 32 字节、名称字节 + 零填充、无长度前缀（`:620-717`）。代码记录：认证前写会被拒（同一写入两次 `-41`），认证后同一写入返回 `0`（`:1350-1360`、`:3157-3169`）。
6. 写 `0x2005`，读 `0x2003` 取相机自报名（`:1377-1379`），再读 `0x200B` 序列号、`0x2A19` 电量、`0x2A26` 固件、`0x2009` feature 连读三次、`0x2008` 读两次（`:1380-1387`、`:1926-1982`）。
7. 系统级经典蓝牙配对（`:1395-1437`）：开 RFCOMM 服务端监听、把手机设为可被发现、发一次触发式 `pairDevice`，随后最多等 120 s 让相机回连并出码（`:2665-2672`）。
8. 配对码分流（`:2369-2398`）：`pinType=2` 时把码写入 `AppStorage('nikonPairCode')` 交给界面，由用户在系统弹窗确认；其它类型尝试 `setDevicePairingConfirmation`，失败则回退 `setDevicePinCode`。代码注明 `setDevicePairingConfirmation` 需要系统级 `MANAGE_BLUETOOTH`，普通应用拿不到（`:2422-2434`）。

RFCOMM 使用标准 SPP UUID `00001101-0000-1000-8000-00805F9B34FB`，`secure: true` 以便相机连入时由协议栈自行发起配对（`:2021-2031`、`:2161-2165`）。

## 3. LSS 认证

### 3.1 17 字节帧

布局由 `NikonLssProtocol.ets:40-57` 固定，编码/解码在 `:142-174`：

| 偏移 | 长度 | 字段 |
|---|---|---|
| 0 | 1 | stage（1/2/3/4） |
| 1 | 8 | nonce |
| 9 | 8 | deviceId |

无长度前缀、无填充。`decodeLssAuthFrame` 要求长度 ≥17，短帧返回 null（`:161-163`）；stage 取自 `bytes[0] & 0xff`。

### 3.2 四个阶段的语义与顺序

状态机常量与准入条件见 `NikonLssSession.ets:242-248`（0 新建 → 1 init → 3 stage1 → 5 stage3 → 6 keyed），阶段顺序由 `authenticate` 串起来（`NikonBleProvisioning.ets:3170-3233`）：

1. **stage 1（手机→相机）**：`init(Date.now() & 0x7fffffff)` 后取 8 字节手机 nonce（`:3175-3176`）。nonce 来自 `cryptoFramework.createRandom().generateRandomSync(8)`（`NikonLssSession.ets:325-337`），注释明确 seed 不参与线上字节。帧为 `[1][N_B][selfDeviceId]`（`NikonBleProvisioning.ets:3194-3195`）。
2. **stage 2（相机→手机）**：必须 `stage === 2`（`:3203-3207`）。此时 `nonce` 是相机 nonce `N_A`，`deviceId` 字段承载的是 **MAC1**（`NikonLssSession.ets:344-354` 的契约说明）。
3. **stage 3（手机→相机）**：`session.stage3(N_A, MAC1)` 用 8 个候选根逐个计算 `MAC(tbl[i] || N_A || X)`，与 MAC1 比对；命中后返回 `MAC2 = MAC(tbl[i] || X || N_A)`（注意交换，`:354-394`）。帧为 `[3][N_B][MAC2]`（`NikonBleProvisioning.ets:3215-3216`）。
4. **stage 4（相机→手机）**：必须 `stage === 4`（`:3223-3227`）。其 `deviceId` 原样作为 `key1` 使用，并写入 `lastCameraDeviceId`（`:3228-3231`）。

相机驱动 2、4 两阶段，手机只发 1、3 两帧（`NikonLssProtocol.ets:258-268`：原生的 `Stage2nd`/`Stage4th` 从未被 Java 调用）。

### 3.3 deviceId 的来源（含未解项）

两个 8 字节字段要分开看：

- **stage 1 帧的 `deviceId`**：代码当前使用“手机自己持久化的 8 字节身份”。依据写在 `NikonBleProvisioning.ets:128-153`：官方把 `SharedPreferences("DeviceID")` 里的 Base64 字符串解码后传给 `BleConnection.connect`，首次运行用 `Random(System.currentTimeMillis()).nextBytes(new byte[8])` 生成，并断言长度正好 8。实现见 `loadClientDeviceId`（`:286-332`），存储名 `nikon_lss_identity`、键 `DeviceID`（`:156`、`:294-298`）。
- **stage 2/4 帧里同名字段**：不是身份。stage 2 承载 MAC1，stage 4 承载 key1（`NikonLssSession.ets:344-354`、`NikonBleProvisioning.ets:3208`、`:3231`）。

**与模块头注释的冲突**：`NikonBleProvisioning.ets:26-34` 仍写着“`cameraDeviceId` 的来源是 open item，由调用方提供、不臆造”。这是旧结论；当前实现（`:1103-1113`、`:3181-3193`）已改为持久客户端身份。按“代码优先”原则，本文以持久身份为准，并记录该注释已过期。旧的“从相机蓝牙地址派生候选”逻辑仍在（`buildDeviceIdCandidates`，`:1714-1731`），但只用于日志与兜底（`:1111-1121`），`authenticate` 内部并不使用该参数（签名 `:3170-3172`）。

**仍未解的一项**：相机在 stage 4 回传的 `key1` 是否等于手机命中的根 `tbl[idx]`。代码不假设，只做诊断：`describeKey1` 输出 `key1=shared-root index=N` 或 `key1=other index=N`（`NikonLssSession.ets:452-462`，调用处 `NikonBleProvisioning.ets:3228-3231`）。这是本线最需要一次真机日志来收口的点。

### 3.4 密钥派生与 Blowfish

会话密钥不来自任何硬编码常量，而是 8 字节 MAC 输出再喂给标准 Blowfish 密钥编排：

- `ctx[0..7] = idx || N_A[1..3] || X[0..3]`，其中 idx 是命中的根序号、X 是手机 nonce（`NikonLssSession.ets:376-386`）。
- `K = MAC8(key1 || key2 || ctx)`，`key2` 是持久客户端身份；`new NikonBlowfish().initKey(K)`（`:428-445`）。
- 字段解密为 CBC、**每字段独立、IV 全零**：32 字节 SSID 与 64 字节密码是两次独立解密，因为库每次调用都重读 IV 且不回写终链（`:464-514`）。

MAC 本身是“固定调度的 Blowfish-CBC-MAC”：初链 `01 02 03 04 05 06 07 08`，每块先与链异或再加密，链即结果；尾部不足 8 字节用 `0xFF` 补齐，长度恰为 8 的倍数时不追加块（`NikonLssSession.ets:174-226`）。

### 3.5 哈希表（预置调度表）

`NikonLssHashTable.ets:1-12`：来自 `libLsSec-jni.so` 的 `.rodata @0x2e28`，1042 个字（18 个 P + 4×256 个 S），共 8336 个十六进制字符；**不是标准 Blowfish 初值**（P[0]=`e813ec15`，标准为 `243f6a88`）；该调度由某个固定密钥编排而来，而该密钥在 .so 中不可恢复，所以只能整表搬运、**不得再调用 initKey**。

同一张表在 `NikonLssSession.ets:67-133` 又内联了一份（`MAC_SCHEDULE_HEX`）。当前实际加密路径用的是内联这份；`NikonLssCrypto.ets:328-457` 的 `NikonLssHandshake`（hash/generateKey/decipher）虽已完整实现，但仓库内没有任何调用方——属于重复实现，见第 9 节风险。

### 3.6 成功与失败判定

没有“认证成功”这种显式应答字节。成功条件是两步都成立：8 个根中命中（`stage3` 返回非 null），且会话密钥派生成功（`NikonBleProvisioning.ets:1319` 的分支）。失败路径与文案（`NikonBleProvisioning.ets:3197-3213`、`3218-3227`、`1333-1335`）：

| 条件 | 结果 |
|---|---|
| 15 s 内无 0x2000 通知 | “第 1/2 轮超时” |
| stage 值不是 2 / 4 | “响应格式异常” |
| 8 个根都不匹配 MAC1 | “未能在 8 个共享根中匹配相机响应” |
| 密钥派生失败 | 记 trace，凭据解密被跳过 |
| 凭据解密/合理性检查失败 | “尼康蓝牙认证已通过，但 Wi-Fi 凭据未能解密”并返回 |

时序与传输细节：认证通知等待 15 s、轮询 100 ms（`:74-76`、`:1764-1778`）；CCCD 订阅后显式等 400 ms 再发第一个写入，避免“订阅与写入撞在一个未完成操作上”导致本地协议栈直接回 2900099（`:1245-1262`）；MTU 请求 512（`:1143`）。

## 4. Wi-Fi 凭据解析

`0x2004` 一次读取返回整块（`NikonCameraService.ets:54-57` 的注释同此）。解析器 `parseLssConnectionConfiguration`（`NikonLssProtocol.ets:213-256`）按以下顺序走：

| 顺序 | 字段 | 长度 | 说明 |
|---|---|---|---|
| 1 | flag | 1 | bit0=Wi-Fi 块，bit1=蓝牙块（`:63-65`） |
| 2 | ssid | 32 | 加密 |
| 3 | password | 64 | 加密 |
| 4 | security | 1 | 明文，按有符号字节取（`:237`） |
| 5 | sppMaxDataLength | 4 | 仅当 bit1 置位，小端 u32（`:247-254`） |

security 的线上值等于枚举的 `value` 而非序号：`UNDEFINED -1 / OPEN 0 / WPA2 1 / WPA3 2 / WPA2_WPA3 3`（`NikonLssProtocol.ets:26-30`、`:80-101`）。

解密后按“首个 NUL 之前”做 UTF-8 解码并 trim（`:183-199`），再做合理性检查：SSID 长度 3–32、密码 0–64、每个字符必须在 32–126 可打印区间（`:128-139`，调用处 `NikonBleProvisioning.ets:1328-1331`）。密码允许为空，对应 OPEN 场景。任一字段解密返回 null 或长度不足，解析器直接返回 null（`:241-243`），不会把半截乱码当凭据。

**断链策略**：解析失败或合理性检查不过时，`configuration` 保持 null，流程立刻返回“认证已通过，但 Wi-Fi 凭据未能解密”（`NikonBleProvisioning.ets:1336-1340`），不会继续入网——因为拿错的密钥去连热点只会得到一次无意义的关联失败，掩盖真正原因。

入网只用到 ssid 与 password：`connectWifi(ssid, password, ...)` 没有 security 参数（`:1608-1615`），`result.security` 仅用于上报与日志（`:1343-1346`）。`sppMaxDataLength` 被解析但当前无消费者；RFCOMM 监听使用的 UUID 是标准 SPP `00001101-...`（`:2027`、`:2161-2165`），与该字段无关。

## 5. Wi-Fi 入网与 PTP/IP 衔接

相机是 AP、手机是 STA，SSID 与密码都由相机经 BLE 给出（`NikonBleProvisioning.ets:1341-1347`），代码不硬编码任何相机热点地址。

关键顺序（这是本线调试代价最大的地方，注释写得很完整）：

1. 认证完成后读 `0x2001`（`:1502-1515`，官方在已绑定会话里先读、不写）。
2. 写 `0x2005 = [1]` 请求拉起连接（`:1521`）。注意函数头注释说 Wi-Fi 应写 `0x05`（`:801-817`），但两处调用点实际都传 `0x01`（`:1377`、`:1521`），且 `:1518-1520` 记录实测官方就是 `[1]`。
3. 开 RFCOMM 监听、等相机主动连入（最长 25 s，`:1574`），然后**彻底放掉蓝牙**：关 RFCOMM 客户端/服务端、退出可发现、停 BLE 扫描、`release()` 关 GATT，再等 2 s 复关一次（`:1567-1597`）。原因是相机同一时刻只能跑一路无线，蓝牙链路还在就不开热点（`:1551-1566`、`:2259-2273`）。
4. 扫描并入网：`connectWifi(ssid, password, trace, 1, noop, 75000, false, onStatus)`（`:1608-1615`），即 1 次尝试、最多 75 s 扫描、状态回调持续刷新进度。
5. 入网成功后从系统取网关与本机地址（`LumixImportPrototype.ets:3033-3047`，网关来自 `wifiManager.getIpInfo().gateway`），`result.gateway` 即后续 PTP/IP 的 host（`CameraPage.ets:2253`、`:5267`）。

入口分工：`provision(..., pairOnly=true)` 只配对不碰热点（`NikonBleProvisioning.ets:1457-1488`）；`startWifi` 复用既有配对、只拉热点并关联（`:990-1001`），由 `CameraPage.ensureNikonWifiForAction` 在“图片传输/相机控制”时调用（`CameraPage.ets:5626`、`:5681`）。入网失败时文案明确指向相机侧（需停留在“连接至智能设备”界面），因为凭据本身来自相机（`NikonBleProvisioning.ets:1618-1633`）。

## 6. PTP/IP 传输

端口 `15740`（`NikonPtpIpService.ets:492`），同一端口开两条 TCP：命令通道与事件通道（`:1915-1935`）。

### 6.1 握手

1. 命令连接 → `InitCommand`（type 1）：16 字节 GUID + UTF-16LE 设备名 `Pixelshop Camera` + 结尾 NUL + u32 版本 `0x00010000`（`:2696-2703`）。帧格式为 `[len u32][type u32][payload]`（`:2726-2732`）。
2. 等 `InitCommandAck`（type 2），取其 u32 作为 connectionNumber（`:1925-1930`）。首帧不盲信：允许跳过 1 个非预期帧并记日志（`:1990-2020`）。
3. 事件连接 → `InitEvent`（type 3，负载为该 connectionNumber）→ 等 `InitEventAck`（type 4）（`:1931-1935`）。
4. `OpenSession`（`0x1002`，参数 `[1]`，transactionId 固定 0），应答必须是 `0x2001`；`0x201E`（SessionAlreadyOpen）会被单独命名（`:1936-1951`、`:540`）。

### 6.2 帧类型

常量定义在 `NikonPtpIpService.ets:494-525`，所有帧都是 8 字节头 `[len u32][type u32]`：

| type | 名称 | 负载 |
|---|---|---|
| 1 | InitCommand | GUID16 + UTF-16LE 名 + 版本 u32 |
| 2 | InitCommandAck | connectionNumber u32 |
| 3 | InitEvent | connectionNumber u32 |
| 4 | InitEventAck | 空 |
| 6 | OperationRequest | dataPhase u32 + opcode u16 + tx u32 + params |
| 7 | OperationResponse | code u16 + tx u32 + params |
| 9 | StartData | tx u32 + 总长 u64（+ 可选内联数据，见 `:2276-2284`） |
| 10 | Data | tx u32 + 分片 |
| 11 / 12 | EndData | tx u32 + 末段数据；发送用 12，接收两者都认 |

### 6.3 事务与错误处理

所有命令经会话队列串行：同一时刻只有一个请求/响应（含完整数据阶段）占用命令通道（`:436-454`）。操作请求 type 6 的负载为 `dataPhase u32 + opcode u16 + tx u32 + params u32[]`（`:2705-2724`）；响应 type 7 为 `code u16 + tx u32 + params u32[]`（`:2059-2074`）。

数据阶段：`StartData`(9, tx + u64 总长)、`Data`(10, tx + 分片)、`EndData`。EndData 常量取 **12**，因为真机上 12 被相机接受、按规范改成 11 会导致写属性挂 10 s 并毒化会话（`:502-525`）；接收侧 11 与 12 都认（`:2322-2334`）。注意接收路径的注释（`:2324`）仍写“发送端已经改成只用 11”，与实际常量不符，属过期注释。

超时会毒化会话（`session.failed`，`:2351-2358`）；实时取景等调用可传 `tolerateTimeout`，把“相机暂时不应答”当作本次无帧而不是断线（`:2194-2246`）。毒化后可用 `recoverSession()` 重开一次（`:2380-2409`）。优雅关闭先发 `0x1003 CloseSession` 再断 TCP，否则相机会认为链路异常并退出“连接至智能设备”模式、连带关掉热点（`:1731-1761`）。

### 6.4 事件通道

每条会话一个后台循环，60 s 空闲超时视为正常（`:668`、`:2414-2433`）。已处理事件：`0x400D` CaptureComplete、`0x4006` DevicePropChanged（只登记属性码，不立即回读）、`0xC10A` 开始录制、`0xC108` 录制完成、`0xC105` 录制被打断（`:2435-2476`、`:652-658`）。

### 6.5 关于 KeepDeviceOn

任务里点名了 `KeepDeviceOn`。**尼康这条线没有它**：全仓仅 `CanonPtpIp.ets:7` 与 `:599` 出现 `KeepDeviceOn`（`0x911D`，佳能线）。尼康的保活/就绪语义由 `0x90C8 DeviceReady` 轮询承担（`NikonPtpIpService.ets:568-570`、`:1069-1082`），100 ms 一次、30 s 上限（`:597-601`、`:1146-1164`）。此处按代码事实更正任务前提，未把佳能的操作码搬到尼康线上。

## 7. 控制面

| 能力 | 操作码 | 参数 / 数据阶段 | 出处 |
|---|---|---|---|
| 接管控制权 | `0x90C2` | `[1]`=HOST，`[0]`=CAMERA | `:1298-1330`、`:1346-1360` |
| 开始实时取景 | `0x9201` | 无参数 | `:571`、`:1285-1292` |
| 结束实时取景 | `0x9202` | 无参数 | `:572`、`:1333-1335` |
| 取一帧 | `0x9203`（默认） | 数据阶段回 384 字节头 + JPEG | `:573`、`:1398-1445` |
| 取一帧（高清变体） | `0x9428` | 同上，但**默认关闭** | `:574`、`:1272-1282` |
| 快门 | `0x9207` | `[releaseMode, storage]` | `:603-630`、`:1096-1110` |
| 就绪轮询 | `0x90C8` | 无参数 | `:570`、`:1069-1082` |
| 录像开始/停止 | `0x920A` / `0x920B` | 无参数 | `:582-595`、`:1362-1388` |
| 切应用模式 | `0x9435` | `[0/1]` | `:579`、`:1454-1467` |

实时取景：开流前先发 `0x90C2 [1]` 接管（`:1286-1291`），不发的话机身会拒绝档位（`0x500E` → `0x200F`）与录像（`0x920A` → `0xA004`）（`:1304-1311`）。帧数据是 384 字节**大端**头 + JPEG，长度在偏移 4 的 u32；长度字段不可信时退回整段尾部，避免切出坏 JPEG（`:632-637`、`:1429-1443`）。`0x9428` 已实现但 `liveViewUsesEx=false`：2026-10-18 在 Z 5 上试开，帧请求被接受但头布局不同，页面直接无画面，且这种“成功但格式不同”无法靠 code 判断降级（`:1272-1282`）。

快门：`capture()` 先轮询就绪，再发 `0x9207`（`RELEASE_NORMAL=-1`，AF 版 `-2`，存储卡 `0`），随后再轮询到就绪；忙码 `0x2019/0xA200/0xA201/0xA207` 视为“继续等”（`:597-601`、`:1121-1137`）。完成也可由 `0x400D` 事件交叉确认（`:2448-2453`）。

录像失败时补读 `0xD0A4`（录像禁止条件）以给出机身侧原因（`:1362-1382`）。

### 7.1 属性读写为什么“看起来没有接到 UI”

`CameraControlBrand.ets:70-91` 的注释是任务要求照引的部分，原文要点：

- `NikonPtpIpService` 里确实有 `readProperty` / `writeProperty`，属性码为 `PROP_APERTURE 0x5007`、`PROP_WHITE_BALANCE 0x5005`、`PROP_EXPOSURE_MODE 0x500E`、`PROP_ISO 0x500F`、`PROP_EXPOSURE_COMPENSATION 0x5010`、`PROP_SHUTTER_SPEED 0xD100`；
- “每个属性的取值编码（光圈是 f×100？快门是分数还是毫秒？）与可选值集合都还没有经过真机核对，也没有 `SDIO_GetAllExtDevicePropInfo` 那样由机身自述的记录表可依赖；而 28 款支持机型里只有 8 款（Z 50 / Z 5 / Z fc / Z 30 / Z f / ZR / Z5II / Z50II）支持 BLE 参数遥控”；
- 因此这 12 个面板（`lut/quality/aspect/settings/mode/ev/shutter/aperture/iso/wb/metering/lvsize`）按“可见但不可用”渲染（`:87-91`）。

属性的实际传输编码：`0x1014` 取描述符、`0x1015` 取值、`0x1016` 写值（`NikonPtpIpService.ets:552-567`，并记录“0x1014/0x1015 曾被改反、真机日志否掉了”，依据是返回宽度 1–4 字节与官方数据类吻合）。

**与代码现状的差异（以代码为准）**：尼康参数已经接到 UI，只是绕开了 `CameraControlBrand` 的静态面板表。`CameraControlPage.ets:3493-3515` 的 `controlPanelEnabled` 在 `nikonMode` 下提前返回：面板是否可用取决于“该面板映射到的属性码是否拿到了合法描述符”，而 `nikonPropCodeOfPanel` 覆盖 `mode/aperture/shutter/iso/ev/wb` 六个面板（`:3523-3539`）。描述符探测与解析在 `NikonCameraParameters.describe/probe`（`NikonCameraParameters.ets:181-289`），写回走 `NikonPtpIpService.writeProperty`（`:408-417`）。显示编码也有出处：光圈是 F 值×100，依据官方 `FNumber` 枚举（`CameraControlPage.ets:3592-3594`）；白平衡取值表来自官方枚举并与真机枚举逐项对上（`NikonCameraParameters.ets:291-319`）。

因此对“为何没有接到 UI”这一问题，准确回答是：**`CameraControlBrand` 那份注释描述的是接入前状态，现已被 `CameraControlPage` 的“机身自述探测”方案取代；该静态表在尼康路径上不再生效。** 注释里 28/8 的机型能力结论在仓库内无处可核（`NikonCameraService` 只有 14 项 Z 机型识别），只能按原注释记录、标注不可验证。

## 8. 图传

枚举（`NikonPtpIpService.ets:775-872`）：

1. `0x1004 GetStorageIDs` 取卡列表；
2. 逐卡 `0x1006 GetNumObjects [sid,0,0]` 与 `0x1007 GetObjectHandles [sid,0,0]`；
3. 句柄升序后**按卡内倒序**排列（最新在前），卡间保持卡槽顺序；每张卡的句柄空间独立，用 `storageOf` 记录归属，`imageId` 形如 `卡号:句柄`（`:832-849`、`:900-917`）；
4. 空卡也算可用卡，界面据此显示置灰的“卡 2”（`:823-828`、`NikonPtpIpCatalogResult.storageIds` 注释 `:34-39`）。

分页与缩略图（`:2545-2616`）：每页最多检查 48 个句柄（`:688`）；未缓存的句柄先 `0x1008 GetObjectInfo`；`size<=0` 或格式 `0x3001`（目录）跳过；`0x100A GetThumb` 落盘为 `nikon_thumbnail_<卡号>_<句柄>.jpg`；视频无缩略图仍列出，仅标记不可预览。

原图下载（`:919-972`、`:2621-2682`）：

- 大小超过 u32 直接拒绝（`:926-929`）；
- 已知大小走 `0x101B GetPartialObject [handle, offset, len]`，每次 1 MB，短块/空块/超长/长度参数不符都算失败；
- 仅当首个分片收到 `0x2005`（操作不支持）时才回退 `0x1009 GetObject`，整对象上限 64 MB（`:689`、`:2669-2671`）；
- 写 `.part` 文件，校验通过后 `rename` 成最终文件，避免“截断文件看起来完整”（`:934-955`）；
- 结束时按 MB/s 记吞吐，便于和 SnapBridge 对比判断瓶颈在机身无线还是传输栈（`:956-960`）。

## 9. 实现对照与冲突清单

| 主题 | 实现位置 | 备注 |
|---|---|---|
| 广播识别 | `NikonBleProvisioning.ets:417-563` | UUID/机型名/命名习惯三路准入 |
| GATT 布局 | `NikonCameraService.ets:44-69` | 私有基址后缀 |
| LSS 帧 | `NikonLssProtocol.ets:40-57,142-174` | 17 字节 |
| 状态机 | `NikonLssSession.ets:241-394` | 1→2→3→4，手机只发 1/3 |
| MAC/密钥 | `NikonLssSession.ets:174-226,428-445` | 预置调度 + CBC 零 IV |
| 凭据 | `NikonLssProtocol.ets:213-256` | flag/SSID/PW/security/spp |
| 入网 | `NikonBleProvisioning.ets:1449-1637` | 0x2005 → 断蓝牙 → 关联 |
| PTP/IP | `NikonPtpIpService.ets:1907-1973` | 双通道 + OpenSession |
| 控制 | `NikonPtpIpService.ets:1096-1450` | 取景/快门/录像/属性 |
| 图传 | `NikonPtpIpService.ets:775-972,2545-2682` | 枚举/缩略图/分片下载 |

代码内部冲突（均以代码行为为准）：

1. `NikonBleProvisioning.ets:26-34` 说 deviceId 来源未解；`:128-153`、`:1103-1113` 已给出持久化身份并把旧推理标为“已被推翻”。头注释过期。
2. `NikonLssSession.ets:396-402` 说 `key2` 是“传入认证调用的相机 device id”；实际调用传的是 `clientDeviceId`（`NikonBleProvisioning.ets:1319`）。
3. `NikonBleProvisioning.ets:801-817` 说 Wi-Fi 请求写 `0x05`；实际调用写 `0x01`（`:1377`、`:1521`）。
4. `NikonPtpIpService.ets:1219-1233` 的注释要求写属性宣告 `DataPhaseInfo 3`；实际 `executeTransactionDataOut` 计算为 `payload.length===0 ? 1 : 2`（`:2114-2122`，并附真机证据说明 3 会得到 `0x201F`）。
5. `NikonPtpIpService.ets:2324` 说发送端已改用 11；常量仍为 12（`:523`），发送处用的也是 12（`:1667`）。
6. `NikonCameraParameters.ets:10-14` 的表把 `0x1015` 写成 Desc、`0x1014` 写成 Value；该文件自身调用 `readPropertyDesc` 实际发的是 `0x1014`（`NikonPtpIpService.ets:1188`），与自己的表相反。
7. `CameraControlBrand.ets:70-91` 的面板清单已被 `CameraControlPage.ets:3493-3515` 的运行时探测绕过（见 7.1）。
8. `NikonBleProvisioning.ets:642-649` 要求报给相机的名字等于本机广播名；但 `openBtcListener` 会尝试把本机名设为固定的 `Pixelshop`（`:1995`、`:2138`），而 `0x2002` 写入取的是系统当前名（`:650-654`）。改名失败时（本机不支持，`:2134-2145`）两者恰好一致，改名成功时则不一致。

## 10. 限制与风险

1. **BLE 参数遥控覆盖面窄**：注释称 28 款支持机型中仅 8 款支持 BLE 参数遥控，但仓库内没有对应能力表，无法核对；实际可用性由机身对 `0x1014` 的回答决定（`CameraControlPage.ets:3494-3512`）。
2. **LSS 未解项**：`key1` 是否等于命中的共享根仍只能靠 `describeKey1` 一行日志判断（`NikonLssSession.ets:452-462`）；未确认前，凭据解密的正确性依赖“可打印文本”启发式（`NikonLssProtocol.ets:116-139`），该检查能挡住错误密钥，但不能证明密钥正确。
3. **密钥不落库**：会话密钥只存在静态字段 `lastSessionKey`（`NikonBleProvisioning.ets:1734`、`:1349`），`takeSessionKey` 返回副本（`:1751-1756`），进程重启即丢失；重启后只能重跑蓝牙。持久化的只有客户端身份 `DeviceID`（Base64、明文 preferences，`:316-319`），它是身份不是密钥。
4. **算法实现重复**：8336 字符的调度表在 `NikonLssSession.ets:67` 与 `NikonLssHashTable.ets:12` 各存一份；`NikonLssHandshake`（`NikonLssCrypto.ets:328-457`）是完整但无人调用的第二套实现。改一处漏一处会静默失败。
5. **注释漂移**：第 9 节 8 条冲突中，4 条属于“注释还停在上一轮结论”。这类漂移在本线已经造成过误判（0x1014/0x1015、DataPhaseInfo、EndData），维护时应优先以真机日志与常量定义为准。
6. **相机侧状态是硬前提**：热点只在相机进入“连接至智能设备”且蓝牙链路释放后出现；`0x2005` 写入成功不代表相机会动作（`NikonBleProvisioning.ets:1541-1550`、`:1618-1633`）。自动化流程无法绕过用户在机身上的操作。
7. **BLE 读 0x2004 对 MTU 敏感**：Z 8 上曾出现 `2900007`（Invalid Offset）与 `2900011`（Insufficient Resources），Z 5 同条件却成功，故 MTU 512 只是消除分段路径、不是根因定论（`:1126-1146`）。
8. **单侧删除的配对不一致**：手机侧仍绑定、相机侧已删时，`pairDevice` 会被系统拒（2900099）且不改变状态；代码只能如实报告并提示两边一起删，因为 HarmonyOS 公开 API 没有解除配对（`:2568-2575`、`:2705-2710`）。
9. **`cameraDeviceIds` 参数已无用**：`authenticate` 接收但不使用（`:3170-3172`），仅在上层日志里出现（`:1120-1121`），属于历史遗留，误读会让人以为仍在尝试多个身份。
10. **属性写入的方向编码仍靠实测维持**：`DataPhaseInfo` 在尼康实现里是 2（非 CIPA 的 3），依据是 2026-10-18 的抓包（`:2114-2122`）；换机型或换固件时需要重新确认，否则表现为“全部写入被 `0x201F` 取消”。

## 11. 一句话结论

这条线的协议骨架是完整的：BLE 识别 → 17 字节 LSS 四阶段 → 预置 Blowfish 调度的 MAC 派生会话密钥 → `0x2004` 凭据解密 → 断蓝牙后入网 → TCP 15740 双通道 PTP/IP → 取景/快门/图传。真正的不确定性集中在两处：stage 4 的 `key1` 语义（需一次真机日志收口），以及相机侧“是否愿意开热点”这个不由协议决定的前提。
