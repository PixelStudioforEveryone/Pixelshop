import {
  BlackWhiteParams, BW_BAND_COUNT, BW_BAND_NAMES, blackWhiteDefaults, blackWhiteIsIdentity,
  blackWhiteNormalize,
} from '../engine/BlackWhiteCore';

/** Serializable form. Both fields are optional so an older sidecar still opens. */
export interface BlackWhiteValues {
  enabled?: boolean;
  mixers?: number[];
}

/**
 * The black-and-white mixer as document state: an on/off switch plus eight band weights.
 *
 * The eight weights are stored as a plain array rather than eight named fields because
 * the band list lives in the engine (`BW_BAND_NAMES`), and duplicating it here is exactly
 * how a UI ends up with a slider whose band the engine does not have. Repair and clamping
 * are delegated to `blackWhiteNormalize` for the same reason.
 */
@Observed
export class BlackWhiteSettings implements BlackWhiteValues {
  public enabled: boolean = false;
  public mixers: number[] = blackWhiteDefaults().mixers;

  clone(): BlackWhiteSettings {
    const copy = new BlackWhiteSettings();
    copy.enabled = this.enabled;
    copy.mixers = this.mixers.slice();
    return copy;
  }

  /** Repairs rather than discards: a bad weight costs that band, not the conversion. */
  static restore(value?: BlackWhiteValues): BlackWhiteSettings {
    const settings = new BlackWhiteSettings();
    if (!value) return settings;
    settings.enabled = !!value.enabled;
    settings.mixers = blackWhiteNormalize({
      enabled: settings.enabled,
      mixers: value.mixers as number[],
    }).mixers;
    return settings;
  }

  /** The engine parameters with no conversion: the model stores the engine's own shape. */
  params(): BlackWhiteParams {
    const p: BlackWhiteParams = { enabled: this.enabled, mixers: this.mixers };
    return p;
  }

  isBypass(): boolean {
    return blackWhiteIsIdentity(this.params());
  }

  bandCount(): number {
    return BW_BAND_COUNT;
  }

  bandName(index: number): string {
    return index >= 0 && index < BW_BAND_NAMES.length ? BW_BAND_NAMES[index] : '';
  }

  /** Bounded and finite by construction, so a slider cannot store a bad weight. */
  setBand(index: number, value: number): void {
    if (index < 0 || index >= BW_BAND_COUNT) return;
    const safe: number = Number.isFinite(value) ? value : 0;
    this.mixers[index] = safe < -1 ? -1 : (safe > 1 ? 1 : safe);
  }

  reset(): void {
    this.enabled = false;
    this.mixers = blackWhiteDefaults().mixers;
  }
}
