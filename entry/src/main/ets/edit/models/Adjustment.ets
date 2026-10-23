import { SpatialEffectSettings } from '../engine/SpatialEffects';
/**
 * Color adjustment parameters — all values normalized to [-1, +1] for UI sliders,
 * except hue which uses degrees [-180, +180].
 * Effective ranges are applied in ColorMatrixBuilder.
 */
@Observed
export class CurveAnchor {
  public x: number = 0;
  public y: number = 0;

  constructor(x: number = 0, y: number = 0) {
    this.x = Math.max(0, Math.min(1, x));
    this.y = Math.max(0, Math.min(1, y));
  }

  clone(): CurveAnchor {
    return new CurveAnchor(this.x, this.y);
  }
}

@Observed
export class ColorAdjustments implements SpatialEffectSettings {
  // Light (Tone)
  public exposure: number = 0;
  public contrast: number = 0;
  public brightness: number = 0;
  public highlights: number = 0;
  public shadows: number = 0;
  public whites: number = 0;
  public blacks: number = 0;

  // Effects: Lightroom-style vignette and film grain.
  public vignetteAmount: number = 0;
  public vignetteMidpoint: number = 0.5;
  public vignetteRoundness: number = 0;
  public vignetteFeather: number = 0.8;
  public vignetteHighlights: number = 0;
  public grainAmount: number = 0;
  public grainSize: number = 0.5;
  public grainRoughness: number = 0.5;

  // Color
  public saturation: number = 0;
  public vibrance: number = 0;
  public temperature: number = 0;
  public tint: number = 0;
  public hue: number = 0;

  // Tone curve. The master curve uses an S-curve while RGB curves use
  // per-channel gamma, matching the four-channel workflow in Lightroom.
  public toneCurve: number = 0;
  public curveRed: number = 0;
  public curveGreen: number = 0;
  public curveBlue: number = 0;

  // Editable point curves. End points stay pinned to the black/white corners;
  // interior anchors are created and moved directly on the curve graph.
  public toneCurvePoints: CurveAnchor[] = ColorAdjustments.defaultCurve();
  public redCurvePoints: CurveAnchor[] = ColorAdjustments.defaultCurve();
  public greenCurvePoints: CurveAnchor[] = ColorAdjustments.defaultCurve();
  public blueCurvePoints: CurveAnchor[] = ColorAdjustments.defaultCurve();

  // Parametric tone curve: four region amounts plus three draggable split
  // points and a saturation refinement, as in Camera Raw's Tone Curve panel.
  // Amounts are normalized to [-1, 1]; splits and refinement to [0, 1].
  // Split defaults match Camera Raw (25 / 50 / 75 percent).
  public parametricHighlights: number = 0;
  public parametricLights: number = 0;
  public parametricDarks: number = 0;
  public parametricShadows: number = 0;
  public parametricShadowSplit: number = 0.25;
  public parametricDarkSplit: number = 0.5;
  public parametricLightSplit: number = 0.75;
  public parametricRefineSaturation: number = 1;

  // Eight-channel HSL mixer: red, orange, yellow, green, aqua, blue,
  // purple and magenta. Values are normalized to [-1, 1].
  public mixHue: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
  public mixSaturation: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
  public mixLuminance: number[] = [0, 0, 0, 0, 0, 0, 0, 0];

  // Camera calibration / primary-color controls.
  public calibrationRedHue: number = 0;
  public calibrationRedSaturation: number = 0;
  public calibrationGreenHue: number = 0;
  public calibrationGreenSaturation: number = 0;
  public calibrationBlueHue: number = 0;
  public calibrationBlueSaturation: number = 0;

  // Lightroom-style color grading. Hue is stored in degrees [0..360],
  // saturation in [0..1], and luminance/mix/balance in [-1..1].
  public colorGradingEnabled: boolean = true;
  public gradingShadowsHue: number = 0;
  public gradingShadowsSaturation: number = 0;
  public gradingShadowsLuminance: number = 0;
  public gradingMidtonesHue: number = 0;
  public gradingMidtonesSaturation: number = 0;
  public gradingMidtonesLuminance: number = 0;
  public gradingHighlightsHue: number = 0;
  public gradingHighlightsSaturation: number = 0;
  public gradingHighlightsLuminance: number = 0;
  public gradingGlobalHue: number = 0;
  public gradingGlobalSaturation: number = 0;
  public gradingGlobalLuminance: number = 0;
  public gradingBlending: number = 0;
  public gradingBalance: number = 0;

  static defaultCurve(): CurveAnchor[] {
    // Interior anchors are added by the user; a fresh curve has only its endpoints.
    return [
      new CurveAnchor(0, 0),
      new CurveAnchor(1, 1),
    ];
  }

  /** Only sidecar import calls this; undo must preserve newly added neutral points. */
  migrateLegacyDefaultCurves(): void {
    for (let channel = 0; channel < 4; channel++) {
      const points = this.getCurvePoints(channel);
      if (points.length !== 3 && points.length !== 5) continue;
      const legacyDefault = points.every((point: CurveAnchor, index: number): boolean =>
        Math.abs(point.x - index / (points.length - 1)) < 1e-9 &&
        Math.abs(point.y - point.x) < 1e-9);
      if (legacyDefault) this.setCurvePoints(channel, ColorAdjustments.defaultCurve());
    }
  }

  clone(): ColorAdjustments {
    const c = new ColorAdjustments();
    c.exposure = this.exposure;
    c.contrast = this.contrast;
    c.brightness = this.brightness;
    c.highlights = this.highlights;
    c.shadows = this.shadows;
    c.whites = this.whites;
    c.blacks = this.blacks;
    c.vignetteAmount = this.vignetteAmount;
    c.vignetteMidpoint = this.vignetteMidpoint;
    c.vignetteRoundness = this.vignetteRoundness;
    c.vignetteFeather = this.vignetteFeather;
    c.vignetteHighlights = this.vignetteHighlights;
    c.grainAmount = this.grainAmount;
    c.grainSize = this.grainSize;
    c.grainRoughness = this.grainRoughness;
    c.saturation = this.saturation;
    c.vibrance = this.vibrance;
    c.temperature = this.temperature;
    c.tint = this.tint;
    c.hue = this.hue;
    c.toneCurve = this.toneCurve;
    c.curveRed = this.curveRed;
    c.curveGreen = this.curveGreen;
    c.curveBlue = this.curveBlue;
    c.toneCurvePoints = this.toneCurvePoints.map((point: CurveAnchor) => point.clone());
    c.redCurvePoints = this.redCurvePoints.map((point: CurveAnchor) => point.clone());
    c.greenCurvePoints = this.greenCurvePoints.map((point: CurveAnchor) => point.clone());
    c.blueCurvePoints = this.blueCurvePoints.map((point: CurveAnchor) => point.clone());
    c.parametricHighlights = this.parametricHighlights;
    c.parametricLights = this.parametricLights;
    c.parametricDarks = this.parametricDarks;
    c.parametricShadows = this.parametricShadows;
    c.parametricShadowSplit = this.parametricShadowSplit;
    c.parametricDarkSplit = this.parametricDarkSplit;
    c.parametricLightSplit = this.parametricLightSplit;
    c.parametricRefineSaturation = this.parametricRefineSaturation;
    c.mixHue = this.mixHue.slice();
    c.mixSaturation = this.mixSaturation.slice();
    c.mixLuminance = this.mixLuminance.slice();
    c.calibrationRedHue = this.calibrationRedHue;
    c.calibrationRedSaturation = this.calibrationRedSaturation;
    c.calibrationGreenHue = this.calibrationGreenHue;
    c.calibrationGreenSaturation = this.calibrationGreenSaturation;
    c.calibrationBlueHue = this.calibrationBlueHue;
    c.calibrationBlueSaturation = this.calibrationBlueSaturation;
    c.colorGradingEnabled = this.colorGradingEnabled;
    c.gradingShadowsHue = this.gradingShadowsHue;
    c.gradingShadowsSaturation = this.gradingShadowsSaturation;
    c.gradingShadowsLuminance = this.gradingShadowsLuminance;
    c.gradingMidtonesHue = this.gradingMidtonesHue;
    c.gradingMidtonesSaturation = this.gradingMidtonesSaturation;
    c.gradingMidtonesLuminance = this.gradingMidtonesLuminance;
    c.gradingHighlightsHue = this.gradingHighlightsHue;
    c.gradingHighlightsSaturation = this.gradingHighlightsSaturation;
    c.gradingHighlightsLuminance = this.gradingHighlightsLuminance;
    c.gradingGlobalHue = this.gradingGlobalHue;
    c.gradingGlobalSaturation = this.gradingGlobalSaturation;
    c.gradingGlobalLuminance = this.gradingGlobalLuminance;
    c.gradingBlending = this.gradingBlending;
    c.gradingBalance = this.gradingBalance;
    return c;
  }

  reset(): void {
    this.exposure = 0;
    this.contrast = 0;
    this.brightness = 0;
    this.highlights = 0;
    this.shadows = 0;
    this.whites = 0;
    this.blacks = 0;
    this.vignetteAmount = 0;
    this.vignetteMidpoint = 0.5;
    this.vignetteRoundness = 0;
    this.vignetteFeather = 0.8;
    this.vignetteHighlights = 0;
    this.grainAmount = 0;
    this.grainSize = 0.5;
    this.grainRoughness = 0.5;
    this.saturation = 0;
    this.vibrance = 0;
    this.temperature = 0;
    this.tint = 0;
    this.hue = 0;
    this.toneCurve = 0;
    this.curveRed = 0;
    this.curveGreen = 0;
    this.curveBlue = 0;
    this.toneCurvePoints = ColorAdjustments.defaultCurve();
    this.redCurvePoints = ColorAdjustments.defaultCurve();
    this.greenCurvePoints = ColorAdjustments.defaultCurve();
    this.blueCurvePoints = ColorAdjustments.defaultCurve();
    this.parametricHighlights = 0;
    this.parametricLights = 0;
    this.parametricDarks = 0;
    this.parametricShadows = 0;
    this.parametricShadowSplit = 0.25;
    this.parametricDarkSplit = 0.5;
    this.parametricLightSplit = 0.75;
    this.parametricRefineSaturation = 1;
    this.mixHue = [0, 0, 0, 0, 0, 0, 0, 0];
    this.mixSaturation = [0, 0, 0, 0, 0, 0, 0, 0];
    this.mixLuminance = [0, 0, 0, 0, 0, 0, 0, 0];
    this.calibrationRedHue = 0;
    this.calibrationRedSaturation = 0;
    this.calibrationGreenHue = 0;
    this.calibrationGreenSaturation = 0;
    this.calibrationBlueHue = 0;
    this.calibrationBlueSaturation = 0;
    this.colorGradingEnabled = true;
    this.gradingShadowsHue = 0;
    this.gradingShadowsSaturation = 0;
    this.gradingShadowsLuminance = 0;
    this.gradingMidtonesHue = 0;
    this.gradingMidtonesSaturation = 0;
    this.gradingMidtonesLuminance = 0;
    this.gradingHighlightsHue = 0;
    this.gradingHighlightsSaturation = 0;
    this.gradingHighlightsLuminance = 0;
    this.gradingGlobalHue = 0;
    this.gradingGlobalSaturation = 0;
    this.gradingGlobalLuminance = 0;
    this.gradingBlending = 0;
    this.gradingBalance = 0;
  }

  getValue(key: string): number {
    if (key === 'exposure') return this.exposure;
    if (key === 'contrast') return this.contrast;
    if (key === 'brightness') return this.brightness;
    if (key === 'highlights') return this.highlights;
    if (key === 'shadows') return this.shadows;
    if (key === 'whites') return this.whites;
    if (key === 'blacks') return this.blacks;
    if (key === 'vignetteAmount') return this.vignetteAmount;
    if (key === 'vignetteMidpoint') return this.vignetteMidpoint;
    if (key === 'vignetteRoundness') return this.vignetteRoundness;
    if (key === 'vignetteFeather') return this.vignetteFeather;
    if (key === 'grainAmount') return this.grainAmount;
    if (key === 'grainSize') return this.grainSize;
    if (key === 'grainRoughness') return this.grainRoughness;
    if (key === 'saturation') return this.saturation;
    if (key === 'vibrance') return this.vibrance;
    if (key === 'temperature') return this.temperature;
    if (key === 'tint') return this.tint;
    if (key === 'hue') return this.hue;
    if (key === 'toneCurve') return this.toneCurve;
    if (key === 'curveRed') return this.curveRed;
    if (key === 'curveGreen') return this.curveGreen;
    if (key === 'curveBlue') return this.curveBlue;
    if (key === 'parametricHighlights') return this.parametricHighlights;
    if (key === 'parametricLights') return this.parametricLights;
    if (key === 'parametricDarks') return this.parametricDarks;
    if (key === 'parametricShadows') return this.parametricShadows;
    if (key === 'parametricShadowSplit') return this.parametricShadowSplit;
    if (key === 'parametricDarkSplit') return this.parametricDarkSplit;
    if (key === 'parametricLightSplit') return this.parametricLightSplit;
    if (key === 'parametricRefineSaturation') return this.parametricRefineSaturation;
    if (key === 'calibrationRedHue') return this.calibrationRedHue;
    if (key === 'calibrationRedSaturation') return this.calibrationRedSaturation;
    if (key === 'calibrationGreenHue') return this.calibrationGreenHue;
    if (key === 'calibrationGreenSaturation') return this.calibrationGreenSaturation;
    if (key === 'calibrationBlueHue') return this.calibrationBlueHue;
    if (key === 'calibrationBlueSaturation') return this.calibrationBlueSaturation;
    if (key === 'gradingShadowsHue') return this.gradingShadowsHue;
    if (key === 'gradingShadowsSaturation') return this.gradingShadowsSaturation;
    if (key === 'gradingShadowsLuminance') return this.gradingShadowsLuminance;
    if (key === 'gradingMidtonesHue') return this.gradingMidtonesHue;
    if (key === 'gradingMidtonesSaturation') return this.gradingMidtonesSaturation;
    if (key === 'gradingMidtonesLuminance') return this.gradingMidtonesLuminance;
    if (key === 'gradingHighlightsHue') return this.gradingHighlightsHue;
    if (key === 'gradingHighlightsSaturation') return this.gradingHighlightsSaturation;
    if (key === 'gradingHighlightsLuminance') return this.gradingHighlightsLuminance;
    if (key === 'gradingGlobalHue') return this.gradingGlobalHue;
    if (key === 'gradingGlobalSaturation') return this.gradingGlobalSaturation;
    if (key === 'gradingGlobalLuminance') return this.gradingGlobalLuminance;
    if (key === 'gradingBlending') return this.gradingBlending;
    if (key === 'gradingBalance') return this.gradingBalance;
    return 0;
  }

  setValue(key: string, value: number): void {
    if (key === 'exposure') { this.exposure = value; }
    else if (key === 'contrast') { this.contrast = value; }
    else if (key === 'brightness') { this.brightness = value; }
    else if (key === 'highlights') { this.highlights = value; }
    else if (key === 'shadows') { this.shadows = value; }
    else if (key === 'whites') { this.whites = value; }
    else if (key === 'blacks') { this.blacks = value; }
    else if (key === 'vignetteAmount') { this.vignetteAmount = value; }
    else if (key === 'vignetteMidpoint') { this.vignetteMidpoint = value; }
    else if (key === 'vignetteRoundness') { this.vignetteRoundness = value; }
    else if (key === 'vignetteFeather') { this.vignetteFeather = value; }
    else if (key === 'grainAmount') { this.grainAmount = value; }
    else if (key === 'grainSize') { this.grainSize = value; }
    else if (key === 'grainRoughness') { this.grainRoughness = value; }
    else if (key === 'saturation') { this.saturation = value; }
    else if (key === 'vibrance') { this.vibrance = value; }
    else if (key === 'temperature') { this.temperature = value; }
    else if (key === 'tint') { this.tint = value; }
    else if (key === 'hue') { this.hue = value; }
    else if (key === 'toneCurve') { this.toneCurve = value; }
    else if (key === 'curveRed') { this.curveRed = value; }
    else if (key === 'curveGreen') { this.curveGreen = value; }
    else if (key === 'curveBlue') { this.curveBlue = value; }
    else if (key === 'parametricHighlights') { this.parametricHighlights = value; }
    else if (key === 'parametricLights') { this.parametricLights = value; }
    else if (key === 'parametricDarks') { this.parametricDarks = value; }
    else if (key === 'parametricShadows') { this.parametricShadows = value; }
    else if (key === 'parametricShadowSplit') { this.parametricShadowSplit = value; }
    else if (key === 'parametricDarkSplit') { this.parametricDarkSplit = value; }
    else if (key === 'parametricLightSplit') { this.parametricLightSplit = value; }
    else if (key === 'parametricRefineSaturation') { this.parametricRefineSaturation = value; }
    else if (key === 'calibrationRedHue') { this.calibrationRedHue = value; }
    else if (key === 'calibrationRedSaturation') { this.calibrationRedSaturation = value; }
    else if (key === 'calibrationGreenHue') { this.calibrationGreenHue = value; }
    else if (key === 'calibrationGreenSaturation') { this.calibrationGreenSaturation = value; }
    else if (key === 'calibrationBlueHue') { this.calibrationBlueHue = value; }
    else if (key === 'calibrationBlueSaturation') { this.calibrationBlueSaturation = value; }
    else if (key === 'gradingShadowsHue') { this.gradingShadowsHue = value; }
    else if (key === 'gradingShadowsSaturation') { this.gradingShadowsSaturation = value; }
    else if (key === 'gradingShadowsLuminance') { this.gradingShadowsLuminance = value; }
    else if (key === 'gradingMidtonesHue') { this.gradingMidtonesHue = value; }
    else if (key === 'gradingMidtonesSaturation') { this.gradingMidtonesSaturation = value; }
    else if (key === 'gradingMidtonesLuminance') { this.gradingMidtonesLuminance = value; }
    else if (key === 'gradingHighlightsHue') { this.gradingHighlightsHue = value; }
    else if (key === 'gradingHighlightsSaturation') { this.gradingHighlightsSaturation = value; }
    else if (key === 'gradingHighlightsLuminance') { this.gradingHighlightsLuminance = value; }
    else if (key === 'gradingGlobalHue') { this.gradingGlobalHue = value; }
    else if (key === 'gradingGlobalSaturation') { this.gradingGlobalSaturation = value; }
    else if (key === 'gradingGlobalLuminance') { this.gradingGlobalLuminance = value; }
    else if (key === 'gradingBlending') { this.gradingBlending = value; }
    else if (key === 'gradingBalance') { this.gradingBalance = value; }
  }

  getColorGradeValue(channel: number, axis: number): number {
    if (channel === 0) {
      if (axis === 0) return this.gradingShadowsHue;
      if (axis === 1) return this.gradingShadowsSaturation;
      return this.gradingShadowsLuminance;
    }
    if (channel === 1) {
      if (axis === 0) return this.gradingMidtonesHue;
      if (axis === 1) return this.gradingMidtonesSaturation;
      return this.gradingMidtonesLuminance;
    }
    if (channel === 2) {
      if (axis === 0) return this.gradingHighlightsHue;
      if (axis === 1) return this.gradingHighlightsSaturation;
      return this.gradingHighlightsLuminance;
    }
    if (axis === 0) return this.gradingGlobalHue;
    if (axis === 1) return this.gradingGlobalSaturation;
    return this.gradingGlobalLuminance;
  }

  setColorGradeValue(channel: number, axis: number, value: number): void {
    if (channel === 0) {
      if (axis === 0) this.gradingShadowsHue = value;
      else if (axis === 1) this.gradingShadowsSaturation = value;
      else this.gradingShadowsLuminance = value;
    } else if (channel === 1) {
      if (axis === 0) this.gradingMidtonesHue = value;
      else if (axis === 1) this.gradingMidtonesSaturation = value;
      else this.gradingMidtonesLuminance = value;
    } else if (channel === 2) {
      if (axis === 0) this.gradingHighlightsHue = value;
      else if (axis === 1) this.gradingHighlightsSaturation = value;
      else this.gradingHighlightsLuminance = value;
    } else if (axis === 0) this.gradingGlobalHue = value;
    else if (axis === 1) this.gradingGlobalSaturation = value;
    else this.gradingGlobalLuminance = value;
  }

  getMixValue(channel: number, axis: number): number {
    if (channel < 0 || channel >= 8) return 0;
    if (axis === 0) return this.mixHue[channel];
    if (axis === 1) return this.mixSaturation[channel];
    return this.mixLuminance[channel];
  }

  setMixValue(channel: number, axis: number, value: number): void {
    if (channel < 0 || channel >= 8) return;
    if (axis === 0) this.mixHue[channel] = value;
    else if (axis === 1) this.mixSaturation[channel] = value;
    else this.mixLuminance[channel] = value;
  }

  getCurvePoints(channel: number): CurveAnchor[] {
    if (channel === 1) return this.redCurvePoints;
    if (channel === 2) return this.greenCurvePoints;
    if (channel === 3) return this.blueCurvePoints;
    return this.toneCurvePoints;
  }

  setCurvePoints(channel: number, points: CurveAnchor[]): void {
    const copied = points.map((point: CurveAnchor) => point.clone());
    if (channel === 1) this.redCurvePoints = copied;
    else if (channel === 2) this.greenCurvePoints = copied;
    else if (channel === 3) this.blueCurvePoints = copied;
    else this.toneCurvePoints = copied;
  }

  private curveIsIdentity(points: CurveAnchor[]): boolean {
    if (points.length < 2 || points[0].x !== 0 || points[points.length - 1].x !== 1) return false;
    for (let index = 0; index < points.length; index++) {
      if (Math.abs(points[index].x - points[index].y) > 0.0005 ||
        (index > 0 && points[index].x <= points[index - 1].x)) return false;
    }
    return true;
  }

  hasAdvancedAdjustments(): boolean {
    // These controls depend on pixel luminance/saturation. They must not be
    // collapsed into the affine colour matrix, otherwise highlights, shadows
    // and vibrance alter every pixel by the same amount.
    if (this.exposure !== 0 || this.highlights !== 0 || this.shadows !== 0 || this.whites !== 0 || this.blacks !== 0 ||
      this.vibrance !== 0 || this.temperature !== 0 || this.tint !== 0) return true;
    if (this.toneCurve !== 0 || this.curveRed !== 0 || this.curveGreen !== 0 || this.curveBlue !== 0) return true;
    // Only the region amounts change the curve; moving a split with every
    // amount at zero still produces the identity, so it needs no pass.
    if (this.parametricHighlights !== 0 || this.parametricLights !== 0 ||
      this.parametricDarks !== 0 || this.parametricShadows !== 0) return true;
    if (!this.curveIsIdentity(this.toneCurvePoints) || !this.curveIsIdentity(this.redCurvePoints) ||
      !this.curveIsIdentity(this.greenCurvePoints) || !this.curveIsIdentity(this.blueCurvePoints)) return true;
    if (this.calibrationRedHue !== 0 || this.calibrationRedSaturation !== 0 ||
      this.calibrationGreenHue !== 0 || this.calibrationGreenSaturation !== 0 ||
      this.calibrationBlueHue !== 0 || this.calibrationBlueSaturation !== 0) return true;
    if (this.vignetteAmount !== 0 || this.grainAmount !== 0) return true;
    if (this.colorGradingEnabled && (this.gradingShadowsSaturation !== 0 || this.gradingShadowsLuminance !== 0 ||
      this.gradingMidtonesSaturation !== 0 || this.gradingMidtonesLuminance !== 0 ||
      this.gradingHighlightsSaturation !== 0 || this.gradingHighlightsLuminance !== 0 ||
      this.gradingGlobalSaturation !== 0 || this.gradingGlobalLuminance !== 0 ||
      this.gradingShadowsHue !== 0 || this.gradingMidtonesHue !== 0 ||
      this.gradingHighlightsHue !== 0 || this.gradingGlobalHue !== 0 ||
      this.gradingBlending !== 0 || this.gradingBalance !== 0)) return true;
    for (let i = 0; i < 8; i++) {
      if (this.mixHue[i] !== 0 || this.mixSaturation[i] !== 0 || this.mixLuminance[i] !== 0) return true;
    }
    return false;
  }
}

export enum AdjustmentCategory {
  LIGHT = 'light',
  COLOR = 'color',
  CURVE = 'curve',
  MIX = 'mix',
  CALIBRATION = 'calibration',
  GRADING = 'grading',
}

export interface AdjustmentDef {
  key: string;
  label: string;
  category: AdjustmentCategory;
  min: number;
  max: number;
  step: number;
  format: (v: number) => string;
}

export const ADJUSTMENT_DEFS: AdjustmentDef[] = [
  { key: 'exposure', label: '曝光', category: AdjustmentCategory.LIGHT, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'contrast', label: '对比度', category: AdjustmentCategory.LIGHT, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'brightness', label: '亮度', category: AdjustmentCategory.LIGHT, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'highlights', label: '高光', category: AdjustmentCategory.LIGHT, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'shadows', label: '阴影', category: AdjustmentCategory.LIGHT, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'whites', label: '白色', category: AdjustmentCategory.LIGHT, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
    { key: 'blacks', label: '黑色', category: AdjustmentCategory.LIGHT, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'vignetteAmount', label: '晕影', category: AdjustmentCategory.LIGHT, min: -1, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'vignetteMidpoint', label: '中点', category: AdjustmentCategory.LIGHT, min: 0, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'vignetteRoundness', label: '圆度', category: AdjustmentCategory.LIGHT, min: -1, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'vignetteFeather', label: '羽化', category: AdjustmentCategory.LIGHT, min: 0, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'grainAmount', label: '颗粒', category: AdjustmentCategory.LIGHT, min: 0, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'grainSize', label: '大小', category: AdjustmentCategory.LIGHT, min: 0, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'grainRoughness', label: '粗糙度', category: AdjustmentCategory.LIGHT, min: 0, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'saturation', label: '饱和度', category: AdjustmentCategory.COLOR, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'vibrance', label: '鲜艳度', category: AdjustmentCategory.COLOR, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'temperature', label: '色温', category: AdjustmentCategory.COLOR, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'tint', label: '色调', category: AdjustmentCategory.COLOR, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'hue', label: '色相', category: AdjustmentCategory.COLOR, min: -180, max: 180, step: 1, format: (v) => v.toFixed(0) + '°' },
  // Parametric tone curve. Region labels are suffixed so they cannot be
  // mistaken for the Light section's global 高光/阴影 sliders.
  { key: 'parametricHighlights', label: '高光区', category: AdjustmentCategory.CURVE, min: -1, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'parametricLights', label: '亮调区', category: AdjustmentCategory.CURVE, min: -1, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'parametricDarks', label: '暗调区', category: AdjustmentCategory.CURVE, min: -1, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'parametricShadows', label: '阴影区', category: AdjustmentCategory.CURVE, min: -1, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'parametricShadowSplit', label: '阴影分割', category: AdjustmentCategory.CURVE, min: 0, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'parametricDarkSplit', label: '暗调分割', category: AdjustmentCategory.CURVE, min: 0, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'parametricLightSplit', label: '亮调分割', category: AdjustmentCategory.CURVE, min: 0, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'parametricRefineSaturation', label: '细化饱和度', category: AdjustmentCategory.CURVE, min: 0, max: 1, step: 0.01, format: (v) => Math.round(v * 100).toString() },
  { key: 'calibrationRedHue', label: '红原色色相', category: AdjustmentCategory.CALIBRATION, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'calibrationRedSaturation', label: '红原色饱和', category: AdjustmentCategory.CALIBRATION, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'calibrationGreenHue', label: '绿原色色相', category: AdjustmentCategory.CALIBRATION, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'calibrationGreenSaturation', label: '绿原色饱和', category: AdjustmentCategory.CALIBRATION, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'calibrationBlueHue', label: '蓝原色色相', category: AdjustmentCategory.CALIBRATION, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
  { key: 'calibrationBlueSaturation', label: '蓝原色饱和', category: AdjustmentCategory.CALIBRATION, min: -1, max: 1, step: 0.01, format: (v) => v.toFixed(2) },
];

/**
 * Monotone cubic interpolation through sorted anchors. Catmull-Rom can
 * overshoot between user points, then get clamped by the renderer.
 */
export function smoothCurveY(points: CurveAnchor[], x: number): number {
  if (points.length === 0) return Math.max(0, Math.min(1, x));
  if (x <= points[0].x) return points[0].y;
  const last = points[points.length - 1];
  if (x >= last.x) return last.y;
  for (let i = 0; i < points.length - 1; i++) {
    const p1 = points[i];
    const p2 = points[i + 1];
    if (x > p2.x) continue;
    const h = Math.max(0.00001, p2.x - p1.x);
    const tangent = (index: number): number => {
      if (index <= 0) return (points[1].y - points[0].y) /
        Math.max(0.00001, points[1].x - points[0].x);
      if (index >= points.length - 1) return (points[index].y - points[index - 1].y) /
        Math.max(0.00001, points[index].x - points[index - 1].x);
      const left = (points[index].y - points[index - 1].y) /
        Math.max(0.00001, points[index].x - points[index - 1].x);
      const right = (points[index + 1].y - points[index].y) /
        Math.max(0.00001, points[index + 1].x - points[index].x);
      return left * right <= 0 ? 0 : 2 * left * right / (left + right);
    };
    const t = (x - p1.x) / h;
    const t2 = t * t;
    const t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * p1.y + (t3 - 2 * t2 + t) * h * tangent(i) +
      (-2 * t3 + 3 * t2) * p2.y + (t3 - t2) * h * tangent(i + 1);
  }
  return last.y;
}
