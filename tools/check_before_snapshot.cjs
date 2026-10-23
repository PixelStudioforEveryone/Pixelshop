// F6 — "hold to see the original" must show the capture as framed, with no grade.
//
// The `before` branch cleared layers/denoise/retouch/LUT/viewport but not the
// document-level stages, so the "original" still showed clarity, black-and-white,
// point colour and lens correction. Those five are reset here; crop, rotation,
// flips and manual geometry stay because they are framing, not grading.
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
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set,
    ArrayBuffer, Uint8Array, Uint8ClampedArray, Uint32Array, Float32Array, Promise, Error,
    setTimeout, clearTimeout, setInterval, clearInterval, Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (name) => {
      if (name === 'libvivid_gpu.so') return { default: {}, GpuOutputGeometry: {} };
      if (name === '@kit.ArkTS') return { taskpool: { Task: class { static isCanceled() { return false; } constructor(f, ...a) { this.f = f; this.a = a; } }, execute: async (t) => t.f(...t.a) } };
      if (name === 'libvivid_pixels.so') return { default: { rasterizeLinear: (w, h) => new ArrayBuffer(w * h), rasterizeRadial: (w, h) => new ArrayBuffer(w * h), remapGeometry: (b, w, h) => new ArrayBuffer(w * h * 4), composeInto() {}, invertOpacity() {}, sampleBitmap() {} } };
      if (name.startsWith('@kit.')) return { hilog: { info() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');

const session = new EditSession();
session.ensureBaseLayer();
session.layers[0].adjustments.exposure = 0.4;
session.denoise.luminance = 0.6;
session.denoise.color = 0.3;
session.detail.clarity = 0.5;
session.detail.texture = 0.25;
session.detail.dehaze = 0.3;
session.detail.sharpenAmount = 0.4;
session.detailHaze = [0.2, 0.3, 0.4];
session.pointColor.addHsl(0.5, 0.5, 1);
session.pointColor.samples[0].hueShift = 0.3;
session.pointColor.samples[0].saturationShift = 0.2;
session.oklch.lightness = 0.3;
session.oklch.chroma = 0.2;
session.blackWhite.enabled = true;
session.blackWhite.mixers[0] = 0.5;
session.optics.distortion = 0.4;
session.optics.vignetteAmount = -0.5;
session.optics.chromaticAberration = 0.3;
session.retouchMarks = [{ id: 'mark', kind: 1, x: 0.5, y: 0.5, radius: 0.1, sourceX: 0, sourceY: 0 }];
session.lutStack = [{ id: 'lut', lutId: 'lut', name: 'n', sourceUri: 's', enabled: true, intensity: 1, lut: null }];
session.lutLink = 'linked';
session.lutPresetName = 'preset';
// Framing that must survive.
session.cropLeft = 0.1; session.cropTop = 0.05;
session.cropRight = 0.9; session.cropBottom = 0.95;
session.rotation = 90;
session.flipH = true; session.flipV = false;
session.geometry = [0.2, -0.1, 0.05, 0, 100, 0, 0, 0];

// The fixture must really have every stage switched on, otherwise the resets
// below would assert nothing.
assert(!session.detail.isBypass(), 'fixture detail stage is active');
assert(!session.pointColor.isBypass(), 'fixture point colour is active');
// OkLCh is retired: the fixture keeps old non-zero sidecar values, but the stage
// must report bypass so it can never alter the before/after render.
assert(session.oklch.lightness === 0.3 && session.oklch.chroma === 0.2,
  'fixture keeps legacy OkLCh values for sidecar compatibility');
assert(session.oklch.isBypass(), 'the retired OkLCh stage is always bypassed');
assert(!session.blackWhite.isBypass(), 'fixture black-and-white is active');
assert(!session.optics.isBypass(), 'fixture optics is active');

// Control: the NORMAL snapshot keeps all of these (so the before reset is a
// deliberate, separate decision rather than snapshot already dropping them).
const normal = ImageProcessor.snapshot(session);
assert(!normal.detail.isBypass() && !normal.pointColor.isBypass() &&
  !normal.blackWhite.isBypass() && !normal.optics.isBypass(),
  'a normal snapshot must keep the active document-level stages');
assert(normal.oklch.isBypass() && normal.oklch.lightness === 0.3 && normal.oklch.chroma === 0.2,
  'the retired OkLCh stage stays bypassed, but its legacy sidecar values still survive the snapshot');

// ---- the before snapshot ----------------------------------------------------
const before = ImageProcessor.beforeSnapshot(session);
assert(before.detail.isBypass(), 'detail (clarity/texture/dehaze/sharpen) must be reset in the original');
assert.strictEqual(before.detailHaze.length, 0, 'the haze statistic must be reset with detail');
assert(before.pointColor.isBypass() && before.pointColor.samples.length === 0,
  'point colour must be reset in the original');
assert(before.oklch.isBypass(), 'the retired OkLCh stage is bypassed in the original too');
assert.strictEqual(before.blackWhite.enabled, false, 'black-and-white must be off in the original');
assert(before.blackWhite.isBypass(), 'and every band weight reset');
assert(before.optics.isBypass(), 'lens correction must be reset in the original');
assert.strictEqual(before.optics.distortion, 0, 'distortion is zero in the original');
assert.strictEqual(before.optics.vignetteAmount, 0, 'optical vignetting is zero in the original');
assert.strictEqual(before.denoise.luminance, 0, 'denoise is off in the original (unchanged behaviour)');
assert.strictEqual(before.layers.length, 0, 'layer grades are gone (unchanged behaviour)');
assert.strictEqual(before.retouchMarks.length, 0, 'retouch marks are gone (unchanged behaviour)');
assert.strictEqual(before.lutStack.length, 0, 'the LUT stack is gone (unchanged behaviour)');
assert.strictEqual(before.lutLink, '', 'LUT link is cleared (unchanged behaviour)');
assert.strictEqual(before.lutPresetName, '', 'LUT preset name is cleared (unchanged behaviour)');

// Framing survives.
assert.strictEqual(before.cropLeft, 0.1, 'crop left survives');
assert.strictEqual(before.cropTop, 0.05, 'crop top survives');
assert.strictEqual(before.cropRight, 0.9, 'crop right survives');
assert.strictEqual(before.cropBottom, 0.95, 'crop bottom survives');
assert.strictEqual(before.rotation, 90, 'rotation survives');
assert.strictEqual(before.flipH, true, 'horizontal flip survives');
assert.strictEqual(before.flipV, false, 'vertical flip survives');
assert.strictEqual(JSON.stringify(Array.from(before.geometry)),
  JSON.stringify([0.2, -0.1, 0.05, 0, 100, 0, 0, 0]), 'manual geometry survives');

// The live session is untouched (a before preview must not edit the document).
assert(!session.detail.isBypass(), 'the source session keeps its detail settings');
assert.strictEqual(session.blackWhite.enabled, true, 'the source session keeps black-and-white enabled');
assert.strictEqual(session.optics.distortion, 0.4, 'the source session keeps its lens correction');
assert.strictEqual(session.cropLeft, 0.1, 'the source session keeps its crop');
assert.strictEqual(session.layers.length, 1, 'the source session keeps its layers');

console.log('PASS before snapshot: clarity/texture/dehaze/sharpen, point colour, black-and-white');
console.log('     and lens correction are all at their bypass in the "original", while crop, rotation, flips');
console.log('     and manual geometry are preserved verbatim. The same fixture keeps all five stages in a');
console.log('     normal snapshot, so the reset is specific to the before frame.');
