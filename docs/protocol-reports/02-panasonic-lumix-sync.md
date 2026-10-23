# 松下三条线之二：LUMIX Sync 世代（BLE GATT 配对 + cam.cgi + DMS 拉取）

> [English](en/02-panasonic-lumix-sync.md) | 简体中文

- 基线提交：`18466be`（工作区 `C:\Users\HQ\DevEcoStudioProjects\VIVID`，ArkTS 工程 Vivid）
- 证据来源：只读代码。主要文件 `LumixSyncControlService.ets`（2052 行）、`LumixSyncImageTransfer.ets`（1684 行）、`LumixImportPrototype.ets`（4450 行）、`LumixCameraService.ets`、`CameraSessionStore.ets`、`pages/home/CameraPage.ets`、`pages/CameraControlPage.ets`
- 文中"官方"指代码注释记录的 LUMIX Sync 官方 APK（jadx）与真机抓包结论（注释带日期），不是本次重新反编译或抓包
- 代码无法证实的标"推断"并给依据；注释未写用途的 UUID 写"代码未标注"

## 0. 摘要

LUMIX Sync 线是"前 Lab"松下机身的连接方式：BLE GATT 把手机身份登记进相机并取回热点凭据 → 手机加入相机 SoftAP → HTTP `cam.cgi` 授权与控制 → 机身内建 DLNA MediaServer（DMS）主动拉图。三个协议层分落三处：BLE 配对与 cam.cgi 在 `LumixSyncControlService.ets`，DMS 浏览/下载在 `LumixSyncImageTransfer.ets`，GATT 读写与 Wi-Fi 加入等通用能力在 `LumixImportPrototype.ets`。最关键的两个事实是 **`req_acc` 才是注册提交**（首次 `ok_under_research`，重发才 `ok`）与**提交后必须留十几秒静默期**（官方 19 s / 34 s，本实现曾因 2 s 被立刻拒绝），两者都在 `LumixSyncControlService.ets:31-52` 的头部注释里有抓包时间戳支撑。

## 1. 线路定位与机型互斥

### 1.1 三条线

`panasonicRouteForModel()` 返回 `'lab'` / `'sync'` / `'lumix_image'` / `''`（`LumixCameraService.ets:1742-1807`）：

| 线路 | 协议形态 | 机型（代码常量） |
| --- | --- | --- |
| `lab` | Lab REST（HTTPS `/auth`、`/media/...`）+ BLE 注册 | S5M2X、S5M2、S1RII/S1RM2、S1II/S1M2、S1IIE/S1M2E、S9、GH7、G9II/G9M2、L10（`LumixCameraService.ets:302-303`） |
| `sync` | BLE GATT 配对 + `cam.cgi` + DMS | S1H、S1R、G100、G100D、GH5M2、GH6、GH1（`LumixCameraService.ets:336-338`），另加经 `isWifiOnlyModel` 纳入的初代 S5 与 ZS300/TZ300 |
| `lumix_image` | 无蓝牙，手动/二维码接热点 + SSDP + `cam.cgi` + DLNA，保留相机端被动推送 | TZ99、ZS99、G90/G91/G95/G95D、TZ95~TZ97、ZS80、GH5、GH5S、G9 等（`LumixCameraService.ets:372-401`） |

### 1.2 与 Lab 线的互斥

互斥是显式不变量，不是"谁先判"的副作用。Sync 表定义处写明：路由一台 Lab 机身进 Sync 线会让同一台相机被两条线同时认领，所以 `PANASONIC_SYNC_MODEL_TOKENS` 直接从候选里减掉 Lab 表，只按 token 精确相等相减（`LumixCameraService.ets:305-338`）。同处还记录：**GH5 / GH5S / G9 于 2026-10-11 从 Sync 线移到 Image App 线**——Sync 源码里这三者只出现在旧版 UI/菜单特例（`g5/a.java:84`、`x5/C3066j.java:330`、`N5/l.java:1378`），而官方 Image App 支持表明确列了 DC-GH5/GH5S/G9，且三者都无蓝牙，留在 BLE 门控的本线等于永远连不上。

七个 Sync token 与 Lab 表无一重合，全部保留；Sync 的 `S1R` 与 Lab 的 `S1RM2`/`S1RII` 不同串，互不吞并。判定顺序为 Lab 表 → 初代 S5 → "BLE 见过但不是 Lab"（`fromBle`，2026-10-18 规则）→ `isWifiOnlyModel` → Sync token 表 → Image App 兜底（`LumixCameraService.ets:1766-1806`）。Lab 必须最前：调用方传的是"机型 + BLE 候选机型 + BLE 广播名"三段拼接，先跑 `isWifiOnlyModel` 会让残留 S5/ZS300 token 把 S1RM2/S9 整条误路由到 Sync（2026-10-11 真机：S1RM2 取图库误走 sync 线）。

### 1.3 S5 / ZS300 特例

`isWifiOnlyModel()` 的注释先纠错：这个名字**不代表没有蓝牙**，集合内机身都有蓝牙、凭据由 Sync 的 BLE 配对下发，谓词只回答"要不要走 Lab 那套 GATT 注册"（`LumixCameraService.ets:449-460`）。实现按空白分词逐 token 判，`S5M2`/`S5M2X` 一旦出现即整体否决（`461-496`）。ZS300 与 TZ300 是同一机身的两地名称，裸机型串、带厂牌前缀、机型+实例后缀三种形态都认，用锚定正则，不允许 `endsWith`/`indexOf` 部分匹配（`498-520`）。S5 另有独立的 `requestS5Access()`：`value` 放客户端标识、`value2` 放 DMS 网络名（默认 `WEB-W00`，注释明确它不是相机 SSID 或密码），与主路径 `value2=Pixelshop` 不同，且不在 `pairAndConnect` 流程内（`2208-2235`）。

## 2. BLE 配对

### 2.1 广播识别

扫描按 Sync 服务 UUID `054ac620-3214-11e6-ac0d-0002a5d5c51b` 过滤（`LumixImportPrototype.ets:312`）。识别用的是广播里的协议字段，而不是可随意修改的显示名（`313-343`、`2220-2284`）：

1. **厂商数据（AD type 0xFF）**：company ID 58（小端 2 字节）+ 恰好 6 字节负载，负载字节 2..5 是 4 字节公网蓝牙地址，即代码里的 `btAddress`（8 位 16 进制）。地址偏移在官方两个状态分支都固定为 2；状态字节要在 6 字节里扫第一个 0 或 3，位置不固定。
2. **本地名末两字节**：倒数第二字节 `0x0A` 标记、最后一字节机型码 1..9，映射表 `['', 'S9', 'GH7', 'S5M2', 'S5M2X', 'G9M2', 'S1M2E', 'S1M2', 'S1RM2', 'L10']`（`339-343`）。这张表是 **Lab APK 的表**，Sync 机身是否落在 1..9 内代码没有答案；`logAdvertisement()` 把"某台 Sync 机身到底广播什么码"列为 APK 无法回答、只能靠设备日志取证的问题，码值超出范围时该机身保持名字回退、路由不变（`2201-2218`）。
3. AD type 0x06/0x07 里出现该服务 UUID（128 bit 小端）时置 `hasLumixService`，仅诊断（`2271-2280`）。

据此纠正一个常见说法：**厂商数据里没有机型码**，它只提供 4 字节蓝牙地址这一"短身份"，机型码在本地名末字节里；两者组合才是本线的稳定标识（改相机名字只影响后者，改地址只影响前者）。注释里写明两处"放宽"：服务 UUID 与"某字节为 0 或 3"的状态检查只记日志不强制，强信号是 company 58 六字节 + 1..9 码值；58 与尼康 135、索尼 301 不会碰撞。

### 2.2 服务与特征 UUID

主服务 `054ac620-3214-11e6-ac0d-0002a5d5c51b`（`LumixSyncControlService.ets:135`）。用途照抄 `indexSyncCharacteristics()` 的注释（`1798-1828`），注释没写的一律"代码未标注"：

| UUID | 服务 | 代码用途 |
| --- | --- | --- |
| `03e23a31-a54c-40fa-a668-de9acdc910bb` | 054ac620 | `INITIAL_INFORM`，读会话密钥（前 4 字节） |
| `bb5d2a8c-5d3b-43ad-bfc3-470cad55c1ca` | 054ac620 | APS 机身 DLNA UUID 写入（o.d 编码） |
| `7b61774f-efb4-44c6-a66d-c69e3b384c4a` | 054ac620 | APS 机身友好名写入（o.c 编码） |
| `e206a5c0-3214-11e6-afe4-0002a5d5c51b` | 054ac620 | Wi-Fi SSID 读取（分号列表） |
| `c97cf1a5-3c03-4290-8c1b-9e74b9500f54` | 054ac620 | Wi-Fi 密码读取（XOR 编码，长度字节在前） |
| `8d08a420-3213-11e6-8aca-0002a5d5c51b` | 054ac620 | 传统机身明文 16 字节身份写入 |
| `cd7a71a0-3213-11e6-8f56-0002a5d5c51b` | 054ac620 | 传统机身友好名（ASCII）写入 |
| `e182ec40-3213-11e6-ab07-0002a5d5c51b` | 054ac620 | action mode 写入（`{0x03}`） |
| `0d6f1880-3217-11e6-a4cb-0002a5d5c51b` | 5ae57260（完整 UUID 代码未标注） | Wi-Fi 连接类型写入（`{0x01}`/`{0x02}`/`{0x03}`） |
| `18345be0-3217-11e6-b56c-0002a5d5c51b` | 5ae57260（完整 UUID 代码未标注） | STA SSID 确认，32 字节 NUL 填充 ASCII |
| `18345be1-3217-11e6-b56c-0002a5d5c51b` | 代码未标注（注释只按 18345be* 族归类） | 推送：`value[0]=1` 表示 SoftAP 链路生效 |
| `e182ec43-3213-11e6-ab07-0002a5d5c51b` | 代码未标注 | 推送：`3`=配对就绪，`1`/`4`=请求连接类型 |
| `e182ec41-3213-11e6-ab07-0002a5d5c51b` | 代码未标注 | 推送：`1`=拒绝控制模式，`0`=控制会话生效 |

`0d6f1880` 与 `18345be0` 不在主服务上：索引函数先按 UUID 认这两个（不限服务），之后才用 `serviceUuid !== SYNC_BLE_SERVICE` 限制其余特征（`1804-1816`）。

### 2.3 十个通知特征

`SYNC_NOTIFY_UUIDS` 固定十项、按序注册、注册在身份写入之前（2026-09-25 抓包：十连 CCCD 早于 `writeUuid` 约 600 ms，`LumixSyncControlService.ets:184-200`）：

| # | UUID | 代码标注 |
| --- | --- | --- |
| 1 | `4cf487c0-32a7-11e6-a50d-0002a5d5c51b` | 代码未标注 |
| 2 | `37701b80-32a7-11e6-bb83-0002a5d5c51b` | 代码未标注 |
| 3 | `18345be1-3217-11e6-b56c-0002a5d5c51b` | SoftAP 生效推送 |
| 4 | `48669da0-3217-11e6-b08d-0002a5d5c51b` | 代码未标注 |
| 5 | `e182ec43-3213-11e6-ab07-0002a5d5c51b` | 配对状态 / 连接类型请求 |
| 6 | `da534d0a-63a3-447c-a889-aab701906af2` | 代码未标注 |
| 7 | `d611b4a0-3217-11e6-8d98-0002a5d5c51b` | 代码未标注 |
| 8 | `e182ec41-3213-11e6-ab07-0002a5d5c51b` | 控制模式结果 |
| 9 | `e182ec42-3213-11e6-ab07-0002a5d5c51b` | 代码未标注（推断与 e182ec41/43 同族，依据仅 UUID 前缀） |
| 10 | `7be5fe6e-475b-11e7-a919-92ebcb67fe33` | 代码未标注 |

注册用 `setCharacteristicChangeNotification(true)`，CCCD 写由平台代管（`1341-1377`，CCCD 常量 `00002902-0000-1000-8000-00805f9b34fb`）。这里有一处与官方相反的事实：官方十次通知注册**全部失败于 `No_Descriptor`**、全新注册一个 CCCD 都没写成功，相机照样继续；HarmonyOS 代管的 CCCD 写相机是容忍的（2026-09-25 配对成功即带这些写）。所以本地订阅保留，但流程不再以 `pairReady` 为门控，`e182ec43` 的值只作诊断（`149-152`、`328-331`）。

### 2.4 身份帧（MEI0 / o.d / o.c）

16 字节 = 固定前缀 + 12 位 16 进制种子（`LumixSyncControlService.ets:1687-1727`）：

- 线上形态：`4D454930010010008001` + 12 位种子 = 32 字符（16 字节），`4D 45 49 30` 即 ASCII `MEI0`
- 点分形态（给 `cam.cgi`）：`4D454930-0100-1000-8001-XXXXXXXXXXXX`，5 段、末段 12 位，非标准 UUID 形状

种子优先级：OAID 前 12 位 16 进制 → 已存 `syncDlnaSeed` → 6 字节随机。注释解释不能每次随机：重装清空偏好后，每次重装都变成相机眼里的新设备（2026-09-26 重装后配对在"信任 Wi-Fi"那一刻失败，重装前同样流程每次成功）；官方种子同样设备派生，注入版 APK 四次改签名重装后仍呈现同一个 `MEI0...02C30003AF62`。前缀段含义代码未标注（推断为版本/设备类别字段，依据仅"官方样例恒定"）。

写入两条分支，判据是 APS 特征是否齐全（`dlnaUuidAps` 与 `friendlyNameAps` 同时存在，`471`）：

- **传统机身**：16 字节明文身份写 `8d08a420`，300 ms 后 ASCII 友好名 `Pixelshop` 写 `cd7a71a0`（`493-511`）
- **APS 机身**：先读 `INITIAL_INFORM` 取密钥，再写 `bb5d2a8c`（身份，`uuidLayout=true`）与 `7b61774f`（名字，`uuidLayout=false`），间隔同为 300 ms

两者共用 `encodeApsBlock()`（`1873-1900`）：明文铺成 20 字节 `[len][data≤16][填充]`，末三字节恒 `0xFF`，填充在 uuidLayout 分支为 `0xFF`、名字分支为 `0x00`；再每 4 字节一组"反转 + 与密钥前向顺序异或"：

```
encoded[i+0] = plain[i+3] ^ key[0]
encoded[i+1] = plain[i+2] ^ key[1]
encoded[i+2] = plain[i+1] ^ key[2]
encoded[i+3] = plain[i+0] ^ key[3]
```

### 2.5 INITIAL_INFORM 会话密钥

`readSessionKey()` 读 `03e23a31` 整段值取前 4 字节（注释称 big-endian）；长度不足 4 或前 4 字节全零时用默认密钥 `0x9032782C`（字节 `90 32 78 2C`，`143-146`、`1848-1871`）。全零语义是"相机还没和任何客户端配对过"，jadx 出处写在常量注释里（`N5/o.java` 的 `j9 = j7 == 0 ? -1875740628L : j7`，-1875740628 即 0x9032782C）。读取失败或特征缺失不致命，直接落默认值；读取有 5 s 超时（`stepWithTimeout`，`1269-1297`）。当前实现会把密钥明文写 hilog，注释承认是临时状态、待复原脱敏（`1857-1859`）。

### 2.6 Wi-Fi 连接类型协商

两个方向的值含义都来自 jadx `i5/g.java`：

- 相机推 `e182ec43`：`value[0]=1|4` 询问连接类型，`value[0]=3` 配对就绪（`149-153`、`364-372`）
- 手机写 `0d6f1880`：`{0x01}` SoftAP、`{0x02}` STA、`{0x03}` 请求重启/切换（`154-159`、`638-651`、`731-744`、`804-808`）
- 手机写 `e182ec40` action mode：`{0x03}`（注释纠正了早期静态分析猜的 `{0x01}`，抓包确认是 `{0x03}`，`160-164`）

官方完整确认链只在 `withControlDance=true` 的可选分支复刻：写 `18345be0`（当前已连 SSID 的 32 字节 NUL 填充 ASCII）→ 写 `0d6f1880 {0x03}` → 等 `18345be1` 推送 → 按首字节回 `{0x01}`（非 0）或 `{0x02}`（为 0，即 STA）→ 写 `e182ec40 {0x03}` → 1.5 s 后查 `e182ec41` 是否 `b0=1`（`710-752`）。`{0x03}` 会让相机重启 SoftAP，抓包里约 41 s 信标中断，之后必须重连 Wi-Fi 再刷新 `req_acc`。默认路径（09-26/09-27 抓包）不写 `18345be0`、不写 `{0x03}`、不等 `18345be1`，只写 `{0x01}` + `e182ec40 {0x03}`，相机静默接受（`769-775`）——全新注册的相机会拒绝那套确认动作。

### 2.7 AP 就绪与凭据读取

顺序照抄官方 e 层 `z#35 → z#5 → z#6`：会话密钥 → SSID → 密码，紧接友好名写入之后，三步各 5 s 超时（`513-516`、`530-553`）：

- **SSID**（`e206a5c0`）：读 UTF-8 后按 `;` 切分取第一个非空段（`firstSsidEntry()`，`1939-1946`），该特征给的是列表而非单个名字
- **密码**（`c97cf1a5`）：每 4 字节一组"反转 + 与密钥反向顺序异或"，**跳过第 1 个字节**（声明长度，官方解码器从不校验），在第一个 `0xFF` 处截断，余下 UTF-8 解码去 NUL（`1902-1937`）。空结果是合法值：S5 的 SoftAP 开放，抓包里那段"密钥重复"密文正好解出空串，官方随后无密钥入网
- 长度不是 4 的倍数直接判失败，日志只记长度

该解码与 2.4 的 `encodeApsBlock` **不是互逆函数**（同 key 套两边得不到原文），它们是两个不同官方例程（写入 `o.d/o.c`，读取 `N5.o.a`）的各自复刻，不能当一对编解码器用。

## 3. 时序

### 3.1 配对完整序列（默认路径）

按 `pairAndConnect()` 执行顺序（`LumixSyncControlService.ets:308-903`）：

1. 停扫描、挂起发现、并行预热 Wi-Fi 射频（`423-428`）；GATT 连接失败最多重连一次，连接中断有独立监听（`326-356`、`430-449`）
2. 轮询 `getServices()` 最多 10 次 × 2.5 s；空表且未掉线时换全新 client 重试一次（`434-446`、`1310-1338`）
3. 注册十个通知后 `delay(600)`（`458-460`）→ 身份写入 → 300 ms → 友好名写入 → 300 ms（APS 分支在身份写入前多一次密钥读取）
4. 凭据读取（传统机身的密钥在此读）→ 持久化 SSID/密码/BLE 地址；GATT 全程不断开（`593-597`）
5. Wi-Fi 加入：直连快路径（已存凭据，2 次 × 15 s）→ 否则短窗口 1 次 × 20 s → 扫不到 AP 时 BLE 唤醒（最多 3 轮，间隔 10 s）→ 长窗口 3 次 × 150 s（`554-685`）
6. `req_acc` 提交（`pairingCommit=true`，最多 40 次轮询）
7. 20 s 静默 → 入场写入（最多 3 轮）→ `waitCameraLinkDrop(ssid, 12000)` → 重连 Wi-Fi → 清会话 → `req_acc` 刷新（40 次、连续空响应上限 12、`entryRefresh=true`）→ `setsetting device_name` → 等 `e182ec41 b0=0` 3 s
8. `setsetting raw_img_send=enable`（失败不致命，`873-880`）→ 断开 GATT → 写偏好 `syncCameraSsid` / `syncCameraBleDeviceId`

### 3.2 `req_acc` 的两次应答

`ensureControlSession()` 对 `req_acc` 反复 GET 并按应答体分流（`911-1035`）：

| 应答 | 处理 |
| --- | --- |
| `ok_under_research...`（含 `_no_msg`） | 记 `sawUnderResearch`，`delay(1000)` 后重发 → 通常第二次 `ok,...` |
| `err_busy` | 最多 5 次，每次隔 1 s |
| `err_user_refused`（普通） | 最多 6 次 × 2 s，提示用户到相机屏幕点"允许"；超限后提示按 MENU 退出上一控制画面 |
| `err_user_refused`（`entryRefresh`） | 最多 3 次 × 2 s，之后放弃会话刷新但**继续激活**（`989-998`） |
| `err_others_requesting` | 立即失败 |
| 其他 `err_` / `ret_empty` | 立即失败，消息带首个逗号前的错误码 |
| `ok` / `upload_bt` / `transfer` 开头 | 建立会话，记 `accessGrantAt`，取第 5 字段做 sessionId |

`ok_under_research` 之后若网络直接断（超时或空体）且调用方是配对提交，代码判定**断线本身就是注册成功信号**：相机收到提交后立即重启 SoftAP 把手机踢下线，后续静默期/BLE 入场/重连/刷新会重建真会话（`948-960`）。

### 3.3 静默期：官方 19 s / 34 s 与 2 s 被拒

同一组对照出现在头部与入场段注释（`41-44`、`785-790`）：官方两次抓包在提交与入场写入之间分别停 **19 s** 与 **34 s**（属用户操作节奏，但是记录里唯一被接受的间隔）；VIVID 在 2026-09-27 10:54 用 **2 s**，`e182ec41` 在 action-mode 写入后 **24 ms** 就回 `b0=1`——相机 BLE 侧还没消化刚提交的注册。因此默认路径硬编码 `delay(20000)`，UI 文案"正在准备相机控制模式（约 20 秒）"（`791-792`）。相关一点：入场后相机会在数秒后断开 Wi-Fi，抢在断开前重连会在 6 ms 内短路到将死链路并拿到过期网关（2026-09-27 19:52），所以先等链路真正消失再扫描（`826-838`、`LumixImportPrototype.ets:2668-2683`）。

### 3.4 控制模式进入的写序列

默认路径每轮（`793-823`）：重读凭据（官方 `R0#35/R0#5/R0#6`）→ 写 `0d6f1880 {0x01}`（SoftAP 应答）→ 写 `e182ec40 {0x03}`（action mode）→ `delay(1500)` 后看 `e182ec41 b0=1`（被拒则 10 s 后重试下一轮，共 3 轮）。成功后按 3.1 第 7 步重连、刷新、`device_name` 收尾，最后等约 200 ms 后的 `e182ec41 {0x00}` 激活推送（3 s 超时；等不到只记警告，官方看不到推送也照样继续）。

### 3.5 授权时效

`accessGrantAt` 记录最近一次被接受的 `req_acc`，`hasControlSession()` 超过 **50 s** 即判过期并允许重发（`233-245`、`289-301`）。依据：官方约每 60 s 重发一次；ZS300 上实测 `req_acc` 后 3 s 缩略图正常、75 s 后原图 GET 断连（`http=0`）、95 s 后 Browse 回 403。下载/预览失败时先 `refreshAccessGrant()`（单次、不轮询、失败不抛错）再重试一次，而不是盲目重试同一张。

## 4. cam.cgi 命令层

### 4.1 URL 与请求头

授权：`GET /cam.cgi?mode=accctrl&type=req_acc&value={dotted}&value2={name}`，`value` 是 2.4 的点分身份（`encodeURIComponent`），`value2` 是 `Pixelshop`（`926`，刷新版同形 `1055-1056`）。HTTP 层统一 `http://{host}{path}`、GET、`User-Agent: LUMIX Sync`、连接与读取超时各 5 s，只在 sessionId 非空时加 `X-SESSION_ID`（`1994-2019`），host 会去掉协议前缀与斜杠（`1990-1992`）。读路径另有官方重试 `httpGetRetry`：`err_busy` 最多 5 次 × 1 s（`2021-2043`，对应官方 `B5/a.F(str,5,1000)`）。

### 4.2 X-SESSION_ID 取第 5 个 CSV 元素

`sessionIdFromResponse()` 按 `,` 切分取 `parts[4]`（第 5 个元素）并去 CR/LF；不足 5 段返回空串（`1984-1988`）。空 sessionId 不等于失败：ZS300 只回 4 个字段、从不给 X-SESSION_ID，授权靠 IP 维持（`274-280`、`1037-1047`）。sessionId 只用于发请求，调用方不得记录或持久化（`257-264`）。

### 4.3 实际发送的命令表

| mode | type / value | 出处 | 用途 |
| --- | --- | --- | --- |
| `accctrl` | `type=req_acc`，`value=<dotted>`，`value2=Pixelshop` | `LumixSyncControlService.ets:926`、`1055` | 注册提交 / 会话续期 |
| `camcmd` | `value=playmode` | `LumixSyncImageTransfer.ets:1084`、`1157`、`1276`、`1304`、`1439`；`CameraControlPage.ets:677` 等 | 切回放（Browse 前置） |
| `camcmd` | `value=recmode` | `LumixSyncImageTransfer.ets:1234`、`1547`；`CameraControlPage.ets:720` | 归还拍摄模式 |
| `camcmd` | `value=capture` / `capture_cancel` / `video_recstart` / `video_recstop` / `oneshot_af` | `CameraControlPage.ets:978-1014` | 快门 / 录制 / 单次对焦 |
| `camcmd` | `value=pictmode` | `LumixCameraService.ets:2254` | S5 图片选择模式；注释注明当前无调用方 |
| `camctrl` | `type=touch`，`value=x/y`（0-1000 归一化），`value2=on` | `LumixSyncControlService.ets:1151-1189`；`CameraControlPage.ets:2318` | 触屏对焦 |
| `setsetting` | `type=device_name`，`value=Pixelshop` | `LumixSyncControlService.ets:1085` | 注册收尾 |
| `setsetting` | `type=raw_img_send`，`value=enable` | `877`；`CameraControlPage.ets:770` | 让相机交付完整 RAW |
| `setsetting` | `type=current_sd`，`value=sd1` 或 `sd2` | `LumixSyncImageTransfer.ets:1642` | 切换存储卡 |
| `setsetting` | `type` ∈ iso、shtrspeed、focal、exposure、whitebalance、photostyle、quality、aspectratio、lightmetering、recmode | `CameraControlPage.ets:2705-2719` → `LumixSyncControlService.ets:1439` | 鼓轮参数写入 |
| `getsetting` | `type=<同上任一>` | `LumixSyncControlService.ets:1500` | 读单项当前值（`<settingvalue type="...">`） |
| `getstate` | `type=keep_alive` | `1402`、`1474` | 心跳 / 状态 |
| `getinfo` | `type=curmenu` / `type=lens` | `1572`、`1598` | 菜单快照 / 镜头信息 |
| `startstream` | `value=<port>` | `1210`；`CameraControlPage.ets:687` | 明文 UDP 实时取景 |
| `stopstream` | — | `1239` | 关闭取景 |

两条编码约定必须照做：`camcmd` 动词只能放 `value=`，带 `type=` 会回 `<result>err_param</result>`（`1093-1101`）；`setsetting` 的 `value` **不做 URL 编码**（相机解析 `%2F`/`%2B` 会失败），只有 `type` 编码（`1434-1439`）。光圈 `focal` 在协议边界换算成 AV×256 有理数（`AV = 2·log2(F)`，F3.6 → `940/256`），已带 `/` 的原生值原样透传（`1421-1433`）。

`playmode`/`recmode` 的额外约束：`stopstream` 后 2.5 s 内不切模式（否则 `err_busy` 锁一分钟）；相机已在目标模式时回的 `err_reject` 按已就位处理；成功切换才记 `lastAcceptedMode`，续拉时若已是 `playmode` 不再重发（`1112-1140`、`210-218`）。`replyVerdict()` 先找 `<result>...</result>`（camrply XML），找不到才按 CSV 取第一个逗号前的段（`1246-1259`）——只看 `startsWith('ok')` 会把 XML 应答全判成失败。

## 5. Wi-Fi 图像传输（DMS 拉取）

### 5.1 定位与前置

图片通道不走 `cam.cgi`，而是机身内建 DLNA MediaServer：`http://{gateway}:60606/Server0/CDS_control`，浏览 `ObjectID="0"` 并下载 `res` URL（`LumixSyncImageTransfer.ets:13-26`）。进入前必须①控制会话可用②`camcmd playmode` 成功③留 800 ms 稳定窗口（`1072-1093`）；`playmode` 后 440 ms 就 Browse 会被当并发请求回 403（`1392-1394`）。

### 5.2 SOAP 信封

`browseEnvelope()`（`102-114`）与官方 `B5.m.a` 逐字一致：SOAP 1.1 Envelope、`u:Browse` 命名空间 `urn:schemas-upnp-org:service:ContentDirectory:1`、`pana` 命名空间 `urn:schemas-panasonic-com:pana`，固定 `ObjectID=0`、`BrowseFlag=BrowseDirectChildren`、`Filter=*`、空 `SortCriteria`、`pana:X_FromCP=LumixLink2.0`。请求头（`120-132`）：`Accept-Charset: UTF-8`、`Content-Type: text/xml; charset="utf-8"`、`SOAPAction: urn:schemas-upnp-org:service:ContentDirectory:1#Browse`、`User-Agent: Panasonic MIL DLNA CP UPnP/1.0`，有会话时附 `X-SESSION_ID`；连接 15 s、读取 30 s。

### 5.3 分页 12 与游标

`SYNC_DMS_PAGE_SIZE = 12`（`25`）。首页 `StartingIndex=0`、`RequestedCount=12`，失败后 1.5 s 重试一次；续拉用 `nextStartIndex`，推进量是**相机回的物理条目数**（`NumberReturned`，缺失时用解析出的 `<item>` 个数），与去重后卡片数解耦（`1113`、`1180`）。`TotalMatches` 决定 `hasMore`（`cursor < total`）；整页重复时不永久关闭加载而是保持可重试（`1181-1196`）；失败后 5 s 冷却，防止滚动把相机顶死（`1045-1052`、`1141-1144`）。

### 5.4 DIDL-Lite 解析

先按官方 `C3142a.l` 顺序反转义 `&lt; &gt; &amp; &quot;`，再截取 `<DIDL-Lite ...>...</DIDL-Lite>`（`152-164`）。每个 `<item>` 取 `id`、`<dc:title>`，遍历全部 `<res>` 分类：

- 缩略图：`protocolInfo` 命中 `jpeg_tn`/`jpeg_sm`/`cam_tn`/`cam_sm`/`cam_lrgtn`，只取第一个
- 视频：`video/` 或 `cam_avc`，或扩展名 `mov`/`mp4`/`m4v`
- JPEG 原图：`cam_raw_jpg`/`cam_hsp_raw_jpg` 必须**先于** `cam_raw` 判定（松下给一组 JPG+RAW 双文件都用 `application/octet-stream`，顺序错了会把 JPEG 字节写成 `.RW2`），以及 `cam_org`/`cam_hsp_jpg`、扩展名 `jpg`/`jpeg`、`image/*`
- RAW：`cam_raw`/`cam_hsp_raw` 或扩展名 `rw2`/`rwl`/`raw`/`dng`
- 显示名：`OriginalFileName`（单引号属性）优先，缺失退回 `id` 末段

下载地址就是 `<res>` 的文本内容（原样使用，通常是相机自报的绝对 URL），`size` 属性即该资源精确字节数。

### 5.5 下载

`downloadToFile()` 用 `requestInStream` 流式落沙箱（`332-491`），UA 与 Browse 相同并附 `X-SESSION_ID`。`dataReceive` 内直接 `writeSync`；进度按 `dataReceiveProgress` 上报，部分真机不回调时用 `dataReceive` 内 250 ms 节流兜底。结束需同时满足"收到状态码"与 `dataEnd`，随后校验字节数：DIDL 声明了尺寸而实收不等时**丢弃文件**（短包通常只是预览图）。超时 120 s（JPEG 原图）、180 s（视频/RAW）、15 s（缩略图）。

### 5.6 JPEG + RAW 双资源：实现与注释不一致

协议层：一个 `<item>` 可以有两个原图 `<res>`，类型注释写明"JPEG+RAW 对有一个可独立定位的第二个 RAW 源"（`38-43`、`1506-1507`）。实现层：`parseItem()` **不填** `rawDownloadUrl`，而是把 RAW 拆成第二张卡片（`imageId` 加 `::raw` 后缀，共享缩略图与尺寸，`286-299`）；因此该字段全文件只读不写（`41`、`283`、`291`、`298`、`1371`、`1508`），`downloadSelected()` 的"同一 item 第二资源"分支（`1508-1528`）与 `planFileCount()` 的 `+1`（`1371`）都走不到。

实际行为是 JPEG 与 RAW 成为网格里两张独立卡片，各按自己的 `res` 下载；选中键为 `imageId:imageType`（RAW=1、JPEG=2），同编号两张卡不会一起选中（`1341-1356`、`507-512`、`1659-1683`）。副作用是两者不再表现为"同一张照片"，用户在 UI 上看不出配对——这是把"一条 DIDL item 两个资源"简化成"两条卡片"，不是相机行为差异。

### 5.7 存储卡与 RAW 交付

`getstate` 的 `<sd_memory>`/`<sd2_memory>` 为 `set` 表示在位，`<current_sd>` 为 `sd1`/`sd2` 决定当前卡；缺失时按"有 SD1 用 SD1，否则 SD2"回退（`1602-1633`）。切卡用 `setsetting current_sd=sd1` 或 `sd2`，成功后清空网格与 DIDL 缓存并重跑完整起始流程（`1635-1656`）。`raw_img_send=enable` 每次连接收尾都发：未开启时 DMS 可能下发精简 RW2（2026-09-28 实机下载的 RW2 缺镜头信息），开启后交付完整 EXIF 含镜头信息；EXIF 镜头标签回填已搁置（自建 IFD 注入导致图库读不出拍摄参数），改为原始字节直存（`1556-1566`）。

## 6. 实现对照表

| 环节 | 官方行为（代码注释/出处） | VIVID 实现 | 差异与影响 |
| --- | --- | --- | --- |
| 广播过滤 | 服务 UUID + 厂商数据 58 + 名字机型码门控（`LumixImportPrototype.ets:313-343`） | 服务 UUID 与状态字节只记日志；强信号为 company 58 六字节 + 机型码（`2201-2284`） | 放宽方向，宁可多认不误藏；可能把非相机 LUMIX 设备列入候选 |
| 通知注册 | 十次 CCCD 全失败于 `No_Descriptor`，仍继续（`LumixSyncControlService.ets:36-39`） | 平台代管 CCCD，注册 10 个并核对 missing（`1347-1377`） | 推送可用性比官方高；依赖推送的步骤仍按"可缺失"处理 |
| 身份与名字 | 传统明文 16 字节 + ASCII 名；APS 用 o.d/o.c（`18-29`） | 按特征齐全度自动选分支（`471-511`） | 一致；APS 分支多一次密钥读取 |
| 注册提交 | 首次 `ok_under_research`，约 1 s 后重发得 `ok`（`31-40`） | 1 s 间隔重发，并把"提交后断网"判成功（`948-972`） | 一致，且对 SoftAP 重启更鲁棒 |
| 静默期 | 19 s / 34 s（`41-44`） | 固定 `delay(20000)`（`791-792`） | 取官方下界；小于此值会吃 `b0=1`，大于 34 s 未验证 |
| 控制模式进入 | `{0x01}` + `{0x03}`，无 `{0x03}` 重启（`769-775`） | 默认同；完整确认链在 `withControlDance` 后 | 默认路径不重启 SoftAP，省约 40 s 中断 |
| 授权续期 | 约每 60 s 重发 `req_acc`（`289-292`） | 50 s 判过期 + 失败后单次刷新（`233-245`、`1048-1072`） | 更保守；ZS300 靠 IP 维持仍会过期 |
| 命令编码 | 动词在 `value=`，`setsetting` 值不编码（`1093-1101`、`1434-1439`） | 同 | 一致 |
| DMS 分页 | Browse `ObjectID=0`，`X_FromCP=LumixLink2.0`（`LumixSyncImageTransfer.ets:102-114`） | 页大小 12，游标按 `NumberReturned` 推进 | 页大小取自常量，官方是否同为 12 代码未标注 |
| JPEG+RAW | 一条 item 两个原图 `res`（`38-43`） | 拆两张卡片，第二资源分支不可达（`286-299`、`1508`） | 功能等价但配对关系丢失，且有死代码 |
| 凭据持久化 | 官方存 `CurrentConnectedSSID`/`CurrentConnectedAddress`（`882-891`） | 偏好 `syncCameraSsid`/`syncCameraBleDeviceId`/`syncCameraPassword`（`1769-1782`） | 见 7.4：密码也一并落盘 |

## 7. 限制与风险

### 7.1 机型与固件差异

- **两套特征集**：只有 `wifiSsid` 与 `wifiPassword` 是硬前提；`dlnaUuidAps`/`friendlyNameAps` 与 `8d08a420`/`cd7a71a0` 各有一组即可，都缺时判"未暴露配对标识特征"（`462-467`）。入场特征 `0d6f1880`/`e182ec40` 缺失时跳过入场、只记警告，注册仍算成功（`780-784`）
- **ZS300**：`req_acc` 只回 4 字段、无 X-SESSION_ID、授权按时间过期，重复 `playmode` 会让 DMS 会话重入（第 3 页起 Browse 全 403），故模式切换做了幂等保护（`LumixSyncControlService.ets:210-218`、`LumixSyncImageTransfer.ets:1151-1166`）
- **S5**：SoftAP 可开放（空密码合法），另有 `requestS5Access`（`value2=WEB-W00`）与 `pictmode` 遗留分支与主路径并存，注释承认 S5 被动推送已停用
- **Sync 机型码未知**：1..9 码表来自 Lab APK，超出范围只能靠名字回退，`logAdvertisement` 留作设备日志待证项

### 7.2 BLE 通知与 `No_Descriptor`

官方十次通知注册全部 `No_Descriptor` 失败仍继续，是本线最反直觉的一点。本实现靠 HarmonyOS 代管 CCCD 拿到订阅（2026-09-25 配对成功），但代码对推送一律按"可能收不到"设计：`pairReady` 不作门控、激活推送缺失只警告，只有可选的 `withControlDance` 把 `18345be1` 当硬等待（5 s 超时即失败）。若某机身要求真正的 CCCD 写而平台不代管，该分支必失败，默认路径不受影响。

### 7.3 时序窗口

- 20 s 静默期硬编码：固件若需更长（官方抓到 34 s），入场写入会吃 `b0=1`，三轮后整次配对失败，用户只能重来
- GATT 每步 5 s 超时、`getServices` 10 × 2.5 s；相机休眠/刚唤醒时窗口偏紧；任何静默失败都会走 `fail()` 并 dump trace
- Wi-Fi 窗口在 Sync 线放宽到 150 s 且"扫不到热点"改走隐藏 SSID 直连，但系统"信任此 Wi-Fi"确认框的 30 s 上限由 SDK 决定，用户不点必然超时（`CameraPage.ets:2222-2230` 为此先收起 App 自己的模态弹窗）
- 授权 50 s/60 s 是日志拟合值，无相机公开文档支撑，只能靠失败后刷新兜底

### 7.4 密码与会话密钥的落盘/落日志

`persistSyncCredentials()` 把 SSID、BLE 地址与**明文 Wi-Fi 密码**写进应用私有偏好 `syncCameraPassword`（`1769-1782`），`storedDirectCredentials()` 原样读回用于直连（`1734-1767`）。所以"密码不落库"并不成立：它落库了，只是不落 hilog（`redactGattValue` 对 `c97cf1a5` 返回 `redacted-sensitive`，`LumixImportPrototype.ets:4320-4323`）。另有会话密钥明文写 hilog 的临时状态（`1857-1859`）。

### 7.5 身份稳定性、明文传输与注释漂移

OAID 不可用且偏好被清（重装）时会生成随机种子，相机把手机当新设备要求重新注册；OAID 本身变化（隐私设置、系统升级）同样造成"设备身份漂移"。`cam.cgi` 与 DMS 下载都是 `http://`，实时取景是明文 UDP（`startstream` 只把端口告诉相机，相机往 `phone:<port>` 发裸 DatagramSocket），本线没有 TLS/DTLS，与 Lab 线的 HTTPS + 证书指纹固定不同（`LumixSyncControlService.ets:1191-1201`）。文档层面还有两处不一致：`LumixSyncControlService.ets` 顶部仍把机型写成 "S5 / GH5 / GH5S / G9 / GH6 / G100D"（`:11-13`），而路由表已在 2026-10-11 把 GH5/GH5S/G9 移到 Image App 线；同目录存在 `LumixSyncImageTransfer.ets.damaged`（67128 字节），本报告未使用，两者关系代码里没有说明。

## 8. 待验证事项

1. **Sync 机型的广播机型码**：码表 1..9 来自 Lab APK，Sync 机身是否落在表内无代码证据，需真机 `adv ... code=` 日志（`LumixImportPrototype.ets:2201-2218` 已埋点）
2. **`e182ec42` 语义**：与 `e182ec41`/`e182ec43` 同属 `e182ec4x` 推送族，注释未写用途，只能确认它在十连通知集合里（`LumixSyncControlService.ets:198`）
3. **`18345be1`/`0d6f1880` 所在服务的完整 UUID**：注释与代码只给短形式 `5ae57260`（`154-159`、`169-176`）
4. **身份前缀 `0100 1000 8001` 的含义**：官方样例恒定，代码未标注，推断为版本/DLNA 设备类别字段
5. **相机侧授权 TTL**：50 s 判过期与"约 60 s"均为日志拟合值
6. **DMS 页大小**：代码固定 12，官方是否同为 12 未在注释中给出抓包依据
7. **`withControlDance` 路线**：默认关闭，仅需 `{0x03}` 重启 SoftAP 时启用；41 s 信标中断与 `err_user_refused` 边界只在 2026-09-25/27 抓包出现，机型覆盖面未知
