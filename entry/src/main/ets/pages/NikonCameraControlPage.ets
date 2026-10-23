import { CameraControlView, CameraControlPageBridge } from './CameraControlPage';
import { CameraSessionStore } from '../services/CameraSessionStore';

/**
 * Nikon 的 PTP/IP 相机控制页。
 *
 * 与 Sony 控制页分开路由；底层复用 CameraControlView 与 NikonPtpIpService，
 * 传输协议不变。
 */
@Entry
@Component
struct NikonCameraControlPage {
  @State private valid: boolean = true;

  aboutToAppear(): void {
    // 本页只管控 Nikon：先锁定品牌，再把协议显式交给视图，不再依赖上一个页面
    // 可能残留的全局 controlProtocol。
    this.valid = CameraSessionStore.instance.cameraBrand === 'Nikon';
    if (this.valid) AppStorage.setOrCreate('controlProtocol', 'nikon');
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
      CameraControlView({ protocolOverride: 'nikon' })
    } else {
      Column({ space: 14 }) {
        Text('页面与机型线不匹配')
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF');
        Text('Nikon 控制页只接受 nikon，请返回相机页重新进入。')
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
