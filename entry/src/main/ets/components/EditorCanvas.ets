import { EditSession, DetailRegion } from '../edit/models/EditSession';
import { ToolType } from '../edit/models/ToolType';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { GpuShaderBridge } from '../edit/engine/GpuShaderBridge';
import { EditorCommandDispatcher, EditorDispatchResult, EditorKeyboardContext } from '../edit/engine/EditorCommandDispatcher';
import {
  EditorCommandId,
  EditorKeyCodes,
  EDITOR_TOOL_ADJUST,
  EDITOR_TOOL_BRUSH_MASK,
  EDITOR_TOOL_CROP,
  EDITOR_TOOL_UPRIGHT,
  editorToolIdOf,
} from '../edit/engine/EditorShortcuts';
import { geometryActive } from '../edit/engine/GeometryTransform';
import { displayToSource } from '../edit/engine/GeometryMath';
import { MaskRenderer } from '../edit/engine/MaskRenderer';
import { LengthMetricsUnit, promptAction } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { RetouchMark } from '../edit/models/RetouchSettings';
import { UprightSettings } from '../edit/models/UprightSettings';
import { BokehSettings } from '../edit/models/BokehSettings';
import { VividNative } from './VividNativeTheme';
import { componentUtils } from '@kit.ArkUI';
import {
  BrushPoint, BrushStroke, LinearGradientParams, MaskType, MaskComponent, MaskComponentType, MaskLayer,
  RadialGradientData, MaskBlendMode,
} from '../edit/models/Mask';

// What the preview stack is currently able to show. The editor page mounts
// this canvas only after its first frame has been rendered (the loading gate
// lives in EditorPage), so the canvas has to resolve the current frame from
// the session instead of waiting for a signal it may have missed.
const FRAME_NONE: number = 0;
const FRAME_BEFORE: number = 1;
const FRAME_SOURCE_BEFORE: number = 2;
const FRAME_PREVIEW: number = 3;
const FRAME_GPU: number = 4;

@Component
export struct EditorCanvas {
  @Consume('editSession') editSession: EditSession;
  // The page owns the full-resolution source and performs the asynchronous
  // tile render. The canvas only reports the visible normalized region.
  onRequestDetailRender: (region: DetailRegion | null) => void = () => {};
  // Preview invalidation is a narrow storage signal.  Passing
  // editSession.processingVersion through PhoneLayout rebuilt the whole
  // adjustment card every time a render completed, which made scrolling and
  // slider gestures stutter.
  @StorageProp('previewVersion') @Watch('syncRenderVersion') renderVersion: number = 0;
  @StorageProp('detailVersion') @Watch('syncDetailVersion') detailVersion: number = 0;
  @StorageProp('cropOverlayRevision') @Watch('syncCropOverlayRevision') cropOverlayRevision: number = 0;
  @StorageProp('maskRevision') @Watch('syncCropOverlayRevision') private maskUiRevision: number = 0;
  /** 正在用滑杆改画笔大小：暂停绘图、隐藏蒙版覆盖，只画一个红色笔头预览圆。 */
  @StorageProp('maskBrushSizing') @Watch('onBrushSizingChanged') private brushSizing: boolean = false;
  /** 滑杆拖动中的计数器：每次变化都重画笔头预览圆。 */
  @StorageProp('maskBrushSizeTick') @Watch('onBrushSizingChanged') private brushSizeTick: number = 0;
  @StorageProp('maskBrushAdjustValue') @Watch('onBrushSizingChanged') private brushAdjustValue: number = 0;
  // Point-colour picking is driven by a narrow signal: the canvas only needs to
  // repaint its "tap the photo" hint, not rebuild the whole editor tree.
  @StorageProp('pointColorRevision') private pointColorUiRevision: number = 0;
  /** 手动白平衡模式：为真时画面上挂着可拖拽的取样锚点。 */
  @StorageProp('wbPicking') @Watch('onWhiteBalancePickingChanged') private wbPicking: boolean = false;
  /**
   * 调色滑杆正在被拖动：此时临时隐藏蒙版叠加层（红色覆盖会挡住画面，看不清
   * 调色效果）。只影响叠加层的显示，蒙版本身照旧生效。
   */
  @StorageProp('maskOverlayHiddenBySlider') @Watch('syncOverlaySuppression') private overlayHiddenBySlider: boolean = false;
  @StorageProp('beforePreviewVersion') beforePreviewVersion: number = 0;
  @StorageProp('windowWidth') windowWidth: number = 0;
  @StorageProp('vividNightMode') private night: boolean = false;
  @StorageProp('desktopMaskOverlay') @Watch('syncCropOverlayRevision') private showMaskCoverage: boolean = true;
  // showBefore lives on the @Observed session, but this component binds the
  // session through @Consume, which has no property-level observation. The
  // canvas-local state is authoritative for touches on the canvas itself;
  // the storage mirror covers the compare button hosted in the editor page.
  @State private showBeforeLocal: boolean = false;
  @StorageProp('vividShowBefore') showBeforeSignal: boolean = false;
  // True while this canvas is the focused editing surface and while no text
  // field or dialog owns the keyboard. PC shortcuts stand down otherwise, so
  // Ctrl+A/C/V/Z and decimal or negative typing in the panels keep working.
  @StorageProp('editorInputFocused') @Watch('onKeyboardContextChange') private inputFocused: boolean = false;
  @StorageProp('editorModalOpen') @Watch('onKeyboardContextChange') private modalOpen: boolean = false;
  // Bumped by the page when a dialog or menu opens, when the photo changes and
  // when the page goes away: every hold command is released, so the original is
  // never left on screen and no key stays stuck.
  @StorageProp('editorShortcutReset') @Watch('releaseHeldKeys') private shortcutReset: number = 0;
  // An export or a long-running dialog owns the keyboard too.
  @StorageProp('vividExportActive') @Watch('onKeyboardContextChange') private exportActive: boolean = false;
  @State private canvasFocused: boolean = false;
  @State private canvasWidth: number = 0;
  @State private canvasHeight: number = 0;
  @State private imageRevision: number = 0;
  /** Set once per CPU->GPU transition, so the reveal re-present runs only once. */
  private gpuLayerRevealed: boolean = false;
  private overlaySettings: RenderingContextSettings = new RenderingContextSettings(true);
  private overlayCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.overlaySettings);
  private reprocessTimer: number = -1;
  private maskOverlayTimer: number = -1;
  // Keep the off-screen canvas together with its context. Constructing an
  // OffscreenCanvasRenderingContext2D directly creates a detached surface on
  // some HarmonyOS builds; putImageData then gets clipped when transferred.
  private maskSurfaceCanvas: OffscreenCanvas | null = null;
  private maskSurface: OffscreenCanvasRenderingContext2D | null = null;
  private maskSurfaceWidth: number = 0;
  private maskSurfaceHeight: number = 0;
  // Keep the last committed mask separate from the stroke currently under
  // the finger. During a stroke we reuse this alpha field and draw only the
  // live path, avoiding a full MaskRenderer pass for every move event.
  private committedMaskAlpha: Uint8ClampedArray | null = null;
  private committedMaskWidth: number = 0;
  private committedMaskHeight: number = 0;
  private committedMaskLayerId: string = '';
  private committedMaskUpdatedAt: number = 0;
  private currentStroke: BrushStroke | null = null;
  private strokeComponentId: string = '';
  private lastMaskOverlayMs: number = 0;
  private overlayRedrawTimer: number = -1;
  private suppressBrushStroke: boolean = false;
  private lastOverlaySignature: string = '';
  private cachedOverlayBitmap: ImageBitmap | null = null;
  private overlayAlphaKey: string = '';
  private overlayAlphaBuffer: Uint8ClampedArray | null = null;
  private strokeSettleUntil: number = 0;
  private brushSizingActive: boolean = false;
  private previewSizeValue: number = 50;
  private previewFeatherValue: number = 20;
  private sourceMapX: Float32Array | null = null;
  private sourceMapY: Float32Array | null = null;
  private sourceMapKey: string = '';
  private cachedOverlayWidth: number = 0;
  /** 这一笔还没被确认为真正的涂抹（可能被双指手势取消）。 */
  private strokeProvisional: boolean = false;
  /** 这一笔的撤销点是否已经压栈（延迟到笔迹成立时才压）。 */
  private strokeUndoPushed: boolean = false;
  private brushCursor: BrushPoint | null = null;
  private cropDragCorner: number = -1;
  private cropStartRect: number[] = [0, 0, 1, 1];
  private cropStartTouch: number[] = [0, 0];
  private linearDragPart: number = -1; // -1 none, 0 start anchor, 1 end anchor
  private radialDragPart: number = -1; // -1 none, 0 center, 1 right, 2 left, 3 top, 4 bottom, 5 rotation
  // 单击不该改动蒙版：在图片上点一下原本会立刻创建一个渐变分量（径向还会把
  // 已有椭圆挪到手指位置并缩成 0.03），所以真正的改动推迟到手指拖出这个距离
  // 之后。按下时只记录起点，够远了才落分量/移动锚点。
  private pendingMaskCreate: boolean = false;
  private pendingTouchX: number = 0;
  private pendingTouchY: number = 0;
  private pendingSourceX: number = 0;
  private pendingSourceY: number = 0;
  private static readonly MASK_DRAG_THRESHOLD: number = 8;
  private pinchStartScale: number = 1;
  private panStartOffsetX: number = 0;
  private panStartOffsetY: number = 0;
  /** Where the eyedropper's finger landed (canvas-local vp) and whether it has
   *  moved far enough to count as a drag rather than a tap. */
  private pointColorPickStartX: number = 0;
  private pointColorPickStartY: number = 0;
  private pointColorPickMoved: boolean = false;
  private static readonly POINT_COLOR_TAP_SLOP: number = 12;
  /** 手动白平衡锚点：画布内 vp 坐标 + 拖拽起点 + 取样节流时间戳。 */
  @State private wbAnchorX: number = 0;
  @State private wbAnchorY: number = 0;
  private wbDragStartX: number = 0;
  private wbDragStartY: number = 0;
  private wbSampleAt: number = 0;
  private wbSampling: boolean = false;
  private static readonly WB_ANCHOR_RADIUS: number = 26;
  private static readonly WB_SAMPLE_INTERVAL_MS: number = 90;
  private detailTimer: number = -1;
  private gpuController: XComponentController = new XComponentController();
  private readonly detailZoomThreshold: number = 1.35;
  private desktopPanActive: boolean = false;
  private retouchGesture: boolean = false;
  private retouchAnchor: BrushPoint | null = null;
  /** Live Upright reference-line drag, in normalized source coordinates. Held on
   *  the component rather than in the session so an in-progress drag is never
   *  persisted and never enters undo. */
  private uprightStart: BrushPoint | null = null;
  private uprightCurrent: BrushPoint | null = null;
  private lastRetouchPoint: BrushPoint | null = null;
  private desktopPanStartTouchX: number = 0;
  private desktopPanStartTouchY: number = 0;
  private desktopPanStartOffsetX: number = 0;
  private desktopPanStartOffsetY: number = 0;
  // Keys are dispatched by a shared module so the canvas, the toolbar buttons
  // and the page commands all run the same business action.
  private keyDispatcher: EditorCommandDispatcher = new EditorCommandDispatcher(
    (id: EditorCommandId) => { this.runEditorCommand(id); },
    (id: EditorCommandId) => { this.endEditorHold(id); },
  );
  private holdOriginalKey: number = -1;

  aboutToAppear(): void {
    // EditorPage only renders the editor layout once `loading` is false, which
    // happens after ImageProcessor has already published the first frame. A
    // @StorageProp watch is NOT delivered for the value a component is
    // initialised with, so a canvas created after that publish starts with
    // imageRevision = 0 while the session already has a frame. Adopt the
    // published version at mount; onAppear below closes the remaining window
    // (a publish that lands while the component is being created).
    this.adoptPublishedFrame('mount');
  }

  /**
   * Re-read the published preview version and make it the canvas' binding
   * revision. This is the first-frame fallback: whether the page published
   * before the canvas existed or in the middle of its creation, the canvas
   * still ends up rebuilding against the frame that is actually current.
   * The rebuild is needed because the GPU XComponent's visibility and the
   * preview Image's `.id` are both derived from the state read in build().
   */
  private adoptPublishedFrame(phase: string): void {
    const published: number = AppStorage.get<number>('previewVersion') ?? this.renderVersion;
    console.info(`VIVID_FRAME t=${Date.now()} event=canvas_frame_sync phase=${phase} version=${published} ` +
      `previous=${this.imageRevision} preview=${this.editSession.previewPixelMap !== null} ` +
      `gpu=${this.editSession.gpuPreviewActive} visible=${this.gpuLayerVisible()} ` +
      `detail=${this.editSession.detailPixelMap !== null}`);
    if (published !== this.imageRevision) this.imageRevision = published;
  }

  /**
   * Which layer build() must draw for the current session state. Kept as a
   * plain method so the mount/visibility contract can be tested without an
   * ArkUI renderer (tools/check_first_frame_visibility.cjs).
   */
  private visibleFrameKind(): number {
    if (this.editSession.gpuPreviewActive) return FRAME_GPU;
    if ((this.showBeforeLocal || this.showBeforeSignal) && this.editSession.beforePixelMap &&
      ImageProcessor.isBeforePreviewReady(this.editSession)) return FRAME_BEFORE;
    if ((this.showBeforeLocal || this.showBeforeSignal) && this.editSession.sourcePixelMap &&
      !this.hasGeometryTransform()) return FRAME_SOURCE_BEFORE;
    if (this.editSession.previewPixelMap) return FRAME_PREVIEW;
    return FRAME_NONE;
  }

  /**
   * Whether the direct EGL surface is part of the composition.
   *
   * The gate cannot follow `gpuPreviewActive` alone: that flag becomes true
   * only *after* the first GPU frame was presented, so the surface would be
   * hidden exactly when the frame is submitted. On phones such a present is
   * consumed by the hidden surface and never composited, leaving a blank
   * canvas until a later present (a touch) happens. The CPU preview Image is
   * drawn *above* the surface (see build()), so the surface can be visible as
   * soon as a CPU frame exists — its pixels are covered by the Image until the
   * GPU layer takes over. This keeps the first presenting frame on a surface
   * that is already composited, with no timing assumption.
   */
  private gpuLayerVisible(): boolean {
    return this.editSession.gpuPreviewActive || this.editSession.previewPixelMap !== null;
  }

  /**
   * True exactly once for every CPU layer -> GPU layer transition. The caller
   * uses it to re-present the frame that was published before the surface
   * became visible; repeated signals for the same GPU layer return false.
   */
  private revealGpuLayer(): boolean {
    if (!this.editSession.gpuPreviewActive) {
      this.gpuLayerRevealed = false;
      return false;
    }
    if (this.gpuLayerRevealed) return false;
    this.gpuLayerRevealed = true;
    return true;
  }

  private syncRenderVersion(): void {
    console.info(`VIVID_FRAME t=${Date.now()} event=canvas_preview_signal version=${this.renderVersion} previous=${this.imageRevision} gpu=${this.editSession.gpuPreviewActive} before=${this.editSession.showBefore}`);
    // Canvas drawing is imperative and onReady only fires once. Repaint after
    // ratio changes and transform buttons update the observed session version.
    this.imageRevision = this.renderVersion;
    // The very first GPU frame is presented while gpuPreviewActive is still
    // false, i.e. before build() has opened the XComponent's visibility gate.
    // On devices where a present to a hidden surface is not composited, the
    // frame exists but never reaches the screen until something else forces a
    // rebuild. Ask for exactly one more present now that this signal has made
    // the surface visible. It is a state transition (cpu layer -> gpu layer),
    // not a timer, so it cannot repeat.
    if (this.revealGpuLayer()) {
      console.info(`VIVID_FRAME t=${Date.now()} event=gpu_layer_reveal_repaint version=${this.renderVersion} sid=${this.editSession.sessionId}`);
      ImageProcessor.process(this.editSession);
    }
    // A preview frame for the same edit is not a reason to rebuild the tile:
    // the page only retires a tile when its edit stamp went stale. Re-request
    // only when the tile is gone or no longer covers what is on screen.
    if (this.detailTileCoversViewport()) {
      if (this.detailTimer >= 0) {
        clearTimeout(this.detailTimer);
        this.detailTimer = -1;
      }
    } else {
      this.scheduleDetailRequest();
    }
    this.requestOverlayRedraw();
  }

  /** True when the published tile already covers the current visible region
   *  at the current edit state. The page guarantees the tile is not stale. */
  private detailTileCoversViewport(): boolean {
    const region = this.editSession.detailRegion;
    if (this.editSession.detailPixelMap === null || region === null) return false;
    const visible = this.getVisibleDetailRegion();
    if (!visible) return false;
    const tolerance = 0.03;
    return Math.abs(region.left - visible.left) <= tolerance &&
      Math.abs(region.top - visible.top) <= tolerance &&
      Math.abs(region.width - visible.width) <= tolerance &&
      Math.abs(region.height - visible.height) <= tolerance;
  }

  private releaseHeldKeys(): void {
    // Focus loss, a dialog opening, a photo change and dispose all land here.
    this.keyDispatcher.releaseAll();
  }

  private onKeyboardContextChange(): void {
    if (this.inputFocused || this.modalOpen || this.exportActive) this.releaseHeldKeys();
  }

  /**
   * 合并叠加层重绘请求。
   *
   * 一笔提交会触发多个 @Watch（蒙版版本、遮罩开关、细节版本……），每个都直接
   * redraw 一次。笔数多以后单次重绘 130ms 以上，一笔就会连着画四五帧，
   * 表现成“点一下卡几秒”。
   */
  private requestOverlayRedraw(): void {
    if (this.overlayRedrawTimer !== -1) return;
    this.overlayRedrawTimer = setTimeout(() => {
      this.overlayRedrawTimer = -1;
      this.redrawOverlay();
    }, 70);
  }

  private onBrushSizingChanged(): void {
    console.info(`VIVID_PERF t=${Date.now()} event=brush_sizing phase=change ` +
      `sizing=${AppStorage.get<boolean>('maskBrushSizing') === true ? 1 : 0} ` +
      `active=${this.brushSizingActive ? 1 : 0} field=${this.brushSizing ? 1 : 0} ` +
      `value=${AppStorage.get<number>('maskBrushAdjustValue') ?? -1} ` +
      `tick=${AppStorage.get<number>('maskBrushSizeTick') ?? -1}`);
    // 滑块拖动结束（sizing 由 true 变 false）时必须强制重绘一次：拖动期间
    // 覆盖层被有意隐藏，结束时蒙版版本并没有变化，重绘签名会把恢复后的这次
    // 绘制当成“重复”直接跳过，于是只有点一下屏幕（触发别的重绘）才回来。
    if (this.brushSizingActive) {
      this.brushSizingActive = false;
      this.strokeSettleUntil = 0;
      this.lastOverlaySignature = '';
      AppStorage.setOrCreate('maskOverlayHiddenBySlider', false);
      this.requestOverlayRedraw();
    } else if (AppStorage.get<boolean>('maskBrushSizing') === true) {
      this.brushSizingActive = true;
      const adjustKind = AppStorage.get<string>('maskBrushAdjustKind') ?? 'size';
      const adjustValue = AppStorage.get<number>('maskBrushAdjustValue') ?? 0;
      if (adjustKind === 'feather') {
        this.previewFeatherValue = adjustValue;
      } else {
        this.previewSizeValue = adjustValue;
        // 调大小时保留上次的羽化值即可：羽化滑杆的值会一直保存在
        // previewFeatherValue 里；不要再从组件 feather 覆盖（画笔组件的
        // feather 常为 0，会把示意圆的过渡带抹平，看起来就是“没有羽化”）。
        if (this.previewFeatherValue <= 0) {
          this.previewFeatherValue = Math.max(0, Math.min(100,
            Math.round((this.editSession.activeMaskComponent?.feather ?? 0) * 100)));
        }
      }
      // 拖动过程中蒙版叠加层被隐藏，画布上只剩“大小/羽化示意”，而这一支
      // 只有在重绘被请求时才会执行。此前进入调参/每次 tick 都没有请求重绘，
      // 于是示意图整段消失（日志里 field=1 却没有任何 overlay_draw branch=sizing）。
      this.requestOverlayRedraw();
    }
    this.requestOverlayRedraw();
  }

  private syncCropOverlayRevision(): void {
    // 蒙版版本变化（隐藏/显示切换、撤销等）后必须允许下一次重绘：抬笔静默期
    // 标记、重绘签名、以及滑杆隐藏标记都可能把这次重绘挡掉，表现就是
    // “恢复显示后画完不出现红色叠加”。
    this.strokeSettleUntil = 0;
    this.lastOverlaySignature = '';
    if (AppStorage.get<boolean>('maskOverlayHiddenBySlider') === true) {
      AppStorage.setOrCreate('maskOverlayHiddenBySlider', false);
    }
    // 蒙版本身刚被重算（范围/颜色滑杆）时，红色覆盖就该看得见。
    // 调色滑杆那套“临时隐藏”依赖定时器恢复，主线程一卡就会残留成
    // true，表现为“滑着滑着红色没了”。
    if (this.isMaskTool() && this.overlayHiddenBySlider) {
      AppStorage.setOrCreate('maskOverlayHiddenBySlider', false);
    }
    // The crop frame is an imperative Canvas overlay. An explicit storage
    // revision makes ratio taps repaint immediately even when the session
    // object itself is not an observable property in the parent layout.
    this.requestOverlayRedraw();
  }

  /** 叠加层的隐藏/恢复要立刻重绘：否则松手后要等下一次其它重绘才出现。 */
  private syncOverlaySuppression(): void {
    this.requestOverlayRedraw();
  }

  private syncDetailVersion(): void {    console.info(`VIVID_FRAME t=${Date.now()} event=canvas_detail_signal version=${this.detailVersion} present=${this.editSession.detailPixelMap !== null}`);
    // The storage revision forces the Image node to bind the newly-created
    // tile. Position and size are derived from the current canvas transform.
    this.requestOverlayRedraw();
  }

  build() {
    Stack() {
      // The surface must be composited *before* the first GPU present. It sits
      // below the CPU preview Image (later children paint on top), which covers
      // exactly the same fit rectangle, so it is invisible until the GPU layer
      // takes over but already part of the window's composition. See
      // gpuLayerVisible() for why the gate must not wait for gpuPreviewActive.
      XComponent({ id: 'vivid-editor-gpu', type: XComponentType.SURFACE, controller: this.gpuController })
        .width(this.previewNodePlacement(false)[2])
        .height(this.previewNodePlacement(false)[3])
        .position({ x: this.previewNodePlacement(false)[0], y: this.previewNodePlacement(false)[1] })
        .scale({ x: this.editSession.canvasScale, y: this.editSession.canvasScale })
        .visibility(this.gpuLayerVisible() ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)
        .onLoad(() => {
          console.info(`VIVID_FRAME t=${Date.now()} event=surface_load`);
          this.editSession.gpuSurfaceId = this.gpuController.getXComponentSurfaceId();
          ImageProcessor.process(this.editSession);
        })
        .onDestroy(() => {
          console.info(`VIVID_FRAME t=${Date.now()} event=surface_destroy`);
          // The editor session survives a layout/theme rebuild, so drop the
          // resident-texture record instead of trusting a texture that was
          // uploaded against a window that no longer exists. The next surface
          // re-uploads from the authoritative PixelMap.
          GpuShaderBridge.surfaceDestroyed(this.editSession);
          this.editSession.gpuSurfaceId = '';
          this.editSession.gpuPreviewActive = false;
          this.editSession.gpuSurfaceDirty = false;
        });

      if (this.visibleFrameKind() === FRAME_BEFORE) {
        // The cached comparison frame has the current crop/rotation/flip
        // baked into its pixels, so it aligns with the graded preview.
        Image(this.editSession.beforePixelMap)
          .id('beforeImage_' + this.beforePreviewVersion.toString())
          .onAppear(() => {
            console.info(`VIVID_FRAME t=${Date.now()} event=before_image_mounted geometry=true`);
          })
          .width(this.previewDrawRect()[2])
          .height(this.previewDrawRect()[3])
          .objectFit(ImageFit.Fill)
          .position({ x: this.previewDrawRect()[0], y: this.previewDrawRect()[1] })
          .scale({ x: this.editSession.canvasScale, y: this.editSession.canvasScale });
      } else if (this.visibleFrameKind() === FRAME_SOURCE_BEFORE) {
        // With identity geometry the source PixelMap is already the exact
        // before frame and avoids an unnecessary copy on every comparison.
        Image(this.editSession.sourcePixelMap)
          .id('beforeImage_source_' + this.beforePreviewVersion.toString())
          .onAppear(() => {
            console.info(`VIVID_FRAME t=${Date.now()} event=before_image_mounted geometry=false`);
          })
          .width(this.previewDrawRect()[2])
          .height(this.previewDrawRect()[3])
          .objectFit(ImageFit.Fill)
          .position({ x: this.previewDrawRect()[0], y: this.previewDrawRect()[1] })
          .scale({ x: this.editSession.canvasScale, y: this.editSession.canvasScale });
      } else if (this.visibleFrameKind() === FRAME_PREVIEW) {
        Image(this.editSession.previewPixelMap)
          // PixelMap pixels are updated in place by the background renderer.
          // A changing id forces the Image node to rebind the texture, so the
          // finished preview appears without requiring a panel tap.
          .id('previewImage_' + this.imageRevision.toString())
          .width(this.previewDrawRect()[2])
          .height(this.previewDrawRect()[3])
          .objectFit(ImageFit.Fill)
          .position({ x: this.previewDrawRect()[0], y: this.previewDrawRect()[1] })
          .scale({ x: this.editSession.canvasScale, y: this.editSession.canvasScale });
      }

      // A full-resolution tile is drawn over the bounded preview only while
      // zoomed. It is positioned using the same fit rectangle as the preview,
      // so the tile edges line up exactly and the rest of the image remains
      // responsive during grading.
      if (!(this.showBeforeLocal || this.showBeforeSignal) && this.editSession.detailPixelMap &&
        this.editSession.detailRegion && !this.editSession.isCropping) {
        Image(this.editSession.detailPixelMap)
          .id('detailImage_' + this.detailVersion.toString())
          .position({ x: this.getDetailImageRect()[0], y: this.getDetailImageRect()[1] })
          .width(this.getDetailImageRect()[2])
          .height(this.getDetailImageRect()[3])
          .objectFit(ImageFit.Fill)
          .hitTestBehavior(HitTestMode.None);
      }

      // The crop scrim and frame sit on top of the preview; hide them while
      // the before image is showing so the comparison is unobstructed.
      // 蒙版红色覆盖 / 裁切框都画在这层画布上，必须先挂载；依赖 maskUiRevision
      // 让 build 在蒙版状态变化时重新求值。
      if (!(this.showBeforeLocal || this.showBeforeSignal)) {
        Canvas(this.overlayCtx)
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
          .onReady(() => {
            this.redrawOverlay();
          });
      }

      // 手动白平衡取样锚点：一个可拖拽的圆环，拖到白色/中性灰区域取点。
      // 只在这一模式下挂载并独占单指触摸，避免同时触发平移或看原图。
      if (this.wbPicking) {
        Stack() {
          Circle().width(EditorCanvas.WB_ANCHOR_RADIUS * 2)
            .height(EditorCanvas.WB_ANCHOR_RADIUS * 2)
            .fill(Color.Transparent)
            .stroke('rgba(0,0,0,0.45)').strokeWidth(4);
          Circle().width(EditorCanvas.WB_ANCHOR_RADIUS * 2)
            .height(EditorCanvas.WB_ANCHOR_RADIUS * 2)
            .fill(Color.Transparent)
            .stroke(Color.White).strokeWidth(1.5);
          Circle().width(10).height(10)
            .fill(Color.White).stroke('rgba(0,0,0,0.5)').strokeWidth(1);
        }
        .width(EditorCanvas.WB_ANCHOR_RADIUS * 2 + 20)
        .height(EditorCanvas.WB_ANCHOR_RADIUS * 2 + 20)
        .position({
          x: this.wbAnchorX - EditorCanvas.WB_ANCHOR_RADIUS - 10,
          y: this.wbAnchorY - EditorCanvas.WB_ANCHOR_RADIUS - 10,
        })
        .hitTestBehavior(HitTestMode.Block)
        .gesture(
          PanGesture({ distance: 0 })
            .onActionStart(() => {
              this.wbDragStartX = this.wbAnchorX;
              this.wbDragStartY = this.wbAnchorY;
            })
            .onActionUpdate((event: GestureEvent) => {
              this.moveWhiteBalanceAnchor(event.offsetX, event.offsetY);
            })
            .onActionEnd(() => {
              this.sampleWhiteBalanceAnchor();
            })
        );
      }

      // 取色模式：画面顶部给一条明确提示，说明这一下点按会取走颜色，而不是
      // 长按切原图。放在画面内而不是面板里，用户视线不必离开照片。
      if (this.wbPicking) {
        Row() {
          Text('把锚点拖到画面里的白色或中性灰区域')
            .fontSize(12)
            .fontColor(this.night ? Color.White : VividNative.textPrimary)
            .backgroundColor(this.night ? 'rgba(20,28,42,0.72)' : VividNative.surfaceSub)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(14);
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: 14 })
        .hitTestBehavior(HitTestMode.None);
      }
      if (this.editSession.pointColor.picking) {
        Row() {
          Text('请在图片上点一下要调整的颜色')
            .fontSize(12)
            .fontColor(this.night ? Color.White : VividNative.textPrimary)
            .backgroundColor(this.night ? 'rgba(20,28,42,0.72)' : VividNative.surfaceSub)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(14);
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: 14 })
        .hitTestBehavior(HitTestMode.None)
        .id('point-color-hint-' + this.pointColorUiRevision.toString());
      }
      if (this.showBeforeLocal || this.showBeforeSignal) {
        Text('原图')
          .fontSize(12)
          // 日间：浅灰底 + 系统主文字色（白字落在浅灰上看不清）；夜间：深色底 + 纯白字。
          .fontColor(this.night ? Color.White : VividNative.textPrimary)
          .backgroundColor(this.night ? 'rgba(20,28,42,0.72)' : VividNative.surfaceSub)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(14)
          .position({ x: 14, y: 14 });
      }
      if (this.windowWidth >= 840) {
        // Keep a stable leaf focus target: focusing a Stack scope may forward
        // keys to the native XComponent rather than this ArkUI handler.
        Text('').id('editor-canvas-keyboard').width(1).height(1).opacity(0)
          .position({ x: 0, y: 0 }).hitTestBehavior(HitTestMode.None)
          .focusable(true).tabStop(true)
          .onKeyEvent((event: KeyEvent) => { this.handleKeyEvent(event); })
          .onFocus(() => {
            this.canvasFocused = true;
          })
          .onBlur(() => {
            this.canvasFocused = false;
            this.keyDispatcher.releaseAll();
          });
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(255,255,255,0)')
    .clip(true)
    .id('editor-canvas')
    .focusable(true)
    .focusOnTouch(true)
    .onClick(() => {
      this.focusCanvasForKeys();
    })
    .onAreaChange((_: Area, newArea: Area) => {
      this.canvasWidth = newArea.width as number;
      this.canvasHeight = newArea.height as number;
      this.redrawOverlay();
    })
    .onAppear(() => {
      // The component is now really on screen. A publish that landed between
      // the @StorageProp initial read and this point was never delivered as a
      // watch, so re-adopt the current version here and repaint once.
      this.adoptPublishedFrame('appear');
    })
    .onTouch((event: TouchEvent) => {
      // 白平衡取点期间单指手势全部交给锚点：这一下不能同时启动画笔、
      // 平移或「按住看原图」。双指缩放/平移不受影响。
      if (this.wbPicking) return;
      if (event.type === TouchType.Down && this.windowWidth >= 840 &&
        !this.modalOpen && !this.exportActive) {
        // Give touch users the same stable keyboard focus as a mouse click.
        
        this.focusCanvasForKeys();
      }
      if (event.touches.length <= 1) {
        // 点颜色取色优先于所有单指手势：取色时这一下点按属于吸管，不能同时
        // 触发“按住看原图”、平移或蒙版笔迹。双指缩放/平移不受影响（走 else）。
        if (this.editSession.pointColor.picking) {
          this.handlePointColorPickTouch(event);
          return;
        }
        // 点选对焦优先于「按住看原图」：大光圈面板进入取点模式后，这一下点按
        // 属于焦点取样，不能同时被原图预览吃掉。
        if (AppStorage.get<boolean>('bokehFocusPicking') === true) {
          this.handleBokehFocusTouch(event);
          return;
        }
        // 普通预览模式下，画布卡片（包括图片周围的空白区域）都承担
        // Before/After 触摸反馈，避免系统长按捕获手势抢占交互。
        if (this.editSession.activeTool === ToolType.HEAL || this.editSession.activeTool === ToolType.RED_EYE) {
          this.handleRetouchTouch(event);
        } else if (this.editSession.activeTool === ToolType.UPRIGHT) {
          this.handleUprightTouch(event);
        } else if (this.editSession.activeTool === ToolType.CROP || this.isMaskTool() ||
          this.brushPartSelected() || AppStorage.get<boolean>('maskRangePickerOpen') === true) {
          this.handleTouch(event);
        } else if (this.canPanPhoto()) {
          this.handleDesktopPhotoTouch(event);
        } else {
          this.handleBeforeTouch(event);
        }
      }
      else this.abortBrushStroke();
    })
    .gesture(
      GestureGroup(GestureMode.Parallel,
        PinchGesture({ fingers: 2 })
          .onActionStart(() => {
            // 双指手势优先于画笔：第一根手指可能已经落了笔，这里必须放弃它，
            // 否则缩放会顺手在图上留下笔迹。
            this.abortBrushStroke();
            this.pinchStartScale = this.editSession.canvasScale;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (this.editSession.isCropping) return;
            const scale = event.scale;
            if (scale && scale !== 1) {
              this.editSession.canvasScale = Math.max(0.5,
                Math.min(5, this.pinchStartScale * scale));
              this.scheduleDetailRequest();
              this.redrawOverlay();
            }
          }),
        PanGesture({ fingers: 2 })
          .onActionStart(() => {
            this.abortBrushStroke();
            this.panStartOffsetX = this.editSession.canvasOffsetX;
            this.panStartOffsetY = this.editSession.canvasOffsetY;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (this.editSession.isCropping) return;
            // Pan offsets are measured from the beginning of the gesture;
            // adding them on every frame caused drift and excessive motion.
            this.editSession.canvasOffsetX = this.panStartOffsetX + event.offsetX;
            this.editSession.canvasOffsetY = this.panStartOffsetY + event.offsetY;
            this.scheduleDetailRequest();
            this.redrawOverlay();
          }),
      )
    );
  }

  private canPanPhoto(): boolean {
    return this.windowWidth >= 840 && this.editSession.activeTool === ToolType.ADJUST &&
      !this.editSession.isCropping;
  }

  private focusCanvasForKeys(): void {
    if (this.windowWidth < 840 || this.modalOpen || this.exportActive) return;
    try {
      this.getUIContext().getFocusController().requestFocus('editor-canvas-keyboard');
    } catch (_error) {
      console.warn('VIVID_SHORTCUT canvas focus request failed');
    }
  }

  private handleDesktopPhotoTouch(event: TouchEvent): void {
    const touch = event.touches.length > 0 ? event.touches[0] : event.changedTouches[0];
    if (!touch) return;
    if (event.type === TouchType.Down) {
      this.desktopPanActive = true;
      this.desktopPanStartTouchX = touch.x;
      this.desktopPanStartTouchY = touch.y;
      this.desktopPanStartOffsetX = this.editSession.canvasOffsetX;
      this.desktopPanStartOffsetY = this.editSession.canvasOffsetY;
    } else if (event.type === TouchType.Move && this.desktopPanActive) {
      this.editSession.canvasOffsetX = this.desktopPanStartOffsetX +
        (touch.x - this.desktopPanStartTouchX);
      this.editSession.canvasOffsetY = this.desktopPanStartOffsetY +
        (touch.y - this.desktopPanStartTouchY);
      this.scheduleDetailRequest();
      this.redrawOverlay();
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.desktopPanActive = false;
      this.scheduleDetailRequest();
      this.redrawOverlay();
    }
  }

  /**
   * Key entry point. Auto-repeat and modifier state come from the framework; the
   * shared dispatcher decides what may run and keeps one-shot and hold state.
   */
  private handleKeyEvent(event: KeyEvent): void {
    const ctrl: boolean = this.modifierPressed(event, 'Ctrl');
    const shift: boolean = this.modifierPressed(event, 'Shift');
    const keyCode: number = event.keyCode;
    if (event.type === KeyType.Down) {
      const repeat: boolean = this.keyDispatcher.isArmed(keyCode) || this.keyDispatcher.isHolding(keyCode);
      const result: EditorDispatchResult = this.keyDispatcher.dispatchKeyDown(
        keyCode, ctrl, shift, repeat, this.keyboardContext());
      if (result === EditorDispatchResult.Handled) {
        // Consumed: stop the framework's own zoom/scale handling of Ctrl+= and
        // Ctrl+- and keep the event away from the panels behind the canvas.
        event.stopPropagation();
      }
      return;
    }
    if (event.type === KeyType.Up) {
      const result: EditorDispatchResult = this.keyDispatcher.dispatchKeyUp(keyCode, ctrl, shift);
      if (result === EditorDispatchResult.Handled) {
        event.stopPropagation();
      }
    }
  }

  /** ArkUI reports modifiers through getModifierKeyState when available. */
  private modifierPressed(event: KeyEvent, name: string): boolean {
    if (event.getModifierKeyState) {
      try {
        return event.getModifierKeyState([name]);
      } catch (_error) {
        return false;
      }
    }
    // Fall back to the event's own flags. ctrlKey/shiftKey are not part of every
    // KeyEvent build, so they are read defensively.
    const raw: object = event as object;
    const flag: number = name === 'Ctrl' ? this.numberField(raw, 'ctrlKey') : this.numberField(raw, 'shiftKey');
    return flag === 1;
  }

  private numberField(source: object, name: string): number {
    const value: number = (source as Record<string, number>)[name];
    return typeof value === 'number' ? value : 0;
  }

  private keyboardContext(): EditorKeyboardContext {
    return {
      inputFocused: this.inputFocused,
      modalOpen: this.modalOpen || this.exportActive,
      canvasFocused: this.canvasFocused,
      desktopLayout: this.windowWidth >= 840,
    };
  }

  /** Runs one business command. Buttons reach the same actions through this. */
  private runEditorCommand(id: EditorCommandId): void {
    switch (id) {
      case EditorCommandId.Undo:
        if (this.editSession.canUndo()) {
          this.editSession.undo();
          ImageProcessor.process(this.editSession);
        }
        return;
      case EditorCommandId.Redo:
        if (this.editSession.canRedo()) {
          this.editSession.redo();
          ImageProcessor.process(this.editSession);
        }
        return;
      case EditorCommandId.ZoomIn:
        this.adjustZoom(1);
        return;
      case EditorCommandId.ZoomOut:
        this.adjustZoom(-1);
        return;
      case EditorCommandId.ZoomFit:
        this.fitToWindow();
        return;
      case EditorCommandId.HoldOriginal:
        // Already showing the original keeps the state; the release path is what
        // turns the comparison off again.
        this.showBeforeLocal = true;
        ImageProcessor.setBeforePreview(this.editSession, true);
        return;
      case EditorCommandId.LeaveTool:
        this.leaveActiveTool();
        return;
      default:
        this.applyToolCommand(id);
        return;
    }
  }

  /** Ends a hold command. Called on key-up, on blur and on any reset. */
  private endEditorHold(id: EditorCommandId): void {
    if (id !== EditorCommandId.HoldOriginal) {
      return;
    }
    if (this.holdOriginalKey >= 0) {
      this.holdOriginalKey = -1;
    }
    this.showBeforeLocal = false;
    ImageProcessor.setBeforePreview(this.editSession, false);
  }

  private applyToolCommand(id: EditorCommandId): void {
    const tool: string = editorToolIdOf(id);
    if (tool.length === 0) {
      return;
    }
    this.selectTool(tool);
  }

  /** Tool selection shared by the toolbar buttons and the tool keys. */
  private selectTool(tool: string): void {
    if (tool === EDITOR_TOOL_ADJUST) {
      AppStorage.setOrCreate('editorPanelRequest', 0);
    } else if (tool === EDITOR_TOOL_CROP) {
      // Use the existing rail action, which also reveals the crop inspector
      // and preserves its source/preview geometry and commit semantics.
      AppStorage.setOrCreate('editorPanelRequest', 4);
      this.editSession.canvasScale = 1;
      this.editSession.canvasOffsetX = 0;
      this.editSession.canvasOffsetY = 0;
    } else if (tool === EDITOR_TOOL_BRUSH_MASK) {
      if (!this.editSession.activeMaskLayer) {
        this.editSession.createMaskLayer(MaskComponentType.BRUSH);
      } else if (this.editSession.activeMaskComponent?.type !== MaskComponentType.BRUSH) {
        this.editSession.addMaskComponent(MaskComponentType.BRUSH);
      }
      AppStorage.setOrCreate('editorPanelRequest', 1);
    } else if (tool === EDITOR_TOOL_UPRIGHT) {
      AppStorage.setOrCreate('editorPanelRequest', 4);
      this.editSession.setActiveTool(ToolType.UPRIGHT);
    } else {
      return;
    }
    ImageProcessor.process(this.editSession);
  }

  private leaveActiveTool(): void {
    if (this.editSession.isCropping || this.editSession.activeTool !== ToolType.ADJUST) {
      this.editSession.isCropping = false;
      this.editSession.setActiveTool(ToolType.ADJUST);
      ImageProcessor.process(this.editSession);
      return;
    }
    this.fitToWindow();
  }

  private adjustZoom(direction: number): void {
    if (this.showBeforeLocal || this.showBeforeSignal) return;
    const current = Math.max(0.5, Math.min(5, this.editSession.canvasScale));
    const next = direction > 0 ? current * 1.15 : current / 1.15;
    this.editSession.canvasScale = Math.max(0.5, Math.min(5, next));
    this.scheduleDetailRequest();
    this.redrawOverlay();
  }

  /** Lightcraft view.zoomFit / Compositor "Fit Canvas": back to the fit view. */
  private fitToWindow(): void {
    this.editSession.canvasScale = 1;
    this.editSession.canvasOffsetX = 0;
    this.editSession.canvasOffsetY = 0;
    this.scheduleDetailRequest();
    this.redrawOverlay();
  }

  /** 叠加层该画的范围：画笔/渐变工具，或选中的是算法生成的选区（亮度范围、主体、天空）。 */
  private showsMaskOverlay(): boolean {
    if (this.isMaskTool()) return true;
    // 画笔分量在工具是 ADJUST 时也要有叠加层画布，否则笔迹画进不存在的画布。
    // adjustmentScope=1 表示当前正在编辑局部（蒙版）而不只是全局调色。
    if (this.editSession.activeMaskLayer === null) return false;
    if (this.editSession.adjustmentScope !== 1) return false;
    return true;
  }

  /** 当前选中的分量是画笔：即使工具没切成 BRUSH_MASK 也要能落笔。 */
  private brushPartSelected(): boolean {
    const part = this.editSession.activeMaskComponent;
    return this.editSession.activeMaskLayer !== null && part !== null &&
      part.type === MaskComponentType.BRUSH;
  }

  /** 当前蒙版是否有位图型组件（主体/天空/范围），这些组件的边界要精细绘制。 */
  private activeRasterMask(): boolean {
    const layer = this.editSession.activeLayer;
    if (!layer) return false;
    for (const maskLayer of layer.maskLayers) {
      for (const component of maskLayer.components) {
        if (this.editSession.isRasterMaskComponent(component)) return true;
      }
    }
    return false;
  }

  private isMaskTool(): boolean {
    return this.editSession.activeTool === ToolType.BRUSH_MASK ||
      this.editSession.activeTool === ToolType.LINEAR_MASK ||
      this.editSession.activeTool === ToolType.RADIAL_MASK;
  }

  private handleTouch(event: TouchEvent): void {
    // 蒙版操作菜单开着时，图上第一下先用来关菜单（同时不阻塞笔迹）。
    if (AppStorage.get<boolean>('maskMenuOpen') === true) {
      // 菜单打开时画布不接受绘图，但不能在按下的那一瞬间就把菜单关掉：
      // 菜单项的 onClick 靠的是后续的抬指事件，菜单被提前卸掉就永远点不中。
      // 这里先吞掉手势，抬指后延迟一小会儿再判断：如果刚刚点过菜单项
      // （maskMenuActionAt）就保持打开，否则关闭。
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        setTimeout(() => {
          const lastAction = AppStorage.get<number>('maskMenuActionAt') ?? 0;
          if (Date.now() - lastAction > 500) AppStorage.setOrCreate('maskMenuOpen', false);
        }, 150);
      }
      return;
    }
    else if (this.editSession.activeTool === ToolType.CROP) this.handleCropTouch(event);
    else if (this.editSession.activeTool === ToolType.BRUSH_MASK) this.handleBrushMaskTouch(event);
    else if (this.editSession.activeTool === ToolType.LINEAR_MASK) this.handleLinearMaskTouch(event);
    else if (this.editSession.activeTool === ToolType.RADIAL_MASK) this.handleRadialMaskTouch(event);
    else if (this.brushPartSelected()) this.handleBrushMaskTouch(event);
  }

  private handleBeforeTouch(event: TouchEvent): void {
    console.info(`VIVID_FRAME t=${Date.now()} event=before_touch type=${event.type} ` +
      `src=${this.editSession.sourcePixelMap !== null} local=${this.showBeforeLocal} signal=${this.showBeforeSignal}`);
    if (event.type === TouchType.Down) {
      this.showBeforeLocal = true;
      ImageProcessor.setBeforePreview(this.editSession, true);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.showBeforeLocal = false;
      ImageProcessor.setBeforePreview(this.editSession, false);
    }
  }

  /**
   * Point-colour eyedropper: one tap reads the real source pixel under the
   * finger and hands it to the session as a new sample.
   *
   * Up, not Down, decides: a press that turns into a drag is a pan attempt and
   * must not sample wherever the finger happened to lift. The coordinate chain
   * is the shared `touchToSourcePoint` (displayed-image rect → normalized
   * display point → displayPointToSource), i.e. exactly what brush, retouch and
   * mask placement use, so crop, rotation, flip and the geometry pass are
   * undone before the pixel is read. It is never taken from the preview
   * thumbnail.
   */
  private handlePointColorPickTouch(event: TouchEvent): void {
    const touch = event.touches.length > 0 ? event.touches[0] : event.changedTouches[0];
    if (!touch) return;
    const local = this.canvasLocalTouch(touch);
    if (event.type === TouchType.Down) {
      this.pointColorPickStartX = local[0];
      this.pointColorPickStartY = local[1];
      this.pointColorPickMoved = false;
      return;
    }
    if (event.type === TouchType.Move) {
      if (!this.pointColorPickMoved &&
        Math.hypot(local[0] - this.pointColorPickStartX,
          local[1] - this.pointColorPickStartY) > EditorCanvas.POINT_COLOR_TAP_SLOP) {
        this.pointColorPickMoved = true;
      }
      return;
    }
    if (event.type !== TouchType.Up) return;
    if (this.pointColorPickMoved) {
      console.info(`VIVID_POINT_COLOR t=${Date.now()} event=pick_drag_ignored sid=${this.editSession.sessionId}`);
      return;
    }
    const point = this.touchToSourcePoint(touch);
    if (!point) {
      // A tap in the letterbox margin has no source pixel. Stay armed so the
      // user can simply tap the photo again instead of re-adding.
      console.info(`VIVID_POINT_COLOR t=${Date.now()} event=pick_outside sid=${this.editSession.sessionId}`);
      return;
    }
    this.pickPointColor(point.x, point.y);
  }

  /** Fire the async sample. The session re-checks the photo identity and the
   *  picking flag after the read, so a late result cannot land in the wrong
   *  state; this method only logs the outcome. */
  private pickPointColor(sourceX: number, sourceY: number): void {
    console.info(`VIVID_POINT_COLOR t=${Date.now()} event=pick_tap sid=${this.editSession.sessionId} ` +
      `x=${sourceX.toFixed(4)} y=${sourceY.toFixed(4)}`);
    this.editSession.pickPointColorAt(sourceX, sourceY).then((added: boolean): void => {
      console.info(`VIVID_POINT_COLOR t=${Date.now()} event=pick_result sid=${this.editSession.sessionId} ` +
        `added=${added} samples=${this.editSession.pointColor.samples.length}`);
    });
  }

  /** 锚点出现时落在画面中心并立刻取一次点：用户看到的第一帧就该是平衡后的结果。 */
  private onWhiteBalancePickingChanged(): void {
    if (!this.wbPicking) return;
    const rect = this.getDisplayedImageRect(false);
    if (rect[2] <= 1 || rect[3] <= 1) {
      this.wbAnchorX = this.canvasWidth / 2;
      this.wbAnchorY = this.canvasHeight / 2;
    } else {
      this.wbAnchorX = rect[0] + rect[2] / 2;
      this.wbAnchorY = rect[1] + rect[3] / 2;
    }
    this.sampleWhiteBalanceAnchor();
  }

  /** 拖拽把锚点限制在照片内，并按 90ms 节流取样（松手时补一次最终值）。 */
  private moveWhiteBalanceAnchor(offsetX: number, offsetY: number): void {
    const rect = this.getDisplayedImageRect(false);
    if (rect[2] <= 1 || rect[3] <= 1) return;
    const marginX = Math.min(EditorCanvas.WB_ANCHOR_RADIUS, rect[2] / 2);
    const marginY = Math.min(EditorCanvas.WB_ANCHOR_RADIUS, rect[3] / 2);
    this.wbAnchorX = Math.min(rect[0] + rect[2] - marginX,
      Math.max(rect[0] + marginX, this.wbDragStartX + offsetX));
    this.wbAnchorY = Math.min(rect[1] + rect[3] - marginY,
      Math.max(rect[1] + marginY, this.wbDragStartY + offsetY));
    if (Date.now() - this.wbSampleAt >= EditorCanvas.WB_SAMPLE_INTERVAL_MS) {
      this.sampleWhiteBalanceAnchor();
    }
  }

  /**
   * 锚点 → 归一化源坐标 → 在源图上取一块小区域解白平衡。
   * 映射走 `displayPointToSource`，和画笔、吸管同一条路径，所以裁切/旋转/拉直
   * 之后取到的仍是锚点下面的那块像素。
   */
  private sampleWhiteBalanceAnchor(): void {
    if (!this.wbPicking || this.wbSampling) return;
    const rect = this.getDisplayedImageRect(false);
    if (rect[2] <= 1 || rect[3] <= 1) return;
    const u = (this.wbAnchorX - rect[0]) / rect[2];
    const v = (this.wbAnchorY - rect[1]) / rect[3];
    if (u < 0 || u > 1 || v < 0 || v > 1) return;
    const source = this.editSession.displayPointToSource(u, v);
    if (!source) return;
    this.wbSampleAt = Date.now();
    this.wbSampling = true;
    ImageProcessor.pickWhiteBalanceAt(this.editSession, source[0], source[1])
      .then((applied: boolean): void => {
        this.wbSampling = false;
        if (!applied) return;
        ImageProcessor.process(this.editSession);
      });
  }

  private hasGeometryTransform(): boolean {
    const session = this.editSession;
    return session.rotation !== 0 || session.flipH || session.flipV ||
      session.cropLeft > 0.001 || session.cropTop > 0.001 ||
      session.cropRight < 0.999 || session.cropBottom < 0.999 ||
      geometryActive(session.geometry);
  }

  private getDisplayedImageRect(useSource: boolean = false): number[] {
    const canvasW = this.canvasWidth;
    const canvasH = this.canvasHeight;
    let imageW = useSource ? this.editSession.imageWidth : this.editSession.previewWidth;
    let imageH = useSource ? this.editSession.imageHeight : this.editSession.previewHeight;
    if (imageW <= 0 || imageH <= 0) {
      imageW = this.editSession.imageWidth;
      imageH = this.editSession.imageHeight;
    }
    if (canvasW <= 0 || canvasH <= 0 || imageW <= 0 || imageH <= 0) return [0, 0, 1, 1];
    const fitScale = Math.min(canvasW / imageW, canvasH / imageH) *
      (this.windowWidth >= 840 ? 0.98 : 0.85) * this.editSession.canvasScale;
    const drawW = imageW * fitScale;
    const drawH = imageH * fitScale;
    const left = (canvasW - drawW) / 2 + this.editSession.canvasOffsetX;
    const top = (canvasH - drawH) / 2 + this.editSession.canvasOffsetY;
    return [left, top, drawW, drawH];
  }

  private getDetailImageRect(): number[] {
    const rect = this.getDisplayedImageRect(false);
    const region = this.editSession.detailRegion;
    if (!region) return [0, 0, 0, 0];
    return [
      rect[0] + rect[2] * region.left,
      rect[1] + rect[3] * region.top,
      rect[2] * region.width,
      rect[3] * region.height,
    ];
  }

  /** Crop frame drags edit the session's working rect, which lives in the
   * DISPLAYED image's normalized space. It is an overlay only: the preview
   * keeps showing the applied crop, and the frame becomes the new crop when
   * the user presses apply (commitCropWorking). */
  private handleCropTouch(event: TouchEvent): void {
    const touch = event.touches[0];
    if (!touch) return;
    const imageRect = this.getDisplayedImageRect(false);
    const imageLeft = imageRect[0];
    const imageTop = imageRect[1];
    const imageWidth = imageRect[2];
    const imageHeight = imageRect[3];
    const working = this.editSession.cropWorking;
    const cropLeft = imageLeft + working[0] * imageWidth;
    const cropTop = imageTop + working[1] * imageHeight;
    const cropRight = imageLeft + working[2] * imageWidth;
    const cropBottom = imageTop + working[3] * imageHeight;
    const handleRadius = 28;

    if (event.type === TouchType.Down) {
      this.cropStartRect = working.slice();
      this.cropStartTouch = [touch.x, touch.y];
      const nearTL = Math.hypot(touch.x - cropLeft, touch.y - cropTop) < handleRadius;
      const nearTR = Math.hypot(touch.x - cropRight, touch.y - cropTop) < handleRadius;
      const nearBL = Math.hypot(touch.x - cropLeft, touch.y - cropBottom) < handleRadius;
      const nearBR = Math.hypot(touch.x - cropRight, touch.y - cropBottom) < handleRadius;
      if (nearTL) this.cropDragCorner = 0;
      else if (nearTR) this.cropDragCorner = 1;
      else if (nearBL) this.cropDragCorner = 2;
      else if (nearBR) this.cropDragCorner = 3;
      else if (touch.x >= cropLeft && touch.x <= cropRight && touch.y >= cropTop && touch.y <= cropBottom) {
        this.cropDragCorner = 4;
      } else {
        this.cropDragCorner = -1;
      }
    } else if (event.type === TouchType.Move && this.cropDragCorner >= 0) {
      let dx = (touch.x - this.cropStartTouch[0]) / imageWidth;
      let dy = (touch.y - this.cropStartTouch[1]) / imageHeight;
      let left = this.cropStartRect[0];
      let top = this.cropStartRect[1];
      let right = this.cropStartRect[2];
      let bottom = this.cropStartRect[3];
      if (this.cropDragCorner === 4) {
        dx = Math.max(-left, Math.min(1 - right, dx));
        dy = Math.max(-top, Math.min(1 - bottom, dy));
        left += dx; top += dy; right += dx; bottom += dy;
      } else {
        if (this.cropDragCorner === 0) { left += dx; top += dy; }
        else if (this.cropDragCorner === 1) { right += dx; top += dy; }
        else if (this.cropDragCorner === 2) { left += dx; bottom += dy; }
        else if (this.cropDragCorner === 3) { right += dx; bottom += dy; }
      }
      const fitted = this.editSession.fitWorkingRect(left, top, right, bottom,
        this.editSession.cropAspectRatio, this.cropDragCorner);
      if (fitted) this.editSession.cropWorking = fitted;
      this.drawCropOverlay();
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.cropDragCorner = -1;
      this.drawCropOverlay();
    }
  }

  private drawCropOverlay(): void {
    const ctx = this.overlayCtx;
    const canvasW = this.canvasWidth;
    const canvasH = this.canvasHeight;
    ctx.clearRect(0, 0, canvasW, canvasH);
    // The preview always shows the applied crop, and the working frame is
    // normalized against that displayed image, so no source-space mapping is
    // needed here.
    const imageRect = this.getDisplayedImageRect(false);
    const imageLeft = imageRect[0];
    const imageTop = imageRect[1];
    const imageWidth = imageRect[2];
    const imageHeight = imageRect[3];
    const working = this.editSession.cropWorking;
    const left = imageLeft + working[0] * imageWidth;
    const top = imageTop + working[1] * imageHeight;
    const right = imageLeft + working[2] * imageWidth;
    const bottom = imageTop + working[3] * imageHeight;
    const cropW = right - left;
    const cropH = bottom - top;
    ctx.fillStyle = 'rgba(20, 27, 39, 0.62)';
    ctx.fillRect(imageLeft, imageTop, imageWidth, Math.max(0, top - imageTop));
    ctx.fillRect(imageLeft, bottom, imageWidth, Math.max(0, imageTop + imageHeight - bottom));
    ctx.fillRect(imageLeft, top, Math.max(0, left - imageLeft), cropH);
    ctx.fillRect(right, top, Math.max(0, imageLeft + imageWidth - right), cropH);
    ctx.strokeStyle = 'rgba(255,255,255,0.46)';
    ctx.lineWidth = 1;
    for (let index = 1; index < 3; index++) {
      const gridX = left + cropW * index / 3;
      const gridY = top + cropH * index / 3;
      ctx.beginPath(); ctx.moveTo(gridX, top); ctx.lineTo(gridX, bottom); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(left, gridY); ctx.lineTo(right, gridY); ctx.stroke();
    }
    ctx.strokeStyle = '#FF2020';
    ctx.lineWidth = 2;
    ctx.strokeRect(left, top, cropW, cropH);
    ctx.fillStyle = '#FFFFFF';
    const corners: number[][] = [[left, top], [right, top], [left, bottom], [right, bottom]];
    for (let index = 0; index < corners.length; index++) {
      ctx.beginPath(); ctx.arc(corners[index][0], corners[index][1], 7, 0, Math.PI * 2); ctx.fill();
    }
  }

  /**
   * 画布全局原点（vp），用于把窗口坐标换算成画布局部坐标。
   *
   * 为什么要绕这一圈：`touch.x/y` 是**相对于事件目标组件**的坐标。画布里的
   * 预览图/叠加层各自带了 scale + translate 变换，一旦命中目标是这些子节点，
   * x/y 就落在"子节点自己的局部坐标系"里（命中测试会按变换反解），于是同一
   * 个手势在缩放后得到的坐标与画布空间的矩形算法不再一致——表现就是笔迹跟着
   * 缩放但缩放比例不对。改用窗口坐标减去画布自身的全局原点，与命中谁、子节点
   * 怎么变换都无关。
   */
  private canvasGlobalOrigin(): number[] | null {
    try {
      const info = componentUtils.getRectangleById('editor-canvas');
      const context = this.getUIContext();
      // getRectangleById 返回 px，窗口坐标是 vp，必须换算后再相减。
      return [context.px2vp(info.windowOffset.x), context.px2vp(info.windowOffset.y)];
    } catch (_error) {
      return null;
    }
  }

  /** 触摸点换算到画布局部坐标；取不到画布矩形时退回 ArkUI 上报的局部坐标。 */
  private canvasLocalTouch(touch: TouchObject): number[] {
    const origin = this.canvasGlobalOrigin();
    if (origin !== null) return [touch.windowX - origin[0], touch.windowY - origin[1]];
    return [touch.x, touch.y];
  }

  private touchToSourcePoint(touch: TouchObject): BrushPoint | null {
    const imageRect = this.getDisplayedImageRect(false);
    const local = this.canvasLocalTouch(touch);
    const u = (local[0] - imageRect[0]) / imageRect[2];
    const v = (local[1] - imageRect[1]) / imageRect[3];
    if (u < 0 || u > 1 || v < 0 || v > 1) return null;
    // One mapping for every tool. Hard-coded quarter-turn math worked while the
    // manual geometry pass was identity; straighten, perspective or auto-crop
    // moved the pixels without moving the tap, so brush and retouch landed on
    // the wrong source location.
    const source = this.editSession.displayPointToSource(u, v);
    if (!source) return null;
    const point = new BrushPoint();
    point.x = source[0];
    point.y = source[1];
    point.radius = this.editSession.brushSize;
    point.hardness = this.editSession.brushHardness;
    return point;
  }

  /**
   * 大光圈「点选对焦主体」：把这一次点按换算成源图坐标，在同一位置的深度
   * 图上取 5×5 邻域，写回 `bokeh.focus`。深度图不随几何变换，所以必须用
   * `displayPointToSource` 之后的源坐标，而不是画布上的屏幕坐标。
   */
  private handleBokehFocusTouch(event: TouchEvent): void {
    if (event.type !== TouchType.Down) return;
    const depth = this.editSession.bokehDepth;
    if (!depth || this.editSession.bokehDepthWidth <= 0 || this.editSession.bokehDepthHeight <= 0) {
      AppStorage.setOrCreate('bokehFocusPicking', false);
      return;
    }
    const touch = event.touches[0] ?? event.changedTouches[0];
    if (!touch) return;
    const point = this.touchToSourcePoint(touch);
    if (!point) return;
    // displayPointToSource 返回的是归一化源坐标（0..1），不是像素坐标；
    // 深度图同样按归一化坐标采样，不要再除以 imageWidth/Height。
    const u = point.x;
    const v = point.y;
    const focus = BokehSettings.focusFromDepth(depth,
      this.editSession.bokehDepthWidth, this.editSession.bokehDepthHeight, u, v);
    this.editSession.pushUndo();
    this.editSession.bokeh.focus = focus;
    AppStorage.setOrCreate('bokehFocusPicking', false);
    this.editSession.requestProcessing();
    AppStorage.setOrCreate('bokehRevision', Date.now());
    console.info(`VIVID_BOKEH focus pick u=${u.toFixed(3)} v=${v.toFixed(3)} focus=${focus.toFixed(3)}`);
    try {
      promptAction.showToast({ message: `焦点 ${Math.round(focus * 100)}%`, duration: 1200 });
    } catch (_error) { /* toast is optional */ }
    ImageProcessor.process(this.editSession);
  }

  private handleRetouchTouch(event: TouchEvent): void {
    const touch = event.touches[0] ?? event.changedTouches[0];
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.retouchGesture) {
        this.retouchGesture = false; this.lastRetouchPoint = null; this.retouchAnchor = null;
        this.editSession.bumpProcessing();
        AppStorage.setOrCreate('retouchRevision', Date.now());
        ImageProcessor.process(this.editSession);
      }
      return;
    }
    if (!touch) return;
    const point = this.touchToSourcePoint(touch);
    if (!point) return;
    if (this.editSession.pickingRetouchSource) {
      if (event.type === TouchType.Down) {
        this.editSession.retouchSource = [point.x, point.y];
        this.editSession.pickingRetouchSource = false;
        AppStorage.setOrCreate('retouchRevision', Date.now());
      }
      return;
    }
    if (event.type === TouchType.Down) {
      this.editSession.pushUndo(); this.retouchGesture = true; this.retouchAnchor = point;
    }
    else if (!this.retouchGesture || this.editSession.retouchKind === 'redeye') return;
    if (this.lastRetouchPoint && Math.hypot(point.x - this.lastRetouchPoint.x, point.y - this.lastRetouchPoint.y) < this.editSession.retouchSize / 3) return;
    if (this.editSession.retouchMarks.length >= 512) return;
    const mark: RetouchMark = { id: Date.now().toString(36) + '-' + this.editSession.retouchMarks.length,
      kind: this.editSession.retouchKind,
      x: point.x, y: point.y, radius: this.editSession.retouchSize, feather: this.editSession.retouchFeather,
      amount: this.editSession.retouchAmount,
      sourceX: this.editSession.retouchSource[0] + point.x - (this.retouchAnchor?.x ?? point.x),
      sourceY: this.editSession.retouchSource[1] + point.y - (this.retouchAnchor?.y ?? point.y) };
    // Heal and clone both read a second location, so an out-of-frame source would
    // sample nothing; fill and redeye do not read one at all.
    if ((mark.kind === 'heal' || mark.kind === 'clone') &&
      (mark.sourceX < 0 || mark.sourceX > 1 || mark.sourceY < 0 || mark.sourceY > 1)) return;
    this.editSession.retouchMarks = this.editSession.retouchMarks.concat([mark]);
    this.lastRetouchPoint = point;
    AppStorage.setOrCreate('retouchRevision', Date.now());
  }

  private sourcePointToCanvas(point: BrushPoint): number[] {
    const rect = this.getDisplayedImageRect(false);
    const display = this.editSession.sourcePointToDisplay(point.x, point.y);
    if (!display) {
      // Outside the published frame (for example a healed source sample that
      // the auto-crop pushed out). Park the marker at the frame edge instead of
      // drawing a handle at a wrong location.
      return [rect[0] - 4, rect[1] - 4];
    }
    return [rect[0] + display[0] * rect[2], rect[1] + display[1] * rect[3]];
  }

  /**
   * 坐标链路的临时诊断：记录一次落笔从画布坐标 → 归一化显示坐标 → 源图坐标
   * → 再映射回显示坐标的全过程。
   *
   * 正反两个方向若不能互逆，说明是触摸映射本身错；若严格互逆，笔迹错位就发生
   * 在下游（栅格化用的坐标系/几何）——两者修法完全不同。只在落笔时打一行，
   * 不随移动刷屏。
   */
  /**
   * 预览节点的**实测**矩形（画布局部坐标，vp）。
   *
   * 这是判断"矩形公式是否等于真实渲染位置"的唯一客观依据：公式自洽不代表它等
   * 于 ArkUI 实际把图放在哪里（例如 translate 与 scale 的先后顺序）。先把实测值
   * 和公式值一起打出来，再决定改哪一边，而不是继续猜。
   */
  private measuredNodeRect(): number[] | null {
    try {
      const info = componentUtils.getRectangleById('vivid-editor-gpu');
      const context = this.getUIContext();
      const origin = this.canvasGlobalOrigin();
      const x = context.px2vp(info.windowOffset.x);
      const y = context.px2vp(info.windowOffset.y);
      const scaleX = info.scale?.x ?? 1;
      const scaleY = info.scale?.y ?? 1;
      const width = context.px2vp(info.size.width) * scaleX;
      const height = context.px2vp(info.size.height) * scaleY;
      return origin !== null
        ? [x - origin[0], y - origin[1], width, height, scaleX, scaleY]
        : [x, y, width, height, scaleX, scaleY];
    } catch (_error) {
      return null;
    }
  }

  private logShapeMapping(touch: TouchObject): void {
    const rect = this.getDisplayedImageRect(false);
    const local = this.canvasLocalTouch(touch);
    const u = (local[0] - rect[0]) / rect[2];
    const v = (local[1] - rect[1]) / rect[3];
    const source = this.editSession.displayPointToSource(u, v);
    const back = source ? this.editSession.sourcePointToDisplay(source[0], source[1]) : null;
    const real = this.measuredNodeRect();
    // 同时打印 ArkUI 上报的局部坐标、窗口坐标换算结果，以及预览节点的实测矩形：
    // 三者对齐与否，能直接区分"触摸基准错"和"渲染基准与公式不一致"。
    console.info(`VIVID_SHAPE t=${Date.now()} event=touch_map rawX=${touch.x.toFixed(1)} ` +
      `rawY=${touch.y.toFixed(1)} winX=${touch.windowX.toFixed(1)} winY=${touch.windowY.toFixed(1)} ` +
      `local=${local[0].toFixed(1)},${local[1].toFixed(1)} ` +
      `cw=${this.canvasWidth.toFixed(1)} ch=${this.canvasHeight.toFixed(1)} ` +
      `rect=${rect[0].toFixed(1)},${rect[1].toFixed(1)},${rect[2].toFixed(1)},${rect[3].toFixed(1)} ` +
      `real=${real ? real.map((value: number) => value.toFixed(1)).join(',') : 'null'} ` +
      `scale=${this.editSession.canvasScale.toFixed(3)} off=${this.editSession.canvasOffsetX.toFixed(1)},` +
      `${this.editSession.canvasOffsetY.toFixed(1)} uv=${u.toFixed(5)},${v.toFixed(5)} ` +
      `src=${source ? source[0].toFixed(5) + ',' + source[1].toFixed(5) : 'null'} ` +
      `back=${back ? back[0].toFixed(5) + ',' + back[1].toFixed(5) : 'null'} ` +
      `srcDim=${this.editSession.imageWidth}x${this.editSession.imageHeight} ` +
      `prevDim=${this.editSession.previewWidth}x${this.editSession.previewHeight} ` +
      `rot=${this.editSession.rotation} flip=${this.editSession.flipH ? 1 : 0}${this.editSession.flipV ? 1 : 0} ` +
      `crop=${this.editSession.cropLeft.toFixed(3)},${this.editSession.cropTop.toFixed(3)},` +
      `${this.editSession.cropRight.toFixed(3)},${this.editSession.cropBottom.toFixed(3)} ` +
      `strokes=${this.editSession.activeMaskComponent?.brushData?.strokes.length ?? 0}`);
  }

  private handleBrushMaskTouch(event: TouchEvent): void {
    // 正在拖大小滑杆时不接受画笔操作：这时画面上只有笔头预览圆。
    if (this.brushSizing) return;
    // 按在工具列 / 盖章上的那一笔直接丢掉：悬浮控件是透清命中测试，
    // 不这样拦的话点按钮会同时在画面上落一笔。
    if (event.type === TouchType.Down && this.touchHitsMaskUi(event.touches.length > 0 ? event.touches[0] : null)) {
      this.suppressBrushStroke = true;
      return;
    }
    if (this.suppressBrushStroke) {
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.suppressBrushStroke = false;
      return;
    }
    if (event.type === TouchType.Down) {
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (event.type === TouchType.Up && this.currentStroke && event.changedTouches.length > 0) {
        const last = this.touchToSourcePoint(event.changedTouches[0]);
        if (last) this.currentStroke.points.push(last);
      }
      this.commitBrushStroke();
      return;
    }
    const touch = event.touches[0];
    if (!touch) return;
    // 双指缩放/移动时必须放弃这一笔：第二根手指落下时第一根手指已经落过笔，
    // 那一笔只属于"以为是画笔"的误触，不能留在蒙版里。
    if (event.touches.length > 1) {
      this.abortBrushStroke();
      return;
    }
    const point = this.touchToSourcePoint(touch);
    if (event.type === TouchType.Down) {
      if (!point) return;
      let component = this.editSession.activeMaskComponent;
      if (!component || component.type !== MaskComponentType.BRUSH) {
        if (this.editSession.activeMaskLayer) {
          component = this.editSession.addMaskComponent(MaskComponentType.BRUSH);
        } else {
          const created = this.editSession.createMaskLayer(MaskComponentType.BRUSH);
          component = created ? created.components[0] : null;
        }
      }
      if (!component) return;
      component.ensureData();
      this.logShapeMapping(touch);
      const stroke = new BrushStroke();
      stroke.mode = this.editSession.maskBrushMode;
      stroke.flow = this.editSession.brushFlow; stroke.density = this.editSession.brushDensity;
      stroke.points.push(point);
      if (component.brushData) {
        // 自动蒙版是画笔工具的一个开关：落笔时把当前开关状态写进该分量的
        // brushData，开关只影响之后刷的笔画，已有笔画保持原样。
        component.brushData.autoMask = this.editSession.brushAutoMask;
        component.brushData.sensitivity = this.editSession.brushAutoMaskSensitivity;
        // 落笔前把源 RGB 代理准备好，否则这一笔只能在"无门限"下先显示。
        if (this.editSession.brushAutoMask) ImageProcessor.ensureAutoMaskProxy(this.editSession);
        component.brushData.strokes.push(stroke);
      }
      this.currentStroke = stroke;
      this.strokeProvisional = true;
      this.strokeUndoPushed = false;
      this.strokeComponentId = component.id;
      // 连续下笔时取消上一笔安排的整图处理：那一趟要上百毫秒，落在 UI 线程上
      // 就是"画第二笔会卡住"。等用户真正停手 260ms 再算。
      if (this.reprocessTimer !== -1) {
        clearTimeout(this.reprocessTimer);
        this.reprocessTimer = -1;
      }
      this.brushCursor = point;
      this.drawMaskOverlay();
    } else if (event.type === TouchType.Move) {
      if (!point || !this.currentStroke || this.strokeComponentId !== this.editSession.selectedMaskComponentId) return;
      // 撤销点在笔迹真正成立时才压栈：一笔如果被双指手势取消，就不该留下
      // 一个"撤销了什么都没变"的撤销步。
      if (this.strokeProvisional) {
        this.strokeProvisional = false;
        this.editSession.pushUndo();
        this.strokeUndoPushed = true;
      }
      // 采样去重：手指移动每 1px 一个点会把一笔刷成两百多个点，而栅格化
      // （CPU + 原生两条路径）和整图合成都按点数摊成本——真机上一笔就能把
      // UI 线程堵到 3 秒以上，系统按 ANR 直接把编辑器杀掉。
      const lastPoint = this.currentStroke.points.length > 0
        ? this.currentStroke.points[this.currentStroke.points.length - 1] : null;
      const minStep = Math.max(0.004, this.editSession.brushSize * 0.3);
      if (lastPoint !== null) {
        const step = Math.hypot(point.x - lastPoint.x, point.y - lastPoint.y);
        if (step < minStep) return;
      }
      // 兜底上限：单笔点数封顶，长笔画也只按上限走一次栅格化。
      if (this.currentStroke.points.length >= 120) return;
      this.currentStroke.points.push(point);
      this.brushCursor = point;
      this.scheduleMaskOverlay();
    }
  }

  /**
   * 双指手势（缩放/移动）抢走触摸时取消当前这一笔。
   *
   * 只删掉这一笔本身，不动别的笔画；撤销点如果已经压过就一并回退，避免留下
   * 空撤销步。画笔分量的创建也一并撤销——双指缩放不该顺手建出一个蒙版分量。
   */
  private abortBrushStroke(): void {
    const stroke = this.currentStroke;
    if (!stroke) return;
    this.currentStroke = null;
    this.brushCursor = null;
    const layer = this.editSession.activeMaskLayer;
    const component = this.strokeComponentId.length > 0
      ? layer?.components.find((item: MaskComponent) => item.id === this.strokeComponentId) : undefined;
    if (component?.brushData) {
      const index = component.brushData.strokes.indexOf(stroke);
      if (index >= 0) component.brushData.strokes.splice(index, 1);
      if (component.brushData.strokes.length === 0) {
        // 这一笔是这个分量唯一的内容：把整个空分量删掉，别留空壳。
        if (layer) {
          const partIndex = layer.components.indexOf(component);
          if (partIndex >= 0) layer.components.splice(partIndex, 1);
        }
      }
    }
    this.strokeComponentId = '';
    if (this.strokeUndoPushed) this.editSession.undoStack.pop();
    this.strokeUndoPushed = false;
    this.strokeProvisional = false;
    if (this.maskOverlayTimer >= 0) clearTimeout(this.maskOverlayTimer);
    this.maskOverlayTimer = -1;
    if (layer) this.editSession.invalidateLayerMaskCache(layer.id);
    this.editSession.notifyMaskRevision();
    this.editSession.requestProcessing();
    this.drawMaskOverlay();
  }

  private commitBrushStroke(): void {
    if (this.currentStroke && this.strokeProvisional) {
      // 单指点一下就抬手：算一个点状笔迹，仍然要能撤销。
      this.editSession.pushUndo();
      this.strokeUndoPushed = true;
    }
    this.strokeProvisional = false;
    this.strokeUndoPushed = false;
    this.finishBrushStroke();
  }

  private finishBrushStroke(): void {
    if (!this.currentStroke) return;
    this.currentStroke = null;
    // 抬笔后不立刻整层重栅格化（日志 raster=43~72ms，正是"抬笔一顿"的来源）：
    // 画布上已经画着这支笔的预览，先保持不动，等手停 350ms 再重算一次。
    this.strokeSettleUntil = Date.now() + 350;
    setTimeout(() => {
      this.strokeSettleUntil = 0;
      this.requestOverlayRedraw();
    }, 380);
    this.strokeComponentId = '';
    this.brushCursor = null;
    if (this.maskOverlayTimer >= 0) clearTimeout(this.maskOverlayTimer);
    this.maskOverlayTimer = -1;
    const layer = this.editSession.activeLayer;
    if (layer) this.editSession.invalidateLayerMaskCache(layer.id);
    this.editSession.activeMaskLayer?.touch();
    this.editSession.notifyMaskRevision();
    this.editSession.requestProcessing();
    this.drawMaskOverlay();
    this.scheduleReprocess();
  }

  private scheduleMaskOverlay(): void {
    if (this.maskOverlayTimer >= 0) return;
    // 覆盖层一帧要几十毫秒时，33ms 的节拍会让定时器排成长队，手指移动越久
    // 队列越长、界面越像卡死。上一帧超预算就跳过这一拍，只保证画面在更新。
    const cost = this.lastMaskOverlayMs;
    const delay = cost >= 45 ? 66 : 33;
    this.maskOverlayTimer = setTimeout(() => {
      this.maskOverlayTimer = -1;
      const frameStart = Date.now();
      this.drawMaskOverlay();
      this.lastMaskOverlayMs = Date.now() - frameStart;
    // MaskRenderer is intentionally sampled at a gesture-friendly 30fps.
    // The final stroke is still rendered immediately at full preview quality.
    }, 33);
  }

  aboutToDisappear(): void {
    // Leaving the editor with the eyedropper armed would keep the mode alive in
    // a session that can be re-entered later.
    this.editSession.cancelPointColorPick();
    // 离开编辑器还挂着白平衡锚点，下次进来会残留一个不可解释的取点模式。
    AppStorage.setOrCreate('wbPicking', false);
    if (this.reprocessTimer >= 0) clearTimeout(this.reprocessTimer);
    if (this.maskOverlayTimer >= 0) clearTimeout(this.maskOverlayTimer);
    if (this.detailTimer >= 0) clearTimeout(this.detailTimer);
    this.detailTimer = -1;
    this.onRequestDetailRender(null);
    this.currentStroke = null;
    this.maskSurfaceCanvas = null;
    this.maskSurface = null;
    this.committedMaskAlpha = null;
    this.committedMaskLayerId = '';
    this.committedMaskWidth = 0;
    this.committedMaskHeight = 0;
  }

  /** Debounce tile requests so pinch/pan frames never start a render each. */
  private scheduleDetailRequest(): void {
    // 长按看原图只是一次显示切换，编辑状态没变：此时既不该重算瓦片，更不该
    // 走下面那条"作废瓦片"的分支。此前按住期间仍会按 180ms 防抖请求，而每次
    // 预览发布又清掉瓦片，于是松手后必须再等一块新瓦片，期间露出有界预览 A。
    if (this.showBeforeLocal || this.showBeforeSignal) {
      if (this.detailTimer >= 0) clearTimeout(this.detailTimer);
      this.detailTimer = -1;
      return;
    }
    // 裁剪不再禁止高清瓦片。此前这里对 cropLeft/cropTop/cropRight/cropBottom 一刀切，
    // 结果是：只要裁过一次，之后无论怎么放大都再也不会请求高清局部渲染。而下游本来就
    // 完整支持裁剪——EditorPage.requestDetailRender 先把画布坐标按 cropLeft/宽度换算回
    // 源坐标（否则裁剪后放大会采到错的像素），再把瓦片会话的裁剪设成"瓦片内的相对可见区"。
    // 所以那条限制不是保护，而是把这个功能关掉了。
    if (this.editSession.canvasScale < this.detailZoomThreshold ||
      this.editSession.isCropping || this.editSession.rotation !== 0 ||
      this.editSession.flipH || this.editSession.flipV) {
      if (this.detailTimer >= 0) clearTimeout(this.detailTimer);
      this.detailTimer = -1;
      this.onRequestDetailRender(null);
      return;
    }
    if (this.detailTimer >= 0) clearTimeout(this.detailTimer);
    this.detailTimer = setTimeout(() => {
      this.detailTimer = -1;
      const region = this.getVisibleDetailRegion();
      this.onRequestDetailRender(region);
    }, 180);
  }

  /** Convert the current zoom/pan transform into a normalized source region. */
  private getVisibleDetailRegion(): DetailRegion | null {
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0 ||
      this.editSession.previewWidth <= 0 || this.editSession.previewHeight <= 0) return null;
    const rect = this.getDisplayedImageRect(false);
    if (rect[2] <= 0 || rect[3] <= 0) return null;
    let left = Math.max(0, Math.min(1, (0 - rect[0]) / rect[2]));
    let top = Math.max(0, Math.min(1, (0 - rect[1]) / rect[3]));
    let right = Math.max(0, Math.min(1, (this.canvasWidth - rect[0]) / rect[2]));
    let bottom = Math.max(0, Math.min(1, (this.canvasHeight - rect[1]) / rect[3]));
    // Add a small margin so a gentle pan does not immediately expose a seam.
    const marginX = Math.max(0.015, (right - left) * 0.12);
    const marginY = Math.max(0.015, (bottom - top) * 0.12);
    left = Math.max(0, left - marginX);
    top = Math.max(0, top - marginY);
    right = Math.min(1, right + marginX);
    bottom = Math.min(1, bottom + marginY);
    const width = right - left;
    const height = bottom - top;
    if (width <= 0 || height <= 0 || (width > 0.96 && height > 0.96)) return null;
    return { left: left, top: top, width: width, height: height };
  }

  private handleLinearMaskTouch(event: TouchEvent): void {
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const changed = this.linearDragPart >= 0 || this.pendingMaskCreate;
      this.linearDragPart = -1;
      this.pendingMaskCreate = false;
      // 单击（没拖出距离）什么都没改，不必重算蒙版与预览。
      if (!changed) return;
      const layer = this.editSession.activeLayer;
      if (layer) this.editSession.invalidateLayerMaskCache(layer.id);
      this.editSession.notifyMaskRevision();
      this.scheduleReprocess();
      this.drawMaskOverlay();
      return;
    }
    const touch = event.touches[0];
    if (!touch) return;
    const point = this.touchToSourcePoint(touch);
    if (event.type === TouchType.Down) {
      const pressed = this.editSession.activeMaskComponent;
      if (!pressed || pressed.type !== MaskComponentType.LINEAR_GRADIENT) {
        // 没有可编辑的线性分量：只记住按下点，等真的拖动再创建。
        if (point) this.beginPendingMaskCreate(touch, point);
        return;
      }
      pressed.ensureData();
      const current = pressed.linearGradientData;
      if (!current) return;
      const start = new BrushPoint();
      start.x = current.startX;
      start.y = current.startY;
      const end = new BrushPoint();
      end.x = current.endX;
      end.y = current.endY;
      const startCanvas = this.sourcePointToCanvas(start);
      const endCanvas = this.sourcePointToCanvas(end);
      if (Math.hypot(touch.x - startCanvas[0], touch.y - startCanvas[1]) < 26) {
        // Dragging the start anchor moves the existing mask position.
        this.editSession.pushUndo();
        this.linearDragPart = 0;
      } else if (Math.hypot(touch.x - endCanvas[0], touch.y - endCanvas[1]) < 26) {
        this.editSession.pushUndo();
        this.linearDragPart = 1;
      } else if (point) {
        // 空白处按下：先不动作，拖出距离后才把这个渐变重画到手指下。
        this.beginPendingMaskCreate(touch, point);
      }
      this.drawMaskOverlay();
      return;
    }
    if (event.type === TouchType.Move && this.pendingMaskCreate &&
      this.pendingDragExceeded(touch)) {
      let target = this.editSession.activeMaskComponent;
      const editable = !!target && target.type === MaskComponentType.LINEAR_GRADIENT;
      this.editSession.pushUndo();
      if (!editable) {
        if (this.editSession.activeMaskLayer) {
          target = this.editSession.addMaskComponent(
            MaskComponentType.LINEAR_GRADIENT, MaskBlendMode.ADD);
        } else {
          const created = this.editSession.createMaskLayer(MaskComponentType.LINEAR_GRADIENT);
          target = created ? created.components[0] : null;
        }
      }
      if (!target) {
        this.pendingMaskCreate = false;
        return;
      }
      target.ensureData();
      const data = target.linearGradientData;
      if (!data) {
        this.pendingMaskCreate = false;
        return;
      }
      // 起点是按下点，终点立即跟手：一次拖拽同时给出位置与方向。
      data.startX = this.pendingSourceX;
      data.startY = this.pendingSourceY;
      data.endX = point ? point.x : this.pendingSourceX;
      data.endY = point ? point.y : this.pendingSourceY;
      // 没有真正拖出方向（点按）时用默认方向：从上到下。
      const spanX = data.endX - data.startX;
      const spanY = data.endY - data.startY;
      if (spanX * spanX + spanY * spanY < 0.0004) {
        data.startX = 0.5;
        data.startY = 0.0;
        data.endX = 0.5;
        data.endY = 1.0;
      }
      this.pendingMaskCreate = false;
      this.linearDragPart = 1;
      this.scheduleMaskOverlay();
      return;
    }
    const dragTarget = this.editSession.activeMaskComponent;
    if (!dragTarget || dragTarget.type !== MaskComponentType.LINEAR_GRADIENT) return;
    dragTarget.ensureData();
    const data = dragTarget.linearGradientData;
    if (!data) return;
    if (event.type === TouchType.Move && this.linearDragPart >= 0) {
      if (!point) return;
      if (this.linearDragPart === 0) {
        data.startX = point.x;
        data.startY = point.y;
      } else {
        data.endX = point.x;
        data.endY = point.y;
      }
    }
    // Do not rasterize the composed mask synchronously for every move event.
    // The throttled overlay keeps the anchors responsive while the final
    // geometry is still committed on Up/Cancel.
    if (event.type === TouchType.Move) this.scheduleMaskOverlay();
    else this.drawMaskOverlay();
  }

  /** 记住按下点：只有手指离开超过阈值才真的改动蒙版。 */
  private beginPendingMaskCreate(touch: TouchObject, point: BrushPoint): void {
    this.pendingMaskCreate = true;
    this.pendingTouchX = touch.x;
    this.pendingTouchY = touch.y;
    this.pendingSourceX = point.x;
    this.pendingSourceY = point.y;
  }

  private pendingDragExceeded(touch: TouchObject): boolean {
    return Math.hypot(touch.x - this.pendingTouchX, touch.y - this.pendingTouchY) >
      EditorCanvas.MASK_DRAG_THRESHOLD;
  }

  private handleRadialMaskTouch(event: TouchEvent): void {
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const changed = this.radialDragPart >= 0 || this.pendingMaskCreate;
      this.radialDragPart = -1;
      this.pendingMaskCreate = false;
      // 单击（没拖出距离）什么都没改，不必重算蒙版与预览。
      if (!changed) return;
      const layer = this.editSession.activeLayer;
      if (layer) this.editSession.invalidateLayerMaskCache(layer.id);
      this.editSession.notifyMaskRevision();
      this.scheduleReprocess();
      this.drawMaskOverlay();
      return;
    }
    const touch = event.touches[0];
    if (!touch) return;
    const point = this.touchToSourcePoint(touch);
    if (event.type === TouchType.Down) {
      const pressed = this.editSession.activeMaskComponent;
      if (!pressed || pressed.type !== MaskComponentType.RADIAL_GRADIENT) {
        // 没有可编辑的径向分量：只记住按下点，等真的拖动再创建。
        if (point) this.beginPendingMaskCreate(touch, point);
        return;
      }
      pressed.ensureData();
      const current = pressed.radialGradientData;
      if (!current) return;
      const center = new BrushPoint();
      center.x = current.centerX;
      center.y = current.centerY;
      const centerCanvas = this.sourcePointToCanvas(center);
      const rightHandle = this.radialCanvasPoint(current, current.radiusX, 0);
      const leftHandle = this.radialCanvasPoint(current, -current.radiusX, 0);
      const topHandle = this.radialCanvasPoint(current, 0, -current.radiusY);
      const bottomHandle = this.radialCanvasPoint(current, 0, current.radiusY);
      const rotationHandle = this.radialCanvasPoint(current, 0, -(current.radiusY + 0.08));

      const near = 26;
      if (Math.hypot(touch.x - centerCanvas[0], touch.y - centerCanvas[1]) < near) {
        this.editSession.pushUndo();
        this.radialDragPart = 0; // move the whole ellipse
      } else if (Math.hypot(touch.x - rightHandle[0], touch.y - rightHandle[1]) < near) {
        this.editSession.pushUndo();
        this.radialDragPart = 1; // right anchor → radiusX
      } else if (Math.hypot(touch.x - leftHandle[0], touch.y - leftHandle[1]) < near) {
        this.editSession.pushUndo();
        this.radialDragPart = 2; // left anchor → radiusX
      } else if (Math.hypot(touch.x - topHandle[0], touch.y - topHandle[1]) < near) {
        this.editSession.pushUndo();
        this.radialDragPart = 3; // top anchor → radiusY
      } else if (Math.hypot(touch.x - bottomHandle[0], touch.y - bottomHandle[1]) < near) {
        this.editSession.pushUndo();
        this.radialDragPart = 4; // bottom anchor → radiusY
      } else if (Math.hypot(touch.x - rotationHandle[0], touch.y - rotationHandle[1]) < near) {
        this.editSession.pushUndo();
        this.radialDragPart = 5; // outer handle → rotation
      } else if (point) {
        // 空白处按下：先不动作。原来这里立刻把椭圆挪到手指位置并缩成 0.03，
        // 于是"在蒙版界面点一下图片"看起来就像凭空画了个径向蒙版。
        this.beginPendingMaskCreate(touch, point);
      }
      this.drawMaskOverlay();
      return;
    }
    if (event.type === TouchType.Move && this.pendingMaskCreate &&
      this.pendingDragExceeded(touch)) {
      let target = this.editSession.activeMaskComponent;
      const editable = !!target && target.type === MaskComponentType.RADIAL_GRADIENT;
      this.editSession.pushUndo();
      if (!editable) {
        if (this.editSession.activeMaskLayer) {
          target = this.editSession.addMaskComponent(
            MaskComponentType.RADIAL_GRADIENT, MaskBlendMode.ADD);
        } else {
          const created = this.editSession.createMaskLayer(MaskComponentType.RADIAL_GRADIENT);
          target = created ? created.components[0] : null;
        }
      }
      if (!target) {
        this.pendingMaskCreate = false;
        return;
      }
      target.ensureData();
      const data = target.radialGradientData;
      if (!data) {
        this.pendingMaskCreate = false;
        return;
      }
      // 椭圆落在按下点，然后由右锚点跟着手指张开。
      data.centerX = this.pendingSourceX;
      data.centerY = this.pendingSourceY;
      data.radiusX = 0.03;
      data.radiusY = 0.03;
      this.pendingMaskCreate = false;
      this.radialDragPart = 1;
      this.scheduleMaskOverlay();
      return;
    }
    const dragTarget = this.editSession.activeMaskComponent;
    if (!dragTarget || dragTarget.type !== MaskComponentType.RADIAL_GRADIENT) return;
    dragTarget.ensureData();
    const data = dragTarget.radialGradientData;
    if (!data) return;
    if (event.type === TouchType.Move && this.radialDragPart >= 0) {
      if (this.radialDragPart === 0) {
        const moved = this.touchToSourcePoint(touch);
        if (moved) {
          data.centerX = moved.x;
          data.centerY = moved.y;
        }
      } else {
        // Radius and rotation are measured in SOURCE pixels, the frame
        // MaskRasterCore rasterizes the ellipse in. Measuring them on the
        // canvas made a drag on a rotated or flipped preview change the other
        // axis (or the opposite sign) and pinned the handles to the wrong
        // ellipse. touchToSourcePoint already inverts the full geometry pass.
        const moved = this.touchToSourcePoint(touch);
        if (moved) {
          const width = Math.max(1, this.editSession.imageWidth);
          const height = Math.max(1, this.editSession.imageHeight);
          const dx = (moved.x - data.centerX) * width;
          const dy = (moved.y - data.centerY) * height;
          const angle = data.rotation * Math.PI / 180;
          const cos = Math.cos(angle);
          const sin = Math.sin(angle);
          if (this.radialDragPart === 5) {
            data.rotation = ((Math.atan2(dy, dx) * 180 / Math.PI) + 90 + 360) % 360;
          } else {
            const localX = dx * cos + dy * sin;
            const localY = -dx * sin + dy * cos;
            if (this.radialDragPart === 1 || this.radialDragPart === 2) {
              data.radiusX = Math.max(0.02, Math.min(1.5, Math.abs(localX) / width));
            } else {
              data.radiusY = Math.max(0.02, Math.min(1.5, Math.abs(localY) / height));
            }
          }
        }
      }
    }
    if (event.type === TouchType.Move) this.scheduleMaskOverlay();
    else this.drawMaskOverlay();
  }

  /**
   * Draw the composed mask preview first, then draw controls for only the
   * selected component. The preview is intentionally a lightweight Canvas2D
   * representation during gestures; the authoritative alpha composition is
   * produced by MaskRenderer for the image pipeline.
   */
  private drawMaskOverlay(): void {
    if (this.brushSizing) {
      this.overlayCtx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
      console.info(`VIVID_PERF t=${Date.now()} event=overlay_draw branch=sizing ` +
        `canvas=${Math.round(this.canvasWidth)}x${Math.round(this.canvasHeight)} ` +
        `value=${AppStorage.get<number>('maskBrushAdjustValue') ?? -1}`);
      this.drawBrushSizePreview();
      return;
    }
    const startedAt = Date.now();
    const ctx = this.overlayCtx;
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    const maskLayer = this.editSession.activeMaskLayer;
    if (!maskLayer) return;
    this.drawComposedMaskCoverage();
    this.drawActiveMaskOverlay();
    // 涂抹时的卡顿必须在设备上量，而不是猜：叠加层每帧重算，这条日志给出
    // 真实耗时，用来判断瓶颈在蒙版栅格化还是在像素映射/位图上传。
    const elapsed = Date.now() - startedAt;
    if (elapsed >= 8) {
      console.info(`VIVID_PERF t=${Date.now()} event=mask_overlay ms=${elapsed} ` +
        `stroke=${this.currentStroke !== null} edge=${this.currentStroke ? 160 : 320} ` +
        `scale=${this.editSession.canvasScale.toFixed(2)}`);
    }
  }

  /** 按点是否落在工具列 / 盖章这些悬浮控件上。 */
  private touchHitsMaskUi(touch: TouchObject | null): boolean {
    if (touch === null) return false;
    const keys: string[] = ['maskUiRectBrush', 'maskUiRectCapsule'];
    for (const key of keys) {
      const raw = AppStorage.get<string>(key);
      if (raw === undefined || raw.length === 0) continue;
      const parts = raw.split(',');
      if (parts.length !== 4) continue;
      const rx = Number(parts[0]);
      const ry = Number(parts[1]);
      const rw = Number(parts[2]);
      const rh = Number(parts[3]);
      if (touch.x >= rx && touch.x <= rx + rw && touch.y >= ry && touch.y <= ry + rh) return true;
    }
    return false;
  }

  /** 该层所有画笔分量的笔画总数，用来决定覆盖层栅格化的分辨率档位。 */
  private maskStrokeCount(layer: MaskLayer): number {
    let total = 0;
    for (const part of layer.components as MaskComponent[]) {
      if (part.type === MaskComponentType.BRUSH && part.brushData !== null) {
        total += part.brushData.strokes.length;
      }
    }
    return total;
  }

  /**
   * 拖动大小 / 羽化滑杆时的屏幕提示：画面中心只显示对应数值。
   */
  private drawBrushSizePreview(): void {
    const ctx = this.overlayCtx;
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    const rect = this.getDisplayedImageRect(false);
    if (rect[2] <= 0 || rect[3] <= 0) return;
    const cx = rect[0] + rect[2] / 2;
    const cy = rect[1] + rect[3] / 2;
    // 示意圆：半径按画笔直径换算，外圈用径向渐变表示羽化，数值压在圆心上。
    const sizePct = Math.max(0, Math.min(100, this.previewSizeValue)) / 100;
    const diameter = Math.max(12, (0.005 + sizePct * sizePct * 0.3) * Math.min(rect[2], rect[3]) * 2);
    const radius = diameter / 2;
    // 羽化取当前蒙版组件的真实羽化（0..1）：圆的大小始终等于当前画笔直径，
    // 羽化只改变圆内由实到虚的过渡范围，而不是把整圆缩小。
    const featherPct = Math.max(0, Math.min(1, this.previewFeatherValue / 100));
    const hardRadius = Math.max(1, radius * (1 - featherPct));
    const gradient = ctx.createRadialGradient(cx, cy, hardRadius * 0.2, cx, cy, radius);
    gradient.addColorStop(0, 'rgba(255,0,0,0.55)');
    gradient.addColorStop(Math.min(0.999, hardRadius / Math.max(1, radius)), 'rgba(255,0,0,0.45)');
    gradient.addColorStop(1, 'rgba(255,0,0,0.06)');
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.fillStyle = gradient;
    ctx.fill();
    const text = `${Math.round(this.brushAdjustValue)}`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = '600 64px sans-serif';
    ctx.fillStyle = 'rgba(0,0,0,0.35)';
    ctx.fillText(text, cx + 2, cy + 2);
    ctx.fillStyle = '#FFFFFF';
    ctx.fillText(text, cx, cy);
  }

  private drawComposedMaskCoverage(): void {
    if (!this.showMaskCoverage) return;
    // 调色过程中藏起来：蒙版仍然生效，只是不画这层红色覆盖。
    if (this.overlayHiddenBySlider) return;
    // 预览尺寸还没就绪时矩形是错的，画出去会落在图片外面。
    if (this.editSession.previewWidth <= 0 || this.editSession.previewHeight <= 0) return;
    const phaseStart = Date.now();
    const layer = this.editSession.activeMaskLayer;
    // 落笔过程中不再整层重算：把上一次（抬笔后）合成好的覆盖层位图直接贴回去，
    // 当前这一笔由 drawActiveMaskOverlay() 实时画。整层重算一笔要 200ms，手指
    // 连续划动时这些重算会把 UI 线程堵到系统判定 ANR。
    if (this.currentStroke !== null && this.cachedOverlayBitmap !== null &&
      this.cachedOverlayWidth === 160) {
      const cachedRect = this.getDisplayedImageRect(false);
      this.overlayCtx.drawImage(this.cachedOverlayBitmap, cachedRect[0], cachedRect[1],
        cachedRect[2], cachedRect[3]);
      return;
    }
    if (!layer || !layer.enabled || !layer.visible) return;
    // 抬笔静默期：这几次重绘的成本（整层栅格化）只为把所有笔迹重新合成一遍，
    // 而画布上显示的内容已经正确，延后到静止后再算。
    if (!this.currentStroke && this.strokeSettleUntil > 0 && Date.now() < this.strokeSettleUntil) return;
    const sourceW = this.editSession.imageWidth;
    const sourceH = this.editSession.imageHeight;
    if (sourceW <= 0 || sourceH <= 0) return;
    // A small alpha-only buffer keeps touch feedback independent of the
    // high-resolution colour pipeline. Composition uses the same renderer.
    // While a brush stroke is active, keep the feedback buffer small enough
    // that a long stroke never blocks touch dispatch. On release the cache is
    // rebuilt at the normal 320px edge for a crisp mask preview.
    // 笔数越多，整层栅格化越贵（50 笔时单帧已到 260ms）。覆盖层只是红色提示，
    // 笔数多时降一档分辨率，单帧回到几十毫秒，不影响最终蒙版与导出。
    const strokeCount = this.maskStrokeCount(layer);
    const previewEdge = this.currentStroke ? 96 : (strokeCount > 24 ? 64 : 128);
    const scale = Math.min(1, previewEdge / Math.max(sourceW, sourceH));
    const width = Math.max(1, Math.round(sourceW * scale));
    const height = Math.max(1, Math.round(sourceH * scale));
    let alpha: Uint8ClampedArray;
    const canReuseCommitted = this.currentStroke !== null &&
      this.committedMaskAlpha !== null &&
      this.committedMaskWidth === width &&
      this.committedMaskHeight === height &&
      this.committedMaskLayerId === layer.id &&
      this.committedMaskUpdatedAt === layer.updatedAt;
    const alphaKey = layer.id + ':' + this.editSession.maskRevision + ':' + width + 'x' + height;
    if (this.overlayAlphaBuffer !== null && this.overlayAlphaKey === alphaKey) {
      // 同一版蒙版、同一尺寸的重绘直接复用上一份 alpha。笔数多了以后整层栅格化
      // 一次就要几百毫秒（debug 包更慢），重复算几遍就会把主线程堵到系统判 ANR。
      alpha = this.overlayAlphaBuffer;
    } else if (canReuseCommitted && this.committedMaskAlpha) {
      alpha = this.committedMaskAlpha;
    } else {
      // 走带自动蒙版代理注入的渲染：直接调 MaskRenderer 会把 sourceProxy 置
      // null，开启自动蒙版时画布叠加层会显示成"没有门限"的原始笔迹——看起来
      // 就是开关毫无效果。代理未就绪时退回无门限版本，且不当成已提交缓存。
      const auto = ImageProcessor.renderMaskLayerSync(this.editSession, layer, width, height);
      const gated = auto !== null;
      alpha = gated ? auto : MaskRenderer.renderMaskLayer(layer, width, height);
      if (this.currentStroke) {
        // 门限是否真的在生产路径上生效，只有设备日志能证明：这里报出栅格
        // 尺寸、门限开关与覆盖率，覆盖率≈100% 就等于"没生效"。
        // 两个渲染入口返回的都是每像素 1 字节的覆盖率缓冲。
        let covered = 0;
        for (let index = 0; index < alpha.length; index++) {
          if (alpha[index] > 0) covered++;
        }
        const ratio = Math.round(covered * 100 / Math.max(1, alpha.length));
        console.info(`VIVID_PERF t=${Date.now()} event=mask_gate gated=${gated} ` +
          `auto=${ImageProcessor.layerNeedsAutoMaskProxy(layer)} raster=${width}x${height} ` +
          `cover=${ratio}% sensitivity=${this.editSession.brushAutoMaskSensitivity.toFixed(2)}`);
      }
      this.overlayAlphaKey = alphaKey;
      this.overlayAlphaBuffer = alpha;
      if (!this.currentStroke && gated) {
        this.committedMaskAlpha = alpha;
        this.committedMaskWidth = width;
        this.committedMaskHeight = height;
        this.committedMaskLayerId = layer.id;
        this.committedMaskUpdatedAt = layer.updatedAt;
      }
    }
    const rect = this.getDisplayedImageRect(false);
    // 坐标系诊断：覆盖层矩形 vs 画布尺寸 vs 预览图尺寸，用来核对与照片的实际贴合。
    console.info(`VIVID_PERF t=${Date.now()} event=mask_overlay_rect ` +
      `canvas=${Math.round(this.canvasWidth)}x${Math.round(this.canvasHeight)} ` +
      `rect=${Math.round(rect[0])},${Math.round(rect[1])},${Math.round(rect[2])},${Math.round(rect[3])} ` +
      `preview=${this.editSession.previewWidth}x${this.editSession.previewHeight} ` +
      `image=${this.editSession.imageWidth}x${this.editSession.imageHeight} ` +
      `scale=${this.editSession.canvasScale.toFixed(3)} window=${this.windowWidth}` +
      ` raster=${this.activeRasterMask() ? 1 : 0}`);
    // 画面里有位图型蒙版（主体/天空/范围）时用更高的显示分辨率：边界就是逐像素
  // 采样出来的，160 边会让 AI 蒙版的轮廓整体看起来偏一两个像素。
  const displayEdge = this.activeRasterMask() ? 240 : 160;
    const displayScale = Math.min(1, displayEdge / Math.max(rect[2], rect[3]));
    const displayW = Math.max(1, Math.round(rect[2] * displayScale));
    const displayH = Math.max(1, Math.round(rect[3] * displayScale));
    const pixels = new Uint8ClampedArray(displayW * displayH * 4);
    // The coverage overlay shares the editor geometry map with the renderer and
    // with touch input. Hard-coded rotation math silently ignored straighten,
    // perspective and auto-crop, so the red coverage drifted off the pixels it
    // described. The alpha buffer is sampled bilinearly because the projective
    // pass is not an integer remap.
    const map = this.editSession.geometryMap(width, height);
    // 采样映射只跟几何（rect/缩放/平移/裁剪）有关，跟蒙版内容无关：缓存成
    // 两个 Float32Array，重绘时只做查表。之前每帧 38k 次 displayToSource 会
    // 分配 38k 个临时数组，光这一趟就 45ms（日志 map=43~52ms），画笔自然卡。
    const mapKey = `${displayW}x${displayH}|${width}x${height}|` +
      `${rect[0].toFixed(1)},${rect[1].toFixed(1)},${rect[2].toFixed(1)},${rect[3].toFixed(1)}|` +
      `${this.editSession.canvasScale.toFixed(3)}|${this.editSession.previewWidth}x${this.editSession.previewHeight}`;
    if (this.sourceMapKey !== mapKey || this.sourceMapX === null || this.sourceMapY === null ||
      this.sourceMapX.length !== displayW * displayH) {
      const count = displayW * displayH;
      const mapX = new Float32Array(count);
      const mapY = new Float32Array(count);
      for (let y = 0; y < displayH; y++) {
        for (let x = 0; x < displayW; x++) {
          const index = y * displayW + x;
          const source = displayToSource(map, (x + 0.5) / displayW, (y + 0.5) / displayH);
          if (source && source[0] >= 0 && source[1] >= 0 &&
            source[0] < width && source[1] < height) {
            mapX[index] = source[0];
            mapY[index] = source[1];
          } else {
            mapX[index] = -1;
            mapY[index] = -1;
          }
        }
      }
      this.sourceMapX = mapX;
      this.sourceMapY = mapY;
      this.sourceMapKey = mapKey;
    }

    const rasterDone = Date.now();
    for (let y = 0; y < displayH; y++) {
      for (let x = 0; x < displayW; x++) {
        const sampleIndex = y * displayW + x;
        const index = sampleIndex * 4;
        pixels[index] = 255;
        pixels[index + 1] = 32;
        pixels[index + 2] = 32;
        const sx = this.sourceMapX[sampleIndex];
        if (sx < 0) continue;
        const sy = this.sourceMapY[sampleIndex];
        // 采样坐标是像素空间的浮点值：最后一列会落在 width-1 与 width 之间
        // （例如 width=85 时的 84.7），它仍属于图像内部。以前用 > width-1 判断
        // 越界会把这一列整条丢掉，覆盖层右边缘就缺一条；放大时缺口随之变大。
        if (sx < 0 || sy < 0 || sx >= width || sy >= height) continue;
        const ix = Math.min(width - 1, Math.floor(sx));
        const iy = Math.min(height - 1, Math.floor(sy));
        const fx = sx - ix;
        const fy = sy - iy;
        const x1 = Math.min(width - 1, ix + 1);
        const y1 = Math.min(height - 1, iy + 1);
        const top = alpha[iy * width + ix] * (1 - fx) + alpha[iy * width + x1] * fx;
        const bottom = alpha[y1 * width + ix] * (1 - fx) + alpha[y1 * width + x1] * fx;
        pixels[index + 3] = Math.round((top * (1 - fy) + bottom * fy) * 0.42);
      }
    }
    {
      const probeRow = Math.floor(displayH / 8);
      const probe = [displayW - 1, displayW - 2, displayW - 3, displayW - 4].map((col: number) =>
        pixels[(probeRow * displayW + col) * 4 + 3]);
      const probeLeft = [0, 1, 2, 3].map((col: number) =>
        pixels[(probeRow * displayW + col) * 4 + 3]);
      console.info(`VIVID_PERF t=${Date.now()} event=mask_overlay_edge display=${displayW}x${displayH} ` +
        `row=${probeRow} left=${probeLeft.join(',')} right=${probe.join(',')} alpha=${width}x${height}`);
    }
    const mapDone = Date.now();

    if (!this.maskSurfaceCanvas || !this.maskSurface ||
      this.maskSurfaceWidth !== displayW || this.maskSurfaceHeight !== displayH) {
      try {
        const surfaceCanvas = new OffscreenCanvas(displayW, displayH, LengthMetricsUnit.PX);
        const surface = surfaceCanvas.getContext('2d', this.overlaySettings);
        this.maskSurfaceCanvas = surfaceCanvas;
        this.maskSurface = surface;
        this.maskSurfaceWidth = displayW;
        this.maskSurfaceHeight = displayH;
      } catch (error) {
        // Older preview runtimes may not expose an off-screen 2D surface.
        // Keep editing usable instead of letting a preview-only allocation
        // terminate the editor process.
        console.error('Mask overlay surface creation failed: ' + error);
        this.maskSurfaceCanvas = null;
        this.maskSurface = null;
        return;
      }
    }
    this.maskSurface.putImageData(new ImageData(displayW, displayH, pixels, LengthMetricsUnit.PX), 0, 0);
    const bitmap = this.maskSurfaceCanvas.transferToImageBitmap();
    this.overlayCtx.drawImage(bitmap, rect[0], rect[1], rect[2], rect[3]);
    // 留一份已提交覆盖层，供落笔期间直接复用（避免每帧整层栅格化）。
    if (this.cachedOverlayBitmap !== null) this.cachedOverlayBitmap.close();
    this.cachedOverlayBitmap = null;
    if (!this.currentStroke) {
      const cacheSurface = new OffscreenCanvas(displayW, displayH, LengthMetricsUnit.PX);
      const cacheContext = cacheSurface.getContext('2d', this.overlaySettings);
      if (cacheContext !== null) {
        cacheContext.putImageData(new ImageData(displayW, displayH, pixels, LengthMetricsUnit.PX), 0, 0);
        this.cachedOverlayBitmap = cacheSurface.transferToImageBitmap();
        this.cachedOverlayWidth = 160;
      }
    }
    bitmap.close();
    // 阶段拆分：栅格化 / 几何映射 / 位图上传。217ms 的叠加层耗时必须落到具体
    // 阶段，否则只能靠猜着优化（上一轮就是这么浪费掉的）。
    const total = Date.now() - phaseStart;
    if (total >= 8) {
      console.info(`VIVID_PERF t=${Date.now()} event=mask_overlay_parts total=${total} ` +
        `raster=${rasterDone - phaseStart} map=${mapDone - rasterDone} ` +
        `upload=${Date.now() - mapDone} alpha=${width}x${height} display=${displayW}x${displayH}`);
    }
  }

  private drawActiveMaskOverlay(): void {
    const ctx = this.overlayCtx;
    const component = this.editSession.activeMaskComponent;
    if (!component) return;
    component.ensureData();
    if (component.type === MaskComponentType.BRUSH && component.brushData) {
      if (this.currentStroke) this.drawCurrentBrushStrokePreview(ctx);
      // Only the cursor is drawn here. Painting the stroke again would
      // hide subtraction and accumulate alpha into a string of dark circles.
      if (this.brushCursor) {
        const point = this.sourcePointToCanvas(this.brushCursor);
        const origin = new BrushPoint();
        const axis = new BrushPoint(); axis.x = 1;
        const start = this.sourcePointToCanvas(origin);
        const end = this.sourcePointToCanvas(axis);
        const sourceScale = Math.hypot(end[0] - start[0], end[1] - start[1]) /
          Math.max(1, this.editSession.imageWidth);
        const radius = Math.max(1, this.brushCursor.radius *
          Math.min(this.editSession.imageWidth, this.editSession.imageHeight) * sourceScale);
        ctx.strokeStyle = '#FFFFFF';
        ctx.lineWidth = 1;
        ctx.beginPath(); ctx.arc(point[0], point[1], radius, 0, Math.PI * 2); ctx.stroke();
      }
    } else if (component.type === MaskComponentType.LINEAR_GRADIENT && component.linearGradientData) {
      const params = new LinearGradientParams();
      params.startX = component.linearGradientData.startX;
      params.startY = component.linearGradientData.startY;
      params.endX = component.linearGradientData.endX;
      params.endY = component.linearGradientData.endY;
      params.feather = Math.max(0, Math.min(1, component.feather));
      this.drawLinearMaskControls(ctx, params);
    } else if (component.type === MaskComponentType.RADIAL_GRADIENT && component.radialGradientData) {
      const data = component.radialGradientData;
      const center = new BrushPoint(); center.x = data.centerX; center.y = data.centerY;
      const centerCanvas = this.sourcePointToCanvas(center);
      // Trace the ellipse in the mask's own source-pixel frame and map every
      // perimeter point through the editor geometry. That reproduces what
      // MaskRasterCore rasterizes for any display transform; a canvas ellipse
      // built from the display scale (the previous version) ignored quarter
      // turns, flips, straighten and perspective, so the outline described a
      // different region than the mask actually affected.
      const width = Math.max(1, this.editSession.imageWidth);
      const height = Math.max(1, this.editSession.imageHeight);
      const rx = Math.max(1, data.radiusX * width);
      const ry = Math.max(1, data.radiusY * height);
      const angle = data.rotation * Math.PI / 180;
      const cos = Math.cos(angle);
      const sin = Math.sin(angle);
      const point = new BrushPoint();
      const steps = 64;
      ctx.strokeStyle = '#EF3333'; ctx.lineWidth = 2;
      let drawing = false;
      for (let step = 0; step <= steps; step++) {
        const t = step * Math.PI * 2 / steps;
        const localX = rx * Math.cos(t);
        const localY = ry * Math.sin(t);
        point.x = data.centerX + (localX * cos - localY * sin) / width;
        point.y = data.centerY + (localX * sin + localY * cos) / height;
        const canvas = this.sourceToCanvasOrNull(point);
        if (!canvas) {
          if (drawing) { ctx.stroke(); drawing = false; }
          continue;
        }
        if (!drawing) { ctx.beginPath(); ctx.moveTo(canvas[0], canvas[1]); drawing = true; }
        else ctx.lineTo(canvas[0], canvas[1]);
      }
      if (drawing) { ctx.closePath(); ctx.stroke(); }
      // Four axis anchors turn the circle into a draggable ellipse.
      ctx.fillStyle = '#EF3333';
      const anchors: number[][] = [
        this.radialCanvasPoint(data, data.radiusX, 0),
        this.radialCanvasPoint(data, -data.radiusX, 0),
        this.radialCanvasPoint(data, 0, -data.radiusY),
        this.radialCanvasPoint(data, 0, data.radiusY),
      ];
      for (let index = 0; index < anchors.length; index++) {
        ctx.beginPath(); ctx.arc(anchors[index][0], anchors[index][1], 6, 0, Math.PI * 2); ctx.fill();
      }
      const rotationHandle = this.radialCanvasPoint(data, 0, -(data.radiusY + 0.08));
      ctx.strokeStyle = '#EF3333'; ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.moveTo(anchors[2][0], anchors[2][1]); ctx.lineTo(rotationHandle[0], rotationHandle[1]); ctx.stroke();
      ctx.beginPath(); ctx.arc(rotationHandle[0], rotationHandle[1], 6, 0, Math.PI * 2); ctx.fill();
      ctx.beginPath(); ctx.arc(centerCanvas[0], centerCanvas[1], 5, 0, Math.PI * 2); ctx.fill();
    }
  }

  /** Draw only the in-progress brush path on top of the committed mask. */
  private drawCurrentBrushStrokePreview(ctx: CanvasRenderingContext2D): void {
    const stroke = this.currentStroke;
    if (!stroke || stroke.points.length === 0) return;
    const rect = this.getDisplayedImageRect(false);
    const imageW = Math.max(1, this.editSession.imageWidth);
    const imageH = Math.max(1, this.editSession.imageHeight);
    const pxScale = Math.min(rect[2] / imageW, rect[3] / imageH);
    const last = stroke.points[stroke.points.length - 1];
    const width = Math.max(1, last.radius * Math.min(imageW, imageH) * pxScale * 2);
    ctx.save();
    ctx.globalAlpha = 0.36;
    ctx.strokeStyle = stroke.mode === 1 ? '#6D7890' : '#EF3333';
    ctx.fillStyle = stroke.mode === 1 ? '#6D7890' : '#EF3333';
    ctx.lineWidth = width;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.beginPath();
    for (let index = 0; index < stroke.points.length; index++) {
      const point = this.sourcePointToCanvas(stroke.points[index]);
      if (index === 0) ctx.moveTo(point[0], point[1]);
      else ctx.lineTo(point[0], point[1]);
    }
    if (stroke.points.length === 1) {
      const point = this.sourcePointToCanvas(stroke.points[0]);
      ctx.arc(point[0], point[1], width / 2, 0, Math.PI * 2);
      ctx.fill();
    } else {
      ctx.stroke();
    }
    ctx.restore();
  }

  /** Canvas point of one point of the radial mask's own frame. `localX`/`localY`
   * are in the mask's normalized radius units (radiusX/radiusY), rotated in
   * SOURCE PIXELS because that is exactly how MaskRasterCore rasterizes the
   * ellipse (rx = radiusX*width, ry = radiusY*height, angle in pixel space).
   * The resulting source point is then mapped through the editor geometry, so
   * the handles stay on the pixels the renderer will affect after a quarter
   * turn, flip, straighten, perspective correction or auto-crop. Drawing them
   * from the display scale alone put every handle (and its hit test) at the
   * unrotated position. */
  private radialCanvasPoint(data: RadialGradientData, localX: number, localY: number): number[] {
    const width = Math.max(1, this.editSession.imageWidth);
    const height = Math.max(1, this.editSession.imageHeight);
    const angle = data.rotation * Math.PI / 180;
    const cos = Math.cos(angle);
    const sin = Math.sin(angle);
    const px = localX * width;
    const py = localY * height;
    const source = new BrushPoint();
    source.x = data.centerX + (px * cos - py * sin) / width;
    source.y = data.centerY + (px * sin + py * cos) / height;
    return this.sourcePointToCanvas(source);
  }

  /** Source-normalized point → canvas point, or null when the geometry puts it
   * outside the published frame (used to break overlay outlines instead of
   * folding them onto a corner). */
  private sourceToCanvasOrNull(source: BrushPoint): number[] | null {
    const rect = this.getDisplayedImageRect(false);
    const display = this.editSession.sourcePointToDisplay(source.x, source.y);
    if (!display) return null;
    return [rect[0] + display[0] * rect[2], rect[1] + display[1] * rect[3]];
  }

  private drawLinearMaskControls(
    ctx: CanvasRenderingContext2D,
    params: LinearGradientParams,
  ): void {
    const start = new BrushPoint(); start.x = params.startX; start.y = params.startY;
    const end = new BrushPoint(); end.x = params.endX; end.y = params.endY;
    const startCanvas = this.sourcePointToCanvas(start);
    const endCanvas = this.sourcePointToCanvas(end);
    // The old implementation drew a solid line directly between the two
    // anchors. That line was mistaken for the transition boundary and made
    // the gradient look like a hard cut. The transition is represented by the
    // composed coverage overlay; keep only the draggable anchor handles here.
    ctx.fillStyle = '#EF3333';
    ctx.beginPath(); ctx.arc(startCanvas[0], startCanvas[1], 8, 0, Math.PI * 2); ctx.fill();
    ctx.beginPath(); ctx.arc(endCanvas[0], endCanvas[1], 8, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#FFFFFF';
    ctx.beginPath(); ctx.arc(startCanvas[0], startCanvas[1], 3, 0, Math.PI * 2); ctx.fill();
    ctx.beginPath(); ctx.arc(endCanvas[0], endCanvas[1], 3, 0, Math.PI * 2); ctx.fill();
  }

  /**
   * Upright reference line: one drag marks one line on the image.
   *
   * Captured in normalized SOURCE coordinates through the same `touchToSourcePoint`
   * the retouch tools use, so a guide means the same thing at any preview
   * resolution. Drawing goes back through `sourcePointToDisplay`, which means a
   * guide STICKS TO THE IMAGE CONTENT: once the solve straightens the line it
   * marks, the overlay line visibly lines up with the frame axis, and a guide
   * drawn afterwards on the already-corrected view maps back to the right source
   * pixels. The two directions are exact inverses, so this is self-consistent
   * rather than approximate.
   *
   * The stroke is tested for acceptability BEFORE anything is mutated: pushing
   * undo after the mutation would snapshot the changed state and make the rejected
   * tap un-undoable.
   */
  private handleUprightTouch(event: TouchEvent): void {
    const touch = event.touches[0] ?? event.changedTouches[0];
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const start = this.uprightStart;
      const end = this.uprightCurrent;
      this.uprightStart = null;
      this.uprightCurrent = null;
      if (event.type === TouchType.Up && start && end &&
        UprightSettings.acceptsGuide(start.x, start.y, end.x, end.y)) {
        this.editSession.pushUndo();
        this.editSession.upright.addGuide(start.x, start.y, end.x, end.y);
        this.editSession.solveUprightGuides();
        this.editSession.bumpProcessing();
        // The panel shows the solved coefficients and the residual, so it has to
        // hear about a solve that happened on the canvas.
        AppStorage.setOrCreate('uprightRevision', Date.now());
        ImageProcessor.process(this.editSession);
      }
      this.redrawOverlay();
      return;
    }
    if (!touch) return;
    const point = this.touchToSourcePoint(touch);
    if (!point) return;
    if (event.type === TouchType.Down) {
      this.uprightStart = point;
      this.uprightCurrent = point;
      this.redrawOverlay();
      return;
    }
    if (!this.uprightStart) return;
    this.uprightCurrent = point;
    this.redrawOverlay();
  }

  /**
   * Draw the committed guides plus the line being dragged.
   *
   * The two axes are coloured differently because they constrain different things:
   * a vertical guide fixes the vertical perspective, while a horizontal one fixes
   * the horizontal perspective AND supplies the straighten angle.
   */
  private drawUprightOverlay(): void {
    const ctx = this.overlayCtx;
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    const guides = this.editSession.upright.guides;
    for (let index = 0; index < guides.length; index++) {
      this.strokeUprightGuide(guides[index].x1, guides[index].y1,
        guides[index].x2, guides[index].y2, guides[index].vertical, false);
    }
    const start = this.uprightStart;
    const end = this.uprightCurrent;
    if (start && end) {
      this.strokeUprightGuide(start.x, start.y, end.x, end.y,
        Math.abs(end.y - start.y) > Math.abs(end.x - start.x), true);
    }
  }

  private strokeUprightGuide(x1: number, y1: number, x2: number, y2: number,
    vertical: boolean, live: boolean): void {
    const from = new BrushPoint(); from.x = x1; from.y = y1;
    const to = new BrushPoint(); to.x = x2; to.y = y2;
    const canvasFrom = this.sourceToCanvasOrNull(from);
    const canvasTo = this.sourceToCanvasOrNull(to);
    // A guide whose endpoint the auto-crop pushed out of frame is skipped rather
    // than folded onto a corner, matching how the mask outlines behave.
    if (!canvasFrom || !canvasTo) return;
    const ctx = this.overlayCtx;
    ctx.strokeStyle = live ? 'rgba(255,214,102,0.95)' : (vertical ? '#5FD3FF' : '#FF9F5F');
    ctx.lineWidth = live ? 4 : 3;
    ctx.setLineDash(live ? [10, 6] : []);
    ctx.beginPath();
    ctx.moveTo(canvasFrom[0], canvasFrom[1]);
    ctx.lineTo(canvasTo[0], canvasTo[1]);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = ctx.strokeStyle;
    const handles: number[][] = [canvasFrom, canvasTo];
    for (let index = 0; index < handles.length; index++) {
      ctx.beginPath();
      ctx.arc(handles[index][0], handles[index][1], 6, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  /**
   * 预览节点的**布局位置**（画布局部 vp）与基础尺寸。
   *
   * 这里刻意不再用 `translate` 表达平移：`translate` 与 `scale` 的先后顺序在
   * 不同实现对"平移量是否也被缩放"的解释并不一致，一旦被缩放，画面上图会出现在
   * `center + offset*scale`，而触摸映射用的是 `center + offset`，误差随缩放与
   * 平移量一起放大——正是"放大后笔迹位置偏了"的表现。
   *
   * 改成把节点**摆**到目标位置（position 是布局，含义无歧义），再围绕自身中心
   * `scale`。这样缩放后的可视矩形恒等于 getDisplayedImageRect 的公式值，触摸
   * 映射与画面在任何缩放/平移下都严格一致，不依赖对变换顺序的假设。
   *
   * `fixedBox` 对应那些用百分比尺寸（'98%'/'85%' + objectFit Contain）的预览
   * 节点；XComponent 用按比例算出的基础尺寸。
   */
  /**
   * 预览图节点的绝对矩形。
   *
   * 以前图片节点用"父容器的 85% + Contain"来布局，而覆盖层和触摸用的是
   * `getDisplayedImageRect()`（按 Canvas 尺寸算）。两者父容器不同（卡片内边距），
   * 于是蒙版整体左移、右侧还差一条，画笔在右边缘也画不到。现在图片节点的尺寸/
   * 位置都从同一个 rect 反推，叠加层与图片在构造上就是同一套坐标。
   *
   * rect 已经含 canvasScale；节点自身再按 canvasScale 缩放（以自身中心为原点），
   * 所以这里先除掉缩放，并把位置对齐到 rect 中心。
   */
  private previewDrawRect(): number[] {
    const rect = this.getDisplayedImageRect(false);
    const scale = Math.max(0.001, this.editSession.canvasScale);
    const boxWidth = rect[2] / scale;
    const boxHeight = rect[3] / scale;
    return [rect[0] + (rect[2] - boxWidth) / 2, rect[1] + (rect[3] - boxHeight) / 2,
      boxWidth, boxHeight];
  }

  private previewNodePlacement(fixedBox: boolean): number[] {
    const rect = this.getDisplayedImageRect(false);
    const scale = Math.max(0.001, this.editSession.canvasScale);
    const canvasW = this.canvasWidth, canvasH = this.canvasHeight;
    let baseW: number;
    let baseH: number;
    if (fixedBox) {
      const factor = this.windowWidth >= 840 ? 0.98 : 0.85;
      baseW = canvasW * factor;
      baseH = canvasH * factor;
    } else {
      baseW = rect[2] / scale;
      baseH = rect[3] / scale;
    }
    return [
      (canvasW - baseW) / 2 + this.editSession.canvasOffsetX,
      (canvasH - baseH) / 2 + this.editSession.canvasOffsetY,
      baseW,
      baseH,
    ];
  }

  private redrawOverlay(): void {
    if (this.brushSizing) {
      this.drawBrushSizePreview();
      return;
    }
    // 签名没变就不重画。毛笔/橡皮擦切换、滑杆开关这类操作会把几个 @Watch
    // 同时叫醒，而单次重绘在笔数多时要几十毫秒，重复几次就是“卡一下”。
    if (this.currentStroke === null) {
      const signature = this.overlaySignature();
      if (signature === this.lastOverlaySignature &&
        this.editSession.activeTool !== ToolType.UPRIGHT && !this.editSession.isCropping) {
        return;
      }
      this.lastOverlaySignature = signature;
    }
    // Upright guide drawing can now happen inside the crop page. While the
    // UPRIGHT tool is active the guides are the interactive overlay, so they
    // must win over the crop frame; switching back to CROP restores the frame.
    if (this.editSession.activeTool === ToolType.UPRIGHT) this.drawUprightOverlay();
    else if (this.editSession.isCropping) this.drawCropOverlay();
    else if (this.showsMaskOverlay()) this.drawMaskOverlay();
    else this.overlayCtx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
  }

  /** 叠加层真正依赖的状态快照，用来避免重复重画。 */
  private overlaySignature(): string {
    return this.editSession.maskRevision + '|' + this.editSession.selectedMaskComponentId + '|' +
      this.editSession.maskBrushMode + '|' + this.editSession.activeTool + '|' +
      (this.showMaskCoverage ? 1 : 0) + '|' + (this.overlayHiddenBySlider ? 1 : 0) + '|' +
      // 画布尺寸必须进签名：弹出选择器卡片后预览区会变矮，尺寸变化触发的
      // onAreaChange 若被签名挡掉，覆盖层就会沿用旧矩形（比图片大、整体下移）。
      Math.round(this.canvasWidth) + 'x' + Math.round(this.canvasHeight) + '|' +
      this.editSession.canvasScale.toFixed(3) + '|' +
      Math.round(this.editSession.canvasOffsetX) + '|' + Math.round(this.editSession.canvasOffsetY) + '|' +
      this.detailVersion;
  }

  private scheduleReprocess(): void {
    if (this.reprocessTimer !== -1) clearTimeout(this.reprocessTimer);
    this.reprocessTimer = setTimeout(() => {
      this.editSession.bumpProcessing();
      ImageProcessor.process(this.editSession);
    }, 900);
  }
}


