// Cloud-preset restore: a sidecar stores only lutId/name/sourceUri, while the
// NP3-derived table lives only in memory. A cold start must rebuild that table
// from the bundled NP3, and a genuinely unknown preset must be reported rather
// than silently turning the layer into "no LUT".
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const rawRoot = path.resolve('entry/src/main/resources/rawfile');
const modules = new Map(), storage = new Map();
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} }; modules.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
    Uint8Array, Uint16Array, Uint32Array, Int32Array, Uint8ClampedArray, Float32Array, DataView, Promise, Error,
    setTimeout, clearTimeout, TextEncoder, TextDecoder, Buffer, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (name) => {
      if (name === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0) }, GpuOutputGeometry: {} };
      if (name === 'libvivid_ai.so') return { default: { isLoaded: () => false, release: () => {}, modelInfo: () => [] } };
      if (name === '@kit.CoreFileKit') {
        return { fileIo: {
          OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 8 },
          openSync: (p, f) => ({ fd: fs.openSync(p, f === 8 ? 'r' : 'w') }),
          closeSync: (h) => fs.closeSync(typeof h === 'number' ? h : h.fd),
          writeSync: (h, b) => fs.writeSync(typeof h === 'number' ? h : h.fd, Buffer.from(b)),
          readSync: (h, b) => fs.readSync(typeof h === 'number' ? h : h.fd, new Uint8Array(b)),
          statSync: (p) => (typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p)),
        } };
      }
      if (name === '@kit.ArkTS') {
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
      if (name === '@kit.LocalizationKit') return { resourceManager: {} };
      if (name === '@kit.ImageKit') return { image: {} };
      if (name.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      if (name.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), name + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { LutLibraryStore } = load(root + '/edit/models/LutLibrary.ets');
const { NikonCloudStore } = load(root + '/edit/models/NikonCloudCatalog.ets');
const { parseNp3, nikonCloudLut } = load(root + '/edit/models/NikonNp3.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');

// The real bundled manifest and NP3 bytes, read through the same sync
// resource-manager surface used by EntryAbility on a cold start.
const manager = {
  getRawFileContentSync(file) { return new Uint8Array(fs.readFileSync(path.join(rawRoot, file))); },
};

let checks = 0;
function ok(cond, message) { checks++; assert(cond, message); }
function maxChannel(a, b) {
  let max = 0;
  for (let i = 0; i < a.length; i++) max = Math.max(max, Math.abs(a[i] - b[i]));
  return max;
}

function snapshotWith(session, lutStack) {
  const snapshot = JSON.parse(session.createSnapshot());
  snapshot.lutStack = lutStack;
  return JSON.stringify(snapshot);
}

NikonCloudStore.attachResourceManager(manager);
LutLibraryStore.setEntries([]);
let resolverCalls = 0;
LutLibraryStore.setNikonResolver((id, name) => {
  resolverCalls++;
  return NikonCloudStore.resolveLutSync(id, name);
});

// a) Empty library, sidecar only has id/name/sourceUri: the resolver must bake
// the table synchronously. Reverting to the old `find() ?? findByName() ?? null`
// makes this assertion fail.
const first = new EditSession();
ok(first.importAdjustmentState(snapshotWith(first, [{
  id: 'lut-layer-cloud', lutId: 'nikon:at-dusk', name: 'At Dusk',
  sourceUri: 'nikon://at-dusk', enabled: true, intensity: 1,
}])), 'the sidecar must import');
const restored = first.lutStack[0];
ok(restored.lut !== null && restored.lut !== undefined, 'a cloud layer must not restore as LUT-less');
ok(restored.lut.table !== null && restored.lut.table !== undefined, 'the rebuilt cloud table must be non-null');
ok(restored.lut.table.size === 33, 'the cloud preset must bake at 33^3');
ok(restored.lut.table.values.length === 33 * 33 * 33 * 3, 'the rebuilt table must be complete');
ok(restored.lutUnavailable === false, 'a restored cloud layer must not be marked unavailable');
ok(resolverCalls === 1, 'the first cold restore must call the NP3 resolver once');

// c) Bake output must be identical to the direct NP3 bake (no parameter drift).
const look = parseNp3(new Uint8Array(fs.readFileSync(path.join(rawRoot, 'NikonCloud/np3/At dusk.NP3'))));
const direct = nikonCloudLut('at-dusk', 'At Dusk', look, 33);
ok(restored.lut.table.size === direct.table.size, 'bake size must match the direct table');
ok(maxChannel(restored.lut.table.values, direct.table.values) === 0,
  'the restored table must be byte-identical to a direct bake');

// The resolver result is cached in LutLibraryStore: a second restore must not
// rebake the same preset.
const second = new EditSession();
ok(second.importAdjustmentState(snapshotWith(second, [{
  id: 'lut-layer-cloud-2', lutId: 'nikon:at-dusk', name: 'At Dusk',
  sourceUri: 'nikon://at-dusk', enabled: true, intensity: 1,
}])), 'the second sidecar must import');
ok(second.lutStack[0].lut.table !== null, 'the second restore must reuse the cached table');
ok(resolverCalls === 1, 'the second restore must not rebake the same preset');

// b) A preset that is genuinely absent from the bundled catalog must be
// explicit, not a silent null.
const logs = [];
const originalInfo = console.info;
console.info = (...args) => { logs.push(args.map(String).join(' ')); };
let missing;
let missingSession;
try {
  const third = new EditSession();
  missingSession = third;
  ok(third.importAdjustmentState(snapshotWith(third, [{
    id: 'lut-layer-missing', lutId: 'nikon:not-in-catalog', name: 'Missing Preset',
    sourceUri: 'nikon://not-in-catalog', enabled: true, intensity: 1,
  }])), 'the missing-preset sidecar must still import');
  missing = third.lutStack[0];
} finally {
  console.info = originalInfo;
}
ok(missing.lut === null, 'an unknown preset must not invent a table');
ok(missing.lutUnavailable === true, 'an unknown preset must be marked lutUnavailable');
ok(JSON.parse(missingSession.exportAdjustmentState()).lutStack[0].lutUnavailable === true,
  'the missing state must be visible in the exported sidecar');
ok(logs.some((line) => line.includes('VIVID_LUT restore-missing id=nikon:not-in-catalog')),
  'an unknown preset must emit the restore-missing diagnostic');

console.log(`PASS cloud LUT cold restore bakes ${direct.table.size}^3 from bundled NP3, ` +
  'reuses the cache, is byte-identical to a direct bake, and reports genuinely missing presets');
console.log(`checks=${checks}`);
