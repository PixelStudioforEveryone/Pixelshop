import { DenoiseValues } from '../models/DenoiseSettings';
import { taskpool } from '@kit.ArkTS';

export function denoiseEnabled(settings?: DenoiseValues): boolean {
  return settings !== undefined && (settings.luminance > 0 || settings.color > 0);
}

/** Long edge of the frame the denoise sliders are authored against. The editor
 * previews at 1280..2048 px (EditorPage.previewMaxDimension clamps to 2048) and
 * exports at the full sensor resolution, so the export frame is typically 2-6x
 * larger than the preview the settings were tuned on. */
export const DENOISE_REFERENCE_LONG_EDGE: number = 2048;
/** Hard cap on the spatial radius: 11x11 taps bound the per-pixel cost of both
 * the CPU worker and the GLES2 fragment shader. The GLES2 loops in
 * vivid_gpu.cpp use the same two constants; keep them in sync. */
export const DENOISE_MAX_RADIUS: number = 5;

/**
 * Spatial radius, in pixels of the frame being filtered.
 *
 * The spatial weight of this filter is a Gaussian expressed in *pixels*, while
 * its range weights are scale-free log-luminance ratios. With a fixed 5x5
 * window a 2048px preview therefore covers ~3x more of the scene than the
 * 6000px export it is supposed to predict: measured on synthetic Gaussian noise
 * the preview residual is ~1.9x cleaner (std) than the same export downsampled
 * to the preview size, i.e. the preview systematically under-reports noise and
 * over-smooths fine texture. Scaling the radius with the frame long edge keeps
 * the spatial footprint constant in scene units, which is the condition for the
 * filter to commute with the preview/export resolution change.
 *
 * Frames at or below the reference keep today's radius 2, so the interactive
 * and full preview renders stay bit-identical and cost nothing extra; only
 * exports larger than the preview grow a wider window.
 *
 * `fixedRadius` exists for process version LEGACY (see models/ProcessVersion.ets):
 * a photo saved before this rule changed replays with radius 2 at every frame
 * size, so its stored look does not drift. 0 — the default — means "use the
 * frame-relative rule", which is what CURRENT and every fresh edit resolve to.
 *
 * Known residual: the radius follows the *buffer* being filtered. The loupe
 * (EditorPage's detail tile) renders a 1:1 crop of the full-resolution source,
 * so that buffer is small while its pixels are source pixels, and it keeps
 * radius 2 while the export of the same photo uses the wider window. Making the
 * loupe track the export at 100% needs the frame extent threaded here as well
 * (the tile's source-per-buffer scale lives in session.renderViewport) *and*
 * the halo in EditorPage raised from `Math.ceil(2 / scale) + 1` to the actual
 * radius, otherwise the tile would clamp at its own padding. The halo file is
 * out of scope for this change, so the loupe is deliberately left untouched. */
export function denoiseSpatialRadius(width: number, height: number, fixedRadius: number = 0): number {
  // Process version LEGACY pins the radius to the constant this filter used
  // before the frame-relative rule existed. The pin is resolved from
  // ProcessBehaviors.denoiseFixedRadius, never from a version number here.
  if (fixedRadius > 0) {
    return Math.max(2, Math.min(DENOISE_MAX_RADIUS, Math.round(fixedRadius)));
  }
  const longEdge = Math.max(1, Math.max(width, height));
  const scaled = Math.round(2 * longEdge / DENOISE_REFERENCE_LONG_EDGE);
  return Math.max(2, Math.min(DENOISE_MAX_RADIUS, scaled));
}

/** Edge-aware log-luminance and linear chromaticity, following lightcraft's
 * separation of luminance/chroma. A bounded bilateral kernel replaces its
 * full-plane guided/Gaussian filters so GLES2 and CPU use identical semantics.
 * Source and destination must be independent; all neighbourhoods read source.
 * Only the rows of the current window are resident, rather than full float
 * image planes. */
/**
 * log2-luminance variation at which Luminance Contrast treats a pixel as
 * structure rather than noise. 0.1 log2 units is about a 7% luminance step:
 * comfortably above sensor noise in a midtone, well below a visible edge.
 */
const LUMA_STRUCTURE_FLOOR: number = 0.1;

export function denoiseRows(source: Uint8ClampedArray, output: Uint8ClampedArray,
  width: number, height: number, settings: DenoiseValues, first: number, end: number,
  checkCancellation: boolean = false, fixedRadius: number = 0): void {
  if (source.buffer === output.buffer) throw new Error('Denoise requires immutable neighbourhoods');
  const lum = Math.max(0, Math.min(1, settings.luminance));
  const color = Math.max(0, Math.min(1, settings.color));
  // Identity at zero. The filter below decodes sRGB, filters in linear light and
  // re-encodes, and that round trip is only *empirically* lossless (it held for
  // every grey level and for thousands of random colours, but nothing in the
  // arithmetic guarantees it). A zero-strength stage must be a provable
  // pass-through, so copy the requested rows instead of filtering them.
  if (lum === 0 && color === 0) {
    for (let y = first; y < end; y++) {
      const start = y * width * 4;
      output.set(source.subarray(start, start + width * 4), start);
    }
    return;
  }
  const sigmaL = 0.08 + 0.55 * lum * (1 - 0.8 * settings.detail);
  const sigmaC = 0.1 + 0.65 * color * (1 - 0.8 * settings.colorDetail);
  // The chroma result is only used through this mix factor: when it is exactly
  // zero (colour noise reduction off) the chroma accumulation cannot influence
  // the output, and the same holds for the luminance accumulation at lum = 0.
  const channelMix = color * (1 - 0.5 * settings.colorDetail);
  const smoothLuminance = lum > 0;
  const smoothChroma = channelMix !== 0;
  // Luminance Contrast and Color Smoothness are read defensively. A caller built
  // before they existed, an old sidecar, or the literal settings objects used by
  // the existing suites leave them undefined; both must then behave as their
  // no-op default so every previously published frame stays byte-identical.
  const luminanceContrast = Number.isFinite(settings.luminanceContrast)
    ? Math.max(-1, Math.min(1, settings.luminanceContrast as number)) : 0;
  const colorSmoothness = Number.isFinite(settings.colorSmoothness)
    ? Math.max(0, Math.min(1, settings.colorSmoothness as number)) : 0.5;
  const radius = denoiseSpatialRadius(width, height, fixedRadius);
  const sigmaS = radius / 2;
  const span = 2 * radius + 1;
  const linear = new Float32Array(256);
  for (let i = 0; i < 256; i++) {
    const v = i / 255;
    linear[i] = v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  }
  // Same spatial Gaussian the GLES2 pass evaluates: exp(-0.5*d2/(sigmaS*sigmaS)).
  const spatial = new Float32Array(span * span);
  let slotIndex = 0;
  for (let y = -radius; y <= radius; y++) {
    for (let x = -radius; x <= radius; x++) {
      spatial[slotIndex++] = Math.exp(-0.5 * (x * x + y * y) / (sigmaS * sigmaS));
    }
  }
  // Color Smoothness widens (or narrows) the spatial kernel used for CHROMA
  // ONLY, which is what the control means: how far colour is averaged, leaving
  // the luminance kernel alone. The scale is exactly 1 at the 0.5 default, so a
  // session that never touched the control reuses the same array and produces
  // the same bytes.
  const chromaSpatialScale = 1 + 0.8 * (colorSmoothness - 0.5);
  let spatialChroma = spatial;
  if (smoothChroma && chromaSpatialScale !== 1) {
    const sigmaChroma = Math.max(0.35, sigmaS * chromaSpatialScale);
    spatialChroma = new Float32Array(span * span);
    let chromaSlot = 0;
    for (let y = -radius; y <= radius; y++) {
      for (let x = -radius; x <= radius; x++) {
        spatialChroma[chromaSlot++] = Math.exp(-0.5 * (x * x + y * y) / (sigmaChroma * sigmaChroma));
      }
    }
  }
  const rows: Float32Array[] = [];
  const rowIds: number[] = [];
  for (let i = 0; i < span; i++) { rows.push(new Float32Array(width * 4)); rowIds.push(-1); }
  for (let y = first; y < end; y++) {
    if (checkCancellation && (y & 31) === 0 && taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
    for (let oy = -radius; oy <= radius; oy++) {
      const sy = Math.max(0, Math.min(height - 1, y + oy));
      const slot = sy % span;
      if (rowIds[slot] === sy) continue;
      const row = rows[slot];
      for (let x = 0; x < width; x++) {
        const p = (sy * width + x) * 4, q = x * 4;
        const r = linear[source[p]], g = linear[source[p + 1]], b = linear[source[p + 2]];
        const light = Math.max(0.00001, r * 0.2126 + g * 0.7152 + b * 0.0722);
        row[q] = r / light; row[q + 1] = g / light; row[q + 2] = b / light;
        row[q + 3] = Math.log2(light);
      }
      rowIds[slot] = sy;
    }
    const center = rows[y % span];
    for (let x = 0; x < width; x++) {
      const q = x * 4, logY = center[q + 3];
      let sumL = 0, weightL = 0, sumR = 0, sumG = 0, sumB = 0, weightC = 0;
      let k = 0;
      for (let oy = -radius; oy <= radius; oy++) {
        const row = rows[Math.max(0, Math.min(height - 1, y + oy)) % span];
        for (let ox = -radius; ox <= radius; ox++, k++) {
          const j = Math.max(0, Math.min(width - 1, x + ox)) * 4;
          const delta = row[j + 3] - logY;
          const spatialWeight = spatial[k];
          if (smoothLuminance) {
            const dl = delta / sigmaL;
            const wl = spatialWeight / (1 + dl * dl);
            sumL += row[j + 3] * wl; weightL += wl;
          }
          if (smoothChroma) {
            const dc = delta / sigmaC;
            const wc = spatialChroma[k] / (1 + dc * dc);
            sumR += row[j] * wc; sumG += row[j + 1] * wc; sumB += row[j + 2] * wc; weightC += wc;
          }
        }
      }
      // A disabled luminance pass keeps the previous 2^log2(light) expression so
      // frames published before this change stay bit-identical; a disabled
      // chroma pass keeps the centre chroma, which is exactly what mix = 0
      // produced.
      // Luminance Contrast re-introduces a fraction of the local luminance
      // variation the denoiser just removed — but only in proportion to how much
      // variation there is, because a small variation is noise and re-adding it
      // would undo the denoising, whereas a large one is structure. At contrast 0
      // (and whenever the luminance pass is off) the expression below reduces
      // EXACTLY to the previous one, so no existing render moves.
      let blendedLog = logY;
      if (smoothLuminance) {
        const smoothed = sumL / weightL;
        const variation = logY - smoothed;
        blendedLog = logY + (smoothed - logY) * Math.sqrt(lum);
        if (luminanceContrast !== 0) {
          const structure = Math.min(1, Math.abs(variation) / LUMA_STRUCTURE_FLOOR);
          blendedLog += variation * luminanceContrast * structure;
        }
      }
      const newY = Math.pow(2, blendedLog);
      const r = smoothChroma ? center[q] + (sumR / weightC - center[q]) * channelMix : center[q];
      const g = smoothChroma ? center[q + 1] + (sumG / weightC - center[q + 1]) * channelMix : center[q + 1];
      const b = smoothChroma ? center[q + 2] + (sumB / weightC - center[q + 2]) * channelMix : center[q + 2];
      const gain = newY / Math.max(0.00001, r * 0.2126 + g * 0.7152 + b * 0.0722);
      const p = (y * width + x) * 4;
      output[p] = encode(r * gain); output[p + 1] = encode(g * gain); output[p + 2] = encode(b * gain);
      output[p + 3] = source[p + 3];
    }
  }
}

function encode(value: number): number {
  const v = Math.max(0, Math.min(1, value));
  return Math.round(255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055));
}
