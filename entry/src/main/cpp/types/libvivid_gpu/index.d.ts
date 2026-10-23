/** Asynchronous OpenGL ES preview backend. The returned ArrayBuffer is RGBA8888. */
export interface GpuPreviewOptions {
  /** Special source detail pass: luminance, colour, luminance detail, colour detail. */
  denoise?: number[];
  /** IDs are monotonically allocated for immutable assets, not memory addresses. */
  toneCurveId?: number;
  redCurveId?: number;
  greenCurveId?: number;
  blueCurveId?: number;
  lutId?: number;
  maskId?: number;
  matrix: ArrayBuffer;
  toneCurve: ArrayBuffer;
  redCurve: ArrayBuffer;
  greenCurve: ArrayBuffer;
  blueCurve: ArrayBuffer;
  lut?: ArrayBuffer;
  mask?: ArrayBuffer;
  mixHue: number[];
  mixSaturation: number[];
  mixLuminance: number[];
  tonal?: number[];
  whiteBalanceGain?: number[];
  exposureGain?: number;
  /** amount, midpoint, roundness, feather, highlight protection */
  vignette?: number[];
  /** amount, size, roughness; deterministic native noise texture is cached */
  grain?: number[];
  lutDomainMin?: number[];
  lutDomainScale?: number[];
  whiteBalanceEnabled?: boolean;
  vibrance?: number;
  calibrationHue?: number[];
  calibrationSaturation?: number[];
  mixerEnabled?: boolean;
  maskWidth?: number;
  maskHeight?: number;
  lutEnabled?: boolean;
  lutSize?: number;
  maskEnabled?: boolean;
  maskOpacity?: number;
  opacity?: number;
  blendMode?: number;
  lutIntensity?: number;
  gradingShadowsTarget?: number[];
  gradingMidtonesTarget?: number[];
  gradingHighlightsTarget?: number[];
  gradingGlobalTarget?: number[];
  gradingShadowsSaturation?: number;
  gradingShadowsLuminance?: number;
  gradingMidtonesSaturation?: number;
  gradingMidtonesLuminance?: number;
  gradingHighlightsSaturation?: number;
  gradingHighlightsLuminance?: number;
  gradingGlobalSaturation?: number;
  gradingGlobalLuminance?: number;
  gradingBlending?: number;
  gradingBalance?: number;
  gradingEnabled?: boolean;
}

export interface GpuCapabilities {
  available: boolean;
  renderer: string;
  backend: string;
}

/** Optional virtual-lens stage, executed after colour/mask passes and before
 *  the output geometry matrix. `depth` is one byte per pixel, normalised so
 *  larger = nearer. When `plateOnly` is set the call returns the bounded
 *  background plate instead of compositing it into the source. */
export interface GpuBokehOptions {
  enabled: boolean;
  depth: ArrayBuffer;
  depthWidth: number;
  depthHeight: number;
  /** aperture, blur, bokeh strength, shape, density, size, spherical, focus */
  params: number[];
  /** Whole-frame plate supplied by an export tile; omitted for preview/whole. */
  plate?: ArrayBuffer;
  plateWidth?: number;
  plateHeight?: number;
  plateOnly?: boolean;
  /** Tile-local UV -> whole-frame UV (vertical export strips). */
  uvOffset?: number[];
  uvScale?: number[];
}

/** Final source-coordinate remap after the colour/mask/LUT passes. */
export interface GpuOutputGeometry {
  width: number;
  height: number;
  uvMatrix: ArrayBuffer;
}

export function capabilities(): GpuCapabilities;
export function renderRgba(input: ArrayBuffer, width: number, height: number,
  options: GpuPreviewOptions): Promise<ArrayBuffer>;
export function renderStack(key: string, surfaceId: string, input: ArrayBuffer | null,
  width: number, height: number, sourceVersion: number, passes: GpuPreviewOptions[],
  outputGeometry?: GpuOutputGeometry, bokeh?: GpuBokehOptions): Promise<ArrayBuffer>;
export function releaseSession(key: string): Promise<ArrayBuffer>;
export function clearSurface(key: string, surfaceId: string): Promise<ArrayBuffer>;
