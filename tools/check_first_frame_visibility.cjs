// First-frame visibility regression.
//
// EditorPage does not render the editor layout until `loading` is false, i.e.
// until after ImageProcessor has published the first preview frame. That means
// the canvas is *always* created after the first publish. A @StorageProp watch
// is not delivered for the value a component was initialised with, so a canvas
// that mounts after a publish must adopt the current version itself, and must
// also re-adopt it once it is really on screen (a publish can land while the
// component is being created). If it does not, the canvas keeps its initial
// `imageRevision`, never rebuilds, and the frame - including the GPU surface
// that was presented before its visibility gate opened - stays invisible until
// some unrelated state change (a touch) forces a rebuild.
//
// Phone logs showed the second half of the defect: the first GPU present
// (upload=true) completed while the XComponent still had .visibility(Hidden),
// and the one-shot re-present that followed reused the resident texture
// (upload=false) while the surface had only just been made visible. On that
// device neither present was composited, so the canvas went blank right after
// the CPU frame had flashed. build() now paints the XComponent below the CPU
// preview Image and opens the gate as soon as a frame exists, so the uploading
// present always lands on a surface that is already part of the composition.
//
// The test runs the REAL methods sliced out of EditorCanvas.ets: aboutToAppear,
// adoptPublishedFrame, visibleFrameKind, gpuLayerVisible, revealGpuLayer and
// hasGeometryTransform. It also checks the build() paint order. It then runs the
// same assertions against a deliberately reverted (defect) copy and requires
// them to fail, so the guard cannot pass vacuously.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(
  path.resolve(root, 'entry/src/main/ets/components/EditorCanvas.ets'), 'utf8')
  .replace(/\r\n/g, '\n');

function slice(startMarker, endMarker, label) {
  const start = source.indexOf(startMarker);
  assert(start >= 0, 'missing ' + label + ' (' + startMarker.trim() + ')');
  const end = source.indexOf(endMarker, start);
  assert(end > start, 'missing end of ' + label);
  return source.slice(start, end);
}

const constants = slice('const FRAME_NONE: number', '@Component', 'frame kind constants');
const aboutToAppear = slice('  aboutToAppear(): void {', '  /**\n   * Re-read the published preview version', 'aboutToAppear');
const adopt = slice('  private adoptPublishedFrame(phase: string): void {',
  '  /**\n   * Which layer build() must draw', 'adoptPublishedFrame');
const visible = slice('  private visibleFrameKind(): number {',
  '  private syncRenderVersion(): void {', 'visibleFrameKind');
const geometry = slice('  private hasGeometryTransform(): boolean {',
  '  private getDisplayedImageRect(', 'hasGeometryTransform');

// The production shape must keep the mount-time fallback wired: aboutToAppear
// and the root Stack's onAppear both call it. Removing either wiring is what
// reintroduces the blank first frame.
assert(aboutToAppear.includes("this.adoptPublishedFrame('mount')"),
  'aboutToAppear must adopt the frame published before the canvas mounted');
assert(/\.onAppear\(\(\) => \{[\s\S]{0,400}?this\.adoptPublishedFrame\('appear'\);/.test(source),
  'the canvas root must re-adopt the published version once it is really on screen');

// The surface must be composited before the first GPU present. build() paints
// the XComponent first (below the CPU preview Image, which covers exactly the
// same fit rectangle) and opens its visibility gate as soon as a CPU frame
// exists - not when gpuPreviewActive flips, which happens only *after* the
// present. Reverting either half puts the first present back on a hidden
// surface, where a phone drops it and the canvas stays blank until a touch.
const buildStart = source.indexOf('  build() {');
assert(buildStart >= 0, 'missing build()');
const gpuNode = source.indexOf("XComponent({ id: 'vivid-editor-gpu'", buildStart);
const firstFrameBranch = source.indexOf('if (this.visibleFrameKind() === FRAME_BEFORE)', buildStart);
assert(gpuNode > buildStart && firstFrameBranch > gpuNode,
  'the XComponent must be the first child so the CPU preview Image paints above it');
assert(/\.visibility\(this\.gpuLayerVisible\(\) \? Visibility\.Visible : Visibility\.Hidden\)/.test(source),
  'the surface gate must use gpuLayerVisible(), which is open while a CPU frame exists');

// The first GPU frame is presented before build() opens the surface gate. The
// watch must therefore ask for exactly one more present after revealing it.
const sync = slice('  private syncRenderVersion(): void {',
  '  /** True when the published tile already covers', 'syncRenderVersion');
assert(/if \(this\.revealGpuLayer\(\)\)[\s\S]{0,300}?ImageProcessor\.process\(this\.editSession\);/.test(sync),
  'syncRenderVersion must re-present a GPU frame that was published behind a hidden surface');

function buildClass(defective) {
  const lifecycle = defective
    ? '  aboutToAppear(): void { }\n  private adoptPublishedFrame(phase: string): void { }\n'
    : aboutToAppear + adopt;
  const visibility = defective
    ? '  private gpuLayerVisible(): boolean { return this.editSession.gpuPreviewActive; }\n'
    : '';
  const code = constants + '\nclass Canvas {\n' +
    '  constructor() {\n' +
    '    this.imageRevision = 0;\n' +
    '    this.renderVersion = 0;\n' +
    '    this.showBeforeLocal = false;\n' +
    '    this.showBeforeSignal = false;\n' +
    '    this.gpuLayerRevealed = false;\n' +
    '    this.editSession = null;\n' +
    '  }\n' +
    lifecycle + (defective ? visibility : '') +
    (defective ? visible.replace(/  private gpuLayerVisible\(\): boolean \{[\s\S]*?\n  \}\n/, '') : visible) +
    geometry + '}\nCanvas;';
  const js = ts.transpileModule(code, {
    compilerOptions: { target: ts.ScriptTarget.ES2021 },
  }).outputText;
  const sandbox = {
    console: { info() {}, warn() {} },
    Date, Math, Number, String, Object, Array,
    AppStorage: {
      get(key) { return sandbox.__store[key]; },
      setOrCreate(key, value) { sandbox.__store[key] = value; },
    },
    __store: Object.create(null),
    ImageProcessor: {
      // beforePixelMap readiness is covered by check_before_snapshot; here the
      // comparison frame is either ready (a populated source/before pair) or
      // not part of the scenario.
      isBeforePreviewReady(session) { return session.beforePixelMap !== null; },
    },
    geometryActive: () => false,
  };
  const Canvas = vm.runInNewContext(js, sandbox);
  return { Canvas, store: sandbox.__store };
}

function makeSession(overrides = {}) {
  return Object.assign({
    previewPixelMap: null,
    gpuPreviewActive: false,
    gpuSurfaceId: '',
    beforePixelMap: null,
    beforePixelMapSource: null,
    beforeGeometryKey: '',
    sourcePixelMap: null,
    detailPixelMap: null,
    imageWidth: 1364,
    imageHeight: 2048,
    rotation: 0,
    flipH: false,
    flipV: false,
    cropLeft: 0,
    cropTop: 0,
    cropRight: 1,
    cropBottom: 1,
    geometry: [],
  }, overrides);
}

// Each scenario mounts a fresh canvas exactly the way ArkUI does: renderVersion
// is initialised from AppStorage, then aboutToAppear() runs, then the component
// appears. Returns the canvas after the appear hook.
function mount(Canvas, store, session, publishedVersion, duringMount) {
  const canvas = new Canvas();
  canvas.editSession = session;
  canvas.renderVersion = store.previewVersion ?? 0;
  canvas.aboutToAppear();
  if (duringMount) duringMount(canvas);
  // The root Stack's onAppear: the real handler, not a copy of its body.
  canvas.adoptPublishedFrame('appear');
  return canvas;
}

function runSuite(Canvas, store) {
  const failures = [];
  const check = (name, fn) => {
    try { fn(); } catch (error) { failures.push(name + ': ' + error.message); }
  };

  // 1. Publish-before-mount: the first JPG frame is already in the session when
  // the canvas is created (this is the normal opening path).
  check('publish-before-mount', () => {
    const frame = { tag: 'first-jpg-frame' };
    const session = makeSession({ previewPixelMap: frame });
    store.previewVersion = 1;
    const canvas = mount(Canvas, store, session, 1);
    assert.strictEqual(canvas.imageRevision, 1,
      'canvas must adopt the version it was created with');
    assert.strictEqual(canvas.visibleFrameKind(), 3,
      'the published CPU preview must be the visible layer, not an empty canvas');
    assert.strictEqual(canvas.editSession.previewPixelMap, frame);
  });

  // 2. Publish lands while the component is being created (the watch for that
  // bump is lost). The GPU surface was presented before gpuPreviewActive made
  // it visible, so only a repaint against the current state can show it.
  check('publish-during-creation', () => {
    const session = makeSession({ previewPixelMap: { tag: 'cpu' } });
    store.previewVersion = 1;
    const canvas = mount(Canvas, store, session, 1, () => {
      // GPU frame completes between the initial @StorageProp read and the
      // watch registration: exactly the window ArkUI does not notify.
      session.gpuPreviewActive = true;
      store.previewVersion = 2;
    });
    assert.strictEqual(canvas.imageRevision, 2,
      'a frame published during creation must still advance the binding revision');
    assert.strictEqual(canvas.visibleFrameKind(), 4,
      'the GPU surface must be made visible for the frame it already holds');
  });

  // 3. Returning to the editor from a mid page: a brand-new canvas mounts on a
  // session that already has both a preview frame and a sharp detail tile.
  check('return-from-mid-page', () => {
    const session = makeSession({
      previewPixelMap: { tag: 'cpu' },
      detailPixelMap: { tag: 'tile' },
      gpuPreviewActive: true,
    });
    store.previewVersion = 7;
    store.detailVersion = 4;
    const canvas = mount(Canvas, store, session, 7);
    assert.strictEqual(canvas.imageRevision, 7);
    assert.strictEqual(canvas.visibleFrameKind(), 4,
      'a re-entered editor must show the current GPU frame immediately');
  });

  // 4. Two JPGs in a row: the second switch publishes a new CPU frame while
  // the canvas is already mounted (the watch path), then the canvas is
  // re-created for the next open and must bind the newer frame.
  check('two-jpgs-in-a-row', () => {
    const first = { tag: 'jpg-A' };
    const second = { tag: 'jpg-B' };
    const session = makeSession({ previewPixelMap: first });
    store.previewVersion = 2;
    const canvas = mount(Canvas, store, session, 2);
    assert.strictEqual(canvas.visibleFrameKind(), 3);

    session.previewPixelMap = second;
    session.gpuPreviewActive = false;
    store.previewVersion = 3;
    canvas.renderVersion = 3;
    canvas.imageRevision = 3;                  // delivered by the real watch
    assert.strictEqual(canvas.visibleFrameKind(), 3);
    assert.strictEqual(canvas.editSession.previewPixelMap, second,
      'the second JPG must replace the first one, not leave the old frame');

    // The next open mounts a fresh canvas after the third frame was published.
    store.previewVersion = 4;
    session.previewPixelMap = { tag: 'jpg-C' };
    const remounted = mount(Canvas, store, session, 4);
    assert.strictEqual(remounted.imageRevision, 4);
    assert.strictEqual(remounted.visibleFrameKind(), 3);
  });

  // 5. The frame that opened the GPU layer was presented while the surface was
  // still hidden. The canvas must request one re-present for that transition,
  // and only one: repeated signals for the same layer must not loop.
  check('gpu-layer-reveal-once', () => {
    const session = makeSession({ previewPixelMap: { tag: 'cpu' } });
    store.previewVersion = 1;
    const canvas = mount(Canvas, store, session, 1);
    assert.strictEqual(canvas.revealGpuLayer(), false,
      'no re-present while the CPU layer is current');
    session.gpuPreviewActive = true;
    assert.strictEqual(canvas.revealGpuLayer(), true,
      'the first GPU layer must be re-presented after its visibility gate opened');
    assert.strictEqual(canvas.revealGpuLayer(), false,
      'the same GPU layer must not be re-presented again');
    session.gpuPreviewActive = false;
    assert.strictEqual(canvas.revealGpuLayer(), false);
    session.gpuPreviewActive = true;
    assert.strictEqual(canvas.revealGpuLayer(), true,
      'a later CPU->GPU transition re-arms the one-shot re-present');
  });

  // 6. Sanity: with no frame at all the canvas must report empty, so the
  // assertions above are not satisfied by a function that always says "shown".
  check('nothing-published', () => {
    const session = makeSession();
    store.previewVersion = 0;
    const canvas = mount(Canvas, store, session, 0);
    assert.strictEqual(canvas.visibleFrameKind(), 0);
  });

  // 7. The surface gate must be open before the first GPU present. The present
  // that uploads the graded frame happens while gpuPreviewActive is still
  // false; if the gate followed that flag, the frame would be submitted to a
  // hidden surface and a phone would drop it (blank canvas until a touch).
  check('surface-visible-before-present', () => {
    const session = makeSession({ previewPixelMap: { tag: 'cpu' } });
    store.previewVersion = 1;
    const canvas = mount(Canvas, store, session, 1);
    assert.strictEqual(canvas.gpuLayerVisible(), true,
      'the EGL surface must be composited while only the CPU frame exists');
    session.gpuPreviewActive = true;
    assert.strictEqual(canvas.gpuLayerVisible(), true,
      'the surface stays visible when the GPU layer takes over');
    session.gpuPreviewActive = false;
    session.previewPixelMap = null;
    assert.strictEqual(canvas.gpuLayerVisible(), false,
      'without any frame the surface must not stay on screen');
  });

  return failures;
}

// ---- Run the real implementation: every scenario must pass.
const real = buildClass(false);
real.store.previewVersion = 0;
const realFailures = runSuite(real.Canvas, real.store);
if (realFailures.length > 0) {
  console.error('FAIL first-frame visibility:\n  ' + realFailures.join('\n  '));
  process.exit(1);
}

// ---- Falsification: the same assumptions against the pre-fix shape (no
// mount-time adoption and no onAppear re-adoption) must fail. If they pass,
// the guard would not catch a regression and is worthless.
const defect = buildClass(true);
defect.store.previewVersion = 0;
const defectFailures = runSuite(defect.Canvas, defect.store);
assert(defectFailures.length > 0,
  'the defect shape passed every scenario: this test does not actually guard the fix');
for (const expected of ['publish-before-mount', 'publish-during-creation', 'return-from-mid-page',
  'surface-visible-before-present']) {
  assert(defectFailures.some(line => line.startsWith(expected)),
    'reverted fix must be caught by scenario "' + expected + '", got:\n  ' +
    defectFailures.join('\n  '));
}

console.log('PASS first-frame visibility: publish-before-mount, publish-during-creation, ' +
  'return-from-mid-page and two-JPGs-in-a-row all bind the current frame; the EGL surface ' +
  'is composited before the first GPU present; the reverted lifecycle and gate fail those ' +
  'scenarios as required');
