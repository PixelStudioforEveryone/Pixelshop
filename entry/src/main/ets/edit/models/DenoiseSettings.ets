export interface DenoiseValues {
  luminance: number;
  color: number;
  detail: number;
  colorDetail: number;
  /** Luminance Contrast, -1..1, default 0. Re-introduces the local luminance
   *  variation the denoiser removed, so it trades noise for micro-contrast. */
  luminanceContrast?: number;
  /** Color Smoothness, 0..1, default 0.5. Widens or narrows the spatial kernel
   *  used for chroma only, so it sets how far colour is averaged. */
  colorSmoothness?: number;
}

/** Global, pre-colour detail stage. Old sidecars restore to an exact bypass. */
@Observed
export class DenoiseSettings implements DenoiseValues {
  public luminance: number = 0;
  public color: number = 0;
  public detail: number = 0.5;
  public colorDetail: number = 0.5;
  public luminanceContrast: number = 0;
  public colorSmoothness: number = 0.5;

  clone(): DenoiseSettings {
    return DenoiseSettings.restore(this);
  }

  static restore(value?: DenoiseValues): DenoiseSettings {
    const result = new DenoiseSettings();
    if (value) {
      result.luminance = DenoiseSettings.unit(value.luminance, 0);
      result.color = DenoiseSettings.unit(value.color, 0);
      result.detail = DenoiseSettings.unit(value.detail, 0.5);
      result.colorDetail = DenoiseSettings.unit(value.colorDetail, 0.5);
      // Defaults are the NO-OP values of each control, not its centre in some
      // abstract sense: contrast 0 and smoothness 0.5 both reproduce the
      // renderer's previous behaviour exactly, so a photo saved before these two
      // controls existed reopens byte-identical.
      result.luminanceContrast = DenoiseSettings.signed(value.luminanceContrast, 0);
      result.colorSmoothness = DenoiseSettings.unit(value.colorSmoothness, 0.5);
    }
    return result;
  }

  private static unit(value: number | undefined, fallback: number): number {
    return Number.isFinite(value) ? Math.max(0, Math.min(1, value as number)) : fallback;
  }

  private static signed(value: number | undefined, fallback: number): number {
    return Number.isFinite(value) ? Math.max(-1, Math.min(1, value as number)) : fallback;
  }
}
