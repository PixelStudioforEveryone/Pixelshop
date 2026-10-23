// Optics: distortion, lateral chromatic aberration, edge-gated defringe, vignetting.
//
// Each stage is measured on its own: identity at its default, monotone in its
// parameter, opposite signs for opposite parameters, and for the fringe stage the
// property that separates defringing from a hue shift (an edge is corrected, a
// flat region is not touched at all).
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
    Uint8Array, Uint8ClampedArray, Float32Array, Promise, Error, Buffer,
    require: (n) => { if (n.startsWith('@kit.')) return {}; if(n.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), n + '.ets')); },
  }, { filename: file });
  return mod.exports;
}
const { applyOptics, opticsDefaults, opticsIsIdentity, distortionScale, vignetteGain } =
  load(root + '/edit/engine/OpticsCore.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
const W = 128, H = 96;
function settings(over) { return Object.assign(opticsDefaults(), over); }
function countDifferences(a, b) {
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}
function radiusOf(x, y) {
  const nx = 2 * (x + 0.5) / W - 1, ny = 2 * (y + 0.5) / H - 1;
  return Math.sqrt(nx * nx + ny * ny) / Math.SQRT2;
}
/** A smooth radial gradient, so a resample has something continuous to preserve. */
function gradientFrame() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const v = Math.round(255 * radiusOf(x, y));
      b[i] = v; b[i + 1] = Math.round(v * 0.7); b[i + 2] = Math.round(v * 0.4); b[i + 3] = 255;
    }
  }
  return b;
}
/** A single bright dot at a chosen radius, on black. */
function dotFrame(targetRadius) {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let i = 3; i < b.length; i += 4) b[i] = 255;
  let bestX = 0, bestY = 0, bestDistance = 1e9;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const distance = Math.abs(radiusOf(x, y) - targetRadius);
      if (distance < bestDistance) { bestDistance = distance; bestX = x; bestY = y; }
    }
  }
  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -1; dx <= 1; dx++) {
      const x = bestX + dx, y = bestY + dy;
      if (x < 0 || y < 0 || x >= W || y >= H) continue;
      const p = (y * W + x) * 4;
      b[p] = 255; b[p + 1] = 255; b[p + 2] = 255;
    }
  }
  return { pixels: b, x: bestX, y: bestY };
}
/** Radius of the brightest pixel in one channel. */
function peakRadius(pixels, channel) {
  let best = -1, bestRadius = 0;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const v = pixels[(y * W + x) * 4 + channel];
      if (v > best) { best = v; bestRadius = radiusOf(x, y); }
    }
  }
  return bestRadius;
}
/** Maximum second difference along a row: how unsmooth the result is. */
function maxSecondDifference(pixels, channel) {
  let worst = 0;
  for (let y = 0; y < H; y++) {
    for (let x = 1; x < W - 1; x++) {
      const a = pixels[(y * W + x - 1) * 4 + channel];
      const b = pixels[(y * W + x) * 4 + channel];
      const c = pixels[(y * W + x + 1) * 4 + channel];
      worst = Math.max(worst, Math.abs(a - 2 * b + c));
    }
  }
  return worst;
}

// --- 1. Identity, purity, well-formedness ---------------------------------
const base = gradientFrame();
const untouched = Uint8ClampedArray.from(base);
const identity = applyOptics(base, W, H, opticsDefaults());
ok(countDifferences(identity, base) === 0, 'the default settings are a byte-for-byte identity');
ok(identity !== base && identity.buffer !== base.buffer, 'it still returns a fresh buffer');
ok(countDifferences(base, untouched) === 0, 'the input is never mutated');
ok(opticsIsIdentity(opticsDefaults()), 'the defaults report themselves as the identity');
ok(opticsIsIdentity(null), 'a missing settings object is an identity');
// The guard must not be a constant: each stage's amount has to count.
ok(!opticsIsIdentity(settings({ distortion: 0.01 })), 'a non-zero distortion is not an identity');
ok(!opticsIsIdentity(settings({ vignetteAmount: 0.01 })), 'a non-zero vignette depth is not an identity');
ok(!opticsIsIdentity(settings({ chromaticAberration: 0.01 })), 'a non-zero CA is not an identity');
ok(!opticsIsIdentity(settings({ defringePurple: 0.01 })), 'a non-zero purple defringe is not an identity');
ok(!opticsIsIdentity(settings({ defringeGreen: 0.01 })), 'a non-zero green defringe is not an identity');
// Midpoint is a SHAPER of the falloff, not an amount: with depth 0 there is no
// falloff for it to move, so on its own it is correctly still an identity.
ok(opticsIsIdentity(settings({ vignetteMidpoint: 0.9 })),
  'moving only the midpoint is still an identity, since depth 0 has no falloff to move');
ok(countDifferences(applyOptics(base, W, H, settings({ vignetteMidpoint: 0.9 })), base) === 0,
  'and it really does change no pixel, which is why the guard treats it as identity');
ok(applyOptics(base, W, H, settings({ vignetteMidpoint: 0.9 })).length === base.length,
  'a midpoint-only change still returns a full frame');

// Distortion, CA and vignetting all act on any frame. The two defringe stages do
// not: they only touch a pixel whose hue is in their band, so they are checked
// against a frame that actually carries that fringe, further down.
const stages = {
  distortion: settings({ distortion: 0.8 }),
  ca: settings({ chromaticAberration: 0.8 }),
  vignette: settings({ vignetteAmount: -0.8 }),
};
for (const name of Object.keys(stages)) {
  const out = applyOptics(base, W, H, stages[name]);
  ok(countDifferences(out, base) > 0, 'the ' + name + ' stage alone changes the frame');
}
const combined = applyOptics(base, W, H, settings({ distortion: 0.5, vignetteAmount: -0.5,
  chromaticAberration: 0.5, defringePurple: 0.5, defringeGreen: 0.5 }));
let wellFormed = true, alphaKept = true;
for (let i = 0; i < combined.length; i++) {
  if (!Number.isInteger(combined[i]) || combined[i] < 0 || combined[i] > 255) wellFormed = false;
}
for (let i = 3; i < combined.length; i += 4) if (combined[i] !== base[i]) alphaKept = false;
ok(wellFormed, 'every output byte is an integer in 0..255 with all five stages active');
ok(alphaKept, 'alpha passes through byte for byte');
ok(countDifferences(applyOptics(base, W, H, stages.distortion), applyOptics(base, W, H, stages.distortion)) === 0,
  'the pipeline is deterministic');

// --- 2. Safety ------------------------------------------------------------
for (const dims of [[1, 1], [1, 40], [40, 1]]) {
  const w = dims[0], h = dims[1];
  const small = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < small.length; i++) small[i] = (i * 7) % 256;
  const out = applyOptics(small, w, h, settings({ distortion: 1, vignetteAmount: 1,
    chromaticAberration: 1, defringePurple: 1, defringeGreen: 1 }));
  let fine = out.length === small.length;
  for (let i = 0; i < out.length; i++) if (!Number.isFinite(out[i])) fine = false;
  ok(fine, 'a ' + w + 'x' + h + ' frame is handled without throwing or producing NaN');
}
const short = new Uint8ClampedArray(16);
const shortOut = applyOptics(short, W, H, settings({ distortion: 1, vignetteAmount: -1 }));
ok(shortOut.length === W * H * 4, 'a buffer shorter than the declared frame yields a full-length result');
let shortFinite = true;
for (let i = 0; i < shortOut.length; i++) if (!Number.isFinite(shortOut[i])) shortFinite = false;
ok(shortFinite, 'and that result is finite rather than reading out of bounds');
ok(applyOptics(base, W, H, null).length === base.length, 'a null settings object is tolerated');
ok(countDifferences(applyOptics(base, W, H, { distortion: NaN, vignetteAmount: NaN,
  vignetteMidpoint: NaN, chromaticAberration: NaN, defringePurple: NaN, defringeGreen: NaN }), base) === 0,
  'non-finite settings fall back to the identity instead of poisoning the frame');

// --- 3. Distortion -------------------------------------------------------
ok(distortionScale(0.5, 0) === 1, 'the distortion scale is exactly 1 at amount 0');
ok(distortionScale(0, 1) === 1, 'and exactly 1 at the centre for any amount');
ok(distortionScale(1, 1) < 1, 'positive distortion samples from a smaller source radius at the corner');
ok(distortionScale(1, -1) > 1, 'negative distortion samples from a larger one');
// Probe far enough out that the radial law has real leverage: the polynomial
// grows with r^2, so a dot near the centre would move only a fraction of a pixel
// and the measurement below would be dominated by the frame's discrete grid.
const PROBE_RADIUS = 0.75;
const dot = dotFrame(PROBE_RADIUS);
const dotIn = applyOptics(dot.pixels, W, H, settings({ distortion: 0.6 }));
const dotOut = applyOptics(dot.pixels, W, H, settings({ distortion: -0.6 }));
const dotStill = applyOptics(dot.pixels, W, H, opticsDefaults());
const centreRadius = peakRadius(dotStill, 0);
ok(Math.abs(centreRadius - PROBE_RADIUS) < 0.05, 'the fixture dot sits where it was placed (r = ' +
  centreRadius.toFixed(3) + ')');
const inRadius = peakRadius(dotIn, 0), outRadius = peakRadius(dotOut, 0);
ok(Math.abs(inRadius - PROBE_RADIUS) > 0.02, 'positive distortion moves the feature radially (r = ' +
  inRadius.toFixed(3) + ' vs ' + PROBE_RADIUS + ')');
ok(Math.abs(outRadius - PROBE_RADIUS) > 0.02, 'negative distortion moves it too (r = ' + outRadius.toFixed(3) + ')');
ok((inRadius - PROBE_RADIUS) * (outRadius - PROBE_RADIUS) < 0, 'and the two directions are OPPOSITE, which a ' +
  'sign error or a no-op rotation would not give (' + inRadius.toFixed(3) + ' vs ' + outRadius.toFixed(3) + ')');
const distortedGradient = applyOptics(gradientFrame(), W, H, settings({ distortion: 0.8 }));
ok(maxSecondDifference(distortedGradient, 0) <= maxSecondDifference(base, 0) + 1,
  'distortion uses bilinear interpolation: a smooth gradient stays smooth (worst second difference ' +
  maxSecondDifference(distortedGradient, 0) + ' vs ' + maxSecondDifference(base, 0) + ' in the source)');
const distinct = new Set();
for (let i = 0; i < distortedGradient.length; i += 4) distinct.add(distortedGradient[i]);
ok(distinct.size > 40, 'the resample produces interpolated values rather than replicating source ' +
  'pixels (' + distinct.size + ' distinct red levels)');
ok(countDifferences(applyOptics(base, W, H, settings({ distortion: 0.2 })), base) > 0,
  'a small distortion amount still does something');

// --- 4. Vignetting -------------------------------------------------------
ok(vignetteGain(0, -1, 0.5) === 1, 'the vignette gain is exactly 1 at the centre');
ok(vignetteGain(0.5, 0, 0.5) === 1, 'and at amount 0 anywhere');
ok(vignetteGain(1, -1, 0.5) < 1, 'negative amount darkens the corner');
ok(vignetteGain(1, 1, 0.5) > 1, 'positive amount brightens it');
const shallow = vignetteGain(0.5, -1, 0.2), deep = vignetteGain(0.5, -1, 0.8);
ok(Math.abs(shallow - deep) > 0.1, 'the midpoint genuinely moves the falloff: the gain at a fixed ' +
  'radius differs between midpoints 0.2 and 0.8 (' + shallow.toFixed(3) + ' vs ' + deep.toFixed(3) + ')');
ok(Math.abs(vignetteGain(0.5, -1, 0.5) - (1 - 0.7 * 0.5)) < 1e-9,
  'the midpoint is the HALF-STRENGTH radius: the gain there is halfway to full depth (got ' +
  vignetteGain(0.5, -1, 0.5).toFixed(4) + ')');
const gains = [-0.8, -0.4, 0, 0.4, 0.8].map((a) => vignetteGain(0.9, a, 0.5));
let gainMonotone = true;
for (let i = 1; i < gains.length; i++) if (!(gains[i] > gains[i - 1])) gainMonotone = false;
ok(gainMonotone, 'the corner gain is strictly monotone in the amount: ' +
  gains.map((g) => g.toFixed(3)).join(' < '));
const vignetted = applyOptics(base, W, H, settings({ vignetteAmount: -1 }));
const centrePixel = ((H >> 1) * W + (W >> 1)) * 4;
ok(vignetted[centrePixel] === base[centrePixel],
  'a real frame keeps its centre pixel exactly (the centre is pinned, not merely close)');
const cornerPixel = 0;
ok(vignetted[cornerPixel] < base[cornerPixel], 'and darkens the corner');
ok(vignetteGain(2, -1, 0.5) === vignetteGain(1.5, -1, 0.5),
  'the falloff saturates rather than growing without bound past the corners');

// --- 5. Lateral chromatic aberration ------------------------------------
const caDot = dotFrame(0.7);
const caOut = applyOptics(caDot.pixels, W, H, settings({ chromaticAberration: 1 }));
const greenRef = peakRadius(caDot.pixels, 1);
ok(countDifferences(applyOptics(caDot.pixels, W, H, settings({ chromaticAberration: 0 })), caDot.pixels) === 0,
  'zero chromatic aberration is a byte-for-byte identity');
const redRadius = peakRadius(caOut, 0), blueRadius = peakRadius(caOut, 2), greenRadius = peakRadius(caOut, 1);
ok(Math.abs(redRadius - greenRef) > 0.001, 'the red channel is displaced (r = ' + redRadius.toFixed(4) +
  ' vs green ' + greenRef.toFixed(4) + ')');
ok(Math.abs(blueRadius - greenRef) > 0.001, 'the blue channel is displaced too (r = ' +
  blueRadius.toFixed(4) + ')');
ok((redRadius - greenRef) * (blueRadius - greenRef) < 0,
  'and they move in OPPOSITE radial directions, which is what lateral CA is (' + redRadius.toFixed(4) +
  ' vs ' + blueRadius.toFixed(4) + ')');
ok(greenRadius === greenRef, 'green is untouched EXACTLY, not approximately');
let greenIdentical = true;
for (let i = 1; i < caDot.pixels.length; i += 4) if (caOut[i] !== caDot.pixels[i]) greenIdentical = false;
ok(greenIdentical, 'every green byte in the frame is unchanged');
const caMirror = applyOptics(caDot.pixels, W, H, settings({ chromaticAberration: -1 }));
const redMirror = peakRadius(caMirror, 0);
ok((redMirror - greenRef) * (redRadius - greenRef) < 0, 'a negative amount mirrors the red displacement (' +
  redMirror.toFixed(4) + ' vs ' + redRadius.toFixed(4) + ')');
const caCentre = dotFrame(0.05);
const caCentreOut = applyOptics(caCentre.pixels, W, H, settings({ chromaticAberration: 1 }));
ok(Math.abs(peakRadius(caCentreOut, 0) - peakRadius(caCentreOut, 2)) < 0.06,
  'the displacement vanishes at the centre, as a radial error must');

// --- 6. Defringe ---------------------------------------------------------
const FRINGE_ROW = 48;
/** A purple fringe on a hard edge, or a flat purple field, at one row. */
function purpleEdgeFrame() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const left = x < W / 2;
      let r = left ? 90 : 210, g = left ? 90 : 210, bl = left ? 90 : 210;
      if (x >= W / 2 - 2 && x < W / 2 + 2) { r = 210; g = 100; bl = 210; }
      b[i] = r; b[i + 1] = g; b[i + 2] = bl; b[i + 3] = 255;
    }
  }
  return b;
}
function flatPurpleFrame() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let i = 0; i < b.length; i += 4) { b[i] = 210; b[i + 1] = 100; b[i + 2] = 210; b[i + 3] = 255; }
  return b;
}
function fringeStrength(pixels) {
  let total = 0;
  const y = FRINGE_ROW;
  for (let x = W / 2 - 2; x < W / 2 + 2; x++) {
    const p = (y * W + x) * 4;
    total += (pixels[p] - pixels[p + 1]) + (pixels[p + 2] - pixels[p + 1]);
  }
  return total;
}
const purpleEdge = purpleEdgeFrame();
const fringeBefore = fringeStrength(purpleEdge);
ok(fringeBefore > 200, 'the fixture fringe is strongly purple to begin with (strength ' + fringeBefore + ')');
const strengths = [0, 0.25, 0.5, 0.75, 1].map((amount) =>
  fringeStrength(applyOptics(purpleEdge, W, H, settings({ defringePurple: amount }))));
ok(countDifferences(applyOptics(purpleEdge, W, H, settings({ defringePurple: 1 })), purpleEdge) > 0,
  'the purple stage alone changes a frame that carries a purple fringe (so it is not a no-op control)');
let fringeDecreasing = true;
for (let i = 1; i < strengths.length; i++) if (!(strengths[i] < strengths[i - 1])) fringeDecreasing = false;
ok(fringeDecreasing, 'purple defringe reduces the fringe monotonically across 0..1: ' +
  strengths.map((s) => s.toFixed(0)).join(' > '));
ok(strengths[4] < strengths[0] * 0.5, 'and removes most of it at full strength (' + strengths[0] +
  ' -> ' + strengths[4] + ')');
// The property that makes it DEFRINGE and not a hue shift.
const flatPurple = flatPurpleFrame();
const flatOut = applyOptics(flatPurple, W, H, settings({ defringePurple: 1 }));
ok(countDifferences(flatOut, flatPurple) === 0,
  'a flat purple region is left EXACTLY untouched, because the detector is gated on a luminance edge');
// Purple and green are independent controls.
function greenEdgeFrame() {
  const b = purpleEdgeFrame();
  for (let y = 0; y < H; y++) {
    for (let x = W / 2 - 2; x < W / 2 + 2; x++) {
      const p = (y * W + x) * 4;
      b[p] = 100; b[p + 1] = 210; b[p + 2] = 100;
    }
  }
  return b;
}
const greenEdge = greenEdgeFrame();
const greenBefore = applyOptics(greenEdge, W, H, opticsDefaults());
ok(countDifferences(applyOptics(greenEdge, W, H, settings({ defringePurple: 1 })), greenBefore) === 0,
  'the purple control does not touch a green fringe');
const greenFringe = (pixels) => {
  let total = 0;
  for (let x = W / 2 - 2; x < W / 2 + 2; x++) {
    const p = (FRINGE_ROW * W + x) * 4;
    total += pixels[p + 1] - Math.max(pixels[p], pixels[p + 2]);
  }
  return total;
};
const greenStrengths = [0, 0.5, 1].map((amount) =>
  greenFringe(applyOptics(greenEdge, W, H, settings({ defringeGreen: amount }))));
ok(greenStrengths[2] < greenStrengths[0] * 0.5, 'the green control removes a green fringe (' +
  greenStrengths[0] + ' -> ' + greenStrengths[2] + ')');
ok(countDifferences(applyOptics(greenEdge, W, H, settings({ defringeGreen: 1 })), greenEdge) > 0,
  'the green stage alone changes a frame that carries a green fringe');
ok(countDifferences(applyOptics(greenEdge, W, H, settings({ defringeGreen: 1 })),
  applyOptics(greenEdge, W, H, settings({ defringeGreen: 1 }))) === 0, 'defringe is deterministic');

console.log('PASS optics core: identity and purity, per-stage effect and monotonicity, distortion');
console.log('     direction and interpolation quality, vignette midpoint semantics and a pinned centre,');
console.log('     lateral CA moving red and blue in opposite directions with green byte-exact, and an');
console.log('     EDGE-GATED defringe that leaves a flat coloured region entirely alone.');
console.log('NOTE no Adobe parity is claimed or tested: the distortion model is a two-term radial');
console.log('     polynomial, the vignette falloff is a smoothstep rather than a measured illumination');
console.log('     profile, and defringe is a hue band gated on a luminance gradient rather than a trained');
console.log('     classifier. The stage is not on the render path yet and is not device-verified.');
console.log(checks + ' checks passed');
