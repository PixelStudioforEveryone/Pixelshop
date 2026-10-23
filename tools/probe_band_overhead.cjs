// 放大瓦片 `cpu-stages layers=… bands=80` 的拆账探针（宿主侧）。
//
// 目的：把「80 个带 × 每带固定开销」的**上界**量出来，而不是靠猜。
//
// 方法：用与 check_export_bands_parity.cjs 相同的 TS→CJS 加载器载入 WorkerCore，
// 但把 `libvivid_composite.so` 换成一个**只计数、不干活**的 mock：
//   - native 返回 true  ⇒ 测到的是纯 ArkTS 侧带宽循环 + N-API 参数打包/调用点
//     （subarray、base 拷贝、视图创建、参数数组、ready 检查、Date.now 计时）；
//   - native 返回 false ⇒ 同一个循环走 ArkTS 参考实现，用于确认参考路径的量级。
// 真实 native 的像素计算不在这里测（宿主 CPU 与手机不可比），但「固定开销」
// 恰恰就是 mock 掉 native 之后剩下的那部分，所以这是它的上界。
//
// 每带的 native 调用次数与打包字节数由 mock 自己按参数长度累计并打印，
// 便于和真机 `stage=layer-passes` 的 adjust/maskAdjust/maskBlend/composite 对齐。
//
// 用法：node tools/probe_band_overhead.cjs [--size 1273x2048] [--bands 32768,131072,1048576]
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const args = process.argv.slice(2);
function arg(name, fallback) {
  const at = args.indexOf('--' + name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
}
const [W, H] = arg('size', '1273x2048').split('x').map(Number);
const BAND_PIXELS = arg('bands', '32768,131072,1048576').split(',').map(Number);

// --- native mock -----------------------------------------------------------
const native = {
  mode: 'noop', // 'noop' | 'reject'
  counters: null,
  reset() {
    this.counters = {
      matrixBand: 0, advancedBand: 0, maskBlend: 0, composite: 0,
      matrixBytes: 0, advancedBytes: 0, maskBlendBytes: 0, compositeBytes: 0,
    };
  },
  matrixBand(input, matrix, output, start, end) {
    if (this.mode === 'reject') return false;
    this.counters.matrixBand++;
    this.counters.matrixBytes += (end - start) + output.length * 4 + matrix.length * 4;
    return true;
  },
  advancedBand(input, start, end, params, curves, tonal, parametric, viewport) {
    if (this.mode === 'reject') return false;
    this.counters.advancedBand++;
    this.counters.advancedBytes += (end - start) + params.length * 8 + curves.length * 8 +
      (tonal ? tonal.length * 4 : 0) + (parametric ? parametric.length * 4 : 0) +
      (viewport ? viewport.length * 8 : 0);
    return true;
  },
  maskBlend(adjusted, maskAdjusted, mask, start, end, pixelOffset) {
    if (this.mode === 'reject') return false;
    this.counters.maskBlend++;
    this.counters.maskBlendBytes += (end - start) * 2 + mask.length;
    return true;
  },
  composite(result, base, adjusted, mask, opacity, blendMode, start, end, pixelOffset) {
    if (this.mode === 'reject') return false;
    this.counters.composite++;
    this.counters.compositeBytes += (end - start) * 3 + (mask ? mask.length : 0);
    return true;
  },
  lutStack() { return this.mode !== 'reject'; },
  pointColor() { return this.mode !== 'reject'; },
  oklch() { return this.mode !== 'reject'; },
  apiVersion() { return 3; },
};
native.reset();

const modules = new Map();
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} };
  modules.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
    Uint8Array, Uint8ClampedArray, Uint32Array, Int32Array, Float32Array, Float64Array,
    Promise, Error, __dirname: path.dirname(file),
    require: (name) => {
      if (name.endsWith('.so')) return { default: native };
      if (name === '@kit.ArkTS') {
        return { taskpool: { Task: class { static isCanceled() { return false; } } } };
      }
      if (name.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const root = path.resolve('entry/src/main/ets');
const W_ = load(root + '/edit/engine/WorkerCore.ets');
const { applyLayerBandFull, buildMatrix, hasAdvancedAdjustments, isIdentity } = W_;

function neutralAdjustments() {
  return {
    exposure: 0, contrast: 0, brightness: 0, highlights: 0, shadows: 0, whites: 0, blacks: 0,
    vignetteAmount: 0, vignetteMidpoint: 0, vignetteRoundness: 0, vignetteFeather: 0,
    vignetteHighlights: 0, grainAmount: 0, grainSize: 0, grainRoughness: 0,
    saturation: 0, vibrance: 0, temperature: 0, tint: 0, hue: 0,
    toneCurve: 0, curveRed: 0, curveGreen: 0, curveBlue: 0,
    toneCurvePoints: [[0, 0], [1, 1]], redCurvePoints: [[0, 0], [1, 1]],
    greenCurvePoints: [[0, 0], [1, 1]], blueCurvePoints: [[0, 0], [1, 1]],
    parametricHighlights: 0, parametricLights: 0, parametricDarks: 0, parametricShadows: 0,
    parametricShadowSplit: 0, parametricDarkSplit: 0, parametricLightSplit: 0,
    parametricRefineSaturation: 0,
    mixHue: new Array(8).fill(0), mixSaturation: new Array(8).fill(0),
    mixLuminance: new Array(8).fill(0),
    calibrationRedHue: 0, calibrationRedSaturation: 0, calibrationGreenHue: 0,
    calibrationGreenSaturation: 0, calibrationBlueHue: 0, calibrationBlueSaturation: 0,
    colorGradingEnabled: false, gradingShadowsHue: 0, gradingShadowsSaturation: 0,
    gradingShadowsLuminance: 0, gradingMidtonesHue: 0, gradingMidtonesSaturation: 0,
    gradingMidtonesLuminance: 0, gradingHighlightsHue: 0, gradingHighlightsSaturation: 0,
    gradingHighlightsLuminance: 0, gradingGlobalHue: 0, gradingGlobalSaturation: 0,
    gradingGlobalLuminance: 0, gradingBlending: 0, gradingBalance: 0,
  };
}

// The tile session in the device log carries real edits; use the common case:
// a colour-matrix layer (contrast/saturation) plus the advanced stage
// (exposure + curves are identity, vignette off) and no mask. With a mask the
// pipeline does two more full-band passes, which is why it is measured too.
function makePipeline(adj, mask) {
  const matrix = buildMatrix(adj);
  return {
    adjustments: adj,
    matrix: isIdentity(matrix) ? null : matrix,
    hasAdvanced: hasAdvancedAdjustments(adj),
    opacity: 1,
    blendMode: 0,
    mask: mask,
    base: null,
    adjusted: null,
    maskAdjustments: neutralAdjustments(),
    maskMatrix: null,
    hasMaskAdjustments: false,
    maskAdjusted: null,
    width: W,
    height: H,
  };
}

function nowMs() { return Number(process.hrtime.bigint() / 1000n) / 1000; }

function runCase(label, adjSpec, withMask, bandPixels, mode) {
  native.mode = mode;
  native.reset();
  const adj = Object.assign(neutralAdjustments(), adjSpec);
  const pixels = new Uint8ClampedArray(W * H * 4);
  // Deterministic non-trivial pixels so the ArkTS reference path does real work.
  let state = 12345;
  for (let i = 0; i < pixels.length; i += 4) {
    state = (state * 1664525 + 1013904223) >>> 0;
    pixels[i] = (state >>> 24) & 255;
    pixels[i + 1] = (state >>> 16) & 255;
    pixels[i + 2] = (state >>> 8) & 255;
    pixels[i + 3] = 255;
  }
  const mask = withMask ? new Uint8ClampedArray(W * H) : null;
  if (mask) for (let i = 0; i < mask.length; i++) mask[i] = (i * 37) & 255;

  const pipeline = makePipeline(adj, mask);
  const bandBytes = Math.min(pixels.length, bandPixels * 4);
  const scratchBase = new Uint8ClampedArray(bandBytes);
  const scratchAdjusted = new Uint8ClampedArray(bandBytes);
  const scratchMaskAdjusted = new Uint8ClampedArray(bandBytes);
  pipeline.base = scratchBase;
  pipeline.adjusted = scratchAdjusted;
  pipeline.maskAdjusted = scratchMaskAdjusted;
  if (mask) {
    // Mask-adjustment branch: an extra matrix + advanced pass over the band.
    const maskAdj = Object.assign(neutralAdjustments(), { contrast: 0.2 });
    const maskMatrix = buildMatrix(maskAdj);
    pipeline.maskAdjustments = maskAdj;
    pipeline.maskMatrix = isIdentity(maskMatrix) ? null : maskMatrix;
    pipeline.hasMaskAdjustments = true;
  }

  const timing = { adjust: 0, maskAdjust: 0, maskBlend: 0, composite: 0 };
  const bands = Math.ceil(pixels.length / bandBytes);
  const started = nowMs();
  for (let start = 0; start < pixels.length; start += bandBytes) {
    const end = Math.min(pixels.length, start + bandBytes);
    const band = pixels.subarray(start, end);
    pipeline.pixelOffset = start / 4;
    pipeline.base.set(band);
    applyLayerBandFull(band, pipeline, 0, band.length, timing);
  }
  const total = nowMs() - started;
  const c = native.counters;
  return {
    label, mode, bands, bandPixels,
    totalMs: +total.toFixed(1),
    perBandMs: +(total / bands).toFixed(3),
    bandsPerMs: +(bands / total).toFixed(2),
    adjust: +timing.adjust.toFixed(1),
    maskAdjust: +timing.maskAdjust.toFixed(1),
    maskBlend: +timing.maskBlend.toFixed(1),
    composite: +timing.composite.toFixed(1),
    calls: c.matrixBand + c.advancedBand + c.maskBlend + c.composite,
    callsPerBand: +((c.matrixBand + c.advancedBand + c.maskBlend + c.composite) / bands).toFixed(2),
    mibPerBand: +(((c.matrixBytes + c.advancedBytes + c.maskBlendBytes + c.compositeBytes) /
      bands / 1048576)).toFixed(2),
    raw: c,
  };
}

console.log(`tile=${W}x${H} (${(W * H / 1e6).toFixed(2)} MP), bandPixels=${BAND_PIXELS.join('/')}`);
const rows = [];
for (const spec of [
  { name: 'matrix-only', adj: { contrast: 0.35, saturation: 0.25, brightness: 0.1 }, mask: false },
  { name: 'advanced', adj: { exposure: 0.35, contrast: 0.35, saturation: 0.25, vibrance: 0.3 }, mask: false },
  { name: 'advanced+mask', adj: { exposure: 0.35, contrast: 0.35, saturation: 0.25, vibrance: 0.3 }, mask: true },
]) {
  for (const bandPixels of BAND_PIXELS) {
    const noop = runCase(spec.name, spec.adj, spec.mask, bandPixels, 'noop');
    rows.push(noop);
    console.log(`${spec.name.padEnd(14)} band=${String(bandPixels).padStart(7)}px ` +
      `bands=${String(noop.bands).padStart(3)} ` +
      `fixedTotal=${String(noop.totalMs).padStart(8)}ms ` +
      `perBand=${String(noop.perBandMs).padStart(6)}ms ` +
      `calls/band=${noop.callsPerBand} bytes/band=${noop.mibPerBand}MiB ` +
      `[adjust=${noop.adjust} maskAdjust=${noop.maskAdjust} ` +
      `maskBlend=${noop.maskBlend} composite=${noop.composite}]`);
  }
}

// ArkTS reference cost (native refuses) at the production band size, for scale.
for (const spec of [
  { name: 'matrix-only', adj: { contrast: 0.35, saturation: 0.25, brightness: 0.1 }, mask: false },
  { name: 'advanced', adj: { exposure: 0.35, contrast: 0.35, saturation: 0.25, vibrance: 0.3 }, mask: false },
]) {
  const r = runCase(spec.name, spec.adj, spec.mask, 32768, 'reject');
  console.log(`${spec.name.padEnd(14)} ArkTS-reference band=32768px total=${r.totalMs}ms ` +
    `perBand=${r.perBandMs}ms`);
  rows.push(r);
}

// Pure per-band plumbing cost, isolated: subarray + base.set + Date.now.
{
  const pixels = new Uint8ClampedArray(W * H * 4);
  const base = new Uint8ClampedArray(32768 * 4);
  const bands = Math.ceil(pixels.length / (32768 * 4));
  const t0 = nowMs();
  for (let start = 0; start < pixels.length; start += 32768 * 4) {
    const end = Math.min(pixels.length, start + 32768 * 4);
    const band = pixels.subarray(start, end);
    base.set(band);
    Date.now();
  }
  const plumbing = nowMs() - t0;
  console.log(`plumbing-only  band=32768px bands=${bands} subarray+base.set+clock=` +
    `${plumbing.toFixed(1)}ms (${(plumbing / bands).toFixed(3)}ms/band)`);
}

// 结论行：把“固定开销上界”与真机 `stage=cpu-stages layers=` 的实测值并列。
// 真机 2.61MP 瓦片的一次日志是 layers=804ms；这里的所有数字都是**不含 native
// 像素计算**的纯 ArkTS/打包/调用开销，所以它们是那 804ms 里非像素部分的上界。
{
  const deviceLayersMs = Number(arg('device-ms', '804'));
  const worst = rows
    .filter((r) => r.mode === 'noop')
    .reduce((max, r) => (r.totalMs > max.totalMs ? r : max), { totalMs: 0, bands: 0 });
  const share = deviceLayersMs > 0 ? (worst.totalMs / deviceLayersMs) * 100 : 0;
  console.log(`\nbound: 80 带 × 固定开销 ≤ ${worst.totalMs.toFixed(1)}ms ` +
    `(${worst.bands} 带, 最坏用例) = 真机 layers=${deviceLayersMs}ms 的 ${share.toFixed(1)}%`);
  console.log(`       其余 ${(deviceLayersMs - worst.totalMs).toFixed(0)}ms 只能来自 ` +
    'native 每像素计算（同一段 .so 与带大小无关），不是带间开销。');
  console.log('       ArkTS 参考实现对同一管线的量级见上面的 *-reference 行：' +
    '若 native 未生效，2.61MP 会是秒级而不是亚秒级。');
}
