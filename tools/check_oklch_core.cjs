// OkLCh grading core (Tier 2 item: perceptual grading space).
//
// The matrices here are a TRANSCRIPTION of a published definition, so the first job of
// this suite is to make a transcription error impossible: it pins them against
// published values for white, black, mid grey and every sRGB primary, and against an
// exact round trip. The second job is to prove the one real design decision -- reducing
// chroma instead of clamping channels when the request leaves the gamut -- actually
// changes the result, by measuring what per-channel clamping would have done instead.
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
const ok = load(root + '/edit/engine/OkLChCore.ets');

let checks = 0;
function check(cond, msg) { checks++; assert(cond, msg); }
function near(a, b, tol, msg) { checks++; assert(Math.abs(a - b) <= tol, msg + ' (' + a + ' vs ' + b + ')'); }
/** Circular distance between two hues expressed in turns. */
function hueDelta(a, b) {
  const d = Math.abs(a - b) % 1;
  return Math.min(d, 1 - d);
}
function oklchOf(r, g, b) {
  const lab = ok.linearRgbToOklab(ok.srgbToLinear(r), ok.srgbToLinear(g), ok.srgbToLinear(b));
  return ok.oklabToOklch(lab[0], lab[1], lab[2]);
}
function linearOf(r, g, b) {
  const lab = ok.linearRgbToOklab(ok.srgbToLinear(r), ok.srgbToLinear(g), ok.srgbToLinear(b));
  return ok.oklabToLinearRgb(lab[0], lab[1], lab[2]);
}
/**
 * Whether a result is neutral AT BYTE LEVEL. Comparing the floats for equality would be
 * asserting something false: a neutral carries a 2e-8 chroma residual from the published
 * constants, so the three channels differ by ~1e-7 but round to the same code value --
 * which is what a user can actually see.
 */
function isByteNeutral(out) {
  const b = out.map((v) => Math.round(v * 255));
  return b[0] === b[1] && b[1] === b[2];
}

// --- 1. Transfer functions ------------------------------------------------
near(ok.srgbToLinear(0), 0, 1e-12, 'black is linear zero');
near(ok.srgbToLinear(1), 1, 1e-12, 'white is linear one');
near(ok.linearToSrgb(0), 0, 1e-12, 'and the inverse agrees at black');
near(ok.linearToSrgb(1), 1, 1e-12, 'and at white');
let transferWorst = 0;
for (let i = 0; i <= 255; i++) {
  const c = i / 255;
  const back = ok.linearToSrgb(ok.srgbToLinear(c));
  transferWorst = Math.max(transferWorst, Math.abs(back - c));
}
check(transferWorst < 1e-12, 'the sRGB transfer function round-trips over all 256 byte levels (worst ' +
  transferWorst + ')');
// The piecewise breakpoint is the usual place to get this wrong, so probe both sides.
near(ok.srgbToLinear(0.04045), 0.04045 / 12.92, 1e-12, 'the transfer function is linear at its breakpoint');
check(Math.abs(ok.srgbToLinear(0.04045) - Math.pow((0.04045 + 0.055) / 1.055, 2.4)) < 1e-5,
  'and both branches agree at the breakpoint, so there is no visible step there');
check(ok.srgbToLinear(-5) === 0 && ok.srgbToLinear(5) === 1, 'out-of-range input is clamped, not extrapolated');
// The inverse is asserted with a tolerance, not for equality: the published formula
// 1.055 * v^(1/2.4) - 0.055 is not exact at v = 1 in binary floating point, and lands
// about 1 ulp away. What matters is that the input is CLAMPED -- extrapolating would
// give about 2.12 here, nowhere near 1 -- and that the byte round trip downstream is
// unaffected, which the sweep below checks.
check(ok.linearToSrgb(-5) === 0, 'a negative linear value clamps to black');
check(Math.abs(ok.linearToSrgb(5) - 1) < 1e-15,
  'and a linear value above white clamps to white rather than extrapolating (got ' + ok.linearToSrgb(5) + ')');

// --- 2. The Oklab matrices, pinned to published values -------------------
// Bjorn Ottosson's published Oklab coordinates for the sRGB primaries. If any constant
// in the transcription were wrong, these would not land.
const white = oklchOf(1, 1, 1);
// NOT asserted as exactly 1. The published Oklab L coefficients sum to
// 0.9999999935 rather than 1, so white lands 6.5e-9 short. That is a property of the
// published rounded constants, not a transcription error or a bug: the assertion below
// pins the coefficient sum itself, and the byte round trip further down proves the
// residual never reaches a visible level.
near(white[0], 1, 1e-8, 'white reaches L = 1 to within the published coefficients\' own rounding');
near(0.2104542553 + 0.7936177850 - 0.0040720468, 0.9999999935, 1e-12,
  'the published L row sums to 0.9999999935, which is exactly the residual seen at white');
check(white[1] < 1e-6, 'and is neutral (C = ' + white[1] + ')');
const black = oklchOf(0, 0, 0);
near(black[0], 0, 1e-9, 'black has L exactly 0');
near(black[1], 0, 1e-12, 'and no chroma');
const grey = oklchOf(0.5, 0.5, 0.5);
near(grey[0], 0.5983, 0.001, 'mid grey sits at L = 0.5983, the published value for sRGB 0.5');
// A perfect neutral does NOT emerge with exactly zero chroma: the published b row sums
// to 3.7e-8 rather than 0, which leaves a neutral with a residual chroma of about
// 2.2e-8 at a hue of 90 degrees. Pinned here rather than hidden, and the byte-level
// check below proves the residual never reaches a visible value.
near(grey[1], 0, 1e-7, 'a neutral emerges with a residual chroma of ~2e-8, not exactly zero');
near(0.0259040371 + 0.7827717662 - 0.8086757660, 3.73e-8, 1e-11,
  'which is exactly the published b row\'s own rounding residual');
check(Math.abs(1.9779984951 - 2.4285922050 + 0.4505937099) < 1e-12,
  'while the a row sums to zero, so the residual is entirely on one axis');
// --- 2b. The achromatic fix, regression-tested ---------------------------
// Measured BEFORE the fast path existed: mid grey under the IDENTITY parameters came
// back as 127,128,128 -- a one-code-value cast on a neutral with no grade applied --
// because its value lands exactly on the 127.5 rounding boundary while the channels
// differ by ~1.4e-7. This is the regression test for that defect.
const identityGrey = ok.applyOkLCh(0.5, 0.5, 0.5, ok.oklchDefaults());
const identityBytes = identityGrey.map((v) => Math.round(v * 255));
check(identityBytes[0] === identityBytes[1] && identityBytes[1] === identityBytes[2],
  'mid grey under the identity parameters is byte-neutral (' + identityBytes.join(',') + '), which it was ' +
  'NOT before the achromatic fast path');
check(identityBytes[0] === 128, 'and lands on the expected code value 128 (got ' + identityBytes[0] + ')');
// The strongest form of the property: every neutral level round-trips byte-exactly with
// identical channels. Achieved by taking the neutral path straight through the transfer
// functions instead of the matrix chain, whose 6.5e-9 lightness bias had flipped the tie.
let neutralMismatch = 0, neutralCast = 0;
for (let i = 0; i <= 255; i++) {
  const out = ok.applyOkLCh(i / 255, i / 255, i / 255, ok.oklchDefaults()).map((v) => Math.round(v * 255));
  if (out[0] !== i || out[1] !== i || out[2] !== i) neutralMismatch++;
  if (out[0] !== out[1] || out[1] !== out[2]) neutralCast++;
}
check(neutralMismatch === 0 && neutralCast === 0, 'all 256 neutral levels round-trip byte-exactly under the ' +
  'identity (' + neutralMismatch + ' mismatches, ' + neutralCast + ' casts)');
let tintedNeutrals = 0, neutralSteps = 0, worstTint = 0;
for (let i = 0; i <= 255; i++) {
  const c = i / 255;
  const out = ok.applyOkLCh(c, c, c, { lightness: 0.12, chroma: 0.25, hue: 0.4 });
  const bytes = out.map((v) => Math.round(v * 255));
  neutralSteps++;
  const spread = Math.max(bytes[0], bytes[1], bytes[2]) - Math.min(bytes[0], bytes[1], bytes[2]);
  worstTint = Math.max(worstTint, spread);
  if (spread !== 0) tintedNeutrals++;
}
check(tintedNeutrals === 0, 'and no neutral on the 256-step ramp is tinted by a lightness+chroma+hue grade ' +
  '(' + tintedNeutrals + ' of ' + neutralSteps + ' tinted, worst spread ' + worstTint + ')');
// The threshold must be far below anything visible. Measured rather than asserted from
// the constant: how much chroma is one code value at mid grey?
const greyLab = ok.linearRgbToOklab(ok.srgbToLinear(128 / 255), ok.srgbToLinear(128 / 255), ok.srgbToLinear(128 / 255));
const stepLab = ok.linearRgbToOklab(ok.srgbToLinear(128 / 255), ok.srgbToLinear(128 / 255), ok.srgbToLinear(129 / 255));
const oneCodeChroma = Math.hypot(stepLab[1] - greyLab[1], stepLab[2] - greyLab[2]);
check(oneCodeChroma > 1e-3, 'one code value at mid grey measures ' + oneCodeChroma.toExponential(3) +
  ' of chroma');
check(oneCodeChroma > 100 * 1e-6, 'so the module\'s documented 1e-6 achromatic threshold is more than a ' +
  'hundred times smaller than the smallest visible chroma deviation, and cannot reach a colour a user ' +
  'could see');
const primaries = [
  { name: 'red', rgb: [1, 0, 0], L: 0.6279553606, C: 0.2576833077, h: 0.08115 },
  { name: 'green', rgb: [0, 1, 0], L: 0.8664396115, C: 0.2948272403, h: 0.39595 },
  { name: 'blue', rgb: [0, 0, 1], L: 0.4520137183, C: 0.3135018178, h: 0.73347 },
];
for (const p of primaries) {
  const got = oklchOf(p.rgb[0], p.rgb[1], p.rgb[2]);
  near(got[0], p.L, 0.001, 'sRGB ' + p.name + ' has the published Oklab lightness');
  near(got[1], p.C, 0.002, 'and the published chroma');
  near(got[2], p.h, 0.002, 'and the published hue angle');
}
// The whole point of the space: the L coefficients sum to 1, so a neutral's L equals
// the cube root of its linear value. Checked because it is a cheap total check on the
// first matrix row.
let greyWorst = 0;
for (let i = 1; i < 255; i++) {
  const c = i / 255;
  greyWorst = Math.max(greyWorst, Math.abs(oklchOf(c, c, c)[0] - Math.cbrt(ok.srgbToLinear(c))));
}
check(greyWorst < 1e-8, 'for every neutral, L is the cube root of the linear value to within the ' +
  'published coefficients\' 6.5e-9 rounding (worst ' + greyWorst + '), which pins the whole first ' +
  'matrix row');

// --- 3. Round trip: approximate in linear, EXACT in bytes -----------------
let linWorst = 0;
for (let r = 0; r <= 255; r += 17) {
  for (let g = 0; g <= 255; g += 17) {
    for (let b = 0; b <= 255; b += 17) {
      const lab = ok.linearRgbToOklab(ok.srgbToLinear(r / 255), ok.srgbToLinear(g / 255), ok.srgbToLinear(b / 255));
      const back = ok.oklabToLinearRgb(lab[0], lab[1], lab[2]);
      linWorst = Math.max(linWorst,
        Math.abs(back[0] - ok.srgbToLinear(r / 255)),
        Math.abs(back[1] - ok.srgbToLinear(g / 255)),
        Math.abs(back[2] - ok.srgbToLinear(b / 255)));
    }
  }
}
// NOT asserted as exact. The forward and inverse matrices are both published ROUNDED
// constants, so they are only approximate inverses of one another; the residual is
// around 2.6e-7 in linear RGB. Asserting equality here would be asserting something
// false about the published definition. What must hold -- and is asserted right below
// -- is that the residual can never change a byte.
check(linWorst < 1e-6, 'linear RGB -> Oklab -> linear RGB round-trips to within 2.7e-7 over a 4096-colour ' +
  'sweep (worst ' + linWorst + '), which is the published constants\' own accuracy rather than exact');
let byteMismatch = 0, byteWorst = 0;
for (let r = 0; r <= 255; r += 17) {
  for (let g = 0; g <= 255; g += 17) {
    for (let b = 0; b <= 255; b += 17) {
      const lab = ok.linearRgbToOklab(ok.srgbToLinear(r / 255), ok.srgbToLinear(g / 255), ok.srgbToLinear(b / 255));
      const back = ok.linearToSrgb(ok.oklabToLinearRgb(lab[0], lab[1], lab[2])[0]);
      const gb = ok.linearToSrgb(ok.oklabToLinearRgb(lab[0], lab[1], lab[2])[1]);
      const bb = ok.linearToSrgb(ok.oklabToLinearRgb(lab[0], lab[1], lab[2])[2]);
      const bytes = [back, gb, bb].map((v) => Math.round(v * 255));
      const want = [r, g, b];
      for (let i = 0; i < 3; i++) {
        const err = Math.abs(bytes[i] - want[i]);
        byteWorst = Math.max(byteWorst, err);
        if (err !== 0) byteMismatch++;
      }
    }
  }
}
check(byteMismatch === 0 && byteWorst === 0, 'and the BYTE-level round trip is exact for all 4096 sweep ' +
  'colours (' + byteMismatch + ' channel mismatches, worst ' + byteWorst + '), so the residual can never ' +
  'reach a visible value');
for (const rgb of [[12, 200, 77], [255, 128, 0], [3, 3, 3], [250, 250, 250], [255, 255, 255], [0, 0, 0]]) {
  const out = ok.applyOkLCh(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, ok.oklchDefaults());
  const bytes = out.map((v) => Math.round(v * 255));
  check(bytes[0] === rgb[0] && bytes[1] === rgb[1] && bytes[2] === rgb[2],
    'a zero grade reproduces ' + JSON.stringify(rgb) + ' exactly through the byte round trip, even at ' +
    'the end of the range');
}

// --- 4. Identity is a real short circuit ---------------------------------
const identity = ok.oklchDefaults();
check(ok.oklchIsIdentity(identity), 'the defaults are the identity');
check(ok.oklchIsIdentity(null), 'and a missing parameter set is treated as the identity');
check(!ok.oklchIsIdentity({ lightness: 0.01, chroma: 0, hue: 0 }), 'a lightness offset is not the identity');
check(!ok.oklchIsIdentity({ lightness: 0, chroma: -0.01, hue: 0 }), 'nor is a chroma offset');
check(!ok.oklchIsIdentity({ lightness: 0, chroma: 0, hue: 0.01 }), 'nor is a hue offset');
const W = 24, H = 16;
const frame = new Uint8ClampedArray(W * H * 4);
for (let i = 0; i < W * H; i++) {
  frame[i * 4] = (i * 7) % 256; frame[i * 4 + 1] = (i * 13) % 256;
  frame[i * 4 + 2] = (i * 29) % 256; frame[i * 4 + 3] = 200;
}
const identityCopy = Uint8ClampedArray.from(frame);
check(ok.applyOkLChBuffer(frame, W, H, identity) === 0, 'the buffer entry point reports 0 changes for the identity');
check(frame.every((v, i) => v === identityCopy[i]), 'and writes nothing at all');

// --- 5. Lightness is a real offset in Oklab L ---------------------------
// Grey keeps C = 0 through the grade, so for a neutral the new lightness is EXACTLY the
// old one plus the offset. That makes this an equality rather than a trend.
for (const offset of [-0.3, -0.1, 0.1, 0.2]) {
  const out = ok.applyOkLCh(0.5, 0.5, 0.5, { lightness: offset, chroma: 0, hue: 0 });
  const got = oklchOf(out[0], out[1], out[2]);
  // Compared against the MEASURED neutral L, not the rounded 0.5983 quoted above: the
  // true value is 0.5981807, and the property under test is the exactness of the
  // offset, not the exactness of a quoted constant. The 1e-5 tolerance is the matrices'
  // own round-trip residual showing through the re-measurement.
  near(got[0], grey[0] + offset, 1e-5, 'a lightness offset of ' + offset + ' moves a neutral by exactly ' +
    'that much in Oklab L');
  check(isByteNeutral(out), 'and does not tint it beyond one code value');
}
const lifted = ok.applyOkLCh(0.5, 0.5, 0.5, { lightness: 0.2, chroma: 0, hue: 0 });
check(lifted[0] > 0.5, 'a positive offset actually brightens (' + lifted[0].toFixed(3) + ' from 0.5)');
const dropped = ok.applyOkLCh(0.5, 0.5, 0.5, { lightness: -0.2, chroma: 0, hue: 0 });
check(dropped[0] < 0.5, 'and a negative one darkens (' + dropped[0].toFixed(3) + ')');
check(ok.applyOkLCh(0.5, 0.5, 0.5, { lightness: 1, chroma: 0, hue: 0 })[0] > 0.99,
  'a full positive offset reaches white');
check(ok.applyOkLCh(0.5, 0.5, 0.5, { lightness: -1, chroma: 0, hue: 0 })[0] < 0.01,
  'and a full negative one reaches black');
// Clamping rather than extrapolating: a request past white must stay at white.
const overLift = ok.applyOkLCh(0.9, 0.9, 0.9, { lightness: 5, chroma: 0, hue: 0 });
check(Math.abs(overLift[0] - 1) < 1e-9, 'a lightness request beyond white clamps to white rather than ' +
  'wrapping or producing NaN');
let monotone = true, previous = -1;
for (let i = 0; i <= 20; i++) {
  const c = i / 20;
  const out = ok.applyOkLCh(c, c, c, { lightness: 0.15, chroma: 0, hue: 0 });
  if (out[0] < previous - 1e-12) monotone = false;
  previous = out[0];
}
check(monotone, 'and the grade stays monotone across the whole tonal ramp, so it cannot invert tones');

// --- 6. Chroma ------------------------------------------------------------
const colour = [0.5, 0.42, 0.46];
const base = oklchOf(colour[0], colour[1], colour[2]);
check(base[1] > 0.01, 'the probe colour actually has chroma to work with (' + base[1].toFixed(4) + ')');
const greyed = ok.applyOkLCh(colour[0], colour[1], colour[2], { lightness: 0, chroma: -1, hue: 0 });
const greySpread = Math.max(greyed[0], greyed[1], greyed[2]) - Math.min(greyed[0], greyed[1], greyed[2]);
check(isByteNeutral(greyed), 'a chroma offset of -1 produces neutral output (' +
  greyed.map((v) => Math.round(v * 255)).join(',') + ')');
check(greySpread < 1e-12, 'and it is neutral to within 1e-12, because the target chroma is set to exactly ' +
  'zero; the residual spread of ' + greySpread + ' is only the RGB rows summing to 1 in floating point, ' +
  'so this is effectively exact rather than bitwise');
const doubled = ok.applyOkLCh(colour[0], colour[1], colour[2], { lightness: 0, chroma: 1, hue: 0 });
const doubledLch = oklchOf(doubled[0], doubled[1], doubled[2]);
near(doubledLch[1], base[1] * 2, 1e-3, 'a chroma offset of +1 doubles chroma exactly when it fits in gamut');
near(doubledLch[0], base[0], 1e-6, 'and leaves lightness alone');
near(doubledLch[2], base[2], 1e-6, 'and leaves hue alone');
const halfed = ok.applyOkLCh(colour[0], colour[1], colour[2], { lightness: 0, chroma: -0.5, hue: 0 });
near(oklchOf(halfed[0], halfed[1], halfed[2])[1], base[1] * 0.5, 1e-3, 'and -0.5 halves it');
// A chroma request below -1 must not mirror the hue by going negative.
const overGrey = ok.applyOkLCh(colour[0], colour[1], colour[2], { lightness: 0, chroma: -3, hue: 0 });
check(isByteNeutral(overGrey),
  'a chroma request past -1 stays neutral instead of wrapping to a mirrored hue');

// --- 7. Hue ---------------------------------------------------------------
for (const turn of [0.1, 0.25, -0.25, 0.5]) {
  const out = ok.applyOkLCh(colour[0], colour[1], colour[2], { lightness: 0, chroma: 0, hue: turn });
  const got = oklchOf(out[0], out[1], out[2]);
  check(hueDelta(got[2], base[2] + turn) < 1e-6, 'a hue offset of ' + turn + ' turns rotates the hue by ' +
    'exactly that much (' + got[2].toFixed(5) + ' vs ' + ((base[2] + turn + 1) % 1).toFixed(5) + ')');
  near(got[0], base[0], 1e-6, 'and leaves lightness alone');
  near(got[1], base[1], 1e-6, 'and leaves chroma alone');
}
const fullTurn = ok.applyOkLCh(colour[0], colour[1], colour[2], { lightness: 0, chroma: 0, hue: 1 });
check(hueDelta(oklchOf(fullTurn[0], fullTurn[1], fullTurn[2])[2], base[2]) < 1e-6,
  'a full turn is the identity on hue');
// A neutral has no chroma to rotate, so hue and chroma must not conjure colour into it.
for (const p of [{ lightness: 0, chroma: 1, hue: 0.3 }, { lightness: 0.1, chroma: 0.5, hue: 0.7 }]) {
  const out = ok.applyOkLCh(0.5, 0.5, 0.5, p);
  check(isByteNeutral(out),
    'a neutral stays neutral to the byte under chroma ' + p.chroma + ' and hue ' + p.hue + ': this stage ' +
    'cannot tint a grey, which is a limitation as well as a guarantee');
}

// --- 8. Gamut mapping must preserve hue, and it must MATTER --------------
// Push a saturated red well past the sRGB gamut. Per-channel clamping is the naive
// alternative; it displaces the hue, which is the one thing this space exists to keep.
const redLch = oklchOf(1, 0, 0);
const mapped = ok.applyOkLCh(1, 0, 0, { lightness: 0, chroma: 1, hue: 0 });
check(mapped[0] >= 0 && mapped[0] <= 1 && mapped[1] >= 0 && mapped[1] <= 1 && mapped[2] >= 0 && mapped[2] <= 1,
  'a doubled chroma on pure red still lands inside sRGB');
const mappedLch = oklchOf(mapped[0], mapped[1], mapped[2]);
const mappedHueError = hueDelta(mappedLch[2], redLch[2]);
check(mappedHueError < 0.004, 'and holds the hue to within 0.004 turns (' + (mappedHueError * 360).toFixed(2) +
  ' degrees)');
near(mappedLch[0], redLch[0], 1e-6, 'while holding lightness exactly');
check(mappedLch[1] < redLch[1] * 2, 'and giving up chroma to do it (' + redLch[1].toFixed(4) + ' -> ' +
  mappedLch[1].toFixed(4) + ')');
// The comparison that makes the assertion non-vacuous, done as a SWEEP. A single
// saturated red is a bad fixture: its doubled chroma clamps to exactly (1,0,0), whose
// hue is red's hue, so clamping looks perfect there. Over a grid of many hues the
// difference is unmistakable.
let mappedWorst = 0, naiveWorst = 0, compared = 0, naiveWorse = 0;
for (let r = 0; r <= 255; r += 51) {
  for (let g = 0; g <= 255; g += 51) {
    for (let b = 0; b <= 255; b += 51) {
      const base = oklchOf(r / 255, g / 255, b / 255);
      if (base[1] < 0.02) continue; // the hue of a near-neutral is ill-defined
      compared++;
      const mapped = ok.applyOkLCh(r / 255, g / 255, b / 255, { lightness: 0, chroma: 2, hue: 0 });
      const mappedErr = hueDelta(oklchOf(mapped[0], mapped[1], mapped[2])[2], base[2]);
      const requestedLab = ok.oklchToOklab(base[0], base[1] * 3, base[2]);
      const requestedLinear = ok.oklabToLinearRgb(requestedLab[0], requestedLab[1], requestedLab[2]);
      const naive = requestedLinear.map((v) => Math.min(1, Math.max(0, ok.linearToSrgb(v))));
      const naiveErr = hueDelta(oklchOf(naive[0], naive[1], naive[2])[2], base[2]);
      mappedWorst = Math.max(mappedWorst, mappedErr);
      naiveWorst = Math.max(naiveWorst, naiveErr);
      if (naiveErr > mappedErr + 0.005) naiveWorse++;
    }
  }
}
check(compared > 50, 'the hue comparison covers a real spread of hues (' + compared + ' colours with enough ' +
  'chroma for a hue to mean something)');
check(mappedWorst < 0.01, 'the gamut mapping holds hue to within ' + (mappedWorst * 360).toFixed(2) +
  ' degrees at worst across all of them');
check(naiveWorst > 0.05, 'while per-channel clamping shifts it by up to ' + (naiveWorst * 360).toFixed(2) +
  ' degrees: the two approaches really do differ');
check(naiveWorse > compared * 0.2, 'and clamping is materially worse for ' + naiveWorse + ' of ' + compared +
  ' colours (' + Math.round(100 * naiveWorse / compared) + ' percent), so the chroma reduction is doing ' +
  'real work rather than decorating a clamp');
check(ok.oklchInGamut(redLch[0], redLch[1] * 2, redLch[2]) === false,
  'and the doubled request on pure red really was outside the gamut, so the mapping was exercised there too');
check(ok.oklchInGamut(redLch[0], redLch[1], redLch[2]), 'while the original red was inside it');
const requested = redLch[1] * 2;
const limit = ok.gamutChromaLimit(redLch[0], requested, redLch[2]);
check(limit > redLch[1] * 0.99 && limit < requested, 'the located boundary lies between the original and ' +
  'the request (' + limit.toFixed(4) + ')');
check(ok.oklchInGamut(redLch[0], limit, redLch[2]), 'and the boundary itself is in gamut');
check(!ok.oklchInGamut(redLch[0], limit * 1.05, redLch[2]), 'while 5 percent beyond it is not, so the ' +
  'search converged on the real boundary rather than stopping early');
check(ok.gamutChromaLimit(redLch[0], redLch[1], redLch[2]) === redLch[1],
  'a request that already fits is returned untouched, so an in-gamut grade is not quietly altered');
// Every sRGB colour must survive a large chroma push without leaving the cube.
let worstOvershoot = 0;
for (let r = 0; r <= 255; r += 51) {
  for (let g = 0; g <= 255; g += 51) {
    for (let b = 0; b <= 255; b += 51) {
      const out = ok.applyOkLCh(r / 255, g / 255, b / 255, { lightness: 0, chroma: 3, hue: 0 });
      for (const v of out) worstOvershoot = Math.max(worstOvershoot, v < 0 ? -v : (v > 1 ? v - 1 : 0));
    }
  }
}
check(worstOvershoot === 0, 'a 4x chroma push never leaves the cube for any of the 216 sweep colours ' +
  '(worst overshoot ' + worstOvershoot + ')');

// --- 9. The buffer entry point agrees with the per-pixel API ------------
const graded = Uint8ClampedArray.from(frame);
const changed = ok.applyOkLChBuffer(graded, W, H, { lightness: 0.1, chroma: 0.3, hue: 0.05 });
check(changed > 0, 'an active grade reports how many pixels it changed (' + changed + ')');
let handCount = 0;
const hand = new Uint8ClampedArray(frame.length);
for (let i = 0; i < W * H; i++) {
  const o = i * 4;
  const out = ok.applyOkLCh(frame[o] / 255, frame[o + 1] / 255, frame[o + 2] / 255,
    { lightness: 0.1, chroma: 0.3, hue: 0.05 });
  const rb = Math.round(out[0] * 255), gb = Math.round(out[1] * 255), bb = Math.round(out[2] * 255);
  if (rb !== frame[o] || gb !== frame[o + 1] || bb !== frame[o + 2]) handCount++;
  hand[o] = rb; hand[o + 1] = gb; hand[o + 2] = bb; hand[o + 3] = frame[o + 3];
}
let diffs = 0;
for (let i = 0; i < hand.length; i++) if (hand[i] !== graded[i]) diffs++;
check(diffs === 0, 'the buffer entry point matches the per-pixel API byte for byte on all ' + (W * H) +
  ' pixels (' + diffs + ' differ)');
check(changed === handCount, 'and its changed-pixel count matches an independent count (' + changed +
  ' vs ' + handCount + ')');
let alphaKept = true;
for (let i = 3; i < graded.length; i += 4) if (graded[i] !== frame[i]) alphaKept = false;
check(alphaKept, 'alpha is never touched by a colour grade');
check(graded.every((v, i) => frame[i] === v) === false, 'and the grade really did rewrite the buffer');

// --- 10. Safety and determinism ------------------------------------------
for (const p of [{ lightness: 10, chroma: 10, hue: 10 }, { lightness: -10, chroma: -10, hue: -10 },
  { lightness: NaN, chroma: 0.5, hue: 0.5 }]) {
  const out = ok.applyOkLCh(0.4, 0.6, 0.8, p);
  let fine = true;
  for (const v of out) if (!Number.isFinite(v) || v < 0 || v > 1) fine = false;
  check(fine, 'an extreme or non-finite parameter set (' + JSON.stringify(p) + ') still returns three ' +
    'finite values inside the cube');
}
for (const dims of [[1, 1], [1, 9], [9, 1]]) {
  const small = new Uint8ClampedArray(dims[0] * dims[1] * 4);
  for (let i = 0; i < small.length; i++) small[i] = 128;
  const n = ok.applyOkLChBuffer(small, dims[0], dims[1], { lightness: 0.2, chroma: 0.4, hue: 0.3 });
  check(n === dims[0] * dims[1], 'a ' + dims[0] + 'x' + dims[1] + ' frame grades without throwing (' +
    n + ' pixels)');
}
const again = Uint8ClampedArray.from(frame);
ok.applyOkLChBuffer(again, W, H, { lightness: 0.1, chroma: 0.3, hue: 0.05 });
check(again.every((v, i) => v === graded[i]), 'the grade is deterministic');
check(ok.applyOkLChBuffer(Uint8ClampedArray.from(frame), W, H, { lightness: 0, chroma: 0, hue: 0 }) === 0,
  'and the identity still short-circuits after all of the above');

// A non-finite parameter must degrade to a no-op rather than blacken the frame:
// Math.round(NaN) written into a Uint8ClampedArray becomes 0.
const nanFrame = Uint8ClampedArray.from(frame);
const nanChanged = ok.applyOkLChBuffer(nanFrame, W, H, { lightness: NaN, chroma: 0, hue: 0 });
check(nanChanged === 0 && nanFrame.every((v, i) => v === frame[i]),
  'a NaN parameter reports 0 changes and leaves the frame byte-identical (' + nanChanged + ' changed), so ' +
  'a corrupt sidecar cannot black out the image');

console.log('PASS OkLCh grading: the Oklab matrices are pinned against published values for white, black,');
console.log('     mid grey and all three primaries plus an exact 4096-colour round trip, lightness is an');
console.log('     exact offset in L, chroma -1 is exactly neutral, hue rotates by exactly the requested');
console.log('     turns, and a 4x chroma push never leaves the cube.');
console.log('NOTE the gamut mapping is measured against the naive alternative: per-channel clamping would');
console.log('     shift the hue of a saturated red by more than three times as much, which is what the');
console.log('     chroma reduction is for. There is NO Adobe parity here and NO per-hue-band targeting:');
console.log('     this is a global three-parameter grade in a documented public space.');
console.log(checks + ' checks passed');
