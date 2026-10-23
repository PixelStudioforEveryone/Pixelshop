# FUJIFILM 路线 · 实施契约（VIVID）

> 本文件是「富士路线」四位实现者共同的接口与边界约定。**先读本文件，再读逆向报告，再动手。**
> 逆向报告（唯一协议事实来源）：
> `C:\Users\HQ\Desktop\picture\documents\Fujifilm\apk\reports\00_协议总览.md` … `05_证据索引.md`
> 结构化码表：同目录 `data\*.csv`、`data\control_property_codes.csv`、`data\ptp_opcode_names.csv`
> 已固化的常量：`entry/src/main/ets/services/FujifilmProtocol.ets`（**只读，不许改；缺常量找协调者加**）
> 已生成的机型素材：`entry/src/main/resources/rawfile/fujifilm/*.png`（85 款机身，透明背景）
> 素材清单：`entry/src/main/ets/services/FujifilmModelImages.ets`（自动生成，勿手改）

## 0. 铁律

1. **只新增、不改旧**：松下 LAB / SYNC / Image App、尼康、索尼 的任何文件、分支、常量、行为都不得改变。
   禁止修改：`LumixCameraService.ets`、`LumixControlService.ets`、`LumixSyncControlService.ets`、
   `LumixSyncImageTransfer.ets`、`LumixImportPrototype.ets`、`LumixFirmwareService.ets`、`LumixLutService.ets`、
   `Nikon*.ets`、`Sony*.ets`、`pages/CameraControlPage.ets`、`pages/ImageTransferPage.ets`、
   `pages/Lumix*Page.ets`、`pages/Nikon*Page.ets`、`pages/Sony*Page.ets`。
2. **共享文件只有 Agent A 能动**：`pages/home/CameraPage.ets`、`services/CameraSessionStore.ets`、
   `services/CameraCardRegistry.ets`、`services/CameraControlBrand.ets`、`src/main/resources/base/profile/main_pages.json`。
3. **协议常量只能来自 `FujifilmProtocol.ets`**；若报告里有而常量缺失，先在 `docs/fujifilm/NOTES_*.md` 记录，
   再找协调者追加，**不许在业务代码里另写字面量**。
4. **拿不准就逆向**：用 `Fujifilm\apk\jadx_src`（Java）、`apk\apktool_out\smali*`（smali）、`apk\tmp\native`（符号/vaddr）
   找证据，结论写进本目录的 `NOTES_<角色>.md`，注明 `J:/S:/N:` 位置。
5. **不改别人的文件**：只写自己名下的文件；需要别人配合，写进 NOTES 或回报给协调者。

## 1. 文件所有权

| 角色 | 拥有（可新建/修改） |
|---|---|
| **A 识别路线** | `services/FujifilmBleService.ets`、`services/FujifilmPtpIp.ets`、`services/FujifilmModels.ets`（机型识别/命名）、`pages/FujifilmPairingPage.ets`（若需要）、共享文件（见铁律 2） |
| **B 控制页** | `services/FujifilmControlService.ets`、`pages/FujifilmCameraControlPage.ets`、`components/FujifilmCameraControl*`（如需） |
| **C 图传页** | `services/FujifilmImportService.ets`、`pages/FujifilmImageTransferPage.ets`、`components/FujifilmGallery*`（如需） |
| **D 固件** | `services/FujifilmFirmwareService.ets`、`pages/FujifilmFirmwarePage.ets`、`components/FujifilmFirmwareProgress.ets`（如需） |

## 2. 公共底座（A 实现，B/C/D 消费）

### 2.1 `services/FujifilmPtpIp.ets` —— PTP-IP 传输（三个端口）

```ts
export interface FujifilmEventFrame { code: number; params: number[]; }
export interface FujifilmReply {
  code: number;            // PTP 响应码，0x2001 = OK
  params: number[];        // 响应参数
  data: Uint8Array;        // 数据阶段字节（无数据时为 0 长）
}

export class FujifilmPtpIp {
  /** 连 55740 → Init_Command_Request/Ack → OpenSession(1)。幂等，可重复调用。 */
  static async connect(): Promise<void>;
  static isConnected(): boolean;
  static async close(): Promise<void>;

  /** 无数据阶段 / 数据入（相机→手机）。超时默认 10000ms。 */
  static async op(opcode: number, params?: number[], timeoutMs?: number): Promise<FujifilmReply>;
  static async opDataIn(opcode: number, params?: number[], timeoutMs?: number): Promise<FujifilmReply>;
  /** 数据出（手机→相机），如固件 0x9040/0x9042。 */
  static async opDataOut(opcode: number, params: number[], data: Uint8Array,
    timeoutMs?: number): Promise<FujifilmReply>;

  /** 事件通道 55742：后台常驻监听，回调可能来自任意时刻。 */
  static onEvent(listener: (frame: FujifilmEventFrame) => void): void;
  static clearEventListeners(): void;

  /** 取景通道 55741：open 后 readFrame 阻塞读 204800 字节。 */
  static async openLiveView(): Promise<void>;
  static async readLiveViewFrame(timeoutMs?: number): Promise<Uint8Array | null>;
  static closeLiveView(): void;
}
```

约定：
- `connect()` 失败抛 `Error`，由调用方决定重试；`OP_OPEN_SESSION` 返回 `0x201E` 视为已开、按成功处理。
- 所有事务串行化（内部队列），并发调用安全。
- 任何通道出错必须把会话置为“不可用”，下一次 `connect()` 重新建立全链路。

### 2.2 `services/FujifilmBleService.ets` —— 蓝牙识别/配对/凭据/拉起

```ts
export interface FujifilmBleCamera {
  deviceId: string;      // 系统 deviceId
  name: string;          // 蓝牙名（前 4 字符 = 短序列号）
  serial: string;        // 短序列号
  model: string;         // 机型名（用于素材/日志）
  red: boolean;          // mf[0]==1 新协议
  rssi: number;
}

export class FujifilmBleService {
  /** 扫描（ScanFilter=7 个服务 UUID，其中 AF854C2E 常驻），命中即回调。 */
  static async startScan(onFound: (camera: FujifilmBleCamera) => void): Promise<void>;
  static stopScan(): void;

  /** GATT 连接 + 订阅 AP_STATE/身份特征。 */
  static async connect(deviceId: string): Promise<boolean>;
  static isConnected(): boolean;

  /** 配对：回写 pairing key（老协议 mf[1..5]）；RED 另写 0x20000000 与 80 01 01。 */
  static async pair(camera: FujifilmBleCamera): Promise<boolean>;

  /** 身份：序列号/机型/MAC/Y 号；固件版本（0x2A26）。 */
  static async readIdentity(): Promise<FujifilmIdentity>;
  static async readFirmwareVersion(): Promise<string>;

  /** WiFi 凭据：SSID(BF6DC9CF) / 密码(E809256A)，UTF-8 读到 0x00。 */
  static async readWifiCredentials(): Promise<FujifilmWifiCredential>;

  /** 功能启动：写 600655E6 = 03/04/05（u16 LE）。 */
  static async launch(kind: number): Promise<boolean>;
  /** 等 AP_STATE=0x8001；超时返回 false。 */
  static async waitApReady(timeoutMs: number): Promise<boolean>;
  static lastApState(): number;

  static async disconnect(): Promise<void>;
}

export interface FujifilmIdentity {
  serial: string; model: string; yNumber: string; mac: string; firmware: string; red: boolean;
}
export interface FujifilmWifiCredential { ssid: string; passphrase: string; }
```

### 2.3 会话字段约定（B/C/D 读取）

`CameraSessionStore.instance` 已有字段，富士线复用，不新增：
`cameraBrand='FUJIFILM'`、`cameraModel`、`cameraImageKey='fujifilm_<slug>'`、`cameraWifiSsid`、
`cameraState`（2=已连接）、`cameraBleStatus`、`cameraWifiStatus`、`cameraSessionStatus`。

## 3. CameraPage 接入（只由 A 改）

1. 品牌常量：字符串 `'FUJIFILM'`。
2. 扫描：`startCameraBleDiscovery()` 内追加富士扫描（与松下扫描并列，互不影响），
   命中后 `cameraCards.observeBle(...)` 入卡，卡片品牌 `FUJIFILM`，机型图用
   `FujifilmModelImages.rawfileOf(model)` + `Image($rawfile(path))`。
3. 卡片按钮行（与松下 LAB 同布局，**去掉「LUT 传输」**）：
   `[图片传输] [相机控制]` + 第二行 `[WIFI 连接] [固件更新]`。
4. 入口行为：
   - 图片传输 → `launch(3)` → `waitApReady` → 连相机 WiFi → `pushUrl('pages/FujifilmImageTransferPage')`
   - 相机控制 → `launch(4)` → 同上 → `pushUrl('pages/FujifilmCameraControlPage')`
   - 固件更新 → `pushUrl('pages/FujifilmFirmwarePage')`
5. `main_pages.json` 注册三个页面。
6. 富士机型的 `imageKey` 一律 `fujifilm_<slug>`；`brandForImageKey` 前缀判定加 `fujifilm_`。

## 4. 验收标准（每位实现者自检）

- 无 ArkTS 类型错误：不用 `any`，接口字段显式类型，`Uint8Array` 读写走 `FujifilmBytes`。
- 所有网络/蓝牙调用都有超时与异常捕获，页面不因相机不在线而崩溃。
- 关键步骤写 `AppLogStore.add('[FUJI] ...')`（前缀 `[FUJI]`，便于筛选）。
- 每条协议行为在代码注释里标出来源（如 `// 01 §8.2 密码读失败即断开`）。
- 页面离开时释放资源（socket/scan/定时器），再次进入可恢复。
- 不改铁律 1 列出的任何文件（用 `git status` 自查）。

## 5. 构建/静态自检

协调者统一构建，实现者不要跑全量 hvigor（耗时长且互相踩缓存）。
实现者自检方式：
```powershell
cd C:\Users\HQ\DevEcoStudioProjects\VIVID
git status --short            # 只应出现自己名下的文件
```
类型/语法自查：检查 import 路径存在、接口字段与调用一致、无未定义符号。
