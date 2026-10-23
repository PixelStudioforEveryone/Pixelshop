/**
 * Nikon LSS (SnapBridge Low-power Service) wire formats.
 *
 * Scope
 * -----
 * This module owns only the *byte-level shapes* of the Nikon BLE provisioning
 * handshake: the authentication frame, the Wi-Fi credential block and the
 * security enumeration. It deliberately contains no cipher, because the LSS
 * cipher lives in `NikonLssCrypto.ets`, and no GATT code, because that lives in
 * `NikonBleProvisioning.ets`.
 *
 * Evidence
 * --------
 * Every constant and offset below was read out of the official SnapBridge
 * 2.13.3 (com.nikon.snapbridge.cmru) `classes.dex`:
 *
 *   - Authentication frame `[stage:1][nonce:8][deviceId:8]` — codec
 *     `snapbridge/bleclient/b;`, which both encodes the phone's request and
 *     decodes the camera's reply. 17 bytes, no length prefix, no padding.
 *   - `BleAuthenticationData.STAGE_1 = 1`, `STAGE_3 = 3`,
 *     `NONCE_LENGTH = 8`, `DEVICE_ID_LENGTH = 8`.
 *   - Connection configuration read response — `snapbridge/bleclient/j;`
 *     (flags) and `snapbridge/bleclient/k;` (Wi-Fi block). Layout:
 *     `flag(1)` then, when bit0 is set, `ssid(32, encrypted)`,
 *     `password(64, encrypted)`, `security(1, plain)`; then, when bit1 is set,
 *     `sppMaxDataLength(4, little-endian, plain)`.
 *   - `BleConnectionConfigurationWifiData$EncryptMode` carries an explicit
 *     `value` field that is the wire byte: UNDEFINED -1, OPEN 0, WPA2 1,
 *     WPA3 2, WPA2_WPA3 3. `valueOf(int)` scans `values()` comparing that
 *     value, so the wire mapping is by value and never by ordinal.
 *
 * The "phone" and "camera" roles below are named for the real participants; the
 * phone is the one running VIVID.
 *
 * @since 2026-11
 */

import { util } from '@kit.ArkTS';

/** Authentication frame: one stage byte, an 8-byte nonce, an 8-byte device id. */
export const LSS_AUTH_FRAME_BYTES: number = 17;
/** Byte offset of the stage field inside an authentication frame. */
export const LSS_AUTH_STAGE_OFFSET: number = 0;
/** Byte offset of the nonce field inside an authentication frame. */
export const LSS_AUTH_NONCE_OFFSET: number = 1;
/** Byte offset of the device id field inside an authentication frame. */
export const LSS_AUTH_DEVICE_ID_OFFSET: number = 9;
/** Nonce length, matching `BleAuthenticationData.NONCE_LENGTH`. */
export const LSS_NONCE_BYTES: number = 8;
/** Device id length, matching `BleAuthenticationData.DEVICE_ID_LENGTH`. */
export const LSS_DEVICE_ID_BYTES: number = 8;

/** Stage values carried in an authentication frame. */
export const LSS_STAGE_1: number = 1;
export const LSS_STAGE_2: number = 2;
export const LSS_STAGE_3: number = 3;
export const LSS_STAGE_4: number = 4;

/** Encrypted SSID field length in a connection-configuration response. */
export const LSS_SSID_BYTES: number = 32;
/** Encrypted password field length in a connection-configuration response. */
export const LSS_PASSWORD_BYTES: number = 64;
/** Flags byte: bit0 announces a Wi-Fi block, bit1 announces a Bluetooth block. */
export const LSS_FLAG_WIFI: number = 0x01;
export const LSS_FLAG_BLUETOOTH: number = 0x02;

/** One decoded authentication frame. */
export interface NikonLssAuthFrame {
  stage: number;
  nonce: Uint8Array;
  deviceId: Uint8Array;
}

/**
 * Wi-Fi security as carried on the wire.
 *
 * These are the `EncryptMode.value` field values, not ordinals: UNDEFINED is
 * -1, so the three real modes are 0/1/2/3 and cannot be indexed directly.
 */
export class NikonLssEncryptMode {
  static readonly UNDEFINED: number = -1;
  static readonly OPEN: number = 0;
  static readonly WPA2: number = 1;
  static readonly WPA3: number = 2;
  static readonly WPA2_WPA3: number = 3;

  /** Whether a wire value names a security mode this app can act on. */
  static isKnown(value: number): boolean {
    return value === NikonLssEncryptMode.OPEN || value === NikonLssEncryptMode.WPA2 ||
      value === NikonLssEncryptMode.WPA3 || value === NikonLssEncryptMode.WPA2_WPA3;
  }

  /** Human-readable label for logging; never contains the credential itself. */
  static nameFor(value: number): string {
    if (value === NikonLssEncryptMode.OPEN) return 'OPEN';
    if (value === NikonLssEncryptMode.WPA2) return 'WPA2';
    if (value === NikonLssEncryptMode.WPA3) return 'WPA3';
    if (value === NikonLssEncryptMode.WPA2_WPA3) return 'WPA2_WPA3';
    return 'UNDEFINED';
  }
}

/** Decoded connection-configuration payload. */
export interface NikonLssConnectionConfiguration {
  hasWifiSetting: boolean;
  hasBluetoothSetting: boolean;
  ssid: string;
  password: string;
  /** Wire value from {@link NikonLssEncryptMode}. */
  security: number;
  /** Bluetooth SPP maximum data length; 0 when the body reported no BT block. */
  sppMaxDataLength: number;
}

/**
 * Whether a decrypted credential field looks like real text.
 *
 * A wrong session key turns a fixed-width field into effectively random bytes,
 * and the NUL-aware decode renders a short run of control characters. Requiring
 * a minimum length as well as printable content is what makes it safe to try
 * several device identifiers against the same payload: an empty or one-byte
 * result is overwhelmingly more likely to be a failed decrypt than a real SSID,
 * and accepting it would silently pick the wrong session key.
 *
 * @param minLength lowest acceptable length; use at least 3 for an SSID
 * @param maxLength field width; 32 for the SSID, 64 for the password
 */
export function isPlausibleCredentialText(value: string, minLength: number, maxLength: number): boolean {
  if (value.length < minLength || value.length > maxLength) {
    return false;
  }
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code < 32 || code > 126) {
      return false;
    }
  }
  return true;
}

/** Encodes a frame the phone writes to the authentication characteristic. */
export function encodeLssAuthFrame(stage: number, nonce: Uint8Array, deviceId: Uint8Array): Uint8Array {
  const frame = new Uint8Array(LSS_AUTH_FRAME_BYTES);
  frame[LSS_AUTH_STAGE_OFFSET] = stage & 0xff;
  const nonceLength = Math.min(nonce.length, LSS_NONCE_BYTES);
  for (let i = 0; i < nonceLength; i++) {
    frame[LSS_AUTH_NONCE_OFFSET + i] = nonce[i];
  }
  const deviceLength = Math.min(deviceId.length, LSS_DEVICE_ID_BYTES);
  for (let i = 0; i < deviceLength; i++) {
    frame[LSS_AUTH_DEVICE_ID_OFFSET + i] = deviceId[i];
  }
  return frame;
}

/**
 * Decodes a frame notified by the camera. Returns null when the payload is not
 * a well-formed 17-byte frame, so a truncated or unrelated notification is
 * rejected instead of being misread as a stage.
 */
export function decodeLssAuthFrame(bytes: Uint8Array): NikonLssAuthFrame | null {
  if (bytes.length < LSS_AUTH_FRAME_BYTES) {
    return null;
  }
  const nonce = new Uint8Array(LSS_NONCE_BYTES);
  const deviceId = new Uint8Array(LSS_DEVICE_ID_BYTES);
  for (let i = 0; i < LSS_NONCE_BYTES; i++) {
    nonce[i] = bytes[LSS_AUTH_NONCE_OFFSET + i];
  }
  for (let i = 0; i < LSS_DEVICE_ID_BYTES; i++) {
    deviceId[i] = bytes[LSS_AUTH_DEVICE_ID_OFFSET + i];
  }
  return { stage: bytes[LSS_AUTH_STAGE_OFFSET] & 0xff, nonce: nonce, deviceId: deviceId };
}

/**
 * NUL-aware UTF-8 decode.
 *
 * The credential strings are fixed-width fields padded with zeros, so the
 * payload is read as UTF-8 up to the first NUL. An all-zero field decodes to
 * the empty string rather than to a run of replacement characters.
 */
export function decodeNulTerminatedUtf8(bytes: Uint8Array): string {
  let end = bytes.length;
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] === 0) {
      end = i;
      break;
    }
  }
  if (end === 0) {
    return '';
  }
  try {
    return util.TextDecoder.create('utf-8').decodeToString(bytes.slice(0, end)).trim();
  } catch (_error) {
    return '';
  }
}

/**
 * Parses a connection-configuration read response.
 *
 * `decrypt` must be the LSS Decipher bound to the session context produced by a
 * completed authentication; it is applied to the 32-byte SSID and the 64-byte
 * password fields exactly as the official client does. Passing a decryptor that
 * fails makes this return null instead of yielding a garbage SSID, so a
 * half-authenticated session can never be mistaken for a successful read.
 *
 * @param payload raw characteristic value (flag + encrypted fields)
 * @param decrypt LSS decipher over a whole field, or null to reject the read
 */
export function parseLssConnectionConfiguration(payload: Uint8Array,
  decrypt: (encrypted: Uint8Array) => Uint8Array | null): NikonLssConnectionConfiguration | null {
  if (payload.length < 1) {
    return null;
  }
  const flags = payload[0];
  const result: NikonLssConnectionConfiguration = {
    hasWifiSetting: (flags & LSS_FLAG_WIFI) !== 0,
    hasBluetoothSetting: (flags & LSS_FLAG_BLUETOOTH) !== 0,
    ssid: '',
    password: '',
    security: NikonLssEncryptMode.UNDEFINED,
    sppMaxDataLength: 0,
  };
  let offset = 1;
  if (result.hasWifiSetting) {
    const needed = offset + LSS_SSID_BYTES + LSS_PASSWORD_BYTES + 1;
    if (payload.length < needed) {
      return null;
    }
    const encryptedSsid = payload.slice(offset, offset + LSS_SSID_BYTES);
    offset += LSS_SSID_BYTES;
    const encryptedPassword = payload.slice(offset, offset + LSS_PASSWORD_BYTES);
    offset += LSS_PASSWORD_BYTES;
    result.security = (payload[offset] << 24) >> 24;
    offset += 1;
    const plainSsid = decrypt(encryptedSsid);
    const plainPassword = decrypt(encryptedPassword);
    if (plainSsid === null || plainPassword === null) {
      return null;
    }
    result.ssid = decodeNulTerminatedUtf8(plainSsid);
    result.password = decodeNulTerminatedUtf8(plainPassword);
  }
  if (result.hasBluetoothSetting) {
    if (payload.length < offset + 4) {
      return null;
    }
    // Little-endian, matching the ByteBuffer order the official parser sets.
    result.sppMaxDataLength = (payload[offset] | (payload[offset + 1] << 8) |
      (payload[offset + 2] << 16) | (payload[offset + 3] << 24)) >>> 0;
  }
  return result;
}

/**
 * The LSS authentication round sequence, as recovered from the official
 * client's `bleclient/a;->lssAuthProc([B)Z`.
 *
 * The *sequence* below is confirmed; the internals of `stage1`, `stage3` and
 * `generateKey` are native and are supplied by `NikonLssCrypto`'s handshake
 * layer. Note that the camera drives stages 2 and 4: the native `Stage2nd` and
 * `Stage4th` entry points are never called from Java (all eight `jniLsSec`
 * cross-references live in one class and pass `false` as the last argument), so
 * the phone only ever emits stage 1 and stage 3 frames.
 */
export interface NikonLssHandshakeOps {
  /** Seeds the native RNG. The official client passes the wall clock in
   * milliseconds truncated to an int. */
  init(seed: number): void;
  /** Produces the phone's stage-1 nonce. */
  stage1(): Uint8Array | null;
  /** Produces the stage-3 device id from the camera's nonce, the phone's own
   * nonce and the camera's device id. */
  stage3(cameraNonce: Uint8Array, phoneNonce: Uint8Array, cameraDeviceId: Uint8Array): Uint8Array | null;
  /** Completes the handshake. Must return 0; anything else is a hard failure. */
  generateKey(cameraDeviceId: Uint8Array, phoneDeviceId: Uint8Array): number;
  /** Decrypts one credential field with the established session key. */
  decipher(input: Uint8Array): Uint8Array | null;
}
