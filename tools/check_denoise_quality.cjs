// Denoise quality/parity/cache-key regression suite (Task C).
//
// Independent of tools/check_denoise_masks.cjs: every assertion here is made
// against the *real* NoiseReduction.ets kernel, the real ProcessWorker entry
// point and the real ImageProcessor cache, on synthetic data whose ground truth
// is known analytically (flat fields, a step edge, coloured speckle). The
// kernel is never re-implemented and compared with itself.
//
//   (a) strength 0 is a bit-exact identity (kernel, worker and cached path)
//   (b) Gaussian noise variance drops materially at high strength
//   (c) a synthetic sharp edge keeps >= 90% of its contrast
//   (d) coloured speckle is removed without destroying luminance structure
//   (e) preview-scale and export-scale results of one scene are statistically
//       equivalent (the spatial window follows the frame long edge)
//   (f) the retained-stage cache key reacts to every one of the four settings
//       and to retouch/viewport/source changes, and ignores unrelated state
//   (g) the GLES2 denoise GLSL still matches NoiseReduction.ets term by term
const fs = require('fs'), path = require('path'), assert = require('assert');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets'), cache = new Map(), storage = new Map();
let canceled = false, noiseTasks = 0, failures = 0, checks = 0;

// The TypeScript loader evaluates module scope (not a fresh vm context): a vm
// context makes Math/typed-array access ~24x slower, which would dominate the
// resolution-scaling measurements below.
const globals = { console, Math, Number, Date, Map, Set, Promise, ArrayBuffer, Uint8Array,
  Uint8ClampedArray, Uint32Array, Float32Array, setTimeout, clearTimeout,
  Observed: (target) => target, Concurrent: (target) => target };
function load(file) {
  file = path.resolve(file);
  if (cache.has(file)) return cache.get(file).exports;
  const mod = { exports: {} }; cache.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'),
    { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021,
      experimentalDecorators: true } }).outputText;
  const require = (name) => {
    if (name === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0) } };
    if (name === '@kit.ArkTS') {
      return { taskpool: { Task: class {
        static isCanceled() { return canceled; }
        constructor(fn, ...args) { this.fn = fn; this.args = args; }
      }, execute: async (task) => { if (task.fn.name === 'denoiseTask') noiseTasks++; return task.fn(...task.args); } } };
    }
    if (name.startsWith('@kit.')) return { hilog: { info() {}, warn() {}, error() {} } };
    // ImageProcessor now clears the AI segmentation cache alongside the other
    // source-derived caches, so its module graph reaches the native AI binding.
    if (name === 'libvivid_ai.so') {
      return { default: { isLoaded: () => false, load: async () => false,
        segment: async () => new ArrayBuffer(0), release() {}, modelInfo: () => [] } };
    }
    if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), name + '.ets'));
  };
  const AppStorage = { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) };
  const names = Object.keys(globals), values = names.map((n) => globals[n]);
  new Function(...names, 'exports', 'module', 'require', 'AppStorage', js)(
    ...values, mod.exports, mod, require, AppStorage);
  return mod.exports;
}

const { denoiseRows, denoiseEnabled, denoiseSpatialRadius,
  DENOISE_REFERENCE_LONG_EDGE, DENOISE_MAX_RADIUS } = load(root + '/edit/engine/NoiseReduction.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { DenoiseSettings } = load(root + '/edit/models/DenoiseSettings.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { ImageProcessor: P } = load(root + '/edit/engine/ImageProcessor.ets');

function check(name, fn) {
  checks++;
  try { fn(); console.log('PASS ' + name); }
  catch (error) { failures++; console.log('FAIL ' + name + ' :: ' + (error && error.message ? error.message : error)); }
}
async function checkAsync(name, fn) {
  checks++;
  try { await fn(); console.log('PASS ' + name); }
  catch (error) { failures++; console.log('FAIL ' + name + ' :: ' + (error && error.message ? error.message : error)); }
}
function near(actual, expected, tolerance, message) {
  assert(Math.abs(actual - expected) <= tolerance,
    message + ' (actual=' + actual.toFixed(4) + ' expected=' + expected + ' +/-' + tolerance + ')');
}

// ---------------------------------------------------------------- synthetic data
let seed = 20261012;
function rnd() { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; }
function gauss(sigma) { // Box-Muller, deterministic
  const u = Math.max(1e-9, rnd());
  return sigma * Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rnd());
}
function blank(w, h, r, g, b, a) {
  const out = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < out.length; i += 4) { out[i] = r; out[i + 1] = g; out[i + 2] = b; out[i + 3] = a; }
  return out;
}
function pixels(w, h, fn) { // fn(x, y) -> [r,g,b] in linear code values
  const out = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const c = fn(x, y), i = (y * w + x) * 4;
    out[i] = c[0]; out[i + 1] = c[1]; out[i + 2] = c[2]; out[i + 3] = 255;
  }
  return out;
}
function run(src, w, h, settings) {
  const out = new Uint8ClampedArray(src.length);
  denoiseRows(src, out, w, h, settings, 0, h);
  return out;
}
function stats(bytes, w, x0, x1, y0, y1, channel = 0) {
  let n = 0, sum = 0, square = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const v = bytes[(y * w + x) * 4 + channel]; n++; sum += v; square += v * v;
  }
  const mean = sum / n;
  return { mean, variance: Math.max(0, square / n - mean * mean), count: n };
}
function luma(bytes, i) { return 0.2126 * bytes[i] + 0.7152 * bytes[i + 1] + 0.0722 * bytes[i + 2]; }
function lumaStats(bytes, w, x0, x1, y0, y1) {
  let n = 0, sum = 0, square = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const v = luma(bytes, (y * w + x) * 4); n++; sum += v; square += v * v;
  }
  const mean = sum / n;
  return { mean, variance: Math.max(0, square / n - mean * mean) };
}
function chromaEnergy(bytes, w, x0, x1, y0, y1) {
  let n = 0, sum = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const i = (y * w + x) * 4, dr = bytes[i] - bytes[i + 1], db = bytes[i + 2] - bytes[i + 1];
    sum += dr * dr + db * db; n++;
  }
  return sum / n;
}
function columnMean(bytes, w, x, y0, y1) {
  let sum = 0; for (let y = y0; y < y1; y++) sum += bytes[(y * w + x) * 4];
  return sum / (y1 - y0);
}
// Exact area-average resample, the same class of scaler the editor preview uses.
function resample(src, w, h, tw, th) {
  const out = new Uint8ClampedArray(tw * th * 4);
  for (let y = 0; y < th; y++) {
    const y0 = y * h / th, y1 = (y + 1) * h / th;
    for (let x = 0; x < tw; x++) {
      const x0 = x * w / tw, x1 = (x + 1) * w / tw;
      let r = 0, g = 0, b = 0, a = 0, weight = 0;
      for (let sy = Math.floor(y0); sy < Math.ceil(y1); sy++) {
        const wy = Math.min(y1, sy + 1) - Math.max(y0, sy);
        for (let sx = Math.floor(x0); sx < Math.ceil(x1); sx++) {
          const wx = Math.min(x1, sx + 1) - Math.max(x0, sx);
          const area = wx * wy, i = (sy * w + sx) * 4;
          r += src[i] * area; g += src[i + 1] * area; b += src[i + 2] * area; a += src[i + 3] * area;
          weight += area;
        }
      }
      const o = (y * tw + x) * 4;
      out[o] = r / weight; out[o + 1] = g / weight; out[o + 2] = b / weight; out[o + 3] = a / weight;
    }
  }
  return out;
}

const measured = {};
console.log('kernel constants: referenceLongEdge=' + DENOISE_REFERENCE_LONG_EDGE +
  ' maxRadius=' + DENOISE_MAX_RADIUS);
console.log('spatial radius: 512->' + denoiseSpatialRadius(512, 384) + '  1024->' + denoiseSpatialRadius(1024, 768) +
  '  2048->' + denoiseSpatialRadius(2048, 1536) + '  3072->' + denoiseSpatialRadius(3072, 2048) +
  '  4096->' + denoiseSpatialRadius(4096, 3072) + '  5120->' + denoiseSpatialRadius(5120, 3840) +
  '  8192->' + denoiseSpatialRadius(8192, 6144));

// ------------------------------------------------------------------ (a) identity
check('(a) strength 0 is a bit-exact identity in the kernel', () => {
  const w = 96, h = 72;
  const src = pixels(w, h, (x, y) => {
    const base = x < w / 2 ? 40 : 200;
    const v = base + gauss(6);
    return [v, v - 3 + gauss(2), v + 5 + gauss(2)];
  });
  for (const settings of [
    { luminance: 0, color: 0, detail: 0, colorDetail: 0 },
    { luminance: 0, color: 0, detail: 1, colorDetail: 1 },
    { luminance: 0, color: 0, detail: 0.5, colorDetail: 0.5 },
  ]) {
    const out = run(src, w, h, settings);
    assert.deepStrictEqual(Buffer.from(out), Buffer.from(src),
      'zero-strength denoise must not re-encode any byte');
  }
  // Banded calls must also be exact, and must only touch their own rows.
  const banded = new Uint8ClampedArray(src.length);
  for (let y = 0; y < h; y += 7) denoiseRows(src, banded, w, h, { luminance: 0, color: 0, detail: 0.5, colorDetail: 0.5 }, y, Math.min(h, y + 7));
  assert.deepStrictEqual(Buffer.from(banded), Buffer.from(src), 'banded zero-strength must be exact');
  assert.strictEqual(denoiseEnabled(new DenoiseSettings()), false);
  assert.strictEqual(denoiseEnabled({ luminance: 0, color: 0, detail: 1, colorDetail: 1 }), false,
    'detail alone must not enable the stage');
  assert.strictEqual(denoiseEnabled({ luminance: 0.01, color: 0, detail: 0, colorDetail: 0 }), true);
});

check('(a) the worker skips the stage entirely at zero', () => {
  const w = 64, h = 48, src = pixels(w, h, (x, y) => [x * 2 + gauss(4), y * 3, 128]);
  const params = (denoise) => ({
    denoise, viewport: [], geometry: [], source: src.slice().buffer, width: w, height: h,
    referenceWidth: w, referenceHeight: h, layers: [], luts: [],
    cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1, rotation: 0,
    flipH: false, flipV: false, applyGeometry: false, ignoreCrop: false,
  });
  const withoutStage = new Uint8ClampedArray(processPixels(params(undefined)).buffer);
  const zeroStage = new Uint8ClampedArray(processPixels(params({ luminance: 0, color: 0, detail: 1, colorDetail: 1 })).buffer);
  assert.deepStrictEqual(Buffer.from(zeroStage), Buffer.from(withoutStage),
    'zero settings must produce exactly the same pixels as no denoise stage at all');
});

// ---------------------------------------------------------- (b) noise variance
check('(b) Gaussian noise variance drops materially at high strength', () => {
  const w = 128, h = 128;
  const src = pixels(w, h, () => { const v = 128 + gauss(8); return [v, v, v]; });
  const before = stats(src, w, 8, w - 8, 8, h - 8).variance;
  const out = run(src, w, h, { luminance: 1, color: 0, detail: 0, colorDetail: 0.5 });
  const after = stats(out, w, 8, w - 8, 8, h - 8).variance;
  measured.flatNoiseVarianceBefore = before;
  measured.flatNoiseVarianceAfter = after;
  measured.flatNoiseReduction = before / Math.max(1e-9, after);
  assert(measured.flatNoiseReduction >= 4,
    'flat-field noise variance must drop at least 4x, got ' + measured.flatNoiseReduction.toFixed(2) + 'x');
  // The residual must stay centred on the clean value (no level shift/tint).
  near(stats(out, w, 8, w - 8, 8, h - 8).mean, 128, 1.0, 'denoised flat field must keep its level');
  // Low strength must smooth less than high strength (monotone control).
  const low = run(src, w, h, { luminance: 0.25, color: 0, detail: 0, colorDetail: 0.5 });
  assert(stats(low, w, 8, w - 8, 8, h - 8).variance > after, 'stronger luminance NR must smooth more');
  // The "detail" slider must preserve more texture, not less.
  const detailed = run(src, w, h, { luminance: 1, color: 0, detail: 1, colorDetail: 0.5 });
  measured.detailVariance = stats(detailed, w, 8, w - 8, 8, h - 8).variance;
  assert(measured.detailVariance > after, 'detail=1 must retain more high-frequency noise than detail=0');
});

// ------------------------------------------------------------ (c) edge contrast
check('(c) a sharp edge keeps >= 90% of its contrast', () => {
  const w = 128, h = 96, edge = w >> 1, low = 55, high = 195;
  const clean = pixels(w, h, (x) => { const v = x < edge ? low : high; return [v, v, v]; });
  const noisy = pixels(w, h, (x) => { const v = (x < edge ? low : high) + gauss(6); return [v, v, v]; });
  const out = run(noisy, w, h, { luminance: 1, color: 1, detail: 0, colorDetail: 0 });
  const y0 = 6, y1 = h - 6;
  const contrast = (b, left, right) => columnMean(b, w, right, y0, y1) - columnMean(b, w, left, y0, y1);
  const cleanContrast = contrast(clean, edge - 4, edge + 3);
  const outContrast = contrast(out, edge - 4, edge + 3);
  const coreRatio = (contrast(out, edge - 1, edge) / contrast(clean, edge - 1, edge));
  measured.cleanEdgeContrast = cleanContrast;
  measured.denoisedEdgeContrast = outContrast;
  measured.edgeContrastRatio = outContrast / cleanContrast;
  measured.edgeCoreRatio = coreRatio;
  assert(outContrast / cleanContrast >= 0.9,
    'edge contrast must stay >=90%, got ' + (100 * outContrast / cleanContrast).toFixed(1) + '%');
  assert(coreRatio >= 0.9,
    'the pixel pair straddling the edge must stay >=90% apart, got ' + (100 * coreRatio).toFixed(1) + '%');
  // Both flats must keep their own level (no halo bleeding across the edge).
  near(columnMean(out, w, edge - 12, y0, y1), low, 2.5, 'dark side level');
  near(columnMean(out, w, edge + 11, y0, y1), high, 2.5, 'bright side level');
  // And the same edge in the *export* spatial regime must not smear it either.
  const wide = 5120, tall = 128, wideEdge = wide >> 1;
  const wideNoisy = pixels(wide, tall, (x) => {
    const v = (x < wideEdge ? low : high) + gauss(6); return [v, v, v];
  });
  const wideOut = run(wideNoisy, wide, tall, { luminance: 1, color: 1, detail: 0, colorDetail: 0 });
  const wideRatio = (columnMean(wideOut, wide, wideEdge + 23, 6, tall - 6) -
    columnMean(wideOut, wide, wideEdge - 24, 6, tall - 6)) / (high - low);
  measured.wideEdgeContrastRatio = wideRatio;
  assert(wideRatio >= 0.9, 'export-scale edge contrast must stay >=90%, got ' + (100 * wideRatio).toFixed(1) + '%');
});

// --------------------------------------------------- (d) chroma vs luminance
check('(d) coloured speckle is removed without destroying luminance structure', () => {
  const w = 128, h = 96, edge = w >> 1;
  const lumaAt = (x) => (x < edge ? 70 : 170);
  const clean = pixels(w, h, (x) => { const y = lumaAt(x); return [y, y, y]; });
  const speckled = pixels(w, h, (x) => { const y = lumaAt(x); return [y + gauss(7), y + gauss(7), y + gauss(7)]; });
  const out = run(speckled, w, h, { luminance: 0, color: 1, detail: 0, colorDetail: 0.5 });
  const before = chromaEnergy(speckled, w, 6, w - 6, 6, h - 6);
  const after = chromaEnergy(out, w, 6, w - 6, 6, h - 6);
  measured.chromaEnergyBefore = before;
  measured.chromaEnergyAfter = after;
  measured.chromaReduction = before / Math.max(1e-9, after);
  assert(measured.chromaReduction >= 3,
    'chroma speckle energy must drop >=3x, got ' + measured.chromaReduction.toFixed(2) + 'x');
  // A chroma-only pass must not rebuild luminance: the luma structure (edge
  // contrast and per-column luma profile) has to survive.
  const cleanLuma = lumaStats(clean, w, 4, edge - 4, 6, h - 6).mean;
  const outLuma = lumaStats(out, w, 4, edge - 4, 6, h - 6).mean;
  const cleanBright = lumaStats(clean, w, edge + 4, w - 4, 6, h - 6).mean;
  const outBright = lumaStats(out, w, edge + 4, w - 4, 6, h - 6).mean;
  measured.chromaPassLumaDriftDark = Math.abs(outLuma - cleanLuma);
  measured.chromaPassLumaDriftBright = Math.abs(outBright - cleanBright);
  assert(Math.abs(outLuma - cleanLuma) <= 2.5, 'dark-side luma must survive a chroma-only pass');
  assert(Math.abs(outBright - cleanBright) <= 2.5, 'bright-side luma must survive a chroma-only pass');
  // The luminance *noise* of the chroma-only pass must be essentially unchanged
  // (i.e. the pass really is chroma-only).
  const lumaNoise = (b) => { let n = 0, s = 0, q = 0; for (let y = 6; y < h - 6; y++) for (let x = 6; x < edge - 6; x++) { const v = luma(b, (y * w + x) * 4); n++; s += v; q += v * v; } return q / n - (s / n) ** 2; };
  measured.chromaPassLumaNoiseBefore = lumaNoise(speckled);
  measured.chromaPassLumaNoiseAfter = lumaNoise(out);
  assert(measured.chromaPassLumaNoiseAfter > 0.5 * measured.chromaPassLumaNoiseBefore,
    'a chroma-only pass must not smooth luminance');
});

// ------------------------------------------------------------- (e) parity
check('(e) preview-scale and export-scale results are statistically equivalent', () => {
  const EW = 5120, EH = 128, PW = 2048, PH = 51; // k = 2.5, both radii from the shipped formula
  const edgeE = EW >> 1, low = 60, high = 190;
  const sceneAt = (x, y, sigma) => {
    const base = x < edgeE ? low : high;
    const v = base + gauss(sigma);
    return [v, v, v];
  };
  const exportNoisy = pixels(EW, EH, (x) => sceneAt(x, 0, 5));
  const exportClean = pixels(EW, EH, (x) => { const v = x < edgeE ? low : high; return [v, v, v]; });
  const previewNoisy = resample(exportNoisy, EW, EH, PW, PH);
  const previewClean = resample(exportClean, EW, EH, PW, PH);
  const settings = { luminance: 1, color: 0, detail: 0, colorDetail: 0.5 };
  // Export pipeline: filter at full size, then view at the preview size.
  const exportDisplayed = resample(run(exportNoisy, EW, EH, settings), EW, EH, PW, PH);
  // Preview pipeline: the editor filters the already downsampled frame.
  const previewFiltered = run(previewNoisy, PW, PH, settings);
  const residual = (a, b) => { // variance of the filter's error on the preview grid
    let n = 0, s = 0, q = 0;
    for (let y = 4; y < PH - 4; y++) for (let x = 60; x < PW / 2 - 60; x++) {
      const d = a[(y * PW + x) * 4] - b[(y * PW + x) * 4]; n++; s += d; q += d * d;
    }
    return Math.max(0, q / n - (s / n) ** 2);
  };
  const previewResidual = residual(previewFiltered, previewClean);
  const exportResidual = residual(exportDisplayed, previewClean);
  measured.previewRadius = denoiseSpatialRadius(PW, PH);
  measured.exportRadius = denoiseSpatialRadius(EW, EH);
  measured.previewResidualVariance = previewResidual;
  measured.exportResidualVariance = exportResidual;
  measured.parityResidualRatio = exportResidual / Math.max(1e-9, previewResidual);
  measured.parityStdRatio = Math.sqrt(measured.parityResidualRatio);
  assert(measured.exportRadius > measured.previewRadius,
    'the export frame must get a wider window than the preview');
  assert(measured.parityResidualRatio >= 0.55 && measured.parityResidualRatio <= 1.8,
    'export/preview residual variance ratio must be ~1, got ' + measured.parityResidualRatio.toFixed(2) +
    ' (std ' + measured.parityStdRatio.toFixed(2) + ')');
  // Edge parity: the export must not keep a visibly harder edge than the preview.
  const contrast = (b) => columnMean(b, PW, PW / 2 + 23, 6, PH - 6) - columnMean(b, PW, PW / 2 - 24, 6, PH - 6);
  measured.parityPreviewEdge = contrast(previewFiltered);
  measured.parityExportEdge = contrast(exportDisplayed);
  assert(contrast(exportDisplayed) / contrast(previewFiltered) > 0.85 &&
    contrast(exportDisplayed) / contrast(previewFiltered) < 1.15,
    'preview and export must agree on edge contrast, got ' +
    (contrast(exportDisplayed) / contrast(previewFiltered)).toFixed(3));
});

// --------------------------------------------------------- (f) cache key
async function cacheKeyChecks() {
  const w = 96, h = 64;
  const src = pixels(w, h, (x, y) => { const v = (x < w / 2 ? 60 : 190) + gauss(5); return [v, v, v]; });
  const session = new EditSession(); session.ensureBaseLayer();
  session.denoise = DenoiseSettings.restore({ luminance: 1, color: 1, detail: 0.5, colorDetail: 0.5 });
  const pixelMap = { readPixelsToBuffer: async (b) => new Uint8Array(b).set(src) };
  const render = (pm = pixelMap, source = src) =>
    P.renderToBuffer(pm, w, h, session, true, () => false, true, source.slice().buffer, true);
  noiseTasks = 0;
  await render();
  assert.strictEqual(noiseTasks, 1, 'the first frame must run the retained stage once');
  await render();
  assert.strictEqual(noiseTasks, 1, 'an identical frame must reuse the retained result');
  for (const [key, value] of [['luminance', 0.6], ['color', 0.4], ['detail', 0.9], ['colorDetail', 0.1]]) {
    const before = noiseTasks;
    session.denoise[key] = value;
    await render();
    assert.strictEqual(noiseTasks, before + 1, 'changing "' + key + '" must invalidate the retained stage');
  }
  assert.strictEqual(noiseTasks, 5, 'four settings changes must produce four extra tasks');
  // Unrelated state: colour adjustments, curves, crop and geometry all run
  // *after* this stage and must not invalidate it.
  session.layers[0].adjustments.exposure = 0.35;
  session.layers[0].adjustments.toneCurve = 0.4;
  session.cropLeft = 0.05; session.cropTop = 0.05; session.cropRight = 0.95; session.cropBottom = 0.95;
  session.rotation = 90; session.flipH = true;
  await render();
  assert.strictEqual(noiseTasks, 5, 'post-stage edits must reuse the retained result');
  session.cropLeft = 0; session.cropTop = 0; session.cropRight = 1; session.cropBottom = 1;
  session.rotation = 0; session.flipH = false;
  // Retouch runs *before* the stage, so its marks must invalidate it.
  session.retouchMarks = [{ id: 'heal-1', kind: 'heal', x: 0.3, y: 0.3, radius: 0.06, feather: 0.5,
    amount: 1, sourceX: 0.4, sourceY: 0.4 }];
  await render();
  assert.strictEqual(noiseTasks, 6, 'retouch marks must invalidate the retained stage');
  session.retouchMarks = [];
  // A region render changes which pixels (and border clamps) this stage sees.
  session.renderViewport = [64, 32, 0.5, 0.5, w, h];
  await render();
  assert.strictEqual(noiseTasks, 7, 'the render viewport must invalidate the retained stage');
  session.renderViewport = [];
  // A new decoded source for the same session must invalidate it.
  const other = pixels(w, h, () => [10, 20, 30]);
  await render({ readPixelsToBuffer: async (b) => new Uint8Array(b).set(other) }, other);
  assert.strictEqual(noiseTasks, 8, 'a new decoded source must invalidate the retained stage');
  // Closing the session must drop its entries.
  P.clearSourceCache(session);
  await render();
  assert.strictEqual(noiseTasks, 9, 'closing the session must release the retained stage');
}

// ---------------------------------------------- (g) GLSL vs ArkTS agreement
check('(g) the GLES2 denoise GLSL matches NoiseReduction.ets term by term', () => {
  const cpp = fs.readFileSync('entry/src/main/cpp/vivid_gpu.cpp', 'utf8');
  const ets = fs.readFileSync('entry/src/main/ets/edit/engine/NoiseReduction.ets', 'utf8');
  const glslStart = cpp.indexOf('vec3 nrLinear(vec3 c)');
  const glsl = cpp.slice(glslStart, cpp.indexOf('void main(){', glslStart));
  assert(glslStart > 0 && glsl.length > 400, 'denoise GLSL block not found');
  // Frame-relative radius, clamped at the exported constants.
  const radiusFormula = glsl.match(/nrRadius\(\)\{return clamp\(floor\(([-\d.]+)\*max\(uFrameSize\.x,uFrameSize\.y\)\/(\d+)\.\+\.5\),([\d.]+),([\d.]+)\);\}/);
  assert(radiusFormula, 'nrRadius() must derive the window from the frame long edge');
  assert.strictEqual(Number(radiusFormula[2]), DENOISE_REFERENCE_LONG_EDGE,
    'GLSL reference long edge must equal DENOISE_REFERENCE_LONG_EDGE');
  assert.strictEqual(Number(radiusFormula[1]), 2, 'GLSL must use the same radius-2 anchor as ArkTS');
  assert.strictEqual(Number(radiusFormula[3]), 2, 'GLSL minimum radius must match the ArkTS floor');
  assert.strictEqual(Number(radiusFormula[4]), DENOISE_MAX_RADIUS,
    'GLSL maximum radius must equal DENOISE_MAX_RADIUS');
  assert(new RegExp('for\\(int y=-' + DENOISE_MAX_RADIUS + ';y<=' + DENOISE_MAX_RADIUS + ';y\\+\\+\\)').test(glsl),
    'GLSL loop bound must equal DENOISE_MAX_RADIUS (GLES2 needs a constant bound)');
  // Sigma formulas and every other term must be shared with the ArkTS kernel.
  assert(glsl.includes('float sl=.08+.55*uDenoise.x*(1.-.8*uDenoise.z)'), 'luminance sigma formula');
  assert(glsl.includes('float sc=.1+.65*uDenoise.y*(1.-.8*uDenoise.w)'), 'chroma sigma formula');
  assert(ets.includes('0.08 + 0.55 * lum * (1 - 0.8 * settings.detail)'), 'ArkTS luminance sigma formula');
  assert(ets.includes('0.1 + 0.65 * color * (1 - 0.8 * settings.colorDetail)'), 'ArkTS chroma sigma formula');
  assert(glsl.includes('float ss=radius*.5;') && ets.includes('const sigmaS = radius / 2;'),
    'the spatial sigma must be radius/2 on both sides');
  assert(glsl.includes('exp(-.5*dot(off,off)/(ss*ss))') &&
    ets.includes('Math.exp(-0.5 * (x * x + y * y) / (sigmaS * sigmaS))'),
    'the spatial Gaussian must be scaled identically');
  assert(glsl.includes('1.+(d/sl)*(d/sl)') && glsl.includes('1.+(d/sc)*(d/sc)') &&
    ets.includes('1 + dl * dl') && ets.includes('1 + dc * dc'),
    'the bounded range weight must be 1/(1+(d/sigma)^2) on both sides');
  assert(glsl.includes('sqrt(uDenoise.x)') && ets.includes('Math.sqrt(lum)'),
    'luminance strength must be sqrt(luminance) on both sides');
  assert(glsl.includes('uDenoise.y*(1.-.5*uDenoise.w)') && ets.includes('color * (1 - 0.5 * settings.colorDetail)'),
    'chroma mix must be color*(1-0.5*colorDetail) on both sides');
  assert(glsl.includes('d=ny-ly') && ets.includes('const delta = row[j + 3] - logY'),
    'both sides must weight by the log2-luminance difference');
  // sRGB transfer functions and the alpha pass-through.
  for (const token of ['0.04045', '12.92', '0.055', '1.055', '2.4']) {
    assert(glsl.includes(token) && ets.includes(token), 'sRGB decode constant ' + token + ' must match');
  }
  assert(glsl.includes('0.0031308') && ets.includes('0.0031308'), 'sRGB encode knee must match');
  assert(cpp.includes('vec4(reduceNoise(n.rgb),n.a)') && ets.includes('output[p + 3] = source[p + 3]'),
    'both sides must pass alpha through untouched');
  // strength 0 must skip the pass on the GPU too (main() gate).
  assert(cpp.includes('if(uDenoise.x>0.||uDenoise.y>0.){'), 'the GLSL main() must gate the stage on strength');
});

(async () => {
  await checkAsync('(a) the cached ImageProcessor path skips the stage at zero', async () => {
    const w = 64, h = 48, src = pixels(w, h, (x, y) => [x * 2 + gauss(4), y * 3, 128]);
    const session = new EditSession(); session.ensureBaseLayer();
    session.denoise = DenoiseSettings.restore({ luminance: 0, color: 0, detail: 0.5, colorDetail: 0.5 });
    const pixelMap = { readPixelsToBuffer: async (b) => new Uint8Array(b).set(src) };
    noiseTasks = 0;
    await P.renderToBuffer(pixelMap, w, h, session, true, () => false, true, src.slice().buffer, true);
    assert.strictEqual(noiseTasks, 0, 'zero settings must not schedule a denoise task at all');
  });
  await checkAsync('(f) a denoise re-run reuses the decoded source buffer', async () => {
    // The audit item behind this: moving a denoise slider must not re-decode the
    // RAW/DCP frame. With no source-buffer override the pipeline has to read the
    // PixelMap exactly once and then re-filter the retained decode.
    const w = 96, h = 64;
    const src = pixels(w, h, (x, y) => { const v = (x < w / 2 ? 60 : 190) + gauss(5); return [v, v, v]; });
    let reads = 0;
    const pixelMap = { readPixelsToBuffer: async (b) => { reads++; new Uint8Array(b).set(src); } };
    const session = new EditSession(); session.ensureBaseLayer();
    session.denoise = DenoiseSettings.restore({ luminance: 1, color: 1, detail: 0.5, colorDetail: 0.5 });
    noiseTasks = 0;
    await P.renderToBuffer(pixelMap, w, h, session, true, () => false, true, undefined, true);
    assert.strictEqual(reads, 1, 'the first frame must decode the source once');
    for (const value of [0.25, 0.75, 1]) {
      session.denoise.luminance = value;
      await P.renderToBuffer(pixelMap, w, h, session, true, () => false, true, undefined, true);
    }
    assert.strictEqual(reads, 1, 'denoise re-runs must not re-read (re-decode) the source pixels');
    // Three new settings produced three filters; sweeping the slider back to the
    // first value is served by the retained entry instead of filtering again.
    assert.strictEqual(noiseTasks, 3, 'only the three changed settings may filter');
    session.denoise.luminance = 0.25;
    await P.renderToBuffer(pixelMap, w, h, session, true, () => false, true, undefined, true);
    assert.strictEqual(noiseTasks, 3, 'returning to a retained setting must reuse it');
  });
  await checkAsync('(f) retained-stage cache key invalidation matrix', cacheKeyChecks);
  console.log('MEASURED ' + JSON.stringify(measured, null, 1));
  console.log((failures ? 'FAIL' : 'PASS') + ' check_denoise_quality: ' + (checks - failures) + '/' + checks + ' checks');
  if (failures) process.exitCode = 1;
})();
