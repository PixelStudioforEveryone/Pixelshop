import { DesktopDevelopPanel } from '../components/DesktopDevelopPanel';
import { DesktopMaskPanel } from '../components/DesktopMaskPanel';
import { LayerPanel } from '../components/LayerPanel';
import { PresetsPanel } from '../components/PresetsPanel';
import { CropPanel } from '../components/CropPanel';
import { EditorCanvas } from '../components/EditorCanvas';
import { HistogramOverlay } from '../components/HistogramOverlay';
import { EditSession, DetailRegion } from '../edit/models/EditSession';
import { ToolType } from '../edit/models/ToolType';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { RecentPhotoRecord } from '../services/RecentPhotoStore';
import { RetouchPanel } from '../components/RetouchPanel';
import { VividNative } from '../components/VividNativeTheme';
@Component
export struct TabletLayout {
  @Consume('editSession') editSession: EditSession;
  @Prop photos: RecentPhotoRecord[] = [];
  @Prop currentUri: string = '';
  @Prop captureInfo: string = '';
  onRequestDetailRender: (region: DetailRegion | null) => void = () => {};
  onAddPhoto: () => void = () => {};
  onSelectPhoto: (uri: string) => void = () => {};
  onRatePhoto: (uri: string, stars: number) => void = () => {};
  @StorageProp('windowWidth') windowWidth: number = 1024;
  @StorageProp('vividNightMode') private night: boolean = false;
  @StorageProp('editorPanelRequest') @Watch('handlePanelRequest') panelRequest: number = -1;
  // 曲线/颜色分级拖拽锚点期间置位；停用检查器纵向滚动，避免拖拽变成翻页。
  @StorageProp('editorPanelScrollLock') private panelScrollLock: boolean = false;
  @State private mode: string = 'develop';
  @State private filmstripOpen: boolean = true;
  @State private minimumStars: number = 0;
  aboutToAppear(): void {
    this.editSession.ensureBaseLayer(); this.editSession.adjustmentScope = 0;
    AppStorage.setOrCreate('desktopMaskOverlay', true);
  }
  build() {
    Row() {
      Column() {
        EditorCanvas({ onRequestDetailRender: this.onRequestDetailRender }).width('100%').layoutWeight(1);
        if (this.filmstripOpen) { this.Filmstrip(); }
        this.StatusBar();
      }.layoutWeight(1).height('100%').backgroundColor(VividNative.surfaceWindow).clip(true);
      this.Inspector(); this.ToolRail();
    }.width('100%').height('100%').backgroundColor(VividNative.surfaceWindow);
  }
  @Builder
  private Filmstrip() {
    Scroll() {
      Row({ space: 6 }) {
        if (this.currentUri.length === 0 && this.editSession.sourcePixelMap) {
          Column() {
            Image(this.editSession.sourcePixelMap).width(110).height(76).objectFit(ImageFit.Contain);
            Text('快速演示').fontSize(10).fontColor(this.textColor());
          }.width(118).height(112).padding(3).border({ width: 2, color: VividNative.emphasize });
        }
        ForEach(this.filteredPhotos(), (photo: RecentPhotoRecord) => {
          Column() {
            Image(photo.thumbUri).width(110).height(76).objectFit(ImageFit.Contain)
              .backgroundColor(VividNative.componentNormal);
            Text(photo.displayName).fontSize(9).fontColor(this.textColor()).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).width(110);
            Text(this.stars(photo.rating ?? 0)).fontSize(10).fontColor(this.textColor());
          }.width(118).height(112).padding(3)
            .border({ width: 2, color: photo.uri === this.currentUri ? VividNative.emphasize : Color.Transparent })
            .id('filmstrip-' + photo.displayName).onClick(() => { this.onSelectPhoto(photo.uri); });
        }, (photo: RecentPhotoRecord) => photo.uri);
        Button('+').height(70).width(60).fontSize(28)
          // 原生文本按钮档位：透明底 + 系统按压/悬停反馈；圆角用系统令牌。
          .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
          .borderRadius(VividNative.radiusClicked).fontColor(this.textColor())
          .accessibilityText('添加多张照片').id('filmstrip-add')
          .onClick(() => { this.onAddPhoto(); });
        if (this.minimumStars > 0 && this.filteredPhotos().length === 0) {
          Text('没有符合星级的照片').fontColor(this.textColor()).fontSize(12).padding(12);
        }
      }.padding({ left: 6, right: 6 }).height(118);
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto).width('100%').height(122)
      .backgroundColor(VividNative.surfaceSub)
      .border({ width: { top: 1 }, color: VividNative.divider }).id('editor-filmstrip');
  }
  @Builder
  private StatusBar() {
    Row({ space: 2 }) {
      Button('适应').fontSize(11).height(34)
        .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
        .borderRadius(VividNative.radiusSmallButton).fontColor(this.textColor())
        .onClick(() => { this.editSession.canvasScale = 1; this.editSession.canvasOffsetX = 0;
          this.editSession.canvasOffsetY = 0; this.onRequestDetailRender(null); });
      Text(Math.round(this.editSession.canvasScale * 100) + '%').fontSize(11).fontColor(this.textColor()).width(45);
      Button(this.filmstripOpen ? '▣' : '▤').height(32).width(32).padding(0)
        .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL).borderRadius(VividNative.radiusSmallButton)
        .fontSize(20).fontColor(this.textColor()).id('filmstrip-toggle')
        .accessibilityText(this.filmstripOpen ? '隐藏缩略图' : '显示缩略图')
        .onClick(() => { this.filmstripOpen = !this.filmstripOpen; });
      Button(this.minimumStars === 0 ? '全部' : this.minimumStars + '★以上').fontSize(10).height(30)
        .padding({ left: 5, right: 5 }).buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
        .borderRadius(VividNative.radiusSmallButton).fontColor(this.textColor())
        .id('rating-filter').bindMenu(this.RatingMenu);
      ForEach([1, 2, 3, 4, 5], (star: number) => {
        // 已选星级用系统选中态文字色（原生选中反馈），未选用系统次级文字色。
        Button(star <= this.currentRating() ? '★' : '☆').width(23).height(30).padding(0).fontSize(19)
          .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
          .fontColor(star <= this.currentRating() ? VividNative.textPrimaryActivated : VividNative.textSecondary)
          .id('rating-' + star)
          .accessibilityText(star + '星').enabled(this.currentUri.length > 0).onClick(() => {
            this.onRatePhoto(this.currentUri, this.currentRating() === star ? 0 : star);
          });
      }, (star: number) => star.toString());
      Blank(); Text('预览 ' + this.editSession.previewWidth + ' × ' + this.editSession.previewHeight)
        .fontSize(10).fontColor(this.textColor()).margin({ right: 10 });
    }.width('100%').height(38).backgroundColor(VividNative.surfaceSub);
  }
  @Builder
  private RatingMenu() {
    Menu() {
      MenuItem({ content: '全部照片' }).onClick(() => { this.minimumStars = 0; });
      ForEach([1, 2, 3, 4, 5], (star: number) => {
        MenuItem({ content: star + ' 星及以上' }).onClick(() => { this.minimumStars = star; });
      }, (star: number) => star.toString());
    }
  }
  @Builder
  private Inspector() {
    Column() {
      Column() { HistogramOverlay({ allowDrag: false, chartHeight: 130 }); }
        .width('100%').height(138).padding({ left: 4, right: 4, top: 4, bottom: 4 })
        .backgroundColor(VividNative.surfaceSub).id('raw-histogram');
      Text(this.captureInfo.length > 0 ? this.captureInfo : '拍摄参数未提供')
        .fontSize(11).fontColor(this.textColor()).width('100%').height(26).textAlign(TextAlign.Center)
        .border({ width: { bottom: 1 }, color: VividNative.divider });
      Row() {
        Text(this.modeTitle()).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.textColor()).layoutWeight(1);
        if (this.mode === 'develop') {
          Button('重置').height(24).fontSize(10).padding({ left: 8, right: 8 })
            .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .borderRadius(VividNative.radiusSmallButton).onClick(() => { this.resetAdjustments(); });
        }
      }.width('100%').height(40).padding({ left: 20, right: 12 });
      Scroll() {
        Column() {
          if (this.mode === 'develop') { DesktopDevelopPanel(); }
          else if (this.mode === 'mask') { DesktopMaskPanel(); }
          else if (this.mode === 'crop') { CropPanel({ externalScroll: true }); }
          else if (this.mode === 'presets') { PresetsPanel({ externalScroll: true }); }
          else if (this.mode === 'layers') { LayerPanel({ externalScroll: true }); }
          else if (this.mode === 'heal' || this.mode === 'redeye') { RetouchPanel({ redEye: this.mode === 'redeye' }); }
        }.width('100%');
      }.width('100%').layoutWeight(1).align(Alignment.TopStart)
        .scrollBar(BarState.On).edgeEffect(EdgeEffect.None).id('raw-inspector-scroll')
        .enableScrollInteraction(!this.panelScrollLock);
    }.width(this.windowWidth >= 1180 ? 326 : 300).height('100%')
      .backgroundColor(VividNative.surfacePanel)
      .border({ width: { left: 1 }, color: VividNative.separator });
  }
  @Builder
  private ToolRail() {
    Column({ space: 2 }) {
      this.ToolButton('develop', 'editor_adjust', '基础调色');
      this.ToolButton('crop', 'editor_crop', '裁切');
      this.ToolButton('heal', 'editor_heal', '修复橡皮擦');
      this.ToolButton('mask', 'editor_mask', '蒙版');
      this.ToolButton('redeye', 'editor_redeye', '红眼修正');
      this.ToolButton('presets', 'editor_preset', 'LUT 风格预设');
      this.ToolButton('layers', 'editor_layers', '图层');
      Blank(); this.ToolButton('move', 'editor_move', '移动照片');
    }.width(42).height('100%').padding({ top: 4, bottom: 8 })
      .backgroundColor(VividNative.surfaceSub)
      .border({ width: { left: 1 }, color: VividNative.separator });
  }
  @Builder
  private ToolButton(id: string, icon: string, label: string) {
    Button() { Image($r('app.media.' + icon + (this.night ? '_night' : ''))).width(24).height(24); }
      .width(36).height(38).padding(0)
      .borderRadius(VividNative.radiusSmallButton)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .backgroundColor(Color.Transparent)
      .border({ width: this.mode === id ? 1 : 0, color: VividNative.textPrimary })
      .focusable(true).focusBox(VividNative.focusBox()).hoverEffect(HoverEffect.Highlight)
      .accessibilityText(label).id('raw-tool-' + id).onClick(() => { this.selectMode(id); });
  }
  private selectMode(id: string): void {
    if (this.editSession.isCropping && id !== 'crop') {
      this.editSession.isCropping = false; this.editSession.bumpProcessing(); ImageProcessor.process(this.editSession);
    }
    if (id === 'move') { this.editSession.setActiveTool(ToolType.ADJUST); return; }
    this.mode = id; this.editSession.adjustmentScope = id === 'mask' ? 1 : 0;
    this.editSession.pickingRetouchSource = id === 'heal';
    if (id === 'heal') this.editSession.setActiveTool(ToolType.HEAL);
    else if (id === 'redeye') this.editSession.setActiveTool(ToolType.RED_EYE);
    else if (id === 'crop') { this.editSession.enterCropMode(); ImageProcessor.process(this.editSession); }
    else if (id === 'mask' && this.editSession.activeMaskComponent) {
      this.editSession.selectMaskComponent(this.editSession.activeMaskComponent.id);
    } else this.editSession.setActiveTool(ToolType.ADJUST);
  }
  private modeTitle(): string {
    if (this.mode === 'heal') return '修复橡皮擦'; if (this.mode === 'redeye') return '红眼修正';
    if (this.mode === 'mask') return '蒙版'; if (this.mode === 'crop') return '裁切与几何';
    if (this.mode === 'presets') return '风格预设'; if (this.mode === 'layers') return '图层'; return '编辑';
  }
  private textColor(): Resource { return VividNative.textPrimary; }
  private filteredPhotos(): RecentPhotoRecord[] { return this.photos.filter((p: RecentPhotoRecord): boolean => (p.rating ?? 0) >= this.minimumStars); }
  private currentRating(): number { return this.photos.find((p: RecentPhotoRecord): boolean => p.uri === this.currentUri)?.rating ?? 0; }
  private stars(count: number): string { return '★'.repeat(Math.max(0, Math.min(5, count))) + '☆'.repeat(Math.max(0, 5 - count)); }
  private resetAdjustments(): void {
    const adj = this.editSession.adjustmentsForContext(false); if (!adj) return;
    this.editSession.pushUndo(); adj.reset(); this.editSession.notifyMaskRevision();
    this.editSession.bumpProcessing(); ImageProcessor.process(this.editSession);
  }
  private handlePanelRequest(): void {
    if (this.panelRequest === 1 || this.panelRequest === 2) this.selectMode('mask');
    else if (this.panelRequest === 0) this.selectMode('develop');
    else if (this.panelRequest === 4) this.selectMode('crop');
    AppStorage.setOrCreate('editorPanelRequest', -1);
  }
}
