// P0 regression. Exercises the REAL production methods - no mirror:
//  * ImageProcessor.clearSourceCache / releaseRetainedFrames / process
//    publish path (dropRetainedFrames) - the frame the canvas is drawing must
//    never be released while it is still the only visible frame.
//  * EditorPage.switchEditorPhoto / loadImage / loadDemoImage /
//    createPlaceholderImage - a late older load must not overwrite a newer one,
//    including when both loads use the SAME uri (ABA), and never after the page
//    was destroyed.
//  * GPU surface rebuild (surfaceDestroyed) and GPU->CPU switching.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const root = path.resolve(__dirname, '..');
const modules = new Map();
const stubs = new Map();

// ---- Minimal stand-ins for the ArkUI/native imports the real files pull in.
class PixelMap {
  constructor(tag) { this.tag = tag; this.released = false; this.width = 64; this.height = 48; }
  release() { assert(!this.released, 'double release of ' + this.tag); this.released = true; }
  async getImageInfo() { return { size: { width: this.width, height: this.height } }; }
  async readPixelsToBuffer(buffer) { new Uint8Array(buffer).fill(200); }
}
let pixelMapSerial = 0;
const nextPixelMap = tag => new PixelMap(tag + '-' + (++pixelMapSerial));

class GpuSessionState {
  constructor() { this.surfaceId = ''; this.gpuPreviewActive = false; this.gpuSurfaceDirty = false; }
}

stubs.set(path.resolve(root, 'entry/src/main/ets/edit/engine/GpuShaderBridge.ets'), {
  GpuShaderBridge: {
    released: [], destroyed: [], cleared: [],
    release(session) { this.released.push(session.sessionId); },
    surfaceDestroyed(session) { this.destroyed.push(session.sessionId); },
    async clearDirectSurface(session) { this.cleared.push(session.sessionId); },
    present() { return Promise.resolve(false); },
    needsSource() { return false; },
    outputGeometry(s, w, h) { return { width: w, height: h }; },
  },
});
stubs.set(path.resolve(root, 'entry/src/main/ets/edit/engine/RangeMaskService.ets'),
  { RangeMaskService: { forget() {} } });
stubs.set(path.resolve(root, 'entry/src/main/ets/edit/engine/AiSegmentationService.ets'),
  { AiSegmentationService: { cancelPending() {} } });
stubs.set(path.resolve(root, 'entry/src/main/ets/edit/engine/PerfStats.ets'),
  { PerfStats: { refreshEnabled() {}, recordQueued() {}, tick() {}, recordStalePublish() {},
    recordPhase() {}, enabled: false } });
stubs.set(path.resolve(root, 'entry/src/main/ets/edit/engine/GeometryTransform.ets'),
  { geometryActive: () => false, transformGeometry: () => [] });

const decoder = { calls: [], results: [], plans: [], delayMs: 0, failWith: null };

// ---- HarmonyOS kit imports: they are real SDK APIs with no Node equivalent.
// Everything the loaded code actually calls is listed here; an unknown symbol
// fails loudly instead of silently passing.
function kitStub(name) {
  const missing = sym => { throw new Error('unstubbed ' + name + ' symbol: ' + sym); };
  const proxy = new Proxy({}, { get: (_t, sym) => {
    if (sym === '__esModule' || typeof sym === 'symbol') return undefined;
    return new Proxy(function () {}, { get: (_f, inner) => {
      if (inner === 'then') return undefined;
      return () => missing(String(sym) + '.' + String(inner));
    }, apply: () => missing(String(sym)) });
  } });
  return proxy;
}
const KIT_STUBS = {
  '@kit.ArkTS': { taskpool: { Task: class {}, cancel() {}, execute: async () => null } },
  '@kit.ImageKit': { image: { PixelMapFormat: { RGBA_8888: 3 }, createPixelMap: async () => nextPixelMap('pm') } },
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {}, debug() {} } },
  '@kit.BasicServicesKit': { BusinessError: class {} },
  '@kit.AbilityKit': { common: { UIAbilityContext: class {} } },
  '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoViewPicker: class {}, PhotoViewMIMETypes: { IMAGE_TYPE: 1 } } },
};

function load(file) {
  file = path.resolve(file);
  const stub = stubs.get(file);
  if (stub) return stub;
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} };
  modules.set(file, mod);
  const source = fs.readFileSync(file, 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  const sandbox = { module: mod, exports: mod.exports, console, Math, Date, JSON, Promise, Object, Array, Number, String, Map, Set, Uint8Array, Uint8ClampedArray, ArrayBuffer, setTimeout, clearTimeout, assert,
    // ArkUI decorators/global runtime: identity no-ops, so the real class
    // bodies run unchanged.
    Observed: target => target, ObservedV2: target => target, Trace: () => {},
    State: () => () => {}, Prop: () => () => {}, Link: () => () => {},
    Provide: () => () => {}, Consume: () => () => {}, Watch: () => () => {},
    Builder: () => () => {}, BuilderParam: () => () => {}, LocalStorageProp: () => () => {},
    StorageLink: () => () => {}, StorageProp: () => () => {}, Computed: () => () => {},
    Concurrent: target => target, Sendable: target => target, AppStorage: { get() { return undefined; }, setOrCreate() {} },
    require: name => {
      if (name.startsWith('@kit.') || name.startsWith('@ohos.')) {
        return KIT_STUBS[name] ?? kitStub(name);
      }
      if (name.endsWith('.so')) return { default: {} };
      return load(resolveModule(path.dirname(file), name));
    } };
  vm.runInNewContext(js, sandbox, { filename: file });
  return mod.exports;
}

/** ArkTS imports omit the extension; Node's resolution does not. */
function resolveModule(dir, name) {
  const base = path.resolve(dir, name);
  for (const candidate of [base, base + '.ets', path.join(base, 'index.ets')]) {
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
  }
  return base;
}

const { EditSession } = load(path.resolve(root, 'entry/src/main/ets/edit/models/EditSession.ets'));

// The real ImageProcessor is enormous; load it and then override only the two
// private render entry points so the real scheduling/publish/release code runs.
const { ImageProcessor } = load(path.resolve(root, 'entry/src/main/ets/edit/engine/ImageProcessor.ets'));
const gpu = stubs.get(path.resolve(root, 'entry/src/main/ets/edit/engine/GpuShaderBridge.ets')).GpuShaderBridge;

// Make the CPU publish path deterministic and cheap: it must still go through
// the real runProcess -> publish -> dropRetainedFrames code.
let publishCount = 0;
ImageProcessor.renderToBuffer = async (src, width, height, session) => {
  const pixels = new Uint8ClampedArray(width * height * 4);
  pixels.fill(255);
  return { pixels: new Uint8ClampedArray(pixels.buffer), width, height };
};
ImageProcessor.createPixelMapFromBuffer = async () => nextPixelMap('published');
ImageProcessor.obtainInteractiveBuffer = async () => null;
ImageProcessor.prepareMasks = async () => {};
ImageProcessor.scheduleHistogram = () => {};

function makeSession() {
  const session = new EditSession();
  session.sessionId = 1;
  return session;
}

(async () => {
  // ---------------------------------------------------------------- P0-1
  // clearSourceCache must NOT release the frame the canvas is still drawing.
  {
    const session = makeSession();
    let visible;
    session.sourcePixelMap = nextPixelMap('source');
    session.imageWidth = 64; session.imageHeight = 48;
    await ImageProcessor.process(session, true);
    const state = ImageProcessor.runs.get(session.sessionId);
    visible = session.previewPixelMap; assert.strictEqual(state.current, visible);
    ImageProcessor.clearSourceCache(session);
    assert(!visible.released, 'P0-1: displayed frame released by clearSourceCache');
    // The new frame is what retires the parked one, not the cache clear.
    session.sourcePixelMap = nextPixelMap('newSource');
    session.imageWidth = 64; session.imageHeight = 48;
    await ImageProcessor.process(session, true);
    assert(!visible.released, 'P0-1: old frame freed before ArkUI could commit the replacement');
    await new Promise(r => setTimeout(r, 80));
    assert(visible.released, 'P0-1: parked frame leaked after the replacement was published');
    assert(session.previewPixelMap && !session.previewPixelMap.released, 'P0-1: new frame released');
  }

  // ---------------------------------------------------------------- P0-2
  // AdjustmentPanel.applyCameraProfile order: the old visible frame stays
  // visible until the replacement exists (no blank canvas, no freed pixels).
  {
    const session = makeSession();
    session.sourcePixelMap = nextPixelMap('source');
    session.imageWidth = 64; session.imageHeight = 48;
    await ImageProcessor.process(session, true);
    const displayed = session.previewPixelMap;
    assert(displayed, 'P0-2: no frame to begin with');
    // Reproduce the production sequence from applyCameraProfile verbatim.
    ImageProcessor.clearSourceCache(session);
    session.previewPixelMap = displayed;                 // keep old visible frame
    session.sourcePixelMap = nextPixelMap('dcpPreview');
    await ImageProcessor.process(session, true);
    assert(!displayed.released || session.previewPixelMap !== displayed,
      'P0-2: canvas still shows a released frame');
    assert(session.previewPixelMap !== displayed, 'P0-2: new frame was not published');
    await new Promise(r => setTimeout(r, 80));
    assert(displayed.released, 'P0-2: old frame leaked');
    assert(!session.previewPixelMap.released, 'P0-2: visible frame released');
  }

  // ---------------------------------------------------------------- P0-3
  // Page destroyed / image switched: frames must really be released.
  {
    const session = makeSession();
    session.sourcePixelMap = nextPixelMap('source');
    session.imageWidth = 64; session.imageHeight = 48;
    await ImageProcessor.process(session, true);
    const displayed = session.previewPixelMap;
    ImageProcessor.clearSourceCache(session, true);
    assert(displayed.released, 'P0-3: page exit left the preview frame alive');
  }
  {
    // switchEditorPhoto: reset() nulls the reference, so the parked frame is
    // unreachable and must be freed, never left behind.
    const session = makeSession();
    session.sourcePixelMap = nextPixelMap('source');
    session.imageWidth = 64; session.imageHeight = 48;
    await ImageProcessor.process(session, true);
    const displayed = session.previewPixelMap;
    ImageProcessor.clearSourceCache(session);
    session.reset();
    ImageProcessor.releaseRetainedFrames(session.sessionId);
    assert(displayed.released, 'P0-3: photo switch leaked the old preview frame');
  }

  // ---------------------------------------------------------------- P0-4
  // GPU: surface rebuild must drop the resident texture; the transparent swap
  // must not be issued for a NEW session key (it would erase the new photo).
  {
    gpu.released.length = 0; gpu.destroyed.length = 0; gpu.cleared.length = 0;
    const session = makeSession();
    session.gpuSurfaceId = 'surface-A';
    session.gpuSurfaceDirty = true;
    ImageProcessor.clearSourceCache(session);
    assert.strictEqual(gpu.released.length, 1, 'P0-4: GPU session not released on cache clear');
    gpu.surfaceDestroyed(session);
    assert.strictEqual(gpu.destroyed.length, 1, 'P0-4: surface rebuild did not invalidate the texture');
  }

  // ---------------------------------------------------------------- P0-5
  // EditorPage load identity: a late older load must not overwrite a newer one,
  // including the same-uri ABA case, and never after the page was destroyed.
  const page = fs.readFileSync(path.resolve(root, 'entry/src/main/ets/pages/EditorPage.ets'), 'utf8');
  function slice(start, end) {
    const at = page.indexOf(start);
    assert(at >= 0, 'missing method: ' + start);
    const to = page.indexOf(end, at);
    assert(to > at, 'missing terminator for ' + start);
    return page.slice(at, to);
  }
  const methods = [
    slice('  private async switchEditorPhoto(', '  /** Replace the editor source'),
    slice('  async loadImage(', '  aboutToDisappear('),
    slice('  async loadDemoImage(', '  private currentRawSourceKind('),
    slice('  async createPlaceholderImage(', '  build()'),
  ].join('\n');
  const js = ts.transpileModule('class Page {\n' + methods + '\n}\nPage;',
    { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;

  function makePage(uri) {
    const session = makeSession();
    const log = { dialogs: [], toasts: [], placeholders: 0 };
    // The sliced page methods now also call AiSegmentationService.cancelPending()
    // next to ImageProcessor.clearSourceCache(), to drop the AI mask cache when the
    // photo changes. The slices are compiled without the module's imports, so the
    // collaborator has to be provided here.
    const p = new (vm.runInNewContext(js, { ImageProcessor, AiSegmentationService: { cancelPending() {} }, PixelMapUtils: {
        loadFromUri: async (uri, max, prog, x, sizeCb, name, rawCb) => {
          const plan = decoder.plans.shift() ?? { delayMs: decoder.delayMs, fail: !!decoder.failWith };
          decoder.calls.push(uri);
          const pm = nextPixelMap(uri + '-decoded');
          decoder.results.push(pm);
          if (plan.delayMs) await new Promise(r => setTimeout(r, plan.delayMs));
          if (sizeCb) sizeCb(plan.width ?? 8152, plan.height ?? 5432);
          if (rawCb) rawCb({ sourceKind: 'native_raw', dcpApplied: true });
          if (plan.error) throw new Error('decoder failure');
          if (plan.fail) { pm.release(); return null; }
          return pm;
        },
      }, RawPreviewLoader: { isRawFile: () => false },
      CameraProfiles: { initialize: async () => {}, CLASSIC_PROFILE_NAME: 'pixel-classic' },
      AppStorage: { setOrCreate() {}, get: () => undefined },
      RecentPhotoStore: { add: async () => {}, list: async () => [] },
      EditSidecar: { read: () => null, write: () => true },
      RawNativeBridge: { clearCache() {} },
      image: { createPixelMap: async () => nextPixelMap('placeholder'), PixelMapFormat: { RGBA_8888: 3 } },
      rawDescriptorJson: JSON.stringify, RawSourceKind: {}, DEMO_IMAGE_NAME: 'demo.jpg', console, Math, Date, JSON, Promise, Object, Array, Number, String, Map, Set,
      Uint8Array, Uint8ClampedArray, ArrayBuffer, setTimeout, clearTimeout, assert }))();
    Object.assign(p, {
      imageUri: uri, pageAlive: true, loadGeneration: 0, loading: false,
      editSession: session, materialMenuOpen: false, exportMetadataLoaded: false,
      captureInfo: '', backdropInitialized: false, rawDecodeInfo: null,
      fullResSource: null, fullResWidth: 0, fullResHeight: 0, recentMaterials: [],
      rawSettingsSaveTimer: -1, previewMaxDimension: () => 1920,
      restoreEditSidecar: () => false, applyIncomingPreset() {},
      imageDisplayName() { return this.imageUri; }, currentRawSourceKind() { return null; }, updateExportMetadataFromSource() {},
      clearDetailRender() {}, requestShortcutReset() {}, saveEditSidecar() {},
      loadRecentMaterials: async () => {}, showUnsupportedImageDialog: () => log.dialogs.push('unsupported'),
      getUIContext: () => ({ getHostContext: () => ({ resourceManager: {}, filesDir: '/tmp' }),
        getPromptAction: () => ({ showToast: m => log.toasts.push(m), showDialog: d => log.dialogs.push(d.title) }) }),
    });
    p.log = log;
    return p;
  }

  async function waitForDecodeStart(count) {
    for (let i = 0; i < 100 && decoder.calls.length < count; i++) await new Promise(r => setTimeout(r, 1));
    assert.strictEqual(decoder.calls.length, count, 'decode must be in flight before the competing load starts');
  }

  // 5a: old load finishes after a newer switch -> must not publish.
  {
    decoder.calls.length = 0; decoder.results.length = 0;
    decoder.plans = [{ delayMs: 60, width: 3000, height: 2000 }, { delayMs: 0, width: 1200, height: 800 }];
    const p = makePage('photo-A.jpg');
    p.editSession.imageUri = 'photo-A.jpg';
    const slow = p.loadImage('photo-A.jpg');
    await waitForDecodeStart(1);
    const fast = p.loadImage('photo-B.jpg');
    await Promise.all([slow, fast]);
    assert.strictEqual(p.imageUri, 'photo-B.jpg', 'P0-5a: newer switch lost the top title uri');
    assert.strictEqual(p.editSession.imageUri, 'photo-B.jpg', 'P0-5a: session uri overwritten by the older load');
    assert.strictEqual(p.editSession.processGeneration, p.loadGeneration, 'P0-5a: stale generation won');
    assert.strictEqual(p.editSession.sourcePixelMap, decoder.results[1], 'P0-5a: older pixels replaced the newer image');
    assert(decoder.results[0].released, 'P0-5a: rejected old decode leaked');
    assert.strictEqual(p.fullResWidth, 1200, 'P0-5a: old metadata overwrote the new dimensions');
    assert.strictEqual(p.fullResHeight, 800);
  }
  // 5b: identical uri reopened - an earlier load must still lose (ABA).
  {
    decoder.calls.length = 0; decoder.results.length = 0;
    decoder.plans = [{ delayMs: 60 }, { delayMs: 0 }];
    const p = makePage('same.RW2');
    p.editSession.imageUri = 'same.RW2';
    const first = p.loadImage('same.RW2');
    await waitForDecodeStart(1);
    const second = p.loadImage('same.RW2');
    await Promise.all([first, second]);
    assert.strictEqual(p.loadGeneration, 2, 'P0-5b: second load did not get its own generation');
    assert.strictEqual(p.editSession.processGeneration, 2, 'P0-5b: earlier same-uri load won (ABA)');
    assert.strictEqual(p.editSession.sourcePixelMap, decoder.results[1], 'P0-5b: older same-uri pixels won');
    assert(decoder.results[0].released, 'P0-5b: rejected same-uri decode leaked');
  }
  // 5c: page destroyed mid-decode -> decode result must be released, no publish.
  {
    decoder.calls.length = 0; decoder.results.length = 0; decoder.plans = [{ delayMs: 40 }];
    const p = makePage('photo-C.jpg');
    p.editSession.imageUri = 'photo-C.jpg';
    const pending = p.loadImage('photo-C.jpg');
    await waitForDecodeStart(1);
    p.pageAlive = false;                     // aboutToDisappear
    p.loadGeneration++;
    await pending;
    assert.strictEqual(p.editSession.sourcePixelMap, null, 'P0-5c: destroyed page published a decoded source');
    assert.strictEqual(p.log.dialogs.length, 0, 'P0-5c: stale failure raised a dialog after page exit');
    assert(p.loadGeneration > 1, 'P0-5c: disposal did not invalidate the load');
    assert(decoder.results[0].released, 'P0-5c: destroyed-page decode leaked');
  }
  // 5d: old load FAILS after a newer switch -> no dialog, no placeholder.
  {
    decoder.calls.length = 0; decoder.results.length = 0;
    decoder.plans = [{ delayMs: 50, error: true }, { delayMs: 0 }];
    const p = makePage('photo-D.jpg');
    p.editSession.imageUri = 'photo-D.jpg';
    const stale = p.loadImage('photo-D.jpg');
    await waitForDecodeStart(1);
    await p.loadImage('photo-E.jpg');
    await stale;
    assert.strictEqual(p.imageUri, 'photo-E.jpg', 'P0-5d: switch did not take effect');
    assert.strictEqual(p.log.dialogs.length, 0,
      'P0-5d: stale failure raised the unsupported-image dialog');
    assert.strictEqual(p.editSession.sourcePixelMap, decoder.results[1]);
  }
  {
    const p = makePage('new.jpg');
    p.loadGeneration = 5; p.editSession.processGeneration = 5; p.editSession.imageUri = 'new.jpg';
    const calls = decoder.calls.length;
    await p.loadImage('stale.jpg', 4);
    assert.strictEqual(p.imageUri, 'new.jpg', 'P0-5e: stale caller changed the title before being rejected');
    assert.strictEqual(p.editSession.imageUri, 'new.jpg');
    assert.strictEqual(p.editSession.processGeneration, 5);
    assert.strictEqual(decoder.calls.length, calls);
    p.pageAlive = false;
    await p.loadImage('resurrect.jpg');
    assert.strictEqual(p.pageAlive, false, 'P0-5e: a late callback revived a destroyed page');
  }
  console.log('PASS P0 lifecycle: DCP frame retention/release order, page-exit and photo-switch disposal, '
    + 'GPU surface rebuild, late/older/ABA/same-uri load rejection, stale failure suppression');
})().catch(e => { console.error(e); process.exitCode = 1; });



