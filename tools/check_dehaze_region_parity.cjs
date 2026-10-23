// 放大瓦片与整帧的去朦胧必须一致（对齐 lightcraft 的整帧 airlight 传递）。
//
// 去朦胧的雾色是整帧统计量：瓦片只看得见自己那一块，自算雾色会与整帧不同，放大后
// 效果对不上。lightcraft 在 `RenderRequest::window` 里把整帧 airlight 带进窗口渲染；
// VIVID 现在由 EditorPage 在请求瓦片时算一次，存进 session.detailHaze，经快照带进
// 瓦片渲染（ProcessParams.detailHaze）。
//
// 本套件证明三件事：
//   1. dehazeHazeColor 能从一帧估出雾色；
//   2. 带雾色的瓦片渲染 == 整帧渲染后裁切（逐像素）；
//   3. 不带雾色的瓦片渲染确实不同（否则上面的相等是空过）。
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
    Uint8Array, Uint16Array, Uint32Array, Int32Array, Uint8ClampedArray, Float32Array, DataView,
    Promise, setTimeout, clearTimeout, TextEncoder, TextDecoder, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (n) => {
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
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { dehazeHazeColor } = load(root + '/edit/engine/LocalContrastCore.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }

// 一幅有雾的画面：上部是明亮的雾霾，下部有一个暗物体。
const W = 200, H = 140;
const source = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    const haze = 210 - Math.round(y * 0.25);
    const dark = x > 60 && x < 110 && y > 70 && y < 110;
    const value = dark ? 40 : haze;
    source[i] = value; source[i + 1] = value; source[i + 2] = Math.min(255, value + 6); source[i + 3] = 255;
  }
}

function render(session, pixels, w, h) {
  const snap = ImageProcessor.snapshot(session);
  const params = ImageProcessor.buildWorkerParams(snap, pixels.buffer.slice(0), w, h);
  return { pixels: new Uint8ClampedArray(processPixels(params).buffer), params: params };
}

const session = new EditSession();
session.detail.dehaze = 0.8;

const haze = dehazeHazeColor(source, W, H);
ok(haze.length === 3, 'dehazeHazeColor 从整帧估出三元雾色');
ok(haze[0] > 0.5 && haze[1] > 0.5 && haze[2] > 0.5, '雾色落在明亮端（' + haze.map((v) => v.toFixed(3)).join(',') + '）');

// 整帧渲染：不带缓存的雾色，由管线自己就地估计。
session.detailHaze = [];
const fullOwn = render(session, source, W, H);
ok(fullOwn.params.detailHaze.length === 0, '未提供整帧雾色时参数里为空，管线就地估计');

// 整帧渲染，带缓存雾色：这是瓦片要复用的那一份。
session.detailHaze = haze;
const fullCached = render(session, source, W, H);
ok(fullCached.params.detailHaze.length === 3, '快照把整帧雾色带进了 worker 参数');
ok(JSON.stringify(Array.from(fullCached.params.detailHaze)) === JSON.stringify(Array.from(session.detailHaze)),
  '带过去的雾色与整帧估计一致');

// 两个整帧渲染必须一致，否则"缓存雾色"本身改变了画面。
let worst = 0;
for (let i = 0; i < fullOwn.pixels.length; i++) {
  worst = Math.max(worst, Math.abs(fullOwn.pixels[i] - fullCached.pixels[i]));
}
ok(worst <= 1, '用缓存雾色与就地估计渲染同一整帧，结果一致（最大差 ' + worst + '）');

// 瓦片：通过 regionSnapshot 走真实路径，快照会自动带上 detailHaze。
const x = 50, y = 40, rw = 90, rh = 70;
const tileSource = new Uint8ClampedArray(rw * rh * 4);
for (let row = 0; row < rh; row++) {
  tileSource.set(source.subarray(((y + row) * W + x) * 4, ((y + row) * W + x + rw) * 4), row * rw * 4);
}
const region = ImageProcessor.regionSnapshot(session, x, y, rw, rh, W, H, rw, rh);
ok(region.detailHaze.length === 3, 'regionSnapshot 把整帧雾色带进瓦片会话');
const tile = render(region, tileSource, rw, rh);

let parity = 0;
for (let row = 0; row < rh; row++) {
  for (let col = 0; col < rw * 4; col++) {
    parity = Math.max(parity, Math.abs(tile.pixels[row * rw * 4 + col] -
      fullCached.pixels[((y + row) * W + x) * 4 + col]));
  }
}
ok(parity <= 1, '带整帧雾色的瓦片 == 整帧渲染后裁切（最大差 ' + parity + '）');

// 反空过：不带宽片雾色时，瓦片必须与整帧不同，否则上面那条相等没有意义。
const regionOwn = ImageProcessor.regionSnapshot(session, x, y, rw, rh, W, H, rw, rh);
regionOwn.detailHaze = [];
const tileOwn = render(regionOwn, tileSource, rw, rh);
let divergence = 0;
for (let i = 0; i < tile.pixels.length; i++) divergence = Math.max(divergence, Math.abs(tile.pixels[i] - tileOwn.pixels[i]));
ok(divergence > 1,
  '瓦片自算雾色与整帧雾色确实不同（最大差 ' + divergence + '），所以上面的一致是这条链路带来的，不是巧合');

console.log('PASS 去朦胧：整帧雾色经 session.detailHaze → 快照 → ProcessParams.detailHaze 进入瓦片渲染，');
console.log('     瓦片与整帧渲染逐像素一致（≤1），不带宽帧雾色时两者确实不同（' + divergence + '）。');
console.log(checks + ' 项通过');
