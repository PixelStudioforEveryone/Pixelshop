import { common } from '@kit.AbilityKit';
import {
  LumixLutSummary,
  LumixCommunityStore,
  lumixImageUrl,
} from '../edit/models/LumixCommunity';
import { LutLibraryStore } from '../edit/models/LutLibrary';
import { LutBridge } from './home/HomeShared';

/** 官方 LUT 列表子页：全部 LUT / 区域 TOP10，每行一个 LUT 并带下载按钮。 */
@Entry
@Component
struct OfficialLutListPage {
  @State private items: LumixLutSummary[] = [];
  @State private offline: boolean = false;
  @State private loading: boolean = true;
  @State private importedCodes: string[] = [];
  @State private downloadingCode: string = '';
  @State private headerTitle: string = '官方 LUT';
  @State private heroPath: string = '';
  @StorageLink('vividNightMode') private isNightMode: boolean = false;
  private genre: string = 'movie';
  private region: string = 'all';

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params !== null) {
      if (typeof params['genre'] === 'string') this.genre = params['genre'] as string;
      if (typeof params['region'] === 'string') this.region = params['region'] as string;
    }
    this.headerTitle = (this.genre === 'movie' ? '视频 LUT' : '照片 LUT') + ' · ' + this.regionLabel();
    this.loadList();
  }

  private regionLabel(): string {
    if (this.region === 'global') return 'TOP10 全球';
    if (this.region === 'americas') return 'TOP10 美洲';
    if (this.region === 'europe') return 'TOP10 欧洲';
    if (this.region === 'oceania') return 'TOP10 大洋洲';
    return '全部 LUT';
  }

  private async loadList(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const result = this.region === 'all'
        ? await LumixCommunityStore.loadGenreAll(context, this.genre)
        : await LumixCommunityStore.loadTop(context, this.genre, this.region);
      this.items = result.items;
      this.offline = result.offline;
      // 区域 TOP10 页以第一名 LUT 的示例图作背景（离线/全部列表不适用）。
      this.heroPath = this.region !== 'all' && !result.offline && result.items.length > 0
        ? result.items[0].thumbPath : '';
    } catch (_error) {
      this.items = [];
      this.offline = true;
    }
    this.loading = false;
    await this.refreshImported();
  }

  private async refreshImported(): Promise<void> {
    if (LutBridge.ensureLutsLoaded !== null) {
      try {
        await LutBridge.ensureLutsLoaded();
      } catch (_error) {
      }
    }
    const imported: string[] = [];
    for (const item of this.items) {
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

  private pageTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#172033';
  }

  private panelTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#1B2536';
  }

  private mutedTextColor(): string {
    return this.isNightMode ? '#9BA8BC' : '#8B96A6';
  }

  private showMessage(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      console.info(message);
    }
  }

  private openDetail(code: string): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/OfficialLutDetailPage',
      params: { lutCode: code },
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

  @Builder
  LutRow(item: LumixLutSummary) {
    Row({ space: 12 }) {
      if (item.thumbPath.length > 0) {
        Image(lumixImageUrl(item.thumbPath))
          .width(88).height(64).objectFit(ImageFit.Cover).borderRadius(12)
          .alt($r('app.media.lut_sample_portrait'));
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
    .onClick(() => { this.openDetail(item.code); });
  }

  build() {
    Stack() {
      if (this.heroPath.length > 0) {
        Image(lumixImageUrl(this.heroPath))
          .width('100%').height('100%').objectFit(ImageFit.Cover)
          .linearGradient({
            angle: 180,
            colors: this.isNightMode
              ? [['rgba(5,7,12,0)', 0], ['rgba(5,7,12,0.55)', 0.5], ['#0D1017', 1]]
              : [['rgba(243,246,252,0)', 0], ['rgba(243,246,252,0.55)', 0.5], ['#E9EFF9', 1]],
          });
      }
      Column() {
        Row() {
          Text('‹')
            .fontSize(34).fontWeight(FontWeight.Medium).fontColor(this.pageTextColor())
            .width(44).height(44).textAlign(TextAlign.Center)
            .onClick(() => { this.getUIContext().getRouter().back(); });
          Text(this.headerTitle)
            .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor())
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
          Blank().width(44);
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 10, bottom: 6 });
        if (this.offline) {
          Text('离线榜单：网络受限，当前为内置下载量排行')
            .fontSize(11).fontColor(this.mutedTextColor())
            .width('100%').textAlign(TextAlign.Center).margin({ top: 2, bottom: 4 });
        }
        if (this.loading) {
          Column({ space: 12 }) {
            LoadingProgress().width(38).height(38).color(this.mutedTextColor());
            Text('正在加载官方 LUT…').fontSize(12).fontColor(this.mutedTextColor());
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
        } else if (this.items.length === 0) {
          Column() {
            Text('暂无内容').fontSize(14).fontColor(this.mutedTextColor());
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
        } else {
          Scroll() {
            Column({ space: 10 }) {
              ForEach(this.items, (item: LumixLutSummary) => {
                this.LutRow(item);
              }, (item: LumixLutSummary) => item.code + ':' +
                (this.isImported(item.code) ? '1' : '0') + ':' +
                (this.downloadingCode === item.code ? 'dl' : '') + ':' +
                (this.heroPath.length > 0 ? 'hero' : ''));
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 40 });
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring);
        }
      }
      .width('100%')
      .height('100%')
      .safeAreaPadding({ top: 24 })
      .linearGradient({
        angle: 160,
        colors: this.heroPath.length > 0
          ? [['rgba(0,0,0,0)', 0], ['rgba(0,0,0,0)', 1]]
          : (this.isNightMode
            ? [['#05070C', 0], ['#0D1017', 1]]
            : [['#F3F6FC', 0], ['#E9EFF9', 1]]),
      });
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 160,
      colors: this.isNightMode
        ? [['#05070C', 0], ['#0D1017', 1]]
        : [['#F3F6FC', 0], ['#E9EFF9', 1]],
    });
  }
}
