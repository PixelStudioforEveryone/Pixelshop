import { EditSession } from '../edit/models/EditSession';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { ColorMath } from '../edit/utils/ColorMath';
import { VividMaterial, VividSliderMaterial } from './VividMaterial';
import { VividNative, VividNumberField } from './VividNativeTheme';

interface GradingMode {
  index: number;
  label: string;
  color: string;
}

const GRADING_MODES: GradingMode[] = [
  // 混合 represents the linked three-way view. It is a peer of the four
  // single-range modes, so the former standalone three-dot selector is gone.
  { index: 0, label: '混合', color: '#316CF4' },
  { index: 1, label: '阴影', color: '#5C6FA7' },
  { index: 2, label: '中间调', color: '#7B83B8' },
  { index: 3, label: '高光', color: '#E0A85C' },
  { index: 4, label: '全局', color: '#6B77EE' },
];

/** Circular H/S picker used by the color-grading panel. */
@Component
struct GradingWheel {
  @Prop @Watch('syncHue') hue: number = 0;
  @Prop @Watch('syncSaturation') saturation: number = 0;
  @Prop compact: boolean = false;
  @Prop title: string = '';
  @Prop showValues: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  onChange: (hue: number, saturation: number) => void = () => {};
  /** 色盘按下/抬起时通知外层：拖拽锚点期间必须停掉页面纵向滚动。 */
  onDragStateChange: (dragging: boolean) => void = () => {};
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  @State private wheelWidth: number = 128;
  @State private wheelHeight: number = 128;
  @State private canvasReady: boolean = false;
  @State private currentHue: number = 0;
  @State private currentSaturation: number = 0;
  private draggingWheel: boolean = false;

  aboutToAppear(): void {
    this.currentHue = this.hue;
    this.currentSaturation = this.saturation;
  }

  build() {
    Column() {
      Canvas(this.context)
        .width(this.compact ? 96 : 154)
        .height(this.compact ? 96 : 154)
        .onReady(() => {
          // Canvas commands are only valid after the native surface exists.
          // Drawing from aboutToAppear caused the grading tab to throw on some
          // HarmonyOS builds before the first frame was attached.
          this.canvasReady = true;
          this.drawWheel();
        })
        .onAreaChange((_: Area, area: Area) => {
          this.wheelWidth = area.width as number;
          this.wheelHeight = area.height as number;
          if (this.canvasReady) this.drawWheel();
        })
        .onTouch((event: TouchEvent) => { this.handleTouch(event); });
      Text(this.title)
        .fontSize(this.compact ? 10 : 12)
        .fontColor(VividNative.textSecondary)
        .margin({ top: 2 });
      if (this.showValues) {
        Row() {
          Text(`H ${this.currentHue.toFixed(0)}°`)
            .fontSize(10)
            .fontColor(VividNative.textSecondary);
          Text(`S ${this.currentSaturation.toFixed(2)}`)
            .fontSize(10)
            .fontColor(VividNative.textSecondary)
            .margin({ left: 14 });
        }
        .margin({ top: 2 });
      }
    }
    .alignItems(HorizontalAlign.Center)
    .width(this.compact ? 108 : 170)
    .padding({ top: 3, bottom: 3 });
  }

  private syncHue(): void {
    this.currentHue = this.hue;
    if (this.canvasReady) setTimeout(() => { this.drawWheel(); }, 0);
  }

  private syncSaturation(): void {
    this.currentSaturation = this.saturation;
    if (this.canvasReady) setTimeout(() => { this.drawWheel(); }, 0);
  }

  private handleTouch(event: TouchEvent): void {
    // 按下即锁、抬起/取消即解锁：色盘用 Canvas 的原始触摸事件取点，不参与
    // 外层 Scroll 的手势仲裁。不锁住的话，拖动锚点时页面会跟着上下滚动。
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.endWheelDrag();
      return;
    }
    if (!this.draggingWheel) {
      this.draggingWheel = true;
      this.onDragStateChange(true);
    }
    const touch = event.touches[0];
    if (!touch) return;
    const centerX = this.wheelWidth / 2;
    const centerY = this.wheelHeight / 2;
    const radius = Math.max(8, Math.min(this.wheelWidth, this.wheelHeight) / 2 - 10);
    const dx = touch.x - centerX;
    const dy = touch.y - centerY;
    const distance = Math.min(radius, Math.hypot(dx, dy));
    const angle = Math.atan2(dy, dx) + Math.PI / 2;
    const hue = ((angle * 180 / Math.PI) % 360 + 360) % 360;
    const saturation = Math.max(0, Math.min(1, distance / radius));
    this.currentHue = hue;
    this.currentSaturation = saturation;
    this.onChange(hue, saturation);
    this.drawWheel();
  }

  private endWheelDrag(): void {
    if (!this.draggingWheel) return;
    this.draggingWheel = false;
    this.onDragStateChange(false);
  }

  aboutToDisappear(): void {
    // 组件被移除时手势可能没有正常结束，必须解锁，否则页面会永久无法滚动。
    this.endWheelDrag();
  }

  private drawWheel(): void {
    const width = this.wheelWidth;
    const height = this.wheelHeight;
    if (!isFinite(width) || !isFinite(height) || width <= 0 || height <= 0) return;
    const ctx = this.context;
    const centerX = width / 2;
    const centerY = height / 2;
    const radius = Math.max(8, Math.min(width, height) / 2 - 10);
    ctx.clearRect(0, 0, width, height);

    // Concentric hue wedges approximate a conic + radial H/S gradient while
    // staying compatible with the Canvas API available on HarmonyOS 7.
    // The wheel is static while scrolling; fewer sectors preserve a smooth
    // gradient but cut Canvas path work by more than half on phone GPUs.
    const hueSteps = 36;
    const saturationSteps = 6;
    for (let satIndex = 0; satIndex < saturationSteps; satIndex++) {
      const inner = Math.max(0.5, radius * satIndex / saturationSteps);
      const outer = radius * (satIndex + 1) / saturationSteps + 0.7;
      const sat = (satIndex + 0.5) / saturationSteps;
      for (let hueIndex = 0; hueIndex < hueSteps; hueIndex++) {
        const start = hueIndex / hueSteps * Math.PI * 2 - Math.PI / 2;
        const end = (hueIndex + 1) / hueSteps * Math.PI * 2 - Math.PI / 2;
        ctx.beginPath();
        ctx.arc(centerX, centerY, outer, start, end);
        ctx.arc(centerX, centerY, inner, end, start, true);
        ctx.closePath();
        ctx.fillStyle = ColorMath.hslToHex(hueIndex / hueSteps * 360, sat, 0.52);
        ctx.fill();
      }
    }

    ctx.strokeStyle = '#FFFFFF';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(centerX, centerY, radius, 0, Math.PI * 2);
    ctx.stroke();

    const selectedAngle = this.currentHue / 360 * Math.PI * 2 - Math.PI / 2;
    const selectedDistance = this.currentSaturation * radius;
    const selectedX = centerX + Math.cos(selectedAngle) * selectedDistance;
    const selectedY = centerY + Math.sin(selectedAngle) * selectedDistance;
    const outerX = centerX + Math.cos(selectedAngle) * radius;
    const outerY = centerY + Math.sin(selectedAngle) * radius;

    // Center point is the active color picker; the perimeter point exposes the
    // saturation value so both controls remain visible in compact mode.
    ctx.fillStyle = '#FFFFFF';
    ctx.strokeStyle = '#344158';
    ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.arc(centerX, centerY, 4, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    ctx.beginPath(); ctx.arc(selectedX, selectedY, 6, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    ctx.fillStyle = ColorMath.hslToHex(this.currentHue, 1, 0.52);
    ctx.beginPath(); ctx.arc(outerX, outerY, 4.5, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
  }
}

/** Slider with the project's light gradient track, triangular indicator and input box. */
@Component
struct GradingSlider {
  @Prop @Watch('syncValue') value: number = 0;
  @Prop label: string = '';
  @Prop min: number = -1;
  @Prop max: number = 1;
  @Prop step: number = 0.01;
  @Prop compact: boolean = false;
  @Prop gradient: Array<[string, number]> = [['#DCE3EE', 0], ['#6B77EE', 1]];
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  formatValue: (value: number) => string = (value: number) => value.toFixed(2);
  onBegin: () => void = () => {};
  onChange: (value: number) => void = () => {};
  @State private currentValue: number = 0;
  @State private trackWidth: number = 220;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    this.currentValue = this.value;
  }

  build() {
    Row() {
      Text(this.label)
        .fontSize(this.compact ? 10 : 12)
        .fontColor(VividNative.textPrimary)
        .width(this.compact ? 16 : 54);
      Stack() {
        Canvas(this.context)
          .width('100%')
          .height(26)
          .hitTestBehavior(HitTestMode.None)
          .onReady(() => { this.drawTrack(); })
          .onAreaChange((_: Area, area: Area) => {
            this.trackWidth = area.width as number;
            this.drawTrack();
          });
        Slider({
          // Keep the native slider's gesture recognizer active.  SliderStyle
          // NONE can render but not dispatch drag changes on some simulator
          // builds, which made luminance/blending/balance appear inert. The
          // track and thumb remain transparent because Canvas draws the visual
          // track and solid circular anchor below.
          style: SliderStyle.OutSet,
          min: this.min,
          max: this.max,
          step: this.step,
          value: this.currentValue,
        })
          .width('100%')
          .height(26)
          // 轨道/滑块全透明：视觉轨道与锚点由上方 Canvas 自绘。
          .trackColor(Color.Transparent)
          .selectedColor(Color.Transparent)
          .blockColor(Color.Transparent)
          .blockBorderColor(Color.Transparent)
          .blockSize({ width: 20, height: 20 })
          .attributeModifier(new VividSliderMaterial())
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) this.onBegin();
          })
          .onChange((value: number) => {
            this.currentValue = value;
            this.drawTrack();
            this.onChange(value);
          });
      }
      .layoutWeight(1)
      .height(28);
      TextInput({ text: this.formatValue(this.currentValue) })
        // Reserve enough room for the complete 0.00 value.  The previous
        // compact width clipped the last zero at the right edge of the wheel.
        .width(this.compact ? 54 : 62)
        .height(28)
        .margin({ left: this.compact ? 5 : 8 })
        .fontSize(11)
        // 调色面板数值改为纯数字：去掉原生数值框的填充与描边。
        .attributeModifier(VividNumberField.plain)
        .textAlign(TextAlign.Center)
        .padding({ left: 0, right: 0 })
        // Keep the decimal point visible/editable; the Number input mode on
        // HarmonyOS accepts only integer characters on some simulator images.
        .type(InputType.Normal)
        .onChange((text: string) => {
          const parsed = parseFloat(text);
          if (isNaN(parsed)) return;
          const value = Math.max(this.min, Math.min(this.max, parsed));
          this.currentValue = value;
          this.drawTrack();
          this.onChange(value);
        });
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 4, bottom: 4 });
  }

  private syncValue(): void {
    this.currentValue = this.value;
    setTimeout(() => { this.drawTrack(); }, 0);
  }

  private drawTrack(): void {
    const width = this.trackWidth;
    if (width <= 0) return;
    const ctx = this.context;
    const position = (this.currentValue - this.min) / Math.max(0.0001, this.max - this.min);
    // Keep the 7px thumb fully inside the canvas at both endpoints.  A value
    // of min/max previously put the circle's edge outside the clipped Canvas.
    const thumbRadius = 7;
    const inset = thumbRadius + 2;
    const x = inset + Math.max(0, Math.min(1, position)) * Math.max(1, width - inset * 2);
    ctx.clearRect(0, 0, width, 26);
    const gradient = ctx.createLinearGradient(0, 0, width, 0);
    for (let index = 0; index < this.gradient.length; index++) {
      gradient.addColorStop(this.gradient[index][1], this.gradient[index][0]);
    }
    ctx.fillStyle = gradient;
    ctx.fillRect(inset, 10, Math.max(1, width - inset * 2), 5);
    // Match the rest of the adjustment controls: a solid circular thumb,
    // rather than the former triangular marker.
    ctx.fillStyle = '#FFFFFF';
    ctx.strokeStyle = this.isNightMode ? 'rgba(255,255,255,0.5)' : '#C9D2DE';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(x, 13, thumbRadius, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();
  }
}

@Component
export struct ColorGradingPanel {
  @Consume('editSession') editSession: EditSession;
  @Prop maskContext: boolean = false;
  @Prop embedded: boolean = false;
  @Prop externalScroll: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  // PhoneLayout/TabletLayout 都消费同一个标记；色盘拖拽期间它同时停掉本面板
  // 自己的 Scroll 和外层页面 Scroll。
  @StorageProp('editorPanelScrollLock') private panelScrollLock: boolean = false;
  @State private collapsed: boolean = false;
  @State private mode: number = 0; // 0 = three-way linked, 1..4 = single wheel
  @State private revision: number = 0;
  private processTimer: number = -1;
  private processPending: boolean = false;

  build() {
    if (this.externalScroll) {
      Column() {
        this.GradingBody();
      }
      .width('100%')
      .attributeModifier(VividMaterial.card);
    } else {
      Scroll() {
        this.GradingBody();
      }
      .layoutWeight(this.embedded ? 0 : 1)
      .height(this.embedded ? 430 : '100%')
      .width('100%')
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .enableScrollInteraction(!this.panelScrollLock)
      .backgroundColor(Color.Transparent)
      .attributeModifier(VividMaterial.card);
    }
  }

  @Builder
  private GradingBody() {
    Column() {
      Row() {
        ForEach(GRADING_MODES, (item: GradingMode) => {
          this.ModeButton(item);
        }, (item: GradingMode) => item.label);
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      .padding({ left: 2, right: 2, top: 8, bottom: 8 });

      if (this.isEnabled()) {
        if (this.mode === 0) {
          this.ThreeWayControls();
        } else {
          this.SingleModeControls(this.mode - 1);
        }
      } else {
        Text('颜色分级已关闭')
          .fontSize(11)
          .fontColor(VividNative.textSecondary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 18, bottom: 24 });
      }
      Text(this.revision.toString())
        .fontSize(1)
        .fontColor(Color.Transparent)
        .height(1);
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6, bottom: 32 });
  }
  @Builder
  private ModeButton(item: GradingMode) {
    Column() {
      Circle()
        .width(24)
        .height(24)
        // 圆点保留各分级模式的语义色（阴影/中间调/高光/全局），选中描边与未选中底改为系统令牌。
        .fill(this.mode === item.index ? item.color : VividNative.componentNormal)
        .stroke(this.mode === item.index ? VividNative.emphasize : VividNative.separator)
        .strokeWidth(1.5);
      Text(item.label)
        .fontSize(9)
        .fontColor(this.mode === item.index ? VividNative.textPrimaryActivated : VividNative.textSecondary)
        .margin({ top: 2 });
    }
    .width(52)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.mode = item.index;
      this.revision++;
    });
  }

  @Builder
  private ThreeWayControls() {
    Column() {
      this.ThreeWayWheel(1, '中间调');
      Row() {
        this.ThreeWayWheel(0, '阴影');
        this.ThreeWayWheel(2, '高光');
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceAround);
      GradingSlider({
        label: '混合', min: -1, max: 1, step: 0.01,
        value: this.gradeGlobal('gradingBlending'),
        gradient: [['#DCE3EE', 0], ['#9CA9C1', 0.5], ['#6B77EE', 1]],
        onBegin: () => { this.editSession.pushUndo(); },
        onChange: (value: number) => { this.setGlobal('gradingBlending', value); },
      });
      GradingSlider({
        label: '平衡', min: -1, max: 1, step: 0.01,
        value: this.gradeGlobal('gradingBalance'),
        gradient: [['#5C6FA7', 0], ['#DCE3EE', 0.5], ['#E0A85C', 1]],
        onBegin: () => { this.editSession.pushUndo(); },
        onChange: (value: number) => { this.setGlobal('gradingBalance', value); },
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: 8 });
  }

  @Builder
  private ThreeWayWheel(channel: number, title: string) {
    Column() {
      GradingWheel({
        title: title,
        compact: true,
        hue: this.grade(channel, 0),
        saturation: this.grade(channel, 1),
        onDragStateChange: (dragging: boolean) => { this.setWheelScrollLock(dragging); },
        onChange: (hue: number, saturation: number) => {
          this.setGrade(channel, 0, hue);
          this.setGrade(channel, 1, saturation);
        },
      });
      GradingSlider({
        label: 'S', min: 0, max: 1, step: 0.01,
        compact: true,
        value: this.grade(channel, 1),
        gradient: [['#DCE3EE', 0], [this.gradeColor(channel), 1]],
        onBegin: () => { this.editSession.pushUndo(); },
        onChange: (value: number) => { this.setGrade(channel, 1, value); },
      });
    }
    .width(154)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 8, bottom: 8, left: 6, right: 6 })
    .borderRadius(VividNative.radiusCard)
    .attributeModifier(VividMaterial.card);
  }

  private gradeColor(channel: number): string {
    if (channel === 0) return '#5C6FA7';
    if (channel === 1) return '#7B83B8';
    return '#E0A85C';
  }

  @Builder
  private SingleModeControls(channel: number) {
    Column() {
      GradingWheel({
        title: this.modeTitle(channel),
        showValues: true,
        hue: this.grade(channel, 0),
        saturation: this.grade(channel, 1),
        onDragStateChange: (dragging: boolean) => { this.setWheelScrollLock(dragging); },
        onChange: (hue: number, saturation: number) => {
          this.setGrade(channel, 0, hue);
          this.setGrade(channel, 1, saturation);
        },
      });
      GradingSlider({
        label: '明亮度', min: -1, max: 1, step: 0.01,
        value: this.grade(channel, 2),
        gradient: [['#DCE3EE', 0], ['#F5F7FA', 0.5], ['#E0A85C', 1]],
        onBegin: () => { this.editSession.pushUndo(); },
        onChange: (value: number) => { this.setGrade(channel, 2, value); },
      });
      if (channel !== 3) {
        GradingSlider({
          label: '混合', min: -1, max: 1, step: 0.01,
          value: this.gradeGlobal('gradingBlending'),
          gradient: [['#DCE3EE', 0], ['#9CA9C1', 0.5], ['#6B77EE', 1]],
          onBegin: () => { this.editSession.pushUndo(); },
          onChange: (value: number) => { this.setGlobal('gradingBlending', value); },
        });
        GradingSlider({
          label: '平衡', min: -1, max: 1, step: 0.01,
          value: this.gradeGlobal('gradingBalance'),
          gradient: [['#5C6FA7', 0], ['#DCE3EE', 0.5], ['#E0A85C', 1]],
          onBegin: () => { this.editSession.pushUndo(); },
          onChange: (value: number) => { this.setGlobal('gradingBalance', value); },
        });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: 8, left: 8, right: 8 })
    .borderRadius(VividNative.radiusCard)
    .attributeModifier(VividMaterial.card);
  }

  private modeTitle(channel: number): string {
    if (channel === 0) return '阴影';
    if (channel === 1) return '中间调';
    if (channel === 2) return '高光';
    return '全局';
  }

  /** 请求外层 Scroll 在色盘手势期间停止响应（PhoneLayout/TabletLayout 消费该标记）。 */
  private setWheelScrollLock(locked: boolean): void {
    AppStorage.setOrCreate('editorPanelScrollLock', locked);
  }

  private isEnabled(): boolean {
    return this.editSession.adjustmentsForContext(this.maskContext)?.colorGradingEnabled ?? true;
  }

  private toggleEnabled(): void {
    const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
    if (!adjustments) return;
    this.editSession.pushUndo();
    adjustments.colorGradingEnabled = !adjustments.colorGradingEnabled;
    this.revision++;
    this.editSession.bumpProcessing();
    ImageProcessor.process(this.editSession);
  }

  private grade(channel: number, axis: number): number {
    return this.editSession.adjustmentsForContext(this.maskContext)?.getColorGradeValue(channel, axis) ?? 0;
  }

  private gradeGlobal(key: string): number {
    return this.editSession.adjustmentsForContext(this.maskContext)?.getValue(key) ?? 0;
  }

  private setGrade(channel: number, axis: number, value: number): void {
    const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
    if (!adjustments) return;
    const safeValue = axis === 0 ? Math.max(0, Math.min(360, value)) :
      axis === 1 ? Math.max(0, Math.min(1, value)) : Math.max(-1, Math.min(1, value));
    adjustments.setColorGradeValue(channel, axis, safeValue);
    this.editSession.requestProcessing();
    this.scheduleProcess();
  }

  private setGlobal(key: string, value: number): void {
    const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
    if (!adjustments) return;
    adjustments.setValue(key, Math.max(-1, Math.min(1, value)));
    this.editSession.requestProcessing();
    this.scheduleProcess();
  }

  private scheduleProcess(): void {
    if (this.processPending) return;
    this.processPending = true;
    this.processTimer = setTimeout(() => {
      this.processPending = false;
      this.processTimer = -1;
      ImageProcessor.process(this.editSession);
    }, 33);
  }
}
