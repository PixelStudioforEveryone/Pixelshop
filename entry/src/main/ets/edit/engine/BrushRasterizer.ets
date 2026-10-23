/** Continuous, round-ended segment in normalized source coordinates.
 * Distance to the segment gives one coverage value per pixel; overlapping
 * touch samples never build up darker dots along a soft brush stroke. */
export function rasterizeBrushSegment(buffer: Uint8ClampedArray, width: number, height: number,
  startX: number, startY: number, startRadius: number, startHardness: number,
  endX: number, endY: number, endRadius: number, endHardness: number): void {
  const ax = startX * width;
  const ay = startY * height;
  const bx = endX * width;
  const by = endY * height;
  const ra = Math.max(1, startRadius * Math.min(width, height));
  const rb = Math.max(1, endRadius * Math.min(width, height));
  const radius = Math.max(ra, rb);
  const dx = bx - ax;
  const dy = by - ay;
  const length2 = dx * dx + dy * dy;
  const left = Math.max(0, Math.floor(Math.min(ax, bx) - radius));
  const right = Math.min(width - 1, Math.ceil(Math.max(ax, bx) + radius));
  const top = Math.max(0, Math.floor(Math.min(ay, by) - radius));
  const bottom = Math.min(height - 1, Math.ceil(Math.max(ay, by) + radius));
  for (let y = top; y <= bottom; y++) {
    for (let x = left; x <= right; x++) {
      const t = length2 > 0 ? Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / length2)) : 0;
      const distance = Math.hypot(x - ax - dx * t, y - ay - dy * t);
      const r = ra + (rb - ra) * t;
      if (distance > r) continue;
      const hardness = Math.max(0, Math.min(1, startHardness + (endHardness - startHardness) * t));
      const inner = r * hardness;
      const alpha = distance <= inner ? 255 : Math.round(255 * (r - distance) / Math.max(0.001, r - inner));
      const index = y * width + x;
      if (alpha > buffer[index]) buffer[index] = alpha;
    }
  }
}

export interface ReferenceBrushPoint { x: number; y: number; radius: number; hardness: number; }

/** Lightcraft brush_dabs / push_dabs / dab_alpha / accumulate (MIT).
 * The UI's short-edge radius is converted to pixel radius at this boundary.
 * Sample density and stationary pointer events must not change coverage. */
export function rasterizeReferenceBrushStroke(buffer: Uint8ClampedArray, width: number, height: number,
  points: ReferenceBrushPoint[], flow: number = 1, density: number = 1): void {
  if (points.length === 0 || width < 1 || height < 1) return;
  const radius = Math.max(0.5, points[0].radius * Math.min(width, height));
  const hard = radius * Math.max(0, Math.min(1, points[0].hardness));
  const spacing = Math.max(0.5, radius / 4);
  const paint = Math.max(0, Math.min(1, flow)), limit = Math.max(0, Math.min(1, density));
  // A stroke can only mark pixels within `radius` of one of its points, so both
  // the band walk and the per-band write can be bounded by that box. Previously
  // every band rewrote its FULL width, i.e. one whole-frame pass per stroke
  // (44 M writes at 45 MP) even when the stroke touched a few hundred pixels —
  // that, not the dab accumulation, is what made a painted mask's rasterisation
  // take seconds. Outside the stamped span the accumulator is exactly zero, so
  // skipping the write is bit-identical to writing zero.
  let boundTop = height, boundBottom = 0;
  for (const point of points) {
    const y = point.y * height;
    if (!Number.isFinite(y)) continue;
    boundTop = Math.min(boundTop, Math.floor(y - radius));
    boundBottom = Math.max(boundBottom, Math.ceil(y + radius));
  }
  if (boundBottom <= boundTop) return;
  boundTop = Math.max(0, boundTop); boundBottom = Math.min(height, boundBottom);
  // Keep the reference float accumulator in a bounded row band, so a
  // 45 MP export does not allocate an extra 180 MB plane per brush stroke.
  // 笔刷内圈的衰减以前每像素一次 Math.hypot + smoothstep，在预览分辨率上
  // 一次覆盖层重绘要几十毫秒（日志 raster=43~72ms，笔数越多越慢）。这里把
  // 衰减曲线预计算成 LUT，内循环只剩一次 sqrt 和一次查表，形状保持不变。
  const FALLOFF_LUT = 128;
  const falloff = new Float32Array(FALLOFF_LUT + 1);
  {
    const span = Math.max(0.00001, radius - hard);
    for (let index = 0; index <= FALLOFF_LUT; index++) {
      const distance = radius * index / FALLOFF_LUT;
      if (distance <= hard) {
        falloff[index] = 1;
      } else {
        const t = Math.max(0, Math.min(1, (distance - hard) / span));
        falloff[index] = 1 - t * t * (3 - 2 * t);
      }
    }
  }
  const bandHeight = Math.min(64, height);
  const alpha = new Float32Array(width * bandHeight);
  for (let bandTop = Math.floor(boundTop / bandHeight) * bandHeight; bandTop < boundBottom; bandTop += bandHeight) {
    const bandBottom = Math.min(height, bandTop + bandHeight);
    alpha.fill(0);
    let firstX = width, lastX = 0;
    let previousX = 0, previousY = 0, started = false;
    const stamp = (cx: number, cy: number): void => {
      if (cy + radius < bandTop || cy - radius >= bandBottom) return;
      const left = Math.max(0, Math.floor(cx - radius)), right = Math.min(width, Math.ceil(cx + radius));
      if (right <= left) return;
      const top = Math.max(bandTop, Math.floor(cy - radius)), bottom = Math.min(bandBottom, Math.ceil(cy + radius));
      const radiusSquared = radius * radius;
      for (let y = top; y < bottom; y++) for (let x = left; x < right; x++) {
        const dx = x + 0.5 - cx;
        const dy = y + 0.5 - cy;
        const squared = dx * dx + dy * dy;
        if (squared > radiusSquared) continue;
        const distance = Math.sqrt(squared);
        const coverage = falloff[(distance / radius * FALLOFF_LUT) | 0];
        const offset = (y - bandTop) * width + x;
        alpha[offset] = Math.min(limit, alpha[offset] + coverage * paint * (1 - alpha[offset]));
      }
      if (left < firstX) firstX = left;
      if (right > lastX) lastX = right;
    };
    for (const point of points) {
      const x = point.x * width, y = point.y * height;
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
      if (started) {
        const distance = Math.hypot(x - previousX, y - previousY);
        if (distance <= 1e-6) continue;
        const count = Math.min(1000000, Math.ceil(distance / spacing));
        for (let k = 1; k < count; k++) stamp(previousX + (x - previousX) * k / count,
          previousY + (y - previousY) * k / count);
      }
      stamp(x, y); previousX = x; previousY = y; started = true;
    }
    for (let y = bandTop; y < bandBottom; y++) {
      const source = (y - bandTop) * width, dest = y * width;
      for (let x = firstX; x < lastX; x++) buffer[dest + x] = Math.round(alpha[source + x] * 255);
    }
  }
}
