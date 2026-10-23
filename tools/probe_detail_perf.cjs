// Detail-stage probe: wall-clock cost and output parity of LocalContrastCore.
//
// Loads a baseline copy of the module and the live module side by side (the file
// is pure, with no imports), so "before" and "after" are measured on the same
// process, the same fixture in memory and the same JIT state. Reports the median
// of N runs in microseconds and the per-channel / per-luma difference between the
// two outputs, plus the number of 8-bit samples that moved by more than 1 and 2.
//
// Usage:
//   node tools/probe_detail_perf.cjs [--before <file.ets>] [--runs 5]
//                                   [--sizes 512,2048] [--json out.json]
const fs = require('fs'), path = require('path'), vm = require('vm');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

// The module is pure and import-free, so it can be transpiled to a temp .cjs and
// require()d. That matters for measurement: loading it through vm.runInNewContext
// makes every `Math.round` a sandbox global lookup, which inflated the per-pixel
// combine loops by ~6x and would have hidden the real effect of this change.
//
// `--vm` selects that vm loader instead. It is not a faster or slower machine: it
// is a useful model of an interpreter-only runtime (the sandbox keeps the module
// from being optimized the way a normal require() is), which is what a debug
// ArkTS build is.
const GEN = path.join('tmp', 'detail-perf', 'gen');
const useVm = process.argv.includes('--vm');
function loadModule(file, tag) {
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  if (useVm) {
    const mod = { exports: {} };
    vm.runInNewContext(js, {
      module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
      Uint8Array, Uint16Array, Uint32Array, Uint8ClampedArray, Float32Array, DataView, Promise, Error,
    }, { filename: file });
    return mod.exports;
  }
  fs.mkdirSync(GEN, { recursive: true });
  const out = path.resolve(GEN, tag + '.cjs');
  fs.writeFileSync(out, js);
  delete require.cache[out];
  return require(out);
}

const args = process.argv.slice(2);
function arg(name, fallback) {
  const at = args.indexOf('--' + name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
}
const beforePath = arg('before', 'tmp/detail-perf/LocalContrastCore.before.ets');
const afterPath = arg('after', 'entry/src/main/ets/edit/engine/LocalContrastCore.ets');
const runs = Number(arg('runs', '5'));
const sizes = arg('sizes', '512,2048').split(',').map(Number);
const jsonPath = arg('json', '');

const after = loadModule(afterPath, 'after');
const before = loadModule(beforePath, 'before');

const WIDTH = { 512: 512, 2048: 2048 };
const HEIGHT = { 512: 341, 2048: 1365 };

function params(p, over) {
  return Object.assign(p.localContrastDefaults(), over);
}

const CASES = [
  { name: 'clarity-0.5', detail: { clarity: 0.5 } },
  { name: 'texture-0.5', detail: { texture: 0.5 } },
  { name: 'texture+clarity', detail: { texture: 0.5, clarity: 0.5 } },
  { name: 'clarity-1.0', detail: { clarity: 1 } },
  { name: 'dehaze-0.5', detail: { dehaze: 0.5 } },
  { name: 'sharpen', detail: { sharpenAmount: 0.5, sharpenRadius: 0.5, sharpenDetail: 0.25 } },
  { name: 'all-detail', detail: { texture: 0.4, clarity: 0.5, dehaze: 0.4, sharpenAmount: 0.4, sharpenRadius: 0.4 } },
];

function timeOne(api, image, w, h, detail) {
  const p = params(api, detail);
  const longEdge = Math.max(w, h);
  // Warm up once, then measure; the buffers are re-created each run so allocation
  // cost stays inside the measurement, as it is on the device.
  api.applyLocalContrast(image.slice(), w, h, p, longEdge);
  const samples = [];
  let out = null;
  for (let run = 0; run < runs; run++) {
    const input = image.slice();
    const start = process.hrtime.bigint();
    out = api.applyLocalContrast(input, w, h, p, longEdge);
    const end = process.hrtime.bigint();
    samples.push(Number(end - start) / 1000);
  }
  samples.sort((a, b) => a - b);
  return { median: samples[Math.floor(samples.length / 2)], min: samples[0], max: samples[samples.length - 1], out };
}

function compare(a, b) {
  let maxChannel = 0, maxLuma = 0, sumLuma = 0, over1 = 0, over2 = 0, count = 0;
  const luma = (buf, i) => (0.2126 * buf[i * 4] + 0.7152 * buf[i * 4 + 1] + 0.0722 * buf[i * 4 + 2]) / 255 * 255;
  for (let i = 0; i < a.length; i += 4) {
    const dl = Math.abs(luma(a, i / 4) - luma(b, i / 4));
    if (dl > maxLuma) maxLuma = dl;
    sumLuma += dl;
    if (dl > 1) over1++;
    if (dl > 2) over2++;
    for (let c = 0; c < 4; c++) {
      const d = Math.abs(a[i + c] - b[i + c]);
      if (d > maxChannel) maxChannel = d;
    }
    count++;
  }
  return {
    maxChannel, maxLuma, meanLuma: sumLuma / count,
    lumaOver1: over1, lumaOver2: over2, pixels: count,
  };
}

const rows = [];
for (const size of sizes) {
  const w = WIDTH[size], h = HEIGHT[size];
  for (const kind of ['photo', 'synth']) {
    const file = path.join('tmp/detail-perf', `${kind}-${w}x${h}.rgba`);
    const image = new Uint8ClampedArray(fs.readFileSync(file));
    for (const c of CASES) {
      const b = timeOne(before, image, w, h, c.detail);
      const a = timeOne(after, image, w, h, c.detail);
      const diff = compare(b.out, a.out);
      rows.push({ size, kind, case: c.name, beforeUs: Math.round(b.median), afterUs: Math.round(a.median),
        speedup: +(b.median / a.median).toFixed(2), ...diff });
      console.log(`${String(size).padStart(4)} ${kind.padEnd(5)} ${c.name.padEnd(16)}` +
        ` before=${(b.median / 1000).toFixed(1)}ms after=${(a.median / 1000).toFixed(1)}ms` +
        ` x${(b.median / a.median).toFixed(2)}  maxCh=${diff.maxChannel} maxLuma=${diff.maxLuma.toFixed(2)}` +
        ` over2=${diff.lumaOver2}/${diff.pixels} (${(100 * diff.lumaOver2 / diff.pixels).toFixed(3)}%)`);
    }
  }
}
if (jsonPath) fs.writeFileSync(jsonPath, JSON.stringify(rows, null, 2));
