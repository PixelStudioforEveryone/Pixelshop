// Independent verification of the clone stamp and the PatchMatch content fill.
// Synthetic pixels only (flat, checkerboard, stripes, ramp, noise). The checks a
// stub cannot fake: a zero mask must be byte-identical, the filled region must
// keep the texture amplitude of its surroundings and not equal a box blur, and
// work must stay bounded.
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

const core = load(root + '/edit/engine/ContentFillCore.ets');
const { cloneStamp, contentAwareFill, contentFillDefaults } = core;

let checks = 0;
const ok = (condition, message) => { assert(condition, message); checks++; };

// --- helpers
/** RGBA frame from a per-pixel function: [r, g, b] or [r, g, b, a]. */
function mk(cols, rows, fn) {
  const buf = new Uint8ClampedArray(cols * rows * 4);
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    const o = (y * cols + x) * 4, c = fn(x, y);
    buf[o] = c[0]; buf[o + 1] = c[1]; buf[o + 2] = c[2]; buf[o + 3] = c.length > 3 ? c[3] : 255;
  }
  return buf;
}
const at = (buf, cols, x, y) => [buf[(y * cols + x) * 4], buf[(y * cols + x) * 4 + 1], buf[(y * cols + x) * 4 + 2], buf[(y * cols + x) * 4 + 3]];
const rgbAt = (buf, cols, x, y) => at(buf, cols, x, y).slice(0, 3);
const same = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
function diffRegion(a, b, cols, x0, y0, w, h) {
  let n = 0;
  for (let y = y0; y < y0 + h; y++) for (let x = x0; x < x0 + w; x++) {
    const o = (y * cols + x) * 4;
    if (a[o] !== b[o] || a[o + 1] !== b[o + 1] || a[o + 2] !== b[o + 2]) n++;
  }
  return n;
}
function regionVar(buf, cols, x0, y0, w, h) {
  let n = 0, sum = 0, sq = 0;
  for (let y = y0; y < y0 + h; y++) for (let x = x0; x < x0 + w; x++) {
    const v = buf[(y * cols + x) * 4 + 1];
    sum += v; sq += v * v; n++;
  }
  return sq / n - (sum / n) * (sum / n);
}
function holeRect(cols, rows, hx, hy, hw, hh) {
  const mask = new Uint8Array(cols * rows);
  for (let y = hy; y < hy + hh; y++) for (let x = hx; x < hx + hw; x++) mask[y * cols + x] = 255;
  return mask;
}
/** Destroy the hole content before filling: otherwise the region still holds
 *  the right pattern and "the fill did nothing" would pass. */
function wreckHole(buf, cols, x0, y0, w, h, v) {
  for (let y = y0; y < y0 + h; y++) for (let x = x0; x < x0 + w; x++) {
    const o = (y * cols + x) * 4;
    buf[o] = v; buf[o + 1] = v; buf[o + 2] = v;
  }
  return buf;
}
function boxBlur3(src, cols, rows) {
  const out = new Uint8ClampedArray(src.length);
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    const o = (y * cols + x) * 4;
    for (let c = 0; c < 3; c++) {
      let sum = 0, n = 0;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const nx = Math.min(cols - 1, Math.max(0, x + dx)), ny = Math.min(rows - 1, Math.max(0, y + dy));
        sum += src[(ny * cols + nx) * 4 + c]; n++;
      }
      out[o + c] = Math.round(sum / n);
    }
    out[o + 3] = src[o + 3];
  }
  return out;
}
const flat = (cols, rows, v) => mk(cols, rows, () => [v, v, v]);
const stripes = (cols, rows) => mk(cols, rows, (x) => { const v = x % 8 < 4 ? 220 : 40; return [v, v, v]; });
const checker = (cols, rows) => mk(cols, rows, (x, y) => { const v = ((x >> 2) + (y >> 2)) % 2 ? 235 : 25; return [v, v, v]; });
const ramp = (cols, rows) => mk(cols, rows, (x) => { const v = Math.round(x * 255 / (cols - 1)); return [v, v, v]; });
function noise(cols, rows, alpha) {
  let s = 987654321;
  const next = () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff; };
  return mk(cols, rows, () => {
    const v = Math.round(next() * 255);
    return alpha ? [v, v, v, Math.round(next() * 255)] : [v, v, v];
  });
}
const mark = (over) => Object.assign({
  centreX: 0.5, centreY: 0.5, radius: 0.2, feather: 0, opacity: 1,
  sourceX: 0.5, sourceY: 0.5, aligned: false,
}, over);

// --- 1. clone stamp places the source where the mark says
{
  const cols = 32, rows = 32;
  const base = flat(cols, rows, 60);
  for (let y = 4; y < 12; y++) for (let x = 20; x < 28; x++) {
    const o = (y * cols + x) * 4;
    base[o] = 255; base[o + 1] = 0; base[o + 2] = 0;
  }
  const before = base.slice();
  const out = cloneStamp(base, cols, rows, [mark({
    centreX: 10 / 31, centreY: 10 / 31, radius: 6 / 32, sourceX: 24 / 31, sourceY: 8 / 31,
  })]);
  ok(rgbAt(out, cols, 10, 10).join() === '255,0,0' && rgbAt(out, cols, 12, 12).join() === '255,0,0',
    'the stamped destination takes the source pattern');
  ok(rgbAt(out, cols, 2, 2).join() === '60,60,60' && rgbAt(out, cols, 30, 30).join() === '60,60,60',
    'nothing outside the mark radius moves');
  ok(same(before, base) && out.length === base.length,
    'clone stamp does not mutate its input and keeps the frame size');
}
// --- 2. opacity 0 is a no-op
{
  const cols = 24, rows = 24;
  const base = stripes(cols, rows);
  ok(same(cloneStamp(base, cols, rows, [mark({ opacity: 0, radius: 0.5, sourceX: 0.1, sourceY: 0.1 })]), base),
    'opacity 0 leaves the frame byte-identical');
}

// --- 3. the feathered edge is a ramp, not a step
{
  // The source offset is -32, so every sample along y = 64 out from the centre
  // lands in the white quadrant x < 64 / y < 64: green reads the falloff.
  const cols = 128, rows = 128;
  const base = flat(cols, rows, 0);
  for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) {
    const o = (y * cols + x) * 4;
    base[o] = 255; base[o + 1] = 255; base[o + 2] = 255;
  }
  const soft = cloneStamp(base, cols, rows, [mark({
    centreX: 64 / 127, centreY: 64 / 127, radius: 24 / 128, feather: 0.5, sourceX: 32 / 127, sourceY: 32 / 127,
  })]);
  const hard = cloneStamp(base, cols, rows, [mark({
    centreX: 64 / 127, centreY: 64 / 127, radius: 24 / 128, feather: 0, sourceX: 32 / 127, sourceY: 32 / 127,
  })]);
  const line = [];
  for (let x = 64; x <= 88; x++) line.push(at(soft, cols, x, 64)[1]);
  const softMiddle = line.filter((v) => v > 5 && v < 250).length;
  const hardMiddle = [70, 74, 78, 82].filter((x) => { const v = at(hard, cols, x, 64)[1]; return v > 5 && v < 250; }).length;
  ok(line.every((v, i) => i === 0 || v <= line[i - 1]), `the feathered falloff never rises outward (${line.join(',')})`);
  ok(softMiddle >= 6 && hardMiddle === 0,
    `feather ramps over ${softMiddle} pixels where a hard edge steps in ${hardMiddle}`);
  ok(at(hard, cols, 64, 64)[1] === 255 && at(soft, cols, 64, 64)[1] === 255,
    'both marks still reach full strength at the centre');
}

// --- 4. marks combine in array order
{
  const cols = 16, rows = 16;
  const base = flat(cols, rows, 0);
  for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) {
    const o = (y * cols + x) * 4;
    base[o] = 255; base[o + 1] = 255; base[o + 2] = 255;
  }
  for (let y = 8; y < 16; y++) for (let x = 8; x < 16; x++) {
    const o = (y * cols + x) * 4;
    base[o] = 0; base[o + 1] = 0; base[o + 2] = 255;
  }
  const geo = { centreX: 8 / 15, centreY: 8 / 15, radius: 5 / 16 };
  const white = mark(Object.assign({}, geo, { sourceX: 3 / 15, sourceY: 3 / 15 }));
  const blue = mark(Object.assign({}, geo, { sourceX: 12 / 15, sourceY: 12 / 15 }));
  const forward = cloneStamp(base, cols, rows, [white, blue]);
  const reverse = cloneStamp(base, cols, rows, [blue, white]);
  ok(rgbAt(forward, cols, 8, 8).join() === '0,0,255' && rgbAt(reverse, cols, 8, 8).join() === '255,255,255',
    'the later mark in the array wins, so marks are applied in order');
}

// --- 5. out-of-range coordinates clamp instead of wrapping
{
  const cols = 32, rows = 32;
  const base = flat(cols, rows, 0);
  const put = (x, y, c) => { const o = (y * cols + x) * 4; base[o] = c[0]; base[o + 1] = c[1]; base[o + 2] = c[2]; };
  put(31, 31, [7, 200, 33]);
  put(0, 0, [200, 7, 99]);
  // Centre on the origin with a source normalised past 1.0: every sample is the
  // last pixel. A wrap would land on (13, 13) instead.
  const high = cloneStamp(base, cols, rows, [mark({
    centreX: 0, centreY: 0, radius: 20 / 32, sourceX: 1.2, sourceY: 1.2,
  })]);
  ok(high.length === base.length && rgbAt(high, cols, 14, 14).join() === '7,200,33',
    'a source past the frame edge clamps to the last pixel instead of wrapping');
  ok(rgbAt(high, cols, 20, 20).join() === '0,0,0',
    'pixels beyond the clamped radius are left alone');
  // Centre on the far corner with a source normalised below 0.0.
  const low = cloneStamp(base, cols, rows, [mark({
    centreX: 1, centreY: 1, radius: 20 / 32, sourceX: -0.4, sourceY: -0.4,
  })]);
  ok(rgbAt(low, cols, 18, 18).join() === '200,7,99',
    'a source before the frame origin clamps to the first pixel instead of wrapping');
  ok(rgbAt(low, cols, 11, 11).join() === '0,0,0',
    'the low clamp does not smear past its radius either');
}

// --- 6. an empty mask changes nothing
{
  const cols = 48, rows = 48;
  const base = stripes(cols, rows);
  const empty = new Uint8Array(cols * rows);
  const p = contentFillDefaults();
  ok(same(contentAwareFill(base, cols, rows, empty, p), base),
    'a zero mask leaves the frame byte-identical');
}

// --- 7. outside the hole, bytes and alpha are untouched
{
  const cols = 64, rows = 64;
  const base = noise(cols, rows, true);
  const mask = holeRect(cols, rows, 24, 24, 16, 16);
  const out = contentAwareFill(base, cols, rows, mask, contentFillDefaults());
  let outsideClean = true, alphaClean = true;
  for (let i = 0; i < cols * rows; i++) {
    const o = i * 4;
    if (base[o + 3] !== out[o + 3]) alphaClean = false;
    if (mask[i] === 0 && (base[o] !== out[o] || base[o + 1] !== out[o + 1] || base[o + 2] !== out[o + 2])) outsideClean = false;
  }
  ok(outsideClean, 'no pixel outside the hole is modified');
  ok(alphaClean, 'alpha is preserved everywhere, inside the hole included');
}

// --- 8. a flat field fills flat, not with clamped NaN
{
  const cols = 48, rows = 48;
  const base = flat(cols, rows, 128);
  const mask = holeRect(cols, rows, 16, 16, 16, 16);
  wreckHole(base, cols, 16, 16, 16, 16, 0);
  const out = contentAwareFill(base, cols, rows, mask, contentFillDefaults());
  let worst = 0, nonFinite = 0;
  for (let i = 0; i < cols * rows; i++) {
    const o = i * 4;
    if (mask[i] !== 0) {
      worst = Math.max(worst, Math.abs(out[o + 1] - 128));
      if (!Number.isFinite(out[o + 1])) nonFinite++;
    }
  }
  ok(worst === 0 && nonFinite === 0, `a flat field fills flat (worst deviation ${worst}, non-finite ${nonFinite})`);
}

// --- 9. anti-blur: texture amplitude survives, and this is not a blur
{
  const cols = 128, rows = 128;
  const base = stripes(cols, rows);
  const mask = holeRect(cols, rows, 52, 52, 24, 24);
  wreckHole(base, cols, 52, 52, 24, 24, 128);
  const out = contentAwareFill(base, cols, rows, mask, contentFillDefaults());
  const inHole = regionVar(out, cols, 52, 52, 24, 24);
  const around = (regionVar(out, cols, 12, 52, 24, 24) + regionVar(out, cols, 92, 52, 24, 24) +
    regionVar(out, cols, 52, 12, 24, 24) + regionVar(out, cols, 52, 92, 24, 24)) / 4;
  const ratio = inHole / around;
  const blurred = boxBlur3(base, cols, rows);
  const differs = diffRegion(out, blurred, cols, 52, 52, 24, 24);
  const changed = diffRegion(out, base, cols, 52, 52, 24, 24);
  ok(inHole > 1000 && ratio > 0.5,
    `filled variance ${inHole.toFixed(0)} keeps up with the surrounding ${around.toFixed(0)} (ratio ${ratio.toFixed(2)}, constant fill would be 0)`);
  ok(differs > 0.5 * 24 * 24,
    `the fill is not a box blur (${differs} of ${24 * 24} hole pixels differ from the blurred input)`);
  ok(changed > 0.9 * 24 * 24, `the flat wrecked hole is repainted with texture (${changed} pixels)`);
}

// --- 10. noise input: the fill synthesises detail, it does not average
{
  const cols = 96, rows = 96;
  const base = noise(cols, rows, false);
  const mask = holeRect(cols, rows, 36, 36, 24, 24);
  wreckHole(base, cols, 36, 36, 24, 24, 0);
  const out = contentAwareFill(base, cols, rows, mask, contentFillDefaults());
  const inHole = regionVar(out, cols, 36, 36, 24, 24);
  const around = regionVar(out, cols, 8, 36, 24, 24);
  ok(inHole / around > 0.3,
    `noise variance ratio ${(inHole / around).toFixed(2)} (a constant fill would be 0)`);
  // A synthesised byte may coincide with the wrecked one: a share, not a count.
  ok(diffRegion(out, base, cols, 36, 36, 24, 24) >= 0.95 * 24 * 24,
    'a noisy frame is synthesised back over the hole');
}

// --- 11. a smooth ramp is continued, not banded
{
  const cols = 96, rows = 32;
  const base = ramp(cols, rows);
  const mask = holeRect(cols, rows, 40, 8, 16, 16);
  wreckHole(base, cols, 40, 8, 16, 16, 0);
  const out = contentAwareFill(base, cols, rows, mask, contentFillDefaults());
  let worst = 0, sum = 0, steps = 0, n = 0;
  for (let y = 8; y < 24; y++) for (let x = 40; x < 56; x++) {
    const want = Math.round(x * 255 / (cols - 1));
    const got = at(out, cols, x, y)[1];
    worst = Math.max(worst, Math.abs(got - want));
    sum += Math.abs(got - want); n++;
    if (x > 40) steps = Math.max(steps, Math.abs(got - at(out, cols, x - 1, y)[1]));
  }
  ok(worst <= 8 && sum / n <= 3,
    `the ramp is continued within ${worst} levels (mean error ${(sum / n).toFixed(2)})`);
  ok(steps <= 6, `no banding: the largest step across the fill is ${steps} levels`);
  let monotone = true;
  for (let y = 8; y < 24; y++) for (let x = 41; x < 56; x++) {
    if (at(out, cols, x, y)[1] < at(out, cols, x - 1, y)[1]) monotone = false;
  }
  ok(monotone, 'the filled ramp never decreases across the hole');
}

// --- 12. determinism
{
  const cols = 80, rows = 80;
  const base = checker(cols, rows);
  const mask = holeRect(cols, rows, 28, 28, 20, 20);
  const p = contentFillDefaults();
  const a = contentAwareFill(base, cols, rows, mask, p);
  const b = contentAwareFill(base, cols, rows, mask, contentFillDefaults());
  const c = contentAwareFill(base, cols, rows, mask, Object.assign(contentFillDefaults(), { seed: p.seed + 7 }));
  ok(same(a, b), 'the same seed gives byte-identical output');
  ok(!same(a, c), 'a different seed changes the output');
}

// --- 13. patchRadius and iterations are clamped to the documented bounds -
{
  const cols = 96, rows = 96;
  const base = stripes(cols, rows);
  const mask = holeRect(cols, rows, 40, 40, 16, 16);
  const wild = contentAwareFill(base, cols, rows, mask, { patchRadius: 99, iterations: 999, searchRadius: 3, seed: 5 });
  const bounded = contentAwareFill(base, cols, rows, mask, { patchRadius: 5, iterations: 10, searchRadius: 1, seed: 5 });
  ok(same(wild, bounded), 'out-of-range settings collapse onto the clamped bounds');
}

// --- 14. bounded work on a large hole
{
  const cols = 256, rows = 256;
  const base = stripes(cols, rows);
  const mask = holeRect(cols, rows, 96, 96, 64, 64);
  wreckHole(base, cols, 96, 96, 64, 64, 128);
  const started = Date.now();
  const out = contentAwareFill(base, cols, rows, mask, contentFillDefaults());
  const ms = Date.now() - started;
  ok(ms < 5000 && diffRegion(out, base, cols, 96, 96, 64, 64) > 0.9 * 64 * 64,
    `a ${64}x${64} hole in ${cols}x${rows} fills in ${ms} ms`);
  console.log(`  largest case: 64x64 hole in 256x256, ${ms} ms`);
}

console.log(`content fill: ${checks} checks passed`);
