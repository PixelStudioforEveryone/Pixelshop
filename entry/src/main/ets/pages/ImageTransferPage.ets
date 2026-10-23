import { CameraSessionStore } from '../services/CameraSessionStore';
import { LumixGalleryItem, LumixImportPrototype } from '../services/LumixImportPrototype';
import { AppDiagnostics } from '../services/AppDiagnostics';

const VIDEO_FILE_EXTENSIONS: string[] = [
  'mov', 'mp4', 'm4v', 'avi', 'mpg', 'mpeg', 'mts', 'm2ts', '3gp', 'wmv', 'asf',
];

function isVideoFileName(name: string): boolean {
  const lower = name.toLowerCase();
  for (const extension of VIDEO_FILE_EXTENSIONS) {
    if (lower.endsWith('.' + extension)) return true;
  }
  return false;
}

/**
 * 单张相机缩略图。原来的 Thumb 是带参数 @Builder，V1 下带参 @Builder 的
 * 子树不会随状态刷新（ForEach 同 key 也不会重跑 generator），因此选中 ✓、
 * 徽标等永远停留在首次构建的结果。改成独立子组件后，父页面每次同步
 * 都会通过 @Prop 把最新值压进来，刷新路径有框架保证。
 */
@Component
struct CameraTile {
  @Require @Prop imageId: string;
  @Require @Prop thumbnailUri: string;
  @Require @Prop originalFileName: string;
  @Require @Prop isVideo: boolean;
  @Require @Prop selected: boolean;
  public onOpenPreview: () => void = () => {
  };
  public onToggleSelect: () => void = () => {
  };

  private placeholderLabel(): string {
    const name = this.originalFileName.toLowerCase();
    const dot = name.lastIndexOf('.');
    if (dot >= 0 && dot < name.length - 1) {
      const ext = name.substring(dot + 1);
      if (ext.length > 0 && ext.length <= 5) return ext.toUpperCase();
    }
    return this.isVideo ? 'VIDEO' : 'IMG';
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // Sync 拉取线可能拿不到缩略图 res：空 URI 时渲染扩展名占位块，
      // 保持网格尺寸一致，点击仍可触发预览。
      if (this.thumbnailUri.length > 0) {
        Image(this.thumbnailUri)
          .width('100%')
          // Typical camera output is 3:2; let the tile height follow its width
          // instead of a fixed 150vp strip so PC-sized cards are not cropped.
          .aspectRatio(1.5)
          .objectFit(ImageFit.Cover)
          // PC cards can be several times larger than the camera thumbnail;
          // high interpolation keeps the upscale smooth instead of blocky.
          .interpolation(ImageInterpolation.High)
          .borderRadius(0)
          .onClick(() => {
            this.onOpenPreview();
          })
      } else {
        Column() {
          Text(this.placeholderLabel())
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#8A97AB')
        }
        .width('100%')
        .aspectRatio(1.5)
        .backgroundColor('#202A3B')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onOpenPreview();
        })
      }
      if (this.isVideo) {
        Text('▶ 视频')
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor('rgba(32,42,59,0.88)')
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .borderRadius(4)
          .position({ x: 4, y: 4 });
      }
      if (this.originalFileName.length > 0) {
        // Anchor the name chip to the tile bottom (the old hardcoded
        // y:122 only matched the removed 150vp fixed height).
        Row() {
          Text(this.originalFileName)
            .fontSize(9)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .backgroundColor('rgba(0,0,0,0.46)')
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .width('62%')
        }
        .width('100%')
        .padding({ left: 4, right: 4 })
        .margin({ bottom: 6 })
        .justifyContent(FlexAlign.Start)
      }
      Button({ type: ButtonType.Circle }) {
        Text(this.selected ? '✓' : '')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.vivid_text_316cf4'))
      }
        .width(28)
        .height(28)
        .padding(0)
        .backgroundColor($r('app.color.vivid_surface_ffffff'))
        .border({
          width: 1.5,
          color: this.selected ? '#316CF4' : 'rgba(255,255,255,0.96)',
        })
        .margin({ right: 6, bottom: 6 })
        .onClick(() => {
          this.onToggleSelect();
        })
    }
    .width('100%')
    .aspectRatio(1.5)
    .padding(0)
    .backgroundColor('rgba(255,255,255,0.02)')
  }
}

/** 薄壳页面把 onBackPress 转发给真正的视图；view 在 aboutToAppear 注册、销毁时清除。 */
export class ImageTransferPageBridge {
  static back: (() => boolean) | null = null;
}

@Component
export struct ImageTransferView {
  /** 会话数据源。V1 @Observed/@Track 对数组属性赋值不会通知页面刷新，
   * 页面不再直接依赖它的响应式，而是同步成本地 @State 镜像。 */
  private cam: CameraSessionStore = CameraSessionStore.instance;
  private scroller: Scroller = new Scroller();
  private lastScrollY: number = 0;
  private scrollWatermark: number = 0;
  private previewPinchStartScale: number = 1;
  private syncTimer: number = -1;
  @State private fabX: number = 0;
  @State private fabY: number = 0;
  private fabPlaced: boolean = false;
  private fabSize: number = 56;
  private fabContainerWidth: number = 0;
  private fabContainerHeight: number = 0;
  private fabDragOriginX: number = 0;
  private fabDragOriginY: number = 0;

  // ---- 本地镜像（唯一的 UI 数据来源） ----
  @State private model: string = '';
  @State private message: string = '';
  @State private sessionStatus: string = '';
  @State private wifiStatus: string = '';
  @State private bleStatus: string = '';
  @State private brand: string = '';
  @State private selectedSd: string = '';
  // 相机通过 BLE SLOT_INFO 上报的槽位名，原样保留（S1RM2 是 CFe/SD/SSD，
  // S9 是 SSD，双 SD 槽机身是 SD1/SD2）。这两个数组与相机上报顺序一一对应。
  // 为空表示还没读到，此时退回旧的 SD1/SD2 双按钮，不替相机假设。
  @State private cameraSlots: string[] = [];
  @State private cameraSlotLabels: string[] = [];
  @State private cameraSlotPresent: boolean[] = [];
  @State private syncPush: boolean = false;
  @State private syncPull: boolean = false;
  @State private sd1Present: boolean = true;
  @State private sd2Present: boolean = false;
  /** 在位状态的来源（none/sync-probe/lab-current-sd/ble-slot），决定按钮是否被门控。 */
  @State private sdPresenceSource: string = 'none';
  @State private items: LumixGalleryItem[] = [];
  @State private total: number = 0;
  @State private hasMore: boolean = false;
  @State private loading: boolean = false;
  @State private selectedIds: string[] = [];
  @State private cameraState: number = 0;
  @State private transferInProgress: boolean = false;
  @State private downloadInProgress: boolean = false;
  @State private downloadProgress: number = 0;
  @State private downloadStatus: string = '';
  @State private s5Receiving: boolean = false;
  @State private s5Progress: number = 0;
  @State private s5Status: string = '';
  @State private s5Files: number = 0;
  @State private previewVisible: boolean = false;
  @State private previewLoading: boolean = false;
  @State private previewUri: string = '';
  @State private previewScale: number = 1;
  @State private previewIsVideo: boolean = false;
  @State private previewPlaybackFailed: boolean = false;

  /** 卡槽诊断去重键：只在取值变化时记一行，避免状态刷新刷屏。 */
  private lastSdPresenceKey: string = '';

  private syncFromStore(): void {
    const cam = this.cam;
    this.model = cam.cameraModel;
    this.message = cam.cameraMessage;
    this.sessionStatus = cam.cameraSessionStatus;
    this.wifiStatus = cam.cameraWifiStatus;
    this.bleStatus = cam.cameraBleStatus;
    this.brand = cam.cameraBrand;
    this.selectedSd = cam.selectedSd;
    const slotInfo = LumixImportPrototype.currentSlotInfo();
    const slotWires: string[] = [];
    const slotLabels: string[] = [];
    const slotPresent: boolean[] = [];
    for (const slot of slotInfo.slots) {
      slotWires.push(slot.wire);
      slotLabels.push(slot.display);
      slotPresent.push(slot.present);
    }
    this.cameraSlots = slotWires;
    this.cameraSlotLabels = slotLabels;
    this.cameraSlotPresent = slotPresent;
    this.syncPush = cam.isPassivePushSelected();
    this.syncPull = cam.syncPullActive;
    this.sd1Present = cam.cameraSd1Present;
    this.sd2Present = cam.cameraSd2Present;
    this.sdPresenceSource = cam.cameraSdPresenceSource;
    // These two flags gate the SD buttons (`enabled`), so a refused click leaves
    // no other trace at all. Record which slots the page believes are present
    // and where that belief came from, but only when it changes.
    const sdPresenceKey = `${cam.selectedSd}|${this.sd1Present ? 1 : 0}|${this.sd2Present ? 1 : 0}|${cam.cameraSdPresenceSource}`;
    if (sdPresenceKey !== this.lastSdPresenceKey) {
      this.lastSdPresenceKey = sdPresenceKey;
      AppDiagnostics.event('APP', `card slot presence selectedSd=${cam.selectedSd}` +
        ` sd1Present=${this.sd1Present ? 1 : 0} sd2Present=${this.sd2Present ? 1 : 0}` +
        ` sdSource=${cam.cameraSdPresenceSource}`);
    }
    this.items = cam.cameraGalleryItems;
    this.total = cam.cameraGalleryTotal;
    this.hasMore = cam.cameraGalleryHasMore;
    this.loading = cam.cameraGalleryLoading;
    this.selectedIds = cam.selectedCameraImageIds;
    this.cameraState = cam.cameraState;
    this.transferInProgress = cam.cameraTransferInProgress;
    this.downloadInProgress = cam.cameraDownloadInProgress;
    this.downloadProgress = cam.cameraDownloadProgress;
    this.downloadStatus = cam.cameraDownloadStatus;
    this.s5Receiving = cam.s5Receiving;
    this.s5Progress = cam.s5ReceiveProgress;
    this.s5Status = cam.s5ReceiveStatus;
    this.s5Files = cam.s5ReceiveFiles;
    this.previewVisible = cam.cameraPreviewVisible;
    this.previewLoading = cam.cameraPreviewLoading;
    this.previewUri = cam.cameraPreviewUri;
    this.previewScale = cam.cameraPreviewScale;
    this.previewIsVideo = cam.cameraPreviewIsVideo;
    if (!cam.cameraPreviewVisible) this.previewPlaybackFailed = false;
  }

  aboutToAppear(): void {
    ImageTransferPageBridge.back = (): boolean => this.handleBackPress();
    this.lastScrollY = 0;
    this.scrollWatermark = 0;
    this.cam.cameraGalleryAtBottomEdge = false;
    this.syncFromStore();
    if (this.cameraState === 2 && this.items.length === 0 &&
      !this.transferInProgress && !this.loading) {
      const driver = this.cam.driver;
      if (driver !== null) void driver.startImageTransfer();
    }
    // 轮询兜底：store 数组赋值不触发 @Track 通知，300ms 内保证可见。
    this.syncTimer = setInterval(() => {
      this.syncFromStore();
    }, 300);
  }

  aboutToDisappear(): void {
    ImageTransferPageBridge.back = null;
    if (this.syncTimer >= 0) {
      clearInterval(this.syncTimer);
      this.syncTimer = -1;
    }
    const driver = this.cam.driver;
    if (driver !== null) void driver.endSession();
  }

  handleBackPress(): boolean {
    // S5 被动接收不再阻塞返回：进度由全局浮层继续显示，退出页面不影响接收。
    if (this.downloadInProgress) return true;
    if (this.previewVisible) {
      const driver = this.cam.driver;
      if (driver !== null) driver.closePreview();
      this.syncFromStore();
      return true;
    }
    return false;
  }

  /**
   * 状态行文字。张数已经由标题表达，这里再重复一句「已从相机下载 12 张缩略图」
   * 只是噪音（2026-10-17 用户要求删除）。错误、切换失败这类有信息量的提示保留。
   */
  private statusMessage(): string {
    const text = this.message;
    if (text.length === 0) return '';
    if (/^已从相机(下载|加载)\s*\d+\s*张缩略图$/.test(text)) return '';
    if (/^已加载\s*\d+\s*张缩略图$/.test(text)) return '';
    return text;
  }

  private gallerySubtitle(): string {
    // 总数是相机一开始就给的（`Data.Count`，官方拉到 loaded >= Count 才停，见
    // CameraGalleryActivity:1189-1196），必须立刻显示，不能等翻完。
    //
    // 但分母不能和网格格数直接相除：`total` 是**记录数**（一张 RAW+JPEG 算 1 条），
    // 网格每格是**文件**（同一条记录的 JPEG 与 RAW 各占一格）。单位不同，写成
    // `24/12` 就是自相矛盾（2026-10-17 真机现象）。所以两个数各自标明含义。
    if (this.items.length === 0) return '等待相机图片';
    if (this.total <= 0) return `${this.items.length} 个文件`;
    if (this.items.length === this.total) return `${this.total} 张`;
    return `共 ${this.total} 张 · 已载 ${this.items.length} 个文件`;
  }

  private emptyStateText(): string {
    // PTP/IP 线（索尼 / 尼康）是主动拉取，没有松下 Lab 的「下滑触发」一说：
    // 进入页面即由 driver.startImageTransfer 取第一页，所以文案不能沿用
    // 「下滑开始加载」。这两条线由 CameraSessionStore.cameraBrand 区分。
    if (this.brand === 'Sony' || this.brand === 'Nikon') {
      if (this.loading) return '正在读取相机图库…';
      if (this.cameraState === 2) return '已连接相机，正在读取相机图库…';
      return '连接相机后即可读取相机图库';
    }
    if (this.syncPull) {
      if (this.loading) return '正在读取相机图库…';
      if (this.cameraState === 2) return '已连接相机，点击读取相机图库';
      return '连接相机后即可读取相机图库';
    }
    if (this.syncPush) {
      if (this.cameraState === 2) {
        return this.s5Files > 0
          ? `已与 ${this.model} 建立接收通道，已接收 ${this.s5Files} 个文件`
          : `已与 ${this.model} 建立接收通道，等待相机推送素材`;
      }
      return '连接后由相机端推送图片';
    }
    if (this.loading) return '正在加载相机照片…';
    if (this.wifiStatus === '已连接') return '已连接相机，下滑开始加载相机照片';
    if (this.transferInProgress) return '正在建立 Wi‑Fi 会话…';
    return '连接相机后，加载并勾选需要导入的照片';
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('‹')
            .fontSize(34)
            .fontColor('#1B2536')
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
          Text('图片传输')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1B2536')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Blank().width(34)
        }
        .width('100%')
        .height(62)
        .padding({ left: 14, right: 14 })

        Scroll(this.scroller) {
          Column() {
            this.StatusCard();
            // SD 选择器与 Lab 线同位置（状态卡与图库卡之间）：Lab 全部
            // 显示；Sync 线在主动拉取模式显示，被动推送模式不显示
            // （推送由相机端当前卡决定）。
            // 松下：Lab 线全部显示；Sync 线仅在主动拉取模式显示（被动推送由
            // 相机端当前卡决定）。索尼：卡槽是 0x923B/0x923C 的请求参数，会话
            // 建立后即可由用户指定并重新枚举，所以 cameraState===2 就显示。
            if ((this.brand === 'Panasonic' && this.cameraState === 2 &&
              (this.syncPull || !this.syncPush)) ||
              (this.brand === 'Sony' && this.cameraState === 2)) {
              this.SdSelector();
            }
            this.GalleryCard();
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 40 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onScrollEdge((side: Edge) => {
          if (side !== Edge.Bottom) return;
          this.cam.cameraGalleryAtBottomEdge = true;
          const driver = this.cam.driver;
          if (driver !== null) void driver.fetchMoreGallery();
          if (driver !== null) void driver.triggerScrollLoad();
        })
        .onScroll(() => {
          const currentOffset = this.scroller.currentOffset().yOffset;
          if (currentOffset < this.lastScrollY) {
            this.cam.cameraGalleryAtBottomEdge = false;
          }
          this.lastScrollY = currentOffset;
          if (currentOffset > this.scrollWatermark + 220) {
            this.scrollWatermark = currentOffset;
            const driver = this.cam.driver;
            if (driver !== null) void driver.fetchMoreGallery();
            if (driver !== null) void driver.triggerScrollLoad();
          }
        })
      }
      .width('100%')
      .height('100%')
      .safeAreaPadding({ top: 24 })

      if (this.items.length > 0) {
        this.DownloadFab();
      }
      if (this.downloadInProgress) {
        this.DownloadOverlay();
      }
      // S5 被动接收进度不再用本页模态弹窗：改为窗口级全局浮层
      // S5ReceiveOverlay（主页与其他页面均可见，非阻塞）。
      if (this.previewVisible) {
        this.PreviewOverlay();
      }
    }
    .width('100%')
    .height('100%')
    .linearGradient({ angle: 160, colors: [['#F3F6FC', 0], ['#E9EFF9', 1]] })
    .onAreaChange((_: Area, newArea: Area) => {
      const width = newArea.width as number;
      const height = newArea.height as number;
      if (width <= 0 || height <= 0) return;
      this.fabContainerWidth = width;
      this.fabContainerHeight = height;
      if (!this.fabPlaced) {
        this.fabPlaced = true;
        this.fabX = Math.max(0, width - this.fabSize - 16);
        // 默认放底部右侧，避开右列缩略图的选中圆钮。
        this.fabY = Math.max(0, height - this.fabSize - 150);
        return;
      }
      const maxX = Math.max(0, width - this.fabSize);
      const maxY = Math.max(0, height - this.fabSize);
      this.fabX = Math.min(this.fabX, maxX);
      this.fabY = Math.min(this.fabY, maxY);
    });
  }

  @Builder
  StatusCard() {
    Column() {
      Row() {
        Column() {
          Text(this.model.length > 0 ? this.model : '相机')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1B2536')
          if (this.statusMessage().length > 0) {
            Text(this.statusMessage())
              .fontSize(10)
              .fontColor('#66758B')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(this.sessionStatus === '已建立' ? '会话已建立' :
          (this.wifiStatus === '已连接' ? 'Wi‑Fi 已连接' : '等待连接'))
          .fontSize(11)
          .fontColor(this.sessionStatus === '已建立' ? '#1E8E5A' : '#66758B')
      }
      .width('100%')
      Row() {
        Text(`蓝牙 ${this.bleStatus}`)
          .fontSize(10)
          .fontColor(this.bleStatus === '已连接' ? '#1E8E5A' : '#7B8798')
          .layoutWeight(1)
        Text(`Wi‑Fi ${this.wifiStatus}`)
          .fontSize(10)
          .fontColor(this.wifiStatus === '已连接' ? '#1E8E5A' : '#7B8798')
          .layoutWeight(1)
        Text(`会话 ${this.sessionStatus}`)
          .fontSize(10)
          .fontColor(this.sessionStatus === '已建立' ? '#1E8E5A' : '#7B8798')
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.78)')
    .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
    .margin({ top: 6 })
  }

  @Builder
  SdSelector() {
    Row() {
      Column() {
        Text('存储卡')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1B2536')
        Text('切换存储卡后将重新读取相机图库')
          .fontSize(9)
          .fontColor('#66758B')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      // 按相机上报的槽位清单渲染，一个槽位一个按钮：
      //   S1RM2 → CFe / SD / SSD（CFexpress 机身，见 C5/L4.java:411-419）
      //   S9    → SSD（单卡槽）
      //   双 SD 槽机身 → SD1 / SD2
      // 写死 SD1/SD2 时 S1RM2 的 current-sd 虽回 200 却不切卡，所以 SD 卡的照片
      // 永远出不来；这里必须用相机的名字。清单读不到时才退回旧的两按钮。
      if (this.cameraSlots.length === 0) {
        this.SdSlotButton(0, 'SD1')
        this.SdSlotButton(1, 'SD2')
      } else {
        this.SdSlotButton(0, 'SD1')
        if (this.cameraSlots.length > 1) {
          this.SdSlotButton(1, 'SD2')
        }
        if (this.cameraSlots.length > 2) {
          this.SdSlotButton(2, 'SD2')
        }
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.78)')
    .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
    .margin({ top: 10 })
  }

  /**
   * 在位状态是否已知。Sync/lumix_image 线由 cam.cgi 的 `<sd_memory>` /
   * `<sd2_memory>` 探针给出（sdSource=sync-probe）；Lab REST 线**没有**这个探针，
   * 早期实现直接借用了它的结果 → S1RM2 上 `cameraSd2Present` 恒为 false，SD2
   * 按钮被 `.enabled(false)` 永久禁用，`CurrentSd=SD2` 请求根本发不出（复核报告 §1）。
   */
  private sdPresenceKnown(): boolean {
    return this.sdPresenceSource !== 'none';
  }

  private sdSlotPresent(slot: string): boolean {
    return slot === 'SD1' ? this.sd1Present : this.sd2Present;
  }

  /** 相机上报的第 index 个槽位的 current-sd 值；没读到清单时退回旧的 SD1/SD2。 */
  private slotNameAt(index: number, fallback: string): string {
    return index < this.cameraSlots.length ? this.cameraSlots[index] : fallback;
  }

  /** 该槽位是否可点：有清单时按相机的在位标志，没清单时沿用旧逻辑。 */
  private slotEnabledAt(index: number, fallback: string): boolean {
    if (index < this.cameraSlotPresent.length) return this.cameraSlotPresent[index];
    return !this.sdPresenceKnown() || this.sdSlotPresent(fallback);
  }

  /**
   * 槽位按钮文字。无卡时**只置灰、不加任何文字标记**（按用户 2026-10-17 要求）：
   * 按钮本来就禁用了，"（无卡）"只会让标题变长、还会被误读成相机识别失败。
   */
  private slotLabelAt(index: number, fallback: string): string {
    return index < this.cameraSlotLabels.length
      ? this.cameraSlotLabels[index] : fallback;
  }

  /**
   * 单个槽位按钮。名字、在位状态、点击后发送的值全部取自相机上报的清单。
   * 线上值按官方序号映射（CameraGalleryActivity.c0 :967-975）：非 SSD 的第 0 个
   * 是 `SD1`、第 1 个是 `SD2`，SSD 单独命名——`CFe`/`SD` 只是显示文字。
   */
  @Builder
  SdSlotButton(index: number, fallback: string) {
    Button(this.slotLabelAt(index, fallback))
      .height(30)
      .fontSize(11)
      .padding({ left: 16, right: 16 })
      .margin({ left: index === 0 ? 0 : 8 })
      .fontColor(this.selectedSd === this.slotNameAt(index, fallback) ? '#FFFFFF' : '#316CF4')
      .type(ButtonType.Capsule)
      .backgroundColor(this.selectedSd === this.slotNameAt(index, fallback)
        ? '#316CF4' : 'rgba(49,108,244,0.10)')
      .opacity(this.slotEnabledAt(index, fallback) ? 1 : 0.45)
      .enabled(this.slotEnabledAt(index, fallback))
      .onClick(() => {
        const driver = this.cam.driver;
        if (driver !== null) void driver.switchSd(this.slotNameAt(index, fallback));
        this.syncFromStore();
      })
  }

  @Builder
  GalleryCard() {
    Column() {
      Row() {
        Column() {
          Text('相机图库')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1B2536')
          Text(this.gallerySubtitle())
            .fontSize(11)
            .fontColor('#66758B')
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text(`${this.selectedIds.length} 张已选`)
          .fontSize(11)
          .fontColor(this.selectedIds.length > 0 ? '#316CF4' : '#66758B')
      }
      .width('100%')
      if (this.items.length > 0) {
        Text('已选 ' + this.selectedIds.length + ' 张 · 继续下滑加载更早照片')
          .fontSize(10)
          .fontColor('#7B8798')
          .width('100%')
          .margin({ top: 14, bottom: 8 })
        Grid() {
          ForEach(this.items, (item: LumixGalleryItem) => {
            GridItem() {
              CameraTile({
                imageId: item.imageId,
                thumbnailUri: item.thumbnailUri,
                originalFileName: item.originalFileName || '',
                isVideo: isVideoFileName(item.originalFileName || ''),
                selected: this.selectedIds.indexOf(LumixImportPrototype.galleryItemKey(item)) >= 0,
                onOpenPreview: (): void => {
                  const driver = this.cam.driver;
                  if (driver !== null) void driver.openPreview(item);
                  this.syncFromStore();
                },
                onToggleSelect: (): void => {
                  const driver = this.cam.driver;
                  if (driver !== null) driver.toggleSelection(LumixImportPrototype.galleryItemKey(item));
                  this.syncFromStore();
                },
              })
            }
          }, (item: LumixGalleryItem) =>
            // key 必须把缩略图状态算进去：galleryItemKey 只有 imageId:imageType，
            // 缩略图到达时它不变 → ArkUI 复用旧节点、不重跑 generator →
            // image 的 @Prop thumbnailUri 永远收不到新值（本文件顶部注释已警告过
            // "ForEach 同 key 也不会重跑 generator"）。带上 0/1 后缀后，每张图
            // 的缩略图到达时会重建一次该节点，正是刷新所需的最少代价。
            `${LumixImportPrototype.galleryItemKey(item)}#${item.thumbnailUri.length > 0 ? 1 : 0}`)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(0)
        .rowsGap(0)
        .cachedCount(4)
        .width('100%')
        if (this.loading) {
          LoadingProgress().width(22).height(22).color('#316CF4').margin({ top: 12 });
        } else if (this.hasMore) {
          Text('继续下滑加载相机照片').fontSize(10).fontColor('#7B8798').margin({ top: 12 });
        } else if (this.total > 0) {
          Text('已加载相机中的全部照片').fontSize(10).fontColor('#7B8798').margin({ top: 12 });
        }
      } else {
        Column() {
          Text('⇣')
            .fontSize(40)
            .fontColor('#B3BCCB')
          Text(this.emptyStateText())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#526078')
            .textAlign(TextAlign.Center)
            .margin({ top: 10 })
          if (this.syncPull) {
            if (!this.loading && !this.transferInProgress && this.cameraState === 2) {
              Button('读取相机图库')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .type(ButtonType.Capsule)
                .height(38)
                .padding({ left: 18, right: 18 })
                .backgroundColor('#316CF4')
                .margin({ top: 16 })
                .onClick(() => {
                  const driver = this.cam.driver;
                  if (driver !== null) void driver.startImageTransfer();
                  this.syncFromStore();
                })
            }
          } else if (!this.syncPush && !this.loading &&
            this.wifiStatus !== '已连接') {
            Button(this.transferInProgress ? '正在建立 Wi‑Fi 会话…' :
              (this.cameraState === 1 ? '正在连接…' : '连接相机'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .type(ButtonType.Capsule)
              .height(38)
              .padding({ left: 18, right: 18 })
              .backgroundColor('#316CF4')
              .margin({ top: 16 })
              .enabled(!this.transferInProgress && this.cameraState !== 1)
              .onClick(() => {
                const driver = this.cam.driver;
                if (driver !== null) void driver.startImageTransfer();
                this.syncFromStore();
              })
          }
        }
        .width('100%')
        .padding({ top: 26, bottom: 26 })
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .padding(18)
    .borderRadius(24)
    .backgroundColor('rgba(255,255,255,0.78)')
    .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
    .margin({ top: 10 })
  }

  @Builder
  DownloadFab() {
    Stack() {
      Column() {
        Text('↓')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.selectedIds.length > 0 ? '#FFFFFF' : '#7B8798')
      }
      .width(this.fabSize)
      .height(this.fabSize)
      .borderRadius(this.fabSize / 2)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.selectedIds.length > 0 ? '#316CF4' : '#D1D5DB')
      .shadow({ radius: 12, color: 'rgba(15,22,35,0.35)', offsetY: 4 })
      .onClick(() => {
        const driver = this.cam.driver;
        if (driver !== null && this.selectedIds.length > 0) {
          void driver.downloadSelected();
          this.syncFromStore();
        }
      })
      .gesture(
        // distance 阈值避免轻微滑动误吞点击。
        PanGesture({ fingers: 1, distance: 8 })
          .onActionStart((event: GestureEvent) => {
            this.fabDragOriginX = this.fabX;
            this.fabDragOriginY = this.fabY;
          })
          .onActionUpdate((event: GestureEvent) => {
            const maxX = Math.max(0, this.fabContainerWidth - this.fabSize);
            const maxY = Math.max(0, this.fabContainerHeight - this.fabSize);
            this.fabX = Math.max(0, Math.min(this.fabDragOriginX + event.offsetX, maxX));
            this.fabY = Math.max(0, Math.min(this.fabDragOriginY + event.offsetY, maxY));
          })
      )
      if (this.selectedIds.length > 0) {
        Text(`${this.selectedIds.length}`)
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width(18)
          .height(18)
          .borderRadius(9)
          .textAlign(TextAlign.Center)
          .backgroundColor('#C4485C')
          .border({ width: 1.5, color: '#FFFFFF' })
          .position({ x: this.fabSize - 12, y: -6 })
      }
    }
    .width(this.fabSize)
    .height(this.fabSize)
    .position({ x: this.fabX, y: this.fabY })
  }

  @Builder
  DownloadOverlay() {
    Column() {
      Column() {
        Text('正在下载原图').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#172033')
        Text(this.downloadStatus).fontSize(11).fontColor('#526078').maxLines(2)
          .margin({ top: 8 });
        Progress({ value: this.downloadProgress, total: 100, type: ProgressType.Linear })
          .width('100%').height(8).color('#316CF4').backgroundColor($r('app.color.vivid_surface_dce2ec'))
          .borderRadius(4).margin({ top: 18, bottom: 8 });
        Text(`${Math.round(this.downloadProgress)}%`).fontSize(12).fontColor($r('app.color.vivid_text_316cf4'))
          .textAlign(TextAlign.End).width('100%');
      }
      .width('82%').padding(22).borderRadius(20)
      .backgroundColor('#FFFFFF')
      .shadow({ radius: 28, color: 'rgba(40,55,82,0.22)', offsetY: 10 });
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(22,30,45,0.28)')
    .zIndex(110)
    .hitTestBehavior(HitTestMode.Block);
  }

  @Builder
  PreviewOverlay() {
    Stack() {
      Column() {
        Stack() {
          if (this.previewLoading) {
            LoadingProgress().width(42).height(42).color('#FFFFFF');
          } else if (this.previewIsVideo && this.previewUri.length > 0) {
            // 视频直接流式播放相机 res URL（不落盘）。MOV/AVCHD 等容器
            // 播放器不支持时走 onError 兜底文案，仍可勾选后下载到图库。
            Column() {
              if (this.previewPlaybackFailed) {
                Text('视频播放失败，可勾选后下载到图库查看')
                  .fontSize(14)
                  .fontColor($r('app.color.vivid_text_ffffff'))
              } else {
                Video({ src: this.previewUri })
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Contain)
                  .autoPlay(true)
                  .controls(true)
                  .borderRadius(18)
                  .onError(() => {
                    this.previewPlaybackFailed = true;
                  })
              }
            }
            .width('92%')
            .height('78%')
            .justifyContent(FlexAlign.Center)
            .shadow({ radius: 22, color: 'rgba(0,0,0,0.48)', offsetX: 12, offsetY: 14 });
          } else if (this.previewUri.length > 0) {
            Stack() {
              Image(this.previewUri)
                .width('92%').height('78%').objectFit(ImageFit.Contain)
                .borderRadius(18)
                .scale({ x: this.previewScale, y: this.previewScale })
                .gesture(
                  PinchGesture({ fingers: 2 })
                    .onActionStart(() => {
                      this.previewPinchStartScale = this.previewScale;
                    })
                    .onActionUpdate((event: GestureEvent) => {
                      const factor = event.scale;
                      if (factor && factor > 0) {
                        const next = Math.max(1,
                          Math.min(5, this.previewPinchStartScale * factor));
                        // 本地与 store 同步写，避免 300ms 轮询把缩放弹回。
                        this.previewScale = next;
                        this.cam.cameraPreviewScale = next;
                      }
                    })
                )
            }
            .width('92%').height('78%')
            .shadow({ radius: 22, color: 'rgba(0,0,0,0.48)', offsetX: 12, offsetY: 14 });
          } else {
            Text('原图加载失败').fontSize(14).fontColor($r('app.color.vivid_text_ffffff'));
          }
        }
        .width('100%').height('82%');
        Text(this.previewIsVideo ? '视频流式播放 · 全局返回关闭' : '双指缩放 · 全局返回关闭')
          .fontSize(11).fontColor('rgba(255,255,255,0.72)').margin({ top: 6 });
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
    }
    .width('100%').height('100%')
    .backgroundColor('rgba(15,22,35,0.88)')
    .zIndex(105)
    .hitTestBehavior(HitTestMode.Block);
  }
}
