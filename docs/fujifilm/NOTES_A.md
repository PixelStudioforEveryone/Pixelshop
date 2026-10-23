# NOTES_A — FUJIFILM 识别路线（角色 A）决策记录

本文是**角色 A**（识别路线）的实现记录：每一处协议行为都对应到分析报告的章节，
所有【推断】/【未知】都写清证据、当前实现与回退方案。契约见 `ROUTE_SPEC.md`。

产物（仅这些文件由 A 写入）：

| 文件 | 作用 |
| --- | --- |
| `entry/src/main/ets/services/FujifilmPtpIp.ets` | PTP-IP 客户端（55740/55741/55742） |
| `entry/src/main/ets/services/FujifilmBleService.ets` | BLE 扫描/配对/凭据/功能拉起 |
| `entry/src/main/ets/services/FujifilmModels.ets` | 机型名归一化 + imageKey |
| `entry/src/main/ets/pages/home/CameraPage.ets` | 卡片、四个入口、扫描接入 |
| `entry/src/main/ets/services/CameraSessionStore.ets` | 追加 `isFujifilmSelected()` |
| `entry/src/main/ets/services/CameraControlBrand.ets` | 追加 `PROTOCOL_FUJIFILM` + 身份行 |
| `entry/src/main/ets/services/CameraCardRegistry.ets` | 富士别名/直连判定 |
| `entry/src/main/resources/base/profile/main_pages.json` | 三个富士页面路由 |

只读依赖：`FujifilmProtocol.ets`（常量全部取自这里）、`FujifilmModelImages.ets`
（自动生成的素材表）、`LumixImportPrototype`（GATT 连接/特征工具）、
`LumixCameraService.connectToCameraWifi`（系统关联）。

---

## 1. 结论速览

* **识别**：BLE 广播（厂商数据 company=0x04D8 + 7 个服务 UUID，其中 `AF854C2E` 常驻）
  → 机型名归一化 → 卡片（`brand='FUJIFILM'`、`imageKey='fujifilm_<slug>'`）。
* **配网**：GATT 连接 → 回写广播里的 pairing key（**无 PIN / 无绑定 / 无加密**）→
  现场读 SSID/密码 → 写功能启动 3/4/5 → 等 `AP_STATE=0x8001` → 系统
  `addCandidateConfig` 关联热点。
* **协议**：不透明 12 字节包头 + CIPA DC-X005 的事务/数据阶段语义，端口是
  **55740/55741/55742**（不是 15740）。
* **取景**：55741 上按 204800 字节读整包，JPEG 起点 = `LE32@12 + 18`。
* **最大风险**：`DataPhaseInfo` 的取值口径冲突（见 §3.4），已用自校准消化。

---

## 2. 公共 API 与契约的对应

### 2.1 `FujifilmPtpIp`（契约 §2.1）

| 契约 | 实现 | 说明 |
| --- | --- | --- |
| `connect()` | ✅ | 控制通道 55740 + 事件通道 55742；幂等，共享在途 `connectTask` |
| `isConnected()` / `close()` | ✅ | `close()` 同时置会话不可用；监听器保留（供固件服务复用） |
| `op(opcode, params?)` | ✅ | `DataPhaseInfo = 无数据` |
| `opDataIn(opcode, params?)` | ✅ | 相机→手机（GetObject/DeviceInfo…） |
| `opDataOut(opcode, params, data)` | ✅ | 手机→相机（固件 0x9040/0x9042…） |
| 事务串行 + TransactionID 自增 | ✅ | `queue` 串行链 + `nextTransactionId()`（1..0xFFFFFFFE 回绕） |
| StartData/Data/EndData，512B 块 | ✅ | `sendDataPhase()`，块大小 `FujifilmNet.DATA_BLOCK` |
| 超时 | ✅ | 连接 5 s / 打开 5 s / 事务 10 s / 打开+传输 30 s（全部取 `FujifilmNet`） |
| `0x201E` 视为已打开成功 | ✅ | `FujifilmResponse.SESSION_ALREADY_OPEN` 直接放行，不重连 |
| 事件通道 → `onEvent` | ✅ | 55742 长读循环，事件帧解析为 `{code, params}` |
| 断连即会话不可用 | ✅ | 任一通道/事务错误 → `markUnavailable()` → `close()` |
| `openLiveView()` | ✅ | 连 55741 + 该通道 initialize（**推断**，见 §4.1） |
| `readLiveViewFrame()` | ✅ | 默认按 204800 读；JPEG 偏移 = `LE32@12 + 18` |
| 小端读写统一走 `FujifilmBytes` | ✅ | 本文件没有任何 `DataView`/手动位移，仅 `Uint8Array` |
| `onEvent` / `clearEventListeners` | ✅ | 固件服务两者都用（`close()` 不清监听器） |

### 2.2 `FujifilmBleService`（契约 §2.2）

| 契约 | 实现 |
| --- | --- |
| `startScan/stopScan` | ✅ 7 个服务 UUID 过滤，60 s 重启；只停自己启动的那一轮 |
| `connect/isConnected/disconnect` | ✅ `createGattClientDevice` + MTU 185 + 订阅 `AP_STATE` |
| `pair(camera)` | ✅ 老协议回写 4 B key；RED 先写 `0x20000000`，再写 key，再写 `80 01 01` |
| `readIdentity()` | ✅ 序列号/机型/MAC/Y 号/固件版本（含 0x2A24/0x2A25 兜底） |
| `readFirmwareVersion()` | ✅ 0x2A26 |
| `readWifiCredentials()` | ✅ SSID `BF6DC9CF` / 密码 `E809256A`，UTF-8 读到 `0x00`；失败即断开并抛错 |
| `launch(kind)` | ✅ 只接受 3/4/5，写 u16 LE 到 `600655E6` |
| `waitApReady(ms)` | ✅ 毫秒语义；轮询 `AP_STATE` 到 `0x8001` |
| `lastApState()` | ✅ |
| **追加**（协调者 2026-10-19 补充） | `writeCharacteristic(uuid, value)` / `readCharacteristic(uuid, timeoutMs?)`：任意特征直读直写，**无需先订阅通知**，带串行锁与超时；固件的 92 B 请求与 29 B 文件信息走这两个方法 |

### 2.3 `FujifilmModels`（契约 §2.3）

`normalize` / `find` / `displayNameOf` / `slugOf` / `imageKeyOf` / `isFujifilmImageKey` /
`slugFromImageKey` / `modelFromImageKey` / `rawfileForImageKey` / `rawfileOf` /
`identifyWifiSsid`，外加 `BRAND='FUJIFILM'`、`IMAGE_KEY_PREFIX='fujifilm_'`。

---

## 3. PTP-IP 实现决策

### 3.1 12 字节包头（`报告 02 §3`）

```
Offset 0..3  Length        LE32  含包头
Offset 4..7  Type          LE32   1..12
Offset 8..11 DataPhaseInfo LE32
```

`Type` 的 1..12 只从 `FujifilmPacketType` 取名；包头构造集中在 `frame(type, phase, payload)`，
所有写出路径共用，避免出现两套长度算法。

### 3.2 `Init_Command_Request` 的 68 字节载荷（**推断已对齐**）

```
0..15   GUID 08 70 B0 61 0A 8B 45 93 B2 E7 93 57 DD 36 E0 50
16..63  UTF-16LE "VIVID Camera Remote App" + 0x0000（23 字符 = 46 B + 2 B 结束符）
64..67  PTP-IP 版本 LE32 = 0x00010000
```

依据：native 侧对 Init 的长度比较是 `cmp w1,#68`（`native_ptp.md §4.2`），而 CIPA 的
Init_Command_Request 是「16 B GUID + UTF-16LE 名字 + 4 B 版本」。23 字符刚好让
16 + 48 + 4 = 68 同时满足两边，于是名字取 ``INIT_NAME = 'VIVID Camera Remote App'``
并把长度**写死进推导**：改名字会破坏 68 字节假设，所以代码里加了注释。

回退：若相机回 `Init_Fail`（类型 2），错误码取自载荷前 4 字节，日志会给出 `0x…`；
此时不重试（重试也不会变），由页面提示用户。

### 3.3 OpenSession（`报告 01 §7.2`、`02 §7`）

`Init_Command_Ack` → `OpenSession(0x1002, sessionID=1)`。`0x201E`
（SESSION_ALREADY_OPEN）**按成功处理**：相机侧会话没释放时这是正常现象，不该让用户
去关相机。`Init_Command_Ack` 里的 `connectionNumber` 解析出来给事件通道用（缺省 1）。

### 3.4 `DataPhaseInfo` 口径冲突（本次最大风险）

* `FujifilmProtocol.FujifilmPacketType.DATA_PHASE_*`：`NONE=0 / IN=1 / OUT=2`。
* CIPA DC-X005：`1=NoData / 2=DataIn / 3=DataOut`（尼康线里也有实测注释印证）。

两者对同一个值给出不同含义，**猜错会让所有带数据的命令静默失配**（相机收不到请求，
只能等超时）。当前实现：

1. 先把「文件常量口径」（`CIPA_PHASE_NONE=1 / IN=2 / OUT=3`）作为首选编码；
2. `connect()` 末尾用 `GetDeviceInfo(0x1001)` 探一次：
   * 返回**有数据** → 编码正确，继续；
   * 返回**有应答但无数据** → 也算正确（这条命令本来就可能不带数据，不能因此换编码）；
   * **无应答/超时** → 切换成 `FujifilmProtocol` 的 0/1/2 口径，重连再探一次。
3. 两种都不通时保留当前编码并记日志，不把会话判死（控制面可能仍可用）。

探测结果只影响「数据阶段编码」，不影响事务队列与包类型。日志关键字：
`数据阶段编码自校准通过：encoding=` / `数据阶段探测无应答`。

### 3.5 数据阶段收发

* **手机→相机**：`StartData(u64 总长)` → 若干 `Data`（每块 512 B，末块可短）→ `EndData`，
  然后等 `Operation_Response`。发送量按实际字节计数，不按块数。
* **相机→手机**：`Operation_Response` 之后读 `StartData`（载荷首 8 字节是 u64 总长）→
  `Data`×n → `EndData`。若 `StartData` 声明长度为 0，直接按 `EndData` 处理。
* `Operation_Response` 载荷按 `u16 code + u32 tid + params` 解析；TransactionID 先按
  offset 2 读，如果和当前 tid 不符再试 offset 4（不同固件对「是否回显 tid」不一致）。
* 任一阶段读超时 → `markUnavailable()`，避免把半包数据留在流里继续用。

### 3.6 事件与取景通道

* **55742**：`Init_Event_Request`（载荷 = `connectionNumber` LE32）→ 等 Ack（1.5 s）。
  **【推断】** 部分固件不回 Ack 而直接推事件，所以 Ack 超时**不断链**，直接进读循环；
  首包就是事件时先分发再进循环（不丢事件）。空闲读超时 4 s，属正常轮询。
* **55741**：见 §4.1。

### 3.7 断连语义

任何通道读失败、事务超时、事件通道中断 → `markUnavailable()` → `close()`。
之后 `op*` 一律抛 `PTP-IP 会话未建立`，页面/服务必须重新 `connect()`。
`close()` **不会**清 `onEvent` 监听器（固件服务在跨阶段复用），需要时显式
`clearEventListeners()`。

---

## 4. 【推断】与【未知】

### 4.1 【推断】取景通道 55741 的 initialize

报告只写到「Phase1 之后由 Java 建 55741/55742 两条 socket 并把 fd 交给 native」
（`02 §4.1`），**没有记录取景通道的握手包**。当前实现：

1. 连 55741，发一次 `Init_Event_Request`（与事件通道同形，载荷 `connectionNumber`）；
2. 1.2 s 内：
   * 收到 `Init_Event_Ack` → 初始化成功；
   * 收到的是**帧**（长度像 204800 的包）→ 暂存（`liveStash`），交给第一次
     `readLiveViewFrame` 返回，不丢帧；
   * 超时 → 记日志后**继续用这条通道**（部分固件 open 之后直接推流）。

回退：如果真机完全没有帧，`readLiveViewFrame` 会在 `timeoutMs` 后返回 `null`，
控制页可以退化成「只有控制、没有实时取景」，不影响其余功能。

### 4.2 【未知】取景帧的完整性判据

当前按「帧头 Length 若在 `[12, 204800]` 内就用它，否则按 204800 兜底」读；
JPEG 偏移用 `LE32@12 + LIVEVIEW_JPEG_HEADER_BIAS(18)`。若真机上 JPEG 解不出来，
第一处要改的是 `LIVEVIEW_JPEG_HEADER_BIAS`（协议常量，不在本文件硬编码）。

### 4.3 【未知】AP_STATE 的通知形态

`AP_STATE` 特征通知按 LE u16 解析（`0x8001` 就绪 / `0x8002` 启动中）。若真机一次推
多字节（例如带长度前缀），`waitApReady` 会一直等不到 0x8001 —— 兜底是它只在
`timeoutMs` 后返回 `false` 并记 `最后值 0x…`，日志能直接暴露真实值。

### 4.4 【未知】老协议广播名的前 4 字符

「前 4 字符 = 短序列号」是报告里的经验规律。老机型若整个名字就是机型名（没有序列号
前缀），`modelOf()` 会先当序列号切掉 4 个字符。缓解：`FujifilmModels.find()` 走
「精确 → 最长包含」，切错的模型名通常仍能包含匹配上；再不行卡片会显示广播原名。

---

## 5. BLE 实现决策

### 5.1 扫描：API 形状偏离契约（已确认可行）

契约示例写的是 `startBLEScan(null, { filters: [...] })`，但本 SDK 是
`startBLEScan(filters: Array<ScanFilter>, options?: ScanOptions)`，`ScanOptions`
**没有** `filters` 字段。实际实现分三级：

1. `ble.startBLEScan([{serviceUuid: uuid} × 7], options)`（带过滤，首选）；
2. 被拒（`401`/正在扫描）→ `ble.startBLEScan(null, options)`（全量，回调里自己过滤）；
3. 仍被拒 → **复用页面已有扫描**：`BLEDeviceFind` 回调仍会送到我们这里
   （松下扫描挂的是无过滤回调，两条线因此可以并列）。

这也是「富士扫描与松下扫描并列」的实现方式：**同一个广播流，两套回调各自过滤**，
A 只 `off` 自己的回调，绝不 `stopBLEScan()` 停别人的轮次（`ownsScan` 标记控制）。

### 5.2 广播解析

* 厂商数据（AD type `0xFF`）company ID `0x04D8`；`mf[0]=1` RED、`=2` 老协议。
* 老协议：`mf[1..4]` = pairing key（4 B），`mf[5]` = 电源键；
  RED：`mf[1..5]` = 5 B ASCII 短序列号，`mf[6]` = 电源键。
* 服务 UUID（AD type `0x06/0x07`）按小端还原，命中 `AF854C2E` 或 RED 两个新服务也接受。
* 判定用「厂商 ID / 常驻服务 / RED 服务」三者之一，**不按名字含 FUJIFILM**：
  免得把打印机等其它富士外设拉进相机列表。

### 5.3 配对：没有 PIN / 没有绑定 / 没有加密

把广播里拿到的 key **原样**写回 `ABA356EB` 就算配对（`01 §7.2`、`§7.5`）。
RED 机型额外两步：`F557D96B ← 0x20000000`（已等于该值则跳过）、
`8B5ECF55 ← 80 01 01`。全程不调 `createBond()`、不弹 PIN、不解密。
**风险**：相机重启后 key 会变，旧 key 写回会被拒 —— 此时 `pair()` 返回 `false`，
`ensureFujifilmWifi` 只记日志并**继续读凭据**（凭据与 key 无关）。

### 5.4 凭据与"密码不落库"

`readWifiCredentials()` 每次现读，读到首个 `0x00` 为止，UTF-8 解码。
密码**失败即断开**并抛错（拿空密码去关联只会得到一次失败的热点尝试）；
日志只记长度，不记内容；`CameraPage` 只把它作为局部变量传给系统关联，
不写 preferences、不写 `CameraSessionStore`。

### 5.5 功能拉起

`600655E6 ← u16 LE`：`3` 图片传输、`4` 遥控、`5` 固件更新。
`launch()` 只接受这三个值（写死校验，防止误调）；`waitApReady(ms)` 是**毫秒**语义，
`AP_STATE` 到 `0x8001` 就返回 `true`。**这是切 Wi‑Fi 的唯一开关**：
广播只能证明机身「在附近」，不能证明热点已起。

### 5.6 固件 BLE 通道（协调者补充）

`writeCharacteristic()` / `readCharacteristic()` 是给 `FujifilmFirmwareService`
注入用的通用通道：

* 固件 92 B 请求 → `writeCharacteristic(CHAR_FW_UPDATE_REQUEST, payload)`；
* 29 B 待升级文件信息 → `readCharacteristic(CHAR_FW_UPDATE_FILE_INFO, 5000)`；
* 状态特征 `CHAR_FW_UPDATE_STATE` 同样直接读；
* **不需要先订阅通知**（这三个特征按需读写）；
* 内部走同一个 GATT 串行锁，避免与控制页的读特征交叉；`readCharacteristic` 超时
  返回 `null`（与"读到空值"区分）。

> 仍需页面侧接线：`FujifilmFirmwareService.setBlePort({...})` 目前没有任何调用点
> （`FujifilmFirmwarePage.ets` 里既没有 `FujifilmBleService` 也没有 `setBlePort`）。
> 固件页应在 `FujifilmBleService.connect(deviceId)` 成功后注入：
> `writeRequest: p => FujifilmBleService.writeCharacteristic(FujifilmBleIds.CHAR_FW_UPDATE_REQUEST, p)`、
> `readFileInformation: () => FujifilmBleService.readCharacteristic(FujifilmBleIds.CHAR_FW_UPDATE_FILE_INFO, 5000)`。
> 未注入时 D 的服务按"老机型、通道 B 不可用"降级。

---

## 6. 缺失/新增常量（需要协调者并入 `FujifilmProtocol.ets`）

| 常量 | 值 | 现状 |
| --- | --- | --- |
| `CHAR_FW_UPDATE_REQUEST/FILE_INFO/STATE` | `B1307521…` / `20EA1FAC…` / `049EC406…` | ✅ 协调者已补（本次使用） |
| `CHAR_Y_NUMBER` | `27870478-94A9-4345-849B-EFA3BF37887F` | ❌ **仍缺**：A 在 `FujifilmBleService.CHAR_Y_NUMBER_PENDING` 里临时兜底（取自 `ble_gatt_table.csv`，`J:BTCamera.java:3366`）。补齐后可删掉该字段 |
| PTP-IP 版本 | `0x00010000` | ❌ 协议文件没有；A 用 `FujifilmPtpIp.PTPIP_VERSION` 兜底（本文件内私有常量，未外泄成字面量） |
| CIPA `DataPhaseInfo` | `1/2/3` | ❌ 协议文件只有 `0/1/2` 一套；A 用 `CIPA_PHASE_*` 私有常量，见 §3.4 |

---

## 7. CameraPage 集成（契约 §3）

* **扫描**：`startCameraBleDiscovery()` 结尾调用 `startFujifilmBleDiscovery()`，与松下
  扫描并列；`stopCameraBleDiscovery()` 里只 `FujifilmBleService.stopScan()`。
* **卡片**：`LumixBleCameraCandidate{ brand:'FUJIFILM', imageKey:'fujifilm_<slug>' }`，
  机型图走 `Image($rawfile(FujifilmModels.rawfileForImageKey(key)))`。
* **按钮**（松下 LAB 布局，**没有 LUT**）：
  * 第一行 `[图片传输][相机控制]`；
  * 第二行 `[WIFI 连接][固件更新]`。
* **入口**：`openFujifilmEntry('image'|'control'|'wifi')` → `ensureFujifilmWifi()`
  → `pushUrl('pages/FujifilmImageTransferPage' | 'pages/FujifilmCameraControlPage')`；
  固件入口 `openFujifilmFirmware()` → `pages/FujifilmFirmwarePage`。
* **Wi‑Fi 关联**：`LumixCameraService.connectToCameraWifi(candidate, true, {password})`，
  `securityType: 3`（WPA2-PSK，与 `CameraWifiPasswordPolicy` 一致），
  `brand:'FUJIFILM'`；成功后写 `cameraWifiSsid/WifiStatus/BleStatus/Brand/State` 与
  `cameraHost`（取 DHCP 网关，取不到用 `FujifilmNet.HOST`）。
* **路由**：三个页面已注册进 `main_pages.json`（协调者 2026-10-19 复核项）。
* **其它文件**：`CameraSessionStore.isFujifilmSelected()`、
  `CameraControlBrand.PROTOCOL_FUJIFILM/isFujifilmProtocol/identityLine`（身份行含三个端口）、
  `CameraCardRegistry.alias()` 去 `fujifilm_` 前缀 + `wifiTile` 的 `direct` 认 FUJIFILM。

### 7.1 动态 `$rawfile` 的风险（承 `NikonCloudCatalog` 的教训）

`Image($rawfile(<变量>))` 在部分设备上不渲染；`NikonCloudCatalog` 里记录了改用
`resourceManager.getRawFileContent` + `createImageSource` + PixelMap 的兜底。
本次按契约直接用 `$rawfile(变量)`（ArkUI 声明为 `$rawfile(value: string)`，编译无碍）。
若真机出现空白机型图，回退顺序建议：

1. 先确认 `rawfileForImageKey()` 返回的路径存在于 `resources/rawfile/fujifilm/`；
2. 仍空白则把该处换成 PixelMap 方案（只改 `CameraModelImage` 的富士分支）。

---

## 8. 自我检查

* ✅ 只改了上表列出的文件；`Lumix*/Nikon*/Sony*`、`CameraControlPage`、
  `ImageTransferPage`、各品牌页均未触碰。
* ✅ 所有 LE 读写走 `FujifilmBytes`；`op*` 三个入口的参数/返回值与 `FujifilmFirmwareService`、
  控制/传输服务现有调用一致。
* ✅ 无 `any`、成员均有显式类型、`struct` 内无静态成员。
* ✅ 未运行完整 hvigor 构建（按指令），只做静态自查：`git status --short` 只出现
  上述文件 + 其它角色的富士新文件。
* ⚠️ 真机未验证项：§4.1 取景通道 initialize、§4.3 AP_STATE 形态、§3.4 编码自校准
  的最终落点（日志 `数据阶段编码自校准通过：encoding=` 会给出答案）。
