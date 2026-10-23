// Black-and-white mixer integration: the model, the real worker pipeline, the stage's
// position relative to optics and detail, and the GPU decline.
//
// check_black_white.cjs proves the ALGORITHM (65 checks). This suite proves the WIRING,
// and holds the reason the stage runs LAST: a frame with the conversion on must be exactly
// neutral, which is only true if the chromatic-aberration correction cannot run after it.
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

const { BlackWhiteSettings } = load(root + '/edit/models/BlackWhiteSettings.ets');
const bw = load(root + '/edit/engine/BlackWhiteCore.ets');
const okc = load(root + '/edit/engine/OkLChCore.ets');
const { applyOptics, opticsDefaults } = load(root + '/edit/engine/OpticsCore.ets');
const { applyLocalContrast, localContrastIsIdentity } = load(root + '/edit/engine/LocalContrastCore.ets');
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
const W = 40, H = 28;
function colourFrame() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      b[i] = (x * 6) % 256; b[i + 1] = (y * 9) % 256; b[i + 2] = ((x * 3 + y * 5)) % 256; b[i + 3] = 255;
    }
  }
  return b;
}
const frame = colourFrame();
function countCast(pixels) {
  let cast = 0;
  for (let i = 0; i < W * H; i++) {
    const o = i * 4;
    if (pixels[o] !== pixels[o + 1] || pixels[o + 1] !== pixels[o + 2]) cast++;
  }
  return cast;
}
function mixers(values) {
  const out = [];
  for (let i = 0; i < bw.BW_BAND_COUNT; i++) out.push(i < values.length ? values[i] : 0);
  return out;
}

// --- 1. The model --------------------------------------------------------
const fresh = new BlackWhiteSettings();
ok(fresh.isBypass() && !fresh.enabled, 'a fresh document bypasses the conversion');
ok(fresh.mixers.length === bw.BW_BAND_COUNT && fresh.mixers.every((v) => v === 0),
  'with eight zero weights');
ok(fresh.bandCount() === bw.BW_BAND_COUNT, 'and it reports the engine\'s band count');
ok(fresh.bandName(0) === bw.BW_BAND_NAMES[0] && fresh.bandName(7) === bw.BW_BAND_NAMES[7],
  'and its band names come from the engine rather than a second copy in the UI');
ok(fresh.bandName(-1) === '' && fresh.bandName(99) === '',
  'an out-of-range band name is empty rather than throwing');
ok(BlackWhiteSettings.restore(undefined).isBypass(), 'a pre-mixer sidecar restores to a bypass');
const repaired = BlackWhiteSettings.restore({ enabled: true, mixers: [0.5, NaN, 9, -9] });
ok(repaired.enabled, 'the switch survives a restore');
ok(repaired.mixers.length === bw.BW_BAND_COUNT, 'a short list is padded (' + repaired.mixers.length + ')');
ok(repaired.mixers[0] === 0.5 && repaired.mixers[1] === 0 && repaired.mixers[2] === 1 &&
  repaired.mixers[3] === -1, 'and a bad weight is repaired or clamped rather than dropped');
const cloned = fresh.clone();
cloned.enabled = true; cloned.mixers[0] = 0.9;
ok(!fresh.enabled && fresh.mixers[0] === 0, 'clone deep-copies both the switch and the weight array');
const setter = new BlackWhiteSettings();
setter.setBand(0, 9); ok(setter.mixers[0] === 1, 'setBand clamps a high value');
setter.setBand(1, -9); ok(setter.mixers[1] === -1, 'and a low one');
setter.setBand(2, NaN); ok(setter.mixers[2] === 0, 'and repairs a non-finite one');
setter.setBand(99, 0.5); ok(setter.mixers.length === bw.BW_BAND_COUNT, 'an out-of-range band is ignored');
setter.setBand(-1, 0.5); ok(setter.mixers.length === bw.BW_BAND_COUNT, 'at both ends');
setter.enabled = true; setter.reset();
ok(setter.isBypass() && setter.mixers.every((v) => v === 0), 'reset returns switch and weights to defaults');
// The model must not reimplement bypass.
let mismatch = 0, probed = 0;
for (const enabled of [true, false]) {
  for (const m of [mixers([]), mixers([1]), mixers([-0.5, 0.5])]) {
    const s = new BlackWhiteSettings();
    s.enabled = enabled; s.mixers = m;
    probed++;
    if (s.isBypass() !== bw.blackWhiteIsIdentity(s.params())) mismatch++;
  }
}
ok(probed === 6 && mismatch === 0, 'the model\'s bypass agrees with the engine on all ' + probed +
  ' probed states (' + mismatch + ' disagreements)');

// --- 2. The real worker pipeline ----------------------------------------
function params(over) {
  const base = {
    source: Uint8ClampedArray.from(frame).buffer,
    width: W, height: H, layers: [], luts: [],
    cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
    rotation: 0, flipH: false, flipV: false,
    applyGeometry: false, ignoreCrop: false,
  };
  return Object.assign(base, over);
}
const bwParams = { enabled: true, mixers: mixers([0.4, 0, -0.2, 0.3]) };
const omitted = new Uint8ClampedArray(processPixels(params({})).buffer);
ok(differences(omitted, frame) === 0, 'omitting the stage reproduces the source byte for byte');
ok(differences(new Uint8ClampedArray(processPixels(params({ blackWhite: bw.blackWhiteDefaults() })).buffer),
  frame) === 0, 'and supplying the switched-off default is also byte-for-byte free');
const converted = new Uint8ClampedArray(processPixels(params({ blackWhite: bwParams })).buffer);
ok(differences(converted, frame) > 1000, 'an enabled conversion changes the frame (' +
  differences(converted, frame) + ' bytes)');
ok(countCast(converted) === 0, 'and the whole frame comes out neutral (' + countCast(converted) +
  ' coloured pixels of ' + (W * H) + ')');
ok(differences(new Uint8ClampedArray(processPixels(params({ blackWhite: bwParams })).buffer), converted) === 0,
  'two identical jobs produce identical output');

// --- 3. The stage must run AFTER optics ---------------------------------
// This is the reason for its position: chromatic-aberration correction scales red and blue
// independently, so if it ran after the conversion it would re-tint a neutral frame.
const optics = opticsDefaults();
optics.chromaticAberration = 1;
const opticsThenBw = new Uint8ClampedArray(processPixels(params({
  optics: optics, blackWhite: bwParams,
})).buffer);
ok(countCast(opticsThenBw) === 0, 'with lens correction active too, the published frame is STILL exactly ' +
  'neutral (' + countCast(opticsThenBw) + ' coloured pixels)');
// Demonstrate that the opposite order really would break it, so the assertion is not vacuous.
const opticsFirst = applyOptics(Uint8ClampedArray.from(frame), W, H, optics);
const castAfterConversionThenOptics = (() => {
  const buffered = Uint8ClampedArray.from(opticsFirst);
  bw.blackWhiteBuffer(buffered, W, H, bwParams);
  // Now optics again, which is what "conversion before optics" would have produced.
  const back = applyOptics(buffered, W, H, optics);
  return countCast(back);
})();
ok(castAfterConversionThenOptics > 0, 'while converting BEFORE the same lens correction tints ' +
  castAfterConversionThenOptics + ' pixels, so the position is doing real work and the assertion above is ' +
  'not vacuous');
// Ordering asserted against the real modules: optics then black-and-white.
const handBuffered = applyOptics(Uint8ClampedArray.from(frame), W, H, optics);
bw.blackWhiteBuffer(handBuffered, W, H, bwParams);
ok(differences(opticsThenBw, handBuffered) === 0, 'the worker composes optics then the conversion (' +
  differences(opticsThenBw, handBuffered) + ' differing bytes)');

// --- 4. The two CPU paths must agree on where it sits -------------------
const workerSource = fs.readFileSync('entry/src/main/ets/edit/engine/ProcessWorker.ets', 'utf8');
const fallbackSource = fs.readFileSync('entry/src/main/ets/edit/engine/ImageProcessor.ets', 'utf8');
function orderOf(source, needles, label) {
  const positions = needles.map((n) => source.indexOf(n));
  for (let i = 0; i < needles.length; i++) ok(positions[i] >= 0, label + ' contains "' + needles[i] + '"');
  for (let i = 1; i < positions.length; i++) {
    ok(positions[i - 1] < positions[i], label + ' orders ' + needles[i - 1] + ' before ' + needles[i]);
  }
}
orderOf(workerSource,
  ['applyPointColorBuffer(result', 'applyOkLChBuffer(result', 'applyLocalContrast(result',
    'result = applyOptics(result', 'blackWhiteBuffer(result'],
  'the worker path');
orderOf(fallbackSource,
  ['applyLutStack(pool.result', 'applyPointColorBuffer(pool.result', 'applyOkLChBuffer(pool.result',
    'pool.result.set(applyLocalContrast(pool.result', 'pool.result.set(applyOptics(pool.result',
    'blackWhiteBuffer(pool.result'],
  'the UI-thread fallback');
ok(workerSource.indexOf('blackWhiteBuffer(result') > workerSource.indexOf('result = applyOptics(result'),
  'in particular the conversion follows optics in the worker, which is the defect its position guards against');

// --- 5. Sidecar and undo -------------------------------------------------
const session = new EditSession();
session.layers = [new Layer('synthetic')];
session.blackWhite.enabled = true;
session.blackWhite.setBand(0, 0.6); session.blackWhite.setBand(4, -0.45);
const exported = JSON.parse(session.exportAdjustmentState());
ok(exported.blackWhite && exported.blackWhite.enabled === true &&
  exported.blackWhite.mixers.length === bw.BW_BAND_COUNT && Math.abs(exported.blackWhite.mixers[0] - 0.6) < 1e-12 &&
  Math.abs(exported.blackWhite.mixers[4] + 0.45) < 1e-12,
  'the exported adjustment state carries the switch and all eight weights');
const reopened = new EditSession();
reopened.layers = [new Layer('synthetic')];
ok(reopened.importAdjustmentState(JSON.stringify(exported)), 'the exported state imports back');
ok(reopened.blackWhite.enabled && Math.abs(reopened.blackWhite.mixers[0] - 0.6) < 1e-12 &&
  Math.abs(reopened.blackWhite.mixers[4] + 0.45) < 1e-12, 'with the weights intact');
const legacy = JSON.parse(JSON.stringify(exported));
delete legacy.blackWhite;
const legacySession = new EditSession();
legacySession.layers = [new Layer('synthetic')];
ok(legacySession.importAdjustmentState(JSON.stringify(legacy)), 'a sidecar written before this stage imports');
ok(legacySession.blackWhite.isBypass(), 'and opens switched off, not as an arbitrary conversion');
const undoSession = new EditSession();
undoSession.layers = [new Layer('synthetic')];
undoSession.pushUndo();
undoSession.blackWhite.enabled = true;
undoSession.pushUndo();
undoSession.blackWhite.setBand(2, 0.7);
undoSession.undo();
ok(undoSession.blackWhite.enabled && undoSession.blackWhite.mixers[2] === 0,
  'undo restores the previous weights while keeping the switch');
undoSession.undo();
ok(undoSession.blackWhite.isBypass(), 'and undo again returns to the bypass');
undoSession.redo();
ok(undoSession.blackWhite.enabled, 'redo brings it back');

// --- 6. GPU decline and the UI -------------------------------------------
const bridgeSource = fs.readFileSync('entry/src/main/ets/edit/engine/GpuShaderBridge.ets', 'utf8');
ok(bridgeSource.includes("if (!session.blackWhite.isBypass()) return GpuShaderBridge.decline('black-white');"),
  'the GPU path declines with reason=black-white while the conversion is on');
ok(bridgeSource.indexOf("decline('oklch')") < bridgeSource.indexOf("decline('black-white')"),
  'and the declines are ordered to match the pipeline');
const panelSource = fs.readFileSync('entry/src/main/ets/components/BlackWhitePanel.ets', 'utf8');
const panelCode = panelSource.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
ok(panelCode.includes('this.editSession.blackWhite.bandCount()'),
  'the panel enumerates bands from the engine rather than hard-coding eight');
ok(panelCode.includes('bandName(index)'), 'and takes each label from the engine too');
ok(panelCode.includes('pushUndo()'), 'and pushes an undo step before either control changes state');
// Falsifiable: the panel must have no single overall strength control, because the eight
// band weights are the whole control surface and a strength slider would be a second
// mechanism pretending to do the same job.
ok(!panelCode.includes('强度') && !panelCode.includes('amount'),
  'the panel offers no overall strength control: the eight band weights are the whole control surface');
const adjustmentSource = fs.readFileSync('entry/src/main/ets/components/AdjustmentPanel.ets', 'utf8');
const mounts = (adjustmentSource.match(/BlackWhitePanel\(\)/g) || []).length;
ok(mounts === 2, 'the panel is mounted in both the desktop and the phone branch (' + mounts + ' mounts)');

console.log('PASS black-and-white integration: the model takes its band count and names from the engine and');
console.log('     repairs rather than discards, the worker bypass is byte-for-byte free, an enabled conversion');
console.log('     leaves the WHOLE frame neutral even with lens correction active, and the stage is asserted to');
console.log('     run after optics on both CPU paths.');
console.log('NOTE the position is not cosmetic: the suite also measures that converting BEFORE the same');
console.log('     chromatic-aberration correction tints the frame, which is what the ordering prevents.');
console.log('NOTE no device verification and no timing. There is no Adobe parity: the band centres are the');
console.log('     conventional evenly-spaced layout, not Adobe\'s unpublished exact positions.');
console.log(checks + ' checks passed');
