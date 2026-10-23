import { ColorAdjustments } from './Adjustment';
import { MaskState, MaskLayer, MaskComponent, MaskComponentType, migrateLegacyMask } from './Mask';

export enum BlendMode {
  NORMAL = 0,
  MULTIPLY = 1,
  SCREEN = 2,
  OVERLAY = 3,
}

@Observed
export class Layer {
  public id: string;
  public name: string;
  public visible: boolean = true;
  public opacity: number = 1.0; // [0..1]
  public blendMode: BlendMode = BlendMode.NORMAL;
  public adjustments: ColorAdjustments = new ColorAdjustments();
  // Colour adjustments scoped to the masked region of this layer.
  public maskAdjustments: ColorAdjustments = new ColorAdjustments();
  /** New Lightroom-style mask stack. `mask` is retained as a legacy bridge. */
  public maskLayers: MaskLayer[] = [];
  public mask: MaskState | null = null;

  constructor(name: string, id?: string) {
    this.id = id ?? generateId();
    this.name = name;
  }

  clone(): Layer {
    const l = new Layer(this.name, this.id);
    l.visible = this.visible;
    l.opacity = this.opacity;
    l.blendMode = this.blendMode;
    l.adjustments = this.adjustments.clone();
    l.maskAdjustments = this.maskAdjustments.clone();
    l.maskLayers = this.maskLayers.map((maskLayer: MaskLayer) => maskLayer.clone());
    l.mask = this.mask ? this.mask.clone() : null;
    return l;
  }

  hasMask(): boolean {
    return this.maskLayers.some((maskLayer: MaskLayer) =>
      maskLayer.enabled && maskLayer.components.some((component: MaskComponent) => component.enabled)) ||
      (this.mask !== null && this.mask.type !== 0);
  }

  /** Ensure old projects are represented by the new mask stack. */
  migrateMask(): void {
    if (this.maskLayers.length === 0 && this.mask && this.mask.type !== 0) {
      const migrated = migrateLegacyMask(this.mask, this.name + ' 蒙版');
      if (migrated) {
        // The former `maskAdjustments` belonged to the single mask. Move it to
        // the new layer owner so legacy sidecars render identically.
        migrated.adjustments = this.maskAdjustments.clone();
        this.maskLayers.push(migrated);
      }
    }
  }

  get firstMaskLayer(): MaskLayer | null {
    this.migrateMask();
    return this.maskLayers.length > 0 ? this.maskLayers[0] : null;
  }

  get firstMaskComponent(): MaskComponent | null {
    const layer = this.firstMaskLayer;
    return layer && layer.components.length > 0 ? layer.components[0] : null;
  }

  touchMaskLayers(): void {
    for (const maskLayer of this.maskLayers) maskLayer.touch();
  }
}

function generateId(): string {
  return 'lyr_' + Date.now().toString(36) + '_' + Math.random().toString(36).substring(2, 8);
}
