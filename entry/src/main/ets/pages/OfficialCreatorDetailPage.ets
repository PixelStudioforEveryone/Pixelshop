import { common } from '@kit.AbilityKit';
import {
  LumixFeaturedCreator,
  LumixLutSummary,
  LumixCommunityStore,
  lumixImageUrl,
} from '../edit/models/LumixCommunity';

/** 制作者详情：头像+名称、简介、主页链接，其 LUT 一行两个平铺。 */
@Entry
@Component
struct OfficialCreatorDetailPage {
  @State private creatorName: string = '';
  @State private creatorIconPath: string = '';
  @State private introduction: string = '';
  @State private homeUrl: string = '';
  @State private luts: LumixLutSummary[] = [];
  @State private loading: boolean = true;
  private creatorCode: string = '';
  @StorageLink('vividNightMode') private isNightMode: boolean = false;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params !== null) {
      if (typeof params['creatorCode'] === 'string') {
        this.creatorCode = params['creatorCode'] as string;
      }
      if (typeof params['name'] === 'string') {
        this.creatorName = params['name'] as string;
      }
      if (typeof params['iconPath'] === 'string') {
        this.creatorIconPath = params['iconPath'] as string;
      }
      if (typeof params['introduction'] === 'string') {
        this.introduction = params['introduction'] as string;
      }
      if (typeof params['url'] === 'string') {
        this.homeUrl = params['url'] as string;
      }
    }
    this.refresh();
  }

  private async refresh(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const snapshot: LumixFeaturedCreator = {
      code: this.creatorCode,
      name: this.creatorName,
      url: this.homeUrl,
      introduction: this.introduction,
      iconPath: this.creatorIconPath,
      thumbPath: '',
      thumbOriginalPath: '',
    };
    try {
      const creator = await LumixCommunityStore.loadCreator(this.creatorCode, snapshot);
      if (creator !== null) {
        this.creatorName = creator.name;
        this.creatorIconPath = creator.iconPath;
        this.introduction = creator.introduction;
        if (creator.url.length > 0) this.homeUrl = creator.url;
      }
      this.luts = await LumixCommunityStore.loadCreatorLuts(context, this.creatorCode);
    } catch (_error) {
    }
    this.loading = false;
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

  private cardBackground(): string {
    return this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.78)';
  }

  private cardBorderColor(): string {
    return this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.9)';
  }

  private formatDownloads(count: number): string {
    if (count >= 10000) {
      const wan = Math.round(count / 1000) / 10;
      return wan.toFixed(1) + ' 万次下载';
    }
    return count.toString() + ' 次下载';
  }

  private openLutDetail(code: string): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/OfficialLutDetailPage',
      params: { lutCode: code },
    });
  }

  private showMessage(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      console.info(message);
    }
  }

  /** 打开制作者主页（系统浏览器）。 */
  private openHomeLink(): void {
    if (this.homeUrl.length === 0) return;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(this.homeUrl, { appLinkingOnly: false })
      .catch((_error: Error) => {
        this.showMessage('暂时无法打开主页链接');
      });
  }

  build() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(34).fontWeight(FontWeight.Medium).fontColor(this.pageTextColor())
          .width(44).height(44).textAlign(TextAlign.Center)
          .onClick(() => { this.getUIContext().getRouter().back(); });
        Text('制作者')
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Blank().width(44);
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 6 });

      Scroll() {
        Column() {
          Row({ space: 14 }) {
            if (this.creatorIconPath.length > 0) {
              Image(lumixImageUrl(this.creatorIconPath))
                .width(64).height(64).borderRadius(32).objectFit(ImageFit.Cover)
                .border({ width: 2, color: this.cardBorderColor() })
                .alt($r('app.media.lut_sample_portrait'));
            } else {
              Circle().width(64).height(64).fill(this.cardBackground());
            }
            Text(this.creatorName.length > 0 ? this.creatorName : 'Lumix Lab 创作者')
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor())
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
          }
          .width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 14 });

          if (this.introduction.length > 0) {
            Text(this.introduction)
              .fontSize(13).fontColor(this.mutedTextColor()).lineHeight(21).width('100%');
          }

          if (this.homeUrl.length > 0) {
            Row({ space: 7 }) {
              Text('主页')
                .fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(10)
                .backgroundColor(this.isNightMode ? '#31507E' : '#202A3B');
              Text(this.homeUrl)
                .fontSize(12).fontColor(this.isNightMode ? '#9FC2F0' : '#2E6DB4')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1);
            }
            .width('100%').alignItems(VerticalAlign.Center).margin({ top: 12 })
            .onClick(() => { this.openHomeLink(); });
          }

          Text('TA 的 LUT（' + this.luts.length.toString() + '）')
            .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
            .width('100%').margin({ top: 20, bottom: 10 });

          if (this.loading) {
            Column({ space: 10 }) {
              LoadingProgress().width(30).height(30).color(this.mutedTextColor());
              Text('正在加载 LUT…').fontSize(12).fontColor(this.mutedTextColor());
            }.width('100%').padding({ top: 30, bottom: 30 });
          } else if (this.luts.length === 0) {
            Text('暂无 LUT 作品')
              .fontSize(13).fontColor(this.mutedTextColor()).width('100%')
              .padding({ top: 24, bottom: 24 }).textAlign(TextAlign.Center);
          } else {
            Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
              ForEach(this.luts, (item: LumixLutSummary) => {
                Column() {
                  Stack() {
                    if (item.thumbPath.length > 0) {
                      Image(lumixImageUrl(item.thumbPath))
                        .width('100%').height('100%').objectFit(ImageFit.Cover)
                        .alt($r('app.media.lut_sample_portrait'));
                    } else {
                      Image($r('app.media.lut_sample_portrait'))
                        .width('100%').height('100%').objectFit(ImageFit.Cover);
                    }
                    Row().width('100%').height('100%').linearGradient({ angle: 90,
                      colors: [['rgba(0,0,0,0.05)', 0], ['rgba(0,0,0,0.5)', 1]] });
                  }
                  .width('100%')
                  .aspectRatio(1.5)
                  .borderRadius(14)
                  .clip(true);

                  Text(item.title)
                    .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor())
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%').margin({ top: 7 });
                  Text(this.formatDownloads(item.downloads))
                    .fontSize(11).fontColor(this.mutedTextColor())
                    .width('100%').margin({ top: 2 });
                }
                .width('50%')
                .padding({ left: 4, right: 4, bottom: 14 })
                .alignItems(HorizontalAlign.Start)
                .onClick(() => { this.openLutDetail(item.code); });
              }, (item: LumixLutSummary) => item.code);
            }
            .width('100%');
          }

          Text('来自 Lumix Lab 社区')
            .fontSize(11).fontColor(this.mutedTextColor()).width('100%').margin({ top: 6, bottom: 8 });
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 40 });
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .height('100%')
    .safeAreaPadding({ top: 24 })
    .linearGradient({
      angle: 160,
      colors: this.isNightMode
        ? [['#05070C', 0], ['#0D1017', 1]]
        : [['#F3F6FC', 0], ['#E9EFF9', 1]],
    });
  }
}
