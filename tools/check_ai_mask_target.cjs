// F9 — a local AI selection must land on the mask that was selected when it
// STARTED, not on whatever is selected when the await resolves.
//
// Both mask panels stored only the segmentation "generation" before awaiting and
// then used `session.activeMaskLayer` to pick the target. During a multi-second
// inference the user can switch layers or mask layers, and the result was added
// to the new target (or to the new layer's mask, which `setMaskComponentRaster`
// then also resolved against). The panels now capture layer+mask ids before the
// await and resolve them after it, reporting "识别结果已失效" when the target is
// gone. The target-aware EditSession API is exercised directly here, plus
// structural assertions that both panels actually use it after the await.
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
    TextEncoder, TextDecoder, Buffer,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (name) => {
      if (name === 'libvivid_gpu.so') return { default: {}, GpuOutputGeometry: {} };
      if (name === '@kit.ArkTS') return {
        taskpool: { Task: class { static isCanceled() { return false; } constructor(f, ...a) { this.f = f; this.a = a; } }, execute: async (t) => t.f(...t.a) },
        util: {
          TextEncoder: class { encode(t) { return new Uint8Array(Buffer.from(t, 'utf8')); } },
          TextDecoder: class { decode(b) { return Buffer.from(b).toString('utf8'); } },
          Base64Helper: class {
            encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
            decodeSync(text) { const b = Buffer.from(text, 'base64'); return new Uint8Array(b.buffer, b.byteOffset, b.byteLength); }
          },
        },
      };
      if (name.endsWith('.so')) return { default: {} };
      if (name.startsWith('@kit.')) return { hilog: { info() {} } };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');
const { MaskComponentType, MaskBlendMode } = load(root + '/edit/models/Mask.ets');

// ---- 1. functional semantics of the target-bound API ----------------------
const session = new EditSession();
const layerA = new Layer('a');
const layerB = new Layer('b');
session.layers = [layerA, layerB];
session.activeLayerIndex = 0;
const maskA = session.createMaskLayerOn(layerA.id, MaskComponentType.SKY);
const maskB = session.createMaskLayerOn(layerB.id, MaskComponentType.SKY);
assert(maskA && maskB, 'both layers get a mask layer');

// What the panel captures before the await.
const targetLayerId = layerA.id;
const targetMaskLayerId = maskA.id;

// The await: the user switches layer and mask selection.
session.activeLayerIndex = 1;
session.selectedMaskLayerId = maskB.id;
session.selectedMaskComponentId = maskB.components[0].id;

// A result bound to the captured ids must go to maskA.
const beforeA = maskA.components.length;
const beforeB = maskB.components.length;
const component = session.addMaskComponentTo(targetLayerId, targetMaskLayerId,
  MaskComponentType.SUBJECT, MaskBlendMode.ADD);
assert(component !== null, 'the bound target still exists, so the component is created');
assert.strictEqual(maskA.components.length, beforeA + 1, 'the component lands on the ORIGINAL mask layer');
assert.strictEqual(maskB.components.length, beforeB, 'the newly selected mask layer is untouched');
assert.strictEqual(maskA.components[maskA.components.length - 1].id, component.id,
  'and it is the component that was created');
const alpha = new Uint8ClampedArray(4 * 3).fill(200);
assert.strictEqual(session.setMaskComponentRasterFor(targetLayerId, component.id, 'subject',
  'model-key', 4, 3, alpha), true, 'the raster attaches to the component of the original layer');
assert(component.raster && component.raster.width === 4 && component.raster.height === 3,
  'the raster is stored on that component');

// Why the binding is needed: the old call shape targets the CURRENT selection.
const beforeB2 = maskB.components.length;
const wrong = session.addMaskComponent(MaskComponentType.SUBJECT, MaskBlendMode.ADD);
assert(wrong !== null && maskB.components.length === beforeB2 + 1,
  'the unbound call shape must land on the NEWLY selected mask layer (this is the defect being fixed)');
assert.strictEqual(maskA.components.length, beforeA + 1,
  'and must not touch the original one');

// ---- 2. deleted target -> explicit invalidation, never a fallback ----------
const layerC = new Layer('c');
session.layers = [layerA, layerB, layerC];
session.activeLayerIndex = 2;
const maskC = session.createMaskLayerOn(layerC.id, MaskComponentType.SKY);
assert.strictEqual(session.addMaskComponentTo(layerA.id, 'mask-deleted',
  MaskComponentType.SUBJECT, MaskBlendMode.ADD), null,
  'a mask layer that no longer exists must yield no component (not another mask)');
// Deleting the original mask layer while the await is in flight.
layerA.maskLayers = layerA.maskLayers.filter((item) => item.id !== maskA.id);
assert.strictEqual(session.addMaskComponentTo(targetLayerId, targetMaskLayerId,
  MaskComponentType.SUBJECT, MaskBlendMode.ADD), null,
  'the deleted target must yield null');
assert.strictEqual(session.setMaskComponentRasterFor(targetLayerId, component.id, 'subject',
  'model-key-2', 4, 3, alpha), false, 'and the raster must be refused');
assert.strictEqual(session.createMaskLayerOn('layer-does-not-exist', MaskComponentType.SKY), null,
  'a deleted LAYER must yield no mask layer');
assert(maskC.components.length === 1, 'nothing leaked into the current selection');

// ---- 3. both panels must use the bound API after the await ----------------
function bodyOf(source, startNeedle, endNeedle) {
  const start = source.indexOf(startNeedle);
  assert(start >= 0, 'missing: ' + startNeedle);
  const end = source.indexOf(endNeedle, start + startNeedle.length);
  assert(end > start, 'missing end marker for ' + startNeedle);
  return source.slice(start, end);
}
for (const file of ['DesktopMaskPanel.ets', 'MaskPanel.ets']) {
  const source = fs.readFileSync('entry/src/main/ets/components/' + file, 'utf8');
  const body = bodyOf(source, 'private async runAiSelection(', 'catch (error)');
  const awaitAt = body.indexOf('await AiSegmentationService.segmentPixelMap');
  const captureAt = body.indexOf('const targetLayerId = session.activeLayer?.id');
  const captureMaskAt = body.indexOf('const targetMaskLayerId = session.activeMaskLayer?.id');
  assert(awaitAt >= 0, file + ': the segmentation await must be present');
  assert(captureAt >= 0 && captureAt < awaitAt,
    file + ': the target layer id must be captured BEFORE the await');
  assert(captureMaskAt >= 0 && captureMaskAt < awaitAt,
    file + ': the target mask layer id must be captured BEFORE the await');
  assert(body.indexOf('session.createMaskLayerOn(targetLayerId, type)') > awaitAt,
    file + ': a new mask layer is created on the captured layer after the await');
  assert(body.indexOf('session.addMaskComponentTo(targetLayerId, targetMaskLayerId') > awaitAt,
    file + ': the component is added to the captured mask layer after the await');
  assert(body.indexOf('session.setMaskComponentRasterFor(targetLayerId, componentId') > awaitAt,
    file + ': the raster is attached to the captured layer after the await');
  assert(/识别结果已失效（目标(蒙版|图层)已不存在）/.test(body),
    file + ': a vanished target must be reported as invalidated');
  // The old selection-relative calls must be gone from this method.
  assert(!/[^A-Za-z]session\.addMaskComponent\(/.test(body),
    file + ': must not use the selection-relative addMaskComponent');
  assert(!/[^A-Za-z]session\.createMaskLayer\(/.test(body),
    file + ': must not use the selection-relative createMaskLayer');
  assert(!/[^A-Za-z]session\.setMaskComponentRaster\(/.test(body),
    file + ': must not use the selection-relative setMaskComponentRaster');
}

console.log('PASS AI mask target binding: a result bound to (layer, mask) lands on that mask even after the');
console.log('     selection moved, the unbound call shape is shown to land on the new selection, a deleted');
console.log('     target yields null/false plus the "识别结果已失效" status, and both mask panels capture the');
console.log('     ids before the await and use the bound API after it.');
