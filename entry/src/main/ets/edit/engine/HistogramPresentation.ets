/** Display-only preparation matching Lightcraft: five-bin smoothing, shared RGB
 * peak excluding endpoint spikes, square-root height, and neutral RGB detection. */
export interface HistogramPlot {
  red: number[];
  green: number[];
  blue: number[];
  luminance: number[];
  peak: number;
  monochrome: boolean;
}
function smoothBins(bins: Uint32Array): number[] {
  const out: number[] = [];
  for (let i = 0; i < 256; i++) {
    const first = Math.max(0, i - 2), last = Math.min(256, i + 3);
    let sum = 0;
    for (let j = first; j < last; j++) sum += bins[j] ?? 0;
    out.push(sum / (last - first));
  }
  return out;
}
export function histogramPlot(red: Uint32Array, green: Uint32Array, blue: Uint32Array,
  luminance: Uint32Array): HistogramPlot {
  const r = smoothBins(red), g = smoothBins(green), b = smoothBins(blue);
  let peak = 1, spread = 0, total = 0;
  for (let i = 0; i < 256; i++) {
    if (i >= 2 && i < 254) peak = Math.max(peak, r[i], g[i], b[i]);
    spread += Math.abs(r[i] - g[i]) + Math.abs(g[i] - b[i]); total += g[i];
  }
  return { red: r, green: g, blue: b, luminance: smoothBins(luminance), peak,
    monochrome: spread / Math.max(1, total) < 0.02 };
}
export function histogramHeight(value: number, peak: number): number {
  return Math.sqrt(Math.max(0, Math.min(1, value / Math.max(1, peak))));
}
// Lightroom-style interaction added to VIVID. Lightcraft v0.6.0 only toggles
// clipping on plot click. Regions drive the existing adjustment semantics.
export function histogramToneIndex(x: number, width: number): number {
  if (!Number.isFinite(x) || !Number.isFinite(width) || width <= 0) return -1;
  return Math.max(0, Math.min(4, Math.floor(x / width * 5)));
}
export function histogramToneKey(index: number): string {
  return ['blacks', 'shadows', 'exposure', 'highlights', 'whites'][index] ?? '';
}
export function histogramDragValue(base: number, deltaX: number, width: number): number {
  if (!Number.isFinite(base) || !Number.isFinite(deltaX) || !Number.isFinite(width) || width <= 0) return base;
  return Math.max(-1, Math.min(1, base + deltaX / width * 2));
}
