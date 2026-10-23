// F1 — the >24MP tiled export must carry the COMPLETE native pass.
//
// The old code built each tile pass from a hand-written 20-field subset of the
// 56-field NativeGpuOptions interface, so a tiled export silently lost the LUT,
// the colour grade, the layer opacity/blend mode and maskEnabled (which turned a
// local adjustment into a global one) while the GPU still reported success.
//
// Two independent proofs, both of which the old code fails:
//   1. static: every field declared by `interface NativeGpuOptions` is assigned
//      in `copyPass`. A future field added to the interface without being copied
//      fails here immediately.
//   2. dynamic: drive the REAL `renderExport` through the tiled path with a
//      recording native stub, then compare every tile pass field-by-field with
//      the whole-frame pass list from the production `buildPasses`, allowing only
//      the mask geometry (mask/maskWidth/maskHeight/maskId) to differ.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const modules = new Map(), storage = new Map(), logLines = [], calls = [];
const consoleStub = {
  log: (...a) => logLines.push(a.join(' ')),
  info: (...a) => logLines.push(a.join(' ')),
  warn: (...a) => logLines.push(a.join(' ')),
  error: (...a) => logLines.push(a.join(' ')),
};
const gpuNative = {
  default: {
    releaseSession: async () => {},
    clearSurface: async () => {},
    renderStack: async (key, surface, input, width, height, version, passes) => {
      calls.push({ key: key, width: width, height: height, passes: passes,
        inputLength: input ? input.byteLength : 0 });
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
        return { taskpool: {
          Task: class { static isCanceled() { return false; } constructor(f, ...a) { this.f = f; this.a = a; } },
          execute: async (t) => t.f(...t.a),
        } };
      }
      if (name === 'libvivid_pixels.so') {
        return { default: {
          rasterizeLinear: (w, h) => new ArrayBuffer(w * h),
          rasterizeRadial: (w, h) => new ArrayBuffer(w * h),
          remapGeometry: (buf, w, h) => new ArrayBuffer(w * h * 4),
          composeInto() {}, invertOpacity() {}, sampleBitmap() {},
        } };
      }
      if (name.startsWith('@kit.')) return { hilog: { info() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { Layer, BlendMode } = load(root + '/edit/models/Layer.ets');
const { MaskLayer, MaskComponent, MaskComponentType } = load(root + '/edit/models/Mask.ets');
const { GpuShaderBridge } = load(root + '/edit/engine/GpuShaderBridge.ets');

const W = 6000, H = 4100; // 24.6 MP: just over the 24 MP whole-frame limit.
assert(W * H > 24000000, 'fixture must take the tiled export path');

function lutItem() {
  const values = [];
  for (let b = 0; b < 2; b++) for (let g = 0; g < 2; g++) for (let r = 0; r < 2; r++) {
    values.push(1 - r, 1 - g, 1 - b);
  }
  const table = { size: 2, values: values, domainMin: [0, 0, 0], domainMax: [1, 1, 1] };
  return {
    id: 'lut-tile', lutId: 'lut-tile', name: 'invert', sourceUri: 'test://invert',
    enabled: true, intensity: 0.75,
    lut: { id: 'lut-tile', name: 'invert', sourceUri: 'test://invert', sampleCount: 8,
      adjustments: {}, table: table },
  };
}

function fixtureSession() {
  const session = new EditSession();
  const layer = new Layer('base');
  layer.opacity = 0.7;
  layer.blendMode = BlendMode.SCREEN;
  const adj = layer.adjustments;
  adj.exposure = 0.35;
  adj.contrast = 0.2;
  adj.temperature = 0.22;
  adj.tint = -0.11;
  adj.vibrance = 0.4;
  adj.hue = 8;
  adj.toneCurve = 0.18;
  adj.mixHue = [0.1, 0, 0, 0, 0, 0, 0, 0];
  adj.calibrationRedHue = 0.1; adj.calibrationRedSaturation = 0.2;
  adj.colorGradingEnabled = true;
  adj.gradingShadowsHue = 30; adj.gradingShadowsSaturation = 0.4; adj.gradingShadowsLuminance = 0.1;
  adj.gradingMidtonesHue = -40; adj.gradingMidtonesSaturation = 0.2; adj.gradingMidtonesLuminance = -0.05;
  adj.gradingHighlightsHue = 80; adj.gradingHighlightsSaturation = 0.5; adj.gradingHighlightsLuminance = 0.2;
  adj.gradingGlobalHue = 10; adj.gradingGlobalSaturation = 0.3; adj.gradingGlobalLuminance = 0.15;
  adj.gradingBlending = 0.3; adj.gradingBalance = 0.2;
  // Parametric curve and denoise stay at identity/off: the tiled path declines
  // those (spatial or unsupported), and this test is about the pass copy.
  const local = new MaskLayer('local');
  local.adjustments.exposure = 0.2;
  local.components = [new MaskComponent(MaskComponentType.BRUSH)];
  layer.maskLayers = [local];
  session.layers = [layer];
  session.lutStack = [lutItem()];
  // The mask alpha is the expensive part of buildPasses; pre-seeding the cache is
  // exactly what a second render of the same session does, and it keeps this
  // suite fast while exercising the real slicing code.
  const cacheKey = layer.id + ':' + local.id + ':' + session.maskRevision + ':' + W + 'x' + H;
  const alpha = new Uint8ClampedArray(W * H);
  for (let i = 0; i < alpha.length; i++) alpha[i] = i % 251;
  session.maskCache.set(cacheKey, alpha);
  return session;
}

function describe(value) {
  if (value instanceof ArrayBuffer) return 'buffer:' + Buffer.from(new Uint8Array(value)).toString('hex');
  return JSON.stringify(value);
}

function fieldsOf(source) {
  const start = source.indexOf('interface NativeGpuOptions {');
  assert(start >= 0, 'NativeGpuOptions interface must exist');
  const end = source.indexOf('\n}', start);
  const body = source.slice(start, end);
  return Array.from(body.matchAll(/^\s*([A-Za-z_][A-Za-z0-9_]*)\??:/gm)).map((m) => m[1]);
}

function missingAssignments(body, fields) {
  return fields.filter((field) => {
    const pattern = new RegExp('(?:copy\\.' + field + '\\s*=)|(?:^\\s*' + field + '\\s*:)', 'm');
    return !pattern.test(body);
  });
}

(async () => {
  // ---- 1. Static guard: copyPass must cover the whole interface ---------------
  const source = fs.readFileSync('entry/src/main/ets/edit/engine/GpuShaderBridge.ets', 'utf8');
  const fields = fieldsOf(source);
  assert(fields.length >= 50, 'the interface is expected to be large, found ' + fields.length + ' fields');
  const copyStart = source.indexOf('private static copyPass(');
  assert(copyStart >= 0, 'copyPass must exist as the single copy point');
  const copyBody = source.slice(copyStart, source.indexOf('return copy;', copyStart));
  const missing = missingAssignments(copyBody, fields);
  assert.deepStrictEqual(missing, [],
    'copyPass must assign every NativeGpuOptions field; missing: ' + missing.join(', '));
  // Anti-tautology: the same check must FAIL when one assignment is removed, so a
  // green run cannot be an artefact of a matcher that always matches.
  const withered = copyBody.replace(/\n\s*copy\.gradingBalance = pass\.gradingBalance;/, '');
  const detected = missingAssignments(withered, fields);
  assert.deepStrictEqual(detected, ['gradingBalance'],
    'the coverage check must detect a field whose assignment was removed');
  // The tile path must actually use copyPass rather than build a literal again.
  const tileStart = source.indexOf('private static async renderExportTiled(');
  assert(tileStart >= 0, 'renderExportTiled must exist');
  const tileBody = source.slice(tileStart, source.indexOf('\n  }', source.indexOf('tilePasses.push', tileStart)));
  assert(tileBody.includes('GpuShaderBridge.copyPass(wholePass)'),
    'the tile loop must copy the whole pass through copyPass');

  // ---- 2. Dynamic guard: real tiled export, field-by-field -------------------
  const session = fixtureSession();
  const wholePasses = GpuShaderBridge.buildPasses(session, W, H, true, true);
  assert(Array.isArray(wholePasses) && wholePasses.length >= 3,
    'fixture must produce layer, mask and LUT passes (got ' + (wholePasses ? wholePasses.length : null) + ')');
  // The dropped fields must be non-default in the fixture, otherwise the
  // comparison below could not distinguish the old subset from the new copy.
  assert(wholePasses.some((p) => p.lutEnabled === true), 'fixture must enable a LUT');
  assert(wholePasses.some((p) => p.gradingEnabled === true), 'fixture must enable colour grading');
  assert(wholePasses.some((p) => p.opacity === 0.7 && p.blendMode === BlendMode.SCREEN),
    'fixture must set layer opacity and a non-normal blend mode');
  assert(wholePasses.some((p) => p.maskEnabled === true && p.maskWidth === W),
    'fixture must contain a full-frame mask pass');

  calls.length = 0;
  const output = await GpuShaderBridge.renderExport(new ArrayBuffer(W * H * 4), W, H, session);
  assert(output instanceof ArrayBuffer, 'the tiled export must succeed');
  assert.strictEqual(output.byteLength, W * H * 4, 'the tiled export must return the full frame');
  const tileCount = Math.ceil(W * H / 16000000);
  assert.strictEqual(calls.length, tileCount, 'one native call per tile (' + calls.length + ' vs ' + tileCount + ')');

  const maskedFields = ['mask', 'maskWidth', 'maskHeight', 'maskId'];
  for (let t = 0; t < calls.length; t++) {
    const call = calls[t];
    assert.strictEqual(call.key, 'vivid-export-tile', 'tiles must use the tile session key');
    assert.strictEqual(call.height, H, 'a tile spans the full height');
    assert.strictEqual(call.passes.length, wholePasses.length, 'every tile must carry every pass');
    for (let p = 0; p < wholePasses.length; p++) {
      const tile = call.passes[p], whole = wholePasses[p];
      for (const field of fields) {
        if (maskedFields.indexOf(field) >= 0) continue;
        const a = tile[field], b = whole[field];
        if (a instanceof ArrayBuffer || b instanceof ArrayBuffer) {
          assert(a instanceof ArrayBuffer && b instanceof ArrayBuffer, 'tile pass ' + p + ' field ' + field + ' buffer kind');
          assert.strictEqual(describe(a), describe(b), 'tile pass ' + p + ' field ' + field + ' must match the whole pass');
        } else if (Array.isArray(a) || Array.isArray(b)) {
          assert.deepStrictEqual(a, b, 'tile pass ' + p + ' field ' + field + ' must match the whole pass');
        } else {
          assert.strictEqual(a, b, 'tile pass ' + p + ' field ' + field + ' must match the whole pass');
        }
      }
      if (whole.maskEnabled === true && whole.mask && whole.maskWidth === W && whole.maskHeight === H) {
        assert.strictEqual(tile.maskEnabled, true,
          'maskEnabled must survive the tile copy (it used to be dropped, turning a local edit global)');
        assert.strictEqual(tile.maskHeight, H, 'tile mask keeps the full height');
        assert.strictEqual(tile.maskWidth, call.width, 'tile mask width is the tile width');
        assert(tile.mask instanceof ArrayBuffer, 'tile mask must be a sliced buffer');
        // Content: exactly the column range of the whole mask.
        const x0 = t * Math.ceil(W / tileCount);
        const expected = new Uint8Array(tile.mask.byteLength);
        const wholeMask = new Uint8Array(whole.mask);
        const tw = tile.maskWidth;
        for (let y = 0; y < H; y++) expected.set(wholeMask.subarray(y * W + x0, y * W + x0 + tw), y * tw);
        assert.strictEqual(Buffer.from(new Uint8Array(tile.mask)).compare(Buffer.from(expected)), 0,
          'tile mask must be exactly the tile column range of the full mask');
        assert(Number.isInteger(tile.maskId) && tile.maskId > 0,
          'a sliced mask needs its own asset id');
        assert.notStrictEqual(tile.maskId, whole.maskId,
          'the sliced mask must NOT reuse the whole mask asset id (the native texture cache keys on it)');
      } else {
        assert.strictEqual(tile.mask, whole.mask, 'passes without a mask must copy the mask field unchanged');
        assert.strictEqual(tile.maskEnabled, whole.maskEnabled, 'passes without a mask keep maskEnabled unchanged');
      }
    }
  }

  console.log('PASS tiled export pass copy: copyPass assigns all ' + fields.length +
    ' NativeGpuOptions fields, and ' + calls.length + ' tiles of ' + W + 'x' + H +
    ' each carry all ' + wholePasses.length + ' passes field-for-field, with only the mask');
  console.log('     geometry sliced (maskEnabled kept, new asset id per tile so the native texture cache cannot');
  console.log('     serve the previous tile\'s mask). LUT, colour grading, opacity and blend mode are asserted');
  console.log('     present in the fixture, so the old 20-field subset would fail every comparison above.');
})().catch((error) => { console.error(error); process.exitCode = 1; });
