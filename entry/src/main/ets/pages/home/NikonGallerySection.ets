/**
 * 尼康相机图库区块 —— 从 `CameraPage` 摘出来的独立组件。
 *
 * **为什么单独成文件**：`CameraPage` 已经接近 7000 行，塞进图库网格、缩略图
 * 徽标、多卡切换之后会进一步膨胀，改一处要在一整个页面里找半天。图库是
 * 自成一体的功能（数据来自 `NikonPtpIpService`，状态放在 `CameraSessionStore`），
 * 摘出来之后 `CameraPage` 只留一行引用。
 *
 * **为什么不需要层层传参**：`CameraSessionStore` 是 `@Observed` + `@Track` 的
 * 单例，本组件直接读 `CameraSessionStore.instance`，图库刷新、选中变化都会
 * 自动触发重绘——和原来在页面里读 `this.cam` 完全等价。
 *
 * 页面只提供两个回调（打开预览、切换选中）和两个主题色，其余全部自持。
 */
import { CameraSessionStore } from '../../services/CameraSessionStore';
import { LumixGalleryItem, LumixImportPrototype } from '../../services/LumixImportPrototype';

/** 视频扩展名。列出来是为了给视频打角标：视频会显示在图库里，但点开只提示不支持调色。 */
const VIDEO_FILE_EXTENSIONS: string[] = [
  'mov', 'mp4', 'm4v', 'avi', 'mpg', 'mpeg', 'mts', 'm2ts', '3gp', 'wmv', 'asf',
];

function isVideoName(name: string): boolean {
  const lower = (name || '').toLowerCase();
  for (const extension of VIDEO_FILE_EXTENSIONS) {
    if (lower.endsWith('.' + extension)) return true;
  }
  return false;
}

/** 文件名里的扩展名，大写；取不到时返回空串。 */
function extensionOf(name: string): string {
  const lower = (name || '').toLowerCase();
  const dot = lower.lastIndexOf('.');
  if (dot < 0 || dot >= lower.length - 1) return '';
  const extension = lower.substring(dot + 1);
  return extension.length > 0 && extension.length <= 5 ? extension.toUpperCase() : '';
}

@Component
export struct NikonGallerySection {
  /** 点缩略图：交给页面去开预览（预览要拿 UIAbilityContext、要下载原图）。 */
  onOpen: (item: LumixGalleryItem) => void = () => {
  };
  /** 点右下角圆圈：交给页面去改选中集合。 */
  onToggleSelect: (key: string) => void = () => {
  };
  /** 主题色由页面压进来，摘出来之后配色仍与页面其它卡片一致。 */
  @Prop panelTextColor: string = '#1B2536';
  @Prop mutedTextColor: string = '#66758B';

  private cam: CameraSessionStore = CameraSessionStore.instance;

  /** 当前选中的卡号。0 表示"还没点过，跟随第一张被发现的卡"。 */
  @State private selectedCard: number = 0;

  /** 要显示切换按钮的卡槽，按卡槽顺序，**含空卡**。
   *
   * 优先用相机上报的 `nikonStorageIds`（`OP_GET_STORAGE_IDS` 的结果，空卡也在
   * 里面）。只有拿不到时才退回从条目里反推——那条路会漏掉空卡，所以只是兜底。 */
  private cardIds(): number[] {
    const reported = this.cam.nikonStorageIds;
    if (reported.length > 0) return reported;
    const cards: number[] = [];
    for (const item of this.cam.cameraGalleryItems) {
      const storageId = item.storageId === undefined ? 0 : item.storageId;
      if (storageId === 0) continue;
      if (!cards.includes(storageId)) cards.push(storageId);
    }
    return cards;
  }

  /** 这张卡上有没有照片。空卡按钮置灰，与 Lab 线「SD2（无卡）」的表现一致。 */
  private cardHasItems(cardId: number): boolean {
    for (const item of this.cam.cameraGalleryItems) {
      if ((item.storageId === undefined ? 0 : item.storageId) === cardId) return true;
    }
    return false;
  }

  /** 当前生效的卡号：用户点过就用他点的，否则用第一张**有照片**的卡。
   *
   * 从有照片的卡开始，是因为插着两张卡但只拍了一张时，用户想看的就是那一张；
   * 落在空卡上会看到一个空网格，像加载失败。 */
  private activeCard(): number {
    const cards = this.cardIds();
    if (cards.length === 0) return 0;
    if (cards.includes(this.selectedCard) && this.cardHasItems(this.selectedCard)) {
      return this.selectedCard;
    }
    for (const cardId of cards) {
      if (this.cardHasItems(cardId)) return cardId;
    }
    return cards[0];
  }

  /** 要显示的照片：多卡时只显示当前卡，单卡时原样返回。
   *
   * 过滤是纯客户端的——`NikonPtpIpService` 建会话时已经把**两张卡**的对象全部
   * 读进来了，切卡只是换个视角看同一份数据，不需要重新连相机（尼康的 PTP/IP
   * 也没有"把当前卡切成哪一张"这种操作）。 */
  private visibleItems(): LumixGalleryItem[] {
    const cards = this.cardIds();
    if (cards.length <= 1) return this.cam.cameraGalleryItems;
    const active = this.activeCard();
    return this.cam.cameraGalleryItems.filter((item: LumixGalleryItem): boolean =>
      (item.storageId === undefined ? 0 : item.storageId) === active);
  }

  /** 卡按钮文案：卡 1 / 卡 2……与相机菜单里的叫法一致；空卡标注出来。 */
  private cardLabel(cardId: number): string {
    const position = this.cardIds().indexOf(cardId);
    const name = position >= 0 ? `卡 ${position + 1}` : '卡';
    return this.cardHasItems(cardId) ? name : `${name}（空）`;
  }

  /**
   * 左侧角标：视频 / 原始格式。
   *
   * 这里按**文件名扩展名**判断，而不是套用某个品牌的固定文案。原来的写法把
   * 松下那套 `RW2`（= 松下的 RAW）写死了，尼康机身上会显示成 `RW2`，而尼康的
   * RAW 是 `NEF`；索尼又是 `ARW`。按扩展名显示对三家都正确。
   */
  private badgeLabel(item: LumixGalleryItem): string {
    if (isVideoName(item.originalFileName || '')) return '▶ 视频';
    const extension = extensionOf(item.originalFileName || '');
    const rawSize = item.rawSize === undefined ? 0 : item.rawSize;
    if (rawSize > 0 && extension.length > 0) return `JPG + ${extension}`;
    if (item.imageType !== 2 || rawSize > 0) {
      return extension.length > 0 ? extension : 'RAW';
    }
    return '';
  }

  @Builder
  CardSelector() {
    // 布局与 Lab 线一致（`ImageTransferPage.SdSelector`）：左边标题 + 副标题，
    // 右边一组胶囊按钮，选中蓝底白字、未选浅蓝底蓝字。
    Row() {
      Column() {
        Text('存储卡')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.panelTextColor)
        Text('切换存储卡后只显示该卡上的照片')
          .fontSize(9)
          .fontColor(this.mutedTextColor)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      ForEach(this.cardIds(), (cardId: number) => {
        Button(this.cardLabel(cardId))
          .height(30)
          .fontSize(11)
          .padding({ left: 16, right: 16 })
          .fontColor(this.activeCard() === cardId ? '#FFFFFF' : '#316CF4')
          .type(ButtonType.Capsule)
          .backgroundColor(this.activeCard() === cardId ? '#316CF4' : 'rgba(49,108,244,0.10)')
          // 空卡仍然可点（点了会看到一个空网格，这是事实，不是错误），但视觉上
          // 压暗一点，和 Lab 线「SD2（无卡）」的半透明处理一致。
          .opacity(this.cardHasItems(cardId) ? 1 : 0.45)
          .margin({ left: 8 })
          .onClick(() => {
            this.selectedCard = cardId;
          })
      }, (cardId: number) => `nikon-card-${cardId}`)
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.78)')
    .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
    .margin({ bottom: 12 })
  }

  @Builder
  Thumbnail(item: LumixGalleryItem) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Image(item.thumbnailUri)
        .width('100%')
        .height(150)
        .objectFit(ImageFit.Cover)
        .borderRadius(0)
        .onClick(() => {
          this.onOpen(item);
        })
      if (this.badgeLabel(item).length > 0) {
        Text(this.badgeLabel(item))
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor('rgba(32,42,59,0.88)')
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .borderRadius(4)
          .position({ x: 4, y: 4 })
      }
      if (item.originalFileName && item.originalFileName.length > 0) {
        Text(item.originalFileName)
          .fontSize(9)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .backgroundColor('rgba(0,0,0,0.46)')
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .position({ x: 4, y: 122 })
          .width('62%')
      }
      Button({ type: ButtonType.Circle }) {
        Text(this.cam.selectedCameraImageIds.indexOf(LumixImportPrototype.galleryItemKey(item)) >= 0
          ? '✓' : '')
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
        color: this.cam.selectedCameraImageIds.indexOf(LumixImportPrototype.galleryItemKey(item)) >= 0
          ? '#316CF4' : 'rgba(255,255,255,0.96)',
      })
      .margin({ right: 6, bottom: 6 })
      .onClick(() => {
        this.onToggleSelect(LumixImportPrototype.galleryItemKey(item));
      })
    }
    .width('100%')
    .height(150)
    .padding(0)
    .backgroundColor('rgba(255,255,255,0.02)')
  }

  build() {
    Column() {
      if (this.cam.cameraGalleryItems.length > 0) {
        Text(`${this.visibleItems().length}${this.cam.cameraGalleryTotal > 0
          ? `/${this.cam.cameraGalleryTotal}` : ''} 张缩略图 · 已选 ${this.cam.selectedCameraImageIds.length} 张`)
          .fontSize(11)
          .fontColor(this.mutedTextColor)
          .margin({ top: 18, bottom: 10 })
        if (this.cardIds().length > 1) {
          this.CardSelector();
        }
        Grid() {
          ForEach(this.visibleItems(), (item: LumixGalleryItem) => {
            GridItem() {
              this.Thumbnail(item);
            }
          }, (item: LumixGalleryItem) =>
            // key 必须把缩略图状态算进去：`galleryItemKey` 只有 imageId:imageType，
            // 缩略图到达时它不变 → ArkUI 复用旧节点、不重跑 generator →
            // 缩略图永远渲染不出来（ImageTransferPage 顶部注释记着同一条规则）。
            `${LumixImportPrototype.galleryItemKey(item)}#${item.thumbnailUri.length > 0 ? 1 : 0}`)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(0)
        .rowsGap(0)
        .cachedCount(4)
        .width('100%')
        if (this.cam.cameraGalleryLoading) {
          LoadingProgress().width(24).height(24).color('#316CF4').margin({ top: 14 })
        } else if (this.cam.cameraGalleryHasMore) {
          Text('继续下滑加载相机照片').fontSize(10).fontColor(this.mutedTextColor).margin({ top: 14 })
        } else if (this.cam.cameraGalleryTotal > 0) {
          Text('已加载相机中的全部照片').fontSize(10).fontColor(this.mutedTextColor).margin({ top: 14 })
        }
      }
    }
    .width('100%')
  }
}
