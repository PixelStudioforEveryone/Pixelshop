import { ColorAdjustments } from './Adjustment';

/** Legacy numeric tool type kept for old sidecars and existing UI callers. */
export enum MaskType {
  NONE = 0,
  BRUSH = 1,
  LINEAR_GRADIENT = 2,
  RADIAL_GRADIENT = 3,
}

/** Lightroom-style mask composition operation. */
export enum MaskBlendMode {
  ADD = 'add',
  SUBTRACT = 'subtract',
  INTERSECT = 'intersect',
}

/** A component is a single selection inside one mask layer. */
export enum MaskComponentType {
  BRUSH = 'brush',
  LINEAR_GRADIENT = 'linearGradient',
  RADIAL_GRADIENT = 'radialGradient',
  /** Locally segmented salient subject (U^2-NetP). */
  SUBJECT = 'subject',
  /** Locally segmented sky (skysegsmall). */
  SKY = 'sky',
  /** Luminance / colour "range" selection computed from the source pixels. */
  RANGE = 'range',
}

/** Numeric component ids shared with MaskRasterCore and the taskpool path. */
export const MASK_WORKER_TYPE_BRUSH: number = 0;
export const MASK_WORKER_TYPE_LINEAR: number = 1;
export const MASK_WORKER_TYPE_RADIAL: number = 2;
export const MASK_WORKER_TYPE_SUBJECT: number = 3;
export const MASK_WORKER_TYPE_SKY: number = 4;
export const MASK_WORKER_TYPE_RANGE: number = 5;

/** Raster origins, recorded in the sidecar so a raster keeps its provenance. */
export const RASTER_ORIGIN_SUBJECT: string = 'subject';
export const RASTER_ORIGIN_SKY: string = 'sky';
export const RASTER_ORIGIN_RANGE: string = 'range';

/**
 * True when a component type is backed by a full-frame soft raster rather than
 * by geometry the rasteriser can evaluate on its own.
 */
export function isRasterComponentType(type: MaskComponentType): boolean {
  return type === MaskComponentType.SUBJECT || type === MaskComponentType.SKY ||
    type === MaskComponentType.RANGE;
}

/** Map a component type to the numeric id used by the rasteriser. */
export function maskWorkerType(type: MaskComponentType): number {
  if (type === MaskComponentType.LINEAR_GRADIENT) return MASK_WORKER_TYPE_LINEAR;
  if (type === MaskComponentType.RADIAL_GRADIENT) return MASK_WORKER_TYPE_RADIAL;
  if (type === MaskComponentType.SUBJECT) return MASK_WORKER_TYPE_SUBJECT;
  if (type === MaskComponentType.SKY) return MASK_WORKER_TYPE_SKY;
  if (type === MaskComponentType.RANGE) return MASK_WORKER_TYPE_RANGE;
  return MASK_WORKER_TYPE_BRUSH;
}

/**
 * A full-frame soft alpha at a bounded resolution, in source-normalised space.
 *
 * Two producers feed these: a local segmentation model (subject / sky) and the
 * analytic range builder (luminance / colour). Both cover the whole SOURCE
 * frame, so they stay registered with every other component — and with crop,
 * rotation, flip and perspective — without any extra mapping. `alpha` is empty
 * until the raster has actually been produced: a component in that state
 * selects nothing rather than pretending to work.
 */
@Observed
export class MaskRaster {
  /** Which producer made this raster; see RASTER_ORIGIN_*. */
  public origin: string = '';
  /** Model key or parameter signature, for provenance and cache keys. */
  public key: string = '';
  public width: number = 0;
  public height: number = 0;
  /** width*height single-channel alpha, 0..255. */
  public alpha: Uint8Array = new Uint8Array(0);

  get hasAlpha(): boolean {
    return this.width > 0 && this.height > 0 && this.alpha.length >= this.width * this.height;
  }

  clone(): MaskRaster {
    const copy = new MaskRaster();
    copy.origin = this.origin;
    copy.key = this.key;
    copy.width = this.width;
    copy.height = this.height;
    copy.alpha = new Uint8Array(this.alpha);
    return copy;
  }
}

/**
 * Parameters of a luminance / colour range selection.
 *
 * Only the parameters live here; the raster they produce is stored in
 * `MaskComponent.raster`, exactly like a model mask. That is deliberate: a
 * range selection is then composited, persisted, undone and exported by the
 * same code path as every other raster selection, instead of needing its own.
 */
@Observed
export class RangeMaskData {
  /** Luminance window, in 0..1 of display-referred Rec.709 luma. */
  public min: number = 0;
  public max: number = 1;
  /** Transition width of both window edges, 0..1. 0 is an almost hard cut. */
  public smoothness: number = 0.25;
  /** Optional colour range, ANDed with the luminance window like Camera Raw. */
  public colorEnabled: boolean = false;
  public colorR: number = 0.5;
  public colorG: number = 0.5;
  public colorB: number = 0.5;
  /** How inclusive the colour match is, 0..1. */
  public colorAmount: number = 0.25;

  clone(): RangeMaskData {
    const copy = new RangeMaskData();
    copy.min = this.min;
    copy.max = this.max;
    copy.smoothness = this.smoothness;
    copy.colorEnabled = this.colorEnabled;
    copy.colorR = this.colorR;
    copy.colorG = this.colorG;
    copy.colorB = this.colorB;
    copy.colorAmount = this.colorAmount;
    return copy;
  }
}

// LocalAdjustments intentionally aliases the full adjustment object. This
// keeps local masks extensible (curves, mixer and grading) while making the
// ownership boundary explicit: a component only stores geometry, the layer
// owns the adjustment set.
export type LocalAdjustments = ColorAdjustments;

export class BrushPoint {
  public x: number = 0; // normalized [0..1]
  public y: number = 0; // normalized [0..1]
  public radius: number = 0.02; // normalized brush size
  public hardness: number = 0.5; // 0 = soft edge, 1 = hard edge
}

@Observed
export class BrushStroke {
  public points: BrushPoint[] = [];
  public mode: number = 0; // 0 = 添加(并集), 1 = 擦除(删除), 2 = 交集
  public flow: number = 1;
  public density: number = 1;
}

@Observed
export class LinearGradientParams {
  public startX: number = 0.5;
  public startY: number = 0.0;
  public endX: number = 0.5;
  public endY: number = 1.0;
  public feather: number = 0.25;
}

/** One linear component in a composite mask. Operation 0 adds coverage and
 * operation 1 subtracts coverage from the components that came before it. */
@Observed
export class LinearMaskPart {
  public operation: number = 0;
  public params: LinearGradientParams = new LinearGradientParams();

  clone(): LinearMaskPart {
    const part = new LinearMaskPart();
    part.operation = this.operation;
    part.params.startX = this.params.startX;
    part.params.startY = this.params.startY;
    part.params.endX = this.params.endX;
    part.params.endY = this.params.endY;
    part.params.feather = this.params.feather;
    return part;
  }
}

@Observed
export class RadialGradientParams {
  public centerX: number = 0.5;
  public centerY: number = 0.5;
  public radius: number = 0.5; // legacy circle radius
  public radiusX: number = 0.5; // horizontal radius (normalized to image width)
  public radiusY: number = 0.5; // vertical radius (normalized to image height)
  public feather: number = 0.2;
  public rotation: number = 0;
}

@Observed
export class BrushMaskData {
  public strokes: BrushStroke[] = [];
  /** Lightroom 式自动蒙版：画笔只在颜色与落笔点相近的像素上着色。 */
  public autoMask: boolean = false;
  /** 自动蒙版灵敏度 0..1，越大越宽容（容差越大）。 */
  public sensitivity: number = 0.5;

  clone(): BrushMaskData {
    const copy = new BrushMaskData();
    copy.strokes = this.strokes.map((stroke: BrushStroke) => {
      const cloned = new BrushStroke();
      cloned.mode = stroke.mode;
      cloned.flow = stroke.flow; cloned.density = stroke.density;
      cloned.points = stroke.points.map((point: BrushPoint) => {
        const p = new BrushPoint();
        p.x = point.x;
        p.y = point.y;
        p.radius = point.radius;
        p.hardness = point.hardness;
        return p;
      });
      return cloned;
    });
    copy.autoMask = this.autoMask;
    copy.sensitivity = this.sensitivity;
    return copy;
  }
}

@Observed
export class LinearGradientData {
  public startX: number = 0.5;
  public startY: number = 0.0;
  public endX: number = 0.5;
  public endY: number = 1.0;

  clone(): LinearGradientData {
    const copy = new LinearGradientData();
    copy.startX = this.startX;
    copy.startY = this.startY;
    copy.endX = this.endX;
    copy.endY = this.endY;
    return copy;
  }
}

@Observed
export class RadialGradientData {
  public centerX: number = 0.5;
  public centerY: number = 0.5;
  public radiusX: number = 0.5;
  public radiusY: number = 0.5;
  public rotation: number = 0;

  clone(): RadialGradientData {
    const copy = new RadialGradientData();
    copy.centerX = this.centerX;
    copy.centerY = this.centerY;
    copy.radiusX = this.radiusX;
    copy.radiusY = this.radiusY;
    copy.rotation = this.rotation;
    return copy;
  }
}

@Observed
export class MaskComponent {
  // v1 preserves existing sidecars; v2 uses smooth, pixel-centred gradients.
  public renderingVersion: number = 3;
  public id: string;
  public type: MaskComponentType;
  public blendMode: MaskBlendMode = MaskBlendMode.ADD;
  public enabled: boolean = true;
  public visible: boolean = true;
  public inverted: boolean = false;
  public opacity: number = 1;
  // Keep the default softness on gradient components only. A value of 0 is
  // meaningful (the user can explicitly request a hard edge), so the
  // renderer must not silently replace it with a fallback value.
  public feather: number = 0;
  public brushData: BrushMaskData | null = null;
  public linearGradientData: LinearGradientData | null = null;
  public radialGradientData: RadialGradientData | null = null;
  /** Range-selection parameters; only meaningful for MaskComponentType.RANGE. */
  public rangeData: RangeMaskData | null = null;
  /**
   * Full-frame soft selection raster, shared by model masks (subject / sky) and
   * range masks. Null for the geometric component types.
   */
  public raster: MaskRaster | null = null;

  constructor(type: MaskComponentType = MaskComponentType.BRUSH, id?: string) {
    this.id = id ?? generateMaskId('cmp');
    this.type = type;
    if (type === MaskComponentType.LINEAR_GRADIENT) this.feather = 0.5;
    if (type === MaskComponentType.RADIAL_GRADIENT) this.feather = 0.2;
    // Model rasters already carry a soft edge from the network and a range
    // raster gets its own edge from the window smoothness, so an extra feather
    // would only blur the selection further; the user can still raise it.
    if (isRasterComponentType(type)) this.feather = 0;
    this.ensureData();
  }

  ensureData(): void {
    if (this.type === MaskComponentType.BRUSH && !this.brushData) this.brushData = new BrushMaskData();
    if (this.type === MaskComponentType.LINEAR_GRADIENT && !this.linearGradientData) {
      this.linearGradientData = new LinearGradientData();
    }
    if (this.type === MaskComponentType.RADIAL_GRADIENT && !this.radialGradientData) {
      this.radialGradientData = new RadialGradientData();
    }
    if (this.type === MaskComponentType.RANGE && !this.rangeData) {
      this.rangeData = new RangeMaskData();
    }
    // A raster component with no raster yet is a valid, meaningful state: it
    // selects nothing until its producer has actually run.
  }

  clone(): MaskComponent {
    const copy = new MaskComponent(this.type, this.id);
    copy.renderingVersion = this.renderingVersion;
    copy.blendMode = this.blendMode;
    copy.enabled = this.enabled;
    copy.visible = this.visible;
    copy.inverted = this.inverted;
    copy.opacity = this.opacity;
    copy.feather = this.feather;
    copy.brushData = this.brushData ? this.brushData.clone() : null;
    copy.linearGradientData = this.linearGradientData ? this.linearGradientData.clone() : null;
    copy.radialGradientData = this.radialGradientData ? this.radialGradientData.clone() : null;
    copy.rangeData = this.rangeData ? this.rangeData.clone() : null;
    copy.raster = this.raster ? this.raster.clone() : null;
    return copy;
  }
}

@Observed
export class MaskLayer {
  public inverted: boolean = false;
  public id: string;
  public name: string;
  public enabled: boolean = true;
  public visible: boolean = true;
  public opacity: number = 1;
  public components: MaskComponent[] = [];
  public adjustments: LocalAdjustments = new ColorAdjustments();
  public createdAt: number;
  public updatedAt: number;

  constructor(name: string = '蒙版 1', id?: string) {
    this.id = id ?? generateMaskId('msk');
    this.name = name;
    this.createdAt = Date.now();
    this.updatedAt = this.createdAt;
  }

  touch(): void {
    this.updatedAt = Date.now();
  }

  clone(): MaskLayer {
    const copy = new MaskLayer(this.name, this.id);
    copy.inverted = this.inverted;
    copy.enabled = this.enabled;
    copy.visible = this.visible;
    copy.opacity = this.opacity;
    copy.createdAt = this.createdAt;
    copy.updatedAt = this.updatedAt;
    copy.components = this.components.map((component: MaskComponent) => component.clone());
    copy.adjustments = this.adjustments.clone();
    return copy;
  }
}

function generateMaskId(prefix: string): string {
  return prefix + '_' + Date.now().toString(36) + '_' + Math.random().toString(36).substring(2, 8);
}

@Observed
export class MaskState {
  /** Versioned Lightroom-style state. Legacy fields below remain readable. */
  public version: number = 2;
  public layers: MaskLayer[] = [];
  public selectedLayerId: string | null = null;
  public selectedComponentId: string | null = null;
  public activeTool: MaskComponentType | null = null;

  // Legacy single-mask fields (read by older screens and migrated on load).
  public type: MaskType = MaskType.NONE;
  public brushStrokes: BrushStroke[] = [];
  public linearGradient: LinearGradientParams = new LinearGradientParams();
  /** Ordered linear components used by Lightroom-style add/subtract masks. */
  public linearParts: LinearMaskPart[] = [];
  public activeLinearIndex: number = 0;
  public radialGradient: RadialGradientParams = new RadialGradientParams();
  public invert: boolean = false;
  public feather: number = 0;

  clone(): MaskState {
    const m = new MaskState();
    m.version = this.version;
    m.layers = this.layers.map((layer: MaskLayer) => layer.clone());
    m.selectedLayerId = this.selectedLayerId;
    m.selectedComponentId = this.selectedComponentId;
    m.activeTool = this.activeTool;
    m.type = this.type;
    m.invert = this.invert;
    m.feather = this.feather;
    m.linearGradient = new LinearGradientParams();
    m.linearGradient.startX = this.linearGradient.startX;
    m.linearGradient.startY = this.linearGradient.startY;
    m.linearGradient.endX = this.linearGradient.endX;
    m.linearGradient.endY = this.linearGradient.endY;
    m.linearGradient.feather = this.linearGradient.feather;
    m.linearParts = this.linearParts.map((part: LinearMaskPart) => part.clone());
    m.activeLinearIndex = this.activeLinearIndex;
    m.radialGradient = new RadialGradientParams();
    m.radialGradient.centerX = this.radialGradient.centerX;
    m.radialGradient.centerY = this.radialGradient.centerY;
    m.radialGradient.radius = this.radialGradient.radius;
    m.radialGradient.radiusX = this.radialGradient.radiusX;
    m.radialGradient.radiusY = this.radialGradient.radiusY;
    m.radialGradient.feather = this.radialGradient.feather;
    m.radialGradient.rotation = this.radialGradient.rotation;
    m.brushStrokes = this.brushStrokes.map(s => {
      const ns = new BrushStroke();
      ns.mode = s.mode;
      ns.points = s.points.map(p => {
        const np = new BrushPoint();
        np.x = p.x;
        np.y = p.y;
        np.radius = p.radius;
        np.hardness = p.hardness;
        return np;
      });
      return ns;
    });
    return m;
  }
}

/** Convert a legacy single-mask state to the new layer/component structure. */
export function migrateLegacyMask(mask: MaskState | null, name: string = '蒙版 1'): MaskLayer | null {
  if (!mask || mask.type === MaskType.NONE) return null;
  const type = mask.type === MaskType.BRUSH ? MaskComponentType.BRUSH :
    (mask.type === MaskType.LINEAR_GRADIENT ? MaskComponentType.LINEAR_GRADIENT : MaskComponentType.RADIAL_GRADIENT);
  const layer = new MaskLayer(name);
  const component = new MaskComponent(type);
  component.renderingVersion = 1;
  component.inverted = mask.invert;
  component.feather = mask.feather;
  if (type === MaskComponentType.BRUSH) {
    component.brushData = new BrushMaskData();
    component.brushData.strokes = mask.brushStrokes;
  } else if (type === MaskComponentType.LINEAR_GRADIENT) {
    const partCount = mask.linearParts.length > 0 ? mask.linearParts.length : 1;
    for (let index = 0; index < partCount; index++) {
      const part: LinearMaskPart = mask.linearParts.length > 0 ? mask.linearParts[index] : new LinearMaskPart();
      if (mask.linearParts.length === 0) {
        part.params.startX = mask.linearGradient.startX;
        part.params.startY = mask.linearGradient.startY;
        part.params.endX = mask.linearGradient.endX;
        part.params.endY = mask.linearGradient.endY;
        part.params.feather = mask.linearGradient.feather;
      }
      const item = index === 0 ? component : new MaskComponent(MaskComponentType.LINEAR_GRADIENT);
      item.blendMode = part.operation === 1 ? MaskBlendMode.SUBTRACT : MaskBlendMode.ADD;
      item.feather = part.params.feather;
      item.renderingVersion = 1;
      item.linearGradientData = new LinearGradientData();
      item.linearGradientData.startX = part.params.startX;
      item.linearGradientData.startY = part.params.startY;
      item.linearGradientData.endX = part.params.endX;
      item.linearGradientData.endY = part.params.endY;
      layer.components.push(item);
    }
    layer.touch();
    return layer;
  } else {
    component.feather = mask.feather > 0 ? mask.feather : mask.radialGradient.feather;
    component.radialGradientData = new RadialGradientData();
    component.radialGradientData.centerX = mask.radialGradient.centerX;
    component.radialGradientData.centerY = mask.radialGradient.centerY;
    component.radialGradientData.radiusX = mask.radialGradient.radiusX || mask.radialGradient.radius;
    component.radialGradientData.radiusY = mask.radialGradient.radiusY || mask.radialGradient.radius;
    component.radialGradientData.rotation = mask.radialGradient.rotation ?? 0;
  }
  layer.components.push(component);
  layer.touch();
  return layer;
}

/** Create a new layer with one component, used by the mask editor entry point. */
export function createMaskLayer(type: MaskComponentType, name: string = '蒙版 1', blendMode: MaskBlendMode = MaskBlendMode.ADD): MaskLayer {
  const layer = new MaskLayer(name);
  const component = new MaskComponent(type);
  component.blendMode = blendMode;
  layer.components.push(component);
  return layer;
}
