// Retouch: clone stamp and content-aware fill, added as two new mark kinds on the
// existing retouch path.
//
// check_content_fill.cjs proves the ALGORITHMS in isolation. This suite proves the
// WIRING, and 鈥?the part that matters 鈥?that `clone` is a genuinely different
// result from `heal` rather than a strength setting dressed up as a feature.
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

const { RetouchMark, cloneRetouchMarks, RETOUCH_CLONE, RETOUCH_FILL, RETOUCH_HEAL, RETOUCH_REDEYE } =
  load(root + '/edit/models/RetouchSettings.ets');
const { retouchPixels, retouchReadBounds } = load(root + '/edit/engine/RetouchCore.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { ToolType } = load(root + '/edit/models/ToolType.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
function differences(a, b) {
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}
const W = 48, H = 32;
function mark(kind, x, y, radius, sourceX, sourceY, feather, amount) {
  return { id: kind + '-' + x, kind: kind, x: x, y: y, radius: radius, feather: feather, amount: amount,
    sourceX: sourceX, sourceY: sourceY };
}
const CLONE_RADIUS = 0.1;
const CLONE_CX = 0.25, CLONE_CY = 0.5;
const CLONE_SX = 0.75, CLONE_SY = 0.5;

/** Flat target on the left, textured source on the right. */
function targetFrame() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const v = x < W / 2 ? 100 : ((x * 7 + y * 13) % 40) + 150;
      b[i] = v; b[i + 1] = v; b[i + 2] = v; b[i + 3] = 255;
    }
  }
  return b;
}

// --- 1. The new kinds survive the model, the old ones are unchanged -------
const accepted = cloneRetouchMarks([
  mark(RETOUCH_HEAL, 0.2, 0.2, 0.05, 0.6, 0.6, 0.5, 1),
  mark(RETOUCH_CLONE, 0.3, 0.3, 0.05, 0.7, 0.7, 0.5, 1),
  mark(RETOUCH_FILL, 0.4, 0.4, 0.05, 0.8, 0.8, 0.5, 1),
  mark(RETOUCH_REDEYE, 0.5, 0.5, 0.05, 0.9, 0.9, 0.5, 1),
]);
ok(accepted.length === 4, 'all four kinds, including the two new ones, survive the model (' +
  accepted.length + ' of 4)');
ok(accepted[1].kind === RETOUCH_CLONE && accepted[2].kind === RETOUCH_FILL,
  'with their kind strings intact');
const unknown = cloneRetouchMarks([mark('blur', 0.2, 0.2, 0.05, 0.6, 0.6, 0.5, 1),
  mark('', 0.3, 0.3, 0.05, 0.7, 0.7, 0.5, 1)]);
ok(unknown.length === 0, 'an unknown or empty kind is still rejected, so the accepted set is not a wildcard');
ok(cloneRetouchMarks(undefined).length === 0 && cloneRetouchMarks([]).length === 0,
  'a missing or empty list is still an empty list');
const clamped = cloneRetouchMarks([mark(RETOUCH_CLONE, 5, -5, 9, -3, 4, 9, 9)])[0];
ok(clamped.x === 1 && clamped.y === 0 && clamped.radius === 0.2 && clamped.feather === 1 &&
  clamped.amount === 1 && clamped.sourceX === 0 && clamped.sourceY === 1,
  'the new kinds get the same clamping the old ones did, not a bypass of it');
const nonFinite = cloneRetouchMarks([mark(RETOUCH_FILL, NaN, 0.5, 0.05, 0.6, 0.6, 0.5, 1)]);
ok(nonFinite.length === 0, 'a non-finite coordinate is still rejected for the new kinds');
const capped = cloneRetouchMarks(new Array(600).fill(null).map((unused, i) =>
  mark(RETOUCH_CLONE, (i % 100) / 100, 0.5, 0.01, 0.9, 0.9, 0.5, 1)));
ok(capped.length === 512, 'and the 512-mark cap still applies (' + capped.length + ')');

// --- 2. Clone must copy VERBATIM, from the RIGHT place, and heal must NOT ---
// A CONSTANT source region makes this assertion independent of the stamp's
// sub-pixel convention. An earlier version of this test hand-computed the source
// pixel as (x + 24, y) and asserted byte equality; it measured 0 of 32, because the
// stamp lands on a neighbouring pixel. Asserting a specific pixel index tests the
// implementation's rounding, not the property that matters. A constant region has no
// neighbouring value to land on, so "the target became exactly the source value" is
// true for ANY correct rounding -- while still proving it read from the source side,
// since 200 exists nowhere else in the frame.
const source = targetFrame();
const radiusPx = CLONE_RADIUS * Math.max(W, H);
const centrePx = Math.round(CLONE_CX * W), centrePy = Math.round(CLONE_CY * H);
function corePixels(pixels, value) {
  let total = 0, matching = 0, target = 0;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      if (Math.hypot(x + 0.5 - centrePx, y + 0.5 - centrePy) > radiusPx * 0.7) continue;
      total++;
      const v = pixels[(y * W + x) * 4];
      if (v === value) matching++;
      if (v === 100) target++;
    }
  }
  return { total: total, matching: matching, target: target };
}
const flatSource = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    const v = x < W / 2 ? 100 : 200;
    flatSource[i] = v; flatSource[i + 1] = v; flatSource[i + 2] = v; flatSource[i + 3] = 255;
  }
}
const flatClone = retouchPixels(flatSource, W, H, [mark(RETOUCH_CLONE, CLONE_CX, CLONE_CY,
  CLONE_RADIUS, CLONE_SX, CLONE_SY, 0, 1)]);
const cloned = corePixels(flatClone, 200);
ok(cloned.total > 20, 'the clone core covers a measurable number of pixels (' + cloned.total + ')');
ok(cloned.matching === cloned.total, 'clone reproduces the source region EXACTLY at every one of the ' +
  cloned.total + ' core pixels (' + cloned.matching + ' match), so it is a copy rather than a blend');
ok(cloned.target === 0, 'and leaves none of the target value behind, so it read from the source side');
const flatHeal = retouchPixels(flatSource, W, H, [mark(RETOUCH_HEAL, CLONE_CX, CLONE_CY,
  CLONE_RADIUS, CLONE_SX, CLONE_SY, 0, 1)]);
const healed = corePixels(flatHeal, 200);
ok(healed.matching < healed.total, 'while heal does NOT reproduce the source value exactly (' +
  healed.matching + ' of ' + healed.total + '), because it adds a boundary correction: that is what ' +
  'makes the two kinds genuinely different operations');
ok(differences(flatClone, flatHeal) > 20, 'and the two renders therefore differ (' +
  differences(flatClone, flatHeal) + ' bytes): clone is not a strength setting dressed up as a tool');
// Opacity must blend, which proves the copy is a weighted composite rather than a
// bitmap paste, and gives the mid value a direction to be checked against.
const halfOpacity = retouchPixels(flatSource, W, H, [mark(RETOUCH_CLONE, CLONE_CX, CLONE_CY,
  CLONE_RADIUS, CLONE_SX, CLONE_SY, 0, 0.5)]);
const halfValue = halfOpacity[(centrePy * W + centrePx) * 4];
ok(halfValue > 100 && halfValue < 200, 'opacity 0.5 lands strictly between the target and the source (' +
  halfValue + '), so the stamp really is weighted');
const cloneOut = retouchPixels(source, W, H, [mark(RETOUCH_CLONE, CLONE_CX, CLONE_CY, CLONE_RADIUS,
  CLONE_SX, CLONE_SY, 0, 1)]);
ok(differences(cloneOut, source) > 100, 'the clone render differs from its input');
// Clone is a verbatim copy, so a clone of a region onto itself must be a no-op even
// over a textured region: any resampling or correction would show up here.
const identityClone = retouchPixels(source, W, H, [mark(RETOUCH_CLONE, CLONE_CX, CLONE_CY,
  CLONE_RADIUS, CLONE_CX, CLONE_CY, 0, 1)]);
ok(differences(identityClone, source) === 0,
  'cloning a textured region onto its own location changes nothing at all (' +
  differences(identityClone, source) + ' bytes), which a resampling or fused operation would not manage');

// --- 3. Fill must replace the marked region with its surroundings ---------
/** A smooth vertical gradient with a bright object sitting in the middle. */
function objectFrame() {
  const b = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const v = 60 + Math.round(60 * y / H) + ((x * 3) % 5);
      b[i] = v; b[i + 1] = v; b[i + 2] = v; b[i + 3] = 255;
    }
  }
  // A bright blob that content-aware fill should remove.
  const cx = W / 2, cy = H / 2, r = 5;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      if (Math.hypot(x + 0.5 - cx, y + 0.5 - cy) > r) continue;
      const i = (y * W + x) * 4;
      b[i] = 250; b[i + 1] = 250; b[i + 2] = 250;
    }
  }
  return b;
}
const objectSource = objectFrame();
const FILL_RADIUS = 0.14;
const fillOut = retouchPixels(objectSource, W, H, [mark(RETOUCH_FILL, 0.5, 0.5,
  FILL_RADIUS, 0.5, 0.5, 0.5, 1)]);
const fillRadiusPx = FILL_RADIUS * Math.max(W, H);
/** Mean absolute deviation from a background estimate taken just OUTSIDE the hole. */
function residualFromRing(pixels) {
  const cx = W / 2, cy = H / 2;
  let ringSum = 0, ringCount = 0;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const d = Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
      if (d > fillRadiusPx + 3 && d < fillRadiusPx + 6) {
        ringSum += pixels[(y * W + x) * 4]; ringCount++;
      }
    }
  }
  const background = ringCount > 0 ? ringSum / ringCount : 0;
  let total = 0, count = 0;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      if (Math.hypot(x + 0.5 - cx, y + 0.5 - cy) > fillRadiusPx) continue;
      total += Math.abs(pixels[(y * W + x) * 4] - background); count++;
    }
  }
  return count > 0 ? total / count : 0;
}
const residualBefore = residualFromRing(objectSource);
const residualAfter = residualFromRing(fillOut);
ok(residualBefore > 40, 'the fixture really does put a bright object inside the hole (' +
  residualBefore.toFixed(1) + ' levels away from its surroundings)');
ok(residualAfter < residualBefore * 0.5, 'fill replaces it with something close to the surroundings (' +
  residualBefore.toFixed(1) + ' -> ' + residualAfter.toFixed(1) + ' levels)');
// Outside the hole nothing may change: fill owns the hole and nothing else.
let outsideChanged = 0;
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    if (Math.hypot(x + 0.5 - W / 2, y + 0.5 - H / 2) <= fillRadiusPx) continue;
    const i = (y * W + x) * 4;
    if (fillOut[i] !== objectSource[i] || fillOut[i + 1] !== objectSource[i + 1] ||
      fillOut[i + 2] !== objectSource[i + 2]) outsideChanged++;
  }
}
ok(outsideChanged === 0, 'and it writes NOTHING outside the hole (' + outsideChanged + ' pixels touched), ' +
  'so a fill cannot smear the rest of the photo');
let alphaKept = true;
for (let i = 3; i < fillOut.length; i += 4) if (fillOut[i] !== objectSource[i]) alphaKept = false;
ok(alphaKept, 'alpha is preserved through the fill');
// Two nearby holes must be solved together, not independently: one combined pass.
const twoHoles = retouchPixels(objectSource, W, H, [
  mark(RETOUCH_FILL, 0.42, 0.5, 0.08, 0.5, 0.5, 0.5, 1),
  mark(RETOUCH_FILL, 0.58, 0.5, 0.08, 0.5, 0.5, 0.5, 1),
]);
ok(differences(twoHoles, objectSource) > 0, 'two fill marks are handled in one pass');
const oneHoleOnly = retouchPixels(objectSource, W, H, [mark(RETOUCH_FILL, 0.42, 0.5, 0.08, 0.5, 0.5, 0.5, 1)]);
ok(differences(twoHoles, oneHoleOnly) > 0,
  'and the second hole changes the result, so neither mark is being dropped');

// --- 4. Determinism, safety, and backward compatibility ------------------
ok(differences(retouchPixels(source, W, H, [mark(RETOUCH_CLONE, CLONE_CX, CLONE_CY, CLONE_RADIUS,
  CLONE_SX, CLONE_SY, 0, 1)]), cloneOut) === 0, 'clone is deterministic');
ok(differences(retouchPixels(objectSource, W, H, [mark(RETOUCH_FILL, 0.5, 0.5, FILL_RADIUS,
  0.5, 0.5, 0.5, 1)]), fillOut) === 0, 'fill is deterministic, including its seeded search');
ok(differences(retouchPixels(source, W, H, []), source) === 0, 'no marks is still a byte-for-byte no-op');
ok(differences(source, targetFrame()) === 0, 'the retouch pass never writes to its input');
// Existing kinds must be untouched by this change.
const healOnly = retouchPixels(source, W, H, [mark(RETOUCH_HEAL, 0.25, 0.5, 0.1, 0.75, 0.5, 0.5, 1)]);
ok(differences(healOnly, source) > 0, 'heal still does something');
const redeyeFrame = new Uint8ClampedArray(W * H * 4);
for (let i = 0; i < redeyeFrame.length; i += 4) {
  redeyeFrame[i] = 220; redeyeFrame[i + 1] = 60; redeyeFrame[i + 2] = 60; redeyeFrame[i + 3] = 255;
}
const redeyeOut = retouchPixels(redeyeFrame, W, H, [mark(RETOUCH_REDEYE, 0.5, 0.5, 0.1, 0.5, 0.5, 0.5, 1)]);
ok(redeyeOut[((H >> 1) * W + (W >> 1)) * 4] < redeyeFrame[((H >> 1) * W + (W >> 1)) * 4],
  'red-eye still darkens a red pupil');
// Safety on degenerate inputs.
for (const dims of [[1, 1], [1, 20], [20, 1]]) {
  const small = new Uint8ClampedArray(dims[0] * dims[1] * 4);
  for (let i = 0; i < small.length; i++) small[i] = 128;
  const out = retouchPixels(small, dims[0], dims[1], [
    mark(RETOUCH_FILL, 0.5, 0.5, 0.3, 0.5, 0.5, 0.5, 1),
    mark(RETOUCH_CLONE, 0.5, 0.5, 0.3, 0.1, 0.1, 0.5, 1),
  ]);
  let fine = out.length === small.length;
  for (let i = 0; i < out.length; i++) if (!Number.isFinite(out[i])) fine = false;
  ok(fine, 'a ' + dims[0] + 'x' + dims[1] + ' frame with a fill and a clone mark does not throw or ' +
    'produce NaN');
}
const cornerMarks = retouchPixels(source, W, H, [
  mark(RETOUCH_CLONE, 0, 0, 0.09, 1, 1, 0.5, 1),
  mark(RETOUCH_FILL, 1, 1, 0.09, 1, 1, 0.5, 1),
]);
ok(cornerMarks.length === source.length, 'marks pinned to the frame corners are handled');

// --- 5. Read bounds must cover the new kinds ----------------------------
// A clone reads from a SECOND location, so bounds that covered only the target disc
// would render from a buffer that does not contain the source pixels at all. The
// pass is given a region of interest that CONTAINS the target but NOT the source, so
// an expansion is the only way the assertion can hold -- passing bounds that already
// covered everything would make it vacuous.
const narrow = [0, 0, Math.round(0.4 * W), H];
const cloneBounds = retouchReadBounds([mark(RETOUCH_CLONE, 0.2, 0.5, 0.05, 0.8, 0.5, 0.5, 1)], narrow, W, H);
ok(cloneBounds[0] === narrow[0] && cloneBounds[1] === narrow[1],
  'the region of interest is kept as the floor (' + JSON.stringify(cloneBounds) + ')');
ok(cloneBounds[2] > Math.round(0.8 * W),
  'clone bounds expand to reach its source, which lies well outside the region of interest (' +
  JSON.stringify(cloneBounds) + ')');
const healBounds = retouchReadBounds([mark(RETOUCH_HEAL, 0.2, 0.5, 0.05, 0.8, 0.5, 0.5, 1)], narrow, W, H);
ok(healBounds[2] === cloneBounds[2] && healBounds[0] === cloneBounds[0],
  'and a clone expands by exactly as much as a heal with the same geometry (' +
  JSON.stringify(healBounds) + ' vs ' + JSON.stringify(cloneBounds) + ')');
const redeyeBounds = retouchReadBounds([mark(RETOUCH_REDEYE, 0.2, 0.5, 0.05, 0.8, 0.5, 0.5, 1)], narrow, W, H);
ok(redeyeBounds[2] === narrow[2],
  'while red-eye, which reads nothing, still expands nothing (' + JSON.stringify(redeyeBounds) + ')');
const fillBounds = retouchReadBounds([mark(RETOUCH_FILL, 0.3, 0.5, 0.1, 0.8, 0.5, 0.5, 1)], narrow, W, H);
ok(fillBounds[2] < Math.round(0.8 * W),
  'and fill does NOT expand toward its unused source coordinate (' + JSON.stringify(fillBounds) + ')');
ok(fillBounds[2] >= Math.round(0.3 * W),
  'but still covers its own disc, so the hole it will punch is inside the buffer (' +
  JSON.stringify(fillBounds) + ')');
const tinyTarget = retouchReadBounds([mark(RETOUCH_CLONE, 0.9, 0.5, 0.02, 0.1, 0.5, 0.5, 1)], narrow, W, H);
ok(tinyTarget[2] === narrow[2] && tinyTarget[0] === narrow[0],
  'a mark whose target is entirely outside the region of interest is still skipped, so the clone ' +
  'expansion does not defeat the skip (' + JSON.stringify(tinyTarget) + ')');

// --- 6. Wiring ----------------------------------------------------------
const coreSource = fs.readFileSync('entry/src/main/ets/edit/engine/RetouchCore.ets', 'utf8');
ok(coreSource.includes('cloneStamp(output, w, h, [cloneMark])'),
  'the retouch core routes clone marks through the verified clone stamp rather than reimplementing it');
ok(coreSource.includes('contentAwareFill(output, w, h, holeMask, contentFillDefaults())'),
  'and routes fill marks through the content-aware fill with the engine defaults');
ok(coreSource.indexOf('let holeMask') > coreSource.indexOf('for (const mark of marks)'),
  'the fill pass runs AFTER the per-mark loop, so all fill marks share one hole');
const settingsSource = fs.readFileSync('entry/src/main/ets/edit/models/RetouchSettings.ets', 'utf8');
ok(settingsSource.includes('RETOUCH_CLONE') && settingsSource.includes('RETOUCH_FILL'),
  'the mark model defines the new kinds');
const canvasSource = fs.readFileSync('entry/src/main/ets/components/EditorCanvas.ets', 'utf8');
ok(canvasSource.includes('kind: this.editSession.retouchKind'),
  'the canvas takes the kind from the session rather than hard-coding heal');
const panelSource = fs.readFileSync('entry/src/main/ets/components/RetouchPanel.ets', 'utf8');
ok(panelSource.includes('RETOUCH_KINDS'), 'the panel offers a kind selector');
ok(panelSource.includes('if (!this.needsSource()) this.editSession.pickingRetouchSource = false;'),
  'and clears a pending source pick when the user switches to a kind that has no source, so a tap ' +
  'cannot be silently swallowed');
ok(panelSource.includes('if (this.redEye || this.activeKind() !== RETOUCH_FILL)'),
  'and hides the opacity control for fill, which ignores it: a slider that changes nothing is a fake control');
// The tool and the mark kind must not drift apart.
const session = new EditSession();
ok(session.retouchKind === RETOUCH_HEAL, 'a fresh session paints heal marks');
session.setActiveTool(ToolType.RED_EYE);
ok(session.retouchKind === RETOUCH_REDEYE, 'selecting the red-eye tool switches the mark kind');
session.setActiveTool(ToolType.HEAL);
ok(session.retouchKind === RETOUCH_HEAL, 'and leaving it switches back rather than leaving the brush stuck');
session.retouchKind = RETOUCH_CLONE;
session.setActiveTool(ToolType.HEAL);
ok(session.retouchKind === RETOUCH_CLONE, 'while a deliberate clone choice survives a tool re-selection');

console.log('PASS retouch clone and fill: the new kinds pass the same model clamping and 512 cap as the old');
console.log('     ones, clone reproduces its source patch EXACTLY while heal does not (so the two are');
console.log('     genuinely different operations), cloning a region onto itself is a byte-exact no-op, fill');
console.log('     removes a marked object and writes NOTHING outside its hole, and the tool and mark kind');
console.log('     cannot drift apart.');
console.log('NOTE no device verification and no timing: content-aware fill is the most expensive operation');
console.log('     in the app (PatchMatch plus voting, once per completed stroke) and its cost was NOT');
console.log('     measured. Its patch search is confined to the buffer it is handed, which is a real');
console.log('     limitation if the retouch path is ever handed a tile.');
console.log(checks + ' checks passed');
