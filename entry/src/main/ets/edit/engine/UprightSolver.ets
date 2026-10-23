/**
 * Upright: solve the manual geometry's projective terms from guide lines.
 *
 * The geometry engine (GeometryMath) applies, in NORMALIZED source coordinates
 * `(X, Y)` with the origin at the frame centre and the half-extent at 1:
 *
 *     u = X / D,  v = Y / D,  D = 1 + px*X + py*Y
 *
 * followed by the straighten/aspect/scale matrix. `px` and `py` are the manual
 * perspective sliders: g[1]/160 and g[0]/160.
 *
 * That is a genuine projective map, so a straight line stays straight; Upright's
 * job is to choose `px`/`py` so that the lines a user marked come out vertical
 * and horizontal. Solving it exactly is what this module does, and it turns out
 * to decouple completely:
 *
 *   - A line `X = alpha + beta*Y` maps to a VERTICAL line iff `py = beta/alpha`.
 *     `px` cancels out of that condition, so a vertical guide constrains py and
 *     nothing else.
 *   - A line `Y = gamma + delta*X` maps to a HORIZONTAL line iff `px = delta/gamma`.
 *
 * (Both follow from requiring the mapped coordinate to be constant along the
 * line; see the derivation in the tests, which verify the result through the
 * real projection rather than by re-deriving it here.)
 *
 * The practical consequence: guides AGREE exactly when their common vanishing
 * point lies on the corresponding centre axis, which is the ordinary case — a
 * building photographed head-on has its verticals converging above or below the
 * frame centre. A left edge `alpha = -0.5, beta = +0.12` and a right edge
 * `alpha = +0.5, beta = -0.12` meet on the vertical centre line and both demand
 * `py = -0.24`, so the solve is exact rather than a fit.
 *
 * LIMITATION, inherent to a two-parameter tilt rather than to this
 * implementation: two lines that are merely PARALLEL (their vanishing point is
 * at infinity) but have different intercepts cannot both be made vertical, and
 * neither can lines whose vanishing point is off the centre axis. Such guides
 * disagree, and `residual` reports how much, so a caller can refuse the solve
 * instead of silently averaging a contradiction. Correcting those cases needs a
 * full homography, which the manual geometry controls do not expose.
 *
 * This module is pure: no imports, no I/O, no randomness, and it never mutates
 * its inputs.
 */

/** Normalized units per slider unit: the geometry engine divides g[0]/g[1] by
 *  this, so multiplying back converts a solved coefficient into a g value. */
const PERSPECTIVE_UNITS: number = 160;

/** Below this an intercept is treated as zero. A guide whose line passes through
 *  the frame's own centre axis carries no perspective information: `beta/alpha`
 *  diverges, so including it would inject an enormous value into the mean. */
const MIN_INTERCEPT: number = 0.02;

/** Shortest guide accepted, in normalized units, and the smallest run of the
 *  independent coordinate. A guide shorter than this has an unreliable slope. */
const MIN_LINE_LENGTH: number = 0.01;

/** The manual perspective sliders span +-100, i.e. +-0.625 normalized, and the
 *  straighten slider +-45 degrees. Solved values are clamped into those ranges so
 *  Upright can never emit a value the manual controls cannot represent. */
const MAX_PERSPECTIVE: number = 0.625;
const MAX_ROTATION_DEGREES: number = 45;

/** A guide line in NORMALIZED source coordinates ([-1,1], y down). The caller is
 *  responsible for converting from source pixels. */
export interface UprightGuide {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  /** True if this line should come out vertical, false if horizontal. */
  vertical: boolean;
}

export interface UprightSolution {
  /** Value for geometry g[0]. */
  verticalPerspective: number;
  /** Value for geometry g[1]. */
  horizontalPerspective: number;
  /** Value for geometry g[2], in degrees. */
  rotation: number;
  /** Guides that actually contributed a constraint. */
  verticalGuides: number;
  horizontalGuides: number;
  /**
   * Largest disagreement between the accepted guides of one direction, in
   * normalized perspective units. 0 means the guides share a vanishing point;
   * a large value means they contradict each other and the result is a
   * compromise. Reported instead of being folded silently into the mean.
   */
  residual: number;
}

export function uprightIsEmpty(solution: UprightSolution): boolean {
  return solution.verticalGuides === 0 && solution.horizontalGuides === 0;
}

/** True when the solution would not change the geometry at all. */
export function uprightIsIdentity(solution: UprightSolution): boolean {
  return solution.verticalPerspective === 0 && solution.horizontalPerspective === 0 &&
    solution.rotation === 0;
}

function mean(values: number[]): number {
  let total = 0;
  for (let i = 0; i < values.length; i++) total += values[i];
  return values.length > 0 ? total / values.length : 0;
}

function clamp(input: number, limit: number): number {
  if (!Number.isFinite(input)) return 0;
  return Math.max(-limit, Math.min(limit, input));
}

/**
 * What to solve for, mirroring Camera Raw's Upright modes.
 *
 * LEVEL rotates only, which is what a user wants when the horizon is tilted and
 * the verticals are fine: correcting it with perspective instead would introduce
 * keystone distortion nobody asked for. PERSPECTIVE solves the tilt only.
 * FULL does the perspective and then whatever straighten is still needed.
 */
export enum UprightMode {
  LEVEL = 0,
  PERSPECTIVE = 1,
  FULL = 2,
}

/**
 * Solve the perspective and/or straighten terms implied by the guides.
 *
 * Lines that cannot contribute (degenerate, wrong orientation for their declared
 * direction, or passing through the centre axis) are skipped rather than
 * approximated, and the count of accepted guides is returned so a caller can
 * distinguish "solved from three lines" from "solved from nothing".
 */
export function solveUpright(guides: UprightGuide[] | undefined,
  mode: UprightMode = UprightMode.FULL): UprightSolution {
  const solution: UprightSolution = {
    verticalPerspective: 0, horizontalPerspective: 0, rotation: 0,
    verticalGuides: 0, horizontalGuides: 0, residual: 0,
  };
  if (!guides || guides.length === 0) return solution;

  // Pass 1: turn each guide into the exact coefficient it demands.
  const verticalDemands: number[] = [];
  const horizontalDemands: number[] = [];
  // Every usable horizontal line, as (delta, gamma) pairs, for the straighten
  // pass. A line rejected for perspective (it passes through the centre axis) can
  // still carry a usable tilt, so it is kept here.
  const horizontalLines: number[] = [];
  for (let i = 0; i < guides.length; i++) {
    const guide = guides[i];
    if (!Number.isFinite(guide.x1) || !Number.isFinite(guide.y1) ||
      !Number.isFinite(guide.x2) || !Number.isFinite(guide.y2)) continue;
    const dx = guide.x2 - guide.x1;
    const dy = guide.y2 - guide.y1;
    if (Math.abs(dx) + Math.abs(dy) < MIN_LINE_LENGTH) continue;
    if (guide.vertical) {
      // X = alpha + beta*Y. A line with no run in Y is horizontal and can never
      // be made vertical, so it carries no information about py.
      if (Math.abs(dy) < MIN_LINE_LENGTH) continue;
      const beta = dx / dy;
      const alpha = guide.x1 - beta * guide.y1;
      if (Math.abs(alpha) < MIN_INTERCEPT) continue;
      verticalDemands.push(beta / alpha);
    } else {
      // Y = gamma + delta*X.
      if (Math.abs(dx) < MIN_LINE_LENGTH) continue;
      const delta = dy / dx;
      const gamma = guide.y1 - delta * guide.x1;
      horizontalLines.push(delta);
      horizontalLines.push(gamma);
      if (Math.abs(gamma) < MIN_INTERCEPT) continue;
      horizontalDemands.push(delta / gamma);
    }
  }

  if (mode !== UprightMode.LEVEL) {
    solution.verticalPerspective = clamp(mean(verticalDemands), MAX_PERSPECTIVE);
    solution.horizontalPerspective = clamp(mean(horizontalDemands), MAX_PERSPECTIVE);
    let residual = 0;
    for (let i = 0; i < verticalDemands.length; i++) {
      const difference = Math.abs(verticalDemands[i] - solution.verticalPerspective);
      if (difference > residual) residual = difference;
    }
    for (let i = 0; i < horizontalDemands.length; i++) {
      const difference = Math.abs(horizontalDemands[i] - solution.horizontalPerspective);
      if (difference > residual) residual = difference;
    }
    solution.residual = residual;
  }
  solution.verticalGuides = verticalDemands.length;
  solution.horizontalGuides = horizontalDemands.length;

  // Straighten. In LEVEL mode this is the line's own tilt in source space. In FULL
  // the tilt must be measured AFTER the perspective correction, because a guide's
  // direction in (u,v) is not its direction in (X,Y): along Y = gamma + delta*X the
  // tangent at the centre axis is proportional to (1, (delta*C - gamma*E)/C) with
  // C = 1 + py*gamma and E = px + py*delta. Averaging ANGLES rather than slopes
  // keeps one near-vertical guide from dominating the result.
  //
  // The sign is negative because the engine's forward map is a rotation by +theta
  // in (u,v) -- ux = c*u - s*v, uy = s*u + c*v -- so a line of slope m comes out
  // horizontal when s + c*m = 0, i.e. theta = -atan(m). The tests verify this by
  // measuring the marked line through the real projection rather than trusting the
  // derivation.
  //
  // Skipped ENTIRELY for PERSPECTIVE, which solves no rotation: running the algebra
  // anyway and relying on the residual cancelling leaves a rounding residue in the
  // field (measured 8e-16 of a degree here), and a mode selector that differs from
  // another mode only approximately is not a real control.
  const py = solution.verticalPerspective;
  const px = solution.horizontalPerspective;
  let angleSum = 0;
  let angleCount = 0;
  if (mode !== UprightMode.PERSPECTIVE) {
    for (let i = 0; i + 1 < horizontalLines.length; i += 2) {
      const delta = horizontalLines[i];
      const gamma = horizontalLines[i + 1];
      if (mode === UprightMode.LEVEL) {
        angleSum += -Math.atan(delta);
        angleCount++;
        continue;
      }
      const c = 1 + py * gamma;
      if (Math.abs(c) < MIN_INTERCEPT) continue;
      const e = px + py * delta;
      angleSum += -Math.atan((delta * c - gamma * e) / c);
      angleCount++;
    }
  }
  if (angleCount > 0) {
    const degrees = (angleSum / angleCount) * 180 / Math.PI;
    solution.rotation = clamp(degrees, MAX_ROTATION_DEGREES);
  }
  return solution;
}

/**
 * Write a solution into a geometry array (the 8-value session field).
 *
 * Only g[0] (vertical perspective), g[1] (horizontal) and g[2] (straighten) are
 * touched; aspect, scale, the spare slots and the auto-crop flag are preserved,
 * because Upright is a solution for the perspective and nothing else. Returns a
 * new array rather than mutating the session's.
 */
export function applyUpright(geometry: number[], solution: UprightSolution): number[] {
  const result: number[] = [];
  for (let i = 0; i < geometry.length; i++) {
    const value = geometry[i];
    result.push(Number.isFinite(value) ? value : 0);
  }
  while (result.length < 8) result.push(0);
  result[0] = solution.verticalPerspective * PERSPECTIVE_UNITS;
  result[1] = solution.horizontalPerspective * PERSPECTIVE_UNITS;
  result[2] = solution.rotation;
  return result;
}

/** Convert a guide given in source PIXELS into normalized coordinates, which is
 *  what solveUpright expects. Kept here so every caller uses one convention, and
 *  it is deliberately the SAME half-pixel convention GeometryMath uses when it
 *  converts a pixel to normalized coordinates, so a guide and the projection that
 *  will later be applied to it agree about where the line is. */
export function normalizeGuide(guide: UprightGuide, width: number, height: number): UprightGuide {
  const w = Math.max(1, width);
  const h = Math.max(1, height);
  const result: UprightGuide = {
    x1: 2 * (guide.x1 + 0.5) / w - 1, y1: 2 * (guide.y1 + 0.5) / h - 1,
    x2: 2 * (guide.x2 + 0.5) / w - 1, y2: 2 * (guide.y2 + 0.5) / h - 1,
    vertical: guide.vertical,
  };
  return result;
}

/**
 * Map a stored numeric mode onto the enum.
 *
 * Sidecars are plain JSON, so an out-of-range, missing or corrupt mode has to
 * land somewhere sensible rather than on an undefined enum member: anything
 * unrecognised becomes FULL, which is the most capable mode and the one the UI
 * offers first.
 */
export function uprightModeFromNumber(value: number): UprightMode {
  if (value === UprightMode.LEVEL) return UprightMode.LEVEL;
  if (value === UprightMode.PERSPECTIVE) return UprightMode.PERSPECTIVE;
  return UprightMode.FULL;
}

/**
 * Solver entry point for guides stored in NORMALIZED source coordinates ([0,1],
 * origin at the top-left corner), which is how the editor captures, persists and
 * re-draws them.
 *
 * The conversion into the centre-origin [-1,1] frame the algebra is written in
 * lives here and nowhere else. `2 * n - 1` is exactly `normalizeGuide`'s
 * convention applied to an already-normalized coordinate, so a guide captured
 * from a touch and the projection later applied to it agree about where the line
 * is regardless of the preview resolution.
 */
export function solveUprightNormalized(guides: UprightGuide[] | undefined,
  mode: UprightMode = UprightMode.FULL): UprightSolution {
  if (!guides || guides.length === 0) return solveUpright(undefined, mode);
  const converted: UprightGuide[] = [];
  for (let i = 0; i < guides.length; i++) {
    const guide = guides[i];
    const item: UprightGuide = {
      x1: 2 * guide.x1 - 1, y1: 2 * guide.y1 - 1,
      x2: 2 * guide.x2 - 1, y2: 2 * guide.y2 - 1,
      vertical: guide.vertical,
    };
    converted.push(item);
  }
  return solveUpright(converted, mode);
}
