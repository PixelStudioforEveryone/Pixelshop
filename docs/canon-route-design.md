# Canon 路线实现契约（Canon Camera Connect / EOS PTP-IP）

> 依据：`C:\Users\HQ\Desktop\picture\documents\Canon\report\00~04`（下称「报告」）、
> `documents\Canon\decompile\jadx_src`、`documents\Canon\tmp\ptp_ds_commands.txt`、
> `documents\Canon\tmp\strings\*.strings.txt`。
> 交叉核对（报告明确说 `0x50xx/D1xx` 码在 native，仅能推断）：本机
> `C:\Users\HQ\Desktop\picture\libgphoto2-master\camlibs\ptp2`（`ptp.h`/`ptp.c`/`ptp-pack.c`/`ptpip.c`）
> 是 Canon EOS PTP 的公开实现，用来补齐报告标注【未知】的 opcode/DPC 数值；
> 每处引用都要在注释里写清「报告 §x / libgphoto2 文件:行」。

## 0. 铁律（评审会逐条检查）

1. **不许改**松下 LAB / SYNC / ImageApp、尼康、索尼、富士的任何协议、页面、
   服务、资源；也不许改它们共用的行为。只允许在下列「我方文件」里新增：
   - `entry/src/main/ets/services/Canon*.ets`
   - `entry/src/main/ets/pages/Canon*.ets`
   - `entry/src/main/ets/pages/home/CameraPage.ets`（仅由主代理改，子代理不碰）
   - `entry/src/main/ets/services/CameraSessionStore.ets`（仅由主代理改）
   - `entry/src/main/resources/base/profile/main_pages.json`（仅由主代理改）
   - `entry/src/main/resources/rawfile/canon/**`（已生成，勿改）
2. **佳能路线与现有路线并行**：BLE 扫描是「追加一轮扫描」，不是替换；
   任何失败都只影响佳能卡片，不能中断松下/尼康/索尼/富士的扫描与已连接会话。
3. **识别身份用相机 UUID**：Canon 广播的 128-bit 相机 UUID（短格式取低 2 字节
   补零）是稳定身份，写入 `LumixBleCameraCandidate.btAddress`（32 位 hex，
   大写）。BLE 的 MAC 可能轮换，不能当身份。
4. **一切协议常量必须有出处注释**（报告章节或 libgphoto2 文件:行）。禁止
   凭感觉编造 opcode / 属性码 / 报文长度。
5. **不能伪造可用性**：相机没给描述符/只读的属性，页面必须「可见但置灰」，
   点击提示「相机未提供该参数」，绝不假装可写。
6. **日志**：统一 `AppLogSink.emit('CANON', ...)`（BLE 用 `CANON_BLE`，
   PTP 用 `CANON_PTP`，控制用 `CANON_CTL`，图传用 `CANON_IMG`，固件用
   `CANON_FW`）。不得打印 WiFi 密码、UUID 全串（取前 8 位）。
7. **ArkTS 严格模式**：禁止 `any`/`unknown` 作字段类型；函数显式返回类型；
   不使用 `!` 非空断言；对象字面量必须有 interface/class 类型；不新增三方依赖。
8. **超时与清理**：所有 socket/定时器/监听必须在 `shutdown()`/`dispose()` 里
   释放；每处 `setTimeout` 都要保存 id 并 `clearTimeout`。

## 1. 品牌与路由

| 项 | 值 |
|---|---|
| `cameraBrand` | `'Canon'`（唯一字符串） |
| `cameraImageKey` | `canon_<slug>`，slug 来自 `CanonModelImages`（`eos_r5` 等） |
| 控制页路由 | `pages/CanonCameraControlPage` |
| 图传页路由 | `pages/CanonImageTransferPage` |
| 固件页路由 | `pages/CanonFirmwarePage` |
| 控制协议全局值 | `AppStorage['controlProtocol'] = 'canon'` |

素材表 `services/CanonModelImages.ets` 已由 `tools/build_canon_art.py` 生成：
95 个产品 ID，`pid` 即 BLE 厂商数据里的 `usbId`，也是固件清单 `<item id>`。
`services/CanonModels.ets` 由主代理实现，对外：

```ts
export interface CanonIdentity {
  pid: number;          // 0 表示未知
  model: string;        // 已收录机型名 / 'Canon 0x32FB' / BLE 名兜底
  imageKey: string;     // 'canon_eos_r5' / ''
  series: string;
}
export class CanonModels {
  static readonly BRAND: string;                 // 'Canon'
  static readonly IMAGE_KEY_PREFIX: string;      // 'canon_'
  static brandOf(pid: number): string;
  static identityFromPid(pid: number, advertisedName: string): CanonIdentity;
  static identityFromName(name: string): CanonIdentity | null;
  static imageKeyOfPid(pid: number): string;
  static isCanonImageKey(key: string): boolean;
  static rawfileForImageKey(key: string): string; // 'canon/<slug>.png'
  static cleanAdvertisedName(raw: string): string; // 去厂商前缀/序列号，限长 40
}
```

## 2. BLE（`services/CanonProtocol.ets` + `services/CanonBleService.ets`）

### 2.1 UUID（报告 01 §5.1，基址 `0000xxxx-0000-1000-0000-d8492fffa821`）

| 名称 | 值 | 用途 |
|---|---|---|
| 主服务 / 扫描过滤 | `00010000-0000-1000-0000-d8492fffa821` | 唯一 ScanFilter |
| 会话状态 | `00010005-…` | read+notify（电源/会话） |
| 配对注册 | `00010006-…` | write `01`+昵称；indicate `02`=OK |
| 会话命令 | `0001000a-…` | UUID/昵称/类型/频段/禁休眠 |
| 能力位图 | `0001000b-…` | read |
| WiFi 事件 | `0001000c-…` | indicate：1=SSID 2=password 3=security 4=result 5=scan 6=securityList |
| WAP 服务 | `00020000-…` | — |
| WAP 能力 | `00020001-…` | read |
| WAP 命令 | `00020002-…` | write 命令；notify TLV 响应 |
| WAP 状态 | `00020003-…` | `[code][subcode]` |
| 交接 SSID/密码/安全 | `00020004/05/06-…` | read |
| 标准设备信息 | `0000180a-…` | `2a29/2a24/2a26/2a28/2a25` |
| CCCD | `00002902-0000-1000-8000-00805f9b34fb` | notify `01 00` / indicate `02 00` |

### 2.2 广播解析（报告 01 §1.2）

`manufacturerData(425)`：

- `[0]` 必须 `== 1`（否则不是 Canon 相机）；
- `[1..2]` 小端 → `usbId`（产品 ID）；
- 长度 19：`[3..18]` 16 字节相机 UUID（小端）；
- 长度 6：`[3..4]` 为 UUID 低 2 字节（放回 16 字节数组的 `[15][14]`），
  `[5]` bit0=已配对，bit1-2=配对/电源状态。
- 只有 `organize==1` 才入列；同 MAC 只更新 flags；身份键 = 相机 UUID。

"小端"指先用 `C0251f.d()` 反转字节再按大端读（报告 01 §1.2）。
实现：`reverse(bytes)` 后 `getLong`/`getShort` 等价；UUID 字符串按
`8-4-4-4-12` 输出大写。

### 2.3 应用层帧

`[1 字节命令][裸 payload]`，无长度/头/CRC；字符串 US-ASCII；多字节小端；
写全部 Write Without Response。命令字节：

- 配对注册：`0x01` + 昵称（ASCII，≤ 20 字节，实际长度以相机能力为准）。
- 会话命令（`0001000a`）：见报告 01 §3.2，主代理只要求实现：
  `writeSessionUuid(uuid)`、`writeNickname(name)`、`prohibitSleep(boolean)`。
- WAP（`00020002`）：`01`=START、`04 09 00 00 00`=带安全类型 START、
  `0x0A`=REQUEST_AP_CONFIG、`03`=CANCEL、`02`=STOP。
- WAP TLV：`0x10`=IP（4B 小端）、`0x02`=BSSID（6B）、`0x30`=WTIME（4B）。

### 2.4 对外 API（页面/主代理只依赖这些）

```ts
export interface CanonBleCamera {
  deviceId: string;
  name: string;        // 广播名（原样）
  model: string;       // CanonModels 清理后的机型名
  imageKey: string;    // 'canon_<slug>' 或 ''
  pid: number;         // usbId，0=未知
  cameraUuid: string;  // 32 位大写 hex（稳定身份）
  paired: boolean;     // 广播 flags bit0
  powerState: number;  // 0/1/2
  connectable: boolean;
  rssi: number;
}

export interface CanonWifiCredential { ssid: string; password: string; security: number; }
export interface CanonWapResult { ok: boolean; ip: string; bssid: string; wtime: number; code: number; subCode: number; message: string; }

export class CanonBleService {
  static startScan(onFound: (camera: CanonBleCamera) => void): Promise<void>;
  static stopScan(): void;
  static isScanning(): boolean;
  static isConnected(): boolean;
  static current(): CanonBleCamera | null;

  static async connect(deviceId: string): Promise<boolean>;
  static async disconnect(): Promise<void>;
  /** 首次配对：必要时 createBond / pairDevice，再写 00010006。 */
  static async register(camera: CanonBleCamera, nickname: string): Promise<boolean>;
  static async bondState(): Promise<number>;              // 10/11/12
  static async readCapabilities(): Promise<number>;       // 0 = 未知
  static async readFirmware(): Promise<string>;           // 2a26，空串=不支持
  static async readSerial(): Promise<string>;             // 2a25
  static async readModelNumber(): Promise<string>;        // 2a24

  /** 相机 indicate 的 SSID/密码；超时抛 CanonBleError。 */
  static async readWifiCredential(timeoutMs: number): Promise<CanonWifiCredential>;
  /** 读 00020004/05/06（部分固件只走 GATT 读，不主动 indicate）。 */
  static async readWapCredentials(): Promise<CanonWifiCredential>;
  /** 请求 AP 配置（0x0A），等 TLV/状态。 */
  static async requestApConfig(timeoutMs: number): Promise<CanonWapResult>;
  /** 拉起相机 AP：01 或 04 09 00 00 00，等 TLV + 00020003。 */
  static async startWap(securityType: number, timeoutMs: number): Promise<CanonWapResult>;
  static async stopWap(): Promise<void>;
  static async setProhibitAutoPowerOff(prohibit: boolean): Promise<void>;
  static async writeSessionUuid(uuid: string): Promise<void>;
}
```

行为要求：

- 扫描复用 `LumixImportPrototype.connectGatt` / `asCharacteristic`，与富士同法，
  以处理 HarmonyOS 的 RPA 地址回写；扫描 60 s 一轮、超时重启（报告 01 §1.1）。
- 连接后按需 `discoverServices` 一次，特征缺失时给出明确错误（哪个 UUID 缺）。
- 绑定：`connection.pairDevice(address)`；`2900099` 视为「已绑定」而非失败
  （与尼康线同样的系统语义，见 `NikonBleProvisioning` 注释）。绑定等待
  `BOND_STATE_CHANGED(12)`；不实现自定义 PIN。
- 密码不落库、不进日志。
- `readWifiCredential` 先在 0001000c 上等 indicate（type=1/2），超时后回退读
  00020004/05；SSID/密码按 NUL 截断、UTF-8 解码。
- WAP 响应要同时匹配 `00020002` notify 的 TLV 与 `00020003` 的 code/subCode；
  code≠0 时返回 ok=false 并带原文。

## 3. PTP/IP 传输（`services/CanonPtpIp.ets`）

### 3.1 连接（报告 03 §1.1 + libgphoto2 `ptpip.c`）

- TCP 15740（报告 03 §1.1【推断】；libgphoto2 `ptpip.c:793`）。
- 命令通道：`Init_Command_Request`（type=1）载荷 = GUID 16B + UTF-16LE
  名称（含 NUL）+ 版本 `0x00010000`；读 `Init_Command_Ack`（type=2），
  取 `connectionNumber`（载荷首 4B）。
- 事件通道：第二条 TCP 15740，`Init_Event_Request`（type=3）载荷 =
  `connectionNumber`；读 `Init_Event_Ack`（type=4），之后只收 `Event`（type=8）。
- 命令：`Operation_Request`（type=6）载荷 = dataPhase(u32) + opcode(u16) +
  transactionId(u32) + 参数（u32 小端）。dataPhase：无数据/收数据=1、发数据=2。
- 应答：`Operation_Response`（type=7）载荷 = code(u16) + transactionId(u32) +
  参数。数据阶段包：`Start_Data`(9) / `Data`(10) / `End_Data`(11)。
- 事务 ID 全局自增（从 1 开始）。
- 连接后：`OpenSession(0x1002, sessionId=1)`，再
  `SetRemoteMode(0x9114, 1)`、`SetEventMode(0x9115, 1)`、`KeepDeviceOn(0x911D)`
  （报告 02 §7 的 ①；libgphoto2 `library.c:3290`、`ptp.h` 0x9114/0x9115/0x911D）。
- 关闭：`CloseSession(0x1003)` → 关两条 socket；设备端 `SetRemoteMode(1)` 复位。

### 3.2 错误与超时

```ts
export class CanonPtpError extends Error {
  readonly code: number;      // PTP response code，0=本地错误
  readonly opcode: number;
  readonly detail: string;
}
```

- 命令超时 10 s；取图/取帧 15 s；`GetEvent` 1 s（超时=无事件，不算错误）。
- socket 断开 → 所有挂起事务 reject `CanonPtpError(code=0, detail='socket closed')`。
- 收到 `DeviceBusy(0x2019)` 时重试一次（间隔 120 ms）。

### 3.3 对外 API

```ts
export interface CanonDeviceInfo {
  manufacturer: string; model: string; deviceVersion: string; serialNumber: string;
  standardOps: number[]; vendorOps: number[]; vendorExtId: number;
}

export interface CanonPtpReply { code: number; params: number[]; }
export interface CanonPtpDataReply { reply: CanonPtpReply; data: Uint8Array; }

export class CanonPtpIp {
  static isOpen(): boolean;
  static async connect(host: string, name: string): Promise<CanonDeviceInfo>;
  static async close(): Promise<void>;
  static async op(opcode: number, params?: number[]): Promise<CanonPtpReply>;
  static async opIn(opcode: number, params?: number[], timeoutMs?: number): Promise<CanonPtpDataReply>;
  static async opOut(opcode: number, params: number[], data: Uint8Array): Promise<CanonPtpReply>;
  static onEvent(listener: (code: number, params: number[], data: Uint8Array) => void): void;
  static offEvent(): void;
}
```

### 3.4 Canon EOS 操作封装（同文件，全部带注释出处）

| 方法 | opcode | 说明 |
|---|---|---|
| `getStorageIds()` | `0x9101`（回退标准 `0x1004`） | 报告 03 §2.1 + `ptp.h:0x9101` |
| `getStorageInfo(id)` | `0x9102`（回退 `0x1005`） | 卷标/访问模式/剩余空间 |
| `getObjectHandles(storage, parent)` | `0x1007` | 目录树（报告 03 §2.2） |
| `getObjectInfo(handle)` | `0x1008` | 名称/大小/时间/格式/文件夹 |
| `getObjectInfoEx(storage, handle)` | `0x9109` | 快速目录（libgphoto2 `ptp.c:3798`） |
| `getThumb(handle)` | `0x910A` | 缩略图（报告 03 §0） |
| `getPartialObject(handle, off, len)` | `0x912C` | 分块下载（`ptp.c:3898`） |
| `endGetPartialObject()` | `0x9132` | 结束分块 |
| `getObject(handle)` | `0x9104`/`0x1009` | 整包下载回退 |
| `setDevicePropValueEx(dpc, value)` | `0x9110` | 载荷 `[dpc u32][value]` |
| `getDevicePropValue(dpc)` | `0x1015` | 标准读值 |
| `requestDevicePropValue(dpc)` | `0x9127` | 读值（配合事件 `0xC189`） |
| `getEvent(timeoutMs)` | `0x9116` | EOS 事件流（报告 02 §1.3） |
| `initiateViewfinder()` | `0x9151` | 取景开始 |
| `terminateViewfinder()` | `0x9152` | 取景结束 |
| `getViewfinderData()` | `0x9153` param `0x00200000` | JPEG 帧；空=无新帧 |
| `doAf()` | `0x9154` | AF |
| `afCancel()` | `0x9160` | 取消 AF |
| `driveLens(amount)` | `0x9155` | LV 焦点微调（命令 259） |
| `drivePowerZoom(speed)` | `0x914D` | 变焦（命令 265） |
| `zoom(dir)` | `0x9158` | 变焦方向（命令 269） |
| `remoteReleaseOn(sw, action)` | `0x9128` | 快门（命令 4） |
| `remoteReleaseOff(sw)` | `0x9129` | 快门释放 |
| `updateFirmware(handleOrData)` | `0x911F` | 固件（见 04 §6） |

事件解析（libgphoto2 `ptp-pack.c:1861`）：

```
blob = [size u32][code u32][payload]...
0xC189 PropValueChanged: dpc=u32@8, value@12
0xC18A AvailListChanged: dpc=u32@8, type=u32@12, count=u32@16, values@20
0xC181 ObjectAddedEx / 0xC187 ObjectInfoChangedEx: handle@8, storage@12, ofc@16(u16), size@28, parent@32, name@40
```

## 4. 控制服务（`services/CanonProperties.ets` + `services/CanonControlService.ets`）

### 4.1 属性表（**严格**按报告 02 §2；PTP 码来自 libgphoto2 `ptp.h`）

| 面板 key | 中文 | EDSDK propId | PTP DPC | 值编码 | 可写 |
|---|---|---|---|---|---|
| `quality` | 画质 | `0x0100` (256) | `0xD120` ImageFormat | u32 枚举 | 相机描述符 |
| `wb` | 白平衡 | `0x0106` (262) | `0xD109` WhiteBalance | u32 枚举 | 相机描述符 |
| `mode` | 曝光模式 | `0x0400` (1024) | `0xD105` AutoExposureMode | u32 枚举 | 相机描述符 |
| `drive` | 驱动模式 | `0x0401` (1025) | `0xD106` DriveMode | u32 枚举 | 相机描述符 |
| `iso` | ISO | `0x0402` (1026) | `0xD103` ISOSpeed | u32 枚举 | 相机描述符 |
| `metering` | 测光 | `0x0403` (1027) | `0xD107` MeteringMode | u32 枚举 | 相机描述符 |
| `focus` | 对焦模式 | `0x0404` (1028) | `0xD108` FocusMode | u32 枚举 | 相机描述符 |
| `aperture` | 光圈 | `0x0405` (1029) | `0xD101` Aperture | u32 APEX 定点 | 相机描述符 |
| `shutter` | 快门 | `0x0406` (1030) | `0xD102` ShutterSpeed | u32 | 相机描述符 |
| `ev` | 曝光补偿 | `0x0407` (1031) | `0xD104` ExpCompensation | i32 1/8 EV | 相机描述符 |
| `bracket` | 包围曝光 | `0x040A` (1034) | `0xD11D` BracketMode | u32 枚举 | 相机描述符 |
| `zoomSpeed` | 变焦速度 | `0x0444` (1092) | `0xD149` PowerZoomSpeed | u32 | 是 |
| `lvOutput` | 取景输出 | `0x0500` (1280) | `0xD1B0` EVFOutputDevice | 位掩码 | 内部 |
| `lvMode` | 取景模式 | `0x0501` (1281) | `0xD1B1` EVFMode | u32 | 内部 |

- 其它面板（`aspect`/`lut`/`settings`）在佳能页**不显示 LUT 传输按钮**；
  `aspect` 若相机没给对应 DPC 就置灰。
- 选项集合**只来自相机**：`0xC18A AvailListChanged` 或 `GetDevicePropDesc`；
  没有描述符 → `writable=false`、`options=[]`，页面置灰。
- 值→显示：光圈 `f/` + `2^(apex/2)`（保留 1 位）、快门按 EDSDK Tv 编码
  （值 `0x0C`=1/60 等，用 `Tv` 表 + 兜底 `1/2^n`）、ISO 数字、EV 用 `+0.0`
  1/8 步、白平衡/画质/模式按相机选项文本。
- 每个属性对象必须暴露 `edsPropId` 与 `ptpDpc`，控制页的「参数对照」抽屉
  直接显示它们，供与报告逐条核对。

### 4.2 对外 API

```ts
export interface CanonParamOption { value: number; label: string; }
export interface CanonParamSpec {
  key: string; panel: string; label: string;
  edsPropId: number; ptpDpc: number;
  value: number; display: string;
  options: CanonParamOption[]; writable: boolean; group: string;
}
export interface CanonControlSnapshot {
  model: string; firmware: string; productName: string; serial: string;
  propsReady: boolean; propCount: number; degradedReason: string;
  driveMode: number; evfOutputDevice: number;
}
export interface CanonCaptureEvent { type: string; param: number; } // 'start'|'complete'|'error'

export interface CanonControlCallbacks {
  onLiveViewFrame?: (jpeg: Uint8Array) => void;
  onCapture?: (event: CanonCaptureEvent) => void;
  onPropChanged?: (key: string, value: number) => void;
  onDeviceChanged?: () => void;
  onNotice?: (message: string) => void;
}

export class CanonControlService {
  static setCallbacks(cb: CanonControlCallbacks): void;
  static async connect(model: string): Promise<CanonControlSnapshot>;
  static async shutdown(): Promise<void>;
  static getProps(): CanonParamSpec[];
  static propOf(key: string): CanonParamSpec | null;
  static async refreshProps(): Promise<boolean>;
  static async setParam(key: string, value: number): Promise<boolean>;

  static async startLiveView(): Promise<boolean>;
  static async stopLiveView(): Promise<void>;
  static async capture(afDrive: boolean): Promise<boolean>;   // S2 全按
  static async halfPress(afDrive: boolean): Promise<void>;    // S1 半按
  static async release(): Promise<void>;                      // param 0
  static async af(on: boolean): Promise<void>;                // 命令 258
  static async tapFocus(x: number, y: number): Promise<void>; // SetLiveAfFrame + DoAf
  static async zoom(direction: number, speed: number): Promise<void>;
  static async toggleMovie(): Promise<boolean>;
  static isMovieMode(): boolean;
  static log(message: string): void;
}
```

- 快门映射必须实现报告 02 §5.1 的 5 个 param（0 / 1 / 0x10001 / 3 / 0x10003）：
  `switch = (param >> 16) & 0xFFFF`、`action = param & 0xFFFF`；
  `remoteReleaseOn(switch, action)`；param=0 时 `remoteReleaseOff(1)` +
  `remoteReleaseOff(2)`。注释里写明这是「报告 param 表 + DS_RemoteReleaseOn
  (inReleaseSwitch,inReleaseAction) 签名」的推导，待真机确认。
- LiveView：`initiateViewfinder` → 循环 `getViewfinderData`（返回 0 字节 =
  无帧，等 60 ms）→ `terminateViewfinder`；帧率不写死。
- 参数写入 500 ms 去抖（报告 02 §3.3），同类任务未完成时覆盖旧值。

## 5. 图传服务（`services/CanonImportService.ets`）

```ts
export interface CanonVolume {
  storageId: number; label: string; access: number;
  capacityBytes: number; freeBytes: number; removable: boolean; sequence: number;
}
export interface CanonGalleryItem {
  imageId: string; storageId: number; handle: number; name: string;
  size: number; dateMs: number; format: number;
  isVideo: boolean; isRaw: boolean; groupId: number; thumbUri: string;
}
export interface CanonImportSnapshot {
  phase: string; message: string; error: string;
  model: string; volumes: CanonVolume[]; activeStorageId: number;
  items: CanonGalleryItem[]; total: number; selectedCount: number;
  loading: boolean; downloadInProgress: boolean; downloadProgress: number;
  downloadStatus: string; downloadCurrent: number; downloadTotal: number;
  revision: number;
}

export class CanonImportService {
  constructor(context: common.UIAbilityContext);
  open(): Promise<void>;                       // 连 PTP/IP，枚举卷，读当前卷
  refresh(): Promise<void>;
  selectVolume(storageId: number): Promise<void>;  // 切卡：清空→加载态→重新枚举
  selectAll(selected: boolean): void;
  toggle(imageId: string): void;
  downloadSelected(): Promise<void>;
  cancelDownload(): void;
  previewUriOf(imageId: string): string;       // 缩略图或已下载原图
  snapshot(): CanonImportSnapshot;
  dispose(): void;
  readonly revision: number;
}
```

- 卷 = 存储卡。**必须以卷为单位建按钮**，空卡也要在列表里（不能从条目反推）；
  卷顺序按 `GetStorageIDs` 返回顺序，`sequence` 从 1 开始；标签用
  `GetStorageInfo` 的 `StorageDescription/VolumeLabel`，空则 `卡 N`。
- 目录树：从卷根递归 `GetObjectHandles` + `GetObjectInfo`（报告 03 §2.2），
  文件夹递归、文件入列；`0x3001` 等视频格式标记视频；CR3/CR2/RAF 等标记
  RAW。**不做任何客户端排序**（报告 03 §2.3：相机顺序即倒序由 App 客户端
  比较器实现；佳能页保持相机顺序，切卡后重新枚举）。
- 缩略图：逐张串行 `getThumb`，缓存到 `context.filesDir/canon_thumb/<handle>.jpg`，
  空闲时后台补齐；页面只读缓存 URI。
- 下载：`getPartialObject` 分块（默认 1 MiB），进度回调写 snapshot；
  保存到 `context.filesDir/canon/<name>` 并 `photoAccessHelper.createAsset`
  进相册（失败只记日志，不影响文件保存）；取消时 `endGetPartialObject`。
- 多卡：切换 storage 时句柄空间独立，`imageId = storageId + ':' + handle`。

## 6. 固件（`services/CanonFirmwareService.ets` + `pages/CanonFirmwarePage.ets`）

严格按报告 04：

1. 当前版本：PTP 属性 7（固件版本）；机型 ID：属性 `0x01000001`；
   产品 ID：`CanonBleService.current().pid`（没有 BLE 时用机型名反查
   `CanonModels`）；都取不到就提示「需要先连接相机」。
2. 清单：`https://gdlp01.c-wss.com/rmds/ic/firmware/camera_urltable.xml`
   （内测包域名的分支不实现，注释说明）；解析 `<firmwarelist><item id version><url>`；
   `Integer.parseInt(id,16)` 与产品 ID 比对。
3. 详情 XML：`<firmware>`/`<filesize>`/`<changes>`/`<eula>`；语言锚点 `#zh-cn`。
4. 版本比较：三段 `parseInt` 严格大于（报告 04 §4）；前导零不影响数值。
5. 下载：GET，8 KB 缓冲，进度百分比，保存 `filesDir/firm/canon/<原名>.FIR`；
   无 Range/超时/校验（与官方一致），失败可重试。
6. `.FIR` 头校验（报告 04 §5.1）：读 4B 小端机型 ID；skip 12；
   若 `0x37582111` 再读 4B；读 12B ASCII 版本；6 段取前 3/后 3；
   文件名 12 字符且扩展名 `FIR`（本实现放宽为「扩展名 FIR」并记录官方约束）。
7. 传输前检查：机型 ID 与 `.FIR` 一致、文件版本 > 当前、文件存在、
   卷 `access==0` 只读 → 卡保护、卷标 7=HDD/错误 → 卡错误、
   `freeBytes <= filesize` → 容量不足、低电量错误码 `0xA101`。
8. 发送：`EOS_UpdateFirmware (0x911F)`。**报告标注该 opcode 未取得**，
   因此实现顺序为：先 `SendObjectInfo(0x100C)` + `SendObject(0x100D)` 把
   `.FIR` 以 `ObjectFormat=0x3000`、文件名原名推入相机，成功后调用
   `0x911F`（参数=objectHandle）；若 `0x911F` 返回 `0x2005/0x2009`
   （不支持/参数错）则回退 `0x910B SendPartialObject` + `0x911F`。
   所有分支写日志并在页面显示「协议为推断，失败时请用读卡器方式升级」。
9. 传输后：进度事件 70 → 百分比；完成 → 提示「等相机重启」10×1s →
   第 4/4 步「请在相机屏幕确认升级」；客户端不再发命令（报告 04 §6.3）。

```ts
export interface CanonFirmwareVersionState {
  current: string; latest: string; productIdHex: string;
  hasUpdate: boolean; detail: CanonFirmwareDetail | null; message: string;
}
export interface CanonFirmwareDetail {
  version: string; firmwareUrl: string; fileSize: number;
  changesUrl: string; eulaUrl: string; productIdHex: string;
}
export class CanonFirmwareService {
  static async readCameraState(): Promise<CanonFirmwareCameraState>; // 版本/机型/产品ID
  static async fetchCatalog(productIdHex: string): Promise<CanonFirmwareVersionState>;
  static async download(detail: CanonFirmwareDetail,
    onProgress: (percent: number, received: number, total: number) => void): Promise<string>;
  static validateFir(path: string): Promise<CanonFirInfo>;
  static async send(path: string, onProgress: (percent: number) => void): Promise<boolean>;
  static async cancel(): Promise<void>;
  static log(message: string): void;
}
export interface CanonFirInfo { modelId: number; version: string; size: number; valid: boolean; reason: string; }
export interface CanonFirmwareCameraState { model: string; firmware: string; modelId: number; productIdHex: string; connected: boolean; }
```

## 7. 页面

### 7.1 `pages/CanonCameraControlPage.ets`

- 复制松下 LAB 控制页的**布局结构**（顶栏 + 身份行 + 快捷参数 + 参数网格 +
  底部条），以 `pages/FujifilmCameraControlPage.ets` 为可编译参照；
  **不保留 LUT 传输按钮**（松下 LAB 页里的 LUT 入口在佳能页不出现）。
- 两种形态必须严格区分（用户明确要求）：
  - 预览：整屏取景 + AF 框 + 底部快门/录像；只有此形态推流；
  - 遥控：顶栏 + 参数网格 + 冻结画面；切到遥控立即 `stopLiveView()`。
- 参数表来自 `CanonControlService.getProps()`；每项显示 `label + display`，
  可写才可点；点击弹选项列表（相机给的 options），确认后 `setParam`。
- 提供「参数对照」抽屉：逐行显示 `中文 / EDSDK 0xXXXX / PTP 0xD1XX /
  当前值 / 可写`，供与报告 02 §2 逐条核对。
- 退出：`stopLiveView` → `shutdown` → 路由返回；`onBackPress` 拦截。
- 连接失败/降级：页面显示原因（不是空白），预览仍可尝试。

### 7.2 `pages/CanonImageTransferPage.ets`

- 复制松下 LAB 图传页布局：顶栏 + 状态卡 + **存储卡切换卡** + 图库网格 +
  底部「全选 / 下载」+ 下载进度遮罩 + 预览遮罩。
- **SD 卡切换**：按钮数量 = 相机上报卷数（含空卡）；空卡置灰但显示；
  切卡先清空列表进加载态，再枚举；当前卡高亮；单卡时仍显示一个按钮。
- 条目：3:2 封面、缩略图懒加载、勾选角标、文件名、视频/RAW 徽标；
  不做倒序选项（相机顺序）。
- 下载：显示 当前/总数 + 百分比 + 取消；完成后可在相册查看。
- 退出清理：`dispose()`；下载中返回先取消。

### 7.3 `pages/CanonFirmwarePage.ets`

- 4 步式（下载 → 连接 → 传输 → 相机确认）+ 注意事项（报告 04 §1）。
- 版本信息卡：当前 / 最新 / 大小 / 机型；有更新才显示「下载」。
- 下载进度、校验结果、传输进度、错误码中文文案（报告 04 §6.4）。
- 未连接相机：显示「先连接相机」并允许返回。

## 8. 识别集成（主代理负责，子代理不要改）

`CameraPage.ets` 追加：

1. `startCanonBleDiscovery()`：与富士同位置启动；`CanonBleService.startScan`，
   命中后构造 `LumixBleCameraCandidate`（brand `'Canon'`，`btAddress` = 相机
   UUID，`imageKey = canon_<slug>`，`model` = 清理后的 BLE 名/机型表名），
   走既有 `cameraCards.observeBle` + `maybeShowNewCameraCard`。
2. 卡片按钮：品牌 `Canon` 时显示「图片传输」「相机控制」「WIFI 连接」
   「固件更新」；无「LUT 传输」。
3. 入口：`openCanonEntry('image'|'control'|'wifi')` —— BLE 连接 + 注册（首次）
   + 读凭据 + WAP START + 等 TLV → `LumixCameraService.connectToCameraWifi`
   → 记录 `cameraHost = TLV IP` → push 对应页面。
4. `openCanonFirmware()` → push 固件页。
5. 图片键：`cameraImageKeyForName` 增加 Canon 分支；`brandForImageKey` 增加
   `canon_` 前缀 → `'Canon'`。
6. `CameraPage` 的相机卡片素材渲染增加 `CanonModels.isCanonImageKey` 分支，
   `Image($rawfile(CanonModels.rawfileForImageKey(key)))`。

## 9. 构建与验收

- 构建：`devecocli build --modules entry`（工作目录为项目根）。
- 每个子代理交付前自查：`grep` 自己的文件无 `any`、无 `TODO` 占位、
  所有异常路径有日志；接口签名与本文档一致。
- 主代理在全部子代理完成后：
  1. 编译通过；
  2. 逐条对照报告核验（BLE UUID/帧、参数表、快门 5 参、卷/目录/缩略图、
     固件 4 步与 `.FIR` 头）；
  3. 确认未改动松下/尼康/索尼/富士文件（`git diff --stat` 只含 Canon 文件
     + CameraPage/CameraSessionStore/main_pages）。

## 10. 实现期修订（与 §1~§7 冲突时以本节为准）

写实现时逐条回对了 APK，以下 5 处与报告/本文档早期口径不同，代码按**新口径**实现，
核实表 `canon-route-verification.md` 的 B 组有对应记录：

1. **注册帧不是无条件发的**：只有相机 UUID 非全 0 时才写 `00010006 = 01 + 昵称`；
   全 0 时只读 `0001000b` 能力位图，**不会回 `02`**。因此 `register()` 在 3 次写入都
   没收到 `02` 时返回 `false`（不抛异常），后续凭据/WAP 照常。
2. **WAP TLV 解析无条件跳过前 2 字节**（`C0235b.java:363`），`0x30` WTIME 官方只读
   **1 字节**并按 `%d00` 解释（≈100 ms 计数），不是 4 字节。实现带头/无头双解析，
   1B/4B 都接受。
3. **WAP READY 位判据自相矛盾**（`C.a()` 要 `0x100000`，TLV 只置 `0x10000`，永远凑不齐）：
   一律以 `00020003` 的 START_ACCEPTED + `00020002` 的 TLV IP 判成功，不看位图。
4. **`04 09 00 00 00` 的前置条件**是 `00020001` bit4 **且** `00020006` 列表含该类型；
   不满足时退回 `01`（实现里 `startWap(9, …)` 会自动判断）。
5. **绑定时机**：官方在服务发现回调里判 `bondState==10` 才 `createBond()`，等
   `BOND_STATE_CHANGED(12)` 再继续；`bondState==11` 不重复绑定。实现把 bond 放进
   `register()`，`2900099` 视为「已绑定」。

另外两条**未取证**、实现时已显式降级的点：

- `0x915A`（SetLiveAfFrame）的数据布局报告只写「sends data」，按 4×u32 矩形发送，
  相机拒绝则退化为 `DoAf`；
- PTP 没有录像指令（录像只在 BLE 遥控服务 `00030030`），`toggleMovie()` 明确返回
  `false` 并提示用户用机身按键。
