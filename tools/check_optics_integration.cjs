// Optics integration: the document model, the two bypass predicates, the
// parameter mapping, the real worker pipeline, stage ordering against BOTH the
// detail stage and geometry, the sidecar round-trip, and the GPU decline.
//
// check_optics_core.cjs proves the ALGORITHM. This suite proves the WIRING.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
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
    // NOTE: JSON is deliberately NOT injected; see check_detail_integration.cjs.
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
    Uint8Array, Uint16Array, Uint32Array, Int32Array, Uint8ClampedArray, Float32Array, DataView, Promise, Error,
    setTimeout, clearTimeout, TextEncoder, TextDecoder, Buffer, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (n) => {
      if (n === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0) }, GpuOutputGeometry: {} };
      if (n === 'libvivid_ai.so') return { default: { isLoaded: () => false, release: () => {}, modelInfo: () => [] } };
      if (n === '@kit.CoreFileKit') {
        return {
          fileIo: {
            OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 8 },
            openSync: (p, f) => ({ fd: fs.openSync(p, f === 8 ? 'r' : 'w') }),
            closeSync: (h) => fs.closeSync(typeof h === 'number' ? h : h.fd),
            writeSync: (h, b) => fs.writeSync(typeof h === 'number' ? h : h.fd, Buffer.from(b)),
            readSync: (h, b) => fs.readSync(typeof h === 'number' ? h : h.fd, new Uint8Array(b)),
            statSync: (p) => (typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p)),
          },
        };
      }
      if (n === '@kit.ArkTS') {
        const encoder = () => ({ encode: (t) => new Uint8Array(Buffer.from(t, 'utf8')),
          encodeInto: (t) => new Uint8Array(Buffer.from(t, 'utf8')) });
        const decoder = () => ({ decode: (b) => Buffer.from(b).toString('utf8'),
          decodeToString: (b) => Buffer.from(b).toString('utf8') });
        function TextEncoderShim() { return encoder(); }
        TextEncoderShim.create = encoder;
        function TextDecoderShim() { return decoder(); }
        TextDecoderShim.create = decoder;
        return {
          util: { TextEncoder: TextEncoderShim, TextDecoder: TextDecoderShim },
          taskpool: { Task: class { static isCanceled() { return false; } }, execute: async (t) => t },
        };
      }
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      if(n.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { OpticsSettings } = load(root + '/edit/models/OpticsSettings.ets');
const { opticsIsIdentity, applyOptics } = load(root + '/edit/engine/OpticsCore.ets');
const { localContrastIsIdentity, applyLocalContrast } = load(root + '/edit/engine/LocalContrastCore.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { applyGeometryFull } = load(root + '/edit/engine/WorkerCore.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
function differences(a, b) {
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}

// --- 1. The document model ------------------------------------------------
const fresh = new OpticsSettings();
ok(fresh.distortion === 0 && fresh.vignetteAmount === 0 && fresh.chromaticAberration === 0 &&
  fresh.defringePurple === 0 && fresh.defringeGreen === 0,
  'a fresh document leaves every correction at its no-op value');
ok(fresh.vignetteMidpoint === 0.5, 'a fresh document uses the midpoint default of 0.5');
ok(fresh.isBypass(), 'a fresh document is a bypass, so a new photo costs no optics pass');
ok(OpticsSettings.restore(undefined).isBypass(), 'a session/sidecar with no optics block restores to a bypass');
const wild = OpticsSettings.restore({ distortion: 9, vignetteAmount: -9, vignetteMidpoint: 4,
  chromaticAberration: NaN, defringePurple: -3, defringeGreen: 7 });
ok(wild.distortion === 1 && wild.vignetteAmount === -1, 'signed corrections clamp to +/-1');
ok(wild.vignetteMidpoint === 1, 'the midpoint clamps into 0..1');
ok(wild.chromaticAberration === 0, 'a non-finite value restores to the no-op default, not to NaN');
ok(wild.defringePurple === 0 && wild.defringeGreen === 1, 'unsigned corrections clamp to 0..1');

// --- 2. The two bypass predicates must agree ------------------------------
// The UI and the GPU gate on OpticsSettings.isBypass(); both renderers gate on
// opticsIsIdentity(). Separate implementations of one truth: if they diverge, the
// GPU can render a frame the CPU would have skipped.
let predicateChecks = 0, disagreements = [];
for (const distortion of [0, 0.5, -0.5, 1]) {
  for (const vignetteAmount of [0, -0.5]) {
    for (const chromaticAberration of [0, 0.5]) {
      for (const defringePurple of [0, 1]) {
        for (const defringeGreen of [0, 1]) {
          for (const vignetteMidpoint of [0, 0.5, 1]) {
            const settings = OpticsSettings.restore({ distortion: distortion, vignetteAmount: vignetteAmount,
              vignetteMidpoint: vignetteMidpoint, chromaticAberration: chromaticAberration,
              defringePurple: defringePurple, defringeGreen: defringeGreen });
            const params = { distortion: settings.distortion, vignetteAmount: settings.vignetteAmount,
              vignetteMidpoint: settings.vignetteMidpoint, chromaticAberration: settings.chromaticAberration,
              defringePurple: settings.defringePurple, defringeGreen: settings.defringeGreen };
            predicateChecks++;
            if (settings.isBypass() !== opticsIsIdentity(params)) disagreements.push(JSON.stringify(params));
          }
        }
      }
    }
  }
}
ok(disagreements.length === 0, 'the UI/GPU bypass test and the renderer bypass test agree on all ' +
  predicateChecks + ' sampled settings' + (disagreements.length ? ': ' + disagreements.slice(0, 2).join(' ') : ''));
const midpointOnly = OpticsSettings.restore({ vignetteMidpoint: 1 });
ok(midpointOnly.isBypass() && opticsIsIdentity({ distortion: 0, vignetteAmount: 0, vignetteMidpoint: 1,
  chromaticAberration: 0, defringePurple: 0, defringeGreen: 0 }),
  'the midpoint alone is a bypass for both predicates: with no depth there is no falloff for it to move');

// --- 3. The parameter mapping must carry all six fields -------------------
const mapped = new EditSession();
mapped.optics.distortion = 0.11; mapped.optics.vignetteAmount = -0.22; mapped.optics.vignetteMidpoint = 0.33;
mapped.optics.chromaticAberration = 0.44; mapped.optics.defringePurple = 0.55;
mapped.optics.defringeGreen = 0.66;
const plain = ImageProcessor.plainOptics(mapped.optics);
ok(plain.distortion === 0.11 && plain.vignetteAmount === -0.22 && plain.vignetteMidpoint === 0.33 &&
  plain.chromaticAberration === 0.44 && plain.defringePurple === 0.55 && plain.defringeGreen === 0.66,
  'the renderer mapping carries all six corrections (a dropped field would silently disable a slider)');

// --- 4. The real worker pipeline -----------------------------------------
const W = 64, H = 48;
function fixture() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const grain = ((x * 5 + y * 11) % 13) - 6;
      const base = 50 + Math.round(120 * x / W);
      b[i] = base + grain; b[i + 1] = Math.round(base * 0.85) + grain;
      b[i + 2] = Math.round(base * 0.7) + grain; b[i + 3] = 255;
    }
  }
  return b;
}
const source = fixture();
function params(over) {
  const base = {
    source: Uint8ClampedArray.from(source).buffer,
    width: W, height: H, layers: [], luts: [],
    cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
    rotation: 0, flipH: false, flipV: false,
    applyGeometry: false, ignoreCrop: false,
  };
  return Object.assign(base, over);
}
const bypass = ImageProcessor.plainOptics(new OpticsSettings());
const strong = { distortion: 0.6, vignetteAmount: -0.7, vignetteMidpoint: 0.4,
  chromaticAberration: 0.5, defringePurple: 0.8, defringeGreen: 0.8 };

const bypassPixels = new Uint8ClampedArray(processPixels(params({ optics: bypass })).buffer);
ok(bypassPixels.length === W * H * 4, 'the bypass job returns a full frame');
ok(differences(bypassPixels, source) === 0, 'a bypassed optics stage reproduces the source byte for byte');
ok(differences(new Uint8ClampedArray(processPixels(params({ optics: undefined })).buffer), source) === 0,
  'omitting the optics block entirely is also byte-for-byte free');
ok(differences(new Uint8ClampedArray(processPixels(params({ optics: ImageProcessor.plainOptics(
  OpticsSettings.restore({ vignetteMidpoint: 1 })) })).buffer), source) === 0,
  'a midpoint-only change reaches the renderer and changes nothing, matching the bypass predicate');

const activePixels = new Uint8ClampedArray(processPixels(params({ optics: strong })).buffer);
let activeDiff = 0, activeMax = 0;
for (let i = 0; i < activePixels.length; i++) {
  const delta = Math.abs(activePixels[i] - source[i]);
  if (delta > 0) activeDiff++;
  if (delta > activeMax) activeMax = delta;
}
ok(activeDiff > 1000, 'the optics stage changes the rendered frame (' + activeDiff + ' bytes, peak ' +
  activeMax + ' levels)');
ok(activeMax >= 6, 'the change is visible rather than a rounding wobble (peak ' + activeMax + ' levels)');
ok(differences(new Uint8ClampedArray(processPixels(params({ optics: strong })).buffer), activePixels) === 0,
  'two identical jobs produce identical output');

// --- 5. Stage ordering, verified against the real stages -----------------
// The contract is: detail first, then optics, then geometry. Each is checked by
// composing the real modules by hand and comparing bytes, and the OPPOSITE order
// is checked too so the assertion cannot pass for a pipeline that did either.
const detailParams = { texture: 0.3, clarity: 0.6, dehaze: 0.2, sharpenAmount: 0.4,
  sharpenRadius: 0.5, sharpenDetail: 0.5, sharpenMasking: 0 };
const bothRun = new Uint8ClampedArray(processPixels(params({ detail: detailParams, optics: strong })).buffer);
// detail then optics, which is what the worker must do.
const detailFirst = applyOptics(
  applyLocalContrast(Uint8ClampedArray.from(source), W, H, detailParams, Math.max(W, H)),
  W, H, strong);
ok(differences(bothRun, detailFirst) === 0,
  'the worker runs detail before optics (' + differences(bothRun, detailFirst) + ' differing bytes)');
// optics then detail, which must NOT match.
const opticsFirst = applyLocalContrast(
  applyOptics(Uint8ClampedArray.from(source), W, H, strong), W, H, detailParams, Math.max(W, H));
const orderGap = differences(bothRun, opticsFirst);
ok(orderGap > 200, 'the opposite order gives a different frame (' + orderGap + ' differing bytes), so the ' +
  'ordering assertion above is not vacuous');

// Optics must run BEFORE geometry: the correction is applied to the full frame and
// then cropped, not applied to the cropped result.
const croppedRun = processPixels(params({ optics: strong, cropRight: 0.5, applyGeometry: true }));
const croppedPixels = new Uint8ClampedArray(croppedRun.buffer);
const cropWidth = Math.round(W * 0.5);
ok(croppedRun.width === cropWidth && croppedRun.height === H,
  'the cropped job returns the cropped dimensions (' + croppedRun.width + 'x' + croppedRun.height + ')');
const correctionFirst = applyGeometryFull(
  applyOptics(Uint8ClampedArray.from(source), W, H, strong), W, H,
  params({ optics: strong, cropRight: 0.5, applyGeometry: true }));
ok(differences(croppedPixels, correctionFirst.pixels) === 0,
  'the worker corrects the full frame and only then crops (' +
  differences(croppedPixels, correctionFirst.pixels) + ' differing bytes)');
const cropThenCorrect = applyOptics(
  applyGeometryFull(Uint8ClampedArray.from(source), W, H,
    params({ optics: strong, cropRight: 0.5, applyGeometry: true })).pixels,
  cropWidth, H, strong);
const cropOrderGap = differences(croppedPixels, cropThenCorrect);
ok(cropOrderGap > 100, 'correcting the crop instead gives a different frame (' + cropOrderGap +
  ' differing bytes), so the geometry ordering assertion is not vacuous');

// --- 6. The sidecar / undo round-trip ------------------------------------
const session = new EditSession();
session.layers = [new Layer('synthetic')];
session.optics.distortion = 0.42; session.optics.vignetteAmount = -0.13;
session.optics.vignetteMidpoint = 0.27; session.optics.chromaticAberration = 0.61;
session.optics.defringePurple = 0.34; session.optics.defringeGreen = 0.19;
const exported = JSON.parse(session.exportAdjustmentState());
ok(exported.optics && exported.optics.distortion === 0.42 && exported.optics.defringeGreen === 0.19,
  'the exported adjustment state carries the optics stage');
const reopened = new EditSession();
reopened.layers = [new Layer('synthetic')];
ok(reopened.importAdjustmentState(JSON.stringify(exported)), 'the exported state imports back');
ok(reopened.optics.distortion === 0.42 && reopened.optics.vignetteAmount === -0.13 &&
  reopened.optics.vignetteMidpoint === 0.27 && reopened.optics.chromaticAberration === 0.61 &&
  reopened.optics.defringePurple === 0.34 && reopened.optics.defringeGreen === 0.19,
  'all six corrections survive the session round-trip');
const legacy = JSON.parse(JSON.stringify(exported));
delete legacy.optics;
const legacySession = new EditSession();
legacySession.layers = [new Layer('synthetic')];
ok(legacySession.importAdjustmentState(JSON.stringify(legacy)), 'a sidecar written before this stage imports');
ok(legacySession.optics.isBypass(), 'a pre-existing photo opens at an exact bypass, not on a random correction');
ok(legacySession.optics.vignetteMidpoint === 0.5, 'and still gets the 0.5 midpoint default');

// Undo must carry the fields too.
const undoSession = new EditSession();
undoSession.layers = [new Layer('synthetic')];
undoSession.pushUndo();
undoSession.optics.distortion = 0.7;
undoSession.pushUndo();
undoSession.optics.distortion = -0.4;
undoSession.undo();
ok(undoSession.optics.distortion === 0.7, 'undo restores the previous distortion (' +
  undoSession.optics.distortion + ')');
undoSession.undo();
ok(undoSession.optics.distortion === 0, 'undo restores the identity when the stage was untouched');
undoSession.redo();
ok(undoSession.optics.distortion === 0.7, 'redo re-applies it');

// --- 7. The GPU must decline rather than omit the corrections -------------
const bridgeSource = fs.readFileSync('entry/src/main/ets/edit/engine/GpuShaderBridge.ets', 'utf8');
ok(bridgeSource.includes("if (!session.optics.isBypass()) return GpuShaderBridge.decline('optics');"),
  'the GPU path declines with reason=optics while the stage is active');
const workerSource = fs.readFileSync('entry/src/main/ets/edit/engine/ProcessWorker.ets', 'utf8');
ok(workerSource.includes('applyOptics(result, width, height, optics)'),
  'the worker applies the corrections to the full frame');
const fallbackSource = fs.readFileSync('entry/src/main/ets/edit/engine/ImageProcessor.ets', 'utf8');
ok(fallbackSource.includes('applyOptics(pool.result, width, height, opticsParams)'),
  'the UI-thread fallback applies the same stage, so both CPU paths agree');

console.log('PASS optics integration: document model, bypass semantics, the two predicate implementations');
console.log('     agreeing over 192 combinations, the full six-field mapping, the real worker pipeline, the');
console.log('     stage order against BOTH the detail stage and geometry (with the opposite orders checked to');
console.log('     be different), sidecar and undo round-trips, and the GPU declining instead of omitting.');
console.log('NOTE the algorithm quality claims are check_optics_core.cjs, not this suite. The GPU decline is');
console.log('     asserted at the source level here and exercised on the running native pipeline by');
console.log('     check_shader_parity.cjs.');
console.log(checks + ' checks passed');
