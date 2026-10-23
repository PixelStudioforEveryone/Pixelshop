# NOTES_F — FUJIFILM 下载照片方向（EXIF Orientation）逆向与实现

> 角色：富士线维护者（本文件与 `entry/src/main/ets/services/FujifilmImportService.ets` 是本轮唯一改动）。
> 目标：让富士 WiFi 下载的照片在「最近作品」里按实际拍摄方向显示，竖拍不横置。
> 证据缩写：`J:` = `Fujifilm\apk\jadx_src\sources\…`；`S:` = `Fujifilm\apk\apktool_out\smali*\…`；
> `N:` = native `.so` 的文件内虚拟地址（vaddr），反汇编工具为 DevEco SDK 的 `llvm-objdump 15.0.4`。
> 样本：FUJIFILM XApp 2.7.0(c2)，`libFFIR.so` / `libFTLPTPIP.so`（arm64-v8a）。

---

## 1. 结论速览

| 问题 | 结论 | 置信度 |
| --- | --- | --- |
| 方向字段在哪 | **不是固定偏移的 u8/u16 数值字段**。它是 `0x9054` 响应里第 4 个 PTP 字符串（标准 ObjectInfo 的 Keywords 槽位）中的 ASCII 键值文本 `Orientation:<n>` | 事实（native 反汇编） |
| 数值宽度/编码 | 文本十进制，wire 上是 PTP Unicode 字符串（UTF-16LE，`u8` 字符数 + 2×n 字节）；native 取低字节后按 `atoi` 解析 | 事实 |
| 取值范围 | **EXIF 1–8**，不是 SDK 的 1/2/3/4 自定义枚举 | 事实（映射表 + Java 常量交叉验证） |
| 相机是否总给 | 不保证。缺失/非法时 native 回退 1；本项目同样回退 1 | 事实 + 保守实现 |
| WiFi 缩略图是否已转正 | **没有转正**，是未旋转的裸像素；必须由客户端按方向补转 | 事实（官方三处代码交叉验证） |
| 传给 `RecentPhotoStore` 的值 | 直接用解析到的 **EXIF 1–8**（不要用官方 SDK 的 1–4 枚举） | 实现决定，理由见 §4 |

一句话：方向藏在 `0x9054` 的第 4 个字符串里，形如 `Orientation:6`；相机缩略图没转，客户端要按 EXIF 值转。

---

## 2. 逆向：方向字段的落点与格式

### 2.1 调用链（从 Java 到解析器）

```
ControlFFIR.getExtensionObjectInfo(handle, "", ImageInformation)
  → native Java_SDK_GetExtensionObjectInfo
  → SDK_CommonReadImageInfo                         N:libFFIR.so 0x5ea00
  → FFIR::CCameraCommandReadImage::ExecCommonReadImageInfo
                                                    N:libFFIR.so 0x74a08
  → FFIR::CPTPCommand::GetExtensionObjectInfo        N:libFFIR.so 0x82484（mode=1）
  → CFTLPTPLib::FTL_PTP_GetExtensionObjectInfo       N:libFFIR.so 0x7d5b8
  → FTL_PTP_GetExtensionObjectInfo                   N:libFTLPTPIP.so 0x2c860（opcode=0x9054=36948）
  → FTL_PTP_CommonGetObjectInfo                      N:libFTLPTPIP.so 0x2bf94
```

- `FTL_PTP_GetExtensionObjectInfo` 把 `w1` 置为 `36948`（`0x9054`）后跳 `FTL_PTP_CommonGetObjectInfo`（`N:0x2c860-0x2c86c`）。
- `SDK_CommonReadImageInfo` 只是构造命令并 `CSDKAPI_CommandExec`（`N:0x5ea50-0x5ea78`）。
- `ExecCommonReadImageInfo` 在栈上准备 `_FTL_PTP_OBJECT_INFO`（1844 字节，`N:0x74a80` 的 `memset(...,1844)`），拿回后映射到 `SDK_ImageInformation`。

### 2.2 wire 布局：标准 PTP ObjectInfo + 4 个 PTP 字符串

`FTL_PTP_CommonGetObjectInfo` 对响应数据（`sp+344`）的处理是**逐字段拷贝/解析**，不是整块 memcpy：

| wire 偏移 | 字段 | 宽度 | 证据 |
| --- | --- | --- | --- |
| 0 | StorageID | u32 | `N:0x2c0b4-0x2c0c4` |
| 4 | ObjectFormat | u16 | `N:0x2c0c0/0x2c0e0` |
| 6 | ProtectionStatus | u16 | `N:0x2c0b8/0x2c0cc` |
| 8 | ObjectCompressedSize | u32 | `N:0x2c0bc/0x2c0d8` |
| 12 | ThumbnailFormat | u16 | `N:0x2c0c8/0x2c0f0` |
| 14 | ThumbnailCompressedSize | u32 | `N:0x2c0f4/0x2c108`（`ldur x9,[x8,#14]` 一次搬 8 字节，含 14/18） |
| 18 | ThumbnailPixWidth | u32 | 同上 |
| 22 | ThumbnailPixHeight | u32 | `N:0x2c0fc/0x2c110` |
| 26 | ImagePixWidth | u32 | `N:0x2c104/0x2c11c` |
| 30 | ImagePixHeight | u32 | `N:0x2c10c/0x2c120` |
| 34 | ImageBitDepth | u32 | `N:0x2c114/0x2c124` |
| 38 | ParentObject | u32 | `N:0x2c118/0x2c128` |
| 42 | AssociationType | u16 | `N:0x2c0d0/0x2c0f8` |
| 44 | AssociationDesc | u32 | `N:0x2c0e8-0x2c100` |
| 48 | SequenceNumber | u32 | `N:0x2c0ec-0x2c100`；**Fuji 私有 `realFileFormat` 复用此位** |
| 52 | PTP 字符串 #1：文件名 | u8 字符数 + UTF-16LE | `N:0x2c148`（`ldrb w10,[sp,#396]` 即 resp+52） |
| 52+len1 | PTP 字符串 #2：拍摄时间 | 同上 | `N:0x2c244` 起 |
| … | PTP 字符串 #3：修改时间 | 同上 | `N:0x2c34c` 起 |
| … | **PTP 字符串 #4：厂商 metadata** | 同上 | `N:0x2c470` 起，目标 `struct+820` |

- 每个 PTP 字符串 = 1 字节字符数 `n`（含结尾 NUL）+ `2*n` 字节 UTF-16LE；native 用 `bfi x8,x10,#1,#8` 算出 `2*n+1` 作为步长（`N:0x2c234`、`0x2c33c`）。
- **纠一个前提**：“文件名在 52”本身并不是私有重排——标准 PTP ObjectInfo 的固定头就是 52 字节，Filename 从 52 开始（52 处是 `u8` 字符数，字符从 53 开始）。富士私有的只有两处：① 偏移 48 的 `SequenceNumber` 被复用为 `realFileFormat`；② 第 4 个字符串（Keywords 槽位）被换成 `key:value` 厂商 metadata。因此不要把“52”当成异常偏移。
- 第 4 个字符串被拷到 `_FTL_PTP_OBJECT_INFO+820`，槽位长 1024 字节（`struct` 总长 1844 = 820+1024，`N:0x2c010` 的 `memset 1844` 与 `N:0x2c470` 的目标偏移）。
- 特殊格式 `0xFFF1`（当前图伪对象）走另一条路：直接从 `resp+98` memcpy 1024 字节到 `struct+820`（`N:0x2c12c-0x2c144`）。
- 因此**方向没有固定 wire 偏移**：它的偏移 = `52 + Σ(1+2*n_i)`（i=1..3），随文件名/时间字符串长度变化。

### 2.3 方向键的解析：`Orientation:` 文本

`FFIR::CCameraCommandReadImage::ExecCommonReadImageInfo` 在 `struct+820` 上：

1. `strlen` 后构造 `std::string`（`N:0x74cc8-0x74d50`）。
2. `memchr(..., 'O', ...)` 找 `"Orientation:"`（12 字节比较常量 `0x7461746E6569724F` + `0x3A6E6F69`，即 `"Orientat"`+`"ion:"`，`N:0x74d7c-0x74dbc`）。
3. 找到后 `atoi` 取十进制（`N:0x74ed0-0x74ee4`）。
4. 值 `3..8` 查 6 项表（`N:0x74ef8-0x74f10`，表在 `N:0x48900`），其它值回退 `1`（`N:0x74f14`）。
5. 结果写入 `SDK_ImageInformation+104`（`N:0x74f18-0x74f1c`）。

同一段代码随后用完全相同的办法解析 `Rating:`（`N:0x750b0`）和 `Option:`（`N:0x75264`），说明第 4 个字符串就是 `key:value` 文本行。

### 2.4 取值范围：EXIF 1–8（关键证据）

`N:libFFIR.so 0x48900` 的 6 项 `int32` 表（按 `value-3` 索引）：

| metadata 值 | 3 | 4 | 5 | 6 | 7 | 8 |
| --- | --- | --- | --- | --- | --- | --- |
| 映射后的 SDK 值 | 3 | 1 | 1 | 2 | 1 | 4 |

官方 SDK 枚举（`J:.../common/ffir/ControlFFIR.java:120-123`）：

```
SDK_ORIENTATION_0   = 1   //   0°
SDK_ORIENTATION_90  = 2
SDK_ORIENTATION_180 = 3
SDK_ORIENTATION_270 = 4
```

把两者对齐：`3→180°`、`6→90°`、`8→270°`，正是 **EXIF Orientation 的 3/6/8**；若输入是 SDK 枚举（1–4），值 4 应保持 4，不可能被映射成 1。故输入确定为 EXIF 1–8。4/5/7 是镜像类，官方只保留“不旋转”（1），本项目按原值交给 `RawPreviewLoader` 处理镜像。

`SDK_ImageInformation+104` 再经 JNI 写到 Java `ImageInformation.orientation`（字段名 `orientation` 在 `N:libFFIR.so 0x430dc`；Java 字段/存取器 `J:.../common/ImageInformation.java:14,104-110`）。**注意：Java 层拿到的是映射后的 SDK 1–4，不是 EXIF 原值。**

---

## 3. WiFi 缩略图到底转没转？——没转

这是本轮最关键的“不要两头都写”的判断。三条独立证据都指向“相机缩略图是未旋转的裸像素，客户端必须自己转”：

1. **文件缓存路径（WiFi 直接证据）**：`J:.../model/importimage/CashDataManager.java:95-110,333-337`
   `registerCashData()` 在 `ConnectType != KUsb` 时把 SDK 方向反算成 EXIF（1→1、2→6、3→3、4→8），先把**原始缩略图字节**写入缓存文件，再用 `ExifInterface.setAttribute(TAG_ORIENTATION, …)` 补写 EXIF。若像素已转正，补写 EXIF 会让所有支持 EXIF 的查看器再转一次。
2. **下载完成后的预览**：`J:.../model/importimage/ReceiveImageModel.java:1800-1816,1857-1867`
   WiFi 路径对刚落地的 JPEG 重新解码（`BitmapFactory`，不处理 EXIF），再按 `information.getImageInformation().getOrientation()` 调 `rotate(90/180/270)` 做卡片缩略图。若像素已转正，这里会二次旋转。
3. **USB 侧对照，解释报告 03 §7.5 那句话**：`J:.../model/importimage/ReceiveImageModel.java:766-799`
   `readThumbnailIfNeeded()` 第一行就是 `if (ConnectType != KUsb) return;`；只有 USB 才从缩略图字节里读 EXIF、再映射成 SDK 1–4 写回 `ImageInformation.orientation`。所以报告 line 652 的“仅 USB 路径把 EXIF 方向映射为 1/2/3/4；WiFi 路径不处理”描述的是 **USB 的 EXIF 再映射**，它**不**表示 WiFi 缩略图像素已经转正。另有 `CashDataManager.bitmapConverter()`（`J:...:744-754`）同样用 `BitmapFactory` 解码（不处理 EXIF）后按方向 `rotateImage`，语义一致。

因此，报告 `03_图片传输_SD卡与倒序.md` §7.5 / line 652 的“仅 USB 路径把 EXIF 方向映射为 1/2/3/4 写入 `ImageInformation.orientation`；WiFi 路径不处理”应理解为：**USB 路径在 Java 侧额外做了一次 EXIF→SDK 的映射；WiFi 路径直接用相机 0x9054 给的方向**。它**不**表示 WiFi 缩略图像素已经转正。结合上面三处，结论是明确的：**未转正，必须按方向补转。**

### 3.1 传给 `RecentPhotoStore` 的是 EXIF 还是 SDK 枚举？

> **最终落地（补充）**：缩略图在缓存阶段就转正了（`orientThumbnail()`，见 §4），
> 因此 `downloadSelected()` 传给 `RecentPhotoStore.add` 的方向是 **1**——缓存文件里
> 的像素已经是显示方向，再传 6/8 会二次旋转。下面的 EXIF/SDK 语义说明仍然成立，
> 它解释了为什么 `orientThumbnail()` 用的是 EXIF 值。

`RecentPhotoStore.add(..., orientation)` 最终会：
- 原图可解码：走 `ExifOrientation.normalize()`，`orientation` 参数根本不用；
- 原图读不出来：用相机缩略图做像素源，`orientation > 1` 时调 `RawPreviewLoader.applyOrientation(pixelMap, orientation)`。

`RawPreviewLoader.applyOrientation`（`D:entry/src/main/ets/edit/utils/RawPreviewLoader.ets:158-176`）的分支是 **EXIF 语义**：
`3→180°`、`6→90°`、`8→270°`、`2/4/5/7→镜像/镜像+旋转`。

所以本项目必须把 **EXIF 1–8** 传下去，不能传官方 SDK 的 1–4。我们解析的是 `Orientation:` 文本原值，天然就是 EXIF；不要复用 native 映射后的 `ImageInformation.orientation`。

---

## 4. 代码改动（`FujifilmImportService.ets`）

| 位置 | 改动 |
| --- | --- |
| `FujifilmObjectInfo` | 新增 `orientation: number`（EXIF 1–8）+ 三个调试字段 `orientationMarker / orientationRaw / orientationValid` |
| `FujifilmGalleryItem` | 新增 `orientation: number`，由 `toGalleryItem()` 透传 |
| `parseObjectInfo()` | 调 `parseOrientation(data)`；缺失/越界回退 1 |
| 新增 `parseOrientation()` | 在整包里找 `Orientation:` 的 UTF-16LE 或 ASCII 字节串，读十进制并校验 1–8；不硬编码偏移 |
| 新增 `markerBytes()/indexOfBytes()/hexRange()/hexTail()` | 无依赖的字节查找与 hex 日志辅助 |
| `readObjectInfo()` | 仅对 `orientation>1` 或解析失败打一条 `objectinfo …`（含原始 hex），避免刷屏 |
| 枚举汇总 | `enumerated=… orientation>1=N orientationMissing=M` |
| `downloadSelected()` | 新增 `[FUJI] 方向 …` 日志；`RecentPhotoStore.add(..., 1)` —— 缩略图已转正，见下两行 |
| 新增 `orientThumbnail()` | `pumpThumbnails()` 取到缩略图字节后，`orientation > 1` 就解码 → `RawPreviewLoader.applyOrientation` → 重编码 JPEG 再缓存；失败原样返回 |
| `pumpThumbnails()` | 缓存/内存里保存的都是**显示方向**的缩略图，列表、预览、「最近作品」兜底三者一致 |

### 4.1 为什么在整包里扫标记，而不是按 §2.2 算偏移？

- §2.2 的字符串步进是 native 的权威布局，但本仓库现有解析器对“文件名在 52 是否带 1 字节 PTP 长度前缀”尚未在真机确认（`docs/fujifilm/NOTES_C.md` §8 也把该点列为待抓包确认）。
- `Orientation:` 只可能出现在第 4 个字符串里；直接在整包里找这个 12 字符标记，对“52 处是否有长度前缀”不敏感，也不会误命中文件名/时间。
- 这与 native 的做法同构：native 也是先拿到第 4 个字符串，再在字符串里 `memchr("Orientation:")`。

### 4.2 日志关键字（真机过滤用）

```
[FUJI] objectinfo handle=0x0000002A bytes=1844 orientation=6 marker=913 valid=1 raw=4F 00 72 00 ...
[FUJI] 方向 handle=0x0000002A orientation=6 thumb=camera
[FUJI] enumerated=812 failures=0 orientation>1=137 orientationMissing=0
```

- `objectinfo` 只在 `orientation>1` 或解析失败时出现（横拍 orientation=1 不打）。
- `方向` 每下载一张打一条，`thumb=camera` 表示该张有相机缩略图可作为「最近作品」兜底像素源。
- `marker` 是字节偏移（十进制）；`raw` 是标记起 48 字节的 hex，UTF-16LE 下会看到 `4F 00 72 00 69 00 …`。

---

## 5. 构建与真机验证

### 5.1 构建

```powershell
cd C:\Users\HQ\DevEcoStudioProjects\VIVID
& "C:\Users\HQ\AppData\Roaming\npm\devecocli.cmd" build --modules entry
```

本轮结果：**BUILD SUCCESSFUL**（见本轮回报）。

### 5.2 真机验证步骤

1. 相机设为竖构图（或把相机顺时针转 90° 拍一张），WiFi 连相机，进「图片传输」。
2. 看 App 日志：
   - 枚举汇总里 `orientation>1=N` 的 `N` 应大于 0；
   - 下载时对应句柄应打 `[FUJI] 方向 handle=0x… orientation=6`（或 8）。
   - 若全部 `orientationMissing=N` 且 `raw` 里看不到 `4F 00 72 00…`，说明该机型 0x9054 没带第 4 个字符串，需要抓包确认（见 §6）。
3. 回到「最近作品」：竖拍卡片应是竖的（2:3 框），点开大图方向正确。
4. 对照测试横拍：`orientation=1`，卡片仍是横的，不能出现“横图被转竖”。
5. 兜底路径验证（可选）：下载后立刻在系统相册里把原图移走/改权限，让 `RecentPhotoStore` 走相机缩略图分支，确认兜底缩略图也方向正确。

### 5.3 快速回退

- 若真机上发现某机型方向反了/多了 90°，只需把 `downloadSelected()` 里传给 `RecentPhotoStore.add` 的 `orientation` 改回 `0`（或按机型 clamp），其余解析与日志可保留。
- 若确认该机型 `0x9054` 没有 `Orientation:`，`parseOrientation()` 会自然回退 1，不会抛错。

---

## 6. 仍未闭合 / 风险

| 项 | 状态 | 说明 / 下一步 |
| --- | --- | --- |
| 52 处是否有 PTP 长度前缀 | **未在真机抓包确认** | native 反汇编显示 52 是 `u8` 字符数、字符从 53 开始（`N:libFTLPTPIP.so 0x2c148/0x2c190`）；本仓库现有 ArkTS 文件名解析仍从 52 直接按 UTF-16 解码，若真机文件名出现乱码，应另开一轮修（本轮不动文件名逻辑）。方向解析不依赖它 |
| 第 4 个字符串在所有机型都存在 | 未知 | 只在 XApp 2.7.0 的 native 里确认了“存在则解析”；没抓到真机包。日志的 `orientationMissing` 就是为此准备的 |
| `Orientation:` 的具体分隔符/换行 | 未知（不影响） | `atoi` 与我们的十进制读取都只依赖冒号后的数字，不依赖 `\n`/`,`/`;` |
| 镜像值 2/4/5/7 | 官方映射表把 4/5/7 归为 1 | 本项目按原值交给 `applyOrientation`（2/4/5/7 会做镜像）。若真机发现镜像方向不对，可在 `parseOrientation()` 里按官方表归一 |
| 视频 MOV/MP4 | 未单独验证 | 官方对视频缩略图也走同一方向值；本项目同样透传。若视频帧本身已转正，可能出现二次旋转，需真机确认后可对 `isVideo` 单独传 1 |
| 特殊格式 0xFFF1（当前图伪对象） | 已确认布局（`resp+98` 1024 字节） | 本页不请求 `0x10000001`，不影响；若以后加顶部“当前图”，扫描法同样适用 |

---

## 7. 证据索引（可直接复查）

| 结论 | 证据 |
| --- | --- |
| 0x9054 入口 | `N:libFTLPTPIP.so 0x2c860`（`mov w1,#36948`） |
| 头 52 字节逐字段拷贝 | `N:libFTLPTPIP.so 0x2c0b4-0x2c12c` |
| 第 1 个字符串在 52（u8 计数 + UTF-16LE） | `N:libFTLPTPIP.so 0x2c148-0x2c244` |
| 第 4 个字符串 → struct+820 | `N:libFTLPTPIP.so 0x2c470-0x2c574` |
| 特殊 0xFFF1：resp+98 → struct+820，1024 B | `N:libFTLPTPIP.so 0x2c12c-0x2c144` |
| 在 +820 找 `Orientation:` 并 atoi | `N:libFFIR.so 0x74cc8-0x74ee4` |
| 3..8 → SDK 1/2/3/4 映射表 | `N:libFFIR.so 0x48900`（表）、`0x74ef8-0x74f1c`（用法） |
| SDK 方向枚举 1/2/3/4 | `J:.../common/ffir/ControlFFIR.java:120-123` |
| Java `ImageInformation.orientation` | `J:.../common/ImageInformation.java:14,104-110` |
| JNI 字段名 `orientation` | `N:libFFIR.so 0x430dc`（rodata） |
| WiFi 缓存缩略图需按方向转（bitmapConverter / EXIF 写入） | `J:.../model/importimage/CashDataManager.java:744-754` |
| WiFi 文件缓存补写 EXIF 方向 | `J:.../model/importimage/CashDataManager.java:95-110,333-337` |
| WiFi 下载后按方向转 JPEG 预览 | `J:.../model/importimage/ReceiveImageModel.java:1800-1816,1867` |
| USB-only 的缩略图 EXIF 映射（报告 03 §7.5） | `J:.../model/importimage/ReceiveImageModel.java:766-799` |
| 同一处的 smali 交叉引用 | `S:.../ImportImageModel$readThumbnail$2$1.smali:164-298` |
| `applyOrientation` 的 EXIF 语义 | `D:entry/src/main/ets/edit/utils/RawPreviewLoader.ets:158-176` |
| 最近作品的方向使用点 | `D:entry/src/main/ets/services/RecentPhotoStore.ets:60-76,113-119` |
