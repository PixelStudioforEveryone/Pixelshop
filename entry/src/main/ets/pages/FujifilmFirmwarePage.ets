/**
 * FUJIFILM 固件更新页（角色 D）。
 *
 * 页面只负责展示与节流，协议与网络全部在 `FujifilmFirmwareService`：
 *   检查更新 → GET privacy.xapp.net/camera_fw/camera_fw_info.json + BLE/PTP 读版本
 *   开始更新 → 下载 .DAT（SHA-256 校验）→ BLE 92 B 请求 → 连相机 WiFi
 *              → SetFunctionMode(0x13) → 1 MiB 分块推流（事件 49/50）
 * 依据：`04_固件更新协议.md`。写入不可逆，所以更新期间锁界面且拦截返回键。
 */

import { common } from '@kit.AbilityKit';
import { CameraSessionStore } from '../services/CameraSessionStore';
import {
  FujifilmFirmwareBlePort, FujifilmFirmwareCheck, FujifilmFirmwareEntry, FujifilmFirmwareResult,
  FujifilmFirmwareService,
} from '../services/FujifilmFirmwareService';
import { FujifilmBleIds } from '../services/FujifilmProtocol';
import { FujifilmBleService } from '../services/FujifilmBleService';
import { AppLogStore } from './home/HomeShared';

/**
 * 固件专用 BLE 通道的实现（ArkTS 不允许用对象字面量实现带方法的接口，故用类）。
 * 只在 `FujifilmBleService` 已连接时注入；未连接时保持降级链路。
 */
class FujifilmFirmwareBleBridge implements FujifilmFirmwareBlePort {
  writeRequest(payload: Uint8Array): Promise<boolean> {
    return FujifilmBleService.writeCharacteristic(FujifilmBleIds.CHAR_FW_UPDATE_REQUEST, payload);
  }

  readFileInformation(): Promise<Uint8Array | null> {
    return FujifilmBleService.readCharacteristic(FujifilmBleIds.CHAR_FW_UPDATE_FILE_INFO, 5000);
  }
}

@Entry
@Component
struct FujifilmFirmwarePage {
  @State private modelName: string = 'FUJIFILM';
  @State private checking: boolean = false;
  @State private updating: boolean = false;
  @State private supported: boolean = false;
  @State private updateAvailable: boolean = false;
  @State private currentVersion: string = '';
  @State private latestVersion: string = '';
  @State private fileSizeText: string = '';
  @State private updateInfo: string = '';
  @State private notes: string = '正在检查更新…';
  @State private statusText: string = '';
  @State private percent: number = -1;
  @State private cancelRequested: boolean = false;
  @State private finished: boolean = false;
  @State private resultOk: boolean = false;
  @State private resultCancelled: boolean = false;
  @State private resultMessage: string = '';
  @State private resultCodeText: string = '';
  @StorageLink('vividNightMode') private isNightMode: boolean = false;

  /** 当前可更新的云端条目（非 UI 状态，build 里只用它的派生字符串）。 */
  private latest: FujifilmFirmwareEntry | null = null;

  aboutToAppear(): void {
    const store = CameraSessionStore.instance;
    const model: string = store.cameraModel.trim();
    if (model.length > 0 && store.cameraBrand === 'FUJIFILM') this.modelName = model;
    AppLogStore.add(`[FUJI] 进入固件更新页 model=${this.modelName}`);
    // 上一次的结论先铺上（秒开），随后再刷新。
    const cached: FujifilmFirmwareCheck | null = FujifilmFirmwareService.lastResult();
    if (cached !== null) this.applyCheck(cached);
    this.runCheck();
  }

  /** 更新中禁止返回：写入固件时断开连接可能让相机无法启动。 */
  onBackPress(): boolean {
    if (this.updating) {
      this.toast('固件更新进行中，不能退出');
      return true;
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // 检查
  // -------------------------------------------------------------------------

  /**
   * 把固件专用的 BLE 通道接到已建立的 GATT 链路上。
   *
   * 92 B 请求（B1307521）与 29 B 文件信息（20EA1FAC）只有固件流程会用到，
   * 因此不放进通用的识别流程，而是由本页按需注入（D 的 `setBlePort` 端口）。
   * 未连接蓝牙时保持“未注入=降级”：只走 launch(5) + waitApReady，trace 会
   * 明确写出“BLE 92 B 请求未发送”，不会静默写坏相机。依据 04 §5.4.3。
   */
  private ensureBlePort(): void {
    if (!FujifilmBleService.isConnected()) {
      AppLogStore.add('[FUJI] 固件页：蓝牙未连接，92 B 请求将不发送（降级）');
      return;
    }
    const port: FujifilmFirmwareBlePort = new FujifilmFirmwareBleBridge();
    FujifilmFirmwareService.setBlePort(port);
    AppLogStore.add(`[FUJI] 固件页：BLE 通道已接线 device=${FujifilmBleService.currentDeviceId()}`);
  }

  private async runCheck(): Promise<void> {
    if (this.checking || this.updating) return;
    this.ensureBlePort();
    this.checking = true;
    this.finished = false;
    this.notes = '正在读取相机版本并获取云端清单…';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const state: FujifilmFirmwareCheck = await FujifilmFirmwareService.check(
        context, this.modelName, (status: string, _percent: number): void => {
          this.notes = status;
        });
      this.applyCheck(state);
    } catch (error) {
      this.notes = '检查更新失败（请确认蓝牙已连接、手机已联网）';
      AppLogStore.add(`[FUJI] 检查更新异常 ${String(error)}`);
    } finally {
      this.checking = false;
    }
  }

  private applyCheck(state: FujifilmFirmwareCheck): void {
    if (state.modelName.length > 0) this.modelName = state.modelName;
    this.supported = state.supported;
    this.updateAvailable = state.updateAvailable;
    this.currentVersion = state.currentVersion;
    this.latest = state.latest;
    this.notes = state.notes;
    if (state.latest !== null) {
      this.latestVersion = state.latest.version;
      this.fileSizeText = FujifilmFirmwareService.sizeText(state.latest.fileSize);
      // 04 §5.1：只有 EN/JA；缺 EN 时回退 JA，都没有给一句占位。
      const info: string = state.latest.updateInfoEn.length > 0
        ? state.latest.updateInfoEn : state.latest.updateInfoJa;
      this.updateInfo = info.trim();
    } else {
      this.latestVersion = '';
      this.fileSizeText = '';
      this.updateInfo = '';
    }
    AppLogStore.add(`[FUJI] 检查结果 supported=${state.supported} ` +
      `current=${state.currentVersion} latest=${this.latestVersion} update=${state.updateAvailable}`);
  }

  // -------------------------------------------------------------------------
  // 更新
  // -------------------------------------------------------------------------

  private async startUpdate(): Promise<void> {
    const entry: FujifilmFirmwareEntry | null = this.latest;
    if (entry === null || this.updating || !this.updateAvailable) return;
    if (FujifilmFirmwareService.isBusy()) {
      this.toast('已有固件更新在进行中');
      return;
    }
    const agreed: boolean = await this.confirm(entry);
    if (!agreed) return;
    this.ensureBlePort();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.updating = true;
    this.finished = false;
    this.cancelRequested = false;
    this.percent = -1;
    this.statusText = '正在准备固件更新…';
    this.resultMessage = '';
    this.resultCodeText = '';
    AppLogStore.add(`[FUJI] 用户确认更新 ${this.currentVersion} → ${entry.version}`);
    try {
      const result: FujifilmFirmwareResult = await FujifilmFirmwareService.update(
        context, entry, this.modelName,
        (status: string, percent: number): void => {
          this.statusText = status;
          this.percent = percent;
        });
      this.resultOk = result.ok;
      this.resultCancelled = result.cancelled;
      this.resultMessage = result.message;
      this.resultCodeText = FujifilmFirmwareService.describeErrorCode(result.code);
      if (result.ok) this.updateAvailable = false;
      AppLogStore.add(`[FUJI] 更新结束 ok=${result.ok} cancelled=${result.cancelled} ` +
        `stage=${result.stage} code=${result.code} trace=${result.trace.join(' | ')}`);
    } catch (error) {
      this.resultOk = false;
      this.resultCancelled = false;
      this.resultMessage = `固件更新异常：${String(error)}`;
      this.resultCodeText = '';
      AppLogStore.add(`[FUJI] 更新异常 ${String(error)}`);
    } finally {
      this.updating = false;
      this.finished = true;
      this.percent = -1;
    }
  }

  /** 开始前的二次确认：写清楚不可逆与"不要断电"。 */
  private confirm(entry: FujifilmFirmwareEntry): Promise<boolean> {
    const lines: string[] = [
      `机型：${this.modelName}`,
      `版本：${this.currentVersion.length > 0 ? this.currentVersion : '未知'} → ${entry.version}`,
      `固件包：${entry.fileName}（${FujifilmFirmwareService.sizeText(entry.fileSize)}）`,
      '',
      '更新过程约 5 分钟以上，相机会自行写入并重启。',
      '过程中请勿关闭相机电源、断开连接或取出存储卡。',
      '固件写入不可逆，App 侧没有回滚能力。',
    ];
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      try {
        this.getUIContext().showAlertDialog({
          title: '更新相机固件',
          message: lines.join('\n'),
          autoCancel: true,
          alignment: DialogAlignment.Center,
          buttons: [
            {
              value: '取消',
              action: (): void => { resolve(false); },
            },
            {
              value: '开始更新',
              action: (): void => { resolve(true); },
            },
          ],
        });
      } catch (_error) {
        // 弹窗不可用时宁可不更新。
        resolve(false);
      }
    });
  }

  private requestCancel(): void {
    if (!this.updating || this.cancelRequested) return;
    this.cancelRequested = true;
    FujifilmFirmwareService.cancel();
    this.statusText = '正在取消…';
    this.toast('已请求取消；相机侧不会回滚已写入的数据');
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
    } catch (_error) {
      // 提示失败不影响主流程。
    }
  }

  // -------------------------------------------------------------------------
  // 颜色
  // -------------------------------------------------------------------------

  private pageTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#172033';
  }

  private panelTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#1B2536';
  }

  private mutedTextColor(): string {
    return this.isNightMode ? '#9BA8BC' : '#8B96A6';
  }

  private cardBackground(): string {
    return this.isNightMode ? 'rgba(32,42,59,0.55)' : 'rgba(255,255,255,0.62)';
  }

  private cardBorder(): string {
    return this.isNightMode ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.85)';
  }

  private versionLine(): string {
    const current: string = this.currentVersion.length > 0 ? this.currentVersion : '未知';
    const latest: string = this.latestVersion.length > 0 ? this.latestVersion : '未知';
    return `相机 ${current} → 云端 ${latest}`;
  }

  // -------------------------------------------------------------------------
  // 视图
  // -------------------------------------------------------------------------

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(this.mutedTextColor())
        .width(84);
      Text(value)
        .fontSize(12)
        .fontColor(this.panelTextColor())
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 7, bottom: 7 });
  }

  @Builder
  BusyOverlay() {
    Column() {
      Column() {
        Text('正在更新相机固件')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isNightMode ? '#F4F7FC' : '#1B2536')
          .width('100%')
          .textAlign(TextAlign.Center);
        if (this.percent >= 0) {
          Progress({ value: this.percent, total: 100, type: ProgressType.Linear })
            .width('100%')
            .margin({ top: 18 });
          Text(`${this.percent}%`)
            .fontSize(13)
            .fontColor(this.isNightMode ? '#C9D3E4' : '#334158')
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 8 });
        } else {
          LoadingProgress()
            .width(44)
            .height(44)
            .color('#5262EC')
            .margin({ top: 18 });
        }
        Text(this.statusText)
          .fontSize(14)
          .fontColor(this.isNightMode ? '#DCE4F0' : '#334158')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 14 });
        Text('过程中请勿关闭相机电源、断开连接或取出存储卡，否则可能导致相机无法启动')
          .fontSize(11)
          .fontColor('#8A95A5')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 12 });
        Button(this.cancelRequested ? '正在取消…' : '取消')
          .enabled(!this.cancelRequested)
          .fontSize(13)
          .height(36)
          .width(120)
          .backgroundColor(this.cancelRequested ? '#B9C2D0' : '#E7EBF3')
          .fontColor('#334158')
          .margin({ top: 18 })
          .onClick(() => { this.requestCancel(); });
      }
      .width(300)
      .padding(24)
      .backgroundColor(this.isNightMode ? '#2A3342' : '#FFFFFF')
      .borderRadius(16)
      .alignItems(HorizontalAlign.Center);
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.45)')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => { });
  }

  @Builder
  ResultCard() {
    Column() {
      Text(this.resultOk ? '更新已发送完成' : (this.resultCancelled ? '已取消' : '更新失败'))
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.resultOk ? '#1E8E5A' : (this.resultCancelled ? '#8A95A5' : '#C8443A'))
        .width('100%');
      if (this.resultMessage.length > 0) {
        Text(this.resultMessage)
          .fontSize(12)
          .fontColor(this.panelTextColor())
          .lineHeight(19)
          .width('100%')
          .margin({ top: 8 });
      }
      if (this.resultCodeText.length > 0) {
        Text(`错误码说明：${this.resultCodeText}`)
          .fontSize(11)
          .fontColor(this.mutedTextColor())
          .lineHeight(17)
          .width('100%')
          .margin({ top: 6 });
      }
      if (this.resultOk) {
        Text('相机正在写入固件并会自行重启。重启完成后可在相机菜单里确认版本号。')
          .fontSize(11)
          .fontColor(this.mutedTextColor())
          .lineHeight(17)
          .width('100%')
          .margin({ top: 8 });
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor(this.cardBackground())
    .border({ width: 1, color: this.cardBorder() })
    .margin({ top: 14 });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Row() {
          Text('‹')
            .fontSize(34)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pageTextColor())
            .width(44)
            .height(44)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              if (this.updating) {
                this.toast('固件更新进行中，不能退出');
                return;
              }
              this.getUIContext().getRouter().back();
            });
          Text('固件更新')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pageTextColor())
            .layoutWeight(1);
          Blank().width(44);
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 10, bottom: 6 });

        Scroll() {
          Column() {
            // ── 版本卡 ──────────────────────────────────────────────────
            Column() {
              Row() {
                Text(this.modelName)
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.panelTextColor())
                  .layoutWeight(1);
                Text(this.supported
                  ? (this.updateAvailable ? '有新固件' : '已是最新')
                  : '无可用固件')
                  .fontSize(11)
                  .fontColor(this.updateAvailable ? '#C8791A' : this.mutedTextColor())
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(9)
                  .backgroundColor(this.updateAvailable ? 'rgba(200,121,26,0.12)' : 'rgba(120,140,170,0.12)');
              }
              .width('100%');

              this.InfoRow('当前版本', this.currentVersion.length > 0 ? this.currentVersion : '未读到');
              this.InfoRow('最新版本', this.latestVersion.length > 0 ? this.latestVersion : '—');
              this.InfoRow('固件大小', this.fileSizeText.length > 0 ? this.fileSizeText : '—');
              if (this.currentVersion.length > 0 && this.latestVersion.length > 0) {
                Text(this.versionLine())
                  .fontSize(11)
                  .fontColor(this.mutedTextColor())
                  .width('100%')
                  .margin({ top: 2 });
              }
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 10 })
            .borderRadius(16)
            .backgroundColor(this.cardBackground())
            .border({ width: 1, color: this.cardBorder() });

            // ── 状态 / 结论 ─────────────────────────────────────────────
            Column() {
              Row() {
                Text('状态')
                  .fontSize(12)
                  .fontColor(this.mutedTextColor())
                  .width(84);
                Text(this.notes)
                  .fontSize(12)
                  .fontColor(this.panelTextColor())
                  .lineHeight(18)
                  .layoutWeight(1);
              }
              .width('100%')
              .alignItems(VerticalAlign.Top);
              if (this.checking) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color('#5262EC')
                  .margin({ top: 8 });
              }
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .borderRadius(16)
            .backgroundColor(this.cardBackground())
            .border({ width: 1, color: this.cardBorder() })
            .margin({ top: 12 });

            // ── 更新说明（UpdateInfo_EN，04 §5.1）───────────────────────
            if (this.updateInfo.length > 0) {
              Column() {
                Text('更新说明')
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.panelTextColor())
                  .width('100%')
                  .margin({ bottom: 8 });
                Text(this.updateInfo)
                  .fontSize(12)
                  .fontColor(this.panelTextColor())
                  .lineHeight(19)
                  .width('100%')
                  .copyOption(CopyOptions.LocalDevice);
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 14 })
              .borderRadius(16)
              .backgroundColor(this.cardBackground())
              .border({ width: 1, color: this.cardBorder() })
              .margin({ top: 12 });
            }

            // ── 结果 ────────────────────────────────────────────────────
            if (this.finished && !this.updating) {
              this.ResultCard();
            }

            // ── 按钮 ────────────────────────────────────────────────────
            Row({ space: 10 }) {
              Button('检查更新')
                .fontSize(13)
                .height(44)
                .layoutWeight(1)
                .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.72)')
                .fontColor(this.panelTextColor())
                .enabled(!this.checking && !this.updating)
                .onClick(() => { this.runCheck(); });
              Button('开始更新')
                .fontSize(13)
                .height(44)
                .layoutWeight(1)
                .backgroundColor(this.updateAvailable ? '#5262EC' : '#B9C2D0')
                .fontColor('#FFFFFF')
                .enabled(this.updateAvailable && !this.updating && !this.checking)
                .onClick(() => { this.startUpdate(); });
              Button('取消')
                .fontSize(13)
                .height(44)
                .width(76)
                .backgroundColor(this.isNightMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.72)')
                .fontColor(this.updating && !this.cancelRequested ? '#C8443A' : this.mutedTextColor())
                .enabled(this.updating && !this.cancelRequested)
                .onClick(() => { this.requestCancel(); });
            }
            .width('100%')
            .margin({ top: 18 });

            Text('固件写入不可逆：更新期间请保持相机开机、不要拔卡或断开连接。' +
              'App 不会发送断电命令，也不会做回滚（见 04 报告 §5.12）。')
              .fontSize(11)
              .fontColor(this.mutedTextColor())
              .lineHeight(17)
              .width('100%')
              .margin({ top: 14 });
            Text('数据来源：privacy.xapp.net/camera_fw/camera_fw_info.json（无鉴权静态清单，30 款机身）。')
              .fontSize(10)
              .fontColor(this.mutedTextColor())
              .lineHeight(16)
              .width('100%')
              .margin({ top: 6 });
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 40 });
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      }
      .width('100%')
      .height('100%')
      .safeAreaPadding({ top: 24 })
      .linearGradient({
        angle: 160,
        colors: this.isNightMode
          ? [['#05070C', 0], ['#0D1017', 1]]
          : [['#F3F6FC', 0], ['#E9EFF9', 1]],
      });

      if (this.updating) {
        this.BusyOverlay();
      }
    }
    .width('100%')
    .height('100%');
  }
}
