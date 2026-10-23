// F5 — a zoom tile must correct optics around the WHOLE FRAME's optical centre
// AND read enough neighbouring pixels for the resampling to be exact.
//
// Two defects, one stage:
//   1. OpticsCore derived the distortion/CA centre and the vignette radius from
//      the buffer it was handed, so a tile's optical centre was the tile centre.
//      `renderViewport` is now forwarded into OpticsParams.frame.
//   2. Distortion and lateral CA MOVE samples: at radius r the distortion
//      displacement is |a|*(0.35r^3 - 0.12r^5) normalized units, CA adds
//      |a|*0.006*r^2. A tile that reads only its own rectangle clamps those
//      samples at its border, so its outermost ring disagrees with the
//      whole-frame render by tens of levels even when the centre is right.
//      ImageProcessor.opticsHaloPad now sizes a halo from the tile's own maximum
//      radius and EditorPage adds it to readBounds.
//
// This suite reproduces the audit probe exactly: 96x72 frame, 32x24 tile at
// (10,8), distortion 0.8. It renders the tile the way EditorPage does — read the
// padded source, render the padded region, crop back — and compares the WHOLE
// tile, boundary included, against whole-frame-then-crop. The unpadded render is
// kept as an explicit anti-vacuous control: it must still fail at the boundary,
// otherwise the halo is not what makes the comparison pass.
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
    ArrayBuffer, Uint8Array, Uint8ClampedArray, Uint32Array, Float32Array, Promise, Error, Buffer,
    setTimeout, clearTimeout, setInterval, clearInterval, Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (name) => {
      if (name === 'libvivid_gpu.so') return { default: {}, GpuOutputGeometry: {} };
      if (name === '@kit.ArkTS') return { taskpool: { Task: class { static isCanceled() { return false; } constructor(f, ...a) { this.f = f; this.a = a; } }, execute: async (t) => t.f(...t.a) } };
      if (name === 'libvivid_pixels.so') return { default: { rasterizeLinear: (w, h) => new ArrayBuffer(w * h), rasterizeRadial: (w, h) => new ArrayBuffer(w * h), remapGeometry: (b, w, h) => new ArrayBuffer(w * h * 4), composeInto() {}, invertOpacity() {}, sampleBitmap() {} } };
      if (name.startsWith('@kit.')) return { hilog: { info() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { applyOptics, opticsDefaults, opticsNeighborhoodRadius, opticsMaxRadius } = load(root + '/edit/engine/OpticsCore.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');

const W = 96, H = 72, X0 = 10, Y0 = 8, RW = 32, RH = 24; // the audit probe's geometry
const settings = Object.assign(opticsDefaults(), { distortion: 0.8, chromaticAberration: 0.8 });

function frameFixture() {
  const pixels = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const p = (y * W + x) * 4;
      // Non-separable, high-frequency enough that bilinear taps are visible.
      pixels[p] = x % 4 < 2 ? 50 : 200;
      pixels[p + 1] = y % 4 < 2 ? 40 : 180;
      pixels[p + 2] = 80 + ((x + y) % 12) * 10;
      pixels[p + 3] = 255;
    }
  }
  return pixels;
}
function cropRect(pixels, sx, sy, w, h) {
  const out = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    const from = ((sy + y) * W + sx) * 4;
    out.set(pixels.subarray(from, from + w * 4), y * w * 4);
  }
  return out;
}
function cropOutput(pixels, w, sx, sy, cw, ch) {
  const out = new Uint8ClampedArray(cw * ch * 4);
  for (let y = 0; y < ch; y++) {
    const from = ((sy + y) * w + sx) * 4;
    out.set(pixels.subarray(from, from + cw * 4), y * cw * 4);
  }
  return out;
}
function maxDiff(a, b) {
  let max = 0, over = 0;
  for (let i = 0; i < a.length; i++) {
    if (i % 4 === 3) continue;
    const d = Math.abs(a[i] - b[i]);
    if (d > max) max = d;
    if (d > 1) over++;
  }
  return { max: max, over: over };
}

function session(amounts) {
  const result = new EditSession();
  result.ensureBaseLayer();
  result.optics.distortion = amounts.distortion;
  result.optics.chromaticAberration = amounts.chromaticAberration;
  result.optics.vignetteAmount = amounts.vignetteAmount || 0;
  return result;
}
function wholeFrameOutput(editSession) {
  const params = ImageProcessor.buildWorkerParams(ImageProcessor.snapshot(editSession),
    new Uint8ClampedArray(W * H * 4).buffer, W, H);
  params.source = frameFixture().buffer;
  return new Uint8ClampedArray(processPixels(params).buffer);
}
function renderTile(source, editSession, left, top, w, h) {
  const region = ImageProcessor.regionSnapshot(editSession, left, top, w, h, W, H, w, h);
  const params = ImageProcessor.buildWorkerParams(region, source.buffer, w, h);
  return new Uint8ClampedArray(processPixels(params).buffer);
}

const frame = frameFixture();
const whole = wholeFrameOutput(session(settings));
const expected = cropRect(whole, X0, Y0, RW, RH);

// ---- 1. the delivered halo covers the probe's worst case -------------------
const pad = ImageProcessor.opticsHaloPad(session(settings).optics, X0, Y0, X0 + RW, Y0 + RH, W, H);
assert(pad > 0, 'distortion/CA at 0.8 near the left edge must need a halo, got ' + pad);
const pX = Math.max(0, X0 - pad), pY = Math.max(0, Y0 - pad);
const pRight = Math.min(W, X0 + RW + pad), pBottom = Math.min(H, Y0 + RH + pad);
const pW = pRight - pX, pH = pBottom - pY;
const paddedSource = cropRect(frame, pX, pY, pW, pH);
const padded = renderTile(paddedSource, session(settings), pX, pY, pW, pH);
const actual = cropOutput(padded, pW, X0 - pX, Y0 - pY, RW, RH);
const withHalo = maxDiff(actual, expected);
assert(withHalo.max <= 1, 'WITH the halo the WHOLE tile (boundary included) must match ' +
  'whole-frame-then-crop: max ' + withHalo.max + ', ' + withHalo.over + ' channels over 1');

// ---- 2. anti-vacuous controls ---------------------------------------------
// Same padded read, but the tile is told it is its own frame (the old behaviour):
// the optical centre moves to the tile and the result must differ everywhere.
const naiveParams = ImageProcessor.buildWorkerParams(ImageProcessor.snapshot(session(settings)),
  paddedSource.buffer, pW, pH);
const naiveAll = new Uint8ClampedArray(processPixels(naiveParams).buffer);
const naive = cropOutput(naiveAll, pW, X0 - pX, Y0 - pY, RW, RH);
const withoutFrame = maxDiff(naive, expected);
assert(withoutFrame.max > 1, 'without the whole-frame reference the tile must differ: ' + withoutFrame.max);

// Without the halo (what the code did before), the same reference still fails at
// the boundary — this is the defect the halo exists to remove.
const unpaddedSource = cropRect(frame, X0, Y0, RW, RH);
const unpadded = renderTile(unpaddedSource, session(settings), X0, Y0, RW, RH);
const withoutHalo = maxDiff(unpadded, expected);
assert(withoutHalo.max > 1, 'WITHOUT the halo the boundary must still disagree: ' + withoutHalo.max);
assert(withHalo.max < withoutHalo.max, 'the halo must be what removes the boundary error');

// The halo is tile-relative: a near-centre tile needs much less read than an
// edge tile. A whole-frame worst case would inflate every tile.
const centreX = Math.floor((W - RW) / 2), centreY = Math.floor((H - RH) / 2);
const centrePad = ImageProcessor.opticsHaloPad(session(settings).optics,
  centreX, centreY, centreX + RW, centreY + RH, W, H);
assert(centrePad > 0 && centrePad < pad, 'the halo must follow the tile radius (centre ' +
  centrePad + ' < edge ' + pad + ')');

// ---- 3. zero movement costs zero halo -------------------------------------
const still = session({ distortion: 0, chromaticAberration: 0, vignetteAmount: 0.8 });
assert.strictEqual(ImageProcessor.opticsHaloPad(still.optics, 0, 0, W, H, W, H), 0,
  'vignette is a pure gain and must not request a halo');
assert.strictEqual(ImageProcessor.opticsHaloPad(session({ distortion: 0, chromaticAberration: 0 }).optics,
  X0, Y0, X0 + RW, Y0 + RH, W, H), 0, 'both sliders at zero must request no halo');
const framedDefaults = Object.assign(opticsDefaults(), { frame: [0, 0, 1, 1, W, H] });
assert.strictEqual(opticsNeighborhoodRadius(framedDefaults, W, H, 1), 0,
  'opticsNeighborhoodRadius must be 0 at zero amounts');
const reference = Object.assign(opticsDefaults(), { frame: [0, 0, 1, 1, W, H], distortion: 0.8 });
const atCorner = opticsNeighborhoodRadius(reference, W, H, 1);
const atCentre = opticsNeighborhoodRadius(reference, W, H, 0);
assert(atCorner > atCentre && atCentre === 0, 'the bound must grow with radius and be 0 at the centre');
assert.strictEqual(opticsNeighborhoodRadius(Object.assign({}, reference, { frame: undefined }), W, H, 1), 0,
  'no frame reference means buffer-is-frame: no halo, old behaviour');
assert.strictEqual(opticsMaxRadius(0, 0, W, H, W, H), 1, 'frame corners are radius 1');

// ---- 4. whole-frame rendering is unchanged by the frame machinery ---------
const wholeExplicit = applyOptics(frame, W, H, Object.assign({}, settings, { frame: [0, 0, 1, 1, W, H] }));
const wholeImplicit = applyOptics(frame, W, H, settings);
assert.strictEqual(Buffer.compare(Buffer.from(wholeExplicit), Buffer.from(wholeImplicit)), 0,
  'an explicit full-frame reference must be byte-identical to the implicit one');
const malformed = applyOptics(cropRect(frame, X0, Y0, RW, RH), RW, RH,
  Object.assign({}, settings, { frame: [0, 0] }));
const bufferOnly = applyOptics(cropRect(frame, X0, Y0, RW, RH), RW, RH, settings);
assert.strictEqual(Buffer.compare(Buffer.from(malformed), Buffer.from(bufferOnly)), 0,
  'a malformed reference must fall back to buffer-is-frame');

// ---- 5. production wiring -------------------------------------------------
const panel = fs.readFileSync('entry/src/main/ets/pages/EditorPage.ets', 'utf8');
const haloCall = panel.indexOf('ImageProcessor.opticsHaloPad(this.editSession.optics');
assert(haloCall > 0, 'EditorPage must compute the optics halo');
const readBounds = panel.indexOf('const readBounds = retouchReadBounds(');
assert(readBounds > haloCall, 'the optics halo must be computed before readBounds');
const padLine = panel.indexOf('pad = Math.max(pad, opticsHalo)', haloCall);
assert(padLine > haloCall && padLine < readBounds, 'and must feed the read-bounds pad');

const viewportSession = session(settings);
const tile = ImageProcessor.regionSnapshot(viewportSession, X0, Y0, RW, RH, W, H, RW, RH);
const params = ImageProcessor.buildWorkerParams(tile, new ArrayBuffer(RW * RH * 4), RW, RH);
assert.strictEqual(JSON.stringify(Array.from(params.optics.frame)), JSON.stringify([X0, Y0, 1, 1, W, H]),
  'the optics stage must receive the whole-frame reference from renderViewport');
const wholeParams = ImageProcessor.buildWorkerParams(
  ImageProcessor.snapshot(viewportSession), new ArrayBuffer(W * H * 4), W, H);
assert.strictEqual(wholeParams.optics.frame, undefined, 'a whole-frame render must not carry a reference');

console.log('PASS optics region parity: 96x72 frame, 32x24 tile at (10,8), distortion 0.8 + CA 0.8.');
console.log('     opticsHaloPad=' + pad + ' px; WHOLE tile vs whole-frame-then-crop: max ' + withHalo.max +
  ' levels (' + withHalo.over + ' channels >1).');
console.log('     Controls: without the frame reference ' + withoutFrame.max +
  '; without the halo (old code) ' + withoutHalo.max +
  '; near-centre tile pad ' + centrePad + ' < edge pad ' + pad + '.');
console.log('     Vignette-only and zero sliders request 0 halo; the explicit full-frame reference is');
console.log('     byte-identical; EditorPage applies opticsHaloPad to readBounds.');
