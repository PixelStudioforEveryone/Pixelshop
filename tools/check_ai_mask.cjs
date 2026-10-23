// Integration test for the local AI mask path: model verification, raster
// production, mask composition, sidecar persistence, cancellation and the
// no-model failure contract.
//
// The native module is simulated, so this test covers the ArkTS contract
// (hashing, loading order, error mapping, staleness, base64 persistence) while
// the actual network accuracy is covered by the Python harnesses
// (tools/ai_validate_u2netp.py, tools/ai_validate_sky.py) which run the real
// converted models against real public test data.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const crypto = require('crypto');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');

// --- simulated rawfile model bytes, matching the manifest hashes ----------
const MODEL_BYTES = {};
for (const name of ['ai_masks/u2netp.ncnn.param', 'ai_masks/u2netp.ncnn.bin',
  'ai_masks/skysegsmall_sim-opt-fp16.param', 'ai_masks/skysegsmall_sim-opt-fp16.bin']) {
  MODEL_BYTES[name] = crypto.createHash('sha256').update(name).digest();
}
const sha256Hex = (bytes) => crypto.createHash('sha256').update(Buffer.from(bytes)).digest('hex');

// The manifest must agree with the real shipped assets, so read them instead of
// inventing sizes. Falls back to the simulated bytes when the rawfile is absent.
const RAW = path.resolve('entry/src/main/resources/rawfile');
const realBytes = (rel) => {
  const file = path.join(RAW, rel);
  return fs.existsSync(file) ? new Uint8Array(fs.readFileSync(file)) : null;
};

const calls = { loadModel: [], segment: [], release: 0 };
/** Per-kind load state, mirroring the native module (release() unloads). */
const loadedKinds = new Set();
let segmentImpl = null;
const aiNative = {
  loadModel: async (kind, param, bin) => {
    calls.loadModel.push({ kind, param: param.byteLength, bin: bin.byteLength });
    if (!param.byteLength || !bin.byteLength) throw new Error('empty weights');
    loadedKinds.add(kind);
    return undefined;
  },
  segment: async (kind, rgba, width, height) => {
    calls.segment.push({ kind, bytes: rgba.byteLength, width, height });
    if (segmentImpl) return segmentImpl(kind, width, height);
    // Deterministic stand-in: left half selected, at the model's own size.
    const side = kind === 1 ? 384 : 320;
    const out = new Uint8Array(8 + side * side);
    new DataView(out.buffer).setUint32(0, side, true);
    new DataView(out.buffer).setUint32(4, side, true);
    for (let y = 0; y < side; y++) for (let x = 0; x < side; x++) out[8 + y * side + x] = x < side / 2 ? 255 : 0;
    return out.buffer;
  },
  isLoaded: (kind) => loadedKinds.has(kind),
  modelInfo: () => [],
  release: () => { calls.release++; loadedKinds.clear(); },
};

// Rawfile access with a tamperable table so the hash check can be exercised.
let rawfileOverrides = new Map();
const resourceManager = {
  getRawFileContent: async (rel) => {
    if (rawfileOverrides.has(rel)) {
      const value = rawfileOverrides.get(rel);
      if (value === null) throw new Error('not found: ' + rel);
      return value;
    }
    const real = realBytes(rel);
    if (real) return real;
    if (MODEL_BYTES[rel]) return MODEL_BYTES[rel];
    throw new Error('not found: ' + rel);
  },
};

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
    Uint8Array, Uint8ClampedArray, Uint32Array, Float32Array, DataView, Promise, Error,
    setTimeout, clearTimeout, TextEncoder, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (n) => {
      if (n === 'libvivid_ai.so') return { default: aiNative };
      if (n === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0) } };
      if (n === '@kit.ArkTS') {
        return {
          util: {
            Base64Helper: class {
              encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
              decodeSync(text) {
                const buf = Buffer.from(text, 'base64');
                return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
              }
            }
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

const { AiMaskKind, AI_MASK_MODELS } = load(root + '/edit/models/AiMaskModels.ets');
const {
  AiSegmentationService, bitmapCoverage, aiMaskErrorMessage, AiMaskError, AiMaskErrorCode,
} = load(root + '/edit/engine/AiSegmentationService.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { MaskComponentType: T, MaskBlendMode: O, MaskRenderer: _unused,
  RASTER_ORIGIN_SUBJECT: ORIGIN_SUBJECT, RASTER_ORIGIN_SKY: ORIGIN_SKY } = load(root + '/edit/models/Mask.ets');
const { MaskRenderer: M } = load(root + '/edit/engine/MaskRenderer.ets');
const { rasterizeComponentCore, rasterizeStructuredMaskCore } = load(root + '/edit/engine/MaskRasterCore.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');

let checks = 0;
const ok = (condition, message) => { assert(condition, message); checks++; };
const W = 64, H = 48;

(async function main() {
  // 1. The manifest must describe the assets that are actually shipped.
  for (const spec of AI_MASK_MODELS) {
    const actualParam = realBytes(spec.paramPath), actualBin = realBytes(spec.binPath);
    if (!actualParam || !actualBin) { console.log(`SKIP: ${spec.paramPath} not present in rawfile`); return 2; }
    ok(actualParam.byteLength === spec.paramBytes,
      `${spec.key} param size manifest=${spec.paramBytes} actual=${actualParam.byteLength}`);
    ok(actualBin.byteLength === spec.binBytes,
      `${spec.key} bin size manifest=${spec.binBytes} actual=${actualBin.byteLength}`);
    ok(sha256Hex(actualParam) === spec.paramSha256, `${spec.key} param sha256 matches the manifest`);
    ok(sha256Hex(actualBin) === spec.binSha256, `${spec.key} bin sha256 matches the manifest`);
  }
  console.log(`manifest verified against ${AI_MASK_MODELS.length} shipped models`);

  // 2. A normal request verifies, loads in order, and yields a real raster.
  const raster = await AiSegmentationService.segment(resourceManager, AiMaskKind.SUBJECT,
    new ArrayBuffer(W * H * 4), W, H);
  ok(calls.loadModel.length === 1 && calls.loadModel[0].kind === AiMaskKind.SUBJECT,
    'the subject model is loaded exactly once before inference');
  ok(calls.loadModel[0].param === AI_MASK_MODELS[0].paramBytes,
    'the verified param bytes are handed to the loader');
  ok(raster.width === 320 && raster.height === 320, 'subject raster uses the model output size');
  ok(raster.alpha.length === 320 * 320, 'subject raster alpha covers width*height');
  ok(Math.abs(bitmapCoverage(raster.alpha) - 0.5) < 0.01, 'coverage reflects the simulated selection');
  ok(raster.alpha[0] === 255 && raster.alpha[319] === 0, 'raster content is the model output, not a stub');

  // 3. The result becomes a real mask component that composes like any other.
  const session = new EditSession();
  session.ensureBaseLayer();
  const layer = session.createMaskLayer(T.SUBJECT);
  const component = layer.components[0];
  ok(session.isRasterMaskComponent(component), 'a subject component is recognised as an AI mask');
  ok(session.setMaskComponentRaster(component.id, ORIGIN_SUBJECT, raster.modelKey,
    raster.width, raster.height, raster.alpha), 'the raster attaches to its component');
  const alpha = M.renderComponent(component, W, H);
  ok(alpha[Math.floor(H / 2) * W + 2] > 250 && alpha[Math.floor(H / 2) * W + W - 3] < 5,
    'left/right halves rasterise from the model output');

  // subtract and intersect must behave exactly like the manual components.
  // The reference equation is the documented Lightroom/Lightcraft algebra
  // (ADD = max, SUBTRACT = a*(1-b), INTERSECT = a*b) evaluated in component
  // order, which is what check_mask_workflow already pins for manual parts.
  const subtract = session.addMaskComponent(T.SKY, O.SUBTRACT);
  session.setMaskComponentRaster(subtract.id, ORIGIN_SKY, 'sky', 8, 8, new Uint8Array(64).fill(128));
  const radial = session.addMaskComponent(T.RADIAL_GRADIENT, O.ADD);
  const composed = M.renderMaskLayer(layer, W, H);
  const radialOnly = M.renderComponent(radial, W, H);
  const expected = new Uint8ClampedArray(W * H);
  for (let i = 0; i < expected.length; i++) {
    const afterAdd = alpha[i];                                        // ADD over empty
    const afterSubtract = Math.round(afterAdd * (255 - 128) / 255);   // SUBTRACT a half mask
    expected[i] = Math.max(afterSubtract, radialOnly[i]);             // ADD the radial
  }
  ok(composed.every((v, i) => v === expected[i]), 'AI parts compose through add/subtract/intersect');
  ok(session.setMaskComponentRaster('missing-id', ORIGIN_SUBJECT, 'x', 4, 4, new Uint8Array(16)) === false,
    'attaching to a deleted component is refused instead of resurrecting it');

  // Unambiguous semantics any wrong implementation must fail: a fully opaque
  // subtract erases everything it covers, and an intersect restricts to it.
  subtract.raster.alpha = new Uint8Array(64).fill(255);
  const erased = M.renderMaskLayer(layer, W, H);
  ok(erased.every((v, i) => v === radialOnly[i]),
    'a fully opaque AI subtract removes exactly what it covers');
  subtract.raster.alpha = new Uint8Array(64);            // now subtract nothing
  const intersect = session.addMaskComponent(T.SKY, O.INTERSECT);
  // A full-resolution raster so bilinear resampling is exact and the intersect
  // boundary is crisp; the resampling itself is asserted separately below.
  const halfMask = new Uint8Array(W * H);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) halfMask[y * W + x] = x < W / 2 ? 0 : 255;
  session.setMaskComponentRaster(intersect.id, ORIGIN_SKY, 'sky', W, H, halfMask);
  const restricted = M.renderMaskLayer(layer, W, H);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = y * W + x;
      const want = x < W / 2 ? 0 : composed[i];
      if (restricted[i] !== want) { assert.fail(`intersect at ${x},${y}: ${restricted[i]} != ${want}`); }
    }
  }
  checks++;
  session.deleteMaskComponent(intersect.id);

  // A model raster coarser than the render raster must be resampled, and the
  // resampling must be a monotone ramp rather than a nearest-neighbour step or
  // a hard left/right split (which would move the selection edge).
  const coarse = session.addMaskComponent(T.SKY, O.INTERSECT);
  const ramp = new Uint8Array(2);
  ramp[0] = 0; ramp[1] = 255;
  session.setMaskComponentRaster(coarse.id, ORIGIN_SKY, 'sky', 2, 1, ramp);
  const ramped = M.renderComponent(coarse, W, H);
  ok(ramped[0] === 0 && ramped[W - 1] === 255, 'a coarse raster spans the frame edge to edge');
  for (let x = 1; x < W; x++) {
    if (ramped[x] < ramped[x - 1]) { assert.fail(`resampling is not monotone at x=${x}`); }
  }
  checks++;
  ok(ramped[W / 2] > 0 && ramped[W / 2] < 255, 'a two-sample raster interpolates instead of switching hard');
  ok(ramped.every((v, i) => v === ramped[i % W]), 'resampling is row-independent');

  // 4. A component with no raster yet selects nothing rather than everything.
  const empty = session.addMaskComponent(T.SKY, O.ADD);
  empty.raster = null;
  const emptyAlpha = M.renderComponent(empty, W, H);
  ok(emptyAlpha.every((v) => v === 0), 'an unscored AI component selects nothing');

  // 5. Sidecar round trip preserves the raster byte for byte.
  const restored = new EditSession();
  ok(restored.importAdjustmentState(session.exportAdjustmentState()), 'state imports');
  const restoredLayer = restored.layers[0].maskLayers[0];
  const restoredComponent = restoredLayer.components[0];
  ok(restoredComponent.raster !== null && restoredComponent.raster.hasAlpha,
    'the AI raster survives serialisation');
  ok(restoredComponent.raster.width === 320 && restoredComponent.raster.height === 320,
    'restored raster keeps its dimensions');
  ok(Array.from(restoredComponent.raster.alpha).every((v, i) => v === raster.alpha[i]),
    'restored raster bytes are identical');
  ok(restoredComponent.raster.key === raster.modelKey, 'restored raster keeps its model key');
  ok(restoredComponent.raster.origin === ORIGIN_SUBJECT, 'restored raster keeps its origin');
  const restoredAlpha = M.renderComponent(restoredComponent, W, H);
  ok(restoredAlpha.every((v, i) => v === alpha[i]), 'a reopened project renders the same mask');

  // 5b. The TaskPool/export path must render an AI mask exactly like the
  //     on-screen overlay. Before the worker layer carried the raster, an AI
  //     component was converted to an empty brush there and silently dropped.
  const workerLayer = ImageProcessor.plainMaskLayer(layer);
  const workerComposed = new Uint8ClampedArray(rasterizeStructuredMaskCore(workerLayer, W, H));
  const uiComposed = M.renderMaskLayer(layer, W, H);
  ok(workerComposed.every((v, i) => v === uiComposed[i]),
    'the worker/export path renders AI masks identically to the overlay');
  const carried = workerLayer.components.filter((c) => c.type === 3 || c.type === 4);
  ok(carried.length > 0 && carried.some((c) => c.bitmap && c.bitmap.alpha.byteLength === 320 * 320),
    'the model raster is carried into the worker layer at full model resolution');
  ok(workerLayer.components.every((c) => (c.type === 3 || c.type === 4) || c.bitmap === null || c.bitmap === undefined),
    'no geometric component carries a model raster into the worker layer');
  // An AI component that has not been scored yet must travel as "no raster"
  // (selecting nothing), never as a default full-frame selection.
  const unscored = workerLayer.components.filter((c) => (c.type === 3 || c.type === 4) && c.bitmap === null);
  ok(unscored.length > 0, 'an AI component with no raster yet carries none');
  const unscoredAlpha = new Uint8ClampedArray(rasterizeComponentCore(unscored[0], W, H));
  ok(unscoredAlpha.every((v) => v === 0), 'an unscored AI component selects nothing in the worker path');

  // 6. A tampered weight file must be rejected, never silently used.
  rawfileOverrides.set(AI_MASK_MODELS[0].binPath, (() => {
    const original = realBytes(AI_MASK_MODELS[0].binPath) || MODEL_BYTES[AI_MASK_MODELS[0].binPath];
    const copy = new Uint8Array(original); copy[1234] ^= 0xFF; return copy;
  })());
  AiSegmentationService.release();
  const loadsBefore = calls.loadModel.length;
  let tampered = null;
  try {
    await AiSegmentationService.segment(resourceManager, AiMaskKind.SUBJECT, new ArrayBuffer(W * H * 4), W, H);
  } catch (error) { tampered = error; }
  ok(tampered instanceof AiMaskError, 'a tampered model raises AiMaskError');
  ok(tampered && tampered.code === AiMaskErrorCode.MODEL_CORRUPT, 'a tampered model reports MODEL_CORRUPT');
  ok(calls.loadModel.length === loadsBefore, 'a tampered model is never handed to the loader');
  ok(!/成功|已生成/.test(aiMaskErrorMessage(tampered)), 'the tampered-model message does not claim success');
  rawfileOverrides.delete(AI_MASK_MODELS[0].binPath);

  // 7. A missing model must report a concrete failure.
  rawfileOverrides.set(AI_MASK_MODELS[0].paramPath, null);
  AiSegmentationService.release();
  let missing = null;
  try {
    await AiSegmentationService.segment(resourceManager, AiMaskKind.SUBJECT, new ArrayBuffer(W * H * 4), W, H);
  } catch (error) { missing = error; }
  ok(missing instanceof AiMaskError && missing.code === AiMaskErrorCode.MODEL_MISSING,
    'a missing model reports MODEL_MISSING');
  ok(/缺失/.test(aiMaskErrorMessage(missing)), 'the missing-model message names the problem');
  rawfileOverrides.delete(AI_MASK_MODELS[0].paramPath);

  // 8. A short source buffer is rejected up front.
  let noSource = null;
  try {
    await AiSegmentationService.segment(resourceManager, AiMaskKind.SUBJECT, new ArrayBuffer(16), W, H);
  } catch (error) { noSource = error; }
  ok(noSource instanceof AiMaskError && noSource.code === AiMaskErrorCode.NO_SOURCE,
    'a short source buffer is rejected before inference');

  // 9. Cancellation: a result that lands after the photo changed is dropped.
  AiSegmentationService.release();
  let releaseSegment = null;
  segmentImpl = () => new Promise((resolve) => { releaseSegment = () => resolve((() => {
    const side = 320; const out = new Uint8Array(8 + side * side);
    new DataView(out.buffer).setUint32(0, side, true); new DataView(out.buffer).setUint32(4, side, true);
    out.fill(200, 8); return out.buffer;
  })()); });
  const pending = AiSegmentationService.segment(resourceManager, AiMaskKind.SUBJECT,
    new ArrayBuffer(W * H * 4), W, H);
  // Wait until the request has actually reached the native call before
  // invalidating it, otherwise there is nothing in flight to discard.
  for (let spin = 0; spin < 1000 && !releaseSegment; spin++) {
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  ok(releaseSegment !== null, 'the pending request reached the native inference');
  AiSegmentationService.cancelPending();
  releaseSegment();
  let cancelled = null;
  try { await pending; } catch (error) { cancelled = error; }
  ok(cancelled instanceof AiMaskError && cancelled.code === AiMaskErrorCode.CANCELLED,
    'a result for a photo the user already left is discarded');
  ok(/已丢弃/.test(aiMaskErrorMessage(cancelled)), 'the cancelled message explains the discard');
  segmentImpl = null;

  // 10. The busy flag must always clear, including after a failure.
  AiSegmentationService.release();
  await AiSegmentationService.segment(resourceManager, AiMaskKind.SKY,
    new ArrayBuffer(W * H * 4), W, H);
  ok(!AiSegmentationService.isBusy(), 'the service is not left busy after a successful run');
  rawfileOverrides.set(AI_MASK_MODELS[1].binPath, new Uint8Array(10));
  AiSegmentationService.release();
  try {
    await AiSegmentationService.segment(resourceManager, AiMaskKind.SKY, new ArrayBuffer(W * H * 4), W, H);
  } catch (_e) { /* expected */ }
  ok(!AiSegmentationService.isBusy(), 'the service is not left busy after a failure');
  rawfileOverrides.delete(AI_MASK_MODELS[1].binPath);

  // 11. Multiple sources in sequence must each produce their own raster, and the
  //     second must not be served from the first one's cache.
  AiSegmentationService.release();
  const first = await AiSegmentationService.segment(resourceManager, AiMaskKind.SKY,
    new ArrayBuffer(64 * 64 * 4), 64, 64);
  const second = await AiSegmentationService.segment(resourceManager, AiMaskKind.SKY,
    new ArrayBuffer(96 * 96 * 4), 96, 96);
  ok(first.width === 384 && second.width === 384, 'both sources use the sky model output size');
  ok(calls.segment[calls.segment.length - 1].width === 96,
    'a different source size is a different cache entry');

  AiSegmentationService.release();
  ok(calls.release > 0, 'release() reaches the native module');
  ok(calls.segment.every((c) => c.bytes === c.width * c.height * 4),
    'every inference input is exactly width*height*4 RGBA bytes');

  console.log(`ai mask integration: ${checks} checks passed`);
  return 0;
})().then((code) => { if (code !== undefined) process.exit(code); })
  .catch((error) => { console.error('FAIL: ' + (error && error.message)); process.exit(1); });
