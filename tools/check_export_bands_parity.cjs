// 导出的“按行分带并行”必须是串行整帧渲染的逐字节复制。
//
// 背景：44MP 导出的整条 CPU 管线原先在一个 TaskPool 任务里跑（layer 11.7s +
// detail 9.9s = 21.6s）。分带方案：
//   1. 逐点阶段（图层/LUT/点颜色/OkLCh）按行切带，每带一个 TaskPool 任务，
//      没有邻域依赖，切开逐字节精确；
//   2. 细节阶段整帧一次，由 native 内部按行/列并行（每行/每列加法顺序不变）；
//   3. 光学/黑白按行切带，光学的 halo 由 opticsHaloPadForRect 给出。
//
// 为什么细节不分带：box blur 的可分离实现用浮点运行和。带的第 0 行开始累加，
// 与整帧第 0 行开始累加不是同一串加法；halo 只能补邻居，补不了 1 LSB 的漂移。
// 本套件用 `detailHaloFor` 真跑一遍细节分带：halo=0 时必须出现明显差异（证伪），
// halo 放大到 45 行后仍有 maxCh<=1 的残留——这就是细节保留整帧的原因。
//
// 生产路径（逐点带 + 整帧细节 + 光学带）对拍串行整帧，要求 maxCh === 0。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const root = path.resolve('entry/src/main/ets');

function makeLoader() {
  const modules = new Map();
  function load(file) {
    file = path.resolve(file);
    if (modules.has(file)) return modules.get(file).exports;
    const mod = { exports: {} };
    modules.set(file, mod);
    const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    }).outputText;
    vm.runInNewContext(js, {
      module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
      Uint8Array, Uint8ClampedArray, Uint32Array, Int32Array, Float32Array, Float64Array,
      Promise, Error, __dirname: path.dirname(file),
      require: (name) => {
        // 所有 native 模块都缺席：细节/合成走 ArkTS 参考实现，Node 上可运行且
        // 与设备上的 .so 逐字节等价（check_detail_native_parity /
        // check_composite_native_parity 已各自证明）。
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

const load = makeLoader();
const bands = load(root + '/edit/engine/ExportBands.ets');
const worker = load(root + '/edit/engine/WorkerCore.ets');
const local = load(root + '/edit/engine/LocalContrastCore.ets');

const {
  BAND_PHASE_POINTWISE, BAND_PHASE_OPTICS, BAND_PHASE_ALL,
  planExportBands, buildBandJob, processExportBand, detailHaloFor,
} = bands;
const {
  applyLayerBandFull, applyLutStack, buildMatrix, hasAdvancedAdjustments, isIdentity,
} = worker;
const { applyLocalContrast, localContrastIsIdentity } = local;
const opticsCore = load(root + '/edit/engine/OpticsCore.ets');
const { applyOptics, opticsIsIdentity } = opticsCore;
const pointColorCore = load(root + '/edit/engine/PointColorCore.ets');
const { applyPointColorBuffer, pointColorIsIdentity } = pointColorCore;
const okLchCore = load(root + '/edit/engine/OkLChCore.ets');
const { applyOkLChBuffer, oklchIsIdentity } = okLchCore;
const blackWhiteCore = load(root + '/edit/engine/BlackWhiteCore.ets');
const { blackWhiteBuffer, blackWhiteIsIdentity } = blackWhiteCore;

let checks = 0;
function ok(condition, message) {
  checks++;
  assert(condition, message);
}

const W = 96;
const ROW_BYTES = W * 4;
const BAND_COUNT = 4;

function makeSource(seed, height) {
  const pixels = new Uint8ClampedArray(W * height * 4);
  let state = seed >>> 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < W; x++) {
      state = (state * 1664525 + 1013904223) >>> 0;
      const noise = ((state >>> 16) & 0xff) / 255;
      const base = 60 + 120 * (0.5 + 0.5 * Math.sin(x * 0.21 + y * 0.13)) +
        40 * (0.5 + 0.5 * Math.cos(y * 0.37));
      const offset = (y * W + x) * 4;
      pixels[offset] = Math.max(0, Math.min(255, base + noise * 26));
      pixels[offset + 1] = Math.max(0, Math.min(255, base * 0.86 + noise * 18));
      pixels[offset + 2] = Math.max(0, Math.min(255, base * 0.72 + noise * 30));
      pixels[offset + 3] = 255;
    }
  }
  return pixels;
}

function neutralAdjustments() {
  return {
    exposure: 0, contrast: 0, brightness: 0, highlights: 0, shadows: 0, whites: 0, blacks: 0,
    vignetteAmount: 0, vignetteMidpoint: 0, vignetteRoundness: 0, vignetteFeather: 0,
    vignetteHighlights: 0,
    grainAmount: 0, grainSize: 0, grainRoughness: 0, saturation: 0, vibrance: 0,
    temperature: 0, tint: 0, hue: 0, toneCurve: 0, curveRed: 0, curveGreen: 0, curveBlue: 0,
    toneCurvePoints: [[0, 0], [1, 1]], redCurvePoints: [[0, 0], [1, 1]],
    greenCurvePoints: [[0, 0], [1, 1]], blueCurvePoints: [[0, 0], [1, 1]],
    parametricHighlights: 0, parametricLights: 0, parametricDarks: 0, parametricShadows: 0,
    parametricShadowSplit: 0, parametricDarkSplit: 0, parametricLightSplit: 0,
    parametricRefineSaturation: 0,
    mixHue: new Array(8).fill(0), mixSaturation: new Array(8).fill(0),
    mixLuminance: new Array(8).fill(0),
    calibrationRedHue: 0, calibrationRedSaturation: 0, calibrationGreenHue: 0,
    calibrationGreenSaturation: 0, calibrationBlueHue: 0, calibrationBlueSaturation: 0,
    colorGradingEnabled: false, gradingShadowsHue: 0, gradingShadowsSaturation: 0,
    gradingShadowsLuminance: 0, gradingMidtonesHue: 0, gradingMidtonesSaturation: 0,
    gradingMidtonesLuminance: 0, gradingHighlightsHue: 0, gradingHighlightsSaturation: 0,
    gradingHighlightsLuminance: 0, gradingGlobalHue: 0, gradingGlobalSaturation: 0,
    gradingGlobalLuminance: 0, gradingBlending: 0, gradingBalance: 0,
  };
}

function adjust(spec) {
  const value = neutralAdjustments();
  for (const key of Object.keys(spec)) value[key] = spec[key];
  return value;
}

function layer(spec) {
  return {
    visible: spec.visible !== false,
    opacity: spec.opacity === undefined ? 1 : spec.opacity,
    blendMode: spec.blendMode || 0,
    adjustments: spec.adjustments || neutralAdjustments(),
    maskAdjustments: spec.maskAdjustments || neutralAdjustments(),
    mask: null,
    maskBuffer: spec.maskBuffer || null,
  };
}

function makeMask(kind, height) {
  const alpha = new Uint8ClampedArray(W * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < W; x++) {
      if (kind === 'radial') {
        const dx = (x - W * 0.55) / (W * 0.45);
        const dy = (y - height * 0.42) / (height * 0.3);
        alpha[y * W + x] = Math.max(0, Math.min(255,
          Math.round(255 * Math.max(0, 1 - Math.sqrt(dx * dx + dy * dy)))));
      } else {
        alpha[y * W + x] = Math.round(255 * (0.15 + 0.85 * (y / (height - 1))));
      }
    }
  }
  return alpha.buffer;
}

function makeDetail(spec) {
  return {
    texture: 0, clarity: 0, dehaze: 0, sharpenAmount: 0,
    sharpenRadius: 0.5, sharpenDetail: 0.5, sharpenMasking: 0.25,
    ...spec,
  };
}

function makeOptics(spec) {
  return {
    distortion: 0, vignetteAmount: 0, vignetteMidpoint: 0.5,
    chromaticAberration: 0, defringePurple: 0, defringeGreen: 0,
    ...spec,
  };
}

function makeLut() {
  const size = 9;
  const values = new Array(size * size * size * 3);
  for (let index = 0; index < size * size * size; index++) {
    values[index * 3] = index / (size * size * size - 1);
    values[index * 3 + 1] = Math.pow(index / (size * size * size - 1), 0.85);
    values[index * 3 + 2] = 1 - index / (size * size * size - 1);
  }
  return {
    enabled: true, intensity: 0.65, size: size, values: values,
    domainMin: [0, 0, 0], domainMax: [1, 1, 1],
  };
}

function makePointColor() {
  return [{
    hue: 0.09, saturation: 0.42, luminance: 0.36,
    hueShift: 0.12, saturationShift: 0.3, luminanceShift: 0.08,
    hueRange: 0.12, saturationRange: 0.35, luminanceRange: 0.4,
  }];
}

function makeOklch() {
  return { lightness: 0.04, chroma: 0.16, hue: 0.12 };
}

function makeBlackWhite() {
  return { enabled: true, mixers: [0.1, 0.2, 0.05, 0.3, 0.0, 0.15, 0.25, 0.1] };
}

/** 串行整帧参考：阶段顺序与 ProcessWorker.processPixels 一致（无降噪/几何）。 */
function serialReference(params) {
  const width = params.width;
  const height = params.height;
  // 必须是副本：参考路径会就地写 result，而 params.source 还要给分带路径用。
  let result = new Uint8ClampedArray(params.source.slice(0));
  const bandBytes = Math.min(result.length, 32768 * 4);
  const scratchBase = new Uint8ClampedArray(bandBytes);
  const scratchAdjusted = new Uint8ClampedArray(bandBytes);
  const scratchMaskAdjusted = new Uint8ClampedArray(bandBytes);
  const pipelines = [];
  for (const item of params.layers) {
    if (!item.visible || item.opacity <= 0) continue;
    const matrix = buildMatrix(item.adjustments);
    const hasMatrix = !isIdentity(matrix);
    const hasAdvanced = hasAdvancedAdjustments(item.adjustments);
    if (!hasMatrix && !hasAdvanced && !item.mask) continue;
    const maskBuffer = item.maskBuffer ? new Uint8ClampedArray(item.maskBuffer) : null;
    const maskMatrix = buildMatrix(item.maskAdjustments);
    const hasMaskMatrix = !isIdentity(maskMatrix);
    const hasMaskAdjustments = hasMaskMatrix || hasAdvancedAdjustments(item.maskAdjustments);
    pipelines.push({
      adjustments: item.adjustments, matrix: hasMatrix ? matrix : null, hasAdvanced,
      opacity: item.opacity, blendMode: item.blendMode, mask: maskBuffer,
      base: scratchBase, adjusted: scratchAdjusted,
      maskAdjustments: item.maskAdjustments,
      maskMatrix: hasMaskMatrix ? maskMatrix : null,
      hasMaskAdjustments: hasMaskAdjustments && maskBuffer !== null,
      maskAdjusted: scratchMaskAdjusted, width, height,
      viewport: params.viewport,
      pixelOffset: 0,
    });
  }
  for (const pipeline of pipelines) {
    for (let start = 0; start < result.length; start += bandBytes) {
      const end = Math.min(result.length, start + bandBytes);
      const band = result.subarray(start, end);
      pipeline.pixelOffset = start / 4;
      pipeline.base.set(band);
      applyLayerBandFull(band, pipeline, 0, band.length);
    }
  }
  for (let start = 0; start < result.length; start += bandBytes) {
    applyLutStack(result.subarray(start, Math.min(result.length, start + bandBytes)), params.luts);
  }
  if (params.pointColor && params.pointColor.length > 0 && !pointColorIsIdentity(params.pointColor)) {
    applyPointColorBuffer(result, width, height, params.pointColor);
  }
  if (params.oklch && !oklchIsIdentity(params.oklch)) {
    applyOkLChBuffer(result, width, height, params.oklch);
  }
  if (params.detail && !localContrastIsIdentity(params.detail)) {
    result = applyLocalContrast(result, width, height, params.detail, Math.max(width, height),
      params.detailHaze || []);
  }
  if (params.optics && !opticsIsIdentity(params.optics)) {
    result = applyOptics(result, width, height, params.optics);
  }
  if (params.blackWhite && !blackWhiteIsIdentity(params.blackWhite)) {
    blackWhiteBuffer(result, width, height, params.blackWhite);
  }
  return result;
}

function runPass(params, plans, source, target) {
  for (const plan of plans) {
    const job = buildBandJob(params, plan, source, params.width, params.height, []);
    const result = processExportBand(job);
    target.set(new Uint8ClampedArray(result.buffer), plan.targetTop * ROW_BYTES);
  }
}

/**
 * 生产路径的分带参考：
 *   pass 1 逐点（带）→ 整帧细节 → pass 2 光学/黑白（带）。
 * 注意 pass 2 的 source 必须是独立副本：生产里 executeBandPass 先建完所有任务
 * 再执行，测试里顺序执行，若 source===target 会读到已写回的行。
 */
function bandedReference(params, bandCount, opticsHaloOverride) {
  const width = params.width;
  const height = params.height;
  const pointwise = planExportBands(width, height, bandCount, 0, null,
    BAND_PHASE_POINTWISE, -1);
  const full = new Uint8ClampedArray(width * height * 4);
  runPass(params, pointwise.bands, new Uint8ClampedArray(params.source), full);

  let staged = full;
  if (params.detail && !localContrastIsIdentity(params.detail)) {
    staged = applyLocalContrast(full, width, height, params.detail, Math.max(width, height),
      params.detailHaze || []);
  }

  const opticsActive = params.optics && !opticsIsIdentity(params.optics);
  const bwActive = params.blackWhite && !blackWhiteIsIdentity(params.blackWhite);
  let opticsPlan = null;
  if (opticsActive || bwActive) {
    opticsPlan = planExportBands(width, height, bandCount, 0, params.optics || null,
      BAND_PHASE_OPTICS, opticsHaloOverride);
    const next = new Uint8ClampedArray(width * height * 4);
    runPass(params, opticsPlan.bands, staged, next);
    staged = next;
  }
  return { pixels: staged, pointwise, opticsPlan };
}

/** 只跑细节的分带诊断（生产不使用）：验证 halo 真的在起作用，并量化浮点漂移。 */
function detailBandReference(params, bandCount, haloOverride) {
  const width = params.width;
  const height = params.height;
  const detailHalo = detailHaloFor(params.detail, width, height);
  const plan = planExportBands(width, height, bandCount, detailHalo, null,
    BAND_PHASE_ALL, haloOverride);
  const target = new Uint8ClampedArray(width * height * 4);
  runPass(Object.assign({}, params, { optics: undefined, blackWhite: undefined }),
    plan.bands, new Uint8ClampedArray(params.source), target);
  return { pixels: target, plan };
}

function maxChannelDiff(a, b) {
  let maxCh = 0;
  let count = 0;
  for (let index = 0; index < a.length; index++) {
    const diff = Math.abs(a[index] - b[index]);
    if (diff > maxCh) maxCh = diff;
    if (diff !== 0) count++;
  }
  return { maxCh, count };
}

function baseParams(spec, height) {
  return {
    source: makeSource(spec.seed || 7, height).buffer,
    width: W,
    height: height,
    layers: spec.layers || [],
    luts: spec.luts || [],
    pointColor: spec.pointColor,
    oklch: spec.oklch,
    blackWhite: spec.blackWhite,
    detail: spec.detail,
    detailHaze: spec.detailHaze,
    optics: spec.optics,
    // 与 buildWorkerParams 一样始终给整帧视口：暗角/颗粒用绝对坐标查表。
    // 放大瓦片还会给一个**非单位缩放**的视口（buffer 像素 ≠ 整帧像素），
    // `viewport` 用例专门覆盖这条映射，逐点带必须按绝对 pixelOffset 取坐标。
    viewport: spec.viewport || [0, 0, 1, 1, W, height],
  };
}

function buildGroups(height) {
  return [
    {
      label: '细节+局部对比（纹理+清晰度+锐化）',
      spec: {
        seed: 11,
        layers: [layer({ adjustments: adjust({ exposure: 0.28, contrast: 0.18, saturation: 0.14 }) })],
        detail: makeDetail({ texture: 0.85, clarity: 0.7, sharpenAmount: 0.9, sharpenRadius: 0.55,
          sharpenDetail: 0.6, sharpenMasking: 0.3 }),
      },
    },
    {
      label: '蒙版局部调整（两层 + 混合模式）',
      spec: {
        seed: 13,
        layers: [
          layer({ adjustments: adjust({ exposure: 0.15, saturation: 0.22 }) }),
          layer({
            opacity: 0.8, blendMode: 1,
            maskBuffer: makeMask('radial', height),
            maskAdjustments: adjust({ exposure: 0.5, contrast: 0.3, saturation: 0.42,
              toneCurve: 1, toneCurvePoints: [[0, 0], [0.3, 0.24], [1, 1]] }),
          }),
        ],
      },
    },
    {
      label: '暗角+颗粒（绝对坐标空间效果）',
      spec: {
        seed: 15,
        layers: [layer({ adjustments: adjust({ exposure: 0.12, saturation: 0.18,
          vignetteAmount: -0.65, vignetteMidpoint: 0.45, vignetteRoundness: 0.2,
          vignetteFeather: 0.6, vignetteHighlights: 0.3,
          grainAmount: 0.45, grainSize: 0.4, grainRoughness: 0.35 }) })],
      },
    },
    {
      label: '光学（畸变+横向色差+去边纹+暗角）',
      falsifyOptics: true,
      spec: {
        seed: 17,
        layers: [layer({ adjustments: adjust({ exposure: 0.1, saturation: 0.1 }) })],
        optics: makeOptics({ distortion: 0.7, chromaticAberration: 0.6,
          defringePurple: 0.5, defringeGreen: 0.4, vignetteAmount: 0.55 }),
      },
    },
    {
      label: '全阶段组合（LUT/点颜色/OkLCh/细节/去朦胧/光学/黑白）',
      falsifyOptics: true,
      spec: {
        seed: 19,
        layers: [
          layer({ adjustments: adjust({ exposure: 0.2, contrast: 0.25, saturation: 0.2,
            mixSaturation: [0, 0.1, 0, 0.2, 0, 0, 0, 0.1] }) }),
          layer({
            opacity: 0.75, blendMode: 1,
            maskBuffer: makeMask('linear', height),
            maskAdjustments: adjust({ exposure: 0.3, temperature: 0.2, saturation: 0.3 }),
          }),
        ],
        luts: [makeLut()],
        pointColor: makePointColor(),
        oklch: makeOklch(),
        blackWhite: makeBlackWhite(),
        detail: makeDetail({ texture: 0.6, clarity: 0.55, dehaze: 0.45,
          sharpenAmount: 0.7, sharpenRadius: 0.5, sharpenDetail: 0.5, sharpenMasking: 0.2 }),
        optics: makeOptics({ distortion: 0.55, chromaticAberration: 0.4,
          defringePurple: 0.3, vignetteAmount: 0.4 }),
      },
    },
    {
      label: '去朦胧使用调用方整帧雾色',
      spec: {
        seed: 23,
        layers: [],
        detail: makeDetail({ clarity: 0.6, dehaze: 0.5, sharpenAmount: 0.6 }),
        detailHaze: [0.72, 0.68, 0.64],
      },
    },
    {
      // 放大瓦片：renderViewport = [x, y, scaleX, scaleY, fullWidth, fullHeight]，
      // 且缩放不是 1。逐点阶段（图层/蒙版/LUT/暗角颗粒）在带内必须用整帧绝对
      // 坐标；这条用例把“带内 0 行”和“整帧 y 行”的偏移真的走一遍。
      label: '放大瓦片视口（非单位缩放 + 蒙版 + LUT + 暗角）',
      spec: {
        seed: 29,
        viewport: [37, 11, 1.17, 1.13, 144, 361],
        layers: [
          layer({ adjustments: adjust({ exposure: 0.22, contrast: 0.2, saturation: 0.24,
            vignetteAmount: -0.4, vignetteMidpoint: 0.45, vignetteFeather: 0.5 }) }),
          layer({
            opacity: 0.8, blendMode: 2,
            maskBuffer: makeMask('radial', height),
            maskAdjustments: adjust({ exposure: 0.35, contrast: 0.25, temperature: 0.18 }),
          }),
        ],
        luts: [makeLut()],
      },
    },
    {
      // 预览语义：RAW 的 fit 预览没有 6 元视口（整帧），但同样带蒙版/LUT/暗角/
      // 细节。它现在也走分带（门槛不再看 previewState），所以必须与串行整帧一致。
      label: '预览语义（整帧 + 蒙版 + LUT + 暗角 + 细节）',
      spec: {
        seed: 31,
        layers: [
          layer({ adjustments: adjust({ exposure: 0.18, contrast: 0.22, saturation: 0.2,
            vignetteAmount: -0.45, vignetteMidpoint: 0.5, vignetteFeather: 0.45 }) }),
          layer({
            opacity: 0.85, blendMode: 1,
            maskBuffer: makeMask('radial', height),
            maskAdjustments: adjust({ exposure: 0.4, contrast: 0.2, temperature: 0.15 }),
          }),
        ],
        luts: [makeLut()],
        detail: makeDetail({ texture: 0.6, clarity: 0.45, sharpenAmount: 0.7, sharpenRadius: 0.5 }),
      },
    },
    {
      // 更深一档的放大视口（1.41×，矩形不在原点）：证明绝对坐标在第二个偏移量
      // 下仍然逐字节一致，而不只是 seed=29 那一组。
      label: '放大瓦片视口（1.41× 深缩放 + 蒙版 + LUT）',
      spec: {
        seed: 33,
        viewport: [96, 180, 1.41, 1.37, 144, 361],
        layers: [
          layer({ adjustments: adjust({ exposure: 0.24, contrast: 0.18, saturation: 0.26,
            vignetteAmount: -0.35, vignetteMidpoint: 0.4, vignetteFeather: 0.55 }) }),
          layer({
            opacity: 0.7, blendMode: 2,
            maskBuffer: makeMask('linear', height),
            maskAdjustments: adjust({ exposure: 0.3, contrast: 0.22, saturation: 0.2 }),
          }),
        ],
        luts: [makeLut()],
      },
    },
  ];
}

const report = [];
for (const height of [192, 320]) {
  for (const group of buildGroups(height)) {
    const params = baseParams(group.spec, height);
    const serial = serialReference(params);
    const startedAt = Date.now();
    const banded = bandedReference(params, BAND_COUNT, -1);
    const bandMs = Date.now() - startedAt;
    const diff = maxChannelDiff(serial, banded.pixels);
    const where = `${height}px ${group.label}`;
    ok(diff.maxCh === 0,
      `${where}：生产分带路径与串行整帧不逐字节一致（maxCh=${diff.maxCh}，${diff.count} 字节不同）`);
    ok(banded.pointwise.bands.length === BAND_COUNT,
      `${where}：应切成 ${BAND_COUNT} 带，实际 ${banded.pointwise.bands.length}`);
    let covered = 0;
    for (const plan of banded.pointwise.bands) {
      ok(plan.procTop <= plan.targetTop &&
        plan.procTop + plan.procRows >= plan.targetTop + plan.targetRows,
      `${where}：带 ${plan.index} 的处理行没有覆盖目标行`);
      ok(plan.procRows === plan.targetRows,
        `${where}：逐点阶段不应多读 halo 行（带 ${plan.index} 多读了 ${plan.procRows - plan.targetRows} 行）`);
      covered += plan.targetRows;
    }
    ok(covered === height, `${where}：所有带的目标行应覆盖 ${height} 行，实际 ${covered}`);

    let opticsHalo = 0;
    if (banded.opticsPlan) {
      for (const plan of banded.opticsPlan.bands) {
        if (plan.opticsHalo > opticsHalo) opticsHalo = plan.opticsHalo;
        ok(plan.procTop <= plan.targetTop &&
          plan.procTop + plan.procRows >= plan.targetTop + plan.targetRows,
        `${where}：光学带 ${plan.index} 的处理行没有覆盖目标行`);
      }
    }
    report.push({
      height, label: group.label, maxCh: diff.maxCh, diffBytes: diff.count,
      bands: banded.pointwise.bands.length, opticsHalo, bandMs,
    });

    if (group.falsifyOptics) {
      // 证伪：halo=0 时带边界没有真实邻居，光学结果必须与整帧不同。
      const broken = bandedReference(params, BAND_COUNT, 0);
      const brokenDiff = maxChannelDiff(serial, broken.pixels);
      ok(broken.opticsPlan !== null && broken.opticsPlan.bands[0].halo === 0 &&
        broken.opticsPlan.bands[0].procRows === broken.opticsPlan.bands[0].targetRows,
      `${where}：证伪计划应把实际 halo 强制为 0`);
      ok(brokenDiff.maxCh > 0,
        `${where}：把 halo 改成 0 后仍然逐字节一致（maxCh=0）——` +
        '说明本套件没有真正检测 halo，分带路径是形同虚设的');
      report[report.length - 1].falsifyMaxCh = brokenDiff.maxCh;
      report[report.length - 1].falsifyBytes = brokenDiff.count;
    }
  }
}

// ---- 细节分带的诊断：证明 halo 不是摆设，并量化“运行和漂移” ----------------
const detailHeight = 256;
const detailParams = makeDetail({ clarity: 0.7, sharpenAmount: 0.9, sharpenRadius: 0.55,
  sharpenDetail: 0.6, sharpenMasking: 0.3 });
const detailFull = serialReference({
  source: makeSource(11, detailHeight).buffer, width: W, height: detailHeight,
  layers: [], luts: [], detail: detailParams,
});
const detailNoHalo = detailBandReference({
  source: makeSource(11, detailHeight).buffer, width: W, height: detailHeight,
  layers: [], luts: [], detail: detailParams,
}, BAND_COUNT, 0);
const detailNoHaloDiff = maxChannelDiff(detailFull, detailNoHalo.pixels);
ok(detailNoHaloDiff.maxCh > 0,
  '细节分带 halo=0 仍然逐字节一致——halo 证伪失败，测试没有真正覆盖边界');

const detailHalo = detailHaloFor(detailParams, W, detailHeight);
const detailBanded = detailBandReference({
  source: makeSource(11, detailHeight).buffer, width: W, height: detailHeight,
  layers: [], luts: [], detail: detailParams,
}, BAND_COUNT, detailHalo);
const detailBandedDiff = maxChannelDiff(detailFull, detailBanded.pixels);

const detailWide = detailBandReference({
  source: makeSource(11, detailHeight).buffer, width: W, height: detailHeight,
  layers: [], luts: [], detail: detailParams,
}, BAND_COUNT, detailHalo * 3);
const detailWideDiff = maxChannelDiff(detailFull, detailWide.pixels);

// 细节 halo 必须来自引擎现有的半径函数，而不是一个碰巧够大的常数。
const zoomHalo = detailHaloFor(detailParams, W, detailHeight);
ok(zoomHalo > 0, '细节 halo 应大于 0');
const expectedHalo = Math.max(local.clarityRadius(Math.max(W, detailHeight)),
  local.sharpenRadiusPixels(Math.max(W, detailHeight), detailParams.sharpenRadius)) * 3;
ok(zoomHalo >= expectedHalo,
  `细节 halo ${zoomHalo} 应覆盖最大核半径的 3 倍支撑 ${expectedHalo}`);
ok(detailHaloFor(makeDetail({}), W, detailHeight) === 0, '细节全默认时 halo 必须为 0');

// 生产接线检查：ImageProcessor 真的调用了分带规划与并行任务体。
const imageSource = fs.readFileSync(root + '/edit/engine/ImageProcessor.ets', 'utf8');
ok(/planExportBands\(width, height, bandCount, 0, null, BAND_PHASE_POINTWISE\)/.test(imageSource),
  'ImageProcessor 的逐点阶段必须用 halo=0 的分带计划');
ok(/planExportBands\(width, height, bandCount, 0,\s*\n?\s*params\.optics/.test(imageSource),
  'ImageProcessor 的光学阶段必须用 opticsHaloPadForRect 规划出的带');
ok(/new taskpool\.Task\(processBandPixels/.test(imageSource),
  'ImageProcessor 必须把每带包装成 processBandPixels 任务');
ok(/detailWorkerParams\(params, (?:full\.buffer|detailSource)/.test(imageSource),
  'ImageProcessor 必须把细节阶段作为整帧任务交给 processPixels/native');
ok(/stage=export-bands/.test(imageSource), '分带计划必须有 VIVID_EDIT_PERF 日志');
// 放大瓦片也必须走分带：旧门槛把 cacheSource（=瓦片）整个拒掉，导致 2.6MP 瓦片
// 退回**单任务**串行（真机 layers=804ms 就是这么来的）。新门槛只保留这几种串行：
// before 渲染、降噪、<2MP、旧式蒙版、以及带非单位缩放视口且光学非恒等（光学带的
// frame 会被改写成带内坐标，宁可变慢也不改像素）。
ok(!/if \(cacheSource \|\| previewState\) return false;/.test(imageSource),
  '瓦片（cacheSource=true）不得被分带门槛整体拒绝');
ok(!/if \(previewState\) return false;/.test(imageSource),
  'previewState 不得再是分带门槛：RAW 的 fit 预览也是 2.8MP，且它只携带取消状态');
ok(/if \(referenceCpu\) return false;/.test(imageSource),
  '看原图（referenceCpu）的 before 渲染必须继续串行');
ok(/const hasViewport = params\.viewport !== undefined && params\.viewport\.length === 6;/.test(imageSource),
  '分带门槛必须区分 6 元视口（放大瓦片）');
ok(/if \(hasViewport && params\.optics !== undefined && !opticsIsIdentity\(params\.optics\)\) return false;/.test(imageSource),
  '非恒等光学的瓦片必须留在串行路径（分带光学改写了 frame）');
ok(/runExportBands\(params, width, height, isStale,\s*\n?\s*previewState !== undefined \? 'preview' :[\s\S]{0,80}?'tile' : 'export'\)/.test(imageSource),
  '分带日志必须区分 preview / tile / export 三种调用方');
ok(/previewState\.bandWorkers = tasks/.test(imageSource) && /cancelPreviewWorker[\s\S]{0,400}?taskpool\.cancel\(task\)/.test(imageSource),
  '分带预览必须把任务句柄交给预览状态，才能逐带取消（否则连续缩放会堆积任务）');
ok(/pointwiseActive/.test(imageSource) && /skipped=empty/.test(imageSource),
  '没有逐点活儿时必须跳过分带逐点趟，而不是跑一趟空任务');
const exportBandsSource = fs.readFileSync(root + '/edit/engine/ExportBands.ets', 'utf8');
ok(/opticsHaloPadForRect\(/.test(exportBandsSource),
  '光学 halo 必须来自 OpticsCore.opticsHaloPadForRect');
const workerSource = fs.readFileSync(root + '/edit/engine/ProcessWorker.ets', 'utf8');
ok(/@Concurrent\s+export function processBandPixels/.test(workerSource),
  'ProcessWorker 必须导出 @Concurrent processBandPixels');

console.log('PASS 导出的逐字节一致性与 halo 证伪：');
for (const row of report) {
  const falsify = row.falsifyMaxCh === undefined ? '' :
    ` | halo=0 证伪 maxCh=${row.falsifyMaxCh} (${row.falsifyBytes} 字节)`;
  console.log(`  - ${row.height}px ${row.label}: maxCh=${row.maxCh} diff=${row.diffBytes}` +
    ` bands=${row.bands} opticsHalo=${row.opticsHalo} bandMs=${row.bandMs}${falsify}`);
}
console.log(`  - 细节分带诊断：halo=0 maxCh=${detailNoHaloDiff.maxCh}` +
  ` | halo=${detailHalo} maxCh=${detailBandedDiff.maxCh} (${detailBandedDiff.count} 字节)` +
  ` | halo=${detailHalo * 3} maxCh=${detailWideDiff.maxCh} (${detailWideDiff.count} 字节)`);
console.log('    细节分带在 halo 充足时仍有 1 LSB 残留（box blur 浮点运行和的顺序差），' +
  '因此生产路径保留整帧细节 + native 行/列并行。');
console.log(checks + ' 项通过');
