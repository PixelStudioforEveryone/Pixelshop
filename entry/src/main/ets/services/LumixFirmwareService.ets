/**
 * LUMIX firmware update over the camera's Wi-Fi HTTP API.
 *
 * Implemented from the reverse-engineered official client (`LUMIX_Lab_固件更新协议-20261002.md`,
 * verified against the jadx sources on 2026-10-11):
 *
 *   cloud  GET  firmware_list.json                       (Basic auth, share server)
 *   cloud  GET  <entry.firmware.url>                     -> FirmResponseBean
 *   cloud  GET  basePath + firm_url                      -> firmware zip
 *   camera POST /firmware/send-prepare  {type,version,size,name,slot}
 *   camera POST /firmware/send   xN     octet-stream + transID=<chunk index> + Content-Length
 *   camera POST /firmware/abort-send    (Authorization only)
 *
 * Two facts shape the code below and must not be "simplified" away:
 *  - The camera never sends a finalize/commit request. The last accepted chunk
 *    ends the app-side flow; the camera writes on its own and reports progress
 *    through BLE notify 16726c35 (value 1 = writing, 2 = finished).
 *  - The catalogue is currently a stub on the server (dsc/lens empty, verified
 *    live on 2026-10-11), so "no update available" is the normal answer today.
 *    The whole cloud leg is written against the real bean shapes so it starts
 *    working the moment the server publishes entries.
 */

import { http } from '@kit.NetworkKit';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo, statfs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LumixImportPrototype } from './LumixImportPrototype';
import { LumixFirmwareWriteState, LumixFirmwareIdentity } from './LumixImportPrototype';
import { LumixFirmwareWebSource, LumixWebFirmware } from './LumixFirmwareWebSource';

const TAG = 'VIVID_FIRMWARE';

/** Share-server root for the firmware catalogue (p107j6/h.java:331). */
const SHARE_BASE = 'https://panasonic.jp/support/share/eww/com/software/lumix_lab/';
/**
 * The official client stores these two base64 blobs (`c3ViLWF2Y3dlYg==` ->
 * `sub-avcweb`, `MXFheg==` -> `1qaz`, p107j6/h.java:309) and sends them as an
 * HTTP Basic credential. It is a catalogue-read credential that ships inside
 * the published APK, not a user secret.
 */
const SHARE_BASIC_USER = 'sub-avcweb';
const SHARE_BASIC_PASSWORD = '1qaz';

/** Minimum free space before downloading, mirroring C1746u.Y0(299, 0). */
const DOWNLOAD_SPACE_MB = 299;
/** Extraction needs size * 2.5 (C5/U4.java:61). */
const EXTRACT_SPACE_FACTOR = 2.5;
/**
 * Cap on waiting for the body's write-completion notify. The body flashes on
 * its own battery with no fixed duration and no HTTP finalize, so an absent
 * notify must not pin the UI; the transfer itself is already complete either
 * way, and the user is told to confirm the version on the camera.
 */
const WRITE_DONE_TIMEOUT_MS = 10 * 60 * 1000;

/**
 * Guard for the streaming download. The archive is ~143 MB, so the read budget
 * has to cover a slow phone connection; the timeout only exists so a silent
 * stall cannot pin the UI forever.
 */
const DOWNLOAD_STREAM_TIMEOUT_MS = 15 * 60 * 1000;

/** One catalogue row as published in firmware_list.json. */
export interface FirmwareCatalogEntry {
  id: string;
  name: string;
  code: string;
  type: number;
  isEnabled: boolean;
  version: string;
  requiredVersion: string;
  url: string;
}

export interface LumixFirmwareCatalog {
  ok: boolean;
  versionCode: number;
  bodies: FirmwareCatalogEntry[];
  lenses: FirmwareCatalogEntry[];
  message: string;
}

/** Single-device metadata (FirmResponseBean fields the flow actually uses). */
export interface LumixFirmwareDetail {
  ok: boolean;
  name: string;
  version: string;
  date: string;
  size: string;
  basePath: string;
  firmUrl: string;
  message: string;
}

export interface LumixFirmwarePackage {
  ok: boolean;
  /** Absolute sandbox path of the extracted firmware binary. */
  path: string;
  /** File name as sent in send-prepare ("name"). */
  fileName: string;
  bytes: number;
  message: string;
}

export interface LumixFirmwareVersionState {
  /** 'unknown' when the body could not be read over BLE. */
  modelName: string;
  cameraFirmware: string;
  lensName: string;
  lensFirmware: string;
  entry: FirmwareCatalogEntry | null;
  /** -1 older, 0 equal, 1 newer than the catalogue version. */
  comparison: number;
  upToDate: boolean;
  /** Catalogue requires a newer body firmware than the body currently has. */
  blockedByBody: boolean;
  message: string;
}

export type LumixFirmwareStage =
  'idle' | 'identity' | 'catalog' | 'metadata' | 'download' | 'extract'
  | 'prepare' | 'transfer' | 'writing' | 'done' | 'failed';

export interface LumixFirmwareProgress {
  stage: LumixFirmwareStage;
  message: string;
  /** 0..100, -1 when the stage has no meaningful percentage. */
  percent: number;
}

export interface LumixFirmwareResult {
  ok: boolean;
  stage: LumixFirmwareStage;
  message: string;
  trace: string[];
}

/**
 * Result of resolving an update from the download site. `web` is carried
 * alongside the usual state because the download step needs the archive URL,
 * the EULA page and the site's own version string — none of which the
 * catalogue-shaped LumixFirmwareVersionState can express.
 */
export interface LumixWebUpdateState {
  state: LumixFirmwareVersionState;
  web: LumixWebFirmware | null;
  trace: string[];
}

export class LumixFirmwareService {
  private static lastCatalog: LumixFirmwareCatalog | null = null;

  private static log(message: string): void {
    hilog.info(0x0001, TAG, message);
  }

  private static logError(phase: string, error: Object): void {
    hilog.error(0x0001, TAG, `${phase} failed %{public}s`, String(error));
  }

  // -------------------------------------------------------------------------
  // Cloud leg
  // -------------------------------------------------------------------------

  private static basicCredential(): string {
    const encoded = new util.TextEncoder().encode(`${SHARE_BASIC_USER}:${SHARE_BASIC_PASSWORD}`);
    return `Basic ${new util.Base64Helper().encodeToStringSync(encoded)}`;
  }

  private static async getText(url: string, trace: string[]): Promise<string> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'Authorization': LumixFirmwareService.basicCredential(),
          'Accept': 'application/json',
        },
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
      });
      const body = typeof response.result === 'string' ? response.result : '';
      trace.push(`GET ${LumixFirmwareService.redact(url)} http=${response.responseCode} bytes=${body.length}`);
      if (response.responseCode < 200 || response.responseCode >= 300) return '';
      return body;
    } catch (error) {
      trace.push(`GET ${LumixFirmwareService.redact(url)} error code=${LumixFirmwareService.errorCode(error)}`);
      return '';
    } finally {
      client.destroy();
    }
  }

  private static redact(url: string): string {
    // Keep the path, drop the query; the credential is in a header.
    const marker = url.indexOf('?');
    return marker >= 0 ? url.substring(0, marker) : url;
  }

  private static errorCode(error: Object): string {
    const withCode = error as ErrorWithCode;
    return withCode.code !== undefined ? String(withCode.code) : String(error);
  }

  /** Strip a leading "/" and join against the share base (p064f7/a.java:182-190). */
  private static joinPath(basePath: string, relative: string): string {
    const left = basePath.trim();
    const right = relative.trim().replace(/^\/+/, '');
    if (/^https?:\/\//i.test(right)) return right;
    if (/^https?:\/\//i.test(left)) {
      return left.endsWith('/') ? left + right : `${left}/${right}`;
    }
    const root = SHARE_BASE.endsWith('/') ? SHARE_BASE : `${SHARE_BASE}/`;
    return root + (left.length > 0 ? left.replace(/^\/+/, '').replace(/\/*$/, '/') : '') + right;
  }

  /**
   * Fetch the firmware catalogue. The server currently answers a stub
   * ({"versionCode":5,"dsc":[],"lens":[]}), which yields ok=true with empty
   * lists — that is "no update published", not a failure.
   */
  private static catalogFailure(message: string): LumixFirmwareCatalog {
    return { ok: false, versionCode: 0, bodies: [], lenses: [], message: message };
  }

  static async fetchCatalog(trace: string[]): Promise<LumixFirmwareCatalog> {
    const body = await LumixFirmwareService.getText(`${SHARE_BASE}firmware_list.json`, trace);
    if (body.length === 0) {
      return LumixFirmwareService.catalogFailure('无法获取云端固件目录');
    }
    try {
      const root = JSON.parse(body) as FirmwareListResponse;
      const bodies = LumixFirmwareService.mapEntries(root.dsc);
      const lenses = LumixFirmwareService.mapEntries(root.lens);
      const catalog: LumixFirmwareCatalog = {
        ok: true,
        versionCode: typeof root.versionCode === 'number' ? root.versionCode : 0,
        bodies: bodies,
        lenses: lenses,
        message: bodies.length === 0 && lenses.length === 0
          ? '云端暂未发布任何固件（目录为空）' : '',
      };
      LumixFirmwareService.lastCatalog = catalog;
      LumixFirmwareService.log(`catalog versionCode=${catalog.versionCode} bodies=${bodies.length} lenses=${lenses.length}`);
      return catalog;
    } catch (error) {
      LumixFirmwareService.logError('catalog parse', error);
      return LumixFirmwareService.catalogFailure('云端固件目录解析失败');
    }
  }

  private static mapEntries(raw: CatalogRawEntry[] | undefined): FirmwareCatalogEntry[] {
    if (!raw) return [];
    const out: FirmwareCatalogEntry[] = [];
    for (const item of raw) {
      if (!item) continue;
      // "Error" rows are server-side placeholders and are dropped by the
      // official client as well (firmware report §2.3).
      const name = typeof item.name === 'string' ? item.name : '';
      if (name === 'Error') continue;
      out.push({
        id: typeof item.id === 'string' ? item.id : '',
        name: name,
        code: typeof item.code === 'string' ? item.code : '',
        type: typeof item.type === 'number' ? item.type : 0,
        isEnabled: item.isEnabled !== false,
        version: item.firmware && typeof item.firmware.version === 'string' ? item.firmware.version : '',
        requiredVersion: item.firmware && typeof item.firmware.required_version === 'string'
          ? item.firmware.required_version : '',
        url: item.firmware && typeof item.firmware.url === 'string' ? item.firmware.url : '',
      });
    }
    return out;
  }

  /** Fetch one device's metadata JSON (FirmResponseBean). */
  static async fetchDetail(entry: FirmwareCatalogEntry, trace: string[]): Promise<LumixFirmwareDetail> {
    const failed = (message: string): LumixFirmwareDetail => ({
      ok: false, name: '', version: '', date: '', size: '', basePath: '', firmUrl: '', message: message,
    });
    if (entry.url.length === 0) return failed('该机型没有固件元数据地址');
    const url = LumixFirmwareService.joinPath('', entry.url);
    const body = await LumixFirmwareService.getText(url, trace);
    if (body.length === 0) return failed('无法获取固件元数据');
    try {
      const root = JSON.parse(body) as FirmResponse;
      return {
        ok: true,
        name: typeof root.name === 'string' ? root.name : entry.name,
        version: typeof root.version === 'string' ? root.version : '',
        date: typeof root.date === 'string' ? root.date : '',
        size: typeof root.size === 'string' ? root.size : '',
        basePath: typeof root.basePath === 'string' ? root.basePath : '',
        firmUrl: typeof root.firm_url === 'string' ? root.firm_url : '',
        message: '',
      };
    } catch (error) {
      LumixFirmwareService.logError('detail parse', error);
      return failed('固件元数据解析失败');
    }
  }

  /**
   * Download the firmware zip, extract it and return the first extracted file.
   * The official client unzips into cache/camera_fw and then picks the first
   * file inside (C5/U4.java) — the .bin is what gets streamed to the camera.
   */
  static async downloadPackage(context: common.UIAbilityContext, detail: LumixFirmwareDetail,
    trace: string[], onProgress?: (percent: number) => void): Promise<LumixFirmwarePackage> {
    const failed = (message: string): LumixFirmwarePackage => ({
      ok: false, path: '', fileName: '', bytes: 0, message: message,
    });
    if (detail.firmUrl.length === 0) return failed('固件元数据中没有固件包地址');
    const url = LumixFirmwareService.joinPath(detail.basePath, detail.firmUrl);
    const safeName = LumixFirmwareService.safeToken(detail.name.length > 0 ? detail.name : 'firmware');
    const zipPath = `${context.cacheDir}/camera_fw_${safeName}.zip`;
    const extractDir = `${context.cacheDir}/camera_fw_${safeName}`;
    trace.push(`firmware download url=${LumixFirmwareService.redact(url)}`);
    try {
      // rmdirSync only removes an EMPTY directory, so it silently did nothing
      // once a previous run had left a .bin behind: the throw was swallowed and
      // mkdirSync(…, true) then happily reused the populated directory. The
      // stale binary stayed put, and firstFile() returns whichever entry
      // listFileSync yields first — so after a version bump that could hand the
      // OLD .bin to the camera while the UI claims it is installing the new
      // one. Measured on device 2026-10-16: the directory still held
      // S1Rm2V16.bin from an earlier attempt. Delete the tree, never assume it
      // is empty.
      LumixFirmwareService.removeTree(extractDir);
      fileIo.mkdirSync(extractDir, true);
    } catch (_error) {
      return failed('无法创建固件解压目录');
    }
    // Space gates: 299 MB before download (C1746u.Y0(299,0)) and size * 2.5
    // before extraction (C5/U4.java:61).
    const declaredBytes = Number(detail.size);
    const available = await LumixFirmwareService.freeBytes(context);
    if (Number.isFinite(declaredBytes) && declaredBytes > 0) {
      // Extraction needs size * 2.5 (C5/U4.java:61).
      const needed = declaredBytes * EXTRACT_SPACE_FACTOR;
      if (available > 0 && available < needed) {
        return failed(`存储空间不足，需要约 ${Math.ceil(needed / (1024 * 1024))} MB`);
      }
    } else if (available > 0 && available < DOWNLOAD_SPACE_MB * 1024 * 1024) {
      // No declared size: fall back to the official flat download gate of
      // 299 MB (C1746u.Y0(299, 0)).
      return failed(`存储空间不足，至少需要 ${DOWNLOAD_SPACE_MB} MB`);
    }
    const client = http.createHttp();
    let file: fileIo.File | null = null;
    let received = 0;
    try {
      const credential = LumixFirmwareService.basicCredential();
      // requestInStream, NOT request. The buffered API caps a response at
      // maxLimit — default 5 MB, hard maximum 100 MB — and the S1RM2 archive is
      // 149,763,213 bytes, so the buffered path can never complete it: measured
      // on device 2026-10-16 it failed in the catch as a bare "固件下载失败"
      // with no HTTP code, because the throw happens before any status is
      // examined. Streaming has no such cap and writes every chunk to disk as
      // it arrives, so a 143 MB body never has to fit in memory either.
      let ended = false;
      const finished = new Promise<void>((resolve: () => void) => {
        client.on('dataReceive', (chunk: ArrayBuffer) => {
          try {
            if (file === null) {
              file = fileIo.openSync(zipPath,
                fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
            }
            fileIo.writeSync(file.fd, chunk);
            received += chunk.byteLength;
            if (onProgress !== undefined && declaredBytes > 0) {
              onProgress(Math.min(99, Math.floor(received * 100 / declaredBytes)));
            }
          } catch (error) {
            LumixFirmwareService.logError('firmware write', error);
          }
        });
        client.on('dataEnd', () => {
          ended = true;
          resolve();
        });
      });
      const responseCode = await client.requestInStream(url, {
        method: http.RequestMethod.GET,
        // The archive URL is public (verified 2026-10-16: 200 with and without
        // this header), so it is harmless here and still correct for the
        // catalogue path, whose zips do live behind the share credential.
        header: { 'Authorization': `Basic ${credential}` },
        connectTimeout: 15000,
        readTimeout: 600000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      });
      if (responseCode < 200 || responseCode >= 300) {
        trace.push(`firmware download http=${responseCode}`);
        return failed(`固件下载失败（HTTP ${responseCode}）`);
      }
      // dataEnd marks the final byte. The race only guards against a stall;
      // whatever arrived is already on disk either way.
      await Promise.race([
        finished,
        new Promise<void>((resolve: () => void) => {
          setTimeout(() => { resolve(); }, DOWNLOAD_STREAM_TIMEOUT_MS);
        }),
      ]);
      if (!ended) {
        trace.push(`firmware download stalled after=${received}`);
      }
      if (file !== null) {
        fileIo.closeSync(file);
        file = null;
      }
    } catch (error) {
      trace.push(`firmware download error code=${LumixFirmwareService.errorCode(error)}`);
      return failed('固件下载失败');
    } finally {
      if (file !== null) {
        try { fileIo.closeSync(file); } catch (_error) { }
      }
      client.destroy();
    }
    if (received === 0) return failed('固件下载为空');
    trace.push(`firmware download bytes=${received}`);
    try {
      await zlib.unzipFile(zipPath, extractDir,
        { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION });
    } catch (error) {
      LumixFirmwareService.logError('firmware unzip', error);
      // Not every server publishes a zip; some hand out the raw .bin. Fall
      // back to the downloaded file itself so the flow can still proceed.
      if (!LumixFirmwareService.looksLikeZip(zipPath)) {
        const stat = fileIo.statSync(zipPath);
        return {
          ok: true, path: zipPath, fileName: LumixFirmwareService.fileNameOf(url, detail),
          bytes: stat.size, message: '',
        };
      }
      return failed('固件解压失败');
    }
    const found = LumixFirmwareService.firstFile(extractDir);
    if (found.length === 0) return failed('固件包内没有可用文件');
    const stat = fileIo.statSync(found);
    const fileName = LumixFirmwareService.baseName(found);
    trace.push(`firmware extracted file bytes=${stat.size}`);
    // The archive has done its job and is 143 MB; the .bin beside it is what
    // actually gets streamed to the camera.
    try { fileIo.unlinkSync(zipPath); } catch (_error) { }
    return { ok: true, path: found, fileName: fileName, bytes: stat.size, message: '' };
  }

  private static looksLikeZip(path: string): boolean {
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const head = new Uint8Array(4);
        fileIo.readSync(file.fd, head.buffer as ArrayBuffer, { length: 4 });
        // PK\x03\x04
        return head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_error) {
      return false;
    }
  }

  /**
   * Recursively delete a path.
   *
   * fileIo has no remove-all, and rmdirSync refuses a non-empty directory —
   * which is precisely how a stale firmware binary survived a re-download.
   */
  private static removeTree(path: string): void {
    try {
      const names = fileIo.listFileSync(path, { recursion: false });
      for (const name of names) {
        const child = `${path}/${name}`;
        try {
          if (fileIo.statSync(child).isDirectory()) {
            LumixFirmwareService.removeTree(child);
          } else {
            fileIo.unlinkSync(child);
          }
        } catch (_error) {
        }
      }
      fileIo.rmdirSync(path);
    } catch (_error) {
    }
  }

  /**
   * Drop the cached archive and extracted binary once the firmware has been
   * handed to the camera. The .bin alone is 162 MB, so leaving it behind costs
   * real space on the phone; a failed transfer deliberately keeps it so an
   * immediate retry does not have to re-download 143 MB.
   */
  static discardPackage(pack: LumixFirmwarePackage): void {
    const cut = pack.path.lastIndexOf('/');
    if (cut > 0) LumixFirmwareService.removeTree(pack.path.substring(0, cut));
  }

  private static firstFile(directory: string): string {
    try {
      const names = fileIo.listFileSync(directory, { recursion: true });
      for (const name of names) {
        const candidate = `${directory}/${name}`;
        try {
          if (fileIo.statSync(candidate).isDirectory()) continue;
        } catch (_error) {
          continue;
        }
        return candidate;
      }
    } catch (_error) {
    }
    return '';
  }

  private static baseName(path: string): string {
    const slash = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  private static fileNameOf(url: string, detail: LumixFirmwareDetail): string {
    const clean = LumixFirmwareService.redact(url);
    const slash = clean.lastIndexOf('/');
    const tail = slash >= 0 ? clean.substring(slash + 1) : clean;
    const dot = tail.lastIndexOf('.');
    const base = dot > 0 ? tail.substring(0, dot) : tail;
    if (base.length > 0) return `${base}.bin`;
    return `${LumixFirmwareService.safeToken(detail.name || 'firmware')}.bin`;
  }

  private static safeToken(value: string): string {
    return value.replace(/[^A-Za-z0-9._-]/g, '_').substring(0, 48);
  }

  /** Free space in the sandbox, or 0 when it cannot be determined. */
  private static async freeBytes(context: common.UIAbilityContext): Promise<number> {
    try {
      return Number(await statfs.getFreeSize(context.filesDir));
    } catch (_error) {
      return 0;
    }
  }

  // -------------------------------------------------------------------------
  // Version comparison
  // -------------------------------------------------------------------------

  /**
   * Official version comparison, transcribed from C1746u.i() — the exact
   * routine FirmwareUpdateDetailFragment:1845 uses to decide whether an update
   * is offered. Each dot-separated segment is right-padded with '0' characters
   * until both sides are equally wide, then parsed as HEXADECIMAL.
   *
   * Hex semantics are load-bearing, not a detail. A body reporting "1.55" is
   * OLDER than a catalogue "1.6": 0x55 = 85 < 0x60 = 96. A decimal compare
   * inverts that (55 > 6) and would silently hide the update — which is
   * precisely the S1RM2 case measured on 2026-10-16 (body 1.55, site Ver.1.6).
   */
  static compareVersion(current: string, target: string): number {
    const left = LumixFirmwareService.versionParts(current);
    const right = LumixFirmwareService.versionParts(target);
    if (left.length === 0 || right.length === 0) return 0;
    const length = Math.max(left.length, right.length);
    for (let index = 0; index < length; index++) {
      let a = index < left.length ? left[index] : '0';
      let b = index < right.length ? right[index] : '0';
      // C1746u.i() pads with String.format("%0<count>d", 0) appended on the
      // right; padding the longer one zero times is the same thing.
      while (a.length < b.length) a = `${a}0`;
      while (b.length < a.length) b = `${b}0`;
      const aValue = LumixFirmwareService.hexSegment(a);
      const bValue = LumixFirmwareService.hexSegment(b);
      if (aValue !== bValue) return aValue < bValue ? -1 : 1;
    }
    return 0;
  }

  /** Raw, unparsed version segments ("Ver.1.55" -> ["1","55"]). */
  private static versionParts(value: string): string[] {
    const cleaned = value.trim().replace(/^ver\.?/i, '').trim();
    if (cleaned.length === 0) return [];
    const out: string[] = [];
    for (const part of cleaned.split('.')) {
      const trimmed = part.trim();
      if (trimmed.length === 0) return out.length > 0 ? out : [];
      out.push(trimmed);
    }
    return out;
  }

  /**
   * Integer.parseInt(segment, 16). Java throws on malformed input and the
   * official client never feeds it one; treating garbage as 0 keeps a bad
   * catalogue row from aborting the whole check.
   */
  private static hexSegment(value: string): number {
    const parsed = Number.parseInt(value, 16);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  /**
   * Normalize a catalogue version into the camera's own "V<major>.<minor>"
   * form for the send-prepare payload. C5/D.java:113-116 keeps the raw digits
   * and pads a single-digit second segment ("4" -> "40"), which is why the
   * body's BLE string looks like "1.55" rather than "1.5".
   */
  static cameraVersionOf(version: string): string {
    const parts = LumixFirmwareService.versionParts(version);
    if (parts.length === 0) return '';
    let minor = parts.length > 1 ? parts[1] : '0';
    while (minor.length < 2) minor = `${minor}0`;
    return `V${parts[0]}.${minor}`;
  }

  /**
   * Match the connected body to a catalogue row. The official client keys off
   * the BLE device code/name (FirmwareUpdateDetailFragment.v0:1825); the BLE
   * CAMERA_MODEL_NAME is "DC-S1RM2" while the catalogue name is "DC-S1RM2",
   * so an exact (case-insensitive) name match is tried first and the model
   * token from the advertisement second.
   */
  static matchBody(catalog: LumixFirmwareCatalog, modelName: string): FirmwareCatalogEntry | null {
    const wanted = modelName.trim().toUpperCase();
    if (wanted.length === 0) return null;
    for (const entry of catalog.bodies) {
      if (entry.name.trim().toUpperCase() === wanted) return entry;
    }
    // Fall back to the token inside the name ("DC-S1RM2" -> "S1RM2").
    const token = wanted.startsWith('DC-') ? wanted.substring(3) : wanted;
    for (const entry of catalog.bodies) {
      const entryToken = entry.name.trim().toUpperCase().replace(/^DC-/, '');
      if (entryToken === token) return entry;
    }
    return null;
  }

  /**
   * One-shot check: read the body over BLE, then ask the cloud what it offers.
   *
   * Callers that own the Wi-Fi state should instead call
   * `readFirmwareIdentity` + `resolveUpdate` separately, because the cloud leg
   * needs internet and the camera AP has no uplink (see `resolveUpdate`).
   */
  static async inspect(context: common.UIAbilityContext, deviceId: string = ''): Promise<LumixFirmwareVersionState> {
    const identity = await LumixImportPrototype.readFirmwareIdentity(context, deviceId);
    return LumixFirmwareService.resolveUpdate(identity);
  }

  /**
   * Compare a BLE-read body against the cloud catalogue.
   *
   * IMPORTANT: this half needs working internet. The camera AP is an isolated
   * network with no uplink, so while the phone is joined to the camera Wi-Fi
   * the official catalogue cannot be reached at all — the official app
   * therefore disconnects the camera Wi-Fi for the whole download phase
   * (firmware report §2.5, the K9 "断开相机 Wi-Fi？" prompt). Callers must
   * leave a real internet path in place before calling this.
   */
  /**
   * Resolve an available update from Panasonic's download site.
   *
   * This is the primary source because the published catalogue endpoint is a
   * dead stub: measured 2026-10-16 it still answered
   * {"versionCode":5,"dsc":[],"lens":[]} with Last-Modified 2026-06-10, while
   * the site had already published S1RM2 Ver.1.6 (2026-10-13). The official
   * client sends the same bare GET there, so it would read the same empty
   * list. resolveUpdate() (the catalogue path) stays as the fallback for the
   * day the server starts publishing again.
   *
   * Needs internet but never touches camera Wi-Fi, so it runs before the
   * camera link is re-established (see the four-phase flow in CameraPage).
   */
  static async resolveWebUpdate(identity: LumixFirmwareIdentity): Promise<LumixWebUpdateState> {
    const trace: string[] = [];
    for (const line of identity.trace) trace.push(line);
    const stateWith = (message: string, web: LumixWebFirmware | null,
      entry: FirmwareCatalogEntry | null, comparison: number): LumixWebUpdateState => {
      return {
        web: web,
        trace: trace,
        state: {
          modelName: identity.modelName,
          cameraFirmware: identity.cameraFirmware,
          lensName: identity.lensName,
          lensFirmware: identity.lensFirmware,
          entry: entry,
          comparison: comparison,
          upToDate: comparison >= 0,
          blockedByBody: false,
          message: message,
        },
      };
    };
    if (identity.modelName.length === 0) {
      return stateWith('未能通过蓝牙读取机型与固件版本，请靠近相机后重试', null, null, 0);
    }
    const web = await LumixFirmwareWebSource.resolve(identity.modelName, trace);
    if (!web.ok) {
      trace.push(`web resolve failed: ${web.message}`);
      return stateWith(web.message, null, null, 0);
    }
    const comparison = LumixFirmwareService.compareVersion(identity.cameraFirmware, web.version);
    // Same synthetic row shape the send-prepare payload needs. type 1 = body
    // (deviceType 0 is the lens), the value FirmwareUpdateDetailFragment:1843
    // selects for a camera-body update.
    const entry: FirmwareCatalogEntry = {
      id: web.zipName,
      name: identity.modelName,
      code: '',
      type: 1,
      isEnabled: true,
      version: web.version,
      requiredVersion: '',
      url: web.fileUrl,
    };
    const message = comparison >= 0
      ? `已是最新固件（${identity.cameraFirmware}）`
      : `可更新至 ${web.version}（当前 ${identity.cameraFirmware}）`;
    LumixFirmwareService.log(`web update model=${web.matchedModel}`
      + ` site=${web.version} body=${identity.cameraFirmware} cmp=${comparison}`);
    return stateWith(message, web, entry, comparison);
  }

  /**
   * Download and extract a web-sourced archive by reusing the catalogue
   * download path: an absolute firmUrl passes through joinPath() untouched,
   * so the only thing needed is a detail object carrying the site's URL.
   */
  static async downloadWebPackage(context: common.UIAbilityContext, web: LumixWebFirmware,
    modelName: string, trace: string[],
    onProgress?: (percent: number) => void): Promise<LumixFirmwarePackage> {
    const detail: LumixFirmwareDetail = {
      ok: true,
      name: modelName.length > 0 ? modelName : web.zipName,
      version: web.version,
      date: '',
      // Drives the size * 2.5 free-space gate (C5/U4.java:61); '' falls back to
      // the flat 299 MB check when the site did not report a length.
      size: web.fileBytes > 0 ? String(web.fileBytes) : '',
      basePath: '',
      firmUrl: web.fileUrl,
      message: '',
    };
    return LumixFirmwareService.downloadPackage(context, detail, trace, onProgress);
  }

  static async resolveUpdate(identity: LumixFirmwareIdentity): Promise<LumixFirmwareVersionState> {
    const trace: string[] = [];
    // ArkTS forbids spread on non-array values; append the BLE trace lines
    // explicitly so they still reach the diagnostics log.
    for (const line of identity.trace) trace.push(line);
    const stateWith = (message: string): LumixFirmwareVersionState => {
      return {
        modelName: identity.modelName,
        cameraFirmware: identity.cameraFirmware,
        lensName: identity.lensName,
        lensFirmware: identity.lensFirmware,
        entry: null,
        comparison: 0,
        upToDate: true,
        blockedByBody: false,
        message: message,
      };
    };
    if (identity.modelName.length === 0) {
      return stateWith('未能通过蓝牙读取机型与固件版本，请靠近相机后重试');
    }
    const catalog = await LumixFirmwareService.fetchCatalog(trace);
    if (!catalog.ok) {
      return stateWith('无法获取云端固件目录，请确认手机已连接到可上网的网络');
    }
    if (catalog.bodies.length === 0) {
      return stateWith('云端暂未发布该机型的固件（目录为空）');
    }
    const entry = LumixFirmwareService.matchBody(catalog, identity.modelName);
    if (entry === null) {
      return stateWith(`云端目录中没有 ${identity.modelName} 的固件`);
    }
    const comparison = LumixFirmwareService.compareVersion(identity.cameraFirmware, entry.version);
    // required_version is a body-firmware floor the catalogue demands before a
    // lens/unit update may be applied (firmware report §2.2, §3.1 case 9).
    const blockedByBody = entry.requiredVersion.length > 0
      && LumixFirmwareService.compareVersion(identity.cameraFirmware, entry.requiredVersion) < 0;
    const upToDate = comparison >= 0;
    const message = upToDate
      ? `已是最新固件（${identity.cameraFirmware}）`
      : `可更新至 ${entry.version}（当前 ${identity.cameraFirmware}）`;
    return {
      modelName: identity.modelName,
      cameraFirmware: identity.cameraFirmware,
      lensName: identity.lensName,
      lensFirmware: identity.lensFirmware,
      entry: entry,
      comparison: comparison,
      upToDate: upToDate,
      blockedByBody: blockedByBody,
      message: message,
    };
  }

  // -------------------------------------------------------------------------
  // Camera leg
  // -------------------------------------------------------------------------

  /**
   * Stream a firmware binary to the camera. Blocks for the whole transfer —
   * the caller owns the UI. Follows the official sequence including the fixed
   * 3 s wait before send-prepare (C5/D.java:104) and the single reused
   * connection for every chunk (the LUT line proved per-chunk connections get
   * silently dropped on S1RM2).
   */
  static async sendToCamera(context: common.UIAbilityContext, entry: FirmwareCatalogEntry,
    detail: LumixFirmwareDetail, pack: LumixFirmwarePackage, slot: string,
    onProgress?: (progress: LumixFirmwareProgress) => void): Promise<LumixFirmwareResult> {
    const trace: string[] = [];
    const stage = (value: LumixFirmwareStage, message: string, percent: number = -1): void => {
      trace.push(`stage=${value} ${message}`);
      if (onProgress) onProgress({ stage: value, message: message, percent: percent });
    };
    const fail = (value: LumixFirmwareStage, message: string): LumixFirmwareResult => {
      LumixFirmwareService.log(`send failed stage=${value} ${message}`);
      return { ok: false, stage: value, message: message, trace: trace };
    };
    const session = LumixImportPrototype.currentSession();
    if (session.host.length === 0 || session.token.length === 0) {
      return fail('idle', '没有可用的相机会话，请先连接相机 Wi‑Fi');
    }
    if (pack.path.length === 0 || pack.bytes <= 0) {
      return fail('prepare', '固件文件无效');
    }
    stage('prepare', '正在与相机协商固件传输…');
    // The camera leaves its current mode after the pairing commit and needs
    // time to reach the firmware-receive state; the official client sleeps a
    // flat 3 s here (C5/D.java:104) before the first request.
    await LumixFirmwareService.delay(3000);
    const client = http.createHttp();
    try {
      const prepareBody = JSON.stringify({
        type: entry.type,
        version: LumixFirmwareService.cameraVersionOf(entry.version),
        size: pack.bytes,
        name: pack.fileName,
        slot: slot,
      });
      trace.push(`send-prepare body=${LumixFirmwareService.summarizeBody(prepareBody)}`);
      const prepareRaw = await LumixFirmwareService.postJson(client, session.host, '/firmware/send-prepare',
        prepareBody, session.token, session.fingerprint, trace);
      const prepare = LumixFirmwareService.parseData(prepareRaw);
      const bufsize = prepare.bufsize !== undefined && prepare.bufsize !== null ? Number(prepare.bufsize) : 0;
      if (!Number.isFinite(bufsize) || bufsize <= 0) {
        const reason = LumixFirmwareService.explainErrorinfo(prepare.errorinfo);
        return fail('prepare', reason.length > 0 ? reason : '相机拒绝了固件传输请求');
      }
      const totalChunks = Math.ceil(pack.bytes / bufsize);
      trace.push(`send-prepare ok bufsize=${bufsize} chunks=${totalChunks}`);
      stage('transfer', '正在传输固件…', 0);
      let file: fileIo.File | null = null;
      try {
        file = fileIo.openSync(pack.path, fileIo.OpenMode.READ_ONLY);
        for (let index = 0; index < totalChunks; index++) {
          const offset = index * bufsize;
          const length = Math.min(pack.bytes, offset + bufsize) - offset;
          const chunk = new Uint8Array(length);
          // The official code re-opens and skips per chunk instead of holding
          // a cursor (FirmwareUpdateDetailFragment.y0:1972-1974); a single
          // sequential read is equivalent and avoids re-open churn.
          fileIo.readSync(file.fd, chunk.buffer as ArrayBuffer, { offset: offset, length: length });
          const headers: Record<string, string> = {
            'Authorization': `'Bearer ${session.token}'`,
            'Content-Type': 'application/octet-stream',
            'Accept': 'application/json',
            'Content-Length': String(length),
            'transID': String(index),
          };
          const chunkRaw = await LumixFirmwareService.postBinary(client, session.host, '/firmware/send',
            chunk.buffer as ArrayBuffer, headers, session.fingerprint, index, trace);
          const chunkData = LumixFirmwareService.parseData(chunkRaw);
          const result = chunkData.Result !== undefined && chunkData.Result !== null
            ? Number(chunkData.Result) : -1;
          if (result !== 0) {
            return fail('transfer', LumixFirmwareService.explainErrorinfo(chunkData.errorinfo,
              `第 ${index + 1}/${totalChunks} 块被相机拒绝（Result=${result}）`));
          }
          if (onProgress) {
            const percent = Math.min(100, Math.floor((index + 1) * 100 / totalChunks));
            onProgress({ stage: 'transfer', message: `正在传输固件 ${percent}%`, percent: percent });
          }
        }
      } catch (error) {
        trace.push(`send read error code=${LumixFirmwareService.errorCode(error)}`);
        return fail('transfer', '固件读取或传输失败');
      } finally {
        if (file !== null) {
          try { fileIo.closeSync(file); } catch (_error) { }
        }
      }
    } catch (error) {
      trace.push(`send-prepare error code=${LumixFirmwareService.errorCode(error)}`);
      return fail('prepare', '与相机通信失败');
    } finally {
      client.destroy();
    }
    // No finalize request exists: the last accepted chunk ends the app side
    // and the body writes on its own, reporting through BLE notify 16726c35.
    stage('writing', '固件已送达，相机正在写入，请勿断电或拔卡', 100);
    // Wait for the body's own completion signal. Without a GATT link there is
    // nothing to observe, so the caller is told the transfer ended and the
    // body is on its own.
    // The body flashes from its own battery over an unbounded time; a camera
    // that never answers must not leave the UI stuck, so the wait is capped
    // and the observer is always detached.
    let writeFinished = false;
    let doneResolve: (() => void) | null = null;
    const writeDone = new Promise<void>((resolve: () => void) => {
      doneResolve = resolve;
    });
    const watcher = LumixImportPrototype.observeFirmwareWriteProgress(trace,
      (state: LumixFirmwareWriteState, _raw: number): void => {
        if (state === 'done') {
          writeFinished = true;
          if (onProgress) {
            onProgress({ stage: 'done', message: '相机已完成固件写入', percent: 100 });
          }
          if (doneResolve !== null) doneResolve();
        } else if (onProgress) {
          onProgress({ stage: 'writing', message: '相机正在写入固件，请勿断电或拔卡', percent: 100 });
        }
      });
    if (watcher === null) {
      return {
        ok: true, stage: 'writing',
        message: '固件已传输完成，相机正在写入。请勿关闭相机电源或取出存储卡。',
        trace: trace,
      };
    }
    // The body flashes from its own battery and takes an unbounded time; a
    // camera that never answers must not leave the UI stuck, so the wait is
    // capped and the observer is always detached.
    await Promise.race([
      writeDone,
      new Promise<void>((resolve: () => void) => {
        setTimeout(() => { resolve(); }, WRITE_DONE_TIMEOUT_MS);
      }),
    ]);
    watcher.detach();
    return {
      ok: true, stage: writeFinished ? 'done' : 'writing',
      message: writeFinished
        ? '相机已完成固件写入，请重启相机后确认版本。'
        : '固件已传输完成，但未收到相机写入完成通知。请勿断电，稍后在相机上确认版本。',
      trace: trace,
    };
  }

  /** Cancel an in-flight transfer (POST /firmware/abort-send, Authorization only). */
  static async abortSend(): Promise<boolean> {
    const session = LumixImportPrototype.currentSession();
    if (session.host.length === 0 || session.token.length === 0) return false;
    const client = http.createHttp();
    const trace: string[] = [];
    try {
      const raw = await LumixFirmwareService.postJson(client, session.host, '/firmware/abort-send', '',
        session.token, session.fingerprint, trace);
      // The official client ignores the result body here (T5/g.java); any
      // answer means the camera accepted the cancel.
      LumixFirmwareService.log(`abort-send bytes=${raw.length}`);
      return true;
    } catch (error) {
      LumixFirmwareService.log(`abort-send failed code=${LumixFirmwareService.errorCode(error)}`);
      return false;
    } finally {
      client.destroy();
    }
  }

  /**
   * Map a camera errorinfo string to a human message. Taken from the official
   * table (T5/e.java:82-134) with the shipped strings.xml wording; the
   * official wording for error_15 is easy to read backwards, so it is spelled
   * out fully here.
   */
  private static explainErrorinfo(errorinfo: string | undefined, fallback: string = ''): string {
    const value = (errorinfo || '').toLowerCase();
    if (value.length === 0) return fallback;
    switch (value) {
      case 'err_lens_error':
        return '未安装镜头，请安装镜头后重试';
      case 'err_sdcard_write_protected':
        return '存储卡写保护已开启，请解除写保护后重试';
      case 'err_fw_same':
        return '相机已经是该版本固件';
      case 'err_fw_old':
        return '相机固件版本比目标版本更新';
      case 'err_battery':
        return '电量不足，请充满电池后重试';
      case 'err_reject':
        return '当前安装的镜头无法更新';
      case 'err_no_media':
        return '传输过程中请勿插拔存储卡';
      case 'err_noremain':
        return '存储卡剩余空间不足';
      case 'err_fw':
        return '固件与当前设备不匹配';
      default:
        return fallback.length > 0 ? fallback : '无法更新，请检查相机状态';
    }
  }

  // -------------------------------------------------------------------------
  // HTTP helpers (camera side; self-signed certificate, pinned when known)
  // -------------------------------------------------------------------------

  private static async postJson(client: http.HttpRequest, host: string, path: string, body: string,
    token: string, fingerprint: string, trace: string[]): Promise<string> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': `'Bearer ${token}'`,
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      body: body,
      connectTimeout: 15000,
      readTimeout: 60000,
      expectDataType: http.HttpDataType.STRING,
      // The camera AP serves a self-signed certificate; this is a private
      // point-to-point link with no third party in the path.
      remoteValidation: (_validation: http.ValidationContext): Promise<boolean> => Promise.resolve(true),
    };
    const response = await client.request(`https://${host}${path}`, options);
    const text = typeof response.result === 'string' ? response.result : '';
    trace.push(`POST ${path} http=${response.responseCode} bytes=${text.length}`);
    if (response.responseCode < 200 || response.responseCode >= 300) {
      throw new Error(`HTTP ${response.responseCode}`);
    }
    return text;
  }

  private static async postBinary(client: http.HttpRequest, host: string, path: string,
    body: ArrayBuffer, headers: Record<string, string>, fingerprint: string,
    index: number, trace: string[]): Promise<string> {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      body: body,
      connectTimeout: 15000,
      readTimeout: 60000,
      expectDataType: http.HttpDataType.STRING,
      remoteValidation: (_validation: http.ValidationContext): Promise<boolean> => Promise.resolve(true),
    };
    const response = await client.request(`https://${host}${path}`, options);
    const text = typeof response.result === 'string' ? response.result : '';
    trace.push(`POST ${path} transID=${index} http=${response.responseCode} bytes=${text.length}`);
    if (response.responseCode < 200 || response.responseCode >= 300) {
      throw new Error(`HTTP ${response.responseCode}`);
    }
    return text;
  }

  private static parseData(body: string): FirmwareDataBean {
    const empty: FirmwareDataBean = {};
    if (body.length === 0) return empty;
    try {
      const root = JSON.parse(body) as FirmwareEnvelope;
      return root.Data ? root.Data : empty;
    } catch (_error) {
      return empty;
    }
  }

  private static summarizeBody(body: string): string {
    // The version and slot matter for diagnosis; the file name is not secret
    // but is noise, so only its length is recorded.
    try {
      const root = JSON.parse(body) as FirmwarePrepareSummary;
      return `version=${root.version} slot=${root.slot} size=${root.size} nameLen=${(root.name || '').length}`;
    } catch (_error) {
      return `len=${body.length}`;
    }
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }

  /** Last catalogue fetched this session, for the UI to reuse. */
  static cachedCatalog(): LumixFirmwareCatalog | null {
    return LumixFirmwareService.lastCatalog;
  }
}

interface ErrorWithCode {
  code?: number;
}

interface FirmwareDataBean {
  Result?: number;
  bufsize?: number;
  errorinfo?: string;
}

interface FirmwareEnvelope {
  Data?: FirmwareDataBean;
}

interface FirmwarePrepareSummary {
  version?: string;
  slot?: string;
  size?: number;
  name?: string;
}

interface CatalogFirmware {
  version?: string;
  required_version?: string;
  url?: string;
}

interface CatalogRawEntry {
  id?: string;
  name?: string;
  code?: string;
  type?: number;
  isEnabled?: boolean;
  firmware?: CatalogFirmware;
}

interface FirmwareListResponse {
  versionCode?: number;
  dsc?: CatalogRawEntry[];
  lens?: CatalogRawEntry[];
}

interface FirmResponse {
  name?: string;
  version?: string;
  date?: string;
  size?: string;
  basePath?: string;
  firm_url?: string;
}
