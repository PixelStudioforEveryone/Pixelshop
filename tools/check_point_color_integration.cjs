// Point colour integration: the model, the two engine entry points agreeing, the
// real worker pipeline and its ordering against the detail stage, sidecar/undo
// round-trips, the GPU decline, and the absence of a fake eyedropper.
//
// check_point_color.cjs proves the per-colour ALGORITHM. This suite proves the
// WIRING and the buffer-level entry point added for the render path.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
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
    // NOTE: JSON is deliberately NOT injected; see check_detail_integration.cjs.
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
        const encoder = () => ({ encode: (t) => new Uint8Array(Buffer.from(t, 'utf8')) });
        const decoder = () => ({ decode: (b) => Buffer.from(b).toString('utf8'),
          decodeToString: (b) => Buffer.from(b).toString('utf8') });
        function TextEncoderShim() { return encoder(); }
        TextEncoderShim.create = encoder;
        function TextDecoderShim() { return decoder(); }
        TextDecoderShim.create = decoder;
        return { util: { TextEncoder: TextEncoderShim, TextDecoder: TextDecoderShim },
          taskpool: { Task: class { static isCanceled() { return false; } }, execute: async (t) => t } };
      }
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      if(n.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { PointColorSettings } = load(root + '/edit/models/PointColorSettings.ets');
const pc = load(root + '/edit/engine/PointColorCore.ets');
const { localContrastIsIdentity, applyLocalContrast } = load(root + '/edit/engine/LocalContrastCore.ets');
const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
function differences(a, b) {
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}

// --- 1. The model ---------------------------------------------------------
const empty = new PointColorSettings();
ok(empty.samples.length === 0 && empty.isBypass(), 'a fresh document bypasses the stage');
ok(!empty.isFull(), 'and is not full');
ok(PointColorSettings.restore(undefined).isBypass(), 'a pre-Point-Colour sidecar restores to a bypass');
ok(empty.addSample(220, 40, 40), 'a sample can be added from an 8-bit colour');
ok(Math.abs(empty.samples[0].hue - 0) < 1e-9, 'red maps to hue 0 (got ' + empty.samples[0].hue + ')');
ok(empty.samples[0].saturation > 0.5 && Math.abs(empty.samples[0].luminance - 0.51) < 0.02,
  'with a high saturation and a mid lightness, not black');
ok(empty.isBypass(), 'a sample with no shift yet is still a bypass, so adding one costs no render');
empty.samples[0].hueShift = 0.5;
ok(!empty.isBypass(), 'and a shift makes it active');
// Repair rather than delete: one bad field must not lose the whole colour.
const repaired = PointColorSettings.restore({ samples: [
  { hue: 0.2, saturation: 0.5, luminance: 0.5, hueShift: NaN, saturationShift: 0.3,
    luminanceShift: 0, hueRange: 9, saturationRange: -4, luminanceRange: 0.4 },
] });
ok(repaired.samples.length === 1, 'a sample with one non-finite field is REPAIRED, not dropped');
ok(repaired.samples[0].hueShift === 0, 'the non-finite shift becomes the no-op default');
ok(repaired.samples[0].saturationShift === 0.3, 'while its usable fields survive');
ok(repaired.samples[0].hueRange === 1 && repaired.samples[0].saturationRange === 0,
  'and out-of-range fields are clamped, not discarded');
const dropped = PointColorSettings.restore({ samples: [
  { hue: NaN, saturation: 0.5, luminance: 0.5 }, null, { hue: 0.5, saturation: NaN, luminance: 0.5 },
] });
ok(dropped.samples.length === 0, 'a sample whose identity colour is unusable is dropped (' +
  dropped.samples.length + ' of 3 kept)');
const capped = PointColorSettings.restore({ samples: new Array(20).fill(null).map(() =>
  ({ hue: 0.1, saturation: 0.5, luminance: 0.5, hueShift: 0.2, saturationShift: 0, luminanceShift: 0,
     hueRange: 0.1, saturationRange: 0.4, luminanceRange: 0.4 })) });
ok(capped.samples.length === pc.MAX_POINT_COLORS, 'a sidecar with too many samples is capped at ' +
  pc.MAX_POINT_COLORS + ' (got ' + capped.samples.length + ')');
ok(capped.isFull(), 'and reports itself full');
ok(!capped.addHsl(0.5, 0.5, 0.5), 'so adding another is refused rather than silently ignored');
const removeMe = new PointColorSettings();
removeMe.addHsl(0.1, 0.5, 0.5); removeMe.addHsl(0.2, 0.5, 0.5); removeMe.addHsl(0.3, 0.5, 0.5);
removeMe.removeAt(1);
ok(removeMe.samples.length === 2 && Math.abs(removeMe.samples[1].hue - 0.3) < 1e-12,
  'removeAt drops the right sample and keeps the order');
removeMe.removeAt(99);
ok(removeMe.samples.length === 2, 'an out-of-range index is ignored rather than throwing');
removeMe.clear();
ok(removeMe.samples.length === 0, 'clear empties the list');
const cloneSource = new PointColorSettings();
cloneSource.addHsl(0.4, 0.6, 0.4); cloneSource.samples[0].hueShift = -0.7;
const cloned = cloneSource.clone();
cloned.samples[0].hueShift = 0.9;
ok(cloneSource.samples[0].hueShift === -0.7, 'clone is a deep copy of the sample data, not a shared reference');

// --- 2. The two engine entry points must agree ---------------------------
// applyPointColorBuffer is what the renderer calls; applyPointColor is what the
// 196-check per-colour suite calls. They share applyPointColorInto, but the buffer
// version does its own byte<->float conversion and rounding, which is exactly where
// a drift could hide.
const W = 64, H = 48;
function fixture() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      // A spread of hues, saturations and lightnesses so the falloff is exercised
      // somewhere in the frame rather than landing entirely outside the range.
      b[i] = Math.round(255 * (0.5 + 0.5 * Math.sin(x * 0.4)));
      b[i + 1] = Math.round(255 * (0.5 + 0.5 * Math.sin(y * 0.3 + 1)));
      b[i + 2] = Math.round(255 * (0.5 + 0.5 * Math.sin((x + y) * 0.2 + 2)));
      b[i + 3] = 255;
    }
  }
  return b;
}
const source = fixture();
const wide = () => {
  const settings = new PointColorSettings();
  settings.addHsl(0.08, 0.6, 0.5);
  const sample = settings.samples[0];
  sample.hueShift = 0.5; sample.saturationShift = 0.4; sample.luminanceShift = -0.3;
  sample.hueRange = 0.5; sample.saturationRange = 0.7; sample.luminanceRange = 0.7;
  return settings.samples;
};
const samples = wide();
const bufferVersion = Uint8ClampedArray.from(source);
const changedCount = pc.applyPointColorBuffer(bufferVersion, W, H, samples);
ok(changedCount > 0, 'the buffer entry point reports how many pixels it changed (' + changedCount + ')');
let expectedByHand = 0;
const perPixelVersion = new Uint8ClampedArray(source.length);
for (let i = 0; i < W * H; i++) {
  const p = i * 4;
  const out = pc.applyPointColor(source[p] / 255, source[p + 1] / 255, source[p + 2] / 255, samples);
  const r = Math.round(Math.max(0, Math.min(1, out[0])) * 255);
  const g = Math.round(Math.max(0, Math.min(1, out[1])) * 255);
  const b = Math.round(Math.max(0, Math.min(1, out[2])) * 255);
  if (r !== source[p] || g !== source[p + 1] || b !== source[p + 2]) expectedByHand++;
  perPixelVersion[p] = r; perPixelVersion[p + 1] = g; perPixelVersion[p + 2] = b;
  perPixelVersion[p + 3] = source[p + 3];
}
ok(differences(bufferVersion, perPixelVersion) === 0,
  'the buffer entry point matches the per-pixel API byte for byte on all ' + (W * H) + ' pixels (' +
  differences(bufferVersion, perPixelVersion) + ' differ)');
ok(changedCount === expectedByHand, 'and its changed-pixel count matches an independent count (' +
  changedCount + ' vs ' + expectedByHand + ')');
// Non-vacuity: a frame the samples cannot reach must be reported as untouched and
// must not be written at all.
const grey = new Uint8ClampedArray(W * H * 4);
for (let i = 0; i < grey.length; i += 4) { grey[i] = 128; grey[i + 1] = 128; grey[i + 2] = 128; grey[i + 3] = 255; }
const greyCopy = Uint8ClampedArray.from(grey);
const chromaticOnly = new PointColorSettings();
chromaticOnly.addHsl(0.9, 0.95, 0.5);
chromaticOnly.samples[0].saturationShift = 0.8;
chromaticOnly.samples[0].hueRange = 0.02; chromaticOnly.samples[0].saturationRange = 0.05;
chromaticOnly.samples[0].luminanceRange = 0.05;
const greyChanged = pc.applyPointColorBuffer(grey, W, H, chromaticOnly.samples);
ok(greyChanged === 0 && differences(grey, greyCopy) === 0,
  'a chromatic sample leaves an all-grey frame byte-for-byte untouched and reports 0 (' + greyChanged + ')');
ok(pc.applyPointColorBuffer(Uint8ClampedArray.from(grey), W, H, []) === 0,
  'an empty sample list is a reported no-op');
ok(pc.applyPointColorBuffer(Uint8ClampedArray.from(grey), W, H, null) === 0, 'so is a null list');
ok(pc.applyPointColorBuffer(Uint8ClampedArray.from(grey), W, H, new Array(64).fill(null).map(() =>
  ({ hue: 0, saturation: 0, luminance: 0, hueShift: 0, saturationShift: 0, luminanceShift: 0,
     hueRange: 0.1, saturationRange: 0.4, luminanceRange: 0.4 }))) === 0,
  'and so is a full list of all-zero shifts: the identity short-circuit runs before any HSL round trip');

// --- 3. The real worker pipeline -----------------------------------------
function params(over) {
  const base = {
    source: Uint8ClampedArray.from(source).buffer,
    width: W, height: H, layers: [], luts: [],
    cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
    rotation: 0, flipH: false, flipV: false,
    applyGeometry: false, ignoreCrop: false,
  };
  return Object.assign(base, over);
}
const bypassRun = new Uint8ClampedArray(processPixels(params({ pointColor: [] })).buffer);
ok(differences(bypassRun, source) === 0, 'an empty sample list reproduces the source byte for byte');
ok(differences(new Uint8ClampedArray(processPixels(params({ pointColor: undefined })).buffer), source) === 0,
  'omitting the stage entirely is also byte-for-byte free');
const activeRun = new Uint8ClampedArray(processPixels(params({ pointColor: samples })).buffer);
const activeDiff = differences(activeRun, source);
ok(activeDiff > 1000, 'an active stage changes the rendered frame (' + activeDiff + ' bytes)');
ok(differences(new Uint8ClampedArray(processPixels(params({ pointColor: samples })).buffer), activeRun) === 0,
  'two identical jobs produce identical output');
// The worker mutates in place, so the caller's buffer must not be the one written.
ok(differences(source, fixture()) === 0, 'the job does not write back into the caller-visible fixture');

// --- 4. Ordering against the detail stage --------------------------------
// Contract: point colour first, then detail. Checked by composing the real modules
// by hand AND by checking the opposite order differs.
const detailParams = { texture: 0.3, clarity: 0.5, dehaze: 0.2, sharpenAmount: 0.4,
  sharpenRadius: 0.5, sharpenDetail: 0.5, sharpenMasking: 0 };
const bothRun = new Uint8ClampedArray(processPixels(params({ pointColor: samples, detail: detailParams })).buffer);
const colourFirst = Uint8ClampedArray.from(source);
pc.applyPointColorBuffer(colourFirst, W, H, samples);
const colourFirstThenDetail = applyLocalContrast(colourFirst.subarray(0, W * H * 4), W, H,
  detailParams, Math.max(W, H));
ok(differences(bothRun, colourFirstThenDetail) === 0,
  'the worker grades before it sharpens (' + differences(bothRun, colourFirstThenDetail) + ' differing bytes)');
const detailFirst = applyLocalContrast(Uint8ClampedArray.from(source), W, H, detailParams, Math.max(W, H));
const detailThenColour = Uint8ClampedArray.from(detailFirst);
pc.applyPointColorBuffer(detailThenColour, W, H, samples);
const orderGap = differences(bothRun, detailThenColour);
ok(orderGap > 200, 'the opposite order gives a different frame (' + orderGap + ' differing bytes), so the ' +
  'ordering assertion is not vacuous');
// Real point-colour grading must not be a no-op on a photo-like frame: assert the
// active run differs from the detail-only run too, so the pass is really happening.
const detailOnly = new Uint8ClampedArray(processPixels(params({ detail: detailParams })).buffer);
ok(differences(bothRun, detailOnly) > 1000,
  'and the point-colour pass really contributes (' + differences(bothRun, detailOnly) + ' bytes differ from ' +
  'the detail-only render)');

// --- 5. Sidecar and undo -------------------------------------------------
const session = new EditSession();
session.layers = [new Layer('synthetic')];
const seeded = new PointColorSettings();
seeded.addSample(200, 60, 40); seeded.addHsl(0.55, 0.7, 0.45);
seeded.samples[0].hueShift = 0.35; seeded.samples[0].saturationShift = -0.2;
seeded.samples[0].hueRange = 0.22;
seeded.samples[1].luminanceShift = 0.6;
session.pointColor = seeded;
const exported = JSON.parse(session.exportAdjustmentState());
ok(exported.pointColor && exported.pointColor.samples && exported.pointColor.samples.length === 2,
  'the exported adjustment state carries both samples');
const reopened = new EditSession();
reopened.layers = [new Layer('synthetic')];
ok(reopened.importAdjustmentState(JSON.stringify(exported)), 'the exported state imports back');
ok(reopened.pointColor.samples.length === 2, 'both samples survive');
ok(Math.abs(reopened.pointColor.samples[0].hueShift - 0.35) < 1e-12 &&
  Math.abs(reopened.pointColor.samples[0].hueRange - 0.22) < 1e-12 &&
  Math.abs(reopened.pointColor.samples[1].luminanceShift - 0.6) < 1e-12,
  'with every shift and range intact');
const legacy = JSON.parse(JSON.stringify(exported));
delete legacy.pointColor;
const legacySession = new EditSession();
legacySession.layers = [new Layer('synthetic')];
ok(legacySession.importAdjustmentState(JSON.stringify(legacy)), 'a sidecar written before this stage imports');
ok(legacySession.pointColor.isBypass() && legacySession.pointColor.samples.length === 0,
  'and opens as an exact bypass, not on a random colour');
const undoSession = new EditSession();
undoSession.layers = [new Layer('synthetic')];
undoSession.pushUndo();
undoSession.pointColor.addHsl(0.3, 0.8, 0.5);
undoSession.pushUndo();
undoSession.pointColor.samples[0].hueShift = 0.8;
undoSession.undo();
ok(undoSession.pointColor.samples.length === 1 && undoSession.pointColor.samples[0].hueShift === 0,
  'undo restores the previous sample state');
undoSession.undo();
ok(undoSession.pointColor.samples.length === 0, 'undo removes the added sample');
undoSession.redo();
ok(undoSession.pointColor.samples.length === 1, 'redo brings it back');

// --- 6. GPU decline, and the panel wired to the canvas picker -------------
const bridgeSource = fs.readFileSync('entry/src/main/ets/edit/engine/GpuShaderBridge.ets', 'utf8');
ok(bridgeSource.includes("if (!session.pointColor.isBypass()) return GpuShaderBridge.decline('point-color');"),
  'the GPU path declines with reason=point-color while the stage is active');
const workerSource = fs.readFileSync('entry/src/main/ets/edit/engine/ProcessWorker.ets', 'utf8');
ok(workerSource.includes('applyPointColorBuffer(result, width, height, params.pointColor)'),
  'the worker applies the stage in place');
ok(workerSource.indexOf('applyPointColorBuffer(result') < workerSource.indexOf('applyLocalContrast(result'),
  'and does so BEFORE the detail stage, matching the assertion above');
const fallbackSource = fs.readFileSync('entry/src/main/ets/edit/engine/ImageProcessor.ets', 'utf8');
ok(fallbackSource.includes('applyPointColorBuffer(pool.result, width, height, pointColorSamples)'),
  'the UI-thread fallback applies the same stage, so both CPU paths agree');
ok(fallbackSource.includes('session.pointColor.samples'), 'the fallback reads the samples with no conversion');
const panelSource = fs.readFileSync('entry/src/main/ets/components/PointColorPanel.ets', 'utf8');
// Check the CODE, not the prose: module comments legitimately describe the old
// behaviour and the picker, so a naive substring search over the whole file
// would only prove the comments exist.
const panelCode = panelSource.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
ok(!/addHsl\(\s*0\s*,\s*0\.75\s*,\s*0\.5\s*\)/.test(panelCode),
  'the 添加颜色 button no longer seeds a hard-coded red sample');
ok(!panelCode.includes('pointColor.addSample(') && !panelCode.includes('pointColor.addHsl('),
  'the panel adds nothing directly: a sample can only come from a picked source pixel');
ok(panelCode.includes('beginPointColorPick') && panelCode.includes('cancelPointColorPick'),
  'the button arms and cancels the canvas eyedropper instead');
ok(panelCode.includes('点按图片取色') && panelCode.includes('请在图片上点一下要调整的颜色'),
  'and it tells the user to tap the photo rather than silently changing a colour');
const panelCancels = (panelCode.match(/cancelPointColorPick\(\)/g) || []).length;
ok(panelCancels >= 3,
  'every panel-side cancel path (leave section, delete, clear) leaves picking mode (' + panelCancels + ' sites)');
const canvasSource = fs.readFileSync('entry/src/main/ets/components/EditorCanvas.ets', 'utf8');
const pickIntercept = canvasSource.indexOf('this.handlePointColorPickTouch(event)');
const beforeTouchCall = canvasSource.indexOf('this.handleBeforeTouch(event)');
ok(pickIntercept >= 0 && beforeTouchCall > pickIntercept,
  'the canvas routes single-finger taps to the eyedropper before the press-to-see-original path, ' +
  'so a pick never flashes the original');
const mixerSource = fs.readFileSync('entry/src/main/ets/components/ColorMixerControl.ets', 'utf8');
const mixerMounts = (mixerSource.match(/PointColorPanel\(\{/g) || []).length;
ok(mixerMounts === 1, 'the panel is embedded in the mixer (' + mixerMounts + ' mount)');
ok(mixerSource.indexOf("isDevelopSectionVisible('point-color', this.maskContext)") >= 0,
  'and is gated by the shared whole-frame predicate, so a mask never mounts it');
const adjustmentSource = fs.readFileSync('entry/src/main/ets/components/AdjustmentPanel.ets', 'utf8');
ok(adjustmentSource.indexOf('PointColorPanel') < 0,
  'the legacy adjustment panel no longer mounts point colour as a separate block');
const developSource = fs.readFileSync('entry/src/main/ets/components/DesktopDevelopPanel.ets', 'utf8');
ok(developSource.indexOf('PointColorPanel') < 0,
  'and neither does the develop panel: it has no independent point-colour section');

console.log('PASS point colour integration: model repair/drop/cap rules, the buffer entry point matching the');
console.log('     per-pixel API byte for byte, an untouched frame reported as untouched, the real worker');
console.log('     pipeline, ordering against detail with the opposite order checked to differ, sidecar and');
console.log('     undo round-trips, the GPU declining instead of omitting, and the panel wired to the canvas');
console.log('     eyedropper instead of seeding a default colour.');
console.log('NOTE the per-colour maths is check_point_color.cjs (196 checks), not this suite. The tap→pixel');
console.log('     path itself is check_point_color_picker.cjs.');
console.log(checks + ' checks passed');
