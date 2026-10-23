/**
 * Point-curve geometry shared by the curve UI and by any future command/MCP
 * entry point. Everything here is a pure function over a structural
 * `{x, y}` anchor: it never imports ArkUI, never touches the session, and
 * never mutates the array it is given.
 *
 * Endpoint semantics (the reason this file exists)
 * ------------------------------------------------
 * A tone curve keeps its two endpoint anchors at the corners of the graph in
 * the x sense -- index 0 is the black point, index length-1 the white point --
 * but both are real, draggable anchors:
 *
 *   black point  slides along the BOTTOM edge (y = 0, x free) to set the input
 *                level that maps to black, or up the LEFT edge (x = 0, y free)
 *                to lift the shadows off zero.
 *   white point  slides along the TOP edge (y = 1, x free) to set the input
 *                level that maps to white, or down the RIGHT edge (x = 1,
 *                y free) to pull the highlights below one.
 *
 * Which of the two edges an endpoint follows is decided by the first move that
 * actually changes the anchor, from that move's target coordinates, and is then
 * locked for the rest of the gesture so it cannot jump between edges. Deciding
 * it at press time would be wrong: a press on the (0,0) or (1,1) corner is
 * equidistant from both of its edges and would always land on the horizontal
 * one, making the vertical axis unreachable.
 * Interior anchors still move on both axes and stay between their neighbours.
 *
 * Reference for the constraint shape (endpoints pinned in x, interior points
 * kept at a minimum x spacing, endpoints never deletable, drag clamped between
 * neighbours): Lightcraft, an MIT OR Apache-2.0 clean-room Lightroom-alike,
 * `crates/ui-egui/src/panels/edit.rs` (point-curve drag: `lo`/`hi` clamp of
 * 0.01, double-click delete refuses `i == 0` and `i == len-1`) and
 * `crates/develop/src/settings.rs` (`ToneCurve`: point curves in 0..1,
 * identity = [(0,0),(1,1)]). Local copy:
 * tmp/render-audit-20261012/lightcraft-source/lightcraft-main (LICENSE-MIT,
 * LICENSE-APACHE). The local Swift reference tmp/comp/CameraRawColor.swift
 * `repair()` agrees: `sorted[0].x = 0`, `sorted[last].x = 1`, interior points
 * dropped when closer than 0.01. It is a local working copy with no licence
 * file of its own and was used for semantics only, not copied.
 */

/** Structural anchor. `CurveAnchor` from models/Adjustment satisfies it. */
export interface CurveAnchorLike {
  x: number;
  y: number;
}

/** Which way an anchor is allowed to travel during one gesture. */
export enum CurveDragAxis {
  /** Interior anchor: both axes follow the pointer. */
  BOTH = -1,
  /** Endpoint on a horizontal edge (bottom for black, top for white). */
  X = 0,
  /** Endpoint on a vertical edge (left for black, right for white). */
  Y = 1,
}

/** Minimum x distance kept between neighbours, matching the existing UI. */
export const CURVE_MIN_GAP: number = 0.01;

/** Default hit radius, in pixels, for grabbing an anchor. */
export const CURVE_HIT_RADIUS: number = 17;

export interface CurveMoveResult {
  /** A clone of the anchors after the move; the input is never modified. */
  points: CurveAnchorLike[];
  /** False when the request was rejected (bad index, NaN, degenerate curve). */
  moved: boolean;
  /** The axis actually applied, so callers can show it. */
  axis: CurveDragAxis;
}

function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(1, value));
}

/** Shallow clone: the caller's anchors are never mutated in place. */
export function cloneCurveAnchors(points: CurveAnchorLike[]): CurveAnchorLike[] {
  const result: CurveAnchorLike[] = [];
  for (let index = 0; index < points.length; index++) {
    result.push({ x: points[index].x, y: points[index].y });
  }
  return result;
}

function isUsableAnchor(value: CurveAnchorLike | undefined): boolean {
  return !!value && Number.isFinite(value.x) && Number.isFinite(value.y) &&
    value.x >= 0 && value.x <= 1 && value.y >= 0 && value.y <= 1;
}

function isUsableCurve(points: CurveAnchorLike[]): boolean {
  if (!points || points.length < 2) return false;
  for (let index = 0; index < points.length; index++) {
    if (!isUsableAnchor(points[index]) || (index > 0 && points[index].x <= points[index - 1].x)) return false;
  }
  return true;
}

/** Inserts an interior anchor; an endpoint moved in x must remain an endpoint. */
export function addCurveAnchor(points: CurveAnchorLike[], x: number, y: number): CurveMoveResult {
  if (!isUsableCurve(points) || !Number.isFinite(x) || !Number.isFinite(y) ||
    x <= points[0].x || x >= points[points.length - 1].x) {
    return { points: cloneCurveAnchors(points ?? []), moved: false, axis: CurveDragAxis.BOTH };
  }
  for (let index = 0; index < points.length; index++) {
    if (Math.abs(points[index].x - x) < CURVE_MIN_GAP) {
      return { points: cloneCurveAnchors(points), moved: false, axis: CurveDragAxis.BOTH };
    }
  }
  const updated = cloneCurveAnchors(points);
  updated.push({ x: x, y: clamp01(y) });
  updated.sort((left: CurveAnchorLike, right: CurveAnchorLike): number => left.x - right.x);
  return { points: updated, moved: true, axis: CurveDragAxis.BOTH };
}

/** Removes interior anchors only, retaining the two endpoints and input ownership. */
export function removeCurveAnchor(points: CurveAnchorLike[], index: number): CurveMoveResult {
  if (!isUsableCurve(points) || !Number.isInteger(index) || index <= 0 || index >= points.length - 1) {
    return { points: cloneCurveAnchors(points ?? []), moved: false, axis: CurveDragAxis.BOTH };
  }
  const updated = cloneCurveAnchors(points);
  updated.splice(index, 1);
  return { points: updated, moved: true, axis: CurveDragAxis.BOTH };
}

/** True for the black (index 0) and white (last index) points. */
export function isCurveEndpoint(points: CurveAnchorLike[], index: number): boolean {
  if (!points || points.length < 2) return false;
  return index === 0 || index === points.length - 1;
}

/**
 * Which edge an endpoint should follow for a move whose target is (x, y).
 *
 * Returns BOTH for an interior anchor (it is not constrained to an edge) and
 * for anything that is not an endpoint of a curve with at least two anchors.
 * The comparison is made in normalized curve space so it is independent of the
 * pixel size of the graph.
 */
export function curvePickEndpointAxis(points: CurveAnchorLike[], index: number,
  x: number, y: number): CurveDragAxis {
  if (!isCurveEndpoint(points, index)) return CurveDragAxis.BOTH;
  if (!Number.isFinite(x) || !Number.isFinite(y)) return CurveDragAxis.BOTH;
  const safeX = clamp01(x);
  const safeY = clamp01(y);
  if (index === 0) {
    // Bottom edge (y = 0) versus left edge (x = 0), whichever is nearer.
    return safeY <= safeX ? CurveDragAxis.X : CurveDragAxis.Y;
  }
  // Top edge (y = 1) versus right edge (x = 1), whichever is nearer.
  return 1 - safeY <= 1 - safeX ? CurveDragAxis.X : CurveDragAxis.Y;
}

/**
 * x-gap actually enforced between an interior anchor and a neighbour.
 *
 * A curve whose neighbours sit closer together than twice CURVE_MIN_GAP has no
 * room for a fixed gap, and a fixed gap would push the anchor PAST its
 * neighbour instead of between them. Shrinking the gap to a quarter of the
 * available span keeps the bounds strictly ordered, so the anchor can never
 * cross either neighbour.
 */
function interiorGap(lowX: number, highX: number): number {
  const span = highX - lowX;
  return Math.min(CURVE_MIN_GAP, span > 0 ? span / 4 : 0);
}

/**
 * Move one anchor to (x, y) under the curve constraints and return a new
 * array. Rejects a non-integer or out-of-range index, a NaN/Infinity
 * coordinate, and a curve with fewer than two anchors, by returning the input
 * unchanged with `moved: false`.
 *
 * `axis` is the axis locked for the gesture. BOTH means "not decided yet": for
 * an endpoint the axis is then derived from THIS move's target coordinates
 * (curvePickEndpointAxis) rather than from the press position, so a drag that
 * begins at the (0,0) or (1,1) corner is not permanently stuck on the
 * horizontal edge. `result.axis` reports the axis that was applied, letting a
 * caller lock it for the rest of the gesture.
 *
 * `moved` is false when the anchor ended up where it already was, so a gesture
 * that changes nothing cannot create an undo entry.
 */
export function moveCurveAnchor(points: CurveAnchorLike[], index: number, x: number, y: number,
  axis: CurveDragAxis = CurveDragAxis.BOTH): CurveMoveResult {
  if (!points || points.length < 2) {
    return { points: cloneCurveAnchors(points ?? []), moved: false, axis: CurveDragAxis.BOTH };
  }
  if (!Number.isInteger(index) || index < 0 || index >= points.length) {
    return { points: cloneCurveAnchors(points), moved: false, axis: CurveDragAxis.BOTH };
  }
  if (!isUsableCurve(points) || !Number.isFinite(x) || !Number.isFinite(y) ||
    (axis !== CurveDragAxis.BOTH && axis !== CurveDragAxis.X && axis !== CurveDragAxis.Y)) {
    return { points: cloneCurveAnchors(points), moved: false, axis: CurveDragAxis.BOTH };
  }
  const previous = index > 0 ? points[index - 1] : undefined;
  const next = index + 1 < points.length ? points[index + 1] : undefined;
  // A neighbour with a non-finite coordinate cannot bound the move; treat the
  // curve as unusable rather than silently producing anchors out of order.
  if ((index > 0 && !isUsableAnchor(previous)) || (index + 1 < points.length && !isUsableAnchor(next))) {
    return { points: cloneCurveAnchors(points), moved: false, axis: CurveDragAxis.BOTH };
  }
  const updated = cloneCurveAnchors(points);
  const safeY = clamp01(y);
  let appliedAxis: CurveDragAxis = axis;
  if (isCurveEndpoint(updated, index)) {
    // Endpoints never change their ordering: index 0 stays first, the last
    // index stays last, so no re-sorting is needed or allowed here.
    if (appliedAxis === CurveDragAxis.BOTH) {
      appliedAxis = curvePickEndpointAxis(updated, index, x, y);
    }
    if (index === 0) {
      const neighbour = updated[1];
      const highX = Math.max(0, Math.min(1, neighbour.x - CURVE_MIN_GAP));
      if (appliedAxis === CurveDragAxis.Y) {
        updated[0] = { x: 0, y: safeY };
      } else {
        updated[0] = { x: Math.max(0, Math.min(highX, clamp01(x))), y: 0 };
      }
    } else {
      const neighbour = updated[updated.length - 2];
      const lowX = Math.min(1, Math.max(0, neighbour.x + CURVE_MIN_GAP));
      const last = updated.length - 1;
      if (appliedAxis === CurveDragAxis.Y) {
        updated[last] = { x: 1, y: safeY };
      } else {
        updated[last] = { x: Math.min(1, Math.max(lowX, clamp01(x))), y: 1 };
      }
    }
  } else {
    const neighbourLow = previous ? previous.x : 0;
    const neighbourHigh = next ? next.x : 1;
    // Refuse to move between neighbours that are coincident or out of order:
    // there is no position that respects both, and clamping to an inverted
    // span is what let an anchor jump over its neighbour.
    if (neighbourHigh <= neighbourLow) {
      return { points: cloneCurveAnchors(points), moved: false, axis: CurveDragAxis.BOTH };
    }
    const gap = interiorGap(neighbourLow, neighbourHigh);
    const lowX = neighbourLow + gap;
    const highX = neighbourHigh - gap;
    updated[index] = { x: Math.max(lowX, Math.min(highX, clamp01(x))), y: safeY };
    appliedAxis = CurveDragAxis.BOTH;
  }
  const before = points[index];
  const after = updated[index];
  const moved = Math.abs(after.x - before.x) > 1e-9 || Math.abs(after.y - before.y) > 1e-9;
  return { points: updated, moved: moved, axis: appliedAxis };
}

/**
 * Nearest anchor to a pixel position, or -1 when the pointer is farther than
 * `radius` from every anchor. Shared so a command entry point hits the same
 * anchor the UI would.
 */
export function curveHitTest(points: CurveAnchorLike[], pixelX: number, pixelY: number,
  width: number, height: number, radius: number = CURVE_HIT_RADIUS): number {
  if (!points || width <= 0 || height <= 0) return -1;
  let nearest = -1;
  let distance = radius;
  for (let index = 0; index < points.length; index++) {
    if (!isUsableAnchor(points[index])) continue;
    const pointX = points[index].x * width;
    const pointY = (1 - points[index].y) * height;
    const current = Math.hypot(pixelX - pointX, pixelY - pointY);
    if (current <= distance) {
      nearest = index;
      distance = current;
    }
  }
  return nearest;
}
