/**
 * Global detail stage: texture, clarity, dehaze and sharpening.
 *
 * Like denoise this is a document-level spatial stage rather than a per-layer
 * colour control, because every one of its four effects is a neighbourhood
 * operation. The worker applies it once to the composed frame, after the LUT
 * stack and before geometry, so a band-local blur can never disagree with a
 * full-frame one.
 *
 * Ranges match LocalContrastParams: texture/clarity/dehaze are signed (-1..1)
 * because each has a meaningful inverse (soften / flatten / add haze), while the
 * three sharpening controls are unsigned (0..1).
 */
export interface DetailValues {
  texture: number;
  clarity: number;
  dehaze: number;
  sharpenAmount: number;
  sharpenRadius: number;
  sharpenDetail: number;
  sharpenMasking: number;
}

/** Old sidecars restore to an exact bypass, never to a mid-strength look. */
@Observed
export class DetailSettings implements DetailValues {
  public texture: number = 0;
  public clarity: number = 0;
  public dehaze: number = 0;
  public sharpenAmount: number = 0;
  public sharpenRadius: number = 0;
  public sharpenDetail: number = 0.25;
  public sharpenMasking: number = 0;

  clone(): DetailSettings {
    return DetailSettings.restore(this);
  }

  static restore(value?: DetailValues): DetailSettings {
    const result = new DetailSettings();
    if (value) {
      result.texture = DetailSettings.signed(value.texture, 0);
      result.clarity = DetailSettings.signed(value.clarity, 0);
      result.dehaze = DetailSettings.signed(value.dehaze, 0);
      result.sharpenAmount = DetailSettings.unit(value.sharpenAmount, 0);
      result.sharpenRadius = DetailSettings.unit(value.sharpenRadius, 0);
      result.sharpenDetail = DetailSettings.unit(value.sharpenDetail, 0.25);
      result.sharpenMasking = DetailSettings.unit(value.sharpenMasking, 0);
    }
    return result;
  }

  /**
   * True when the stage is an exact no-op.
   *
   * Mirrors `localContrastIsIdentity`, including its deliberate asymmetry:
   * radius, detail and masking only shape how much sharpening is applied, so on
   * their own — with the amount at zero — they change nothing and must not cost
   * a pass. The engine module remains the authority; this exists so the UI and
   * the settings model can ask the question without importing the engine.
   */
  isBypass(): boolean {
    return DetailSettings.zero(this.texture) && DetailSettings.zero(this.clarity) &&
      DetailSettings.zero(this.dehaze) && DetailSettings.zero(this.sharpenAmount);
  }

  private static zero(value: number): boolean {
    return !Number.isFinite(value) || Math.abs(value) < 1e-12;
  }

  private static unit(value: number, fallback: number): number {
    return Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : fallback;
  }

  private static signed(value: number, fallback: number): number {
    return Number.isFinite(value) ? Math.max(-1, Math.min(1, value)) : fallback;
  }
}
