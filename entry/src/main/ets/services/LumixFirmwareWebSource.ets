/**
 * Panasonic firmware catalogue, read from the public download site.
 *
 * Why this exists instead of the app's own catalogue endpoint: LUMIX Lab's
 * `firmware_list.json` is a stub on Panasonic's server. Measured live on
 * 2026-10-16 it answers `{"versionCode":5,"dsc":[],"lens":[]}` with
 * `Last-Modified: 2026-06-10`, while the download site already published
 * S1RM2 Ver.1.6 on 2026-10-13. The official client sends a bare GET plus one
 * Basic credential there (p107j6/a.java:217, p107j6/h.java:309-331), so it
 * would receive exactly the same empty list — the site is the only channel
 * that is actually current.
 *
 * The chain, verified end to end on 2026-10-16 against five bodies spanning
 * all three body categories (S1RM2, S5M2, G9M2, GH7, L10):
 *
 *   GET  download/index4.html | index.html | index2.html    body model table
 *   ->   row(model, Ver.x.y, OpenWin target)                exact model match
 *   GET  <popup>.html                                       version history
 *   ->   *_dl.html and the EULA iframe
 *   GET  <model>_dl.html
 *   ->   <form action=...> + <input name="MODEL" value="...">
 *   POST <form action>  MODEL=<zip>&submit=Accepted
 *   ->   302 Location = the firmware zip
 *
 * Four properties of that chain are load-bearing. Each was measured the hard
 * way, and "simplifying" any one of them silently breaks bodies other than
 * the one being tested:
 *
 *  - The zip name is NOT derivable. Measured: S1Rm2V16.zip, S9___V21.zip,
 *    S5m2_V37.zip, G9m2_V27.zip, GH7__V18.zip, L10__V12.zip. Separators and
 *    padding differ per model, so it must be read out of the form.
 *  - The receiving CGI is NOT constant: download_s.cgi (full-frame),
 *    download_g.cgi (Micro Four Thirds), download_compact.cgi (compact).
 *    Posting an MFT zip name to download_s.cgi answers 302 with an EMPTY
 *    Location — a silent failure — so the action must be read out of the form.
 *  - Only the body pages may be consulted. The same model names also appear on
 *    the "Others" page carrying lower, unrelated versions (GH7 reads 1.0 there
 *    against the real 1.8), so index3 and index5 are deliberately excluded.
 *  - Model matching must be exact. DC-S5M2 is a prefix of DC-S5M2X, and
 *    DC-S1M2 of DC-S1M2ES; substring matching silently offers the wrong body's
 *    firmware.
 *
 * The site is also intermittently unreliable — on 2026-10-16 the same URL
 * timed out twice and succeeded on the third attempt — so every fetch retries.
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'VIVID_FW_WEB';
const SITE_ORIGIN = 'https://av.jpn.support.panasonic.com';
const DOWNLOAD_DIR = `${SITE_ORIGIN}/support/global/cs/dsc/download/`;
const USER_AGENT = 'Mozilla/5.0 (Linux; HarmonyOS; VIVID) AppleWebKit/537.36';

/**
 * Body-firmware index pages, in probe order. The "Others" (index3) and "Lens"
 * (index5) pages are excluded on purpose — see the header note.
 */
const BODY_INDEX_PAGES: string[] = ['index4.html', 'index.html', 'index2.html'];

const FETCH_ATTEMPTS = 4;
const FETCH_RETRY_BASE_MS = 700;

/** Resolved firmware for one body, straight from Panasonic's download site. */
export interface LumixWebFirmware {
  ok: boolean;
  /** The model string exactly as the site spells it. */
  matchedModel: string;
  /** Site version, e.g. "1.6". Compare with LumixFirmwareService.compareVersion. */
  version: string;
  /** The uploaded archive name, e.g. "S1Rm2V16.zip". */
  zipName: string;
  /** Absolute URL of the firmware zip (post-EULA redirect target). */
  fileUrl: string;
  /** Content-Length of the zip, or -1 when the site did not report one. */
  fileBytes: number;
  /** Absolute URL of the EULA page the user must accept, or ''. */
  eulaUrl: string;
  message: string;
}

/** One parsed row of a body index table. */
interface WebRow {
  model: string;
  version: string;
  target: string;
}

/** The EULA form on a *_dl.html page. */
interface WebDownloadForm {
  actionUrl: string;
  zipName: string;
}

export class LumixFirmwareWebSource {
  private static log(message: string): void {
    hilog.info(0x0001, TAG, message);
  }

  /**
   * Resolve the newest published body firmware for `modelName` (the BLE
   * CAMERA_MODEL_NAME, e.g. "DC-S1RM2"). Never downloads the archive.
   */
  static async resolve(modelName: string, trace: string[]): Promise<LumixWebFirmware> {
    const failed = (message: string): LumixWebFirmware => {
      return {
        ok: false, matchedModel: '', version: '', zipName: '', fileUrl: '',
        fileBytes: -1, eulaUrl: '', message: message,
      };
    };
    const wanted = LumixFirmwareWebSource.stripPrefix(modelName);
    if (wanted.length === 0) return failed('未提供机型名，无法查询官网固件');
    let row: WebRow | null = null;
    let pageUrl = '';
    for (const page of BODY_INDEX_PAGES) {
      const url = `${DOWNLOAD_DIR}${page}`;
      const html = await LumixFirmwareWebSource.getText(url, trace);
      if (html.length === 0) {
        trace.push(`web index ${page} unreachable`);
        continue;
      }
      const rows = LumixFirmwareWebSource.parseRows(html);
      trace.push(`web index ${page} rows=${rows.length}`);
      const hit = LumixFirmwareWebSource.matchRow(rows, wanted);
      if (hit !== null) {
        row = hit;
        pageUrl = url;
        break;
      }
    }
    if (row === null) return failed(`官网固件表中没有 ${modelName}`);
    trace.push(`web row model=${row.model} version=${row.version} target=${row.target}`);
    if (row.target.length === 0) return failed('官网固件表该行没有详情页链接');
    const popupUrl = LumixFirmwareWebSource.resolveUrl(pageUrl, row.target);
    const popup = await LumixFirmwareWebSource.getText(popupUrl, trace);
    if (popup.length === 0) return failed('无法打开官网固件详情页');
    const dlHref = LumixFirmwareWebSource.firstMatch(popup, /href\s*=\s*"([^"]*_dl\.html)"/i);
    if (dlHref.length === 0) return failed('官网详情页中没有下载页链接');
    const dlUrl = LumixFirmwareWebSource.resolveUrl(popupUrl, dlHref);
    const dlPage = await LumixFirmwareWebSource.getText(dlUrl, trace);
    if (dlPage.length === 0) return failed('无法打开官网下载页');
    const form = LumixFirmwareWebSource.parseDownloadForm(dlPage);
    if (form === null) return failed('官网下载页结构无法识别（可能已改版）');
    const eulaHref = LumixFirmwareWebSource.firstMatch(dlPage, /<iframe[^>]*\ssrc\s*=\s*"([^"]+)"/i);
    const eulaUrl = eulaHref.length > 0
      ? LumixFirmwareWebSource.resolveUrl(dlUrl, eulaHref) : '';
    trace.push(`web dl page zip=${form.zipName} action=${form.actionUrl} eula=${eulaUrl.length > 0 ? 'yes' : 'no'}`);
    const fileUrl = await LumixFirmwareWebSource.acceptAndResolve(
      LumixFirmwareWebSource.resolveUrl(dlUrl, form.actionUrl), form.zipName, trace);
    if (fileUrl.length === 0) return failed('官网没有返回固件下载地址（EULA 表单未被接受）');
    const bytes = await LumixFirmwareWebSource.headBytes(fileUrl, trace);
    LumixFirmwareWebSource.log(`web resolve model=${row.model} version=${row.version} bytes=${bytes}`);
    return {
      ok: true,
      matchedModel: row.model,
      version: row.version,
      zipName: form.zipName,
      fileUrl: fileUrl,
      fileBytes: bytes,
      eulaUrl: eulaUrl,
      message: '',
    };
  }

  // -------------------------------------------------------------------------
  // HTTP
  // -------------------------------------------------------------------------

  private static async delay(ms: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }

  /** GET text with retries; the site drops connections intermittently. */
  private static async getText(url: string, trace: string[]): Promise<string> {
    for (let attempt = 1; attempt <= FETCH_ATTEMPTS; attempt++) {
      const client = http.createHttp();
      try {
        const response = await client.request(url, {
          method: http.RequestMethod.GET,
          header: { 'User-Agent': USER_AGENT, 'Accept': 'text/html,application/xhtml+xml' },
          connectTimeout: 15000,
          readTimeout: 30000,
          expectDataType: http.HttpDataType.STRING,
          maxRedirects: 3,
        });
        const body = typeof response.result === 'string' ? response.result : '';
        trace.push(`web GET ${LumixFirmwareWebSource.shortPath(url)}#${attempt} http=${response.responseCode} bytes=${body.length}`);
        if (response.responseCode >= 200 && response.responseCode < 300 && body.length > 0) return body;
      } catch (error) {
        trace.push(`web GET ${LumixFirmwareWebSource.shortPath(url)}#${attempt} error code=${LumixFirmwareWebSource.errorCode(error)}`);
      } finally {
        client.destroy();
      }
      if (attempt < FETCH_ATTEMPTS) {
        await LumixFirmwareWebSource.delay(FETCH_RETRY_BASE_MS * attempt);
      }
    }
    return '';
  }

  /**
   * Accept the EULA and read the redirect target.
   *
   * The Location has to come from the `headersReceive` event, not from the
   * request promise: setting maxRedirects to 0 does NOT mean "do not follow"
   * the way the SDK text claims ("If the value is set to 0, redirection is
   * disabled"). Measured on device 2026-10-16: 0 is taken as the *limit*, so a
   * single 302 immediately trips 2300047 "the number of redirections reaches
   * the maximum allowed" and the promise rejects. The 302 headers still arrive
   * before that, so the event carries the Location.
   *
   * Keeping maxRedirects at 0 is deliberate: the request can never run on into
   * the archive, so the worst case is a clean failure rather than pulling
   * 143 MB into memory as a string.
   */
  private static async acceptAndResolve(actionUrl: string, zipName: string,
    trace: string[]): Promise<string> {
    const client = http.createHttp();
    let location = '';
    const onHeaders = (header: Object): void => {
      if (location.length > 0) return;
      const value = LumixFirmwareWebSource.headerValue(header, 'location');
      if (value.length > 0) location = value;
    };
    client.on('headersReceive', onHeaders);
    try {
      const response = await client.request(actionUrl, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': USER_AGENT,
        },
        extraData: `MODEL=${encodeURIComponent(zipName)}&submit=Accepted`,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
        maxRedirects: 0,
      });
      const direct = LumixFirmwareWebSource.headerValue(response.header, 'location');
      const target = location.length > 0 ? location : direct;
      trace.push(`web accept ${zipName} http=${response.responseCode} location=${target.length > 0 ? 'yes' : 'no'}`);
      if (target.length === 0) return '';
      return LumixFirmwareWebSource.resolveUrl(actionUrl, target);
    } catch (error) {
      // 2300047 is the expected way this call ends when it stops at the 302.
      const code = LumixFirmwareWebSource.errorCode(error);
      trace.push(`web accept ${zipName} stopped code=${code} location=${location.length > 0 ? 'yes' : 'no'}`);
      if (location.length === 0) return '';
      return LumixFirmwareWebSource.resolveUrl(actionUrl, location);
    } finally {
      client.off('headersReceive', onHeaders);
      client.destroy();
    }
  }

  /** Content-Length of the archive, or -1 when unavailable. */
  private static async headBytes(url: string, trace: string[]): Promise<number> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.HEAD,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
        maxRedirects: 3,
      });
      const raw = LumixFirmwareWebSource.headerValue(response.header, 'content-length');
      const parsed = Number.parseInt(raw, 10);
      trace.push(`web head http=${response.responseCode} contentLength=${raw}`);
      return Number.isNaN(parsed) ? -1 : parsed;
    } catch (error) {
      trace.push(`web head error code=${LumixFirmwareWebSource.errorCode(error)}`);
      return -1;
    } finally {
      client.destroy();
    }
  }

  /**
   * Case-insensitive response-header lookup. ArkTS rejects `obj['field']`
   * (arkts-no-props-by-index) and "content-length" is not a usable identifier,
   * so the header object is walked as entries — reading the value by position
   * is allowed.
   */
  private static headerValue(header: Object, name: string): string {
    const wanted = name.toLowerCase();
    const entries = Object.entries(header as object) as [string, string][];
    for (const entry of entries) {
      if (entry[0].toLowerCase() === wanted) {
        return entry[1] !== undefined && entry[1] !== null ? String(entry[1]) : '';
      }
    }
    return '';
  }

  private static errorCode(error: Object): string {
    const withCode = error as ErrorWithCode;
    return withCode.code !== undefined ? String(withCode.code) : String(error);
  }

  private static shortPath(url: string): string {
    return url.replace(SITE_ORIGIN, '').replace(DOWNLOAD_DIR, '');
  }

  // -------------------------------------------------------------------------
  // HTML
  // -------------------------------------------------------------------------

  /** `function OpenWin17(){ win17=window.open("ff/dl/s1rm2.html" ...) }` */
  private static parseOpenWinTargets(html: string): Map<string, string> {
    const map = new Map<string, string>();
    const pattern = /function\s+OpenWin(\d+)\s*\(\s*\)\s*\{[\s\S]{0,240}?window\.open\(\s*"([^"]+)"/gi;
    let match = pattern.exec(html);
    while (match !== null) {
      map.set(`OpenWin${match[1]}`, match[2]);
      match = pattern.exec(html);
    }
    return map;
  }

  private static parseRows(html: string): WebRow[] {
    const targets = LumixFirmwareWebSource.parseOpenWinTargets(html);
    const rows: WebRow[] = [];
    for (const chunk of html.split(/<tr/i)) {
      const versionMatch = /Ver\.?\s*(\d+(?:\.\d+)*)/i.exec(chunk);
      if (versionMatch === null) continue;
      const tokens = chunk.match(/\b(?:DC|DMC|DMW)-[A-Za-z0-9]+(?:\/[A-Za-z0-9]+)*/g);
      if (tokens === null || tokens.length === 0) continue;
      let target = '';
      const openWin = /OpenWin(\d+)/i.exec(chunk);
      if (openWin !== null) {
        const key = `OpenWin${openWin[1]}`;
        const found = targets.get(key);
        if (found !== undefined) target = found;
      }
      if (target.length === 0) {
        const href = /href\s*=\s*"([^"]+)"/i.exec(chunk);
        target = href !== null ? href[1] : '';
      }
      // Some rows carry href="javascript:void(0);" (the site never wired a popup
      // for them). Treating that as a URL would build a nonsense request; the row
      // is kept so resolve() can still report the version it published.
      if (/^\s*javascript:/i.test(target)) target = '';
      for (const token of tokens) {
        for (const full of LumixFirmwareWebSource.expandModelToken(token)) {
          rows.push({ model: full, version: versionMatch[1], target: target });
        }
      }
    }
    return rows;
  }

  /** `DC-S5/S5D` -> ["DC-S5","DC-S5D"]; `DC-G100/G110` -> both prefixed. */
  private static expandModelToken(token: string): string[] {
    const parts = token.split('/');
    const first = parts[0];
    const dash = first.indexOf('-');
    const prefix = dash >= 0 ? first.substring(0, dash + 1) : '';
    const out: string[] = [];
    for (const part of parts) {
      out.push(part.indexOf('-') >= 0 ? part : `${prefix}${part}`);
    }
    return out;
  }

  private static stripPrefix(model: string): string {
    return model.trim().toUpperCase().replace(/^(?:DC|DMC|DMW)-/, '');
  }

  /** Exact match only — see the prefix-collision note in the header. */
  private static matchRow(rows: WebRow[], wanted: string): WebRow | null {
    for (const row of rows) {
      if (LumixFirmwareWebSource.stripPrefix(row.model) === wanted) return row;
    }
    return null;
  }

  /**
   * Find the EULA form that actually carries the archive name.
   *
   * Every one of these pages opens with the site's own header search form
   * (`action="https://www.panasonic.com/jp/search.html"`), so taking the first
   * <form> and looking for MODEL inside it silently grabs the search box and
   * fails. Measured on 2026-10-16: that is exactly how the first device run
   * died with "官网下载页结构无法识别". The form is therefore selected by its
   * contents, not by its position.
   */
  private static parseDownloadForm(html: string): WebDownloadForm | null {
    const formPattern = /<form[^>]*>([\s\S]*?)<\/form>/gi;
    let match = formPattern.exec(html);
    while (match !== null) {
      const body = match[1];
      const input = /<input[^>]*name\s*=\s*"MODEL"[^>]*>/i.exec(body);
      if (input !== null) {
        const action = /action\s*=\s*"([^"]+)"/i.exec(match[0]);
        const value = /value\s*=\s*"([^"]*)"/i.exec(input[0]);
        if (action !== null && value !== null && value[1].length > 0) {
          return { actionUrl: action[1], zipName: value[1] };
        }
      }
      match = formPattern.exec(html);
    }
    return null;
  }

  private static firstMatch(html: string, pattern: RegExp): string {
    const match = pattern.exec(html);
    return match !== null && match[1] !== undefined ? match[1] : '';
  }

  // -------------------------------------------------------------------------
  // URL
  // -------------------------------------------------------------------------

  private static resolveUrl(base: string, relative: string): string {
    const rel = relative.trim();
    if (/^https?:\/\//i.test(rel)) return rel;
    if (rel.startsWith('//')) return `https:${rel}`;
    const originMatch = /^(https?:\/\/[^/]+)/i.exec(base);
    const origin = originMatch !== null ? originMatch[1] : SITE_ORIGIN;
    if (rel.startsWith('/')) return `${origin}${rel}`;
    const cut = base.lastIndexOf('/');
    const baseDir = cut >= 0 ? base.substring(0, cut + 1) : `${origin}/`;
    return LumixFirmwareWebSource.normalizePath(`${baseDir}${rel}`);
  }

  /** Collapse "./" and "../" so the EULA iframe (../../license_en.html) works. */
  private static normalizePath(url: string): string {
    const match = /^(https?:\/\/[^/?#]+)([^?#]*)/i.exec(url);
    if (match === null) return url;
    const origin = match[1];
    const segments: string[] = [];
    for (const segment of match[2].split('/')) {
      if (segment.length === 0 || segment === '.') continue;
      if (segment === '..') {
        if (segments.length > 0) segments.pop();
        continue;
      }
      segments.push(segment);
    }
    return `${origin}/${segments.join('/')}`;
  }
}

interface ErrorWithCode {
  code?: number;
}
