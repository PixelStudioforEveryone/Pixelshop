import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { VividMaterial } from '../../components/VividMaterial';
import { CameraSessionStore } from '../../services/CameraSessionStore';
import { LumixImportPrototype } from '../../services/LumixImportPrototype';
import { HuaweiAccountService } from '../../services/HuaweiAccountService';
import { CustomLut, parseLutText } from '../../edit/models/LutLibrary';
import { AppLogStore, NavColorService, LutBridge } from './HomeShared';
import { AppLogPolicy } from '../../services/AppLogPolicy';

// 问题反馈「发送日志」目标：阿里云 ECS 上的 Node.js 接收端（server/log-receiver.js）。
// pixelshop.cloud 备案通过后切换为 HTTPS 域名。
const LOG_UPLOAD_URL: string = 'https://your-server.example.com/api/logs';
// 用户 LUT 云存储接口（同一台服务器，按华为账号 openID 隔离目录）。
const LUT_API_BASE: string = 'https://your-server.example.com/api/luts';
// 上报令牌：与服务器端 UPLOAD_TOKEN 保持一致，仅用于日志上报鉴权（非云平台密钥）。
const LOG_UPLOAD_TOKEN: string = 'vivid-log-Kq7fXm2Rt9Lw4Zb8';

/** 云端 LUT 列表条目（GET /api/luts 响应）。 */
class CloudLutEntry {
  name: string = '';
  bytes: number = 0;
  updatedAt: number = 0;
  hasPreview: boolean = false;
  author: string = '';
  category: string = '';
}

/** GET /api/luts 响应根对象。 */
class CloudLutList {
  luts: CloudLutEntry[] = [];
}

/** 云 LUT 弹层行数据：列表条目 + 缩略图（预览图缺失时为 null）。 */
class CloudLutRow {
  entry: CloudLutEntry;
  thumb: image.PixelMap | null = null;

  constructor(entry: CloudLutEntry) {
    this.entry = entry;
  }
}

/** GET /api/luts/file 响应：cube 文本 + 作者 + 说明 + 分类 + 预览图（JPEG base64）。 */
class CloudLutFile {
  name: string = '';
  cubeText: string = '';
  author: string = '';
  description: string = '';
  category: string = '';
  previewBase64: string = '';
}

/** 首页「我的」页：个人中心、问题反馈、特别鸣谢、支持作者与联系我们子页。 */
@Component
export struct ProfileSection {
  // 相机会话的共享状态：图片传输页面与首页持有同一实例。
  @State private cam: CameraSessionStore = CameraSessionStore.instance;
  // LUT 页面右侧的个人中心与反馈子页状态。
  @StorageLink('homeProfileSubpage') private profileSubpage: number = 0; // 0=个人中心，1=问题反馈，2=特别鸣谢，3=支持作者，4=联系我们
  @State private profileName: string = '像素工坊用户';
  @State private profileAvatarUri: string = '';
  // 「背景图片滚动」：默认关闭；关闭时不显示背景图片，开启后用最近作品
  // 的高清缓存帧滚动。持久化在 pixelshop_profile 中。
  @StorageLink('homeBackdropEnabled') private backdropScrollEnabled: boolean = false;
  // 「浮动导航栏」：默认关闭 = 底部固定导航栏；开启 = 浮动圆环。
  // Index 按这个键二选一挂载导航层，ProfileSection 负责持久化。
  @StorageLink('homeFloatingNav') private floatingNavEnabled: boolean = false;
  @State private feedbackExportStatus: string = '';
  // 「发送日志」预览弹层：logSendPreviewText 非空时在页面之上显示。
  @State private logSendPreviewText: string = '';
  @State private logSendResult: string = '';
  @State private logSending: boolean = false;
  /** 上传到开发者服务器需要华为账号；「复制日志」不需要。两者分开控制。 */
  @State private logSendLoggedIn: boolean = false;
  /** 复制结果提示（成功/失败/已截断）。 */
  @State private logSendCopyHint: string = '';
  // 华为账号会话镜像（真实状态在 HuaweiAccountService，此处仅为驱动 UI 刷新）。
  @State private hwLoggedIn: boolean = false;
  @State private hwNickName: string = '';
  @State private hwAvatarUri: string = '';
  @State private lutSyncing: boolean = false;
  @State private lutSyncStatus: string = '';
  // 「云LUT」弹层：云端列表（含缩略图）、状态文本与操作互斥锁。
  @State private cloudPanelOpen: boolean = false;
  @State private cloudRows: CloudLutRow[] = [];
  @State private cloudPanelStatus: string = '';
  private cloudBusy: boolean = false;
  private logDeviceId: string = '';
  private profilePreferences: preferences.Preferences | null = null;
  @StorageLink('vividNightMode') private isNightMode: boolean = false;
  @StorageProp('windowWidth') private windowWidth: number = 390;
  @StorageLink('homeNavCollapsed') private navCollapsed: boolean = false;

  aboutToAppear(): void {
    this.loadProfile();
    this.restoreHuaweiSession();
  }

  /** 从持久化会话恢复华为登录态，刷新本页镜像状态。 */
  private restoreHuaweiSession(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    HuaweiAccountService.ensureLoaded(context).then(() => {
      this.refreshHuaweiUiState();
    });
  }

  private refreshHuaweiUiState(): void {
    this.hwLoggedIn = HuaweiAccountService.isLoggedIn();
    this.hwNickName = HuaweiAccountService.nickName;
    this.hwAvatarUri = HuaweiAccountService.avatarUri;
  }

  private scheduleNavColorRefresh(): void {
    NavColorService.schedule(this.getUIContext());
  }

  private isDesktop(): boolean {
    return this.windowWidth >= 840;
  }

  /** 任一主页面下滑时导航栏收缩为右侧「我的」小胶囊，上滑或点击胶囊恢复完整导航。 */
  private updateNavCollapse(yOffset: number): void {
    if (yOffset > 4) {
      if (!this.navCollapsed) {
        // geometryTransition 形变必须由 animateTo 驱动，时长曲线跟随此处配置。
        this.getUIContext().animateTo({ duration: 500, curve: Curve.EaseOut }, () => {
          this.navCollapsed = true;
        });
      }
    } else if (yOffset < -4) {
      if (this.navCollapsed) {
        this.getUIContext().animateTo({ duration: 500, curve: Curve.EaseOut }, () => {
          this.navCollapsed = false;
        });
      }
    }
  }

  private showMessage(message: string): void {
    AppLogStore.add('ui ' + message);
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      console.info(message);
    }
  }

  private pageTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#172033';
  }

  private cardMaterial(): VividMaterial {
    return this.isNightMode ? VividMaterial.cardNight : VividMaterial.card;
  }

  private panelTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#1B2536';
  }

  private secondaryTextColor(): string {
    return this.isNightMode ? '#D1D9E8' : '#526078';
  }

  private mutedTextColor(): string {
    return this.isNightMode ? '#B7C3D6' : '#7B8798';
  }

  @Builder
  ProfilePage() {
    // Keep the shared page backdrop visible through every surface. The other
    // three sections use VividMaterial.card; the profile page follows the same
    // spacing and material hierarchy instead of painting an opaque full-screen
    // white/black sheet over the backdrop.
    Scroll() {
      Column() {
        if (this.profileSubpage === 0) {
          Column() {
            Text('账号信息').fontSize(14).fontWeight(FontWeight.Bold)
              .fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Row() {
              if (this.hwAvatarUri.length > 0) {
                Image(this.hwAvatarUri)
                  .width(72).height(72).borderRadius(36).objectFit(ImageFit.Cover);
              } else if (this.profileAvatarUri.length > 0) {
                Image(this.profileAvatarUri)
                  .width(72).height(72).borderRadius(36).objectFit(ImageFit.Cover);
              } else {
                Stack({ alignContent: Alignment.Center }) {
                  Text('P').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FFFFFF');
                }
                .width(72).height(72).borderRadius(36).backgroundColor('#316CF4');
              }
              Column() {
                Text(this.hwLoggedIn
                  ? (this.hwNickName.length > 0 ? this.hwNickName : '华为用户')
                  : (this.profileName.length > 0 ? this.profileName : '像素工坊用户'))
                  .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(this.hwLoggedIn ? '华为账号 · 支持云端同步 LUT' : '个人中心')
                  .fontSize(12).fontColor(this.secondaryTextColor()).margin({ top: 6 });
              }
              .alignItems(HorizontalAlign.Start).margin({ left: 14 });
              Blank();
              if (!this.hwLoggedIn) {
                Button('编辑')
                  .type(ButtonType.Capsule).height(32).fontSize(11)
                  .fontColor(this.isNightMode ? '#DDE8FF' : '#316CF4')
                  .backgroundColor(this.isNightMode ? 'rgba(49,108,244,0.28)' : 'rgba(232,238,255,0.86)')
                  .onClick(() => { this.chooseProfileAvatar(); });
              }
            }.width('100%');
            Row().width('100%').height(1).backgroundColor('rgba(255,255,255,0.24)').margin({ top: 18, bottom: 14 });
            if (this.hwLoggedIn) {
              // 已登录华为账号：原「你的名称」编辑框替换为「同步LUT」入口。
              Row() {
                Column() {
                  Text('同步LUT').fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(this.panelTextColor());
                  Text('从云端下载你的自定义 LUT（同名跳过）').fontSize(11)
                    .fontColor(this.mutedTextColor()).margin({ top: 4 });
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1);
                Button('云LUT')
                  .type(ButtonType.Capsule).height(32).fontSize(12)
                  .fontColor(this.isNightMode ? '#DDE8FF' : '#316CF4')
                  .backgroundColor(this.isNightMode ? 'rgba(49,108,244,0.28)' : 'rgba(232,238,255,0.86)')
                  .margin({ left: 12 })
                  .onClick(() => { this.openCloudPanel(); });
                Button(this.lutSyncing ? '同步中…' : '同步')
                  .type(ButtonType.Capsule).height(32).fontSize(12)
                  .fontColor('#FFFFFF').backgroundColor('#316CF4')
                  .enabled(!this.lutSyncing)
                  .margin({ left: 12 })
                  .onClick(() => { this.syncCloudLuts(); });
              }
              .width('100%').padding({ top: 2 });
              if (this.lutSyncStatus.length > 0) {
                Text(this.lutSyncStatus).fontSize(11).fontColor(this.secondaryTextColor())
                  .width('100%').maxLines(3).margin({ top: 10 });
              }
            } else {
              TextInput({ text: this.profileName, placeholder: '你的名称' })
                .width('100%').height(44).fontSize(14).fontColor(this.panelTextColor())
                .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.50)')
                .borderRadius(14).onChange((value: string) => {
                  this.profileName = value;
                  this.persistProfile();
                });
              Row() {
                Column() {
                  Text('华为账号登录').fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(this.panelTextColor());
                  Text('登录后可把自定义 LUT 同步到你的云端空间').fontSize(11)
                    .fontColor(this.mutedTextColor()).margin({ top: 4 });
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1);
                Text('›').fontSize(24).fontColor(this.secondaryTextColor());
              }
              .width('100%').padding({ top: 14 })
              .onClick(() => { this.loginWithHuawei(); });
            }
            Row().width('100%').height(1)
              .backgroundColor('rgba(255,255,255,0.24)').margin({ top: 16 });
            Row() {
              Column() {
                Text('背景图片滚动').fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(this.panelTextColor());
                Text('开启后，页面背景滚动展示最近作品').fontSize(11)
                  .fontColor(this.mutedTextColor()).margin({ top: 4 });
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1);
              Toggle({ type: ToggleType.Switch, isOn: this.backdropScrollEnabled })
                .selectedColor('#316CF4')
                .margin({ left: 12 })
                .onChange((isOn: boolean) => {
                  if (isOn === this.backdropScrollEnabled) return;
                  this.backdropScrollEnabled = isOn;
                  this.persistProfile();
                });
            }
            .width('100%').padding({ top: 14 });
            Row() {
              Column() {
                Text('浮动导航栏').fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(this.panelTextColor());
                Text('开启后导航切换为可拖动的浮动圆环，关闭时固定在屏幕底部')
                  .fontSize(11).fontColor(this.mutedTextColor()).margin({ top: 4 });
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1);
              Toggle({ type: ToggleType.Switch, isOn: this.floatingNavEnabled })
                .selectedColor('#316CF4')
                .margin({ left: 12 })
                .onChange((isOn: boolean) => {
                  if (isOn === this.floatingNavEnabled) return;
                  this.floatingNavEnabled = isOn;
                  this.persistProfile();
                });
            }
            .width('100%').padding({ top: 14 });
          }
          .width('100%').padding(20).borderRadius(26).attributeModifier(this.cardMaterial());

          Column() {
            Text('帮助与支持').fontSize(14).fontWeight(FontWeight.Bold)
              .fontColor(this.panelTextColor()).width('100%').margin({ bottom: 8 });
            Row() {
              Column() {
                Text('问题反馈').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor());
                Text('收集最近 5 分钟的应用诊断日志').fontSize(11).fontColor(this.mutedTextColor()).margin({ top: 4 });
              }.alignItems(HorizontalAlign.Start);
              Blank();
              Text('›').fontSize(24).fontColor(this.secondaryTextColor());
            }
            .width('100%').padding({ top: 12, bottom: 12 })
            .onClick(() => { this.profileSubpage = 1; });
            Row().width('100%').height(1).backgroundColor('rgba(255,255,255,0.20)');
            Row() {
              Column() {
                Text('特别鸣谢').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor());
                Text('查看开源库与许可证说明').fontSize(11).fontColor(this.mutedTextColor()).margin({ top: 4 });
              }.alignItems(HorizontalAlign.Start);
              Blank();
              Text('›').fontSize(24).fontColor(this.secondaryTextColor());
            }
            .width('100%').padding({ top: 12, bottom: 12 })
            .onClick(() => { this.profileSubpage = 2; });
            Row().width('100%').height(1).backgroundColor('rgba(255,255,255,0.20)');
            Row() {
              Column() {
                Text('支持作者').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor());
                Text('微信 / 支付宝赞助，支持软件持续开发').fontSize(11).fontColor(this.mutedTextColor()).margin({ top: 4 });
              }.alignItems(HorizontalAlign.Start);
              Blank();
              Text('›').fontSize(24).fontColor(this.secondaryTextColor());
            }
            .width('100%').padding({ top: 12, bottom: 12 })
            .onClick(() => { this.profileSubpage = 3; });
            Row().width('100%').height(1).backgroundColor('rgba(255,255,255,0.20)');
            Row() {
              Column() {
                Text('联系我们').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor());
                Text('QQ 交流群：839356591').fontSize(11).fontColor(this.mutedTextColor()).margin({ top: 4 });
              }.alignItems(HorizontalAlign.Start);
              Blank();
              Text('›').fontSize(24).fontColor(this.secondaryTextColor());
            }
            .width('100%').padding({ top: 12, bottom: 12 })
            .onClick(() => { this.profileSubpage = 4; });
          }
          .width('100%').padding(20).borderRadius(26).attributeModifier(this.cardMaterial())
          .margin({ top: 14 });
        } else if (this.profileSubpage === 1) {
          Row() {
            Button('‹').fontSize(28).fontColor(this.panelTextColor()).backgroundColor('#00000000')
              .width(40).height(40).padding(0).onClick(() => { this.profileSubpage = 0; });
            Text('问题反馈').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
              .margin({ left: 8 });
            Blank();
          }.width('100%').margin({ bottom: 14 });
          Column() {
            Text('收集最近 5 分钟的应用诊断日志用于本地留存；也可以发送当日脱敏诊断日志，帮助定位连接、传输和导出问题。日志过多时保留最新记录，无需读取系统日志权限。')
              .fontSize(12).fontColor(this.secondaryTextColor()).width('100%');
            Button('收集日志').width('100%').height(44).fontSize(13).fontColor('#FFFFFF')
              .type(ButtonType.Capsule).backgroundColor('#316CF4').margin({ top: 22 })
              .onClick(() => { this.exportRecentAppLogs(); });
            Button('发送今日日志').width('100%').height(44).fontSize(13)
              .fontColor(this.isNightMode ? '#DDE8FF' : '#316CF4')
              .backgroundColor(this.isNightMode ? 'rgba(49,108,244,0.28)' : 'rgba(232,238,255,0.86)')
              .type(ButtonType.Capsule).margin({ top: 12 })
              .onClick(() => { this.prepareLogSend(); });
            if (this.feedbackExportStatus.length > 0) {
              Text(this.feedbackExportStatus).fontSize(11).fontColor(this.secondaryTextColor())
                .width('100%').maxLines(4).margin({ top: 14 });
            }
          }.width('100%').padding(20).borderRadius(26).attributeModifier(this.cardMaterial());
        } else if (this.profileSubpage === 2) {
          Row() {
            Button('‹').fontSize(28).fontColor(this.panelTextColor()).backgroundColor('#00000000')
              .width(40).height(40).padding(0).onClick(() => { this.profileSubpage = 0; });
            Text('特别鸣谢').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
              .margin({ left: 8 });
            Blank();
          }.width('100%').margin({ bottom: 14 });
          Column() {
            Text('感谢以下开源项目与系统组件为像素工坊提供支持。')
              .fontSize(12).fontColor(this.secondaryTextColor()).width('100%').margin({ bottom: 14 });
            Text('• HarmonyOS ArkUI / ArkTS').fontSize(13).fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Text('• LibRaw（LGPL/CDDL，按随附许可证使用）').fontSize(13).fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Text('• libgphoto2（LGPL-2.1，数码相机通信协议支持）').fontSize(13).fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Text('• OpenGL ES / EGL（系统 API）').fontSize(13).fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Text('• lightcraft（MIT，蒙版组合与渲染阶段缓存设计参考）').fontSize(13).fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Text('• Compositor（MIT，画笔合成与图像处理设计参考）').fontSize(13).fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Text('• libjpeg、zlib 及相关图像处理组件（按各自 LICENSE/NOTICE）').fontSize(13).fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Text('• Lumix Lab（松下官方影像应用，LUT 传输协议的行为参考与灵感来源）').fontSize(13).fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Text('• Lumix Sync（松下官方影像应用，相机通信与控制协议的行为参考与灵感来源）').fontSize(13).fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Text('• ChatGPT Luna、ChatGPT Astra 与 GLM 5.3（开发路上的 AI 协作伙伴，感谢它们的智慧与陪伴）').fontSize(13).fontColor(this.panelTextColor()).width('100%').margin({ bottom: 12 });
            Text('开源库的版权声明、许可证和 NOTICE 随应用源码及发布包一并保留；使用者应遵守对应许可证义务。')
              .fontSize(11).fontColor(this.secondaryTextColor()).width('100%').margin({ top: 4 });
          }.width('100%').padding(20).borderRadius(26).attributeModifier(this.cardMaterial());
        } else if (this.profileSubpage === 3) {
          Row() {
            Button('‹').fontSize(28).fontColor(this.panelTextColor()).backgroundColor('#00000000')
              .width(40).height(40).padding(0).onClick(() => { this.profileSubpage = 0; });
            Text('支持作者').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
              .margin({ left: 8 });
            Blank();
          }.width('100%').margin({ bottom: 14 });
          Column() {
            Text('像素工坊由作者利用业余时间独立开发，长期免费且无广告。如果它在你的创作中帮到了你，欢迎在 GitHub 上点一颗星，或通过仓库 Issue 留下反馈——每一份支持，都是软件持续迭代的动力。衷心感谢你的心意！')
              .fontSize(12).fontColor(this.secondaryTextColor()).width('100%').lineHeight(20);
            Text('赞赏二维码未随开源版本发布')
              .fontSize(12).fontColor(this.mutedTextColor()).width('100%').margin({ top: 18 });
          }.width('100%').padding(20).borderRadius(26).attributeModifier(this.cardMaterial());
        } else if (this.profileSubpage === 4) {
          Row() {
            Button('‹').fontSize(28).fontColor(this.panelTextColor()).backgroundColor('#00000000')
              .width(40).height(40).padding(0).onClick(() => { this.profileSubpage = 0; });
            Text('联系我们').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
              .margin({ left: 8 });
            Blank();
          }.width('100%').margin({ bottom: 14 });
          Column() {
            Row() {
              Text('QQ群：839356591').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor());
              Blank();
              Button('复制')
                .type(ButtonType.Capsule).height(32).fontSize(12)
                .fontColor(this.isNightMode ? '#DDE8FF' : '#316CF4')
                .backgroundColor(this.isNightMode ? 'rgba(49,108,244,0.28)' : 'rgba(232,238,255,0.86)')
                .onClick(() => { this.copyQqGroupNumber(); });
            }.width('100%');
            Column() {
              Column() {
                Image($r('app.media.contact_qq_group'))
                  .width(216).height(288).objectFit(ImageFit.Contain);
              }
              .padding(10).borderRadius(18).backgroundColor('#FFFFFF');
              Text('截图或用 QQ「扫一扫」识别上方二维码加群')
                .fontSize(11).fontColor(this.mutedTextColor()).margin({ top: 10 });
            }.width('100%').alignItems(HorizontalAlign.Center).margin({ top: 18 });
          }.width('100%').padding(20).borderRadius(26).attributeModifier(this.cardMaterial());
        }
      }
      .width('100%')
      .padding({ left: this.isDesktop() ? 28 : 16, right: this.isDesktop() ? 28 : 16,
        top: 10, bottom: this.isDesktop() ? 36 : 104 });
    }
    .width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
    .onScroll((_xOffset: number, yOffset: number) => {
      this.scheduleNavColorRefresh();
      this.updateNavCollapse(yOffset);
    });
  }
  private async loadProfile(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.profilePreferences = await preferences.getPreferences(context, 'pixelshop_profile');
      const name = await this.profilePreferences.get('name', this.profileName);
      const avatar = await this.profilePreferences.get('avatar', '');
      const backdropScroll = await this.profilePreferences.get('backdropScroll', false);
      if (typeof name === 'string' && name.length > 0) this.profileName = name;
      if (typeof avatar === 'string') this.profileAvatarUri = avatar;
      if (typeof backdropScroll === 'boolean') this.backdropScrollEnabled = backdropScroll;
      const floatingNav = await this.profilePreferences.get('floatingNav', false);
      if (typeof floatingNav === 'boolean') this.floatingNavEnabled = floatingNav;
      // 日志上报的匿名设备标识：首次生成后持久化，仅用于服务端按设备归档。
      const deviceId = await this.profilePreferences.get('logDeviceId', '');
      if (typeof deviceId === 'string' && deviceId.length > 0) {
        this.logDeviceId = deviceId;
      } else {
        const newId = util.generateRandomUUID(false);
        this.logDeviceId = newId;
        await this.profilePreferences.put('logDeviceId', newId);
        await this.profilePreferences.flush();
      }
    } catch (_error) {
      this.profilePreferences = null;
    }
  }

  private async persistProfile(): Promise<void> {
    try {
      if (!this.profilePreferences) {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.profilePreferences = await preferences.getPreferences(context, 'pixelshop_profile');
      }
      await this.profilePreferences.put('name', this.profileName);
      await this.profilePreferences.put('avatar', this.profileAvatarUri);
      await this.profilePreferences.put('backdropScroll', this.backdropScrollEnabled);
      await this.profilePreferences.put('floatingNav', this.floatingNavEnabled);
      await this.profilePreferences.flush();
    } catch (_error) { }
  }

  private chooseProfileAvatar(): void {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      photoPicker.select({ MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: 1 })
        .then((result: photoAccessHelper.PhotoSelectResult) => {
          if (result.photoUris.length > 0) {
            this.profileAvatarUri = result.photoUris[0];
            this.persistProfile();
          }
        }).catch(() => {});
    } catch (_error) {
      this.showMessage('无法打开图库选择头像');
    }
  }

  /** 拉起华为账号登录；成功后头像昵称替换本地资料展示。 */
  private async loginWithHuawei(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const error = await HuaweiAccountService.login(context);
    if (error.length > 0) {
      this.showMessage(error);
      return;
    }
    this.refreshHuaweiUiState();
    this.lutSyncStatus = '';
    this.showMessage('华为账号登录成功');
    AppLogStore.add('huawei login ok openId=' + HuaweiAccountService.openId);
  }

  /**
   * 同步云端 LUT（v3 JSON 协议）：拉取列表 → 跳过本地同名 → 下载
   * {cubeText, author, description, previewBase64} → 预览图落盘 → 解析后
   * 经 LutBridge 交给 LutPage 落库（自定义分类，持久化 + 卡片刷新）。
   */
  private async syncCloudLuts(): Promise<void> {
    if (this.lutSyncing) return;
    if (!HuaweiAccountService.isLoggedIn()) {
      this.showMessage('请先登录华为账号');
      return;
    }
    if (LutBridge.listCustomLutNames === null || LutBridge.importCloudLut === null) {
      this.showMessage('请先打开一次「调色」页再同步');
      return;
    }
    this.lutSyncing = true;
    this.lutSyncStatus = '正在获取云端 LUT 列表…';
    const client = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'X-Upload-Token': LOG_UPLOAD_TOKEN,
        'X-User-Id': HuaweiAccountService.openId,
      };
      const listResponse = await client.request(LUT_API_BASE, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 20000,
      });
      if (listResponse.responseCode !== 200) {
        this.lutSyncStatus = '获取云端列表失败（HTTP ' + listResponse.responseCode + '）';
        return;
      }
      const parsed = JSON.parse(listResponse.result as string) as CloudLutList;
      const entries: CloudLutEntry[] = [];
      if (parsed.luts instanceof Array) {
        for (const item of parsed.luts) {
          if (item !== null && typeof item.name === 'string' && item.name.length > 0) {
            entries.push(item);
          }
        }
      }
      if (entries.length === 0) {
        this.lutSyncStatus = '云端暂无 LUT，可在「调色」页长按自定义 LUT 上传';
        return;
      }
      const localNames = LutBridge.listCustomLutNames();
      let added = 0;
      let skipped = 0;
      let failed = 0;
      for (let index = 0; index < entries.length; index++) {
        const entry = entries[index];
        this.lutSyncStatus = '正在同步 ' + (index + 1).toString() + '/' + entries.length.toString() +
          '：「' + entry.name + '」';
        if (localNames.indexOf(entry.name) >= 0) {
          skipped++;
          continue;
        }
        try {
          const result = await this.importCloudLutByName(client, headers, entry.name);
          if (result === 'added') {
            added++;
            localNames.push(entry.name);
          } else if (result === 'exists') {
            skipped++;
          } else {
            failed++;
          }
        } catch (_itemError) {
          failed++;
        }
      }
      let summary = '同步完成：新增 ' + added.toString() + ' 个';
      if (skipped > 0) summary += '，跳过同名 ' + skipped.toString() + ' 个';
      if (failed > 0) summary += '，失败 ' + failed.toString() + ' 个';
      this.lutSyncStatus = summary;
      AppLogStore.add('lut sync done added=' + added + ' skipped=' + skipped + ' failed=' + failed);
    } catch (error) {
      const err = error as BusinessError;
      this.lutSyncStatus = '同步失败：' + (err.message !== undefined && err.message.length > 0 ? err.message : '网络错误');
      AppLogStore.add('lut sync failed code=' + err.code);
    } finally {
      client.destroy();
      this.lutSyncing = false;
    }
  }

  /** 下载并导入单个云端 LUT（v3 JSON 协议：含预览图/作者/说明/分类）。
   * 返回 'added' | 'exists' | 'failed'。 */
  private async importCloudLutByName(client: http.HttpRequest,
    headers: Record<string, string>, name: string): Promise<string> {
    if (LutBridge.listCustomLutNames === null || LutBridge.importCloudLut === null) {
      return 'failed';
    }
    const localNames = LutBridge.listCustomLutNames();
    if (localNames.indexOf(name) >= 0) {
      return 'exists';
    }
    const fileResponse = await client.request(
      LUT_API_BASE + '/file?name=' + encodeURIComponent(name), {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 10000,
      readTimeout: 30000,
    });
    if (fileResponse.responseCode !== 200) {
      return 'failed';
    }
    const cloudFile = JSON.parse(fileResponse.result as string) as CloudLutFile;
    if (typeof cloudFile.cubeText !== 'string' || cloudFile.cubeText.length === 0) {
      return 'failed';
    }
    const author = typeof cloudFile.author === 'string' ? cloudFile.author : '';
    const description = typeof cloudFile.description === 'string' ? cloudFile.description : '';
    const previewBase64 = typeof cloudFile.previewBase64 === 'string' ? cloudFile.previewBase64 : '';
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // 预览图：与碰一碰导入同模式，base64 直接落盘为 jpg 文件。
    let previewPath = '';
    if (previewBase64.length > 0) {
      try {
        const bytes = new util.Base64Helper().decodeSync(previewBase64);
        previewPath = context.filesDir + '/lut_sample_cloud_' + Date.now().toString(36) + '.jpg';
        const previewFile = fileIo.openSync(previewPath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(previewFile.fd, bytes.buffer);
        } finally {
          fileIo.closeSync(previewFile);
        }
      } catch (_previewError) {
        previewPath = '';
      }
    }
    // 与碰一碰导入同路径：先落盘 .cube 再解析，sourceUri 指向沙箱文件。
    const lutPath = context.filesDir + '/lut_cloud_' + Date.now().toString(36) + '.cube';
    const lutFile = fileIo.openSync(lutPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(lutFile.fd, cloudFile.cubeText);
    } finally {
      fileIo.closeSync(lutFile);
    }
    const imported = parseLutText(cloudFile.cubeText, lutPath);
    if (imported === null || imported.table === null) {
      return 'failed';
    }
    imported.name = name;
    imported.author = author;
    imported.description = description;
    // 分类还原：人像/自然直接进入对应行的卡片位，其余归入自定义行。
    const cloudCategory = typeof cloudFile.category === 'string' ? cloudFile.category : '';
    imported.category = (cloudCategory === '人像' || cloudCategory === '自然') ? cloudCategory : '自定义';
    imported.format = 'cube';
    if (previewPath.length > 0) {
      imported.sampleUri = previewPath;
      imported.coverUri = previewPath;
    } else {
      imported.sampleUri = 'resource://vivid_cover';
      imported.coverUri = 'resource://vivid_cover';
    }
    const ok = await LutBridge.importCloudLut(imported);
    return ok ? 'added' : 'failed';
  }

  /** 打开「云LUT」弹层并拉取云端列表。 */
  private openCloudPanel(): void {
    if (!HuaweiAccountService.isLoggedIn()) {
      this.showMessage('请先登录华为账号');
      return;
    }
    if (LutBridge.listCustomLutNames === null || LutBridge.importCloudLut === null) {
      this.showMessage('请先打开一次「调色」页');
      return;
    }
    this.cloudPanelOpen = true;
    this.refreshCloudRows();
  }

  private closeCloudPanel(): void {
    this.cloudPanelOpen = false;
  }

  /** 拉取云端 LUT 列表（含作者/分类），随后逐个加载缩略图。 */
  private async refreshCloudRows(): Promise<void> {
    this.cloudRows = [];
    this.cloudPanelStatus = '正在获取云端 LUT 列表…';
    const client = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'X-Upload-Token': LOG_UPLOAD_TOKEN,
        'X-User-Id': HuaweiAccountService.openId,
      };
      const listResponse = await client.request(LUT_API_BASE, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 20000,
      });
      if (listResponse.responseCode !== 200) {
        this.cloudPanelStatus = '获取云端列表失败（HTTP ' + listResponse.responseCode + '）';
        return;
      }
      const parsed = JSON.parse(listResponse.result as string) as CloudLutList;
      const rows: CloudLutRow[] = [];
      if (parsed.luts instanceof Array) {
        for (const item of parsed.luts) {
          if (item !== null && typeof item.name === 'string' && item.name.length > 0) {
            if (typeof item.author !== 'string') item.author = '';
            if (typeof item.category !== 'string') item.category = '';
            rows.push(new CloudLutRow(item));
          }
        }
      }
      this.cloudRows = rows;
      this.cloudPanelStatus = rows.length === 0 ? '云端暂无 LUT，可在「调色」页长按自定义 LUT 上传' : '';
      // 缩略图：逐个拉取预览 JPEG 并生成 ≤128px 小图，完成一个刷新一行。
      for (let index = 0; index < rows.length; index++) {
        if (!this.cloudPanelOpen) return;
        const entry = rows[index].entry;
        if (!entry.hasPreview) continue;
        try {
          const thumb = await this.fetchCloudThumb(client, headers, entry.name);
          if (!this.cloudPanelOpen) return;
          if (thumb !== null) {
            rows[index].thumb = thumb;
            this.cloudRows = rows.slice();
          }
        } catch (_thumbError) {
        }
      }
    } catch (error) {
      const err = error as BusinessError;
      this.cloudPanelStatus = '获取失败：' + (err.message !== undefined && err.message.length > 0 ? err.message : '网络错误');
    } finally {
      client.destroy();
    }
  }

  /** 拉取云端缩略图（服务端优先返回 ≤256px 小图）并解码为 ≤64px PixelMap。 */
  private async fetchCloudThumb(client: http.HttpRequest, headers: Record<string, string>,
    name: string): Promise<image.PixelMap | null> {
    const response = await client.request(
      LUT_API_BASE + '/preview?name=' + encodeURIComponent(name), {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 10000,
      readTimeout: 20000,
    });
    if (response.responseCode !== 200) return null;
    const buffer = response.result as ArrayBuffer;
    if (buffer.byteLength === 0) return null;
    const source = image.createImageSource(buffer);
    try {
      const info = await source.getImageInfo();
      const scale = Math.min(1, 64 / Math.max(info.size.width, info.size.height));
      const width = Math.max(1, Math.round(info.size.width * scale));
      const height = Math.max(1, Math.round(info.size.height * scale));
      return await source.createPixelMap({ desiredSize: { width: width, height: height } });
    } finally {
      source.release();
    }
  }

  /** 「下载」：把该云端 LUT 导入本地（本地同名时提示已存在）。 */
  private async downloadCloudLut(row: CloudLutRow): Promise<void> {
    if (this.cloudBusy) return;
    if (LutBridge.listCustomLutNames === null || LutBridge.importCloudLut === null) {
      this.showMessage('请先打开一次「调色」页');
      return;
    }
    const localNames = LutBridge.listCustomLutNames();
    if (localNames.indexOf(row.entry.name) >= 0) {
      this.cloudPanelStatus = '本地已存在「' + row.entry.name + '」';
      this.showMessage('本地已存在同名 LUT');
      return;
    }
    this.cloudBusy = true;
    this.cloudPanelStatus = '正在下载「' + row.entry.name + '」…';
    const client = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'X-Upload-Token': LOG_UPLOAD_TOKEN,
        'X-User-Id': HuaweiAccountService.openId,
      };
      const result = await this.importCloudLutByName(client, headers, row.entry.name);
      if (result === 'added') {
        this.cloudPanelStatus = '已导入「' + row.entry.name + '」';
        this.showMessage('已导入「' + row.entry.name + '」');
        AppLogStore.add('lut cloud download ok name=' + row.entry.name);
      } else if (result === 'exists') {
        this.cloudPanelStatus = '本地已存在「' + row.entry.name + '」';
      } else {
        this.cloudPanelStatus = '下载失败，请稍后重试';
      }
    } catch (error) {
      const err = error as BusinessError;
      this.cloudPanelStatus = '下载失败：' + (err.message !== undefined && err.message.length > 0 ? err.message : '网络错误');
    } finally {
      client.destroy();
      this.cloudBusy = false;
    }
  }

  /** 「删除」：二次确认后删除该云端 LUT 的全部文件（cube/预览/元数据）。 */
  private confirmDeleteCloudLut(row: CloudLutRow): void {
    AlertDialog.show({
      title: '删除云端 LUT',
      message: '将删除「' + row.entry.name + '」的全部云端文件（含预览图），删除后不可恢复。确定删除吗？',
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E24A4A',
        action: () => {
          this.deleteCloudLut(row);
        }
      }
    });
  }

  private async deleteCloudLut(row: CloudLutRow): Promise<void> {
    if (this.cloudBusy) return;
    this.cloudBusy = true;
    this.cloudPanelStatus = '正在删除「' + row.entry.name + '」…';
    const client = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'X-Upload-Token': LOG_UPLOAD_TOKEN,
        'X-User-Id': HuaweiAccountService.openId,
      };
      const response = await client.request(
        LUT_API_BASE + '?name=' + encodeURIComponent(row.entry.name), {
        method: http.RequestMethod.DELETE,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 30000,
      });
      if (response.responseCode === 200) {
        this.cloudRows = this.cloudRows.filter((item: CloudLutRow) => item.entry.name !== row.entry.name);
        this.cloudPanelStatus = this.cloudRows.length === 0 ? '云端暂无 LUT' : '';
        this.showMessage('已删除「' + row.entry.name + '」');
        AppLogStore.add('lut cloud deleted name=' + row.entry.name);
      } else if (response.responseCode === 404) {
        this.cloudPanelStatus = '云端已不存在该 LUT';
      } else {
        this.cloudPanelStatus = '删除失败（HTTP ' + response.responseCode + '）';
      }
    } catch (error) {
      const err = error as BusinessError;
      this.cloudPanelStatus = '删除失败：' + (err.message !== undefined && err.message.length > 0 ? err.message : '网络错误');
    } finally {
      client.destroy();
      this.cloudBusy = false;
    }
  }

  private copyQqGroupNumber(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, '839356591');
      pasteboard.getSystemPasteboard().setData(data)
        .then(() => {
          this.showMessage('已复制QQ群号 839356591');
        })
        .catch(() => {
          this.showMessage('复制失败，请手动记录群号');
        });
    } catch (_error) {
      this.showMessage('复制失败，请手动记录群号');
    }
  }

  private async exportRecentAppLogs(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const directory = context.filesDir + '/document';
      try { await fileIo.mkdir(directory); } catch (_error) { }
      const now = new Date();
      const stamp = now.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
      const fileName = stamp + '_log.md';
      const path = directory + '/' + fileName;
      const lines = AppLogStore.recent(5 * 60 * 1000);
      const content = '# Pixelshop App Log\n\n' +
        '- 导出时间: ' + now.toISOString() + '\n' +
        '- 时间窗口: 最近 5 分钟\n' +
        '- 相机状态: ' + this.cam.cameraBleStatus + ' / ' + this.cam.cameraWifiStatus + ' / ' + this.cam.cameraSessionStatus + '\n\n' +
        '## 事件\n\n' + (lines.length > 0 ? lines.map((line: string) => '- ' + line).join('\n') : '- 暂无应用事件记录') + '\n';
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        const bytes = util.TextEncoder.create('utf-8').encode(content);
        fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      } finally { fileIo.closeSync(file); }
      this.feedbackExportStatus = '已导出 ' + fileName + ' 到 ' + directory;
      AppLogStore.add('feedback log exported file=' + fileName);
    } catch (_error) {
      this.feedbackExportStatus = '日志导出失败，请稍后重试';
    }
  }

  /** 打开「发送日志」预览弹层；内容为今日完整落盘日志。
   * 需已登录华为账号（未登录仅允许本地「收集日志」）。 */
  private prepareLogSend(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    HuaweiAccountService.ensureLoaded(context).then(() => {
      // 未登录**不再直接拦住**：先前的做法会让没有华为账号的用户完全交不出日志，
      // 而「复制日志」并不需要账号。现在预览与复制对所有人生效，只有上传到
      // 开发者服务器需要账号（服务端按 openID 归档）。
      this.logSendLoggedIn = HuaweiAccountService.isLoggedIn();
      // 发送前先落一条相机现场快照。SD 卡与连接类问题在日志里往往只有几行零散
      // 记录，缺了这张快照很难判断「哪条线、哪个槽位、卡在哪个状态」——复核时
      // 最费时的就是反推这些。槽位用 name:present 形式，不含敏感值。
      try {
        const slot = LumixImportPrototype.currentSlotInfo();
        const slotParts: string[] = [];
        for (const item of slot.slots) {
          slotParts.push(`${item.name}:${item.present ? 1 : 0}`);
        }
        AppLogStore.add(`feedback snapshot brand=${this.cam.cameraBrand} model=${this.cam.cameraModel}`
          + ` line=${this.cam.panasonicLine()} ble=${this.cam.cameraBleStatus}`
          + ` wifi=${this.cam.cameraWifiStatus} session=${this.cam.cameraSessionStatus}`
          + ` sd=${this.cam.selectedSd} slotOk=${slot.ok ? 1 : 0}`
          + ` slotRaw=${slotParts.length > 0 ? slotParts.join(',') : 'none'}`);
      } catch (_error) {
      }
      const text = AppLogStore.uploadLogText();
      if (text.trim().length === 0) {
        this.feedbackExportStatus = '今日暂无日志可发送';
        return;
      }
      this.logSendResult = '';
      this.logSendCopyHint = '';
      this.logSendPreviewText = text;
      AppLogStore.add(`feedback log preview opened loggedIn=${this.logSendLoggedIn ? 1 : 0}`);
    });
  }

  /**
   * 把整理好的日志复制到剪贴板。
   *
   * 这是**没有华为账号时的唯一出口**：本地「导出」写的是应用沙箱路径
   * （`filesDir/document`），用户在「文件」里看不到，等于拿不到。剪贴板不依赖
   * 账号也不依赖网络，用户可以直接贴到微信/邮件发给开发者。
   *
   * 系统剪贴板对超长文本可能拒绝，失败时退到尾部 200000 字符并明说已截断——
   * 尾部才是最新的现场。
   */
  private async copyLogToPasteboard(): Promise<void> {
    const text = this.logSendPreviewText;
    if (text.length === 0) return;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.logSendCopyHint = '已复制完整日志，可直接粘贴发送';
      AppLogStore.add(`feedback log copied chars=${text.length} truncated=0`);
      return;
    } catch (_error) {
      // 落到下面的尾部截断重试。
    }
    try {
      const tail = text.length > 200000 ? text.substring(text.length - 200000) : text;
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, tail);
      await pasteboard.getSystemPasteboard().setData(data);
      this.logSendCopyHint = '日志较长，已复制最后 200000 字符（含最新现场）';
      AppLogStore.add(`feedback log copied chars=${tail.length} truncated=1`);
    } catch (_error) {
      this.logSendCopyHint = '复制失败，请改用「确认发送」';
    }
  }

  private closeLogSendPreview(): void {
    if (this.logSending) return;
    this.logSendPreviewText = '';
  }

  private formatLogSize(text: string): string {
    const kb = Math.max(1, Math.round(util.TextEncoder.create('utf-8').encode(text).byteLength / 1024));
    return kb >= 1024 ? (kb / 1024).toFixed(1) + ' MB' : kb + ' KB';
  }

  /** 预览只显示尾部，避免超长文本拖慢渲染；发送为已整理的日志包。 */
  private logPreviewDisplayText(): string {
    const text = this.logSendPreviewText;
    if (text.length <= 60000) return text;
    return '……（内容较长，仅预览最后 60000 字符，实际发送已整理的日志包）……\n' +
      text.substring(text.length - 60000);
  }

  private async sendLogToServer(): Promise<void> {
    const text = this.logSendPreviewText;
    if (text.length === 0 || this.logSending) return;
    if (!this.logSendLoggedIn) {
      // 上传按华为账号 openID 归档，未登录时服务端无法归属。此时按钮本应被
      // 禁用，这里再兜一层，避免状态不同步时发出无归属的上传。
      this.logSendResult = '上传需先登录华为账号；可改用「复制日志」自行发送';
      return;
    }
    this.logSending = true;
    this.logSendResult = '';
    const client = http.createHttp();
    try {
      // 按 UTF-8 字节限制并保留整行，不能从某行中间截断导致服务端拒收。
      const sendText = AppLogPolicy.prepareUpload(text);
      if (sendText.length === 0) {
        this.logSendResult = '暂无有效诊断日志，请复现问题后再发送';
        return;
      }
      // 明文上报（identity）：日志体积通常几十 KB，当前 SDK 的 zlib 无内存
      // 压缩 API；服务器端已兼容，后续如需压缩可换 gzip 文件或升级 SDK。
      const raw = util.TextEncoder.create('utf-8').encode(sendText);
      const payload: ArrayBuffer = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
      const encoding = 'identity';
      const headers: Record<string, string> = {
        'Content-Type': 'application/octet-stream',
        'Content-Encoding': encoding,
        'X-Upload-Token': LOG_UPLOAD_TOKEN,
        'X-Device-Id': this.logDeviceId,
      };
      const response = await client.request(LOG_UPLOAD_URL, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: payload,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 20000,
      });
      if (response.responseCode === 200) {
        this.feedbackExportStatus = '日志已发送，感谢你的反馈';
        AppLogStore.add('feedback log sent bytes=' + payload.byteLength + ' encoding=' + encoding);
        this.logSendPreviewText = '';
      } else if (response.responseCode === 429) {
        this.logSendResult = '今日发送次数已达上限（20 次），请明天再试';
        AppLogStore.add('feedback log send rejected rate-limit');
      } else {
        this.logSendResult = '发送失败（HTTP ' + response.responseCode + '），请稍后重试';
        AppLogStore.add('feedback log send rejected http=' + response.responseCode);
      }
    } catch (error) {
      const err = error as BusinessError;
      this.logSendResult = '发送失败：' + (err.message && err.message.length > 0 ? err.message : '网络错误');
      AppLogStore.add('feedback log send failed code=' + err.code);
    } finally {
      client.destroy();
      this.logSending = false;
    }
  }

  /** 「发送日志」预览弹层：遮罩点击关闭，卡片内确认后才真正上传。 */
  @Builder
  LogSendPreviewOverlay() {
    Column() {
      Column() {
        Row() {
          Text('发送日志预览').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor());
          Blank();
          Button('✕').fontSize(16).fontColor(this.secondaryTextColor()).backgroundColor('#00000000')
            .width(36).height(36).padding(0)
            .onClick(() => { this.closeLogSendPreview(); });
        }.width('100%');
        Text('本次日志 ' + this.formatLogSize(this.logSendPreviewText) +
          '：可「复制日志」自行发送，或登录华为账号后一键上传到开发者服务器。')
          .fontSize(11).fontColor(this.secondaryTextColor()).width('100%').margin({ top: 6 });
        Text('日志识别码：' + this.logDeviceId)
          .fontSize(11).fontColor(this.mutedTextColor()).width('100%').margin({ top: 4 });
        if (this.logSendResult.length > 0) {
          Text(this.logSendResult).fontSize(11).fontColor('#E24A4A').width('100%').margin({ top: 8 });
        }
        if (this.logSendCopyHint.length > 0) {
          Text(this.logSendCopyHint).fontSize(11).fontColor('#2E9E5B').width('100%').margin({ top: 8 });
        }
        if (!this.logSendLoggedIn) {
          Text('未登录华为账号：可「复制日志」后自行发送给开发者；上传到服务器需先登录。')
            .fontSize(11).fontColor('#E2904A').width('100%').margin({ top: 8 });
        }
        Scroll() {
          Text(this.logPreviewDisplayText()).fontSize(10).fontColor(this.mutedTextColor())
            .fontFamily('monospace').width('100%');
        }
        .width('100%').constraintSize({ maxHeight: 320 }).margin({ top: 12 })
        .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.55)')
        .borderRadius(14).align(Alignment.Top).scrollBar(BarState.Auto);
        Row({ space: 12 }) {
          Button('复制日志').layoutWeight(1).height(42).fontSize(13)
            .fontColor(this.panelTextColor())
            .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(23,32,51,0.06)')
            .type(ButtonType.Capsule)
            .onClick(() => { this.copyLogToPasteboard(); });
          Button('取消').layoutWeight(1).height(42).fontSize(13)
            .fontColor(this.panelTextColor())
            .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(23,32,51,0.06)')
            .type(ButtonType.Capsule)
            .onClick(() => { this.closeLogSendPreview(); });
          Button(this.logSending ? '发送中…' : (this.logSendLoggedIn ? '确认发送' : '需登录'))
            .layoutWeight(1).height(42).fontSize(13)
            .fontColor('#FFFFFF').backgroundColor('#316CF4')
            .type(ButtonType.Capsule).enabled(!this.logSending && this.logSendLoggedIn)
            .opacity(this.logSendLoggedIn ? 1 : 0.5)
            .onClick(() => { this.sendLogToServer(); });
        }.width('100%').margin({ top: 16 })
      }
      // 弹窗必须用不透明底色：材质卡是半透明的，日志文字会和底下的
      // 反馈页文字重叠（参照 ExportOverlay 的 0.97 不透明度）。
      .width('100%').padding(18).borderRadius(24)
      .backgroundColor(this.isNightMode ? 'rgba(16,22,34,0.97)' : 'rgba(255,255,255,0.97)')
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24 })
    .backgroundColor('rgba(9,14,26,0.55)')
    .onClick(() => { this.closeLogSendPreview(); });
  }

  /** 「云LUT」弹层：左侧缩略图+名称+作者，右侧下载/删除。 */
  @Builder
  CloudLutOverlay() {
    Column() {
      Column() {
        Row() {
          Text('云端 LUT').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor());
          Blank();
          Button('✕').fontSize(16).fontColor(this.secondaryTextColor()).backgroundColor('#00000000')
            .width(36).height(36).padding(0)
            .onClick(() => { this.closeCloudPanel(); });
        }.width('100%');
        if (this.cloudPanelStatus.length > 0) {
          Text(this.cloudPanelStatus).fontSize(11).fontColor(this.secondaryTextColor())
            .width('100%').maxLines(3).margin({ top: 6 });
        }
        Scroll() {
          Column() {
            ForEach(this.cloudRows, (row: CloudLutRow) => {
              Row() {
                if (row.thumb !== null) {
                  Image(row.thumb)
                    .width(48).height(48).borderRadius(10).objectFit(ImageFit.Cover);
                } else {
                  Stack({ alignContent: Alignment.Center }) {
                    Text('L').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#FFFFFF');
                  }
                  .width(48).height(48).borderRadius(10)
                  .backgroundColor(this.isNightMode ? 'rgba(49,108,244,0.45)' : 'rgba(49,108,244,0.22)');
                }
                Column() {
                  Text(row.entry.name).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.panelTextColor())
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                  Text(row.entry.author.length > 0 ? row.entry.author : '未知作者')
                    .fontSize(11).fontColor(this.mutedTextColor()).margin({ top: 3 })
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 });
                Button('下载')
                  .type(ButtonType.Capsule).height(30).fontSize(11)
                  .fontColor(this.isNightMode ? '#DDE8FF' : '#316CF4')
                  .backgroundColor(this.isNightMode ? 'rgba(49,108,244,0.28)' : 'rgba(232,238,255,0.86)')
                  .onClick(() => { this.downloadCloudLut(row); });
                Button('删除')
                  .type(ButtonType.Capsule).height(30).fontSize(11)
                  .fontColor('#E24A4A')
                  .backgroundColor(this.isNightMode ? 'rgba(226,74,74,0.22)' : 'rgba(226,74,74,0.10)')
                  .margin({ left: 8 })
                  .onClick(() => { this.confirmDeleteCloudLut(row); });
              }
              .width('100%').padding({ top: 8, bottom: 8 });
            }, (row: CloudLutRow) => row.entry.name + (row.thumb !== null ? '-t' : ''))
          }.width('100%')
        }
        .width('100%').constraintSize({ maxHeight: 380 }).margin({ top: 10 })
        .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.55)')
        .borderRadius(14).scrollBar(BarState.Auto)
      }
      // 弹窗必须用不透明底色：材质卡是半透明的，列表文字会和底下的
      // 页面文字重叠（参照 LogSendPreviewOverlay）。
      .width('100%').padding(18).borderRadius(24)
      .backgroundColor(this.isNightMode ? 'rgba(16,22,34,0.97)' : 'rgba(255,255,255,0.97)')
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24 })
    .backgroundColor('rgba(9,14,26,0.55)')
    .onClick(() => { this.closeCloudPanel(); });
  }

  build() {
    Stack() {
      this.ProfilePage();
      if (this.logSendPreviewText.length > 0) {
        this.LogSendPreviewOverlay();
      }
      if (this.cloudPanelOpen) {
        this.CloudLutOverlay();
      }
    }
    .width('100%').height('100%');
  }
}
