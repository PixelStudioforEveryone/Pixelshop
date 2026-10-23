// F10 — saving a LUT must bake only RGB->RGB stages.
//
// `saveCurrentLut` feeds a 33^3 RGB grid through the normal pipeline. Vignette
// and grain are functions of pixel POSITION; applied to grid coordinates they
// become functions of the colour at that cube position, so a positional effect
// silently turned into a colour-dependent one. Both are excluded from the bake
// now: the same session must produce a byte-identical LUT with them on and off.
//
// Anti-vacuous controls:
//   * the normal (non-bake) parameter mapping DOES change when vignette/grain are
//     set, so the two stages are real and active in this fixture;
//   * the bake still contains the colour grade (its output differs from the
//     ungraded grid), so "identical" is not "both empty".
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
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');

const SIZE = 33;
function grid() {
  const pixels = new Uint8ClampedArray(SIZE * SIZE * SIZE * 4);
  let offset = 0;
  for (let b = 0; b < SIZE; b++) for (let g = 0; g < SIZE; g++) for (let r = 0; r < SIZE; r++) {
    pixels[offset++] = Math.round(r * 255 / (SIZE - 1));
    pixels[offset++] = Math.round(g * 255 / (SIZE - 1));
    pixels[offset++] = Math.round(b * 255 / (SIZE - 1));
    pixels[offset++] = 255;
  }
  return pixels;
}
function fixtureSession(withSpatial) {
  const session = new EditSession();
  session.ensureBaseLayer();
  const adj = session.layers[0].adjustments;
  adj.exposure = 0.35;
  adj.contrast = 0.25;
  adj.saturation = 0.3;
  adj.temperature = 0.2;
  adj.toneCurve = 0.2;
  if (withSpatial) {
    adj.vignetteAmount = -0.8;
    adj.vignetteMidpoint = 0.3;
    adj.vignetteRoundness = 0.4;
    adj.vignetteFeather = 0.5;
    adj.vignetteHighlights = 0.6;
    adj.grainAmount = 0.7;
    adj.grainSize = 0.5;
    adj.grainRoughness = 0.4;
  }
  return session;
}
function bake(session, pixels) {
  const params = ImageProcessor.globalLutParams(session, pixels.buffer.slice(0), SIZE * SIZE, SIZE);
  return { params: params, output: new Uint8ClampedArray(processPixels(params).buffer) };
}
function differingBytes(a, b) {
  let count = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) count++;
  return count;
}
function maxDifference(a, b) {
  let max = 0;
  for (let i = 0; i < a.length; i++) max = Math.max(max, Math.abs(a[i] - b[i]));
  return max;
}

const pixels = grid();
const gradedGrid = bake(fixtureSession(false), pixels);

// ---- 1. the bake ignores vignette and grain --------------------------------
const withSpatial = bake(fixtureSession(true), pixels);
assert.strictEqual(differingBytes(withSpatial.output, gradedGrid.output), 0,
  'the LUT data must be identical whether vignette/grain are set or zero');
assert.strictEqual(maxDifference(withSpatial.output, gradedGrid.output), 0,
  'and identical byte for byte, not just nearly');
// The mapping itself must carry zeros, so a future refactor that feeds the raw
// adjustments back in fails here even before the render comparison.
for (const layer of withSpatial.params.layers) {
  assert.strictEqual(layer.adjustments.vignetteAmount, 0, 'the bake mapping zeroes vignetteAmount');
  assert.strictEqual(layer.adjustments.vignetteMidpoint, 0, 'the bake mapping zeroes vignetteMidpoint');
  assert.strictEqual(layer.adjustments.vignetteRoundness, 0, 'the bake mapping zeroes vignetteRoundness');
  assert.strictEqual(layer.adjustments.vignetteFeather, 0, 'the bake mapping zeroes vignetteFeather');
  assert.strictEqual(layer.adjustments.vignetteHighlights, 0, 'the bake mapping zeroes vignetteHighlights');
  assert.strictEqual(layer.adjustments.grainAmount, 0, 'the bake mapping zeroes grainAmount');
  assert.strictEqual(layer.adjustments.grainSize, 0, 'the bake mapping zeroes grainSize');
  assert.strictEqual(layer.adjustments.grainRoughness, 0, 'the bake mapping zeroes grainRoughness');
}

// ---- 2. anti-vacuous: the stages are real and the grade is baked -----------
const fullSession = fixtureSession(true);
const fullParams = ImageProcessor.buildWorkerParams(fullSession, pixels.buffer.slice(0), SIZE * SIZE, SIZE);
const fullOutput = new Uint8ClampedArray(processPixels(fullParams).buffer);
assert(differingBytes(fullOutput, withSpatial.output) > 5000,
  'the NORMAL pipeline must change when vignette/grain are set (they are real stages): ' +
  differingBytes(fullOutput, withSpatial.output) + ' differing bytes');
assert(maxDifference(fullOutput, withSpatial.output) >= 8,
  'and the difference must be visible, not rounding');
const ungraded = new EditSession();
ungraded.ensureBaseLayer();
const plainGrid = bake(ungraded, pixels).output;
assert(differingBytes(gradedGrid.output, plainGrid) > 5000,
  'the LUT must still contain the colour grade (' + differingBytes(gradedGrid.output, plainGrid) + ' bytes differ)');
assert(differingBytes(gradedGrid.output, pixels) > 5000,
  'and differ from the raw grid');

console.log('PASS LUT bake: the same session produces byte-identical LUT data with vignette/grain set and');
console.log('     zeroed (max difference ' + maxDifference(withSpatial.output, gradedGrid.output) +
  '), while the normal pipeline changes by ' +
  differingBytes(fullOutput, withSpatial.output) + ' bytes (peak ' + maxDifference(fullOutput, withSpatial.output) +
  ') and the bake still contains the colour grade.');
