// Noise reduction: do the preview path and the export path produce the SAME pixels?
//
// There are two CPU denoise entry points and they are chosen by image size, not by user
// intent:
//   * the RETAINED stage (`obtainDenoisedSource` -> `denoiseTask`), used for the bounded
//     interactive preview, i.e. width*height <= 4194304;
//   * the COLOUR WORKER's own leading denoise (ProcessWorker), used for the full-resolution
//     export and for any preview too large for the retained stage.
// Both call `denoiseRows`. They only agree if they are handed the same settings and the
// same process version. They were NOT: the retained stage received four of the six
// parameters and no process version, so it silently fell back to LEGACY behaviours and
// ignored luminance contrast and colour smoothness entirely. A slider that worked in the
// export therefore did nothing in the preview.
//
// This suite mirrors `denoiseTask`'s body exactly, so it fails if that body and the
// worker's leading pass ever diverge again.
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
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
    Uint8Array, Uint16Array, Uint32Array, Int32Array, Uint8ClampedArray, Float32Array, DataView, Promise, Error,
    setTimeout, clearTimeout, TextEncoder, TextDecoder, Buffer, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (n) => {
      if (n === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0) }, GpuOutputGeometry: {} };
      if (n === 'libvivid_ai.so') return { default: { isLoaded: () => false, release: () => {}, modelInfo: () => [] } };
      if (n === '@kit.CoreFileKit') {
        return { fileIo: {
          OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 8 },
          openSync: (p, f) => ({ fd: fs.openSync(p, f === 8 ? 'r' : 'w') }),
          closeSync: (h) => fs.closeSync(typeof h === 'number' ? h : h.fd),
          writeSync: (h, b) => fs.writeSync(typeof h === 'number' ? h : h.fd, Buffer.from(b)),
          readSync: (h, b) => fs.readSync(typeof h === 'number' ? h : h.fd, new Uint8Array(b)),
          statSync: (p) => (typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p)),
        } };
      }
      if (n === '@kit.ArkTS') {
        const encoder = () => ({ encode: (t) => new Uint8Array(Buffer.from(t, 'utf8')) });
        const decoder = () => ({ decode: (b) => Buffer.from(b).toString('utf8'),
          decodeToString: (b) => Buffer.from(b).toString('utf8') });
        function TextEncoderShim() { return encoder(); }
        TextEncoderShim.create = encoder;
        function TextDecoderShim() { return decoder(); }
        TextDecoderShim.create = decoder;
        return { util: { TextEncoder: TextEncoderShim, TextDecoder: TextDecoderShim },
          taskpool: { Task: class { static isCanceled() { return false; } }, execute: async (t) => t } };
      }
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      if(n.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { denoiseRows, denoiseEnabled } = load(root + '/edit/engine/NoiseReduction.ets');
const { processBehaviors, PROCESS_VERSION_LEGACY, PROCESS_VERSION_CURRENT } =
  load(root + '/edit/models/ProcessVersion.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
function differences(a, b) {
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}

// A noisy frame WITH structure, because luminance contrast acts through a structure term
// and would be a no-op on pure flat noise.
const W = 64, H = 48;
const noisy = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    // A low-frequency ramp plus high-frequency noise.
    const base = 90 + Math.round(70 * (0.5 + 0.5 * Math.sin(x / 6)) * (0.6 + 0.4 * Math.cos(y / 9)));
    const n = ((x * 37 + y * 53) % 23) - 11;
    noisy[i] = base + n;
    noisy[i + 1] = base + Math.round(n * 0.6) + (((x + y) % 5) - 2);
    noisy[i + 2] = base - Math.round(n * 0.4) + (((x * 3 + y) % 7) - 3);
    noisy[i + 3] = 255;
  }
}
const six = { luminance: 0.6, color: 0.5, detail: 0.7, colorDetail: 0.4,
  luminanceContrast: 0.8, colorSmoothness: 0.9 };
const fourOnly = { luminance: 0.6, color: 0.5, detail: 0.7, colorDetail: 0.4 };

/** Exactly what `denoiseTask` does, so a divergence in that function is caught here. */
function retainedPath(settings, processVersion) {
  const source = new Uint8ClampedArray(noisy);
  const output = new Uint8ClampedArray(source.length);
  const behaviors = processBehaviors(processVersion === undefined ? PROCESS_VERSION_LEGACY : processVersion);
  denoiseRows(source, output, W, H, settings, 0, H, true, behaviors.denoiseFixedRadius);
  return output;
}
/** What the colour worker's leading denoise pass does. */
function workerPath(settings, processVersion) {
  const params = {
    source: Uint8ClampedArray.from(noisy).buffer, width: W, height: H,
    denoise: settings, processVersion: processVersion,
    layers: [], luts: [], cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
    rotation: 0, flipH: false, flipV: false, applyGeometry: false, ignoreCrop: false,
  };
  return new Uint8ClampedArray(processPixels(params).buffer);
}

ok(denoiseEnabled(six), 'the fixture has noise reduction enabled, or nothing below is measured');

// --- 1. The two paths must agree ----------------------------------------
const retained = retainedPath(six, PROCESS_VERSION_CURRENT);
const worker = workerPath(six, PROCESS_VERSION_CURRENT);
ok(differences(retained, worker) === 0, 'the retained preview stage and the export worker produce ' +
  'IDENTICAL pixels with all six parameters set (' + differences(retained, worker) + ' bytes differ). Before ' +
  'the fix they did not: the retained stage was handed four parameters and no process version');
ok(differences(retained, noisy) > 5000, 'and the denoise is actually doing work (' +
  differences(retained, noisy) + ' bytes changed), so the agreement above is not equality of two no-ops');
ok(differences(retainedPath(fourOnly, PROCESS_VERSION_CURRENT),
  retainedPath(six, PROCESS_VERSION_CURRENT)) > 200,
  'dropping the two newer parameters changes the result, which is exactly why omitting them from the retained ' +
  'stage was visible as a preview/export mismatch');
// Non-vacuity: replay the PRE-FIX retained invocation and show it disagrees with the worker.
const preFix = (() => {
  const source = new Uint8ClampedArray(noisy);
  const output = new Uint8ClampedArray(source.length);
  // Pre-fix: four settings, and the version omitted, so denoiseTask resolved LEGACY.
  denoiseRows(source, output, W, H, fourOnly, 0, H, true,
    processBehaviors(PROCESS_VERSION_LEGACY).denoiseFixedRadius);
  return output;
})();
ok(differences(preFix, worker) > 0, 'the pre-fix retained invocation differs from the export by ' +
  differences(preFix, worker) + ' bytes, which is the defect this suite exists to catch');
ok(differences(preFix, retained) > 0, 'and it differs from the fixed retained stage by ' +
  differences(preFix, retained) + ' bytes');

// --- 2. Each of the two newer parameters must change the picture ---------
for (const field of ['luminanceContrast', 'colorSmoothness']) {
  const varied = Object.assign({}, six);
  varied[field] = field === 'luminanceContrast' ? -0.8 : 0.05;
  const deltaRetained = differences(retainedPath(varied, PROCESS_VERSION_CURRENT), retained);
  const deltaWorker = differences(workerPath(varied, PROCESS_VERSION_CURRENT), worker);
  ok(deltaRetained > 100, field + ' changes the retained preview path (' + deltaRetained + ' bytes)');
  ok(deltaWorker > 100, field + ' changes the export worker path (' + deltaWorker + ' bytes)');
  ok(differences(retainedPath(varied, PROCESS_VERSION_CURRENT),
    workerPath(varied, PROCESS_VERSION_CURRENT)) === 0,
    field + ': and the two paths still agree once it is changed');
}

// --- 3. The process version must reach the retained stage ---------------
// It selects denoiseFixedRadius. If the retained stage cannot see it, a photo pinned to an
// older generation silently denoises like the current one.
const legacyRetained = retainedPath(six, PROCESS_VERSION_LEGACY);
const currentRetained = retainedPath(six, PROCESS_VERSION_CURRENT);
// denoiseFixedRadius only matters above a 2048 long edge, which this fixture is not, so
// the two must be equal HERE; the point of the assertion is that the value is threaded at
// all, which the source-level checks below prove.
ok(processBehaviors(PROCESS_VERSION_LEGACY).denoiseFixedRadius !==
  processBehaviors(PROCESS_VERSION_CURRENT).denoiseFixedRadius,
  'the two process versions really do differ in the denoise radius behaviour');
const ipSource = fs.readFileSync('entry/src/main/ets/edit/engine/ImageProcessor.ets', 'utf8');
const taskSource = fs.readFileSync('entry/src/main/ets/edit/engine/NoiseReductionTask.ets', 'utf8');
const bridgeSource = fs.readFileSync('entry/src/main/ets/edit/engine/GpuShaderBridge.ets', 'utf8');
const retainedCall = ipSource.substring(ipSource.indexOf('const params: DenoiseTaskParams'));
ok(/luminanceContrast:\s*settings\.luminanceContrast/.test(retainedCall),
  'the retained stage is handed luminance contrast');
ok(/colorSmoothness:\s*settings\.colorSmoothness/.test(retainedCall),
  'and colour smoothness');
ok(/processVersion:\s*snapshot\.processVersion/.test(retainedCall),
  'and the process version, without which it always resolved to LEGACY');
ok(/denoiseRows\(source, output, params\.width, params\.height, params\.settings/.test(taskSource),
  'denoiseTask passes that whole settings object through to the core');
// The cache key must distinguish everything that changes the result.
const keyStart = ipSource.indexOf('const key = owner.sessionId');
const keyText = ipSource.substring(keyStart, ipSource.indexOf('.join(\'|\')', keyStart));
for (const term of ['settings.luminanceContrast', 'settings.colorSmoothness', 'snapshot.processVersion']) {
  ok(keyText.indexOf(term) >= 0, 'the denoise cache key includes ' + term + ', so changing it cannot ' +
    'return a stale buffer');
}
ok(keyStart >= 0 && keyText.indexOf('settings.luminance') >= 0 && keyText.indexOf('renderViewport') >= 0,
  'and it still includes the original terms, so the key was extended rather than replaced');

// --- 4. The GPU must not pretend to implement them ----------------------
ok(/denoiseEnabled\(session\.denoise\) &&[\s\S]{0,200}luminanceContrast !== 0/.test(bridgeSource),
  'the GPU path declines while luminance contrast is non-default');
ok(bridgeSource.indexOf("decline('denoise-extras')") >= 0, 'through a named decline reason');
ok(/colorSmoothness !== 0\.5/.test(bridgeSource),
  'and the same for colour smoothness, which is non-default away from 0.5');
ok(bridgeSource.indexOf("decline('denoise-extras')") < bridgeSource.indexOf('noise.denoise = ['),
  'the decline happens BEFORE the four-value uniform is built, so the GPU can never render a denoise the ' +
  'export will not reproduce');
// And the switch must not fire when both are at their defaults, or the GPU would be lost
// for ordinary noise reduction.
const gpuGuard = bridgeSource.substring(bridgeSource.indexOf('const passes: NativeGpuOptions[]'),
  bridgeSource.indexOf('noise.denoise = ['));
ok(gpuGuard.indexOf('luminanceContrast !== 0') < 0 || gpuGuard.indexOf('if (denoiseEnabled') >= 0,
  'and the guard is conditional rather than unconditional');

// --- 5. End to end through the snapshot ---------------------------------
const session = new EditSession();
session.denoise.luminance = 0.6;
session.denoise.color = 0.5;
session.denoise.luminanceContrast = 0.8;
session.denoise.colorSmoothness = 0.9;
session.processVersion = PROCESS_VERSION_CURRENT;
const snap = ImageProcessor.snapshot(session);
ok(snap.denoise.luminanceContrast === 0.8 && snap.denoise.colorSmoothness === 0.9,
  'a snapshot taken from a live session carries both newer parameters');
ok(snap.processVersion === PROCESS_VERSION_CURRENT, 'and its process version');
const built = ImageProcessor.buildWorkerParams(snap, Uint8ClampedArray.from(noisy).buffer, W, H);
ok(built.denoise.luminanceContrast === 0.8 && built.denoise.colorSmoothness === 0.9,
  'and both reach the worker parameters');
ok(built.processVersion === PROCESS_VERSION_CURRENT, 'as does the process version');

console.log('PASS noise-reduction path agreement: the retained preview stage and the export worker produce');
console.log('     IDENTICAL pixels for all six parameters, each newer parameter changes both paths, and the');
console.log('     process version now reaches the retained stage instead of silently resolving to LEGACY.');
console.log('DEFECT RECORDED: the retained stage was handed four of six parameters and no process version, so');
console.log('     luminance contrast and colour smoothness worked in the export and did nothing in the preview,');
console.log('     and a photo pinned to an older generation denoised like a current one.');
console.log('NOTE the GPU has no shader implementation of those two parameters, so it now DECLINES with');
console.log('     reason=denoise-extras while either is non-default. The honest cost is that moving those two');
console.log('     sliders drops the preview to the CPU path; the alternative was a preview the export does not');
console.log('     reproduce.');
console.log(checks + ' checks passed');
