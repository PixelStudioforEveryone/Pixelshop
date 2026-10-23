// GPU-side verification for the parametric tone curve.
//
// check_shader_parity.cjs proves the shader COMPILES and that the CPU/GPU export
// paths agree for its own combinations, but it marshals options by hand for a
// WSL native binary and its combinations never enable the parametric curve. So
// it cannot speak to this feature. Rather than claim GPU parity without
// evidence, this suite tests the one place where the CPU and GPU curve
// evaluations genuinely differ:
//
//   CPU  evaluates a 256-knot Float32 table with linear interpolation.
//   GPU  evaluates a 1025x1 RGBA8 ramp (16-bit R+G packing) with linear
//        interpolation, because GLES2 cannot take a float array.
//
// Everything after the curve is the same formula on both sides, so the packing
// and upsampling is where a real disagreement would show up. The buffer under
// test is the one production code emits (GpuShaderBridge.parametricBuffer),
// read back through a faithful mirror of the GLSL sampleCurve/unpackCurve.
const fs = require('fs'), path = require('path'), vm = require('vm'), crypto = require('crypto'), assert = require('assert');
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
    Uint8Array, Uint16Array, Uint32Array, Int32Array, Uint8ClampedArray, Float32Array, DataView, Promise, Error,
    setTimeout, clearTimeout, TextEncoder, TextDecoder, Buffer, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (n) => {
      if (n === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0) }, GpuOutputGeometry: {} };
      if (n === 'libvivid_ai.so') return { default: { isLoaded: () => false, release: () => {}, modelInfo: () => [] } };
      if (n === '@kit.CoreFileKit') return { fileIo: { openSync: () => { throw new Error('no fs'); } } };
      if (n === '@kit.ArkTS') {
        return {
          util: {
            TextEncoder: class { encode(t) { return new Uint8Array(Buffer.from(t, 'utf8')); } },
            TextDecoder: class { decode(b) { return Buffer.from(b).toString('utf8'); } },
            Base64Helper: class {
              encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
              decodeSync(t) { const b = Buffer.from(t, 'base64'); return new Uint8Array(b.buffer, b.byteOffset, b.byteLength); }
            },
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
      if (n === '@kit.ImageKit') return { image: { PixelMapFormat: { RGBA8888: 3 } } };
      if (n === '@kit.LocalizationKit') return { resourceManager: {} };
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      if(n.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { ColorAdjustments } = load(root + '/edit/models/Adjustment.ets');
const pc = load(root + '/edit/engine/ParametricCurveCore.ets');
const bridge = load(root + '/edit/engine/GpuShaderBridge.ets');
const { applyAdvancedBand } = load(root + '/edit/engine/WorkerCore.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }

// --- faithful mirrors of the GLSL helpers --------------------------------
// unpackCurve(vec4 encoded): (r*65280 + g*255)/65535, with r,g normalised
// bytes. sampleCurve(tex, value): linear interpolation over 1025 texels.
function unpackCurve(r, g) { return (r * 65280 + g * 255) / 65535; }
function texel(buf, index) {
  return [buf[index * 4] / 255, buf[index * 4 + 1] / 255, buf[index * 4 + 2] / 255, buf[index * 4 + 3] / 255];
}
function shaderSampleCurve(buf, value) {
  const p = Math.max(0, Math.min(1, value)) * 1024;
  const lo = Math.floor(p);
  const hi = Math.min(lo + 1, 1024);
  const a = unpackCurve(texel(buf, lo)[0], texel(buf, lo)[1]);
  const b = unpackCurve(texel(buf, hi)[0], texel(buf, hi)[1]);
  return a + (b - a) * (p - lo);
}
// The CPU table lookup, mirrored from WorkerCore.sampleTable.
function cpuSampleTable(table, value) {
  const size = table.length;
  const position = Math.max(0, Math.min(1, value)) * (size - 1);
  const index = Math.floor(position);
  if (index >= size - 1) return table[size - 1];
  return table[index] + (table[index + 1] - table[index]) * (position - index);
}
function rampsAgree(buf, table, tolerance, label) {
  let worst = 0, worstAt = 0;
  for (let i = 0; i <= 4096; i++) {
    const x = i / 4096;
    const difference = Math.abs(shaderSampleCurve(buf, x) - cpuSampleTable(table, x));
    if (difference > worst) { worst = difference; worstAt = x; }
  }
  ok(worst <= tolerance, label + ': worst disagreement ' + worst.toExponential(3) +
    ' at x=' + worstAt.toFixed(4) + ' (tolerance ' + tolerance.toExponential(1) + ')');
  return worst;
}

// --- 1. The buffer production code emits is a 1025x1 RGBA ramp ------------
const active = new ColorAdjustments();
active.parametricHighlights = 0.55;
active.parametricLights = -0.3;
active.parametricDarks = 0.45;
active.parametricShadows = -0.2;
const activeBuffer = new Uint8Array(bridge.GpuShaderBridge.parametricBuffer(active, true));
ok(activeBuffer.length === 1025 * 4, 'the parametric GPU buffer is 1025 texels of RGBA8');
let opaque = true;
for (let i = 0; i < 1025; i++) if (activeBuffer[i * 4 + 3] !== 255) opaque = false;
ok(opaque, 'every texel is fully opaque');

// --- 2. Shader-side evaluation must reproduce the CPU table --------------
const settings = {
  highlights: active.parametricHighlights, lights: active.parametricLights,
  darks: active.parametricDarks, shadows: active.parametricShadows,
  shadowSplit: active.parametricShadowSplit, darkSplit: active.parametricDarkSplit,
  lightSplit: active.parametricLightSplit, refineSaturation: active.parametricRefineSaturation,
};
const cpuTable = pc.buildParametricLut(settings);
ok(cpuTable.length === 256, 'the CPU table under comparison has 256 knots');
// The 1025-knot grid cannot land on the 256-knot grid (255 and 1024 are
// coprime), so the shader reconstructs the CPU table by interpolation and a
// small residual is unavoidable. What matters is that it stays far below the
// 8-bit level the renderer quantises to.
const BYTE_LEVEL = 1 / 255;
let worstAtKnot = 0, worstBetween = 0;
for (let i = 0; i < 256; i++) {
  const x = i / 255;
  const difference = Math.abs(shaderSampleCurve(activeBuffer, x) - cpuTable[i]);
  if (difference > worstAtKnot) worstAtKnot = difference;
}
ok(worstAtKnot <= BYTE_LEVEL * 0.05, 'at every CPU knot the shader ramp reproduces the CPU table to ' +
  (worstAtKnot / BYTE_LEVEL).toFixed(4) + ' of one 8-bit level (worst ' + worstAtKnot.toExponential(3) + ')');
// Between knots the reconstruction error must stay just as small, otherwise the
// error would show as banding wherever the curve bends.
for (let i = 0; i <= 4096; i++) {
  const x = i / 4096;
  const difference = Math.abs(shaderSampleCurve(activeBuffer, x) - cpuSampleTable(cpuTable, x));
  if (difference > worstBetween) worstBetween = difference;
}
ok(worstBetween <= BYTE_LEVEL * 0.05, 'between knots the shader ramp tracks the CPU table to ' +
  (worstBetween / BYTE_LEVEL).toFixed(4) + ' of one 8-bit level (worst ' + worstBetween.toExponential(3) + ')');
ok(worstBetween > 0, 'the residual is genuinely measurable rather than an exactly-zero artefact of the ' +
  'comparison, so the bounds above are not vacuous');

// --- 3. Endpoints and monotonicity survive the packing -------------------
ok(Math.abs(shaderSampleCurve(activeBuffer, 0)) <= 1 / 65535, 'the shader ramp pins black at 0');
ok(Math.abs(shaderSampleCurve(activeBuffer, 1) - 1) <= 1 / 65535, 'the shader ramp pins white at 1');
let monotone = true, previous = -1;
for (let i = 0; i <= 1025 * 4; i++) {
  const value = shaderSampleCurve(activeBuffer, i / (1025 * 4));
  if (value < previous - 1e-9) monotone = false;
  previous = value;
}
ok(monotone, 'the shader ramp is non-decreasing (no inversion from byte carries)');

// --- 4. The disabled buffer is the exact identity ------------------------
const idle = new Uint8Array(bridge.GpuShaderBridge.parametricBuffer(new ColorAdjustments(), false));
let identityWorst = 0;
for (let i = 0; i <= 4096; i++) {
  const x = i / 4096;
  identityWorst = Math.max(identityWorst, Math.abs(shaderSampleCurve(idle, x) - x));
}
ok(identityWorst <= 1 / 65535, 'with the curve disabled the shader ramp is the identity within one ' +
  '16-bit step (worst ' + identityWorst.toExponential(3) + '), so an inactive curve cannot shift pixels');

// --- 5. The two sides must implement the SAME refinement formula ---------
// The GPU recomputes the refinement inline in GLSL, so the formula is written
// twice. A change to one that misses the other would silently desynchronise
// preview from export. Assert the GLSL still carries the same shape as the CPU
// helper, and that the helper is what the CPU renderer actually calls.
const cpp = fs.readFileSync('entry/src/main/cpp/vivid_gpu.cpp', 'utf8');
const pipeline = fs.readFileSync('entry/src/main/cpp/vivid_gpu_pipeline.inc', 'utf8');
// CORRECTION, and the reason this suite's original claim was misleading: the assertions
// below inspect vivid_gpu.cpp, whose single-pass shader does implement the curve -- but that
// is NOT the pipeline this process runs. The resident preview and the readback export both
// go through the multi-pass stack renderer in vivid_gpu_pipeline.inc, and that file contains
// NO parametric code at all. So "the shader implements it" was true of a file the app does
// not use, and the parametric curve was in fact absent from every GPU frame. The bridge now
// declines while the curve is active; the assertions below are kept as a record of the
// single-pass implementation that exists but is unreachable.
ok(!/parametric/i.test(pipeline), 'the running pipeline (vivid_gpu_pipeline.inc) has NO parametric ' +
  'support: that is why GpuShaderBridge must decline rather than render the curve on the GPU');
ok(/parametric/i.test(cpp), 'while the unused single-pass shader in vivid_gpu.cpp does implement it, which is ' +
  'what made the earlier version of this suite look like evidence when it was not');
ok(cpp.includes('uniform float uParametricRefine;'), 'the shader still declares the refinement uniform');
ok(cpp.includes('uniform sampler2D uParametricCurve;'), 'the shader still declares the parametric ramp');
ok(cpp.includes('(satAfter-satBefore)/satAfter'),
  'the shader still scales by (saturationAfter - saturationBefore) / saturationAfter');
ok(cpp.includes('1.0+(uParametricRefine-1.0)'),
  'the shader still interpolates between "no change" and "fully restore" with the refinement slider');
ok(cpp.includes('satAfter>satBefore'),
  'the shader still refuses to act when the curve did not ADD saturation');
ok(cpp.includes('dot(mapped.rgb,vec3(0.2126,0.7152,0.0722))'),
  'the shader still scales chroma about the same luma weights the CPU uses');
for (const weight of ['0.2126', '0.7152', '0.0722']) {
  ok(fs.readFileSync('entry/src/main/ets/edit/engine/WorkerCore.ets', 'utf8').includes(weight),
    'the CPU still uses luma weight ' + weight);
}
// The helper the renderer calls must agree with the mirrored GLSL arithmetic.
function glslRefineScale(satBefore, satAfter, refine) {
  if (!(satAfter > 0.0001) || !(satAfter > satBefore)) return 1;
  return 1 + (refine - 1) * (satAfter - satBefore) / satAfter;
}
let formulaAgrees = true, formulaChecked = 0;
for (let s0 = 0; s0 <= 1.0001; s0 += 0.05) {
  for (let s1 = 0; s1 <= 1.0001; s1 += 0.05) {
    for (const refine of [0, 0.25, 0.5, 0.75, 1]) {
      const a = pc.parametricRefineScale(s0, s1, refine);
      const b = glslRefineScale(s0, s1, refine);
      formulaChecked++;
      if (Math.abs(a - b) > 1e-12) formulaAgrees = false;
    }
  }
}
ok(formulaAgrees, 'the CPU helper and the mirrored GLSL formula agree on all ' + formulaChecked +
  ' sampled (satBefore, satAfter, refine) combinations');

// --- 6. The CPU renderer must actually use the shared helper -------------
// A helper that agrees with the shader but is never called would make this suite
// vacuous, so drive the real renderer and confirm the refinement changes pixels.
function img(w, h, fn) {
  const b = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const v = fn(x, y), i = (y * w + x) * 4;
    b[i] = v[0]; b[i + 1] = v[1]; b[i + 2] = v[2]; b[i + 3] = 255;
  }
  return b;
}
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const refined = ImageProcessor.plainAdjustments(
  Object.assign(new ColorAdjustments(), { parametricDarks: 0.9, parametricRefineSaturation: 0 }));
const unrefined = ImageProcessor.plainAdjustments(
  Object.assign(new ColorAdjustments(), { parametricDarks: 0.9, parametricRefineSaturation: 1 }));
// Sweep rather than hand-pick: the curve is applied per channel, so a colour
// whose channels both sit outside the steep region is untouched by it and shows
// no difference between the refinement settings at all.
const channelSpread = (b) => Math.max(b[0], b[1], b[2]) - Math.min(b[0], b[1], b[2]);
let differing = 0, example = null;
for (let r = 40; r <= 215; r += 5) {
  for (let g = 20; g < r; g += 5) {
    const single = img(1, 1, () => [r, g, g]);
    const outRefined = Uint8ClampedArray.from(single), outUnrefined = Uint8ClampedArray.from(single);
    applyAdvancedBand(outRefined, refined, 0, 4, 1, 1);
    applyAdvancedBand(outUnrefined, unrefined, 0, 4, 1, 1);
    if (channelSpread(outRefined) < channelSpread(outUnrefined)) {
      differing++;
      if (!example) {
        example = { rgb: [r, g, g], spreadAtRefine0: channelSpread(outRefined),
          spreadAtRefine1: channelSpread(outUnrefined) };
      }
    }
  }
}
ok(differing > 0, 'the real renderer applies refinement (a helper that agreed with the shader but was ' +
  'never called would make this suite vacuous): ' + differing + ' sampled colours lose channel spread at ' +
  'refinement 0, e.g. ' + JSON.stringify(example));

console.log('PASS parametric GPU ramp: 16-bit packing round-trip, agreement with the 256-knot CPU table at');
console.log('     and between knots, pinned endpoints, monotonicity, exact identity when disabled, and the');
console.log('     refinement formula matching between the CPU helper and the GLSL.');
console.log('NOTE this validates the GPU-side curve EVALUATION, the 16-bit packing and the shared');
console.log('     refinement formula. It does NOT execute the shader, and the shader it inspects');
console.log('     (vivid_gpu.cpp) is NOT the pipeline the app runs: the multi-pass stack renderer in');
console.log('     vivid_gpu_pipeline.inc has no parametric support at all, which check_shader_parity.cjs');
console.log('     demonstrated with real GLES (up to 14 levels of omission). GpuShaderBridge therefore');
console.log('     declines the GPU while the curve is active, so GPU/CPU parametric parity is NOT claimed;');
console.log('     implementing the stage in vivid_gpu_pipeline.inc is the remaining work.');
console.log(checks + ' checks passed');
