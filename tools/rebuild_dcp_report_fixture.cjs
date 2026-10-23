// Rebuild the tmp/dcp-report fixture from the shipped .dcp profile.
//
// The fixture is the output of the SAME parser over the SAME shipped file, not
// invented data. The original report was written by a one-off tool that named
// the tags; JSON.stringify of the parser's Map field would drop every tag, so
// the named conversion below is what makes forwardMatrix2 visible to
// check_geometry_dcp.cjs (DNG tag 0xC715).
//
// Usage: node tools/rebuild_dcp_report_fixture.cjs
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const parserPath = 'entry/src/main/ets/edit/utils/DcpProfileParser.ets';
const dcpPath = 'entry/src/main/resources/rawfile/Camera/Panasonic DC-S1RM2/Panasonic DC-S1RM2 Camera Standard.dcp';
const outPath = 'tmp/dcp-report/Panasonic DC-S1RM2 Camera Standard.json';

const TAG = {
  colorMatrix1: 0xc621,
  colorMatrix2: 0xc622,
  forwardMatrix1: 0xc714,
  forwardMatrix2: 0xc715,
  cameraCalibration1: 0xc623,
  cameraCalibration2: 0xc624,
};

const mod = { exports: {} };
const js = ts.transpileModule(fs.readFileSync(parserPath, 'utf8'),
  { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
vm.runInNewContext(js, {
  module: mod, exports: mod.exports, console, Math, Number, String, Boolean, Array, Object, JSON,
  isNaN, parseInt, parseFloat, Uint8Array, Uint16Array, Uint32Array, Int8Array, Int16Array,
  Int32Array, Float32Array, Float64Array, DataView, ArrayBuffer, Map, Set, Error,
  TextDecoder: global.TextDecoder,
}, { filename: parserPath });

const bytes = fs.readFileSync(dcpPath);
const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
const parsed = mod.exports.parseDcpProfile(buffer, 'DC-S1RM2', 'Panasonic DC-S1RM2 Camera Standard', false);
if (!parsed || !parsed.fields || !(parsed.fields instanceof Map)) {
  console.error('parseDcpProfile did not return a field map');
  process.exit(1);
}

const named = {};
for (const [name, tag] of Object.entries(TAG)) {
  const value = parsed.fields.get(tag);
  if (value !== undefined) named[name] = value;
}
if (!named.forwardMatrix2 || named.forwardMatrix2.length !== 9) {
  console.error('shipped .dcp has no usable ForwardMatrix2 (0xC715); refusing to write a fake fixture');
  process.exit(1);
}

// Same neutral check as check_geometry_dcp.cjs, run here so a bad extraction is
// caught before it is written.
const m = named.forwardMatrix2;
const xyz = [0, 1, 2].map((i) => m[i * 3] + m[i * 3 + 1] + m[i * 3 + 2]);
const rgb = [
  3.1338561 * xyz[0] - 1.6168667 * xyz[1] - 0.4906146 * xyz[2],
  -0.9787684 * xyz[0] + 1.9161415 * xyz[1] + 0.0334540 * xyz[2],
  0.0719453 * xyz[0] - 0.2289914 * xyz[1] + 1.4052427 * xyz[2],
];
if (Math.max(...rgb) - Math.min(...rgb) >= 0.002) {
  console.error('ForwardMatrix2 does not preserve a neutral: rgb=' + rgb.join(','));
  process.exit(1);
}

fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, JSON.stringify({
  source: dcpPath,
  parser: parserPath,
  parsedFields: named,
}, null, 2) + '\n', 'utf8');
console.log('wrote ' + outPath + ' (' + fs.statSync(outPath).size + ' bytes)');
console.log('forwardMatrix2=' + JSON.stringify(named.forwardMatrix2));
console.log('neutral rgb=' + rgb.map((v) => v.toFixed(6)).join(','));
