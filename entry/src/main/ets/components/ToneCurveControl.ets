import { EditSession } from '../edit/models/EditSession';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { ColorAdjustments, CurveAnchor } from '../edit/models/Adjustment';
import {
  CurveAnchorLike, CurveDragAxis, CurveMoveResult, addCurveAnchor, curveHitTest, isCurveEndpoint, moveCurveAnchor, removeCurveAnchor,
} from '../edit/engine/ToneCurveCore';
import { VividMaterial } from './VividMaterial';
import { VividNative } from './VividNativeTheme';

@Component
export struct ToneCurveControl {
  @Consume('editSession') editSession: EditSession;
  @Prop maskContext: boolean = false;
  @Prop embedded: boolean = false;
  // Bumped via AppStorage when the panel-level reset restores all adjustments;
  // the curve canvas is imperative and will not repaint on its own. A plain
  // @Prop chain through AdjustmentPanel proved unreliable, so this listens on
  // the shared storage bus directly.
  @StorageLink('adjustmentResetRevision') @Watch('onResetRevision') resetRevisionBus: number = 0;
  @State private selectedChannel: number = 0;
  @State private selectedPoint: number = -1;
  @State private curveRevision: number = 0;
  @State private graphWidth: number = 260;
  @State private graphHeight: number = 150;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private processTimer: number = -1;
  private processPending: boolean = false;
  private draggingPoint: number = -1;
  // One undo entry per gesture, pushed by the first move that actually moves an
  // anchor. A press that only selects -- or that lands on an endpoint and never
  // moves -- must not leave a no-op entry on the stack.
  private gestureUndoPushed: boolean = false;
  // Edge an endpoint follows for the whole gesture: BOTH until the first real
  // move decides it, then locked so the drag cannot switch edges mid-way.
  private gestureAxis: CurveDragAxis = CurveDragAxis.BOTH;
  private pointerStartX: number = 0;
  private pointerStartY: number = 0;
  private anchorStartX: number = 0;
  private anchorStartY: number = 0;
  private gestureTarget: ColorAdjustments | null = null;
  private gestureChannel: number = 0;
  @State private showCurvePointMenu: boolean = false;
  @State private contextPoint: number = -1;
  @State private menuOffsetX: number = 0;
  @State private menuOffsetY: number = 0;
  private menuTarget: ColorAdjustments | null = null;
  private menuChannel: number = 0;
  private menuCurveSignature: string = '';
  private leftMouseDown: boolean = false;

  @Prop externalScroll: boolean = false;

  build() {
    if (this.externalScroll) {
      Column() {
        this.CurveBody();
      }
      .width('100%')
      .attributeModifier(VividMaterial.card);
    } else {
      Scroll() {
        this.CurveBody();
      }
      .width('100%')
      .height(this.embedded ? 286 : '100%')
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .borderRadius(VividNative.radiusPanel)
      .attributeModifier(VividMaterial.card);
    }
  }

  @Builder
  private CurvePointMenu() {
    Menu() {
      MenuItem({ content: this.canDeleteContextPoint() ? '删除锚点' :
        this.contextPoint >= 0 ? '两端锚点不能删除' : '无可删除的锚点' })
        .id('curve-point-delete')
        .contentFontColor(VividNative.textPrimary)
        .enabled(this.canDeleteContextPoint())
        .onClick(() => { this.deleteContextPoint(); });
    }
  }

  @Builder
  private CurveBody() {
    Column() {
      Row() {
        Text('曲线')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(VividNative.textPrimary);
        Blank();
        Text('点击添加 · 拖动调整')
          .fontSize(9)
          .fontColor(VividNative.textSecondary);
      }
      .width('calc(100% - 28vp)')
      .margin({ bottom: 6 });

      Row() {
        // 通道圆点保持各自通道色（R/G/B/合成是调色语义），只有选中描边用系统主题色。
        this.ChannelIcon(0, '#FFFFFF');
        this.ChannelIcon(1, '#E64B5F');
        this.ChannelIcon(2, '#36A56B');
        this.ChannelIcon(3, '#4E79E8');
        Blank();
      }
      .width('calc(100% - 28vp)')
      .margin({ bottom: 8 });

      Canvas(this.context)
        .id('tone-curve-graph')
        .width('calc(100% - 28vp)')
        .height(150)
        .borderRadius(VividNative.radiusClicked)
        .backgroundColor('#8A94A6')
        .onReady(() => { this.drawCurve(); })
        .onAreaChange((_: Area, area: Area) => {
          this.graphWidth = area.width as number;
          this.graphHeight = area.height as number;
          this.drawCurve();
        })
        .onTouch((event: TouchEvent) => { this.handleCurveTouch(event); })
        .onMouse((event: MouseEvent) => { this.handleCurveMouse(event); })
        .bindContextMenu(this.CurvePointMenu, ResponseType.RightClick, {
          onAppear: () => { this.showCurvePointMenu = true; },
          onDisappear: () => { this.showCurvePointMenu = false; this.menuTarget = null; },
        });

      Text(this.selectedPointLabel())
        .fontSize(10)
        .fontColor(VividNative.textSecondary)
        .margin({ top: 6 });

      Row() {
        Text('端点沿坐标轴拖动设定黑白场，点击空白区域添加锚点；拖动圆形锚点改变曲线效果')
          .fontSize(9)
          .fontColor(VividNative.textTertiary)
          .layoutWeight(1)
          .margin({ top: 2 });
        // 原生次要按钮。
        Button('重置')
          .fontSize(10)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .controlSize(ControlSize.SMALL)
          .height(24)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .onClick(() => { this.resetCurves(); });
      }
      .width('calc(100% - 28vp)');

      Text(this.curveRevision.toString())
        .fontSize(1)
        .fontColor(Color.Transparent)
        .height(1);
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 6, bottom: 6 });
  }
  @Builder
  ChannelIcon(index: number, color: string) {
    // 纯圆形按钮：用 Shape 描边画圆环，避免 border 带来的方形外框。
    Circle()
      .width(26)
      .height(26)
      .fill(color)
      .stroke(this.selectedChannel === index ? VividNative.emphasize : VividNative.componentNormal)
      .strokeWidth(this.selectedChannel === index ? 2.5 : 1)
      .margin({ right: 10 })
      .onClick(() => {
        this.selectedChannel = index;
        this.selectedPoint = -1;
        setTimeout(() => { this.drawCurve(); }, 0);
      });
  }

  private onResetRevision(): void {
    this.selectedPoint = -1;
    this.drawCurve();
    // The reset rewrites the session anchors this component renders directly;
    // redraw once more after the current frame so the fresh data is visible
    // even if the watch fired before the reset finished mutating state.
    setTimeout(() => { this.drawCurve(); }, 0);
  }

  private currentPoints(): CurveAnchor[] {
    return this.pointsForChannel(this.selectedChannel);
  }

  private pointsForChannel(channel: number): CurveAnchor[] {
    const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
    return adjustments ? adjustments.getCurvePoints(channel) : ColorAdjustmentsFallback();
  }

  private selectedPointLabel(): string {
    const points = this.currentPoints();
    const index = this.selectedPoint >= 0 && this.selectedPoint < points.length ? this.selectedPoint : 0;
    const point = points[index];
    if (!point) return '';
    return `锚点 ${index + 1}  ·  输入 ${(point.x * 100).toFixed(0)}%  输出 ${(point.y * 100).toFixed(0)}%`;
  }

  private curveSignature(points: CurveAnchor[]): string {
    return points.map((point: CurveAnchor): string => point.x + ',' + point.y).join(';');
  }

  private handleCurveMouse(event: MouseEvent): void {
    if (event.button === MouseButton.Left && event.action === MouseAction.Press) {
      this.leftMouseDown = true;
      this.handleCurvePointer(TouchType.Down, event.x, event.y);
      return;
    }
    if (this.leftMouseDown && event.action === MouseAction.Move) {
      this.handleCurvePointer(TouchType.Move, event.x, event.y);
      return;
    }
    if (this.leftMouseDown && event.action === MouseAction.Release) {
      this.leftMouseDown = false;
      this.handleCurvePointer(TouchType.Up, event.x, event.y);
      return;
    }
    if (event.button !== MouseButton.Right || event.action !== MouseAction.Press) return;
    this.leftMouseDown = false;
    event.stopPropagation();
    this.menuTarget = null;
    this.contextPoint = -1;
    const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
    const points = adjustments ? adjustments.getCurvePoints(this.selectedChannel) : [];
    const hit = this.findNearestPoint(points, event.x, event.y);
    console.info(`VIVID_CURVE right x=${event.x} y=${event.y} hit=${hit} w=${this.graphWidth} h=${this.graphHeight}`);
    if (!adjustments || hit < 0) return;
    this.draggingPoint = -1;
    this.gestureTarget = null;
    this.contextPoint = hit;
    this.selectedPoint = hit;
    this.menuTarget = adjustments;
    this.menuChannel = this.selectedChannel;
    this.menuCurveSignature = this.curveSignature(points);
    this.menuOffsetX = event.x;
    this.menuOffsetY = event.y;
    this.drawCurve();
  }

  private canDeleteContextPoint(): boolean {
    const target = this.editSession.adjustmentsForContext(this.maskContext);
    if (!target || target !== this.menuTarget || this.selectedChannel !== this.menuChannel) return false;
    const points = target.getCurvePoints(this.menuChannel);
    return this.contextPoint > 0 && this.contextPoint < points.length - 1 &&
      this.curveSignature(points) === this.menuCurveSignature;
  }

  private deleteContextPoint(): boolean {
    const target = this.menuTarget;
    const allowed = this.canDeleteContextPoint();
    this.showCurvePointMenu = false;
    if (!allowed || !target) return false;
    const result = removeCurveAnchor(this.structuralPoints(target.getCurvePoints(this.menuChannel)), this.contextPoint);
    if (!result.moved) return false;
    this.editSession.pushUndo();
    target.setCurvePoints(this.menuChannel,
      result.points.map((point: CurveAnchorLike): CurveAnchor => new CurveAnchor(point.x, point.y)));
    this.selectedPoint = -1;
    this.contextPoint = -1;
    this.menuTarget = null;
    this.curveRevision++;
    this.drawCurve();
    this.scheduleProcess();
    return true;
  }

  private handleCurveTouch(event: TouchEvent): void {
    // Mouse input is routed separately; ignore its synthetic touch duplicates.
    if (event.source === SourceType.Mouse) return;
    const touch = event.touches[0];
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.setPanelScrollLock(false);
      this.handleCurvePointer(event.type, 0, 0);
    } else if (touch) {
      // 曲线用原始触摸事件取点，不参与手势仲裁：不锁住外层 Scroll 的话，
      // 拖拽锚点时页面会跟着手指一起上下滚动。按下即锁、抬起/取消即解锁。
      if (event.type === TouchType.Down) this.setPanelScrollLock(true);
      this.handleCurvePointer(event.type, touch.x, touch.y);
    }
  }

  /** 请求外层面板滚动条在曲线手势期间停止响应（PhoneLayout 消费该标记）。 */
  private setPanelScrollLock(locked: boolean): void {
    AppStorage.setOrCreate('editorPanelScrollLock', locked);
  }

  aboutToDisappear(): void {
    // 组件被移除时若手势未正常结束，必须解锁，否则面板会永久无法滚动。
    this.setPanelScrollLock(false);
  }

  private handleCurvePointer(action: TouchType, pointerX: number, pointerY: number): void {
    if (this.showCurvePointMenu) return;
    // On release `event.touches` is empty, so settle the gesture first and
    // then read coordinates only for Down/Move events.
    if (action === TouchType.Up || action === TouchType.Cancel) {
      this.draggingPoint = -1;
      this.gestureUndoPushed = false;
      this.gestureAxis = CurveDragAxis.BOTH;
      this.gestureTarget = null;
      // Rendering the curve itself stays synchronous during a gesture. The
      // pixel pipeline runs once after release, preventing a burst of async
      // PixelMap allocations from destabilising low-memory phones.
      this.scheduleProcess();
      return;
    }
    if (this.graphWidth <= 0 || this.graphHeight <= 0) return;
    const points = this.currentPoints();
    const x = Math.max(0, Math.min(1, pointerX / this.graphWidth));
    const y = Math.max(0, Math.min(1, 1 - pointerY / this.graphHeight));
    if (action === TouchType.Down) {
      console.info(`VIVID_CURVE down x=${pointerX} y=${pointerY} w=${this.graphWidth} h=${this.graphHeight} n=${points.length}`);
      // A press only selects. Hitting an existing anchor -- including the two
      // endpoints -- never adds another point, and the undo entry waits until
      // a move actually changes something, so selecting cannot fill the stack.
      this.gestureUndoPushed = false;
      this.gestureAxis = CurveDragAxis.BOTH;
      this.selectedPoint = this.findNearestPoint(points, pointerX, pointerY);
      if (this.selectedPoint >= 0) {
        this.draggingPoint = this.selectedPoint;
      } else {
        this.gestureUndoPushed = this.addAnchorAt(x, y);
        this.draggingPoint = this.gestureUndoPushed ? this.selectedPoint : -1;
      }
      this.pointerStartX = pointerX;
      this.pointerStartY = pointerY;
      const anchor = this.currentPoints()[this.draggingPoint];
      this.anchorStartX = anchor ? anchor.x : 0;
      this.anchorStartY = anchor ? anchor.y : 0;
      this.gestureTarget = this.editSession.adjustmentsForContext(this.maskContext);
      this.gestureChannel = this.selectedChannel;
      this.drawCurve();
    } else if (action === TouchType.Move && this.draggingPoint >= 0) {
      const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
      if (!adjustments || adjustments !== this.gestureTarget || this.selectedChannel !== this.gestureChannel) {
        this.draggingPoint = -1;
        return;
      }
      const current = adjustments.getCurvePoints(this.selectedChannel);
      const deltaX = pointerX - this.pointerStartX;
      const deltaY = pointerY - this.pointerStartY;
      // A hit within the anchor's radius must not jump to the finger or lock
      // the wrong axis on a zero-distance Move generated by native drag.
      if (Math.hypot(deltaX, deltaY) < 3) return;
      const structural = this.structuralPoints(current);
      let axis = this.gestureAxis;
      if (axis === CurveDragAxis.BOTH && isCurveEndpoint(structural, this.draggingPoint)) {
        axis = Math.abs(deltaX) >= Math.abs(deltaY) ? CurveDragAxis.X : CurveDragAxis.Y;
      }
      const move: CurveMoveResult = moveCurveAnchor(structural, this.draggingPoint,
        this.anchorStartX + deltaX / this.graphWidth,
        this.anchorStartY - deltaY / this.graphHeight, axis);
      if (!move.moved) return;
      // The first move that really moves an anchor owns the undo entry for this
      // gesture; every later move reuses it. Endpoints are draggable here too:
      // they slide along one axis, chosen by this move and locked afterwards
      // (see curvePickEndpointAxis for why it cannot be chosen on Down).
      if (!this.gestureUndoPushed) {
        this.editSession.pushUndo();
        this.gestureUndoPushed = true;
      }
      this.gestureAxis = move.axis;
      adjustments.setCurvePoints(this.selectedChannel,
        move.points.map((point: CurveAnchorLike): CurveAnchor => new CurveAnchor(point.x, point.y)));
      this.curveRevision++;
      this.drawCurve();
      // Throttled reprocess keeps the preview following the finger in near
      // real time; stale runs abort themselves via processingRequestVersion.
      this.scheduleProcess();
    }
  }

  private addAnchorAt(x: number, y: number): boolean {
    const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
    if (!adjustments) return false;
    const result = addCurveAnchor(this.structuralPoints(adjustments.getCurvePoints(this.selectedChannel)), x, y);
    if (!result.moved) return false;
    this.editSession.pushUndo();
    const points = result.points.map((point: CurveAnchorLike): CurveAnchor => new CurveAnchor(point.x, point.y));
    adjustments.setCurvePoints(this.selectedChannel, points);
    this.selectedPoint = points.findIndex((point: CurveAnchor): boolean => point.x === x);
    this.curveRevision++;
    this.drawCurve();
    this.scheduleProcess();
    return true;
  }

  private structuralPoints(points: CurveAnchor[]): CurveAnchorLike[] {
    return points.map((point: CurveAnchor): CurveAnchorLike => ({ x: point.x, y: point.y }));
  }

  private findNearestPoint(points: CurveAnchor[], x: number, y: number): number {
    // Endpoints are returned like any other anchor: they are selectable and
    // draggable; the delete action independently protects the endpoints.
    return curveHitTest(this.structuralPoints(points), x, y, this.graphWidth, this.graphHeight);
  }

  private drawCurve(): void {
    const ctx = this.context;
    const width = this.graphWidth;
    const height = this.graphHeight;
    if (width <= 0 || height <= 0) return;
    ctx.clearRect(0, 0, width, height);
    // 基础灰底
    ctx.fillStyle = '#8A94A6';
    ctx.fillRect(0, 0, width, height);
    // 各通道专属渐变底色：左上通道色 → 右下互补色，低透明度叠加，仅作淡淡背景。
    const backdrop = ctx.createLinearGradient(0, 0, width, height);
    if (this.selectedChannel === 0) {
      // 复合通道：中性灰色渐变，无彩色倾向。
      backdrop.addColorStop(0, 'rgba(190,198,208,0.35)');
      backdrop.addColorStop(1, 'rgba(105,113,126,0.35)');
    } else if (this.selectedChannel === 1) {
      // 红色通道：红 → 青。
      backdrop.addColorStop(0, 'rgba(232,72,96,0.40)');
      backdrop.addColorStop(1, 'rgba(58,205,205,0.40)');
    } else if (this.selectedChannel === 2) {
      // 绿色通道：绿 → 品红。
      backdrop.addColorStop(0, 'rgba(56,168,108,0.40)');
      backdrop.addColorStop(1, 'rgba(226,84,170,0.40)');
    } else {
      // 蓝色通道：蓝 → 黄。
      backdrop.addColorStop(0, 'rgba(62,110,232,0.40)');
      backdrop.addColorStop(1, 'rgba(240,196,72,0.40)');
    }
    ctx.fillStyle = backdrop;
    ctx.fillRect(0, 0, width, height);

    // 3 横 3 竖网格线，把画布均匀分成 4×4。
    ctx.strokeStyle = 'rgba(255,255,255,0.30)';
    ctx.lineWidth = 1;
    for (let index = 1; index < 4; index++) {
      const x = width * index / 4;
      const y = height * index / 4;
      ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, height); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(width, y); ctx.stroke();
    }

    // 直方图波形：色彩随通道（复合=深色波形，红/绿/蓝=对应颜色波形）。
    this.drawHistogram(ctx, width, height);

    // 其他通道曲线以各自通道色虚化显示，便于对照；当前通道曲线再叠加在上层。
    const ghostColors: string[] = [
      'rgba(255,255,255,0.30)', 'rgba(230,75,95,0.42)',
      'rgba(54,165,107,0.42)', 'rgba(78,121,232,0.42)',
    ];
    const channelColors: string[] = ['#FFFFFF', '#E64B5F', '#36A56B', '#4E79E8'];
    for (let channel = 0; channel < 4; channel++) {
      if (channel === this.selectedChannel) continue;
      this.strokeChannelCurve(ctx, this.pointsForChannel(channel), width, height, ghostColors[channel], 1.5);
    }

    // 曲线：平滑贝塞尔路径，颜色与通道对应（复合=白、红、绿、蓝）。
    const points = this.currentPoints();
    ctx.strokeStyle = channelColors[this.selectedChannel];
    ctx.lineWidth = 2.5;
    ctx.beginPath();
    ctx.moveTo(points[0].x * width, height - points[0].y * height);
    for (let index = 0; index < points.length - 1; index++) {
      const p0 = index > 0 ? points[index - 1] : points[index];
      const p1 = points[index];
      const p2 = points[index + 1];
      const p3 = index + 2 < points.length ? points[index + 2] : points[index + 1];
      const c1x = p1.x + (p2.x - p0.x) / 6;
      const c1y = p1.y + (p2.y - p0.y) / 6;
      const c2x = p2.x - (p3.x - p1.x) / 6;
      const c2y = p2.y - (p3.y - p1.y) / 6;
      ctx.bezierCurveTo(
        c1x * width, height - c1y * height,
        c2x * width, height - c2y * height,
        p2.x * width, height - p2.y * height);
    }
    ctx.stroke();

    // 锚点：实心白色圆点，选中点加大并带深色外环。
    for (let index = 0; index < points.length; index++) {
      const px = points[index].x * width;
      const py = height - points[index].y * height;
      const selected = index === this.selectedPoint;
      ctx.fillStyle = '#FFFFFF';
      ctx.strokeStyle = '#FFFFFF';
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.arc(px, py, selected ? 6.5 : 5.5, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();
      if (selected) {
        ctx.strokeStyle = '#253148';
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(px, py, 9, 0, Math.PI * 2);
        ctx.stroke();
      }
    }
  }

  /** 绘制一条通道的平滑曲线（虚化通道复用）。 */
  private strokeChannelCurve(ctx: CanvasRenderingContext2D, points: CurveAnchor[],
    width: number, height: number, color: string, lineWidth: number): void {
    if (points.length === 0) return;
    ctx.strokeStyle = color;
    ctx.lineWidth = lineWidth;
    ctx.beginPath();
    ctx.moveTo(points[0].x * width, height - points[0].y * height);
    for (let index = 0; index < points.length - 1; index++) {
      const p0 = index > 0 ? points[index - 1] : points[index];
      const p1 = points[index];
      const p2 = points[index + 1];
      const p3 = index + 2 < points.length ? points[index + 2] : points[index + 1];
      const c1x = p1.x + (p2.x - p0.x) / 6;
      const c1y = p1.y + (p2.y - p0.y) / 6;
      const c2x = p2.x - (p3.x - p1.x) / 6;
      const c2y = p2.y - (p3.y - p1.y) / 6;
      ctx.bezierCurveTo(
        c1x * width, height - c1y * height,
        c2x * width, height - c2y * height,
        p2.x * width, height - p2.y * height);
    }
    ctx.stroke();
  }

  private drawHistogram(ctx: CanvasRenderingContext2D, width: number, height: number): void {
    const data = this.histogramForChannel();
    let maxValue = 1;
    for (let index = 0; index < 256; index++) {
      if (data[index] > maxValue) maxValue = data[index];
    }
    const bucketW = width / 256;
    const maxH = height - 6;
    ctx.beginPath();
    ctx.moveTo(0, height);
    for (let index = 0; index < 256; index++) {
      const x = index * bucketW;
      const y = height - (data[index] / maxValue) * maxH - 3;
      ctx.lineTo(x, y);
    }
    ctx.lineTo(width, height);
    ctx.closePath();
    ctx.fillStyle = this.histogramColor();
    ctx.fill();
  }

  private histogramForChannel(): Uint32Array {
    if (this.selectedChannel === 1) return this.editSession.histogramR;
    if (this.selectedChannel === 2) return this.editSession.histogramG;
    if (this.selectedChannel === 3) return this.editSession.histogramB;
    return this.editSession.histogramL;
  }

  private histogramColor(): string {
    if (this.selectedChannel === 1) return 'rgba(230,75,95,0.42)';
    if (this.selectedChannel === 2) return 'rgba(54,165,107,0.42)';
    if (this.selectedChannel === 3) return 'rgba(78,121,232,0.42)';
    return 'rgba(38,50,71,0.38)';
  }

  /** 重置四个通道的曲线锚点与曲线强度，并立即重绘画布与预览。 */
  private resetCurves(): void {
    const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
    if (!adjustments) return;
    this.editSession.pushUndo();
    for (let channel = 0; channel < 4; channel++) {
      adjustments.setCurvePoints(channel, ColorAdjustments.defaultCurve());
    }
    adjustments.setValue('toneCurve', 0);
    adjustments.setValue('curveRed', 0);
    adjustments.setValue('curveGreen', 0);
    adjustments.setValue('curveBlue', 0);
    this.selectedPoint = -1;
    this.curveRevision++;
    this.drawCurve();
    this.scheduleProcess();
  }

  private scheduleProcess(): void {
    // Throttle instead of debounce: while a drag is active the pipeline runs
    // every 33ms so the preview updates live, but never more often than that.
    // Curves mutate the adjustment model directly, so mark the request here
    // instead of bumping the public UI version on every move.  The timestamp
    // also selects the bounded 512px/GPU path while the finger is down.
    this.editSession.requestProcessing();
    if (this.processPending) return;
    this.processPending = true;
    this.processTimer = setTimeout(() => {
      this.processPending = false;
      this.processTimer = -1;
      ImageProcessor.process(this.editSession);
    }, 33);
  }
}

function ColorAdjustmentsFallback(): CurveAnchor[] {
  return ColorAdjustments.defaultCurve();
}
