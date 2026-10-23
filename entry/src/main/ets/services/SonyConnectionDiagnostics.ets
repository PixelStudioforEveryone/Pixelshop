/**
 * 索尼连接失败现场取证（只读探针）。
 *
 * 为什么需要这个文件
 * ------------------
 * A7M5（ILCE-7M5）在真机上表现为「Wi-Fi 已连接、会话未建立、蓝牙状态一直跳」，
 * 而同样的代码在 A7M4 上可用。日志里只能看到 64 次 TCP connect 全部失败、
 * 0 个 PTP 帧，无法判断失败发生在哪一层。候选原因互相排斥，必须一次测全：
 *
 *   H1 相机没在 15740 监听（PTP/IP 被 SSH 隧道替代，见索尼官方
 *      SshSupportCamera：DID 里 X_SSH_Support=Enable 时官方客户端根本不连
 *      15740，而是 SSH 到 22 端口再本地转发）
 *   H2 相机在监听，但我们拿到 EINPROGRESS(2301115) 就放弃了
 *   H3 我们连的地址不是相机（官方从 SSDP LOCATION 取 host，我们取 DHCP 网关）
 *   H4 会话被我们自己拆掉（每 2 秒一次 Wi-Fi 扫描 -> wifiConnectionChange ->
 *      refreshCameraWifiState 关闭 PTP/IP 栈）
 *   H5 相机的 DID 要求先做一次 Wi-Fi 配对（X_PTP_PairingNecessity=Necessary）
 *
 * 每个探针只回答一个问题，全部结果落进反馈日志，一行 `SONY_DIAG_REPORT`
 * 汇总，用户测一轮就能定位，不需要再猜。
 *
 * 只读约定
 * --------
 * 不写相机、不改配置、不发 PTP 业务操作。只做：读本机网络事实、TCP 连端口、
 * UDP 发 M-SEARCH、GET 相机的 dd.xml（UPnP 描述文档）。全部失败都吞掉，绝不
 * 影响正在进行的会话。
 *
 * @since 2026-10
 */

import { socket, http } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';

const DOMAIN: number = 0x0001;
const TAG: string = 'VIVID_SONY_DIAG';

/** PTP/IP 的固定端口。相机若走 SSH 隧道，这个端口不对外开放。 */
const PORT_PTPIP: number = 15740;
/** 索尼 HTTP 接口（dd.xml / ScalarWebAPI）默认端口。 */
const PORT_HTTP: number = 8080;
/** SSH 端口。开放即说明相机可能走 SshSupportCamera 那条路。 */
const PORT_SSH: number = 22;

/** PTP/IP 端口等待时间：SYN 被丢弃时只能靠超时收场，给足预算。 */
const PTPIP_TIMEOUT_MS: number = 6000;
/** 其余端口的等待时间。 */
const SIDE_PORT_TIMEOUT_MS: number = 3000;
/** connect() 报 EINPROGRESS 之后再观察多久，用来区分「真的没连上」和「还在连」。 */
const EINPROGRESS_EXTRA_MS: number = 5000;
/** SSDP 收集窗口。 */
const SSDP_WINDOW_MS: number = 3500;
/** 状态采样间隔，用来量化「蓝牙状态一直跳」。 */
const STATUS_SAMPLE_MS: number = 500;

export interface SonyDiagContext {
  /** 当前用来连 PTP/IP 的地址。 */
  host: string;
  /** 记录下来的相机 SSID（cam.cameraWifiSsid）。 */
  expectedSsid: string;
  /** 失败发生的位置，例如 'browse'。 */
  stage: string;
  bleStatus: string;
  wifiStatus: string;
  sessionStatus: string;
  /** CC0D 能力位摘要（由 SonyBleProvisioning 在调用前读好）。空表示没读到。 */
  bleCaps: string;
}

export interface SonyDiagPortResult {
  host: string;
  port: number;
  connected: boolean;
  /** 从发起连接到得出结论的毫秒数。 */
  elapsedMs: number;
  /** BusinessError.code；0 表示没有错误码。 */
  code: number;
  message: string;
  /** connect 事件在报错之后才到达时的毫秒数；-1 表示没到。 */
  lateConnectMs: number;
}

export interface SonyDiagReport {
  host: string;
  ssidLive: string;
  ssidMatch: string;
  gateway: string;
  portSummary: string;
  /** SSDP 应答里出现的 LOCATION host 列表。 */
  ssdpHosts: string;
  didHost: string;
  sshSupport: string;
  pairingNecessity: string;
  ptpVersions: string;
  mediaServerSupport: string;
  remoteControlSupport: string;
  bleCaps: string;
  /** 采样窗口内状态标签变化的次数。 */
  statusJumps: number;
}

export class SonyConnectionDiagnostics {
  private static running: boolean = false;
  private static report: SonyDiagReport | null = null;

  static isRunning(): boolean {
    return SonyConnectionDiagnostics.running;
  }

  /** 最近一次报告，供页面在对话框里展示结论。 */
  static lastReport(): SonyDiagReport | null {
    return SonyConnectionDiagnostics.report;
  }

  private static log(message: string): void {
    try { hilog.info(DOMAIN, TAG, '%{public}s', message); } catch (_error) { }
    AppLogSink.emit('DIAG', message);
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => { resolve(); }, ms);
    });
  }

  private static errorText(error: Object): string {
    const typed = error as BusinessError;
    const code: number = typed.code === undefined ? 0 : typed.code;
    const message: string = typed.message === undefined ? String(error) : typed.message;
    return `code=${code} ${message}`;
  }

  /**
   * 跑完整套探针。`readStatus` 是一个三元组读取器，探针期间每 500ms 采样一次，
   * 用来客观统计「状态跳变」的次数。
   */
  static async run(context: SonyDiagContext, readStatus: () => string[]): Promise<SonyDiagReport> {
    const report: SonyDiagReport = {
      host: context.host,
      ssidLive: '',
      ssidMatch: 'unknown',
      gateway: '',
      portSummary: '',
      ssdpHosts: '',
      didHost: '',
      sshSupport: 'not-probed',
      pairingNecessity: 'not-probed',
      ptpVersions: 'not-probed',
      mediaServerSupport: 'not-probed',
      remoteControlSupport: 'not-probed',
      bleCaps: context.bleCaps.length > 0 ? context.bleCaps : 'not-probed',
      statusJumps: 0,
    };
    if (SonyConnectionDiagnostics.running) {
      SonyConnectionDiagnostics.log('诊断已在进行中，跳过本次');
      return report;
    }
    SonyConnectionDiagnostics.running = true;
    SonyConnectionDiagnostics.report = report;

    // ---- 采样：量化「状态一直在跳」。探针要跑十几秒，正好覆盖用户看到的现象。
    let lastStatus = '';
    let jumps = 0;
    let samples = 0;
    const timer = setInterval((): void => {
      try {
        const now = readStatus().join('/');
        samples += 1;
        if (lastStatus.length === 0) {
          lastStatus = now;
          SonyConnectionDiagnostics.log(`status baseline ${now}`);
          return;
        }
        if (now !== lastStatus) {
          jumps += 1;
          SonyConnectionDiagnostics.log(`status jump #${jumps} ${lastStatus} -> ${now}`);
          lastStatus = now;
        }
      } catch (_error) { }
    }, STATUS_SAMPLE_MS);

    try {
      SonyConnectionDiagnostics.log(`==== 索尼连接诊断开始 stage=${context.stage} host=${context.host} ` +
        `ble=${context.bleStatus} wifi=${context.wifiStatus} session=${context.sessionStatus}`);

      // ---- 探针 1：本机网络事实（纯读，无副作用）。
      let liveSsid = '';
      let gateway = '';
      try {
        const linked = await wifiManager.getLinkedInfo();
        liveSsid = (linked.ssid === undefined ? '' : linked.ssid).replace(/^"|"$/g, '').trim();
      } catch (error) {
        SonyConnectionDiagnostics.log(`net linkedSsid failed ${SonyConnectionDiagnostics.errorText(error)}`);
      }
      try {
        const info = wifiManager.getIpInfo();
        const value: number = Number(info.gateway);
        if (Number.isFinite(value) && value > 0) {
          gateway = `${(value >>> 24) & 0xff}.${(value >>> 16) & 0xff}.${(value >>> 8) & 0xff}.${value & 0xff}`;
        }
        const local: number = Number(info.ipAddress);
        const localText = Number.isFinite(local) && local > 0
          ? `${(local >>> 24) & 0xff}.${(local >>> 16) & 0xff}.${(local >>> 8) & 0xff}.${local & 0xff}` : 'n/a';
        const mask: number = Number(info.netmask);
        const maskText = Number.isFinite(mask) && mask > 0
          ? `${(mask >>> 24) & 0xff}.${(mask >>> 16) & 0xff}.${(mask >>> 8) & 0xff}.${mask & 0xff}` : 'n/a';
        report.ssidLive = liveSsid;
        report.gateway = gateway;
        SonyConnectionDiagnostics.log(`net ssid_live=${liveSsid.length > 0 ? liveSsid : '<empty>'} ` +
          `ip=${localText} mask=${maskText} gateway=${gateway.length > 0 ? gateway : '<empty>'}`);
      } catch (error) {
        SonyConnectionDiagnostics.log(`net ipInfo failed ${SonyConnectionDiagnostics.errorText(error)}`);
      }
      const expected = context.expectedSsid;
      // 这一条正是 refreshCameraWifiState 判定「是不是还在相机热点上」的比较式。
      report.ssidMatch = expected.length === 0 ? 'no-recorded-ssid'
        : (liveSsid === expected ? 'yes' : 'no');
      SonyConnectionDiagnostics.log(`net ssid_match=${report.ssidMatch} expected=${expected.length > 0 ? expected : '<empty>'} ` +
        `live=${liveSsid.length > 0 ? liveSsid : '<empty>'}`);

      // ---- 探针 2：SSDP 发现。官方用 LOCATION 里的 host 当 PTP/IP 目标，
      // 我们用的是 DHCP 网关，两者可能不同（H3）。
      const ssdpHosts = await SonyConnectionDiagnostics.probeSsdp();
      report.ssdpHosts = ssdpHosts.length > 0 ? ssdpHosts.join(',') : 'none';

      // ---- 探针 3：端口。host 只测一次 15740；SSDP 发现的其他候选也测 15740。
      const candidates: string[] = [];
      if (context.host.length > 0) candidates.push(context.host);
      if (gateway.length > 0 && gateway !== context.host) candidates.push(gateway);
      for (const found of ssdpHosts) {
        if (candidates.indexOf(found) < 0) candidates.push(found);
      }
      const portParts: string[] = [];
      const ports: SonyDiagPortResult[] = [];
      for (let index = 0; index < candidates.length; index++) {
        const candidate = candidates[index];
        const ptpip = await SonyConnectionDiagnostics.probeTcp(candidate, PORT_PTPIP, PTPIP_TIMEOUT_MS);
        ports.push(ptpip);
        portParts.push(`${candidate}:${PORT_PTPIP}=${SonyConnectionDiagnostics.portLabel(ptpip)}`);
        SonyConnectionDiagnostics.log(`port host=${candidate} port=${PORT_PTPIP} ${SonyConnectionDiagnostics.portDetail(ptpip)}`);
        // 侧端口只对首选地址测，避免探针时间翻倍。
        if (index > 0) continue;
        const ssh = await SonyConnectionDiagnostics.probeTcp(candidate, PORT_SSH, SIDE_PORT_TIMEOUT_MS);
        ports.push(ssh);
        portParts.push(`${candidate}:${PORT_SSH}=${SonyConnectionDiagnostics.portLabel(ssh)}`);
        SonyConnectionDiagnostics.log(`port host=${candidate} port=${PORT_SSH} ${SonyConnectionDiagnostics.portDetail(ssh)}`);
        const web = await SonyConnectionDiagnostics.probeTcp(candidate, PORT_HTTP, SIDE_PORT_TIMEOUT_MS);
        ports.push(web);
        portParts.push(`${candidate}:${PORT_HTTP}=${SonyConnectionDiagnostics.portLabel(web)}`);
        SonyConnectionDiagnostics.log(`port host=${candidate} port=${PORT_HTTP} ${SonyConnectionDiagnostics.portDetail(web)}`);
      }
      report.portSummary = portParts.join(' ');

      // ---- 探针 4：DID。分辨 H1（SSH 隧道）和 H5（需要先配对）都靠它。
      // 优先用 SSDP 报出来的地址，其次用当前 host。
      let didHost = ssdpHosts.length > 0 ? ssdpHosts[0] : context.host;
      if (didHost.length === 0) didHost = gateway;
      report.didHost = didHost;
      if (didHost.length > 0) {
        await SonyConnectionDiagnostics.probeDid(didHost, report);
      } else {
        SonyConnectionDiagnostics.log('DID skipped: 没有可用地址');
      }

      // ---- 探针 5：BLE 能力位。读取必须发生在 GATT 还活着的时候，所以由调用方
      // 用 SonyBleProvisioning.readCameraCapabilities 读好再传进来；这里只回显。
      SonyConnectionDiagnostics.log(`ble caps summary=${report.bleCaps}`);
    } catch (error) {
      SonyConnectionDiagnostics.log(`诊断异常 ${SonyConnectionDiagnostics.errorText(error)}`);
    } finally {
      clearInterval(timer);
      report.statusJumps = jumps;
      SonyConnectionDiagnostics.running = false;
      SonyConnectionDiagnostics.report = report;
      SonyConnectionDiagnostics.log(`status samples=${samples} jumps=${jumps}`);
      SonyConnectionDiagnostics.log(`SONY_DIAG_REPORT stage=${context.stage} host=${context.host} ssidMatch=${report.ssidMatch} ` +
        `ports=[${report.portSummary}] ssdp=[${report.ssdpHosts}] did=${report.didHost} ` +
        `ssh=${report.sshSupport} pairing=${report.pairingNecessity} ptpVersions=${report.ptpVersions} ` +
        `mediaServer=${report.mediaServerSupport} remoteControl=${report.remoteControlSupport} ` +
        `bleCaps=${report.bleCaps} statusJumps=${report.statusJumps}`);
    }
    return report;
  }

  private static portLabel(result: SonyDiagPortResult): string {
    if (result.connected) return result.lateConnectMs >= 0 ? `late(${result.lateConnectMs}ms)` : 'open';
    return result.code > 0 ? `closed/${result.code}` : 'closed';
  }

  private static portDetail(result: SonyDiagPortResult): string {
    return `connected=${result.connected} elapsedMs=${result.elapsedMs} code=${result.code} ` +
      `lateConnectMs=${result.lateConnectMs} message=${result.message}`;
  }

  /**
   * 单端口探测。
   *
   * 关键点：`connect()` 以 EINPROGRESS(2301115, "Operation in progress") 失败时，
   * 语义是「还在连」，不是「连不上」。主链路把它当硬失败直接放弃（这正是 H2），
   * 所以这里在报错之后继续等 `connect` 事件，把两者区分开。
   */
  private static async probeTcp(host: string, port: number, timeoutMs: number): Promise<SonyDiagPortResult> {
    const result: SonyDiagPortResult = {
      host: host, port: port, connected: false, elapsedMs: 0, code: 0, message: '', lateConnectMs: -1,
    };
    const started = Date.now();
    const tcp = socket.constructTCPSocketInstance();
    let connectEventMs = -1;
    try {
      tcp.on('connect', (): void => {
        connectEventMs = Date.now() - started;
      });
    } catch (_error) { }
    try {
      tcp.on('error', (_error: BusinessError): void => { });
    } catch (_error) { }
    try {
      try {
        await tcp.bind({ address: '0.0.0.0', family: 1, port: 0 });
      } catch (_error) { }
      await tcp.connect({ address: { address: host, family: 1, port: port }, timeout: timeoutMs });
      result.connected = true;
      result.elapsedMs = Date.now() - started;
    } catch (error) {
      const typed = error as BusinessError;
      result.code = typed.code === undefined ? 0 : typed.code;
      result.message = typed.message === undefined ? String(error) : typed.message;
      result.elapsedMs = Date.now() - started;
      // 2301115 = errno 115 = EINPROGRESS。等 connect 事件补齐结论。
      if (result.code === 2301115 && connectEventMs < 0) {
        await SonyConnectionDiagnostics.delay(EINPROGRESS_EXTRA_MS);
      }
      if (connectEventMs >= 0) {
        result.connected = true;
        result.lateConnectMs = connectEventMs;
      }
    } finally {
      try { await tcp.close(); } catch (_error) { }
    }
    return result;
  }

  /**
   * SSDP M-SEARCH。相机的 UPnP 应答里有 `LOCATION: http://<ip>:8080/...`，
   * 那是官方客户端真正使用的 host —— 比 DHCP 网关可靠。
   */
  private static async probeSsdp(): Promise<string[]> {
    const hosts: string[] = [];
    const udp = socket.constructUDPSocketInstance();
    try {
      udp.on('message', (info: socket.SocketMessageInfo): void => {
        try {
          if (!info || info.message === undefined || info.message === null) return;
          const text = SonyConnectionDiagnostics.decode(new Uint8Array(info.message));
          const location = SonyConnectionDiagnostics.headerValue(text, 'LOCATION');
          const sender = info.remoteInfo === undefined ? '' : info.remoteInfo.address;
          const st = SonyConnectionDiagnostics.headerValue(text, 'ST');
          const usn = SonyConnectionDiagnostics.headerValue(text, 'USN');
          SonyConnectionDiagnostics.log(`ssdp reply from=${sender.length > 0 ? sender : 'n/a'} ` +
            `st=${st.length > 0 ? st : '-'} usn=${usn.length > 0 ? usn : '-'} ` +
            `location=${location.length > 0 ? location : '-'}`);
          const host = SonyConnectionDiagnostics.hostOf(location);
          const usable = host.length > 0 ? host : sender;
          if (usable.length > 0 && hosts.indexOf(usable) < 0) hosts.push(usable);
        } catch (_error) { }
      });
      udp.on('error', (_error: BusinessError): void => { });
      await udp.bind({ address: '0.0.0.0', family: 1, port: 0 });
      // 三个 ST：Sony 的 ScalarWebAPI、DigitalImaging，以及通用的 rootdevice。
      const targets: string[] = [
        'urn:schemas-sony-com:service:ScalarWebAPI:1',
        'urn:schemas-sony-com:service:DigitalImaging:1',
        'upnp:rootdevice',
      ];
      for (const target of targets) {
        const request = 'M-SEARCH * HTTP/1.1\r\n' +
          'HOST: 239.255.255.250:1900\r\n' +
          'MAN: "ssdp:discover"\r\n' +
          'MX: 2\r\n' +
          `ST: ${target}\r\n\r\n`;
        try {
          await udp.send({ data: request, address: { address: '239.255.255.250', family: 1, port: 1900 } });
          SonyConnectionDiagnostics.log(`ssdp sent st=${target}`);
        } catch (error) {
          SonyConnectionDiagnostics.log(`ssdp send failed st=${target} ${SonyConnectionDiagnostics.errorText(error)}`);
        }
      }
      await SonyConnectionDiagnostics.delay(SSDP_WINDOW_MS);
      SonyConnectionDiagnostics.log(`ssdp done responders=${hosts.length}`);
    } catch (error) {
      SonyConnectionDiagnostics.log(`ssdp failed ${SonyConnectionDiagnostics.errorText(error)}`);
    } finally {
      try { await udp.close(); } catch (_error) { }
    }
    return hosts;
  }

  /**
   * 取相机的 UPnP 描述文档并读出能力位。
   *
   * `X_SSH_Support=Enable` 意味着官方客户端不连 15740，而是 SSH 到 22 端口做转发
   * （SshSupportCamera.getIpAddress() 返回 "localhost"）。这是 H1 的判据。
   * `X_PTP_PairingNecessity=Necessary` 是 H5 的判据。
   */
  private static async probeDid(host: string, report: SonyDiagReport): Promise<void> {
    const url = `http://${host}:8080/dd.xml`;
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 4000,
        readTimeout: 5000,
        expectDataType: http.HttpDataType.STRING,
      });
      const body = response.result === undefined || response.result === null ? '' : String(response.result);
      SonyConnectionDiagnostics.log(`DID url_present=1 code=${response.responseCode} length=${body.length}`);
      if (body.length === 0) return;
      const tags: string[] = [
        'X_SSH_Support',
        'X_SSH_PairingNecessity',
        'X_PTP_PairingNecessity',
        'X_PTP_Versions',
        'X_PTP_MediaServerSupport',
        'X_PTP_RemoteControlSupport',
        'X_PTP_ContentsTransferSupport',
        'X_ScalarWebAPI_BaseURL',
      ];
      for (const tag of tags) {
        const value = SonyConnectionDiagnostics.tagValue(body, tag);
        SonyConnectionDiagnostics.log(`DID ${tag}=${value.length > 0 ? value : '<absent>'}`);
      }
      report.sshSupport = SonyConnectionDiagnostics.orAbsent(SonyConnectionDiagnostics.tagValue(body, 'X_SSH_Support'));
      report.pairingNecessity =
        SonyConnectionDiagnostics.orAbsent(SonyConnectionDiagnostics.tagValue(body, 'X_PTP_PairingNecessity'));
      report.ptpVersions = SonyConnectionDiagnostics.orAbsent(SonyConnectionDiagnostics.tagValue(body, 'X_PTP_Versions'));
      report.mediaServerSupport =
        SonyConnectionDiagnostics.orAbsent(SonyConnectionDiagnostics.tagValue(body, 'X_PTP_MediaServerSupport'));
      report.remoteControlSupport =
        SonyConnectionDiagnostics.orAbsent(SonyConnectionDiagnostics.tagValue(body, 'X_PTP_RemoteControlSupport'));
      // 头部留样：万一上面全 absent，说明拿到的不是 dd.xml，靠这段判断。
      const head = body.substring(0, 240).replace(/\s+/g, ' ');
      SonyConnectionDiagnostics.log(`DID head=${head}`);
    } catch (error) {
      SonyConnectionDiagnostics.log(`DID failed ${SonyConnectionDiagnostics.errorText(error)}`);
    } finally {
      try { client.destroy(); } catch (_error) { }
    }
  }

  private static orAbsent(value: string): string {
    return value.length > 0 ? value : 'absent';
  }

  /** 取 XML 标签的文本内容；同名标签取第一个，去掉嵌套标签。 */
  private static tagValue(xml: string, tag: string): string {
    try {
      const pattern = new RegExp(`<${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</${tag}>`);
      const match = xml.match(pattern);
      if (match === null || match.length < 2) return '';
      return match[1].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    } catch (_error) {
      return '';
    }
  }

  /** 从 HTTP 应答文本里取头字段（大小写不敏感）。 */
  private static headerValue(text: string, name: string): string {
    const pattern = new RegExp(`^${name}:\\s*(.+)$`, 'im');
    const match = text.match(pattern);
    if (match === null || match.length < 2) return '';
    return match[1].trim();
  }

  /** 从 `http://1.2.3.4:8080/dd.xml` 里取出 `1.2.3.4`。 */
  private static hostOf(location: string): string {
    const match = location.match(/^https?:\/\/([^/:]+)/i);
    return match === null || match.length < 2 ? '' : match[1];
  }

  /** 字节转文本：这些应答都是 ASCII，但仍按 UTF-8 解一次并兜底。 */
  private static decode(bytes: Uint8Array): string {
    let text = '';
    for (let index = 0; index < bytes.length; index++) {
      const code = bytes[index];
      if (code === 0) break;
      text += String.fromCharCode(code);
    }
    return text;
  }
}
