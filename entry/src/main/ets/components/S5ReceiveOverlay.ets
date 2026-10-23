import { ComponentContent, UIContext } from '@kit.ArkUI';

/** 全局被动接收进度浮层（Sync 被动 wifiPTP 路线）。
 *
 * 相机推送图片时，接收进度不再以图片传输页的模态弹窗显示，而是经
 * OverlayManager 挂到窗口最顶层（与 ExportOverlay 同级），在任意页面
 * （含主页）都以顶部非阻塞悬浮卡片展示，用户可继续浏览其他内容。
 *
 * 状态由 CameraPage 的 PanasonicS5Receiver 回调同步写入 AppStorage
 * （vividS5* 键），浮层经 @StorageLink 实时刷新。 */

@Component
struct S5ReceiveOverlayPanel {
  @StorageLink('vividS5Receiving') private receiving: boolean = false;
  @StorageLink('vividS5Progress') private progress: number = 0;
  @StorageLink('vividS5Status') private status: string = '';
  @StorageLink('vividS5Files') private files: number = 0;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @StorageProp('windowWidth') private windowWidth: number = 390;

  build() {
    if (this.receiving) {
      Column() {
        Row() {
          Text('正在接收相机图片')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_1b2536'))
          Blank().layoutWeight(1)
          if (this.files > 0) {
            Text(`已接收 ${this.files} 个文件`)
              .fontSize(11)
              .fontColor(this.isNightMode ? $r('app.color.vivid_text_a9b2be') : $r('app.color.vivid_text_66758b'))
          }
        }
        .width('100%')
        Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(6)
          .color('#316CF4')
          .backgroundColor('rgba(49,108,244,0.16)')
          .borderRadius(3)
          .margin({ top: 8 })
        Text(this.status.length > 0 ? this.status : '相机正在发送文件，请稍候')
          .fontSize(10)
          .fontColor(this.isNightMode ? $r('app.color.vivid_text_a9b2be') : $r('app.color.vivid_text_718096'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })
      }
      .width(this.windowWidth >= 840 ? 420 : '86%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .borderRadius(14)
      .backgroundColor(this.isNightMode ? 'rgba(16,22,34,0.92)' : 'rgba(255,255,255,0.96)')
      .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.SYSTEM })
      .shadow({ radius: 18, color: 'rgba(40,55,82,0.26)', offsetY: 8 })
      .hitTestBehavior(HitTestMode.Block)
    }
  }
}

@Builder
function s5ReceiveOverlayBuilder(_: S5ReceiveOverlayParams) {
  Column() {
    S5ReceiveOverlayPanel()
  }
  .width('100%')
  .height('100%')
  .alignItems(HorizontalAlign.Center)
  .justifyContent(FlexAlign.Start)
  .padding({ top: 46 })
  // 容器自身不拦截触摸：除卡片本体外，页面其余区域照常可交互。
  .hitTestBehavior(HitTestMode.Transparent)
}

class S5ReceiveOverlayParams {
}

export class S5ReceiveOverlay {
  private static content: ComponentContent<S5ReceiveOverlayParams> | null = null;

  /** 幂等挂载：窗口内容加载完成后调用一次即可。 */
  static mount(uiContext: UIContext): void {
    if (S5ReceiveOverlay.content !== null) return;
    const content = new ComponentContent<S5ReceiveOverlayParams>(uiContext,
      wrapBuilder(s5ReceiveOverlayBuilder), new S5ReceiveOverlayParams());
    uiContext.getOverlayManager().addComponentContent(content);
    S5ReceiveOverlay.content = content;
  }
}
