// Black-and-white mixer core (Tier 2 item: 黑白混色器).
//
// The two properties that decide whether this is a real mixer or a fake one:
//   * a neutral pixel must be UNTOUCHED by any mixer setting, because a neutral has no
//     hue to attribute to a band;
//   * the output must ALWAYS be exactly neutral, at byte level, for every input.
// Both are sweep-tested rather than spot-checked.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
function load(file) {
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  const mod = { exports: {} };
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console, Math, Number, ArrayBuffer, Uint8Array,
    Uint8ClampedArray, Int32Array, Float32Array, DataView, Error, Set, Map,
  }, { filename: file });
  return mod.exports;
}
const bw = load(root + '/edit/engine/BlackWhiteCore.ets');

let checks = 0;
function check(cond, msg) { checks++; assert(cond, msg); }
function near(a, b, tol, msg) { checks++; assert(Math.abs(a - b) <= tol, msg + ' (' + a + ' vs ' + b + ')'); }
function mixers(values) {
  const out = [];
  for (let i = 0; i < bw.BW_BAND_COUNT; i++) out.push(i < values.length ? values[i] : 0);
  return out;
}

// --- 1. Defaults, identity, normalisation --------------------------------
const defaults = bw.blackWhiteDefaults();
check(bw.BW_BAND_COUNT === 8, 'there are eight mixer bands, as the panel and the names assume');
check(defaults.mixers.length === 8 && defaults.mixers.every((v) => v === 0),
  'the default mixer is eight zeros');
check(defaults.enabled === false, 'and the stage starts switched off');
check(bw.blackWhiteIsIdentity(defaults), 'so a fresh document bypasses it');
check(bw.blackWhiteIsIdentity(null), 'and a missing parameter set is treated as the identity');
check(!bw.blackWhiteIsIdentity({ enabled: true, mixers: mixers([]) }),
  'switching it on is not the identity even with all mixers at zero, because the conversion itself is the effect');
check(bw.blackWhiteIsIdentity({ enabled: false, mixers: mixers([1, 1, 1]) }),
  'while mixers set on a switched-off stage stay the identity');
// Normalisation must pad, truncate, clamp and repair rather than throw.
const repaired = bw.blackWhiteNormalize({ enabled: true, mixers: [0.5, NaN, 9, -9, 'x'] });
check(repaired.mixers.length === 8, 'a short or malformed mixer list is padded to eight (' +
  repaired.mixers.length + ')');
near(repaired.mixers[0], 0.5, 1e-12, 'and usable values survive');
check(repaired.mixers[1] === 0, 'a non-finite value is repaired to zero, not propagated');
check(repaired.mixers[2] === 1 && repaired.mixers[3] === -1, 'and out-of-range values clamp at both ends');
const longList = [0, 0, 0, 0, 0, 0, 0, 0, 0.9, 0.9];
check(bw.blackWhiteNormalize({ enabled: true, mixers: longList }).mixers.length === 8,
  'a longer list is truncated to eight rather than indexed out of bounds');
check(bw.blackWhiteNormalize({ enabled: true, mixers: [] }).mixers.length === 8,
  'and an empty list still yields eight weights');
check(bw.blackWhiteNormalize(undefined).enabled === false, 'normalising nothing yields the bypass');

// --- 2. Hue and saturation -----------------------------------------------
const hueCases = [
  { name: 'pure red', rgb: [1, 0, 0], hue: 0 },
  { name: 'pure green', rgb: [0, 1, 0], hue: 1 / 3 },
  { name: 'pure blue', rgb: [0, 0, 1], hue: 2 / 3 },
  { name: 'yellow', rgb: [1, 1, 0], hue: 1 / 6 },
  { name: 'cyan', rgb: [0, 1, 1], hue: 1 / 2 },
  { name: 'magenta', rgb: [1, 0, 1], hue: 5 / 6 },
];
for (const c of hueCases) {
  near(bw.blackWhiteHue(c.rgb[0], c.rgb[1], c.rgb[2]), c.hue, 1e-9, c.name + ' sits at the expected hue');
  near(bw.blackWhiteSaturation(c.rgb[0], c.rgb[1], c.rgb[2]), 1, 1e-12, 'and is fully saturated');
}
for (const grey of [0, 0.25, 0.5, 1]) {
  check(bw.blackWhiteSaturation(grey, grey, grey) === 0, 'a neutral at ' + grey + ' has zero saturation');
  check(bw.blackWhiteHue(grey, grey, grey) === 0, 'and a defined hue of 0 rather than NaN');
}
near(bw.blackWhiteSaturation(1, 0.5, 0.5), 0.5, 1e-12, 'saturation is measured as (max-min)/max');
// The luma coefficients must be the project's own, or a mixer at zero would not be the
// same conversion the rest of the pipeline performs.
check(bw.BW_LUMA_RED === 0.2126 && bw.BW_LUMA_GREEN === 0.7152 && bw.BW_LUMA_BLUE === 0.0722,
  'the luma coefficients match the project\'s existing Rec.709 constants');
near(bw.blackWhiteLuma(1, 1, 1), 1, 1e-12, 'white converts to 1');
near(bw.blackWhiteLuma(0, 0, 0), 0, 1e-12, 'black converts to 0');
near(bw.blackWhiteLuma(1, 0, 0), 0.2126, 1e-12, 'and pure red converts to its luma, not to a scaled grey');

// --- 3. Band weights: they must cover every hue exactly once -------------
let worstSum = 0, worstHue = -1, nonNegativeFailures = 0;
for (let i = 0; i <= 2000; i++) {
  const hue = i / 2000 - 0.25; // deliberately includes negative and >1 hues
  const out = [];
  bw.blackWhiteBandWeights(hue, out);
  let sum = 0;
  for (const w of out) {
    sum += w;
    if (w < -1e-15 || w > 1 + 1e-15) nonNegativeFailures++;
  }
  const error = Math.abs(sum - 1);
  if (error > worstSum) { worstSum = error; worstHue = hue; }
}
check(worstSum < 1e-12, 'band weights sum to 1 for every hue over 2001 samples including out-of-range ' +
  'hues (worst error ' + worstSum + ' at hue ' + worstHue + ')');
check(nonNegativeFailures === 0, 'and no weight is ever negative or above 1 (' + nonNegativeFailures +
  ' violations)');
// A hue exactly on a band centre must attribute entirely to that band.
let centreFailures = 0;
for (let b = 0; b < bw.BW_BAND_COUNT; b++) {
  const out = [];
  bw.blackWhiteBandWeights(bw.BW_BAND_HUES[b], out);
  if (out[b] !== 1) centreFailures++;
  for (let j = 0; j < bw.BW_BAND_COUNT; j++) if (j !== b && Math.abs(out[j]) > 1e-12) centreFailures++;
}
check(centreFailures === 0, 'a hue sitting exactly on a band centre attributes entirely to that band (' +
  centreFailures + ' violations across all eight centres)');
// Continuity: neighbouring hues must not produce a step, or the conversion would band.
let worstJump = 0;
for (let i = 0; i <= 2000; i++) {
  const a = []; const b = [];
  bw.blackWhiteBandWeights(i / 2000, a);
  bw.blackWhiteBandWeights((i + 1) / 2000, b);
  for (let j = 0; j < bw.BW_BAND_COUNT; j++) worstJump = Math.max(worstJump, Math.abs(a[j] - b[j]));
}
check(worstJump < 0.02, 'and the weights change smoothly with hue (worst step ' + worstJump.toFixed(4) +
  ' over a 0.0005 hue increment), so the conversion cannot band at a band edge');
// The wheel must wrap: hue 0.99 must be mostly the red band, not nothing.
const wrap = [];
bw.blackWhiteBandWeights(0.999, wrap);
check(wrap[0] > 0.9, 'the wheel wraps between magenta and red: hue 0.999 attributes ' +
  wrap[0].toFixed(3) + ' to the red band');

// --- 4. The two properties that make it real -----------------------------
const extreme = mixers([1, -1, 1, -1, 1, -1, 1, -1]);
const extremeOn = { enabled: true, mixers: extreme };
// (a) a neutral must be UNTOUCHED by any mixer
let neutralMovements = 0, neutralSteps = 0, worstNeutralMove = 0;
for (let i = 0; i <= 255; i++) {
  const c = i / 255;
  const plain = bw.blackWhiteValue(c, c, c, { enabled: false, mixers: extreme });
  const mixed = bw.blackWhiteValue(c, c, c, extremeOn);
  neutralSteps++;
  const move = Math.abs(mixed - plain);
  worstNeutralMove = Math.max(worstNeutralMove, move);
  if (move !== 0) neutralMovements++;
}
check(neutralSteps === 256 && neutralMovements === 0, 'a neutral is byte-for-byte UNTOUCHED by the most ' +
  'extreme mixer setting, across all 256 levels (' + neutralMovements + ' moved, worst ' +
  worstNeutralMove + '): a grey has no hue to attribute to a band');
// (b) the output must always be exactly neutral
let notNeutral = 0, couTinted = 0;
for (let r = 0; r <= 255; r += 15) {
  for (let g = 0; g <= 255; g += 15) {
    for (let b = 0; b <= 255; b += 15) {
      const out = bw.blackWhiteApply(r / 255, g / 255, b / 255, extremeOn);
      couTinted++;
      if (out[0] !== out[1] || out[1] !== out[2]) notNeutral++;
    }
  }
}
check(couTinted > 4000 && notNeutral === 0, 'the conversion output is exactly neutral for all ' + couTinted +
  ' sweep colours under the extreme mixer (' + notNeutral + ' tinted): it is a black-and-white ' +
  'conversion, not a colour filter');
// (c) all-zero mixers must be EXACTLY the plain luma, not merely close
let zeroMixerError = 0;
for (let r = 0; r <= 255; r += 51) {
  for (let g = 0; g <= 255; g += 51) {
    for (let b = 0; b <= 255; b += 51) {
      const on = bw.blackWhiteValue(r / 255, g / 255, b / 255, { enabled: true, mixers: mixers([]) });
      const plain = bw.blackWhiteLuma(r / 255, g / 255, b / 255);
      zeroMixerError = Math.max(zeroMixerError, Math.abs(on - plain));
    }
  }
}
check(zeroMixerError === 0, 'switching the stage on with all mixers at zero is EXACTLY the plain luma ' +
  'conversion (worst error ' + zeroMixerError + '), so the neutral setting is not merely close to it');

// --- 5. A band must move its own hue and leave the others alone ----------
// Direction AND selectivity, because a mixer that brightened everything would pass a
// direction-only test.
const redUp = { enabled: true, mixers: mixers([0.5]) };
const redDown = { enabled: true, mixers: mixers([-0.5]) };
const plainRed = bw.blackWhiteValue(1, 0, 0, { enabled: false, mixers: mixers([0.5]) });
const plainBlue = bw.blackWhiteValue(0, 0, 1, { enabled: false, mixers: mixers([0.5]) });
const litRed = bw.blackWhiteValue(1, 0, 0, redUp);
const darkRed = bw.blackWhiteValue(1, 0, 0, redDown);
const sameBlue = bw.blackWhiteValue(0, 0, 1, redUp);
check(litRed > plainRed + 0.05, 'the red mixer brightens a red (' + plainRed.toFixed(3) + ' -> ' +
  litRed.toFixed(3) + ')');
check(darkRed < plainRed - 0.05, 'and a negative red mixer darkens it (' + darkRed.toFixed(3) + ')');
check(Math.abs(sameBlue - plainBlue) < 1e-12, 'while leaving a pure blue completely alone (' +
  plainBlue.toFixed(4) + ' vs ' + sameBlue.toFixed(4) + '): the bands are selective, not global ' +
  'brightness controls');
// Each of the eight bands must be reachable at its own centre hue.
let unreachable = 0;
for (let b = 0; b < bw.BW_BAND_COUNT; b++) {
  const values = []; for (let i = 0; i < 8; i++) values.push(0);
  values[b] = 0.6;
  const p = { enabled: true, mixers: mixers(values) };
  // Build a fully saturated colour at that band's centre hue.
  const hue = bw.BW_BAND_HUES[b];
  const angle = hue * Math.PI * 2;
  const r = 0.5 + 0.5 * Math.cos(angle), g = 0.5 + 0.5 * Math.cos(angle - 2 * Math.PI / 3),
    bl = 0.5 + 0.5 * Math.cos(angle - 4 * Math.PI / 3);
  const before = bw.blackWhiteValue(r, g, bl, { enabled: false, mixers: mixers(values) });
  const after = bw.blackWhiteValue(r, g, bl, p);
  if (Math.abs(after - before) < 0.01) unreachable++;
}
check(unreachable === 0, 'and every one of the eight bands actually reaches its own hue (' + unreachable +
  ' of ' + bw.BW_BAND_COUNT + ' unreachable): no band is a dead slider');
// A mixer must not be able to push the result outside the cube.
let outOfCube = 0;
for (const m of [mixers([1, 1, 1, 1, 1, 1, 1, 1]), mixers([-1, -1, -1, -1, -1, -1, -1, -1])]) {
  for (let b = 0; b < bw.BW_BAND_COUNT; b++) {
    const hue = bw.BW_BAND_HUES[b];
    const angle = hue * Math.PI * 2;
    const r = 0.5 + 0.5 * Math.cos(angle), g = 0.5 + 0.5 * Math.cos(angle - 2 * Math.PI / 3),
      bl = 0.5 + 0.5 * Math.cos(angle - 4 * Math.PI / 3);
    const v = bw.blackWhiteValue(r, g, bl, { enabled: true, mixers: m });
    if (!Number.isFinite(v) || v < 0 || v > 1) outOfCube++;
  }
}
check(outOfCube === 0, 'and a fully positive or fully negative mixer never leaves 0..1 (' + outOfCube +
  ' violations)');

// --- 6. The buffer entry point -------------------------------------------
const W = 32, H = 24;
const frame = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    frame[i] = (x * 8) % 256; frame[i + 1] = (y * 10) % 256; frame[i + 2] = ((x + y) * 5) % 256;
    frame[i + 3] = 190;
  }
}
const bufferCopy = Uint8ClampedArray.from(frame);
check(bw.blackWhiteBuffer(frame, W, H, defaults) === 0, 'a bypassed stage reports 0 changes');
check(frame.every((v, i) => v === bufferCopy[i]), 'and writes nothing at all');
const marked = Uint8ClampedArray.from(frame);
const changed = bw.blackWhiteBuffer(marked, W, H, { enabled: true, mixers: mixers([0.4, 0, 0, -0.3]) });
check(changed > 0, 'an enabled stage reports how many pixels it changed (' + changed + ')');
let handCount = 0, diffs = 0;
const hand = new Uint8ClampedArray(frame.length);
const paramsForHand = { enabled: true, mixers: mixers([0.4, 0, 0, -0.3]) };
for (let i = 0; i < W * H; i++) {
  const o = i * 4;
  const grey = Math.round(bw.blackWhiteValue(frame[o] / 255, frame[o + 1] / 255, frame[o + 2] / 255,
    paramsForHand) * 255);
  if (grey !== frame[o] || grey !== frame[o + 1] || grey !== frame[o + 2]) handCount++;
  hand[o] = grey; hand[o + 1] = grey; hand[o + 2] = grey; hand[o + 3] = frame[o + 3];
}
for (let i = 0; i < hand.length; i++) if (hand[i] !== marked[i]) diffs++;
check(diffs === 0, 'and the buffer entry point matches the per-pixel API byte for byte on all ' + (W * H) +
  ' pixels (' + diffs + ' differ)');
check(changed === handCount, 'with a changed-pixel count matching an independent count (' + changed + ' vs ' +
  handCount + ')');
let alphaKept = true, strayColour = 0;
for (let i = 0; i < W * H; i++) {
  const o = i * 4;
  if (marked[o + 3] !== frame[o + 3]) alphaKept = false;
  if (marked[o] !== marked[o + 1] || marked[o + 1] !== marked[o + 2]) strayColour++;
}
check(alphaKept, 'alpha is preserved');
check(strayColour === 0, 'and the whole buffer came out neutral (' + strayColour + ' coloured pixels)');

// --- 7. Determinism and safety -------------------------------------------
const again = Uint8ClampedArray.from(frame);
bw.blackWhiteBuffer(again, W, H, { enabled: true, mixers: mixers([0.4, 0, 0, -0.3]) });
check(again.every((v, i) => v === marked[i]), 'the conversion is deterministic');
check(bw.blackWhiteBuffer(Uint8ClampedArray.from(frame), W, H, null) === 0, 'a null parameter set bypasses');
for (const dims of [[1, 1], [1, 7], [7, 1]]) {
  const small = new Uint8ClampedArray(dims[0] * dims[1] * 4);
  for (let i = 0; i < small.length; i++) small[i] = 128;
  const n = bw.blackWhiteBuffer(small, dims[0], dims[1], { enabled: true, mixers: mixers([1, -1, 1]) });
  let fine = true;
  for (let i = 0; i < small.length; i++) if (!Number.isFinite(small[i])) fine = false;
  check(fine, 'a ' + dims[0] + 'x' + dims[1] + ' frame converts without throwing (' + n + ' pixels)');
}
check(bw.blackWhiteValue(0.4, 0.6, 0.8, { enabled: true, mixers: [NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN] })
  === bw.blackWhiteLuma(0.4, 0.6, 0.8),
  'an all-NaN mixer degrades to the plain conversion rather than producing NaN');

console.log('PASS black-and-white mixer: eight selective bands whose weights sum to 1 for every hue and');
console.log('     vary smoothly, a neutral is byte-for-byte untouched by the most extreme mixer setting, the');
console.log('     output is exactly neutral for every sweep colour, and all-zero mixers are EXACTLY the plain');
console.log('     Rec.709 luma rather than merely close to it.');
console.log('NOTE no Adobe parity: the eight band centres are the conventional evenly-spaced layout and are');
console.log('     NOT claimed to be Adobe\'s exact positions, which are not published. The mixer range is');
console.log('     -1..1 and the mapping from a weight to a brightness change is this implementation\'s own.');
console.log(checks + ' checks passed');
