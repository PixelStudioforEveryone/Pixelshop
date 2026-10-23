import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { abilityAccessCtrl, common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CustomLut } from '../../edit/models/LutLibrary';
import { PixelMapUtils } from '../../edit/utils/PixelMapUtils';
import { PhotoShareService } from '../../services/PhotoShareService';
import { EditSession } from '../../edit/models/EditSession';
import { Layer } from '../../edit/models/Layer';
import { ImageProcessor } from '../../edit/engine/ImageProcessor';
import { EditSidecar } from '../../edit/utils/EditSidecar';
import { CameraProfiles } from '../../edit/utils/CameraProfiles';
import { VividMaterial } from '../../components/VividMaterial';
import { RawPreviewLoader } from '../../edit/utils/RawPreviewLoader';
import { ExifOrientation } from '../../edit/utils/ExifOrientation';
import { PhotoItem, RECENT_THUMBNAIL_ASPECT_RATIO, RECENT_THUMBNAIL_VERSION, AppLogStore, NavColorService,
  WorksBridge, LutBridge, extensionFromName as sharedExtensionFromName,
  isRawExtension as sharedIsRawExtension, isVideoExtension as sharedIsVideoExtension } from './HomeShared';

/** 「复制参数」可勾选的参数组：按位组合后写入 copiedParamKinds。 */
const PARAM_NONE: number = 0;
const PARAM_ADJUST: number = 1;
const PARAM_CROP: number = 2;
const PARAM_MASK: number = 4;
const PARAM_PRESET: number = 8;
const PARAM_BOKEH: number = 16;

/** 快照里可被「复制参数」单独搬运的字段（与 EditSession 的快照同名）。 */
interface ParamSnapshotJson {
  retouchMarks?: Object;
  denoise?: Object;
  detail?: Object;
  detailHaze?: Object;
  optics?: Object;
  bokeh?: Object;
  upright?: Object;
  pointColor?: Object;
  oklch?: Object;
  blackWhite?: Object;
  rawSettings?: Object;
  geometry?: Object;
  cropLeft?: number;
  cropTop?: number;
  cropRight?: number;
  cropBottom?: number;
  rotation?: number;
  flipH?: boolean;
  flipV?: boolean;
  cropAspectRatio?: number;
  lutLink?: string;
  lutPresetName?: string;
  lutStack?: Object;
  layers?: ParamLayerJson[];
}

interface ParamLayerJson {
  adjustments?: Object;
  maskAdjustments?: Object;
  mask?: Object;
  maskLayers?: Object;
}

/** 一张新生成的卡片缩略图，连同它自己的构图方向。 */
interface ImportedThumb {
  uri: string;
  /** 缩略图**转过方向之后**是竖构图（高 > 宽）。卡片据此决定长宽比。 */
  portrait: boolean;
}

/** 首页「作品」页：最近修图列表、导入/分享/导出与背景图片滚动数据源。 */
@Component
export struct WorksPage {
  // 最近作品列表同时驱动「背景图片滚动」的高清背景帧，任何赋值后都要
  // 重新收集背景图（去抖合并，避免校验/删除/导入连发触发多次渲染）。
  @StorageLink('worksPhotos') @Watch('onPhotosForBackdrop') private photos: PhotoItem[] = [];
  @State private loading: boolean = false;
  @State private recentPhotoChecking: boolean = false;
  @StorageLink('worksSelectionMode') private selectionMode: boolean = false;
  @StorageLink('worksSelectedUris') private selectedUris: string[] = [];
  @StorageLink('worksSharing') private sharing: boolean = false;
  @StorageLink('homeNavCollapsed') private navCollapsed: boolean = false;
  /** 最近作品按星级过滤：0 = 全部，1..5 = 只显示该星级的照片。 */
  @State private minimumStars: number = 0;
  /** 已复制的参数组（位掩码）与快照；0 表示剪贴板为空，粘贴置灰。 */
  @State private copiedParamKinds: number = PARAM_NONE;
  private copiedParamJson: string = '';
  private copySourceName: string = '';
  // 「复制参数」弹窗里的勾选状态。
  @State private copyAdjust: boolean = true;
  @State private copyCrop: boolean = true;
  @State private copyMask: boolean = true;
  @State private copyPreset: boolean = true;
  @State private copyBokeh: boolean = true;
  private copyParamsDialogController: CustomDialogController | null = null;
  // 长按照片后的自绘浮层菜单（自己接手势，避免被系统抓图抢走）。
  @State private photoMenuVisible: boolean = false;
  @State private photoMenuRating: number = 0;
  @State private photoMenuX: number = 0;
  @State private photoMenuY: number = 0;
  private photoMenuTarget: PhotoItem | null = null;
  // 「背景图片滚动」：默认关闭；关闭时不显示背景图片，开启后用最近作品
  // 的高清缓存帧滚动。持久化在 pixelshop_profile 中。
  @StorageLink('homeBackdropEnabled') @Watch('onBackdropScrollChanged') private backdropScrollEnabled: boolean = false;
  @StorageLink('homeBackdropUris') private backdropImageUris: string[] = [];
  @StorageLink('vividNightMode') private isNightMode: boolean = false;
  @StorageProp('windowWidth') private windowWidth: number = 390;
  @StorageProp('homeSection') private selectedSection: number = 0;
  @StorageProp('homeSectionTick') @Watch('onSectionChanged') private sectionTick: number = 0;
  @StorageProp('homeShowTick') @Watch('onHomeShowTick') private showTick: number = 0;
  // 导出状态全局化（AppStorage + 全局浮层 ExportOverlay）：跨页面可见，
  // 从编辑页发起的导出返回主界面后进度仍会显示。
  @StorageLink('vividExportActive') private exportInProgress: boolean = false;
  @StorageLink('vividExportProgress') private exportProgress: number = 0;
  @StorageLink('vividExportStatus') private exportStatus: string = '';
  @StorageLink('vividExportBackgrounded') private exportBackgrounded: boolean = false;
  @StorageLink('vividExportCancelRequested') private exportCancelRequested: boolean = false;
  @State private copiedAdjustmentState: string = '';
  private batchExportDialogController: CustomDialogController | null = null;
  private photoPreferences: preferences.Preferences | null = null;
  private importedPhotoLoadPromise: Promise<void> | null = null;
  private recentPhotoValidationRunning: boolean = false;
  private thumbnailRepairRunning: boolean = false;
  private backdropUriCache: Record<string, string> = {};
  private backdropRefreshScheduled: boolean = false;
  private lastSection: number = 0;

  aboutToAppear(): void {
    WorksBridge.importPhotos = (uris: string[]): Promise<void> => this.importPhotosAndEdit(uris);
    // 常驻挂载：注册跨页桥接，供相机页导入照片与壳页面触发系统分享。
    WorksBridge.addImportedPhoto =
      (uri: string, displayNameOverride: string, fallbackThumbUri: string,
        orientation: number): Promise<PhotoItem | null> =>
        this.addImportedPhoto(uri, displayNameOverride, fallbackThumbUri, orientation);
    WorksBridge.repairMissingThumbnails = (): void => {
      this.repairMissingThumbnails();
    };
    WorksBridge.shareSelectedPhotos = (): void => {
      this.shareSelectedPhotos();
    };
    // Let the first frame and navigation render before loading imported photos.
    setTimeout(() => {
      this.importedPhotoLoadPromise = this.loadImportedPhotos();
      this.prepareLibrary();
    }, 320);
  }

  aboutToDisappear(): void {
    WorksBridge.importPhotos = null;
    WorksBridge.addImportedPhoto = null;
    WorksBridge.repairMissingThumbnails = null;
    WorksBridge.shareSelectedPhotos = null;
  }

  /** 壳页面 switchSection 的页签进入/离开回放（原 switchSection 作品分支）。 */
  private onSectionChanged(): void {
    if (this.selectedSection === 0 && this.lastSection !== 0) {
      this.validateRecentPhotosOnEntry();
    }
    this.lastSection = this.selectedSection;
  }

  private onHomeShowTick(): void {
    // Returning from the editor is also an entry into the works page. Recheck
    // persisted source URIs even when the tab index itself did not change.
    if (this.selectedSection === 0) this.validateRecentPhotosOnEntry();
  }

  private scheduleNavColorRefresh(): void {
    NavColorService.schedule(this.getUIContext());
  }

  private extensionFromName(name: string): string {
    return sharedExtensionFromName(name);
  }

  private isRawExtension(extension: string): boolean {
    return sharedIsRawExtension(extension);
  }

  private isVideoExtension(extension: string): boolean {
    return sharedIsVideoExtension(extension);
  }

  private async ensureLutsLoaded(): Promise<void> {
    if (LutBridge.ensureLutsLoaded) await LutBridge.ensureLutsLoaded();
  }

  private findAnyLut(name: string): CustomLut | undefined {
    return LutBridge.findAnyLut ? LutBridge.findAnyLut(name) : undefined;
  }

  private async loadBundledLut(name: string): Promise<CustomLut | null> {
    return LutBridge.loadBundledLut ? LutBridge.loadBundledLut(name) : Promise.resolve(null);
  }

  private pageTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#172033';
  }

  private cardMaterial(): VividMaterial {
    return this.isNightMode ? VividMaterial.cardNight : VividMaterial.card;
  }

  private panelTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#1B2536';
  }

  private secondaryTextColor(): string {
    return this.isNightMode ? '#D1D9E8' : '#526078';
  }

  private mutedTextColor(): string {
    return this.isNightMode ? '#B7C3D6' : '#7B8798';
  }

  @StorageProp('recentPhotoRevision') @Watch('reloadExternalRecentPhotos') private recentPhotoRevision: number = 0;

  private reloadExternalRecentPhotos(): void {
    if (this.recentPhotoRevision <= 0) return;
    // A photo can be picked from LutDetailPage or the PC editor while Index is
    // underneath the route. Reload the shared recent-work preference so the
    // new card is visible immediately when Works is shown again.
    this.importedPhotoLoadPromise = this.loadImportedPhotos();
  }

  @Builder
  LibraryContent() {
    Scroll() {
      Column() {
        this.LibraryHero();
        Row() {
          Column() {
            Text('最近作品')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.pageTextColor());
            Text(this.photos.length > 0 ? `${this.photos.length} 张照片` : '为你的影像建立视觉记忆')
              .fontSize(12)
              .fontColor($r('app.color.vivid_text_7a8798'))
              .margin({ top: 3 });
          }
          .alignItems(HorizontalAlign.Start);
          Blank();
          Row() {
            if (this.copiedAdjustmentState.length > 0) {
              Row() {
                Text('⧉').fontSize(17).fontColor(this.selectionMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_243047'));
                Text('粘贴').fontSize(12)
                  .fontColor(this.selectionMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_526078')).margin({ left: 7 });
              }
              .height(36).padding({ left: 10, right: 10 }).borderRadius(18)
              .backgroundColor(this.selectionMode ? '#316CF4' : 'rgba(255,255,255,0.58)')
              .onClick(() => this.handlePasteButton());
            } else {
              Row() {
                // 退出态只留文字，不再带 ✕。
                if (!this.selectionMode) {
                  Text('▦')
                    .fontSize(18)
                    .fontColor($r('app.color.vivid_text_243047'));
                }
                Text(this.selectionMode ? '退出' : '筛选')
                  .fontSize(12)
                  .fontColor(this.selectionMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_526078'))
                  .margin({ left: this.selectionMode ? 0 : 8 });
              }
              .height(36)
              .padding({ left: 10, right: 10 })
              .borderRadius(18)
              .backgroundColor(this.selectionMode ? '#316CF4' : 'rgba(255,255,255,0.58)')
              .onClick(() => {
                this.selectionMode = !this.selectionMode;
                if (!this.selectionMode) {
                  this.selectedUris = [];
                  // 退出筛选时清掉星级过滤，否则列表会停在「没有 N 星的照片」。
                  this.minimumStars = 0;
                }
              });
            }
            // 星级筛选：进入筛选后占据原「完成」的位置，点开是 1~5 星子菜单，
            // 选中的星级决定最近作品只显示哪一档（再点「全部」恢复）。
            if (this.selectionMode) {
              Row() {
                Text(this.minimumStars > 0 ? '★' : '☆')
                  .fontSize(15)
                  .fontColor(this.minimumStars > 0 ? $r('app.color.vivid_text_ffffff')
                    : $r('app.color.vivid_text_243047'));
                Text(this.minimumStars > 0 ? `${this.minimumStars} 星` : '星级')
                  .fontSize(12)
                  .fontColor(this.minimumStars > 0 ? $r('app.color.vivid_text_ffffff')
                    : $r('app.color.vivid_text_526078'))
                  .margin({ left: 6 });
                Text('▾').fontSize(9)
                  .fontColor(this.minimumStars > 0 ? $r('app.color.vivid_text_ffffff')
                    : $r('app.color.vivid_text_8a95a5'))
                  .margin({ left: 4 });
              }
              .height(36)
              .padding({ left: 10, right: 10 })
              .borderRadius(18)
              .margin({ left: 8 })
              .backgroundColor(this.minimumStars > 0 ? '#202A3B' : 'rgba(255,255,255,0.58)')
              .id('works-star-filter')
              .bindMenu(this.RatingMenu);
            }
          }
          .height(36)
          .borderRadius(18);
        }
        .width('100%')
        .margin({ top: 24, bottom: this.selectionMode ? 8 : 14 });

        // 多选操作单独占一行：全选 / 删除 / 导出 按文字自适应宽度。
        // 之前和标题、星级挤在同一行，窄屏上「导出」会被顶出屏幕外。
        if (this.selectionMode) {
          Row({ space: 8 }) {
            Blank();
            Button('全选')
              .fontSize(11)
              .fontColor($r('app.color.vivid_text_334158'))
              .type(ButtonType.Capsule)
              .height(34)
              .padding({ left: 14, right: 14 })
              .backgroundColor('rgba(255,255,255,0.72)')
              .onClick(() => { this.selectAllPhotos(); });
            Button('删除')
              .fontSize(11)
              .fontColor(this.selectedUris.length > 0 ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_a6afbc'))
              .type(ButtonType.Capsule)
              .height(34)
              .padding({ left: 14, right: 14 })
              .backgroundColor(this.selectedUris.length > 0 ? '#C4485C' : 'rgba(228,232,239,0.9)')
              .enabled(this.selectedUris.length > 0)
              .onClick(() => { this.deleteSelectedPhotos(); });
            Button('导出')
              .fontSize(11)
              .fontColor(this.selectedUris.length > 0 ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_a6afbc'))
              .type(ButtonType.Capsule)
              .height(34)
              .padding({ left: 14, right: 14 })
              .backgroundColor(this.selectedUris.length > 0 ? '#202A3B' : 'rgba(228,232,239,0.9)')
              .enabled(this.selectedUris.length > 0 && !this.exportInProgress)
              .onClick(() => { this.exportSelectedPhotos(); });
          }
          .width('100%')
          .margin({ bottom: 14 });
        }

        if (this.loading || this.recentPhotoChecking) {
          Column() {
            LoadingProgress().width(34).height(34).color('#5262EC');
          }
          .width('100%')
          .height(180)
          .justifyContent(FlexAlign.Center);
        } else if (this.visiblePhotos().length > 0) {
          Grid() {
            ForEach(this.visiblePhotos(), (photo: PhotoItem) => {
              GridItem() { this.PhotoThumbnail(photo); }
            }, (photo: PhotoItem) => photo.uri + ':' + (photo.rating ?? 0).toString());
          }
          .columnsTemplate(this.getLibraryColumns())
          .columnsGap(this.isDesktop() ? 16 : 10)
          .rowsGap(this.isDesktop() ? 16 : 10)
          .cachedCount(4)
          .width('100%');
        } else if (this.minimumStars > 0) {
          Column() {
            Text(this.starsText(this.minimumStars))
              .fontSize(22)
              .fontColor('#5262EC');
            Text(`没有 ${this.minimumStars} 星的照片`)
              .fontSize(12)
              .fontColor($r('app.color.vivid_text_7a8798'))
              .margin({ top: 8 });
            Text('长按照片可以给它打分')
              .fontSize(11)
              .fontColor($r('app.color.vivid_text_a6afbc'))
              .margin({ top: 4 });
          }
          .width('100%')
          .height(180)
          .justifyContent(FlexAlign.Center);
        } else {
          this.EmptyLibraryState();
        }
      }
      .width('100%')
      .padding({ left: this.isDesktop() ? 28 : 14, right: this.isDesktop() ? 28 : 14, bottom: this.isDesktop() ? 32 : 96 });
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScroll((_xOffset: number, yOffset: number) => {
      this.scheduleNavColorRefresh();
      this.updateNavCollapse(yOffset);
    });
  }

  /** 任一主页面下滑时导航栏收缩为右侧「我的」小胶囊，上滑或点击胶囊恢复完整导航。 */
  private updateNavCollapse(yOffset: number): void {
    if (yOffset > 4) {
      if (!this.navCollapsed) {
        // geometryTransition 形变必须由 animateTo 驱动，时长曲线跟随此处配置。
        this.getUIContext().animateTo({ duration: 500, curve: Curve.EaseOut }, () => {
          this.navCollapsed = true;
        });
      }
    } else if (yOffset < -4) {
      if (this.navCollapsed) {
        this.getUIContext().animateTo({ duration: 500, curve: Curve.EaseOut }, () => {
          this.navCollapsed = false;
        });
      }
    }
  }

  @Builder
  EmptyLibraryState() {
    Column() {
      Text('暂无最近作品')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isNightMode ? this.pageTextColor() : $r('app.color.vivid_text_263247'));
      Text('从图库选择一张照片开始编辑')
        .fontSize(12)
        .fontColor(this.isNightMode ? this.mutedTextColor() : $r('app.color.vivid_text_7a8798'))
        .margin({ top: 7, bottom: 18 });
      Button('预览图库')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.vivid_text_ffffff'))
        .type(ButtonType.Capsule)
        .height(40)
        .padding({ left: 22, right: 22 })
        .backgroundColor('#316CF4')
        .onClick(() => { this.openPhotoPicker(); });
    }
    .width('100%')
    .height(220)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(24)
    // 夜间用 100% 透明底：灰卡片压在深色页面上很脏；日间保留原来的浅色玻璃。
    .backgroundColor(this.isNightMode ? Color.Transparent : 'rgba(255,255,255,0.48)')
    .border({ width: 1, color: this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.76)' });
  }

  @Builder
  LibraryHero() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($r('app.media.vivid_cover'))
        .width('100%')
        .height('100%')
        .sourceSize({ width: 1200, height: 800 })
        .objectFit(ImageFit.Cover)
        .objectRepeat(ImageRepeat.NoRepeat);
      // A light contrast wash keeps the supplied cover visible while keeping
      // the white title readable over both sky and grass.
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 120,
          colors: [['rgba(11,20,35,0.48)', 0.0], ['rgba(36,52,78,0.24)', 0.48],
            ['rgba(74,52,95,0.42)', 1.0]],
        });
      Row() {
        Column() {
          Row() {
            if (!this.isDesktop()) {
              Text('Pixelshop')
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor('rgba(255,255,255,0.82)')
                .letterSpacing(1.4);
            }
            Blank();
            Text('RAW  14 BIT').fontSize(10).fontColor('rgba(255,255,255,0.76)');
          }
          .width('100%');
          Blank();
          Text('把现场的光，\n留成你的颜色。')
            .fontSize(this.isDesktop() ? 30 : 25)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.vivid_text_ffffff'))
            .lineHeight(this.isDesktop() ? 39 : 33);
          Text('连接 LUMIX、导入 RAW，并在同一个无损工作流中完成调色。')
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.78)')
            .maxLines(2)
            .margin({ top: 9 });
          Row() {
            Button('打开照片')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.vivid_text_1c2638'))
              .type(ButtonType.Capsule)
              .backgroundColor($r('app.color.vivid_surface_ffffff'))
              .height(38)
              .padding({ left: 18, right: 18 })
              .onClick(() => { this.openPhotoPicker(); });
            Button('快速演示')
              .fontSize(13)
              .fontColor($r('app.color.vivid_text_ffffff'))
              .type(ButtonType.Capsule)
              .backgroundColor('rgba(255,255,255,0.18)')
              .height(38)
              .padding({ left: 18, right: 18 })
              .margin({ left: 8 })
              .onClick(() => { this.startDemoEditing(); });
          }
          .margin({ top: 17 });
        }
        .layoutWeight(1)
        .height('100%')
        .alignItems(HorizontalAlign.Start);

      }
      .width('100%')
      .height('100%')
      .padding(this.isDesktop() ? 26 : 20);
    }
    .width('100%')
    .height(this.isDesktop() ? 258 : 265)
    .borderRadius(this.isDesktop() ? 32 : 26)
    .clip(true)
    .shadow({ radius: 34, color: 'rgba(40,52,84,0.25)', offsetY: 14 });
  }

  @Builder
  PhotoThumbnail(photo: PhotoItem) {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (photo.thumbUri.length > 0) {
        Image(photo.thumbUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          // 关掉系统识图/抓图：默认长按照片会被系统接管去提取内容，
          // 我们的快捷菜单（删除/复制/粘贴/分享）就弹不出来。
          .enableAnalyzer(false);
      } else {
        // 缩略图生成失败时也不能回退到原图，否则一张超大照片就会
        // 在首页触发全尺寸解码并导致应用被系统杀死。
        Column() {
          Text('▧')
            .fontSize(34)
            .fontColor('rgba(35,49,72,0.52)');
          Text('预览不可用')
            .fontSize(11)
            .fontColor('rgba(35,49,72,0.62)')
            .margin({ top: 6 });
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        // 夜间透明：卡片随页面背景透出，白天仍用浅灰提示"这里该有图"。
        .backgroundColor(this.isNightMode ? Color.Transparent : $r('app.color.vivid_surface_dce4ef'));
      }
      Column() {
        Text(photo.displayName)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.vivid_text_ffffff'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(12)
      .backgroundColor('rgba(17,25,39,0.50)')
      .backdropBlur(14);

      // 多选模式：右下角勾选框，用布局内边距远离卡片圆角（不再使用
      // 百分比 position，避免部分设备上定位到圆角边缘相切）。
      if (this.selectionMode) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Stack() {
            if (this.isPhotoSelected(photo.uri)) {
              Text('✓').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.vivid_text_ffffff'));
            }
          }
          .width(26)
          .height(26)
          .borderRadius(13)
          .backgroundColor(this.isPhotoSelected(photo.uri) ? '#316CF4' : 'rgba(255,255,255,0.92)')
          .border({
            width: 1.5,
            color: this.isPhotoSelected(photo.uri) ? '#316CF4' : 'rgba(120,130,145,0.9)',
          })
        }
        .width('100%')
        .height('100%')
        .padding({ right: 14, bottom: 14 })
        .hitTestBehavior(HitTestMode.None);
      }
    }
    .width('100%')
    .aspectRatio(photo.portrait ? 1 / RECENT_THUMBNAIL_ASPECT_RATIO : RECENT_THUMBNAIL_ASPECT_RATIO)
    .borderRadius(20)
    .clip(true)
    .onClick(() => {
      if (this.selectionMode) {
        this.togglePhotoSelection(photo.uri);
      } else if (this.isVideoPhotoItem(photo)) {
        this.openVideoInSystemViewer(photo);
      } else {
        this.navigateToEditor(photo.uri);
      }
    })
    // 长按由我们自己的手势接住：系统默认会在图片上起「抓图/识图」，
    // 一旦让它接管，删除/复制/粘贴/分享这个菜单就永远弹不出来。
    .gesture(LongPressGesture({ repeat: false, duration: 400 })
      .onAction((event: GestureEvent) => {
        this.openPhotoMenu(photo, event);
      }))
  }

  /**
   * 长按弹出的自绘菜单。
   *
   * 不用 `bindContextMenu`：那一层长按会先被系统拿去「抓图/识图」，菜单弹不出来。
   * 这里用 `LongPressGesture` 自己接住手势，再在页面上叠一个浮层菜单。
   */
  private openPhotoMenu(photo: PhotoItem, event: GestureEvent): void {
    const finger = event.fingerList.length > 0 ? event.fingerList[0] : null;
    const width = 196;
    const height = 292;
    const screenWidth = this.windowWidth > 0 ? this.windowWidth : 390;
    const touchX = finger !== null ? finger.globalX : screenWidth / 2;
    const touchY = finger !== null ? finger.globalY : 300;
    this.photoMenuX = Math.max(8, Math.min(touchX - width / 2, screenWidth - width - 8));
    this.photoMenuY = Math.max(60, touchY - height / 2);
    this.photoMenuTarget = photo;
    // 星级一定要回查当前列表：ForEach 的 key 只带 uri，卡片不会因为 rating 变化
    // 重建，传进来的 photo 可能是打分之前的旧对象，直接用它会一直显示 0 星。
    const latest = this.photos.find((item: PhotoItem): boolean => item.uri === photo.uri);
    this.photoMenuRating = latest !== undefined ? (latest.rating ?? 0) : (photo.rating ?? 0);
    this.photoMenuVisible = true;
  }

  private closePhotoMenu(): void {
    this.photoMenuVisible = false;
    this.photoMenuTarget = null;
  }

  @Builder
  MenuActionRow(label: string, color: string, enabled: boolean, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor(enabled ? color : $r('app.color.vivid_text_a6afbc'))
      .width('100%')
      .height(44)
      .padding({ left: 16 })
      .textAlign(TextAlign.Start)
      .align(Alignment.Start)
      .onClick(() => {
        if (!enabled) return;
        action();
      });
  }

  @Builder
  PhotoMenuPanel() {
    Column() {
      // 星级：实心星表示当前评级，点一次打分，再点同一档取消。
      Row() {
        ForEach([1, 2, 3, 4, 5], (star: number) => {
          Text(star <= this.photoMenuRating ? '★' : '☆')
            .fontSize(22)
            .fontColor(star <= this.photoMenuRating ? '#F5B301' : this.mutedTextColor())
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              const target = this.photoMenuTarget;
              if (target === null) return;
              const next = this.photoMenuRating === star ? 0 : star;
              this.photoMenuRating = next;
              this.ratePhoto(target, next);
              this.closePhotoMenu();
            });
        }, (star: number) => 'menu-star-' + star.toString());
      }
      .width('100%')
      .height(46);

      Divider().color(this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(20,30,50,0.08)');

      this.MenuActionRow('删除', '#C4485C', true, () => {
        const target = this.photoMenuTarget;
        this.closePhotoMenu();
        if (target !== null) this.deleteSinglePhoto(target);
      });
      this.MenuActionRow('复制', this.panelTextColor(), true, () => {
        const target = this.photoMenuTarget;
        this.closePhotoMenu();
        if (target !== null) this.openCopyParamsDialog(target);
      });
      this.MenuActionRow('粘贴', this.panelTextColor(),
        this.copiedParamKinds !== PARAM_NONE &&
          (this.photoMenuTarget !== null && !this.isVideoPhotoItem(this.photoMenuTarget)),
        () => {
          const target = this.photoMenuTarget;
          this.closePhotoMenu();
          if (target !== null) this.pasteParamsToPhoto(target);
        });
      this.MenuActionRow('分享', this.panelTextColor(), true, () => {
        const target = this.photoMenuTarget;
        this.closePhotoMenu();
        if (target !== null) this.shareRenderedPhoto(target);
      });
    }
    .width(196)
    .padding({ top: 2, bottom: 6 })
    .borderRadius(18)
    .backgroundColor(this.isNightMode ? '#20242C' : '#FFFFFF')
    .border({ width: 1, color: this.isNightMode ? 'rgba(255,255,255,0.12)' : 'rgba(20,30,50,0.06)' })
    .shadow({ radius: 28, color: 'rgba(16,24,40,0.28)', offsetY: 10 })
    .position({ x: this.photoMenuX, y: this.photoMenuY })
    // 弹出/收起都走一次缩放 + 淡入，不要"啪"一下直接出现。
    .transition(
      TransitionEffect.OPACITY
        .animation({ duration: 150, curve: Curve.EaseOut })
        .combine(
          TransitionEffect.scale({ x: 0.88, y: 0.88 })
            .animation({ duration: 180, curve: Curve.FastOutSlowIn })
        )
    );
  }

  @Builder
  RatingMenu() {
    Menu() {
      MenuItem({ content: '全部照片' }).onClick(() => { this.minimumStars = 0; });
      ForEach([1, 2, 3, 4, 5], (star: number) => {
        MenuItem({ content: '★'.repeat(star) })
          .onClick(() => { this.minimumStars = this.minimumStars === star ? 0 : star; });
      }, (star: number) => 'filter-' + star.toString());
    }
  }

  /** 实心星串，用于空状态提示。 */
  private starsText(count: number): string {
    return '★'.repeat(Math.max(0, Math.min(5, count)));
  }

  private visiblePhotos(): PhotoItem[] {
    if (this.minimumStars <= 0) return this.photos;
    return this.photos.filter((photo: PhotoItem): boolean => (photo.rating ?? 0) === this.minimumStars);
  }

  /** 给一张照片打分并立刻反映到列表（0 表示取消评级）。 */
  private async ratePhoto(photo: PhotoItem, stars: number): Promise<void> {
    // 先改本地列表（界面立刻生效），再写同一份 preferences。
    // 不走 RecentPhotoStore.rate：它会 bump recentPhotoRevision，触发整页重载，
    // 星级还没落盘就被读回来覆盖，表现就是「点星级没反应」。
    this.photos = this.photos.map((item: PhotoItem): PhotoItem => {
      if (item.uri !== photo.uri) return item;
      const updated: PhotoItem = {
        uri: item.uri, thumbUri: item.thumbUri, displayName: item.displayName,
        thumbnailVersion: item.thumbnailVersion, rating: stars, portrait: item.portrait,
      };
      return updated;
    });
    try {
      await this.persistImportedPhotos();
    } catch (_error) {
      this.showMessage('星级保存失败');
    }
  }

  private isDesktop(): boolean {
    return this.windowWidth >= 840;
  }

  private getLibraryColumns(): string {
    if (this.windowWidth >= 1380) return '1fr 1fr 1fr 1fr';
    if (this.windowWidth >= 840) return '1fr 1fr 1fr';
    return '1fr 1fr';
  }

  private onPhotosForBackdrop(): void {
    this.scheduleBackdropRefresh();
  }

  private onBackdropScrollChanged(): void {
    this.scheduleBackdropRefresh();
  }

  private scheduleBackdropRefresh(): void {
    if (this.backdropRefreshScheduled) return;
    this.backdropRefreshScheduled = true;
    setTimeout(() => {
      this.backdropRefreshScheduled = false;
      this.refreshBackdropImages();
    }, 120);
  }

  private async refreshBackdropImages(): Promise<void> {
    if (!this.backdropScrollEnabled) {
      this.backdropImageUris = [];
      return;
    }
    const limit = Math.min(4, this.photos.length);
    const uris: string[] = [];
    for (let index = 0; index < limit; index++) {
      // 串行生成，避免启动时并发解码多张原图挤占内存。
      uris.push(await this.backdropUriFor(this.photos[index]));
    }
    this.backdropImageUris = uris;
  }

  /**
   * 背景滚动帧来源：旧实现直接绑定 360px 的作品缩略图，全屏放大后发虚。
   * 这里改为从原图（含 RAW 内嵌预览）生成 1280px 高清 JPEG 缓存
   * （vivid_backdrop_*.jpg），一次生成后每次启动直接读取。
   */
  private async backdropUriFor(photo: PhotoItem): Promise<string> {
    if (photo.uri.length === 0) return photo.thumbUri;
    const cached = this.backdropUriCache[photo.uri];
    if (cached) return cached;
    let pixelMap: image.PixelMap | null = null;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path = context.filesDir + '/vivid_backdrop_' + this.thumbnailKey(photo.uri) + '.jpg';
      try {
        if (fileIo.statSync(path).size > 0) {
          const uri = 'file://' + path;
          this.backdropUriCache[photo.uri] = uri;
          return uri;
        }
      } catch (_error) {
        // 首次访问没有缓存文件，继续生成。
      }
      pixelMap = await PixelMapUtils.loadFromUri(photo.uri, 1280,
        undefined, undefined, undefined, photo.displayName, undefined, true);
      if (!pixelMap && photo.thumbUri.length > 0) {
        pixelMap = await PixelMapUtils.loadFromUri(photo.thumbUri, 1280);
      }
      if (!pixelMap) return photo.thumbUri;
      const jpeg = await PixelMapUtils.encodeToJpeg(pixelMap, 86);
      if (!jpeg) return photo.thumbUri;
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, jpeg);
      } finally {
        fileIo.closeSync(file);
      }
      const uri = 'file://' + path;
      this.backdropUriCache[photo.uri] = uri;
      return uri;
    } catch (_error) {
      return photo.thumbUri;
    } finally {
      if (pixelMap) pixelMap.release();
    }
  }

  private isPhotoSelected(uri: string): boolean {
    return this.selectedUris.indexOf(uri) >= 0;
  }

  private togglePhotoSelection(uri: string): void {
    const index = this.selectedUris.indexOf(uri);
    if (index >= 0) {
      this.selectedUris = this.selectedUris.filter((u: string) => u !== uri);
    } else {
      this.selectedUris = this.selectedUris.concat([uri]);
    }
  }

  private selectAllPhotos(): void {
    if (this.selectedUris.length === this.photos.length && this.photos.length > 0) {
      this.selectedUris = [];
    } else {
      this.selectedUris = this.photos.map((p: PhotoItem) => p.uri);
    }
  }

  private deleteSelectedPhotos(): void {
    if (this.selectedUris.length === 0) return;
    this.getUIContext().getPromptAction().showDialog({
      title: '删除所选图片',
      message: `确定从最近修图移除选中的 ${this.selectedUris.length} 张图片吗？`,
      buttons: [
        { text: '取消', color: '#536176' },
        { text: '删除', color: '#C4485C' },
      ],
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.performDeleteSelected();
      }
    }).catch(() => {});
  }

  private performDeleteSelected(): void {
    const removed = this.selectedUris;
    const removedItems = this.photos.filter((photo: PhotoItem) => removed.indexOf(photo.uri) >= 0);
    for (let index = 0; index < removedItems.length; index++) {
      const thumb = removedItems[index].thumbUri;
      if (thumb.indexOf('file://') === 0 && thumb.indexOf('vivid_import_thumb_') >= 0) {
        try {
          fileIo.unlinkSync(thumb.replace('file://', ''));
        } catch (_error) {
          // Thumbnail may already have been cleaned up.
        }
      }
    }
    this.photos = this.photos.filter((p: PhotoItem) => removed.indexOf(p.uri) < 0);
    this.selectedUris = [];
    this.selectionMode = false;
    this.persistImportedPhotos();
  }

  private async prepareLibrary(): Promise<void> {
    // Recent works are app imports only. The system gallery permission is
    // intentionally not requested here; PhotoViewPicker grants a scoped URI
    // when the user explicitly chooses an image.
    if (!this.importedPhotoLoadPromise) {
      this.importedPhotoLoadPromise = this.loadImportedPhotos();
    }
    await this.importedPhotoLoadPromise;
  }

  private async loadImportedPhotos(): Promise<void> {
    this.loading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.photoPreferences = await preferences.getPreferences(context, 'vivid_imported_photos');
      const raw = await this.photoPreferences.get('items', '[]');
      if (typeof raw === 'string') {
        const parsed = JSON.parse(raw) as PhotoItem[];
        const validItems: PhotoItem[] = parsed instanceof Array ? parsed.filter((item: PhotoItem) =>
          !!item && typeof item.uri === 'string' && item.uri.length > 0) : [];
        // Imported RAW/JPEG files are user work, even when an older build
        // used one of the test filenames.  Do not discard 侧视图3.RW2 (or any
        // other imported asset) before the thumbnail repair pass can rebuild
        // its recent-work card.
        this.photos = validItems;
      } else {
        this.photos = [];
      }
      // 清理由旧版本首次启动时复制到沙箱的测试原图和 RAW 预览，避免它们
      // 在升级后继续占用应用空间。
      const legacyPaths: string[] = [
        context.filesDir + '/test_image_2.jpg',
        context.filesDir + '/P2214191.RW2',
        context.filesDir + '/P2214191.RW2.preview.jpg',
      ];
      for (const path of legacyPaths) {
        try {
          fileIo.unlinkSync(path);
        } catch (_error) {
          // Legacy files may already be absent.
        }
      }
    } catch (_error) {
      this.photos = [];
    }
    this.loading = false;
    // The app opens on the works page. Run the same URI validation used when
    // returning to it, after the first frame has had a chance to render.
    setTimeout(() => { this.validateRecentPhotosOnEntry(); }, 0);
    // Persisted imports may predate RAW thumbnail generation (and the media
    // provider can return a URI without a filename). Repair them after the
    // recent-work list is visible so RW2 cards get a JPEG preview without
    // delaying the first frame.
    setTimeout(() => { this.repairMissingThumbnails(); }, 350);
  }

  private async persistImportedPhotos(): Promise<void> {
    try {
      if (this.importedPhotoLoadPromise) await this.importedPhotoLoadPromise;
      if (!this.photoPreferences) return;
      await this.photoPreferences.put('items', JSON.stringify(this.photos));
      await this.photoPreferences.flush();
    } catch (_error) {
      // Keep the in-memory recent list available if preferences are read-only.
    }
  }

  /** Check whether an imported source URI still resolves to a non-empty file. */
  private importedPhotoSourceUsable(uri: string): boolean {
    if (typeof uri !== 'string' || uri.trim().length === 0) return false;
    let file: fileIo.File | null = null;
    try {
      // fileIo accepts both app-scoped media URIs (file://media/...) and the
      // sandbox file URIs created for downloaded camera assets. Opening the
      // URI is a stronger existence check than trusting a cached thumbnail.
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      return Number(fileIo.statSync(file.fd).size) > 0;
    } catch (_error) {
      return false;
    } finally {
      if (file) {
        try { fileIo.closeSync(file); } catch (_error) { }
      }
    }
  }

  private removeImportedThumbnail(item: PhotoItem): void {
    const thumb = item.thumbUri || '';
    if (thumb.indexOf('file://') !== 0 || thumb.indexOf('vivid_import_thumb_') < 0) return;
    try { fileIo.unlinkSync(thumb.replace(/^file:\/\//, '')); } catch (_error) { }
  }

  /**
   * Reconcile the recent-work index with storage whenever the works page is
   * entered. Deleted media must not remain visible just because its cached
   * thumbnail is still present in the app sandbox.
   */
  private validateRecentPhotosOnEntry(): void {
    if (this.recentPhotoValidationRunning) return;
    this.recentPhotoValidationRunning = true;
    this.recentPhotoChecking = true;
    this.validateRecentPhotos().catch(() => {
      // A transient provider error leaves the current list intact; the next
      // page entry retries the check instead of deleting records blindly.
    }).finally(() => {
      this.recentPhotoValidationRunning = false;
      this.recentPhotoChecking = false;
    });
  }

  private async validateRecentPhotos(): Promise<void> {
    if (this.importedPhotoLoadPromise) await this.importedPhotoLoadPromise;
    const snapshot = this.photos.slice();
    if (snapshot.length === 0) return;

    const valid: PhotoItem[] = [];
    const removed: PhotoItem[] = [];
    for (const item of snapshot) {
      if (this.importedPhotoSourceUsable(item.uri)) valid.push(item);
      else removed.push(item);
      // Yield between provider calls so entering the works page never blocks
      // gesture dispatch for a large recent list.
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
    }
    if (removed.length === 0) return;

    for (const item of removed) this.removeImportedThumbnail(item);
    // An import can finish while the asynchronous validation is running. Keep
    // any newer item that was not part of the validation snapshot.
    const snapshotUris: string[] = snapshot.map((item: PhotoItem) => item.uri);
    const newerItems = this.photos.filter((item: PhotoItem) => snapshotUris.indexOf(item.uri) < 0);
    const next = valid.concat(newerItems);
    this.photos = next;
    this.selectedUris = this.selectedUris.filter((uri: string) =>
      next.some((item: PhotoItem) => item.uri === uri));
    await this.persistImportedPhotos();
  }

  private fileNameFromUri(uri: string): string {
    let value = uri;
    const query = value.indexOf('?');
    if (query >= 0) value = value.substring(0, query);
    const hash = value.indexOf('#');
    if (hash >= 0) value = value.substring(0, hash);
    const slash = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
    if (slash >= 0) value = value.substring(slash + 1);
    try {
      value = decodeURIComponent(value);
    } catch (_error) {
      // Keep the provider's original leaf name when it is not URI encoded.
    }
    return value.length > 0 ? value : '导入图片';
  }

  private thumbnailKey(uri: string): string {
    let hash = 2166136261;
    for (let index = 0; index < uri.length; index++) {
      hash ^= uri.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16);
  }

  /** 松下画廊缩略图（相机 HTTP API 返回的本地 JPEG）：校验存在且非空后原样使用。 */
  private resolveCameraFallbackThumbnail(candidate: string): string {
    try {
      const path = candidate.replace(/^file:\/\//, '');
      if (path.length > 0 && fileIo.statSync(path).size > 0) return candidate;
    } catch (_error) {
    }
    return '';
  }

  /**
   * Camera RAW previews can contain a letterboxed frame, and a video frame is
   * 16:9.  Crop only the cached card thumbnail to the card ratio the card will
   * actually use — 3:2 for a landscape shot, 2:3 for a portrait one, so a
   * portrait photo is no longer squeezed into a landscape window.  The
   * original URI remains untouched.
   */
  private async cropThumbnailToCard(pixelMap: image.PixelMap, targetRatio: number): Promise<void> {
    try {
      const info = await pixelMap.getImageInfo();
      const sourceWidth = info.size.width;
      const sourceHeight = info.size.height;
      if (sourceWidth <= 0 || sourceHeight <= 0) return;
      const sourceRatio = sourceWidth / sourceHeight;
      if (Math.abs(sourceRatio - targetRatio) < 0.01) return;

      let cropWidth = sourceWidth;
      let cropHeight = sourceHeight;
      let cropX = 0;
      let cropY = 0;
      if (sourceRatio > targetRatio) {
        cropWidth = Math.max(1, Math.floor(sourceHeight * targetRatio));
        cropX = Math.max(0, Math.floor((sourceWidth - cropWidth) / 2));
      } else {
        cropHeight = Math.max(1, Math.floor(sourceWidth / targetRatio));
        cropY = Math.max(0, Math.floor((sourceHeight - cropHeight) / 2));
      }
      await pixelMap.crop({
        x: cropX,
        y: cropY,
        size: { width: cropWidth, height: cropHeight },
      });
    } catch (_error) {
      // Keep the decoded preview if a provider returns an immutable map.
    }
  }

  /** 用系统 AVImageGenerator 抽取视频首帧作为作品卡片缩略图；4K/6K 帧
   *  等比缩到长边 720，控制缩略图文件体积。 */
  private async extractVideoFrame(videoUri: string): Promise<image.PixelMap | null> {
    let generator: media.AVImageGenerator | null = null;
    let file: fileIo.File | null = null;
    try {
      // 媒体库 URI（file://media/...）直接可用；沙箱 file:/// 路径需去掉协议头。
      const filePath = videoUri.indexOf('file://media/') === 0
        ? videoUri : videoUri.replace(/^file:\/\//, '');
      const size = fileIo.statSync(filePath).size;
      if (size <= 0) return null;
      file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      generator = await media.createAVImageGenerator();
      const fdSrc: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: size };
      generator.fdSrc = fdSrc;
      const params: media.PixelMapParams = {};
      const frame = await generator.fetchFrameByTime(0,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC, params);
      const info = await frame.getImageInfo();
      const maxSide = Math.max(info.size.width, info.size.height);
      if (maxSide > 720) {
        const scale = 720 / maxSide;
        await frame.scale(scale, scale);
      }
      return frame;
    } catch (_error) {
      hilog.warn(0x0001, 'VIVID_IMPORT', 'video frame extract failed %{public}s', String(_error));
      return null;
    } finally {
      if (generator !== null) {
        try {
          await generator.release();
        } catch (_releaseError) {
        }
      }
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
        }
      }
    }
  }

  private async createImportedThumbnail(uri: string, displayNameHint: string = '',
    fallbackThumbUri: string = '', orientation: number = 0): Promise<ImportedThumb> {
    let pixelMap: image.PixelMap | null = null;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const displayExtension = this.extensionFromName(displayNameHint);
      const extension = displayExtension.length > 0 ? displayExtension : this.extensionFromName(uri);
      const isVideo = this.isVideoExtension(extension);
      const cameraThumb = fallbackThumbUri.length > 0 ?
        this.resolveCameraFallbackThumbnail(fallbackThumbUri) : '';
      hilog.info(0x0001, 'VIVID_IMPORT', 'thumb start ext=%{public}s video=%{public}d fallback=%{public}d name=%{public}s',
        extension, isVideo ? 1 : 0, cameraThumb.length > 0 ? 1 : 0, displayNameHint);
      // Videos: the camera DIDL thumbnail (an already-downloaded local JPEG)
      // is the most reliable immediate source, mirroring the RAW path — a
      // freshly created media asset can briefly reject reads (EPERM). When it
      // is absent, extract the first frame with AVImageGenerator; a failure
      // stays repairable through the background thumbnail repair pass.
      // 只有"拿相机缩略图当像素源"时才需要补方向：那张 JPEG 不带 EXIF。
      // 从**原图**解码时系统解码器已经应用过 EXIF Orientation，再转一次会把
      // 竖图转倒——这正是上一轮 +90/-90 踩过的坑，所以必须区分来源。
      let fromCameraThumb = false;
      if (isVideo) {
        if (cameraThumb.length > 0) {
          pixelMap = await PixelMapUtils.loadFromUri(cameraThumb, 360);
        }
        if (!pixelMap) {
          pixelMap = await this.extractVideoFrame(uri);
        }
      } else {
        // The Panasonic gallery thumbnail is a local JPEG and the safest
        // source for an RW2 recent-work card. Copy it into Vivid's own
        // thumbnail file instead of persisting a transfer-session path.
        // NEF cards never take this branch: the Nikon download passes no
        // fallback, so the embedded preview is decoded from the NEF itself.
        if (cameraThumb.length > 0 && this.isRawExtension(extension)) {
          pixelMap = await PixelMapUtils.loadFromUri(cameraThumb, 360);
          fromCameraThumb = pixelMap !== null;
        }
        if (!pixelMap) {
          pixelMap = await PixelMapUtils.loadFromUri(uri, 360,
            undefined, undefined, undefined, displayNameHint, undefined, true);
        }
        if (!pixelMap && cameraThumb.length > 0) {
          pixelMap = await PixelMapUtils.loadFromUri(cameraThumb, 360);
          fromCameraThumb = pixelMap !== null;
        }
        // 从**原图**解码时，部分源（Fuji 的 JPEG/HEIC、媒体库刚创建的资产、
        // 带 desiredSize 的缩放解码）系统解码器并不会应用 EXIF Orientation，
        // 结果是竖拍图在卡片里横置。这里按「原始宽高比 vs 解码宽高比」判断
        // 解码器到底转没转，只在没转时补一次，避免二次旋转（松下 JPEG 走同一
        // 条路，判定为已转时行为完全不变）。
        if (pixelMap && !fromCameraThumb && !this.isRawExtension(extension)) {
          // 带上下载阶段从沙箱临时文件读到的方向做兜底：媒体库 URI 读不到 EXIF 时
          // 仍然知道这张图该竖着还是横着（尼康线就属于这种情况）。
          const applied: number = await ExifOrientation.normalize(pixelMap, uri, orientation);
          if (applied > 1) {
            hilog.info(0x0001, 'VIVID_IMPORT',
              'thumb exif orientation applied=%{public}d name=%{public}s', applied, displayNameHint);
          }
        }
      }
      if (!pixelMap) {
        hilog.error(0x0001, 'VIVID_IMPORT', 'thumb decode failed ext=%{public}s name=%{public}s',
          extension, displayNameHint);
        return { uri: '', portrait: false };
      }
      // 相机回来的缩略图 JPEG **不带 EXIF 方向**——官方也是拿 gallery/info 的
      // `Orientation` 自己转（X0.java:67 的 `s1(matrix, orientation)`），所以这里
      // 必须先把方向补上，否则竖拍 RAW 的卡片就是躺倒的横图。
      // 1=正常 3=180° 6=顺时针90° 8=逆时针90°，镜像值一并交给 RawPreviewLoader。
      if (fromCameraThumb && orientation > 1) {
        await RawPreviewLoader.applyOrientation(pixelMap, orientation);
        hilog.info(0x0001, 'VIVID_IMPORT', 'thumb orientation applied=%{public}d name=%{public}s',
          orientation, displayNameHint);
      }
      // 方向修完才知道这张图是横是竖——据此决定卡片长宽比，竖图不再被塞进
      // 3:2 横框里裁成横构图。RAW 预览可能带信箱黑边、视频帧多为 16:9，
      // 所以仍统一居中裁到目标比例。
      const composed = await pixelMap.getImageInfo();
      const portrait = composed.size.height > composed.size.width;
      if (this.isRawExtension(extension) || isVideo) {
        await this.cropThumbnailToCard(pixelMap,
          portrait ? 1 / RECENT_THUMBNAIL_ASPECT_RATIO : RECENT_THUMBNAIL_ASPECT_RATIO);
      }
      const jpeg = await PixelMapUtils.encodeToJpeg(pixelMap, 82);
      if (!jpeg) {
        hilog.error(0x0001, 'VIVID_IMPORT', 'thumb encode failed ext=%{public}s name=%{public}s',
          extension, displayNameHint);
        return { uri: '', portrait: false };
      }
      const path = context.filesDir + '/vivid_import_thumb_' + this.thumbnailKey(uri) + '.jpg';
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, jpeg);
      fileIo.closeSync(file);
      hilog.info(0x0001, 'VIVID_IMPORT', 'thumb ok name=%{public}s bytes=%{public}d',
        displayNameHint, jpeg.byteLength);
      return { uri: 'file://' + path, portrait };
    } catch (_error) {
      hilog.error(0x0001, 'VIVID_IMPORT', 'thumb exception name=%{public}s code=%{public}s',
        displayNameHint, String(_error));
      return { uri: '', portrait: false };
    } finally {
      if (pixelMap) pixelMap.release();
    }
  }

  private importedThumbnailUsable(uri: string): boolean {
    if (typeof uri !== 'string' || uri.length === 0) return false;
    if (uri.indexOf('file://') !== 0) return true;
    let file: fileIo.File | null = null;
    try {
      const path = uri.replace(/^file:\/\//, '');
      if (fileIo.statSync(path).size < 3) return false;
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const signature = new ArrayBuffer(3);
      const read = fileIo.readSync(file.fd, signature, { length: 3 });
      const bytes = new Uint8Array(signature);
      return read === 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF;
    } catch (_error) {
      return false;
    } finally {
      if (file) fileIo.closeSync(file);
    }
  }

  /** Rebuild missing recent-work thumbnails (RAW embedded preview or a
   * re-decode of an imported JPEG/HEIF) without touching the original media
   * asset. */
  private async repairMissingThumbnails(): Promise<void> {
    if (this.thumbnailRepairRunning || !this.photoPreferences) return;
    this.thumbnailRepairRunning = true;
    try {
      const repaired: PhotoItem[] = this.photos.slice();
      let changed = false;
      for (let index = 0; index < repaired.length; index++) {
        const item = repaired[index];
        // The persisted display name is not guaranteed to contain the suffix
        // (some picker providers return a title only), so also inspect the
        // original URI.  This keeps RW2/ARW/CR3 and other RAW cards repairable,
        // not just the legacy NEF records this routine was first written for.
        const isRaw = this.isRawExtension(this.extensionFromName(item.displayName)) ||
          this.isRawExtension(this.extensionFromName(item.uri));
        const isVideoItem = sharedIsVideoExtension(this.extensionFromName(item.displayName)) ||
          sharedIsVideoExtension(this.extensionFromName(item.uri));
        const usable = this.importedThumbnailUsable(item.thumbUri);
        const needsVersionRepair = item.thumbnailVersion !== RECENT_THUMBNAIL_VERSION;
        // 缩略图版本变化时重建卡片：RAW 一直如此；**非 RAW 图片**也一并重建，
        // 因为 v4 起缩略图会按 EXIF 方向归一化（此前竖拍图可能被存成横置卡片，
        // 比如富士下载的 JPEG/HEIC）。视频继续保持"只有坏了才重建"，避免每次
        // 进页面都抽第一帧。
        // 非 RAW 还额外承担 EPERM 场景：媒体库刚创建的资产在导入瞬间读不出来，
        // 这一趟（稍后执行）资产已提交，可以正常解码。
        const needsRepair = isVideoItem ? !usable : (needsVersionRepair || !usable);
        if (!needsRepair) continue;
        const thumb = await this.createImportedThumbnail(item.uri, item.displayName);
        if (thumb.uri.length === 0) continue;
        repaired[index] = {
          uri: item.uri,
          thumbUri: thumb.uri,
          displayName: item.displayName,
          thumbnailVersion: RECENT_THUMBNAIL_VERSION,
          rating: item.rating ?? 0,
          portrait: thumb.portrait,
        };
        this.photos = repaired.slice();
        changed = true;
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
      if (changed) {
        await this.photoPreferences.put('items', JSON.stringify(repaired));
        await this.photoPreferences.flush();
      }
    } catch (_error) {
      // Keep the original card if the NEF contains no readable JPEG preview.
    } finally {
      this.thumbnailRepairRunning = false;
    }
  }

  private async addImportedPhoto(uri: string, displayNameOverride: string = '',
    fallbackThumbUri: string = '', orientation: number = 0): Promise<PhotoItem | null> {
    try {
      const displayName = displayNameOverride.length > 0 ? displayNameOverride : this.fileNameFromUri(uri);
      const thumb = await this.createImportedThumbnail(uri, displayName, fallbackThumbUri, orientation);
      let thumbUri = thumb.uri;
      if (thumbUri.length === 0 && fallbackThumbUri.length > 0) {
        thumbUri = this.resolveCameraFallbackThumbnail(fallbackThumbUri);
      }
      const item: PhotoItem = {
        uri: uri,
        thumbUri: thumbUri,
        displayName: displayName,
        thumbnailVersion: RECENT_THUMBNAIL_VERSION,
        rating: this.photos.find((photo: PhotoItem): boolean => photo.uri === uri)?.rating ?? 0,
        portrait: thumb.portrait,
      };
      this.photos = [item].concat(this.photos.filter((photo: PhotoItem) => photo.uri !== uri));
      await this.persistImportedPhotos();
      hilog.info(0x0001, 'VIVID_IMPORT', 'import photo name=%{public}s thumbLen=%{public}d',
        displayName, item.thumbUri.length);
      return item;
    } catch (_error) {
      hilog.error(0x0001, 'VIVID_IMPORT', 'import photo failed name=%{public}s code=%{public}s',
        displayNameOverride, String(_error));
      return null;
    }
  }

  private async openPhotoPicker(presetName: string = ''): Promise<void> {
    await this.ensureLutsLoaded();
    let selectedLut = this.findAnyLut(presetName);
    if (selectedLut && selectedLut.sourceUri.indexOf('bundled://') === 0 && selectedLut.sampleCount === 0) {
      const loadedLut = await this.loadBundledLut(presetName);
      if (loadedLut) selectedLut = loadedLut;
    }
    const lutId = selectedLut ? selectedLut.id : '';
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        // 0 = 不限数量，支持批量导入。
        maxSelectNumber: 0,
      }).then((result: photoAccessHelper.PhotoSelectResult) => {
        if (result.photoUris.length === 0) return;
        if (result.photoUris.length === 1) {
          this.addImportedPhoto(result.photoUris[0]).then((item: PhotoItem | null) => {
            if (item) {
              this.navigateToEditor(item.uri, presetName, '', lutId);
            } else {
              this.showMessage('图片导入失败，请重试');
            }
          });
          return;
        }
        // 批量导入：全部加入最近修图。
        let pending = result.photoUris.length;
        let imported = 0;
        for (const uri of result.photoUris) {
          this.addImportedPhoto(uri).then((item: PhotoItem | null) => {
            if (item) imported++;
            pending--;
            if (pending === 0) {
              this.showMessage(`已导入 ${imported} 张图片`);
            }
          });
        }
      }).catch(() => {});
    } catch (_error) {
      this.showMessage('无法打开图库');
    }
  }

  private async importPhotosAndEdit(uris: string[]): Promise<void> {
    if (this.importedPhotoLoadPromise) await this.importedPhotoLoadPromise;
    let first = '';
    for (const uri of uris) {
      let source: fileIo.File | null = null;
      try {
        // Drop access is temporary. Keep an owned original, not just its
        // thumbnail, so reopening the editor/export works after a restart.
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const name = decodeURIComponent(uri.split('?')[0]).split('/').pop() ?? 'photo.jpg';
        const safeName = name.replace(/[^a-zA-Z0-9\u4e00-\u9fff._-]/g, '_');
        const destination = context.filesDir + '/drop_' + Date.now().toString(36) + '_' + safeName;
        source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
        await fileIo.copyFile(source.fd, destination);
        const item = await this.addImportedPhoto('file://' + destination);
        if (item && first.length === 0) first = item.uri;
      } catch (_error) { this.showMessage('有一张照片无法读取，已继续导入其他照片'); }
      finally { if (source) fileIo.closeSync(source); }
    }
    if (first.length > 0) this.navigateToEditor(first);
    else this.showMessage('没有可读取的照片');
  }

  private startDemoEditing(presetName: string = '', customPresetJson: string = ''): void {
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/EditorPage',
        params: { imageUri: '', presetName: presetName, customPresetJson: customPresetJson },
      });
    } catch (_error) {
      this.showMessage('无法打开编辑器');
    }
  }

  /** 作品卡片里的视频：显示名或原始 URI 任一带视频扩展名即判定。 */
  private isVideoPhotoItem(photo: PhotoItem): boolean {
    return this.isVideoExtension(this.extensionFromName(photo.displayName)) ||
      this.isVideoExtension(this.extensionFromName(photo.uri));
  }

  /** 视频卡片交给系统播放器打开；VIVID 的编辑器只处理静态图。 */
  private openVideoInSystemViewer(photo: PhotoItem): void {
    AppLogStore.add(`ui 打开视频 ${photo.displayName}`);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: photo.uri,
        type: 'video/*',
      };
      context.startAbility(want).catch((): void => {
        this.showMessage('无法打开视频，可在系统图库中查看');
      });
    } catch (_error) {
      this.showMessage('无法打开视频，可在系统图库中查看');
    }
  }

  private navigateToEditor(uri: string, presetName: string = '', customPresetJson: string = '', lutId: string = ''): void {
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/EditorPage',
        params: { imageUri: uri, presetName: presetName, customPresetJson: customPresetJson, lutId: lutId },
      });
    } catch (_error) {
      this.showMessage('无法打开所选照片');
    }
  }

  /** 通过鸿蒙系统分享面板分享筛选后选中的图片。 */
  private shareSelectedPhotos(): void {
    const targets = this.selectionMode ?
      this.photos.filter((p: PhotoItem) => this.isPhotoSelected(p.uri)) : [];
    if (targets.length === 0) {
      if (this.photos.length === 0) {
        this.showMessage('请先导入图片');
      } else {
        this.selectionMode = true;
        this.showMessage('请选择图片，再点击系统分享');
      }
      return;
    }
    this.sharePhotos(targets);
  }

  /** 分享指定图片列表（快捷菜单单张分享与筛选多选分享共用）。 */
  private async sharePhotos(targets: PhotoItem[]): Promise<void> {
    if (targets.length === 0 || this.sharing) return;
    this.sharing = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await PhotoShareService.share(context, targets);
    } catch (_error) {
      this.showMessage('无法分享，请确认原文件仍可访问后重试');
    } finally {
      this.sharing = false;
    }
  }

  /** 复制参数：先勾选要搬运的参数组，再把源照片的完整快照放进剪贴板。 */
  private openCopyParamsDialog(photo: PhotoItem): void {
    if (this.isVideoPhotoItem(photo)) {
      this.showMessage('视频不支持复制参数');
      return;
    }
    this.copyParamsDialogController = new CustomDialogController({
      builder: CopyParamsDialog({
        sourceName: photo.displayName,
        onConfirm: (kinds: number) => { this.applyCopyParams(photo, kinds); },
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true,
    });
    this.copyParamsDialogController.open();
  }

  /** 写入剪贴板：保存源快照 + 勾选的参数组位掩码。 */
  private applyCopyParams(photo: PhotoItem, kinds: number): void {
    if (kinds === PARAM_NONE) {
      this.showMessage('未勾选任何参数');
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const serialized = EditSidecar.read(photo.uri, context.filesDir);
      const source = new EditSession();
      source.layers = [new Layer('背景')];
      if (serialized && !source.importAdjustmentState(serialized)) {
        this.showMessage('参数读取失败');
        return;
      }
      // 重新序列化一次，保证剪贴板里是经过模型校验的快照结构。
      this.copiedParamJson = source.exportAdjustmentState();
      this.copiedAdjustmentState = this.copiedParamJson;
      this.copiedParamKinds = kinds;
      this.showMessage(`已复制「${photo.displayName}」的参数，长按目标照片可粘贴`);
    } catch (_error) {
      this.showMessage('参数复制失败');
    }
  }

  /**
   * 把勾选的参数组合并进目标照片的快照。
   * 调色 = 各图层调整 + 全局调色字段；裁剪 = 裁剪框 / 旋转 / 翻转 / 几何；
   * 蒙版 = 图层下的蒙版层；预设 = LUT 栈；大光圈 = 焦外参数。
   * 没勾的组保持目标照片原值，所以只贴裁剪不会把别人的色调带过来。
   */
  private mergeParamSnapshot(baseJson: string, sourceJson: string, kinds: number): string {
    const base = JSON.parse(baseJson) as ParamSnapshotJson;
    const source = JSON.parse(sourceJson) as ParamSnapshotJson;
    const baseLayers: ParamLayerJson[] = base.layers ?? [];
    const sourceLayers: ParamLayerJson[] = source.layers ?? [];
    if ((kinds & PARAM_ADJUST) !== 0) {
      base.retouchMarks = source.retouchMarks;
      base.denoise = source.denoise;
      base.detail = source.detail;
      base.detailHaze = source.detailHaze;
      base.optics = source.optics;
      base.upright = source.upright;
      base.pointColor = source.pointColor;
      base.oklch = source.oklch;
      base.blackWhite = source.blackWhite;
      base.rawSettings = source.rawSettings;
      for (let index = 0; index < baseLayers.length; index++) {
        if (sourceLayers.length === 0) break;
        const from = sourceLayers[Math.min(index, sourceLayers.length - 1)];
        baseLayers[index].adjustments = from.adjustments;
      }
    }
    if ((kinds & PARAM_CROP) !== 0) {
      base.cropLeft = source.cropLeft;
      base.cropTop = source.cropTop;
      base.cropRight = source.cropRight;
      base.cropBottom = source.cropBottom;
      base.rotation = source.rotation;
      base.flipH = source.flipH;
      base.flipV = source.flipV;
      base.geometry = source.geometry;
      base.cropAspectRatio = source.cropAspectRatio;
    }
    if ((kinds & PARAM_MASK) !== 0) {
      for (let index = 0; index < baseLayers.length; index++) {
        if (sourceLayers.length === 0) break;
        const from = sourceLayers[Math.min(index, sourceLayers.length - 1)];
        baseLayers[index].maskLayers = from.maskLayers;
        baseLayers[index].mask = from.mask;
        baseLayers[index].maskAdjustments = from.maskAdjustments;
      }
    }
    if ((kinds & PARAM_PRESET) !== 0) {
      base.lutLink = source.lutLink;
      base.lutPresetName = source.lutPresetName;
      base.lutStack = source.lutStack;
    }
    if ((kinds & PARAM_BOKEH) !== 0) {
      base.bokeh = source.bokeh;
    }
    return JSON.stringify(base);
  }

  /** 单张粘贴：只把剪贴板里勾选的参数组合并到这张照片的侧车文件。 */
  private async pasteParamsToPhoto(photo: PhotoItem): Promise<void> {
    if (this.copiedParamKinds === PARAM_NONE || this.copiedParamJson.length === 0) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const target = new EditSession();
      target.imageUri = photo.uri;
      target.layers = [new Layer('背景')];
      const existing = EditSidecar.read(photo.uri, context.filesDir);
      if (existing) target.importAdjustmentState(existing);
      const merged = this.mergeParamSnapshot(target.exportAdjustmentState(), this.copiedParamJson,
        this.copiedParamKinds);
      if (!target.importAdjustmentState(merged)) {
        this.showMessage('剪贴板参数已失效，请重新复制');
        return;
      }
      if (!EditSidecar.write(photo.uri, target.exportAdjustmentState(), context.filesDir)) {
        this.showMessage('参数粘贴失败');
        return;
      }
      this.showMessage(`已粘贴参数到「${photo.displayName}」`);
    } catch (_error) {
      this.showMessage('参数粘贴失败');
    }
  }

  /** 复制属性后第一次点击用于进入多选，第二次点击才执行粘贴。 */
  private handlePasteButton(): void {
    if (!this.selectionMode) {
      this.selectionMode = true;
      this.selectedUris = [];
      this.showMessage('请选择要粘贴参数的图片');
      return;
    }
    if (this.selectedUris.length === 0) {
      this.showMessage('请先选择图片');
      return;
    }
    this.pastePropertiesToSelected();
  }

  private async pastePropertiesToSelected(): Promise<void> {
    if (this.copiedAdjustmentState.length === 0 || this.selectedUris.length === 0) return;
    const targets = this.photos.filter((photo: PhotoItem) => this.isPhotoSelected(photo.uri));
    if (targets.length === 0) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let applied = 0;
      for (const photo of targets) {
        const target = new EditSession();
        target.imageUri = photo.uri;
        target.layers = [new Layer('背景')];
        const existing = EditSidecar.read(photo.uri, context.filesDir);
        if (existing) target.importAdjustmentState(existing);
        const merged = this.mergeParamSnapshot(target.exportAdjustmentState(), this.copiedParamJson,
          this.copiedParamKinds === PARAM_NONE ? PARAM_ADJUST : this.copiedParamKinds);
        if (!target.importAdjustmentState(merged)) continue;
        if (EditSidecar.write(photo.uri, target.exportAdjustmentState(), context.filesDir)) applied++;
      }
      // 粘贴完成后清空剪贴板，主页按钮恢复为「筛选」。
      if (applied > 0) {
        this.copiedAdjustmentState = '';
        this.copiedParamJson = '';
        this.copiedParamKinds = PARAM_NONE;
      }
      this.selectedUris = [];
      this.selectionMode = false;
      this.showMessage(`已粘贴参数到 ${applied} 张图片`);
    } catch (_error) {
      this.showMessage('参数粘贴失败');
    }
  }

  /**
   * 分享一张照片的最终效果图：有编辑就按侧车参数渲染终稿再走系统分享面板，
   * 没编辑过直接分享原文件。渲染失败时退回原文件，不会卡住分享入口。
   */
  private async shareRenderedPhoto(photo: PhotoItem): Promise<void> {
    if (this.sharing) return;
    this.sharing = true;
    let source: image.PixelMap | null = null;
    let output: image.PixelMap | null = null;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const sidecar = EditSidecar.read(photo.uri, context.filesDir);
      if (!sidecar || this.isVideoPhotoItem(photo)) {
        await PhotoShareService.share(context, [photo]);
        return;
      }
      const session = new EditSession();
      session.imageUri = photo.uri;
      session.layers = [new Layer('背景')];
      session.importAdjustmentState(sidecar);
      await CameraProfiles.initialize(context.resourceManager);
      source = await PixelMapUtils.loadFromUri(photo.uri, 0, undefined, undefined, undefined,
        photo.displayName, undefined, false,
        session.rawSettings ?? { profile: CameraProfiles.CLASSIC_PROFILE_NAME, kelvin: 0, tint: 0 });
      if (!source) {
        await PhotoShareService.share(context, [photo]);
        return;
      }
      const info = await source.getImageInfo();
      const rendered = await ImageProcessor.renderToBuffer(source, info.size.width, info.size.height,
        session, false, (): boolean => false);
      if (!rendered) {
        await PhotoShareService.share(context, [photo]);
        return;
      }
      output = await ImageProcessor.createPixelMapFromBuffer(rendered.pixels, rendered.width, rendered.height);
      if (!output) {
        await PhotoShareService.share(context, [photo]);
        return;
      }
      const base = this.sanitizeExportBaseName(photo.displayName);
      const path = context.cacheDir + '/vivid_share_' + base + '_' + Date.now() + '.jpg';
      await PixelMapUtils.encodeImageToFile(output, path, 'JPG', 95);
      await PhotoShareService.share(context, [{ uri: path, displayName: base + '.jpg' }]);
    } catch (_error) {
      this.showMessage('分享失败，请稍后重试');
    } finally {
      if (output !== null) output.release();
      if (source !== null) source.release();
      this.sharing = false;
    }
  }

  /** 批量导出先选择 JPEG 品质，再按原始尺寸重跑每张图片的非破坏编辑。 */
  private exportSelectedPhotos(): void {
    if (this.exportInProgress || this.selectedUris.length === 0) return;
    const targets = this.photos.filter((photo: PhotoItem) => this.isPhotoSelected(photo.uri));
    if (targets.length === 0) return;
    this.batchExportDialogController = new CustomDialogController({
      builder: BatchExportQualityDialog({
        photos: targets,
        onConfirm: (quality: number, format: string) => {
          this.exportSelectedPhotosWithQuality(quality, format);
        },
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true,
    });
    this.batchExportDialogController.open();
  }

  private async exportSelectedPhotosWithQuality(quality: number, format: string): Promise<void> {
    if (this.exportInProgress || this.selectedUris.length === 0) return;
    const targets = this.photos.filter((photo: PhotoItem) => this.isPhotoSelected(photo.uri));
    if (targets.length === 0) return;
    this.exportInProgress = true;
    this.exportBackgrounded = false;
    this.exportCancelRequested = false;
    this.exportProgress = 0;
    this.exportStatus = `准备导出 ${targets.length} 张图片 · ${format}`;
    this.exportTrace(`start count=${targets.length} quality=${Math.round(quality)} format=${format}`);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const manager = abilityAccessCtrl.createAtManager();
      const permissionResult = await manager.requestPermissionsFromUser(context, ['ohos.permission.WRITE_IMAGEVIDEO']);
      const granted = permissionResult.authResults.length > 0 && permissionResult.authResults[0] === 0;
      if (!granted) {
        this.showMessage('需要「保存到相册」权限才能导出');
        return;
      }
      let exported = 0;
      let cancelled = false;
      for (let index = 0; index < targets.length; index++) {
        if (this.exportCancelRequested) {
          cancelled = true;
          break;
        }
        const photo = targets[index];
        const start = (index / targets.length) * 100;
        const span = 100 / targets.length;
        this.exportStatus = `正在导出 ${index + 1}/${targets.length} · ${photo.displayName}`;
        this.exportTrace(`photo_start index=${index + 1}/${targets.length}`);
        const ok = await this.exportPhotoToGallery(photo, context, quality, format, (fraction: number) => {
          this.exportProgress = Math.min(99, start + span * fraction);
        });
         if (ok) {
           exported++;
           this.exportProgress = Math.round(((index + 1) / targets.length) * 100);
         } else {
           // Do not report 100% for a failed RAW/JPEG asset write. Keep the
           // progress sheet actionable and let the final summary show the
           // failed count.
           this.exportProgress = Math.min(99, Math.round(start + span * 0.96));
         }
      }
       if (cancelled) {
         this.showMessage(`批量导出已取消，已完成 ${exported}/${targets.length} 张`);
         this.exportTrace(`batch_cancelled exported=${exported}/${targets.length}`);
       } else {
        this.showMessage(exported === targets.length
          ? `批量导出完成：${exported}/${targets.length} 张`
          : `批量导出完成：${exported}/${targets.length} 张，失败 ${targets.length - exported} 张`);
       this.exportTrace(`batch_done exported=${exported}/${targets.length}`);
       this.selectedUris = [];
       this.selectionMode = false;
       }
    } catch (_error) {
      this.exportTrace('batch_failed');
      this.showMessage('批量导出失败，请确认原文件仍可访问');
    } finally {
      this.exportInProgress = false;
      this.exportBackgrounded = false;
      this.exportCancelRequested = false;
      this.exportStatus = '';
    }
  }

  private async exportPhotoToGallery(photo: PhotoItem, context: common.UIAbilityContext, quality: number,
    format: string, onProgress: (fraction: number) => void): Promise<boolean> {
    let source: image.PixelMap | null = null;
    let exportPm: image.PixelMap | null = null;
    try {
      onProgress(0.04);
      this.exportTrace('stage=load_start');
      const session = new EditSession();
      session.imageUri = photo.uri;
      session.layers = [new Layer('背景')];
      const sidecar = EditSidecar.read(photo.uri, context.filesDir);
      if (sidecar) session.importAdjustmentState(sidecar);
      await CameraProfiles.initialize(context.resourceManager);
       // Media-library URIs often omit the original suffix. Passing the
       // display name keeps Panasonic RW2 on the RAW/embedded-preview path
       // instead of relying on URI extension inference.
       source = await PixelMapUtils.loadFromUri(photo.uri, 0, undefined, undefined, undefined, photo.displayName,
         undefined, false, session.rawSettings ?? { profile: CameraProfiles.CLASSIC_PROFILE_NAME, kelvin: 0, tint: 0 });
      if (!source) {
        this.exportTrace('stage=load_failed');
        return false;
      }
      const info = await source.getImageInfo();
      this.exportTrace(`stage=source_loaded width=${info.size.width} height=${info.size.height}`);
      onProgress(0.18);

      this.exportTrace('stage=render_start');
      const rendered = await ImageProcessor.renderToBuffer(
        source, info.size.width, info.size.height, session, false, (): boolean => false);
      this.exportTrace(rendered ? `stage=render_done width=${rendered.width} height=${rendered.height}` : 'stage=render_failed');
      onProgress(0.78);
      if (!rendered) return false;
      exportPm = await ImageProcessor.createPixelMapFromBuffer(rendered.pixels, rendered.width, rendered.height);
      if (!exportPm) {
        this.exportTrace('stage=pixelmap_failed');
        return false;
      }
      this.exportTrace('stage=encode_start');
      const base = this.sanitizeExportBaseName(photo.displayName);
      const fileName = `VIVID_${base}_${Date.now()}`;
      const ext = format === 'PNG' ? 'png' : (format === 'TIFF' ? 'tiff' : 'jpg');
      const cachePath = context.cacheDir + '/' + fileName + '.' + ext;
      await PixelMapUtils.encodeImageToFile(exportPm, cachePath, format, Math.round(quality));
      this.exportTrace('stage=encode_done');
      onProgress(0.9);
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, ext, { title: fileName });
      if (!uri) {
        this.exportTrace('stage=asset_failed');
        return false;
      }
       const input = fileIo.openSync(cachePath, fileIo.OpenMode.READ_ONLY);
       const output = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
       let size = 0;
       try {
         size = Number(fileIo.statSync(input.fd).size);
         if (size <= 0) throw new Error('Encoded file is empty');
         // copyFile is provider-safe for MediaLibrary asset descriptors and
         // avoids the partial write seen at the final progress tick for large
         // RW2-derived exports.
         await fileIo.copyFile(cachePath, output.fd);
         const written = Number(fileIo.statSync(output.fd).size);
         if (written !== size) throw new Error('Gallery file length mismatch');
       } finally {
         fileIo.closeSync(input);
         fileIo.closeSync(output);
       }
      this.exportTrace(`stage=asset_done bytes=${size}`);
      onProgress(1);
      return true;
    } catch (_error) {
      this.exportTrace('stage=failed');
      return false;
    } finally {
      if (source) source.release();
      if (exportPm) exportPm.release();
    }
  }

  private exportTrace(message: string): void {
    AppLogStore.add('export ' + message);
    hilog.info(0x0001, 'VIVID_EXPORT', '%{public}s', message);
  }

  private sanitizeExportBaseName(name: string): string {
    let value = name;
    const dot = value.lastIndexOf('.');
    if (dot > 0) value = value.substring(0, dot);
    value = value.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').trim();
    return value.length > 0 ? value.substring(0, 48) : '图片';
  }

  /** 快捷菜单单张删除：确认后从最近修图移除。 */
  private deleteSinglePhoto(photo: PhotoItem): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除图片',
      message: `确定从最近修图移除「${photo.displayName}」吗？`,
      buttons: [
        { text: '取消', color: '#536176' },
        { text: '删除', color: '#C4485C' },
      ],
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.photos = this.photos.filter((p: PhotoItem) => p.uri !== photo.uri);
        this.selectedUris = this.selectedUris.filter((u: string) => u !== photo.uri);
        this.persistImportedPhotos();
      }
    }).catch(() => {});
  }

  private showMessage(message: string): void {
    AppLogStore.add('ui ' + message);
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      console.info(message);
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.LibraryContent();
      if (this.photoMenuVisible) {
        // 点空白处关闭
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.18)')
          .onClick(() => { this.closePhotoMenu(); })
          .transition(TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseOut }));
        this.PhotoMenuPanel();
      }
    }
    .width('100%')
    .height('100%');
  }
}

/** 批量导出设置，与编辑页导出对话框对齐：格式（JPG/PNG/TIFF）与 JPEG 品质。 */
@CustomDialog
struct BatchExportQualityDialog {
  controller?: CustomDialogController;
  photos: PhotoItem[] = [];
  onConfirm: (quality: number, format: string) => void = () => {};
  @State private quality: number = 95;
  @State private format: string = 'JPG';

  build() {
    Column() {
      Text('批量导出设置')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.vivid_text_1b2536'))
        .fontFamily('HarmonyOS Sans')
        .width('100%')
        .textAlign(TextAlign.Center);
      Text(`将按原图像素导出 ${this.photos.length} 张图片`)
        .fontSize(12)
        .fontColor($r('app.color.vivid_text_718096'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 8 });

      Row() {
        Text('格式')
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .fontFamily('HarmonyOS Sans')
          .width(56);
        Blank();
        Select([{ value: 'JPG' }, { value: 'PNG' }, { value: 'TIFF' }])
          .value(this.format)
          .selected(this.format === 'PNG' ? 1 : (this.format === 'TIFF' ? 2 : 0))
          .width(150)
          .height(38)
          .font({ size: 13 })
          .fontColor($r('app.color.vivid_text_334158'))
          .backgroundColor($r('app.color.vivid_surface_f2f5f9'))
          .borderRadius(10)
          .optionBgColor('#FFFFFF')
          .optionFontColor('#334158')
          .onSelect((index: number, value: string) => {
            this.format = value;
          });
      }
      .width('100%')
      .margin({ top: 18 });

      Row() {
        Text('品质')
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .fontFamily('HarmonyOS Sans')
          .width(42);
        Text('低')
          .fontSize(11)
          .fontColor($r('app.color.vivid_text_8a95a5'));
        Slider({
          value: this.quality,
          min: 0,
          max: 100,
          step: 1,
          style: SliderStyle.OutSet,
        })
          .width('100%')
          .trackColor('#D3DAE5')
          .selectedColor('#5262EC')
          .blockColor('#FFFFFF')
          .blockBorderColor('#5262EC')
          .blockBorderWidth(2)
          .layoutWeight(1)
          .margin({ left: 8, right: 8 })
          .onChange((value: number) => {
            this.quality = value;
          });
        Text('高')
          .fontSize(11)
          .fontColor($r('app.color.vivid_text_8a95a5'));
        Text(`${Math.round(this.quality)}`)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.vivid_text_1b2536'))
          .width(34)
          .textAlign(TextAlign.End)
          .margin({ left: 8 });
      }
      .width('100%')
      .margin({ top: 14 })
      .opacity(this.format === 'JPG' ? 1 : 0.4);

      if (this.format !== 'JPG') {
        Text('PNG / TIFF 为无损格式，品质设置不生效')
          .fontSize(11)
          .fontColor($r('app.color.vivid_text_8a95a5'))
          .width('100%')
          .margin({ top: 6 });
      }

      Row() {
        Button('取消')
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_536176'))
          .type(ButtonType.Capsule)
          .backgroundColor('rgba(222,228,238,0.9)')
          .height(40)
          .layoutWeight(1)
          .onClick(() => {
            if (this.controller) this.controller.close();
          });
        Button('导出')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.vivid_text_ffffff'))
          .type(ButtonType.Capsule)
          .backgroundColor('#202A3B')
          .height(40)
          .layoutWeight(1)
          .margin({ left: 10 })
          .onClick(() => {
            this.onConfirm(Math.round(this.quality), this.format);
            if (this.controller) this.controller.close();
          });
      }
      .width('100%')
      .margin({ top: 18 });
    }
    .width('100%')
    .padding(24)
    .borderRadius(24)
    .backgroundColor($r('app.color.vivid_surface_ffffff'))
    .shadow({ radius: 32, color: 'rgba(20,30,50,0.18)', offsetY: 12 });
  }
}

/** 「复制参数」弹窗：勾选要搬运到别的照片上的参数组。 */
@CustomDialog
struct CopyParamsDialog {
  controller?: CustomDialogController;
  sourceName: string = '';
  onConfirm: (kinds: number) => void = () => {};
  @State private adjust: boolean = true;
  @State private crop: boolean = true;
  @State private maskOn: boolean = true;
  @State private preset: boolean = true;
  @State private bokeh: boolean = true;

  private selectedKinds(): number {
    let kinds: number = PARAM_NONE;
    if (this.adjust) kinds = kinds | PARAM_ADJUST;
    if (this.crop) kinds = kinds | PARAM_CROP;
    if (this.maskOn) kinds = kinds | PARAM_MASK;
    if (this.preset) kinds = kinds | PARAM_PRESET;
    if (this.bokeh) kinds = kinds | PARAM_BOKEH;
    return kinds;
  }

  @Builder
  OptionRow(label: string, checked: boolean, onToggle: () => void) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.vivid_text_334158'))
        .layoutWeight(1);
      Checkbox({ name: label, group: 'copyParams' })
        .select(checked)
        .selectedColor('#316CF4')
        .onChange((value: boolean) => { if (value !== checked) onToggle(); });
    }
    .width('100%')
    .height(46)
    .onClick(() => { onToggle(); });
  }

  build() {
    Column() {
      Text('复制参数')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.vivid_text_1b2536'))
        .width('100%')
        .textAlign(TextAlign.Center);
      Text(`选择要从「${this.sourceName}」复制的内容`)
        .fontSize(12)
        .fontColor($r('app.color.vivid_text_718096'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 8, bottom: 6 });
      this.OptionRow('调色', this.adjust, () => { this.adjust = !this.adjust; });
      this.OptionRow('裁剪', this.crop, () => { this.crop = !this.crop; });
      this.OptionRow('蒙版', this.maskOn, () => { this.maskOn = !this.maskOn; });
      this.OptionRow('预设', this.preset, () => { this.preset = !this.preset; });
      this.OptionRow('大光圈效果', this.bokeh, () => { this.bokeh = !this.bokeh; });
      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .fontColor($r('app.color.vivid_text_334158'))
          .type(ButtonType.Capsule)
          .height(42)
          .layoutWeight(1)
          .backgroundColor($r('app.color.vivid_surface_f2f5f9'))
          .onClick(() => { this.controller?.close(); });
        Button('复制')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.vivid_text_ffffff'))
          .type(ButtonType.Capsule)
          .height(42)
          .layoutWeight(1)
          .backgroundColor('#202A3B')
          .enabled(this.selectedKinds() !== PARAM_NONE)
          .onClick(() => {
            this.onConfirm(this.selectedKinds());
            this.controller?.close();
          });
      }
      .width('100%')
      .margin({ top: 16 });
    }
    .width('100%')
    .padding(24)
    .borderRadius(24)
    .backgroundColor($r('app.color.vivid_surface_ffffff'))
    .shadow({ radius: 32, color: 'rgba(20,30,50,0.18)', offsetY: 12 });
  }
}