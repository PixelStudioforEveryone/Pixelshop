# Canon 路线核实表

> 用途：逐条对照 `documents/Canon/report/00~04` 核验实现，防止「看起来能编译」
> 但协议细节走样。每条给出**代码位置**与**证据出处**。
> **核实方式**：静态核实（无佳能真机）。所有结论来自报告 + APK 反编译 +
> libgphoto2 公开实现；真机行为仍需实测，凡属推断的条目在状态列写明「推断」。

图例：✅ 静态通过 ｜ ⚠️ 通过但有偏差/限制 ｜ ❌ 未通过

## A. 识别（BLE）

| # | 要求 | 证据 | 实现位置 | 状态 |
|---|---|---|---|---|
| A1 | 只按 Canon 主服务 UUID 过滤扫描 | 报告 01 §1.1 | `CanonProtocol.CanonBleUuids.SCAN_SERVICE_UUIDS`（只有 `00010000-…`）/ `CanonBleService.startRadio` | ✅ 过滤失败时**不降级**为全量扫描，改在回调里按厂商数据过滤 |
| A2 | 厂商数据 Company ID 425、`[0]==1`、`usbId` 小端 | 报告 01 §1.2 | `CanonAdvParser.parseAdvert` | ✅ |
| A3 | 128-bit UUID（19B）/ 2B 后缀（6B）两种广播 | 报告 01 §1.2 | 同上（短格式 `[3][4]`→`uuid[14][15]`） | ✅ |
| A4 | 稳定身份 = 相机 UUID（写进候选 `btAddress`） | 用户要求 + 报告 01 §1.2 | `CanonModels.identityFromPid` + `CameraPage.startCanonBleDiscovery` 去重 | ✅ BLE 地址会轮换，去重键用 32 位十六进制相机 UUID |
| A5 | 产品 ID → 机型名/素材（未收录显示 `Canon 0xXXXX`） | APK drawable + report 00 §5 | `CanonModelImages`（95 条）/ `CanonModels.find`（精确→最长子串→回退） | ✅ 实测 95 个 slug 全部命中，无缺图 |
| A6 | 与松下/富士扫描并列，互不阻塞 | 用户要求 | `CameraPage.startCanonBleDiscovery`（在富士扫描后调用）；`startScan` 已在扫时只换回调 | ✅ 佳能不 `disconnect()` 就不动扫描器 |
| A7 | 卡片图片 = 本项目生成的透明背景图 | 用户要求 | `CameraPage.CameraModelImage` → `CanonModels.rawfileForImageKey` → `rawfile/canon/*.png` | ✅ `rawfile/canon/` 95 张；交付目录 `C:\Users\HQ\Desktop\picture\Canon` 同源 |

## B. 配对 / 注册 / Wi‑Fi 交接

| # | 要求 | 证据 | 实现位置 | 状态 |
|---|---|---|---|---|
| B1 | 首次配对：`pairDevice` + `00010006` 写 `01`+昵称 | 报告 01 §3 | `CanonBleService.register` → `bondIfNeeded` | ✅ `2900099` 视为「已绑定」不报错；相机 UUID 全 0 时只读能力位图（APK 实测行为） |
| B2 | WAP 命令 `01` / `04 09 00 00 00` / `0A` / `02` / `03` | 报告 01 §4 | `CanonFrames.wapStart/wapStartWithSecurity/wapRequestApConfig/wapStop/wapCancel`；`startWap/requestApConfig/stopWap` | ✅ `04 09 …` 需 `00020001` bit4 且 `00020006` 含该类型，否则退回 `01` |
| B3 | TLV：`0x10` IP、`0x02` BSSID、`0x30` WTIME | 报告 01 §4.2 | `CanonWapTlv.parse`（带头/无头双解析） | ⚠️ 官方解析**无条件跳过前 2 字节**且 WTIME 只读 1 字节（`%d00`）；实现两种都接受 |
| B4 | 状态字 `00020003` = `[code][subCode]` | 报告 01 §4.2 | `startWap` 合流状态 | ✅ READY 位判据在 APK 里自相矛盾，未采用；以「状态码 + TLV IP」为准 |
| B5 | SSID/密码：`0001000c` indicate 或 `00020004/05` 读 | 报告 01 §4.3 | `readWifiCredential` → 兜底 `readWapCredentials` | ✅ 页面先读缓存凭据，再拉 AP，再读一次 |
| B6 | 密码不落库、不进日志 | 报告 01 §4.3 | 全链路只记长度 | ✅ 无持久化 |
| B7 | 关联热点复用已验证的 PSK 关联实现 | — | `CameraPage.joinCanonWifi` → `LumixCameraService.connectToCameraWifi(..., {password})` | ✅ 安全类型固定 PSK=3（相机 AP 为 WPA2） |

## C. PTP/IP 传输

| # | 要求 | 证据 | 实现位置 | 状态 |
|---|---|---|---|---|
| C1 | 双 TCP 15740 + Init_Command/Event 握手 | 报告 03 §1.1 + `ptpip.c` | `CanonPtpIp.openSession`（GUID+UTF‑16LE 名称+版本；第二 socket Init_Event） | ✅ 事件通道失败只降级，不阻断 |
| C2 | OpenSession → SetRemoteMode → SetEventMode → KeepDeviceOn | 报告 02 §7 + `ptp.h` | 同上 | ✅ 后三步失败只记日志（部分机身只支持其一） |
| C3 | 包类型 6/7/9/10/11/8 与小端分帧 | ISO 15740 / `ptpip.c` | `CanonTcpChannel.readPacket` + `CanonBytes.buildPacket` | ✅ 8 字节头（长度+类型），载荷按 1 MiB 切片 |
| C4 | 超时/断链 reject 挂起、DeviceBusy 重试 | — | `readExactly` deadline + `fail()` + `awaitResponse` 的 `0x2019` 重发 | ✅ 事务串行化（单队列），事件泵不会插队 |
| C5 | EOS 操作码表 | `ptp.h` + 报告 03 §2 | `CanonEosOp` | ⚠️ 覆盖 0x9101/9102/9104/910A/9110/9116/911F/9127/9128/9129/912C/9132/9151~9153/9158/915A/9160；`0x9109`（GetObjectEx）与 `0x915F` 未封装（图传走 0x9104/0x912C），`0x914D` 仅定义未用（变焦走 0x9158） |

## D. 相机控制（参数表严格对照）

| # | 要求 | 证据 | 实现位置 | 状态 |
|---|---|---|---|---|
| D1 | 14 项 EDSDK 属性 ID 与报告 02 §2 完全一致 | 报告 02 §2 表 | `CanonProperties.CanonPropCatalog.DEFS`（14 行） | ✅ 0x0100/0x0106/0x0400~0x0407/0x040A/0x0444/0x0500/0x0501 |
| D2 | EDSDK ID ↔ PTP DPC 映射有出处 | `ptp.h` D1xx | 同行 `ptpDpc` 字段 + 文件头注释 | ✅ EDSDK 列抄报告，DPC 列标 libgphoto2（报告 02 §8 明确 Java 层没有 DPC） |
| D3 | 选项只来自相机（0xC18A/描述符），无描述符即置灰 | 报告 02 §1.3/§3.1 | `CanonControlService.loadProp` | ⚠️ 枚举类无描述符→置灰；连续量（光圈/快门/ISO/EV）用本地 1/3 档候选并标记 `inferred`，避免整页不可用 |
| D4 | 快门 5 个 param（0/1/0x10001/3/0x10003）→ RemoteReleaseOn/Off | 报告 02 §5.1 | `capture/halfPress/release/releaseSwitch` | ⚠️ 映射为「高 16 位=switch、低 16 位=action」的推导（`DS_RemoteReleaseOn(switch, action)`），日志打印实际值 |
| D5 | LiveView：Initiate → 循环 GetViewFinderData → Terminate | 报告 02 §4 | `startLiveView/stopLiveView/liveViewLoop` | ✅ 启动前 `0xD1B0 |= 2`，停止时清位；空帧按 60 ms 自然限速 |
| D6 | 参数写入 500 ms 去抖、同类覆盖 | 报告 02 §3.3 | `setParam`（同 key 覆盖 + 定时器重置） | ✅ |
| D7 | 页面区分预览/遥控；遥控不推流 | 用户要求 | `CanonCameraControlPage` 两态 + `stopLiveView()` | ✅ 切遥控即停流，画面冻结在最后一帧 |
| D8 | 无 LUT 传输按钮 | 用户要求 | 同上按钮清单（无 LUT 入口，仅注释说明） | ✅ |
| D9 | 参数对照抽屉显示 EDSDK/PTP ID | 用户要求 | 同上 `compareRows()`（固定 14 行） | ✅ 相机上报过的用真值，未上报的退回报告静态值 |

## E. 图片传输（SD 卡/多卡）

| # | 要求 | 证据 | 实现位置 | 状态 |
|---|---|---|---|---|
| E1 | 卷 = 存储卡，按 `GetStorageIDs` 顺序，空卡也建按钮 | 报告 03 §2.1 | `CanonImportService.open/refresh` + 页面卷按钮（数量 = `volumes.length`） | ✅ 空卡也入列并置灰卡片 |
| E2 | 递归 `GetObjectHandles`+`GetObjectInfo` 建目录树，无分页/无条数上限 | 报告 03 §2.2 | `CanonImportService`（3 参数失败回退 2 参数） | ✅ 不做客户端排序，保持相机原序 |
| E3 | 切卡清空→加载态→重枚举，条目按卡隔离 | 报告 03 §2.1 | `selectVolume` + 页面 revision 轮询（250 ms） | ✅ 条目键含 storageId，切卡不会串图 |
| E4 | 缩略图 `GetThumbEx` 缓存、失败不阻断 | 报告 03 §0/§3 | `filesDir/canon_thumb/<storageId>_<handle>.jpg` | ✅ 串行 + 批 6 + 失败留空占位 |
| E5 | 原图 `GetPartialObject` 分块 + 进度 + 取消 | 报告 03 §3 | `downloadSelected/cancelDownload`（1 MiB 分块，`0x912C`/`0x9132`） | ✅ 取消后保留已下完的文件 |
| E6 | 页面布局照松下 LAB（状态卡/卡切换/网格/底部条/遮罩） | 用户要求 | `CanonImageTransferPage`（3:2 网格、下载遮罩、预览遮罩） | ✅ 返回键顺序：预览→取消下载→退出 |

## F. 固件

| # | 要求 | 证据 | 实现位置 | 状态 |
|---|---|---|---|---|
| F1 | 当前版本 = PTP 属性 7；机型 ID = 0x01000001 | 报告 04 §2 | `CanonFirmwareService.readCameraState` | ✅ 用 `GetDevicePropValue`（0x1015）读，非 EOS 私有包 |
| F2 | 清单 URL + `<item id=hex>` 匹配产品 ID | 报告 04 §3 | `fetchCatalog` | ✅ `gdlp01.c-wss.com/rmds/ic/firmware/camera_urltable.xml` |
| F3 | 三段严格大于比较 | 报告 04 §4 | `isNewer` | ✅ 逐段数值比较，非字符串比较 |
| F4 | `.FIR` 头解析（0x37582111 分支、12B 版本、6 段规则） | 报告 04 §5.1 | `validateFir` | ✅ 机型 ID 不匹配直接拒绝 |
| F5 | 传输前五项检查（机型/版本/文件/卡/电量） | 报告 04 §6.2 | `send` + 页面卡片 | ✅ 任一不满足即中止 |
| F6 | 发送链路与失败回退、不伪造成功 | 报告 04 §6.1 | `send`（SendObjectInfo → SendObject → 0x911F） | ⚠️ `0x911F` 直发为推断路径，主链路有 APK 证据；失败按步回退并保留日志 |
| F7 | 页面 4 步 + 相机屏幕确认提示 | 报告 04 §7 | `CanonFirmwarePage`（检查/下载/传输/确认） | ✅ 传输期锁操作、拦返回键；`configure(context)` 已注入 |

## G. 隔离性（不得影响其它路线）

| # | 要求 | 检查 | 状态 |
|---|---|---|---|
| G1 | 松下 LAB/SYNC/ImageApp 行为不变 | `git diff`：`LumixCameraService`/`LumixControlService` 的改动是本次之前就存在的未提交修改，未再追加 Canon 逻辑；Canon 只调用既有公开方法 | ✅ |
| G2 | 尼康/索尼/富士行为不变 | 同上；`FujifilmFirmwareService` 等 Canon 字样为原有内容 | ✅ |
| G3 | 新增页面只在 `main_pages.json` 追加 3 条路由 | `git diff` 共 3 行新增 | ✅ |
| G4 | 新增素材只在 `rawfile/canon/`，不动 media 资源 | `git status` 新增目录仅 `rawfile/canon/` | ✅ |

## H. 构建

| # | 要求 | 命令 | 状态 |
|---|---|---|---|
| H1 | `devecocli build --modules entry` 成功 | 见设计文档 §9 | ✅ 清空 ArkTS 缓存后全量重编译：`CompileArkTS` 25.2 s → `SignHap` 2.3 s → **BUILD SUCCESSFUL**，产出 `entry-default-signed.hap`。注：本机若遇到 `SignHap` 报 `No permission write to …signConfigCheckJson.json`，是 hvigor 的 **Java 守护进程**持有该临时文件所致（`java daemon remote sign failed` 后回退本地签名仍被占用）；`taskkill` 掉 java 守护进程，或加 `--no-daemon` 用 `hvigorw.js assembleHap …` 构建即恢复，与工程代码无关 |
| H2 | 无 `any`/`TODO`/未使用导入 | 脚本 + 人工 | ✅ 12 个 Canon 文件全量扫描 0 命中 |

## I. 未验证 / 已知限制（必须让用户知道）

1. **无佳能真机**：BLE 广播、WAP 交接、PTP/IP 会话、取景、快门、图传、固件全链路只做过静态核对，未做真机联调。
2. **PTP 无录像指令**：报告 02 §6 的录像只存在于 BLE 遥控服务 `00030030`，因此控制页的录像按钮会明确提示失败（不伪造成功）。
3. **点按对焦数据布局**：`0x915A` 报告只写「sends data」，实现按 4×u32 矩形发送，相机拒绝时退化为 `DoAf`。
4. **APEX×8 假设**：光圈/快门同按 APEX×8 解释（1/125 s ≈ 56、f/4 ≈ 32），与报告 02 §2 的「APEX 定点」一致；若真机值域不同，只需改 `CanonFormat`。
5. **枚举文案**：相机不给列表时用 EDSDK 文档口径的中文表，未知值显示 `#十进制`。
6. **签名**：见 H1，属本机工具链环境，与 Canon 代码无关。
