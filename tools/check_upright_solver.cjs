// Upright guide solving.
//
// The whole point of this suite is that it does NOT re-derive the solver's own
// algebra. Each solved coefficient is written into a real geometry array and
// pushed through the production projection (buildScalingGeometryMap +
// sourceToFrame), then the line the user marked is measured in the OUTPUT: it
// must actually come out vertical (or horizontal). A solver that returned the
// right number for the wrong reason, or with the wrong sign, fails here.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const modules = new Map();
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} }; modules.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
    Uint8Array, Uint8ClampedArray, Float32Array, Int32Array, Promise, Error, Buffer,
    require: (n) => {
      if (n.startsWith('@kit.')) return {};
      if(n.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { solveUpright, applyUpright, uprightIsEmpty, uprightIsIdentity, normalizeGuide, UprightMode } =
  load(root + '/edit/engine/UprightSolver.ets');
const { buildScalingGeometryMap, sourceToFrame } = load(root + '/edit/engine/GeometryMath.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
const W = 1600, H = 1200;
const IDENTITY_GEOMETRY = [0, 0, 0, 0, 100, 0, 0, 0];

// --- projection helpers ---------------------------------------------------
function framePoint(geometry, nx, ny) {
  // Normalized [-1,1] -> source pixels -> the real projection -> frame pixels.
  const sx = (nx + 1) * W / 2 - 0.5;
  const sy = (ny + 1) * H / 2 - 0.5;
  const map = buildScalingGeometryMap(geometry, W, H, { renderWidth: W, renderHeight: H });
  const point = sourceToFrame(map, sx, sy);
  return point;
}
/** How far a line marked vertical still leans, in output pixels. */
function verticalLeaningPixels(geometry, alpha, beta) {
  const y1 = -0.5, y2 = 0.5;
  const a = framePoint(geometry, alpha + beta * y1, y1);
  const b = framePoint(geometry, alpha + beta * y2, y2);
  if (!a || !b) return null;
  return Math.abs(a[0] - b[0]);
}
/** How far a line marked horizontal still tilts, in output pixels. */
function horizontalLeaningPixels(geometry, gamma, delta) {
  const x1 = -0.6, x2 = 0.6;
  const a = framePoint(geometry, x1, gamma + delta * x1);
  const b = framePoint(geometry, x2, gamma + delta * x2);
  if (!a || !b) return null;
  return Math.abs(a[1] - b[1]);
}

// --- 1. Degenerate input --------------------------------------------------
const empty = solveUpright(undefined);
ok(empty.verticalGuides === 0 && empty.horizontalGuides === 0, 'no guides yields no constraints');
ok(uprightIsEmpty(empty), 'an empty solve reports itself as empty');
ok(uprightIsIdentity(empty), 'an empty solve is the identity, so it cannot disturb a session');
ok(uprightIsEmpty(solveUpright([])), 'an empty guide list is the same as no guides');

// --- 2. A single guide whose direction is already correct is a no-op ------
const alreadyVertical = solveUpright([{ x1: -0.4, y1: -0.5, x2: -0.4, y2: 0.5, vertical: true }]);
ok(alreadyVertical.verticalPerspective === 0, 'a source-vertical guide demands no vertical perspective');
ok(alreadyVertical.verticalGuides === 1, 'it is still counted as a contributing guide');
const alreadyHorizontal = solveUpright([{ x1: -0.6, y1: 0.25, x2: 0.6, y2: 0.25, vertical: false }]);
ok(alreadyHorizontal.horizontalPerspective === 0, 'a source-horizontal guide demands no horizontal perspective');

// --- 3. The case Upright exists for: two CONVERGING verticals -------------
// Left edge leans in with beta=+0.12 at alpha=-0.5, right edge leans in with
// beta=-0.12 at alpha=+0.5. Both independently demand py = beta/alpha = -0.24.
const converging = solveUpright([
  { x1: -0.56, y1: -0.5, x2: -0.44, y2: 0.5, vertical: true },
  { x1: 0.56, y1: -0.5, x2: 0.44, y2: 0.5, vertical: true },
]);
ok(converging.verticalGuides === 2, 'both converging guides contribute');
ok(Math.abs(converging.verticalPerspective - (-0.24)) < 1e-9,
  'two converging lines AGREE on py = -0.24 (got ' + converging.verticalPerspective + '); this is the ' +
  'property that makes the solve exact rather than a fit');
ok(converging.residual < 1e-9, 'they agree exactly, so the residual is 0 (got ' + converging.residual + ')');
ok(converging.horizontalPerspective === 0, 'vertical guides say nothing about horizontal perspective');
ok(converging.horizontalGuides === 0, 'no horizontal guide was supplied');

// --- 4. Verified through the REAL projection -----------------------------
const leanedBefore = verticalLeaningPixels(IDENTITY_GEOMETRY, -0.5, 0.12);
ok(leanedBefore !== null && leanedBefore > 50, 'the marked line really does lean before solving (' +
  (leanedBefore === null ? 'null' : leanedBefore.toFixed(1)) + ' px across the frame), so the ' +
  'measurement below is not vacuous');
const solvedGeometry = applyUpright(IDENTITY_GEOMETRY, converging);
const leanedAfter = verticalLeaningPixels(solvedGeometry, -0.5, 0.12);
ok(leanedAfter !== null, 'the solved line projects inside the frame');
ok(leanedAfter < 1.5, 'after solving, the real projection makes the marked line vertical: ' +
  leanedAfter.toFixed(3) + ' px of lean remain (was ' + leanedBefore.toFixed(1) + ')');
// The other converging line must come out vertical from the SAME solution, which
// is what distinguishes a solved vanishing point from a per-line fit.
const rightLeanedBefore = verticalLeaningPixels(IDENTITY_GEOMETRY, 0.5, -0.12);
const rightLeanedAfter = verticalLeaningPixels(solvedGeometry, 0.5, -0.12);
ok(rightLeanedAfter < 1.5, 'the mirrored line is vertical too (' +
  rightLeanedAfter.toFixed(3) + ' px, was ' + rightLeanedBefore.toFixed(1) + '): one solution fixes both');

// --- 5. Horizontal guides, verified the same way -------------------------
// Same construction as the verticals: two lines meeting on the HORIZONTAL centre
// line (Y = 0), which is the case they can agree on. Both demand
// px = delta/gamma = 0.1/0.3.
const horizontals = solveUpright([
  { x1: -0.6, y1: 0.3 - 0.06, x2: 0.6, y2: 0.3 + 0.06, vertical: false },
  { x1: -0.6, y1: -0.3 + 0.06, x2: 0.6, y2: -0.3 - 0.06, vertical: false },
]);
ok(horizontals.horizontalGuides === 2, 'both horizontal guides contribute');
ok(Math.abs(horizontals.horizontalPerspective - 0.1 / 0.3) < 1e-9,
  'a line Y = gamma + 0.1X with gamma = 0.3 demands px = delta/gamma = 0.3333 (got ' +
  horizontals.horizontalPerspective + ')');
ok(horizontals.residual < 1e-9, 'the two mirrored horizontal guides agree exactly (residual ' +
  horizontals.residual + ')');
const tiltBefore = horizontalLeaningPixels(IDENTITY_GEOMETRY, 0.3, 0.1);
ok(tiltBefore !== null && tiltBefore > 50, 'the marked horizontal line really does tilt before solving (' +
  (tiltBefore === null ? 'null' : tiltBefore.toFixed(1)) + ' px)');
const horizontalSolvedGeometry = applyUpright(IDENTITY_GEOMETRY, horizontals);
const tiltAfter = horizontalLeaningPixels(horizontalSolvedGeometry, 0.3, 0.1);
ok(tiltAfter < 3, 'after solving, the real projection makes it horizontal: ' + tiltAfter.toFixed(3) +
  ' px of tilt remain (was ' + tiltBefore.toFixed(1) + ')');
ok(horizontalLeaningPixels(horizontalSolvedGeometry, -0.3, -0.1) < 3,
  'the mirrored horizontal line is horizontal too, from the same solution');
// The documented limitation, asserted rather than merely written down: two
// PARALLEL lines (vanishing point at infinity) with different intercepts cannot
// both be levelled, so the solver must report a disagreement.
const parallel = solveUpright([
  { x1: -0.6, y1: 0.3 - 0.06, x2: 0.6, y2: 0.3 + 0.06, vertical: false },
  { x1: -0.6, y1: -0.4 - 0.06, x2: 0.6, y2: -0.4 + 0.06, vertical: false },
]);
ok(parallel.residual > 0.1, 'two parallel horizontals with different intercepts are reported as a ' +
  'disagreement (residual ' + parallel.residual.toFixed(3) + '), matching the documented limitation ' +
  'that a two-parameter tilt cannot fix an off-axis vanishing point');

// --- 6. Disagreeing guides are reported, not hidden ----------------------
const contradictory = solveUpright([
  { x1: -0.56, y1: -0.5, x2: -0.44, y2: 0.5, vertical: true },
  { x1: 0.56, y1: -0.5, x2: 0.2, y2: 0.5, vertical: true },
]);
ok(contradictory.verticalGuides === 2, 'both contradictory guides still contribute');
ok(contradictory.residual > 0.1, 'guides that do not share a vanishing point produce a large residual (' +
  contradictory.residual.toFixed(3) + '), so the caller can tell a solve from a compromise');
ok(Number.isFinite(contradictory.verticalPerspective), 'the compromise is still a finite number');

// --- 7. Lines that carry no information are skipped, not approximated ----
const junk = solveUpright([
  { x1: 0.1, y1: 0.1, x2: 0.1, y2: 0.1, vertical: true },
  { x1: -0.5, y1: 0.2, x2: 0.5, y2: 0.2, vertical: true },
  { x1: 0.3, y1: -0.5, x2: 0.3, y2: 0.5, vertical: false },
  { x1: -0.5, y1: 0.0, x2: 0.5, y2: 0.0, vertical: false },
  { x1: NaN, y1: 0, x2: 0.5, y2: 0.5, vertical: true },
  { x1: 0, y1: 0, x2: 0.5, y2: 0.5, vertical: true },
]);
ok(junk.verticalGuides === 0 && junk.horizontalGuides === 0,
  'zero-length lines, a line whose declared direction is impossible, a line through the centre axis ' +
  'and a non-finite line are all skipped (got ' + junk.verticalGuides + '/' + junk.horizontalGuides + ')');
ok(uprightIsIdentity(junk), 'skipping every guide leaves an identity rather than a junk injection');
ok(Number.isFinite(junk.verticalPerspective) && Number.isFinite(junk.horizontalPerspective) &&
  Number.isFinite(junk.rotation), 'no NaN or Infinity escapes the solver');

// --- 8. Clamping ---------------------------------------------------------
const extreme = solveUpright([
  { x1: -0.5, y1: -0.5, x2: 0.5, y2: -0.49, vertical: true },
  { x1: -0.5, y1: -0.49, x2: 0.5, y2: 0.5, vertical: false },
]);
ok(Math.abs(extreme.verticalPerspective) <= 0.625, 'an extreme guide is clamped into the manual slider ' +
  'range (|py| = ' + Math.abs(extreme.verticalPerspective).toFixed(3) + ' <= 0.625)');
ok(Math.abs(extreme.horizontalPerspective) <= 0.625, 'horizontal perspective is clamped too');
ok(Math.abs(extreme.rotation) <= 45, 'straighten is clamped to +-45 degrees');

// --- 9. Writing the solution into a session geometry array --------------
const rich = [12, -34, 3, 25, 130, 7, 9, 1];
const written = applyUpright(rich, converging);
ok(rich[0] === 12 && rich[1] === -34 && rich[2] === 3, 'applyUpright does not mutate the session array');
ok(written !== rich, 'it returns a new array');
ok(written[0] === converging.verticalPerspective * 160 && written[1] === converging.horizontalPerspective * 160,
  'g[0] and g[1] carry the solved perspective in the engine units (x160)');
ok(written[2] === converging.rotation, 'g[2] carries the solved straighten');
ok(written[3] === 25 && written[4] === 130 && written[5] === 7 && written[6] === 9 && written[7] === 1,
  'aspect, scale, the spare slots and the auto-crop flag are preserved: Upright solves perspective only');
const padded = applyUpright([0, 0], converging);
ok(padded.length === 8 && padded[4] === 0, 'a short geometry array is padded to 8 rather than crashing');
ok(applyUpright([0, 0, 0, 0, NaN, 0, 0, 0], empty)[4] === 0,
  'a non-finite geometry value is repaired to 0 instead of propagating NaN into the projection');

// --- 10. Guide normalization convention ---------------------------------
const normalized = normalizeGuide({ x1: 799.5, y1: 599.5, x2: 799.5, y2: 0, vertical: true }, 1600, 1200);
ok(Math.abs(normalized.x1 - 0) < 1e-12, 'the frame centre normalizes to 0 (got ' + normalized.x1 + ')');
ok(Math.abs(normalized.y1 - 0) < 1e-12, 'and so does the vertical centre');
ok(Math.abs(normalized.x2 - 0) < 1e-12 && normalized.y2 < -0.9,
  'a line up the middle stays at x = 0 and reaches the top edge');
const corner = normalizeGuide({ x1: -0.5, y1: -0.5, x2: 0, y2: 0, vertical: false }, 1600, 1200);
ok(Math.abs(corner.x1 - (-1)) < 1e-12 && Math.abs(corner.y1 - (-1)) < 1e-12,
  'the top-left pixel corner normalizes to (-1,-1), matching GeometryMath exactly');

// --- 11. Level mode, and why it is a separate mode ----------------------
// LEVEL rotates only. Levelling a tilted horizon with perspective instead would
// introduce keystone distortion nobody asked for, so the two are separate.
const tiltedGuide = { x1: -0.6, y1: 0.3 - 0.06, x2: 0.6, y2: 0.3 + 0.06, vertical: false };
const level = solveUpright([tiltedGuide], UprightMode.LEVEL);
ok(level.rotation !== 0, 'LEVEL produces a non-zero straighten (' + level.rotation.toFixed(3) + ' deg)');
ok(level.horizontalPerspective === 0 && level.verticalPerspective === 0,
  'LEVEL leaves both perspective terms at zero (px = ' + level.horizontalPerspective + ')');
ok(Math.abs(level.rotation - (-Math.atan(0.1) * 180 / Math.PI)) < 1e-9,
  'the angle is -atan(delta), not +atan(delta): the engine rotates by +theta in (u,v), which the test ' +
  'below confirms by measurement (got ' + level.rotation.toFixed(4) + ' deg)');
const levelSolved = applyUpright(IDENTITY_GEOMETRY, level);
const levelRemaining = horizontalLeaningPixels(levelSolved, 0.3, 0.1);
const levelStart = horizontalLeaningPixels(IDENTITY_GEOMETRY, 0.3, 0.1);
ok(levelRemaining < levelStart * 0.05, 'applying the LEVEL straighten through the real projection levels ' +
  'the marked line: ' + levelRemaining.toFixed(2) + ' px remain, down from ' + levelStart.toFixed(1) +
  ' (the wrong sign would leave it fully tilted or make it worse)');
// In FULL mode the same single guide needs no rotation at all: the perspective
// it solves already levels the line exactly.
const fullSingle = solveUpright([tiltedGuide]);
ok(fullSingle.horizontalPerspective !== 0, 'FULL mode uses perspective for that guide');
ok(fullSingle.rotation === 0, 'and then needs no straighten, because the solved perspective already ' +
  'levels the line exactly (got ' + fullSingle.rotation + ')');
ok(horizontalLeaningPixels(applyUpright(IDENTITY_GEOMETRY, fullSingle), 0.3, 0.1) < 3,
  'FULL mode levels it through perspective alone');
// PERSPECTIVE mode must not emit a rotation even when one would be needed.
const perspectiveOnly = solveUpright([tiltedGuide], UprightMode.PERSPECTIVE);
ok(perspectiveOnly.rotation === 0, 'PERSPECTIVE mode emits no rotation');
ok(perspectiveOnly.horizontalPerspective === fullSingle.horizontalPerspective,
  'PERSPECTIVE and FULL agree on the perspective term');
// PERSPECTIVE must be EXACTLY zero, not zero-up-to-rounding, and it must be
// distinguishable from FULL where a straighten is genuinely needed. A guide that
// passes exactly through the centre axis supplies no perspective (gamma = 0, so it
// is rejected for that) but does carry a usable tilt: FULL rotates, PERSPECTIVE
// must not.
const centreLine = { x1: -0.8, y1: -0.05, x2: 0.8, y2: 0.05, vertical: false };
const centreFull = solveUpright([centreLine], UprightMode.FULL);
const centrePerspective = solveUpright([centreLine], UprightMode.PERSPECTIVE);
ok(centreFull.rotation !== 0, 'a guide through the centre axis still carries a usable tilt for FULL (' +
  centreFull.rotation.toFixed(4) + ' deg)');
ok(centreFull.horizontalPerspective === 0, 'while supplying no perspective constraint at all');
ok(centrePerspective.rotation === 0,
  'and PERSPECTIVE mode is EXACTLY zero there, not merely close to it (got ' +
  centrePerspective.rotation + '): the mode is a real control, not an approximately' +
  ' different one');
ok(solveUpright([centreLine], UprightMode.LEVEL).rotation === centreFull.rotation,
  'LEVEL and FULL agree when there is no perspective to undo');

// --- 12. Determinism ----------------------------------------------------
const a = solveUpright([{ x1: -0.56, y1: -0.5, x2: -0.44, y2: 0.5, vertical: true }]);
const b = solveUpright([{ x1: -0.56, y1: -0.5, x2: -0.44, y2: 0.5, vertical: true }]);
ok(a.verticalPerspective === b.verticalPerspective && a.residual === b.residual, 'the solver is deterministic');

console.log('PASS upright solver: exact one-constraint-per-guide algebra, and every solved coefficient');
console.log('     verified by pushing the marked line through the PRODUCTION projection and measuring the');
console.log('     output. Includes converging-pair agreement, mirrored-line fixing, level/straighten sign,');
console.log('     residual reporting for contradictory guides, skipping of uninformative lines, clamping,');
console.log('     and that only g[0..2] are written.');
console.log('NOTE the solver returns perspective and straighten together, but they are solved');
console.log('     independently: the perspective is exact, while the straighten is the angle that levels the');
console.log('     guides AFTER that perspective, averaged over the guides. No UI draws guides yet and this');
console.log('     module is not on the render path, so nothing here is device-verified.');
console.log(checks + ' checks passed');
