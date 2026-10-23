const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const input = process.argv[2];
const output = process.argv[3];
if (!input || !output) {
  console.error('usage: node extract_s5_firmware.cjs <bin> <output-dir>');
  process.exit(2);
}

const data = fs.readFileSync(input);
const tableOffset = 0x2ec;
const recordSize = 0x5c;
const records = [];
for (let offset = tableOffset; offset + recordSize <= data.length; offset += recordSize) {
  const rawName = data.subarray(offset, offset + 12);
  const nul = rawName.indexOf(0);
  const name = rawName.subarray(0, nul >= 0 ? nul : rawName.length).toString('ascii');
  if (!/^[A-Za-z0-9_]{1,12}$/.test(name)) break;
  const fileOffset = data.readUInt32LE(offset + 12);
  const fileLength = data.readUInt32LE(offset + 16);
  const loadAddress = data.readUInt32LE(offset + 20);
  const flags = data.readUInt32LE(offset + 24);
  const valid = fileOffset <= data.length && fileLength <= data.length - fileOffset;
  records.push({ name, tableOffset: offset, fileOffset, fileLength, loadAddress, flags, valid });
}

fs.mkdirSync(output, { recursive: true });
const segmentDir = path.join(output, 'segments');
fs.mkdirSync(segmentDir, { recursive: true });
for (const item of records) {
  if (!item.valid || item.fileLength === 0) continue;
  const target = path.join(segmentDir, item.name + '.bin');
  fs.writeFileSync(target, data.subarray(item.fileOffset, item.fileOffset + item.fileLength));
  item.extractedPath = target;
  item.sha256 = crypto.createHash('sha256').update(data.subarray(item.fileOffset, item.fileOffset + item.fileLength)).digest('hex');
}

const needles = [
  'wifi', 'wi-fi', 'wlan', 'bluetooth', 'ble', 'gatt', 'l2cap', 'pair', 'ssid',
  'panasonic', 'lumix', 'camera', 'http', 'https', 'socket', 'tcp', 'udp',
  'mdns', 'bonjour', 'bonjour', 'upnp', 'ptp', 'ftp', 'websocket', 'tls',
  'certificate', 'server', 'auth', 'password', 'firmware', 'update', 'ssid',
];
const hits = [];
function scanStrings(start, end, encoding) {
  let run = [];
  const flush = (at) => {
    if (run.length < (encoding === 'utf16le' ? 8 : 12)) { run = []; return; }
    const text = Buffer.from(run).toString(encoding);
    const lower = text.toLowerCase();
    if (needles.some((needle) => lower.includes(needle))) hits.push({ offset: at - run.length, encoding, text });
    run = [];
  };
  if (encoding === 'utf16le') {
    for (let p = start; p + 1 < end; p += 2) {
      const code = data.readUInt16LE(p);
      if ((code >= 0x20 && code <= 0x7e) || code >= 0x80) { run.push(data[p], data[p + 1]); }
      else flush(p);
    }
  } else {
    for (let p = start; p < end; p++) {
      const code = data[p];
      if (code >= 0x20 && code <= 0x7e) run.push(code); else flush(p);
    }
  }
  flush(end);
}

for (const item of records) {
  if (!item.valid || item.fileLength === 0) continue;
  const start = item.fileOffset;
  const end = start + item.fileLength;
  scanStrings(start, end, 'latin1');
  scanStrings(start, end, 'utf16le');
}

const signatureNames = {
  '7f454c46': 'ELF', '504b0304': 'ZIP', '1f8b08': 'GZIP',
  'fd377a585a00': 'XZ', '68737173': 'SquashFS', '89504e470d0a1a0a': 'PNG',
  'ffd8ff': 'JPEG', '55424923': 'UBI', '555046': 'UPF/UPD',
};
const signatures = [];
for (const item of records) {
  if (!item.valid || item.fileLength === 0) continue;
  const start = item.fileOffset;
  const end = start + item.fileLength;
  for (const [hex, name] of Object.entries(signatureNames)) {
    const needle = Buffer.from(hex, 'hex');
    let p = start;
    let count = 0;
    while ((p = data.indexOf(needle, p)) >= 0 && p < end && count < 64) {
      signatures.push({ segment: item.name, type: name, absoluteOffset: p, relativeOffset: p - start });
      p += 1;
      count++;
    }
  }
}

const manifest = {
  input, bytes: data.length,
  sha256: crypto.createHash('sha256').update(data).digest('hex'),
  tableOffset, recordSize, records,
  signatures,
  stringHitCount: hits.length,
};
fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2));
fs.writeFileSync(path.join(output, 'protocol_strings.json'), JSON.stringify(hits, null, 2));
const text = hits.map((hit) => `${hit.offset}\t${hit.encoding}\t${hit.text}`).join('\n') + '\n';
fs.writeFileSync(path.join(output, 'protocol_strings.txt'), text);
console.log(JSON.stringify({ output, bytes: data.length, segments: records.filter((r) => r.valid && r.fileLength > 0).length, stringHits: hits.length, signatures: signatures.length }, null, 2));
