/**
 * 画笔自动蒙版（Lightroom Auto Mask）的颜色门限内核。
 *
 * 结构是两步，这不是优化而是必需的：
 *
 * 1. **在源图代理网格上算一次门限**（`buildGate`）。门限是"颜色相似度"的
 *    空间分布，它的信息量上限就是源图代理的网格密度（颜色本身也只在那个
 *    网格上有）。在栅格分辨率上逐 dab 冲压会让代价随输出分辨率放大：预览
 *    1.3K 还好，导出 44MP 就是灾难级的慢——而那正是导出变慢的来源之一。
 * 2. **把门限双线性套到目标栅格**（`applyGate`）。代价只与笔迹覆盖面积成正比，
 *    与"这一笔在多少分辨率下栅格化"无关，任意输出尺寸都同样便宜，而且双线性
 *    采样让门限边缘是软的，不会出现方块台阶。
 *
 * 另外两条之前踩过的坑在这里保留：参考色**沿笔画插值**（一笔从天空划到屋檐时
 * 门限跟着过渡），颜色距离用**归一化的感知加权**（除以权重和，否则"容差"不再
 * 是每通道容差，绿色实际只剩一半，门限会严到像没开一样）。
 */
import { RangeMaskProxy } from './RangeMaskCore';
import { MaskWorkerPoint } from './MaskWorkerTypes';

/** 颜色距离的感知加权：绿通道权重最高，近似人眼对亮度的敏感度分布。 */
const WEIGHT_R: number = 2;
const WEIGHT_G: number = 4;
const WEIGHT_B: number = 3;
/** 权重和：距离平方要除以它，容差才等于"每通道容差"。 */
const WEIGHT_SUM: number = WEIGHT_R + WEIGHT_G + WEIGHT_B;

/** 双线性采样源代理的一个通道，越界钳制到边缘。 */
function sampleChannel(proxy: RangeMaskProxy, x: number, y: number, channel: number): number {
  const width = proxy.width, height = proxy.height;
  const fx = Math.max(0, Math.min(width - 1, x));
  const fy = Math.max(0, Math.min(height - 1, y));
  const x0 = Math.floor(fx), y0 = Math.floor(fy);
  const x1 = Math.min(width - 1, x0 + 1), y1 = Math.min(height - 1, y0 + 1);
  const tx = fx - x0, ty = fy - y0;
  const rgb = proxy.rgb;
  const i00 = (y0 * width + x0) * 3 + channel;
  const i10 = (y0 * width + x1) * 3 + channel;
  const i01 = (y1 * width + x0) * 3 + channel;
  const i11 = (y1 * width + x1) * 3 + channel;
  const top = rgb[i00] + (rgb[i10] - rgb[i00]) * tx;
  const bottom = rgb[i01] + (rgb[i11] - rgb[i01]) * tx;
  return top + (bottom - top) * ty;
}

/** 采样门限缓冲（单通道）的一个值，双线性，越界钳制。 */
function sampleGate(gate: Uint8ClampedArray, width: number, height: number,
  x: number, y: number): number {
  const fx = Math.max(0, Math.min(width - 1, x));
  const fy = Math.max(0, Math.min(height - 1, y));
  const x0 = Math.floor(fx), y0 = Math.floor(fy);
  const x1 = Math.min(width - 1, x0 + 1), y1 = Math.min(height - 1, y0 + 1);
  const tx = fx - x0, ty = fy - y0;
  const i00 = y0 * width + x0, i10 = y0 * width + x1;
  const i01 = y1 * width + x0, i11 = y1 * width + x1;
  const top = gate[i00] + (gate[i10] - gate[i00]) * tx;
  const bottom = gate[i01] + (gate[i11] - gate[i01]) * tx;
  return top + (bottom - top) * ty;
}

/** 灵敏度 0..1 → 每通道容差（0..255）；0.5 时约 64。 */
function toleranceFor(sensitivity: number): number {
  const clamped = Math.max(0, Math.min(1, sensitivity));
  return 8 + clamped * 112;
}

/**
 * 在代理网格上建立门限：每个 dab 用插值后的参考色与网格像素比色，取最大值
 * （over 合成），与笔刷自己的冲压几何一致（相邻点按 radius/4 插值）。
 */
function buildGate(points: MaskWorkerPoint[], proxy: RangeMaskProxy,
  sensitivity: number): Uint8ClampedArray {
  const width = proxy.width, height = proxy.height;
  const gate = new Uint8ClampedArray(width * height);
  const shortSide = Math.min(width, height);
  const tolerance = toleranceFor(sensitivity);
  const tolerance2 = tolerance * tolerance;
  const keep2 = tolerance2 * 0.36;

  // 落笔点的参考色（代理网格上的双线性采样）。
  const count = points.length;
  const refR = new Float32Array(count);
  const refG = new Float32Array(count);
  const refB = new Float32Array(count);
  let maxRadius = 0;
  for (let index = 0; index < count; index++) {
    const point = points[index];
    const px = Math.max(0, Math.min(1, point.x)) * width - 0.5;
    const py = Math.max(0, Math.min(1, point.y)) * height - 0.5;
    refR[index] = sampleChannel(proxy, px, py, 0);
    refG[index] = sampleChannel(proxy, px, py, 1);
    refB[index] = sampleChannel(proxy, px, py, 2);
    const radius = Math.max(1, point.radius * shortSide);
    if (radius > maxRadius) maxRadius = radius;
  }
  if (maxRadius <= 0) return gate;

  const stamp = (cx: number, cy: number, radius: number, r: number, g: number, b: number): void => {
    const left = Math.max(0, Math.floor(cx - radius));
    const right = Math.min(width, Math.ceil(cx + radius));
    const top = Math.max(0, Math.floor(cy - radius));
    const bottom = Math.min(height, Math.ceil(cy + radius));
    if (right <= left || bottom <= top) return;
    const radius2 = radius * radius;
    for (let y = top; y < bottom; y++) {
      const dy = y + 0.5 - cy;
      const row = y * width;
      for (let x = left; x < right; x++) {
        const dx = x + 0.5 - cx;
        const distance = dx * dx + dy * dy;
        if (distance > radius2) continue;
        const cr = proxy.rgb[(row + x) * 3];
        const cg = proxy.rgb[(row + x) * 3 + 1];
        const cb = proxy.rgb[(row + x) * 3 + 2];
        const dr = cr - r, dg = cg - g, db = cb - b;
        const color2 = (WEIGHT_R * dr * dr + WEIGHT_G * dg * dg + WEIGHT_B * db * db) / WEIGHT_SUM;
        let weight: number;
        if (color2 <= keep2) weight = 255;
        else if (color2 >= tolerance2) weight = 0;
        else {
          const t = (Math.sqrt(color2 / tolerance2) - 0.6) / 0.4;
          weight = Math.round(255 * (1 - t * t * (3 - 2 * t)));
        }
        if (weight === 0) continue;
        const offset = row + x;
        if (weight > gate[offset]) gate[offset] = weight;
      }
    }
  };

  const spacing = Math.max(0.5, maxRadius / 4);
  let started = false;
  let previousX = 0, previousY = 0, previousRadius = 0;
  let previousR = 0, previousG = 0, previousB = 0;
  for (let index = 0; index < count; index++) {
    const point = points[index];
    const x = point.x * width, y = point.y * height;
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
    const radius = Math.max(1, point.radius * shortSide);
    const r = refR[index], g = refG[index], b = refB[index];
    if (started) {
      const span = Math.hypot(x - previousX, y - previousY);
      if (span > 1e-6) {
        const steps = Math.min(1000000, Math.ceil(span / spacing));
        for (let step = 1; step < steps; step++) {
          const t = step / steps;
          stamp(previousX + (x - previousX) * t, previousY + (y - previousY) * t,
            previousRadius + (radius - previousRadius) * t,
            previousR + (r - previousR) * t, previousG + (g - previousG) * t,
            previousB + (b - previousB) * t);
        }
      }
    }
    stamp(x, y, radius, r, g, b);
    previousX = x; previousY = y; previousRadius = radius;
    previousR = r; previousG = g; previousB = b;
    started = true;
  }
  return gate;
}

/**
 * 把自动蒙版门限作用到已栅格化的笔刷 alpha 上（原地修改 buffer）。
 *
 * `points` 与笔刷共用同一套几何；`proxy` 是**源图坐标系**的 RGB 代理（必须与
 * 栅格同一坐标系，否则门限会采到图片上不相干的位置）；`sensitivity` 是容差。
 */
export function applyBrushAutoMask(buffer: Uint8ClampedArray, width: number, height: number,
  points: MaskWorkerPoint[], proxy: RangeMaskProxy | null, sensitivity: number): void {
  if (!proxy || points.length === 0 || width < 1 || height < 1) return;
  if (proxy.width < 1 || proxy.height < 1 || proxy.rgb.length < proxy.width * proxy.height * 3) return;
  const gate = buildGate(points, proxy, sensitivity);
  const proxyWidth = proxy.width, proxyHeight = proxy.height;
  const shortSide = Math.min(width, height);

  // 只需处理笔迹可能覆盖的范围：门限非零处必然落在某个 dab 内。
  let maxRadius = 0;
  let boundLeft = width, boundRight = 0, boundTop = height, boundBottom = 0;
  for (const point of points) {
    const x = point.x * width, y = point.y * height;
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
    const radius = Math.max(1, point.radius * shortSide);
    if (radius > maxRadius) maxRadius = radius;
    if (x - radius < boundLeft) boundLeft = x - radius;
    if (x + radius > boundRight) boundRight = x + radius;
    if (y - radius < boundTop) boundTop = y - radius;
    if (y + radius > boundBottom) boundBottom = y + radius;
  }
  if (boundRight <= boundLeft || boundBottom <= boundTop) return;
  const left = Math.max(0, Math.floor(boundLeft)), right = Math.min(width, Math.ceil(boundRight));
  const top = Math.max(0, Math.floor(boundTop)), bottom = Math.min(height, Math.ceil(boundBottom));
  const scaleX = proxyWidth / width, scaleY = proxyHeight / height;
  for (let y = top; y < bottom; y++) {
    const row = y * width;
    const proxyY = (y + 0.5) * scaleY - 0.5;
    for (let x = left; x < right; x++) {
      const value = buffer[row + x];
      if (value === 0) continue;
      const weight = sampleGate(gate, proxyWidth, proxyHeight, (x + 0.5) * scaleX - 0.5, proxyY);
      buffer[row + x] = Math.round(value * weight / 255);
    }
  }
}
