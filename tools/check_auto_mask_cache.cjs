// F8 — the auto-mask fallback must NOT populate the mask cache.
//
// When the source proxy cannot be read, `rasterizeMaskInto` falls back to the
// brush without the colour gate. The comment says "do not cache, retry next time"
// but the code wrote the un-gated alpha into `session.maskCache`; `prepareMasks`
// then skips every later attempt, so turning on auto mask did nothing for the
// whole session (its threshold could never take effect).
//
// The test drives the REAL `prepareMasks` twice on the same session:
//   1. proxy unavailable -> the cache must stay EMPTY, and the display path must
//      still fall back for that frame (renderMaskLayerForDisplay returns the
//      un-gated alpha rather than failing),
//   2. proxy available   -> the very next prepareMasks rasterizes and caches,
//      which is the "retry" the comment promises.
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
      if (name === 'libvivid_pixels.so') return { default: { rasterizeLinear: (w, h) => new ArrayBuffer(w * h), rasterizeRadial: (w, h) => new ArrayBuffer(w * h), rasterizeBrushStroke: (w, h) => new ArrayBuffer(w * h), remapGeometry: (b, w, h) => new ArrayBuffer(w * h * 4), composeInto() {}, invertOpacity() {}, sampleBitmap() {} } };
      if (name.startsWith('@kit.')) return { hilog: { info() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { MaskLayer, MaskComponent, MaskComponentType } = load(root + '/edit/models/Mask.ets');
const { RangeMaskService } = load(root + '/edit/engine/RangeMaskService.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');

const W = 24, H = 16;
const session = new EditSession();
session.ensureBaseLayer();
const local = new MaskLayer('auto');
const brush = new MaskComponent(MaskComponentType.BRUSH);
brush.brushData.autoMask = true;
local.components = [brush];
// `prepareMasks` now skips masks that carry no local adjustment (they cannot
// change a pixel, and the region renderer caches only real pipelines). This
// fixture tests the auto-mask cache, so it must be a mask the pipeline uses.
local.adjustments.setValue('exposure', 0.2);
session.layers[0].maskLayers = [local];
const key = session.layers[0].id + ':' + local.id + ':' + session.maskRevision + ':' + W + 'x' + H;

assert(ImageProcessor.layerNeedsAutoMaskProxy(local), 'the fixture mask really needs the auto-mask proxy');

const realEnsure = RangeMaskService.ensureAutoMaskProxy;

(async () => {
  // ---- 1. proxy unavailable --------------------------------------------------
  RangeMaskService.ensureAutoMaskProxy = async () => null;
  await ImageProcessor.prepareMasks(session, W, H);
  assert.strictEqual(session.maskCache.size, 0,
    'a missing auto-mask proxy must not cache the un-gated fallback (cache size ' +
    session.maskCache.size + ')');
  assert(!session.maskCache.has(key), 'the fallback key must not be present');

  // The display path still has to show something for this frame: it falls back
  // to the un-gated brush WITHOUT caching.
  const display = ImageProcessor.renderMaskLayerForDisplay(session, local, W, H);
  assert(display.length === W * H, 'the display fallback still returns a mask');
  assert.strictEqual(session.maskCache.size, 0, 'the display fallback must not cache either');

  // ---- 2. proxy available on the next attempt --------------------------------
  RangeMaskService.ensureAutoMaskProxy = async () => ({
    width: 8, height: 6, rgb: new Uint8Array(8 * 6 * 3).fill(128),
  });
  await ImageProcessor.prepareMasks(session, W, H);
  assert(session.maskCache.has(key), 'the next attempt with a proxy must rasterize and cache');
  assert.strictEqual(session.maskCache.get(key).length, W * H, 'the cached alpha has one byte per pixel');

  // The cache entry is what prepareMasks uses to skip work: a third run with the
  // proxy withdrawn must NOT throw it away.
  RangeMaskService.ensureAutoMaskProxy = async () => null;
  await ImageProcessor.prepareMasks(session, W, H);
  assert(session.maskCache.has(key), 'a cached entry must survive a later proxy-less prepare');

  // A source-level guard keeps the fallback branch honest even if the runtime
  // behaviour above is refactored: no maskCache.set inside the proxy-null branch.
  const processorSource = fs.readFileSync('entry/src/main/ets/edit/engine/ImageProcessor.ets', 'utf8');
  const branch = processorSource.slice(
    processorSource.indexOf('const proxy = await RangeMaskService.ensureAutoMaskProxy(session);'),
    processorSource.indexOf('// 解析型分量', processorSource.indexOf('const proxy = await RangeMaskService.ensureAutoMaskProxy(session);')));
  assert(branch.length > 0, 'the auto-mask branch must exist');
  assert(!/maskCache\.set/.test(branch),
    'the proxy-null fallback branch must not write maskCache: ' + branch);

  RangeMaskService.ensureAutoMaskProxy = realEnsure;
  console.log('PASS auto-mask cache: with no source proxy the fallback caches nothing, the display path still');
  console.log('     renders for that frame, and the next prepareMasks with a proxy rasterizes and caches the');
  console.log('     gated mask — while an existing cache entry survives a later proxy-less call.');
})().catch((error) => { console.error(error); process.exitCode = 1; });
