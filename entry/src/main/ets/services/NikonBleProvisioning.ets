/**
 * Nikon BLE pairing -> Wi-Fi credential provisioning.
 *
 * This is the Nikon counterpart of the LUMIX Lab line's BLE step: it pairs over
 * Bluetooth, authenticates with Nikon's LSS handshake, reads the Wi-Fi
 * credentials the camera hands back, and joins that network so the existing
 * PTP/IP transfer and camera-control code can take over.
 *
 * Relationship to the other Nikon modules
 * ---------------------------------------
 *   NikonCameraService    identity, routing and the confirmed GATT layout
 *   NikonLssProtocol      LSS wire shapes (auth frame, credential block)
 *   NikonLssCrypto        Blowfish
 *   NikonLssSession       the authentication state machine
 *   NikonBleProvisioning  this file: GATT transport + the flow that uses all of
 *                         the above
 *   NikonPtpIpService     Wi-Fi image transfer and camera control
 *
 * Transport is deliberately borrowed, not duplicated: `connectGatt`,
 * `enableNotification`, `readGatt`, `writeGatt` and `connectWifi` on
 * `LumixImportPrototype` contain no Panasonic-specific logic (the Panasonic
 * filter lives in that file's private `scanBle`), so the Nikon route reuses
 * them. Only discovery differs, because Nikon advertises a service UUID rather
 * than Panasonic's manufacturer data.
 *
 * Not guessed
 * -----------
 * `cameraDeviceId` is an explicit parameter. The official client passes an
 * 8-byte value into `lssAuthProc(byte[])` and echoes it as the stage-1 frame's
 * `deviceId` field, but the origin of that value is an open item, so it is
 * supplied by the caller instead of being invented here. `describeKey1` then
 * reports, in one log line, whether the value the camera returns at stage 4 is
 * the shared root the phone recovered — which is the other open item, and the
 * one a single hardware session settles.
 *
 * @since 2026-11
 */

import { ble, connection, socket } from '@kit.ConnectivityKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import bluetoothAccess from '@ohos.bluetooth.access';
import { NikonCameraService } from './NikonCameraService';
import { NikonLssSession } from './NikonLssSession';
import {
  decodeLssAuthFrame,
  encodeLssAuthFrame,
  isPlausibleCredentialText,
  LSS_STAGE_2,
  LSS_STAGE_4,
  NikonLssConnectionConfiguration,
  NikonLssEncryptMode,
  parseLssConnectionConfiguration
} from './NikonLssProtocol';
import { LumixImportPrototype, WifiConnection } from './LumixImportPrototype';

const DOMAIN: number = 0x0001;
const TAG: string = 'VIVID_NIKON_BLE';

/** Width of the `0x2002` CLIENT_DEVICE_NAME field.
 *
 * Fixed at 32 by the official client's serialiser, which allocates a 32-byte
 * little-endian ByteBuffer, puts the name, and returns the whole array — so the
 * name is zero-padded out to 32 bytes and never length-prefixed. */
const CLIENT_DEVICE_NAME_LENGTH: number = 32;

/** How long to wait for one camera notification on the authentication
 * characteristic. The camera answers within a few hundred milliseconds in the
 * normal case; the margin is for a body that is still waking up. */
const NOTIFICATION_TIMEOUT_MS: number = 15000;
/** Poll cadence while waiting for a notification. */
const NOTIFICATION_POLL_MS: number = 100;
/** How long to scan for a Nikon advertisement. */
const SCAN_WINDOW_MS: number = 10000;

/** A Nikon advertisement, decoded from the AD structures. */
interface NikonAdvertisement {
  /** Local name from AD types 0x08/0x09, empty when absent. */
  name: string;
  /** True when the SnapBridge service UUID is advertised. */
  hasSnapBridgeService: boolean;
  /** Human-readable manufacturer payload, for diagnostics only. */
  manufacturerHex: string;
}

/** Outcome of the whole BLE provisioning flow. */
export interface NikonProvisionResult {
  ok: boolean;
  /** Which step the flow reached, for diagnostics: scan/gatt/auth/credentials/wifi. */
  stage: string;
  message: string;
  ssid: string;
  password: string;
  /** Wire value from {@link NikonLssEncryptMode}; -1 when unknown. */
  security: number;
  /** Gateway of the joined camera network; empty when the join failed. */
  gateway: string;
  ipAddress: string;
}

/** One AD structure decoded out of an advertising payload. */
interface NikonAdField {
  type: number;
  value: Uint8Array;
}

export class NikonBleProvisioning {
  /** Most recent GATT client, kept so a caller can close it explicitly. */
  private static activeGatt: ble.GattClientDevice | null = null;

  /** How many scan results the most recent `findCamera` window actually saw.
   *
   * Exposed so the caller can report "no advertisement at all" and "thousands
   * of advertisements, none of them identifiable" as the different failures
   * they are. Zero-result and unmatched-result runs used to produce the same
   * message, which made them indistinguishable from the log. */
  static lastScanSeen: number = 0;

  /** Timer that mirrors trace entries to HiLog while `provision` is running. */
  private static tracePumpId: number = -1;
  /** Index of the first trace entry not yet mirrored to HiLog. */
  private static tracePumpAt: number = 0;

  /**
   * **持久化的客户端身份 —— 这正是 Nikon LSS 认证里我们一直搞错的那个字段。**
   *
   * 官方实现（`M0.smali` / `D6.smali` / `E6.smali` / `n0.smali` 反编译）：
   *
   *   - `SharedPreferences` 里存一个 `"DeviceID"` 字符串
   *   - 首次运行：`new Random(System.currentTimeMillis()).nextBytes(new byte[8])`
   *   - 存储：`Base64.encodeToString(bytes, 0)`
   *   - 读取：`Base64.decode(prefs.getString("DeviceID", ""), 0)`
   *   - 保存时**断言长度必须正好是 8**
   *   - 每次 `BleConnection.connect(Context, BluetoothDevice, byte[] deviceId, …)`
   *     都把**同一个值**传进去；再由 `lssAuthProc` 放进 stage-1 帧的 `deviceId` 字段
   *
   * 也就是说：**这是手机自己的身份，一次生成、永久不变，和相机的蓝牙地址毫无关系。**
   *
   * 我们此前每个会话都从相机地址推导它（先是 BLE 广播地址，后来改成经典地址），
   * 所以相机每次看到的都是一个陌生客户端——它存着注册时的那份身份，匹配不上就拒绝
   * 认证。实测两次对照：
   *
   *   成功那次：identifier = 926e3a43a0940000  ← 经典地址
   *   失败这次：identifier = aee5575898230000  ← BLE 地址（轮换过）
   *
   * **两个都是错的**；正确值根本不由相机决定。用户当时的描述"我方蓝牙对方不认可"
   * 就是字面意思。
   */
  private static clientDeviceId: Uint8Array | null = null;

  /** preferences 存储名，与官方一样只放一个 `DeviceID` 键。 */
  private static readonly CLIENT_ID_STORE = 'nikon_lss_identity';

  /**
   * 读回持久化的客户端身份；没有（或长度不是 8）就生成一个并存下来。
   *
   * 一旦生成就不再改变——这是与相机之间"这台手机是谁"的唯一凭据。
   */
  // ---------------------------------------------------------------------------
  // 相机经典地址的持久缓存
  //
  // 为什么必须有它：10-16 23:24 那次 Z 8 配对成功的日志显示，相机是在**经典蓝牙
  // 搜索里被按名字找到**的（`FA:62:E4:27:F2:66 name=Z_8_8046830`），随后对它调
  // `pairDevice`，7 秒后系统弹出配对码、绑定成功。而同一份日志后面几轮全都撞在
  // `In DISCOVERYING or DISCOVERY_STARTED state` 上——**那时它没有重新搜，而是
  // 沿用了已经找到过的那个地址**，所以照样成功。
  //
  // 这就说明：经典地址**搜到一次就该记住**。相机的经典侧并不总是可发现（它只在
  // 配对窗口里开放一小段时间），而框架的发现状态一旦卡在 DISCOVERYING 就再也发
  // 不出新的搜索。没有缓存时，一次没搜到就彻底没戏——今天（10-18 12:44）三轮都
  // 没在 17 个设备里看到相机，于是连一次 `pairDevice` 都没发出去。
  // ---------------------------------------------------------------------------
  private static readonly CLASSIC_STORE = 'nikon_classic_addresses';
  /** 相机名 → 经典蓝牙地址。进程内缓存，启动时从 preferences 灌入。 */
  private static classicAddresses: Map<string, string> = new Map<string, string>();
  private static classicCacheLoaded: boolean = false;
  /** 配对流程开始时的 ability context，供写缓存使用（`bondWithPasskey` 没有它）。 */
  private static appContext: common.UIAbilityContext | null = null;

  /** 从持久存储读回经典地址表。幂等，`provision` 开头调一次即可。 */
  private static async loadClassicAddresses(context: common.UIAbilityContext,
    trace: string[]): Promise<void> {
    if (NikonBleProvisioning.classicCacheLoaded) {
      return;
    }
    NikonBleProvisioning.classicCacheLoaded = true;
    NikonBleProvisioning.appContext = context;
    try {
      const store = await preferences.getPreferences(context,
        NikonBleProvisioning.CLASSIC_STORE);
      const raw = await store.get('addresses', '') as string;
      if (raw.length === 0) {
        // **这里绝对不能 return。**
        //
        // 原来写的是 `trace.push('… cache: empty'); return;`，而下面"种入实测地址"
        // 的代码在 try/catch 之外、紧跟其后——于是首次运行（存储本来就是空的）
        // 一定在这里提前返回，种子永远执行不到，日志里连着 5 次
        // `Nikon classic address cache: empty`，一次 `seeded` 都没有。
        // 现在只是记录下来，继续往下走。
        trace.push('Nikon classic address cache: empty (first run)');
      } else {
        for (const entry of raw.split(';')) {
          const at = entry.indexOf('=');
          if (at > 0 && at < entry.length - 1) {
            NikonBleProvisioning.classicAddresses.set(entry.substring(0, at),
              entry.substring(at + 1));
          }
        }
        trace.push('Nikon classic address cache: ' +
          NikonBleProvisioning.describeClassicCache());
      }
    } catch (error) {
      trace.push('Nikon classic address cache read failed: ' +
        NikonBleProvisioning.describeError(error));
    }
    // **种子地址已删除。**
    //
    // 这里原本种入 10-16 日志里看到过的 `Z_8_8046830 = FA:62:E4:27:F2:66`，想让
    // 搜不到时也有条退路。10-18 13:33 的日志证明它**有害**：
    //   classic discovery found 21 device(s)          ← 搜到了，但相机不在里面
    //   bonding target=FA:62:E4:27:F2:66              ← 用了缓存的旧地址
    //   pairDevice rejected: Address has not been
    //     discovered or recorded.（2900099）
    // 框架**只接受本次搜索里真正出现过的地址**，10-16 那个随机地址早就失效了。
    // 留着它只会把"这轮没搜到"变成"拿一个必然被拒的地址再等 60 秒"。
    //
    // 所以缓存只保留**搜索真的搜到过的**地址（由 rememberClassicAddress 写入），
    // 而且只作为搜索失败后的记录，不再人工种入任何值。
  }

  private static describeClassicCache(): string {
    const parts: string[] = [];
    NikonBleProvisioning.classicAddresses.forEach((address: string, name: string) => {
      parts.push(name + '=' + address);
    });
    return parts.length > 0 ? parts.join(', ') : '(none)';
  }

  /** 记住"这台相机（按它自报的名字）的经典地址是这个"。
   *
   *  context 用 `loadClassicAddresses` 存下的那个——`bondWithPasskey` 这条路径
   *  上没有 ability context，而把 context 一路透传下去要改好几个签名。 */
  private static async rememberClassicAddress(name: string, address: string,
    trace: string[]): Promise<void> {
    if (name.length === 0 || address.length === 0) {
      return;
    }
    if (NikonBleProvisioning.classicAddresses.get(name) === address) {
      return;
    }
    NikonBleProvisioning.classicAddresses.set(name, address);
    trace.push('Nikon classic address remembered: ' + name + '=' + address);
    const context = NikonBleProvisioning.appContext;
    if (context === null) {
      trace.push('Nikon classic address cache not persisted (no context on this path)');
      return;
    }
    try {
      const parts: string[] = [];
      NikonBleProvisioning.classicAddresses.forEach((value: string, key: string) => {
        parts.push(key + '=' + value);
      });
      const store = await preferences.getPreferences(context,
        NikonBleProvisioning.CLASSIC_STORE);
      await store.put('addresses', parts.join(';'));
      await store.flush();
    } catch (error) {
      trace.push('Nikon classic address cache write failed: ' +
        NikonBleProvisioning.describeError(error));
    }
  }

  /** 取"这台相机的经典地址"，没有就返回空串。 */
  private static recallClassicAddress(name: string): string {
    if (name.length === 0) {
      return '';
    }
    const stored = NikonBleProvisioning.classicAddresses.get(name);
    return stored !== undefined ? stored : '';
  }

  private static async loadClientDeviceId(context: common.UIAbilityContext,
    trace: string[]): Promise<Uint8Array> {
    if (NikonBleProvisioning.clientDeviceId !== null) {
      return NikonBleProvisioning.clientDeviceId;
    }
    let bytes: Uint8Array | null = null;
    try {
      const store = await preferences.getPreferences(context,
        NikonBleProvisioning.CLIENT_ID_STORE);
      const stored = await store.get('DeviceID', '') as string;
      if (stored.length > 0) {
        // 官方用的是 Base64.decode(str, 0)：标准 Base64（非 URL-safe、非 no-wrap）。
        const decoded = new util.Base64Helper().decodeSync(stored);
        if (decoded.length === 8) {
          bytes = Uint8Array.from(decoded);
          trace.push('Nikon client DeviceID restored from storage: ' +
            NikonBleProvisioning.hex8(bytes) +
            ' (the official persists this one value for the lifetime of the install)');
        } else {
          trace.push('Nikon stored DeviceID is ' + decoded.length +
            ' bytes, not 8; regenerating (the official asserts exactly 8)');
        }
      }
    } catch (error) {
      trace.push('Nikon client DeviceID read failed: ' +
        NikonBleProvisioning.describeError(error));
    }
    if (bytes === null) {
      bytes = NikonBleProvisioning.generateClientDeviceId();
      try {
        const store = await preferences.getPreferences(context,
          NikonBleProvisioning.CLIENT_ID_STORE);
        await store.put('DeviceID', new util.Base64Helper().encodeToStringSync(bytes));
        await store.flush();
        trace.push('Nikon client DeviceID generated and persisted: ' +
          NikonBleProvisioning.hex8(bytes) +
          ' (8 random bytes, Base64 — replaced the per-session address derivation)');
      } catch (error) {
        // 存不下也要继续：本次仍用这个值，只是下次会重生成（那会再被相机拒绝一次）。
        trace.push('Nikon client DeviceID persist FAILED (it will change next session, ' +
          'and the camera will then reject the authentication): ' +
          NikonBleProvisioning.describeError(error));
      }
    }
    NikonBleProvisioning.clientDeviceId = bytes;
    return bytes;
  }

  /** 8 个随机字节，对应官方的 `new Random(time).nextBytes(new byte[8])`。 */
  private static generateClientDeviceId(): Uint8Array {
    const bytes = new Uint8Array(8);
    for (let index = 0; index < 8; index++) {
      bytes[index] = Math.floor(Math.random() * 256) & 0xff;
    }
    return bytes;
  }

  private static log(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
    AppLogSink.emit('CTL', message);
  }

  private static async delay(milliseconds: number): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => { resolve(); }, milliseconds);
    });
  }

  /**
   * Splits an advertising payload into its AD structures.
   *
   * Each structure is a length byte, a type byte, then `length - 1` bytes of
   * value; a zero length terminates the list. Malformed trailing bytes are
   * ignored rather than thrown, because the platform may hand back a truncated
   * scan response.
   */
  private static parseAdStructures(data: ArrayBuffer): NikonAdField[] {
    const fields: NikonAdField[] = [];
    if (!data || data.byteLength === 0) {
      return fields;
    }
    const bytes = new Uint8Array(data);
    let offset = 0;
    while (offset < bytes.length) {
      const length = bytes[offset];
      if (length === 0) {
        break;
      }
      if (offset + 1 + length > bytes.length || length < 1) {
        break;
      }
      const type = bytes[offset + 1];
      const value = bytes.slice(offset + 2, offset + 1 + length);
      fields.push({ type: type, value: value });
      offset += 1 + length;
    }
    return fields;
  }

  /** Formats 16 AD bytes as a UUID string. AD stores UUIDs little-endian, so
   * the byte list is reversed before grouping. */
  private static uuidFromLittleEndian(value: Uint8Array): string {
    if (value.length < 16) {
      return '';
    }
    let hex = '';
    for (let i = 15; i >= 0; i--) {
      hex += value[i].toString(16).padStart(2, '0');
    }
    return hex.substr(0, 8) + '-' + hex.substr(8, 4) + '-' + hex.substr(12, 4) + '-' +
      hex.substr(16, 4) + '-' + hex.substr(20, 12);
  }

  private static readAdName(fields: NikonAdField[]): string {
    for (const field of fields) {
      if (field.type === 0x08 || field.type === 0x09) {
        let text = '';
        for (let i = 0; i < field.value.length; i++) {
          const code = field.value[i];
          if (code >= 32 && code < 127) {
            text += String.fromCharCode(code);
          }
        }
        if (text.length > 0) {
          return text;
        }
      }
    }
    return '';
  }

  private static decodeAdvertisement(data: ArrayBuffer): NikonAdvertisement {
    const fields = NikonBleProvisioning.parseAdStructures(data);
    let hasSnapBridge = false;
    let manufacturerHex = '';
    const wanted = NikonCameraService.SNAPBRIDGE_SERVICE.toLowerCase();
    for (const field of fields) {
      if (field.type === 0x06 || field.type === 0x07) {
        for (let offset = 0; offset + 16 <= field.value.length; offset += 16) {
          const uuid = NikonBleProvisioning.uuidFromLittleEndian(field.value.slice(offset, offset + 16));
          if (uuid.toLowerCase() === wanted) {
            hasSnapBridge = true;
          }
        }
      }
      if (field.type === 0xff) {
        let hex = '';
        for (let i = 0; i < field.value.length; i++) {
          hex += field.value[i].toString(16).padStart(2, '0');
        }
        manufacturerHex = hex;
      }
    }
    return {
      name: NikonBleProvisioning.readAdName(fields),
      hasSnapBridgeService: hasSnapBridge,
      manufacturerHex: manufacturerHex,
    };
  }

  /**
   * Finds a nearby Nikon body.
   *
   * Admission is deliberately narrow: the SnapBridge service UUID must be
   * advertised, or the advertised name must resolve to a known Nikon model
   * through the same table the rest of the app uses. Matching on a bare
   * "NIKON" prefix would admit the wrong body when several are in range.
   */
  static async findCamera(trace: string[], preferredDeviceId: string = ''): Promise<string> {
    if (preferredDeviceId.length > 0) {
      trace.push('Nikon BLE reusing established address; discovery skipped');
      return preferredDeviceId;
    }
    let found = '';
    let fallback = '';
    let seen = 0;
    const samples: string[] = [];
    const callback = (results: Array<ble.ScanResult>): void => {
      for (const result of results) {
        if (!result.deviceId) {
          continue;
        }
        seen += 1;
        // Diagnose the identification path, not only the outcome. Every run so
        // far has ended in an opaque "no Nikon advertisement", which is
        // indistinguishable from "thousands of results arrived but none could
        // be identified" — and that distinction is the entire question here:
        // the platform logs `ConvertDataMapToJS memcpy_s error` while converting
        // advertisement data, so an empty `data` payload is a live possibility
        // and would reject the camera without leaving any trace.
        const advertised = NikonBleProvisioning.decodeAdvertisement(result.data);
        const deviceName = result.deviceName ? result.deviceName : '';
        const name = advertised.name.length > 0 ? advertised.name : deviceName;
        const identity = NikonCameraService.identifyBluetoothName(name);
        const isNikon = advertised.hasSnapBridgeService || identity !== null
          || NikonBleProvisioning.looksLikeNikonBleName(name);
        if (!isNikon) {
          if (samples.length < 12) {
            samples.push('name=' + (name.length > 0 ? name : '(none)') +
              ' deviceName=' + (deviceName.length > 0 ? deviceName : '(none)') +
              ' data=' + (result.data ? result.data.byteLength : 0) + 'B' +
              ' service=' + (advertised.hasSnapBridgeService ? 'snapbridge' : 'no') +
              ' rssi=' + result.rssi);
          }
          continue;
        }
        trace.push('Nikon BLE advertisement name=' + (name.length > 0 ? name : '(none)') +
          ' service=' + (advertised.hasSnapBridgeService ? 'snapbridge' : 'unresolved') +
          ' rssi=' + result.rssi +
          ' manufacturer=' + (advertised.manufacturerHex.length > 0 ? advertised.manufacturerHex : 'none'));
        // 原始广播报文原样打出来。相机是双模设备，它的**经典（BR/EDR）地址**多半
        // 就在广播里——要么在制造商标数据里，要么是 AD type 0x0A/0x0B 的
        // "Bluetooth Device Address"（双模设备用这种方式让主机同时知道两个地址）。
        // 官方 App 绑定的是经典地址（removeBond 操作的是 A0:CD:xx:xx:xx），而我们
        // 一直绑 BLE 地址，所以手机侧进 BONDING 但相机不认。之前这里只提取了名称
        // 和服务 UUID，原始字节从没被看到过。
        const rawAdvertisement = result.data ? new Uint8Array(result.data) : new Uint8Array(0);
        trace.push('Nikon BLE advertisement raw deviceId=' + result.deviceId +
          ' len=' + rawAdvertisement.length +
          ' hex=' + NikonBleProvisioning.hex8(rawAdvertisement));
        if (result.connectable === false) {
          if (fallback.length === 0) {
            fallback = result.deviceId;
          }
          continue;
        }
        if (found.length === 0) {
          found = result.deviceId;
        }
      }
    };
    const startedAt = Date.now();
    let startedScan = false;
    try {
      ble.on('BLEDeviceFind', callback);
      ble.startBLEScan(null, {
        interval: 0,
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
      });
      startedScan = true;
      trace.push('Nikon BLE scan filter=none; admitted on SnapBridge service or a known model name');
    } catch (error) {
      // A refused start is NOT fatal, and used to abort the whole pairing flow:
      // the camera page keeps its own discovery scan running, and asking for a
      // second scan while one is active fails with 2900099 "Operation failed".
      // Our BLEDeviceFind callback still receives the results of the scan that
      // is already running, so the body can be found without owning the scan.
      // This is the same reasoning (and the same shape) as SonyBleProvisioning.
      trace.push('Nikon BLE scan start refused; continuing on the scan already running: '
        + NikonBleProvisioning.describeError(error));
    }
    try {
      while (found.length === 0 && Date.now() - startedAt < SCAN_WINDOW_MS) {
        await NikonBleProvisioning.delay(200);
      }
      NikonBleProvisioning.lastScanSeen = seen;
      trace.push('Nikon BLE scan saw ' + seen + ' results');
      for (const sample of samples) {
        trace.push('Nikon BLE candidate ' + sample);
      }
    } finally {
      // Only tear down a scan this call actually started. The camera page runs
      // its own discovery scan; stopping that one would blank the
      // nearby-camera list.
      if (startedScan) {
        try {
          ble.stopBLEScan();
        } catch (_error) {
        }
      }
      try {
        ble.off('BLEDeviceFind', callback);
      } catch (_error) {
      }
    }
    return found.length > 0 ? found : fallback;
  }

  /** Renders an error together with its HarmonyOS error code.
   *
   * The bare `message` of a Bluetooth failure is very often just
   * "Operation failed", which identifies nothing at all; the `code` is the only
   * actionable field (2900099 operation failed, 2900003 adapter off,
   * 201 permission denied, 2900001 service stopped). Reporting the message
   * alone made the first field report of this failure undiagnosable. */
  private static describeError(error: Object): string {
    const typed = error as BusinessError;
    const message = typed.message !== undefined && typed.message.length > 0
      ? typed.message : String(error);
    const code = typed.code;
    return code !== undefined ? `${message}（code ${code}）` : message;
  }

  /** Renders a characteristic's advertised permissions.
   *
   * A rejected write has two very different explanations — the camera refused
   * it, or we asked for an operation the characteristic does not permit — and
   * only the advertised flags separate them. */
  /** Whether a BLE local name follows Nikon's camera convention.
   *
   * Bodies advertise names such as `Z_5_`, `Z_6_2_`, `Z_f_` and `D850_` — the
   * model with spaces replaced by underscores, often with a trailing one. This
   * is a weaker signal than the SnapBridge service UUID, so it only adds an
   * admission path: the model table stays authoritative when it matches. The
   * pattern is deliberately anchored so that unrelated names merely starting
   * with Z (ZTE, Zepp) are not admitted. */
  private static looksLikeNikonBleName(name: string): boolean {
    if (name.length === 0) {
      return false;
    }
    const normalized = name.trim().toUpperCase();
    if (normalized.startsWith('NIKON')) {
      return true;
    }
    return /^Z[_ ][0-9A-Z]/.test(normalized) || /^Z[0-9]/.test(normalized)
      || /^D[0-9]{3}/.test(normalized);
  }

  private static describeProperties(properties: ble.GattProperties | undefined): string {
    if (!properties) {
      return '(none reported)';
    }
    const names: string[] = [];
    if (properties.read) names.push('read');
    if (properties.write) names.push('write');
    if (properties.writeNoResponse) names.push('writeNoResponse');
    if (properties.notify) names.push('notify');
    if (properties.indicate) names.push('indicate');
    if (properties.broadcast) names.push('broadcast');
    if (properties.authenticatedSignedWrite) names.push('signedWrite');
    return names.length > 0 ? names.join('+') : '(none)';
  }

  /** Write of the client device name (pairing Stage-1, `0x2002`).
   *
   * The payload is a FIXED 32-byte field, not a bare name. The official
   * client's serialiser for this characteristic is, at the bytecode level:
   *
   *   ByteBuffer.allocate(32).order(LITTLE_ENDIAN).put(name.getBytes()).array()
   *
   * — the name's bytes followed by zero padding out to 32 bytes, with no length
   * prefix. The first field run wrote five raw bytes (`VIVID`) and the camera
   * refused with service status 128; writing a malformed width to a
   * fixed-width field is the most likely reason, and this now matches the
   * shipped client exactly.
   *
   * Returns true on success and never throws: a failure is recorded and the
   * route continues, so the camera can report the real reason on the next step. */
  private static async writeClientDeviceName(gatt: ble.GattClientDevice,
    characteristic: ble.BLECharacteristic | undefined, trace: string[]): Promise<boolean> {
    if (!characteristic) {
      trace.push('Nikon client device name characteristic not present');
      return false;
    }
    try {
      // 报给相机的名字**必须等于手机在经典蓝牙里广播的名字**：相机是搜索手机、
      // 凭这个名字认出来的，不一致它就永远不连过来（实测手机广播的是「单哥啊」，
      // 而我们报 `HOS Pixelshop`，两边对不上，RFCOMM 监听一直空等）。
      //
      // 本机**不支持改名**（`setLocalName` 抛 801 Capability is not supported），
      // 所以这里只能取系统当前名称，让两边天然一致。想让相机上显示
      // "HOS Pixelshop"，请在系统设置 → 蓝牙 → 本机名称 里把手机改成它，本函数
      // 会自动跟随。
      const name = NikonBleProvisioning.phoneBluetoothName();
      const payload = NikonBleProvisioning.encodeClientName(name);
      await LumixImportPrototype.writeGatt(gatt, characteristic, payload, trace);
      trace.push('Nikon client device name sent as "' + name + '" in ' + payload.byteLength +
        // 步骤 3/9：客户端名写进去了——这一步就是"向相机注册本机身份"。
        ' zero-padded bytes (pairing Stage-1)');
      // 步骤 4/9：客户端名写进去了——这正是"向相机注册本机身份"那一步。
      NikonBleProvisioning.step(trace, 4, 9, '正在向相机注册客户端名称…');
      return true;
    } catch (error) {
      trace.push('Nikon client device name write failed: ' +
        NikonBleProvisioning.describeError(error));
      return false;
    }
  }

  /** 配对时发给相机的"本机名称"（`0x2002` CLIENT_DEVICE_NAME）。
   *
   * 官方客户端发的是**手机自己的蓝牙名称**（用户在系统设置里看到的名字），不是
   * 一个固定的产品名。相机把客户端名称当作这条配对记录的名字显示在机身上，所以
   * 用固定名会在相机里堆出多条同名记录——而我们已经用 'VIVID' 试过十几轮了。
   *
   * 取不到时才回退到固定名，并把原因记进日志。 */
  private static phoneBluetoothName(): string {
    try {
      const name: string = connection.getLocalName();
      if (name.length > 0) {
        return name;
      }
      NikonBleProvisioning.log('Nikon local bluetooth name is empty; falling back to VIVID');
    } catch (error) {
      NikonBleProvisioning.log('Nikon local bluetooth name unavailable ('
        + NikonBleProvisioning.describeError(error) + '); falling back to VIVID');
    }
    return 'VIVID';
  }

  /** UTF-8 编码名称，按 32 字节截断、其余补零。
   *
   * 布局照官方序列化器 `snapbridge/bleclient/g.a(BleClientDeviceNameData;)[B`：
   * `ByteBuffer.allocate(32)` → `order(LITTLE_ENDIAN)` → `put(String.getBytes())`。
   * `put` 只写数组那么长，剩下的保持 0，所以就是"名称字节 + 零填充"。
   * 官方用的是 `String.getBytes()`（平台默认 UTF-8），所以中文名要按 UTF-8 编码，
   * 直接取 charCode 会把非 ASCII 名称写成乱码。 */
  private static encodeClientName(name: string): Uint8Array {
    const payload = new Uint8Array(CLIENT_DEVICE_NAME_LENGTH);
    let out = 0;
    for (let index = 0; index < name.length && out < CLIENT_DEVICE_NAME_LENGTH; index++) {
      const code = name.charCodeAt(index);
      if (code < 0x80) {
        payload[out++] = code;
      } else if (code < 0x800) {
        if (out + 2 > CLIENT_DEVICE_NAME_LENGTH) {
          break;
        }
        payload[out++] = 0xc0 | (code >> 6);
        payload[out++] = 0x80 | (code & 0x3f);
      } else {
        if (out + 3 > CLIENT_DEVICE_NAME_LENGTH) {
          break;
        }
        payload[out++] = 0xe0 | (code >> 12);
        payload[out++] = 0x80 | ((code >> 6) & 0x3f);
        payload[out++] = 0x80 | (code & 0x3f);
      }
    }
    return payload;
  }

  /** The address to use for the LSS link once bonded.
   *
   * Bonding resolves the advertised privacy address to the camera's identity
   * address, so the address the scan returned may no longer be the connectable
   * one — which is also why the camera can stop appearing in the nearby list
   * after a successful pairing. The exact address is preferred; otherwise a
   * single Nikon-named bond is accepted, and anything ambiguous is refused
   * rather than guessed. */
  private static bondedAddressFor(deviceId: string, trace: string[]): string {
    try {
      const paired = connection.getPairedDevices();
      trace.push('Nikon bonded device count=' + paired.length);
      for (const address of paired) {
        if (address.toUpperCase() === deviceId.toUpperCase()) {
          return address;
        }
      }
      let candidate = '';
      let matches = 0;
      for (const address of paired) {
        let name = '';
        try {
          name = connection.getRemoteDeviceName(address);
        } catch (_error) {
          name = '';
        }
        trace.push('Nikon bonded device ' + NikonBleProvisioning.tailOf(address) +
          ' name=' + (name.length > 0 ? name : '(unknown)'));
        // **通用判据优先：拿相机在 LSS 里自报的名字（`0x2003`）精确匹配。**
        //
        // 这是唯一不依赖品牌和命名习惯的判据——相机在系统蓝牙列表里显示的名字就是
        // 它自己报的那个字符串，换任何机型的相机都成立。命中就直接返回，不做任何
        // 计数和猜测。
        const reported = NikonBleProvisioning.cameraReportedName;
        if (reported.length > 0 && name === reported) {
          trace.push('Nikon bonded device ' + NikonBleProvisioning.tailOf(address) +
            ' matches the name the camera reported over LSS ("' + reported + '")');
          return address;
        }
        // **同样接受"型号前缀一致"。**
        //
        // 用户实测：相机已经出现在手机系统蓝牙列表里（名字 `Z_8_8046830`），
        // 但应用这边一直没认出来，最后是手动配对完成的。做到"逐字相等才认"太脆，
        // 所以这里与经典搜索的判据保持一致：型号前缀相同就认。
        const prefix = NikonBleProvisioning.namePrefix(reported);
        if (reported.length > 0 && prefix.length > 1 && name.startsWith(prefix)) {
          trace.push('Nikon bonded device ' + NikonBleProvisioning.tailOf(address)
            + ' has the camera model prefix "' + prefix + '"; using it'
            + ' (camera-reported name was "' + reported + '")');
          return address;
        }
        // 退一步的启发式：Nikon 机身名字以 Z 开头（Z 5、Z 6II、Z f …）。只在拿不到
        // 自报名字时才用，且仍要求唯一命中。别家相机的名字形态不同，但走上一条
        // 通用判据就够，不需要在这里枚举品牌。
        if (name.length > 0 && (name.charAt(0) === 'Z' || name.charAt(0) === 'z')) {
          matches += 1;
          candidate = address;
        }
      }
      if (matches === 1) {
        trace.push('Nikon using the single Nikon-named bond ' +
          NikonBleProvisioning.tailOf(candidate));
        return candidate;
      }
      if (matches > 1) {
        trace.push('Nikon ' + matches + ' Nikon-named bonds present; refusing to guess');
        return '';
      }
      trace.push('Nikon no Nikon-named bond found; keeping the scanned address');
      return '';
    } catch (error) {
      trace.push('Nikon bonded device lookup failed: ' +
        NikonBleProvisioning.describeError(error));
      return '';
    }
  }

  /** Last five characters of an address, for the diagnostic trace. */
  private static tailOf(address: string): string {
    return '…' + address.substring(Math.max(0, address.length - 5));
  }

  /** Asks the body to bring its Wi-Fi access point up (`0x2005`).
   *
   * This is the step that was missing, and it explains the whole shape of the
   * failure: the camera hands the SSID and password over BLE through `0x2004`
   * but only raises the network on this command, so a phone that reads the
   * credentials and immediately scans for the SSID waits for an access point
   * that has not been asked to exist yet.
   *
   * The payload is one byte. The shipped client's serialiser allocates
   * `ByteBuffer.allocate(1)`, orders it LITTLE_ENDIAN and writes
   * `0x04 | (wifi ? 0x01 : 0) | (notRequired ? 0x10 : 0)`, so a Wi-Fi
   * establishment request is `0x05` (BT is `0x04`). Verified by decoding the
   * serialiser's bytecode, not inferred from the data-class field names.
   *
   * Best-effort: a refusal is recorded and the join still runs, because the
   * credential read already succeeded and some bodies raise the AP on their own
   * once an authenticated session exists. */
  private static async requestConnectionEstablishment(gatt: ble.GattClientDevice,
    services: ble.GattService[], byte: number, trace: string[]): Promise<void> {
    const characteristic = NikonBleProvisioning.findCharacteristic(services,
      NikonCameraService.CONNECTION_ESTABLISHMENT_CHARACTERISTIC);
    if (!characteristic) {
      trace.push('Nikon connection establishment characteristic 0x2005 not present');
      return;
    }
    try {
      await LumixImportPrototype.writeGatt(gatt, characteristic, new Uint8Array([byte]), trace);
      trace.push('Nikon ' + (byte === 0x05 ? 'Wi-Fi access point' : 'connection') +
        ' requested on 0x2005 (byte 0x' + byte.toString(16) + ')');
    } catch (error) {
      trace.push('Nikon connection establishment request on 0x2005 failed: ' +
        NikonBleProvisioning.describeError(error));
    }
  }

  /** Reads the body's device name (`0x2003`), the SERVER_DEVICE_NAME step.
   *
   * The official orchestration does this on the CONNECTED transition, before
   * CURRENT_TIME. Best-effort: the name is not needed by anything downstream. */
  private static async readServerDeviceName(gatt: ble.GattClientDevice,
    services: ble.GattService[], trace: string[]): Promise<void> {
    const characteristic = NikonBleProvisioning.findCharacteristic(services,
      NikonCameraService.SERVER_DEVICE_NAME_CHARACTERISTIC);
    if (!characteristic) {
      trace.push('Nikon server device name characteristic 0x2003 not present');
      return;
    }
    try {
      const raw = new Uint8Array(await LumixImportPrototype.readGatt(gatt, characteristic, trace));
      // 把相机自报的名字存下来。这是**通用**判据，不是按机型写死：相机在系统蓝牙
      // 列表里显示的名字就是它，所以后面要"从已绑定记录里认出这台相机"时，直接拿
      // 这个名字去精确匹配即可——换任何一台相机、任何品牌都成立。
      NikonBleProvisioning.cameraReportedName = NikonBleProvisioning.decodeAscii(raw);
      trace.push('Nikon server device name read (' + raw.length + ' bytes) value="' +
        NikonBleProvisioning.cameraReportedName + '"');
      // 步骤 5/9：相机自报的名字、序列号、固件、feature 都是在这一段读的。
      NikonBleProvisioning.step(trace, 5, 9, '正在读取相机信息…');
    } catch (error) {
      trace.push('Nikon server device name read on 0x2003 failed: ' +
        NikonBleProvisioning.describeError(error));
    }
  }

  /** 把 NUL 结尾/补齐的 ASCII 字段解成字符串。
   *
   * 相机自报的名字（`0x2003`）和序列号（`0x200B`）都是这个格式：定长、尾部补 0。
   * 遇到 0 或非可打印字符即停，避免把填充字节带进结果。 */
  private static decodeAscii(bytes: Uint8Array): string {
    let text = '';
    for (let index = 0; index < bytes.length; index++) {
      const value = bytes[index];
      if (value === 0 || value < 32 || value > 126) {
        break;
      }
      text += String.fromCharCode(value);
    }
    return text;
  }

  /** Writes the phone's local time to the body (`0x2006`), the CURRENT_TIME step.
   *
   * The body's screen stays on "waiting to pair" without this, and
   * CONNECT_REQUEST alone did not move it. The payload is 10 bytes,
   * little-endian, exactly as the shipped client's serialiser emits:
   * `putShort(year) put(month) put(day) put(hours) put(minutes) put(seconds)
   *  put(dstOffset) put(tzOffsetHours) put(tzOffsetMinutes)` — including the
   * getter-to-slot mapping, read out of the serialiser's bytecode.
   *
   * `year` is a short, so it carries the full year rather than an offset. */
  private static async writeCurrentTime(gatt: ble.GattClientDevice,
    services: ble.GattService[], trace: string[]): Promise<void> {
    const characteristic = NikonBleProvisioning.findCharacteristic(services,
      NikonCameraService.CURRENT_TIME_CHARACTERISTIC);
    if (!characteristic) {
      trace.push('Nikon current time characteristic 0x2006 not present');
      return;
    }
    const now = new Date();
    const year = now.getFullYear();
    const payload = new Uint8Array(10);
    payload[0] = year & 0xFF;
    payload[1] = (year >> 8) & 0xFF;
    payload[2] = now.getMonth() + 1;
    payload[3] = now.getDate();
    payload[4] = now.getHours();
    payload[5] = now.getMinutes();
    payload[6] = now.getSeconds();
    payload[7] = 0;                              // no daylight saving in use
    const tzMinutes = -now.getTimezoneOffset();  // east of UTC is positive
    payload[8] = Math.floor(tzMinutes / 60);
    payload[9] = ((tzMinutes % 60) + 60) % 60;
    const dump: string[] = [];
    for (const byte of payload) {
      dump.push(byte < 16 ? '0' + byte.toString(16) : byte.toString(16));
    }
    trace.push('Nikon current time payload=' + dump.join(' ') +
      ' year=' + year + ' tzOffset=' + tzMinutes + 'min');
    try {
      await LumixImportPrototype.writeGatt(gatt, characteristic, payload, trace);
      trace.push('Nikon current time written on 0x2006');
    } catch (error) {
      trace.push('Nikon current time write on 0x2006 failed: ' +
        NikonBleProvisioning.describeError(error));
    }
  }

  /** Arms the authentication characteristic, choosing the CCCD the camera
   *  actually advertises.
   *
   * The live Z 5 reports `0x2000` as `read+write+indicate` — the static table
   * says notify — and enabling *notification* on an indicate-only
   * characteristic is refused by the camera. `setCharacteristicChangeIndication`
   * writes the other CCCD bit, and OHOS delivers both through the same
   * BLECharacteristicChange event. */
  private static async armAuthCharacteristic(gatt: ble.GattClientDevice,
    characteristic: ble.BLECharacteristic, trace: string[]): Promise<void> {
    const properties = characteristic.properties;
    const canNotify = properties !== undefined && properties.notify === true;
    const canIndicate = properties !== undefined && properties.indicate === true;
    const item = LumixImportPrototype.asCharacteristic(characteristic);
    if (canIndicate && !canNotify) {
      trace.push('Nikon arming INDICATION on 0x2000 (advertises indicate only)');
      await gatt.setCharacteristicChangeIndication(item, true);
      trace.push('Nikon indication armed on 0x2000');
      // 步骤 2/9：CCCD 挂好、认证通道就绪，接下来是最容易"看起来卡住"的一段。
      NikonBleProvisioning.step(trace, 2, 9, '正在进行 LSS 认证…');
      return;
    }
    trace.push('Nikon arming NOTIFICATION on 0x2000 (notify=' + canNotify +
      ' indicate=' + canIndicate + ')');
    await gatt.setCharacteristicChangeNotification(item, true);
    trace.push('Nikon notification armed on 0x2000');
  }

  /** Renders an 8-byte identifier as lowercase hex for the diagnostic trace. */
  private static hex8(value: Uint8Array): string {
    let text = '';
    for (let i = 0; i < value.length; i++) {
      const byte = value[i] & 0xff;
      text += byte < 16 ? '0' + byte.toString(16) : byte.toString(16);
    }
    return text;
  }

  /** Locates one characteristic inside a discovered service tree. */
  private static findCharacteristic(services: ble.GattService[],
    characteristicUuid: string): ble.BLECharacteristic | undefined {
    const wanted = characteristicUuid.toLowerCase();
    for (const service of services) {
      for (const characteristic of service.characteristics || []) {
        if (characteristic.characteristicUuid.toLowerCase() === wanted) {
          return characteristic;
        }
      }
    }
    return undefined;
  }

  /**
   * Runs the full route: pair over BLE, authenticate, read the Wi-Fi
   * credentials and join the network.
   *
   * @param trace a caller-owned list the route appends its step-by-step
   *        findings to, including the identifier candidates it tried, so one
   *        hardware session is enough to resolve the open question
   * @param preferredDeviceId a known BLE address, to skip discovery
   * @param extraCandidates further 8-byte device identifiers to try after the
   *        ones derived from the scanned address
   */
  /** 只拉起相机 Wi‑Fi：**不重新配对**，复用「确认连接」已经建立的配对。
   *
   * 与 `SonyBleProvisioning.startWifi` 同形——这才是「图片传输」和「尼康控制」
   * 该走的入口。重新配对是「确认连接」的职责；在这里再配一次不但多花 40 秒以上，
   * 还会让流程卡在经典搜索那一步，导致后面的 Wi-Fi 关联根本执行不到。
   *
   * 用户实测的现象正是如此："点图片传输后又配对了一次，相机 Wi-Fi 已经打开，
   * 手机却没有发起连接"。 */
  static async startWifi(context: common.UIAbilityContext,
    trace: string[]): Promise<NikonProvisionResult> {
    return NikonBleProvisioning.provision(context, trace, '', [], false, true);
  }

  static async provision(context: common.UIAbilityContext, trace: string[],
    preferredDeviceId: string = '', extraCandidates: Uint8Array[] = [],
    pairOnly: boolean = false, wifiOnly: boolean = false): Promise<NikonProvisionResult> {
    const result: NikonProvisionResult = {
      ok: false,
      stage: 'scan',
      message: '',
      ssid: '',
      password: '',
      security: NikonLssEncryptMode.UNDEFINED,
      gateway: '',
      ipAddress: '',
    };
    const notifications: Uint8Array[] = [];
    // 读回"相机名 → 经典地址"的持久缓存。配对段要靠它：相机的经典侧只在配对窗口
    // 里可发现，而框架的发现状态经常卡在 DISCOVERYING，搜不到时只能用记下的地址。
    await NikonBleProvisioning.loadClassicAddresses(context, trace);
    // 步骤 1/9：整条流程的入口。用户点下去之后最先要知道的就是"它在找相机"。
    NikonBleProvisioning.step(trace, 1, 9, '正在扫描并连接相机…');
    let gatt: ble.GattClientDevice | null = null;
    NikonBleProvisioning.startTracePump(trace);
    try {
      await LumixImportPrototype.closeActiveGatt();
      // A powered-off adapter makes the first BLE call fail generically
      // ("Operation failed"), so check it up front and name the real problem.
      // Mirrors the check CameraPage already does before its own scan.
      try {
        const adapterState = bluetoothAccess.getState();
        trace.push('Nikon preflight bluetooth state=' + adapterState);
        if (adapterState === bluetoothAccess.BluetoothState.STATE_OFF) {
          result.message = '手机蓝牙未开启，请先打开蓝牙再配对尼康相机';
          NikonBleProvisioning.log(result.message);
          return result;
        }
      } catch (error) {
        trace.push('Nikon preflight bluetooth state unavailable: '
          + NikonBleProvisioning.describeError(error));
      }
      let scannedDeviceId = await NikonBleProvisioning.findCamera(trace, preferredDeviceId);
      // **提到这个分支之外**：下面构造 LSS 身份标识时也要用。经典地址是稳定的，
      // 而扫描到的 BLE 广播地址每次会话都会变（见下方 identityAddress 处的说明）。
      const knownBond = NikonBleProvisioning.bondedAddressFor('', trace);
      if (scannedDeviceId.length === 0) {
        // **不要把"已绑定的地址"当成 GATT 连接目标——这里原来就是这么做的，
        // 结果是 `GATT connection timeout`，用户看到"尼康蓝牙配网异常：GATT"。**
        //
        // 原来那几行：
        //   const knownBond = bondedAddressFor('', trace);
        //   if (knownBond.length > 0) scannedDeviceId = knownBond;
        //
        // 两个错误叠在一起：
        //   1. `bondedAddressFor` 返回的是相机的**经典蓝牙地址**（实测
        //      `92:6E:3A:43:A0:94`，来自系统配对列表），而下面要做的是
        //      **BLE 的 GATT 连接**——经典地址和 BLE 地址是两套东西，不能混用。
        //   2. GATT 连接需要相机正在**广播**。已配对的机身确实会停播，但正确的
        //      结论是"相机没进入可连接状态"，而不是硬连一个旧地址。
        //
        // 所以这里只记日志、不再替换连接目标；下面那个空结果分支会给出正确的
        // 结论（相机不在可连接状态）。
        if (knownBond.length > 0) {
          trace.push('Nikon no advertisement. The known bond ' + knownBond +
            ' is the camera Classic address; it cannot be used as a BLE GATT target '
            + '(doing so produced the "GATT connection timeout"), so the camera must advertise');
        }
      }
      if (scannedDeviceId.length === 0) {
        // Separate the two failures: nothing on the air at all, versus a busy
        // band in which nothing could be identified. They call for different
        // user actions and previously produced the same message, which is why
        // the last run could not be diagnosed from its own error text.
        result.message = NikonBleProvisioning.lastScanSeen > 0
          ? '扫描到 ' + NikonBleProvisioning.lastScanSeen
            + ' 个蓝牙设备，但均无法识别为尼康相机；请让相机停留在配对窗口后重试'
          : '未发现尼康 BLE 广播；请打开相机蓝牙并保持在配对窗口';
        NikonBleProvisioning.log(result.message);
        return result;
      }

      // The OS bond is deliberately NOT established here. The official client's
      // 22-step orchestration runs the entire BLE segment — client name,
      // connect request, server name, clock sync and LSS authentication —
      // BEFORE its BTC bond, and that bond is a Bluetooth *Classic* one for the
      // SPP channel. A field attempt that bonded first made the Z 5 report
      // "cannot connect" and leave pairing mode, so bonding before this point
      // was not merely useless, it was actively wrong.
      const deviceId = scannedDeviceId;

      // **标识要用"稳定地址"，不能用每次轮换的 BLE 广播地址。**
      //
      // 原来这里的注释写着"派生自扫描实际返回的地址"——那正是 BLE 广播地址，而它
      // **每次会话都会变**。相机的客户端身份是**注册那一次**记下来的，拿一个已经变了
      // 的值去认证，相机匹配不上就拒收。实测两次会话的对照非常清楚：
      //
      //   成功那次：identifier = 926e3a43a0940000  ← 经典地址 92:6E:3A:43:A0:94（稳定）
      //   失败这次：identifier = aee5575898230000  ← BLE 地址（已经轮换过）
      //
      // 用户的原话就是"**我方蓝牙对方不认可**"——字面意义上的不认可。
      //
      // **身份标识与相机地址无关 —— 这一点之前两版都搞错了。**
      //
      // 官方的 `deviceId` 是**手机自己持久化的 8 字节身份**（完整依据见
      // `loadClientDeviceId` 上方的说明）。它不是从相机推导出来的，所以下面这段
      // "用经典地址代替 BLE 地址"的推理**已被推翻**——两个地址都不是答案：
      //
      //   成功那次：identifier = 926e3a43a0940000  ← 经典地址
      //   失败这次：identifier = aee5575898230000  ← BLE 地址（已经轮换过）
      //   正确值：  手机自己存的 8 字节，一次生成、永久不变
      //
      // `buildDeviceIdCandidates` 与 `extraCandidates` 保留，但**只用于日志与兜底**：
      // 真正写进 stage-1 帧的是下面这个持久身份。
      const clientDeviceId = await NikonBleProvisioning.loadClientDeviceId(context, trace);
      const cameraDeviceIds: Uint8Array[] =
        NikonBleProvisioning.buildDeviceIdCandidates(deviceId).concat(extraCandidates);
      // Logged because the platform's deviceId is a MAC address on some builds
      // and an opaque privacy identifier on others; without it a run cannot
      // even tell whether the candidate list was meaningful.
      trace.push('Nikon BLE scanned=' + scannedDeviceId + ' connecting to=' + deviceId);
      trace.push('Nikon LSS identifier candidates=' +
        cameraDeviceIds.map((item: Uint8Array): string => NikonBleProvisioning.hex8(item)).join(' '));

      result.stage = 'gatt';
      gatt = await LumixImportPrototype.connectGatt(deviceId, trace);
      NikonBleProvisioning.activeGatt = gatt;
      // **请求最大 MTU，不再固定 64。**
      //
      // 以前这里是 `setBLEMtu(64)`，理由是"64 是尼康实测协商出来的值"。固定 64 的
      // 后果是 ATT 载荷只有 61 字节，而 `0x2004` 的 Wi-Fi 凭据是 **102 字节**——一次
      // 读装不下，协议栈就得走 Read Blob（第二次读带 offset）。
      //
      // Z 8 上真机日志把这条链完整暴露了出来：
      //   step 3/9 正在获取相机 Wi-Fi 凭据
      //   → 10.1 秒后 read-retry attempt=1/3 code=2900007   ← ATT 0x07 Invalid Offset
      //   → 0.4 秒后 read-retry attempt=2/3 code=2900011   ← ATT 0x11 Insufficient Resources
      // 三个错误码（Invalid Offset + Insufficient Resources）正好对应"分段读被拒、
      // 重试又撞上还没释放的操作"。
      //
      // 必须说明：**Z 5 上同样是 102 字节、同样 MTU 64 却读成功了**，所以 MTU 未必是
      // 全部原因，这里只是把这条不必要的分段路径彻底消除。平台与相机协商出多少就
      // 是多少（返回值记录在日志里），相机若给不到 512，行为不会比以前更差。
      try {
        trace.push('Nikon GATT MTU negotiated=' + (await gatt.setBLEMtu(512)));
      } catch (_error) {
        trace.push('Nikon GATT MTU=platform default');
      }

      const services = await gatt.getServices();
      let snapBridgeFound = false;
      for (const service of services) {
        trace.push('Nikon service ' + service.serviceUuid);
        if (service.serviceUuid.toLowerCase() === NikonCameraService.SNAPBRIDGE_SERVICE.toLowerCase()) {
          snapBridgeFound = true;
          // Log every LSS characteristic with its advertised permissions: this
          // is what separates "the camera refused the write" from "we asked for
          // an operation the characteristic does not permit". The live table
          // does not match the static one — this body exposes
          // 2082/2083/2084/2086/2087 where the DEX table lists 2081 — so the
          // permissions have to come from the device, not from the table.
          for (const characteristic of service.characteristics || []) {
            trace.push('Nikon LSS characteristic ' + characteristic.characteristicUuid +
              ' properties=' + NikonBleProvisioning.describeProperties(characteristic.properties));
          }
        }
      }
      if (!snapBridgeFound) {
        result.message = '尼康 BLE 已连接，但未发现 SnapBridge 服务；未发送猜测指令';
        NikonBleProvisioning.log(result.message);
        return result;
      }

      const authCharacteristic = NikonBleProvisioning.findCharacteristic(services,
        NikonCameraService.AUTHENTICATION_CHARACTERISTIC);
      const configurationCharacteristic = NikonBleProvisioning.findCharacteristic(services,
        NikonCameraService.CONNECTION_CONFIGURATION_CHARACTERISTIC);
      if (!authCharacteristic || !configurationCharacteristic) {
        result.message = '尼康 SnapBridge 服务缺少认证或 Wi-Fi 凭据特征，无法配网';
        NikonBleProvisioning.log(result.message);
        return result;
      }
      trace.push('Nikon auth characteristic properties=' +
        NikonBleProvisioning.describeProperties(authCharacteristic.properties));

      // The server device name (0x2003) is deliberately NOT read here. The
      // official order is CLIENT_DEVICE_NAME -> CONNECT_REQUEST ->
      // SERVER_DEVICE_NAME, so reading it before the connect request is out of
      // order — and the camera answers an out-of-order operation with the same
      // service status 128 that the earlier read probe produced and that was
      // briefly misread as a broken link. The read belongs after the connect
      // request, which is not implemented yet.
      const serverNameCharacteristic = NikonBleProvisioning.findCharacteristic(services,
        NikonCameraService.SERVER_DEVICE_NAME_CHARACTERISTIC);
      trace.push('Nikon server device name characteristic ' +
        (serverNameCharacteristic
          ? 'present; read deferred until after the connect request'
          : 'not present'));

      // Official pairing Stage-1 writes the client identity to 2002
      // (CLIENT_DEVICE_NAME) before the LSS authentication — see the
      // PAIRING_STAGE1_CLIENT_DEVICE_NAME_START/_END steps in the DEX. The LSS
      // session key is derived from a value both ends must agree on, and the
      // camera side can only know the phone's contribution if it was sent first;
      // this write is the most likely such transmission. It is best-effort: a
      // failure is logged and the route continues, because whether it is a hard
      // prerequisite is not yet confirmed and one capture will settle it. The
      // exact on-wire field width is likewise not yet confirmed, so the name is
      // kept short and ASCII.
      const clientNameCharacteristic = NikonBleProvisioning.findCharacteristic(services,
        NikonCameraService.CLIENT_DEVICE_NAME_CHARACTERISTIC);
      // **先不写 `0x2002`：官方第一个动作是"认证"，不是客户端名。**
      //
      // 安卓 logcat 实测（已注册会话 19:59:36，每一次写入都是 status=0）：
      //   订阅 CCCD ×5 → **写 0x2000 认证 ×2** → 读 2A19 → 写 0x2002 → 写 0x2007
      //   → 读 0x2009 / 0x2A26 → 读 0x2008 ×2 + 写 0x2008
      //   → 读 0x2001 / 0x2004 → 写 0x2005
      //
      // 而我们原来第一个动作就是写 `0x2002`——**它正好是失败的第一个写入**
      // （实测 0 毫秒返回、由本地协议栈直接拒掉，code 2900099）。
      //
      // 相机很可能要求"认证先于一切写入"：会话未被认证之前，它对 0x2002 这类需要
      // 权限的特征一律不认。所以把 `0x2002` 从认证之前挪到认证之后——认证之后那次
      // 写入就是下面的 `clientNameAfterAuth`。
      gatt.on('BLECharacteristicChange', (changed: ble.BLECharacteristic): void => {
        const bytes = new Uint8Array(changed.characteristicValue);
        if (changed.characteristicUuid.toLowerCase() ===
          NikonCameraService.AUTHENTICATION_CHARACTERISTIC.toLowerCase()) {
          notifications.push(bytes.slice());
        }
      });
      let authArmed = true;
      let authFailure = '';
      try {
        await NikonBleProvisioning.armAuthCharacteristic(gatt, authCharacteristic, trace);
      } catch (error) {
        // Name the step that failed. Letting this escape produced a bare
        // 2900099 "Operation failed" that said nothing about where it happened.
        authArmed = false;
        authFailure = NikonBleProvisioning.describeError(error);
        trace.push('Nikon arming 0x2000 FAILED: ' + authFailure);
      }
      // 官方在**认证之前**就把 CCCD 全配好了：插桩日志里那几次
      // setCharacteristicNotification 全部出现在认证写入之前。我们此前把这组订阅
      // 放在配对阶段之后，顺序和官方正好相反。
      await NikonBleProvisioning.listenToCamera(gatt, services, trace);
      // **等 CCCD 订阅落定，再发第一个写入。**
      //
      // 这是 `2900099` 的真正来源。实测时间戳：
      //   20:03:51.043  subscribed to 00002021-...        ← 最后一个 CCCD 订阅
      //   20:03:51.043  write-before 00002000-...         ← 同一毫秒就发写入
      //   20:03:51.043  write-result status=error code=2900099
      //
      // 鸿蒙的 GATT 客户端**同一时刻只允许一个未完成的操作**，而订阅 CCCD 本身
      // 就是一次**描述符写入**。它还没完成时紧接着调用 `writeCharacteristicValue`，
      // 会被本地协议栈**立刻拒绝**——0 毫秒、`2900099`，字节根本没上空口，所以
      // 相机那边毫无反应。
      //
      // 这也解释了为什么它是"时好时坏"的：链路快时订阅几毫秒内完成，写入落在
      // 后面就成功（之前那些成功的会话）；链路慢时两者重叠就被拒。
      //
      // 官方客户端每个操作之间自然相隔约 100 毫秒（它的 CCCD 订阅、认证、电量读取
      // 从不重叠），所以永远不撞车。这里显式等一段，把这个隐含假设变成代码。
      await LumixImportPrototype.delay(400);
      if (!authArmed) {
        result.message = '无法在尼康认证特征 0x2000 上开启通知/指示：' + authFailure +
          '（相机拒绝该操作：机身可能未确认配对，或已绑定其他手机）';
        NikonBleProvisioning.log(result.message);
        return result;
      }

      // --- LSS authentication -------------------------------------------------
      result.stage = 'auth';
      const session = await NikonBleProvisioning.authenticate(gatt, authCharacteristic,
        notifications, cameraDeviceIds, result, trace);
      if (session === null) return result;

      // --- Wi-Fi credentials --------------------------------------------------
      //
      // The credential bytes are read once: they do not depend on the device
      // identifier. What does depend on it is the session key, because the
      // official client passes the identifier as `key2` into the derivation.
      // The handshake itself never binds it, so each candidate is tried purely
      // locally against the same bytes and accepted only when the SSID decrypts
      // into printable text — a wrong key yields a short run of control bytes,
      // which that check rejects. Every attempt is logged, so one hardware
      // session identifies the real source and this list collapses to one entry.
      result.stage = 'credentials';
      // 步骤 3/9：相机把 Wi-Fi 凭据（SSID + 密码）交出来。
      //
      // **注意它在流程里的位置**：读凭据排在配对段**之前**（日志实测 3 秒内就到），
      // 而 Wi-Fi 关联排在配对段**之后**。所以步骤号必须按真实执行顺序编，
      // 否则弹窗会出现 5 在 3、4 之前的乱序。
      NikonBleProvisioning.step(trace, 3, 9, '正在获取相机 Wi‑Fi 凭据…');
      const raw = new Uint8Array(await LumixImportPrototype.readGattRetry(gatt, configurationCharacteristic, trace));
      // 原始的 0x2004 读取结果（102 字节）原样打出来。我们此前只解析出里面的
      // Wi-Fi SSID / 密码就把其余部分丢掉了，而相机的**真实蓝牙地址（BD_ADDR）**
      // 很可能就藏在这块数据里——这是相机告诉客户端"我是谁"最自然的位置。
      //
      // 为什么必须找到它：相机的 BLE 广播用的是**不可解析私有地址**（NRPA，最高
      // 两位为 00），实测两次运行分别是 30:78:2E:32:C0:4C 和 3E:36:C7:13:DE:29，
      // 每次都在变。这种一次性地址根本无法用于绑定：拿它调 pairDevice，手机侧会
      // 进 BONDING(1)，但相机不认这个地址，于是 passkey=0、不出码，随即回滚
      // NONE(0)——我们每一轮看到的就是这个。
      trace.push('Nikon 0x2004 connection configuration raw len=' + raw.length +
        ' hex=' + NikonBleProvisioning.hex8(raw));
      let configuration: NikonLssConnectionConfiguration | null = null;
      // **会话密钥的两个素材已经用原生库自己证实了**（探针
      // `vivid_lssprobe` 在设备上 dlopen 了 `libLsSec-jni.so`，让原生代码
      // 去穷举 8 个共享根并派生密钥，再把真实密文解出来）：
      //
      //   key1 = stage-4 帧的 deviceId 字段（= `lastCameraDeviceId`）
      //   key2 = **客户端持久 DeviceID**，不是相机地址
      //
      // 原生证据：`ConnectBluetoothAction.generateKey(kVar2.b(), bArr)`，
      // 其中 `bArr` 与 `BleConnection.connect(..., deviceId, ...)` 同源，即
      // `SharedPreferences("DeviceID")` 里那份 8 字节客户端身份。
      //
      // 之前这里在 `cameraDeviceIds`（从相机蓝牙地址推导）里循环，方向就是
      // 错的——那个值是手机自己的，跟相机地址没有任何关系。
      if (session.deriveSessionKey(NikonBleProvisioning.lastCameraDeviceId, clientDeviceId)) {
        const attempt = parseLssConnectionConfiguration(raw,
          (encrypted: Uint8Array): Uint8Array | null => {
            const plain = session.decipher(encrypted);
            trace.push('Nikon 0x2004 field cipherLen=' + encrypted.length +
              ' cipher=' + NikonBleProvisioning.hex8(encrypted) +
              ' plain=' + (plain === null ? '(decrypt failed)' : NikonBleProvisioning.hex8(plain)));
            return plain;
          });
        if (attempt !== null && attempt.hasWifiSetting &&
          isPlausibleCredentialText(attempt.ssid, 3, 32) &&
          isPlausibleCredentialText(attempt.password, 0, 64)) {
          configuration = attempt;
        }
      } else {
        trace.push('Nikon LSS session key derivation failed: stage 3 did not run or the ids are short');
      }
      if (configuration === null) {
        result.message = '尼康蓝牙认证已通过，但 Wi-Fi 凭据未能解密';
        NikonBleProvisioning.log(result.message);
        return result;
      }
      result.ssid = configuration.ssid;
      result.password = configuration.password;
      result.security = configuration.security;
      trace.push('Nikon Wi-Fi credential received ssid=' + configuration.ssid +
        ' security=' + NikonLssEncryptMode.nameFor(configuration.security) +
        ' passwordLength=' + configuration.password.length);
      // The same key protects the PTP-side credential mirror (0x9532), so keep
      // it for whichever transport reads the block next.
      NikonBleProvisioning.lastSessionKey = session.exportSessionKey();
      // 第三次尝试写客户端名（0x2002）。前两次都发生在 LSS 会话建立**之前**：
      // 0x2002 的属性只有 write，实测框架对它的写入一律返回 ret=-41，而同一条
      // 连接上 0x2000 的写入是 ret=0，所以失败不是链路问题。官方顺序把
      // CLIENT_DEVICE_NAME 排在第一步，但相机屏幕一直停在「等待配对」，而它要的
      // 很可能就是一个"经认证的链路上报上的手机名"。现在会话密钥已经协商完成，
      // 这是唯一一次在已认证链路上写这个名字的机会。
      const clientNameAfterAuth = await NikonBleProvisioning.writeClientDeviceName(
        gatt, clientNameCharacteristic, trace);
      trace.push(clientNameAfterAuth
        ? 'Nikon client device name accepted after LSS authentication'
        : 'Nikon client device name still rejected after LSS authentication');
      // 官方顺序里 CONNECT_REQUEST 紧跟 CLIENT_DEVICE_NAME，是配对的收尾步骤，
      // 相机从「等待连接」翻到「已连接」靠的就是这一条。此前只在动作路径以 Wi-Fi
      // 标志（0x05）发过一次，配对阶段一次都没发，所以相机一直停在「等待连接」。
      // 同一个特征两个值：0x04 = BT（完成配对本身），0x05 = Wi-Fi（拉起热点）。
      // **写 0x2005 = CONNECTION_ESTABLISHMENT。**
      //
      // 之前依据"官方第一段会话里没有 0x2005"把它从配对路径上拿掉了。这个判断太
      // 绝对：官方是在第二段会话写它、紧接着就 `bindlisten`
      //   write connection establishment → bindlisten rfcomm channel: 7
      // 而"相机主动连入手机"这件事，我们从来没让它真正有机会发生——**手机可被
      // 发现、RFCOMM 监听、0x2005 这三个前提从来没有同时成立过**。
      //
      // 现在必须凑齐，因为这是唯一剩下的路：BLE 侧的绑定相机是明确拒绝的（PIN
      // 正确、系统已确认 accept=1，仍然 `AUTH_FAILURE`），经典侧又永远不对 inquiry
      // 应答（两次搜索、59 个设备、没有 A0:CD:F3）。所以只能等相机主动连进来，
      // 用 getDeviceId 从连接里直接拿到它真正的经典地址。
      await NikonBleProvisioning.requestConnectionEstablishment(gatt, services, 0x01, trace);
      trace.push('Nikon pairing path: 0x2005 = [1] sent so the camera can open the BTC link');
      await NikonBleProvisioning.readServerDeviceName(gatt, services, trace);
      // 官方 `pairing end` 之后还有三次**读**，我们一直漏掉了：
      //   0x200B LSS_SERIAL_NUMBER_STRING   → 日志 "read lss serial number string"
      //   0x2A26 firmware revision string   → 日志 "read firmware revision string"
      //   0x2009 LSS_FEATURE                → 日志 "read lss feature"，**连读 3 次**
      // 官方把这三步读完之后才 disconnect，紧接着相机自己发起蓝牙配对——那一段
      // 应用日志是完全空白的（从 15:22:53.654 一直到 20 秒后的 removeBond），
      // 说明配对不是应用发起的，是相机发起的。相机多半就是在等客户端把这些读走。
      await NikonBleProvisioning.readCameraInfo(gatt, services, trace);
      // 0x2006 CURRENT_TIME：官方日志原话 "This camera need not write time info."，
      // Z 5 上**不写**这个特征。
      // 0x2001 POWER_CONTROL：一并去掉。官方只在**已绑定之后**的会话里**读**它
      // （日志 `read power control` → readCharacteristic 0x2001），配对路径上
      // 完全不碰；我们之前写 WAKE_WAIT 每次都返回 2900099，正是因为那个特征在
      // 配对阶段不接受写入。
      // （CCCD 订阅已在**认证之前**完成，见上面的 listenToCamera 调用。）
      // --- 收尾：系统级蓝牙配对（数字比对）----------------------------------
      // 官方状态机的最后一段。相机给码、手机确认、相机再确认——缺了这一步相机就
      // 一直停在「等待配对」。必须放在 LSS 阶段**之后**：早前放在开头试过，相机
      // 直接报「无法连接」并退出配对模式。
      // **相机若已经在系统里绑定过，就不要再自己创建绑定了。**
      //
      // 用户手动在系统蓝牙里配对 `Z_5_8073573` 成功——这证明相机的经典侧**是**能
      // 被发现的，只是不对我们用 API 发起的那 12 秒搜索窗口应答。既然绑定已经存在，
      // 再去 `pairDevice`（而且是在每轮轮换的 BLE 广播地址上）只会拿到
      // `AUTH_FAILURE`，还可能把已有的正确记录搅乱。
      //
      // 这一步同时把相机的**真实经典地址**打了出来（`bondedAddressFor` 会逐条打印
      // 已绑定记录的名字和地址），那正是我们几十轮一直缺的那个东西。
      // **手机侧有绑定，不代表相机侧还认我们。**
      //
      // 相机可以自己删掉配对记录、恢复出厂设置、或者被配到别的手机上。如果因为
      // "系统里有记录"就整段跳过配对，那么相机一旦忘了我们，App 永远发现不了，
      // 也永远不会重新配对——这正是用户指出的缺陷。
      //
      // 所以**每次都走一遍**：解析出相机的经典地址后调 `pairDevice`。两边都还绑着
      // 时系统会立刻返回已绑定（不弹框、不阻塞）；相机忘了我们时才会真正发起配对、
      // 由用户核对码确认。手机侧的记录只当作**日志和首选目标**（省掉那 36 秒搜索），
      // 绝不作为跳过流程的依据。
      const bondedCamera = NikonBleProvisioning.bondedAddressFor(deviceId, trace);
      trace.push('Nikon BTC phone-side bond for the camera: ' +
        (bondedCamera.length > 0
          ? bondedCamera + ' (used as the preferred target; the camera is still asked)'
          : '(none, pairing from scratch)'));
      // **图片传输（`wifiOnly`）跳过整段配对。**
      //
      // 用户点「图片传输」时配对早就由「确认连接」完成了；这一段唯一的作用是重新
      // 配对（触发 + 经典搜索，40 秒以上），而且实测会把流程**卡在第 7 步**，
      // 让后面的 Wi-Fi 关联根本执行不到——表现就是"又配对了一次，却没连 Wi-Fi"。
      //
      // 跳过之后流程直接落到下面的 Wi-Fi 段，这正是 `SonyBleProvisioning.startWifi`
      // 的形状：复用已有配对，只拉起热点并关联。
      let bondOk = true;
      if (wifiOnly) {
        trace.push('Nikon image transfer: pairing was completed by 「确认连接」; '
          + 'skipping the pairing segment and going straight to the Wi-Fi access point');
      } else {
        bondOk = await NikonBleProvisioning.bondWithPasskey(deviceId, trace, bondedCamera);
      }
      trace.push('Nikon BTC segment result=' + (bondOk ? 'ok' : 'not completed'));
      // 第二段（重连再认证）和第三段（经典蓝牙绑定）都已实测为死路：
      // 同链路与新建链路相机都不再回应认证，经典搜索里相机完全不可见。
      // 暂时停掉，避免每轮多花 40 秒并淹没日志；代码留在 runSecondSegment /
      // requestSystemBond 里，需要时随时可以重新打开。
      // const secondSegmentOk = await NikonBleProvisioning.runSecondSegment(
      //   trace, deviceId, cameraDeviceIds);
      // trace.push('Nikon second segment result=' + (secondSegmentOk ? 'ok' : 'not completed'));
      // const bondOk = await NikonBleProvisioning.requestSystemBond(deviceId, trace);
      // trace.push('Nikon BTC segment result=' + (bondOk ? 'ok' : 'not completed'));

      // --- Join the camera network -------------------------------------------
      // A pairing-only run stops here. `确认连接` is the Bluetooth pairing: it
      // reads the Wi-Fi name and password and leaves the radio alone. Raising
      // the access point and joining it belongs to the action that actually
      // needs the network (图片传输 / 相机控制), which is why that work sits in
      // the caller's ensureNikonWifiForAction. Doing it here made the confirm
      // step sit for a minute waiting for an access point that only the later
      // action is supposed to ask for.
      if (pairOnly) {
        // **配对成没成，就看绑定有没有真的建立，不能靠"超时到了"算过。**
        //
        // 这里原来无条件写 `result.ok = true`，`bondOk` 只进了日志。后果是：
        // 用户点了「确认连接」，配对码自始至终没出现、`pairDevice` 还失败了，
        // 流程等满时限之后照样返回成功——上层于是把这张卡片记成
        // `blePaired = true`（也就是界面上那个「已注册」）。
        //
        // 但绑定根本没建立，蓝牙链路是不通的，后续拉热点、开控制全都是空转；
        // 而且相机会**停止广播**，一旦被误标成已注册，它就会一直挂在"已注册"
        // 分类里，用户既用不了、也不知道该重新配。
        //
        // 现在只有两种情形算配对成功：
        //   · 本轮真的等到了 BONDED（用户在两台设备上确认了配对码）
        //   · 手机侧本来就已经绑过这台相机（复用既有绑定，不再弹配对码）
        // 其余一律失败，让上层不要写注册标记。
        result.stage = bondOk ? 'paired' : 'bond';
        result.ok = bondOk;
        result.ssid = configuration.ssid;
        result.password = configuration.password;
        result.security = configuration.security;
        if (bondOk) {
          trace.push('Nikon pairing-only run: credentials read, access point left alone');
        } else {
          result.message = '尼康相机蓝牙配对未完成：没有等到配对码确认，未建立系统绑定。'
            + '请在手机「设置 → 蓝牙」里手动配对这台相机，或确认相机处于配对模式后重试。';
          trace.push('Nikon pairing-only run: bond not established, so this run does NOT '
            + 'count as registered（Wi-Fi 凭据已读到，但不写入卡片）');
          NikonBleProvisioning.log(result.message);
        }
        return result;
      }
      result.stage = 'wifi';
      // **补上官方在写 `0x2005` 之前的那个读：`0x2001` POWER_CONTROL。**
      //
      // 安卓抓包里，官方**已绑定之后**的会话（下载照片那次）顺序是：
      //   认证 → 读 0x2001 → 读 0x2004 → 写 0x2005 = [1] → requestNetwork
      // 而我们的流程从头到尾没有读 0x2001。
      //
      // 之前我在配对路径上把它去掉了，理由是"写它总是 2900099 失败"——可官方那里是
      // **读**、不是写，我把这两件事混在一起处理了。实测后果：跳过配对段的那一轮，
      // `0x2005 = [1]` 写入返回 success，相机却始终没把热点挂出来（扫描 8 轮全空）。
      //
      // 放在这里（`pairOnly` 已提前返回之后）正好对应官方的时序：配对那次不碰它，
      // 真正要用网络时才读。读失败不阻断流程——相机若不需要它，行为与之前一致。
      try {
        const powerCharacteristic = NikonBleProvisioning.findCharacteristic(services,
          NikonCameraService.POWER_CONTROL_CHARACTERISTIC);
        if (powerCharacteristic) {
          const powerValue = new Uint8Array(
            await LumixImportPrototype.readGatt(gatt, powerCharacteristic, trace));
          trace.push('Nikon 0x2001 power control read before 0x2005 = ' +
            NikonBleProvisioning.hex8(powerValue));
        } else {
          trace.push('Nikon power control characteristic 0x2001 not present');
        }
      } catch (error) {
        trace.push('Nikon 0x2001 read failed: ' + NikonBleProvisioning.describeError(error));
      }
      // Raise the access point first: the credentials arrived over BLE, but the
      // network itself only comes up when the camera is told to establish it.
      // 0x2005 CONNECTION_ESTABLISHMENT：实测官方写的是 **[1]**，不是报告里说的
      // 0x04 / 0x05。已绑定之后的会话（下载照片那次）在认证完、读完 0x2001 和
      // 0x2004 之后就写这一个字节，紧接着是 requestNetwork + RFCOMM 监听。
      await NikonBleProvisioning.requestConnectionEstablishment(gatt, services, 0x01, trace);
      // **补上官方紧跟在 `0x2005` 之后的那一步：开 RFCOMM 监听。**
      //
      // 安卓抓包里，官方写完 `0x2005 = [1]` 的下一件事就是：
      //   `bindlisten add: … mType:1, rfcomm channel: 7`
      // 而在此之前它还会把手机**设为可被发现**。
      //
      // 我们之前只在配对段（`bondWithPasskey`）里开这个监听——图片传输跳过配对段时，
      // 这一步被一起跳过了。用户实测：相机停在「蓝牙已连接」，但**不切换到 Wi-Fi
      // 模式**。这很可能就是原因：相机在 `0x2005` 之后要等客户端把 BTC 通道挂起来
      // （或等手机变得可被发现）才肯开热点。
      //
      // 失败不阻断：监听开不起来时，后面的扫描照跑，行为与之前一致，不会更差。
      try {
        NikonBleProvisioning.openBtcListener(trace);
      } catch (error) {
        trace.push('Nikon BTC listener on the Wi-Fi path failed: ' +
          NikonBleProvisioning.describeError(error));
      }
      //
      // 实测结论：相机**没有进入 Wi-Fi 模式**时，`0x2005 = [1]` 写入照样返回
      // `success`（字节进了特征），但相机**不做任何事**——热点永远不出现，扫描
      // 8 轮全空，最后报一句"加入网络失败"，用户完全不知道问题在相机那边
      // （实测就是这么卡住的）。
      //
      // 唯一成功看到热点的那一轮耗时 **44 毫秒**——那是缓存结果，说明热点在扫描
      // 之前**就已经开着**，是相机自己开的，不是我们拉起的。这反过来印证了：
      // 热点是机身状态决定的，App 只能请求、不能代替用户把相机切到那个界面。
      //
      // 所以这一步必须明确告诉用户去相机上做什么，而不是让 App 空转。
      // **在扫描热点之前，先断开蓝牙链路。**
      //
      // 这是整条图传链路上最关键的一处顺序问题。用户现场观察非常明确：
      // 点图片传输后热点一直不出现，**一退出 App**（进程结束、系统断开 BLE 链路）
      // **热点"一瞬间"出现并且保持不关**。
      //
      // 结论：相机收到 `0x2005 = [1]` 之后**不会立刻开热点**，它要等蓝牙链路
      // 断开才开——相机同一时刻只能跑一路无线，蓝牙占着它就不开 Wi-Fi。
      //
      // 而原来的顺序是：写 `0x2005` → 开始扫描热点（约 1.5 分钟）→ 最后才在
      // `finally` 里释放链路。**整个扫描期间链路都连着，所以热点永远不出现**，
      // 扫描必然是"8 轮全空"，最后报一句"未找到相机 Wi-Fi"。
      //
      // 凭据早就读完、`0x2005` 也发出去了，后面的关联热点不需要蓝牙，所以这里
      // 把释放提前。`finally` 里那次释放保留不动（`release` 可重入，重复调用无害），
      // 这样异常路径上也依然会释放。
      try {
        // 监听必须在等之前就挂上。配对段被跳过时（「确认连接」已经配过）它不一定
        // 开过，而相机的连入正是热点出现的触发条件——所以这里补一次，幂等。
        NikonBleProvisioning.openBtcListener(trace);
        // **先等相机连进来。** 这是相机开热点的触发条件：官方的顺序是
        // 「写 0x2005 → 开 RFCOMM 监听 → 相机连入 → 链路断开 → 热点出现」。
        // 少了"相机连入"这一环，后面无论断得多干净相机都不动。
        await NikonBleProvisioning.waitForBtcPeer(25000, trace);
        // 然后把经典蓝牙那一侧彻底放掉（相机连进来的 RFCOMM 链路 + 服务端监听 +
        // 可被发现模式），再放 GATT。三样缺一相机都不开热点——详见 closeBtc。
        NikonBleProvisioning.closeBtc(trace);
        try {
          ble.stopBLEScan();
          trace.push('Nikon BLE scan stopped before the Wi-Fi join');
        } catch (error) {
          trace.push('Nikon stopBLEScan before the Wi-Fi join failed: ' +
            NikonBleProvisioning.describeError(error));
        }
        await NikonBleProvisioning.release();
        trace.push('Nikon BLE link released BEFORE the Wi-Fi join '
          + '(the camera only raises its access point after Bluetooth drops)');
        // 再等一拍、再关一次：`sppListen` 的回调可能比上面这一轮更晚到，
        // 那时它会拿着一个新句柄出现在已经释放过的系统状态里。
        await LumixImportPrototype.delay(2000);
        NikonBleProvisioning.closeBtc(trace);
        trace.push('Nikon Bluetooth re-released after a settle delay '
          + '(catches sockets whose async callbacks arrived late)');
      } catch (error) {
        trace.push('Nikon early Bluetooth release failed: ' +
          NikonBleProvisioning.describeError(error));
      }
      NikonBleProvisioning.step(trace, 8, 9,
        '正在连接相机 Wi-Fi。请在相机上进入「连接至智能设备」并停留在该界面'
        + '（相机不在该界面就不会开启热点）；'
        + '相机屏幕上若出现确认提示，请在相机上选择「OK / 确定」；'
        + '手机弹出 Wi-Fi 授权提示时请允许。密码由相机提供，无需输入');
      // 第 5～8 个参数用默认值（joinAttempts / onPrompt / scanWindowMs /
      // skipScanWhenLinked），只有最后一个 onStatus 要接上：扫描阶段最长 75 秒，
      // 而这段时间弹窗原本一个字都不变（实测 23:25:13.800 显示"正在连接相机
      // Wi-Fi"，直到 23:25:32.305 才扫到热点，中间 19 秒静止），看着就像卡死。
      // 把"已等待多少秒"持续报出去，用户才知道是在正常推进。
      const joined: WifiConnection = await LumixImportPrototype.connectWifi(
        configuration.ssid, configuration.password, trace, 1,
        (_attempt: number): void => {},
        75000,
        false,
        (status: string): void => {
          NikonBleProvisioning.step(trace, 8, 9, status);
        });
      result.gateway = joined.gateway;
      result.ipAddress = joined.ipAddress;
      if (!joined.connected || joined.gateway.length === 0) {
        // 失败原因几乎总是"相机没开热点"，而不是凭据或密码有问题——凭据是从相机
        // 自己手里读来的，不会错。所以这句话必须指向相机那一侧的动作。
        //
        // 已经确认：`0x2001` 读到 `03`（相机醒着）、`0x2005 = [1]` 写入 success、
        // 手机已设为可被发现、RFCOMM 监听已挂起——**官方的整套动作全部做完了**，
        // 相机仍然不开热点。所以剩下的开关一定在相机菜单上，不在协议里。
        result.message = '未找到相机 Wi-Fi（' + configuration.ssid + '）。'
          + '蓝牙部分已完成，但相机没有开启热点。请在相机上确认三点：'
          + '① 进入「连接至智能设备」并停留在该界面；'
          + '② 相机屏幕上若出现确认提示，选择「OK / 确定」；'
          + '③ 相机菜单里的 Wi-Fi 连接未被关闭、也未处于飞行模式。'
          + '然后重试';
        NikonBleProvisioning.log(result.message);
        return result;
      }
      result.ok = true;
      result.message = '尼康蓝牙配网完成，已接入相机 Wi-Fi';
      NikonBleProvisioning.log(result.message + ' gateway=' + joined.gateway);
      return result;
    } catch (error) {
      // Report the stage and the platform error code, not just the message: a
      // bare "Operation failed" cannot be acted on, while
      // "stage=gatt code=2900099" names the exact step that failed.
      const detail = NikonBleProvisioning.describeError(error);
      result.message = '尼康蓝牙配网异常：' + detail + `（阶段 ${result.stage}）`;
      trace.push(`Nikon exception stage=${result.stage} detail=${detail}`);
      hilog.error(DOMAIN, TAG, '%{public}s', result.message);
      AppLogSink.emit('CTL_ERR', result.message);
      return result;
    } finally {
      // Release the link before returning. A body that is connected to us stops
      // advertising, so holding the GATT connection after pairing is what made
      // the camera card vanish from the nearby list — and no amount of
      // restarting discovery can find a camera that has stopped beaconing.
      // Nothing after this point needs BLE: the session key is already saved and
      // image transfer and control run over Wi-Fi.
      try {
        await NikonBleProvisioning.release();
      } catch (error) {
        trace.push('Nikon GATT release failed: ' +
          NikonBleProvisioning.describeError(error));
      }
      // Mirror the whole run trace to HiLog. This flow is diagnosed from
      // `hdc shell hilog`, and steps that only reach the in-app log are
      // invisible there — which is what made the first field failure (2900099
      // at stage gatt) impossible to place without a round-trip. The pump has
      // already emitted everything produced so far; this flushes the remainder.
      NikonBleProvisioning.stopTracePump(trace);
    }
  }

  /** Mirrors trace entries to HiLog as they are produced.
   *
   * The trace used to be dumped in one go when `provision` returned, so a run
   * that never returned produced no output at all — indistinguishable from a
   * tap that never reached the route. That ambiguity cost a field round: the
   * app appeared to do nothing and the log was empty. Pumping on a timer makes
   * a stall visible at the step where it happened, without every producer
   * having to log as it goes. */
  private static startTracePump(trace: string[]): void {
    NikonBleProvisioning.tracePumpAt = 0;
    NikonBleProvisioning.tracePumpId = setInterval((): void => {
      NikonBleProvisioning.flushTrace(trace);
    }, 400);
  }

  /** Emits trace entries produced since the previous flush. */
  private static flushTrace(trace: string[]): void {
    while (NikonBleProvisioning.tracePumpAt < trace.length) {
      hilog.info(DOMAIN, TAG, '%{public}s',
        'nikon-trace ' + trace[NikonBleProvisioning.tracePumpAt]);
        AppLogSink.emit('CTL', 'nikon-trace ' + trace[NikonBleProvisioning.tracePumpAt]);
      NikonBleProvisioning.tracePumpAt += 1;
    }
  }

  /** Stops pumping and emits whatever is left. */
  private static stopTracePump(trace: string[]): void {
    if (NikonBleProvisioning.tracePumpId >= 0) {
      clearInterval(NikonBleProvisioning.tracePumpId);
      NikonBleProvisioning.tracePumpId = -1;
    }
    NikonBleProvisioning.flushTrace(trace);
  }

  /**
   * Builds the candidate device identifiers to try.
   *
   * The 8-byte value the official client passes into `lssAuthProc` could not be
   * recovered statically. Rather than invent one, this returns every observable
   * 8-byte interpretation and lets the two independent plausibility checks in
   * the caller decide. The order is deliberate — the most likely shapes first,
   * so a normal session succeeds immediately while the log still records the
   * whole list for the record.
   */
  static buildDeviceIdCandidates(bleAddress: string): Uint8Array[] {
    const candidates: Uint8Array[] = [];
    const digits = bleAddress.replace(/[^0-9A-Fa-f]/g, '');
    if (digits.length >= 12) {
      const address = new Uint8Array(6);
      for (let i = 0; i < 6; i++) {
        address[i] = parseInt(digits.substr(i * 2, 2), 16) & 0xff;
      }
      const low = new Uint8Array(8);
      low.set(address, 0);
      candidates.push(low);
      const high = new Uint8Array(8);
      high.set(address, 2);
      candidates.push(high);
    }
    candidates.push(new Uint8Array(8));
    return candidates;
  }

  /** Session key from the most recent successful provisioning, or null. */
  private static lastSessionKey: Uint8Array | null = null;

  /** 相机在 LSS 第 4 帧里放回的 deviceId（即 key1）。
   *
   * 认证握手被抽成 `authenticate()` 之后，这个值不再留在 `provision` 的局部
   * 作用域里，但下面的凭据解密要用它当 `key2` 的候选来源，所以握手结束时把它
   * 存到这里。 */
  private static lastCameraDeviceId: Uint8Array = new Uint8Array(0);

  /**
   * Returns a copy of the session key established by the last successful BLE
   * provisioning, or null when none is held.
   *
   * The PTP-side credential mirror (`0x9532`) is protected by the same key, so
   * a body already on Wi-Fi can re-issue its credentials to the same phone
   * without a fresh Bluetooth pairing.
   */
  static takeSessionKey(): Uint8Array | null {
    if (NikonBleProvisioning.lastSessionKey === null) {
      return null;
    }
    return NikonBleProvisioning.lastSessionKey.slice();
  }

  /**
   * Waits for the next queued authentication notification.
   *
   * Returns null on timeout rather than throwing, so a silent camera produces a
   * phase message instead of an exception.
   */
  private static async waitForNotification(queue: Uint8Array[], trace: string[]): Promise<Uint8Array | null> {
    const startedAt = Date.now();
    while (Date.now() - startedAt < NOTIFICATION_TIMEOUT_MS) {
      if (queue.length > 0) {
        const next = queue.shift();
        if (next !== undefined) {
          trace.push('Nikon LSS notification len=' + next.length);
          return next;
        }
      }
      await NikonBleProvisioning.delay(NOTIFICATION_POLL_MS);
    }
    trace.push('Nikon LSS notification timeout after ' + NOTIFICATION_TIMEOUT_MS + 'ms');
    return null;
  }

  /** 订阅所有可通知/指示的特征，并把相机发来的每一帧原始字节记进日志。
   *
   * 到这一步为止，我们只在 `0x2000` 上收到过相机的数据（LSS 认证的应答）。如果
   * 相机要告诉我们"配对完成"或"请在机身上确认"之类的事情，它只可能走
   * notify/indicate——而设备上 `0x2008`、`0x200A`、`0x2020`、`0x2021`、`0x2084`、
   * `0x2087` 都支持这些属性，**我们一个都没订阅过**。
   *
   * 这个函数把"相机到底有没有对我们说话"变成一个看日志就能回答的问题，而不是
   * 继续靠推测。 */
  private static async listenToCamera(gatt: ble.GattClientDevice,
    services: ble.GattService[], trace: string[]): Promise<void> {
    gatt.on('BLECharacteristicChange', (changed: ble.BLECharacteristic): void => {
      const bytes = new Uint8Array(changed.characteristicValue);
      let hex = '';
      for (let index = 0; index < bytes.length; index++) {
        hex += (bytes[index] < 16 ? '0' : '') + bytes[index].toString(16);
      }
      trace.push('Nikon camera notification ' + changed.characteristicUuid +
        ' len=' + bytes.length + ' data=' + hex);
      // 相机在 LSS 认证阶段会把**配对码**发过来：实测载荷是 ASCII "-303351"，
      // 前面是会话状态字节。这个码一直只被记进日志，然后就没有下文了。
      NikonBleProvisioning.harvestCameraPin(bytes, trace);
    });
    let armed = 0;
    for (const service of services) {
      const characteristics = service.characteristics;
      if (characteristics === undefined) {
        continue;
      }
      for (const characteristic of characteristics) {
        const uuid = characteristic.characteristicUuid.toLowerCase();
        // 官方只配这 4 个特征（插桩日志里 setCharacteristicNotification 恰好出现
        // 4 次，一次不多）：
        //   0x200A LSS_CABLE_ATTACHMENT           → notification
        //   0x2000 LSS_AUTHENTICATION             → indication（armAuthCharacteristic 管）
        //   0x2020 LSS_STATUS_FOR_CONTROL         → indication
        //   0x2021 LSS_CONTROL_POINT_FOR_CONTROL  → indication
        // 我们此前把链路上 7 个可通知/指示特征全部订阅（0x2A05 服务变更、0x2008、
        // 0x2084、0x2087 都订了），这份 CCCD 状态和官方不一样，相机看到的是一份
        // 它没预期的配置。
        const isCableAttachment = uuid === '0000200a-3dd4-4255-8d62-6dc7b9bd5561';
        const isStatusForControl = uuid === '00002020-3dd4-4255-8d62-6dc7b9bd5561';
        const isControlPointForControl = uuid === '00002021-3dd4-4255-8d62-6dc7b9bd5561';
        // **0x2008：官方在"已注册"会话里订阅的第 5 个特征，我们一直漏了。**
        //
        // 实测官方已注册会话（安卓 logcat 19:59:36）的订阅顺序是**五个**：
        //   0x2008 → 0x200A → 0x2000 → 0x2020 → 0x2021
        // 而 `0x2008` 随后被"**读两次 + 写一次**"，位置正好夹在固件
        // （`0x2A26`）读取和电源（`0x2001`）读取之间——也就是**紧挨着拉起热点的
        // `0x2005` 之前**。
        //
        // 我们此前只订 4 个（`0x2000` 由 armAuthCharacteristic 单独负责），
        // 所以既收不到 `0x2008` 的任何回应，也从不参与这段交互。
        const isLocationInformation = uuid === '00002008-3dd4-4255-8d62-6dc7b9bd5561';
        if (!isCableAttachment && !isStatusForControl && !isControlPointForControl
          && !isLocationInformation) {
          continue;
        }
        const properties = characteristic.properties;
        if (properties === undefined) {
          continue;
        }
        try {
          // 0x200A 官方用 notification，0x2020 / 0x2021 官方用 indication。
          // 0x2008 与 0x200A 同类（官方对两者都用通用的
          // setCharacteristicNotification），所以走 notification。
          if (isCableAttachment || isLocationInformation) {
            await gatt.setCharacteristicChangeNotification(characteristic, true);
          } else {
            await gatt.setCharacteristicChangeIndication(characteristic, true);
          }
          armed++;
          trace.push('Nikon subscribed to ' + characteristic.characteristicUuid);
        } catch (error) {
          trace.push('Nikon subscribe failed for ' + characteristic.characteristicUuid + ': ' +
            NikonBleProvisioning.describeError(error));
        }
      }
    }
    trace.push('Nikon subscribed to ' + armed + ' notification characteristic(s) '
      + '(the official client arms exactly 0x200A + 0x2000 + 0x2020 + 0x2021)');
  }

  /** 唤醒深睡眠中的相机（`0x2001` POWER_CONTROL）。
   *
   * 官方状态机里的 `BLE_DEEP_SLEEP_WAIT`（"等待相机从深睡眠唤醒"）对应的就是这一步：
   * 手机写 `WAKE_WAIT`，相机醒来后把该特征置为 `VALID_WAKE`。
   *
   * 载荷是 1 字节，从官方序列化器 `d0.a(BlePowerControlData;)[B` 的字节码读出——
   * `ByteBuffer.allocate(1)` + LITTLE_ENDIAN + `put(Types.getByte())`，没有别的字段。
   * 枚举值（`BlePowerControlData$Types` 的常量表）：
   * `UNDEFINED=-1`、`STOP=0`、`WAKE_WAIT=1`、`INVALID_WAKE=2`、`VALID_WAKE=3`。
   *
   * 这是整条蓝牙路线里我们从没碰过的一步，而设备确实暴露了 `2001` (read+write)。
   * 相机屏幕停在「等待配对」而不完成，最合理的解释就是它处于深睡眠、还没被叫醒。
   */
  private static async wakeCamera(gatt: ble.GattClientDevice,
    services: ble.GattService[], trace: string[]): Promise<void> {
    const characteristic = NikonBleProvisioning.findCharacteristic(services,
      NikonCameraService.POWER_CONTROL_CHARACTERISTIC);
    if (!characteristic) {
      trace.push('Nikon power control characteristic 0x2001 not present');
      return;
    }
    try {
      await LumixImportPrototype.writeGatt(gatt, characteristic, new Uint8Array([1]), trace);
      trace.push('Nikon WAKE_WAIT written to 0x2001');
    } catch (error) {
      trace.push('Nikon WAKE_WAIT on 0x2001 failed: ' +
        NikonBleProvisioning.describeError(error));
      return;
    }
    // 醒来之后相机把 0x2001 读回 VALID_WAKE(3)。轮询读回，读到就算唤醒完成。
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      await NikonBleProvisioning.delay(500);
      let value = -1;
      try {
        const raw = new Uint8Array(
          await LumixImportPrototype.readGatt(gatt, characteristic, trace));
        if (raw.length > 0) value = raw[0];
      } catch (error) {
        trace.push('Nikon 0x2001 read failed: ' + NikonBleProvisioning.describeError(error));
        return;
      }
      trace.push('Nikon 0x2001 power control=' + value);
      if (value === 3) {
        trace.push('Nikon camera reports VALID_WAKE');
        return;
      }
    }
    trace.push('Nikon camera did not report VALID_WAKE within 10s');
  }

  /** `pairing end` 之后的收尾读取：0x200B / 0x2A26 / 0x2009 ×3。
   *
   * 官方日志里的标签分别是 `P`（read lss serial number string）、`p`（read
   * firmware revision string）、`N`（read lss feature，**连读三次**）。这三步在
   * 官方流程里全部发生在 disconnect **之前**，而我们一直漏掉了整段。
   *
   * 0x2009 LSS_FEATURE 连读三次是为了取全相机宣告的能力位。能力位在配对前后会
   * 翻转，这是判断"相机是否已经认下这条配对"最直接的依据：
   *   配对前：hasQuickWakeUp=false  isBtcCoopWait=false
   *   配对后：hasQuickWakeUp=true   isBtcCoopWait=true
   *
   * 全部尽力而为：特征不存在或读失败都只记日志，不中断后续流程。 */
  private static async readCameraInfo(gatt: ble.GattClientDevice,
    services: ble.GattService[], trace: string[]): Promise<void> {
    const uuids: string[] = [
      '0000200B-3DD4-4255-8D62-6DC7B9BD5561',
      '00002A19-0000-1000-8000-00805F9B34FB',
      '00002A26-0000-1000-8000-00805F9B34FB',
      '00002009-3DD4-4255-8D62-6DC7B9BD5561',
      '00002009-3DD4-4255-8D62-6DC7B9BD5561',
      '00002009-3DD4-4255-8D62-6DC7B9BD5561',
      '00002008-3DD4-4255-8D62-6DC7B9BD5561',
      '00002008-3DD4-4255-8D62-6DC7B9BD5561'
    ];
    const labels: string[] = [
      'lss serial number string',
      'battery level (2A19)',
      'firmware revision string',
      'lss feature', 'lss feature', 'lss feature',
      'location information (0x2008) read #1',
      'location information (0x2008) read #2'
    ];
    for (let index = 0; index < uuids.length; index++) {
      const characteristic = NikonBleProvisioning.findCharacteristic(services, uuids[index]);
      if (!characteristic) {
        trace.push('Nikon ' + labels[index] + ': characteristic ' + uuids[index] +
          ' not present on this camera');
        continue;
      }
      try {
        const raw = new Uint8Array(
          await LumixImportPrototype.readGatt(gatt, characteristic, trace));
        // **把原始字节和位串打全。**
        //
        // 之前这里只打 `len=4`，值没留下——于是"0x2009 在配对前后会不会翻转"
        // 这个关键判据一直没法用我们自己的数据验证，只能靠官方安卓端的日志。
        //
        // 现在每个字节 + 完整位串都记下来：在"相机认我们"和"相机侧已删配对"
        // 两种状态下各跑一次，直接 diff 就能确定到底哪一位在变。
        let hexValue = '';
        let bitValue = '';
        for (let byteIndex = 0; byteIndex < raw.length; byteIndex++) {
          hexValue += raw[byteIndex].toString(16).padStart(2, '0');
          bitValue += raw[byteIndex].toString(2).padStart(8, '0');
        }
        trace.push('Nikon ' + labels[index] + ' [' + (index + 1) + '/' + uuids.length +
          '] len=' + raw.length + ' hex=' + hexValue + ' bits=' + bitValue);
        if (labels[index] === 'lss feature') {
          // 单独一行、固定前缀，方便在两次日志之间直接对比（grep 这一行即可）。
          trace.push('Nikon LSS FEATURE VERDICT #' + (index - 1) + ' hex=' + hexValue
            + ' bits=' + bitValue
            + '  <- 对比这一行：相机认我们 vs 相机侧已删配对');
        }
      } catch (error) {
        trace.push('Nikon ' + labels[index] + ' read failed: ' +
          NikonBleProvisioning.describeError(error));
      }
    }
  }

  /** 报给相机的客户端名称（`0x2002` CLIENT_DEVICE_NAME）。
   *
   * **这个名字必须同时是手机自己的经典蓝牙名。** 相机的配对方式是"搜索手机、凭
   * 名字认出来"，而它认的就是我们从 `0x2002` 报过去的那个字符串；如果手机在经典
   * 蓝牙里广播的是另一个名字（实测是「单哥啊」），相机搜到也对不上，于是永远不
   * 发起连接，RFCOMM 监听就一直空等。
   *
   * 官方客户端报的 `Android_WEB-W00_8061` 正是那台安卓手机自己的蓝牙名——不是
   * 随手起的，也印证了"报给相机的名字必须等于自己广播的名字"。
   *
   * 所以这里只定义一次，写入 `0x2002` 和 `setLocalName` 两处都取它，避免再次漂移。 */
  private static readonly CLIENT_DEVICE_NAME: string = 'Pixelshop';

  /** 在进度里打一个带序号的步骤标记。
   *
   * 整条配对链路实测要 60 秒以上（光是经典搜索那一轮就可能 36 秒），而之前进度里
   * 只有零散的技术日志，用户看不出"到哪一步了、还剩几步"，就会以为卡死。
   *
   * 固定格式 `Nikon step N/M 描述`——界面可以据此直接画进度条，不必解析技术日志。
   * 序号只为让用户看清进度，不影响任何流程逻辑。 */
  private static step(trace: string[], index: number, total: number, text: string): void {
    trace.push('Nikon step ' + index + '/' + total + ' ' + text);
  }

  /** 相机通过 LSS 认证通知发来的配对码（见 `harvestCameraPin`）。
   *
   * 系统做**传统 PIN 配对**时会在 `pinRequired` 里向我们索要 PIN，而这个码就是
   * 相机自己给的那一个。之前我们收到它只记进日志就丢掉了，配对因此永远停在半路。 */
  private static cameraPin: string = '';

  /** 相机通过 `0x2003` 自报的名字（实测 `"Z_5_8073573"`）。
   *
   * 这是**通用**判据：相机在系统蓝牙列表里显示的名字就是它自己报的这个字符串。
   * 所以"从已绑定记录里认出这台相机"可以直接精确匹配，不必按机型、品牌或命名
   * 习惯写死——换任何相机都成立。 */
  private static cameraReportedName: string = '';

  /** 标准串口服务（Serial Port Profile）UUID。
   *
   * 反编译官方 APK 后在 `const-string` 里找到它出现 3 次，是经典蓝牙那一段用的
   * 唯一 UUID；官方日志里 `bindlisten ... rfcomm channel: 7` 就是把它注册成
   * SDP 记录之后系统分配到的频道号。相机通过 SDP 查这个 UUID 拿到频道号，所以
   * 手机这边必须用同一个 UUID 才能被相机找到。 */
  private static readonly SPP_UUID: string = '00001101-0000-1000-8000-00805F9B34FB';
  private static btcServerSocket: number = -1;
  /** 相机连进来的那条 RFCOMM 链路。**必须留引用**：它是一条活着的蓝牙链路，
   * 只要不关，相机就不会开 Wi-Fi 热点（用户实测：退出 App、进程一死热点立刻出现）。 */
  private static btcClientSocket: number = -1;
  /** `sppListen` / `sppAccept` 是**异步**回调。实测它们的回调会晚于 `closeBtc()`
   * 才到达：那一刻 `btcServerSocket` 还是 -1，于是"释放"什么都没关，监听却在
   * 释放之后挂了起来——蓝牙继续占着，相机照样不开热点。
   * 这个闸门一旦置位，迟到的回调必须**把自己刚拿到的 socket 立刻关掉**。 */
  private static btcClosed: boolean = false;

  /** 从相机通知里拣出配对码。
   *
   * 实测 `0x2000` 认证通知的载荷（17 字节）尾部是 ASCII `-303351`，前面是会话
   * 状态字节。这里做最保守的提取：从末尾往前取数字串，允许一个前导 `-`；
   * 长度不在 4–8 之间就什么都不做——绝不因为解析失败干扰正常流程。 */
  private static harvestCameraPin(bytes: Uint8Array, trace: string[]): void {
    let tail = '';
    for (let index = bytes.length - 1; index >= 0; index--) {
      const value = bytes[index];
      if (value === 0 && tail.length === 0) {
        continue;
      }
      if (value >= 48 && value <= 57) {
        tail = String.fromCharCode(value) + tail;
        continue;
      }
      break;
    }
    if (tail.length >= 4 && tail.length <= 8) {
      NikonBleProvisioning.cameraPin = tail;
      // **这里拿到的东西不是配对码。**
      //
      // 曾经把它当成配对码显示到界面上，是错的。真机日志（10-16 19:50 成功那次）
      // 把两者并排摆在一起，一眼就能看出不是一个东西：
      //   相机 `0x2000` 通知尾部        → 303351
      //   系统 `pinRequired` 给出的码   → 216182  ← 真正在相机屏幕上显示、用户确认的
      //   `bonded … passkey=`           → 216182
      //
      // 而且通知原文是 `0400000000000000002d33303333353100`，末尾是 **`-303351`**，
      // 带负号——这是 LSS 侧的数值，不是六位配对码。
      //
      // 真正的配对码只来自 `pinRequired`（`pinType=2`，即 ENTER_PASSKEY）：系统生成、
      // 交给我们、我们原样确认回系统，相机上显示同一个码由用户点 OK。见
      // `onPinRequired` 里对 `nikonPairCode` 的写入。
      trace.push('Nikon LSS notification tail value (NOT the pairing code): ' + tail);
    }
  }

  /** 判断 BLE 地址类型（蓝牙 Core 规范：地址最高字节的高两位）。
   *
   * 相机的广播地址**每次配对会话都在变**，实测三种类型都出现过，而能不能绑定完全
   * 取决于这两位——这是几十轮失败里一直没被记录下来的一个变量：
   *   `00` 不可解析私有地址 NRPA —— 一次性，绑了必然从 BONDING(1) 回滚 NONE(0)
   *   `01` 可解析私有地址 RPA   —— 需要 IRK 才能解析，第三方同样绑不上
   *   `11` 静态随机地址         —— **可以绑定**
   *
   * 把它打进日志，就能一眼看出这一轮到底有没有机会成功，不必再靠猜。 */
  private static describeAddressType(address: string): string {
    const value = parseInt(address.slice(0, 2), 16);
    if (isNaN(value)) {
      return 'unknown (unparsable "' + address.slice(0, 2) + '")';
    }
    const kind = value >> 6;
    if (kind === 0) {
      return 'NRPA non-resolvable private (00) - one-shot, cannot be bonded';
    }
    if (kind === 1) {
      return 'RPA resolvable private (01) - needs the IRK, cannot be bonded by us';
    }
    if (kind === 2) {
      return 'reserved (10)';
    }
    return 'static random (11) - bondable';
  }

  /** 开一个 RFCOMM 服务端，等**相机连进来**（对应官方日志里的 `bindlisten`）。
   *
   * 这是整条链路上我们之前搞错方向最严重的一处：我们一直在用
   * `connection.startBluetoothDiscovery()` 搜索经典蓝牙，而官方从不搜索——它
   * 开监听，相机主动连入。相机因此在我们历次的搜索结果里一次都没出现过。
   *
   * `secure: true` 表示要求已认证的链路，这样相机连入时若还没有绑定，协议栈会
   * 自己发起配对（系统数字比对弹窗），不需要应用调 `pairDevice`。 */
  private static openBtcListener(trace: string[]): void {
    NikonBleProvisioning.btcClosed = false;
    if (NikonBleProvisioning.btcServerSocket >= 0) {
      trace.push('Nikon BTC listener already open id=' + NikonBleProvisioning.btcServerSocket);
      return;
    }
    // 让手机**可被发现**。这是整条链路上一直漏掉的一环，也是所有现象的解释。
    //
    // 相机不等手机来连它，而是**自己去搜索手机**——凭的就是我们写进 0x2002 的
    // 客户端名称。官方的名字是 `Android_<机型>_<编号>`，我们的是 `HOS Pixelshop`，
    // 共同点是**唯一可辨**：相机要在一堆设备里认出哪个才是配对的发起方。这也解释了
    // 为什么官方的名字带机型还带一串数字，而不是简单的手机蓝牙名。
    //
    // 之前手机从没设过可被发现模式，相机搜不到它，于是：RFCOMM 监听空等、相机不
    // 出码、系统弹窗不出现、绑定永远不发生。而我们去绑广播地址（最高两位为 00、
    // 每次运行都在变的不可解析私有地址 NRPA）必然从 BONDING(1) 回滚到 NONE(0)——
    // 方向从一开始就反了。
    //
    // 相机连进来时走的是 `secure: true` 的 RFCOMM，链路需要认证，于是协议栈自己
    // 发起 SSP 数字比对：手机弹窗出码、相机也出码、两边确认——正是实测看到的那个
    // 流程，而且全程不需要应用调 pairDevice。
    // 改名和"可被发现"是**两件独立的事，必须各做各的 try**。
    //
    // 上一版把它们写在同一个 try 里，结果 `setLocalName` 抛异常（本机不支持，
    // 801 Capability is not supported）直接把"可被发现"也跳过了——比改之前还退
    // 一步，连被搜到都做不到。这类"顺带跳过"的写法代价太大，拆开。
    try {
      connection.setLocalName(NikonBleProvisioning.CLIENT_DEVICE_NAME);
      trace.push('Nikon BTC local Bluetooth name set to "' +
        NikonBleProvisioning.CLIENT_DEVICE_NAME + '"');
    } catch (error) {
      trace.push('Nikon BTC setLocalName not supported on this device: ' +
        NikonBleProvisioning.describeError(error) +
        ' — the name reported to the camera will follow the system name instead');
    }
    try {
      connection.setBluetoothScanMode(
        connection.ScanMode.SCAN_MODE_CONNECTABLE_GENERAL_DISCOVERABLE, 0);
      let localName = '';
      try {
        localName = connection.getLocalName();
      } catch (_error) {
        localName = '';
      }
      trace.push('Nikon BTC the phone is now discoverable as "' + localName +
        '"; the camera finds it by exactly this name, so 0x2002 must carry it too');
    } catch (error) {
      trace.push('Nikon BTC setBluetoothScanMode failed: ' +
        NikonBleProvisioning.describeError(error));
    }
    const options: socket.SppOptions = {
      uuid: NikonBleProvisioning.SPP_UUID,
      secure: true,
      type: socket.SppType.SPP_RFCOMM
    };
    try {
      socket.sppListen('VIVID', options, (error: BusinessError, serverSocket: number): void => {
        if (error) {
          trace.push('Nikon BTC sppListen failed: code=' + error.code + ' message=' + error.message);
          return;
        }
        NikonBleProvisioning.btcServerSocket = serverSocket;
        trace.push('Nikon BTC RFCOMM server listening id=' + serverSocket +
          ' uuid=' + NikonBleProvisioning.SPP_UUID + ' (equivalent of the official bindlisten)');
        if (NikonBleProvisioning.btcClosed) {
          // 回调迟到：closeBtc() 已经跑过，它当时看不到这个 id。就地关掉，
          // 否则这条监听会一直占着蓝牙，相机永远不开热点。
          try {
            socket.sppCloseServerSocket(serverSocket);
            NikonBleProvisioning.btcServerSocket = -1;
            trace.push('Nikon BTC late sppListen callback closed id=' + serverSocket +
              ' (Bluetooth had already been released)');
          } catch (error) {
            trace.push('Nikon BTC late sppListen close failed: ' +
              NikonBleProvisioning.describeError(error));
          }
          return;
        }
        socket.sppAccept(serverSocket, (acceptError: BusinessError, clientSocket: number): void => {
          if (acceptError) {
            trace.push('Nikon BTC sppAccept failed: code=' + acceptError.code +
              ' message=' + acceptError.message);
            return;
          }
          if (NikonBleProvisioning.btcClosed) {
            try {
              socket.sppCloseClientSocket(clientSocket);
              trace.push('Nikon BTC late sppAccept callback closed id=' + clientSocket +
                ' (Bluetooth had already been released)');
            } catch (error) {
              trace.push('Nikon BTC late sppAccept close failed: ' +
                NikonBleProvisioning.describeError(error));
            }
            return;
          }
          NikonBleProvisioning.btcClientSocket = clientSocket;
          let peer = '';
          try {
            peer = socket.getDeviceId(clientSocket);
          } catch (_error) {
            peer = '';
          }
          trace.push('Nikon BTC camera connected over RFCOMM clientSocket=' + clientSocket +
            ' peer=' + peer);
        });
      });
    } catch (error) {
      trace.push('Nikon BTC sppListen threw: ' + NikonBleProvisioning.describeError(error));
    }
  }

  /** 等**相机主动连进我们的 RFCOMM 监听**，最多 `timeoutMs`。
   *
   * 这一步不能省，它是"相机开热点"的触发条件。官方的真实顺序是：
   *
   *     写 0x2005 = [1]  →  bindlisten rfcomm channel 7  →  **相机连入**  →
   *     链路结束  →  相机把 Wi-Fi 热点挂出来
   *
   * 我们之前的顺序缺了中间那一环：`sppListen` 是异步的，监听句柄在流程已经走到
   * "释放蓝牙"之后才挂起来，于是刚拿到就被关掉，**相机一次都没连进来过**，
   * 热点自然也不出现。用户观察到的"退出 App 热点立刻出现"，正是因为进程结束时
   * 监听还在、相机已经连上过（或被拒绝后重试），随后链路断开触发了热点。
   *
   * 返回是否等到了相机。超时不抛异常——热点仍可能在断开后出现，所以调用方
   * 照常往下走。 */
  private static async waitForBtcPeer(timeoutMs: number, trace: string[]): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    let announced = false;
    while (Date.now() < deadline) {
      if (NikonBleProvisioning.btcClientSocket >= 0) {
        trace.push('Nikon BTC camera is on the RFCOMM link (id=' +
          NikonBleProvisioning.btcClientSocket + '); releasing Bluetooth now so the '
          + 'camera raises its access point');
        return true;
      }
      // 监听句柄自己也是异步出现的，等它的过程中顺带报一次，便于对照官方时序。
      if (!announced && NikonBleProvisioning.btcServerSocket >= 0) {
        trace.push('Nikon BTC RFCOMM listener is up id=' +
          NikonBleProvisioning.btcServerSocket + ', waiting for the camera to dial in');
        announced = true;
      }
      await LumixImportPrototype.delay(500);
    }
    trace.push('Nikon BTC no camera connection within ' + timeoutMs +
      ' ms; releasing Bluetooth anyway in case the bare disconnect is the trigger');
    return false;
  }

  /** **彻底放开蓝牙**，让相机去开 Wi-Fi 热点。
   *
   * 这是整条链路上最后一个、也是最关键的一个开关。用户现场观察：
   * 点「图片传输」后热点一直不出现，**一退出 App**（进程结束、系统把该进程的
   * 所有蓝牙资源一起回收）**热点立刻出现并保持**。
   *
   * 之前只关了 GATT，另外两样仍然活着：
   *
   *   1. `sppAccept` 拿到的 `clientSocket` —— **相机自己连进来的那条 RFCOMM 链路**。
   *      它是实打实的双向连接，只是我们从来没存引用、也就从来没关过。
   *   2. `sppListen` 的服务端 socket 与「可被发现」模式。
   *
   * 相机同一时刻只能跑一路无线：蓝牙链路还在，它就不开 Wi-Fi。所以必须在扫描
   * 热点**之前**把这三样（GATT + RFCOMM 客户端 + RFCOMM 服务端）全部关掉，
   * 并且退出可被发现模式。 */
  private static closeBtc(trace: string[]): void {
    // 先置闸门再关 socket：晚到的 sppListen/sppAccept 回调会在自己的回调里
    // 看到它，从而就地关掉刚拿到的句柄。
    NikonBleProvisioning.btcClosed = true;
    if (NikonBleProvisioning.btcClientSocket >= 0) {
      try {
        socket.sppCloseClientSocket(NikonBleProvisioning.btcClientSocket);
        trace.push('Nikon BTC camera RFCOMM link closed id=' +
          NikonBleProvisioning.btcClientSocket);
      } catch (error) {
        trace.push('Nikon BTC sppCloseClientSocket failed: ' +
          NikonBleProvisioning.describeError(error));
      }
      NikonBleProvisioning.btcClientSocket = -1;
    }
    if (NikonBleProvisioning.btcServerSocket >= 0) {
      try {
        socket.sppCloseServerSocket(NikonBleProvisioning.btcServerSocket);
        trace.push('Nikon BTC RFCOMM server socket closed id=' +
          NikonBleProvisioning.btcServerSocket);
      } catch (error) {
        trace.push('Nikon BTC sppCloseServerSocket failed: ' +
          NikonBleProvisioning.describeError(error));
      }
      NikonBleProvisioning.btcServerSocket = -1;
    }
    try {
      connection.setBluetoothScanMode(connection.ScanMode.SCAN_MODE_NONE, 0);
      trace.push('Nikon BTC left discoverable mode so the camera stops looking for us');
    } catch (error) {
      trace.push('Nikon BTC reset scan mode failed: ' +
        NikonBleProvisioning.describeError(error));
    }
  }

  /** 配对的收尾：系统级蓝牙配对，处理**数字比对/通行码**。
   *
   * 用户的实测把这一步讲清楚了：配对过程中**相机给出一个码**，手机上要确认两边
   * 一致，一致之后**在相机上点确认**。
   *
   * 这个码不走 GATT。它是蓝牙配对握手的数字比对值，由系统通过 `pinRequired`
   * 回调交给应用；相机那边等的正是这次确认。之前我们直接调 `pairDevice` 就撒手
   * 不管了——系统配对框弹出来了、相机也在等，但没有人去读那个码、更没有人回确认，
   * 握手就停在半路，相机因此一直停在「等待配对」。这也解释了为什么相机在 BLE 上
   * 从此完全沉默：它在等的根本不是 GATT 层的东西。
   *
   * 位置同样重要：报告的状态机把 BTC 绑定排在**最后**一段。早前把它放在流程开头
   * 试过一次，相机直接报「无法连接」并退出配对模式——顺序错了。
   */
  private static async bondWithPasskey(deviceId: string, trace: string[],
    preferredClassic: string): Promise<boolean> {
    let passkey = '';
    const onPinRequired = (param: connection.PinRequiredParam): void => {
      passkey = param.pinCode;
      // **把回调的全部内容打出来。** 系统实际配对的身份地址很可能就在这里面。
      //
      // 实测 `param.deviceId` 给的是广播地址 `22:D6:1C:F0:0C:F5`，而协议栈构建
      // 配对对话框用的是另一个身份地址 `CD:95:xx:xx:xx:D0`，且用的是默认全零 PIN：
      //   bt_service_dialog_pair: (BuildStartCommand) address: CD:95:...:D0,
      //                           pinCode: 00***0, pinType: 3
      //   bt_service_classic_adapter: (SetDevicePin) pincode:30***1   ← 我们的码
      // 我们那个正确的随机码因此交给了错误的地址，相机收到的是 PIN=000000，
      // 于是 AUTH_FAILURE。所以要找的就是"系统实际在配对的那个地址"。
      let raw = '';
      try {
        raw = JSON.stringify(param);
      } catch (error) {
        raw = '(not serializable)';
      }
      trace.push('Nikon BTC pinRequired deviceId=' + param.deviceId +
        ' pinCode=' + param.pinCode + ' raw=' + raw);
      trace.push('Nikon BTC passkey from the camera=' + param.pinCode +
        ' device=' + param.deviceId);
      // **把 PIN 交回去。** 系统正在做的是传统 PIN 配对，而 `pinRequired` 就是在
      // 向应用索要 PIN。之前我们只把码记进日志就撒手不管，配对因此永远停在半路，
      // 相机那边也就一直停在「等待配对」。
      //
      // 关键区别：`setDevicePinCode` 只需要 ohos.permission.ACCESS_BLUETOOTH，
      // 不像 `setDevicePairingConfirmation` 还要系统级的 MANAGE_BLUETOOTH
      // （那个实测恒返回 201）。也就是说这个 API 我们是**有权限**用的，
      // 而它一次都没被调用过——这才是"没有 MANAGE_BLUETOOTH 就没法确认配对"
      // 这个结论的真正漏洞。
      //
      // **码是系统给的，不是相机给的。**
      //
      // 这里原来写着"PIN 来自相机自己：它在 LSS 认证通知里把码发给了我们（实测
      // ASCII "-303351"）"——**那是错的**。10-16 成功那次的日志把两者并排摊开了：
      //   相机 `0x2000` 通知尾部      → 303351   （带负号：`-303351`，是 LSS 数值）
      //   系统 `pinRequired.pinCode`  → 216182   ← 真正的配对码
      //   `bonded … passkey=`         → 216182
      // 两者毫无关系。配对码由系统生成，`pinRequired` 把它交给应用，应用再交回去
      // （或者像 `pinType=2` 那样，留给用户在系统弹窗里确认）。
      //
      // **按弹窗类型分流。**
      //
      // 实测相机这边会出两次配对请求，形态完全不同：
      //   第一次  pinType=3（PIN 输入）+ pinCode=0 —— 来自 BLE 广播地址，那个地址
      //           每轮都在换、根本绑不成。**但用户观察到一个关键副作用：只有发起过
      //           这一次，相机的经典侧才会出现在系统蓝牙列表里。** 所以它虽绑不成，
      //           却是必须走的一步。
      //   第二次  pinType=2（确认比对）+ 真实比对码（如 384678）—— 来自经典地址，
      //           这才是能绑成的那一次。
      //
      // 所以：**第一次由 App 直接确认**，不让用户去处理那个没有意义的框；**第二次
      // 留给系统弹窗**，由用户核对码后确认。这也正是用户提出的分流方式。
      // 注意：`PinRequiredParam` 的**类型定义里没有 `pinType`**（ArkTS 直接取属性会
      // 编译报错），但运行时它确实带着这个字段——`raw` 里能看到 `"pinType":2`。
      // 所以只能从序列化结果判断，不能在类型上取。
      if (raw.indexOf('"pinType":2') >= 0) {
        // **这个码就是系统正在用的那个配对码，把它摆到界面上。**
        //
        // 用户描述的实际流程是：手机连上相机 → 手机这边出一个码 → 用户点配对 →
        // 码转发给相机 → 相机屏幕显示同一个码，用户在相机上点 OK。所以这里既不能
        // 替用户确认，也不能把这个码藏起来——它是用户唯一能用来核对的东西。
        //
        // 注意它**不是**相机 `0x2000` 通知尾部那个值（那是个带负号的 LSS 数值，
        // 例如 `-303351`，与配对码无关）。
        try {
          AppStorage.setOrCreate('nikonPairCode', param.pinCode);
        } catch (_storageError) {
        }
        NikonBleProvisioning.step(trace, 9, 9,
          '请在系统弹窗中核对配对码 ' + param.pinCode + ' 并确认（相机屏幕上也会显示同一个码）');
        return;
      }
      try {
        connection.setDevicePairingConfirmation(param.deviceId, true);
        trace.push('Nikon BTC first dialog auto-confirmed for ' + param.deviceId +
          ' (not pinType=2) so the camera exposes its Classic side');
        return;
      } catch (error) {
        trace.push('Nikon BTC setDevicePairingConfirmation rejected (' +
          NikonBleProvisioning.describeError(error) + '); falling back to the PIN');
      }
      const pin = NikonBleProvisioning.cameraPin;
      if (pin.length > 0) {
        try {
          connection.setDevicePinCode(param.deviceId, pin);
          trace.push('Nikon BTC PIN submitted to the system: ' + pin +
            ' (harvested from the camera LSS notification)');
        } catch (error) {
          trace.push('Nikon BTC setDevicePinCode failed: ' +
            NikonBleProvisioning.describeError(error));
        }
      } else {
        trace.push('Nikon BTC no PIN harvested from the camera; '
          + 'leaving confirmation to the system dialog');
      }
      // 这里**仍然不调用** connection.setDevicePairingConfirmation。
      //
      // SDK 里那个 API 的权限标注是：
      //   @permission ohos.permission.ACCESS_BLUETOOTH and ohos.permission.MANAGE_BLUETOOTH
      // MANAGE_BLUETOOTH 是系统应用权限，普通应用永远拿不到——实测调用返回
      // `BussinessError 201: Permission denied`，而且这次失败的调用会让数字比对
      // 超时，绑定随即从 BONDING(11) 回滚到 NONE(10)。
      //
      // 确认只能由系统配对弹窗（BluetoothPairingDialog）完成，那正是官方 App 的
      // 做法：它同样把用户送进系统对话框。所以这里只把码记下来、交给界面提示用户，
      // 不再代劳。
      trace.push('Nikon BTC confirmation must be done in the system pairing dialog ' +
        '(MANAGE_BLUETOOTH is a system-only permission)');
    };
    const onBondState = (data: connection.BondStateParam): void => {
      trace.push('Nikon BTC bond state device=' + data.deviceId + ' state=' + data.state);
    };
    try {
      connection.on('pinRequired', onPinRequired);
      connection.on('bondStateChange', onBondState);
    } catch (error) {
      trace.push('Nikon BTC pairing listener registration failed: ' +
        NikonBleProvisioning.describeError(error));
    }
    // 关掉 BLE 链路，然后**开一个 RFCOMM 服务端**等相机连进来。
    //
    // 官方客户端的插桩日志给出了答案（见 tmp/nikon-official-ble-flow.md）：
    //   I/BluetoothSocket: bindlisten add: ... mType:1, rfcomm channel: 7
    // 它**从不搜索经典蓝牙**——整个会话里没有一次 startDiscovery——而是作为
    // RFCOMM 服务端监听，由**相机主动连入**。这就是我们历次 startBluetoothDiscovery
    // 都找不到相机的原因：相机不做经典广播，它在等手机开监听。历次结果 23/24/25
    // 个设备全是笔记本、信标、打印机，相机一次都没出现过。
    //
    // UUID 用标准串口服务 00001101-0000-1000-8000-00805F9B34FB（反编译代码里出现
    // 3 次的那个），相机通过 SDP 查到频道号（官方那边系统分配的是频道 7）。
    // **在放开 BLE 之前**先搜一次经典蓝牙。
    //
    // 之前我们总是在 release() 之后才搜，而那一刻相机已经脱离了配对状态，经典侧
    // 也不再响应 inquiry——所以历次搜索都是 23/24/25 个无关设备，相机一次都没出现
    // （而当时还只按名字过滤，等于双重漏掉）。现在相机仍停在 LSS 配对会话里
    // （「等待配对」还亮着），这才是它最可能被搜到的时刻。
    //
    // 搜索目标不再是名字，而是确切的 OUI：官方日志证明配对对象是经典地址
    // `A0:CD:F3:44:xx:AD`（`BTM_SecBond ... transport 1` → `WAIT_NUM_CONFIRM`
    // → 弹码 → `BONDED`）。RPA/NRPA 那套地址类型判断只对 BLE 地址有意义。
    // 手机侧若已记录相机的经典地址，直接拿它当目标——省掉"触发 + 搜索"那 40 秒
    // 以上。地址未知时才去搜。**注意这不是跳过配对**：下面照样会调 pairDevice，
    // 相机忘了我们时依然会真正发起配对、让用户核对码。
    let classicCamera = preferredClassic;
    await NikonBleProvisioning.release();
    trace.push('Nikon BTC: BLE link released before the classic segment');
    await NikonBleProvisioning.delay(300);
    NikonBleProvisioning.openBtcListener(trace);
    NikonBleProvisioning.step(trace, 6, 9,
      '正在通知相机进入经典配对（此时可能出现第一个系统弹窗，应用会自动确认）');
    // **每次都发起，绝不因为手机侧已有记录就跳过。**
    //
    // 关键在于这个触发打的是 **BLE 广播地址**，而相机每轮都换一个新的——所以它
    // 永远是一个"未绑定"的地址，系统每次都会真的去问相机一次。这正是"再走一遍"
    // 的着力点：手机侧有记录**不代表相机侧还认我们**（相机可能自己删了配对、
    // 恢复过出厂、或被配到别的手机上）。
    //
    // 官方客户端的做法是 removeBond → createBond，但鸿蒙公开 API 里**没有解除配对
    // 的函数**（connection 模块只有 pairDevice / getPairedDevices / getPairState /
    // setDevicePairingConfirmation），官方能删是因为它是系统签名应用。所以我们用
    // "每轮都打新地址"来达到同样的效果。
    try {
      await connection.pairDevice(deviceId);
      trace.push('Nikon BTC trigger pairDevice issued for ' + deviceId +
        ' (a fresh rotating BLE address, so the camera is always asked)');
    } catch (error) {
      trace.push('Nikon BTC trigger pairDevice rejected: ' +
        NikonBleProvisioning.describeError(error));
    }
    // 给相机一点时间把经典侧挂出来（用户实测：第一个框弹出后列表里才出现它）。
    await NikonBleProvisioning.delay(3000);
    // **每次都重新按名字找一遍相机的经典侧**，手机侧有记录也一样找。
    // **顺序：先搜，搜不到才用缓存。**
    //
    // 一度写成"缓存优先、有就不搜"，那是错的。缓存里种的是 10-16 的地址
    // `FA:62:E4:27:F2:66`，而相机的随机地址**每轮都在变**（10-18 13:04 那一轮
    // 就变成了 `64:F8:9A:D1:91:AE`）。缓存优先会让缓存里那个过期的地址挡住一次
    // 本来能成功的搜索——而这恰恰是 13:04 之后唯一还靠谱的路径。
    //
    // 所以正确顺序是：
    //   ① 搜（第 1 轮真的能找到，13:04 的日志里就找到了，只是被桶过滤丢掉了）
    //   ② 搜到 → 记住它，下次不用再搜
    //   ③ 搜不到 → 才退回缓存/手机侧已绑定的记录
    const searched = await NikonBleProvisioning.findClassicCameraByInquiry(trace, 3);
    if (searched.length > 0) {
      classicCamera = searched;
      trace.push('Nikon BTC searched classic address ' + searched
        + ' will be remembered for next time');
      await NikonBleProvisioning.rememberClassicAddress(
        NikonBleProvisioning.cameraReportedName, searched, trace);
    } else {
      const cached = NikonBleProvisioning.recallClassicAddress(
        NikonBleProvisioning.cameraReportedName);
      if (cached.length > 0) {
        classicCamera = cached;
        trace.push('Nikon BTC search found nothing; using the remembered classic '
          + 'address ' + cached + ' (it may have rotated since it was recorded)');
      } else if (classicCamera.length > 0) {
        trace.push('Nikon BTC search found nothing new; falling back to the recorded '
          + 'classic address ' + classicCamera);
      }
    }
    //
    // 官方日志的绑定发生在 BLE 会话结束**之后**（disconnect 15:22:53.654 →
    // BTM_SecBond 15:23:28.197，隔了 35 秒），说明相机的经典侧很可能是在 LSS
    // 配对阶段结束后才开放可发现性的。而用户能在系统蓝牙列表里看到并配对
    // `Z_5_8073573` —— 系统界面是**持续**扫描的，我们单轮 12 秒搜不到并不代表
    // 相机不在广播。所以这里多搜几轮，命中即停。
    // **没有经典地址就是没戏，不要退回 BLE 地址。**
    //
    // 原来的代码在搜不到时拿 BLE 广播地址去 `pairDevice`，注释里还写着
    // `expects just-works, no code dialog`——也就是说这条退路**注定不会弹配对码**。
    // 它唯一的效果是把一次明确的"没搜到"变成一次"发了请求、等 12 秒、什么都没有"，
    // 用户看到的就是"卡在等待配对码"。
    //
    // 现在直接失败返回，让上层把原因说清楚。
    const target = classicCamera;
    if (target.length === 0) {
      trace.push('Nikon BTC 未在经典蓝牙搜索里找到这台相机，无法发起经典配对。'
        + '经典配对是相机主动连回手机、由系统弹出配对码的那一步，'
        + '必须有一个可绑定的经典地址才能开始。'
        + '请在相机上确认它处于「连接至智能设备」/配对界面，'
        + '或在手机系统蓝牙里手动配对这台相机后重试。');
      return false;
    }
    trace.push('Nikon BTC bonding target=' + target
      + ' (camera Classic address, exactly as the official client does)');
    // **不要因为手机侧还有记录就跳过——这里原本就是那个 bug 的根源。**
    //
    // 原来的代码：
    //   if (getPairState(target) === BOND_STATE_BONDED) {
    //     trace.push('Nikon BTC bond already present for ' + target);
    //     return true;                     // ← 直接认定配对成功
    //   }
    //
    // 后果正是用户报的：**相机侧已经删掉配对时，我们连问都不问相机，就认定成功**，
    // 于是"配对成功"却连不上。上一轮我只删掉了外层那处判断，漏了这一处内层的，
    // 日志里 `bond already present for 92:6E:3A:43:A0:94` 就是它。
    //
    // 手机侧的状态现在**只用来打日志**，绝不作为跳过或提前返回的依据。必须继续
    // 往下走，把请求真的发给相机，由相机决定认不认。
    // 记录**进入配对段之前**手机侧的绑定状态。这不是用来跳过流程的（下面照旧把
    // 请求发给相机），而是用来事后判断"这次到底有没有真的建立新绑定"。
    //
    // 真机踩到的情形：用户**只删了相机侧的配对，手机侧的没删**。于是
    //   `pairDevice` 被系统拒掉（2900099，因为手机侧已经绑过，不需要新建）
    //   相机侧没有对应记录，所以**相机不会弹「配对成功」**
    // 用户看到的就是"直接中断了"。但流程其实走完了——BLE 段成功、凭据也读到了。
    // 这种"单侧删除"造成的不一致，从这两条信息就能确定地判出来。
    let phoneSideBondBefore = -1;
    try {
      phoneSideBondBefore = connection.getPairState(target);
      trace.push('Nikon BTC phone-side bond state for ' + target + ' = '
        + phoneSideBondBefore + ' (logged only; the camera is still asked)');
    } catch (_error) {
    }
    // 主动发起绑定，**同时**保持上面已经开好的 RFCOMM 监听。
    //
    // 这两件事不是二选一。上一版我把 pairDevice 删掉、只等相机发起，结果是绑定
    // 根本没开始：`pinRequired` 在几十轮测试里一次都没自己触发过，两边干等 60 秒。
    // 那是错误的删除。现在恢复主动发起，监听继续留着——相机若真会连进来，那条路
    // 依然能走通，两条路互不影响。
    //
    // 先判断地址类型再发。相机在配对模式下**每次会话都换地址**，实测三种类型都
    // 出现过，能不能绑完全取决于最高两位：
    //   00 → 不可解析私有地址（NRPA），一次性，绑了必然从 BONDING(1) 回滚 NONE(0)
    //   01 → 可解析私有地址（RPA），需要 IRK 才能解析，第三方同样绑不上
    //   11 → 静态随机地址，**可以绑定**
    // 之前几十轮全部失败，很可能就有一部分是抽到了 00/01 这两种不可绑的地址。
    const addressType = NikonBleProvisioning.describeAddressType(target);
    trace.push('Nikon BTC target ' + target + ' addressType=' + addressType);
    /** 系统配对流程是否真的被启动。`pairDevice` 抛异常时为 false——这时配对码
     *  不可能出现，等待循环也就没有必要给足一分钟（见下面的 waitMs）。 */
    let pairIssued = false;
    if (classicCamera.length === 0) {
      // 触发过了、也搜过了，但经典侧仍没出现。这一轮就到此为止，不再对同一个
      // BLE 地址重复发起配对（那只会再弹一次无意义的框）。
      trace.push('Nikon BTC no Classic address after the trigger; '
        + 'skipping the second pairDevice this round');
    } else {
    // **手机侧已经绑过这台相机，就不要再发起配对。**
    //
    // `pairDevice` 是"发起一次新的配对"，在已有绑定的设备上会被系统直接拒
    // （真机上就是 `2900099`），而且它拒掉之后**既不会弹配对码、也不会改变绑定
    // 状态**——用户看到的现象就是"什么都不发生，页面卡在等配对码"。
    //
    // 而手机侧已经有绑定这件事本身，就说明经典链路是通的（用户很可能是在系统
    // 蓝牙设置里手动配对成功的，那条路实测可行）。这种情况下需要的是**使用**这条
    // 链路，而不是重新建立它，所以直接跳过。
    if (phoneSideBondBefore === connection.BondState.BOND_STATE_BONDED) {
      trace.push('Nikon BTC 手机侧已绑定 ' + target + '，跳过 pairDevice 直接使用现有链路');
      pairIssued = true;
    } else {
    try {
      await connection.pairDevice(target);
      pairIssued = true;
      trace.push('Nikon BTC pairDevice issued for ' + target + ' (addressType=' +
        addressType + '); the code should now appear in the system dialog');
    } catch (error) {
      // **发起就失败了，那配对码永远不会出现**——这一步必须如实、立刻反映出去，
      // 不能靠后面那个等待循环去"等一个根本不会来的绑定"。
      //
      // 真机上见过的形状（Z 8，2026-10-18 12:23）：
      //   BTC bonding target=7A:5C:BC:EC:F4:21 (camera Classic address)
      //   BTC pairDevice rejected for 7A:5C:BC:EC:F4:21: 2900099
      //   （然后页面停在"等待相机显示配对码"，一直到超时）
      // 2900099 是框架的通用「Operation failed」，它不说明原因，但可以确定的是
      // **系统配对流程没有被启动**，所以既不会有配对码、也不会有绑定状态变化。
      trace.push('Nikon BTC pairDevice rejected for ' + target + ': ' +
        NikonBleProvisioning.describeError(error));
      // **不要把"被拒"写成"不会弹配对码"——那是错的。**
      //
      // 10-18 13:46 的日志里，同一句拒绝之后 **50 秒**，系统才通过 `pinRequired`
      // 送来配对码 761341，随后绑定成功：
      //   13:46:39.148  pairDevice rejected for 86:FE:BC:6D:2D:D5（2900099）
      //   13:47:29.757  pinRequired … pinCode=761341 pinType=2
      //   13:47:33.510  bond state = 2 (BONDED)
      // 因为发起方是**相机**：它收到 `0x2005` 后自己建立经典链路，系统随后才弹配对。
      // 之前这里写"系统配对流程没有启动，相机不会显示配对码"并停止等待，正是用户
      // 看到的"卡在第 5 步"——明明马上要成功，却被自己的提示劝退了。
      trace.push('Nikon BTC 注意：pairDevice 被拒（2900099）不等于配对没开始。'
        + '相机收到 0x2005 后会自己连回来，实测最久约 50 秒后系统才弹出配对码；'
        + '继续等待。');
    }
    }
    }
    // **`pairDevice` 返回 2900099 并不代表配对没开始。**
    //
    // 10-16 23:24 的 Z 8 成功日志里，同一句 `pairDevice rejected … 2900099` 之后
    // 7 秒，系统弹出了配对码（`pinRequired … pinCode=795224`），随后绑定成功。
    // 原因是**相机才是发起方**：它收到 `0x2005 = [1]` 后自己建立经典链路，手机侧
    // 的 `pairDevice` 只是顺带把系统配对界面唤起来。
    //
    // 所以这里一律给足等待时间，不因为 `pairDevice` 抛错就提前放弃。
    // 实测（10-18 13:46）：`pairDevice` 被拒之后 **50 秒** 配对码才到，随即绑定成功。
    // 原来的 60 秒窗口只剩 10 秒余量，稍微慢一点就会被判超时——而用户看到的就是
    // "卡在等待配对码"。这里放宽到 120 秒，并且在等待期间把提示写清楚，让用户知道
    // 此时该去看相机屏幕，而不是以为应用死了。
    const waitMs = 120000;
    NikonBleProvisioning.step(trace, 8, 9, '等待相机回连并确认配对码（最长 '
      + Math.round(waitMs / 1000) + ' 秒）：相机屏幕上出现配对码后，请在相机上点 OK');
    const deadline = Date.now() + waitMs;
    // 弹窗里的「配对相机」按钮靠这两个 AppStorage 键和服务端通信：
    //   `nikonPairActionable` 由服务端置位（进入等待阶段才允许点）
    //   `nikonPairRequest`    由弹窗写入（用户点击的时间戳）
    // 用时间戳而不是布尔值，是因为用户可能点第二次——服务端只认"变了"，不认"是 true"。
    try {
      AppStorage.setOrCreate('nikonPairActionable', true);
    } catch (_storageError) {
    }
    let lastPairRequest = NikonBleProvisioning.readNumber('nikonPairRequest');
    while (Date.now() < deadline) {
      await NikonBleProvisioning.delay(500);
      // 用户点了「配对相机」→ 立刻重新发起一次配对。
      const request = NikonBleProvisioning.readNumber('nikonPairRequest');
      if (request > lastPairRequest) {
        lastPairRequest = request;
        trace.push('Nikon BTC 用户点了「配对相机」，重新发起 pairDevice for ' + target);
        try {
          await connection.pairDevice(target);
          trace.push('Nikon BTC pairDevice re-issued for ' + target);
        } catch (error) {
          trace.push('Nikon BTC pairDevice re-issue rejected for ' + target + ': '
            + NikonBleProvisioning.describeError(error)
            + '（仍继续等待相机自己连回来）');
        }
      }
      try {
        if (connection.getPairState(target) === connection.BondState.BOND_STATE_BONDED) {
          trace.push('Nikon BTC bonded with ' + target + ' passkey=' + passkey);
          // 分清"这次真的新建了绑定"和"手机侧本来就绑着"。
          //
          // 后者意味着：手机侧有记录，但相机侧可能已经被用户删掉了。这种单侧删除
          // 的状态下，`pairDevice` 会被系统拒（无需新建），**相机也不会弹「配对
          // 成功」**——用户看到的现象就是"直接中断了"，而实际上蓝牙段是通的。
          //
          // 鸿蒙没有取消配对的 API，所以这里只能如实报告，让用户自己去系统蓝牙
          // 设置里删掉旧记录，两边一起删才能重新走一次真正的配对。
          if (phoneSideBondBefore === connection.BondState.BOND_STATE_BONDED) {
            trace.push('Nikon BTC 说明：手机侧在本次配对**之前**已经是「已绑定」状态。'
              + '若相机上没有弹出「配对成功」，说明相机侧的记录已被删除而手机侧还留着——'
              + '这是单侧删除造成的不一致。请在系统蓝牙设置里对 ' + target
              + ' 选择「取消配对 / 忽略此设备」后再试，两次要一起删。');
          }
          NikonBleProvisioning.clearPairActionable();
          return true;
        }
      } catch (_error) {
      }
    }
    NikonBleProvisioning.clearPairActionable();
    trace.push('Nikon BTC pairing did not reach BONDED within ' + Math.round(waitMs / 1000)
      + 's (target=' + target + ' passkey=' + passkey + ')');
    return false;
  }

  /** 收起弹窗里的「配对相机」按钮。绑定结束（成功或超时）后都要调，
   *  否则按钮会一直留在弹窗上，用户点了也不会有任何效果。 */
  private static clearPairActionable(): void {
    try {
      AppStorage.setOrCreate('nikonPairActionable', false);
    } catch (_storageError) {
    }
  }

  /** 官方配对的第三段（`BTC_*`）：经典蓝牙系统级绑定。
   *
   * 报告 §6.3 的状态机：`BTC_SEARCH_START → BTC_BOND_START → BTC_COMPLETE`，
   * 是配对的**最后**一段；`CameraPairingUseCase$ErrorCode` 里专门有
   * `COULD_NOT_BOND`。索尼线早就在用同一套机制（SonyBleProvisioning 的
   * ensureSystemBond），所以这里沿用它的做法：先查是否已绑定，再发起一次。
   *
   * 位置是关键。之前我在流程**开头**试过一次，相机直接显示「无法连接」并退出
   * 配对模式；按官方顺序绑定属于第三段，那次是位置放错了。现在只在第一段
   * （BLE 准入）、第二段（重连再认证）都走完之后才发起，且只发一次。
   */
  private static async requestSystemBond(deviceId: string, trace: string[]): Promise<boolean> {
    // 先做经典蓝牙搜索（官方 BTC_SEARCH_START）。这一步不能省，也不能用 BLE 的
    // 地址代替：BLE 扫描拿到的是**随机私有地址**（RPA），它不是经典蓝牙的
    // BR/EDR 硬件地址。拿 RPA 调 pairDevice 时框架既不抛异常、也不报错，只是
    // 什么都不做——实测 trace 里写着 "bond requested"、pairDevice 正常返回，而
    // 框架日志里连一条 create_bond 都没有。
    trace.push('Nikon BTC: the BLE address ' + deviceId +
      ' is a random private address and cannot carry a Classic bond');
    const discovered = await NikonBleProvisioning.searchClassicCameras(trace);
    if (discovered.length === 0) {
      trace.push('Nikon BTC classic discovery found nothing; no bond attempted');
      return false;
    }
    for (const address of discovered) {
      try {
        if (connection.getPairState(address) === connection.BondState.BOND_STATE_BONDED) {
          trace.push('Nikon BTC bond already present for ' + address);
          return true;
        }
      } catch (_error) {
      }
      let name = '';
      try {
        name = connection.getRemoteDeviceName(address);
      } catch (_error) {
        name = '';
      }
      // 经典地址上只绑名字像相机的：用户周围还有耳机、手表、车机。
      if (!NikonBleProvisioning.looksLikeNikonBleName(name)) {
        trace.push('Nikon BTC skip ' + address + ' name=' + name);
        continue;
      }
      trace.push('Nikon BTC bonding ' + address + ' name=' + name);
      try {
        await connection.pairDevice(address);
      } catch (error) {
        trace.push('Nikon BTC pairDevice rejected for ' + address + ': ' +
          NikonBleProvisioning.describeError(error));
        continue;
      }
      if (await NikonBleProvisioning.waitForBond(address, trace)) {
        trace.push('Nikon BTC bonded ' + address);
        return true;
      }
    }
    trace.push('Nikon BTC no discovered device accepted the bond');
    return false;
  }

  /** 经典蓝牙搜索，官方 `BTC_SEARCH_START` 那一步。
   *
   * 只负责把附近的经典蓝牙地址收齐并记名，不做判断。窗口是固定时长：平台没有
   * "搜索完成"的回调，只有 bluetoothDeviceFind 的增量通知。 */
  private static async searchClassicCameras(trace: string[]): Promise<string[]> {
    const found: string[] = [];
    const onFind = (devices: string[]): void => {
      for (const address of devices) {
        if (found.indexOf(address) < 0) found.push(address);
      }
    };
    try {
      connection.on('bluetoothDeviceFind', onFind);
    } catch (error) {
      trace.push('Nikon BTC discovery listener failed: ' +
        NikonBleProvisioning.describeError(error));
      return found;
    }
    // **先把可能还在跑的搜索停掉，等它真正停下再开新的。**
    //
    // 真机日志（Z 8，2026-10-18 12:28）暴露的问题：
    //   12:28:49.201  第 1/3 轮 → rejected: In DISCOVERYING or DISCOVERY_STARTED state
    //   12:28:49.201  第 2/3 轮 → rejected: 同上
    //   12:28:49.201  第 3/3 轮 → rejected: 同上
    //   12:28:49.201  inquiry exhausted 3 round(s) without finding the camera
    // 三轮挤在同一毫秒。原因是 `startBluetoothDiscovery` 一旦被拒就**立刻返回
    // 空列表**，而调用方的循环于是瞬间空转完三轮——所谓"搜了 3 轮没找到"，其实
    // **一轮都没搜**。而拒绝的起因是上一轮搜索（或应用自己的相机发现）还占着
    // 控制器的搜索状态。
    //
    // 所以：开新的一轮之前先 `stopBluetoothDiscovery`，给协议栈一点时间落地；
    // 万一还是被拒，就等一会儿重试一次，而不是空手返回。
    try {
      connection.stopBluetoothDiscovery();
    } catch (_stopError) {
    }
    await NikonBleProvisioning.delay(600);
    let started = false;
    for (let attempt = 1; attempt <= 3 && !started; attempt++) {
      try {
        connection.startBluetoothDiscovery();
        started = true;
      } catch (error) {
        const detail = NikonBleProvisioning.describeError(error);
        trace.push('Nikon BTC classic discovery rejected (attempt ' + attempt + '/3): ' + detail);
        if (attempt < 3) {
          await NikonBleProvisioning.delay(1500);
        }
      }
    }
    if (!started) {
      try {
        connection.off('bluetoothDeviceFind', onFind);
      } catch (_error) {
      }
      return found;
    }
    trace.push('Nikon BTC classic discovery started');
    await NikonBleProvisioning.delay(12000);
    try {
      connection.stopBluetoothDiscovery();
    } catch (_error) {
    }
    try {
      connection.off('bluetoothDeviceFind', onFind);
    } catch (_error) {
    }
    for (const address of found) {
      let name = '';
      try {
        name = connection.getRemoteDeviceName(address);
      } catch (_error) {
        name = '';
      }
      // 高亮"就是这台相机"的那一条。判据是**相机自报的名字**（`0x2003`，也就是系统
      // 蓝牙列表里显示的那个名字），不按 OUI、不按品牌——换任何机型都成立。
      const reported = NikonBleProvisioning.cameraReportedName;
      const isCamera = reported.length > 0 && name === reported;
      trace.push('Nikon BTC candidate ' + address + ' name=' + name +
        (isCamera ? '  <== this is the camera (matches the name it reported over LSS)' : ''));
    }
    trace.push('Nikon BTC classic discovery found ' + found.length + ' device(s)');
    return found;
  }

  /** 在经典搜索结果里按**相机自报的名字**找出它。
   *
   * 判据是相机通过 `0x2003` 报给我们的那个字符串（实测 `Z_5_8073573`）——**也就是
   * 系统蓝牙列表里显示的那个名字**。用户手动点的那条记录正是它，所以这条判据和
   * 人工操作等价，而且不按 OUI、不按品牌、不按命名习惯，换任何机型都成立。
   *
   * 名字取不到就返回空串，调用方退回 BLE 地址，不会因为这一条卡住流程。 */
  /** 读一个数值型的 AppStorage 键，读不到（或不是数字）就当 0。
   *
   *  AppStorage 是跨页面/弹窗的广播通道：弹窗写、服务端读。封装一层是为了让
   *  "键不存在"不会抛异常打断配对流程。 */
  private static readNumber(key: string): number {
    try {
      const value = AppStorage.get<number>(key);
      if (value === undefined || value === null) {
        return 0;
      }
      return value as number;
    } catch (_error) {
      return 0;
    }
  }

  /** 取相机上报名字的"型号前缀"：`Z_8_8046830` → `Z_8_`（取到第一个下划线）。
   *
   *  用它做宽松匹配：真机日志里经典侧广播的名字有时与 LSS 上报的名字不完全相等，
   *  而逐字相等一旦差一个字就整个匹配不上——搜到了也当没搜到。前缀取自相机自己
   *  上报的名字，不写死任何机型。 */
  private static namePrefix(reported: string): string {
    const at = reported.indexOf('_');
    if (at > 0 && at < reported.length - 1) {
      return reported.substring(0, at + 1);
    }
    return '';
  }

  private static findClassicCamera(candidates: string[], trace: string[],
    logged: string[] = []): string {
    const reported = NikonBleProvisioning.cameraReportedName;
    if (reported.length === 0) {
      trace.push('Nikon BTC no camera-reported name available; cannot match the classic device');
      return '';
    }
    for (const address of candidates) {
      let name = '';
      try {
        name = connection.getRemoteDeviceName(address);
      } catch (_error) {
        name = '';
      }
      // **匹配放宽到"型号前缀一致"。**
      //
      // 相机自报的名字是 `Z_8_8046830` 这种形状：`型号_序列号`。经典侧广播的名字
      // 与它一致时最理想（10-16 的日志就是逐字相等），但真机上也可能出现尾部差异，
      // 而"逐字相等"一旦差一个字就整个匹配不上——**搜到了也当没搜到**。
      //
      // 所以：要么逐字相等，要么**型号前缀**相同（`Z_8_` / `Z_5_` …，取到第一个
      // 下划线为止）。前缀取自相机自己上报的名字，不写死任何机型。
      //
      // 另外先把每个候选的名字都记下来：没有这行就判断不了"相机到底在不在搜索
      // 结果里"——10-18 13:33 那轮搜到 21 个设备却没有匹配，日志里一个名字都没有，
      // 只能靠猜。现在有名字就能一眼看出是"没搜到"还是"名字对不上"。
      //
      // `logged` 由调用方传入，用来避免"边搜边认"时每秒把同一批地址重复打一遍。
      // **但也允许重复打：名字第一次取不到（空串）、后来才取到的情况是存在的**，
      // 把空名字永久压掉会让这类设备永远匹配不上——那正是"搜到了却当没搜到"。
      // `logged` 里存的是「地址|名字」而不是单存地址：名字一开始常常取不到（空串），
      // 过一会儿才解析出来。只按地址去重会把"名字后来才出现"这种情况永久压掉，
      // 而边搜边认靠的正是这个名字。
      const logKey = address + '|' + name;
      if (logged.indexOf(logKey) < 0) {
        trace.push('Nikon BTC candidate ' + address + ' name=' + name);
        logged.push(logKey);
      }
      const prefix = NikonBleProvisioning.namePrefix(reported);
      const exact = name === reported;
      const sameModel = prefix.length > 1 && name.startsWith(prefix);
      if (exact || sameModel) {
        trace.push('Nikon BTC classic match ' + address + ' name=' + name
          + (exact ? ' (identical to the name the camera reported over LSS)'
            : ' (same model prefix "' + prefix + '" as the camera-reported name "'
              + reported + '")'));
        return address;
      }
    }
    return '';
  }

  /** 一次开到底的经典蓝牙搜索：**边搜边按名字认**，认到就立刻返回。
   *
   * 为什么不再"多轮"——10-18 13:42 的真机日志把多轮判了死刑：
   *   classic discovery found 11 device(s)          ← 第 1 轮正常跑完，没有相机
   *   rejected (attempt 1/3): In DISCOVERYING …     ← 第 2 轮开始，被拒
   *   rejected (attempt 2/3) / (attempt 3/3)        ← 第 3 轮，同样被拒
   *   … 一共 6 次拒绝
   * 也就是 `stopBluetoothDiscovery()` 并没有真的把控制器从 DISCOVERYING 状态里拉
   * 出来，于是**第一轮之后再也起不了新的一轮**。"3 轮 × 12 秒"实际只有前 12 秒
   * 是有效的。
   *
   * 而用户手机的系统蓝牙列表里**一直能看见** `Z_8_8046830`——因为系统界面是持续
   * 扫描的，相机晚一点冒出来也照样被收进去。所以这里改成同样的策略：
   *
   *   · 只 start 一次，中途绝不 stop / 重启；
   *   · 监听器一直挂着，累积所有 `bluetoothDeviceFind`；
   *   · 每秒扫一遍已累积的地址，**名字一解析出来就比对**（名字常常比地址晚到）；
   *   · 认到立即返回，不再等满整个窗口。
   *
   * `rounds` 参数保留是为了不改调用方签名，含义变成"窗口预算 = rounds × 15 秒"。 */
  private static async findClassicCameraByInquiry(trace: string[],
    rounds: number): Promise<string> {
    const budgetMs = Math.max(1, rounds) * 15000;
    const found: string[] = [];
    const logged: string[] = [];
    const onFind = (devices: string[]): void => {
      for (const address of devices) {
        if (found.indexOf(address) < 0) {
          found.push(address);
        }
      }
    };
    try {
      connection.on('bluetoothDeviceFind', onFind);
    } catch (error) {
      trace.push('Nikon BTC discovery listener failed: ' +
        NikonBleProvisioning.describeError(error));
      return '';
    }
    // 只在前置停一次：把可能还占着控制器的搜索（例如应用自己的相机发现）清掉。
    try {
      connection.stopBluetoothDiscovery();
    } catch (_stopError) {
    }
    await NikonBleProvisioning.delay(600);
    let started = false;
    for (let attempt = 1; attempt <= 3 && !started; attempt++) {
      try {
        connection.startBluetoothDiscovery();
        started = true;
      } catch (error) {
        trace.push('Nikon BTC classic discovery rejected (attempt ' + attempt + '/3): '
          + NikonBleProvisioning.describeError(error));
        if (attempt < 3) {
          await NikonBleProvisioning.delay(1500);
        }
      }
    }
    if (!started) {
      try {
        connection.off('bluetoothDeviceFind', onFind);
      } catch (_error) {
      }
      return '';
    }
    trace.push('Nikon BTC classic discovery started (single window, '
      + Math.round(budgetMs / 1000) + 's, matched incrementally)');
    NikonBleProvisioning.step(trace, 7, 9, '正在搜索相机（最多 '
      + Math.round(budgetMs / 1000) + ' 秒，搜到会立即继续；请勿关闭相机）');
    const deadline = Date.now() + budgetMs;
    let matched = '';
    let sweeps = 0;
    while (Date.now() < deadline && matched.length === 0) {
      await NikonBleProvisioning.delay(1000);
      sweeps += 1;
      matched = NikonBleProvisioning.findClassicCamera(found, trace, logged);
    }
    try {
      connection.stopBluetoothDiscovery();
    } catch (_error) {
    }
    try {
      connection.off('bluetoothDeviceFind', onFind);
    } catch (_error) {
    }
    if (matched.length > 0) {
      trace.push('Nikon BTC found the camera after ' + sweeps + ' sweep(s): ' + matched);
      return matched;
    }
    trace.push('Nikon BTC inquiry window closed after ' + Math.round(budgetMs / 1000)
      + 's with ' + found.length + ' device(s) seen and no name match for "'
      + NikonBleProvisioning.cameraReportedName + '"');
    return '';
  }

  /** 轮询绑定状态直到 BONDED 或超时：pairDevice 是异步的，返回成功只代表请求
   * 已受理。 */
  private static async waitForBond(address: string, trace: string[]): Promise<boolean> {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      try {
        if (connection.getPairState(address) === connection.BondState.BOND_STATE_BONDED) {
          return true;
        }
      } catch (_error) {
      }
      await NikonBleProvisioning.delay(500);
    }
    trace.push('Nikon BTC bond did not reach BONDED within 10s for ' + address);
    return false;
  }

  /** 官方配对的第二段（`BLE2ND_*`）：重新建立一条 BLE 连接，再认证一次。
   *
   * 报告 §6.3 的状态机里，第一段（`BLE_*`）走完之后还有：
   * `BLE2ND_FIND_CAMERA_BLE_START` → `BLE2ND_GATT_CONNECT_REQUEST` →
   * `BLE2ND_LSS_AUTHENTICATION_REQUEST`。也就是**重新找相机、重新连、再认证**。
   *
   * 两条实测证据说明这一段是必要的：
   * · 在同一条链路上做第二次认证，相机一个字都不回（等满 15 s 超时）——
   *   认证不能被重放；
   * · 第一段走完后相机立刻停止广播（释放链接后扫描 1833 个设备也没有它）。
   * 合起来看：相机收下了全部信息、进入等待状态，它等的是**一条全新的连接**。
   *
   * 尽力而为：任何一步失败都只记日志并返回 false，不影响第一段已经拿到的凭据。
   */
  private static async runSecondSegment(trace: string[], deviceId: string,
    cameraDeviceIds: Uint8Array[]): Promise<boolean> {
    // 先断开第一段的链路：相机等的就是"重连"这件事，占着旧链路它不会往下走。
    await NikonBleProvisioning.release();
    const settleMs = 2000;
    trace.push('Nikon second segment: released the first link, settling ' + settleMs + 'ms');
    await NikonBleProvisioning.delay(settleMs);

    // 相机可能已经恢复广播，也可能只在被直连时响应，两条都试。
    const rediscovered = await NikonBleProvisioning.findCamera(trace, deviceId);
    const target = rediscovered.length > 0 ? rediscovered : deviceId;
    trace.push('Nikon second segment: target=' + target + (rediscovered.length > 0
      ? ' (re-discovered on the air)'
      : ' (reusing the first-segment address)'));

    const scratch: NikonProvisionResult = {
      ok: false,
      stage: 'second',
      message: '',
      ssid: '',
      password: '',
      security: NikonLssEncryptMode.UNDEFINED,
      gateway: '',
      ipAddress: '',
    };
    try {
      const gatt = await LumixImportPrototype.connectGatt(target, trace);
      NikonBleProvisioning.activeGatt = gatt;
      // 与第一段一致：请求最大 MTU，别再把 ATT 载荷压到 61 字节。第二段也要读
      // `0x2004` 这类百字节级属性，固定 64 会强制分段读（见第一段那处的注释）。
      try {
        trace.push('Nikon second segment MTU=' + (await gatt.setBLEMtu(512)));
      } catch (_error) {
        trace.push('Nikon second segment MTU=platform default');
      }
      const services = await gatt.getServices();
      const authCharacteristic = NikonBleProvisioning.findCharacteristic(services,
        NikonCameraService.AUTHENTICATION_CHARACTERISTIC);
      if (!authCharacteristic) {
        trace.push('Nikon second segment: auth characteristic 0x2000 not present');
        return false;
      }
      const notifications: Uint8Array[] = [];
      gatt.on('BLECharacteristicChange', (changed: ble.BLECharacteristic): void => {
        const bytes = new Uint8Array(changed.characteristicValue);
        if (changed.characteristicUuid.toLowerCase() ===
          NikonCameraService.AUTHENTICATION_CHARACTERISTIC.toLowerCase()) {
          notifications.push(bytes.slice());
        }
      });
      await NikonBleProvisioning.armAuthCharacteristic(gatt, authCharacteristic, trace);
      const session = await NikonBleProvisioning.authenticate(gatt, authCharacteristic,
        notifications, cameraDeviceIds, scratch, trace);
      if (session === null) {
        trace.push('Nikon second segment authentication failed: ' + scratch.message);
        return false;
      }
      NikonBleProvisioning.lastSessionKey = session.exportSessionKey();
      trace.push('Nikon second segment authenticated (BLE2ND complete)');
      return true;
    } catch (error) {
      trace.push('Nikon second segment failed: ' + NikonBleProvisioning.describeError(error));
      return false;
    }
  }

  /** Runs the two-round LSS authentication handshake on `0x2000`.
   *
   * Returns the session on success, or null after recording the failure in
   * `result.message` and the trace.
   *
   * Extracted from `provision` because this handshake has to run **twice**. The
   * official orchestration runs authentication at the *end* of pairing Stage-1
   * (after CURRENT_TIME and DEEP_SLEEP_WAIT), but the client device name on
   * `0x2002` is only accepted once the link is authenticated — verified on the
   * body: the same write returns `-41` twice before the handshake and `0` after
   * it. So one pass runs early to unlock `0x2002`, and a second pass closes the
   * stage in the documented position. Running it more than once is normal: the
   * official second segment (`BLE2ND_*`) reconnects and re-authenticates. */
  private static async authenticate(gatt: ble.GattClientDevice,
    authCharacteristic: ble.BLECharacteristic, notifications: Uint8Array[],
    cameraDeviceIds: Uint8Array[], result: NikonProvisionResult,
    trace: string[]): Promise<NikonLssSession | null> {
    const session = new NikonLssSession();
    session.init(Date.now() & 0x7fffffff);
    const phoneNonce = session.stage1();
    if (phoneNonce === null) {
      result.message = '尼康 LSS 会话初始化失败';
      return null;
    }
    // **stage-1 帧的 `deviceId` 是手机自己的持久身份，不是相机地址。**
    //
    // 官方链条：`Base64.decode(prefs.getString("DeviceID", ""), 0)` → 8 字节 →
    // `BleConnection.connect(Context, BluetoothDevice, byte[] deviceId, …)` →
    // `lssAuthProc(deviceId)` → stage-1 帧的第三个字段。
    //
    // 主流程已经在 `provision` 里调过 `loadClientDeviceId`，这里直接取。
    const selfDeviceId = NikonBleProvisioning.clientDeviceId;
    if (selfDeviceId === null) {
      result.message = '尼康 LSS 客户端身份未初始化（持久身份读取失败）';
      NikonBleProvisioning.log(result.message);
      return null;
    }
    await LumixImportPrototype.writeGatt(gatt, authCharacteristic,
      encodeLssAuthFrame(1, phoneNonce, selfDeviceId), trace);

    const stage2Bytes = await NikonBleProvisioning.waitForNotification(notifications, trace);
    if (stage2Bytes === null) {
      result.message = '尼康 LSS 认证第 1 轮超时：相机未回应认证特征';
      NikonBleProvisioning.log(result.message);
      return null;
    }
    const stage2 = decodeLssAuthFrame(stage2Bytes);
    if (stage2 === null || stage2.stage !== LSS_STAGE_2) {
      result.message = '尼康 LSS 认证第 1 轮响应格式异常';
      return null;
    }
    const mac2 = session.stage3(stage2.nonce, stage2.deviceId);
    if (mac2 === null) {
      result.message = '尼康 LSS 认证失败：未能在 8 个共享根中匹配相机响应';
      NikonBleProvisioning.log(result.message);
      return null;
    }
    trace.push('Nikon LSS shared root index=' + session.index());
    await LumixImportPrototype.writeGatt(gatt, authCharacteristic,
      encodeLssAuthFrame(3, phoneNonce, mac2), trace);

    const stage4Bytes = await NikonBleProvisioning.waitForNotification(notifications, trace);
    if (stage4Bytes === null) {
      result.message = '尼康 LSS 认证第 2 轮超时：相机未回应认证特征';
      return null;
    }
    const stage4 = decodeLssAuthFrame(stage4Bytes);
    if (stage4 === null || stage4.stage !== LSS_STAGE_4) {
      result.message = '尼康 LSS 认证第 2 轮响应格式异常';
      return null;
    }
    // The camera picks this value; both sides must derive the same session
    // key from it, so it is taken verbatim rather than assumed.
    trace.push('Nikon LSS ' + session.describeKey1(stage4.deviceId));
    NikonBleProvisioning.lastCameraDeviceId = stage4.deviceId.slice();
    return session;
  }

  /** Releases the GATT link, if this module still holds one. */
  static async release(): Promise<void> {
    // **必须关尼康自己的句柄。**
    //
    // 这里原来只做两件事：先把 `NikonBleProvisioning.activeGatt` 置空，再调用
    // `LumixImportPrototype.closeActiveGatt()`。但后者读的是
    // **`LumixImportPrototype.activeGatt`**——另一个字段，尼康流程从来没往里存过
    // 东西，于是它执行到 `if (!gatt) return;` 就静默返回了。
    //
    // 结果：**GATT 链路从头到尾没有断开过**，只有进程被杀死时系统才回收它。
    // 用户的现场判断完全正确——"一退出 App 热点立马出现，说明蓝牙一直没断开"。
    // 相机看到客户端仍在连接，就一直不开 Wi-Fi 热点；后面所有"扫描不到 SSID"
    // 的排查方向因此全是错的。
    const gatt = NikonBleProvisioning.activeGatt;
    NikonBleProvisioning.activeGatt = null;
    if (gatt) {
      try {
        gatt.disconnect();
      } catch (error) {
        // 已经断开时再 disconnect 会抛，属于正常情况，继续走 close。
      }
      try {
        gatt.close();
      } catch (error) {
        // 同上：close 失败也继续，不能因为清理动作把主流程掀翻。
      }
    }
    // 再把共享的那一份也收干净（尼康流程若曾借道 Lumix 的连接路径，句柄会在那边）。
    await LumixImportPrototype.closeActiveGatt();
  }
}
