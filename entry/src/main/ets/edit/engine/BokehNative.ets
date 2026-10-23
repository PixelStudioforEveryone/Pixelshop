/**
 * 大光圈原生库的唯一调用点。
 *
 * 这里只做参数整形与异常兜底：任何 native 失败都返回 null，让调用方保留
 * 已经渲染好的调色结果，而不是让一帧变黑。真正的算法在 vivid_bokeh.cpp。
 */
import bokehNative from 'libvivid_bokeh.so';
import { BokehValues } from '../models/BokehSettings';

/**
 * 同步渲染。调用方必须已经在后台线程（TaskPool worker）；UI 线程直接调用
 * 会在 24MP 导出上卡住数百毫秒到数秒。
 */
export function renderBokeh(rgba: ArrayBuffer, width: number, height: number,
  depth: ArrayBuffer | null, depthWidth: number, depthHeight: number,
  values: BokehValues): ArrayBuffer | null {
  if (width <= 0 || height <= 0 || rgba.byteLength < width * height * 4) return null;
  const hasDepth = depth !== null && depth.byteLength >= depthWidth * depthHeight &&
    depthWidth > 0 && depthHeight > 0;
  try {
    const result: ArrayBuffer = bokehNative.render(rgba, width, height,
      hasDepth ? depth : null, hasDepth ? depthWidth : 0, hasDepth ? depthHeight : 0, {
        aperture: values.aperture,
        blurStrength: values.blurStrength,
        bokehStrength: values.bokehStrength,
        shape: values.shape,
        density: values.density,
        size: values.size,
        spherical: values.spherical,
        focus: values.focus,
      });
    if (!result || result.byteLength !== width * height * 4) return null;
    return result;
  } catch (error) {
    console.error('VIVID_BOKEH native render failed: ' + String(error));
    return null;
  }
}
