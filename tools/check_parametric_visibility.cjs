// F2 — a parametric tone curve on a layer that cannot reach the frame must not
// drag the whole frame back to the CPU.
//
// `parametricIsIdentity` walked every layer and every mask layer and never looked
// at `visible`, `opacity`, `enabled` or `components.length`, while `buildPasses`
// skips exactly those. A curve stored on a hidden layer therefore made the GPU
// decline('parametric-curve') for a setting with no visible effect.
//
// Each case below flips ONE visibility field on the same curve and asserts that
// the GPU pass list changes, so the test proves the filter rather than the
// presence of the check.
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
const { MaskLayer, MaskComponent, MaskComponentType } = load(root + '/edit/models/Mask.ets');
const { GpuShaderBridge } = load(root + '/edit/engine/GpuShaderBridge.ets');

const W = 32, H = 24;
function visibleLayer() {
  const layer = new Layer('visible');
  layer.adjustments.exposure = 0.3;
  return layer;
}
function curvedLayer(visible) {
  const layer = new Layer('curved');
  layer.visible = visible;
  layer.adjustments.parametricHighlights = 0.4;
  return layer;
}
function sessionWith(...layers) {
  const session = new EditSession();
  session.layers = layers;
  return session;
}
function passes(session) { return GpuShaderBridge.buildPasses(session, W, H, true, true); }

let checks = 0;
function ok(condition, message) { checks++; assert(condition, message); }

// --- the curve is real -------------------------------------------------------
logLines.length = 0;
const active = sessionWith(visibleLayer(), curvedLayer(true));
ok(passes(active) === null, 'a visible layer\'s parametric curve declines the GPU');
ok(logLines.some((line) => line.includes('parametric-curve')),
  'and the decline reason names the parametric curve: ' + logLines.join(' | '));

// --- a hidden layer cannot reach the frame -----------------------------------
logLines.length = 0;
const hidden = sessionWith(visibleLayer(), curvedLayer(false));
const hiddenPasses = passes(hidden);
ok(Array.isArray(hiddenPasses) && hiddenPasses.length > 0,
  'the SAME curve on a hidden layer must not decline the GPU');
ok(!logLines.some((line) => line.includes('parametric-curve')),
  'a hidden layer must not even report a parametric-curve decline');

// --- zero-opacity layer ------------------------------------------------------
logLines.length = 0;
const transparent = curvedLayer(true);
transparent.opacity = 0;
const zeroOpacityPasses = passes(sessionWith(visibleLayer(), transparent));
ok(Array.isArray(zeroOpacityPasses) && zeroOpacityPasses.length > 0,
  'a zero-opacity layer\'s curve must not decline the GPU');

// --- mask-layer gate, one field at a time ------------------------------------
function maskedSession(mutate) {
  const layer = new Layer('masked');
  layer.adjustments.exposure = 0.2;
  const local = new MaskLayer('local');
  local.components = [new MaskComponent(MaskComponentType.BRUSH)];
  local.adjustments.parametricShadows = 0.5;
  mutate(local);
  layer.maskLayers = [local];
  return sessionWith(layer);
}
const localActive = maskedSession(() => {});
ok(passes(localActive) === null, 'an enabled, visible mask layer\'s curve declines the GPU');

const localDisabled = maskedSession((local) => { local.enabled = false; });
ok(Array.isArray(passes(localDisabled)) && passes(localDisabled).length > 0,
  'a disabled mask layer\'s curve must not decline the GPU');
const localHidden = maskedSession((local) => { local.visible = false; });
ok(Array.isArray(passes(localHidden)) && passes(localHidden).length > 0,
  'a hidden mask layer\'s curve must not decline the GPU');
const localTransparent = maskedSession((local) => { local.opacity = 0; });
ok(Array.isArray(passes(localTransparent)) && passes(localTransparent).length > 0,
  'a zero-opacity mask layer\'s curve must not decline the GPU');
const localEmpty = maskedSession((local) => { local.components = []; });
ok(Array.isArray(passes(localEmpty)) && passes(localEmpty).length > 0,
  'a mask layer with no components is skipped by buildPasses and must not decline the GPU');

// --- the skip list must match buildPasses exactly ---------------------------
// A hidden layer with an unsupported stage would be skipped by both; the point
// here is that the two predicates agree on visibility, so check the mirror: a
// visible mask layer with the curve DOES decline while each skip field does not.
ok(passes(active) === null && passes(hidden) !== null,
  'the only difference between the two sessions is layer.visible');

console.log('PASS parametric visibility: the parametric-curve decline fires for a curve that can reach the');
console.log('     frame (visible layer, and an enabled/visible/opaque mask layer with components) and does not');
console.log('     fire for a hidden layer, a zero-opacity layer, or a disabled/hidden/zero-opacity/empty mask');
console.log('     layer — the exact skips buildPasses makes. ' + checks + ' checks.');
