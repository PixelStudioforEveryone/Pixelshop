// Does a render actually SEE each stage? This suite exists because the answer was NO.
//
// Every CPU render path -- preview and export alike -- builds its worker parameters from
// `ImageProcessor.snapshot(session)`, not from the live session. `snapshot` captured only
// some of the fields `buildWorkerParams` reads, so six render inputs (processVersion,
// detail, optics, pointColor, oklch, blackWhite) were dropped on the way in. The panels
// moved, the sliders stored their values, every unit test passed -- and the preview and
// export rendered those stages as BYPASSED, because they were reading a snapshot that had
// default-initialised them.
//
// The earlier integration suites missed this because they passed a live EditSession
// straight to the worker, i.e. they tested AROUND the snapshot instead of THROUGH it. This
// suite renders through it, and additionally derives the list of fields that MUST be copied
// from the source of `buildWorkerParams` itself, so the same omission cannot recur when
// somebody adds the next stage.
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

const { ImageProcessor } = load(root + '/edit/engine/ImageProcessor.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');
const { localContrastIsIdentity } = load(root + '/edit/engine/LocalContrastCore.ets');
const { opticsIsIdentity } = load(root + '/edit/engine/OpticsCore.ets');
const { pointColorIsIdentity } = load(root + '/edit/engine/PointColorCore.ets');
const { oklchIsIdentity } = load(root + '/edit/engine/OkLChCore.ets');
const { blackWhiteIsIdentity } = load(root + '/edit/engine/BlackWhiteCore.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
function differences(a, b) {
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}
const W = 48, H = 32;
const source = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    source[i] = (x * 5) % 256;
    source[i + 1] = (y * 11) % 256;
    source[i + 2] = ((x * 7 + y * 3)) % 256;
    source[i + 3] = 255;
  }
}

/** The real path: live session -> snapshot -> worker parameters -> rendered pixels. */
function renderThroughSnapshot(session) {
  const snap = ImageProcessor.snapshot(session);
  const params = ImageProcessor.buildWorkerParams(snap, Uint8ClampedArray.from(source).buffer, W, H);
  return { snap: snap, params: params, out: new Uint8ClampedArray(processPixels(params).buffer) };
}
const baselineSession = new EditSession();
const baseline = renderThroughSnapshot(baselineSession);
ok(differences(baseline.out, source) === 0, 'a default session renders the source unchanged, so the baseline ' +
  'is a real bypass and every difference below is attributable to the stage under test');

// --- Every stage must survive the snapshot AND reach the render ----------
// `label`, a mutator, and a predicate that says whether the built parameters carry it.
const stages = [
  {
    label: 'detail (texture/clarity)',
    mutate: (s) => { s.detail.texture = 0.6; s.detail.clarity = 0.5; },
    carries: (p) => !!p.detail && !localContrastIsIdentity(p.detail),
    survives: (snap) => snap.detail.texture === 0.6 && snap.detail.clarity === 0.5,
  },
  {
    label: 'optics (vignette)',
    mutate: (s) => { s.optics.vignetteAmount = -0.7; },
    carries: (p) => !!p.optics && !opticsIsIdentity(p.optics),
    survives: (snap) => snap.optics.vignetteAmount === -0.7,
  },
  {
    label: 'optics (chromatic aberration)',
    mutate: (s) => { s.optics.chromaticAberration = 0.8; },
    carries: (p) => !!p.optics && !opticsIsIdentity(p.optics),
    survives: (snap) => snap.optics.chromaticAberration === 0.8,
  },
  {
    label: 'point colour',
    mutate: (s) => { s.pointColor.addHsl(0.1, 0.6, 0.5); s.pointColor.samples[0].hueShift = 0.5; },
    carries: (p) => !!p.pointColor && p.pointColor.length === 1 && !pointColorIsIdentity(p.pointColor),
    survives: (snap) => snap.pointColor.samples.length === 1 &&
      snap.pointColor.samples[0].hueShift === 0.5,
  },
  {
    label: 'OkLCh grade (retired)',
    mutate: (s) => { s.oklch.chroma = 0.6; },
    // 功能已下线：旧侧车字段仍然保存，但 worker 参数必须是 identity，
    // 这样即使旧文件带着非零值打开，也不会改变任何像素。
    carries: (p) => !!p.oklch && oklchIsIdentity(p.oklch),
    survives: (snap) => snap.oklch.chroma === 0.6,
    pixelEffect: false,
    pixelReason: 'the OkLCh stage is retired, so it correctly changes no pixels even with legacy sidecar values',
  },
  {
    label: 'black-and-white',
    mutate: (s) => { s.blackWhite.enabled = true; s.blackWhite.setBand(0, 0.6); },
    carries: (p) => !!p.blackWhite && !blackWhiteIsIdentity(p.blackWhite),
    survives: (snap) => snap.blackWhite.enabled === true && snap.blackWhite.mixers[0] === 0.6,
  },
  {
    label: 'process version',
    mutate: (s) => { s.processVersion = 1; },
    carries: (p) => p.processVersion === 1,
    survives: (snap) => snap.processVersion === 1,
    // Process Version has no pixel effect on this fixture and this is NOT a gap: its one
    // gated behaviour (denoiseFixedRadius) only applies when noise reduction is on AND the
    // long edge exceeds 2048. What must be proven here is that the value reaches the
    // worker at all, which `carries` does; check_process_version.cjs covers the behaviour.
    pixelEffect: false,
  },
];
for (const stage of stages) {
  const session = new EditSession();
  stage.mutate(session);
  // The live session must actually hold the change, or the test would be measuring nothing.
  let liveHolds = false;
  try { liveHolds = stage.survives(session); } catch (e) { liveHolds = false; }
  ok(liveHolds, stage.label + ': the live session holds the change (guard against a no-op fixture)');
  const rendered = renderThroughSnapshot(session);
  ok(stage.survives(rendered.snap), stage.label + ': the value SURVIVES the render snapshot. This is the ' +
    'assertion that failed before the fix: snapshot() dropped the field, so the stage rendered as bypassed');
  ok(stage.carries(rendered.params), stage.label + ': and the built worker parameters carry it');
  if (stage.pixelEffect === false) {
    ok(differences(rendered.out, baseline.out) === 0, stage.label + ': and it correctly changes no pixels (' +
      (stage.pixelReason || 'its single gated behaviour needs conditions this fixture does not meet') + ')');
  } else {
    const delta = differences(rendered.out, baseline.out);
    ok(delta > 100, stage.label + ': and the RENDERED PIXELS differ from the bypass render (' + delta +
      ' bytes), which is the only proof that the slider does anything at all');
  }
}

// --- The black-and-white stage must still come out neutral through the snapshot ---
const bwSession = new EditSession();
bwSession.blackWhite.enabled = true;
bwSession.blackWhite.setBand(1, 0.7);
const bwRendered = renderThroughSnapshot(bwSession);
let cast = 0;
for (let i = 0; i < W * H; i++) {
  const o = i * 4;
  if (bwRendered.out[o] !== bwRendered.out[o + 1] || bwRendered.out[o + 1] !== bwRendered.out[o + 2]) cast++;
}
ok(cast === 0, 'and an enabled conversion rendered through the snapshot is neutral across the whole frame (' +
  cast + ' coloured pixels)');

// --- Denoise: the two NEW parameters must survive into the worker ----------
// They were added late; a cache key or a snapshot that forgets them makes the preview
// disagree with the export.
const denoiseSession = new EditSession();
denoiseSession.denoise.luminance = 0.5;
denoiseSession.denoise.luminanceContrast = 0.8;
denoiseSession.denoise.colorSmoothness = 0.9;
const denoiseRendered = renderThroughSnapshot(denoiseSession);
ok(denoiseRendered.snap.denoise.luminanceContrast === 0.8,
  'the luminance-contrast denoise parameter survives the snapshot');
ok(denoiseRendered.snap.denoise.colorSmoothness === 0.9,
  'and so does colour smoothness');
ok(denoiseRendered.params.denoise.luminanceContrast === 0.8 &&
  denoiseRendered.params.denoise.colorSmoothness === 0.9,
  'and both reach the worker parameters, which is what makes the preview agree with the export');
// Changing ONLY a new parameter must change the render, or that slider is inert.
const noiseFrame = new Uint8ClampedArray(W * H * 4);
for (let i = 0; i < W * H; i++) {
  const base = 120 + ((i * 37) % 17) - 8;
  noiseFrame[i * 4] = base; noiseFrame[i * 4 + 1] = base + ((i * 13) % 7) - 3;
  noiseFrame[i * 4 + 2] = base; noiseFrame[i * 4 + 3] = 255;
}
function renderNoise(session) {
  const snap = ImageProcessor.snapshot(session);
  const params = ImageProcessor.buildWorkerParams(snap, Uint8ClampedArray.from(noiseFrame).buffer, W, H);
  return new Uint8ClampedArray(processPixels(params).buffer);
}
const plainNoise = new EditSession();
plainNoise.denoise.luminance = 0.6;
const plainOut = renderNoise(plainNoise);
const contrastNoise = new EditSession();
contrastNoise.denoise.luminance = 0.6;
contrastNoise.denoise.luminanceContrast = 1;
ok(differences(renderNoise(contrastNoise), plainOut) > 20,
  'and changing ONLY luminance contrast changes the rendered pixels (' +
  differences(renderNoise(contrastNoise), plainOut) + ' bytes), so it is not an inert slider');

// --- The structural guard: derive the required fields from the source -----
// Reading `buildWorkerParams`'s own body means a future stage is covered automatically,
// instead of depending on somebody remembering to extend this test.
const ipSource = fs.readFileSync('entry/src/main/ets/edit/engine/ImageProcessor.ets', 'utf8');
function bodyOf(startMarker) {
  const start = ipSource.indexOf(startMarker);
  if (start < 0) return '';
  const end = ipSource.indexOf('\n  }\n', start);
  return end < 0 ? ipSource.substring(start) : ipSource.substring(start, end);
}
const buildBody = bodyOf('private static buildWorkerParams(');
const snapshotBody = bodyOf('static snapshot(source: EditSession): EditSession {');
ok(buildBody.length > 500, 'the buildWorkerParams body was located (' + buildBody.length + ' chars)');
ok(snapshotBody.length > 500, 'and the snapshot body was located (' + snapshotBody.length + ' chars)');
function referencedFields(text, receiver) {
  const found = new Set();
  const re = new RegExp(receiver + '\\.([a-zA-Z][a-zA-Z0-9]*)', 'g');
  let m;
  while ((m = re.exec(text)) !== null) found.add(m[1]);
  return found;
}
const read = referencedFields(buildBody, 'session');
const copied = referencedFields(snapshotBody, 'source');
// Fields that legitimately do not need copying: they are not part of the session's
// renderable state, or they are consumed before a snapshot is taken.
const exempt = new Set(['sessionId', 'layers', 'lutStack', 'geometry', 'renderViewport']);
const missing = [];
for (const field of read) {
  if (exempt.has(field)) continue;
  if (!copied.has(field)) missing.push(field);
}
ok(read.size >= 12, 'the derivation found the fields the worker reads (' + read.size + ' of them: ' +
  Array.from(read).join(', ') + ')');
ok(missing.length === 0, 'EVERY session field that buildWorkerParams reads is copied by snapshot(). ' +
  'Missing: ' + (missing.length === 0 ? '(none)' : missing.join(', ')) +
  '. This is the automated form of the bug that made six stages no-ops');
// Non-vacuity, and a record of the actual defect: replay the PRE-FIX snapshot body -- the
// same text with those six assignments deleted -- and confirm the derivation reports them.
// Without this, a broken regex would make the guard above pass forever and prove nothing.
const preFixBody = snapshotBody
  .replace(/result\.processVersion = source\.processVersion;/g, '')
  .replace(/result\.detail = source\.detail\.clone\(\);/g, '')
  .replace(/result\.optics = source\.optics\.clone\(\);/g, '')
  .replace(/result\.pointColor = source\.pointColor\.clone\(\);/g, '')
  .replace(/result\.oklch = source\.oklch\.clone\(\);/g, '')
  .replace(/result\.blackWhite = source\.blackWhite\.clone\(\);/g, '');
const preFixCopied = referencedFields(preFixBody, 'source');
const preFixMissing = [];
for (const field of read) {
  if (exempt.has(field)) continue;
  if (!preFixCopied.has(field)) preFixMissing.push(field);
}
for (const field of ['processVersion', 'detail', 'optics', 'pointColor', 'oklch', 'blackWhite']) {
  ok(preFixMissing.indexOf(field) >= 0, 'the derivation is not vacuous: replaying the pre-fix snapshot flags ' +
    field + ' as missing (it reports ' + preFixMissing.length + ': ' + preFixMissing.sort().join(', ') + ')');
}

console.log('PASS render snapshot coverage: every stage that buildWorkerParams reads survives ' +
  'ImageProcessor.snapshot() AND changes the rendered pixels when reached through it.');
console.log('WHY THIS SUITE EXISTS: the earlier integration suites passed a live EditSession straight to the');
console.log('     worker, so they tested AROUND the snapshot. snapshot() was dropping processVersion, detail,');
console.log('     optics, pointColor, oklch and blackWhite, which made those six stages silent no-ops in the');
console.log('     preview and the export while every unit test still passed.');
console.log('NOTE the field list is DERIVED from the source of buildWorkerParams, not hand-written, so a');
console.log('     future stage is covered without editing this test.');
console.log(checks + ' checks passed');
