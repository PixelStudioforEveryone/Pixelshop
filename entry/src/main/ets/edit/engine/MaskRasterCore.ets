import { rasterizeBrushSegment, rasterizeReferenceBrushStroke } from './BrushRasterizer';
import { RangeMaskProxy } from './RangeMaskCore';
import { applyBrushAutoMask } from './AutoMaskBrush';
import { MaskWorkerPoint } from './MaskWorkerTypes';
import pixelsNative from 'libvivid_pixels.so';

export { MaskWorkerPoint } from './MaskWorkerTypes';

/**
 * Transfer-safe representation of a structured mask. The model classes are
 * @Observed and cannot be constructed inside TaskPool workers, so masks are
 * flattened to this small data shape before rasterization.
 */
export interface MaskWorkerStroke { mode: number; points: MaskWorkerPoint[]; flow?: number; density?: number; }
/**
 * Soft alpha from a local segmentation model. It covers the whole source frame,
 * so sampling it needs no crop/rotation awareness: the caller rasterises into
 * the same source-normalised buffer as every other component type.
 */
export interface MaskWorkerBitmap { width: number; height: number; alpha: ArrayBuffer; }
/**
 * 自动蒙版用的源图像 RGB 代理。刻意 type-alias 到范围蒙版的 RangeMaskProxy：
 * ArkTS 禁止结构化类型，两个同名形状的接口互不相容，而自动蒙版直接消费
 * buildProxy 的产物，所以这里必须是同一个类型。
 */
export interface MaskWorkerComponent {
  renderingVersion?: number;
  type: number; // 0 brush, 1 linear, 2 radial, 3 subject, 4 sky
  blendMode: number; // 0 add, 1 subtract, 2 intersect
  enabled: boolean;
  visible: boolean;
  inverted: boolean;
  opacity: number;
  feather: number;
  strokes: MaskWorkerStroke[];
  linear: number[]; // sx, sy, ex, ey
  radial: number[]; // cx, cy, rx, ry, rotation
  bitmap?: MaskWorkerBitmap | null;
  /**
   * 自动蒙版：笔刷颜色门限的开关与容差，以及源图 RGB 代理。
   *
   * 代理用 ArrayBuffer 而不是 Uint8Array，因为任务要跨 TaskPool 边界：笔刷的
   * 自动门限必须在 worker 里算（44MP 主线程逐像素会把导出拖成几十秒），而
   * ArrayBuffer 是可转移/可复制的，Uint8Array 视图不是。
   */
  autoMask?: boolean;
  autoMaskSensitivity?: number;
  sourceProxyWidth?: number;
  sourceProxyHeight?: number;
  sourceProxyRgb?: ArrayBuffer | null;
}
export interface MaskWorkerLayer {
  inverted?: boolean;
  enabled: boolean;
  visible: boolean;
  opacity: number;
  components: MaskWorkerComponent[];
}

function clampByte(value: number): number {
  return Math.max(0, Math.min(255, Math.round(value)));
}

function renderLinearReference(component: MaskWorkerComponent, width: number, height: number): Uint8ClampedArray {
  const p = component.linear;
  const buffer = new Uint8ClampedArray(width * height);
  const sx = (p[0] ?? 0.5) * width, sy = (p[1] ?? 0) * height;
  const ex = (p[2] ?? 0.5) * width, ey = (p[3] ?? 1) * height;
  const dx = ex - sx, dy = ey - sy, len2 = dx * dx + dy * dy;
  const modern = (component.renderingVersion ?? 1) >= 2;
  if (len2 < 1) { if (!modern) buffer.fill(255); return buffer; }
  const feather = Math.max(0, Math.min(0.5, component.feather));
  const start = 0.5 - feather, end = 0.5 + feather;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const offset = modern ? 0.5 : 0;
    const t0 = ((x + offset - sx) * dx + (y + offset - sy) * dy) / len2;
    const t = Math.max(0, Math.min(1, t0));
    let alpha: number;
    if (feather <= 0.0001) alpha = t < 0.5 ? 255 : 0;
    else if (t <= start) alpha = 255;
    else if (t >= end) alpha = 0;
    else {
      const v = (t - start) / Math.max(0.0001, end - start);
      alpha = 255 * (1 - (modern ? v * v * (3 - 2 * v) : v));
    }
    buffer[y * width + x] = clampByte(alpha);
  }
  return buffer;
}

function renderRadialReference(component: MaskWorkerComponent, width: number, height: number): Uint8ClampedArray {
  const p = component.radial;
  const buffer = new Uint8ClampedArray(width * height);
  const cx = (p[0] ?? 0.5) * width, cy = (p[1] ?? 0.5) * height;
  const rx = Math.max(1, (p[2] ?? 0.5) * width), ry = Math.max(1, (p[3] ?? 0.5) * height);
  const angle = (p[4] ?? 0) * Math.PI / 180, ca = Math.cos(angle), sa = Math.sin(angle);
  const feather = Math.max(0, Math.min(1, component.feather)), inner = 1 - feather;
  const modern = (component.renderingVersion ?? 1) >= 2;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const offset = modern ? 0.5 : 0;
    const dx = x + offset - cx, dy = y + offset - cy;
    const nx = (dx * ca + dy * sa) / rx, ny = (-dx * sa + dy * ca) / ry;
    const distance = Math.sqrt(nx * nx + ny * ny);
    let alpha: number;
    if (feather <= 0.0001) alpha = distance <= 1 ? 255 : 0;
    else if (distance <= inner) alpha = 255;
    else if (distance >= 1) alpha = 0;
    else {
      const v = (distance - inner) / feather;
      alpha = 255 * (1 - (modern ? v * v * (3 - 2 * v) : v));
    }
    buffer[y * width + x] = clampByte(alpha);
  }
  return buffer;
}

/**
 * Lightroom 式自动蒙版：在已栅格化的笔刷覆盖区内做颜色门限。
 *
 * 真正的算法在 AutoMaskBrush 里（按 dab 冲压 + 参考色沿笔画插值 + 代理双线性
 * 采样）；这里只负责把 worker 组件里的扁平字段还原成它需要的形状。
 */
function applyAutoMask(component: MaskWorkerComponent, width: number, height: number,
  buffer: Uint8ClampedArray): void {
  if (!component.autoMask) return;
  const proxyWidth = component.sourceProxyWidth ?? 0;
  const proxyHeight = component.sourceProxyHeight ?? 0;
  const rgb = component.sourceProxyRgb;
  // 门限到底有没有在生产路径上生效，只有设备日志能证明。任务在 TaskPool worker
  // 里跑，worker 的 console 同样进 hilog，所以这里把关键输入（代理尺寸/字节数、
  // 笔画数）和结果（覆盖率）都报出来：代理丢失或笔画为空都会让门限静默失效，
  // 而这两种情况的日志长得完全不一样。
  let strokeCount = 0;
  let pointCount = 0;
  for (const stroke of component.strokes) {
    strokeCount++;
    pointCount += stroke.points.length;
  }
  if (!rgb || proxyWidth <= 0 || proxyHeight <= 0) {
    console.info(`VIVID_PERF t=${Date.now()} event=auto_mask raster=${width}x${height} ` +
      `proxy=${proxyWidth}x${proxyHeight} bytes=${rgb ? rgb.byteLength : 0} strokes=${strokeCount} ` +
      `points=${pointCount} result=no-proxy`);
    return;
  }
  const proxy: RangeMaskProxy = {
    width: proxyWidth,
    height: proxyHeight,
    rgb: new Uint8Array(rgb),
  };
  const points: MaskWorkerPoint[] = [];
  for (const stroke of component.strokes) {
    for (const point of stroke.points) points.push(point);
  }
  // 用**平均 alpha 保留比例**衡量门限强度：只数"非零像素"是不准的，权重哪怕
  // 只剩 1/255 也仍算非零，会把"门限几乎没起作用"报成 100%。100% = 门限完全
  // 没削减覆盖（即没生效），明显小于 100% 才说明门限在削。
  const step = Math.max(1, Math.floor(buffer.length / 20000));
  let beforeSum = 0;
  for (let index = 0; index < buffer.length; index += step) beforeSum += buffer[index];
  applyBrushAutoMask(buffer, width, height, points, proxy, component.autoMaskSensitivity ?? 0.5);
  let afterSum = 0;
  for (let index = 0; index < buffer.length; index += step) afterSum += buffer[index];
  console.info(`VIVID_PERF t=${Date.now()} event=auto_mask raster=${width}x${height} ` +
    `proxy=${proxyWidth}x${proxyHeight} bytes=${rgb.byteLength} strokes=${strokeCount} ` +
    `points=${pointCount} kept=${beforeSum > 0 ? Math.round(afterSum * 100 / beforeSum) : -1}% ` +
    `result=applied`);
}

function renderBrushCore(component: MaskWorkerComponent, width: number, height: number): Uint8ClampedArray {
  const buffer = new Uint8ClampedArray(width * height);
  // Every stroke is bounded by its points' radius, so the union of those boxes
  // is the only region this component can ever mark. The per-stroke scratch
  // therefore only has to be cleared there, and the max/subtract combine only
  // has to walk there. Before, each stroke allocated a full-frame 44 MB buffer
  // and ran a full-frame combine loop, which is what dominated a painted
  // mask's rasterisation at 45 MP. Outside the union nothing can change, so the
  // bounded loops are bit-identical to the full-frame ones.
  const shortSide = Math.min(width, height);
  let boundLeft = width, boundRight = 0, boundTop = height, boundBottom = 0;
  for (const stroke of component.strokes) {
    for (let index = 0; index < stroke.points.length; index++) {
      const point = stroke.points[index];
      const x = point.x * width, y = point.y * height;
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
      const radius = Math.max(1, point.radius * shortSide);
      if (x - radius < boundLeft) boundLeft = x - radius;
      if (x + radius > boundRight) boundRight = x + radius;
      if (y - radius < boundTop) boundTop = y - radius;
      if (y + radius > boundBottom) boundBottom = y + radius;
    }
  }
  if (boundRight <= boundLeft || boundBottom <= boundTop) return buffer;
  const left = Math.max(0, Math.floor(boundLeft)), right = Math.min(width, Math.ceil(boundRight));
  const top = Math.max(0, Math.floor(boundTop)), bottom = Math.min(height, Math.ceil(boundBottom));
  const scratch = new Uint8ClampedArray(width * height);
  const clearRect = (l: number, t: number, r: number, b: number): void => {
    const span = r - l;
    if (span <= 0) return;
    for (let y = t; y < b; y++) {
      const start = y * width + l;
      scratch.fill(0, start, start + span);
    }
  };
  let hasSelection = false;
  for (const stroke of component.strokes) {
    if (stroke.points.length === 0) continue;
    const points = stroke.points;
    // 每一笔只在自己笔迹的包围盒里清脏与合成。之前用的是“全部笔迹的并集”，
    // 笔数一多就变成 O(笔数 × 并集面积)，在预览分辨率上就是每笔几百毫秒，
    // 表现成“画到第四笔就卡住”。
    let sLeft = width, sRight = 0, sTop = height, sBottom = 0;
    for (const point of points) {
      const px = point.x * width, py = point.y * height;
      if (!Number.isFinite(px) || !Number.isFinite(py)) continue;
      const pr = Math.max(1, point.radius * shortSide);
      if (px - pr < sLeft) sLeft = px - pr;
      if (px + pr > sRight) sRight = px + pr;
      if (py - pr < sTop) sTop = py - pr;
      if (py + pr > sBottom) sBottom = py + pr;
    }
    if (sRight <= sLeft || sBottom <= sTop) continue;
    const l = Math.max(0, Math.floor(sLeft)), r = Math.min(width, Math.ceil(sRight));
    const t = Math.max(0, Math.floor(sTop)), b = Math.min(height, Math.ceil(sBottom));
    // INTERSECT is the one mode whose effect reaches the whole frame (everything
    // outside the stroke is cleared), and the first INTERSECT stroke also seeds
    // the group, so those cases keep full-frame rules.
    if (stroke.mode === 2) scratch.fill(0); else clearRect(l, t, r, b);
    if ((component.renderingVersion ?? 1) >= 3) {
      rasterizeReferenceBrushStroke(scratch, width, height, points, stroke.flow ?? 1, stroke.density ?? 1);
    } else for (let index = 0; index < points.length; index++) {
      const a = points[index], bb = points[Math.min(index + 1, points.length - 1)];
      rasterizeBrushSegment(scratch, width, height, a.x, a.y, a.radius, a.hardness,
        bb.x, bb.y, bb.radius, bb.hardness);
    }
    if (stroke.mode === 2 && !hasSelection) {
      buffer.set(scratch);
    } else if (stroke.mode === 1) {
      for (let y = t; y < b; y++) {
        const row = y * width;
        for (let x = l; x < r; x++) buffer[row + x] = Math.max(0,
          Math.round(buffer[row + x] * (255 - scratch[row + x]) / 255));
      }
    } else if (stroke.mode === 2) {
      for (let index = 0; index < buffer.length; index++) buffer[index] = Math.round(
        buffer[index] * scratch[index] / 255);
    } else {
      for (let y = t; y < b; y++) {
        const row = y * width;
        for (let x = l; x < r; x++) if (scratch[row + x] > buffer[row + x]) {
          buffer[row + x] = scratch[row + x];
        }
      }
    }
    hasSelection = true;
  }
  return buffer;
}

/**
 * Sample a stored full-frame soft mask into the render raster.
 *
 * The stored raster spans the source frame at a bounded resolution (the
 * network's own 320/384 for a model, RANGE_MASK_MAX_EDGE for a range mask), so
 * this is a plain resample: no geometry, crop or rotation term is involved,
 * which is exactly why a model or range selection stays registered with the
 * rest of the mask under any transform.
 *
 * A component with no raster yet rasterises to nothing. That is deliberate: it
 * makes a failed or still-running producer visibly empty instead of silently
 * selecting the whole frame.
 */
/**
 * 算出图像在栅格里的有效内容矩形（x, y, w, h）。
 *
 * AI 分割把画面按比例放进**方形**输入，输出也是方形（如 320x320），
 * 图像之外是零边。若把整个方形直接铺满 3:4 画面，主体会被压到中间
 * 一小块。这里按目标比例反推中央子矩形，实现 letterbox 还原。
 */
function bitmapContentRect(bitmapWidth: number, bitmapHeight: number,
  targetWidth: number, targetHeight: number): number[] {
  if (bitmapWidth <= 0 || bitmapHeight <= 0 || targetWidth <= 0 || targetHeight <= 0) {
    return [0, 0, bitmapWidth, bitmapHeight];
  }
  // 只有“栅格是方形、目标不是方形”时才存在 letterbox。
  const bitmapSquare = Math.abs(bitmapWidth / bitmapHeight - 1) <= 0.02;
  const targetSquare = Math.abs(targetWidth / targetHeight - 1) <= 0.02;
  if (!bitmapSquare || targetSquare) return [0, 0, bitmapWidth, bitmapHeight];
  const aspect = targetWidth / targetHeight;
  let contentWidth = bitmapWidth;
  let contentHeight = bitmapHeight;
  if (aspect < 1) contentWidth = Math.max(1, Math.round(bitmapWidth * aspect));
  else contentHeight = Math.max(1, Math.round(bitmapHeight / aspect));
  const left = Math.floor((bitmapWidth - contentWidth) / 2);
  const top = Math.floor((bitmapHeight - contentHeight) / 2);
  return [left, top, contentWidth, contentHeight];
}

let lastBitmapDiag: string = '';

function renderBitmapReference(component: MaskWorkerComponent, width: number, height: number,
  feather: number): Uint8ClampedArray {
  const buffer = new Uint8ClampedArray(width * height);
  const bitmap = component.bitmap;
  if (!bitmap || bitmap.width <= 0 || bitmap.height <= 0) return buffer;
  if (bitmap.alpha.byteLength < bitmap.width * bitmap.height) return buffer;
  const source = new Uint8ClampedArray(bitmap.alpha, 0, bitmap.width * bitmap.height);
  // 诊断日志：看清 AI 栅格与目标尺寸的关系（方形输出发布在 3:4 画面上
  // 只会落在中间一块，这条日志能直接证实）。
  const diagKey = `${bitmap.width}x${bitmap.height}->${width}x${height}`;
  if (diagKey !== lastBitmapDiag) {
    lastBitmapDiag = diagKey;
    console.info(`VIVID_PERF t=${Date.now()} event=ai_compose bitmap=${bitmap.width}x${bitmap.height} ` +
      `target=${width}x${height} feather=${feather.toFixed(2)}`);
  }
  const content = [0, 0, bitmap.width, bitmap.height];
  const scaleX = bitmap.width / width;
  const scaleY = bitmap.height / height;
  // The producer's edge is already soft; `feather` only cross-fades the
  // transition band towards a hard cut so the slider stays meaningful in both
  // directions.
  const softness = Math.max(0.05, 1 - Math.min(1, Math.max(0, feather)));
  for (let y = 0; y < height; y++) {
    const sampleY = Math.min(bitmap.height - 1,
      Math.max(0, content[1] + (y + 0.5) * scaleY - 0.5));
    const y0 = Math.floor(sampleY);
    const y1 = Math.min(bitmap.height - 1, y0 + 1);
    const fy = sampleY - y0;
    const row0 = y0 * bitmap.width;
    const row1 = y1 * bitmap.width;
    for (let x = 0; x < width; x++) {
      const sampleX = Math.min(bitmap.width - 1,
        Math.max(0, content[0] + (x + 0.5) * scaleX - 0.5));
      const x0 = Math.floor(sampleX);
      const x1 = Math.min(bitmap.width - 1, x0 + 1);
      const fx = sampleX - x0;
      const top = source[row0 + x0] + (source[row0 + x1] - source[row0 + x0]) * fx;
      const bottom = source[row1 + x0] + (source[row1 + x1] - source[row1 + x0]) * fx;
      let alpha = top + (bottom - top) * fy;
      if (softness < 1) {
        const normalized = alpha / 255;
        const curved = normalized <= 0.5
          ? 0.5 * Math.pow(normalized * 2, softness)
          : 1 - 0.5 * Math.pow((1 - normalized) * 2, softness);
        alpha = 255 * curved;
      }
      buffer[y * width + x] = clampByte(alpha);
    }
  }
  return buffer;
}

/**
 * Native fast paths for the three rasterizers that dominate a masked export.
 *
 * Each one is adopted only after a byte-for-byte probe against the reference
 * implementation above. The probe runs per call rather than once: the UI thread
 * and every TaskPool worker load this module separately, and the stored-raster
 * curve depends on the requested softness. A probe costs a few hundred pixels
 * against frames of tens of megapixels, so it is noise next to the work it
 * guards, and a mismatch simply falls back to the reference.
 */
const NATIVE_PROBE_WIDTH: number = 23;
const NATIVE_PROBE_HEIGHT: number = 17;

function sameBytes(left: Uint8ClampedArray, right: Uint8ClampedArray): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

function renderLinearNative(component: MaskWorkerComponent, width: number,
  height: number): Uint8ClampedArray {
  const p = component.linear;
  const sx = (p[0] ?? 0.5) * width, sy = (p[1] ?? 0) * height;
  const ex = (p[2] ?? 0.5) * width, ey = (p[3] ?? 1) * height;
  const alpha: ArrayBuffer = pixelsNative.rasterizeLinear(width, height, sx, sy, ex, ey,
    component.feather, (component.renderingVersion ?? 1) >= 2) as ArrayBuffer;
  return new Uint8ClampedArray(alpha);
}

function renderRadialNative(component: MaskWorkerComponent, width: number,
  height: number): Uint8ClampedArray {
  const p = component.radial;
  const cx = (p[0] ?? 0.5) * width, cy = (p[1] ?? 0.5) * height;
  const rx = Math.max(1, (p[2] ?? 0.5) * width), ry = Math.max(1, (p[3] ?? 0.5) * height);
  const angle = (p[4] ?? 0) * Math.PI / 180;
  // cos/sin stay on the ArkTS side: Math.cos/Math.sin are engine-specific while
  // the native routine only uses IEEE-correct arithmetic on doubles.
  const alpha: ArrayBuffer = pixelsNative.rasterizeRadial(width, height, cx, cy, rx, ry,
    Math.cos(angle), Math.sin(angle), component.feather,
    (component.renderingVersion ?? 1) >= 2) as ArrayBuffer;
  return new Uint8ClampedArray(alpha);
}

function renderBitmapNative(component: MaskWorkerComponent, width: number, height: number,
  softness: number): Uint8ClampedArray {
  const buffer = new Uint8ClampedArray(width * height);
  const bitmap = component.bitmap;
  if (!bitmap) return buffer;
  pixelsNative.sampleBitmap(bitmap.alpha, bitmap.width, bitmap.height,
    buffer.buffer as ArrayBuffer, width, height, softness);
  return buffer;
}

/** Synthetic gradients that exercise both sides of every branch. */
function probeLinearComponent(): MaskWorkerComponent {
  return {
    renderingVersion: 3, type: 1, blendMode: 0, enabled: true, visible: true,
    inverted: false, opacity: 1, feather: 0.25, strokes: [],
    linear: [0.05, 0.2, 0.92, 0.78], radial: [],
  };
}

function probeRadialComponent(): MaskWorkerComponent {
  return {
    renderingVersion: 3, type: 2, blendMode: 0, enabled: true, visible: true,
    inverted: false, opacity: 1, feather: 0.3, strokes: [], linear: [],
    radial: [0.42, 0.58, 0.7, 0.33, 25],
  };
}

function probeBitmapComponent(feather: number): MaskWorkerComponent {
  const source = new Uint8ClampedArray(9 * 7);
  for (let index = 0; index < source.length; index++) source[index] = (index * 29 + 7) & 255;
  const bitmap: MaskWorkerBitmap = { width: 9, height: 7, alpha: source.buffer as ArrayBuffer };
  return {
    renderingVersion: 3, type: 3, blendMode: 0, enabled: true, visible: true,
    inverted: false, opacity: 1, feather: feather, strokes: [], linear: [], radial: [],
    bitmap: bitmap,
  };
}

function linearNativeVerified(component: MaskWorkerComponent): boolean {
  try {
    const probe = probeLinearComponent();
    return sameBytes(renderLinearReference(probe, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT),
        renderLinearNative(probe, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT)) &&
      sameBytes(renderLinearReference(component, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT),
        renderLinearNative(component, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT));
  } catch (_error) {
    return false;
  }
}

function radialNativeVerified(component: MaskWorkerComponent): boolean {
  try {
    const probe = probeRadialComponent();
    return sameBytes(renderRadialReference(probe, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT),
        renderRadialNative(probe, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT)) &&
      sameBytes(renderRadialReference(component, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT),
        renderRadialNative(component, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT));
  } catch (_error) {
    return false;
  }
}

function bitmapNativeVerified(component: MaskWorkerComponent, feather: number,
  softness: number): boolean {
  try {
    const probe = probeBitmapComponent(feather);
    return sameBytes(renderBitmapReference(probe, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT, feather),
        renderBitmapNative(probe, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT, softness)) &&
      sameBytes(renderBitmapReference(component, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT, feather),
        renderBitmapNative(component, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT, softness));
  } catch (_error) {
    return false;
  }
}

/** 多笔 + 软硬边 + 大半径 + 高密度 dab 的合成探针：覆盖插值步进与饱和分支。 */
function probeBrushComponent(): MaskWorkerComponent {
  const strokeA: MaskWorkerStroke = {
    mode: 0,
    points: [
      { x: 0.10, y: 0.20, radius: 0.30, hardness: 0.0 },
      { x: 0.55, y: 0.45, radius: 0.22, hardness: 0.65 },
      { x: 0.80, y: 0.15, radius: 0.35, hardness: 1.0 },
    ],
    flow: 0.7,
    density: 0.9,
  };
  const strokeB: MaskWorkerStroke = {
    mode: 1,
    points: [
      { x: 0.30, y: 0.70, radius: 0.18, hardness: 0.5 },
      { x: 0.70, y: 0.85, radius: 0.18, hardness: 0.5 },
    ],
    flow: 1,
    density: 1,
  };
  return {
    renderingVersion: 3, type: 0, blendMode: 0, enabled: true, visible: true,
    inverted: false, opacity: 1, feather: 0, strokes: [strokeA, strokeB],
    linear: [], radial: [],
  };
}

/**
 * 对拍结果按分量签名缓存。
 *
 * 这个对拍是为了决定能不能走 native 笔刷快路径，但它自己也要把整个分量
 * 在 CPU/native 上各算一遍，一旦不一致还会逐笔二分。每帧都跑就是真机上
 * “画几笔就卡退”的直接原因（单帧 6 秒、UI 线程超 3 秒被系统判死）。
 * 签名没变就直接复用上一次的结论。
 */
const brushVerifyCache: Map<string, boolean> = new Map<string, boolean>();

function brushVerifyKey(component: MaskWorkerComponent): string {
  let points = 0;
  for (const stroke of component.strokes) points += stroke.points.length;
  return `${component.renderingVersion}|${component.blendMode}|${component.strokes.length}|` +
    `${points}|${component.autoMask ? 1 : 0}`;
}

/** 位精确对拍：探针组件 + 实际组件，native 与参考必须逐字节一致。 */
function brushNativeVerified(component: MaskWorkerComponent): boolean {
  const cacheKey = brushVerifyKey(component);
  const cached = brushVerifyCache.get(cacheKey);
  if (cached !== undefined) return cached;
  try {
    if (brushVerifyCache.size > 64) brushVerifyCache.clear();
    const probe = probeBrushComponent();
    const probeRef = renderBrushCore(probe, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT);
    const probeNat = renderBrushNativeCore(probe, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT);
    if (!sameBytes(probeRef, probeNat)) {
      console.warn(`VIVID_PERF event=brush_native mismatch=probe ` +
        `ref0=${probeRef[0]} nat0=${probeNat[0]} size=${NATIVE_PROBE_WIDTH}x${NATIVE_PROBE_HEIGHT}`);
      return false;
    }
    const compRef = renderBrushCore(component, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT);
    const compNat = renderBrushNativeCore(component, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT);
    if (!sameBytes(compRef, compNat)) {
      brushVerifyCache.set(cacheKey, false);
      let firstDiff = -1;
      for (let index = 0; index < compRef.length; index++) {
        if (compRef[index] !== compNat[index]) { firstDiff = index; break; }
      }
      // 逐笔二分：前 n 笔子组件逐个对拍，锁定第一笔出现差异的笔，再打出该笔
      // 的完整参数（mode/flow/density/点数/首点），一次日志定位分歧笔。
      let divergeAt = -1;
      let divergeStroke: MaskWorkerStroke | null = null;
      for (let n = 1; n <= component.strokes.length; n++) {
        const sub: MaskWorkerComponent = {
          renderingVersion: component.renderingVersion, type: component.type,
          blendMode: component.blendMode, enabled: true, visible: true,
          inverted: component.inverted, opacity: component.opacity, feather: component.feather,
          strokes: component.strokes.slice(0, n), linear: component.linear, radial: component.radial,
        };
        if (!sameBytes(renderBrushCore(sub, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT),
          renderBrushNativeCore(sub, NATIVE_PROBE_WIDTH, NATIVE_PROBE_HEIGHT))) {
          divergeAt = n - 1;
          divergeStroke = component.strokes[divergeAt];
          break;
        }
      }
      const strokeInfo = divergeStroke === null ? 'none' :
        `mode=${divergeStroke.mode} flow=${divergeStroke.flow ?? 1} ` +
        `density=${divergeStroke.density ?? 1} points=${divergeStroke.points.length} ` +
        `p0=${divergeStroke.points[0].x},${divergeStroke.points[0].y}` +
        ` r=${divergeStroke.points[0].radius} h=${divergeStroke.points[0].hardness}`;
      // 单笔分歧时 dump 完整点表（一次警告日志），供本地 V8 复算 dab 序列。
      let dump = '';
      if (divergeStroke !== null && divergeStroke.points.length <= 64) {
        const flat: number[] = [];
        for (const point of divergeStroke.points) {
          flat.push(point.x, point.y, point.radius, point.hardness);
        }
        dump = ' pts=' + JSON.stringify(flat);
      }
      const strokes = component.strokes.length;
      const points = component.strokes.reduce((total, stroke): number => total + stroke.points.length, 0);
      console.warn(`VIVID_PERF event=brush_native mismatch=component strokes=${strokes} ` +
        `points=${points} at=${firstDiff} ref=${firstDiff >= 0 ? compRef[firstDiff] : -1} ` +
        `nat=${firstDiff >= 0 ? compNat[firstDiff] : -1} px=${firstDiff % NATIVE_PROBE_WIDTH}` +
        `,${Math.floor(firstDiff / NATIVE_PROBE_WIDTH)} divergeStroke=${divergeAt} ${strokeInfo}${dump}`);
      return false;
    }
    brushVerifyCache.set(cacheKey, true);
    return true;
  } catch (error) {
    console.warn(`VIVID_PERF event=brush_native error=${(error as Error).message ?? error}`);
    brushVerifyCache.set(cacheKey, false);
    return false;
  }
}

function renderLinear(component: MaskWorkerComponent, width: number, height: number): Uint8ClampedArray {
  if (linearNativeVerified(component)) {
    try {
      return renderLinearNative(component, width, height);
    } catch (_error) {
      // Fall through to the reference below.
    }
  }
  return renderLinearReference(component, width, height);
}

function renderRadial(component: MaskWorkerComponent, width: number, height: number): Uint8ClampedArray {
  if (radialNativeVerified(component)) {
    try {
      return renderRadialNative(component, width, height);
    } catch (_error) {
      // Fall through to the reference below.
    }
  }
  return renderRadialReference(component, width, height);
}

function renderBitmap(component: MaskWorkerComponent, width: number, height: number,
  feather: number): Uint8ClampedArray {
  const bitmap = component.bitmap;
  if (!bitmap || bitmap.width <= 0 || bitmap.height <= 0 ||
    bitmap.alpha.byteLength < bitmap.width * bitmap.height) {
    return new Uint8ClampedArray(width * height);
  }
  // The producer's edge is already soft; `feather` only cross-fades the
  // transition band towards a hard cut so the slider stays meaningful in both
  // directions.
  const softness = Math.max(0.05, 1 - Math.min(1, Math.max(0, feather)));
  if (bitmapNativeVerified(component, feather, softness)) {
    try {
      return renderBitmapNative(component, width, height, softness);
    } catch (_error) {
      // Fall through to the reference below.
    }
  }
  return renderBitmapReference(component, width, height, feather);
}

/**
 * Native 参考笔刷：每笔一次 rasterizeBrushStroke 调用（native 端新建独立
 * alpha 缓冲），多笔之间在 ArkTS 按同一 blend 规则合成——合成循环与参考实现
 * 共用（见 renderBrushCore 里的 mode 1/2/0 分支），而单笔栅格化（真正的逐
 * 像素热点）在 native 完成。
 *
 * 注意 scratch 生命周期与参考实现完全一致：每笔开始前清边界带（INTERSECT
 * 清全帧），native 返回的新缓冲直接 set 进 scratch。
 */
function renderBrushNativeCore(component: MaskWorkerComponent, width: number, height: number): Uint8ClampedArray {
  const buffer = new Uint8ClampedArray(width * height);
  const shortSide = Math.min(width, height);
  let boundLeft = width, boundRight = 0, boundTop = height, boundBottom = 0;
  for (const stroke of component.strokes) {
    for (const point of stroke.points) {
      const x = point.x * width, y = point.y * height;
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
      const radius = Math.max(1, point.radius * shortSide);
      if (x - radius < boundLeft) boundLeft = x - radius;
      if (x + radius > boundRight) boundRight = x + radius;
      if (y - radius < boundTop) boundTop = y - radius;
      if (y + radius > boundBottom) boundBottom = y + radius;
    }
  }
  if (boundRight <= boundLeft || boundBottom <= boundTop) return buffer;
  const left = Math.max(0, Math.floor(boundLeft)), right = Math.min(width, Math.ceil(boundRight));
  const top = Math.max(0, Math.floor(boundTop)), bottom = Math.min(height, Math.ceil(boundBottom));
  const scratch = new Uint8ClampedArray(width * height);
  const clearBound = (): void => {
    const span = right - left;
    for (let y = top; y < bottom; y++) {
      const start = y * width + left;
      scratch.fill(0, start, start + span);
    }
  };
  let hasSelection = false;
  for (const stroke of component.strokes) {
    if (stroke.points.length === 0) continue;
    const points = stroke.points;
    if (stroke.mode === 2) scratch.fill(0); else clearBound();
    if ((component.renderingVersion ?? 1) >= 3) {
      // 扁平化点：[x,y,radius,hardness]*n，Float64 与 native 的 double 解包对应。
      const flat = new Float64Array(points.length * 4);
      for (let index = 0; index < points.length; index++) {
        const point = points[index];
        flat[index * 4] = point.x;
        flat[index * 4 + 1] = point.y;
        flat[index * 4 + 2] = point.radius;
        flat[index * 4 + 3] = point.hardness;
      }
      const strokeAlpha: ArrayBuffer = pixelsNative.rasterizeBrushStroke(width, height,
        flat.buffer as ArrayBuffer, stroke.flow ?? 1, stroke.density ?? 1) as ArrayBuffer;
      scratch.set(new Uint8ClampedArray(strokeAlpha));
    } else for (let index = 0; index < points.length; index++) {
      const a = points[index], b = points[Math.min(index + 1, points.length - 1)];
      rasterizeBrushSegment(scratch, width, height, a.x, a.y, a.radius, a.hardness,
        b.x, b.y, b.radius, b.hardness);
    }
    if (stroke.mode === 2 && !hasSelection) {
      buffer.set(scratch);
    } else if (stroke.mode === 1) {
      for (let y = top; y < bottom; y++) {
        const row = y * width;
        for (let x = left; x < right; x++) buffer[row + x] = Math.max(0,
          Math.round(buffer[row + x] * (255 - scratch[row + x]) / 255));
      }
    } else if (stroke.mode === 2) {
      for (let index = 0; index < buffer.length; index++) buffer[index] = Math.round(
        buffer[index] * scratch[index] / 255);
    } else {
      for (let y = top; y < bottom; y++) {
        const row = y * width;
        for (let x = left; x < right; x++) if (scratch[row + x] > buffer[row + x]) {
          buffer[row + x] = scratch[row + x];
        }
      }
    }
    if (stroke.mode === 2) hasSelection = true;
  }
  if (component.autoMask) applyAutoMask(component, width, height, buffer);
  return buffer;
}

/** 笔刷栅格化 + 可选的自动蒙版颜色门限（Lightroom Auto Mask）。 */
function renderBrush(component: MaskWorkerComponent, width: number, height: number): Uint8ClampedArray {
  if (brushNativeVerified(component)) {
    try {
      return renderBrushNativeCore(component, width, height);
    } catch (_error) {
      // Fall through to the reference below.
    }
  }
  const buffer = renderBrushCore(component, width, height);
  if (component.autoMask) applyAutoMask(component, width, height, buffer);
  return buffer;
}

export function rasterizeComponentCore(component: MaskWorkerComponent, width: number, height: number): Uint8ClampedArray {
  let buffer: Uint8ClampedArray;
  if (component.type === 0) buffer = renderBrush(component, width, height);
  else if (component.type === 1) buffer = renderLinear(component, width, height);
  else if (component.type === 3 || component.type === 4 || component.type === 5) {
    // Subject (3), sky (4) and range (5) all carry a stored full-frame raster;
    // they differ only in how that raster was produced, which is not this
    // function's concern.
    buffer = renderBitmap(component, width, height, component.feather);
  } else buffer = renderRadial(component, width, height);
  // 反转/量值各是一整趟逐像素循环，native 版本已逐字节校验过。
  const nativeInvert = (component.inverted || component.opacity < 1)
    ? applyInvertOpacityNative(buffer, component.inverted === true, component.opacity) : false;
  if (!nativeInvert) {
    if (component.inverted) for (let index = 0; index < buffer.length; index++) buffer[index] = 255 - buffer[index];
    if (component.opacity < 1) {
      const opacity = Math.max(0, Math.min(1, component.opacity));
      for (let index = 0; index < buffer.length; index++) buffer[index] = clampByte(buffer[index] * opacity);
    }
  }
  return buffer;
}

/**
 * Rasterized mask alpha plus, when `collectStats` was requested, a compact
 * per-component timing string. Mask rasterisation is the dominant part of an
 * export's pre-render phase, so the export path needs to see which component
 * type (brush / linear / radial / stored raster) is actually costing the time.
 */
export interface MaskRasterOutput {
  alpha: ArrayBuffer;
  stats: string;
}

/** ArkTS twin of the native `composeInto`, used only as the probe reference. */
function composeReference(dst: Uint8ClampedArray, src: Uint8ClampedArray, blendMode: number): void {
  if (blendMode === 1) for (let index = 0; index < dst.length; index++) {
    dst[index] = Math.max(0, Math.round(dst[index] * (255 - src[index]) / 255));
  } else if (blendMode === 2) for (let index = 0; index < dst.length; index++) {
    dst[index] = Math.round(dst[index] * src[index] / 255);
  } else for (let index = 0; index < dst.length; index++) if (src[index] > dst[index]) {
    dst[index] = src[index];
  }
}

/** Blend / invert / amount are one full-frame pass each; verify before adopting. */
function composeNativeVerified(blendMode: number): boolean {
  try {
    const left = new Uint8ClampedArray([10, 200, 127, 255, 0, 61, 128, 3, 250, 5, 99, 64]);
    const right = new Uint8ClampedArray([90, 100, 128, 1, 255, 77, 200, 3, 4, 250, 99, 64]);
    const expected = new Uint8ClampedArray(left);
    composeReference(expected, right, blendMode);
    const actual = new Uint8ClampedArray(left);
    pixelsNative.composeInto(actual.buffer as ArrayBuffer, right.buffer as ArrayBuffer, blendMode);
    return sameBytes(expected, actual);
  } catch (_error) {
    return false;
  }
}

function invertNativeVerified(): boolean {
  try {
    const sample = new Uint8ClampedArray([0, 1, 127, 128, 200, 255, 33, 99]);
    const expected = new Uint8ClampedArray(sample);
    for (let index = 0; index < expected.length; index++) {
      expected[index] = 255 - expected[index];
    }
    for (let index = 0; index < expected.length; index++) {
      expected[index] = clampByte(expected[index] * 0.6);
    }
    const actual = new Uint8ClampedArray(sample);
    pixelsNative.invertOpacity(actual.buffer as ArrayBuffer, true, 0.6);
    return sameBytes(expected, actual);
  } catch (_error) {
    return false;
  }
}

/** Native whole-buffer invert + amount when the probe allows it. */
function applyInvertOpacityNative(buffer: Uint8ClampedArray, inverted: boolean,
  opacity: number): boolean {
  if (!invertNativeVerified()) return false;
  pixelsNative.invertOpacity(buffer.buffer as ArrayBuffer, inverted === true, opacity);
  return true;
}

/** Rasterize one structured mask layer off the ArkUI thread. */
export function rasterizeStructuredMaskCore(layer: MaskWorkerLayer, width: number, height: number,
  collectStats: boolean = false): MaskRasterOutput {
  const result = new Uint8ClampedArray(width * height);
  if (!layer.enabled || !layer.visible) {
    return { alpha: result.buffer as ArrayBuffer, stats: '' };
  }
  let hasSelection = false;
  const startedAt = collectStats ? Date.now() : 0;
  const parts: string[] = [];
  let components = 0;
  for (const component of layer.components) {
    if (!component.enabled || !component.visible) continue;
    const componentStart = collectStats ? Date.now() : 0;
    const source = rasterizeComponentCore(component, width, height);
    // Lightcraft evaluate_one: the first non-intersection initializes the
    // group, even after deleting its original additive component. Preserve
    // legacy sidecar semantics; newly created v2 masks follow the reference.
    const modern = (component.renderingVersion ?? 1) >= 2;
    if (!hasSelection && (modern ? component.blendMode !== 2 : component.blendMode === 2)) {
      result.set(source);
    } else if (composeNativeVerified(component.blendMode)) {
      // 逐像素布尔合成在 native 里做，每分量省一整趟 ArkTS 循环。
      pixelsNative.composeInto(result.buffer as ArrayBuffer, source.buffer as ArrayBuffer,
        component.blendMode);
    } else if (component.blendMode === 1) for (let index = 0; index < result.length; index++) {
      result[index] = Math.max(0, Math.round(result[index] * (255 - source[index]) / 255));
    }
    else if (component.blendMode === 2) for (let index = 0; index < result.length; index++) {
      result[index] = Math.round(result[index] * source[index] / 255);
    }
    else for (let index = 0; index < result.length; index++) if (source[index] > result[index]) {
      result[index] = source[index];
    }
    hasSelection = true;
    components++;
    if (collectStats) {
      // 类型与渲染版本之间必须有分隔符：拼接成 "13" 无法区分"类型1版本3"和
      // "类型13"，之前就这样误读过一次。
      parts.push(`${component.type}v${component.renderingVersion ?? 1}:${Date.now() - componentStart}ms` +
        `/${component.strokes.length}st`);
    }
  }
  // Whole-group inversion occurs after boolean composition, before amount.
  const nativeGroup = (layer.inverted === true || layer.opacity < 1)
    ? applyInvertOpacityNative(result, layer.inverted === true, layer.opacity) : false;
  if (!nativeGroup) {
    if (layer.inverted) for (let index = 0; index < result.length; index++) result[index] = 255 - result[index];
    if (layer.opacity < 1) {
      const opacity = Math.max(0, Math.min(1, layer.opacity));
      for (let index = 0; index < result.length; index++) result[index] = clampByte(result[index] * opacity);
    }
  }
  const stats = collectStats
    ? `ms=${Date.now() - startedAt} comps=${components} parts=${parts.join(',')}` : '';
  return { alpha: result.buffer as ArrayBuffer, stats: stats };
}
