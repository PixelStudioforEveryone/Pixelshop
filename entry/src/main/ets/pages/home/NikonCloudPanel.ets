import { webview } from '@kit.ArkWeb';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { NikonCloudBack } from './NikonCloudBack';

const NIKON_CLOUD_URL: string = 'https://imagingcloud.nikon.com/top/zh-cn/';

/** 风格库「尼康云创」页签：直接内嵌尼康云创官方手机版页面（仅浏览）。 */
@Component
export struct NikonCloudPanel {
  private controller: webview.WebviewController = new webview.WebviewController();
  @State private loading: boolean = true;
  @State private loadError: boolean = false;
  @State private progressValue: number = 0;
  @StorageLink('vividNightMode') private isNightMode: boolean = false;
  @StorageProp('homeSection') @Watch('onBackScopeChanged') private selectedSection: number = 0;
  @StorageProp('homeProfileVisible') @Watch('onBackScopeChanged') private profileVisible: boolean = false;
  @StorageProp('officialLutRefreshTick') @Watch('onRefreshTick') private refreshTick: number = 0;

  aboutToAppear(): void {
    // 把网页控制器交给返回桥：系统返回手势先让网页自己退历史。
    NikonCloudBack.attach(this.controller);
    this.syncBackVisible();
  }

  aboutToDisappear(): void {
    NikonCloudBack.detach(this.controller);
  }

  /** 只在「风格库」页签真正显示时，才让网页消费系统返回手势。 */
  private onBackScopeChanged(): void {
    this.syncBackVisible();
  }

  private syncBackVisible(): void {
    NikonCloudBack.setVisible(this.selectedSection === 3 && !this.profileVisible);
  }

  private onRefreshTick(): void {
    if (this.selectedSection !== 3) return;
    try {
      this.controller.refresh();
    } catch (_error) {
      // Web 尚未挂载时忽略，挂载后会自动加载。
    }
  }

  private reload(): void {
    this.loadError = false;
    this.loading = true;
    try {
      this.controller.refresh();
    } catch (_error) {
      try {
        this.controller.loadUrl(NIKON_CLOUD_URL);
      } catch (_inner) {
      }
    }
  }

  private openInBrowser(): void {
    try {
      // openLink 在 UIAbilityContext 上，getHostContext() 返回的是基类 Context。
      const host = this.getUIContext().getHostContext();
      if (host !== undefined) {
        const uiAbility = host as common.UIAbilityContext;
        uiAbility.openLink(NIKON_CLOUD_URL, { appLinkingOnly: false });
      }
    } catch (_error) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '无法打开浏览器' });
      } catch (_inner) {
      }
    }
  }

  private panelTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#1B2536';
  }

  private mutedTextColor(): string {
    return this.isNightMode ? '#9BA8BC' : '#8B96A6';
  }

  build() {
    Stack() {
      Column() {
        // 顶部细进度条：网页加载进度反馈。
        if (this.loading) {
          Progress({ value: this.progressValue, total: 100, type: ProgressType.Linear })
            .width('100%').height(2).color('#5262EC')
            .borderRadius(1);
        }
        Web({ src: NIKON_CLOUD_URL, controller: this.controller })
          .width('100%')
          .layoutWeight(1)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(false)
          .onControllerAttached(() => {
            // 以手机浏览器 UA 访问，命中官方移动版页面布局。
            try {
              this.controller.setCustomUserAgent(
                'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) ' +
                'Chrome/124.0.0.0 Mobile Safari/537.36');
            } catch (_error) {
            }
          })
          .onPageBegin(() => {
            this.loading = true;
            this.loadError = false;
          })
          .onProgressChange((event: OnProgressChangeEvent) => {
            this.progressValue = event.newProgress;
          })
          .onPageEnd(() => {
            this.loading = false;
            this.progressValue = 100;
          })
          .onErrorReceive((_event) => {
            this.loading = false;
            this.loadError = true;
            return false;
          })
          .overScrollMode(OverScrollMode.NEVER);
      }
      .width('100%')
      .height('100%');

      if (this.loadError) {
        Column({ space: 12 }) {
          Text('尼康云创页面加载失败')
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor());
          Text('请检查网络后重试，或直接在浏览器打开')
            .fontSize(11).fontColor(this.mutedTextColor());
          Row({ space: 10 }) {
            Text('重试')
              .fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.vivid_text_ffffff'))
              .height(36).padding({ left: 20, right: 20 })
              .borderRadius(18).backgroundColor('#202A3B')
              .onClick(() => { this.reload(); });
            Text('浏览器打开')
              .fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(this.panelTextColor())
              .height(36).padding({ left: 20, right: 20 })
              .borderRadius(18)
              .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.72)')
              .onClick(() => { this.openInBrowser(); });
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.isNightMode ? '#0D1017' : '#F3F6FC');
      }
    }
    .width('100%')
    .height('100%');
  }
}
