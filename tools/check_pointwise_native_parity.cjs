// Pointwise native parity: LUT stack, point colour, OkLCh, and a combined
// layer + LUT + point-colour + OkLCh scene, byte for byte.
//
// Why this suite exists: the export pointwise stage still walked every pixel in
// interpreted ArkTS for three stages that had not moved to C++ (LUT sampling,
// point colour, OkLCh). Moving them is only acceptable if the production path
// (native first) and the pure ArkTS reference produce identical bytes. This
// suite compiles the same translation unit the device library uses, feeds it
// the same packed typed arrays production sends, and asserts maxCh === 0 for
// every case at two sizes.
//
// The suite also proves the test can fail: with --falsify <channel> the C++
// core adds one to every sample of that channel. The test then asserts maxCh > 0
// and that every differing byte lies on that channel, so a channel swap or a
// silently ignored stage cannot pass.
//
// Fallback is exercised twice: a registry with no native module (the normal
// Node path) and one whose exports throw. Both must equal the ArkTS reference
// byte for byte, and both must log VIVID_NATIVE_POINTWISE fallback=...
//
// Host toolchain: same WSL g++ dependency as check_advanced_native_parity.cjs;
// absent g++ prints SKIP and exits 0.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const os = require('os');
const cp = require('child_process');
const assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const root = path.resolve('entry/src/main/ets');
const cppDir = path.resolve('entry/src/main/cpp');
const probeSource = path.resolve('tools/native_pointwise_probe.cpp');
const DISTRO = process.env.VIVID_WSL_DISTRO || 'Ubuntu-22.04';
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vivid-pointwise-parity-'));
const probeBinary = '/tmp/vivid_pointwise_probe_' + process.pid;

let checks = 0;
function ok(condition, message) {
  checks++;
  assert(condition, message);
}

function toWslPath(winPath) {
  const normalized = path.resolve(winPath).replace(/\\/g, '/');
  return `/mnt/${normalized[0].toLowerCase()}${normalized.slice(2)}`;
}

function wsl(command) {
  return cp.spawnSync('wsl', ['-d', DISTRO, '--', 'bash', '-lc', command], { encoding: 'utf8' });
}

const version = wsl('g++ --version >/dev/null 2>&1 && echo gxx-ok || echo gxx-missing');
if (version.status !== 0 || !String(version.stdout).includes('gxx-ok')) {
  console.log('SKIP check_pointwise_native_parity: no host C++ toolchain (g++ in WSL).');
  process.exit(0);
}

const compile = wsl(`g++ -O2 -ffp-contract=off -std=c++17 -I ${toWslPath(cppDir)} ` +
  `${toWslPath(probeSource)} ${toWslPath(path.join(cppDir, 'vivid_pointwise_core.cpp'))} ` +
  `${toWslPath(path.join(cppDir, 'vivid_composite_core.cpp'))} -o ${probeBinary}`);
if (compile.status !== 0) {
  console.error(compile.stdout);
  console.error(compile.stderr);
  throw new Error('failed to compile native pointwise probe');
}

/** One module registry per native behaviour, so a throw cannot poison another. */
function makeLoader(nativeMode) {
  const modules = new Map();
  const warnings = [];
  const nativeCalls = { count: 0, values: [], metas: [] };
  function fakeNative() {
    if (nativeMode === 'throwing') {
      const boom = () => { throw new Error('native disabled for fallback test'); };
      return { default: {
        matrixBand: boom, maskBlend: boom, composite: boom, advancedBand: boom,
        lutStack: boom, pointColor: boom, oklch: boom, apiVersion: boom,
      } };
    }
    if (nativeMode === 'counting') {
      // Accepts every LUT call and records the exact typed arrays it received:
      // the build-once test asserts identity, so a per-band rebuild is visible.
      const accept = () => true;
      return { default: {
        matrixBand: () => false, maskBlend: () => false, composite: () => false,
        advancedBand: () => false,
        lutStack: (pixels, values, meta) => {
          nativeCalls.count++;
          nativeCalls.values.push(values);
          nativeCalls.metas.push(meta);
          return true;
        },
        pointColor: accept, oklch: accept, apiVersion: () => 3,
      } };
    }
    return { default: {} };
  }
  function load(file) {
    file = path.resolve(file);
    if (modules.has(file)) return modules.get(file).exports;
    const mod = { exports: {} };
    modules.set(file, mod);
    const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
    }).outputText;
    vm.runInNewContext(js, {
      module: mod, exports: mod.exports,
      console: { info() {}, warn(message) { warnings.push(String(message)); }, error() {} },
      Math, Number, Date, Map, Set, ArrayBuffer, Error,
      Uint8Array, Uint16Array, Uint32Array, Int32Array, Float32Array, Float64Array, Uint8ClampedArray,
      Promise, setTimeout, clearTimeout, TextEncoder, TextDecoder, __dirname: path.dirname(file),
      Observed: (c) => c, Concurrent: (f) => f,
      AppStorage: { get: () => undefined, setOrCreate: () => {} },
      require: (name) => {
        if (name.endsWith('.so')) return fakeNative();
        if (name === '@kit.ArkTS') {
          return { taskpool: { Task: class { static isCanceled() { return false; } }, execute: async (task) => task } };
        }
        if (name.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
        return load(path.resolve(path.dirname(file), name + '.ets'));
      },
    }, { filename: file });
    return mod.exports;
  }
  return { load, warnings, nativeCalls };
}

const absentRegistry = makeLoader('absent');
const throwingRegistry = makeLoader('throwing');
const countingRegistry = makeLoader('counting');
const workerAbsent = absentRegistry.load(root + '/edit/engine/WorkerCore.ets');
const workerThrowing = throwingRegistry.load(root + '/edit/engine/WorkerCore.ets');
const workerCounting = countingRegistry.load(root + '/edit/engine/WorkerCore.ets');
const pointAbsent = absentRegistry.load(root + '/edit/engine/PointColorCore.ets');
const oklchAbsent = absentRegistry.load(root + '/edit/engine/OkLChCore.ets');

const { buildMatrix, applyLayerBandFull, applyLutStack, applyLutStackReference,
  applyPointColorBuffer, applyOkLChBuffer } = workerAbsent;

/* ------------------------------- fixture I/O ------------------------------ */

class Writer {
  constructor() { this.parts = []; }
  bytes(buffer) { this.parts.push(buffer); return this; }
  u32(value) { const b = Buffer.alloc(4); b.writeUInt32LE(value >>> 0, 0); return this.bytes(b); }
  i32(value) { const b = Buffer.alloc(4); b.writeInt32LE(value | 0, 0); return this.bytes(b); }
  f32(value) { const b = Buffer.alloc(4); b.writeFloatLE(value, 0); return this.bytes(b); }
  f64(value) { const b = Buffer.alloc(8); b.writeDoubleLE(value, 0); return this.bytes(b); }
  done() { return Buffer.concat(this.parts); }
}

function makePixels(width, height, seed) {
  const pixels = new Uint8ClampedArray(width * height * 4);
  let state = seed >>> 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      state = (state * 1664525 + 1013904223) >>> 0;
      pixels[i] = (x * 255 / Math.max(1, width - 1) + ((state >>> 24) & 31)) & 0xff;
      pixels[i + 1] = (y * 255 / Math.max(1, height - 1) + ((state >>> 16) & 31)) & 0xff;
      pixels[i + 2] = ((x * 7 + y * 13 + (state & 63)) * 3) & 0xff;
      pixels[i + 3] = 255;
    }
  }
  return pixels;
}

function makeLut(size, gamma, amount, minValue, maxValue) {
  const values = [];
  for (let b = 0; b < size; b++) {
    for (let g = 0; g < size; g++) {
      for (let r = 0; r < size; r++) {
        values.push(Math.pow(r / (size - 1), gamma),
          Math.pow(g / (size - 1), gamma * 0.95),
          Math.pow(b / (size - 1), gamma * 1.05));
      }
    }
  }
  return { enabled: true, intensity: amount, size, values,
    domainMin: [minValue, minValue, minValue], domainMax: [maxValue, maxValue, maxValue] };
}

const LUT_STACK = [
  makeLut(17, 0.82, 0.65, 0, 1),
  makeLut(9, 1.15, 0.4, 0.04, 0.96),
];

const POINT_SAMPLES = [
  { hue: 0.05, saturation: 0.62, luminance: 0.48, hueShift: 0.35, saturationShift: 0.4,
    luminanceShift: 0.2, hueRange: 0.08, saturationRange: 0.3, luminanceRange: 0.3 },
  { hue: 0.58, saturation: 0.5, luminance: 0.55, hueShift: -0.25, saturationShift: -0.3,
    luminanceShift: -0.15, hueRange: 0.1, saturationRange: 0.25, luminanceRange: 0.35 },
];

const OKLCH_PARAMS = { lightness: 0.035, chroma: 0.22, hue: 0.04 };

function buildFixture(options) {
  const { stage, width, height, pixels } = options;
  const lutStack = options.lutStack || [];
  const samples = options.samples || [];
  const hasLayer = options.hasLayer ? 1 : 0;
  const hasMask = options.hasMask ? 1 : 0;
  const maskConsumed = options.maskConsumed ? 1 : 0;
  const writer = new Writer();
  writer.u32(0x50575631).u32(stage).i32(width).i32(height)
    .i32(lutStack.length).i32(samples.length).i32(hasLayer).i32(hasMask)
    .i32(maskConsumed)
    .f64(options.opacity === undefined ? 1 : options.opacity)
    .i32(options.blendMode || 0);
  if (hasLayer) {
    const matrix = options.matrix;
    for (let i = 0; i < 20; i++) writer.f32(matrix[i]);
  }
  if (hasMask && maskConsumed) {
    const maskMatrix = options.maskMatrix;
    for (let i = 0; i < 20; i++) writer.f32(maskMatrix[i]);
  }
  for (const lut of lutStack) {
    writer.i32(lut.size).i32(lut.values.length).f64(lut.intensity)
      .f64(lut.domainMin[0]).f64(lut.domainMin[1]).f64(lut.domainMin[2])
      .f64(lut.domainMax[0]).f64(lut.domainMax[1]).f64(lut.domainMax[2]);
    for (const value of lut.values) writer.f64(value);
  }
  for (const sample of samples) {
    writer.f64(sample.hue).f64(sample.saturation).f64(sample.luminance)
      .f64(sample.hueShift).f64(sample.saturationShift).f64(sample.luminanceShift)
      .f64(sample.hueRange).f64(sample.saturationRange).f64(sample.luminanceRange);
  }
  if (stage === 2 || stage === 3) {
    const params = options.oklch || { lightness: 0, chroma: 0, hue: 0 };
    writer.f64(params.lightness).f64(params.chroma).f64(params.hue);
  }
  if (hasMask) {
    writer.u32(options.mask.length).bytes(Buffer.from(options.mask.buffer, options.mask.byteOffset, options.mask.byteLength));
  }
  writer.u32(pixels.length).bytes(Buffer.from(pixels.buffer, pixels.byteOffset, pixels.byteLength));
  return writer.done();
}

function runProbe(fixture, label, falsifyChannel) {
  const input = path.join(tmpDir, label + '.bin');
  const output = path.join(tmpDir, label + '.out');
  fs.writeFileSync(input, fixture);
  const command = `'${probeBinary}' '${toWslPath(input)}' '${toWslPath(output)}'` +
    (falsifyChannel === undefined ? '' : ` --falsify ${falsifyChannel}`);
  const result = wsl(command);
  if (result.status !== 0) {
    console.error(result.stdout);
    console.error(result.stderr);
    throw new Error(`probe failed for ${label}`);
  }
  return new Uint8ClampedArray(fs.readFileSync(output));
}

/** kLutStack* code for a fixture's LUT stack, straight from the C++ validator. */
function runProbeReason(fixture, label) {
  const input = path.join(tmpDir, label + '.bin');
  fs.writeFileSync(input, fixture);
  const result = wsl(`'${probeBinary}' '${toWslPath(input)}' - --reason`);
  if (result.status !== 0) {
    console.error(result.stdout);
    console.error(result.stderr);
    throw new Error(`reason probe failed for ${label}`);
  }
  return Number(String(result.stdout).trim());
}

/** Element count the N-API boundary must derive from a reported length. */
function runProbeLengths(reported, viewBytes, elementSize) {
  const result = wsl(`'${probeBinary}' - - --lengths ${reported} ${viewBytes} ${elementSize}`);
  if (result.status !== 0) {
    console.error(result.stdout);
    console.error(result.stderr);
    throw new Error('length probe failed');
  }
  return Number(String(result.stdout).trim());
}

function maxChannelDiff(reference, native) {
  let maxCh = 0;
  let count = 0;
  let sum = 0;
  const channels = new Set();
  for (let i = 0; i < reference.length; i++) {
    const diff = Math.abs(reference[i] - native[i]);
    if (diff !== 0) {
      count++;
      channels.add(i % 4);
      sum += diff;
    }
    if (diff > maxCh) maxCh = diff;
  }
  return { maxCh, count, sum, channels };
}

function assertParity(label, reference, native) {
  const diff = maxChannelDiff(reference, native);
  ok(diff.maxCh === 0, `${label}: native vs ArkTS maxCh=${diff.maxCh} (must be 0)`);
  return diff;
}

/* --------------------------------- cases --------------------------------- */

function maskGradient(width, height) {
  const mask = new Uint8ClampedArray(width * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      mask[y * width + x] = Math.max(0, Math.min(255,
        Math.round(255 * (0.15 + 0.75 * x / Math.max(1, width - 1) * (y / Math.max(1, height - 1))))));
    }
  }
  return mask;
}

function layerAdjustments() {
  return {
    exposure: 0.12, contrast: 0.22, brightness: 0, highlights: 0.15, shadows: -0.1,
    whites: 0, blacks: 0, saturation: 0.18, vibrance: 0.2, temperature: 1.06, tint: 0.03, hue: 0.02,
    toneCurve: 0, curveRed: 0, curveGreen: 0, curveBlue: 0,
    toneCurvePoints: [[0, 0], [1, 1]], redCurvePoints: [[0, 0], [1, 1]],
    greenCurvePoints: [[0, 0], [1, 1]], blueCurvePoints: [[0, 0], [1, 1]],
    parametricHighlights: 0, parametricLights: 0, parametricDarks: 0, parametricShadows: 0,
    parametricShadowSplit: 0.25, parametricDarkSplit: 0.5, parametricLightSplit: 0.75,
    parametricRefineSaturation: 1,
    mixHue: [0.1, -0.1, 0.05, 0, 0, 0, 0, 0],
    mixSaturation: [0.2, 0, -0.15, 0, 0.1, 0, 0, 0],
    mixLuminance: [0, 0.1, 0, -0.05, 0, 0, 0, 0],
    calibrationRedHue: 0.03, calibrationRedSaturation: 0.05,
    calibrationGreenHue: 0, calibrationGreenSaturation: 0,
    calibrationBlueHue: -0.02, calibrationBlueSaturation: 0.04,
    colorGradingEnabled: false,
    gradingShadowsHue: 0, gradingShadowsSaturation: 0, gradingShadowsLuminance: 0,
    gradingMidtonesHue: 0, gradingMidtonesSaturation: 0, gradingMidtonesLuminance: 0,
    gradingHighlightsHue: 0, gradingHighlightsSaturation: 0, gradingHighlightsLuminance: 0,
    gradingGlobalHue: 0, gradingGlobalSaturation: 0, gradingGlobalLuminance: 0,
    gradingBlending: 0, gradingBalance: 0,
    vignetteAmount: 0, vignetteMidpoint: 0.5, vignetteRoundness: 0, vignetteFeather: 0.8,
    vignetteHighlights: 0, grainAmount: 0, grainSize: 0.5, grainRoughness: 0.5,
  };
}

function neutralAdjustments() {
  const adjustments = layerAdjustments();
  adjustments.exposure = 0;
  adjustments.contrast = 0;
  adjustments.highlights = 0;
  adjustments.shadows = 0;
  adjustments.whites = 0;
  adjustments.blacks = 0;
  adjustments.saturation = 0;
  adjustments.vibrance = 0;
  adjustments.temperature = 0;
  adjustments.tint = 0;
  adjustments.hue = 0;
  adjustments.mixHue = adjustments.mixHue.map(() => 0);
  adjustments.mixSaturation = adjustments.mixSaturation.map(() => 0);
  adjustments.mixLuminance = adjustments.mixLuminance.map(() => 0);
  adjustments.calibrationRedHue = 0;
  adjustments.calibrationRedSaturation = 0;
  adjustments.calibrationGreenHue = 0;
  adjustments.calibrationGreenSaturation = 0;
  adjustments.calibrationBlueHue = 0;
  adjustments.calibrationBlueSaturation = 0;
  return adjustments;
}

const SIZES = [
  { width: 192, height: 160 },
  { width: 320, height: 257 },
];

const report = [];

for (const { width, height } of SIZES) {
  const pixels = makePixels(width, height, 0x51ed + width * 31 + height);
  const sizeLabel = `${width}x${height}`;
  const matrix = Array.from(buildMatrix(layerAdjustments()));
  const maskMatrix = Array.from(buildMatrix(Object.assign(layerAdjustments(), { exposure: 0.24 })));
  const mask = maskGradient(width, height);

  // 1. LUT stack, including multi-LUT composition, interpolation and domains.
  {
    const reference = new Uint8ClampedArray(pixels);
    applyLutStackReference(reference, LUT_STACK);
    const native = runProbe(buildFixture({ stage: 0, width, height, pixels,
      lutStack: LUT_STACK }), `lut-${sizeLabel}`);
    report.push({ label: `${sizeLabel} LUT 栈(2 表/域映射/插值)`, diff: assertParity('LUT', reference, native) });
  }

  // 2. Point colour: ordered samples, hue/saturation/luminance shifts.
  {
    const reference = new Uint8ClampedArray(pixels);
    pointAbsent.applyPointColorBuffer(reference, width, height, POINT_SAMPLES);
    const native = runProbe(buildFixture({ stage: 1, width, height, pixels,
      samples: POINT_SAMPLES }), `point-${sizeLabel}`);
    report.push({ label: `${sizeLabel} 点颜色(2 样本/HSL 偏移)`, diff: assertParity('pointColor', reference, native) });
  }

  // 3. OkLCh, including gamut mapping.
  {
    const reference = new Uint8ClampedArray(pixels);
    oklchAbsent.applyOkLChBuffer(reference, width, height, OKLCH_PARAMS);
    const native = runProbe(buildFixture({ stage: 2, width, height, pixels,
      oklch: OKLCH_PARAMS }), `oklch-${sizeLabel}`);
    report.push({ label: `${sizeLabel} OkLCh(色域映射)`, diff: assertParity('oklch', reference, native) });
  }

  // 4. Layer pass: matrix -> mask matrix -> mask alpha -> blend + opacity.
  {
    const adjusted = new Uint8ClampedArray(pixels);
    const base = new Uint8ClampedArray(pixels);
    const maskAdjusted = new Uint8ClampedArray(pixels);
    const result = new Uint8ClampedArray(pixels);
    const pipeline = {
      adjustments: layerAdjustments(), matrix: new Float32Array(matrix), hasAdvanced: false,
      opacity: 0.62, blendMode: 3, mask: mask, base: base, adjusted: adjusted,
      maskAdjustments: neutralAdjustments(),
      maskMatrix: null, hasMaskAdjustments: false,
      maskAdjusted: maskAdjusted, width: width, height: height, pixelOffset: 0,
    };
    applyLayerBandFull(result, pipeline, 0, result.length);
    const native = runProbe(buildFixture({ stage: 3, width, height, pixels,
      hasLayer: true, matrix: matrix, hasMask: true, maskConsumed: false, mask: mask,
      opacity: 0.62, blendMode: 3, lutStack: [], samples: [], oklch: { lightness: 0, chroma: 0, hue: 0 } }),
      `layer-${sizeLabel}`);
    report.push({ label: `${sizeLabel} 矩阵+蒙版 alpha+不透明度+叠加混合`, diff: assertParity('layer', result, native) });
  }

  // 5. Combined scene in production order.
  {
    const adjusted = new Uint8ClampedArray(pixels);
    const base = new Uint8ClampedArray(pixels);
    const maskAdjusted = new Uint8ClampedArray(pixels);
    const result = new Uint8ClampedArray(pixels);
    const pipeline = {
      adjustments: layerAdjustments(), matrix: new Float32Array(matrix), hasAdvanced: false,
      opacity: 0.62, blendMode: 3, mask: mask, base: base, adjusted: adjusted,
      maskAdjustments: neutralAdjustments(),
      maskMatrix: null, hasMaskAdjustments: false,
      maskAdjusted: maskAdjusted, width: width, height: height, pixelOffset: 0,
    };
    applyLayerBandFull(result, pipeline, 0, result.length);
    applyLutStackReference(result, LUT_STACK);
    pointAbsent.applyPointColorBuffer(result, width, height, POINT_SAMPLES);
    oklchAbsent.applyOkLChBuffer(result, width, height, OKLCH_PARAMS);
    const native = runProbe(buildFixture({ stage: 3, width, height, pixels,
      hasLayer: true, matrix: matrix, hasMask: true, maskConsumed: false, mask: mask,
      opacity: 0.62, blendMode: 3, lutStack: LUT_STACK, samples: POINT_SAMPLES, oklch: OKLCH_PARAMS }),
      `combo-${sizeLabel}`);
    report.push({ label: `${sizeLabel} 组合(图层+蒙版+LUT+点颜色+OkLCh)`, diff: assertParity('combo', result, native) });
  }
}

/* --------------------------- reject-code contract -------------------------- */

{
  // The device log names the failing field via lutStackReason, so the codes are
  // a contract: valid data must return 0, and each malformed field its own code.
  const width = 8, height = 8;
  const pixels = makePixels(width, height, 0x5eed);
  const reasonFor = (stack, label) => runProbeReason(
    buildFixture({ stage: 0, width, height, pixels, lutStack: stack }), label);

  ok(reasonFor(LUT_STACK, 'reason-valid') === 0, 'valid LUT stack must report kLutStackOk=0');
  ok(reasonFor([makeLut(1, 1, 1, 0, 1)], 'reason-size') === 5,
    'size 1 must report kLutStackBadSize=5');
  ok(reasonFor([Object.assign(makeLut(9, 1, 1, 0, 1), { intensity: -0.25 })] , 'reason-amount') === 6,
    'negative intensity must report kLutStackBadIntensity=6');
  ok(reasonFor([Object.assign(makeLut(9, 1, 1, 0, 1), { domainMax: [NaN, 1, 1] })], 'reason-domain') === 7,
    'non-finite domain must report kLutStackBadDomain=7');
  ok(reasonFor([Object.assign(makeLut(9, 1, 1, 0, 1), { domainMax: [0, 1, 1] })], 'reason-order') === 8,
    'max <= min must report kLutStackBadDomainOrder=8');
  ok(reasonFor([{ enabled: true, intensity: 1, size: 9, values: [], domainMin: [0, 0, 0],
    domainMax: [1, 1, 1] }], 'reason-short') === 4,
    'fewer than three doubles must report kLutStackValuesTooShort=4');
  ok(reasonFor([{ enabled: true, intensity: 1, size: 9, values: [0, 0, 0], domainMin: [0, 0, 0],
    domainMax: [1, 1, 1] }], 'reason-bounds') === 10,
    'a truncated table must report kLutStackTableOutOfRange=10');
  // The second entry is the invalid one: the validator must walk the whole
  // stack, not just the first entry.
  ok(reasonFor([makeLut(9, 1, 1, 0, 1), makeLut(1, 1, 1, 0, 1)], 'reason-second') === 5,
    'an invalid second LUT must still be reported');
}

/* ----------------------- N-API length normalisation ----------------------- */

{
  // Measured on device: a 9-element Float64Array arrives as 72 (bytes). Both
  // semantics must produce 9 elements; a shorter byte view must trust the
  // runtime's element count instead of the buffer size.
  ok(runProbeLengths(9, 72, 8) === 9, 'element-count semantics: 9 doubles stays 9');
  ok(runProbeLengths(72, 72, 8) === 9, 'byte-count semantics: 72 bytes -> 9 doubles');
  ok(runProbeLengths(107811, 862488, 8) === 107811,
    'byte-count semantics: a 33^3 table must become 107811 doubles');
  ok(runProbeLengths(18, 72, 4) === 18, 'element-count semantics: 18 floats stays 18');
  ok(runProbeLengths(72, 72, 4) === 18, 'byte-count semantics: 72 bytes -> 18 floats');
  ok(runProbeLengths(100, 512, 1) === 100,
    'a short byte subview must trust the reported element count');
  ok(runProbeLengths(512, 512, 1) === 512, 'a full byte view keeps its length');
  ok(runProbeLengths(0, 0, 8) === 0, 'empty arrays stay empty');
}

/* ------------------------- prepared LUT stack ---------------------------- */

{
  const width = 192, height = 160;
  const pixels = makePixels(width, height, 0x9a9a);
  const reference = new Uint8ClampedArray(pixels);
  applyLutStackReference(reference, LUT_STACK);

  // Absent native: no payload is built, and the prepared path is exactly the
  // reference applied band by band.
  const preparedAbsent = workerAbsent.prepareLutStack(LUT_STACK);
  ok(preparedAbsent.payload === null, 'no native module must not build a payload');
  ok(workerAbsent.currentLutBuildCount() === 0, 'no native module must count zero builds');
  const banded = new Uint8ClampedArray(pixels);
  const cut = (banded.length / 2) & ~3;
  workerAbsent.applyPreparedLutStack(banded.subarray(0, cut), preparedAbsent);
  workerAbsent.applyPreparedLutStack(banded.subarray(cut), preparedAbsent);
  assertParity('prepared stack (absent native), two bands', reference, banded);

  // Counting native: one build for the frame, the same payload object for every
  // band. A per-band rebuild would change the identity and the build count.
  const preparedNative = workerCounting.prepareLutStack(LUT_STACK);
  ok(preparedNative.payload !== null, 'native module must pack a payload');
  ok(preparedNative.payload.meta.length === LUT_STACK.length * 9,
    'meta must hold nine doubles per LUT');
  ok(preparedNative.payload.values.length === LUT_STACK.reduce((sum, lut) => sum + lut.values.length, 0),
    'values must concatenate every table exactly once');
  ok(workerCounting.currentLutBuildCount() === 1, 'preparing a stack must build exactly once');
  const callsBefore = countingRegistry.nativeCalls.count;
  const streamed = new Uint8ClampedArray(pixels);
  const bands = 5;
  const step = Math.ceil((streamed.length / bands) / 4) * 4;
  for (let start = 0; start < streamed.length; start += step) {
    workerCounting.applyPreparedLutStack(streamed.subarray(start, Math.min(streamed.length, start + step)),
      preparedNative);
  }
  ok(countingRegistry.nativeCalls.count - callsBefore === bands,
    `every band must call native (saw ${countingRegistry.nativeCalls.count - callsBefore}/${bands})`);
  ok(countingRegistry.nativeCalls.values.every((values) => values === preparedNative.payload.values),
    'every band must reuse the same packed values array (no per-band rebuild)');
  ok(countingRegistry.nativeCalls.metas.every((meta) => meta === preparedNative.payload.meta),
    'every band must reuse the same packed meta array (no per-band rebuild)');
  ok(workerCounting.currentLutBuildCount() === 1,
    `applying ${bands} bands must not build again (count=${workerCounting.currentLutBuildCount()})`);
}

{
  // The bundled 65^3 LUTs are the worst case that motivated the fix: one table
  // is 823875 doubles (6.3 MB), so a per-band rebuild copied ~680 MB per frame.
  const size = 65;
  const bigLut = makeLut(size, 1.05, 0.97, 0.02, 0.98);
  const pixels = makePixels(16, 16, 0x77aa);
  const reason = runProbeReason(
    buildFixture({ stage: 0, width: 16, height: 16, pixels, lutStack: [bigLut] }), 'reason-65');
  ok(reason === 0, `65^3 LUT must validate (got ${reason})`);
  const prepared = workerCounting.prepareLutStack([bigLut]);
  ok(prepared.payload.values.length === size * size * size * 3,
    '65^3 values must pack to 823875 doubles');
  ok(prepared.payload.meta.length === 9, '65^3 meta must stay nine doubles');
  ok(workerCounting.currentLutBuildCount() === 2, 'the 65^3 stack is a second build, not a reuse');
}

{
  // A native call that throws must still produce exactly the reference bytes
  // and must stop retrying native for the rest of the frame.
  const width = 128, height = 96;
  const pixels = makePixels(width, height, 0x1234);
  const reference = new Uint8ClampedArray(pixels);
  applyLutStackReference(reference, LUT_STACK);
  const preparedThrowing = workerThrowing.prepareLutStack(LUT_STACK);
  ok(preparedThrowing.payload !== null, 'a throwing native module still packs a payload');
  const got = new Uint8ClampedArray(pixels);
  const cut = (got.length / 2) & ~3;
  workerThrowing.applyPreparedLutStack(got.subarray(0, cut), preparedThrowing);
  ok(preparedThrowing.rejected, 'a thrown native call must disable native for later bands');
  workerThrowing.applyPreparedLutStack(got.subarray(cut), preparedThrowing);
  assertParity('prepared stack (throwing native), two bands', reference, got);
}

/* ------------------------------ falsification ----------------------------- */

{
  const width = 192, height = 160;
  const pixels = makePixels(width, height, 0xbeef);
  const reference = new Uint8ClampedArray(pixels);
  applyLutStackReference(reference, LUT_STACK);
  const honest = runProbe(buildFixture({ stage: 0, width, height, pixels, lutStack: LUT_STACK }),
    'falsify-honest');
  ok(maxChannelDiff(reference, honest).maxCh === 0, 'falsify control: unmodified probe must be maxCh=0');

  const falsified = runProbe(buildFixture({ stage: 0, width, height, pixels, lutStack: LUT_STACK }),
    'falsify-green', 1);
  const diff = maxChannelDiff(reference, falsified);
  ok(diff.maxCh > 0, '--falsify 1 must produce maxCh > 0');
  ok(diff.maxCh === 1, `--falsify 1 must differ by exactly 1, got ${diff.maxCh}`);
  ok(diff.count > 0, '--falsify 1 must change some bytes');
  ok(diff.channels.size === 1 && diff.channels.has(1),
    `--falsify 1 differences must fall only on green, saw channels ${[...diff.channels].join(',')}`);
  console.log(`证伪: --falsify 1 -> maxCh=${diff.maxCh} diffBytes=${diff.count} ` +
    `channels=${[...diff.channels].join(',')}`);
}

/* ------------------------------- fallback --------------------------------- */

{
  const width = 192, height = 160;
  const pixels = makePixels(width, height, 0xfa11);

  const referenceLut = new Uint8ClampedArray(pixels);
  applyLutStackReference(referenceLut, LUT_STACK);
  const absentLut = new Uint8ClampedArray(pixels);
  applyLutStack(absentLut, LUT_STACK);
  assertParity('fallback(absent) LUT', referenceLut, absentLut);
  const throwingLut = new Uint8ClampedArray(pixels);
  workerThrowing.applyLutStack(throwingLut, LUT_STACK);
  assertParity('fallback(throwing) LUT', referenceLut, throwingLut);

  const referencePoint = new Uint8ClampedArray(pixels);
  pointAbsent.applyPointColorBuffer(referencePoint, width, height, POINT_SAMPLES);
  const absentPoint = new Uint8ClampedArray(pixels);
  applyPointColorBuffer(absentPoint, width, height, POINT_SAMPLES);
  assertParity('fallback(absent) pointColor', referencePoint, absentPoint);
  const throwingPoint = new Uint8ClampedArray(pixels);
  workerThrowing.applyPointColorBuffer(throwingPoint, width, height, POINT_SAMPLES);
  assertParity('fallback(throwing) pointColor', referencePoint, throwingPoint);

  const referenceOklch = new Uint8ClampedArray(pixels);
  oklchAbsent.applyOkLChBuffer(referenceOklch, width, height, OKLCH_PARAMS);
  const absentOklch = new Uint8ClampedArray(pixels);
  applyOkLChBuffer(absentOklch, width, height, OKLCH_PARAMS);
  assertParity('fallback(absent) oklch', referenceOklch, absentOklch);
  const throwingOklch = new Uint8ClampedArray(pixels);
  workerThrowing.applyOkLChBuffer(throwingOklch, width, height, OKLCH_PARAMS);
  assertParity('fallback(throwing) oklch', referenceOklch, throwingOklch);

  const fallbackLogs = throwingRegistry.warnings.filter((line) =>
    line.includes('VIVID_NATIVE_POINTWISE fallback'));
  ok(fallbackLogs.length > 0, 'throwing native module must log VIVID_NATIVE_POINTWISE fallback');

  const absentLogs = absentRegistry.warnings.filter((line) =>
    line.includes('VIVID_NATIVE_POINTWISE fallback'));
  ok(absentLogs.length > 0, 'absent native module must log VIVID_NATIVE_POINTWISE fallback');
}

/* --------------------------------- report --------------------------------- */

console.log('PASS 逐点阶段 native <=> ArkTS 逐字节：');
for (const row of report) {
  console.log(`  - ${row.label}: maxCh=${row.diff.maxCh} diff=${row.diff.count}`);
}
console.log(checks + ' 项通过');
