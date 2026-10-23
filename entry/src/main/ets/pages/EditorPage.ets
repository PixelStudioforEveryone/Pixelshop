import { image } from '@kit.ImageKit';
import { taskpool } from '@kit.ArkTS';
import { processPixels, ProcessResult } from '../edit/engine/ProcessWorker';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { EditSession, DetailRegion } from '../edit/models/EditSession';
import { Layer } from '../edit/models/Layer';
import { ImageProcessor, DetailTileStamp } from '../edit/engine/ImageProcessor';
import { AiSegmentationService } from '../edit/engine/AiSegmentationService';
import { localContrastHaloRadius, LocalContrastParams, dehazeHazeColor } from '../edit/engine/LocalContrastCore';
import { retouchReadBounds } from '../edit/engine/RetouchCore';
import { denoiseSpatialRadius } from '../edit/engine/NoiseReduction';
import { buildGeometryMap } from '../edit/engine/GeometryMath';
import { RegionPixels } from '../edit/utils/RegionPixels';
import { DetailSourceReader } from '../edit/engine/DetailSourceReader';
import { PixelMapUtils, RawPreviewSettings } from '../edit/utils/PixelMapUtils';
import { RawDecodeDescriptor, RawSourceKind, rawDescriptorJson } from '../edit/utils/RawSourceContract';
import { CameraProfiles } from '../edit/utils/CameraProfiles';
import { RawPreviewLoader } from '../edit/utils/RawPreviewLoader';
import { EditSidecar } from '../edit/utils/EditSidecar';
import { EditorLayout } from '../views/EditorLayout';
import { PRESETS, Preset, applyPreset } from '../edit/models/Presets';
import { CustomLut, LutLibraryStore, createLutStackItem } from '../edit/models/LutLibrary';
import { abilityAccessCtrl, common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetricsUnit, display } from '@kit.ArkUI';
import { RawNativeBridge } from '../edit/utils/RawNativeBridge';
import { ExportFrameOptions, ExportFrameRenderer } from '../edit/utils/ExportFrameRenderer';
import { EditorCommandId } from '../edit/engine/EditorShortcuts';
import { VividNative } from '../components/VividNativeTheme';
import { AppLogStore } from './home/HomeShared';
import { RecentPhotoRecord, RecentPhotoStore } from '../services/RecentPhotoStore';

// 调色预览只需保证滑块反馈流畅；原图在导出时才按需解码。
// Keep interactive previews light enough for color grading and masks. The
// original source is still decoded only for export, so this does not reduce
// output quality.
// A bounded interactive surface keeps slider feedback responsive. When the
// user zooms, EditorCanvas requests a full-resolution tile for only the
// visible region; export still renders the complete original separately.
// Settled previews use a 1280px long edge for a visibly sharper canvas. The
// processing engine still drops to 512px during active slider gestures and
// export always re-renders from the original source dimensions.
const EDIT_PREVIEW_MAX_DIMENSION: number = 1280;
const DEMO_IMAGE_NAME: string = 'P2213215.jpg';

interface CameraSelectOption {
  value: string;
}

@Entry
@Component
struct EditorPage {
  private previewMaxDimension(): number {
    try {
      const screen = display.getDefaultDisplaySync();
      return Math.max(1280, Math.min(2048, Math.ceil(Math.max(screen.width, screen.height) * 0.85)));
    } catch (_error) { return EDIT_PREVIEW_MAX_DIMENSION; }
  }
  @Provide('editSession') editSession: EditSession = new EditSession();
  @State loading: boolean = true;
  @State windowWidth: number = 360;
  @State windowHeight: number = 800;
  // 导出状态全局化（AppStorage + 全局浮层 ExportOverlay）：跨页面可见，
  // 返回主界面后台进度按钮仍然显示。
  @StorageLink('vividExportActive') exportInProgress: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @StorageProp('selectedCameraProfile') @Watch('invalidateRawProfileSource') private selectedRawProfile: string = '';
  @StorageProp('rawWhiteBalanceKelvin') @Watch('invalidateRawProfileSource') private rawKelvin: number = 0;
  @StorageProp('rawWhiteBalanceTint') @Watch('invalidateRawProfileSource') private rawTint: number = 0;
  @State private savingLut: boolean = false;
  // Raised whenever the keyboard must let go: a dialog opens, the photo changes,
  // the page goes away. The canvas watches it and releases every held key, so the
  // original is never left on screen.
  private shortcutResetVersion: number = 0;
  private modalDepth: number = 0;
  /** 蒙版操作菜单打开时，全局返回手势先把它收掉，而不是退出编辑器。 */
  onBackPress(): boolean {
    if (AppStorage.get<boolean>('maskMenuOpen') === true) {
      AppStorage.setOrCreate('maskMenuOpen', false);
      return true;
    }
    return false;
  }

  /** Runs a shared editor command from a button. */
  private runEditorCommand(id: EditorCommandId): void {
    if (id === EditorCommandId.Undo) {
      if (!this.editSession.canUndo()) return;
      this.editSession.undo();
      ImageProcessor.process(this.editSession);
      return;
    }
    if (id === EditorCommandId.Redo) {
      if (!this.editSession.canRedo()) return;
      this.editSession.redo();
      ImageProcessor.process(this.editSession);
      return;
    }
    if (id === EditorCommandId.ZoomFit) {
      this.editSession.canvasScale = 1;
      this.editSession.canvasOffsetX = 0;
      this.editSession.canvasOffsetY = 0;
    }
  }
  /** Called around every dialog so keyboard shortcuts stand down and any held
   * key is released before the dialog takes the keyboard. */
  private beginModal(): void {
    this.modalDepth++;
    AppStorage.setOrCreate('editorModalOpen', true);
    this.requestShortcutReset();
  }
  private endModal(): void {
    this.modalDepth = this.modalDepth > 0 ? this.modalDepth - 1 : 0;
    AppStorage.setOrCreate('editorModalOpen', this.modalDepth > 0);
    this.requestShortcutReset();
  }
  private requestShortcutReset(): void {
    this.shortcutResetVersion++;
    AppStorage.setOrCreate('editorShortcutReset', this.shortcutResetVersion);
  }
  @StorageLink('vividExportProgress') exportProgress: number = 0;
  @StorageLink('vividExportStatus') exportStatus: string = '';
  @StorageLink('vividExportBackgrounded') exportBackgrounded: boolean = false;
  // The header title is derived from this field. It must be observable: as a
  // plain field, switching photos updated the filmstrip selection (@Prop) while
  // the title still showed the previous photo's name.
  @State private imageUri: string = '';
  @State private materialMenuOpen: boolean = false;
  @State private recentMaterials: RecentPhotoRecord[] = [];

  private async syncSystemTheme(): Promise<void> {
    try {
      if (AppStorage.get('vividNightMode') !== undefined) return;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const configuration = await context.resourceManager.getConfiguration();
      const night = configuration.colorMode === 0;
      AppStorage.setOrCreate('vividNightMode', night);
    } catch (_error) {
      // Keep the light default if configuration is temporarily unavailable.
    }
  }
  private toggleNightMode(): void {
    this.isNightMode = !this.isNightMode;
    AppStorage.setOrCreate('vividNightMode', this.isNightMode);
    // 标记手动锁定：系统日夜间再切换时由 EntryAbility 解除并全局跟随。
    AppStorage.setOrCreate('vividNightModeManual', true);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.getApplicationContext().setColorMode(this.isNightMode ?
        ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (_error) {
      // Keep the persisted mode if the host does not expose a color-mode API.
    }
  }
  private invalidateRawProfileSource(): void {
    this.clearDetailRender();
    if (this.fullResSource && !this.exportInProgress) {
      this.fullResSource.release();
      this.fullResSource = null;
    }
    if (!this.loading && RawPreviewLoader.isRawFile(this.imageDisplayName())) {
      this.editSession.setRawSettings(PixelMapUtils.rawPreviewSettings());
      if (this.rawSettingsSaveTimer !== -1) clearTimeout(this.rawSettingsSaveTimer);
      // WB sliders update storage during dragging. Coalesce disk writes.
      this.rawSettingsSaveTimer = setTimeout(() => {
        this.rawSettingsSaveTimer = -1;
        this.saveEditSidecar();
      }, 300);
    }
  }

  private rawSettingsSaveTimer: number = -1;

  private async saveCurrentLut(): Promise<void> {
    if (this.savingLut) return;
    this.savingLut = true;
    try {
      const size = 33;
      const pixels = new Uint8ClampedArray(size * size * size * 4);
      let offset = 0;
      for (let b = 0; b < size; b++) {
        for (let g = 0; g < size; g++) {
          for (let r = 0; r < size; r++) {
            pixels[offset++] = Math.round(r * 255 / (size - 1));
            pixels[offset++] = Math.round(g * 255 / (size - 1));
            pixels[offset++] = Math.round(b * 255 / (size - 1));
            pixels[offset++] = 255;
          }
        }
      }
      const params = ImageProcessor.globalLutParams(this.editSession, pixels.buffer as ArrayBuffer, size * size, size);
      const result = await taskpool.execute(new taskpool.Task(processPixels, params)) as ProcessResult;
      const mapped = new Uint8Array(result.buffer);
      const values: number[] = [];
      for (let i = 0; i < mapped.length; i += 4) {
        values.push(mapped[i] / 255, mapped[i + 1] / 255, mapped[i + 2] / 255);
      }
      const id = 'saved-' + Date.now().toString(36);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let sampleUri = 'resource://lut_sample_portrait';
      if (this.editSession.sourcePixelMap) {
        const jpeg = await PixelMapUtils.encodeToJpeg(this.editSession.sourcePixelMap, 85);
        if (jpeg) {
          sampleUri = context.filesDir + '/lut_sample_' + id + '.jpg';
          const file = fileIo.openSync(sampleUri, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
          try { fileIo.writeSync(file.fd, jpeg); } finally { fileIo.closeSync(file); }
        }
      }
      const lut: CustomLut = {
        id: id, name: '我的调色 ' + new Date().toLocaleTimeString(), sourceUri: 'generated://' + id,
        sampleCount: size * size * size, format: 'cube', category: '自定义', adjustments: {},
        sampleUri: sampleUri, coverUri: sampleUri,
        table: { size: size, values: values, domainMin: [0, 0, 0], domainMax: [1, 1, 1] },
      };
      LutLibraryStore.setPending(lut);
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/LutImportConfirmPage', params: { saveMode: true } });
    } catch (_error) {
      this.getUIContext().getPromptAction().showToast({ message: '生成 LUT 失败，请重试' });
    } finally { this.savingLut = false; }
  }
  private presetName: string = '';
  private customPresetJson: string = '';
  private incomingLutId: string = '';
  // Identity of the load currently owning the session. Bumped before every
  // decode so a slow older load can be recognised and discarded instead of
  // overwriting the newer photo. Comparing uris alone cannot do this: opening
  // the same file twice produces two loads with the same uri (ABA).
  private loadGeneration: number = 0;
  // False once the page is gone. Every async load rechecks it, so a decode
  // that finishes after aboutToDisappear cannot publish into the session.
  private pageAlive: boolean = false;
  @State private rawDecodeInfo: RawDecodeDescriptor | null = null;
  private exportDialogController: CustomDialogController | null = null;
  // 全分辨率源图：只在导出时懒加载，用它重跑管线得到原始尺寸。
  private fullResSource: image.PixelMap | null = null;
  /**
   * 去朦胧的整帧雾色缓存。
   *
   * 雾色是**整帧统计量**，而瓦片只看得见自己那一块，所以放大后必须用整帧算出的值
   * （lightcraft 同样把整帧 airlight 带进窗口渲染）。但它只依赖源图内容，与曝光、
   * LUT、缩放、平移都无关——每请求一块瓦片就重读一次整帧（`RegionPixels.read` 到
   * 512px）纯属浪费，连续缩放时会反复解码整张图，这正是"放大后局部渲染很久才生效"
   * 的主要来源之一。按源图身份缓存，换图（`fullResSource` 换了对象）自然失效。
   */
  private hazeCacheSource: image.PixelMap | null = null;
  private hazeCacheValue: number[] = [];
  private fullResWidth: number = 0;
  private fullResHeight: number = 0;
  // Cache the most recent full-resolution graded frame so panning a zoomed
  // view only crops a new tile instead of running the colour pipeline again.
  private detailRequestSerial: number = 0;
  private detailRendering: boolean = false;
  private pendingDetailRegion: DetailRegion | null = null;
  /**
   * The edit state the currently displayed detail tile was rendered from.
   * Preview frames do not belong to this stamp: they can arrive for the same
   * edit (refinement) or for a display-only toggle (hold-to-compare), and
   * both used to destroy a perfectly valid tile. See invalidateStaleDetailTile.
   */
  private detailTileStamp: DetailTileStamp | null = null;
  // 模糊背景用的屏幕尺寸副本：先缩放到窗口比例，再模糊铺满，避免只显示原图一角。
  @State private backdropPixelMap: image.PixelMap | null = null;
  private backdropTimer: number = -1;
  private backdropRunning: boolean = false;
  private backdropInitialized: boolean = false;
  @StorageLink('vividExportCancelRequested') private exportCancelRequested: boolean = false;
  private sidecarDirectory: string = '';
  private previewRevision: number = 0;
  private exportMetadata: ExportFrameOptions = {
    enabled: false,
    style: '经典相框',
    brand: 'Panasonic',
    camera: 'S1RII',
    fontSize: 16,
    fontColor: '#111111',
    lens: '28-105mm F2.8 DG DN | Art',
    focalLength: '49mm',
    aperture: 'F4.0',
    shutter: '1/500s',
    iso: 'ISO100',
  };
  // Read source metadata once per editor image. Reopening the export sheet
  // must preserve any manual edits made in the previous sheet.
  private exportMetadataLoaded: boolean = false;
  @State private captureInfo: string = '';

  aboutToAppear(): void {
    this.pageAlive = true;
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params && params['imageUri']) {
      this.imageUri = params['imageUri'] as string;
    }
    if (params && params['presetName']) {
      this.presetName = params['presetName'] as string;
    }
    if (params && params['customPresetJson']) {
      this.customPresetJson = params['customPresetJson'] as string;
    }
    if (params && params['lutId']) this.incomingLutId = params['lutId'] as string;
    this.editSession.imageUri = this.imageUri;
    this.exportMetadataLoaded = false;
    this.loadRecentMaterials();
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.sidecarDirectory = context.filesDir;
    } catch (_error) {
      this.sidecarDirectory = '';
    }
    AppStorage.setOrCreate('windowWidth', this.windowWidth);
    this.previewRevision = 0;
    AppStorage.setOrCreate('previewVersion', 0);
    AppStorage.setOrCreate('detailVersion', 0);
    AppStorage.setOrCreate('editorPanelRequest', this.incomingLutId.length > 0 ? 3 : -1);
    AppStorage.setOrCreate('maskRevision', this.editSession.maskRevision);

    // Initialize with a default layer
    this.editSession.layers = [new Layer('背景')];
    this.editSession.activeLayerIndex = 0;
    this.editSession.adjustmentScope = 0;
    // The editor decides between the CPU preview Image and the GPU surface
    // from these three fields. Entering the page is the one moment where a
    // value left behind by a previous visit must not survive: a stale
    // gpuPreviewActive=true would hide the preview Image while the new
    // surface has not presented anything yet, which reads as an empty canvas.
    // A fresh session already starts false, but resetting here also covers a
    // session that is re-entered through the same page instance.
    this.editSession.gpuPreviewActive = false;
    this.editSession.gpuSurfaceDirty = false;
    this.editSession.gpuSurfaceId = '';
    this.editSession.showBefore = false;
    AppStorage.setOrCreate('vividShowBefore', false);

    this.exportDialogController = null;

    // 预览每次更新后刷新模糊背景副本。
    this.editSession.onPreviewUpdated = () => {
      console.info(`VIVID_FRAME t=${Date.now()} event=page_preview_callback version=${this.previewRevision} gpu=${this.editSession.gpuPreviewActive} detail=${this.editSession.detailPixelMap !== null}`);
      // Any adjustment invalidates the zoomed full-resolution tile. The next
      // zoom/pan request will rebuild it from the new session state. This is
      // deliberately a *staleness* check, not an unconditional clear: a
      // refinement frame or a hold-to-compare frame for the same edit must
      // neither release nor hide the sharp tile.
      this.invalidateStaleDetailTile();
      // Notify only the canvas that a new PixelMap is ready.  Keeping this
      // separate from the observed session object prevents the adjustment
      // panel and its Scroll from being rebuilt after every render.
      this.previewRevision++;
      AppStorage.setOrCreate('previewVersion', this.previewRevision);
      // 背景只在打开图片时生成一次，后续调整只更新前景预览。
      if (!this.backdropInitialized) this.scheduleBackdropRefresh();
    };

    if (this.imageUri) {
      this.loadImage(this.imageUri);
    } else {
      this.loadDemoImage();
    }
  }

  /**
   * 生成保持原始宽高比的背景副本，再交给 Image.blur 做高斯模糊。
   * 横图和竖图统一使用等比缩放，避免为了铺满窗口而拉伸变形；
   * 画布中的 Cover/Contain 双层背景负责填充与展示完整画面。
   */
  private scheduleBackdropRefresh(): void {
    if (this.backdropTimer !== -1) clearTimeout(this.backdropTimer);
    this.backdropTimer = setTimeout(() => {
      this.backdropTimer = -1;
      this.refreshBackdrop();
    }, 200);
  }

  private async refreshBackdrop(): Promise<void> {
    // 背景已改为纯色填充，不再生成照片的模糊副本：省一次缩放与一份常驻内存。
    this.backdropInitialized = true;
  }

  /** 快速演示：全分辨率源图用于导出，1920 预览用于实时编辑。 */
  async loadDemoImage(): Promise<void> {
    if (!this.pageAlive) return;
    this.loading = true;
    this.loadGeneration++;
    const generation = this.loadGeneration;
    this.editSession.processGeneration = generation;
    this.clearDetailRender();
    ImageProcessor.clearSourceCache(this.editSession);
    ImageProcessor.clearRegionMaskCache();
    // AI 蒙版缓存必须同源清理：它的键是"模型+代数+尺寸"，**不含照片标识**，所以同尺寸的
    // 第二张照片会命中第一张的缓存并直接复用其蒙版。同时 cancelPending 会递增代数，让
    // segment() 与两个蒙版面板里那道"代数已变则丢弃结果"的守卫真正生效——此前它从未被
    // 调用，等于死代码。（不放在 ImageProcessor 里，避免把原生 AI 模块拉进渲染引擎的
    // 依赖图，那会让大量独立测试在加载期崩溃。）
    AiSegmentationService.cancelPending();
    this.backdropInitialized = false;
    let preview: image.PixelMap | null = null;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const data = await context.resourceManager.getRawFileContent(DEMO_IMAGE_NAME);

      // 预览解码：限制在 1280 内，保证滑块实时。desiredSize 不保持宽高比，
      // 必须按原图比例计算目标尺寸，否则图片会被拉伸变形。
      const previewSource = image.createImageSource(data.buffer as ArrayBuffer);
      const previewOptions: image.DecodingOptions = {
        editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      };
      const previewInfo = await previewSource.getImageInfo();
      if (!this.pageAlive || generation !== this.loadGeneration) {
        previewSource.release();
        return;
      }
      const previewRawW = previewInfo.size.width;
      const previewRawH = previewInfo.size.height;
      this.fullResWidth = previewRawW;
      this.fullResHeight = previewRawH;
      const previewScale = Math.min(1, this.previewMaxDimension() / Math.max(previewRawW, previewRawH));
      previewOptions.desiredSize = {
        width: Math.max(1, Math.round(previewRawW * previewScale)),
        height: Math.max(1, Math.round(previewRawH * previewScale)),
      };
      preview = await previewSource.createPixelMap(previewOptions);
      previewSource.release();
    } catch (_error) {
      console.error('Failed to load bundled demo image');
    }
    // The demo decode awaits; a photo switch or page exit in the meantime makes
    // this result stale. Comparing generations - not the empty uri - also
    // covers reopening the same file.
    if (!this.pageAlive || generation !== this.loadGeneration ||
      this.editSession.processGeneration !== generation) {
      if (preview) preview.release();
      return;
    }
    if (preview) {
      this.editSession.sourcePixelMap = preview;
      const info = await preview.getImageInfo();
      if (!this.pageAlive || generation !== this.loadGeneration ||
        this.editSession.sourcePixelMap !== preview) return;
      this.editSession.imageWidth = info.size.width;
      this.editSession.imageHeight = info.size.height;
      this.applyIncomingPreset();
      await ImageProcessor.process(this.editSession);
      if (!this.pageAlive || generation !== this.loadGeneration) return;
      this.loading = false;
      this.updateExportMetadataFromSource();
      return;
    }
    // 演示图缺失或解码失败时回退到合成占位图。
    this.createPlaceholderImage();
  }

  private currentRawSourceKind(): RawSourceKind | null {
    const info = this.rawDecodeInfo;
    if (info === null) return null;
    return info.sourceKind;
  }

  async loadImage(uri: string, generation: number = 0): Promise<void> {
    if (!this.pageAlive || (generation !== 0 && generation !== this.loadGeneration)) return;
    // Anything decoded from here on belongs to this generation. A page that
    // has been destroyed, or a newer switch that already started, must not be
    // overwritten by this load's late results.
    if (generation === 0) {
      this.loadGeneration++;
      generation = this.loadGeneration;
    }
    this.loading = true;
    this.editSession.processGeneration = generation;
    this.imageUri = uri;
    this.editSession.imageUri = uri;
    // A destroyed page must not publish into a recycled session: the editor
    // can be re-entered with the same session id, which would otherwise let a
    // late decode from the previous visit win.
    if (!this.pageAlive || generation !== this.loadGeneration) return;
    // Restore RAW settings before decoding, so the first displayed pixels,
    // zoomed detail and export all use this image's saved configuration.
    const restoredSidecar = this.restoreEditSidecar();
    if (!restoredSidecar) this.editSession.setRawSettings(null);
    const isRaw = RawPreviewLoader.isRawFile(this.imageDisplayName());
    const rawSettings: RawPreviewSettings = isRaw && this.editSession.rawSettings
      ? { profile: this.editSession.rawSettings.profile, kelvin: this.editSession.rawSettings.kelvin,
        tint: this.editSession.rawSettings.tint }
      : { profile: isRaw ? CameraProfiles.CLASSIC_PROFILE_NAME : '', kelvin: 0, tint: 0 };
    this.editSession.setRawSettings(isRaw ? rawSettings : null);
    AppStorage.setOrCreate('rawCameraModel', '');
    AppStorage.setOrCreate('rawCameraProfileMissing', false);
    // Only new/legacy RAW edits without stored development settings use
    // Pixel Classic. An explicit saved empty profile is also preserved.
    AppStorage.setOrCreate('selectedCameraProfile', rawSettings.profile);
    AppStorage.setOrCreate('rawWhiteBalanceKelvin', rawSettings.kelvin);
    AppStorage.setOrCreate('rawWhiteBalanceTint', rawSettings.tint);
    const profileContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await CameraProfiles.initialize(profileContext.resourceManager);
    // Every await above and below is a point where a newer switch (or page
    // destruction) can happen. Recheck before touching any page or session
    // state, otherwise a slow older load overwrites the newer photo.
    if (!this.pageAlive || generation !== this.loadGeneration ||
      this.editSession.processGeneration !== generation) return;
    this.clearDetailRender();
    ImageProcessor.clearSourceCache(this.editSession);
    ImageProcessor.clearRegionMaskCache();
    // AI 蒙版缓存必须同源清理：它的键是"模型+代数+尺寸"，**不含照片标识**，所以同尺寸的
    // 第二张照片会命中第一张的缓存并直接复用其蒙版。同时 cancelPending 会递增代数，让
    // segment() 与两个蒙版面板里那道"代数已变则丢弃结果"的守卫真正生效——此前它从未被
    // 调用，等于死代码。（不放在 ImageProcessor 里，避免把原生 AI 模块拉进渲染引擎的
    // 依赖图，那会让大量独立测试在加载期崩溃。）
    AiSegmentationService.cancelPending();
    this.exportMetadataLoaded = false;
    this.captureInfo = '';
    this.loadRecentMaterials();
    this.backdropInitialized = false;
    this.rawDecodeInfo = null;
    AppStorage.setOrCreate('rawDecodeSource', '');
    AppStorage.setOrCreate('rawSourceName', this.imageDisplayName());
    this.editSession.imageUri = uri;
    // 全分辨率源图延迟到导出时读取，打开图片阶段只保留轻量预览。
    if (this.fullResSource) {
      this.fullResSource.release();
      this.fullResSource = null;
    }
    this.fullResWidth = 0;
    this.fullResHeight = 0;
    let pm: image.PixelMap | null = null;
    try {
      pm = await PixelMapUtils.loadFromUri(uri, this.previewMaxDimension(),
      undefined, undefined,
      (width: number, height: number): void => {
        // loadFromUri decodes a bounded preview, so pm.getImageInfo() below is
        // intentionally smaller. Keep the source dimensions separately for
        // the export settings dialog and for the later full-resolution pass.
        // The callbacks fire during the decode and can be delivered after a
        // newer switch started; both are generation-tagged like the result.
        if (!this.pageAlive || generation !== this.loadGeneration) return;
        this.fullResWidth = width;
        this.fullResHeight = height;
      }, this.imageDisplayName(), (info: RawDecodeDescriptor): void => {
        if (!this.pageAlive || generation !== this.loadGeneration) return;
        this.rawDecodeInfo = info;
        AppStorage.setOrCreate('rawDecodeSource', rawDescriptorJson(info));
      }, false, rawSettings);
    } catch (error) {
      if (this.pageAlive && generation === this.loadGeneration) {
        console.warn('VIVID_FRAME image decode failed: ' + String(error));
      }
    }
    // A late decode returning null is a failure of the photo being left, not
    // of the one now selected: it must not raise the unsupported-image dialog
    // or install a placeholder over the newer image.
    if (!this.pageAlive || generation !== this.loadGeneration ||
      this.editSession.processGeneration !== generation) {
      if (pm) pm.release();
      return;
    }
    if (pm) {
      this.editSession.sourcePixelMap = pm;
      const kind: RawSourceKind | null = this.currentRawSourceKind();
      if (kind === RawSourceKind.EMBEDDED_JPEG_PREVIEW) {
        this.getUIContext().getPromptAction().showDialog({
          title: '无 RAW 配置文件',
          message: '未找到此相机的 RAW 配置文件，经典开源色彩解码也不可用，已采用内嵌 JPG 预览读取。',
          buttons: [{ text: '知道了', color: '#316CF4' }],
        });
      } else if (AppStorage.get<boolean>('rawCameraProfileMissing') &&
        kind === RawSourceKind.NATIVE_RENDERED_RGB) {
        this.getUIContext().getPromptAction().showToast({ message: '此相机无 RAW 配置文件，已应用「Pixel 经典」开源色彩。' });
      }
      const info = await pm.getImageInfo();
      // getImageInfo is another await: the source may already be replaced.
      if (!this.pageAlive || generation !== this.loadGeneration ||
        this.editSession.sourcePixelMap !== pm) return;
      this.editSession.imageWidth = info.size.width;
      this.editSession.imageHeight = info.size.height;
      if (!restoredSidecar) this.applyIncomingPreset();
      await ImageProcessor.process(this.editSession);
    } else {
      this.showUnsupportedImageDialog();
      await this.createPlaceholderImage();
    }
    if (!this.pageAlive || generation !== this.loadGeneration) return;
    this.loading = false;
    this.updateExportMetadataFromSource();
  }

  aboutToDisappear(): void {
    // Invalidate every in-flight load first: the session id can be reused by
    // the next visit, and a decode from this page must not publish into it.
    this.loadGeneration++;
    this.pageAlive = false;
    if (this.rawSettingsSaveTimer !== -1) clearTimeout(this.rawSettingsSaveTimer);
    this.rawSettingsSaveTimer = -1;
    // Leaving the page drops the keyboard: release every held command first.
    this.requestShortcutReset();
    AppStorage.setOrCreate('editorModalOpen', false);
    AppStorage.setOrCreate('editorInputFocused', false);
    RawNativeBridge.clearCache();
    this.saveEditSidecar();
    this.editSession.onPreviewUpdated = null;
    this.clearDetailRender();
    // The page is going away: nothing can display the parked frames, so they
    // are released here. A photo switch keeps them alive (see switchEditorPhoto).
    ImageProcessor.clearSourceCache(this.editSession, true);
    ImageProcessor.clearRegionMaskCache();
    if (this.backdropTimer !== -1) {
      clearTimeout(this.backdropTimer);
      this.backdropTimer = -1;
    }
    if (this.fullResSource) {
      this.fullResSource.release();
      this.fullResSource = null;
    }
    if (this.backdropPixelMap) {
      this.backdropPixelMap.release();
      this.backdropPixelMap = null;
    }
  }

  private showUnsupportedImageDialog(): void {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '无法解码图片',
        message: '该文件不是受支持的图片格式（已尝试内嵌 RAW 预览），已切换到演示图片继续编辑。',
        buttons: [{ text: '确定', color: '#5262EC' }],
      });
    } catch (_error) {
      console.error('Unable to show unsupported image dialog');
    }
  }

  async createPlaceholderImage(): Promise<void> {
    // Create a simple checkerboard placeholder for demo
    const generation = this.loadGeneration;
    const w = 800;
    const h = 600;
    try {
      const opts: image.InitializationOptions = {
        editable: true,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        size: { width: w, height: h },
      };
      const placeholderColors = new ArrayBuffer(w * h * 4);
      const pm = await image.createPixelMap(placeholderColors, opts);
      const buffer = new ArrayBuffer(w * h * 4);
      const pixels = new Uint8Array(buffer);

      // Create a gradient + pattern placeholder
      for (let y = 0; y < h; y++) {
        for (let x = 0; x < w; x++) {
          const idx = (y * w + x) * 4;
          const fx = x / w;
          const fy = y / h;

          // Gradient: blue sky to warm ground
          const skyR = 40 + fy * 180;
          const skyG = 80 + fy * 120;
          const skyB = 180 - fy * 100;

          // Sun in top-right
          const sunDist = Math.hypot((x - w * 0.75) / (w * 0.3), (y - h * 0.2) / (h * 0.3));
          const sunGlow = Math.exp(-sunDist * sunDist * 3);

          pixels[idx] = Math.min(255, skyR + sunGlow * 255);
          pixels[idx + 1] = Math.min(255, skyG + sunGlow * 220);
          pixels[idx + 2] = Math.min(255, skyB + sunGlow * 100);
          pixels[idx + 3] = 255;
        }
      }

      await pm.writeBufferToPixels(buffer);
      // The placeholder is only a fallback for the load that is still current.
      // A newer switch already owns the session, so drop these pixels.
      if (!this.pageAlive || generation !== this.loadGeneration ||
        this.editSession.processGeneration !== generation) {
        pm.release();
        return;
      }
      this.editSession.sourcePixelMap = pm;
      this.editSession.imageWidth = w;
      this.editSession.imageHeight = h;
      this.applyIncomingPreset();
      this.loading = false;
      await ImageProcessor.process(this.editSession);
    } catch (_e) {
      if (this.pageAlive && generation === this.loadGeneration) this.loading = false;
    }
  }

  build() {
    Stack() {
      // 整页背景改为纯色填充：日间纯白、夜间纯黑。
      // 之前铺的是当前照片的高斯模糊副本，照片颜色会透到面板/工具栏后面，
      // 日间看着是一层灰雾，控件对比度也跟着照片变。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isNightMode ? '#000000' : '#FFFFFF');
      // 工具栏与编辑区域保持透明，底下的照片由系统材质卡片折射出来。
      Column() {
      Row() {
        Button(this.windowWidth >= 600 ? '‹  作品' : '‹')
          .fontSize(14)
          .fontColor($r('app.color.vivid_text_415068'))
          .type(ButtonType.Capsule)
          .backgroundColor(this.isNightMode ? '#25272C' : 'rgba(255,255,255,0.72)')
          .width(this.windowWidth >= 600 ? 78 : 36)
          .height(36)
          .onClick(() => {
            this.saveEditSidecar();
            this.getUIContext().getRouter().back();
          });

        Column() {
          Row() {
            Text(this.imageDisplayName())
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.vivid_text_1c273a'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
          }
          .width('100%')
          .margin({ top: 2 })
          .onClick(() => {
            this.materialMenuOpen = !this.materialMenuOpen;
            if (this.materialMenuOpen) this.loadRecentMaterials();
          });
          if (this.rawSourceLabel().length > 0) {
            Text(this.rawSourceLabel())
              .fontSize(9)
              .fontColor($r('app.color.vivid_text_8792a3'))
              .margin({ top: 1 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 });

        Blank();

        if (this.windowWidth >= 840) {
          Button({ type: ButtonType.Circle }) {
            Text(this.isNightMode ? '☼' : '☾')
              .fontSize(17)
              .fontColor(this.isNightMode ? '#FFFFFF' : '#1C2738');
          }
          .width(34)
          .height(34)
          .padding(0)
          .backgroundColor(this.isNightMode ? '#25272C' : 'rgba(255,255,255,0.72)')
          .accessibilityText(this.isNightMode ? '切换日间模式' : '切换夜间模式')
          .onClick(() => { this.toggleNightMode(); })
          .margin({ right: 8 });
        }
        if (this.windowWidth >= 980) {
          Text('按住查看原图')
            .fontSize(11)
            // 日间：浅灰填充 + 主文字色；夜间：深色底 + 纯白字。
            .fontColor(this.isNightMode ? Color.White : VividNative.textPrimary)
            .backgroundColor(this.isNightMode ? '#25272C' : VividNative.surfaceSub)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(15)
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                ImageProcessor.setBeforePreview(this.editSession, true);
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                ImageProcessor.setBeforePreview(this.editSession, false);
              }
            });
        }

        Button(this.savingLut ? '生成中' : '保存 LUT')
          .fontSize(10).height(32).padding({ left: 9, right: 9 })
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontColor(this.isNightMode ? Color.White : Color.Black).backgroundColor(Color.Transparent)
          .enabled(!this.savingLut && !this.loading && !this.exportInProgress)
          .onClick(() => { this.saveCurrentLut(); });

        Button() {
          Image($r('app.media.history_undo')).width(21).height(21)
            .fillColor($r('app.color.history_icon')).opacity(this.editSession.canUndo() ? 1 : 0.35);
        }
          .type(ButtonType.Capsule)
          .backgroundColor(this.isNightMode ? '#30343B' : 'rgba(255,255,255,0.66)')
          .fontColor(this.editSession.canUndo() ? '#26334A' : '#A7AFBA')
          .width(36).height(36)
          .enabled(this.editSession.canUndo()).accessibilityText('撤销')
          .margin({ left: 8 })
          .onClick(() => {
            this.runEditorCommand(EditorCommandId.Undo);
          });

        Button() {
          Image($r('app.media.history_redo')).width(21).height(21)
            .fillColor($r('app.color.history_icon')).opacity(this.editSession.canRedo() ? 1 : 0.35);
        }
          .type(ButtonType.Capsule)
          .backgroundColor(this.isNightMode ? '#30343B' : 'rgba(255,255,255,0.66)')
          .fontColor(this.editSession.canRedo() ? '#26334A' : '#A7AFBA')
          .width(36).height(36)
          .enabled(this.editSession.canRedo()).accessibilityText('恢复')
          .margin({ left: 2 })
          .onClick(() => {
            this.runEditorCommand(EditorCommandId.Redo);
          });

        Button('导出')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .type(ButtonType.Capsule)
          .backgroundColor('#202A3B')
          .fontColor($r('app.color.vivid_text_ffffff'))
          .height(36)
          .margin({ left: 8 })
          .enabled(!this.exportInProgress)
          .onClick(() => {
            this.openExportDialog();
          });
      }
      .width('100%')
      .height(58)
      .padding({ left: 10, right: 10 });

      // Editor area
      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(40).height(40)
            .color('#8392FF');

          Text('加载中...')
            .fontSize(14)
            .fontColor($r('app.color.vivid_text_7c899b'))
            .margin({ top: 12 });
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(255,255,255,0)');
      } else {
        EditorLayout({ onRequestDetailRender: (region: DetailRegion | null) => {
          this.requestDetailRender(region);
        }, onAddPhoto: () => { this.chooseEditorPhoto(); }, photos: this.recentMaterials,
          currentUri: this.imageUri,
          captureInfo: this.captureInfo,
          onSelectPhoto: (uri: string) => { this.switchEditorPhoto(uri); },
          onRatePhoto: (uri: string, stars: number) => { this.rateEditorPhoto(uri, stars); },
        }).layoutWeight(1);
      }

      }
      .width('100%')
      .height('100%')
      // 沉浸式布局下仅扩展背景，工具栏内容保留顶部安全区，避免
      // 被状态栏图标和摄像头挖孔覆盖。模糊背景之上不再叠加玻璃纱罩。
      .safeAreaPadding({ top: this.windowWidth >= 840 ? 0 : 24 })
      .onAreaChange((_: Area, newArea: Area) => {
        this.windowWidth = newArea.width as number;
        this.windowHeight = newArea.height as number;
        AppStorage.setOrCreate('windowWidth', this.windowWidth);
        this.scheduleBackdropRefresh();
      });

      // Desktop material switcher: the former filmstrip is intentionally gone;
      // the current filename remains the compact entry point for recent assets.
      if (this.materialMenuOpen && this.windowWidth >= 840) {
        Column() {
          Text('最近素材')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isNightMode ? '#FFFFFF' : '#1C2738')
            .margin({ bottom: 8 });
          if (this.recentMaterials.length === 0) {
            Text('暂无最近素材')
              .fontSize(11)
              .fontColor(this.isNightMode ? '#AEB6C4' : '#718096')
              .padding({ top: 8, bottom: 12 });
          } else {
            ForEach(this.recentMaterials.slice(0, 8), (item: RecentPhotoRecord) => {
              Row() {
                Text(item.displayName)
                  .fontSize(11)
                  .fontColor(this.isNightMode ? '#F4F6FA' : '#263247')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1);
                Text(item.uri === this.imageUri ? '当前' : '切换')
                  .fontSize(10)
                  .fontColor(item.uri === this.imageUri ? '#316CF4' : (this.isNightMode ? '#AEB6C4' : '#718096'))
                  .margin({ left: 10 });
              }
              .width('100%')
              .height(34)
              .padding({ left: 8, right: 8 })
              .borderRadius(8)
              .backgroundColor(item.uri === this.imageUri ?
                (this.isNightMode ? '#303B50' : '#EEF3FF') : '#00000000')
              .onClick(() => { this.switchEditorPhoto(item.uri); });
            }, (item: RecentPhotoRecord) => item.uri);
          }
          Row() {
            Text('从图库选择…')
              .fontSize(11)
              .fontColor('#316CF4');
          }
          .width('100%')
          .height(36)
          .padding({ left: 8, right: 8 })
          .margin({ top: 6 })
          .borderRadius(8)
          .backgroundColor(this.isNightMode ? '#303B50' : '#F2F5FA')
          .onClick(() => {
            this.materialMenuOpen = false;
            this.chooseEditorPhoto();
          });
        }
        .width(292)
        .padding(12)
        .backgroundColor(this.isNightMode ? '#25272C' : '#FFFFFF')
        .borderRadius(12)
        .border({ width: 1, color: this.isNightMode ? '#4A4F59' : '#D9E0EA' })
        .shadow({ radius: 24, color: 'rgba(0,0,0,0.28)', offsetY: 8 })
        .position({ x: 112, y: 70 })
        .zIndex(150);
      }
      // 导出进度卡片与后台环形进度按钮已迁移到全局浮层 ExportOverlay
      // （EntryAbility 经 OverlayManager 挂载），跨页面可见。
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isNightMode ? '#000000' : '#FFFFFF');
  }

  /** Restore a Camera Raw-style sidecar before applying a preset. */
  private restoreEditSidecar(): boolean {
    if (!this.imageUri) return false;
    const serialized = EditSidecar.read(this.imageUri, this.sidecarDirectory);
    if (!serialized) return false;
    const restored = this.editSession.importAdjustmentState(serialized);
    if (restored && this.editSession.lutLink.length > 0) {
      this.editSession.lutPreset = {
        id: 'sidecar:' + this.editSession.lutLink,
        sourceUri: this.editSession.lutLink,
        name: this.editSession.lutPresetName.length > 0 ? this.editSession.lutPresetName : '已保存 LUT',
        sampleCount: 0,
        adjustments: {},
      } as CustomLut;
    }
    return restored;
  }

  private imageDisplayName(): string {
    if (!this.imageUri) return DEMO_IMAGE_NAME;
    let value = this.imageUri;
    const query = value.indexOf('?');
    if (query >= 0) value = value.substring(0, query);
    const hash = value.indexOf('#');
    if (hash >= 0) value = value.substring(0, hash);
    const slash = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
    if (slash >= 0) value = value.substring(slash + 1);
    try {
      value = decodeURIComponent(value);
    } catch (_error) {
      // Provider names may not be URI encoded.
    }
    return value.length > 0 ? value : DEMO_IMAGE_NAME;
  }

  private rawSourceLabel(): string {
    if (!this.rawDecodeInfo) return '';
    if (this.rawDecodeInfo.sourceKind === 'embedded_jpeg_preview') return 'RAW 内嵌 JPEG 预览 · 非线性 · 不可作为 RAW 导出';
    if (this.rawDecodeInfo.sourceKind === 'system_decoder_rgba') return '系统 RAW 解码 · 色彩状态未知 · 未应用 DCP';
    return this.rawDecodeInfo.dcpApplied ? 'RAW · 相机配置参考显色' : 'RAW · 线性相机 RGB';
  }

  /** Decode the original only when export needs it; editing never keeps this copy. */
  private async ensureFullResSource(): Promise<boolean> {
    if (this.fullResSource) return true;
    try {
      if (this.imageUri) {
        this.fullResSource = await PixelMapUtils.loadFromUri(this.imageUri, 0,
          (progress: number): void => {
            this.exportProgress = Math.max(4, Math.min(16, 4 + Math.round(progress * 12)));
            this.exportStatus = `正在读取原图… ${Math.round(progress * 100)}%`;
          },
          (): boolean => this.exportCancelled(), undefined, this.imageDisplayName(), (info: RawDecodeDescriptor): void => {
            this.rawDecodeInfo = info;
            AppStorage.setOrCreate('rawDecodeSource', rawDescriptorJson(info));
          });
      } else {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const data = await context.resourceManager.getRawFileContent(DEMO_IMAGE_NAME);
        const fullSource = image.createImageSource(data.buffer as ArrayBuffer);
        try {
          this.fullResSource = await fullSource.createPixelMap({
            editable: false,
            desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
          });
        } finally {
          fullSource.release();
        }
      }
      if (this.fullResSource) {
        const info = await this.fullResSource.getImageInfo();
        this.fullResWidth = info.size.width;
        this.fullResHeight = info.size.height;
        return true;
      }
    } catch (_error) {
      this.fullResSource = null;
    }
    return false;
  }

  /**
   * Drop only the displayed tile. Keeping this separate from the rendered
   * full-resolution cache lets a pan reuse the expensive graded frame.
   */
  private clearDetailTile(): void {
    this.editSession.clearDetailPixelMap();
    AppStorage.setOrCreate('detailVersion', this.editSession.detailRevision);
  }

  /** Invalidate the currently displayed high-resolution tile.
   *
   * `reason` is logged so a device trace can tell a real edit (stale) from a
   * zoom-out/teardown. Doing nothing when there is neither a tile nor work in
   * flight matters: this used to be called unconditionally on every preview
   * frame and, during a hold/pinch, hundreds of times per second, each call
   * cancelling the tile render that was about to finish.
   */
  private clearDetailRender(reason: string = 'explicit'): void {
    const hadTile = this.editSession.detailPixelMap !== null;
    const hadWork = this.detailRendering || this.pendingDetailRegion !== null;
    if (!hadTile && !hadWork) return;
    console.info(`VIVID_FRAME t=${Date.now()} event=detail_clear reason=${reason} ` +
      `present=${hadTile} rendering=${this.detailRendering}`);
    this.detailRequestSerial++;
    this.pendingDetailRegion = null;
    this.clearDetailTile();
    this.detailTileStamp = null;
  }

  /**
   * Stamp describing everything a published tile's pixels depend on, apart
   * from the visible region (panning reuses the same grade at a new region).
   * `processingRequestVersion` advances for real edits only; the hold-to-
   * compare toggle no longer bumps it (see ImageProcessor.setBeforePreview).
   */
  private currentDetailTileStamp(): DetailTileStamp {
    const session = this.editSession;
    const geometryKey = [session.cropLeft.toFixed(6), session.cropTop.toFixed(6),
      session.cropRight.toFixed(6), session.cropBottom.toFixed(6),
      session.rotation.toFixed(0), session.flipH ? '1' : '0', session.flipV ? '1' : '0'].join('|');
    const sourceKey = this.loadGeneration.toString() + ':' + this.imageDisplayName() + ':' +
      (this.fullResSource !== null ? '1' : '0');
    return {
      requestVersion: session.processingRequestVersion,
      // Some edits (layer visibility, presets, mask layer toggles) only call
      // bumpProcessing(), so the public version is a required half of the
      // edit generation; checking only the request version would keep a tile
      // after exactly those changes.
      publicVersion: session.processingVersion,
      maskRevision: session.maskRevision,
      geometryKey: geometryKey,
      sourceKey: sourceKey,
    };
  }

  private isDetailTileCurrent(): boolean {
    const stamp = this.detailTileStamp;
    if (this.editSession.detailPixelMap === null || stamp === null) return false;
    return ImageProcessor.detailTileMatches(stamp, this.currentDetailTileStamp());
  }

  /**
   * A preview frame is published. It may only retire the detail tile when the
   * edit state really changed; when the stamp still matches, the tile is
   * newer/equal information for the zoomed view and must stay on top.
   */
  private invalidateStaleDetailTile(): void {
    if (this.editSession.detailPixelMap !== null && this.isDetailTileCurrent()) {
      const stamp = this.detailTileStamp;
      const version = stamp !== null ? stamp.requestVersion : -1;
      console.info(`VIVID_FRAME t=${Date.now()} event=detail_tile_kept ` +
        `request=${version} masks=${this.editSession.maskRevision}`);
      return;
    }
    this.clearDetailRender('stale');
  }

  /**
   * Render the current edit for the visible source region at source resolution
   * and publish a tile. Slider changes continue to publish only the bounded
   * preview; this path is entered after a zoom/pan debounce.
   */
  private async requestDetailRender(region: DetailRegion | null): Promise<void> {
    if (!region) {
      this.clearDetailRender('no-region');
      return;
    }
    if (this.editSession.isCropping || this.editSession.rotation !== 0 ||
      this.editSession.flipH || this.editSession.flipV) {
      this.clearDetailRender('geometry');
      return;
    }
    if (!ImageProcessor.isRegionRenderSafe(this.editSession)) { this.clearDetailRender('unsafe'); return; }
    this.pendingDetailRegion = region;
    if (this.detailRendering) return;
    this.detailRendering = true;
    // 瓦片耗时分解：这条路径跨"源图解码/瓦片读入/整帧雾色/蒙版/渲染/贴图"六段，
    // 只打总时长无法判断该修哪一段。所有字段都以 ms 为单位，与 VIVID_DETAIL
    // 现有 request/ready 标记同一命名空间，真机上按 t= 排序即可对上一次请求。
    const requestStart = Date.now();
    hilog.info(0x0001, 'VIVID_DETAIL', '%{public}s',
      `request ${Math.round(region.left * 1000) / 10}%/${Math.round(region.top * 1000) / 10}% ` +
      `${Math.round(region.width * 1000) / 10}%x${Math.round(region.height * 1000) / 10}% ` +
      `scale=${this.editSession.canvasScale.toFixed(2)} dehaze=${this.editSession.detail.dehaze} ` +
      `masks=${this.editSession.maskRevision} src=${this.fullResSource !== null}`);
    const requestSerial = ++this.detailRequestSerial;
    const requestProcessingVersion = this.editSession.processingRequestVersion;
    const requestPublicVersion = this.editSession.processingVersion;
    try {
      const sourceStart = Date.now();
      if (!(await this.ensureFullResSource()) || !this.fullResSource) return;
      const sourceMs = Date.now() - sourceStart;
      if (requestSerial !== this.detailRequestSerial) return;
      const currentRegion = this.pendingDetailRegion;
      this.pendingDetailRegion = null;
      if (!currentRegion) return;
      const isStale = (): boolean => {
        return requestSerial !== this.detailRequestSerial ||
          requestProcessingVersion !== this.editSession.processingRequestVersion ||
          requestPublicVersion !== this.editSession.processingVersion;
      };

      const fullWidth = this.fullResWidth, fullHeight = this.fullResHeight;
      // The canvas region is expressed in the displayed (possibly cropped)
      // frame. Convert it back to original-source coordinates before reading a
      // tile; otherwise zooming after a crop samples the wrong pixels.
      const cropLeft = Math.max(0, Math.min(1, this.editSession.cropLeft));
      const cropTop = Math.max(0, Math.min(1, this.editSession.cropTop));
      const cropWidth = Math.max(0.0001, Math.min(1, this.editSession.cropRight) - cropLeft);
      const cropHeight = Math.max(0.0001, Math.min(1, this.editSession.cropBottom) - cropTop);
      const sourceLeft = cropLeft + currentRegion.left * cropWidth;
      const sourceTop = cropTop + currentRegion.top * cropHeight;
      const sourceRight = cropLeft + (currentRegion.left + currentRegion.width) * cropWidth;
      const sourceBottom = cropTop + (currentRegion.top + currentRegion.height) * cropHeight;
      const x = Math.max(0, Math.min(fullWidth - 1, Math.floor(sourceLeft * fullWidth)));
      const y = Math.max(0, Math.min(fullHeight - 1, Math.floor(sourceTop * fullHeight)));
      const right = Math.max(x + 1, Math.min(fullWidth, Math.ceil(sourceRight * fullWidth)));
      const bottom = Math.max(y + 1, Math.min(fullHeight, Math.ceil(sourceBottom * fullHeight)));
      const maxEdge = Math.min(2048, Math.max(this.getUIContext().vp2px(this.windowWidth),
        this.getUIContext().vp2px(this.windowHeight)) * 1.15);
      // Neighbour filters need a halo before the final crop. Otherwise every
      // loupe tile clamps at its own edge and adds a moving two-pixel seam.
      // The denoise window is resolution-relative, so the halo must be derived
      // from the same radius the filter will actually use: with a 6000 px source
      // that is 5 px, and a hard-coded 2 would leave a visible seam.
      const noiseEnabled = this.editSession.denoise.luminance > 0 || this.editSession.denoise.color > 0;
      const noiseRadius = denoiseSpatialRadius(fullWidth, fullHeight);
      const scale = Math.min(1, maxEdge / Math.max(right - x, bottom - y));
      // 外扩必须覆盖**所有已启用阶段**的核半径，不只是降噪。纹理/清晰度/去朦胧/锐化的
      // 核宽可达数十像素，而这里此前只按降噪半径算——不降噪时 pad 为 0，于是开了细节
      // 再放大的瓦片四周没有 halo，边界出现接缝和错值。lightcraft 正是为此按各阶段
      // sigma 推边距并断言"窗口渲染 == 整帧渲染后裁切"。
      let pad = noiseEnabled ? Math.ceil(noiseRadius / scale) + 1 : 0;
      // ArkTS 不做结构化类型转换，所以显式取一次字段。
      const detailForHalo: LocalContrastParams = {
        texture: this.editSession.detail.texture,
        clarity: this.editSession.detail.clarity,
        dehaze: this.editSession.detail.dehaze,
        sharpenAmount: this.editSession.detail.sharpenAmount,
        sharpenRadius: this.editSession.detail.sharpenRadius,
        sharpenDetail: this.editSession.detail.sharpenDetail,
        sharpenMasking: this.editSession.detail.sharpenMasking,
      };
      const detailHalo = localContrastHaloRadius(fullWidth, detailForHalo);
      if (detailHalo > 0) pad = Math.max(pad, Math.ceil(detailHalo / scale) + 1);
      // 光学校正（畸变/横向色差）也要邻域：瓦片只读自己的矩形时，最外圈采到
      // 的是瓦片自身边缘像素，与整图渲染差出一整圈。位移上界按瓦片自身所在
      // 半径求（靠近画面中心的瓦片只需很小的 halo），再并进 readBounds 的外扩。
      const opticsHalo = ImageProcessor.opticsHaloPad(this.editSession.optics,
        x, y, right, bottom, fullWidth, fullHeight);
      if (opticsHalo > 0) pad = Math.max(pad, opticsHalo);
      const readBounds = retouchReadBounds(this.editSession.retouchMarks,
        [Math.max(0, x - pad), Math.max(0, y - pad), Math.min(fullWidth, right + pad), Math.min(fullHeight, bottom + pad)],
        fullWidth, fullHeight);
      const tileX = readBounds[0], tileY = readBounds[1], tileRight = readBounds[2], tileBottom = readBounds[3];
      const readStart = Date.now();
      const sampled = await DetailSourceReader.read(this.fullResSource, tileX, tileY,
        tileRight - tileX, tileBottom - tileY, maxEdge, isStale, 'tile');
      const readMs = Date.now() - readStart;
      if (!sampled || isStale()) return;
      hilog.info(0x0001, 'VIVID_DETAIL', '%{public}s',
        `source-read ms=${readMs} tile=${sampled.width}x${sampled.height} ` +
        `bounds=${tileX},${tileY},${tileRight},${tileBottom} pad=${pad} maxEdge=${maxEdge}`);
      // 去朦胧的雾色是**整帧统计量**：瓦片只看得见自己那一块，自算出来的雾色与整帧
      // 不同，放大之后的效果就和整帧对不上。lightcraft 为此把整帧 airlight 显式带进
      // 窗口渲染（`RenderRequest::window`）；这里同样在请求瓦片时对整帧采样算一次，
      // 存到会话上，由快照带进瓦片渲染。
      const hazeStart = Date.now();
      if (this.editSession.detail.dehaze !== 0) {
        if (this.hazeCacheSource === this.fullResSource && this.hazeCacheValue.length === 3) {
          // 缓存命中：省掉一次整帧读取 + 降采样（连续缩放时每瓦片都要一次）。
          this.editSession.detailHaze = this.hazeCacheValue.slice();
        } else {
          const whole = await RegionPixels.read(this.fullResSource, 0, 0, fullWidth, fullHeight,
            512, isStale);
          if (whole && !isStale()) {
            const value = dehazeHazeColor(new Uint8ClampedArray(whole.pixels),
              whole.width, whole.height);
            this.hazeCacheSource = this.fullResSource;
            this.hazeCacheValue = value;
            this.editSession.detailHaze = value.slice();
          }
        }
      } else {
        this.editSession.detailHaze = [];
      }
      const hazeMs = Date.now() - hazeStart;
      hilog.info(0x0001, 'VIVID_DETAIL', '%{public}s',
        `haze ms=${hazeMs} cached=${this.hazeCacheSource === this.fullResSource} ` +
        `value=${this.editSession.detailHaze.length === 3 ? this.editSession.detailHaze.map((v: number): string => v.toFixed(3)).join(',') : 'none'}`);
      const snapshotStart = Date.now();
      const detailSession = ImageProcessor.regionSnapshot(this.editSession, tileX, tileY, tileRight - tileX, tileBottom - tileY,
        fullWidth, fullHeight, sampled.width, sampled.height);
      // Crop has already been applied while selecting the source tile. Applying
      // it again here would shrink/offset the high-resolution tile a second time.
      detailSession.cropLeft = (x - tileX) / (tileRight - tileX);
      detailSession.cropTop = (y - tileY) / (tileBottom - tileY);
      detailSession.cropRight = (right - tileX) / (tileRight - tileX);
      detailSession.cropBottom = (bottom - tileY) / (tileBottom - tileY);
      const snapshotMs = Date.now() - snapshotStart;
      // 蒙版 alpha 只依赖整帧归一化几何，与瓦片缓冲尺寸无关。此前每块瓦片都按
      // 自己的尺寸重算一遍（regionSnapshot 还会清空 maskCache），平移/缩放时
      // 每个蒙版反复付全尺寸栅格化的钱。这里按整帧栅格化一次并缓存，瓦片用
      // 自己的源矩形裁切+缩放；renderToBuffer 的 prepareMasks 随后直接命中。
      const regionMaskStart = Date.now();
      const regionMasks = await ImageProcessor.prepareRegionMasks(this.editSession, detailSession,
        `${this.loadGeneration}:${this.imageDisplayName()}`, fullWidth, fullHeight,
        tileX, tileY, tileRight - tileX, tileBottom - tileY,
        sampled.width, sampled.height, isStale);
      const regionMaskMs = Date.now() - regionMaskStart;
      const renderStart = Date.now();
      const result = await ImageProcessor.renderToBuffer(this.fullResSource, sampled.width, sampled.height,
        detailSession, true, isStale, true, sampled.pixels);
      const renderMs = Date.now() - renderStart;
      if (!result || isStale()) return;
      const tileWidth = result.width, tileHeight = result.height, tilePixels = result.pixels;
      const publishStart = Date.now();
      const tileMap = await ImageProcessor.createPixelMapFromBuffer(tilePixels, tileWidth, tileHeight);
      const publishMs = Date.now() - publishStart;
      if (!tileMap || isStale()) {
        if (tileMap) tileMap.release();
        return;
      }
      const old = this.editSession.detailPixelMap;
      this.editSession.detailPixelMap = tileMap;
      this.editSession.detailRegion = currentRegion;
      this.editSession.detailWidth = tileWidth;
      this.editSession.detailHeight = tileHeight;
      this.editSession.detailRevision++;
      // isStale() held across every await above, so the live session is still
      // the state this tile was rendered from. This stamp is what keeps a
      // later preview frame from retiring the tile.
      this.detailTileStamp = this.currentDetailTileStamp();
      AppStorage.setOrCreate('detailVersion', this.editSession.detailRevision);
      hilog.info(0x0001, 'VIVID_DETAIL', '%{public}s',
        `ready ${tileWidth}x${tileHeight} from ${this.fullResWidth}x${this.fullResHeight} ` +
        `total=${Date.now() - requestStart}ms source=${sourceMs} read=${readMs} haze=${hazeMs} ` +
        `snapshot=${snapshotMs} regionMask=${regionMaskMs} masks=${regionMasks} ` +
        `render=${renderMs} publish=${publishMs}`);
      if (old) {
        try { old.release(); } catch (_error) { /* stale tile */ }
      }
    } catch (error) {
      console.info('VIVID_DETAIL full-resolution tile unavailable: ' + JSON.stringify(error));
    } finally {
      this.detailRendering = false;
      if (this.pendingDetailRegion) {
        // A pan arrived while the current tile was rendering. Render the latest
        // region on the next turn; this also covers an adjustment invalidating
        // an in-flight frame while the user keeps the canvas zoomed.
        setTimeout(() => {
          const next = this.pendingDetailRegion;
          if (next) this.requestDetailRender(next);
        }, 0);
      }
    }
  }

  /** Persist the current non-destructive edit state beside the source image. */
  private saveEditSidecar(): void {
    if (this.loading || !this.imageUri) return;
    if (!this.editSession.sourcePixelMap && !this.editSession.previewPixelMap) return;
    if (RawPreviewLoader.isRawFile(this.imageDisplayName())) {
      this.editSession.setRawSettings(PixelMapUtils.rawPreviewSettings());
    }
    const saved = EditSidecar.write(this.imageUri, this.editSession.exportAdjustmentState(), this.sidecarDirectory);
    if (!saved) {
      console.error('Unable to write Pixelshop sidecar for ' + this.imageUri);
    }
  }

  private async loadRecentMaterials(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.recentMaterials = await RecentPhotoStore.list(context);
    } catch (_error) {
      this.recentMaterials = [];
    }
  }

  private async rateEditorPhoto(uri: string, stars: number): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await RecentPhotoStore.rate(context, uri, stars);
      await this.loadRecentMaterials();
    } catch (_error) {
      this.getUIContext().getPromptAction().showToast({ message: '星级保存失败' });
    }
  }

  private async switchEditorPhoto(uri: string): Promise<void> {
    if (uri.length === 0 || uri === this.imageUri) {
      this.materialMenuOpen = false;
      return;
    }
    try {
      if (this.rawSettingsSaveTimer !== -1) clearTimeout(this.rawSettingsSaveTimer);
      this.rawSettingsSaveTimer = -1;
      // The source image is being replaced, so a render started for the old
      // photo must not publish into the new one. Bumping the generation here -
      // before the decode - is what makes every `await` below re-checkable.
      this.loadGeneration++;
      const generation = this.loadGeneration;
      this.saveEditSidecar();
      const previousSource = this.editSession.sourcePixelMap;
      // A new photo must not inherit a held key from the old one.
      this.requestShortcutReset();
      // Drop the rendered frames of the photo being left before the session
      // is reset: clearSourceCache owns the last two preview PixelMaps and
      // must see the old source still in place. The newest frame is parked
      // instead of released - `reset()` nulls previewPixelMap, so this is the
      // point where a parked frame becomes unreachable.
      ImageProcessor.clearSourceCache(this.editSession);
    // AI 蒙版缓存必须同源清理：它的键是"模型+代数+尺寸"，**不含照片标识**，所以同尺寸的
    // 第二张照片会命中第一张的缓存并直接复用其蒙版。同时 cancelPending 会递增代数，让
    // segment() 与两个蒙版面板里那道"代数已变则丢弃结果"的守卫真正生效——此前它从未被
    // 调用，等于死代码。（不放在 ImageProcessor 里，避免把原生 AI 模块拉进渲染引擎的
    // 依赖图，那会让大量独立测试在加载期崩溃。）
    AiSegmentationService.cancelPending();
      this.editSession.reset();
      ImageProcessor.releaseRetainedFrames(this.editSession.sessionId);
      if (previousSource) previousSource.release();
      this.editSession.sourcePixelMap = null;
      this.materialMenuOpen = false;
      this.imageUri = uri;
      // Late callbacks from the previous photo are rejected by generation,
      // not by the uri string, so re-opening the same file cannot make an
      // older load overwrite a newer one (ABA on identical uris).
      if (generation !== this.loadGeneration) return;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await RecentPhotoStore.add(context, uri);
      if (generation !== this.loadGeneration) return;
      await this.loadImage(uri, generation);
      if (generation !== this.loadGeneration) return;
      await this.loadRecentMaterials();
    } catch (_error) {
      this.getUIContext().getPromptAction().showToast({ message: '无法切换素材' });
    }
  }
  /** Replace the editor source from the PC素材栏 without stacking another route. */
  private async chooseEditorPhoto(): Promise<void> {
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const result = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: this.windowWidth >= 840 ? 100 : 1,
      });
      if (!result.photoUris || result.photoUris.length === 0) return;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      for (let index = 1; index < result.photoUris.length; index++) {
        await RecentPhotoStore.add(context, result.photoUris[index]);
      }
      await this.switchEditorPhoto(result.photoUris[0]);
    } catch (_error) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开图库' });
    }
  }  private applyIncomingPreset(): void {
    if (!this.editSession.activeLayer) return;
    const catalogLut = this.incomingLutId.length > 0 ? LutLibraryStore.find(this.incomingLutId) : undefined;
    if (catalogLut) {
      this.editSession.lutStack = [createLutStackItem(catalogLut, 1)];
      this.editSession.lutPreset = catalogLut;
      this.editSession.lutLink = catalogLut.sourceUri;
      this.editSession.lutPresetName = catalogLut.name;
      this.editSession.bumpProcessing();
      return;
    }
    let preset: Preset | undefined = PRESETS.find((item: Preset) => item.name === this.presetName);
    let lut: CustomLut | null = null;
    if (!preset && this.customPresetJson.length > 0) {
      try {
        lut = JSON.parse(this.customPresetJson) as CustomLut;
        preset = lut as Preset;
      } catch (_error) {
        preset = undefined;
      }

    }
    if (preset) {
      applyPreset(this.editSession.activeLayer.adjustments, preset);
      if (lut) {
        this.editSession.lutStack = [createLutStackItem(lut, 1)];
        this.editSession.lutPreset = lut;
        this.editSession.lutLink = lut.sourceUri;
        this.editSession.lutPresetName = lut.name;
      } else {
        this.editSession.lutPreset = null;
        this.editSession.lutLink = '';
        this.editSession.lutPresetName = '';
      }
      this.editSession.bumpProcessing();
    }
  }

  /** Read camera metadata once when the export sheet is opened.  RAW files are
   * handled locally from their TIFF/EXIF header; the image source API is used
   * first for JPEG/HEIF/DNG providers that expose properties directly. */
  private async updateExportMetadataFromSource(): Promise<void> {
    if (this.exportMetadataLoaded) return;
    const metadataUri = this.imageUri;
    const values: Record<string, string> = {};
    try {
      if (this.imageUri) {
        await this.readExportImageSourceProperties(metadataUri, values);
      }

      let bytes: ArrayBuffer | null = null;
      if (!this.imageUri) {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const data = await context.resourceManager.getRawFileContent(DEMO_IMAGE_NAME);
        const size = Math.min(data.byteLength, 8 * 1024 * 1024);
        bytes = data.buffer.slice(data.byteOffset, data.byteOffset + size) as ArrayBuffer;
      } else {
        let file: fileIo.File | null = null;
        try {
          file = fileIo.openSync(metadataUri, fileIo.OpenMode.READ_ONLY);
          // A media-library URI is not a filesystem path.  The descriptor was
          // opened with user-granted access and is valid for stat/read.
          const stat = fileIo.statSync(file.fd);
          const size = Math.min(stat.size, 8 * 1024 * 1024);
          const buffer = new ArrayBuffer(size);
          const read = fileIo.readSync(file.fd, buffer, { length: size });
          bytes = read === size ? buffer : buffer.slice(0, Math.max(0, read));
        } finally {
          if (file) fileIo.closeSync(file);
        }
      }

      if (bytes && bytes.byteLength >= 8) {
        const view = new DataView(bytes);
        const parseClassicTiff = (base: number): void => {
          if (base < 0 || base + 8 > view.byteLength) return;
          const little = view.getUint8(base) === 0x49;
          if (!little && view.getUint8(base) !== 0x4D) return;
          const magic = view.getUint16(base + 2, little);
          // Panasonic RW2 uses 85 (IIU\0), while classic TIFF uses 42. Both
          // retain the same 32-bit first-IFD pointer; BigTIFF (43) is omitted.
          if (magic !== 42 && magic !== 85) return;
          const firstIfd = base + view.getUint32(base + 4, little);
          const nextIfd = this.readExportIfd(view, base, firstIfd, little, values, 0, new Set<number>());
          if (nextIfd > 0) this.readExportIfd(view, base, nextIfd, little, values, 0, new Set<number>());
        };
        const startsTiff = (view.getUint8(0) === 0x49 && view.getUint8(1) === 0x49) ||
          (view.getUint8(0) === 0x4D && view.getUint8(1) === 0x4D);
        if (startsTiff) parseClassicTiff(0);
        // JPEG APP1 is normally near the start; RW2 can carry a second APP1
        // inside its embedded JPEG preview. It supplements the main IFD.
        const embeddedExif = this.findEmbeddedExifBase(view);
        if (embeddedExif >= 0) parseClassicTiff(embeddedExif);
      }
      if (this.imageUri !== metadataUri) return;
      this.applyExportMetadataValues(values);
      this.updateCaptureInfo(values);
      hilog.info(0x0001, 'VIVID_META',
        'source metadata fields model=%{public}d lens=%{public}d focal=%{public}d aperture=%{public}d shutter=%{public}d iso=%{public}d',
        values['model'] ? 1 : 0, values['lens'] ? 1 : 0, values['focal'] ? 1 : 0,
        values['aperture'] ? 1 : 0, values['shutter'] ? 1 : 0, values['iso'] ? 1 : 0);
    } catch (_error) {
      // Content URIs and protected camera files may not expose raw bytes. Keep
      // any values obtained from ImageSource and leave the remaining fields
      // editable in the dialog.
      if (this.imageUri !== metadataUri) return;
      this.applyExportMetadataValues(values);
      this.updateCaptureInfo(values);
      hilog.info(0x0001, 'VIVID_META',
        'source metadata fields model=%{public}d lens=%{public}d focal=%{public}d aperture=%{public}d shutter=%{public}d iso=%{public}d',
        values['model'] ? 1 : 0, values['lens'] ? 1 : 0, values['focal'] ? 1 : 0,
        values['aperture'] ? 1 : 0, values['shutter'] ? 1 : 0, values['iso'] ? 1 : 0);
    } finally {
      if (this.imageUri === metadataUri) this.exportMetadataLoaded = true;
    }
  }

  private updateCaptureInfo(values: Record<string, string>): void {
    const labels: string[] = [];
    if (values['iso']) labels.push(this.formatExportIso(values['iso']));
    if (values['focal']) labels.push(this.formatExportFocal(values['focal']));
    if (values['aperture']) labels.push(this.formatExportAperture(values['aperture']));
    if (values['shutter']) labels.push(this.formatExportShutter(values['shutter']));
    this.captureInfo = labels.join('    ');
  }

  /** Locate the TIFF header that follows an "Exif\0\0" APP1 signature. */
  private findEmbeddedExifBase(view: DataView): number {
    for (let i = 2; i + 10 < view.byteLength; i++) {
      if (view.getUint8(i) === 0x45 && view.getUint8(i + 1) === 0x78 &&
        view.getUint8(i + 2) === 0x69 && view.getUint8(i + 3) === 0x66 &&
        view.getUint8(i + 4) === 0 && view.getUint8(i + 5) === 0) {
        return i + 6;
      }
    }
    return -1;
  }

  private async readExportImageSourceProperties(uri: string, values: Record<string, string>): Promise<void> {
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(uri);
      const keys: Array<image.PropertyKey> = [
        image.PropertyKey.MAKE,
        image.PropertyKey.MODEL,
        image.PropertyKey.LENS_MODEL,
        image.PropertyKey.FOCAL_LENGTH,
        image.PropertyKey.F_NUMBER,
        image.PropertyKey.EXPOSURE_TIME,
        image.PropertyKey.ISO_SPEED_RATINGS,
        image.PropertyKey.DATE_TIME_ORIGINAL,
        image.PropertyKey.DATE_TIME,
      ];
      const properties = await source.getImageProperties(keys);
      const copy = (key: image.PropertyKey, name: string): void => {
        const value = properties[key];
        if (typeof value === 'string' && value.trim().length > 0) values[name] = value;

      };
      copy(image.PropertyKey.MAKE, 'make');
      copy(image.PropertyKey.MODEL, 'model');
      copy(image.PropertyKey.LENS_MODEL, 'lens');
      copy(image.PropertyKey.FOCAL_LENGTH, 'focal');
      copy(image.PropertyKey.F_NUMBER, 'aperture');
      copy(image.PropertyKey.EXPOSURE_TIME, 'shutter');
      copy(image.PropertyKey.ISO_SPEED_RATINGS, 'iso');
      copy(image.PropertyKey.DATE_TIME_ORIGINAL, 'date');
      if (!values['date']) copy(image.PropertyKey.DATE_TIME, 'date');
    } catch (_error) {
      // NEF/ARW/CR3 providers commonly reject ImageSource EXIF access; the
      // bounded TIFF parser in updateExportMetadataFromSource handles those.
    } finally {
      if (source) source.release();
    }
  }

  private cleanExportText(value: string): string {
    let result = '';
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index);
      if (code >= 32 && code !== 127) result += String.fromCharCode(code);
    }
    return result.replace(/\s+/g, ' ').trim();
  }

  private parseExportNumber(value: string): number {
    const text = this.cleanExportText(value).replace(/^f\s*\/\s*/i, '');
    const slash = text.indexOf('/');
    if (slash > 0 && slash < text.length - 1) {
      const numerator = Number(text.substring(0, slash));
      const denominator = Number(text.substring(slash + 1));
      if (Number.isFinite(numerator) && Number.isFinite(denominator) && denominator !== 0) {
        return numerator / denominator;
      }
    }
    const match = text.match(/[-+]?(?:\d+\.?\d*|\.\d+)/);
    return match ? Number(match[0]) : Number.NaN;
  }

  private formatExportDecimal(value: number, decimals: number): string {
    let text = value.toFixed(decimals);
    if (text.indexOf('.') >= 0) text = text.replace(/0+$/, '').replace(/\.$/, '');
    return text;
  }

  private formatExportFocal(value: string): string {
    const number = this.parseExportNumber(value);
    if (!Number.isFinite(number) || number <= 0) return this.cleanExportText(value);
    const text = Math.abs(number - Math.round(number)) < 0.05 ? Math.round(number).toString() :
      this.formatExportDecimal(number, 1);
    return text + 'mm';
  }

  private formatExportAperture(value: string): string {
    const number = this.parseExportNumber(value);
    return Number.isFinite(number) && number > 0 ? 'F' + number.toFixed(1) : this.cleanExportText(value);
  }

  private formatExportShutter(value: string): string {
    const clean = this.cleanExportText(value).replace(/s$/i, '').trim();
    const number = this.parseExportNumber(clean);
    if (!Number.isFinite(number) || number <= 0) return clean.length > 0 ? clean + 's' : '';
    if (number < 1) return '1/' + Math.max(1, Math.round(1 / number)).toString() + 's';
    return this.formatExportDecimal(number, 2) + 's';
  }

  private formatExportIso(value: string): string {
    const number = this.parseExportNumber(value);
    return Number.isFinite(number) && number > 0 ? 'ISO ' + Math.round(number).toString() : this.cleanExportText(value);
  }

  private applyExportMetadataValues(values: Record<string, string>): void {
    if (values['model']) this.exportMetadata.camera = this.cleanExportText(values['model']);
    if (values['make']) {
      const make = this.cleanExportText(values['make']);
      this.exportMetadata.brand = make.toLowerCase().indexOf('panasonic') >= 0 ? 'Panasonic' : make;
    }
    if (values['lens']) this.exportMetadata.lens = this.cleanExportText(values['lens']);
    if (values['focal']) this.exportMetadata.focalLength = this.formatExportFocal(values['focal']);
    if (values['aperture']) this.exportMetadata.aperture = this.formatExportAperture(values['aperture']);
    if (values['shutter']) this.exportMetadata.shutter = this.formatExportShutter(values['shutter']);
    if (values['iso']) this.exportMetadata.iso = this.formatExportIso(values['iso']);
    if (values['date']) {
      const date = this.cleanExportText(values['date']);
      this.exportMetadata.capturedAt = date.substring(0, 16).replace(/^(\d{4}):(\d{2}):(\d{2})/, '$1-$2-$3');
    }
  }

  private readExportIfd(view: DataView, base: number, ifd: number, little: boolean,
    values: Record<string, string>, depth: number = 0, visited: Set<number> = new Set<number>()): number {
    if (depth > 8 || ifd < base || ifd + 2 > view.byteLength || visited.has(ifd)) return 0;
    visited.add(ifd);
    const count = Math.min(view.getUint16(ifd, little), 4096);
    let exifIfd = 0;
    const subIfds: number[] = [];
    for (let i = 0; i < count && ifd + 2 + (i + 1) * 12 + 4 <= view.byteLength; i++) {
      try {
        const entry = ifd + 2 + i * 12;
        const tag = view.getUint16(entry, little);
        const type = view.getUint16(entry + 2, little);
        const itemCount = view.getUint32(entry + 4, little);
        const unit = type === 1 || type === 2 || type === 7 ? 1 :
          (type === 3 || type === 8 ? 2 : (type === 4 || type === 9 ? 4 : 8));
        const length = itemCount * unit;
        if (length <= 0 || length > 16 * 1024 * 1024) continue;
        const valueOffset = length <= 4 ? entry + 8 : base + view.getUint32(entry + 8, little);
        if (valueOffset < base || valueOffset + Math.min(length, 512) > view.byteLength) continue;

        if (tag === 0x8769 && length >= 4) {
          exifIfd = base + view.getUint32(valueOffset, little);
          continue;
        }
        if (tag === 0x014A && type === 4) {
          const limit = Math.min(itemCount, 8);
          for (let sub = 0; sub < limit && valueOffset + sub * 4 + 4 <= view.byteLength; sub++) {
            subIfds.push(base + view.getUint32(valueOffset + sub * 4, little));
          }
          continue;
        }

        const text = this.readExportTag(view, valueOffset, type, itemCount, little);
        if (!text) continue;
        if (tag === 0x010F) values['make'] = text;
        else if (tag === 0x0110) values['model'] = text;
        else if (tag === 0xA434) values['lens'] = text;
        // LensModel is optional in Panasonic RW2. LensInfo is the standard
        // four-RATIONAL fallback: min/max focal and aperture at both ends.
        else if (tag === 0xA432 && !values['lens']) {
          const lensInfo = this.readExportLensInfo(view, valueOffset, type, itemCount, little);
          if (lensInfo.length > 0) values['lens'] = lensInfo;
        }
        else if (tag === 0x920A) values['focal'] = text;
        else if (tag === 0x829D) values['aperture'] = text;
        else if (tag === 0x829A) values['shutter'] = text;
        else if (tag === 0x8827) values['iso'] = text;
        else if (tag === 0x9003 || (tag === 0x0132 && !values['date'])) values['date'] = text;
      } catch (_error) {
        // One malformed MakerNote entry must not hide the standard EXIF tags.
      }
    }
    if (exifIfd > 0) this.readExportIfd(view, base, exifIfd, little, values, depth + 1, visited);
    for (const subIfd of subIfds) {
      this.readExportIfd(view, base, subIfd, little, values, depth + 1, visited);
    }
    const tail = ifd + 2 + count * 12;
    if (tail + 4 > view.byteLength) return 0;
    const next = view.getUint32(tail, little);
    return next > 0 ? base + next : 0;
  }

  private readExportTag(view: DataView, offset: number, type: number, count: number, little: boolean): string {
    if (type === 2 || type === 7) {
      let text = '';
      const limit = Math.min(count, 256);
      for (let i = 0; i < limit && offset + i < view.byteLength; i++) {
        const ch = view.getUint8(offset + i);
        if (ch === 0) break;
        text += String.fromCharCode(ch);
      }
      return this.cleanExportText(text);
    }
    if (type === 3) return view.getUint16(offset, little).toString();
    if (type === 4) return view.getUint32(offset, little).toString();
    if (type === 8) return view.getInt16(offset, little).toString();
    if (type === 9) return view.getInt32(offset, little).toString();
    if (type === 5 || type === 10) {
      const numerator = type === 10 ? view.getInt32(offset, little) : view.getUint32(offset, little);
      const denominator = type === 10 ? view.getInt32(offset + 4, little) : view.getUint32(offset + 4, little);
      if (!denominator) return '';
      // Keep the raw fraction: a fast shutter like 1/320s is 0.003 after the
      // division and would round to a useless "0" for every display format.
      // parseExportNumber reduces n/d, so formatters still see plain numbers.
      return `${numerator}/${denominator}`;
    }
    return '';
  }

  /** Formats the standard EXIF LensInfo fallback when LensModel is absent. */
  private readExportLensInfo(view: DataView, offset: number, type: number, count: number, little: boolean): string {
    if (type !== 5 || count < 4 || offset < 0 || offset + 32 > view.byteLength) return '';
    const values: number[] = [];
    for (let index = 0; index < 4; index++) {
      const numerator = view.getUint32(offset + index * 8, little);
      const denominator = view.getUint32(offset + index * 8 + 4, little);
      if (denominator === 0) return '';
      values.push(numerator / denominator);
    }
    const minFocal = values[0];
    const maxFocal = values[1];
    const minAperture = values[2];
    const maxAperture = values[3];
    if (!Number.isFinite(minFocal) || minFocal <= 0) return '';
    const focal = !Number.isFinite(maxFocal) || maxFocal <= 0 || Math.abs(maxFocal - minFocal) < 0.05
      ? this.formatExportDecimal(minFocal, 1) + 'mm'
      : this.formatExportDecimal(minFocal, 1) + '-' + this.formatExportDecimal(maxFocal, 1) + 'mm';
    if (!Number.isFinite(minAperture) || minAperture <= 0) return focal;
    const aperture = !Number.isFinite(maxAperture) || maxAperture <= 0 || Math.abs(maxAperture - minAperture) < 0.05
      ? 'F' + this.formatExportDecimal(minAperture, 1)
      : 'F' + this.formatExportDecimal(minAperture, 1) + '-' + this.formatExportDecimal(maxAperture, 1);
    return focal + ' ' + aperture;
  }
  private async openExportDialog(): Promise<void> {
    if (this.exportInProgress) return;
    // Populate the frame with the source camera metadata before the settings
    // sheet is built.  This is especially important for NEF/RAW assets: the
    // editor intentionally loads only a bounded preview on entry, so the
    // export sheet must perform its own local EXIF/TIFF read.
    await this.updateExportMetadataFromSource();
    // 打开“导出”时只显示设置面板。全分辨率读取、渲染和编码均延迟到
    // 设置面板中的“导出”按钮被点击后，避免进度遮罩抢先盖住设置面板。
    // Derive the default export size from the UNCROPPED original, using the
    // exact same integer crop boundaries and rotation as the renderer. Using
    // previewWidth here can crop twice; ignoring crop would scale a cropped
    // result back to the original aspect ratio when the user confirms 100%.
    let width = this.fullResWidth > 0 ? this.fullResWidth : this.editSession.imageWidth;
    let height = this.fullResHeight > 0 ? this.fullResHeight : this.editSession.imageHeight;
    // RAW source metadata precedes EXIF orientation, while sourcePixelMap is
    // already oriented. Crop coordinates belong to that decoded source frame.
    // Match its orientation without loading a full-resolution image here.
    const sourceWidth = this.editSession.imageWidth;
    const sourceHeight = this.editSession.imageHeight;
    if (sourceWidth > 0 && sourceHeight > 0 &&
      (width - height) * (sourceWidth - sourceHeight) < 0) {
      const unrotatedWidth = width;
      width = height;
      height = unrotatedWidth;
    }
    const baseWidth = width > 0 ? Math.round(width) : 1920;
    const baseHeight = height > 0 ? Math.round(height) : 1280;
    const output = buildGeometryMap(this.editSession.geometry, baseWidth, baseHeight, {
      width: baseWidth, height: baseHeight,
      cropLeft: this.editSession.cropLeft, cropTop: this.editSession.cropTop,
      cropRight: this.editSession.cropRight, cropBottom: this.editSession.cropBottom,
      rotation: this.editSession.rotation, flipH: this.editSession.flipH, flipV: this.editSession.flipV,
    });
    const dialogWidth = output.outputWidth;
    const dialogHeight = output.outputHeight;
    this.exportDialogController = new CustomDialogController({
      builder: ExportQualityDialog({
        originalWidth: dialogWidth,
        originalHeight: dialogHeight,
        previewPixelMap: this.editSession.previewPixelMap,
        metadata: this.exportMetadata,
        onClosed: () => { this.endModal(); },
        onConfirm: (quality: number, targetWidth: number, targetHeight: number, frame: ExportFrameOptions, format: string) => {
          this.exportMetadata = frame;
          // The dialog's confirm handler closes the custom dialog immediately
          // after invoking this callback. Start on the next UI turn so the
          // settings sheet can finish closing and the progress overlay gets a
          // real interactive frame before any heavy export stage begins.
          setTimeout(() => {
            this.exportImage(quality, targetWidth, targetHeight, frame, format);
          }, 0);
        },
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true,
    });
    this.beginModal();
    try {
      this.exportDialogController.open();
    } catch (error) {
      this.endModal();
      throw new Error('Unable to open export settings: ' + (error as Error).message);
    }
  }

  async exportImage(quality: number = 95, targetWidth: number = 0, targetHeight: number = 0,
    frame: ExportFrameOptions = this.exportMetadata, format: string = 'JPG'): Promise<void> {
    if (!this.editSession.previewPixelMap || this.exportInProgress) return;
    this.exportInProgress = true;
    this.exportBackgrounded = false;
    this.exportCancelRequested = false;
    this.exportProgress = 4;
    this.exportStatus = '准备导出…';
    const exportSession = ImageProcessor.snapshot(this.editSession);
    this.exportTrace(`start quality=${Math.round(quality)} format=${format} target=${targetWidth}x${targetHeight} frame=${frame && frame.enabled ? 'on' : 'off'}`);
    let exportPm: image.PixelMap | null = null;
    // 导出耗时分解：用户反馈"非常慢"时看不出卡在哪一步。把每个阶段的耗时、
    // 实际渲染尺寸与后端（原生 GPU 读回 / TaskPool CPU 管线）写进问题反馈
    // 日志，一次导出只加一行。backend 为空即 GPU 导出条件不成立（见
    // GpuShaderBridge.renderExport 的显存上限）。
    const exportStarted = Date.now();
    let stageMark = exportStarted;
    const stages: string[] = [];
    const markStage = (name: string, extra: string = ''): void => {
      const now = Date.now();
      stages.push(`${name}:${now - stageMark}ms${extra}`);
      stageMark = now;
    };
    // 清空上一次的后端标记：只有本次真的走了原生读回才会被重新写入。
    AppStorage.setOrCreate('vividGpuExportBackend', '');
    try {
      // Let the state update above commit before opening the large source or
      // allocating export buffers. This is what makes 取消导出 clickable at
      // the beginning of a long export instead of waiting for the first stage.
      await new Promise<void>((resolve) => setTimeout(resolve, 16));
      if (this.exportCancelled()) return;
      this.exportTrace('stage=source_prepare');
      const fullSourceReady = await this.ensureFullResSource();
      if (this.exportCancelled()) return;
      if (!fullSourceReady || !this.fullResSource) {
        this.showExportError('无法读取原始图片，已取消导出');
        return;
      }
      this.exportTrace(`stage=source_ready full=${this.fullResWidth}x${this.fullResHeight}`);
      markStage('source', ` ${this.fullResWidth}x${this.fullResHeight}`);
      this.exportProgress = 18;
      this.exportStatus = '正在按原始像素渲染…';
      // 全分辨率源已在上方确认可用；在原始尺寸上重跑管线。
      {
        this.exportProgress = 20;
        this.exportTrace('stage=render_start');
        this.getUIContext().getPromptAction().showToast({ message: '正在以原始分辨率渲染…' });
        const result = await ImageProcessor.renderToBuffer(
          this.fullResSource, this.fullResWidth, this.fullResHeight,
          exportSession, false, (): boolean => this.exportCancelled());
        this.exportTrace(result ? `stage=render_done size=${result.width}x${result.height}` : 'stage=render_failed');
        const renderBackend = AppStorage.get<string>('vividGpuExportBackend') ?? '';
        markStage('render', ` ${result ? `${result.width}x${result.height}` : 'failed'}` +
          ` backend=${renderBackend.length > 0 ? renderBackend : 'taskpool-cpu'}`);
        if (this.exportCancelled()) return;
        if (!result) {
          this.showExportError('原始尺寸渲染失败');
          return;
        }
        this.exportProgress = 72;
        const fullPm = await ImageProcessor.createPixelMapFromBuffer(result.pixels, result.width, result.height);
        this.exportTrace(fullPm ? 'stage=pixelmap_done' : 'stage=pixelmap_failed');
        markStage('pixelmap');
        if (!fullPm) {
          this.showExportError('无法创建原始尺寸画面');
          return;
        }
        const safeWidth = targetWidth > 0 ? targetWidth : result.width;
        const safeHeight = targetHeight > 0 ? targetHeight : result.height;
        const scaleX = safeWidth / result.width;
        const scaleY = safeHeight / result.height;
        if (scaleX !== 1 || scaleY !== 1) {
          await fullPm.scale(scaleX, scaleY);
        }
        markStage('scale', ` ${Math.round(safeWidth)}x${Math.round(safeHeight)}`);
        if (this.exportCancelled()) {
          fullPm.release();
          return;
        }
        exportPm = fullPm;
      }

      // The frame is an export-only composition. Keep the interactive image
      // untouched and add the selected metadata layout after resizing.
      if (frame && frame.enabled && exportPm) {
        this.exportStatus = '正在合成边框…';
        this.exportProgress = 80;
        this.exportTrace('stage=frame_start');
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
        if (this.exportCancelled()) return;
        const framed = await ExportFrameRenderer.render(exportPm, frame,
          this.getUIContext().getHostContext() as common.UIAbilityContext,
          (): boolean => this.exportCancelled());
        if (this.exportCancelled()) {
          if (framed) framed.release();
          return;
        }
        this.exportTrace(framed ? 'stage=frame_done' : 'stage=frame_failed');
        markStage('frame');
        if (framed) {
          exportPm.release();
          exportPm = framed;
        } else {
          this.showExportError('边框合成失败，请重试');
          return;
        }
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const baseName = `VIVID_${Date.now()}`;
      const ext = format === 'PNG' ? 'png' : (format === 'TIFF' ? 'tiff' : 'jpg');
      const filePath = context.cacheDir + '/' + baseName + '.' + ext;
      this.exportStatus = `正在编码 ${format}…`;
      this.exportTrace('stage=encode_start');
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
      if (this.exportCancelled()) return;
      const exportInfo = await exportPm.getImageInfo();
      const exportedWidth = exportInfo.size.width;
      const exportedHeight = exportInfo.size.height;
      await PixelMapUtils.encodeImageToFile(exportPm, filePath, format, Math.round(quality));
      if (this.exportCancelled()) return;
      this.exportTrace('stage=encode_done');
      markStage('encode');
      exportPm.release();
      exportPm = null;
      this.exportProgress = 90;
      this.exportStatus = '正在保存到相册…';
      this.exportTrace('stage=gallery_start');

      const manager = abilityAccessCtrl.createAtManager();
      const permissionResult = await manager.requestPermissionsFromUser(context, ['ohos.permission.WRITE_IMAGEVIDEO']);
      const granted = permissionResult.authResults.length > 0 && permissionResult.authResults[0] === 0;
      if (!granted) {
        this.showExportError('需要「保存到相册」权限才能导出照片，请在系统设置中允许后重试');
        return;
      }

      // Create media asset in gallery. Note: the title must NOT contain the
      // extension (error 14000001 invalid display name); it is passed
      // separately as the second argument.
      const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      const createOption: photoAccessHelper.CreateOptions = {
        title: baseName,
      };
      const uri = await phAccessHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, ext, createOption);
      if (this.exportCancelled()) return;
      if (uri) {
        const writeFd = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
        try {
          await fileIo.copyFile(filePath, writeFd.fd);
          if (fileIo.statSync(writeFd.fd).size !== fileIo.statSync(filePath).size) {
            throw new Error('Gallery file length does not match the encoded file');
          }
        } finally {
          fileIo.closeSync(writeFd);
        }

        this.getUIContext().getPromptAction().showDialog({
          title: '导出成功',
          message: `已以 ${format} 格式 · ${Math.round(quality)}% 品质 · ${exportedWidth}×${exportedHeight} 像素保存到相册`,
          buttons: [{ text: '确定', color: '#2196F3' }],
        });
        this.exportProgress = 100;
        this.exportTrace('stage=gallery_done');
        markStage('gallery');
      }
    } catch (e) {
      this.exportTrace('stage=failed');
      console.error('Export failed:', JSON.stringify(e));
      this.showExportError('保存照片时出错');
    } finally {
      AppLogStore.add(`export format=${format} quality=${Math.round(quality)}` +
        ` target=${Math.round(targetWidth)}x${Math.round(targetHeight)}` +
        ` total=${Date.now() - exportStarted}ms stages=${stages.join(' ')}`);
      if (exportPm) exportPm.release();
      this.exportInProgress = false;
      this.exportBackgrounded = false;
      this.exportCancelRequested = false;
      this.exportStatus = '';
    }
  }

  private backgroundExport(): void {
    if (!this.exportInProgress) return;
    this.exportBackgrounded = true;
    this.exportStatus = '后台导出中…';
  }

  private cancelExport(): void {
    if (!this.exportInProgress) return;
    this.exportCancelRequested = true;
    this.exportBackgrounded = true;
    this.exportStatus = '正在取消导出…';
    this.exportTrace('cancel_requested');
  }

  private exportCancelled(): boolean {
    return this.exportCancelRequested;
  }

  private showExportError(message: string): void {
    if (this.exportCancelRequested) return;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '导出失败',
        message: message,
        buttons: [{ text: '确定', color: '#5262EC' }],
      });
    } catch (_promptError) {
      console.error('Unable to show export error dialog');
    }
  }

  private exportTrace(message: string): void {
    hilog.info(0x0001, 'VIVID_EXPORT', '%{public}s', message);
  }
}

interface VividExportMetadataField {
  key: string;
  label: string;
  text: string;
  selected: boolean;
  placeholder: string;
}

@CustomDialog
struct ExportQualityDialog {
  controller?: CustomDialogController;
  originalWidth: number = 1920;
  originalHeight: number = 1280;
  previewPixelMap: image.PixelMap | null = null;
  metadata: ExportFrameOptions = {
    enabled: false,
    style: '经典相框',
    brand: 'Panasonic',
    camera: 'S1RII',
    fontSize: 16,
    fontColor: '#111111',
    lens: '28-105mm F2.8 DG DN | Art',
    focalLength: '49mm',
    aperture: 'F4.0',
    shutter: '1/500s',
    iso: 'ISO100',
  };
  onConfirm: (quality: number, width: number, height: number, frame: ExportFrameOptions, format: string) => void = () => {};
  onClosed: () => void = () => {};
  @State private quality: number = 95;
  @State private format: string = 'JPG';
  @State private scalePercent: string = '100%';
  @State private resample: string = '两次立方（自动）';
  @State private exportWidth: string = '';
  @State private exportHeight: string = '';
  @State @Watch('scheduleFramePreview') private frameEnabled: boolean = false;
  @State @Watch('scheduleFramePreview') private frameStyle: string = '经典相框';
  @State @Watch('scheduleFramePreview') private brand: string = 'Panasonic';
  @State @Watch('scheduleFramePreview') private brandManual: string = '';
  @State @Watch('scheduleFramePreview') private camera: string = 'S1RII';
  @State @Watch('scheduleFramePreview') private cameraManual: string = '';
  @State @Watch('scheduleFramePreview') private fontSize: number = 16;
  @State @Watch('scheduleFramePreview') private fontColor: string = '#111111';
  @State @Watch('scheduleFramePreview') private lens: string = '28-105mm F2.8 DG DN | Art';
  @State @Watch('scheduleFramePreview') private focalLength: string = '49mm';
  @State @Watch('scheduleFramePreview') private aperture: string = 'F4.0';
  @State @Watch('scheduleFramePreview') private shutter: string = '1/500s';
  @State @Watch('scheduleFramePreview') private iso: string = 'ISO100';
  @State @Watch('scheduleFramePreview') private capturedAt: string = '';
  @State @Watch('scheduleFramePreview') private showCamera: boolean = false;
  @State @Watch('scheduleFramePreview') private showLens: boolean = false;
  @State @Watch('scheduleFramePreview') private showFocalLength: boolean = false;
  @State @Watch('scheduleFramePreview') private showAperture: boolean = false;
  @State @Watch('scheduleFramePreview') private showShutter: boolean = false;
  @State @Watch('scheduleFramePreview') private showIso: boolean = false;
  @State @Watch('scheduleFramePreview') private showCapturedAt: boolean = false;
  // Keep the export sheet compact on desktop while preserving the phone layout.
  @StorageProp('windowWidth') private windowWidth: number = 360;

  private detectBrand(value: string): string {
    const text = value.toLowerCase();
    if (text.indexOf('nikon') >= 0) return 'Nikon';
    if (text.indexOf('z9') >= 0 || text.indexOf('z8') >= 0 || text.indexOf('zf') >= 0 ||
      text.indexOf('z6') >= 0 || text.indexOf('z7') >= 0 || text.indexOf('d850') >= 0) return 'Nikon';
    if (text.indexOf('sony') >= 0 || text.indexOf('alpha') >= 0 || text.indexOf('α') >= 0) return 'Sony';
    if (text.indexOf('ilce-') >= 0 || text.indexOf('a7') >= 0 || text.indexOf('a6700') >= 0) return 'Sony';
    if (text.indexOf('canon') >= 0 || text.indexOf('eos') >= 0) return 'Canon';
    if (text.indexOf('r5') >= 0 || text.indexOf('r6') >= 0 || text.indexOf('r7') >= 0 || text.indexOf('r50') >= 0) return 'Canon';
    if (text.indexOf('ricoh') >= 0 || text.indexOf('gr ') >= 0) return 'Ricoh';
    if (text.indexOf('pentax') >= 0 || text.indexOf('k-3') >= 0 || text.indexOf('k-1') >= 0) return 'Pentax';
    if (text.indexOf('fujifilm') >= 0 || text.indexOf('fuji') >= 0 || text.indexOf('gfx') >= 0) return 'Fujifilm';
    if (text.indexOf('olympus') >= 0 || text.indexOf('om-') >= 0) return 'Olympus';
    if (text.indexOf('leica') >= 0) return 'Leica';
    if (text.indexOf('hasselblad') >= 0 || text.indexOf('x2d') >= 0 || text.indexOf('x1d') >= 0) return 'Hasselblad';
    if (text.indexOf('dji') >= 0 || text.indexOf('zenmuse') >= 0) return 'DJI';
    return 'Panasonic';
  }

  private stripCameraBrand(value: string): string {
    let result = value.trim();
    const prefixes: string[] = [
      'Panasonic ', 'PANASONIC ', 'Lumix ', 'LUMIX ', 'Nikon ', 'NIKON ',
      'Sony ', 'SONY ', 'Canon ', 'CANON ', 'EOS ', 'Ricoh ', 'RICOH ',
      'Pentax ', 'PENTAX ', 'Fujifilm ', 'FUJIFILM ', 'Olympus ', 'OLYMPUS ',
      'Leica ', 'LEICA ', 'Hasselblad ', 'HASSELBLAD ', 'DJI '
    ];
    for (const prefix of prefixes) {
      if (result.indexOf(prefix) === 0) {
        result = result.substring(prefix.length).trim();
        break;
      }
    }
    return result.length > 0 ? result : 'S1RII';
  }

  private cameraModelOptions(brand: string): string[] {
    switch (brand) {
      case 'Nikon': return ['Z9', 'Z8', 'Zf', 'Z6III', 'Z6II', 'Z7II', 'Z5', 'Z50II', 'Z50', 'D850', 'D780', 'D500'];
      case 'Sony': return ['α1 II', 'α1', 'α9 III', 'α7 V', 'α7R VI', 'α7R V', 'α7 IV', 'α7 III', 'α7S III', 'α7CR', 'α7C II', 'α7C', 'α6700', 'α6600', 'α6400', 'ZV-E10 II', 'ZV-E10', 'ZV-E1'];
      case 'Canon': return ['R1', 'R5 Mark II', 'R5', 'R6 Mark II', 'R8', 'R7', 'R10', 'R50', '5D Mark IV', '90D'];
      case 'Ricoh': return ['GR III', 'GR IIIx', 'K-3 Mark III', 'K-1 Mark II', 'KF'];
      case 'Fujifilm': return ['GFX100 II', 'GFX50S II', 'X-T5', 'X-H2', 'X-S20', 'X-T50', 'X100VI'];
      case 'Olympus': return ['OM-1 Mark II', 'OM-5', 'E-M1 Mark III', 'E-M5 Mark III'];
      case 'Leica': return ['SL3', 'Q3', 'M11', 'Q2'];
      case 'Hasselblad': return ['X2D 100C', 'X1D II 50C', '907X 100C'];
      case 'DJI': return ['Zenmuse X5', 'Zenmuse X5S'];
      case 'Pentax': return ['K-3 Mark III', 'K-1 Mark II', 'KF', 'K-70'];
      default: return ['S1', 'S1R', 'S1RII', 'S1H', 'S1M', 'S5', 'S5M2', 'S5M2X', 'S5D', 'S9', 'G9II', 'GH7', 'G9'];
    }
  }

  private cameraSelectOptions(): CameraSelectOption[] {
    const values: string[] = this.cameraModelOptions(this.brand);
    values.push('手动输入');
    const options: CameraSelectOption[] = [];
    for (const value of values) {
      const option: CameraSelectOption = { value: value };
      options.push(option);
    }
    return options;
  }

  private brandSelectOptions(): CameraSelectOption[] {
    const values: string[] = ['Panasonic', 'Nikon', 'Sony', 'Canon', 'Ricoh', 'Pentax', 'Fujifilm', 'Olympus', 'Leica', 'Hasselblad', 'DJI', '手动输入'];
    const options: CameraSelectOption[] = [];
    for (const value of values) options.push({ value: value });
    return options;
  }

  aboutToAppear(): void {
    this.exportWidth = this.originalWidth.toString();
    this.exportHeight = this.originalHeight.toString();
    this.frameEnabled = this.metadata.enabled;
    this.frameStyle = this.metadata.style === '白底信息框' ? '经典相框' :
      (this.metadata.style === '沉浸圆角' || this.metadata.style === '阴影边框' || this.metadata.style === '沉浸体感' ? '沉浸光感' : this.metadata.style);
    this.brand = this.detectBrand(`${this.metadata.brand} ${this.metadata.camera}`);
    this.brandManual = this.metadata.brand;
    this.camera = this.stripCameraBrand(this.metadata.camera);
    this.fontSize = this.metadata.fontSize > 0 ? this.metadata.fontSize : 16;
    this.fontColor = this.metadata.fontColor === '#FFFFFF' ? '#FFFFFF' : '#111111';
    const knownCamera = this.cameraModelOptions(this.brand).indexOf(this.camera) >= 0;
    if (!knownCamera) {
      this.cameraManual = this.camera;
      this.camera = '手动输入';
    }
    this.lens = this.metadata.lens;
    this.focalLength = ExportFrameRenderer.formatParameter('focalLength', this.metadata.focalLength);
    this.aperture = ExportFrameRenderer.formatParameter('aperture', this.metadata.aperture);
    this.shutter = ExportFrameRenderer.formatParameter('shutter', this.metadata.shutter);
    this.iso = ExportFrameRenderer.formatParameter('iso', this.metadata.iso);
    this.capturedAt = this.metadata.capturedAt || '';
    this.showCamera = this.metadata.showCamera === true;
    this.showLens = this.metadata.showLens === true;
    this.showFocalLength = this.metadata.showFocalLength === true;
    this.showAperture = this.metadata.showAperture === true;
    this.showShutter = this.metadata.showShutter === true;
    this.showIso = this.metadata.showIso === true;
    this.showCapturedAt = this.metadata.showCapturedAt === true;
    this.previewAlive = true;
    this.scheduleFramePreview();
  }

  build() {
    Column() {
      Scroll() {
        Column() {
      Text('导出设置')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.vivid_text_1b2536'))
        .fontFamily('HarmonyOS Sans')
        .width('100%')
        .textAlign(TextAlign.Center);

      // ── 第一组：文件设置 ────────────────────────────────
      Text('文件设置')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.vivid_text_334158'))
        .width('100%')
        .margin({ top: 20 });
      Row() {
        Text('格式')
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .fontFamily('HarmonyOS Sans')
          .width(72);
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
      .margin({ top: 10 });

      Row() {
        Text('品质')
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .fontFamily('HarmonyOS Sans')
          .width(72);
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

      Divider().color('rgba(93,106,126,0.14)').width('100%').margin({ top: 18, bottom: 16 });

      // ── 第二组：图像大小 ────────────────────────────────
      Text('图像大小')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.vivid_text_334158'))
        .width('100%');
      Row() {
        Text('宽度')
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .fontFamily('HarmonyOS Sans')
          .width(72);
        Blank();
        TextInput({ text: this.exportWidth })
          .width(110)
          .height(38)
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .backgroundColor($r('app.color.vivid_surface_f2f5f9'))
          .type(InputType.Number)
          .borderRadius(10)
          .border({ width: 1, color: '#D3DAE5' })
          .textAlign(TextAlign.Center)
          .onChange((value: string) => {
            this.onWidthInput(value);
          });
        Text('像素')
          .fontSize(12)
          .fontColor($r('app.color.vivid_text_536176'))
          .margin({ left: 8 });
      }
      .width('100%')
      .margin({ top: 10 });

      Row() {
        Text('高度')
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .fontFamily('HarmonyOS Sans')
          .width(72);
        Blank();
        TextInput({ text: this.exportHeight })
          .width(110)
          .height(38)
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .backgroundColor($r('app.color.vivid_surface_f2f5f9'))
          .type(InputType.Number)
          .borderRadius(10)
          .border({ width: 1, color: '#D3DAE5' })
          .textAlign(TextAlign.Center)
          .onChange((value: string) => {
            this.onHeightInput(value);
          });
        Text('像素')
          .fontSize(12)
          .fontColor($r('app.color.vivid_text_536176'))
          .margin({ left: 8 });
      }
      .width('100%')
      .margin({ top: 10 });

      Row() {
        Text('缩放')
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .fontFamily('HarmonyOS Sans')
          .width(72);
        Blank();
        Select([
          { value: '100%' },
          { value: '75%' },
          { value: '50%' },
          { value: '25%' },
        ])
          .value(this.scalePercent)
          .width(150)
          .height(38)
          .font({ size: 13 })
          .fontColor($r('app.color.vivid_text_334158'))
          .backgroundColor($r('app.color.vivid_surface_f2f5f9'))
          .borderRadius(10)
          .optionBgColor('#FFFFFF')
          .optionFontColor('#334158')
          .onSelect((index: number, value: string) => {
            const pct = parseInt(value);
            if (!isNaN(pct)) this.applyScalePercent(pct);
          });
      }
      .width('100%')
      .margin({ top: 10 });

      Row() {
        Text('重新取样')
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .fontFamily('HarmonyOS Sans')
          .width(72);
        Blank();
        Select([{ value: '两次立方（自动）' }])
          .value(this.resample)
          .selected(0)
          .width(150)
          .height(38)
          .font({ size: 13 })
          .fontColor($r('app.color.vivid_text_334158'))
          .backgroundColor($r('app.color.vivid_surface_f2f5f9'))
          .borderRadius(10)
          .optionBgColor('#FFFFFF')
          .optionFontColor('#334158')
          .onSelect((index: number, value: string) => {
            this.resample = value;
          });
      }
      .width('100%')
      .margin({ top: 10 });

      Divider().color('rgba(93,106,126,0.14)').width('100%').margin({ top: 18, bottom: 14 });
      Text('边框与拍摄信息')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.vivid_text_334158'))
        .width('100%');
      Row() {
        Toggle({ type: ToggleType.Checkbox, isOn: this.frameEnabled })
          .width(24)
          .height(24)
          .onChange((value: boolean) => {
            this.frameEnabled = value;
          });
        Text('导出边框')
          .fontSize(13)
          .fontColor($r('app.color.vivid_text_334158'))
          .margin({ left: 8 });
        Blank();
        Text(this.frameEnabled ? '已启用' : '仅导出原图')
          .fontSize(11)
          .fontColor($r('app.color.vivid_text_7b8798'));
      }
      .width('100%')
      .margin({ top: 10 });

      if (this.frameEnabled) {
        this.FramePreview();
        Row() {
          Text('样式').fontSize(13).fontColor($r('app.color.vivid_text_334158')).width(72);
          Blank();
          Select([{ value: '经典相框' }, { value: '沉浸光感' }])
            .value(this.frameStyle)
            .width(170)
            .height(36)
            .font({ size: 13 })
            .fontColor($r('app.color.vivid_text_334158'))
            .backgroundColor($r('app.color.vivid_surface_f2f5f9'))
            .borderRadius(10)
            .optionBgColor('#FFFFFF')
            .optionFontColor('#334158')
            .onSelect((index: number, value: string) => {
              this.frameStyle = value;
            });
        }.width('100%').margin({ top: 10 });
        Row() {
          Text('品牌').fontSize(13).fontColor($r('app.color.vivid_text_334158')).width(72);
          Select(this.brandSelectOptions())
            .value(this.brand)
            .width(170).height(36).font({ size: 13 }).fontColor($r('app.color.vivid_text_334158'))
            .backgroundColor($r('app.color.vivid_surface_f2f5f9')).borderRadius(10)
            .optionBgColor('#FFFFFF').optionFontColor('#334158')
            .onSelect((index: number, value: string) => {
              this.brand = value;
              if (value !== '手动输入') {
                const models = this.cameraModelOptions(value);
                this.camera = models.length > 0 ? models[0] : '手动输入';
                this.cameraManual = '';
              }
            });
        }.width('100%').margin({ top: 8 });
        if (this.brand === '手动输入') {
          Row() {
            Text('自定义').fontSize(12).fontColor($r('app.color.vivid_text_7b8798')).width(72);
            TextInput({ text: this.brandManual })
              .layoutWeight(1).height(36).fontSize(13).fontColor($r('app.color.vivid_text_334158'))
              .backgroundColor($r('app.color.vivid_surface_f2f5f9')).borderRadius(10)
              .onChange((value: string) => { this.brandManual = value; });
          }.width('100%').margin({ top: 6 });
        }
        Row() {
          Text('字体大小').fontSize(13).fontColor($r('app.color.vivid_text_334158')).width(72);
          Slider({ value: this.fontSize, min: 12, max: 28, step: 1, style: SliderStyle.OutSet })
            .layoutWeight(1)
            .trackColor('#D3DAE5')
            .selectedColor('#5262EC')
            .blockColor('#FFFFFF')
            .onChange((value: number) => { this.fontSize = value; });
          Text(`${Math.round(this.fontSize)}px`).fontSize(11).fontColor($r('app.color.vivid_text_536176')).width(38).textAlign(TextAlign.End);
        }.width('100%').margin({ top: 8 });
        Row() {
          Text('字体颜色').fontSize(13).fontColor($r('app.color.vivid_text_334158')).width(72);
          Select([{ value: '黑色' }, { value: '白色' }])
            .value(this.frameStyle === '沉浸光感' || this.fontColor === '#FFFFFF' ? '白色' : '黑色')
            .enabled(this.frameStyle !== '沉浸光感')
            .width(170).height(36).font({ size: 13 }).fontColor($r('app.color.vivid_text_334158'))
            .backgroundColor($r('app.color.vivid_surface_f2f5f9')).borderRadius(10)
            .optionBgColor('#FFFFFF').optionFontColor('#334158')
            .onSelect((index: number, value: string) => { this.fontColor = value === '白色' ? '#FFFFFF' : '#111111'; });
        }.width('100%').margin({ top: 8 });
        Row() {
          Checkbox({ name: 'export-camera' })
            .id('export-show-camera').select(this.showCamera).width(22).height(22)
            .margin({ right: 8 }).onChange((checked: boolean) => { this.showCamera = checked; });
          Text('相机').fontSize(13).fontColor($r('app.color.vivid_text_334158')).width(42);
          Select(this.cameraSelectOptions())
            .value(this.camera === '手动输入' ? '手动输入' : this.camera)
            .width(170).height(36).font({ size: 13 }).fontColor($r('app.color.vivid_text_334158'))
            .backgroundColor($r('app.color.vivid_surface_f2f5f9')).borderRadius(10)
            .optionBgColor('#FFFFFF').optionFontColor('#334158')
            .onSelect((index: number, value: string) => { this.camera = value; });
        }.width('100%').margin({ top: 8 });
        if (this.camera === '手动输入') {
          Row() {
            Text('自定义').fontSize(12).fontColor($r('app.color.vivid_text_7b8798')).width(72);
            TextInput({ text: this.cameraManual })
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .fontColor($r('app.color.vivid_text_334158'))
              .backgroundColor($r('app.color.vivid_surface_f2f5f9'))
              .borderRadius(10)
              .onChange((value: string) => { this.cameraManual = value; });
          }
          .width('100%')
          .margin({ top: 6 });
        }
        this.MetadataFieldRow({ key: 'lens', label: '镜头', text: this.lens,
          selected: this.showLens, placeholder: '镜头名称' });
        Text('拍摄参数 · 勾选后显示在相框中').fontSize(11)
          .fontColor($r('app.color.vivid_text_7b8798')).width('100%').margin({ top: 12 });
        this.MetadataFieldRow({ key: 'focalLength', label: '焦距', text: this.focalLength,
          selected: this.showFocalLength, placeholder: 'xxmm' });
        this.MetadataFieldRow({ key: 'aperture', label: '光圈', text: this.aperture,
          selected: this.showAperture, placeholder: 'Fxx' });
        this.MetadataFieldRow({ key: 'shutter', label: '快门', text: this.shutter,
          selected: this.showShutter, placeholder: 'xx s' });
        this.MetadataFieldRow({ key: 'iso', label: 'ISO', text: this.iso,
          selected: this.showIso, placeholder: 'ISO xxx' });
        if (this.capturedAt.length > 0) {
          this.MetadataFieldRow({ key: 'capturedAt', label: '日期', text: this.capturedAt,
            selected: this.showCapturedAt, placeholder: '拍摄日期' });
        }
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
            const w = parseInt(this.exportWidth);
            const h = parseInt(this.exportHeight);
            this.onConfirm(
              Math.round(this.quality),
              isNaN(w) || w <= 0 ? this.originalWidth : w,
              isNaN(h) || h <= 0 ? this.originalHeight : h,
              this.frameOptions(),
              this.format);
            if (this.controller) this.controller.close();
          });
      }
      .width('100%')
      .margin({ top: 20 });
        }
      }
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
    }
    // 浅色卡片容器，与应用整体设计语言一致。
    .width(this.windowWidth >= 840 ? 620 : '100%')
    .height('82%')
    .padding(24)
    .borderRadius(24)
    .backgroundColor($r('app.color.vivid_surface_ffffff'))
    .shadow({ radius: 32, color: 'rgba(20,30,50,0.18)', offsetY: 12 });
  }

  @Builder
  MetadataFieldRow($$: VividExportMetadataField) {
    Row() {
      Checkbox({ name: 'export-' + $$.key })
        .id('export-show-' + $$.key).select($$.selected).width(22).height(22)
        .margin({ right: 8 })
        .onChange((checked: boolean) => { this.setMetadataVisibility($$.key, checked); });
      Text($$.label).fontSize(13).fontColor($r('app.color.vivid_text_334158')).width(42);
      TextInput({ text: $$.text, placeholder: $$.placeholder })
        .id('export-value-' + $$.key).layoutWeight(1).height(36).fontSize(13)
        .fontColor($r('app.color.vivid_text_334158'))
        .backgroundColor($r('app.color.vivid_surface_f2f5f9')).borderRadius(10)
        .onChange((text: string) => { this.setMetadataText($$.key, text); });
    }.width('100%').alignItems(VerticalAlign.Center).margin({ top: 8 });
  }

  private setMetadataVisibility(key: string, checked: boolean): void {
    switch (key) {
      case 'lens': this.showLens = checked; break;
      case 'focalLength': this.showFocalLength = checked; break;
      case 'aperture': this.showAperture = checked; break;
      case 'shutter': this.showShutter = checked; break;
      case 'iso': this.showIso = checked; break;
      case 'capturedAt': this.showCapturedAt = checked; break;
    }
  }

  private setMetadataText(key: string, text: string): void {
    switch (key) {
      case 'lens': this.lens = text; break;
      case 'focalLength': this.focalLength = text; break;
      case 'aperture': this.aperture = text; break;
      case 'shutter': this.shutter = text; break;
      case 'iso': this.iso = text; break;
      case 'capturedAt': this.capturedAt = text; break;
    }
  }

  @Builder
  FramePreview() {
    Column() {
      Row() {
        Text('导出效果预览').fontSize(11).fontColor($r('app.color.vivid_text_7b8798'));
        Blank();
        Text('点击放大').fontSize(10).fontColor($r('app.color.vivid_text_7b8798'));
        Text(this.frameStyle).fontSize(11).fontColor($r('app.color.vivid_text_5262ec')).margin({ left: 8 });
      }.width('100%');
      if (this.composedPreview) {
        Image(this.composedPreview)
          .width('100%')
          .height(this.previewIsPortrait() ? 320 : 220)
          .objectFit(ImageFit.Contain)
          .interpolation(ImageInterpolation.High)
          .margin({ top: 8 })
          .onClick(() => { this.framePreviewExpanded = true; })
          .bindContentCover(this.framePreviewExpanded, this.FramePreviewExpandedCover(), {
            modalTransition: ModalTransition.DEFAULT,
            onDisappear: () => { this.framePreviewExpanded = false; },
          })
      } else {
        LoadingProgress().width(28).height(28).margin(16);
      }
    }.width('100%').margin({ top: 10 });
  }

  @Builder
  FramePreviewExpandedCover() {
    Column() {
      Image(this.composedPreview)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .interpolation(ImageInterpolation.High)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(12,14,20,0.96)')
    .onClick(() => { this.framePreviewExpanded = false; })
  }

  private previewTimer: number = -1;
  private previewRevision: number = 0;
  private previewAlive: boolean = false;
  private previewRendering: boolean = false;
  @State private composedPreview: image.PixelMap | null = null;
  @State private framePreviewExpanded: boolean = false;

  private frameOptions(): ExportFrameOptions {
    return {
      enabled: this.frameEnabled,
      style: this.frameStyle,
      brand: this.brand === '手动输入' ? this.brandManual.trim() : this.brand,
      camera: this.camera === '手动输入' ? this.cameraManual.trim() : this.camera,
      fontSize: this.fontSize,
      fontColor: this.frameStyle === '沉浸光感' ? '#FFFFFF' : this.fontColor,
      lens: this.lens, focalLength: this.focalLength, aperture: this.aperture,
      shutter: this.shutter, iso: this.iso, capturedAt: this.capturedAt,
      showCamera: this.showCamera, showLens: this.showLens,
      showFocalLength: this.showFocalLength, showAperture: this.showAperture,
      showShutter: this.showShutter, showIso: this.showIso, showCapturedAt: this.showCapturedAt,
    };
  }

  private scheduleFramePreview(): void {
    this.previewRevision++;
    if (!this.previewAlive || !this.frameEnabled) return;
    if (this.previewTimer >= 0) clearTimeout(this.previewTimer);
    this.previewTimer = setTimeout(() => {
      this.previewTimer = -1;
      this.renderFramePreview();
    }, 70);
  }

  private async renderFramePreview(): Promise<void> {
    if (!this.previewAlive || !this.previewPixelMap || this.previewRendering) return;
    const revision = this.previewRevision;
    this.previewRendering = true;
    try {
      const next = await ExportFrameRenderer.render(this.previewPixelMap, this.frameOptions(),
        this.getUIContext().getHostContext() as common.UIAbilityContext);
      if (!next) {
        return;
      }
      if (!this.previewAlive || revision !== this.previewRevision) {
        next.release();
      } else {
        const old = this.composedPreview;
        this.composedPreview = next;
        if (old) old.release();
      }
    } catch (_error) {
      // Keep the last good preview until the next valid metadata update.
    } finally {
      this.previewRendering = false;
      if (this.previewAlive && revision !== this.previewRevision) this.scheduleFramePreview();
    }
  }

  aboutToDisappear(): void {
    this.onClosed();
    this.previewAlive = false;
    this.previewRevision++;
    this.framePreviewExpanded = false;
    if (this.previewTimer >= 0) clearTimeout(this.previewTimer);
    if (this.composedPreview) this.composedPreview.release();
    this.composedPreview = null;
  }
  private previewIsPortrait(): boolean {
    return this.originalHeight > this.originalWidth;
  }

  private previewAspectRatio(): number {
    if (this.originalWidth <= 0 || this.originalHeight <= 0) return 1.5;
    return Math.max(0.25, Math.min(4, this.originalWidth / this.originalHeight));
  }

  /** 手动输入宽度：按原图比例联动高度并回填缩放百分比。 */
  private onWidthInput(value: string): void {
    this.exportWidth = value;
    const width = parseInt(value);
    if (isNaN(width) || width <= 0 || this.originalWidth <= 0) return;
    const ratio = this.originalHeight / this.originalWidth;
    this.exportHeight = Math.max(1, Math.round(width * ratio)).toString();
    this.scalePercent = `${Math.round(width / this.originalWidth * 100)}%`;
  }

  /** 手动输入高度：按原图比例联动宽度并回填缩放百分比。 */
  private onHeightInput(value: string): void {
    this.exportHeight = value;
    const height = parseInt(value);
    if (isNaN(height) || height <= 0 || this.originalHeight <= 0) return;
    const ratio = this.originalWidth / this.originalHeight;
    this.exportWidth = Math.max(1, Math.round(height * ratio)).toString();
    this.scalePercent = `${Math.round(height / this.originalHeight * 100)}%`;
  }

  /** 选择缩放百分比：同步更新宽高输入框。 */
  private applyScalePercent(pct: number): void {
    this.scalePercent = `${pct}%`;
    this.exportWidth = Math.max(1, Math.round(this.originalWidth * pct / 100)).toString();
    this.exportHeight = Math.max(1, Math.round(this.originalHeight * pct / 100)).toString();
  }
}



