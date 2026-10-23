import { ImageTransferView, ImageTransferPageBridge } from './ImageTransferPage';
import { CameraSessionStore } from '../services/CameraSessionStore';

/**
 * Nikon 的 PTP/IP 图片传输页。
 *
 * 与 Sony 图传页分开路由；底层复用 ImageTransferView + NikonPtpIpService，
 * 传输协议不变。
 */
@Entry
@Component
struct NikonImageTransferPage {
  @State private valid: boolean = CameraSessionStore.instance.cameraBrand === 'Nikon';

  onBackPress(): boolean {
    const back = ImageTransferPageBridge.back;
    return back !== null ? back() : false;
  }

  build() {
    if (this.valid) {
      ImageTransferView()
    } else {
      Column({ space: 14 }) {
        Text('页面与机型线不匹配')
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF');
        Text('Nikon 图传页只接受 Nikon，请返回相机页重新进入。')
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
