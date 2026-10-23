import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  LumixFeaturedCreator,
  LumixGenre,
  LumixLutSummary,
  LumixCommunityStore,
  LumixCatalog,
  LumixLutIndex,
  lumixImageUrl,
  lumixSearchByName,
} from '../../edit/models/LumixCommunity';
import { CustomLut, LutLibraryStore, upsertCustomLut } from '../../edit/models/LutLibrary';
import { LutBridge } from './HomeShared';

/** 分区卡片信息：全部 LUT 与四个区域 TOP10。 */
interface LumixRegionCard {
  region: string;
  label: string;
  imagePath: string;
}

interface LumixRegionDef {
  region: string;
  label: string;
}

/** 搜索结果一次最多铺多少行，超出提示总数（目录本身只有数百条）。 */
const SEARCH_RESULT_LIMIT: number = 60;

/** CDN 缩略图加载失败后的自动重试间隔（毫秒）。只补几轮：真离线时不要把
 *  CDN 反复打爆，连上网络后自然就能换回真图。 */
const IMAGE_RETRY_DELAYS: number[] = [1500, 5000, 12000, 30000];

/** 官方 LUT 平铺区：每行两张卡，区域高度固定为两行，超出部分在区域内纵向滚动。 */
const TILE_COLUMNS: number = 2;
const TILE_GAP: number = 8;
const TILE_ASPECT: number = 1.7;
/** 目录分析（overview 关键字）缓存：键名分开存，便于单条失败后重试。 */
const KEYWORD_PREFS: string = 'vivid_lut_keyword_cache';
const KEYWORD_PORTRAIT_KEY: string = 'portraitCodesV2';
const KEYWORD_ANALYZED_KEY: string = 'analyzedCodesV2';

/** 风格库「官方 LUT」页签内容：顶部官方目录搜索 / 制作者头条 / 新 LUT 轮播 / 视频与照片分区。 */
@Component
export struct OfficialLutPanel {
  @State private featured: LumixFeaturedCreator | null = null;
  @State private newLuts: LumixLutSummary[] = [];
  @State private movieGenre: LumixGenre | null = null;
  @State private stillGenre: LumixGenre | null = null;
  /** 搜索框内容；非空时页面切换为官方目录检索结果。 */
  @State private searchQuery: string = '';
  @State private searchResults: LumixLutSummary[] = [];
  /** 命中总数（可能超过 SEARCH_RESULT_LIMIT，用于提示）。 */
  @State private searchMatched: number = 0;
  /** 可检索的官方目录：先用内置快照，网络目录到位后替换。 */
  @State private searchPool: LumixLutSummary[] = [];
  @State private searchOffline: boolean = true;
  @State private searchIndexReady: boolean = false;
  @State private importedCodes: string[] = [];
  @State private downloadingCode: string = '';
  /** 平铺用的全量官方 LUT（按下载量降序）。 */
  @State private movieAll: LumixLutSummary[] = [];
  @State private stillAll: LumixLutSummary[] = [];
  @State private tilesLoading: string = '';
  /** 照片 LUT 筛选：all / portrait / nature。 */
  @State private stillFilter: string = 'all';
  /** 照片 LUT 多选状态。 */
  @State private stillSelecting: boolean = false;
  @State private stillSelected: string[] = [];
  @State private batchDownloading: boolean = false;
  /** overview 关键字分析缓存（肤色/人像）。 */
  @State private portraitCodes: string[] = [];
  @State private analyzedCodes: string[] = [];
  @State private analyzingPortrait: boolean = false;
  /** 加载失败过的 CDN 缩略图（按图片路径记）。ArkUI 不会为同一个 src 的失败
   *  结果自动重试，失败过的那几张会一直停在 alt 占位图（「离线加载图」）上，
   *  必须换 src 才会重新请求，所以这里记住它们并在重试时换 URL 后缀。 */
  @State private failedImages: string[] = [];
  /** 图片重试代次：+1 会让所有失败过的图换一个新 URL 重新请求。 */
  @State private imageRetryEpoch: number = 0;
  private imageRetryIndex: number = 0;
  private imageRetryTimer: number = -1;
  @StorageLink('vividNightMode') private isNightMode: boolean = false;
  @StorageProp('windowWidth') private windowWidth: number = 390;
  @StorageProp('homeSection') private selectedSection: number = 0;
  @StorageProp('officialLutRefreshTick') @Watch('onRefreshTick') private refreshTick: number = 0;
  private newLutScroller: Scroller = new Scroller();
  private autoScrollTimer: number = -1;
  private scrollResumeTimer: number = -1;
  private scrollPaused: boolean = false;

  aboutToAppear(): void {
    this.resetImageRetries();
    this.loadEmbeddedInitial();
    this.refresh();
    this.loadSearchPools();
    this.loadTiles();
    this.loadKeywordCache();
    this.startAutoScroll();
  }

  /** 拉全量官方 LUT（视频 + 照片各一份），按下载量降序供平铺区使用。 */
  private async loadTiles(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    console.info('[VIVID] loadTiles start');
    this.tilesLoading = 'movie';
    try {
      const result = await LumixCommunityStore.loadGenreAll(context, 'movie');
      this.movieAll = result.items.slice().sort((a: LumixLutSummary, b: LumixLutSummary) => b.downloads - a.downloads);
      console.info('[VIVID] movie tiles=' + this.movieAll.length.toString() + ' offline=' + result.offline.toString());
    } catch (error) {
      console.info('[VIVID] movie tiles failed ' + JSON.stringify(error));
      this.movieAll = [];
    }
    this.tilesLoading = 'still';
    try {
      const result = await LumixCommunityStore.loadGenreAll(context, 'still');
      this.stillAll = result.items.slice().sort((a: LumixLutSummary, b: LumixLutSummary) => b.downloads - a.downloads);
      console.info('[VIVID] still tiles=' + this.stillAll.length.toString() + ' offline=' + result.offline.toString());
    } catch (error) {
      console.info('[VIVID] still tiles failed ' + JSON.stringify(error));
      this.stillAll = [];
    }
    this.tilesLoading = '';
    await this.refreshImportedFlags();
  }

  /** 已入库角标：把两个平铺区的官方条目统一标出来。 */
  private async refreshImportedFlags(): Promise<void> {
    if (LutBridge.ensureLutsLoaded !== null) {
      try {
        await LutBridge.ensureLutsLoaded();
      } catch (_error) {
      }
    }
    const imported: string[] = [];
    const all = this.movieAll.concat(this.stillAll);
    for (const item of all) {
      if (LutLibraryStore.find('official:' + item.code) !== undefined) imported.push(item.code);
    }
    this.importedCodes = imported;
  }

  /** 读 overview 关键字缓存（人像/风光筛选只分析一次）。 */
  private async loadKeywordCache(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = await preferences.getPreferences(context, KEYWORD_PREFS);
      const portrait = await store.get(KEYWORD_PORTRAIT_KEY, '[]');
      const analyzed = await store.get(KEYWORD_ANALYZED_KEY, '[]');
      if (typeof portrait === 'string') this.portraitCodes = JSON.parse(portrait) as string[];
      if (typeof analyzed === 'string') this.analyzedCodes = JSON.parse(analyzed) as string[];
    } catch (_error) {
      this.portraitCodes = [];
      this.analyzedCodes = [];
    }
  }

  private async saveKeywordCache(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = await preferences.getPreferences(context, KEYWORD_PREFS);
      await store.put(KEYWORD_PORTRAIT_KEY, JSON.stringify(this.portraitCodes));
      await store.put(KEYWORD_ANALYZED_KEY, JSON.stringify(this.analyzedCodes));
      await store.flush();
    } catch (_error) {
    }
  }

  /**
   * 逐条拉官方详情，检查「关于此 LUT」里是否出现「肤色」「人像」。
   * 只分析还没进缓存的条目；四条并发，避免一次打完 CDN。
   */
  private async analyzePortraitKeywords(): Promise<void> {
    if (this.analyzingPortrait) return;
    const pending = this.stillAll.filter((item: LumixLutSummary): boolean =>
      this.analyzedCodes.indexOf(item.code) < 0);
    if (pending.length === 0) return;
    this.analyzingPortrait = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const portrait: string[] = this.portraitCodes.slice();
    const analyzed: string[] = this.analyzedCodes.slice();
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < pending.length) {
        const index = cursor;
        cursor++;
        const item = pending[index];
        try {
          const detail = await LumixCommunityStore.loadDetail(context, item.code);
          // overview 为空说明这条走了离线兜底，先不记缓存，联网后再试。
          if (detail !== null && detail.overview.length > 0) {
            if (detail.overview.indexOf('肤色') >= 0 || detail.overview.indexOf('人像') >= 0 ||
              detail.overview.indexOf('人物') >= 0) {
              if (portrait.indexOf(item.code) < 0) portrait.push(item.code);
            }
            if (analyzed.indexOf(item.code) < 0) analyzed.push(item.code);
          }
        } catch (_error) {
        }
      }
    };
    const workers: Promise<void>[] = [];
    for (let i = 0; i < 4; i++) workers.push(worker());
    await Promise.all(workers);
    this.portraitCodes = portrait;
    this.analyzedCodes = analyzed;
    this.analyzingPortrait = false;
    await this.saveKeywordCache();
  }

  /** 当前筛选下要展示的照片 LUT。人像优先按下载量排（stillAll 已降序）。 */
  private stillItems(): LumixLutSummary[] {
    if (this.stillFilter === 'portrait') {
      return this.stillAll.filter((item: LumixLutSummary): boolean => this.portraitCodes.indexOf(item.code) >= 0);
    }
    if (this.stillFilter === 'nature') {
      return this.stillAll.filter((item: LumixLutSummary): boolean => this.portraitCodes.indexOf(item.code) < 0);
    }
    return this.stillAll;
  }

  /** 内容区宽度（LutPage 给的是 14/28 的左右内边距）。 */  private tilesContentWidth(): number {
    const padding = this.isDesktop() ? 56 : 28;
    return Math.max(240, this.windowWidth - padding);
  }

  private tileWidth(): number {
    return (this.tilesContentWidth() - TILE_GAP * (TILE_COLUMNS - 1)) / TILE_COLUMNS;
  }

  /** 卡片总高 = 图（1.7:1）+ 下方两行文字。 */
  private tileHeight(): number {
    return Math.round(this.tileWidth() / TILE_ASPECT) + 58;
  }

  /** 区域高度固定两行：正好看到四张完整卡片，其余在区域内纵向滚动。 */
  private tileAreaHeight(): number {
    return Math.round(this.tileHeight() * 2 + TILE_GAP);
  }

  private isStillSelected(code: string): boolean {
    return this.stillSelected.indexOf(code) >= 0;
  }

  private toggleStillSelection(code: string): void {
    if (this.isStillSelected(code)) {
      this.stillSelected = this.stillSelected.filter((item: string): boolean => item !== code);
    } else {
      this.stillSelected = this.stillSelected.concat([code]);
    }
  }

  private stillFilterActive(): boolean {
    return this.stillFilter !== 'all';
  }

  private async onStillFilterTap(next: string): Promise<void> {
    const target = this.stillFilter === next ? 'all' : next;
    this.stillFilter = target;
    if (target === 'portrait' || target === 'nature') {
      await this.analyzePortraitKeywords();
    }
  }

  private tileOf(code: string): LumixLutSummary | null {
    for (const item of this.stillAll) {
      if (item.code === code) return item;
    }
    return null;
  }

  /**
   * 批量下载：按当前筛选归类——人像筛选下的进「人像」，其余进「自然」。
   * 直接落库（不再逐张确认），失败条目留在原处可重试。
   */
  private async downloadSelectedToCategory(): Promise<void> {
    if (this.batchDownloading || this.stillSelected.length === 0) return;
    const category = this.stillFilter === 'portrait' ? '人像' : '自然';
    this.batchDownloading = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let ok = 0;
    let fail = 0;
    const codes = this.stillSelected.slice();
    // 按下载量降序落库：本地 人像/自然 行是「先入库的排前面」，
    // 用 stillAll（已按下载量降序）的顺序写，行里的顺序就跟着下载量走。
    const ordered: string[] = [];
    for (const item of this.stillAll) {
      if (codes.indexOf(item.code) >= 0) ordered.push(item.code);
    }
    for (const code of codes) {
      if (ordered.indexOf(code) < 0) ordered.push(code);
    }
    for (const code of ordered) {
      if (LutLibraryStore.find('official:' + code) !== undefined) {
        ok++;
        continue;
      }
      try {
        const lut = await LumixCommunityStore.fetchOfficialLutForImport(context, code);
        lut.category = category;
        await upsertCustomLut(context, lut as CustomLut);
        LutLibraryStore.upsert(lut);
        ok++;
      } catch (_error) {
        fail++;
      }
    }
    AppStorage.setOrCreate('lutImportRevision', Date.now());
    this.batchDownloading = false;
    this.stillSelecting = false;
    this.stillSelected = [];
    await this.refreshImportedFlags();
    const base = `已下载 ${ok} 个 LUT 到「${category}」`;
    this.showMessage(fail > 0 ? base + `，${fail} 个失败` : base);
  }

  aboutToDisappear(): void {
    this.stopAutoScroll();
    if (this.imageRetryTimer >= 0) {
      clearTimeout(this.imageRetryTimer);
      this.imageRetryTimer = -1;
    }
  }

  /** 壳页面切回风格库时触发一次立即刷新（页签挂载时 aboutToAppear 已刷新）。
   *  顺带给上次失败过的缩略图一次重新请求的机会。 */
  private onRefreshTick(): void {
    if (this.selectedSection !== 3) return;
    this.resetImageRetries();
    this.refresh();
  }

  /** 先用内置目录秒开，网络结果随后覆盖。 */
  private async loadEmbeddedInitial(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      if (this.featured === null) this.featured = await LumixCatalog.featured(context);
      if (this.newLuts.length === 0) this.newLuts = await LumixCatalog.newSummaries(context);
      if (this.movieGenre === null || this.stillGenre === null) {
        this.applyGenres(await LumixCatalog.genres(context));
      }
    } catch (_error) {
    }
  }

  private async refresh(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const featured = await LumixCommunityStore.loadFeatured(context);
      if (featured !== null) this.featured = featured;
    } catch (_error) {
    }
    try {
      const newLuts = await LumixCommunityStore.loadNew(context);
      if (newLuts.length > 0) this.newLuts = newLuts;
    } catch (_error) {
    }
    try {
      this.applyGenres(await LumixCommunityStore.loadGenres(context));
    } catch (_error) {
    }
  }

  private applyGenres(genres: LumixGenre[]): void {
    for (const genre of genres) {
      if (genre.code === 'movie') this.movieGenre = genre;
      if (genre.code === 'still') this.stillGenre = genre;
    }
  }

  /**
   * 搜索目录：内置官方快照先就位（离线也能按官网名称检索），再用
   * luts/filter 分页拉全的官方目录替换；网络失败时保留内置快照。
   */
  private async loadSearchPools(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (this.searchPool.length === 0) {
      try {
        const embedded = await LumixCatalog.allSummaries(context);
        if (this.searchPool.length === 0 && embedded.length > 0) {
          this.searchPool = embedded;
          this.searchOffline = true;
          this.searchIndexReady = true;
          if (this.isSearching()) this.runSearch();
        }
      } catch (_error) {
      }
    }
    try {
      const index: LumixLutIndex = await LumixCommunityStore.loadOfficialIndex(context);
      if (index.items.length > 0) {
        this.searchPool = index.items;
        this.searchOffline = index.offline;
        this.searchIndexReady = true;
        if (this.isSearching()) this.runSearch();
      }
    } catch (_error) {
    }
  }

  private isSearching(): boolean {
    return this.searchQuery.trim().length > 0;
  }

  /** 输入即检索：目录在内存里，逐键过滤比发请求更稳（220ms 内不会卡顿）。 */
  private onSearchChange(value: string): void {
    this.searchQuery = value;
    this.runSearch();
  }

  private runSearch(): void {
    const query = this.searchQuery.trim();
    if (query.length === 0) {
      this.searchResults = [];
      this.searchMatched = 0;
      this.importedCodes = [];
      return;
    }
    const matched = lumixSearchByName(this.searchPool, query);
    this.searchMatched = matched.length;
    this.searchResults = matched.slice(0, SEARCH_RESULT_LIMIT);
    this.refreshImported();
  }

  /** 标出已在「本机 LUT」里的官方条目，避免重复导入。 */
  private async refreshImported(): Promise<void> {
    if (LutBridge.ensureLutsLoaded !== null) {
      try {
        await LutBridge.ensureLutsLoaded();
      } catch (_error) {
      }
    }
    const imported: string[] = [];
    for (const item of this.searchResults) {
      if (LutLibraryStore.find('official:' + item.code) !== undefined) imported.push(item.code);
    }
    this.importedCodes = imported;
  }

  private isImported(code: string): boolean {
    return this.importedCodes.indexOf(code) >= 0;
  }

  private formatDownloads(count: number): string {
    if (count >= 10000) {
      const wan = Math.round(count / 1000) / 10;
      return wan.toFixed(1) + ' 万次下载';
    }
    return count.toString() + ' 次下载';
  }

  private showMessage(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      console.info(message);
    }
  }

  /** 缩略图地址：正常用 CDN 原地址。失败过的图分两级重试——第一轮只靠 ForEach
   *  换 key 重建节点（和切页签同效，重新发起请求）；若仍然失败，才换一个带
   *  后缀的地址，避免 CDN 对未知查询参数挑剔时反而把能加载的图弄坏。 */
  private imageSource(path: string): string {
    const url = lumixImageUrl(path);
    if (this.failedImages.indexOf(path) < 0) return url;
    if (this.imageRetryEpoch < 2) return url;
    return url + (url.indexOf('?') >= 0 ? '&' : '?') + 'retry=' +
      this.imageRetryEpoch.toString();
  }

  /** 记录一张失败的图并排下一轮重试。 */
  private markImageFailed(path: string): void {
    if (path.length === 0) return;
    if (this.failedImages.indexOf(path) < 0) {
      this.failedImages = this.failedImages.concat([path]);
      // 新出现的失败重新给满重试预算，避免预算耗尽后新图再也没有机会。
      this.imageRetryIndex = 0;
    }
    this.scheduleImageRetry();
  }

  /** 排一轮自动重试；IMAGE_RETRY_DELAYS 用完就不再排，避免离线时刷屏。 */
  private scheduleImageRetry(): void {
    if (this.imageRetryTimer >= 0) return;
    if (this.imageRetryIndex >= IMAGE_RETRY_DELAYS.length) return;
    const delay = IMAGE_RETRY_DELAYS[this.imageRetryIndex];
    this.imageRetryIndex += 1;
    this.imageRetryTimer = setTimeout(() => {
      this.imageRetryTimer = -1;
      this.imageRetryEpoch += 1;
    }, delay) as number;
  }

  /** 重置重试预算并让失败过的图立刻再试一次（挂载、切回风格库时调用）。 */
  private resetImageRetries(): void {
    this.imageRetryIndex = 0;
    if (this.imageRetryTimer >= 0) {
      clearTimeout(this.imageRetryTimer);
      this.imageRetryTimer = -1;
    }
    if (this.failedImages.length > 0) this.imageRetryEpoch += 1;
  }

  /** ForEach 键里的图片令牌：只有失败过的图会随重试代次换 key，因此重试时
   *  只重建这几项，已经加载好的图不受影响（不会整片闪一下占位图）。 */
  private imageToken(path: string): string {
    return this.failedImages.indexOf(path) >= 0 ? 'r' + this.imageRetryEpoch.toString() : 'ok';
  }

  /** 「新 LUT」是嵌套 ForEach：外层不重建时内层不会重新求值，所以任一新 LUT
   *  图失败过就换整组 key，让内层重新求值（只会发生在失败重试时）。 */
  private newLutImageToken(): string {
    for (const item of this.newLuts) {
      if (this.failedImages.indexOf(item.thumbPath) >= 0) {
        return 'r' + this.imageRetryEpoch.toString();
      }
    }
    return 'ok';
  }

  private isDesktop(): boolean {
    return this.windowWidth >= 840;
  }

  /** 平铺区数据：movie 用全量视频 LUT，still 走当前筛选（人像/风光/全部）。 */
  private tilesFor(genreCode: string): LumixLutSummary[] {
    return genreCode === 'movie' ? this.movieAll : this.stillItems();
  }

  private pageTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#172033';
  }

  private panelTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#1B2536';
  }

  private mutedTextColor(): string {
    return this.isNightMode ? '#9BA8BC' : '#8B96A6';
  }

  private pageBackground(): string {
    return this.isNightMode ? '#000000' : '#FFFFFF';
  }

  private startAutoScroll(): void {
    if (this.autoScrollTimer >= 0) return;
    this.autoScrollTimer = setInterval(() => {
      if (this.selectedSection !== 3 || this.scrollPaused) return;
      this.autoScrollNewLuts();
    }, 40) as number;
  }

  private stopAutoScroll(): void {
    if (this.autoScrollTimer >= 0) clearInterval(this.autoScrollTimer);
    this.autoScrollTimer = -1;
    if (this.scrollResumeTimer >= 0) clearTimeout(this.scrollResumeTimer);
    this.scrollResumeTimer = -1;
    this.scrollPaused = false;
  }

  /** 新 LUT 行匀速右移并在边界回绕（与本机 LUT 行同模式）；检索中不滚动。 */
  private autoScrollNewLuts(): void {
    if (this.isSearching()) return;
    const count = this.newLuts.length;
    if (count <= 2) return;
    try {
      const cardPitch = (this.isDesktop() ? 200 : 190) + 8;
      const cycleWidth = count * cardPitch;
      const offset = this.newLutScroller.currentOffset().xOffset;
      let next = offset + 0.7;
      if (next < cycleWidth) next += cycleWidth;
      if (next >= cycleWidth * 2) next -= cycleWidth;
      this.newLutScroller.scrollTo({ xOffset: next, yOffset: 0, animation: false });
    } catch (_error) {
    }
  }

  /** 组装分区行卡片：全部 LUT + 四个区域 TOP10。 */
  private regionCards(genre: LumixGenre | null): LumixRegionCard[] {
    const cards: LumixRegionCard[] = [{
      region: 'all',
      label: '全部 LUT',
      imagePath: genre !== null ? genre.thumbPath : '',
    }];
    const defs: LumixRegionDef[] = [
      { region: 'global', label: 'TOP10 全球' },
      { region: 'americas', label: 'TOP10 美洲' },
      { region: 'europe', label: 'TOP10 欧洲' },
      { region: 'oceania', label: 'TOP10 大洋洲' },
    ];
    for (const def of defs) {
      let imagePath = '';
      if (genre !== null) {
        for (const top of genre.tops) {
          if (top.region === def.region) imagePath = top.thumbPath;
        }
      }
      cards.push({ region: def.region, label: def.label, imagePath: imagePath });
    }
    return cards;
  }

  private genreFallbackMedia(genreCode: string): Resource {
    return genreCode === 'movie' ? $r('app.media.lumix_genre_movie') : $r('app.media.lumix_genre_still');
  }

  private openLutDetail(code: string): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/OfficialLutDetailPage',
      params: { lutCode: code },
    });
  }

  private openRegionList(genreCode: string, region: string): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/OfficialLutListPage',
      params: { genre: genreCode, region: region },
    });
  }

  private openCreatorDetail(creator: LumixFeaturedCreator): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/OfficialCreatorDetailPage',
      params: {
        creatorCode: creator.code,
        name: creator.name,
        introduction: creator.introduction,
        url: creator.url,
        iconPath: creator.iconPath,
      },
    });
  }

  /** 下载官方 LUT 并转入与相机导入一致的「导入 LUT」确认弹窗。 */
  private async downloadLut(item: LumixLutSummary): Promise<void> {
    if (this.downloadingCode.length > 0) return;
    if (this.isImported(item.code)) {
      this.showMessage('已在「本机 LUT」自定义库中');
      return;
    }
    this.downloadingCode = item.code;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const lut = await LumixCommunityStore.fetchOfficialLutForImport(context, item.code);
      LutLibraryStore.setPending(lut);
      this.getUIContext().getRouter().pushUrl({ url: 'pages/LutImportConfirmPage' });
    } catch (error) {
      const err = error as Error;
      this.showMessage(err.message !== undefined && err.message.length > 0 ? err.message : '下载失败，请稍后再试');
    } finally {
      this.downloadingCode = '';
    }
  }

  /** 顶部官方目录搜索框：按松下官网名称检索，输入即出结果。 */
  @Builder
  SearchBar() {
    Search({ value: this.searchQuery, placeholder: '搜索松下官方 LUT 名称，如 Daydream' })
      .width('100%')
      .height(42)
      .borderRadius(21)
      .backgroundColor(this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.78)')
      .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.9)' })
      .shadow({ radius: 14, color: this.isNightMode ? 'rgba(0,0,0,0.24)' : 'rgba(57,70,92,0.08)', offsetY: 5 })
      .placeholderColor(this.mutedTextColor())
      .placeholderFont({ size: 13 })
      .textFont({ size: 13 })
      .fontColor(this.panelTextColor())
      .searchIcon({ size: 16, color: this.mutedTextColor() })
      .cancelButton({ style: CancelButtonStyle.INPUT })
      .caretStyle({ width: 1.5, color: this.panelTextColor() })
      .enterKeyType(EnterKeyType.Search)
      .onChange((value: string) => { this.onSearchChange(value); })
      .margin({ top: 2 });
  }

  /** 结果行：缩略图 + 官网名称 + 制作者/下载量 + 直接下载。 */
  @Builder
  SearchResultRow(item: LumixLutSummary) {
    Row({ space: 12 }) {
      if (item.thumbPath.length > 0) {
        Image(this.imageSource(item.thumbPath))
          .width(88).height(64).objectFit(ImageFit.Cover).borderRadius(12)
          .alt($r('app.media.lut_sample_portrait'))
          .onError(() => { this.markImageFailed(item.thumbPath); });
      } else {
        Image($r('app.media.lut_sample_portrait'))
          .width(88).height(64).objectFit(ImageFit.Cover).borderRadius(12);
      }
      Column({ space: 4 }) {
        Text(item.title.length > 0 ? item.title : item.code)
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text((item.creatorName.length > 0 ? item.creatorName : 'Lumix Lab') +
          ' · ' + this.formatDownloads(item.downloads))
          .fontSize(11).fontColor(this.mutedTextColor())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
      if (this.isImported(item.code)) {
        Text('已入库')
          .fontSize(12).fontColor(this.isNightMode ? '#8FD6B4' : '#1E8E5A')
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(16)
          .border({ width: 1, color: this.isNightMode ? 'rgba(143,214,180,0.45)' : 'rgba(30,142,90,0.35)' });
      } else if (this.downloadingCode === item.code) {
        Row({ space: 6 }) {
          LoadingProgress().width(16).height(16).color(this.mutedTextColor());
          Text('下载中').fontSize(12).fontColor(this.mutedTextColor());
        }.padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(16);
      } else {
        Text('下载')
          .fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.vivid_text_ffffff'))
          .backgroundColor('#202A3B')
          .padding({ left: 16, right: 16, top: 7, bottom: 7 })
          .borderRadius(16)
          .onClick(() => { this.downloadLut(item); });
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(18)
    .backgroundColor(this.isNightMode ? 'rgba(13,16,23,0.55)' : 'rgba(255,255,255,0.55)')
    .backgroundBlurStyle(BlurStyle.Regular, { colorMode: ThemeColorMode.SYSTEM })
    .border({ width: 1, color: this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.75)' })
    .shadow({ radius: 18, color: 'rgba(57,70,92,0.10)', offsetY: 7 })
    .onClick(() => { this.openLutDetail(item.code); });
  }

  /** 检索结果区：标题 + 目录来源 + 行列表 / 空状态。 */
  @Builder
  SearchSection() {
    Column() {
      Row() {
        Text('官方 LUT 搜索')
          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor());
        Text(this.searchOffline ? ' · 内置目录' : ' · 松下官网目录')
          .fontSize(10).fontColor(this.mutedTextColor());
        Blank();
        Text(this.searchMatched.toString() + ' 个匹配')
          .fontSize(11).fontColor(this.mutedTextColor());
      }
      .width('100%')
      .margin({ top: 12, bottom: 8 });
      if (this.searchResults.length === 0) {
        Column({ space: 8 }) {
          Text(this.searchIndexReady ? '没有名称匹配的官方 LUT' : '正在读取官方 LUT 目录…')
            .fontSize(13).fontColor(this.pageTextColor());
          Text('试试松下官网上的英文名，例如 Daydream、Ionias、Old Cinema-S')
            .fontSize(11).fontColor(this.mutedTextColor()).textAlign(TextAlign.Center);
        }
        .width('100%')
        .padding({ top: 30, bottom: 34, left: 20, right: 20 });
      } else {
        Column({ space: 10 }) {
          ForEach(this.searchResults, (item: LumixLutSummary) => {
            this.SearchResultRow(item);
          }, (item: LumixLutSummary) => item.code + ':' +
            (this.isImported(item.code) ? '1' : '0') + ':' +
            (this.downloadingCode === item.code ? 'dl' : '') + ':' +
            item.downloads.toString() + ':' + item.thumbPath + ':' +
            this.imageToken(item.thumbPath));
        }
        .width('100%');
        if (this.searchMatched > this.searchResults.length) {
          Text('共 ' + this.searchMatched.toString() + ' 个匹配，先显示前 ' +
            this.searchResults.length.toString() + ' 个')
            .fontSize(10).fontColor(this.mutedTextColor())
            .width('100%').textAlign(TextAlign.Center).margin({ top: 10 });
        }
      }
    }
    .width('100%');
  }

  @Builder
  FeaturedHeader() {
    if (this.featured !== null) {
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.featured.thumbPath.length > 0) {
          Image(this.imageSource(this.featured.thumbPath))
            .width('100%').height(160).objectFit(ImageFit.Cover)
            .onError(() => { this.markImageFailed(this.featured === null ? '' : this.featured.thumbPath); });
        } else {
          Image($r('app.media.lumix_genre_movie')).width('100%').height(160).objectFit(ImageFit.Cover);
        }
        // 自上向下渐隐：图片向页面背景色过渡。
        Column()
          .width('100%').height(80)
          .linearGradient({
            angle: 180,
            colors: [['rgba(0,0,0,0)', 0], [this.pageBackground(), 1]] as [ResourceColor, number][],
          });
        Row({ space: 10 }) {
          if (this.featured.iconPath.length > 0) {
            Image(this.imageSource(this.featured.iconPath))
              .width(40).height(40).borderRadius(20).objectFit(ImageFit.Cover)
              .border({ width: 1.5, color: 'rgba(255,255,255,0.9)' })
              .onError(() => { this.markImageFailed(this.featured === null ? '' : this.featured.iconPath); });
          }
          Column({ space: 2 }) {
            Text(this.featured.name)
              .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor()).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
            Text(this.featured.introduction)
              .fontSize(11).fontColor(this.mutedTextColor()).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).lineHeight(14);
          }.alignItems(HorizontalAlign.Start).layoutWeight(1);
        }.width('100%').padding({ left: 16, right: 16, bottom: 12 }).alignItems(VerticalAlign.Center);
      }
      .width('100%').height(160).clip(true)
      .onClick(() => {
        const creator = this.featured;
        if (creator !== null) {
          this.openCreatorDetail(creator);
        }
      });
    }
  }

  @Builder
  OfficialLutCard(item: LumixLutSummary) {
    Column() {
      Stack() {
        if (item.thumbPath.length > 0) {
          Image(this.imageSource(item.thumbPath)).width('100%').height('100%').objectFit(ImageFit.Cover)
            .alt($r('app.media.lut_sample_portrait'))
            .onError(() => { this.markImageFailed(item.thumbPath); });
        } else {
          Image($r('app.media.lut_sample_portrait')).width('100%').height('100%').objectFit(ImageFit.Cover);
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
          Text(item.title.length > 0 ? item.title : item.code)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.panelTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(item.creatorName.length > 0 ? item.creatorName : 'Lumix Lab')
            .fontSize(8)
            .fontColor(this.mutedTextColor())
            .letterSpacing(0.6)
            .margin({ top: 3 });
        }
        .alignItems(HorizontalAlign.Start);
        Blank();
        Text('官方').fontSize(9).fontColor(this.mutedTextColor());
      }
      .width('100%')
      .height(44)
      .padding({ left: 3, right: 3, top: 6 });
    }
    .width(this.isDesktop() ? 200 : 190)
      .height(170)
    .padding(8)
    .borderRadius(22)
    .backgroundColor(this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.52)')
    .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.82)' })
    .shadow({ radius: 18, color: this.isNightMode ? 'rgba(0,0,0,0.28)' : 'rgba(57,70,92,0.10)', offsetY: 7 })
    .onClick(() => { this.openLutDetail(item.code); });
  }

  @Builder
  NewLutSection() {
    Column() {
      Text('新 LUT').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor())
        .width('100%').margin({ top: 6, bottom: 7 });
      Scroll(this.newLutScroller) {
        Row({ space: 8 }) {
          ForEach(this.newLuts.length > 2 ? [0, 1, 2] : [0], (copy: number) => {
            ForEach(this.newLuts, (item: LumixLutSummary) => { this.OfficialLutCard(item); },
              (item: LumixLutSummary) => item.code + ':' + copy.toString() + ':' +
                this.imageToken(item.thumbPath));
          }, (copy: number) => 'new:' + copy.toString() + ':' +
            this.newLuts.map((item: LumixLutSummary): string => item.code).join('|') + ':' +
            this.newLutImageToken());
        }.padding({ left: 1, right: 14 });
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
        .height(176).width('100%')
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.scrollPaused = true;
            if (this.scrollResumeTimer >= 0) clearTimeout(this.scrollResumeTimer);
            this.scrollResumeTimer = setTimeout(() => {
              this.scrollPaused = false;
              this.scrollResumeTimer = -1;
            }, 900) as number;
          }
          if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.scrollPaused = false;
            if (this.scrollResumeTimer >= 0) clearTimeout(this.scrollResumeTimer);
            this.scrollResumeTimer = -1;
          }
        });
    }.width('100%').margin({ top: 14 });
  }

  @Builder
  RegionCard(genreCode: string, card: LumixRegionCard) {
    Stack({ alignContent: Alignment.Bottom }) {
      if (card.imagePath.length > 0) {
        Image(this.imageSource(card.imagePath)).width('100%').height('100%').objectFit(ImageFit.Cover)
          .alt(this.genreFallbackMedia(genreCode))
          .onError(() => { this.markImageFailed(card.imagePath); });
      } else {
        Image(this.genreFallbackMedia(genreCode)).width('100%').height('100%').objectFit(ImageFit.Cover);
      }
      Column() {
        Text(card.label)
          .fontSize(11).fontWeight(FontWeight.Bold).fontColor($r('app.color.vivid_text_ffffff'));
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 22, bottom: 8 })
      .alignItems(HorizontalAlign.Start)
      .linearGradient({ angle: 180,
        colors: [['rgba(0,0,0,0)', 0], ['rgba(0,0,0,0.55)', 1]] });
    }
    .width(150)
    .height(118)
    .borderRadius(16)
    .clip(true)
    .shadow({ radius: 14, color: 'rgba(57,70,92,0.10)', offsetY: 5 })
    .onClick(() => { this.openRegionList(genreCode, card.region); });
  }

  /**
   * 旧的区域卡片行（TOP10 全球/美洲/欧洲/大洋洲）。
   * 按需求暂时不展示：保留实现，等区域榜单设计定稿再接回去。
   */
  @Builder
  GenreSection(title: string, genreCode: string, genre: LumixGenre | null) {
    Column() {
      Text(title).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor())
        .width('100%').margin({ top: 14, bottom: 7 });
      Scroll() {
        Row({ space: 10 }) {
          ForEach(this.regionCards(genre), (card: LumixRegionCard) => {
            this.RegionCard(genreCode, card);
          }, (card: LumixRegionCard) => genreCode + ':' + card.region + ':' + card.imagePath +
            ':' + this.imageToken(card.imagePath));
        }.padding({ left: 1, right: 14 });
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
        .height(122).width('100%');
    }.width('100%');
  }

  /**
   * 照片 LUT 的筛选行：全部 / 人像 / 风光 / 多选（多选态换成 退出多选 + 下载）。
   * 每个胶囊的选中态都在自身内部读 @State，不能作为 @Builder 参数传进来——
   * 按值传参的 builder 不会随状态刷新，会出现"内容切了、按钮没切"的假死。
   */
  @Builder
  StillFilterBar() {
    Row() {
      if (!this.stillSelecting) {
        Text('全部')
          .fontSize(11)
          .fontWeight(this.stillFilter === 'all' ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.stillFilter === 'all' ? $r('app.color.vivid_text_ffffff') : this.mutedTextColor())
          .height(28).padding({ left: 12, right: 12 }).borderRadius(14)
          .backgroundColor(this.stillFilter === 'all' ? '#202A3B'
            : (this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.72)'))
          .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.9)' })
          .margin({ left: 6 })
          .onClick(() => { this.stillFilter = 'all'; });
        Text('人像')
          .fontSize(11)
          .fontWeight(this.stillFilter === 'portrait' ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.stillFilter === 'portrait' ? $r('app.color.vivid_text_ffffff') : this.mutedTextColor())
          .height(28).padding({ left: 12, right: 12 }).borderRadius(14)
          .backgroundColor(this.stillFilter === 'portrait' ? '#202A3B'
            : (this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.72)'))
          .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.9)' })
          .margin({ left: 6 })
          .onClick(() => { this.onStillFilterTap('portrait'); });
        Text('风光')
          .fontSize(11)
          .fontWeight(this.stillFilter === 'nature' ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.stillFilter === 'nature' ? $r('app.color.vivid_text_ffffff') : this.mutedTextColor())
          .height(28).padding({ left: 12, right: 12 }).borderRadius(14)
          .backgroundColor(this.stillFilter === 'nature' ? '#202A3B'
            : (this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.72)'))
          .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.9)' })
          .margin({ left: 6 })
          .onClick(() => { this.onStillFilterTap('nature'); });
        Text('多选')
          .fontSize(11)
          .fontColor(this.mutedTextColor())
          .height(28).padding({ left: 12, right: 12 }).borderRadius(14)
          .backgroundColor(this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.72)')
          .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.9)' })
          .margin({ left: 6 })
          .onClick(() => {
            this.stillSelecting = true;
            this.stillSelected = [];
          });
      } else {
        Text('退出多选')
          .fontSize(11)
          .fontColor(this.mutedTextColor())
          .height(28).padding({ left: 12, right: 12 }).borderRadius(14)
          .backgroundColor(this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.72)')
          .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.9)' })
          .margin({ left: 6 })
          .onClick(() => {
            this.stillSelecting = false;
            this.stillSelected = [];
          });
        Text(this.stillSelected.length > 0 ? `下载(${this.stillSelected.length})` : '下载')
          .fontSize(11)
          .fontColor(this.stillSelected.length > 0
            ? $r('app.color.vivid_text_ffffff') : this.mutedTextColor())
          .height(28).padding({ left: 12, right: 12 }).borderRadius(14)
          .backgroundColor(this.stillSelected.length > 0 ? '#202A3B'
            : (this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(228,232,239,0.9)'))
          .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.9)' })
          .margin({ left: 6 })
          .onClick(() => { if (this.stillSelected.length > 0) this.downloadSelectedToCategory(); });
      }
    };
  }
  /** 平铺卡片：图 + 名称/作者·下载量；多选态右上角显示勾选圈。 */
  @Builder
  OfficialLutTile(item: LumixLutSummary, genreCode: string) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        if (item.thumbPath.length > 0) {
          Image(this.imageSource(item.thumbPath)).width('100%').height('100%').objectFit(ImageFit.Cover)
            .alt($r('app.media.lut_sample_portrait'))
            .onError(() => { this.markImageFailed(item.thumbPath); });
        } else {
          Image($r('app.media.lut_sample_portrait')).width('100%').height('100%').objectFit(ImageFit.Cover);
        }
        if (genreCode === 'still' && this.stillSelecting) {
          Stack() {
            if (this.isStillSelected(item.code)) {
              Text('✓').fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.vivid_text_ffffff'));
            }
          }
          .width(22).height(22).borderRadius(11)
          .backgroundColor(this.isStillSelected(item.code) ? '#316CF4' : 'rgba(255,255,255,0.9)')
          .border({ width: 1.2, color: this.isStillSelected(item.code) ? '#316CF4' : 'rgba(120,130,145,0.9)' })
          .margin(6);
        } else if (this.isImported(item.code)) {
          Text('已入库')
            .fontSize(9).fontColor($r('app.color.vivid_text_ffffff'))
            .backgroundColor('rgba(17,25,39,0.62)')
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .borderRadius(9)
            .margin(6);
        }
      }
      .width('100%')
      .layoutWeight(1)
      .borderRadius(14)
      .clip(true);

      Column() {
        Text(item.title.length > 0 ? item.title : item.code)
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text((item.creatorName.length > 0 ? item.creatorName : 'Lumix Lab') + ' · ' +
          this.formatDownloads(item.downloads))
          .fontSize(9).fontColor(this.mutedTextColor())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .height(44)
      .padding({ top: 6 });
    }
    .width('100%')
    .height(this.tileHeight())
    .padding(6)
    .borderRadius(18)
    .backgroundColor(this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.52)')
    .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.82)' })
    .shadow({ radius: 16, color: this.isNightMode ? 'rgba(0,0,0,0.26)' : 'rgba(57,70,92,0.09)', offsetY: 6 })
    .onClick(() => {
      if (genreCode === 'still' && this.stillSelecting) {
        this.toggleStillSelection(item.code);
        return;
      }
      this.openLutDetail(item.code);
    });
  }

  /** 两列网格：高度固定为两行卡片，其余在网格内部纵向滚动。 */
  /** 视频/照片 LUT 的标题行；照片这一行带人像/风光/多选。 */
  @Builder
  LutSectionHeader(title: string, genreCode: string) {
    Row() {
      Text(title)
        .fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor());
      Blank();
      if (genreCode === 'still') {
        this.StillFilterBar();
      }
    }
    .width('100%')
    .height(30)
    .margin({ top: 16, bottom: 8 });
  }

  /**
   * 两列平铺区：高度固定为两行卡片，其余在网格内部纵向滚动。
   * 注意这里不能把 LUT 数组当参数传进来——@Builder 按值传参不会随状态刷新，
   * 首次渲染拿到空数组后会一直显示空状态；必须在内部直接读 @State。
   */
  @Builder
  LutTileArea(genreCode: string) {
    if (this.analyzingPortrait && genreCode === 'still' && this.stillFilterActive() &&
      this.tilesFor(genreCode).length === 0) {
      Row({ space: 8 }) {
        LoadingProgress().width(16).height(16).color(this.mutedTextColor());
        Text('正在分析「关于此 LUT」…').fontSize(11).fontColor(this.mutedTextColor());
      }
      .width('100%')
      .height(this.tileAreaHeight())
      .justifyContent(FlexAlign.Center);
    } else if (this.tilesFor(genreCode).length === 0) {
      Column() {
        Text(this.tilesLoading.length > 0 ? '正在加载官方 LUT…' : '暂无内容')
          .fontSize(12).fontColor(this.mutedTextColor());
      }
      .width('100%')
      .height(this.tileAreaHeight())
      .justifyContent(FlexAlign.Center);
    } else {
      Grid() {
        ForEach(this.tilesFor(genreCode), (item: LumixLutSummary) => {
          GridItem() {
            this.OfficialLutTile(item, genreCode);
          }
        }, (item: LumixLutSummary) => genreCode + ':' + item.code + ':' +
          (this.isImported(item.code) ? '1' : '0') + ':' +
          (this.isStillSelected(item.code) ? 's' : 'o') + ':' +
          (this.stillSelecting ? 'm' : 'n') + ':' + this.imageToken(item.thumbPath));
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(TILE_GAP)
      .rowsGap(TILE_GAP)
      .width('100%')
      .height(this.tileAreaHeight())
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // 固定高度 + 裁切：不裁的话第三行会画到区域外面，露出半张卡。
      .clip(true)
      .nestedScroll({
        scrollForward: NestedScrollMode.SELF_FIRST,
        scrollBackward: NestedScrollMode.SELF_FIRST,
      });
    }
  }

  build() {
    Column() {
      this.SearchBar();
      if (this.isSearching()) {
        this.SearchSection();
      } else {
        this.FeaturedHeader();
        this.NewLutSection();
        // 照片 LUT 在上、视频 LUT 在下（人像/风光筛选挂在照片这一行）。
        this.LutSectionHeader('照片 LUT', 'still');
        this.LutTileArea('still');
        this.LutSectionHeader('视频 LUT', 'movie');
        this.LutTileArea('movie');
      }
    }.width('100%');
  }
}
