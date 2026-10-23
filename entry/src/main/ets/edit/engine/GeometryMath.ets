/**
 * Single source of truth for every coordinate-space conversion in the editor.
 *
 * The editor has exactly three spaces:
 *   SOURCE  – the decoded camera/RAW frame, the space masks, brush strokes and
 *             retouch marks are stored in.
 *   FRAME   – the source after the manual geometry pass (straighten, aspect,
 *             scale, perspective correction, optional auto-crop). The manual
 *             geometry pass never changes the buffer size, so FRAME is
 *             normalized against the same width/height as SOURCE.
 *   DISPLAY – the published preview/export: the applied crop rectangle, the
 *             quarter-turn rotation and the flips.
 *
 * The bundled tools (tools/check_geometry_map.cjs) transpile this file and
 * compare every mapping against the row loops in WorkerCore.applyGeometryFull
 * and GeometryTransform.transformGeometry, so the two can never drift.
 */

/** Coefficients of the inverse geometry sampling pass (destination → source). */
export interface GeometryCoefficients {
  a: number;
  b: number;
  d: number;
  e: number;
  px: number;
  py: number;
  zoom: number;
  active: boolean;
  autoCrop: boolean;
  /** False when the caller rendered a bounded preview of a larger source. The
   * projection is still identical; this only records the situation so tests and
   * diagnostics can assert preview/export equality explicitly. */
  scaleInvariant: boolean;
}

export interface GeometryDims {
  width: number;
  height: number;
  cropLeft: number;
  cropTop: number;
  cropRight: number;
  cropBottom: number;
  rotation: number;
  flipH: boolean;
  flipV: boolean;
}

export interface GeometryMap {
  left: number;
  top: number;
  cropWidth: number;
  cropHeight: number;
  rotation: number;
  flipH: boolean;
  flipV: boolean;
  active: boolean;
  coef: GeometryCoefficients | null;
  outputWidth: number;
  outputHeight: number;
  width: number;
  height: number;
}

const IDENTITY_COEFFICIENTS: GeometryCoefficients = {
  a: 1, b: 0, d: 0, e: 1, px: 0, py: 0, zoom: 1, active: false, autoCrop: false,
  scaleInvariant: true,
};

export function geometryIsActive(g: number[] | undefined): boolean {
  // g[7] is the persisted auto-crop flag. Treating it as inactive made the
  // control appear to save successfully while the geometry pass was skipped.
  return !!g && g.length >= 7 && (g[0] !== 0 || g[1] !== 0 || g[2] !== 0 || g[3] !== 0 ||
    g[4] !== 100 || g[5] !== 0 || g[6] !== 0 || (g.length > 7 && g[7] !== 0));
}

export function quarterTurns(rotation: number): number {
  return ((Math.round(rotation / 90) * 90) % 360 + 360) % 360;
}

/** Largest centered output scale whose four corners still resolve inside the
 * source once the perspective correction is inverted. Mirrors the 20-step
 * bisection used by the sampling pass, so both agree exactly. */
export function autoCropZoom(a: number, b: number, d: number, e: number, px: number, py: number): number {
  let low = 1;
  let high = 32;
  for (let iteration = 0; iteration < 20; iteration++) {
    const candidate = (low + high) / 2;
    let fits = true;
    for (let corner = 0; corner < 4; corner++) {
      const x = (corner % 2 === 0 ? -1 : 1) / candidate;
      const y = (corner < 2 ? -1 : 1) / candidate;
      const u = a * x + b * y;
      const v = d * x + e * y;
      const den = 1 - px * u - py * v;
      if (den <= 0 || Math.abs(u / den) > 1 || Math.abs(v / den) > 1) fits = false;
    }
    if (fits) high = candidate; else low = candidate;
  }
  return high;
}

export function geometryCoefficients(g: number[] | undefined, renderWidth: number = 0,
  renderHeight: number = 0): GeometryCoefficients {
  const options: GeometryCoefficientOptions = {
    renderWidth: renderWidth, renderHeight: renderHeight,
  };
  return geometryCoefficientsFor(g, options);
}

export interface GeometryCoefficientOptions {
  /** Buffer the geometry pass receives; equals the source unless the caller
   * renders a bounded interactive preview. */
  renderWidth?: number;
  renderHeight?: number;
  /** Source buffer dimensions the control values were authored against. */
  referenceWidth?: number;
  referenceHeight?: number;
}

/** The manual geometry controls are authored against the whole source frame.
 * Every term below is applied in NORMALIZED [-1,1] coordinates: `nx`/`ny` are
 * dimensionless and `px`/`py` multiply them directly, so the projective term
 * is already resolution independent. It must NOT be rescaled by the preview
 * resolution — doing that would give a bounded drag preview a different
 * perspective strength than the full-resolution export. `renderWidth` and
 * `referenceWidth` are therefore accepted only so callers can pass their pixel
 * geography for diagnostics; they never scale the projection. */
export function geometryCoefficientsFor(g: number[] | undefined,
  options: GeometryCoefficientOptions): GeometryCoefficients {
  const renderWidth = options.renderWidth ?? 0;
  const renderHeight = options.renderHeight ?? 0;
  const referenceWidth = options.referenceWidth ?? renderWidth;
  const referenceHeight = options.referenceHeight ?? renderHeight;
  const scaleInvariant = renderWidth === referenceWidth && renderHeight === referenceHeight;
  if (!g || !geometryIsActive(g)) return IDENTITY_COEFFICIENTS;
  const angle = g[2] * Math.PI / 180;
  const c = Math.cos(angle);
  const s = Math.sin(angle);
  const aspect = Math.pow(2, g[3] / 100);
  const scale = Math.max(0.1, g[4] / 100);
  const px = g[1] / 160;
  const py = g[0] / 160;
  const autoCrop = g.length > 7 && g[7] === 1;
  // ratio is 1: the geometry pass preserves the source buffer dimensions.
  const a = c / (scale * aspect);
  const b = s / (scale * aspect);
  const d = -s / scale;
  const e = c / scale;
  return {
    a: a, b: b, d: d, e: e, px: px, py: py,
    zoom: autoCrop ? autoCropZoom(a, b, d, e, px, py) : 1,
    active: true, autoCrop: autoCrop, scaleInvariant: scaleInvariant,
  };
}

/** Geometry map of the manual pass alone (identity crop, no rotation), with the
 * reference/render rescale applied. */
export function buildScalingGeometryMap(g: number[] | undefined, width: number, height: number,
  options: GeometryCoefficientOptions): GeometryMap {
  const coef = geometryCoefficientsFor(g, {
    renderWidth: width, renderHeight: height,
    referenceWidth: options.referenceWidth ?? width,
    referenceHeight: options.referenceHeight ?? height,
  });
  return buildGeometryMapFromCoefficients(coef, width, height, {
    width: width, height: height, cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
    rotation: 0, flipH: false, flipV: false,
  });
}

export function identityGeometryMap(width: number, height: number): GeometryMap {
  return {
    left: 0, top: 0, cropWidth: width, cropHeight: height, rotation: 0,
    flipH: false, flipV: false, active: false, coef: null,
    outputWidth: width, outputHeight: height, width: width, height: height,
  };
}

/** Build the frame/display mapping for one frame. `width`/`height` are the
 * pixel dimensions of the buffer the geometry pass receives; when they differ
 * from the source the projective term is rescaled so preview and export agree. */
export function buildGeometryMap(g: number[] | undefined, width: number, height: number,
  dims: GeometryDims, options: GeometryCoefficientOptions = {}): GeometryMap {
  const coef = geometryCoefficientsFor(g, {
    renderWidth: width, renderHeight: height,
    referenceWidth: options.referenceWidth ?? width,
    referenceHeight: options.referenceHeight ?? height,
  });
  return buildGeometryMapFromCoefficients(coef, width, height, dims);
}

export function buildGeometryMapFromCoefficients(coef: GeometryCoefficients, width: number,
  height: number, dims: GeometryDims): GeometryMap {
  const left = Math.max(0, Math.min(width - 1, Math.floor(dims.cropLeft * width)));
  const top = Math.max(0, Math.min(height - 1, Math.floor(dims.cropTop * height)));
  const right = Math.max(left + 1, Math.min(width, Math.ceil(dims.cropRight * width)));
  const bottom = Math.max(top + 1, Math.min(height, Math.ceil(dims.cropBottom * height)));
  const cropWidth = right - left;
  const cropHeight = bottom - top;
  const rotation = quarterTurns(dims.rotation);
  const turns = rotation === 90 || rotation === 270;
  return {
    left: left, top: top, cropWidth: cropWidth, cropHeight: cropHeight,
    rotation: rotation, flipH: dims.flipH, flipV: dims.flipV, active: coef.active,
    coef: coef,
    outputWidth: turns ? cropHeight : cropWidth,
    outputHeight: turns ? cropWidth : cropHeight,
    width: width, height: height,
  };
}

/** FRAME pixel → SOURCE pixel, the projective inverse used by the sampling
 * pass. Returns null when the sample falls outside the source. */
export function frameToSource(map: GeometryMap, fx: number, fy: number): number[] | null {
  const coef = map.coef;
  if (!coef || !coef.active) return [fx, fy];
  const cx = 2 * (fx + 0.5) / map.width - 1;
  const cy = 2 * (fy + 0.5) / map.height - 1;
  const nx = cx / coef.zoom;
  const ny = cy / coef.zoom;
  const u = coef.a * nx + coef.b * ny;
  const v = coef.d * nx + coef.e * ny;
  const den = 1 - coef.px * u - coef.py * v;
  if (den <= 0) return null;
  const sx = (u / den + 1) * map.width / 2 - 0.5;
  const sy = (v / den + 1) * map.height / 2 - 0.5;
  if (sx < 0 || sy < 0 || sx > map.width - 1 || sy > map.height - 1) return null;
  return [sx, sy];
}

/** SOURCE pixel → FRAME pixel. The analytic inverse of frameToSource, so
 * overlay drawing, touch input, masks and retouch marks all land on the same
 * pixels the preview shows. Returns null when the source point is outside the
 * auto-cropped frame. */
export function sourceToFrame(map: GeometryMap, sx: number, sy: number): number[] | null {
  const cx = 2 * (sx + 0.5) / map.width - 1;
  const cy = 2 * (sy + 0.5) / map.height - 1;
  return sourceToFrameNormalized(map, cx, cy);
}

export function sourceToFrameNormalized(map: GeometryMap, cx: number, cy: number): number[] | null {
  let ux = cx;
  let uy = cy;
  const coef = map.coef;
  if (coef && coef.active) {
    // Homography M = [[a, b, 0], [d, e, 0], [px, py, 1]] maps FRAME +1 coords
    // to SOURCE +1 coords. Its adjugate gives the exact forward direction.
    const a = coef.a, b = coef.b, d = coef.d, e = coef.e, p = coef.px, q = coef.py;
    const det = a * e - b * d;
    if (Math.abs(det) < 1e-12) return null;
    const ia = e / det, ib = -b / det, id = -d / det, ie = a / det;
    // The forward map is the homography
    //   H = [[a, b, 0], [d, e, 0], [-p*a - q*d, -p*b - q*e, 1]]
    // whose adjugate bottom row collapses to (p*det, q*det, det); dividing by
    // det leaves exactly (p, q, 1), so the projective denominator is
    // `p*U + q*V + 1` with no other factors. Using anything else here makes
    // source->frame disagree with frame->source by several percent.
    const den = p * cx + q * cy + 1;
    if (den <= 0) return null;
    ux = (ia * cx + ib * cy) / den;
    uy = (id * cx + ie * cy) / den;
    if (coef.autoCrop && (Math.abs(ux) > 1 || Math.abs(uy) > 1)) return null;
  }
  const zoom = coef && coef.active ? coef.zoom : 1;
  const fx = (ux * zoom + 1) * map.width / 2 - 0.5;
  const fy = (uy * zoom + 1) * map.height / 2 - 0.5;
  if (coef && coef.active && coef.autoCrop && (fx < 0 || fy < 0 || fx > map.width - 1 || fy > map.height - 1)) return null;
  return [fx, fy];
}

/** FRAME normalized [-1,1] → SOURCE normalized [-1,1], without the pixel
 * centre offset. Used to build the integer sampling tables of the geometry
 * row loops so the map only has to be solved once per column and row. */
export function frameToSourceNormalized(map: GeometryMap, cx: number, cy: number): number[] | null {
  const coef = map.coef;
  if (!coef || !coef.active) return [cx, cy];
  const nx = cx / coef.zoom;
  const ny = cy / coef.zoom;
  const u = coef.a * nx + coef.b * ny;
  const v = coef.d * nx + coef.e * ny;
  const den = 1 - coef.px * u - coef.py * v;
  if (den <= 0) return null;
  return [u / den, v / den];
}

/** SOURCE pixel → DISPLAY normalized [0,1] over the published frame. */
export function sourceToDisplay(map: GeometryMap, sx: number, sy: number): number[] | null {
  const frame = sourceToFrame(map, sx, sy);
  if (!frame) return null;
  return frameToDisplay(map, frame[0], frame[1]);
}

/** DISPLAY normalized [0,1] → SOURCE pixel. */
export function displayToSource(map: GeometryMap, u: number, v: number): number[] | null {
  const frame = displayToFrame(map, u, v);
  if (!frame) return null;
  return frameToSource(map, frame[0], frame[1]);
}

/** FRAME pixel → DISPLAY normalized [0,1] (crop, rotate, flip). */
export function frameToDisplay(map: GeometryMap, fx: number, fy: number): number[] | null {
  const cropX = fx - map.left;
  const cropY = fy - map.top;
  if (cropX < -0.5 || cropY < -0.5 || cropX > map.cropWidth - 0.5 || cropY > map.cropHeight - 0.5) return null;
  const x = cropX / map.cropWidth;
  const y = cropY / map.cropHeight;
  let u = x;
  let v = y;
  if (map.rotation === 90) { u = 1 - y; v = x; }
  else if (map.rotation === 180) { u = 1 - x; v = 1 - y; }
  else if (map.rotation === 270) { u = y; v = 1 - x; }
  if (map.flipH) u = 1 - u;
  if (map.flipV) v = 1 - v;
  return [u, v];
}

/** DISPLAY normalized [0,1] → FRAME pixel (inverse of frameToDisplay). */
export function displayToFrame(map: GeometryMap, u: number, v: number): number[] | null {
  if (u < -0.001 || v < -0.001 || u > 1.001 || v > 1.001) return null;
  let x = u;
  let y = v;
  if (map.flipH) x = 1 - x;
  if (map.flipV) y = 1 - y;
  let frameX = x;
  let frameY = y;
  if (map.rotation === 90) { frameX = y; frameY = 1 - x; }
  else if (map.rotation === 180) { frameX = 1 - x; frameY = 1 - y; }
  else if (map.rotation === 270) { frameX = 1 - y; frameY = x; }
  return [map.left + frameX * map.cropWidth, map.top + frameY * map.cropHeight];
}

/** Precomputed nearest-source lookup for the rotate/flip remap. Both the
 * TaskPool worker and the main-thread fallback consume the same table, so the
 * published pixels cannot differ between the two paths. */
export interface FrameSampleTable {
  x: Int32Array;
  y: Int32Array;
}

function buildFrameSampleAxis(count: number, otherCount: number): Int32Array {
  return new Int32Array(count * Math.max(1, otherCount));
}

export function buildFrameSampleTable(map: GeometryMap): FrameSampleTable {
  const wide = buildFrameSampleAxis(map.outputWidth, map.outputHeight);
  const tall = buildFrameSampleAxis(map.outputHeight, map.outputWidth);
  // Crop, rotation and flip are an exact integer bijection between the cropped
  // frame and the displayed frame. Building the table in the FORWARD direction
  // keeps it exact: sampling the inverse with pixel-centre rounding mapped
  // output pixel x onto source pixel x+1 (Math.round(0.5) rounds up), which
  // shifted every cropped frame by one pixel.
  //
  // frameToDisplay composes the transform as `quarter turn, THEN flip`, so the
  // inverse has to undo the rotation first and mirror in OUTPUT space. Undoing
  // the flip in CROP space (the previous order) mirrors the wrong axis for the
  // 90/270 turns with exactly one flip enabled: the CPU worker and the export
  // then published a frame mirrored against the GPU present pass, the mask
  // coverage overlay and touch input, all of which invert through
  // frameToDisplay/displayToFrame. Rot 0/180 and the both-flips combinations
  // are unaffected by the order.
  const outputWidth = map.outputWidth;
  const outputHeight = map.outputHeight;
  for (let cropY = 0; cropY < map.cropHeight; cropY++) {
    for (let cropX = 0; cropX < map.cropWidth; cropX++) {
      let dx = cropX;
      let dy = cropY;
      if (map.rotation === 90) {
        // Forward: cropX → output y, cropY → outputWidth - 1 - output x.
        dx = map.cropHeight - 1 - cropY;
        dy = cropX;
      } else if (map.rotation === 180) {
        dx = map.cropWidth - 1 - cropX;
        dy = map.cropHeight - 1 - cropY;
      } else if (map.rotation === 270) {
        dx = cropY;
        dy = map.cropWidth - 1 - cropX;
      }
      if (map.flipH) dx = outputWidth - 1 - dx;
      if (map.flipV) dy = outputHeight - 1 - dy;
      if (dx < 0 || dy < 0 || dx >= outputWidth || dy >= outputHeight) continue;
      wide[dy * outputWidth + dx] = cropX;
      tall[dx * outputHeight + dy] = cropY;
    }
  }
  return { x: wide, y: tall };
}

/** Copy the rotation/flip/crop remap into `output`. `input` must already have
 * the manual geometry pass applied. */
export function remapFrameToDisplay(input: Uint8ClampedArray, map: GeometryMap,
  output: Uint8ClampedArray, table: FrameSampleTable): void {
  const outputWidth = map.outputWidth;
  for (let y = 0; y < map.outputHeight; y++) {
    const row = y * outputWidth;
    for (let x = 0; x < outputWidth; x++) {
      const cropX = table.x[row + x];
      if (cropX < 0) continue;
      const cropY = table.y[x * map.outputHeight + y];
      const sourceIndex = ((map.top + cropY) * map.width + map.left + cropX) * 4;
      const destinationIndex = (row + x) * 4;
      output[destinationIndex] = input[sourceIndex];
      output[destinationIndex + 1] = input[sourceIndex + 1];
      output[destinationIndex + 2] = input[sourceIndex + 2];
      output[destinationIndex + 3] = input[sourceIndex + 3];
    }
  }
}

