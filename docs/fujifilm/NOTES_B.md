# NOTES_B — 富士相机控制页实现说明（角色 B）

本文件记录 `FujifilmControlService.ets` 与 `FujifilmCameraControlPage.ets` 的
协议依据、实现取舍、覆盖范围与仍未确定的事项。所有 `N:` 证据都指
`tmp/native/` 下对应 so 的**文件内虚拟地址**（`libFFIR.so` / `libFTLPTPIP.so`）。

> 结论先行：
> - `SetFunctionMode` / `SetCameraFunctionMode` / `SetFunctionVersion` 全部是
>   **标准 `0x1016 SetDevicePropValue`**，不是 `0x9060 SetCameraEvent`；
> - `GetFunctionVersion` 是 **`0x1015 GetDevicePropValue`**；
> - `0x902B` 的线上格式是「`u32 count` + 每条 8 字节 TLV 头 + payload」，
>   8 字节头由 `FTL_PTP_GetDevicePropDescAll` 的反汇编直接确认；
> - 事件 11/40 在角色 A 当前暴露的原始 PTP 事件里没有对应项，服务做了
>   「原始事件映射 + 超时降级 + 写后单点回读」，没有假装收到。

---

## 1. 三个未知映射的逆向结论

### 1.1 `SetFunctionMode(mode)`

证据链：

1. `SDK_SetFunctionMode` @ `N:libFFIR.so 0x5ed28`
   构造 `CCameraParamForSetInt`，立即数：
   - `cmd = 0x4078`（SDK 内部命令分派索引，不上网）
   - `prop = 0xDF01`
   - `dataType = 4`（PTP `UINT16`）
   值从 `[sp,#8]` 取，随后调 `CSDKAPI_SetParamFunc`。
2. `CCameraParamForSetInt::SetParamFunc` @ `N:0x76b48`
   → `CParamForSetFunc::SetParamFunc` @ `N:0x86e84`
   → `CPTPCommand::SetDeviceProperty` @ `N:0x83ff8`。
3. `CPTPCommand::SetDeviceProperty` 组装的是 **PTP `0x1016`**（`SetDevicePropValue`）。

**结论**：`SetFunctionMode(mode)` = `0x1016`，参数 `[0xDF01]`，数据 2 字节
LE（`mode & 0xFFFF`）。

### 1.2 `SetCameraFunctionMode(mode)`

`SDK_SetCameraFunctionMode` @ `N:0x6155c`：`cmd = 0x4210`、`prop = 0xDF00`、
`dataType = 4`。走同一条 `CParamForSetFunc` → `0x1016`。

**结论**：`0x1016`，参数 `[0xDF00]`，数据 2 字节 LE。

### 1.3 `SetFunctionVersion(prop, version)` / `GetFunctionVersion(prop)`

- `SDK_SetFunctionVersion` @ `N:0x5ee14`：`cmd = 0x4130`、`prop = 入参`、
  `dataType = 6`（`UINT32`）→ `0x1016`，数据 4 字节 LE。
- `SDK_GetFunctionVersion` @ `N:0x5eee8`：`cmd = 0x4131`、`prop = 入参`、
  `dataType = 6`；用 `CCameraParamForGetInt` + `API_GetParamFunc` → `0x1015`，
  数据入 4 字节。

**结论**：

| 逻辑调用 | 线上操作 | 参数 | 数据 |
|---|---|---|---|
| `SetFunctionMode(mode)` | `0x1016` | `[0xDF01]` | `u16 mode` |
| `SetCameraFunctionMode(mode)` | `0x1016` | `[0xDF00]` | `u16 mode` |
| `SetFunctionVersion(prop, v)` | `0x1016` | `[prop]` | `u32 v` |
| `GetFunctionVersion(prop)` | `0x1015` | `[prop]` | 4 字节 LE |

`0x9060 SetCameraEvent` **不参与模式协商**。它只被 `ControlFFIR.setCameraEvent`
用于事件码 `0x1001`（导入图片计数）和 `0x1002`（固件序号），见
`tmp/findings/camera_control.md §8.4`。

### 1.4 其余动作

| 动作 | 操作码 | 参数 | 证据 |
|---|---|---|---|
| `InitiateCapture` | `0x100E` | 无 | 报告 02 §4；39 条码名表 |
| `CancelInitiateCapture` | `0x9030` | 无 | 同上 |
| `InitiateOpenCapture` Phase1 | `0x101C` | 无，30 s | `FTL_PTP_InitiateOpenCapturePhase1` |
| `InitiateOpenCapture` Phase2 | **无 PTP op** | — | Phase2 只建 55741/55742（见 §1.5） |
| `TerminateOpenCapture` | `0x1018` | `[0]` | `FTL_PTP_TerminateOpenCapture` |
| `InitiateMovieCapture` | `0x9020` | 无 | 39 条码名表 |
| `TerminateMovieCapture` | `0x9021` | 无 | 同上 |
| `Postview` | `0x9022` | 无 | `tmp/findings/native_ptp.md` |
| `StartZoom(dir,speed)` | `0x9023` | `[dir,speed]` | 报告 02 §5.5 |
| `StopZoom()` | `0x9024` | 无 | 同上 |
| `StepZoom(dir,speed)` | `0x9025` | `[dir,speed]` | 同上 |
| `LockS1Lock(afArea)` | `0x9026` | `[afArea]` | 同上 |
| `UnlockS1Lock()` | `0x9027` | 无 | 同上 |
| `StepShutterspeed(dir)` | `0x902C` | `[dir]` | 同上 |
| `StepFnumber(dir)` | `0x902D` | `[dir]` | 同上 |
| `StepExposureBias(dir)` | `0x902E` | `[dir]` | 同上 |
| `GetDevicePropDescAll` | `0x902B` | `[0]` | `FTL_PTP_GetDevicePropDescAll` |

`dir`：0=tele，1=wide；`speed`：0=×1，1=×2（`ControlFFIR.java` 的形参名叫
`zoomDirection` 是历史遗留，语义仍是 0/1）。

### 1.5 Phase2 为什么没有 PTP op

`FTL_PTP_GetDevicePropDescAll` 的调用方 `Q` 用的是 `x1=0x902b, x2=1`；而
`Phase1/Phase2` 在 `libFFIR.so` 里是两条独立入口，Phase2 之后没有新的
`ExecPTPOperation` 立即数，只有 `SetOpenSocket` 的 55741/55742 建链。因此
本实现把 Phase2 定义为：

```ts
await FujifilmPtpIp.openLiveView();   // 55741 建链
```

并在 NOTES 里明确：**这不是一条 PTP 指令**，而是取景 socket 的建立。若后续
抓包发现 Phase2 还需要某条 op，只需在 `initiateOpenCapture()` 里补，不影响
页面。

---

## 2. `0x902B` 的线上格式

### 2.1 8 字节 TLV 头（反汇编确认）

`FTL_PTP_GetDevicePropDescAll` @ `N:libFTLPTPIP.so 0x2f478`，循环体
`0x2f5b8` 起：

```asm
LDR  x27, [x8]        ; code + getSet 打包
LDRH w9,  [x8, #4]    ; dataType
LDRH w2,  [x8, #6]    ; payloadSize
ADD  x22, x8, #8      ; payload 起点
...
CMP  w9, #7           ; 字符串类型走 setDevicePropDescStr
BL   setDevicePropDescInt / setDevicePropDescStr
```

所以整体是：

```
u32 count
count × {
  u16 code
  u8  getSet        ; 0=只读，1=可读写
  u8  reserved
  u16 dataType      ; 含 0x10000/0x20000 字符串标志
  u16 payloadSize
  u8[payloadSize] payload
}
```

`payload` 由 `setDevicePropDescInt` @ `N:0x2e3d4` 解析，字段顺序为
`factory → current → formFlag → range(min,max,step) / enum(n,values[])`；
这与报告 02 §5.2 的 14 个 Java 回调顺序一致。

### 2.2 解析器的保守设计

线上 `getSet` 的精确位置报告没有给出（只在回调里有 `SetGetSet`）。因此
`parsePropDescAll()` 会依次试三种 8 字节头排布：

1. `code u16 | getSet u8 | rsv u8 | type u16 | size u16`
2. `code u16 | type u16 | getSet u16 | size u16`
3. `code u32 | type u16 | size u16`（getSet 缺省）

每种排布都要求：

- `count ∈ 1...512`；
- 每条 `code ∈ 0x5000...0xDFFF`；
- `payloadSize` 不越界；
- 数值 payload **必须正好消费完**（允许 ≤3 字节零填充）。

选「解析出的属性条数最多」的那张表。任何一种排布失败都不会返回半张表；
全部失败时 `loadProps()` 把 `propsReady` 置 false，写
`[FUJI] PROP_PARSE_FAIL ...`，页面把所有参数置灰，但**仍可拍摄**（这是
有意的降级，不是成功）。

### 2.3 `getSet` 全 0 的兜底

如果三种排布都解析成功、但所有 `getSet` 都是 0（说明固件把该字段放在别处），
`loadProps()` 只对参数目录里 `kind != 'read'` 的项放开写权限，并写日志。
真正写失败由 `0x1016` 的响应码兜底，不会崩。

### 2.4 字符串属性

报告里唯一确认的字符串属性是 `0xD2B7`（type `0x10007`）；`0x501D/0x501E/
0x501F` 也是字符串。本实现只对这 4 个码走 `parseStringRecord()`（PTP
长度前缀 + UTF-16LE），其余裸 `type=7` 当 INT64 数值处理，避免把普通
INT64 误当字符串。

---

## 3. 连接编排（报告 02 §4）

`FujifilmControlService.connect()` 的顺序：

| 步 | 调用 | 超时/重试 | 失败处理 |
|---|---|---|---|
| S01 | `FujifilmPtpIp.connect()` | A 的 5 s × ≤6 | 抛错，页面显示 Wi-Fi 重试 |
| S05 | `GetDeviceInfo(0x1001)` 解析 Model/Serial | 8 s | 用 BLE 型号兜底，不阻断 |
| S11 | 等事件 11 | 12 s | **超时降级**：按模式 5 继续 |
| S13 | `SetFunctionMode(20, 0xDF28, ≤3)` | 4102/0x2019 ×5 ×100 ms | 抛错 |
| S14 | `SetCameraFunctionMode(6)` | 同上 | 抛错 |
| S15 | `SetFunctionMode(22, 0xDF2A, ≤4)` | 同上 | 抛错 |
| S20 | `GetDevicePropDescAll(0x902B)` | 20 s，4102 ×5 | 降级，不阻断 |
| S23 | `InitiateOpenCapture` Phase1 `0x101C` | 30 s，4102 ×5 | 抛错 |
| S24 | Phase2 `openLiveView()` | 连接超时 | 抛错 |
| S29 | 再等事件 11 | 4 s | 没有也继续 |
| S30 | `SetFunctionMode(5)` + `GetFunctionVersion(0xDF25)` + `SetFunctionVersion(0xDF24, 131083)` | 10 s | **只降级**，不判死 |

`versionRemote` 固定默认 `131083`（`0x0002000B`，camera.xml 缺省），可在
`FujifilmControlService.versionRemote` 改。

### 3.1 为什么事件 11 可以超时降级

角色 A 的 `FujifilmPtpIp` 目前把 55742 上的**原始 PTP 事件码**直接抛给
`onEvent`（`FujifilmEventFrame.code`），而报告里的 11/30/31/32/40/43 是
FFIR 的 **SDK 回调 eventType**，两者中间隔着一层 `CCameraEvent`。

已确认的原始 → SDK 映射（`N:libFFIR.so 0x6bc24 CCameraEvent::ThreadProc`）：

| 原始 PTP | SDK | 证据 |
|---|---|---|
| `0xC004` | 30 CAPTURE_START | `0x6bd28` 日志 + `0x6bd3c` `MOVZ w1,#0x1e` |
| `0x400D` | 31 CAPTURE_COMPLETE | `0x6bd68` + `0x6bd80` `MOVZ w1,#0x1f` |
| `0xC001` | 32 POSTVIEW_COMPLETE | `0x6bda4` + `0x6bdbc` `MOVZ w1,#0x20` |
| `0xC005` | 43 AF | `0x6bdd4` + `0x6bde8` `MOVZ w1,#0x2b` |
| `0x4008` | 41 DEVICEINFOCHANGED | `0x6be08` + `0x6be1c` `MOVZ w1,#0x29` |

但 `0x6bc24` 的分支里**没有** 11（GET_CAMERA_MODE）和 40（PROPVALUE）；
`CCameraHandleData::ReceivePTPEvent` @ `0x6c7fc` 只有 8 字节（`RET`，空壳）。
也就是说，11/40 很可能来自 `CCameraPropertyList` 的轮询线程或 A 尚未实现的
SDK 层，而不是事件 socket 的原始码。

因此本实现：

- 直接接受 SDK 码 11/30/31/32/40/41/43/44/45/49/50；
- 同时把原始码按上表映射；
- `0x4006`（DevicePropChanged）先看 `params[1]` 是否有值，没有就发一条
  `0x1015 [code]` 单点回读；
- 11 超过 12 s 没来就按默认模式继续，并在 snapshot 的
  `degradedReason` 里写明「未收到相机模式请求」。

**这不是假装成功**：页面顶部会显示降级原因；用户能看到「未收到事件 11」。

### 3.2 事件 40 缺失时的写后回读

`setValue()` 成功后 250 ms 发一次 `0x1015 [code]` 读回；`step()` 成功后
350 ms 读回。这样即使没有 40 事件，参数面板也会在一秒内更新到相机真实值。
读回失败只写日志，不影响写入结果。

---

## 4. 预览 / 遥控的区别（页面）

| | 预览 | 遥控 |
|---|---|---|
| 取景流 | **推**：`startLiveView()` 循环读 55741 | **不推**：`setViewMode('remote')` 会 `stopLiveView()` + `closeLiveView()` |
| 画面 | 全屏 `ImageFit.Contain` | 最后一帧冻结（55% 透明度）+「遥控模式 · 不推流」角标 |
| 参数 | 只读芯片条（EV/快门/光圈/ISO/胶片） | 14 个主参数网格 + 6 个快捷芯片 + 全部 53 项列表 |
| 交互 | 点按画面 AF、底部快门/录像/对焦 | 点参数打开底部面板；步进/枚举写入 |
| 底部 | 录像、快门、对焦 | 变焦 −、快门/录像、变焦 +、拍照/录像切换 |

切回预览时重新 `openLiveView()`，不存在「遥控态还在后台读流」的情况。

### 4.1 取景帧

`FujifilmPtpIp.readLiveViewFrame()` 返回**相机声明的整包**（含 12 字节
PTP-IP 头和帧内 JPEG 前的头），`jpegOfFrame()` = `LE32@12 + 18` 到包尾。
服务再 `image.createImageSource(jpeg).createPixelMap()`；页面替换
`framePm` 时释放上一帧。没有用固定 204800 字节去解码整块缓冲。

---

## 5. 参数表覆盖（53 条）

下表「UI」列：

- **主** = 遥控页 14 个主网格之一；
- **快** = 快捷芯片；
- **全** = 只在「全部参数」列表里；
- **只读** = 目录 `kind=read`，描述符即使说可写也不在 UI 放开
  （`0xD2B7` 的「清零」是 App 特例，未做）。

| 码 | 名称 | UI | 值域/编码来源 |
|---|---|---|---|
| `0x5001` | BatteryLevel | 全/只读 | 0–100 %（CSV） |
| `0x5002` | FunctionMode | 全/只读 | SDK 内部（CSV） |
| `0x5003` | ImageSize | 全/只读 | 描述符 values |
| `0x5004` | CompressionSetting | 主 | 描述符 values（CSV 未给码值，不臆造） |
| `0x5005` | WhiteBalance | 主 | 12 个已确认值（CSV/报告 §5.4.5） |
| `0x5006` | RGBGain | 全/只读 | 结构，描述符 |
| `0x5007` | F-Number | 主 | F×100（CSV/§5.4.2） |
| `0x5008` | FocalLength | 全/只读 | 描述符 |
| `0x5009` | FocusDistance | 全/只读 | 描述符 |
| `0x500A` | FocusMode | 主 | 1/32769/32770（CSV） |
| `0x500B` | ExposureMeteringMode | 全/只读 | 描述符 |
| `0x500C` | FlashMode | 主/快 | 32777/32778（CSV） |
| `0x500D` | ExposureTime | 全/只读 | 传统字段（CSV） |
| `0x500E` | ExposureProgramMode | 主 | 1/2/3/4/6/0x8002–0x8008/0xFFFF8001（CSV） |
| `0x500F` | ExposureIndex | 全/只读 | 描述符 |
| `0x5010` | ExposureBiasCompensation | 主 | 1/1000 EV，±5000，333（CSV/§5.4.3） |
| `0x5011` | DateTime | 全/只读 | 描述符 |
| `0x5012` | CaptureDelay | 主/快 | 0/2/4（CSV） |
| `0x5013` | StillCaptureMode | 全/只读 | 描述符 |
| `0x5014` | Contrast | 全/只读 | 描述符 |
| `0x5015` | Sharpness | 全/只读 | 描述符 |
| `0x5016` | DigitalZoom | 全/只读 | 描述符 |
| `0x5017` | EffectMode | 全/只读 | 描述符 |
| `0x5018` | BurstNumber | 全/只读 | 描述符 |
| `0x5019` | BurstInterval | 全/只读 | 描述符 |
| `0x501A` | TimelapseNumber | 全/只读 | 描述符 |
| `0x501B` | TimelapseInterval | 全/只读 | 描述符 |
| `0x501C` | FocusMeteringMode | 全/只读 | 描述符 |
| `0x501D` | UploadURL | 全/只读 | 字符串 |
| `0x501E` | Artist | 全/只读 | 字符串 |
| `0x501F` | CopyrightInfo | 全/只读 | 字符串 |
| `0xD001` | FilmSimulation | 主/快 | 1–20（CSV/§5.4.6） |
| `0xD018` | CCDMode | 全/只读 | 描述符 |
| `0xD019` | RecModeEnable | 全/只读 | 描述符 |
| `0xD01D` | Macro | 全 | 描述符 values |
| `0xD028` | ExposureColor | 全/只读 | 0/1/2（CSV） |
| `0xD02A` | ISO | 主 | bit31 AUTO / bit30 扩展（CSV/§5.4.4） |
| `0xD02B` | MovieISO | 全 | 同 ISO |
| `0xD170` | ZoomPosition | 全/只读 | 描述符 |
| `0xD17C` | S1Lock | 全/只读 | 位域（CSV/§5.4.7） |
| `0xD209` | S1LockColor | 全/只读 | 0/1（CSV） |
| `0xD21B` | DeviceError | 全/只读 | 0–17（CSV/§8.3） |
| `0xD229` | RemainingSheet | 全/只读 | 描述符 |
| `0xD22A` | RemainingTime | 全/只读 | 秒（CSV） |
| `0xD240` | ShutterSpeedEx | 主 | bit31 分数 / 否则毫秒（CSV/§5.4.1） |
| `0xD241` | PixelSize | 主/快 | L/M/S 代码分组（CSV/§5.4.7） |
| `0xD242` | BatteryMultiSteps | 全/只读 | 描述符 |
| `0xD243` | CurrentShutterType | 全/只读 | 描述符（CSV 只写「枚举」，不编 0/1/2） |
| `0xD245` | AfSelectMode | 主 | 0–7（CSV），名称只标序号 |
| `0xD246` | DriveMode | 主 | 0/1（CSV） |
| `0xD2B7` | MovieTransparentFrameInfo | 全/只读 | 字符串（CSV） |
| `0xD212` | Fpcsh_PropList | 全/只读 | 结构（CSV） |
| `0xD220` | CameraSendRequestObjectHandle | 全/只读 | 整数（CSV） |

共 **53/53** 个属性码进入目录；其中 14 个主网格、6 个快捷芯片、其余在
「全部参数」列表可见。**可用性完全由 `0x902B` 描述符决定**：没上报的项
显示「不可用」并置灰；`getSet=0` 的项可打开面板但写入按钮提示「只读」。

### 5.1 值域缺口（没有编造）

| 项 | 已知 | 缺口 |
|---|---|---|
| `0x5004` 画质 | 描述符 values | CSV 没给 0/1/2 语义，不硬编码 |
| `0xD243` 快门类型 | 描述符 values | CSV 只说「枚举」，删掉了猜测的 0/1/2 标签 |
| `0xD245` AF 区域 | 0–7 范围 | CSV 没给每档名称，只显示「区域 N」 |
| `0xD241` 尺寸 | L/M/S 代码分组 | 具体像素数由描述符 values 给出 |
| `0xD01D` 微距 | 描述符 values | CSV 没给码值 |
| `0x5005` 白平衡 | 12 个确认值 | 报告写「14 项」，表里只列出 12 项；其余 2 项未找到语义，不补 |
| `0xD2B7` 字符串 | PTP 字符串 | 只读展示，未做「清零」写入 |

---

## 6. 与 `FujifilmProtocol.ets` 的冲突（需要协调者处理）

`FujifilmProtocol.ets` 是角色 A 的只读常量文件，但控制路线发现两处**与报告
不符**：

| 常量 | 当前值 | 报告事实 |
|---|---|---|
| `FujifilmProp.FILM_SIMULATION` | `0xD245` | 胶片模拟是 `0xD001`；`0xD245` 是 AF 区域 |
| `FujifilmProp.IMAGE_QUALITY` | `0xD244` | 报告/CSV 没有 `0xD244`；画质是 `0x5004` |
| `FujifilmEvent.CAPTURE_ERROR` | `32` | 32 是 POSTVIEW_COMPLETE |
| `FujifilmEvent.PROP_CHANGED` | `0x4006` | 这是原始 PTP 事件，不是 SDK 40 |

另外 `FujifilmOp` 缺 `0x9020–0x9030` 与 `0x1018/0x101C`，`FujifilmProp` 缺
全部 `0xD0xx/0xDFxx`。

**本文件的处理**：在 `FujifilmControlService.ets` 顶部定义
`FujifilmCtl` 作为临时表，所有码都带注释；没有改 `FujifilmProtocol.ets`。
建议后续由 A/协调者把这些码并入协议文件，然后删掉 `FujifilmCtl`，避免
两套常量长期漂移。

---

## 7. 错误与退出

- 4102（`0x1006`）/ `0x2019`：`busyRetry()` 5 次 × 100 ms；其余响应码
  立即失败。
- `0xD21B` 0–17：`FujifilmParamCatalog.statusText()`；7/11/12/13/14/15/16
  在页面顶部显示红色状态条，但不阻断用户按快门（相机自己会拒绝）。
- 所有写失败只 `toast`，不抛到 UI；`setValue`/`step` 返回 boolean。
- 退出：`UnlockS1Lock(0x9027) → StopZoom(0x9024) → TerminateMovieCapture
  (0x9021) → CancelInitiateCapture(0x9030)` → `stopLiveView` +
  `closeLiveView` → `TerminateOpenCapture(0x1018,[0])` → `FujifilmPtpIp.close()`。
  每个回滚 op 只等 1.2 s，页面最多等 2.5 s 就 `router.back()`，不会卡死。
- 页面销毁 `aboutToDisappear` 会停流、释放 PixelMap、清回调、再兜底
  `shutdown()`（`leaving` 时只由 `exitPage()` 做一次）。

---

## 8. 静态自检

- 没有跑完整 `hvigor` 构建（按任务约束）。
- 只改了本角色三个文件：
  - `entry/src/main/ets/services/FujifilmControlService.ets`
  - `entry/src/main/ets/pages/FujifilmCameraControlPage.ets`
  - `docs/fujifilm/NOTES_B.md`
- 未改 `CameraControlPage.ets` / `Lumix*` / `Nikon*` / `Sony*` /
  `pages/home/CameraPage.ets` / `main_pages.json`。
- 自检项：
  - service 与 page 括号配平；
  - 无 `any`、无非空断言 `!`、无 `as any`；
  - 所有异步写路径 `try/catch` 或返回 boolean；
  - 日志统一 `[FUJI]` 前缀（页面 UI 动作用 `AppLogStore.add('[FUJI] ui …')`）；
  - 参数目录 53 条、无重复码。

## 9. 仍未确定 / 真机要看的点

1. **`0x902B` payload 的 `getSet` 精确偏移**：三种头排布都试，靠「payload
   正好消费完」自校验；如果真机仍然全失败，日志会打印前 16 字节
   `PROP_PARSE_FAIL`，需要按真机抓包再补一种排布。
2. **Phase2 是否还有隐藏 op**：当前按「建 55741 socket」实现；若真机
   `InitiateOpenCapture` 后取景不出帧，优先查 Phase2。
3. **事件 11/40 的来源**：A 现在抛原始 PTP 事件；如果后续 A 改成抛 SDK
   事件码，本服务的直通分支仍然可用；如果 A 增加了 `CCameraPropertyList`
   轮询，40 会自然出现。
4. **`0xDB40` 类未出现码**：本目录只列报告确认的 53 条；相机实际可能多报
   未知码，服务会保留在 `props()` 里（页面「全部参数」按目录过滤，不会
   显示未知码）。
5. **`0xD240` 低 31 位是否严格 `N×1000`**：显示按报告口径；如果真机出现
   `1/4000` 显示成 `1/4.0` 之类，需要按抓包修 `shutterText`。
