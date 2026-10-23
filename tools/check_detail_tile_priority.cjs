// 高清瓦片与有界预览的显示优先级（真机 C→A 闪烁回归）。
//
// 现场（14:52:xx 的 VIVID_ 日志）：放大后一块 1455x2048 的 CPU 瓦片 C 发布，
// 随后任意一次预览帧发布都会让 EditorPage.onPreviewUpdated 无条件调用
// clearDetailRender()，于是 detailPixelMap=null，画面落到有界预览 A（本机是
// gpuPreviewActive=true 的 EGL 表面帧），颜色与 C 不同；长按看原图同样会在按下
// 的瞬间清掉 C，松手后只能等一块新瓦片。
//
// 本套件钉死修复的两条结构不变量：
//   1) 预览发布只能让"编辑状态真的变了"的瓦片过期；同一次编辑的 refine 帧和
//      长按原图的切换帧都不得清掉瓦片。
//   2) 长按原图是显示切换，不是参数变化：它不得递增 processingRequestVersion，
//      否则"编辑状态指纹"会把显示切换误判成编辑。
//
// 可证伪性（已实际验证）：把 onPreviewUpdated 改回无条件 clearDetailRender()，
// 第 3 节水片有效期断言失败；把 setBeforePreview 的 requestVersion++ 加回去，
// 第 2 节行为断言失败。

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const root = path.resolve('entry/src/main/ets');
const cache = new Map();
const storage = new Map();

function load(file) {
  file = path.resolve(file);
  if (cache.has(file)) return cache.get(file).exports;
  const mod = { exports: {} };
  cache.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  const ctx = {
    exports: mod.exports, module: mod,
    console: { info() {}, warn() {}, error() {}, log() {} },
    Math, Number, Date, Map, Set, Promise, ArrayBuffer, Uint8Array, Uint8ClampedArray, Uint32Array, Float32Array,
    setTimeout, clearTimeout, setInterval, clearInterval,
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (name) => {
      if (name === 'libvivid_gpu.so') {
        return { default: {
          renderStack: async () => { throw new Error('no gpu in this test'); },
          clearSurface: async () => new ArrayBuffer(0),
          releaseSession: async () => new ArrayBuffer(0),
        } };
      }
      if (name === '@kit.ArkTS') {
        return { taskpool: {
          Task: class { static isCanceled() { return true; } constructor(fn) { this.fn = fn; } },
          execute: async () => { throw new Error('cancelled'); },
          cancel() {},
        } };
      }
      if (name === '@kit.ImageKit') {
        return { image: { PixelMapFormat: { RGBA_8888: 3 }, createPixelMap: async () => null } };
      }
      if (name.startsWith('@kit.')) return { hilog: { info() {}, warn() {}, error() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  };
  vm.runInNewContext(js, ctx, { filename: file });
  return mod.exports;
}

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }

const page = fs.readFileSync('entry/src/main/ets/pages/EditorPage.ets', 'utf8');
const canvas = fs.readFileSync('entry/src/main/ets/components/EditorCanvas.ets', 'utf8');
const processor = fs.readFileSync('entry/src/main/ets/edit/engine/ImageProcessor.ets', 'utf8');
const { ImageProcessor: P } = load(root + '/edit/engine/ImageProcessor.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');

// ---- 1. 编辑状态指纹的真值表 -------------------------------------------
const tile = { requestVersion: 7, publicVersion: 4, maskRevision: 3, geometryKey: '0|0|1|1|0|0|0', sourceKey: '2:photo.jpg:1' };
const same = { requestVersion: 7, publicVersion: 4, maskRevision: 3, geometryKey: '0|0|1|1|0|0|0', sourceKey: '2:photo.jpg:1' };
ok(P.detailTileMatches(tile, same) === true,
  '同一次编辑的预览帧与瓦片指纹相同 -> 瓦片必须继续有效（不能切到有界预览）');
ok(P.detailTileMatches(tile, { ...same, requestVersion: 8 }) === false,
  '参数变化（processingRequestVersion 前进）-> 瓦片过期');
ok(P.detailTileMatches(tile, { ...same, publicVersion: 5 }) === false,
  '只调用 bumpProcessing 的编辑（图层可见性/预设/蒙版层开关）也必须让瓦片过期');
ok(P.detailTileMatches(tile, { ...same, maskRevision: 4 }) === false,
  '蒙版变化（maskRevision 前进）-> 瓦片过期');
ok(P.detailTileMatches(tile, { ...same, geometryKey: '0.1|0.1|0.9|0.9|0|0|0' }) === false,
  '裁剪/旋转/翻转变化 -> 瓦片过期');
ok(P.detailTileMatches(tile, { ...same, sourceKey: '3:photo.jpg:1' }) === false,
  '换源/换图 -> 瓦片过期');
ok(typeof P.detailTileMatches === 'function',
  '指纹比较是 ImageProcessor 上的真实函数（页面与测试共用一份，不会各写一套）');

// ---- 2. 长按原图不得伪装成一次编辑 ------------------------------------
(async () => {
  const s = new EditSession();
  s.imageWidth = 100; s.imageHeight = 80;
  s.maskRevision = 3;
  s.cropLeft = 0.1; s.cropTop = 0; s.cropRight = 0.9; s.cropBottom = 1;
  s.requestProcessing();
  const beforeHold = s.processingRequestVersion;
  await P.setBeforePreview(s, true);
  ok(s.showBefore === true, 'fixture: hold 已经进入原图模式');
  ok(s.processingRequestVersion === beforeHold,
    '长按看原图是显示切换，processingRequestVersion 不得前进（否则瓦片会被误判过期）');
  await P.setBeforePreview(s, false);
  ok(s.showBefore === false, 'fixture: 松手回到调色画面');
  ok(s.processingRequestVersion === beforeHold,
    '松手同样是显示切换，processingRequestVersion 仍不得前进');
  s.requestProcessing();
  ok(s.processingRequestVersion === beforeHold + 1,
    '真正的参数变化仍然要让 processingRequestVersion 前进，瓦片才能被正确作废');

  // ---- 3. 页面：预览发布只作废"真的过期"的瓦片 ------------------------
  function slice(start, end, source) {
    const text = source || page;
    const at = text.indexOf(start);
    assert(at >= 0, 'missing marker: ' + start);
    const to = text.indexOf(end, at);
    assert(to > at, 'missing terminator for ' + start);
    return text.slice(at, to);
  }
  const onPreview = slice('this.editSession.onPreviewUpdated = () =>', 'if (this.imageUri)');
  const onPreviewCode = onPreview.replace(/\/\/[^\n]*/g, '');
  ok(onPreviewCode.indexOf('this.clearDetailRender()') < 0,
    'onPreviewUpdated 不得再无条件下清空瓦片（这正是 C→A 的触发点）');
  ok(onPreviewCode.indexOf('this.invalidateStaleDetailTile()') >= 0,
    '预览发布必须走"只作废过期瓦片"的门控');

  const staleFn = slice('private invalidateStaleDetailTile(): void', 'private async requestDetailRender');
  const staleCode = staleFn.replace(/\/\/[^\n]*/g, '');
  ok(staleCode.indexOf('this.isDetailTileCurrent()') >= 0,
    '门控必须先判断当前瓦片是否仍匹配编辑状态');
  ok(staleCode.indexOf('return;') >= 0 && staleCode.indexOf('clearDetailRender') > staleCode.indexOf('return;'),
    '匹配时必须在 clearDetailRender 之前返回：有效瓦片保持最上层');

  const currentFn = slice('private currentDetailTileStamp(): DetailTileStamp', 'private isDetailTileCurrent');
  ok(/requestVersion:\s*session\.processingRequestVersion/.test(currentFn),
    '指纹包含 processingRequestVersion');
  ok(/publicVersion:\s*session\.processingVersion/.test(currentFn),
    '指纹包含 processingVersion（覆盖只 bumpProcessing 的编辑）');
  ok(/maskRevision:\s*session\.maskRevision/.test(currentFn), '指纹包含 maskRevision');
  ok(/cropLeft[\s\S]*cropTop[\s\S]*cropRight[\s\S]*cropBottom/.test(currentFn),
    '指纹包含裁剪边界');
  ok(/rotation[\s\S]*flipH[\s\S]*flipV/.test(currentFn), '指纹包含旋转与翻转');
  ok(/loadGeneration[\s\S]*imageDisplayName[\s\S]*fullResSource/.test(currentFn),
    '指纹包含源图身份（换图/换源后旧瓦片不得留在屏幕上）');
  ok(/ImageProcessor\.detailTileMatches/.test(slice('private isDetailTileCurrent(): boolean',
    'private invalidateStaleDetailTile')), '页面调用共享的指纹比较函数');

  const publish = page.slice(page.indexOf('this.editSession.detailPixelMap = tileMap;'),
    page.indexOf('if (old) {'));
  ok(publish.indexOf('this.detailTileStamp = this.currentDetailTileStamp()') >= 0,
    '瓦片发布时必须记录它所对应的编辑状态指纹');

  const clearFn = slice('private clearDetailRender(reason: string =', 'private currentDetailTileStamp');
  ok(/if \(!hadTile && !hadWork\) return;/.test(clearFn),
    '没有瓦片也没有在途请求时 clearDetailRender 直接返回（避免按住/缩放期间每毫秒重复取消在途瓦片）');

  // ---- 4. 画布：有效瓦片不被预览信号重建 ------------------------------
  const syncFn = slice('private syncRenderVersion(): void', 'private detailTileCoversViewport', canvas);
  ok(syncFn.indexOf('this.detailTileCoversViewport()') >= 0,
    '预览信号只有在瓦片缺失/区域已变时才请求新瓦片');
  const coverFn = slice('private detailTileCoversViewport(): boolean', 'private releaseHeldKeys', canvas);
  ok(/region === null/.test(coverFn) && /getVisibleDetailRegion\(\)/.test(coverFn),
    '覆盖判断同时要求瓦片与其可见区域');

  const scheduleFn = slice('private scheduleDetailRequest(): void', 'private getVisibleDetailRegion', canvas);
  const scheduleCode = scheduleFn.replace(/\/\/[^\n]*/g, '');
  const holdAt = scheduleCode.indexOf('this.showBeforeLocal || this.showBeforeSignal');
  const clearAt = scheduleCode.indexOf('this.onRequestDetailRender(null)');
  ok(holdAt >= 0, '长按期间 scheduleDetailRequest 必须先短路');
  ok(holdAt < clearAt,
    '长按短路必须发生在"作废瓦片"分支之前：按住/松手不再丢瓦片');
  const holdBranch = scheduleCode.slice(holdAt, clearAt);
  ok(holdBranch.indexOf('onRequestDetailRender') < 0,
    '长按短路分支不得调用 onRequestDetailRender(null)（否则仍会清掉有效瓦片）');

  // ---- 5. 引擎：显示切换不递增参数版本 --------------------------------
  const setBefore = processor.slice(processor.indexOf('static setBeforePreview('),
    processor.indexOf('private static async renderBeforePreview('));
  const setBeforeCode = setBefore.replace(/\/\/[^\n]*/g, '');
  ok(setBeforeCode.indexOf('processingRequestVersion++') < 0,
    'setBeforePreview 不得再递增 processingRequestVersion（显示切换不是编辑）');

  console.log('PASS 高清瓦片优先级：编辑状态指纹真值表正确；长按/松手不再递增参数版本；');
  console.log('     预览发布只作废真正过期的瓦片，有效瓦片在缩放期间保持最上层。');
  console.log(checks + ' 项通过');
  process.exit(0);
})().catch((error) => {
  console.error('FAIL ' + (error && error.message ? error.message : String(error)));
  process.exit(1);
});
