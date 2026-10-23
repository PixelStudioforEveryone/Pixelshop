// F3 — denoise must use ONE neighbourhood per process generation on all three
// CPU paths and must not silently use a different one on the GPU.
//
// LEGACY (process version 1) pins the bilateral radius to 2 pixels
// (ProcessBehaviors.denoiseFixedRadius). The TaskPool worker and the retained
// denoise task resolve that from the generation table, but:
//   * the GPU shader derives its radius from the frame long edge (vivid_gpu.cpp
//     nrRadius, 2..5) and has no uniform for the pinned value, and
//   * the main-thread fallback ignored processVersion entirely.
// Fix: the GPU declines a LEGACY session (`denoise-version`) so it renders on the
// CPU with its pinned radius, and the main-thread fallback resolves the same
// generation table as the worker. This suite proves all three choices agree.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const modules = new Map(), storage = new Map(), logLines = [];
const consoleStub = {
  log: (...a) => logLines.push(a.join(' ')), info: (...a) => logLines.push(a.join(' ')),
  warn: (...a) => logLines.push(a.join(' ')), error: (...a) => logLines.push(a.join(' ')),
};
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} }; modules.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console: consoleStub, Math, Number, Date, Map, Set,
    ArrayBuffer, Uint8Array, Uint8ClampedArray, Uint32Array, Float32Array, Promise, Error,
    setTimeout, clearTimeout, Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (name) => {
      if (name === 'libvivid_gpu.so') return { default: { renderStack: async (k, s, i, w, h) => new ArrayBuffer(w * h * 4) }, GpuOutputGeometry: {} };
      if (name === '@kit.ArkTS') return { taskpool: { Task: class { static isCanceled() { return false; } constructor(f, ...a) { this.f = f; this.a = a; } }, execute: async (t) => t.f(...t.a) } };
      if (name === 'libvivid_pixels.so') return { default: { rasterizeLinear: (w, h) => new ArrayBuffer(w * h), rasterizeRadial: (w, h) => new ArrayBuffer(w * h), remapGeometry: (b, w, h) => new ArrayBuffer(w * h * 4), composeInto() {}, invertOpacity() {}, sampleBitmap() {} } };
      if (name.startsWith('@kit.')) return { hilog: { info() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');
const { PROCESS_VERSION_LEGACY, PROCESS_VERSION_CURRENT, processBehaviors } = load(root + '/edit/models/ProcessVersion.ets');
const { denoiseRows, denoiseSpatialRadius } = load(root + '/edit/engine/NoiseReduction.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { GpuShaderBridge } = load(root + '/edit/engine/GpuShaderBridge.ets');

const W = 2600, H = 8; // long edge 2600 -> frame-relative radius 3, legacy pin 2
const DENOISE = { luminance: 0.8, color: 0.4, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 0, colorSmoothness: 0.5 };

function sourcePixels() {
  const pixels = new Uint8ClampedArray(W * H * 4);
  let state = 123456789;
  const random = () => { state = (Math.imul(state, 1103515245) + 12345) >>> 0; return state / 4294967296; };
  for (let i = 0; i < pixels.length; i += 4) {
    const base = 60 + Math.round(120 * ((i / 4) % W) / W);
    const noise = Math.round((random() - 0.5) * 60);
    pixels[i] = base + noise; pixels[i + 1] = base + noise; pixels[i + 2] = base + noise; pixels[i + 3] = 255;
  }
  return pixels;
}

function workerDenoise(version) {
  const params = {
    source: sourcePixels().buffer, width: W, height: H, layers: [], luts: [],
    denoise: DENOISE, processVersion: version,
    cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
    rotation: 0, flipH: false, flipV: false, applyGeometry: false, ignoreCrop: false,
  };
  return new Uint8ClampedArray(processPixels(params).buffer);
}

function directDenoise(fixedRadius) {
  const source = sourcePixels();
  const output = new Uint8ClampedArray(source.length);
  denoiseRows(source, output, W, H, DENOISE, 0, H, true, fixedRadius);
  return output;
}

function same(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function gpuSession(version) {
  const session = new EditSession();
  const layer = new Layer('base');
  layer.adjustments.exposure = 0.2;
  session.layers = [layer];
  session.denoise.luminance = DENOISE.luminance;
  session.denoise.color = DENOISE.color;
  session.processVersion = version;
  return session;
}

function gpuPasses(session) { return GpuShaderBridge.buildPasses(session, W, H, true, true); }

// ---- 1. GPU choice -----------------------------------------------------------
logLines.length = 0;
const legacySession = gpuSession(PROCESS_VERSION_LEGACY);
assert.strictEqual(gpuPasses(legacySession), null,
  'a LEGACY session with denoise must decline the GPU (the shader cannot honour the pinned radius)');
assert(logLines.some((line) => line.includes('denoise-version')),
  'the decline reason must name denoise-version: ' + logLines.join(' | '));
const currentSession = gpuSession(PROCESS_VERSION_CURRENT);
const currentPasses = gpuPasses(currentSession);
assert(Array.isArray(currentPasses) && currentPasses.length > 0,
  'a CURRENT session with denoise still renders on the GPU');
assert.strictEqual(currentPasses[0].denoise[0], DENOISE.luminance,
  'the CURRENT GPU pass carries the denoise settings');

// The shader's own radius formula, mirrored from vivid_gpu.cpp nrRadius:
// clamp(floor(2*max(w,h)/2048 + .5), 2, 5). At 2600 it is 3, while LEGACY pins 2.
const shaderRadius = (w, h) => Math.max(2, Math.min(5, Math.floor(2 * Math.max(w, h) / 2048 + 0.5)));
assert.strictEqual(shaderRadius(W, H), 3, 'fixture must be large enough that the GPU radius is not 2');
assert.strictEqual(denoiseSpatialRadius(W, H, processBehaviors(PROCESS_VERSION_CURRENT).denoiseFixedRadius), 3,
  'CURRENT CPU and the shader agree on the frame-relative radius');
assert.notStrictEqual(shaderRadius(W, H),
  denoiseSpatialRadius(W, H, processBehaviors(PROCESS_VERSION_LEGACY).denoiseFixedRadius),
  'LEGACY CPU radius (2) differs from what the shader would do (3): this is exactly why the GPU must decline');

// ---- 2. Worker + retained task + fallback all resolve the same table ----------
assert(same(workerDenoise(PROCESS_VERSION_LEGACY), directDenoise(2)),
  'the worker filters a LEGACY photo with radius 2');
assert(same(workerDenoise(PROCESS_VERSION_CURRENT), directDenoise(0)),
  'the worker filters a CURRENT photo with the frame-relative radius');
assert(!same(workerDenoise(PROCESS_VERSION_LEGACY), workerDenoise(PROCESS_VERSION_CURRENT)),
  'the two generations really do produce different pixels at this frame size');

const fallbackLegacy = ImageProcessor.denoiseFallbackRadius(gpuSession(PROCESS_VERSION_LEGACY));
const fallbackCurrent = ImageProcessor.denoiseFallbackRadius(gpuSession(PROCESS_VERSION_CURRENT));
assert.strictEqual(fallbackLegacy, 2, 'the main-thread fallback uses radius 2 for LEGACY');
assert.strictEqual(fallbackCurrent, 0, 'the main-thread fallback uses the frame-relative rule for CURRENT');
assert.strictEqual(denoiseSpatialRadius(W, H, fallbackLegacy),
  denoiseSpatialRadius(W, H, processBehaviors(PROCESS_VERSION_LEGACY).denoiseFixedRadius),
  'fallback and worker resolve the same LEGACY radius');
assert.strictEqual(denoiseSpatialRadius(W, H, fallbackCurrent),
  denoiseSpatialRadius(W, H, processBehaviors(PROCESS_VERSION_CURRENT).denoiseFixedRadius),
  'fallback and worker resolve the same CURRENT radius');
assert(same(directDenoise(fallbackLegacy), workerDenoise(PROCESS_VERSION_LEGACY)),
  'a fallback render of a LEGACY photo is byte-identical to the worker render');

// The fallback must actually pass the resolved value to denoiseRows; a source
// assertion is used because the call sits inside the chunked main-thread loop.
const processorSource = fs.readFileSync('entry/src/main/ets/edit/engine/ImageProcessor.ets', 'utf8');
const fallbackStart = processorSource.indexOf('const fallbackRadius = ImageProcessor.denoiseFallbackRadius(session);');
assert(fallbackStart >= 0, 'the fallback must resolve the generation radius');
const fallbackCall = processorSource.indexOf('denoiseRows(', fallbackStart);
assert(fallbackCall > fallbackStart, 'the fallback must call denoiseRows');
const fallbackBody = processorSource.slice(fallbackCall, fallbackCall + 260);
assert(/denoiseRows\([^;]*fallbackRadius\)/.test(fallbackBody),
  'the fallback denoiseRows call must pass the resolved radius: ' + fallbackBody);

console.log('PASS denoise process-version paths: LEGACY declines the GPU by name (denoise-version) and renders');
console.log('     with radius 2 on the worker and the main-thread fallback; CURRENT renders on the GPU and');
console.log('     filters with the frame-relative radius on both CPU paths. At ' + W + 'x' + H + ' the shader radius is ' +
  shaderRadius(W, H) + ', the LEGACY pin 2, and the two');
console.log('     generations are shown to produce different pixels, so the assertions are not vacuous.');
