/**
 * FUJIFILM BLE 识别 / 配对 / 凭据 / 功能拉起。
 *
 * 事实来源（`01_首次配对_蓝牙配对与WiFi凭据.md`）
 * ------------------------------------------------
 *  - §2 / §4.1：`ScanFilter` 挂服务 UUID，`AF854C2E` 在任何模式都常驻；
 *    `ScanSettings` 只设 scanMode=2，**60 s** 一轮超时后重启扫描。
 *  - §4.4：广播厂商数据 `mf[0]=1` 为 RED（新协议），`=2` 为老协议；
 *    老协议 `mf[1..4]` 是 pairing key、`mf[5]` 是电源键；
 *    RED 的 `mf[1..5]` 是 5 字节 ASCII 短序列号、`mf[6]` 是电源键。
 *    广播名前 4 字符 = 老协议的短序列号。
 *  - §3 / §5.2：特征 UUID 与读写方向（常量见 `FujifilmProtocol.FujifilmBleIds`）。
 *  - §6 / §7.2：配对 = 把相机广播里给的 key 原样写回 `ABA356EB`；
 *    RED 另写 `F557D96B = 0x20000000` 与固定 `80 01 01` 到 `8B5ECF55`。
 *    **没有 PIN、没有绑定、没有加解密**（`createBond()` 全库 0 处）。
 *  - §8：SSID `BF6DC9CF` / 密码 `E809256A`，UTF-8 读到首个 `0x00`；
 *    **密码读失败立即断开**，且不落库。
 *  - §9.2：功能拉起写 `600655E6` = u16 LE 3/4/5，等 `A68E3F66 = 0x8001`。
 *
 * 传输层复用 `LumixImportPrototype` 的 `connectGatt` / `asCharacteristic`
 * （与索尼、尼康两条线同样的做法）：它们不含厂商逻辑，且已经处理了
 * HarmonyOS 的 RPA 地址回写与重试。本文件只实现富士自己的 GATT 语义。
 */

import { ble, constant } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';
import { LumixImportPrototype } from './LumixImportPrototype';
import { FujifilmBytes, FujifilmBleIds } from './FujifilmProtocol';

/** 扫描命中的富士机身（契约 §2.2）。 */
export interface FujifilmBleCamera {
  /** 系统 deviceId。 */
  deviceId: string;
  /** 蓝牙名（前 4 字符 = 老协议的短序列号）。 */
  name: string;
  /** 短序列号。 */
  serial: string;
  /** 机型名（用于素材/日志）。 */
  model: string;
  /** true = 新协议（`mf[0]==1`）。 */
  red: boolean;
  rssi: number;
}

/** 机身身份（契约 §2.2）。 */
export interface FujifilmIdentity {
  serial: string;
  model: string;
  yNumber: string;
  mac: string;
  firmware: string;
  red: boolean;
}

/** WiFi 凭据（契约 §2.2）。密码只存内存，不落库。 */
export interface FujifilmWifiCredential {
  ssid: string;
  passphrase: string;
}

/** 一条广播里解析出来的富士身份信息。 */
interface FujifilmAdvertisement {
  name: string;
  red: boolean;
  /** `mf[0]`；没有厂商数据时为 -1。 */
  protocol: number;
  /** 老协议 4 字节 key / RED 5 字节 ASCII 序列号。 */
  pairingKey: Uint8Array;
  /** 电源键状态；未知 -1。 */
  powerKey: number;
  companyId: number;
  hasAlwaysService: boolean;
}

/** BLE 扫描 + GATT 边界（`01 §3`）常量。 */
class FujifilmBleTuning {
  /** `01 §7.2 第 4 步`：`gatt.requestMtu(185)`（`BTManager.MTU_SIZE=185`）。 */
  static readonly MTU: number = 185;
  /** `01 §4.3`：60 s 一轮扫描超时后重启。 */
  static readonly SCAN_RESTART_MS: number = 60000;
  /** 同一台机身两次上报的最小间隔，避免把回调打成风暴。 */
  static readonly REPORT_INTERVAL_MS: number = 3000;
  /** AP_STATE 轮询步长（通知之外的兜底）。 */
  static readonly AP_POLL_MS: number = 250;
  /** 老协议短序列号长度（广播名前 4 字符）。 */
  static readonly LEGACY_SERIAL_LENGTH: number = 4;
  /** RED 短序列号长度（`mf[1..5]`）。 */
  static readonly RED_SERIAL_LENGTH: number = 5;
}

export class FujifilmBleService {
  private static gatt: ble.GattClientDevice | null = null;
  private static services: ble.GattService[] = [];
  private static connectedDeviceId: string = '';
  private static connected: boolean = false;

  private static scanListener: ((results: Array<ble.ScanResult>) => void) | null = null;
  private static onFoundCallback: ((camera: FujifilmBleCamera) => void) | null = null;
  private static restartTimer: number = -1;
  private static ownsScan: boolean = false;
  private static lastReportAt: Map<string, number> = new Map<string, number>();

  /** deviceId → 最近一次广播内容（配对要回写里面的 key）。 */
  private static advertisements: Map<string, FujifilmAdvertisement> = new Map<string, FujifilmAdvertisement>();

  private static apStateValue: number = -1;
  /** 通用特征通道（固件读写）的串行锁。 */
  private static ioBusy: boolean = false;
  private static characteristicChangeHandler:
    ((change: ble.BLECharacteristic) => void) | null = null;
  private static connectionChangeHandler:
    ((change: ble.BLEConnectionChangeState) => void) | null = null;

  /**
   * Y 号特征。
   *
   * 【缺常量】`FujifilmProtocol.ets` 没有这个 UUID；值取自
   * `reports/data/ble_gatt_table.csv`（`CHARACTERISTIC_FF_CAMERA_Y_NUMBER`，
   * `J:BTCamera.java:3366`）。已报协调者补 `FujifilmBleIds.CHAR_Y_NUMBER`，
   * 补齐后删掉本行（见 `NOTES_A.md §6`）。
   */
  private static readonly CHAR_Y_NUMBER_PENDING: string = '27870478-94A9-4345-849B-EFA3BF37887F';

  // -------------------------------------------------------------------------
  // 扫描
  // -------------------------------------------------------------------------

  /**
   * 扫描（ScanFilter = 7 个服务 UUID，其中 AF854C2E 常驻），命中即回调。
   *
   * 页面上的松下扫描可能已经在跑，而 HarmonyOS 同一时刻只允许一轮扫描：
   * 这时 `startBLEScan` 会被拒，但**已有的扫描结果仍会送到我们的
   * `BLEDeviceFind` 回调**，所以这里把「启动失败」降级为「复用页面扫描」，
   * 两条线因此可以并列运行、互不影响。
   */
  static async startScan(onFound: (camera: FujifilmBleCamera) => void): Promise<void> {
    FujifilmBleService.stopScan();
    FujifilmBleService.onFoundCallback = onFound;
    const listener = (results: Array<ble.ScanResult>): void => {
      FujifilmBleService.handleScanResults(results);
    };
    FujifilmBleService.scanListener = listener;
    try {
      ble.on('BLEDeviceFind', listener);
    } catch (error) {
      FujifilmBleService.log(`注册扫描回调失败：${FujifilmBleService.describe(error)}`);
      throw error instanceof Error ? error : new Error(String(error));
    }
    FujifilmBleService.startRadio();
    FujifilmBleService.restartTimer = setInterval((): void => {
      // `01 §4.3`：单轮扫描 60 s 后到期；我们只重启自己拥有的那一轮。
      if (!FujifilmBleService.ownsScan) return;
      FujifilmBleService.log('扫描到期，重启一轮（60s）');
      FujifilmBleService.startRadio();
    }, FujifilmBleTuning.SCAN_RESTART_MS) as number;
  }

  static stopScan(): void {
    if (FujifilmBleService.restartTimer !== -1) {
      clearInterval(FujifilmBleService.restartTimer);
      FujifilmBleService.restartTimer = -1;
    }
    const listener = FujifilmBleService.scanListener;
    FujifilmBleService.scanListener = null;
    FujifilmBleService.onFoundCallback = null;
    if (listener !== null) {
      try {
        ble.off('BLEDeviceFind', listener);
      } catch (_error) {
      }
    }
    // 只停自己启动的那一轮：松下扫描不归我们管，停了会打断它的候选列表。
    if (FujifilmBleService.ownsScan) {
      try {
        ble.stopBLEScan();
      } catch (_error) {
      }
      FujifilmBleService.ownsScan = false;
    }
  }

  private static startRadio(): void {
    const filters: ble.ScanFilter[] = [];
    for (const uuid of FujifilmBleIds.SCAN_SERVICE_UUIDS) {
      filters.push({ serviceUuid: uuid });
    }
    const options: ble.ScanOptions = {
      interval: 0,
      dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
      matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
    };
    try {
      ble.startBLEScan(filters, options);
      FujifilmBleService.ownsScan = true;
      FujifilmBleService.log(`扫描已启动（${filters.length} 个服务 UUID 过滤）`);
      return;
    } catch (error) {
      FujifilmBleService.log(`带过滤的扫描未启动：${FujifilmBleService.describe(error)}`);
    }
    try {
      // 带过滤被拒时退回全量扫描：回调里按厂商数据 / 服务 UUID 自己过滤。
      ble.startBLEScan(null, options);
      FujifilmBleService.ownsScan = true;
      FujifilmBleService.log('扫描已启动（全量，回调内过滤）');
    } catch (error) {
      FujifilmBleService.log(`扫描未启动，复用页面已有的扫描：${FujifilmBleService.describe(error)}`);
      FujifilmBleService.ownsScan = false;
    }
  }

  private static handleScanResults(results: Array<ble.ScanResult>): void {
    if (!results || results.length === 0) return;
    const now = Date.now();
    for (const result of results) {
      if (!result.deviceId) continue;
      const parsed = FujifilmBleService.parseAdvertisement(result.data);
      if (parsed === null) continue;
      const camera: FujifilmBleCamera = {
        deviceId: result.deviceId,
        name: parsed.name,
        serial: FujifilmBleService.serialOf(parsed),
        model: FujifilmBleService.modelOf(parsed),
        red: parsed.red,
        rssi: result.rssi,
      };
      if (camera.name.length === 0 && camera.serial.length === 0) continue;
      FujifilmBleService.advertisements.set(result.deviceId, parsed);
      const previous = FujifilmBleService.lastReportAt.get(result.deviceId);
      if (previous !== undefined && now - previous < FujifilmBleTuning.REPORT_INTERVAL_MS) continue;
      FujifilmBleService.lastReportAt.set(result.deviceId, now);
      FujifilmBleService.log(`命中 name=${camera.name} serial=${camera.serial} model=${camera.model} ` +
        `red=${camera.red ? 1 : 0} rssi=${camera.rssi} connectable=${result.connectable}`);
      const callback = FujifilmBleService.onFoundCallback;
      if (callback !== null) {
        try {
          callback(camera);
        } catch (error) {
          FujifilmBleService.log(`扫描回调异常：${FujifilmBleService.describe(error)}`);
        }
      }
    }
  }

  /**
   * 解析广播。
   *
   * 识别依据（`01 §4.1/§4.4`）：厂商数据 company=0x04D8，或服务 UUID 含常驻的
   * `AF854C2E`，或含 RED 的两个新服务之一。纯按名字含 `FUJIFILM` 判定不放行：
   * 那会把打印机、随身打印机（instax）之外的其他富士设备也拉进来。
   */
  private static parseAdvertisement(data: ArrayBuffer): FujifilmAdvertisement | null {
    if (data === undefined || data === null || data.byteLength === 0) return null;
    const bytes = new Uint8Array(data);
    let offset = 0;
    let name = '';
    let companyId = -1;
    let manufacturer: Uint8Array = new Uint8Array(0);
    let hasAlways = false;
    let hasRed = false;
    while (offset + 1 < bytes.length) {
      const length = bytes[offset];
      if (length === 0) break;
      const type = bytes[offset + 1];
      const bodyStart = offset + 2;
      const bodyEnd = Math.min(offset + 1 + length, bytes.length);
      if (bodyEnd <= bodyStart) {
        offset += 1 + length;
        continue;
      }
      const body = bytes.subarray(bodyStart, bodyEnd);
      if (type === 0x08 || type === 0x09) {
        name = FujifilmBleService.asciiUntilNul(body);
      } else if (type === 0xFF && body.length >= 2) {
        companyId = body[0] | (body[1] << 8);
        manufacturer = body.subarray(2);
      } else if (type === 0x06 || type === 0x07) {
        for (let at = 0; at + 16 <= body.length; at += 16) {
          const uuid = FujifilmBleService.uuidFromLittleEndian(body, at);
          if (uuid === FujifilmBleIds.SCAN_UUID_ALWAYS) hasAlways = true;
          if (uuid === FujifilmBleIds.SERVICE_CAMERA_INFORMATION_RED ||
            uuid === FujifilmBleIds.SERVICE_CONNECTED_DEVICE_INFO_RED) hasRed = true;
        }
      }
      offset += 1 + length;
    }
    const hasFujiCompany = companyId === FujifilmBleIds.COMPANY_ID;
    if (!hasFujiCompany && !hasAlways && !hasRed) return null;
    const protocol = manufacturer.length > 0 ? manufacturer[0] : -1;
    const red = protocol === FujifilmBleIds.ADV_PROTOCOL_RED;
    let pairingKey = new Uint8Array(0);
    let powerKey = -1;
    if (red) {
      // [01][s0..s4][powerKeyState]
      const end = Math.min(1 + FujifilmBleTuning.RED_SERIAL_LENGTH, manufacturer.length);
      if (end > 1) pairingKey = manufacturer.slice(1, end);
      if (manufacturer.length > end) powerKey = manufacturer[end];
    } else if (protocol === FujifilmBleIds.ADV_PROTOCOL_LEGACY) {
      // [02][key0..key3][powerKeyState]
      const end = Math.min(5, manufacturer.length);
      if (end > 1) pairingKey = manufacturer.slice(1, end);
      if (manufacturer.length > end) powerKey = manufacturer[end];
    }
    return {
      name: name,
      red: red,
      protocol: protocol,
      pairingKey: pairingKey,
      powerKey: powerKey,
      companyId: companyId,
      hasAlwaysService: hasAlways,
    };
  }

  /** 短序列号：RED 取 `mf[1..5]` 的 ASCII，老协议取广播名前 4 字符。 */
  private static serialOf(parsed: FujifilmAdvertisement): string {
    if (parsed.red) return FujifilmBleService.asciiUntilNul(parsed.pairingKey);
    if (parsed.name.length <= FujifilmBleTuning.LEGACY_SERIAL_LENGTH) return parsed.name;
    return parsed.name.substring(0, FujifilmBleTuning.LEGACY_SERIAL_LENGTH);
  }

  /** 机型名：RED 用整串广播名，老协议用前 4 字符之后剩下的部分。 */
  private static modelOf(parsed: FujifilmAdvertisement): string {
    if (parsed.red) return parsed.name;
    if (parsed.name.length <= FujifilmBleTuning.LEGACY_SERIAL_LENGTH) return '';
    return parsed.name.substring(FujifilmBleTuning.LEGACY_SERIAL_LENGTH).trim();
  }

  /** 蓝牙 AD 里的 128-bit UUID 是小端序（最低字节在前）。 */
  private static uuidFromLittleEndian(bytes: Uint8Array, start: number): string {
    let raw = '';
    for (let index = 15; index >= 0; index--) {
      const part = bytes[start + index].toString(16).toUpperCase();
      raw += part.length === 1 ? '0' + part : part;
    }
    return `${raw.substring(0, 8)}-${raw.substring(8, 12)}-${raw.substring(12, 16)}-` +
      `${raw.substring(16, 20)}-${raw.substring(20)}`;
  }

  // -------------------------------------------------------------------------
  // GATT
  // -------------------------------------------------------------------------

  /**
   * GATT 连接 + 订阅 AP_STATE/身份特征。
   *
   * 顺序照 `01 §7.2`：连接 → `requestMtu(185)` → 发现服务（`getServices`）
   * → 订阅通知（`AP_STATE` 是唯一的拉起完成信号，`01 §9.4`）。
   */
  static async connect(deviceId: string): Promise<boolean> {
    if (FujifilmBleService.gatt !== null && FujifilmBleService.connected &&
      FujifilmBleService.connectedDeviceId === deviceId) return true;
    await FujifilmBleService.disconnect();
    const trace: string[] = [];
    try {
      const client = await LumixImportPrototype.connectGatt(deviceId, trace);
      FujifilmBleService.gatt = client;
      FujifilmBleService.connectedDeviceId = deviceId;
      // 契约要求 185；`setBLEMtuSize` 是同步接口，失败时再试异步的 `setBLEMtu`。
      try {
        client.setBLEMtuSize(FujifilmBleTuning.MTU);
      } catch (_error) {
        try {
          await client.setBLEMtu(FujifilmBleTuning.MTU);
        } catch (_ignored) {
          FujifilmBleService.log('MTU 设置失败，按缺省 MTU 继续');
        }
      }
      FujifilmBleService.characteristicChangeHandler = (change: ble.BLECharacteristic): void => {
        FujifilmBleService.handleCharacteristicChange(change);
      };
      FujifilmBleService.connectionChangeHandler = (change: ble.BLEConnectionChangeState): void => {
        if (change.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
          FujifilmBleService.log('GATT 链路断开');
          FujifilmBleService.connected = false;
          FujifilmBleService.apStateValue = -1;
        }
      };
      client.on('BLECharacteristicChange', FujifilmBleService.characteristicChangeHandler);
      client.on('BLEConnectionStateChange', FujifilmBleService.connectionChangeHandler);
      FujifilmBleService.services = await client.getServices();
      FujifilmBleService.connected = true;
      FujifilmBleService.log(`GATT 已连接 ${deviceId}，服务 ${FujifilmBleService.services.length} 个`);
      await FujifilmBleService.enableNotify(FujifilmBleIds.CHAR_AP_STATE, 'AP_STATE');
      return true;
    } catch (error) {
      FujifilmBleService.log(`GATT 连接失败 ${deviceId}：${FujifilmBleService.describe(error)}`);
      FujifilmBleService.log(`GATT trace: ${trace.join(' | ')}`);
      await FujifilmBleService.disconnect();
      return false;
    }
  }

  static isConnected(): boolean {
    return FujifilmBleService.gatt !== null && FujifilmBleService.connected;
  }

  /** 当前 GATT 连接的 deviceId（未连接为空串）。固件页据此复用同一条链路。 */
  static currentDeviceId(): string {
    return FujifilmBleService.connected ? FujifilmBleService.connectedDeviceId : '';
  }

  static async disconnect(): Promise<void> {
    const client = FujifilmBleService.gatt;
    FujifilmBleService.gatt = null;
    FujifilmBleService.connected = false;
    FujifilmBleService.connectedDeviceId = '';
    FujifilmBleService.services = [];
    FujifilmBleService.apStateValue = -1;
    if (client === null) return;
    const changeHandler = FujifilmBleService.characteristicChangeHandler;
    const connectionHandler = FujifilmBleService.connectionChangeHandler;
    FujifilmBleService.characteristicChangeHandler = null;
    FujifilmBleService.connectionChangeHandler = null;
    try {
      if (changeHandler !== null) client.off('BLECharacteristicChange', changeHandler);
      if (connectionHandler !== null) client.off('BLEConnectionStateChange', connectionHandler);
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
  }

  private static handleCharacteristicChange(change: ble.BLECharacteristic): void {
    if (change === undefined || change === null) return;
    const uuid = (change.characteristicUuid || '').toLowerCase();
    if (uuid !== FujifilmBleIds.CHAR_AP_STATE.toLowerCase()) return;
    const value = change.characteristicValue !== undefined
      ? new Uint8Array(change.characteristicValue) : new Uint8Array(0);
    const state = value.length >= 2 ? FujifilmBytes.readU16(value, 0) : -1;
    FujifilmBleService.apStateValue = state;
    FujifilmBleService.log(`AP_STATE 通知 = ${FujifilmBytes.hex(state, 4)}`);
  }

  private static async enableNotify(uuid: string, label: string): Promise<void> {
    const gatt = FujifilmBleService.gatt;
    if (gatt === null) return;
    const characteristic = FujifilmBleService.findCharacteristic(uuid);
    if (characteristic === null) {
      FujifilmBleService.log(`相机没有 ${label} 特征（${uuid}），跳过订阅`);
      return;
    }
    try {
      await gatt.setCharacteristicChangeNotification(
        LumixImportPrototype.asCharacteristic(characteristic), true);
      FujifilmBleService.log(`已订阅 ${label}`);
    } catch (error) {
      FujifilmBleService.log(`订阅 ${label} 失败：${FujifilmBleService.describe(error)}`);
    }
  }

  private static findCharacteristic(uuid: string): ble.BLECharacteristic | null {
    const expected = (uuid || '').toLowerCase();
    if (expected.length === 0) return null;
    for (const service of FujifilmBleService.services) {
      for (const characteristic of service.characteristics) {
        if (FujifilmBleService.sameUuid(characteristic.characteristicUuid, expected)) return characteristic;
      }
    }
    return null;
  }

  /** 128-bit 全等；16-bit 短 UUID 允许平台只回 4 位十六进制。 */
  private static sameUuid(actual: string, expected: string): boolean {
    const value = (actual || '').toLowerCase();
    if (value === expected) return true;
    if (value.length === 4 && expected.indexOf('0000' + value) === 0) return true;
    return false;
  }

  // -------------------------------------------------------------------------
  // 配对
  // -------------------------------------------------------------------------

  /**
   * 配对：把广播里的 pairing key 原样回写（`01 §7.2 12/17`）。
   * RED 机型先补 `F557D96B = 0x20000000`，再写固定 `80 01 01` 到 `8B5ECF55`。
   * 全程没有 PIN / 加密 / 系统绑定。
   */
  static async pair(camera: FujifilmBleCamera): Promise<boolean> {
    if (!FujifilmBleService.isConnected()) {
      const linked = await FujifilmBleService.connect(camera.deviceId);
      if (!linked) return false;
    }
    const advertisement = FujifilmBleService.advertisements.get(camera.deviceId);
    if (advertisement === undefined || advertisement.pairingKey.length === 0) {
      FujifilmBleService.log('广播里没有 pairing key，无法配对（请重新扫描后再试）');
      return false;
    }
    try {
      if (camera.red) {
        // 只读一次：非 0 说明已经绑定过，不重复写（`01 §7.2 15-16`）。
        let identification = 0;
        try {
          const current = await FujifilmBleService.readValue(FujifilmBleIds.CHAR_CONNECTED_DEVICE_ID,
            'RED 设备识别号', false);
          identification = current.length >= 4 ? FujifilmBytes.readU32(current, 0) : 0;
        } catch (error) {
          FujifilmBleService.log(`读设备识别号失败（按未绑定处理）：${FujifilmBleService.describe(error)}`);
        }
        if (identification !== FujifilmBleIds.XAPP_IDENTIFIER) {
          const written = await FujifilmBleService.writeValue(FujifilmBleIds.CHAR_CONNECTED_DEVICE_ID,
            'RED 设备识别号', FujifilmBytes.u32(FujifilmBleIds.XAPP_IDENTIFIER));
          if (!written) return false;
        }
      }
      const keyed = await FujifilmBleService.writeValue(FujifilmBleIds.CHAR_PAIRING_KEY,
        '配对密钥', advertisement.pairingKey);
      if (!keyed) return false;
      if (camera.red) {
        const appInfo = new Uint8Array(FujifilmBleIds.RED_APP_INFO_BYTES);
        const written = await FujifilmBleService.writeValue(FujifilmBleIds.CHAR_CONNECTED_APP_INFO,
          'App 信息', appInfo);
        if (!written) return false;
      }
      FujifilmBleService.log(`配对完成 name=${camera.name} red=${camera.red ? 1 : 0}`);
      return true;
    } catch (error) {
      FujifilmBleService.log(`配对失败：${FujifilmBleService.describe(error)}`);
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // 身份 / 固件版本 / 凭据
  // -------------------------------------------------------------------------

  static async readIdentity(): Promise<FujifilmIdentity> {
    const advertisement = FujifilmBleService.connectedDeviceId.length > 0
      ? FujifilmBleService.advertisements.get(FujifilmBleService.connectedDeviceId) : undefined;
    let serial = await FujifilmBleService.readText(FujifilmBleIds.CHAR_SERIAL_NUMBER, '序列号');
    if (serial.length === 0) {
      serial = await FujifilmBleService.readText(FujifilmBleIds.CHAR_SERIAL_NUMBER_STD, '序列号(0x2A25)');
    }
    let model = await FujifilmBleService.readText(FujifilmBleIds.CHAR_MODEL_NUMBER_STD, '机型(0x2A24)');
    if (model.length === 0 && advertisement !== undefined) model = advertisement.name;
    const mac = await FujifilmBleService.readText(FujifilmBleIds.CHAR_MAC_ADDRESS, 'WiFi MAC');
    const yNumber = await FujifilmBleService.readText(FujifilmBleService.CHAR_Y_NUMBER_PENDING, 'Y 号');
    const firmware = await FujifilmBleService.readFirmwareVersion();
    const identity: FujifilmIdentity = {
      serial: serial,
      model: model,
      yNumber: yNumber,
      mac: mac,
      firmware: firmware,
      red: advertisement !== undefined ? advertisement.red : false,
    };
    FujifilmBleService.log(`身份 serial=${identity.serial} model=${identity.model} ` +
      `mac=${identity.mac} fw=${identity.firmware} y=${identity.yNumber} red=${identity.red ? 1 : 0}`);
    return identity;
  }

  /** 标准 GATT 固件版本特征 0x2A26（UTF-8/ASCII）。读不到返回 ''。 */
  static async readFirmwareVersion(): Promise<string> {
    try {
      const data = await FujifilmBleService.readValue(FujifilmBleIds.CHAR_FIRMWARE_REVISION,
        '固件版本(0x2A26)', false);
      return FujifilmBleService.asciiUntilNul(data);
    } catch (error) {
      FujifilmBleService.log(`读固件版本失败：${FujifilmBleService.describe(error)}`);
      return '';
    }
  }

  /**
   * WiFi 凭据：SSID `BF6DC9CF` / 密码 `E809256A`，UTF-8 读到 0x00。
   *
   * `01 §8.4`：密码读失败**立即断开**并把错误抛给调用方 —— 不能拿空密码去连
   * 相机热点；密码只留在内存，不进任何持久化。
   */
  static async readWifiCredentials(): Promise<FujifilmWifiCredential> {
    let ssid = '';
    try {
      const data = await FujifilmBleService.readValue(FujifilmBleIds.CHAR_SSID, 'SSID', false);
      ssid = FujifilmBleService.asciiUntilNul(data);
    } catch (error) {
      FujifilmBleService.log(`读 SSID 失败：${FujifilmBleService.describe(error)}`);
    }
    if (ssid.length === 0) {
      await FujifilmBleService.disconnect();
      throw new Error('读相机 SSID 失败，请重新配对后再试');
    }
    let passphrase = '';
    let failure: string = '';
    try {
      const data = await FujifilmBleService.readValue(FujifilmBleIds.CHAR_PASSPHRASE, 'WiFi 密码', true);
      passphrase = FujifilmBleService.asciiUntilNul(data);
    } catch (error) {
      failure = FujifilmBleService.describe(error);
    }
    if (passphrase.length === 0) {
      await FujifilmBleService.disconnect();
      throw new Error(failure.length > 0
        ? `读相机 Wi-Fi 密码失败：${failure}` : '相机返回的 Wi-Fi 密码为空，请重新配对后再试');
    }
    FujifilmBleService.log(`凭据已读取 ssid=${ssid}（密码 ${passphrase.length} 字符，不落日志）`);
    return { ssid: ssid, passphrase: passphrase };
  }

  // -------------------------------------------------------------------------
  // 功能拉起 / AP 状态
  // -------------------------------------------------------------------------

  /** 写 `600655E6` = u16 LE（3=图传 4=遥控 5=相机设置/固件）。 */
  static async launch(kind: number): Promise<boolean> {
    const allowed = kind === FujifilmBleIds.LAUNCH_IN_CAMERA_VIEWING ||
      kind === FujifilmBleIds.LAUNCH_REMOTE_SHOOTING ||
      kind === FujifilmBleIds.LAUNCH_UPDATE_FIRMWARE;
    if (!allowed) {
      FujifilmBleService.log(`功能启动值非法：${kind}（只允许 3/4/5）`);
      return false;
    }
    if (!FujifilmBleService.isConnected()) {
      FujifilmBleService.log('功能启动失败：GATT 未连接');
      return false;
    }
    FujifilmBleService.apStateValue = -1;
    const written = await FujifilmBleService.writeValue(FujifilmBleIds.CHAR_FUNCTION_LAUNCH,
      `功能启动(${kind})`, FujifilmBytes.u16(kind));
    FujifilmBleService.log(written ? `功能启动已写 ${kind}，等待 AP_STATE` : `功能启动写入失败 ${kind}`);
    return written;
  }

  /** 等 AP_STATE = 0x8001（热点就绪）；超时返回 false。 */
  static async waitApReady(timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (FujifilmBleService.apStateValue === FujifilmBleIds.AP_STATE_LAUNCHED) {
        FujifilmBleService.log('AP_STATE = 0x8001，热点已就绪');
        return true;
      }
      await FujifilmBleService.delay(FujifilmBleTuning.AP_POLL_MS);
    }
    const ready = FujifilmBleService.apStateValue === FujifilmBleIds.AP_STATE_LAUNCHED;
    FujifilmBleService.log(`等待 AP_STATE 超时（最后值 ${FujifilmBytes.hex(FujifilmBleService.apStateValue, 4)}）`);
    return ready;
  }

  static lastApState(): number {
    return FujifilmBleService.apStateValue;
  }

  // -------------------------------------------------------------------------
  // 通用特征通道（固件服务注入用）
  // -------------------------------------------------------------------------

  /**
   * 写任意特征（固件的 92 B 请求就走这里）。
   *
   * 这三条固件特征（`CHAR_FW_UPDATE_*`）**不需要先订阅通知**：相机把请求当普通
   * 写特征收，状态用读回。写入串行化，避免与控制页的读特征交叉（BLE 同一时刻
   * 只允许一个 GATT 操作）。
   */
  static async writeCharacteristic(uuid: string, value: Uint8Array): Promise<boolean> {
    if (!FujifilmBleService.isConnected()) {
      FujifilmBleService.log(`写特征 ${uuid} 失败：GATT 未连接`);
      return false;
    }
    await FujifilmBleService.acquireIo();
    try {
      return await FujifilmBleService.writeValue(uuid, `特征 ${uuid}`, value);
    } finally {
      FujifilmBleService.releaseIo();
    }
  }

  /**
   * 读任意特征（固件状态 29 B 就走这里）。
   *
   * 失败或超时返回 `null`，不抛异常：调用方（固件服务）用 `null` 表示"这一轮没
   * 读到"，与"值是空"区分开。`timeoutMs` 是毫秒，缺省 5000。
   */
  static async readCharacteristic(uuid: string, timeoutMs: number = 5000): Promise<Uint8Array | null> {
    if (!FujifilmBleService.isConnected()) {
      FujifilmBleService.log(`读特征 ${uuid} 失败：GATT 未连接`);
      return null;
    }
    await FujifilmBleService.acquireIo();
    try {
      return await FujifilmBleService.readValueWithin(uuid, timeoutMs);
    } catch (error) {
      FujifilmBleService.log(`读特征 ${uuid} 失败：${FujifilmBleService.describe(error)}`);
      return null;
    } finally {
      FujifilmBleService.releaseIo();
    }
  }

  /** GATT 读 + 超时；超时抛错，由 `readCharacteristic` 转成 null。 */
  private static readValueWithin(uuid: string, timeoutMs: number): Promise<Uint8Array> {
    return new Promise<Uint8Array>((resolve: (value: Uint8Array) => void,
      reject: (reason: Error) => void): void => {
      let settled = false;
      const timer = setTimeout((): void => {
        if (settled) return;
        settled = true;
        reject(new Error(`读特征超时（${timeoutMs}ms）`));
      }, timeoutMs) as number;
      FujifilmBleService.readValue(uuid, `特征 ${uuid}`, false).then((value: Uint8Array): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      }).catch((error: Error): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
      });
    });
  }

  /** 串行锁：BLE 同一时刻只允许一个 GATT 操作，跨页面调用也要排队。 */
  private static async acquireIo(): Promise<void> {
    while (FujifilmBleService.ioBusy) {
      await FujifilmBleService.delay(20);
    }
    FujifilmBleService.ioBusy = true;
  }

  private static releaseIo(): void {
    FujifilmBleService.ioBusy = false;
  }

  // -------------------------------------------------------------------------
  // 读写工具
  // -------------------------------------------------------------------------

  private static async readValue(uuid: string, label: string, secret: boolean): Promise<Uint8Array> {
    const gatt = FujifilmBleService.gatt;
    if (gatt === null || !FujifilmBleService.connected) throw new Error('GATT 未连接');
    const characteristic = FujifilmBleService.findCharacteristic(uuid);
    if (characteristic === null) throw new Error(`相机没有「${label}」特征（${uuid}）`);
    const result = await gatt.readCharacteristicValue(LumixImportPrototype.asCharacteristic(characteristic));
    const value = result !== undefined && result.characteristicValue !== undefined
      ? new Uint8Array(result.characteristicValue) : new Uint8Array(0);
    FujifilmBleService.log(`读「${label}」len=${value.length}` +
      (secret ? '（内容不落日志）' : ` bytes=${FujifilmBytes.hexBytes(value, 16)}`));
    return value;
  }

  private static async writeValue(uuid: string, label: string, data: Uint8Array): Promise<boolean> {
    const gatt = FujifilmBleService.gatt;
    if (gatt === null || !FujifilmBleService.connected) {
      FujifilmBleService.log(`写「${label}」失败：GATT 未连接`);
      return false;
    }
    const characteristic = FujifilmBleService.findCharacteristic(uuid);
    if (characteristic === null) {
      FujifilmBleService.log(`写「${label}」失败：相机没有该特征（${uuid}）`);
      return false;
    }
    try {
      const item = LumixImportPrototype.asCharacteristic(characteristic);
      item.characteristicValue = data.buffer.slice(data.byteOffset,
        data.byteOffset + data.byteLength) as ArrayBuffer;
      try {
        await gatt.writeCharacteristicValue(item, ble.GattWriteType.WRITE);
      } catch (_error) {
        await gatt.writeCharacteristicValue(item, ble.GattWriteType.WRITE_NO_RESPONSE);
      }
      FujifilmBleService.log(`写「${label}」len=${data.length} 成功`);
      return true;
    } catch (error) {
      FujifilmBleService.log(`写「${label}」失败：${FujifilmBleService.describe(error)}`);
      return false;
    }
  }

  private static async readText(uuid: string, label: string): Promise<string> {
    try {
      const data = await FujifilmBleService.readValue(uuid, label, false);
      return FujifilmBleService.asciiUntilNul(data);
    } catch (error) {
      FujifilmBleService.log(`读「${label}」失败：${FujifilmBleService.describe(error)}`);
      return '';
    }
  }

  /** UTF-8 有效字节（到首个 0x00 为止）；解不出来时退回逐字节 ASCII。 */
  private static asciiUntilNul(data: Uint8Array): string {
    if (data.length === 0) return '';
    let end = data.length;
    for (let index = 0; index < data.length; index++) {
      if (data[index] === 0) {
        end = index;
        break;
      }
    }
    if (end === 0) return '';
    const slice = data.subarray(0, end);
    try {
      return util.TextDecoder.create('utf-8').decodeToString(slice).trim();
    } catch (_error) {
      let text = '';
      for (let index = 0; index < slice.length; index++) {
        text += String.fromCharCode(slice[index]);
      }
      return text.trim();
    }
  }

  private static delay(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, milliseconds);
    });
  }

  private static describe(error: Object): string {
    const typed = error as Error;
    return typed !== null && typed !== undefined && typed.message !== undefined ? typed.message : String(error);
  }

  private static log(message: string): void {
    try {
      hilog.info(0x0001, 'VIVID_FUJI_BLE', '%{public}s', message);
    } catch (_error) {
    }
    AppLogSink.emit('[FUJI]', message);
  }
}
