/**
 * Global optics stage: lens corrections.
 *
 * Document-level like denoise and the detail stage, and for the same reason:
 * every one of these corrections is a full-frame operation. Distortion and
 * chromatic aberration resample the whole image, and vignetting is a radial gain
 * over the whole frame. The worker applies the stage once, after the LUT and
 * detail stages and immediately before geometry — before geometry because the
 * correction is a property of the capture, and after the layer/mask stages
 * because masks and retouch marks are authored in source space and must travel
 * WITH the content they select rather than be distorted away from it.
 *
 * Ranges mirror OpticsParams: distortion, vignette amount and chromatic
 * aberration are signed (-1..1) because each has a meaningful inverse, while the
 * two defringe amounts and the vignette midpoint are unsigned (0..1).
 */
export interface OpticsValues {
  distortion: number;
  vignetteAmount: number;
  vignetteMidpoint: number;
  chromaticAberration: number;
  defringePurple: number;
  defringeGreen: number;
}

/** Old sidecars restore to an exact bypass, never to a mid-strength look. */
@Observed
export class OpticsSettings implements OpticsValues {
  public distortion: number = 0;
  public vignetteAmount: number = 0;
  public vignetteMidpoint: number = 0.5;
  public chromaticAberration: number = 0;
  public defringePurple: number = 0;
  public defringeGreen: number = 0;

  clone(): OpticsSettings {
    return OpticsSettings.restore(this);
  }

  static restore(value?: OpticsValues): OpticsSettings {
    const result = new OpticsSettings();
    if (value) {
      result.distortion = OpticsSettings.signed(value.distortion, 0);
      result.vignetteAmount = OpticsSettings.signed(value.vignetteAmount, 0);
      result.vignetteMidpoint = OpticsSettings.unit(value.vignetteMidpoint, 0.5);
      result.chromaticAberration = OpticsSettings.signed(value.chromaticAberration, 0);
      result.defringePurple = OpticsSettings.unit(value.defringePurple, 0);
      result.defringeGreen = OpticsSettings.unit(value.defringeGreen, 0);
    }
    return result;
  }

  /**
   * True when the stage is an exact no-op.
   *
   * Mirrors `opticsIsIdentity`, including its deliberate asymmetry: the vignette
   * MIDPOINT only shapes where the falloff happens, so with the depth at zero it
   * changes nothing and must not cost a pass. The engine module remains the
   * authority; this exists so the UI and the settings model can ask the question
   * without importing the engine. The two are pinned against each other by
   * check_optics_integration.cjs.
   */
  isBypass(): boolean {
    return OpticsSettings.zero(this.distortion) && OpticsSettings.zero(this.vignetteAmount) &&
      OpticsSettings.zero(this.chromaticAberration) && OpticsSettings.zero(this.defringePurple) &&
      OpticsSettings.zero(this.defringeGreen);
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
