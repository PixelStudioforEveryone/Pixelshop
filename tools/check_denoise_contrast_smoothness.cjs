// The two denoise controls that complete Camera Raw's set of six: Luminance
// Contrast and Color Smoothness.
//
// The properties that matter here are (a) both must be REAL, measurable effects
// rather than sliders that repaint nothing, (b) both must be exactly inert when
// absent or at their default, because every photo saved before they existed has
// to reopen byte-identical, and (c) each must be inert when the pass it belongs
// to is switched off.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const modules = new Map();
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} }; modules.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
    Uint8Array, Uint8ClampedArray, Float32Array, Promise, Error, setTimeout, clearTimeout, Buffer,
    Observed: (c) => c, require: (n) => {
      if (n === '@kit.ArkTS') return { taskpool: { Task: { isCanceled: () => false } } };
      if (n.startsWith('@kit.')) return {};
      if(n.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { denoiseRows, denoiseEnabled } = load(root + '/edit/engine/NoiseReduction.ets');
const { DenoiseSettings } = load(root + '/edit/models/DenoiseSettings.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
function run(src, w, h, settings) {
  const out = new Uint8ClampedArray(src.length);
  denoiseRows(src, out, w, h, settings, 0, h);
  return out;
}
function luma(px, i) { return px[i] * 0.2126 + px[i + 1] * 0.7152 + px[i + 2] * 0.0722; }

// --- 1. The model ---------------------------------------------------------
const fresh = new DenoiseSettings();
ok(fresh.luminanceContrast === 0, 'a fresh document leaves Luminance Contrast at 0');
ok(fresh.colorSmoothness === 0.5, 'a fresh document uses the 50 Color Smoothness default');
const wild = DenoiseSettings.restore({ luminance: 1, color: 1, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 9, colorSmoothness: -4 });
ok(wild.luminanceContrast === 1, 'Luminance Contrast clamps to +1');
ok(DenoiseSettings.restore({ luminanceContrast: -9 }).luminanceContrast === -1,
  'Luminance Contrast clamps to -1 (it is signed, it must not be floored at 0)');
ok(DenoiseSettings.restore({ colorSmoothness: 7 }).colorSmoothness === 1, 'Color Smoothness clamps to 1');
ok(wild.colorSmoothness === 0, 'Color Smoothness clamps to 0');
const missing = DenoiseSettings.restore({ luminance: 0.5, color: 0.5, detail: 0.5, colorDetail: 0.5 });
ok(missing.luminanceContrast === 0 && missing.colorSmoothness === 0.5,
  'a settings block written before these two controls existed restores to their no-op defaults');
const nan = DenoiseSettings.restore({ luminanceContrast: NaN, colorSmoothness: Infinity });
ok(nan.luminanceContrast === 0 && nan.colorSmoothness === 0.5,
  'non-finite values fall back to the no-op defaults rather than poisoning the filter');

// --- fixtures -------------------------------------------------------------
const W = 48, H = 32;
function edgeFrame() {
  const b = new Uint8ClampedArray(W * H * 4);
  // The step must sit INSIDE the filter's luminance range sigma (about a 1.33x
  // ratio at these settings) or the bilateral term preserves it outright and
  // there is no removed variation left for Luminance Contrast to restore.
  // 100 -> 118 is a 1.18x ratio: genuinely smoothed, and measurable.
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const v = x < W / 2 ? 100 : 118;
      b[i] = v; b[i + 1] = v; b[i + 2] = v; b[i + 3] = 255;
    }
  }
  return b;
}
function flatFrame() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let i = 0; i < b.length; i += 4) { b[i] = 128; b[i + 1] = 128; b[i + 2] = 128; b[i + 3] = 255; }
  return b;
}
let seed = 20261012;
function nextRandom() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; }
/** Constant luminance, per-pixel chroma noise: the chroma pass's natural target. */
function chromaNoiseFrame() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let i = 0; i < b.length; i += 4) {
    const dr = Math.round((nextRandom() - 0.5) * 60);
    const db = Math.round((nextRandom() - 0.5) * 60);
    b[i] = 128 + dr; b[i + 1] = 128 - Math.round((dr + db) / 2); b[i + 2] = 128 + db; b[i + 3] = 255;
  }
  return b;
}
/** Constant luminance, a chroma step in the middle: measures how far colour spreads. */
function chromaStepFrame() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const left = x < W / 2;
      const dr = left ? -55 : 55, db = left ? 55 : -55;
      b[i] = 128 + dr; b[i + 1] = 128 - Math.round((dr + db) / 2); b[i + 2] = 128 + db; b[i + 3] = 255;
    }
  }
  return b;
}
const denoiseOn = { luminance: 1, color: 1, detail: 0.5, colorDetail: 0.5 };

function countDifferences(a, b) {
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}
/**
 * Steepest single-column luminance step in a window around the edge.
 *
 * Total variation across a monotone edge is preserved by any smoothing, so
 * summing the differences cannot detect it; the PEAK gradient is what a low-pass
 * lowers and what restoring the removed variation raises. On the source frame
 * this is the full 18-level step.
 */
function peakGradient(out) {
  let peak = 0;
  const c = Math.floor(W / 2);
  for (let y = 0; y < H; y++) {
    for (let x = c - 6; x < c + 6; x++) {
      if (x < 0 || x >= W - 1) continue;
      const here = Math.abs(luma(out, (y * W + x) * 4) - luma(out, (y * W + x + 1) * 4));
      if (here > peak) peak = here;
    }
  }
  return peak;
}
/** RMS chroma spread: how much colour varies across the frame. */
function chromaEnergy(px) {
  let sum = 0, n = 0;
  for (let i = 0; i < px.length; i += 4) {
    const a = px[i] - px[i + 1], b = px[i + 1] - px[i + 2];
    sum += a * a + b * b; n++;
  }
  return Math.sqrt(sum / n);
}
/** Pixels whose chroma sits strictly between the two plateau colours. */
function transitionPixels(out) {
  let n = 0;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const chroma = out[i] - out[i + 2];
      if (chroma > -95 && chroma < 95) n++;
    }
  }
  return n;
}

// --- 2. Both controls must be exactly inert at their default --------------
const edge = edgeFrame();
// The old callers in the shipped suites pass a four-field literal; that must be
// indistinguishable from an explicit no-op default, byte for byte.
const legacySettings = { luminance: 1, color: 1, detail: 0.5, colorDetail: 0.5 };
const explicitDefault = { luminance: 1, color: 1, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 0, colorSmoothness: 0.5 };
for (const fixture of [['edge', edge], ['flat', flatFrame()], ['chroma-noise', chromaNoiseFrame()],
  ['chroma-step', chromaStepFrame()]]) {
  const a = run(fixture[1], W, H, legacySettings);
  const b = run(fixture[1], W, H, explicitDefault);
  ok(countDifferences(a, b) === 0, 'the ' + fixture[0] + ' frame is byte-identical whether the two new ' +
    'fields are absent or explicitly at their defaults');
}

// --- 3. Luminance Contrast is a real, monotone, structure-weighted effect --
const baselineEdge = run(edge, W, H, explicitDefault);
const sourcePeak = peakGradient(edge);
const basePeak = peakGradient(baselineEdge);
ok(basePeak < sourcePeak * 0.97, 'the fixture edge really is smoothed by the denoiser (peak gradient ' +
  basePeak.toFixed(2) + ' vs ' + sourcePeak.toFixed(2) + ' in the source), otherwise the sweep below ' +
  'would prove nothing');
const peaks = [];
for (const contrast of [-1, -0.5, 0, 0.5, 1]) {
  const settings = { luminance: 1, color: 1, detail: 0.5, colorDetail: 0.5,
    luminanceContrast: contrast, colorSmoothness: 0.5 };
  peaks.push(peakGradient(run(edge, W, H, settings)));
}
let strictlySteeper = true;
for (let i = 1; i < peaks.length; i++) if (!(peaks[i] > peaks[i - 1])) strictlySteeper = false;
ok(strictlySteeper, 'raising Luminance Contrast strictly steepens the smoothed edge, across ' +
  '[-1,-0.5,0,0.5,1]: ' + peaks.map((p) => p.toFixed(2)).join(' < '));
ok(peaks[4] > peaks[2] * 1.05, 'the effect is substantial, not a rounding wobble (' +
  peaks[2].toFixed(2) + ' at 0 vs ' + peaks[4].toFixed(2) + ' at +1)');
ok(peaks[0] < peaks[2], 'negative contrast flattens the edge further (' + peaks[0].toFixed(2) +
  ' at -1 vs ' + peaks[2].toFixed(2) + ' at 0)');
// At full contrast the control restores the removed variation exactly where the
// structure term saturates, so it must approach the source WITHOUT overshooting
// it: this is a restoration, not an unsharp mask.
ok(peaks[4] <= sourcePeak + 0.5, 'at full contrast the edge is restored to about the source steepness (' +
  peaks[4].toFixed(2) + ' vs ' + sourcePeak.toFixed(2) + ') without overshooting it');

// On a frame with no variation at all there is nothing to restore, so the
// control must be exactly inert rather than merely small.
const flat = flatFrame();
let flatMoves = 0;
for (const contrast of [-1, -0.5, 0.5, 1]) {
  const out = run(flat, W, H, { luminance: 1, color: 0, detail: 0.5, colorDetail: 0.5,
    luminanceContrast: contrast, colorSmoothness: 0.5 });
  flatMoves += countDifferences(out, flat);
}
ok(flatMoves === 0, 'on a perfectly flat frame Luminance Contrast changes nothing (' + flatMoves +
  ' bytes), because there is no structure for it to restore');
// And with the luminance pass off there is no denoising to trade against.
const lumOff = { luminance: 0, color: 1, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 1, colorSmoothness: 0.5 };
const lumOffOut = run(edge, W, H, lumOff);
const lumOffRef = run(edge, W, H, { luminance: 0, color: 1, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 0, colorSmoothness: 0.5 });
ok(countDifferences(lumOffOut, lumOffRef) === 0,
  'with the luminance pass switched off, Luminance Contrast is inert');

// --- 4. Color Smoothness is a real, monotone spatial effect --------------
const chromaNoise = chromaNoiseFrame();
const chromaEnergies = [];
for (const smoothness of [0, 0.25, 0.5, 0.75, 1]) {
  const out = run(chromaNoise, W, H, { luminance: 0, color: 1, detail: 0.5, colorDetail: 0.5,
    luminanceContrast: 0, colorSmoothness: smoothness });
  chromaEnergies.push(chromaEnergy(out));
}
let chromaDecreasing = true;
for (let i = 1; i < chromaEnergies.length; i++) {
  if (!(chromaEnergies[i] < chromaEnergies[i - 1])) chromaDecreasing = false;
}
ok(chromaDecreasing, 'raising Color Smoothness strictly reduces residual chroma variation, across ' +
  '[0,0.25,0.5,0.75,1]: ' + chromaEnergies.map((c) => c.toFixed(3)).join(' > '));
ok(chromaEnergies[4] < chromaEnergies[2] * 0.95, 'the effect is measurable at the top of the range (' +
  chromaEnergies[2].toFixed(3) + ' at 0.5 vs ' + chromaEnergies[4].toFixed(3) + ' at 1)');
// The control claims to change the SPATIAL EXTENT of chroma smoothing, so the
// colour transition must actually get wider, not just weaker.
const step = chromaStepFrame();
const narrow = run(step, W, H, { luminance: 0, color: 1, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 0, colorSmoothness: 0 });
const wide = run(step, W, H, { luminance: 0, color: 1, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 0, colorSmoothness: 1 });
const narrowWidth = transitionPixels(narrow), wideWidth = transitionPixels(wide);
ok(wideWidth > narrowWidth, 'higher smoothness spreads the colour transition over more pixels (' +
  narrowWidth + ' at 0 vs ' + wideWidth + ' at 1), which is the extent claim and not merely a ' +
  'weaker blur');
ok(narrowWidth > 0, 'the transition-width fixture actually measures a transition (' + narrowWidth +
  ' pixels), so the comparison above is not two degenerate zeroes');
// With the chroma pass off, smoothness has nothing to act on.
const colorOffOut = run(chromaNoise, W, H, { luminance: 1, color: 0, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 0, colorSmoothness: 1 });
const colorOffRef = run(chromaNoise, W, H, { luminance: 1, color: 0, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 0, colorSmoothness: 0 });
ok(countDifferences(colorOffOut, colorOffRef) === 0,
  'with the colour pass switched off, Color Smoothness is inert');

// --- 5. Both together stay well-formed -----------------------------------
const both = { luminance: 1, color: 1, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 0.8, colorSmoothness: 0.9 };
for (const fixture of [['edge', edge], ['chroma-noise', chromaNoise], ['chroma-step', step], ['flat', flat]]) {
  const out = run(fixture[1], W, H, both);
  let wellFormed = true;
  for (let i = 0; i < out.length; i++) {
    if (!Number.isInteger(out[i]) || out[i] < 0 || out[i] > 255) wellFormed = false;
  }
  ok(wellFormed, 'the ' + fixture[0] + ' frame stays integral and in range with both new controls active');
  let alphaKept = true;
  for (let i = 3; i < out.length; i += 4) if (out[i] !== fixture[1][i]) alphaKept = false;
  ok(alphaKept, 'the ' + fixture[0] + ' frame keeps alpha byte for byte');
  const again = run(fixture[1], W, H, both);
  ok(countDifferences(out, again) === 0, 'the ' + fixture[0] + ' frame is deterministic');
}

// --- 6. The controls cannot be reached while the stage is off -------------
// luminanceContrast and colorSmoothness only shape the two passes; with both
// amounts at zero the whole stage must remain a copy, exactly as before.
ok(denoiseEnabled({ luminance: 0, color: 0, detail: 1, colorDetail: 1,
  luminanceContrast: 1, colorSmoothness: 0 }) === false,
  'turning on only Luminance Contrast does not activate the denoise stage');
const offSrc = edgeFrame(), offDst = new Uint8ClampedArray(offSrc.length);
denoiseRows(offSrc, offDst, W, H, { luminance: 0, color: 0, detail: 0.5, colorDetail: 0.5,
  luminanceContrast: 1, colorSmoothness: 0 }, 0, H);
ok(countDifferences(offSrc, offDst) === 0,
  'with both amounts at zero the stage is a byte-for-byte copy regardless of the two new controls');

console.log('PASS denoise contrast/smoothness: model defaults and clamps, byte-identical backward');
console.log('     compatibility when absent or at the default, a strictly monotone structure-weighted');
console.log('     Luminance Contrast, a strictly monotone spatial Color Smoothness, exact inertness on');
console.log('     structure-free frames and with the relevant pass off, and well-formedness.');
console.log('NOTE the structure floor means Luminance Contrast ALSO re-amplifies luminance variation');
console.log('     that exceeds it, including strong noise. That is the intended trade of the control,');
console.log('     not an oversight, and it is why the default is 0.');
console.log(checks + ' checks passed');
