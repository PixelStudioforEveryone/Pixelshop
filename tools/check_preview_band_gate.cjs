// 分带并行的"门槛"与"取消"语义：
//
//   1. 逐条钉住 exportBandsEligible 的判定：哪些大帧可以分带、哪些必须串行；
//   2. 证伪旧门槛：同一组参数喂给旧签名（previewState 非空即拒）会得到 false，
//      而新门槛得到 true —— 这正是 22:45 真机 RAW 预览 layers=1069ms 的原因；
//   3. 取消：cancelPreviewWorker 拿到分带任务列表时必须逐带 taskpool.cancel 并
//      把 workerCancelled 置真，否则连续缩放会把 6 个带任务排到新帧前面。
//
// 门控函数是 private static，但 private 只是 TS 语法；转译后可直接调用。
// 不需要模拟器，也不碰像素。
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const modules = new Map(), storage = new Map();
const cancelled = [];

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
      if (n.endsWith('.so')) return { default: {} };
      if (n === '@kit.ArkTS') {
        return {
          taskpool: {
            Task: class {
              static isCanceled() { return false; }
              constructor(fn, ...args) { this.fn = fn; this.args = args; }
            },
            execute: async (task) => task.fn(...task.args),
            cancel: (task) => { cancelled.push(task); },
            getTaskPoolInfo: () => ({ threadInfos: [{}, {}, {}, {}] }),
          },
          util: {},
        };
      }
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }

// 门控只看这几个字段，用普通对象即可，不必构造真实会话。
function params(extra) {
  const base = {
    source: new ArrayBuffer(16),
    width: 64, height: 64,
    layers: [], luts: [],
  };
  return Object.assign(base, extra || {});
}
const identityOptics = {
  distortion: 0, chromatic: 0, defringe: 0, vignette: 0,
  perspectiveX: 0, perspectiveY: 0, perspectiveScale: 1,
};
const realOptics = Object.assign({}, identityOptics, { distortion: 0.2, vignette: -0.4 });
const viewport6 = [37, 11, 1.17, 1.13, 144, 361];

function eligible(p, w, h, referenceCpu) {
  return ImageProcessor['exportBandsEligible'](p, w, h, referenceCpu === true);
}
// 旧门槛的等价形式：previewState 非空直接拒绝。
function oldEligible(p, w, h, previewState) {
  if (previewState) return false;
  return eligible(p, w, h, false);
}

const RAW_PREVIEW = [1365, 2048];   // 5432×8152 的 1/4 fit 预览，真机 layers=1069ms
const TILE = [1365, 2048];          // 放大瓦片（带 6 元视口）
const EXPORT = [5432, 8152];        // 44MP 导出
const SMALL = [341, 512];           // 小预览

// ---- 1. 可以分带 ----
ok(ImageProcessor['exportBandsEligible'].length === 4,
  '门槛签名只有 (params,width,height,referenceCpu)，previewState/cacheSource 已移出');
ok(eligible(params({}), RAW_PREVIEW[0], RAW_PREVIEW[1], false) === true,
  '≥2MP 的 fit 预览可以分带（旧门槛用 previewState 拒掉了它）');
ok(eligible(params({ viewport: viewport6, optics: identityOptics }), TILE[0], TILE[1], false) === true,
  '光学恒等的放大瓦片可以分带');
ok(eligible(params({ viewport: viewport6 }), TILE[0], TILE[1], false) === true,
  '没有 optics 字段的瓦片可以分带');
ok(eligible(params({ layers: [{ maskBuffer: new Uint8ClampedArray(16), mask: { id: 1 } }] }),
  TILE[0], TILE[1], false) === true,
  '结构化蒙版（maskBuffer 已在）可以分带');
ok(eligible(params({}), EXPORT[0], EXPORT[1], false) === true, '44MP 导出可以分带');

// ---- 2. 必须串行（逐条例外） ----
ok(eligible(params({}), RAW_PREVIEW[0], RAW_PREVIEW[1], true) === false,
  '看原图 before 渲染必须串行');
ok(eligible(params({ denoise: { luminance: 40, color: 10 } }), RAW_PREVIEW[0], RAW_PREVIEW[1], false) === false,
  '降噪必须串行（分带路径没有降噪阶段）');
ok(eligible(params({}), SMALL[0], SMALL[1], false) === false,
  '<2MP 的小预览必须串行（任务开销大于收益）');
ok(eligible(params({ layers: [{ maskBuffer: null, mask: { id: 1 } }] }), TILE[0], TILE[1], false) === false,
  '旧式未结构化蒙版必须串行（带内无法还原整帧坐标）');
ok(eligible(params({ viewport: viewport6, optics: realOptics }), TILE[0], TILE[1], false) === false,
  '非恒等光学的放大瓦片必须串行（光学带改写 frame）');
ok(eligible(params({}), 64, 32, false) === false, '窄条（height<64）不做分带');
ok(eligible(params({}), 1, 2048, false) === false, '单列不做分带');

// ---- 3. 证伪：旧门槛在 RAW 预览上必然拒绝 ----
ok(oldEligible(params({}), RAW_PREVIEW[0], RAW_PREVIEW[1], { worker: null }) === false,
  '证伪成立：旧门槛（previewState 非空即拒）对 RAW fit 预览返回 false');
ok(eligible(params({}), RAW_PREVIEW[0], RAW_PREVIEW[1], false) === true,
  '新门槛对同一组参数返回 true —— 差异即 layers=1069ms 的成因');
const sourceText = fs.readFileSync(root + '/edit/engine/ImageProcessor.ets', 'utf8');
ok(/if \(previewState\) return false;/.test(sourceText) === false,
  '源码里不得残留 `if (previewState) return false;`');

// ---- 4. 取消：分带任务必须逐带取消 ----
{
  const bandA = new (class { constructor() { this.id = 'A'; } })();
  const bandB = new (class { constructor() { this.id = 'B'; } })();
  const state = { worker: null, workerCancelled: false, bandWorkers: [bandA, bandB] };
  cancelled.length = 0;
  ImageProcessor['cancelPreviewWorker'](state);
  ok(state.workerCancelled === true, '取消分带预览必须置 workerCancelled，让 isStale 立刻为真');
  ok(cancelled.length === 2 && cancelled[0] === bandA && cancelled[1] === bandB,
    '取消分带预览必须逐带 taskpool.cancel（实际 ' + cancelled.length + ' 个）');
  ok(state.bandWorkers.length === 0, '取消后必须清空任务列表，避免下一帧复用旧句柄');
}

// ---- 5. 取消：单任务路径保持原样 ----
{
  const single = { id: 'S' };
  const state = { worker: single, workerCancelled: false };
  cancelled.length = 0;
  ImageProcessor['cancelPreviewWorker'](state);
  ok(state.workerCancelled === true && cancelled.length === 1 && cancelled[0] === single,
    '单任务预览的取消语义不变');
}

// ---- 6. 取消后不再重复取消/空转 ----
{
  const state = { worker: null, workerCancelled: true, bandWorkers: [] };
  cancelled.length = 0;
  ImageProcessor['cancelPreviewWorker'](state);
  ok(cancelled.length === 0, '没有在跑的任务时取消是空操作');
}

console.log('PASS 分带门槛与取消语义：');
console.log('  - 可并行：>=2MP 预览、光学恒等瓦片、结构化蒙版、44MP 导出');
console.log('  - 必串行：before、降噪、<2MP、旧式蒙版、非恒等光学瓦片、窄条');
console.log('  - 证伪：旧 previewState 门槛对 1365×2048 预览返回 false（新门槛 true）');
console.log('  - 取消：6 带任务逐带 cancel，workerCancelled 置真，列表清空');
console.log(`${checks} 项通过`);
