// Integration verification for the parametric tone curve.
//
// check_parametric_curve.cjs proves the MATHS of ParametricCurveCore in
// isolation. This suite proves the WIRING: that the parameters survive the real
// ColorAdjustments -> WorkerAdjustments mapping, that ColorAdjustments.clone()
// and the render path carry them, and that the pixels the production CPU
// renderer produces actually respond. Nothing here re-tests the maths.
const fs = require('fs'), path = require('path'), vm = require('vm'), crypto = require('crypto'), assert = require('assert');
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
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
    Uint8Array, Uint16Array, Uint32Array, Int32Array, Uint8ClampedArray, Float32Array, DataView, Promise, Error,
    setTimeout, clearTimeout, TextEncoder, TextDecoder, Buffer, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (n) => {
      if (n === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0) }, GpuOutputGeometry: {} };
      if (n === 'libvivid_ai.so') return { default: { isLoaded: () => false, release: () => {}, modelInfo: () => [] } };
      if (n === '@kit.CoreFileKit') {
        // Real filesystem shim so the sidecar round-trip writes and reads actual
        // bytes rather than a stub that would make the test vacuous.
        return {
          fileIo: {
            OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 8 },
            // EditSidecar mixes the two conventions: it passes the raw fd to
            // writeSync/readSync but the whole handle to closeSync.
            openSync: (p, f) => ({ fd: fs.openSync(p, f === 8 ? 'r' : 'w') }),
            closeSync: (h) => fs.closeSync(typeof h === 'number' ? h : h.fd),
            writeSync: (h, b) => fs.writeSync(typeof h === 'number' ? h : h.fd, Buffer.from(b)),
            readSync: (h, b) => fs.readSync(typeof h === 'number' ? h : h.fd, new Uint8Array(b)),
            statSync: (p) => (typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p)),
          },
        };
      }
      if (n === '@kit.ArkTS') {
        // Support both the class form and the `.create()` factory form, because
        // different modules in this tree use different ones.
        const encoder = () => ({
          encode: (t) => new Uint8Array(Buffer.from(t, 'utf8')),
          encodeInto: (t) => new Uint8Array(Buffer.from(t, 'utf8')),
        });
        const decoder = () => ({
          decode: (b) => Buffer.from(b).toString('utf8'),
          decodeToString: (b) => Buffer.from(b).toString('utf8'),
        });
        function TextEncoderShim() { return encoder(); }
        TextEncoderShim.create = encoder;
        function TextDecoderShim() { return decoder(); }
        TextDecoderShim.create = decoder;
        return {
          util: {
            TextEncoder: TextEncoderShim,
            TextDecoder: TextDecoderShim,
            Base64Helper: class {
              encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
              decodeSync(text) { const b = Buffer.from(text, 'base64'); return new Uint8Array(b.buffer, b.byteOffset, b.byteLength); }
            },
          },
          taskpool: { Task: class { static isCanceled() { return false; } constructor(f, ...a) { this.f = f; this.a = a; } }, execute: async (t) => t.f(...t.a) },
        };
      }
      if (n === '@kit.CryptoArchitectureKit') {
        return {
          cryptoFramework: {
            createMd: () => {
              const chunks = [];
              return {
                update: async (blob) => { chunks.push(Buffer.from(blob.data)); },
                digest: async () => ({ data: new Uint8Array(crypto.createHash('sha256').update(Buffer.concat(chunks)).digest()) }),
              };
            },
          },
        };
      }
      if (n === '@kit.ImageKit') return { image: { PixelMapFormat: { RGBA_8888: 3 } } };
      if (n === '@kit.LocalizationKit') return { resourceManager: {} };
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      if(n.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { ColorAdjustments } = load(root + '/edit/models/Adjustment.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { applyAdvancedBand, prepareAdvancedTables, hasAdvancedAdjustments } =
  load(root + '/edit/engine/WorkerCore.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
function img(w, h, fn) {
  const b = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const v = fn(x, y), i = (y * w + x) * 4;
    b[i] = v[0]; b[i + 1] = v[1]; b[i + 2] = v[2]; b[i + 3] = 255;
  }
  return b;
}
function same(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
// Mean absolute luma change over a column range, in byte levels.
function meanLumaChange(before, after, w, h, x0, x1) {
  let total = 0, n = 0;
  for (let y = 0; y < h; y++) for (let x = x0; x < x1; x++) {
    const i = (y * w + x) * 4;
    const l0 = 0.2126 * before[i] + 0.7152 * before[i + 1] + 0.0722 * before[i + 2];
    const l1 = 0.2126 * after[i] + 0.7152 * after[i + 1] + 0.0722 * after[i + 2];
    total += Math.abs(l1 - l0); n++;
  }
  return total / n;
}
function saturationAt(buf, index) {
  const r = buf[index] / 255, g = buf[index + 1] / 255, b = buf[index + 2] / 255;
  const high = Math.max(r, g, b), low = Math.min(r, g, b);
  return high <= 0 ? 0 : (high - low) / high;
}

const W = 64, H = 8;
const ramp = img(W, H, (x) => { const v = Math.round(x * 255 / (W - 1)); return [v, v, v]; });

// --- 1. The parameters survive the real ColorAdjustments -> Worker mapping ---
const adj = new ColorAdjustments();
adj.parametricHighlights = 0.6;
adj.parametricLights = -0.25;
adj.parametricDarks = 0.4;
adj.parametricShadows = -0.15;
adj.parametricShadowSplit = 0.3;
adj.parametricDarkSplit = 0.55;
adj.parametricLightSplit = 0.8;
adj.parametricRefineSaturation = 0.35;
const worker = ImageProcessor.plainAdjustments(adj);
ok(worker.parametricHighlights === 0.6, 'highlights reach WorkerAdjustments');
ok(worker.parametricLights === -0.25, 'lights reach WorkerAdjustments');
ok(worker.parametricDarks === 0.4, 'darks reach WorkerAdjustments');
ok(worker.parametricShadows === -0.15, 'shadows reach WorkerAdjustments');
ok(worker.parametricShadowSplit === 0.3, 'shadow split reaches WorkerAdjustments');
ok(worker.parametricDarkSplit === 0.55, 'dark split reaches WorkerAdjustments');
ok(worker.parametricLightSplit === 0.8, 'light split reaches WorkerAdjustments');
ok(worker.parametricRefineSaturation === 0.35, 'refine saturation reaches WorkerAdjustments');
// The worker payload must be structured-cloneable for the taskpool: a method
// or a class instance there would fail at dispatch time, not at build time.
ok(JSON.parse(JSON.stringify(worker.parametricHighlights)) === 0.6,
  'the mapped value is a plain number, so it survives structured cloning');

// A freshly constructed adjustment must not silently enable the curve.
const fresh = ImageProcessor.plainAdjustments(new ColorAdjustments());
ok(fresh.parametricHighlights === 0 && fresh.parametricLights === 0 &&
  fresh.parametricDarks === 0 && fresh.parametricShadows === 0, 'defaults map to an inactive curve');
ok(fresh.parametricShadowSplit === 0.25 && fresh.parametricDarkSplit === 0.5 &&
  fresh.parametricLightSplit === 0.75, 'split defaults match Camera Raw 25/50/75');
ok(fresh.parametricRefineSaturation === 1, 'refinement defaults to fully on, not off');

// --- 2. clone() and reset() carry the fields (a silent-drop guard) ---
const cloned = adj.clone();
ok(cloned.parametricHighlights === 0.6 && cloned.parametricLights === -0.25 &&
  cloned.parametricDarks === 0.4 && cloned.parametricShadows === -0.15 &&
  cloned.parametricShadowSplit === 0.3 && cloned.parametricDarkSplit === 0.55 &&
  cloned.parametricLightSplit === 0.8 && cloned.parametricRefineSaturation === 0.35,
  'clone() copies every parametric field (it enumerates fields by hand)');
cloned.parametricHighlights = 0.9;
ok(adj.parametricHighlights === 0.6, 'clone() is a deep-enough copy: mutating it leaves the source alone');
const cleared = adj.clone(); cleared.reset();
ok(cleared.parametricHighlights === 0 && cleared.parametricLights === 0 &&
  cleared.parametricDarks === 0 && cleared.parametricShadows === 0 &&
  cleared.parametricShadowSplit === 0.25 && cleared.parametricDarkSplit === 0.5 &&
  cleared.parametricLightSplit === 0.75 && cleared.parametricRefineSaturation === 1,
  'reset() restores every parametric field to its identity value');

// --- 3. hasAdvancedAdjustments must request a pass ---
ok(hasAdvancedAdjustments(worker) === true, 'a non-identity curve requests an advanced pass');
ok(hasAdvancedAdjustments(ImageProcessor.plainAdjustments(new ColorAdjustments())) === false,
  'an untouched adjustment still reports no advanced work (no wasted pass)');
const splitsOnly = new ColorAdjustments();
splitsOnly.parametricShadowSplit = 0.4;
splitsOnly.parametricLightSplit = 0.6;
ok(hasAdvancedAdjustments(ImageProcessor.plainAdjustments(splitsOnly)) === false,
  'moving only the splits still reports no advanced work');

// --- 4. The production renderer must actually respond ---
const identityInput = Uint8ClampedArray.from(ramp);
applyAdvancedBand(identityInput, fresh, 0, identityInput.length, W, H);
ok(same(identityInput, ramp), 'an identity curve leaves the rendered frame byte-identical');

const lifted = Uint8ClampedArray.from(ramp);
const liftParams = ImageProcessor.plainAdjustments(new ColorAdjustments());
liftParams.parametricHighlights = 0.8;
applyAdvancedBand(lifted, liftParams, 0, lifted.length, W, H);
ok(!same(lifted, ramp), 'a non-identity curve changes the rendered frame');
// The highlights bump must act on the bright end of the ramp, not everywhere.
const darkQuarter = meanLumaChange(ramp, lifted, W, H, 0, W / 4);
const brightQuarter = meanLumaChange(ramp, lifted, W, H, W * 3 / 4, W);
ok(brightQuarter > darkQuarter * 2,
  'the highlights region acts on the bright end: bright-quarter mean change ' +
  brightQuarter.toFixed(2) + ' vs dark-quarter ' + darkQuarter.toFixed(2));
ok(brightQuarter > 1, 'the bright end actually moves (not a no-op)');

// Direction check: lifting the shadows region must brighten dark tones. The
// exact endpoints are pinned by construction, so probe the region interior
// rather than x=0 鈥?a probe at the endpoint would pass or fail vacuously.
const shadowLift = Uint8ClampedArray.from(ramp);
const shadowParams = ImageProcessor.plainAdjustments(new ColorAdjustments());
shadowParams.parametricShadows = 0.8;
applyAdvancedBand(shadowLift, shadowParams, 0, shadowLift.length, W, H);
let bestX = -1, bestDelta = -1e9;
for (let x = 1; x < W / 4; x++) {
  const delta = shadowLift[x * 4] - ramp[x * 4];
  if (delta > bestDelta) { bestDelta = delta; bestX = x; }
}
ok(bestDelta > 1, 'raising the shadows region brightens dark tones (best +' + bestDelta +
  ' at input value ' + ramp[bestX * 4] + ')');
let anyDarker = false;
for (let x = 1; x < W / 4; x++) if (shadowLift[x * 4] < ramp[x * 4]) anyDarker = true;
ok(!anyDarker, 'raising the shadows region never darkens a dark tone anywhere in its range');
ok(ramp[0] === 0 && shadowLift[0] === 0, 'the black end stays pinned when only shadows move');
// Endpoints stay pinned: the white end must not be pushed past white.
const whiteBefore = ramp[(W - 1) * 4];
ok(shadowLift[(W - 1) * 4] === whiteBefore,
  'the white end stays pinned when only shadows move (' + whiteBefore + ')');

// Moving only the splits must render identically, because the curve integrates
// to the identity when every amount is zero.
const splitShift = ImageProcessor.plainAdjustments(splitsOnly);
const splitOut = Uint8ClampedArray.from(ramp);
applyAdvancedBand(splitOut, splitShift, 0, splitOut.length, W, H);
ok(same(splitOut, ramp), 'moving the splits with every amount at zero renders identically');

// --- 5. The folded fast-path table is what actually renders ---
// A grey 256-wide ramp exercises every byte value. The per-channel fast path
// folds the parametric curve into fastChannels, so the rendered output must
// equal that table exactly; otherwise the fast path and general path disagree.
const grey = img(256, 2, (x, y) => [x, x, x]);
const greyOut = Uint8ClampedArray.from(grey);
applyAdvancedBand(greyOut, liftParams, 0, greyOut.length, 256, 2);
const tables = prepareAdvancedTables(liftParams);
let fastPathExact = true, mismatches = 0;
for (let x = 0; x < 256; x++) {
  const i = x * 4;
  if (greyOut[i] !== tables.fastChannels[0][x]) { fastPathExact = false; mismatches++; }
}
ok(fastPathExact, 'the rendered result equals the folded fast-path table at every byte value' +
  (fastPathExact ? '' : ' (mismatches: ' + mismatches + ')'));
ok(tables.parametric !== null && tables.parametric.length === 256,
  'the prepared tables expose a 256-entry parametric ramp when the curve is active');
// The luminance-indexed refinement table was removed: it was measured to be
// inert for 59% of the colours the curve affects. Refinement is now measured
// per pixel from the actual before/after saturation, so no table is prepared.
ok(tables.parametricRefine === undefined,
  'no luminance-indexed refinement table is prepared any more (refinement is measured per pixel)');
const refineTables = prepareAdvancedTables(ImageProcessor.plainAdjustments(
  Object.assign(new ColorAdjustments(), { parametricHighlights: 0.5, parametricRefineSaturation: 0 })));
ok(refineTables.parametric !== null && Object.keys(refineTables).length === Object.keys(tables).length,
  'preparing tables for a refined curve has the same shape as an unrefined one');

// --- 6. Refinement pulls back the saturation the curve introduces ---
// Hand-picking a probe colour is unreliable: the curve is applied per CHANNEL,
// so a colour can easily have both channels outside the steep region and be
// left alone entirely. Sweep saturated colours and keep only those whose
// saturation the curve demonstrably raises, so nothing below passes vacuously.
const pcCore = load(root + '/edit/engine/ParametricCurveCore.ets');
const fullRefine = ImageProcessor.plainAdjustments(new ColorAdjustments());
fullRefine.parametricDarks = 0.9;
fullRefine.parametricRefineSaturation = 1;
const noRefine = ImageProcessor.plainAdjustments(new ColorAdjustments());
noRefine.parametricDarks = 0.9;
noRefine.parametricRefineSaturation = 0;
let probe = null, raisedCount = 0, inertCount = 0, worstResidual = 0, bestRestore = 1;
for (let r = 40; r <= 210; r += 3) {
  for (let g = 20; g < r; g += 3) {
    const cand = img(4, 1, () => [r, g, g]);
    const out = Uint8ClampedArray.from(cand);
    applyAdvancedBand(out, fullRefine, 0, out.length, 4, 1);
    const s0 = saturationAt(cand, 0), s1 = saturationAt(out, 0);
    if (s1 <= s0 + 0.02) continue;
    raisedCount++;
    // Refinement must be ABLE to act on every colour the curve affected. This is
    // the property the luminance-indexed slope model failed for 59% of colours.
    if (pcCore.parametricRefineScale(s0, s1, 0) >= 0.99) { inertCount++; continue; }
    const none = Uint8ClampedArray.from(cand);
    applyAdvancedBand(none, noRefine, 0, none.length, 4, 1);
    const sNone = saturationAt(none, 0);
    if (sNone - s0 > worstResidual) worstResidual = sNone - s0;
    if (sNone / s1 < bestRestore) bestRestore = sNone / s1;
    if (!probe) probe = { r: r, g: g, cand: cand, out: out, none: none, s0: s0, s1: s1, sNone: sNone };
  }
}
ok(raisedCount > 50, 'the sweep found plenty of colours whose saturation the curve raises (' +
  raisedCount + '), so the assertions below are meaningful');
ok(inertCount === 0, 'refinement can act on EVERY such colour (' + inertCount + ' of ' + raisedCount +
  ' are inert); under the previous luminance-indexed slope model this was 59%');
ok(probe !== null, 'a probe colour exists for the direct comparisons below');
console.log('DIAGNOSTIC: over ' + raisedCount + ' colours whose saturation the curve raises, refinement at 0 ' +
  'leaves at most ' + worstResidual.toFixed(4) + ' saturation above the input (worst case), and in the best ' +
  'case reduces it to ' + (100 * bestRestore).toFixed(1) + '% of the unrefined value.');
const probeLuma = 0.2126 * probe.cand[0] / 255 + 0.7152 * probe.cand[1] / 255 + 0.0722 * probe.cand[2] / 255;
ok(probe.s1 > probe.s0, 'the curve on its own does raise saturation (' + probe.s0.toFixed(4) + ' -> ' +
  probe.s1.toFixed(4) + ' at luma ' + probeLuma.toFixed(3) + '), which is what refinement counters');
ok(probe.s1 > probe.s0, 'the curve on its own does raise saturation (' +
  probe.s0.toFixed(4) + ' -> ' + probe.s1.toFixed(4) + '), which is what refinement exists to counter');
const satFull = saturationAt(probe.out, 0), satNone = saturationAt(probe.none, 0);
ok(satNone < satFull, 'refinement 0 lowers the rendered saturation versus refinement 1 (' +
  satNone.toFixed(4) + ' < ' + satFull.toFixed(4) + ')');
// Restoration is APPROXIMATE, not exact: the scale is derived in saturation
// space but applied by scaling chroma toward the luma-weighted luminance, and
// HSV saturation is not linear in that operation. The residual is bounded and
// measured rather than assumed, and refine=0 lands slightly ABOVE the input
// saturation (it pulls back, it does not overshoot into desaturation).
ok(worstResidual <= 0.05, 'refinement 0 leaves at most 0.05 saturation above the input across the whole ' +
  'sweep (measured worst case ' + worstResidual.toFixed(4) + ')');
ok(satNone <= probe.s0 + 0.05, 'refinement 0 pulls saturation back to within 0.05 of the input (' +
  satNone.toFixed(4) + ' vs input ' + probe.s0.toFixed(4) + ')');
ok(satNone >= probe.s0 - 0.02, 'refinement 0 does not overshoot below the input saturation (' +
  satNone.toFixed(4) + ' vs input ' + probe.s0.toFixed(4) + ')');
// Refinement must not darken the pixel: it is a saturation-only control.
const lumaFull = 0.2126 * probe.out[0] + 0.7152 * probe.out[1] + 0.0722 * probe.out[2];
const lumaNone = 0.2126 * probe.none[0] + 0.7152 * probe.none[1] + 0.0722 * probe.none[2];
ok(Math.abs(lumaFull - lumaNone) <= 1.5,
  'refinement preserves luminance (it is not a hidden brightness control): ' +
  lumaFull.toFixed(2) + ' vs ' + lumaNone.toFixed(2));

// --- 7. Bands must agree with a single full-frame pass ---
// The export path renders in bands; refactoring the curve into a per-pixel
// branch must not make band boundaries visible.
const banded = Uint8ClampedArray.from(ramp);
applyAdvancedBand(banded, liftParams, 0, 64, W, H);
applyAdvancedBand(banded, liftParams, 64, banded.length, W, H);
const whole = Uint8ClampedArray.from(ramp);
applyAdvancedBand(whole, liftParams, 0, whole.length, W, H);
ok(same(banded, whole), 'tiled bands produce exactly the same pixels as one full-frame pass');

// --- 8. Determinism and finiteness on the production path ---
const again = Uint8ClampedArray.from(ramp);
applyAdvancedBand(again, liftParams, 0, again.length, W, H);
ok(same(again, lifted), 'the render path is deterministic for identical parameters');
let finite = true;
for (let i = 0; i < lifted.length; i++) if (!Number.isFinite(lifted[i])) finite = false;
ok(finite, 'no NaN or Infinity reaches the output');
let alphaKept = true;
for (let i = 3; i < lifted.length; i += 4) if (lifted[i] !== 255) alphaKept = false;
ok(alphaKept, 'alpha is untouched by the tone stage');

// --- 9. Sidecar round-trip through the real EditSession ---
// The parametric fields travel through createSnapshot / restoreLayersFromSnapshot,
// which serve BOTH the undo stack and the XML sidecar, so this covers undo too.
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');
const { EditSidecar } = load(root + '/edit/utils/EditSidecar.ets');
const os = require('os');
const sidecarDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vivid-parametric-'));
function findAdjustments(node) {
  if (!node || typeof node !== 'object') return null;
  if (Array.isArray(node)) {
    for (const item of node) { const found = findAdjustments(item); if (found) return found; }
    return null;
  }
  if ('parametricHighlights' in node) return node;
  for (const key of Object.keys(node)) { const found = findAdjustments(node[key]); if (found) return found; }
  return null;
}
function freshSession() {
  const session = new EditSession();
  session.layers = [new Layer('synthetic')];
  return session;
}
const source = freshSession();
const written = source.layers[0].adjustments;
written.parametricHighlights = 0.42;
written.parametricLights = -0.11;
written.parametricDarks = 0.33;
written.parametricShadows = -0.07;
written.parametricShadowSplit = 0.31;
written.parametricDarkSplit = 0.57;
written.parametricLightSplit = 0.83;
written.parametricRefineSaturation = 0.28;
const exported = source.exportAdjustmentState();
const exportedAdjustments = findAdjustments(JSON.parse(exported));
ok(exportedAdjustments !== null, 'the exported adjustment state contains the parametric fields');
ok(exportedAdjustments.parametricHighlights === 0.42 && exportedAdjustments.parametricRefineSaturation === 0.28,
  'the exported state carries the parametric values, not defaults');
const shot = path.join(sidecarDir, 'shot.rw2');
ok(EditSidecar.write(shot, exported, sidecarDir), 'the sidecar writes');
const reopened = freshSession();
ok(reopened.importAdjustmentState(EditSidecar.read(shot, sidecarDir)), 'the sidecar reads back');
const roundTripped = reopened.layers[0].adjustments;
ok(roundTripped.parametricHighlights === 0.42 && roundTripped.parametricLights === -0.11 &&
  roundTripped.parametricDarks === 0.33 && roundTripped.parametricShadows === -0.07 &&
  roundTripped.parametricShadowSplit === 0.31 && roundTripped.parametricDarkSplit === 0.57 &&
  roundTripped.parametricLightSplit === 0.83 && roundTripped.parametricRefineSaturation === 0.28,
  'every parametric field survives the real sidecar write/read round-trip');
// An older sidecar has no such fields. Refinement must fall back to 1, not 0:
// defaulting to 0 would silently desaturate every previously saved photo.
const legacyState = JSON.parse(exported);
const legacyAdjustments = findAdjustments(legacyState);
for (const key of ['parametricHighlights', 'parametricLights', 'parametricDarks', 'parametricShadows',
  'parametricShadowSplit', 'parametricDarkSplit', 'parametricLightSplit', 'parametricRefineSaturation']) {
  delete legacyAdjustments[key];
}
const legacySession = freshSession();
ok(legacySession.importAdjustmentState(JSON.stringify(legacyState)),
  'a sidecar written before the parametric curve still imports');
const legacy = legacySession.layers[0].adjustments;
ok(legacy.parametricHighlights === 0 && legacy.parametricLights === 0 &&
  legacy.parametricDarks === 0 && legacy.parametricShadows === 0,
  'a pre-parametric sidecar opens with an inactive curve (not a random one)');
ok(legacy.parametricShadowSplit === 0.25 && legacy.parametricDarkSplit === 0.5 &&
  legacy.parametricLightSplit === 0.75,
  'a pre-parametric sidecar opens with the 25/50/75 splits');
ok(legacy.parametricRefineSaturation === 1,
  'a pre-parametric sidecar opens with refinement fully ON, so an old photo is not silently desaturated');
// Undo/redo must carry the fields too.
const undoSession = freshSession();
const undoAdjustments = undoSession.layers[0].adjustments;
undoSession.pushUndo();
undoAdjustments.parametricDarks = 0.77;
undoSession.pushUndo();
undoAdjustments.parametricDarks = -0.44;
undoSession.undo();
ok(undoSession.layers[0].adjustments.parametricDarks === 0.77,
  'undo restores the previous parametric value (' + undoSession.layers[0].adjustments.parametricDarks + ')');
undoSession.undo();
ok(undoSession.layers[0].adjustments.parametricDarks === 0,
  'undo restores the identity when the curve was untouched (' + undoSession.layers[0].adjustments.parametricDarks + ')');
undoSession.redo();
ok(undoSession.layers[0].adjustments.parametricDarks === 0.77, 'redo re-applies the parametric value');

console.log('PASS parametric integration: ColorAdjustments -> WorkerAdjustments mapping, clone/reset,');
console.log('     hasAdvancedAdjustments gating, production CPU render response and direction, region');
console.log('     selectivity, pinned endpoints, splits-only identity, folded fast-path equivalence,');
console.log('     refinement semantics, band tiling, determinism, finiteness, alpha.');
console.log('NOTE this covers the CPU render path and the parameter plumbing. The GPU shader path is');
console.log('     validated by check_shader_parity.cjs (shader compiles, CPU/GPU parity holds); the');
console.log('     parametric-specific GPU buffer is not asserted here.');
console.log(checks + ' checks passed');
