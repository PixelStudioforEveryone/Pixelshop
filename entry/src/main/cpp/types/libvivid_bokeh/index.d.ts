/**
 * 大光圈模拟（Edmund Lumen Bokeh）原生阶段。
 *
 * 纯 CPU、无第三方依赖；调用方负责在后台线程执行，并保证 `rgba` 与
 * `depth` 在调用期间有效。参数语义与 `BokehSettings` 一一对应。
 */
export interface VividBokehOptions {
  /** 模拟光圈 f/1.2 … f/8。 */
  aperture: number;
  /** 虚化强度 0..1。 */
  blurStrength: number;
  /** 光斑强度 0..1。 */
  bokehStrength: number;
  /** 0 = 圆形，5..9 = 对应叶片数。 */
  shape: number;
  /** 光斑密度 0..1。 */
  density: number;
  /** 光斑大小 0.3..2。 */
  size: number;
  /** 球差 -1..+1。 */
  spherical: number;
  /** 焦点深度 0..0.98。 */
  focus: number;
}

/**
 * 渲染一帧大光圈效果。
 *
 * @param rgba        源 RGBA8888（width*height*4）。
 * @param width       源宽度。
 * @param height      源高度。
 * @param depth       单通道深度图（值越大越近），可为 null 以使用中心对焦。
 * @param depthWidth  深度图宽度。
 * @param depthHeight 深度图高度。
 * @param options     光圈/虚化/光斑参数。
 * @returns 新的 RGBA8888 ArrayBuffer（width*height*4）；失败时返回 null。
 */
export function render(
  rgba: ArrayBuffer,
  width: number,
  height: number,
  depth: ArrayBuffer | null,
  depthWidth: number,
  depthHeight: number,
  options: VividBokehOptions
): ArrayBuffer;
