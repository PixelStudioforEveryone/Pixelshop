# 松下第三条线：LUMIX Image App / Lumix Link 世代（无蓝牙）

- 工程：Vivid（ArkTS，`C:\Users\HQ\DevEcoStudioProjects\VIVID`）
- 基线提交：`18466be`（调色颜色面板加入自动/手动白平衡）
- 方法：只读代码与文档，不运行设备、不改代码
- 覆盖文件：`LumixCameraService.ets`、`LumixImportPrototype.ets`、`PanasonicS5Receiver.ets`、`LumixSyncImageTransfer.ets`、`LumixSyncControlService.ets`、`CameraWifiPasswordPolicy.ets`、`CameraSessionStore.ets`、`CameraPage.ets`
- 约定：路径省略 `entry/src/main/ets/services/`（页面文件为 `entry/src/main/ets/pages/...`）；行号对应基线；凡代码未实现而只由注释记载者，明确标注；凡由代码结构推出而未经实机验证者，标注「推断」

## 1. 结论摘要

1. 本线是松下三条线中唯一没有蓝牙配对的世代：入网凭据由用户手工提供（相机屏幕上显示的 AP 密码），代码中不存在二维码与 NFC 实现（`LumixCameraService.ets:340-371` 仅记载官方 App 具备该三种入网方式）。
2. 线路判定完全由机型 token 表加兜底正则决定，不依赖 BLE 广播：`panasonicRouteForModel()` 先比 Lab 表、再比 Sync 表，最后落 `isPanasonicImageModel()`（`LumixCameraService.ets:1766-1831`）。
3. 老世代没有相机侧反向的 BLE 注册，因此 `needsBlePairing('lumix_image')` 恒为 false（`LumixCameraService.ets:1866-1873`）；一旦把本线机型送进 BLE 配准流程就必然卡死。
4. 手机侧「发现」有两种形态：作为客户端向外发 SSDP M-SEARCH（MediaServer:1），以及作为 DMS 自己应答 M-SEARCH 并周期发 NOTIFY（`LumixCameraService.ets:2356-2382`、`PanasonicS5Receiver.ets:736-819`）。
5. 控制面只读探测链固定为 `getstate/keep_alive` → `getinfo/capability` → `getinfo/allmenu`，用返回体长度挑载荷，`err_*` 一律不计为应答（`LumixCameraService.ets:2149-2206`）。
6. 图片通道是机身内建 DLNA MediaServer（`:60606/Server0/CDS_control`）上的 SOAP Browse + DIDL-Lite 解析 + res URL GET（`LumixSyncImageTransfer.ets:23-26`、`:103-177`）。
7. 反向通道（相机推到手机）只在 imageApp 线启用：手机监听 `50000`（必需）与 `49152`（可选），先 `accctrl/req_acc` 再亮出本机 DMS，随后由相机发起 `GET /dms/ddd.xml`、`X_GetDLNAUploadProfiles`、`CreateObject` 与 chunked 上传（`PanasonicS5Receiver.ets:80-108`、`CameraPage.ets:6589-6724`）。
8. 该线的图片页处于「被动推送」模式，不启动 DMS 主动浏览：`syncPush=true`、`syncPull=false`（`CameraSessionStore.ets:141-151`、`CameraPage.ets:2269-2279`）。
9. 老机型 `accctrl` 授权可能只回 4 个字段、不给 `X-SESSION_ID`，此时所有 cam.cgi 请求不带该头、授权只靠源 IP 维持，并按约 60 秒窗口重发 `req_acc`（`LumixSyncControlService.ets:1037-1047`、`:1994-2002`）。
10. 主要风险：机型表与 SSID 识别表覆盖面有限、UI 上「相机控制」入口对本线实际不可达、权限申请结果未被校验、端口与后台监听受系统限制。

## 2. 线路定位

### 2.1 三条线如何分区

三张 token 表按「高优先集合减去低优先集合」构造，保证互斥（`LumixCameraService.ets:240-401`）：

| 线 | 表 | 定位 |
| --- | --- | --- |
| `lab` | `PANASONIC_LAB_MODEL_TOKENS`（`:302-303`） | LUMIX Lab 世代，BLE 广播携带紧凑机型码 |
| `sync` | `PANASONIC_SYNC_MODEL_TOKENS`（`:336-338`） | LUMIX Sync 世代，BLE 配对下发 Wi-Fi 凭据 |
| `lumix_image` | `PANASONIC_IMAGE_MODEL_TOKENS`（`:372-401`） | Image App / Lumix Link 2.0 世代，无蓝牙 |

减法本身有实机依据：GH5/GH5S/G9 在 2026-10-11 从 Sync 线移到本线，理由是官方 Image App 支持表列有这三台、三台都没有蓝牙电台，而 Sync 线入口是 BLE 门控的（`LumixCameraService.ets:326-335`）。ZS300/TZ300 是唯一被主动摘出的机型：同一台机身两个区域名，由 Sync 线的 `isWifiOnlyModel()` 认领（`:361-363`）。G97/GH3 的官方支持表早于这两台，但 Lab 与 Sync 源码均零命中，因此留在本线作唯一归档（`:365-366`）。

### 2.2 为什么这条线没有 BLE

`LumixCameraService.ets:340-371` 的原始结论（照录要点）：

- 「Image App 1.9.0（Lumix Link 2.0）contains no Bluetooth code at all — zero hits for BluetoothAdapter/BluetoothGatt/BLE across the Java sources, smali, resources, the manifest and every native library.」
- 「That generation provisions Wi-Fi by hand (an unfiltered AP list the user picks from), by QR code (MDL/SSID/PW/CRYPT/DeviceID) or by NFC, discovers the body over SSDP and then speaks cam.cgi plus DLNA.」
- 「Neither LUMIX Lab nor LUMIX Sync mentions any of these tokens」。
- 争用检查（2026-10-11）：Lab 反编译源码对该表零字面量；Sync 全源码只出现 DC-GH5/DC-GH5S/DC-G9，且全部是继承自 Sync 之前代码库的 UI/菜单值特例，并非支持表（`:352-359`）。

结论落到代码：`needsBlePairing(route)` 只对 `lab`/`sync` 返回 true（`:1866-1873`），调用方据此把本线挡在 BLE 配对与 GATT 注册之外。

### 2.3 判定谓词与兜底

- 未知身份的通用 LUMIX 卡不猜线路：`compactIdentity` 为 `LUMIX`/`PANASONIC`/`PANA` 时返回 `''`（`:1769-1772`）。
- 只要身份串里出现 Lab token 即判 `lab`；原始 S5 一律 `sync`（`:1787-1792`）。
- BLE 观察到但不在 Lab 表的松下机身一律判 `sync`（`:1793-1797`）。
- 本线是最后兜底：先比 token 表，再对任何松下形状的串（`/^(?:DC|DMC|LUMIX|PANASONIC|PANA)[-_ ]?[A-Z0-9]+$/`）判真（`:1809-1831`）。这意味着「机型表未收录的松下机身」也归本线，而不是报未知。
- 两条 cam.cgi 线共用同一套协议，UI 判定统一走 `isCamCgiRoute()`（`:1854-1864`），需要区分时用 `isSyncRouteSelected()` / `isImageAppSelected()`（`CameraSessionStore.ets:101-143`）。

### 2.4 三线对照

| 维度 | `lab` | `sync` | `lumix_image`（本报告） |
| --- | --- | --- | --- |
| 入网凭据来源 | BLE GATT 注册后下发 | BLE 配对后下发 | 用户手输（相机屏幕显示） |
| 是否有蓝牙腿 | 有 | 有 | 无 |
| 发现 | 相机 AP + Lab REST | 相机 AP + cam.cgi | SSDP + cam.cgi + DLNA |
| 控制面 | Lab REST | cam.cgi | cam.cgi（入口实际关闭） |
| 图片面 | Lab gallery REST | DLNA/DMS 主动拉取 | 相机反向推送为主 |
| 路由证据 | `LumixCameraService.ets:302-303` | `:336-338` | `:372-401` |
| 谓词 | `needsBlePairing` 真 | `needsBlePairing` 真 | `needsBlePairing` 假（`:1871-1873`） |

## 3. 入网方式

### 3.1 手工选 AP

实际实现只有这一条路径（`CameraPage.ets:6555-6574` → `:4350-4434`）：

1. 打开页面即请求 Wi-Fi/定位权限并确保射频开启（`CameraPage.ets:4246-4260`、`LumixCameraService.ets:1883-1887`）。
2. `scanForCameras()` 先 `startScan()`（旧 SDK 退回 `scan()`），等 900 ms，再读 `getScanInfoList()`（旧 SDK 退回 `getScanResults()`），逐个走 `identifyWifiSsid()`，并按 RSSI 降序（`LumixCameraService.ets:1889-1942`）。
3. 若手机已关联的 SSID 就是所选相机，直接复用该热点，不再发扫描（`CameraPage.ets:4367-4399`）。
4. 未自动命中时弹候选列表让用户挑（`:4428-4430`），确认后进入 `connectCameraWifi()`（`:4530-4676`）。
5. 加入方式：先查系统已存配置；能复用就复用 `netId`；否则删掉同 SSID 的旧记录、`addCandidateConfig()` 后 `connectToCandidateConfig()`（SDK≥26 带 `withUserAction` 与 30 秒超时；SDK 20–25 用 `connectToCandidateConfigWithUserAction`）（`LumixCameraService.ets:1986-2046`）。
6. 加入成功的判据不是「信任弹窗已关闭」，而是 30 次 × 500 ms 轮询 `getLinkedInfo()` 且 SSID 精确匹配（`:2047-2056`、`:2079-2085`）。失败次数上限为「一次复用已存密钥 + 一次显式输入」两次（`:1996-2072`）。

失败语义（每条都对应独立中文提示，便于用户自查）：

- `2501005`：系统信任确认超时（`:2063`）。
- `2501006`：用户在系统弹窗上取消（`:2064`）。
- 复用已保存密钥失败且允许输入：清空密码、置「已保存的连接未能成功，请核对相机当前显示的 Wi-Fi 密码」并要求重输（`:2065-2069`）。
- 非受保护网络失败：提示确认热点仍开启并完成系统信任确认（`:2070-2071`）。
- 任一异常（权限、系统拒绝）：统一回「无法切换到相机 Wi-Fi」（`:2074-2076`），此时要结合 `VIVID_WIFI` 日志里的 `security`/`reused`/`attempt` 三项定位（`:2031-2033`）。

### 3.2 SSID 形态与默认网关

- 相机 AP 名形态为「机型 token + `-`/`_` + 实例后缀」：`matchesPanasonicName()` 用 `^<token>[-_][A-Z0-9]{3,}(?:[-_][A-Z0-9]+)*$`，带厂商前缀时允许 `LUMIX|PANASONIC|PANA|DC|DMC|CAMERA` 前缀（`LumixCameraService.ets:522-530`）。ZS300/TZ300 另有锚定形态 `^(?:ZS|TZ)300-[A-Z0-9]{6}$`（`:498-507`）。SSID 大小写敏感、内部空格与完整后缀都要保留，仅去掉外层引号（`CameraWifiPasswordPolicy.ets:31-36`）。
- 主机地址从不硬编码，一律取 DHCP 网关：`wifiManager.getIpInfo().gateway` 按网络字节序拆成十进制点分（`LumixCameraService.ets:1954-1968`）。相机 AP 就是默认路由，因此网关即相机 HTTP 端点。网关为空时各入口都直接失败而不是退回猜测地址（`:2215-2218`、`:2283-2286`、`CameraPage.ets:6612`）。
- `LumixImportPrototype.selectHost()` 也是同一原则：网关优先，`hostOverride` 仅作显式覆盖（`LumixImportPrototype.ets:4223-4237`）。

### 3.3 密码策略

`CameraWifiPasswordPolicy`（`CameraWifiPasswordPolicy.ets:1-37`）只处理个人热点，企业/证书网络要求用户去系统设置：

- 支持类型：`OPEN=1`、WEP=2、WPA/WPA2=3、WPA3=4、OWE=7；其余直接拒绝并给中文提示（`:8-14`）。
- 需要密码的类型：除 1 与 7 之外都算（`:3-6`）。
- WEP：5 或 13 个可打印 ASCII，或 10/26 位十六进制（`:18-23`）。
- WPA/WPA2：至少 8 字符；上限 63 字符，允许 64 位十六进制 PSK（`:24-27`）。
- 禁止换行与控制字符（`:17`）。
- 老世代相机屏幕上显示的密码由用户读入：`requestPassword` 回调弹输入框，输入非法时把校验文案回显并要求重输（`LumixCameraService.ets:2002-2009`、`CameraPage.ets:4468-4479`）。

### 3.4 二维码与 NFC

代码中没有二维码扫描、也没有 NFC 读写实现：全工程检索 `MDL`/`CRYPT`/`nfc` 只命中 `LumixCameraService.ets:347` 这一行注释。也就是说，`MDL/SSID/PW/CRYPT/DeviceID` 这组字段只作为「官方 Image App 支持二维码入网」的文献证据存在，Vivid 侧未实现对应解析，也未实现 NFC 触碰入网。

结论：本线当前唯一的入网路径是 3.1 的手工 AP 列表（或复用系统已保存的该相机热点）。二维码/NFC 若要落地，属于待开发能力而非既有实现。

## 4. 设备发现（SSDP / DMP）

### 4.1 手机向相机发 M-SEARCH（DMP 探测）

`sendS5DmpSearch()`（`LumixCameraService.ets:2356-2382`）的实际报文：

```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 2
ST: urn:schemas-upnp-org:device:MediaServer:1
```

- 本地绑定 `0.0.0.0:0`（随机源端口，family=1），发往 `239.255.255.250:1900`（`:2362`、`:2368-2371`）。
- 是否需要应答不是判据：官方抓包里相机会回应，但部分固件在已连接的 datagram socket 上不回包、仍会完成状态迁移，因此只等 350 ms 就关 socket，仅记录 `reply=0/1`（`:2297-2302`、`:2372-2376`）。
- 关键反例记录在代码里：把该报文直接发到 `60606` 会让 S5 固件停在「Wi-Fi 已连接」页，必须发到标准 SSDP 组播地址（`:2363-2367`）。

### 4.2 相机侧 DMP 描述符

`requestS5DmpBrowse()`（`:2281-2312`）按官方顺序做「读描述符 → M-SEARCH → 再读描述符」：

- 端口顺序 `60606`（原生抓包）→ `49320`（旧固件兼容）（`:2287-2292`）。
- 描述符 URL 为 `http://<gateway>:<port>/Lumix/Server0/ddd`，带 `User-Agent: Panasonic Android/1 DM-CP` 与显式 `Host` 头，连接 3 s / 读 5 s（`:2314-2329`）。
- 判定：两次读里任一为 2xx 且 body 非空即为 true（`:2305-2306`），且此步失败不阻断后续鉴权（`:2277-2279`、`CameraPage.ets:6617-6620`）。
- 不能在此处发 Browse：抓包里 Browse 属于握手之后的操作，提前发会让 S5 回 500 并挡住 `req_acc`（`:2273-2279`）。
- 授权成功后再按 2 s / 3 s / 5 s 三次补发 M-SEARCH，给相机多几次跑状态机的机会（`:2338-2354`）。

### 4.3 手机作为 DMS 的发现响应

`PanasonicS5Receiver.startSsdp()`（`PanasonicS5Receiver.ets:736-763`）：

- 先尝试绑定 `1900`；被占用则退到临时端口，仅保留发包能力（`:743-750`）。
- 就绪后立刻发 `ssdp:alive`，此后每 1500 ms 重发；`stop()` 时先发 `ssdp:byebye` 再关 socket（`:753-756`、`:195-202`）。
- NOTIFY 目标集：`uuid:<clientUuid>`、`urn:schemas-upnp-org:device:MediaServer:1`、`upnp:rootdevice`、`urn:schemas-upnp-org:service:ContentDirectory:1`、`urn:schemas-upnp-org:service:ConnectionManager:1`；alive 包带 `CACHE-CONTROL: max-age=1800`、`LOCATION: http://<localIp>:<controlPort>/dms/ddd.xml`、`SERVER: Android/1 UPnP/1.0 Panasonic-DM-SV/1`；byebye 包刻意不带 LOCATION 与缓存头（`:765-799`）。组播失败时改向相机网关单播同一包（`:775-776`、`:791-796`）。
- 应答 M-SEARCH 的匹配规则（`:801-819`）：`ST` 必须等于 `ssdp:all`、`upnp:rootdevice`、`uuid:<clientUuid>`，或以 `urn:schemas-upnp-org:device:mediaserver:`、`...:service:contentdirectory:`、`...:service:connectionmanager:` 开头；其余一律不应答。应答含 `EXT`、`BOOTID.UPNP.ORG: 1`、`CONFIGID.UPNP.ORG: 1`（`:812-814`）。

### 4.4 本机 DMS 暴露的路径

`xmlForPath()` 决定相机 GET/HEAD 时回什么（`PanasonicS5Receiver.ets:869-883`）：

| 请求路径包含 | 返回 |
| --- | --- |
| `/`、`description`、`rootdesc`、`desc.xml`、`/ddd.xml` | 设备描述（MediaServer，含 ContentDirectory 与 ConnectionManager 两个 service） |
| `/sdd_1.xml`、`/sdd_2.xml`、`connectionmanager` | ConnectionManager SCPD（`GetProtocolInfo` 等三项） |
| `contentdir`、`contentdirectory`、`cds`、`scpd`、`/sdd_0.xml` | ContentDirectory SCPD（含 `X_GetDLNAUploadProfiles`、`CreateObject`、`Browse`） |
| 其他 | 404（`:371-373`） |

补充三点：

- GET/HEAD 命中时用 DMS 专用应答（带 `CONTENT-LANGUAGE: ja` 与 `CONNECTION: close`），未命中回纯文本 404（`:367-374`、`:836-846`）。
- `POST` 不做路径校验：任何 POST 都进入同一个 SOAP action 分派（以 `SOAPAction` 里的 action 名为准）（`:382-392`、`:438-476`）。因此 `/dms/control_1` 与 `/dms/control_0` 在本实现里同义（推断：官方只在 `control_0` 上发 SOAP，故未按路径分流）。
- `SUBSCRIBE` 回 `SID: uuid:<clientUuid>` + `TIMEOUT: Second-1800`，`UNSUBSCRIBE` 回空 200（`:377-381`、`:860-867`）。前 8 字节不是已知 HTTP 方法时按裸流落盘，避免个别固件的私有封装被丢掉（`:270-279`）。

## 5. cam.cgi 控制面

### 5.1 只读探测链

`probe(host)`（`LumixCameraService.ets:2136-2206`）按固定顺序 GET：

| 序 | endpoint | 说明 |
| --- | --- | --- |
| 1 | `/cam.cgi?mode=getstate&type=keep_alive` | 存活 |
| 2 | `/cam.cgi?mode=getinfo&type=capability` | 能力表 |
| 3 | `/cam.cgi?mode=getinfo&type=allmenu` | 菜单快照 |

- 只接受 2xx；含 `err_` 的体既不算「有应答」也不参与机型解析，避免把错误 XML 当成 payload（`:2161-2170`）。
- payload 取三者中**最长**的返回体（`:2168-2170`）；机型从 `<model>/<name>/<product>/<serial>` 依次取，最后退回 `DC-[A-Za-z0-9]+` 正则（`:2409-2417`）。
- 机型查表 `lookupModel()` 先精确、再「键包含于值」、最后「值包含于键且长度≥3」的反向匹配（`:2419-2442`）。
- 全部端点无应答 → 中文提示「未找到相机，请先连接相机创建的 Wi-Fi」（`:2173-2182`）；有应答但机型未收录 → 仍返回 connected，族别标「未收录型号」（`:2198-2205`）。
- 代码明确记录不探 `getinfo&type=model`：官方客户端从不传变量 type，且协议错误体也会被当成应答（`:2149-2154`）。

### 5.2 常用命令表

以下均为 GET，参数一律走 `value=`（`mode=camcmd` 的 verb 放 `type=` 会得到 `err_param`，`LumixSyncControlService.ets:1094-1101`）：

| 用途 | 请求 | 出处 |
| --- | --- | --- |
| 访问授权（注册提交） | `/cam.cgi?mode=accctrl&type=req_acc&value=<uuid>&value2=<name>` | `LumixSyncControlService.ets:926`、`LumixCameraService.ets:2224` |
| 切到回放（浏览图库前） | `/cam.cgi?mode=camcmd&value=playmode` | `LumixSyncImageTransfer.ets:1084` |
| 归还遥控权 | `/cam.cgi?mode=camcmd&value=recmode` | `LumixSyncImageTransfer.ets:1231-1236` |
| 图库/推送模式 | `/cam.cgi?mode=camcmd&value=pictmode` | `LumixCameraService.ets:2237-2269`（当前无调用方） |
| 触屏对焦等控制 | `/cam.cgi?mode=camctrl&type=<type>&value=<value>[&value2=]` | `LumixSyncControlService.ets:1151-1189` |
| 单项设置写入 | `/cam.cgi?mode=setsetting&type=<type>&value=<value>` | `LumixSyncControlService.ets:1406-1439` |
| 单项设置读取 | `/cam.cgi?mode=getsetting&type=<type>` | `LumixSyncControlService.ets:1488-1500` |
| 当前菜单 | `/cam.cgi?mode=getinfo&type=curmenu` | `LumixSyncControlService.ets:1559-1572` |
| 镜头信息 | `/cam.cgi?mode=getinfo&type=lens` | `LumixSyncControlService.ets:1586-1598` |
| 实时取景开流 | `/cam.cgi?mode=startstream&value=<port>` | `LumixSyncControlService.ets:1191-1210` |
| 存储卡切换 | `/cam.cgi?mode=setsetting&type=current_sd&value=sd1`（或 `sd2`） | `LumixSyncImageTransfer.ets:1635-1642` |
| 设备名 | `/cam.cgi?mode=setsetting&type=device_name&value=<name>` | `LumixSyncControlService.ets:1085` |

应答有两种形态：`camrply` XML 包 `<result>ok</result>`，或 accctrl 的纯 CSV `ok,...`。`replyVerdict()` 先取 `<result>`，否则取首个逗号前的段，避免把 XML 头误判成失败（`LumixSyncControlService.ets:1246-1259`）。`err_busy` 按最多 5 次、每次 1 s 重试；`playmode`/`recmode` 的 `err_reject` 视为「已就位」的良性拒绝（`:1121-1141`）。

`setsetting` 的 `value` 必须原样拼进 URL、不能 `encodeURIComponent`：`-02/3` 被编码后相机回 `err_param`；`1/400` 这类快门值相机回 `ok` 却不生效，只有 `type` 才做编码（`LumixSyncControlService.ets:1434-1439`）。`focal` 的线上值是 `AV×256` 有理数而非 `F×256`（`:1421-1433`）。

### 5.3 鉴权

- `req_acc` 的 `value` 是客户端自身的 DLNA 身份（点分 UUID 形态），`value2` 是 DMS 友好名。S5 路径把 `value2` 固定为观测到的 `WEB-W00`，并在日志里注明「不是相机 SSID 或密码」（`LumixCameraService.ets:2219-2225`）。
- 老的 S5 路径只判 2xx 且不含 `err_reject|err_busy|err_unsuitable_app`（`:2228-2234`）；Sync 路径要轮询到 `ok`/`upload_bt`/`transfer` 前缀，`ok_under_research` 表示相机尚在确认、隔 1 s 重发，并记录第 5 个 CSV 字段为 `X-SESSION_ID`（`LumixSyncControlService.ets:936-1035`、`:1984-1988`）。
- 无 `X-SESSION_ID` 时的行为（关键）：请求头只在 sessionId 非空时添加（`LumixSyncControlService.ets:1997-2002`），DMS Browse 与下载同样如此（`LumixSyncImageTransfer.ets:130-131`、`:387-388`）。ZS300 这类机身 `req_acc` 只回 4 个字段、不给会话号，授权靠源 IP 维持并按时间过期：实测 req_acc 后 3 秒缩略图正常、75 秒后原图 GET 断连（http=0）、95 秒后 Browse 回落 403；因此下载/预览失败后先重发一次 `req_acc` 再重试，而不是盲目重试同一授权（`LumixSyncControlService.ets:1037-1047`、`LumixSyncImageTransfer.ets:1488-1496`）。
- 会话新鲜度有显式窗口（约 60 s），窗口内不发请求；缓存标记必须带时效，否则 `ensureControlSession` 短路会导致一次 `req_acc` 都不发（`LumixSyncControlService.ets:233-241`、`:274-291`）。

### 5.4 req_acc 应答语义

轮询实现把每种前缀映射成不同的后续动作（`LumixSyncControlService.ets:936-1034`）：

| 应答 | 处理 |
| --- | --- |
| `ok_under_research` | 相机还在确认，隔 1 s 重发；注册提交场景下若随后网络断开，视为提交成功（`:968-972`、`:957-959`） |
| `err_busy` | 最多重试 5 次、每次 1 s，之后报「相机忙」（`:973-980`） |
| `err_user_refused` | 相机屏幕上的确认框未点「允许」；默认重试 6 次并提示用户操作相机；控制模式后置刷新场景重试 3 次后按「已进入控制模式」继续（`:981-1015`） |
| `err_others_requesting` | 其它设备正在请求，直接失败（`:1016-1018`） |
| 其他 `err_*` / `ret_empty` | 直接失败并把首段回给用户（`:1019-1021`） |
| `ok` / `upload_bt` / `transfer` | 成功；第 5 个 CSV 字段作为会话号，并记录授权时间戳（`:1022-1029`） |

单次续期（不轮询、不抛错）用于下载/预览失败后的重试（`:1037-1047`、`:1048-1070`）。

## 6. 图像传输

### 6.1 DLNA/DMS 主动浏览（Sync 与 Image App 共用）

- 端点：`http://<gateway>:60606/Server0/CDS_control`，页大小 12（`LumixSyncImageTransfer.ets:23-25`）。
- 请求：POST + `Content-Type: text/xml; charset="utf-8"` + `SOAPAction: urn:schemas-upnp-org:service:ContentDirectory:1#Browse` + `User-Agent: Panasonic MIL DLNA CP UPnP/1.0`，带会话时附 `X-SESSION_ID`（`:120-132`）。
- SOAP 体：`Browse` / `BrowseDirectChildren` / `ObjectID=0` / `Filter=*` / `StartingIndex` / `RequestedCount` / 空 `SortCriteria` / `pana:X_FromCP=LumixLink2.0`（`:103-114`）。
- 反转义顺序照抄官方解析器：`&lt;` → `&gt;` → `&amp;` → `&quot;`（`:152-157`）。
- 分页游标按 `NumberReturned` 推进，与去重后的条目数解耦；`TotalMatches` 决定 `hasMore`（`:158-170`、`:1113-1118`）。
- 起始流程：确认 accctrl 会话 → 校准 SD 在位 → `playmode` → 等 800 ms → Browse(0,12)，失败再等 1500 ms 重试一次（`:1062-1101`）。
- 续拉流程：先 `ensureAccessGrantFresh`，若当前已不在 `playmode` 才补发（重复切模式会把 DMS 会话重入），切完等 300 ms，失败后退避 5 s（`:1150-1174`）。

### 6.2 DIDL-Lite 解析规则

单个 `<item>` 内可能有多条 `<res>`，按 `protocolInfo` 与扩展名分类（`LumixSyncImageTransfer.ets:203-301`）：

- 缩略图：`jpeg_tn` / `jpeg_sm` / `cam_tn` / `cam_sm` / `cam_lrgtn`（`:232-234`）。
- 视频：`video/`、`cam_avc`，或扩展名 mov/mp4/m4v（`:235-236`）。
- RAW：`cam_raw` / `cam_hsp_raw`，或 rw2/rwl/raw/dng；必须先判 `cam_raw_jpg` / `cam_hsp_raw_jpg`，否则 JPG 会被写成 `.RW2`（`:237-244`）。
- JPEG 原图：`cam_org` / `cam_hsp_jpg` / `image/*` / jpg/jpeg（`:245-247`）。
- 显示名取 `OriginalFileName='...'`，缺失退回 `dc:title`，再退回 item id 末段；`size` 属性保留为原图期望字节数（`:229-230`、`:269-276`）。
- JPG+RAW 成对时拆成两条独立资源，RAW 的 id 追加 `::raw`、独立计一次下载（`:286-299`、`:1506-1519`）。

### 6.3 下载与校验

- 流式 GET（`requestInStream` + `dataReceive` 落盘）到沙箱，UA 与会话头与 Browse 一致（`LumixSyncImageTransfer.ets:337-429`）。
- 进度：`dataReceiveProgress` 在部分真机不回调，改为在 `dataReceive` 内每 250 ms 自报一次，总量用 DIDL 声明尺寸兜底（`:402-409`）。
- 完整性：`received !== expectedBytes` 即删半成品并返回空串——DIDL 声明的是原图精确长度，短应答通常是预览图，不能当原图保存（`:452-461`）。
- 失败现场必须留 BusinessError 的 code/message，否则日志里只剩 http=0 bytes=0，无法区分授权过期、连不上与超时（`:432-446`）。
- 缩略图逐张下载（15 s 超时），失败留空占位（`:1659-1683`）。
- 批量下载先申请 `ohos.permission.WRITE_IMAGEVIDEO`，未授权即中止（`:1427-1435`）。

### 6.4 分页、去重与「全重复页」

- 首屏失败后等 1500 ms 重试一次，覆盖「刚切完 playmode、DMS 还没起来」的窗口（`LumixSyncImageTransfer.ets:1095-1101`）。
- 游标按相机 `NumberReturned` 推进（`nextStartIndex = startIndex + sourceCount`），与去重后的卡片数解耦，否则 JPG+RAW 拆卡会让翻页少走一半（`:1180`）。
- 条目以 `imageId` 去重；本页全是已见条目但游标仍未到 `TotalMatches` 时保持「可重试」，不再永久关闭续拉（`:1175-1196`，注释记录了 2026-09-27 实机 `start=36` 的现象）。
- 任一页失败后冷却 5 s 再允许触发，防止滚动把相机顶死（`:1045-1052`、`:1141-1144`、`:1170-1174`）。

### 6.5 存储卡

- 会话起始读 `getstate` 的 `current_sd` / `sd_memory` / `sd2_memory`：`set` 表示在位；`current_sd` 为 `sd1`/`sd2` 时采用，否则无 SD1 而 SD2 在位时落 SD2，其余默认 SD1（`LumixSyncImageTransfer.ets:1602-1633`）。
- 切卡用 `setsetting current_sd=sd1|sd2`，随后清空网格、`TotalMatches` 与 DIDL 缓存并完整重走起始流程（`:1635-1656`）。
- 被动推送模式不显示卡槽选择器：推送用哪张卡由相机端决定（`ImageTransferPage.ets:377-384`）。

### 6.6 相机反向推送（手机当 HTTP/SOAP 服务端）

命名沿用了 S5，但绑定在 imageApp 线（`PanasonicS5Receiver.ets:80-91`、`CameraPage.ets:4661-4667`）。顺序：`req_acc` 先成功，再亮本机 DMS；提前亮 DMS 会让相机停在「LUMIX Sync」等待页（`CameraPage.ets:6600-6612`）。

- 端口：`50000`（上传/DMS，必需）与 `49152`（控制/发现，可选；绑定失败则控制端口退回 50000）（`PanasonicS5Receiver.ets:110`、`:156-185`）。两个端口都失败才抛错（`:182-185`）。
- 本机 IP：`wifiManager.getIpInfo().ipAddress` 按网络字节序转点分；取不到时 `importUri` 退回 `127.0.0.1`，且不发 NOTIFY（`:972-986`、`:424-429`、`:765-766`）。
- DMS 描述：`friendlyName=WEB-W00`、`modelName=LUMIX_UP_SERVER_SMP`、`UDN=uuid:<clientUuid>`、`X_DLNADOC=DMS-1.50`、`X_DLNACAP=audio-upload,image-upload,av-upload`；ContentDirectory 的 `controlURL=/dms/control_0`、`SCPDURL=/dms/sdd_0.xml`（`:869-926`）。
- 客户端身份：`LumixImportPrototype.persistentS5DmsUuid()` 生成并持久化 `4D454930-0100-1000-8001-<12 位十六进制>`（6 字节随机后缀），键 `s5DmsUuid`（`LumixImportPrototype.ets:1984-2003`）。该 UUID 由本工程自行构造，未复制官方值。
- SOAP：`X_GetDLNAUploadProfiles` 返回固定 profile 列表（JPEG_SM/JPEG_MED/JPEG_LRG/CAM_RAW + 6 条 AVC_MP4，顺序不可动）（`PanasonicS5Receiver.ets:441-452`）；`CreateObject` 先在内存挂一条 `PendingCreateEntry`（从 DIDL `dc:title` 取真实文件名、`res size` 取期望字节数、`protocolInfo` 判 RAW），再回 `CreateObjectResponse` + DIDL-Lite（`objectId` 为 `1-media-i`/`2-media-i`，`parentID="i"`，`upnp:class=object.item.imageItem`）（`:397-468`）。其他 action 回空响应信封（`:469-472`）。
- 上传识别：`POST` 且非控制请求，且（chunked 或路径以 `/MEDIA` 开头或有 legacy 文件名头）= 上传（`:346-352`）。
- 上传状态机：模式 0=chunked（`<hex>\r\n` + 数据 + `\r\n`，终止块后还要吃一个 `\r\n`）、1=Content-Length、2=裸流（前 8 字节不是 HTTP 方法时按裸流落盘）（`:551-637`、`:270-279`）。带 `Expect: 100-continue` 时先回 `HTTP/1.1 100 Continue`（`:533-534`、`:849-852`）；完整接收后回 `HTTP/1.1 200 OK` + `Content-Length: 0`（`:855-858`）。
- RAW 判定：JPG 与 RW2 都声明 `image/jpeg`，RAW 标记只在 `contentfeatures.dlna.org` 的 `PANASONIC.COM_PN=CAM_RAW` 里（`:479-486`）；文件名优先按 `importUri` 路径匹配挂起表，其次按扩展名取首条，60 s 过期清理（`:488-518`）。
- 落盘与完成：文件写到 `filesDir/s5_receive_<ts>_<n>_<name>`；声明尺寸与实际不一致则删文件并提示「接收长度不完整」（`:666-716`）。
- DMS 应答头刻意保留松下形态：`CONTENT-LANGUAGE: ja`（描述符）、`EXT:`（ContentDirectory 动作）、`SERVER: Android/1 UPnP/1.0 Panasonic-DM-SV/1`、`CONNECTION: close`（`:830-846`）。
- 入口不追加 `camcmd/pictmode`：抓包里没有该请求，且 S5 对它回 `err_param`，会把相机留在「开始 Lumix Sync」页（`CameraPage.ets:6678-6683`）。`requestS5PictureMode()` 因此当前无调用方（`LumixCameraService.ets:2249-2253`）。

## 7. 实现对照表

| 能力 | 代码位置 | 状态 |
| --- | --- | --- |
| 三线分区与 token 表 | `LumixCameraService.ets:240-401` | 已实现，互斥由减法保证 |
| 无 BLE 判定 | `LumixCameraService.ets:1866-1873` | 已实现 |
| 手工 AP 列表 | `CameraPage.ets:4350-4434`、`LumixCameraService.ets:1889-1942` | 已实现（仅识别表中 token） |
| 手工密码输入与校验 | `CameraWifiPasswordPolicy.ets:1-37` | 已实现 |
| 二维码（MDL/SSID/PW/CRYPT/DeviceID） | 仅注释 `LumixCameraService.ets:347` | 未实现 |
| NFC 入网 | 仅注释 `LumixCameraService.ets:347` | 未实现 |
| SSDP M-SEARCH 客户端 | `LumixCameraService.ets:2356-2382` | 已实现 |
| DMP 描述符 `/Lumix/Server0/ddd` | `LumixCameraService.ets:2314-2335` | 已实现（60606 → 49320） |
| cam.cgi 只读探测 | `LumixCameraService.ets:2136-2206` | 已实现 |
| accctrl/req_acc | `LumixCameraService.ets:2213-2235`、`LumixSyncControlService.ets:905-1035` | 已实现 |
| cam.cgi 控制页 | `LumixSyncControlService.ets:1094-1213` | 已实现，但本线入口被前置 return 挡住（见 8.2） |
| DLNA/DMS Browse + DIDL | `LumixSyncImageTransfer.ets:103-301` | 已实现 |
| 原图/RAW/视频下载 | `LumixSyncImageTransfer.ets:1414-1519` | 已实现（RAW 无预览） |
| 本机 DMS 通告 | `PanasonicS5Receiver.ets:736-819` | 已实现 |
| CreateObject / 上传状态机 | `PanasonicS5Receiver.ets:397-716` | 已实现 |
| 相机被动推送 UI | `CameraSessionStore.ets:141-151`、`ImageTransferPage.ets:321-347` | 已实现（不显示 SD 选择器） |

## 8. 限制与风险

### 8.1 老机型 API 子集不一致

- 各机身实现的 endpoint 子集不同，握手才遍历全部已知端点并用最长应答挑载荷（`LumixCameraService.ets:403-411`、`:2149-2171`）；未收录机型只能得到「未收录型号 / 支持 RAW=true」的兜底结论（`:2198-2205`），族别与 RAW 能力都不可信。
- `MODEL_REGISTRY` 只覆盖 S/GH/G/GX/FZ/LX/TZ 的一部分（`LumixCameraService.ets:240-291`）：例如 TZ95、TZ90、GX8、GF8、G6、LF1 只在 Image App token 表里，既不在 registry，也不在 SSID 识别表（`:2095-2124`）。这些机身的 AP 不会被扫描结果识别出来（`identifyWifiSsid()` 返回 null 即丢弃，`:1923-1927`），只能靠系统已保存热点或已记住的卡片绕过（推断：无线索时的实操路径只剩「先在系统设置里连上相机热点」）。
- 状态与能力的语义在不同机身上不一致：`err_reject` 对模式切换是良性、对其它命令是失败；`err_busy` 可能意味着最长一分钟的锁死（`LumixSyncControlService.ets:206-214`、`:1126-1141`）。

### 8.2 只能只读探测与入口可达性

- 探测链本身不写任何设置、不触发快门（`LumixCameraService.ets:834-840`），这是设计约束而非临时状态。
- `openCameraControl()` 在开头就对本线 `return`（`CameraPage.ets:1631-1636`），其后再出现一次 `imageAppSelected()` 分支（`:1643-1656`）永远不会执行——即本线的 cam.cgi 控制页入口实际不可达，只能走图片传输。该分支是死代码（推断：与 `:1610-1614` 的 `cameraControlActionReady()` 对本线返回 false 一致，说明入口被刻意关闭，但残留分支未删）。
- 图片传输页对本线处于被动模式（`syncPush=true`、`syncPull=false`，`CameraSessionStore.ets:141-151`、`CameraPage.ets:2269-2279`）；页内 `startImageTransfer` 对 cam.cgi 家族只重新拉起 Wi-Fi（`CameraPage.ets:3908-3918`），不发起 DMS Browse。因此本线若没有相机主动推送，就不会出现图库条目（推断：与 `ImageTransferPage.ets:335-342` 的空态文案一致）。

### 8.3 权限

- 声明：`INTERNET`、`GET_NETWORK_INFO`、`WRITE_IMAGEVIDEO`、`GET_WIFI_INFO`、`SET_WIFI_INFO`、`LOCATION`、`APPROXIMATELY_LOCATION`（`entry/src/main/module.json5:23-86`）。
- 运行时申请 `GET_WIFI_INFO`/`SET_WIFI_INFO`/`LOCATION`/`APPROXIMATELY_LOCATION`，但 `requestWifiPermissions()` 忽略 `authResults`、恒返回 true（`CameraPage.ets:4246-4260`）——权限被拒时流程继续走到扫描，表现为「扫不到相机」而不是明确提示（推断：扫描与关联都会因缺少权限失败，日志里只剩空候选列表）。
- 同一页面初始化对本线也申请 `ACCESS_BLUETOOTH`（`CameraPage.ets:4269-4286`），与本线无蓝牙的事实不一致，仅是多一次无谓授权（无害但不精确）。
- 下载原图需要 `WRITE_IMAGEVIDEO` 且会检查结果（`LumixSyncImageTransfer.ets:1427-1435`），这一点比 Wi-Fi 权限处理严格。

### 8.4 后台与网络限制

- DMS 监听、SSDP 通告与上传接收都依赖应用进程存活；`stop()` 会撤通告并关全部连接（`PanasonicS5Receiver.ets:195-233`），页面返回不会自动停（`ImageTransferPage.ets:284-294` 明确不阻塞返回），但进程被系统回收后相机的推送必然失败（推断）。
- UDP `1900` 常被系统占用，代码以随机端口降级、只保留发通告能力（`PanasonicS5Receiver.ets:743-750`），此时相机靠 NOTIFY 仍能发现手机，但手机收不到相机的 M-SEARCH（推断：`respondToSearch` 只在绑定到组播端的 socket 上生效）。
- 相机热点没有外网，加入时用 `showNoInternetDialog: true` 避免系统反复弹「无网络」打扰（`LumixCameraService.ets:2018-2023`）。
- 大量失败路径依赖「日志能传上来」：Wi-Fi 直连、S5/cam.cgi、DMP 发现以前只写 hilog，现在统一经 `AppLogSink` 落盘并按 SSID/MAC/URL/路径打码（`LumixCameraService.ets:413-426`、`LumixSyncImageTransfer.ets:64-88`）。

### 8.5 协议层面的未定项

- `pictmode` 的确切作用只在注释里描述为「图像选择模式」，代码不发送它（`LumixCameraService.ets:2237-2253`、`CameraPage.ets:6678-6683`）。
- `accctrl` 授权窗口的 60 s 是单台机身的实测（ZS300，2026-10-21），是否适用于全部老机型未验证（`LumixSyncControlService.ets:1041-1043`）。
- 手工选 AP / 二维码 / NFC 三条官方入网路径中，本工程只实现了第一条；另两条的实现前提（相机侧 QR 内容格式、NFC 标签 NDEF 结构）在代码里没有任何样本。

### 8.6 可观测性与排查入口

- 日志标签：`VIVID_S5`（反向推送、DMP 描述符、req_acc）、`VIVID_SYNC_DMS`（Browse、下载）、`VIVID_SYNC`（accctrl、camcmd）、`VIVID_WIFI`（直连加入）、`VIVID_USB`（USB 路径）（`PanasonicS5Receiver.ets:1007-1010`、`LumixSyncImageTransfer.ets:26`、`LumixSyncControlService.ets:148`、`LumixCameraService.ets:2031-2033`）。
- Browse 原始应答与 `getsetting`/`getinfo` 原文按 3600 字符一段、最多 10 段落到应用日志，便于事后微调解析器（`LumixSyncImageTransfer.ets:316-330`、`LumixSyncControlService.ets:1505`、`:1577`、`:1603`）。
- 下载失败必须带 `BusinessError` 的 code/message，`http=0 bytes=0` 单独出现时无法区分「授权过期 / 连不上 / 超时」（`LumixSyncImageTransfer.ets:432-446`）。
- 应用日志落盘前经 `AppLogPolicy.sanitize` 打码 SSID/MAC/URL/路径，并由 `AppLogSink` 限流（`LumixCameraService.ets:413-426`）。因此日志里的主机与 SSID 是脱敏后的形态，核对具体机型要依赖 `model`/`identifyWifiSsid` 的结论行。
- 相机地址与客户端身份都以 `present`/`absent` 形式记录，不把具体地址写进日志（如 `req_acc GET host=present client=present profile=WEB-W00`，`LumixCameraService.ets:2225`）。

## 9. 现场核对清单

按此顺序核对，可在不看代码的情况下判断断点在哪一层：

1. 卡片上的线路是否为 `lumix_image`：`CameraSessionStore.panasonicLine()` 的返回值（`CameraSessionStore.ets:101-109`）。
2. 扫描候选里是否有该机身：`scanForCameras()` 结果与 `identifyWifiSsid()` 是否命中 token（`LumixCameraService.ets:1889-1942`、`:2087-2130`）。
3. Wi-Fi 是否真的关联到该 SSID：`VIVID_WIFI` 的 `direct association confirmed` 行（`:2052`）。
4. 网关是否可读：`linkedGateway()` 为空即所有 HTTP 步骤都不会发起（`:1959-1968`、`CameraPage.ets:6612`）。
5. `req_acc` 是否被接受：`VIVID_S5` 的 `req_acc response code=… marker=…`（`:2232`）。
6. 本机 DMS 是否已通告：`passive receiver started ports=…` 与 `SSDP ready ip=present`（`PanasonicS5Receiver.ets:191-192`、`:757`）。
7. 相机是否来取描述符：`DMS GET …` 与 `dms descriptor response code=…`（`PanasonicS5Receiver.ets:374`、`LumixCameraService.ets:2296`）。
8. 上传是否成帧：`upload start … chunked=1`、`file done … bytes=…`，异常时看 `upload aborted: …`（`PanasonicS5Receiver.ets:535`、`:713`、`:653`）。

## 10. 引用索引

- 线路与机型：`LumixCameraService.ets:240-401`、`:1766-1831`、`:1862-1873`、`:2087-2130`
- 入网：`LumixCameraService.ets:1883-2077`、`:1954-1968`、`CameraWifiPasswordPolicy.ets:1-37`、`CameraPage.ets:4246-4260`、`:4350-4434`、`:4530-4676`
- 发现：`LumixCameraService.ets:2281-2382`、`PanasonicS5Receiver.ets:736-819`
- 控制面：`LumixCameraService.ets:2136-2269`、`LumixSyncControlService.ets:905-1035`、`:1094-1259`、`:1984-2002`
- 图像：`LumixSyncImageTransfer.ets:23-490`、`:1030-1221`、`:1414-1519`、`:1659-1683`、`PanasonicS5Receiver.ets:80-946`
- 入口与会话：`CameraSessionStore.ets:87-156`、`CameraPage.ets:1309-1318`、`:2263-2279`、`:3873-3919`、`:6482-6724`
