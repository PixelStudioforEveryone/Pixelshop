// 高清瓦片的外扩边距（halo）必须覆盖细节阶段所有已启用滤波器的真实影响范围。
//
// 背景：放大后渲染的是源图的一个窗口（EditorPage.requestDetailRender）。邻域滤波器
// 在窗口边缘会钳在自己的边界上，于是瓦片四周出现接缝和错值。此前 pad 只按降噪半径
// 算，不降噪时为 0——开了细节再放大，边界就是错的。
//
// 参考实现 lightcraft（crates/ui-egui/src/region.rs）按各阶段 sigma 的 3σ 推边距，
// 并在 crates/pipeline/src/tests_window.rs 里断言"窗口渲染 == 整帧渲染后裁切"。
//
// 本套件不靠"读代码相信公式"，而是**实测**每个阶段的影响半径：改动距离 d 处的一个
// 像素，看中心探测点是否变化，取最大的 d 作为真实影响半径，再断言 halo >= 它。
// 这个断言是可证伪的：halo 一旦小于真实范围，测试就红。
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
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
    Promise, Error, require: (n) => {
      // LocalContrastCore now imports its native wrapper; the .so is stubbed so
      // the ArkTS implementation (the reference this suite measures) runs.
      if (n.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const core = load(root + '/edit/engine/LocalContrastCore.ets');
const { applyLocalContrast, localContrastHaloRadius, textureRadius, clarityRadius,
  sharpenRadiusPixels, dehazeWindowRadius, localContrastDefaults } = core;

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }

const W = 161, H = 121, CX = 80, CY = 60;
// 有轻微起伏的中灰图：滤波器需要有信号才看得出影响。
const base = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    const value = 100 + ((x * 3 + y * 5) % 40);
    base[i] = value; base[i + 1] = value; base[i + 2] = value; base[i + 3] = 255;
  }
}

function params(spec) {
  const p = localContrastDefaults();
  for (const key of Object.keys(spec)) p[key] = spec[key];
  return p;
}

/** 在距离 d 处改一个像素，返回中心探测点的 RGB 是否变化。 */
function changesAt(p, distance) {
  const probe = applyLocalContrast(base, W, H, p, Math.max(W, H));
  const probeValue = [probe[(CY * W + CX) * 4], probe[(CY * W + CX) * 4 + 1], probe[(CY * W + CX) * 4 + 2]];
  const moved = new Uint8ClampedArray(base);
  const tx = CX + distance, ty = CY;
  if (tx >= W) return false;
  const offset = (ty * W + tx) * 4;
  const bumped = base[offset] > 128 ? 0 : 255;
  moved[offset] = bumped; moved[offset + 1] = bumped; moved[offset + 2] = bumped;
  const other = applyLocalContrast(moved, W, H, p, Math.max(W, H));
  return other[(CY * W + CX) * 4] !== probeValue[0] ||
    other[(CY * W + CX) * 4 + 1] !== probeValue[1] ||
    other[(CY * W + CX) * 4 + 2] !== probeValue[2];
}

/** 实测影响半径：最大的、仍能让探测点变化的距离。 */
function measureReach(p) {
  ok(changesAt(p, 0) || changesAt(p, 1),
    '探针本身必须对近邻改动敏感，否则下面的距离测量没有意义');
  let reach = 0;
  for (let d = 1; d <= 40; d++) if (changesAt(p, d)) reach = d;
  return reach;
}

const cases = [
  { label: '纹理', spec: { texture: 0.9 }, radius: textureRadius },
  { label: '清晰度', spec: { clarity: 0.9 }, radius: clarityRadius },
  { label: '锐化', spec: { sharpenAmount: 1.0, sharpenRadius: 0.5 }, radius: (e) => sharpenRadiusPixels(e, 0.5) },
];

for (const item of cases) {
  const p = params(item.spec);
  const halo = localContrastHaloRadius(Math.max(W, H), p);
  const reach = measureReach(p);
  ok(reach > 0, item.label + '：实测影响半径为正（' + reach + ' px），说明该阶段确实是邻域运算');
  ok(halo >= reach,
    item.label + '：halo ' + halo + ' px 覆盖实测影响半径 ' + reach + ' px。若 halo 偏小，' +
    '放大后的瓦片边界就会出现接缝——这正是此前 pad 只按降噪半径算时的状态');
  // 与单一阶段半径的关系：启用后 halo 至少等于该阶段的核半径。
  ok(halo >= item.radius(Math.max(W, H)),
    item.label + '：halo 不小于该阶段声明的核半径 ' + item.radius(Math.max(W, H)) + ' px');
}

// 去朦胧单独处理：它的 airlight 是**整帧统计量**（暗通道的高百分位），改一个像素几乎
// 不动它，所以上面那套"改近邻看探针"的测法对它测出 0——这不是它不相邻域，而是它的
// 主导项根本不在邻域里。lightcraft 因此在 finish.rs / lib.rs 里把整帧 airlight 显式
// 传进窗口渲染（"The whole frame's dehaze airlight, for a windowed render"）。
const dehazeParams = params({ dehaze: 0.9 });
const dehazeHalo = localContrastHaloRadius(Math.max(W, H), dehazeParams);
ok(dehazeHalo === 0, '去朦胧换成 Compositor 的逐像素实现后不再需要外扩（halo = 0）');
// 这一条是**限制说明**，不是通过项：单像素扰动影响不到探测点，说明雾色是整帧统计量，
// halo 无法弥补。放大瓦片的去朦胧仍需把整帧雾色传进去（当前未实现），lightcraft 就是这么做的。
ok(!changesAt(dehazeParams, 1),
  '去朦胧对单像素扰动不敏感：雾色是整帧统计量，halo 无法让它与整帧等价');

localContrastHaloRadius(Math.max(W, H), params({ clarity: 0.5 }));
ok(localContrastHaloRadius(Math.max(W, H), localContrastDefaults()) === 0,
  '全部为默认值时 halo 为 0：瓦片不必多读任何像素');

// 多阶段同时启用时取最大值，而不是相加——相加会让瓦片无谓地变得很大。
const combo = params({ texture: 0.9, clarity: 0.9 });
const comboHalo = localContrastHaloRadius(Math.max(W, H), combo);
ok(comboHalo === localContrastHaloRadius(Math.max(W, H), params({ clarity: 0.9 })),
  '纹理与清晰度同时启用时 halo 取两者较大者（' + comboHalo + ' px），不是两者相加');
ok(comboHalo >= measureReach(combo), '并且仍然覆盖两者的组合实测影响半径');

// 导出分辨率越高，核半径与外扩都应随之增长（导出与预览同比例，才谈得上一致）。
const small = localContrastHaloRadius(500, params({ clarity: 0.5 }));
const large = localContrastHaloRadius(4000, params({ clarity: 0.5 }));
ok(large > small, '长边 4000 的外扩（' + large + ' px）大于长边 500 的（' + small + ' px）');

// 去朦胧的窗口半径只有一处定义：applyDehaze 必须复用它，否则瓦片边距会和实际窗口漂移。
const source = fs.readFileSync(root + '/edit/engine/LocalContrastCore.ets', 'utf8');
const dehazeBody = source.slice(source.indexOf('function applyDehaze'), source.indexOf('function applySharpen'));
ok(dehazeBody.indexOf('dehazeWindowRadius(longEdge)') >= 0,
  'applyDehaze 直接调用 dehazeWindowRadius()，窗口半径只有一处定义');
ok(!/Math\.round\(longEdge \* DEHAZE_WINDOW_FRACTION\)/.test(dehazeBody),
  'applyDehaze 内部不再自己抄一份窗口公式');

// 放大瓦片必须真的用上它（EditorPage 的 pad）。
const page = fs.readFileSync('entry/src/main/ets/pages/EditorPage.ets', 'utf8');
ok(/localContrastHaloRadius\(fullWidth, detailForHalo\)/.test(page),
  'EditorPage 用 localContrastHaloRadius 计算瓦片外扩');
ok(/const detailForHalo: LocalContrastParams = \{/.test(page),
  '并把细节设置显式取成 LocalContrastParams（ArkTS 不支持结构化类型转换）');
ok(/pad = Math\.max\(pad, Math\.ceil\(detailHalo \/ scale\) \+ 1\)/.test(page),
  '外扩按渲染缩放折算成源像素，并与降噪外扩取较大者');

console.log('PASS 细节阶段的外扩边距覆盖实测影响半径：' + cases.map((c) => c.label).join('/') +
  ' 各自的真实影响范围都不超过 halo，全默认时为 0，且随导出分辨率增长。');
console.log('NOTE halo 覆盖最大核半径即保证"窗口渲染 == 整帧渲染后裁切"；本套件实测了影响半径作为上界证据，');
console.log('     但尚未跑整帧 vs 窗口的逐像素等价对比（那需要走 renderViewport 的瓦片通路）。');
console.log(checks + ' 项通过');
