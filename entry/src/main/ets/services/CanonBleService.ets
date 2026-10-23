/**
 * Canon 路线 BLE：识别 / 绑定 / 注册 / WiFi 凭据 / WAP 交接。
 *
 * 契约：`docs/canon-route-design.md` §2（对外 API §2.4 的签名一字不差）。
 * 报告：`01-首次配对-BLE扫描配对与WiFi交接.md`（§1 扫描、§2 GATT、§3 报文、
 * §4 凭据来源、§5 WAP、§6 时序、§7 绑定）。
 * 反编译：`C0251f.java`（扫描/连接/绑定）、`C0243d.java`（广播）、
 * `C0291p.java`（特征表/注册帧/0001000c）、`C0235b.java`（CCCD/TLV/状态）、
 * `C.java`（WAP 命令）、`V.java`（0001000a 命令字）、`C0286n2.java`（绑定回调）。
 *
 * 传输层复用 `LumixImportPrototype.connectGatt` / `asCharacteristic`
 * （与富士、索尼、尼康同法：它们不含厂商逻辑，并已处理鸿蒙的 RPA 地址回写与
 * 一次重试）。本文件只实现佳能自己的 GATT 语义。
 *
 * 与其它路线的关系（契约 §0.2）：BLE 扫描是「追加一轮」，任何失败只影响佳能
 * 卡片；本文件绝不停止或改写松下/尼康/索尼/富士的会话与扫描状态。
 */

import { ble, connection, constant } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';
import { LumixImportPrototype } from './LumixImportPrototype';
import { CanonModels } from './CanonModels';
import {
  CanonAdv,
  CanonAdvInfo,
  CanonAdvParser,
  CanonAdRecord,
  CanonBleError,
  CanonBleErrorCode,
  CanonBleUuids,
  CanonBytes,
  CanonCapability,
  CanonFrames,
  CanonSecurityType,
  CanonWapCapability,
  CanonWapStatus,
  CanonWapStatusInfo,
  CanonWapTlv,
  CanonWapTlvInfo,
  CanonWifiEvent,
} from './CanonProtocol';

/** 扫描命中的佳能机身（契约 §2.4）。 */
export interface CanonBleCamera {
  /** 系统 deviceId（BLE 地址，可能轮换，**不是**身份）。 */
  deviceId: string;
  /** 广播名（原样）。 */
  name: string;
  /** `CanonModels` 清理后的机型名。 */
  model: string;
  /** `canon_<slug>` 或空串。 */
  imageKey: string;
  /** usbId；0 = 未知。 */
  pid: number;
  /** 32 位大写 hex 相机 UUID（稳定身份，调用方写进 candidate.btAddress）。 */
  cameraUuid: string;
  /** 广播 flags bit0。 */
  paired: boolean;
  /** 广播 flags bit1-2：0/1/2。 */
  powerState: number;
  connectable: boolean;
  rssi: number;
}

/** 相机交接的 WiFi 凭据（契约 §2.4）。密码只存内存，不落库、不进日志。 */
export interface CanonWifiCredential {
  ssid: string;
  password: string;
  security: number;
}

/** WAP 交接结果（契约 §2.4）。 */
export interface CanonWapResult {
  ok: boolean;
  ip: string;
  bssid: string;
  wtime: number;
  code: number;
  subCode: number;
  message: string;
}

/** BLE 时序与超时（每处出处见注释）。 */
class CanonBleTuning {
  /** 报告 01 §1.1：官方 `ScanSettings` 只设 scanMode，一轮 60 s 后重启。 */
  static readonly SCAN_ROUND_MS: number = 60000;
  /** 同一 deviceId 的扫描日志最小间隔（只限日志，**不限回调**）。 */
  static readonly SCAN_LOG_INTERVAL_MS: number = 3000;
  /** GATT 读超时（`C0291p.java:452` 官方读超时 5 s）。 */
  static readonly READ_TIMEOUT_MS: number = 5000;
  /** GATT 写超时（无响应写通常 < 200 ms，留足余量）。 */
  static readonly WRITE_TIMEOUT_MS: number = 4000;
  /** 绑定轮询上限：官方 `Thread.sleep(500)` 后直接 `createBond()`，无固定上限。 */
  static readonly BOND_WAIT_MS: number = 8000;
  static readonly BOND_POLL_MS: number = 400;
  /** 等 `00010006` indicate `02` 的单次窗口。 */
  static readonly REGISTER_ACK_MS: number = 6000;
  /** 契约 §2.4：注册超时重试 2 次（共 3 次写入）。 */
  static readonly REGISTER_RETRY: number = 2;
  /** `readWifiCredential` 缺省等待。 */
  static readonly CREDENTIAL_DEFAULT_MS: number = 8000;
  /** `requestApConfig` / `startWap` 缺省等待。 */
  static readonly WAP_DEFAULT_MS: number = 20000;
  /** BLE 串行锁的轮询步长。 */
  static readonly IO_POLL_MS: number = 20;
  /** 刚收到的 `0001000c` 凭据可复用的窗口。 */
  static readonly CREDENTIAL_CACHE_MS: number = 30000;
}

/** 等 `0001000c` SSID/密码的聚合器（密码只在内存里挂最多 `timeoutMs`）。 */
class CanonCredentialWaiter {
  ssid: string = '';
  password: string = '';
  security: number = 0;
  hasSsid: boolean = false;
  hasPassword: boolean = false;
  hasSecurity: boolean = false;
  settled: boolean = false;
  timer: number = -1;
  onDone: ((value: CanonWifiCredential | null) => void) | null = null;
}

/** 等 `00020002` TLV + `00020003` 状态的聚合器。 */
class CanonWapWaiter {
  ip: string = '';
  bssid: string = '';
  wtime: number = 0;
  hasTlv: boolean = false;
  code: number = 0;
  subCode: number = 0;
  hasStatus: boolean = false;
  settled: boolean = false;
  timer: number = -1;
  onDone: ((result: CanonWapResult) => void) | null = null;
}

export class CanonBleService {
  /** HarmonyOS 通用「Operation failed」：`pairDevice` 在已绑定设备上会抛它。 */
  static readonly ERR_OPERATION_FAILED: number = 2900099;
  /** 绑定状态（`C0251f.java:166-184`：10 未配对 / 11 配对中 / 12 已配对）。 */
  static readonly BOND_NONE: number = 10;
  static readonly BOND_BONDING: number = 11;
  static readonly BOND_BONDED: number = 12;

  /** 全 0 UUID（`C0291p.java:700-703`：`00000000-…` 视为「未注册」）。 */
  private static readonly ZERO_UUID: string = '00000000000000000000000000000000';

  // ---- GATT 会话 ----
  private static gatt: ble.GattClientDevice | null = null;
  private static services: ble.GattService[] = [];
  private static connected: boolean = false;
  private static connectedDeviceId: string = '';
  private static currentCamera: CanonBleCamera | null = null;
  private static cameraByDeviceId: Map<string, CanonBleCamera> = new Map<string, CanonBleCamera>();

  // ---- 扫描 ----
  private static scanListener: ((results: Array<ble.ScanResult>) => void) | null = null;
  private static onFoundCallback: ((camera: CanonBleCamera) => void) | null = null;
  private static scanRestartTimer: number = -1;
  private static ownsScan: boolean = false;
  private static lastScanLogAt: Map<string, number> = new Map<string, number>();

  // ---- 通知 ----
  /**
   * `BLECharacteristicChange` 事件回调的参数类型是 `ble.BLECharacteristic`
   * （平台没有 `ble.BLECharacteristicChange` 这个名字，只有事件名字符串叫
   * `'BLECharacteristicChange'`）。
   */
  private static characteristicHandler: ((change: ble.BLECharacteristic) => void) | null = null;
  private static connectionHandler: ((change: ble.BLEConnectionChangeState) => void) | null = null;

  // ---- 状态 ----
  private static powerState: number = -1;
  private static capabilityBitmap: number = 0;
  private static wapCapability: number = 0;
  private static ioBusy: boolean = false;

  /** 所有**一次性**定时器（扫描轮次定时器归 `stopScan` 管，见 `disconnect`）。 */
  private static operationTimers: Set<number> = new Set<number>();

  // ---- 等待方 ----
  private static registrationSettle: ((ok: boolean) => void) | null = null;
  private static credentialWaiter: CanonCredentialWaiter | null = null;
  private static wapWaiter: CanonWapWaiter | null = null;

  // ---- 最近一次 `0001000c` 凭据（仅内存，30 s 内可复用；断开即清） ----
  private static cachedSsid: string = '';
  private static cachedPassword: string = '';
  private static cachedSecurity: number = 0;
  private static cachedAt: number = 0;

  // -------------------------------------------------------------------------
  // 扫描（报告 01 §1.1，C0251f.java:198-223）
  // -------------------------------------------------------------------------

  /**
   * 启动扫描：**唯一**过滤条件 = 服务 UUID `00010000-…`，LOW_LATENCY。
   *
   * 可重复调用：已在扫时拒绝再启一轮（鸿蒙同一时刻只允许一轮扫描），只把回调
   * 换成新的，因此页面反复挂载/卸载不会把扫描打乱。
   * 命中后 `onFound` 会**重复**触发（RSSI/电源状态变化都会再报），调用方去重。
   */
  static async startScan(onFound: (camera: CanonBleCamera) => void): Promise<void> {
    CanonBleService.onFoundCallback = onFound;
    if (CanonBleService.scanListener !== null) {
      CanonBleService.log('扫描已在运行：拒绝重复启动，复用现有扫描（回调已更新）');
      return;
    }
    const listener = (results: Array<ble.ScanResult>): void => {
      CanonBleService.handleScanResults(results);
    };
    CanonBleService.scanListener = listener;
    try {
      ble.on('BLEDeviceFind', listener);
    } catch (error) {
      CanonBleService.scanListener = null;
      CanonBleService.onFoundCallback = null;
      throw CanonBleError.wrap(error, CanonBleErrorCode.LOCAL, '注册扫描回调失败');
    }
    CanonBleService.startRadio();
    // 报告 01 §1.1：一轮 60 s，到期重启。自己占着扫描器时先 stop 再 start
    // （官方 `C0251f.i(false)` → `i(true)` 就是这个节奏）；没占到就再试着接管
    // 一次——别的路线可能已经停了，此时才能拿到「被过滤的」结果。
    CanonBleService.scanRestartTimer = setInterval((): void => {
      CanonBleService.log('扫描到期（60 s），重启一轮');
      if (CanonBleService.ownsScan) {
        try {
          ble.stopBLEScan();
        } catch (_error) {
        }
        CanonBleService.ownsScan = false;
      }
      CanonBleService.startRadio();
    }, CanonBleTuning.SCAN_ROUND_MS) as number;
  }

  static stopScan(): void {
    if (CanonBleService.scanRestartTimer !== -1) {
      clearInterval(CanonBleService.scanRestartTimer);
      CanonBleService.scanRestartTimer = -1;
    }
    const listener = CanonBleService.scanListener;
    CanonBleService.scanListener = null;
    CanonBleService.onFoundCallback = null;
    if (listener !== null) {
      try {
        ble.off('BLEDeviceFind', listener);
      } catch (_error) {
      }
    }
    // 只停自己启动的那一轮：别的路线（松下/富士）的扫描不归我们管。
    if (CanonBleService.ownsScan) {
      try {
        ble.stopBLEScan();
      } catch (_error) {
      }
      CanonBleService.ownsScan = false;
    }
    CanonBleService.lastScanLogAt.clear();
  }

  static isScanning(): boolean {
    return CanonBleService.scanListener !== null;
  }

  /**
   * 启动一轮带过滤的扫描。
   *
   * 失败（多半是别的路线已经在扫）时**不降级成全量扫描**：契约 §2.1 要求过滤
   * 条件只能是这个服务 UUID；改用全量扫描会推翻别人的过滤并让佳能结果里混入
   * 其它品牌。此时继续依赖 `BLEDeviceFind` 回调（同一份扫描结果会送给所有
   * 监听者），回调里再按厂商数据 425 + 服务 UUID 过滤。
   */
  private static startRadio(): void {
    const filters: ble.ScanFilter[] = [];
    for (const uuid of CanonBleUuids.SCAN_SERVICE_UUIDS) {
      const filter: ble.ScanFilter = { serviceUuid: uuid };
      filters.push(filter);
    }
    const options: ble.ScanOptions = {
      interval: 0,
      dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
      matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
    };
    try {
      ble.startBLEScan(filters, options);
      CanonBleService.ownsScan = true;
      CanonBleService.log(`扫描已启动（唯一过滤 ${CanonBleUuids.shortLabel(CanonBleUuids.SERVICE_SESSION)}，LOW_LATENCY）`);
    } catch (error) {
      CanonBleService.ownsScan = false;
      CanonBleService.log(`带过滤的扫描未启动（可能已有其它路线在扫）：${CanonBleError.describe(error)}；` +
        '继续复用系统已开的那一轮，回调内按厂商数据过滤');
    }
  }

  private static handleScanResults(results: Array<ble.ScanResult>): void {
    if (results === undefined || results === null || results.length === 0) return;
    const callback = CanonBleService.onFoundCallback;
    for (const result of results) {
      if (result.deviceId === undefined || result.deviceId.length === 0) continue;
      const record: CanonAdRecord | null = CanonAdvParser.parseAdvert(result.data);
      if (record === null) continue;
      const info: CanonAdvInfo = record.info;
      const identity = CanonModels.identityFromPid(info.pid, record.name);
      const camera: CanonBleCamera = {
        deviceId: result.deviceId,
        name: record.name,
        model: identity.model,
        imageKey: identity.imageKey,
        pid: info.pid,
        cameraUuid: info.cameraUuid,
        paired: info.paired,
        powerState: info.powerState,
        connectable: result.connectable === true,
        rssi: result.rssi,
      };
      CanonBleService.cameraByDeviceId.set(camera.deviceId, camera);
      // 日志限流，但**回调不限流**：调用方自己去重（契约 §2.4 的行为要求）。
      const now = Date.now();
      const previous = CanonBleService.lastScanLogAt.get(camera.deviceId);
      if (previous === undefined || now - previous >= CanonBleTuning.SCAN_LOG_INTERVAL_MS) {
        CanonBleService.lastScanLogAt.set(camera.deviceId, now);
        CanonBleService.log(`命中 pid=0x${CanonModels.pidHex(camera.pid)} model=${camera.model} ` +
          `uuid=${camera.cameraUuid.substring(0, 8)}…（32 位 hex，仅前 8 位入日志） ` +
          `paired=${camera.paired ? 1 : 0} power=${camera.powerState} ` +
          `rssi=${camera.rssi} connectable=${camera.connectable ? 1 : 0} adv=${record.name}`);
        if (camera.cameraUuid === CanonBleService.ZERO_UUID) {
          CanonBleService.log('注意：相机 UUID 全 0（未注册），本次身份不唯一，请以界面出现顺序为准');
        }
      }
      if (callback === null) continue;
      try {
        callback(camera);
      } catch (error) {
        CanonBleService.log(`扫描回调异常：${CanonBleError.describe(error)}`);
      }
    }
  }

  // -------------------------------------------------------------------------
  // 连接
  // -------------------------------------------------------------------------

  static isConnected(): boolean {
    return CanonBleService.gatt !== null && CanonBleService.connected;
  }

  static current(): CanonBleCamera | null {
    if (!CanonBleService.connected || CanonBleService.currentCamera === null) return null;
    return CanonBleService.currentCamera;
  }

  /**
   * 连接并发现服务，一次完成。
   *
   * 顺序照报告 01 §6 的 3~5 步：`connectGatt` → `discoverServices`（
   * `C0291p.java:687-689`）→ 订阅通道。绑定不在这里做（见 `register`）：
   * 官方是「连上 → 发现服务 → 若未配对再 createBond」（`C0235b.java:1060-1080`）。
   */
  static async connect(deviceId: string): Promise<boolean> {
    if (deviceId === undefined || deviceId.length === 0) {
      CanonBleService.log('连接失败：deviceId 为空');
      return false;
    }
    if (CanonBleService.gatt !== null && CanonBleService.connected &&
      CanonBleService.connectedDeviceId === deviceId) {
      return true;
    }
    await CanonBleService.disconnect();
    const trace: string[] = [];
    try {
      const client = await LumixImportPrototype.connectGatt(deviceId, trace);
      CanonBleService.gatt = client;
      CanonBleService.connectedDeviceId = deviceId;
      CanonBleService.characteristicHandler = (change: ble.BLECharacteristic): void => {
        CanonBleService.handleCharacteristicChange(change);
      };
      CanonBleService.connectionHandler = (change: ble.BLEConnectionChangeState): void => {
        if (change.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
          CanonBleService.log('GATT 链路断开（系统回调）');
          CanonBleService.connected = false;
          CanonBleService.powerState = -1;
        }
      };
      client.on('BLECharacteristicChange', CanonBleService.characteristicHandler);
      client.on('BLEConnectionStateChange', CanonBleService.connectionHandler);
      CanonBleService.services = await client.getServices();
      CanonBleService.connected = true;
      const known = CanonBleService.cameraByDeviceId.get(deviceId);
      CanonBleService.currentCamera = known !== undefined ? known : null;
      CanonBleService.log(`GATT 已连接 ${deviceId}，服务 ${CanonBleService.services.length} 个`);
      const bond = await CanonBleService.bondState();
      CanonBleService.log(`BondState=${bond}（10 未配对 / 11 配对中 / 12 已配对）`);
      CanonBleService.requireSessionChannels();
      await CanonBleService.armChannels();
      return true;
    } catch (error) {
      CanonBleService.log(`GATT 连接失败 ${deviceId}：${CanonBleError.describe(error)}`);
      CanonBleService.log(`GATT trace: ${trace.join(' | ')}`);
      await CanonBleService.disconnect();
      return false;
    }
  }

  /** 连接后自检：注册/能力/事件三个必需特征缺一个就抛明确的 UUID。 */
  private static requireSessionChannels(): void {
    const missing: string[] = [];
    if (CanonBleService.findCharacteristic(CanonBleUuids.CHAR_REGISTRATION) === null) {
      missing.push(CanonBleUuids.shortLabel(CanonBleUuids.CHAR_REGISTRATION));
    }
    if (CanonBleService.findCharacteristic(CanonBleUuids.CHAR_CAPABILITY) === null) {
      missing.push(CanonBleUuids.shortLabel(CanonBleUuids.CHAR_CAPABILITY));
    }
    if (CanonBleService.findCharacteristic(CanonBleUuids.CHAR_WIFI_EVENT) === null) {
      missing.push(CanonBleUuids.shortLabel(CanonBleUuids.CHAR_WIFI_EVENT));
    }
    if (missing.length > 0) {
      throw new CanonBleError(CanonBleErrorCode.CHARACTERISTIC_MISSING,
        `相机缺少会话特征：${missing.join(', ')}`,
        `服务 00010000 下未找到注册(00010006)/能力(0001000b)/事件(0001000c) 中的：${missing.join(', ')}`);
    }
  }

  /**
   * 订阅通道（CCCD：notify=`01 00`、indicate=`02 00`，`C0291p.java:417-438`）。
   *
   * WAP 服务在老固件上可能不存在，订阅失败只记日志，不影响注册与凭据读取
   * （契约 §0.5：不伪造可用性，但也不因此中断整条链路）。
   */
  private static async armChannels(): Promise<void> {
    await CanonBleService.armChannel(CanonBleUuids.CHAR_REGISTRATION, '配对注册', true);
    await CanonBleService.armChannel(CanonBleUuids.CHAR_WIFI_EVENT, 'WiFi 事件', true);
    await CanonBleService.armChannel(CanonBleUuids.CHAR_SESSION_STATE, '会话状态', false);
    const hasWap = CanonBleService.findCharacteristic(CanonBleUuids.CHAR_WAP_COMMAND) !== null;
    if (!hasWap) {
      CanonBleService.log(`相机没有 WAP 命令特征 ${CanonBleUuids.shortLabel(CanonBleUuids.CHAR_WAP_COMMAND)}，` +
        'WAP 交接不可用（仅能读凭据）');
      return;
    }
    await CanonBleService.armChannel(CanonBleUuids.CHAR_WAP_COMMAND, 'WAP 命令/TLV', false);
    await CanonBleService.armChannel(CanonBleUuids.CHAR_WAP_STATUS, 'WAP 状态', true);
  }

  /** 按特征实际支持的属性选 notify 或 indicate 写 CCCD。 */
  private static async armChannel(uuid: string, label: string, preferIndicate: boolean): Promise<boolean> {
    const gatt = CanonBleService.gatt;
    if (gatt === null || !CanonBleService.connected) return false;
    const characteristic = CanonBleService.findCharacteristic(uuid);
    if (characteristic === null) {
      CanonBleService.log(`相机没有「${label}」特征（${CanonBleUuids.shortLabel(uuid)}），跳过订阅`);
      return false;
    }
    const properties = characteristic.properties;
    const supportsNotify = properties !== undefined && properties.notify === true;
    const supportsIndicate = properties !== undefined && properties.indicate === true;
    try {
      const item = LumixImportPrototype.asCharacteristic(characteristic);
      if (preferIndicate && supportsIndicate) {
        await gatt.setCharacteristicChangeIndication(item, true);
        CanonBleService.log(`已订阅「${label}」（${CanonBleUuids.shortLabel(uuid)}，indicate）`);
        return true;
      }
      if (supportsNotify) {
        await gatt.setCharacteristicChangeNotification(item, true);
        CanonBleService.log(`已订阅「${label}」（${CanonBleUuids.shortLabel(uuid)}，notify）`);
        return true;
      }
      if (supportsIndicate) {
        await gatt.setCharacteristicChangeIndication(item, true);
        CanonBleService.log(`已订阅「${label}」（${CanonBleUuids.shortLabel(uuid)}，indicate 兜底）`);
        return true;
      }
      CanonBleService.log(`「${label}」既不支持 notify 也不支持 indicate，跳过`);
      return false;
    } catch (error) {
      CanonBleService.log(`订阅「${label}」失败：${CanonBleError.describe(error)}`);
      return false;
    }
  }

  /**
   * 断开并清理：扫描轮次定时器、一次性定时器、所有等待方、订阅与 GATT。
   *
   * 扫描一并停掉的理由：鸿蒙同一时刻只允许一轮扫描，连接后继续占着扫描会把
   * 其它路线的识别挤掉（契约 §0.2）。
   */
  static async disconnect(): Promise<void> {
    CanonBleService.stopScan();
    CanonBleService.cancelRegistrationAck();
    CanonBleService.finishCredential(null);
    CanonBleService.abortWapWaiter('BLE 链路已断开');
    CanonBleService.clearTimers();

    const client = CanonBleService.gatt;
    CanonBleService.gatt = null;
    CanonBleService.connected = false;
    CanonBleService.connectedDeviceId = '';
    CanonBleService.services = [];
    CanonBleService.currentCamera = null;
    CanonBleService.powerState = -1;
    CanonBleService.capabilityBitmap = 0;
    CanonBleService.wapCapability = 0;
    CanonBleService.ioBusy = false;
    CanonBleService.clearCredentialCache();
    if (client === null) return;

    const changeHandler = CanonBleService.characteristicHandler;
    const stateHandler = CanonBleService.connectionHandler;
    CanonBleService.characteristicHandler = null;
    CanonBleService.connectionHandler = null;
    try {
      if (changeHandler !== null) client.off('BLECharacteristicChange', changeHandler);
      if (stateHandler !== null) client.off('BLEConnectionStateChange', stateHandler);
    } catch (_error) {
    }
    try {
      client.disconnect();
    } catch (_error) {
    }
    try {
      client.close();
    } catch (_error) {
    }
    CanonBleService.log('GATT 已断开并清理');
  }

  // -------------------------------------------------------------------------
  // 绑定（报告 01 §7，C0235b.java:1060-1080、C0286n2.java:89-99）
  // -------------------------------------------------------------------------

  /** 系统绑定状态：10 未配对 / 11 配对中 / 12 已配对；未知返回 0。 */
  static async bondState(): Promise<number> {
    const address = CanonBleService.connectedDeviceId;
    if (address.length === 0) return 0;
    let raw = 0;
    try {
      raw = connection.getPairState(address) as number;
    } catch (error) {
      CanonBleService.log(`读取绑定状态失败：${CanonBleError.describe(error)}`);
      return 0;
    }
    // 报告 01 §7 用 Android 的 10/11/12；鸿蒙 `BondState` 枚举是 0/1/2。
    // 两者都接受，统一归一成 10/11/12 再对外（`BOND_STATE_BONDED` 用枚举比较，
    // 不写死数字，避免不同 API 版本数值不同）。
    const bonded = connection.BondState.BOND_STATE_BONDED as number;
    if (raw === bonded || raw === CanonBleService.BOND_BONDED || raw === 2) {
      return CanonBleService.BOND_BONDED;
    }
    if (raw === CanonBleService.BOND_BONDING || raw === 1) {
      return CanonBleService.BOND_BONDING;
    }
    if (raw === CanonBleService.BOND_NONE) return CanonBleService.BOND_NONE;
    return 0;
  }

  /**
   * 发起/等待系统绑定。
   *
   * 官方顺序（`C0235b.java:1060-1080`）：服务发现后 `bondState == 10` 才
   * `createBond()`，收到 `BOND_STATE_CHANGED(12)` 再进注册序列。
   * 鸿蒙侧对应 `connection.pairDevice(address)` + 轮询 `getPairState`。
   *
   * `2900099` 视为「已绑定」而非失败（尼康线同语义：`pairDevice` 在已有绑定的
   * 设备上会被系统直接拒，且拒后既不改状态也不弹框）。不实现自定义 PIN
   * （报告 01 §7【未知】：系统 Just Works / 数字比较由系统 UI 决定）。
   *
   * 返回 false 不中断流程：部分机型首次写 `00010006` 就会触发配对。
   */
  private static async ensureBond(deviceId: string): Promise<boolean> {
    const before = await CanonBleService.bondState();
    CanonBleService.log(`绑定前状态 ${before}（10 未配对 / 11 配对中 / 12 已配对 / 0 未知）`);
    if (before === CanonBleService.BOND_BONDED) {
      CanonBleService.log('已绑定（12），直接进入注册序列');
      return true;
    }
    if (before === CanonBleService.BOND_BONDING) {
      CanonBleService.log('绑定已在进行中（11），不再重复发起');
    } else {
      if (before === 0) {
        CanonBleService.log('系统未给出该地址的绑定状态（BLE 地址可能不是 BR/EDR 地址）：' +
          '仍尝试 pairDevice，失败只记日志（官方也只在 bondState==10 时 createBond）');
      }
      try {
        await connection.pairDevice(deviceId);
        CanonBleService.log('已向系统请求配对（pairDevice）');
      } catch (error) {
        const typed = error as BusinessError;
        const code = typed !== null && typed !== undefined ? typed.code : undefined;
        if (code === CanonBleService.ERR_OPERATION_FAILED) {
          CanonBleService.log('pairDevice 返回 2900099：按「已绑定/无需新建」处理，继续注册序列');
        } else {
          CanonBleService.log(`pairDevice 不可用：${CanonBleError.describe(error)}；` +
            '若系统不支持按 BLE 地址绑定，部分机型首次写入即触发配对，继续');
        }
      }
    }
    const deadline = Date.now() + CanonBleTuning.BOND_WAIT_MS;
    while (Date.now() < deadline) {
      const current = await CanonBleService.bondState();
      if (current === CanonBleService.BOND_BONDED) {
        CanonBleService.log('绑定完成（12）');
        return true;
      }
      await CanonBleService.delay(CanonBleTuning.BOND_POLL_MS);
    }
    CanonBleService.log(`等待绑定超时（${CanonBleTuning.BOND_WAIT_MS} ms），继续注册序列`);
    return false;
  }

  // -------------------------------------------------------------------------
  // 注册（报告 01 §3.1/§7，C0291p.java:228-241）
  // -------------------------------------------------------------------------

  /**
   * 首次配对注册：绑定 → 写 `00010006 = 01 + 昵称` → 等 indicate `02`。
   *
   * 超时重试 2 次（契约 §2.4）。返回 false 表示相机**没有**回 `02`
   * （`C0291p.B()` 只在相机 UUID 非全 0 时才发注册帧，全新机身可能不回应），
   * 此时不抛异常：后续的凭据读取与 WAP 仍可继续。
   */
  static async register(camera: CanonBleCamera, nickname: string): Promise<boolean> {
    if (!CanonBleService.isConnected()) {
      const linked = await CanonBleService.connect(camera.deviceId);
      if (!linked) {
        throw new CanonBleError(CanonBleErrorCode.NOT_CONNECTED,
          `连接相机失败：${camera.model.length > 0 ? camera.model : camera.name}`,
          `connect(${camera.deviceId}) 返回 false`);
      }
    }
    CanonBleService.currentCamera = camera;
    CanonBleService.cameraByDeviceId.set(camera.deviceId, camera);
    const bonded = await CanonBleService.ensureBond(camera.deviceId);
    if (!bonded) {
      CanonBleService.log('绑定未达 12：继续写注册帧（部分机型首写即触发配对）');
    }
    const frame = CanonFrames.registration(nickname);
    CanonBleService.log(`注册帧 len=${frame.length} 昵称长度=${frame.length - 1}（上限 ` +
      `${CanonFrames.NICKNAME_MAX_BYTES} 字节）`);
    for (let attempt = 0; attempt <= CanonBleTuning.REGISTER_RETRY; attempt++) {
      const ack = CanonBleService.waitRegistrationAck(CanonBleTuning.REGISTER_ACK_MS);
      const written = await CanonBleService.writeRaw(CanonBleUuids.CHAR_REGISTRATION,
        '配对注册', frame, CanonBleTuning.WRITE_TIMEOUT_MS);
      if (!written) {
        // 写入没成功就不会有回执：立刻收掉等待方，别让 6 s 定时器空转。
        CanonBleService.cancelRegistrationAck();
        await ack;
        CanonBleService.log(`注册帧第 ${attempt + 1} 次写入失败`);
        continue;
      }
      if (await ack) {
        CanonBleService.log('注册成功：相机在 00010006 上回 02');
        return true;
      }
      CanonBleService.log(`注册帧第 ${attempt + 1} 次未收到 02 回执` +
        (attempt < CanonBleTuning.REGISTER_RETRY ? '，重写' : ''));
    }
    CanonBleService.log(`注册重试 ${CanonBleTuning.REGISTER_RETRY} 次后仍无 02 回执：` +
      '按「相机已注册过」继续（不中断凭据/WAP）');
    return false;
  }

  private static waitRegistrationAck(timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      let settled = false;
      let timer = -1;
      const finish = (ok: boolean): void => {
        if (settled) return;
        settled = true;
        if (timer >= 0) CanonBleService.cancel(timer);
        CanonBleService.registrationSettle = null;
        resolve(ok);
      };
      CanonBleService.registrationSettle = finish;
      timer = CanonBleService.schedule((): void => {
        CanonBleService.log(`等待 00010006 回执超时（${timeoutMs} ms）`);
        finish(false);
      }, timeoutMs);
    });
  }

  /** 主动收掉注册回执等待方（写入失败/断开时用，避免空转 6 s）。 */
  private static cancelRegistrationAck(): void {
    const settle = CanonBleService.registrationSettle;
    CanonBleService.registrationSettle = null;
    if (settle !== null) settle(false);
  }

  // -------------------------------------------------------------------------
  // 身份 / 固件 / 能力（报告 01 §2.1/§3.3）
  // -------------------------------------------------------------------------

  /** `0001000b` read，4 字节小端；读不到返回 0（未知）。 */
  static async readCapabilities(): Promise<number> {
    let bitmap = 0;
    try {
      const value = await CanonBleService.readRaw(CanonBleUuids.CHAR_CAPABILITY,
        '能力位图', false, CanonBleTuning.READ_TIMEOUT_MS);
      bitmap = CanonBytes.readU32(value, 0);
    } catch (error) {
      CanonBleService.log(`读能力位图失败：${CanonBleError.describe(error)}`);
      return 0;
    }
    CanonBleService.capabilityBitmap = bitmap;
    CanonBleService.log(`能力位图 ${CanonCapability.describe(bitmap)}`);
    return bitmap;
  }

  /** `2a26` 固件版本；空串 = 相机不支持（`C0235b.java:799-811`）。 */
  static async readFirmware(): Promise<string> {
    return await CanonBleService.readText(CanonBleUuids.CHAR_FIRMWARE, '固件版本(2a26)');
  }

  /** `2a25` 序列号。 */
  static async readSerial(): Promise<string> {
    return await CanonBleService.readText(CanonBleUuids.CHAR_SERIAL, '序列号(2a25)');
  }

  /** `2a24` 机型串。 */
  static async readModelNumber(): Promise<string> {
    return await CanonBleService.readText(CanonBleUuids.CHAR_MODEL_NUMBER, '机型(2a24)');
  }

  // -------------------------------------------------------------------------
  // WiFi 凭据（报告 01 §4）
  // -------------------------------------------------------------------------

  /**
   * 相机经 `0001000c` indicate 下发的 SSID/密码/安全类型。
   *
   * 契约 §2.4：先等 indicate（type=1/2），超时后**回退**读 `00020004/05`
   * （报告 01 §4 的第二条路径）。两条都拿不到才抛 `CanonBleError`。
   * 密码只用于立即入网，不落库、不完整打印。
   */
  static async readWifiCredential(timeoutMs: number): Promise<CanonWifiCredential> {
    if (!CanonBleService.isConnected()) {
      throw new CanonBleError(CanonBleErrorCode.NOT_CONNECTED,
        'BLE 未连接，无法读取相机 Wi-Fi 凭据', 'readWifiCredential without GATT');
    }
    // 1) 刚收到的事件（例如刚发过 REQUEST_AP_CONFIG）可以直接复用。
    if (CanonBleService.cachedSsid.length > 0 && CanonBleService.cachedAt > 0 &&
      Date.now() - CanonBleService.cachedAt <= CanonBleTuning.CREDENTIAL_CACHE_MS) {
      const cached: CanonWifiCredential = {
        ssid: CanonBleService.cachedSsid,
        password: CanonBleService.cachedPassword,
        security: CanonBleService.cachedSecurity,
      };
      if (CanonBleService.isUsableCredential(cached)) {
        CanonBleService.log(`复用 ${Math.round((Date.now() - CanonBleService.cachedAt) / 1000)} s 前的 ` +
          `0001000c 凭据 ssid=${cached.ssid}（密码 ${cached.password.length} 字符，不落日志）`);
        return cached;
      }
      CanonBleService.log('缓存的 0001000c 凭据不完整（缺密码且非 OPEN），重新等待');
    }
    // 2) 在 0001000c 上等 indicate。
    await CanonBleService.armChannel(CanonBleUuids.CHAR_WIFI_EVENT, 'WiFi 事件', true);
    const wait = timeoutMs > 0 ? timeoutMs : CanonBleTuning.CREDENTIAL_DEFAULT_MS;
    const waiter = new CanonCredentialWaiter();
    const received = new Promise<CanonWifiCredential | null>(
      (resolve: (value: CanonWifiCredential | null) => void): void => {
        waiter.onDone = resolve;
      });
    CanonBleService.credentialWaiter = waiter;
    waiter.timer = CanonBleService.schedule((): void => {
      CanonBleService.log(`等待 0001000c 凭据超时（${wait} ms）`);
      CanonBleService.finishCredential(null);
    }, wait);
    const indicated = await received;
    if (indicated !== null && CanonBleService.isUsableCredential(indicated)) {
      return indicated;
    }
    if (indicated !== null) {
      CanonBleService.log('0001000c 给的凭据不完整（缺密码且非 OPEN），改读 00020004/00020005');
    }
    // 3) 回退：直接读 00020004/00020005/00020006（报告 01 §4 第 2 条）。
    CanonBleService.log('回退读 00020004/00020005/00020006');
    const fallback = await CanonBleService.readWapCredentials();
    CanonBleService.checkCredential(fallback);
    return fallback;
  }

  /** SSID 非空且（有密码或确实是开放网络）才算可用。 */
  private static isUsableCredential(credential: CanonWifiCredential): boolean {
    if (credential.ssid.length === 0) return false;
    if (credential.password.length > 0) return true;
    return credential.security === CanonSecurityType.OPEN;
  }

  /** 空密码只在 OPEN 网络下合法；其余情况视为相机没给凭据。 */
  private static checkCredential(credential: CanonWifiCredential): void {
    if (credential.ssid.length === 0) {
      throw new CanonBleError(CanonBleErrorCode.CREDENTIAL_UNAVAILABLE,
        '相机返回的 Wi-Fi 名称为空，请重新配对后再试', 'credential.ssid empty');
    }
    if (credential.password.length === 0 && credential.security !== CanonSecurityType.OPEN) {
      throw new CanonBleError(CanonBleErrorCode.CREDENTIAL_UNAVAILABLE,
        `相机返回的 Wi-Fi 密码为空（security=${credential.security}），请重新配对后再试`,
        'credential.password empty and not OPEN');
    }
  }

  /**
   * 读 `00020004/05/06`（部分固件只走 GATT 读，不主动 indicate）。
   * SSID/密码按 NUL 截断、UTF-8 解码；密码不打日志。
   */
  static async readWapCredentials(): Promise<CanonWifiCredential> {
    if (!CanonBleService.isConnected()) {
      throw new CanonBleError(CanonBleErrorCode.NOT_CONNECTED,
        'BLE 未连接，无法读取交接凭据', 'readWapCredentials without GATT');
    }
    const ssid = await CanonBleService.readText(CanonBleUuids.CHAR_WAP_SSID, '交接 SSID(00020004)');
    const password = await CanonBleService.readText(CanonBleUuids.CHAR_WAP_PASSWORD,
      '交接密码(00020005)');
    const security = await CanonBleService.readWapSecurity();
    if (ssid.length === 0 && password.length === 0) {
      throw new CanonBleError(CanonBleErrorCode.CREDENTIAL_UNAVAILABLE,
        '相机未提供交接凭据（00020004/00020005 均为空）',
        'readWapCredentials: ssid empty, password empty');
    }
    const credential: CanonWifiCredential = {
      ssid: ssid,
      password: password,
      security: security,
    };
    CanonBleService.log(`交接凭据 ssid=${ssid.length > 0 ? ssid : '(空)'} ` +
      `密码长度=${password.length} security=${CanonSecurityType.label(security)}（密码不落日志）`);
    return credential;
  }

  /** `00020006` 安全类型列表（int32 小端数组），取首项；读不到返回 0。 */
  private static async readWapSecurity(): Promise<number> {
    try {
      const value = await CanonBleService.readRaw(CanonBleUuids.CHAR_WAP_SECURITY,
        '安全类型列表(00020006)', false, CanonBleTuning.READ_TIMEOUT_MS);
      if (value.length >= 4) return CanonBytes.readU32(value, 0);
      return 0;
    } catch (error) {
      CanonBleService.log(`读安全类型列表失败：${CanonBleError.describe(error)}`);
      return 0;
    }
  }

  // -------------------------------------------------------------------------
  // WAP 交接（报告 01 §5）
  // -------------------------------------------------------------------------

  /**
   * `00020002` = `0A`（REQUEST_AP_CONFIG，初始化时必发，报告 01 §5.1）。
   * 等 TLV（`00020002` notify）与状态（`00020003`）。
   */
  static async requestApConfig(timeoutMs: number): Promise<CanonWapResult> {
    return await CanonBleService.runWap(CanonFrames.wapRequestApConfig(), 'REQUEST_AP_CONFIG',
      timeoutMs);
  }

  /**
   * 拉起相机 AP：`01`，或在相机支持时 `04 09 00 00 00`。
   *
   * 前置条件（`C.java:115-118`）：`00020001` bit4 置位且安全类型列表含 9；
   * 任一不满足就退回 `01`（不猜、不硬写）。
   */
  static async startWap(securityType: number, timeoutMs: number): Promise<CanonWapResult> {
    if (!CanonBleService.isConnected()) {
      throw new CanonBleError(CanonBleErrorCode.NOT_CONNECTED,
        'BLE 未连接，无法拉起相机 AP', 'startWap without GATT');
    }
    let frame = CanonFrames.wapStart();
    let label = 'START';
    if (securityType > 0) {
      const capability = await CanonBleService.readWapCapability();
      const securityList = await CanonBleService.readWapSecurityList();
      const supported = CanonWapCapability.has(capability, CanonWapCapability.SECURITY_TYPE) &&
        securityList.indexOf(securityType) >= 0;
      if (supported) {
        frame = CanonFrames.wapStartWithSecurity(securityType);
        label = `START_WITH_SECURITY(${securityType})`;
      } else {
        CanonBleService.log(`相机不支持带安全类型 START（cap=${CanonBytes.hex(capability, 8)} ` +
          `列表=[${securityList.join(',')}]），退回 01`);
      }
    }
    return await CanonBleService.runWap(frame, label, timeoutMs);
  }

  static async stopWap(): Promise<void> {
    if (!CanonBleService.isConnected()) {
      CanonBleService.log('stopWap：BLE 未连接，忽略');
      return;
    }
    try {
      const written = await CanonBleService.writeRaw(CanonBleUuids.CHAR_WAP_COMMAND,
        'WAP STOP', CanonFrames.wapStop(), CanonBleTuning.WRITE_TIMEOUT_MS);
      CanonBleService.log(written ? '已发送 WAP STOP（02）' : 'WAP STOP 写入失败');
    } catch (error) {
      // 停止是清理动作：失败只记日志，绝不把异常抛给退出流程。
      CanonBleService.log(`WAP STOP 失败：${CanonBleError.describe(error)}`);
    }
  }

  /** `00020001` WAP 能力位（4B 小端）；读不到返回 0。 */
  private static async readWapCapability(): Promise<number> {
    if (CanonBleService.wapCapability !== 0) return CanonBleService.wapCapability;
    try {
      const value = await CanonBleService.readRaw(CanonBleUuids.CHAR_WAP_CAPABILITY,
        'WAP 能力(00020001)', false, CanonBleTuning.READ_TIMEOUT_MS);
      const capability = CanonBytes.readU32(value, 0);
      CanonBleService.wapCapability = capability;
      CanonBleService.log(`WAP 能力 ${CanonBytes.hex(capability, 8)}`);
      return capability;
    } catch (error) {
      CanonBleService.log(`读 WAP 能力失败：${CanonBleError.describe(error)}`);
      return 0;
    }
  }

  /** `00020006` 作为「安全类型列表」读取（`C.java:117` 用它判断是否含 9）。 */
  private static async readWapSecurityList(): Promise<number[]> {
    const list: number[] = [];
    try {
      const value = await CanonBleService.readRaw(CanonBleUuids.CHAR_WAP_SECURITY,
        '安全类型列表(00020006)', false, CanonBleTuning.READ_TIMEOUT_MS);
      for (let offset = 0; offset + 4 <= value.length; offset += 4) {
        list.push(CanonBytes.readU32(value, offset));
      }
    } catch (error) {
      CanonBleService.log(`读安全类型列表失败：${CanonBleError.describe(error)}`);
    }
    return list;
  }

  /** 写 WAP 命令并等 TLV + 状态；超时/被拒都返回带原文的结果（不抛）。 */
  private static async runWap(frame: Uint8Array, label: string,
    timeoutMs: number): Promise<CanonWapResult> {
    if (!CanonBleService.isConnected()) {
      throw new CanonBleError(CanonBleErrorCode.NOT_CONNECTED,
        'BLE 未连接，无法执行 WAP 命令', `runWap(${label}) without GATT`);
    }
    CanonBleService.abortWapWaiter('新的 WAP 命令覆盖了旧等待');
    const waiter = new CanonWapWaiter();
    const received = new Promise<CanonWapResult>(
      (resolve: (value: CanonWapResult) => void): void => {
        waiter.onDone = resolve;
      });
    CanonBleService.wapWaiter = waiter;
    const written = await CanonBleService.writeRaw(CanonBleUuids.CHAR_WAP_COMMAND,
      `WAP ${label}`, frame, CanonBleTuning.WRITE_TIMEOUT_MS);
    if (!written) {
      CanonBleService.wapWaiter = null;
      throw new CanonBleError(CanonBleErrorCode.WRITE_FAILED,
        `WAP ${label} 写入失败`, `write 00020002 frame=${CanonBytes.hexBytes(frame, 8)}`);
    }
    const wait = timeoutMs > 0 ? timeoutMs : CanonBleTuning.WAP_DEFAULT_MS;
    waiter.timer = CanonBleService.schedule((): void => {
      CanonBleService.log(`WAP ${label} 等待超时（${wait} ms）`);
      const ok = waiter.hasTlv && waiter.ip.length > 0;
      const message = ok
        ? `WAP ${label}：只收到 TLV（IP=${waiter.ip}），未收到 00020003 状态`
        : `WAP ${label} 超时：未收到 00020002 TLV / 00020003 状态` +
          (label === 'REQUEST_AP_CONFIG' ? '（凭据可能改走 0001000c）' : '');
      CanonBleService.finishWap(waiter, ok, message);
    }, wait);
    return await received;
  }

  private static finishWap(waiter: CanonWapWaiter, ok: boolean, message: string): void {
    if (waiter.settled) return;
    waiter.settled = true;
    if (CanonBleService.wapWaiter === waiter) CanonBleService.wapWaiter = null;
    if (waiter.timer >= 0) CanonBleService.cancel(waiter.timer);
    const result: CanonWapResult = {
      ok: ok,
      ip: waiter.ip,
      bssid: waiter.bssid,
      wtime: waiter.wtime,
      code: waiter.code,
      subCode: waiter.subCode,
      message: message,
    };
    CanonBleService.log(`WAP 结果 ok=${ok} ip=${result.ip.length > 0 ? result.ip : '-'} ` +
      `bssid=${result.bssid.length > 0 ? result.bssid : '-'} wtime=${result.wtime} ` +
      `code=${result.code}/${result.subCode} ${message}`);
    const done = waiter.onDone;
    waiter.onDone = null;
    if (done !== null) done(result);
  }

  /** 断开/被新命令覆盖时收尾，避免调用方永远挂住。 */
  private static abortWapWaiter(reason: string): void {
    const waiter = CanonBleService.wapWaiter;
    if (waiter === null) return;
    CanonBleService.finishWap(waiter, false, `WAP 中止：${reason}`);
  }

  private static maybeFinishWap(): void {
    const waiter = CanonBleService.wapWaiter;
    if (waiter === null || waiter.settled || !waiter.hasStatus) return;
    const status = CanonWapStatus.decode(new Uint8Array([waiter.code, waiter.subCode]));
    if (status.rejected) {
      CanonBleService.finishWap(waiter, false,
        `START_REJECTED（Code=${waiter.code} SubCode=${waiter.subCode}）`);
      return;
    }
    if (!status.accepted) {
      // 请求事件/取消事件等未识别状态：有 IP 就说明相机已把 AP 拉起来了，
      // 不再干等成超时（只对「没有明确拒绝」的情况放行）。
      if (waiter.hasTlv && waiter.ip.length > 0) {
        CanonBleService.finishWap(waiter, true,
          `WAP 就绪（状态未识别 Code=${waiter.code} SubCode=${waiter.subCode}，但 IP/BSSID 已收到）`);
      }
      return;
    }
    if (!waiter.hasTlv || waiter.ip.length === 0) {
      // 受理了但 IP 还没到：等 TLV（报告 01 §6 第 20→21 步的先后顺序）。
      CanonBleService.log('WAP 已受理（START_ACCEPTED），继续等 IP/BSSID/WTIME');
      return;
    }
    CanonBleService.finishWap(waiter, true,
      `Handover ready（${status.label} + IP/BSSID/WTIME 已收齐）`);
  }

  // -------------------------------------------------------------------------
  // 0001000a 会话命令（报告 01 §3.2，V.java:149-197）
  // -------------------------------------------------------------------------

  /** `0A 01/02`；能力位 0x40 未置位时不写（契约 §0.5：不假装可写）。 */
  static async setProhibitAutoPowerOff(prohibit: boolean): Promise<void> {
    if (!CanonBleService.isConnected()) {
      throw new CanonBleError(CanonBleErrorCode.NOT_CONNECTED,
        'BLE 未连接，无法设置自动关机', 'setProhibitAutoPowerOff without GATT');
    }
    if (CanonBleService.capabilityBitmap === 0) {
      await CanonBleService.readCapabilities();
    }
    if (!CanonCapability.has(CanonBleService.capabilityBitmap, CanonCapability.PROHIBIT_AUTO_POWER_OFF)) {
      CanonBleService.log('相机能力位未置 0x40（不支持禁止自动关机），不写 0A');
      return;
    }
    const written = await CanonBleService.writeRaw(CanonBleUuids.CHAR_SESSION_COMMAND,
      prohibit ? '禁止自动关机(0A 01)' : '允许自动关机(0A 02)',
      CanonFrames.prohibitAutoPowerOff(prohibit), CanonBleTuning.WRITE_TIMEOUT_MS);
    if (!written) {
      throw new CanonBleError(CanonBleErrorCode.WRITE_FAILED,
        '写入自动关机设置失败', 'write 0001000a 0A failed');
    }
    CanonBleService.log(prohibit ? '已禁止相机自动关机' : '已允许相机自动关机');
  }

  /** 契约 §2.3 的同义方法（`prohibitSleep` 与 `setProhibitAutoPowerOff` 等价）。 */
  static async prohibitSleep(prohibit: boolean): Promise<void> {
    await CanonBleService.setProhibitAutoPowerOff(prohibit);
  }

  /** `03` + 16 字节 UUID（小端）；uuid 接受 32 位 hex 或 8-4-4-4-12。 */
  static async writeSessionUuid(uuid: string): Promise<void> {
    const frame = CanonFrames.sessionUuid(uuid);
    if (frame.length !== 17) {
      throw new CanonBleError(CanonBleErrorCode.INVALID_ARGUMENT,
        '会话 UUID 必须是 32 位 hex（或带 - 的 8-4-4-4-12）',
        `writeSessionUuid length=${uuid.length}`);
    }
    if (!CanonBleService.isConnected()) {
      throw new CanonBleError(CanonBleErrorCode.NOT_CONNECTED,
        'BLE 未连接，无法写会话 UUID', 'writeSessionUuid without GATT');
    }
    const written = await CanonBleService.writeRaw(CanonBleUuids.CHAR_SESSION_COMMAND,
      '会话 UUID(03)', frame, CanonBleTuning.WRITE_TIMEOUT_MS);
    if (!written) {
      throw new CanonBleError(CanonBleErrorCode.WRITE_FAILED,
        '写会话 UUID 失败', 'write 0001000a 03 failed');
    }
    CanonBleService.log(`已写会话 UUID（${CanonBleUuids.shortLabel(uuid)}…，16 字节小端）`);
  }

  /** `04` + 昵称 ASCII（`V.java:172-179`）。失败抛 `CanonBleError`。 */
  static async writeNickname(name: string): Promise<void> {
    if (!CanonBleService.isConnected()) {
      throw new CanonBleError(CanonBleErrorCode.NOT_CONNECTED,
        'BLE 未连接，无法写昵称', 'writeNickname without GATT');
    }
    const written = await CanonBleService.writeRaw(CanonBleUuids.CHAR_SESSION_COMMAND,
      '会话昵称(04)', CanonFrames.sessionNickname(name), CanonBleTuning.WRITE_TIMEOUT_MS);
    if (!written) {
      throw new CanonBleError(CanonBleErrorCode.WRITE_FAILED,
        '写会话昵称失败', 'write 0001000a 04 failed');
    }
    CanonBleService.log(`已写会话昵称（ASCII ${name.length} 字符）`);
  }

  // -------------------------------------------------------------------------
  // 特征通知分发
  // -------------------------------------------------------------------------

  /**
   * `'BLECharacteristicChange'` 的回调。
   *
   * 参数类型是 `ble.BLECharacteristic`（平台没有 `ble.BLECharacteristicChange`
   * 这个类型名；那只是事件字符串）。字段：`characteristicUuid` +
   * `characteristicValue`。
   */
  private static handleCharacteristicChange(change: ble.BLECharacteristic): void {
    if (change === undefined || change === null) return;
    const uuid: string = change.characteristicUuid !== undefined ? change.characteristicUuid : '';
    const value: Uint8Array = change.characteristicValue !== undefined
      ? new Uint8Array(change.characteristicValue) : new Uint8Array(0);
    if (CanonBleUuids.same(uuid, CanonBleUuids.CHAR_REGISTRATION)) {
      CanonBleService.onRegistrationAck(value);
      return;
    }
    if (CanonBleUuids.same(uuid, CanonBleUuids.CHAR_WIFI_EVENT)) {
      CanonBleService.onWifiEvent(value);
      return;
    }
    if (CanonBleUuids.same(uuid, CanonBleUuids.CHAR_SESSION_STATE)) {
      CanonBleService.onSessionState(value);
      return;
    }
    if (CanonBleUuids.same(uuid, CanonBleUuids.CHAR_WAP_COMMAND)) {
      CanonBleService.onWapTlv(value);
      return;
    }
    if (CanonBleUuids.same(uuid, CanonBleUuids.CHAR_WAP_STATUS)) {
      CanonBleService.onWapStatus(value);
    }
  }

  /** `00010006` indicate：首字节 2 = OK（`C0235b.java:71-87`）。 */
  private static onRegistrationAck(value: Uint8Array): void {
    if (value.length === 0) return;
    const ack = value[0];
    CanonBleService.log(`注册回执 ${CanonBytes.hex(ack, 2)}`);
    const settle = CanonBleService.registrationSettle;
    if (settle === null) return;
    settle(ack === CanonFrames.ACK_REGISTER_OK);
  }

  /** `0001000c`：1=SSID 2=password 3=security 4=result 5/6=列表（`C0235b.java:95-123`）。 */
  private static onWifiEvent(value: Uint8Array): void {
    if (value.length === 0) return;
    const type = value[0];
    if (type === CanonWifiEvent.TYPE_SSID) {
      const ssid = CanonBytes.textFrom(value, 1);
      CanonBleService.log(`WiFi 事件 1：SSID=${ssid}（${ssid.length} 字符）`);
      CanonBleService.cachedSsid = ssid;
      CanonBleService.cachedAt = Date.now();
      const waiter = CanonBleService.credentialWaiter;
      if (waiter !== null) {
        waiter.ssid = ssid;
        waiter.hasSsid = ssid.length > 0;
        CanonBleService.maybeFinishCredential();
      }
      return;
    }
    if (type === CanonWifiEvent.TYPE_PASSWORD) {
      const password = CanonBytes.textFrom(value, 1);
      // 密码绝不完整打印：只报长度。
      CanonBleService.log(`WiFi 事件 2：密码长度=${password.length}（内容不落日志）`);
      CanonBleService.cachedPassword = password;
      CanonBleService.cachedAt = Date.now();
      const waiter = CanonBleService.credentialWaiter;
      if (waiter !== null) {
        waiter.password = password;
        waiter.hasPassword = password.length > 0;
        CanonBleService.maybeFinishCredential();
      }
      return;
    }
    if (type === CanonWifiEvent.TYPE_SECURITY) {
      const security = value.length >= 2 ? value[1] : 0;
      CanonBleService.log(`WiFi 事件 3：security=${security}(${CanonSecurityType.label(security)})`);
      CanonBleService.cachedSecurity = security;
      const waiter = CanonBleService.credentialWaiter;
      if (waiter !== null) {
        waiter.security = security;
        waiter.hasSecurity = true;
        CanonBleService.maybeFinishCredential();
      }
      return;
    }
    if (type === CanonWifiEvent.TYPE_RESULT) {
      const result = value.length >= 2 ? value[1] : 0;
      if (result === CanonWifiEvent.RESULT_OK) {
        CanonBleService.log('WiFi 事件 4：交接结果 = 成功');
      } else {
        CanonBleService.log(`WiFi 事件 4：交接结果 = 失败/取消（${result}）`);
        CanonBleService.finishCredential(null);
      }
      return;
    }
    if (type === CanonWifiEvent.TYPE_SCAN_LIST || type === CanonWifiEvent.TYPE_SECURITY_LIST) {
      // 报告 01 §2.2 末注：WiFi 扫描列表 UI 在本 APK 里没有赋值点，本实现不使用。
      CanonBleService.log(`WiFi 事件 ${type}：扫描/安全列表（本实现不使用，len=${value.length}）`);
      return;
    }
    CanonBleService.log(`WiFi 事件 ${type}：未知类型（len=${value.length}）`);
  }

  /** `00010005`：0=AUTO_POWER_OFF 1=POWER_ON 2=POWER_SW_OFF（`V.java:134-147`）。 */
  private static onSessionState(value: Uint8Array): void {
    if (value.length === 0) return;
    CanonBleService.powerState = value[0];
    let label = 'UNKNOWN';
    if (value[0] === CanonAdv.POWER_AUTO_OFF) label = 'AUTO_POWER_OFF';
    else if (value[0] === CanonAdv.POWER_ON) label = 'POWER_ON';
    else if (value[0] === CanonAdv.POWER_SWITCH_OFF) label = 'POWER_SW_OFF';
    CanonBleService.log(`会话状态 ${value[0]}（${label}）`);
  }

  /** `00020002` notify：TLV（`C0235b.java:353-428`）。 */
  private static onWapTlv(value: Uint8Array): void {
    const info: CanonWapTlvInfo = CanonWapTlv.parse(value);
    CanonBleService.log(`WAP TLV len=${value.length} tags=${info.tagCount} ip=${info.ip} ` +
      `bssid=${info.bssid} wtime=${info.wtime}`);
    const waiter = CanonBleService.wapWaiter;
    if (waiter === null || waiter.settled) return;
    if (info.hasIp) waiter.ip = info.ip;
    if (info.hasBssid) waiter.bssid = info.bssid;
    if (info.hasWtime) waiter.wtime = info.wtime;
    waiter.hasTlv = waiter.hasTlv || info.hasIp || info.hasBssid || info.hasWtime;
    CanonBleService.maybeFinishWap();
  }

  /** `00020003` indicate：`[Code][SubCode]`（`C0235b.java:429-470`）。 */
  private static onWapStatus(value: Uint8Array): void {
    const status: CanonWapStatusInfo = CanonWapStatus.decode(value);
    CanonBleService.log(`WAP 状态 Code=${status.code} SubCode=${status.subCode}（${status.label}）`);
    const waiter = CanonBleService.wapWaiter;
    if (waiter === null || waiter.settled) return;
    waiter.code = status.code;
    waiter.subCode = status.subCode;
    waiter.hasStatus = true;
    CanonBleService.maybeFinishWap();
  }

  private static maybeFinishCredential(): void {
    const waiter = CanonBleService.credentialWaiter;
    if (waiter === null || waiter.settled) return;
    // 报告 01 §3.4：只有能力位 0x08 为真时 SSID+密码都齐才算完整；安全类型
    // 单独到达时也一并收下（部分固件不发 type=3）。
    if (!waiter.hasSsid || !waiter.hasPassword) return;
    const credential: CanonWifiCredential = {
      ssid: waiter.ssid,
      password: waiter.password,
      security: waiter.security,
    };
    CanonBleService.finishCredential(credential);
  }

  private static finishCredential(value: CanonWifiCredential | null): void {
    const waiter = CanonBleService.credentialWaiter;
    if (waiter === null || waiter.settled) return;
    waiter.settled = true;
    CanonBleService.credentialWaiter = null;
    if (waiter.timer >= 0) CanonBleService.cancel(waiter.timer);
    if (value !== null) {
      CanonBleService.log(`凭据已就绪 ssid=${value.ssid} 密码长度=${value.password.length} ` +
        `security=${CanonSecurityType.label(value.security)}`);
    }
    const done = waiter.onDone;
    waiter.onDone = null;
    if (done !== null) done(value);
  }

  private static clearCredentialCache(): void {
    CanonBleService.cachedSsid = '';
    CanonBleService.cachedPassword = '';
    CanonBleService.cachedSecurity = 0;
    CanonBleService.cachedAt = 0;
  }

  // -------------------------------------------------------------------------
  // 读写与工具
  // -------------------------------------------------------------------------

  private static findCharacteristic(uuid: string): ble.BLECharacteristic | null {
    for (const service of CanonBleService.services) {
      for (const characteristic of service.characteristics) {
        if (CanonBleUuids.same(characteristic.characteristicUuid, uuid)) return characteristic;
      }
    }
    return null;
  }

  /** GATT 读（带超时与串行锁）；失败抛 `CanonBleError`。 */
  private static async readRaw(uuid: string, label: string, secret: boolean,
    timeoutMs: number): Promise<Uint8Array> {
    const gatt = CanonBleService.gatt;
    if (gatt === null || !CanonBleService.connected) {
      throw new CanonBleError(CanonBleErrorCode.NOT_CONNECTED,
        `读「${label}」失败：BLE 未连接`, 'readRaw without GATT');
    }
    const characteristic = CanonBleService.findCharacteristic(uuid);
    if (characteristic === null) {
      throw new CanonBleError(CanonBleErrorCode.CHARACTERISTIC_MISSING,
        `读「${label}」失败：相机没有特征 ${CanonBleUuids.shortLabel(uuid)}`,
        `readRaw missing ${CanonBleUuids.shortLabel(uuid)}`);
    }
    await CanonBleService.acquireIo();
    try {
      const item = LumixImportPrototype.asCharacteristic(characteristic);
      const result = await CanonBleService.withTimeout<ble.BLECharacteristic>(
        gatt.readCharacteristicValue(item), timeoutMs, `读「${label}」超时（${timeoutMs} ms）`,
        CanonBleErrorCode.READ_FAILED);
      const bytes: Uint8Array = result.characteristicValue !== undefined
        ? new Uint8Array(result.characteristicValue) : new Uint8Array(0);
      CanonBleService.log(`读「${label}」(${CanonBleUuids.shortLabel(uuid)}) len=${bytes.length}` +
        (secret ? '（内容不落日志）' : ` ${CanonBytes.hexBytes(bytes, 16)}`));
      return bytes;
    } finally {
      CanonBleService.releaseIo();
    }
  }

  /**
   * GATT 写：契约 §2.3 要求全部 Write Without Response（`setWriteType(2)`，
   * `C0291p.java:399-405`）。平台偶有拒绝无响应写的情况，退回 `WRITE` 但不静默：
   * 两种都失败才返回 false，调用方决定是否抛错。
   */
  private static async writeRaw(uuid: string, label: string, data: Uint8Array,
    timeoutMs: number): Promise<boolean> {
    const gatt = CanonBleService.gatt;
    if (gatt === null || !CanonBleService.connected) {
      CanonBleService.log(`写「${label}」失败：BLE 未连接`);
      return false;
    }
    const characteristic = CanonBleService.findCharacteristic(uuid);
    if (characteristic === null) {
      CanonBleService.log(`写「${label}」失败：相机没有特征 ${CanonBleUuids.shortLabel(uuid)}`);
      return false;
    }
    await CanonBleService.acquireIo();
    try {
      const item = LumixImportPrototype.asCharacteristic(characteristic);
      item.characteristicValue = data.buffer.slice(data.byteOffset,
        data.byteOffset + data.byteLength) as ArrayBuffer;
      try {
        const noResponse: Promise<number> =
          gatt.writeCharacteristicValue(item, ble.GattWriteType.WRITE_NO_RESPONSE)
            .then((): number => 0);
        await CanonBleService.withTimeout<number>(noResponse, timeoutMs,
          `写「${label}」超时（No Response）`, CanonBleErrorCode.WRITE_FAILED);
        CanonBleService.log(`写「${label}」(${CanonBleUuids.shortLabel(uuid)}) len=${data.length} ` +
          `成功（No Response）${CanonBytes.hexBytes(data, 12)}`);
        return true;
      } catch (error) {
        CanonBleService.log(`无响应写「${label}」失败：${CanonBleError.describe(error)}；` +
          '退回有响应写');
      }
      try {
        const withResponse: Promise<number> =
          gatt.writeCharacteristicValue(item, ble.GattWriteType.WRITE).then((): number => 0);
        await CanonBleService.withTimeout<number>(withResponse, timeoutMs,
          `写「${label}」超时（WRITE）`, CanonBleErrorCode.WRITE_FAILED);
        CanonBleService.log(`写「${label}」(${CanonBleUuids.shortLabel(uuid)}) len=${data.length} 成功（WRITE）`);
        return true;
      } catch (error) {
        CanonBleService.log(`写「${label}」失败：${CanonBleError.describe(error)}`);
        return false;
      }
    } finally {
      CanonBleService.releaseIo();
    }
  }

  /** 读文本特征；失败/不支持返回空串（契约 §2.4：空串 = 不支持）。 */
  private static async readText(uuid: string, label: string): Promise<string> {
    try {
      const value = await CanonBleService.readRaw(uuid, label, false, CanonBleTuning.READ_TIMEOUT_MS);
      return CanonBytes.textUntilNul(value);
    } catch (error) {
      CanonBleService.log(`读「${label}」失败：${CanonBleError.describe(error)}`);
      return '';
    }
  }

  /** 给任意 Promise 套超时；超时抛 `CanonBleError(TIMEOUT)`，底层失败按 `errorCode` 归类。 */
  private static withTimeout<T>(task: Promise<T>, timeoutMs: number, message: string,
    errorCode: number = CanonBleErrorCode.LOCAL): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void,
      reject: (reason: CanonBleError) => void): void => {
      let settled = false;
      const timer = CanonBleService.schedule((): void => {
        if (settled) return;
        settled = true;
        reject(new CanonBleError(CanonBleErrorCode.TIMEOUT, message, message));
      }, timeoutMs);
      task.then((result: T): void => {
        if (settled) return;
        settled = true;
        CanonBleService.cancel(timer);
        resolve(result);
      }).catch((error: Object): void => {
        if (settled) return;
        settled = true;
        CanonBleService.cancel(timer);
        reject(CanonBleError.wrap(error, errorCode, message));
      });
    });
  }

  /** BLE 同一时刻只允许一个 GATT 操作：跨页面调用也要排队（同富士线做法）。 */
  private static async acquireIo(): Promise<void> {
    while (CanonBleService.ioBusy) {
      await CanonBleService.delay(CanonBleTuning.IO_POLL_MS);
    }
    CanonBleService.ioBusy = true;
  }

  private static releaseIo(): void {
    CanonBleService.ioBusy = false;
  }

  /**
   * 登记一次性定时器，保证 `disconnect()` 能全部清掉（契约 §0.8）。
   * 扫描轮次定时器是 `setInterval`，由 `stopScan()` 管（`disconnect` 会调它）。
   */
  private static schedule(action: () => void, delayMs: number): number {
    const id = setTimeout((): void => {
      CanonBleService.operationTimers.delete(id);
      action();
    }, delayMs) as number;
    CanonBleService.operationTimers.add(id);
    return id;
  }

  private static cancel(id: number): void {
    if (id < 0) return;
    try {
      clearTimeout(id);
    } catch (_error) {
    }
    CanonBleService.operationTimers.delete(id);
  }

  private static clearTimers(): void {
    CanonBleService.operationTimers.forEach((id: number): void => {
      try {
        clearTimeout(id);
      } catch (_error) {
      }
    });
    CanonBleService.operationTimers.clear();
  }

  /**
   * 纯等待**不登记**到 `operationTimers`：登记后被 `disconnect()` 清掉，等待方
   * 就永远不会醒，轮询会挂死。等待方一律有 deadline 或外部状态兜底。
   */
  private static delay(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, milliseconds);
    });
  }

  private static log(message: string): void {
    try {
      hilog.info(0x0001, 'VIVID_CANON_BLE', '%{public}s', message);
    } catch (_error) {
    }
    AppLogSink.emit('CANON_BLE', message);
  }
}
