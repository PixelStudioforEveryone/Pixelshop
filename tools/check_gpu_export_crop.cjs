// F4 — a cropped session must render on the GPU for BOTH preview and export.
//
// Preview called buildPasses(session, w, h, true, true) (crop allowed) while the
// export path called it with allowCrop=false, so any non-default crop made
// buildPasses decline('crop') and the whole export fell back to the CPU for a
// geometry step that is applied downstream anyway (ImageProcessor renderExport
// comments and applyGeometryTask / native remapGeometry). Measured against the
// production buildPasses, not a mock.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const modules = new Map(), storage = new Map(), logLines = [], calls = [];
const consoleStub = {
  log: (...a) => logLines.push(a.join(' ')), info: (...a) => logLines.push(a.join(' ')),
  warn: (...a) => logLines.push(a.join(' ')), error: (...a) => logLines.push(a.join(' ')),
};
const gpuNative = {
  default: {
    releaseSession: async () => {}, clearSurface: async () => {},
    renderStack: async (key, surface, input, width, height, version, passes) => {
      calls.push({ key: key, width: width, height: height, passes: passes });
      return new ArrayBuffer(width * height * 4);
    },
  },
  GpuOutputGeometry: {},
};
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} }; modules.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console: consoleStub, Math, Number, Date, Map, Set,
    ArrayBuffer, Uint8Array, Uint8ClampedArray, Uint32Array, Float32Array, Promise, Error,
    setTimeout, clearTimeout, setInterval, clearInterval, Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (name) => {
      if (name === 'libvivid_gpu.so') return gpuNative;
      if (name === '@kit.ArkTS') {
        return { taskpool: { Task: class { static isCanceled() { return false; } constructor(f, ...a) { this.f = f; this.a = a; } }, execute: async (t) => t.f(...t.a) } };
      }
      if (name === 'libvivid_pixels.so') {
        return { default: { rasterizeLinear: (w, h) => new ArrayBuffer(w * h), rasterizeRadial: (w, h) => new ArrayBuffer(w * h), remapGeometry: (b, w, h) => new ArrayBuffer(w * h * 4), composeInto() {}, invertOpacity() {}, sampleBitmap() {} } };
      }
      if (name.startsWith('@kit.')) return { hilog: { info() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');
const { GpuShaderBridge } = load(root + '/edit/engine/GpuShaderBridge.ets');

const W = 64, H = 48;
function fixtureSession() {
  const session = new EditSession();
  const layer = new Layer('base');
  layer.adjustments.exposure = 0.25;
  session.layers = [layer];
  // A real crop: a third off the left and a tenth off the bottom.
  session.cropLeft = 0.2;
  session.cropTop = 0.1;
  session.cropRight = 0.85;
  session.cropBottom = 0.9;
  return session;
}

(async () => {
  const session = fixtureSession();
  const crop = [session.cropLeft, session.cropTop, session.cropRight, session.cropBottom];

  // The preview contract: a cropped session is accepted (crop is applied by the
  // output geometry pass, not by the colour passes).
  const previewPasses = GpuShaderBridge.buildPasses(session, W, H, true, true);
  assert(Array.isArray(previewPasses) && previewPasses.length > 0,
    'the preview pass list must accept a cropped session');

  // The old export contract, asserted directly: with allowCrop=false the very
  // same session is declined. If this stops being null the forward assertion
  // below would no longer prove anything about the export change.
  const declined = GpuShaderBridge.buildPasses(session, W, H, false, true);
  assert.strictEqual(declined, null, 'allowCrop=false must still decline a cropped session (old behaviour)');

  // The real export entry point, with the native renderer recording the call.
  calls.length = 0; logLines.length = 0;
  const output = await GpuShaderBridge.renderExport(new ArrayBuffer(W * H * 4), W, H, session);
  assert(output instanceof ArrayBuffer, 'a cropped export must render on the GPU');
  assert.strictEqual(output.byteLength, W * H * 4, 'the readback is the full uncropped frame');
  assert.strictEqual(calls.length, 1, 'one native export call');
  const call = calls[0];
  assert.strictEqual(call.key, 'vivid-export', 'the whole-frame export session must be used');
  assert.strictEqual(call.width, W, 'the shader renders the uncropped width');
  assert.strictEqual(call.height, H, 'the shader renders the uncropped height');
  assert.deepStrictEqual(call.passes, previewPasses, 'export and preview use the same production pass list');
  assert(!logLines.some((line) => line.includes('reason=crop')),
    'the export must not decline the session for its crop: ' + logLines.join(' | '));

  // The crop itself is untouched: it is applied downstream, not baked here.
  assert.deepStrictEqual([session.cropLeft, session.cropTop, session.cropRight, session.cropBottom], crop,
    'rendering must not mutate the crop');
  // A rotated + flipped session was already accepted by allowTransform; keep it
  // in the same call so the combination (crop + quarter turn + flips) is covered.
  session.rotation = 90; session.flipH = true;
  calls.length = 0;
  const turned = await GpuShaderBridge.renderExport(new ArrayBuffer(W * H * 4), W, H, session);
  assert(turned instanceof ArrayBuffer, 'crop + rotation + flip must also export on the GPU');
  assert.strictEqual(calls[0].key, 'vivid-export');

  console.log('PASS cropped export: the production buildPasses accepts the crop for preview and export,');
  console.log('     the REAL renderExport returns a full uncropped frame from one native call with the same');
  console.log('     pass list as the preview, and crop+rotation+flip exports too. allowCrop=false is still');
  console.log('     asserted to decline, so the forward assertion cannot pass for an unchanged export path.');
})().catch((error) => { console.error(error); process.exitCode = 1; });
