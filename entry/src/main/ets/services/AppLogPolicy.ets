import { util } from '@kit.ArkTS';

/** Privacy and wire-format rules shared by local logs and feedback uploads. */
export class AppLogPolicy {
  private static readonly MAX_MESSAGE_CHARS: number = 900;
  private static readonly MAX_UPLOAD_BYTES: number = 1024 * 1024;
  private static readonly MAX_UPLOAD_LINES: number = 12000;

  static sanitize(message: string): string {
    // Redact before truncating, including quoted values and values with spaces.
    // Sensitive assignments discard the remaining text instead of guessing
    // where a password/token ends. Protocol diagnostics use explicit metadata.
    const safe = String(message)
      .replace(/[\r\n]+/g, ' <CR> ')
      .replace(/[\u0000-\u001f\u007f\ufffd]/g, '?')
      .replace(/(["']?\b[A-Za-z0-9._-]*(?:authorization|token|password|passwd|secret|openid|deviceid|imageid|clientuuid|bssid|ssid|credential|privatekey|signature|fingerprint)[A-Za-z0-9._-]*["']?\s*[:=]\s*).*/ig, '$1[redacted]')
      .replace(/\bBearer\s+[^\s'",;|}]+/ig, 'Bearer [redacted]')
      .replace(/https?:\/\/[^\s]+/ig, '[url]')
      .replace(/(?:file:\/\/|\/data\/|\/storage\/|[A-Z]:[\\/])[^\s)]+/ig, '[path]')
      .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/ig, '[uuid]')
      .replace(/\b(?:[0-9a-f]{2}:){5,}[0-9a-f]{2}\b/ig, '[address]')
      .replace(/\b(S5M2X|S5M2|S1RM2|S1RII|S1M2E|S1IIE|S1M2|S1II|S1H|S1R|S5|S9|ZS300|GH[0-9][A-Z0-9]*|G9M2|G9)[-_][A-Z0-9_-]+\b/ig, '$1-[instance]')
      .replace(/\b(?:NIKON[_ -])?Z[_ -](?:[0-9]+[A-Z]*|F|FC)[_ -][A-Z0-9_-]+\b/ig, 'Nikon-[instance]')
      .replace(/\b[A-Za-z0-9_-]{28,}\b/g, '[identifier]')
      .trim();
    // <= 3600 UTF-8 bytes plus timestamp, below the receiver's 4096-byte line cap.
    return safe.length > AppLogPolicy.MAX_MESSAGE_CHARS
      ? safe.substring(0, AppLogPolicy.MAX_MESSAGE_CHARS) + ' [truncated]' : safe;
  }

  /** Select whole newest lines. Character slicing can create a non-ISO first
   * line, causing the server to reject an otherwise valid upload. */
  static prepareUpload(text: string): string {
    const source = text.split('\n');
    const selected: string[] = [];
    let bytes = 512; // Reserve space for the upload summary.
    let omitted = 0;
    let reachedLimit = false;
    for (let index = source.length - 1; index >= 0; index--) {
      const line = source[index];
      if (line.trim().length === 0) continue;
      if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z \S/.test(line)) {
        omitted += 1;
        continue;
      }
      const message = AppLogPolicy.sanitize(line.substring(25));
      if (message.length === 0) { omitted += 1; continue; }
      const normalized = line.substring(0, 25) + message;
      const size = util.TextEncoder.create('utf-8').encode(normalized + '\n').byteLength;
      if (reachedLimit || selected.length >= AppLogPolicy.MAX_UPLOAD_LINES || bytes + size > AppLogPolicy.MAX_UPLOAD_BYTES) {
        reachedLimit = true;
        omitted += 1;
        continue;
      }
      selected.push(normalized);
      bytes += size;
    }
    if (selected.length === 0) return '';
    selected.reverse();
    const summary = new Date().toISOString() +
      ` log_upload format=2 included=${selected.length} omitted=${omitted} bounded=1`;
    return summary + '\n' + selected.join('\n') + '\n';
  }
}
