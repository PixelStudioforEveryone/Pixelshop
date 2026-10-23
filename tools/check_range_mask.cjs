// Independent verification of the luminance / colour range mask.
//
// The core equations are re-derived here from their definition rather than
// replayed from the implementation, and the integration half drives the real
// ArkTS mask pipeline (component -> raster -> composition -> sidecar -> worker)
// so a range selection is proven to behave exactly like every other selection.
//
// Synthetic pixels only; never reads camera captures or user photos.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const crypto = require('crypto');
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
    Uint8Array, Uint16Array, Uint32Array, Uint8ClampedArray, Float32Array, DataView, Promise, Error,
    setTimeout, clearTimeout, TextEncoder, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (n) => {
      if (n === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0) } };
      if (n === 'libvivid_ai.so') return { default: { isLoaded: () => false, release: () => {}, modelInfo: () => [] } };
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

const M = load(root + '/edit/models/Mask.ets');
const core = load(root + '/edit/engine/RangeMaskCore.ets');
const { MaskRenderer } = load(root + '/edit/engine/MaskRenderer.ets');
const { rasterizeStructuredMaskCore } = load(root + '/edit/engine/MaskRasterCore.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { RangeMaskService } = load(root + '/edit/engine/RangeMaskService.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');

let checks = 0;
const ok = (condition, message) => { assert(condition, message); checks++; };
const T = M.MaskComponentType, O = M.MaskBlendMode;

// --- independent re-derivations -------------------------------------------
const LUMA_R = 0.2126, LUMA_G = 0.7152, LUMA_B = 0.0722;
function refSmoothStep(e0, e1, x) {
  if (e1 <= e0) return x < e0 ? 0 : 1;
  let t = (x - e0) / (e1 - e0);
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  return t * t * (3 - 2 * t);
}
// The documented range equation, written out here instead of being replayed.
// Includes the two documented edge rules: a minimum window width, and non
// overlapping transitions.
function refAlpha(r, g, b, p) {
  const rn = r / 255, gn = g / 255, bn = b / 255;
  const reqMin = Math.max(0, Math.min(1, p.min)), reqMax = Math.max(0, Math.min(1, p.max));
  let lo = Math.min(reqMin, reqMax), hi = Math.max(reqMin, reqMax);
  const MINIMUM_WIDTH = 0.01;
  if (hi - lo < MINIMUM_WIDTH) {
    const centre = (lo + hi) * 0.5;
    lo = Math.max(0, centre - MINIMUM_WIDTH * 0.5);
    hi = Math.min(1, centre + MINIMUM_WIDTH * 0.5);
  }
  const half = Math.min(Math.max(0.0005, Math.max(0, Math.min(1, p.smoothness)) * 0.5), (hi - lo) * 0.5);
  const luma = LUMA_R * rn + LUMA_G * gn + LUMA_B * bn;
  const lower = lo <= 0 ? 1 : refSmoothStep(lo - half, lo + half, luma);
  const upper = hi >= 1 ? 1 : 1 - refSmoothStep(hi - half, hi + half, luma);
  let w = lower * upper;
  if (p.colorEnabled && w > 0) {
    const dr = rn - p.colorR, dg = gn - p.colorG, db = bn - p.colorB;
    const distance = Math.sqrt((dr * dr + dg * dg + db * db) / 3);
    const radius = 0.04 + Math.max(0, Math.min(1, p.colorAmount)) * 0.6;
    w *= 1 - refSmoothStep(radius * 0.5, radius, distance);
  }
  return Math.max(0, Math.min(255, Math.round(w * 255)));
}
const params = (over) => Object.assign(new M.RangeMaskData(), over);

/** A horizontal grey ramp: luma rises 0..255 across the width. */
function rampProxy(width, height) {
  const rgb = new Uint8Array(width * height * 3);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const value = Math.round(x * 255 / (width - 1));
      const o = (y * width + x) * 3;
      rgb[o] = value; rgb[o + 1] = value; rgb[o + 2] = value;
    }
  }
  return { width, height, rgb };
}
/** Left half pure red, right half pure blue. */
function twoColorProxy(width, height) {
  const rgb = new Uint8Array(width * height * 3);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 3;
      if (x < width / 2) { rgb[o] = 255; rgb[o + 1] = 0; rgb[o + 2] = 0; }
      else { rgb[o] = 0; rgb[o + 1] = 0; rgb[o + 2] = 255; }
    }
  }
  return { width, height, rgb };
}
const coverage = (alpha, threshold = 128) => {
  let n = 0;
  for (let i = 0; i < alpha.length; i++) if (alpha[i] >= threshold) n++;
  return n / alpha.length;
};
/** Total selection weight, 0..1. Threshold-free, so it also measures how
 *  strongly a soft/partial selection is included. */
const mass = (alpha) => {
  let sum = 0;
  for (let i = 0; i < alpha.length; i++) sum += alpha[i];
  return alpha.length === 0 ? 0 : sum / (255 * alpha.length);
};
const partial = (alpha) => {
  let n = 0;
  for (let i = 0; i < alpha.length; i++) if (alpha[i] > 0 && alpha[i] < 255) n++;
  return n;
};

// --- 1. the equation itself ------------------------------------------------
{
  const proxy = rampProxy(128, 4);
  const cases = [
    params({ min: 0.2, max: 0.8, smoothness: 0.25 }),
    params({ min: 0, max: 1, smoothness: 0.25 }),
    params({ min: 0.5, max: 0.5, smoothness: 0.1 }),
    params({ min: 0.3, max: 0.7, smoothness: 0 }),
    params({ min: 0.1, max: 0.9, smoothness: 1 }),
    params({ min: 0.2, max: 0.6, smoothness: 0.3, colorEnabled: true, colorR: 0.5, colorG: 0.5, colorB: 0.5, colorAmount: 0.4 }),
  ];
  let mismatches = 0, worst = 0;
  for (const p of cases) {
    const alpha = core.buildRangeAlpha(proxy, p);
    for (let i = 0; i < alpha.length; i++) {
      const want = refAlpha(proxy.rgb[i * 3], proxy.rgb[i * 3 + 1], proxy.rgb[i * 3 + 2], p);
      if (alpha[i] !== want) { mismatches++; worst = Math.max(worst, Math.abs(alpha[i] - want)); }
    }
  }
  ok(mismatches === 0, `range equation matches the independent derivation (${mismatches} mismatches, worst ${worst})`);
}

// --- 2. identity and endpoint behaviour -----------------------------------
{
  const full = core.buildRangeAlpha(rampProxy(64, 8), params({ min: 0, max: 1, smoothness: 0.25 }));
  ok(full.length > 0 && full.every((v) => v === 255), 'a full window selects every pixel');
  const narrow = core.buildRangeAlpha(rampProxy(256, 2), params({ min: 0.4, max: 0.6, smoothness: 0.2 }));
  const row = narrow.subarray(0, 256);
  // Luma of a grey pixel is exactly its value/255, so the window maps directly
  // onto pixel positions: 0.4..0.6 of 255 is roughly x=102..153.
  ok(row[0] === 0 && row[255] === 0, 'outside the window nothing is selected');
  ok(row[128] === 255, 'well inside the window everything is selected');
  ok(partial(narrow) > 0 && partial(narrow) < narrow.length, 'the window has soft edges');
  // A tonal window must produce one contiguous band: the selection rises to a
  // single peak and falls away again, never oscillating with luma.
  let peak = 0;
  for (let x = 1; x < 256; x++) if (row[x] > row[peak]) peak = x;
  for (let x = 1; x <= peak; x++) assert(row[x] >= row[x - 1], `not non-decreasing before the peak at ${x}`);
  for (let x = peak + 1; x < 256; x++) assert(row[x] <= row[x - 1], `not non-increasing after the peak at ${x}`);
  ok(peak > 0 && peak < 255, 'the window selects a single contiguous tonal band');
  const degenerate = core.buildRangeAlpha(rampProxy(256, 2), params({ min: 0.5, max: 0.5, smoothness: 0.05 }));
  const degenerateCoverage = coverage(degenerate);
  ok(degenerateCoverage > 0 && degenerateCoverage < 0.2,
    'a zero-width window selects a thin tonal band rather than everything');
}

// --- 3. smoothness widens the transition ----------------------------------
{
  const proxy = rampProxy(256, 2);
  const counts = [0, 0.1, 0.3, 0.6, 1].map((s) =>
    partial(core.buildRangeAlpha(proxy, params({ min: 0.35, max: 0.65, smoothness: s }))));
  for (let i = 1; i < counts.length; i++) {
    assert(counts[i] >= counts[i - 1],
      `smoothness ${i} produced fewer partial pixels (${counts[i]} < ${counts[i - 1]})`);
  }
  checks++;
  ok(counts[counts.length - 1] > counts[0], 'higher smoothness produces a softer edge');
}

// --- 4. colour range ------------------------------------------------------
{
  const proxy = twoColorProxy(64, 8);
  const red = core.buildRangeAlpha(proxy, params({
    min: 0, max: 1, smoothness: 0.25, colorEnabled: true,
    colorR: 1, colorG: 0, colorB: 0, colorAmount: 0.3,
  }));
  const mid = 4 * 64 + 10, right = 4 * 64 + 54;
  ok(red[mid] === 255, 'the picked colour is fully selected');
  ok(red[right] === 0, 'a distant colour is not selected');
  // A colour match is soft, so inclusivity is measured as total selection
  // weight rather than above a hard threshold: a distant colour is partially
  // included long before it is fully included.
  const amounts = [0, 0.2, 0.5, 0.8, 1].map((a) => mass(core.buildRangeAlpha(proxy, params({
    min: 0, max: 1, colorEnabled: true, colorR: 0.5, colorG: 0.5, colorB: 0.5, colorAmount: a,
  }))));
  for (let i = 1; i < amounts.length; i++) {
    assert(amounts[i] >= amounts[i - 1] - 1e-9, `colour amount ${i} reduced the selection mass`);
  }
  checks++;
  ok(amounts[amounts.length - 1] > amounts[0], 'higher colour amount is more inclusive');
  ok(amounts[0] === 0, 'a tight colour match excludes distant colours entirely');
}

// --- 5. luminance and colour are ANDed -----------------------------------
{
  const proxy = twoColorProxy(64, 8);
  const base = { min: 0.1, max: 0.6, smoothness: 0.2, colorR: 1, colorG: 0, colorB: 0, colorAmount: 0.5 };
  const lumaOnly = coverage(core.buildRangeAlpha(proxy, params(Object.assign({}, base, { colorEnabled: false }))));
  const both = coverage(core.buildRangeAlpha(proxy, params(Object.assign({}, base, { colorEnabled: true }))));
  ok(both <= lumaOnly + 1e-9, 'enabling the colour range never widens the selection (AND, not OR)');
}

// --- 6. proxy downsampling -----------------------------------------------
{
  // A 2x2 checkerboard downsampled to 1x1 must be the average, not one sample.
  const rgba = new Uint8Array([0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255]);
  const one = core.buildProxy(rgba, 2, 2, 1);
  ok(one.width === 1 && one.height === 1, 'proxy respects the requested maximum edge');
  ok(Math.abs(one.rgb[0] - 128) <= 1, `box average of a checkerboard is the mean (got ${one.rgb[0]})`);
  const scaled = core.buildProxy(new Uint8Array(400 * 200 * 4), 400, 200, 100);
  ok(scaled.width === 100 && scaled.height === 50, 'proxy keeps the aspect ratio while bounding the long edge');
  const tiny = core.buildProxy(new Uint8Array(3 * 2 * 4), 3, 2, 192);
  ok(tiny.width === 3 && tiny.height === 2, 'a source smaller than the limit is not upscaled');
  const short = core.buildProxy(new Uint8Array(4), 8, 8, 192);
  ok(short.rgb.length === 64 * 3 && short.rgb.every((v) => v === 0),
    'a short buffer degrades to zeros instead of reading out of bounds');
}

// --- 7. automatic window --------------------------------------------------
{
  // A ramp occupying only the middle of the tonal range must not return 0..1.
  const rgb = new Uint8Array(256 * 3);
  for (let i = 0; i < 256; i++) { const v = i; rgb[i * 3] = v; rgb[i * 3 + 1] = v; rgb[i * 3 + 2] = v; }
  const win = core.luminanceWindow({ width: 256, height: 1, rgb });
  ok(win.min > 0 && win.max < 1, `the automatic window is data-derived (${win.min.toFixed(2)}..${win.max.toFixed(2)})`);
  ok(win.min < 0.12 && win.max > 0.88, 'the automatic window tracks the 5th/95th percentile');
  const flat = core.luminanceWindow({ width: 4, height: 1, rgb: new Uint8Array([90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90]) });
  ok(flat.max - flat.min >= 0.08 - 1e-9, 'a flat image still yields a usable window instead of a zero-width one');
}

// --- 8. colour sampling from the current selection ------------------------
{
  const proxy = twoColorProxy(64, 8);
  const count = 64 * 8;
  ok(core.averageSelectedColor(proxy, new Uint8Array(count)) === null,
    'sampling with nothing selected reports null instead of an arbitrary colour');
  const all = core.averageSelectedColor(proxy, new Uint8Array(count).fill(255));
  ok(all !== null && Math.abs(all[0] - 0.5) < 0.01 && Math.abs(all[2] - 0.5) < 0.01,
    'sampling the whole frame returns the mean of its colours');
  const leftOnly = new Uint8Array(count);
  for (let y = 0; y < 8; y++) for (let x = 0; x < 32; x++) leftOnly[y * 64 + x] = 255;
  const red = core.averageSelectedColor(proxy, leftOnly);
  ok(red !== null && red[0] > 0.99 && red[1] < 0.01 && red[2] < 0.01,
    'sampling a partial selection returns that selection\'s colour');
  // A short alpha buffer must be handled by length, not by over-reading.
  const short = core.averageSelectedColor(proxy, new Uint8Array(4).fill(255));
  ok(short !== null, 'a short alpha buffer is bounded rather than read out of range');
}

// --- 9. provenance signature ---------------------------------------------
{
  const a = core.rangeSignature(params({ min: 0.2, max: 0.8, smoothness: 0.25 }));
  const b = core.rangeSignature(params({ min: 0.2, max: 0.8, smoothness: 0.25 }));
  const c = core.rangeSignature(params({ min: 0.2, max: 0.9, smoothness: 0.25 }));
  ok(a === b, 'the signature is stable for identical parameters');
  ok(a !== c, 'the signature changes when the parameters change');
  const off = core.rangeSignature(params({ min: 0.2, max: 0.8, colorEnabled: false }));
  const on = core.rangeSignature(params({ min: 0.2, max: 0.8, colorEnabled: true, colorR: 1, colorG: 0, colorB: 0, colorAmount: 0.3 }));
  ok(off !== on, 'enabling the colour range changes the signature');
}

// --- 9. determinism -------------------------------------------------------
{
  const proxy = rampProxy(96, 5);
  const p = params({ min: 0.25, max: 0.75, smoothness: 0.4, colorEnabled: true, colorR: 0.6, colorG: 0.4, colorB: 0.2, colorAmount: 0.5 });
  const first = core.buildRangeAlpha(proxy, p), second = core.buildRangeAlpha(proxy, p);
  ok(first.every((v, i) => v === second[i]), 'the range builder is deterministic');
}

// --- 10. integration through the real mask pipeline -----------------------
{
  const width = 320, height = 240;
  const proxy = twoColorProxy(120, 20);
  const p = params({ min: 0, max: 1, smoothness: 0.25, colorEnabled: true, colorR: 1, colorG: 0, colorB: 0, colorAmount: 0.3 });
  const raster = RangeMaskService.buildRaster(proxy, p);
  ok(raster.origin === M.RASTER_ORIGIN_RANGE, 'a range raster records its origin');
  ok(raster.key === core.rangeSignature(p), 'a range raster records its parameter signature');
  ok(raster.width === proxy.width && raster.height === proxy.height,
    'a range raster is stored at the proxy resolution, not the source resolution');

  const session = new EditSession();
  session.ensureBaseLayer();
  const layer = session.createMaskLayer(T.RANGE);
  const component = layer.components[0];
  ok(component.rangeData !== null, 'a range component is created with default parameters');
  // The parameters the raster was built from live on the component, which is
  // what makes a reopened mask editable instead of merely visible.
  component.rangeData = p;
  ok(session.isRasterMaskComponent(component), 'a range component is treated as a raster component');
  ok(component.feather === 0, 'a range component does not add a second feather on top of its window');
  ok(M.maskWorkerType(T.RANGE) === 5, 'a range component maps to worker type 5');
  ok(M.isRasterComponentType(T.RANGE) && M.isRasterComponentType(T.SUBJECT) &&
    !M.isRasterComponentType(T.BRUSH), 'only raster-backed types report as raster components');

  ok(session.setMaskComponentRaster(component.id, raster.origin, raster.key,
    raster.width, raster.height, raster.alpha), 'the range raster attaches to its component');
  const alpha = MaskRenderer.renderComponent(component, width, height);
  ok(coverage(alpha) > 0.4 && coverage(alpha) < 0.6,
    'the range selection covers the picked colour and only that colour');
  ok(alpha[Math.floor(height / 2) * width + 10] > 250 && alpha[Math.floor(height / 2) * width + width - 10] < 5,
    'the left (picked) half is selected and the right half is not');

  // Composition must reuse the shared algebra.
  const subtract = session.addMaskComponent(T.RANGE, O.SUBTRACT);
  session.setMaskComponentRaster(subtract.id, M.RASTER_ORIGIN_RANGE, 'x', 1, 1, new Uint8Array([255]));
  const composed = MaskRenderer.renderMaskLayer(layer, width, height);
  ok(composed.every((v) => v === 0), 'a fully opaque range subtract removes the selection');
  session.deleteMaskComponent(subtract.id);

  // Worker/export parity.
  const workerLayer = ImageProcessor.plainMaskLayer(layer);
  const workerAlpha = new Uint8ClampedArray(rasterizeStructuredMaskCore(workerLayer, width, height));
  const uiAlpha = MaskRenderer.renderMaskLayer(layer, width, height);
  ok(workerAlpha.every((v, i) => v === uiAlpha[i]),
    'the worker/export path renders a range mask identically to the overlay');
  ok(workerLayer.components.some((c) => c.bitmap && c.bitmap.width === proxy.width),
    'the range raster is carried into the worker layer');

  // Sidecar round trip: parameters and raster both survive.
  const restored = new EditSession();
  ok(restored.importAdjustmentState(session.exportAdjustmentState()), 'state imports');
  const restoredComponent = restored.layers[0].maskLayers[0].components[0];
  ok(restoredComponent.raster !== null && restoredComponent.raster.hasAlpha,
    'the range raster survives serialisation');
  ok(restoredComponent.raster.origin === M.RASTER_ORIGIN_RANGE, 'the restored raster keeps its origin');
  ok(Array.from(restoredComponent.raster.alpha).every((v, i) => v === raster.alpha[i]),
    'restored raster bytes are identical');
  const rp = restoredComponent.rangeData;
  ok(rp !== null, 'the range parameters survive serialisation');
  ok(rp.colorEnabled && Math.abs(rp.colorR - 1) < 1e-9 && Math.abs(rp.colorAmount - 0.3) < 1e-9,
    'the restored parameters match the ones that produced the raster');
  ok(core.rangeSignature(rp) === raster.key,
    'the restored parameters regenerate the recorded signature, so a reopened mask is editable');
  const restoredAlpha = MaskRenderer.renderComponent(restoredComponent, width, height);
  ok(restoredAlpha.every((v, i) => v === alpha[i]), 'a reopened project renders the same range mask');

  // A damaged sidecar must not become a full-frame selection. The snapshot is
  // JSON, so it is edited as a parsed document and re-serialised.
  const damaged = JSON.parse(session.exportAdjustmentState());
  damaged.layers[0].maskLayers[0].components[0].rasterAlpha = Buffer.from([1, 2, 3]).toString('base64');
  const broken = new EditSession();
  ok(broken.importAdjustmentState(JSON.stringify(damaged)), 'damaged state still imports');
  const brokenComponent = broken.layers[0].maskLayers[0].components[0];
  ok(brokenComponent.raster === null,
    'a truncated raster is dropped rather than trusted');
  const brokenAlpha = MaskRenderer.renderComponent(brokenComponent, width, height);
  ok(brokenAlpha.every((v) => v === 0), 'a dropped raster selects nothing, not everything');

  // recompute() must refresh an existing component...
  // Red has Rec.709 luma 0.213 and blue 0.072, so a window up to 0.5 contains
  // both, and one up to 0.1 contains only the blue patch. That is the whole
  // point of a tonal window: it discriminates by luma, not by colour.
  const updated = params({ min: 0, max: 0.5, smoothness: 0.25 });
  ok(RangeMaskService.recompute(session, component.id, updated, proxy),
    'recompute refreshes an existing range component');
  const afterUpdate = MaskRenderer.renderComponent(component, width, height);
  ok(coverage(afterUpdate) > 0.999, 'a window containing both patches selects the whole frame');
  const darkOnly = params({ min: 0, max: 0.1, smoothness: 0.25 });
  ok(RangeMaskService.recompute(session, component.id, darkOnly, proxy),
    'recompute accepts a narrowed window');
  const darkAlpha = MaskRenderer.renderComponent(component, width, height);
  ok(Math.abs(coverage(darkAlpha) - 0.5) < 0.06,
    'narrowing the window below the brighter patch leaves about half the frame');
  const midRow = Math.floor(height / 2) * width;
  ok(darkAlpha[midRow + 10] < 5 && darkAlpha[midRow + width - 10] > 200,
    'the tonal window drops the brighter patch and keeps the darker one');
  // ...and must refuse a component that is gone.
  ok(RangeMaskService.recompute(session, 'missing-id', updated, proxy) === false,
    'recompute refuses a deleted component instead of resurrecting it');
}

// --- 11. proxy cache is invalidated with the source ----------------------
{
  const session = new EditSession();
  session.imageWidth = 100; session.imageHeight = 50;
  const token = RangeMaskService.tokenFor(session);
  ok(token.indexOf(`${session.sessionId}:`) === 0, 'the proxy token is scoped to the session');
  // Seed the cache through the real store path, then confirm clearSourceCache
  // drops it. Without this a range mask rebuilt after an image switch would be
  // thresholded against the previous photo's tonal distribution.
  const proxy = twoColorProxy(4, 2);
  RangeMaskService['store'](token, proxy);
  ok(RangeMaskService.cachedProxy(token) !== null, 'the proxy is cached for the session');
  ImageProcessor.clearSourceCache(session);
  ok(RangeMaskService.cachedProxy(token) === null,
    'changing the source drops the cached proxy');
}

console.log(`range mask: ${checks} checks passed`);
