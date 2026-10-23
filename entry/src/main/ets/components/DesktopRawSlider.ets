import { VividNative, VividNumberField } from './VividNativeTheme';
import { noteSliderInteracting, sliderInteractingEnded } from './SliderOverlayGuard';

/** Compact desktop inspector control. Display units do not change stored values. */
@Component
export struct DesktopRawSlider {
  @Prop label: string = '';
  @Prop controlId: string = '';
  @Prop @Watch('syncValue') currentValue: number = 0;
  @Prop lower: number = -1;
  @Prop upper: number = 1;
  @Prop increment: number = 0.01;
  @Prop displayScale: number = 100;
  @Prop decimals: number = 0;
  @Prop suffix: string = '';
  @Prop gradientType: string = 'normal';
  @Prop disabled: boolean = false;
  @StorageProp('vividNightMode') private night: boolean = false;
  @State private editing: boolean = false;
  @State private draft: string = '';
  @State private displayedValue: number = 0;
  private gestureStarted: boolean = false;
  onBegin: () => void = () => {};
  onUpdate: (v: number) => void = () => {};
  onEnd: () => void = () => {};
  /** 与 SliderControl 同义：拖动期间临时隐藏蒙版叠加层，便于观察调色效果。 */
  @Prop hideOverlayWhileDragging: boolean = true;

  aboutToAppear(): void { this.syncValue(); }

  private syncValue(): void {
    this.displayedValue = this.currentValue;
  }

  build() {
    Column() {
      Row() {
        Text(this.label).fontSize(12).fontColor(VividNative.textPrimary).layoutWeight(1);
        // 数值只显示数字本身：去掉原生数值框的填充与描边（仍可点入编辑）。
        // 类型保持 Normal，否则负号与小数点会被拦掉。
        TextInput({ text: this.editing ? this.draft : (this.displayedValue * this.displayScale).toFixed(this.decimals) })
          .id('raw-value-' + this.controlId).width(56).height(26).fontSize(11)
          .textAlign(TextAlign.End)
          .padding({ left: 5, right: 5, top: 0, bottom: 0 })
          .attributeModifier(VividNumberField.plain)
          .onFocus(() => { this.editing = true; this.draft = (this.displayedValue * this.displayScale).toFixed(this.decimals); })
          .onChange((text: string) => { this.draft = text; })
          .onSubmit(() => { this.commitInput(); })
          .onBlur(() => { if (this.editing) this.commitInput(); });
        if (this.suffix.length > 0) {
          Text(this.suffix).fontSize(10).fontColor(VividNative.textSecondary).margin({ left: 4 });
        }
      }.width('100%').height(28);
      Stack() {
        // 彩色渐变轨道保留：滑杆的调色语义（色温/色调/色相方向）不能退化成无色。
        Row().width('calc(100% - 12vp)').height(4).borderRadius(2)
          .linearGradient({ angle: 90, colors: this.gradientColors() });
        Slider({ value: this.displayedValue, min: this.lower, max: this.upper, step: this.increment,
        style: SliderStyle.OutSet })
        .id('raw-slider-' + this.controlId).width('100%').height(16).trackThickness(3)
        .trackColor(Color.Transparent).selectedColor(Color.Transparent)
        .blockColor(this.night ? '#FFFFFF' : '#000000').blockBorderWidth(0)
        .blockSize({ width: 12, height: 10 })
        .blockStyle({ type: SliderBlockType.SHAPE, shape: new Path().commands('M 0 9 L 6 0 L 12 9 Z') })
        .onChange((v: number, mode: SliderChangeMode) => {
          if (!this.gestureStarted) {
            this.gestureStarted = true;
            if (this.hideOverlayWhileDragging) noteSliderInteracting();
            this.onBegin();
          }
          this.displayedValue = v;
          if (this.hideOverlayWhileDragging) noteSliderInteracting();
          this.onUpdate(v);
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.gestureStarted = false; this.onEnd();
            if (this.hideOverlayWhileDragging) sliderInteractingEnded();
          }
        });
      }.width('100%').height(16);
    }.width('100%').height(46).margin({ bottom: 2 })
      .enabled(!this.disabled)
      // 禁用反馈走系统禁用透明度令牌，和原生控件一致。
      .opacity(this.disabled ? VividNative.disabledAlphaFallback : 1);
  }

  private gradientColors(): Array<[string, number]> {
    if (this.gradientType === 'temperature') return [['#3F72EF', 0], ['#D4D4D4', 0.5], ['#F2D23C', 1]];
    if (this.gradientType === 'tint') return [['#D74BB5', 0], ['#D4D4D4', 0.5], ['#42BE68', 1]];
    if (this.gradientType === 'hue') return [['#36C9D1', 0], ['#C24ED9', 0.25], ['#ED534A', 0.5], ['#6BC64B', 0.75], ['#36C9D1', 1]];
    if (this.gradientType === 'saturation' || this.gradientType === 'vibrance') return [['#858585', 0], ['#D3ADAD', 0.5], ['#E64778', 1]];
    if (this.gradientType === 'exposure' || this.gradientType === 'brightness' || this.gradientType === 'highlights' ||
      this.gradientType === 'shadows' || this.gradientType === 'whites' || this.gradientType === 'blacks' || this.gradientType === 'contrast') {
      return [['#343434', 0], ['#969696', 0.5], ['#FFFFFF', 1]];
    }
    return [[this.night ? '#999999' : '#777777', 0], [this.night ? '#EEEEEE' : '#DADADA', 1]];
  }

  private commitInput(): void {
    const number = Number(this.draft.trim());
    this.editing = false;
    if (!Number.isFinite(number) || this.draft.trim().length === 0) return;
    this.onBegin();
    this.displayedValue = Math.max(this.lower, Math.min(this.upper, number / this.displayScale));
    this.onUpdate(this.displayedValue);
    this.onEnd();
  }
}
