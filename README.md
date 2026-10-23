# Pixelshop · Vivid for HarmonyOS

Vivid（应用名「像素工坊」，vendor `Pixelshop`）是一个 HarmonyOS 影像工作台：ArkTS + ArkUI，覆盖图库、相机连接（蓝牙配对 + Wi-Fi 传输 + 遥控）、后台传输、LUT 风格库和无损参数编辑。

## 相机协议路线

五家品牌、七条协议线，逐条实现在 `entry/src/main/ets/services/`，逐条报告在 `docs/protocol-reports/`：

| # | 线路 | 配对 | 传输 | 控制 | 报告 |
|---|------|------|------|------|------|
| 1 | 松下 LUMIX Lab | BLE GATT 注册（共享 `LumixImportPrototype`）+ 读 AP 凭据 | `/remote/*` REST + DTLS 取景 | `camcmd` / `set-setting` / `get-state` | [01](docs/protocol-reports/01-panasonic-lumix-lab.md) |
| 2 | 松下 LUMIX Sync | BLE GATT 注册下发凭据 | `cam.cgi` + DLNA/DMS | `cam.cgi` + `X-SESSION_ID` | [02](docs/protocol-reports/02-panasonic-lumix-sync.md) |
| 3 | 松下 Image App | 无蓝牙（手工/二维码/NFC 入网） | `cam.cgi` + DLNA/DMS | 只读探测 + 老世代命令 | [03](docs/protocol-reports/03-panasonic-image-app.md) |
| 4 | 索尼 Alpha | BLE `8000EE00` 配对 + 凭据 | ISO 15740 PTP/IP :15740 | `0x9209` / `0x9205` / `0x9207` | [04](docs/protocol-reports/04-sony-alpha.md) |
| 5 | 佳能 EOS | BLE `0001xxxx-d8492fffa821` | ISO 15740 PTP/IP :15740 | EOS 属性码 + `0x9114`/`0x9115` | [05](docs/protocol-reports/05-canon-eos.md) |
| 6 | 富士 X | BLE XApp GATT（老协议 / RED） | 私有 PTP-IP :55740/55741/55742 | PTP 操作码 + 属性码 | [06](docs/protocol-reports/06-fujifilm-x.md) |
| 7 | 尼康 Z | BLE SnapBridge + LSS 认证 | ISO 15740 PTP/IP :15740 | 取景 `0x9201` / 快门 `0x9207` | [07](docs/protocol-reports/07-nikon-z.md) |

总览与横向对照见 [`docs/protocol-reports/00-overview.md`](docs/protocol-reports/00-overview.md)。

> 本仓库是公开版本：**不包含** `server/`（信令、日志接收、LUT 市场后端）与服务端脚本，所有服务端地址已替换为占位符 `https://your-server.example.com`；赞赏二维码资源与相关页面片段已移除。相机协议部分（BLE / PTP-IP / HTTP）不依赖任何自建服务端。

## 已实现

- 响应式首页：小窗口使用底部悬浮导航，`840vp` 以上切换为侧栏与多列内容。
- 作品库：读取授权图库、系统照片选择器、示例作品和编辑器入口。
- LUMIX 连接：连接相机 Wi-Fi 后，通过局域网地址探测 Panasonic `cam.cgi` 状态端点。
- 传输中心：RAW + JPEG 队列、进度与后台任务信息界面。
- LUT 库：内置 LUMIX 风格与通用调色预设；支持通过鸿蒙文档选择器导入 `.cube/.3dl/.look`，解析为可复用的无损调色预设，支持删除自定义 LUT 并用 Preferences 持久化。
- 专业编辑器：基础光效与色彩、带可添加/删除/拖动锚点的 RGB/主通道曲线、色温/色调/饱和度/鲜艳度彩色滑轨与三角指示、八色 HSL 混色、相机原色色准、真实像素裁剪/旋转/翻转、会话内完整保留笔迹的画笔/线性/径向蒙版、叠加式调整图层、直方图、前后对比、完整撤销/重做及 JPEG 导出。
- 桌面工作台：素材胶片栏、中央画布、浮动工具条和右侧显影检查器。
- 手机工作台：不遮挡照片的上下分区画布、胶囊形液态玻璃底栏和可滚动工具卡片。
- 原生动效：主工作区使用 ArkUI `Particle` 粒子系统生成低干扰的环境光粒子。

## 运行

1. 在 DevEco Studio 中打开本目录。
2. 等待工程同步完成。
3. 选择 `entry` 模块和已签名的本地设备/模拟器。
4. 点击 Run。首次启动时可授权图库读取；也可以拒绝并使用内置演示素材。

当前工程使用 HarmonyOS 26.0.0 / API 26 作为目标 SDK，最低兼容 API 23。首页和编辑器底栏在支持设备上使用原生 Tabs 悬浮材质，通用调节滑动条使用系统沉浸光感与粒子动画；旧系统或不支持材质的设备使用毛玻璃回退。普通内容卡片位于系统材质支持区域之外，统一使用 backgroundBlurStyle，避免将无效的 systemMaterial 当作原生折射效果。背景粒子在应用退到后台时停止。

## 相机连接说明

进入“相机”页前，请先在系统网络设置中连接 LUMIX 创建的 Wi-Fi。默认地址为 `192.168.54.1`，可以在界面中修改。不同机型和固件开放的控制能力不同：当前适配器先进行只读状态探测，只有探测成功后才应继续扩展遥控拍摄、缩略图索引和原片下载命令。

USB 连接按 Panasonic Lumix Remote Control Library 示例的顺序执行：枚举并筛选 Still Image/PTP 接口，调用系统 `requestRight` 请求 USB 访问授权，设置配置并占用接口，发送标准 `OpenSession`（会话 1），再发送 LUMIX 专用 `LumixOpenSession`（操作码 `0x9102`，参数 `0x00010001`）完成 SDK 会话授权，读取包含 DATA 与 RESPONSE 的 `GetDeviceInfo` 事务，关闭时先发 `LumixCloseSession`（`0x9103`）再发 `CloseSession` 并释放接口。首次 USB 连接前请在相机中完成蓝牙配对，并将 `[USB > USB 模式]` 设为 `LUMIX Lab`。官方 `Lmxptpif.dll` 是 Windows 库，HarmonyOS 版本使用 `usbManager` 直接传输 PTP 容器。

核心入口：

- `entry/src/main/ets/pages/Index.ets`：产品主界面和四大工作区。
- `entry/src/main/ets/pages/EditorPage.ets`：编辑会话、导出和响应式外壳。
- `entry/src/main/ets/views/TabletLayout.ets`：桌面/2in1 三栏工作台。
- `entry/src/main/ets/views/PhoneLayout.ets`：手机与窄窗口编辑器。
- `entry/src/main/ets/services/LumixCameraService.ets`：Panasonic 局域网连接适配器。
- `entry/src/main/ets/edit/`：图像处理、调整、预设、图层与蒙版引擎。
