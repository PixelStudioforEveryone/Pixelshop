import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want, bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { errorManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ExportOverlay } from '../components/ExportOverlay';
import { S5ReceiveOverlay } from '../components/S5ReceiveOverlay';
import { AppLogStore } from '../pages/home/HomeShared';
import { AppDiagnostics } from '../services/AppDiagnostics';
import { AppLogSink } from '../services/AppLogSink';
import { CustomLut, LutLibraryStore } from '../edit/models/LutLibrary';
import { NikonCloudStore } from '../edit/models/NikonCloudCatalog';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private gpuValidation: boolean = false;
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 诊断日志落盘（filesDir/logs，一日一清），问题反馈页据此发送。
    AppLogStore.init(this.context.filesDir);
    // A sidecar can reference a cloud preset whose LUT is baked from a bundled
    // NP3 rather than persisted. Install the resolver before any editor page
    // restores a sidecar, otherwise the layer silently becomes LUT-less.
    NikonCloudStore.attachResourceManager(this.context.resourceManager);
    LutLibraryStore.setNikonResolver((id: string, name: string): CustomLut | null =>
      NikonCloudStore.resolveLutSync(id, name));
    AppDiagnostics.configure((message: string): void => { AppLogStore.add(message); },
      (): void => { AppLogStore.flushNow(); });
    // 服务层协议日志（BLE/HTTP/相机控制）的原文出口。用户读不到 hilog，
    // 「问题反馈 → 发送日志」上传的只有这个文件，所以链路细节必须落到这里。
    AppLogSink.install((message: string): void => { AppLogStore.add(message); });
    // 自检标记：每份反馈日志都能据此确认「这份日志里应当有 CTL 行」。
    // 如果用户上传的日志里连这一行都没有，说明包是旧版本或 init 未跑，
    // 而不是「链路没记录」——这两种情况以前无法区分。
    AppLogSink.emit('CTL', 'log sink installed; protocol trace enabled');
    AppLogStore.add('ability onCreate');
    try {
      const bundle = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const version = /^[0-9.]+$/.test(bundle.versionName) ? bundle.versionName : 'unavailable';
      AppLogStore.add(`app_build version=${version} versionCode=${bundle.versionCode} sdk=${deviceInfo.sdkApiVersion} diagnostics=3`);
    } catch (_error) { AppLogStore.add('app_build metadata=unavailable diagnostics=3'); }
    // 直接记录脱敏异常到应用沙箱，不依赖用户读取系统 HiLog/faultlog。
    try {
      errorManager.on('error', {
        onUnhandledException: (errMsg: string): void => {
          hilog.error(DOMAIN, 'VIVID_JS_ERROR', '%{public}s', errMsg);
          AppDiagnostics.exception('APP', 'unhandled', errMsg);
        },
      });
    } catch (err) {
      hilog.error(DOMAIN, 'VIVID_JS_ERROR', 'register observer failed %{public}s', JSON.stringify(err));
    }
    this.gpuValidation = want.parameters?.['vividGpuSelfTest'] === '1';
    this.captureKnockImport(want);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      // 新会话恢复跟随系统：手动日夜间锁定标记复位。
      AppStorage.setOrCreate('vividNightModeManual', false);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 首帧布局前同步检测系统夜间/日间模式：应用跟随系统（NOT_SET）时
    // config.colorMode 即系统当前模式。先写 AppStorage 再 loadContent，
    // 避免首页/导航栏以日间配色绘制夜间界面（灰底白字看不清）。
    try {
      const colorMode = this.context.config?.colorMode;
      if (colorMode !== undefined && colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
        AppStorage.setOrCreate('vividNightMode',
          colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to read system color mode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  /** 系统夜间/日间切换时同步 AppStorage，页面配色实时跟随。
   * 若用户手动锁定过日/夜间（toggleNightMode 的 setColorMode(DARK/LIGHT)），
   * 必须先解除锁定回到跟随系统，否则资源配色停在旧模式、JS 配色却跟随
   * AppStorage 切换，出现「有的变有的没变」的错乱。 */
  onConfigurationUpdate(newConfig: Configuration): void {
    try {
      if (newConfig.colorMode !== undefined &&
        newConfig.colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
        const manual = AppStorage.get<boolean>('vividNightModeManual') === true;
        if (manual) {
          // 先清标记再重置，setColorMode 触发的二次 onConfigurationUpdate
          // 不会再进入该分支，避免递归。
          AppStorage.setOrCreate('vividNightModeManual', false);
          this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
        }
        AppStorage.setOrCreate('vividNightMode',
          newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to update color mode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 碰一碰分享的「指定应用直达」会以 viewData 拉起本应用并携带包文件 URI。
    this.captureKnockImport(want);
  }

  /** 记录碰一碰直达带来的 LUT 分享包文件，由首页在可见时导入。 */
  private captureKnockImport(want: Want): void {
    try {
      if (want.action === 'ohos.want.action.viewData' && want.uri &&
        want.uri.toLowerCase().endsWith('.json')) {
        AppStorage.setOrCreate('vividPendingKnockImport', want.uri);
        hilog.info(DOMAIN, 'testTag', 'knock import uri=%{public}s', want.uri);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to capture knock import. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    AppLogStore.flushNow();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 开启沉浸式布局，让页面背景可以延伸到系统状态栏和导航栏区域。
    // 系统栏本身保持透明，时间、电量和手势条仍然显示在页面之上。
    try {
      const mainWindow = windowStage.getMainWindowSync();
      // 页面根节点已经绘制全屏背景。部分真机在窗口 surface 尚未完成
      // attach 时调用 setWindowBackgroundColor 会抛出 1300002，导致
      // DevEco USB 调试日志显示启动错误，因此不再调用该 API。
      mainWindow.setWindowLayoutFullScreen(true).then(() => {
        return mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: '#172033',
          navigationBarContentColor: '#172033',
          isStatusBarLightIcon: false,
          isNavigationBarLightIcon: false,
        });
      }).catch(() => {
        hilog.error(DOMAIN, 'testTag', 'Failed to enable immersive window layout.');
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to configure window surface. Cause: %{public}s', JSON.stringify(err));
    }

    windowStage.loadContent(this.gpuValidation ? 'pages/GpuValidationPage' : 'pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // 全局导出进度浮层：挂到窗口 OverlayManager，所有页面之上可见。
      try {
        ExportOverlay.mount(windowStage.getMainWindowSync().getUIContext());
      } catch (overlayErr) {
        hilog.error(DOMAIN, 'testTag', 'Failed to mount export overlay. Cause: %{public}s', JSON.stringify(overlayErr));
      }
      // 全局被动接收进度浮层（Sync 相机推送图片）：与导出浮层同级挂载，
      // 主页与其他页面均以非阻塞卡片显示接收进度。
      try {
        S5ReceiveOverlay.mount(windowStage.getMainWindowSync().getUIContext());
      } catch (overlayErr) {
        hilog.error(DOMAIN, 'testTag', 'Failed to mount S5 receive overlay. Cause: %{public}s', JSON.stringify(overlayErr));
      }
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    AppStorage.setOrCreate('vividForeground', true);
    // 应用在后台挂起期间系统可能切过日夜模式，onConfigurationUpdate 不保证送达；
    // 回到前台再与系统配置对一次，避免界面停在错误配色上（手动锁定除外）。
    this.resyncColorMode();
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  /** 与系统当前日夜模式对齐 AppStorage；用户手动锁定过则不覆盖。 */
  private resyncColorMode(): void {
    try {
      if (AppStorage.get<boolean>('vividNightModeManual') === true) return;
      const colorMode = this.context.config?.colorMode;
      if (colorMode !== undefined && colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
        AppStorage.setOrCreate('vividNightMode',
          colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to resync color mode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onBackground(): void {
    AppStorage.setOrCreate('vividForeground', false);
    AppLogStore.flushNow();
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
