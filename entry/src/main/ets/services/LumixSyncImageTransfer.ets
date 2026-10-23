import { http } from '@kit.NetworkKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CameraSessionDriver, CameraSessionStore } from './CameraSessionStore';
import { LumixGalleryItem, LumixImportPrototype } from './LumixImportPrototype';
import { LumixSyncCamCmdResult, LumixSyncControlService } from './LumixSyncControlService';
import { WorksBridge } from '../pages/home/HomeShared';
import { AppLogSink } from './AppLogSink';

/**
 * LUMIX Sync 世代的图片传输主动拉取（DMS Browse）：
 * 官方 App 在手动传输页通过机身内建 DLNA MediaServer（:60606/Server0/CDS_control）
 * 浏览 ObjectID="0" 并下载 res URL。本文件复刻该链路——
 *   camcmd playmode → SOAP Browse(BrowseDirectChildren, pana:X_FromCP=LumixLink2.0)
 *   → DIDL-Lite 解析 → 缩略图/原图 GET 下载到沙箱。
 * 请求头、SOAP 信封、反转义顺序与 jadx B5.m.a / Z5.C3142a.l 逐字一致；
 * 首个实机 Browse 应答通过 logChunks 全量落 hilog（VIVID_SYNC_DMS），供解析微调。
 */

const SYNC_DMS_PORT = 60606;
const SYNC_DMS_PATH = '/Server0/CDS_control';
const SYNC_DMS_PAGE_SIZE = 12;
const SYNC_DMS_TAG = 'VIVID_SYNC_DMS';

/** 一条 DIDL item 的解析结果（驱动内部元数据，不进 store）。 */
export interface SyncDmsItem {
  imageId: string;
  /** Primary resource shown by one gallery card: video, JPEG original, or RAW-only. */
  displayName: string;
  downloadUrl: string;
  /** DIDL-Lite declares the exact payload length for the primary resource. */
  downloadSize: number;
  thumbUrl: string;
  isVideo: boolean;
  /** True only when this item has no JPEG primary and the primary is RAW. */
  isRaw: boolean;
  /** A JPEG+RAW pair has a second, separately addressable RAW source. */
  rawDownloadUrl: string;
  rawDisplayName: string;
  rawSize: number;
}

interface DmsBrowsePage {
  ok: boolean;
  items: SyncDmsItem[];
  total: number;
  message: string;
  /** Number of physical DIDL camera items returned by this page. */
  sourceCount: number;
}

interface ParsedDmsItems {
  items: SyncDmsItem[];
  sourceCount: number;
}
interface SyncDownloadProgress {
  receiveSize: number;
  totalSize: number;
}

export class LumixSyncImageTransfer {
  /**
   * 转发到 hilog **并**写入应用日志（「问题反馈 → 发送日志」上传的是后者）。
   *
   * 签名与 `hilog.info` 完全一致，所以调用点只需换函数名，参数与格式串都不用动。
   * 为什么要这么绕：Sync 线的 DMS 浏览/下载失败只写 hilog 的话，用户既读不到也
   * 传不上来，真机报"传图失败"时无从判断卡在哪一步。
   *
   * 落盘前仍过 `AppLogPolicy.sanitize`（URL/路径/MAC/序列号打码），并由
   * `AppLogSink` 统一限流，避免下载进度把环形缓冲冲干净。
   */
  static logBoth(domain: number, tag: string, format: string, ...args: Object[]): void {
    try { hilog.info(domain, tag, format, ...args); } catch (_error) { }
    AppLogSink.emit('CTL', tag + ' ' + LumixSyncImageTransfer.fillTrace(format, args));
  }

  static warnBoth(domain: number, tag: string, format: string, ...args: Object[]): void {
    try { hilog.warn(domain, tag, format, ...args); } catch (_error) { }
    AppLogSink.emit('CTL', tag + ' ' + LumixSyncImageTransfer.fillTrace(format, args));
  }

  static errorBoth(domain: number, tag: string, format: string, ...args: Object[]): void {
    try { hilog.error(domain, tag, format, ...args); } catch (_error) { }
    AppLogSink.emit('CTL_ERR', tag + ' ' + LumixSyncImageTransfer.fillTrace(format, args));
  }

  /** 把 hilog 的 `%{public}s` / `%{public}d` 占位符按顺序替换成实参，
   *  让应用日志里留下可读文本而不是格式串。 */
  private static fillTrace(format: string, args: Object[]): string {
    let index = 0;
    return format.replace(/%\{public\}[a-zA-Z]+/g, (): string => {
      if (index >= args.length) return '?';
      const value = args[index];
      index += 1;
      return String(value);
    });
  }

  /** 与官方 B5.m.a 完全一致的 Browse SOAP 信封（ObjectID 固定 "0"）。 */
  private static browseEnvelope(startingIndex: number, requestedCount: number): string {
    return '<?xml version="1.0" encoding="utf-8"?>' +
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ' +
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>' +
      '<u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1" ' +
      'xmlns:pana="urn:schemas-panasonic-com:pana">' +
      '<ObjectID>0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter>' +
      `<StartingIndex>${startingIndex}</StartingIndex>` +
      `<RequestedCount>${requestedCount}</RequestedCount>` +
      '<SortCriteria></SortCriteria><pana:X_FromCP>LumixLink2.0</pana:X_FromCP>' +
      '</u:Browse></s:Body></s:Envelope>';
  }

  /**
   * 向机身 DMS 发送一页 Browse。任何失败都以 ok=false + 中文 message 返回，
   * 原始应答（成功与失败）都会分段写入 hilog 以便实机调优解析器。
   */
  static async browsePage(host: string, startingIndex: number, requestedCount: number): Promise<DmsBrowsePage> {
    const request = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Accept-Charset': 'UTF-8',
        'Content-Type': 'text/xml; charset="utf-8"',
        'SOAPAction': 'urn:schemas-upnp-org:service:ContentDirectory:1#Browse',
        'User-Agent': 'Panasonic MIL DLNA CP UPnP/1.0',
      };
      const url = `http://${host}:${SYNC_DMS_PORT}${SYNC_DMS_PATH}`;
      const sessionId = LumixSyncControlService.sessionIdForHost(host);
      if (sessionId.length > 0) headers['X-SESSION_ID'] = sessionId;
      const body = LumixSyncImageTransfer.browseEnvelope(startingIndex, requestedCount);
      const response = await request.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        body: body,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
      });
      if (response.responseCode !== 200) {
        // 403 的响应体是唯一能说明原因的线索（SOAP fault / 相机自定义错误），
        // 之前只记了状态码，等于把现场丢了。同时记录能解释鉴权的响应头。
        const failureBody = typeof response.result === 'string' ? response.result : '';
        LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG,
          'browse http=%{public}d start=%{public}d body=%{public}s',
          response.responseCode, startingIndex, LumixSyncImageTransfer.clipForLog(failureBody, 400));
        return { ok: false, items: [], total: 0, message: `相机图库服务应答 ${response.responseCode}`, sourceCount: 0 };
      }
      const raw = response.result as string;
      LumixSyncImageTransfer.logChunks('browse_res', raw);
      // 官方 C3142a.l 的反转义顺序：&lt; &gt; &amp; &quot;（照抄，含其边界行为）。
      const unescaped = raw
        .replace(new RegExp('&lt;', 'g'), '<')
        .replace(new RegExp('&gt;', 'g'), '>')
        .replace(new RegExp('&amp;', 'g'), '&')
        .replace(new RegExp('&quot;', 'g'), '"');
      const total = LumixSyncImageTransfer.matchNumber(unescaped, 'TotalMatches');
      const didlStart = unescaped.indexOf('<DIDL-Lite');
      let didl = '';
      if (didlStart >= 0) {
        const didlEnd = unescaped.indexOf('</DIDL-Lite>');
        didl = didlEnd > didlStart ? unescaped.substring(didlStart, didlEnd + 12) : unescaped.substring(didlStart);
      }
      const parsed = LumixSyncImageTransfer.parseItems(didl);
      const returned = LumixSyncImageTransfer.matchNumber(unescaped, 'NumberReturned');
      const sourceCount = returned > 0 ? returned : parsed.sourceCount;
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, 'browse start=%{public}d total=%{public}d source=%{public}d resources=%{public}d',
        startingIndex, total, sourceCount, parsed.items.length);
      return { ok: true, items: parsed.items, total: total, message: '', sourceCount: sourceCount };
    } catch (error) {
      LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG, 'browse failed %{public}s', String(error));
      return { ok: false, items: [], total: 0, message: '无法连接相机图库服务', sourceCount: 0 };
    } finally {
      request.destroy();
    }
  }

  /**
   * One DIDL item can contain two original resources.  Keep them as separate
   * cards; sourceCount remains the physical DIDL item count for paging.
   */
  private static parseItems(didl: string): ParsedDmsItems {
    const items: SyncDmsItem[] = [];
    let sourceCount = 0;
    if (didl.length === 0) return { items: items, sourceCount: sourceCount };
    const itemRe = new RegExp('<item[\\s\\S]*?</item>', 'g');
    let itemMatch = itemRe.exec(didl);
    while (itemMatch !== null) {
      sourceCount += 1;
      const resources = LumixSyncImageTransfer.parseItem(itemMatch[0]);
      for (const resource of resources) items.push(resource);
      itemMatch = itemRe.exec(didl);
    }
    return { items: items, sourceCount: sourceCount };
  }
  /**
   * 单个 <item>：收集 res URL 列表并按官方 protocolInfo 标记分类。
   * 缩略图=JPEG_TN/JPEG_SM/CAM_TN/CAM_SM；原图优先 CAM_ORG，其次普通 image/*；
   * RAW=x-panasonic-raw/CAM_RAW；视频=video/*。显示名取 res 的
   * OriginalFileName 属性（官方解析器同源），缺失时退回 id 末段。
   */
  private static parseItem(block: string): SyncDmsItem[] {
    const idMatch = new RegExp('<item[^>]*?\\sid="([^"]*)"').exec(block);
    if (idMatch === null) return [];
    const imageId = idMatch[1];
    const titleMatch = new RegExp('<dc:title>([^<]*)</dc:title>', 'i').exec(block);
    let title = titleMatch !== null ? titleMatch[1].trim() : '';
    let originalName = '';
    let thumbUrl = '';
    let jpegUrl = '';
    let jpegSize = 0;
    let rawUrl = '';
    let rawSize = 0;
    let videoUrl = '';
    let videoSize = 0;
    let isVideo = false;

    const resRe = new RegExp('<res([^>]*)>([\\s\\S]*?)</res>', 'g');
    let resMatch = resRe.exec(block);
    while (resMatch !== null) {
      const attrs = resMatch[1];
      const url = resMatch[2].trim();
      if (url.length > 0) {
        const piMatch = new RegExp('protocolInfo="([^"]*)"').exec(attrs);
        const protocolInfo = piMatch !== null ? piMatch[1].toLowerCase() : '';
        const sizeMatch = new RegExp('\\ssize="(\\d+)"').exec(attrs);
        const declaredSize = sizeMatch !== null ? Number.parseInt(sizeMatch[1], 10) : 0;
        const nameMatch = new RegExp("OriginalFileName='([^']*)'").exec(attrs);
        if (originalName.length === 0 && nameMatch !== null) originalName = nameMatch[1].trim();
        const extension = LumixSyncImageTransfer.urlExtensionOf(url).toLowerCase();
        const isThumbRes = protocolInfo.indexOf('jpeg_tn') >= 0 || protocolInfo.indexOf('jpeg_sm') >= 0 ||
          protocolInfo.indexOf('cam_tn') >= 0 || protocolInfo.indexOf('cam_sm') >= 0 ||
          protocolInfo.indexOf('cam_lrgtn') >= 0;
        const isVideoRes = protocolInfo.indexOf('video/') >= 0 || protocolInfo.indexOf('cam_avc') >= 0 ||
          extension === 'mov' || extension === 'mp4' || extension === 'm4v';
        // Panasonic uses application/octet-stream for both files of a JPG+RAW
        // pair. CAM_RAW_JPG is the JPEG original and must be tested before
        // CAM_RAW; treating it as RAW writes JPEG bytes into an .RW2 asset.
        const isRawJpegRes = protocolInfo.indexOf('cam_raw_jpg') >= 0 ||
          protocolInfo.indexOf('cam_hsp_raw_jpg') >= 0;
        const isRawRes = !isRawJpegRes && (protocolInfo.indexOf('cam_raw') >= 0 ||
          protocolInfo.indexOf('cam_hsp_raw') >= 0 || extension === 'rw2' || extension === 'rwl' ||
          extension === 'raw' || extension === 'dng');
        const isJpegOriginal = !isThumbRes && !isRawRes && (isRawJpegRes ||
          protocolInfo.indexOf('cam_org') >= 0 || protocolInfo.indexOf('cam_hsp_jpg') >= 0 ||
          extension === 'jpg' || extension === 'jpeg' || protocolInfo.indexOf('image/') >= 0);
        if (isThumbRes) {
          if (thumbUrl.length === 0) thumbUrl = url;
        } else if (isVideoRes) {
          isVideo = true;
          if (videoUrl.length === 0) {
            videoUrl = url;
            videoSize = Number.isFinite(declaredSize) && declaredSize > 0 ? declaredSize : 0;
          }
        } else if (isRawRes) {
          if (rawUrl.length === 0) {
            rawUrl = url;
            rawSize = Number.isFinite(declaredSize) && declaredSize > 0 ? declaredSize : 0;
          }
        } else if (isJpegOriginal && jpegUrl.length === 0) {
          jpegUrl = url;
          jpegSize = Number.isFinite(declaredSize) && declaredSize > 0 ? declaredSize : 0;
        }
      }
      resMatch = resRe.exec(block);
    }

    if (title.length === 0) title = originalName;
    if (title.length === 0) {
      const slash = imageId.lastIndexOf('/');
      title = slash >= 0 ? imageId.substring(slash + 1) : imageId;
    }
    const titleDot = title.lastIndexOf('.');
    const base = titleDot > 0 ? title.substring(0, titleDot) : title;
    const safeBase = base.length > 0 ? base : `VIVID_SYNC_${imageId}`;
    const resources: SyncDmsItem[] = [];
    if (isVideo && videoUrl.length > 0) {
      const videoExtension = LumixSyncImageTransfer.urlExtensionOf(videoUrl).toLowerCase();
      resources.push({ imageId: imageId,
        displayName: `${safeBase}.${(videoExtension.length > 0 ? videoExtension : 'mov').toUpperCase()}`,
        downloadUrl: videoUrl, downloadSize: videoSize, thumbUrl: thumbUrl, isVideo: true, isRaw: false,
        rawDownloadUrl: '', rawDisplayName: '', rawSize: 0 });
      return resources;
    }
    if (jpegUrl.length > 0) {
      const jpegExtension = LumixSyncImageTransfer.urlExtensionOf(jpegUrl).toLowerCase();
      resources.push({ imageId: imageId,
        displayName: `${safeBase}.${(jpegExtension.length > 0 ? jpegExtension : 'jpg').toUpperCase()}`,
        downloadUrl: jpegUrl, downloadSize: jpegSize, thumbUrl: thumbUrl, isVideo: false, isRaw: false,
        rawDownloadUrl: '', rawDisplayName: '', rawSize: 0 });
    }
    if (rawUrl.length > 0) {
      const rawExtension = LumixSyncImageTransfer.urlExtensionOf(rawUrl).toLowerCase();
      resources.push({ imageId: `${imageId}::raw`,
        displayName: `${safeBase}.${(rawExtension.length > 0 ? rawExtension : 'rw2').toUpperCase()}`,
        downloadUrl: rawUrl, downloadSize: rawSize, thumbUrl: thumbUrl, isVideo: false, isRaw: true,
        rawDownloadUrl: '', rawDisplayName: '', rawSize: 0 });
    }
    return resources;
  }
  private static matchNumber(xml: string, tag: string): number {
    const re = new RegExp('<' + tag + '>(\\d+)</' + tag + '>');
    const match = re.exec(xml);
    if (match === null) return 0;
    const parsed = Number(match[1]);
    return isNaN(parsed) ? 0 : parsed;
  }

  /** 把响应体压成一行并截断，用于失败现场日志。 */
  private static clipForLog(text: string, max: number): string {
    const flat = text.replace(new RegExp('[\\r\\n]+', 'g'), ' ').trim();
    return flat.length <= max ? flat : flat.substring(0, max) + '…';
  }

  /** 长文本分段写 hilog（单条上限 ~4K，最多 10 段后截断）。 */
  private static logChunks(label: string, text: string): void {
    const chunkSize = 3600;
    const totalChunks = Math.ceil(text.length / chunkSize);
    const limit = Math.min(totalChunks, 10);
    for (let i = 0; i < limit; i++) {
      const start = i * chunkSize;
      const end = Math.min(start + chunkSize, text.length);
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, '%{public}s[%{public}d/%{public}d] %{public}s',
        label, i + 1, totalChunks, text.substring(start, end));
    }
    if (totalChunks > limit) {
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, '%{public}s truncated totalLen=%{public}d', label, text.length);
    }
  }

  /**
   * 流式 GET 下载到沙箱（requestInStream + dataReceive 落盘）。
   * 返回 file:// URI；失败返回空串并清理半成品文件。官方用 libdlnaCore
   * 原生下载，Java 层无参考，这里用普通 GET + 相同 UA 试探。
   */
  static async downloadToFile(context: common.UIAbilityContext, url: string, destFileName: string,
    readTimeoutMs: number = 60000,
    onProgress?: (received: number, total: number) => void,
    expectedBytes: number = 0,
    sessionHost: string = ''): Promise<string> {
    const request = http.createHttp();
    const path = `${context.filesDir}/${destFileName}`;
    let file: fileIo.File | null = null;
    let received: number = 0;
    let statusCode: number = 0;
    let dataEnded: boolean = false;
    let failure: Object | null = null;
    let settled: boolean = false;
    let resolveDone: (ok: boolean) => void = (_ok: boolean) => {
    };
    const streamDone = new Promise<boolean>((resolve: (ok: boolean) => void) => {
      resolveDone = resolve;
    });
    const settle = (): void => {
      if (settled) return;
      if (failure !== null) {
        settled = true;
        resolveDone(false);
        return;
      }
      if (statusCode > 0 && dataEnded) {
        settled = true;
        resolveDone(statusCode >= 200 && statusCode < 300 && received > 0);
      }
    };
    const fail = (error: Object): void => {
      if (failure === null) failure = error;
      settle();
    };
    const discardFile = (): void => {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_error) {
        }
        file = null;
      }
      try {
        fileIo.unlinkSync(path);
      } catch (_error) {
      }
    };
    const headers: Record<string, string> = {
      'User-Agent': 'Panasonic MIL DLNA CP UPnP/1.0',
    };
    const sessionId = LumixSyncControlService.sessionIdForHost(sessionHost);
    if (sessionId.length > 0) headers['X-SESSION_ID'] = sessionId;
    const progressHandler = (info: SyncDownloadProgress): void => {
      if (onProgress !== undefined) onProgress(info.receiveSize, info.totalSize);
    };
    let lastProgressAt = 0;
    try {
      request.on('dataReceive', (chunk: ArrayBuffer) => {
        if (settled || chunk.byteLength === 0) return;
        try {
          if (file === null) {
            file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
          }
          fileIo.writeSync(file.fd, chunk);
          received += chunk.byteLength;
          // dataReceiveProgress 在部分真机流式下载场景不回调（2026-09-28
          // 进度条失效）：在 dataReceive 内自行节流上报兜底（每 250ms
          // 一次），total 用 DIDL 声明尺寸。
          const now = Date.now();
          if (onProgress !== undefined && now - lastProgressAt >= 250) {
            lastProgressAt = now;
            onProgress(received, expectedBytes > 0 ? expectedBytes : 0);
          }
        } catch (error) {
          fail(error);
        }
      });
      request.on('dataEnd', () => {
        dataEnded = true;
        settle();
      });
      request.on('dataReceiveProgress', progressHandler);
      request.requestInStream(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 15000,
        readTimeout: readTimeoutMs,
      }).then((code: number) => {
        statusCode = code;
        settle();
      }).catch((error: BusinessError) => {
        fail(error);
      });
      const ok = await streamDone;
      if (!ok) {
        // 只打 http=0 bytes=0 无法区分「授权过期」「连不上」「超时」——下一次
        // 真机日志必须带上 BusinessError 的 code 与 message 才能定位。
        let failureText = 'none';
        if (failure !== null) {
          const error = failure as BusinessError;
          failureText = error.code !== undefined ? `${error.code}` : 'no-code';
          if (error.message !== undefined && error.message.length > 0) {
            failureText = `${failureText}:${error.message}`;
          }
        }
        LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG,
          'download http=%{public}d bytes=%{public}d err=%{public}s file=%{public}s',
          statusCode, received, failureText.substring(0, 80), destFileName);
        discardFile();
        return '';
      }
      if (file !== null) {
        fileIo.closeSync(file);
        file = null;
      }
      // DIDL-Lite gives the exact original-resource size. A smaller successful
      // HTTP response is not an acceptable substitute: it is commonly a
      // camera preview and would otherwise be saved as a misleading original.
      if (expectedBytes > 0 && received !== expectedBytes) {
        LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG,
          'download incomplete bytes=%{public}d expected=%{public}d file=%{public}s',
          received, expectedBytes, destFileName);
        discardFile();
        return '';
      }
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, 'download ok bytes=%{public}d expected=%{public}d file=%{public}s',
        received, expectedBytes, destFileName);
      return `file://${path}`;
    } catch (error) {
      LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG, 'download failed %{public}s', String(error));
      discardFile();
      return '';
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_error) {
        }
        file = null;
      }
      try {
        request.off('dataReceive');
      } catch (_error) {
      }
      try {
        request.off('dataEnd');
      } catch (_error) {
      }
      try {
        request.off('dataReceiveProgress', progressHandler);
      } catch (_error) {
      }
      request.destroy();
    }
  }

  static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: (value: void) => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 沙箱文件名安全化：保留字母数字与 . _ -，其余替换为下划线。 */
  static safeToken(value: string): string {
    const cleaned = value.replace(new RegExp('[^A-Za-z0-9._-]', 'g'), '_');
    return cleaned.length > 0 ? cleaned : 'item';
  }

  static imageTypeOf(item: SyncDmsItem): number {
    if (item.isRaw) return 1;
    // imageType=2 is the shared gallery contract for a JPEG primary. A paired
    // RW2 remains represented by rawSize and rawDownloadUrl on the Sync item.
    return 2;
  }

  /** res URL 尾段的扩展名（如 ".../P1010534.JPG" → "JPG"）；无扩展名或
   * 含非常规字符时返回空串。 */
  private static urlExtensionOf(url: string): string {
    if (url.length === 0) return '';
    let tail = url;
    const query = tail.indexOf('?');
    if (query >= 0) tail = tail.substring(0, query);
    const slash = tail.lastIndexOf('/');
    if (slash >= 0) tail = tail.substring(slash + 1);
    const dot = tail.lastIndexOf('.');
    if (dot <= 0 || dot === tail.length - 1) return '';
    const ext = tail.substring(dot + 1);
    if (ext.length > 5) return '';
    for (let i = 0; i < ext.length; i++) {
      const c = ext.charCodeAt(i);
      const alnum = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
      if (!alnum) return '';
    }
    return ext.toUpperCase();
  }

  static extensionOf(item: SyncDmsItem): string {
    const name = item.displayName.toLowerCase();
    const dot = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1) {
      const ext = name.substring(dot + 1);
      const known: string[] = ['jpg', 'jpeg', 'png', 'heic', 'heif', 'webp',
        'rw2', 'rwl', 'raw', 'dng', 'tif', 'tiff',
        'mov', 'mp4', 'm4v', 'avi', 'mpg', 'mpeg', 'mts', 'm2ts', '3gp', 'wmv', 'asf'];
      if (known.indexOf(ext) >= 0) return ext;
    }
    if (item.isVideo) return 'mp4';
    return item.isRaw ? 'rw2' : 'jpg';
  }

  static extensionForName(displayName: string, fallback: string): string {
    const dot = displayName.lastIndexOf('.');
    if (dot > 0 && dot < displayName.length - 1) {
      const ext = displayName.substring(dot + 1).toLowerCase();
      const known: string[] = ['jpg', 'jpeg', 'png', 'heic', 'heif', 'webp',
        'rw2', 'rwl', 'raw', 'dng', 'tif', 'tiff',
        'mov', 'mp4', 'm4v', 'avi', 'mpg', 'mpeg', 'mts', 'm2ts', '3gp', 'wmv', 'asf'];
      if (known.indexOf(ext) >= 0) return ext;
    }
    return fallback;
  }

  static titleOf(displayName: string, index: number): string {
    const dot = displayName.lastIndexOf('.');
    const base = dot > 0 ? displayName.substring(0, dot) : displayName;
    return base.length > 0 ? base : `VIVID_SYNC_${index + 1}`;
  }

  /** 视频原片体积可达数 GB：分块写入媒体库资产，避免整文件进内存。 */
  static async copyFileChunked(sourcePath: string, targetUri: string): Promise<number> {
    const source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
    const output = fileIo.openSync(targetUri, fileIo.OpenMode.WRITE_ONLY);
    const chunk = new ArrayBuffer(8 * 1024 * 1024);
    let copied = 0;
    try {
      while (true) {
        const read = fileIo.readSync(source.fd, chunk);
        if (read <= 0) break;
        fileIo.writeSync(output.fd, read === chunk.byteLength ? chunk : chunk.slice(0, read));
        copied += read;
        // 让出主线程，避免长时间同步拷贝卡住进度 UI。
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
    } finally {
      fileIo.closeSync(source);
      fileIo.closeSync(output);
    }
    return copied;
  }

  /** 诊断：扫描下载文件前 512KB 的镜头信息 ASCII 字符串（RW2/JPG 的
   *  EXIF MakerNote 里镜头名以明文存储），落 hilog 供「下载图片镜头信息
   *  错误」定位——判断是相机 DMS 下发的字节本身缺镜头信息，还是展示
   *  侧问题。 */
  static scanLensEvidence(path: string): void {
    try {
      const size = Number(fileIo.statSync(path).size);
      // EXIF/MakerNote 与预览在文件头部；扫描前 2MB 足够覆盖镜头名字段。
      const scanLen = Math.min(size, 2 * 1024 * 1024);
      const source = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const matches: string[] = [];
      const chunk = new ArrayBuffer(64 * 1024);
      let carry = '';
      let scanned = 0;
      // 分块扫描：一次性把大块展开成字符会栈溢出（2026-09-28 首版
      // 静默失败无日志），按 64KB 读、16KB 拼串，尾 120 字符跨块携带。
      while (scanned < scanLen) {
        const read = fileIo.readSync(source.fd, chunk);
        if (read <= 0) {
          break;
        }
        const bytes = new Uint8Array(chunk, 0, read);
        const ascii = new Uint8Array(read);
        for (let i = 0; i < read; i++) {
          const b = bytes[i];
          ascii[i] = (b >= 32 && b < 127) ? b : 32;
        }
        let text = '';
        for (let off = 0; off < read; off += 16384) {
          const part = ascii.slice(off, Math.min(read, off + 16384));
          text += String.fromCharCode(...Array.from(part));
        }
        const full = carry + text;
        const regex = /LUMIX[^\s]{0,40}|[0-9]{1,3}-[0-9]{1,3}mm|H-FS[^\s]{0,20}|H-ES[^\s]{0,20}|S PRO[^\s]{0,20}|50mm|N\/A/g;
        let match = regex.exec(full);
        while (match !== null) {
          const at = match.index;
          // 命中偏移（近似）：定位字符串所在文件区域（EXIF/MakerNote/数据区）。
          const offset = Math.max(0, scanned - carry.length + at);
          const ctx = full.substring(Math.max(0, at - 40),
            Math.min(full.length, at + match[0].length + 60)).replace(/\s+/g, ' ');
          const entry = `@${offset}:${ctx}`;
          if (matches.indexOf(entry) < 0) {
            matches.push(entry);
          }
          if (matches.length >= 8) {
            break;
          }
          match = regex.exec(full);
        }
        scanned += read;
        if (matches.length >= 8) {
          break;
        }
        carry = full.substring(Math.max(0, full.length - 120));
      }
      fileIo.closeSync(source);
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, 'lens evidence file=%{public}s size=%{public}d hits=%{public}s',
        path.substring(path.lastIndexOf('/') + 1), size, matches.join(' | '));
      // 结构化 EXIF：图库展示镜头信息读的是标准标签（LensModel 0xA434
      // 等），MakerNote 里的镜头名字符串不参与展示。解析两者一起落日志。
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, '%{public}s', LumixSyncImageTransfer.scanExifTags(path));
    } catch (_error) {
      LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG, 'lens evidence scan failed %{public}s', String(_error));
    }
  }

  /** 结构化 EXIF 解析：读取 IFD0 与 ExifIFD 中的镜头相关标准标签
   *  （0xA432 LensInfo、0xA433 LensSerialNumber、0xA434 LensModel、
   *  0x0110 Model）以及 Panasonic MakerNote 的 0x0051 LensType——判断
   *  图库显示镜头信息为空的根因在哪个字段。 */
  static scanExifTags(path: string): string {
    try {
      const size = Number(fileIo.statSync(path).size);
      const head = new Uint8Array(Math.min(size, 2 * 1024 * 1024));
      const source = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let got = 0;
      while (got < head.length) {
        const n = fileIo.readSync(source.fd, head.buffer, { offset: got, length: head.length - got });
        if (n <= 0) {
          break;
        }
        got += n;
      }
      fileIo.closeSync(source);
      // TIFF 基址：JPEG 走 APP1 "Exif\0\0" 段，RW2 从文件头开始。
      let base = 0;
      if (head[0] === 0xFF && head[1] === 0xD8) {
        let p = 2;
        while (p + 4 < head.length) {
          if (head[p] !== 0xFF) {
            break;
          }
          const marker = head[p + 1];
          if (marker === 0xDA || marker === 0xD9) {
            break;
          }
          const segLen = (head[p + 2] << 8) | head[p + 3];
          if (marker === 0xE1 && segLen >= 8 && head[p + 4] === 0x45 && head[p + 5] === 0x78 &&
            head[p + 6] === 0x69 && head[p + 7] === 0x66) {
            base = p + 10;
            break;
          }
          p += 2 + segLen;
        }
      }
      if (base + 8 >= head.length || !(head[base] === 0x49 || head[base] === 0x4D)) {
        return 'exif tags tiff=absent';
      }
      const le = head[base] === 0x49;
      const u16 = (o: number): number => le ? head[o] | (head[o + 1] << 8) : (head[o] << 8) | head[o + 1];
      const u32 = (o: number): number => le
        ? head[o] | (head[o + 1] << 8) | (head[o + 2] << 16) | (head[o + 3] * 0x1000000)
        : (head[o] * 0x1000000) | (head[o + 1] << 16) | (head[o + 2] << 8) | head[o + 3];
      const asciiAt = (o: number, count: number): string => {
        let out = '';
        for (let i = 0; i < count && o + i < head.length; i++) {
          if (head[o + i] === 0) {
            break;
          }
          out += String.fromCharCode(head[o + i]);
        }
        return out;
      };
      const ifd0 = u32(base + 4);
      const parts: string[] = [];
      let exifIfd = 0;
      let makerNote = 0;
      let model = '';
      const walk = (ifd: number, prefix: string): void => {
        if (ifd <= 0 || ifd + 2 >= head.length) {
          return;
        }
        const count = u16(ifd);
        for (let i = 0; i < count; i++) {
          const e = ifd + 2 + i * 12;
          if (e + 12 > head.length) {
            break;
          }
          const tag = u16(e);
          const type = u16(e + 2);
          const num = u32(e + 4);
          const raw = u32(e + 8);
          if (tag === 0x8769 && type === 4) {
            exifIfd = raw;
          }
          if (tag === 0x927C) {
            makerNote = raw;
          }
          if (tag === 0x0110 && type === 2) {
            const at = num <= 4 ? e + 8 : base + raw;
            model = asciiAt(at, Math.min(num, 80));
          }
          if (tag === 0xA434 && type === 2) {
            const at = num <= 4 ? e + 8 : base + raw;
            parts.push(`${prefix}LensModel=${asciiAt(at, Math.min(num, 80))}`);
          }
          if (tag === 0xA433 && type === 2) {
            const at = num <= 4 ? e + 8 : base + raw;
            parts.push(`${prefix}LensSerial=${asciiAt(at, Math.min(num, 80))}`);
          }
          if (tag === 0xA432 && type === 5 && num >= 4) {
            const at = base + raw;
            const v = (o: number): number => {
              const n = u32(o);
              const d = u32(o + 4);
              return d > 0 ? Math.round(n * 10 / d) / 10 : 0;
            };
            parts.push(`${prefix}LensInfo=${v(at)},${v(at + 8)},${v(at + 16)},${v(at + 24)}`);
          }
        }
      };
      // 转储 IFD0 全部标签 ID（诊断 DMS 重建的 EXIF 结构保留了哪些字段）。
      const ifdTags: string[] = [];
      if (ifd0 > 0 && ifd0 + 2 < head.length) {
        const count0 = u16(ifd0);
        for (let i = 0; i < count0; i++) {
          const e = ifd0 + 2 + i * 12;
          if (e + 12 > head.length) {
            break;
          }
          ifdTags.push(u16(e).toString(16));
        }
      }
      walk(ifd0, 'ifd0:');
      if (exifIfd > 0) {
        walk(exifIfd, 'exif:');
      }
      // Panasonic MakerNote：前 12 字节 "Panasonic\0\0\0"，随后是 IFD。
      if (makerNote > 0 && makerNote + 20 < head.length && head[makerNote] === 0x50) {
        const mnIfd = makerNote + 12;
        const count = u16(mnIfd);
        for (let i = 0; i < count; i++) {
          const e = mnIfd + 2 + i * 12;
          if (e + 12 > head.length) {
            break;
          }
          const tag = u16(e);
          const type = u16(e + 2);
          const num = u32(e + 4);
          const raw = u32(e + 8);
          if (tag === 0x0051 && type === 2) {
            const at = num <= 4 ? e + 8 : makerNote + raw;
            parts.push(`mn:LensType=${asciiAt(at, Math.min(num, 80))}`);
          }
        }
      }
      return `exif tags model=${model} ifd0=[${ifdTags.join(',')}] ${parts.join(' ')}`;
    } catch (_error) {
      return `exif tags scan failed ${String(_error)}`;
    }
  }

  /**
   * 镜头信息回填：DMS 下发的 JPG/RW2 缺少标准 EXIF 镜头标签
   *  （LensModel 0xA434 / LensInfo 0xA432）——图库与 Pixelshop 边框
   *  显示镜头为空的根因（2026-09-28 实测：IFD0 有 0x8769 但 ExifIFD
   *  无镜头标签，镜头名字符串在文件头部偏移处）。从镜头名字符串
   *  （如 "LUMIX S 70-300/F4.5-5.6"）重建 ExifIFD 并回填两个标签，
   *  IFD0 的 0x8769 指针改到新表。返回是否修改了文件。
   */
  static backfillLensExif(path: string): boolean {
    try {
      const size = Number(fileIo.statSync(path).size);
      if (size <= 0 || size > 128 * 1024 * 1024) {
        return false;
      }
      const data = new Uint8Array(size);
      const source = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let got = 0;
      while (got < size) {
        const n = fileIo.readSync(source.fd, data.buffer, { offset: got, length: size - got });
        if (n <= 0) {
          break;
        }
        got += n;
      }
      fileIo.closeSync(source);
      if (got !== size) {
        return false;
      }
      // 1) TIFF 基址。
      let base = 0;
      let segStart = -1;
      let segLen = 0;
      if (data[0] === 0xFF && data[1] === 0xD8) {
        let p = 2;
        while (p + 4 < data.length) {
          if (data[p] !== 0xFF) {
            break;
          }
          const marker = data[p + 1];
          if (marker === 0xDA || marker === 0xD9) {
            break;
          }
          const len = (data[p + 2] << 8) | data[p + 3];
          if (marker === 0xE1 && len >= 8 && data[p + 4] === 0x45 && data[p + 5] === 0x78 &&
            data[p + 6] === 0x69 && data[p + 7] === 0x66) {
            segStart = p;
            segLen = len;
            base = p + 10;
            break;
          }
          p += 2 + len;
        }
      }
      if (base + 8 >= data.length || !(data[base] === 0x49 || data[base] === 0x4D)) {
        return false;
      }
      const le = data[base] === 0x49;
      const u16 = (o: number): number => le ? data[o] | (data[o + 1] << 8) : (data[o] << 8) | data[o + 1];
      const u32 = (o: number): number => le
        ? data[o] | (data[o + 1] << 8) | (data[o + 2] << 16) | (data[o + 3] * 0x1000000)
        : (data[o] * 0x1000000) | (data[o + 1] << 16) | (data[o + 2] << 8) | data[o + 3];
      const asciiAt = (o: number, count: number): string => {
        let out = '';
        for (let i = 0; i < count && o + i < data.length; i++) {
          if (data[o + i] === 0) {
            break;
          }
          out += String.fromCharCode(data[o + i]);
        }
        return out;
      };
      const ifd0 = u32(base + 4);
      // 2) 定位 IFD0 的 0x8769 条目与 ExifIFD 现状。
      let exifEntryValuePos = -1;
      let exifIfd = 0;
      if (ifd0 > 0 && ifd0 + 2 < data.length) {
        const count = Math.min(u16(ifd0), 200);
        for (let i = 0; i < count; i++) {
          const e = ifd0 + 2 + i * 12;
          if (e + 12 > data.length) {
            break;
          }
          if (u16(e) === 0x8769 && u16(e + 2) === 4) {
            exifEntryValuePos = e + 8;
            exifIfd = u32(e + 8);
            break;
          }
        }
      }
      if (exifEntryValuePos < 0) {
        return false;
      }
      // 已有 LensModel 且非空则不重复回填。
      if (exifIfd > 0 && exifIfd + 2 < data.length) {
        const count = Math.min(u16(exifIfd), 200);
        for (let i = 0; i < count; i++) {
          const e = exifIfd + 2 + i * 12;
          if (e + 12 > data.length) {
            break;
          }
          if (u16(e) === 0xA434 && u16(e + 2) === 2) {
            const num = u32(e + 4);
            const at = num <= 4 ? e + 8 : base + u32(e + 8);
            if (asciiAt(at, Math.min(num, 80)).trim().length > 0) {
              return false;
            }
          }
        }
      }
      // 3) 从文件头部找镜头名字符串并推导参数。
      let lensName = '';
      const scanLen = Math.min(data.length, 1024 * 1024);
      let text = '';
      for (let off = 0; off < scanLen; off += 16384) {
        const part = data.slice(off, Math.min(scanLen, off + 16384));
        const ascii = new Uint8Array(part.length);
        for (let i = 0; i < part.length; i++) {
          const b = part[i];
          ascii[i] = (b >= 32 && b < 127) ? b : 32;
        }
        text += String.fromCharCode(...Array.from(ascii));
      }
      const lensRe = /LUMIX[^0-9]{0,8}[0-9]{1,3}-[0-9]{1,3}\/F[0-9.]+-[0-9.]+/;
      const lensMatch = lensRe.exec(text);
      if (lensMatch !== null) {
        lensName = lensMatch[0];
      }
      if (lensName.length === 0) {
        LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG, 'lens backfill skipped: no lens name string');
        return false;
      }
      const focalRe = /([0-9]{1,3})-([0-9]{1,3})\/F([0-9.]+)-([0-9.]+)/;
      const focalMatch = focalRe.exec(lensName);
      let minFocal = 0;
      let maxFocal = 0;
      let maxAperture = 0;
      let minAperture = 0;
      if (focalMatch !== null) {
        minFocal = parseInt(focalMatch[1], 10);
        maxFocal = parseInt(focalMatch[2], 10);
        maxAperture = Math.round(parseFloat(focalMatch[3]) * 10);
        minAperture = Math.round(parseFloat(focalMatch[4]) * 10);
      }
      // 4) 构建新 ExifIFD（2 个条目 + 数据）。
      const nameBytes = new Uint8Array(lensName.length + 1);
      for (let i = 0; i < lensName.length; i++) {
        nameBytes[i] = lensName.charCodeAt(i) & 0xFF;
      }
      nameBytes[lensName.length] = 0;
      const ifdHeader = 2 + 2 * 12 + 4;
      const lensInfoOffset = ifdHeader;
      const lensModelOffset = ifdHeader + 32;
      const newIfd = new Uint8Array(ifdHeader + 32 + nameBytes.length);
      newIfd[0] = 2;
      newIfd[1] = 0;
      const put16 = (o: number, v: number): void => {
        if (le) {
          newIfd[o] = v & 0xFF;
          newIfd[o + 1] = (v >> 8) & 0xFF;
        } else {
          newIfd[o] = (v >> 8) & 0xFF;
          newIfd[o + 1] = v & 0xFF;
        }
      };
      const put32 = (o: number, v: number): void => {
        for (let i = 0; i < 4; i++) {
          newIfd[o + i] = le ? (v >> (i * 8)) & 0xFF : (v >> ((3 - i) * 8)) & 0xFF;
        }
      };
      // 条目1：LensInfo 0xA432 RATIONAL×4。
      put16(2, 0xA432);
      put16(4, 5);
      put32(6, 4);
      put32(8, 0xFFFFFFFF); // 占位：下方写入 TIFF 基址相对偏移
      // 条目2：LensModel 0xA434 ASCII。
      put16(14, 0xA434);
      put16(16, 2);
      put32(18, nameBytes.length);
      put32(20, 0xFFFFFFFF); // 占位：下方写入 TIFF 基址相对偏移
      put32(26, 0); // next IFD
      const rationals: number[] = [maxAperture, 10, minAperture, 10, minFocal, 1, maxFocal, 1];
      for (let i = 0; i < 8; i++) {
        put32(lensInfoOffset + i * 4, rationals[i]);
      }
      newIfd.set(nameBytes, lensModelOffset);
      // 5) 写入：RW2 追加到文件尾；JPG 扩进 APP1 段并修正段长。
      let insertAt = data.length;
      let newOffsetFromBase = data.length - base;
      if (segStart >= 0) {
        insertAt = segStart + 2 + segLen;
        newOffsetFromBase = insertAt - base;
      }
      // IFD 条目的值偏移必须相对 TIFF 基址（此前误写相对新表，
      // 读取器会指向旧数据区）。
      put32(8, newOffsetFromBase + lensInfoOffset);
      put32(20, newOffsetFromBase + lensModelOffset);
      const out = new Uint8Array(data.length + newIfd.length);
      out.set(data.subarray(0, insertAt), 0);
      out.set(newIfd, insertAt);
      out.set(data.subarray(insertAt), insertAt + newIfd.length);
      // 回写新 ExifIFD 偏移到 IFD0 的 0x8769 条目（原位 4 字节）。
      const patch = (o: number, v: number): void => {
        for (let i = 0; i < 4; i++) {
          out[o + i] = le ? (v >> (i * 8)) & 0xFF : (v >> ((3 - i) * 8)) & 0xFF;
        }
      };
      patch(exifEntryValuePos, newOffsetFromBase);
      if (segStart >= 0) {
        out[segStart + 2] = ((segLen + newIfd.length) >> 8) & 0xFF;
        out[segStart + 3] = (segLen + newIfd.length) & 0xFF;
      }
      const target = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      let written = 0;
      while (written < out.length) {
        written += fileIo.writeSync(target.fd, out.buffer, { offset: written, length: out.length - written });
      }
      fileIo.closeSync(target);
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG,
        'lens backfill done lens=%{public}s minF=%{public}d maxF=%{public}d minA=%{public}d maxA=%{public}d',
        lensName, minFocal, maxFocal, maxAperture, minAperture);
      return true;
    } catch (_error) {
      LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG, 'lens backfill failed %{public}s', String(_error));
      return false;
    }
  }
}

/**
 * 图片传输页的 Sync 线会话驱动：实现 CameraSessionDriver 全部回调。
 * 生命周期约定：
 *  - startImageTransfer：确认 accctrl 会话 → camcmd playmode → Browse(0,0,12)；
 *  - fetchMoreGallery/triggerScrollLoad：先幂等补发 playmode，再按已加载数续拉；
 *  - endSession：尽力发 recmode 归还遥控权（官方互切语义），保留图库与元数据，
 *    再次进入页面时网格直接可用；
 *  - Wi-Fi 链路归控制页所有，closeWifi 不做断开。
 */
export class LumixSyncGalleryDriver implements CameraSessionDriver {
  private context: common.UIAbilityContext;
  private host: string;
  private cam: CameraSessionStore = CameraSessionStore.instance;
  private dmsItems: Map<string, SyncDmsItem> = new Map<string, SyncDmsItem>();
  private fetchSeq: number = 0;
  /**
   * 上一页失败后的冷却截止时间（epoch ms）。
   *
   * 2026-10-20 ZS300 实机：一旦 DMS 开始回 403，列表滚动会在 40 秒里触发
   * 10 次续拉，每次都重切模式 + 重发 Browse，把相机彻底顶死（随后 camcmd
   * 也不再响应）。失败之后先退避，别把相机当成可以无限重试的对象。
   */
  private pageRetryNotBefore: number = 0;
  private previewPath: string = '';
  /** DMS Browse 游标：按相机应答推进，与去重后的 items.length 解耦。 */
  private nextStartIndex: number = 0;

  constructor(context: common.UIAbilityContext, host: string) {
    this.context = context;
    this.host = host;
  }

  async startImageTransfer(): Promise<void> {
    const cam = this.cam;
    if (cam.cameraGalleryLoading || cam.cameraDownloadInProgress) return;
    const seq = ++this.fetchSeq;
    cam.syncPullActive = true;
    cam.cameraSessionStatus = '认证中';
    cam.cameraMessage = '正在确认相机控制会话…';
    cam.cameraGalleryLoading = true;
    cam.cameraGalleryHasMore = false;
    try {
      const session = await LumixSyncControlService.ensureControlSession(this.context, this.host);
      if (seq !== this.fetchSeq) return;
      if (!session.ok) {
        cam.cameraMessage = `控制会话不可用：${session.message}`;
        cam.cameraSessionStatus = '未建立';
        return;
      }
      // SD 卡槽在位与当前卡：默认 SD1，无 SD1 时落到 SD2（getstate
      // current_sd/sd_memory/sd2_memory，官方浏览器同源数据）。
      await this.syncSdPresence();
      if (seq !== this.fetchSeq) return;
      cam.cameraMessage = '正在切换相机到回放模式…';
      const play = await LumixSyncControlService.sendCamCmd(this.host, 'playmode');
      if (seq !== this.fetchSeq) return;
      if (!play.ok) {
        cam.cameraMessage = `切换回放模式失败：${play.message}`;
        return;
      }
      await LumixSyncImageTransfer.delay(800);
      if (seq !== this.fetchSeq) return;
      cam.cameraMessage = '正在读取相机图库…';
      let page = await LumixSyncImageTransfer.browsePage(this.host, 0, SYNC_DMS_PAGE_SIZE);
      if (seq !== this.fetchSeq) return;
      if (!page.ok) {
        // 模式切换后 DMS 可能仍在启动，失败后补一次重试。
        await LumixSyncImageTransfer.delay(1500);
        if (seq !== this.fetchSeq) return;
        page = await LumixSyncImageTransfer.browsePage(this.host, 0, SYNC_DMS_PAGE_SIZE);
        if (seq !== this.fetchSeq) return;
      }
      if (!page.ok) {
        cam.cameraMessage = `读取相机图库失败：${page.message}`;
        cam.cameraSessionStatus = '未建立';
        return;
      }
      const items = await this.hydrateThumbs(page.items, seq);
      if (seq !== this.fetchSeq) return;
      this.dmsItems.clear();
      for (const dms of page.items) {
        this.dmsItems.set(dms.imageId, dms);
      }
      this.nextStartIndex = page.sourceCount;
      cam.cameraGalleryItems = items;
      cam.cameraGalleryTotal = page.total > 0 ? page.total : items.length;
      cam.cameraGalleryHasMore = page.total > 0
        ? this.nextStartIndex < page.total
        : items.length >= SYNC_DMS_PAGE_SIZE;
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG,
        'sync pull start done: items=%{public}d cursor=%{public}d total=%{public}d hasMore=%{public}d',
        items.length, this.nextStartIndex, cam.cameraGalleryTotal, cam.cameraGalleryHasMore ? 1 : 0);
      cam.selectedCameraImageIds = [];
      cam.cameraSessionStatus = '已建立';
      cam.cameraMessage = page.total > 0
        ? `已读取相机图库 ${items.length}/${page.total}`
        : (items.length > 0 ? `已读取相机图库 ${items.length} 张` : '相机图库为空');
    } catch (error) {
      LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG, 'sync pull start failed %{public}s', String(error));
      cam.cameraMessage = '读取相机图库失败，请重试';
    } finally {
      if (seq === this.fetchSeq) cam.cameraGalleryLoading = false;
    }
  }

  async fetchMoreGallery(): Promise<void> {
    const cam = this.cam;
    if (!cam.syncPullActive) return;
    if (cam.cameraGalleryLoading || cam.cameraDownloadInProgress) return;
    if (cam.cameraGalleryItems.length === 0) return;
    if (!cam.cameraGalleryHasMore) return;
    if (Date.now() < this.pageRetryNotBefore) {
      cam.cameraMessage = '相机图库暂时无响应，稍后自动重试';
      return;
    }
    const seq = ++this.fetchSeq;
    LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG,
      'fetch more: items=%{public}d cursor=%{public}d total=%{public}d',
      cam.cameraGalleryItems.length, this.nextStartIndex, cam.cameraGalleryTotal);
    cam.cameraGalleryLoading = true;
    try {
      // 续拉前先确认授权还新鲜：ZS300 的 accctrl 授权过期后 Browse 直接 403，
      // 而 403 与「模式没切好」在日志里长得一样，先排除前者。
      await LumixSyncControlService.ensureAccessGrantFresh(this.context, this.host);
      // 已经在回放模式时不要再发 playmode：重复的模式切换会把相机的 DMS
      // 会话重入掉（ZS300 实机第 3 页起 Browse 全部 403，见 lastAcceptedMode）。
      if (LumixSyncControlService.currentMode() !== 'playmode') {
        const play = await LumixSyncControlService.sendCamCmd(this.host, 'playmode');
        if (seq !== this.fetchSeq) return;
        if (!play.ok) {
          this.pageRetryNotBefore = Date.now() + 5000;
          cam.cameraMessage = `续拉前切换回放模式失败：${play.message}`;
          return;
        }
        // 切完模式立刻 Browse 会被相机当成并发请求，留一个稳定窗口。
        await LumixSyncImageTransfer.delay(300);
      }
      const startIndex = this.nextStartIndex;
      const page = await LumixSyncImageTransfer.browsePage(this.host, startIndex, SYNC_DMS_PAGE_SIZE);
      if (seq !== this.fetchSeq) return;
      if (!page.ok) {
        this.pageRetryNotBefore = Date.now() + 5000;
        cam.cameraMessage = `加载更多失败：${page.message}`;
        return;
      }
      const fresh: SyncDmsItem[] = [];
      for (const dms of page.items) {
        if (this.dmsItems.has(dms.imageId)) continue;
        fresh.push(dms);
      }
      this.nextStartIndex = startIndex + page.sourceCount;
      if (fresh.length === 0) {
        // 2026-09-27 实机：第 4 页(start=36)只回已见条目时，旧逻辑把
        // hasMore 永久置 false，36/72 之后永远不再加载。只要游标还没走到
        // TotalMatches 就保持可重试，让下一次触发继续向后推进。
        if (page.total > 0 && this.nextStartIndex < page.total) {
          LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG,
            'fetch more all-dupes start=%{public}d total=%{public}d; keep retryable',
            startIndex, page.total);
          cam.cameraGalleryHasMore = true;
          cam.cameraMessage = '本页照片与已加载重复，继续下滑加载更多…';
          return;
        }
        cam.cameraGalleryHasMore = false;
        cam.cameraMessage = '相机图库已全部加载';
        return;
      }
      const added = await this.hydrateThumbs(fresh, seq);
      if (seq !== this.fetchSeq) return;
      for (const dms of fresh) {
        this.dmsItems.set(dms.imageId, dms);
      }
      cam.cameraGalleryItems = cam.cameraGalleryItems.concat(added);
      if (page.total > 0 && page.total !== cam.cameraGalleryTotal) {
        cam.cameraGalleryTotal = page.total;
      }
      cam.cameraGalleryHasMore = page.total > 0
        ? this.nextStartIndex < page.total
        : fresh.length >= SYNC_DMS_PAGE_SIZE;
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG,
        'fetch more done: start=%{public}d fresh=%{public}d items=%{public}d cursor=%{public}d total=%{public}d hasMore=%{public}d',
        startIndex, fresh.length, cam.cameraGalleryItems.length, this.nextStartIndex, page.total,
        cam.cameraGalleryHasMore ? 1 : 0);
      cam.cameraMessage = `已加载 ${cam.cameraGalleryItems.length}` +
        (page.total > 0 ? `/${page.total}` : '') + ' 张';
    } catch (error) {
      LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG, 'sync pull more failed %{public}s', String(error));
      cam.cameraMessage = '加载更多失败，请稍后重试';
    } finally {
      if (seq === this.fetchSeq) cam.cameraGalleryLoading = false;
    }
  }

  async triggerScrollLoad(): Promise<void> {
    await this.fetchMoreGallery();
  }

  async endSession(): Promise<void> {
    const cam = this.cam;
    if (cam.cameraDownloadInProgress) return;
    if (cam.cameraPreviewVisible) this.closePreview();
    // 归还遥控权：官方从手动传输返回遥控时同样只发一条 recmode。
    if (LumixSyncControlService.hasControlSession(this.host)) {
      try {
        await LumixSyncControlService.sendCamCmd(this.host, 'recmode');
      } catch (_error) {
      }
    }
  }

  closePreview(): void {
    const cam = this.cam;
    cam.cameraPreviewVisible = false;
    cam.cameraPreviewLoading = false;
    cam.cameraPreviewIsVideo = false;
    cam.cameraPreviewUri = '';
    cam.cameraPreviewScale = 1;
    if (this.previewPath.length > 0) {
      try {
        fileIo.unlinkSync(this.previewPath);
      } catch (_error) {
      }
      this.previewPath = '';
    }
  }

  async openPreview(item: LumixGalleryItem): Promise<void> {
    const cam = this.cam;
    const dms = this.dmsItems.get(item.imageId);
    if (dms === undefined) {
      cam.cameraMessage = '该照片的图库信息已失效，请重新读取图库';
      return;
    }
    if (dms.isVideo) {
      if (dms.downloadUrl.length === 0) {
        cam.cameraMessage = '该视频没有可用的播放地址';
        return;
      }
      if (cam.cameraDownloadInProgress) return;
      cam.cameraPreviewVisible = true;
      cam.cameraPreviewLoading = true;
      cam.cameraPreviewIsVideo = true;
      cam.cameraPreviewUri = '';
      // 视频不落盘：幂等拉回回放模式后，把相机 res URL 直接交给 Video
      // 组件流式播放（MOV/AVCHD 容器若解码失败由前端展示兜底文案）。
      try {
        await LumixSyncControlService.sendCamCmd(this.host, 'playmode');
      } catch (_error) {
      }
      await LumixSyncImageTransfer.delay(400);
      if (!cam.cameraPreviewVisible) {
        cam.cameraPreviewIsVideo = false;
        return;
      }
      cam.cameraPreviewUri = dms.downloadUrl;
      cam.cameraPreviewLoading = false;
      return;
    }
    if (dms.isRaw) {
      cam.cameraMessage = 'RAW 原图预览暂不支持，可勾选后下载导入';
      return;
    }
    if (dms.downloadUrl.length === 0) {
      cam.cameraMessage = '该照片没有可用的原图下载地址';
      return;
    }
    if (cam.cameraDownloadInProgress) return;
    cam.cameraPreviewVisible = true;
    cam.cameraPreviewLoading = true;
    cam.cameraPreviewIsVideo = false;
    cam.cameraPreviewUri = '';
    // 预览可能发生在返回过的会话（机身已回 recmode），先幂等拉回回放。
    await LumixSyncControlService.ensureAccessGrantFresh(this.context, this.host);
    try {
      await LumixSyncControlService.sendCamCmd(this.host, 'playmode');
    } catch (_error) {
    }
    await LumixSyncImageTransfer.delay(400);
    const fileName = `lumix_sync_preview_${LumixSyncImageTransfer.safeToken(dms.imageId)}.jpg`;
    let uri = await LumixSyncImageTransfer.downloadToFile(this.context, dms.downloadUrl, fileName,
      60000, undefined, dms.downloadSize, this.host);
    if (uri.length === 0) {
      // 同一张原图在授权过期后第一次必失败（2026-10-21 10:03 日志：http=0）。
      // 续一次授权再取，避免用户看到「原图加载失败」却重试也无效。
      const refreshed = await LumixSyncControlService.refreshAccessGrant(this.context, this.host);
      if (refreshed) {
        await LumixSyncImageTransfer.delay(300);
        uri = await LumixSyncImageTransfer.downloadToFile(this.context, dms.downloadUrl, fileName,
          60000, undefined, dms.downloadSize, this.host);
      }
    }
    if (!cam.cameraPreviewVisible) {
      // 用户已在下载期间关闭预览，丢弃半成品。
      if (uri.length > 0) {
        try {
          fileIo.unlinkSync(uri.substring('file://'.length));
        } catch (_error) {
        }
      }
      return;
    }
    if (uri.length === 0) {
      cam.cameraPreviewLoading = false;
      cam.cameraMessage = '原图加载失败';
      return;
    }
    cam.cameraPreviewUri = uri;
    cam.cameraPreviewLoading = false;
    this.previewPath = uri.substring('file://'.length);
  }

  /**
   * 选中/取消选中。
   *
   * 传入的是 `LumixImportPrototype.galleryItemKey(item)`（`imageId:imageType`），
   * **不是**裸 `imageId`——同一个 ImageId 的 JPG 卡与 RAW 卡共用编号，只用
   * imageId 会让两张卡一起被选中。比较点必须用同一个键，否则选中项全部落空。
   */
  toggleSelection(itemKey: string): void {
    const cam = this.cam;
    const index = cam.selectedCameraImageIds.indexOf(itemKey);
    if (index >= 0) {
      cam.selectedCameraImageIds = cam.selectedCameraImageIds.filter((id: string) => id !== itemKey);
    } else {
      cam.selectedCameraImageIds = cam.selectedCameraImageIds.concat([itemKey]);
    }
  }

  /** 统计选中项里能映射到 DIDL 资源的个数，并把网格/选中/映射三个数记进日志。 */
  private planFileCount(): number {
    const cam = this.cam;
    let mapped = 0;
    let total = 0;
    for (const item of cam.cameraGalleryItems) {
      // 选中项存的是 galleryItemKey（imageId:imageType），不是裸 imageId。
      // 用裸 imageId 比对会让所有选中项都落空，最终报「没有可用的原图地址」。
      if (cam.selectedCameraImageIds.indexOf(LumixImportPrototype.galleryItemKey(item)) < 0) continue;
      const dms = this.dmsItems.get(item.imageId);
      if (dms === undefined || dms.downloadUrl.length === 0) continue;
      mapped += 1;
      total += 1;
      if (!dms.isVideo && dms.rawDownloadUrl.length > 0) total += 1;
    }
    if (mapped === 0 && cam.selectedCameraImageIds.length > 0) {
      // 一个都映射不上时，把两侧各一个样本打出来：选中键与网格键的形态差异
      // （imageId 与 imageId:imageType）一眼可辨，不必再靠猜。
      const firstSelected = cam.selectedCameraImageIds[0];
      const firstGrid = cam.cameraGalleryItems.length > 0
        ? LumixImportPrototype.galleryItemKey(cam.cameraGalleryItems[0]) : '';
      LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG,
        'download plan mismatch selectedKey=%{public}s gridKey=%{public}s',
        firstSelected, firstGrid);
    }
    LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG,
      'download plan grid=%{public}d selected=%{public}d mapped=%{public}d files=%{public}d',
      cam.cameraGalleryItems.length, cam.selectedCameraImageIds.length, mapped, total);
    return total;
  }

  /** 重新拉第 0 页 DIDL 并补进映射表；用于选中项找不到下载地址时自愈。 */
  private async rebuildDmsItems(): Promise<boolean> {
    try {
      // 刚切过 playmode 就 Browse 会被相机判成并发请求而回 403
      // （2026-10-23 日志：playmode 后 440 ms Browse → 403）。留足稳定窗口。
      await LumixSyncImageTransfer.delay(900);
      const page = await LumixSyncImageTransfer.browsePage(this.host, 0, SYNC_DMS_PAGE_SIZE);
      if (!page.ok) {
        LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG,
          'download plan rebuild failed: %{public}s', page.message);
        return false;
      }
      for (const dms of page.items) {
        this.dmsItems.set(dms.imageId, dms);
      }
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG,
        'download plan rebuilt items=%{public}d', page.items.length);
      return true;
    } catch (error) {
      LumixSyncImageTransfer.warnBoth(0x0001, SYNC_DMS_TAG,
        'download plan rebuild error: %{public}s', String(error));
      return false;
    }
  }

  async downloadSelected(): Promise<void> {
    const cam = this.cam;
    LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, 'download selected count=%{public}d inProgress=%{public}d',
      cam.selectedCameraImageIds.length, cam.cameraDownloadInProgress ? 1 : 0);
    if (cam.cameraDownloadInProgress) return;
    if (cam.selectedCameraImageIds.length === 0) {
      cam.cameraMessage = '请先勾选要下载的照片';
      return;
    }
    cam.cameraDownloadInProgress = true;
    cam.cameraDownloadProgress = 0;
    cam.cameraDownloadStatus = '准备下载原始文件…';
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const permissionResult =
        await manager.requestPermissionsFromUser(this.context, ['ohos.permission.WRITE_IMAGEVIDEO']);
      const granted = permissionResult.authResults.length > 0 && permissionResult.authResults[0] === 0;
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, 'download permission granted=%{public}d', granted ? 1 : 0);
      if (!granted) {
        cam.cameraMessage = '需要「保存到相册」权限才能下载';
        return;
      }
      // 长会话里 accctrl 授权会先过期；先续一次再动模式，否则接下来的
      // playmode 与原图 GET 会一起失败（2026-10-21 10:03 日志）。
      await LumixSyncControlService.ensureAccessGrantFresh(this.context, this.host);
      const play = await LumixSyncControlService.sendCamCmd(this.host, 'playmode');
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, 'download playmode ok=%{public}d', play.ok ? 1 : 0);
      await LumixSyncImageTransfer.delay(400);

      // 诊断先行：2026-10-21 10:03 的日志里 downloadSelected 只留下 playmode
      // 与 recmode 两行就结束了，无法判断是「网格空了」「选中项对不上 DIDL」
      // 还是「DIDL 没给原图地址」。planFileCount() 把这三个数分开记。
      let totalFiles = this.planFileCount();
      if (totalFiles === 0) {
        // 映射丢失（驱动被重建、图库在别的实例里加载过）时重建一次 DIDL 再试，
        // 而不是直接回「没有可用的原图地址」。
        if (await this.rebuildDmsItems()) {
          totalFiles = this.planFileCount();
        }
      }
      if (totalFiles === 0) {
        cam.cameraMessage = '所选照片没有可用的原图地址';
        return;
      }

      let completed = 0;
      let saved = 0;
      let savedVideos = 0;
      let failed = 0;
      for (const item of cam.cameraGalleryItems) {
        // 选中项存的是 galleryItemKey（imageId:imageType），不是裸 imageId。
      // 用裸 imageId 比对会让所有选中项都落空，最终报「没有可用的原图地址」。
      if (cam.selectedCameraImageIds.indexOf(LumixImportPrototype.galleryItemKey(item)) < 0) continue;
        const dms = this.dmsItems.get(item.imageId);
        if (dms === undefined || dms.downloadUrl.length === 0) {
          failed += 1;
          continue;
        }
        const primaryIndex = completed;
        completed += 1;
        cam.cameraDownloadStatus = `正在下载 ${primaryIndex + 1}/${totalFiles} · ${dms.displayName}`;
        LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, 'download file start index=%{public}d/%{public}d url=%{public}s',
          primaryIndex + 1, totalFiles, dms.downloadUrl);
        const fetchOriginal = async (): Promise<string> => {
          return await LumixSyncImageTransfer.downloadToFile(this.context, dms.downloadUrl,
            `lumix_sync_original_${primaryIndex}_${LumixSyncImageTransfer.safeToken(dms.displayName)}`,
            dms.isVideo ? 180000 : 120000,
            (received: number, total: number): void => {
              const fileTotal = total > 0 ? total : (dms.downloadSize > 0 ? dms.downloadSize : received);
              const fileShare = fileTotal > 0 ? Math.min(1, received / fileTotal) : 0;
              cam.cameraDownloadProgress = Math.min(100, Math.round(((primaryIndex + fileShare) / totalFiles) * 100));
            }, dms.downloadSize, this.host);
        };
        let primaryUri = await fetchOriginal();
        if (primaryUri.length === 0) {
          // ZS300 的 accctrl 授权约 60 秒过期，之后原图 GET 直接断连（http=0）。
          // 重发一次 req_acc 再取同一张，比重试同一个已失效的授权有效。
          const refreshed = await LumixSyncControlService.refreshAccessGrant(this.context, this.host);
          if (refreshed) {
            await LumixSyncImageTransfer.delay(300);
            primaryUri = await fetchOriginal();
          }
        }
        if (primaryUri.length === 0) {
          failed += 1;
        } else if (await this.saveDownloadedAsset(primaryUri, dms.displayName, dms.isVideo, item.thumbnailUri)) {
          if (dms.isVideo) savedVideos += 1;
          else saved += 1;
        } else {
          failed += 1;
        }

        // The RAW pair is a second <res>, not an alternate extension for the
        // JPEG resource. Keep it as an independently checked transfer.
        if (!dms.isVideo && dms.rawDownloadUrl.length > 0) {
          const rawIndex = completed;
          completed += 1;
          const rawName = dms.rawDisplayName.length > 0 ? dms.rawDisplayName : `${dms.displayName}.RW2`;
          cam.cameraDownloadStatus = `正在下载 ${rawIndex + 1}/${totalFiles} · ${rawName}`;
          const rawUri = await LumixSyncImageTransfer.downloadToFile(this.context, dms.rawDownloadUrl,
            `lumix_sync_raw_${rawIndex}_${LumixSyncImageTransfer.safeToken(rawName)}`,
            180000,
            (received: number, total: number): void => {
              const fileTotal = total > 0 ? total : (dms.rawSize > 0 ? dms.rawSize : received);
              const fileShare = fileTotal > 0 ? Math.min(1, received / fileTotal) : 0;
              cam.cameraDownloadProgress = Math.min(100, Math.round(((rawIndex + fileShare) / totalFiles) * 100));
            }, dms.rawSize, this.host);
          if (rawUri.length === 0) {
            failed += 1;
          } else if (await this.saveDownloadedAsset(rawUri, rawName, false, item.thumbnailUri)) {
            saved += 1;
          } else {
            failed += 1;
          }
        }
      }
      const summary: string[] = [];
      if (saved > 0) summary.push(`已保存 ${saved} 张原图`);
      if (savedVideos > 0) summary.push(`${savedVideos} 个视频`);
      if (failed > 0) summary.push(`${failed} 个失败`);
      cam.cameraMessage = summary.length > 0 ? summary.join('，') : '没有可下载的文件';
      cam.selectedCameraImageIds = [];
    } catch (error) {
      LumixSyncImageTransfer.errorBoth(0x0001, SYNC_DMS_TAG, 'batch import failed %{public}s', String(error));
      cam.cameraMessage = '图片保存失败，请检查图库权限';
    } finally {
      cam.cameraDownloadProgress = 100;
      cam.cameraDownloadStatus = '下载完成';
      setTimeout(() => {
        cam.cameraDownloadInProgress = false;
      }, 350);
      // 下载入口发过 playmode：完成后切回拍摄模式，避免相机控制页返回
      // 时 startstream 被拒（2026-09-28 实测 err_reject）。
      LumixSyncControlService.sendCamCmd(this.host, 'recmode').then((result: LumixSyncCamCmdResult): void => {
        LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG, 'download recmode restore ok=%{public}d', result.ok ? 1 : 0);
      }).catch(() => {
      });
    }
  }

  /** 诊断：扫描下载文件前 512KB 的镜头信息 ASCII 字符串（RW2/JPG 的
   *  EXIF MakerNote 里镜头名以明文存储），落 hilog 供「下载图片镜头信息
  /** Persist a fully validated camera resource and add the durable asset to recent works. */
  private async saveDownloadedAsset(sourceUri: string, displayName: string, isVideo: boolean,
    fallbackThumbUri: string): Promise<boolean> {
    const sourcePath = sourceUri.substring('file://'.length);
    try {
      LumixSyncImageTransfer.scanLensEvidence(sourcePath);
      // 注意：EXIF 镜头标签回填（backfillLensExif）已搁置——自建 IFD
      // 注入导致图库连拍摄参数都读不出（2026-09-28 实测）。恢复原始
      // 字节直存，待后续用可靠方案（专用 EXIF 库 / Pixelshop 解析器
      // 读 MakerNote 字符串）再处理。
      const extension = LumixSyncImageTransfer.extensionForName(displayName, isVideo ? 'mp4' : 'jpg');
      const sourceSize = Number(fileIo.statSync(sourcePath).size);
      if (sourceSize <= 0) throw new Error('Downloaded file is empty');
      const helper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const uri = await helper.createAsset(
        isVideo ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE,
        extension, { title: LumixSyncImageTransfer.titleOf(displayName, 0) });
      const writtenBytes = await LumixSyncImageTransfer.copyFileChunked(sourcePath, uri);
      if (writtenBytes !== sourceSize) {
        throw new Error(`Media library write mismatch expected=${sourceSize} actual=${writtenBytes}`);
      }
      LumixSyncImageTransfer.logBoth(0x0001, SYNC_DMS_TAG,
        'import asset name=%{public}s ext=%{public}s video=%{public}d bytes=%{public}d',
        displayName, extension, isVideo ? 1 : 0, writtenBytes);
      if (WorksBridge.addImportedPhoto !== null) {
        // Sync / Image App 线的 DLNA DIDL 没有方向字段（`<res>` 只有
        // `resolution` 和 `OriginalFileName`），传 0 表示"相机未给方向"。
        // 这条线下载的是原图 JPEG，EXIF Orientation 由系统解码器应用，
        // 缩略图本来就是正的；横竖由解码后的实际像素尺寸判定。
        await WorksBridge.addImportedPhoto(uri, displayName, fallbackThumbUri, 0);
      }
      try {
        fileIo.unlinkSync(sourcePath);
      } catch (_unlinkError) {
      }
      return true;
    } catch (error) {
      LumixSyncImageTransfer.errorBoth(0x0001, SYNC_DMS_TAG, 'import asset failed name=%{public}s %{public}s',
        displayName, String(error));
      return false;
    }
  }
  /** Sync 线的 Wi-Fi 归控制会话所有；图片传输退出不主动断链。 */
  async closeWifi(): Promise<void> {
  }

  /** 读取当前卡与卡槽在位状态（getstate current_sd/sd_memory/sd2_memory）。 */
  private async syncSdPresence(): Promise<void> {
    const cam = this.cam;
    try {
      const state = await LumixSyncControlService.fetchSyncState(this.host);
      if (!state.ok) {
        return;
      }
      const tagOf = (name: string): string => {
        const open = `<${name}>`;
        const start = state.body.indexOf(open);
        if (start < 0) {
          return '';
        }
        const from = start + open.length;
        const end = state.body.indexOf(`</${name}>`, from);
        return end < 0 ? '' : state.body.substring(from, end).trim();
      };
      cam.cameraSd1Present = tagOf('sd_memory') === 'set';
      cam.cameraSd2Present = tagOf('sd2_memory') === 'set';
      cam.cameraSdPresenceSource = 'sync-probe';
      const current = tagOf('current_sd');
      if (current === 'sd1' || current === 'sd2') {
        cam.selectedSd = current === 'sd1' ? 'SD1' : 'SD2';
      } else if (!cam.cameraSd1Present && cam.cameraSd2Present) {
        cam.selectedSd = 'SD2';
      } else {
        cam.selectedSd = 'SD1';
      }
    } catch (_error) {
    }
  }

  /** SD 卡切换：官方浏览器用 setsetting current_sd=sd1/sd2
   *  （com/panasonic/jp/view/play/browser/j.java L("current_sd", value)），
   *  切换后重新拉取相机图库。 */
  async switchSd(sd: string): Promise<void> {
    const cam = this.cam;
    const wire = sd === 'SD2' ? 'sd2' : 'sd1';
    cam.cameraMessage = `正在切换存储卡 ${sd}…`;
    const result = await LumixSyncControlService.sendCamSetting(this.host, 'current_sd', wire);
    if (!result.ok) {
      cam.cameraMessage = `无法切换存储卡：${result.message}`;
      return;
    }
    cam.selectedSd = sd;
    // 切换后重新拉取：清空网格与 DIDL 缓存，走完整起始流程（playmode
    // + 全新 Browse）。
    cam.cameraGalleryItems = [];
    cam.cameraGalleryTotal = 0;
    cam.cameraGalleryHasMore = false;
    this.dmsItems.clear();
    this.nextStartIndex = 0;
    await this.startImageTransfer();
  }

  /** 逐张下载缩略图并映射为图片传输页的网格条目；失败留空占位。 */
  private async hydrateThumbs(items: SyncDmsItem[], seq: number): Promise<LumixGalleryItem[]> {
    const out: LumixGalleryItem[] = [];
    let index = 0;
    for (const dms of items) {
      if (seq !== this.fetchSeq) return out;
      let thumbUri = '';
      if (dms.thumbUrl.length > 0) {
        this.cam.cameraMessage = `正在加载缩略图 ${index + 1}/${items.length}…`;
        const fileName = `lumix_sync_thumb_${LumixSyncImageTransfer.safeToken(dms.imageId)}.jpg`;
        const uri = await LumixSyncImageTransfer.downloadToFile(this.context, dms.thumbUrl, fileName,
          15000, undefined, 0, this.host);
        if (uri.length > 0) thumbUri = uri;
      }
      out.push({
        imageId: dms.imageId,
        imageType: LumixSyncImageTransfer.imageTypeOf(dms),
        thumbnailUri: thumbUri,
        size: dms.downloadSize,
        rawSize: dms.rawDownloadUrl.length > 0 ? dms.rawSize : undefined,
        originalFileName: dms.displayName,
      });
      index += 1;
    }
    return out;
  }
}
