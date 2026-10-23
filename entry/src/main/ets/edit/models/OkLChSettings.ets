import { OkLChParams, oklchDefaults } from '../engine/OkLChCore';

/** Serializable form. Every field is optional so an older sidecar still opens. */
export interface OkLChValues {
  lightness?: number;
  chroma?: number;
  hue?: number;
}

/** All three parameters are bounded to -1..1; see the panel's slider ranges. */
function unit(value: number, fallback: number): number {
  if (!Number.isFinite(value)) return fallback;
  return value < -1 ? -1 : (value > 1 ? 1 : value);
}

/**
 * The three OkLCh grade parameters as document state.
 *
 * Bypass is delegated to the engine rather than reimplemented, so the model and the
 * render stage can never disagree about when the stage costs nothing: that is exactly the
 * kind of drift that produces a stage which claims to be off but still runs, or claims
 * to be on and silently does nothing.
 */
@Observed
export class OkLChSettings implements OkLChValues {
  public lightness: number = 0;
  public chroma: number = 0;
  public hue: number = 0;

  clone(): OkLChSettings {
    const copy = new OkLChSettings();
    copy.lightness = this.lightness;
    copy.chroma = this.chroma;
    copy.hue = this.hue;
    return copy;
  }

  /** Repairs field by field rather than discarding the whole grade over one bad value. */
  static restore(value?: OkLChValues): OkLChSettings {
    const settings = new OkLChSettings();
    const defaults = oklchDefaults();
    if (!value) return settings;
    settings.lightness = unit(value.lightness as number, defaults.lightness);
    settings.chroma = unit(value.chroma as number, defaults.chroma);
    settings.hue = unit(value.hue as number, defaults.hue);
    return settings;
  }

  /** The engine parameters for the retired stage.
   *
   *  OkLCh has been removed from the UI. The fields are kept so an old sidecar
   *  still imports/exports without loss, but the render stage must be an exact
   *  no-op even when those fields are non-zero. Returning the identity here is
   *  what makes every consumer (worker params, CPU fallback, GPU bypass check)
   *  agree without touching the engine files. */
  params(): OkLChParams {
    return oklchDefaults();
  }

  isBypass(): boolean {
    // 功能已下线：恒为 bypass。保留类与字段只为旧侧车文件能正常读取。
    return true;
  }

  reset(): void {
    const defaults = oklchDefaults();
    this.lightness = defaults.lightness;
    this.chroma = defaults.chroma;
    this.hue = defaults.hue;
  }
}
