import { EditSession } from '../edit/models/EditSession';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { VividMaterial, VividSliderMaterial } from './VividMaterial';
import { VividNative, VividNumberField } from './VividNativeTheme';

interface CalibrationGroup {
  title: string;
  hueKey: string;
  satKey: string;
  hueGradient: Array<[string, number]>;
  satGradient: Array<[string, number]>;
}

/** 色准三原色分组：布局与渐变严格按参考截图。 */
const CALIBRATION_GROUPS: CalibrationGroup[] = [
  {
    title: '红原色',
    hueKey: 'calibrationRedHue',
    satKey: 'calibrationRedSaturation',
    hueGradient: [['#D3447B', 0.0], ['#E74C3C', 0.5], ['#B96E3D', 1.0]], // 玫红 → 红 → 棕橙
    satGradient: [['#A9A9A9', 0.0], ['#FF2B2B', 1.0]], // 灰 → 正红
  },
  {
    title: '绿原色',
    hueKey: 'calibrationGreenHue',
    satKey: 'calibrationGreenSaturation',
    hueGradient: [['#A8C93F', 0.0], ['#4FAE5C', 0.5], ['#2FA598', 1.0]], // 黄绿 → 草绿 → 青绿
    satGradient: [['#A9A9A9', 0.0], ['#2EBC4F', 1.0]], // 灰 → 绿
  },
  {
    title: '蓝原色',
    hueKey: 'calibrationBlueHue',
    satKey: 'calibrationBlueSaturation',
    hueGradient: [['#33A9C0', 0.0], ['#3D6FE8', 0.5], ['#8A56E8', 1.0]], // 青绿 → 蓝 → 紫
    satGradient: [['#A9A9A9', 0.0], ['#2E6BE8', 1.0]], // 灰 → 蓝
  },
];

@Component
export struct CalibrationPanel {
  @Consume('editSession') editSession: EditSession;
  @Prop maskContext: boolean = false;
  @Prop embedded: boolean = false;
  @Prop externalScroll: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  // calibrationRevision：外部改动（重置/输入框编辑）后同步滑块。
  // displayRevision：滑块拖动后实时刷新右侧数值框。
  @State private calibrationRevision: number = 0;
  @State private displayRevision: number = 0;

  @Builder
  private CalibrationBody() {
    Column() {
      ForEach(CALIBRATION_GROUPS, (group: CalibrationGroup, index: number) => {
        Column() {
          Stack({ alignContent: Alignment.TopEnd }) {
            Text(group.title)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(VividNative.textPrimary)
              .fontFamily('HarmonyOS Sans')
              .width('100%')
              .textAlign(TextAlign.Center);
            if (index === 0) {
              Button('重置')
                .fontSize(10)
                // 原生次要按钮：填充/文字色/圆角由 ButtonStyleMode + ControlSize 决定。
                .buttonStyle(ButtonStyleMode.NORMAL)
                .controlSize(ControlSize.SMALL)
                .height(24)
                .padding({ left: 10, right: 10 })
                .margin({ top: 5 })
                .onClick(() => { this.resetCalibration(); });
            }
          }
          .width('100%')
          .height(36)
          .padding({ top: 8, bottom: 2 });
          CalibrationSliderRow({
            maskContext: this.maskContext,
            label: '色相',
            adjustKey: group.hueKey,
            gradient: group.hueGradient,
            revision: this.calibrationRevision,
            valueRevision: this.displayRevision,
            onApplied: () => { this.displayRevision++; },
            onEdited: () => { this.calibrationRevision++; },
          });
          CalibrationSliderRow({
            maskContext: this.maskContext,
            label: '饱和度',
            adjustKey: group.satKey,
            gradient: group.satGradient,
            revision: this.calibrationRevision,
            valueRevision: this.displayRevision,
            onApplied: () => { this.displayRevision++; },
            onEdited: () => { this.calibrationRevision++; },
          });
        }
        .width('100%')
        .margin({ top: index > 0 ? 12 : 0 })
        .padding({ left: 8, right: 8, bottom: 8 })
        .borderRadius(VividNative.radiusCard)
        .attributeModifier(VividMaterial.card);
      }, (group: CalibrationGroup) => group.title);
    }
    .width('100%')
    .padding({ left: 16, right: 24, top: 4, bottom: 24 });
  }

  build() {
    if (this.externalScroll) {
      Column() {
        this.CalibrationBody();
      }
      .width('100%')
      .attributeModifier(VividMaterial.card);
    } else {
      Scroll() {
        this.CalibrationBody();
      }
      .layoutWeight(this.embedded ? 0 : 1)
      .height(this.embedded ? 360 : 'auto')
      .width('100%')
      .scrollBar(BarState.Off)
      .margin({ left: this.embedded ? 0 : 10, right: this.embedded ? 0 : 10, top: 6, bottom: 10 })
      .borderRadius(this.embedded ? 0 : 16)
      .border({ width: this.embedded ? 0 : 1, color: VividNative.separator })
      .backgroundColor(Color.Transparent)
      .attributeModifier(VividMaterial.card);
    }
  }
  /** 重置六个校准参数并同步所有滑块与数值框。 */
  private resetCalibration(): void {
    const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
    if (!adjustments) return;
    this.editSession.pushUndo();
    adjustments.setValue('calibrationRedHue', 0);
    adjustments.setValue('calibrationRedSaturation', 0);
    adjustments.setValue('calibrationGreenHue', 0);
    adjustments.setValue('calibrationGreenSaturation', 0);
    adjustments.setValue('calibrationBlueHue', 0);
    adjustments.setValue('calibrationBlueSaturation', 0);
    this.calibrationRevision++;
    this.displayRevision++;
    this.editSession.requestProcessing();
    ImageProcessor.process(this.editSession);
  }
}

/** 数值输入框：独立组件，滑块拖动时经 displayRevision 实时同步显示，
 * 输入时回写会话并通知滑块同步，互不干扰。 */
@Component
struct CalibrationValueBox {
  @Consume('editSession') editSession: EditSession;
  @Prop maskContext: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @Prop label: string = '';
  @Prop adjustKey: string = '';
  @Prop @Watch('syncText') revision: number = 0;
  onEdited: () => void = () => {};
  @State private inputText: string = '';
  private processTimer: number = -1;
  private processPending: boolean = false;

  aboutToAppear(): void {
    this.syncText();
  }

  private syncText(): void {
    const value = this.editSession.adjustmentsForContext(this.maskContext)?.getValue(this.adjustKey) ?? 0;
    this.inputText = value.toFixed(2);
  }

  build() {
    TextInput({ text: this.inputText })
      // 加宽并收窄内边距：负值（如 -0.50）居中对齐时右侧数字不再被裁切。
      .width(64)
      .height(30)
      // 滑轨终点与输入框之间保留固定水平空隙，滑块到最右端也不会相碰。
      .margin({ left: 12 })
      .fontSize(11)
      .padding({ left: 4, right: 4 })
      // InputType.Number is integer-only on HarmonyOS and silently removes
      // the decimal point from values such as 0.00. Use the normal editor so
      // the displayed calibration value remains complete and editable.
      .type(InputType.Normal)
      // 调色面板数值改为纯数字：去掉原生数值框的填充与描边。
      .attributeModifier(VividNumberField.plain)
      .textAlign(TextAlign.Center)
      .onChange((value: string) => {
        this.inputText = value;
        const parsed = parseFloat(value);
        if (isNaN(parsed)) return;
        const clamped = Math.max(-1, Math.min(1, parsed));
        const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
        if (!adjustments) return;
        adjustments.setValue(this.adjustKey, clamped);
        this.editSession.requestProcessing();
        this.onEdited();
        if (this.processPending) return;
        this.processPending = true;
        this.processTimer = setTimeout(() => {
          this.processPending = false;
          this.processTimer = -1;
          ImageProcessor.process(this.editSession);
        }, 33);
      });
  }
}

/** 单行参数：渐变滑轨 + 数值输入。
 * 拖动期间滑块只写会话值、不触发本行重渲染（此前重建导致拖动偏移/跳最大）；
 * 数值输入框使用独立文本状态，仅外部重置（revision）时与滑块一并同步。 */
@Component
struct CalibrationSliderRow {
  @Consume('editSession') editSession: EditSession;
  @Prop maskContext: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @Prop label: string = '';
  @Prop adjustKey: string = '';
  @Prop gradient: Array<[string, number]> = [];
  // 外部重置（含面板重置按钮/输入框编辑）后通过 revision 触发重新同步数值。
  @Prop @Watch('syncFromSession') revision: number = 0;
  // 滑块拖动只刷新同一行里的数值框，不重建整个校准面板。
  @Prop @Watch('syncInputRevision') valueRevision: number = 0;
  // 拖动后通知面板刷新右侧数值框。
  onApplied: () => void = () => {};
  onEdited: () => void = () => {};
  @State private currentValue: number = 0;
  private processTimer: number = -1;
  private processPending: boolean = false;

  aboutToAppear(): void {
    this.syncFromSession();
  }

  private syncFromSession(): void {
    this.currentValue = this.readValue();
  }

  private syncInputRevision(): void {
    // The value box owns its text state, so the revision is intentionally
    // consumed by the child rather than rebuilding this slider row.
  }

  build() {
    Row() {
      Text(this.label)
        .fontSize(12)
        .fontColor(VividNative.textPrimary)
        .fontFamily('HarmonyOS Sans')
        .width(48);

      Stack() {
        Row()
          .width('100%')
          .height(6)
          .borderRadius(3)
          .linearGradient({ angle: 90, colors: this.gradient });
        Slider({
          style: SliderStyle.OutSet,
          min: -1,
          max: 1,
          step: 0.01,
          value: this.currentValue,
        })
          .width('100%')
          // 轨道全透明：只显示渐变彩条，与白色面板底色融为一体。
          // 轨道全透明：只显示渐变色条，彩色滑杆不退回无色。
          .trackColor(Color.Transparent)
          .selectedColor(Color.Transparent)
          // 滑块用系统滑块前景色 + 系统控件常态色描边。
          .blockColor(VividNative.sliderBlock)
          .blockBorderColor(VividNative.componentNormal)
          .blockBorderWidth(1)
          .blockSize({ width: 16, height: 16 })
          .enableHapticFeedback(true)
          .attributeModifier(new VividSliderMaterial())
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) this.editSession.pushUndo();
          })
          .onChange((val: number) => {
            // 只写会话值：不更新本地状态，避免拖动中重建滑块导致偏移。
            this.apply(val);
          });
      }
      .layoutWeight(1)
      .height(28);

      CalibrationValueBox({
        maskContext: this.maskContext,
        adjustKey: this.adjustKey,
        revision: this.valueRevision,
        onEdited: this.onEdited,
      });
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 });
  }

  private readValue(): number {
    return this.editSession.adjustmentsForContext(this.maskContext)?.getValue(this.adjustKey) ?? 0;
  }

  private apply(value: number): void {
    const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
    if (!adjustments) return;
    adjustments.setValue(this.adjustKey, value);
    this.editSession.requestProcessing();
    this.onApplied();
    if (this.processPending) return;
    this.processPending = true;
    this.processTimer = setTimeout(() => {
      this.processPending = false;
      this.processTimer = -1;
      ImageProcessor.process(this.editSession);
    }, 33);
  }
}
