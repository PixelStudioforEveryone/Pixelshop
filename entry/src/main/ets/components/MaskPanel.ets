import { EditSession } from '../edit/models/EditSession';
import { MaskBlendMode, MaskComponent, MaskComponentType, MaskLayer } from '../edit/models/Mask';
import { ToolType } from '../edit/models/ToolType';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { SliderControl } from './SliderControl';
import { AdjustmentPanel } from './AdjustmentPanel';
import { AiMaskKind } from '../edit/models/AiMaskModels';
import {
  AiSegmentationService, bitmapCoverage, aiMaskErrorMessage, aiMaskOrigin,
} from '../edit/engine/AiSegmentationService';
import { RangeMaskService } from '../edit/engine/RangeMaskService';
import { RangeMaskProxy, averageSelectedColor } from '../edit/engine/RangeMaskCore';
import { RangeMaskData } from '../edit/models/Mask';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { VividNative, VividNumberField } from './VividNativeTheme';

/** Mobile bottom-drawer mask editor. A mask layer owns adjustments; rows
 * below it only edit selection geometry and composition. */
@Component
export struct MaskPanel {
  @Consume('editSession') editSession: EditSession;
  onContentHeightChange: (height: number) => void = () => {};
  @State private renamingMaskId: string = '';
  @State private renameText: string = '';
  /** Non-empty while a local model is running; blocks a second request. */
  @State private aiBusyKind: number = -1;
  /** Honest outcome text: success with coverage, or the concrete failure. */
  @State private aiStatus: string = '';
  /** Non-zero while the source tonal proxy is being read; blocks a second run. */
  @State private rangeBusy: boolean = false;
  @State private rangeStatus: string = '';
  /** 与桌面面板共用同一叠加开关（AppStorage 'desktopMaskOverlay'）。 */
  @StorageLink('desktopMaskOverlay') private showCoverage: boolean = true;
  /** Last captured source proxy, so a slider drag never re-reads the image. */
  private rangeProxy: RangeMaskProxy | null = null;
  // Structural mask operations publish this narrow revision so the panel's
  // ForEach list is rebuilt immediately while it remains open.
  @StorageProp('maskRevision') private maskRevision: number = 0;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @Prop showHeader: boolean = true;
  @Prop externalScroll: boolean = false;
  @Prop desktopAccordion: boolean = false;
  private processTimer: number = -1;
  private processPending: boolean = false;

  build() {
    Column() {
      if (this.showHeader) {
        Row() {
          Text('蒙版图层').fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor(VividNative.textPrimary);
          Blank();
        }
        .width('100%').height(30).padding({ left: 12, right: 12 });
      }

      if (this.externalScroll) {
        this.MaskContent();
      } else {
        Scroll() {
          this.MaskContent();
        }
        .layoutWeight(1).scrollBar(BarState.On).edgeEffect(EdgeEffect.None).width('100%');
      }

      Button('完成蒙版').fontSize(12).type(ButtonType.Capsule).height(34)
        .buttonStyle(ButtonStyleMode.EMPHASIZED).margin({ top: 5, bottom: 5 })
        .onClick(() => {
          this.editSession.adjustmentScope = 1;
          this.editSession.setActiveTool(ToolType.ADJUST);
          this.editSession.bumpProcessing();
          ImageProcessor.process(this.editSession);
          this.editSession.adjustmentScope = 0;
          AppStorage.setOrCreate('editorPanelRequest', -2);
        });
    }
    .id('mask-panel-' + this.maskRevision.toString())
    .width('100%')
    .height(this.externalScroll ? 'auto' : '100%')
    .backgroundColor(Color.Transparent);
  }

  @Builder
  private MaskContent() {
    Column() {
      Row() {
        this.NewMaskButton('画笔', MaskComponentType.BRUSH);
        this.NewMaskButton('线性渐变', MaskComponentType.LINEAR_GRADIENT);
        this.NewMaskButton('径向渐变', MaskComponentType.RADIAL_GRADIENT);
      }
      .width('100%').height(36).justifyContent(FlexAlign.SpaceEvenly).padding({ left: 6, right: 6, bottom: 6 });

      // 与桌面面板同款的"显示叠加 / 自动蒙版"行：开关共用同一 AppStorage 键，
      // 自动蒙版只在选中的是画笔分量时出现。
      Row() {
        Checkbox({ name: 'mask-overlay-phone' }).select(this.showCoverage).width(14).height(14)
          .selectedColor(VividNative.emphasize)
          .onChange((checked: boolean) => { this.showCoverage = checked; });
        Text('显示叠加').fontSize(11).fontColor(VividNative.textSecondary);
        Blank();
        if (this.autoMaskAvailable()) {
          Checkbox({ name: 'mask-auto-brush-phone' }).select(this.editSession.brushAutoMask)
            .width(14).height(14).selectedColor(VividNative.emphasize)
            .onChange((checked: boolean) => {
              this.editSession.pushUndo();
              this.editSession.brushAutoMask = checked;
              // 开关切换同步到当前选中的画笔分量：已刷的笔画立即生效/失效，
              // 而不是只有之后再刷的笔画才带门限。
              this.applyAutoMaskToSelected(checked);
            });
          Text('自动蒙版').fontSize(11).fontColor(VividNative.textSecondary);
        }
      }
      .width('100%').height(30).padding({ left: 12, right: 12 });

      // Local, offline subject / sky selection. These build a real mask
      // component that supports add/subtract/intersect like any other, so the
      // network only proposes a starting selection and the user stays in charge.
      Row() {
        this.AiSelectionButton('主体', AiMaskKind.SUBJECT);
        this.AiSelectionButton('天空', AiMaskKind.SKY);
      }
      .width('100%').height(32).justifyContent(FlexAlign.SpaceEvenly).padding({ left: 6, right: 6, bottom: 6 });

      // Range selection: instead of drawing, narrow the selection by where a
      // pixel sits in the image's tonal and chromatic distribution.
      Row() {
        Button(this.rangeBusy ? '范围…' : '范围')
          .fontSize(11).type(ButtonType.Capsule).height(28).layoutWeight(1).margin({ left: 3, right: 3 })
          .enabled(!this.rangeBusy)
          .buttonStyle(ButtonStyleMode.EMPHASIZED).controlSize(ControlSize.SMALL)
          .onClick(() => { this.createRangeMask(); });
        Button('取色范围')
          .fontSize(11).type(ButtonType.Capsule).height(28).layoutWeight(1).margin({ left: 3, right: 3 })
          .enabled(!this.rangeBusy && this.editSession.activeMaskComponent?.type === MaskComponentType.RANGE)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => { this.pickRangeColor(); });
      }
      .width('100%').height(32).justifyContent(FlexAlign.SpaceEvenly).padding({ left: 6, right: 6, bottom: 6 });

      if (this.aiBusyKind >= 0 || this.aiStatus.length > 0 || this.rangeStatus.length > 0) {
        Row() {
          Text(this.aiBusyKind >= 0 ? '正在本地识别…' :
            (this.rangeStatus.length > 0 ? this.rangeStatus : this.aiStatus)).fontSize(10)
            .fontColor(VividNative.textSecondary).layoutWeight(1);
        }
        .width('100%').padding({ left: 12, right: 12, bottom: 6 });
      }

      ForEach(this.editSession.activeLayer?.maskLayers ?? [], (maskLayer: MaskLayer) => {
        this.MaskLayerCard(maskLayer);
      }, (maskLayer: MaskLayer) => maskLayer.id);

      if (this.editSession.activeMaskLayer) {
        SliderControl({ label: '蒙版强度', value: this.editSession.activeMaskLayer.opacity,
          min: 0, max: 1, step: 0.01, formatValue: (v: number) => Math.round(v * 100) + '%',
          onBegin: () => { this.editSession.pushUndo(); },
          onChange: (v: number) => {
            const mask = this.editSession.activeMaskLayer;
            if (!mask) return;
            mask.opacity = v; mask.touch();
            this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
            this.scheduleProcess();
          },
        });
        Column() {
          Row() {
            Text('向当前蒙版添加选区').fontSize(11)
              .fontColor(VividNative.textSecondary);
            Blank();
          }.width('100%');

          Row() {
            this.ComponentButton('+画笔', MaskComponentType.BRUSH, MaskBlendMode.ADD);
            this.ComponentButton('+线性', MaskComponentType.LINEAR_GRADIENT, MaskBlendMode.ADD);
            this.ComponentButton('+径向', MaskComponentType.RADIAL_GRADIENT, MaskBlendMode.ADD);
            this.ComponentButton('-画笔', MaskComponentType.BRUSH, MaskBlendMode.SUBTRACT);
            this.ComponentButton('-线性', MaskComponentType.LINEAR_GRADIENT, MaskBlendMode.SUBTRACT);
            this.ComponentButton('-径向', MaskComponentType.RADIAL_GRADIENT, MaskBlendMode.SUBTRACT);
          }
          .width('100%').margin({ top: 2 });
          Row() {
            this.ComponentButton('∩画笔', MaskComponentType.BRUSH, MaskBlendMode.INTERSECT);
            this.ComponentButton('∩线性', MaskComponentType.LINEAR_GRADIENT, MaskBlendMode.INTERSECT);
            this.ComponentButton('∩径向', MaskComponentType.RADIAL_GRADIENT, MaskBlendMode.INTERSECT);
          }.width('100%').margin({ top: 4 });
          // AI selections compose with the manual ones through the same
          // add/subtract/intersect operations, so a miss can be trimmed here
          // instead of forcing the user to start over.
          Row() {
            this.AiComponentButton('-主体', AiMaskKind.SUBJECT, MaskBlendMode.SUBTRACT);
            this.AiComponentButton('∩主体', AiMaskKind.SUBJECT, MaskBlendMode.INTERSECT);
            this.AiComponentButton('-天空', AiMaskKind.SKY, MaskBlendMode.SUBTRACT);
            this.AiComponentButton('∩天空', AiMaskKind.SKY, MaskBlendMode.INTERSECT);
          }.width('100%').margin({ top: 4 });
        }
        .width('100%').padding({ left: 10, right: 8, top: 6, bottom: 4 });

        if (this.editSession.activeMaskComponent) this.ComponentSettings(this.editSession.activeMaskComponent);

        Column() {
          AdjustmentPanel({
            resetRevision: 0,
            embedded: true,
            externalScroll: this.externalScroll,
            desktopAccordion: this.desktopAccordion
          });
        }
        .width('100%')
        .margin({ top: 6 });
      }
    }
    .width('100%')
    .padding({ bottom: (this.editSession.activeLayer?.maskLayers.length ?? 0) > 0 ? 12 : 0 })
    .onAreaChange((_: Area, area: Area) => this.onContentHeightChange(Number(area.height)));
  }
  @Builder
  NewMaskButton(label: string, type: MaskComponentType) {
      Button(label).fontSize(11).type(ButtonType.Capsule).height(28)
      .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
        .onClick(() => {
        // The top-level tools create independent mask layers. Composition
        // inside an existing layer is exposed explicitly by the +/− buttons
        // below, so a linear mask followed by a brush always gets its own
        // visible brush layer.
        this.editSession.createMaskLayer(type);
        ImageProcessor.process(this.editSession);
      });
  }

  @Builder
  MaskLayerCard(maskLayer: MaskLayer) {
    Column() {
      Row() {
        this.MaskPill(maskLayer.visible ? '显示' : '隐藏', maskLayer.visible, () => {
          const value = !maskLayer.visible;
          this.editSession.pushUndo(); maskLayer.visible = value; maskLayer.touch();
          this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
          ImageProcessor.process(this.editSession);
        });
        if (this.renamingMaskId === maskLayer.id) {
          TextInput({ text: this.renameText, placeholder: maskLayer.name })
            .fontSize(12).height(26).layoutWeight(1)
            .attributeModifier(VividNumberField.field)
            .onChange((value: string) => { this.renameText = value; });
          Button('确定').fontSize(9).type(ButtonType.Capsule).height(24)
            .padding({ left: 7, right: 7 }).buttonStyle(ButtonStyleMode.EMPHASIZED).controlSize(ControlSize.SMALL)
            .onClick(() => {
              this.editSession.renameMaskLayer(maskLayer.id, this.renameText);
              this.renamingMaskId = '';
              this.renameText = '';
            });
        } else {
          Text(maskLayer.name).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(VividNative.textPrimary).layoutWeight(1)
            .margin({ left: 8 });
          Button('改名').fontSize(9).type(ButtonType.Capsule).height(24).padding({ left: 7, right: 7 })
            .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .onClick(() => { this.renamingMaskId = maskLayer.id; this.renameText = maskLayer.name; });
        }
        Button('复制').fontSize(9).type(ButtonType.Capsule).height(24).padding({ left: 7, right: 7 })
          .buttonStyle(ButtonStyleMode.EMPHASIZED).controlSize(ControlSize.SMALL)
          .onClick(() => { this.editSession.duplicateMaskLayer(maskLayer.id); ImageProcessor.process(this.editSession); });
        Button('删除').fontSize(9).type(ButtonType.Capsule).height(24).width(40)
          .padding({ left: 0, right: 0 })
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => { this.editSession.deleteMaskLayer(maskLayer.id); ImageProcessor.process(this.editSession); });
      }.width('100%');

      Row() {
        this.MaskPill(maskLayer.enabled ? '启用' : '停用', maskLayer.enabled, () => {
          this.editSession.pushUndo(); maskLayer.enabled = !maskLayer.enabled; maskLayer.touch();
          this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
          ImageProcessor.process(this.editSession);
        });
        this.MaskPill('反转组', maskLayer.inverted, () => {
          this.editSession.pushUndo(); maskLayer.inverted = !maskLayer.inverted; maskLayer.touch();
          this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
          this.editSession.bumpProcessing();
          ImageProcessor.process(this.editSession);
        });
        Blank();
        Text(maskLayer.components.length + ' 个选区').fontSize(10)
          .fontColor(VividNative.textSecondary);
      }.width('100%').padding({ left: 28, right: 8, top: 2, bottom: 2 });

      ForEach(maskLayer.components, (component: MaskComponent) => {
        Row() {
          Text(component.blendMode === MaskBlendMode.ADD ? '添加' :
            (component.blendMode === MaskBlendMode.SUBTRACT ? '减去' : '相交'))
            .fontSize(10).fontColor(VividNative.textSecondary).width(34);
          Text(this.componentLabel(component)).fontSize(11)
            .fontColor(component.id === this.editSession.selectedMaskComponentId ? VividNative.textPrimary : VividNative.textSecondary)
            .fontWeight(component.id === this.editSession.selectedMaskComponentId ? FontWeight.Medium : FontWeight.Regular)
            .layoutWeight(1).onClick(() => this.editSession.selectMaskComponent(component.id));
          this.MaskPill(component.enabled ? '启用' : '停用', component.enabled, () => {
            this.editSession.pushUndo(); component.enabled = !component.enabled;
            this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
            ImageProcessor.process(this.editSession);
          });
          this.MaskPill(component.visible ? '显示' : '隐藏', component.visible, () => {
            this.editSession.pushUndo(); component.visible = !component.visible;
            this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
            ImageProcessor.process(this.editSession);
          });
          Button('删除').fontSize(9).type(ButtonType.Capsule).height(22).width(40)
            .padding({ left: 0, right: 0 })
            .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .onClick(() => { this.editSession.deleteMaskComponent(component.id); ImageProcessor.process(this.editSession); });
        }.width('100%').padding({ left: 28, right: 2, top: 3, bottom: 3 });
      }, (component: MaskComponent) => component.id);
    }
    .width('calc(100% - 16vp)').padding({ left: 10, right: 8, top: 7, bottom: 6 })
    .margin({ left: 8, right: 8, bottom: 6 })
    .backgroundColor(Color.Transparent)
    .border({ width: 1, color: maskLayer.id === this.editSession.selectedMaskLayerId ? VividNative.separator : Color.Transparent })
    .borderRadius(VividNative.radiusClicked)
    .onClick(() => this.editSession.selectMaskLayer(maskLayer.id));
  }

  @Builder
  ComponentButton(label: string, type: MaskComponentType, mode: MaskBlendMode) {
    Button(label).fontSize(9).type(ButtonType.Capsule).height(26)
      .layoutWeight(1).padding({ left: 0, right: 0 }).margin({ left: 2, right: 2 })
      .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
      .onClick(() => { this.editSession.addMaskComponent(type, mode); ImageProcessor.process(this.editSession); });
  }

  @Builder
  AiSelectionButton(label: string, kind: AiMaskKind) {
    Button(this.aiBusyKind === kind as number ? label + '…' : label)
      .fontSize(11).type(ButtonType.Capsule).height(28).layoutWeight(1)
      .margin({ left: 3, right: 3 })
      .enabled(this.aiBusyKind < 0)
      .buttonStyle(ButtonStyleMode.EMPHASIZED).controlSize(ControlSize.SMALL)
      .onClick(() => { this.runAiSelection(kind, true, MaskBlendMode.ADD); });
  }

  @Builder
  AiComponentButton(label: string, kind: AiMaskKind, mode: MaskBlendMode) {
    Button(label).fontSize(9).type(ButtonType.Capsule).height(26)
      .layoutWeight(1).padding({ left: 0, right: 0 }).margin({ left: 2, right: 2 })
      .enabled(this.aiBusyKind < 0)
      .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
      .onClick(() => { this.runAiSelection(kind, false, mode); });
  }

  /**
   * Run one local segmentation and turn it into a real mask component.
   *
   * The component is created only after inference succeeds, so a missing or
   * corrupt model can never leave an empty mask layer behind, and a result that
   * arrives for a photo the user already left is dropped. `aiBusyKind` is
   * cleared in `finally` on every path, so the buttons can never stay disabled.
   */
  private async runAiSelection(kind: AiMaskKind, asNewLayer: boolean,
    mode: MaskBlendMode): Promise<void> {
    if (this.aiBusyKind >= 0) return;
    const session = this.editSession;
    const source = session.sourcePixelMap;
    // The mask lives in source-normalised space, so a lower-resolution preview
    // is a valid, correctly aligned input; only grading is excluded from it.
    if (!source) {
      this.aiStatus = '请先打开一张照片';
      return;
    }
    const type = kind === AiMaskKind.SKY ? MaskComponentType.SKY : MaskComponentType.SUBJECT;
    this.aiBusyKind = kind as number;
    this.aiStatus = '';
    const generation = AiSegmentationService.currentGeneration();
    // 发起识别时的目标在 await 之前固定：期间切换图层/蒙版不能让结果改落点。
    const targetLayerId = session.activeLayer?.id ?? '';
    const targetMaskLayerId = session.activeMaskLayer?.id ?? '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const raster = await AiSegmentationService.segmentPixelMap(
        context.resourceManager, kind, source);
      if (generation !== AiSegmentationService.currentGeneration()) return;
      if (targetLayerId.length === 0) {
        this.aiStatus = '识别结果已失效（目标图层已不存在），请重试';
        return;
      }
      let componentId = '';
      if (asNewLayer || targetMaskLayerId.length === 0) {
        const maskLayer = session.createMaskLayerOn(targetLayerId, type);
        if (!maskLayer) {
          this.aiStatus = '识别结果已失效（目标图层已不存在），请重试';
          return;
        }
        componentId = maskLayer.components.length > 0 ? maskLayer.components[0].id : '';
      } else {
        const component = session.addMaskComponentTo(targetLayerId, targetMaskLayerId, type, mode);
        if (!component) {
          this.aiStatus = '识别结果已失效（目标蒙版已不存在），请重试';
          return;
        }
        componentId = component.id;
      }
      if (componentId.length === 0) {
        this.aiStatus = '无法创建蒙版，请重试';
        return;
      }
      const applied = session.setMaskComponentRasterFor(targetLayerId, componentId,
        aiMaskOrigin(kind), raster.modelKey, raster.width, raster.height, raster.alpha);
      if (!applied) {
        this.aiStatus = '识别结果已失效（蒙版已被删除），请重试';
        return;
      }
      const coverage = bitmapCoverage(raster.alpha);
      // An all-but-empty result is reported as a miss, not as success: for the
      // sky network in particular this is the common failure mode.
      this.aiStatus = coverage < 0.002
        ? '未识别到明显区域：可换一张照片，或改用画笔手动选区'
        : `已生成选区（覆盖约 ${Math.round(coverage * 100)}%），可用画笔或 ± 按钮修正`;
      ImageProcessor.process(session);
    } catch (error) {
      this.aiStatus = aiMaskErrorMessage(error as Object);
    } finally {
      this.aiBusyKind = -1;
    }
  }

  /**
   * Luminance / colour range controls.
   *
   * Every change rebuilds the raster from the cached source proxy, so dragging
   * a slider never re-reads the image: the proxy is captured once when the mask
   * is created, and lazily on the first edit after a reopen (the persisted
   * raster alone is enough to *render*, but not to recompute).
   */
  @Builder
  RangeSettings(component: MaskComponent) {
    Column() {
      Row() {
        Text('范围选区').fontSize(12).fontWeight(FontWeight.Bold)
          .fontColor(VividNative.textPrimary);
        Blank();
        Text(this.rangeEnabled(component) ? '含颜色范围' : '仅亮度范围').fontSize(10)
          .fontColor(VividNative.textSecondary);
      }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 2 });
      this.RangeSlider('亮度下限', this.rangeMin(component), (v: number) => {
        const data = this.rangeParams(component);
        if (!data) return;
        data.min = Math.min(v, data.max);
        this.recomputeRange();
      });
      this.RangeSlider('亮度上限', this.rangeMax(component), (v: number) => {
        const data = this.rangeParams(component);
        if (!data) return;
        data.max = Math.max(v, data.min);
        this.recomputeRange();
      });
      this.RangeSlider('边缘平滑', this.rangeSmoothness(component), (v: number) => {
        const data = this.rangeParams(component);
        if (!data) return;
        data.smoothness = v;
        this.recomputeRange();
      });
      if (this.rangeEnabled(component)) {
        this.RangeSlider('颜色容差', this.rangeColorAmount(component), (v: number) => {
          const data = this.rangeParams(component);
          if (!data) return;
          data.colorAmount = v;
          this.recomputeRange();
        });
      }
      Row() {
        Button('按选区取色').fontSize(10).type(ButtonType.Capsule).height(26).layoutWeight(1)
          .enabled(!this.rangeBusy)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => { this.pickRangeColor(); });
        Button(this.rangeEnabled(component) ? '取消颜色范围' : '仅亮度').fontSize(10).type(ButtonType.Capsule)
          .height(26).layoutWeight(1).margin({ left: 6 })
          .enabled(!this.rangeBusy)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => {
            const data = this.rangeParams(component);
            if (!data) return;
            data.colorEnabled = false;
            this.recomputeRange();
          });
      }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 });
    }.width('100%');
  }

  @Builder
  RangeSlider(label: string, value: number, onValue: (v: number) => void) {
    Row() {
      Text(label).fontSize(11)
        .fontColor(VividNative.textSecondary).width(64);
      Slider({ style: SliderStyle.OutSet, min: 0, max: 1, step: 0.01, value: value })
        .layoutWeight(1).trackColor(VividNative.sliderTrack)
          .selectedColor(VividNative.emphasize).blockColor(VividNative.sliderBlock)
          .blockBorderColor(VividNative.componentNormal).blockBorderWidth(1).enableHapticFeedback(true)
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) this.editSession.pushUndo();
        })
        .onChange((v: number) => { onValue(v); });
      Text(Math.round(value * 100).toString() + '%').fontSize(10)
        .fontColor(VividNative.textSecondary)
        .width(36).textAlign(TextAlign.End);
    }.width('100%').padding({ left: 12, right: 12, top: 2 });
  }

  private rangeParams(component: MaskComponent): RangeMaskData | null {
    return component.type === MaskComponentType.RANGE ? component.rangeData : null;
  }
  private rangeMin(component: MaskComponent): number {
    const data = component.rangeData;
    return data ? data.min : 0;
  }
  private rangeMax(component: MaskComponent): number {
    const data = component.rangeData;
    return data ? data.max : 1;
  }
  private rangeSmoothness(component: MaskComponent): number {
    const data = component.rangeData;
    return data ? data.smoothness : 0.25;
  }
  private rangeColorAmount(component: MaskComponent): number {
    const data = component.rangeData;
    return data ? data.colorAmount : 0.25;
  }
  private rangeEnabled(component: MaskComponent): boolean {
    const data = component.rangeData;
    return data ? data.colorEnabled : false;
  }

  /**
   * Capture (or reuse) the bounded source proxy.
   *
   * The panel keeps the last proxy so a slider drag never re-reads the image;
   * the service also caches it per source, so a reopen inside the same session
   * is still free. Only a genuinely new source costs a read.
   */
  private async ensureRangeProxy(): Promise<RangeMaskProxy | null> {
    const session = this.editSession;
    const token = RangeMaskService.tokenFor(session);
    const cached = RangeMaskService.cachedProxy(token);
    if (cached !== null) {
      this.rangeProxy = cached;
      return cached;
    }
    const source = session.sourcePixelMap;
    // 代理必须来自源图坐标系（蒙版栅格就在那个坐标系里）；取不到就不做门限，
    // 而不是退到旋转/裁剪过的预览图——那会让门限采到图片上不相干的位置。
    if (!source) return null;
    const proxy = await RangeMaskService.proxyFor(source, token);
    if (proxy !== null) this.rangeProxy = proxy;
    return proxy;
  }

  /**
   * Create a range mask and give it a starting window derived from this image.
   *
   * The layer is created only after the source has actually been read, so a
   * failed read leaves no empty mask behind, and the status text always reports
   * the real coverage rather than assuming success.
   */
  private async createRangeMask(): Promise<void> {
    if (this.rangeBusy) return;
    const session = this.editSession;
    if (!session.sourcePixelMap) {
      this.rangeStatus = '请先打开一张照片';
      return;
    }
    this.rangeBusy = true;
    this.rangeStatus = '正在分析图像色调…';
    this.aiStatus = '';
    try {
      const proxy = await this.ensureRangeProxy();
      if (proxy === null) {
        this.rangeStatus = '无法读取源图像像素，请重新打开照片';
        return;
      }
      const maskLayer = session.createMaskLayer(MaskComponentType.RANGE);
      const component = maskLayer && maskLayer.components.length > 0 ? maskLayer.components[0] : null;
      if (!component) {
        this.rangeStatus = '无法创建蒙版，请重试';
        return;
      }
      const window = RangeMaskService.defaultWindow(proxy);
      const params = new RangeMaskData();
      params.min = window.min;
      params.max = window.max;
      params.smoothness = 0.25;
      component.rangeData = params;
      if (!RangeMaskService.recompute(session, component.id, params, proxy)) {
        this.rangeStatus = '范围蒙版生成失败，请重试';
        return;
      }
      const raster = component.raster;
      const coverage = raster ? bitmapCoverage(raster.alpha) : 0;
      // The window comes from the image's own tonal distribution, so say so;
      // a near-empty result is reported as a miss rather than as success.
      this.rangeStatus = coverage < 0.002
        ? '该图像色调过于集中，范围选区几乎为空：可放宽亮度范围'
        : `已按图像色调生成范围（覆盖约 ${Math.round(coverage * 100)}%），可调整亮度范围`;
      ImageProcessor.process(session);
    } finally {
      this.rangeBusy = false;
    }
  }

  /** Rebuild the active range component's raster from the cached proxy. */
  private async recomputeRange(): Promise<void> {
    const session = this.editSession;
    const component = session.activeMaskComponent;
    if (!component || component.type !== MaskComponentType.RANGE) return;
    const params = component.rangeData;
    if (!params) return;
    const proxy = await this.ensureRangeProxy();
    if (proxy === null) {
      this.rangeStatus = '无法读取源图像像素，范围未更新';
      return;
    }
    if (!RangeMaskService.recompute(session, component.id, params, proxy)) {
      this.rangeStatus = '范围蒙版已被删除，未更新';
      return;
    }
    const raster = component.raster;
    const coverage = raster ? bitmapCoverage(raster.alpha) : 0;
    this.rangeStatus = coverage < 0.002
      ? '当前范围几乎没有选中任何区域'
      : `范围覆盖约 ${Math.round(coverage * 100)}%`;
    session.invalidateLayerMaskCache(session.activeLayer?.id ?? '');
    this.scheduleProcess();
  }

  /**
   * Narrow the selection to the colour that is currently selected.
   *
   * This is the Camera Raw workflow — keep the colour you have, discard the
   * rest — and it needs no eyedropper gesture because the colour is sampled
   * from real source pixels inside the current selection.
   */
  private async pickRangeColor(): Promise<void> {
    const session = this.editSession;
    const component = session.activeMaskComponent;
    if (!component || component.type !== MaskComponentType.RANGE) return;
    const params = component.rangeData;
    if (!params) return;
    this.rangeBusy = true;
    try {
      const proxy = await this.ensureRangeProxy();
      if (proxy === null) {
        this.rangeStatus = '无法读取源图像像素，取色失败';
        return;
      }
      const raster = component.raster;
      if (!raster || !raster.hasAlpha) {
        this.rangeStatus = '请先生成范围选区，再取色';
        return;
      }
      const color = averageSelectedColor(proxy, raster.alpha);
      if (color === null) {
        this.rangeStatus = '当前没有选中的像素可供取色：请先放宽亮度范围';
        return;
      }
      params.colorR = color[0];
      params.colorG = color[1];
      params.colorB = color[2];
      params.colorEnabled = true;
      if (!RangeMaskService.recompute(session, component.id, params, proxy)) {
        this.rangeStatus = '范围蒙版已被删除，取色未应用';
        return;
      }
      const after = component.raster;
      const coverage = after ? bitmapCoverage(after.alpha) : 0;
      this.rangeStatus = coverage < 0.002
        ? '取色后选区为空：可提高颜色容差'
        : `已按选区取色（覆盖约 ${Math.round(coverage * 100)}%），可调整颜色容差`;
      session.invalidateLayerMaskCache(session.activeLayer?.id ?? '');
      this.scheduleProcess();
    } finally {
      this.rangeBusy = false;
    }
  }

  @Builder
  MaskPill(label: string, active: boolean, onTap: () => void) {
    // Use a real Button rather than a clickable Text nested in the mask card.
    // Text hit regions were frequently swallowed by the card's click handler
    // on device, so the enable/disable control looked interactive but did
    // not toggle reliably.
    Button(label)
      .type(ButtonType.Capsule)
      .fontSize(9)
      .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
      .fontColor(active ? VividNative.textPrimary : VividNative.textSecondary)
      .height(24)
      .borderRadius(VividNative.radiusLevel12)
      .padding({ left: 8, right: 8 })
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: active ? VividNative.separator : Color.Transparent })
      .onClick(onTap);
  }

  @Builder
  ComponentSettings(component: MaskComponent) {
    Column() {
      Row() {
        Text('选区参数').fontSize(12).fontWeight(FontWeight.Bold)
          .fontColor(VividNative.textPrimary); Blank();
        Text(component.inverted ? '已反相' : '').fontSize(10)
          .fontColor(VividNative.textSecondary);
      }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 2 });
      Row() {
        Text('不透明度').fontSize(11)
          .fontColor(VividNative.textSecondary).width(64);
        Slider({ style: SliderStyle.OutSet, min: 0, max: 1, step: 0.01, value: component.opacity })
          .layoutWeight(1).trackColor(VividNative.sliderTrack)
          .selectedColor(VividNative.emphasize).blockColor(VividNative.sliderBlock)
          .blockBorderColor(VividNative.componentNormal).blockBorderWidth(1).enableHapticFeedback(true).onChange((value: number) => {
            component.opacity = value; this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
            this.scheduleProcess();
          });
        Text((component.opacity * 100).toFixed(0) + '%').fontSize(10)
          .fontColor(VividNative.textSecondary).width(36).textAlign(TextAlign.End);
      }.width('100%').padding({ left: 12, right: 12 });
      Row() {
        Button(component.inverted ? '取消反相' : '反相').fontSize(10).type(ButtonType.Capsule).height(26)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo(); component.inverted = !component.inverted;
            this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
            ImageProcessor.process(this.editSession);
          });
        Blank();
        if (component.type !== MaskComponentType.BRUSH) {
          Text('羽化').fontSize(11).fontColor(VividNative.textSecondary);
          Slider({ style: SliderStyle.OutSet, min: 0,
            max: component.type === MaskComponentType.LINEAR_GRADIENT ? 0.5 : 1,
            step: 0.01, value: component.feather })
            .layoutWeight(1).trackColor(VividNative.sliderTrack)
            .selectedColor(VividNative.emphasize).blockColor(VividNative.sliderBlock)
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) this.editSession.pushUndo();
            })
            .onChange((value: number) => {
              component.feather = value;
              this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
              this.scheduleProcess();
            });
        }
      }.width('100%').padding({ left: 12, right: 12, top: 4 });
      if (component.type === MaskComponentType.RANGE && component.rangeData) {
        this.RangeSettings(component);
      }
      if (component.type === MaskComponentType.BRUSH) {
        Row() {
          Text('画笔模式').fontSize(11)
            .fontColor(VividNative.textSecondary).width(64);
          this.BrushModeButton('绘制选区', 0);
          this.BrushModeButton('擦除笔迹', 1);
        }.width('100%').padding({ left: 12, right: 12, top: 6 });
        // 画笔的滑杆是"正在绘制的反馈"，拖动时叠加层要留着，所以显式关掉隐藏。
        SliderControl({ label: '大小', min: 0.005, max: 0.15, step: 0.005, value: this.editSession.brushSize,
          hideOverlayWhileDragging: false,
          onBegin: () => this.editSession.pushUndo(),
          onChange: (value: number) => { this.editSession.brushSize = value; this.editSession.requestProcessing(); },
          onEnd: () => this.editSession.bumpProcessing(),
        });
        SliderControl({ label: '硬度', min: 0, max: 1, step: 0.01, value: this.editSession.brushHardness,
          hideOverlayWhileDragging: false,
          onBegin: () => this.editSession.pushUndo(),
          onChange: (value: number) => { this.editSession.brushHardness = value; this.editSession.requestProcessing(); },
          onEnd: () => this.editSession.bumpProcessing(),
        });
      }
    }.width('100%');
  }

  @Builder
  BrushModeButton(label: string, mode: number) {
    Button(label).fontSize(9).type(ButtonType.Capsule).height(24)
      .buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(VividNative.textPrimary).controlSize(ControlSize.SMALL)
      .border({ width: this.editSession.maskBrushMode === mode ? 1 : 0, color: VividNative.separator })
      .margin({ right: 4 })
      .onClick(() => {
        this.editSession.pushUndo();
        this.editSession.maskBrushMode = mode;
        this.editSession.requestProcessing();
      });
  }

  @Builder
  LocalAdjustments() {
    if (this.editSession.activeMaskLayer) {
      Column() {
        Text('蒙版局部调整').fontSize(12).fontWeight(FontWeight.Bold)
          .fontColor(VividNative.textPrimary)
          .width('100%').padding({ left: 12, top: 8, bottom: 2 });
        this.MaskAdjustSlider('曝光', 'exposure', 'normal');
        this.MaskAdjustSlider('对比度', 'contrast', 'normal');
        this.MaskAdjustSlider('高光', 'highlights', 'normal');
        this.MaskAdjustSlider('阴影', 'shadows', 'normal');
        this.MaskAdjustSlider('色温', 'temperature', 'temperature');
        this.MaskAdjustSlider('色调', 'tint', 'tint');
        this.MaskAdjustSlider('饱和度', 'saturation', 'saturation');
      }.width('100%');
    }
  }

  @Builder
  MaskAdjustSlider(label: string, key: string, gradient: string) {
    if (this.editSession.activeMaskLayer) {
      SliderControl({ label: label, min: -1, max: 1, step: 0.01, value: this.editSession.activeMaskLayer?.adjustments.getValue(key) ?? 0, gradientType: gradient,
        onBegin: () => this.editSession.pushUndo(),
        onChange: (value: number) => this.updateMaskAdjustment(key, value),
        onEnd: () => { this.editSession.bumpProcessing(); },
      });
    }
  }

  private componentLabel(component: MaskComponent): string {
    const operation = component.blendMode === MaskBlendMode.SUBTRACT ? '（减去）' :
      (component.blendMode === MaskBlendMode.INTERSECT ? '（相交）' : '');
    if (component.type === MaskComponentType.BRUSH) return '画笔蒙版' + operation;
    if (component.type === MaskComponentType.LINEAR_GRADIENT) return '线性蒙版' + operation;
    return '径向蒙版' + operation;
  }

  private updateMaskAdjustment(key: string, value: number): void {
    const layer = this.editSession.activeMaskLayer;
    if (!layer) return;
    layer.adjustments.setValue(key, value);
    layer.touch();
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

  /** 开关切换时把状态写入选中的画笔分量并重算其栅格。 */
  private applyAutoMaskToSelected(enabled: boolean): void {
    const component = this.editSession.activeMaskComponent;
    if (!component || component.type !== MaskComponentType.BRUSH) return;
    component.ensureData();
    const brush = component.brushData;
    if (!brush) return;
    brush.autoMask = enabled;
    brush.sensitivity = this.editSession.brushAutoMaskSensitivity;
    // 预热源 RGB 代理：缺它时自动蒙版无从计算，叠加层也只能显示无门限笔迹。
    if (enabled) ImageProcessor.ensureAutoMaskProxy(this.editSession);
    if (brush.strokes.length > 0) {
      const layer = this.editSession.activeMaskLayer;
      if (layer) layer.touch();
      this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
      this.scheduleProcess();
    }
  }

  /** 自动蒙版开关只在选中的是画笔分量时显示（与桌面面板同一规则）。 */
  private autoMaskAvailable(): boolean {
    const selected = this.editSession.selectedMaskComponentId;
    if (selected !== null && selected !== undefined && selected.length > 0) {
      const layer = this.editSession.activeMaskLayer;
      if (layer) {
        for (const part of layer.components) {
          if (part.id === selected) return part.type === MaskComponentType.BRUSH;
        }
      }
    }
    return false;
  }

  /** 容差改变后重算已有自动蒙版笔刷分量的栅格。 */
  private refreshAutoMaskRaster(): void {
    const layer = this.editSession.activeMaskLayer;
    if (!layer) return;
    for (const component of layer.components) {
      if (component.type !== MaskComponentType.BRUSH) continue;
      const brush = component.brushData;
      if (!brush || !brush.autoMask || brush.strokes.length === 0) continue;
      brush.sensitivity = this.editSession.brushAutoMaskSensitivity;
    }
    layer.touch();
    this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
    this.scheduleProcess();
  }

  aboutToDisappear(): void {
    if (this.processTimer >= 0) clearTimeout(this.processTimer);
  }
}
