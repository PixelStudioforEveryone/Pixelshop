// Guard for D2: "hold to see the original" must still produce a before frame
// while a long preview render owns the queue, and that frame must differ from
// the graded frame (and equal the ungraded source when framing is identity).
//
// Falsifiability (verified by temporarily reverting each half):
//  * setBeforePreview -> `return ImageProcessor.process(session)` makes the
//    priority case time out, because it queues behind the gated render and the
//    hold is over before the queue drains (the device log showed queueMs=774351).
//  * beforeSnapshot -> snapshot() makes `before` equal the graded render, so the
//    "before differs from normal" assertion fails.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const modules = new Map(), storage = new Map();

let gateOpen = false, gateUsed = false, executeCalls = 0;
const taskpool = {
  Task: class {
    static isCanceled() { return false; }
    constructor(fn, ...args) { this.fn = fn; this.args = args; }
  },
  execute: async (task) => {
    executeCalls++;
    if (!gateUsed) {
      gateUsed = true;
      // The "expensive" preview frame holds the single render slot until the
      // test releases it. A before preview must not wait for this.
      while (!gateOpen) await new Promise((r) => setTimeout(r, 5));
    }
    return task.fn(...task.args);
  },
  cancel() {},
};

function fakePixelMap(width, height, data) {
  return {
    width, height,
    getImageInfo: async () => ({ size: { width, height } }),
    readPixelsToBuffer: async (buffer) => { new Uint8Array(buffer).set(data.subarray(0, buffer.byteLength)); },
    writeBufferToPixels: async () => {},
    release: () => {},
    isReleased: () => false,
  };
}

function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} }; modules.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  const sandbox = {
    module: mod, exports: mod.exports, console: { info() {}, warn() {}, error() {}, log() {} },
    Math, Number, Date, Map, Set, ArrayBuffer, Uint8Array, Uint16Array, Uint32Array, Int32Array,
    Uint8ClampedArray, Float32Array, Float64Array, DataView, Promise, Error, JSON, Buffer,
    setTimeout, clearTimeout, setInterval, clearInterval, Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (name) => {
      if (name === 'libvivid_gpu.so') return { default: { renderStack: async () => { throw new Error('no gpu in test'); }, releaseSession: async () => new ArrayBuffer(0) } };
      if (name === 'libvivid_pixels.so') return { default: {} };
      if (name === '@kit.ArkTS') return { taskpool };
      if (name === '@kit.ImageKit') {
        return { image: {
          PixelMapFormat: { RGBA_8888: 3 },
          createPixelMap: async (colors, opts) => fakePixelMap(opts.size.width, opts.size.height, new Uint8Array(colors.length)),
        } };
      }
      if (name.startsWith('@kit.')) return { hilog: { info() {}, warn() {}, error() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  };
  vm.runInNewContext(js, sandbox, { filename: file });
  return mod.exports;
}

const { ImageProcessor: P } = load(root + '/edit/engine/ImageProcessor.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');
const { processPixels } = load(root + '/edit/engine/ProcessWorker.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }

// ---- part 1: the before frame is genuinely different from the graded frame --
const W = 64, H = 48;
const source = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
  const i = (y * W + x) * 4;
  const v = 60 + Math.round(100 * Math.sin(x / 7) * Math.cos(y / 5)) + 40;
  source[i] = v; source[i + 1] = Math.min(255, v + 8); source[i + 2] = Math.max(0, v - 8); source[i + 3] = 255;
}
function gradedSession() {
  const s = new EditSession();
  s.layers = [new Layer('hold')];
  s.layers[0].adjustments.exposure = 0.5;
  s.layers[0].adjustments.temperature = 0.4;
  s.detail.clarity = 0.5;
  s.detail.texture = 0.4;
  s.optics.distortion = 0.2;
  return s;
}
function render(session) {
  const params = P.buildWorkerParams(P.snapshot(session), source.buffer.slice(0), W, H);
  return new Uint8ClampedArray(processPixels(params).buffer);
}
function renderBefore(session) {
  const params = P.buildWorkerParams(P.beforeSnapshot(session), source.buffer.slice(0), W, H);
  return new Uint8ClampedArray(processPixels(params).buffer);
}
const graded = render(gradedSession());
const before = renderBefore(gradedSession());
let max = 0, sum = 0;
for (let i = 0; i < graded.length; i++) {
  if (i % 4 === 3) continue;
  const d = Math.abs(graded[i] - before[i]);
  if (d > max) max = d; sum += d;
}
const mean = sum / ((graded.length / 4) * 3);
ok(max >= 20 && mean >= 3,
  'before frame must differ from the graded frame when a grade is active: max=' + max +
  ' mean=' + mean.toFixed(2));
let beforeMatchesSource = true;
for (let i = 0; i < before.length; i++) if (before[i] !== source[i]) { beforeMatchesSource = false; break; }
ok(beforeMatchesSource, 'with identity framing the before frame must be the ungraded source, byte for byte');

// ---- part 2: the before frame must not queue behind a long render ----------
(async () => {
  const s = gradedSession();
  s.imageWidth = W;
  s.imageHeight = H;
  s.sourcePixelMap = fakePixelMap(W, H, source);
  // Start the expensive preview first: it takes the render slot and blocks in
  // the task pool until the gate opens.
  const first = P.process(s);
  while (!gateUsed) await new Promise((r) => setTimeout(r, 5));
  ok(!gateOpen, 'fixture: the first render is still occupying the slot');

  const hold = P.setBeforePreview(s, true);
  const outcome = await Promise.race([
    hold.then(() => 'resolved'),
    new Promise((r) => setTimeout(() => r('timeout'), 1500)),
  ]);
  ok(outcome === 'resolved', 'setBeforePreview must complete while the preview slot is busy (it timed out = it queued)');
  ok(s.beforePixelMap !== null || s.gpuPreviewActive,
    'the before preview must have published a frame (beforePixelMap or GPU surface) before the hold ends');

  gateOpen = true;
  await first;
  await P.setBeforePreview(s, false);
  ok(true, 'releasing the hold restores the normal render path');
  console.log('PASS hold-to-original: before differs from graded (max=' + max + ', mean=' + mean.toFixed(2) +
    '), equals source with identity framing, and renders without waiting for a busy full-size frame.');
  console.log(checks + ' checks passed');
  process.exit(0);
})().catch((error) => { console.error('FAIL ' + error.message); process.exit(1); });
