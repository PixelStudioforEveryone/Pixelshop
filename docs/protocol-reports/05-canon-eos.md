# 05 · 佳能 EOS：BLE 配对、WAP 入网与 PTP/IP 传输/遥控

> 代码基线 `18466be`。只读核查：`CanonProtocol.ets`、`CanonBleService.ets`、`CanonPtpIp.ets`、
> `CanonControlService.ets`、`CanonProperties.ets`、`CanonImportService.ets`、`CanonModels.ets`、
> `CanonModelImages.ets`，以及 `pages/home/CameraPage.ets` 的 Canon 分支；文档为
> `docs/canon-route-design.md`（下称「契约」）与 `docs/canon-route-verification.md`（下称「核实表」）。
> 行号为当前工作区实际行号。**事实**=代码/契约可直接对照；**推断**=有依据、无真机确认（核实表 §I.1）。

## 1. 线路定位与边界

**结论：BLE（Canon Camera Connect 私有 GATT，仅配对/凭据/拉 AP）+ 相机 AP 入网 + PTP/IP（TCP 15740）传输与遥控。CCAPI 未被采用。**

- 全仓库检索 `CCAPI|ccapi` 无命中；Canon 服务里唯一的 HTTP 客户端在
  `CanonFirmwareService.ets:241`、`:599`，只下载官方固件清单，不参与相机控制；对相机的唯一
  网络通道是 `CanonPtpIp.ets:189` 的 TCP socket。
- BLE 表只有 0001（会话/注册/能力/事件）与 0002（WAP）两组加标准 180a，**没有**媒体/取景特征
  （`CanonProtocol.ets:189-233`），因此 BLE 不承担参数与图传。
- EOS 的参数、快门、取景、目录、缩略图、原图能力全在 PTP 操作码集合里
  （`CanonPtpIp.ets:62-97`、`CanonImportService.ets:71-131`）；8 字节包头 + 类型 1~12、
  双 TCP 15740、`Init_Command/Event` 与 ISO 15740 / CIPA DC-X005 一致（契约 §3.1，对照 libgphoto2 `ptpip.c`）。
- 推断（范围性）：CCAPI 要求相机另开 HTTP 服务（常见 8080），本工程既未实现也未探测，
  故「不用 CCAPI」是现状取舍，不是对 CCAPI 可用性的否定。

| 边界 | 做法 | 出处 |
|---|---|---|
| BLE 扫描 | 追加一轮、唯一过滤 Canon 主服务；失败**不降级**全量扫描；只停自己那一轮 | `CanonBleService.ets:276-296`、`:254-260` |
| 识别身份 | 相机 128-bit UUID（32 位 hex 大写）写入 `btAddress`；BLE 地址可轮换，不作身份 | 契约 §0.3、`CanonBleService.ets:57-58` |
| 路由/协议值 | `AppStorage['controlProtocol']='canon'`、`canonHost` | `CameraPage.ets:2962-2963`、`:3123` |
| 关联热点 | 复用松下的 `LumixCameraService.connectToCameraWifi` | `CameraPage.ets:3096-3097` |
| 页面清理 | 图传 `dispose()` **不**关 PTP/IP；控制页 `shutdown()` 才关 | `CanonImportService.ets:474-489`、`CanonControlService.ets:681-706` |

| 段 | 触发点 | 实现 | 产物 |
|---|---|---|---|
| 识别 | 相机页 `startCanonBleDiscovery` | `startScan` + `CanonAdvParser` | `CanonBleCamera`（pid/UUID/rssi/电源位） |
| 配对注册 | `ensureCanonWifi` | `connect` → `ensureBond` → `register` | 绑定 12（尽力）+ `02` 回执（可缺） |
| 入网 | 同上 | 读凭据 → `startWap(9)` → `joinCanonWifi` | 内存 SSID/密码 + host（TLV IP） |
| 传输/遥控 | 图传页/控制页 | `CanonPtpIp` + Import/Control | 图库、下载、参数、取景 |

（入口见 `CameraPage.ets:2861`、`:2944`、`:2993`；各段失败只影响佳能卡片。）

## 2. BLE 广播与识别

服务 UUID 形态 `0001xxxx-0000-1000-0000-D8492FFFA821`：低 96 位固定在 `BASE_SUFFIX`
（`CanonProtocol.ets:191`），首段 8 位区分通道（`00010000` 主服务、`00010005` 状态…），
0002 组是 WAP。注意 `full()`（`:244-246`）只对 4 位短 UUID 成立，而 Canon 首段是 8 位；
该方法当前无调用者（全仓库检索为空），不构成运行时问题。

广播（厂商数据 Company ID 425 = 0x01A9，`CanonProtocol.ets:317`）：

- `[0]` 必须 `== 1`（`organize`），否则不是 Canon BLE 相机（`:319`、`:352-354`）；
- `[1..2]` 小端 = `usbId`（产品 ID），同时是素材表与固件清单的产品号（`:325`、`:356`）；
- 只认两种长度（`:321-323`、`:351-388`）：19 字节长格式 `[3..18]` 为 16B 相机 UUID（小端），
  **不带 flags**（固定 `paired=false`、`powerState=1`，`:357-369`）；6 字节短格式把 `[3][4]`
  放进 16 字节数组的 `[14][15]`（其余补 0），`[5]` 为 flags（`:371-386`），故身份串只有尾 4 位有效；
- flags：bit0=已配对，bit1-2=电源/配对状态 0/1/2（`:334-337`）；0=AUTO_POWER_OFF、
  1=POWER_ON、2=POWER_SWITCH_OFF（`:339-341`，`00010005` 运行时同义，`CanonBleService.ets:1199-1207`）；
- 入列只看厂商数据 `organize==1`，服务 UUID 仅补充 `hasSessionService`（`:397-439`）；
- 身份串 = 16 字节先反转再按大端输出 32 位大写 hex（`:448-456`），与官方取 UUID 尾 4 位一致。

扫描（`CanonBleService.ets:205-296`）：唯一 `ScanFilter` 为主服务（`:277-281`，
`SCAN_SERVICE_UUIDS` 只有一项，`CanonProtocol.ets:241`）；`SCAN_MODE_LOW_LATENCY` +
`MATCH_MODE_AGGRESSIVE`、`interval: 0`（`:282-286`）；一轮 60 s 到期 stop→start（`:226-236`）；
已在扫只换回调（`:207-210`）；带过滤扫描失败只记日志，继续复用系统那一轮并在回调里按 425
过滤（`:276-296`、`:298-305`）；同一设备重复回调，日志 3 s 限流、回调不限流（`:320-338`）。

机型表（`CanonModels.ets` + `CanonModelImages.ets`）：95 条，`pid` 即广播 `usbId`
（`CanonModelImages.ets:16`），例 `0x3250 EOS 6D`、`0x3281 EOS 5D Mark IV`、`0x32d2 EOS M50`、
`0x32da EOS R`、`0x32f4 EOS R5`、`0x32f5 EOS R6`、`0x32fc EOS R3`、`0x330b EOS R6 Mark II`、
`0x3313 EOS R1`；未收录就是 `Canon 0x32FB` 形态。`identityFromPid` 三级匹配（pid → 广播名 →
回退，`CanonModels.ets:100-126`），`imageKey='canon_'+slug`，未收录为空串；
`cleanAdvertisedName` 去 `CANON` 前缀/分隔符、能命中素材表时纠正空格、限长 40（`:41-64`）。

## 3. GATT 表（以代码里真实出现的 UUID 为准）

属性列是代码侧期望，运行时以相机上报的 `properties` 为准（`CanonBleService.ets:447-481`）；
注册/能力/事件三特征缺失时 `requireSessionChannels()` 抛 `CHARACTERISTIC_MISSING`（`:408-424`）。

| UUID（首段） | 归属 | 代码期望属性 | 代码用途 | 出处 |
|---|---|---|---|---|
| `00010000` | 服务 0001 | primary service | 唯一 ScanFilter + 会话服务 | `CanonProtocol.ets:194`、`:241` |
| `00010005` | 0001 | read + notify | 会话/电源状态 0/1/2 | `:196`；订阅 `CanonBleService.ets:435`；解析 `:1199` |
| `00010006` | 0001 | write(no rsp) + indicate | 注册 `01`+昵称；回 `02`=OK | `:198`；写 `:643`；回执 `:1128-1135` |
| `0001000a` | 0001 | write(no rsp) | 会话命令 `03`/`04`/`05`/`0A` | `:200`、`:477-489`；写 `:1039`、`:1066`、`:1081` |
| `0001000b` | 0001 | read | 4 字节能力位图 | `:202`；读 `:695-708` |
| `0001000c` | 0001 | indicate | WiFi 事件 type 1~6 | `:204`、`:583-601`；解析 `:1138-1196` |
| `00020000` | 服务 0002 | — | WAP 服务容器 | `:207` |
| `00020001` | 0002 | read | WAP 能力位（bit4=支持带安全类型 START） | `:209`；读 `:902-915` |
| `00020002` | 0002 | write + notify | WAP 命令；TLV 响应 | `:211`；写 `:946`；TLV `:1210-1221` |
| `00020003` | 0002 | indicate | `[code][subCode]` 状态 | `:213`；订阅 `:443`；解析 `:1224-1233` |
| `00020004` | 0002 | read | 交接 SSID | `:215`；读 `:812` |
| `00020005` | 0002 | read | 交接密码（不落库/不进日志） | `:217`；读 `:813` |
| `00020006` | 0002 | read | 安全类型列表（int32 小端数组） | `:219`；`:832-842`、`:918-930` |
| `0000180a` | 标准 DIS | read | 2a29/2a24/2a26/2a28/2a25 | `:222-230`；`:711-723` |
| `00002902` | CCCD | write | notify=`01 00`、indicate=`02 00`（平台 API 代写） | `:233` |

读写细节：读 5 s、写 4 s 超时（`CanonBleService.ets:92-94`）；写优先 `WRITE_NO_RESPONSE`，
被拒才退 `WRITE` 并记日志（`:1336-1359`）；GATT 操作用 `ioBusy` 串行锁，跨页面也排队
（`:1402-1411`）。WAP 服务在老固件上可能缺失：订阅失败只记日志，链路继续（`:436-441`）。

## 4. 首次配对时序

1. **连接**：`connect(deviceId)` → 复用 `LumixImportPrototype.connectGatt`（处理 RPA 地址回写）
   → `getServices()` → 挂 `BLECharacteristicChange`/`BLEConnectionStateChange` → 记录 `bondState`
   → `requireSessionChannels()` → `armChannels()`（`CanonBleService.ets:362-405`）。
2. **订阅**：00010006（优先 indicate）、0001000c（indicate）、00010005（notify）、
   00020002（notify）、00020003（indicate），按实际支持降级（`:432-481`）。
3. **绑定**：`bondState()` 把鸿蒙 `getPairState` 的 0/1/2 与 Android 口径 10/11/12 归一（`:534-556`）。
   `ensureBond`：12 直接过、11 不重复发起，否则 `pairDevice(address)`（`2900099` 视为「已绑定」），
   每 400 ms 轮询、最多 8 s 等 12，超时只记日志并继续（`:571-610`）。
4. **注册帧**：`00010006 = 01 + 昵称`，US-ASCII，昵称截断 20 字节（`CanonProtocol.ets:532-539`）；
   写 3 次（每轮 6 s 等 indicate `02`），写失败立刻收掉等待方；3 次无回执返回 `false` **不抛异常**
   （`CanonBleService.ets:623-662`）。相机 UUID 全 0 时官方根本不发注册帧，全新机身可能永不回
   `02`（`:329-331`、`:616-621`；契约 §10.1）。
5. **禁休眠**：`0001000a = 0A 01`/`0A 02`，仅当能力位 0x40 置位才写，否则只记日志
   （`:1027-1047`、`CanonProtocol.ets:573-576`）；`prohibitSleep()` 为同义别名。
6. **WAP 命令**：`01`=START、`04`+int32 小端 9=`04 09 00 00 00`、`0A`=REQUEST_AP_CONFIG、
   `02`=STOP、`03`=CANCEL（`CanonProtocol.ets:492-529`）。`startWap(9)` 先读 `00020001` bit4 与
   `00020006` 列表，都满足才发 `04 09 …`，否则退回 `01`（`CanonBleService.ets:863-884`）。
7. **交接判据**：同时消费 `00020002` 的 TLV 与 `00020003` 的 `[code][subCode]`；`Code=1/Sub=3`
   （或 `Code=2/Sub=3`）视为受理、`Code=1/Sub=4..9` 视为拒绝，受理后还要等 IP 到齐
   （`:995-1020`、`CanonProtocol.ets:694-729`）。READY 位 `0x100000` 只留常量**不参与判定**：
   TLV 只置 `0x10000`，两者在 APK 里自相矛盾（`CanonProtocol.ets:638-660`；契约 §10.3）。
8. **TLV**：主路径无条件跳过前 2 字节（`:751-773`），解析不到已知 tag 再按「无头」重试一次
   （推断：老固件可能直接给 TLV）。`0x10` IP 4B 小端→点分十进制；`0x02` BSSID 6B 小端→12 位
   大写 hex；`0x30` WTIME 官方只读 1 字节、不反转、按 `%d00` 解释，代码 ≥4B 按 u32、否则按 1B，
   统一 ×100 得毫秒（`:797-812`；契约 §10.2）。
9. **其余会话字**：`03`+16B 反转 UUID、`04`+昵称、`05 02`（`CanonProtocol.ets:547-570`）；
   `writeSessionUuid` 只收 32 位 hex / 8-4-4-4-12，长度不对抛 `INVALID_ARGUMENT`
   （`CanonBleService.ets:1055-1073`）。
10. **清理**：`disconnect()` 停扫描轮次、收掉注册/凭据/WAP 等待方、清一次性定时器、反订阅、
    `disconnect()`+`close()` GATT（`:489-527`）。

错误码（`CanonBleError.code`，`CanonProtocol.ets:861-873`）：0 LOCAL、1 NOT_CONNECTED、
2 CHARACTERISTIC_MISSING、3 WRITE_FAILED、4 READ_FAILED、5 TIMEOUT、9 INVALID_ARGUMENT、
10 CREDENTIAL_UNAVAILABLE 均在用；**6 BOND_FAILED / 7 REGISTER_REJECTED / 8 WAP_REJECTED
从不抛出**——绑定失败、注册无回执、WAP 被拒都降级为 `false` / `ok=false`（全仓库仅定义处命中）。

## 5. Wi-Fi

- 形态：相机自建 AP，手机作 STA 关联；相机在 AP 内是网关（`CameraPage.ets:3111-3112` 的注释与
  「无 IP 时退回 `linkedGateway()`」印证）。DHCP 服务端身份属**推断**。
- SSID 规则：**代码不构造 SSID**，也不做前缀/后缀推导——SSID 只出现在「读相机下发值」与
  日志/关联路径（`CanonBleService.ets:736-829`、`:1138-1166`）。AP 名由机身决定（推断）。
- 凭据来源两条：① `0001000c` indicate（type1=SSID、2=密码、3=安全、4=结果，
  `CanonProtocol.ets:583-601`），收到的凭据 30 s 内可复用（`CanonBleService.ets:742-755`、`:108-109`）；
  ② 回退直读 `00020004/05/06`（`:807-842`）。判据：SSID 非空且（密码非空或 OPEN），否则抛
  `CREDENTIAL_UNAVAILABLE`（`:784-801`）。密码只在内存与函数栈，不落库、不进日志（`:1156-1157`）。
- 关联：`securityType` 固定 3（HarmonyOS WPA2-PSK），整体委托松下关联实现
  （`CameraPage.ets:3084-3097`）；这是常量而非相机上报值，属实现取舍。
- 地址与端口：host = WAP TLV `0x10` 的 IP → `linkedGateway()` → 兜底 `192.168.1.2`，写
  `AppStorage['canonHost']`（`:3113-3123`）。端口固定 **15740**（`CanonPtpIp.ets:466`）。
  控制/图传页取 host：`AppStorage['canonHost']` → `linkedGateway()`
  （`CanonControlService.ets:189-197`、`CanonImportService.ets:1285-1298`）。

## 6. PTP/IP 传输层

- 两条 TCP：命令 + 事件，同为 15740（`CanonPtpIp.ets:466`、`:550`、`:570`）。
- 分帧：8 字节头 = 长度 u32（含头）+ 类型 u32，均小端；长度 `<8` 或超上限判非法
  （`CanonTcpChannel.readPacket`，`:242-252`）。控制通道单包上限 64 MiB、事件通道 256 KiB（`:469-471`）。
- 握手：`Init_Command_Request`(1) 载荷 = 16B 固定 GUID + UTF-16LE 名称 + 2B NUL + 版本
  `0x00010000`（`:551-558`、`:485-493`）；读 `Init_Command_Ack`(2)，`connectionNumber` 取载荷
  首 4B（缺省 1），`Init_Fail`(5) 抛错（`:559-567`）。事件通道发 `Init_Event_Request`(3) 载荷 =
  connectionNumber，读 `Init_Event_Ack`(4) 后启动常驻读循环；事件通道失败只降级（`:568-583`）。
- 会话序列：`OpenSession(0x1002, session=1)` → `SetRemoteMode(0x9114, 1)` →
  `SetEventMode(0x9115, 1)` → `KeepDeviceOn(0x911D)` → `GetDeviceInfo(0x1001)`；后三步失败仅记
  日志（`:584-604`）。关闭：`CloseSession(0x1003)`（3 s）后关两条 socket（`:611-633`）。

| 类型 | 名称 | 本工程使用 |
|---|---|---|
| 1/2 | Init_Command_Request / Ack | 握手（`:558`、`:559`） |
| 3/4 | Init_Event_Request / Ack | 事件通道握手（`:571-577`） |
| 5 | Init_Fail | 命令通道判失败（`:560-562`）；事件通道仅记日志 |
| 6/7 | Operation_Request / Response | 所有事务（`:678-696`） |
| 8 | Event | 异步事件，两条通道都处理（`:797-799`、`:822`） |
| 9/10/11 | Start_Data / Data / End_Data | 收/发数据阶段（`:727-741`、`:764-775`） |
| 12 | Cancel_Transaction | **已定义未使用**（`:38`，无第二处引用） |

- 请求：`dataPhase(u32) + opcode(u16) + transactionId(u32) + 参数(u32 小端)`（`:678-684`）。
  dataPhase 取 `NONE=1 / IN=2 / OUT=3`（`:42-46`），与契约 §3.1 的「无数据/收数据=1、发数据=2」
  文字不一致；代码按 CIPA 口径（推断：标准如此，代码更可能正确）。
- 应答：`code(u16) + transactionId(u32) + 参数`，参数从偏移 6 起（`:686-696`）；事务 ID 自增并
  跳过 0（`:672-676`）；所有事务经 `runExclusive` 单队列串行，事件泵不插队（`:654-670`）。
- 数据阶段：收方向 `Start_Data` 读总长度（u64 @4），`Data`/`End_Data` 各剥 4 字节 transactionId
  后拼包（`:716-754`）；发方向按 1 MiB 切片，先 `Start_Data(txid+u64 长度)` 再 `Data`，最后
  `End_Data`（`:756-778`）。
- 超时：握手 6 s、命令 10 s、取数据 15 s（`:473-477`）；事件读循环 4 s 超时视为无事件继续
  （`:821-827`）；`GetEvent` 最小 1 s，超时返回空数组（`:858-870`）。
- DeviceBusy：`0x2019` 时等 120 ms 重发一次（`:787-793`）。**缺陷**：重发用
  `buildOperationRequest(opcode, transactionId, [], NONE)`，原参数被丢弃（`:792`），带参命令
  （读属性、分块取图）会以空参数重试，大概率换回 `0x2006`。
- 事件 blob：`[size u32][code u32][payload]` 循环，`size<8`、越界或 `size==8 && code==0` 即停
  （`:873-894`）。`0xC189`：dpc@0、值@+4（相对 blob 即 `0x0c`），控制层按 `data.subarray(4)` 读
  （`CanonControlService.ets:369-383`）；`0xC18A`：dpc@0、type@+4、count@+8、values@+12（绝对
  `0x14`），按 count 逐 u32 读（`:384-402`）。
- 异步 Event 包 = `code(u16) + txid(u32) + 参数`，参数从偏移 6 起（`:835-851`）；监听器异常被吞掉。
- 设备信息按 ISO 15740 §13.2 顺序解析（`:906-932`），只取厂商名/机型/版本/序列号/标准操作码。

EOS 操作码使用情况（常量表 `CanonPtpIp.ets:62-97`、`CanonImportService.ets:71-131`）：

| 用途 | 操作码 | 调用位置 |
|---|---|---|
| 会话/事件 | `0x1001` `0x1002` `0x1003` `0x9114` `0x9115` `0x9116` `0x911D` | `CanonPtpIp.ets:584-621`、`:862` |
| 属性 | `0x1015` 读、`0x9110` 写、`0x1014` 描述符 | `:977`、`:968`、`CanonControlService.ets:244` |
| 快门/AF/变焦 | `0x9128` `0x9129` `0x9154` `0x9160` `0x9158` `0x915A` | `CanonControlService.ets:578-653` |
| 取景 | `0x9151` `0x9152` `0x9153` | `:471-497`、`CanonPtpIp.ets:986` |
| 存储/目录 | `0x9101`/`0x1004`、`0x9102`/`0x1005`、`0x1007`、`0x1008` | `CanonImportService.ets:527-689` |
| 图传 | `0x910A`/`0x100A`、`0x9104`/`0x1009`、`0x912C`、`0x9132` | `:786-1020` |
| 固件 | `0x100C` `0x100D` `0x911F` | `CanonFirmwareService.ets:412-464` |
| 定义未用 | `0x9127` RequestDevicePropValue、`0x9155` DriveLens、`0x914D` DrivePowerZoom | `CanonPtpIp.ets:76`、`:87-88`（无调用） |
| 未定义 | `0x9109` GetObjectInfoEx | 常量与实现都没有（核实表 C5） |

## 7. 控制与传输

### 7.1 参数 get/set

`get = GetDevicePropValue(0x1015, [dpc])`（`CanonPtpIp.ets:977-984`）；
`set = SetDevicePropValueEx(0x9110)`，载荷 `[dpc u32][value u32]`（`:968-975`）。
描述符读 `0x1014`：`getSet` bit0 判可写、`formFlag==2` 才解析枚举（`CanonControlService.ets:241-276`）。
14 项属性表（`CanonProperties.ets:62-139`；EDSDK 列抄契约 §4.1，DPC 列来自 libgphoto2）：

| key | 中文 | EDSDK | PTP DPC | 编码 | 无描述符可写 |
|---|---|---|---|---|---|
| `mode` | 曝光模式 | 0x0400 | 0xD105 | u32 | 否 |
| `shutter` | 快门 | 0x0406 | 0xD102 | APEX×8 | 是（本地候选，标 inferred） |
| `aperture` | 光圈 | 0x0405 | 0xD101 | APEX×8 | 是（同上） |
| `iso` | ISO | 0x0402 | 0xD103 | u32 | 是（同上） |
| `ev` | 曝光补偿 | 0x0407 | 0xD104 | i32 1/8 EV | 是（同上） |
| `quality` | 画质 | 0x0100 | 0xD120 | u32 | 否 |
| `wb` | 白平衡 | 0x0106 | 0xD109 | u32 | 否 |
| `drive` | 驱动模式 | 0x0401 | 0xD106 | u32 | 否 |
| `bracket` | 包围曝光 | 0x040A | 0xD11D | u32 | 否 |
| `focus` | 对焦模式 | 0x0404 | 0xD108 | u32 | 否 |
| `metering` | 测光 | 0x0403 | 0xD107 | u32 | 否 |
| `zoomSpeed` | 变焦速度 | 0x0444 | 0xD149 | u32 | 是 |
| `lvOutput` | 取景输出 | 0x0500 | 0xD1B0 | 位掩码 | 是（内部） |
| `lvMode` | 取景模式 | 0x0501 | 0xD1B1 | u32 | 是（内部） |

选项来源优先级：`0x1014` 描述符 → `0xC18A` 事件 → 连续量本地候选（`inferred`）；枚举类无相机
列表时用静态文案表但 `writable=false`（`CanonControlService.ets:200-234`、`:369-402`）。写入
500 ms 去抖、同 key 覆盖（`:314-334`、`:336-351`），失败只提示不抛。事件泵每 400 ms 一轮
（`:357-367`），`0xC181`/`0xC187` 触发拍摄完成与设备变化回调（`:403-407`）。值格式化：光圈
`2^(apex/2)`、快门 `2^(-apex)`，0/`0xFFFFFFFF` 显示 `--`（`CanonProperties.ets:281-302`）。

### 7.2 快门 / 录像 / 取景 / 对焦 / 变焦

- 快门五参数：`switch=(param>>16)&0xFFFF`、`action=param&0xFFFF`，调 `RemoteReleaseOn(0x9128)`
  两个参数（`CanonControlService.ets:589-602`）；全按 param 3（带 AF）或 `0x10003`（不带），
  保持 220 ms 后释放（`:546-562`）；半按 1 / `0x10001`（`:565-573`）；param 0 等价于连发
  `RemoteReleaseOff(0x9129,[1])` 与 `[2]`（`:576-587`）。映射属推导（契约 §4.2），日志打印实际值。
- 录像：PTP 无取证过的录像指令，`toggleMovie()` 返回 `false` 并提示用机身按键（`:666-669`）；
  `isMovieMode()` 只看曝光模式值 11（`:672-675`）。
- 取景：`0xD1B0 |= 2` → `InitiateViewfinder(0x9151)` → 循环 `GetViewFinderData(0x9153,[0x00200000])`
  → `TerminateViewfinder(0x9152)`；空帧等 60 ms，连续 5 次失败停流（`:458-533`、`:30-34`）；
  停止时清 `0xD1B0` 的 bit1（`:501-506`）。
- 对焦：`DoAf(0x9154)` / `AfCancel(0x9160)`（`:604-611`）；点按先 `SetLiveAfFrame(0x915A)` 发
  4×u32 矩形（`x1,y1,x2,y2`，半宽 40 px）再 `DoAf`，布局无取证、被拒即退化（`:613-637`）。
- 变焦：先写 `0xD149` 速度（可写时），再发 `Zoom(0x9158)`，方向夹 0..2（`:639-660`）；
  `0x914D` DrivePowerZoom 只在常量表（`CanonPtpIp.ets:88`、核实表 C5）。

### 7.3 卷、目录、缩略图、下载（`CanonImportService.ets`）

- 卷：`0x9101` 失败回退 `0x1004`（`:527-545`）；**过滤 storageId=0**（PTP 里 0 表示全部卷，
  `:539-543`）；逐卷 `0x9102` → `0x1005`（`:547-575`），标签取 `VolumeLabel`，空则
  `StorageDescription`，再空则 `卡 N`（`:505`、`:1113-1117`）；体积须自洽（容量>0 且剩余≤容量）
  才 valid（`:1119`），不可解析时卷仍入列、数值为 0（`:568-571`）。
- 目录：BFS 从 `parent=0` 递归，保持 `GetObjectHandles` 原序、不做客户端排序；防御上限
  2048 目录/深度 12/200000 对象（`:604-660`、`:63-66`）。`0x1007` 先发 3 参数
  `(storage, 0, parent)`，回 `0x2005/0x2006` 退 2 参数，其它非 OK 按空目录（`:662-680`）。
- 条目：`0x1008` 数据集 <53B 丢弃；偏移 `storage@0`、`format@4(u16)`、`size@8`、`parent@38`、
  文件名 `@52` 起 PTP 字符串（`:682-689`、`:1080-1099`）。过滤目录 `0x3001` 与
  Text/DPOF/WAV/MP3/XML；视频含 MP4 `0xB982`、AVI/MPEG/ASF/QT；RAW 含 CRW/CRW3/CR3
  （`:108-131`、`:1158-1204`）。`imageId=storageId+':'+handle`，`groupId` 取目录号（`:638-650`）。
- 缩略图：`0x910A` → `0x910A[handle,0]` → `0x100A`，失败留空占位（`:786-797`）；缓存
  `filesDir/canon_thumb/<storageId>_<handle>.jpg`，串行、每轮 6 次请求、间隔 160 ms，下载期让路
  （`:724-783`、`:44-52`）。
- 下载：逐张串行，1 MiB 分块 `0x912C`，4 参数 `(handle, offset, len, 0)` 被拒改 3 参数并记住
  （`:969-991`）；首块失败则整包回退 `0x9104`→`0x1009`（上限 64 MiB，超限放弃，`:994-1007`）；
  成功/取消/失败都在 `finally` 发 `0x9132`（`:1010-1020`）；落盘写 `.part`，校验字节数与
  `ObjectInfo.size` 一致后 rename（`:893-966`），再 `createAsset` 进相册，失败只记日志（`:1022-1040`）。
- 取消：置标记，块间退出，停在当前条目并保留已下载文件（`:804-810`、`:873-875`）。

## 8. 实现对照表

| 能力 | 契约/核实表要求 | 代码事实 | 判定 |
|---|---|---|---|
| 控制协议 | 不用 CCAPI | 无 CCAPI 痕迹，无相机 HTTP 通道 | 一致 |
| BLE 扫描 | 唯一 ScanFilter + LOW_LATENCY，60 s 重启 | `CanonBleService.ets:277-290`、`:226-236` | 一致 |
| 广播解析 | 425、`[0]==1`、19/6 字节 | `CanonProtocol.ets:351-439` | 一致 |
| GATT 表 | 0001/0002/180a/CCCD | `CanonProtocol.ets:189-233` + `armChannels`（`CanonBleService.ets:432-444`） | 一致 |
| 绑定 | 10 才绑、等 12、2900099 视为已绑 | `CanonBleService.ets:571-610` | 一致 |
| 注册 | `01`+昵称，3 次等 `02` | `CanonBleService.ets:623-662` | 一致（失败不抛） |
| WAP 命令/前置条件 | `04 09 …` 需 bit4+列表含 9 | `CanonBleService.ets:863-884` | 一致 |
| TLV/状态 | 跳 2 字节、1B WTIME、code/subcode | `CanonBleService.ets:751-827`、`CanonProtocol.ets:694-729` | 有偏差（双解析兜底） |
| PTP/IP 握手 | 双 15740 + Init 1/2/3/4 | `CanonPtpIp.ets:538-583` | 一致 |
| 会话序列 | 0x1002→0x9114→0x9115→0x911D | `CanonPtpIp.ets:584-600` | 一致（后三步可失败） |
| 事务/重试 | 6/7/9/10/11、Busy 重试 | `CanonPtpIp.ets:704-809` | 有偏差（重试丢参数） |
| 事件 blob | `[size][code][payload]`，值 `@0x0c`、列表 `@0x14` | `CanonPtpIp.ets:873-894` | 一致 |
| 参数表 | 14 项 EDSDK↔DPC | `CanonProperties.ets:62-139` | 一致 |
| 快门五参数 | 0/1/0x10001/3/0x10003 | `CanonControlService.ets:546-602` | 推断（高低位拆分） |
| 取景 | Initiate→循环→Terminate | `CanonControlService.ets:458-533` | 一致 |
| 录像 | 无 PTP 指令 | `CanonControlService.ets:666-669` 返回 false | 一致（显式失败） |
| 卷/目录 | 卷为单位、不排序、递归 | `CanonImportService.ets:495-680` | 一致 |
| 缩略图/下载 | 0x910A 缓存、0x912C 分块+0x9132 | `CanonImportService.ets:786-1020` | 一致 |
| 契约 §3.4 包装 API | `getObjectHandles`/`getThumb`/`getPartialObject` 等 | **未实现**：`CanonPtpIp.ets:949-991` 只有 `getStorageIds`/`setDevicePropValueEx`/`getDevicePropValue`/`getViewFinderData`，其余由 Import/Control 直接 `op/opIn/opOut` | 偏差（功能等价） |
| 契约 §3.3 签名 | `connect(host, name)` | `connect(host, name, timeoutMs=10s)` | 偏差（多可选参数） |

## 9. 限制与风险

1. **无真机**：BLE 广播、WAP 交接、PTP/IP、取景、快门、图传、固件全链路只做静态核对
   （核实表 §I.1）；标注「推断」的项已在上表体现。
2. **机型差异**：老固件可能没有 0002 组（WAP 不可用、只能读凭据）；`0x9101/0x9102/0x910A/0x912C`
   都备了回退分支（契约 §3.4），但哪些机身会回 `0x2005/0x2006` 未取证；空卡/只读卡可能不给体积
   （按 0 显示）。这些分支均无真机覆盖。
3. **BLE 地址轮换**：身份用相机 UUID，但短格式只有尾 4 位有效、全新机身 UUID 全 0，此时身份
   不唯一、只能靠界面顺序（`CanonBleService.ets:329-331`）；`getPairState` 对 BLE 地址可能返 0
   （非 BR/EDR 地址），绑定退化为「试一次 `pairDevice` 再等 8 s」（`:581-584`）。
4. **注册失败重试**：3 次 ×6 s 无 `02` 返回 `false` 继续；若相机要求注册成功才给凭据，会在 WAP
   阶段以「无 SSID」告终，用户看到的是 Wi-Fi 失败而不是注册失败。
5. **WAP READY 位不可达**：`0x100000` 与 TLV 只置的 `0x10000` 冲突，实现改为「状态码 + TLV IP」；
   若相机只发状态不发 TLV，只能靠超时分支判 ok（`:954-962`）。
6. **TLV 头部假设**：跳 2 字节来自 APK，无头解析是推断性兜底；带 2 字节头而首 tag 未知时两种
   解析都可能落空 → 拿不到 IP → 退回网关地址。
7. **DeviceBusy 重试丢参数**（`CanonPtpIp.ets:792`）：带参命令可能因重试变成参数错，建议保留原请求体。
8. **APEX×8 假设**：光圈/快门同按 APEX×8（1/125 s≈56、f/4≈32），与契约 §4.1「APEX 定点」一致
   但未真机验证；值域不同只需改 `CanonFormat`（核实表 §I.4）。
9. **枚举文案本地化**：相机不给列表时用 EDSDK 口径中文表，未知值显示 `#十进制`；连续量候选标
   `inferred`，可能与具体机身档位不一致。点按对焦的 4×u32 布局同样无取证，`0x914D` 未封装。
10. **录像不可用**：PTP 无指令，按钮必然失败；录像只在 BLE 遥控服务 `00030030`（未实现）。
11. **权限**：需 `ACCESS_BLUETOOTH`、`LOCATION`/`APPROXIMATELY_LOCATION`（BLE 扫描系统要求）、
    `GET_WIFI_INFO`/`SET_WIFI_INFO`、`GET_NETWORK_INFO`、`INTERNET`、`WRITE_IMAGEVIDEO`（存相册），
    见 `entry/src/main/module.json5`；未授权时扫描/关联/TCP/相册步骤失败，只写日志与页面文案。
12. **会话共享**：图传 `dispose()` 不关 PTP/IP、控制页 `shutdown()` 会关；两页同时存活时先退出的
    控制页会断掉图传页会话（`CanonImportService.ets:474-489` 注释已声明该取舍）。
