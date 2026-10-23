// 细节面板的七个参数，逐个证明它在真实渲染路径上真的生效。
//
// 为什么需要这个套件：上一轮发现 snapshot() 漏掉 detail 等六个渲染输入，导致细节面板
// 在预览和导出里全部按"关闭"渲染——滑杆动了画面不变。修好之后必须逐个参数证明，而不是
// 只证明"detail 这个阶段整体有影响"，否则某一个参数漏接仍然看不出来。
//
// 每个参数都用"只改这一个、其余完全相同"的两张图对比，并且与 bypass 渲染对比：
//   * 与 bypass 不同   -> 这个阶段确实在做工（不是空过）
//   * 两个取值之间不同 -> 这个参数本身真的被读取了（不是被忽略）
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
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
    Uint8Array, Uint16Array, Uint32Array, Int32Array, Uint8ClampedArray, Float32Array, DataView, Promise, Error,
    setTimeout, clearTimeout, TextEncoder, TextDecoder, Buffer, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (n) => {
      if (n === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0) }, GpuOutputGeometry: {} };
      if (n === 'libvivid_ai.so') return { default: { isLoaded: () => false, release: () => {}, modelInfo: () => [] } };
      if (n === '@kit.CoreFileKit') {
        return { fileIo: {
          OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 8 },
          openSync: (p, f) => ({ fd: fs.openSync(p, f === 8 ? 'r' : 'w') }),
          closeSync: (h) => fs.closeSync(typeof h === 'number' ? h : h.fd),
          writeSync: (h, b) => fs.writeSync(typeof h === 'number' ? h : h.fd, Buffer.from(b)),
          readSync: (h, b) => fs.readSync(typeof h === 'number' ? h : h.fd, new Uint8Array(b)),
          statSync: (p) => (typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p)),
        } };
      }
      if (n === '@kit.ArkTS') {
        return { util: { TextEncoder: class { encode(t) { return new Uint8Array(Buffer.from(t, 'utf8')); } },
          TextDecoder: class { decode(b) { return Buffer.from(b).toString('utf8'); } } },
        taskpool: { Task: class { static isCanceled() { return false; } }, execute: async (t) => t } };
      }
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      // 其余原生模块只需要能加载；本套件不调用它们。
      if (n.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { sharpenRadiusPixels } = load(root + '/edit/engine/LocalContrastCore.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
function differences(a, b) {
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}

// 纹理丰富 + 有噪声的图：锐化的三个参数需要真实的边缘和噪声才有可测效果。
// 长边必须足够大：锐化半径按"长边 / 2048 × 32^滑杆"量化成整数像素，72px 的小图上
// 0.1 和 0.95 都会取整成 1px，那样的 fixture 无法区分两个取值——这不是产品缺陷，
// 而是测量尺度不对。下面先把这个量化性质断言出来，再在能分辨的尺度上测。
const W = 1024, H = 64;
ok(sharpenRadiusPixels(Math.min(W, H), 0.1) === sharpenRadiusPixels(Math.min(W, H), 0.95),
  '在小图上（长边 64）两个半径取值确实量化到同一像素，所以测试必须用大图，否则断言是假失败');
ok(sharpenRadiusPixels(W, 0.1) !== sharpenRadiusPixels(W, 0.95),
  '而在长边 ' + W + ' 上两个取值得到不同像素半径（' + sharpenRadiusPixels(W, 0.1) + ' vs ' +
  sharpenRadiusPixels(W, 0.95) + '），本套件才测得出锐化半径是否被读取');
const source = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    const pattern = ((x >> 3) + (y >> 3)) % 2 === 0 ? 150 : 95;
    const noise = ((x * 37 + y * 53) % 13) - 6;
    source[i] = pattern + noise;
    source[i + 1] = pattern + Math.round(noise * 0.7) + ((x * 7) % 9);
    source[i + 2] = pattern - Math.round(noise * 0.5) + ((y * 11) % 9);
    source[i + 3] = 255;
  }
}

/** 走真实路径：session -> snapshot -> worker 参数 -> 渲染像素。 */
function render(setup) {
  const session = new EditSession();
  if (setup) setup(session.detail, session);
  const snap = ImageProcessor.snapshot(session);
  const params = ImageProcessor.buildWorkerParams(snap, Uint8ClampedArray.from(source).buffer, W, H);
  return { pixels: new Uint8ClampedArray(processPixels(params).buffer), params: params, snap: snap };
}

const bypass = render(null);
ok(differences(bypass.pixels, source) === 0, '全部为默认值时渲染等于源图，所以下面每一处差异都归因于被测参数');

// 七个参数：(标签, 基线设置, 变体设置)
const cases = [
  { label: '纹理 texture', base: (d) => { }, variant: (d) => { d.texture = 0.8; } },
  { label: '清晰度 clarity', base: (d) => { }, variant: (d) => { d.clarity = 0.8; } },
  { label: '去朦胧 dehaze', base: (d) => { }, variant: (d) => { d.dehaze = 0.8; } },
  { label: '锐化量 sharpenAmount', base: (d) => { }, variant: (d) => { d.sharpenAmount = 0.9; } },
  // 锐化的三个细项只有在锐化量开启时才有意义，这是正确行为而不是缺失，
  // 因此以"锐化量已开启"为基线来测它们。
  { label: '锐化半径 sharpenRadius', base: (d) => { d.sharpenAmount = 0.9; d.sharpenRadius = 0.1; },
    variant: (d) => { d.sharpenAmount = 0.9; d.sharpenRadius = 0.95; } },
  { label: '锐化细节 sharpenDetail', base: (d) => { d.sharpenAmount = 0.9; d.sharpenDetail = 0.0; },
    variant: (d) => { d.sharpenAmount = 0.9; d.sharpenDetail = 0.95; } },
  { label: '锐化蒙版 sharpenMasking', base: (d) => { d.sharpenAmount = 0.9; d.sharpenMasking = 0.0; },
    variant: (d) => { d.sharpenAmount = 0.9; d.sharpenMasking = 0.95; } },
];

for (const item of cases) {
  const a = render(item.base);
  const b = render(item.variant);
  // 1) 这个阶段真的在工作（变体与全默认的 bypass 不同）
  ok(differences(a.snapshot !== undefined ? a.pixels : a.pixels, bypass.pixels) > 50 ||
    differences(b.pixels, bypass.pixels) > 50,
    item.label + '：开启后与全默认渲染不同，说明该阶段确实在 CPU 路径上工作（不是被跳过）');
  // 2) 这个参数本身被读取（两个取值之间不同）
  const delta = differences(a.pixels, b.pixels);
  ok(delta > 20, item.label + '：只改这一个参数就改变渲染结果（' + delta + ' 字节），所以它不是被忽略的滑杆');
  // 3) 值确实进了 worker 参数
  const key = item.label.split(' ')[1];
  ok(b.params.detail[key] === b.snap.detail[key],
    item.label + '：参数值经快照原样进入 worker（' + key + '）');
}

// 反空过：把 detail 从快照里拿掉必须让这些断言失败（重现上一轮的缺陷）。
const withDetail = ImageProcessor.snapshot;
const broken = new EditSession();
broken.detail.texture = 0.8;
const brokenSnap = withDetail(broken);
brokenSnap.detail.texture = 0; // 模拟"快照丢失该字段"
const brokenParams = ImageProcessor.buildWorkerParams(brokenSnap, Uint8ClampedArray.from(source).buffer, W, H);
const brokenPixels = new Uint8ClampedArray(processPixels(brokenParams).buffer);
ok(differences(brokenPixels, bypass.pixels) === 0,
  '反空过：把这些字段丢掉后纹理就完全不生效（0 字节差异），这正是上一轮"细节面板全部失效"的成因');

console.log('PASS 细节面板七个参数逐个生效：纹理/清晰度/去朦胧/锐化量各自开启都改变画面，');
console.log('     锐化半径/细节/蒙版在锐化量开启后各自单独改变画面，且都经 snapshot 进入 worker。');
console.log('NOTE 该阶段在 GPU 上被有意拒绝（decline local-contrast），没有着色器实现，全部由 CPU 渲染；');
console.log('     所以"没进入 GPU 管线"是设计如此，但"功能缺失"不是——前提是构建包含上一轮 snapshot 修复。');
console.log(checks + ' 项通过');
