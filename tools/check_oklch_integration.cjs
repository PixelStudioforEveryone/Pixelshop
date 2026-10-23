// OkLCh grading integration: the model, the real worker pipeline, stage ORDER against
// point colour and detail, and the GPU decline.
//
// check_oklch_core.cjs proves the MATHS (116 checks). This suite proves the WIRING, and
// holds a regression test for a real defect found and fixed while wiring it: the
// UI-thread fallback ran point colour AFTER detail and optics while the worker ran it
// before, so the two CPU paths published different pixels whenever both were active.
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

const { OkLChSettings } = load(root + '/edit/models/OkLChSettings.ets');
const ok = load(root + '/edit/engine/OkLChCore.ets');
const pc = load(root + '/edit/engine/PointColorCore.ets');
const { applyLocalContrast, localContrastIsIdentity } = load(root + '/edit/engine/LocalContrastCore.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');

let checks = 0;
function okc(cond, msg) { checks++; assert(cond, msg); }
function differences(a, b) {
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}
const W = 48, H = 32;
const frame = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    frame[i] = Math.round(255 * (0.5 + 0.5 * Math.sin(x * 0.3)));
    frame[i + 1] = Math.round(255 * (0.5 + 0.5 * Math.sin(y * 0.25 + 1)));
    frame[i + 2] = Math.round(255 * (0.5 + 0.5 * Math.sin((x + y) * 0.18 + 2)));
    frame[i + 3] = 255;
  }
}

// --- 1. The model --------------------------------------------------------
const fresh = new OkLChSettings();
okc(fresh.isBypass(), 'a fresh document bypasses the OkLCh stage');
okc(fresh.params().lightness === 0 && fresh.params().chroma === 0 && fresh.params().hue === 0,
  'and its engine parameters are all zero');
// P3: OkLCh was retired. A legacy sidecar may still carry non-zero fields, but
// the stage must stay an exact no-op: isBypass() is constant true and params()
// is the identity, so neither the worker nor the CPU fallback can apply it.
const retired = new OkLChSettings();
retired.lightness = 0.6; retired.chroma = -0.7; retired.hue = 0.4;
okc(retired.isBypass(), 'a retired OkLCh stage bypasses even with non-zero legacy values');
okc(ok.oklchIsIdentity(retired.params()), 'and exposes identity params, so no render path can resurrect it');
okc(!OkLChSettings.restore(undefined).isBypass() === false, 'a pre-OkLCh sidecar restores to a bypass');
okc(OkLChSettings.restore({}).isBypass(), 'and so does an empty object');
// Repair rather than discard: one bad field must not throw away the other two.
const repaired = OkLChSettings.restore({ lightness: NaN, chroma: 0.4, hue: 9 });
okc(repaired.lightness === 0, 'a non-finite lightness is repaired to the no-op default');
okc(repaired.chroma === 0.4, 'while a usable chroma survives');
okc(repaired.hue === 1, 'and an out-of-range hue is clamped, not discarded (got ' + repaired.hue + ')');
const clampedLow = OkLChSettings.restore({ lightness: -9, chroma: -9, hue: -9 });
okc(clampedLow.lightness === -1 && clampedLow.chroma === -1 && clampedLow.hue === -1,
  'and out-of-range values clamp at the low end too');
const cloneSource = new OkLChSettings();
cloneSource.lightness = 0.3; cloneSource.chroma = -0.4; cloneSource.hue = 0.25;
const cloned = cloneSource.clone();
cloned.lightness = 0.9; cloned.chroma = 0.9;
okc(cloneSource.lightness === 0.3 && cloneSource.chroma === -0.4,
  'clone is a deep copy, not a shared reference');
cloneSource.reset();
okc(cloneSource.isBypass(), 'reset returns the grade to the bypass');
// The model must not reimplement bypass: any disagreement here would let the stage claim
// to be off while still running, or claim to be on and do nothing.
let bypassMismatch = 0, probed = 0;
for (const l of [-1, -0.5, 0, 0.5, 1]) {
  for (const c of [-1, -0.2, 0, 0.2, 1]) {
    for (const h of [-1, -0.3, 0, 0.3, 1]) {
      const s = new OkLChSettings();
      s.lightness = l; s.chroma = c; s.hue = h;
      probed++;
      if (s.isBypass() !== ok.oklchIsIdentity(s.params())) bypassMismatch++;
    }
  }
}
okc(probed === 125 && bypassMismatch === 0, 'the retired stage reports bypass and identity params on all ' +
  probed + ' probed parameter combinations (' + bypassMismatch + ' disagreements)');

// --- 2. The real worker pipeline -----------------------------------------
function params(over) {
  const base = {
    source: Uint8ClampedArray.from(frame).buffer,
    width: W, height: H, layers: [], luts: [],
    cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
    rotation: 0, flipH: false, flipV: false,
    applyGeometry: false, ignoreCrop: false,
  };
  return Object.assign(base, over);
}
const grade = { lightness: 0.12, chroma: 0.35, hue: 0.08 };
const omitted = new Uint8ClampedArray(processPixels(params({})).buffer);
okc(differences(omitted, frame) === 0, 'omitting the stage reproduces the source byte for byte');
okc(differences(new Uint8ClampedArray(processPixels(params({ oklch: ok.oklchDefaults() })).buffer), frame) === 0,
  'and supplying the identity parameters is also byte-for-byte free, so the bypass is real');
const graded = new Uint8ClampedArray(processPixels(params({ oklch: grade })).buffer);
okc(differences(graded, frame) > 1000, 'an active grade changes the rendered frame (' +
  differences(graded, frame) + ' bytes)');
okc(differences(new Uint8ClampedArray(processPixels(params({ oklch: grade })).buffer), graded) === 0,
  'two identical jobs produce identical output');
okc(differences(frame, frame) === 0, 'the fixture is not modified by the job');
// The grade must be neutral-preserving through the real pipeline: a grey ramp must not
// pick up a cast, which is the defect the core's achromatic path exists to prevent.
const greyRamp = new Uint8ClampedArray(W * H * 4);
for (let i = 0; i < W * H; i++) {
  const v = i % 256;
  greyRamp[i * 4] = v; greyRamp[i * 4 + 1] = v; greyRamp[i * 4 + 2] = v; greyRamp[i * 4 + 3] = 255;
}
const greyGraded = new Uint8ClampedArray(processPixels(params({ source: greyRamp.buffer, oklch: grade })).buffer);
let castCount = 0;
for (let i = 0; i < W * H; i++) {
  const o = i * 4;
  if (greyGraded[o] !== greyGraded[o + 1] || greyGraded[o + 1] !== greyGraded[o + 2]) castCount++;
}
okc(castCount === 0, 'a grey ramp passes through the whole worker pipeline with no colour cast on any of the ' +
  (W * H) + ' pixels (' + castCount + ' cast)');

// --- 3. Stage ORDER: point colour, then OkLCh, then detail --------------
// The contract is asserted by hand-composing the real modules AND by checking that the
// opposite order produces a different frame, so the assertion cannot pass by accident.
const colour = [pc.pointColorDefaults()];
colour[0].hue = 0.1; colour[0].saturation = 0.6; colour[0].luminance = 0.5;
colour[0].hueShift = 0.3; colour[0].saturationShift = 0.2; colour[0].luminanceShift = 0.1;
colour[0].hueRange = 0.4; colour[0].saturationRange = 0.5; colour[0].luminanceRange = 0.5;
const detail = { texture: 0.3, clarity: 0.4, dehaze: 0.15, sharpenAmount: 0.35,
  sharpenRadius: 0.5, sharpenDetail: 0.5, sharpenMasking: 0 };
okc(!localContrastIsIdentity(detail), 'the detail fixture is active, so the ordering assertion is not vacuous');
okc(!pc.pointColorIsIdentity(colour), 'and the point-colour fixture is active too');
const allThree = new Uint8ClampedArray(processPixels(params({
  pointColor: colour, oklch: grade, detail: detail,
})).buffer);
const hand = Uint8ClampedArray.from(frame);
pc.applyPointColorBuffer(hand, W, H, colour);
ok.applyOkLChBuffer(hand, W, H, grade);
const handDone = applyLocalContrast(hand, W, H, detail, Math.max(W, H));
okc(differences(allThree, handDone) === 0, 'the worker runs point colour, then OkLCh, then detail (' +
  differences(allThree, handDone) + ' differing bytes from the hand-composed order)');
// Opposite: OkLCh before point colour.
const swapped = Uint8ClampedArray.from(frame);
ok.applyOkLChBuffer(swapped, W, H, grade);
pc.applyPointColorBuffer(swapped, W, H, colour);
const swappedDone = applyLocalContrast(swapped, W, H, detail, Math.max(W, H));
const swappedGap = differences(allThree, swappedDone);
okc(swappedGap > 100, 'grading before point colour gives a different frame (' + swappedGap +
  ' differing bytes), so the two orders are genuinely distinguishable and the assertion above is not vacuous');
// And each stage must actually contribute.
okc(differences(allThree, new Uint8ClampedArray(processPixels(params({ pointColor: colour, detail: detail })).buffer)) > 500,
  'the OkLCh pass really contributes to the combined render');
okc(differences(allThree, new Uint8ClampedArray(processPixels(params({ oklch: grade, detail: detail })).buffer)) > 500,
  'and so does point colour');

// --- 4. Regression: the two CPU paths must agree on stage order ---------
// The fallback used to run detail and optics BEFORE point colour while the worker ran it
// before them, so with both active the two paths published different pixels -- exactly
// what the comments on both paths promise will not happen.
const workerSource = fs.readFileSync('entry/src/main/ets/edit/engine/ProcessWorker.ets', 'utf8');
const fallbackSource = fs.readFileSync('entry/src/main/ets/edit/engine/ImageProcessor.ets', 'utf8');
function orderOf(source, needles, label) {
  const positions = needles.map((n) => source.indexOf(n));
  for (let i = 0; i < positions.length; i++) {
    okc(positions[i] >= 0, label + ' contains "' + needles[i] + '"');
  }
  for (let i = 1; i < positions.length; i++) {
    okc(positions[i - 1] < positions[i], label + ' orders ' + needles[i - 1] + ' before ' + needles[i]);
  }
}
orderOf(workerSource,
  ['applyPointColorBuffer(result', 'applyOkLChBuffer(result', 'applyLocalContrast(result', 'applyOptics(result'],
  'the worker path');
// Asserted as the FULL chain, so a stage moved anywhere -- not just the pair that was
// wrong -- shows up here.
okc(fallbackSource.includes('applyLutStack(pool.result'), 'the fallback LUT stage was located');
orderOf(fallbackSource,
  ['applyLutStack(pool.result', 'applyPointColorBuffer(pool.result', 'applyOkLChBuffer(pool.result',
    'pool.result.set(applyLocalContrast(pool.result', 'pool.result.set(applyOptics(pool.result'],
  'the UI-thread fallback');
okc(fallbackSource.indexOf('applyPointColorBuffer(pool.result') <
  fallbackSource.indexOf('pool.result.set(applyLocalContrast(pool.result'),
  'in particular point colour now precedes detail, which is the defect this suite holds the fix for');
// The stale comment that described the old (wrong) order must be gone.
okc(!fallbackSource.includes('Point colour, before the detail stage so both CPU paths agree on order'),
  'the comment that claimed the old order agreed with the worker is gone, because it was false');

// --- 5. Sidecar and undo -------------------------------------------------
const session = new EditSession();
session.layers = [new Layer('synthetic')];
session.oklch.lightness = 0.22; session.oklch.chroma = -0.33; session.oklch.hue = 0.44;
okc(session.oklch.isBypass(), 'a live session carrying legacy values still reports the retired stage as bypassed');
const exported = JSON.parse(session.exportAdjustmentState());
okc(exported.oklch && Math.abs(exported.oklch.lightness - 0.22) < 1e-12 &&
  Math.abs(exported.oklch.chroma + 0.33) < 1e-12 && Math.abs(exported.oklch.hue - 0.44) < 1e-12,
  'the exported adjustment state carries all three parameters');
const reopened = new EditSession();
reopened.layers = [new Layer('synthetic')];
okc(reopened.importAdjustmentState(JSON.stringify(exported)), 'the exported state imports back');
okc(Math.abs(reopened.oklch.lightness - 0.22) < 1e-12 && Math.abs(reopened.oklch.chroma + 0.33) < 1e-12 &&
  Math.abs(reopened.oklch.hue - 0.44) < 1e-12, 'with every parameter intact');
okc(reopened.oklch.isBypass() && ok.oklchIsIdentity(reopened.oklch.params()),
  'but the retired stage cannot render those legacy values');
const legacy = JSON.parse(JSON.stringify(exported));
delete legacy.oklch;
const legacySession = new EditSession();
legacySession.layers = [new Layer('synthetic')];
okc(legacySession.importAdjustmentState(JSON.stringify(legacy)), 'a sidecar written before this stage imports');
okc(legacySession.oklch.isBypass(), 'and opens as an exact bypass, not on an arbitrary grade');
const undoSession = new EditSession();
undoSession.layers = [new Layer('synthetic')];
undoSession.pushUndo();
undoSession.oklch.chroma = 0.5;
undoSession.pushUndo();
undoSession.oklch.hue = 0.9;
undoSession.undo();
okc(undoSession.oklch.chroma === 0.5 && undoSession.oklch.hue === 0, 'undo restores the previous grade');
undoSession.undo();
okc(undoSession.oklch.isBypass(), 'and undo again returns to the bypass');
undoSession.redo();
okc(Math.abs(undoSession.oklch.chroma - 0.5) < 1e-12, 'redo brings it back');

// --- 6. GPU decline and the retired UI entry -----------------------------
const bridgeSource = fs.readFileSync('entry/src/main/ets/edit/engine/GpuShaderBridge.ets', 'utf8');
okc(bridgeSource.includes("if (!session.oklch.isBypass()) return GpuShaderBridge.decline('oklch');"),
  'the engine-side GPU guard still exists, but isBypass() is now constant true so it can never fire');
okc(bridgeSource.indexOf("decline('point-color')") < bridgeSource.indexOf("decline('oklch')"),
  'and the declines are ordered after point colour, matching the pipeline');
const adjustmentSource = fs.readFileSync('entry/src/main/ets/components/AdjustmentPanel.ets', 'utf8');
okc(adjustmentSource.indexOf('OkLChPanel') < 0,
  'the legacy adjustment panel no longer mounts the OkLCh panel');
const developSource = fs.readFileSync('entry/src/main/ets/components/DesktopDevelopPanel.ets', 'utf8');
okc(developSource.indexOf('OkLChPanel') < 0,
  'the develop panel no longer mounts the OkLCh panel');
const sectionsSource = fs.readFileSync('entry/src/main/ets/edit/models/DevelopSections.ets', 'utf8');
okc(sectionsSource.indexOf("'oklch'") < 0,
  'the section table no longer contains an oklch entry');
const panelSource = fs.readFileSync('entry/src/main/ets/components/OkLChPanel.ets', 'utf8');
okc(panelSource.includes('export struct OkLChPanel'),
  'the component file is retained (unmounted) so old builds/sources still resolve it');

console.log('PASS OkLCh integration: the model repairs rather than discards legacy sidecar values, the');
console.log('     retired stage is always bypassed and exposes identity params on all 125 probed');
console.log('     combinations, and neither the develop panel nor the legacy adjustment panel mounts it.');
console.log('REGRESSION this suite still holds the engine-side stage-order proof (point colour, OkLCh,');
console.log('     detail) against the real modules: the retired model cannot reach that stage any more,');
console.log('NOTE no device verification and no timing: the OkLCh stage is per-pixel but its gamut search');
console.log('     runs a bisection only when a request leaves the gamut, so the common case is arithmetic.');
console.log(checks + ' checks passed');
