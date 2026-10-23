import { EditSession } from '../edit/models/EditSession';
import { promptAction } from '@kit.ArkUI';
import { ADJUSTMENT_DEFS, AdjustmentDef, ColorAdjustments } from '../edit/models/Adjustment';
import { DenoiseSettings } from '../edit/models/DenoiseSettings';
import { DetailSettings } from '../edit/models/DetailSettings';
import { OpticsSettings } from '../edit/models/OpticsSettings';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { DesktopRawSlider } from './DesktopRawSlider';
import { AdjustmentPanel } from './AdjustmentPanel';
import { ToneCurveControl } from './ToneCurveControl';
import { ColorMixerControl } from './ColorMixerControl';
import { ColorGradingPanel } from './ColorGradingPanel';
import { CalibrationPanel } from './CalibrationPanel';
import { DisclosureChevron } from './DisclosureChevron';
import { BlackWhitePanel } from './BlackWhitePanel';
import { BokehPanel } from './BokehPanel';
import { VividNative } from './VividNativeTheme';
import {
  DEVELOP_SECTIONS, DevelopSection, isDevelopSectionVisible, isWholeFrameSection,
} from '../edit/models/DevelopSections';
import {
  PROCESS_VERSION_CURRENT, ProcessVersionNote, isLatestProcessVersion,
  legacyPinnedBehaviors, processVersionLabel, processVersionSummary,
} from '../edit/models/ProcessVersion';

const DESKTOP_LIGHT_KEYS: string[] = ['exposure', 'contrast', 'highlights', 'shadows', 'whites', 'blacks'];
const DESKTOP_COLOR_KEYS: string[] = ['temperature', 'tint', 'vibrance', 'saturation', 'hue'];

/** 手机端分类导航项：图标 + 文字。glyphSize 用来把不同字形的墨迹大小调成一致。 */
interface DevelopCategory {
  id: string;
  title: string;
  glyph: string;
  glyphSize: number;
  /** 字形基线补偿（vp）：∿ ⌗ 这类字形的墨迹天然偏下，往上提一点才和其它图标齐平。 */
  glyphDy?: number;
}

/**
 * 手机端调色分类顺序。「黑白」按需求暂时从手机导航里移除
 * （底层能力与平板折叠列表都保留，不影响参数读写）。
 */
const PHONE_CATEGORIES: DevelopCategory[] = [
  { id: 'light', title: '亮', glyph: '☼', glyphSize: 17, glyphDy: -1 },
  { id: 'color', title: '颜色', glyph: '◐', glyphSize: 14 },
  { id: 'effects', title: '效果', glyph: '✦', glyphSize: 13, glyphDy: 2 },
  { id: 'curve', title: '曲线', glyph: '∿', glyphSize: 20, glyphDy: -5 },
  { id: 'mixer', title: '混色器', glyph: '◍', glyphSize: 15, glyphDy: 1 },
  { id: 'grading', title: '颜色分级', glyph: '◑', glyphSize: 14 },
  { id: 'detail', title: '细节', glyph: '◈', glyphSize: 15, glyphDy: 1 },
  { id: 'optics', title: '光学', glyph: '◎', glyphSize: 17, glyphDy: 3 },
  { id: 'calibration', title: '校准', glyph: '⌗', glyphSize: 15, glyphDy: -6.5 },
  { id: 'bokeh', title: '大光圈模拟', glyph: '◉', glyphSize: 15, glyphDy: -1 },
];

/** Desktop-only Camera Raw organisation; preserves the existing engine/units. */
@Component
export struct DesktopDevelopPanel {
  @Consume('editSession') editSession: EditSession;
  @Prop maskContext: boolean = false;
  @Prop showProfile: boolean = true;
  @StorageProp('vividNightMode') private night: boolean = false;
  @StorageProp('maskRevision') private controlsRevision: number = 0;
  @StorageProp('toneControlRevision') private toneControlsRevision: number = 0;
  /** 手机端：分类图标行 + 从底部向上弹出的参数卡片（平板/桌面仍是折叠列表）。 */
  @Prop compactPhone: boolean = false;
  /**
   * 蒙版面板的导航行：只保留 亮/颜色/效果/细节，且没有选中蒙版时整行灰色不可点。
   */
  @Prop maskCategories: boolean = false;
  @StorageProp('maskCategoryOpen') private maskCategoryOpen: boolean = false;
  /** 手动白平衡取点模式（画布上挂着锚点），按钮文案随之切换成「完成」。 */
  @StorageProp('wbPicking') private wbPicking: boolean = false;
  /** 外部（蒙版胶囊）请求展开某个分类：改成非空值即打开对应卡片。 */
  @StorageProp('maskCategoryRequest') @Watch('applyCategoryRequest') private categoryRequest: string = '';
  /** 当前展开的手机分类 id；空串表示卡片收起。 */
  @State private activeCategory: string = '';
  @State private expandedSections: string[] = ['light'];
  @State private vignetteOpen: boolean = false;
  @State private grainOpen: boolean = false;
  @State private manualNoiseOpen: boolean = true;
  @State private detailEffectsOpen: boolean = true;
  private timer: number = -1;

  build() {
    if (this.compactPhone) {
      this.CompactPanel();
    } else {
      this.DesktopSections();
    }
  }

  /** 平板/桌面：原来的折叠分区列表，行为不变。 */
  @Builder
  private DesktopSections() {
    Column() {
      if (this.showProfile && !this.maskContext) {
        AdjustmentPanel({ profileOnly: true, externalScroll: true, desktopAccordion: true });
      }
      ForEach(DEVELOP_SECTIONS.filter((section: DevelopSection): boolean =>
        isDevelopSectionVisible(section.id, this.maskContext)), (section: DevelopSection) => {
        this.SectionHeader(section);
        if (this.expandedSections.indexOf(section.id) >= 0) {
          Column() {
            this.SectionBody(section.id);
          }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 18 });
        }
      }, (section: DevelopSection) => section.id + ':' + this.controlsRevision + ':' + this.toneControlsRevision);
    }.width('100%').alignItems(HorizontalAlign.Start);
  }

  /**
   * 分区内容。折叠列表和手机端弹出卡片共用这一套控件，
   * 只换容器，不动任何参数读写逻辑。
   */
  @Builder
  private SectionBody(sectionId: string) {
    if (sectionId === 'light') {
      ForEach(DESKTOP_LIGHT_KEYS, (key: string) => { this.AdjustmentControl(key); }, (key: string) => key);
    } else if (sectionId === 'color') {
      if (!this.maskContext) this.WhiteBalanceRow();
      ForEach(DESKTOP_COLOR_KEYS, (key: string) => { this.AdjustmentControl(key); }, (key: string) => key);
    } else if (sectionId === 'effects') {
      this.AdjustmentControl('vignetteAmount');
      this.EffectDisclosure('晕影设置', 'vignette', this.vignetteOpen);
      if (this.vignetteOpen) {
        this.AdjustmentControl('vignetteMidpoint'); this.AdjustmentControl('vignetteRoundness');
        this.AdjustmentControl('vignetteFeather'); this.AdjustmentControl('vignetteHighlights');
      }
      this.AdjustmentControl('grainAmount');
      this.EffectDisclosure('颗粒设置', 'grain', this.grainOpen);
      if (this.grainOpen) { this.AdjustmentControl('grainSize'); this.AdjustmentControl('grainRoughness'); }
    } else if (sectionId === 'curve') {
      ToneCurveControl({ maskContext: this.maskContext, embedded: true, externalScroll: true });
      // Parametric curve, in Camera Raw's order: the four region amounts,
      // then the three splits, then saturation refinement.
      this.AdjustmentControl('parametricHighlights');
      this.AdjustmentControl('parametricLights');
      this.AdjustmentControl('parametricDarks');
      this.AdjustmentControl('parametricShadows');
      this.AdjustmentControl('parametricShadowSplit');
      this.AdjustmentControl('parametricDarkSplit');
      this.AdjustmentControl('parametricLightSplit');
      this.AdjustmentControl('parametricRefineSaturation');
    } else if (sectionId === 'mixer') {
      ColorMixerControl({ maskContext: this.maskContext, embedded: true, externalScroll: true });
    } else if (sectionId === 'grading') {
      ColorGradingPanel({ maskContext: this.maskContext, embedded: true, externalScroll: true });
    } else if (sectionId === 'calibration') {
      CalibrationPanel({ maskContext: this.maskContext, embedded: true, externalScroll: true });
      // Process version is a document-level setting, so it sits in the
      // same section Camera Raw keeps it in and never shows for a mask.
      if (!this.maskContext) this.ProcessVersionRow();
    } else if (sectionId === 'detail') {
      Row() {
        Text('手动降噪').fontSize(12).fontColor(this.textColor()); Blank();
        DisclosureChevron({ expanded: this.manualNoiseOpen });
      }.width('100%').height(30).alignItems(VerticalAlign.Center)
        .focusable(true).focusBox(VividNative.focusBox()).hoverEffect(HoverEffect.Highlight)
        .onClick(() => { this.manualNoiseOpen = !this.manualNoiseOpen; });
      if (this.manualNoiseOpen) {
        this.NoiseControl('亮度', 'luminance', 0); this.NoiseControl('亮度细节', 'detail', 0);
        this.NoiseControl('亮度对比度', 'luminanceContrast', -1);
        this.NoiseControl('颜色', 'color', 0); this.NoiseControl('颜色细节', 'colorDetail', 0);
        this.NoiseControl('颜色平滑', 'colorSmoothness', 0);
      }
      Row() {
        Text('纹理与锐化').fontSize(12).fontColor(this.textColor()); Blank();
        DisclosureChevron({ expanded: this.detailEffectsOpen });
      }.width('100%').height(30).alignItems(VerticalAlign.Center)
        .focusable(true).focusBox(VividNative.focusBox()).hoverEffect(HoverEffect.Highlight)
        .onClick(() => { this.detailEffectsOpen = !this.detailEffectsOpen; });
      if (this.detailEffectsOpen) {
        this.DetailControl('纹理', 'texture', -1);
        this.DetailControl('清晰度', 'clarity', -1);
        this.DetailControl('去朦胧', 'dehaze', -1);
        this.DetailControl('锐化', 'sharpenAmount', 0);
        this.DetailControl('锐化半径', 'sharpenRadius', 0);
        this.DetailControl('锐化细节', 'sharpenDetail', 0);
        this.DetailControl('锐化蒙版', 'sharpenMasking', 0);
      }
    } else if (sectionId === 'optics') {
      // Lens corrections. Distortion/CA/vignette depth are signed because
      // each has a meaningful inverse; the fringe amounts are not, and the
      // vignette midpoint only shapes where the falloff happens.
      this.OpticsControl('畸变', 'distortion', -1);
      this.OpticsControl('横向色差', 'chromaticAberration', -1);
      this.OpticsControl('紫边', 'defringePurple', 0);
      this.OpticsControl('绿边', 'defringeGreen', 0);
      this.OpticsControl('暗角', 'vignetteAmount', -1);
      this.OpticsControl('暗角中点', 'vignetteMidpoint', 0);
    } else if (sectionId === 'black-white') {
      if (!this.maskContext) BlackWhitePanel();
    } else if (sectionId === 'bokeh') {
      if (!this.maskContext) BokehPanel();
    }
  }

  /** 手机端：底部一行图标+文字分类导航，点开的内容从底部向上弹出成卡片。 */
  @Builder
  private CompactPanel() {
    Column() {
      Stack({ alignContent: Alignment.Bottom }) {
        // 未选中分类时面板留白，不放任何占位/空态提示。
        if (this.activeCategory.length > 0) {
          this.CategoryCard();
        }
      }
      .width('100%')
      .layoutWeight(1);

      this.CategoryBar();
    }
    .width('100%')
    .height('100%');
  }

  /** 弹出的参数卡片：标题 + 分区重置 + 关闭，正文复用 SectionBody。 */
  @Builder
  private CategoryCard() {
    Column() {
      Row() {
        Text(this.categoryTitle(this.activeCategory))
          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.textColor());
        Blank();
        Button('重置')
          .fontSize(10)
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .controlSize(ControlSize.SMALL)
          .height(26)
          .padding({ left: 8, right: 8 })
          .margin({ right: 4 })
          .onClick(() => { this.resetSection(this.activeCategory); });
        Text('✕')
          .fontSize(13).fontColor(VividNative.textSecondary)
          .width(28).height(28).textAlign(TextAlign.Center)
          .borderRadius(14)
          .onClick(() => { this.closeCategory(); });
      }
      .width('100%')
      .height(42)
      .padding({ left: 16, right: 12 })
      .border({ width: { bottom: 1 }, color: VividNative.divider });

      Scroll() {
        Column() {
          this.ActiveBody();
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 });
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .scrollBarWidth(8)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.TopStart);
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.night ? '#14181F' : '#FFFFFF')
    .borderRadius({ topLeft: 18, topRight: 18 })
    .shadow({ radius: 24, color: VividNative.shadowSm, offsetY: -6 })
    .clip(true)
    // 卡片从底部往上滑入，收起时反向淡出。
    .transition(
      TransitionEffect.OPACITY
        .animation({ duration: 150, curve: Curve.EaseOut })
        .combine(
          TransitionEffect.translate({ y: 48 })
            .animation({ duration: 220, curve: Curve.FastOutSlowIn })
        )
    );
  }

  /**
   * 当前分类正文。这里必须用「字面量分支」而不是 SectionBody(this.activeCategory)：
   * @Builder 按值传参会被冻结成首次渲染时的值，切分类时标题变了、滑杆却还是旧的那一组。
   */
  @Builder
  private ActiveBody() {
    if (this.activeCategory === 'light') {
      this.SectionBody('light');
    } else if (this.activeCategory === 'color') {
      this.SectionBody('color');
    } else if (this.activeCategory === 'effects') {
      this.SectionBody('effects');
    } else if (this.activeCategory === 'curve') {
      this.SectionBody('curve');
    } else if (this.activeCategory === 'mixer') {
      this.SectionBody('mixer');
    } else if (this.activeCategory === 'grading') {
      this.SectionBody('grading');
    } else if (this.activeCategory === 'detail') {
      if (this.maskContext) {
        // 细节属整幅处理（WHOLE_FRAME_ONLY），蒙版不单独支持，给一句明确说明
        // 而不是弹出一张空白卡片。
        Text('细节（锐化 / 降噪）作用于整幅画面，蒙版暂不支持单独调整。')
          .fontSize(12)
          .lineHeight(20)
          .fontColor(VividNative.textSecondary)
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 });
      } else {
        this.SectionBody('detail');
      }
    } else if (this.activeCategory === 'optics') {
      this.SectionBody('optics');
    } else if (this.activeCategory === 'calibration') {
      this.SectionBody('calibration');
    } else if (this.activeCategory === 'bokeh') {
      this.SectionBody('bokeh');
    }
  }

  /**
   * 分类导航：严格一行。用 layoutWeight 平分宽度而不是固定宽度，
   * 这样不管屏幕多窄，十个分类都在一行里，不会换行也不会需要横滑。
   */
  @Builder
  private CategoryBar() {
    Row() {
      ForEach(this.categoryList(), (item: DevelopCategory) => {
        Column({ space: 1 }) {
          // 图标放进固定尺寸的 Stack 居中，十个分类的图标与文字才会在同一条水平线上。
          Stack({ alignContent: Alignment.Center }) {
            Text(item.glyph)
              .fontSize(item.glyphSize)
              .offset({ y: item.glyphDy ?? 0 })
              .fontColor(this.activeCategory === item.id ? VividNative.textPrimary : VividNative.textSecondary);
          }
          .width('100%')
          .height(18);

          Text(this.barLabel(item))
            .fontSize(8)
            .height(12)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .fontColor(this.activeCategory === item.id ? VividNative.textPrimary : VividNative.textTertiary);
        }
        .layoutWeight(1)
        .height(46)
        .justifyContent(FlexAlign.Center)
        .borderRadius(10)
        // 蒙版面板：还没选中蒙版时整行灰色、点不动。
        .opacity(this.categoriesEnabled() ? 1 : 0.35)
        .backgroundColor(this.activeCategory === item.id
          ? (this.night ? 'rgba(255,255,255,0.10)' : 'rgba(20,30,50,0.07)') : Color.Transparent)
        .onClick(() => {
          if (!this.categoriesEnabled()) return;
          this.toggleCategory(item.id);
        });
      }, (item: DevelopCategory) => item.id);
    }
    .width('100%')
    .height(56)
    .padding({ left: 2, right: 2 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { top: 1 }, color: VividNative.divider });
  }

  /** 蒙版导航行的分类：只留 亮/颜色/效果/细节。 */
  private categoryList(): DevelopCategory[] {
    if (this.maskCategories) {
      return PHONE_CATEGORIES.filter((item: DevelopCategory): boolean =>
        item.id === 'light' || item.id === 'color' ||
          item.id === 'effects' || item.id === 'detail');
    }
    return PHONE_CATEGORIES.filter((item: DevelopCategory): boolean =>
      isDevelopSectionVisible(item.id, this.maskContext));
  }

  /** 蒙版面板要选中一个蒙版图层之后才可用。 */
  private categoriesEnabled(): boolean {
    return !(this.maskContext && this.editSession.activeMaskLayer === null);
  }
  /** 导航行放不下的长名字用短标签（大光圈模拟 → 大光圈），分类标题仍用全称。 */
  private barLabel(item: DevelopCategory): string {
    return item.id === 'bokeh' ? '大光圈' : item.title;
  }

  private categoryTitle(id: string): string {
    for (const item of PHONE_CATEGORIES) {
      if (item.id === id) return item.title;
    }
    return '调色';
  }

  /** Storage 复位总线：与 PhoneLayout 主重置共用同一个 key，让 ToneCurveControl
   * 等监听者在分区重置后同步重绘（分区 curve 用）。 */
  @StorageLink('adjustmentResetRevision') private sectionResetRevision: number = 0;

  /**
   * 分区级重置。分区与参数组的对应关系：
   * - 亮/颜色/效果/曲线 → ColorAdjustments 上的对应字段组；
   * - 混色器 → mix 三通道数组；颜色分级 → grading 字段组；校准 → calibration 字段组；
   * - 细节 → detail + denoise（该分区同时承载手动降噪与纹理锐化）；
   * - 光学 → optics。
   * 曲线/参数曲线的点表重置走 ColorAdjustments 的 defaultCurve。
   */
  private resetSection(sectionId: string): void {
    // Whole-frame sections are not reachable from a mask panel (the section
    // list hides them), but a reset must not fall through to the document if it
    // is ever invoked there: resetting "optical" from a mask would wipe the
    // photo's lens correction instead of the mask's settings.
    if (this.maskContext && isWholeFrameSection(sectionId)) return;
    const adj = this.editSession.adjustmentsForContext(this.maskContext);
    if (!adj) return;
    this.editSession.pushUndo();
    if (sectionId === 'light') {
      adj.exposure = 0; adj.contrast = 0; adj.brightness = 0;
      adj.highlights = 0; adj.shadows = 0; adj.whites = 0; adj.blacks = 0;
    } else if (sectionId === 'color') {
      adj.temperature = 0; adj.tint = 0; adj.vibrance = 0; adj.saturation = 0; adj.hue = 0;
    } else if (sectionId === 'effects') {
      adj.vignetteAmount = 0; adj.vignetteMidpoint = 0.5; adj.vignetteRoundness = 0;
      adj.vignetteFeather = 0.8; adj.vignetteHighlights = 0;
      adj.grainAmount = 0; adj.grainSize = 0.5; adj.grainRoughness = 0.5;
    } else if (sectionId === 'curve') {
      adj.toneCurve = 0; adj.curveRed = 0; adj.curveGreen = 0; adj.curveBlue = 0;
      adj.toneCurvePoints = ColorAdjustments.defaultCurve();
      adj.redCurvePoints = ColorAdjustments.defaultCurve();
      adj.greenCurvePoints = ColorAdjustments.defaultCurve();
      adj.blueCurvePoints = ColorAdjustments.defaultCurve();
      adj.parametricHighlights = 0; adj.parametricLights = 0;
      adj.parametricDarks = 0; adj.parametricShadows = 0;
      adj.parametricShadowSplit = 0.25; adj.parametricDarkSplit = 0.5;
      adj.parametricLightSplit = 0.75; adj.parametricRefineSaturation = 1;
      // ToneCurveControl 画布监听这个总线，收到后重绘曲线。
      this.sectionResetRevision++;
    } else if (sectionId === 'mixer') {
      adj.mixHue = [0, 0, 0, 0, 0, 0, 0, 0];
      adj.mixSaturation = [0, 0, 0, 0, 0, 0, 0, 0];
      adj.mixLuminance = [0, 0, 0, 0, 0, 0, 0, 0];
      // 点颜色已并入混色器：分区重置时一并清空整帧阶段的取样色。
      // 蒙版上下文里混色器仍可重置，但点颜色是整帧阶段，绝不能从这里写全局状态。
      if (!this.maskContext) this.editSession.pointColor.clear();
    } else if (sectionId === 'grading') {
      adj.colorGradingEnabled = true;
      adj.gradingShadowsHue = 0; adj.gradingShadowsSaturation = 0; adj.gradingShadowsLuminance = 0;
      adj.gradingMidtonesHue = 0; adj.gradingMidtonesSaturation = 0; adj.gradingMidtonesLuminance = 0;
      adj.gradingHighlightsHue = 0; adj.gradingHighlightsSaturation = 0; adj.gradingHighlightsLuminance = 0;
      adj.gradingGlobalHue = 0; adj.gradingGlobalSaturation = 0; adj.gradingGlobalLuminance = 0;
      adj.gradingBlending = 0; adj.gradingBalance = 0;
    } else if (sectionId === 'calibration') {
      adj.calibrationRedHue = 0; adj.calibrationRedSaturation = 0;
      adj.calibrationGreenHue = 0; adj.calibrationGreenSaturation = 0;
      adj.calibrationBlueHue = 0; adj.calibrationBlueSaturation = 0;
    } else if (sectionId === 'detail') {
      this.editSession.detail = new DetailSettings();
      this.editSession.denoise = new DenoiseSettings();
    } else if (sectionId === 'optics') {
      this.editSession.optics = new OpticsSettings();
    } else if (sectionId === 'black-white') {
      this.editSession.blackWhite.reset();
    } else if (sectionId === 'bokeh') {
      this.editSession.bokeh.reset();
      this.editSession.clearBokehDepth();
      AppStorage.setOrCreate('bokehFocusPicking', false);
      AppStorage.setOrCreate('bokehDepthStatus', '中心对焦（未生成 AI 深度图）');
      AppStorage.setOrCreate('bokehRevision', Date.now());
      AppStorage.setOrCreate('bokehDepthVersion', Date.now());
    }
    // maskRevision 总线驱动本面板 ForEach key 重算（所有滑杆/数值框回到新值），
    // 同时清蒙版缓存；flushRender 刷新预览。
    this.editSession.invalidateMaskCache();
    this.editSession.bumpProcessing();
    this.flushRender();
  }

  @Builder
  private SectionHeader(section: DevelopSection) {
    Row() {
      DisclosureChevron({ expanded: this.expandedSections.indexOf(section.id) >= 0 }).margin({ right: 6 });
      Text(section.title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.textColor()).layoutWeight(1);
      // 分区级重置：只还原该分区下的参数，不影响其它分区。
      Button('重置')
        .fontSize(10)
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .controlSize(ControlSize.SMALL)
        .height(26)
        .padding({ left: 8, right: 8 })
        .margin({ right: 8 })
        .onClick(() => {
          this.resetSection(section.id);
        });
    }.id('raw-section-' + section.id).width('100%').height(42).alignItems(VerticalAlign.Center)
      .padding({ left: 20, right: 18 })
      // 日间模式去掉分区头的白色填充（用户要求），只留系统分隔线；
      // 夜间保留系统次级底色，避免白字落在透出的画面上。
      .border({ width: { top: 1 }, color: VividNative.divider })
      .backgroundColor(this.night ? VividNative.surfaceSub : Color.Transparent)
      // PC 键盘导航与鼠标悬停走原生反馈（焦点框 + 系统悬停高亮）。
      .focusable(true)
      .focusBox(VividNative.focusBox())
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        this.expandedSections = this.expandedSections.indexOf(section.id) >= 0 ?
          this.expandedSections.filter((id: string): boolean => id !== section.id) : this.expandedSections.concat([section.id]);
      });
  }

  @Builder
  private AdjustmentControl(key: string) {
    ForEach(ADJUSTMENT_DEFS.filter((def: AdjustmentDef): boolean => def.key === key), (def: AdjustmentDef) => {
      DesktopRawSlider({ label: def.label, controlId: (this.maskContext ? 'mask-' : '') + key,
        currentValue: this.editSession.adjustmentsForContext(this.maskContext)?.getValue(key) ?? 0, gradientType: key,
        lower: def.min, upper: def.max, increment: def.step, displayScale: key === 'exposure' ? 2 : (key === 'hue' ? 1 : 100),
        decimals: key === 'exposure' ? 2 : 0,
        onBegin: () => { this.editSession.pushUndo(); },
        onUpdate: (v: number) => {
          const adj = this.editSession.adjustmentsForContext(this.maskContext);
          if (!adj) return;
          adj.setValue(key, v); this.scheduleRender();
        }, onEnd: () => { this.flushRender(); },
      });
    }, (def: AdjustmentDef) => def.key);
  }

  /**
   * 颜色面板顶部的白平衡快捷行：自动（读源图估计光源色）与手动（画布上拖锚点取点）。
   * 自动只作用于整帧，蒙版上下文里不出现。
   */
  @Builder
  private WhiteBalanceRow() {
    Row() {
      Text('白平衡').fontSize(12).fontColor(this.textColor()).layoutWeight(1);
      Row() {
        Text('自动').fontSize(12).fontColor(this.textColor());
      }
      .height(28).padding({ left: 16, right: 16 }).borderRadius(14)
      .backgroundColor(this.night ? '#232A34' : '#EFF1F4')
      .focusable(true).focusBox(VividNative.focusBox())
      .onClick(() => { this.applyAutoWhiteBalance(); });
      Row() {
        Text(this.wbPicking ? '完成' : '手动').fontSize(12)
          .fontColor(this.wbPicking ? VividNative.onEmphasize : this.textColor());
      }
      .height(28).padding({ left: 16, right: 16 }).borderRadius(14)
      .margin({ left: 8 })
      .backgroundColor(this.wbPicking ? VividNative.emphasize : (this.night ? '#232A34' : '#EFF1F4'))
      .focusable(true).focusBox(VividNative.focusBox())
      .onClick(() => { this.toggleManualWhiteBalance(); });
    }.width('100%').height(36).alignItems(VerticalAlign.Center);
  }

  /** 手动白平衡：按下时记一次撤销点并挂出锚点，再按（此时显示「完成」）收起锚点。 */
  private toggleManualWhiteBalance(): void {
    if (this.maskContext) return;
    if (this.wbPicking) {
      AppStorage.setOrCreate('wbPicking', false);
      return;
    }
    this.editSession.pushUndo();
    AppStorage.setOrCreate('wbPicking', true);
    promptAction.showToast({ message: '把锚点拖到画面中的白色或中性灰区域', duration: 2000 });
  }

  /** 自动白平衡：读写整帧调整。取不到源图像素时保持原值，不写半成品参数。 */
  private async applyAutoWhiteBalance(): Promise<void> {
    if (this.maskContext) return;
    const applied = await ImageProcessor.autoWhiteBalance(this.editSession);
    if (!applied) {
      console.warn('VIVID_PERF event=auto_wb_failed');
      return;
    }
    this.flushRender();
  }

  @Builder
  private ProcessVersionRow() {
    Column() {
      Row() {
        Text('处理版本').fontSize(12).fontColor(this.textColor()).layoutWeight(1);
        Text(processVersionLabel(this.editSession.processVersion))
          .fontSize(12).fontColor(VividNative.textSecondary);
      }.width('100%').height(30).alignItems(VerticalAlign.Center);
      if (!isLatestProcessVersion(this.editSession.processVersion)) {
        Text(processVersionSummary(this.editSession.processVersion))
          .fontSize(10).fontColor(VividNative.textTertiary).width('100%');
        // State exactly what the old generation holds fixed rather than
        // implying the two are interchangeable.
        ForEach(legacyPinnedBehaviors(), (note: ProcessVersionNote) => {
          Text('· ' + note.title + '：' + note.detail)
            .fontSize(10).fontColor(VividNative.textTertiary).width('100%').margin({ top: 2 });
        }, (note: ProcessVersionNote) => note.title);
        // 原生次要按钮：形状/圆角/填充/文字色交给 ButtonStyleMode.NORMAL + ControlSize.SMALL。
        Button('更新到当前处理版本')
          .fontSize(12).height(30).width('100%').margin({ top: 6 })
          .buttonStyle(ButtonStyleMode.NORMAL)
          .controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo();
            this.editSession.processVersion = PROCESS_VERSION_CURRENT;
            this.flushRender();
          });
      }
    }.width('100%').alignItems(HorizontalAlign.Start);
  }

  @Builder
  private EffectDisclosure(label: string, id: string, expanded: boolean) {
    Row() {
      Text(label).fontSize(11).fontColor(VividNative.textSecondary).layoutWeight(1);
      DisclosureChevron({ expanded: expanded });
    }.id('raw-effect-' + id).width('100%').height(26).alignItems(VerticalAlign.Center)
      .focusable(true).focusBox(VividNative.focusBox()).hoverEffect(HoverEffect.Highlight)
      .onClick(() => { if (id === 'vignette') this.vignetteOpen = !this.vignetteOpen; else this.grainOpen = !this.grainOpen; });
  }

  @Builder
  private NoiseControl(label: string, key: string, lower: number) {
    DesktopRawSlider({ label: label, controlId: 'noise-' + key, lower: lower, upper: 1,
      currentValue: this.noiseValue(key), onBegin: () => { this.editSession.pushUndo(); },
      onUpdate: (v: number) => {
        if (key === 'luminance') this.editSession.denoise.luminance = v;
        else if (key === 'color') this.editSession.denoise.color = v;
        else if (key === 'detail') this.editSession.denoise.detail = v;
        else if (key === 'colorDetail') this.editSession.denoise.colorDetail = v;
        else if (key === 'luminanceContrast') this.editSession.denoise.luminanceContrast = v;
        else this.editSession.denoise.colorSmoothness = v;
        this.scheduleRender();
      }, onEnd: () => { this.flushRender(); },
    });
  }

  private noiseValue(key: string): number {
    if (key === 'luminance') return this.editSession.denoise.luminance;
    if (key === 'color') return this.editSession.denoise.color;
    if (key === 'detail') return this.editSession.denoise.detail;
    if (key === 'colorDetail') return this.editSession.denoise.colorDetail;
    if (key === 'luminanceContrast') return this.editSession.denoise.luminanceContrast;
    return this.editSession.denoise.colorSmoothness;
  }

  /** Texture/clarity/dehaze are signed, so they take a -1 lower bound; the
   *  sharpening controls are unsigned. */
  @Builder
  private DetailControl(label: string, key: string, lower: number) {
    DesktopRawSlider({ label: label, controlId: 'detail-' + key, lower: lower, upper: 1,
      currentValue: this.detailValue(key), onBegin: () => { this.editSession.pushUndo(); },
      onUpdate: (v: number) => {
        if (key === 'texture') this.editSession.detail.texture = v;
        else if (key === 'clarity') this.editSession.detail.clarity = v;
        else if (key === 'dehaze') this.editSession.detail.dehaze = v;
        else if (key === 'sharpenAmount') this.editSession.detail.sharpenAmount = v;
        else if (key === 'sharpenRadius') this.editSession.detail.sharpenRadius = v;
        else if (key === 'sharpenDetail') this.editSession.detail.sharpenDetail = v;
        else this.editSession.detail.sharpenMasking = v;
        this.scheduleRender();
      }, onEnd: () => { this.flushRender(); },
    });
  }

  /** Lens corrections. `lower` is -1 for the three signed controls. */
  @Builder
  private OpticsControl(label: string, key: string, lower: number) {
    DesktopRawSlider({ label: label, controlId: 'optics-' + key, lower: lower, upper: 1,
      currentValue: this.opticsValue(key), onBegin: () => { if (!this.maskContext) this.editSession.pushUndo(); },
      onUpdate: (v: number) => {
        // 光学校正是**整帧**阶段（session.optics），不是蒙版的局部调整。蒙版面板
        // 已经不展示这个分区，这里再挡一次写入：即使将来布局又把它挂回来，局部
        // 面板也不可能改到全局镜头校正。
        if (this.maskContext) return;
        if (key === 'distortion') this.editSession.optics.distortion = v;
        else if (key === 'chromaticAberration') this.editSession.optics.chromaticAberration = v;
        else if (key === 'defringePurple') this.editSession.optics.defringePurple = v;
        else if (key === 'defringeGreen') this.editSession.optics.defringeGreen = v;
        else if (key === 'vignetteAmount') this.editSession.optics.vignetteAmount = v;
        else this.editSession.optics.vignetteMidpoint = v;
        this.scheduleRender();
      }, onEnd: () => { this.flushRender(); },
    });
  }

  private opticsValue(key: string): number {
    if (key === 'distortion') return this.editSession.optics.distortion;
    if (key === 'chromaticAberration') return this.editSession.optics.chromaticAberration;
    if (key === 'defringePurple') return this.editSession.optics.defringePurple;
    if (key === 'defringeGreen') return this.editSession.optics.defringeGreen;
    if (key === 'vignetteAmount') return this.editSession.optics.vignetteAmount;
    return this.editSession.optics.vignetteMidpoint;
  }

  private detailValue(key: string): number {    if (key === 'texture') return this.editSession.detail.texture;
    if (key === 'clarity') return this.editSession.detail.clarity;
    if (key === 'dehaze') return this.editSession.detail.dehaze;
    if (key === 'sharpenAmount') return this.editSession.detail.sharpenAmount;
    if (key === 'sharpenRadius') return this.editSession.detail.sharpenRadius;
    if (key === 'sharpenDetail') return this.editSession.detail.sharpenDetail;
    return this.editSession.detail.sharpenMasking;
  }
  /** 正文文字统一走系统主文字色：日间黑字、夜间白字由主题决定，对比度由系统保证。 */
  private textColor(): Resource { return VividNative.textPrimary; }
  private scheduleRender(): void {
    this.editSession.requestProcessing();
    if (this.timer !== -1) return;
    this.timer = setTimeout(() => { this.timer = -1; ImageProcessor.process(this.editSession); }, 33);
  }
  private flushRender(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    ImageProcessor.process(this.editSession);
  }
  /** 面板高度由 PhoneLayout 控制：没有分类展开时收成「标题 + 分类行」一行的高度。 */
  aboutToAppear(): void {
    if (!this.compactPhone) return;
    AppStorage.setOrCreate(this.openFlagKey(), this.activeCategory.length > 0);
  }

  aboutToDisappear(): void {
    if (this.compactPhone) AppStorage.setOrCreate(this.openFlagKey(), false);
    if (this.timer !== -1) this.flushRender();
  }

  /** 调色面板与蒙版面板各自一个开启标志，切换工具时高度互不影响。 */
  private openFlagKey(): string {
    return this.maskCategories ? 'maskCategoryOpen' : 'developCategoryOpen';
  }

  private toggleCategory(id: string): void {
    this.activeCategory = this.activeCategory === id ? '' : id;
    if (this.compactPhone) AppStorage.setOrCreate(this.openFlagKey(), this.activeCategory.length > 0);
  }

  private closeCategory(): void {
    this.activeCategory = '';
    if (this.compactPhone) AppStorage.setOrCreate(this.openFlagKey(), false);
  }

  /**
   * 胶囊里点了蒙版 / 回车键时，通过这个通道请求展开指定分类。
   * 消费一次后清空，这样再点同一项仍会触发。
   */
  private applyCategoryRequest(): void {
    const id = this.categoryRequest;
    if (id.length === 0) return;
    AppStorage.setOrCreate('maskCategoryRequest', '');
    if (!this.compactPhone) return;
    if (id === 'close') {
      this.activeCategory = '';
      AppStorage.setOrCreate(this.openFlagKey(), false);
      return;
    }
    if (this.maskContext && this.editSession.activeMaskLayer === null) return;
    this.activeCategory = id;
    AppStorage.setOrCreate(this.openFlagKey(), true);
  }
}
