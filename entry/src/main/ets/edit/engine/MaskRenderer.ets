import { rasterizeBrushSegment } from './BrushRasterizer';
import { MaskWorkerBitmap, MaskWorkerComponent, MaskWorkerStroke, MaskWorkerPoint, rasterizeComponentCore, rasterizeStructuredMaskCore } from './MaskRasterCore';
import {
  MaskState, MaskType, BrushStroke, BrushPoint, LinearGradientParams, RadialGradientParams,
  MaskLayer, MaskComponent, MaskComponentType, MaskBlendMode, maskWorkerType, isRasterComponentType,
} from '../models/Mask';

/**
 * Copy a component's stored raster into the transfer-safe worker shape.
 *
 * The alpha is copied rather than shared: the same component is rasterised on
 * the UI thread for the overlay and inside a TaskPool worker for export, and a
 * shared ArrayBuffer would let one path observe a half-updated selection.
 * Returns null when the component has no raster (including "not produced yet"),
 * which rasterises to an empty selection.
 */
export function bitmapWorkerData(component: MaskComponent): MaskWorkerBitmap | null {
  if (!isRasterComponentType(component.type)) return null;
  const data = component.raster;
  if (!data || !data.hasAlpha) return null;
  const copy = new ArrayBuffer(data.width * data.height);
  new Uint8Array(copy).set(data.alpha.subarray(0, data.width * data.height));
  return { width: data.width, height: data.height, alpha: copy };
}

/**
 * Renders masks to alpha buffers at given dimensions.
 * All coordinates are normalized [0..1].
 */
export class MaskRenderer {
  /** Render and compose every component in one Lightroom-style mask layer. */
  /**
   * 交互预览用的封顶栅格化。
   *
   * 笔刷蒙版的栅格化成本与像素面积、笔数、点数成正比：在 1536x2048 的预览通道上
   * 画到二十几笔就要六秒多，直接被系统当 ANR 杀掉。交互预览只需要
   * 蒙版边界大致对得上，因此先在封顶尺寸上栅格化，再最近邻放大到目标尺寸；
   * 导出路径仍然走未封顶的 renderMaskLayer。
   */
  static renderMaskLayerCapped(layer: MaskLayer, width: number, height: number,
    maxEdge: number): Uint8ClampedArray {
    const edge = Math.max(width, height);
    if (maxEdge <= 0 || edge <= maxEdge) return MaskRenderer.renderMaskLayer(layer, width, height);
    const scale = maxEdge / edge;
    const smallW = Math.max(1, Math.round(width * scale));
    const smallH = Math.max(1, Math.round(height * scale));
    const small = MaskRenderer.renderMaskLayer(layer, smallW, smallH);
    const out = new Uint8ClampedArray(width * height);
    for (let y = 0; y < height; y++) {
      const sy = Math.min(smallH - 1, Math.floor(y * smallH / height));
      const srcRow = sy * smallW;
      const dstRow = y * width;
      for (let x = 0; x < width; x++) {
        out[dstRow + x] = small[srcRow + Math.min(smallW - 1, Math.floor(x * smallW / width))];
      }
    }
    return out;
  }

  static renderMaskLayer(layer: MaskLayer, width: number, height: number): Uint8ClampedArray {
    // Overlay, thumbnails, GPU alpha and CPU export share the same reference
    // composition. A display-order reversal never mutates this model order.
    const rendered = rasterizeStructuredMaskCore({
      enabled: layer.enabled, visible: layer.visible, inverted: layer.inverted,
      opacity: layer.opacity,
      components: layer.components.map((part: MaskComponent): MaskWorkerComponent => MaskRenderer.plainComponent(part)),
    }, width, height);
    return new Uint8ClampedArray(rendered.alpha);
  }
  static renderComponent(component: MaskComponent, width: number, height: number): Uint8ClampedArray {
    // One geometry implementation for overlay, GPU alpha and TaskPool export.
    return rasterizeComponentCore(MaskRenderer.plainComponent(component), width, height);
  }

  private static plainComponent(component: MaskComponent): MaskWorkerComponent {
    component.ensureData();
    return {
      renderingVersion: component.renderingVersion,
      type: maskWorkerType(component.type),
      blendMode: component.blendMode === MaskBlendMode.ADD ? 0 :
        (component.blendMode === MaskBlendMode.SUBTRACT ? 1 : 2),
      enabled: component.enabled, visible: component.visible, inverted: component.inverted,
      opacity: component.opacity, feather: component.feather,
      strokes: (component.brushData?.strokes ?? []).map((stroke: BrushStroke): MaskWorkerStroke => ({
        mode: stroke.mode, flow: stroke.flow, density: stroke.density,
        points: stroke.points.map((point: BrushPoint): MaskWorkerPoint => ({
          x: point.x, y: point.y, radius: point.radius, hardness: point.hardness,
        })),
      })),
      linear: component.linearGradientData ? [component.linearGradientData.startX,
        component.linearGradientData.startY, component.linearGradientData.endX,
        component.linearGradientData.endY] : [0.5, 0, 0.5, 1],
      radial: component.radialGradientData ? [component.radialGradientData.centerX,
        component.radialGradientData.centerY, component.radialGradientData.radiusX,
        component.radialGradientData.radiusY, component.radialGradientData.rotation] : [0.5, 0.5, 0.5, 0.5, 0],
      bitmap: bitmapWorkerData(component),
      autoMask: component.brushData?.autoMask ?? false,
      autoMaskSensitivity: component.brushData?.sensitivity ?? 0.5,
      // 自动蒙版的源代理由 ImageProcessor 在栅格化前注入（MaskRenderer 拿不到
      // 会话，也就拿不到源图像）；这里留空表示"未注入"。
      sourceProxyWidth: 0,
      sourceProxyHeight: 0,
      sourceProxyRgb: null,
    };
  }

  /**
   * Render a complete mask to an alpha buffer.
   * Returns Uint8ClampedArray of length width*height, each value 0..255.
   */
  static renderMask(
    mask: MaskState,
    width: number,
    height: number,
  ): Uint8ClampedArray {
    if (!mask || mask.type === MaskType.NONE) {
      return MaskRenderer.fullAlpha(width, height);
    }

    let buffer: Uint8ClampedArray;

    switch (mask.type) {
      case MaskType.BRUSH:
        buffer = MaskRenderer.renderBrush(mask.brushStrokes, width, height);
        break;
      case MaskType.LINEAR_GRADIENT:
        buffer = MaskRenderer.renderLinearMask(mask, width, height);
        break;
      case MaskType.RADIAL_GRADIENT:
        buffer = MaskRenderer.renderRadialGradient(mask.radialGradient, width, height);
        break;
      default:
        buffer = MaskRenderer.fullAlpha(width, height);
    }

    // Post-process: feather and invert
    if (mask.feather > 0 || mask.invert) {
      MaskRenderer.postProcess(buffer, width, height, mask.feather, mask.invert);
    }

    return buffer;
  }

  static fullAlpha(width: number, height: number): Uint8ClampedArray {
    const buffer = new Uint8ClampedArray(width * height);
    buffer.fill(255);
    return buffer;
  }

  static renderBrush(
    strokes: BrushStroke[],
    width: number,
    height: number,
  ): Uint8ClampedArray {
    const buffer = new Uint8ClampedArray(width * height);
    if (strokes.length === 0) return buffer;

    // Strokes render in order; each one combines with the accumulated mask
    // according to its mode: union (add), erase (delete) or intersect.
    let hasSelection = false;
    for (const stroke of strokes) {
      if (stroke.points.length === 0) continue;
      const strokeBuffer = MaskRenderer.renderBrushStroke(stroke, width, height);
      if (!hasSelection && stroke.mode === 2) buffer.set(strokeBuffer);
      else MaskRenderer.combine(buffer, strokeBuffer, stroke.mode);
      hasSelection = true;
    }

    return buffer;
  }

  /** Render ordered add/subtract linear components. The first component is an
   * additive mask; later components can union or remove coverage, matching the
   * mask stack interaction used by Lightroom/Camera Raw. */
  private static renderLinearMask(mask: MaskState, width: number, height: number): Uint8ClampedArray {
    if (!mask.linearParts || mask.linearParts.length === 0) {
      return MaskRenderer.renderLinearGradient(mask.linearGradient, width, height);
    }
    const result = new Uint8ClampedArray(width * height);
    for (const part of mask.linearParts) {
      const source = MaskRenderer.renderLinearGradient(part.params, width, height);
      if (part.operation === 1) {
        for (let index = 0; index < result.length; index++) {
          result[index] = Math.max(0, Math.round(result[index] * (255 - source[index]) / 255));
        }
      } else {
        for (let index = 0; index < result.length; index++) {
          if (source[index] > result[index]) result[index] = source[index];
        }
      }
    }
    return result;
  }

  private static renderBrushStroke(stroke: BrushStroke, width: number, height: number): Uint8ClampedArray {
    const buffer = new Uint8ClampedArray(width * height);
    const points = stroke.points;
    for (let index = 0; index < points.length; index++) {
      const a = points[index];
      const b = points[Math.min(index + 1, points.length - 1)];
      rasterizeBrushSegment(buffer, width, height, a.x, a.y, a.radius, a.hardness,
        b.x, b.y, b.radius, b.hardness);
    }
    return buffer;
  }

  /** Combine a stroke's alpha with the accumulated mask by brush mode. */
  private static combine(target: Uint8ClampedArray, stroke: Uint8ClampedArray, mode: number): void {
    const len = target.length;
    if (mode === 1) {
      // Erase (delete): remove stroke area from the mask.
      for (let i = 0; i < len; i++) {
        target[i] = Math.max(0, Math.round(target[i] * (255 - stroke[i]) / 255));
      }
    } else if (mode === 2) {
      // Intersect: keep only where the stroke overlaps the existing mask.
      for (let i = 0; i < len; i++) {
        target[i] = Math.round(target[i] * stroke[i] / 255);
      }
    } else {
      // Union (add): the default behaviour.
      for (let i = 0; i < len; i++) {
        if (stroke[i] > target[i]) target[i] = stroke[i];
      }
    }
  }


  static renderLinearGradient(
    params: LinearGradientParams,
    width: number,
    height: number,
  ): Uint8ClampedArray {
    const buffer = new Uint8ClampedArray(width * height);
    const sx = params.startX * width;
    const sy = params.startY * height;
    const ex = params.endX * width;
    const ey = params.endY * height;

    const dx = ex - sx;
    const dy = ey - sy;
    const len2 = dx * dx + dy * dy;

    if (len2 < 1) {
      buffer.fill(255);
      return buffer;
    }

    const len = Math.sqrt(len2);
    // The two handles define the direction and the midpoint is the nominal
    // transition boundary. Feather widens that boundary symmetrically; the
    // previous split at t=.5 produced a 0 -> 255 jump in the middle of every
    // linear mask.
    const feather = Math.max(0, Math.min(0.5, params.feather));
    const transitionStart = 0.5 - feather;
    const transitionEnd = 0.5 + feather;

    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        // Project point onto gradient line
        const px = x - sx;
        const py = y - sy;
        let t = (px * dx + py * dy) / len2;
        t = Math.max(0, Math.min(1, t));

        let alpha: number;
        if (feather <= 0.0001) {
          alpha = t < 0.5 ? 255 : 0;
        } else if (t <= transitionStart) {
          alpha = 255;
        } else if (t >= transitionEnd) {
          alpha = 0;
        } else {
          alpha = Math.round(255 * (1 - (t - transitionStart) /
            Math.max(0.0001, transitionEnd - transitionStart)));
        }
        alpha = Math.max(0, Math.min(255, alpha));
        buffer[y * width + x] = alpha;
      }
    }
    return buffer;
  }

  static renderRadialGradient(
    params: RadialGradientParams,
    width: number,
    height: number,
  ): Uint8ClampedArray {
    const buffer = new Uint8ClampedArray(width * height);
    const cx = params.centerX * width;
    const cy = params.centerY * height;
    // Ellipse radii per axis; legacy circle masks fall back to `radius`.
    const rx = (params.radiusX > 0 ? params.radiusX : params.radius) * width;
    const ry = (params.radiusY > 0 ? params.radiusY : params.radius) * height;
    const feather = Math.max(0, Math.min(1, params.feather));
    const innerT = 1 - feather;
    const angle = (params.rotation ?? 0) * Math.PI / 180;
    const cosAngle = Math.cos(angle);
    const sinAngle = Math.sin(angle);

    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const deltaX = x - cx;
        const deltaY = y - cy;
        const rotatedX = deltaX * cosAngle + deltaY * sinAngle;
        const rotatedY = -deltaX * sinAngle + deltaY * cosAngle;
        const nx = rotatedX / Math.max(1, rx);
        const ny = rotatedY / Math.max(1, ry);
        const dist = Math.sqrt(nx * nx + ny * ny);
        let alpha: number;
        if (feather <= 0.0001) {
          alpha = dist <= 1 ? 255 : 0;
        } else if (dist <= innerT) {
          alpha = 255;
        } else if (dist >= 1) {
          alpha = 0;
        } else {
          alpha = Math.round(255 * (1 - (dist - innerT) / feather));
        }
        buffer[y * width + x] = alpha;
      }
    }
    return buffer;
  }

  static postProcess(
    buffer: Uint8ClampedArray,
    width: number,
    height: number,
    feather: number,
    invert: boolean,
  ): void {
    const len = buffer.length;

    // Separable sliding-window box blur. The old nested neighbourhood loop was
    // O(width*height*radius²) and made a soft brush mask stall the editor.
    if (feather > 0) {
      const radius = Math.max(1, Math.round(feather * Math.min(width, height) * 0.5));
      const horizontal = new Uint8ClampedArray(buffer.length);
      for (let y = 0; y < height; y++) {
        const row = y * width;
        let sum = 0;
        let count = 0;
        for (let sample = 0; sample <= Math.min(width - 1, radius); sample++) {
          sum += buffer[row + sample];
          count++;
        }
        for (let x = 0; x < width; x++) {
          horizontal[row + x] = Math.round(sum / Math.max(1, count));
          const remove = x - radius;
          const add = x + radius + 1;
          if (remove >= 0) { sum -= buffer[row + remove]; count--; }
          if (add < width) { sum += buffer[row + add]; count++; }
        }
      }
      for (let x = 0; x < width; x++) {
        let sum = 0;
        let count = 0;
        for (let sample = 0; sample <= Math.min(height - 1, radius); sample++) {
          sum += horizontal[sample * width + x];
          count++;
        }
        for (let y = 0; y < height; y++) {
          buffer[y * width + x] = Math.round(sum / Math.max(1, count));
          const remove = y - radius;
          const add = y + radius + 1;
          if (remove >= 0) { sum -= horizontal[remove * width + x]; count--; }
          if (add < height) { sum += horizontal[add * width + x]; count++; }
        }
      }
    }

    // Apply invert
    if (invert) {
      for (let i = 0; i < len; i++) {
        buffer[i] = 255 - buffer[i];
      }
    }
  }
}
