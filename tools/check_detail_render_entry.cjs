// Guard for D3: the GPU must not silently accept a session with texture /
// clarity / dehaze and publish a frame that omits them, and the real preview
// entry (renderToBuffer) must actually change pixels for clarity=0.5.
//
// Falsifiable shape: delete `decline('local-contrast')` from buildPasses and
// this test fails twice — buildPasses starts returning passes, and the stubbed
// native renderer (which returns zeros) becomes the published frame instead of
// the CPU result. That is exactly the "GPU reports success while dropping the
// detail stage" failure this guard exists for.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const modules = new Map(), storage = new Map();
let gpuCalls = 0;

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
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console: { info() {}, warn() {}, error() {}, log() {} },
    Math, Number, Date, Map, Set, ArrayBuffer, Uint8Array, Uint16Array, Uint32Array, Int32Array,
    Uint8ClampedArray, Float32Array, Float64Array, DataView, Promise, Error, JSON, Buffer,
    setTimeout, clearTimeout, setInterval, clearInterval, Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (name) => {
      if (name === 'libvivid_gpu.so') {
        return { default: {
          // A GPU that "succeeds". With no pass it copies the source (what the
          // native empty stack does); with a detail pass it would have to draw
          // something, and this test asserts that call never happens.
          renderStack: async (key, surface, input, width, height) => {
            gpuCalls++;
            if (input && input.byteLength === width * height * 4) {
              return new Uint8Array(input).slice().buffer;
            }
            return new ArrayBuffer(width * height * 4);
          },
          releaseSession: async () => new ArrayBuffer(0),
        } };
      }
      if (name === '@kit.ArkTS') {
        return { taskpool: { Task: class { static isCanceled() { return false; } constructor(f, ...a) { this.f = f; this.a = a; } }, execute: async (t) => t.f(...t.a) } };
      }
      if (name === '@kit.ImageKit') {
        return { image: { PixelMapFormat: { RGBA_8888: 3 },
          createPixelMap: async (colors, opts) => fakePixelMap(opts.size.width, opts.size.height, new Uint8Array(colors.length)) } };
      }
      if (name.startsWith('@kit.')) return { hilog: { info() {}, warn() {}, error() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { ImageProcessor: P } = load(root + '/edit/engine/ImageProcessor.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');
const { GpuShaderBridge: G } = load(root + '/edit/engine/GpuShaderBridge.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
function diff(a, b) {
  let max = 0, sum = 0, n = 0;
  for (let i = 0; i < a.length; i++) {
    if (i % 4 === 3) continue;
    const d = Math.abs(a[i] - b[i]);
    if (d > max) max = d; sum += d; n++;
  }
  return { max, mean: sum / n };
}

const W = 320, H = 240;
const source = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
  const i = (y * W + x) * 4;
  // Rich mid/high-frequency detail plus a haze gradient: all three controls
  // have something to act on.
  const base = 90 + 55 * Math.sin(x / 9) * Math.cos(y / 7) + ((x * 13 + y * 7) % 11) * 4;
  const haze = 30 * (1 - y / H);
  const v = Math.max(0, Math.min(255, Math.round(base + haze)));
  source[i] = v; source[i + 1] = Math.max(0, Math.min(255, v + 5)); source[i + 2] = Math.max(0, Math.min(255, v - 3)); source[i + 3] = 255;
}

function sessionWith(setup) {
  const s = new EditSession();
  s.layers = [new Layer('detail-guard')];
  if (setup) setup(s.detail);
  return s;
}

(async () => {
  // 1. GPU must decline the whole frame, not render it without detail.
  for (const [label, setup] of [
    ['clarity=0.5', (d) => { d.clarity = 0.5; }],
    ['texture=0.5', (d) => { d.texture = 0.5; }],
    ['dehaze=0.5', (d) => { d.dehaze = 0.5; }],
  ]) {
    const s = sessionWith(setup);
    G.lastDecline = '';
    const passes = G.buildPasses(s, W, H, true, true);
    ok(passes === null && G.lastDecline === 'local-contrast',
      label + ' must decline the GPU with reason local-contrast, got passes=' +
      (passes === null ? 'null' : passes.length) + ' reason=' + G.lastDecline);
  }

  // 2. clarity=0.5 through the REAL preview entry changes pixels, and it was the
  //    CPU that produced them (zero native GPU calls).
  const baseSession = sessionWith(null);
  const identityOut = await P.renderToBuffer(fakePixelMap(W, H, source), W, H, baseSession,
    true, () => false, true, source.buffer.slice(0), false);
  ok(identityOut !== null, 'identity renderToBuffer must return pixels');
  let identityIsSource = true;
  for (let i = 0; i < identityOut.pixels.length; i++) {
    if (identityOut.pixels[i] !== source[i]) { identityIsSource = false; break; }
  }
  if (!identityIsSource) {
    const dbg = diff(identityOut.pixels, source);
    console.log('DEBUG identity diff max=' + dbg.max + ' mean=' + dbg.mean.toFixed(3));
    for (let i = 0; i < identityOut.pixels.length; i++) {
      if (identityOut.pixels[i] !== source[i]) {
        console.log('DEBUG first diff i=' + i + ' got=' + identityOut.pixels[i] + ' want=' + source[i]);
        break;
      }
    }
  }
  ok(identityIsSource, 'with all detail at default, renderToBuffer must equal the source');

  gpuCalls = 0;
  const claritySession = sessionWith((d) => { d.clarity = 0.5; });
  const clarityOut = await P.renderToBuffer(fakePixelMap(W, H, source), W, H, claritySession,
    true, () => false, true, source.buffer.slice(0), false);
  ok(clarityOut !== null, 'clarity renderToBuffer must return pixels');
  const delta = diff(clarityOut.pixels, identityOut.pixels);
  ok(delta.max >= 8 && delta.mean >= 1,
    'clarity=0.5 must change the rendered frame through renderToBuffer: max=' + delta.max +
    ' mean=' + delta.mean.toFixed(2));
  ok(gpuCalls === 0, 'the detail frame must be produced by the CPU path, not by a GPU pass that omits it (gpu calls=' + gpuCalls + ')');

  // 3. The snapshot carries detail unchanged into the worker parameters.
  const snap = P.snapshot(claritySession);
  ok(snap.detail.clarity === 0.5, 'snapshot must copy detail.clarity (got ' + snap.detail.clarity + ')');
  const params = P.buildWorkerParams(snap, source.buffer.slice(0), W, H);
  ok(params.detail !== undefined && params.detail.clarity === 0.5,
    'buildWorkerParams must forward detail.clarity (got ' + (params.detail && params.detail.clarity) + ')');

  console.log('PASS detail render entry: GPU declines local-contrast, clarity=0.5 changes pixels through ' +
    'renderToBuffer (max=' + delta.max + ', mean=' + delta.mean.toFixed(2) + '), and snapshot forwards detail.');
  console.log(checks + ' checks passed');
})().catch((error) => { console.error('FAIL ' + error.message); process.exit(1); });
