import socket from '@ohos.net.socket';
import wifiManager from '@ohos.wifiManager';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';
import { util } from '@kit.ArkTS';

/** Metadata for one file pushed by an original Panasonic S5. */
export interface PanasonicS5ReceivedFile {
  path: string;
  name: string;
  size: number;
  extension: string;
}

export interface PanasonicS5ReceiverCallbacks {
  onSessionStart?: (remote: string) => void;
  onProgress?: (received: number, total: number) => void;
  onFile?: (file: PanasonicS5ReceivedFile) => void;
  onSessionEnd?: () => void;
  onError?: (message: string) => void;
}

export interface PanasonicS5ReceiverOptions {
  /** The same Vivid-owned stable id sent in accctrl/req_acc. */
  clientUuid?: string;
  /** Camera gateway learned from the active Wi-Fi network; never hard-coded. */
  peerHost?: string;
}

interface HttpRequestInfo {
  method: string;
  path: string;
  headers: Map<string, string>;
  contentLength: number;
  chunked: boolean;
  soapAction: string;
  isUpload: boolean;
  isCreateObject: boolean;
}

interface UploadState {
  name: string;
  extension: string;
  path: string;
  file: fileIo.File | null;
  received: number;
  total: number;
  /** 0 = chunked framing, 1 = plain Content-Length body, 2 = raw legacy stream. */
  mode: number;
  /** Chunked stages: 0 = size line, 1 = chunk data, 2 = trailing CRLF. */
  chunkStage: number;
  chunkRemain: number;
  plainRemain: number;
}

interface ConnectionState {
  port: number;
  counter: number;
  buffer: Uint8Array;
  /** 0 = request header, 1 = control request body, 2 = upload payload. */
  phase: number;
  request: HttpRequestInfo | null;
  bodyReceived: number;
  createBody: string;
  upload: UploadState | null;
}

interface PendingCreateEntry {
  name: string;
  time: number;
  objectId: string;
  importUri: string;
  size: number;
  resolution: string;
  protocolInfo: string;
}

/**
 * Passive DMS/DLNA receiver for the LUMIX Image App line (`lumix_image`).
 *
 * The LUMIX Image App / Lumix Link 2.0 generation has no Bluetooth code at all
 * (Image App 1.9.0: zero hits for BluetoothAdapter/BluetoothGatt/BLE across
 * Java, smali, resources, manifest and native strings). It discovers the body
 * with an SSDP M-SEARCH to 239.255.255.250:1900, drives it through cam.cgi and
 * exchanges images over DLNA. The reverse direction — the phone running its own
 * DMS so the camera can push to it — is exactly the capability that line needs,
 * so this receiver is bound to `lumix_image`. The LUMIX Sync line pairs over
 * Bluetooth and pulls images actively after joining the camera access point with
 * the BLE-delivered SSID and password, so it no longer starts this session.
 *
 * Decoded from the LUMIX Sync native capture (nativehook_v5): after req_acc
 * the camera connects back to the local listeners (49152 control, 50000
 * upload) and drives a fixed HTTP exchange per file:
 *   control conn: GET /dms/ddd.xml -> POST /dms/control_0
 *                 (X_GetDLNAUploadProfiles, 646B body)
 *                 -> POST /dms/control_0 (CreateObject, 1038/1042B body that
 *                 carries the real file name in DIDL dc:title)
 *   upload conn:  POST /MEDIA-<id>-i-<n> with Transfer-Encoding: chunked
 *                 (64KB chunks), Expect: 100-continue, Content-Type
 *                 image/jpeg for BOTH JPG and RW2 - the RAW marker lives in
 *                 contentfeatures.dlna.org (PANASONIC.COM_PN=CAM_RAW).
 * The phone answers the two control actions with SOAP bodies, answers each
 * upload request with HTTP 100 Continue, then returns HTTP 200 after the
 * complete body. The receiver therefore implements a real HTTP request state
 * machine with chunked de-framing instead of assuming Content-Length uploads.
 */
export class PanasonicS5Receiver {
  private static readonly PORTS: number[] = [50000, 49152];
  private static readonly SSDP_PORT: number = 1900;
  private static readonly SSDP_GROUP: string = '239.255.255.250';
  private static readonly PHASE_HEADER: number = 0;
  private static readonly PHASE_BODY: number = 1;
  private static readonly PHASE_UPLOAD: number = 2;
  private static readonly UPLOAD_CHUNKED: number = 0;
  private static readonly UPLOAD_PLAIN: number = 1;
  private static readonly UPLOAD_RAW: number = 2;
  private static readonly MAX_CREATE_BODY: number = 16384;
  private static readonly MAX_HEADER_BYTES: number = 65536;
  private static servers: socket.TCPSocketServer[] = [];
  private static clients: socket.TCPSocketConnection[] = [];
  private static states: Map<socket.TCPSocketConnection, ConnectionState> = new Map();
  private static ssdp: socket.UDPSocket | null = null;
  private static advertisementTimer: number | undefined = undefined;
  private static localIp: string = '';
  private static controlPort: number = 49152;
  private static peerHost: string = '';
  private static clientUuid: string = '';
  private static callbacks: PanasonicS5ReceiverCallbacks | null = null;
  private static context: common.UIAbilityContext | null = null;
  private static running: boolean = false;
  private static fileCounter: number = 0;
  private static objectCounter: number = 1;
  private static pendingCreates: PendingCreateEntry[] = [];

  static isRunning(): boolean {
    return PanasonicS5Receiver.running;
  }

  static async start(context: common.UIAbilityContext, callbacks: PanasonicS5ReceiverCallbacks,
    options?: PanasonicS5ReceiverOptions): Promise<void> {
    await PanasonicS5Receiver.stop();
    PanasonicS5Receiver.context = context;
    PanasonicS5Receiver.callbacks = callbacks;
    PanasonicS5Receiver.clientUuid = PanasonicS5Receiver.normalizeUuid(options?.clientUuid || '');
    if (PanasonicS5Receiver.clientUuid.length === 0) {
      PanasonicS5Receiver.clientUuid = PanasonicS5Receiver.makeUuid();
    }
    PanasonicS5Receiver.peerHost = PanasonicS5Receiver.normalizeHost(options?.peerHost || '');
    PanasonicS5Receiver.localIp = PanasonicS5Receiver.readLocalIp();
    PanasonicS5Receiver.controlPort = 49152;
    PanasonicS5Receiver.running = true;
    let bound = 0;
    let uploadPortBound = false;
    for (const port of PanasonicS5Receiver.PORTS) {
      try {
        const server = socket.constructTCPSocketServerInstance();
        server.on('connect', (client: socket.TCPSocketConnection): void => {
          PanasonicS5Receiver.attach(client, port);
        });
        server.on('error', (error: Error): void => {
          // 49152 is an optional control/discovery listener. It may be
          // occupied by another local service while the required DMS upload
          // port 50000 is still healthy; do not turn that optional event into
          // a user-facing "S5 listener failed" state.
          if (port === 50000) PanasonicS5Receiver.report(`监听端口 ${port} 失败`);
          PanasonicS5Receiver.logError(`server ${port}`, error);
        });
        await server.listen({ address: '0.0.0.0', family: 1, port: port });
        PanasonicS5Receiver.servers.push(server);
        bound++;
        if (port === 50000) uploadPortBound = true;
      } catch (error) {
        // 49152 is an optional DLNA endpoint.  The DMS endpoint on 50000 is
        // required; a failure on that port is surfaced to the UI.
        PanasonicS5Receiver.logError(`listen ${port}`, error);
        if (port === 50000) PanasonicS5Receiver.report('无法开启 S5 图片接收监听');
        if (port === 49152) PanasonicS5Receiver.controlPort = 50000;
      }
    }
    if (!uploadPortBound || bound === 0) {
      PanasonicS5Receiver.running = false;
      throw new Error('No S5 receiver port could be bound');
    }
    // The S5 is a push sender. LUMIX Sync's native DMS layer advertises a
    // MediaServer after req_acc; a raw TCP listener alone is invisible to the
    // camera. Advertise only after the upload/descriptor port is ready so the
    // camera cannot race a description request against bind().
    await PanasonicS5Receiver.startSsdp();
    hilog.info(0x0000, 'VIVID_S5', `passive receiver started ports=${bound}`);
    AppLogSink.emit('CTL', 'passive receiver started ports=' + bound);
  }

  static async stop(): Promise<void> {
    PanasonicS5Receiver.running = false;
    // LUMIX Sync withdraws the previous DMS advertisement before closing its
    // sockets. This prevents an S5 from retaining a stale client endpoint when
    // Vivid retries the handshake or the Wi-Fi association changes.
    if (PanasonicS5Receiver.ssdp && PanasonicS5Receiver.localIp.length > 0) {
      try { await PanasonicS5Receiver.sendAdvertisements('ssdp:byebye'); } catch (_error) { }
    }
    const clients = PanasonicS5Receiver.clients.slice();
    PanasonicS5Receiver.clients = [];
    for (const client of clients) {
      try { client.close(); } catch (_error) { }
    }
    for (const state of PanasonicS5Receiver.states.values()) {
      if (state.upload) PanasonicS5Receiver.closeUpload(state.upload, state.upload.received > 0);
    }
    PanasonicS5Receiver.states.clear();
    const servers = PanasonicS5Receiver.servers.slice();
    PanasonicS5Receiver.servers = [];
    for (const server of servers) {
      try { await server.close(); } catch (_error) { }
    }
    if (PanasonicS5Receiver.advertisementTimer !== undefined) {
      clearInterval(PanasonicS5Receiver.advertisementTimer);
      PanasonicS5Receiver.advertisementTimer = undefined;
    }
    if (PanasonicS5Receiver.ssdp) {
      try { await PanasonicS5Receiver.ssdp.close(); } catch (_error) { }
      PanasonicS5Receiver.ssdp = null;
    }
    PanasonicS5Receiver.pendingCreates = [];
    PanasonicS5Receiver.objectCounter = 1;
    PanasonicS5Receiver.localIp = '';
    PanasonicS5Receiver.controlPort = 49152;
    PanasonicS5Receiver.peerHost = '';
    PanasonicS5Receiver.clientUuid = '';
    PanasonicS5Receiver.callbacks = null;
    PanasonicS5Receiver.context = null;
  }

  private static attach(client: socket.TCPSocketConnection, port: number): void {
    PanasonicS5Receiver.clients.push(client);
    const state: ConnectionState = {
      port: port, counter: PanasonicS5Receiver.fileCounter++, buffer: new Uint8Array(0),
      phase: PanasonicS5Receiver.PHASE_HEADER, request: null, bodyReceived: 0, createBody: '',
      upload: null,
    };
    PanasonicS5Receiver.states.set(client, state);
    // The socket API exposes getRemoteAddress() as a Promise on API 26. The
    // UI only needs a redacted connection marker, so do not block attachment
    // on resolving a peer address.
    const remote = `port=${port}`;
    const callback = PanasonicS5Receiver.callbacks;
    if (port === 50000 && callback && callback.onSessionStart) callback.onSessionStart(remote);
    client.on('message', (info: socket.SocketMessageInfo): void => {
      const value = info && info.message ? new Uint8Array(info.message) : new Uint8Array(0);
      if (value.length === 0) return;
      PanasonicS5Receiver.processBytes(client, state, value);
    });
    client.on('close', (): void => {
      PanasonicS5Receiver.finish(client, state);
    });
    client.on('error', (error: Error): void => {
      PanasonicS5Receiver.logError('client', error);
      PanasonicS5Receiver.finish(client, state);
    });
  }

  private static processBytes(client: socket.TCPSocketConnection, state: ConnectionState, value: Uint8Array): void {
    state.buffer = PanasonicS5Receiver.concat(state.buffer, value);
    PanasonicS5Receiver.processBuffer(client, state);
  }

  private static processBuffer(client: socket.TCPSocketConnection, state: ConnectionState): void {
    while (true) {
      if (state.phase === PanasonicS5Receiver.PHASE_HEADER) {
        // Wait until the method prefix can be sniffed reliably.
        if (state.buffer.length < 8) return;
        const prefix = PanasonicS5Receiver.decodeAscii(state.buffer.slice(0, 8)).toUpperCase();
        if (!PanasonicS5Receiver.isHttpMethodPrefix(prefix)) {
          // Some firmware revisions use a compact proprietary framing rather
          // than HTTP. Preserve those bytes as a file without logging payloads.
          PanasonicS5Receiver.beginRawUpload(state);
          continue;
        }
        const marker = PanasonicS5Receiver.findHeaderEnd(state.buffer);
        if (marker < 0) {
          if (state.buffer.length > PanasonicS5Receiver.MAX_HEADER_BYTES) {
            PanasonicS5Receiver.logEvent('header overflow; drop connection');
            PanasonicS5Receiver.finish(client, state);
            try { client.close(); } catch (_error) { }
          }
          return;
        }
        const headerBytes = state.buffer.slice(0, marker + 4);
        state.buffer = state.buffer.slice(marker + 4);
        const request = PanasonicS5Receiver.parseRequest(headerBytes);
        PanasonicS5Receiver.handleRequest(client, state, request);
        continue;
      }
      if (state.phase === PanasonicS5Receiver.PHASE_BODY) {
        const request = state.request;
        if (!request) {
          state.phase = PanasonicS5Receiver.PHASE_HEADER;
          continue;
        }
        const need = request.contentLength - state.bodyReceived;
        if (need <= 0) {
          PanasonicS5Receiver.finishControlRequest(client, state);
          continue;
        }
        if (state.buffer.length === 0) return;
        const take = Math.min(need, state.buffer.length);
        const part = state.buffer.slice(0, take);
        state.buffer = state.buffer.slice(take);
        state.bodyReceived += take;
        if (request.isCreateObject && state.createBody.length < PanasonicS5Receiver.MAX_CREATE_BODY) {
          const room = PanasonicS5Receiver.MAX_CREATE_BODY - state.createBody.length;
          state.createBody += PanasonicS5Receiver.decodeAscii(part.slice(0, room));
        }
        if (state.bodyReceived >= request.contentLength) {
          PanasonicS5Receiver.finishControlRequest(client, state);
          continue;
        }
        return;
      }
      const progressed = PanasonicS5Receiver.processUpload(client, state);
      if (!progressed) return;
    }
  }

  private static parseRequest(headerBytes: Uint8Array): HttpRequestInfo {
    const text = PanasonicS5Receiver.decodeAscii(headerBytes);
    const lines = text.split('\r\n');
    const firstLine = lines.length > 0 ? lines[0] : '';
    const parts = firstLine.split(' ');
    const method = (parts.length > 0 ? parts[0] : '').toUpperCase();
    const path = parts.length > 1 ? parts[1] : '/';
    const headers = new Map<string, string>();
    for (let i = 1; i < lines.length; i++) {
      const line = lines[i];
      const separator = line.indexOf(':');
      if (separator <= 0) continue;
      headers.set(line.slice(0, separator).trim().toLowerCase(), line.slice(separator + 1).trim());
    }
    const parsedLength = Number.parseInt(headers.get('content-length') || '0', 10);
    const contentLength = Number.isFinite(parsedLength) && parsedLength > 0 ? parsedLength : 0;
    const transferEncoding = (headers.get('transfer-encoding') || '').toLowerCase();
    const chunked = transferEncoding.indexOf('chunked') >= 0;
    const soapAction = headers.get('soapaction') || '';
    const contentType = (headers.get('content-type') || '').toLowerCase();
    const legacyMarkers = (headers.get('content-disposition') || headers.get('x-file-name') ||
      headers.get('x-filename') || '').length > 0 || contentType.indexOf('octet-stream') >= 0;
    const isControl = soapAction.length > 0 || contentType.indexOf('text/xml') >= 0;
    // The real S5 upload is POST /MEDIA-<id>-i-<n> with chunked framing and
    // no Content-Disposition; the marker list only covers legacy firmware.
    const isUpload = method === 'POST' && !isControl &&
      (chunked || path.toUpperCase().indexOf('/MEDIA') === 0 || legacyMarkers);
    const request: HttpRequestInfo = {
      method: method, path: path, headers: headers, contentLength: contentLength,
      chunked: chunked, soapAction: soapAction, isUpload: isUpload,
      isCreateObject: soapAction.indexOf('CreateObject') >= 0,
    };
    return request;
  }

  private static handleRequest(client: socket.TCPSocketConnection, state: ConnectionState,
    request: HttpRequestInfo): void {
    if (request.isUpload) {
      PanasonicS5Receiver.beginUpload(client, state, request);
      return;
    }
    if (request.method === 'GET' || request.method === 'HEAD') {
      const xml = PanasonicS5Receiver.xmlForPath(request.path);
      if (xml.length > 0) {
        PanasonicS5Receiver.sendDmsHttp(client, 200, 'text/xml; charset="utf-8"', request.method === 'HEAD' ? '' : xml, true, false);
      } else {
        PanasonicS5Receiver.sendHttp(client, 404, 'text/plain; charset="utf-8"', '');
      }
      PanasonicS5Receiver.logEvent(`DMS ${request.method} ${PanasonicS5Receiver.pathLabel(request.path)}`);
      return;
    }
    if (request.method === 'SUBSCRIBE' || request.method === 'UNSUBSCRIBE') {
      PanasonicS5Receiver.sendSubscriptionResponse(client, request.method === 'SUBSCRIBE');
      PanasonicS5Receiver.logEvent(`DMS ${request.method}`);
      return;
    }
    if (request.method === 'POST') {
      state.request = request;
      state.bodyReceived = 0;
      state.createBody = '';
      if (request.contentLength > 0) {
        state.phase = PanasonicS5Receiver.PHASE_BODY;
        return;
      }
      PanasonicS5Receiver.finishControlRequest(client, state);
      return;
    }
    PanasonicS5Receiver.sendHttp(client, 200, 'text/plain; charset="utf-8"', '');
    PanasonicS5Receiver.logEvent(`DMS ${request.method} ignored`);
  }

  private static finishControlRequest(client: socket.TCPSocketConnection, state: ConnectionState): void {
    const request = state.request;
    state.request = null;
    state.phase = PanasonicS5Receiver.PHASE_HEADER;
    if (!request) return;
    let createEntry: PendingCreateEntry | null = null;
    if (request.isCreateObject && state.createBody.length > 0) {
      // CreateObject carries the real file name (P10xxxxx.JPG/RW2) in DIDL.
      const decoded = PanasonicS5Receiver.decodeXmlEntities(state.createBody);
      const titleMatch = new RegExp('<(?:[A-Za-z0-9_]+:)?title[^>]*>[\\s]*([^<]+?)[\\s]*</(?:[A-Za-z0-9_]+:)?title>', 'i').exec(decoded);
      const title = titleMatch && titleMatch.length >= 2 ? PanasonicS5Receiver.safeName(titleMatch[1]) : '';
      const resMatch = /<res\\b([^>]*)>/i.exec(decoded);
      const resAttrs = resMatch && resMatch.length >= 2 ? resMatch[1] : '';
      const sizeText = PanasonicS5Receiver.xmlAttribute(resAttrs, 'size');
      const parsedSize = Number.parseInt(sizeText, 10);
      const protocolInfo = PanasonicS5Receiver.xmlAttribute(resAttrs, 'protocolInfo');
      const resolution = PanasonicS5Receiver.xmlAttribute(resAttrs, 'resolution');
      const extension = PanasonicS5Receiver.extensionOf(title).length > 0 ?
        PanasonicS5Receiver.extensionOf(title) :
        (protocolInfo.toLowerCase().indexOf('cam_raw') >= 0 ? 'rw2' : 'jpg');
      const safeTitle = title.length > 0 ? title : `S5_${Date.now()}_${PanasonicS5Receiver.objectCounter}.${extension}`;
       const objectNumber = PanasonicS5Receiver.objectCounter++;
       // LUMIX Sync returns the media class identifier (1 for JPEG, 2 for
       // Panasonic RAW) and keeps the per-file uniqueness in the MEDIA URI.
       // S5 firmware accepts the same class identifier for subsequent files.
       const objectId = extension === 'rw2' ? '2-media-i' : '1-media-i';
       const mediaPath = `/MEDIA-${Date.now()}-i-${objectNumber}`;
      const host = PanasonicS5Receiver.localIp.length > 0 ? PanasonicS5Receiver.localIp : '127.0.0.1';
      createEntry = {
        name: safeTitle,
        time: Date.now(),
        objectId: objectId,
        importUri: `http://${host}:50000${mediaPath}`,
        size: Number.isFinite(parsedSize) && parsedSize > 0 ? parsedSize : 0,
        resolution: resolution,
        protocolInfo: protocolInfo.length > 0 ? protocolInfo :
          (extension === 'rw2' ? '*:*:application/octet-stream:PANASONIC.COM_PN=CAM_RAW' :
            '*:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG;DLNA.ORG_CI=0'),
      };
      PanasonicS5Receiver.pendingCreates.push(createEntry);
    }
    const hashIndex = request.soapAction.indexOf('#');
    const rawAction = hashIndex >= 0 ? request.soapAction.slice(hashIndex + 1) : request.soapAction;
    const action = rawAction.replace(/["']/g, '').trim();
    if (action === 'X_GetDLNAUploadProfiles') {
      const service = 'urn:schemas-upnp-org:service:ContentDirectory:1';
      // Keep the profile list in the same order as the captured LUMIX Sync
      // response.  The S5 chooses the upload representation from this list;
      // omitting the AVC entries or moving CAM_RAW can make it reject the DMS
      // even though the two image profiles are present.
      const profiles = 'JPEG_SM,JPEG_MED,JPEG_LRG,PANASONIC.COM_PN=CAM_RAW,' +
        'AVC_MP4_BL_L31_HD_AAC,AVC_MP4_MP_HD_1080i_AAC,' +
        'AVC_MP4_BL_CIF15_AAC_520,AVC_MP4_MP_HD_720p_AAC,' +
        'AVC_MP4_BL_L3_SD_AAC,AVC_MP4_MP_SD_AAC_LC';
      const body = `<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:X_GetDLNAUploadProfilesResponse xmlns:u="${service}"><SupportedUploadProfiles>${PanasonicS5Receiver.escapeXml(profiles)}</SupportedUploadProfiles></u:X_GetDLNAUploadProfilesResponse></s:Body></s:Envelope>`;
      PanasonicS5Receiver.sendDmsHttp(client, 200, 'text/xml; charset="utf-8"', body, false, true);
    } else if (action === 'CreateObject') {
      const entry = createEntry || {
         name: `S5_${Date.now()}_${state.counter}.jpg`, time: Date.now(),
         objectId: '1-media-i',
        importUri: `http://${PanasonicS5Receiver.localIp || '127.0.0.1'}:50000/MEDIA-${Date.now()}-i-${state.counter}`,
        size: 0, resolution: '', protocolInfo: '*:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG;DLNA.ORG_CI=0',
      };
      if (!createEntry) PanasonicS5Receiver.pendingCreates.push(entry);
      const service = 'urn:schemas-upnp-org:service:ContentDirectory:1';
       // Preserve the slightly unusual namespace spelling and element order
       // emitted by LUMIX Sync.  The S5 parser is stricter than a general
       // UPnP parser here (notably parentID="i" and imageItem without the
       // optional .photo suffix).
       const didl = `<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnporg:metadata-1-0/DIDL-Lite"><item id="${PanasonicS5Receiver.escapeXml(entry.objectId)}" parentID="i" restricted="0"><dc:title>${PanasonicS5Receiver.escapeXml(entry.name.replace(/\.(?:jpg|jpeg|rw2|raw)$/i, ''))}</dc:title><res importUri="${PanasonicS5Receiver.escapeXml(entry.importUri)}" protocolInfo="${PanasonicS5Receiver.escapeXml(entry.protocolInfo)}"/><upnp:class>object.item.imageItem</upnp:class></item></DIDL-Lite>`;
      const body = `<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:CreateObjectResponse xmlns:u="${service}"><ObjectID>${PanasonicS5Receiver.escapeXml(entry.objectId)}</ObjectID><Result>${PanasonicS5Receiver.escapeXml(didl)}</Result></u:CreateObjectResponse></s:Body></s:Envelope>`;
      PanasonicS5Receiver.sendDmsHttp(client, 200, 'text/xml; charset="utf-8"', body, false, true);
    } else if (action.length > 0) {
      const service = 'urn:schemas-upnp-org:service:ContentDirectory:1';
      const body = `<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:${action}Response xmlns:u="${service}"></u:${action}Response></s:Body></s:Envelope>`;
      PanasonicS5Receiver.sendDmsHttp(client, 200, 'text/xml; charset="utf-8"', body, false, true);
    } else {
      PanasonicS5Receiver.sendHttp(client, 200, 'text/plain; charset="utf-8"', '');
    }
    PanasonicS5Receiver.logEvent(`DMS SOAP ${PanasonicS5Receiver.pathLabel(action.length > 0 ? action : request.path)}`);
  }

  private static beginUpload(client: socket.TCPSocketConnection, state: ConnectionState, request: HttpRequestInfo): void {
    // JPG and RW2 are both pushed as image/jpeg; the RAW marker lives in the
    // contentfeatures.dlna.org header (PANASONIC.COM_PN=CAM_RAW).
    const features = (request.headers.get('contentfeatures.dlna.org') || '').toLowerCase();
    const contentType = (request.headers.get('content-type') || '').toLowerCase();
    let extension = 'jpg';
    if (features.indexOf('cam_raw') >= 0 || contentType.indexOf('rw2') >= 0 ||
      contentType.indexOf('raw') >= 0) extension = 'rw2';
    let name = '';
    const now = Date.now();
    while (PanasonicS5Receiver.pendingCreates.length > 0 && now - PanasonicS5Receiver.pendingCreates[0].time > 60000) {
      PanasonicS5Receiver.pendingCreates.shift();
    }
    let matched: PendingCreateEntry | null = null;
    let matchedIndex = -1;
    const requestPath = request.path.split('?')[0];
    for (let index = 0; index < PanasonicS5Receiver.pendingCreates.length; index++) {
      const candidate = PanasonicS5Receiver.pendingCreates[index];
      if (candidate.importUri.indexOf(requestPath) >= 0) {
        matched = candidate;
        matchedIndex = index;
        break;
      }
    }
    if (!matched && PanasonicS5Receiver.pendingCreates.length > 0) {
      const candidate = PanasonicS5Receiver.pendingCreates[0];
      if (PanasonicS5Receiver.extensionOf(candidate.name) === extension) {
        matched = candidate;
        matchedIndex = 0;
      }
    }
    if (matched) {
      name = matched.name;
      PanasonicS5Receiver.pendingCreates.splice(matchedIndex, 1);
    }
    if (name.length === 0) {
      const match = new RegExp('/MEDIA-([0-9]+)-i-([0-9]+)', 'i').exec(request.path);
      if (match && match.length >= 3) name = `S5_${match[1]}_${match[2]}.${extension}`;
      else name = `S5_${Date.now()}_${state.counter}.${extension}`;
    }
    const safe = PanasonicS5Receiver.safeName(name);
    name = safe.length > 0 ? safe : `S5_${Date.now()}_${state.counter}.${extension}`;
    if (PanasonicS5Receiver.extensionOf(name).length === 0) name += `.${extension}`;
    const total = !request.chunked && request.contentLength > 0 ? request.contentLength :
      (matched && matched.size > 0 ? matched.size : 0);
    const upload: UploadState = {
      name: name, extension: extension, path: '', file: null, received: 0, total: total,
      mode: request.chunked ? PanasonicS5Receiver.UPLOAD_CHUNKED :
        (request.contentLength > 0 ? PanasonicS5Receiver.UPLOAD_PLAIN : PanasonicS5Receiver.UPLOAD_RAW),
      chunkStage: 0, chunkRemain: 0, plainRemain: request.contentLength,
    };
    PanasonicS5Receiver.openUploadFile(state, upload);
    state.upload = upload;
    state.phase = PanasonicS5Receiver.PHASE_UPLOAD;
    const expect = (request.headers.get('expect') || '').toLowerCase();
    if (expect.indexOf('100-continue') >= 0) PanasonicS5Receiver.sendContinue(client);
    PanasonicS5Receiver.logEvent(`upload start ${PanasonicS5Receiver.pathLabel(upload.name)} chunked=${request.chunked ? 1 : 0}`);
  }

  private static beginRawUpload(state: ConnectionState): void {
    const extension = PanasonicS5Receiver.extensionFromMagic(state.buffer);
    const upload: UploadState = {
      name: `S5_${Date.now()}_${state.counter}.${extension}`, extension: extension, path: '',
      file: null, received: 0, total: 0, mode: PanasonicS5Receiver.UPLOAD_RAW,
      chunkStage: 0, chunkRemain: 0, plainRemain: 0,
    };
    PanasonicS5Receiver.openUploadFile(state, upload);
    state.upload = upload;
    state.phase = PanasonicS5Receiver.PHASE_UPLOAD;
    PanasonicS5Receiver.logEvent('raw stream fallback');
  }

  private static processUpload(client: socket.TCPSocketConnection, state: ConnectionState): boolean {
    const upload = state.upload;
    if (!upload) {
      state.phase = PanasonicS5Receiver.PHASE_HEADER;
      return true;
    }
    if (upload.mode === PanasonicS5Receiver.UPLOAD_RAW) {
      if (state.buffer.length === 0) return false;
      PanasonicS5Receiver.writeUploadBytes(upload, state.buffer);
      state.buffer = new Uint8Array(0);
      return false;
    }
    if (upload.mode === PanasonicS5Receiver.UPLOAD_PLAIN) {
      if (upload.plainRemain > 0) {
        if (state.buffer.length === 0) return false;
        const take = Math.min(upload.plainRemain, state.buffer.length);
        PanasonicS5Receiver.writeUploadBytes(upload, state.buffer.slice(0, take));
        state.buffer = state.buffer.slice(take);
        upload.plainRemain -= take;
        if (upload.plainRemain > 0) return false;
      }
      PanasonicS5Receiver.finishUpload(client, state);
      return true;
    }
    // Chunked framing: "<hex-size>\r\n" + <size bytes> + "\r\n", "0\r\n\r\n".
    while (true) {
      if (upload.chunkStage === 0) {
        const lineEnd = PanasonicS5Receiver.findCrlf(state.buffer);
        if (lineEnd < 0) {
          if (state.buffer.length > 128) {
            PanasonicS5Receiver.abortUpload(state, 'chunk size line');
            return false;
          }
          return false;
        }
        const line = PanasonicS5Receiver.decodeAscii(state.buffer.slice(0, lineEnd)).trim();
        state.buffer = state.buffer.slice(lineEnd + 2);
        const semiIndex = line.indexOf(';');
        const sizeText = semiIndex >= 0 ? line.slice(0, semiIndex) : line;
        const size = PanasonicS5Receiver.parseHexSize(sizeText);
        if (size < 0) {
          PanasonicS5Receiver.abortUpload(state, 'chunk size parse');
          return false;
        }
        if (size === 0) {
          // Terminal chunk is followed by a final CRLF. Wait for that pair
          // before acknowledging the file; a split TCP packet must not leave
          // the CRLF to be misread as the next HTTP request.
          upload.chunkStage = 3;
          continue;
        }
        upload.chunkRemain = size;
        upload.chunkStage = 1;
        continue;
      }
      if (upload.chunkStage === 1) {
        if (upload.chunkRemain > 0) {
          if (state.buffer.length === 0) return false;
          const take = Math.min(upload.chunkRemain, state.buffer.length);
          PanasonicS5Receiver.writeUploadBytes(upload, state.buffer.slice(0, take));
          state.buffer = state.buffer.slice(take);
          upload.chunkRemain -= take;
          if (upload.chunkRemain > 0) return false;
        }
        upload.chunkStage = 2;
        continue;
      }
      if (upload.chunkStage === 3) {
        if (state.buffer.length < 2) return false;
        if (state.buffer[0] !== 13 || state.buffer[1] !== 10) {
          PanasonicS5Receiver.abortUpload(state, 'terminal chunk framing');
          return false;
        }
        state.buffer = state.buffer.slice(2);
        PanasonicS5Receiver.finishUpload(client, state);
        return true;
      }
      if (state.buffer.length < 2) return false;
      if (state.buffer[0] === 13 && state.buffer[1] === 10) {
        state.buffer = state.buffer.slice(2);
        upload.chunkStage = 0;
        continue;
      }
      PanasonicS5Receiver.abortUpload(state, 'chunk framing');
      return false;
    }
  }

  private static finishUpload(client: socket.TCPSocketConnection, state: ConnectionState): void {
    const upload = state.upload;
    if (!upload) {
      state.phase = PanasonicS5Receiver.PHASE_HEADER;
      return;
    }
    const complete = PanasonicS5Receiver.closeUpload(upload, upload.received > 0);
    state.upload = null;
    state.phase = PanasonicS5Receiver.PHASE_HEADER;
    if (complete) PanasonicS5Receiver.sendUploadComplete(client);
  }

  private static abortUpload(state: ConnectionState, reason: string): void {
    const upload = state.upload;
    PanasonicS5Receiver.logEvent(`upload aborted: ${reason}`);
    if (upload) {
      // A de-framing failure means the remaining bytes cannot be trusted;
      // drop the partial file without emitting onFile.
      PanasonicS5Receiver.closeUpload(upload, false);
      try {
        if (upload.path.length > 0) fileIo.unlinkSync(upload.path);
      } catch (_error) { }
    }
    state.upload = null;
    state.phase = PanasonicS5Receiver.PHASE_HEADER;
  }

  private static openUploadFile(state: ConnectionState, upload: UploadState): void {
    if (!PanasonicS5Receiver.context || upload.file) return;
    upload.path = `${PanasonicS5Receiver.context.filesDir}/s5_receive_${Date.now()}_${state.counter}_${upload.name}`;
    try {
      upload.file = fileIo.openSync(upload.path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    } catch (error) {
      PanasonicS5Receiver.logError('open file', error);
      PanasonicS5Receiver.report('无法保存相机图片');
    }
  }

  private static writeUploadBytes(upload: UploadState, bytes: Uint8Array): void {
    if (bytes.length === 0) return;
    if (upload.file) {
      try {
        fileIo.writeSync(upload.file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer);
      } catch (error) {
        PanasonicS5Receiver.logError('write file', error);
        PanasonicS5Receiver.report('写入相机图片失败');
      }
    }
    upload.received += bytes.length;
    const callback = PanasonicS5Receiver.callbacks;
    if (callback && callback.onProgress) callback.onProgress(upload.received, upload.total);
  }

  private static closeUpload(upload: UploadState, notify: boolean): boolean {
    if (upload.file) {
      try { fileIo.closeSync(upload.file); } catch (_error) { }
      upload.file = null;
    }
    const valid = notify && upload.received > 0 && (upload.total <= 0 || upload.received === upload.total);
    if (notify && upload.received > 0 && !valid) {
      PanasonicS5Receiver.logEvent(`file size mismatch expected=${upload.total} received=${upload.received}`);
      PanasonicS5Receiver.report('相机图片接收长度不完整');
      try {
        if (upload.path.length > 0) fileIo.unlinkSync(upload.path);
      } catch (_error) { }
    }
    if (valid) {
      const callback = PanasonicS5Receiver.callbacks;
      if (callback && callback.onFile) {
        callback.onFile({
          path: upload.path, name: upload.name, size: upload.received,
          extension: upload.extension.length > 0 ? upload.extension : PanasonicS5Receiver.extensionOf(upload.name),
        });
      }
      PanasonicS5Receiver.logEvent(`file done ${PanasonicS5Receiver.pathLabel(upload.name)} bytes=${upload.received}`);
    }
    return valid;
  }

  private static finish(client: socket.TCPSocketConnection, state: ConnectionState): void {
    if (!PanasonicS5Receiver.states.has(client)) return;
    PanasonicS5Receiver.states.delete(client);
    const upload = state.upload;
    if (upload) {
      PanasonicS5Receiver.closeUpload(upload, upload.received > 0);
      state.upload = null;
    }
    const index = PanasonicS5Receiver.clients.indexOf(client);
    if (index >= 0) PanasonicS5Receiver.clients.splice(index, 1);
    const callback = PanasonicS5Receiver.callbacks;
    let dmsActive = false;
    for (const current of PanasonicS5Receiver.states.values()) {
      if (current.port === 50000) { dmsActive = true; break; }
    }
    if (state.port === 50000 && callback && callback.onSessionEnd && !dmsActive) callback.onSessionEnd();
  }

  private static async startSsdp(): Promise<void> {
    try {
      const udp = socket.constructUDPSocketInstance();
      udp.on('message', (info: socket.SocketMessageInfo): void => {
        PanasonicS5Receiver.respondToSearch(udp, info);
      });
      udp.on('error', (error: Error): void => PanasonicS5Receiver.logError('ssdp', error));
      try {
        await udp.bind({ address: '0.0.0.0', family: 1, port: PanasonicS5Receiver.SSDP_PORT });
      } catch (_error) {
        // If another system service owns 1900, an ephemeral source port can
        // still send NOTIFY packets. The camera's upload connection remains
        // on 50000 and is independent of this fallback.
        await udp.bind({ address: '0.0.0.0', family: 1, port: 0 });
      }
      try { await udp.setExtraOptions({ reuseAddress: true, broadcast: true }); } catch (_error) { }
      PanasonicS5Receiver.ssdp = udp;
      await PanasonicS5Receiver.sendAdvertisements('ssdp:alive');
      PanasonicS5Receiver.advertisementTimer = setInterval((): void => {
        void PanasonicS5Receiver.sendAdvertisements('ssdp:alive');
      }, 1500) as number;
      PanasonicS5Receiver.logEvent(`SSDP ready ip=${PanasonicS5Receiver.localIp.length > 0 ? 'present' : 'unknown'}`);
    } catch (error) {
      // SSDP is required for automatic S5 mode entry, but do not prevent the
      // raw receiver from starting on platform builds that block UDP 1900.
      PanasonicS5Receiver.logError('ssdp start', error);
    }
  }

  private static async sendAdvertisements(notification: string = 'ssdp:alive'): Promise<void> {
    if (!PanasonicS5Receiver.ssdp || PanasonicS5Receiver.localIp.length === 0) return;
    const uuid = `uuid:${PanasonicS5Receiver.clientUuid}`;
    const targets: string[] = [
      uuid,
      'urn:schemas-upnp-org:device:MediaServer:1',
      'upnp:rootdevice',
      'urn:schemas-upnp-org:service:ContentDirectory:1',
      'urn:schemas-upnp-org:service:ConnectionManager:1',
    ];
    const destinations: string[] = [PanasonicS5Receiver.SSDP_GROUP];
    if (PanasonicS5Receiver.peerHost.length > 0) destinations.push(PanasonicS5Receiver.peerHost);
    for (const target of targets) {
      const usn = target === uuid ? uuid : `${uuid}::${target}`;
      // The byebye packet in the capture intentionally has no LOCATION or
      // cache headers. Alive packets carry the same compact header set used by
      // LUMIX Sync; BOOTID/CONFIGID are not present in the S5 trace.
      const packet = notification === 'ssdp:byebye'
        ? `NOTIFY * HTTP/1.1\r\nHOST: ${PanasonicS5Receiver.SSDP_GROUP}:${PanasonicS5Receiver.SSDP_PORT}\r\nNT: ${target}\r\nNTS: ssdp:byebye\r\nUSN: ${usn}\r\n\r\n`
        : `NOTIFY * HTTP/1.1\r\nHOST: ${PanasonicS5Receiver.SSDP_GROUP}:${PanasonicS5Receiver.SSDP_PORT}\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://${PanasonicS5Receiver.localIp}:${PanasonicS5Receiver.controlPort}/dms/ddd.xml\r\nNT: ${target}\r\nNTS: ssdp:alive\r\nSERVER: Android/1 UPnP/1.0 Panasonic-DM-SV/1\r\nUSN: ${usn}\r\n\r\n`;
      for (const destination of destinations) {
        try {
          await PanasonicS5Receiver.ssdp.send({
            data: packet,
            address: { address: destination, family: 1, port: PanasonicS5Receiver.SSDP_PORT },
          });
        } catch (error) {
          // Some Harmony builds reject multicast sends with Connection
          // aborted. Continue with the camera's learned gateway so the S5 can
          // still receive the same advertisement over unicast.
          PanasonicS5Receiver.logError(destination === PanasonicS5Receiver.SSDP_GROUP ? 'ssdp multicast' : 'ssdp unicast', error);
        }
      }
    }
  }

  private static respondToSearch(udp: socket.UDPSocket, info: socket.SocketMessageInfo): void {
    if (!info || !info.remoteInfo) return;
    const text = PanasonicS5Receiver.decodeAscii(new Uint8Array(info.message)).toLowerCase();
    if (text.indexOf('m-search') < 0) return;
    const targetMatch = text.match(/(?:^|\r\n)st:\s*([^\r\n]+)/i);
    const target = targetMatch ? targetMatch[1].trim() : 'ssdp:all';
    const supported = target === 'ssdp:all' || target === 'upnp:rootdevice' || target === `uuid:${PanasonicS5Receiver.clientUuid}` ||
      target.indexOf('urn:schemas-upnp-org:device:mediaserver:') === 0 ||
      target.indexOf('urn:schemas-upnp-org:service:contentdirectory:') === 0 ||
      target.indexOf('urn:schemas-upnp-org:service:connectionmanager:') === 0;
    if (!supported) return;
    const location = `http://${PanasonicS5Receiver.localIp}:${PanasonicS5Receiver.controlPort}/dms/ddd.xml`;
    const uuid = `uuid:${PanasonicS5Receiver.clientUuid}`;
    const response = `HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nDATE: ${new Date().toUTCString()}\r\nEXT:\r\nLOCATION: ${location}\r\nSERVER: Android/1 UPnP/1.0 Panasonic-DM-SV/1\r\nBOOTID.UPNP.ORG: 1\r\nCONFIGID.UPNP.ORG: 1\r\nST: ${target}\r\nUSN: ${target === uuid ? uuid : `${uuid}::${target}`}\r\n\r\n`;
    void udp.send({ data: response, address: { address: info.remoteInfo.address, family: 1, port: info.remoteInfo.port } }).catch((error: Error): void => {
      PanasonicS5Receiver.logError('ssdp response', error);
    });
    PanasonicS5Receiver.logEvent(`SSDP M-SEARCH ${PanasonicS5Receiver.pathLabel(target)}`);
  }

  private static sendHttp(client: socket.TCPSocketConnection, status: number, contentType: string, body: string): void {
    const bytes = util.TextEncoder.create('utf-8').encode(body);
    // Generic fallback response for non-DMS paths. Captured DMS descriptor and
    // SOAP responses use sendDmsHttp() below so their Panasonic headers and
    // close semantics stay exact.
    const response = `HTTP/1.1 ${status} ${status === 200 ? 'OK' : 'Not Found'}\r\nContent-Type: ${contentType}\r\nContent-Length: ${bytes.byteLength}\r\nConnection: keep-alive\r\n\r\n${body}`;
    void client.send({ data: response }).catch((error: Error): void => PanasonicS5Receiver.logError('dms http response', error));
  }

  /**
   * DMS response headers captured from LUMIX Sync. The S5 is conservative
   * about the device description and SOAP response shape: it expects the
   * Panasonic server banner, a Japanese content-language on ddd.xml, and the
   * EXT marker on ContentDirectory actions.
   */
  private static sendDmsHttp(client: socket.TCPSocketConnection, status: number, contentType: string,
    body: string, includeLanguage: boolean, includeExt: boolean): void {
    const bytes = util.TextEncoder.create('utf-8').encode(body);
    let response = `HTTP/1.1 ${status} ${status === 200 ? 'OK' : 'Not Found'}\r\n`;
    if (includeLanguage) response += 'CONTENT-LANGUAGE: ja\r\n';
    response += `CONTENT-LENGTH: ${bytes.byteLength}\r\nContent-Type: ${contentType}\r\n`;
    if (includeExt) response += 'EXT:\r\n';
    response += 'SERVER: Android/1 UPnP/1.0 Panasonic-DM-SV/1\r\nCONNECTION: close\r\n\r\n';
    if (body.length > 0) response += body;
    void client.send({ data: response }).catch((error: Error): void => PanasonicS5Receiver.logError('dms response', error));
  }

  /** Exact short response used for Expect: 100-continue uploads. */
  private static sendContinue(client: socket.TCPSocketConnection): void {
    const response = 'HTTP/1.1 100 Continue\r\nContent-Length: 0\r\n\r\n';
    void client.send({ data: response }).catch((error: Error): void => PanasonicS5Receiver.logError('upload continue', error));
  }

  /** Exact short response observed after a complete camera upload. */
  private static sendUploadComplete(client: socket.TCPSocketConnection): void {
    const response = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n';
    void client.send({ data: response }).catch((error: Error): void => PanasonicS5Receiver.logError('upload complete', error));
  }

  private static sendSubscriptionResponse(client: socket.TCPSocketConnection, subscribe: boolean): void {
    if (!subscribe) {
      PanasonicS5Receiver.sendHttp(client, 200, 'text/plain; charset="utf-8"', '');
      return;
    }
    const response = `HTTP/1.1 200 OK\r\nSID: uuid:${PanasonicS5Receiver.clientUuid}\r\nTIMEOUT: Second-1800\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n`;
    void client.send({ data: response }).catch((error: Error): void => PanasonicS5Receiver.logError('dms subscribe', error));
  }

  private static xmlForPath(requestPath: string): string {
    const path = requestPath.split('?')[0].toLowerCase();
    if (path === '/' || path.indexOf('description') >= 0 || path.indexOf('rootdesc') >= 0 ||
      path.indexOf('desc.xml') >= 0 || path.indexOf('/ddd.xml') >= 0) {
      return PanasonicS5Receiver.deviceDescription();
    }
    if (path.indexOf('/sdd_1.xml') >= 0 || path.indexOf('/sdd_2.xml') >= 0 || path.indexOf('connectionmanager') >= 0) {
      return PanasonicS5Receiver.connectionManagerScpd();
    }
    if (path.indexOf('contentdir') >= 0 || path.indexOf('contentdirectory') >= 0 || path.indexOf('cds') >= 0 ||
      path.indexOf('scpd') >= 0 || path.indexOf('/sdd_0.xml') >= 0) {
      return PanasonicS5Receiver.contentDirectoryScpd();
    }
    return '';
  }

  private static deviceDescription(): string {
    const uuid = `uuid:${PanasonicS5Receiver.clientUuid}`;
    return `<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:vli="urn:schemas-panasonic-com:vli">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
    <friendlyName>WEB-W00</friendlyName>
    <manufacturer>Panasonic</manufacturer>
    <modelName>LUMIX_UP_SERVER_SMP</modelName>
    <modelNumber>1.00</modelNumber>
    <modelDescription></modelDescription>
    <serialNumber></serialNumber>
    <modelURL></modelURL>
    <manufacturerURL></manufacturerURL>
    <UDN>${uuid}</UDN>
    <iconList>
      <icon><mimetype>image/png</mimetype><width>48</width><height>48</height><depth>24</depth><url>/dms/dlna_icon_48.png</url></icon>
      <icon><mimetype>image/png</mimetype><width>120</width><height>120</height><depth>24</depth><url>/dms/dlna_icon_120.png</url></icon>
      <icon><mimetype>image/jpeg</mimetype><width>48</width><height>48</height><depth>24</depth><url>/dms/dlna_icon_48.jpg</url></icon>
      <icon><mimetype>image/jpeg</mimetype><width>120</width><height>120</height><depth>24</depth><url>/dms/dlna_icon_120.jpg</url></icon>
    </iconList>
    <dlna:X_DLNADOC xmlns:dlna="urn:schemas-dlna-org:device-1-0">DMS-1.50</dlna:X_DLNADOC>
    <dlna:X_DLNACAP xmlns:dlna="urn:schemas-dlna-org:device-1-0">audio-upload,image-upload,av-upload</dlna:X_DLNACAP>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>
        <SCPDURL>/dms/sdd_0.xml</SCPDURL>
        <controlURL>/dms/control_0</controlURL>
        <eventSubURL>/dms/event_0</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <SCPDURL>/dms/sdd_1.xml</SCPDURL>
        <controlURL>/dms/control_1</controlURL>
        <eventSubURL>/dms/event_1</eventSubURL>
      </service>
    </serviceList>
  </device>
</root>`;
  }

  private static contentDirectoryScpd(): string {
    return `<?xml version="1.0"?><scpd xmlns="urn:schemas-upnp-org:service-1-0"><specVersion><major>1</major><minor>0</minor></specVersion><actionList>
<action><name>GetSearchCapabilities</name><argumentList><argument><name>SearchCaps</name><direction>out</direction><relatedStateVariable>SearchCapabilities</relatedStateVariable></argument></argumentList></action>
<action><name>GetSortCapabilities</name><argumentList><argument><name>SortCaps</name><direction>out</direction><relatedStateVariable>SortCapabilities</relatedStateVariable></argument></argumentList></action>
<action><name>GetSystemUpdateID</name><argumentList><argument><name>Id</name><direction>out</direction><relatedStateVariable>SystemUpdateID</relatedStateVariable></argument></argumentList></action>
<action><name>X_GetDLNAUploadProfiles</name><argumentList><argument><name>SupportedUploadProfiles</name><direction>out</direction><relatedStateVariable>UploadProfiles</relatedStateVariable></argument></argumentList></action>
<action><name>CreateObject</name><argumentList><argument><name>ContainerID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument><argument><name>Elements</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument><argument><name>ObjectID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument><argument><name>Result</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument></argumentList></action>
<action><name>Browse</name><argumentList><argument><name>ObjectID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument><argument><name>BrowseFlag</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_BrowseFlag</relatedStateVariable></argument><argument><name>Filter</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Filter</relatedStateVariable></argument><argument><name>StartingIndex</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Index</relatedStateVariable></argument><argument><name>RequestedCount</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>SortCriteria</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SortCriteria</relatedStateVariable></argument><argument><name>Result</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument><argument><name>NumberReturned</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>TotalMatches</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>UpdateID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UpdateID</relatedStateVariable></argument></argumentList></action>
</actionList><serviceStateTable><stateVariable sendEvents="no"><name>A_ARG_TYPE_ObjectID</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_Result</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>UploadProfiles</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_BrowseFlag</name><dataType>string</dataType><allowedValueList><allowedValue>BrowseMetadata</allowedValue><allowedValue>BrowseDirectChildren</allowedValue></allowedValueList></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_Filter</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_SortCriteria</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_Index</name><dataType>ui4</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_Count</name><dataType>ui4</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_UpdateID</name><dataType>ui4</dataType></stateVariable><stateVariable sendEvents="no"><name>SearchCapabilities</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>SortCapabilities</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="yes"><name>SystemUpdateID</name><dataType>ui4</dataType></stateVariable></serviceStateTable></scpd>`;
  }

  private static connectionManagerScpd(): string {
    return `<?xml version="1.0"?><scpd xmlns="urn:schemas-upnp-org:service-1-0"><specVersion><major>1</major><minor>0</minor></specVersion><actionList>
<action><name>GetProtocolInfo</name><argumentList><argument><name>Source</name><direction>out</direction><relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument><argument><name>Sink</name><direction>out</direction><relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument></argumentList></action>
<action><name>GetCurrentConnectionIDs</name><argumentList><argument><name>ConnectionIDs</name><direction>out</direction><relatedStateVariable>CurrentConnectionIDs</relatedStateVariable></argument></argumentList></action>
<action><name>GetCurrentConnectionInfo</name><argumentList><argument><name>ConnectionID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument><argument><name>RcsID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable></argument><argument><name>AVTransportID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable></argument><argument><name>ProtocolInfo</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable></argument><argument><name>PeerConnectionManager</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionManager</relatedStateVariable></argument><argument><name>PeerConnectionID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument><argument><name>Direction</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable></argument><argument><name>Status</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionStatus</relatedStateVariable></argument></argumentList></action>
</actionList><serviceStateTable><stateVariable sendEvents="no"><name>SourceProtocolInfo</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>SinkProtocolInfo</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>CurrentConnectionIDs</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionID</name><dataType>i4</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_RcsID</name><dataType>i4</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_AVTransportID</name><dataType>i4</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_ProtocolInfo</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionManager</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_Direction</name><dataType>string</dataType></stateVariable><stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionStatus</name><dataType>string</dataType></stateVariable></serviceStateTable></scpd>`;
  }

  private static isHttpMethodPrefix(prefix: string): boolean {
    return prefix.indexOf('GET ') === 0 || prefix.indexOf('HEAD ') === 0 || prefix.indexOf('POST ') === 0 ||
      prefix.indexOf('PUT ') === 0 || prefix.indexOf('DELETE ') === 0 || prefix.indexOf('OPTIONS ') === 0 ||
      prefix.indexOf('NOTIFY ') === 0 || prefix.indexOf('SUBSCRIBE ') === 0 || prefix.indexOf('UNSUBSCRIBE ') === 0;
  }

  private static parseHexSize(text: string): number {
    if (text.length === 0 || text.length > 8) return -1;
    let value = 0;
    for (let i = 0; i < text.length; i++) {
      const digit = PanasonicS5Receiver.hexDigit(text.charCodeAt(i));
      if (digit < 0) return -1;
      value = value * 16 + digit;
    }
    return value <= 0x8000000 ? value : -1;
  }

  private static hexDigit(code: number): number {
    if (code >= 48 && code <= 57) return code - 48;
    if (code >= 97 && code <= 102) return code - 87;
    if (code >= 65 && code <= 70) return code - 55;
    return -1;
  }

  private static readLocalIp(): string {
    try {
      const info = wifiManager.getIpInfo();
      const value: number | string = info.ipAddress as number | string;
      if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
        // WifiIpInfo uses network byte order (192.168.54.10 is represented as
        // 0xC0A8360A), matching the existing Wi-Fi connection code.
        return `${(value >>> 24) & 0xff}.${(value >>> 16) & 0xff}.${(value >>> 8) & 0xff}.${value & 0xff}`;
      }
      const text = String(value || '').trim();
      return /^\d{1,3}(?:\.\d{1,3}){3}$/.test(text) ? text : '';
    } catch (_error) {
      return '';
    }
  }

  private static normalizeUuid(value: string): string {
    const compact = value.toLowerCase().replace(/^uuid:/, '').trim();
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(compact) ? compact : '';
  }

  private static normalizeHost(value: string): string {
    const host = value.trim().replace(/^https?:\/\//i, '').split('/')[0];
    return /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host) ? host : '';
  }

  private static makeUuid(): string {
    const hex = (): string => Math.floor(Math.random() * 0x10000).toString(16).padStart(4, '0');
    return `${hex()}${hex()}${hex()}${hex()}-${hex()}-${hex()}-${hex()}-${hex()}${hex()}${hex()}`;
  }

  private static pathLabel(value: string): string {
    return value.replace(/[^A-Za-z0-9_:/.-]/g, '').slice(0, 96);
  }

  private static logEvent(message: string): void {
    try { hilog.info(0x0000, 'VIVID_S5', message); } catch (_error) { }
    AppLogSink.emit('CTL', message);
  }

  private static concat(left: Uint8Array, right: Uint8Array): Uint8Array {
    const result = new Uint8Array(left.length + right.length);
    result.set(left, 0); result.set(right, left.length);
    return result;
  }

  private static findHeaderEnd(value: Uint8Array): number {
    for (let i = 0; i + 3 < value.length; i++) {
      if (value[i] === 13 && value[i + 1] === 10 && value[i + 2] === 13 && value[i + 3] === 10) return i;
    }
    return -1;
  }

  private static findCrlf(value: Uint8Array): number {
    for (let i = 0; i + 1 < value.length; i++) {
      if (value[i] === 13 && value[i + 1] === 10) return i;
    }
    return -1;
  }

  private static decodeAscii(value: Uint8Array): string {
    let result = '';
    for (const byte of value) result += String.fromCharCode(byte);
    return result;
  }

  private static decodeXmlEntities(value: string): string {
    return value.replace(/&quot;/g, '"').replace(/&apos;/g, "'")
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
  }

  private static escapeXml(value: string): string {
    return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  }

  private static xmlAttribute(attributes: string, name: string): string {
    const match = new RegExp(`${name}\\s*=\\s*"([^"]*)"`, 'i').exec(attributes);
    return match && match.length >= 2 ? PanasonicS5Receiver.decodeXmlEntities(match[1]) : '';
  }

  private static safeName(value: string): string {
    return value.replace(/^.*[\\/]/, '').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 120);
  }

  private static extensionOf(value: string): string {
    const dot = value.lastIndexOf('.');
    return dot >= 0 ? value.slice(dot + 1).toLowerCase() : '';
  }

  private static extensionFromMagic(value: Uint8Array): string {
    if (value.length >= 3 && value[0] === 0xFF && value[1] === 0xD8 && value[2] === 0xFF) return 'jpg';
    return 'rw2';
  }

  private static report(message: string): void {
    const callback = PanasonicS5Receiver.callbacks;
    if (callback && callback.onError) callback.onError(message);
  }

  private static logError(scope: string, error: Error | Object): void {
    try { hilog.error(0x0000, 'VIVID_S5', `${scope} ${JSON.stringify(error)}`); } catch (_error) { }
    AppLogSink.emit('CTL_ERR', scope);
  }
}
