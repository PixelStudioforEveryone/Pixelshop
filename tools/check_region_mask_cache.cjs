// 区域（放大瓦片）蒙版 alpha 缓存：
//   1. 同一会话连续请求 3 个不同瓦片，整帧蒙版只栅格化一次；
//   2. 每块瓦片的 alpha 与"整帧栅格化后按源矩形裁切"逐字节一致；
//   3. 带蒙版的瓦片渲染与整帧渲染后裁切一致（≤1，沿用现有对拍口径）；
//   4. 证伪：退回"每块瓦片各自栅格化"时计数变成 3，上面第 1 条必然失败；
//      修改 mask revision 后缓存失效、重新栅格化。
//
// 本套件不依赖模拟器；native cropScaleAlpha 在 Node 下不可用，因此同时验证
// ArkTS 回退实现。生产设备上走 libvivid_pixels 的同公式 C++ 版本。
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
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer, Error,
    Uint8Array, Uint16Array, Uint32Array, Int32Array, Float32Array, Float64Array, Uint8ClampedArray,
    Promise, setTimeout, clearTimeout, TextEncoder, TextDecoder, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (n) => {
      if (n === 'libvivid_composite.so') return { default: {} };
      if (n.endsWith('.so')) return { default: {} };
      if (n === '@kit.ArkTS') {
        return { taskpool: {
          Task: class { static isCanceled() { return false; } constructor(fn, ...args) { this.fn = fn; this.args = args; } },
          execute: async (task) => task.fn(...task.args),
        }, util: {} };
      }
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { MaskComponentType } = load(root + '/edit/models/Mask.ets');
const { MaskRenderer } = load(root + '/edit/engine/MaskRenderer.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }

async function main() {
  const W = 160, H = 120;
  const source = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      source[i] = (x * 3 + y * 5) & 255;
      source[i + 1] = (x * 7 + 40) & 255;
      source[i + 2] = (y * 11 + 80) & 255;
      source[i + 3] = 255;
    }
  }

  const session = new EditSession();
  session.ensureBaseLayer();
  const mask = session.createMaskLayer(MaskComponentType.LINEAR_GRADIENT);
  ok(!!mask && mask.components.length === 1, '线性渐变蒙版创建成功');
  const line = mask.components[0].linearGradientData;
  line.startX = 0.05; line.startY = 0.1; line.endX = 0.95; line.endY = 0.9;
  mask.components[0].feather = 0.45;
  // 没有局部调整的蒙版不产生像素；这里加曝光让它进入真实管线。
  mask.adjustments.setValue('exposure', 0.35);

  function fullAlpha() {
    return MaskRenderer.renderMaskLayer(mask, W, H);
  }

  function renderFull() {
    const snap = ImageProcessor.snapshot(session);
    const params = ImageProcessor.buildWorkerParams(snap, source.buffer.slice(0), W, H);
    return new Uint8ClampedArray(processPixels(params).buffer);
  }

  function cropSource(x, y, w, h) {
    const out = new Uint8ClampedArray(w * h * 4);
    for (let row = 0; row < h; row++) {
      out.set(source.subarray(((y + row) * W + x) * 4, ((y + row) * W + x + w) * 4), row * w * 4);
    }
    return out;
  }

  const whole = fullAlpha();
  const fullPixels = renderFull();
  // 整帧参考渲染本身会栅格化一次蒙版；计数从区域请求开始算。
  ImageProcessor.resetMaskRasterCount();

  const rects = [[12, 10, 70, 52], [80, 40, 64, 60], [45, 66, 90, 44]];

  async function runCachedTiles() {
    const alphas = [];
    const pixels = [];
    for (const [x, y, w, h] of rects) {
      const target = ImageProcessor.regionSnapshot(session, x, y, w, h, W, H, w, h);
      const prepared = await ImageProcessor.prepareRegionMasks(session, target, 'fixture-source',
        W, H, x, y, w, h, w, h);
      ok(prepared === 1, '每块瓦片都从整帧缓存得到 1 个蒙版 alpha');
      const alpha = target.maskCache.get(
        `${session.layers[0].id}:${mask.id}:${target.maskRevision}:${w}x${h}`);
      ok(!!alpha && alpha.length === w * h, '瓦片蒙版 alpha 已写入目标快照的 maskCache');
      alphas.push({ x, y, w, h, alpha });
      const params = ImageProcessor.buildWorkerParams(target, cropSource(x, y, w, h).buffer, w, h);
      pixels.push({ x, y, w, h, data: new Uint8ClampedArray(processPixels(params).buffer) });
    }
    return { alphas, pixels };
  }

  const cached = await runCachedTiles();
  ok(ImageProcessor.maskRasterCount() === 1,
    '同一会话连续 3 个不同瓦片，蒙版只栅格化一次（实际 ' + ImageProcessor.maskRasterCount() + '）');

  // 逐字节对拍：整帧 alpha 按瓦片源矩形裁切 == 瓦片 alpha。
  let alphaWorst = 0;
  for (const tile of cached.alphas) {
    for (let row = 0; row < tile.h; row++) {
      for (let col = 0; col < tile.w; col++) {
        const expected = whole[(tile.y + row) * W + tile.x + col];
        const actual = tile.alpha[row * tile.w + col];
        if (actual !== expected) alphaWorst = Math.max(alphaWorst, Math.abs(actual - expected));
      }
    }
  }
  ok(alphaWorst === 0, '瓦片 alpha == 整帧 alpha 裁切，逐字节一致（最大差 ' + alphaWorst + '）');

  // 管线对拍：瓦片渲染 == 整帧渲染后裁切（≤1，与现有 region parity 口径一致）。
  let pixelWorst = 0;
  for (const tile of cached.pixels) {
    for (let row = 0; row < tile.h; row++) {
      for (let col = 0; col < tile.w * 4; col++) {
        const expected = fullPixels[((tile.y + row) * W + tile.x) * 4 + col];
        const actual = tile.data[row * tile.w * 4 + col];
        pixelWorst = Math.max(pixelWorst, Math.abs(actual - expected));
      }
    }
  }
  ok(pixelWorst <= 1, '带蒙版的瓦片渲染 == 整帧渲染后裁切（最大差 ' + pixelWorst + '）');

  // 缓存失效：revision 改变后必须重新栅格化。
  ImageProcessor.resetMaskRasterCount();
  session.invalidateMaskCache();
  line.startX = 0.25;
  const staleTarget = ImageProcessor.regionSnapshot(session, rects[0][0], rects[0][1],
    rects[0][2], rects[0][3], W, H, rects[0][2], rects[0][3]);
  await ImageProcessor.prepareRegionMasks(session, staleTarget, 'fixture-source',
    W, H, rects[0][0], rects[0][1], rects[0][2], rects[0][3], rects[0][2], rects[0][3]);
  ok(ImageProcessor.maskRasterCount() === 1,
    'mask revision 改变后整帧缓存失效并重新栅格化一次');

  // 证伪：退回"每块瓦片各自栅格化"（regionSnapshot 会清空 maskCache）。
  ImageProcessor.resetMaskRasterCount();
  for (const [x, y, w, h] of rects) {
    const legacy = ImageProcessor.regionSnapshot(session, x, y, w, h, W, H, w, h);
    await ImageProcessor.prepareMasks(legacy, w, h);
  }
  const legacyCount = ImageProcessor.maskRasterCount();
  ok(legacyCount === 3, '旧路径每块瓦片各栅格化一次（3 块 → ' + legacyCount + '）');
  ok(legacyCount !== 1,
    '证伪成立：把实现改回每块瓦片重算后，"只栅格化一次"的断言会失败');

  console.log('PASS 区域蒙版：整帧栅格化一次 + 瓦片裁切/缩放；alpha 逐字节一致，');
  console.log('     管线与整帧渲染后裁切 ≤1；revision 失效与"改回重算"证伪均通过。');
  console.log(checks + ' 项通过');
}

main().catch((error) => { console.error(error); process.exit(1); });
