/**
 * Nikon identity and protocol constants.
 *
 * This module deliberately contains no Panasonic identifiers.  Nikon bodies
 * advertise a model token followed by a numeric instance suffix (for example
 * Z_5_1234567).  The suffix is not persisted and is never treated as a
 * credential; it is only used to recognise the nearby body.
 */
export interface NikonCameraIdentity {
  brand: string;
  model: string;
  family: string;
  imageKey: string;
}

export interface NikonWifiIdentity {
  brand: string;
  model: string;
  family: string;
  imageKey: string;
}

interface NikonModelSpec {
  code: string;
  model: string;
  family: string;
  imageKey: string;
}

export class NikonCameraService {
  /** SnapBridge LSS (Low-power Service) GATT layout.
   *
   * Every UUID below is a shipped-artifact fact, not a community guess: they
   * were read out of the official SnapBridge 2.13.3 (com.nikon.snapbridge.cmru)
   * `classes.dex`, in `bleclient/service/ble/BleLssService.<clinit>`, where the
   * service registers its characteristic table.  Nikon's private base suffix is
   * 3DD4-4255-8D62-6DC7B9BD5561; the standard SIG suffix
   * 0000-1000-8000-00805F9B34FB is used only for the device-information service,
   * the battery level and the CCCD.
   *
   * The runtime always discovers the service tree first, so a body that omits
   * one of these characteristics simply skips the corresponding step instead of
   * failing the whole session. */
  static readonly SNAPBRIDGE_SERVICE = '0000DE00-3DD4-4255-8D62-6DC7B9BD5561';
  /** LSS authentication.  The 17-byte `{stage, nonce, deviceId}` handshake is
   * written here by the phone and notified back here by the camera. */
  static readonly AUTHENTICATION_CHARACTERISTIC = '00002000-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly POWER_CONTROL_CHARACTERISTIC = '00002001-3DD4-4255-8D62-6DC7B9BD5561';
  /** Where the phone writes its own name during pairing. */
  static readonly CLIENT_DEVICE_NAME_CHARACTERISTIC = '00002002-3DD4-4255-8D62-6DC7B9BD5561';
  /** Where the camera reads its own name back — this, not 2002, is the body
   * identity characteristic. */
  static readonly SERVER_DEVICE_NAME_CHARACTERISTIC = '00002003-3DD4-4255-8D62-6DC7B9BD5561';
  /** Wi-Fi credentials.  One read returns flag + encrypted SSID (32 bytes) +
   * encrypted password (64 bytes) + security (1 byte); notifications announce a
   * later change.  Requires a completed LSS authentication to decrypt. */
  static readonly CONNECTION_CONFIGURATION_CHARACTERISTIC = '00002004-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly CONNECTION_ESTABLISHMENT_CHARACTERISTIC = '00002005-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly CURRENT_TIME_CHARACTERISTIC = '00002006-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly LOCATION_CHARACTERISTIC = '00002007-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly CONTROL_POINT_CHARACTERISTIC = '00002008-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly FEATURE_CHARACTERISTIC = '00002009-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly CABLE_ATTACHMENT_CHARACTERISTIC = '0000200A-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly SERIAL_NUMBER_CHARACTERISTIC = '0000200B-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly STATUS_FOR_CONTROL_CHARACTERISTIC = '00002020-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly CONTROL_POINT_FOR_CONTROL_CHARACTERISTIC = '00002021-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly CATEGORY_INFO_CHARACTERISTIC = '00002080-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly STATUS_FOR_CAPTURE_CHARACTERISTIC = '00002081-3DD4-4255-8D62-6DC7B9BD5561';
  static readonly BATTERY_LEVEL_CHARACTERISTIC = '00002A19-0000-1000-8000-00805F9B34FB';
  static readonly DEVICE_INFORMATION_SERVICE = '0000180A-0000-1000-8000-00805F9B34FB';
  /** Client Characteristic Configuration descriptor. */
  static readonly CLIENT_CONFIGURATION_DESCRIPTOR = '00002902-0000-1000-8000-00805F9B34FB';

  // Legacy aliases.  PAIR/STATUS both resolve to the authentication
  // characteristic because that is where the LSS handshake is observed; the
  // former ID mapping to 2002 was wrong (2002 is the client device name, which
  // the phone writes), so ID now follows the server device name instead.
  static readonly PAIR_CHARACTERISTIC = NikonCameraService.AUTHENTICATION_CHARACTERISTIC;
  static readonly ID_CHARACTERISTIC = NikonCameraService.SERVER_DEVICE_NAME_CHARACTERISTIC;
  static readonly TIME_CHARACTERISTIC = NikonCameraService.CURRENT_TIME_CHARACTERISTIC;
  static readonly GEO_CHARACTERISTIC = NikonCameraService.LOCATION_CHARACTERISTIC;
  static readonly STATUS_CHARACTERISTIC = NikonCameraService.AUTHENTICATION_CHARACTERISTIC;

  private static readonly MODELS: Array<NikonModelSpec> = [
    { code: '50II', model: 'NIKON Z 50II', family: 'Z 系列·半画幅', imageKey: 'nikon_z50ii' },
    { code: '6III', model: 'NIKON Z 6III', family: 'Z 系列·全画幅', imageKey: 'nikon_z6iii' },
    { code: '5II', model: 'NIKON Z 5II', family: 'Z 系列·全画幅', imageKey: 'nikon_z5ii' },
    { code: '7II', model: 'NIKON Z 7II', family: 'Z 系列·全画幅', imageKey: 'nikon_z7ii' },
    { code: '6II', model: 'NIKON Z 6II', family: 'Z 系列·全画幅', imageKey: 'nikon_z6ii' },
    { code: '6', model: 'NIKON Z 6', family: 'Z 系列·全画幅', imageKey: 'nikon_z6' },
    { code: '7', model: 'NIKON Z 7', family: 'Z 系列·全画幅', imageKey: 'nikon_z7' },
    { code: '50', model: 'NIKON Z 50', family: 'Z 系列·半画幅', imageKey: 'nikon_z50' },
    { code: '30', model: 'NIKON Z 30', family: 'Z 系列·半画幅', imageKey: 'nikon_z30' },
    { code: '5', model: 'NIKON Z 5', family: 'Z 系列·全画幅', imageKey: 'nikon_z5' },
    { code: '8', model: 'NIKON Z 8', family: 'Z 系列·全画幅', imageKey: 'nikon_z8' },
    { code: '9', model: 'NIKON Z 9', family: 'Z 系列·全画幅', imageKey: 'nikon_z9' },
    { code: 'FC', model: 'NIKON Z fc', family: 'Z 系列·半画幅', imageKey: 'nikon_zfc' },
    { code: 'F', model: 'NIKON Z f', family: 'Z 系列·全画幅', imageKey: 'nikon_zf' },
  ];

  /** Match Bluetooth names without guessing a MAC address or a handle. */
  static identifyBluetoothName(deviceName: string): NikonCameraIdentity | null {
    const normalized = deviceName.toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '');
    if (normalized.length === 0) return null;
    // Z8 advertises the complete local name as NIKON_Z_8_<numeric-id>.
    // Keep this exact form explicit because it shares the Z5 direct
    // Wi-Fi/PTP import route while retaining the Z8 identity artwork.
    if (/^NIKON_Z_8_[0-9]{4,}$/.test(normalized)) {
      return { brand: 'Nikon', model: 'NIKON Z 8', family: 'Z 系列·全画幅', imageKey: 'nikon_z8' };
    }
    const body = normalized.indexOf('NIKON_') === 0 ? normalized.substring(6) : normalized;
    // The serial part is a numeric advertisement suffix.  Requiring at least
    // four digits avoids treating a generic "Z5" BLE device as a camera while
    // accepting the seven/eight digit names used by bodies.
    const entry = NikonCameraService.parseZBodyTokens(body, /^[0-9]{4,}$/);
    if (entry !== null) {
      return { brand: 'Nikon', model: entry.model, family: entry.family, imageKey: entry.imageKey };
    }
    return null;
  }

  /**
   * Parse the generic Z-body name layout: Z + model code + optional
   * generation digit + serial, separated by underscores after normalisation.
   * Nikon never spells the mark number in roman numerals inside the
   * advertised name; the generation digit carries it instead, so
   * Z_6_2_xxxxxxx is the Z 6II, Z_6_3_xxxxxxx the Z 6III and Z_6_xxxxxxx
   * the Z 6, and likewise NIKON_Z50_2_xxxxxx is the Z 50II.
   */
  private static parseZBodyTokens(body: string, serialTest: RegExp): NikonModelSpec | null {
    const tokens = body.split('_');
    let code = '';
    let restStart = -1;
    if (tokens[0] === 'Z') {
      if (tokens.length < 3) return null;
      code = tokens[1];
      restStart = 2;
    } else if (tokens[0].length > 1 && tokens[0].charAt(0) === 'Z') {
      code = tokens[0].substring(1);
      restStart = 1;
    } else {
      return null;
    }
    if (!/^([0-9]{1,2}|FC|F)$/.test(code)) return null;
    const rest = tokens.slice(restStart);
    let serial = '';
    if (rest.length === 1) {
      serial = rest[0];
    } else if (rest.length === 2 && /^[0-9]$/.test(rest[0])) {
      if (rest[0] === '2') {
        code += 'II';
      } else if (rest[0] === '3') {
        code += 'III';
      } else {
        return null;
      }
      serial = rest[1];
    } else {
      return null;
    }
    if (!serialTest.test(serial)) return null;
    for (const entry of NikonCameraService.MODELS) {
      if (entry.code === code) {
        return entry;
      }
    }
    return null;
  }

  /** Match Nikon camera access points.  SSID/password values are generated or
   * changed by the camera, so this function only identifies the model token;
   * it deliberately does not embed a password. */
  static identifyWifiSsid(ssid: string): NikonWifiIdentity | null {
    const normalized = ssid.toUpperCase().replace(/[^A-Z0-9]+/g, '_');
    const trimmed = normalized.replace(/^_+|_+$/g, '');
    const body = trimmed.indexOf('NIKON_') === 0 ? trimmed.substring(6) : trimmed;
    const parsed = NikonCameraService.parseZBodyTokens(body, /^[A-Z0-9]{4,}$/);
    if (parsed !== null) {
      return { brand: 'Nikon', model: parsed.model, family: parsed.family, imageKey: parsed.imageKey };
    }
    for (const entry of NikonCameraService.MODELS) {
      // No bare `_${code}_` substring alias: it matched ordinary AP names
      // such as HOME_5_ABCDE and let a generic router masquerade as a Nikon
      // body. Only brand/model-anchored forms are accepted.
      const aliases = [
        `NIKON_Z_${entry.code}_`, `Z_${entry.code}_`,
        `NIKON_Z${entry.code}_`, `Z${entry.code}_`,
      ];
      for (const alias of aliases) {
        if (normalized.indexOf(alias) < 0) continue;
        const suffix = normalized.substring(normalized.indexOf(alias) + alias.length).replace(/^_+/, '');
        if (/^[A-Z0-9]{4,}$/.test(suffix)) {
          return { brand: 'Nikon', model: entry.model, family: entry.family, imageKey: entry.imageKey };
        }
      }
    }
    return null;
  }

  static imageKeyForModel(model: string): string {
    const upper = model.toUpperCase().replace(/[^A-Z0-9]+/g, '');
    for (const entry of NikonCameraService.MODELS) {
      if (upper.indexOf(`Z${entry.code}`) >= 0 || (entry.code === 'F' && upper.indexOf('ZF') >= 0)) {
        return entry.imageKey;
      }
    }
    return '';
  }

  static isNikonImageKey(imageKey: string): boolean {
    return imageKey.indexOf('nikon_') === 0;
  }
}
