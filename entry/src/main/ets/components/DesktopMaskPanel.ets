import { EditSession } from '../edit/models/EditSession';
import { MaskComponent, MaskComponentType, MaskBlendMode, MaskLayer, isRasterComponentType } from '../edit/models/Mask';
import { MaskRenderer } from '../edit/engine/MaskRenderer';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { DesktopRawSlider } from './DesktopRawSlider';
import { DesktopDevelopPanel } from './DesktopDevelopPanel';
import { LayerPanel } from './LayerPanel';
import { MaskGroupActions } from './MaskGroupActions';
import { AiMaskKind } from '../edit/models/AiMaskModels';
import {
  AiSegmentationService, bitmapCoverage, aiMaskErrorMessage, aiMaskOrigin,
} from '../edit/engine/AiSegmentationService';
import { RangeMaskService } from '../edit/engine/RangeMaskService';
import { RangeMaskProxy, averageSelectedColor } from '../edit/engine/RangeMaskCore';
import { RangeMaskData } from '../edit/models/Mask';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { VividNative, VividNumberField } from './VividNativeTheme';

@Component
struct DesktopMaskThumbnail {
  @Consume('editSession') editSession: EditSession;
  @Prop groupId: string = '';
  @Prop partId: string = '';
  @StorageProp('maskRevision') @Watch('refresh') private revision: number = 0;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;

  build() {
    Canvas(this.context).width('100%').height('100%').onReady(() => { this.ready = true; this.refresh(); });
  }
  private refresh(): void {
    if (!this.ready) return;
    const group = this.editSession.activeLayer?.maskLayers.find((m: MaskLayer): boolean => m.id === this.groupId);
    if (!group) return;
    const part = group.components.find((c: MaskComponent): boolean => c.id === this.partId);
    const alpha = part ? MaskRenderer.renderComponent(part, 24, 24) : MaskRenderer.renderMaskLayer(group, 24, 24);
    const ctx = this.context;
    ctx.clearRect(0, 0, ctx.width, ctx.height);
    for (let y = 0; y < 24; y++) for (let x = 0; x < 24; x++) {
      const a = alpha[y * 24 + x];
      ctx.fillStyle = `rgb(${a},${a},${a})`;
      ctx.fillRect(x * ctx.width / 24, y * ctx.height / 24, ctx.width / 24 + 0.5, ctx.height / 24 + 0.5);
    }
  }
}

/** Camera Raw-style mask stack. All actions use the existing mask model. */
@Component
export struct DesktopMaskPanel {
  @Consume('editSession') editSession: EditSession;
  @StorageProp('vividNightMode') private night: boolean = false;
  @StorageLink('desktopMaskOverlay') private showCoverage: boolean = true;
  @StorageProp('maskRevision') private revision: number = 0;
  /**
   * 手机端「图层与蒙版」把图层列表插在"创建新蒙版"之后（用户要求：
   * 先创建蒙版、再看图层，蒙版列表与参数仍在其后）。桌面/平板各自
   * 已有独立的图层面板，保持默认 false 不受影响。
   */
  @Prop showLayerList: boolean = false;
  /**
   * 手机端把「图层/蒙版」拆成两个工具：图层页只显示图层列表，
   * 蒙版页只显示蒙版相关（创建/列表/参数）。桌面/平板保持默认 false。
   */
  @Prop layersOnly: boolean = false;
  @State private renameId: string = '';
  @State private renameDraft: string = '';
  /** Non-negative while a local model runs; blocks a second request. */
  @State private aiBusyKind: number = -1;
  @State private aiStatus: string = '';
  /** Non-zero while the source tonal proxy is being read. */
  @State private rangeBusy: boolean = false;
  /** Last captured source proxy, so a slider drag never re-reads the image. */
  private rangeProxy: RangeMaskProxy | null = null;
  private timer: number = -1;

  build() {
    Column() {
      if (this.layersOnly) {
        // 独立图层页：只挂图层列表，蒙版行/参数/叠加开关都不显示。
        LayerPanel({ externalScroll: true });
      } else {
      Row() {
        Button('+').fontSize(24).width(30).height(30).padding(0).type(ButtonType.Circle)
          .buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(VividNative.textPrimary)
          .border({ width: 1, color: VividNative.separator }).id('raw-mask-create').bindMenu(this.CreateMenu);
        Text('创建新蒙版').fontSize(12).fontColor(this.textColor()).layoutWeight(1).margin({ left: 12 });
        Button('◉').width(28).height(28).fontSize(16).padding(0)
          .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
          .focusable(true).focusBox(VividNative.focusBox())
          .onClick(() => { this.showCoverage = !this.showCoverage; });
      }.width('100%').height(52).padding({ left: 16, right: 12 });

      if (this.aiStatus.length > 0) {
        Row() {
          Text(this.aiStatus).fontSize(10).fontColor(VividNative.textSecondary).layoutWeight(1);
        }.width('100%').padding({ left: 16, right: 12, bottom: 6 });
      }

      if (this.showLayerList) {
        // 图层列表紧跟"创建新蒙版"，排在蒙版列表与蒙版参数之前。
        LayerPanel({ externalScroll: true });
      }

      Column() {
        ForEach(this.groups(), (group: MaskLayer) => { this.GroupRow(group); },
          // Key on the structure, not on the revision counter. The revision
          // changes on selection, rename and raster attach as well as on add /
          // delete, so keying on it destroyed and recreated every parent row —
          // and with it the child list and any open ⋯ menu — for operations
          // that do not change the row's contents at all. The child count is
          // the only structural fact the row renders, and each thumbnail still
          // refreshes itself through its own `maskRevision` @Watch.
          (group: MaskLayer) => group.id + ':' + group.components.length);
        if (this.groups().length === 0) {
          Text('创建蒙版以开始局部调整').fontSize(11).fontColor(VividNative.textSecondary)
            .width('100%').padding(20);
        }
      }.width('100%').padding({ left: 10, right: 10, bottom: 10 });
      Row() {
        Checkbox({ name: 'mask-overlay' }).select(this.showCoverage).width(14).height(14)
          .selectedColor(VividNative.emphasize)
          .onChange((checked: boolean) => { this.showCoverage = checked; });
        Text('显示叠加').fontSize(12).fontColor(this.textColor()); Blank();
        // 自动蒙版开关与"显示叠加"同行：只在画笔分量设置时才有意义，
        // 落笔时写入分量的 brushData（见 EditorCanvas / MaskPanel）。
        if (this.autoMaskAvailable()) {
          Checkbox({ name: 'mask-auto-brush' }).select(this.editSession.brushAutoMask)
            .width(14).height(14).selectedColor(VividNative.emphasize)
            .onChange((checked: boolean) => {
              this.editSession.pushUndo();
              this.editSession.brushAutoMask = checked;
              // 与手机端一致：切换立即作用到选中的画笔分量的已有笔画。
              this.applyAutoMaskToSelected(checked);
            });
          Text('自动蒙版').fontSize(12).fontColor(this.textColor())
            .margin({ right: 12 });
        }
      }.height(38).width('100%').padding({ left: 12, right: 12 })
        .border({ width: { top: 1, bottom: 1 }, color: VividNative.divider });

      ForEach(this.selectedParts(), (selected: MaskComponent) => {
        this.PartSettings(selected);
      }, (selected: MaskComponent) => selected.id + ':' + this.revision);
      if (this.editSession.activeMaskLayer) {
        Row() {
          Text(this.editSession.activeMaskLayer?.name ?? '').fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(this.textColor()).layoutWeight(1);
          Button('重置').height(24).fontSize(10).padding({ left: 6, right: 6 })
            .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .onClick(() => {
              const selected = this.editSession.activeMaskLayer;
              if (!selected) return;
              this.editSession.pushUndo(); selected.adjustments.reset(); this.render();
            });
        }.height(40).width('100%').padding({ left: 20, right: 16 });
        DesktopRawSlider({ label: '数量', controlId: 'mask-amount', lower: 0, upper: 1,
          currentValue: this.editSession.activeMaskLayer?.opacity ?? 1,
          onBegin: () => { this.editSession.pushUndo(); }, onUpdate: (v: number) => {
            const selected = this.editSession.activeMaskLayer;
            if (!selected) return;
            selected.opacity = v; this.invalidate();
          }, onEnd: () => { this.render(); },
        }).padding({ left: 20, right: 20, bottom: 14 });
        DesktopDevelopPanel({ maskContext: true, showProfile: false });
      }
      }
    }.width('100%').alignItems(HorizontalAlign.Start);
  }

  @Builder
  private CreateMenu() { this.ToolMenu(0); }
  @Builder
  private AddMenu() { this.ToolMenu(1); }
  @Builder
  private SubtractMenu() { this.ToolMenu(2); }
  @Builder
  private ToolMenu(operation: number) {
    Menu() {
      MenuItem({ content: '画笔' }).onClick(() => { this.chooseTool(MaskComponentType.BRUSH, operation); });
      MenuItem({ content: '线性渐变' }).onClick(() => { this.chooseTool(MaskComponentType.LINEAR_GRADIENT, operation); });
      MenuItem({ content: '径向渐变' }).onClick(() => { this.chooseTool(MaskComponentType.RADIAL_GRADIENT, operation); });
      // Local, offline segmentation. It produces an ordinary mask component, so
      // it can be added, subtracted or intersected exactly like the tools above.
      MenuItem({ content: this.aiBusyKind >= 0 ? '识别中…' : '主体' })
        .enabled(this.aiBusyKind < 0)
        .onClick(() => { this.chooseTool(MaskComponentType.SUBJECT, operation); });
      MenuItem({ content: this.aiBusyKind >= 0 ? '识别中…' : '天空' })
        .enabled(this.aiBusyKind < 0)
        .onClick(() => { this.chooseTool(MaskComponentType.SKY, operation); });
      // Range selection: narrow the selection by where each pixel sits in the
      // image's tonal (and optionally chromatic) distribution.
      MenuItem({ content: this.rangeBusy ? '分析中…' : '范围（亮度/颜色）' })
        .enabled(!this.rangeBusy)
        .onClick(() => { this.chooseTool(MaskComponentType.RANGE, operation); });
    };
  }

  @Builder
  private GroupRow(group: MaskLayer) {
    Column() {
      Row() {
        Row() {
          Stack() { DesktopMaskThumbnail({ groupId: group.id }); }
            .width(42).height(42).border({ width: 2, color: group.id === this.editSession.selectedMaskLayerId ? VividNative.emphasize : VividNative.componentNormal })
            .borderRadius(VividNative.radiusSmallButton)
            // 黑白预览是画满整格的方形位图，不裁剪的话四个角会穿出圆角边框。
            .clip(true);
          if (this.renameId === group.id) {
            TextInput({ text: this.renameDraft }).height(28).fontSize(12).layoutWeight(1)
              .attributeModifier(VividNumberField.field)
              .onChange((text: string) => { this.renameDraft = text; })
              .onSubmit(() => { this.editSession.renameMaskLayer(group.id, this.renameDraft); this.renameId = ''; });
          } else {
            Text(group.name).fontSize(12).fontColor(this.textColor())
              .fontWeight(group.id === this.editSession.selectedMaskLayerId ? FontWeight.Medium : FontWeight.Regular)
              .layoutWeight(1).margin({ left: 12 });
          }
        }.layoutWeight(1).height('100%')
          .onClick(() => { this.editSession.selectMaskLayer(group.id); this.render(); });
        // Keep menu outside the selection hit area: opening it must not rebuild
        // the revision-keyed parent row and dispose its menu immediately.
        MaskGroupActions({ groupId: group.id,
          onRename: (target: MaskLayer) => { this.renameId = target.id; this.renameDraft = target.name; },
          onChange: () => { this.render(); },
        });
      }.width('100%').height(52).id('raw-mask-' + group.id);
      if (group.id === this.editSession.selectedMaskLayerId) {
        ForEach(group.components.slice().reverse(), (part: MaskComponent) => {
          Row() {
            Row() {
              Stack() { DesktopMaskThumbnail({ groupId: group.id, partId: part.id }); }
                .width(24).height(24).border({ width: 1, color: part.id === this.editSession.selectedMaskComponentId ? VividNative.emphasize : VividNative.separator })
                .borderRadius(6)
                .clip(true);
              Text(this.partLabel(part)).fontSize(11)
                .fontColor(this.textColor())
                .fontWeight(part.id === this.editSession.selectedMaskComponentId ? FontWeight.Medium : FontWeight.Regular)
                .margin({ left: 10 }).layoutWeight(1);
            }.layoutWeight(1).height('100%')
              .onClick(() => { this.editSession.selectMaskComponent(part.id); this.render(); });
            Button('×').width(22).height(24).padding(0).fontSize(13)
              .buttonStyle(ButtonStyleMode.TEXTUAL).role(ButtonRole.ERROR).controlSize(ControlSize.SMALL)
              .onClick(() => { this.editSession.deleteMaskComponent(part.id); this.render(); });
          }.id('raw-part-' + part.id).width('100%').height(34).padding({ left: 18, right: 6 });
        }, (part: MaskComponent) => part.id);
        Row({ space: 8 }) {
          Button('▣  添加').fontSize(11).height(28).layoutWeight(1)
            .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL).fontColor(this.textColor())
            .border({ width: 1, color: VividNative.separator })
            .id('raw-mask-add').bindMenu(this.AddMenu);
          Button('▣  减去').fontSize(11).height(28).layoutWeight(1)
            .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL).fontColor(this.textColor())
            .border({ width: 1, color: VividNative.separator })
            .id('raw-mask-subtract').bindMenu(this.SubtractMenu);
        }.width('100%').padding({ left: 10, right: 10, top: 6, bottom: 8 });
      }
    }.width('100%').padding({ left: 5, right: 5 })
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: group.id === this.editSession.selectedMaskLayerId ? VividNative.separator : Color.Transparent });
  }

  @Builder
  private PartSettings(part: MaskComponent) {
    Column() {
      Row() {
        Text(this.partLabel(part)).fontSize(12).fontColor(this.textColor()).layoutWeight(1);
        Button(part.inverted ? '取消反向组件' : '反向组件').fontSize(10).height(24).padding({ left: 6, right: 6 })
          .id('raw-part-invert')
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL).onClick(() => {
            this.editSession.pushUndo(); part.inverted = !part.inverted; this.invalidate(); this.render();
          });
      }.width('100%').height(32);
      if (part.type === MaskComponentType.BRUSH) {
        Row({ space: 8 }) {
          // 画笔模式互斥选择：原生按钮档位表达当前模式。
          Button('绘制').height(24).fontSize(11)
            .buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(VividNative.textPrimary).controlSize(ControlSize.SMALL)
            .border({ width: this.editSession.maskBrushMode === 0 ? 1 : 0, color: VividNative.separator })
            .onClick(() => { this.editSession.maskBrushMode = 0; });
          Button('擦除').height(24).fontSize(11)
            .buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(VividNative.textPrimary).controlSize(ControlSize.SMALL)
            .border({ width: this.editSession.maskBrushMode === 1 ? 1 : 0, color: VividNative.separator })
            .onClick(() => { this.editSession.maskBrushMode = 1; });
        }.width('100%');
        DesktopRawSlider({ label: '大小', controlId: 'brush-size', lower: 0.005, upper: 0.15, increment: 0.005,
          currentValue: this.editSession.brushSize, onUpdate: (v: number) => { this.editSession.brushSize = v; } });
        DesktopRawSlider({ label: '硬度', controlId: 'brush-hardness', lower: 0, upper: 1,
          currentValue: this.editSession.brushHardness, onUpdate: (v: number) => { this.editSession.brushHardness = v; } });
        DesktopRawSlider({ label: '流量', controlId: 'brush-flow', lower: 0, upper: 1,
          currentValue: this.editSession.brushFlow, onUpdate: (v: number) => { this.editSession.brushFlow = v; } });
        DesktopRawSlider({ label: '密度', controlId: 'brush-density', lower: 0, upper: 1,
          currentValue: this.editSession.brushDensity, onUpdate: (v: number) => { this.editSession.brushDensity = v; } });
      } else if (part.type === MaskComponentType.RANGE && part.rangeData) {
        DesktopRawSlider({ label: '亮度下限', controlId: 'range-min', lower: 0, upper: 1,
          currentValue: part.rangeData.min, onBegin: () => { this.editSession.pushUndo(); },
          onUpdate: (v: number) => {
            const data = part.rangeData;
            if (!data) return;
            data.min = Math.min(v, data.max);
            this.applyRange(part);
          }, onEnd: () => { this.render(); } });
        DesktopRawSlider({ label: '亮度上限', controlId: 'range-max', lower: 0, upper: 1,
          currentValue: part.rangeData.max, onBegin: () => { this.editSession.pushUndo(); },
          onUpdate: (v: number) => {
            const data = part.rangeData;
            if (!data) return;
            data.max = Math.max(v, data.min);
            this.applyRange(part);
          }, onEnd: () => { this.render(); } });
        DesktopRawSlider({ label: '边缘平滑', controlId: 'range-smooth', lower: 0, upper: 1,
          currentValue: part.rangeData.smoothness, onBegin: () => { this.editSession.pushUndo(); },
          onUpdate: (v: number) => {
            const data = part.rangeData;
            if (!data) return;
            data.smoothness = v;
            this.applyRange(part);
          }, onEnd: () => { this.render(); } });
        if (part.rangeData.colorEnabled) {
          DesktopRawSlider({ label: '颜色容差', controlId: 'range-color', lower: 0, upper: 1,
            currentValue: part.rangeData.colorAmount, onBegin: () => { this.editSession.pushUndo(); },
            onUpdate: (v: number) => {
              const data = part.rangeData;
              if (!data) return;
              data.colorAmount = v;
              this.applyRange(part);
            }, onEnd: () => { this.render(); } });
        }
        Row({ space: 8 }) {
          Button('按选区取色').height(24).fontSize(11).id('raw-range-pick')
            .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .enabled(!this.rangeBusy).onClick(() => { this.pickRangeColor(part); });
          Button(part.rangeData.colorEnabled ? '仅亮度' : '未启用颜色').height(24).fontSize(11)
            .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .enabled(!this.rangeBusy && part.rangeData.colorEnabled)
            .onClick(() => {
              const data = part.rangeData;
              if (!data) return;
              data.colorEnabled = false;
              this.applyRange(part);
              this.render();
            });
        }.width('100%');
      } else {
        DesktopRawSlider({ label: '羽化', controlId: 'mask-feather', lower: 0,
          upper: part.type === MaskComponentType.LINEAR_GRADIENT ? 0.5 : 1, currentValue: part.feather,
          onBegin: () => { this.editSession.pushUndo(); }, onUpdate: (v: number) => { part.feather = v; this.invalidate(); },
          onEnd: () => { this.render(); },
        });
      }
    }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 14 })
      .border({ width: { bottom: 1 }, color: VividNative.divider });
  }

  private groups(): MaskLayer[] { return (this.editSession.activeLayer?.maskLayers ?? []).slice().reverse(); }
  private selectedParts(): MaskComponent[] {
    const selected = this.editSession.activeMaskComponent;
    return selected ? [selected] : [];
  }
  private textColor(): Resource { return VividNative.textPrimary; }

  /** 开关切换时把状态写入选中的画笔分量并重算其栅格。 */
  private applyAutoMaskToSelected(enabled: boolean): void {
    const component = this.editSession.activeMaskComponent;
    if (!component || component.type !== MaskComponentType.BRUSH) return;
    component.ensureData();
    const brush = component.brushData;
    if (!brush) return;
    brush.autoMask = enabled;
    brush.sensitivity = this.editSession.brushAutoMaskSensitivity;
    // 预热源 RGB 代理：缺它时自动蒙版无从计算。
    if (enabled) ImageProcessor.ensureAutoMaskProxy(this.editSession);
    if (brush.strokes.length > 0) {
      const layer = this.editSession.activeMaskLayer;
      if (layer) layer.touch();
      this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
      this.render();
    }
  }

  /** 自动蒙版开关只在选中的是画笔分量（或正在画笔工具下）时显示。 */
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
  private partLabel(part: MaskComponent): string {
    const label = part.type === MaskComponentType.BRUSH ? '画笔' :
      (part.type === MaskComponentType.LINEAR_GRADIENT ? '线性渐变' :
        (part.type === MaskComponentType.RADIAL_GRADIENT ? '径向渐变' :
          (part.type === MaskComponentType.RANGE ? '范围' :
            (part.type === MaskComponentType.SKY ? '天空' : '主体'))));
    const detail = isRasterComponentType(part.type) && (!part.raster || !part.raster.hasAlpha)
      ? '（未生成）' : '';
    return (part.blendMode === MaskBlendMode.SUBTRACT ? '减去 · ' :
      (part.blendMode === MaskBlendMode.INTERSECT ? '相交 · ' : '添加 · ')) + label + detail;
  }
  private chooseTool(type: MaskComponentType, operation: number): void {
    if (type === MaskComponentType.SUBJECT || type === MaskComponentType.SKY) {
      this.runAiSelection(type === MaskComponentType.SKY ? AiMaskKind.SKY : AiMaskKind.SUBJECT, operation);
      return;
    }
    if (type === MaskComponentType.RANGE) {
      this.runRangeSelection(operation);
      return;
    }
    if (operation === 0) this.editSession.createMaskLayer(type);
    else this.editSession.addMaskComponent(type, operation === 2 ? MaskBlendMode.SUBTRACT :
      (operation === 3 ? MaskBlendMode.INTERSECT : MaskBlendMode.ADD));
    this.showCoverage = true; this.render();
  }

  /** Capture (or reuse) the bounded source proxy used by every range recompute. */
  private async ensureRangeProxy(): Promise<RangeMaskProxy | null> {
    const session = this.editSession;
    const token = RangeMaskService.tokenFor(session);
    const cached = RangeMaskService.cachedProxy(token);
    if (cached !== null) {
      this.rangeProxy = cached;
      return cached;
    }
    const source = session.sourcePixelMap;
    // 与手机端一致：代理只能来自源图坐标系，否则门限会采到错误的图像位置。
    if (!source) return null;
    const proxy = await RangeMaskService.proxyFor(source, token);
    if (proxy !== null) this.rangeProxy = proxy;
    return proxy;
  }

  /**
   * Create a range mask with a starting window derived from this image.
   *
   * The component is created only after the source has actually been read, so a
   * failed read leaves no empty mask behind.
   */
  private async runRangeSelection(operation: number): Promise<void> {
    if (this.rangeBusy) return;
    const session = this.editSession;
    if (!session.sourcePixelMap) {
      this.aiStatus = '请先打开一张照片';
      return;
    }
    this.rangeBusy = true;
    this.aiStatus = '正在分析图像色调…';
    try {
      const proxy = await this.ensureRangeProxy();
      if (proxy === null) {
        this.aiStatus = '无法读取源图像像素，请重新打开照片';
        return;
      }
      const mode = operation === 2 ? MaskBlendMode.SUBTRACT :
        (operation === 3 ? MaskBlendMode.INTERSECT : MaskBlendMode.ADD);
      let component: MaskComponent | null = null;
      if (operation === 0 || !session.activeMaskLayer) {
        const maskLayer = session.createMaskLayer(MaskComponentType.RANGE);
        component = maskLayer && maskLayer.components.length > 0 ? maskLayer.components[0] : null;
      } else {
        component = session.addMaskComponent(MaskComponentType.RANGE, mode);
      }
      if (!component) {
        this.aiStatus = '无法创建蒙版，请重试';
        return;
      }
      const window = RangeMaskService.defaultWindow(proxy);
      const params = new RangeMaskData();
      params.min = window.min;
      params.max = window.max;
      params.smoothness = 0.25;
      component.rangeData = params;
      if (!RangeMaskService.recompute(session, component.id, params, proxy)) {
        this.aiStatus = '范围蒙版生成失败，请重试';
        return;
      }
      const raster = component.raster;
      const coverage = raster ? bitmapCoverage(raster.alpha) : 0;
      this.aiStatus = coverage < 0.002
        ? '该图像色调过于集中，范围选区几乎为空：可放宽亮度范围'
        : `已按图像色调生成范围（覆盖约 ${Math.round(coverage * 100)}%）`;
      this.showCoverage = true;
      this.invalidate();
    } finally {
      this.rangeBusy = false;
    }
  }

  /** Rebuild a range component's raster from the cached proxy. */
  private async applyRange(part: MaskComponent): Promise<void> {
    const session = this.editSession;
    const params = part.rangeData;
    if (!params) return;
    const proxy = await this.ensureRangeProxy();
    if (proxy === null) {
      this.aiStatus = '无法读取源图像像素，范围未更新';
      return;
    }
    if (!RangeMaskService.recompute(session, part.id, params, proxy)) {
      this.aiStatus = '范围蒙版已被删除，未更新';
      return;
    }
    const raster = part.raster;
    const coverage = raster ? bitmapCoverage(raster.alpha) : 0;
    this.aiStatus = coverage < 0.002
      ? '当前范围几乎没有选中任何区域'
      : `范围覆盖约 ${Math.round(coverage * 100)}%`;
    this.invalidate();
  }

  /**
   * Narrow the selection to the colour that is currently selected, sampled from
   * real source pixels inside it — the Camera Raw "keep this colour" workflow.
   */
  private async pickRangeColor(part: MaskComponent): Promise<void> {
    const session = this.editSession;
    const params = part.rangeData;
    if (!params) return;
    this.rangeBusy = true;
    try {
      const proxy = await this.ensureRangeProxy();
      if (proxy === null) {
        this.aiStatus = '无法读取源图像像素，取色失败';
        return;
      }
      const raster = part.raster;
      if (!raster || !raster.hasAlpha) {
        this.aiStatus = '请先生成范围选区，再取色';
        return;
      }
      const color = averageSelectedColor(proxy, raster.alpha);
      if (color === null) {
        this.aiStatus = '当前没有选中的像素可供取色：请先放宽亮度范围';
        return;
      }
      params.colorR = color[0];
      params.colorG = color[1];
      params.colorB = color[2];
      params.colorEnabled = true;
      if (!RangeMaskService.recompute(session, part.id, params, proxy)) {
        this.aiStatus = '范围蒙版已被删除，取色未应用';
        return;
      }
      const after = part.raster;
      const coverage = after ? bitmapCoverage(after.alpha) : 0;
      this.aiStatus = coverage < 0.002
        ? '取色后选区为空：可提高颜色容差'
        : `已按选区取色（覆盖约 ${Math.round(coverage * 100)}%），可调整颜色容差`;
      this.invalidate();
    } finally {
      this.rangeBusy = false;
    }
  }

  /**
   * Run one local segmentation and turn it into a real mask component.
   *
   * Identical contract to the phone panel: the component is created only after
   * inference succeeds, a result for a photo the user already left is dropped,
   * and `aiBusyKind` is cleared in `finally` so the menu can never stick in the
   * "识别中…" state.
   */
  private async runAiSelection(kind: AiMaskKind, operation: number): Promise<void> {
    if (this.aiBusyKind >= 0) return;
    const session = this.editSession;
    const source = session.sourcePixelMap;
    if (!source) {
      this.aiStatus = '请先打开一张照片';
      return;
    }
    const type = kind === AiMaskKind.SKY ? MaskComponentType.SKY : MaskComponentType.SUBJECT;
    this.aiBusyKind = kind as number;
    this.aiStatus = '正在本地识别…';
    const generation = AiSegmentationService.currentGeneration();
    // 绑定发起识别时的目标。await 可能持续数秒，期间用户可能切换图层或蒙版：
    // 旧代码在 await 之后按“当前” activeMaskLayer 决定落点，于是识别结果会
    // 加到用户后来选中的蒙版上。这里把 layer/maskLayer 的 id 在 await 之前
    // 固定下来，之后只按 id 重新解析目标。
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
      const mode = operation === 2 ? MaskBlendMode.SUBTRACT :
        (operation === 3 ? MaskBlendMode.INTERSECT : MaskBlendMode.ADD);
      let componentId = '';
      if (operation === 0 || targetMaskLayerId.length === 0) {
        // 新建蒙版层时也必须落在发起时的图层上，而不是当前选中的图层。
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
      // A near-empty result is reported as a miss rather than as success.
      this.aiStatus = coverage < 0.002
        ? '未识别到明显区域：可换一张照片，或改用画笔手动选区'
        : `已生成选区（覆盖约 ${Math.round(coverage * 100)}%）`;
      this.showCoverage = true;
      this.invalidate();
    } catch (error) {
      this.aiStatus = aiMaskErrorMessage(error as Object);
    } finally {
      this.aiBusyKind = -1;
    }
  }
  private invalidate(): void {
    this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
    this.editSession.requestProcessing();
    if (this.timer !== -1) return;
    this.timer = setTimeout(() => { this.timer = -1; ImageProcessor.process(this.editSession); }, 33);
  }
  private render(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    this.editSession.notifyMaskRevision();
    ImageProcessor.process(this.editSession);
  }
  aboutToDisappear(): void { if (this.timer !== -1) this.render(); }
}
