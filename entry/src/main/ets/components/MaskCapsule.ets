import { EditSession } from '../edit/models/EditSession';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { MaskRenderer } from '../edit/engine/MaskRenderer';
import { MaskBlendMode, MaskComponent, MaskComponentType, MaskLayer, RangeMaskData } from '../edit/models/Mask';
import { AiMaskKind } from '../edit/models/AiMaskModels';
import {
  AiSegmentationService, bitmapCoverage, aiMaskErrorMessage, aiMaskOrigin,
} from '../edit/engine/AiSegmentationService';
import { RangeMaskService } from '../edit/engine/RangeMaskService';
import { RangeMaskProxy, averageSelectedColor, buildRangeAlpha } from '../edit/engine/RangeMaskCore';
import { common } from '@kit.AbilityKit';
import { VividNative } from './VividNativeTheme';

/**
 * 预览卡片右下角的蒙版胶囊（宽度固定，底部贴着卡片右下角，所以每加一层都向上长一格）：
 *   [+ 新建蒙版]
 *   [矩形蒙版缩略图]  ← 单击选中（再点一次弹出操作菜单）；下方 + / − 增删该层选区
 *          + −
 * 选中某层后左侧出现一个同样式的窄胶囊：删除 / 反相 两个图标按钮。
 */
const CAPSULE_WIDTH: number = 64;
/** + 按钮直径；缩略图宽度与它一致。 */
const ADD_BUTTON: number = 45;
const THUMB_WIDTH: number = ADD_BUTTON + 6;
const THUMB_HEIGHT: number = 36;
/** 子蒙版缩略图：比父层小一圈，方便区分层级。 */
const CHILD_WIDTH: number = 33;
const CHILD_HEIGHT: number = 22;

interface MaskToolOption {
  type: MaskComponentType;
  label: string;
  glyph: string;
  ai: boolean;
  /** 范围蒙版的两种起点：只按亮度，或亮度 + 颜色。 */
  range: string;
}

const MASK_TOOLS: MaskToolOption[] = [
  { type: MaskComponentType.BRUSH, label: '画笔', glyph: '✎', ai: false, range: '' },
  { type: MaskComponentType.LINEAR_GRADIENT, label: '线性渐变', glyph: '▤', ai: false, range: '' },
  { type: MaskComponentType.RADIAL_GRADIENT, label: '径向渐变', glyph: '◎', ai: false, range: '' },
  { type: MaskComponentType.SUBJECT, label: '主体', glyph: '◉', ai: true, range: '' },
  { type: MaskComponentType.SKY, label: '天空', glyph: '☁', ai: true, range: '' },
  { type: MaskComponentType.RANGE, label: '亮度范围', glyph: '◐', ai: false, range: 'luma' },
  { type: MaskComponentType.RANGE, label: '颜色范围', glyph: '◍', ai: false, range: 'color' },
];

/** 回车键图标（参考 Lightroom 的蒙版行）：从缩略图左下角进入该蒙版。 */
@Component
struct MaskEnterIcon {
  @Prop color: ResourceColor = '#1B2536';
  /** 目标边长：内部笔画按 14 画，再整体缩放到这个尺寸。 */
  @Prop box: number = 14;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 横向笔画
      Row()
        .width(9)
        .height(1.3)
        .borderRadius(1)
        .backgroundColor(this.color)
        .offset({ y: 2.4 });
      // 右侧向上的转折
      Row()
        .width(1.3)
        .height(6)
        .borderRadius(1)
        .backgroundColor(this.color)
        .offset({ x: 3.9, y: -0.6 });
      // 左端箭头
      Row()
        .width(4.2)
        .height(1.3)
        .borderRadius(1)
        .backgroundColor(this.color)
        .rotate({ angle: -45 })
        .offset({ x: -2.6, y: 0.6 });
      Row()
        .width(4.2)
        .height(1.3)
        .borderRadius(1)
        .backgroundColor(this.color)
        .rotate({ angle: 45 })
        .offset({ x: -2.6, y: 4.2 });
    }
    .width(14)
    .height(14)
    .scale({ x: -this.box / 14, y: this.box / 14 });
  }
}

/** 垃圾桶图标：字体里没有对应字形，用图元拼一个。 */
@Component
struct MaskTrashIcon {
  @Prop color: ResourceColor = '#1B2536';
  /** 图标外框尺寸，矢量细节按比例放大。 */
  @Prop box: number = 16;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 桶身
      Row()
        .width(10)
        .height(11)
        .borderRadius(2)
        .border({ width: 1.3, color: this.color })
        .offset({ y: 3 });
      // 桶盖
      Row()
        .width(15)
        .height(1.4)
        .borderRadius(1)
        .backgroundColor(this.color)
        .offset({ y: -5 });
      // 提手
      Row()
        .width(5)
        .height(1.4)
        .borderRadius(1)
        .backgroundColor(this.color)
        .offset({ y: -8 });
    }
    .width(this.box)
    .height(this.box)
    .scale({ x: this.box / 16, y: this.box / 16 });
  }
}

interface MaskActionOption {
  id: string;
  glyph: string;
  label: string;
}

const MASK_ACTIONS: MaskActionOption[] = [
  { id: 'toggle', glyph: '◍', label: '隐藏' },
  { id: 'rename', glyph: '✎', label: '重命名' },
  { id: 'copy', glyph: '⧉', label: '复制蒙版' },
  { id: 'copyInvert', glyph: '⧈', label: '复制并反相' },
  { id: 'invert', glyph: '◐', label: '反相蒙版' },
  { id: 'delete', glyph: '⌫', label: '删除' },
];

/** 胶囊里的蒙版缩略图：直接画 MaskRenderer 出来的 alpha 图。 */
@Component
struct CapsuleMaskThumb {
  @Consume('editSession') editSession: EditSession;
  @Prop groupId: string = '';
  @Prop partId: string = '';
  @StorageProp('maskRevision') @Watch('refresh') private revision: number = 0;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;

  build() {
    Canvas(this.context)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.ready = true;
        this.refresh();
      });
  }

  private refresh(): void {
    if (!this.ready) return;
    const group = this.editSession.activeLayer?.maskLayers.find((item: MaskLayer): boolean => item.id === this.groupId);
    if (!group) return;
    const part = group.components.find((item: MaskComponent): boolean => item.id === this.partId);
    const ctx = this.context;
    // 按画布尺寸逐像素画，缩略图才不会被放大成马赛克。
    const cols = Math.min(160, Math.max(16, Math.round(ctx.width)));
    const rows = Math.min(160, Math.max(16, Math.round(ctx.height)));
    const alpha = part ? MaskRenderer.renderComponent(part, cols, rows)
      : MaskRenderer.renderMaskLayer(group, cols, rows);
    ctx.clearRect(0, 0, ctx.width, ctx.height);
    for (let y = 0; y < rows; y++) {
      for (let x = 0; x < cols; x++) {
        const a = alpha[y * cols + x];
        ctx.fillStyle = `rgb(${a},${a},${a})`;
        ctx.fillRect(x * ctx.width / cols, y * ctx.height / rows,
          ctx.width / cols + 0.4, ctx.height / rows + 0.4);
      }
    }
  }
}

/** 预览卡片左下角的蒙版快捷胶囊：删除 / 反相，作用于当前选中的蒙版。 */
@Component
export struct MaskSideActions {
  @Consume('editSession') editSession: EditSession;
  @StorageLink('desktopMaskOverlay') private overlayOn: boolean = true;
  @StorageProp('maskRevision') private revision: number = 0;
  @StorageProp('vividNightMode') private night: boolean = false;
  private timer: number = -1;

  private iconColor(): string {
    return this.night ? '#F4F7FC' : '#1B2536';
  }

  /** 当前选中分量在该蒙版层里的序号；-1 表示没有选中分量。 */
  private activeComponentIndex(): number {
    const layer = this.editSession.activeMaskLayer;
    const part = this.editSession.activeMaskComponent;
    if (layer === null || part === null) return -1;
    return layer.components.findIndex((item: MaskComponent): boolean => item.id === part.id);
  }

  private removeLayer(): void {
    const layer = this.editSession.activeMaskLayer;
    if (layer === null) return;
    // 选中的是子蒙版（第 2 份起）时只删这一份，否则删掉整个父级蒙版。
    const part = this.editSession.activeMaskComponent;
    if (part !== null && this.activeComponentIndex() > 0) {
      this.editSession.deleteMaskComponent(part.id);
      this.afterChange();
      return;
    }
    this.editSession.deleteMaskLayer(layer.id);
    this.afterChange();
  }

  private invertLayer(): void {
    const layer = this.editSession.activeMaskLayer;
    if (layer === null) return;
    const part = this.editSession.activeMaskComponent;
    this.editSession.pushUndo();
    if (part !== null && this.activeComponentIndex() >= 0) {
      // 只反相当前选中的那一份选区（子蒙版可以单独反相）。
      part.inverted = !part.inverted;
    } else {
      layer.inverted = !layer.inverted;
    }
    layer.touch();
    this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
    this.editSession.bumpProcessing();
    this.afterChange();
  }

  private afterChange(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.editSession.notifyMaskRevision();
    ImageProcessor.process(this.editSession);
  }

  build() {
    Column({ space: 6 }) {
      // 眼睛：显示 / 隐藏当前蒙版的红色叠加（与桌面蒙版面板共用同一个开关）。
      Button() {
        Stack({ alignContent: Alignment.Center }) {
          Row()
            .width(14)
            .height(9)
            .borderRadius(5)
            .border({ width: 1.3, color: this.iconColor() });
          Row()
            .width(3.4)
            .height(3.4)
            .borderRadius(2)
            .backgroundColor(this.iconColor());
          if (!this.overlayOn) {
            Row()
              .width(18)
              .height(1.4)
              .borderRadius(1)
              .backgroundColor(this.iconColor())
              .rotate({ angle: -42 });
          }
        }
        .width(16)
        .height(16)
        .scale({ x: 22 / 16, y: 22 / 16 });
      }
      .width(44)
      .height(44)
      .padding(0)
      .type(ButtonType.Circle)
      .buttonStyle(ButtonStyleMode.NORMAL)
      .controlSize(ControlSize.SMALL)
      .accessibilityText(this.overlayOn ? '隐藏蒙版叠加' : '显示蒙版叠加')
      .onClick(() => { this.overlayOn = !this.overlayOn; });
      Button() {
        MaskTrashIcon({ color: this.night ? '#F4F7FC' : '#1B2536', box: 22 });
      }
      .width(44)
      .height(44)
      .padding(0)
      .type(ButtonType.Circle)
      .buttonStyle(ButtonStyleMode.NORMAL)
      .controlSize(ControlSize.SMALL)
      .accessibilityText('删除蒙版')
      .onClick(() => { this.removeLayer(); });
      Button('◐')
        .fontSize(20)
      .width(44)
      .height(44)
        .padding(0)
        .type(ButtonType.Circle)
        .buttonStyle(ButtonStyleMode.NORMAL)
        .controlSize(ControlSize.SMALL)
        .accessibilityText('反相蒙版')
        .onClick(() => { this.invertLayer(); });
    }
    // 与上方工具列对齐：54vp 宽、药丸形状。
    .width(54)
    .padding(5)
    .borderRadius(27)
    .backgroundColor(this.night ? 'rgba(22,26,34,0.88)' : 'rgba(255,255,255,0.92)')
    .border({ width: 1, color: this.night ? 'rgba(255,255,255,0.12)' : VividNative.separator })
    .shadow({ radius: 14, color: this.night ? 'rgba(0,0,0,0.4)' : 'rgba(20,30,50,0.14)', offsetY: 4 })
    .id('mask-side-' + this.revision);
  }
}

/** 点 + 后的添加蒙版弹窗：没有标题，两列图标 + 文字。 */
@CustomDialog
struct MaskPickerDialog {
  controller?: CustomDialogController;
  onPick: (tool: MaskToolOption) => void = (tool: MaskToolOption): void => {};
  @StorageProp('vividNightMode') private night: boolean = false;

  private textColor(): string {
    return this.night ? '#F4F7FC' : '#1B2536';
  }

  build() {
    Column() {
      Grid() {
        ForEach(MASK_TOOLS, (tool: MaskToolOption) => {
          GridItem() {
            Column({ space: 6 }) {
              Text(tool.glyph)
                .fontSize(20)
                .fontColor(this.textColor());
              Text(tool.label)
                .fontSize(11)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor(this.textColor());
            }
            .width('100%')
            .height(66)
            .justifyContent(FlexAlign.Center)
            .borderRadius(12)
            .backgroundColor(this.night ? 'rgba(255,255,255,0.08)' : 'rgba(20,30,50,0.05)')
            .onClick(() => {
              this.controller?.close();
              this.onPick(tool);
            });
          }
        }, (tool: MaskToolOption) => 'dlg-' + tool.label);
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .width('100%')
      // 4 行 × 66 + 3 × 10 间距，最后一行的文字不会被卡片底边切掉。
      .height(300)
      .scrollBar(BarState.Off);
    }
    .width(300)
    .padding(14)
    .borderRadius(20)
    .backgroundColor(this.night ? '#161A22' : '#FFFFFF');
  }
}

@Component
export struct MaskCapsule {
  @Consume('editSession') editSession: EditSession;
  @StorageProp('maskRevision') private revision: number = 0;
  @StorageProp('vividNightMode') private night: boolean = false;
  private picker: CustomDialogController = new CustomDialogController({
    builder: MaskPickerDialog({
      onPick: (tool: MaskToolOption): void => { this.chooseTool(tool); },
    }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    autoCancel: true,
  });
  @State private aiStatus: string = '';
  /** 当前操作中的蒙版层：非空时左侧出现快捷胶囊。 */
  @State private actionId: string = '';
  /** 展开了 +/- 号与子蒙版的那一层。 */
  @State private expandedId: string = '';
  /** 长按缩略图才弹出完整操作菜单。 */
  @StorageLink('maskMenuOpen') private menuOpen: boolean = false;
  @State private renaming: boolean = false;
  @State private renameDraft: string = '';
  /** 弹窗选类型时的落点：非空表示加到这一层的子蒙版。 */
  private pendingLayerId: string = '';
  private pendingSubtract: boolean = false;
  private aiBusy: boolean = false;
  private rangeBusy: boolean = false;
  private timer: number = -1;

  /** 新层排在前面，于是它正好出现在 + 号下方。 */
  private layers(): MaskLayer[] {
    return (this.editSession.activeLayer?.maskLayers ?? []).slice().reverse();
  }

  private findLayer(id: string): MaskLayer | null {
    const list = this.editSession.activeLayer?.maskLayers ?? [];
    for (const layer of list) {
      if (layer.id === id) return layer;
    }
    return null;
  }

  private isActive(layer: MaskLayer): boolean {
    return this.editSession.activeMaskLayer?.id === layer.id;
  }

  private chooseTool(tool: MaskToolOption): void {
    if (this.aiBusy || this.rangeBusy) return;
    // 父层 +/− 发起的添加落在该父层里，作为子蒙版；从顶部 + 发起则新建父层。
    const parentId = this.pendingLayerId;
    const mode: MaskBlendMode = this.pendingSubtract ? MaskBlendMode.SUBTRACT : MaskBlendMode.ADD;
    this.pendingLayerId = '';
    this.pendingSubtract = false;
    if (tool.ai) {
      this.createAiMask(tool.type === MaskComponentType.SKY ? AiMaskKind.SKY : AiMaskKind.SUBJECT,
        parentId, mode);
      return;
    }
    if (tool.type === MaskComponentType.RANGE) {
      this.createRangeMask(tool.range === 'color', parentId, mode);
      return;
    }
    this.createMask(tool.type, parentId, mode);
  }

  private createMask(type: MaskComponentType, parentId: string, mode: MaskBlendMode): void {
    const session = this.editSession;
    const layerId = session.activeLayer?.id ?? '';
    if (layerId.length === 0) return;
    session.pushUndo();
    if (parentId.length > 0) {
      const component = session.addMaskComponentTo(layerId, parentId, type, mode);
      if (component === null) {
        this.aiStatus = '无法添加子蒙版';
        return;
      }
      session.selectMaskLayer(parentId);
      session.selectMaskComponent(component.id);
      this.actionId = parentId;
      this.expandedId = parentId;
    } else {
      const created = session.createMaskLayer(type);
      if (created) {
        this.actionId = created.id;
        this.expandedId = created.id;
        // 新建层后要选中首个分量，工具才会切成画笔/渐变，否则笔迹落不到画布。
        if (created.components.length > 0) session.selectMaskComponent(created.components[0].id);
      }
      this.menuOpen = false;
    }
    this.afterChange();
  }

  /** 主体 / 天空：本地模型识别后把栅格挂到新建的蒙版层（或父层的子蒙版）上。 */
  private async createAiMask(kind: AiMaskKind, parentId: string, mode: MaskBlendMode): Promise<void> {
    const session = this.editSession;
    const source = session.sourcePixelMap;
    if (!source) {
      this.aiStatus = '请先打开一张照片';
      return;
    }
    const type = kind === AiMaskKind.SKY ? MaskComponentType.SKY : MaskComponentType.SUBJECT;
    this.aiBusy = true;
    this.aiStatus = '正在本地识别…';
    const generation = AiSegmentationService.currentGeneration();
    const targetLayerId = session.activeLayer?.id ?? '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const raster = await AiSegmentationService.segmentPixelMap(context.resourceManager, kind, source);
      if (generation !== AiSegmentationService.currentGeneration()) return;
      if (targetLayerId.length === 0) return;
      if (raster.width <= 0 || raster.height <= 0 || raster.alpha.length === 0) {
        this.aiStatus = '识别结果为空';
        return;
      }
      let componentId = '';
      let layerId = parentId;
      if (parentId.length > 0) {
        const component = session.addMaskComponentTo(targetLayerId, parentId, type, mode);
        if (component === null) {
          this.aiStatus = '无法添加子蒙版';
          return;
        }
        componentId = component.id;
      } else {
        const maskLayer = session.createMaskLayerOn(targetLayerId, type);
        if (!maskLayer || maskLayer.components.length === 0) {
          this.aiStatus = '无法创建蒙版层';
          return;
        }
        componentId = maskLayer.components[0].id;
        layerId = maskLayer.id;
      }
      console.info(`VIVID_PERF t=${Date.now()} event=ai_raster kind=${kind} ` +
        `raster=${raster.width}x${raster.height} image=${session.imageWidth}x${session.imageHeight} ` +
        `origin=${aiMaskOrigin(kind)}`);
      // 诊断：把栅格压成 10x10 块均值，直接看清选区在栅格里的分布。
      {
        const cols = 10;
        const rows = 10;
        const cw = Math.max(1, Math.floor(raster.width / cols));
        const ch = Math.max(1, Math.floor(raster.height / rows));
        let map = '';
        for (let ry = 0; ry < rows; ry++) {
          for (let rx = 0; rx < cols; rx++) {
            let sum = 0;
            for (let y = ry * ch; y < Math.min(raster.height, (ry + 1) * ch); y++) {
              for (let x = rx * cw; x < Math.min(raster.width, (rx + 1) * cw); x++) {
                sum += raster.alpha[y * raster.width + x];
              }
            }
            const avg = Math.round(sum / (cw * ch));
            map += avg >= 200 ? '#' : (avg >= 80 ? '+' : (avg >= 20 ? '.' : ' '));
          }
          map += '/';
        }
        console.info(`VIVID_PERF t=${Date.now()} event=ai_map raster=${raster.width}x${raster.height} map=${map}`);
      }
      const applied = session.setMaskComponentRasterFor(targetLayerId, componentId,
        aiMaskOrigin(kind), raster.modelKey, raster.width, raster.height, raster.alpha);
      if (!applied) {
        this.aiStatus = '识别结果写入失败';
        return;
      }
      const coverage = bitmapCoverage(raster.alpha);
      this.aiStatus = coverage < 0.002 ? '未识别到明显区域' : '';
      session.selectMaskLayer(layerId);
      this.actionId = layerId;
      this.expandedId = layerId;
      this.menuOpen = false;
      this.afterChange();
    } catch (error) {
      this.aiStatus = aiMaskErrorMessage(error as Object);
    } finally {
      this.aiBusy = false;
    }
  }

  /**
   * 亮度范围 / 颜色范围：按图像自身的色调分布取一个起始窗口。
   * 颜色范围在此基础上附加一个由该窗口内像素平均色得来的颜色基准。
   */
  private async createRangeMask(withColor: boolean, parentId: string, mode: MaskBlendMode): Promise<void> {
    const session = this.editSession;
    const source = session.sourcePixelMap;
    if (!source) {
      this.aiStatus = '请先打开一张照片';
      return;
    }
    this.rangeBusy = true;
    this.aiStatus = '正在分析色调…';
    try {
      const token = RangeMaskService.tokenFor(session);
      let proxy: RangeMaskProxy | null = RangeMaskService.cachedProxy(token);
      if (proxy === null) proxy = await RangeMaskService.proxyFor(source, token);
      if (proxy === null) {
        this.aiStatus = '无法读取源图';
        return;
      }
      const window = RangeMaskService.defaultWindow(proxy);
      const params = new RangeMaskData();
      params.min = window.min;
      params.max = window.max;
      params.smoothness = 0.25;
      if (withColor) {
        const base = buildRangeAlpha(proxy, params);
        const average = averageSelectedColor(proxy, base);
        if (average !== null) {
          params.colorEnabled = true;
          params.colorR = average[0];
          params.colorG = average[1];
          params.colorB = average[2];
          params.colorAmount = 0.4;
        }
      }
      const layerId = session.activeLayer?.id ?? '';
      if (layerId.length === 0) return;
      let component: MaskComponent | null = null;
      if (parentId.length > 0) {
        component = session.addMaskComponentTo(layerId, parentId, MaskComponentType.RANGE, mode);
      } else {
        const maskLayer = session.createMaskLayer(MaskComponentType.RANGE);
        component = maskLayer && maskLayer.components.length > 0 ? maskLayer.components[0] : null;
      }
      if (component === null) {
        this.aiStatus = '无法创建蒙版';
        return;
      }
      component.rangeData = params;
      if (!RangeMaskService.recompute(session, component.id, params, proxy)) {
        this.aiStatus = '范围生成失败';
        return;
      }
      const raster = component.raster;
      const coverage = raster ? bitmapCoverage(raster.alpha) : 0;
      this.aiStatus = coverage < 0.002 ? '范围选区几乎为空' : '';
      // 找出这个分量所属的蒙版层，展开它并把子蒙版露出来。
      const createdId = component.id;
      const owner = (session.activeLayer?.maskLayers ?? [])
        .find((item: MaskLayer): boolean => item.components.some((c: MaskComponent): boolean => c.id === createdId));
      const ownerId = owner ? owner.id : parentId;
      if (ownerId.length > 0) session.selectMaskLayer(ownerId);
      this.actionId = ownerId;
      this.expandedId = ownerId;
      this.menuOpen = false;
      this.afterChange();
      // 亮度范围：创建后立刻弹出「选择明亮度」卡片。
      // 颜色范围与亮度范围走同一套：一样弹选择器、一样有锚点。
      AppStorage.setOrCreate('maskRangeColorMode', withColor);
      AppStorage.setOrCreate('maskRangePickerOpen', true);
    } finally {
      this.rangeBusy = false;
    }
  }

  /** 点父层下方的 + / −：先把目标记下来，再从弹窗里选一个蒙版类型作为子蒙版。 */
  private openChildPicker(layer: MaskLayer, subtract: boolean): void {
    // 去加/减子蒙版时，「选择明亮度」卡片和取样锚点都该收起。
    AppStorage.setOrCreate('maskRangePickerOpen', false);
    AppStorage.setOrCreate('maskRangeLuma', -1);
    this.pendingLayerId = layer.id;
    this.pendingSubtract = subtract;
    this.editSession.selectMaskLayer(layer.id);
    this.picker.open();
  }

  /** 单击缩略图：选中并把该层的 +/- 号与子蒙版展开/收起。 */
  private tapLayer(layer: MaskLayer): void {
    const isCurrent = this.editSession.activeMaskLayer?.id === layer.id;
    const isExpanded = this.expandedId === layer.id;
    if (isCurrent && isExpanded) {
      // 已经切到这一层并展开：再点就是开关菜单，不再收起子级。
      this.actionId = layer.id;
      this.renaming = false;
      this.menuOpen = !this.menuOpen;
      return;
    }
    // 第一次点：切到这一层并自动展开子级（其它层的子级随之收起）。
    this.editSession.selectMaskLayer(layer.id);
    this.actionId = layer.id;
    this.renaming = false;
    this.menuOpen = false;
    this.expandedId = layer.id;
    // 这一层如果是亮度范围，选中它的范围分量并把「选择明亮度」卡片调出来。
    const rangePart = layer.components.find((item: MaskComponent): boolean =>
      item.type === MaskComponentType.RANGE);
    if (rangePart !== undefined) this.editSession.selectMaskComponent(rangePart.id);
    AppStorage.setOrCreate('maskRangePickerOpen', rangePart !== undefined);
    // 换层就把取样锚点清掉，重新取才是这一层的光值。
    AppStorage.setOrCreate('maskRangeLuma', -1);
    AppStorage.setOrCreate('maskRangeReset', Date.now());
    // 换层后必须重画叠加层，否则红色覆盖会停在上一层的状态（看起来像没画）。
    this.editSession.notifyMaskRevision();
  }

  /** 回车键：选中该蒙版并打开蒙版参数卡片（亮 / 颜色 / 效果 / 细节）。 */
  private enterLayer(layer: MaskLayer): void {
    this.editSession.selectMaskLayer(layer.id);
    this.actionId = layer.id;
    this.menuOpen = false;
    AppStorage.setOrCreate('maskCategoryRequest', 'light');
  }

  /** 子蒙版的回车键：连子选区分量一起选中，再打开参数卡片。 */
  /** 该子蒙版是否是当前的编辑分量。 */
  private isActivePart(part: MaskComponent): boolean {
    return this.editSession.activeMaskComponent?.id === part.id;
  }

  /** 点选子蒙版：切到该分量并重绘叠加层，左侧删除/反相也会作用在它身上。 */
  private selectChild(layer: MaskLayer, part: MaskComponent): void {
    this.editSession.selectMaskLayer(layer.id);
    this.editSession.selectMaskComponent(part.id);
    this.actionId = layer.id;
    this.menuOpen = false;
    this.expandedId = layer.id;
    this.editSession.notifyMaskRevision();
  }

  private enterChild(layer: MaskLayer, part: MaskComponent): void {
    this.editSession.selectMaskLayer(layer.id);
    this.editSession.selectMaskComponent(part.id);
    this.actionId = layer.id;
    this.menuOpen = false;
    AppStorage.setOrCreate('maskCategoryRequest', 'light');
  }

  /** 长按缩略图：弹出该层的操作菜单。 */
  private openMenu(layer: MaskLayer): void {    this.editSession.selectMaskLayer(layer.id);
    this.actionId = layer.id;
    this.expandedId = layer.id;
    this.renaming = false;
    this.menuOpen = true;
  }

  private runAction(action: string): void {
    const layer = this.findLayer(this.actionId);
    if (layer === null) return;
    const session = this.editSession;
    if (action === 'toggle') {
      // 隐藏 = 这一层不参与合成，但保留在列表里（缩略图变暗表示）。
      session.pushUndo();
      layer.enabled = !layer.enabled;
      session.invalidateLayerMaskCache(session.activeLayer?.id ?? '');
      session.bumpProcessing();
      this.afterChange();
      return;
    }
    if (action === 'rename') {
      this.renaming = true;
      this.renameDraft = layer.name;
      return;
    }
    if (action === 'copy' || action === 'copyInvert') {
      const copy = session.duplicateMaskLayer(layer.id, action === 'copyInvert');
      if (copy) {
        session.selectMaskLayer(copy.id);
        this.actionId = copy.id;
      }
      this.menuOpen = false;
      this.afterChange();
      return;
    }
    if (action === 'invert') {
      session.pushUndo();
      layer.inverted = !layer.inverted;
      layer.touch();
      session.invalidateLayerMaskCache(session.activeLayer?.id ?? '');
      session.bumpProcessing();
      this.afterChange();
      return;
    }
    if (action === 'delete') {
      session.deleteMaskLayer(layer.id);
      this.actionId = '';
      this.menuOpen = false;
      this.afterChange();
    }
  }

  private applyRename(): void {
    const layer = this.findLayer(this.actionId);
    const name = this.renameDraft.trim();
    if (layer === null) return;
    this.editSession.renameMaskLayer(layer.id, name.length > 0 ? name : layer.name);
    this.renaming = false;
    this.menuOpen = false;
    this.afterChange();
  }

  private afterChange(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.editSession.notifyMaskRevision();
    ImageProcessor.process(this.editSession);
  }

  private textColor(): string {
    return this.night ? '#F4F7FC' : '#1B2536';
  }

  /** 当前层已隐藏时，菜单项显示「显示」。 */
  private toggleLabel(): string {
    const layer = this.findLayer(this.actionId);
    if (layer === null) return '隐藏';
    return layer.enabled ? '隐藏' : '显示';
  }

  private capsuleFill(): ResourceColor {
    return this.night ? 'rgba(22,26,34,0.88)' : 'rgba(255,255,255,0.92)';
  }

  private capsuleStroke(): ResourceColor {
    return this.night ? 'rgba(255,255,255,0.12)' : VividNative.separator;
  }

  /** 完整操作菜单：图标 + 文字，逐行列出。 */
  @Builder
  ActionMenu() {
    Column({ space: 2 }) {
      if (this.renaming) {
        TextInput({ text: this.renameDraft, placeholder: '蒙版名称' })
          .height(26)
          .fontSize(10)
          .width('100%')
          .onChange((text: string) => { this.renameDraft = text; })
          .onSubmit(() => { this.applyRename(); });
        Row() {
          Text('确定')
            .fontSize(10)
            .fontColor('#316CF4')
            .onClick(() => { this.applyRename(); });
        }
        .width('100%')
        .height(22)
        .justifyContent(FlexAlign.End)
        .padding({ right: 4 });
      } else {
        ForEach(MASK_ACTIONS, (action: MaskActionOption) => {
          Row({ space: 9 }) {
            if (action.id === 'delete') {
              // 删除用图元画的垃圾桶，其余用字形图标。
              Row() {
                MaskTrashIcon({ color: this.night ? '#F4F7FC' : '#1B2536' });
              }
              .width(22)
              .justifyContent(FlexAlign.Center);
            } else {
              Text(action.glyph)
                .fontSize(17)
                .width(22)
                .textAlign(TextAlign.Center)
                .fontColor(this.textColor());
            }
            Text(action.id === 'toggle' ? this.toggleLabel() : action.label)
              .fontSize(13)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.textColor());
          }
          .width('100%')
          .height(38)
          .padding({ left: 8, right: 8 })
          .borderRadius(7)
          .onClick(() => { this.runAction(action.id); });
        }, (action: MaskActionOption) => 'act-' + action.id);
      }
    }
    .width(142)
    .padding(5)
    .borderRadius(14)
    .backgroundColor(this.capsuleFill())
    .border({ width: 1, color: this.capsuleStroke() })
    .shadow({ radius: 14, color: this.night ? 'rgba(0,0,0,0.4)' : 'rgba(20,30,50,0.16)', offsetY: 4 });
  }

  /** 子级蒙版 = 除第一份（父级自身的选区）以外的分量。 */
  private childParts(layer: MaskLayer): MaskComponent[] {
    return layer.components.slice(1);
  }

  @Builder
  LayerRow(layer: MaskLayer) {
    Column({ space: 3 }) {
      // 缩略图：一眼看出这一层选了哪块区域；隐藏时压暗。
      Stack() {
        CapsuleMaskThumb({ groupId: layer.id });
      }
      .width(THUMB_WIDTH)
      .height(THUMB_HEIGHT)
      .borderRadius(3)
      .clip(true)
      .opacity(layer.enabled ? 1 : 0.35)
      .backgroundColor('#000000')
      .border({
        width: this.isActive(layer) ? 2 : 1,
        color: this.isActive(layer) ? '#316CF4' : (this.night ? 'rgba(255,255,255,0.16)' : 'rgba(20,30,50,0.12)'),
      })
      .onClick(() => { this.tapLayer(layer); })
      // 长按才弹操作菜单。
      .gesture(LongPressGesture({ repeat: false, duration: 380 })
        .onAction(() => { this.openMenu(layer); }));

      if (this.expandedId === layer.id) {
        // 只有真正有子级蒙版时才出现箭头（进入该蒙版）；收起状态不显示。
        if (this.childParts(layer).length > 0) {
          Row() {
            MaskEnterIcon({ color: this.night ? '#F4F7FC' : '#1B2536', box: 16 });
          }
          .width('100%')
          .height(13)
          .justifyContent(FlexAlign.Start)
          .accessibilityText('进入蒙版')
          .onClick(() => { this.enterLayer(layer); });
        }

        // 子蒙版向下累加（新加的排在最下面），右对齐；子层之间不加箭头。
        Column({ space: 3 }) {
          ForEach(this.childParts(layer), (part: MaskComponent) => {
            Stack({ alignContent: Alignment.BottomEnd }) {
              CapsuleMaskThumb({ groupId: layer.id, partId: part.id });

              // 右下角的 +/- 角标：标明这一份子蒙版是加还是减。
              Row() {
                Text(part.blendMode === MaskBlendMode.SUBTRACT ? '−' : '+')
                  .fontSize(9)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF');
              }
              .width(10)
              .height(10)
              .borderRadius(5)
              .justifyContent(FlexAlign.Center)
              .margin({ right: 1, bottom: 1 })
              .backgroundColor(part.blendMode === MaskBlendMode.SUBTRACT
                ? 'rgba(24,32,46,0.85)' : 'rgba(49,108,244,0.95)');
            }
            .width(CHILD_WIDTH)
            .height(CHILD_HEIGHT)
            .borderRadius(2)
            .clip(true)
            .opacity(layer.enabled ? 1 : 0.35)
            .backgroundColor('#000000')
            .border({
              width: this.isActivePart(part) ? 2 : 1,
              color: this.isActivePart(part) ? '#316CF4'
                : (this.night ? 'rgba(255,255,255,0.14)' : 'rgba(20,30,50,0.10)'),
            })
            .onClick(() => { this.selectChild(layer, part); });
          }, (part: MaskComponent) => 'child-' + part.id);
        }
        .width('100%')
        .alignItems(HorizontalAlign.End);

        // +/− 始终在父层列表最下方，可以一直加子蒙版。
        Row({ space: 4 }) {
          Button() {
            Text('+')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.night ? '#F4F7FC' : '#1B2536');
          }
          .width(24)
          .height(24)
          .padding(0)
          .type(ButtonType.Circle)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor(this.night ? 'rgba(255,255,255,0.12)' : 'rgba(20,30,50,0.07)')
          .accessibilityText('添加子蒙版')
          .onClick(() => { this.openChildPicker(layer, false); });
          Button() {
            Text('−')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.night ? '#F4F7FC' : '#1B2536');
          }
          .width(24)
          .height(24)
          .padding(0)
          .type(ButtonType.Circle)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor(this.night ? 'rgba(255,255,255,0.12)' : 'rgba(20,30,50,0.07)')
          .accessibilityText('减去子蒙版')
          .onClick(() => { this.openChildPicker(layer, true); });
        }
        .width('100%')
        .height(24)
        .justifyContent(FlexAlign.Center);
      }
    }
    .width('100%')
    // 菜单内的任何按下都算「用户在操作菜单」；画布那边会根据这个时间戳
    // 决定是否关闭菜单，避免点菜单项时菜单先消失导致点击无效。
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) AppStorage.setOrCreate('maskMenuActionAt', Date.now());
    });
  }

  build() {
    Row({ space: 6 }) {
      // 再点一次缩略图才在胶囊左侧展开完整操作菜单。
      if (this.menuOpen && this.actionId.length > 0) {
        this.ActionMenu();
      }

      Column({ space: 6 }) {
        Button() {
          Text('+')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White);
        }
        .width(ADD_BUTTON)
        .height(ADD_BUTTON)
        .padding(0)
        .type(ButtonType.Circle)
        .backgroundColor('#316CF4')
        .accessibilityText('新建蒙版')
        .onClick(() => {
          // 顶部 + = 新建父级蒙版；父层下方的 +/- 才加子蒙版。
          this.pendingLayerId = '';
          this.pendingSubtract = false;
          this.picker.open();
        });

        if (this.aiStatus.length > 0) {
          Text(this.aiStatus)
            .fontSize(8)
            .maxLines(2)
            .textAlign(TextAlign.Center)
            .fontColor(VividNative.textTertiary);
        }

        if (this.layers().length > 0) {
          Scroll() {
            Column({ space: 5 }) {
              ForEach(this.layers(), (layer: MaskLayer) => { this.LayerRow(layer); },
                (layer: MaskLayer) => layer.id + ':' + layer.components.length + ':' + (layer.enabled ? 1 : 0) + ':' + (this.expandedId === layer.id ? 'open' : 'shut'));
            }
            .width('100%');
          }
          .width('100%')
          // 层数多了以后胶囊自己在内部滚，不再一路顶到预览顶部。
          .constraintSize({ maxHeight: 240 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None);
        }
      }
      .width(CAPSULE_WIDTH)
      .padding(5)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(14)
      .backgroundColor(this.capsuleFill())
      .border({ width: 1, color: this.capsuleStroke() })
      .shadow({ radius: 14, color: this.night ? 'rgba(0,0,0,0.4)' : 'rgba(20,30,50,0.14)', offsetY: 4 })
      .id('mask-capsule-' + this.revision);
    }
    .alignItems(VerticalAlign.Bottom)
    .onAreaChange((_old: Area, area: Area) => {
      const x = Number(area.position.x);
      const y = Number(area.position.y);
      const w = Number(area.width);
      const h = Number(area.height);
      if (!Number.isFinite(x) || !Number.isFinite(y) || w <= 0 || h <= 0) return;
      AppStorage.setOrCreate('maskUiRectCapsule', `${x},${y},${w},${h}`);
    });
  }
}
