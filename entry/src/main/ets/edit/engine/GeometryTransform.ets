import {
  GeometryCoefficients,
  GeometryDims,
  GeometryMap,
  buildGeometryMap,
  buildGeometryMapFromCoefficients,
  displayToFrame,
  displayToSource,
  frameToDisplay,
  frameToSource,
  frameToSourceNormalized,
  geometryCoefficients,
  geometryCoefficientsFor,
  geometryIsActive,
  sourceToDisplay,
  sourceToFrame,
} from './GeometryMath';

export {
  GeometryCoefficients, GeometryDims, GeometryMap,
  buildGeometryMap, buildGeometryMapFromCoefficients,
  displayToFrame, displayToSource, frameToDisplay, frameToSource,
  frameToSourceNormalized, geometryCoefficients, geometryCoefficientsFor, sourceToDisplay,
  sourceToFrame,
};

/** Inverse projective sampling shared by TaskPool preview and export. The
 * coefficients themselves live in GeometryMath so the overlay, touch input,
 * masks and retouch marks invert exactly the same transform. */
export function geometryActive(g: number[] | undefined): boolean {
  return geometryIsActive(g);
}

/** The session-shaped entry point: builds the frame/display map once per frame
 * and keeps a single implementation of the projection. `imageWidth/Height` are
 * the source dimensions the control values were authored against; the crop and
 * rotation operate on the buffer the geometry pass receives. */
export function geometryMapFor(imageWidth: number, imageHeight: number,
  g: number[] | undefined, crop: number[], rotation: number, flipH: boolean, flipV: boolean,
  renderWidth: number = 0, renderHeight: number = 0): GeometryMap {
  const width = Math.max(1, Math.round(imageWidth));
  const height = Math.max(1, Math.round(imageHeight));
  const targetWidth = renderWidth > 0 ? Math.max(1, Math.round(renderWidth)) : width;
  const targetHeight = renderHeight > 0 ? Math.max(1, Math.round(renderHeight)) : height;
  const dims: GeometryDims = {
    width: targetWidth, height: targetHeight,
    cropLeft: crop[0], cropTop: crop[1], cropRight: crop[2], cropBottom: crop[3],
    rotation: rotation, flipH: flipH, flipV: flipV,
  };
  return buildGeometryMap(g, targetWidth, targetHeight, dims, {
    referenceWidth: width, referenceHeight: height,
  });
}

export function transformGeometry(src: Uint8ClampedArray, w: number, h: number, g: number[] | undefined,
  referenceWidth: number = 0, referenceHeight: number = 0): Uint8ClampedArray {
  if (!g || !geometryActive(g)) return src;
  const coef = geometryCoefficientsFor(g, {
    renderWidth: w, renderHeight: h,
    referenceWidth: referenceWidth > 0 ? referenceWidth : w,
    referenceHeight: referenceHeight > 0 ? referenceHeight : h,
  });
  const map = buildGeometryMapFromCoefficients(coef, w, h, {
    width: w, height: h, cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
    rotation: 0, flipH: false, flipV: false,
  });
  const out = new Uint8ClampedArray(src.length);
  const clampX = w - 1;
  const clampY = h - 1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const sample = frameToSource(map, x, y);
      if (!sample) continue;
      const sx = sample[0];
      const sy = sample[1];
      const ix = Math.floor(sx);
      const iy = Math.floor(sy);
      const fx = sx - ix;
      const fy = sy - iy;
      const p = (iy * w + ix) * 4;
      const q = (iy * w + Math.min(clampX, ix + 1)) * 4;
      const r = (Math.min(clampY, iy + 1) * w + ix) * 4;
      const t = (Math.min(clampY, iy + 1) * w + Math.min(clampX, ix + 1)) * 4;
      const dest = (y * w + x) * 4;
      for (let ch = 0; ch < 4; ch++) {
        out[dest + ch] = (src[p + ch] * (1 - fx) + src[q + ch] * fx) * (1 - fy) +
          (src[r + ch] * (1 - fx) + src[t + ch] * fx) * fy;
      }
    }
  }
  return out;
}
