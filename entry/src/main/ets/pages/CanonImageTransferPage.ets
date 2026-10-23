/**
 * Canon 图片传输页（EOS PTP/IP）。
 *
 * 契约：`docs/canon-route-design.md` §0/§1/§5/§7.2；
 * 行为依据：`documents/Canon/report/03-图片传输-SD卡列表与下载.md`
 *   §2.1 枚举卷（EdsGetVolumeInfo）→ 以「卷」为单位展示存储卡
 *   §2.2 卷根递归目录树（文件入列，全量无分页）
 *   §2.3 条目字段（ObjectHandle / mFileName / mSize / mDateTime / mFormat）
 *   §3   多卡：SD 与 CFexpress 靠卷列表区分，条目字段不可反推卡
 *   §5   缩略图逐张串行、本地缓存（页面只读 thumbUri）
 *   §6   原图下载按勾选逐张；取消 = CancelTransfer
 *
 * 页面只做展示与节流，所有 PTP 事务在 `CanonImportService`（§5 的接口）：
 *   open() → 枚举卷 → 读当前卷目录树 → 缩略图缓存补齐 → 勾选下载。
 *
 * 三条硬约束（评审逐条检查）：
 *   1. **存储卡按钮数量 = snapshot().volumes.length**，单卡也画一个；空卡置灰
 *      但仍显示，点击提示「该卡没有照片」。绝不从 items 数量反推卡数。
 *   2. 切卡先本地清空列表 + 置 loading（服务同时 revision++），再调
 *      selectVolume(storageId)；当前卡高亮。
 *   3. 不做任何排序/倒序：相机顺序即 UI 顺序（§2.3「客户端排序」在佳能页不启用）。
 *
 * ArkTS：类型全部显式（无动态类型字段、无非空断言、所有方法带返回类型、
 * 对象字面量均有类型）。
 */

import { common } from '@kit.AbilityKit';
import { CameraSessionStore } from '../services/CameraSessionStore';
import { AppLogSink } from '../services/AppLogSink';
import {
  CanonGalleryItem,
  CanonImportService,
  CanonImportSnapshot,
  CanonVolume,
} from '../services/CanonImportService';
import { AppLogStore } from './home/HomeShared';

const CANON_BRAND: string = 'Canon';
/** 与 FujifilmImageTransferPage 一致：250 ms 比较 service.revision 再同步快照。 */
const SYNC_INTERVAL_MS: number = 250;

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 拍摄时间：CanonGalleryItem.dateMs 是毫秒时间戳（§5），0 表示相机未给。 */
function canonDateText(ms: number): string {
  if (ms <= 0) return '';
  const date: Date = new Date(ms);
  return `${date.getFullYear()}/${pad2(date.getMonth() + 1)}/${pad2(date.getDate())}` +
    ` ${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

function canonSizeText(bytes: number): string {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

/** `IMG_1234.CR3` → `CR3`；取不到时返回空串（占位块会退回 IMG/VIDEO）。 */
function extensionOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  if (dot < 0 || dot >= name.length - 1) return '';
  const ext: string = name.substring(dot + 1);
  if (ext.length === 0 || ext.length > 5) return '';
  return ext.toUpperCase();
}

@Entry
@Component
struct CanonImageTransferPage {
  private service: CanonImportService | null = null;
  private syncTimer: number = -1;
  private lastRevision: number = -1;
  private previewPinchStart: number = 1;
  private lastLoggedError: string = '';
  /** 上一次同步到的卷；变化即代表服务已切卡，本地勾选镜像随之清空。 */
  private selectionStorageId: number = 0;

  @State private brand: string = '';
  @State private model: string = '';
  @State private phase: string = 'idle';
  @State private message: string = '正在准备…';
  @State private error: string = '';
  @State private volumes: CanonVolume[] = [];
  @State private activeStorageId: number = 0;
  @State private items: CanonGalleryItem[] = [];
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
  /**
   * 勾选状态的本地镜像。§5 的 `CanonGalleryItem` 只给元数据、没有 selected 字段
   * （服务用 selectedCount 汇总），所以角标/全选标签按 imageId 在页面侧维护；
   * 每次快照同步仍以服务的 selectedCount 为准回填计数。
   */
  @State private selectedIds: string[] = [];
  /** 已确认「卷存在但没有条目」的 storageId。只用于按钮置灰，不参与卡数推断。 */
  @State private emptyStorageIds: number[] = [];

  aboutToAppear(): void {
    const store: CameraSessionStore = CameraSessionStore.instance;
    this.brand = store.cameraBrand;
    this.model = store.cameraModel.length > 0 ? store.cameraModel : CANON_BRAND;

    if (this.brand !== CANON_BRAND) {
      this.phase = 'mismatch';
      this.message = '当前会话不是 Canon 相机';
      this.loading = false;
      AppLogSink.emit('CANON_IMG', `图传页拒绝进入：brand=${this.brand}（要求 Canon）`);
      return;
    }

    AppLogStore.add(`[CANON] 进入图片传输页 model=${this.model}`);
    AppLogSink.emit('CANON_IMG', `进入图片传输页 model=${this.model}`);

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.service = new CanonImportService(context);
    void this.service.open();
    this.syncTimer = setInterval(() => {
      this.syncNow();
    }, SYNC_INTERVAL_MS);
  }

  aboutToDisappear(): void {
    if (this.syncTimer >= 0) {
      clearInterval(this.syncTimer);
      this.syncTimer = -1;
    }
    const service = this.service;
    this.service = null;
    if (service !== null) service.dispose();
    AppLogSink.emit('CANON_IMG', '离开图片传输页，已 dispose');
  }

  /** 预览打开先关；下载中先取消；其余交给默认返回。 */
  onBackPress(): boolean {
    if (this.previewVisible) {
      this.closePreview();
      return true;
    }
    if (this.downloadInProgress) {
      const service = this.service;
      if (service !== null) service.cancelDownload();
      this.toast('正在取消下载，请稍候');
      return true;
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // 快照同步
  // -------------------------------------------------------------------------

  private syncNow(): void {
    const service = this.service;
    if (service === null) return;
    if (service.revision === this.lastRevision) return;
    this.lastRevision = service.revision;
    const snapshot: CanonImportSnapshot = service.snapshot();
    this.applySnapshot(snapshot);
  }

  private applySnapshot(snapshot: CanonImportSnapshot): void {
    const wasDownloading: boolean = this.downloadInProgress;
    this.phase = snapshot.phase;
    if (snapshot.model.length > 0) this.model = snapshot.model;
    this.message = snapshot.message;
    this.error = snapshot.error;
    this.volumes = snapshot.volumes;
    this.activeStorageId = snapshot.activeStorageId;
    this.items = snapshot.items;
    this.total = snapshot.total;
    this.selectedCount = snapshot.selectedCount;
    this.loading = snapshot.loading;
    this.downloadInProgress = snapshot.downloadInProgress;
    this.downloadProgress = snapshot.downloadProgress;
    this.downloadStatus = snapshot.downloadStatus;
    this.downloadCurrent = snapshot.downloadCurrent;
    this.downloadTotal = snapshot.downloadTotal;
    this.reconcileSelection(snapshot);
    this.reconcileEmptiness(snapshot);

    // 下载刚结束（完成或取消）：把服务给的结论复述一次，用户不必回想。
    if (wasDownloading && !snapshot.downloadInProgress && snapshot.downloadStatus.length > 0) {
      this.toast(snapshot.downloadStatus);
    }

    if (snapshot.error.length > 0 && snapshot.error !== this.lastLoggedError) {
      this.lastLoggedError = snapshot.error;
      AppLogSink.emit('CANON_IMG', `图传异常 phase=${snapshot.phase} error=${snapshot.error}`);
    }
  }

  /** 服务切卡会清空选择（§5 多卡句柄空间独立），本地镜像跟随，避免勾选残留。 */
  private reconcileSelection(snapshot: CanonImportSnapshot): void {
    if (snapshot.activeStorageId !== this.selectionStorageId) {
      this.selectionStorageId = snapshot.activeStorageId;
      this.selectedIds = [];
    }
  }

  /**
   * 空卡判定：只在「当前卷读完了且确实 0 条」或「此前访问过该卷且 0 条」时成立。
   * 绝不因为某个卷没出现在 items 里就当成不存在——卷列表只认 snapshot.volumes。
   */
  private reconcileEmptiness(snapshot: CanonImportSnapshot): void {
    if (snapshot.loading) return;
    if (snapshot.error.length > 0) return;
    if (snapshot.activeStorageId <= 0) return;
    this.markVolumeEmpty(snapshot.activeStorageId, snapshot.items.length === 0);
  }

  private markVolumeEmpty(storageId: number, empty: boolean): void {
    const index: number = this.emptyStorageIds.indexOf(storageId);
    if (empty) {
      if (index >= 0) return;
      const next: number[] = this.emptyStorageIds.slice();
      next.push(storageId);
      this.emptyStorageIds = next;
      return;
    }
    if (index < 0) return;
    const next: number[] = this.emptyStorageIds.slice();
    next.splice(index, 1);
    this.emptyStorageIds = next;
  }

  private isVolumeEmpty(storageId: number): boolean {
    if (storageId === this.activeStorageId) {
      return !this.loading && this.error.length === 0 && this.items.length === 0;
    }
    return this.emptyStorageIds.indexOf(storageId) >= 0;
  }

  // -------------------------------------------------------------------------
  // 存储卡
  // -------------------------------------------------------------------------

  private volumeLabel(volume: CanonVolume): string {
    if (volume.label.length > 0) return volume.label;
    return `卡 ${volume.sequence}`;
  }

  private volumeDetail(volume: CanonVolume): string {
    if (volume.storageId === this.activeStorageId && this.loading) return '读取中…';
    if (this.isVolumeEmpty(volume.storageId)) return '无照片';
    if (volume.storageId === this.activeStorageId) return `${this.items.length} 项`;
    if (volume.access === 0) return '只读';
    return `剩余 ${canonSizeText(volume.freeBytes)}`;
  }

  /** 空卡与当前卡同时成立时用灰蓝实心块：既表明「当前」，也表明「无照片」。 */
  private volumeButtonBg(volume: CanonVolume): string {
    const empty: boolean = this.isVolumeEmpty(volume.storageId);
    if (volume.storageId === this.activeStorageId) {
      return empty ? '#98A2B3' : '#316CF4';
    }
    return empty ? 'rgba(120,140,170,0.12)' : 'rgba(49,108,244,0.10)';
  }

  private volumeLabelColor(volume: CanonVolume): string {
    if (volume.storageId === this.activeStorageId) return '#FFFFFF';
    return this.isVolumeEmpty(volume.storageId) ? '#8A95A5' : '#316CF4';
  }

  private volumeDetailColor(volume: CanonVolume): string {
    return volume.storageId === this.activeStorageId
      ? 'rgba(255,255,255,0.82)' : '#8A95A5';
  }

  private activeVolume(): CanonVolume | null {
    for (const volume of this.volumes) {
      if (volume.storageId === this.activeStorageId) return volume;
    }
    return null;
  }

  private activeVolumeLabel(): string {
    const volume: CanonVolume | null = this.activeVolume();
    return volume === null ? '—' : this.volumeLabel(volume);
  }

  private activeVolumeSummary(): string {
    const volume: CanonVolume | null = this.activeVolume();
    if (volume === null) return '尚未读到存储卡信息';
    const access: string = volume.access === 0 ? '只读' : '可读写';
    return `${access} · 剩余 ${canonSizeText(volume.freeBytes)}` +
      ` / 共 ${canonSizeText(volume.capacityBytes)}`;
  }

  /**
   * 点击存储卡。空卡不切（只提示），因为服务会清空列表再枚举，若卡内 0 条
   * 用户只会看到空列表，不如直接说明「该卡没有照片」。
   */
  private onVolumeTap(volume: CanonVolume): void {
    if (this.downloadInProgress) {
      this.toast('下载中，请先取消下载');
      return;
    }
    if (this.isVolumeEmpty(volume.storageId)) {
      this.toast('该卡没有照片');
      return;
    }
    if (volume.storageId === this.activeStorageId) {
      return;
    }
    const service = this.service;
    if (service === null) return;

    AppLogSink.emit('CANON_IMG',
      `切卡 storageId=${volume.storageId} label=${this.volumeLabel(volume)}`);
    // 先本地清空并进入 loading（服务会 revision++），避免旧卡缩略图残留在新卡上。
    this.activeStorageId = volume.storageId;
    this.items = [];
    this.total = 0;
    this.selectedIds = [];
    this.selectedCount = 0;
    this.loading = true;
    this.error = '';
    this.message = `正在读取 ${this.volumeLabel(volume)}…`;
    void service.selectVolume(volume.storageId);
  }

  /** 刷新：卡可能被拔插，清掉「已知空卡」缓存后重新枚举当前卷。 */
  private refreshGallery(): void {
    if (this.downloadInProgress) {
      this.toast('下载中，请先取消下载');
      return;
    }
    const service = this.service;
    if (service === null) return;
    this.emptyStorageIds = [];
    this.items = [];
    this.total = 0;
    this.selectedIds = [];
    this.selectedCount = 0;
    this.loading = true;
    this.error = '';
    this.message = '正在重新读取相机存储卡…';
    void service.refresh();
  }

  // -------------------------------------------------------------------------
  // 勾选 / 下载 / 预览
  // -------------------------------------------------------------------------

  private isAllSelected(): boolean {
    return this.items.length > 0 && this.selectedCount >= this.items.length;
  }

  private onToggleItem(item: CanonGalleryItem): void {
    if (this.downloadInProgress) {
      this.toast('下载中，请先取消下载');
      return;
    }
    const service = this.service;
    if (service === null) return;
    service.toggle(item.imageId);
    const index: number = this.selectedIds.indexOf(item.imageId);
    const next: string[] = this.selectedIds.slice();
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(item.imageId);
    }
    this.selectedIds = next;
    this.selectedCount = next.length;
    this.syncNow();
  }

  private onToggleAll(): void {
    if (this.downloadInProgress) {
      this.toast('下载中，请先取消下载');
      return;
    }
    const service = this.service;
    if (service === null) return;
    const selectAll: boolean = !this.isAllSelected();
    service.selectAll(selectAll);
    if (selectAll) {
      const ids: string[] = [];
      for (const item of this.items) ids.push(item.imageId);
      this.selectedIds = ids;
      this.selectedCount = ids.length;
    } else {
      this.selectedIds = [];
      this.selectedCount = 0;
    }
    this.syncNow();
  }

  private startDownload(): void {
    if (this.downloadInProgress) return;
    const service = this.service;
    if (service === null) return;
    if (this.selectedCount <= 0) {
      this.toast('请先勾选要下载的照片');
      return;
    }
    AppLogStore.add(`[CANON] 开始下载 ${this.selectedCount} 张 · 卡 ${this.activeVolumeLabel()}`);
    void service.downloadSelected();
  }

  private cancelDownload(): void {
    const service = this.service;
    if (service === null) return;
    service.cancelDownload();
    this.toast('正在取消下载…');
  }

  private openPreview(item: CanonGalleryItem): void {
    if (this.downloadInProgress) {
      this.toast('下载中，请稍后再预览');
      return;
    }
    const service = this.service;
    let uri: string = '';
    if (service !== null) uri = service.previewUriOf(item.imageId);
    if (uri.length === 0) uri = item.thumbUri;
    if (uri.length === 0) {
      this.toast('预览还在准备，请稍后再试');
      return;
    }
    this.previewName = item.name;
    this.previewUri = uri;
    this.previewScale = 1;
    this.previewVisible = true;
    AppLogSink.emit('CANON_IMG',
      `预览 name=${item.name} raw=${item.isRaw ? 1 : 0} video=${item.isVideo ? 1 : 0}`);
  }

  private closePreview(): void {
    this.previewVisible = false;
    this.previewScale = 1;
    this.previewUri = '';
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private goBack(): void {
    if (this.downloadInProgress) {
      this.toast('下载中，请先取消下载');
      return;
    }
    this.getUIContext().getRouter().back();
  }

  // -------------------------------------------------------------------------
  // 视图状态文案
  // -------------------------------------------------------------------------

  private phaseText(): string {
    if (this.brand !== CANON_BRAND) return '品牌不符';
    if (this.phase === 'error' || this.error.length > 0) return '异常';
    if (this.downloadInProgress) return '下载中';
    if (this.loading) return '读取中';
    if (this.selectedCount > 0) return `已选 ${this.selectedCount}`;
    if (this.items.length > 0) return '已连接';
    return '待读取';
  }

  private emptyTitle(): string {
    if (this.volumes.length > 1) return `${this.activeVolumeLabel()} 没有照片`;
    if (this.volumes.length === 1) return '相机存储卡里还没有照片';
    return '相机图库为空';
  }

  private emptyHint(): string {
    if (this.volumes.length > 1) {
      return '换一张卡试试：点上方其他存储卡，列表会清空并重新读取。';
    }
    return '请确认相机已插卡，且卡内有照片；插拔卡后可点「刷新」重新读取。';
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
            if (this.brand !== CANON_BRAND) {
              this.MismatchCard()
            } else {
              this.StatusCard()
              this.VolumeCard()
              if (this.error.length > 0) {
                this.ErrorCard()
              } else if (this.loading) {
                this.LoadingCard()
              } else if (this.items.length === 0) {
                this.EmptyCard()
              } else {
                this.GalleryCard()
              }
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 18 });
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        if (this.brand === CANON_BRAND && this.items.length > 0 && this.error.length === 0) {
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
        .fontColor(this.phase === 'error' || this.error.length > 0 || this.brand !== CANON_BRAND
          ? '#C8443A' : '#316CF4')
        .padding({ left: 9, right: 9, top: 4, bottom: 4 })
        .borderRadius(10)
        .backgroundColor(this.phase === 'error' || this.error.length > 0 ||
          this.brand !== CANON_BRAND
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
        Text(this.volumes.length > 1 ? `多卡 · ${this.volumes.length} 卷` :
          (this.volumes.length === 1 ? '单卡 · 1 卷' : '等待卷信息'))
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
        Text(`卡 ${this.activeVolumeLabel()}`)
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

      Text(this.activeVolumeSummary())
        .fontSize(9)
        .fontColor('#8A95A5')
        .width('100%')
        .margin({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.78)')
    .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
    .margin({ top: 6 });
  }

  /**
   * 存储卡切换卡。
   * 按钮逐个对应 `snapshot.volumes`（GetStorageIDs 顺序，§5/§7.2）：
   * 单卡也有一个按钮；空卡置灰但保留，点击提示「该卡没有照片」。
   * 注意：这里**没有**任何 `items.length` 参与卡数计算。
   */
  @Builder
  VolumeCard() {
    Column() {
      Row() {
        Column() {
          Text('存储卡')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1B2536');
          Text('切卡会清空列表并重新枚举目录树')
            .fontSize(9)
            .fontColor('#66758B')
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Text('刷新')
          .fontSize(10)
          .fontColor('#316CF4')
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor('rgba(49,108,244,0.10)')
          .onClick(() => {
            this.refreshGallery();
          });
      }
      .width('100%');

      if (this.volumes.length === 0) {
        Text('尚未读到存储卡信息')
          .fontSize(10)
          .fontColor('#8A95A5')
          .width('100%')
          .margin({ top: 10 });
      } else {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.volumes, (volume: CanonVolume) => {
            Button() {
              Column() {
                Text(this.volumeLabel(volume))
                  .fontSize(11)
                  .fontWeight(volume.storageId === this.activeStorageId
                    ? FontWeight.Bold : FontWeight.Medium)
                  .fontColor(this.volumeLabelColor(volume))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(this.volumeDetail(volume))
                  .fontSize(7)
                  .fontColor(this.volumeDetailColor(volume))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 1 });
              }
              .alignItems(HorizontalAlign.Start);
            }
            .height(46)
            .constraintSize({ minWidth: 96 })
            .padding({ left: 12, right: 12 })
            .margin({ right: 8, top: 10 })
            .borderRadius(12)
            .backgroundColor(this.volumeButtonBg(volume))
            .opacity(this.isVolumeEmpty(volume.storageId) ? 0.7 : 1)
            .onClick(() => {
              this.onVolumeTap(volume);
            });
          }, (volume: CanonVolume) =>
          `${volume.storageId}_${volume.sequence}_${volume.label}` +
            `_${this.activeStorageId === volume.storageId ? 1 : 0}` +
            `_${this.isVolumeEmpty(volume.storageId) ? 1 : 0}` +
            `_${this.loading ? 1 : 0}_${this.items.length}`);
        }
        .width('100%');
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
  MismatchCard() {
    Column() {
      Text('相机品牌不匹配')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#C8443A');
      Text(`本页只处理 Canon 会话，当前会话品牌为「${this.brand}」。请从佳能相机连接页进入。`)
        .fontSize(11)
        .fontColor('#66758B')
        .lineHeight(18)
        .margin({ top: 8 });
      Button('返回')
        .height(36)
        .fontSize(12)
        .fontColor('#FFFFFF')
        .backgroundColor('#316CF4')
        .margin({ top: 14 })
        .onClick(() => {
          this.getUIContext().getRouter().back();
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
          this.refreshGallery();
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
      Text('正在枚举卷内目录树（DCIM/xxxCANON），大容量卡请稍候')
        .fontSize(9)
        .fontColor('#8A95A5')
        .margin({ top: 4 })
        .textAlign(TextAlign.Center);
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
      Text(this.emptyHint())
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
          Text(`相机顺序 · 最新在前 · 不排序 · 卡 ${this.activeVolumeLabel()}`)
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
        ForEach(this.items, (item: CanonGalleryItem) => {
          GridItem() {
            CanonTransferTile({
              name: item.name,
              thumbUri: item.thumbUri,
              isVideo: item.isVideo,
              isRaw: item.isRaw,
              selected: this.selectedIds.indexOf(item.imageId) >= 0,
              dateText: canonDateText(item.dateMs),
              sizeText: canonSizeText(item.size),
              onOpen: (): void => {
                this.openPreview(item);
              },
              onToggle: (): void => {
                this.onToggleItem(item);
              },
            })
          }
        }, (item: CanonGalleryItem) =>
        `${item.imageId}#${item.thumbUri.length > 0 ? 1 : 0}` +
          `#${this.selectedIds.indexOf(item.imageId) >= 0 ? 1 : 0}`)
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .width('100%')
      // 缩略图由服务串行生成后缓存到 filesDir/canon_thumb（§5），页面只渲染
      // 可见窗口内的格子，滚动时才构建新的 Image —— 这就是缩略图懒加载。
      .cachedCount(4);
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
      Column() {
        Text(`已选 ${this.selectedCount} / ${this.total}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.selectedCount > 0 ? '#316CF4' : '#66758B');
        Text(this.downloadInProgress ? '下载中…' : '原图保存到相册')
          .fontSize(8)
          .fontColor('#8A95A5')
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      Button(this.isAllSelected() ? '取消全选' : '全选')
        .height(38)
        .fontSize(11)
        .fontColor(this.downloadInProgress ? '#8A95A5' : '#316CF4')
        .backgroundColor('rgba(49,108,244,0.10)')
        .enabled(!this.downloadInProgress)
        .onClick(() => {
          this.onToggleAll();
        });

      Button(this.selectedCount > 0 ? `下载 ${this.selectedCount}` : '下载')
        .height(38)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .backgroundColor(this.selectedCount > 0 && !this.downloadInProgress
          ? '#316CF4' : '#B9C2D0')
        .enabled(this.selectedCount > 0 && !this.downloadInProgress)
        .margin({ left: 8 })
        .onClick(() => {
          this.startDownload();
        });
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor('rgba(255,255,255,0.94)');
  }

  @Builder
  DownloadOverlay() {
    Column() {
      Text('正在下载原图')
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
        Text(`${Math.round(this.downloadProgress)}%`)
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
          this.cancelDownload();
        });
    }
    .width(300)
    .padding(22)
    .borderRadius(18)
    .backgroundColor('#FFFFFF')
    .shadow({ radius: 24, color: 'rgba(15,22,35,0.22)', offsetX: 0, offsetY: 10 })
    .zIndex(120);
  }

  /** 预览：点击空白或返回关闭；双指缩放 1–4 倍。 */
  @Builder
  PreviewOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(15,22,35,0.90)')
        .onClick(() => {
          this.closePreview();
        });

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
              this.closePreview();
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
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.previewPinchStart = this.previewScale;
              })
              .onActionUpdate((event: GestureEvent) => {
                const next: number = this.previewPinchStart * event.scale;
                this.previewScale = Math.max(1, Math.min(4, next));
              })
          )
          .onClick(() => {
            // 吞掉图片区域的点击，只有点空白（底层遮罩）才关闭。
          });

        Text('缩略图 / 已下载原图 · 双指缩放 · 点击空白或返回关闭')
          .fontSize(10)
          .fontColor('rgba(255,255,255,0.62)')
          .margin({ top: 6 });
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center);
    }
    .width('100%')
    .height('100%')
    .zIndex(130)
    .hitTestBehavior(HitTestMode.Block);
  }
}

/**
 * 单张缩略图格子。只接收原始值：选中/缩略图 URI 变化时由父页面通过 key 重建，
 * 子组件不持有服务引用。
 */
@Component
struct CanonTransferTile {
  @Prop name: string = '';
  @Prop thumbUri: string = '';
  @Prop isVideo: boolean = false;
  @Prop isRaw: boolean = false;
  @Prop selected: boolean = false;
  @Prop dateText: string = '';
  @Prop sizeText: string = '';
  onOpen: () => void = () => {
  };
  onToggle: () => void = () => {
  };

  private placeholderLabel(): string {
    const ext: string = extensionOf(this.name);
    if (ext.length > 0) return ext;
    return this.isVideo ? 'VIDEO' : 'IMG';
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.thumbUri.length > 0) {
          Image(this.thumbUri)
            .width('100%')
            .aspectRatio(1.5)
            .objectFit(ImageFit.Cover)
            .interpolation(ImageInterpolation.High);
        } else {
          // 相机还没送出缩略图（服务串行 getThumb 中）：用扩展名占位块撑住 3:2，
          // 保证网格不跳版，点击仍可尝试预览。
          Column() {
            Text(this.placeholderLabel())
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#8A95A5');
            Text('缩略图')
              .fontSize(8)
              .fontColor('#A9B3C1')
              .margin({ top: 3 });
          }
          .width('100%')
          .aspectRatio(1.5)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#E8EDF6');
        }

        Row() {
          if (this.isVideo) {
            Text('视频')
              .fontSize(8)
              .fontColor('#FFFFFF')
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor('rgba(15,22,35,0.72)')
              .margin({ right: 4 });
          }
          if (this.isRaw) {
            Text('RAW')
              .fontSize(8)
              .fontColor('#FFFFFF')
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor('rgba(158,106,32,0.88)');
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
    });
  }
}
