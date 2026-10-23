import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { LutLibraryStore } from '../../edit/models/LutLibrary';
import { PixelshopMarket, MarketLutMeta } from '../../edit/models/PixelshopMarket';
import { LutBridge } from './HomeShared';

/** 「粘贴好友的 LUT」弹层内容（从本机 LUT 页发起）：粘贴分享码 → 检索卡片 →
 *  复用官方下载导入链路。 */
@Component
export struct LutMarketPanel {
  @State private codeInput: string = '';
  @State private searching: boolean = false;
  @State private searchError: string = '';
  @State private result: MarketLutMeta | null = null;
  @State private resultPreview: image.PixelMap | null = null;
  @State private downloading: boolean = false;
  @State private importedCode: string = '';
  @StorageLink('vividNightMode') private isNightMode: boolean = false;

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
    }
  }

  private normalizeCode(raw: string): string {
    return raw.trim();
  }

  private async pasteFromClipboard(): Promise<void> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      const text = data !== null ? data.getPrimaryText() : '';
      if (text !== null && text.length > 0) {
        this.codeInput = this.normalizeCode(text);
      } else {
        this.showMessage('剪贴板中没有文本');
      }
    } catch (_error) {
      this.showMessage('读取剪贴板失败');
    }
  }

  private async searchMarket(): Promise<void> {
    const code = this.normalizeCode(this.codeInput);
    if (code.length === 0) {
      this.showMessage('请先粘贴 LUT 标志');
      return;
    }
    this.searching = true;
    this.searchError = '';
    this.releasePreview();
    this.result = null;
    this.importedCode = '';
    try {
      const meta = await PixelshopMarket.search(code);
      if (meta === null) {
        this.searchError = '未找到该标志对应的 LUT，请确认后重试';
      } else {
        this.result = meta;
        await this.decodePreview(meta.previewBase64);
        await this.refreshImported();
      }
    } catch (error) {
      const err = error as Error;
      this.searchError = err.message !== undefined && err.message.length > 0
        ? err.message : '搜索失败，请检查网络';
    } finally {
      this.searching = false;
    }
  }

  private async decodePreview(previewBase64: string): Promise<void> {
    if (previewBase64.length === 0) return;
    try {
      const bytes = new util.Base64Helper().decodeSync(previewBase64);
      const source = image.createImageSource(bytes.buffer);
      try {
        this.resultPreview = await source.createPixelMap();
      } finally {
        source.release();
      }
    } catch (_error) {
      this.resultPreview = null;
    }
  }

  private releasePreview(): void {
    if (this.resultPreview !== null) {
      this.resultPreview.release();
      this.resultPreview = null;
    }
  }

  private async refreshImported(): Promise<void> {
    const meta = this.result;
    if (meta === null) return;
    if (LutBridge.ensureLutsLoaded !== null) {
      try {
        await LutBridge.ensureLutsLoaded();
      } catch (_error) {
      }
    }
    this.importedCode = LutLibraryStore.find('market:' + meta.code) !== undefined ? meta.code : '';
  }

  /** 复用官方 LUT 下载导入链路：下载解析 → setPending → 确认弹窗。 */
  private async downloadMarketLut(): Promise<void> {
    const meta = this.result;
    if (meta === null || this.downloading) return;
    if (this.importedCode === meta.code) {
      this.showMessage('已在「本机 LUT」自定义库中');
      return;
    }
    this.downloading = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const lut = await PixelshopMarket.fetchMarketLutForImport(context, meta.code);
      LutLibraryStore.setPending(lut);
      this.getUIContext().getRouter().pushUrl({ url: 'pages/LutImportConfirmPage' });
    } catch (error) {
      const err = error as Error;
      this.showMessage(err.message !== undefined && err.message.length > 0
        ? err.message : '下载失败，请稍后再试');
    } finally {
      this.downloading = false;
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('粘贴好友分享的 LUT 标志（PS-XXXX-日期-数字），即可下载 TA 的 LUT')
        .fontSize(11).fontColor(this.mutedTextColor()).width('100%').margin({ top: 2 });
      Row({ space: 8 }) {
        TextInput({ text: this.codeInput, placeholder: '如 PS-K3F9-20261002-4820' })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(this.panelTextColor())
          .placeholderColor(this.mutedTextColor())
          .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.72)')
          .onChange((value: string) => { this.codeInput = value; })
        Text('粘贴')
          .fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(this.panelTextColor())
          .height(40)
          .padding({ left: 14, right: 14 })
          .borderRadius(20)
          .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.82)')
          .onClick(() => { this.pasteFromClipboard(); })
        Text('搜索')
          .fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.vivid_text_ffffff'))
          .height(40)
          .padding({ left: 16, right: 16 })
          .borderRadius(20)
          .backgroundColor('#202A3B')
          .onClick(() => { this.searchMarket(); })
      }.width('100%');

      if (this.searching) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color(this.mutedTextColor());
          Text('正在搜索…').fontSize(12).fontColor(this.mutedTextColor());
        }.width('100%').margin({ top: 6 });
      }
      if (this.searchError.length > 0) {
        Text(this.searchError).fontSize(12).fontColor('#C4485C').width('100%').margin({ top: 4 });
      }
      if (this.result !== null) {
        Column({ space: 10 }) {
          if (this.resultPreview !== null) {
            Image(this.resultPreview)
              .width('100%').height(180).objectFit(ImageFit.Cover).borderRadius(16);
          } else {
            Column() {
              Text('暂无预览图').fontSize(12).fontColor(this.mutedTextColor());
            }
            .width('100%').height(120).justifyContent(FlexAlign.Center)
            .borderRadius(16)
            .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.6)');
          }
          Column({ space: 4 }) {
            Text(this.result.name.length > 0 ? this.result.name : this.result.code)
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
            Text('作者：' + (this.result.author.length > 0 ? this.result.author : 'Pixelshop 用户'))
              .fontSize(12).fontColor(this.mutedTextColor());
            if (this.result.description.length > 0) {
              Text(this.result.description)
                .fontSize(12).fontColor(this.mutedTextColor())
                .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis });
            }
          }.alignItems(HorizontalAlign.Start).width('100%');

          if (this.importedCode === this.result.code) {
            Text('已入库')
              .fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(this.isNightMode ? '#8FD6B4' : '#1E8E5A')
              .width('100%').height(42).textAlign(TextAlign.Center)
              .borderRadius(21)
              .border({ width: 1, color: this.isNightMode ? 'rgba(143,214,180,0.45)' : 'rgba(30,142,90,0.35)' });
          } else if (this.downloading) {
            Row({ space: 8 }) {
              LoadingProgress().width(18).height(18).color($r('app.color.vivid_text_ffffff'));
              Text('下载中…').fontSize(13).fontColor($r('app.color.vivid_text_ffffff'));
            }
            .width('100%').height(42).justifyContent(FlexAlign.Center)
            .borderRadius(21).backgroundColor('#202A3B');
          } else {
            Text('下载')
              .fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.vivid_text_ffffff'))
              .width('100%').height(42).textAlign(TextAlign.Center)
              .borderRadius(21).backgroundColor('#5262EC')
              .onClick(() => { this.downloadMarketLut(); });
          }
        }
        .width('100%')
        .padding(14)
        .borderRadius(20)
        .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.55)')
        .backgroundBlurStyle(BlurStyle.Regular, { colorMode: ThemeColorMode.SYSTEM })
        .border({ width: 1, color: this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.82)' })
        .margin({ top: 4 });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: 24 });
  }
}
