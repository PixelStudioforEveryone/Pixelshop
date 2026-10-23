import { ComponentContent, UIContext } from '@kit.ArkUI';

/** 全局导出进度浮层。
 *
 * 状态保存在 AppStorage（vividExport* 键），Index 批量导出与 EditorPage
 * 单张导出通过 @StorageLink 写入同一份状态；浮层本体由 EntryAbility 在
 * 窗口加载完成后经 OverlayManager 挂到窗口最顶层，生命周期与窗口一致。
 * 这样无论从哪个页面发起、中途返回主界面或跳转其他页面，
 * 「正在导出」卡片和后台环形进度按钮都保持可见。 */

@Component
struct ExportOverlayPanel {
  @StorageLink('vividExportActive') private active: boolean = false;
  @StorageLink('vividExportBackgrounded') private backgrounded: boolean = false;
  @StorageLink('vividExportProgress') private progress: number = 0;
  @StorageLink('vividExportStatus') private status: string = '';
  @StorageLink('vividExportCancelRequested') private cancelRequested: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @StorageProp('windowWidth') private windowWidth: number = 390;

  build() {
    if (this.active) {
      Stack() {
        // 前台进度卡片：全屏遮罩，阻止误触页面内容。
        if (!this.backgrounded) {
          Column() {
            Column() {
              Text('正在导出').fontSize(17).fontWeight(FontWeight.Bold)
                .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_1b2536'));
              Text(this.status).fontSize(11).fontColor($r('app.color.vivid_text_718096')).maxLines(2)
                .margin({ top: 8 });
              Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
                .width('100%').height(8).color('#316CF4')
                .backgroundColor($r('app.color.vivid_surface_dce2ec'))
                .borderRadius(4).margin({ top: 18, bottom: 8 });
              Text(`${Math.round(this.progress)}%`).fontSize(12)
                .fontColor($r('app.color.vivid_text_316cf4'))
                .textAlign(TextAlign.End).width('100%');
              Row() {
                Button('后台导出')
                  .fontSize(12)
                  .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_536176'))
                  .type(ButtonType.Capsule)
                  .backgroundColor(this.isNightMode ? '#202A3B' : $r('app.color.vivid_surface_e7ecf4'))
                  .height(36)
                  .layoutWeight(1)
                  .onClick(() => {
                    if (this.active) this.backgrounded = true;
                  });
                Button('取消导出')
                  .fontSize(12)
                  .fontColor($r('app.color.vivid_text_ffffff'))
                  .type(ButtonType.Capsule)
                  .backgroundColor('#C4485C')
                  .height(36)
                  .layoutWeight(1)
                  .margin({ left: 10 })
                  .onClick(() => {
                    if (this.active) {
                      this.cancelRequested = true;
                      this.backgrounded = true;
                      this.status = '正在取消导出…';
                    }
                  });
              }
              .width('100%')
              .margin({ top: 16 });
            }
            .width(this.windowWidth >= 840 ? 620 : '82%').padding(22).borderRadius(20)
            .backgroundColor(this.isNightMode ? '#000000' : '#FFFFFF')
            .shadow({ radius: 28, color: 'rgba(40,55,82,0.22)', offsetY: 10 });
          }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor('rgba(22,30,45,0.28)')
          // 必须是 Default（自身+子节点响应，仅阻断兄弟节点）。这里原先是
          // HitTestMode.Block —— 按 SDK 文档 Block 会"阻断子节点的命中测试"，
          // 于是卡片里的「后台导出」「取消导出」永远收不到点击（用户反馈的
          // "后台导出按钮无效"）。Default 同时满足遮罩需求：点空白处命中的是
          // 本容器，页面（兄弟节点）被挡住。
          .hitTestBehavior(HitTestMode.Default);
        }
        // 后台导出：右下角悬浮圆形按钮，环形进度顺时针推进；点击恢复进度卡片。
        if (this.backgrounded) {
          Column() {
            Stack() {
              Column()
                .width(66)
                .height(66)
                .borderRadius(33)
                // 不用 backgroundBlurStyle：它的裁剪在部分版本不跟随圆角，会在
                // 圆形按钮外露出方形毛玻璃底（另一种"方框虚影"）。填充本身已是
                // 0.94/0.86 近不透明色，毛玻璃几乎没有视觉贡献。
                .backgroundColor(this.isNightMode ? 'rgba(16,22,34,0.86)' : 'rgba(255,255,255,0.94)');
              Progress({ value: this.progress, total: 100, type: ProgressType.Ring })
                .width(66)
                .height(66)
                .color('#316CF4')
                .backgroundColor('rgba(49,108,244,0.16)')
                .style({ strokeWidth: 6 });
              Text(this.cancelRequested ? '取消中' : `${Math.round(this.progress)}%`)
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_1b2536'));
            }
            .width(66)
            .height(66)
            // 阴影必须挂在圆角上：这是个 66×66 的方框 Stack，不写 borderRadius
            // 时阴影按正方形描边，就是用户看到的"方框虚影"。
            .borderRadius(33)
            .shadow({ radius: 18, color: 'rgba(40,55,82,0.26)', offsetY: 8 })
            .onClick(() => { this.backgrounded = false; });
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .alignItems(HorizontalAlign.End)
          .padding({ right: 20, bottom: 140 })
          .hitTestBehavior(HitTestMode.Transparent);
        }
      }
      .width('100%')
      .height('100%')
      // 根节点是整屏 Stack：它保持 Default 就会以整屏命中挡住兄弟节点（页面），
      // 于是后台化之后整个界面点不动、只剩右下角环形按钮可用。Transparent 让
      // 事件继续传给页面，同时保留子节点（环形按钮）自身的点击。
      .hitTestBehavior(this.backgrounded ? HitTestMode.Transparent : HitTestMode.Default);
    }
  }
}

@Builder
function exportOverlayBuilder(_: ExportOverlayParams) {
  ExportOverlayPanel()
}

class ExportOverlayParams {
}

export class ExportOverlay {
  private static content: ComponentContent<ExportOverlayParams> | null = null;

  /** 幂等挂载：窗口内容加载完成后调用一次即可。 */
  static mount(uiContext: UIContext): void {
    if (ExportOverlay.content !== null) return;
    const content = new ComponentContent<ExportOverlayParams>(uiContext,
      wrapBuilder(exportOverlayBuilder), new ExportOverlayParams());
    uiContext.getOverlayManager().addComponentContent(content);
    ExportOverlay.content = content;
  }
}
