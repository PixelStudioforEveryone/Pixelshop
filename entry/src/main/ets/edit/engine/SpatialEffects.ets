/** Shared spatial effects for TaskPool preview and full-size CPU export. */
export interface SpatialEffectSettings {
  vignetteAmount: number;
  vignetteMidpoint: number;
  vignetteRoundness: number;
  vignetteFeather: number;
  vignetteHighlights: number;
  grainAmount: number;
  grainSize: number;
  grainRoughness: number;
}

function unit(value: number): number {
  return Math.max(0, Math.min(1, value));
}

function smoothStep(edge0: number, edge1: number, value: number): number {
  const t = unit((value - edge0) / Math.max(0.0001, edge1 - edge0));
  return t * t * (3 - 2 * t);
}

function hash(x: number, y: number): number {
  let n = Math.imul(x, 374761393) ^ Math.imul(y, 668265263);
  n = Math.imul(n ^ (n >>> 13), 1274126177);
  return ((n ^ (n >>> 16)) >>> 0) / 4294967295 * 2 - 1;
}

function noise(x: number, y: number): number {
  const ix = Math.floor(x);
  const iy = Math.floor(y);
  const fx = x - ix;
  const fy = y - iy;
  const u = fx * fx * (3 - 2 * fx);
  const v = fy * fy * (3 - 2 * fy);
  const a = hash(ix, iy);
  const b = hash(ix + 1, iy);
  const c = hash(ix, iy + 1);
  const d = hash(ix + 1, iy + 1);
  return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v;
}

export function applySpatialEffects(input: Uint8ClampedArray, index: number,
  adj: SpatialEffectSettings, x: number, y: number, width: number, height: number): void {
  let r = input[index] / 255;
  let g = input[index + 1] / 255;
  let b = input[index + 2] / 255;
  if (adj.vignetteAmount !== 0) {
    // Ellipse at zero; negative roundness approaches a rounded rectangle,
    // positive roundness approaches a circle in physical image coordinates.
    const roundness = Math.max(-1, Math.min(1, adj.vignetteRoundness));
    const nx = Math.abs((x + 0.5) / width * 2 - 1);
    const ny = Math.abs((y + 0.5) / height * 2 - 1);
    const shortSide = Math.min(width, height);
    const sx = nx * (1 + Math.max(0, roundness) * (width / shortSide - 1));
    const sy = ny * (1 + Math.max(0, roundness) * (height / shortSide - 1));
    const power = 2 + Math.max(0, -roundness) * 6;
    const radius = Math.pow(Math.pow(sx, power) + Math.pow(sy, power), 1 / power);
    const outer = 0.35 + unit(adj.vignetteMidpoint) * 0.95;
    const inner = outer * (1 - 0.98 * unit(adj.vignetteFeather));
    const t = unit((radius - inner) / Math.max(0.005, outer - inner));
    const baseStrength = Math.min(1, Math.abs(adj.vignetteAmount)) * t * t * (3 - 2 * t);
    // Preserve bright specular regions as the control promises.  The previous
    // persisted value was never read, so the UI slider had no image effect.
    const luminance = unit(r * 0.2126 + g * 0.7152 + b * 0.0722);
    // Highlight protection applies to darkening, matching this control's
    // documented purpose; it must not silently suppress a bright vignette.
    const highlightProtection = adj.vignetteAmount < 0
      ? unit(adj.vignetteHighlights) * smoothStep(0.52, 0.98, luminance) : 0;
    const strength = baseStrength * (1 - highlightProtection);
    if (adj.vignetteAmount < 0) {
      const gain = Math.pow(2, -3 * strength);
      r *= gain; g *= gain; b *= gain;
    } else {
      r += (1 - r) * strength;
      g += (1 - g) * strength;
      b += (1 - b) * strength;
    }
  }
  if (adj.grainAmount > 0) {
    // Fixed image-relative coordinates keep the pattern stable across preview
    // and export sizes. Smooth interpolation avoids square constant cells.
    const scale = Math.max(width, height) / 1600;
    const cell = (0.8 + unit(adj.grainSize) * 5.2) * scale;
    const gx = (x + 0.5) / cell;
    const gy = (y + 0.5) / cell;
    const roughness = unit(adj.grainRoughness);
    const sample = noise(gx, gy) * (1 - roughness * 0.45) +
      noise(gx * 2.17 + 31.7, gy * 2.17 + 19.3) * roughness * 0.45;
    const luminance = unit(r * 0.2126 + g * 0.7152 + b * 0.0722);
    const amplitude = unit(adj.grainAmount) * 0.22 * (0.3 + 0.7 * Math.sqrt(4 * luminance * (1 - luminance)));
    const delta = sample * amplitude;
    r += delta; g += delta; b += delta;
  }
  input[index] = Math.round(unit(r) * 255);
  input[index + 1] = Math.round(unit(g) * 255);
  input[index + 2] = Math.round(unit(b) * 255);
}
