/**
 * Sony BLE pairing -> Wi-Fi credential provisioning.
 *
 * This is the Sony counterpart of the Nikon line's BLE step: it pairs over
 * Bluetooth using Sony's private pairing service, switches the camera Wi-Fi on,
 * reads the AP credentials the body hands back, and joins that network so the
 * existing PTP/IP transfer and camera-control code can take over.
 *
 * Relationship to the other Sony modules
 * --------------------------------------
 *   SonyCameraService     identity, the confirmed GATT layout and wire decoders
 *   SonyBleProvisioning   this file: discovery + the pairing/provisioning flow
 *   NikonPtpIpService     Wi-Fi image transfer and camera control (shared: Sony
 *                         speaks standard ISO 15740 PTP/IP like Nikon does)
 *
 * Two entry points, in the order the user drives them
 * ---------------------------------------------------
 *   pairOnly(trace, deviceId)   Bluetooth only: discover, GATT connect, read the
 *                               identity, run the pairing handshake, wait for
 *                               the Classic Bluetooth bond. Sends no Wi-Fi
 *                               command and reads no credential.
 *   startWifi(trace, deviceId)  On demand: reconnect GATT, write the Wi-Fi-on
 *                               command, read CC06/CC07/CC0C and join the AP.
 *                               Idempotent while the phone is already on the
 *                               camera's network.
 *   provision(trace, deviceId)  Legacy composition of both, for callers that
 *                               genuinely want the whole chain in one call.
 *
 * Transport is deliberately borrowed, not duplicated: `connectGatt`,
 * `enableNotification`, `readGatt`, `writeGatt` and `connectWifi` on
 * `LumixImportPrototype` contain no brand-specific logic, so the Sony route
 * reuses them exactly as the Nikon route does. Only discovery and the pairing
 * wire differ, because Sony advertises a private service and manufacturer data
 * rather than Nikon's SnapBridge service.
 *
 * Protocol facts (all from Sony's own Creators' App 3.5.0)
 * --------------------------------------------------------
 *   - Pairing service 8000EE00-EE00-FFFF-FFFF-FFFFFFFFFFFF
 *     write 0000EE01 = {6,8,1,0,0,0,0} to start pairing
 *     notify 0000EE03 = 7-byte [len][0][0][type][v31..v7] state(1)/result(2)
 *     read  0000EE04 = [len][type_hi][type_lo][fwLen][fw][modelLen][model]
 *   - Control service 8000CC00-CC00-FFFF-FFFF-FFFFFFFFFFFF
 *     write 0000CC08 = {1} to switch the camera Wi-Fi on
 *     read  0000CC06 = SSID, 0000CC07 = password, 0000CC0C = BSSID
 *     each credential read carries a 3-byte [len][type_hi][type_lo] header
 *   - Nine pairing states and ten result codes are decoded by SonyCameraService.
 *
 * Not implemented on purpose
 * --------------------------
 * DiRxTx (8000BB00) and its ECDH P-256 + AES-CTR "secure AP pouring" variant
 * encrypt credentials for the *reverse* case - the phone opens a hotspot and
 * hands its own AP credentials to the camera. This app only ever joins the
 * camera's AP, so the plain CC06/CC07 path is the one that applies.
 *
 * @since 2026-11
 */

import { ble, connection } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';
import { SonyCameraService } from './SonyCameraService';
import { LumixCameraService } from './LumixCameraService';
import { LumixImportPrototype, WifiConnection } from './LumixImportPrototype';

const DOMAIN: number = 0x0001;
const TAG: string = 'VIVID_SONY_BLE';

/** How long to scan for a Sony advertisement. */
const SCAN_TIMEOUT_MS: number = 15000;
/** How long to wait for one pairing notification on 0000EE03. */
const PAIRING_NOTIFICATION_TIMEOUT_MS: number = 30000;
/** How long to wait for the camera Wi-Fi to come up after the CC08 write. */
const WIFI_ON_SETTLE_MS: number = 4000;
/** Grace period before requesting the Classic Bluetooth bond even if the camera
 * never announces the BTC stage on EE03. */
const BOND_FALLBACK_MS: number = 2500;
/** Time allowed for a freshly requested bond to settle before the encrypted
 * link is used for a GATT write. */
const BOND_SETTLE_MS: number = 1500;

export interface SonyProvisionResult {
  ok: boolean;
  stage: string;
  message: string;
  ssid: string;
  password: string;
  /** BSSID read from 0000CC0C; empty when the body does not expose it. */
  bssid: string;
  gateway: string;
  ipAddress: string;
  /** Model name reported by the camera over 0000EE04. */
  model: string;
  /** Firmware version reported by the camera over 0000EE04. */
  firmware: string;
}

/** One re-established GATT link: the client plus the address that answered it.
 *
 * The address is returned because a completed Classic Bluetooth bond can hand
 * the body a new BLE address, so the value the caller passed in is not
 * guaranteed to be the one that worked. */
interface SonyGattLink {
  gatt: ble.GattClientDevice;
  deviceId: string;
}

/** CC0D 能力位的解析结果：短摘要进诊断报告，明细进日志。 */
interface SonyCapabilityDecode {
  summary: string;
  detail: string;
}

export class SonyBleProvisioning {
  /** Most recent GATT client, kept so a caller can close it explicitly. */
  private static activeGatt: ble.GattClientDevice | null = null;
  /** Address resolved by the last successful discovery, so the Wi-Fi leg of a
   * later call can skip a second 15-second scan when the caller has no address
   * at hand. */
  private static lastDeviceId: string = '';
  /** SSID the phone was last placed on by startWifi. Together with the Sony AP
   * naming pattern this makes the Wi-Fi leg idempotent without touching GATT
   * again. */
  private static lastJoinedSsid: string = '';

  private static log(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
    AppLogSink.emit('CTL', message);
  }

  /** A result with every field present, so no caller ever receives a hole. */
  private static emptyResult(): SonyProvisionResult {
    return {
      ok: false,
      stage: 'init',
      message: '',
      ssid: '',
      password: '',
      bssid: '',
      gateway: '',
      ipAddress: '',
      model: '',
      firmware: '',
    };
  }

  private static async delay(milliseconds: number): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => { resolve(); }, milliseconds);
    });
  }

  /**
   * Finds a nearby Sony body.
   *
   * Admission is deliberately narrow, mirroring the Nikon route: the
   * manufacturer data must decode to a Sony *camera* payload, or the advertised
   * name must resolve to a known Sony model through the shared identity table.
   * Matching on a bare "SONY" prefix would admit TVs, headphones and speakers.
   */
  static async findCamera(trace: string[], preferredDeviceId: string = ''): Promise<string> {
    if (preferredDeviceId.length > 0) {
      trace.push('Sony BLE reusing established address; discovery skipped');
      return preferredDeviceId;
    }
    let found = '';
    let loggedDevices = 0;
    const callback = (results: Array<ble.ScanResult>): void => {
      for (const result of results) {
        if (!result.deviceId || found.length > 0) {
          continue;
        }
        const advertised = SonyCameraService.parseSonyAdvertisement(result.data);
        const name = SonyBleProvisioning.advertisedName(result.data);
        const identity = SonyCameraService.identifyBluetoothName(name);
        // A Sony camera payload is authoritative; a known model name is the
        // fallback for bodies whose manufacturer data the platform truncates.
        const isSony = advertised.isSonyCamera || identity !== null;
        // Log a bounded sample of everything in range. If the camera is
        // advertising but our parser rejects it, the raw AD bytes are the only
        // way to see why; they also reveal a body that never advertises Sony's
        // company id at all.
        if (loggedDevices < 12) {
          loggedDevices++;
          trace.push('Sony scan seen name=' + (name.length > 0 ? name : '(none)') +
            ' rssi=' + result.rssi + ' sonyCompany=' + advertised.isSony +
            ' sonyCamera=' + advertised.isSonyCamera +
            ' raw=' + SonyBleProvisioning.hex(result.data));
        }
        if (!isSony) {
          continue;
        }
        found = result.deviceId;
        trace.push('Sony BLE advertisement accepted name=' + (name.length > 0 ? name : '(none)') +
          // connectable=false means the body only ever beacons and a GATT
          // connect to this address will fail every time.
          ' connectable=' + result.connectable +
          ' modelCode=' + (advertised.modelCode.length > 0 ? advertised.modelCode : '-') +
          ' pairingSupported=' + advertised.pairingSupported +
          ' pairingEnabled=' + advertised.pairingEnabled +
          ' remoteControl=' + advertised.remoteControlSupported +
          ' imageTransfer=' + advertised.imageTransferSupported);
      }
    };
    let startedScan = false;
    try {
      ble.on('BLEDeviceFind', callback);
      ble.startBLEScan(null, {
        interval: 0,
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
      });
      startedScan = true;
      const deadline = Date.now() + SCAN_TIMEOUT_MS;
      while (found.length === 0 && Date.now() < deadline) {
        await SonyBleProvisioning.delay(200);
      }
    } catch (error) {
      trace.push('Sony BLE scan error: ' + (error as Error).message);
    } finally {
      // Only tear down a scan this call actually started. The camera page runs
      // its own discovery scan; stopping that one would blank the nearby-camera
      // list. When the start was refused because a scan is already running, our
      // BLEDeviceFind callback still receives that scan's results, so the
      // camera can be found without owning the scan.
      if (startedScan) {
        try { ble.stopBLEScan(); } catch (_error) { }
      }
      try { ble.off('BLEDeviceFind', callback); } catch (_error) { }
    }
    if (found.length === 0) {
      trace.push('Sony BLE scan filter=none; admitted on Sony camera manufacturer data or a known model name');
    }
    return found;
  }

  /** Read the complete/short local name out of a raw BLE AD payload. */
  /** Hex dump of a raw AD payload, for diagnosing a rejected advertisement. */
  private static hex(data: ArrayBuffer): string {
    if (!data) {
      return '(none)';
    }
    const bytes = new Uint8Array(data);
    let text = '';
    for (let index = 0; index < bytes.length && index < 31; index++) {
      text += bytes[index].toString(16).padStart(2, '0');
    }
    return text.length > 0 ? text : '(empty)';
  }

  private static advertisedName(data: ArrayBuffer): string {
    if (!data || data.byteLength < 3) {
      return '';
    }
    const bytes = new Uint8Array(data);
    let offset = 0;
    while (offset < bytes.length) {
      const length = bytes[offset];
      if (length === 0) {
        break;
      }
      const end = offset + 1 + length;
      if (end > bytes.length || length < 1) {
        break;
      }
      // 0x08 = shortened local name, 0x09 = complete local name.
      if (bytes[offset + 1] === 0x08 || bytes[offset + 1] === 0x09) {
        let text = '';
        for (let index = offset + 2; index < end; index++) {
          const code = bytes[index];
          if (code === 0) {
            break;
          }
          if (code < 0x20 || code > 0x7E) {
            text = '';
            break;
          }
          text += String.fromCharCode(code);
        }
        if (text.length > 0) {
          return text;
        }
      }
      offset = end;
    }
    return '';
  }

  /** Reduce a UUID to its 16-bit assigned value for comparison.
   *
   * HarmonyOS reports a UUID in whichever form it holds: the full
   * "0000EE01-EE00-FFFF-FFFF-FFFFFFFFFFFF", the shortened "0000EE01", or the
   * bare "EE01". All three denote the same 16-bit value. The first group is
   * therefore normalised by dropping leading zeros rather than being truncated
   * to a fixed width: a fixed 8-character slice compared "0000ee01" against
   * "ee01" and never matched.
   */
  private static assignedUuid(uuid: string): string {
    const lowered = uuid.toLowerCase().trim();
    const dash = lowered.indexOf('-');
    const first = dash >= 0 ? lowered.substring(0, dash) : lowered;
    const stripped = first.replace(/^0+/, '');
    return stripped.length > 0 ? stripped : '0';
  }

  /** Locate a characteristic by its 16-bit assigned UUID. */
  private static findCharacteristic(services: Array<ble.GattService>,
    uuid: string): ble.BLECharacteristic | undefined {
    const wanted = SonyBleProvisioning.assignedUuid(uuid);
    for (const service of services) {
      for (const characteristic of service.characteristics) {
        if (SonyBleProvisioning.assignedUuid(characteristic.characteristicUuid) === wanted) {
          return characteristic;
        }
      }
    }
    return undefined;
  }

  private static hasService(services: Array<ble.GattService>, uuid: string): boolean {
    const wanted = SonyBleProvisioning.assignedUuid(uuid);
    return services.some((service: ble.GattService): boolean =>
      SonyBleProvisioning.assignedUuid(service.serviceUuid) === wanted);
  }

  /**
   * UUIDs of the characteristics under one service, for diagnostics.
   *
   * When a characteristic cannot be located this is the evidence that separates
   * "the body exposes a different layout" from "our match is wrong".
   */
  private static characteristicsOf(services: Array<ble.GattService>, serviceUuid: string): string {
    const wanted = SonyBleProvisioning.assignedUuid(serviceUuid);
    for (const service of services) {
      if (SonyBleProvisioning.assignedUuid(service.serviceUuid) !== wanted) {
        continue;
      }
      const list: string[] = [];
      for (const characteristic of service.characteristics) {
        list.push(characteristic.characteristicUuid);
      }
      return list.length > 0 ? list.join(' ') : '(no characteristics)';
    }
    return '(service absent)';
  }

  /** The whole GATT map as one line: every service with its characteristics.
   * Reported verbatim when pairing characteristics cannot be located, so the
   * failure dialog carries the full layout instead of a guess. */
  private static fullLayout(services: Array<ble.GattService>): string {
    const parts: string[] = [];
    for (const service of services) {
      const chars: string[] = [];
      for (const characteristic of service.characteristics) {
        chars.push(characteristic.characteristicUuid);
      }
      parts.push(service.serviceUuid + '[' + (chars.length > 0 ? chars.join(' ') : '-') + ']');
    }
    return parts.length > 0 ? parts.join(' | ') : '(no services)';
  }

  /**
   * Write the pairing trigger, trying both GATT write types.
   *
   * writeGatt() picks one type from the characteristic's properties and throws
   * on failure. The camera answered the first attempt with the generic 2900099
   * "operation failed", which does not distinguish a wrong write type from a
   * rejected payload or an unusable link - and a wrong write type is the one
   * cause that a second attempt can actually fix.
   */
  private static async writeCommandWithFallback(gatt: ble.GattClientDevice,
    characteristic: ble.BLECharacteristic, bytes: Uint8Array, trace: string[],
    preferred: ble.GattWriteType): Promise<boolean> {
    const order: ble.GattWriteType[] = preferred === ble.GattWriteType.WRITE
      ? [ble.GattWriteType.WRITE, ble.GattWriteType.WRITE_NO_RESPONSE]
      : [ble.GattWriteType.WRITE_NO_RESPONSE, ble.GattWriteType.WRITE];
    for (let attempt = 0; attempt < order.length; attempt++) {
      const writeType = order[attempt];
      const label = writeType === ble.GattWriteType.WRITE ? 'WRITE' : 'WRITE_NO_RESPONSE';
      const item = LumixImportPrototype.asCharacteristic(characteristic);
      item.characteristicValue = bytes.buffer as ArrayBuffer;
      try {
        await gatt.writeCharacteristicValue(item, writeType);
        trace.push('Sony write-result ' + item.characteristicUuid + ' type=' + label + ' status=success');
        return true;
      } catch (error) {
        const code = (error as BusinessError).code;
        trace.push('Sony write-result ' + item.characteristicUuid + ' type=' + label +
          ' status=error code=' + (code === undefined ? 'unknown' : String(code)));
      }
    }
    return false;
  }

  /**
   * Bluetooth-only half of the Sony route: discover -> GATT connect -> read the
   * body identity -> pairing handshake -> wait for the Classic Bluetooth bond.
   *
   * It stops the moment pairing is confirmed. It deliberately sends no Wi-Fi-on
   * command, reads no credential characteristic and joins no network: the body
   * must sit idle until the user actually asks for image transfer or camera
   * control, which is when {@link startWifi} raises the access point. Pairing
   * credentials are therefore never pre-cached here.
   */
  static async pairOnly(trace: string[], preferredDeviceId: string = ''): Promise<SonyProvisionResult> {
    const result = SonyBleProvisioning.emptyResult();

    const deviceId = await SonyBleProvisioning.findCamera(trace, preferredDeviceId);
    if (deviceId.length === 0) {
      result.stage = 'scan';
      result.message = '未发现索尼 BLE 广播；请在相机上打开蓝牙并进入配对窗口';
      SonyBleProvisioning.log(result.message);
      return result;
    }
    trace.push('Sony BLE deviceId=' + deviceId);
    SonyBleProvisioning.lastDeviceId = deviceId;

    let gatt: ble.GattClientDevice | null = null;
    try {
      gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
      SonyBleProvisioning.activeGatt = gatt;
      // 64 matches the proven Nikon negotiation. 158 is the DiRxTx frame MTU,
      // which only matters for bulk image frames; the pairing and credential
      // characteristics carry short values, so there is no reason to ask for an
      // MTU the controller may not grant on this path.
      try {
        trace.push('Sony GATT MTU negotiated=' + (await gatt.setBLEMtu(64)));
      } catch (_error) {
        trace.push('Sony GATT MTU=platform default');
      }

      const services = await gatt.getServices();
      for (const service of services) {
        trace.push('Sony service ' + service.serviceUuid);
        // Log the characteristics too, not just the services. Without them a
        // stall cannot be told apart between "this body exposes a different
        // layout" and "our UUID constants are wrong" - which is exactly the
        // question when pairing fails to advance.
        for (const characteristic of service.characteristics) {
          let flags = '';
          // properties is optional on BLECharacteristic, so it must be tested
          // explicitly: a try/catch satisfies the runtime but not the ArkTS
          // strict null check, which rejected the direct field access.
          const props = characteristic.properties;
          if (props !== undefined) {
            flags = ` R=${props.read} W=${props.write} N=${props.notify} I=${props.indicate}`;
          }
          trace.push('Sony   char ' + characteristic.characteristicUuid + flags);
        }
      }

      // ---- Read the camera identity before pairing, so a successful run can
      // report which body was paired (and the UI can show the model).
      const infoCharacteristic = SonyBleProvisioning.findCharacteristic(services,
        SonyCameraService.PAIRING_INFO_CHARACTERISTIC);
      if (infoCharacteristic) {
        try {
          const raw = new Uint8Array(await LumixImportPrototype.readGatt(gatt, infoCharacteristic, trace));
          const identity = SonyCameraService.parsePairingIdentity(raw);
          if (identity) {
            result.model = identity.model;
            result.firmware = identity.firmware;
            trace.push('Sony identity model=' + identity.model + ' firmware=' + identity.firmware);
          }
        } catch (error) {
          trace.push('Sony identity read failed (continuing): ' + (error as Error).message);
        }
      } else {
        trace.push('Sony pairing info characteristic not present');
      }

      // ---- Pairing: subscribe to 0000EE03, then trigger with 0000EE01.
      const notifyCharacteristic = SonyBleProvisioning.findCharacteristic(services,
        SonyCameraService.PAIRING_NOTIFY_CHARACTERISTIC);
      const commandCharacteristic = SonyBleProvisioning.findCharacteristic(services,
        SonyCameraService.PAIRING_COMMAND_CHARACTERISTIC);
      // Actual layout of the pairing service, quoted in any failure below so the
      // dialog alone shows what the body really exposes.
      const pairingLayout = SonyBleProvisioning.characteristicsOf(services,
        SonyCameraService.PAIRING_SERVICE);
      const gattLayout = SonyBleProvisioning.fullLayout(services);
      trace.push('Sony pairing service characteristics: ' + pairingLayout);
      trace.push('Sony GATT layout: ' + gattLayout);

      if (!SonyBleProvisioning.hasService(services, SonyCameraService.PAIRING_SERVICE)) {
        result.stage = 'service';
        result.message = '索尼 BLE 已连接，但未发现配对服务；未发送猜测指令';
        SonyBleProvisioning.log(result.message);
        return result;
      }
      if (!commandCharacteristic) {
        result.stage = 'service';
        result.message = '索尼配对服务缺少配对指令特征（EE01）。配对服务实际暴露：' + pairingLayout +
          '；完整 GATT 表：' + gattLayout;
        SonyBleProvisioning.log(result.message);
        return result;
      }
      if (!notifyCharacteristic) {
        result.stage = 'service';
        result.message = '索尼配对服务缺少状态通知特征（EE03）。配对服务实际暴露：' + pairingLayout +
          '；完整 GATT 表：' + gattLayout;
        SonyBleProvisioning.log(result.message);
        return result;
      }

      const notifications: Uint8Array[] = [];
      // This body runs on the BLE stack's callback, not on our async flow. An
      // exception raised here escapes into native code, where nothing can catch
      // it and the whole process is taken down - so the entire body is guarded.
      // Two further hazards are handled explicitly:
      //  - characteristicValue is typed ArrayBuffer but the stack can hand back
      //    an absent value; the length is taken from the Uint8Array view so no
      //    property is dereferenced on it directly;
      //  - the returned buffer is reused by the stack, so the bytes are copied
      //    before the callback returns.
      const handler = (changed: ble.BLECharacteristic): void => {
        try {
          const uuid = changed.characteristicUuid;
          // Same normalisation as findCharacteristic. The notify characteristic
          // is reported shortened, so a full-UUID comparison here would
          // silently discard every pairing state notification - the write would
          // appear to succeed and then nothing would ever arrive.
          if (SonyBleProvisioning.assignedUuid(uuid) !==
            SonyBleProvisioning.assignedUuid(SonyCameraService.PAIRING_NOTIFY_CHARACTERISTIC)) {
            return;
          }
          const bytes = new Uint8Array(changed.characteristicValue);
          notifications.push(bytes.slice());
          trace.push('Sony notify ' + uuid + ' len=' + bytes.length);
        } catch (error) {
          trace.push('Sony notify handler error (ignored): ' + (error as Error).message);
        }
      };
      // ---- Bond before the GATT exchange.
      //
      // The trigger write was rejected with the generic 2900099 "operation
      // failed". Sony's own client gates this flow on isReadyToBond() and bonds
      // through the platform *before* it exchanges pairing data. A
      // characteristic that requires an encrypted link fails exactly this way:
      // the stack surfaces no specific "insufficient authentication" code, only
      // a generic failure. Requested at most once.
      let bondRequested = false;
      const ensureSystemBond = async (): Promise<void> => {
        if (bondRequested) {
          return;
        }
        bondRequested = true;
        try {
          if (connection.getPairState(deviceId) === connection.BondState.BOND_STATE_BONDED) {
            trace.push('Sony BTC bond already present');
            return;
          }
        } catch (_error) {
        }
        try {
          await connection.pairDevice(deviceId);
          trace.push('Sony BTC system bond requested');
          // Let the bond settle before using the freshly encrypted link.
          await SonyBleProvisioning.delay(BOND_SETTLE_MS);
        } catch (error) {
          trace.push('Sony BTC system bond rejected: ' + (error as Error).message);
        }
      };
      await ensureSystemBond();

      gatt.on('BLECharacteristicChange', handler);
      await LumixImportPrototype.enableNotification(gatt, notifyCharacteristic, trace);

      // ---- Trigger pairing. The write type comes from the characteristic's
      // properties, with the other type as a fallback: 2900099 does not say
      // whether the write type, the payload or the link state was at fault, and
      // a wrong write type is the one cause a second attempt can fix.
      const commandProps = commandCharacteristic.properties;
      const preferredType = (commandProps !== undefined && commandProps.write === true)
        ? ble.GattWriteType.WRITE : ble.GattWriteType.WRITE_NO_RESPONSE;
      const wrote = await SonyBleProvisioning.writeCommandWithFallback(gatt,
        commandCharacteristic, new Uint8Array(SonyCameraService.PAIRING_COMMAND_PAYLOAD),
        trace, preferredType);
      if (!wrote) {
        result.stage = 'exception';
        result.message = '索尼配对指令写入失败：GATT 两种写类型都被相机拒绝（2900099）。' +
          '相机可能要求先完成系统级蓝牙配对，或该特征需要加密链路。';
        SonyBleProvisioning.log(result.message);
        return result;
      }
      trace.push('Sony pairing command written');

      // ---- Sony pairing is two-stage: the trigger above only puts the camera
      // into pairing mode; the EE03 state machine then announces the Classic
      // Bluetooth stage as BTC_ENABLED(4) / BTC_REQUEST_RECEIVED(5) and reports
      // BTC_PAIRING_SUCCESS(8). The bond was already requested above, so the
      // calls inside the wait loop below are no-ops kept as a safety net.

      // ---- Wait for a terminal state/result from the camera.
      const deadline = Date.now() + PAIRING_NOTIFICATION_TIMEOUT_MS;
      // If the body never announces the BTC stage on EE03, ask for the bond
      // anyway after a short grace period so the BLE stage can finish first.
      const bondFallbackAt = Date.now() + BOND_FALLBACK_MS;
      let paired = false;
      let failureMessage = '';
      while (Date.now() < deadline) {
        // The Classic Bluetooth bond is the authoritative success signal for
        // Sony's pairing, and it is the state the camera's own screen reports.
        // Observed on ILCE-7M4: the body showed the pairing as successful while
        // EE03 delivered no notification at all, so waiting on the notification
        // alone timed out on a pairing that had in fact completed.
        try {
          if (connection.getPairState(deviceId) === connection.BondState.BOND_STATE_BONDED) {
            paired = true;
            trace.push('Sony pairing confirmed by system bond state');
            break;
          }
        } catch (_error) {
        }
        if (notifications.length === 0) {
          if (Date.now() >= bondFallbackAt) {
            await ensureSystemBond();
          }
          await SonyBleProvisioning.delay(150);
          continue;
        }
        const frame = notifications.shift() as Uint8Array;
        const decoded = SonyCameraService.parsePairingNotification(frame);
        if (!decoded) {
          continue;
        }
        if (decoded.kind === 1) {
          const label = SonyCameraService.stateLabel(decoded.value);
          trace.push('Sony pairing state=' + decoded.value + ' (' + label + ')');
          // The camera has reached the BTC stage and is waiting for the OS bond.
          if (decoded.value === SonyCameraService.STATE_BTC_ENABLED ||
            decoded.value === SonyCameraService.STATE_BTC_REQUEST_RECEIVED) {
            await ensureSystemBond();
          }
          if (decoded.value === SonyCameraService.STATE_BTC_PAIRING_SUCCESS) {
            paired = true;
            break;
          }
          if (decoded.value === SonyCameraService.STATE_USER_CANCEL ||
            decoded.value === SonyCameraService.STATE_BLE_AUTH_REJECTED ||
            decoded.value === SonyCameraService.STATE_BTC_AUTH_REJECTED) {
            failureMessage = label;
            break;
          }
        } else {
          const label = SonyCameraService.resultLabel(decoded.value);
          trace.push('Sony pairing result=' + decoded.value + ' (' + label + ')');
          if (decoded.value === SonyCameraService.RESULT_SUCCESS) {
            paired = true;
            break;
          }
          failureMessage = label;
          break;
        }
      }

      if (!paired) {
        result.stage = 'pairing';
        result.message = failureMessage.length > 0
          ? `索尼蓝牙配对未完成：${failureMessage}`
          : '索尼蓝牙配对超时：相机未在配对窗口内回应，请在相机上确认配对后重试';
        SonyBleProvisioning.log(result.message);
        return result;
      }
      trace.push('Sony pairing confirmed');
      try { gatt.off('BLECharacteristicChange', handler); } catch (_error) { }

      // ---- Bluetooth only: stop here.
      //
      // Everything below this point in the old single-shot flow (CC08 Wi-Fi on,
      // CC06/CC07/CC0C credential reads, AP association) belongs to startWifi
      // and must not run merely because the user confirmed the connection: the
      // body would announce image import before the user asked for anything.
      SonyBleProvisioning.lastDeviceId = deviceId;
      result.ok = true;
      result.stage = 'paired';
      result.message = '索尼蓝牙配对完成';
      SonyBleProvisioning.log(result.message + ' model=' + (result.model.length > 0 ? result.model : '-'));
      return result;
    } catch (error) {
      result.stage = 'exception';
      result.message = '索尼蓝牙配对异常：' + (error as Error).message;
      SonyBleProvisioning.log(result.message);
      return result;
    }
  }

  /**
   * Wi-Fi half of the Sony route, raised on demand: reconnect GATT to the
   * already-paired body, switch its Wi-Fi on (0000CC08), read the credentials
   * the body hands back (0000CC06 / 0000CC07 / 0000CC0C) and join that access
   * point. The credentials are read here and never cached by pairOnly.
   *
   * Idempotent: when the phone is already associated with the camera's network
   * this returns success immediately without redoing any GATT work, so a second
   * tap on 「图片传输」/「相机控制」 costs nothing.
   */
  static async startWifi(trace: string[], preferredDeviceId: string = ''): Promise<SonyProvisionResult> {
    const result = SonyBleProvisioning.emptyResult();

    // ---- Already on the camera's network? Do nothing.
    const linked = await SonyBleProvisioning.linkedCameraWifi(trace);
    if (linked.connected) {
      result.ok = true;
      result.stage = 'wifi';
      result.message = '已接入相机 Wi‑Fi，无需重新连接';
      result.ssid = linked.ssid;
      result.gateway = linked.gateway;
      result.ipAddress = linked.ipAddress;
      SonyBleProvisioning.log(result.message + ' ssid=' + linked.ssid + ' gateway=' + linked.gateway);
      return result;
    }

    const link = await SonyBleProvisioning.reconnectGatt(trace, preferredDeviceId);
    if (link === null) {
      result.stage = 'ble';
      result.message = '索尼相机蓝牙未连接：无法重新连接相机以读取 Wi‑Fi 凭据，请确认相机蓝牙已开启并已与手机配对';
      SonyBleProvisioning.log(result.message);
      return result;
    }
    const gatt = link.gatt;
    SonyBleProvisioning.activeGatt = gatt;
    SonyBleProvisioning.lastDeviceId = link.deviceId;

    try {
      // 64 matches the proven Nikon negotiation and the pairing leg above.
      try {
        trace.push('Sony GATT MTU negotiated=' + (await gatt.setBLEMtu(64)));
      } catch (_error) {
        trace.push('Sony GATT MTU=platform default');
      }
      const services = await gatt.getServices();
      for (const service of services) {
        trace.push('Sony service ' + service.serviceUuid);
      }

      // ---- Switch the camera Wi-Fi on.
      const wifiOnCharacteristic = SonyBleProvisioning.findCharacteristic(services,
        SonyCameraService.WIFI_ON_CHARACTERISTIC);
      if (wifiOnCharacteristic) {
        try {
          await LumixImportPrototype.writeGatt(gatt, wifiOnCharacteristic,
            new Uint8Array(SonyCameraService.WIFI_ON_PAYLOAD), trace);
          trace.push('Sony Wi-Fi on command written');
          await SonyBleProvisioning.delay(WIFI_ON_SETTLE_MS);
        } catch (error) {
          trace.push('Sony Wi-Fi on write failed (continuing): ' + (error as Error).message);
        }
      } else {
        trace.push('Sony Wi-Fi on characteristic not present; assuming the AP is already up');
      }

      const ssidCharacteristic = SonyBleProvisioning.findCharacteristic(services,
        SonyCameraService.WIFI_SSID_CHARACTERISTIC);
      const passwordCharacteristic = SonyBleProvisioning.findCharacteristic(services,
        SonyCameraService.WIFI_PASSWORD_CHARACTERISTIC);
      const bssidCharacteristic = SonyBleProvisioning.findCharacteristic(services,
        SonyCameraService.WIFI_BSSID_CHARACTERISTIC);

      if (!ssidCharacteristic || !passwordCharacteristic) {
        result.stage = 'credentials';
        result.message = '相机未提供 Wi‑Fi 凭据特征（CC06/CC07）';
        SonyBleProvisioning.log(result.message);
        return result;
      }

      const ssid = await SonyBleProvisioning.readCredential(gatt, ssidCharacteristic, trace);
      if (ssid.length === 0) {
        result.stage = 'credentials';
        result.message = '相机未下发 Wi‑Fi 名称（CC06 为空）';
        SonyBleProvisioning.log(result.message);
        return result;
      }
      const password = await SonyBleProvisioning.readCredential(gatt, passwordCharacteristic, trace);
      if (password.length === 0) {
        result.stage = 'credentials';
        result.message = '相机未下发 Wi‑Fi 密码（CC07 为空）';
        SonyBleProvisioning.log(result.message);
        return result;
      }
      // The BSSID is optional: the official client skips it with a warning when
      // the read cannot be started.
      const bssid = bssidCharacteristic
        ? await SonyBleProvisioning.readCredential(gatt, bssidCharacteristic, trace) : '';
      result.ssid = ssid;
      result.password = password;
      result.bssid = bssid;
      trace.push('Sony credential received ssid=' + ssid + ' bssid=' + (bssid.length > 0 ? bssid : '-') +
        ' passwordLength=' + password.length);

      // ---- Join the camera access point.
      // skipScanWhenLinked=true: the camera control page may already have the
      // PTP/IP session up on this very AP. Discovery scanning here would fire a
      // startScan() every 2.5 s on the interface carrying that session and kill
      // it (proven on the ILCE-7M4: the transaction timed out, the session was
      // poisoned and the LiveViewUrl read never succeeded).
      const joined: WifiConnection = await LumixImportPrototype.connectWifi(ssid, password, trace, 1,
        (_attempt: number): void => { }, 75000, true);
      if (!joined.connected) {
        result.stage = 'wifi';
        result.message = '索尼相机 Wi‑Fi 未能加入，请确认相机已创建热点后重试';
        SonyBleProvisioning.log(result.message);
        return result;
      }
      SonyBleProvisioning.lastJoinedSsid = ssid;
      result.gateway = joined.gateway;
      result.ipAddress = joined.ipAddress;
      result.ok = true;
      result.stage = 'wifi';
      result.message = '已通过蓝牙获取相机 Wi‑Fi 并接入';
      SonyBleProvisioning.log(result.message + ' gateway=' + joined.gateway);
      return result;
    } catch (error) {
      result.stage = 'exception';
      result.message = '索尼相机 Wi‑Fi 连接异常：' + (error as Error).message;
      SonyBleProvisioning.log(result.message);
      return result;
    }
  }

  /**
   * Legacy single-shot route, kept as a thin composition of the two half-steps
   * above: pair over Bluetooth, then immediately raise the camera Wi-Fi and join
   * it. Callers that must not bring Wi-Fi up at confirmation time should use
   * {@link pairOnly} and {@link startWifi} separately instead.
   */
  static async provision(trace: string[], preferredDeviceId: string = ''): Promise<SonyProvisionResult> {
    const paired = await SonyBleProvisioning.pairOnly(trace, preferredDeviceId);
    if (!paired.ok) {
      return paired;
    }
    // The identity read during pairing is the only place the model and firmware
    // are reported, so it is carried onto whichever result is returned.
    const wifi = await SonyBleProvisioning.startWifi(trace, preferredDeviceId);
    wifi.model = paired.model;
    wifi.firmware = paired.firmware;
    if (!wifi.ok) {
      return wifi;
    }
    wifi.stage = 'complete';
    wifi.message = '索尼蓝牙配对完成，已接入相机 Wi‑Fi';
    SonyBleProvisioning.log(wifi.message + ' gateway=' + wifi.gateway);
    return wifi;
  }

  /**
   * Whether the phone is already associated with the camera's access point.
   *
   * Two relations are accepted: the SSID this process joined itself, and an SSID
   * that matches Sony's camera AP naming (DIRECT-<instance>:<model>). A linked
   * but unknown network never qualifies, so a home router can never be mistaken
   * for the camera.
   */
  private static async linkedCameraWifi(trace: string[]): Promise<WifiConnection> {
    const none: WifiConnection = { connected: false, ssid: '', gateway: '', ipAddress: '' };
    let linkedSsid = '';
    try {
      linkedSsid = (await LumixCameraService.linkedSsid()).replace(/^"|"$/g, '').trim();
    } catch (_error) {
      return none;
    }
    if (linkedSsid.length === 0) {
      return none;
    }
    const known = SonyBleProvisioning.lastJoinedSsid;
    const isCameraAp = (known.length > 0 && linkedSsid === known) ||
      SonyCameraService.identifyWifiSsid(linkedSsid) !== null;
    if (!isCameraAp) {
      return none;
    }
    // The DHCP lease can lag the association. Poll briefly instead of redoing
    // the GATT exchange the caller wanted to skip.
    let gateway = '';
    for (let attempt = 0; attempt < 6; attempt++) {
      try {
        gateway = await LumixCameraService.linkedGateway();
      } catch (_error) {
        gateway = '';
      }
      if (gateway.length > 0) {
        break;
      }
      await SonyBleProvisioning.delay(1000);
    }
    trace.push('Sony Wi-Fi already linked ssid=' + linkedSsid +
      ' gateway=' + (gateway.length > 0 ? gateway : '-'));
    return { connected: true, ssid: linkedSsid, gateway: gateway, ipAddress: '' };
  }

  /**
   * Re-establish GATT for the Wi-Fi leg, reusing the link the pairing leg left
   * open when it still answers.
   *
   * A completed Classic Bluetooth bond can drop the pre-bond LE link and hand
   * the body a new BLE address, so a fresh connection is attempted once when
   * the remembered address no longer answers.
   */
  private static async reconnectGatt(trace: string[], preferredDeviceId: string): Promise<SonyGattLink | null> {
    const existing = SonyBleProvisioning.activeGatt;
    if (existing !== null) {
      try {
        await existing.getServices();
        trace.push('Sony GATT link from pairing still usable; reconnect skipped');
        return {
          gatt: existing,
          deviceId: SonyBleProvisioning.lastDeviceId.length > 0
            ? SonyBleProvisioning.lastDeviceId : preferredDeviceId,
        };
      } catch (_error) {
        trace.push('Sony GATT link from pairing is gone; reconnecting');
      }
      await SonyBleProvisioning.close();
    }
    let deviceId = preferredDeviceId.length > 0 ? preferredDeviceId : SonyBleProvisioning.lastDeviceId;
    deviceId = await SonyBleProvisioning.findCamera(trace, deviceId);
    if (deviceId.length === 0) {
      trace.push('Sony BLE scan found no camera for the Wi-Fi leg');
      return null;
    }
    trace.push('Sony BLE deviceId=' + deviceId);
    try {
      return { gatt: await LumixImportPrototype.connectGatt(deviceId, trace), deviceId: deviceId };
    } catch (error) {
      trace.push('Sony GATT reconnect failed: ' + (error as Error).message);
    }
    const rediscovered = await SonyBleProvisioning.findCamera(trace, '');
    if (rediscovered.length === 0 || rediscovered === deviceId) {
      return null;
    }
    trace.push('Sony BLE rediscovered deviceId=' + rediscovered + '; retrying GATT');
    try {
      return { gatt: await LumixImportPrototype.connectGatt(rediscovered, trace), deviceId: rediscovered };
    } catch (error) {
      trace.push('Sony GATT reconnect failed after rediscovery: ' + (error as Error).message);
      return null;
    }
  }

  /** Read one credential characteristic and strip its 3-byte header. The value
   * is US-ASCII, exactly as BluetoothGattUtil.getWifiInfo decodes it. */
  private static async readCredential(gatt: ble.GattClientDevice,
    characteristic: ble.BLECharacteristic | undefined, trace: string[]): Promise<string> {
    if (!characteristic) {
      return '';
    }
    try {
      const raw = new Uint8Array(await LumixImportPrototype.readGatt(gatt, characteristic, trace));
      if (raw.length <= 3) {
        return '';
      }
      let text = '';
      for (let index = 3; index < raw.length; index++) {
        const code = raw[index];
        if (code === 0) {
          break;
        }
        if (code < 0x20 || code > 0x7E) {
          return '';
        }
        text += String.fromCharCode(code);
      }
      return text.trim();
    } catch (error) {
      trace.push('Sony credential read failed (ignored): ' + (error as Error).message);
      return '';
    }
  }

  /** EnumSupportInfo 的名称表，下标就是 CC0D 记录里的 id_lo（顺序取自官方
   * `EnumSupportInfo.smali` 的 `<clinit>`）。诊断只用来把位翻成可读名字。 */
  private static readonly SUPPORT_INFO_NAMES: string[] = [
    'MediaInfo', 'BatteryInfo', 'FriendlyName', 'DateFormat', 'TimeArea',
    'AutoPowerOffTemperature', 'HashSerial', 'BleDeviceLog', 'SshInfo',
    'CloudDeviceRegister', 'ApConnection', 'SmartPhoneConnectionMenu',
    'unassigned12', 'Identifier', 'ApListFetching', 'CameraLensInfo',
    'WifiFrequencyBand', 'GetSerial',
  ];

  /**
   * 诊断用：读相机的身份与能力位，回答「这台相机会不会走 SSH 隧道」。
   *
   * 背景：官方 `SingleCameraManager` 在 `X_SSH_Support=Enable` 时**不连**
   * 15740，而是 SSH 到 22 端口再本地转发（`SshSupportCamera.getIpAddress()`
   * 返回 "localhost"）。判定需要 DID 与 CC0D 的能力位一起看。
   *
   * 只读：不发任何写特征值。**从不记录 CC17 的内容**（里面是 SSH 账号口令），
   * 只记存在与长度。复用 pairing/Wi-Fi 阶段留下的 GATT 连接。
   */
  static async readCameraCapabilities(trace: string[]): Promise<string> {
    const gatt = SonyBleProvisioning.activeGatt;
    if (gatt === null) {
      SonyBleProvisioning.log('ble caps skipped: 没有可复用的 GATT 连接');
      return 'no-gatt';
    }
    try {
      const services = await gatt.getServices();
      const firmware = await SonyBleProvisioning.readShortText(gatt, services,
        SonyCameraService.FIRMWARE_VERSION_CHARACTERISTIC);
      const model = await SonyBleProvisioning.readShortText(gatt, services,
        SonyCameraService.MODEL_NAME_CHARACTERISTIC);
      const identifier = await SonyBleProvisioning.readShortText(gatt, services,
        SonyCameraService.IDENTIFIER_CHARACTERISTIC);
      const band = await SonyBleProvisioning.readShortText(gatt, services,
        SonyCameraService.WIFI_BAND_CHARACTERISTIC);
      SonyBleProvisioning.log(`ble identity fw=${firmware.length > 0 ? firmware : '-'} ` +
        `model=${model.length > 0 ? model : '-'} band=${band.length > 0 ? band : '-'} ` +
        `identifierLength=${identifier.length}`);

      const sshInfo = SonyBleProvisioning.findCharacteristic(services,
        SonyCameraService.SSH_INFO_CHARACTERISTIC);
      if (sshInfo === undefined) {
        SonyBleProvisioning.log('ble ssh-info characteristic=absent');
      } else {
        // 只记长度：内容是 SSH 账号口令，不能进反馈日志。
        try {
          const raw = new Uint8Array(await LumixImportPrototype.readGatt(gatt, sshInfo, []));
          SonyBleProvisioning.log(`ble ssh-info characteristic=present length=${raw.length} content=not-logged`);
        } catch (error) {
          SonyBleProvisioning.log('ble ssh-info read failed: ' + (error as Error).message);
        }
      }

      const capabilityCharacteristic = SonyBleProvisioning.findCharacteristic(services,
        SonyCameraService.CAPABILITY_CHARACTERISTIC);
      if (capabilityCharacteristic === undefined) {
        SonyBleProvisioning.log('ble caps characteristic=absent');
        return 'caps-absent';
      }
      const capabilityBytes = new Uint8Array(
        await LumixImportPrototype.readGatt(gatt, capabilityCharacteristic, trace));
      SonyBleProvisioning.log(`ble caps length=${capabilityBytes.length} ` +
        `hex=${SonyBleProvisioning.hexOf(capabilityBytes)}`);
      const decoded = SonyBleProvisioning.decodeCapabilities(capabilityBytes);
      SonyBleProvisioning.log('ble caps decoded ' + decoded.detail);
      return decoded.summary;
    } catch (error) {
      SonyBleProvisioning.log('ble caps failed: ' + (error as Error).message);
      return 'error';
    }
  }

  /** 读一个短文本特征值（ASCII），读到 0x00 或尾端为止。 */
  private static async readShortText(gatt: ble.GattClientDevice, services: Array<ble.GattService>,
    uuid: string): Promise<string> {
    const characteristic = SonyBleProvisioning.findCharacteristic(services, uuid);
    if (characteristic === undefined) return '';
    try {
      const raw = new Uint8Array(await LumixImportPrototype.readGatt(gatt, characteristic, []));
      let text = '';
      for (let index = 0; index < raw.length; index++) {
        const code = raw[index];
        if (code === 0) break;
        text += code >= 0x20 && code <= 0x7E ? String.fromCharCode(code) : '?';
      }
      return text.trim();
    } catch (_error) {
      return '';
    }
  }

  private static hexOf(raw: Uint8Array): string {
    let text = '';
    for (let index = 0; index < raw.length; index++) {
      const hex = raw[index].toString(16);
      text += hex.length < 2 ? '0' + hex : hex;
      if (index + 1 < raw.length) text += ' ';
    }
    return text;
  }

  /**
   * 解 CC0D 能力位。
   *
   * 官方按 `1 字节长度 + 3 字节记录 {id_hi, id_lo, on/off}` 解析；凭证类特征值
   * 另有 3 字节头，所以这里同时试 offset 1 / 3 / 0，并把三种解释都写进日志。
   * 原始 hex 也记录，事后可以离线复核，不依赖这里的猜测。
   */
  private static decodeCapabilities(raw: Uint8Array): SonyCapabilityDecode {
    const names = SonyBleProvisioning.SUPPORT_INFO_NAMES;
    const details: string[] = [];
    let summary = 'undecodable';
    const starts: number[] = [1, 3, 0];
    for (const start of starts) {
      const on: string[] = [];
      const off: string[] = [];
      for (let index = start; index + 2 < raw.length; index += 3) {
        const idHi = raw[index];
        const idLo = raw[index + 1];
        const value = raw[index + 2];
        if (idHi !== 0 || idLo >= names.length) continue;
        if (value === 0) {
          off.push(names[idLo]);
          continue;
        }
        on.push(names[idLo]);
      }
      if (on.length + off.length === 0) continue;
      details.push(`offset${start} on=[${on.join(',')}] off=[${off.join(',')}]`);
      // 以官方读取路径（1 字节长度头）为准生成短摘要。
      if (start === 1) summary = on.length > 0 ? on.join(',') : 'none-on';
    }
    return { summary: summary, detail: details.length > 0 ? details.join(' | ') : 'no-records' };
  }

  /** Close the GATT client left open by {@link pairOnly} / {@link startWifi}. */
  static async close(): Promise<void> {
    const gatt = SonyBleProvisioning.activeGatt;
    SonyBleProvisioning.activeGatt = null;
    if (!gatt) {
      return;
    }
    try { gatt.disconnect(); } catch (_error) { }
    try { gatt.close(); } catch (_error) { }
  }
}
