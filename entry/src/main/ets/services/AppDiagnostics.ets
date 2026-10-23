interface AppDiagnosticErrorInfo {
  name?: string;
  message?: string;
  stack?: string;
  code?: number | string;
}

/** App-owned structured diagnostics. No system-log read permission is used.
 * Services depend on this small sink instead of importing the home page. */
export class AppDiagnostics {
  private static writer: ((message: string) => void) | null = null;
  private static flusher: (() => void) | null = null;
  private static pending: string[] = [];
  private static readonly CHANNELS: string[] = ['VIVID_BLE', 'VIVID_HTTP', 'VIVID_WIFI', 'VIVID_CTRL', 'APP'];
  private static readonly PATHS: string[] = ['/auth', '/media/gallery/current-sd',
    '/media/gallery/count', '/media/gallery/info', '/media/gallery/thumbnail', '/media/image'];
  /** 存储卡点击被拒的原因（固定枚举，不含任何相机回传值）。 */
  private static readonly SD_BLOCK_REASONS: string[] = ['none', 'invalid-slot', 'same-slot',
    'camera-not-ready', 'gallery-busy'];
  /** 在位标志的来源：Lab 线上没有任何来源（'none'），按钮因此被禁用。 */
  private static readonly SD_SOURCES: string[] = ['none', 'sync-probe', 'lab-current-sd', 'ble-slot'];
  /** current-sd 的实际应答结果：Lab 线靠它确认槽位是否真的被接受。 */
  private static readonly SD_RESULTS: string[] = ['none', 'ok', 'rejected'];

  static configure(writer: (message: string) => void, flusher: () => void): void {
    AppDiagnostics.writer = writer;
    AppDiagnostics.flusher = flusher;
    const buffered = AppDiagnostics.pending;
    AppDiagnostics.pending = [];
    for (const message of buffered) AppDiagnostics.emit(message);
  }

  static event(channel: string, message: string): void {
    const safeChannel = AppDiagnostics.CHANNELS.indexOf(channel) >= 0 ? channel : 'APP';
    const stage = AppDiagnostics.stage(message);
    if (stage === 'unknown') return;
    const event = message.indexOf('HTTP_REQ') === 0 ? 'request' :
      (message.indexOf('HTTP_RES') === 0 ? 'response' :
        (message.indexOf('HTTP_ERR') === 0 ? 'request_error' :
          (message.indexOf('FLOW_PHASE') === 0 ? 'phase' :
            (message.indexOf('FLOW_ERR') === 0 ? 'flow_error' :
              (message.indexOf('adv ') === 0 ? 'advertisement' : 'trace')))));
    const parts: string[] = [`diag channel=${safeChannel} event=${event} stage=${stage}`];
    // These are public protocol UUIDs, never device addresses. Only the three
    // one-byte mode/status characteristics may retain their raw byte value.
    const characteristicUuids = ['7644371c-1ddc-4b16-832f-f07c322e311b',
      'dcba3a74-80bc-4919-8ef4-0c9f99cc20dd', '6c875728-7636-425e-818a-f1d93a39e075'];
    const characteristicNames = ['ACTION_MODE', 'AP_STATE', 'ACTION_MODE_RESULT'];
    const lowerMessage = message.toLowerCase();
    for (let index = 0; index < characteristicUuids.length; index++) {
      if (lowerMessage.indexOf(characteristicUuids[index]) < 0) continue;
      parts.push(`characteristic=${characteristicNames[index]}`);
      const rawValue = message.match(/\b(?:raw|value|hex)=([0-9a-f]{2})(?=[\s,;)]|$)/i);
      if (rawValue) parts.push(`valueHex=${rawValue[1].toLowerCase()} meaning=UNRESOLVED`);
      break;
    }
    for (const path of AppDiagnostics.PATHS) {
      if (message.indexOf(path) >= 0) { parts.push(`path=${path}`); break; }
    }
    // Values from raw strings/bodies are never forwarded. Only known numeric
    // fields, fixed enums and header framing evidence enter the log file.
    const numericFields = ['flow', 'seq', 'code', 'http', 'business', 'ResponseCode', 'elapsedMs',
      'bytes', 'bodyBytes', 'rspBytes', 'status', 'items', 'total', 'start', 'StartIndex',
      'Limit', 'Type', 'ImageSize', 'ThumbnailCategory', 'Count', 'attempt', 'retry',
      'mtu', 'len', 'digest', 'expected', 'x509', 'pem', 'ble', 'wifi', 'session',
      'rssi', 'security', 'reused',
      // Advertisement identity: model code separates S1RM2 (8) from S9 (1).
      'lumixSvc', 'rawLen',
      // Card-slot state that gates the SD buttons in the transfer page.
      'sd1Present', 'sd2Present'];
    for (const field of numericFields) {
      const pattern = new RegExp(`(?:^|[\\s,;|{(.=])${field}[=:]\\s*(-?\\d{1,12})(?=[\\s,;|)}]|$)`, 'i');
      const matched = message.match(pattern);
      if (matched) parts.push(`${field}=${matched[1]}`);
    }
    const values = ['ble', 'wifi', 'session', 'failed', 'complete', 'success', 'error',
      'true', 'false', 'CONFIRMED', 'INFERRED', 'UNRESOLVED', 'match', 'mismatch',
      'reused', 'platform-managed', 'signaled', 'timeout', 'ready', 'empty', 'ok',
      'sent', 'present', 'none', 'unavailable', 'header-present', 'bonded', 'not-bonded'];
    for (const field of ['phase', 'state', 'result', 'evidence', 'registration', 'reuse', 'found', 'actual']) {
      const matched = message.match(new RegExp(`(?:^|[\\s,;])${field}=([A-Za-z-]+)(?=[\\s,;)]|$)`));
      if (matched && values.indexOf(matched[1]) >= 0) parts.push(`${field}=${matched[1]}`);
    }
    const sd = message.match(/(?:CurrentSd|sd)=(SD[12])\b/i);
    if (sd) parts.push(`sd=${sd[1].toUpperCase()}`);
    if (/method=POST\b|^POST\s/.test(message)) parts.push('method=POST');
    if (/method=GET\b|^GET\s/.test(message)) parts.push('method=GET');
    const auth = message.match(/Authorization=present\(len=(\d+),quoted=([01])\)/i);
    if (auth) parts.push(`authPresent=1 authLength=${auth[1]} authQuoted=${auth[2]}`);
    if (/Content-Type=application\/json\b/i.test(message)) parts.push('contentType=application/json');
    if (/Content-Type=application\/octet-stream\b/i.test(message)) parts.push('contentType=application/octet-stream');
    const dataCount = message.match(/DataList=count\((\d+)\)/);
    if (dataCount) parts.push(`dataListCount=${dataCount[1]}`);
    if (/body=binary\b/.test(message)) parts.push('bodyShape=binary');
    if (/body=json\(/.test(message)) parts.push('bodyShape=json');
    const fields: string[] = [];
    for (const name of ['AppInfo', 'FriendlyName', 'Uuid', 'CurrentSd', 'Type',
      'ThumbnailCategory', 'ImageSize', 'StartIndex', 'Limit', 'ImageId', 'Rating']) {
      if (new RegExp(`\\b${name}=`).test(message)) fields.push(name);
    }
    if (fields.length > 0) parts.push('fields=' + fields.join('|'));
    // The advertisement line names the body only through `display=`; accept the
    // same fixed model list there so the report says which camera it came from.
    let model = message.match(/\bmodel=(S5M2X|S5M2|S1RM2|S1RII|S1M2E|S1M2|S9|S5|ZS300)(?=\s|$)/);
    if (!model) {
      model = message.match(/\bdisplay=(S5M2X|S5M2|S1RM2|S1RII|S1M2E|S1M2|S9|S5|ZS300)(?=[-_]|\s|$)/);
    }
    if (model) parts.push(`model=${model[1]}`);
    // Card-slot diagnostics: the switch request, why a click was refused, and
    // where the presence flags came from. Booleans and fixed enums only.
    const sdSwitch = message.match(/\bsdSwitch=(SD[12])\b/i);
    if (sdSwitch) parts.push(`sdSwitch=${sdSwitch[1].toUpperCase()}`);
    const sdBlocked = message.match(/\bsdBlocked=([A-Za-z-]+)/);
    if (sdBlocked && AppDiagnostics.SD_BLOCK_REASONS.indexOf(sdBlocked[1]) >= 0) {
      parts.push(`sdBlocked=${sdBlocked[1]}`);
    }
    const sdSource = message.match(/\bsdSource=([A-Za-z-]+)/);
    if (sdSource && AppDiagnostics.SD_SOURCES.indexOf(sdSource[1]) >= 0) parts.push(`sdSource=${sdSource[1]}`);
    const sdResult = message.match(/\bsdResult=([A-Za-z-]+)/);
    if (sdResult && AppDiagnostics.SD_RESULTS.indexOf(sdResult[1]) >= 0) parts.push(`sdResult=${sdResult[1]}`);
    AppDiagnostics.emit(parts.join(' '));
  }

  static exception(channel: string, scope: string, error: Object | string): void {
    const info: AppDiagnosticErrorInfo = typeof error === 'string' || error === null || error === undefined
      ? {} : error as AppDiagnosticErrorInfo;
    const message = typeof error === 'string' ? error : String(info.message ?? '');
    const stack = typeof error === 'string' ? error : String(info.stack ?? '');
    const names = ['TypeError', 'RangeError', 'ReferenceError', 'SyntaxError', 'BusinessError', 'Error'];
    let name = 'Error';
    for (const candidate of names) {
      if (info.name === candidate || new RegExp(`\\b${candidate}\\b`).test(message)) { name = candidate; break; }
    }
    const rawCode = String(info.code ?? '0');
    const code = /^-?\d{1,12}$/.test(rawCode) ? rawCode : '0';
    const safeChannel = AppDiagnostics.CHANNELS.indexOf(channel) >= 0 ? channel : 'APP';
    const reasons: string[] = [];
    if (/is not a function/i.test(message)) reasons.push('not_function');
    if (/cannot read|undefined|null/i.test(message)) reasons.push('missing_value');
    if (/timed?\s*out|timeout/i.test(message)) reasons.push('timeout');
    if (/permission|denied/i.test(message)) reasons.push('permission');
    if (/certificate|tls|ssl/i.test(message)) reasons.push('certificate');
    if (/network|connect/i.test(message)) reasons.push('network');
    if (/json|parse/i.test(message)) reasons.push('parse');
    const frames: string[] = [];
    const knownFiles = ['LumixImportPrototype', 'LumixCameraService', 'LumixControlService',
      'CameraPage', 'CameraControlPage', 'EntryAbility', 'Index', 'ProfileSection'];
    for (const file of knownFiles) {
      const matched = stack.match(new RegExp(`\\b${file}\\.(?:ets|ts|js):(\\d{1,6})(?::(\\d{1,5}))?`));
      if (matched) frames.push(`${file}:${matched[1]}:${matched[2] ?? '0'}`);
      if (frames.length >= 4) break;
    }
    const propertyNames: string[] = [];
    for (const property of ['byteLength', 'length', 'Data', 'Header', 'DataList', 'result',
      'getServices', 'request', 'writeCharacteristic']) {
      if (new RegExp(`["']${property}["']`).test(message)) propertyNames.push(property);
    }
    // Neither message nor complete stack/URL is recorded.
    AppDiagnostics.emit(`diag channel=${safeChannel} event=exception stage=${AppDiagnostics.stage(scope)} name=${name} code=${code}` +
      ` reasons=${reasons.join('|') || 'unclassified'} properties=${propertyNames.join('|') || 'none'} frames=${frames.join('|') || 'unavailable'}`);
    AppDiagnostics.flush();
  }

  static flush(): void {
    try { if (AppDiagnostics.flusher) AppDiagnostics.flusher(); } catch (_error) { }
  }

  private static stage(message: string): string {
    const lower = message.toLowerCase();
    if (/flow[_ ]|^flow|^result/.test(lower)) return 'flow';
    if (lower.indexOf('http_') === 0) return 'http';
    if (lower.indexOf('thumbnail') >= 0) return 'thumbnail';
    if (lower.indexOf('gallery/info') >= 0) return 'gallery_info';
    if (lower.indexOf('gallery/count') >= 0) return 'gallery_count';
    if (lower.indexOf('current-sd') >= 0) return 'current_sd';
    // Before the generic `gallery` branch: a refused switch carries a reason
    // such as `gallery-busy` and must not be filed as a gallery read.
    if (/card slot|sd switch|sdswitch=|sdblocked=|sdpresent/.test(lower)) return 'card_slot';
    if (lower.indexOf('gallery') >= 0) return 'gallery';
    if (lower.indexOf('media/image') >= 0 || lower.indexOf('original') >= 0) return 'image';
    if (/certificate|tls/.test(lower)) return 'tls';
    if (lower.indexOf('auth') >= 0) return 'auth';
    if (lower.indexOf('initial_inform') >= 0) return 'initial_inform';
    if (lower.indexOf('action_mode') >= 0) return 'action_mode';
    if (/wifi|wi-fi|direct (?:join|association)/.test(lower)) return 'wifi';
    if (lower.indexOf('notify') >= 0) return 'notify';
    if (lower.indexOf('write') >= 0) return 'gatt_write';
    if (lower.indexOf('read ') === 0) return 'gatt_read';
    if (/pair|registration/.test(lower)) return 'pairing';
    if (/gatt|mtu|service |characteristic |descriptor /.test(lower)) return 'gatt';
    if (/^adv |adv id=/.test(lower)) return 'ble_adv';
    if (/ble|discovery|scan|camera candidate/.test(lower)) return 'ble';
    if (lower.indexOf('session') >= 0) return 'session';
    return 'unknown';
  }

  private static emit(message: string): void {
    try {
      if (AppDiagnostics.writer) AppDiagnostics.writer(message);
      else {
        AppDiagnostics.pending.push(message);
        if (AppDiagnostics.pending.length > 64) AppDiagnostics.pending.shift();
      }
    } catch (_error) { /* Diagnostics never break a camera operation. */ }
  }
}
