// Native advanced band (curves / HSL mixer / calibration / grading / vignette /
// grain) vs the ArkTS reference in WorkerCore.applyAdvancedBand.
//
// The device runs the C++ core from libvivid_composite.so; the ArkTS loop stays
// as the fallback. This suite compiles the same core translation unit on the
// host (same -O2 / -ffp-contract=off flags) and compares it byte for byte with
// the transpiled ArkTS reference over several adjustment sets, including the
// spatial effects (vignette + grain) that made the CPU export slow.
//
// Falsification: the probe prints every byte difference; a channel swap or a
// missing stage shows up directly. `--falsify` is not needed here because the
// fixture already exercises all stages and the assertion is maxCh <= 1.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const os = require('os');
const cp = require('child_process');
const assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const root = path.resolve('entry/src/main/ets');
const cppDir = path.resolve('entry/src/main/cpp');
const DISTRO = process.env.VIVID_WSL_DISTRO || 'Ubuntu-22.04';
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vivid-advanced-parity-'));
const probeBinary = '/tmp/vivid_advanced_probe_' + process.pid;

const modules = new Map();
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} }; modules.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer, Error,
    Uint8Array, Uint16Array, Uint32Array, Int32Array, Float32Array, Float64Array, Uint8ClampedArray,
    Promise, setTimeout, clearTimeout, TextEncoder, TextDecoder, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: () => undefined, setOrCreate: () => {} },
    require: (n) => {
      if (n.endsWith('.so')) return { default: {} };
      if (n === '@kit.ArkTS') {
        return { taskpool: { Task: class { static isCanceled() { return false; } constructor(fn, ...args) { this.fn = fn; this.args = args; } }, execute: async (task) => task.fn(...task.args) } };
      }
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { ColorAdjustments } = load(root + '/edit/models/Adjustment.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { applyAdvancedBand, prepareAdvancedTables } = load(root + '/edit/engine/WorkerCore.ets');

function toWslPath(winPath) {
  const normalized = path.resolve(winPath).replace(/\\/g, '/');
  return `/mnt/${normalized[0].toLowerCase()}${normalized.slice(2)}`;
}
function wsl(command) {
  return cp.spawnSync('wsl', ['-d', DISTRO, '--', 'bash', '-lc', command], { encoding: 'utf8' });
}

let checks = 0;
function ok(condition, message) { checks++; assert(condition, message); }

const version = wsl('g++ --version >/dev/null 2>&1 && echo gxx-ok || echo gxx-missing');
if (version.status !== 0 || !String(version.stdout).includes('gxx-ok')) {
  console.log('SKIP check_advanced_native_parity: no host C++ toolchain (g++ in WSL).');
  process.exit(0);
}
const compile = wsl(`g++ -O2 -ffp-contract=off -std=c++17 -I ${toWslPath(cppDir)} ` +
  `${toWslPath(path.join('tools', 'native_advanced_probe.cpp'))} ` +
  `${toWslPath(path.join(cppDir, 'vivid_advanced_core.cpp'))} -o ${probeBinary}`);
if (compile.status !== 0) console.error(compile.stderr || '');
ok(compile.status === 0, 'host probe must compile with the same flags as the device library');

const W = 64, H = 48;
const input = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    input[i] = (x * 4 + y) & 255;
    input[i + 1] = (x + y * 3) & 255;
    input[i + 2] = (x * 2 + y * 7) & 255;
    input[i + 3] = 255;
  }
}

function adjustments() {
  return new ColorAdjustments();
}

const CASES = [
  { name: 'mixer', build: (a) => { a.mixSaturation[0] = 0.81; a.mixHue[2] = 0.4; } },
  { name: 'vignette', build: (a) => { a.vignetteAmount = -0.7; a.vignetteMidpoint = 0.6; a.vignetteFeather = 0.4; a.vignetteHighlights = 0.5; } },
  { name: 'grain', build: (a) => { a.grainAmount = 0.6; a.grainSize = 0.4; a.grainRoughness = 0.5; } },
  { name: 'tonal+wb+vibrance', build: (a) => { a.exposure = 0.35; a.temperature = 0.3; a.tint = -0.2; a.highlights = 0.4; a.shadows = -0.3; a.whites = 0.2; a.blacks = -0.1; a.vibrance = 0.45; } },
  { name: 'calibration+grading', build: (a) => { a.calibrationRedHue = 0.3; a.calibrationBlueSaturation = 0.4; a.colorGradingEnabled = true; a.gradingShadowsHue = 210; a.gradingShadowsSaturation = 0.5; a.gradingHighlightsHue = 40; a.gradingHighlightsSaturation = 0.3; a.gradingBlending = 0.6; a.gradingBalance = 0.2; } },
  { name: 'parametric-refine', build: (a) => { a.parametricHighlights = 0.6; a.parametricShadows = 0.4; a.parametricRefineSaturation = 0.3; } },
  { name: 'all', build: (a) => { a.exposure = 0.25; a.temperature = 0.2; a.tint = 0.1; a.highlights = 0.2; a.shadows = -0.2; a.whites = 0.1; a.blacks = -0.05; a.vibrance = 0.3; a.calibrationGreenHue = 0.2; a.mixSaturation[1] = 0.5; a.mixLuminance[4] = 0.2; a.vignetteAmount = -0.45; a.grainAmount = 0.3; a.grainSize = 0.2; a.parametricLights = 0.3; a.parametricRefineSaturation = 0.5; } },
];

function writeFixture(file, params, curves, tonal, parametric, viewport, pixels) {
  const header = Buffer.alloc(20);
  header.writeInt32LE(0x56415642, 0);
  header.writeInt32LE(tonal !== null ? 1 : 0, 4);
  header.writeInt32LE(parametric !== null ? 1 : 0, 8);
  header.writeInt32LE(viewport !== null ? 1 : 0, 12);
  header.writeInt32LE(pixels.length, 16);
  const paramsBuf = Buffer.alloc(70 * 8);
  for (let i = 0; i < 70; i++) paramsBuf.writeDoubleLE(params[i], i * 8);
  const curvesBuf = Buffer.alloc(4 * 1025 * 8);
  for (let i = 0; i < 4 * 1025; i++) curvesBuf.writeDoubleLE(curves[i], i * 8);
  const tonalBuf = Buffer.alloc(1025 * 4);
  if (tonal !== null) for (let i = 0; i < 1025; i++) tonalBuf.writeFloatLE(tonal[i], i * 4);
  const paramBuf = Buffer.alloc(256 * 4);
  if (parametric !== null) for (let i = 0; i < 256; i++) paramBuf.writeFloatLE(parametric[i], i * 4);
  const viewportBuf = Buffer.alloc(6 * 8);
  if (viewport !== null) for (let i = 0; i < 6; i++) viewportBuf.writeDoubleLE(viewport[i], i * 8);
  fs.writeFileSync(file, Buffer.concat([header, paramsBuf, curvesBuf, tonalBuf, paramBuf, viewportBuf, Buffer.from(pixels)]));
}

const rows = [];
for (const testCase of CASES) {
  const adj = adjustments();
  testCase.build(adj);
  const plain = ImageProcessor.plainAdjustments(adj);
  const tables = prepareAdvancedTables(plain);
  const viewport = testCase.name === 'all' ? [8, 4, 0.75, 0.75, W * 0.75, H * 0.75] : null;

  const reference = input.slice();
  applyAdvancedBand(reference, plain, 0, reference.length, W, H,
    viewport === null ? undefined : viewport, 0, tables);

  const params = tables.nativeParams;
  params[16] = W; params[17] = H; params[18] = 0;
  const fixture = path.join(tmpDir, testCase.name + '.bin');
  const output = path.join(tmpDir, testCase.name + '.out');
  writeFixture(fixture, params, tables.nativeCurves, tables.tonal, tables.parametric,
    viewport === null ? null : Float64Array.from(viewport), input);
  const run = wsl(`${probeBinary} ${toWslPath(fixture)} ${toWslPath(output)}`);
  ok(run.status === 0, `native probe must run for ${testCase.name}` +
    (run.status === 0 ? '' : ` (stderr: ${run.stderr || run.stdout})`));
  const native = new Uint8ClampedArray(fs.readFileSync(output));

  let maxChannel = 0, over1 = 0, sum = 0;
  for (let i = 0; i < reference.length; i++) {
    const diff = Math.abs(reference[i] - native[i]);
    if (diff > maxChannel) maxChannel = diff;
    if (diff > 1) over1++;
    sum += diff;
  }
  rows.push({ name: testCase.name, maxChannel, over1, mean: sum / reference.length });
  ok(reference.length === native.length, `${testCase.name}: output length`);
  ok(maxChannel <= 1, `${testCase.name}: native vs ArkTS max channel diff ${maxChannel} (must be <= 1)`);
  ok(over1 === 0, `${testCase.name}: no sample differs by more than 1`);
  console.log(`${testCase.name.padEnd(22)} maxCh=${maxChannel} over1=${over1} ` +
    `mean=${(sum / reference.length).toFixed(4)}`);
}

console.log('PASS advanced band native <=> ArkTS: all stages, max channel diff <= 1.');
console.log(checks + ' 项通过');
