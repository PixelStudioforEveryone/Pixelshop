import { CameraControlView, CameraControlPageBridge } from './CameraControlPage';
import { CameraSessionStore } from '../services/CameraSessionStore';

/**
 * Lumix（Lab / Sync）相机控制页。
 *
 * 与 PTP/IP 线（Nikon / Sony）分成不同入口：视图仍是同一个 CameraControlView，
 * 但路由、返回拦截与取景恢复都由本页转发，协议层完全不变。
 */
@Entry
@Component
struct LumixCameraControlPage {
  @State private valid: boolean = true;
  @State private protocolValue: string = 'lab';

  aboutToAppear(): void {
    // 本页只管控 Panasonic：从全局取出 lab/sync 后显式传给视图，避免 PTP
    // 页面残留的 sony/nikon 模式被误用。
    const protocol = AppStorage.get<string>('controlProtocol');
    this.protocolValue = protocol === 'sync' ? 'sync' : 'lab';
    this.valid = CameraSessionStore.instance.cameraBrand === 'Panasonic';
    if (this.valid) AppStorage.setOrCreate('controlProtocol', this.protocolValue);
  }

  onPageShow(): void {
    const show = CameraControlPageBridge.show;
    if (show !== null) show();
  }

  onBackPress(): boolean {
    const back = CameraControlPageBridge.back;
    return back !== null ? back() : false;
  }

  build() {
    if (this.valid) {
      CameraControlView({ protocolOverride: this.protocolValue })
    } else {
      Column({ space: 14 }) {
        Text('页面与机型线不匹配')
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF');
        Text('Lumix 控制页只接受 lab / sync，请返回相机页重新进入。')
          .fontSize(12).fontColor('#9AA8BD').textAlign(TextAlign.Center);
        Button('返回')
          .onClick(() => { this.getUIContext().getRouter().back(); });
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#0B1017');
    }
  }
}
