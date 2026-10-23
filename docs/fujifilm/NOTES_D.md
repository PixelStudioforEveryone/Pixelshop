# NOTES_D · FUJIFILM 固件更新（角色 D）

> 实现者：角色 D（固件线）。
> 交付文件：`services/FujifilmFirmwareService.ets`、`pages/FujifilmFirmwarePage.ets`、本文件。
> 唯一事实来源：`Fujifilm\apk\reports\04_固件更新协议.md`（下称 **04**）、`01_首次配对_蓝牙配对与WiFi凭据.md`（**01**）、
> `reports\data\firmware_camera_fw_info.json`（30 条实测）、`firmware_download_url_list.tsv`、`firmware_http_headers.txt`、
> `firmware_firmware_state_machine.txt`、`firmware_ble_ptp_constants.md`。
> 证据缩写：`J:` = `jadx_src/sources/…`，`S:` = smali，`N:` = native vaddr，`D:` = 本目录代码。

---

## 1. 实现边界（做了什么 / 没做什么）

| 项 | 状态 | 依据 |
|---|---|---|
| 云端清单 `GET https://privacy.xapp.net/camera_fw/camera_fw_info.json`（无鉴权/无参数） | 已实现 | 04 §0.1、S01–S02 |
| 机型匹配（`ProductName` 归一化） | 已实现 | 04 §2.1、S04 |
| 相机当前版本：BLE `0x2A26` | 已实现（调 A 的 `readFirmwareVersion/readIdentity`） | 01 §8、04 §5.4.1、S06 |
| 相机当前版本：PTP `0xD22F`（相机内固件文件名） | 已实现（PTP 已连时才读） | 04 §0.2 路径③、§5.5 |
| 下载 `.DAT` + 进度 + `FileSize`/`Sha256` 校验 | 已实现 | 04 S17–S21 |
| BLE 92 B 请求（`B1307521`，type 5/6） | 已实现载荷构造；发送走注入端口 | 04 §5.4.3、S23 |
| `SetFunctionMode(0x13)` → 版本协商 → `FmSendObjectInfo` → 1 MiB 分块 → 事件 49/50 | 已实现 | 04 S26–S36 |
| 断电 / 回滚 / 自动重试 | **不实现**（明确不做） | 04 §5.12、§7.2 #8/#14 |
| 通道 A（type=6，相机自理）的后续投递 | **不实现**（官方 Java 层也没有） | 04 §4.3、§8-2 |
| 后台自动下载（`AutoFWService`） | **不实现**（报告证明无前台通知、与本线无关） | 04 §4.4 |

页面只做三件事：展示版本/说明、确认后调用服务、用模态进度锁住界面。**所有协议常量取自
`FujifilmProtocol.ets`**；报告里有而常量缺失的 3 个值集中在 `FujifilmFirmwareCode`（见 §6）。

---

## 2. 检查更新链路

```
页面 aboutToAppear
  └ FujifilmFirmwareService.check(context, modelHint)
      ① BLE 身份：FujifilmBleService.readIdentity() → {model, firmware}
                 失败再 readFirmwareVersion()（0x2A26，UTF-8 截断到首个 0x00）
      ② PTP 0xD22F：仅当 FujifilmPtpIp.isConnected()，取相机内固件文件名 → 解析出版本
      ③ GET camera_fw_info.json（2 次尝试，15 s connect/read）
      ④ ProductName 归一化匹配（FujifilmModels.normalize + displayNameOf）
      ⑤ compareVersions(云端, 相机) > 0 ⇒ updateAvailable
      ⇒ { supported, currentVersion, latest, updateAvailable, notes, modelName, trace }
```

要点：

- **元数据无鉴权**：`java.net.URL.openStream()`，没有 header / token / 参数（04 §0.1、S01），
  所以这里也不发任何鉴权头；只有下载 `.DAT` 时带官方 UA `13c00fcc 984546f2`（04 §5.10）。
- **只有 8 个字段**：`ProductName / FileName / FWVersion / FileSize / Sha256 / URL / UpdateInfo_EN / UpdateInfo_JA`；
  没有发布日期、没有 region、没有强制升级标记（04 §5.1）。页面因此只显示这 8 个里面的可见项。
- **说明只有 EN/JA**：官方其它语言回退 EN；本实现 `UpdateInfo_EN` 优先，空则回退 `UpdateInfo_JA`（04 §5.1）。
- **机型匹配**：官方是严格 `equals`（04 §2.1）；这里先做 `normalize` 全等（吸收 `GFX 100` / `GFX100` 空格差异），
  再做包含匹配，且**只有唯一命中才采用**——否则 `X-T5` 会命中 `X-T50`。多义时返回"未收录"，不做猜测。
- **清单覆盖 30 款机身**（附录 A），全部为机身；镜头/闪光灯/转接环/增距镜条目为零（`FirmwareType.Lens` 零调用）。

---

## 3. 更新链路

```
① 下载（必须在切相机 WiFi 之前；相机热点无外网，01 §9.6）
   GET <JSON.URL>，requestInStream 边下边写盘边算 SHA-256
   → 校验 received == FileSize → SHA-256 == JSON.Sha256（不等即删）→ 复用/落盘 filesDir/fuji_firmware/<FileName>
② BLE 通知
   buildBleRequest(type, productName, fileName, fileSize, version) → 92 B
   （type：20EA1FAC availability==1 且 相机版本 >= 目标版本 ⇒ 6，否则 5，04 §2.3）
   FujifilmBleService.launch(5 = UpdateFirmware) → waitApReady(60 s)
③ 连相机 WiFi
   readWifiCredentials() → SSID 字面匹配 + WPA2 + showNoInternetDialog:true → 轮询 getLinkedInfo 40 s
④ PTP（FujifilmPtpIp.connect() = 192.168.0.1:55740）
   SetFunctionMode(19) ≤5 次
   GetFunctionVersion(0xDF27) → v；v > 1 ⇒ VersionError（App 太旧，S29）
   SetFunctionVersion(0xDF27, min(v,1)) ≤5 次
   读 0xD22F（相机内固件文件名，仅记录/解析）
⑤ 推流
   FmSendObjectInfo(0x9040, "FUP_FILE.DAT", size)
   首块 1 MiB FmSendPartialObject(0x9042)（S33，不等待事件）
   循环：等事件 49（≤5 s）→ 发下一块 1 MiB；等不到不报错继续等（04 §7.2 #15），整程上限 600 s
        事件 50 到达 → 结束；arg1==1 ⇒ 相机侧取消
   最后一块发完：再等事件 50（≤60 s），等不到 ⇒ 失败码 8194（SDK_ERRCODE_TIMEOUT）
⑥ 收尾
   清事件监听 + FujifilmPtpIp.close()；**不发断电、不回滚**；提示相机自行重启
```

**顺序不可换**：手机连上相机热点后没有外网（01 §9.6 `removeCapability(INTERNET)`），
下载必须在前，否则必然失败。

### 3.1 事件 49/50 时序

```
App                        相机
 |  FmSendObjectInfo(0x9040) |
 |-------------------------->|  声明对象名 + 总长
 |  FmSendPartialObject #0   |
 |-------------------------->|  首块（1 MiB），S33 不等事件
 |          event 49         |
 |<--------------------------|  “要下一块”（native 侧 wait(5000)）
 |  FmSendPartialObject #1   |
 |-------------------------->|
 |          event 49         |
 |<--------------------------|  …… 直到最后一块
 |          event 50         |
 |<--------------------------|  arg1=0 正常 / arg1=1 已取消
 |  Close()                  |  相机自行写入 → 断电重启
```

- 事件队列由 `FujifilmPtpIp.onEvent` 常驻回调写入本地数组，传输循环以 50 ms 步长轮询；
  这样即使事件在发送过程中到达也不会丢。
- 单块等待 5 s（`FujifilmNet.FIRMWARE_CHUNK_WAIT_MS`），整程 600 s
  （`FujifilmNet.FIRMWARE_TOTAL_TIMEOUT_MS`，与 native `WaitFirmUpdate` 600 s 一致）。
- 事件 7（`SDK_EVENTTYPE_CAMERA_DISCONNECT`）在固件模式内即视为异常，循环立即失败。
- 监听器**只注册一次、不注销**：A 的 `FujifilmPtpIp.onEvent` 是**追加式**（`listeners.push`），
  而 `clearEventListeners()` 会把控制页/图传页的监听一起清空，所以收尾只清本地队列。
  代价是固件之外收到的 49/50 也会进队列，但没人消费，不影响其它页面。

---

## 4. BLE 92 字节包布局（`B1307521-…`，Write）

| 偏移 | 长度 | 字段 | 编码 | 证据 |
|---|---|---|---|---|
| 0 | 2 | `type` | **u16 LE**：5=`CameraBodyXapp`（主流程）/ 6=`CameraBodyMediafile`（新机型） | 04 §5.4.3、§5.8 |
| 2 | 64 | `productName` | UTF-8 原始字节，**无 NUL 填充** | 04 §5.4.3 |
| 66 | 15 | `fileName` | UTF-8（`FWUP0030.DAT` 等服务器文件名） | 同上 |
| 81 | 4 | `fileSize` | **u32 LE** | 同上 |
| 85 | 7 | `version` | ASCII（`4.31`） | 同上 |

合计 `2+64+15+4+7 = 92`（`FujifilmFirmware.BLE_REQUEST_BYTES`）。

规则与坑：

- **`cameraID` 不参与序列化**（04 §3.3）。它只是官方客户端的本地路由键，写进报文会被相机当成
  `productName` 的一部分，直接 `NG_PRODUCT_NAME(80)`。
- **productName 超 64 B 会覆盖 fileName 区，官方无校验**（04 §5.4.3）。本实现先按字段截断
  （`truncateBytes`），宁可截断也不让后面的 `fileName/fileSize/version` 错位。
- `fileSize` 是**字节**（不是分块数）；最大实测 165 795 434（X-HF1），在 u32 内。
- 通道选择（04 §2.3）：
  ```
  availability == 1 且 compareDouble(20EA1FAC.version, JSON.FWVersion*100) != Small
      → type = 6（相机自理，App 只等 049EC406 状态）
  否则（含老机型没有 20EA1FAC）→ type = 5（App 下载 + 推流，主流程）
  ```
  29 B 结构（04 §5.4.2）：`productName[20] | version[4]（ASCII ×100）| totalNo u16LE | seqNo u16LE | availability(1=可用)`。

---

## 5. 版本比较规则

任务要求"按段数值比较，不要字符串比较"，实现见 `compareVersions`：

1. 按 `.` 切段；
2. 每段去非数字字符，转整数；
3. **主版本不做尾 0 处理**（`10.0` ≠ `1.0`），**小数段去掉尾部 0**（`4.30 ≡ 4.3`、`4.10 ≡ 4.1`、`2.50 ≡ 2.5`）；
4. 从高段往低段逐段比，缺段按 0。

| 云端 | 相机 | 本实现 | 官方 BigDecimal（04 §5.9） |
|---|---|---|---|
| 4.31 | 4.30 | 云端更新 ✅ | 云端更新 ✅ |
| 4.31 | 4.31 | 相等 | 相等 |
| 5.12 | 5.1 | 云端更新 ✅ | 云端更新 ✅ |
| 3.11 | 3.9 | 云端更新 ✅ | 云端更新 ✅ |
| 1.12 | 1.2 | **云端更新**（12 > 2） | **不更新**（0.12 < 0.2） |

> 最后一行是**已知偏差**：官方 `Double.parseDouble` + `BigDecimal` 是十进制数值语义，
> 按段比较在"段长不一致"时会反向。云端 30 条里没有这种机型；真遇到也不会写坏相机——
> 相机侧 `NG_FIRMWARE_VERSION(128)` 会拦住降级（04 §5.7.2、§7.2 #13）。
> 若协调者要求与官方 100% 一致，把 `compareVersions` 换成"按最长小数位放大成整数"即可，只改一个函数。

其它约束：
- 版本串生成 `formatVersion` 等价 `String.valueOf(double)`：`4.31→"4.31"`、`2.5→"2.5"`、`2.0→"2.0"`。
  92 B 报文和 UI 都用它，避免出现 `4.3100000000001`。
- `20EA1FAC` 的 version 是 `×100` 的整数字符串（`"431"`），比较前先 `/100`。

---

## 6. 待并入 `FujifilmProtocol.ets` 的常量（ROUTE_SPEC 铁律 3）

`FujifilmProtocol.ets` 只读，缺的 3 个值暂放本文件的 `FujifilmFirmwareCode`，请协调者并入后删除本地类：

| 常量 | 值 | 报告出处 |
|---|---|---|
| `PROP_CURRENT_BODY_FIRMWARE_FILENAME` | `0xD22F`（53807） | 04 §5.5；`J:common/ffir/ControlFFIR.java:44,1157-1167` |
| `TYPE_CAMERA_BODY_XAPP` | `5` | 04 §5.8 `FirmwareType.java:12-19` |
| `TYPE_CAMERA_BODY_MEDIAFILE` | `6` | 同上 |
| `EVENT_CAMERA_DISCONNECT` | `7` | 04 §5.6 `SDK_EVENTTYPE_CAMERA_DISCONNECT` |

> `FujifilmProp` 里没有 `0xD22F`，`FujifilmEvent` 里没有 7，`FujifilmFirmware` 里没有 FirmwareType。

### 6.1 还缺的 3 个 BLE 特征 UUID（`FujifilmBleIds` 里没有）

| 常量（建议名） | UUID | 用途 | 出处 |
|---|---|---|---|
| `CHAR_FIRMWARE_UPDATE_REQUEST` | `B1307521-7AC5-4199-AAEE-9D094781CE69` | 写 92 B 升级请求 | 04 §5.4.3；`data/firmware_ble_ptp_constants.md` |
| `CHAR_FIRMWARE_UPDATE_FILE_INFO` | `20EA1FAC-19D8-48A8-A80C-535D34300958` | 读 29 B 待升级文件信息 | 04 §5.4.2 |
| `CHAR_FIRMWARE_UPDATE_STATE` | `049EC406-EF75-4205-A390-08FE209C51F0` | 相机回传升级状态（`FirmwareUpdateState`） | 04 §5.7.2 |

D 的代码只用到前两个的动作（载荷构造在 D，读写在 A），第三个只影响"错误码从哪来"；
三者都需要加进 `FujifilmProtocol.ets` 的 `FujifilmBleIds`（D 无权改该文件）。

---

## 7. 错误处理与码表来源

### 7.1 相机侧准入/结果（BLE `049EC406` 回传，04 §5.7.2）

`FirmwareUpdateState`：`0 NG_NO_REASON / 1 OK / 16 NG_BUSY / 32 NG_LENS / 48 NG_ACCESSORY /
64 NG_LOW_BATTERY / 65 NG_LOW_BATTERY_LX44 / 80 NG_PRODUCT_NAME / 96 NG_FIRMWARE_FILE_NAME /
112 NG_FIRMWARE_FILE_SIZE / 128 NG_FIRMWARE_VERSION / 256 NG_USER_CANCEL`
（`J:model/fwupdate/FirmwareUpdateState.java:13-24`，UI 映射在 `BTCameraModel.java:5332-5367`）。

本实现把整张表落成 `describeCameraState()`，页面在拿得到码时直接显示中文解释。
**注意**：A 的 `FujifilmBleService` 契约暂未暴露 `049EC406` 通知，所以这个码目前只在
注入端口返回或后续接线后才用得上；拿不到时失败原因落在 PTP 响应码/SDK 错误码上。

### 7.2 SDK 错误码（04 §5.7.1，`ControlFFIR.java:66-82`）

`0 NOERR / 1 CANCEL / -1 ERROR / -2 ERROR_OPEN_SOCKET / 4102 BUSY / 8193 COMMUNICATION /
8194 TIMEOUT / 12289 SYSTEMERROR / 12290 STORE_FULL / 12291 PROTECT_CARD /
12293 STORE_NOT_AVAILABLE / 36865 INTERNAL`

### 7.3 PTP 响应码（`FujifilmResponse`）

`0x2001 OK / 0x2002 GENERAL_ERROR / 0x2003 SESSION_NOT_OPEN / 0x2005 OPERATION_NOT_SUPPORTED /
0x2006 PARAMETER_NOT_SUPPORTED / 0x2019 DEVICE_BUSY / 0x201C INVALID_DEVICE_PROP_VALUE /
0x201F TRANSACTION_CANCELLED`。

重试判据只有"忙"两类：`0x2019` 与 `4102`（`SDK_ERRCODE_BUSY`），其余直接失败——
官方 `SetFunctionMode` 也只对 4102 重试（04 §5.10）。

### 7.4 失败后的行为

- 下载失败/校验不过：删本地文件，页面显示"下载失败（或校验不通过）"。
- `FmSendObjectInfo` 非 0x2001：直接失败，带响应码。
- 推流中失败：关会话，页面显示失败 + 码解释；**没有回滚、没有自动重试**（04 §5.12 明确不存在）。
- 取消：`cancel()` 置标记，循环在检查点退出；提示"相机侧不会回滚已写入的数据"。
- 断电：**不发**。native 升级末尾会碰 `0xD17B` / `XSDK_PowerOFF(0x1023)`，本实现在收尾只打一行日志
  `收尾：不发送断电/重启命令（0xD17B / 0x1023 仅记录）`。

---

## 8. 与角色 A 的接口依赖

按 ROUTE_SPEC §2 契约调用（未改动 A 的任何文件）：

| 调用 | 用途 |
|---|---|
| `FujifilmBleService.readIdentity()` / `readFirmwareVersion()` | 机型 + 当前版本（0x2A26） |
| `FujifilmBleService.launch(5)` / `waitApReady(60000)` | 拉起相机 AP（01 §9.2：`UpdateFirmware(5)` 也被"相机设置"复用） |
| `FujifilmBleService.readWifiCredentials()` | SSID / 密码（01 §8：`BF6DC9CF` / `E809256A`） |
| `FujifilmPtpIp.connect/close/isConnected/opDataIn/opDataOut/onEvent/clearEventListeners` | PTP-IP 会话、属性读写、事件通道 |

> A 的实现落地后已核对：`opDataIn(opcode, params?, timeoutMs?)`、`opDataOut(opcode, params, data, timeoutMs?)`
> 与本文件的调用方式一致；`onEvent` 是**追加式监听**（不覆盖别人的监听），
> 所以本文件只注册一次、不调用 `clearEventListeners()`。

A 的契约里**没有**两个固件专用特征，因此本文件留了注入点 `FujifilmFirmwareBlePort`：

```ts
export interface FujifilmFirmwareBlePort {
  writeRequest(payload: Uint8Array): Promise<boolean>;      // B1307521 写 92 B
  readFileInformation(): Promise<Uint8Array | null>;        // 20EA1FAC 读 29 B
}
FujifilmFirmwareService.setBlePort(port);                   // A 在 BLE 会话就绪后注入
```

不注入时的降级：`type` 恒为 5（老机型主流程），不写 92 B 请求，只靠 `launch(5) + waitApReady`
拉起 AP；trace 里会明确写 `BLE 92B 请求未发送`。相机若因此拒绝，会在 `SetFunctionMode` /
`FmSendObjectInfo` 上回明确错误码，不会静默写坏相机。

**建议**（给协调者）：让 A 在 `FujifilmBleService` 上补两个方法（内部已有私有 `writeValue/readValue`，
只需各加一个 public 包装），再在启动/连接完成后把端口注进来：

```ts
// FujifilmProtocol.ets（FujifilmBleIds，追加常量）
static readonly CHAR_FIRMWARE_UPDATE_REQUEST: string = 'B1307521-7AC5-4199-AAEE-9D094781CE69';
static readonly CHAR_FIRMWARE_UPDATE_FILE_INFO: string = '20EA1FAC-19D8-48A8-A80C-535D34300958';
static readonly CHAR_FIRMWARE_UPDATE_STATE: string = '049EC406-EF75-4205-A390-08FE209C51F0';

// FujifilmBleService.ets（public 包装，私有方法已有）
static async writeFirmwareRequest(data: Uint8Array): Promise<boolean> {
  return FujifilmBleService.writeValue(FujifilmBleIds.CHAR_FIRMWARE_UPDATE_REQUEST, '固件升级请求(92B)', data);
}
static async readFirmwareFileInformation(): Promise<Uint8Array | null> {
  try {
    return await FujifilmBleService.readValue(
      FujifilmBleIds.CHAR_FIRMWARE_UPDATE_FILE_INFO, '待升级文件信息(29B)', false);
  } catch (_error) { return null; }
}
```

然后在页面进入前（或 A 的连接回调里）一次性接线，业务代码不用动：

```ts
FujifilmFirmwareService.setBlePort({
  writeRequest: (payload: Uint8Array): Promise<boolean> =>
    FujifilmBleService.writeFirmwareRequest(payload),
  readFileInformation: (): Promise<Uint8Array | null> =>
    FujifilmBleService.readFirmwareFileInformation(),
});
```

> D 的载荷构造（`buildBleRequest` / `parseFwFileInformation`）不依赖这两个 UUID，
> 所以常量缺失只影响"能不能真的写出去"，不影响 92 B 布局本身的正确性。

---

## 9. 仍未知项（静态分析无法闭合）

| # | 未知 | 现状 | 影响 / 闭合手段 |
|---|---|---|---|
| 1 | `SetFunctionMode` / `Get|SetFunctionVersion` 对应的**真实 PTP 操作码** | 02 §8 明确标未知（`0x4078/0x4130/0x4131` 只是 libFFIR 内部 dispatch 索引） | 本实现按 `SetDevicePropValue(0x5002)` / `Get|SetDevicePropValue(0xDF27)` 落地，集中在 3 个函数里；抓 55740 报文即可校正 |
| 2 | `FmSendObjectInfo` 的 **data phase 编码** | 报告只给 Java 签名 `(hCamera, internalName, dataSize)` | 现按 PTP 标准串（1 B 字符数 + UTF-16LE + NUL），参数传 `[size]`；证伪只改 `buildObjectInfo` + 一处调用 |
| 3 | `FmSendPartialObject` 的**参数语义**（offset/length 还是只 length） | 报告只有 `(hCamera, byte[], dataSize)` | 现传 `[offset, length]` + 数据；抓包校正只改 `sendChunk` |
| 4 | 通道 A（type=6）的**文件投递过程** | 04 §8-2：Java 只发请求，没有投递代码 | 本实现只发 type=6 请求并等状态，不做投递（与官方一致） |
| 5 | 相机是否**二次校验 SHA-256** | 04 §8-7 未知 | App 侧照官方只校验本地文件；相机侧行为需真机篡改实验（高风险） |
| 6 | **CDN 地域校验** | 04 §8-6 未知；4 个 region 常量在 prod 指向同一 URL | 未做地域逻辑；CloudFront 条目（GFX100 II）按直链下载 |
| 7 | `0xD22F` 返回串的**具体编码** | 报告未写死（native 是 `char[]`） | 实现里三种解码顺序兜底（PTP 串 → UTF-8 → 裸 UTF-16LE） |
| 8 | 断电/重启的**确切时间点** | 04 §8-4/8-5 | App 只显示"相机正在写入"，不探测、不催促 |
| 9 | 相机是否允许**同版本重刷** | 04 §8-12 | 本实现按"云端 > 相机"才提示；同版本不提供入口 |
| 10 | BLE 92 B 的 **`fileSize` 是否必须等于真实字节**（通道 A 里相机自取文件） | 报告未验证 | 直接下发 JSON.FileSize，与官方一致 |
| 11 | `049EC406` 升级状态通知的**取值语义**（除 FirmwareUpdateState 外是否还有进度值） | 报告只给准入枚举 | 页面在拿不到进度时显示不确定进度（percent=-1） |
| 12 | `0x9040` 的**响应时机**：相机是立刻回 0x2001，还是等收完数据才回 | 未知 | `FujifilmPtpIp` 是**同步事务**（发完等 Operation_Response），所以 `FmSendObjectInfo` 的 600 s 超时既是上限也是风险点：若相机延后回应，会卡在这一步。抓包确认后可改成"先发 0x9040 再发首块"的非阻塞序列 |

---

## 10. 静态自检记录

- `FujifilmFirmwareService.ets` / `FujifilmFirmwarePage.ets` 写完做了人工静态检查：
  import 路径、接口字段、无 `any`、显式类型、`Uint8Array` 读写统一走 `FujifilmBytes`。
- **未跑 hvigor 全量构建**（ROUTE_SPEC §5：协调者统一构建）。
- 静态自检方式：把 `.ets` 复制成 `.ts` 用 Node 22 的 TypeScript 解析（`node --experimental-strip-types`）
  验证语法（服务文件通过；页面因 ArkUI DSL 无法用 TS 解析，改为与 `NikonCloudDetailPage` 逐项对照）。
- A 的 `FujifilmProtocol.ets` / `FujifilmPtpIp.ets` / `FujifilmBleService.ets` / `FujifilmModels.ets`
  落地后已逐项核对：常量名、`opDataIn/opDataOut` 签名、`FujifilmIdentity` 字段
  （`serial/model/yNumber/mac/firmware/red`）、`FujifilmWifiCredential`（`ssid/passphrase`）全部对得上。
- ⚠️ **仍缺的两块**（都在 A 名下，D 不能改）：`B1307521` 写与 `20EA1FAC` 读。
  A 现在只有私有 `writeValue/readValue`，且 `FujifilmProtocol.ets` 里没有这三个固件特征 UUID。
  按 §8 的补丁接上即可；未接时按 §8 的降级路径运行（trace 会写明 `BLE 92B 请求未发送`）。
- 页面路由 `pages/FujifilmFirmwarePage` 由角色 A 注册到 `main_pages.json`（D 不改该文件）。
- 日志前缀统一 `[FUJI]`，`AppLogStore.add('[FUJI] …')`；下载/推流进度不逐块写日志，只写阶段与结果。
  `AppLogPolicy.sanitize` 会把 `ssid=` / `passphrase` 一类字段脱敏，所以 trace 里看不到明文凭据。

---

## 11. 关键实现位置（自查用）

| 职责 | 位置（`FujifilmFirmwareService.ets`） |
|---|---|
| 检查更新 | `check()` |
| 清单拉取/解析/匹配 | `fetchCatalog()` / `parseCatalog()` / `matchEntry()` |
| 版本比较 | `compareVersions()` / `versionSegments()` / `formatVersion()` |
| 92 B 载荷 | `buildBleRequest()` |
| 29 B 文件信息 / 通道判定 | `parseFwFileInformation()` / `transferTypeFor()` |
| 下载 + 校验 | `downloadPackage()` |
| 相机 WiFi | `joinCameraWifi()` / `linkedSsid()` |
| 模式协商 | `enterFirmwareMode()` / `setFunctionMode()` / `getFunctionVersion()` / `setFunctionVersion()` |
| 推流 | `transferFile()` / `sendChunk()` / `waitEvent()` |
| 0xD22F | `readPtpFirmwareFilename()` / `decodePtpString()` |
| 收尾 | `finishTransfer()` |
| 码表 | `describeCameraState()` / `describeErrorCode()` |
