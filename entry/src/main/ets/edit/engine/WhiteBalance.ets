import { solveNeutralPatch, wbSrgbToLinear } from './WhiteBalancePickerCore';

/**
 * 白平衡估计。
 *
 * 只用缩略像素统计，成本与图像分辨率无关：
 *  1. 取亮度最高的 7% 像素做“白点”候选，逐通道取中位数——比灰世界稳，
 *     因为大面积单色场景（草地、天空）会把灰世界拉偏；
 *  2. 与全图逐通道均值按 0.7 / 0.3 加权，兼顾整体偏色；
 *  3. 把光源色换算成色温 / 色调偏移（暖→色温正、绿→色调负、品红→色调正）。
 */
export class WhiteBalance {
  /** 白点在候选集合里的占比。 */
  static readonly WHITE_PERCENTILE: number = 0.07;
  /** 白点法与灰世界法的权重。 */
  static readonly WHITE_WEIGHT: number = 0.7;

  /**
   * 估计光源色。
   *
   * @param rgba RGBA8888 像素
   * @returns 三个通道 0..255 的估计值，越接近中性灰说明已平衡
   */
  static estimateLight(rgba: Uint8Array | Uint8ClampedArray, width: number,
    height: number): number[] {
    const count = Math.max(1, Math.min(Math.floor(width * height), Math.floor(rgba.length / 4)));
    const luma = new Float32Array(count);
    let sumR = 0, sumG = 0, sumB = 0;
    for (let index = 0; index < count; index++) {
      const offset = index * 4;
      const r = rgba[offset];
      const g = rgba[offset + 1];
      const b = rgba[offset + 2];
      luma[index] = (r * 299 + g * 587 + b * 114) / 1000;
      sumR += r; sumG += g; sumB += b;
    }
    const meanR = sumR / count, meanG = sumG / count, meanB = sumB / count;

    // 直方图取阈值，避免对大数组排序。
    const histogram = new Uint32Array(256);
    for (let index = 0; index < count; index++) histogram[Math.min(255, Math.max(0, luma[index] | 0))]++;
    const wanted = Math.max(1, Math.floor(count * WhiteBalance.WHITE_PERCENTILE));
    let threshold = 255, seen = 0;
    for (let value = 255; value >= 0; value--) {
      seen += histogram[value];
      if (seen >= wanted) { threshold = value; break; }
    }

    let countR = 0, countG = 0, countB = 0, kept = 0;
    for (let index = 0; index < count; index++) {
      if (luma[index] < threshold) continue;
      const offset = index * 4;
      countR += rgba[offset];
      countG += rgba[offset + 1];
      countB += rgba[offset + 2];
      kept++;
    }
    if (kept < 8) return [meanR, meanG, meanB];

    const whiteR = countR / kept, whiteG = countG / kept, whiteB = countB / kept;
    const weight = WhiteBalance.WHITE_WEIGHT;
    return [
      whiteR * weight + meanR * (1 - weight),
      whiteG * weight + meanG * (1 - weight),
      whiteB * weight + meanB * (1 - weight),
    ];
  }

  /**
   * 光源色 → 色温 / 色调偏移。
   *
   * 换算复用吸管那套求解（WhiteBalancePickerCore.solveNeutralPatch），
   * 保证自动白平衡和手动吸点写出的是同一个坐标系里的参数：
   * 增益在 sRGB → 线性光之后乘，数值与 WorkerCore / GpuShaderBridge 一致。
   *
   * @param light 估计出的光源色（R,G,B 0..255）
   * @param temperatureLimit 色温参数允许的绝对上限
   * @param tintLimit 色调参数允许的绝对上限
   */
  static toTemperatureTint(light: number[], temperatureLimit: number = 1,
    tintLimit: number = 1): number[] {
    const solved = solveNeutralPatch(
      wbSrgbToLinear(light[0]), wbSrgbToLinear(light[1]), wbSrgbToLinear(light[2]));
    if (!solved.ok) return [0, 0];
    return [
      WhiteBalance.clamp(solved.temperature, -1, 1) * temperatureLimit,
      WhiteBalance.clamp(solved.tint, -1, 1) * tintLimit,
    ];
  }

  private static clamp(value: number, low: number, high: number): number {
    return value < low ? low : (value > high ? high : value);
  }
}
