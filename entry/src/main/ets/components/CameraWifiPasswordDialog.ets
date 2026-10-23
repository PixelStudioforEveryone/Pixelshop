import { CameraWifiPasswordPolicy } from '../services/CameraWifiPasswordPolicy';

export interface CameraWifiPasswordDialogOptions {
  ssid: string;
  securityType: number;
  message: string;
  onConfirm: (password: string) => void;
  onCancel: () => void;
}

/** The password lives in this dialog only; it is never put in AppStorage or logs. */
@Component
export struct CameraWifiPasswordDialog {
  @Prop wifiSsid: string = '';
  @Prop wifiSecurityType: number = 3;
  @Prop promptMessage: string = '';
  @StorageProp('vividNightMode') private nightMode: boolean = false;
  @State private wifiPasswordText: string = '';
  @State private inputError: string = '';
  @State private submitted: boolean = false;
  onConfirm: (password: string) => void = (_password: string): void => {};
  onCancel: () => void = (): void => {};

  private submitPassword(): void {
    if (this.submitted) return;
    this.inputError = CameraWifiPasswordPolicy.validationError(this.wifiSecurityType, this.wifiPasswordText);
    if (this.inputError.length > 0) return;
    this.submitted = true;
    const password = this.wifiPasswordText;
    this.wifiPasswordText = '';
    this.onConfirm(password);
  }

  aboutToDisappear(): void {
    this.wifiPasswordText = '';
  }

  build() {
    Column({ space: 16 }) {
      Text('输入相机 Wi-Fi 密码')
        .fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(this.nightMode ? '#FFFFFF' : '#151515');
      Text(this.wifiSsid)
        .fontSize(14).fontColor(this.nightMode ? '#FFFFFF' : '#151515')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
      Text(this.promptMessage.length > 0 ? this.promptMessage : '请填写相机显示的密码，然后在系统弹窗中确认信任。')
        .fontSize(12).fontColor(this.nightMode ? '#B7BCC5' : '#657286');
      TextInput({ placeholder: 'Wi-Fi 密码', text: this.wifiPasswordText })
        .id('cameraWifiPasswordInput')
        .type(InputType.Password).showPasswordIcon(true).maxLength(64)
        .height(48).fontSize(16)
        .fontColor(this.nightMode ? '#FFFFFF' : '#151515')
        .placeholderColor(this.nightMode ? '#A6ADB8' : '#657286')
        .backgroundColor(this.nightMode ? '#222630' : '#F0F2F5')
        .enabled(!this.submitted)
        .onChange((text: string): void => { this.wifiPasswordText = text; this.inputError = ''; })
        .onSubmit((): void => { this.submitPassword(); });
      if (this.inputError.length > 0) {
        Text(this.inputError).fontSize(12).fontColor(this.nightMode ? '#FFA5A5' : '#B52424');
      }
      Row({ space: 12 }) {
        Button('取消')
          .id('cameraWifiPasswordCancel').height(42).layoutWeight(1)
          .fontColor(this.nightMode ? '#FFFFFF' : '#151515')
          .backgroundColor(this.nightMode ? '#303541' : '#E8EBEF')
          .enabled(!this.submitted)
          .onClick((): void => { this.wifiPasswordText = ''; this.onCancel(); });
        Button('连接')
          .id('cameraWifiPasswordConfirm').height(42).layoutWeight(1)
          .fontColor('#FFFFFF').backgroundColor('#316CF4')
          .enabled(!this.submitted && this.wifiPasswordText.length > 0)
          .onClick((): void => { this.submitPassword(); });
      }
      .width('100%');
    }
    .width('100%').constraintSize({ maxWidth: 360 })
    .padding(24).borderRadius(20)
    .backgroundColor(this.nightMode ? '#111318' : '#FFFFFF')
    .alignItems(HorizontalAlign.Start);
  }
}
