// 图层混合 native 与 ArkTS 的逐字节对拍 + 性能对比。
//
// 背景：`WorkerCore.applyLayerBandFull` 每个可见图层每个带要走三趟解释执行
// （颜色矩阵、蒙版 alpha 混合、混合模式合成），真机 512x341 预览在这上面花了约
// 400ms。整条逐像素算术搬进 native（entry/src/main/cpp/vivid_composite_core.cpp），
// 高级调色（applyAdvancedBand，曲线/HSL/分级）仍留在 ArkTS，所以四趟的顺序不变：
//
//   矩阵 ->（高级，ArkTS）-> 蒙版矩阵 ->（蒙版高级，ArkTS）-> 蒙版混合 -> 合成
//
// 本套件编译**同一份** C++ 源（同一组 -O2/-ffp-contract=off）成宿主探针，喂同一份
// fixture，把 native 的三段输出与转译后的 ArkTS `applyLayerBandFull` 逐字节比较。
// 断言 maxCh === 0。
//
// 证伪：探针支持 --falsify=1，把绿通道整体 +1；套件必须报告 maxCh>0 且差异全部落在
// 绿通道上。也就是说"native 结果写错一个通道"确实会让本套件失败。
//
// 另有一条装配检查：用"只记录参数、返回 false"的假 .so 加载 WorkerCore，断言 wrapper
// 传给 native 的实参（区间、pixelOffset、不透明度、混合模式、蒙版）与 ArkTS 循环所需
// 完全一致——参数传错时这里会红，而不是等画面花了才发现。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const os = require('os');
const cp = require('child_process');
const assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const root = path.resolve('entry/src/main/ets');
const cppDir = path.resolve('entry/src/main/cpp');
const DISTRO = process.env.VIVID_WSL_DISTRO || 'Ubuntu-22.04';
const probeDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vivid-composite-parity-'));
const probeBinary = '/tmp/vivid_composite_probe_' + process.pid;

function makeLoader(nativeModule) {
  const modules = new Map();
  function load(file) {
    file = path.resolve(file);
    if (modules.has(file)) return modules.get(file).exports;
    const mod = { exports: {} }; modules.set(file, mod);
    const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    }).outputText;
    vm.runInNewContext(js, {
      module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
      Uint8Array, Uint8ClampedArray, Uint32Array, Int32Array, Float32Array, Float64Array,
      Promise, Error, __dirname: path.dirname(file),
      require: (name) => {
        if (name === 'libvivid_composite.so') return { default: nativeModule };
        // Every other native module is absent: this suite measures the ArkTS
        // reference for the composition loops, and the detail stage is not part
        // of the band pipeline at all.
        if (name.endsWith('.so')) return { default: {} };
        if (name === '@kit.ArkTS') {
          return { taskpool: { Task: class { static isCanceled() { return false; } } } };
        }
        if (name.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
        return load(path.resolve(path.dirname(file), name + '.ets'));
      },
    }, { filename: file });
    return mod.exports;
  }
  return load;
}

const reference = makeLoader({})(root + '/edit/engine/WorkerCore.ets');

function toWslPath(winPath) {
  const normalized = path.resolve(winPath).replace(/\\/g, '/');
  return `/mnt/${normalized[0].toLowerCase()}${normalized.slice(2)}`;
}
function wsl(command) {
  return cp.spawnSync('wsl', ['-d', DISTRO, '--', 'bash', '-lc', command], { encoding: 'utf8' });
}

let checks = 0;
function ok(condition, message) {
  checks++;
  assert(condition, message);
}

const version = wsl('g++ --version >/dev/null 2>&1 && echo gxx-ok || echo gxx-missing');
if (version.status !== 0 || !String(version.stdout).includes('gxx-ok')) {
  console.log('SKIP check_composite_native_parity: no host C++ toolchain (g++ in WSL).');
  console.log('     Native/ArkTS parity for the composition loops was NOT verified here.');
  process.exit(0);
}
const compile = wsl(`g++ -O2 -ffp-contract=off -std=c++17 -I ${toWslPath(cppDir)} ` +
  `${toWslPath(path.join('tools', 'native_composite_probe.cpp'))} ` +
  `${toWslPath(path.join(cppDir, 'vivid_composite_core.cpp'))} -o ${probeBinary}`);
if (compile.status !== 0) console.error(compile.stderr || '');
ok(compile.status === 0, 'host probe must compile with the same flags as the device library');

// --- fixtures --------------------------------------------------------------
function makeBytes(length, seed) {
  const buffer = new Uint8ClampedArray(length);
  let state = seed >>> 0;
  for (let index = 0; index < length; index++) {
    state = (state * 1664525 + 1013904223) >>> 0;
    buffer[index] = (state >>> 24) & 0xff;
  }
  return buffer;
}

function makeMatrix(seed, scale) {
  const matrix = new Float32Array(20);
  let state = seed >>> 0;
  for (let index = 0; index < 20; index++) {
    state = (state * 1103515245 + 12345) >>> 0;
    matrix[index] = ((state >>> 16) % 1000) / 1000 * scale;
  }
  // Keep the alpha row close to identity so the fixtures stay opaque.
  matrix[15] = 0; matrix[16] = 0; matrix[17] = 0; matrix[18] = 1; matrix[19] = 0;
  return matrix;
}

const W = 512, H = 341;
const bandBytes = W * H * 4;

function writeProbeFile(name, bytes) {
  const file = path.join(probeDir, name);
  fs.writeFileSync(file, Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength));
  return toWslPath(file);
}

/** Run one native pass; returns the resulting bytes. */
function nativeMatrix(input, matrix, start, end) {
  const inputPath = writeProbeFile(`m_in_${probeCounter}.rgba`, input);
  const matrixPath = writeProbeFile(`m_mat_${probeCounter}.f32`, new Uint8Array(matrix.buffer));
  const outputPath = path.join(probeDir, `m_out_${probeCounter}.rgba`);
  probeCounter++;
  const run = wsl([probeBinary, 'matrix', inputPath, matrixPath, toWslPath(outputPath),
    start, end].join(' '));
  ok(run.status === 0, `matrix probe failed: ${run.stderr}`);
  const file = fs.readFileSync(outputPath);
  return new Uint8ClampedArray(file.buffer, file.byteOffset, file.byteLength);
}

function nativeMaskBlend(adjusted, maskAdjusted, mask, start, end, pixelOffset) {
  const adjustedPath = writeProbeFile(`b_adj_${probeCounter}.rgba`, adjusted);
  const maskAdjustedPath = writeProbeFile(`b_madj_${probeCounter}.rgba`, maskAdjusted);
  const maskPath = writeProbeFile(`b_mask_${probeCounter}.u8`, mask);
  const outputPath = path.join(probeDir, `b_out_${probeCounter}.rgba`);
  probeCounter++;
  const run = wsl([probeBinary, 'maskblend', adjustedPath, maskAdjustedPath, maskPath,
    start, end, pixelOffset, toWslPath(outputPath)].join(' '));
  ok(run.status === 0, `maskblend probe failed: ${run.stderr}`);
  const file = fs.readFileSync(outputPath);
  return new Uint8ClampedArray(file.buffer, file.byteOffset, file.byteLength);
}

function nativeComposite(result, base, adjusted, mask, opacity, blendMode, start, end, pixelOffset, falsify) {
  const resultPath = writeProbeFile(`c_res_${probeCounter}.rgba`, result);
  const basePath = writeProbeFile(`c_base_${probeCounter}.rgba`, base);
  const adjustedPath = writeProbeFile(`c_adj_${probeCounter}.rgba`, adjusted);
  const maskPath = mask ? writeProbeFile(`c_mask_${probeCounter}.u8`, mask) : '-';
  const outputPath = path.join(probeDir, `c_out_${probeCounter}.rgba`);
  probeCounter++;
  const args = [probeBinary, 'composite', resultPath, basePath, adjustedPath, maskPath,
    opacity, blendMode, start, end, pixelOffset, toWslPath(outputPath)];
  if (falsify !== undefined) args.push(`--falsify=${falsify}`);
  const run = wsl(args.join(' '));
  ok(run.status === 0, `composite probe failed: ${run.stderr}`);
  const file = fs.readFileSync(outputPath);
  return new Uint8ClampedArray(file.buffer, file.byteOffset, file.byteLength);
}
let probeCounter = 0;

/** A neutral WorkerAdjustments: every stage at its identity value. */
function neutralAdjustments() {
  return {
    exposure: 0, contrast: 0, brightness: 0, highlights: 0, shadows: 0, whites: 0, blacks: 0,
    vignetteAmount: 0, vignetteMidpoint: 0, vignetteRoundness: 0, vignetteFeather: 0, vignetteHighlights: 0,
    grainAmount: 0, grainSize: 0, grainRoughness: 0, saturation: 0, vibrance: 0,
    temperature: 0, tint: 0, hue: 0, toneCurve: 0, curveRed: 0, curveGreen: 0, curveBlue: 0,
    toneCurvePoints: [[0, 0], [1, 1]], redCurvePoints: [[0, 0], [1, 1]],
    greenCurvePoints: [[0, 0], [1, 1]], blueCurvePoints: [[0, 0], [1, 1]],
    parametricHighlights: 0, parametricLights: 0, parametricDarks: 0, parametricShadows: 0,
    parametricShadowSplit: 0, parametricDarkSplit: 0, parametricLightSplit: 0,
    parametricRefineSaturation: 0,
    mixHue: new Array(8).fill(0), mixSaturation: new Array(8).fill(0), mixLuminance: new Array(8).fill(0),
    calibrationRedHue: 0, calibrationRedSaturation: 0, calibrationGreenHue: 0,
    calibrationGreenSaturation: 0, calibrationBlueHue: 0, calibrationBlueSaturation: 0,
    colorGradingEnabled: false, gradingShadowsHue: 0, gradingShadowsSaturation: 0,
    gradingShadowsLuminance: 0, gradingMidtonesHue: 0, gradingMidtonesSaturation: 0,
    gradingMidtonesLuminance: 0, gradingHighlightsHue: 0, gradingHighlightsSaturation: 0,
    gradingHighlightsLuminance: 0, gradingGlobalHue: 0, gradingGlobalSaturation: 0,
    gradingGlobalLuminance: 0, gradingBlending: 0, gradingBalance: 0,
  };
}

/** Build a pipeline the way ProcessWorker does, then run the ArkTS band pass. */
function arktsBand(spec) {
  const width = spec.width || W;
  const height = spec.height || H;
  const bytes = width * height * 4;
  const result = spec.result ? Uint8ClampedArray.from(spec.result) : makeBytes(bytes, 11);
  const pipeline = {
    adjustments: neutralAdjustments(),
    matrix: spec.matrix || null,
    hasAdvanced: false,
    opacity: spec.opacity,
    blendMode: spec.blendMode,
    mask: spec.mask || null,
    base: Uint8ClampedArray.from(spec.base || makeBytes(bytes, 22)),
    adjusted: new Uint8ClampedArray(bytes),
    maskAdjustments: neutralAdjustments(),
    maskMatrix: spec.maskMatrix || null,
    hasMaskAdjustments: spec.hasMaskAdjustments === true,
    maskAdjusted: new Uint8ClampedArray(bytes),
    width,
    height,
    pixelOffset: spec.pixelOffset || 0,
  };
  const start = spec.start || 0;
  const end = spec.end || bytes;
  reference.applyLayerBandFull(result, pipeline, start, end);
  return { result, pipeline, start, end, bytes };
}

/** The same three passes the wrapper performs, in the same order. */
function nativeBand(spec) {
  const width = spec.width || W;
  const height = spec.height || H;
  const bytes = width * height * 4;
  const start = spec.start || 0;
  const end = spec.end || bytes;
  const pixelOffset = spec.pixelOffset || 0;
  const base = Uint8ClampedArray.from(spec.base || makeBytes(bytes, 22));
  const result = spec.result ? Uint8ClampedArray.from(spec.result) : makeBytes(bytes, 11);
  let adjusted = spec.matrix ? nativeMatrix(base, spec.matrix, start, end) : Uint8ClampedArray.from(base);
  if (spec.hasMaskAdjustments) {
    const maskAdjusted = spec.maskMatrix
      ? nativeMatrix(adjusted, spec.maskMatrix, start, end)
      : Uint8ClampedArray.from(adjusted);
    adjusted = nativeMaskBlend(adjusted, maskAdjusted, spec.mask, start, end, pixelOffset);
  }
  const compositeMask = spec.hasMaskAdjustments ? null : (spec.mask || null);
  return nativeComposite(result, base, adjusted, compositeMask, spec.opacity, spec.blendMode,
    start, end, pixelOffset);
}

function compare(referenceBytes, candidate) {
  const length = Math.min(referenceBytes.length, candidate.length);
  let maxCh = 0, over2 = 0;
  const channelMax = [0, 0, 0, 0];
  for (let index = 0; index < length; index++) {
    const delta = Math.abs(referenceBytes[index] - candidate[index]);
    if (delta > channelMax[index & 3]) channelMax[index & 3] = delta;
    if (delta > 2) over2++;
    if (delta > maxCh) maxCh = delta;
  }
  return { maxCh, over2, channelMax, lengthDiffers: referenceBytes.length !== candidate.length };
}

// --- cases -----------------------------------------------------------------
const cases = [];
for (const blendMode of [0, 1, 2, 3]) {
  cases.push({ name: `normal-opacity-${blendMode}`, spec: { matrix: makeMatrix(blendMode + 1, 0.15), opacity: 1, blendMode } });
  cases.push({ name: `masked-opacity0.35-${blendMode}`, spec: { matrix: makeMatrix(blendMode + 7, 0.12), mask: null, opacity: 0.35, blendMode, masked: 'composite' } });
}
cases.push({ name: 'opacity-0', spec: { matrix: makeMatrix(31, 0.2), opacity: 0, blendMode: 2 } });
cases.push({ name: 'no-matrix-normal', spec: { matrix: null, opacity: 1, blendMode: 0 } });
cases.push({ name: 'mask-adjustments', spec: { matrix: makeMatrix(41, 0.1), maskMatrix: makeMatrix(43, 0.08), hasMaskAdjustments: true, opacity: 0.8, blendMode: 3 } });
cases.push({ name: 'mask-adjustments-opacity1', spec: { matrix: makeMatrix(47, 0.2), maskMatrix: makeMatrix(53, 0.2), hasMaskAdjustments: true, opacity: 1, blendMode: 1 } });
cases.push({ name: 'band-offset', spec: { matrix: makeMatrix(59, 0.1), hasMaskAdjustments: true, maskMatrix: makeMatrix(61, 0.1), opacity: 0.6, blendMode: 2, start: 1024 * 4, end: 4096 * 4, pixelOffset: 1024 } });

const masks = new Map();
function maskFor(kind) {
  if (!masks.has(kind)) {
    const mask = new Uint8Array(W * H);
    for (let index = 0; index < mask.length; index++) {
      state = (state * 1664525 + 1013904223) >>> 0;
      mask[index] = index % 7 === 0 ? 0 : (state >>> 24) & 0xff;
    }
    masks.set(kind, mask);
  }
  return masks.get(kind);
}
let state = 99;

const rows = [];
for (const entry of cases) {
  const spec = Object.assign({}, entry.spec);
  // A composite-stage mask (no mask adjustments) and a mask-adjustment mask are
  // the two mask paths the ArkTS code distinguishes.
  if (spec.hasMaskAdjustments) spec.mask = maskFor('blend');
  else if (spec.masked === 'composite') spec.mask = maskFor('composite');
  const referenceRun = arktsBand(spec);
  const nativeBytes = nativeBand(spec);
  const diff = compare(referenceRun.result, nativeBytes);
  rows.push({ name: entry.name, maxCh: diff.maxCh, over2: diff.over2, channelMax: diff.channelMax });
  ok(!diff.lengthDiffers, `${entry.name}: same byte count`);
  ok(diff.maxCh === 0 && diff.over2 === 0,
    `${entry.name} must be byte-identical, got maxCh=${diff.maxCh} over2=${diff.over2} channels=${diff.channelMax}`);
}

// --- falsification ---------------------------------------------------------
{
  const spec = Object.assign({}, cases[2].spec);
  const referenceRun = arktsBand(spec);
  const base = Uint8ClampedArray.from(spec.base || makeBytes(W * H * 4, 22));
  const matrix = spec.matrix;
  const adjusted = matrix ? nativeMatrix(base, matrix, 0, W * H * 4) : base;
  const falsified = nativeComposite(referenceRun.result.slice(), base, adjusted, null,
    spec.opacity, spec.blendMode, 0, W * H * 4, 0, 1);
  const diff = compare(referenceRun.result, falsified);
  let differing = 0;
  for (let index = 0; index < referenceRun.result.length; index++) {
    if (referenceRun.result[index] !== falsified[index]) differing++;
  }
  ok(diff.maxCh > 0, 'falsified green channel must be detected');
  ok(diff.channelMax[0] === 0 && diff.channelMax[2] === 0 && diff.channelMax[3] === 0,
    'only the falsified channel may differ');
  ok(differing > 1000, `the wrong channel must be visible on the frame, only ${differing} bytes differed`);
}

// --- wrapper wiring (fake native that records its arguments) ----------------
{
  const calls = [];
  const fake = {
    apiVersion: () => 1,
    matrixBand: (input, matrix, output, start, end) => {
      calls.push({ kind: 'matrix', input, matrix, output, start, end });
      return false;
    },
    maskBlend: (adjusted, maskAdjusted, mask, start, end, pixelOffset) => {
      calls.push({ kind: 'maskBlend', adjusted, maskAdjusted, mask, start, end, pixelOffset });
      return false;
    },
    composite: (result, base, adjusted, mask, opacity, blendMode, start, end, pixelOffset) => {
      calls.push({ kind: 'composite', result, base, adjusted, mask, opacity, blendMode, start, end, pixelOffset });
      return false;
    },
  };
  const wired = makeLoader(fake)(root + '/edit/engine/WorkerCore.ets');
  const width = 32, height = 16, bytes = width * height * 4;
  const matrix = makeMatrix(77, 0.1);
  const maskMatrix = makeMatrix(79, 0.1);
  const mask = new Uint8Array(width * height).fill(128);
  const base = makeBytes(bytes, 3);
  const result = makeBytes(bytes, 4);
  const originalResult = Uint8ClampedArray.from(result);
  const pipeline = {
    adjustments: neutralAdjustments(), matrix, hasAdvanced: false, opacity: 0.42, blendMode: 3,
    mask, base: Uint8ClampedArray.from(base), adjusted: new Uint8ClampedArray(bytes),
    maskAdjustments: neutralAdjustments(), maskMatrix, hasMaskAdjustments: true,
    maskAdjusted: new Uint8ClampedArray(bytes), width, height, pixelOffset: 7,
  };
  wired.applyLayerBandFull(result, pipeline, 0, bytes);
  ok(calls.length === 4, `wrapper must make four native calls, made ${calls.length}: ${calls.map((c) => c.kind)}`);
  ok(calls[0].kind === 'matrix' && calls[0].input === pipeline.base && calls[0].output === pipeline.adjusted &&
    calls[0].start === 0 && calls[0].end === bytes, 'matrix pass must transform base into adjusted over the band');
  ok(calls[1].kind === 'matrix' && calls[1].input === pipeline.adjusted && calls[1].output === pipeline.maskAdjusted,
    'mask matrix must transform adjusted into maskAdjusted');
  ok(calls[2].kind === 'maskBlend' && calls[2].adjusted === pipeline.adjusted &&
    calls[2].maskAdjusted === pipeline.maskAdjusted && calls[2].mask === mask &&
    calls[2].pixelOffset === 7, 'mask blend must run on adjusted, with the band pixel offset');
  ok(calls[3].kind === 'composite' && calls[3].mask === null && calls[3].opacity === 0.42 &&
    calls[3].blendMode === 3 && calls[3].pixelOffset === 7,
    'composite must drop the mask after mask adjustments, and carry opacity/blend/offset');
  // Every fake call returned false, so the ArkTS loops must still have produced
  // the same frame as the pure-ArkTS reference.
  const pure = arktsBand({ matrix, maskMatrix, hasMaskAdjustments: true, opacity: 0.42, blendMode: 3,
    mask, base, result: originalResult, width, height, pixelOffset: 7 });
  ok(pure.result.length === result.length && compare(pure.result, result).maxCh === 0,
    'a rejected native call must fall back to the ArkTS loop, byte for byte');
  // And the mask-less composite path must pass null, not a stale mask.
  calls.length = 0;
  wired.applyLayerBandFull(result, Object.assign({}, pipeline, { hasMaskAdjustments: false }),
    0, bytes);
  const compositeCall = calls.find((call) => call.kind === 'composite');
  ok(compositeCall && compositeCall.mask === mask,
    'without mask adjustments the composite must receive the layer mask');
}

// --- performance -----------------------------------------------------------
const perfSpec = { matrix: makeMatrix(101, 0.12), hasMaskAdjustments: true, maskMatrix: makeMatrix(103, 0.1), mask: maskFor('perf'), opacity: 0.7, blendMode: 3 };
const perfReference = arktsBand(perfSpec);
const arktsStart = process.hrtime.bigint();
for (let run = 0; run < 3; run++) arktsBand(perfSpec);
const arktsMs = Number(process.hrtime.bigint() - arktsStart) / 1e6 / 3;
const nativePerf = nativeBand(perfSpec);
ok(compare(perfReference.result, nativePerf).maxCh === 0, 'timed case must still be byte-identical');
// In-process native timing (the single-shot numbers above include six WSL
// round trips, which are process-spawn cost rather than pipeline cost).
const benchInput = writeProbeFile('bench_in.rgba', perfSpec.base || makeBytes(bandBytes, 22));
const benchMask = writeProbeFile('bench_mask.u8', perfSpec.mask);
const benchMatrix = writeProbeFile('bench_matrix.f32', new Uint8Array(perfSpec.matrix.buffer));
const benchMaskMatrix = writeProbeFile('bench_maskmatrix.f32', new Uint8Array(perfSpec.maskMatrix.buffer));
const benchRun = wsl([probeBinary, 'bench', benchInput, benchMask, benchMatrix, benchMaskMatrix,
  perfSpec.opacity, perfSpec.blendMode, 0, bandBytes, 0, 30, '/tmp/vivid_composite_bench.rgba'].join(' '));
ok(benchRun.status === 0, `bench mode failed: ${benchRun.stderr}`);
const benchMatch = /ms=([0-9.]+)/.exec(String(benchRun.stdout));
const nativeMs = benchMatch ? Number(benchMatch[1]) : NaN;

console.log('case                              maxCh over2  ch0 ch1 ch2 ch3');
console.log('-'.repeat(66));
for (const row of rows) {
  console.log(`${row.name.padEnd(33)} ${String(row.maxCh).padStart(5)} ${String(row.over2).padStart(5)}` +
    `  ${row.channelMax.map((v) => String(v).padStart(3)).join(' ')}`);
}
console.log('');
console.log(`one 512x341 band, matrix+mask+overlay (30 native runs, 3 ArkTS runs): ` +
  `arkts=${arktsMs.toFixed(1)}ms native=${nativeMs.toFixed(2)}ms speedup=${(arktsMs / nativeMs).toFixed(1)}x`);
console.log(`check_composite_native_parity: ${checks} checks, ${rows.length} byte comparisons`);

fs.rmSync(probeDir, { recursive: true, force: true });
