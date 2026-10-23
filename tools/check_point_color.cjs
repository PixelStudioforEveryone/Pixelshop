// Independent verification of the Point Color sampler (PointColorCore.ets).
//
// Every property below is re-derived from its statement in the module header and
// checked against the module; the falloff, the hue distance and the HSL
// conversions are all written a second time here in a deliberately different
// form (Hermite factored as (1-t)^2(1+2t), hue distance as min(d, 1-d), HSL via
// the chroma/sector construction) so that a bug shared between the two would
// have to be a bug in the definition rather than in the code.
//
// The loader is copied verbatim from tools/check_range_mask.cjs, the reference
// harness, including its require shim.
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

const pc = load(root + '/edit/engine/PointColorCore.ets');

let checks = 0;
const ok = (condition, message) => { assert(condition, message); checks++; };
const close = (a, b, eps, message) => {
  assert(Number.isFinite(a) && Math.abs(a - b) <= eps, `${message} (got ${a}, want ${b})`);
  checks++;
};

// --- independent re-derivations -------------------------------------------

/** Hue difference the short way round, written as min(d, 1-d) rather than by
 *  shifting the signed difference into (-0.5, 0.5]. */
function refHueDelta(first, second) {
  const a = ((first % 1) + 1) % 1, b = ((second % 1) + 1) % 1;
  const raw = Math.abs(a - b);
  return Math.min(raw, 1 - raw);
}
/** smoothstep falloff, factored as (1-t)^2 (1+2t) instead of 1 - t^2(3-2t). */
function refFalloff(distance, range) {
  const d = Math.abs(distance);
  if (!Number.isFinite(d)) return 0;
  if (d <= 0) return 1;
  const r = Math.max(0, Math.min(1, range));
  if (!(r > 0)) return 0;
  if (d >= r) return 0;
  const t = d / r;
  return (1 - t) * (1 - t) * (1 + 2 * t);
}
const ACHROMATIC = 1e-4;
function refWeight(sample, h, s, l) {
  const ss = Math.max(0, Math.min(1, sample.saturation));
  const ps = Math.max(0, Math.min(1, s));
  const pl = Math.max(0, Math.min(1, l));
  let hueAxis;
  if (ss <= ACHROMATIC) hueAxis = 1;
  else if (ps <= ACHROMATIC) hueAxis = 0;
  else hueAxis = refFalloff(refHueDelta(h, sample.hue), sample.hueRange);
  return hueAxis
    * refFalloff(ps - ss, sample.saturationRange)
    * refFalloff(pl - Math.max(0, Math.min(1, sample.luminance)), sample.luminanceRange);
}
/** RGB -> HSL via chroma + a modulo-6 hue sector (a different arrangement from
 *  the implementation's `+6` correction branch). */
function refRgbToHsl(r, g, b) {
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
  const l = (mx + mn) / 2;
  const c = mx - mn;
  let h = 0, s = 0;
  if (c > 0) {
    const sector = mx === r ? ((g - b) / c + 6) % 6 : (mx === g ? (b - r) / c + 2 : (r - g) / c + 4);
    h = sector / 6;
    s = l > 0.5 ? c / (2 - mx - mn) : c / (mx + mn);
  }
  return [((h % 1) + 1) % 1, Math.max(0, Math.min(1, s)), Math.max(0, Math.min(1, l))];
}
/** HSL -> RGB via chroma + the sector table (a different arrangement from the
 *  implementation's p/q hueToChannel ramp). */
function refHslToRgb(h, s, l) {
  const hh = (((h % 1) + 1) % 1) * 6;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs((hh % 2) - 1));
  let r1 = 0, g1 = 0, b1 = 0;
  if (hh < 1) { r1 = c; g1 = x; }
  else if (hh < 2) { r1 = x; g1 = c; }
  else if (hh < 3) { g1 = c; b1 = x; }
  else if (hh < 4) { g1 = x; b1 = c; }
  else if (hh < 5) { r1 = x; b1 = c; }
  else { r1 = c; b1 = x; }
  const m = l - c / 2;
  return [r1 + m, g1 + m, b1 + m];
}

const sample = (over) => Object.assign(pc.pointColorDefaults(), over);
/** A sample that matches a colour exactly, so its weight there is 1. */
function sampleAt(r, g, b, over) {
  const hsl = pc.rgbToHsl01(r, g, b);
  return sample(Object.assign({ hue: hsl[0], saturation: hsl[1], luminance: hsl[2] }, over));
}
const REPRESENTATIVE = [
  [0, 0, 0], [1, 1, 1], [0.5, 0.5, 0.5], [1, 0, 0], [0, 1, 0], [0, 0, 1],
  [1, 1, 0], [0, 1, 1], [1, 0, 1], [0.1, 0.2, 0.3], [0.77, 0.13, 0.42], [0.03, 0.91, 0.6],
];

// --- 1. the exported surface ----------------------------------------------
{
  ok(pc.MAX_POINT_COLORS === 8, 'MAX_POINT_COLORS is 8');
  for (const name of ['pointColorDefaults', 'pointColorIsIdentity', 'pointColorWeight',
    'applyPointColor', 'rgbToHsl01', 'hsl01ToRgb']) {
    ok(typeof pc[name] === 'function', `${name} is exported as a function`);
  }
  const d = pc.pointColorDefaults();
  ok(d.hueShift === 0 && d.saturationShift === 0 && d.luminanceShift === 0, 'defaults are unshifted');
  close(d.hueRange, 30 / 360, 1e-15, 'default hue range is 30 degrees');
  ok(d.saturationRange === 0.4, 'default saturation range is 0.4');
  ok(d.luminanceRange === 0.4, 'default luminance range is 0.4');
  // Defaults must be a fresh object: a caller editing its sample must not
  // corrupt every later default.
  const d2 = pc.pointColorDefaults();
  d2.hueShift = 0.9;
  ok(pc.pointColorDefaults().hueShift === 0, 'defaults() hands out an independent object');
}

// --- 2. identity detection ------------------------------------------------
{
  ok(pc.pointColorIsIdentity([]) === true, 'an empty list is identity');
  ok(pc.pointColorIsIdentity([sample()]) === true, 'one zero-shift sample is identity');
  ok(pc.pointColorIsIdentity([sample(), sample(), sample()]) === true, 'three zero-shift samples are identity');
  ok(pc.pointColorIsIdentity([sample({ hueShift: 0.001 })]) === false, 'a hue shift breaks identity');
  ok(pc.pointColorIsIdentity([sample({ saturationShift: -0.5 })]) === false, 'a saturation shift breaks identity');
  ok(pc.pointColorIsIdentity([sample(), sample(), sample({ luminanceShift: 0.25 })]) === false,
    'a shift in a later sample breaks identity');
  const beyond = [];
  for (let i = 0; i < 12; i++) beyond.push(sample({ hueShift: i >= 8 ? 1 : 0 }));
  ok(pc.pointColorIsIdentity(beyond) === true,
    'a shift past MAX_POINT_COLORS does not break identity, because it is ignored');
}

// --- 3. exact identity through applyPointColor ----------------------------
{
  for (const c of REPRESENTATIVE) {
    const out = pc.applyPointColor(c[0], c[1], c[2], []);
    assert(out.length === 3, 'applyPointColor returns three components');
    for (let i = 0; i < 3; i++) {
      assert(Math.abs(out[i] - c[i]) <= 1e-9, `empty list changed ${c} at ${i}: ${out[i]}`);
    }
    checks++;
  }
  const zeros = [sample(), sample(), sample()];
  for (const c of REPRESENTATIVE) {
    const out = pc.applyPointColor(c[0], c[1], c[2], zeros);
    for (let i = 0; i < 3; i++) {
      // Bit-exact, not merely close: the identity path must not round-trip HSL.
      assert(out[i] === c[i], `zero shifts changed ${c} at ${i}: ${out[i]} vs ${c[i]}`);
    }
    checks++;
  }
  const clamped = pc.applyPointColor(-5, 4, 0.25, []);
  ok(clamped[0] === 0 && clamped[1] === 1 && clamped[2] === 0.25, 'incoming colour channels are clamped into 0..1');
  const nanFree = pc.applyPointColor(NaN, Infinity, -Infinity, []);
  ok(nanFree.every((c) => Number.isFinite(c) && c >= 0 && c <= 1),
    'non-finite colour input degrades to a finite 0..1 colour');
}

// --- 4. rgbToHsl01 / hsl01ToRgb ------------------------------------------
{
  const red = pc.rgbToHsl01(1, 0, 0), green = pc.rgbToHsl01(0, 1, 0), blue = pc.rgbToHsl01(0, 0, 1);
  close(red[0], 0, 1e-12, 'pure red has hue 0');
  close(red[1], 1, 1e-12, 'pure red is fully saturated');
  close(red[2], 0.5, 1e-12, 'pure red is mid lightness');
  close(green[0], 1 / 3, 1e-12, 'pure green sits at hue 1/3');
  close(blue[0], 2 / 3, 1e-12, 'pure blue sits at hue 2/3');
  const grey = pc.rgbToHsl01(0.5, 0.5, 0.5);
  ok(grey[0] === 0 && grey[1] === 0 && grey[2] === 0.5, 'mid grey is hue 0, saturation 0, lightness 0.5');
  const black = pc.rgbToHsl01(0, 0, 0), white = pc.rgbToHsl01(1, 1, 1);
  ok(black[1] === 0 && black[2] === 0, 'black is unsaturated with lightness 0');
  ok(white[1] === 0 && white[2] === 1, 'white is unsaturated with lightness 1');
  close(pc.hsl01ToRgb(0, 1, 0.5)[0], 1, 1e-12, 'hsl(0,1,0.5) is red');
  ok(pc.hsl01ToRgb(1 / 3, 1, 0.5)[1] === 1 && pc.hsl01ToRgb(1 / 3, 1, 0.5)[0] < 1e-15, 'hsl(1/3,1,0.5) is green');
  ok(pc.hsl01ToRgb(2 / 3, 1, 0.5)[2] === 1 && pc.hsl01ToRgb(2 / 3, 1, 0.5)[0] < 1e-15, 'hsl(2/3,1,0.5) is blue');
  const greyOut = pc.hsl01ToRgb(0.42, 0, 0.25);
  ok(greyOut.every((c) => c === 0.25), 'a zero-saturation HSL triple converts to the exact grey');

  // Round trip RGB -> HSL -> RGB.
  for (const c of REPRESENTATIVE) {
    const back = pc.hsl01ToRgb.apply(null, pc.rgbToHsl01(c[0], c[1], c[2]));
    for (let i = 0; i < 3; i++) assert(Math.abs(back[i] - c[i]) <= 1e-9,
      `rgb round trip failed for ${c} at ${i}: ${back[i]} vs ${c[i]}`);
    checks++;
  }
  // Round trip HSL -> RGB -> HSL, against the independent conversion.
  for (let hi = 0; hi < 6; hi++) {
    const h = hi / 7, s = 0.13 + hi * 0.14, l = 0.08 + hi * 0.15;
    const back = pc.rgbToHsl01.apply(null, pc.hsl01ToRgb(h, s, l));
    close(back[0], h, 1e-9, `hsl round trip hue for h=${h}`);
    close(back[1], s, 1e-9, `hsl round trip saturation for s=${s}`);
    close(back[2], l, 1e-9, `hsl round trip lightness for l=${l}`);
  }
  // Cross-check both conversions against the independent chroma/sector form.
  let worstHsl = 0, worstRgb = 0;
  for (let i = 0; i < 40; i++) {
    const r = ((i * 37) % 101) / 100, g = ((i * 53) % 97) / 96, b = ((i * 71) % 89) / 88;
    const mine = pc.rgbToHsl01(r, g, b), ref = refRgbToHsl(r, g, b);
    for (let k = 0; k < 3; k++) worstHsl = Math.max(worstHsl, Math.abs(mine[k] - ref[k]));
    const h = ((i * 29) % 100) / 100, s = ((i * 17) % 100) / 100, l = 0.02 + (((i * 41) % 96) / 100);
    const mineRgb = pc.hsl01ToRgb(h, s, l), refRgb = refHslToRgb(h, s, l);
    for (let k = 0; k < 3; k++) worstRgb = Math.max(worstRgb, Math.abs(mineRgb[k] - refRgb[k]));
  }
  ok(worstHsl <= 1e-12, `rgbToHsl01 matches the independent chroma/sector derivation (worst ${worstHsl})`);
  ok(worstRgb <= 1e-12, `hsl01ToRgb matches the independent sector-table derivation (worst ${worstRgb})`);
}

// --- 5. weight: endpoints and axes ----------------------------------------
{
  // Probe values are chosen so every +/- range step stays inside 0..1: the
  // weight is only defined on those axes, and asking about saturation 1.18
  // would be testing a colour that cannot exist.
  const s = sample({
    hue: 0.25, saturation: 0.5, luminance: 0.5, hueShift: 0.5,
    hueRange: 0.25, saturationRange: 0.4, luminanceRange: 0.4,
  });
  close(pc.pointColorWeight(s, s.hue, s.saturation, s.luminance), 1, 1e-12,
    'weight is exactly 1 at the sampled colour');
  // Straight out along each axis, to the range and past it.
  ok(pc.pointColorWeight(s, s.hue, s.saturation + s.saturationRange, s.luminance) === 0,
    'weight is 0 at the saturation range');
  ok(pc.pointColorWeight(s, s.hue, s.saturation + s.saturationRange + 0.05, s.luminance) === 0,
    'weight is 0 past the saturation range');
  ok(pc.pointColorWeight(s, s.hue, s.saturation - s.saturationRange, s.luminance) === 0,
    'weight is 0 below the saturation range, not just above it');
  ok(pc.pointColorWeight(s, s.hue, s.saturation - s.saturationRange - 0.05, s.luminance) === 0,
    'weight is 0 well below the saturation range');
  ok(pc.pointColorWeight(s, s.hue, s.saturation, s.luminance + s.luminanceRange) === 0,
    'weight is 0 at the luminance range');
  ok(pc.pointColorWeight(s, s.hue, s.saturation, s.luminance - s.luminanceRange) === 0,
    'weight is 0 below the luminance range');
  ok(pc.pointColorWeight(s, s.hue + s.hueRange, s.saturation, s.luminance) === 0,
    'weight is 0 at the hue range');
  ok(pc.pointColorWeight(s, s.hue - s.hueRange, s.saturation, s.luminance) === 0,
    'weight is 0 at the hue range in the other direction');
  // An exact hit with a zero-width range is a hit, not a division by zero.
  const hard = sample({
    hue: 0.25, saturation: 0.5, luminance: 0.5, hueRange: 0, saturationRange: 0, luminanceRange: 0,
  });
  close(pc.pointColorWeight(hard, hard.hue, hard.saturation, hard.luminance), 1, 1e-12,
    'zero-width ranges still select an exact match');
  ok(pc.pointColorWeight(hard, hard.hue + 1e-6, hard.saturation, hard.luminance) === 0,
    'zero-width hue range rejects a hue that is merely close');
  ok(pc.pointColorWeight(hard, hard.hue, hard.saturation + 1e-6, hard.luminance) === 0,
    'zero-width saturation range rejects a saturation that is merely close');
  ok(Number.isFinite(pc.pointColorWeight(hard, hard.hue + 1e-6, hard.saturation + 1e-6, hard.luminance + 1e-6)),
    'a zero-width range produces a finite weight, not NaN');
  // The weight is a product of independent axes, so it can never exceed 1.
  const straddle = sampleAt(0.6, 0.6, 0.4, { hueRange: 1, saturationRange: 1, luminanceRange: 1 });
  ok(pc.pointColorWeight(straddle, 0.1, 0.9, 0.9) <= 1, 'weight never exceeds 1');
  ok(pc.pointColorWeight(straddle, 0.1, 0.9, 0.9) > 0, 'a colour inside all three ranges is affected');
}

// --- 6. hue wraparound ----------------------------------------------------
{
  const near = sample({ hue: 0.98, saturation: 0.5, luminance: 0.5, hueShift: 0.5 });
  const far = sample({ hue: 0.5, saturation: 0.5, luminance: 0.5, hueShift: 0.5 });
  const wrapped = pc.pointColorWeight(near, 0.02, 0.5, 0.5);
  ok(wrapped > 0.5, `a sample at hue 0.98 strongly affects a pixel at hue 0.02 (weight ${wrapped})`);
  close(wrapped, refWeight(near, 0.02, 0.5, 0.5), 1e-12, 'the wrapped weight matches the min(d, 1-d) derivation');
  ok(pc.pointColorWeight(far, 0.02, 0.5, 0.5) < 1e-12,
    'a sample at hue 0.5 does not reach a pixel at hue 0.02');
  // The mirror image must behave identically: 0.02 -> 0.98 is the same gap.
  close(pc.pointColorWeight(near, 0.02, 0.5, 0.5), pc.pointColorWeight(sample({ hue: 0.02, saturation: 0.5, luminance: 0.5 }), 0.98, 0.5, 0.5),
    1e-12, 'the hue weight is symmetric across the seam');
  // Out-of-range hues are wrapped rather than rejected or extrapolated.
  close(pc.pointColorWeight(near, 1.02, 0.5, 0.5), wrapped, 1e-12, 'a pixel hue of 1.02 is read as 0.02');
  close(pc.pointColorWeight(near, -0.98, 0.5, 0.5), wrapped, 1e-12, 'a negative pixel hue wraps into range');
  // And the wrap must survive the full apply path, not just the weight. The
  // pixel is on the far side of the seam from the sample, so a correct wrap
  // gives it a solid rotation; a broken (non-wrapping) distance would give it
  // nearly none.
  const src = pc.hsl01ToRgb(0.02, 0.5, 0.5);
  const shifted = pc.applyPointColor(src[0], src[1], src[2], [near]);
  const movedHue = pc.rgbToHsl01(shifted[0], shifted[1], shifted[2])[0];
  const expectedMove = (0.02 + 0.5 * (30 / 360) * wrapped) % 1;
  close(movedHue, expectedMove, 1e-9, 'the pixel across the seam is rotated by the weighted, wrapped shift');
  ok(Math.abs(movedHue - 0.02) > 0.01, 'the wrapped sample really does move a pixel across the seam');
  ok(Math.abs(movedHue - 0.02) < 0.05, 'the rotation across the seam is a small step, not a leap');
}

// --- 7. monotone falloff along each axis ----------------------------------
{
  const s = sampleAt(0.2, 0.6, 0.5, { hueRange: 0.25, saturationRange: 0.5, luminanceRange: 0.5, hueShift: 0.5 });
  const hueSteps = [], satSteps = [], lumSteps = [];
  for (let i = 0; i <= 20; i++) {
    const t = i / 20;
    hueSteps.push(pc.pointColorWeight(s, s.hue + t * 0.25, s.saturation, s.luminance));
    satSteps.push(pc.pointColorWeight(s, s.hue, s.saturation + t * 0.5, s.luminance));
    lumSteps.push(pc.pointColorWeight(s, s.hue, s.saturation, s.luminance + t * 0.5));
  }
  for (let i = 1; i <= 20; i++) {
    assert(hueSteps[i] <= hueSteps[i - 1] + 1e-12, `hue weight rose while moving away (${i})`);
    assert(satSteps[i] <= satSteps[i - 1] + 1e-12, `saturation weight rose while moving away (${i})`);
    assert(lumSteps[i] <= lumSteps[i - 1] + 1e-12, `luminance weight rose while moving away (${i})`);
  }
  checks += 3;
  ok(hueSteps[0] > 0.99 && hueSteps[20] === 0, 'the hue falloff runs from 1 to 0 across its range');
  ok(satSteps[0] > 0.99 && satSteps[20] === 0, 'the saturation falloff runs from 1 to 0 across its range');
  ok(lumSteps[0] > 0.99 && lumSteps[20] === 0, 'the luminance falloff runs from 1 to 0 across its range');
  // Smoothstep: the first step out of the centre must be almost flat, which is
  // what stops a visible ring where the selection ends.
  const firstStep = 1 - pc.pointColorWeight(s, s.hue + 0.25 / 20, s.saturation, s.luminance);
  ok(firstStep < 0.01, `the falloff leaves the centre with ~zero slope (first step ${firstStep})`);
  const lastStep = pc.pointColorWeight(s, s.hue + 0.96 * s.hueRange, s.saturation, s.luminance);
  ok(lastStep < 0.02, `the falloff approaches its end with ~zero slope (last step ${lastStep})`);
}

// --- 8. wider ranges never reduce the weight ------------------------------
{
  const s = sample({ hue: 0.3, saturation: 0.5, luminance: 0.5, hueShift: 0.5 });
  const probeH = 0.34, probeS = 0.62, probeL = 0.38;
  const hueSweep = [], satSweep = [], lumSweep = [];
  for (let i = 0; i <= 10; i++) {
    const r = i / 10;
    hueSweep.push(pc.pointColorWeight(sample(Object.assign({}, s, { hueRange: r })), probeH, probeS, probeL));
    satSweep.push(pc.pointColorWeight(sample(Object.assign({}, s, { saturationRange: r })), probeH, probeS, probeL));
    lumSweep.push(pc.pointColorWeight(sample(Object.assign({}, s, { luminanceRange: r })), probeH, probeS, probeL));
  }
  for (let i = 1; i <= 10; i++) {
    assert(hueSweep[i] >= hueSweep[i - 1] - 1e-12, `a wider hue range lowered the weight at step ${i}`);
    assert(satSweep[i] >= satSweep[i - 1] - 1e-12, `a wider saturation range lowered the weight at step ${i}`);
    assert(lumSweep[i] >= lumSweep[i - 1] - 1e-12, `a wider luminance range lowered the weight at step ${i}`);
  }
  checks += 3;
  ok(hueSweep[10] > hueSweep[0], 'a wide hue range reaches a colour a narrow one misses');
  ok(satSweep[10] > satSweep[0], 'a wide saturation range reaches a colour a narrow one misses');
  ok(lumSweep[10] > lumSweep[0], 'a wide luminance range reaches a colour a narrow one misses');
}

// --- 9. weight agrees with the independent derivation over a sweep --------
{
  let mismatches = 0, worst = 0;
  for (let i = 0; i < 8; i++) {
    for (let j = 0; j < 8; j++) {
      const s = {
        hue: (i * 0.137) % 1, saturation: ((j * 0.19) % 1), luminance: ((i + j) * 0.071) % 1,
        hueShift: 0.5, saturationShift: 0.5, luminanceShift: 0.5,
        hueRange: 0.02 + i * 0.11, saturationRange: 0.05 + j * 0.12, luminanceRange: 0.9 - i * 0.1,
      };
      for (let k = 0; k < 8; k++) {
        const h = (i * 0.31 + k * 0.083) % 1, sat = (j * 0.13 + k * 0.11) % 1, lum = (k * 0.17 + i * 0.05) % 1;
        const mine = pc.pointColorWeight(s, h, sat, lum), ref = refWeight(s, h, sat, lum);
        if (Math.abs(mine - ref) > 1e-12) { mismatches++; worst = Math.max(worst, Math.abs(mine - ref)); }
      }
    }
  }
  ok(mismatches === 0, `the weight matches the independent smoothstep derivation (${mismatches} mismatches, worst ${worst})`);
}

// --- 10. applying a sample moves the colour as documented -----------------
{
  // Hue 0.5 so that a +/-30 degree rotation stays inside the circle and the
  // direction of the move can be read off without wrapping.
  const src = pc.hsl01ToRgb(0.5, 0.7, 0.5);
  const srcHsl = pc.rgbToHsl01(src[0], src[1], src[2]);
  close(srcHsl[0], 0.5, 1e-12, 'the probe colour starts at hue 0.5');

  const hup = pc.applyPointColor(src[0], src[1], src[2], [sampleAt(src[0], src[1], src[2], { hueShift: 0.4 })]);
  const hupHsl = pc.rgbToHsl01(hup[0], hup[1], hup[2]);
  const expectedHue = (srcHsl[0] + 0.4 * (30 / 360) + 1) % 1;
  close(hupHsl[0], expectedHue, 1e-9, '+hueShift rotates the hue by 0.4 * 30 degrees');

  const hdown = pc.applyPointColor(src[0], src[1], src[2], [sampleAt(src[0], src[1], src[2], { hueShift: -0.4 })]);
  const hdownHsl = pc.rgbToHsl01(hdown[0], hdown[1], hdown[2]);
  close(hdownHsl[0], srcHsl[0] - 0.4 * (30 / 360), 1e-9, '-hueShift rotates the hue the other way');
  ok(hdownHsl[0] < srcHsl[0], '-hueShift moves the hue backwards, not forwards past the circle');

  const lup = pc.applyPointColor(src[0], src[1], src[2], [sampleAt(src[0], src[1], src[2], { luminanceShift: 0.5 })]);
  ok(pc.rgbToHsl01(lup[0], lup[1], lup[2])[2] > srcHsl[2], '+luminanceShift raises lightness');
  const ldown = pc.applyPointColor(src[0], src[1], src[2], [sampleAt(src[0], src[1], src[2], { luminanceShift: -0.5 })]);
  ok(pc.rgbToHsl01(ldown[0], ldown[1], ldown[2])[2] < srcHsl[2], '-luminanceShift lowers lightness');
  close(pc.rgbToHsl01(lup[0], lup[1], lup[2])[2], srcHsl[2] + 0.5 * 0.5, 1e-9,
    'a full luminance shift at weight 1 moves lightness by half the range');

  const sup = pc.applyPointColor(src[0], src[1], src[2], [sampleAt(src[0], src[1], src[2], { saturationShift: 0.5 })]);
  ok(pc.rgbToHsl01(sup[0], sup[1], sup[2])[1] > srcHsl[1], '+saturationShift raises saturation');
  const sdown = pc.applyPointColor(src[0], src[1], src[2], [sampleAt(src[0], src[1], src[2], { saturationShift: -0.5 })]);
  ok(pc.rgbToHsl01(sdown[0], sdown[1], sdown[2])[1] < srcHsl[1], '-saturationShift lowers saturation');

  // A sample that matches all three axes must leave saturation and lightness
  // alone when only the hue shift is set.
  close(hupHsl[1], srcHsl[1], 1e-9, 'a hue-only shift leaves saturation untouched');
  close(hupHsl[2], srcHsl[2], 1e-9, 'a hue-only shift leaves lightness untouched');

  // A grey pixel picked as the sample with only a luminance shift: hue and
  // saturation must stay put.
  const greyUp = pc.applyPointColor(0.4, 0.4, 0.4, [sampleAt(0.4, 0.4, 0.4, { luminanceShift: 0.6 })]);
  const greyHsl = pc.rgbToHsl01(greyUp[0], greyUp[1], greyUp[2]);
  ok(greyHsl[1] === 0, 'shifting the luminance of a grey leaves it grey');
  close(greyHsl[2], 0.4 + 0.6 * 0.5, 1e-9, 'a grey sample moves grey lightness by the weighted shift');
}

// --- 11. the shift fades with the weight ----------------------------------
{
  const s = sampleAt(0.2, 0.7, 0.5, { hueShift: 0.6, hueRange: 0.3, saturationRange: 1, luminanceRange: 1 });
  const base = pc.hsl01ToRgb(s.hue, s.saturation, s.luminance);
  const near = pc.applyPointColor(base[0], base[1], base[2], [s]);
  const edgeHue = s.hue + s.hueRange * 0.999;
  const edge = pc.hsl01ToRgb(edgeHue, s.saturation, s.luminance);
  const edgeOut = pc.applyPointColor(edge[0], edge[1], edge[2], [s]);
  const nearMove = Math.abs(pc.rgbToHsl01(near[0], near[1], near[2])[0] - s.hue);
  const edgeMove = Math.abs(pc.rgbToHsl01(edgeOut[0], edgeOut[1], edgeOut[2])[0] - edgeHue);
  ok(nearMove > edgeMove, 'a pixel at the centre moves far more than one at the edge of the range');
  ok(edgeMove < 1e-6, 'a pixel essentially at the edge of the range is essentially unchanged');
  // Weighted, not all-or-nothing: the move at half the range is strictly between.
  const halfHue = s.hue + s.hueRange * 0.5;
  const half = pc.hsl01ToRgb(halfHue, s.saturation, s.luminance);
  const halfOut = pc.applyPointColor(half[0], half[1], half[2], [s]);
  const halfMove = Math.abs(pc.rgbToHsl01(halfOut[0], halfOut[1], halfOut[2])[0] - halfHue);
  ok(halfMove > edgeMove && halfMove < nearMove, 'at half the range the shift is applied only partially');
  // The weighting must apply to the other two axes as well, or a range would be
  // a hard mask on saturation and luminance.
  const lumSample = sample({ hue: 0.25, saturation: 0.5, luminance: 0.5, luminanceShift: 0.5, hueRange: 1, saturationRange: 1, luminanceRange: 0.4 });
  const halfLum = pc.hsl01ToRgb(0.25, 0.5, 0.5 + 0.4 * 0.5);
  const halfLumOut = pc.applyPointColor(halfLum[0], halfLum[1], halfLum[2], [lumSample]);
  close(pc.rgbToHsl01(halfLumOut[0], halfLumOut[1], halfLumOut[2])[2], 0.7 + 0.5 * 0.5 * 0.5, 1e-9,
    'a luminance shift half way out in its range is applied at half strength');
  const satSample = sample({ hue: 0.25, saturation: 0.5, luminance: 0.5, saturationShift: -0.5, hueRange: 1, saturationRange: 0.4, luminanceRange: 1 });
  const halfSat = pc.hsl01ToRgb(0.25, 0.5 + 0.4 * 0.5, 0.5);
  const halfSatOut = pc.applyPointColor(halfSat[0], halfSat[1], halfSat[2], [satSample]);
  close(pc.rgbToHsl01(halfSatOut[0], halfSatOut[1], halfSatOut[2])[1], 0.7 * (1 - 0.5 * 0.5), 1e-9,
    'a saturation shift half way out in its range is applied at half strength');
  // ...and the luminance shift near the edge of its range is nearly nothing.
  const edgeLum = pc.hsl01ToRgb(0.25, 0.5, 0.5 + 0.4 * 0.98);
  const edgeLumOut = pc.applyPointColor(edgeLum[0], edgeLum[1], edgeLum[2], [lumSample]);
  ok(Math.abs(pc.rgbToHsl01(edgeLumOut[0], edgeLumOut[1], edgeLumOut[2])[2] - (0.5 + 0.4 * 0.98)) < 0.005,
    'a luminance shift at the very edge of its range barely moves the lightness');
}

// --- 12. a distant colour is left alone -----------------------------------
{
  // Same saturation and lightness, opposite side of the hue circle.
  const s = sampleAt(1, 0, 0, { hueShift: 0.8, saturationShift: 0.8, luminanceShift: 0.8 });
  const far = pc.applyPointColor(0, 0, 1, [s]);
  close(far[0], 0, 1e-9, 'a hue-distant colour keeps its red');
  close(far[1], 0, 1e-9, 'a hue-distant colour keeps its green');
  close(far[2], 1, 1e-9, 'a hue-distant colour keeps its blue');
  const alsoFar = pc.applyPointColor(0.2, 0.8, 0.6, [sampleAt(0.9, 0.1, 0.1, {
    hueShift: 1, saturationShift: 1, luminanceShift: 1,
  })]);
  const srcHsl = pc.rgbToHsl01(0.2, 0.8, 0.6);
  const outHsl = pc.rgbToHsl01(alsoFar[0], alsoFar[1], alsoFar[2]);
  close(outHsl[0], srcHsl[0], 1e-9, 'an unrelated colour keeps its hue');
  close(outHsl[1], srcHsl[1], 1e-9, 'an unrelated colour keeps its saturation');
  close(outHsl[2], srcHsl[2], 1e-9, 'an unrelated colour keeps its lightness');
}

// --- 13. greys and the hue axis -------------------------------------------
{
  // A chromatic sample with the widest possible ranges must still not capture a
  // grey through the hue axis.
  const chromatic = sample({ hue: 0, saturation: 1, luminance: 0.5, hueShift: 0.5, hueRange: 1 });
  ok(pc.pointColorWeight(chromatic, 0, 0, 0.5) === 0,
    'a grey pixel is not captured by a hue range even when the hue distance is 0');
  const greyIn = pc.applyPointColor(0.5, 0.5, 0.5, [chromatic]);
  ok(greyIn[0] === 0.5 && greyIn[1] === 0.5 && greyIn[2] === 0.5, 'a hue-only sample leaves a grey pixel alone');
  ok(pc.pointColorWeight(chromatic, 0, 1e-7, 0.5) === 0, 'a nearly grey pixel is also excluded');
  // The exclusion has to come from the hue axis itself rather than from the
  // saturation axis happening to be narrow. A barely-chromatic sample with a
  // saturation range wide enough to reach a grey isolates the hue axis.
  const nearNeutral = sample({ hue: 0, saturation: 0.05, luminance: 0.5, hueShift: 0.5, hueRange: 1, saturationRange: 1, luminanceRange: 1 });
  ok(pc.pointColorWeight(nearNeutral, 0, 0.05, 0.5) > 0.99, 'a barely-chromatic sample matches its own colour');
  ok(pc.pointColorWeight(nearNeutral, 0, 0, 0.5) === 0,
    'the hue axis alone excludes a grey, even when the saturation axis would admit it');
  ok(pc.pointColorWeight(nearNeutral, 0, 0.02, 0.5) > 0.99,
    'the same sample still admits a pixel that has a trace of colour');
  // The documented choice: an achromatic SAMPLE does gate through the other two
  // axes, because its own hue is just as meaningless as the pixel's.
  const achromaticSample = sample({ hue: 0.4, saturation: 0, luminance: 0.5, saturationRange: 0.5, luminanceRange: 0.5, luminanceShift: -0.5 });
  close(pc.pointColorWeight(achromaticSample, 0.9, 0, 0.5), 1, 1e-12,
    'an achromatic sample reports full weight on a grey pixel regardless of hue');
  ok(pc.pointColorWeight(achromaticSample, 0.9, 0.05, 0.5) > 0.9,
    'an achromatic sample still reaches a low-saturation pixel');
  const dimmed = pc.applyPointColor(0.5, 0.5, 0.5, [achromaticSample]);
  ok(pc.rgbToHsl01(dimmed[0], dimmed[1], dimmed[2])[2] < 0.5, 'an achromatic sample can still darken a grey');
  const satGrey = pc.applyPointColor(0.5, 0.5, 0.5, [sample({ hue: 0, saturation: 0, luminance: 0.5, saturationShift: 0.5, saturationRange: 0.5, luminanceRange: 0.5 })]);
  ok(Math.abs(satGrey[0] - 0.5) < 1e-9, 'a relative saturation shift cannot colourise a neutral pixel');
  // A grey pixel is inside the saturation band of a low-saturation sample.
  ok(pc.pointColorWeight(achromaticSample, 0.9, 0, 0.5) > 0.9,
    'a grey pixel sits at full weight on the saturation axis of a neutral sample');
}

// --- 14. saturation stays bounded and never inverts -----------------------
{
  for (const base of [[0.9, 0.1, 0.1], [0.2, 0.5, 0.8], [0.95, 0.9, 0.1], [0.3, 0.3, 0.31]]) {
    const hsl = pc.rgbToHsl01(base[0], base[1], base[2]);
    for (const shift of [-1, -0.75, -0.5, -0.01, 0, 0.01, 0.5, 0.75, 1]) {
      const out = pc.applyPointColor(base[0], base[1], base[2], [sampleAt(base[0], base[1], base[2], {
        saturationShift: shift, hueRange: 1, saturationRange: 1, luminanceRange: 1,
      })]);
      const outHsl = pc.rgbToHsl01(out[0], out[1], out[2]);
      assert(outHsl[1] >= 0 && outHsl[1] <= 1, `saturation left 0..1 for shift ${shift}: ${outHsl[1]}`);
      assert(out.every((c) => Number.isFinite(c) && c >= 0 && c <= 1), `channel out of range for shift ${shift}`);
      if (shift > 0) assert(outHsl[1] >= hsl[1] - 1e-12, `a positive shift lowered saturation at ${shift}`);
      if (shift < 0) assert(outHsl[1] <= hsl[1] + 1e-12, `a negative shift raised saturation at ${shift}`);
      if (shift === -1) assert(outHsl[1] === 0, 'a full negative saturation shift lands on exactly 0, not below');
    }
    checks++;
  }
  // The boost is asymptotic rather than clamped: a full positive shift on a
  // half-saturated colour lands on 0.75, strictly below 1. A naive
  // s * (1 + shift) clamped at 1 would land on 1 here, which is what makes the
  // slider go dead over its top half.
  const boostBase = pc.hsl01ToRgb(0.5, 0.5, 0.5);
  const boostSample = sample({ hue: 0.5, saturation: 0.5, luminance: 0.5, saturationShift: 1, hueRange: 1, saturationRange: 1, luminanceRange: 1 });
  const boostOut = pc.applyPointColor(boostBase[0], boostBase[1], boostBase[2], [boostSample]);
  close(pc.rgbToHsl01(boostOut[0], boostOut[1], boostOut[2])[1], 0.75, 1e-9,
    'a full positive saturation shift scales relatively towards 1, not onto it');
  const nearFull = pc.hsl01ToRgb(0.5, 0.9, 0.5);
  const nearFullOut = pc.applyPointColor(nearFull[0], nearFull[1], nearFull[2], [boostSample]);
  const nearFullS = pc.rgbToHsl01(nearFullOut[0], nearFullOut[1], nearFullOut[2])[1];
  ok(nearFullS > 0.9 && nearFullS < 1,
    `a boost on a nearly saturated colour stays short of 1 rather than flattening (${nearFullS})`);
  // Extreme values well outside the documented range must still be safe.
  const absurd = pc.applyPointColor(0.9, 0.2, 0.4, [sampleAt(0.9, 0.2, 0.4, {
    hueShift: 40, saturationShift: -40, luminanceShift: 40, hueRange: 9, saturationRange: -3, luminanceRange: 5,
  })]);
  ok(absurd.every((c) => Number.isFinite(c) && c >= 0 && c <= 1), 'out-of-range shift and range values are clamped safely');
  const nanSample = pc.applyPointColor(0.9, 0.2, 0.4, [sampleAt(0.9, 0.2, 0.4, {
    hueShift: NaN, saturationShift: NaN, luminanceShift: NaN, hueRange: NaN, saturationRange: NaN, luminanceRange: NaN,
  })]);
  ok(nanSample.every((c) => Number.isFinite(c)), 'a NaN-bearing sample produces a finite colour');
  const infSample = pc.applyPointColor(0.9, 0.2, 0.4, [sampleAt(0.9, 0.2, 0.4, {
    hueShift: Infinity, saturationShift: Infinity, luminanceShift: -Infinity, hueRange: Infinity,
    saturationRange: Infinity, luminanceRange: Infinity,
  })]);
  ok(infSample.every((c) => Number.isFinite(c) && c >= 0 && c <= 1), 'an Infinity-bearing sample produces a finite colour');
  const allNan = sample({ hue: NaN, saturation: NaN, luminance: NaN });
  const nanWeight = pc.pointColorWeight(allNan, NaN, NaN, NaN);
  ok(Number.isFinite(nanWeight) && nanWeight >= 0 && nanWeight <= 1,
    'a fully NaN sample and pixel still produce a weight inside 0..1');
  const nanApplied = pc.applyPointColor(0.3, 0.6, 0.2, [allNan]);
  ok(nanApplied[0] === 0.3 && nanApplied[1] === 0.6 && nanApplied[2] === 0.2,
    'a sample with NaN geometry but zero shifts is still an exact identity');
}

// --- 15. sample count above the maximum is ignored ------------------------
{
  const px15 = [0.3, 0.5, 0.7];
  const px15hsl = pc.rgbToHsl01(px15[0], px15[1], px15[2]);
  // A sample that matches this pixel exactly and would visibly wreck it if it
  // were applied. Without this control the "ignored" assertion would pass even
  // if the tail were applied, because a mismatched tail changes nothing.
  const rabid = sample({
    hue: px15hsl[0], saturation: px15hsl[1], luminance: px15hsl[2],
    hueShift: 1, saturationShift: 1, luminanceShift: 1,
    hueRange: 1, saturationRange: 1, luminanceRange: 1,
  });
  const rabidOnly = pc.applyPointColor(px15[0], px15[1], px15[2], [rabid]);
  assert(rabidOnly.some((c, i) => Math.abs(c - px15[i]) > 0.01),
    'the control sample really does change the colour when it is inside the cap');
  checks++;
  const many = [sample(), sample(), sample(), sample(), sample(), sample(), sample(), sample(), rabid, rabid, rabid, rabid];
  const out = pc.applyPointColor(px15[0], px15[1], px15[2], many);
  ok(out[0] === 0.3 && out[1] === 0.5 && out[2] === 0.7,
    'shifts past MAX_POINT_COLORS are ignored, not applied and not fatal');

  const first = sampleAt(0.8, 0.3, 0.4, { hueShift: 0.5, saturationShift: 0.4, luminanceShift: -0.3 });
  const filler = sampleAt(0.8, 0.3, 0.4, {
    hueShift: -0.5, saturationShift: 0.5, luminanceShift: 0.5,
    hueRange: 1, saturationRange: 1, luminanceRange: 1,
  });
  const padded = [first];
  for (let i = 0; i < 20; i++) padded.push(filler);
  const capped = pc.applyPointColor(0.8, 0.3, 0.4, padded);
  const only8 = pc.applyPointColor(0.8, 0.3, 0.4, padded.slice(0, 8));
  const justOne = pc.applyPointColor(0.8, 0.3, 0.4, [first]);
  ok(capped.every((c, i) => c === only8[i]), 'a 21-sample stack behaves exactly like its first 8 samples');
  assert(capped.some((c, i) => Math.abs(c - justOne[i]) > 1e-6),
    'samples 2..8 do contribute, so the cap is 8 and not 1');
  checks++;
  ok(pc.applyPointColor(0.5, 0.5, 0.5, new Array(64).fill(sample())).every((c) => c === 0.5),
    'a long list of zero-shift samples is still a bit-exact identity');
}

// --- 16. determinism and sample order -------------------------------------
{
  const src = [0.62, 0.31, 0.19];
  const stack = [
    sampleAt(0.62, 0.31, 0.19, { hueShift: 0.3, hueRange: 0.2, saturationRange: 1, luminanceRange: 1 }),
    sample({ hue: 0.05, saturation: 0.5, luminance: 0.5, hueShift: -0.2, saturationShift: 0.4, luminanceShift: 0.3 }),
  ];
  const a = pc.applyPointColor(src[0], src[1], src[2], stack);
  const b = pc.applyPointColor(src[0], src[1], src[2], stack);
  ok(a.every((c, i) => c === b[i]), 'applyPointColor is deterministic');
  const c = pc.applyPointColor(src[0], src[1], src[2], stack.slice());
  ok(c.every((v, i) => v === a[i]), 'a copied stack gives the identical result');
  const reordered = pc.applyPointColor(src[0], src[1], src[2], [stack[1], stack[0]]);
  assert(reordered.some((v, i) => Math.abs(v - a[i]) > 1e-9),
    'reversing the stack changes the result, because each sample sees the current colour');
  checks++;
  // The header promises in-order application. Prove the second sample is
  // weighted against the colour the first sample produced, not the original.
  const probe = [stack[0], sampleAt(0, 0, 0, { luminanceShift: 0.5, hueRange: 1, saturationRange: 1, luminanceRange: 1 })];
  // Rebuild the second sample against the *original* colour and show it differs.
  const afterFirst = pc.applyPointColor(src[0], src[1], src[2], [stack[0]]);
  const afterFirstHsl = pc.rgbToHsl01(afterFirst[0], afterFirst[1], afterFirst[2]);
  const srcHsl = pc.rgbToHsl01(src[0], src[1], src[2]);
  const secondAgainstCurrent = sample(Object.assign({}, probe[1], {
    hue: afterFirstHsl[0], saturation: afterFirstHsl[1], luminance: afterFirstHsl[2],
  }));
  const chained = pc.applyPointColor(src[0], src[1], src[2], [stack[0], secondAgainstCurrent]);
  const sequential = pc.applyPointColor(afterFirst[0], afterFirst[1], afterFirst[2], [secondAgainstCurrent]);
  ok(chained.every((v, i) => Math.abs(v - sequential[i]) <= 1e-9),
    'sample 2 is applied to the colour sample 1 produced');
  close(afterFirstHsl[2], srcHsl[2], 1e-9, 'a hue-only first sample preserves lightness along the chain');
  // A tight form of the same promise: a second sample whose ranges are
  // essentially zero only fires at all if it is measured against the colour the
  // first sample produced. Measured against the original colour instead, its
  // weight collapses to 0 and the two paths diverge completely.
  const tightA = sampleAt(src[0], src[1], src[2], { hueShift: 0.5, hueRange: 1, saturationRange: 1, luminanceRange: 1 });
  const afterTightA = pc.applyPointColor(src[0], src[1], src[2], [tightA]);
  const afterTightHsl = pc.rgbToHsl01(afterTightA[0], afterTightA[1], afterTightA[2]);
  const tightB = sample({
    hue: afterTightHsl[0], saturation: afterTightHsl[1], luminance: afterTightHsl[2],
    hueShift: 0.3, saturationShift: 0.3, luminanceShift: 0.3,
    hueRange: 1e-6, saturationRange: 1e-6, luminanceRange: 1e-6,
  });
  const chainedTight = pc.applyPointColor(src[0], src[1], src[2], [tightA, tightB]);
  const sequentialTight = pc.applyPointColor(afterTightA[0], afterTightA[1], afterTightA[2], [tightB]);
  ok(chainedTight.every((v, i) => Math.abs(v - sequentialTight[i]) <= 1e-9),
    'a near-zero-range second sample still fires, so it was measured against the updated colour');
  ok(Math.abs(pc.rgbToHsl01(chainedTight[0], chainedTight[1], chainedTight[2])[0] - afterTightHsl[0]) > 1e-6,
    'the tight second sample really did contribute rather than being a no-op control');
}

// --- 17. self-inverse sanity ----------------------------------------------
{
  // The reverse shift must undo part of the forward shift without overshooting
  // past the original colour, because the weight at the new position is smaller.
  const s = sample({ hue: 0.25, saturation: 0.6, luminance: 0.5, hueRange: 0.25, saturationRange: 1, luminanceRange: 1 });
  const src = pc.hsl01ToRgb(0.25, 0.6, 0.5);
  const forwardOnly = pc.applyPointColor(src[0], src[1], src[2], [sample(Object.assign({}, s, { hueShift: 0.4 }))]);
  const thereAndBack = pc.applyPointColor(src[0], src[1], src[2], [
    sample(Object.assign({}, s, { hueShift: 0.4 })),
    sample(Object.assign({}, s, { hueShift: -0.4 })),
  ]);
  const f = pc.rgbToHsl01(forwardOnly[0], forwardOnly[1], forwardOnly[2])[0];
  const b = pc.rgbToHsl01(thereAndBack[0], thereAndBack[1], thereAndBack[2])[0];
  ok(b > 0.25 - 1e-9 && b <= f + 1e-9, `the reverse shift lands between the original and the forward result (${b})`);
  ok(Math.abs(b - 0.25) < Math.abs(f - 0.25), 'the reverse shift moved the hue back towards the original');
  // hue symmetry: the weight does not care which of the two hues is the sample.
  const p = sample({ hue: 0.9, saturation: 0.5, luminance: 0.5 });
  close(pc.pointColorWeight(p, 0.05, 0.5, 0.5),
    pc.pointColorWeight(sample({ hue: 0.05, saturation: 0.5, luminance: 0.5 }), 0.9, 0.5, 0.5),
    1e-12, 'the hue weight is symmetric in the sample and the pixel');
  // An identity stack changes nothing and, applied on its own, an identity
  // stack is its own inverse.
  const twice = pc.applyPointColor(src[0], src[1], src[2], [sample()]);
  ok(twice.every((v, i) => v === src[i]), 'an identity stack is an exact no-op in both directions');
}

// --- 18. not a no-op: a matching sample with a tiny range must bite -------
{
  const px = [0.83, 0.24, 0.37];
  const pxHsl = pc.rgbToHsl01(px[0], px[1], px[2]);
  const tight = sampleAt(px[0], px[1], px[2], {
    hueShift: 0.5, saturationShift: 0.5, luminanceShift: 0.5,
    hueRange: 0.01, saturationRange: 0.01, luminanceRange: 0.01,
  });
  close(pc.pointColorWeight(tight, pxHsl[0], pxHsl[1], pxHsl[2]), 1, 1e-12,
    'a tiny range still gives full weight at the sampled colour');
  const out = pc.applyPointColor(px[0], px[1], px[2], [tight]);
  const moved = Math.max(Math.abs(out[0] - px[0]), Math.abs(out[1] - px[1]), Math.abs(out[2] - px[2]));
  ok(moved > 0.01, `applyPointColor with a matching sample really changes the colour (moved ${moved})`);
  // Each axis alone must move something too.
  const hueOnly = pc.applyPointColor(px[0], px[1], px[2], [sampleAt(px[0], px[1], px[2], { hueShift: 0.5, hueRange: 0.01, saturationRange: 1, luminanceRange: 1 })]);
  const hueOnlyHsl = pc.rgbToHsl01(hueOnly[0], hueOnly[1], hueOnly[2]);
  close(hueOnlyHsl[0], (pxHsl[0] + 0.5 * (30 / 360)) % 1, 1e-9, 'a hue-only shift alone rotates the hue');
  const lumOnly = pc.applyPointColor(px[0], px[1], px[2], [sampleAt(px[0], px[1], px[2], { luminanceShift: 0.5, hueRange: 1, saturationRange: 1, luminanceRange: 0.01 })]);
  close(pc.rgbToHsl01(lumOnly[0], lumOnly[1], lumOnly[2])[2], pxHsl[2] + 0.25, 1e-9,
    'a luminance-only shift alone raises lightness');
  // And a caller must be able to tell "nothing matched" from "matched": a
  // sample whose ranges exclude the pixel leaves it alone.
  const miss = pc.applyPointColor(px[0], px[1], px[2], [sampleAt(0.1, 0.9, 0.9, { hueShift: 0.5, hueRange: 0.01, saturationRange: 0.01, luminanceRange: 0.01 })]);
  ok(miss.every((v, i) => Math.abs(v - px[i]) <= 1e-9), 'a sample that does not match leaves the colour untouched');
}

console.log(`point color: ${checks} checks passed`);
