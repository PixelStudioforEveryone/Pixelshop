/**
 * 大光圈模拟（Edmund Lumen Bokeh）— 文档级景深虚化阶段。
 *
 * 参数语义与 KyMoShI/edmund-lumen-bokeh（MIT）保持一致，并由
 * `vivid_bokeh` 原生库执行：深度图 + 光圈 PSF 卷积 + 光圈形状光斑叠加。
 * 与降噪/细节/光学一样，这是整帧阶段：它必须发生在几何裁剪之前，深度图
 * 才与像素对齐。
 */

/** 光斑形状：0 = 圆形，5..9 = 对应叶片数的圆角多边形。 */
export enum BokehShape {
  CIRCLE = 0,
  PENTAGON = 5,
  HEXAGON = 6,
  HEPTAGON = 7,
  OCTAGON = 8,
  NONAGON = 9,
}

export interface BokehValues {
  enabled: boolean;
  /** 模拟光圈值 f/1.2 … f/8，越小虚化越强。 */
  aperture: number;
  /** 虚化强度 0..1。 */
  blurStrength: number;
  /** 光斑强度 0..1。 */
  bokehStrength: number;
  /** 0 或 5..9。 */
  shape: number;
  /** 光斑密度 0..1。 */
  density: number;
  /** 光斑大小 0.3..2（1 = 100%）。 */
  size: number;
  /** 球差 -1..+1：正值=边缘亮环，负值=中心亮核。 */
  spherical: number;
  /** 焦点深度 0..0.98；深度图里值越大越近。 */
  focus: number;
}

/**
 * 旧 sidecar 没有这个字段时恢复成精确旁路，而不是半强度效果。
 *
 * 与 OpticsSettings 相同的做法：每个字段都在自己的有效区间内还原，
 * 非法值回落到默认值，确保 JSON 里一个坏数字不会变成“看起来像开了”的状态。
 */
@Observed
export class BokehSettings implements BokehValues {
  public enabled: boolean = false;
  public aperture: number = 1.4;
  public blurStrength: number = 0.55;
  public bokehStrength: number = 0.35;
  public shape: number = 7;
  public density: number = 0.55;
  public size: number = 1.0;
  public spherical: number = 0;
  public focus: number = 0.45;

  clone(): BokehSettings {
    return BokehSettings.restore(this);
  }

  static restore(value?: BokehValues): BokehSettings {
    const result = new BokehSettings();
    if (!value) return result;
    result.enabled = value.enabled === true;
    result.aperture = BokehSettings.clamp(value.aperture, 1.2, 8, 1.4);
    result.blurStrength = BokehSettings.clamp(value.blurStrength, 0, 1, 0.55);
    result.bokehStrength = BokehSettings.clamp(value.bokehStrength, 0, 1, 0.35);
    result.shape = BokehSettings.shapeValue(value.shape, 7);
    result.density = BokehSettings.clamp(value.density, 0, 1, 0.55);
    result.size = BokehSettings.clamp(value.size, 0.3, 2, 1.0);
    result.spherical = BokehSettings.clamp(value.spherical, -1, 1, 0);
    result.focus = BokehSettings.clamp(value.focus, 0, 0.98, 0.45);
    return result;
  }

  reset(): void {
    this.enabled = false;
    this.aperture = 1.4;
    this.blurStrength = 0.55;
    this.bokehStrength = 0.35;
    this.shape = 7;
    this.density = 0.55;
    this.size = 1.0;
    this.spherical = 0;
    this.focus = 0.45;
  }

  /** 精确旁路：关闭时整段不进入渲染管线。 */
  isBypass(): boolean {
    return !this.enabled;
  }

  /** 形状下拉菜单的显示名。 */
  shapeLabel(): string {
    if (this.shape < 3) return '圆形';
    return `${Math.round(this.shape)} 边形`;
  }

  /** 形状下拉菜单的选项。顺序与 native ABI 无关，值取自枚举。 */
  static shapeOptions(): SelectOption[] {
    return [
      { value: '圆形' },
      { value: '5 边形' },
      { value: '6 边形' },
      { value: '7 边形' },
      { value: '8 边形' },
      { value: '9 边形' },
    ];
  }

  static shapeFromIndex(index: number): number {
    const values: number[] = [0, 5, 6, 7, 8, 9];
    if (index < 0 || index >= values.length) return 0;
    return values[index];
  }

  static shapeIndex(shape: number): number {
    const values: number[] = [0, 5, 6, 7, 8, 9];
    const index = values.indexOf(Math.round(shape));
    return index >= 0 ? index : 0;
  }

  /**
   * 点选对焦：在归一化画面坐标 (u, v) 处取深度，返回 0.01..0.98 的焦点值。
   *
   * 取 5×5 邻域的平均值，而不是单像素：深度图在设备上只有 384 长边，单点
   * 采样会把模型的小噪点直接变成焦点漂移；邻域平均仍能跟随主体边缘。
   */
  static focusFromDepth(depth: Uint8Array, width: number, height: number,
    u: number, v: number): number {
    if (!depth || width <= 0 || height <= 0) return 0.45;
    const cx = Math.round(Math.max(0, Math.min(1, u)) * (width - 1));
    const cy = Math.round(Math.max(0, Math.min(1, v)) * (height - 1));
    let total = 0;
    let count = 0;
    for (let dy = -2; dy <= 2; dy++) {
      const y = cy + dy;
      if (y < 0 || y >= height) continue;
      for (let dx = -2; dx <= 2; dx++) {
        const x = cx + dx;
        if (x < 0 || x >= width) continue;
        total += depth[y * width + x];
        count++;
      }
    }
    if (count === 0) return 0.45;
    return Math.max(0.01, Math.min(0.98, total / count / 255));
  }

  private static clamp(value: number, min: number, max: number, fallback: number): number {
    if (!Number.isFinite(value)) return fallback;
    return Math.max(min, Math.min(max, value));
  }

  private static shapeValue(value: number, fallback: number): number {
    if (!Number.isFinite(value)) return fallback;
    const rounded = Math.round(value);
    return rounded === 0 || (rounded >= 5 && rounded <= 9) ? rounded : fallback;
  }
}
