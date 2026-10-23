import { EditSession } from '../edit/models/EditSession';
import { MaskComponent, MaskComponentType } from '../edit/models/Mask';
import { ToolType } from '../edit/models/ToolType';
import { VividNative } from './VividNativeTheme';

/**
 * 画笔蒙版的竖排工具列：接在预览卡片左侧的删除/反相胶囊上方。
 * 画笔（带 − 角标）/ 橡皮擦 / 大小 / 羽化 / 流畅度；点大小、羽化、流畅度
 * 会在工具列右侧展开一条滑槽调数值。
 */
@Component
export struct MaskBrushTools {
  @Consume('editSession') editSession: EditSession;
  @StorageProp('vividNightMode') private night: boolean = false;
  @StorageProp('maskRevision') private revision: number = 0;
  /** '' | 'size' | 'feather' | 'flow' */
  @State private activeParam: string = '';

  private brush(): boolean {
    return this.editSession.activeMaskComponent?.type === MaskComponentType.BRUSH;
  }

  private iconColor(): string {
    return this.night ? '#F4F7FC' : '#1B2536';
  }

  private frameColor(): string {
    return this.night ? 'rgba(255,255,255,0.10)' : 'rgba(20,30,50,0.08)';
  }

  private fillColor(): string {
    return this.night ? 'rgba(26,29,36,0.96)' : 'rgba(252,253,255,0.97)';
  }

  // editSession.brushSize 等字段不是可观察的，直接读它们画数字会停在首次渲染的值（滑到
  // 100 而按钮上还是 4），所以这里用 @State 镜像一份，改参数时同步更新。
  @State private sizePct: number = 30;
  @State private featherPct: number = 50;
  @State private flowPct: number = 100;

  /** 正在拖滑杆改大小：只有这一刻才隐藏按钮列与蒙版覆盖。 */
  @State private sizing: boolean = false;

  aboutToAppear(): void {
    this.syncParams();
  }

  /** 把工具栏在预览里的矩形发给画布，起笔时好忽略按在控件上的那一笔。 */
  private publishHitRect(area: Area): void {
    const x = Number(area.position.x);
    const y = Number(area.position.y);
    const w = Number(area.width);
    const h = Number(area.height);
    if (!Number.isFinite(x) || !Number.isFinite(y) || w <= 0 || h <= 0) return;
    AppStorage.setOrCreate('maskUiRectBrush', `${x},${y},${w},${h}`);
  }

  private syncParams(): void {
    this.sizePct = this.sizeValue();
    this.featherPct = this.featherValue();
    this.flowPct = this.flowValue();
  }

  /** 0..100 的大小。小值细调、大值才明显变粗：半径 = 0.5% + (v/100)^2 * 30%。 */
  private sizeValue(): number {
    const raw = (this.editSession.brushSize - 0.005) / 0.3;
    return Math.round(Math.sqrt(Math.max(0, Math.min(1, raw))) * 100);
  }

  private featherValue(): number {
    return Math.round((1 - this.editSession.brushHardness) * 100);
  }

  private flowValue(): number {
    return Math.round(this.editSession.brushFlow * 100);
  }

  private setParam(value: number): void {
    const session = this.editSession;
    const pct = Math.round(value);
    // 拖动中画布上只显示这个数值。
    AppStorage.setOrCreate('maskBrushAdjustValue', pct);
    AppStorage.setOrCreate('maskBrushAdjustKind', this.activeParam);
    if (this.activeParam === 'size') {
      this.sizePct = pct;
      session.brushSize = Math.max(0.005, Math.min(0.35, 0.005 + Math.pow(pct / 100, 2) * 0.3));
    } else if (this.activeParam === 'feather') {
      this.featherPct = pct;
      session.brushHardness = Math.max(0, Math.min(1, 1 - pct / 100));
    } else if (this.activeParam === 'flow') {
      this.flowPct = pct;
      session.brushFlow = Math.max(0.05, Math.min(1, pct / 100));
    }
  }

  private currentValue(): number {
    if (this.activeParam === 'size') return this.sizePct;
    if (this.activeParam === 'feather') return this.featherPct;
    return this.flowPct;
  }

  private paramLabel(): string {
    if (this.activeParam === 'size') return '画笔大小';
    if (this.activeParam === 'feather') return '羽化';
    return '流畅度';
  }

  @Builder
  ToolButton(id: string, value: number, showBadge: boolean) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        if (id === 'brush') {
          // 画笔：一笔杆 + 斜笔刷头
          Stack() {
            Row().width(2).height(13).borderRadius(1).backgroundColor(this.iconColor())
              .rotate({ angle: 42 }).offset({ x: 1, y: -2 });
            Row().width(7).height(5).borderRadius(2).backgroundColor(this.iconColor())
              .rotate({ angle: 42 }).offset({ x: -3, y: 6 });
          }
          .width(20)
          .height(20);
        } else if (id === 'eraser') {
          Stack() {
            Row().width(14).height(8).borderRadius(2)
              .border({ width: 1.6, color: this.iconColor() }).rotate({ angle: -30 });
            Row().width(10).height(1.6).backgroundColor(this.iconColor()).rotate({ angle: -30 })
              .offset({ y: 5 });
          }
          .width(20)
          .height(20);
        } else if (id === 'feather') {
          Stack() {
            Row().width(13).height(13).borderRadius(7)
              .border({ width: 1.4, color: this.iconColor() });
            Row().width(7).height(7).borderRadius(4)
              .backgroundColor(this.iconColor()).opacity(0.35);
          }
          .width(20)
          .height(20);
        } else if (id === 'flow') {
          Stack() {
            Row().width(15).height(1.6).backgroundColor(this.iconColor()).offset({ y: -4 });
            Row().width(15).height(1.6).backgroundColor(this.iconColor());
            Row().width(15).height(1.6).backgroundColor(this.iconColor()).offset({ y: 4 });
          }
          .width(20)
          .height(20);
        } else {
          Text(`${value}`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.iconColor());
        }
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center);

      if (showBadge) {
        Row() {
          Text('−').fontSize(9).fontColor('#FFFFFF');
        }
        .width(13)
        .height(13)
        .borderRadius(7)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(24,32,46,0.9)')
        .margin({ right: 2, bottom: 2 });
      }
    }
    .width(44)
    .height(44);
  }

  build() {
    if (!this.brush()) {
      // 不是画笔分量就不出现，避免占着预览卡片的左侧。
      Column() {}.width(0).height(0);
    } else {
      Row({ space: 6 }) {
        // 调整大小时只留滑杆：左侧按钮列在这期间隐藏，避免遮挡画面预览。
        if (!this.sizing) {
        Column({ space: 6 }) {
          // 画笔：右下角 − 角标表示当前是「减去」用法（画笔本身始终是加/减由模式决定）。
          Button() { this.ToolButton('brush', 0, false) }
            .padding(0)
            .type(ButtonType.Circle)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .backgroundColor(this.editSession.maskBrushMode === 0 ? 'rgba(49,108,244,0.16)' : this.fillColor())
            .border({ width: 1, color: this.editSession.maskBrushMode === 0 ? '#316CF4' : this.frameColor() })
            .accessibilityText('画笔')
            .onClick(() => {
              this.editSession.maskBrushMode = 0;
              // 无论当前选的是哪一层/哪个子蒙版，点画笔都切到该层的画笔分量，保证能落笔。
              const layer = this.editSession.activeMaskLayer;
              const brush = layer !== null ? layer.components.find((item: MaskComponent): boolean =>
                item.type === MaskComponentType.BRUSH) : undefined;
              // 已经选中的就是这个画笔分量时不要再选一次：selectMaskComponent 会
              // 触发一次蒙版版本递增 + 覆盖层重算，点一下画笔就觉得"卡一下"。
              const switchStart = Date.now();
              if (brush !== undefined && this.editSession.selectedMaskComponentId !== brush.id) {
                this.editSession.selectMaskComponent(brush.id);
              }
              const afterSelect = Date.now();
              if (this.editSession.activeTool !== ToolType.BRUSH_MASK) {
                this.editSession.setActiveTool(ToolType.BRUSH_MASK);
              }
              console.info(`VIVID_PERF event=brush_switch select=${afterSelect - switchStart} ` +
                `tool=${Date.now() - afterSelect} strokes=` +
                `${brush !== undefined && brush.brushData !== null ? brush.brushData.strokes.length : -1}`);
              this.activeParam = '';
            });

          Button() { this.ToolButton('eraser', 0, false) }
            .padding(0)
            .type(ButtonType.Circle)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .backgroundColor(this.editSession.maskBrushMode === 1 ? 'rgba(49,108,244,0.16)' : this.fillColor())
            .border({ width: 1, color: this.editSession.maskBrushMode === 1 ? '#316CF4' : this.frameColor() })
            .accessibilityText('橡皮擦')
            .onClick(() => {
              this.editSession.maskBrushMode = 1;
              this.editSession.setActiveTool(ToolType.BRUSH_MASK);
              this.activeParam = '';
            });

          Button() { this.ToolButton('size', this.sizePct, false) }
            .padding(0)
            .type(ButtonType.Circle)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .backgroundColor(this.activeParam === 'size' ? 'rgba(49,108,244,0.16)' : this.fillColor())
            .border({ width: 1, color: this.activeParam === 'size' ? '#316CF4' : this.frameColor() })
            .accessibilityText('画笔大小')
            .onClick(() => {
              this.syncParams();
              this.activeParam = this.activeParam === 'size' ? '' : 'size';
              // 只有真正拖动滑杆时才进入调整态（暂停绘图 / 隐藏覆盖层 / 隐藏按钮）。
              AppStorage.setOrCreate('maskBrushSizing', false);
            });

          Button() { this.ToolButton('feather', this.featherPct, false) }
            .padding(0)
            .type(ButtonType.Circle)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .backgroundColor(this.activeParam === 'feather' ? 'rgba(49,108,244,0.16)' : this.fillColor())
            .border({ width: 1, color: this.activeParam === 'feather' ? '#316CF4' : this.frameColor() })
            .accessibilityText('羽化')
            .onClick(() => {
              this.syncParams();
              this.activeParam = this.activeParam === 'feather' ? '' : 'feather';
            });

          Button() { this.ToolButton('flow', this.flowPct, false) }
            .padding(0)
            .type(ButtonType.Circle)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .backgroundColor(this.activeParam === 'flow' ? 'rgba(49,108,244,0.16)' : this.fillColor())
            .border({ width: 1, color: this.activeParam === 'flow' ? '#316CF4' : this.frameColor() })
            .accessibilityText('流畅度')
            .onClick(() => {
              this.syncParams();
              this.activeParam = this.activeParam === 'flow' ? '' : 'flow';
            });
        }
        .padding(5)
        .borderRadius(26)
        .backgroundColor(this.fillColor())
        .border({ width: 1, color: this.frameColor() })
        .shadow({ radius: 12, color: 'rgba(20,30,50,0.16)', offsetY: 3 })
        // 工具列自己消耗触摸，不让点按透到下面的画布去（否则点画笔会同时落一笔）。
        .hitTestBehavior(HitTestMode.Default);
        }

        // 选中某个参数时，右侧滑出滑槽。
        if (this.activeParam.length > 0) {
          Column({ space: 4 }) {
            if (!this.sizing) {
            Row() {
              Text(this.paramLabel())
                .fontSize(10)
                .fontColor(VividNative.textSecondary);
              Blank();
              Text(`${this.currentValue()}`)
                .fontSize(10)
                .fontWeight(FontWeight.Medium)
                .fontColor('#316CF4');
            }
            .width('100%');
            }

            Column() {
            Slider({ value: this.currentValue(), min: 0, max: 100, style: SliderStyle.OutSet })
              .onChange((value: number) => {
                this.setParam(value);
                // 滑杆不会自己刷新画布，每次变化推一个计数器过去重画笔头圆。
                AppStorage.setOrCreate('maskBrushSizeTick', Date.now());
              })
              .width(120)
              .trackThickness(3)
              .blockSize({ width: 14, height: 14 })
              .selectedColor('#316CF4')

          }
          .parallelGesture(PanGesture({ distance: 4 })
            .onActionStart(() => {
              // 大小与羽化走同一套：拖动滑杆才隐藏界面，并在画面中心预览笔头。
              const adjustable = this.activeParam === 'size' || this.activeParam === 'feather';
              this.sizing = adjustable;
              AppStorage.setOrCreate('maskBrushSizing', adjustable);
              AppStorage.setOrCreate('maskBrushSizeTick', Date.now());
            })
            .onActionEnd(() => {
              this.sizing = false;
              AppStorage.setOrCreate('maskBrushSizing', false);
              AppStorage.setOrCreate('maskBrushSizeTick', Date.now());
              this.activeParam = '';
            }))
          .width(140)
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .borderRadius(14)
          .backgroundColor(this.fillColor())
          .border({ width: 1, color: this.frameColor() })
          .shadow({ radius: 12, color: 'rgba(20,30,50,0.16)', offsetY: 3 })
          .hitTestBehavior(HitTestMode.Default);
        }
        }
      }
      .alignItems(VerticalAlign.Center)
      .onAreaChange((_old: Area, area: Area) => { this.publishHitRect(area); });
    }
  }
}
