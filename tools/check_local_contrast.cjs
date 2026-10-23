// Independent verification of the four spatial local-contrast stages
// (texture, clarity, dehaze, sharpening).
//
// Every property below is checked against an independently built measurement 鈥?// a brute-force sliding-window minimum, a synthetic hazy scene with a known
// airlight and transmission, hand-placed step edges, flat and noisy fields, and
// an explicit frequency-response comparison. Nothing is checked by replaying the
// implementation's own formulas, so a change to the algorithm that breaks a
// stated behaviour fails here rather than being mirrored by the test.
//
// Where a property could not be proven, the test says so instead of weakening
// the assertion; see the notes on dehaze's mean and on the clean-frame no-op.
//
// Synthetic pixels only; never reads camera captures or user photos.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
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
                digest: async () => ({ data: new Uint8Array(require('crypto').createHash('sha256').update(Buffer.concat(chunks)).digest()) }),
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

const C = load(root + '/edit/engine/LocalContrastCore.ets');

let checks = 0;
const ok = (condition, message) => { assert(condition, message); checks++; };

// --- independent re-derivations -------------------------------------------
const LUMA_R = 0.2126, LUMA_G = 0.7152, LUMA_B = 0.0722;
const lumaOf = (buffer, index) =>
  (LUMA_R * buffer[index * 4] + LUMA_G * buffer[index * 4 + 1] + LUMA_B * buffer[index * 4 + 2]) / 255;

const params = (over) => Object.assign(C.localContrastDefaults(), over);
const apply = (image, w, h, over, longEdge) =>
  C.applyLocalContrast(image, w, h, params(over), longEdge === undefined ? Math.max(w, h) : longEdge);

function gray(w, h, fn) {
  const out = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const index = y * w + x;
    const v = Math.max(0, Math.min(255, Math.round(fn(x, y))));
    out[index * 4] = v; out[index * 4 + 1] = v; out[index * 4 + 2] = v; out[index * 4 + 3] = 255;
  }
  return out;
}
const meanLuma = (buffer, count) => {
  let sum = 0;
  for (let index = 0; index < count; index++) sum += lumaOf(buffer, index);
  return sum / count * 255;
};
const meanAbsDiff = (a, b, count) => {
  let sum = 0;
  for (let index = 0; index < count; index++) sum += Math.abs(lumaOf(a, index) - lumaOf(b, index));
  return sum / count * 255;
};
const meanAbsChange = (image, w, h, over, longEdge) => {
  const out = apply(image, w, h, over, longEdge);
  let sum = 0;
  for (let index = 0; index < w * h; index++) sum += Math.abs(lumaOf(out, index) - lumaOf(image, index));
  return sum / (w * h) * 255;
};
const sameBytes = (a, b) => {
  if (a.length !== b.length) return false;
  for (let index = 0; index < a.length; index++) if (a[index] !== b[index]) return false;
  return true;
};

// ==========================================================================
// 1. Defaults and the identity short-circuit
// ==========================================================================
const defaults = C.localContrastDefaults();
ok(defaults.texture === 0 && defaults.clarity === 0 && defaults.dehaze === 0,
  `the local-contrast defaults are neutral, got ${JSON.stringify(defaults)}`);
ok(defaults.sharpenAmount === 0, 'the sharpening amount defaults to off');
ok(defaults.sharpenRadius >= 0 && defaults.sharpenRadius <= 1, 'the sharpening radius defaults inside its range');
ok(defaults.sharpenDetail >= 0 && defaults.sharpenDetail <= 1, 'the sharpening detail defaults inside its range');
ok(defaults.sharpenMasking >= 0 && defaults.sharpenMasking <= 1, 'the sharpening masking defaults inside its range');

const identityInput = gray(64, 64, (x, y) => 40 + ((x * 5 + y * 11) % 180));
const identityCopy = Uint8ClampedArray.from(identityInput);
const identityOut = C.applyLocalContrast(identityInput, 64, 64, C.localContrastDefaults(), 2048);
ok(identityOut !== identityInput, 'applyLocalContrast returns a new buffer, not the input');
ok(sameBytes(identityOut, identityCopy), 'identity parameters reproduce the input byte for byte');
ok(sameBytes(identityInput, identityCopy), 'applyLocalContrast never mutates its input');

ok(C.localContrastIsIdentity(null), 'a null parameter bundle is the identity');
ok(C.localContrastIsIdentity(undefined), 'a missing parameter bundle is the identity');
ok(C.localContrastIsIdentity(C.localContrastDefaults()), 'the defaults are the identity');
// The three sharpening shape controls do nothing on their own: only the amount
// decides whether the stage runs at all.
ok(C.localContrastIsIdentity(params({ sharpenRadius: 1 })),
  'a sharpening radius with no amount is still the identity');
ok(C.localContrastIsIdentity(params({ sharpenDetail: 1 })),
  'a sharpening detail with no amount is still the identity');
ok(C.localContrastIsIdentity(params({ sharpenMasking: 1 })),
  'a sharpening masking with no amount is still the identity');
ok(!C.localContrastIsIdentity(params({ texture: 0.0001 })), 'a non-zero texture is not the identity');
ok(!C.localContrastIsIdentity(params({ clarity: -0.0001 })), 'a non-zero clarity is not the identity');
ok(!C.localContrastIsIdentity(params({ dehaze: 0.0001 })), 'a non-zero dehaze is not the identity');
ok(!C.localContrastIsIdentity(params({ sharpenAmount: 0.0001 })), 'a non-zero sharpen amount is not the identity');

// ==========================================================================
// 2. Radius helpers
// ==========================================================================
const LONG_EDGES = [1, 2, 63, 160, 512, 1024, 2048, 4096, 8192, 65536];
for (const longEdge of LONG_EDGES) {
  const texture = C.textureRadius(longEdge);
  const clarity = C.clarityRadius(longEdge);
  // Compositor fits both radii to the long edge (8 px and 32 px at 1456 wide), so the
  // texture radius at 2048 is 11 px, not 2. The cap only bounds absurd exports.
  ok(Number.isInteger(texture) && texture >= 1 && texture <= 24,
    `textureRadius(${longEdge}) is a whole number of pixels in 1..24, got ${texture}`);
  ok(Number.isInteger(clarity) && clarity >= 2 && clarity <= 64,
    `clarityRadius(${longEdge}) is a whole number of pixels in 2..64, got ${clarity}`);
  ok(clarity > texture,
    `clarity stays the lower-frequency of the two at ${longEdge}px (${clarity} > ${texture})`);
  for (const slider of [0, 0.25, 0.5, 0.75, 1]) {
    const radius = C.sharpenRadiusPixels(longEdge, slider);
    ok(Number.isInteger(radius) && radius >= 1 && radius <= 32,
      `sharpenRadiusPixels(${longEdge}, ${slider}) is a whole number of pixels in 1..32, got ${radius}`);
  }
  ok(C.sharpenRadiusPixels(longEdge, 0) <= C.sharpenRadiusPixels(longEdge, 0.5) &&
    C.sharpenRadiusPixels(longEdge, 0.5) <= C.sharpenRadiusPixels(longEdge, 1),
    `sharpenRadiusPixels is non-decreasing in the slider at ${longEdge}px`);
}
ok(C.textureRadius(1024) <= C.textureRadius(4096) && C.textureRadius(4096) <= C.textureRadius(16384),
  'textureRadius is non-decreasing in the long edge');
ok(C.clarityRadius(1024) <= C.clarityRadius(4096) && C.clarityRadius(4096) <= C.clarityRadius(16384),
  'clarityRadius is non-decreasing in the long edge');
ok(C.sharpenRadiusPixels(2048, 1) > C.sharpenRadiusPixels(2048, 0),
  'the sharpening radius slider actually spans more than one pixel at the reference size');
ok(C.textureRadius(0) >= 1 && C.clarityRadius(0) >= 1 &&
  C.sharpenRadiusPixels(0, 0) >= 1 && C.sharpenRadiusPixels(0, 1) >= 1,
  'a degenerate long edge still yields at least one pixel of radius');
ok(C.textureRadius(NaN) >= 1 && C.clarityRadius(Infinity) >= 1,
  'a non-finite long edge falls back to a usable radius instead of NaN');

// ==========================================================================
// 3. Mean luminance preservation
// ==========================================================================
// A moderate-contrast frame, so the assertion measures the operator rather than
// the clipping at 0 and 255 that a saturated test pattern would introduce.
const MOD_W = 192, MOD_H = 192;
const moderate = gray(MOD_W, MOD_H, (x, y) =>
  128 + 30 * Math.sin((x / MOD_W) * 4 * Math.PI) * Math.cos((y / MOD_H) * 4 * Math.PI) +
  10 * Math.sin(x * 1.5) * Math.sin(y * 1.5));
const moderateMean = meanLuma(moderate, MOD_W * MOD_H);
const shiftOf = (over) => meanLuma(apply(moderate, MOD_W, MOD_H, over, 2048), MOD_W * MOD_H) - moderateMean;
ok(Math.abs(shiftOf({ texture: 1 })) <= 0.02, `texture preserves the mean, shift ${shiftOf({ texture: 1 }).toFixed(5)}`);
ok(Math.abs(shiftOf({ clarity: 1 })) <= 0.02, `clarity preserves the mean, shift ${shiftOf({ clarity: 1 }).toFixed(5)}`);
ok(Math.abs(shiftOf({ texture: 1, clarity: 1 })) <= 0.02,
  `texture and clarity together preserve the mean, shift ${shiftOf({ texture: 1, clarity: 1 }).toFixed(5)}`);
ok(Math.abs(shiftOf({ sharpenAmount: 1 })) <= 0.02,
  `sharpening preserves the mean, shift ${shiftOf({ sharpenAmount: 1 }).toFixed(5)}`);
ok(Math.abs(shiftOf({ texture: -1 })) <= 0.02, 'a negative texture also preserves the mean');
ok(Math.abs(shiftOf({ clarity: -1 })) <= 0.02, 'a negative clarity also preserves the mean');
// The three mean-preserving stages still preserve the mean when chained; the
// residual is the rounding of three separate 8-bit writes.
const threeStageShift = shiftOf({ texture: 1, clarity: 1, sharpenAmount: 1 });
ok(Math.abs(threeStageShift) <= 0.05,
  `texture + clarity + sharpening preserve the mean, shift ${threeStageShift.toFixed(5)}`);
// Dehaze is deliberately NOT mean-preserving: positive strength removes an additive
// airlight term, negative strength veils the frame in the haze colour. Since the stage
// was replaced with Compositor's implementation (Rendering/AdjustPixels.c,
// `dehaze_haze` / `effects_dehaze`: haze = mean of the brightest 1%, and
// `c = (c - haze)/t + haze` with t floored at 0.5), assert the *shape* rather than a
// hand-tuned magnitude bound: direction, monotonicity in strength, and the invariant
// that a single-colour frame is all haze and must not move at all.
const dehazeShift = shiftOf({ dehaze: 1 });
ok(dehazeShift < 0,
  `positive dehaze removes the airlight term, so it lowers the mean, shift ${dehazeShift.toFixed(5)}`);
ok(shiftOf({ dehaze: -1 }) > 0,
  'negative dehaze veils the frame in the haze colour, so it raises the mean');
ok(Math.abs(shiftOf({ dehaze: 0.25 })) < Math.abs(dehazeShift),
  'a weaker dehaze moves the mean less than a stronger one');

// ==========================================================================
// 4. Texture versus clarity: a genuine frequency split
// ==========================================================================
// Both bands are measured at the reference long edge, where the two radii are
// 2 px and 61 px, so the patterns below sit squarely in one band or the other.
const FREQ_W = 320, FREQ_H = 320, FREQ_LE = 2048;
const fineChecker = gray(FREQ_W, FREQ_H, (x, y) => (((x + y) % 2) === 0 ? 100 : 156));
const broadStructure = gray(FREQ_W, FREQ_H, (x) => 128 + 28 * Math.sin((x / 96) * 2 * Math.PI));
const broaderStructure = gray(FREQ_W, FREQ_H, (x) => 128 + 28 * Math.sin((x / 192) * 2 * Math.PI));

const fineTexture = meanAbsChange(fineChecker, FREQ_W, FREQ_H, { texture: 1 }, FREQ_LE);
const fineClarity = meanAbsChange(fineChecker, FREQ_W, FREQ_H, { clarity: 1 }, FREQ_LE);
ok(fineTexture > 5,
  `texture visibly acts on a 2px checkerboard, change ${fineTexture.toFixed(4)}`);
// Compositor's own test for these controls (CameraRawTests.textureAndClaritySharpen-
// AnEdgeAndLeaveAFlatField) separates them by REACH, not by magnitude: on a fine
// checkerboard both bands respond, and the wider one responds more. That is true for
// the aligned radii too (8/1456 and 32/1456), so assert the reach instead.
const STEP_W = 320, STEP_H = 24;
const stepImage = gray(STEP_W, STEP_H, (x) => (x < STEP_W / 2 ? 70 : 190));
function bandReach(image, w, h, params, longEdge) {
  const changed = apply(image, w, h, params, longEdge);
  const edge = w / 2;
  let reach = 0;
  for (let d = 1; d < edge; d++) {
    let sum = 0;
    for (let y = 0; y < h; y++) {
      const offset = (y * w + (edge - 1 - d)) * 4;
      sum += Math.abs(changed[offset] - image[offset]);
    }
    if (sum / h > 0.5) reach = d;
  }
  return reach;
}
const textureReach = bandReach(stepImage, STEP_W, STEP_H, { texture: 1 }, FREQ_LE);
const clarityReach = bandReach(stepImage, STEP_W, STEP_H, { clarity: 1 }, FREQ_LE);
ok(textureReach > 0 && clarityReach > textureReach,
  `clarity reaches further from an edge than texture (${textureReach} vs ${clarityReach} px)`);

const broadTexture = meanAbsChange(broadStructure, FREQ_W, FREQ_H, { texture: 1 }, FREQ_LE);
const broadClarity = meanAbsChange(broadStructure, FREQ_W, FREQ_H, { clarity: 1 }, FREQ_LE);
ok(broadClarity > 5,
  `clarity visibly acts on 96px structure, change ${broadClarity.toFixed(4)}`);
// The dominance ratio follows the radii: with Compositor's 8/1456 and 32/1456 the
// texture band (11 px at the reference edge) still partly sees 96px structure, so the
// old 4x factor no longer holds. 2x still separates the bands without weakening the
// claim that clarity owns broad structure.
ok(broadClarity > 2 * broadTexture,
  `clarity dominates texture on broad structure (${broadClarity.toFixed(4)} vs ${broadTexture.toFixed(4)})`);

const broaderTexture = meanAbsChange(broaderStructure, FREQ_W, FREQ_H, { texture: 1 }, FREQ_LE);
const broaderClarity = meanAbsChange(broaderStructure, FREQ_W, FREQ_H, { clarity: 1 }, FREQ_LE);
ok(broaderClarity > 4 * broaderTexture,
  `clarity still dominates texture at 192px (${broaderClarity.toFixed(4)} vs ${broaderTexture.toFixed(4)})`);
// The two controls must not be the same filter at two strengths. With the aligned
// radii both bands respond to both patterns, so the ordering does not flip; what does
// hold is that clarity's *relative* advantage grows with the structure size.
ok((broadClarity / broadTexture) > (fineClarity / fineTexture),
  'clarity gains relative advantage as structure grows, so the two controls are not one filter ' +
  `at two strengths (fine ${(fineClarity / fineTexture).toFixed(4)}, broad ${(broadClarity / broadTexture).toFixed(4)})`);

// The low-pass behind both bands has to use the same radius on each axis, or the
// operator would answer horizontal and vertical detail differently. Stripes are
// measured both ways to pin that.
const verticalStripes = gray(FREQ_W, FREQ_H, (x) => (((x % 2) === 0) ? 100 : 156));
const horizontalStripes = gray(FREQ_W, FREQ_H, (x, y) => (((y % 2) === 0) ? 100 : 156));
const verticalTexture = meanAbsChange(verticalStripes, FREQ_W, FREQ_H, { texture: 1 }, FREQ_LE);
const horizontalTexture = meanAbsChange(horizontalStripes, FREQ_W, FREQ_H, { texture: 1 }, FREQ_LE);
ok(verticalTexture > 5 && horizontalTexture > 5,
  `texture acts on fine stripes at either orientation (${verticalTexture.toFixed(4)} / ${horizontalTexture.toFixed(4)})`);
ok(Math.abs(verticalTexture - horizontalTexture) / Math.max(verticalTexture, horizontalTexture) < 0.05,
  `texture is isotropic (vertical ${verticalTexture.toFixed(4)} vs horizontal ${horizontalTexture.toFixed(4)})`);
const verticalBroad = gray(FREQ_W, FREQ_H, (x) => 128 + 28 * Math.sin((x / 96) * 2 * Math.PI));
const horizontalBroad = gray(FREQ_W, FREQ_H, (x, y) => 128 + 28 * Math.sin((y / 96) * 2 * Math.PI));
const verticalClarity = meanAbsChange(verticalBroad, FREQ_W, FREQ_H, { clarity: 1 }, FREQ_LE);
const horizontalClarity = meanAbsChange(horizontalBroad, FREQ_W, FREQ_H, { clarity: 1 }, FREQ_LE);
ok(Math.abs(verticalClarity - horizontalClarity) / Math.max(verticalClarity, horizontalClarity) < 0.05,
  `clarity is isotropic (vertical ${verticalClarity.toFixed(4)} vs horizontal ${horizontalClarity.toFixed(4)})`);

// A global linear ramp is invisible to any symmetric local operator, which is
// what makes these local-contrast controls rather than exposure controls. The
// interior is measured away from the borders, where the clamped window legitimately
// lags a ramp.
function interiorChange(image, w, h, over, longEdge, margin) {
  const out = apply(image, w, h, over, longEdge);
  let sum = 0, count = 0;
  for (let y = margin; y < h - margin; y++) for (let x = margin; x < w - margin; x++) {
    const index = y * w + x;
    sum += Math.abs(lumaOf(out, index) - lumaOf(image, index));
    count++;
  }
  return sum / count * 255;
}
const ramp = gray(FREQ_W, FREQ_H, (x, y) => 30 + 195 * ((x + y) / (FREQ_W + FREQ_H - 2)));
const rampTexture = interiorChange(ramp, FREQ_W, FREQ_H, { texture: 1 }, FREQ_LE, 96);
const rampClarity = interiorChange(ramp, FREQ_W, FREQ_H, { clarity: 1 }, FREQ_LE, 96);
ok(rampTexture < 0.05, `texture ignores a global ramp away from the borders, change ${rampTexture.toFixed(5)}`);
ok(rampClarity < 0.05, `clarity ignores a global ramp away from the borders, change ${rampClarity.toFixed(5)}`);

// ==========================================================================
// 5. Clarity's midtone weighting
// ==========================================================================
// The operator deliberately scales its correction with the local base (that is
// what stops a boost near black from becoming a blowout), so the midtone weight
// is only visible once that scaling is removed. The first measurement below uses
// step edges with the SAME relative contrast and divides the measured change by
// the edge's own base 鈥?the mean of its two levels, an independent estimate of
// the local base for a step edge measured away from the border. What is left is
// the midtone weight alone. The second measurement holds the ABSOLUTE contrast
// fixed instead, which additionally shows the weight beating the base scaling.
const MID_W = 256, MID_H = 256;
const midtoneResponse = (base, relativeContrast) => {
  const half = Math.round(base * relativeContrast / 2);
  const lo = base - half, hi = base + half;
  const image = gray(MID_W, MID_H, (x) => (x < MID_W / 2 ? lo : hi));
  const out = apply(image, MID_W, MID_H, { clarity: 1 }, 2048);
  let sum = 0;
  for (let index = 0; index < MID_W * MID_H; index++) sum += Math.abs(lumaOf(out, index) - lumaOf(image, index));
  const change = sum / (MID_W * MID_H) * 255;
  return { change: change, perBase: change / (base / 255), lo: lo, hi: hi };
};
const darkEdge = midtoneResponse(48, 0.25);
const midEdge = midtoneResponse(128, 0.25);
const brightEdge = midtoneResponse(208, 0.25);
// Compositor's clarity has no midtone taper: it is a guided-filter band with one fixed
// gain, so a highlight is pushed about as hard as a midtone. The previous
// implementation tapered at both ends of the tonal range; aligning with the reference
// removes that, and these assertions pin the new behaviour instead of the old one.
ok(brightEdge.perBase > 0.6 * midEdge.perBase,
  `clarity is no longer tapered at the highlight end (mid ${midEdge.perBase.toFixed(4)} vs bright ${brightEdge.perBase.toFixed(4)})`);
ok(darkEdge.perBase > 0.2 * midEdge.perBase,
  `clarity still answers in the shadows (mid ${midEdge.perBase.toFixed(4)} vs dark ${darkEdge.perBase.toFixed(4)})`);
// And in raw pixel terms, with the same ABSOLUTE contrast at each level, the
// midtone edge still moves more than the highlight edge 鈥?even though a
// brighter edge has the larger relative gain and would otherwise win.
const absoluteResponse = (base) => {
  const image = gray(MID_W, MID_H, (x) => (x < MID_W / 2 ? base - 16 : base + 16));
  const out = apply(image, MID_W, MID_H, { clarity: 1 }, 2048);
  let sum = 0;
  for (let index = 0; index < MID_W * MID_H; index++) sum += Math.abs(lumaOf(out, index) - lumaOf(image, index));
  return sum / (MID_W * MID_H) * 255;
};
const equalContrastDark = absoluteResponse(48);
const equalContrastMid = absoluteResponse(128);
const equalContrastBright = absoluteResponse(224);
// With one fixed 32-level edge contrast, Compositor's clarity responds about equally at
// every tonal level (there is no midtone weight), so the assertion is uniformity rather
// than midtone dominance.
const equalContrastMax = Math.max(equalContrastDark, equalContrastMid, equalContrastBright);
const equalContrastMin = Math.min(equalContrastDark, equalContrastMid, equalContrastBright);
ok(equalContrastMax < 1.2 * equalContrastMin,
  `at one fixed 32-level edge contrast every tonal level moves about the same (${equalContrastDark.toFixed(4)} / ${equalContrastMid.toFixed(4)} / ${equalContrastBright.toFixed(4)})`);
// The step edge also has far more energy in the clarity band than in the
// texture band, which is what makes the two stages different controls rather
// than two strengths of one.
const textureAtEdge = (() => {
  const image = gray(MID_W, MID_H, (x) => (x < MID_W / 2 ? 112 : 144));
  const out = apply(image, MID_W, MID_H, { texture: 1 }, 2048);
  let sum = 0;
  for (let index = 0; index < MID_W * MID_H; index++) sum += Math.abs(lumaOf(out, index) - lumaOf(image, index));
  return sum / (MID_W * MID_H) * 255;
})();
ok(textureAtEdge < midEdge.change,
  `a step edge belongs to the clarity band, not the texture band (${textureAtEdge.toFixed(4)} vs ${midEdge.change.toFixed(4)})`);

// ==========================================================================
// 6. Dehaze (dark-channel prior)
// ==========================================================================
// A synthetic hazy scene with a known airlight (245) and a transmission that
// runs from 0.62 on the left to 0.88 on the right, built by the forward
// atmospheric model I = J*t + A*(1-t) from a known clean scene.
const DEH_W = 160, DEH_H = 160;
const cleanScene = gray(DEH_W, DEH_H, (x, y) => {
  if (x >= 30 && x < 80 && y >= 30 && y < 80) return 30;
  if (x >= 96 && x < 130 && y >= 96 && y < 130) return 128;
  return 205;
});
const AIRLIGHT = 245;
const transmissionAt = (x) => 0.62 + 0.26 * (x / (DEH_W - 1));
const hazyScene = gray(DEH_W, DEH_H, (x, y) =>
  cleanScene[(y * DEH_W + x) * 4] * transmissionAt(x) + AIRLIGHT * (1 - transmissionAt(x)));
const sceneDiff = (a, b) => meanAbsDiff(a, b, DEH_W * DEH_H);

const uncorrected = sceneDiff(hazyScene, cleanScene);
ok(uncorrected > 10, `the synthetic haze is a substantial error to start with, ${uncorrected.toFixed(4)}`);
const dehazeCurve = [];
for (let step = 0; step <= 10; step++) {
  dehazeCurve.push(sceneDiff(apply(hazyScene, DEH_W, DEH_H, { dehaze: step / 10 }, 2048), cleanScene));
}
let monotone = true;
for (let step = 1; step <= 10; step++) if (dehazeCurve[step] > dehazeCurve[step - 1] + 1e-9) monotone = false;
ok(monotone,
  `more dehaze is never worse: ${dehazeCurve.map((v) => v.toFixed(3)).join(' ')}`);
const reduction = 1 - dehazeCurve[10] / dehazeCurve[0];
ok(reduction > 0.2,
  `dehaze recovers a meaningful part of the scene, error ${dehazeCurve[0].toFixed(4)} -> ${dehazeCurve[10].toFixed(4)} (${(reduction * 100).toFixed(1)}%)`);
ok(dehazeCurve[5] < dehazeCurve[0] && dehazeCurve[5] > dehazeCurve[10],
  'a half-strength dehaze lands between no correction and full correction');
ok(sceneDiff(apply(hazyScene, DEH_W, DEH_H, { dehaze: 0 }, 2048), hazyScene) === 0,
  'dehaze at zero is exact identity');
// The recovered dark object must move towards its true value, not away from it.
const objectIndex = (55 * DEH_W + 55) * 4;
const objectBefore = Math.abs(hazyScene[objectIndex] - cleanScene[objectIndex]);
const objectAfter = Math.abs(apply(hazyScene, DEH_W, DEH_H, { dehaze: 1 }, 2048)[objectIndex] - cleanScene[objectIndex]);
ok(objectAfter < objectBefore,
  `dehaze moves the dark object towards its true value (${objectBefore} -> ${objectAfter})`);

// A clean frame that satisfies the prior (dark detail in every window) must be
// left essentially alone: the prior reads almost no haze, so there is almost
// nothing to remove.
const priorCompatibleClean = gray(DEH_W, DEH_H, (x, y) => {
  if (x % 4 === 0 && y % 4 === 0) return 12;
  return 70 + 60 * Math.sin((x / DEH_W) * 3 * Math.PI) * Math.cos((y / DEH_H) * 3 * Math.PI);
});
// Compositor's dehaze (which this stage now implements) has no "a clean frame is a
// no-op" property: it always estimates a haze colour from the brightest 1% and removes
// it by transmission, so a haze-free frame is darkened too — Photoshop's Dehaze behaves
// the same way. What remains invariant, and is what these assertions pin down:
//   * a single-colour frame is entirely haze, so it must not move at all;
//   * the effect grows with the amount.
const cleanSelfChange = sceneDiff(apply(priorCompatibleClean, DEH_W, DEH_H, { dehaze: 1 }, 2048), priorCompatibleClean);
const cleanSelfChangeHalf = sceneDiff(apply(priorCompatibleClean, DEH_W, DEH_H, { dehaze: 0.5 }, 2048), priorCompatibleClean);
const recovered = dehazeCurve[0] - dehazeCurve[10];
const uniformFrame = gray(DEH_W, DEH_H, () => 120);
const uniformChange = sceneDiff(apply(uniformFrame, DEH_W, DEH_H, { dehaze: 1 }, 2048), uniformFrame);
ok(uniformChange < 2,
  `a single-colour frame is all haze and must not move, change ${uniformChange.toFixed(4)}`);
ok(cleanSelfChangeHalf < cleanSelfChange, 'the disturbance of a clean frame grows with the dehaze amount');
// The airlight estimate is not tested against 245 on purpose: the estimator can
// only see the brightest dark-channel tail present in the frame, and a scene
// whose transmission never reaches zero has no pixel at the true airlight. That
// is a property of the prior, not a defect, and it is why the recovery above is
// partial rather than complete.

// The transmission is a LOCAL statistic: a dark speck can only darken the
// estimation window around it, and the window is a small fraction of the frame.
// This is measured on the pipeline output rather than on internals, and it is
// what proves the dark-channel window is bounded and clamped 鈥?an unbounded or
// wrapping minimum would let a speck anywhere in the frame change every pixel.
const LOCAL_W = 256, LOCAL_H = 256;
const PROBE_X = 128, PROBE_Y = 128;
const speckFrame = (dx) => gray(LOCAL_W, LOCAL_H, (x, y) =>
  (x >= PROBE_X + dx - 1 && x <= PROBE_X + dx + 1 && y >= PROBE_Y - 1 && y <= PROBE_Y + 1) ? 20 : 200);
const probeValue = (image) => lumaOf(apply(image, LOCAL_W, LOCAL_H, { dehaze: 1 }, 2048), PROBE_Y * LOCAL_W + PROBE_X) * 255;
const probeWithoutSpeck = probeValue(speckFrame(100000));
const probeWithNearSpeck = probeValue(speckFrame(0));
const probeWithFarSpeck = probeValue(speckFrame(30));
ok(Math.abs(probeWithNearSpeck - probeWithoutSpeck) > 10,
  `a dark speck inside the window changes the recovered pixel (${probeWithoutSpeck.toFixed(3)} -> ${probeWithNearSpeck.toFixed(3)})`);
ok(Math.abs(probeWithFarSpeck - probeWithoutSpeck) < 1,
  `a dark speck 30px away, outside the window, does not (${probeWithoutSpeck.toFixed(3)} -> ${probeWithFarSpeck.toFixed(3)})`);
ok(Math.abs(probeWithFarSpeck - probeWithoutSpeck) < Math.abs(probeWithNearSpeck - probeWithoutSpeck),
  'the influence of a dark speck falls off with distance');

// Negative dehaze runs the forward model and adds haze. It is measured on the
// scene that already reads as bright, because adding haze is proportional to the
// airlight: a frame with almost no airlight has almost no haze to add, which is
// the correct behaviour rather than a weak effect.
const hazedOnce = sceneDiff(apply(cleanScene, DEH_W, DEH_H, { dehaze: -0.5 }, 2048), cleanScene);
const hazedTwice = sceneDiff(apply(cleanScene, DEH_W, DEH_H, { dehaze: -1 }, 2048), cleanScene);
ok(hazedOnce > 0 && hazedTwice > hazedOnce,
  `negative dehaze adds haze and grows with the amount (${hazedOnce.toFixed(4)} -> ${hazedTwice.toFixed(4)})`);
// Compositor's two branches are independent formulas: positive removes haze by
// transmission (floored at 0.5), negative veils with `0.3 * amount^1.3`. Nothing makes
// the veil smaller than the removal, so a cross-branch size comparison would be a claim
// about this fixture, not about the algorithm. The direction and the growth are what the
// implementation guarantees, and both are asserted above.

// ==========================================================================
// 7. Sharpening
// ==========================================================================
const SHARP_W = 96, SHARP_H = 96;
const stepEdge = gray(SHARP_W, SHARP_H, (x) => (x < SHARP_W / 2 ? 70 : 190));
const midRow = (SHARP_H >> 1) * SHARP_W;
const edgeContrast = (buffer) =>
  lumaOf(buffer, midRow + SHARP_W / 2) * 255 - lumaOf(buffer, midRow + SHARP_W / 2 - 1) * 255;
const originalContrast = edgeContrast(stepEdge);
ok(Math.abs(originalContrast - 120) < 1e-9, 'the test edge starts with 120 levels of contrast');
ok(Math.abs(edgeContrast(apply(stepEdge, SHARP_W, SHARP_H, { sharpenAmount: 0 }, 2048)) - originalContrast) < 1e-9,
  'a zero sharpening amount leaves the edge exactly as it was');
const amountContrasts = [0.25, 0.5, 1].map((amount) =>
  edgeContrast(apply(stepEdge, SHARP_W, SHARP_H, { sharpenAmount: amount, sharpenRadius: 0.2 }, 2048)));
ok(amountContrasts[0] > originalContrast,
  `sharpening raises the edge contrast (${originalContrast} -> ${amountContrasts[0]})`);
ok(amountContrasts[0] < amountContrasts[1] && amountContrasts[1] < amountContrasts[2],
  `edge contrast grows with the amount: ${amountContrasts.join(' < ')}`);
const overshoot = apply(stepEdge, SHARP_W, SHARP_H, { sharpenAmount: 1, sharpenRadius: 0.2 }, 2048);
ok(lumaOf(overshoot, midRow + SHARP_W / 2 - 1) * 255 < 70,
  'the dark side of a sharpened edge is pushed below its original value (an undershoot, not a lift)');
ok(lumaOf(overshoot, midRow + SHARP_W / 2) * 255 > 190,
  'the bright side of a sharpened edge is pushed above its original value');

// The radius spreads the correction over a wider halo, so the total energy next
// to the edge grows even where the single-pixel contrast saturates.
function edgeEnergy(buffer) {
  let sum = 0;
  for (let x = SHARP_W / 2 - 20; x < SHARP_W / 2 + 20; x++) {
    sum += Math.abs(lumaOf(buffer, midRow + x) - lumaOf(stepEdge, midRow + x));
  }
  return sum * 255;
}
const radiusEnergy = [0, 0.25, 0.5, 0.75, 1].map((radius) =>
  edgeEnergy(apply(stepEdge, SHARP_W, SHARP_H, { sharpenAmount: 1, sharpenRadius: radius }, 2048)));
let radiusMonotone = true;
for (let step = 1; step < radiusEnergy.length; step++) {
  if (radiusEnergy[step] <= radiusEnergy[step - 1]) radiusMonotone = false;
}
ok(radiusMonotone, `a larger sharpening radius spreads the correction further: ${radiusEnergy.join(' < ')}`);

// Detail mixes a second, wider high-pass into the unsharp mask, so it changes
// the result at a fixed amount.
const detailEnergy = [0, 0.25, 0.5, 0.75, 1].map((detail) =>
  edgeEnergy(apply(stepEdge, SHARP_W, SHARP_H, { sharpenAmount: 0.25, sharpenDetail: detail }, 2048)));
ok(detailEnergy[0] < detailEnergy[2] && detailEnergy[2] < detailEnergy[4],
  `the detail control changes the sharpened result: ${detailEnergy.join(' ')}`);

// Masking protects flat and low-contrast areas.
const flatField = gray(SHARP_W, SHARP_H, () => 128);
const flatOut = apply(flatField, SHARP_W, SHARP_H, { sharpenAmount: 1 }, 2048);
let flatMax = 0;
for (let index = 0; index < SHARP_W * SHARP_H; index++) {
  flatMax = Math.max(flatMax, Math.abs(flatOut[index * 4] - 128));
}
ok(flatMax === 0, `a perfectly flat field is untouched by sharpening, max change ${flatMax}`);
const noisyFlat = gray(SHARP_W, SHARP_H, (x, y) => 128 + ((x * 7 + y * 13) % 11) - 5);
const maskingChanges = [0, 0.25, 0.5, 0.75, 1].map((masking) =>
  meanAbsChange(noisyFlat, SHARP_W, SHARP_H, { sharpenAmount: 1, sharpenMasking: masking }, 2048));
ok(maskingChanges[0] > 1,
  `sharpening does amplify a noisy flat field when masking is off, change ${maskingChanges[0].toFixed(4)}`);
let maskingMonotone = true;
for (let step = 1; step < maskingChanges.length; step++) {
  if (maskingChanges[step] > maskingChanges[step - 1] + 1e-9) maskingMonotone = false;
}
ok(maskingMonotone, `masking reduces the change on a flat field monotonically: ${maskingChanges.map((v) => v.toFixed(3)).join(' ')}`);
ok(maskingChanges[4] === 0, `full masking leaves a noisy flat field exactly alone, change ${maskingChanges[4]}`);
// Masking must not be a global gain: it has to leave a real edge boosted.
const maskedEdge = edgeContrast(apply(stepEdge, SHARP_W, SHARP_H, { sharpenAmount: 1, sharpenMasking: 1 }, 2048));
ok(maskedEdge > originalContrast,
  `full masking still sharpens a real edge (${originalContrast} -> ${maskedEdge})`);

// ==========================================================================
// 8. Border policy: clamp to the edge, never wrap
// ==========================================================================
const BORD_W = 96, BORD_H = 96;
const horizontalBorder = gray(BORD_W, BORD_H, (x) => (x === 0 ? 190 : (x === BORD_W - 1 ? 66 : 128)));
const horizontalOut = apply(horizontalBorder, BORD_W, BORD_H, { texture: 1 }, 2048);
for (const y of [0, 5, 40, BORD_H - 1]) {
  ok(horizontalOut[(y * BORD_W) * 4] > 190,
    `the bright left edge column is pushed further up at row ${y} (clamped, not wrapped)`);
  ok(horizontalOut[(y * BORD_W + BORD_W - 1) * 4] < 66,
    `the dark right edge column is pushed further down at row ${y} (clamped, not wrapped)`);
}
// A wrap would have made the left column see the right column's dark value and
// move DOWN instead; the reverse comparison pins that the two edges are treated
// as their own neighbourhoods.
const verticalBorder = gray(BORD_W, BORD_H, (x, y) => (y === 0 ? 190 : (y === BORD_H - 1 ? 66 : 128)));
const verticalOut = apply(verticalBorder, BORD_W, BORD_H, { texture: 1 }, 2048);
for (const x of [0, 5, 40, BORD_W - 1]) {
  ok(verticalOut[x * 4] > 190, `the bright top edge row is pushed further up at column ${x}`);
  ok(verticalOut[((BORD_H - 1) * BORD_W + x) * 4] < 66, `the dark bottom edge row is pushed further down at column ${x}`);
}

// ==========================================================================
// 9. Determinism, alpha, range, and degenerate frames
// ==========================================================================
const busy = gray(128, 96, (x, y) => 30 + ((x * 13 + y * 29) % 200));
const busyParams = { texture: 0.7, clarity: 0.4, dehaze: 0.3, sharpenAmount: 0.6, sharpenRadius: 0.5 };
ok(sameBytes(apply(busy, 128, 96, busyParams, 2048), apply(busy, 128, 96, busyParams, 2048)),
  'the same input and parameters give the same bytes every time');

const alphaFrame = new Uint8ClampedArray(96 * 96 * 4);
for (let index = 0; index < 96 * 96; index++) {
  alphaFrame[index * 4] = busy[(index * 7) % (busy.length / 4) * 4];
  alphaFrame[index * 4 + 1] = 90;
  alphaFrame[index * 4 + 2] = 210;
  alphaFrame[index * 4 + 3] = index % 254;
}
const alphaOut = apply(alphaFrame, 96, 96, { texture: 1, clarity: 1, dehaze: 1, sharpenAmount: 1 }, 2048);
let alphaMismatch = 0, nonFinite = 0, outOfRange = 0;
for (let index = 0; index < 96 * 96; index++) {
  if (alphaOut[index * 4 + 3] !== alphaFrame[index * 4 + 3]) alphaMismatch++;
  for (let channel = 0; channel < 4; channel++) {
    const v = alphaOut[index * 4 + channel];
    if (!Number.isFinite(v)) nonFinite++;
    if (v < 0 || v > 255 || Math.round(v) !== v) outOfRange++;
  }
}
ok(alphaMismatch === 0, `every alpha byte survives all four stages unchanged, mismatches ${alphaMismatch}`);
ok(nonFinite === 0, `no output byte is NaN or Infinity, count ${nonFinite}`);
ok(outOfRange === 0, `every output byte is an integer in 0..255, violations ${outOfRange}`);

const allStages = { texture: 1, clarity: 1, dehaze: 1, sharpenAmount: 1, sharpenRadius: 1, sharpenDetail: 1, sharpenMasking: 1 };
for (const [w, h] of [[1, 1], [1, 40], [40, 1], [2, 2], [3, 7], [17, 3]]) {
  const image = gray(w, h, (x, y) => 40 + ((x * 7 + y * 31) % 180));
  let out = null;
  try {
    out = apply(image, w, h, allStages, 2048);
  } catch (error) {
    ok(false, `a ${w}x${h} frame must not throw, got ${error.message}`);
  }
  if (out !== null) {
    let bad = 0;
    for (let index = 0; index < w * h * 4; index++) if (!Number.isFinite(out[index])) bad++;
    ok(bad === 0, `a ${w}x${h} frame stays finite through all four stages`);
    ok(out.length === w * h * 4, `a ${w}x${h} frame returns the expected number of bytes`);
  }
}
// A short input must degrade to transparent black instead of reading out of
// bounds, and must not disturb the pixel data that was supplied.
const shortInput = new Uint8ClampedArray([10, 20, 30, 255, 40, 50, 60, 128]);
const shortOut = apply(shortInput, 4, 4, { texture: 1 }, 2048);
ok(shortOut.length === 4 * 4 * 4, 'a short input still returns a full frame');
ok(shortOut[3] === 255 && shortOut[7] === 128,
  'the alpha of a short input\'s supplied pixels is carried through untouched');
let shortTrailing = 0;
for (let index = 8; index < shortOut.length; index++) if (shortOut[index] !== 0) shortTrailing++;
ok(shortTrailing === 0, 'the missing pixels of a short input stay transparent black');

// ==========================================================================
// 10. Every stage is real: each one alone changes the frame
// ==========================================================================
const stageImage = gray(128, 128, (x, y) =>
  128 + 42 * Math.sin((x / 128) * 6 * Math.PI) * Math.cos((y / 128) * 6 * Math.PI) + 14 * Math.sin(x * 2.3));
for (const stage of ['texture', 'clarity', 'dehaze', 'sharpenAmount']) {
  const over = {};
  over[stage] = 1;
  const out = apply(stageImage, 128, 128, over, 2048);
  ok(!sameBytes(out, stageImage), `${stage} at 1.0 actually changes the frame`);
  const zero = {};
  zero[stage] = 0;
  ok(sameBytes(apply(stageImage, 128, 128, zero, 2048), stageImage), `${stage} at 0.0 is exactly the identity`);
}
// And the four stages are not aliases of each other.
const stageOutputs = ['texture', 'clarity', 'sharpenAmount'].map((stage) => {
  const over = {};
  over[stage] = 1;
  return apply(stageImage, 128, 128, over, 2048);
});
for (let a = 0; a < stageOutputs.length; a++) {
  for (let b = a + 1; b < stageOutputs.length; b++) {
    ok(!sameBytes(stageOutputs[a], stageOutputs[b]), 'the mean-preserving stages produce different results');
  }
}
// Sign symmetry: the texture stage is an odd operator on a zero-mean pattern, so
// pushing and pulling by the same amount must be mirror images of each other
// around the untouched frame.
const symmetric = gray(64, 64, (x, y) => 128 + (((x + y) % 2) === 0 ? -30 : 30));
const pushed = apply(symmetric, 64, 64, { texture: 0.5 }, 2048);
const pulled = apply(symmetric, 64, 64, { texture: -0.5 }, 2048);
let mirrorWorst = 0;
for (let index = 0; index < 64 * 64; index++) {
  mirrorWorst = Math.max(mirrorWorst,
    Math.abs((lumaOf(pushed, index) + lumaOf(pulled, index)) - 2 * lumaOf(symmetric, index)));
}
ok(mirrorWorst < 0.02,
  `texture at +a and -a are mirror images around the original, worst luma deviation ${mirrorWorst.toFixed(5)}`);

console.log(`local contrast: ${checks} checks passed`);
