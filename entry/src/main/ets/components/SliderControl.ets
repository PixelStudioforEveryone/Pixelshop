import { VividSliderMaterial } from './VividMaterial';
import { VividNative } from './VividNativeTheme';
import { PerfStats } from '../edit/utils/PerfStats';
import { noteSliderInteracting, sliderInteractingEnded } from './SliderOverlayGuard';
@Component
export struct SliderControl {
  @Prop @Watch('syncValue') value: number = 0;
  @State private currentValue: number = 0;
  @Prop label: string = '';
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @Prop min: number = -1;
  @Prop max: number = 1;
  @Prop step: number = 0.01;
  @Prop gradientType: string = 'normal';
  @Prop gradientStart: string = '';
  @Prop gradientMid: string = '';
  @Prop gradientEnd: string = '';
  /**
   * 任意数量的渐变停靠点，`|` 分隔的 #RRGGBB，位置在 0..1 上等距铺开。
   * 点颜色的色相滑槽需要 9 个点绕满 ±180° 色相环，固定的三个端点做不到。
   */
  @Prop gradientRamp: string = '';
  /**
   * 白色锚点：混色器的调色滑块要求把拖动锚点从系统主文字色（日间为黑）
   * 改成白色。白填充在浅色轨道上会糊成一片，所以同时换成深色描边。
   * 默认 false，其它面板的滑杆外观不变。
   */
  @Prop whiteAnchor: boolean = false;
  formatValue: (v: number) => string = (v) => v.toFixed(2);
  onBegin: () => void = () => {};
  onEnd: () => void = () => {};
  onChange: (val: number) => void = () => {};
  /**
   * 拖动时是否临时隐藏蒙版叠加层（默认隐藏）。
   *
   * 调色时红色覆盖会挡住画面，看不清效果，所以拖动期间先藏起来。画笔自己的滑
   * 杆（笔刷大小等）要例外——那时蒙版叠加是正在绘制的反馈，不该消失。
   */
  @Prop hideOverlayWhileDragging: boolean = true;

  aboutToAppear(): void {
    this.currentValue = this.value;
  }

  private syncValue(): void {
    this.currentValue = this.value;
  }

  build() {
    Column() {
      Row() {
        Text(this.label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(VividNative.textPrimary)
          .fontFamily('HarmonyOS Sans')
          .width(64)
          .textAlign(TextAlign.Start);

        Stack() {
          // 彩色渐变轨道保留：调色语义（色温/色调/色相/混色器）不能退化成无色。
          if (this.gradientType !== 'normal') {
            Row()
              .width('100%')
              .height(5)
              .borderRadius(3)
              .linearGradient({ angle: 90, colors: this.gradientColors() });
          }
          Slider({
            style: SliderStyle.OutSet,
            min: this.min,
            max: this.max,
            step: this.step,
            value: this.currentValue,
          })
            .width('100%')
            // 无渐变滑杆用系统轨道色；不再自带蓝色已选段（原有视觉语义不变）。
            .trackColor(this.gradientType === 'normal' ? VividNative.sliderTrack : Color.Transparent)
            .selectedColor(this.gradientType === 'normal' ? VividNative.sliderTrack : Color.Transparent)
            .trackThickness(8)
            // 滑块用系统滑块前景色 + 系统控件常态色描边。
            // 混色器例外：白色填充 + 深色描边，确保在白色/中灰轨道上都看得清。
            .blockColor(this.whiteAnchor ? Color.White : VividNative.sliderBlock)
            .blockBorderColor(this.whiteAnchor ? '#344158' : VividNative.componentNormal)
            .blockBorderWidth(this.whiteAnchor ? 1.5 : 1)
            .blockSize({ width: 16, height: 16 })
            // 原生触感反馈（系统滑杆参数）。
            .enableHapticFeedback(true)
            .attributeModifier(new VividSliderMaterial())
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                if (this.hideOverlayWhileDragging) noteSliderInteracting();
                this.onBegin();
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.onEnd();
                if (this.hideOverlayWhileDragging) sliderInteractingEnded();
              }
            })
            .onChange((val: number) => {
              this.currentValue = val;
              // 兜底：有些调用点不接 onEnd，靠这里的防抖超时自动恢复。
              if (this.hideOverlayWhileDragging) noteSliderInteracting();
              const start = Date.now();
              this.onChange(val);
              PerfStats.recordSliderCallback(Date.now() - start);
            });
        }
        .layoutWeight(1)
        .height(24);

        Text(this.formatValue(this.currentValue))
          .fontSize(13)
          .fontWeight(FontWeight.Regular)
          .fontColor(VividNative.textPrimary)
          .fontFamily('HarmonyOS Sans')
          .width(48)
          .textAlign(TextAlign.End);
      }
      .width('100%')
      .padding({ left: 14, right: 14 });
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 });
  }

  private gradientColors(): Array<[string, number]> {
    if (this.gradientType === 'ramp' && this.gradientRamp.length > 0) {
      const parts: string[] = this.gradientRamp.split('|');
      if (parts.length >= 2) {
        const stops: Array<[string, number]> = [];
        for (let i = 0; i < parts.length; i++) {
          const position: number = i / (parts.length - 1);
          const stop: [string, number] = [parts[i], position];
          stops.push(stop);
        }
        return stops;
      }
    }
    if (this.gradientType === 'custom') {
      return [[this.gradientStart, 0.0], [this.gradientMid, 0.5], [this.gradientEnd, 1.0]];
    }
    if (this.gradientType === 'temperature') return [['#4D7FE8', 0.0], ['#B4C3E8', 0.48], ['#E6B84D', 1.0]];
    // 色调：负值=减绿（偏品红），正值=加绿——左品红、右绿，与实际效果同向。
    if (this.gradientType === 'tint') return [['#D94C73', 0.0], ['#D6DCE8', 0.5], ['#40A96B', 1.0]];
    // 色相：正值向黄绿旋转、负值向品红/青旋转——以 0°（红）为中心，
    // 左端 -180°=青、-90°=品红、中点红、+90°=绿、右端 +180°=青。
    if (this.gradientType === 'hue') return [
      ['#0FA6B4', 0.0], ['#C249B8', 0.25], ['#E8453C', 0.5], ['#2FA84C', 0.75], ['#0FA6B4', 1.0],
    ];
    if (this.gradientType === 'vibrance') return [['#AEB8C7', 0.0], ['#E1C6B6', 0.48], ['#E04D6C', 1.0]];
    if (this.gradientType === 'saturation') return [['#AEB8C7', 0.0], ['#DFC2CC', 0.48], ['#D94C73', 1.0]];
    return [['#CAD3E0', 0.0], ['#6E7CF2', 1.0]];
  }
}
