import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { Layer, BlendMode } from './Layer';
import { ToolType } from './ToolType';
import { RawPreviewSettings } from './RawDevelopmentSettings';
import { DenoiseSettings, DenoiseValues } from './DenoiseSettings';
import { DetailSettings, DetailValues } from './DetailSettings';
import { OpticsSettings, OpticsValues } from './OpticsSettings';
import { BokehSettings, BokehValues } from './BokehSettings';
import { UprightSettings, UprightValues } from './UprightSettings';
import { PointColorSettings, PointColorValues } from './PointColorSettings';
import { PointColorPicker } from './PointColorPicker';
import { OkLChSettings, OkLChValues } from './OkLChSettings';
import { BlackWhiteSettings, BlackWhiteValues } from './BlackWhiteSettings';
import { RetouchMark, cloneRetouchMarks, RETOUCH_HEAL } from './RetouchSettings';
import { CustomLut, LutLibraryStore, LutStackItem, createLutStackItem } from './LutLibrary';
import { AdjustmentCategory, ColorAdjustments, CurveAnchor } from './Adjustment';
import {
  PROCESS_VERSION_CURRENT, PROCESS_VERSION_LEGACY, normalizeProcessVersion,
} from './ProcessVersion';
import {
  BrushPoint, BrushStroke, LinearMaskPart, MaskState, MaskType, MaskBlendMode,
  MaskComponent, MaskComponentType, MaskLayer, createMaskLayer,
  migrateLegacyMask, BrushMaskData, LinearGradientData, RadialGradientData,
  MaskRaster, RangeMaskData, isRasterComponentType,
} from './Mask';
import { GeometryMap, buildGeometryMap, displayToSource, sourceToDisplay } from '../engine/GeometryMath';
import {
  UprightSolution, applyUpright, solveUprightNormalized, uprightModeFromNumber,
} from '../engine/UprightSolver';

/**
 * Normalized portion of the image that is visible while the canvas is
 * zoomed. The editor keeps the interactive preview at a bounded resolution
 * and asks the page for a full-resolution tile only for this region.
 */
export interface DetailRegion {
  left: number;
  top: number;
  width: number;
  height: number;
}

interface LayerSnapshotAdjustments {
  exposure: number;
  contrast: number;
  brightness: number;
  highlights: number;
  shadows: number;
  whites: number;
  blacks: number;
  vignetteAmount: number;
  vignetteMidpoint: number;
  vignetteRoundness: number;
  vignetteFeather: number;
  vignetteHighlights: number;
  grainAmount: number;
  grainSize: number;
  grainRoughness: number;
  saturation: number;
  vibrance: number;
  temperature: number;
  tint: number;
  hue: number;
  toneCurve: number;
  curveRed: number;
  curveGreen: number;
  curveBlue: number;
  toneCurvePoints: CurveAnchor[];
  redCurvePoints: CurveAnchor[];
  greenCurvePoints: CurveAnchor[];
  blueCurvePoints: CurveAnchor[];
  parametricHighlights: number;
  parametricLights: number;
  parametricDarks: number;
  parametricShadows: number;
  parametricShadowSplit: number;
  parametricDarkSplit: number;
  parametricLightSplit: number;
  parametricRefineSaturation: number;
  mixHue: number[];
  mixSaturation: number[];
  mixLuminance: number[];
  calibrationRedHue: number;
  calibrationRedSaturation: number;
  calibrationGreenHue: number;
  calibrationGreenSaturation: number;
  calibrationBlueHue: number;
  calibrationBlueSaturation: number;
  colorGradingEnabled: boolean;
  gradingShadowsHue: number;
  gradingShadowsSaturation: number;
  gradingShadowsLuminance: number;
  gradingMidtonesHue: number;
  gradingMidtonesSaturation: number;
  gradingMidtonesLuminance: number;
  gradingHighlightsHue: number;
  gradingHighlightsSaturation: number;
  gradingHighlightsLuminance: number;
  gradingGlobalHue: number;
  gradingGlobalSaturation: number;
  gradingGlobalLuminance: number;
  gradingBlending: number;
  gradingBalance: number;
}

interface LayerSnapshot {
  id: string;
  name: string;
  visible: boolean;
  opacity: number;
  blendMode: number;
  adjustments: LayerSnapshotAdjustments;
  maskAdjustments: LayerSnapshotAdjustments | null;
  mask: MaskState | null;
  maskLayers?: MaskLayerSnapshot[];
}

interface MaskComponentSnapshot {
  renderingVersion?: number;
  id: string;
  type: MaskComponentType;
  blendMode: MaskBlendMode;
  enabled: boolean;
  visible: boolean;
  inverted: boolean;
  opacity: number;
  feather: number;
  brushStrokes: BrushStroke[];
  linear: number[];
  radial: number[];
  // Stored full-frame selection raster: model masks (subject / sky) and range
  // masks both persist through these fields. Optional and additive: sidecars
  // written before this existed simply have no field, and a component whose
  // raster could not be produced is persisted without one rather than as an
  // empty selection.
  rasterOrigin?: string;
  rasterKey?: string;
  rasterWidth?: number;
  rasterHeight?: number;
  /** Base64 of the width*height alpha raster, 0..255, source-normalised space. */
  rasterAlpha?: string;
  /** Range-mask parameters; absent for every other component type. */
  range?: number[];
}

interface MaskLayerSnapshot {
  inverted?: boolean;
  id: string;
  name: string;
  enabled: boolean;
  visible: boolean;
  opacity: number;
  createdAt: number;
  updatedAt: number;
  adjustments: LayerSnapshotAdjustments;
  components: MaskComponentSnapshot[];
}

interface SessionSnapshot {
  retouchMarks?: RetouchMark[];
  denoise?: DenoiseValues;
  detail?: DetailValues;
  /** 整帧雾色，供放大瓦片复用去朦胧的整帧统计量。 */
  detailHaze?: number[];
  optics?: OpticsValues;
  bokeh?: BokehValues;
  upright?: UprightValues;
  pointColor?: PointColorValues;
  oklch?: OkLChValues;
  blackWhite?: BlackWhiteValues;
  rawSettings?: RawPreviewSettings | null;
  geometry?: number[];
  version?: number;
  layers: LayerSnapshot[];
  activeLayerIndex: number;
  cropLeft: number;
  cropTop: number;
  cropRight: number;
  cropBottom: number;
  rotation: number;
  flipH: boolean;
  flipV: boolean;
  /** Algorithm generation; absent in sidecars written before it existed. */
  processVersion?: number;
  cropAspectRatio: number;
  selectedMaskLayerId?: string | null;
  selectedMaskComponentId?: string | null;
  lutLink?: string;
  lutPresetName?: string;
  lutStack?: LutStackSnapshot[];
}

interface LutStackSnapshot {
  id: string;
  lutId: string;
  name: string;
  sourceUri: string;
  enabled: boolean;
  intensity: number;
  /** Diagnostic persisted with the sidecar when the cloud table could not be rebuilt. */
  lutUnavailable?: boolean;
}

@Observed
export class EditSession {
  // Diagnostic identity: the editor can swap sessions across image loads and
  // VIVID_FRAME logs need to distinguish which instance rendered.
  private static nextSessionId: number = 0;
  public readonly sessionId: number = ++EditSession.nextSessionId;
  // Image data
  public processGeneration: number = 0;
  public sourcePixelMap: image.PixelMap | null = null;
  public gpuSurfaceId: string = '';
  public gpuPreviewActive: boolean = false;
  // True while the direct EGL window still holds a presented frame. The native
  // surface keeps compositing its last swapped buffer even after the ArkTS side
  // falls back to the CPU path, so a transparent clear must be swapped in once.
  public gpuSurfaceDirty: boolean = false;
  public renderViewport: number[] = [];
  public previewPixelMap: image.PixelMap | null = null;
  public imageWidth: number = 0;
  public imageHeight: number = 0;
  public previewWidth: number = 0;
  public previewHeight: number = 0;
  // Geometry-only source used by the press-and-hold "原图" comparison. The
  // old comparison bound sourcePixelMap directly, which bypassed the
  // non-destructive crop/rotation/flip pass and showed the uncropped source.
  public beforePixelMap: image.PixelMap | null = null;
  public beforePixelMapSource: image.PixelMap | null = null;
  public beforeGeometryKey: string = '';
  public beforeRenderToken: number = 0;
  // Working crop frame while the crop tool is open, normalized to the
  // DISPLAYED (already cropped/rotated) preview. It starts as the full frame
  // on every tool entry and is composed into cropLeft/Top/Right/Bottom only
  // when the user presses apply, so the preview never flashes back to the
  // uncropped original while cropping.
  public cropWorking: number[] = [0, 0, 1, 1];
  public imageUri: string = '';
  public rawSettings: RawPreviewSettings | null = null;
  public denoise: DenoiseSettings = new DenoiseSettings();
  public detail: DetailSettings = new DetailSettings();
  public optics: OpticsSettings = new OpticsSettings();
  /** 大光圈模拟参数（文档级阶段，关闭时精确旁路）。 */
  public bokeh: BokehSettings = new BokehSettings();
  /**
   * 大光圈模拟的深度图（单通道，0..255，值越大越近）。
   *
   * 不进入 sidecar：它是从当前像素重新推导的中间结果，不是编辑参数。
   * 坐标与未裁剪的源帧一致，因为该阶段发生在几何变换之前。
   */
  public bokehDepth: Uint8Array | null = null;
  public bokehDepthWidth: number = 0;
  public bokehDepthHeight: number = 0;
  public bokehDepthSourceKey: string = '';
  public upright: UprightSettings = new UprightSettings();
  public pointColor: PointColorSettings = new PointColorSettings();
  public oklch: OkLChSettings = new OkLChSettings();
  public blackWhite: BlackWhiteSettings = new BlackWhiteSettings();
  public retouchMarks: RetouchMark[] = [];
  /**
   * Which kind of mark the next retouch stroke creates.
   *
   * This is a separate axis from `activeTool`, because all four kinds are painted
   * with the same brush gesture: the tool decides that the canvas is in retouch
   * mode, and this decides what a stroke in that mode means. Keep the 去红眼 tool's
   * value in step with it so both entry points agree.
   */
  public retouchKind: string = RETOUCH_HEAL;
  public retouchSize: number = 0.025;
  public retouchFeather: number = 0.5;
  public retouchAmount: number = 0.8;
  public retouchSource: number[] = [0.65, 0.5];
  public pickingRetouchSource: boolean = false;
  // Full-resolution detail tile used only while the user is zoomed in. It is
  // deliberately separate from previewPixelMap so slider updates can keep
  // using the small cached surface without replacing the whole image.
  public detailPixelMap: image.PixelMap | null = null;
  public detailRegion: DetailRegion | null = null;
  public detailWidth: number = 0;
  public detailHeight: number = 0;
  /**
   * 整帧雾色（[r,g,b]，0..1），供放大瓦片复用；空数组表示就地估计。
   *
   * 去朦胧的雾色是整帧统计量，瓦片里自算会与整帧不同。lightcraft 把整帧 airlight
   * 显式带进窗口渲染，这里同样在请求瓦片时算一次并缓存，使瓦片与整帧一致。
   */
  public detailHaze: number[] = [];
  public detailRevision: number = 0;
  // Reference to the LUT used by the current edit. The link/name are persisted
  // in sidecars so copying edits does not silently drop the selected LUT.
  public lutLink: string = '';
  public lutPresetName: string = '';
  public lutPreset: CustomLut | null = null;
  /** Ordered LUT layers. `lutPreset` remains as a legacy bridge for old sidecars. */
  public lutStack: LutStackItem[] = [];

  // Layers (index 0 = bottom)
  public layers: Layer[] = [];
  public activeLayerIndex: number = 0;

  // UI state
  public activeTool: ToolType = ToolType.ADJUST;
  public activeCategory: AdjustmentCategory = AdjustmentCategory.LIGHT;
  // 0 edits the layer itself; 1 edits the adjustment set scoped to its mask.
  // The layer panel switches this to 1 when a masked layer is selected.
  public adjustmentScope: number = 0;
  public canvasScale: number = 1.0;
  public canvasOffsetX: number = 0;
  public canvasOffsetY: number = 0;

  // Undo/Redo
  public undoStack: string[] = []; // JSON-serialized layers snapshots
  public redoStack: string[] = [];

  // Mask cache: layerId -> alpha buffer (Uint8ClampedArray)
  public maskCache: Map<string, Uint8ClampedArray> = new Map();

  // Brush mask combination mode: 0 = 添加(并集), 1 = 擦除(删除), 2 = 交集
  public maskBrushMode: number = 0;

  // Lightroom-style mask selection state. IDs are persisted with the edit
  // session so reopening a photo returns to the same mask/component.
  public selectedMaskLayerId: string | null = null;
  public selectedMaskComponentId: string | null = null;
  // Structural mask changes need a narrow UI signal. The observed layer
  // graph is shared by several panels and ArkUI can otherwise retain a stale
  // ForEach tree until the user leaves and re-enters the editor.
  public maskRevision: number = 0;
  // Point-colour has the same problem for a different reason: the sample is
  // added by the canvas, not by the panel that owns the sliders. This counter
  // (mirrored into AppStorage) lets that panel expand and re-key the new
  // sample without rebuilding the whole editor.
  public pointColorRevision: number = 0;

  // Before/After comparison
  public showBefore: boolean = false;

  // Processing version for triggering re-renders
  public processingVersion: number = 0;
  public processingRequestVersion: number = 0;
  /** Timestamp of the most recent interactive adjustment request.  The
   * renderer uses this short quiet window to select the 512px drag preview;
   * a settled request is rendered again at the normal preview resolution. */
  public lastProcessingRequestAt: number = 0;
  // 预览更新完成后的通知（页面用它刷新模糊背景等派生资源）。
  public onPreviewUpdated: (() => void) | null = null;

  // Histogram data (256 entries each for R, G, B, L)
  public histogramR: Uint32Array = new Uint32Array(256);
  public histogramG: Uint32Array = new Uint32Array(256);
  public histogramB: Uint32Array = new Uint32Array(256);
  public histogramL: Uint32Array = new Uint32Array(256);
  public histogramVersion: number = 0;

  // Crop & Transform state
  // Crop rect in normalized image coordinates [0..1]
  public cropLeft: number = 0;
  public cropTop: number = 0;
  public cropRight: number = 1;
  public cropBottom: number = 1;
  public isCropping: boolean = false;
  public rotation: number = 0; // 0, 90, 180, 270 degrees
  public geometry: number[] = [0, 0, 0, 0, 100, 0, 0, 0];
  public flipH: boolean = false;
  public flipV: boolean = false;
  /** Pins this photo's render to an algorithm generation. Fresh sessions and
   * Reset use CURRENT; a sidecar with no field restores as LEGACY so an
   * untouched old photo keeps the look it was edited to. */
  public processVersion: number = PROCESS_VERSION_CURRENT;
  public cropAspectRatio: number = 0;
  public brushSize: number = 0.03;
  public brushHardness: number = 0.5;
  public brushFlow: number = 1;
  public brushDensity: number = 1;
  /** 画笔自动蒙版（Lightroom Auto Mask）：只在颜色相近的像素上着色。 */
  public brushAutoMask: boolean = false;
  public brushAutoMaskSensitivity: number = 0.5;

  get activeLayer(): Layer | undefined {
    return this.layers[this.activeLayerIndex];
  }

  get activeLayerMask(): MaskState | null {
    return this.activeLayer?.mask ?? null;
  }

  get activeMaskLayer(): MaskLayer | null {
    const layer = this.activeLayer;
    if (!layer) return null;
    layer.migrateMask();
    if (layer.maskLayers.length === 0) return null;
    const selected = layer.maskLayers.find((item: MaskLayer) => item.id === this.selectedMaskLayerId);
    const active = selected ?? layer.maskLayers[0];
    if (this.selectedMaskLayerId !== active.id) this.selectedMaskLayerId = active.id;
    return active;
  }

  get activeMaskComponent(): MaskComponent | null {
    const maskLayer = this.activeMaskLayer;
    if (!maskLayer || maskLayer.components.length === 0) return null;
    const selected = maskLayer.components.find((item: MaskComponent) => item.id === this.selectedMaskComponentId);
    const active = selected ?? maskLayer.components[0];
    if (this.selectedMaskComponentId !== active.id) this.selectedMaskComponentId = active.id;
    return active;
  }

  /** Embedded mask panels keep a fixed target even when layer selection
   * switches the shared editor scope back to global adjustments. */
  adjustmentsForContext(maskContext: boolean): ColorAdjustments | null {
    return maskContext ? (this.activeMaskLayer?.adjustments ?? null) : this.activeAdjustments;
  }

  get activeAdjustments(): ColorAdjustments | null {
    const layer = this.activeLayer;
    if (!layer) return null;
    if (this.adjustmentScope === 1) {
      // Scope is determined by the selected mask layer, not by hasMask().
      // hasMask() intentionally ignores disabled components for rendering, but
      // a disabled mask must still be editable without redirecting sliders to
      // the global layer adjustments.
      const maskLayer = this.activeMaskLayer;
      if (maskLayer) return maskLayer.adjustments;
      if (layer.mask !== null) return layer.maskAdjustments;
    }
    return layer.adjustments;
  }

  /**
   * Keep the editor usable even when an old or incomplete sidecar contains
   * zero layers. The adjustment panels are read-only views of this graph, so
   * they must never render against an undefined active layer.
   */
  public ensureBaseLayer(): void {
    if (this.layers.length === 0) {
      this.layers = [new Layer('背景')];
      this.activeLayerIndex = 0;
      this.adjustmentScope = 0;
      return;
    }
    if (this.activeLayerIndex < 0 || this.activeLayerIndex >= this.layers.length) {
      this.activeLayerIndex = 0;
    }
  }
  // ---- Layer operations ----

  addLayer(name?: string): void {
    this.pushUndo();
    const layerName = name ?? `图层 ${this.layers.length + 1}`;
    this.layers.push(new Layer(layerName));
    this.activeLayerIndex = this.layers.length - 1;
    this.invalidateMaskCache();
    this.bumpProcessing();
  }

  removeLayer(index: number): void {
    if (this.layers.length <= 1) return;
    this.pushUndo();
    const layer = this.layers[index];
    if (layer) {
      this.maskCache.delete(layer.id);
    }
    this.layers.splice(index, 1);
    if (this.activeLayerIndex >= this.layers.length) {
      this.activeLayerIndex = this.layers.length - 1;
    }
    this.invalidateMaskCache();
    this.bumpProcessing();
  }

  duplicateLayer(index: number): void {
    this.pushUndo();
    const src = this.layers[index];
    if (!src) return;
    const dup = src.clone();
    dup.name = src.name + ' 副本';
    this.layers.splice(index + 1, 0, dup);
    this.activeLayerIndex = index + 1;
    this.invalidateMaskCache();
    this.bumpProcessing();
  }

  reorderLayer(fromIndex: number, toIndex: number): void {
    if (fromIndex === toIndex || fromIndex < 0 || toIndex < 0) return;
    if (fromIndex >= this.layers.length || toIndex >= this.layers.length) return;
    this.pushUndo();
    const moved = this.layers.splice(fromIndex, 1)[0];
    this.layers.splice(toIndex, 0, moved);
    this.activeLayerIndex = toIndex;
    this.bumpProcessing();
  }

  // ---- Tool operations ----

  setActiveTool(tool: ToolType): void {
    this.activeTool = tool;
    // Every non-adjust tool paints/drags the image; a picker left armed behind
    // it would swallow the next tap or fire on a crop handle. Cancel here so
    // every tool entry point agrees instead of each panel remembering to.
    if (tool !== ToolType.ADJUST) this.cancelPointColorPick();
    // Keep the mark kind in step with the tool, because all four retouch kinds are
    // painted with the same gesture: entering 去红眼 must produce red-eye marks, and
    // leaving it must not leave the brush stuck on them. Handled here rather than at
    // each call site so every entry point agrees.
    if (tool === ToolType.RED_EYE) {
      this.retouchKind = 'redeye';
    } else if (this.retouchKind === 'redeye') {
      this.retouchKind = RETOUCH_HEAL;
    }
    console.info(`VIVID_FRAME t=${Date.now()} event=tool_switch sid=${this.sessionId} tool=${tool} cropping=${this.isCropping} crop=${this.cropLeft.toFixed(3)},${this.cropTop.toFixed(3)},${this.cropRight.toFixed(3)},${this.cropBottom.toFixed(3)}`);
  }

  /** Open the crop tool. The preview keeps showing the current (cropped)
   * image; the working frame always starts covering it fully. */
  enterCropMode(): void {
    this.setActiveTool(ToolType.CROP);
    this.isCropping = true;
    this.cropWorking = [0, 0, 1, 1];
  }

  // ---- Mask operations ----

  ensureActiveLayerMask(): MaskState {
    const layer = this.activeLayer;
    if (!layer) {
      return new MaskState();
    }
    if (!layer.mask || layer.mask.type === MaskType.NONE) {
      layer.mask = new MaskState();
      layer.mask.type = MaskType.BRUSH;
    }
    // Keep the new model available to the renderer for legacy callers.
    layer.migrateMask();
    const migrated = layer.firstMaskLayer;
    if (migrated) {
      this.selectedMaskLayerId = migrated.id;
      this.selectedMaskComponentId = migrated.components.length > 0 ? migrated.components[0].id : null;
    }
    return layer.mask;
  }

  /** Resolve a layer by id, independent of the current selection. */
  layerById(layerId: string): Layer | undefined {
    return this.layers.find((item: Layer): boolean => item.id === layerId);
  }

  /** Create an independent mask layer and select its first component. */
  createMaskLayer(type: MaskComponentType, blendMode: MaskBlendMode = MaskBlendMode.ADD,
    name?: string): MaskLayer | null {
    const layer = this.activeLayer;
    if (!layer) return null;
    return this.createMaskLayerOn(layer.id, type, blendMode, name);
  }

  /**
   * Create a mask layer on a SPECIFIC layer.
   *
   * Async callers (local AI segmentation) must use this form: by the time the
   * result arrives the user may have selected another layer, and creating the
   * mask through `activeLayer` would attach the result to a mask the user never
   * asked about. Returns null when the layer no longer exists.
   */
  createMaskLayerOn(layerId: string, type: MaskComponentType,
    blendMode: MaskBlendMode = MaskBlendMode.ADD, name?: string): MaskLayer | null {
    const layer = this.layerById(layerId);
    if (!layer) return null;
    this.pushUndo();
    layer.migrateMask();
    const maskName = name ?? `蒙版 ${layer.maskLayers.length + 1}`;
    const maskLayer = createMaskLayer(type, maskName, blendMode);
    // Reassign the observed collection so ArkUI invalidates ForEach rows
    // immediately. Mutating the plain array in place can leave the mask card
    // stale until the panel is rebuilt by a tab switch.
    layer.maskLayers = layer.maskLayers.concat([maskLayer]);
    if (this.activeLayer?.id === layer.id) {
      this.selectedMaskLayerId = maskLayer.id;
      this.selectedMaskComponentId = maskLayer.components[0].id;
      this.adjustmentScope = 1;
      this.syncToolToComponent(maskLayer.components[0]);
    }
    layer.touchMaskLayers();
    this.invalidateLayerMaskCache(layer.id);
    this.notifyMaskRevision();
    this.bumpProcessing();
    return maskLayer;
  }

  addMaskComponent(type: MaskComponentType, blendMode: MaskBlendMode = MaskBlendMode.ADD): MaskComponent | null {
    const layer = this.activeLayer;
    const maskLayer = this.activeMaskLayer;
    if (!layer || !maskLayer) return null;
    return this.addMaskComponentTo(layer.id, maskLayer.id, type, blendMode);
  }

  /**
   * Add a component to a SPECIFIC mask layer.
   *
   * Same rationale as `createMaskLayerOn`: the target is resolved by id, so a
   * result that arrives after the selection moved is attached to the mask that
   * was active when the operation started — never to whatever happens to be
   * selected when the await resolves. Returns null when the masked layer or the
   * mask layer is gone.
   */
  addMaskComponentTo(layerId: string, maskLayerId: string, type: MaskComponentType,
    blendMode: MaskBlendMode = MaskBlendMode.ADD): MaskComponent | null {
    const layer = this.layerById(layerId);
    if (!layer) return null;
    const maskLayer = layer.maskLayers.find((item: MaskLayer): boolean => item.id === maskLayerId);
    if (!maskLayer) return null;
    this.pushUndo();
    const component = new MaskComponent(type);
    component.blendMode = blendMode;
    // Keep the child list observable. `MaskLayer` is observed, but a raw
    // Array.push does not reliably invalidate a ForEach on device.
    maskLayer.components = maskLayer.components.concat([component]);
    maskLayer.touch();
    if (this.activeLayer?.id === layer.id) {
      this.selectedMaskLayerId = maskLayer.id;
      this.selectedMaskComponentId = component.id;
    AppStorage.setOrCreate('maskMenuOpen', false);
      this.adjustmentScope = 1;
      this.syncToolToComponent(component);
    }
    this.invalidateLayerMaskCache(layer.id);
    this.notifyMaskRevision();
    this.bumpProcessing();
    return component;
  }

  /**
   * Attach a freshly computed local-model raster to a subject/sky component.
   *
   * Returns false when the component no longer exists — the user deleted the
   * mask, switched photos or undid the creation while inference was running —
   * so the caller can drop the result instead of resurrecting a stale
   * selection onto an unrelated mask.
   */
  setMaskComponentRaster(componentId: string, origin: string, key: string,
    width: number, height: number, alpha: Uint8Array, bump: boolean = true): boolean {
    const layer = this.activeLayer;
    if (!layer) return false;
    return this.setMaskComponentRasterFor(layer.id, componentId, origin, key, width, height, alpha, bump);
  }

  /** `setMaskComponentRaster` bound to an explicit layer id. */
  setMaskComponentRasterFor(layerId: string, componentId: string, origin: string, key: string,
    width: number, height: number, alpha: Uint8Array, bump: boolean = true): boolean {
    const layer = this.layerById(layerId);
    if (!layer || width <= 0 || height <= 0 || alpha.length < width * height) return false;
    let target: MaskComponent | null = null;
    for (let layerIndex = 0; layerIndex < layer.maskLayers.length && target === null; layerIndex++) {
      const maskLayer = layer.maskLayers[layerIndex];
      for (let index = 0; index < maskLayer.components.length; index++) {
        if (maskLayer.components[index].id === componentId) {
          target = maskLayer.components[index];
          break;
        }
      }
    }
    if (target === null) return false;
    const data = new MaskRaster();
    data.origin = origin;
    data.key = key;
    data.width = width;
    data.height = height;
    data.alpha = alpha;
    target.raster = data;
    this.invalidateLayerMaskCache(layer.id);
    this.notifyMaskRevision();
    // 拖动锚点时每 120ms 重算一次：如果每次都叫醒预览重算，
    // 预览图像会在重建期间黑屏一下（也就是用户看到的黑帧）。
    // 只需要蒙版覆盖层跟着变，松手时再统一重算一次预览。
    if (bump) this.bumpProcessing();
    return true;
  }

  /** True when a component is backed by a stored raster rather than geometry. */
  isRasterMaskComponent(component: MaskComponent): boolean {
    return isRasterComponentType(component.type);
  }

  selectMaskLayer(maskLayerId: string): void {
    const maskLayer = this.activeLayer?.maskLayers.find((item: MaskLayer) => item.id === maskLayerId);
    if (!maskLayer) return;
    this.adjustmentScope = 1;
    // Child row clicks bubble to the card. Keep the selected subtract
    // component instead of silently jumping back to the first additive one.
    if (this.selectedMaskLayerId === maskLayerId) return;
    this.selectedMaskLayerId = maskLayer.id;
    this.selectedMaskComponentId = maskLayer.components.length > 0 ? maskLayer.components[0].id : null;
    AppStorage.setOrCreate('maskMenuOpen', false);
    if (maskLayer.components.length > 0) this.syncToolToComponent(maskLayer.components[0]);
    this.notifyMaskRevision();
  }

  selectMaskComponent(componentId: string): void {
    const maskLayer = this.activeMaskLayer;
    const component = maskLayer?.components.find((item: MaskComponent) => item.id === componentId);
    if (!component) return;
    this.adjustmentScope = 1;
    this.selectedMaskComponentId = component.id;
    AppStorage.setOrCreate('maskMenuOpen', false);
    const selectStart = Date.now();
    this.syncToolToComponent(component);
    const afterTool = Date.now();
    this.notifyMaskRevision();
    console.info(`VIVID_PERF event=mask_select tool=${afterTool - selectStart} ` +
      `revision=${Date.now() - afterTool} comps=${maskLayer !== null ? maskLayer.components.length : -1}`);
  }

  // ---- LUT stack operations ----

  addLutLayer(lut: CustomLut): LutStackItem {
    const item = createLutStackItem(lut, 1);
    this.lutStack = this.lutStack.concat([item]);
    this.syncLegacyLut(lut);
    this.bumpProcessing();
    return item;
  }

  replaceLutLayer(index: number, lut: CustomLut | null): void {
    if (index < 0 || index >= this.lutStack.length) return;
    if (!lut) {
      this.lutStack = this.lutStack.map((item: LutStackItem, i: number) => {
        if (i !== index) return item;
        const cleared: LutStackItem = {
          id: item.id, lutId: '', name: '无 LUT', sourceUri: '', enabled: item.enabled,
          intensity: item.intensity, lut: null,
        };
        return cleared;
      });
      // Keep the legacy single-LUT fields consistent with the ordered stack.
      // Otherwise a v1 sidecar can resurrect the LUT that was just bypassed
      // when the image is reopened before the catalog finishes loading.
      this.syncLegacyFromStack();
    } else {
      const current = this.lutStack[index];
      const next: LutStackItem = {
        id: current.id,
        lutId: lut.id,
        name: lut.name,
        sourceUri: lut.sourceUri,
        enabled: current.enabled,
        intensity: current.intensity,
        lut: lut,
      };
      this.lutStack = this.lutStack.map((item: LutStackItem, i: number) => i === index ? next : item);
      this.syncLegacyLut(lut);
    }
    this.bumpProcessing();
  }

  removeLutLayer(index: number): void {
    if (index < 0 || index >= this.lutStack.length) return;
    this.lutStack = this.lutStack.filter((_: LutStackItem, i: number) => i !== index);
    this.syncLegacyFromStack();
    this.bumpProcessing();
  }

  moveLutLayer(index: number, offset: number): void {
    const target = Math.max(0, Math.min(this.lutStack.length - 1, index + offset));
    if (target === index || index < 0 || index >= this.lutStack.length) return;
    const next = this.lutStack.slice();
    const moved = next.splice(index, 1)[0];
    next.splice(target, 0, moved);
    this.lutStack = next;
    this.bumpProcessing();
  }

  setLutEnabled(index: number, enabled: boolean): void {
    const item = this.lutStack[index];
    if (!item) return;
    item.enabled = enabled;
    this.lutStack = this.lutStack.slice();
    this.bumpProcessing();
  }

  setLutIntensity(index: number, intensity: number): void {
    const item = this.lutStack[index];
    if (!item) return;
    item.intensity = Math.max(0, Math.min(1, intensity));
    this.lutStack = this.lutStack.slice();
  }

  /**
   * Reconnect LUT stack entries restored from a sidecar to the asynchronously
   * loaded catalog.  A sidecar intentionally stores only the stable id/URI;
   * when the editor opens before bundled LUT parsing finishes, the entry has
   * no table and the renderer must skip it.  Rebinding also replaces stale
   * placeholder objects whose table was filled later in the catalog.
   */
  resolveLutLayers(entries: CustomLut[]): boolean {
    if (entries.length === 0) return false;
    // Version 1 sidecars stored only one legacy link and therefore restored
    // with an empty stack when the catalog was still loading. Recreate that
    // layer as soon as its parsed table becomes available.
    if (this.lutStack.length === 0 && this.lutLink.length > 0) {
      const legacy = entries.find((candidate: CustomLut): boolean =>
        candidate.id === this.lutLink || candidate.sourceUri === this.lutLink ||
        candidate.name === this.lutPresetName);
      if (legacy?.table && legacy.table.values.length >= 3) {
        this.lutStack = [createLutStackItem(legacy, 1)];
        this.syncLegacyLut(legacy);
        this.bumpProcessing();
        return true;
      }
      return false;
    }
    if (this.lutStack.length === 0) return false;
    let changed = false;
    let legacy: CustomLut | null = null;
    const next = this.lutStack.map((item: LutStackItem): LutStackItem => {
      const current = item.lut;
      if (current?.table && current.table.values.length >= 3) {
        if (!legacy) legacy = current;
        return item;
      }
      const found = entries.find((candidate: CustomLut): boolean =>
        candidate.id === item.lutId ||
        candidate.sourceUri === item.sourceUri ||
        candidate.name === item.name);
      if (!found || !found.table || found.table.values.length < 3) return item;
      changed = true;
      if (!legacy) legacy = found;
      return {
        id: item.id,
        lutId: found.id,
        name: found.name,
        sourceUri: found.sourceUri,
        enabled: item.enabled,
        intensity: item.intensity,
        lut: found,
      };
    });
    if (!changed) return false;
    this.lutStack = next;
    if (legacy) this.syncLegacyLut(legacy);
    this.bumpProcessing();
    return true;
  }

  private syncLegacyLut(lut: CustomLut): void {
    this.lutPreset = lut;
    this.lutLink = lut.sourceUri;
    this.lutPresetName = lut.name;
  }

  private syncLegacyFromStack(): void {
    const active = this.lutStack.find((item: LutStackItem): boolean =>
      item.enabled && item.intensity > 0 && item.lut?.table !== null && item.lut?.table !== undefined);
    if (active?.lut) {
      this.syncLegacyLut(active.lut);
    } else {
      this.lutPreset = null;
      this.lutLink = '';
      this.lutPresetName = '';
    }
  }

  deleteMaskComponent(componentId: string): void {
    const layer = this.activeLayer;
    const maskLayer = this.activeMaskLayer;
    if (!layer || !maskLayer) return;
    const index = maskLayer.components.findIndex((item: MaskComponent) => item.id === componentId);
    if (index < 0) return;
    this.pushUndo();
    maskLayer.components = maskLayer.components.filter((item: MaskComponent) => item.id !== componentId);
    maskLayer.touch();
    this.selectedMaskComponentId = maskLayer.components.length > 0 ?
      maskLayer.components[Math.max(0, index - 1)].id : null;
    this.invalidateLayerMaskCache(layer.id);
    this.notifyMaskRevision();
    this.bumpProcessing();
  }

  deleteMaskLayer(maskLayerId: string): void {
    const layer = this.activeLayer;
    if (!layer) return;
    const index = layer.maskLayers.findIndex((item: MaskLayer) => item.id === maskLayerId);
    if (index < 0) return;
    this.pushUndo();
    layer.maskLayers = layer.maskLayers.filter((item: MaskLayer) => item.id !== maskLayerId);
    const selected = layer.maskLayers[Math.max(0, index - 1)];
    this.selectedMaskLayerId = selected?.id ?? null;
    this.selectedMaskComponentId = selected && selected.components.length > 0 ? selected.components[0].id : null;
    this.invalidateLayerMaskCache(layer.id);
    this.notifyMaskRevision();
    this.bumpProcessing();
  }

  duplicateMaskLayer(maskLayerId: string, invertCopy: boolean = false): MaskLayer | null {
    const layer = this.activeLayer;
    const source = layer?.maskLayers.find((item: MaskLayer) => item.id === maskLayerId);
    if (!layer || !source) return null;
    this.pushUndo();
    const copy = source.clone();
    copy.name = source.name + (invertCopy ? ' 副本（反向）' : ' 副本');
    // Flip the composed coverage, preserving every component and adjustment.
    // Apply this before publishing so copy-and-invert is one undoable action.
    if (invertCopy) copy.inverted = !source.inverted;
    copy.id = 'msk_' + Date.now().toString(36) + '_' + Math.random().toString(36).substring(2, 8);
    copy.components = copy.components.map((component: MaskComponent) => {
      const cloned = component.clone();
      cloned.id = 'cmp_' + Date.now().toString(36) + '_' + Math.random().toString(36).substring(2, 8);
      return cloned;
    });
    const index = layer.maskLayers.indexOf(source);
    layer.maskLayers.splice(index + 1, 0, copy);
    this.selectedMaskLayerId = copy.id;
    this.selectedMaskComponentId = copy.components.length > 0 ? copy.components[0].id : null;
    this.invalidateLayerMaskCache(layer.id);
    this.notifyMaskRevision();
    this.bumpProcessing();
    return copy;
  }

  renameMaskLayer(maskLayerId: string, name: string): void {
    const layer = this.activeLayer;
    const maskLayer = layer?.maskLayers.find((item: MaskLayer) => item.id === maskLayerId);
    const nextName = name.trim();
    if (!layer || !maskLayer || nextName.length === 0 || maskLayer.name === nextName) return;
    this.pushUndo();
    maskLayer.name = nextName;
    maskLayer.touch();
    layer.touchMaskLayers();
    this.notifyMaskRevision();
    this.bumpProcessing();
  }

  reorderMaskLayer(fromIndex: number, toIndex: number): void {
    const layer = this.activeLayer;
    if (!layer || fromIndex < 0 || toIndex < 0 || fromIndex >= layer.maskLayers.length ||
      toIndex >= layer.maskLayers.length || fromIndex === toIndex) return;
    this.pushUndo();
    const moved = layer.maskLayers.splice(fromIndex, 1)[0];
    layer.maskLayers.splice(toIndex, 0, moved);
    this.invalidateLayerMaskCache(layer.id);
    this.notifyMaskRevision();
    this.bumpProcessing();
  }

  moveMaskLayer(maskLayerId: string, offset: number): void {
    const layer = this.activeLayer;
    if (!layer || offset === 0) return;
    const index = layer.maskLayers.findIndex((item: MaskLayer) => item.id === maskLayerId);
    if (index < 0) return;
    const target = Math.max(0, Math.min(layer.maskLayers.length - 1, index + offset));
    this.reorderMaskLayer(index, target);
  }

  /** Notify mask editors without forcing the entire editor tree to rebuild. */
  notifyMaskRevision(): void {
    this.maskRevision++;
    AppStorage.setOrCreate('maskRevision', this.maskRevision);
  }

  /**
   * Arm the point-colour eyedropper: the next tap on the canvas adds a sample.
   *
   * Nothing is added here. The previous "添加颜色" button called addHsl with a
   * hard-coded red; users asked for the tap-on-photo workflow instead, so this
   * only flips the mode and the canvas performs the actual sample.
   */
  beginPointColorPick(): boolean {
    if (!this.sourcePixelMap) return false;
    const started = this.pointColor.beginPick();
    if (started) {
      console.info(`VIVID_POINT_COLOR t=${Date.now()} event=pick_arm sid=${this.sessionId} ` +
        `samples=${this.pointColor.samples.length}`);
      this.notifyPointColorRevision();
    }
    return started;
  }

  /** Leave picking mode without adding anything (button toggled, panel left,
   *  sample deleted, tool switched, photo opened). Idempotent. */
  cancelPointColorPick(): void {
    if (!this.pointColor.picking) return;
    this.pointColor.cancelPick();
    console.info(`VIVID_POINT_COLOR t=${Date.now()} event=pick_cancel sid=${this.sessionId} ` +
      `samples=${this.pointColor.samples.length}`);
    this.notifyPointColorRevision();
  }

  /**
   * Read the real source pixel under a normalized SOURCE point and add it.
   *
   * The point is the output of displayPointToSource, so crop, rotation, flip
   * and the manual geometry pass are already undone — this is the same mapping
   * the brush, retouch and white-balance sampling use. The source PixelMap is
   * captured before the await and re-checked after it: a photo switch, a reset
   * or a cancellation while the read is in flight must not append a sample to
   * the wrong image or to a mode the user already left.
   */
  async pickPointColorAt(sourceX: number, sourceY: number): Promise<boolean> {
    const settings = this.pointColor;
    if (!settings.picking) return false;
    const source = this.sourcePixelMap;
    if (!source) {
      this.cancelPointColorPick();
      return false;
    }
    const generation = this.processGeneration;
    const rgb = await PointColorPicker.samplePixel(source, sourceX, sourceY);
    if (this.processGeneration !== generation || this.sourcePixelMap !== source) return false;
    // Undo/reset can replace the whole PointColorSettings object while the read
    // is in flight. Writing into the captured object would append a sample to a
    // list the user is no longer editing, so require the live object to be the
    // same one and still armed.
    if (this.pointColor !== settings || !settings.picking) return false;
    if (rgb === null) {
      // Tap landed on the margin or the read failed: stay armed so the next tap
      // works, and refresh the hint rather than silently doing nothing.
      this.notifyPointColorRevision();
      return false;
    }
    console.info(`VIVID_POINT_COLOR t=${Date.now()} event=pick_pixel sid=${this.sessionId} ` +
      `x=${sourceX.toFixed(4)} y=${sourceY.toFixed(4)} r=${rgb[0]} g=${rgb[1]} b=${rgb[2]}`);
    this.pushUndo();
    const added = settings.addPickedSample(rgb[0], rgb[1], rgb[2]);
    this.notifyPointColorRevision();
    return added;
  }

  /** Point-colour state changed outside the panel (canvas pick, cancel, tool
   *  switch); the panel keys its ForEach on this narrow signal. */
  notifyPointColorRevision(): void {
    this.pointColorRevision++;
    AppStorage.setOrCreate('pointColorRevision', this.pointColorRevision);
  }

  private syncToolToComponent(component: MaskComponent): void {
    if (component.type === MaskComponentType.BRUSH) {
      // A subtract component stores positive brush coverage, then the layer
      // subtracts it once. Do not inherit eraser mode from the previous brush.
      this.maskBrushMode = 0;
      this.setActiveTool(ToolType.BRUSH_MASK);
    }
    else if (component.type === MaskComponentType.LINEAR_GRADIENT) this.setActiveTool(ToolType.LINEAR_MASK);
    // 亮度/颜色范围、主体、天空都是算法生成的选区，拖图不应该再画出径向蒙版。
    else if (component.type === MaskComponentType.RANGE || component.type === MaskComponentType.SUBJECT ||
      component.type === MaskComponentType.SKY) this.setActiveTool(ToolType.ADJUST);
    else this.setActiveTool(ToolType.RADIAL_MASK);
  }

  /** Return the currently edited linear component, creating the legacy first
   * component lazily so older sidecars remain fully compatible. */
  ensureActiveLinearPart(): LinearMaskPart {
    const mask = this.ensureActiveLayerMask();
    if (mask.linearParts.length === 0) {
      const first = new LinearMaskPart();
      first.operation = 0;
      first.params.startX = mask.linearGradient.startX;
      first.params.startY = mask.linearGradient.startY;
      first.params.endX = mask.linearGradient.endX;
      first.params.endY = mask.linearGradient.endY;
      first.params.feather = mask.linearGradient.feather;
      mask.linearParts.push(first);
    }
    if (mask.activeLinearIndex < 0 || mask.activeLinearIndex >= mask.linearParts.length) {
      mask.activeLinearIndex = mask.linearParts.length - 1;
    }
    return mask.linearParts[mask.activeLinearIndex];
  }

  /** Add a new linear mask component. A component is immediately active so
   * dragging on the canvas edits the newly added gradient. */
  addLinearMask(operation: number = 0): void {
    const mask = this.ensureActiveLayerMask();
    this.pushUndo();
    mask.type = MaskType.LINEAR_GRADIENT;
    this.ensureActiveLinearPart();
    const part = new LinearMaskPart();
    part.operation = operation === 1 ? 1 : 0;
    // Start a new component at a predictable, in-bounds vertical gradient.
    part.params.startX = 0.5;
    part.params.startY = 0.08;
    part.params.endX = 0.5;
    part.params.endY = 0.92;
    part.params.feather = 0.25;
    mask.linearParts.push(part);
    mask.activeLinearIndex = mask.linearParts.length - 1;
    this.invalidateLayerMaskCache(this.activeLayer!.id);
    this.bumpProcessing();
  }

  clearActiveLayerMask(): void {
    const layer = this.activeLayer;
    if (!layer) return;
    this.pushUndo();
    if (layer.maskLayers.length > 0) {
      const maskLayer = this.activeMaskLayer;
      if (maskLayer) {
        maskLayer.components = [];
        maskLayer.touch();
      }
      this.selectedMaskComponentId = null;
    }
    layer.mask = null;
    this.invalidateMaskCache();
    this.bumpProcessing();
  }

  invertActiveLayerMask(): void {
    const component = this.activeMaskComponent;
    if (component) {
      this.pushUndo();
      component.inverted = !component.inverted;
      this.invalidateLayerMaskCache(this.activeLayer?.id ?? '');
      this.bumpProcessing();
      return;
    }
    const mask = this.activeLayerMask;
    if (!mask || mask.type === MaskType.NONE) return;
    this.pushUndo();
    mask.invert = !mask.invert;
    this.invalidateMaskCache();
    this.bumpProcessing();
  }

  // ---- History ----

  /** Export the non-destructive edit state for an XML sidecar file. */
  public exportAdjustmentState(): string {
    const snapshot = JSON.parse(this.createSnapshot()) as SessionSnapshot;
    snapshot.version = 3;
    snapshot.rawSettings = this.rawSettings ? {
      profile: this.rawSettings.profile, kelvin: this.rawSettings.kelvin, tint: this.rawSettings.tint,
    } : null;
    return JSON.stringify(snapshot);
  }

  public setRawSettings(settings: RawPreviewSettings | null): void {
    if (!settings || typeof settings.profile !== 'string' ||
      !Number.isFinite(settings.kelvin) || !Number.isFinite(settings.tint)) {
      this.rawSettings = null;
      return;
    }
    this.rawSettings = { profile: settings.profile,
      kelvin: settings.kelvin === 0 ? 0 : Math.max(2000, Math.min(12000, settings.kelvin)),
      tint: Math.max(-100, Math.min(100, settings.tint)) };
  }

  /** Restore a sidecar snapshot and clear transient undo/redo history. */
  public importAdjustmentState(serialized: string): boolean {
    try {
      const parsed = JSON.parse(serialized) as SessionSnapshot;
      if (!parsed || !(parsed.layers instanceof Array)) return false;
      this.restoreLayersFromSnapshot(serialized);
      for (const layer of this.layers) {
        layer.adjustments.migrateLegacyDefaultCurves();
        layer.maskAdjustments.migrateLegacyDefaultCurves();
        for (const maskLayer of layer.maskLayers) maskLayer.adjustments.migrateLegacyDefaultCurves();
      }
      this.setRawSettings(parsed.rawSettings ?? null);
      this.undoStack = [];
      this.redoStack = [];
      this.invalidateMaskCache();
      this.bumpProcessing();
      return true;
    } catch (_error) {
      return false;
    }
  }

  pushUndo(): void {
    const snapshot = this.createSnapshot();
    this.undoStack.push(snapshot);
    // 动作记录只保留最近 20 步。
    if (this.undoStack.length > 20) {
      this.undoStack.shift();
    }
    this.redoStack = [];
  }

  private createSnapshot(): string {
    for (const layer of this.layers) layer.migrateMask();
    const snapshot: SessionSnapshot = {
      retouchMarks: cloneRetouchMarks(this.retouchMarks),
      denoise: this.denoise.clone(),
      detail: this.detail.clone(),
      detailHaze: this.detailHaze.slice(),
      optics: this.optics.clone(),
      bokeh: this.bokeh.clone(),
      upright: this.upright.clone(),
      pointColor: this.pointColor.clone(),
      oklch: this.oklch.clone(),
      blackWhite: this.blackWhite.clone(),
      version: 2,
      layers: this.layers.map((l: Layer): LayerSnapshot => ({
      id: l.id,
      name: l.name,
      visible: l.visible,
      opacity: l.opacity,
      blendMode: l.blendMode,
      adjustments: this.serializeAdjustments(l.adjustments),
      maskAdjustments: this.serializeAdjustments(l.maskAdjustments),
      mask: l.mask ? l.mask.clone() : null,
      maskLayers: l.maskLayers.map((maskLayer: MaskLayer) => this.serializeMaskLayer(maskLayer)),
    })),
      activeLayerIndex: this.activeLayerIndex,
      cropLeft: this.cropLeft,
      cropTop: this.cropTop,
      cropRight: this.cropRight,
      cropBottom: this.cropBottom,
      rotation: this.rotation,
      geometry: this.geometry.slice(),
      flipH: this.flipH,
      flipV: this.flipV,
      processVersion: this.processVersion,
      cropAspectRatio: this.cropAspectRatio,
      selectedMaskLayerId: this.selectedMaskLayerId,
      selectedMaskComponentId: this.selectedMaskComponentId,
      lutLink: this.lutLink,
      lutPresetName: this.lutPresetName,
      lutStack: this.lutStack.map((item: LutStackItem): LutStackSnapshot => ({
        id: item.id,
        lutId: item.lutId,
        name: item.name,
        sourceUri: item.sourceUri,
        enabled: item.enabled,
        intensity: item.intensity,
        lutUnavailable: item.lutUnavailable === true,
      })),
    };
    return JSON.stringify(snapshot);
  }

  private serializeAdjustments(adj: ColorAdjustments): LayerSnapshotAdjustments {
    return {
      exposure: adj.exposure,
      contrast: adj.contrast,
      brightness: adj.brightness,
      highlights: adj.highlights,
      shadows: adj.shadows,
      whites: adj.whites,
      blacks: adj.blacks,
      vignetteAmount: adj.vignetteAmount,
      vignetteMidpoint: adj.vignetteMidpoint,
      vignetteRoundness: adj.vignetteRoundness,
      vignetteFeather: adj.vignetteFeather,
      vignetteHighlights: adj.vignetteHighlights,
      grainAmount: adj.grainAmount,
      grainSize: adj.grainSize,
      grainRoughness: adj.grainRoughness,
      saturation: adj.saturation,
      vibrance: adj.vibrance,
      temperature: adj.temperature,
      tint: adj.tint,
      hue: adj.hue,
      toneCurve: adj.toneCurve,
      curveRed: adj.curveRed,
      curveGreen: adj.curveGreen,
      curveBlue: adj.curveBlue,
      toneCurvePoints: adj.toneCurvePoints.map((point: CurveAnchor) => point.clone()),
      redCurvePoints: adj.redCurvePoints.map((point: CurveAnchor) => point.clone()),
      greenCurvePoints: adj.greenCurvePoints.map((point: CurveAnchor) => point.clone()),
      blueCurvePoints: adj.blueCurvePoints.map((point: CurveAnchor) => point.clone()),
      parametricHighlights: adj.parametricHighlights,
      parametricLights: adj.parametricLights,
      parametricDarks: adj.parametricDarks,
      parametricShadows: adj.parametricShadows,
      parametricShadowSplit: adj.parametricShadowSplit,
      parametricDarkSplit: adj.parametricDarkSplit,
      parametricLightSplit: adj.parametricLightSplit,
      parametricRefineSaturation: adj.parametricRefineSaturation,
      mixHue: adj.mixHue.slice(),
      mixSaturation: adj.mixSaturation.slice(),
      mixLuminance: adj.mixLuminance.slice(),
      calibrationRedHue: adj.calibrationRedHue,
      calibrationRedSaturation: adj.calibrationRedSaturation,
      calibrationGreenHue: adj.calibrationGreenHue,
      calibrationGreenSaturation: adj.calibrationGreenSaturation,
      calibrationBlueHue: adj.calibrationBlueHue,
      calibrationBlueSaturation: adj.calibrationBlueSaturation,
      colorGradingEnabled: adj.colorGradingEnabled,
      gradingShadowsHue: adj.gradingShadowsHue,
      gradingShadowsSaturation: adj.gradingShadowsSaturation,
      gradingShadowsLuminance: adj.gradingShadowsLuminance,
      gradingMidtonesHue: adj.gradingMidtonesHue,
      gradingMidtonesSaturation: adj.gradingMidtonesSaturation,
      gradingMidtonesLuminance: adj.gradingMidtonesLuminance,
      gradingHighlightsHue: adj.gradingHighlightsHue,
      gradingHighlightsSaturation: adj.gradingHighlightsSaturation,
      gradingHighlightsLuminance: adj.gradingHighlightsLuminance,
      gradingGlobalHue: adj.gradingGlobalHue,
      gradingGlobalSaturation: adj.gradingGlobalSaturation,
      gradingGlobalLuminance: adj.gradingGlobalLuminance,
      gradingBlending: adj.gradingBlending,
      gradingBalance: adj.gradingBalance,
    };
  }

  private restoreAdjustments(adj: ColorAdjustments, saved: LayerSnapshotAdjustments): void {
    adj.exposure = saved.exposure;
    adj.contrast = saved.contrast;
    adj.brightness = saved.brightness;
    adj.highlights = saved.highlights;
    adj.shadows = saved.shadows;
    adj.whites = saved.whites;
    adj.blacks = saved.blacks;
    adj.vignetteAmount = saved.vignetteAmount ?? 0;
    adj.vignetteMidpoint = saved.vignetteMidpoint ?? 0.5;
    adj.vignetteRoundness = saved.vignetteRoundness ?? 0;
    adj.vignetteFeather = saved.vignetteFeather ?? 0.8;
    adj.vignetteHighlights = saved.vignetteHighlights ?? 0;
    adj.grainAmount = saved.grainAmount ?? 0;
    adj.grainSize = saved.grainSize ?? 0.5;
    adj.grainRoughness = saved.grainRoughness ?? 0.5;
    adj.saturation = saved.saturation;
    adj.vibrance = saved.vibrance;
    adj.temperature = saved.temperature;
    adj.tint = saved.tint;
    adj.hue = saved.hue;
    adj.toneCurve = saved.toneCurve ?? 0;
    adj.curveRed = saved.curveRed ?? 0;
    adj.curveGreen = saved.curveGreen ?? 0;
    adj.curveBlue = saved.curveBlue ?? 0;
    adj.toneCurvePoints = this.restoreCurvePoints(saved.toneCurvePoints);
    adj.redCurvePoints = this.restoreCurvePoints(saved.redCurvePoints);
    adj.greenCurvePoints = this.restoreCurvePoints(saved.greenCurvePoints);
    adj.blueCurvePoints = this.restoreCurvePoints(saved.blueCurvePoints);
    // Splits and refinement default to their identity values, not to zero:
    // a zero refinement would silently desaturate every older sidecar.
    adj.parametricHighlights = saved.parametricHighlights ?? 0;
    adj.parametricLights = saved.parametricLights ?? 0;
    adj.parametricDarks = saved.parametricDarks ?? 0;
    adj.parametricShadows = saved.parametricShadows ?? 0;
    adj.parametricShadowSplit = saved.parametricShadowSplit ?? 0.25;
    adj.parametricDarkSplit = saved.parametricDarkSplit ?? 0.5;
    adj.parametricLightSplit = saved.parametricLightSplit ?? 0.75;
    adj.parametricRefineSaturation = saved.parametricRefineSaturation ?? 1;
    adj.mixHue = saved.mixHue ? saved.mixHue.slice() : [0, 0, 0, 0, 0, 0, 0, 0];
    adj.mixSaturation = saved.mixSaturation ? saved.mixSaturation.slice() : [0, 0, 0, 0, 0, 0, 0, 0];
    adj.mixLuminance = saved.mixLuminance ? saved.mixLuminance.slice() : [0, 0, 0, 0, 0, 0, 0, 0];
    adj.calibrationRedHue = saved.calibrationRedHue ?? 0;
    adj.calibrationRedSaturation = saved.calibrationRedSaturation ?? 0;
    adj.calibrationGreenHue = saved.calibrationGreenHue ?? 0;
    adj.calibrationGreenSaturation = saved.calibrationGreenSaturation ?? 0;
    adj.calibrationBlueHue = saved.calibrationBlueHue ?? 0;
    adj.calibrationBlueSaturation = saved.calibrationBlueSaturation ?? 0;
    adj.colorGradingEnabled = saved.colorGradingEnabled ?? true;
    adj.gradingShadowsHue = saved.gradingShadowsHue ?? 0;
    adj.gradingShadowsSaturation = saved.gradingShadowsSaturation ?? 0;
    adj.gradingShadowsLuminance = saved.gradingShadowsLuminance ?? 0;
    adj.gradingMidtonesHue = saved.gradingMidtonesHue ?? 0;
    adj.gradingMidtonesSaturation = saved.gradingMidtonesSaturation ?? 0;
    adj.gradingMidtonesLuminance = saved.gradingMidtonesLuminance ?? 0;
    adj.gradingHighlightsHue = saved.gradingHighlightsHue ?? 0;
    adj.gradingHighlightsSaturation = saved.gradingHighlightsSaturation ?? 0;
    adj.gradingHighlightsLuminance = saved.gradingHighlightsLuminance ?? 0;
    adj.gradingGlobalHue = saved.gradingGlobalHue ?? 0;
    adj.gradingGlobalSaturation = saved.gradingGlobalSaturation ?? 0;
    adj.gradingGlobalLuminance = saved.gradingGlobalLuminance ?? 0;
    adj.gradingBlending = saved.gradingBlending ?? 0;
    adj.gradingBalance = saved.gradingBalance ?? 0;
  }

  private serializeMaskLayer(maskLayer: MaskLayer): MaskLayerSnapshot {
    return {
      id: maskLayer.id,
      name: maskLayer.name,
      enabled: maskLayer.enabled,
      visible: maskLayer.visible,
      opacity: maskLayer.opacity,
      createdAt: maskLayer.createdAt,
      inverted: maskLayer.inverted,
      updatedAt: maskLayer.updatedAt,
      adjustments: this.serializeAdjustments(maskLayer.adjustments),
      components: maskLayer.components.map((component: MaskComponent): MaskComponentSnapshot => {
        component.ensureData();
        const linear = component.linearGradientData ? [component.linearGradientData.startX,
          component.linearGradientData.startY, component.linearGradientData.endX,
          component.linearGradientData.endY] : [];
        const radial = component.radialGradientData ? [component.radialGradientData.centerX,
          component.radialGradientData.centerY, component.radialGradientData.radiusX,
          component.radialGradientData.radiusY, component.radialGradientData.rotation] : [];
        const snapshot: MaskComponentSnapshot = {
          id: component.id,
          renderingVersion: component.renderingVersion,
          type: component.type,
          blendMode: component.blendMode,
          enabled: component.enabled,
          visible: component.visible,
          inverted: component.inverted,
          opacity: component.opacity,
          feather: component.feather,
          brushStrokes: component.brushData ? component.brushData.strokes : [],
          linear: linear,
          radial: radial,
        };
        // Persisting the raster is what makes a subject/sky/range selection
        // survive a reopen without re-running inference or re-reading the source,
        // and keeps export identical to the preview even when the model assets
        // or the source proxy change later.
        const raster = component.raster;
        if (raster && raster.hasAlpha) {
          snapshot.rasterOrigin = raster.origin;
          snapshot.rasterKey = raster.key;
          snapshot.rasterWidth = raster.width;
          snapshot.rasterHeight = raster.height;
          snapshot.rasterAlpha = new util.Base64Helper().encodeToStringSync(
            raster.alpha.subarray(0, raster.width * raster.height));
        }
        if (component.rangeData) {
          const range = component.rangeData;
          snapshot.range = [range.min, range.max, range.smoothness,
            range.colorEnabled ? 1 : 0, range.colorR, range.colorG, range.colorB, range.colorAmount];
        }
        return snapshot;
      }),
    };
  }

  undo(): void {
    const snapshot = this.undoStack.pop();
    if (!snapshot) return;
    this.redoStack.push(this.createSnapshot());
    console.info(`VIVID_FRAME t=${Date.now()} event=undo sid=${this.sessionId} depth=${this.undoStack.length}`);
    this.restoreLayersFromSnapshot(snapshot);
    this.invalidateMaskCache();
    this.bumpProcessing();
  }

  redo(): void {
    const snapshot = this.redoStack.pop();
    if (!snapshot) return;
    this.undoStack.push(this.createSnapshot());
    console.info(`VIVID_FRAME t=${Date.now()} event=redo sid=${this.sessionId}`);
    this.restoreLayersFromSnapshot(snapshot);
    this.invalidateMaskCache();
    this.bumpProcessing();
  }

  canUndo(): boolean {
    return this.undoStack.length > 0;
  }

  canRedo(): boolean {
    return this.redoStack.length > 0;
  }

  private restoreLayersFromSnapshot(snapshot: string): void {
    try {
      const data = JSON.parse(snapshot) as SessionSnapshot;
      this.retouchMarks = cloneRetouchMarks(data.retouchMarks);
      this.denoise = DenoiseSettings.restore(data.denoise);
      this.detail = DetailSettings.restore(data.detail);
      this.optics = OpticsSettings.restore(data.optics);
      this.bokeh = BokehSettings.restore(data.bokeh);
      this.upright = UprightSettings.restore(data.upright);
      this.pointColor = PointColorSettings.restore(data.pointColor);
      this.oklch = OkLChSettings.restore(data.oklch);
      this.blackWhite = BlackWhiteSettings.restore(data.blackWhite);
      const restored: Layer[] = [];
      for (let i = 0; i < data.layers.length; i++) {
        const saved = data.layers[i];
        const layer = new Layer(saved.name, saved.id);
        layer.visible = saved.visible;
        layer.opacity = saved.opacity;
        layer.blendMode = saved.blendMode;
        // Restore adjustment values
        this.restoreAdjustments(layer.adjustments, saved.adjustments);
        if (saved.maskAdjustments) {
          this.restoreAdjustments(layer.maskAdjustments, saved.maskAdjustments);
        }
        if (saved.maskLayers && saved.maskLayers.length > 0) {
          layer.maskLayers = saved.maskLayers.map((maskLayer: MaskLayerSnapshot) => this.restoreMaskLayer(maskLayer));
        } else {
          layer.mask = this.restoreMask(saved.mask);
          layer.migrateMask();
        }
        restored.push(layer);
      }
      // A truncated or old sidecar may parse but contain no layers.
      // Keep one editable base layer so the PC basic-adjustment panel always
      // has a concrete target instead of rendering an empty state.
      this.layers = restored.length > 0 ? restored : [new Layer('背景')];
      this.activeLayerIndex = data.activeLayerIndex ?? 0;
      if (this.activeLayerIndex < 0 || this.activeLayerIndex >= this.layers.length) {
        this.activeLayerIndex = 0;
      }
      this.cropLeft = data.cropLeft ?? 0;
      this.cropTop = data.cropTop ?? 0;
      this.cropRight = data.cropRight ?? 1;
      this.cropBottom = data.cropBottom ?? 1;
      this.rotation = data.rotation ?? 0;
      this.geometry = data.geometry?.slice() ?? [0, 0, 0, 0, 100, 0, 0, 0];
      this.flipH = data.flipH ?? false;
      this.flipV = data.flipV ?? false;
      // Missing field means the sidecar predates process versions. Resolving it
      // to LEGACY is the conservative direction: CURRENT would re-render the
      // photo with maths the user never saw.
      this.processVersion = normalizeProcessVersion(data.processVersion ?? PROCESS_VERSION_LEGACY);
      this.cropAspectRatio = data.cropAspectRatio ?? 0;
      console.info(`VIVID_FRAME t=${Date.now()} event=snapshot_restore sid=${this.sessionId} crop=${this.cropLeft.toFixed(3)},${this.cropTop.toFixed(3)},${this.cropRight.toFixed(3)},${this.cropBottom.toFixed(3)} rot=${this.rotation} geo=${this.geometry.join(',')}`);
      this.selectedMaskLayerId = data.selectedMaskLayerId ?? null;
      this.selectedMaskComponentId = data.selectedMaskComponentId ?? null;
      this.lutLink = data.lutLink ?? '';
      this.lutPresetName = data.lutPresetName ?? '';
      // The parsed LUT body is supplied by the editor when the source is
      // available. The persisted URI/name still survives a restart.
      this.lutPreset = null;
      this.lutStack = (data.lutStack ?? []).map((item: LutStackSnapshot): LutStackItem => {
        const lut = LutLibraryStore.findOrRestore(item.lutId, item.name, item.sourceUri);
        if (!lut) {
          console.info(`VIVID_LUT restore-missing id=${item.lutId} source=${item.sourceUri}`);
        }
        return {
          id: item.id,
          lutId: item.lutId,
          name: item.name,
          sourceUri: item.sourceUri,
          enabled: item.enabled ?? true,
          intensity: item.intensity ?? 1,
          lut: lut,
          lutUnavailable: lut === null,
        };
      });
      // Version 1 sidecars had one LUT link. Migrate it into a one-layer stack.
      if (this.lutStack.length === 0 && this.lutLink.length > 0) {
        const legacy = LutLibraryStore.findOrRestore(this.lutLink, this.lutPresetName, this.lutLink);
        if (legacy) this.lutStack = [createLutStackItem(legacy, 1)];
      }
    } catch (_e) {
      // ignore parse errors
    }
  }

  private restoreMask(saved: MaskState | null): MaskState | null {
    if (!saved) return null;
    const mask = new MaskState();
    mask.type = saved.type;
    mask.invert = saved.invert;
    mask.feather = saved.feather;
    mask.linearGradient.startX = saved.linearGradient.startX;
    mask.linearGradient.startY = saved.linearGradient.startY;
    mask.linearGradient.endX = saved.linearGradient.endX;
    mask.linearGradient.endY = saved.linearGradient.endY;
    mask.linearGradient.feather = saved.linearGradient.feather;
    mask.linearParts = (saved.linearParts ?? []).map((part: LinearMaskPart) => {
      const restored = new LinearMaskPart();
      restored.operation = part.operation ?? 0;
      restored.params.startX = part.params.startX;
      restored.params.startY = part.params.startY;
      restored.params.endX = part.params.endX;
      restored.params.endY = part.params.endY;
      restored.params.feather = part.params.feather;
      return restored;
    });
    mask.activeLinearIndex = saved.activeLinearIndex ?? 0;
    mask.radialGradient.centerX = saved.radialGradient.centerX;
    mask.radialGradient.centerY = saved.radialGradient.centerY;
    mask.radialGradient.radius = saved.radialGradient.radius;
    mask.radialGradient.radiusX = saved.radialGradient.radiusX ?? saved.radialGradient.radius;
    mask.radialGradient.radiusY = saved.radialGradient.radiusY ?? saved.radialGradient.radius;
    mask.radialGradient.feather = saved.radialGradient.feather;
    mask.radialGradient.rotation = saved.radialGradient.rotation ?? 0;
    mask.brushStrokes = saved.brushStrokes.map(stroke => {
      const restoredStroke = new BrushStroke();
      restoredStroke.mode = stroke.mode ?? 0;
      restoredStroke.points = stroke.points.map(point => {
        const restoredPoint = new BrushPoint();
        restoredPoint.x = point.x;
        restoredPoint.y = point.y;
        restoredPoint.radius = point.radius;
        restoredPoint.hardness = point.hardness ?? 0.5;
        return restoredPoint;
      });
      return restoredStroke;
    });
    return mask;
  }

  private restoreMaskLayer(saved: MaskLayerSnapshot): MaskLayer {
    const layer = new MaskLayer(saved.name ?? '蒙版', saved.id);
    layer.inverted = saved.inverted ?? false;
    layer.enabled = saved.enabled ?? true;
    layer.visible = saved.visible ?? true;
    layer.opacity = saved.opacity ?? 1;
    layer.createdAt = saved.createdAt ?? Date.now();
    layer.updatedAt = saved.updatedAt ?? layer.createdAt;
    if (saved.adjustments) this.restoreAdjustments(layer.adjustments, saved.adjustments);
    layer.components = (saved.components ?? []).map((savedComponent: MaskComponentSnapshot) => {
      const component = new MaskComponent(savedComponent.type, savedComponent.id);
      component.renderingVersion = savedComponent.renderingVersion ?? 1;
      component.blendMode = savedComponent.blendMode ?? MaskBlendMode.ADD;
      component.enabled = savedComponent.enabled ?? true;
      component.visible = savedComponent.visible ?? true;
      component.inverted = savedComponent.inverted ?? false;
      component.opacity = savedComponent.opacity ?? 1;
      if (savedComponent.feather !== undefined) component.feather = savedComponent.feather;
      if (savedComponent.brushStrokes) {
        const strokes = savedComponent.brushStrokes;
        component.brushData = new BrushMaskData();
        component.brushData.strokes = strokes.map((stroke: BrushStroke) => {
          const restoredStroke = new BrushStroke();
          restoredStroke.mode = stroke.mode ?? 0;
          restoredStroke.flow = Number.isFinite(stroke.flow) ? Math.max(0, Math.min(1, stroke.flow)) : 1;
          restoredStroke.density = Number.isFinite(stroke.density) ? Math.max(0, Math.min(1, stroke.density)) : 1;
          restoredStroke.points = (stroke.points ?? []).map((point: BrushPoint) => {
            const restoredPoint = new BrushPoint();
            restoredPoint.x = point.x; restoredPoint.y = point.y;
            restoredPoint.radius = point.radius; restoredPoint.hardness = point.hardness ?? 0.5;
            return restoredPoint;
          });
          return restoredStroke;
        });
      }
      if (savedComponent.linear.length >= 4) {
        component.linearGradientData = new LinearGradientData();
        component.linearGradientData.startX = savedComponent.linear[0];
        component.linearGradientData.startY = savedComponent.linear[1];
        component.linearGradientData.endX = savedComponent.linear[2];
        component.linearGradientData.endY = savedComponent.linear[3];
      }
      if (savedComponent.radial.length >= 4) {
        component.radialGradientData = new RadialGradientData();
        component.radialGradientData.centerX = savedComponent.radial[0];
        component.radialGradientData.centerY = savedComponent.radial[1];
        component.radialGradientData.radiusX = savedComponent.radial[2];
        component.radialGradientData.radiusY = savedComponent.radial[3];
        component.radialGradientData.rotation = savedComponent.radial[4] ?? 0;
      }
      // Restore a persisted raster selection. A malformed or truncated raster is
      // dropped (component selects nothing) instead of being trusted, so a
      // damaged sidecar can never silently select the whole frame.
      const rasterWidth = savedComponent.rasterWidth ?? 0;
      const rasterHeight = savedComponent.rasterHeight ?? 0;
      const rasterAlpha = savedComponent.rasterAlpha;
      if (rasterWidth > 0 && rasterHeight > 0 && rasterAlpha !== undefined && rasterAlpha.length > 0) {
        try {
          const decoded = new util.Base64Helper().decodeSync(rasterAlpha);
          if (decoded.length >= rasterWidth * rasterHeight) {
            const data = new MaskRaster();
            data.origin = savedComponent.rasterOrigin ?? '';
            data.key = savedComponent.rasterKey ?? '';
            data.width = rasterWidth;
            data.height = rasterHeight;
            data.alpha = decoded.slice(0, rasterWidth * rasterHeight);
            component.raster = data;
          }
        } catch (_e) {
          component.raster = null;
        }
      }
      // Range parameters are restored before the raster so a reopened range mask
      // is editable immediately: the sliders show the values the saved raster
      // was made with, instead of resetting to the defaults and disagreeing with
      // the selection the user can see.
      const savedRange = savedComponent.range;
      if (component.type === MaskComponentType.RANGE && savedRange !== undefined &&
        savedRange.length >= 8) {
        const range = new RangeMaskData();
        range.min = savedRange[0];
        range.max = savedRange[1];
        range.smoothness = savedRange[2];
        range.colorEnabled = savedRange[3] >= 0.5;
        range.colorR = savedRange[4];
        range.colorG = savedRange[5];
        range.colorB = savedRange[6];
        range.colorAmount = savedRange[7];
        component.rangeData = range;
      }
      return component;
    });
    return layer;
  }

  private restoreCurvePoints(saved: CurveAnchor[] | undefined): CurveAnchor[] {
    if (!saved || saved.length < 2) return ColorAdjustments.defaultCurve();
    return saved.map((point: CurveAnchor) => new CurveAnchor(point.x, point.y));
  }

  // ---- Mask cache management ----

  invalidateMaskCache(): void {
    this.notifyMaskRevision();
    this.maskCache.clear();
  }

  invalidateLayerMaskCache(layerId: string): void {
    this.maskRevision++;
    this.maskCache.delete(layerId);
    const prefix = layerId + ':';
    const keys = Array.from(this.maskCache.keys());
    for (const key of keys) {
      if (key.indexOf(prefix) === 0) this.maskCache.delete(key);
    }
  }

  // ---- Processing ----

  /**
   * Mark an in-flight render as stale without invalidating the UI tree.
   *
   * Slider gestures can emit many values per second.  Bumping
   * processingVersion for every value caused the whole editor (including the
   * scrollable adjustment card) to rebuild on each frame.  The renderer only
   * needs processingRequestVersion to cancel that pass; it bumps the public
   * processingVersion once when the finished preview is ready.
   */
  requestProcessing(): void {
    this.processingRequestVersion++;
    this.lastProcessingRequestAt = Date.now();
  }

  bumpProcessing(): void {
    this.processingVersion++;
  }

  /** Release the geometry-only comparison frame and invalidate pending jobs. */
  clearBeforePreview(): void {
    this.beforeRenderToken++;
    const old = this.beforePixelMap;
    this.beforePixelMap = null;
    this.beforePixelMapSource = null;
    this.beforeGeometryKey = '';
    if (old) {
      try { old.release(); } catch (_error) { /* already released */ }
    }
    const version = AppStorage.get<number>('beforePreviewVersion') ?? 0;
    AppStorage.setOrCreate('beforePreviewVersion', version + 1);
  }

  /** Release a zoom detail tile and invalidate the detail overlay. */
  clearDetailPixelMap(): void {
    const old = this.detailPixelMap;
    this.detailPixelMap = null;
    this.detailRegion = null;
    this.detailWidth = 0;
    this.detailHeight = 0;
    this.detailRevision++;
    if (old) {
      try { old.release(); } catch (_error) { /* already released */ }
    }
  }

  // ---- Histogram ----

  async computeHistogram(): Promise<void> {
    const pm = this.previewPixelMap;
    if (!pm) return;

    this.histogramR.fill(0);
    this.histogramG.fill(0);
    this.histogramB.fill(0);
    this.histogramL.fill(0);

    try {
      const info = await pm.getImageInfo();
      const w = info.size.width;
      const h = info.size.height;
      const bufferSize = w * h * 4;
      const buffer = new ArrayBuffer(bufferSize);
      await pm.readPixelsToBuffer(buffer);
      const pixels = new Uint8Array(buffer);

      // Sample every 4th pixel for performance
      const step = 4;
      const sampleCount = Math.floor(w / step) * Math.floor(h / step);

      for (let y = 0; y < h; y += step) {
        for (let x = 0; x < w; x += step) {
          const idx = (y * w + x) * 4;
          const R = pixels[idx];
          const G = pixels[idx + 1];
          const B = pixels[idx + 2];
          // Luminance (Rec. 709)
          const L = Math.round(0.2126 * R + 0.7152 * G + 0.0722 * B);

          this.histogramR[R]++;
          this.histogramG[G]++;
          this.histogramB[B]++;
          this.histogramL[L]++;
        }
      }
    } catch (_e) {
      // Silently ignore histogram errors
    }
    this.histogramVersion++;
  }

  // ---- Crop operations ----

  resetCrop(): void {
    this.cropLeft = 0;
    this.cropTop = 0;
    this.cropRight = 1;
    this.cropBottom = 1;
    this.cropAspectRatio = 0;
    console.info(`VIVID_FRAME t=${Date.now()} event=reset_crop sid=${this.sessionId}`);
  }

  rotateCW(): void {
    this.pushUndo();
    this.rotation = (this.rotation + 90) % 360;
    this.bumpProcessing();
  }

  flipHorizontal(): void {
    this.pushUndo();
    this.flipH = !this.flipH;
    this.bumpProcessing();
  }

  flipVertical(): void {
    this.pushUndo();
    this.flipV = !this.flipV;
    this.bumpProcessing();
  }

  getCropWidth(): number {
    return this.cropRight - this.cropLeft;
  }

  getCropHeight(): number {
    return this.cropBottom - this.cropTop;
  }

  /** Pixel size of the image currently displayed by the editor canvas:
   * the applied crop region, swapped for quarter-turn rotations. */
  displayedPixelSize(): number[] {
    const cropW = Math.max(1, this.getCropWidth() * Math.max(1, this.imageWidth));
    const cropH = Math.max(1, this.getCropHeight() * Math.max(1, this.imageHeight));
    const rotation = ((this.rotation % 360) + 360) % 360;
    return rotation === 90 || rotation === 270 ? [cropH, cropW] : [cropW, cropH];
  }

  /** Clamp a working-frame rect (display space) and enforce the selected
   * aspect ratio. `anchor` follows the drag corner semantics: 0=TL, 1=TR,
   * 2=BL, 3=BR, 4=move, -1=keep centered (ratio buttons). Returns null when
   * the result would be too small, leaving the caller's frame untouched. */
  fitWorkingRect(
    left: number,
    top: number,
    right: number,
    bottom: number,
    aspectRatio: number,
    anchor: number,
  ): number[] | null {
    let l = Math.max(0, Math.min(1, left));
    let t = Math.max(0, Math.min(1, top));
    let r = Math.max(0, Math.min(1, right));
    let b = Math.max(0, Math.min(1, bottom));
    const minSize = 0.04;

    // Keep the dragged side from crossing its opposite side. This also makes
    // the fixed diagonal handle stay put while a corner is stretched.
    if (anchor === 0 || anchor === 2) l = Math.max(0, Math.min(r - minSize, l));
    if (anchor === 1 || anchor === 3) r = Math.min(1, Math.max(l + minSize, r));
    if (anchor === 0 || anchor === 1) t = Math.max(0, Math.min(b - minSize, t));
    if (anchor === 2 || anchor === 3) b = Math.min(1, Math.max(t + minSize, b));
    if (anchor === 4) {
      const width = r - l;
      const height = b - t;
      if (width > 0 && height > 0) {
        if (l < 0) { r -= l; l = 0; }
        if (t < 0) { b -= t; t = 0; }
        if (r > 1) { l -= r - 1; r = 1; }
        if (b > 1) { t -= b - 1; b = 1; }
      }
    }

    // Aspect ratio is enforced in DISPLAY space so what the user frames is
    // exactly what the render outputs, independent of rotation.
    if (aspectRatio > 0) {
      const display = this.displayedPixelSize();
      const currentW = r - l;
      const currentH = b - t;
      const normalizedRatio = aspectRatio * display[1] / Math.max(1, display[0]);
      const currentRatio = currentH > 0 ? currentW / currentH : normalizedRatio;
      if (Math.abs(currentRatio - normalizedRatio) > 0.001) {
        if (currentRatio > normalizedRatio) {
          const targetW = Math.min(currentH * normalizedRatio, 1);
          if (anchor === 0 || anchor === 2) l = r - targetW;
          else if (anchor === 1 || anchor === 3) r = l + targetW;
          else {
            const center = (l + r) / 2;
            l = center - targetW / 2;
            r = center + targetW / 2;
          }
        } else {
          const targetH = Math.min(currentW / normalizedRatio, 1);
          if (anchor === 0 || anchor === 1) t = b - targetH;
          else if (anchor === 2 || anchor === 3) b = t + targetH;
          else {
            const center = (t + b) / 2;
            t = center - targetH / 2;
            b = center + targetH / 2;
          }
        }
      }
    }

    l = Math.max(0, Math.min(1 - minSize, l));
    t = Math.max(0, Math.min(1 - minSize, t));
    r = Math.max(minSize, Math.min(1, r));
    b = Math.max(minSize, Math.min(1, b));
    if (anchor === 0 || anchor === 2) l = Math.min(l, r - minSize);
    if (anchor === 1 || anchor === 3) r = Math.max(r, l + minSize);
    if (anchor === 0 || anchor === 1) t = Math.min(t, b - minSize);
    if (anchor === 2 || anchor === 3) b = Math.max(b, t + minSize);
    if (r - l < minSize || b - t < minSize) {
      console.info(`VIVID_FRAME t=${Date.now()} event=fit_working_rect_rejected sid=${this.sessionId} l=${l.toFixed(3)} t=${t.toFixed(3)} r=${r.toFixed(3)} b=${b.toFixed(3)} ratio=${aspectRatio} anchor=${anchor}`);
      return null;
    }
    return [l, t, r, b];
  }

  /** Applied crop rectangle mapped into the currently displayed
   * (rotated/flipped) image coordinates. */
  cropBoundsDisplayed(): number[] {
    let left = this.cropLeft;
    let top = this.cropTop;
    let right = this.cropRight;
    let bottom = this.cropBottom;
    const rotation = ((this.rotation % 360) + 360) % 360;
    if (rotation === 90) {
      const oldLeft = left;
      left = 1 - bottom;
      right = 1 - top;
      top = oldLeft;
      bottom = this.cropRight;
    } else if (rotation === 180) {
      const oldLeft = left;
      const oldTop = top;
      left = 1 - right;
      right = 1 - oldLeft;
      top = 1 - bottom;
      bottom = 1 - oldTop;
    } else if (rotation === 270) {
      const oldLeft = left;
      const oldTop = top;
      top = 1 - right;
      bottom = 1 - oldLeft;
      left = oldTop;
      right = this.cropBottom;
    }
    if (this.flipH) {
      const oldLeft = left;
      left = 1 - right;
      right = 1 - oldLeft;
    }
    if (this.flipV) {
      const oldTop = top;
      top = 1 - bottom;
      bottom = 1 - oldTop;
    }
    return [left, top, right, bottom];
  }

  /**
   * Single geometry map for overlay drawing, touch input, mask placement and
   * retouch marks. Without it the overlay silently ignored the manual geometry
   * pass (straighten/perspective/auto-crop) and drew the crop rectangle and
   * mask preview at the untransformed location.
   */
  geometryMap(renderWidth: number = 0, renderHeight: number = 0): GeometryMap {
    const width = Math.max(1, this.imageWidth);
    const height = Math.max(1, this.imageHeight);
    const targetWidth = renderWidth > 0 ? Math.max(1, Math.round(renderWidth)) : width;
    const targetHeight = renderHeight > 0 ? Math.max(1, Math.round(renderHeight)) : height;
    return buildGeometryMap(this.geometry, targetWidth, targetHeight, {
      width: targetWidth, height: targetHeight,
      cropLeft: this.cropLeft, cropTop: this.cropTop,
      cropRight: this.cropRight, cropBottom: this.cropBottom,
      rotation: this.rotation, flipH: this.flipH, flipV: this.flipV,
    }, { referenceWidth: width, referenceHeight: height });
  }

  /**
   * Solve the stored Upright guides and write the result into the manual geometry
   * fields (g[0] vertical perspective, g[1] horizontal, g[2] straighten).
   *
   * This is the ONE place the solve happens, so the panel, the canvas and the
   * tests all go through identical code. It is not a render stage: the geometry
   * uniforms already carry the result to both the CPU and the GPU path.
   *
   * With no guides the solution is empty and `applyUpright` writes zeros, so
   * deleting the last guide restores the manual values rather than leaving a
   * stale correction behind. Returns the solution so the UI can show the residual
   * and the accepted-guide counts instead of implying the solve always succeeded.
   */
  solveUprightGuides(apply: boolean = true): UprightSolution {
    const solution = solveUprightNormalized(this.upright.guides, uprightModeFromNumber(this.upright.mode));
    // `apply=false` lets the panel refresh its readout on mount without wiping
    // the manual geometry when there are no guides yet.
    if (apply) this.geometry = applyUpright(this.geometry, solution);
    return solution;
  }

  /** Source normalised point → displayed (crop/rotate/flip/geometry) normalised
   * point. Returns null when the point is outside the published frame. */
  sourcePointToDisplay(x: number, y: number): number[] | null {
    return sourceToDisplay(this.geometryMap(), x * this.imageWidth, y * this.imageHeight);
  }

  /** Displayed normalised point → source normalised point. */
  displayPointToSource(x: number, y: number): number[] | null {
    const point = displayToSource(this.geometryMap(), x, y);
    if (!point || this.imageWidth <= 0 || this.imageHeight <= 0) return null;
    return [point[0] / this.imageWidth, point[1] / this.imageHeight];
  }

  /** Displayed normalised rect → source normalised rect, sampling all four
   * corners so a projective transform cannot be approximated by one corner. */
  displayBoundsToSourceMapped(bounds: number[]): number[] {
    const corners: number[][] = [
      [bounds[0], bounds[1]], [bounds[2], bounds[1]],
      [bounds[0], bounds[3]], [bounds[2], bounds[3]],
    ];
    let left = 1, top = 1, right = 0, bottom = 0, found = false;
    for (const corner of corners) {
      const mapped = this.displayPointToSource(corner[0], corner[1]);
      if (!mapped) continue;
      found = true;
      left = Math.min(left, mapped[0]); top = Math.min(top, mapped[1]);
      right = Math.max(right, mapped[0]); bottom = Math.max(bottom, mapped[1]);
    }
    if (!found) return this.displayedBoundsToSource(bounds);
    return [Math.max(0, left), Math.max(0, top), Math.min(1, right), Math.min(1, bottom)];
  }

  /** Inverse of cropBoundsDisplayed: a rect in displayed coordinates back
   * into source (uncropped, unrotated) normalized coordinates. */
  displayedBoundsToSource(bounds: number[]): number[] {
    let left = bounds[0];
    let top = bounds[1];
    let right = bounds[2];
    let bottom = bounds[3];
    if (this.flipH) {
      const oldLeft = left;
      left = 1 - right;
      right = 1 - oldLeft;
    }
    if (this.flipV) {
      const oldTop = top;
      top = 1 - bottom;
      bottom = 1 - oldTop;
    }
    const rotation = ((this.rotation % 360) + 360) % 360;
    if (rotation === 90) {
      return [top, 1 - right, bottom, 1 - left];
    }
    if (rotation === 180) {
      return [1 - right, 1 - bottom, 1 - left, 1 - top];
    }
    if (rotation === 270) {
      return [1 - bottom, left, 1 - top, right];
    }
    return [left, top, right, bottom];
  }

  /** Compose the working frame (display space over the current preview) into
   * the session crop. Called by the apply button; an untouched full-extent
   * frame leaves the crop unchanged. */
  commitCropWorking(): void {
    const w = this.cropWorking;
    const untouched = w[0] <= 0.0005 && w[1] <= 0.0005 && w[2] >= 0.9995 && w[3] >= 0.9995;
    if (!untouched) {
      const base = this.cropBoundsDisplayed();
      const baseW = base[2] - base[0];
      const baseH = base[3] - base[1];
      const abs: number[] = [
        base[0] + w[0] * baseW,
        base[1] + w[1] * baseH,
        base[0] + w[2] * baseW,
        base[1] + w[3] * baseH,
      ];
      const src = this.displayBoundsToSourceMapped(abs);
      this.cropLeft = src[0];
      this.cropTop = src[1];
      this.cropRight = src[2];
      this.cropBottom = src[3];
      console.info(`VIVID_FRAME t=${Date.now()} event=commit_crop_working sid=${this.sessionId} working=${w[0].toFixed(3)},${w[1].toFixed(3)},${w[2].toFixed(3)},${w[3].toFixed(3)} crop=${this.cropLeft.toFixed(3)},${this.cropTop.toFixed(3)},${this.cropRight.toFixed(3)},${this.cropBottom.toFixed(3)}`);
    }
    this.cropWorking = [0, 0, 1, 1];
  }

  // ---- 大光圈深度图 ----

  /** 丢弃深度图（换图/重置时调用）。像素与参数都不受影响。 */
  clearBokehDepth(): void {
    this.bokehDepth = null;
    this.bokehDepthWidth = 0;
    this.bokehDepthHeight = 0;
    this.bokehDepthSourceKey = '';
  }

  /** 发布一张新深度图；尺寸与源帧坐标同时更新。 */
  setBokehDepth(depth: Uint8Array | null, width: number, height: number,
    sourceKey: string): void {
    if (!depth || width <= 0 || height <= 0 || depth.length < width * height) {
      this.clearBokehDepth();
      return;
    }
    this.bokehDepth = depth;
    this.bokehDepthWidth = width;
    this.bokehDepthHeight = height;
    this.bokehDepthSourceKey = sourceKey;
  }

  hasBokehDepth(): boolean {
    return this.bokehDepth !== null && this.bokehDepthWidth > 0 && this.bokehDepthHeight > 0;
  }

  // ---- Reset ----

  reset(): void {
    this.retouchMarks = [];
    this.pickingRetouchSource = false;
    this.denoise = new DenoiseSettings();
    this.detail = new DetailSettings();
    // 雾色是整帧统计量：细节设置一改就必须重新估计，否则瓦片会用旧雾色。
    this.detailHaze = [];
    this.optics = new OpticsSettings();
    this.bokeh = new BokehSettings();
    this.clearBokehDepth();
    this.upright = new UprightSettings();
    this.pointColor = new PointColorSettings();
    // The cached source bytes belong to the photo being replaced; a fresh
    // PointColorSettings also leaves picking mode, so the next photo starts
    // with no eyedropper armed.
    PointColorPicker.invalidate();
    this.notifyPointColorRevision();
    this.oklch = new OkLChSettings();
    this.blackWhite = new BlackWhiteSettings();
    this.rawSettings = null;
    this.clearDetailPixelMap();
    this.clearBeforePreview();
    // Displayed frames belong to the previous photo. Dropping them here keeps
    // the canvas from showing the old preview (or a stale GPU flag) while the
    // next image is still decoding. The last two CPU frames are released by
    // ImageProcessor.clearSourceCache, which owns those PixelMaps.
    this.previewPixelMap = null;
    this.gpuPreviewActive = false;
    this.gpuSurfaceDirty = false;
    this.layers = [new Layer('背景')];
    this.activeLayerIndex = 0;
    this.activeTool = ToolType.ADJUST;
    this.canvasScale = 1.0;
    this.canvasOffsetX = 0;
    this.canvasOffsetY = 0;
    this.undoStack = [];
    this.redoStack = [];
    this.maskCache.clear();
    this.processingVersion = 0;
    this.processingRequestVersion = 0;
    this.resetCrop();
    this.rotation = 0;
    this.flipH = false;
    this.flipV = false;
    // Reset moves the photo onto the current algorithm generation.
    this.processVersion = PROCESS_VERSION_CURRENT;
    this.previewWidth = this.imageWidth;
    this.previewHeight = this.imageHeight;
    this.brushSize = 0.03;
    this.brushHardness = 0.5;
    this.brushFlow = 1; this.brushDensity = 1;
    this.maskBrushMode = 0;
    this.adjustmentScope = 0;
    this.lutLink = '';
    this.lutPresetName = '';
    this.lutPreset = null;
    this.lutStack = [];
  }
}





