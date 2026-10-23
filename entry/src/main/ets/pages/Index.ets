import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { LumixWifiCandidate } from '../services/LumixCameraService';
import { ParticleAura } from '../components/ParticleAura';
import { RecentPhotoBackdrop } from '../components/RecentPhotoBackdrop';
import { RingNavigator } from '../components/RingNavigator';
import { BottomTabBar } from '../components/BottomTabBar';
import { CameraSessionStore } from '../services/CameraSessionStore';
import { AppLogStore, NavColorService, WorksBridge, CameraBridge, PhotoItem } from './home/HomeShared';
import { WorksPage } from './home/WorksPage';
import { CameraPage } from './home/CameraPage';
import { LutPage } from './home/LutPage';
import { NikonCloudBack } from './home/NikonCloudBack';
import { ProfileSection } from './home/ProfileSection';
import { unifiedDataChannel, uniformTypeDescriptor } from '@kit.ArkData';

interface HomePhotoDropData { fileUri?: string; uri?: string; imageUri?: string; fileUris?: string[]; }

/**
 * 首页壳页面：持有导航栏、页面标题与 Wi-Fi 候选弹层。作品/相机/LUT/我的
 * 四个业务页作为常驻子组件挂载（Visibility 切换，不销毁状态），页面间
 * 状态经 AppStorage 键共享，跨页动作经 HomeShared 的函数桥调用。
 */
@Entry
@Component
struct Index {
  @StorageLink('homeSection') private selectedSection: number = 0;
  @StorageLink('homeSectionTick') private sectionTick: number = 0;
  @StorageLink('homeShowTick') private showTick: number = 0;
  // LUT 页面右侧的个人中心与反馈子页状态。
  @StorageLink('homeProfileVisible') private profileVisible: boolean = false;
  @StorageLink('homeProfileSubpage') private profileSubpage: number = 0; // 0=个人中心，1=问题反馈，2=特别鸣谢，3=支持作者，4=联系我们
  // 作品/相机/LUT/我的页下滑收缩导航的历史键：圆环导航为常驻悬浮控件，
  // 不再随页面滚动收缩；保留键写入兼容旧子页面代码。
  @StorageLink('homeNavCollapsed') private navCollapsed: boolean = false;
  @StorageLink('homeShowWifiPicker') private showWifiPicker: boolean = false;
  @StorageLink('homeWifiScanState') private wifiScanState: number = 0;
  @StorageLink('homeWifiCandidates') private wifiCandidates: LumixWifiCandidate[] = [];
  @StorageLink('homeWifiConnecting') private wifiConnecting: boolean = false;
  @StorageLink('worksPhotos') private photos: PhotoItem[] = [];
  @StorageLink('worksSelectionMode') private selectionMode: boolean = false;
  @StorageLink('worksSelectedUris') private selectedUris: string[] = [];
  @StorageLink('worksSharing') private sharing: boolean = false;
  // 「背景图片滚动」开关与作品页收集的背景帧经 AppStorage 共享。
  @StorageLink('homeBackdropEnabled') private backdropScrollEnabled: boolean = false;
  @StorageLink('homeBackdropUris') private backdropImageUris: string[] = [];
  // 导航模式：false（默认）= 底部固定导航栏；true = 浮动圆环（RingNavigator）。
  // 「我的」页开关写入，ProfileSection 负责持久化。
  @StorageLink('homeFloatingNav') private floatingNavEnabled: boolean = false;
  // API 26 material, filmstrip and particle layers are lightweight surfaces
  // and must be present from the first frame. Delaying them made the
  // immersive motion appear to be missing on real devices.
  @State private visualEffectsReady: boolean = true;
  @State private windowWidth: number = 390;
  // 屏幕尺寸：圆环导航据此默认停在右下角，并在拖动时做限位。
  @State private windowHeight: number = 0;
  // 相机会话的共享状态：图片传输页面与首页持有同一实例。
  @State private cam: CameraSessionStore = CameraSessionStore.instance;
  // 必须走 AppStorage 双向绑定：EntryAbility.onConfigurationUpdate 只更新这个键，
  // 原先用 @State 导致系统切换日夜时子组件（@StorageProp）都跟着变、唯独首页
  // 外壳（顶栏、背景渐变、桌面导航）停在旧配色，出现"有的跟随有的不跟随"。
  @StorageLink('vividNightMode') private isNightMode: boolean = false;

  aboutToAppear(): void {
    this.loadSystemColorMode();
    this.scheduleNavColorRefresh();
  }

  onPageShow(): void {
    // 递增 showTick，让四个常驻子页面回放原 onPageShow 分支：作品页重新
    // 校验最近作品；LUT 页对账目录并消费碰一碰分享包。
    this.showTick++;
  }

  onBackPress(): boolean {
    if (this.profileVisible) {
      if (this.profileSubpage !== 0) this.profileSubpage = 0;
      else {
        this.profileVisible = false;
      }
      return true;
    }
    if (this.cam.s5Receiving) {
      // The S5 push session owns the page while bytes are being written. Do
      // not let a system back gesture navigate away and orphan the receiver.
      return true;
    }
    if (this.cam.cameraPreviewVisible) {
      this.closeCameraPreview();
      return true;
    }
    if (this.selectionMode) {
      this.selectionMode = false;
      this.selectedUris = [];
      return true;
    }
    // 尼康云创内嵌网页：系统返回手势先交给网页自己退浏览历史，一级一级往回，
    // 直到退无可退（最初的尼康云创主页）才交回系统，由系统回桌面。
    if (NikonCloudBack.canGoBack()) {
      NikonCloudBack.goBack();
      return true;
    }
    return false;
  }

  private switchSection(index: number): void {
    // The profile is a full page state. Selecting another section must leave it
    // instead of keeping the profile content mounted over the new section.
    this.profileVisible = false;
    this.profileSubpage = 0;
    // 先写 homeSection 再递增 tick：@StorageLink 同步传播，子页面在
    // @Watch 回调里读到的已是新页签；重拍当前页签也会重放进入分支。
    this.selectedSection = index;
    this.sectionTick++;
  }

  private async loadSystemColorMode(): Promise<void> {
    try {
      const savedMode: boolean | undefined = AppStorage.get('vividNightMode') as boolean | undefined;
      if (savedMode !== undefined && savedMode !== null) {
        this.isNightMode = savedMode as boolean;
        return;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const configuration = await context.resourceManager.getConfiguration();
      const mode = configuration.colorMode;
      this.isNightMode = mode === 0;
      AppStorage.setOrCreate('vividNightMode', this.isNightMode);
    } catch (_error) {
      this.isNightMode = false;
    }
  }

  private toggleNightMode(): void {
    this.isNightMode = !this.isNightMode;
    AppStorage.setOrCreate('vividNightMode', this.isNightMode);
    // 标记手动锁定：系统日夜间再切换时由 EntryAbility 解除并全局跟随。
    AppStorage.setOrCreate('vividNightModeManual', true);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.getApplicationContext().setColorMode(this.isNightMode ?
      ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
  }

  private pageTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#172033';
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

  private isDesktop(): boolean {
    return this.windowWidth >= 840;
  }

  private getPageTitle(): string {
    if (this.profileVisible) return '我的';
    if (this.selectedSection === 0) return '作品';
    if (this.selectedSection === 1) return '相机';
    return '风格库';
  }

  private getPageEyebrow(): string {
    if (this.profileVisible) return '个人中心';
    if (this.selectedSection === 0) return '作品空间';
    if (this.selectedSection === 1) return '相机连接';
    return '颜色库';
  }

  private scheduleNavColorRefresh(): void {
    NavColorService.schedule(this.getUIContext());
  }

  private showMessage(message: string): void {
    AppLogStore.add('ui ' + message);
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      console.info(message);
    }
  }

  private closeCameraPreview(): void {
    this.cam.cameraPreviewVisible = false;
    this.cam.cameraPreviewLoading = false;
    this.cam.cameraPreviewUri = '';
    this.cam.cameraPreviewScale = 1;
  }

  private shareSelectedPhotos(): void {
    const share = WorksBridge.shareSelectedPhotos;
    if (share !== null) share();
  }

  private isPtpIpCamera(): boolean {
    const isPtpIp = CameraBridge.isPtpIpCamera;
    return isPtpIp !== null ? isPtpIp() : false;
  }

  private scanCameraWifi(): void {
    const scan = CameraBridge.scanCameraWifi;
    if (scan !== null) scan();
  }

  private confirmCameraWifi(candidate: LumixWifiCandidate): void {
    const confirmCamera = CameraBridge.confirmCameraWifi;
    if (confirmCamera !== null) confirmCamera(candidate);
  }

  private receivePhotoDrop(event: DragEvent): void {
    if (this.cam.s5Receiving || !WorksBridge.importPhotos) { event.setResult(DragResult.DRAG_FAILED); return; }
    try {
      const uris: string[] = [];
      for (const record of event.getData().getRecords()) {
        const type = record.getType();
        let uri = '';
        if (type === uniformTypeDescriptor.UniformDataType.IMAGE) uri = (record as unifiedDataChannel.Image).imageUri;
        else if (type === uniformTypeDescriptor.UniformDataType.FILE) uri = (record as unifiedDataChannel.File).uri;
        else if (type === uniformTypeDescriptor.UniformDataType.FILE_URI) {
          const payload = record.getValue();
          if (typeof payload === 'string') uri = payload;
          else if (payload && typeof payload === 'object') {
            const data = payload as HomePhotoDropData;
            uri = data.fileUri ?? data.uri ?? '';
            if (data.fileUris) for (const file of data.fileUris) if (uris.indexOf(file) < 0) uris.push(file);
          }
        }
        if (uri.length > 0 && uris.indexOf(uri) < 0) uris.push(uri);
      }
      const photos = uris.filter((uri: string): boolean =>
        /\.(jpe?g|png|heic|heif|webp|bmp|tiff?|dng|rw2|nef|nrw|arw|cr[23]|orf|raf|pef|srw)(?:[?#].*)?$/i.test(uri) || uri.indexOf('file://media/Photo/') === 0);
      if (photos.length === 0) { event.setResult(DragResult.DRAG_FAILED); this.showMessage('请拖入照片或 RAW 文件'); return; }
      event.setResult(DragResult.DRAG_SUCCESSFUL);
      this.switchSection(0);
      WorksBridge.importPhotos(photos).catch(() => { this.showMessage('照片导入失败'); });
    } catch (_error) { event.setResult(DragResult.DRAG_FAILED); this.showMessage('无法读取拖入的照片'); }
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 145,
          colors: this.isNightMode
            ? [['#000000', 0.0], ['#000000', 0.52], ['#000000', 1.0]]
            : [['#FFFFFF', 0.0], ['#FFFFFF', 0.48], ['#FFFFFF', 1.0]],
        })
        // 沉浸式窗口下，背景层覆盖系统状态栏和导航栏；交互内容仍通过
        // safeAreaPadding 保持在安全区内。
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);

      if (this.visualEffectsReady) {
        // 背景图片滚动受「我的」页开关控制：关闭时不挂载背景图层。
        if (this.backdropScrollEnabled) {
          RecentPhotoBackdrop({ imageUris: this.backdropImageUris });
        }
        ParticleAura();
      }

      if (this.isDesktop()) {
        Row() {
          this.DesktopNavigation();
          Column() {
            this.DesktopTopBar();
            this.PageContent();
          }
          .layoutWeight(1)
          .height('100%');
        }
        .width('100%')
        .height('100%');
      } else {
        // 手机端：业务页铺满整个可视区，玻璃导航叠在内容之上。
        // 导航不再占一条独立的布局带——那样会在底部形成一条纯页面底色的方块，
        // 把滚到那里的卡片整块切掉，看起来就像被导航挡住。
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            this.MobileTopBar();
            Column() {
              this.PageContent();
            }
            .layoutWeight(1)
            .width('100%')
            .clip(true);
          }
          .width('100%')
          .height('100%');

          if (!this.floatingNavEnabled) {
            BottomTabBar({
              activeKey: this.profileVisible ? -2 : (this.selectedSection === 3 ? 3 : this.selectedSection),
              onSelect: (key: number) => {
                if (key === -2) {
                  this.profileSubpage = 0;
                  this.profileVisible = true;
                } else {
                  this.switchSection(key);
                }
                this.scheduleNavColorRefresh();
              },
            });
          }
        }
        .width('100%')
        .height('100%')
        .id('homeContentStack')
        .safeAreaPadding({ top: 24 });
      }

      // 可选圆环仍是独立悬浮层。
      if (!this.isDesktop() && this.floatingNavEnabled) {
        Stack() {
          RingNavigator({
            activeKey: this.profileVisible ? -1 : (this.selectedSection === 3 ? 3 : this.selectedSection),
            pageWidth: this.windowWidth,
            pageHeight: this.windowHeight,
            onSelect: (key: number) => {
              if (key === -2) {
                this.profileSubpage = 0;
                this.profileVisible = true;
              } else {
                this.switchSection(key);
              }
              this.scheduleNavColorRefresh();
            },
          })
            .width('100%')
            .height('100%')
            .hitTestBehavior(HitTestMode.Transparent);
        }
        .width('100%')
        .height('100%')
        .alignContent(Alignment.TopStart)
        .hitTestBehavior(HitTestMode.Transparent);
      }

      if (this.showWifiPicker) {
        this.CameraWifiPicker();
      }

      // 导出进度卡片与后台环形进度按钮已迁移到全局浮层 ExportOverlay
      // （EntryAbility 经 OverlayManager 挂载），跨页面可见。

      // 原图批量下载进度、S5 接收与预览大图随「图片传输」功能迁往
      // ImageTransferPage；首页不再持有这些覆盖层。

    }
    .width('100%')
    .height('100%')
    .allowDrop([uniformTypeDescriptor.UniformDataType.IMAGE, uniformTypeDescriptor.UniformDataType.FILE,
      uniformTypeDescriptor.UniformDataType.FILE_URI])
    .onDrop((event: DragEvent) => { this.receivePhotoDrop(event); })
    .onAreaChange((_: Area, newArea: Area) => {
      this.windowWidth = newArea.width as number;
      this.windowHeight = newArea.height as number;
      AppStorage.setOrCreate('windowWidth', this.windowWidth);
    });
  }

  @Builder
  PageContent() {
    Stack() {
      ProfileSection()
        .visibility(this.profileVisible ? Visibility.Visible : Visibility.None)
      WorksPage()
        .visibility(!this.profileVisible && this.selectedSection === 0 ? Visibility.Visible : Visibility.None)
      CameraPage()
        .visibility(!this.profileVisible && this.selectedSection === 1 ? Visibility.Visible : Visibility.None)
      LutPage()
        .visibility(!this.profileVisible && this.selectedSection !== 0 && this.selectedSection !== 1 ?
          Visibility.Visible : Visibility.None)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  DesktopNavigation() {
    Column() {
      // Desktop navigation intentionally omits the app logo and Pixelshop title.
      Blank()
        .width('100%')
        .height(90);

      this.DesktopNavItem(0, '▣', '作品');
      this.DesktopNavItem(1, '◎', '相机');
      this.DesktopNavItem(3, '◇', 'LUT');
      // 个人中心属于全局导航，不再放在 LUT 页面标题行中。
      this.DesktopNavItem(-1, '◉', '我的');
      Blank();
      Column() {
        Text('⚙')
          .fontSize(18)
          .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_000000'));
        if (this.windowWidth >= 1120) {
          Text('设置')
            .fontSize(12)
            .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_000000'))
            .margin({ top: 5 });
        }
      }
      .width(this.windowWidth >= 1120 ? 84 : 56)
      .height(58)
      .justifyContent(FlexAlign.Center)
      .borderRadius(18)
      .margin({ bottom: 20 })
      .onClick(() => {
        this.showMessage('像素工坊已跟随系统窗口与显示偏好');
      });
    }
    .width(this.windowWidth >= 1120 ? 126 : 84)
    .height('100%')
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  DesktopNavItem(index: number, icon: string, label: string) {
    Column() {
      Text(icon)
        .fontSize(21)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_000000'));
      if (this.windowWidth >= 1120) {
        Text(label)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_000000'))
          .margin({ top: 4 });
      }
    }
    .width(this.windowWidth >= 1120 ? 86 : 58)
    .height(this.windowWidth >= 1120 ? 66 : 56)
    .justifyContent(FlexAlign.Center)
    .borderRadius(20)
    .margin({ bottom: 8 })
      .backgroundColor('rgba(255,255,255,0)')
    .animation({ duration: 220, curve: Curve.EaseOut })
    .onClick(() => {
      if (index < 0) {
        this.profileSubpage = 0;
        this.profileVisible = true;
      } else {
        this.switchSection(index);
      }
    });
  }

  @Builder
  DesktopTopBar() {
    Row() {
      Column() {
        Text(this.getPageEyebrow())
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.vivid_text_8a95a5'))
          .letterSpacing(1.2);
        Text(this.getPageTitle())
          .fontSize(25)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.pageTextColor())
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start);
      Blank();
      Text('●')
        .fontSize(14)
        .fontColor(this.cam.cameraState === 2 ? $r('app.color.vivid_text_37b27b') : $r('app.color.vivid_text_a9b2be'))
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .backgroundColor('rgba(255,255,255,0.58)')
        .borderRadius(20)
        .margin({ left: 10 });
    }
    .width('100%')
    .height(82)
    .padding({ left: 28, right: 28 });
  }

  @Builder
  MobileTopBar() {
    Row() {
      // 左上角图标已移除，仅保留页面标题。
      Text(this.getPageTitle())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pageTextColor());
      Blank();
      Button({ type: ButtonType.Circle }) {
        // Use a text-only sun glyph; the common U+2600 form is promoted to a
        // yellow emoji by some system fonts and cannot be recolored.
        Text(this.isNightMode ? '☼' : '☾')
          .fontSize(19)
          .fontColor(this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_000000'));
      }
        .width(38)
        .height(38)
        .padding(0)
        .backgroundColor('#00000000')
        .borderRadius(19)
        .accessibilityText(this.isNightMode ? '切换日间模式' : '切换夜间模式')
        .onClick(() => { this.toggleNightMode(); });
      // 系统分享按钮：分享筛选后选中的图片。
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.share'))
          .fontSize(20)
          .fontColor([this.isNightMode ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_425168')]);
      }
        .width(38)
        .height(38)
        .backgroundColor('rgba(255,255,255,0.66)')
        .borderRadius(19)
        .margin({ left: 8 })
        .enabled(!this.sharing)
        .accessibilityText('系统分享')
        .onClick(() => { this.shareSelectedPhotos(); });
    }
    .width('100%')
    .height(62)
    .padding({ left: 16, right: 16 });
  }

  /** 全局圆环导航构建器已内联到 build 的手机分支（全屏穿透层 + 绝对定位）。 */

  @Builder
  CameraWifiPicker() {
    Stack({ alignContent: Alignment.Center }) {
      // 半透明遮罩防止误触页面；弹窗卡片本身用近实色背景——毛玻璃材质
      // 在真机上透明度过高（materialColor #12EAF1FF ≈ 7%），页面内容
      // 透出影响阅读（2026-09-28 用户反馈）。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(22,31,47,0.35)')
        .onClick(() => { this.showWifiPicker = false; });

      Column() {
        Row() {
          Column() {
            Text('发现相机 Wi-Fi')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.panelTextColor());
            Text(`选择网络后由系统完成连接，再进行 ${this.isPtpIpCamera() ? 'PTP/IP' : 'LUMIX'} 握手`)
              .fontSize(11)
              .fontColor(this.mutedTextColor())
              .margin({ top: 5 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);
          Button('×')
            .type(ButtonType.Capsule)
            .width(34)
            .height(34)
            .fontSize(18)
            .fontColor($r('app.color.vivid_text_657286'))
            .backgroundColor('rgba(226,232,241,0.85)')
            .onClick(() => { this.showWifiPicker = false; });
        }
        .width('100%');

        if (this.wifiCandidates.length === 0) {
          Column() {
            Text(this.wifiScanState === 1 ? '正在扫描附近 Wi-Fi…' : '未发现符合条件的相机 Wi-Fi')
              .fontSize(13)
              .fontColor(this.secondaryTextColor());
            Text('请打开相机 Wi-Fi，并允许系统获取附近网络信息')
              .fontSize(11)
              .fontColor(this.mutedTextColor())
              .margin({ top: 8 });
            Button('重新扫描')
              .type(ButtonType.Capsule)
              .height(38)
              .padding({ left: 22, right: 22 })
              .fontSize(12)
              .fontColor($r('app.color.vivid_text_ffffff'))
              .backgroundColor('#316CF4')
              .margin({ top: 18 })
              .onClick(() => { this.scanCameraWifi(); });
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 32, bottom: 26 });
        } else {
          Column() {
            ForEach(this.wifiCandidates, (candidate: LumixWifiCandidate) => {
              Row() {
                Column() {
                  Text(candidate.ssid)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.panelTextColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis });
                  Text(`${candidate.model} · ${candidate.family} · 信号 ${candidate.rssi} dBm`)
                    .fontSize(10)
                    .fontColor(this.mutedTextColor())
                    .margin({ top: 4 });
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);
                Button(this.wifiConnecting ? '连接中…' : '连接')
                  .type(ButtonType.Capsule)
                  .height(32)
                  .padding({ left: 14, right: 14 })
                  .fontSize(11)
                  .fontColor($r('app.color.vivid_text_ffffff'))
                  .backgroundColor('#316CF4')
                  .enabled(!this.wifiConnecting)
                  .onClick(() => { this.confirmCameraWifi(candidate); });
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .border({ width: { bottom: 1 }, color: 'rgba(203,213,228,0.62)' });
            }, (candidate: LumixWifiCandidate) => candidate.ssid);
            Button('取消')
              .type(ButtonType.Capsule)
              .height(36)
              .fontSize(12)
              .fontColor(this.secondaryTextColor())
              .backgroundColor('rgba(228,234,243,0.90)')
              .margin({ top: 14 })
              .onClick(() => { this.showWifiPicker = false; });
          }
          .width('100%')
          .margin({ top: 18 });
        }
      }
      .width('calc(100% - 36vp)')
      .padding(20)
      .borderRadius(26)
      // 发现相机 Wi-Fi 弹窗：近实色卡片（毛玻璃材质透明度不足，见上方
      // 遮罩注释），保证候选列表与说明文字清晰可读。
      .backgroundColor(this.isNightMode ? 'rgba(24,30,40,0.96)' : 'rgba(250,252,255,0.96)')
      .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
      .shadow({ radius: 24, color: 'rgba(40,55,82,0.28)', offsetY: 8 })
      .onClick(() => {});
    }
    .width('100%')
    .height('100%');
  }
}
