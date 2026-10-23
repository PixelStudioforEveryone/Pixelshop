# 04 索尼 Alpha：BLE 配网 + ISO 15740 PTP/IP 传输与控制

> [English](en/04-sony-alpha.md) | 简体中文

基线提交 `18466be`。只依据本仓库代码及其中引用的官方客户端事实，不引入外部协议猜测；代码未证实、由现有证据外推的结论标「推断」。

## 1. 线路定位：索尼为什么和尼康共用一条 PTP/IP

索尼微单的照片传输走标准 PTP/IP（CIPA DC-005），TCP 15740，与尼康同一条传输，依据四处：
`SonyCameraService.ets:5-11` 写明机身在「PC 远程功能」激活时广播 Wi-Fi Direct 热点，热点上的传输是标准
PTP/IP，"与 libgphoto2 对索尼机身通用提供的是同一传输"，故该模块只负责身份表、适配器与尼康共用；
`SonyBleProvisioning.ets:13-14` 写明 `NikonPtpIpService` 承担图传与控制，"shared: Sony speaks standard
ISO 15740 PTP/IP like Nikon does"；`CameraControlBrand.ets:11-21` 写明索尼线"共享 ISO 15740 PTP/IP 传输，
见 NikonPtpIpService"、尼康线"走的是同一条 ISO 15740 PTP/IP 传输（同一个 NikonPtpIpService 单例）"；
`CameraControlBrand.ets:114-125` 的 `isPtpIpProtocol` 只对 sony / nikon 为真，并解释 `isSonyProtocol` 为何
不复用同一标志——两者页面形态相同，底层服务调用不同（SonyLiveView / SonyPtpIpControl 对 NikonPtpIpService）。

共用发生在**传输层**（TCP 连接、Init 握手、事务队列、数据阶段、事件通道），不发生在业务层：索尼私有操作码
（0x92xx）、机身自述属性表（0x9209）、取景 HTTP 流都由 Sony 侧三个模块实现。反例是同仓库富士线——自有 PTP-IP
变体、12 字节包头、私有端口 55740/55741/55742，被 `isPtpIpProtocol` 明确排除（`CameraControlBrand.ets:101-108`）。
传输层是逐函数借用：`connectGatt` / `enableNotification` / `readGatt` / `writeGatt` / `connectWifi` 在
`LumixImportPrototype` 里无品牌逻辑，索尼与尼康一样直用；只有发现与配对线各写各的（`SonyBleProvisioning.ets:29-34`）。

## 2. 广播与识别

### 2.1 制造数据（AD type 0xFF）

`SonyCameraService.parseSonyAdvertisement`（`SonyCameraService.ets:261-334`）：

| 偏移 | 内容 | 判定 |
| --- | --- | --- |
| 0..1 | 公司 ID `45 01` = 0x012D（小端） | 不符即非索尼 |
| 2..3 | `03 00`（"camera"标记） | 不符则 `isSony` 真、`isSonyCamera` 假 |
| 4..5 | 保留 | 不解析 |
| 6..7 | 两个 ASCII 字符 = 机型码 | 原样保留，只进日志 |
| 8.. | TLV 三元组 `[tag][d0][d1]`，步长 3，`tag == 0` 终止 | 见下表 |

至少 11 字节才解析（`:287`）；按长度字节逐段走 AD 结构，只取第一个 0xFF 记录（`:290-303`）；公司 ID 常量见
`:150-153`（0x012D = 301，线上小端 `45 01`）。

| tag | 字段 | 判定式（代码原文） |
| --- | --- | --- |
| 33 (0x21) | Wi-Fi 凭据交接 | 支持 `(d0 & 0x20) != 0`；启用 `(d0 & 0x30) == 0x10` |
| 34 (0x22) | 配对 | 支持 `(d0 & 0x80) != 0`；启用 `(d0 & 0xC0) == 0x40` |
| 35 (0x23) | 遥控 / 图传 | 遥控支持 `(d0 & 0x80)`、启用 `(d0 & 0x60) == 0x20`；图传支持 `(d0 & 0x10)`、启用 `(d0 & 0x0C) == 0x04` |

"启用"是两位三态，所以用掩码比较而非逐位测试（`:276-277`）。tag 34 的 bit5/4（位置服务）、tag 35 的 bit1/0
（推送）、d1 bit7（后台）在注释里列出但未解码。

### 2.2 机型码、机型表与 SSID 形态

两字符机型码只出现在扫描日志的 `modelCode=`（`SonyBleProvisioning.ets:194-202`），不参与分支——身份另有两条
来源：BLE 本地名（`identifyBluetoothName`，`SonyCameraService.ets:242-259`，接受 `ILCE-7M4` / `ILCE-7M4-1234567` /
`SONY ILCE-7M4`，按 token 长度倒序以免 `ILCE-7M` 吃掉 `ILCE-7M5`）与 Wi-Fi SSID。机型表 26 条
（`:155-182`，Alpha / Cinema Line / ZV / RX / ILX），另有只在 BLE 名里出现的 `ILCE-7CM2`（`:184-189`）。

广播准入刻意窄：制造数据解出 `isSonyCamera`，**或**本地名落在机型表，二者之一（`SonyBleProvisioning.ets:153-160`、
`:173-192`）；注释说明"只匹配 SONY 前缀会把电视、耳机、音箱一起放进来"。扫描 15 s、
`SCAN_MODE_LOW_LATENCY` + `MATCH_MODE_AGGRESSIVE`（`:70`、`:208-213`），且只关闭本次自己启动的扫描，避免清空
相机页的附近列表（`:220-230`）。

SSID 形态 `DIRECT-<4+ 位大写字母数字>:<机型 token>`，例如 `DIRECT-12AB:ILCE-7M4`（`SonyCameraService.ets:1-7`、
`:191-217`）：必须 `DIRECT-` 开头、冒号前实例名满足 `^[0-9A-Z]{4,}$`、冒号后 token 精确命中机型表（可带
`SONY-` 前缀）。实例名与密码由机身生成，函数只识别机型（`:194-196`）。`identifyWifiSsid` 同时是"手机是否已在
相机热点上"的判据（`SonyBleProvisioning.ets:846-870`），家用路由器因此不会被误判成相机。

## 3. BLE 配对

### 3.1 服务与特征（`SonyCameraService.ets:73-118`）

| 角色 | UUID（常量展开） | 用途 |
| --- | --- | --- |
| 配对服务 | `8000EE00-EE00-FFFF-FFFF-FFFFFFFFFFFF` | 私有配对 |
| 配对指令 | `0000EE01-EE00-FFFF-FFFF-FFFFFFFFFFFF` | 写 `{6,8,1,0,0,0,0}` 启动配对 |
| 配对状态 | `0000EE03-EE00-FFFF-FFFF-FFFFFFFFFFFF` | notify 状态/结果帧 |
| 机身身份 | `0000EE04-EE00-FFFF-FFFF-FFFFFFFFFFFF` | read 固件 + 机型 |
| 控制服务 | `8000CC00-CC00-FFFF-FFFF-FFFFFFFFFFFF` | Wi-Fi 开关与凭据 |
| Wi-Fi 开 | `0000CC08-CC00-…` | 写 `{1}` |
| SSID | `0000CC06-CC00-…` | read，3 字节头 + ASCII |
| 密码 | `0000CC07-CC00-…` | read，3 字节头 + ASCII |
| BSSID | `0000CC0C-CC00-…` | read，可选 |
| 能力位 | `0000CC0D-CC00-…` | 诊断用 EnumSupportInfo 记录 |
| SSH 凭据 | `0000CC17-CC00-…` | 只记存在与长度，不记内容 |

同服务下另有 `CCA2`（相机 UUID）、`CCA7`（标识符）、`CC0A`（固件）、`CC0B`（机型名）、`CCAB`（Wi-Fi 频段），
官方读取顺序 CC0A → CC0B → CCA7 → CC0D → CCAB（`:103-115`）。特征按"首段去前导零"归一化后比较，因为平台可能
给出全 UUID、`0000EE01` 或裸 `EE01`（`SonyBleProvisioning.ets:289-318`）；CCCD 是标准 `00002902-…`
（`SonyCameraService.ets:118`）。

### 3.2 配对流程（`pairOnly`，`SonyBleProvisioning.ets:405-686`）

1. 扫描取 `deviceId`、连 GATT、`setBLEMtu(64)`（与尼康同一协商值；158 是 DiRxTx 帧的 MTU，配对/凭据特征值都很短，
   没必要要一个控制器可能不给的 MTU，`:422-430`），随后先读 EE04 身份，让成功结果带回机型与固件（`:452-470`）。
2. 找 EE01 / EE03；缺服务或特征直接返回，并把配对服务实际暴露的特征列表与整张 GATT 表拼进文案，
   "未发送猜测指令"（`:485-504`）。
3. **先做系统级 bonding**：`getPairState` 已是 BONDED 则跳过，否则 `connection.pairDevice` 并等 1500 ms 落地。
   理由：配对写入曾被回通用 `2900099`，而"该特征要求加密链路"正是这种无具体错误码的失败（`:534-564`）。
4. 订阅 EE03，写启动帧 `{6,8,1,0,0,0,0}`（`SonyCameraService.ets:122`）。写类型按特征属性选 `WRITE` 或
   `WRITE_NO_RESPONSE`，另一种作回退——`2900099` 不区分写类型错/载荷错/链路不可用，而写类型是重试能修的
   那一个（`SonyBleProvisioning.ets:362-393`、`:569-585`）。
5. 配对是两段式：启动帧只让机身进配对窗口，EE03 状态机再宣告经典蓝牙阶段——`BTC_ENABLED(4)` /
   `BTC_REQUEST_RECEIVED(5)`、成功 `BTC_PAIRING_SUCCESS(8)`（`:588-592`）。
6. 等终止态，上限 30 s（`:72`）。若 2500 ms 内 EE03 一条通知都没有，也主动请求 bonding（`:596-621`）。
   **系统 bond 状态才是权威成功信号**：ILCE-7M4 实测机身显示配对成功、EE03 却一条通知都不发，只等通知会把
   已完成的配对判成超时（`:601-614`）。
7. 成功即返回：**不写 CC08、不读凭据、不连热点**，也不缓存凭据（`:668-679`）。

### 3.3 状态帧与结果码

EE03 帧 `[len][0][0][type][v31][v23][v15][v7]`：`type` 1 = 状态、2 = 结果，值是大端 u32
（`SonyCameraService.ets:360-375`），解析器要求至少 8 字节以免 u32 越界读（`:366-369`）。注意
`SonyBleProvisioning.ets:40` 的注释写"7 字节"却列出 8 个字段，解析器按 8 字节走——以解析器为准。

九个配对状态（`stateLabel`，`SonyCameraService.ets:378-391`）：1 相机已收到配对请求、2 蓝牙认证通过、
3 蓝牙认证被拒、4 经典蓝牙已启用、5 相机已收到经典蓝牙配对请求、6 经典蓝牙认证通过、7 经典蓝牙认证被拒、
8 配对成功、9 相机端已取消。

十个结果码（`resultLabel`，`:394-408`）：1 配对成功、2 蓝牙认证被拒、3 蓝牙配对失败、4 经典蓝牙认证被拒、
5 经典蓝牙配对失败、6 用户取消、7 相机未进入配对窗口、8 MFi 认证被拒、9 随机数不匹配、10 配对注册失败。

状态 `3/7/9` 与任何非 1 的结果立即失败；状态 `8` 或结果 `1` 为成功（`SonyBleProvisioning.ets:627-654`）。

### 3.4 身份读取帧（EE04）

`[len][type_hi][type_lo][fwLen][firmware][modelLen][model]`：`type` 必须为 0（相机信息帧），`len` 非 0 时整帧
必须够长，机型为空判失败（`SonyCameraService.ets:336-358`）。字符串按 ASCII 逐字节取、遇 0 截断、出现不可打印
字节整帧作废（`:410-419`）。

## 4. Wi-Fi 凭据与入网（`startWifi`，`SonyBleProvisioning.ets:698-819`）

1. 幂等短路：手机已在相机热点上（本进程加入过的 SSID，或 SSID 命中 DIRECT-…:机型）立即成功，网关最多轮询
   6×1 s 等 DHCP 租约（`:701-712`、`:854-888`）。否则重连 GATT：配对阶段留下的连接还能 `getServices()` 就复用；
   否则重连，并在记住的地址不应答时重新发现一次——经典蓝牙 bond 可能换掉 BLE 地址（`:890-937`）。
2. 写 CC08 `{1}` 开相机 Wi-Fi，等 4000 ms 稳定（`:737-751`、`:74`）；特征缺失时记日志并按"热点已起"继续。
3. 读 CC06 / CC07 / CC0C：三者都是 **3 字节头 `[len][type_hi][type_lo]` + US-ASCII**，读到 0x00 或非法字节即止，
   `length <= 3` 当空（`:939-967`，与官方 `BluetoothGattUtil.getWifiInfo` 一致）。BSSID 可选，官方读不到时也只
   跳过（`:781-784`）。SSID 或密码为空即失败，不猜。
4. 入网调共享的 `connectWifi(ssid, password, trace, 1, cb, 75000, true)`：`joinAttempts=1`、总预算 75 s、
   `skipScanWhenLinked=true`。最后这个标志有实测理由——控制页可能已在这张网上跑着 PTP/IP 会话，入网时每 2.5 s
   一次 `startScan()` 会把它打断（ILCE-7M4 实测：事务超时、会话毒化、LiveViewUrl 再也读不到，`:791-798`）。

### 4.1 DiRxTx（8000BB00）为什么不实现

`SonyBleProvisioning.ets:48-53`：DiRxTx 及其 ECDH P-256 + AES-CTR 的 "secure AP pouring" 变体用于**反向**
场景——手机自己开热点，把**手机的** AP 凭据加密交给相机。本应用只加入相机的 AP，所以走明文 CC06/CC07；加密
注网没有实现，也不需要。同一清单里的 CC17（SSH 账号口令）在诊断中只记长度与存在，内容永不落日志（`:986-1021`）。

## 5. PTP/IP 传输层（共享，`NikonPtpIpService.ets`）

- 端口 15740，两条 TCP 连接：command 与 event（`:492`、`:1909-1935`）。握手包类型 `1 Init_Command`、
  `2 Init_Command_Ack`、`3 Init_Event`、`4 Init_Event_Ack`（`:494-497`）；`Init_Command` 载荷 = 16 字节 GUID +
  UTF-16 名称 `"Pixelshop Camera"` + u32 版本 `0x00010000`（`:482-484`、`:2696-2701`），`Init_Event` 载荷是 Ack
  带回的 `connectionNumber`（`:1930-1935`）。
- 事务包类型 `6 Operation_Request`、`7 Operation_Response`、`9 Start_Data`、`10 Data`、`12 End_Data`
  （`:498-523`）。**12 而不是规范表的 11**：代码保留实测结论——改回 11 后相机对结束帧完全不理会，一次"快速
  拒绝"变成 10 s 挂死加会话毒化；故发送端用 12，接收端两者都认（`:502-525`）。
- 会话打开：握手完成后在**事务号 0** 上发 session-open 操作（`:1936-1951`）。默认 `0x1002 [1]`，索尼要求
  `0x9210 [1, 2]`（见 5.1），所以 `acquireSession` 把打开操作做成参数；已开会话再开得到
  `0x201E SessionAlreadyOpen`（`:540`、`:1942-1947`）。
- 事务串行化：`enqueue` 单队列，同一时刻只有一个请求/响应（含完整数据阶段）占用 command 通道；数据阶段长度必须
  等于 StartData 声明的 u64，否则抛 `PTP/IP data length mismatch`（`:436-454`、`:2257-2331`）；`enqueueDataOut`
  供索尼控制命令发送 0/2/4 字节数据阶段（`:456-472`）。
- 事件通道：每会话一个被动循环，`next(60000)` 超时属正常空闲（`:2411-2447`）。`DevicePropChanged`(0x4006) 只
  登记不回读——机身挂起取景流后不再处理命令，此刻回读只会超时并毒化会话，变化集留给控制页在安全窗口统一读
  （`:2462-2476`）。
- 主机地址取 Wi-Fi 的 DHCP 网关（`CameraPage.ets:5594-5605`、`:7292`），不是 SSDP 的 LOCATION；官方从 SSDP 取
  host 这一点被记为诊断假设 H3（`SonyConnectionDiagnostics.ets:14`）。

### 5.1 OpenSession 之后的索尼初始化序列

标准 `OpenSession` 不够：索尼在 PTP/IP 会话之上还有自己的厂商会话，未跑完则扩展操作全被拒
（`SonyPtpIpContent.ets:32-40`）。`setupSonySession`（`:2023-2095`）按官方 `Initializer` 顺序执行，每会话一次
（缓存，翻页不重跑）：

| 步 | 操作 | 参数 | 说明 |
| --- | --- | --- | --- |
| S1 | `0x1001 GetDeviceInfo` | 无 | 被拒即中止，记录首个失败步 |
| S1b | `0x923A` DD 文档 | `[1]` | 非致命，仅取证 |
| S1c | `0x923A` DID 文档 | `[2]` | 读 `X_ServerVersion`，≥4.0 才需要 mode 2 |
| S2 | `0x9210 SDIO_OpenSession` | `[1, 2]` | `2 = REMOTE_CONTROL_WITH_TRANSFER_MODE` |
| S3 | `0x9201 SDIO_Connect` | `[1,0,0]` | |
| S4 | `0x9201 SDIO_Connect` | `[2,0,0]` | |
| S5 | `0x9216 GetVendorCodeVersion` | 空 | 返回首个响应参数；≥310 时后续带 flag |
| S6 | `0x9202 GetExtDeviceInfo` | `[300]` / `[300,1]` | 机身自述的属性/事件码表 |
| S7 | `0x9201 SDIO_Connect` | `[3,0,0]` | 此步触发 `onInitialized`，之后才发 0x9209 |

S7 是分水岭：`onInitialized` 之前发 0x9209/0x9202/0x9216 会被拒，而 0x9212 之类简单设置却可能被接受——这正是
"部分操作可用、属性表永远为空"的成因（`:56-63`、`:2003-2010`）。`0x9210` 是**替代**而非追加 `0x1002`（官方两条
分支是同一个 if/else，`:78-120`、`:1209-1216`），所以浏览路径直接以 mode-2 开会话；只有 mode-2 会话连六步都跑
不通时才回退标准开会话，并把"下次用标准"钉住（`:4395-4410`）。

图传要点：`0x923B`（1 个 u32 槽号）与 `0x923C`（5 个 u32：时间戳高低位、每页条数、槽号、顺序标志）列举媒体，槽位看
`ContentsInfoListEnableStatusSlot1/2`（53716/53717）与 `MediaSLOT1Status/2Status`（53832/53846）；原图 `0x923D`
每次 ≤3 MiB 带偏移，缩略图 `0x923E` 单次数据阶段（`SonyPtpIpContent.ets:231-267`、`:1578-1650`、`:4956-5010`）。
`0x9212` 可开关、默认跳过（`:1347-1362`）。

## 6. 控制：读 0x9209、写 0x9205

### 6.1 一条自述记录同时给值和可选值

`0x9209` 是数据入阶段，参数 `[0]`（首次）或 `[0,1]`（版本 ≥310）；官方按 `SDIE_DevicePropChanged` 刷新时用
`[1, flag]`（`SonyPtpIpContent.ets:141-153`、`:2555-2574`）。载荷 = u64 记录数 + 记录：

```
u16 code, u16 dataType, u8 getSet, u8 isEnable,
<defaultValue> <currentValue>      按 dataType 编码
u8 formFlag   0 -> 无   1 -> 再 3 个值(min/max/step)   2 -> u16 n + n 个值，再 u16 m + m 个值
```

（`:820-853`。）formFlag-2 的**两个** u16 计数数组在**同一条记录**里：第一个是官方无序 `mSetValues`
（HashSet），第二个是有序 `mGetSetValues`（LinkedList）。面板要显示第二个，第一个只作成员过滤；两者都随这次
0x9209 到达，不需要额外往返（`:867-882`、`:1032-1048`、`:1084-1103`）。`DATA_TYPE_STR` 记录同样保留，
`LiveViewUrl` 就从这里读（`:857-866`）。

解析器以 `receivedBytes`（传输层真实数据阶段长度）为分母，只有"走完的字节数 == 收到的字节数"才算 `clean`，
对应官方 `position == capacity` 断言（`:170-191`、`:1073-1081`）。首轮 dump 只有部分记录是正常的：官方把每次
应答合并进一个累积 map，刷新应答可以只含变化项，本端口同样合并（值、字符串、可选值、getSet、dataType 都不被
后续 delta 抹掉），并以本次尝试中最大的那次载荷作为遍历判定的归属（`:193-230`）。

### 6.2 可写性判定与写入

`canSet = isEnable == True && getSet == GetSet`（`SonyPtpIpContent.ets:3104-3109`，getSet 八位组的来源与理由见
`:889-896`），`DispOnly(2)` 只可显示不可写；再叠加全局 `RemoteControlRestrictionStatus`（53860，必须为 0，
`SonyPtpIpControl.ets:124-136`）。记录缺失按"不禁用"处理。两条都在发包前检查，未通过只产生日志、不发请求
（`:496-528`）。

写入走 `SDIO_SetExtDevicePropValue`（0x9205），参数 `[code]`，厂商码版本 ≥310 时 `[code, 1]`；数据阶段是该属性
**自己声明的** `EnumDataType` 对应的明文小端标量，不补齐、不用数组形式（`SonyPtpIpControl.ets:13-19`、
`:516-527`、`:539-556`）。宽度一律查 0x9209 记录：硬编码 2 字节在某台可行、在另一台会写坏值（`:530-537`）。
这不是 `0x1016 SetDevicePropValue`——索尼的操作码枚举里根本没有 0x1016（`SonyPtpIpContent.ets:1559-1562`）。
设置成功后把值写回累积表，否则面板一直显示旧值（`:3061-3078`）。

### 6.3 参数表与 ILCE-7M4 只读案例

| 面板 | 属性码 | 格式化规则（`SonyPtpIpControl.formatValue`） |
| --- | --- | --- |
| 光圈 | `FNumber` 20487 | f 值 ×100，<10 保留一位小数；0/65534/65535 显示 `--` |
| 快门 | `ShutterSpeed` 53773 / `ExtendedShutterSpeed` 53663 | 低 16 位分母、高 16 位分子；全 0 为 BULB；分母 10 表示秒 |
| ISO | `ISOSensitivity` 53790 | 低 24 位为 ISO，0xFFFFFF 为 AUTO |
| EV | `ExposureBiasCompensation` 20496 | 有符号 16 位毫 EV，`±0.0` 表示 0 |
| 模式 | `ExposureProgramMode` 20494 | 全 32 位精确匹配 62 项表（P/A/S/M、场景、视频、S&Q） |
| WB | `WhiteBalance` 20485 | 掩 16 位后精确匹配（含 0x8001… 荧光/自定义/水下） |
| 画质 | 回退链 0xD288 → 0xD287 → 0xD252 | RAW 压缩档 / JPEG-HEIF / JPEG 等级 |
| 比例 | `AspectRatio` 53777 | 掩低字节：1=3:2、2=16:9、3=4:3、4=1:1 |

快门是唯一"读用 A、写用 B"的参数：扩展快门只要能读（`isEnable` 为 True 或 DispOnly）就用扩展属性读，只有能
SET 时才用扩展属性写，否则一律走普通 `ShutterSpeed`（`SonyPtpIpControl.ets:89-122`）。真机 ILCE-7M4 的只读案例
（均来自代码中的实测记录）：

- `ExposureProgramMode 20494` 为 `opt0:ro`——机身拨盘控制，遥控侧只读，模式面板显示当前档位但点不动；这是相机
  的声明，不是我们的限制（`CameraControlBrand.ets:58-60`）。
- `CompressionSetting 0x5004` 根本不在 0x9209 记录里（`0x5004:none:opt0:ro`）；`JPEGQuality 0xD252` 声明只读且
  当前值 0（Sony 的 Undefined）。同一批记录里 `CompressionFileFormat 0xD287`（`opt3:set`）、
  `RawFileType 0xD288`（`opt5:set`）、`AspectRatio 0xD211`（`opt4:set`）却可写——同样是 UINT8 + 四选项，差别在
  机身声明本身（`SonyPtpIpControl.ets:246-301`）。故画质面板按 0xD288 → 0xD287 → 0xD252 回退。
- 强写只读画质会被本地拦下并记 `sony set quality refused: camera does not allow a set code=53842`
  （`:274-283`、`:506-510`）。

## 7. 取景与快门

先纠正一处文档口径：页面层注释把索尼取景通道写成 `0x9201 / 0x9203 / 0x9202`（`CameraControlBrand.ets:16`、
`:83-85`、`CameraPage.ets:279`、`:1708`），**实现不是这样**——`0x9201` 是 `SDIO_Connect`、`0x9202` 是
`SDIO_GetExtDeviceInfo`，两者都是 §5.1 的会话建立步骤；`0x9203` 是**尼康**的 `GetLiveViewImage`
（`NikonPtpIpService.ets:573`）；`SonyLiveView.ets:139-141` 明确写着本模块"从不发 0x9201/0x9202/0x9203"。
索尼的取景开关与快门都在 `0x9207 SDIO_ControlDevice`，帧来自一条独立 HTTP 流。

| 用途 | 控制码 | 参数 | 数据阶段 |
| --- | --- | --- | --- |
| 开/关实时取景 | `54035 SetLiveViewEnable` | `[54035, flag]` | 2 字节 LE：`02 00` 开、`01 00` 关 |
| AF 半按 / 快门 | `53953 S1Button` / `53954 S2Button` | `[code, flag]` | 2 字节 LE `Down(2)` / `Up(1)`；快门 = S1 按下 → S2 按下 → S2 松开 → S1 松开 |
| 录像 | `53960 MovieRecButton` | `[53960, flag]` | 开只按下、停是按下 + 松开（官方即不对称） |
| 触摸 AF / 取消 | `53988` / `53989` | `[code, flag]` | 4 字节 LE（x 高 16 位、y 低 16 位，640×480 网格）/ 2 字节 LE |
| 已废弃 | `53959 RequestOneShooting` | `[53959, flag]` | **0 字节**，见下 |

`flag` 来自 `SDIO_GetVendorCodeVersion` 的版本，≥310 才追加第二个参数 1（`SonyLiveView.ets:26-30`、
`:313-347`）。这不是可选优化：版本读失败会让参数退化成 `[54035]`，机身回 `0x2005`，取景 HTTP 流随即答 503
（`:314-322` 的实测记录），所以优先复用六步 setup 已读到的值。

- 取景 URL：属性 `LiveViewUrl` 53880（字符串）取自累积的 0x9209 表；回退是 DD 文档
  `X_ScalarWebAPI_LiveView_URL`。**不对该属性发定向 `GetDevicePropValue`**——0x9210 会话上机身根本不答，十秒后
  对端关 socket，整条会话作废（`SonyPtpIpContent.ets:2437-2443`、`:2455-2489`）。
- 流：一次 HTTP GET，默认端口 60152，永不结束的 200 响应；帧由 16 字节小端头分隔（图像偏移/长度、焦点框信息
  偏移/长度），只取 JPEG 段，焦点/AF 叠加块丢弃（`SonyLiveView.ets:81-119`）；与 PTP/IP 是两条独立连接，不复用
  命令通道（`:1078-1087`）。
- 快门：`captureStill` 按官方顺序——按下发 S1 down，抬起发 S2 down、S2 up、S1 up，四条事务严格串行；不轮询
  `FocusIndication`，S1 在任何路径上都会松开（`SonyLiveView.ets:474-528`）。`requestOneShooting` 仅作诊断保留：
  其控制码序号 5 在官方 `getData` 里没有分支，载荷 0 字节，官方代码树也无调用者（`:619-647`）。
- 会话前置：0x9207 只能在 `0x9210`（mode 2）且六步 setup 跑过的会话上发出。把 0x1002 会话直接升级成 0x9210 而
  不重跑六步时，机身对 `0x9209` 与取景开关都回 `0x2005`，流停在 503，而两秒前同一台机身对跑过六步的会话正常
  返回 351 条属性（`:649-728`）。

## 8. 实现对照表

| 能力 | 实现位置 | 状态 |
| --- | --- | --- |
| BLE 扫描/准入 | `SonyBleProvisioning.findCamera` | 已实现，制造数据或机型名二选一 |
| GATT 连接/MTU/bond | 同上 `:420-430`、`:534-564`、`:898-937` | 已实现，bond 后地址变化会重发现 |
| 配对握手 / 身份 | `:472-655`；EE04 + `parsePairingIdentity` | 已实现，两段式；EE03 可能无通知 |
| Wi-Fi 开热点 + 凭据 | CC08 `{1}` + CC06/CC07/CC0C | 已实现，BSSID 可选，按需调用 |
| 入网 | 共享 `connectWifi`，跳过扫描 | 已实现 |
| PTP/IP 传输 | `NikonPtpIpService` | 共用，端口 15740 |
| 索尼会话初始化 | `setupSonySession` 六步 + 0x9210 | 已实现，每会话一次 |
| 属性读取 / 写入 | 0x9209 记录；0x9205 `[code]` / `[code,1]` | 已实现，含可选值；宽度取自述类型 |
| 图传枚举 | 0x923B / 0x923C（0x9212 默认跳过） | 已实现，双卡槽探测 |
| 缩略图 / 原图 | 0x923E 单次 / 0x923D 每次 ≤3 MiB | 已实现，`.part` 完成后改名 |
| 实时取景 / 快门 / 录像 / 触摸 AF | 0x9207 + HTTP 60152 | 已实现 |
| 事件驱动属性刷新 | 0x4006 只登记 | 部分实现，靠安全窗口回读 |
| DiRxTx 反向注网 / SSH 隧道 | — | 刻意不实现（后者仅诊断记录能力位） |

## 9. 限制与边界

**机型差异。** 机型表 26 条只决定身份与配图，不保证同一组属性；可写性完全由机身 0x9209 记录决定（ILCE-7M4 上模式与 JPEG 画质即只读）。ILCE-7M5 实测出现"Wi-Fi 已连、会话未建立、蓝牙状态反复跳"，而同样代码在 ILCE-7M4 可用（`SonyConnectionDiagnostics.ets:1-20`）。其中一个候选是官方 `SshSupportCamera`：`X_SSH_Support=Enable` 时官方根本不连 15740，而是 SSH 到 22 端口再本地转发；判定需 DID 与 CC0D 能力位一起看（`SonyBleProvisioning.ets:979-1007`）。本应用不建隧道，这类机身只能得到"能配对、连不上 PTP/IP"的结果——这是未覆盖的机型分支，不是配对失败。

**机内限制。** 三类硬门控都在本端提前判掉：属性 `ro`/`DispOnly`、全局 `RemoteControlRestrictionStatus != 0`、以及取景要求 mode-2 会话且初始化完成。卡槽还有两层：`ContentsInfoListEnableStatusSlot1/2` 是**应用权限位**而非介质在位位，真正的介质状态是 `MediaSLOT1Status/2Status`（53832/53846，255 掩码：OK=1、无卡=2、卡错=3、识别中=4），所以槽位选择是"介质感知"的、两个槽都带重试（`SonyPtpIpContent.ets:250-267`、`:1246-1256`）。无卡时 0x923B 会被拒，这正是过去那条无法解释的 `0x923B` 错误。

**无需 PC Remote 常开的边界。** 蓝牙侧写 CC08 `{1}` 就由机身自己拉起热点，用户不必先在相机菜单里打开「PC 远程功能」；页面为此保留两个入口——「开始配对」走蓝牙配网，「继续连接（已开热点）」直接加入用户手动开的 PC 远程热点（`CameraPage.ets:4850-4908`）。边界三条：其一，配对阶段仍要求机身蓝牙开启并处于配对窗口，手机侧要确认系统弹窗；其二，热点起来不等于会话可用，PTP/IP 仍需 0x9210 + 六步初始化，否则属性与取景一律 `0x2005`；其三，若机身选择了 SSH 隧道（见上），PC Remote 热点在 15740 上不监听，本应用无法继续。

**已知未覆盖。** 色温属性 `ColorTemperature` 53775 存在但未接面板（`SonyPtpIpControl.ets:197-207`）；事件驱动刷新只登记不回读；`0x923E` 的 SCREENNAIL 变体未用；索尼路径不用 `0x9211 GetPartialLargeObject`（那是标准 PTP 句柄读取，ILCE-7M4 对 contents 拒绝，`SonyPtpIpContent.ets:1600-1607`）；视频/音频元数据解析不在范围内。

**推断（明确标注）。** 各机型 tag 33/34/35 的"启用"三态取值分布未见真机汇总，本文只复述解码规则；EE03 在 ILCE-7M4 上不发通知是否也发生在其他机型，现有代码只留了"bond 状态兜底"这一种处理，没有机型维度证据。
