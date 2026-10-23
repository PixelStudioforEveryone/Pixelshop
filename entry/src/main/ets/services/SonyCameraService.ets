/**
 * Sony Alpha identity and protocol constants.
 *
 * Sony mirrorless bodies expose their Wi-Fi Direct access point while the
 * "PC Remote" (PC 远程功能) smart feature is active. The AP SSID layout is
 * DIRECT-<4+ alnum>:<model token>, for example DIRECT-12AB:ILCE-7M4 or
 * DIRECT-C0DE:ZV-E10. The photo transport on that network is standard
 * PTP/IP (CIPA DC-005) on TCP port 15740 - the same transport libgphoto2
 * serves generically for Sony bodies - so this module only owns the model
 * identity table; the transport adapter is shared with the Nikon PTP/IP
 * implementation.
 *
 * BLE GATT layout
 * ---------------
 * Every UUID and wire constant below is a shipped-artifact fact read out of
 * Sony's own Creators' App 3.5.0 (`jp.co.sony.ips.portalapp`), not a community
 * guess. Sony uses 128-bit services of the form
 * `8000XX00-XX00-FFFF-FFFF-FFFFFFFFFFFF` and 16-bit-short characteristics
 * (`8000EE01`, `8000CC06`, ...); the official client matches characteristics by
 * UUID-string prefix rather than by full comparison.
 */
export interface SonyCameraIdentity {
  brand: string;
  model: string;
  family: string;
  imageKey: string;
}

/** Capability bits a Sony body advertises in its BLE manufacturer data. */
export interface SonyAdvertisement {
  /** True when the manufacturer data carries Sony's SIG company id (0x012D). */
  isSony: boolean;
  /** True when the Sony payload also carries the "camera" marker 03 00. */
  isSonyCamera: boolean;
  /** Two-character model code, e.g. "U0". Empty when not advertised. */
  modelCode: string;
  /** Pairing is supported / currently enabled (tag 34). */
  pairingSupported: boolean;
  pairingEnabled: boolean;
  /** Smartphone remote control supported / enabled (tag 35). */
  remoteControlSupported: boolean;
  remoteControlEnabled: boolean;
  /** Smartphone image transfer supported / enabled (tag 35). */
  imageTransferSupported: boolean;
  imageTransferEnabled: boolean;
  /** Wi-Fi credential handover supported / enabled (tag 33). */
  wifiHandoverSupported: boolean;
  wifiHandoverEnabled: boolean;
}

interface SonyModelSpec {
  /** SSID model token, e.g. ILCE-7M4. */
  token: string;
  model: string;
  family: string;
  imageKey: string;
}

interface PairingIdentity {
  firmware: string;
  model: string;
}

interface PairingNotification {
  kind: number;
  value: number;
}

export class SonyCameraService {
  /** PTP/IP command/event port shared by every CIPA DC-005 body. */
  static readonly PTPIP_PORT = 15740;

  /** Sony private GATT base suffix: 8000XX00-XX00-FFFF-FFFF-FFFFFFFFFFFF. */
  private static readonly UUID_SUFFIX = '-CC00-FFFF-FFFF-FFFFFFFFFFFF';
  private static readonly UUID_SUFFIX_EE = '-EE00-FFFF-FFFF-FFFFFFFFFFFF';

  /** Pairing service. The phone writes a trigger, subscribes for state/result
   * notifications and reads the camera identity. */
  static readonly PAIRING_SERVICE = `8000EE00${SonyCameraService.UUID_SUFFIX_EE}`;
  /** Write `{6,8,1,0,0,0,0}` here to ask the body to start pairing. */
  static readonly PAIRING_COMMAND_CHARACTERISTIC = `0000EE01${SonyCameraService.UUID_SUFFIX_EE}`;
  /** Notify: 7-byte `[len][0][0][type][v31][v23][v15][v7]` state/result frames. */
  static readonly PAIRING_NOTIFY_CHARACTERISTIC = `0000EE03${SonyCameraService.UUID_SUFFIX_EE}`;
  /** Read: `[len][type_hi][type_lo][fwLen][firmware][modelLen][model]`. */
  static readonly PAIRING_INFO_CHARACTERISTIC = `0000EE04${SonyCameraService.UUID_SUFFIX_EE}`;

  /** Camera control service: Wi-Fi on/off and the AP credentials. */
  static readonly CONTROL_SERVICE = `8000CC00${SonyCameraService.UUID_SUFFIX}`;
  /** Write `{1}` to switch the camera Wi-Fi on. */
  static readonly WIFI_ON_CHARACTERISTIC = `0000CC08${SonyCameraService.UUID_SUFFIX}`;
  /** Read: 3-byte header then the SSID as US-ASCII. */
  static readonly WIFI_SSID_CHARACTERISTIC = `0000CC06${SonyCameraService.UUID_SUFFIX}`;
  /** Read: 3-byte header then the password as US-ASCII. */
  static readonly WIFI_PASSWORD_CHARACTERISTIC = `0000CC07${SonyCameraService.UUID_SUFFIX}`;
  /** Read: 3-byte header then the BSSID as US-ASCII. Optional. */
  static readonly WIFI_BSSID_CHARACTERISTIC = `0000CC0C${SonyCameraService.UUID_SUFFIX}`;
  /** Read: camera UUID (device identity). */
  static readonly CAMERA_UUID_CHARACTERISTIC = `0000CCA2${SonyCameraService.UUID_SUFFIX}`;
  /** Read: SSH tunnel credentials (id / password / host-key fingerprint).
   * 官方 SshSupportCamera 用它建隧道；本应用不读内容，只在诊断里记长度。 */
  static readonly SSH_INFO_CHARACTERISTIC = `0000CC17${SonyCameraService.UUID_SUFFIX}`;

  /** Read: 固件版本（ASCII）。官方 GettingCameraDeviceInfoState 按
   * CC0A -> CC0B -> CCA7 -> CC0D -> CCAB 的顺序读，全部只用于显示与路由判定。 */
  static readonly FIRMWARE_VERSION_CHARACTERISTIC = `0000CC0A${SonyCameraService.UUID_SUFFIX}`;
  /** Read: 机型字符串（ASCII）。官方解析后只写日志，不参与任何分支。 */
  static readonly MODEL_NAME_CHARACTERISTIC = `0000CC0B${SonyCameraService.UUID_SUFFIX}`;
  /** Read: 能力位 TLV。官方按 `1 字节长度 + 3 字节记录 {id_hi, id_lo, on/off}`
   * 解析成 EnumSupportInfo 集合，其中 id 8 = SshInfo、10 = ApConnection、
   * 11 = SmartPhoneConnectionMenu。这是「这条相机会不会走 SSH 隧道」的判据。 */
  static readonly CAPABILITY_CHARACTERISTIC = `0000CC0D${SonyCameraService.UUID_SUFFIX}`;
  /** Read: 相机标识符。 */
  static readonly IDENTIFIER_CHARACTERISTIC = `0000CCA7${SonyCameraService.UUID_SUFFIX}`;
  /** Read: 当前 Wi-Fi 频段（官方 SettingWifiFrequencyBandState 用的 CCAB）。 */
  static readonly WIFI_BAND_CHARACTERISTIC = `0000CCAB${SonyCameraService.UUID_SUFFIX}`;

  /** Standard SIG Client Characteristic Configuration descriptor. */
  static readonly CLIENT_CONFIGURATION_DESCRIPTOR = '00002902-0000-1000-8000-00805F9B34FB';

  /** Payload written to {@link PAIRING_COMMAND_CHARACTERISTIC} to request
   * pairing. Byte-exact from `BluetoothGattUtil.PAIRING_COMMAND_CHARACTERISTIC`. */
  static readonly PAIRING_COMMAND_PAYLOAD: number[] = [6, 8, 1, 0, 0, 0, 0];
  /** Payload written to {@link WIFI_ON_CHARACTERISTIC}. */
  static readonly WIFI_ON_PAYLOAD: number[] = [1];

  /** Pairing state values notified on {@link PAIRING_NOTIFY_CHARACTERISTIC}
   * (frame type 1). Values are the big-endian u32 carried in bytes 3..6. */
  static readonly STATE_BLE_REQUEST_RECEIVED = 1;
  static readonly STATE_BLE_AUTH_PERMITTED = 2;
  static readonly STATE_BLE_AUTH_REJECTED = 3;
  static readonly STATE_BTC_ENABLED = 4;
  static readonly STATE_BTC_REQUEST_RECEIVED = 5;
  static readonly STATE_BTC_AUTH_PERMITTED = 6;
  static readonly STATE_BTC_AUTH_REJECTED = 7;
  static readonly STATE_BTC_PAIRING_SUCCESS = 8;
  static readonly STATE_USER_CANCEL = 9;

  /** Pairing result values (frame type 2). */
  static readonly RESULT_SUCCESS = 1;
  static readonly RESULT_FAIL_BLE_AUTH_REJECTED = 2;
  static readonly RESULT_FAIL_BLE_PAIRING_FAILED = 3;
  static readonly RESULT_FAIL_BTC_AUTH_REJECTED = 4;
  static readonly RESULT_FAIL_BTC_PAIRING_FAILED = 5;
  static readonly RESULT_FAIL_USER_CANCEL = 6;
  static readonly RESULT_FAIL_NOT_READY_FOR_PAIRING = 7;
  static readonly RESULT_FAIL_MFI_AUTH_REJECTED = 8;
  static readonly RESULT_FAIL_RANDOM_NUMBER_MISMATCH = 9;
  static readonly RESULT_FAIL_PAIR_REGISTRATION_FAILURE = 10;

  /** Manufacturer-data constants used by {@link parseSonyAdvertisement}.
   * Sony's Bluetooth SIG company id is 0x012D = 301, which appears
   * little-endian on the wire as `45 01`. */
  private static readonly SIG_COMPANY_ID = 0x012D;

  private static readonly MODELS: Array<SonyModelSpec> = [
    { token: 'ILCE-1M2', model: 'Sony α1 II', family: 'Alpha 全画幅微单', imageKey: 'sony_a1m2' },
    { token: 'ILCE-1', model: 'Sony α1', family: 'Alpha 全画幅微单', imageKey: 'sony_a1' },
    { token: 'ILCE-9M3', model: 'Sony α9 III', family: 'Alpha 全画幅微单', imageKey: 'sony_a9m3' },
    { token: 'ILCE-7RM6', model: 'Sony α7R VI', family: 'Alpha 全画幅微单', imageKey: 'sony_a7r6' },
    { token: 'ILCE-7RM5', model: 'Sony α7R V', family: 'Alpha 全画幅微单', imageKey: 'sony_a7r5' },
    { token: 'ILCE-7SM3', model: 'Sony α7S III', family: 'Alpha 全画幅微单', imageKey: 'sony_a7s3' },
    { token: 'ILCE-7M5', model: 'Sony α7 V', family: 'Alpha 全画幅微单', imageKey: 'sony_a7m5' },
    { token: 'ILCE-7M4', model: 'Sony α7 IV', family: 'Alpha 全画幅微单', imageKey: 'sony_a7m4' },
    { token: 'ILCE-7M3', model: 'Sony α7 III', family: 'Alpha 全画幅微单', imageKey: 'sony_a7m3' },
    { token: 'ILCE-7CR', model: 'Sony α7CR', family: 'Alpha 全画幅微单', imageKey: 'sony_a7cr' },
    { token: 'ILCE-7CM2', model: 'Sony α7C II', family: 'Alpha 全画幅微单', imageKey: 'sony_a7c2' },
    { token: 'ILCE-7C', model: 'Sony α7C', family: 'Alpha 全画幅微单', imageKey: 'sony_a7c' },
    { token: 'ILCE-6700', model: 'Sony α6700', family: 'Alpha 半画幅微单', imageKey: 'sony_a6700' },
    { token: 'ILCE-6600', model: 'Sony α6600', family: 'Alpha 半画幅微单', imageKey: 'sony_a6600' },
    { token: 'ILCE-6400', model: 'Sony α6400', family: 'Alpha 半画幅微单', imageKey: 'sony_a6400' },
    { token: 'ILME-FX3A', model: 'Sony FX3A', family: 'Cinema Line 电影机', imageKey: 'sony_a7s3' },
    { token: 'ILME-FX3', model: 'Sony FX3', family: 'Cinema Line 电影机', imageKey: 'sony_a7s3' },
    { token: 'ILME-FX2', model: 'Sony FX2', family: 'Cinema Line 电影机', imageKey: 'sony_a7s3' },
    { token: 'ILME-FX30', model: 'Sony FX30', family: 'Cinema Line 电影机', imageKey: 'sony_a6700' },
    { token: 'ZV-E10M2', model: 'Sony ZV-E10 II', family: 'ZV 系列Vlog微单', imageKey: 'sony_zve10ii' },
    { token: 'ZV-E10', model: 'Sony ZV-E10', family: 'ZV 系列Vlog微单', imageKey: 'sony_zve10' },
    { token: 'ZV-E1', model: 'Sony ZV-E1', family: 'ZV 系列Vlog微单', imageKey: 'sony_zve1' },
    { token: 'ZV-1M2', model: 'Sony ZV-1 II', family: 'ZV 系列Vlog卡片机', imageKey: 'sony_zve10' },
    { token: 'ZV-1F', model: 'Sony ZV-1F', family: 'ZV 系列Vlog卡片机', imageKey: 'sony_zve10' },
    { token: 'DSC-RX1RM3', model: 'Sony RX1R III', family: 'RX 系列高端卡片机', imageKey: 'sony_a7cr' },
    { token: 'ILX-LR1', model: 'Sony ILX-LR1', family: 'Alpha 全画幅微单', imageKey: 'sony_a1' },
  ];

  /** Tokens that only ever appear in a BLE local name (never in a DIRECT- SSID),
   * so {@link identifyBluetoothName} can accept them without loosening the
   * Wi-Fi matcher. */
  private static readonly NAME_ONLY_TOKENS: Array<SonyModelSpec> = [
    { token: 'ILCE-7CM2', model: 'Sony α7C II', family: 'Alpha 全画幅微单', imageKey: 'sony_a7c2' },
  ];

  /**
   * Match Sony camera access points: DIRECT-<instance>:<model token>. The
   * DIRECT- prefix is required so ordinary home routers or Sony TVs can never
   * masquerade as a camera, and the model token must be one of the known
   * mirrorless bodies. SSID/password values are generated by the camera, so
   * this function only identifies the model.
   */
  static identifyWifiSsid(ssid: string): SonyCameraIdentity | null {
    const normalized = ssid.toUpperCase().replace(/^\"|\"$/g, '').trim();
    if (normalized.length === 0) return null;
    const colon = normalized.indexOf(':');
    if (colon < 0) return null;
    const prefix = normalized.substring(0, colon);
    if (prefix.indexOf('DIRECT-') !== 0) return null;
    const instance = prefix.substring('DIRECT-'.length);
    if (!/^[0-9A-Z]{4,}$/.test(instance)) return null;
    let token = normalized.substring(colon + 1).replace(/[^A-Z0-9-]+/g, '');
    if (token.indexOf('SONY-') === 0) token = token.substring('SONY-'.length);
    // Longer tokens must win so ILCE-7M5 is not eaten by ILCE-7M.
    const sorted = SonyCameraService.MODELS.slice().sort((a: SonyModelSpec, b: SonyModelSpec): number => b.token.length - a.token.length);
    for (const entry of sorted) {
      if (token === entry.token) {
        return { brand: 'Sony', model: entry.model, family: entry.family, imageKey: entry.imageKey };
      }
    }
    return null;
  }

  static imageKeyForModel(model: string): string {
    const upper = model.toUpperCase().replace(/[^A-Z0-9]+/g, '');
    // Longest token first: ILCE-7M5 / ZV-E10M2 must win over their shorter
    // prefixes (ILCE-7M, ZV-E10) when both match the same name.
    const sorted = SonyCameraService.MODELS.slice().sort((a: SonyModelSpec, b: SonyModelSpec): number => b.token.length - a.token.length);
    for (const entry of sorted) {
      const tokenAlpha = entry.token.replace(/[^A-Z0-9]+/g, '');
      if (upper.indexOf(tokenAlpha) >= 0) return entry.imageKey;
    }
    return '';
  }

  static isSonyImageKey(imageKey: string): boolean {
    return imageKey.indexOf('sony_') === 0;
  }

  /**
   * Recognise a Sony body from its advertised Bluetooth local name.
   *
   * The camera advertises its model token (for example `ILCE-7M4`) as the
   * local name, sometimes with a serial suffix. This is the BLE counterpart of
   * {@link identifyWifiSsid} and mirrors NikonCameraService.identifyBluetoothName.
   */
  static identifyBluetoothName(deviceName: string): SonyCameraIdentity | null {
    const cleaned = deviceName.replace(/[\u0000-\u001F\u007F]/g, '').trim();
    if (cleaned.length === 0) return null;
    const upper = cleaned.toUpperCase().replace(/[^A-Z0-9-]+/g, '-');
    // Longest token first: ILCE-7CM2 / ZV-E10M2 must win over ILCE-7C / ZV-E10.
    const sorted = SonyCameraService.MODELS.concat(SonyCameraService.NAME_ONLY_TOKENS)
      .slice()
      .sort((a: SonyModelSpec, b: SonyModelSpec): number => b.token.length - a.token.length);
    for (const entry of sorted) {
      // Accept "ILCE-7M4", "ILCE-7M4-1234567" and "SONY ILCE-7M4".
      const tokenAlpha = entry.token.replace(/[^A-Z0-9]+/g, '');
      const upperAlpha = upper.replace(/[^A-Z0-9]+/g, '');
      if (upperAlpha.indexOf(tokenAlpha) === 0) {
        return { brand: 'Sony', model: entry.model, family: entry.family, imageKey: entry.imageKey };
      }
    }
    return null;
  }

  /**
   * Decode the Sony manufacturer-specific AD record (AD type 0xFF).
   *
   * Layout recovered from `BluetoothLeDevice` in the official client:
   *   [0..1] company id 45 01 (0x012D, little-endian) -> Sony
   *   [2..3] 03 00                                    -> Sony camera
   *   [4..5] reserved
   *   [6..7] two ASCII characters                     -> model code
   *   [8..]  TLV triples [tag][d0][d1], stepping 3, tag 0 terminates
   *     tag 33 (0x21): d0 bit7 wireless-power-on, bit6 camera on,
   *                    bit5/4 Wi-Fi handover supported/enabled
   *     tag 34 (0x22): d0 bit7/bit6 pairing supported/enabled,
   *                    bit5/4 location supported/enabled
   *     tag 35 (0x23): d0 bit7 remote-control supported, bit4 image-transfer
   *                    supported, bit1/0 push-notification; d1 bit7 background
   *     "enabled" values are two-bit tri-states, so they are masked, not tested
   *     bit by bit: (d0 & 0x60) == 0x20 means remote control is enabled.
   */
  static parseSonyAdvertisement(data: ArrayBuffer): SonyAdvertisement {
    const parsed: SonyAdvertisement = {
      isSony: false, isSonyCamera: false, modelCode: '',
      pairingSupported: false, pairingEnabled: false,
      remoteControlSupported: false, remoteControlEnabled: false,
      imageTransferSupported: false, imageTransferEnabled: false,
      wifiHandoverSupported: false, wifiHandoverEnabled: false,
    };
    if (!data || data.byteLength < 11) return parsed;
    const bytes = new Uint8Array(data);

    // Walk the AD structures to find the manufacturer-specific record (0xFF).
    let offset = 0;
    let payload: Uint8Array | null = null;
    while (offset < bytes.length) {
      const fieldLength = bytes[offset];
      if (fieldLength === 0) break;
      const fieldEnd = offset + 1 + fieldLength;
      if (fieldEnd > bytes.length || fieldLength < 1) break;
      if (bytes[offset + 1] === 0xFF) {
        payload = bytes.subarray(offset + 2, fieldEnd);
        break;
      }
      offset = fieldEnd;
    }
    if (payload === null) return parsed;

    const company = payload[0] | (payload[1] << 8);
    if (company !== SonyCameraService.SIG_COMPANY_ID) return parsed;
    parsed.isSony = true;
    if (payload[2] !== 0x03 || payload[3] !== 0x00) return parsed;
    parsed.isSonyCamera = true;
    parsed.modelCode = String.fromCharCode(payload[6]) + String.fromCharCode(payload[7]);

    let index = 8;
    while (index + 2 < payload.length) {
      const tag = payload[index];
      const d0 = payload[index + 1];
      const d1 = payload[index + 2];
      if (tag === 0) break;
      if (tag === 33) {
        parsed.wifiHandoverSupported = (d0 & 0x20) !== 0;
        parsed.wifiHandoverEnabled = (d0 & 0x30) === 0x10;
      } else if (tag === 34) {
        parsed.pairingSupported = (d0 & 0x80) !== 0;
        parsed.pairingEnabled = (d0 & 0xC0) === 0x40;
      } else if (tag === 35) {
        parsed.remoteControlSupported = (d0 & 0x80) !== 0;
        parsed.remoteControlEnabled = (d0 & 0x60) === 0x20;
        parsed.imageTransferSupported = (d0 & 0x10) !== 0;
        parsed.imageTransferEnabled = (d0 & 0x0C) === 0x04;
      }
      index += 3;
    }
    return parsed;
  }

  /**
   * Decode the camera identity read from {@link PAIRING_INFO_CHARACTERISTIC}
   * (0000EE04): `[len][type_hi][type_lo][fwLen][firmware][modelLen][model]`.
   * Returns null when the frame is truncated or is not a camera-info frame.
   */
  static parsePairingIdentity(bytes: Uint8Array): PairingIdentity | null {
    if (bytes.length < 5) return null;
    const total = bytes[0] & 0xFF;
    if (total !== 0 && bytes.length < total) return null;
    const dataType = (bytes[1] & 0xFF) << 8 | (bytes[2] & 0xFF);
    // Type 0 is the camera-information frame; anything else is not identity.
    if (dataType !== 0) return null;
    const firmwareLength = bytes[3] & 0xFF;
    if (4 + firmwareLength >= bytes.length) return null;
    const firmware = SonyCameraService.ascii(bytes, 4, firmwareLength);
    const modelLengthIndex = 4 + firmwareLength;
    const modelLength = bytes[modelLengthIndex] & 0xFF;
    const modelStart = modelLengthIndex + 1;
    if (modelStart + modelLength > bytes.length) return null;
    const model = SonyCameraService.ascii(bytes, modelStart, modelLength);
    if (model.length === 0) return null;
    return { firmware: firmware, model: model } as PairingIdentity;
  }

  /**
   * Decode one pairing state/result notification from
   * {@link PAIRING_NOTIFY_CHARACTERISTIC} (0000EE03). The frame is 8 bytes:
   * `[len][0][0][type][v31][v23][v15][v7]` with a big-endian u32 value.
   * Type 1 is a state, type 2 is a result.
   */
  static parsePairingNotification(bytes: Uint8Array): PairingNotification | null {
    // Requiring the full 8 bytes (not 7) keeps the u32 read from running off the
    // end of a short frame.
    if (bytes.length < 8) return null;
    const kind = bytes[3] & 0xFF;
    if (kind !== 1 && kind !== 2) return null;
    const value = ((bytes[4] & 0xFF) << 24) | ((bytes[5] & 0xFF) << 16) |
      ((bytes[6] & 0xFF) << 8) | (bytes[7] & 0xFF);
    return { kind: kind, value: value } as PairingNotification;
  }

  /** Human-readable label for a pairing state value, for UI and logs. */
  static stateLabel(value: number): string {
    switch (value) {
      case SonyCameraService.STATE_BLE_REQUEST_RECEIVED: return '相机已收到配对请求';
      case SonyCameraService.STATE_BLE_AUTH_PERMITTED: return '蓝牙认证通过';
      case SonyCameraService.STATE_BLE_AUTH_REJECTED: return '蓝牙认证被拒';
      case SonyCameraService.STATE_BTC_ENABLED: return '经典蓝牙已启用';
      case SonyCameraService.STATE_BTC_REQUEST_RECEIVED: return '相机已收到经典蓝牙配对请求';
      case SonyCameraService.STATE_BTC_AUTH_PERMITTED: return '经典蓝牙认证通过';
      case SonyCameraService.STATE_BTC_AUTH_REJECTED: return '经典蓝牙认证被拒';
      case SonyCameraService.STATE_BTC_PAIRING_SUCCESS: return '配对成功';
      case SonyCameraService.STATE_USER_CANCEL: return '相机端已取消';
      default: return `配对状态 ${value}`;
    }
  }

  /** Human-readable label for a pairing result value, for UI and logs. */
  static resultLabel(value: number): string {
    switch (value) {
      case SonyCameraService.RESULT_SUCCESS: return '配对成功';
      case SonyCameraService.RESULT_FAIL_BLE_AUTH_REJECTED: return '蓝牙认证被拒';
      case SonyCameraService.RESULT_FAIL_BLE_PAIRING_FAILED: return '蓝牙配对失败';
      case SonyCameraService.RESULT_FAIL_BTC_AUTH_REJECTED: return '经典蓝牙认证被拒';
      case SonyCameraService.RESULT_FAIL_BTC_PAIRING_FAILED: return '经典蓝牙配对失败';
      case SonyCameraService.RESULT_FAIL_USER_CANCEL: return '用户取消';
      case SonyCameraService.RESULT_FAIL_NOT_READY_FOR_PAIRING: return '相机未进入配对窗口';
      case SonyCameraService.RESULT_FAIL_MFI_AUTH_REJECTED: return 'MFi 认证被拒';
      case SonyCameraService.RESULT_FAIL_RANDOM_NUMBER_MISMATCH: return '随机数不匹配';
      case SonyCameraService.RESULT_FAIL_PAIR_REGISTRATION_FAILURE: return '配对注册失败';
      default: return `配对结果 ${value}`;
    }
  }

  private static ascii(bytes: Uint8Array, start: number, length: number): string {
    let text = '';
    for (let index = start; index < start + length && index < bytes.length; index++) {
      const value = bytes[index];
      if (value === 0) break;
      if (value < 0x20 || value > 0x7E) return '';
      text += String.fromCharCode(value);
    }
    return text.trim();
  }
}
