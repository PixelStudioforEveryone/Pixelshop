import { image } from '@kit.ImageKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { picker, fileIo, fileUri } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { taskpool, util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HuaweiAccountService } from '../../services/HuaweiAccountService';
import { PRESETS, Preset } from '../../edit/models/Presets';
import { CustomLut, LutLibraryStore, parseLutFile, parseLutText, parseLutMetadata, readLutText,
lutEffectCachePath, lutSampleBaseName, lutCacheToken, loadSampleOverrides, applySampleOverrides, lutDisplayUri,
loadCustomLuts as loadCustomLutsFromStore, saveCustomLuts, loadDeletedBundledLuts,
saveDeletedBundledLuts } from '../../edit/models/LutLibrary';
import { PixelMapUtils } from '../../edit/utils/PixelMapUtils';
import { processPixels, ProcessParams, ProcessResult, WorkerLut } from '../../edit/engine/ProcessWorker';
import { LutLoader } from '../../edit/utils/LutLoader';
import { GpuShaderBridge } from '../../edit/engine/GpuShaderBridge';
import { VividMaterial } from '../../components/VividMaterial';
import { AppLogStore, NavColorService, LutBridge, knockPackageField } from './HomeShared';
import { OfficialLutPanel } from './OfficialLutPanel';
import { NikonCloudLocalPanel } from './NikonCloudLocalPanel';
import { LutMarketPanel } from './LutMarketPanel';
import { NikonCloudPanel } from './NikonCloudPanel';

// 用户 LUT 云存储接口（与 ProfileSection 一致，按华为账号 openID 隔离）。
const LUT_API_BASE: string = 'https://your-server.example.com/api/luts';
const LUT_UPLOAD_TOKEN: string = 'vivid-log-Kq7fXm2Rt9Lw4Zb8';

/** 云端预览载荷：≤1080P 预览图 + ≤256px 缩略图（弹层加速用）。 */
class CloudPreviewPayload {
  previewBase64: string = '';
  thumbBase64: string = '';
}

/** POST /api/luts?share=1 响应：服务器签发的分享码（LUT 唯一标志符）。 */
interface CloudShareResult {
  code?: string;
}

/** GET /api/luts 响应条目（上传前重复校验/配额预检用）。 */
interface CloudLutListItem {
  name?: string;
  shareCode?: string;
}

/** GET /api/luts 响应根对象。 */
interface CloudLutList {
  luts?: CloudLutListItem[];
}

/** 首页「调色」页：预设与自定义 LUT 管理、卡片预览和碰一碰导入。 */
@Component
export struct LutPage {
  @State private selectedPreset: string = '';
  @State private selectedLutCategory: string = '全部';
  @State private lutTab: string = 'official';
  /** 「粘贴好友的 LUT」底部弹层（原 LUT 市场功能，现属本机 LUT 页）。 */
  @State private showPasteSheet: boolean = false;
  @State private customLuts: CustomLut[] = [];
  @State private bundledLuts: CustomLut[] = [];
  /** 自定义 LUT 卡片长按后的操作弹层目标；null 表示弹层关闭。 */
  @State private lutActionsTarget: CustomLut | null = null;
  /** 上传/分享进度弹层：visible 时全屏遮罩阻断操作，value 0~100。 */
  @State private uploadProgressVisible: boolean = false;
  @State private uploadProgressValue: number = 0;
  @State private uploadProgressText: string = '';
  private uploadProgressTimerId: number = -1;
  // Small, asynchronously generated card previews. The full-resolution
  // sample remains reserved for the detail page/editor; cards use these
  // PixelMaps so every LUT visibly reflects its own table.
  @State private lutCardPreviewIds: string[] = [];
  @State private lutCardPreviewMaps: image.PixelMap[] = [];
  private lutCardPreviewLoading: boolean = false;
  private lutCardPreviewQueued: boolean = false;
  private visibleLutIds: Set<string> = new Set<string>();
  private visibleLutLoading: boolean = false;
  private lutPreviewLegacyCleaned: boolean = false;
  @State private lutCatalogRevision: number = 0;
  @State private deletedBundledLutSources: string[] = [];
  private lutLoadPromise: Promise<void> | null = null;
  private portraitLutScroller: Scroller = new Scroller();
  private natureLutScroller: Scroller = new Scroller();
  private customLutScroller: Scroller = new Scroller();
  private lutAutoScrollTimer: number = -1;
  private lutScrollResumeTimer: number = -1;
  private lutScrollPaused: boolean = false;
  /** Set by a card long press so the trailing click is swallowed once. */
  private lutLongPressConsumed: boolean = false;
  // 内置 LUT 已全部下线（NC 经典负片、肤色优化、夏日、日系青调不再随包分发），
  // 现在只保留 catalog.json 里仍在的条目；这里留空数组是为了让
  // seedLutPlaceholders / 兜底加载在没有 rawfile 目录时也不产生幽灵条目。
  private readonly bundledLutPaths: string[] = [];
  // Keep the user-facing names independent from the ASCII resource paths.
  // restool on Windows has trouble cleaning rawfile entries containing
  // Unicode directory/file names during incremental builds.
  private readonly bundledLutDisplayNames: string[] = [];
  /** Media reference used to preview each built-in LUT. */
  private readonly bundledLutReferenceKeys: string[] = [];
  // Keep an in-app fallback for builds where rawfile sidecars are not exposed
  // by resourceManager (some release packages flatten the .txt entries).
  private readonly bundledLutAuthors: string[] = [];
  @StorageLink('vividNightMode') private isNightMode: boolean = false;
  @StorageProp('windowWidth') private windowWidth: number = 390;
  @StorageProp('homeSection') private selectedSection: number = 0;
  @StorageProp('homeSectionTick') @Watch('onSectionChanged') private sectionTick: number = 0;
  @StorageProp('homeShowTick') @Watch('onHomeShowTick') private showTick: number = 0;
  @StorageLink('homeNavCollapsed') private navCollapsed: boolean = false;
  /** 人像 / 自然两行是否切到平铺网格（2 列 × 2 行可见，纵向滚动）。 */
  @State private portraitTiled: boolean = false;
  @State private natureTiled: boolean = false;
  private lastSection: number = 0;

  aboutToAppear(): void {
    // 常驻挂载：作品页导入图片时经 LutBridge 读取 LUT 目录与内置表。
    LutBridge.ensureLutsLoaded = (): Promise<void> => this.ensureLutsLoaded();
    LutBridge.findAnyLut = (name: string): CustomLut | undefined => this.findAnyLut(name);
    LutBridge.loadBundledLut = (name: string): Promise<CustomLut | null> => this.loadBundledLut(name);
    // 云同步落库入口：ProfileSection 下载的云端 LUT 经此加入自定义库。
    LutBridge.listCustomLutNames = (): string[] => this.customLutNamesSnapshot();
    LutBridge.importCloudLut = (lut: CustomLut): Promise<boolean> => this.importCloudLutEntry(lut);
    this.ensureCustomLutsLoaded();
  }

  aboutToDisappear(): void {
    this.visibleLutIds.clear();
    LutBridge.ensureLutsLoaded = null;
    LutBridge.findAnyLut = null;
    LutBridge.loadBundledLut = null;
    LutBridge.listCustomLutNames = null;
    LutBridge.importCloudLut = null;
    this.stopLutAutoScroll();
    if (this.lutScrollResumeTimer >= 0) clearTimeout(this.lutScrollResumeTimer);
    for (const map of this.lutCardPreviewMaps) map.release();
    this.lutCardPreviewMaps = [];
    this.lutCardPreviewIds = [];
  }

  /** 当前自定义 LUT 名称快照：云同步用于跳过同名。 */
  private customLutNamesSnapshot(): string[] {
    return this.customLuts.map((item: CustomLut): string => item.name);
  }

  /**
   * 云端 LUT 落库：追加到自定义列表、注册进 LutLibraryStore、持久化并
   * 刷新卡片预览；本地已有同名时返回 false（调用方按跳过处理）。
   */
  private async importCloudLutEntry(lut: CustomLut): Promise<boolean> {
    try {
      await this.ensureLutsLoaded();
    } catch (_error) {
      // 保持内存态导入。
    }
    for (const item of this.customLuts) {
      if (item.name === lut.name) return false;
    }
    this.customLuts = this.customLuts.concat([lut]);
    LutLibraryStore.upsert(lut);
    this.lutCatalogRevision++;
    AppStorage.setOrCreate('lutCatalogRevision', this.lutCatalogRevision);
    await this.persistCustomLuts();
    setTimeout(() => { this.loadLutCardPreviews(); }, 0);
    return true;
  }

  /** 壳页面 switchSection 的页签进入/离开回放（原 switchSection LUT 分支）。 */
  private onSectionChanged(): void {
    if (this.lastSection === 3 && this.selectedSection !== 3) {
      this.stopLutAutoScroll();
    }
    if (this.selectedSection === 3) {
      this.seedLutPlaceholders();
      this.ensureLutsLoaded().then(() => {
        this.loadLutCardPreviews();
      });
      this.startLutAutoScroll();
      // 官方页签常驻挂载时，重回风格库要立即刷新一次。
      if (this.lutTab === 'official') {
        AppStorage.setOrCreate('officialLutRefreshTick', Date.now());
      }
    }
    this.lastSection = this.selectedSection;
  }

  /** 壳页面 onPageShow 的回放（原 onPageShow 的 LUT 相关分支）。 */
  private onHomeShowTick(): void {
    // The confirmation route can return before the lazy LUT catalog has
    // finished loading. Reconcile after that promise so a newly imported LUT
    // is not overwritten by the late preferences read.
    this.reconcilePendingLut();
    // 碰一碰直达可能在首页创建前就已写入 AppStorage，@Watch 不会为初始值
    // 触发，因此在每次页面可见时再消费一次待导入的分享包。
    this.consumePendingKnockImport();
    if (this.selectedSection === 3) this.startLutAutoScroll();
  }

  private scheduleNavColorRefresh(): void {
    NavColorService.schedule(this.getUIContext());
  }

  private isDesktop(): boolean {
    return this.windowWidth >= 840;
  }

  /** 本机 LUT 页的左右留白：与列表容器的 padding 保持一致。 */
  private lutPagePadding(): number {
    return this.isDesktop() ? 28 : 14;
  }

  /** 列表可见区宽度（扣掉左右留白），平铺网格与动作卡片都按它算尺寸。 */
  private lutContentWidth(): number {
    return Math.max(240, this.windowWidth - this.lutPagePadding() * 2);
  }

  /** 平铺时一列卡片的总宽：两列 + 8 间距正好铺满可见区。 */
  private lutTileWidth(): number {
    return (this.lutContentWidth() - 8) / 2;
  }

  /**
   * 平铺卡片的总高。卡片内部是 8 内边距 ×2 + 1.7:1 的预览图 + 44 的名称区，
   * 和横滑卡片的比例一致，只是宽度换成列宽，所以网格刚好能露出两整行。
   */
  private lutTileHeight(): number {
    return (this.lutTileWidth() - 16) / 1.7 + 44 + 16;
  }

  /** 人像 / 自然两行各自记住"横滑 ⇄ 平铺"的形态。 */
  private isTiled(category: string): boolean {
    return category === '人像' ? this.portraitTiled : this.natureTiled;
  }

  private toggleTiled(category: string): void {
    if (category === '人像') this.portraitTiled = !this.portraitTiled;
    else if (category === '自然') this.natureTiled = !this.natureTiled;
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

  private showMessage(message: string): void {
    AppLogStore.add('ui ' + message);
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      console.info(message);
    }
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

  @StorageProp('lutImportRevision') @Watch('onLutImportChanged') private lutImportRevision: number = 0;

  @StorageProp('lutSampleRevision') @Watch('onLutSampleChanged') private lutSampleRevision: number = 0;

  @StorageProp('vividPendingKnockImport') @Watch('onKnockImportArrived') private knockImportRevision: string = '';

  private onKnockImportArrived(): void {
    this.consumePendingKnockImport();
  }

  /** 取出（并清除）碰一碰直达带来的 LUT 分享包地址，触发导入。 */
  private consumePendingKnockImport(): void {
    const uri = AppStorage.get<string>('vividPendingKnockImport') ?? '';
    if (uri.length === 0) return;
    // 先清标记再导入，@StorageProp 的 @Watch 与 onPageShow 可能先后触发。
    AppStorage.setOrCreate('vividPendingKnockImport', '');
    this.importKnockLutPackage(uri);
  }

  /**
   * 导入碰一碰分享包：单个 JSON 文件内含效果图（base64 JPEG）、.cube LUT
   * 文本和说明信息。还原为沙箱文件后注册为自定义 LUT，同名 LUT 直接选中。
   */
  private async importKnockLutPackage(uri: string): Promise<void> {
    try {
      await this.ensureLutsLoaded();
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pkg = JSON.parse(readLutText(uri)) as Record<string, Object>;
      if (Number(pkg['pixelshopLutPackage']) !== 1) {
        this.showMessage('不是有效的 Pixelshop LUT 分享包');
        return;
      }
      const lutText = knockPackageField(pkg, 'lutText');
      if (lutText.length === 0) {
        this.showMessage('LUT 分享包数据无效');
        return;
      }
      let name = knockPackageField(pkg, 'name');
      if (name.length === 0) name = '碰一碰 LUT';
      for (const item of this.customLuts) {
        if (item.name === name) {
          this.selectedPreset = name;
          this.showMessage(`LUT「${name}」已在库中`);
          return;
        }
      }
      // 还原效果图：作为该 LUT 的示例图展示在卡片与详情页。
      let previewPath = '';
      const previewBase64 = knockPackageField(pkg, 'previewBase64');
      if (previewBase64.length > 0) {
        try {
          const bytes = new util.Base64Helper().decodeSync(previewBase64);
          previewPath = context.filesDir + '/lut_sample_knock_' + Date.now().toString(36) + '.jpg';
          const previewFile = fileIo.openSync(previewPath,
            fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
          try {
            fileIo.writeSync(previewFile.fd, bytes.buffer);
          } finally {
            fileIo.closeSync(previewFile);
          }
        } catch (_error) {
          previewPath = '';
        }
      }
      // 还原 LUT 文件并解析。
      const lutPath = context.filesDir + '/lut_knock_' + Date.now().toString(36) + '.cube';
      const lutFile = fileIo.openSync(lutPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(lutFile.fd, lutText);
      } finally {
        fileIo.closeSync(lutFile);
      }
      const imported = parseLutText(lutText, lutPath);
      if (!imported || !imported.table) {
        this.showMessage('LUT 分享包数据无效');
        return;
      }
      imported.name = name;
      imported.author = knockPackageField(pkg, 'author');
      imported.description = knockPackageField(pkg, 'description');
      imported.category = '自定义';
      imported.format = knockPackageField(pkg, 'format') || 'cube';
      if (previewPath.length > 0) {
        imported.sampleUri = previewPath;
        imported.coverUri = previewPath;
      } else {
        imported.sampleUri = 'resource://vivid_cover';
        imported.coverUri = 'resource://vivid_cover';
      }
      this.customLuts = this.customLuts.concat([imported]);
      LutLibraryStore.upsert(imported);
      this.lutCatalogRevision++;
      AppStorage.setOrCreate('lutCatalogRevision', this.lutCatalogRevision);
      await this.persistCustomLuts();
      this.selectedPreset = imported.name;
      this.showMessage(`已通过碰一碰导入 LUT「${name}」`);
      setTimeout(() => { this.loadLutCardPreviews(); }, 0);
    } catch (_error) {
      this.showMessage('碰一碰 LUT 导入失败');
    }
  }

  private onLutImportChanged(): void { this.reconcilePendingLut(); }

  /** A LUT's sample image was replaced on the detail page; refresh the
   * in-memory entries and card previews so cards follow the new sample. */
  private onLutSampleChanged(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    loadSampleOverrides(context).then((overrides: Record<string, string>) => {
      // changeSampleImage mutates the shared LutLibraryStore entry in place,
      // so an entry may already carry the new sample here. Always reassign
      // the lists and re-render: cached rows reload from disk and only the
      // row with the new sample (new cache name) actually re-renders.
      const nextBundled = this.bundledLuts.map((entry: CustomLut): CustomLut => {
        const override = overrides[entry.id];
        if (override !== undefined && override.length > 0) {
          entry.sampleUri = override;
          entry.coverUri = override;
        }
        return entry;
      });
      const nextCustom = this.customLuts.map((entry: CustomLut): CustomLut => {
        const override = overrides[entry.id];
        if (override !== undefined && override.length > 0) {
          entry.sampleUri = override;
          entry.coverUri = override;
        }
        return entry;
      });
      this.bundledLuts = nextBundled;
      this.customLuts = nextCustom;
      LutLibraryStore.setEntries(nextCustom.concat(nextBundled));
      setTimeout(() => { this.loadLutCardPreviews(); }, 0);
    });
  }

  private async reconcilePendingLut(): Promise<void> {
    const pending = LutLibraryStore.committedImport;
    const storeCustom = LutLibraryStore.entriesSnapshot().filter((item: CustomLut) =>
      item.sourceUri.indexOf('bundled://') !== 0);
    const incoming: CustomLut[] = pending ? [pending] : storeCustom;
    if (incoming.length === 0) return;
    try { await this.ensureLutsLoaded(); } catch (_error) { /* keep in-memory import */ }
    let changed = false;
    for (const imported of incoming) {
      const existingIndex = this.customLuts.findIndex((item: CustomLut) => item.id === imported.id);
      if (existingIndex < 0) {
        this.customLuts = this.customLuts.concat([imported]);
        changed = true;
      } else if (pending) {
        const next = this.customLuts.slice();
        next[existingIndex] = imported;
        this.customLuts = next;
        changed = true;
      }
      LutLibraryStore.upsert(imported);
    }
    if (pending) this.selectedPreset = pending.name;
    if (changed) {
      this.lutCatalogRevision++;
      AppStorage.setOrCreate('lutCatalogRevision', this.lutCatalogRevision);
      await this.persistCustomLuts();
      setTimeout(() => { this.loadLutCardPreviews(); }, 0);
    }
    if (pending) LutLibraryStore.committedImport = null;
  }

  @Builder
  LutContent() {
    Column() {
      // 页签行固定在风格库顶部，内容区独立滚动。
      Column() {
        this.LutTabRow();
      }
      .width('100%')
      .padding({ left: this.isDesktop() ? 28 : 14, right: this.isDesktop() ? 28 : 14, top: 10 });
      if (this.lutTab === 'nikon') {
        // 尼康云创是整页内嵌 Web，独立于滚动区直接填满内容区。
        Column() {
          NikonCloudPanel()
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: this.isDesktop() ? 28 : 14, right: this.isDesktop() ? 28 : 14, top: 4 });
      } else {
        Scroll() {
          Column() {
            if (this.lutTab === 'official') {
              OfficialLutPanel()
            } else if (this.lutTab === 'cloud') {
              NikonCloudLocalPanel()
            } else {
              this.LutCategoryRow('人像', this.portraitLutScroller);
              this.LutCategoryRow('自然', this.natureLutScroller);
              this.LutCategoryRow('自定义', this.customLutScroller);
            }
          }
          .width('100%')
          .padding({ left: this.isDesktop() ? 28 : 14, right: this.isDesktop() ? 28 : 14, top: 4, bottom: 96 });
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onScroll((_xOffset: number, yOffset: number) => {
          this.scheduleNavColorRefresh();
          this.updateNavCollapse(yOffset);
        });
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.showPasteSheet, this.PasteLutSheet(), {
      height: 560,
      dragBar: true,
      showClose: true,
      backgroundColor: this.isNightMode ? '#0D1017' : '#F7F9FD',
      onDisappear: () => { this.showPasteSheet = false; },
    });
  }

  /** 风格库四页签：官方 LUT / 本机 LUT / 云创本地 / 尼康云创，各占行宽四分之一。 */
  @Builder
  LutTabRow() {
    Row() {
      Text('官方 LUT')
        .fontSize(14)
        .fontWeight(this.lutTab === 'official' ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.lutTab === 'official' ? $r('app.color.vivid_text_ffffff') : this.mutedTextColor())
        .width('25%')
        .height(36)
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor(this.lutTab === 'official' ? '#202A3B' : 'rgba(0,0,0,0)')
        .onClick(() => { this.switchLutTab('official'); });
      Text('本机 LUT')
        .fontSize(14)
        .fontWeight(this.lutTab === 'local' ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.lutTab === 'local' ? $r('app.color.vivid_text_ffffff') : this.mutedTextColor())
        .width('25%')
        .height(36)
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor(this.lutTab === 'local' ? '#202A3B' : 'rgba(0,0,0,0)')
        .onClick(() => { this.switchLutTab('local'); });
      Text('云创本地')
        .fontSize(14)
        .fontWeight(this.lutTab === 'cloud' ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.lutTab === 'cloud' ? $r('app.color.vivid_text_ffffff') : this.mutedTextColor())
        .width('25%')
        .height(36)
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor(this.lutTab === 'cloud' ? '#202A3B' : 'rgba(0,0,0,0)')
        .onClick(() => { this.switchLutTab('cloud'); });
      Text('尼康云创')
        .fontSize(14)
        .fontWeight(this.lutTab === 'nikon' ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.lutTab === 'nikon' ? $r('app.color.vivid_text_ffffff') : this.mutedTextColor())
        .width('25%')
        .height(36)
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor(this.lutTab === 'nikon' ? '#202A3B' : 'rgba(0,0,0,0)')
        .onClick(() => { this.switchLutTab('nikon'); });
    }
    .width('100%')
    .height(44)
    .padding(4)
    .borderRadius(22)
    .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.55)')
    .border({ width: 1, color: this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.82)' });
  }

  /** 切换风格库页签：官方页签挂载即刷新；本机页签补种卡片预览。 */
  private switchLutTab(tab: string): void {
    if (this.lutTab === tab) return;
    this.lutTab = tab;
    if (tab === 'official') {
      AppStorage.setOrCreate('officialLutRefreshTick', Date.now());
    } else if (tab === 'local') {
      this.seedLutPlaceholders();
      this.ensureLutsLoaded().then(() => {
        this.loadLutCardPreviews();
      });
    } else if (tab === 'nikon') {
      // 尼康云创页签：重回时刷新一次内嵌页面，保持与官网内容同步。
      AppStorage.setOrCreate('officialLutRefreshTick', Date.now());
    }
  }

  /**
   * 一行的标题条。人像 / 自然右侧带「平铺」开关：关着是左右横滑的卡片流，
   * 打开后同一批卡片改成两列网格，一次露出四张、上下滑动看剩下的。
   */
  @Builder
  LutSectionHeader(title: string) {
    Row() {
      Text(title).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor());
      Blank();
      if (title !== '自定义') {
        Text('平铺')
          .fontSize(11)
          .fontWeight(this.isTiled(title) ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.isTiled(title) ? $r('app.color.vivid_text_ffffff') : this.panelTextColor())
          .padding({ left: 11, right: 11, top: 4, bottom: 4 })
          .borderRadius(12)
          .backgroundColor(this.isTiled(title) ? '#202A3B'
            : (this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.55)'))
          .border({
            width: 1,
            color: this.isTiled(title) ? '#202A3B'
              : (this.isNightMode ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.82)'),
          })
          .onClick(() => { this.toggleTiled(title); });
      }
    }
    .width('100%')
    .height(30)
    .margin({ top: title === '自定义' ? 14 : 6, bottom: 7 });
  }

  /** 平铺视图：两列，可视高度正好两行（4 张），其余向下滚动。 */
  @Builder
  LutTileGrid(category: string) {
    Grid() {
      ForEach(this.rowLuts(category), (lut: CustomLut, index: number) => {
        GridItem() {
          this.LutCard(lut, index, true);
        }
      }, (lut: CustomLut) => 'tile:' + lut.id + ':' + lut.name + ':' + (lut.author ?? ''));
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(8)
    .rowsGap(8)
    .width('100%')
    .height(this.lutTileHeight() * 2 + 8)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None);
  }

  @Builder
  LutCategoryRow(title: string, scroller: Scroller) {
    Column() {
      this.LutSectionHeader(title);
      if (title !== '自定义' && this.isTiled(title)) {
        this.LutTileGrid(title);
      } else {
        Scroll(scroller) {
          Row({ space: 8 }) {
            ForEach(this.rowLuts(title).length > 2 ? [0, 1, 2] : [0], (copy: number) => {
              if (title === '自定义') {
                this.LutImportCard();
                this.LutPasteCard();
              }
              ForEach(this.rowLuts(title), (lut: CustomLut, index: number) => { this.LutCard(lut, index, false); },
                (lut: CustomLut) => lut.id + ':' + lut.name + ':' + (lut.author ?? ''));
            }, (copy: number) => title + ':' + copy.toString() + ':' + this.rowLuts(title).map((lut: CustomLut) => lut.id).join('|'));
          }.padding({ left: 1, right: 14 });
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
          .height(176).width('100%')
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.lutScrollPaused = true;
              if (this.lutScrollResumeTimer >= 0) clearTimeout(this.lutScrollResumeTimer);
              // Some HarmonyOS builds do not dispatch Up when the horizontal
              // scroller takes ownership of the gesture. Never leave the row
              // permanently paused in that case.
              this.lutScrollResumeTimer = setTimeout(() => {
                this.lutScrollPaused = false;
                this.lutScrollResumeTimer = -1;
              }, 900) as number;
            }
            if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.lutScrollPaused = false;
              if (this.lutScrollResumeTimer >= 0) clearTimeout(this.lutScrollResumeTimer);
              this.lutScrollResumeTimer = -1;
            }
          });
      }
    }.width('100%');
  }

  @Builder
  LutImportCard() {
    Column() {
      Text('+').fontSize(34).fontColor($r('app.color.vivid_text_6d7890'));
      Text('导入 LUT').fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor())
        .margin({ top: 8 });
      Text('自定义').fontSize(9).fontColor(this.mutedTextColor()).margin({ top: 3 });
    }.width((this.lutContentWidth() - 23) / 2).height(170).justifyContent(FlexAlign.Center)
      .borderRadius(22)
      .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(150,165,190,0.42)' })
      .backgroundColor(this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.42)')
      .onClick(() => { this.importLut(); });
  }

  /** 粘贴好友分享的 LUT 标志（原「LUT 市场」功能，现归属本机 LUT 页）。 */
  @Builder
  LutPasteCard() {
    Column() {
      Text('贴').fontSize(26).fontWeight(FontWeight.Medium).fontColor($r('app.color.vivid_text_6d7890'));
      Text('粘贴好友').fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor())
        .margin({ top: 8 });
      Text('分享码').fontSize(9).fontColor(this.mutedTextColor()).margin({ top: 3 });
    }.width((this.lutContentWidth() - 23) / 2).height(170).justifyContent(FlexAlign.Center)
      .borderRadius(22)
      .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(150,165,190,0.42)' })
      .backgroundColor(this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.42)')
      .onClick(() => { this.showPasteSheet = true; });
  }

  /** 粘贴弹层：复用原 LUT 市场的分享码检索 / 下载入库链路。 */
  @Builder
  PasteLutSheet() {
    Column() {
      Text('粘贴好友的 LUT')
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor())
        .width('100%').margin({ bottom: 4 });
      Scroll() {
        Column() {
          LutMarketPanel()
        }.width('100%');
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 12 });
  }

  private lutsForCategory(category: string): CustomLut[] {
    return this.bundledLuts.filter((lut: CustomLut) =>
      this.deletedBundledLutSources.indexOf(lut.sourceUri) < 0 && lut.category === category);
  }

  private rowLuts(category: string): CustomLut[] {
    if (category === '自定义') {
      // The custom row keeps every entry that did not opt into the 人像/自然
      // rows at import time: knockshare imports, legacy entries and the rest.
      return this.customLuts.filter((lut: CustomLut) => lut.category !== '人像' && lut.category !== '自然');
    }
    return this.lutsForCategory(category).concat(this.customLuts.filter((lut: CustomLut) => lut.category === category));
  }

  @Builder
  LutCard(preset: Preset, index: number, tile: boolean) {
    Column() {
      Stack() {
        if (this.cardPreviewFor((preset as CustomLut).id)) {
          Image(this.cardPreviewFor((preset as CustomLut).id) as image.PixelMap)
            .width('100%').height('100%').objectFit(ImageFit.Cover);
        } else if ((preset as CustomLut).sampleUri && (preset as CustomLut).sampleUri!.length > 0 &&
          (preset as CustomLut).sampleUri!.indexOf('resource://') !== 0) {
          Image(lutDisplayUri((preset as CustomLut).sampleUri as string))
            .width('100%').height('100%').objectFit(ImageFit.Cover);
        } else {
          Image(this.lutReferenceResource(preset as CustomLut)).width('100%').height('100%').objectFit(ImageFit.Cover);
        }
        Row().width('100%').height('100%').linearGradient({ angle: 90,
          colors: [['rgba(0,0,0,0.05)', 0], ['rgba(0,0,0,0.55)', 1]] });
      }
      .width('100%')
      .aspectRatio(1.7)
      .borderRadius(17)
      .clip(true);
      Row() {
        Column() {
          Text(preset.name)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.panelTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(((preset as CustomLut).author && (preset as CustomLut).author!.length > 0)
            ? (preset as CustomLut).author! : '未知作者')
            .fontSize(8)
            .fontColor(this.mutedTextColor())
            .letterSpacing(0.6)
            .margin({ top: 3 });
        }
        .alignItems(HorizontalAlign.Start);
        Blank();
        // Only user imported entries are deletable. Bundled portrait/nature
        // resources remain in the catalog and show their built-in marker.
        // Custom entries are managed through the long-press action menu.
        if (this.findCustomLut(preset.name) === undefined) {
          Text('内置').fontSize(9).fontColor($r('app.color.vivid_text_8b96a6'));
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 3, right: 3, top: 6 });
    }
    .width(tile ? '100%' : (this.isDesktop() ? 200 : 190))
    .height(tile ? this.lutTileHeight() : 170)
    .padding(8)
    .borderRadius(22)
    // 夜间填充与官方 LUT 页卡片取同一套色值（rgba(32,42,59,0.62) + 冷灰描边），
    // 选中态只是把同一底色提到更实的透明度，不再出现灰白玻璃片。
    .backgroundColor(this.findCustomLut(preset.name) !== undefined && this.selectedPreset === preset.name ?
      (this.isNightMode ? 'rgba(32,42,59,0.92)' : 'rgba(255,255,255,0.82)')
      : (this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.52)'))
    .border({ width: 1, color: this.findCustomLut(preset.name) !== undefined && this.selectedPreset === preset.name ?
      '#B4BDF9' : (this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.82)') })
    .shadow({ radius: 18, color: this.isNightMode ? 'rgba(0,0,0,0.26)' : 'rgba(57,70,92,0.10)', offsetY: 7 })
    .onVisibleAreaChange([0, 0.2], (_expanding: boolean, ratio: number) => {
      const id = (preset as CustomLut).id;
      if (ratio > 0) {
        this.visibleLutIds.add(id);
        this.hydrateVisibleLuts();
      } else {
        this.visibleLutIds.delete(id);
      }
    })
    .gesture(LongPressGesture({ repeat: false }).onAction(() => {
      // Long-press acts only on user imported entries; bundled cards keep
      // plain tap-to-detail behavior.
      const custom = this.findCustomLut(preset.name);
      if (!custom) return;
      // A completed long press would also raise onClick on release; mark the
      // gesture so the follow-up click does not push the detail page.
      this.lutLongPressConsumed = true;
      this.showCustomLutActions(custom);
    }))
    .onClick(() => {
      if (this.lutLongPressConsumed) {
        this.lutLongPressConsumed = false;
        return;
      }
      this.selectedPreset = preset.name;
      const lut = preset as CustomLut;
      if (lut.id && lut.id.length > 0) {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/LutDetailPage', params: { lutId: lut.id } });
      }
    });
  }

  private seedLutPlaceholders(): void {
    if (this.bundledLuts.length > 0) return;
    this.bundledLuts = this.bundledLutPaths.map((path: string, index: number) => ({
      id: 'bundled:' + path, sourceUri: 'bundled://' + path,
      name: this.bundledLutDisplayNames[index] ?? path, sampleCount: 0,
      category: path.indexOf('/portrait/') >= 0 ? '人像' : '自然',
      sampleUri: 'resource://lut_sample_portrait', coverUri: 'resource://lut_sample_portrait',
      referenceKey: this.bundledLutReferenceKeys[index] ?? '',
      adjustments: {}, table: null,
    } as CustomLut));
    LutLibraryStore.setEntries(this.customLuts.concat(this.bundledLuts));
    this.lutCatalogRevision++;
    AppStorage.setOrCreate('lutCatalogRevision', this.lutCatalogRevision);
  }

  private startLutAutoScroll(): void {
    if (this.lutAutoScrollTimer >= 0) return;
    this.lutAutoScrollTimer = setInterval(() => {
      if (this.selectedSection !== 3 || this.lutScrollPaused || this.lutTab !== 'local') return;
      try {
        this.autoScrollLut(this.portraitLutScroller, this.rowLuts('人像').length, 1, false);
        this.autoScrollLut(this.natureLutScroller, this.rowLuts('自然').length, -1, false);
        this.autoScrollLut(this.customLutScroller, this.rowLuts('自定义').length, 1, true);
      } catch (_error) {
      }
    }, 40) as number;
  }

  private stopLutAutoScroll(): void {
    if (this.lutAutoScrollTimer >= 0) clearInterval(this.lutAutoScrollTimer);
    this.lutAutoScrollTimer = -1;
    if (this.lutScrollResumeTimer >= 0) clearTimeout(this.lutScrollResumeTimer);
    this.lutScrollResumeTimer = -1;
    this.lutScrollPaused = false;
  }

  /** Keep each LUT row moving in its requested direction and wrap at the edge. */
  private autoScrollLut(scroller: Scroller, count: number, direction: number, hasImportCard: boolean): void {
    if (count <= 2) return;
    try {
      // Card width (200/190) plus the row's breathing room. Keeping this
      // estimate slightly conservative lets the wrap trigger before the
      // scroller reaches its hard end, where some devices stop dispatching
      // tiny scrollBy deltas.
      const cardPitch = (this.isDesktop() ? 200 : 190) + 8;
      const itemCount = count + (hasImportCard ? 1 : 0);
      const cycleWidth = itemCount * cardPitch;
      const offset = scroller.currentOffset().xOffset;
      let next = offset + direction * 0.7;
      if (next < cycleWidth) next += cycleWidth;
      if (next >= cycleWidth * 2) next -= cycleWidth;
      scroller.scrollTo({ xOffset: next, yOffset: 0, animation: false });
    } catch (_error) {
      // The scroller is not bound during the first layout pass.
    }
  }

  private async loadCustomLuts(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const parsed = await loadCustomLutsFromStore(context);
      this.customLuts = parsed.map((item: CustomLut) => {
        // Imported LUTs keep their chosen 人像/自然 row across restarts;
        // knockshare and legacy entries stay in the custom row.
        if (item.category !== '人像' && item.category !== '自然') item.category = '自定义';
        if (!item.coverUri) item.coverUri = 'resource://vivid_cover';
        if (!item.sampleUri) item.sampleUri = 'resource://vivid_cover';
        return item;
      });
      this.deletedBundledLutSources = await loadDeletedBundledLuts(context);
      // 更换示例图 overrides apply to custom LUTs as well (lut:<uri> ids).
      applySampleOverrides(this.customLuts, await loadSampleOverrides(context));
    } catch (_error) {
      this.customLuts = [];
      this.deletedBundledLutSources = [];
    }
    for (const lut of this.customLuts) LutLibraryStore.upsert(lut);
    this.lutCatalogRevision++;
    AppStorage.setOrCreate('lutCatalogRevision', this.lutCatalogRevision);
  }

  private customLutLoadPromise: Promise<void> | null = null;
  private ensureCustomLutsLoaded(): Promise<void> {
    if (!this.customLutLoadPromise) this.customLutLoadPromise = this.loadCustomLuts();
    return this.customLutLoadPromise;
  }

  private ensureLutsLoaded(): Promise<void> {
    if (!this.lutLoadPromise) {
      this.lutLoadPromise = this.ensureCustomLutsLoaded().then(() => this.loadBundledLuts());
    }
    return this.lutLoadPromise;
  }

  /** Load the LUT files shipped in resources/rawfile/Lut on first LUT-page use. */
  private async loadBundledLuts(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const sampleOverrides = await loadSampleOverrides(context);
      const loaded: CustomLut[] = this.bundledLutPaths.map((path: string, index: number) => ({
        id: 'bundled:' + path,
        sourceUri: 'bundled://' + path,
        name: this.bundledLutDisplayNames[index] ?? path,
        sampleCount: LutLibraryStore.find('bundled:' + path)?.sampleCount ?? 0,
        category: path.indexOf('/portrait/') >= 0 ? '人像' : '自然',
        sampleUri: 'resource://lut_sample_portrait',
        coverUri: 'resource://lut_sample_portrait',
        referenceKey: this.bundledLutReferenceKeys[index] ?? '',
        adjustments: {},
        table: LutLibraryStore.find('bundled:' + path)?.table ?? null,
      } as CustomLut));
      // Publish placeholders immediately so the page never shows a large blank
      // area while a text LUT is being parsed. Each entry is replaced in place
      // as its table becomes available.
      this.bundledLuts = loaded.slice();
      LutLibraryStore.setEntries(this.customLuts.concat(loaded));
      for (let index = 0; index < this.bundledLutPaths.length; index++) {
        const path = this.bundledLutPaths[index];
        // Catalogs need only metadata/reference images. Tables are parsed by
        // the shared loader when selected, rather than cloned back en masse.
        const parsed = LutLibraryStore.find('bundled:' + path) ?? null;
        const category = path.indexOf('/portrait/') >= 0 ? '人像' : '自然';
        const name = this.bundledLutDisplayNames[index] ?? path;
        const entry: CustomLut = parsed ?? ({
          id: 'bundled:' + path, sourceUri: 'bundled://' + path, name: name,
          sampleCount: 0, adjustments: {}, table: null,
        } as CustomLut);
        entry.id = 'bundled:' + path;
        entry.sourceUri = 'bundled://' + path;
        entry.name = name;
        entry.category = category;
        entry.sampleUri = 'resource://lut_sample_portrait';
        entry.coverUri = 'resource://lut_sample_portrait';
        entry.referenceKey = this.bundledLutReferenceKeys[index] ?? '';
        // 更换示例图: a persisted user sample wins over the bundled reference.
        const sampleOverride = sampleOverrides[entry.id];
        if (sampleOverride !== undefined && sampleOverride.length > 0) {
          entry.sampleUri = sampleOverride;
          entry.coverUri = sampleOverride;
        }
        try {
          const metadataPath = path.substring(0, path.lastIndexOf('.')) + '.txt';
          const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          const metadataData = await context.resourceManager.getRawFileContent(metadataPath);
          const metadata = parseLutMetadata(util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(metadataData)));
          entry.author = metadata.author.length > 0 ? metadata.author : (this.bundledLutAuthors[index] ?? '');
          entry.description = metadata.description;
        } catch (_error) {
          entry.author = this.bundledLutAuthors[index] ?? '';
          entry.description = '';
        }
        loaded[index] = entry;
        this.bundledLuts = loaded.slice();
        LutLibraryStore.setEntries(this.customLuts.concat(loaded));
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
      this.bundledLuts = loaded;
      LutLibraryStore.setEntries(this.customLuts.concat(loaded));
      this.lutCatalogRevision++;
      AppStorage.setOrCreate('lutCatalogRevision', this.lutCatalogRevision);
      // Do not hold the page transition on image processing. Card previews are
      // generated from the already parsed tables after the catalog is visible.
      setTimeout(() => { this.loadLutCardPreviews(); }, 0);
    } catch (_error) {
      // Keep already published placeholders if a resource manager call fails.
    }
  }

  /** Resolve the bundled reference image used by a LUT card/detail page. */
  private lutReferenceResource(entry: CustomLut) {
    switch (entry.referenceKey ?? '') {
      case 'sunny_mint': return $r('app.media.lut_ref_sunny_mint');
      case 'japanese_cyan': return $r('app.media.lut_ref_japanese_cyan');
      case 'fresh_food': return $r('app.media.lut_ref_fresh_food');
      case 'healing_light': return $r('app.media.lut_ref_healing_light');
      case 'snow_portrait': return $r('app.media.lut_ref_snow_portrait');
      case 'seaside_portrait': return $r('app.media.lut_ref_seaside_portrait');
      case 'nc_classic_neg': return $r('app.media.lut_ref_nc_classic_neg');
      default: return $r('app.media.lut_sample_portrait');
    }
  }
  /** Generate compact, real LUT-rendered previews for the horizontal cards.
   * 卡片先以占位内容渲染，效果图在后台队列里逐个生成，每完成一个立即
   * 回显到对应卡片，避免全部完成时一次性刷新造成页面卡顿。 */
  private async loadLutCardPreviews(): Promise<void> {
    if (this.lutCardPreviewLoading) { this.lutCardPreviewQueued = true; return; }
    const entries: CustomLut[] = this.bundledLuts.concat(this.customLuts)
      .filter((entry: CustomLut) => this.visibleLutIds.has(entry.id) && entry.table !== null && entry.table !== undefined);
    if (entries.length === 0) return;
    this.lutCardPreviewLoading = true;
    let source: image.ImageSource | null = null;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!this.lutPreviewLegacyCleaned) {
        this.lutPreviewLegacyCleaned = true;
        this.cleanLegacyLutPreviews(context.filesDir);
      }
      const bytes = await context.resourceManager.getMediaContent($r('app.media.lut_sample_portrait'));
      source = image.createImageSource(bytes.buffer as ArrayBuffer);
      const info = await source.getImageInfo();
      const scale = Math.min(1, 640 / Math.max(info.size.width, info.size.height));
      const width = Math.max(1, Math.round(info.size.width * scale));
      const height = Math.max(1, Math.round(info.size.height * scale));
      const original = await source.createPixelMap({ editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888, desiredSize: { width: width, height: height } });
      const baseBuffer = new ArrayBuffer(width * height * 4);
      await original.readPixelsToBuffer(baseBuffer);
      original.release();
      const basePixels = new Uint8ClampedArray(baseBuffer);
      for (const entry of entries) {
        if (!this.visibleLutIds.has(entry.id)) continue;
        const map = await this.renderLutCardPreview(context, entry, basePixels, width, height);
        if (map && !this.visibleLutIds.has(entry.id)) { map.release(); continue; }
        if (map) {
          // 每完成一个立即回显：已有同 id 的预览原位替换，否则追加。
          const index = this.lutCardPreviewIds.indexOf(entry.id);
          if (index >= 0 && index < this.lutCardPreviewMaps.length) {
            const previous = this.lutCardPreviewMaps[index];
            this.lutCardPreviewMaps[index] = map;
            if (previous) previous.release();
          } else {
            this.lutCardPreviewMaps = this.lutCardPreviewMaps.concat([map]);
            this.lutCardPreviewIds = this.lutCardPreviewIds.concat([entry.id]);
          }
        }
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
    } catch (_error) {
      // 单个预览失败只影响对应卡片，队列继续。
    } finally {
      if (source) source.release();
      this.lutCardPreviewLoading = false;
      if (this.lutCardPreviewQueued) {
        this.lutCardPreviewQueued = false;
        setTimeout(() => { this.loadLutCardPreviews(); }, 0);
      }
    }
  }

  /** Render real effects only for cards on screen, with one parse in flight. */
  private async hydrateVisibleLuts(): Promise<void> {
    if (this.visibleLutLoading || this.selectedSection !== 3 || this.lutTab !== 'local') return;
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    this.visibleLutLoading = true;
    const attempted = new Set<string>();
    try {
      await this.ensureLutsLoaded();
      this.bundledLuts = this.bundledLuts.map((item: CustomLut): CustomLut =>
        this.visibleLutIds.has(item.id) ? (LutLibraryStore.find(item.id) ?? item) : item);
      while (this.selectedSection === 3 && this.lutTab === 'local') {
        const entry = LutLibraryStore.entriesSnapshot().find((item: CustomLut): boolean =>
          this.visibleLutIds.has(item.id) && !item.table && !attempted.has(item.id));
        if (!entry) break;
        attempted.add(entry.id);
        const loaded = await LutLoader.load(context.resourceManager, entry);
        if (loaded && LutLibraryStore.find(entry.id)) {
          this.bundledLuts = this.bundledLuts.map((item: CustomLut): CustomLut => item.id === loaded.id ? loaded : item);
        }
      }
      if (this.selectedSection === 3 && this.lutTab === 'local') await this.loadLutCardPreviews();
    } finally { this.visibleLutLoading = false; }
  }

  /** Render one LUT card preview: cache hit returns immediately, otherwise
   * the reference/sample pixels pass through the LUT (GPU bridge first,
   * TaskPool fallback) and the result is persisted for the shared cache. */
  private async renderLutCardPreview(context: common.UIAbilityContext, entry: CustomLut,
    basePixels: Uint8ClampedArray, width: number, height: number): Promise<image.PixelMap | null> {
    const table = entry.table;
    if (!table) return null;
    const cachePath = this.lutPreviewCachePath(context.filesDir, entry);
    try {
      if (fileIo.statSync(cachePath).size > 0) {
        const cached = await PixelMapUtils.loadFromUri(cachePath, 640);
        if (cached) return cached;
      }
    } catch (_error) {
      // First run or an invalidated cache falls through to rendering.
    }
    // Card previews are deliberately tiny. Run the same LUT stage in a
    // TaskPool worker so parsing/sampling never occupies the UI thread;
    // export remains the only full-resolution path.
    let renderWidth = width;
    let renderHeight = height;
    let renderBuffer = basePixels.buffer.slice(0);
    if (entry.sampleUri && entry.sampleUri.indexOf('resource://') !== 0) {
      // 更换示例图: the user-chosen sample wins over the bundled reference.
      const sample = await PixelMapUtils.loadFromUri(entry.sampleUri, 640);
      if (!sample) return null;
      try {
        const sampleInfo = await sample.getImageInfo();
        renderWidth = sampleInfo.size.width;
        renderHeight = sampleInfo.size.height;
        renderBuffer = new ArrayBuffer(renderWidth * renderHeight * 4);
        await sample.readPixelsToBuffer(renderBuffer);
      } finally { sample.release(); }
    } else if ((entry.referenceKey ?? '').length > 0) {
      let referenceSource: image.ImageSource | null = null;
      try {
        const referenceBytes = await context.resourceManager.getMediaContent(this.lutReferenceResource(entry));
        referenceSource = image.createImageSource(referenceBytes.buffer as ArrayBuffer);
        const referenceInfo = await referenceSource.getImageInfo();
        const referenceScale = Math.min(1, 640 / Math.max(referenceInfo.size.width, referenceInfo.size.height));
        renderWidth = Math.max(1, Math.round(referenceInfo.size.width * referenceScale));
        renderHeight = Math.max(1, Math.round(referenceInfo.size.height * referenceScale));
        const referenceMap = await referenceSource.createPixelMap({
          editable: true, desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
          desiredSize: { width: renderWidth, height: renderHeight },
        });
        renderBuffer = new ArrayBuffer(renderWidth * renderHeight * 4);
        await referenceMap.readPixelsToBuffer(renderBuffer);
        referenceMap.release();
      } catch (_error) {
        renderWidth = width;
        renderHeight = height;
        renderBuffer = basePixels.buffer.slice(0);
      } finally {
        if (referenceSource) referenceSource.release();
      }
    }
    const workerLut: WorkerLut = { enabled: true, intensity: 1, size: table.size,
      values: table.values, domainMin: table.domainMin, domainMax: table.domainMax };
    let pixels: Uint8ClampedArray;
    const gpuBuffer = await GpuShaderBridge.renderLutPreview(renderBuffer.slice(0), renderWidth, renderHeight, table);
    if (gpuBuffer && gpuBuffer.byteLength > 0) {
      pixels = new Uint8ClampedArray(gpuBuffer);
    } else {
      const params: ProcessParams = {
        source: renderBuffer, width: renderWidth, height: renderHeight,
        layers: [], luts: [workerLut], cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
        rotation: 0, flipH: false, flipV: false, applyGeometry: false, ignoreCrop: true,
      };
      const task = new taskpool.Task(processPixels, params);
      const result = await taskpool.execute(task) as ProcessResult;
      if (!result || result.buffer.byteLength === 0) return null;
      pixels = new Uint8ClampedArray(result.buffer);
    }
    const output = await image.createPixelMap(new ArrayBuffer(pixels.byteLength), {
      editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888, size: { width: renderWidth, height: renderHeight } });
    await output.writeBufferToPixels(pixels.buffer);
    try {
      const jpeg = await PixelMapUtils.encodeToJpeg(output, 90);
      if (jpeg) {
        const file = fileIo.openSync(cachePath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, jpeg);
        fileIo.closeSync(file);
      }
    } catch (_error) {
      // A cache failure must not affect the in-memory preview.
    }
    return output;
  }

  private cardPreviewFor(id: string): image.PixelMap | null {
    const index = this.lutCardPreviewIds.indexOf(id);
    return index >= 0 && index < this.lutCardPreviewMaps.length ? this.lutCardPreviewMaps[index] : null;
  }

  private lutPreviewCachePath(filesDir: string, entry: CustomLut): string {
    // 原图名+LUT 命名的共享效果图缓存：与 LUT 传输页本机列表共用同一份
    // 文件，首次进入 LUT 页渲染落盘后，之后每次启动直接加载不再渲染。
    return lutEffectCachePath(filesDir, lutSampleBaseName(entry), entry.name);
  }

  /** Delete the old hash-named preview caches once; the readable
   * 原图名+LUT files replace them. */
  private cleanLegacyLutPreviews(filesDir: string): void {
    try {
      const names = fileIo.listFileSync(filesDir);
      for (const name of names) {
        if (name.startsWith('vivid_lut_preview_')) {
          try {
            fileIo.unlinkSync(filesDir + '/' + name);
          } catch (_error) {
          }
        }
      }
    } catch (_error) {
    }
  }

  /** Parse exactly one bundled LUT when it is selected for an edit. */
  private async loadBundledLut(name: string): Promise<CustomLut | null> {
    const placeholder = this.findAnyLut(name);
    if (!placeholder || placeholder.sourceUri.indexOf('bundled://') !== 0 || placeholder.sampleCount > 0) {
      return placeholder ?? null;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const parsed = await LutLoader.load(context.resourceManager, placeholder);
      if (!parsed) return null;
      parsed.name = placeholder.name;
      parsed.id = placeholder.id;
      parsed.category = placeholder.category;
      parsed.author = placeholder.author;
      parsed.description = placeholder.description;
      parsed.sampleUri = placeholder.sampleUri;
      parsed.coverUri = placeholder.coverUri;
      parsed.referenceKey = placeholder.referenceKey;
      const next: CustomLut[] = this.bundledLuts.map((item: CustomLut) =>
        item.sourceUri === placeholder.sourceUri ? parsed : item);
      this.bundledLuts = next;
      LutLibraryStore.setEntries(this.customLuts.concat(next));
      this.lutCatalogRevision++;
      AppStorage.setOrCreate('lutCatalogRevision', this.lutCatalogRevision);
      return parsed;
    } catch (_error) {
      return null;
    }
  }

  private async persistCustomLuts(): Promise<void> {
    try {
      if (this.lutLoadPromise) await this.lutLoadPromise;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await saveCustomLuts(context, this.customLuts);
      await saveDeletedBundledLuts(context, this.deletedBundledLutSources);
    } catch (_error) {
      // The in-memory list remains available when the store is unavailable.
    }
  }

  private async importLut(): Promise<void> {
    try {
      await this.ensureLutsLoaded();
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris = await documentPicker.select({
        fileSuffixFilters: ['LUT|.cube,.3dl,.look,.vlt'],
        maxSelectNumber: 1,
      });
      if (!uris || uris.length === 0) return;
      const imported = parseLutFile(uris[0]);
      if (!imported) {
        this.showMessage('无法读取 LUT 文件，请选择 .cube、.3dl、.look 或 .vlt 文件');
        return;
      }
      for (let index = 0; index < this.customLuts.length; index++) {
        if (this.customLuts[index].sourceUri === imported.sourceUri) {
          this.selectedPreset = this.customLuts[index].name;
          this.showMessage('该 LUT 已在库中');
          return;
        }
      }
      imported.category = '自定义';
      imported.coverUri = 'resource://vivid_cover';
      imported.sampleUri = 'resource://vivid_cover';
      LutLibraryStore.setPending(imported);
      this.getUIContext().getRouter().pushUrl({ url: 'pages/LutImportConfirmPage' });
    } catch (_error) {
      this.showMessage('LUT 导入已取消');
    }
  }

  /** 长按自定义 LUT 卡片：弹出分享/删除操作菜单（自绘窄弹层）。 */
  private showCustomLutActions(lut: CustomLut): void {
    this.lutActionsTarget = lut;
  }

  private confirmDeleteSingleCustomLut(lut: CustomLut): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除 LUT',
      message: `确定删除「${lut.name}」吗？已被草稿引用的 LUT 将从引用中移除，但不会删除原照片。`,
      buttons: [
        { text: '取消', color: '#536176' },
        { text: '删除', color: '#C4485C' },
      ],
    }).then(async (result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index !== 1) return;
      LutLibraryStore.remove(lut.id);
      this.customLuts = this.customLuts.filter((item: CustomLut) => item.id !== lut.id);
      this.lutCatalogRevision++;
      AppStorage.setOrCreate('lutCatalogRevision', this.lutCatalogRevision);
      if (this.selectedPreset === lut.name) this.selectedPreset = '';
      await this.persistCustomLuts();
      this.showMessage(`已删除 LUT「${lut.name}」`);
    }).catch(() => {
    });
  }

  /**
   * 分享自定义 LUT：与碰一碰分享包同格式（单个 JSON 内嵌 .cube 文本、说明
   * 与卡片效果图），接收端导入后即可还原。效果图复用卡片预览缓存。
   */
  private async shareCustomLut(lut: CustomLut): Promise<void> {
    if (!lut.table) {
      this.showMessage('LUT 数据尚未加载，请稍后再试');
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const table = lut.table;
      // 从已解析的 LUT 表重新生成 .cube 文本，不依赖原始文件仍然可读。
      const lines: string[] = ['TITLE "' + lut.name.replace(/["\r\n]/g, ' ') + '"',
        'LUT_3D_SIZE ' + table.size.toString(),
        'DOMAIN_MIN ' + table.domainMin.join(' '),
        'DOMAIN_MAX ' + table.domainMax.join(' ')];
      for (let i = 0; i < table.values.length; i += 3) {
        lines.push(table.values[i].toFixed(7) + ' ' + table.values[i + 1].toFixed(7) + ' ' + table.values[i + 2].toFixed(7));
      }
      let previewBase64 = '';
      try {
        const previewPath = lutEffectCachePath(context.filesDir, lutSampleBaseName(lut), lut.name);
        const previewFile = fileIo.openSync(previewPath, fileIo.OpenMode.READ_ONLY);
        try {
          const size = fileIo.statSync(previewFile.fd).size;
          const buffer = new ArrayBuffer(size);
          fileIo.readSync(previewFile.fd, buffer);
          previewBase64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer));
        } finally {
          fileIo.closeSync(previewFile);
        }
      } catch (_error) {
        previewBase64 = '';
      }
      const token = lutCacheToken(lut.name);
      const packageJson: Record<string, Object> = {
        'pixelshopLutPackage': 1,
        'name': lut.name,
        'author': lut.author ?? '',
        'description': lut.description ?? '',
        'format': lut.format ?? 'cube',
        'sharedAt': Date.now(),
        'lutFileName': token + '.cube',
        'lutText': lines.join('\n') + '\n',
        'previewBase64': previewBase64,
      };
      const packagePath = context.cacheDir + '/lut_share_' + token + '_' + Date.now().toString(36) + '.json';
      const packageFile = fileIo.openSync(packagePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(packageFile.fd, JSON.stringify(packageJson));
      } finally {
        fileIo.closeSync(packageFile);
      }
      const record: systemShare.SharedRecord = {
        utd: uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.json'),
        uri: fileUri.getUriFromPath(packagePath),
        title: `Pixelshop LUT · ${lut.name}`,
        description: lut.author && lut.author.length > 0 ? `${lut.author} 的 LUT` : '分享的 Pixelshop LUT',
      };
      const controller = new systemShare.ShareController(new systemShare.SharedData(record));
      await controller.show(context, { selectionMode: systemShare.SelectionMode.SINGLE });
    } catch (_error) {
      this.showMessage('分享 LUT 失败');
    }
  }

  /** 从已解析的 LUT 表重建 .cube 文本（上传/分享共用）。 */
  private buildLutCubeText(lut: CustomLut): string {
    const table = lut.table;
    if (!table) return '';
    const lines: string[] = ['TITLE "' + lut.name.replace(/["\r\n]/g, ' ') + '"',
      'LUT_3D_SIZE ' + table.size.toString(),
      'DOMAIN_MIN ' + table.domainMin.join(' '),
      'DOMAIN_MAX ' + table.domainMax.join(' ')];
    for (let i = 0; i < table.values.length; i += 3) {
      lines.push(table.values[i].toFixed(7) + ' ' + table.values[i + 1].toFixed(7) + ' ' + table.values[i + 2].toFixed(7));
    }
    return lines.join('\n') + '\n';
  }

  /** 读取卡片效果缓存图并编码为 ≤1080P 预览 + ≤256px 缩略图；失败返回空串。 */
  private async loadCloudPreviewPayload(context: common.UIAbilityContext,
    lut: CustomLut): Promise<CloudPreviewPayload> {
    const payload = new CloudPreviewPayload();
    try {
      const previewPath = lutEffectCachePath(context.filesDir, lutSampleBaseName(lut), lut.name);
      const previews = await this.encodeCloudPreview(previewPath);
      payload.previewBase64 = previews.previewBase64;
      payload.thumbBase64 = previews.thumbBase64;
    } catch (_error) {
    }
    return payload;
  }

  /** 拉取云端 LUT 列表条目（名称+分享码，上传前重复校验/配额预检用）；
   * 失败抛错由调用方兜底。 */
  private async fetchCloudLutEntries(): Promise<CloudLutListItem[]> {
    const client = http.createHttp();
    try {
      const response = await client.request(LUT_API_BASE, {
        method: http.RequestMethod.GET,
        header: {
          'X-Upload-Token': LUT_UPLOAD_TOKEN,
          'X-User-Id': HuaweiAccountService.openId,
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 30000,
      });
      if (response.responseCode !== 200) {
        throw new Error('http ' + response.responseCode);
      }
      const parsed = JSON.parse(response.result as string) as CloudLutList;
      const items: CloudLutListItem[] = [];
      if (parsed.luts instanceof Array) {
        for (const item of parsed.luts) {
          if (typeof item.name === 'string' && item.name.length > 0) {
            items.push({
              name: item.name,
              shareCode: typeof item.shareCode === 'string' ? item.shareCode : '',
            });
          }
        }
      }
      return items;
    } finally {
      client.destroy();
    }
  }

  /** 在云端列表中查找同名条目；不存在返回 null。 */
  private findCloudEntry(entries: CloudLutListItem[], name: string): CloudLutListItem | null {
    for (const item of entries) {
      if (item.name === name) return item;
    }
    return null;
  }

  /** 上传期间向目标值缓动推进进度（网络阶段拿不到真实字节进度）。 */
  private startUploadProgressSim(from: number, to: number): void {
    this.stopUploadProgressSim();
    this.uploadProgressValue = from;
    this.uploadProgressTimerId = setInterval(() => {
      const remain = to - this.uploadProgressValue;
      if (remain <= 0.5) {
        this.uploadProgressValue = to;
        this.stopUploadProgressSim();
        return;
      }
      this.uploadProgressValue = this.uploadProgressValue + Math.max(0.6, remain * 0.1);
    }, 180);
  }

  private stopUploadProgressSim(): void {
    if (this.uploadProgressTimerId >= 0) {
      clearInterval(this.uploadProgressTimerId);
      this.uploadProgressTimerId = -1;
    }
  }

  private setUploadProgress(value: number, text: string): void {
    this.uploadProgressValue = value;
    this.uploadProgressText = text;
  }

  /** 上传自定义 LUT 到当前华为账号的云端空间（长按菜单入口）。
   * v3：JSON 载荷（cube 文本 + ≤1080P 预览图 + 作者 + 说明），
   * 服务端仅中转到 OBS，目录名 = 昵称_openID。 */
  private async uploadCustomLutToCloud(lut: CustomLut): Promise<void> {
    if (!lut.table) {
      this.showMessage('LUT 数据尚未加载，请稍后再试');
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await HuaweiAccountService.ensureLoaded(context);
    if (!HuaweiAccountService.isLoggedIn()) {
      this.showMessage('请先在「我的」页登录华为账号');
      return;
    }
    // 上传前校验：同名 LUT 已在云端则跳过，避免重复上传覆盖。
    let cloudEntries: CloudLutListItem[] = [];
    try {
      cloudEntries = await this.fetchCloudLutEntries();
    } catch (_error) {
      cloudEntries = [];
    }
    if (this.findCloudEntry(cloudEntries, lut.name) !== null) {
      this.showMessage('「' + lut.name + '」已在云端，无需重复上传');
      AppLogStore.add('lut upload skipped duplicate name=' + lut.name);
      return;
    }
    this.uploadProgressVisible = true;
    this.setUploadProgress(8, '正在上传「' + lut.name + '」…');
    const cubeText = this.buildLutCubeText(lut);
    this.setUploadProgress(24, '正在编码预览图…');
    const previews = await this.loadCloudPreviewPayload(context, lut);
    this.setUploadProgress(40, '正在上传到云端…');
    this.startUploadProgressSim(45, 90);
    const payload: Record<string, Object> = {
      'author': lut.author ?? '',
      'description': lut.description ?? '',
      'category': lut.category ?? '自定义',
      'cubeText': cubeText,
      'previewBase64': previews.previewBase64,
      'thumbBase64': previews.thumbBase64,
    };
    const raw = util.TextEncoder.create('utf-8').encode(JSON.stringify(payload));
    const client = http.createHttp();
    try {
      const requestUrl = LUT_API_BASE + '?user=' + encodeURIComponent(HuaweiAccountService.nickName) +
        '&name=' + encodeURIComponent(lut.name);
      const response = await client.request(requestUrl, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'X-Upload-Token': LUT_UPLOAD_TOKEN,
          'X-User-Id': HuaweiAccountService.openId,
        },
        extraData: raw.buffer as ArrayBuffer,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 60000,
      });
      this.stopUploadProgressSim();
      if (response.responseCode === 200) {
        this.setUploadProgress(100, '上传完成');
        this.showMessage('已上传「' + lut.name + '」到云端');
        AppLogStore.add('lut upload ok name=' + lut.name + ' bytes=' + raw.byteLength +
          ' preview=' + previews.previewBase64.length);
      } else if (response.responseCode === 503) {
        this.showMessage('服务器繁忙，请稍后再试');
        AppLogStore.add('lut upload server busy');
      } else if (response.responseCode === 429) {
        this.showMessage('云端 LUT 数量已达上限（20 个）');
        AppLogStore.add('lut upload rejected quota');
      } else {
        this.showMessage('上传失败（HTTP ' + response.responseCode + '）');
        AppLogStore.add('lut upload rejected http=' + response.responseCode);
      }
    } catch (error) {
      const err = error as BusinessError;
      this.showMessage('上传失败：' + (err.message !== undefined && err.message.length > 0 ? err.message : '网络错误'));
      AppLogStore.add('lut upload failed code=' + err.code);
    } finally {
      this.stopUploadProgressSim();
      this.uploadProgressVisible = false;
      client.destroy();
    }
  }

  /**
   * 分享 LUT 给其他 Pixelshop 用户：先校验云端——已上传且带分享码则直接
   * 复用标志符；否则上传到本人云端空间（受每用户 20 个上限约束，进度弹层），
   * 上传完成由服务器签发/复用唯一标志符 → 复制到剪贴板；标志符随索引写回，
   * 本人的云端 LUT 列表随之更新。
   */
  private async shareLutByCode(lut: CustomLut): Promise<void> {
    if (!lut.table) {
      this.showMessage('LUT 数据尚未加载，请稍后再试');
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await HuaweiAccountService.ensureLoaded(context);
    if (!HuaweiAccountService.isLoggedIn()) {
      this.showMessage('请先在「我的」页登录华为账号');
      return;
    }
    // 上传前校验 + 配额预检：已在云端且带分享码 → 直接复用，不再重复上传；
    // 新名称且云端已满 20 个 → 直接提示，避免白传大文件。
    let cloudEntries: CloudLutListItem[] = [];
    try {
      cloudEntries = await this.fetchCloudLutEntries();
    } catch (_error) {
      cloudEntries = [];
    }
    const existingEntry = this.findCloudEntry(cloudEntries, lut.name);
    if (existingEntry === null && cloudEntries.length >= 20) {
      this.showMessage('云端 LUT 数量已达上限（20 个），请先在「云LUT」中删除部分');
      return;
    }
    if (existingEntry !== null && existingEntry.shareCode !== undefined &&
      existingEntry.shareCode.length > 0) {
      const code = existingEntry.shareCode;
      lut.shareCode = code;
      LutLibraryStore.upsert(lut);
      await this.persistCustomLuts();
      try {
        const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, code);
        await pasteboard.getSystemPasteboard().setData(pasteData);
        this.showMessage('已在云端，LUT标志已复制：' + code);
      } catch (_error) {
        this.showMessage('已在云端，LUT标志：' + code);
      }
      AppLogStore.add('lut share reuse cloud code=' + code + ' name=' + lut.name);
      return;
    }
    // 走到这里：云端无此 LUT（正常上传），或已在云端但无分享码
    // （早期普通上传的条目，仍需 share=1 上传由服务器补发标志符）。
    this.uploadProgressVisible = true;
    this.setUploadProgress(6, '正在上传「' + lut.name + '」…');
    const cubeText = this.buildLutCubeText(lut);
    this.setUploadProgress(22, '正在编码预览图…');
    const previews = await this.loadCloudPreviewPayload(context, lut);
    this.setUploadProgress(40, '正在上传到云端…');
    this.startUploadProgressSim(45, 90);
    const payload: Record<string, Object> = {
      'author': lut.author ?? '',
      'description': lut.description ?? '',
      'category': lut.category ?? '自定义',
      'cubeText': cubeText,
      'previewBase64': previews.previewBase64,
      'thumbBase64': previews.thumbBase64,
    };
    const raw = util.TextEncoder.create('utf-8').encode(JSON.stringify(payload));
    const client = http.createHttp();
    try {
      const requestUrl = LUT_API_BASE + '?user=' + encodeURIComponent(HuaweiAccountService.nickName) +
        '&name=' + encodeURIComponent(lut.name) + '&share=1';
      const response = await client.request(requestUrl, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'X-Upload-Token': LUT_UPLOAD_TOKEN,
          'X-User-Id': HuaweiAccountService.openId,
        },
        extraData: raw.buffer as ArrayBuffer,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 60000,
      });
      this.stopUploadProgressSim();
      if (response.responseCode === 200) {
        this.setUploadProgress(96, '正在发布分享码…');
        let code = '';
        try {
          const parsed = JSON.parse(response.result as string) as CloudShareResult;
          code = parsed.code ?? '';
        } catch (_error) {
          code = '';
        }
        // 服务器签发的标志符持久化到本地条目，下次分享自动复用。
        if (code.length > 0) {
          lut.shareCode = code;
          LutLibraryStore.upsert(lut);
          await this.persistCustomLuts();
        }
        this.setUploadProgress(100, '分享完成');
        let copied = false;
        try {
          const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, code);
          await pasteboard.getSystemPasteboard().setData(pasteData);
          copied = true;
        } catch (_error) {
          copied = false;
        }
        if (code.length === 0) {
          this.showMessage('已上传到云端，但未获取到标志符');
        } else if (copied) {
          this.showMessage('已上传并复制LUT标志：' + code);
        } else {
          this.showMessage('已上传，LUT标志：' + code);
        }
        AppLogStore.add('lut share upload ok name=' + lut.name + ' code=' + code +
          ' bytes=' + raw.byteLength + ' preview=' + previews.previewBase64.length);
      } else if (response.responseCode === 503) {
        this.showMessage('服务器繁忙，请稍后再试');
        AppLogStore.add('lut share upload server busy');
      } else if (response.responseCode === 429) {
        this.showMessage('云端 LUT 数量已达上限（20 个）');
        AppLogStore.add('lut share upload rejected quota');
      } else {
        this.showMessage('分享失败（HTTP ' + response.responseCode + '）');
        AppLogStore.add('lut share upload rejected http=' + response.responseCode);
      }
    } catch (error) {
      const err = error as BusinessError;
      this.showMessage('分享失败：' + (err.message !== undefined && err.message.length > 0 ? err.message : '网络错误'));
      AppLogStore.add('lut share upload failed code=' + err.code);
    } finally {
      this.stopUploadProgressSim();
      this.uploadProgressVisible = false;
      client.destroy();
    }
  }

  /** 读取预览 JPEG 文件，生成最长边 ≤1080P 的预览图与 ≤256px 的缩略图。
   * 同一 PixelMap 连续缩放两次编码，失败抛异常由调用方兜底。 */
  private async encodeCloudPreview(previewPath: string): Promise<CloudPreviewPayload> {
    const previewFile = fileIo.openSync(previewPath, fileIo.OpenMode.READ_ONLY);
    let buffer: ArrayBuffer;
    try {
      const size = fileIo.statSync(previewFile.fd).size;
      buffer = new ArrayBuffer(size);
      fileIo.readSync(previewFile.fd, buffer);
    } finally {
      fileIo.closeSync(previewFile);
    }
    const source = image.createImageSource(buffer);
    try {
      const pixelMap = await source.createPixelMap({ editable: true });
      const payload = new CloudPreviewPayload();
      try {
        const info = await pixelMap.getImageInfo();
        const maxSide = Math.max(info.size.width, info.size.height);
        if (maxSide > 1080) {
          const scale = 1080 / maxSide;
          await pixelMap.scale(scale, scale);
        }
        const packer = image.createImagePacker();
        try {
          const preview = await packer.packing(pixelMap, { format: 'image/jpeg', quality: 85 });
          payload.previewBase64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(preview));
          // 缩略图：在预览图基础上继续缩到 ≤256px，低质量即可（弹层 48px 显示）。
          const scaledInfo = await pixelMap.getImageInfo();
          const scaledMax = Math.max(scaledInfo.size.width, scaledInfo.size.height);
          if (scaledMax > 256) {
            const thumbScale = 256 / scaledMax;
            await pixelMap.scale(thumbScale, thumbScale);
          }
          const thumb = await packer.packing(pixelMap, { format: 'image/jpeg', quality: 70 });
          payload.thumbBase64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(thumb));
        } finally {
          packer.release();
        }
      } finally {
        pixelMap.release();
      }
      return payload;
    } finally {
      source.release();
    }
  }

  private findCustomLut(name: string): CustomLut | undefined {    for (let index = 0; index < this.customLuts.length; index++) {
      if (this.customLuts[index].name === name) return this.customLuts[index];
    }
    return undefined;
  }

  private findAnyLut(name: string): CustomLut | undefined {
    const custom = this.findCustomLut(name);
    if (custom) return custom;
    for (let index = 0; index < this.bundledLuts.length; index++) {
      if (this.bundledLuts[index].name === name &&
        this.deletedBundledLutSources.indexOf(this.bundledLuts[index].sourceUri) < 0) {
        return this.bundledLuts[index];
      }
    }
    return undefined;
  }

  private bundledLutCategory(lut: CustomLut): string {
    const source = lut.sourceUri.toLowerCase();
    if (source.indexOf('/portrait/') >= 0) return '人像';
    if (source.indexOf('/film/') >= 0) return '电影';
    return '自然';
  }

  private allPresets(): Preset[] {
    const all: Preset[] = [];
    for (let index = 0; index < this.bundledLuts.length; index++) {
      const lut = this.bundledLuts[index];
      if (this.deletedBundledLutSources.indexOf(lut.sourceUri) < 0 &&
        (this.selectedLutCategory === '全部' || this.bundledLutCategory(lut) === this.selectedLutCategory)) {
        all.push(lut);
      }
    }
    if (this.selectedLutCategory === '全部') {
      for (let index = 0; index < this.customLuts.length; index++) all.push(this.customLuts[index]);
      // Keep the classic adjustment styles in the same picker as LUTs. A
      // style without a LUT still goes through the normal non-destructive
      // Camera Raw preset path when the user opens an image.
      for (let index = 0; index < PRESETS.length; index++) {
        const preset = PRESETS[index];
        if (!all.some((item: Preset) => item.name === preset.name)) all.push(preset);
      }
    }
    return all;
  }

  private actionLutTitle(): string {
    const target = this.lutActionsTarget;
    return target !== null ? `LUT「${target.name}」` : '';
  }

  /** 长按菜单：窄版自绘弹层（遮罩点击关闭，分享/删除两项）。 */
  @Builder
  LutActionsOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.28)')
        .onClick(() => { this.lutActionsTarget = null; })
      Column() {
        Text(this.actionLutTitle())
          .fontSize(11)
          .fontColor(this.mutedTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, left: 16, right: 16, bottom: 2 })
        Text('分享')
          .fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_1b2536'))
          .width('100%').height(46).textAlign(TextAlign.Center)
          .onClick(() => {
            const target = this.lutActionsTarget;
            this.lutActionsTarget = null;
            if (target !== null) this.shareCustomLut(target);
          })
        Divider().color(this.isNightMode ? 'rgba(255,255,255,0.12)' : 'rgba(23,32,48,0.10)')
        Text('分享给 Pixelshop 用户')
          .fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_1b2536'))
          .width('100%').height(46).textAlign(TextAlign.Center)
          .onClick(() => {
            const target = this.lutActionsTarget;
            this.lutActionsTarget = null;
            if (target !== null) this.shareLutByCode(target);
          })
        Divider().color(this.isNightMode ? 'rgba(255,255,255,0.12)' : 'rgba(23,32,48,0.10)')
        Text('上传LUT')
          .fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_1b2536'))
          .width('100%').height(46).textAlign(TextAlign.Center)
          .onClick(() => {
            const target = this.lutActionsTarget;
            this.lutActionsTarget = null;
            if (target !== null) this.uploadCustomLutToCloud(target);
          })
        Divider().color(this.isNightMode ? 'rgba(255,255,255,0.12)' : 'rgba(23,32,48,0.10)')
        Text('删除')
          .fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor('#C4485C')
          .width('100%').height(46).textAlign(TextAlign.Center)
          .onClick(() => {
            const target = this.lutActionsTarget;
            this.lutActionsTarget = null;
            if (target !== null) this.confirmDeleteSingleCustomLut(target);
          })
      }
      .width(this.isDesktop() ? 280 : 240)
      .borderRadius(20)
      .backgroundColor(this.isNightMode ? 'rgba(22,29,44,0.98)' : 'rgba(255,255,255,0.98)')
      .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.SYSTEM })
      .shadow({ radius: 30, color: 'rgba(10,16,30,0.35)', offsetY: 12 })
      .clip(true)
    }
    .width('100%')
    .height('100%')
  }

  /** 上传/分享进度弹层：全屏遮罩阻断操作 + 进度条 + 阶段文本（不可手动关闭）。 */
  @Builder
  UploadProgressOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.38)')
        .onClick(() => {})
      Column({ space: 12 }) {
        Text(this.uploadProgressText)
          .fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_1b2536'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Progress({ value: this.uploadProgressValue, total: 100, type: ProgressType.Linear })
          .width('100%')
          .color('#316CF4')
          .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.14)' : 'rgba(23,32,48,0.10)')
        Text(Math.ceil(this.uploadProgressValue).toString() + '%')
          .fontSize(11)
          .fontColor(this.mutedTextColor())
      }
      .alignItems(HorizontalAlign.Center)
      .width(this.isDesktop() ? 300 : 260)
      .padding(22)
      .borderRadius(20)
      .backgroundColor(this.isNightMode ? 'rgba(22,29,44,0.98)' : 'rgba(255,255,255,0.98)')
      .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.SYSTEM })
      .shadow({ radius: 30, color: 'rgba(10,16,30,0.35)', offsetY: 12 })
      .clip(true)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      this.LutContent();
      if (this.lutActionsTarget !== null) {
        this.LutActionsOverlay();
      }
      if (this.uploadProgressVisible) {
        this.UploadProgressOverlay();
      }
    }
    .width('100%')
    .height('100%')
  }
}
