/**
 * FUJIFILM 图片传输页（角色 C）。
 *
 * 布局对齐松下 LAB 图片传输页：顶部返回 / 相机名 / 状态，下面是存储卡选择、
 * 相机图库网格、底部“全选 + 下载”，再加下载进度与缩略图预览。
 *
 * 页面只做展示和节流，所有 PTP 事务在 FujifilmImportService：
 *   建链 → event 11 → SetFunctionMode(20) → 版本协商 → 双槽状态
 *   → 当前槽枚举 → 缩略图窗口 → 勾选下载（相册 / 应用目录）。
 *
 * 关键需求：
 *   - 卡槽按钮数量来自相机上报（1–4 双槽，5–7 三槽；status 0 按机型兜底），
 *     空卡置灰但仍显示，不能从条目数量反推卡数；
 *   - 切槽先清空列表并进入加载态，再重新枚举；
 *   - 不做任何排序 / 倒序：按相机返回顺序（最新在前，handles[0]）。
 */

import { common } from '@kit.AbilityKit';
import { CameraSessionStore } from '../services/CameraSessionStore';
import {
  FujifilmGalleryItem,
  FujifilmImportService,
  FujifilmSlotView,
  FujifilmTransferSnapshot,
} from '../services/FujifilmImportService';
import { AppLogStore } from './home/HomeShared';

@Entry
@Component
struct FujifilmImageTransferPage {
  private service: FujifilmImportService | null = null;
  private syncTimer: number = -1;
  private lastRevision: number = -1;
  private previewPinchStart: number = 1;

  @State private brand: string = '';
  @State private model: string = '';
  @State private phase: string = 'idle';
  @State private message: string = '正在准备…';
  @State private error: string = '';
  @State private items: FujifilmGalleryItem[] = [];
  @State private slots: FujifilmSlotView[] = [];
  @State private activeSlot: number = 0;
  @State private slotControlSupported: boolean = false;
  @State private total: number = 0;
  @State private selectedCount: number = 0;
  @State private loading: boolean = true;
  @State private downloadInProgress: boolean = false;
  @State private downloadProgress: number = 0;
  @State private downloadStatus: string = '';
  @State private downloadCurrent: number = 0;
  @State private downloadTotal: number = 0;
  @State private previewVisible: boolean = false;
  @State private previewUri: string = '';
  @State private previewName: string = '';
  @State private previewScale: number = 1;

  aboutToAppear(): void {
    const store = CameraSessionStore.instance;
    this.brand = store.cameraBrand;
    this.model = store.cameraModel;
    if (this.model.length === 0) this.model = 'FUJIFILM';
    AppLogStore.add(`[FUJI] 进入图片传输页 model=${this.model} brand=${this.brand}`);

    if (this.brand !== 'FUJIFILM') {
      this.phase = 'error';
      this.error = '当前会话不是 FUJIFILM 相机，无法读取图片';
      this.message = this.error;
      return;
    }

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.service = new FujifilmImportService(context);
    void this.service.open();
    this.syncTimer = setInterval(() => {
      this.syncNow();
    }, 250);
  }

  aboutToDisappear(): void {
    if (this.syncTimer >= 0) {
      clearInterval(this.syncTimer);
      this.syncTimer = -1;
    }
    const service = this.service;
    this.service = null;
    if (service !== null) service.dispose();
  }

  /** 下载中返回先取消；预览打开时先关预览。 */
  onBackPress(): boolean {
    if (this.previewVisible) {
      this.previewVisible = false;
      return true;
    }
    if (this.downloadInProgress) {
      if (this.service !== null) this.service.cancelDownload();
      this.toast('正在取消下载，请稍候');
      return true;
    }
    return false;
  }

  private syncNow(): void {
    const service = this.service;
    if (service === null) return;
    if (service.revision === this.lastRevision) return;
    this.lastRevision = service.revision;
    const snapshot: FujifilmTransferSnapshot = service.snapshot();
    this.phase = snapshot.phase;
    this.model = snapshot.model;
    this.message = snapshot.message;
    this.error = snapshot.error;
    this.items = snapshot.items;
    this.slots = snapshot.slots;
    this.activeSlot = snapshot.activeSlot;
    this.slotControlSupported = snapshot.slotControlSupported;
    this.total = snapshot.total;
    this.selectedCount = snapshot.selectedCount;
    this.loading = snapshot.loading;
    this.downloadInProgress = snapshot.downloadInProgress;
    this.downloadProgress = snapshot.downloadProgress;
    this.downloadStatus = snapshot.downloadStatus;
    this.downloadCurrent = snapshot.downloadCurrent;
    this.downloadTotal = snapshot.downloadTotal;
  }

  private phaseText(): string {
    if (this.phase === 'idle') return '准备中';
    if (this.phase === 'connecting') return '连接中';
    if (this.phase === 'mode') return '切模式';
    if (this.phase === 'slots') return '读卡槽';
    if (this.phase === 'enumerating') return '读图库';
    if (this.phase === 'downloading') return '下载中';
    if (this.phase === 'error') return '异常';
    if (this.selectedCount > 0) return `已选 ${this.selectedCount}`;
    return '已连接';
  }

  private slotName(): string {
    return this.activeSlot > 0 ? `SD${this.activeSlot}` : '—';
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private goBack(): void {
    if (this.downloadInProgress) {
      this.toast('下载中，请先取消');
      return;
    }
    this.getUIContext().getRouter().back();
  }

  private isAllSelected(): boolean {
    return this.items.length > 0 && this.selectedCount === this.items.length;
  }

  private emptyTitle(): string {
    if (this.activeSlot > 0) return `${this.slotName()} 没有照片`;
    if (this.slots.length > 0) return '未检测到存储卡';
    return '相机图库为空';
  }

  private openPreview(item: FujifilmGalleryItem): void {
    if (item.thumbUri.length === 0) {
      this.toast('缩略图还在加载');
      return;
    }
    this.previewName = item.name;
    this.previewUri = item.thumbUri;
    this.previewScale = 1;
    this.previewVisible = true;
  }

  // -------------------------------------------------------------------------
  // 页面
  // -------------------------------------------------------------------------

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.Header()
        Scroll() {
          Column() {
            this.StatusCard()
            this.SlotCard()
            if (this.brand !== 'FUJIFILM') {
              this.MismatchCard()
            } else if (this.error.length > 0) {
              this.ErrorCard()
            } else if (this.loading) {
              this.LoadingCard()
            } else if (this.items.length === 0) {
              this.EmptyCard()
            } else {
              this.GalleryCard()
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 18 });
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        if (this.items.length > 0 && this.error.length === 0) {
          this.BottomBar()
        }
      }
      .width('100%')
      .height('100%')
      .safeAreaPadding({ top: 24 })

      if (this.downloadInProgress) this.DownloadOverlay()
      if (this.previewVisible) this.PreviewOverlay()
    }
    .width('100%')
    .height('100%')
    .linearGradient({ angle: 160, colors: [['#F3F6FC', 0], ['#E9EFF9', 1]] });
  }

  @Builder
  Header() {
    Row() {
      Text('‹')
        .fontSize(34)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1B2536')
        .width(44)
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.goBack();
        });
      Column() {
        Text('图片传输')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B2536');
        Text(this.model)
          .fontSize(10)
          .fontColor('#66758B')
          .margin({ top: 1 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
      Text(this.phaseText())
        .fontSize(10)
        .fontColor(this.phase === 'error' ? '#C8443A' : '#316CF4')
        .padding({ left: 9, right: 9, top: 4, bottom: 4 })
        .borderRadius(10)
        .backgroundColor(this.phase === 'error'
          ? 'rgba(200,68,58,0.10)' : 'rgba(49,108,244,0.10)');
    }
    .width('100%')
    .padding({ left: 10, right: 16, top: 8, bottom: 4 });
  }

  @Builder
  StatusCard() {
    Column() {
      Row() {
        Text(this.model)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B2536')
          .layoutWeight(1);
        Text(this.slotControlSupported
          ? (this.slots.length > 1 ? '双槽控制可用' : '单槽控制可用')
          : '标准存储枚举')
          .fontSize(9)
          .fontColor('#66758B');
      }
      .width('100%');

      Text(this.message)
        .fontSize(11)
        .fontColor('#4A5A72')
        .lineHeight(17)
        .width('100%')
        .margin({ top: 5 })
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis });

      Row() {
        Text(`卡槽 ${this.slotName()}`)
          .fontSize(10)
          .fontColor('#66758B')
          .layoutWeight(1);
        Text(`共 ${this.total} 项`)
          .fontSize(10)
          .fontColor('#66758B')
          .layoutWeight(1);
        Text(`已选 ${this.selectedCount}`)
          .fontSize(10)
          .fontColor(this.selectedCount > 0 ? '#316CF4' : '#66758B')
          .layoutWeight(1);
      }
      .width('100%')
      .margin({ top: 7 });
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.78)')
    .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
    .margin({ top: 6 });
  }

  /**
   * 卡槽按钮：数量 = 相机上报槽位。status 0 时按机型兜底，仍把空卡画出来；
   * 无卡的槽位置灰禁用，但绝不隐藏。
   */
  @Builder
  SlotCard() {
    Column() {
      Row() {
        Column() {
          Text('存储卡')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1B2536');
          Text('切槽会清空当前列表并重新读取')
            .fontSize(9)
            .fontColor('#66758B')
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        if (!this.slotControlSupported) {
          Text('只读')
            .fontSize(9)
            .fontColor('#8A95A5')
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .borderRadius(8)
            .backgroundColor('rgba(120,140,170,0.12)');
        }
      }
      .width('100%');

      if (this.slots.length === 0) {
        Text('尚未读到卡槽信息')
          .fontSize(10)
          .fontColor('#8A95A5')
          .width('100%')
          .margin({ top: 10 });
      } else {
        Row() {
          ForEach(this.slots, (slot: FujifilmSlotView) => {
            this.SlotButton(slot)
          }, (slot: FujifilmSlotView) =>
          `${slot.slot}_${slot.current ? 1 : 0}_${slot.available ? 1 : 0}_${slot.status}`);
        }
        .width('100%')
        .margin({ top: 10 });
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.78)')
    .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
    .margin({ top: 10 });
  }

  @Builder
  SlotButton(slot: FujifilmSlotView) {
    Button() {
      Column() {
        Text(slot.label)
          .fontSize(11)
          .fontWeight(slot.current ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(slot.current ? '#FFFFFF' : (slot.available ? '#316CF4' : '#8A95A5'));
        if (slot.detail.length > 0) {
          Text(slot.detail)
            .fontSize(7)
            .fontColor(slot.current ? 'rgba(255,255,255,0.82)' : '#8A95A5')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 1 });
        }
      }
    }
    .height(40)
    .padding({ left: 14, right: 14 })
    .margin({ right: 8 })
    .borderRadius(12)
    .backgroundColor(slot.current
      ? '#316CF4' : (slot.available ? 'rgba(49,108,244,0.10)' : 'rgba(120,140,170,0.12)'))
    .opacity(slot.available ? 1 : 0.55)
    .enabled(slot.available)
    .onClick(() => {
      const service = this.service;
      if (service !== null) void service.switchSlot(slot.slot);
    });
  }

  @Builder
  MismatchCard() {
    Column() {
      Text('相机品牌不匹配')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#C8443A');
      Text('本页只处理 FUJIFILM 会话。请从富士相机连接页进入。')
        .fontSize(11)
        .fontColor('#66758B')
        .lineHeight(18)
        .margin({ top: 8 });
    }
    .width('100%')
    .padding(18)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.8)')
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  ErrorCard() {
    Column() {
      Text('读取失败')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#C8443A');
      Text(this.error)
        .fontSize(11)
        .fontColor('#4A5A72')
        .lineHeight(18)
        .margin({ top: 8 });
      Button('重试')
        .height(34)
        .fontSize(12)
        .fontColor('#FFFFFF')
        .backgroundColor('#316CF4')
        .margin({ top: 14 })
        .onClick(() => {
          const service = this.service;
          if (service !== null) void service.resetAndRetry();
        });
    }
    .width('100%')
    .padding(18)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.8)')
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  LoadingCard() {
    Column() {
      LoadingProgress()
        .width(30)
        .height(30)
        .color('#316CF4');
      Text(this.message)
        .fontSize(11)
        .fontColor('#4A5A72')
        .margin({ top: 10 })
        .textAlign(TextAlign.Center);
      Text('首次读取会逐条拉取对象信息，请稍候')
        .fontSize(9)
        .fontColor('#8A95A5')
        .margin({ top: 4 });
    }
    .width('100%')
    .height(220)
    .justifyContent(FlexAlign.Center)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.72)')
    .margin({ top: 12 });
  }

  @Builder
  EmptyCard() {
    Column() {
      Text(this.emptyTitle())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#4A5A72');
      Text(this.slots.length > 1
        ? '换一张卡试试：点上方其他卡槽，列表会清空并重新读取。'
        : '请确认相机已插卡，且卡内有照片。')
        .fontSize(10)
        .fontColor('#8A95A5')
        .lineHeight(17)
        .margin({ top: 8 })
        .textAlign(TextAlign.Center);
    }
    .width('100%')
    .height(240)
    .justifyContent(FlexAlign.Center)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.72)')
    .margin({ top: 12 });
  }

  @Builder
  GalleryCard() {
    Column() {
      Row() {
        Column() {
          Text('相机图库')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1B2536');
          Text('相机顺序 · 最新在前 · 不排序')
            .fontSize(9)
            .fontColor('#66758B')
            .margin({ top: 3 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Text(`共 ${this.total} 项`)
          .fontSize(10)
          .fontColor('#316CF4')
          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor('rgba(49,108,244,0.10)');
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 10 });

      Grid() {
        ForEach(this.items, (item: FujifilmGalleryItem) => {
          GridItem() {
            FujifilmTransferTile({
              name: item.name,
              thumbUri: item.thumbUri,
              isVideo: item.isVideo,
              selected: item.selected,
              current: item.current,
              dateText: FujifilmImportService.prettyDate(item.captureDate),
              sizeText: FujifilmImportService.sizeText(item.size),
              onOpen: (): void => {
                this.openPreview(item);
              },
              onToggle: (): void => {
                const service = this.service;
                if (service !== null) service.toggleSelection(item.handle);
                this.syncNow();
              },
              onNeedThumb: (): void => {
                const service = this.service;
                if (service !== null) service.requestThumbnail(item.handle);
              },
            })
          }
        }, (item: FujifilmGalleryItem) =>
        `${item.handle}_${item.selected ? 1 : 0}_${item.current ? 1 : 0}_${item.thumbUri}`)
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .width('100%')
      .cachedCount(6);
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 14, bottom: 14 })
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.78)')
    .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
    .margin({ top: 12 });
  }

  @Builder
  BottomBar() {
    Row() {
      Button(this.isAllSelected() ? '取消全选' : '全选')
        .height(42)
        .layoutWeight(1)
        .fontSize(12)
        .fontColor(this.items.length > 0 ? '#316CF4' : '#8A95A5')
        .backgroundColor('rgba(49,108,244,0.10)')
        .enabled(this.items.length > 0)
        .onClick(() => {
          const service = this.service;
          if (service !== null) service.selectAll(!this.isAllSelected());
          this.syncNow();
        });
      Button(this.selectedCount > 0 ? `下载 ${this.selectedCount}` : '下载')
        .height(42)
        .layoutWeight(1)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .backgroundColor(this.selectedCount > 0 ? '#316CF4' : '#B9C2D0')
        .enabled(this.selectedCount > 0)
        .margin({ left: 10 })
        .onClick(() => {
          const service = this.service;
          if (service !== null) void service.downloadSelected();
        });
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor('rgba(255,255,255,0.94)');
  }

  @Builder
  DownloadOverlay() {
    Column() {
      Text('正在下载')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1B2536');
      Text(this.downloadStatus)
        .fontSize(10)
        .fontColor('#66758B')
        .lineHeight(16)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 8 })
        .textAlign(TextAlign.Center);
      Progress({ value: this.downloadProgress, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(6)
        .color('#316CF4')
        .margin({ top: 16 });
      Row() {
        Text(`${this.downloadProgress}%`)
          .fontSize(11)
          .fontColor('#316CF4')
          .layoutWeight(1);
        Text(`${this.downloadCurrent}/${this.downloadTotal}`)
          .fontSize(11)
          .fontColor('#66758B');
      }
      .width('100%')
      .margin({ top: 6 });
      Button('取消下载')
        .height(36)
        .fontSize(12)
        .fontColor('#334158')
        .backgroundColor('#E7EBF3')
        .margin({ top: 16 })
        .onClick(() => {
          const service = this.service;
          if (service !== null) service.cancelDownload();
        });
    }
    .width(300)
    .padding(22)
    .borderRadius(18)
    .backgroundColor('#FFFFFF')
    .shadow({ radius: 24, color: 'rgba(15,22,35,0.22)', offsetX: 0, offsetY: 10 })
    .zIndex(120);
  }

  @Builder
  PreviewOverlay() {
    Column() {
      Row() {
        Text(this.previewName)
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.78)')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text('关闭')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(12)
          .backgroundColor('rgba(255,255,255,0.16)')
          .onClick(() => {
            this.previewVisible = false;
          });
      }
      .width('92%')
      .margin({ top: 10 });
      Image(this.previewUri)
        .width('92%')
        .height('78%')
        .objectFit(ImageFit.Contain)
        .scale({ x: this.previewScale, y: this.previewScale })
        .gesture(
          PinchGesture()
            .onActionStart(() => {
              this.previewPinchStart = this.previewScale;
            })
            .onActionUpdate((event: GestureEvent) => {
              const next: number = this.previewPinchStart * event.scale;
              this.previewScale = Math.max(1, Math.min(4, next));
            })
        );
      Text('缩略图预览 · 双指缩放 · 全局返回关闭')
        .fontSize(10)
        .fontColor('rgba(255,255,255,0.62)')
        .margin({ top: 6 });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(15,22,35,0.90)')
    .zIndex(130);
  }
}

/**
 * 单张缩略图卡片。只接收原始值，选中/当前/URI 变化时由父页面重建；
 * 避免在子组件里持有服务引用。
 */
@Component
struct FujifilmTransferTile {
  @Prop name: string = '';
  @Prop thumbUri: string = '';
  @Prop isVideo: boolean = false;
  @Prop selected: boolean = false;
  @Prop current: boolean = false;
  @Prop dateText: string = '';
  @Prop sizeText: string = '';
  onOpen: () => void = () => {};
  onToggle: () => void = () => {};
  onNeedThumb: () => void = () => {};

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.thumbUri.length > 0) {
          Image(this.thumbUri)
            .width('100%')
            .aspectRatio(1.5)
            .objectFit(ImageFit.Cover);
        } else {
          Column() {
            LoadingProgress()
              .width(20)
              .height(20)
              .color('#8A95A5');
            Text('缩略图')
              .fontSize(8)
              .fontColor('#8A95A5')
              .margin({ top: 4 });
          }
          .width('100%')
          .aspectRatio(1.5)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#E8EDF6');
        }

        Row() {
          if (this.current) {
            Text('当前')
              .fontSize(8)
              .fontColor('#FFFFFF')
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor('rgba(30,142,90,0.92)')
              .margin({ right: 4 });
          }
          if (this.isVideo) {
            Text('视频')
              .fontSize(8)
              .fontColor('#FFFFFF')
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor('rgba(15,22,35,0.72)');
          }
          Blank();
          Button() {
            Text(this.selected ? '✓' : '')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF');
          }
          .width(26)
          .height(26)
          .borderRadius(13)
          .backgroundColor(this.selected ? '#316CF4' : 'rgba(15,22,35,0.36)')
          .border({ width: 1, color: '#FFFFFF' })
          .onClick(() => {
            this.onToggle();
          });
        }
        .width('100%')
        .padding(6)
        .alignItems(VerticalAlign.Top);
      }
      .width('100%')
      .clip(true)
      .borderRadius({ topLeft: 12, topRight: 12 });

      Column() {
        Text(this.name)
          .fontSize(9)
          .fontColor('#1B2536')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Row() {
          Text(this.dateText.length > 0 ? this.dateText : '—')
            .fontSize(7)
            .fontColor('#8A95A5')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(this.sizeText)
            .fontSize(7)
            .fontColor('#8A95A5');
        }
        .width('100%')
        .margin({ top: 2 });
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 7 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#FFFFFF');
    }
    .width('100%')
    .borderRadius(12)
    .border({ width: 1, color: this.selected ? '#316CF4' : 'rgba(203,213,228,0.55)' })
    .onClick(() => {
      this.onOpen();
    })
    .onAppear(() => {
      this.onNeedThumb();
    });
  }
}
