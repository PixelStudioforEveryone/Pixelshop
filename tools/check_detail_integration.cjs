// Detail stage integration: the model, the two bypass predicates, the parameter
// mapping, the real worker pipeline, stage ordering and the sidecar round-trip.
//
// check_local_contrast.cjs proves the ALGORITHM. This suite proves the WIRING:
// that the document setting actually reaches the renderer, that a bypass is
// byte-for-byte free, and that the stage runs in the right place in the pipeline.
// Nothing here re-tests the algorithm's own quality claims.
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
    // NOTE: JSON is deliberately NOT injected. Injecting the outer realm's JSON
    // makes the VM parse arrays with the outer Array constructor, after which
    // EditSession's own `parsed.layers instanceof Array` (the VM's Array) is
    // false and every import silently reports failure.
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

const { DetailSettings } = load(root + '/edit/models/DetailSettings.ets');
const { localContrastIsIdentity, applyLocalContrast } = load(root + '/edit/engine/LocalContrastCore.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { applyGeometryFull } = load(root + '/edit/engine/WorkerCore.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }

// --- 1. The document model ------------------------------------------------
const fresh = new DetailSettings();
ok(fresh.texture === 0 && fresh.clarity === 0 && fresh.dehaze === 0 && fresh.sharpenAmount === 0,
  'a fresh document leaves the four active stages at bypass');
ok(fresh.sharpenDetail === 0.25, 'a fresh document uses the 25 detail default, not 0');
ok(fresh.isBypass(), 'a fresh document is a bypass, so a new photo costs no detail pass');
ok(DetailSettings.restore(undefined).isBypass(), 'a session/sidecar with no detail block restores to a bypass');

const wild = DetailSettings.restore({ texture: 5, clarity: -5, dehaze: NaN, sharpenAmount: -1,
  sharpenRadius: 9, sharpenDetail: -3, sharpenMasking: 2 });
ok(wild.texture === 1 && wild.clarity === -1, 'signed stages clamp to +/-1');
ok(wild.dehaze === 0, 'a non-finite dehaze restores to 0 rather than propagating NaN into every pixel');
ok(wild.sharpenAmount === 0 && wild.sharpenRadius === 1 && wild.sharpenDetail === 0 && wild.sharpenMasking === 1,
  'unsigned stages clamp to 0..1');
ok(DetailSettings.restore({ texture: 0.4 }).clarity === 0,
  'a partially specified detail block fills the missing stages with bypass values');

// --- 2. The two bypass predicates must agree ------------------------------
// The UI and the GPU gate on DetailSettings.isBypass() while the renderers gate
// on localContrastIsIdentity(). They are separate implementations of one truth:
// if they ever disagree, the GPU can render a frame the CPU would have skipped
// (or vice versa) and preview would stop matching export.
let predicateChecks = 0, disagreements = [];
const extras = [{}, { sharpenRadius: 1 }, { sharpenDetail: 1 }, { sharpenMasking: 1 },
  { sharpenRadius: 1, sharpenDetail: 1, sharpenMasking: 1 }];
for (const texture of [0, 0.5, -0.5, 1, -1]) {
  for (const clarity of [0, 0.5]) {
    for (const dehaze of [0, -0.5]) {
      for (const sharpenAmount of [0, 0.5]) {
        for (const extra of extras) {
          const d = DetailSettings.restore({ texture: texture, clarity: clarity, dehaze: dehaze,
            sharpenAmount: sharpenAmount, sharpenRadius: extra.sharpenRadius ?? 0,
            sharpenDetail: extra.sharpenDetail ?? 0.25, sharpenMasking: extra.sharpenMasking ?? 0 });
          const p = { texture: d.texture, clarity: d.clarity, dehaze: d.dehaze,
            sharpenAmount: d.sharpenAmount, sharpenRadius: d.sharpenRadius,
            sharpenDetail: d.sharpenDetail, sharpenMasking: d.sharpenMasking };
          predicateChecks++;
          if (d.isBypass() !== localContrastIsIdentity(p)) disagreements.push(JSON.stringify(p));
        }
      }
    }
  }
}
ok(disagreements.length === 0, 'the UI/GPU bypass test and the renderer bypass test agree on all ' +
  predicateChecks + ' sampled settings' + (disagreements.length ? ': ' + disagreements.slice(0, 3).join(' ') : ''));
// The asymmetric part is the one worth pinning: radius/detail/masking alone are
// inert, because they only shape how much sharpening is applied.
const radiusOnly = DetailSettings.restore({ sharpenRadius: 1, sharpenDetail: 1, sharpenMasking: 1 });
ok(radiusOnly.isBypass(), 'radius/detail/masking alone are a bypass (there is nothing for them to shape)');
ok(localContrastIsIdentity({ texture: 0, clarity: 0, dehaze: 0, sharpenAmount: 0,
  sharpenRadius: 1, sharpenDetail: 1, sharpenMasking: 1 }),
  'the renderer agrees that radius/detail/masking alone are a bypass');

// --- 3. The parameter mapping must carry all seven fields -----------------
const mapped = new EditSession();
mapped.detail.texture = 0.11; mapped.detail.clarity = -0.22; mapped.detail.dehaze = 0.33;
mapped.detail.sharpenAmount = 0.44; mapped.detail.sharpenRadius = 0.55;
mapped.detail.sharpenDetail = 0.66; mapped.detail.sharpenMasking = 0.77;
const plain = ImageProcessor.plainDetail(mapped.detail);
ok(plain.texture === 0.11 && plain.clarity === -0.22 && plain.dehaze === 0.33 &&
  plain.sharpenAmount === 0.44 && plain.sharpenRadius === 0.55 && plain.sharpenDetail === 0.66 &&
  plain.sharpenMasking === 0.77,
  'the renderer mapping carries all seven stages (a dropped field would silently disable a slider)');

// --- 4. The real worker pipeline ------------------------------------------
const W = 96, H = 64;
function clamp255(v) { return v < 0 ? 0 : (v > 255 ? 255 : Math.round(v)); }
// A gradient carrying fine texture, so every stage has something to act on.
function fixture() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const grain = ((x * 7 + y * 13) % 17) - 8;
      const base = 40 + Math.round(140 * x / W);
      b[i] = clamp255(base + grain); b[i + 1] = clamp255(base * 0.8 + grain);
      b[i + 2] = clamp255(base * 0.6 + grain); b[i + 3] = 255;
    }
  }
  return b;
}
const source = fixture();
function params(detail, cropRight) {
  return {
    source: Uint8ClampedArray.from(source).buffer,
    width: W, height: H, layers: [], luts: [],
    cropLeft: 0, cropTop: 0, cropRight: cropRight, cropBottom: 1,
    rotation: 0, flipH: false, flipV: false,
    applyGeometry: cropRight < 1, ignoreCrop: false, detail: detail,
  };
}
function bypassDetail() {
  const d = new DetailSettings();
  return ImageProcessor.plainDetail(d);
}
const strong = { texture: 0.7, clarity: 0.9, dehaze: 0.5, sharpenAmount: 0.8,
  sharpenRadius: 0.5, sharpenDetail: 0.5, sharpenMasking: 0 };

// A bypass must be byte-for-byte free, not merely close.
const bypassRun = processPixels(params(bypassDetail(), 1));
const bypassPixels = new Uint8ClampedArray(bypassRun.buffer);
ok(bypassPixels.length === W * H * 4, 'the bypass job returns a full frame');
let bypassDiff = 0;
for (let i = 0; i < bypassPixels.length; i++) if (bypassPixels[i] !== source[i]) bypassDiff++;
ok(bypassDiff === 0, 'a bypassed detail stage reproduces the source byte for byte (' + bypassDiff + ' differing bytes)');
// And an omitted block must behave identically to a bypassed one.
const omittedRun = processPixels(params(undefined, 1));
let omittedDiff = 0;
const omittedPixels = new Uint8ClampedArray(omittedRun.buffer);
for (let i = 0; i < omittedPixels.length; i++) if (omittedPixels[i] !== source[i]) omittedDiff++;
ok(omittedDiff === 0, 'omitting the detail block entirely is also byte-for-byte free');

// An active stage must actually change the frame: a slider that renders nothing
// would be exactly the fake control this work must not ship.
const activeRun = processPixels(params(strong, 1));
const activePixels = new Uint8ClampedArray(activeRun.buffer);
let activeDiff = 0, activeMax = 0;
for (let i = 0; i < activePixels.length; i++) {
  const delta = Math.abs(activePixels[i] - source[i]);
  if (delta > 0) activeDiff++;
  if (delta > activeMax) activeMax = delta;
}
ok(activeDiff > 1000, 'the detail stage changes the rendered frame (' + activeDiff + ' bytes, peak ' +
  activeMax + ' levels)');
ok(activeMax >= 4, 'the change is visible rather than a rounding wobble (peak ' + activeMax + ' levels)');

// The worker must be deterministic.
const repeatRun = processPixels(params(strong, 1));
const repeatPixels = new Uint8ClampedArray(repeatRun.buffer);
let repeatDiff = 0;
for (let i = 0; i < repeatPixels.length; i++) if (repeatPixels[i] !== activePixels[i]) repeatDiff++;
ok(repeatDiff === 0, 'two identical jobs produce identical output');
// Buffer ownership: the job owns the buffer it is handed (TaskPool transfers it),
// so it is allowed to write into it and an aliasing result is by design. The
// property worth pinning instead is that a buffer whose size disagrees with the
// declared dimensions is refused rather than rendered as a misaligned frame 鈥?// which is exactly what a detail stage reading neighbours could turn into a
// silently corrupted picture.
let rejected = null;
try {
  const bad = params(strong, 1);
  bad.source = new Uint8ClampedArray(W * H * 4 + 4).buffer;
  processPixels(bad);
} catch (error) {
  rejected = String(error && error.message ? error.message : error);
}
ok(rejected !== null && rejected.indexOf('Invalid RGBA worker dimensions') >= 0,
  'a source buffer that does not match the declared dimensions is rejected, not misrendered (' +
  rejected + ')');

// --- 5. Stage ordering: detail runs before geometry -----------------------
// This is the property that decides whether an export matches its preview, and
// it is invisible in any single-stage test.
const cropParams = params(strong, 0.5);
const croppedRun = processPixels(cropParams);
const croppedPixels = new Uint8ClampedArray(croppedRun.buffer);
const expectedWidth = Math.round(W * 0.5);
ok(croppedRun.width === expectedWidth && croppedRun.height === H,
  'the cropped job returns the cropped dimensions (' + croppedRun.width + 'x' + croppedRun.height + ')');
// The contract: clean the full frame, then crop it.
const cleanFirst = applyGeometryFull(
  applyLocalContrast(Uint8ClampedArray.from(source), W, H, strong, Math.max(W, H)),
  W, H, params(strong, 0.5));
let orderDiff = 0;
for (let i = 0; i < croppedPixels.length; i++) {
  if (croppedPixels[i] !== cleanFirst.pixels[i]) orderDiff++;
}
ok(orderDiff === 0, 'the worker cleans the full frame and only then crops (' + orderDiff + ' differing bytes)');
// The opposite order must NOT reproduce it, or the assertion above would pass
// for a pipeline that did the stage in either place.
const cropFirstPixels = applyGeometryFull(Uint8ClampedArray.from(source), W, H, params(strong, 0.5)).pixels;
const cropFirst = applyLocalContrast(cropFirstPixels, expectedWidth, H, strong, Math.max(W, H));
let wrongOrderDiff = 0;
for (let i = 0; i < croppedPixels.length; i++) {
  if (croppedPixels[i] !== cropFirst[i]) wrongOrderDiff++;
}
ok(wrongOrderDiff > 100, 'the opposite order gives a different frame (' + wrongOrderDiff +
  ' differing bytes), so the ordering assertion above is not vacuous');

// --- 6. The sidecar / undo round-trip ------------------------------------
const session = new EditSession();
session.layers = [new Layer('synthetic')];
session.detail.texture = 0.42; session.detail.clarity = -0.13; session.detail.dehaze = 0.27;
session.detail.sharpenAmount = 0.61; session.detail.sharpenRadius = 0.34;
session.detail.sharpenDetail = 0.72; session.detail.sharpenMasking = 0.19;
const exported = JSON.parse(session.exportAdjustmentState());
ok(exported.detail && exported.detail.texture === 0.42 && exported.detail.sharpenMasking === 0.19,
  'the exported adjustment state carries the detail stage');
const reopened = new EditSession();
reopened.layers = [new Layer('synthetic')];
ok(reopened.importAdjustmentState(JSON.stringify(exported)), 'the exported state imports back');
ok(reopened.detail.texture === 0.42 && reopened.detail.clarity === -0.13 &&
  reopened.detail.dehaze === 0.27 && reopened.detail.sharpenAmount === 0.61 &&
  reopened.detail.sharpenRadius === 0.34 && reopened.detail.sharpenDetail === 0.72 &&
  reopened.detail.sharpenMasking === 0.19,
  'all seven stages survive the session round-trip');
// A pre-detail sidecar must not acquire a look.
const legacy = JSON.parse(JSON.stringify(exported));
delete legacy.detail;
const legacySession = new EditSession();
legacySession.layers = [new Layer('synthetic')];
ok(legacySession.importAdjustmentState(JSON.stringify(legacy)), 'a sidecar written before this stage imports');
ok(legacySession.detail.isBypass(), 'a pre-existing photo opens at an exact bypass, not on a random look');
ok(legacySession.detail.sharpenDetail === 0.25, 'a pre-existing photo still gets the 25 detail default');

// --- 7. The GPU must decline rather than omit the stage -------------------
// GpuShaderBridge has no implementation for these stages. Rendering anyway would
// produce a preview that disagrees with the export, so the decline is part of
// the contract. Asserted at the source level here because driving the real
// native decline needs the GLES harness; check_shader_parity.cjs covers the
// running pipeline.
const bridgeSource = fs.readFileSync('entry/src/main/ets/edit/engine/GpuShaderBridge.ets', 'utf8');
ok(bridgeSource.includes("if (!session.detail.isBypass()) return GpuShaderBridge.decline('local-contrast');"),
  'the GPU path declines with reason=local-contrast while the stage is active');
ok(bridgeSource.includes('GpuShaderBridge.decline('), 'the decline mechanism is the shared one, not a silent bypass');
// And the worker must run the stage even when the GPU declined for that reason,
// i.e. the stage cannot live only in the shader it does not have.
const workerSource = fs.readFileSync('entry/src/main/ets/edit/engine/ProcessWorker.ets', 'utf8');
ok(/applyLocalContrast\(\s*result,\s*width,\s*height,\s*detail,\s*Math\.max\(width, height\)/.test(workerSource),
  'the worker applies the stage to the full frame at its own long edge');
// 瓦片渲染还要带上整帧雾色，否则去朦胧在放大后与整帧不一致。
ok(workerSource.includes('params.detailHaze'),
  'the worker forwards the whole-frame dehaze haze so a zoom tile matches the full frame');
const fallbackSource = fs.readFileSync('entry/src/main/ets/edit/engine/ImageProcessor.ets', 'utf8');
ok(/applyLocalContrast\(\s*pool\.result,\s*width,\s*height,\s*detailParams,\s*Math\.max\(width, height\)/.test(fallbackSource),
  'the UI-thread fallback applies the same stage with the same radii, so both CPU paths agree');
ok(fallbackSource.includes('session.detailHaze'),
  'the UI-thread fallback forwards the same whole-frame haze');

console.log('PASS detail integration: document model, bypass semantics, the two predicate implementations');
console.log('     agreeing, full parameter mapping, the real worker pipeline (bypass is byte-free, an active');
console.log('     stage changes pixels, determinism), stage ordering against geometry, sidecar round-trip, and');
console.log('     the GPU declining instead of omitting the stage.');
console.log('NOTE the algorithm\'s own quality claims are check_local_contrast.cjs, not this suite. The GPU');
console.log('     decline is asserted at the source level here; check_shader_parity.cjs exercises the');
console.log('     running native pipeline.');
console.log(checks + ' checks passed');
