/* Read-only DCP inspector. It decodes the public DNG Profile IFD fields and
 * writes a provenance-preserving JSON snapshot; it never changes the profile. */
const fs = require('fs');
const path = require('path');

const TAGS = {
  0xC614: 'uniqueCameraModel', 0xC621: 'colorMatrix1', 0xC622: 'colorMatrix2',
  0xC623: 'cameraCalibration1', 0xC624: 'cameraCalibration2',
  0xC625: 'reductionMatrix1', 0xC626: 'reductionMatrix2',
  0xC65A: 'calibrationIlluminant1', 0xC65B: 'calibrationIlluminant2',
  0xC629: 'forwardMatrix1', 0xC62A: 'forwardMatrix2',
  0xC6F4: 'profileCalibrationSignature', 0xC6F8: 'profileName',
  0xC6F9: 'profileHueSatMapDims', 0xC6FA: 'profileHueSatMapData1',
  0xC6FB: 'profileHueSatMapData2', 0xC6FC: 'profileToneCurve',
  0xC6FD: 'profileEmbedPolicy', 0xC6FE: 'profileCopyright',
  0xC725: 'profileLookTableDims', 0xC726: 'profileLookTableData',
  0xC7A3: 'profileHueSatMapEncoding', 0xC7A4: 'profileLookTableEncoding',
  0xC7A5: 'baselineExposureOffset', 0xC7A6: 'defaultBlackRender',
  0xC714: 'forwardMatrix1', 0xC715: 'forwardMatrix2',
};
const TYPE_SIZE = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8 };

function readAscii(view, pos, count) {
  const bytes = [];
  for (let i = 0; i < count && pos + i < view.byteLength; i++) bytes.push(view.getUint8(pos + i));
  return Buffer.from(bytes).toString('utf8').replace(/\0+$/, '');
}
function readValues(view, pos, type, count, little) {
  const out = [];
  for (let i = 0; i < count; i++) {
    const p = pos + i * TYPE_SIZE[type];
    if (p + TYPE_SIZE[type] > view.byteLength) throw new Error('value outside file');
    if (type === 1 || type === 7) out.push(view.getUint8(p));
    else if (type === 2) out.push(readAscii(view, p, Math.min(1, count - i)));
    else if (type === 3) out.push(view.getUint16(p, little));
    else if (type === 4) out.push(view.getUint32(p, little));
    else if (type === 5) out.push(view.getUint32(p, little) / Math.max(1, view.getUint32(p + 4, little)));
    else if (type === 6) out.push(view.getInt8(p));
    else if (type === 8) out.push(view.getInt16(p, little));
    else if (type === 9) out.push(view.getInt32(p, little));
    else if (type === 10) out.push(view.getInt32(p, little) / Math.max(1, view.getInt32(p + 4, little)));
    else if (type === 11) out.push(view.getFloat32(p, little));
    else if (type === 12) out.push(view.getFloat64(p, little));
  }
  return out;
}
function parseDcp(file) {
  const bytes = fs.readFileSync(file);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.byteLength < 8) throw new Error('file too short');
  const little = view.getUint8(0) === 0x49 && view.getUint8(1) === 0x49;
  if (!little && !(view.getUint8(0) === 0x4D && view.getUint8(1) === 0x4D)) throw new Error('not TIFF byte order');
  const order = little ? 'little-endian' : 'big-endian';
  const magic = view.getUint16(2, little);
  // Adobe Camera Raw DCP files use the compact "IIRC" container: the first
  // four bytes are II RC, followed by a 32-bit header value and an IFD count.
  const adobeDcp = magic === 0x4352;
  if (!adobeDcp && magic !== 42 && magic !== 43) throw new Error('unsupported TIFF magic ' + magic);
  const ifdOffset = adobeDcp ? 8 : (magic === 43 ? Number(view.getBigUint64(8, little)) : view.getUint32(4, little));
  if (ifdOffset > view.byteLength - 2) throw new Error('IFD offset outside file');
  const count = view.getUint16(ifdOffset, little);
  const fields = {}; const warnings = [];
  for (let i = 0; i < count; i++) {
    const p = ifdOffset + 2 + i * 12;
    if (p + 12 > view.byteLength) { warnings.push('truncated IFD entry ' + i); break; }
    const tag = view.getUint16(p, little); const type = view.getUint16(p + 2, little);
    const n = view.getUint32(p + 4, little); const size = TYPE_SIZE[type];
    if (!size) { warnings.push('unsupported TIFF type ' + type + ' for tag 0x' + tag.toString(16)); continue; }
    const total = size * n; const pos = total <= 4 ? p + 8 : view.getUint32(p + 8, little);
    if (pos + total > view.byteLength) { warnings.push('tag 0x' + tag.toString(16) + ' points outside file'); continue; }
    const name = TAGS[tag] || ('tag_0x' + tag.toString(16));
    if (type === 2) fields[name] = readAscii(view, pos, n);
    else fields[name] = readValues(view, pos, type, n, little);
    fields[name + 'Meta'] = { tag: '0x' + tag.toString(16), type, count: n, byteOffset: pos, byteLength: total };
  }
  const arrayChecks = ['colorMatrix1','colorMatrix2','forwardMatrix1','forwardMatrix2','cameraCalibration1','cameraCalibration2','reductionMatrix1','reductionMatrix2'];
  for (const key of arrayChecks) if (Array.isArray(fields[key]) && fields[key].length !== 9) warnings.push(key + ' length ' + fields[key].length + ', expected 9');
  for (const key of ['profileHueSatMapDims','profileLookTableDims']) if (Array.isArray(fields[key]) && fields[key].length !== 3) warnings.push(key + ' dimension length is not 3');
  return { format: 'DCP/TIFF', sourceFile: file, fileBytes: bytes.length, byteOrder: order, tiffMagic: magic,
    parsedFields: fields, warnings, unsupportedImportantFields: warnings.length > 0 ? warnings : [] };
}

const inputDir = process.argv[2]; const outputDir = process.argv[3];
if (!inputDir || !outputDir) { console.error('usage: node dcp_inspect.js <dcp-dir> <json-dir>'); process.exit(2); }
fs.mkdirSync(outputDir, { recursive: true });
for (const name of fs.readdirSync(inputDir).filter((n) => n.toLowerCase().endsWith('.dcp'))) {
  const file = path.join(inputDir, name); let report;
  try { report = parseDcp(file); } catch (e) { report = { format: 'DCP/TIFF', sourceFile: file, parseError: String(e), warnings: ['profile not parsed'] }; }
  const out = path.join(outputDir, name.replace(/\.dcp$/i, '.json'));
  fs.writeFileSync(out, JSON.stringify(report, null, 2), 'utf8');
  console.log(path.basename(out), report.parseError || ('fields=' + Object.keys(report.parsedFields || {}).length + ' warnings=' + (report.warnings || []).length));
}
