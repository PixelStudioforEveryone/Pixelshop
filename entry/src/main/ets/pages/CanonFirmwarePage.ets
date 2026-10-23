/**
 * 佳能（Canon）固件更新页：4 步式。
 *
 *   1 检查版本      → CanonFirmwareService.readCameraState + fetchCatalog
 *   2 下载固件      → CanonFirmwareService.download（本机落盘）
 *   3 传输到相机    → validateFir 校验 .FIR 文件头 + send（PTP/IP 推流）
 *   4 相机屏幕确认  → 相机自行重启，约 10 秒后在机身屏幕上确认
 *
 * 页面只做展示、节流与流程编排，协议/网络全部在 `CanonFirmwareService`。
 * 固件写入不可逆：传输期间锁定操作并拦截返回键。
 */

import { common } from '@kit.AbilityKit';
import { CameraSessionStore } from '../services/CameraSessionStore';
import {
  CanonFirmwareCameraState,
  CanonFirmwareDetail,
  CanonFirmwareService,
  CanonFirmwareVersionState,
  CanonFirInfo,
} from '../services/CanonFirmwareService';
import { AppLogSink } from '../services/AppLogSink';
import { AppLogStore } from './home/HomeShared';

const CANON_FW_TAG: string = 'CANON_FW';

/** 下载 / 传输流程状态（@State 只允许基础类型，故用字符串常量而非枚举对象）。 */
const ST_IDLE: string = 'idle';
const ST_RUNNING: string = 'running';
const ST_DONE: string = 'done';
const ST_FAILED: string = 'failed';
const ST_CANCELLED: string = 'cancelled';

const COLOR_ACCENT: string = '#316CF4';
const COLOR_TEXT: string = '#F4F7FC';
const COLOR_MUTED: string = '#9BA8BC';
const COLOR_OK: string = '#4ADE80';
const COLOR_WARN: string = '#F5A524';
const COLOR_DANGER: string = '#FF6B5E';
const CARD_BG: string = 'rgba(255,255,255,0.06)';
const CARD_BORDER: string = 'rgba(255,255,255,0.08)';

const CANON_FW_STEPS: string[] = [
  '检查版本',
  '下载固件',
  '传输到相机',
  '相机屏幕确认',
];

/** 注意事项：用相机格式化存储卡、电池满电/AC 适配器、勿断电勿拔卡、拆下镜头以外的附件。 */
const CANON_FW_NOTES: string[] = [
  '用相机格式化存储卡，避免旧文件占用空间或分区异常。',
  '电池满电，或使用 AC 适配器供电。',
  '传输中勿断电、勿拔卡，也不要关闭相机。',
  '拆下镜头以外的附件（遮光罩、闪光灯等），避免传输中受力或遮挡。',
];

@Entry
@Component
struct CanonFirmwarePage {
  @State private brandOk: boolean = true;
  @State private modelName: string = 'Canon';
  @State private hostText: string = '';
  @State private connected: boolean = false;
  @State private checking: boolean = false;
  @State private currentVersion: string = '';
  @State private latestVersion: string = '';
  @State private fileSizeText: string = '—';
  @State private productIdText: string = '—';
  @State private hasUpdate: boolean = false;
  @State private detailReady: boolean = false;
  @State private catalogMessage: string = '';
  @State private currentStep: number = 1;

  @State private downloadState: string = ST_IDLE;
  @State private downloadPercent: number = 0;
  @State private downloadReceivedMb: number = 0;
  @State private downloadTotalMb: number = 0;
  @State private downloadError: string = '';

  @State private firReady: boolean = false;
  @State private firName: string = '';
  @State private firModelText: string = '未知';
  @State private firModelMatches: boolean = false;
  @State private firVersion: string = '未知';
  @State private firValid: boolean = false;
  @State private firReason: string = '';

  @State private transferState: string = ST_IDLE;
  @State private transferPercent: number = 0;
  @State private transferError: string = '';
  @State private transferCode: string = '';

  /** 云端详情（非 UI 状态，仅为 download 参数保留）。 */
  private detail: CanonFirmwareDetail | null = null;
  /** 已落盘的固件路径（send 参数）。 */
  private firPath: string = '';
  /** 相机机型 ID（用于判断 .FIR 是否与当前机身匹配）。 */
  private cameraModelId: number = -1;
  private cancelRequested: boolean = false;

  aboutToAppear(): void {
    // 服务要把 .FIR 落到 context.filesDir；页面是唯一拿到 UIAbilityContext 的地方。
    try {
      CanonFirmwareService.configure(getContext(this) as common.UIAbilityContext);
    } catch (error) {
      this.trace(`注入 context 失败 ${String(error)}`);
    }
    this.hostText = this.readHost();
    const store: CameraSessionStore = CameraSessionStore.instance;
    if (store.cameraBrand !== 'Canon') {
      this.brandOk = false;
      this.trace(`品牌不匹配 brand=${store.cameraBrand}，拒绝进入佳能固件页`);
      return;
    }
    this.brandOk = true;
    const model: string = store.cameraModel.trim();
    if (model.length > 0) {
      this.modelName = model;
    }
    this.trace(`进入佳能固件更新页 model=${this.modelName} host=${this.hostText}`);
    this.loadState();
  }

  /** 下载/传输中返回：先请求取消并提示，再放行返回。 */
  onBackPress(): boolean {
    if (this.isBusy()) {
      this.requestCancel();
      this.toast('已请求取消当前任务');
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // 数据
  // -------------------------------------------------------------------------

  private readHost(): string {
    try {
      const value: string | undefined = AppStorage.get<string>('canonHost');
      if (value === undefined) {
        return '';
      }
      return value.trim();
    } catch (error) {
      this.trace(`读取 canonHost 失败 ${String(error)}`);
      return '';
    }
  }

  private async loadState(): Promise<void> {
    if (this.isBusy()) {
      return;
    }
    this.checking = true;
    this.catalogMessage = '正在读取相机型号与固件版本…';
    try {
      const camera: CanonFirmwareCameraState = await CanonFirmwareService.readCameraState();
      this.connected = camera.connected;
      if (camera.model.length > 0) {
        this.modelName = camera.model;
      }
      if (camera.firmware.length > 0) {
        this.currentVersion = camera.firmware;
      }
      if (camera.modelId > 0) {
        this.cameraModelId = camera.modelId;
      }
      if (camera.productIdHex.length > 0) {
        this.productIdText = `0x${camera.productIdHex.toUpperCase()}`;
      }
      this.trace(`相机状态 model=${camera.model} fw=${camera.firmware} ` +
        `modelId=${camera.modelId} connected=${camera.connected}`);
      if (!this.connected) {
        this.catalogMessage = '需要先连接相机（BLE + Wi-Fi）';
        this.hasUpdate = false;
        return;
      }
      if (camera.productIdHex.length === 0) {
        this.catalogMessage = '未读取到产品 ID，无法获取云端固件清单';
        this.hasUpdate = false;
        return;
      }
      this.catalogMessage = '正在获取云端固件清单…';
      try {
        const version: CanonFirmwareVersionState =
          await CanonFirmwareService.fetchCatalog(camera.productIdHex);
        this.applyCatalog(version);
      } catch (error) {
        this.hasUpdate = false;
        this.catalogMessage = `获取固件清单失败：${String(error)}`;
        this.trace(`获取清单异常 ${String(error)}`);
      }
    } catch (error) {
      this.connected = false;
      this.hasUpdate = false;
      this.catalogMessage = `读取相机状态失败：${String(error)}`;
      this.trace(`读取相机状态异常 ${String(error)}`);
    } finally {
      this.checking = false;
      this.refreshStep();
    }
  }

  private applyCatalog(state: CanonFirmwareVersionState): void {
    if (state.current.length > 0) {
      this.currentVersion = state.current;
    }
    this.latestVersion = state.latest;
    this.hasUpdate = state.hasUpdate;
    this.catalogMessage = state.message;
    if (state.productIdHex.length > 0) {
      this.productIdText = `0x${state.productIdHex.toUpperCase()}`;
    }
    const detail: CanonFirmwareDetail | null = state.detail;
    if (detail !== null) {
      this.detail = detail;
      this.detailReady = true;
      this.fileSizeText = `${this.mbValue(detail.fileSize).toFixed(1)} MB`;
      if (detail.productIdHex.length > 0) {
        this.productIdText = `0x${detail.productIdHex.toUpperCase()}`;
      }
    } else {
      this.detail = null;
      this.detailReady = false;
      this.fileSizeText = '—';
    }
    this.trace(`清单 current=${this.currentVersion} latest=${this.latestVersion} ` +
      `hasUpdate=${this.hasUpdate} detail=${this.detailReady} message=${this.catalogMessage}`);
    this.refreshStep();
  }

  // -------------------------------------------------------------------------
  // 步骤 2：下载
  // -------------------------------------------------------------------------

  private async startDownload(): Promise<void> {
    const detail: CanonFirmwareDetail | null = this.detail;
    if (detail === null) {
      this.toast('没有可下载的固件信息，请先检查版本');
      return;
    }
    if (!this.connected) {
      this.toast('需要先连接相机（BLE + Wi-Fi）');
      return;
    }
    if (!this.hasUpdate) {
      this.toast('已是最新版本，无需下载');
      return;
    }
    if (this.isBusy()) {
      this.toast('已有任务在进行中');
      return;
    }
    this.downloadState = ST_RUNNING;
    this.downloadPercent = 0;
    this.downloadReceivedMb = 0;
    this.downloadTotalMb = this.mbValue(detail.fileSize);
    this.downloadError = '';
    this.firReady = false;
    this.firValid = false;
    this.firModelMatches = false;
    this.firReason = '';
    this.firPath = '';
    this.transferState = ST_IDLE;
    this.transferPercent = 0;
    this.transferError = '';
    this.transferCode = '';
    this.cancelRequested = false;
    this.refreshStep();
    this.trace(`下载开始 version=${detail.version} size=${detail.fileSize} ` +
      `url=${detail.firmwareUrl}`);

    let path: string = '';
    try {
      path = await CanonFirmwareService.download(detail,
        (percent: number, received: number, total: number): void => {
          this.downloadPercent = percent;
          this.downloadReceivedMb = this.mbValue(received);
          if (total > 0) {
            this.downloadTotalMb = this.mbValue(total);
          }
        });
    } catch (error) {
      this.downloadState = ST_FAILED;
      this.downloadError = `下载失败：${String(error)}`;
      this.trace(`下载失败 ${String(error)}`);
      return;
    }
    if (this.cancelRequested) {
      this.downloadState = ST_CANCELLED;
      this.downloadError = '下载已取消';
      this.trace('下载已取消');
      return;
    }
    if (path.length === 0) {
      this.downloadState = ST_FAILED;
      this.downloadError = '下载失败：未获得本地固件路径';
      this.trace('下载失败：path 为空');
      return;
    }
    this.firPath = path;
    this.downloadState = ST_DONE;
    this.downloadPercent = 100;
    this.downloadReceivedMb = this.downloadTotalMb;
    this.trace(`下载完成 path=${path}`);
    AppLogStore.add(`[CANON_FW] 固件已下载：${this.fileNameOf(path)}`);
    await this.verifyFir(path);
    this.refreshStep();
  }

  private async verifyFir(path: string): Promise<void> {
    try {
      const info: CanonFirInfo = await CanonFirmwareService.validateFir(path);
      this.firReady = true;
      this.firName = this.fileNameOf(path);
      this.firModelText = info.modelId > 0 ? String(info.modelId) : '未知';
      this.firModelMatches = this.cameraModelId > 0 && info.modelId === this.cameraModelId;
      this.firVersion = info.version.length > 0 ? info.version : '未知';
      this.firValid = info.valid;
      if (info.reason.length > 0) {
        this.firReason = info.reason;
      } else {
        this.firReason = info.valid ? '校验通过' : '校验未通过';
      }
      this.trace(`FIR 校验 valid=${info.valid} modelId=${info.modelId} ` +
        `version=${info.version} reason=${info.reason}`);
    } catch (error) {
      this.firReady = true;
      this.firName = this.fileNameOf(path);
      this.firModelText = '未知';
      this.firModelMatches = false;
      this.firVersion = '未知';
      this.firValid = false;
      this.firReason = `校验异常：${String(error)}`;
      this.trace(`FIR 校验异常 ${String(error)}`);
    }
    this.refreshStep();
  }

  // -------------------------------------------------------------------------
  // 步骤 3：传输
  // -------------------------------------------------------------------------

  private async startTransfer(): Promise<void> {
    if (!this.connected) {
      this.toast('需要先连接相机（BLE + Wi-Fi）');
      return;
    }
    if (!this.firReady || !this.firValid) {
      this.toast('固件文件未通过校验，不能传输');
      return;
    }
    if (!this.firModelMatches) {
      this.toast('固件机型与当前相机不一致');
      return;
    }
    if (this.firPath.length === 0) {
      this.toast('没有可传输的固件文件');
      return;
    }
    if (this.isBusy()) {
      this.toast('已有任务在进行中');
      return;
    }
    this.transferState = ST_RUNNING;
    this.transferPercent = 0;
    this.transferError = '';
    this.transferCode = '';
    this.cancelRequested = false;
    this.refreshStep();
    this.trace(`开始传输 ${this.firPath}`);

    try {
      const ok: boolean = await CanonFirmwareService.send(this.firPath,
        (percent: number): void => {
          this.transferPercent = percent;
        });
      if (this.cancelRequested) {
        this.transferState = ST_CANCELLED;
        this.transferError = '传输已取消；请确认相机状态，必要时重新开始';
        this.trace('传输已取消');
      } else if (ok) {
        this.transferState = ST_DONE;
        this.transferPercent = 100;
        this.trace('传输完成，等待相机屏幕确认');
        AppLogStore.add('[CANON_FW] 固件传输完成，等待相机重启与屏幕确认');
      } else {
        this.transferState = ST_FAILED;
        this.transferError = '相机拒绝了固件传输（PTP 会话中断或机型不匹配）';
        this.transferCode = '未回传';
        this.trace('传输失败 ok=false');
      }
    } catch (error) {
      this.transferState = ST_FAILED;
      this.transferError = `传输异常：${String(error)}`;
      this.transferCode = '未回传';
      this.trace(`传输异常 ${String(error)}`);
    }
    this.refreshStep();
  }

  private async requestCancel(): Promise<void> {
    if (!this.isBusy()) {
      return;
    }
    this.cancelRequested = true;
    this.trace('用户请求取消，调用 CanonFirmwareService.cancel()');
    try {
      await CanonFirmwareService.cancel();
      this.toast('已请求取消');
    } catch (error) {
      this.trace(`取消失败 ${String(error)}`);
      this.toast('取消失败，请断开相机连接');
    }
  }

  private refreshStep(): void {
    if (this.transferState === ST_DONE) {
      this.currentStep = 4;
      return;
    }
    if (this.transferState === ST_RUNNING) {
      this.currentStep = 3;
      return;
    }
    if (this.downloadState === ST_DONE) {
      this.currentStep = (!this.firReady || this.firValid) ? 3 : 2;
      return;
    }
    this.currentStep = this.hasUpdate ? 2 : 1;
  }

  // -------------------------------------------------------------------------
  // 判定
  // -------------------------------------------------------------------------

  private isBusy(): boolean {
    return this.downloadState === ST_RUNNING || this.transferState === ST_RUNNING;
  }

  private canDownload(): boolean {
    return this.connected && this.hasUpdate && this.detailReady && !this.isBusy();
  }

  private canTransfer(): boolean {
    return this.connected && this.firReady && this.firValid &&
      this.firModelMatches && !this.isBusy();
  }

  private downloadButtonLabel(): string {
    return this.hasUpdate ? '下载固件' : '已是最新版本';
  }

  private ptpExplanation(): string {
    return 'PTP/IP 通道中断：请确认相机仍保持 Wi-Fi 连接、存储卡可用且剩余空间充足，' +
      '再点「重试传输」。若多次失败，请在相机端重新进入固件升级菜单。';
  }

  // -------------------------------------------------------------------------
  // 工具
  // -------------------------------------------------------------------------

  private mbValue(bytes: number): number {
    if (bytes <= 0) {
      return 0;
    }
    return bytes / 1048576;
  }

  private percentText(percent: number): string {
    return `${Math.round(percent)}%`;
  }

  private fileNameOf(path: string): string {
    const slash: number = path.lastIndexOf('/');
    const backslash: number = path.lastIndexOf('\\');
    const index: number = Math.max(slash, backslash);
    if (index >= 0 && index < path.length - 1) {
      return path.substring(index + 1);
    }
    return path;
  }

  private trace(message: string): void {
    try {
      AppLogSink.emit(CANON_FW_TAG, message);
    } catch (_error) {
      // 日志失败不影响固件流程。
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
    } catch (_error) {
      // 提示失败不影响主流程。
    }
  }

  private subTitleLine(): string {
    if (this.hostText.length > 0) {
      return `${this.modelName} · ${this.hostText}`;
    }
    return this.modelName;
  }

  private stepMark(index: number): string {
    if (index < this.currentStep) {
      return '✓';
    }
    return String(index);
  }

  private stepNumberColor(index: number): string {
    if (index === this.currentStep) {
      return '#FFFFFF';
    }
    if (index < this.currentStep) {
      return COLOR_OK;
    }
    return COLOR_MUTED;
  }

  private stepNumberBg(index: number): string {
    if (index === this.currentStep) {
      return COLOR_ACCENT;
    }
    if (index < this.currentStep) {
      return 'rgba(74,222,128,0.16)';
    }
    return 'rgba(255,255,255,0.08)';
  }

  private stepTitleColor(index: number): string {
    return index === this.currentStep ? COLOR_TEXT : COLOR_MUTED;
  }

  private stepTitle(index: number): string {
    return `${index} ${CANON_FW_STEPS[index - 1]}`;
  }

  private versionPillText(): string {
    if (!this.hasUpdate) {
      return '已是最新';
    }
    return this.detailReady ? '有新固件' : '暂无清单';
  }

  private onBackTap(): void {
    if (this.isBusy()) {
      this.requestCancel();
      this.toast('已请求取消，正在返回');
    }
    this.getUIContext().getRouter().back();
  }

  // -------------------------------------------------------------------------
  // 视图
  // -------------------------------------------------------------------------

  @Builder
  TopBar() {
    Row() {
      Text('‹')
        .fontSize(34)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_TEXT)
        .width(44)
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => { this.onBackTap(); });
      Column() {
        Text('固件更新')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
          .width('100%');
        Text(this.subTitleLine())
          .fontSize(11)
          .fontColor(COLOR_MUTED)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);
      Text(this.connected ? '已连接' : '未连接')
        .fontSize(10)
        .fontColor(this.connected ? COLOR_OK : COLOR_WARN)
        .padding({ left: 9, right: 9, top: 4, bottom: 4 })
        .borderRadius(9)
        .backgroundColor(this.connected
          ? 'rgba(74,222,128,0.14)' : 'rgba(245,165,36,0.14)');
    }
    .width('100%')
    .padding({ left: 10, right: 16, top: 10, bottom: 6 })
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(COLOR_MUTED)
        .width(84);
      Text(value)
        .fontSize(12)
        .fontColor('#DFE6F3')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 7, bottom: 7 });
  }

  @Builder
  StepRow(index: number) {
    Row() {
      Text(this.stepMark(index))
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.stepNumberColor(index))
        .width(22)
        .height(22)
        .textAlign(TextAlign.Center)
        .borderRadius(11)
        .backgroundColor(this.stepNumberBg(index));
      Text(this.stepTitle(index))
        .fontSize(12)
        .fontColor(this.stepTitleColor(index))
        .fontWeight(index === this.currentStep ? FontWeight.Medium : FontWeight.Normal)
        .margin({ left: 10 })
        .layoutWeight(1);
      if (index < this.currentStep) {
        Text('已完成')
          .fontSize(10)
          .fontColor(COLOR_OK);
      } else if (index === this.currentStep) {
        Text('进行中')
          .fontSize(10)
          .fontColor('#8FB0FF');
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor(index === this.currentStep ? 'rgba(49,108,244,0.18)' : 'rgba(0,0,0,0)')
    .margin({ top: 4 })
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  StepCard() {
    Column() {
      this.StepRow(1)
      this.StepRow(2)
      this.StepRow(3)
      this.StepRow(4)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(18)
    .backgroundColor(CARD_BG)
    .border({ width: 1, color: CARD_BORDER })
    .margin({ top: 12 });
  }

  @Builder
  VersionCard() {
    Column() {
      Row() {
        Text(this.modelName)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.versionPillText())
          .fontSize(10)
          .fontColor(this.hasUpdate ? COLOR_WARN : COLOR_MUTED)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor(this.hasUpdate
            ? 'rgba(245,165,36,0.14)' : 'rgba(160,175,200,0.12)');
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      this.InfoRow('当前版本', this.currentVersion.length > 0 ? this.currentVersion : '未读到')
      this.InfoRow('最新版本', this.latestVersion.length > 0 ? this.latestVersion : '—')
      this.InfoRow('固件大小', this.fileSizeText)
      this.InfoRow('产品 ID', this.productIdText)
      if (this.hostText.length > 0) {
        this.InfoRow('相机地址', this.hostText)
      }

      if (this.checking) {
        Row() {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(COLOR_ACCENT);
          Text(this.catalogMessage)
            .fontSize(11)
            .fontColor(COLOR_MUTED)
            .margin({ left: 8 })
            .layoutWeight(1);
        }
        .width('100%')
        .margin({ top: 6 })
        .alignItems(VerticalAlign.Center);
      } else if (!this.connected) {
        Text('需要先连接相机（BLE + Wi-Fi）')
          .fontSize(12)
          .fontColor(COLOR_WARN)
          .lineHeight(18)
          .width('100%')
          .margin({ top: 6 });
        Button('重试')
          .type(ButtonType.Normal)
          .borderRadius(12)
          .height(38)
          .width('100%')
          .fontSize(12)
          .backgroundColor('rgba(255,255,255,0.10)')
          .fontColor(COLOR_TEXT)
          .margin({ top: 10 })
          .onClick(() => { this.loadState(); });
      } else if (!this.hasUpdate) {
        Text('已是最新版本')
          .fontSize(12)
          .fontColor(COLOR_OK)
          .lineHeight(18)
          .width('100%')
          .margin({ top: 6 });
      } else if (this.catalogMessage.length > 0) {
        Text(this.catalogMessage)
          .fontSize(11)
          .fontColor(COLOR_MUTED)
          .lineHeight(17)
          .width('100%')
          .margin({ top: 6 });
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(18)
    .backgroundColor(CARD_BG)
    .border({ width: 1, color: CARD_BORDER })
    .margin({ top: 12 });
  }

  @Builder
  NoticeCard() {
    Column() {
      Text('注意事项')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TEXT)
        .width('100%')
        .margin({ bottom: 6 });
      ForEach(CANON_FW_NOTES, (note: string) => {
        Row() {
          Text('•')
            .fontSize(12)
            .fontColor(COLOR_WARN)
            .width(12);
          Text(note)
            .fontSize(11)
            .fontColor('#C3CCDA')
            .lineHeight(18)
            .layoutWeight(1);
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ top: 3, bottom: 3 });
      }, (note: string, index: number) => `${index}-${note}`);
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(18)
    .backgroundColor(CARD_BG)
    .border({ width: 1, color: CARD_BORDER })
    .margin({ top: 12 });
  }

  @Builder
  DownloadCard() {
    Column() {
      Row() {
        Text('2 下载固件')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
          .layoutWeight(1);
        if (this.downloadState === ST_DONE) {
          Text('已下载')
            .fontSize(10)
            .fontColor(COLOR_OK);
        } else if (this.downloadState === ST_RUNNING) {
          Text(this.percentText(this.downloadPercent))
            .fontSize(11)
            .fontColor('#8FB0FF');
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Text('固件包先下载到手机本地，校验 .FIR 文件头后再传输到相机。')
        .fontSize(11)
        .fontColor(COLOR_MUTED)
        .lineHeight(17)
        .width('100%')
        .margin({ top: 6 });

      if (this.downloadState === ST_RUNNING) {
        Progress({ value: this.downloadPercent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .margin({ top: 12 })
          .color(COLOR_ACCENT)
          .backgroundColor('rgba(255,255,255,0.12)');
        Row() {
          Text(`${this.downloadReceivedMb.toFixed(1)} / ${this.downloadTotalMb.toFixed(1)} MB`)
            .fontSize(11)
            .fontColor(COLOR_MUTED)
            .layoutWeight(1);
          Text('下载中…')
            .fontSize(11)
            .fontColor('#8FB0FF');
        }
        .width('100%')
        .margin({ top: 6 });
        Button(this.cancelRequested ? '正在取消…' : '取消下载')
          .type(ButtonType.Normal)
          .borderRadius(12)
          .height(38)
          .width('100%')
          .fontSize(12)
          .backgroundColor('rgba(255,255,255,0.10)')
          .fontColor(COLOR_TEXT)
          .margin({ top: 12 })
          .enabled(!this.cancelRequested)
          .onClick(() => { this.requestCancel(); });
      } else if (this.downloadState === ST_DONE) {
        Text(`已保存：${this.firName.length > 0 ? this.firName : '固件文件'}（` +
          `${this.downloadTotalMb.toFixed(1)} MB）`)
          .fontSize(11)
          .fontColor('#C3CCDA')
          .lineHeight(17)
          .width('100%')
          .margin({ top: 8 });
        Button('重新下载')
          .type(ButtonType.Normal)
          .borderRadius(12)
          .height(38)
          .width('100%')
          .fontSize(12)
          .backgroundColor('rgba(255,255,255,0.10)')
          .fontColor(COLOR_TEXT)
          .margin({ top: 10 })
          .enabled(this.canDownload())
          .onClick(() => { this.startDownload(); });
      } else if (this.downloadState === ST_FAILED || this.downloadState === ST_CANCELLED) {
        Text(this.downloadError.length > 0 ? this.downloadError : '下载失败')
          .fontSize(11)
          .fontColor(COLOR_DANGER)
          .lineHeight(17)
          .width('100%')
          .margin({ top: 8 });
        Button('重试下载')
          .type(ButtonType.Normal)
          .borderRadius(12)
          .height(40)
          .width('100%')
          .fontSize(13)
          .backgroundColor(this.canDownload() ? COLOR_ACCENT : '#2A3140')
          .fontColor(this.canDownload() ? '#FFFFFF' : COLOR_MUTED)
          .margin({ top: 10 })
          .enabled(this.canDownload())
          .onClick(() => { this.startDownload(); });
      } else {
        Button(this.downloadButtonLabel())
          .type(ButtonType.Normal)
          .borderRadius(12)
          .height(40)
          .width('100%')
          .fontSize(13)
          .backgroundColor(this.canDownload() ? COLOR_ACCENT : '#2A3140')
          .fontColor(this.canDownload() ? '#FFFFFF' : COLOR_MUTED)
          .margin({ top: 10 })
          .enabled(this.canDownload())
          .onClick(() => { this.startDownload(); });
        if (!this.connected) {
          Text('需要先连接相机（BLE + Wi-Fi）')
            .fontSize(10)
            .fontColor(COLOR_MUTED)
            .width('100%')
            .margin({ top: 6 });
        } else if (!this.hasUpdate) {
          Text('已是最新版本，无需下载')
            .fontSize(10)
            .fontColor(COLOR_MUTED)
            .width('100%')
            .margin({ top: 6 });
        }
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(18)
    .backgroundColor(CARD_BG)
    .border({ width: 1, color: CARD_BORDER })
    .margin({ top: 12 });
  }

  @Builder
  FirCard() {
    Column() {
      Row() {
        Text('FIR 校验结果')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
          .layoutWeight(1);
        Text(this.firValid ? '有效' : '无效')
          .fontSize(10)
          .fontColor(this.firValid ? COLOR_OK : COLOR_DANGER)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor(this.firValid
            ? 'rgba(74,222,128,0.14)' : 'rgba(255,107,94,0.14)');
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      this.InfoRow('文件名', this.firName.length > 0 ? this.firName : '—')
      this.InfoRow('机型 ID', `${this.firModelText}` +
        `（${this.firModelMatches ? '与当前机型一致' : '与当前机型不一致'}）`)
      this.InfoRow('文件版本', this.firVersion)
      this.InfoRow('校验结果', this.firValid ? '有效' : '无效')

      if (this.firReason.length > 0) {
        Text(this.firReason)
          .fontSize(11)
          .fontColor(this.firValid ? COLOR_MUTED : COLOR_DANGER)
          .lineHeight(17)
          .width('100%')
          .margin({ top: 6 });
      }
      if (!this.firValid || !this.firModelMatches) {
        Text('固件文件与当前机身不匹配或内容不完整，禁止传输。请回到第 2 步重新下载。')
          .fontSize(10)
          .fontColor(COLOR_MUTED)
          .lineHeight(16)
          .width('100%')
          .margin({ top: 6 });
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(18)
    .backgroundColor(CARD_BG)
    .border({ width: 1, color: CARD_BORDER })
    .margin({ top: 12 });
  }

  @Builder
  TransferCard() {
    Column() {
      Row() {
        Text('3 传输到相机')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
          .layoutWeight(1);
        if (this.transferState === ST_DONE) {
          Text('已发送')
            .fontSize(10)
            .fontColor(COLOR_OK);
        } else if (this.transferState === ST_RUNNING) {
          Text(this.percentText(this.transferPercent))
            .fontSize(11)
            .fontColor('#8FB0FF');
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      if (this.transferState === ST_RUNNING) {
        Progress({ value: this.transferPercent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .margin({ top: 12 })
          .color(COLOR_ACCENT)
          .backgroundColor('rgba(255,255,255,0.12)');
        Text('请勿断电')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_DANGER)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 10 });
        Text('传输中断可能导致相机无法启动，请保持相机开机与 Wi-Fi 连接。')
          .fontSize(10)
          .fontColor(COLOR_MUTED)
          .lineHeight(16)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 4 });
        Button(this.cancelRequested ? '正在取消…' : '取消传输')
          .type(ButtonType.Normal)
          .borderRadius(12)
          .height(38)
          .width('100%')
          .fontSize(12)
          .backgroundColor('rgba(255,255,255,0.10)')
          .fontColor(COLOR_TEXT)
          .margin({ top: 12 })
          .enabled(!this.cancelRequested)
          .onClick(() => { this.requestCancel(); });
      } else if (this.transferState === ST_DONE) {
        Text('固件已发送到相机，机身正在写入。')
          .fontSize(11)
          .fontColor('#C3CCDA')
          .lineHeight(17)
          .width('100%')
          .margin({ top: 8 });
        Text('相机将重启，约 10 秒后请在相机屏幕确认升级')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_OK)
          .lineHeight(18)
          .width('100%')
          .margin({ top: 8 });
      } else if (this.transferState === ST_FAILED || this.transferState === ST_CANCELLED) {
        Text(this.transferError.length > 0 ? this.transferError : '传输失败')
          .fontSize(11)
          .fontColor(COLOR_DANGER)
          .lineHeight(17)
          .width('100%')
          .margin({ top: 8 });
        Text(`PTP 错误码：${this.transferCode.length > 0 ? this.transferCode : '未回传'}`)
          .fontSize(11)
          .fontColor(COLOR_TEXT)
          .width('100%')
          .margin({ top: 6 });
        Text(this.ptpExplanation())
          .fontSize(10)
          .fontColor(COLOR_MUTED)
          .lineHeight(16)
          .width('100%')
          .margin({ top: 4 });
        Button('重试传输')
          .type(ButtonType.Normal)
          .borderRadius(12)
          .height(40)
          .width('100%')
          .fontSize(13)
          .backgroundColor(this.canTransfer() ? COLOR_ACCENT : '#2A3140')
          .fontColor(this.canTransfer() ? '#FFFFFF' : COLOR_MUTED)
          .margin({ top: 10 })
          .enabled(this.canTransfer())
          .onClick(() => { this.startTransfer(); });
      } else {
        Text('通过 PTP/IP 把 .FIR 写入相机。传输前请确保电量充足。')
          .fontSize(11)
          .fontColor(COLOR_MUTED)
          .lineHeight(17)
          .width('100%')
          .margin({ top: 6 });
        Button('传输到相机')
          .type(ButtonType.Normal)
          .borderRadius(12)
          .height(40)
          .width('100%')
          .fontSize(13)
          .backgroundColor(this.canTransfer() ? COLOR_ACCENT : '#2A3140')
          .fontColor(this.canTransfer() ? '#FFFFFF' : COLOR_MUTED)
          .margin({ top: 10 })
          .enabled(this.canTransfer())
          .onClick(() => { this.startTransfer(); });
        if (!this.connected) {
          Text('需要先连接相机（BLE + Wi-Fi）')
            .fontSize(10)
            .fontColor(COLOR_MUTED)
            .width('100%')
            .margin({ top: 6 });
        } else if (!this.firReady) {
          Text('请先完成第 2 步下载与校验')
            .fontSize(10)
            .fontColor(COLOR_MUTED)
            .width('100%')
            .margin({ top: 6 });
        } else if (!this.firValid || !this.firModelMatches) {
          Text('固件未通过校验或机型不一致，无法传输')
            .fontSize(10)
            .fontColor(COLOR_DANGER)
            .width('100%')
            .margin({ top: 6 });
        }
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(18)
    .backgroundColor(CARD_BG)
    .border({ width: 1, color: CARD_BORDER })
    .margin({ top: 12 });
  }

  @Builder
  ConfirmCard() {
    Column() {
      Text('4 相机屏幕确认')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TEXT)
        .width('100%');
      Text('相机将重启，约 10 秒后请在相机屏幕确认升级')
        .fontSize(12)
        .fontColor(COLOR_OK)
        .lineHeight(19)
        .width('100%')
        .margin({ top: 8 });
      Text('确认后相机自动重启完成安装；重启期间不要关机、不要拔卡。' +
        '版本号可在相机菜单的固件信息里核对。')
        .fontSize(10)
        .fontColor(COLOR_MUTED)
        .lineHeight(16)
        .width('100%')
        .margin({ top: 6 });
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(18)
    .backgroundColor('rgba(49,108,244,0.12)')
    .border({ width: 1, color: 'rgba(49,108,244,0.32)' })
    .margin({ top: 12 });
  }

  @Builder
  BrandMismatchCard() {
    Column() {
      Text('相机品牌不匹配')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_DANGER)
        .width('100%');
      Text('当前会话不是佳能相机，固件更新页已停用。请返回并重新连接佳能机身。')
        .fontSize(12)
        .fontColor(COLOR_MUTED)
        .lineHeight(19)
        .width('100%')
        .margin({ top: 10 });
      Button('返回')
        .type(ButtonType.Normal)
        .borderRadius(12)
        .height(42)
        .width('100%')
        .fontSize(13)
        .backgroundColor('rgba(255,255,255,0.10)')
        .fontColor(COLOR_TEXT)
        .margin({ top: 16 })
        .onClick(() => { this.getUIContext().getRouter().back(); });
    }
    .width('100%')
    .padding(16)
    .borderRadius(18)
    .backgroundColor(CARD_BG)
    .border({ width: 1, color: CARD_BORDER })
    .margin({ top: 24 });
  }

  build() {
    Column() {
      this.TopBar()

      Scroll() {
        Column() {
          if (!this.brandOk) {
            this.BrandMismatchCard()
          } else {
            this.StepCard()
            this.VersionCard()
            this.NoticeCard()
            this.DownloadCard()
            if (this.firReady) {
              this.FirCard()
            }
            this.TransferCard()
            if (this.transferState === ST_DONE) {
              this.ConfirmCard()
            }

            Text('固件写入不可逆：传输期间请保持相机开机、不要断电或拔卡。' +
              'App 侧不提供回滚，失败后请重新走完整流程。')
              .fontSize(10)
              .fontColor(COLOR_MUTED)
              .lineHeight(16)
              .width('100%')
              .margin({ top: 14 });
          }
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
      colors: [['#05070C', 0], ['#0D1017', 1]],
    });
  }
}
