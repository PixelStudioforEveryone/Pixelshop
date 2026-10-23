import { VividMaterial } from '../components/VividMaterial';
import { VividNative } from '../components/VividNativeTheme';
import { AdjustmentPanel } from '../components/AdjustmentPanel';
import { MaskPanel } from '../components/MaskPanel';
import { PresetsPanel } from '../components/PresetsPanel';
import { CropPanel } from '../components/CropPanel';
import { EditorCanvas } from '../components/EditorCanvas';
import { BottomToolbar } from '../components/BottomToolbar';
import { EditSession, DetailRegion } from '../edit/models/EditSession';
import { ToolType } from '../edit/models/ToolType';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { MaskComponentType } from '../edit/models/Mask';
import { DenoiseSettings } from '../edit/models/DenoiseSettings';
import { DetailSettings } from '../edit/models/DetailSettings';
import { OpticsSettings } from '../edit/models/OpticsSettings';
import { UprightSettings } from '../edit/models/UprightSettings';
import { PointColorSettings } from '../edit/models/PointColorSettings';
import { OkLChSettings } from '../edit/models/OkLChSettings';
import { BlackWhiteSettings } from '../edit/models/BlackWhiteSettings';
import { DesktopDevelopPanel } from '../components/DesktopDevelopPanel';
import { DesktopMaskPanel } from '../components/DesktopMaskPanel';
import { MaskCapsule, MaskSideActions } from '../components/MaskCapsule';
import { MaskRangeAnchor, MaskRangePicker } from '../components/MaskRangePicker';
import { MaskBrushTools } from '../components/MaskBrushTools';
import { RetouchPanel } from '../components/RetouchPanel';
import { RETOUCH_CLONE, RETOUCH_HEAL, RETOUCH_REDEYE } from '../edit/models/RetouchSettings';

/** 调色面板收起态高度：只剩一行分类导航（标题行已去掉）。 */
const COMPACT_DEVELOP_PANEL_HEIGHT: number = 56;

@Component
export struct PhoneLayout {
  @Consume('editSession') editSession: EditSession;
  onRequestDetailRender: (region: DetailRegion | null) => void = () => {};
  @State private selectedPanel: number = -1;
  /** 面板先出壳、内容延后一帧挂载：调色/图层/裁剪面板都很重，重建内容会卡住弹出动画。 */
  @State private panelBodyReady: boolean = false;
  // Shared reset bus: ToneCurveControl listens via @StorageLink because the
  // previous @Prop chain through AdjustmentPanel never fired its @Watch.
  @StorageLink('adjustmentResetRevision') private adjustmentResetRevision: number = 0;
  @State private layoutHeight: number = 0;
  @State private layoutWidth: number = 0;
  @State private maskContentHeight: number = 0;
  // Mask completion/edit actions can request a panel switch from a nested
  // component without coupling that component to the phone layout.
  @StorageProp('editorPanelRequest') @Watch('handlePanelRequest') panelRequest: number = -1;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  /** 蒙版面板的分类行是否展开（与调色面板的 developCategoryOpen 分开记）。 */
  @StorageProp('maskMenuOpen') private maskMenuOpen: boolean = false;
  @StorageProp('maskRangePickerOpen') private rangePickerOpen: boolean = false;
  @StorageProp('maskCategoryOpen') private maskCategoryOpen: boolean = false;
  // 曲线拖拽锚点期间由 ToneCurveControl 置位，用来停掉面板的纵向滚动：
  // 原始触摸事件不与 Scroll 做手势仲裁，只有停用滚动交互才能避免页面跟着动。
  @StorageProp('editorPanelScrollLock') private panelScrollLock: boolean = false;
  // 预览卡片与面板卡片之间的分界线。预览卡片吃剩余空间（layoutWeight(1)），
  // 所以改面板高度就等于反着改预览高度，中间不会留下空隙；拖动预览卡片下边缘
  // 与拖动面板卡片上沿是同一条边界。0 = 使用各面板的默认高度。
  // AppStorage 承载，切面板、进出编辑器都保留用户拉出来的高度。
  @StorageLink('vividEditorPanelHeight') private panelDragHeight: number = 0;
  /** 手机调色面板是否有分类展开：没有展开时面板收成一行，不留空白。 */
  @StorageProp('developCategoryOpen') private developCategoryOpen: boolean = false;
  @State private panelDragOrigin: number = 0;
  aboutToAppear(): void { AppStorage.setOrCreate('desktopMaskOverlay', true); }

  build() {
    Column() {
      // 原来的纵向布局整体保留：预览卡片 → 分界抓手 → 面板卡片。
      Stack({ alignContent: Alignment.BottomEnd }) {
          EditorCanvas({ onRequestDetailRender: this.onRequestDetailRender });

        Text('触摸空白处查看原图 · 双指缩放 · 拖动画布')
          .fontSize(9)
          // 日间：浅灰填充 + 主文字色；夜间：系统即时提示底色 + 纯白字。
          .fontColor(this.isNightMode ? Color.White : VividNative.textPrimary)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.isNightMode ? $r('sys.color.ohos_id_color_instant_tip_bg') : VividNative.surfaceSub)
          .backdropBlur(16)
          .borderRadius(VividNative.radiusSmallButton)
          .position({ x: 10, y: 'calc(100% - 34vp)' });

        // 蒙版工具：右侧是新建/图层胶囊，左侧是选中蒙版的删除/反相胶囊，
        // 两个胶囊都用相对坐标贴着预览卡片底部（右下 / 左下）。
        // 蒙版工具可能落在 7（手机蒙版面板）或 1/2（局部蒙版面板）上，都要出胶囊。
        if (this.selectedPanel === 7 || this.selectedPanel === 1 || this.selectedPanel === 2) {
          // 蒙版操作菜单打开时铺一层透明遮罩，点画面任意处把菜单收掉。
          Row() {
            // 画笔竖排工具列 + 删除/反相胶囊，共用左列。
            Column({ space: 8 }) {
              MaskBrushTools()
              if (this.editSession.activeMaskLayer !== null) {
                MaskSideActions()
              }
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            MaskCapsule()
          }
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 12 })
          .alignItems(VerticalAlign.Bottom)
          // 这一行只承载左右两列胶囊/工具，行本身占满整宽；不设 Transparent
          // 时它会吞掉整条预览下方的触摸，画笔在画面上就完全落不了笔。
          .hitTestBehavior(HitTestMode.Transparent)
        }

        // 亮度范围：贴在预览卡片底部弹出的「选择明亮度」卡片。
        // 亮度范围：图上的虚线双环取样锚点。
        if (this.rangePickerOpen) {
          MaskRangeAnchor()
        }
      }
      .layoutWeight(1)
      .width('calc(100% - 16vp)')
      .margin({ left: 8, right: 8, top: 8 })
      .borderRadius(VividNative.radiusPanel)
      .clip(true)
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: VividNative.separator })
      .shadow({ radius: 20, color: VividNative.shadowSm, offsetY: 8 });

      // 亮度范围：贴在「亮 / 颜色 / 效果 / 细节」导航栏上方弹出。
      if (this.rangePickerOpen) {
        MaskRangePicker()
      }

      // 分界线抓手：夹在预览卡片与面板卡片之间，只吃预览的剩余空间，不占面板
      // 内容，也不会压住照片。向上拖 = 面板变高、预览变矮；向下拖相反；双击
      // 恢复各面板的默认高度。14vp 命中区包住 40x4 的细条。
      if (this.selectedPanel >= 0) {
        Column() {
          Row() {}
          .width(40)
          .height(4)
          .borderRadius(2)
          .backgroundColor(this.isNightMode ? Color.White : VividNative.textTertiary)
          .opacity(0.5);
        }
        .width('100%')
        .height(14)
        .justifyContent(FlexAlign.Center)
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PanGesture({ fingers: 1, distance: 4 })
              .onActionStart(() => {
                this.panelDragOrigin = this.panelDragHeight > 0
                  ? this.panelDragHeight : this.getPanelDefaultHeight();
              })
              .onActionUpdate((event: GestureEvent) => {
                const available = this.layoutHeight > 0 ? this.layoutHeight : 800;
                const maxHeight = Math.max(160, available - 220);
                this.panelDragHeight = Math.max(120,
                  Math.min(maxHeight, this.panelDragOrigin - event.offsetY));
              }),
            TapGesture({ count: 2 })
              .onAction(() => { this.panelDragHeight = 0; })
          )
        );
      }



      if (this.selectedPanel >= 0) {
        Column() {
          // 调色面板（手机）不再要标题行：分类导航直接顶到面板顶部，
          // 分区级「重置」在弹出卡片里，整页重置仍在工具栏。
          if (this.selectedPanel !== 0 && this.selectedPanel !== 7) {
            Row() {
              Column() {
                if (this.getPanelEyebrow().length > 0) {
                  Text(this.getPanelEyebrow())
                    .fontSize(9)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(VividNative.textTertiary)
                    .letterSpacing(1.0);
                }
                Text(this.getPanelTitle())
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(VividNative.textPrimary)
                  .margin({ top: 2 });
              }
              .alignItems(HorizontalAlign.Start);

              Blank();

              Button('✕')
                .fontSize(14)
                .type(ButtonType.Circle)
                .buttonStyle(ButtonStyleMode.NORMAL)
                .controlSize(ControlSize.SMALL)
                .width(32)
                .height(32)
                .onClick(() => {
                  this.closePanel();
                });
            }
            .width('100%')
            .height(52)
            .padding({ left: 16, right: 12 });
          }

          Column() {
            if (this.panelBodyReady) {
              if (this.selectedPanel === 0) {
                // 手机端调色面板：底部一行「图标 + 文字」分类导航，
                // 点分类后参数卡片从面板底部向上弹出（组件内部自带滚动）。
                DesktopDevelopPanel({ compactPhone: true })
                  .height('100%')
                  .width('100%');
              } else if (this.selectedPanel === 1 || this.selectedPanel === 2) {
                Scroll() {
                  // 图层页：只显示图层列表。
                  DesktopMaskPanel({ layersOnly: true });
                }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.On)
                  .edgeEffect(EdgeEffect.None)
                  .enableScrollInteraction(!this.panelScrollLock);
              } else if (this.selectedPanel === 7) {
                // 蒙版工具：面板本体只剩一行分类（亮/颜色/效果/细节），
                // 蒙版的增删和选中交给预览卡片右下角的胶囊。
                DesktopDevelopPanel({ compactPhone: true, maskContext: true, maskCategories: true })
                  .height('100%')
                  .width('100%');
              } else if (this.selectedPanel === 3) {
                PresetsPanel();
              } else if (this.selectedPanel === 4) {
                CropPanel();
              } else if (this.selectedPanel === 5) {
                // 修复与红眼合并：类型档里含「红眼」，不再单开面板。
                Scroll() { RetouchPanel(); }
                  .height('100%').width('100%').align(Alignment.TopStart).scrollBar(BarState.Auto);
              }
            }
          }
          .layoutWeight(1)
          .width('100%');
        }
        .width('calc(100% - 16vp)')
        .height(this.getPanelHeight())
        .margin({ left: 8, right: 8, top: 8 })
        // 面板卡片改为纯色填充：日间纯白、夜间纯黑，不要毛玻璃/原生材质
        // （模糊底会把后面的照片透出来，调色参数区域看着发灰、对比不稳）。
        .backgroundColor(this.isNightMode ? '#000000' : '#FFFFFF')
        .borderRadius(VividNative.radiusPanel)
        // 与上方图片预览卡片保持同一套描边与投影。
        .border({ width: 1, color: VividNative.separator })
        .shadow({ radius: 20, color: VividNative.shadowSm, offsetY: 8 })
        .clip(true)
        .transition(
          TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.EaseOut })
            .combine(
              TransitionEffect.translate({ y: 60 })
                .animation({ duration: 240, curve: Curve.EaseOut })
            )
        );
      }

      BottomToolbar({
        selectedIndex: this.selectedPanel,
        onSelect: (index: number) => {
          this.togglePanel(index);
        },
      });
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: 4 })
    .safeAreaPadding({ bottom: 8 })
    .onAreaChange((_: Area, area: Area) => {
      const height = Number(area.height);
      const width = Number(area.width);
      if (height > 0 && Math.abs(this.layoutHeight - height) > 1) {
        this.layoutHeight = height;
        // 旋转/窗口变化后把拖出来的高度收进可用范围，别把预览挤没。
        if (this.panelDragHeight > 0 && this.panelDragHeight > height - 220) {
          this.panelDragHeight = Math.max(120, height - 220);
        }
      }
      if (width > 0 && Math.abs(this.layoutWidth - width) > 1) this.layoutWidth = width;
    })
    // 半透明浅色纱罩：让页面的图片高斯模糊背景透出。

  }

  private getPanelTitle(): string {
    switch (this.selectedPanel) {
      case 0: return '调色';
      case 1: return '图层';
      case 2: return '图层';
      case 7: return '蒙版';
      case 3: return '风格预设';
      case 4: return '裁剪与几何';
      case 5: return '修复与红眼';
      default: return '';
    }
  }

  private getPanelEyebrow(): string {
    switch (this.selectedPanel) {
      // Keep one clear title in the adjustment card; the former eyebrow made
      // the phone layout show “调色” twice.
      case 0: return '';
      case 1: return '';
      case 2: return '';
      case 7: return '';
      case 3: return '';
      case 4: return '裁剪几何';
      case 5: return '';
      default: return 'Pixelshop';
    }
  }

  private resetAdjustments(): void {
    if (this.selectedPanel !== 0 || !this.editSession.activeLayer) return;
    const adjustments = this.editSession.activeAdjustments;
    if (!adjustments) return;
    this.editSession.pushUndo();
    adjustments.reset();
    // 主重置覆盖调色页的**全部**调整组：ColorAdjustments 之外，细节/降噪/光学/
    // Upright/点颜色/OkLCh/黑白各自是独立设置对象，此前主重置从不碰它们，导致
    // "细节参数等不会重置"。全部换新实例即可回到默认值。
    this.editSession.denoise = new DenoiseSettings();
    this.editSession.detail = new DetailSettings();
    this.editSession.optics = new OpticsSettings();
    this.editSession.upright = new UprightSettings();
    this.editSession.pointColor = new PointColorSettings();
    this.editSession.oklch = new OkLChSettings();
    this.editSession.blackWhite = new BlackWhiteSettings();
    this.editSession.invalidateMaskCache();
    this.editSession.bumpProcessing();
    this.adjustmentResetRevision++;
    ImageProcessor.process(this.editSession);
  }

  /** 预览/面板分界线的高度：用户拖过就用拖出来的值，否则用面板默认高度。 */
  private getPanelHeight(): number {
    // 调色面板收起态（没点分类）不占高度，避免一块空白盖住预览。
    if (this.selectedPanel === 0 && !this.developCategoryOpen) return COMPACT_DEVELOP_PANEL_HEIGHT;
    // 蒙版面板同理：只留分类导航那一行。
    if (this.selectedPanel === 7 && !this.maskCategoryOpen) return COMPACT_DEVELOP_PANEL_HEIGHT;
    if (this.panelDragHeight > 0) return this.panelDragHeight;
    return this.getPanelDefaultHeight();
  }

  private getPanelDefaultHeight(): number {
    if (this.selectedPanel === 0) return 360;
    // Natural content + title + mask toolbar/footer, capped at half of the
    // available editor. Measuring the scroll content also handles deletion,
    // category changes, rotation and large fonts without fixed row counts.
    if (this.selectedPanel === 1 || this.selectedPanel === 2) {
      const contentHeight = 52 + 110 + this.maskContentHeight;
      // The local-mask drawer is a bottom card. Its outer height, including
      // the title and toolbar, is never allowed to exceed half of the page.
      // Keep the fallback conservative until the first area measurement.
      const pageHalf = this.layoutHeight > 0 ? this.layoutHeight * 0.5 : 320;
      return Math.min(contentHeight, Math.max(1, pageHalf));
    }
    // 蒙版调色卡片：默认不超过屏幕高度的 25%，用户可拖顶部小白杠拉高。
    if (this.selectedPanel === 7) {
      const quarter = this.layoutHeight > 0 ? this.layoutHeight * 0.25 : 200;
      return Math.max(160, Math.round(quarter));
    }
    if (this.selectedPanel === 3) return 320;
    if (this.selectedPanel === 4) return 320;
    if (this.selectedPanel === 2 && this.editSession.activeLayer?.hasMask()) return 430;
    return 300;
  }

  private handlePanelRequest(): void {
    const request = this.panelRequest === 2 ? 1 : this.panelRequest;
    if (request === -2) {
      this.closePanel();
      AppStorage.setOrCreate('editorPanelRequest', -1);
      return;
    }
    if (request !== 0 && request !== 1 && request !== 2) return;
    // 与底栏点按一致：先出壳、下一帧再挂内容。
    this.panelBodyReady = false;
    this.selectedPanel = request;
    setTimeout(() => { this.panelBodyReady = true; }, 0);
    if (request === 0) {
      this.editSession.adjustmentScope = 0;
      this.editSession.setActiveTool(ToolType.ADJUST);
      this.editSession.isCropping = false;
    } else if (request === 1) {
      this.editSession.adjustmentScope = 1;
      const component = this.editSession.activeMaskComponent;
      if (component) {
        if (component.type === MaskComponentType.BRUSH) this.editSession.setActiveTool(ToolType.BRUSH_MASK);
        else if (component.type === MaskComponentType.LINEAR_GRADIENT) this.editSession.setActiveTool(ToolType.LINEAR_MASK);
        else if (component.type === MaskComponentType.RADIAL_GRADIENT) this.editSession.setActiveTool(ToolType.RADIAL_MASK);
      }
    } else {
      this.editSession.adjustmentScope = 0;
      this.editSession.setActiveTool(ToolType.ADJUST);
    }
    // Reset the request so a later completion can request the same panel.
    AppStorage.setOrCreate('editorPanelRequest', -1);
  }

  private togglePanel(index: number): void {
    if (this.selectedPanel === 4 && index !== 4) {
      this.commitCropBeforeSwitch();
    }
    if (this.selectedPanel === index) {
      this.closePanel();
    } else {
      // 先让面板壳和弹出动画出一帧，再挂载内容（内容重建很重，会吃掉这一帧）。
      this.panelBodyReady = false;
      this.selectedPanel = index;
      this.setToolForPanel(index);
      setTimeout(() => { this.panelBodyReady = true; }, 0);
    }
  }

  private commitCropBeforeSwitch(): void {
    if (!this.editSession.isCropping) return;
    this.editSession.isCropping = false;
    this.editSession.setActiveTool(ToolType.ADJUST);
    this.editSession.bumpProcessing();
    this.editSession.requestProcessing();
    AppStorage.setOrCreate('cropOverlayRevision', this.editSession.processingVersion);
    setTimeout(() => { ImageProcessor.process(this.editSession); }, 0);
  }

  private closePanel(): void {
    const wasCropping = this.editSession.isCropping;
    this.panelBodyReady = false;
    this.selectedPanel = -1;
    this.editSession.adjustmentScope = 0;
    this.editSession.setActiveTool(ToolType.ADJUST);
    this.editSession.isCropping = false;
    if (wasCropping) {
      // Leaving the crop panel commits the current frame even when the user
      // did not press “应用裁剪”. This keeps the non-destructive crop state
      // when switching to another tool or back to the gallery.
      this.editSession.bumpProcessing();
      this.editSession.requestProcessing();
      AppStorage.setOrCreate('cropOverlayRevision', this.editSession.processingVersion);
      setTimeout(() => { ImageProcessor.process(this.editSession); }, 0);
    }
  }

  private setToolForPanel(index: number): void {
    switch (index) {
      case 0:
        this.editSession.adjustmentScope = 0;
        this.editSession.setActiveTool(ToolType.ADJUST);
        this.editSession.isCropping = false;
        break;
      case 1:
      case 7:
        this.editSession.adjustmentScope = this.editSession.activeMaskLayer ? 1 : 0;
        this.editSession.setActiveTool(ToolType.ADJUST);
        this.editSession.isCropping = false;
        break;
      case 2:
      case 3:
        this.editSession.adjustmentScope = 0;
        this.editSession.setActiveTool(ToolType.ADJUST);
        this.editSession.isCropping = false;
        break;
      case 4:
        this.editSession.enterCropMode();
        this.editSession.canvasScale = 1;
        this.editSession.canvasOffsetX = 0;
        this.editSession.canvasOffsetY = 0;
        this.editSession.requestProcessing();
        // 整幅重渲染放到下一帧：同步发起会把点按反馈帧和面板弹出动画一起卡掉。
        setTimeout(() => { ImageProcessor.process(this.editSession); }, 0);
        break;
      case 5: {
        // 修复与红眼合并：按当前类型决定画笔工具，红眼只是其中一档。
        this.editSession.adjustmentScope = 0;
        this.editSession.isCropping = false;
        const retouchKind = this.editSession.retouchKind;
        this.editSession.pickingRetouchSource =
          retouchKind === RETOUCH_HEAL || retouchKind === RETOUCH_CLONE;
        this.editSession.setActiveTool(retouchKind === RETOUCH_REDEYE ? ToolType.RED_EYE : ToolType.HEAL);
        break;
      }
    }
  }
}
