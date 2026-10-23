# NOTES_C — FUJIFILM 图片传输（角色 C）实现与逆向记录

本文是**角色 C**（图片传输页）的实现记录。契约见 `ROUTE_SPEC.md`；这里只写
“为什么这么做、证据在哪、哪里还没证实”。所有协议行为都尽量落到
`Fujifilm\apk\reports\03_图片传输_SD卡与倒序.md`（下称“03 报告”）和 native
反汇编地址，【推断】/【未知】单独标注。

产物（仅这两个代码文件 + 本文由 C 写入）：

| 文件 | 作用 |
| --- | --- |
| `entry/src/main/ets/services/FujifilmImportService.ets` | PTP 会话准备、双槽、枚举、缩略图队列、下载/落地 |
| `entry/src/main/ets/pages/FujifilmImageTransferPage.ets` | 页面：顶栏 / 卡槽 / 网格 / 底部下载 / 进度 / 预览 |
| `docs/fujifilm/NOTES_C.md` | 本文 |

只读依赖：`FujifilmPtpIp.ets`、`FujifilmProtocol.ets`、`CameraSessionStore.ets`、
`pages/home/HomeShared.ets`（`AppLogStore`）。C 未改 `main_pages.json`；
A 已把 `pages/FujifilmImageTransferPage` 追加进路由，可直接跳转。

---

## 1. 结论速览

* **会话**：`connect()` → 等 event 11 → `SetFunctionMode(20)` → 读/写
  `FunctionVersion(0xDF28)` → `GetDualSlotStatus` → 枚举当前槽。
* **模式写入的真实属性是 `0xDF01`，不是 `0x5002`**。`0x5002` 是标准 PTP
  FunctionMode，富士图片浏览链路走私有属性（native 证据见 §2.1）。
* **双槽 status 的 wire 操作是 `Get/SetDevicePropValue(0xD244, UINT8)`**。
  FFIR 的 `0x6073/0x6074` 只是内部命令 ID，不是 PTP opcode。
* **枚举**：当前句柄 `0xD22B` → 总张数 `0xD620` → 日期分组 `0x9053(0,30000)`
  → 全部句柄 `0xD621`（一次取全，不分页）→ 每条 `0x9054` 对象信息。
* **不排序**：Wi‑Fi 链路的相机顺序就是“最新在前”，`handles[0]` 最新；页面
  只写“相机顺序 · 最新在前”，没有任何排序开关。
* **卡槽数**：status 1–4 画 2 个按钮，5–7 画 3 个；status 0 没有槽位信息，
  按机型兜底（默认 2，紧凑单卡系列 1），空卡置灰但**不隐藏**。
* **缩略图**：`0x9055` 失败回退 `0x100A`；串行队列，上限 50，内存缓存 24 张，
  文件缓存 `filesDir/fujifilm/thumbs/`。
* **下载**：≤20 MiB 用 `0x1009` 整包；大文件用 `0x9056`，块大小 12582880；
  失败回退 `0x101B`；进度/取消/最多 2 次尝试；重名 `name (N).ext`。
* **落地**：先写 `filesDir/fujifilm/`，再用 `photoAccessHelper.createAsset`
  写系统相册；相册失败保留应用目录文件并在完成文案里区分。

---

## 2. 会话准备与两个“属性码冲突”

### 2.1 `SetFunctionMode(20)` → `SetDevicePropValue(0xDF01, UINT16)`

证据（`libFFIR.so`，见 `apk\tmp\native\opcodes_FFIR.csv`）：

| 函数 | vaddr | 关键立即数 | 说明 |
| --- | --- | --- | --- |
| `SDK_SetFunctionMode` | `0x5ed28` | `0x4078` / `0xDF01` / `4` | 内部命令 `0x4078`；构造 `CCameraParamForSetInt`，属性 `0xDF01`，PTP 类型 `4` = UINT16 |
| `SDK_SetFunctionVersion` | `0x5ee14` | `0x4130` / 属性参数 / `6` | 内部命令 `0x4130`；类型 `6` = UINT32 |
| `SDK_GetFunctionVersion` | `0x5eee8` | `0x4131` / `6` | 类型 `6` = UINT32 |
| `SDK_GetDualSlotStatus` | `0x61ce8` | `0x6074` / `0xD244` / `2` | 类型 `2` = UINT8 |
| `SDK_SetDualSlotStatus` | `0x61c18` | `0x6073` / `0xD244` / `2` | 类型 `2` = UINT8 |

`CParamForSetFunc::SetParamFunc`（XAPI，`0xe3658`）从结构 `+0x30` 取属性码、
`+0x34` 取数据类型，再调 native setter——所以命令构造函数里的 `0xDF01` 不是
“内部 command id”，而是真正下发的 DevicePropCode。

实现：

```ts
SetDevicePropValue(0x1016, params=[0xDF01], data=u16(20))
GetDevicePropValue(0x1015, params=[0xDF28]) → u32 cameraVersion
SetDevicePropValue(0x1016, params=[0xDF28], data=u32(cameraVersion))
```

**冲突 1**：`FujifilmProtocol.ets` 里 `FujifilmProp.FUNCTION_MODE = 0x5002`。
本轮反汇编证明图片浏览不走它；A/B/D 若用 `0x5002` 切模式会读不到图库。
C 不改协议文件，只在 `FujifilmTransferCode.PROP_FUNCTION_MODE = 0xDF01`
本地定义，待协调者合并。

### 2.2 版本协商：相机版本 > 3 时官方直接报错

`CameraConnectModel$setFunctionMode$1.smali` 第 187 行附近：

```
if (cameraVersion > versionApp) {
    CameraConnectStatus.VersionError;
    return;
}
SetFunctionVersion(0xDF28, cameraVersion);
```

图片浏览的 `versionApp = 3`（`FujifilmMode.MIN_VERSION_IMAGE_VIEW`）。实现：

* 读不到（≤0）：跳过 `SetFunctionVersion`，继续；
* `cameraVersion > 3`：记日志并跳过写入，**不直接失败**（枚举可能仍可用；
  官方是弹版本错误，但我们的页面没有版本错误弹窗需求）；
* 1–3：原样写回相机版本。

这样既符合官方“不高版本写入”的保护，也不会在新机上把整页卡死。

### 2.3 event 11 与兜底

* 先注册 `FujifilmPtpIp.onEvent`，再 `connect()`；等 `GET_CAMERA_MODE(11)`，
  上限 6 s。等不到也继续——真正的门是模式写入。
* 模式写入失败（非 `0x2019`/`4102` 或 5 次重试仍失败）→ 发一次标准
  `OpenSession(1)`（`0x1002`）后继续枚举。A 的 `connect()` 已经带 OpenSession，
  这里只覆盖“连接成功但会话异常”的降级路径。
* **不调用** `clearEventListeners()`：A 的 PTP 客户端和 D 的固件服务共用监听器，
  清空会误伤别人。页面销毁只置 `disposed=true`，回调自行忽略。

**冲突 2**：`FujifilmProp.IMAGE_QUALITY = 0xD244`，而 native 明确把 `0xD244`
当双槽状态（UINT8，0–7）。C 不引用 `IMAGE_QUALITY`，本地
`FujifilmTransferCode.PROP_DUAL_SLOT_STATUS = 0xD244`。请协调者把协议文件里的
`IMAGE_QUALITY` 改名/换码；否则 B 的图片质量读写会把双槽状态写坏。

---

## 3. 双槽 / 多 SD 卡

### 3.1 `convertCardStatus`（官方逐字映射）

`J:...model\importimage\ImportImageModel.java:3539-3634`：

| 当前 status | 目标槽 | 新 status |
| --- | --- | --- |
| 1 | 2 | 2 |
| 2 | 1 | 1 |
| 3 | 2 | 4 |
| 4 | 1 | 3 |
| 5 | 2 | 6 |
| 5 | 3 | 7 |
| 6 | 1 | 5 |
| 6 | 3 | 7 |
| 7 | 1 | 5 |
| 7 | 2 | 6 |

其他组合返回 `-1`，页面不发送写请求。实现见
`FujifilmSlotPolicy.convertCardStatus`。

### 3.2 槽位数与当前槽

`J:...ui\importimage\ImportImageViewHeaderKt.java:1236-1299` 的 `z3/z4/z5`
（三个槽图标哪个是当前）：

| status | 当前槽 | 槽位数 |
| --- | --- | --- |
| 0 | 无 | 无信息 |
| 1 / 3 / 5 | 1 | 2 / 2 / 3 |
| 2 / 4 / 6 | 2 | 2 / 2 / 3 |
| 7 | 3 | 3 |

`ProductType` 只特判 `X-T3`、`X-Pro3`、`GFX 50R`；status 0 时官方对这三个
显示“双槽禁用”，其余显示“单槽禁用”。这个特判覆盖不了所有新机型，C 改成：

* status 1–4 → 2 个按钮；5–7 → 3 个按钮；
* status 0 → 紧凑单卡系列（X100 / X-E / X-T10/20/30/50 / X-T100/200 /
  X-A / X-M / X-S10/20 / X70 / XQ）1 个，其余 2 个；X-Pro 系列是双槽，
  不列入单卡前缀；
* 没有卡也把按钮画出来，`.enabled(false)` + 透明度 0.55。

### 3.3 “可用槽”与空卡的取舍【推断】

03 报告 §4.4 的“可用槽”表（1→槽2、2→槽1、5→槽2/3、6→槽1/3、7→三槽）
如果按“在位卡集合”理解，会和 `convertCardStatus` 组合出死路：

* status 5 切到槽 2 → status 6；若 6 的在位集合是 {1,3}，刚切过去的槽 2
  反而“无卡”，列表立刻又空。

因此 C 采用能自洽的解释：

* status 1–7 表示至少有一张卡，`availableSlots = [1..slotCount]`；
* 当前槽由 `convertCardStatus` 反推（1/3/5→1，2/4/6→2，7→3）；
* status 0 才是“一张卡都没有”，所有按钮灰显；
* 如果后续真机证明存在“某槽空、另一槽有卡”的独立位，只需替换
  `FujifilmSlotPolicy.availableSlots`，页面与切槽流程不用动。

这是本文件最重要的【推断】。真机验证方法：单卡插槽 1 / 单卡插槽 2 /
双卡 / 三卡各读一次 status，并对照相机屏幕当前槽。

### 3.4 标准 `0x1004 + 0x1005` 的用途

即使双槽属性可用，也调用：

```
GetStorageIDs(0x1004) → count + storageID[]
GetStorageInfo(0x1005, [id]) → description(offset 26, UTF-16LE) + volumeLabel
```

用途：

* 给卡槽按钮补 `detail`（如 “SD”“CFexpress”）；
* `0xD244` 读不到（老机型 / 模式没切成功）时，退回按 storage 枚举：
  `slots = storages`，`activeStorageId = storages[0].id`，
  `GetObjectHandles(0x1007, [storageId,0,0])`；
* 此时 `slotControlSupported=false`，按钮只读，页面显示“标准存储枚举”。

### 3.5 切槽流程

1. `busy()` 或下载中直接拒绝；
2. `convertCardStatus` 算出目标 status；
3. **先清空** `items`、`selected`、`total`、缩略图队列/内存缓存，phase 置
   `slots`（页面进入 LoadingCard）；
4. `SetDualSlotStatus` 5 次 ×100 ms；
5. 成功：更新 `slotStatus/activeSlot`，重建按钮，重新枚举；
6. 失败：`phase=error` + 错误文案 + 重试按钮。

清空发生在写请求之前，满足“切换期间清空列表并显示加载态”。

---

## 4. 枚举

### 4.1 调用顺序

```
GetDevicePropValue(0x1015, [0xD22B])          // 当前对象句柄
GetDevicePropValue(0x1015, [0xD620])          // 总张数
0x9053(params=[0, 30000])                     // 日期分组张数（只诊断，见 §8）
GetDevicePropValue(0x1015, [0xD621])          // 全部句柄
0x9054(params=[handle])                       // 每条对象信息
```

`0xD22B / 0xD620 / 0xD621` 是 native getter 内部的属性码，和
`CommandExec_GetSpecifiedObjectHandles` 里出现的 `0x1015` 对应（`libFFIR.so`
`0x78334`）。`0x10000001` 是官方“当前图”伪句柄，配合 `0x9054/0x9055` 用；
本页没有顶部“当前图”卡片，因此没有额外请求它，当前项用真实句柄标记。

### 4.2 张数与句柄的容错

* 先读 `0xD620`；失败回退标准 `GetNumObjects(0x1006, [storage,0,0])`。
* 句柄先读 `0xD621`；失败回退 `GetObjectHandles(0x1007, [storage,0,0])`。
* `0xD621` 的响应有两种可能布局：裸数组 `N×u32`，或 `u32 count + N×u32`。
  `parseHandleArray` 按 `expected`（总张数）优先匹配：
  * `words == expected` → offset 0；
  * `words == expected+1 && first == expected` → offset 4；
  * 否则 `first` 像一个合法 count 时按 count 读；
  * 兜底按裸数组读。
* 过滤 `handle == 0`，最多保留 `OBJECT_COUNT_LIMIT × 4`（12 万）防异常包。
* **不做 offset 分页**：`count` 一次给全；`0x9053` 的 offset 恒 0、count 30000。

### 4.3 对象信息布局

`0x9054` 的数据是标准 PTP ObjectInfo + 一个富士私有 `realFileFormat`：

| 偏移 | 字段 | 类型 |
| --- | --- | --- |
| 0 | StorageID | u32 |
| 4 | ObjectFormat | u16 |
| 6 | ProtectionStatus | u16 |
| 8 | ObjectCompressedSize | u32 |
| 12 | ThumbFormat | u16 |
| 14 | ThumbCompressedSize | u32 |
| 18 | ThumbPixWidth | u32 |
| 22 | ThumbPixHeight | u32 |
| 26 | ImagePixWidth | u32 |
| 30 | ImagePixHeight | u32 |
| 34 | ParentObject | u32 |
| 38 | AssociationType | u16 |
| 40 | AssociationDesc | u32 |
| 44 | SequenceNumber | u32 |
| **48** | **realFileFormat（富士私有）** | **u32** |
| **52** | **Filename（UTF-16LE，NUL 结尾）** | **string** |
| 52+ | CaptureDate | string |
| … | ModificationDate / Keywords | string |

标准 `0x1008` 没有 48 的私有字段，文件名在 48。解析器先试 48、再试 52、44：
富士包的 48 处是 `realFileFormat` 低字节（控制字符），会被
`isPlausibleName` 拒掉；标准包 48 直接命中。拍摄时间不依赖文件名偏移，
从文件名后 600 字节内扫描 `YYYY[-/:]MM[-/:]DD` 形状的 UTF‑16 字符串。

### 4.4 格式码

`J:...model\importimage\ReceiveImageDataKt.java:9-26`：

| 码 | 值 | 扩展名 | MIME |
| --- | --- | --- | --- |
| `FORMAT_ASSOCIATION` | `0x3001` (12289) | — | 跳过（文件夹） |
| `FORMAT_EXIF_JPEG` | `0x3801` (14337) | jpg | image/jpeg |
| `FORMAT_JFIF` | `0x3808` (14344) | jpg | image/jpeg |
| `FORMAT_HEIF` | `0x3812` (14354) | heic | image/heic |
| `FORMAT_RAF` | `0xB103` (45315) | raf | image/x-fuji-raf |
| `FORMAT_MOV` | `0x300D` (12301) | mov | video/quicktime |
| `FORMAT_MP4` | `0xB982` (47490) | mp4 | video/mp4 |
| `FORMAT_PNG` | `0x380B` | png | image/png |
| `FORMAT_TIFF` | `0x380D` | tif | image/tiff |

文件名后缀优先（用户看到的真实格式）；`realFileFormat` 只做兜底。RAF/HEIC
没有缩略图时仍按原格式保存，避免把 RAW 改名成 JPG。

### 4.5 排序

**Wi‑Fi 链路不做任何排序**。03 报告 §6 的证据：官方 `GetSpecifiedObjectHandles`
返回的顺序就是相机顺序，`handles[0]` 最新；USB 链路才有时间/句柄倒序。页面
不提供排序开关，文案固定“相机顺序 · 最新在前 · 不排序”。如果未来加开关，
“默认/重置”必须回到相机顺序，而不是再次倒序。

---

## 5. 缩略图

* 主请求 `GetExtensionThumb(0x9055, [handle])`；失败/空数据回退
  `GetThumb(0x100A, [handle])`。
* 队列：页面首屏请求 30 个；每个 tile `onAppear` 再请求自己的 handle；
  服务端 `thumbQueue` 上限 50（可见行 ×3 的上限），超出静默丢弃，等下一次
  `onAppear` 再入队。
* 串行：`pumpThumbnails` 单 worker，避免几十个 PTP 事务同时排队。
* 内存缓存：`Map<handle, Uint8Array>`，LRU 式上限 24 张。
* 文件缓存：`filesDir/fujifilm/thumbs/s<slot>_<handle>.jpg`；页面用
  `file://` URI。文件名带槽号，避免两张卡同 handle 串图。
* 失败：`thumbState='failed'`，tile 显示占位；不自动无限重试，避免坏卡刷屏。
* 切槽/重新枚举：`thumbEpoch++`，旧 worker 在下一个检查点退出；清空队列与
  内存缓存（文件缓存保留，按槽号隔离）。

`GetExtensionThumb` 返回的是 JPEG 原始字节（官方 `ReadThumbnail` 同链路）；
若 magic 不是 `FF D8` 且对象是 HEIC，则按 `.heic` 落盘，其余仍按 `.jpg`。

---

## 6. 下载与落地

### 6.1 整包 vs 分块

`ReceiveImageDataKt.GET_OBJECT_SIZE_ONE_TIME = 20971520`（20 MiB）：

* `size > 0 && size <= 20 MiB`：先 `GetObject(0x1009, [handle])` 一次拉完；
  返回长度必须等于 `size`（size 未知时接受非空）。
* 否则 / 整包失败：`GetExtensionPartialObject(0x9056, [handle, offset, ask])`，
  `ask = min(12582880, remain)`（官方 MOV/RAF 滚动缓冲）。
* `0x9056` 抛错时回退 `GetPartialObject(0x101B, [handle, offset, ask])`。
* 每块写完回调进度；块间 `await delay(0)` 让 UI 刷新；取消在块间生效。
* 结束校验 `received == size`；不完整抛错，删 `.part` 后最多再试 1 次（共 2 次）。

### 6.2 文件与相册

* 先写 `filesDir/fujifilm/.<handle>_<timestamp>.part`，校验通过后
  `renameSync` 成正式名。
* 重名：`name.ext` → `name (1).ext` → …，最多 999。
* 相册：`photoAccessHelper.getPhotoAccessHelper(context).createAsset(type, ext,
  { title: baseName })`，再用 8 MiB 块 `copyFileChunked`；写入字节数必须等于
  文件大小。成功后删应用目录副本；失败则保留应用目录副本，完成文案显示
  “相册 N，应用目录 M，失败 K”。
* `createAsset` 对 RAF/HEIC 可能拒绝；被拒就只留应用目录，不阻塞其他文件。

### 6.3 未实现的官方动作

* `SetImageForceCompression(0)`（进图库前强制不压缩）：FFIR 内部命令
  `0x4100`，但 wire 属性码未在本轮确认，且不影响读图；未实现。
* `SetCameraEvent(4097, n)`（下载完成回告相机）：内部 `0x6200`，wire 映射
  未确认；未实现，避免误写相机状态。

这两条都在 §8 标【未知】。

---

## 7. 页面行为

* `@Entry` 自包含；`aboutToAppear` 校验
  `CameraSessionStore.instance.cameraBrand === 'FUJIFILM'`，不匹配显示
  “相机品牌不匹配”卡片，不建立 PTP。
* 数据流：服务只暴露 `snapshot()` + `revision`；页面 250 ms 轮询，revision
  不变不拷贝，避免把 `@State` 全量重设。
* 顶栏：返回 / “图片传输” / 机型 / 阶段 chip。
* 状态卡：机型、消息、卡槽、总数、已选。
* 卡槽卡：按钮数 = 服务上报；当前蓝色，可用浅蓝，空卡灰色禁用；切槽立即
  进入 LoadingCard。
* 图库：2 列 Grid，3:2 缩略图，视频/当前角标，右上勾选，底部文件名/日期/大小；
  点图打开缩略图预览（双指 1–4 倍），点圆圈只切换选中。
* 底部固定“全选/取消全选 + 下载 N”；没有排序/倒序入口。
* 空态分三种：当前卡无卡、未检测到卡、卡内无照片；错误态有“重试”。
* 下载浮层：状态、进度条、百分比、当前/总数、取消；返回键在下载中先取消。
* 离开页面：清 timer、`service.dispose()`（取消下载/缩略图，`PtpIp.close()`）。
  再次进入重新建链。

**路由**：`main_pages.json` 由 A 维护，C 没有改；需要 A 追加
`pages/FujifilmImageTransferPage`，否则页面编译但不可达。

---

## 8. 未知 / 风险 / 需要协调

| # | 项 | 现状 | 建议 |
| --- | --- | --- | --- |
| 1 | status 0–7 的位域定义 | 只知道 `convertCardStatus` 与 UI 当前槽；§3.3 是自洽推断 | 真机四组插卡组合读 status，补全位定义 |
| 2 | `0x9053` 响应布局 | 只调用并打日志（code/bytes/head），不参与 UI | 需要日期分组标题时再解码 |
| 3 | `0xD621` 是否带 count 前缀 | 解析器兼容两种布局，用 expected 优先 | 真机抓一次原始字节确认 |
| 4 | `0x9056` 的 offset 宽度 | 按 u32 发送；>4 GB 文件可能溢出 | 用 >4 GB MOV 验证；必要时改 u64 参数 |
| 5 | `realFileFormat` 偏移 48 | 由 native ObjectInfo 读取模式与文件名偏移推断；解析器 48/52 双试 | 抓一条 0x9054 原始包确认 |
| 6 | `0xD244` 与 `IMAGE_QUALITY` 冲突 | C 本地用 `PROP_DUAL_SLOT_STATUS`，未改协议文件 | 协调者改 `FujifilmProtocol.ets`，并通知 B/D |
| 7 | `FUNCTION_MODE=0x5002` 冲突 | C 本地用 `0xDF01`；D 的固件服务仍按 `0x5002` | 协调者统一，D 复核固件模式写入 |
| 8 | 页面销毁 `PtpIp.close()` | 会关闭共享连接；若从控制页跳转回来需重连 | 若产品要求保活，改成引用计数 |
| 9 | 事件监听器无移除 API | 每次进页新增一个 lambda，旧实例 `disposed` 后忽略 | A 可加 `offEvent`；当前只泄漏少量闭包 |
| 10 | 当前图伪句柄 `0x10000001` | 本页没有顶部当前图卡片，未请求 | 若加顶部当前图，按官方 0x9054/0x9055 取 |
| 11 | 相册失败后的空资产 | `createAsset` 成功但 copy 失败时可能留下 0 字节资产 | 后续用 `deleteAssets` 清理 |
| 12 | 缩略图与下载并发 | 下载时缩略图队列仍可能在跑；A 的事务队列串行，安全但会拖慢 | 下载开始时暂停缩略图队列（可选优化） |

---

## 9. 静态自检 / 真机清单

本轮**没有跑全量 hvigor 构建**（按约束），只做了：

* `git status --short` 确认 C 只新增服务、页面两个代码文件 + 本文；
* 检查 import：`FujifilmPtpIp` / `FujifilmProtocol` / `CameraSessionStore` /
  `HomeShared` 路径均存在；
* 检查没有 `any`、没有改动禁改文件、日志统一 `[FUJI]` 前缀；
* 服务/页面通过词法括号检查（跳过注释、字符串、模板字符串、正则）与
  `ohos-typescript` 语法解析；**页面 ArkUI DSL 没跑 hvigor**，按约束只做静态检查。

真机建议按下面顺序：

1. 单卡槽 1、单卡槽 2、双卡、三卡各进一次，记录 `dualSlotStatus` 与按钮数；
2. 当前槽无卡时列表应为空、文案提示换卡；点另一槽应清空并重新加载；
3. JPG / RAF / HEIC / MOV / MP4 各一张，确认扩展名、MIME、视频角标；
4. 选一个 >20 MiB 的 MOV 和一个 >4 GB 的文件，确认 0x9056 分块与进度；
5. 下载中取消，确认 `.part` 被删、相册无残留；
6. 同名文件下载两次，确认 ` (1)`；
7. 拒绝相册权限，确认回退到 `filesDir/fujifilm/` 且完成文案区分；
8. 对照相机屏幕确认 `handles[0]` 是最新一张，页面没有倒序；
9. 断开相机 Wi‑Fi，确认错误卡与重试；
10. 从页面返回再进，确认 PTP 重连与列表恢复。

---

## 10. 与 03 报告章节的对应

| 03 报告 | 本实现 |
| --- | --- |
| §0.1 12 步链路 | `open()` + `enumerateCurrentSlot()` |
| §1 / §3.2 event 11 | `waitEvent11()` |
| §3.3 SetFunctionMode | `setFunctionMode()`，`0xDF01` |
| §3.4 Get/SetDualSlotStatus | `readDualSlotStatus()` / `writeDualSlotStatus()` |
| §3.5 切槽刷新 | `switchSlot()` |
| §3.7 当前图 | 未做顶部当前图；当前项用 `0xD22B` 标记 |
| §3.8 张数 / 句柄 | `readObjectCount()` / `readHandles()` |
| §3.9 缩略图 | `pumpThumbnails()` |
| §3.10 下载 | `downloadOne()` / `downloadInChunks()` |
| §4.4 双槽映射 | `FujifilmSlotPolicy` |
| §4.5 格式码 | `formatInfo()` |
| §6 排序 | 不排序；`items` 保持 `handles` 顺序 |
| §7 落地 | `saveToGallery()` + `filesDir/fujifilm/` |
| §9 错误码 | `isRetryable()`：`0x2019` / `4102` |
