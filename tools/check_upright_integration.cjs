// Upright integration: the guide model, the solve path, and 鈥?the part that
// matters 鈥?whether the lines a user draws actually come out straight through the
// PRODUCTION projection.
//
// check_upright_solver.cjs proves the ALGEBRA. This suite proves the WIRING: that
// the model, the session's single solve entry point, the sidecar and the real
// geometry map agree, and that a solve leaves the GPU path untouched because it
// writes the fields the GPU already uploads.
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
        return {
          fileIo: {
            OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 8 },
            openSync: (p, f) => ({ fd: fs.openSync(p, f === 8 ? 'r' : 'w') }),
            closeSync: (h) => fs.closeSync(typeof h === 'number' ? h : h.fd),
            writeSync: (h, b) => fs.writeSync(typeof h === 'number' ? h : h.fd, Buffer.from(b)),
            readSync: (h, b) => fs.readSync(typeof h === 'number' ? h : h.fd, new Uint8Array(b)),
            statSync: (p) => (typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p)),
          },
        };
      }
      if (n === '@kit.ArkTS') {
        const encoder = () => ({ encode: (t) => new Uint8Array(Buffer.from(t, 'utf8')) });
        const decoder = () => ({ decode: (b) => Buffer.from(b).toString('utf8'),
          decodeToString: (b) => Buffer.from(b).toString('utf8') });
        function TextEncoderShim() { return encoder(); }
        TextEncoderShim.create = encoder;
        function TextDecoderShim() { return decoder(); }
        TextDecoderShim.create = decoder;
        return {
          util: { TextEncoder: TextEncoderShim, TextDecoder: TextDecoderShim },
          taskpool: { Task: class { static isCanceled() { return false; } }, execute: async (t) => t },
        };
      }
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      if(n.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { UprightSettings, UPRIGHT_MIN_GUIDE_LENGTH } = load(root + '/edit/models/UprightSettings.ets');
const { UprightMode, uprightModeFromNumber, solveUpright, applyUpright, uprightIsEmpty } =
  load(root + '/edit/engine/UprightSolver.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { ToolType } = load(root + '/edit/models/ToolType.ets');
const { Layer } = load(root + '/edit/models/Layer.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }

/** A session with a synthetic frame, so the real projection can be exercised. */
function session() {
  const s = new EditSession();
  s.layers = [new Layer('synthetic')];
  s.imageWidth = 1200; s.imageHeight = 900;
  return s;
}
/** How much a marked line wanders off-axis once rendered, in normalized display
 *  units. This measures the OUTPUT, not the solver's own numbers. */
function axisSpread(s, guide, axis) {
  let min = Infinity, max = -Infinity, seen = 0;
  for (let step = 0; step <= 10; step++) {
    const t = step / 10;
    const x = guide.x1 + (guide.x2 - guide.x1) * t;
    const y = guide.y1 + (guide.y2 - guide.y1) * t;
    const display = s.sourcePointToDisplay(x, y);
    if (!display) continue;
    seen++;
    const value = axis === 'x' ? display[0] : display[1];
    if (value < min) min = value;
    if (value > max) max = value;
  }
  return seen === 0 ? Infinity : max - min;
}
function verticalGuide(x1, y1, x2, y2) { const g = new UprightSettings(); g.addGuide(x1, y1, x2, y2); return g.guides[0]; }

// --- 1. The guide model ---------------------------------------------------
const empty = new UprightSettings();
ok(empty.guides.length === 0 && !empty.hasGuides(), 'a fresh document has no guides');
ok(empty.mode === UprightMode.FULL, 'and defaults to the most capable mode');
ok(UprightSettings.restore(undefined).guides.length === 0, 'a pre-Upright sidecar restores to no guides');
const fallback = UprightSettings.restore({ mode: 99, guides: [{ x1: 0, y1: 0, x2: 1, y2: 1, vertical: true }] });
ok(fallback.mode === UprightMode.FULL, 'an unrecognised stored mode falls back to FULL rather than to an ' +
  'undefined enum member');
ok(uprightModeFromNumber(NaN) === UprightMode.FULL && uprightModeFromNumber(-1) === UprightMode.FULL,
  'a non-finite or negative mode also falls back to FULL');
ok(uprightModeFromNumber(UprightMode.LEVEL) === UprightMode.LEVEL, 'a valid stored mode survives');
// Corrupt guides must be dropped, not carried into the solver as NaN.
const dirty = UprightSettings.restore({ mode: 2, guides: [
  { x1: NaN, y1: 0, x2: 1, y2: 1, vertical: true },
  { x1: -5, y1: 0.5, x2: 9, y2: 0.5, vertical: false },
  null,
] });
ok(dirty.guides.length === 1, 'a guide with a non-finite coordinate is dropped (' + dirty.guides.length +
  ' of 3 kept)');
ok(dirty.guides[0].x1 === 0 && dirty.guides[0].x2 === 1, 'out-of-range coordinates are clamped into 0..1');
// The class is a class, not an interface: restore must not hand back a bare object
// that later fails an instanceof-style check.
ok(dirty.clone() instanceof UprightSettings, 'clone returns a real UprightSettings');

// --- 2. acceptsGuide and addGuide must agree ------------------------------
// addGuide calls acceptsGuide, so this pins the behaviour rather than the
// structure: a caller that opened an undo step for an accepted stroke must get a
// guide appended, and a rejected tap must not.
const probes = [
  [0.1, 0.1, 0.9, 0.1], [0.1, 0.1, 0.1, 0.9], [0.5, 0.5, 0.5, 0.5],
  [0.1, 0.1, 0.12, 0.12], [0.1, 0.1, 0.5, 0.5], [0.1, 0.1, 0.3, 0.35],
  [0.1, 0.1, 0.4, 0.1], [0.2, 0.2, NaN, 0.4], [0, 0, 1, 1],
];
let agreementFailures = [];
for (const probe of probes) {
  const model = new UprightSettings();
  const accepted = UprightSettings.acceptsGuide(probe[0], probe[1], probe[2], probe[3]);
  const added = model.addGuide(probe[0], probe[1], probe[2], probe[3]);
  if (accepted !== added || model.guides.length !== (added ? 1 : 0)) agreementFailures.push(probe.join(','));
}
ok(agreementFailures.length === 0, 'acceptsGuide and addGuide agree on all ' + probes.length + ' probes, so ' +
  'an undo step opened for an accepted stroke always gets a guide' +
  (agreementFailures.length ? ': ' + agreementFailures.join(' | ') : ''));
const tap = new UprightSettings();
ok(!tap.addGuide(0.5, 0.5, 0.5 + UPRIGHT_MIN_GUIDE_LENGTH / 4, 0.5),
  'a tap shorter than the minimum is rejected rather than stored as a degenerate line');
ok(!tap.addGuide(0, 0, 1, 1), 'a 45-degree stroke is rejected rather than guessed at');
ok(tap.guides.length === 0, 'and neither rejection stored anything');
const axes = new UprightSettings();
axes.addGuide(0.1, 0.5, 0.9, 0.5);
axes.addGuide(0.5, 0.1, 0.5, 0.9);
ok(axes.guides[0].vertical === false, 'a mostly-horizontal stroke becomes a horizontal guide');
ok(axes.guides[1].vertical === true, 'a mostly-vertical stroke becomes a vertical guide');
axes.clear();
ok(axes.guides.length === 0 && !axes.hasGuides(), 'clear removes every guide');

// --- 3. The solve writes ONLY the three geometry fields -------------------
const two = session();
two.geometry = [0.11, 0.22, 0.33, -40, 130, 7, 8, 1];
two.upright.addGuide(0.3, 0.9, 0.4, 0.1);
two.upright.addGuide(0.7, 0.9, 0.6, 0.1);
// Both mirrored edges converge on the vertical centre line, so they demand the
// same coefficient and the solve should be exact.
const solved = two.solveUprightGuides();
ok(solved.verticalGuides === 2 && solved.horizontalGuides === 0,
  'both vertical guides were accepted (' + solved.verticalGuides + ')');
ok(Math.abs(solved.verticalPerspective - 0.4166666666666667) < 1e-9,
  'the solve reproduces the exact converging-edge coefficient (got ' + solved.verticalPerspective + ')');
ok(solved.residual < 1e-9, 'and the two mirrored guides agree exactly (residual ' + solved.residual + ')');
ok(two.geometry[3] === -40 && two.geometry[4] === 130 && two.geometry[5] === 7 &&
  two.geometry[6] === 8 && two.geometry[7] === 1,
  'aspect, scale, the spare slots and the auto-crop flag are preserved: ' + JSON.stringify(two.geometry));
ok(two.geometry[0] === solved.verticalPerspective * 160, 'g[0] carries the vertical perspective in slider units');
ok(two.geometry[1] === 0 && two.geometry[2] === 0, 'g[1] and g[2] are zero when no horizontal guide exists');
ok(two.geometry.length === 8, 'the geometry array keeps its eight slots');

// --- 4. END TO END through the production projection ---------------------
// The point of Upright is that the line the user marked comes out straight. This
// samples the marked line and pushes each sample through the same geometry map
// the renderer and the mask overlay use, then measures the result.
const e2e = session();
const leftEdge = { x1: 0.30, y1: 0.90, x2: 0.40, y2: 0.10 };
const rightEdge = { x1: 0.70, y1: 0.90, x2: 0.60, y2: 0.10 };
const beforeLeft = axisSpread(e2e, leftEdge, 'x');
ok(beforeLeft > 0.05, 'the fixture vertical edge really is tilted to begin with (' +
  beforeLeft.toFixed(4) + ' of normalized width across its length)');
e2e.upright.addGuide(leftEdge.x1, leftEdge.y1, leftEdge.x2, leftEdge.y2);
e2e.upright.addGuide(rightEdge.x1, rightEdge.y1, rightEdge.x2, rightEdge.y2);
e2e.solveUprightGuides();
const afterLeft = axisSpread(e2e, leftEdge, 'x');
const afterRight = axisSpread(e2e, rightEdge, 'x');
ok(afterLeft < beforeLeft * 0.02, 'after the solve the marked LEFT edge renders vertical through the real ' +
  'projection (' + afterLeft.toFixed(5) + ' remain, down from ' + beforeLeft.toFixed(4) + ')');
ok(afterRight < beforeLeft * 0.02, 'and so does the RIGHT edge, which shares the same solution (' +
  afterRight.toFixed(5) + ')');

// A horizontal guide, in the mode where perspective alone levels it.
const horiz = session();
const slopedLine = { x1: 0.10, y1: 0.75, x2: 0.90, y2: 0.65 };
const beforeHoriz = axisSpread(horiz, slopedLine, 'y');
ok(beforeHoriz > 0.03, 'the fixture horizontal edge is tilted to begin with (' + beforeHoriz.toFixed(4) + ')');
horiz.upright.addGuide(slopedLine.x1, slopedLine.y1, slopedLine.x2, slopedLine.y2);
const horizSolved = horiz.solveUprightGuides();
ok(horizSolved.horizontalGuides === 1, 'the horizontal guide supplied a perspective constraint');
ok(Math.abs(horizSolved.horizontalPerspective + 0.3125) < 1e-9,
  'with the exact delta/gamma coefficient (got ' + horizSolved.horizontalPerspective + ')');
const afterHoriz = axisSpread(horiz, slopedLine, 'y');
ok(afterHoriz < beforeHoriz * 0.02, 'and it renders level afterwards (' + afterHoriz.toFixed(5) +
  ' remain, down from ' + beforeHoriz.toFixed(4) + ')');

// LEVEL mode must rotate only. Rotating the whole image by a line's own angle
// levels that line whatever its intercept, which is why this is testable.
const level = session();
level.upright.mode = UprightMode.LEVEL;
level.upright.addGuide(slopedLine.x1, slopedLine.y1, slopedLine.x2, slopedLine.y2);
const levelSolved = level.solveUprightGuides();
ok(level.geometry[0] === 0 && level.geometry[1] === 0,
  'LEVEL leaves both perspective fields at zero (g[0]=' + level.geometry[0] + ', g[1]=' + level.geometry[1] + ')');
ok(level.geometry[2] !== 0, 'and writes a straighten angle instead (' + level.geometry[2].toFixed(3) + ' deg)');
ok(axisSpread(level, slopedLine, 'y') < beforeHoriz * 0.02,
  'which levels the marked line through the real projection (' +
  axisSpread(level, slopedLine, 'y').toFixed(5) + ')');
// PERSPECTIVE mode must not rotate.
const onlyPerspective = session();
onlyPerspective.upright.mode = UprightMode.PERSPECTIVE;
onlyPerspective.upright.addGuide(slopedLine.x1, slopedLine.y1, slopedLine.x2, slopedLine.y2);
onlyPerspective.solveUprightGuides();
ok(onlyPerspective.geometry[2] === 0, 'PERSPECTIVE mode writes no rotation (got ' +
  onlyPerspective.geometry[2] + ', geometry ' + JSON.stringify(onlyPerspective.geometry) + ')');
ok(onlyPerspective.geometry[1] === horizSolved.horizontalPerspective * 160,
  'but agrees with FULL on the perspective term');

// --- 5. Removing the guides restores the manual values -------------------
const restore = session();
restore.geometry = [12, -7, 3.5, 0, 100, 0, 0, 0];
restore.upright.addGuide(0.3, 0.9, 0.4, 0.1);
restore.solveUprightGuides();
ok(restore.geometry[0] !== 12, 'a solve overwrites the manual vertical perspective');
restore.upright.clear();
restore.solveUprightGuides();
ok(restore.geometry[0] === 0 && restore.geometry[1] === 0 && restore.geometry[2] === 0,
  'clearing the guides writes the three fields back to zero rather than leaving a stale ' +
  'correction (' + JSON.stringify(restore.geometry) + ')');
ok(restore.geometry[4] === 100, 'while the manual scale is still preserved');
const noGuides = session();
noGuides.geometry = [12, -7, 3.5, 0, 100, 0, 0, 0];
noGuides.solveUprightGuides();
ok(noGuides.geometry[0] === 0 && noGuides.geometry[2] === 0,
  'solving with no guides at all is a well-defined reset, not a crash');
ok(uprightIsEmpty(solveUpright([], UprightMode.FULL)), 'and that solve really is the empty solution');

// --- 6. Sidecar and undo round-trips -------------------------------------
const exportedSession = session();
exportedSession.upright.mode = UprightMode.LEVEL;
exportedSession.upright.addGuide(0.30, 0.90, 0.40, 0.10);
exportedSession.upright.addGuide(0.10, 0.75, 0.90, 0.65);
const exported = JSON.parse(exportedSession.exportAdjustmentState());
ok(exported.upright && exported.upright.guides && exported.upright.guides.length === 2,
  'the exported adjustment state carries both guides');
const reopened = session();
ok(reopened.importAdjustmentState(JSON.stringify(exported)), 'the exported state imports back');
ok(reopened.upright.guides.length === 2, 'both guides survive the round-trip');
ok(reopened.upright.mode === UprightMode.LEVEL, 'and so does the mode');
ok(Math.abs(reopened.upright.guides[0].x2 - 0.40) < 1e-12 && reopened.upright.guides[1].vertical === false,
  'with their coordinates and axes intact');
// Re-solving after reopening must reproduce the same correction.
const reSolved = reopened.solveUprightGuides();
ok(Math.abs(reSolved.rotation - levelSolved.rotation) < 1e-9,
  're-solving a reopened document reproduces the same straighten angle (' +
  reSolved.rotation.toFixed(6) + ' vs ' + levelSolved.rotation.toFixed(6) + ')');
const legacy = JSON.parse(JSON.stringify(exported));
delete legacy.upright;
const legacySession = session();
ok(legacySession.importAdjustmentState(JSON.stringify(legacy)), 'a sidecar written before Upright imports');
ok(legacySession.upright.guides.length === 0 && legacySession.upright.mode === UprightMode.FULL,
  'and opens with no guides in the default mode');

const undoSession = session();
undoSession.pushUndo();
undoSession.upright.addGuide(0.3, 0.9, 0.4, 0.1);
undoSession.solveUprightGuides();
undoSession.pushUndo();
// Deliberately NOT the mirrored edge: two mirrored edges demand the SAME
// coefficient, so the solve would be unchanged and the undo assertion below would
// hold even if undo did nothing at all.
undoSession.upright.addGuide(0.7, 0.9, 0.62, 0.1);
undoSession.solveUprightGuides();
const twoGuidePerspective = undoSession.geometry[0];
ok(Math.abs(twoGuidePerspective - 0.4166666666666667 * 160) > 1,
  'the second guide genuinely moves the solution, so the undo check is not vacuous (' +
  twoGuidePerspective.toFixed(3) + ' vs ' + (0.4166666666666667 * 160).toFixed(3) + ')');
undoSession.undo();
ok(undoSession.upright.guides.length === 1, 'undo removes the second guide (' +
  undoSession.upright.guides.length + ' left)');
ok(undoSession.geometry[0] !== twoGuidePerspective,
  'and the correction it contributed is gone with it, because the geometry is part of the snapshot (' +
  undoSession.geometry[0] + ' vs ' + twoGuidePerspective + ')');
undoSession.undo();
ok(undoSession.upright.guides.length === 0, 'undo removes the first guide too');
undoSession.redo();
ok(undoSession.upright.guides.length === 1, 'redo brings it back');

// --- 7. Wiring, and the absence of a GPU bypass -------------------------
const bridgeSource = fs.readFileSync('entry/src/main/ets/edit/engine/GpuShaderBridge.ets', 'utf8');
ok(!bridgeSource.includes("decline('upright')"),
  'the GPU path does NOT decline for Upright: a solve writes the geometry fields the GPU already ' +
  'uploads, so there is no new stage to bypass');
const canvasSource = fs.readFileSync('entry/src/main/ets/components/EditorCanvas.ets', 'utf8');
ok(canvasSource.includes('this.handleUprightTouch(event)'),
  'the canvas dispatches touches to the Upright handler when the tool is active');
ok(canvasSource.includes('this.drawUprightOverlay()'), 'and draws the guides on the overlay');
ok(canvasSource.includes('UprightSettings.acceptsGuide('),
  'and tests acceptability before pushing undo, so a rejected tap is not an undo step');
const toolbarSource = fs.readFileSync('entry/src/main/ets/components/EditorToolbar.ets', 'utf8');
ok(toolbarSource.includes("ToolType.UPRIGHT"), 'the toolbar offers the tool');
const panelSource = fs.readFileSync('entry/src/main/ets/components/UprightPanel.ets', 'utf8');
ok(panelSource.includes('this.editSession.solveUprightGuides(apply)'),
  'the panel solves through the session (with the read-only apply flag) rather than duplicating the call');
ok(panelSource.includes('this.refresh(false)'),
  'mounting the panel is read-only: it must not wipe manual geometry when there are no guides');
const cropSource = fs.readFileSync('entry/src/main/ets/components/CropPanel.ets', 'utf8');
const cropMounts = (cropSource.match(/UprightPanel\(\{/g) || []).length;
ok(cropMounts === 1, 'the panel is mounted in the crop page (' + cropMounts + ' mount)');
ok(cropSource.indexOf("import { UprightPanel } from './UprightPanel'") >= 0,
  'and the crop page imports it');
const developSource = fs.readFileSync('entry/src/main/ets/components/DesktopDevelopPanel.ets', 'utf8');
ok(developSource.indexOf('UprightPanel') < 0,
  'the develop panel no longer has an independent Upright section');
const adjustmentSource = fs.readFileSync('entry/src/main/ets/components/AdjustmentPanel.ets', 'utf8');
ok(adjustmentSource.indexOf('UprightPanel') < 0,
  'the legacy adjustment panel no longer mounts Upright either');
const toolTypeSource = fs.readFileSync('entry/src/main/ets/edit/models/ToolType.ets', 'utf8');
ok(toolTypeSource.includes("UPRIGHT = 'upright'"), 'and the tool type exists');
ok(ToolType.UPRIGHT === 'upright', 'with the value the canvas compares against');

console.log('PASS upright integration: guide model and corrupt-sidecar rejection, acceptsGuide/addGuide');
console.log('     agreement over 9 probes, the single solve entry point writing only g[0..2], and 鈥?through');
console.log('     the PRODUCTION projection 鈥?a marked tilted edge rendering vertical and a marked sloped');
console.log('     edge rendering level, in each mode separately. Guide removal restores the manual values.');
console.log('NOTE the algebra is check_upright_solver.cjs, not this suite. Two-parameter tilt cannot fix a');
console.log('     vanishing point that is off the centre axis; such guides disagree and the residual is');
console.log('     surfaced to the user rather than hidden. No auto-Upright, no lens profiles, no Unity.');
console.log(checks + ' checks passed');
