const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const input = process.argv[2];
const output = process.argv[3];
if (!input || !output) {
  console.error('usage: node analyze_s5_protocols.cjs <bin> <output-dir>');
  process.exit(2);
}

const data = fs.readFileSync(input);
const out = path.resolve(output);
fs.mkdirSync(out, { recursive: true });
const segmentsDir = path.join(out, 'segments');
fs.mkdirSync(segmentsDir, { recursive: true });

const tableOffset = 0x2ec;
const recordSize = 0x5c;
const records = [];
for (let off = tableOffset; off + recordSize <= data.length; off += recordSize) {
  const nameBuf = data.subarray(off, off + 12);
  const nul = nameBuf.indexOf(0);
  const name = nameBuf.subarray(0, nul < 0 ? nameBuf.length : nul).toString('ascii');
  if (!/^[A-Za-z0-9_]{1,12}$/.test(name)) break;
  const fileOffset = data.readUInt32LE(off + 12);
  const fileLength = data.readUInt32LE(off + 16);
  const loadAddress = data.readUInt32LE(off + 20);
  const flags = data.readUInt32LE(off + 24);
  const valid = fileOffset <= data.length && fileLength <= data.length - fileOffset;
  const rec = { name, tableOffset: off, fileOffset, fileLength, loadAddress, flags, valid };
  if (valid && fileLength > 0) {
    const bytes = data.subarray(fileOffset, fileOffset + fileLength);
    const p = path.join(segmentsDir, `${name}.bin`);
    if (!fs.existsSync(p) || fs.statSync(p).size !== bytes.length) fs.writeFileSync(p, bytes);
    rec.extractedPath = p;
    rec.sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  }
  records.push(rec);
}

const needles = [
  'wifi', 'wi-fi', 'wlan', 'bluetooth', 'ble', 'gatt', 'l2cap', 'att', 'smp',
  'pair', 'ssid', 'panasonic', 'lumix', 'camera', 'http', 'https', 'socket',
  'tcp', 'udp', 'mdns', 'bonjour', 'upnp', 'ptp', 'ftp', 'websocket', 'tls',
  'certificate', 'trust', 'server', 'auth', 'password', 'nonce', 'token',
  'firmware', 'update', 'network', 'dhcp', 'dns', 'wifi_info',
];
const protocolStrings = [];
const uuidHits = [];
const endpointHits = [];
const uuidRe = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/ig;
const endpointRe = /(?:https?|wss?):\/\/[^\x00\x20\x7f]{4,}|\/(?:[A-Za-z0-9_.-]+\/){1,}[A-Za-z0-9_.?=&:%-]+/g;

function addString(segment, abs, encoding, text) {
  const lower = text.toLowerCase();
  if (needles.some((n) => lower.includes(n))) {
    const item = { segment, absoluteOffset: abs, encoding, text };
    protocolStrings.push(item);
    for (const match of text.matchAll(uuidRe)) uuidHits.push({ segment, absoluteOffset: abs + match.index, encoding, uuid: match[0] });
    for (const match of text.matchAll(endpointRe)) endpointHits.push({ segment, absoluteOffset: abs + match.index, encoding, endpoint: match[0] });
  }
}

function scanAscii(segment, start, end) {
  let run = [];
  const flush = (at) => {
    if (run.length >= 8) addString(segment, at - run.length, 'latin1', Buffer.from(run).toString('latin1'));
    run = [];
  };
  for (let p = start; p < end; p++) {
    const c = data[p];
    if (c >= 0x20 && c <= 0x7e) run.push(c); else flush(p);
  }
  flush(end);
}

function scanUtf16(segment, start, end) {
  let run = [];
  const flush = (at) => {
    if (run.length >= 16) addString(segment, at - run.length, 'utf16le', Buffer.from(run).toString('utf16le'));
    run = [];
  };
  for (let p = start; p + 1 < end; p += 2) {
    const code = data.readUInt16LE(p);
    if ((code >= 0x20 && code <= 0x7e) || code >= 0x80) { run.push(data[p], data[p + 1]); } else flush(p);
  }
  flush(end);
}

function entropy(bytes) {
  if (!bytes.length) return 0;
  const counts = new Uint32Array(256);
  for (const b of bytes) counts[b]++;
  let h = 0;
  for (const n of counts) if (n) { const p = n / bytes.length; h -= p * Math.log2(p); }
  return Number(h.toFixed(5));
}

function signatures(segment, start, end) {
  const defs = [
    ['7f454c46', 'ELF'], ['504b0304', 'ZIP'], ['1f8b08', 'GZIP'],
    ['fd377a585a00', 'XZ'], ['68737173', 'SquashFS'], ['89504e470d0a1a0a', 'PNG'],
    ['ffd8ff', 'JPEG'], ['55424923', 'UBI'], ['555044', 'UPD'],
  ];
  const outHits = [];
  for (const [hex, type] of defs) {
    const needle = Buffer.from(hex, 'hex');
    let p = start;
    let count = 0;
    while ((p = data.indexOf(needle, p)) >= 0 && p < end && count++ < 128) {
      outHits.push({ segment, type, absoluteOffset: p, relativeOffset: p - start });
      p++;
    }
  }
  return outHits;
}

const segmentReports = [];
const signatureHits = [];
for (const rec of records) {
  if (!rec.valid || !rec.fileLength) continue;
  const start = rec.fileOffset;
  const end = start + rec.fileLength;
  const bytes = data.subarray(start, end);
  scanAscii(rec.name, start, end);
  scanUtf16(rec.name, start, end);
  signatureHits.push(...signatures(rec.name, start, end));
  segmentReports.push({
    name: rec.name,
    absoluteOffset: start,
    length: rec.fileLength,
    sha256: rec.sha256,
    entropy: entropy(bytes),
    first16: bytes.subarray(0, 16).toString('hex'),
    last16: bytes.subarray(Math.max(0, bytes.length - 16)).toString('hex'),
  });
}

const summary = {
  input: path.resolve(input),
  bytes: data.length,
  sha256: crypto.createHash('sha256').update(data).digest('hex'),
  headerHex: data.subarray(0, 512).toString('hex'),
  tableOffset,
  recordSize,
  records,
  segmentReports,
  protocolStrings,
  uuidHits,
  endpointHits,
  signatureHits,
  caveat: '此结果仅是离线静态扫描；未执行固件，也不是蓝牙空口或 Wi-Fi 空口抓包。高熵/无可读字符串时，协议字段仍属未知。',
};
fs.writeFileSync(path.join(out, 'protocol_analysis.json'), JSON.stringify(summary, null, 2));
fs.writeFileSync(path.join(out, 'protocol_strings.json'), JSON.stringify(protocolStrings, null, 2));
fs.writeFileSync(path.join(out, 'uuid_hits.json'), JSON.stringify(uuidHits, null, 2));
fs.writeFileSync(path.join(out, 'endpoint_hits.json'), JSON.stringify(endpointHits, null, 2));
fs.writeFileSync(path.join(out, 'segment_entropy.json'), JSON.stringify(segmentReports, null, 2));

const report = [];
report.push('# Panasonic S5 固件静态协议线索报告');
report.push('');
report.push(`- 输入：${summary.input}`);
report.push(`- 文件大小：${summary.bytes} bytes`);
report.push(`- SHA-256：${summary.sha256}`);
report.push('- 方法：解析固件分段表、导出分段、扫描 ASCII/UTF-16 字符串、UUID/URL/路径模式、文件签名并计算熵；不执行固件。');
report.push('');
report.push('## CONFIRMED');
report.push('');
report.push(`- 分段表位于 ` + `0x${tableOffset.toString(16)}` + `，记录长度 ` + `0x${recordSize.toString(16)}` + `；共解析 ${records.length} 条记录。`);
report.push('- 固件中明确存在 `program`、`zimage`、`rootfs1`、`rootfs2`、`wifi_info` 等分段名。');
report.push(`- 协议关键词命中 ${protocolStrings.length} 条，UUID 命中 ${uuidHits.length} 条，URL/路径模式命中 ${endpointHits.length} 条。`);
report.push(`- 可识别签名 ${signatureHits.length} 处；这些签名可能位于压缩、资源或随机数据中，不能单独证明是可执行网络模块。`);
report.push('');
report.push('## INFERRED');
report.push('');
report.push('- `wifi_info` 更像无线配置/校准数据分区；真正 Wi-Fi/BLE 协议实现更可能位于 `program`、`zimage`、`rootfs*` 或其加载的模块中。');
report.push('- 大型分段的熵接近 8 bit/byte，且未发现可验证的 ELF、SquashFS、UBI、ZIP/XZ 头，推测存在压缩、加密、专用封装或校验层。');
report.push('- 仅凭固件分段名无法建立 BLE GATT UUID、Wi-Fi API 路径、握手 payload 或密钥的对应关系。');
report.push('');
report.push('## UNKNOWN / 仍需运行时验证');
report.push('');
report.push('- 蓝牙广播、GATT 服务/特征 UUID、读写值、CCCD、通知顺序。');
report.push('- Wi-Fi 扫描、热点启动、DHCP、HTTP(S) 端点、认证头、Token/签名与实际 payload。');
report.push('- 任何加密或压缩层的密钥、解密参数及版本差异。');
report.push('- “抓取所有通信协议”不能由离线 bin 完成；需要设备运行时的 HCI snoop、系统 Wi-Fi 日志或应用层埋点/空口抓包。');
report.push('');
report.push('## 文件');
report.push('');
report.push('- `manifest.json`：分段表和每段哈希。');
report.push('- `protocol_analysis.json`：完整机器可读结果。');
report.push('- `protocol_strings.json`、`uuid_hits.json`、`endpoint_hits.json`：协议相关字符串、UUID、路径命中。');
report.push('- `segment_entropy.json`：每段熵和头尾字节。');
report.push('- `segments/`：按分段名导出的中间二进制文件。');
fs.writeFileSync(path.join(out, 'analysis_report.md'), report.join('\n') + '\n');

console.log(JSON.stringify({
  output: out,
  bytes: data.length,
  records: records.length,
  segments: segmentReports.length,
  protocolStrings: protocolStrings.length,
  uuidHits: uuidHits.length,
  endpointHits: endpointHits.length,
  signatures: signatureHits.length,
}, null, 2));
