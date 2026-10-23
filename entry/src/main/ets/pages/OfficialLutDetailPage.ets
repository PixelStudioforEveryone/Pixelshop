import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import {
  LumixLutDetail,
  LumixCommunityStore,
  lumixImageUrl,
  lumixPhotoStyleName,
  lumixPhotoStyleDescription,
} from '../edit/models/LumixCommunity';
import { LutLibraryStore } from '../edit/models/LutLibrary';
import { RecentPhotoStore } from '../services/RecentPhotoStore';

/** 官方 LUT 详情：CDN 原图/效果图前后对比、简介、下载入库与用于编辑。 */
@Entry
@Component
struct OfficialLutDetailPage {
  @State private detail: LumixLutDetail | null = null;
  @State private loading: boolean = true;
  @State private imported: boolean = false;
  @State private downloading: boolean = false;
  @State private split: number = 0.5;
  @State private previewWidth: number = 1;
  private splitStart: number = 0.5;
  private lutCode: string = '';
  @StorageLink('vividNightMode') private isNightMode: boolean = false;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params !== null && typeof params['lutCode'] === 'string') {
      this.lutCode = params['lutCode'] as string;
    }
    this.loadDetail();
  }

  /** 从「导入 LUT」确认弹窗返回时刷新入库状态。 */
  onPageShow(): void {
    if (!this.loading && this.lutCode.length > 0) {
      this.refreshImported();
    }
  }

  private async loadDetail(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.detail = await LumixCommunityStore.loadDetail(context, this.lutCode);
    } catch (_error) {
      this.detail = null;
    }
    this.loading = false;
    await this.refreshImported();
  }

  private async refreshImported(): Promise<void> {
    this.imported = await LumixCommunityStore.isImported(this.lutCode);
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

  private formatDownloads(count: number): string {
    if (count >= 10000) {
      const wan = Math.round(count / 1000) / 10;
      return wan.toFixed(1) + ' 万次下载';
    }
    return count.toString() + ' 次下载';
  }

  private detailTitle(): string {
    const detail = this.detail;
    if (detail !== null && detail.title.length > 0) return detail.title;
    return this.lutCode;
  }

  private showMessage(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      console.info(message);
    }
  }

  /** 下载官方 LUT 并转入与相机导入一致的「导入 LUT」确认弹窗。 */
  private async downloadLut(): Promise<void> {
    if (this.downloading || this.imported) return;
    this.downloading = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const lut = await LumixCommunityStore.fetchOfficialLutForImport(context, this.lutCode);
      LutLibraryStore.setPending(lut);
      this.getUIContext().getRouter().pushUrl({ url: 'pages/LutImportConfirmPage' });
    } catch (error) {
      const err = error as Error;
      this.showMessage(err.message !== undefined && err.message.length > 0 ? err.message : '下载失败，请稍后再试');
    } finally {
      this.downloading = false;
    }
  }

  /** 选一张照片，打开编辑器并直接套用该 LUT（非破坏性图层）。 */
  private async choosePhotoForLut(): Promise<void> {
    if (!this.imported) {
      this.showMessage('请先下载入库后再用于编辑');
      return;
    }
    const lut = LutLibraryStore.find('official:' + this.lutCode);
    if (lut === undefined) {
      this.showMessage('LUT 尚未就绪，请稍后再试');
      return;
    }
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const result = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      if (!result.photoUris || result.photoUris.length === 0) return;
      const uri = result.photoUris[0];
      LutLibraryStore.upsert(lut);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await RecentPhotoStore.add(context, uri);
      await this.getUIContext().getRouter().pushUrl({
        url: 'pages/EditorPage',
        params: { imageUri: uri, presetName: '', customPresetJson: '', lutId: lut.id },
      });
    } catch (_error) {
      this.showMessage('无法打开图库');
    }
  }

  @Builder
  ComparePreview() {
    Stack() {
      if (this.detail !== null && this.detail.thumbPath.length > 0) {
        Image(lumixImageUrl(this.detail.thumbPath))
          .width('100%').height(300).objectFit(ImageFit.Cover)
          .alt($r('app.media.lut_sample_portrait'));
      } else {
        Image($r('app.media.lut_sample_portrait')).width('100%').height(300).objectFit(ImageFit.Cover);
      }
      if (this.detail !== null && this.detail.thumbOriginalPath.length > 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(lumixImageUrl(this.detail.thumbOriginalPath))
            .width(this.previewWidth).height(300).objectFit(ImageFit.Cover);
        }.width(this.previewWidth).height(300)
          .clip(new Rect({ width: this.previewWidth * this.split, height: 300 }))
          .position({ x: 0, y: 0 });
        Column() {
          Divider().vertical(true).height(300).strokeWidth(2).color('#FFFFFF');
          Circle().width(34).height(34).fill('#222222').stroke('#FFFFFF').strokeWidth(2)
            .position({ x: -17, y: 133 });
        }.width(2).height(300).position({ x: this.previewWidth * this.split, y: 0 })
          .hitTestBehavior(HitTestMode.None);
        Text('原图').fontSize(10).fontColor($r('app.color.vivid_text_ffffff')).position({ x: 10, y: 10 });
        Text('LUT').fontSize(10).fontColor($r('app.color.vivid_text_ffffff')).position({ x: '88%', y: 10 });
      }
    }
    .width('100%')
    .height(300)
    .clip(true)
    .borderRadius(18)
    .priorityGesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 1 })
      .onActionStart(() => { this.splitStart = this.split; })
      .onActionUpdate((event: GestureEvent) => {
        this.split = Math.max(0, Math.min(1, this.splitStart + event.offsetX / Math.max(1, this.previewWidth)));
      }))
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const width = Number(newArea.width);
      if (width > 0 && width !== this.previewWidth) this.previewWidth = width;
    });
  }

  build() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(34).fontWeight(FontWeight.Medium).fontColor(this.pageTextColor())
          .width(44).height(44).textAlign(TextAlign.Center)
          .onClick(() => { this.getUIContext().getRouter().back(); });
        Text(this.detailTitle())
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Blank().width(44);
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 6 });

      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(38).height(38).color(this.mutedTextColor());
          Text('正在加载 LUT 详情…').fontSize(12).fontColor(this.mutedTextColor());
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
      } else if (this.detail === null) {
        Column() {
          Text('未找到该 LUT').fontSize(14).fontColor(this.mutedTextColor());
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
      } else {
        Scroll() {
          Column() {
            Row({ space: 10 }) {
              if (this.detail.creatorIconPath.length > 0) {
                Image(lumixImageUrl(this.detail.creatorIconPath))
                  .width(38).height(38).borderRadius(19).objectFit(ImageFit.Cover);
              }
              Column({ space: 2 }) {
                Text(this.detail.creatorName.length > 0 ? this.detail.creatorName : 'Lumix Lab')
                  .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor())
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(this.formatDownloads(this.detail.downloads) +
                  (this.detail.photoStyle.length > 0 ?
                  ' · ' + lumixPhotoStyleName(this.detail.photoStyle) : ''))
                  .fontSize(11).fontColor(this.mutedTextColor());
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);
            }
            .width('100%').margin({ top: 4, bottom: 12 });

            this.ComparePreview();

            Row({ space: 12 }) {
              if (this.imported) {
                Button('选照片应用')
                  .fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.vivid_text_ffffff'))
                  .backgroundColor('#202A3B')
                  .height(44).layoutWeight(1)
                  .onClick(() => { this.choosePhotoForLut(); });
                Text('已入库')
                  .fontSize(12).fontColor(this.isNightMode ? '#8FD6B4' : '#1E8E5A')
                  .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                  .borderRadius(18)
                  .border({ width: 1, color: this.isNightMode ? 'rgba(143,214,180,0.45)' : 'rgba(30,142,90,0.35)' });
              } else if (this.downloading) {
                Row({ space: 8 }) {
                  LoadingProgress().width(18).height(18).color($r('app.color.vivid_text_ffffff'));
                  Text('正在下载入库…')
                    .fontSize(14).fontColor($r('app.color.vivid_text_ffffff'));
                }
                .height(44).layoutWeight(1).justifyContent(FlexAlign.Center)
                .backgroundColor('#202A3B').borderRadius(22);
              } else {
                Button('下载入库')
                  .fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.vivid_text_ffffff'))
                  .backgroundColor('#202A3B')
                  .height(44).layoutWeight(1)
                  .onClick(() => { this.downloadLut(); });
              }
            }
            .width('100%').margin({ top: 16, bottom: 6 });

            if (this.detail.overview.length > 0) {
              Text('关于此 LUT')
                .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
                .width('100%').margin({ top: 14, bottom: 7 });
              Text(this.detail.overview)
                .fontSize(13).fontColor(this.mutedTextColor()).lineHeight(20).width('100%');
            }

            if (this.detail.photoStyle.length > 0) {
              Text('基础照片格调')
                .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
                .width('100%').margin({ top: 16, bottom: 7 });
              Text('「' + lumixPhotoStyleName(this.detail.photoStyle) +
                '（' + this.detail.photoStyle + '）」')
                .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor())
                .width('100%').margin({ bottom: 5 });
              Text(lumixPhotoStyleDescription(this.detail.photoStyle))
                .fontSize(13).fontColor(this.mutedTextColor()).lineHeight(20).width('100%');
              Text('相机在使用实时 LUT 功能时，将依据此基础照片格调自动匹配对应的图像格调。')
                .fontSize(11).fontColor(this.mutedTextColor()).lineHeight(17)
                .width('100%').margin({ top: 8 });
            }
            Text('来自 Lumix Lab 社区 · 下载后可在「本机 LUT」的自定义库中管理')
              .fontSize(11).fontColor(this.mutedTextColor()).width('100%').margin({ top: 16 });
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 40 });
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
      colors: this.isNightMode
        ? [['#05070C', 0], ['#0D1017', 1]]
        : [['#F3F6FC', 0], ['#E9EFF9', 1]],
    });
  }
}
