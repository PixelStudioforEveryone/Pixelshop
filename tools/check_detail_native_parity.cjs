// 细节阶段 native 与 ArkTS 的逐字节对拍 + 性能对比。
//
// 背景：`LocalContrastCore.applyLocalContrast` 在真机 512x341 上要 725ms，而同样
// 的字节在 Node 上只要 20-47ms——慢的是 ArkTS 解释执行，不是算术。于是把整条管线
// 搬进 native（entry/src/main/cpp/vivid_detail_core.cpp）。两条路都会在真机上跑
// （native 不可用时回退 ArkTS），所以必须逐字节相同。
//
// 本套件编译**同一份** C++ 源（同一组 -O2/-ffp-contract=off）成一个宿主探针，喂
// 同一份 fixture，再把输出与转译后的 ArkTS 参考实现逐字节比较。断言 maxCh === 0：
// 任何一位不同都红。这不是"读代码相信公式"，而是实测两条实现的输出。
//
// 依赖宿主 C++ 工具链（WSL 里的 g++）。缺少时打印 SKIP 并以 0 退出——那台机器上
// 这条证据不存在，报告里必须如实写明，而不是假装通过。
//
// 证伪：同一探针支持 --falsify=1，把绿通道整体 +1；套件必须报告 maxCh>0，且差异
// 全部落在绿通道上。也就是说"native 结果写错一个通道"确实会让本套件失败。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const os = require('os');
const cp = require('child_process');
const assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const root = path.resolve('entry/src/main/ets');
const cppDir = path.resolve('entry/src/main/cpp');
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
    require: (n) => {
      // libvivid_detail.so 一定不可用：本套件的参考实现就是 ArkTS 那条路。
      if (n.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const C = load(root + '/edit/engine/LocalContrastCore.ets');
const D = load(root + '/edit/engine/NativeDetail.ets');

const DISTRO = process.env.VIVID_WSL_DISTRO || 'Ubuntu-22.04';
const probeDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vivid-detail-parity-'));
const probeBinary = '/tmp/vivid_detail_probe_' + process.pid;

function toWslPath(winPath) {
  const normalized = path.resolve(winPath).replace(/\\/g, '/');
  const drive = normalized[0].toLowerCase();
  return `/mnt/${drive}${normalized.slice(2)}`;
}

function wsl(command, options) {
  return cp.spawnSync('wsl', ['-d', DISTRO, '--', 'bash', '-lc', command],
    Object.assign({ encoding: 'utf8' }, options || {}));
}

let checks = 0;
function ok(condition, message) {
  checks++;
  assert(condition, message);
}

// --- host toolchain --------------------------------------------------------
const version = wsl('g++ --version >/dev/null 2>&1 && echo gxx-ok || echo gxx-missing');
if (version.status !== 0 || !String(version.stdout).includes('gxx-ok')) {
  console.log('SKIP check_detail_native_parity: no host C++ toolchain (g++ in WSL).');
  console.log('     This machine cannot compile the probe, so native/ArkTS parity was NOT verified here.');
  process.exit(0);
}

// -fopenmp makes the host probe take the real parallel branches; the parity
// assertion still requires maxCh=0, so a race or changed summation order fails.
const compile = wsl(`g++ -O2 -ffp-contract=off -std=c++17 -fopenmp -I ${toWslPath(cppDir)} ` +
  `${toWslPath(path.join('tools', 'native_detail_probe.cpp'))} ` +
  `${toWslPath(path.join(cppDir, 'vivid_detail_core.cpp'))} -o ${probeBinary}`);
if (compile.status !== 0) {
  console.error(compile.stdout || '');
  console.error(compile.stderr || '');
}
ok(compile.status === 0, 'host probe must compile with the same flags as the device library');

// --- fixtures --------------------------------------------------------------
function makeImage(width, height, seed) {
  const buffer = new Uint8ClampedArray(width * height * 4);
  let state = seed >>> 0;
  const random = () => {
    state = (state + 0x6D2B79F5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const index = (y * width + x) * 4;
      const u = x / (width - 1);
      const v = y / (height - 1);
      // A sky-to-ground gradient, a bright patch (a plausible airlight), two
      // hard-edged blocks, a fine sinusoidal texture and sensor-like noise.
      let r = 40 + 150 * u + 35 * v;
      let g = 55 + 120 * u + 30 * v;
      let b = 80 + 90 * u + 20 * v;
      const bright = Math.max(0, 1 - Math.hypot(u - 0.72, v - 0.28) * 5);
      r += 80 * bright; g += 80 * bright; b += 80 * bright;
      if (x > width * 0.18 && x < width * 0.34 && y > height * 0.55 && y < height * 0.8) { r = 28; g = 30; b = 24; }
      if (x > width * 0.6 && x < width * 0.78 && y > height * 0.6 && y < height * 0.72) { r = 210; g = 200; b = 180; }
      const fine = 18 * Math.sin(x * 0.9) * Math.cos(y * 0.7);
      const noise = (random() - 0.5) * 9;
      buffer[index] = r + fine + noise;
      buffer[index + 1] = g + fine * 0.8 + noise;
      buffer[index + 2] = b + fine * 0.6 + noise;
      // Alpha variation matters: the dehaze stage skips fully transparent
      // pixels and weights its airlight estimate by alpha.
      buffer[index + 3] = (y % 37 === 0) ? 0 : ((x % 53 === 0) ? 128 : 255);
    }
  }
  return buffer;
}

function paramsOf(overrides) {
  const p = C.localContrastDefaults();
  Object.keys(overrides).forEach((key) => { p[key] = overrides[key]; });
  return p;
}

const W512 = 512, H512 = 341, W2048 = 2048, H2048 = 1365;

const caseList = [
  { name: 'clarity0.5', overrides: { clarity: 0.5 } },
  { name: 'clarity1.0', overrides: { clarity: 1.0 } },
  { name: 'texture0.5', overrides: { texture: 0.5 } },
  { name: 'texture-0.5', overrides: { texture: -0.5 } },
  { name: 'texture+clarity', overrides: { texture: 0.5, clarity: 0.5 } },
  { name: 'texture+clarity-max', overrides: { texture: 1.0, clarity: -1.0 } },
  { name: 'dehaze+0.5', overrides: { dehaze: 0.5 } },
  { name: 'dehaze-0.5', overrides: { dehaze: -0.5 } },
  { name: 'dehaze+0.5+haze', overrides: { dehaze: 0.5 }, externalHaze: true },
  { name: 'dehaze-0.5+haze', overrides: { dehaze: -0.5 }, externalHaze: true },
  { name: 'sharpen', overrides: { sharpenAmount: 0.8, sharpenRadius: 0.5, sharpenDetail: 0.25, sharpenMasking: 0 } },
  { name: 'sharpen-masking', overrides: { sharpenAmount: 1.0, sharpenRadius: 0.2, sharpenDetail: 0.6, sharpenMasking: 0.5 } },
  { name: 'sharpen-wide', overrides: { sharpenAmount: 0.6, sharpenRadius: 1.0, sharpenDetail: 0, sharpenMasking: 0.8 } },
  { name: 'all-detail', overrides: { texture: 0.6, clarity: 0.7, dehaze: 0.4, sharpenAmount: 0.7, sharpenRadius: 0.6, sharpenDetail: 0.4, sharpenMasking: 0.3 } },
  { name: 'identity', overrides: {} },
  { name: 'haze-white-earlyout', overrides: { dehaze: 0.6 }, externalHaze: 'white' },
];

function clampMagnitude(input, limit) {
  if (!Number.isFinite(input)) return 0;
  return Math.max(-limit, Math.min(limit, input));
}

/** Exactly the request LocalContrastCore hands the native module. */
function requestFor(params, longEdge, haze) {
  const dehaze = clampMagnitude(params.dehaze, 1);
  return {
    radiusTexture: C.textureRadius(longEdge),
    radiusClarity: C.clarityRadius(longEdge),
    radiusSharpen: C.sharpenRadiusPixels(longEdge, params.sharpenRadius),
    texture: params.texture,
    clarity: params.clarity,
    dehaze: params.dehaze,
    veil: 0.3 * Math.pow(Math.abs(dehaze), 1.3),
    sharpenAmount: params.sharpenAmount,
    sharpenDetail: params.sharpenDetail,
    sharpenMasking: params.sharpenMasking,
    hasHaze: haze.length === 3,
    hazeRed: haze.length === 3 ? haze[0] : 1,
    hazeGreen: haze.length === 3 ? haze[1] : 1,
    hazeBlue: haze.length === 3 ? haze[2] : 1,
  };
}

function runProbe(image, width, height, request, options) {
  const tag = `p${process.pid}_${runProbe.counter++}`;
  const inputPath = path.join(probeDir, `${tag}.rgb`);
  const outputPath = path.join(probeDir, `${tag}.out`);
  fs.writeFileSync(inputPath, Buffer.from(image.buffer, image.byteOffset, image.byteLength));
  const args = ['detail', toWslPath(inputPath), toWslPath(outputPath), width, height,
    request.radiusTexture, request.radiusClarity, request.radiusSharpen,
    request.texture, request.clarity, request.dehaze, request.veil,
    request.sharpenAmount, request.sharpenDetail, request.sharpenMasking,
    request.hasHaze ? 1 : 0, request.hazeRed, request.hazeGreen, request.hazeBlue];
  if (options && options.repeat) args.push(`--repeat=${options.repeat}`);
  if (options && options.falsify !== undefined) args.push(`--falsify=${options.falsify}`);
  const run = wsl([probeBinary].concat(args).join(' '));
  ok(run.status === 0, `probe must succeed for ${tag}: ${run.stderr || ''}`);
  const output = fs.readFileSync(outputPath);
  const millis = /ms=([0-9.]+)/.exec(String(run.stdout));
  return { bytes: new Uint8ClampedArray(output.buffer, output.byteOffset, output.byteLength),
    millis: millis ? Number(millis[1]) : NaN };
}
runProbe.counter = 0;

/** Compare two RGBA buffers; returns maxCh, over2 and the per-channel maxima. */
function compare(reference, candidate) {
  const length = Math.min(reference.length, candidate.length);
  let maxCh = 0, over2 = 0;
  const channelMax = [0, 0, 0, 0];
  const channelOver2 = [0, 0, 0, 0];
  for (let index = 0; index < length; index++) {
    const delta = Math.abs(reference[index] - candidate[index]);
    const channel = index & 3;
    if (delta > channelMax[channel]) channelMax[channel] = delta;
    if (delta > 2) { over2++; channelOver2[channel]++; }
    if (delta > maxCh) maxCh = delta;
  }
  return { maxCh, over2, channelMax, channelOver2, lengthDiffers: reference.length !== candidate.length };
}

function runCase(width, height, image, spec) {
  const longEdge = Math.max(width, height);
  const params = paramsOf(spec.overrides);
  let haze = [];
  if (spec.externalHaze === 'white') haze = [1, 1, 1];
  else if (spec.externalHaze) haze = C.dehazeHazeColor(image, width, height);
  const request = requestFor(params, longEdge, haze);
  const reference = C.applyLocalContrast(image, width, height, params, longEdge, haze);
  const native = runProbe(image, width, height, request).bytes;
  const diff = compare(reference, native);
  return { params, haze, request, reference, native, diff };
}

function label(width, height) {
  return `${width}x${height}`;
}

// --- 512x341: the interactive preview size, full matrix ---------------------
const image512 = makeImage(W512, H512, 0x5eed1234);
const rows = [];
for (const spec of caseList) {
  const result = runCase(W512, H512, image512, spec);
  const { diff } = result;
  rows.push({ size: label(W512, H512), name: spec.name, maxCh: diff.maxCh, over2: diff.over2, channelMax: diff.channelMax });
  ok(!diff.lengthDiffers, `${spec.name} @512 must produce the same byte count`);
  ok(diff.maxCh === 0 && diff.over2 === 0,
    `${spec.name} @512 must be byte-identical, got maxCh=${diff.maxCh} over2=${diff.over2} channels=${diff.channelMax}`);
}

// --- 2048 long edge: the export-sized frame, same matrix -------------------
const image2048 = makeImage(W2048, H2048, 0xc0ffee);
for (const spec of caseList) {
  const result = runCase(W2048, H2048, image2048, spec);
  const { diff } = result;
  rows.push({ size: label(W2048, H2048), name: spec.name, maxCh: diff.maxCh, over2: diff.over2, channelMax: diff.channelMax });
  ok(!diff.lengthDiffers, `${spec.name} @2048 must produce the same byte count`);
  ok(diff.maxCh === 0 && diff.over2 === 0,
    `${spec.name} @2048 must be byte-identical, got maxCh=${diff.maxCh} over2=${diff.over2} channels=${diff.channelMax}`);
}

// --- dehaze haze-colour estimate: exact doubles, not bytes -----------------
for (const [width, height, image] of [[W512, H512, image512], [W2048, H2048, image2048]]) {
  const rTag = `haze${process.pid}`;
  const inputPath = path.join(probeDir, `${rTag}_${width}.rgb`);
  fs.writeFileSync(inputPath, Buffer.from(image.buffer, image.byteOffset, image.byteLength));
  const run = wsl([probeBinary, 'haze', toWslPath(inputPath), width, height].join(' '));
  ok(run.status === 0, 'haze probe must succeed');
  const reference = C.dehazeHazeColor(image, width, height);
  const text = String(run.stdout).trim();
  ok(reference.length === 3, `haze estimate @${width} must exist`);
  const native = text.split(/\s+/).map(Number);
  ok(native.length === 3 && native[0] === reference[0] && native[1] === reference[1] &&
    native[2] === reference[2],
    `haze estimate @${width} must match exactly: native=${text} arkts=${reference.map((v) => v.toFixed(17)).join(' ')}`);
}

// --- falsification: one wrong channel must fail this comparison ------------
{
  const spec = caseList.find((entry) => entry.name === 'all-detail');
  const result = runCase(W512, H512, image512, spec);
  const falsified = runProbe(image512, W512, H512, result.request, { falsify: 1 }).bytes;
  const diff = compare(result.reference, falsified);
  let differing = 0;
  for (let index = 0; index < result.reference.length; index++) {
    if (result.reference[index] !== falsified[index]) differing++;
  }
  ok(diff.maxCh > 0, 'falsified green channel must be detected');
  ok(diff.channelMax[0] === 0 && diff.channelMax[2] === 0 && diff.channelMax[3] === 0,
    'only the falsified channel may differ');
  // A +1 in the green channel has to be visible on essentially the whole frame
  // (only saturated pixels cannot move), so a check that still passes here
  // would be blind to a wrong channel rather than merely tolerant of rounding.
  ok(differing > 1000, `the falsified channel must be reported as wrong, only ${differing} bytes differed`);
  ok(diff.channelMax[1] >= 1, 'the wrong channel must be flagged');
  // And the un-falsified run of the same case is still clean, so the check is
  // not simply "always red".
  ok(result.diff.maxCh === 0, 'the un-falsified run stays byte-identical');
}

// --- dispatch/fallback wiring ---------------------------------------------
{
  ok(D.nativeDetailReady() === false, 'with the stub module, native must report itself unavailable');
  const params = paramsOf({ clarity: 0.5 });
  const output = C.applyLocalContrast(image512, W512, H512, params, W512);
  ok(output.length === W512 * H512 * 4, 'fallback must still produce a full frame');
  const again = C.applyLocalContrast(image512, W512, H512, params, W512);
  ok(output[0] === again[0] && output[12345] === again[12345], 'fallback path must be deterministic');
  ok(output[0] !== image512[0] || output[400] !== image512[400], 'a clarity pass must change the pixels');
}

// --- performance ----------------------------------------------------------
const perfParams = paramsOf(caseList.find((entry) => entry.name === 'all-detail').overrides);
const perfHaze = [];
const perfRequest = requestFor(perfParams, W512, perfHaze);
const nativePerf = runProbe(image512, W512, H512, perfRequest, { repeat: 20 }).millis;
const arktsStart = process.hrtime.bigint();
const ARKTS_RUNS = 3;
for (let run = 0; run < ARKTS_RUNS; run++) C.applyLocalContrast(image512, W512, H512, perfParams, W512);
const arktsMillis = Number(process.hrtime.bigint() - arktsStart) / 1e6 / ARKTS_RUNS;
const bigRequest = requestFor(perfParams, W2048, []);
const nativePerf2048 = runProbe(image2048, W2048, H2048, bigRequest, { repeat: 5 }).millis;
const arktsStart2048 = process.hrtime.bigint();
C.applyLocalContrast(image2048, W2048, H2048, perfParams, W2048);
const arktsMillis2048 = Number(process.hrtime.bigint() - arktsStart2048) / 1e6;

// --- report ---------------------------------------------------------------
const header = 'size      case                  maxCh over2  ch0 ch1 ch2 ch3';
console.log(header);
console.log('-'.repeat(header.length));
for (const row of rows) {
  console.log(`${row.size.padEnd(9)} ${row.name.padEnd(21)} ${String(row.maxCh).padStart(5)} ${String(row.over2).padStart(5)}` +
    `  ${row.channelMax.map((v) => String(v).padStart(3)).join(' ')}`);
}
console.log('');
console.log(`renderer timing (all-detail, ${ARKTS_RUNS} ArkTS runs, 20/5 native runs):`);
console.log(`  512x341   arkts=${arktsMillis.toFixed(1)}ms  native=${nativePerf.toFixed(1)}ms  speedup=${(arktsMillis / nativePerf).toFixed(1)}x`);
console.log(`  2048x1365 arkts=${arktsMillis2048.toFixed(1)}ms  native=${nativePerf2048.toFixed(1)}ms  speedup=${(arktsMillis2048 / nativePerf2048).toFixed(1)}x`);
console.log('');
console.log(`check_detail_native_parity: ${checks} checks, ${rows.length} byte comparisons, all maxCh=0`);

fs.rmSync(probeDir, { recursive: true, force: true });
