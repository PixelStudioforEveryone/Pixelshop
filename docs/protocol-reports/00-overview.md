# 00 总览：五品牌、七条线路的蓝牙配对 / Wi-Fi 传输 / 相机控制

> [English](en/00-overview.md) | 简体中文

基线提交 `18466be`（Vivid / 像素工坊）。本目录按**协议线**而不是按品牌撰写：
同一台松下机身可能落在三条线中的一条，而索尼、佳能、尼康、富士各一条。
每条线单独一份报告，本文件只做横向对照与索引，不重复细节。

| # | 线路 | 机型范围（代码判定） | 蓝牙在链路里的角色 | Wi-Fi 传输 | 控制面 |
|---|------|----------------------|--------------------|------------|--------|
| 1 | [松下 LUMIX Lab](01-panasonic-lumix-lab.md) | `S5M2X S5M2 S1RM2 S1RII S1M2E S1IIE S1M2 S1II S9 GH7 G9M2 G9II L10` | GATT 注册 + 读 AP 凭据（共享 `LumixImportPrototype`，主服务 `1fe71b85`） | HTTPS `/remote/*` + `/lut/*`；取景为 UDP + DTLS 1.2 | `camcmd` / `set-setting` / `get-state` / `camctrl` |
| 2 | [松下 LUMIX Sync](02-panasonic-lumix-sync.md) | `S1H S1R G100D G100 GH5M2 GH6 GH1` | GATT 注册下发凭据（服务 `054ac620`），十特征通知 | HTTP `cam.cgi`；图像走机身 DLNA/DMS :60606 | `cam.cgi` + `X-SESSION_ID`；`startstream` 明文 UDP（手机侧 1210） |
| 3 | [松下 Image App](03-panasonic-image-app.md) | GH5/GH5S/G9、GX/TZ/FZ/LX/GM 等老机身 | **无蓝牙**：手工选 AP（官方另有二维码/NFC） | HTTP `cam.cgi` + DLNA/SSDP | 以只读探测为主，老世代命令 |
| 4 | [索尼 Alpha](04-sony-alpha.md) | Alpha / Cinema Line / ZV / RX 等 26 条机型 token | 私有配对服务 `8000EE00`，控制服务 `8000CC00` 读 SSID/密码 | ISO 15740 PTP/IP，TCP :15740（与尼康共用传输层） | `0x9209` 读自述属性、`0x9205` 写值；取景与快门都在 `0x9207`，画面来自 HTTP :60152 |
| 5 | [佳能 EOS](05-canon-eos.md) | 95 条 pid 机型表（R5/R6 II/R1…） | 私有 GATT `0001xxxx-…-D8492FFFA821`：绑定 → 注册 → WAP 交接 | ISO 15740 PTP/IP，两条 TCP :15740 通道 | EOS 属性 `0x1015`/`0x9110`、`0x1014` 描述符、`0x9128` 快门；**未采用 CCAPI** |
| 6 | [富士 X](06-fujifilm-x.md) | X 系列（老协议 / RED 两代） | XApp 私有 GATT：把广播里的 key 写回、读 SSID/密码、功能拉起 | **私有 PTP-IP**：TCP :55740 控制 / :55741 取景 / :55742 事件，12 字节包头 | PTP 操作码 + 私有属性码；取景 JPEG 偏移 `LE32@12 + 18` |
| 7 | [尼康 Z](07-nikon-z.md) | Z 系列 14 条机型表 | SnapBridge `0000DE00-3DD4-4255-8D62-6DC7B9BD5561` + LSS 四阶段认证 | ISO 15740 PTP/IP，TCP :15740 | `0x90C2` 接管、`0x9201/0x9202/0x9203` 取景、`0x9207` 快门、属性 `0x1014/0x1015/0x1016` |

## 1. 七条线共享的三条规律

### 1.1 蓝牙只负责"进门"，从不搬数据

除富士的取景与控制仍走 TCP 之外，其余六条线的 BLE 只做三件事：识别机身、登记客户端身份、
把 SSID/密码交到手机。像素、缩略图、实时取景全部走 Wi-Fi。这不是设计偏好，而是机身固件如此：
佳能 BLE 表里没有任何媒体特征（`CanonProtocol.ets:189-233`），尼康 BLE 只写一个连接配置块
（`NikonLssProtocol.ets:23-30`），松下的 SSID/密码两个特征都是 read（`LumixImportPrototype.ets:344-378`）。

由此派生出两条实现纪律：

- **BLE 失败不等于相机不可用**。三条松下线的 BLE 注册都是 best-effort；Lab 线注册失败仍继续
  `/auth`（`LumixControlService.ets:1125`），佳能扫描失败只影响佳能卡片（`CanonBleService.ets:276-296`）。
- **凭据只在该次会话内有效**。松下的密码随 AP 重启变化，富士的密码读失败即断开且不落库
  （`FujifilmBleService.ets`），尼康的 LSS 会话密钥不持久化（`NikonLssSession.ets`）。

### 1.2 Wi-Fi 上只有两个家族

| 家族 | 线路 | 形态 | 事务模型 |
|------|------|------|----------|
| HTTP | 松下三条线 | `cam.cgi` 查询串 / `/remote/*` JSON 信封 / DLNA SOAP | 一问一答，会话令牌或 `X-SESSION_ID` |
| PTP/IP | 索尼、佳能、尼康（标准 15740）＋ 富士（私有 5574x） | 二进制包头 + 操作码 + 数据阶段 | 事务 ID 配对，事件通道常驻 |

PTP/IP 家族内部也有分叉：索尼与尼康共用同一个 `NikonPtpIpService` 单例，佳能自己一份
（`CanonPtpIp.ets`，双通道 + `SetRemoteMode`/`SetEventMode`），富士连端口和包头长度都改过。
把"PTP/IP"当成一个协议会踩坑——`CameraControlBrand.isPtpIpProtocol()` 就明确把富士排除在外
（`CameraControlBrand.ets:101-108`）。

### 1.3 能控什么，由机身自述决定

- 索尼：参数、可选值与可写性全部来自 `0x9209` 的 `formFlag-2` 记录，代码不维护映射表
  （`SonyPtpIpControl.ets`）。真机 ILCE-7M4 的曝光模式是 `opt0:ro`，面板能显示但点不动。
- 佳能：`0x1014` 描述符先探，再决定 14 项 EDSDK 属性里哪些可读可写（`CanonControlService.ets`）。
- 尼康：同样走 `0x1014` 描述符探测，覆盖 6 个面板；`CameraControlBrand` 里那份"尼康 12 面板不可用"
  的旧清单在该路径上已失效（见 07 报告 §9 的注释/实现冲突清单）。
- 松下：Lab 线有 `get-setting` 参数域与 `get-state` 33 字段回读；Sync/Image App 线靠 `cam.cgi` 的
  `getsetting`/`getstate`，能力随固件裁剪。

## 2. 配对要点速查

| 线路 | 广播识别 | 配对动作 | 凭据读取 |
|------|----------|----------|----------|
| 松下 Lab | 厂商 ID 58（6 字节承载蓝牙地址）+ 本机名末两字节机型码 `0x0A+1..9` | 写 `APP_UUID`（异或编码）→ `APP_INFO` → `FRIENDLY_NAME` → `PAIRING_INIT=0x02` → `ACTION_MODE=0x01` | `WIFI_SSID` / `WIFI_PASSWORD` 两个 read 特征 |
| 松下 Sync | 服务 `054ac620`；机型码同样在名字末两字节 | 16 字节 MEI0 身份（APS 机型先读 `INITIAL_INFORM` 取会话密钥）→ 名字 → 等 AP 就绪 | `e206a5c0` SSID 列表 / `c97cf1a5` 密码（长度字节在前，XOR） |
| 松下 Image App | 无 BLE | 无（用户手工入网） | 无（密码由机身屏幕给出） |
| 索尼 | 公司 ID `0x012D` + `03 00` 标记 + tag 33/34/35 能力位 | 系统 bond 后写 `EE01 = {6,8,1,0,0,0,0}`，等 `EE03` 状态 | 写 `CC08={1}` 开 Wi-Fi，读 `CC06/CC07/CC0C`（3 字节头） |
| 佳能 | 公司 ID 425、`[0]==1`、19B/6B 两种厂商数据 | bond（10/11/12 归一）→ 注册帧 `01`+昵称 → `0A 01/02` | WAP 交接：`04 09…` + TLV（`0x10` IP / `0x02` BSSID） |
| 富士 | 公司 ID `0x04D8`、`mf[0]=1`(RED)/`2`(老协议) | 把广播里的 key 原样写回 `ABA356EB`；RED 另写 `F557D96B` 与 `8B5ECF55` | `BF6DC9CF` SSID / `E809256A` 密码（UTF-8 到 `0x00`） |
| 尼康 | SnapBridge 服务 UUID / Z 机型表 / 名字正则三路准入 | LSS 四阶段：`[stage][nonce8][deviceId8]`，Blowfish 解密凭据块 | 连接配置块：flag + SSID 32 + 密码 64 + security + sppMaxDataLength |

三条容易写错的细节：

1. 松下 Sync 的 `req_acc` 才是注册提交，第一次回 `ok_under_research`，约 1 s 后重发才回 `ok`，
   且提交后要留十几秒静默期（官方 19 s / 34 s），本实现曾用 2 s 被相机立即拒绝
   （`LumixSyncControlService.ets:31-52`）。
2. 索尼的配对成功以**系统 bond 状态**为准，不是 `EE03` 通知——ILCE-7M4 上机身显示配对成功，
   `EE03` 一个通知都不发（`SonyBleProvisioning.ets:596-621`）。
3. 尼康写 `0x2005=[1]` 之后必须先彻底释放蓝牙（RFCOMM 客户端/服务端、可发现、GATT），
   相机热点才会出现（`NikonBleProvisioning.ets`，见 07 报告 §6）。

## 3. 证据等级

七份报告使用同一套标注：

- **事实**：能直接落到 `文件:行号` 的代码/常量/注释，或仓库内已有的抓包与反编译记录。
- **推断**：有依据但未上真机验证，逐条写明依据与回退方案。
- **代码未标注**：UUID 或字段在源码里出现但注释没写用途，照实标注，不补猜。

方法上有两点限制，读者需要知道：

1. 本仓库的逆向结论来自官方客户端的反编译与真机抓包，报告只转述代码里已固化的事实，
   没有在这次写作中重新抓包或重新反编译。
2. 报告里的"官方"指代码注释记录的官方 APK（LUMIX Lab / LUMIX Sync / Image App / Creators' App /
   Camera Connect / XApp / SnapBridge）版本，不是本次重新获取的版本。

## 4. 安全与隐私边界

- 本仓库是公开版本：不包含 `server/`（信令、日志接收、LUT 市场后端）与服务端脚本，
  代码里的服务端地址已替换为占位符 `https://your-server.example.com`。
- 相机 Wi-Fi 密码、LSS 会话密钥、客户端 UUID 都属于运行时数据；各报告在"限制与风险"一节
  逐条标出了**当前实现与注释承诺不一致**的地方，例如松下 Sync 线的明文密码落库
  （`LumixSyncControlService.ets:1769-1782`）与会话密钥写 hilog（`:1857-1859`）。
  这些是待修项，不是设计意图。

## 5. 阅读顺序建议

先读本文件，再按需要跳转：

- 只关心"手机怎么连上相机"：读各报告的 §2（配对）与 §3（传输）。
- 要做跨品牌统一控制层：读 04（索尼）§6 与 05（佳能）§7，两家的"机身自述能力"模型最完整。
- 要复现某条线的握手：每条报告末尾都有"实现对照表"与"待真机确认"，按类名即可定位源码。
