// Guard for D1: the tint slider's green/magenta direction and its magnitude.
//
// Falsifiable shape: reverting the renderer to the old magenta-positive,
// double-scaled formula fails the sign assertions (right tint would raise R/B
// and lower G) and the magnitude floor (old full tint was ~3% vs ~18% now).
// The CPU and GPU formulas are checked separately, and the white-balance solve
// is checked as the exact inverse of the renderer's gains.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const modules = new Map(), storage = new Map();
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} }; modules.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console: { info() {}, warn() {}, error() {}, log() {} },
    Math, Number, Date, Map, Set, ArrayBuffer, Uint8Array, Uint16Array, Uint32Array, Int32Array,
    Uint8ClampedArray, Float32Array, Float64Array, DataView, Promise, Error, JSON, Buffer,
    setTimeout, clearTimeout, setInterval, clearInterval, Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (name) => {
      if (name === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0), releaseSession: async () => new ArrayBuffer(0) } };
      if (name === '@kit.ArkTS') {
        return { taskpool: { Task: class { static isCanceled() { return false; } constructor(f, ...a) { this.f = f; this.a = a; } }, execute: async (t) => t.f(...t.a) } };
      }
      if (name.startsWith('@kit.')) return { hilog: { info() {}, warn() {}, error() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { ImageProcessor: P } = load(root + '/edit/engine/ImageProcessor.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { GpuShaderBridge: G } = load(root + '/edit/engine/GpuShaderBridge.ets');
const WB = load(root + '/edit/engine/WhiteBalanceSampling.ets');
const PICK = load(root + '/edit/engine/WhiteBalancePickerCore.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }

const W = 32, H = 32;
const gray = new Uint8ClampedArray(W * H * 4);
for (let i = 0; i < W * H; i++) { gray[i * 4] = 128; gray[i * 4 + 1] = 128; gray[i * 4 + 2] = 128; gray[i * 4 + 3] = 255; }
function sessionWith(key, value) {
  const s = new EditSession();
  s.layers = [new Layer('tint-guard')];
  s.layers[0].adjustments[key] = value;
  return s;
}
function render(session) {
  const params = P.buildWorkerParams(P.snapshot(session), gray.buffer.slice(0), W, H);
  return new Uint8ClampedArray(processPixels(params).buffer);
}
function mean(pixels) {
  let r = 0, g = 0, b = 0;
  for (let i = 0; i < pixels.length; i += 4) { r += pixels[i]; g += pixels[i + 1]; b += pixels[i + 2]; }
  const n = pixels.length / 4;
  return [r / n, g / n, b / n];
}
function delta(base, out) { return [out[0] - base[0], out[1] - base[1], out[2] - base[2]]; }
function dist(d) { return Math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]); }

const base = mean(render(sessionWith('exposure', 0)));
const plus = delta(base, mean(render(sessionWith('tint', 1))));
const minus = delta(base, mean(render(sessionWith('tint', -1))));
const half = delta(base, mean(render(sessionWith('tint', 0.5))));
const quarter = delta(base, mean(render(sessionWith('tint', 0.25))));
const temp = delta(base, mean(render(sessionWith('temperature', 1))));

// 1. Direction: right (positive) = green, left = magenta/red. The old formula
//    did the opposite, so these two assertions are the regression guard.
ok(plus[1] > plus[0] + 3 && plus[1] > plus[2] + 3,
  'tint +1 must be green: mean G must exceed R and B by >3 levels, got Δ=' + plus.join(','));
ok(minus[1] < minus[0] - 3 && minus[1] < minus[2] - 3,
  'tint -1 must be magenta/red: mean G must trail R and B by >3 levels, got Δ=' + minus.join(','));
ok(Math.abs(plus[0] - plus[2]) < 1.5 && Math.abs(minus[0] - minus[2]) < 1.5,
  'tint must move on the green/magenta axis only, leaving R and B equal');

// 2. Monotonic in |tint|.
ok(dist(quarter) > 0 && dist(half) > dist(quarter) && dist(plus) > dist(half),
  'tint response must be monotonic: .25=' + dist(quarter).toFixed(2) +
  ' .5=' + dist(half).toFixed(2) + ' 1=' + dist(plus).toFixed(2));

// 3. Full strength must be the same order of magnitude as temperature, not the
//    old ~16x-weak whisper. The old tint +1 moved |Δ|≈4.0 (3% of 128); the
//    floor below fails that.
ok(dist(plus) >= 0.5 * dist(temp),
  'full tint must be comparable to full temperature: tint |Δ|=' + dist(plus).toFixed(2) +
  ' temperature |Δ|=' + dist(temp).toFixed(2));
ok(dist(plus) >= 12,
  'full tint must move a neutral by at least 12 8-bit levels of RGB distance, got ' + dist(plus).toFixed(2));

// 4. GPU pass gains must agree with the CPU path (the shader is the preview path).
const gpuPlus = G.buildPasses(sessionWith('tint', 1), W, H, true, true)[0].whiteBalanceGain;
const gpuMinus = G.buildPasses(sessionWith('tint', -1), W, H, true, true)[0].whiteBalanceGain;
ok(gpuPlus[1] > gpuPlus[0] + 0.1 && gpuPlus[1] > gpuPlus[2] + 0.1,
  'GPU tint +1 must raise the green gain: ' + gpuPlus.map((v) => v.toFixed(3)).join(','));
ok(gpuMinus[1] < gpuMinus[0] - 0.1 && gpuMinus[1] < gpuMinus[2] - 0.1,
  'GPU tint -1 must lower the green gain: ' + gpuMinus.map((v) => v.toFixed(3)).join(','));

// 5. Both white-balance solvers are exact inverses of the renderer model.
for (const [t, tint] of [[0.4, 0.7], [-0.6, -0.4], [0, 1]]) {
  const gains = WB.whiteBalanceGains(t, tint);
  const stat = { red: 1 / gains[0], green: 1 / gains[1], blue: 1 / gains[2], accepted: 64, visited: 64 };
  const solved = WB.solveWhiteBalance(stat);
  ok(Math.abs(solved.temperature - t) < 1e-6 && Math.abs(solved.tint - tint) < 1e-6,
    'WhiteBalanceSampling solve must invert the renderer at (' + t + ',' + tint + '), got (' +
    solved.temperature.toFixed(6) + ',' + solved.tint.toFixed(6) + ')');
  const pick = PICK.solveNeutralPatch(stat.red, stat.green, stat.blue);
  ok(Math.abs(pick.temperature - t) < 1e-6 && Math.abs(pick.tint - tint) < 1e-6,
    'WhiteBalancePickerCore solve must invert the renderer at (' + t + ',' + tint + '), got (' +
    pick.temperature.toFixed(6) + ',' + pick.tint.toFixed(6) + ')');
}

console.log('PASS tint direction/magnitude: right=green, left=magenta, monotonic, full-strength |Δ|=' +
  dist(plus).toFixed(2) + ' vs temperature ' + dist(temp).toFixed(2) + '; GPU gains and both WB solves agree.');
console.log(checks + ' checks passed');
