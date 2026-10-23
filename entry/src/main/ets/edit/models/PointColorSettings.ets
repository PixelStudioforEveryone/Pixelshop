/**
 * Point colour: a list of sampled colours, each with its own HSL shift and the
 * ranges that decide how far that shift reaches.
 *
 * A colour op applied to the whole frame, document level like denoise, the detail
 * stage and optics. The worker runs it once, after the LUT stack (so it grades the
 * already-graded image, matching the order Camera Raw uses) and before the detail
 * stage (so sharpening and structure act on the final colour rather than being
 * re-graded afterwards).
 *
 * `PointColorSample` is imported from the engine rather than redeclared: two
 * identically shaped but differently named interfaces are NOT interchangeable in an
 * object literal under ArkTS (`arkts-no-untyped-obj-literals`), which already cost
 * this project one failed build. Models importing engine types is an established
 * pattern here (Adjustment.ets and EditSession.ets both do it).
 */
import {
  PointColorSample, MAX_POINT_COLORS, pointColorDefaults, pointColorIsIdentity, rgbToHsl01,
} from '../engine/PointColorCore';

/** Seed for restore. Samples are optional so a pre-Point-Colour sidecar opens clean. */
export interface PointColorValues {
  samples?: PointColorSample[];
}

@Observed
export class PointColorSettings implements PointColorValues {
  public samples: PointColorSample[] = [];
  /**
   * True while the panel is waiting for a tap on the canvas.
   *
   * UI state, deliberately not part of `PointColorValues`/the sidecar: a
   * reopened photo must never come back armed, and the "add colour" button must
   * not add anything until a real pixel has been picked.
   */
  public picking: boolean = false;

  clone(): PointColorSettings {
    return PointColorSettings.restore(this);
  }

  /**
   * Rebuild from a sidecar, dropping anything unusable.
   *
   * A corrupt sample is REPAIRED rather than dropped where possible, because a
   * single bad field (say a NaN range from an older build) should not silently
   * delete a colour the user dialled in. A sample whose identity fields are
   * unusable is dropped, and the list is capped at the engine's maximum.
   */
  static restore(value?: PointColorValues): PointColorSettings {
    const result = new PointColorSettings();
    if (!value || !value.samples) return result;
    const restored: PointColorSample[] = [];
    for (let i = 0; i < value.samples.length; i++) {
      if (restored.length >= MAX_POINT_COLORS) break;
      const sample = value.samples[i];
      if (!sample) continue;
      if (!Number.isFinite(sample.hue) || !Number.isFinite(sample.saturation) ||
        !Number.isFinite(sample.luminance)) continue;
      const item: PointColorSample = pointColorDefaults();
      item.hue = PointColorSettings.unit(sample.hue, 0);
      item.saturation = PointColorSettings.unit(sample.saturation, 0);
      item.luminance = PointColorSettings.unit(sample.luminance, 0);
      item.hueShift = PointColorSettings.signed(sample.hueShift, 0);
      item.saturationShift = PointColorSettings.signed(sample.saturationShift, 0);
      item.luminanceShift = PointColorSettings.signed(sample.luminanceShift, 0);
      item.hueRange = PointColorSettings.unit(sample.hueRange, 30 / 360);
      item.saturationRange = PointColorSettings.unit(sample.saturationRange, 0.4);
      item.luminanceRange = PointColorSettings.unit(sample.luminanceRange, 0.4);
      restored.push(item);
    }
    result.samples = restored;
    return result;
  }

  /** True when the stage is an exact no-op, so the worker can skip the pass.
   *  Delegates to the engine rather than re-deriving the test, so the two cannot
   *  disagree about which sample counts as identity. */
  isBypass(): boolean {
    return this.samples.length === 0 || pointColorIsIdentity(this.samples);
  }

  isFull(): boolean {
    return this.samples.length >= MAX_POINT_COLORS;
  }

  /** Arm the canvas eyedropper. Returns false when the list is already full. */
  beginPick(): boolean {
    if (this.isFull()) return false;
    this.picking = true;
    return true;
  }

  cancelPick(): void {
    this.picking = false;
  }

  /**
   * Add the colour sampled from a real source pixel and leave picking mode.
   *
   * Separate from addHsl so the sample is always tied to a pixel: the old
   * "添加颜色" button called addHsl(0, 0.75, 0.5) and planted a red sample that
   * the user never chose. Nothing in the UI may add a sample any more; it is
   * only reachable through the canvas pick (or a sidecar restore).
   */
  addPickedSample(red: number, green: number, blue: number): boolean {
    const added = this.addSample(red, green, blue);
    this.picking = false;
    return added;
  }

  /** Add a sample from an 8-bit colour. Returns false when the list is full. */
  addSample(red: number, green: number, blue: number): boolean {
    const hsl = rgbToHsl01(PointColorSettings.unit(red / 255, 0),
      PointColorSettings.unit(green / 255, 0), PointColorSettings.unit(blue / 255, 0));
    return this.addHsl(hsl[0], hsl[1], hsl[2]);
  }

  /** Add a sample from HSL directly, which is what the panel's controls drive. */
  addHsl(hue: number, saturation: number, luminance: number): boolean {
    if (this.isFull()) return false;
    const item: PointColorSample = pointColorDefaults();
    item.hue = PointColorSettings.unit(hue, 0);
    item.saturation = PointColorSettings.unit(saturation, 0);
    item.luminance = PointColorSettings.unit(luminance, 0);
    this.samples = this.samples.concat([item]);
    return true;
  }

  removeAt(index: number): void {
    if (index < 0 || index >= this.samples.length) return;
    // Deleting while the canvas is armed must not leave the user stuck in a
    // mode whose button no longer corresponds to the list they are editing.
    this.picking = false;
    const kept: PointColorSample[] = [];
    for (let i = 0; i < this.samples.length; i++) {
      if (i !== index) kept.push(this.samples[i]);
    }
    this.samples = kept;
  }

  clear(): void {
    this.picking = false;
    this.samples = [];
  }

  private static unit(value: number, fallback: number): number {
    return Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : fallback;
  }

  private static signed(value: number, fallback: number): number {
    return Number.isFinite(value) ? Math.max(-1, Math.min(1, value)) : fallback;
  }
}
