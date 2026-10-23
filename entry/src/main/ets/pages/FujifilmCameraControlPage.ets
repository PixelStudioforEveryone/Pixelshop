/*
 * FUJIFILM 相机控制页（LAB 风格）
 *
 * 与松下 `CameraControlView` 完全独立：不引用它的任何状态、@Builder 或
 * 服务，只共用 `CameraSessionStore` 的会话身份与 `VividMaterial` 的卡片材质。
 *
 * 两种形态（这是本页最重要的区分）：
 *  - 预览：整屏取景 + AF 框 + 底部快门/录像。取景流**只在这个形态**推流；
 *  - 遥控：顶栏 + 身份行 + 快捷参数 + 冻结画面 + 参数网格 + 底栏。
 *    切到遥控态 `stopLiveView()`，不再从 55741 取流；参数面板全部可点可调。
 *
 * 参数码与值域严格来自 `reports/data/control_property_codes.csv` 与报告 02
 * §5.3/§5.4；没有描述符（或描述符只读）的项保持可见但置灰，点击给出提示。
 * 不伪造可写。
 */
import { image } from '@kit.ImageKit';
import { VividMaterial } from '../components/VividMaterial';
import { CameraSessionStore } from '../services/CameraSessionStore';
import {
  FujifilmCaptureEvent,
  FujifilmControlService,
  FujifilmControlSnapshot,
  FujifilmParamOption,
  FujifilmParamSpec,
  FujifilmParamCatalog,
  FujifilmPropDesc,
} from '../services/FujifilmControlService';
import { AppLogStore } from './home/HomeShared';

const FUJI_GROUP_ORDER: string[] = ['曝光', '色彩', '画质', '拍摄', '对焦', '状态', '系统'];

@Entry
@Component
struct FujifilmCameraControlPage {
  @State private valid: boolean = true;
  @State private phase: string = 'connecting';
  @State private statusText: string = '正在建立 PTP-IP 会话…';
  @State private model: string = '';
  @State private serial: string = '';
  @State private previewMode: boolean = true;
  @State private hideParams: boolean = false;
  @State private framePm: image.PixelMap | undefined = undefined;
  @State private props: FujifilmPropDesc[] = [];
  @State private propCount: number = 0;
  @State private degradedReason: string = '';
  @State private shooting: boolean = false;
  @State private recording: boolean = false;
  @State private movieMode: boolean = false;
  @State private afX: number = -1;
  @State private afY: number = -1;
  @State private afFocused: boolean = false;
  @State private previewW: number = 0;
  @State private previewH: number = 0;
  @State private selectedCode: number = 0;
  @State private selectedValue: number = 0;
  @State private showAll: boolean = false;
  @State private leaving: boolean = false;
  @State private zoomSpeed: number = 0;
  @State private warning: string = '';

  private disposed: boolean = false;
  private refreshTimer: number = -1;
  private focusTimer: number = -1;

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  aboutToAppear(): void {
    const store = CameraSessionStore.instance;
    this.valid = store.cameraBrand === 'FUJIFILM';
    this.model = store.cameraModel;
    if (!this.valid) {
      this.phase = 'error';
      this.statusText = `当前会话是 ${store.cameraBrand}，不是富士相机`;
      return;
    }
    void this.begin();
  }

  aboutToDisappear(): void {
    this.dispose();
  }

  onBackPress(): boolean {
    this.exitPage();
    return true;
  }

  private async begin(): Promise<void> {
    this.phase = 'connecting';
    this.statusText = '正在建立 PTP-IP 会话…';
    FujifilmControlService.setCallbacks({
      onCapture: (event: FujifilmCaptureEvent): void => {
        this.handleCapture(event);
      },
      onPropChanged: (code: number, value: number): void => {
        this.scheduleRefresh();
      },
      onAfDone: (): void => {
        this.afFocused = true;
      },
      onDeviceChanged: (): void => {
        void this.refreshProps(false);
      },
      onNotice: (message: string): void => {
        this.toast(message);
      },
    });
    try {
      const snapshot = await FujifilmControlService.connect(this.model);
      if (this.disposed) {
        void FujifilmControlService.shutdown();
        return;
      }
      this.applySnapshot(snapshot);
      this.phase = snapshot.propsReady ? 'ready' : 'degraded';
      this.statusText = snapshot.propsReady ? '' : '参数表不可用：仍可拍摄，参数项保持置灰';
      this.movieMode = snapshot.driveMode === 1;
      FujifilmControlService.log(
        `页面就绪 props=${snapshot.propCount} degraded=${snapshot.degradedReason}`);
      if (this.previewMode) {
        await this.startPreviewStream();
      }
    } catch (error) {
      if (this.disposed) return;
      this.phase = 'error';
      this.statusText = this.explain(error);
      FujifilmControlService.log(`连接失败：${this.describe(error)}`);
    }
  }

  private applySnapshot(snapshot: FujifilmControlSnapshot): void {
    this.model = snapshot.model.length > 0 ? snapshot.model : this.model;
    this.serial = snapshot.serial;
    this.propCount = snapshot.propCount;
    this.degradedReason = snapshot.degradedReason;
    this.props = snapshot.propsReady ? FujifilmControlService.getProps().slice() : [];
    this.updateWarning();
  }

  private updateWarning(): void {
    const status = FujifilmControlService.valueOf(0xD21B);
    if (status > 0) {
      this.warning = FujifilmParamCatalog.statusText(status);
    } else {
      this.warning = '';
    }
  }

  private handleCapture(event: FujifilmCaptureEvent): void {
    if (event.type === 'start') {
      this.shooting = true;
      FujifilmControlService.log(`事件 30：开始曝光 param=${event.param}`);
    } else if (event.type === 'complete') {
      this.shooting = false;
      this.recording = false;
      this.toast('拍摄完成');
      FujifilmControlService.log(`事件 31：曝光完成 param=${event.param}`);
    } else {
      FujifilmControlService.log(`事件 32：Postview 就绪 param=${event.param}`);
    }
  }

  private scheduleRefresh(): void {
    if (this.refreshTimer >= 0) return;
    this.refreshTimer = setTimeout((): void => {
      this.refreshTimer = -1;
      this.props = FujifilmControlService.getProps().slice();
      this.propCount = this.props.length;
      this.selectedValue = this.selectedCode > 0
        ? (FujifilmControlService.valueOf(this.selectedCode) >>> 0) : 0;
      this.updateWarning();
    }, 80);
  }

  private async refreshProps(showToast: boolean): Promise<void> {
    const ok = await FujifilmControlService.refreshProps();
    this.props = ok ? FujifilmControlService.getProps().slice() : [];
    this.propCount = this.props.length;
    this.updateWarning();
    if (showToast) this.toast(ok ? '参数已刷新' : '参数刷新失败');
  }

  // -------------------------------------------------------------------------
  // 取景
  // -------------------------------------------------------------------------

  private async startPreviewStream(): Promise<void> {
    if (this.phase !== 'ready' && this.phase !== 'degraded') return;
    try {
      await FujifilmControlService.startLiveView((pixelMap: image.PixelMap): void => {
        this.publishFrame(pixelMap);
      });
    } catch (error) {
      FujifilmControlService.log(`取景启动失败：${this.describe(error)}`);
      this.toast('取景通道打开失败，可在遥控页继续操作');
    }
  }

  private publishFrame(pixelMap: image.PixelMap): void {
    if (this.disposed) {
      pixelMap.release();
      return;
    }
    const old = this.framePm;
    this.framePm = pixelMap;
    if (old !== undefined && old !== pixelMap) {
      try {
        old.release();
      } catch (error) {
      }
    }
  }

  private releaseFrame(): void {
    const old = this.framePm;
    this.framePm = undefined;
    if (old !== undefined) {
      try {
        old.release();
      } catch (error) {
      }
    }
  }

  private toggleMode(toPreview: boolean): void {
    if (this.previewMode === toPreview) return;
    this.previewMode = toPreview;
    this.selectedCode = 0;
    this.showAll = false;
    if (toPreview) {
      FujifilmControlService.setViewMode('preview');
      void this.startPreviewStream();
    } else {
      FujifilmControlService.setViewMode('remote');
      FujifilmControlService.stopLiveView();
    }
    AppLogStore.add(toPreview ? '[FUJI] ui 进入预览（推流）' : '[FUJI] ui 进入遥控（停止推流）');
  }

  // -------------------------------------------------------------------------
  // 动作
  // -------------------------------------------------------------------------

  private async capture(): Promise<void> {
    if (this.phase === 'error' || this.phase === 'connecting') return;
    this.shooting = true;
    const ok = await FujifilmControlService.capture();
    if (!ok) {
      this.shooting = false;
      this.toast('拍摄指令失败（日志 [FUJI] InitiateCapture）');
    }
  }

  private async toggleVideo(): Promise<void> {
    if (this.phase === 'error' || this.phase === 'connecting') return;
    const want = !this.recording;
    const ok = want
      ? await FujifilmControlService.startMovie()
      : await FujifilmControlService.stopMovie();
    if (ok) {
      this.recording = want;
      this.movieMode = true;
      this.toast(want ? '开始录像' : '停止录像');
    } else {
      this.toast(want ? '开始录像失败' : '停止录像失败');
    }
  }

  private tapFocus(event: ClickEvent): void {
    if (this.phase === 'error' || this.phase === 'connecting') return;
    this.afX = event.x;
    this.afY = event.y;
    this.afFocused = false;
    const width = this.previewW > 0 ? this.previewW : 360;
    const height = this.previewH > 0 ? this.previewH : 480;
    const cellX = Math.max(1, Math.min(12, Math.floor(event.x / width * 12) + 1));
    const cellY = Math.max(1, Math.min(12, Math.floor(event.y / height * 12) + 1));
    // `[aspW][aspH][cellX][cellY]`，1-based；asp 用 3:2 的常见画幅。
    const afArea = ((3 & 0xFF) << 24) | ((2 & 0xFF) << 16) |
      ((cellX & 0xFF) << 8) | (cellY & 0xFF);
    FujifilmControlService.log(`点按对焦 cell=${cellX},${cellY} afArea=0x${(afArea >>> 0).toString(16)}`);
    void FujifilmControlService.lockS1(afArea).then((ok: boolean): void => {
      if (!ok) this.toast('对焦指令未响应');
    });
    if (this.focusTimer >= 0) clearTimeout(this.focusTimer);
    this.focusTimer = setTimeout((): void => {
      this.focusTimer = -1;
      void FujifilmControlService.unlockS1();
    }, 700);
  }

  private async zoomStep(direction: number): Promise<void> {
    const ok = await FujifilmControlService.stepZoom(direction, this.zoomSpeed);
    if (!ok) this.toast('变焦指令未响应');
  }

  private async zoomStart(direction: number): Promise<void> {
    const ok = await FujifilmControlService.startZoom(direction, this.zoomSpeed);
    if (!ok) this.toast('变焦启动失败');
  }

  private async zoomStop(): Promise<void> {
    await FujifilmControlService.stopZoom();
  }

  // -------------------------------------------------------------------------
  // 参数面板
  // -------------------------------------------------------------------------

  private available(spec: FujifilmParamSpec): boolean {
    return FujifilmControlService.propOf(spec.code) !== null;
  }

  private writable(spec: FujifilmParamSpec): boolean {
    return FujifilmControlService.canWrite(spec.code);
  }

  private paramValue(spec: FujifilmParamSpec): string {
    const text = FujifilmControlService.valueText(spec.code);
    return text.length > 0 ? text : '--';
  }

  private openPanel(spec: FujifilmParamSpec): void {
    const desc = FujifilmControlService.propOf(spec.code);
    if (desc === null) {
      this.toast(`相机未上报「${spec.label}」`);
      return;
    }
    this.selectedCode = spec.code;
    this.selectedValue = desc.current >>> 0;
    this.showAll = false;
    FujifilmControlService.log(`ui 打开参数面板 ${spec.label} 0x${spec.code.toString(16)}`);
  }

  private closePanel(): void {
    this.selectedCode = 0;
  }

  private selectedSpec(): FujifilmParamSpec | null {
    return FujifilmParamCatalog.find(this.selectedCode);
  }

  private selectedDesc(): FujifilmPropDesc | null {
    return FujifilmControlService.propOf(this.selectedCode);
  }

  private panelOptions(): FujifilmParamOption[] {
    const spec = this.selectedSpec();
    if (spec === null) return [];
    const desc = this.selectedDesc();
    if (desc !== null && desc.values.length > 0) {
      const out: FujifilmParamOption[] = [];
      for (const value of desc.values) {
        out.push({
          value: value >>> 0,
          label: FujifilmControlService.formatValue(spec.code, value),
        });
      }
      return out;
    }
    if (spec.options.length > 0) {
      return spec.options;
    }
    if (spec.code === 0x5010) {
      // 描述符没有 values 时的兜底：报告 02 §5.4.3 的 −5000…+5000 / 333。
      const out: FujifilmParamOption[] = [];
      for (let value = -5000; value <= 5000; value += 333) {
        const raw = value >>> 0;
        out.push({ value: raw, label: FujifilmControlService.evText(raw) });
      }
      return out;
    }
    return spec.options;
  }

  private panelOptionsCount(): number {
    return this.panelOptions().length;
  }

  private selectedLabel(): string {
    const spec = this.selectedSpec();
    return spec === null ? '' : spec.label;
  }

  private selectedMeta(): string {
    const spec = this.selectedSpec();
    if (spec === null) return '';
    const mode = this.writable(spec) ? '可调' : '只读';
    return `0x${spec.code.toString(16)} · ${mode}`;
  }

  private selectedIsStep(): boolean {
    const spec = this.selectedSpec();
    return spec !== null && spec.kind === 'step';
  }

  private catalogLabel(code: number): string {
    const spec = FujifilmParamCatalog.find(code);
    return spec === null ? `0x${code.toString(16)}` : spec.label;
  }

  private async applyOption(option: FujifilmParamOption): Promise<void> {
    const spec = this.selectedSpec();
    if (spec === null) return;
    if (!this.writable(spec)) {
      this.toast(FujifilmControlService.propOf(spec.code) === null
        ? '相机未上报该参数' : '该参数为只读');
      return;
    }
    const ok = await FujifilmControlService.setValue(spec.code, option.value);
    if (ok) {
      this.selectedValue = option.value >>> 0;
      this.toast(`${spec.label} 已设为 ${option.label}`);
      this.scheduleRefresh();
    } else {
      this.toast(`${spec.label} 设置失败`);
    }
  }

  private async applyStep(direction: number): Promise<void> {
    const spec = this.selectedSpec();
    if (spec === null) return;
    if (!this.writable(spec)) {
      this.toast('该参数为只读');
      return;
    }
    const ok = await FujifilmControlService.step(spec.code, direction);
    if (!ok) {
      this.toast('步进指令未响应');
      return;
    }
    setTimeout((): void => {
      this.selectedValue = FujifilmControlService.valueOf(spec.code) >>> 0;
      this.scheduleRefresh();
    }, 450);
  }

  // -------------------------------------------------------------------------
  // 退出
  // -------------------------------------------------------------------------

  private exitPage(): void {
    if (this.leaving) return;
    this.leaving = true;
    this.dispose();
    const router = this.getUIContext().getRouter();
    void Promise.race([FujifilmControlService.shutdown(), this.delay(2500)])
      .then((): void => {
        try {
          router.back();
        } catch (error) {
        }
      });
  }

  private dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    FujifilmControlService.clearCallbacks();
    FujifilmControlService.stopLiveView();
    this.releaseFrame();
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    if (this.focusTimer >= 0) {
      clearTimeout(this.focusTimer);
      this.focusTimer = -1;
    }
    if (!this.leaving) {
      void FujifilmControlService.shutdown();
    }
    AppLogStore.add('[FUJI] ui 页面销毁');
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private explain(error: Object): string {
    const message = this.describe(error);
    if (message.indexOf('ECONNREFUSED') >= 0 || message.indexOf('connect') >= 0 ||
      message.indexOf('timeout') >= 0 || message.indexOf('timed out') >= 0 ||
      message.indexOf('连接') >= 0 || message.indexOf('未建立') >= 0) {
      return '无法连接相机（192.168.0.1:55740）。请先在系统 Wi-Fi 里连上相机热点，' +
        '确认相机处于遥控模式，然后点「重试」。';
    }
    return `连接失败：${message}`;
  }

  private describe(error: Object): string {
    if (error instanceof Error) return error.message;
    return String(error);
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (!this.valid) {
        this.fatalScreen('当前会话不是富士相机', '请从相机页的富士入口进入');
      } else if (this.phase === 'error') {
        this.fatalScreen('连接未建立', this.statusText);
      } else if (this.previewMode) {
        this.previewScreen();
      } else {
        this.remoteScreen();
      }
      if (this.selectedCode > 0) {
        this.paramSheet();
      }
      if (this.showAll) {
        this.allParamsSheet();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0D1017');
  }

  @Builder
  private fatalScreen(title: string, detail: string) {
    Column({ space: 12 }) {
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF');
      Text(detail)
        .fontSize(13)
        .fontColor('#8A97AB')
        .textAlign(TextAlign.Center)
        .padding({ left: 28, right: 28 });
      Row({ space: 10 }) {
        Button('重试')
          .backgroundColor('#2563EB')
          .fontColor('#FFFFFF')
          .fontSize(14)
          .height(42)
          .layoutWeight(1)
          .onClick((): void => {
            this.disposed = false;
            this.leaving = false;
            void this.begin();
          });
        Button('返回')
          .backgroundColor('#232833')
          .fontColor('#FFFFFF')
          .fontSize(14)
          .height(42)
          .layoutWeight(1)
          .onClick((): void => {
            this.exitPage();
          });
      }
      .width('100%')
      .padding({ left: 28, right: 28, top: 6 });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#0D1017');
  }

  // ---- 预览形态 -----------------------------------------------------------

  @Builder
  private previewScreen() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.framePm !== undefined) {
        Image(this.framePm)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .backgroundColor('#000000')
          .onAreaChange((oldValue: Area, newValue: Area): void => {
            this.previewW = Number(newValue.width);
            this.previewH = Number(newValue.height);
          })
          .onClick((event: ClickEvent): void => {
            this.tapFocus(event);
          });
      } else {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(38)
            .height(38)
            .color('#FFFFFF');
          Text(this.phase === 'connecting' ? this.statusText : '等待相机画面…')
            .fontSize(13)
            .fontColor('#FFFFFF');
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#000000');
      }

      if (this.afX >= 0) {
        Stack({ alignContent: Alignment.Center }) {
          Text('')
            .width(1)
            .height(1)
        }
        .width(76)
        .height(76)
        .border({ width: 2, color: this.afFocused ? '#34D399' : '#FFFFFF' })
        .borderRadius(6)
        .position({ x: this.afX - 38, y: this.afY - 38 })
        Text(this.afFocused ? 'AF 已合焦' : 'AF 对焦中')
          .fontSize(9)
          .fontColor(this.afFocused ? '#34D399' : '#FFFFFF')
          .backgroundColor('#99000000')
          .borderRadius(4)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .position({ x: this.afX - 24, y: this.afY + 42 })
      }

      Column() {
        this.previewTopBar();
        Blank();
        if (!this.hideParams) {
          this.previewChips();
        }
        this.previewBottomBar();
      }
      .width('100%')
      .height('100%')
      .padding({ top: 26, bottom: 22 })
      .hitTestBehavior(HitTestMode.Transparent);
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000');
  }

  @Builder
  private previewTopBar() {
    Row({ space: 8 }) {
      Text('‹')
        .fontSize(28)
        .fontColor('#FFFFFF')
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .onClick((): void => {
          this.exitPage();
        });
      Column({ space: 1 }) {
        Text('相机控制')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF');
        Text(this.model.length > 0 ? this.model : 'FUJIFILM')
          .fontSize(10)
          .fontColor('#C7D0DE');
      }
      .alignItems(HorizontalAlign.Start);
      if (this.degradedReason.length > 0) {
        Text('降级')
          .fontSize(9)
          .fontColor('#0D1017')
          .backgroundColor('#F59E0B')
          .borderRadius(6)
          .padding({ left: 5, right: 5, top: 2, bottom: 2 });
      }
      Blank();
      Row() {
        Text(this.hideParams ? '显示参数' : '隐藏参数')
          .fontSize(11)
          .fontColor(this.hideParams ? '#8A97AB' : '#FFFFFF')
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .onClick((): void => {
            this.hideParams = !this.hideParams;
          });
        Text('遥控')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor('#2563EB')
          .borderRadius(12)
          .onClick((): void => {
            this.toggleMode(false);
          });
      }
      .backgroundColor('#232833')
      .borderRadius(15)
      .padding(3);
    }
    .width('100%')
    .height(54)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  private previewChips() {
    Scroll() {
      Row({ space: 8 }) {
        this.readonlyChip('EV', 0x5010);
        this.readonlyChip('快门', 0xD240);
        this.readonlyChip('光圈', 0x5007);
        this.readonlyChip('ISO', 0xD02A);
        this.readonlyChip('胶片', 0xD001);
      }
      .padding({ left: 12, right: 12 });
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ bottom: 10 });
  }

  @Builder
  private readonlyChip(label: string, code: number) {
    Row({ space: 5 }) {
      Text(label)
        .fontSize(10)
        .fontColor('#C7D0DE');
      Text(FujifilmControlService.valueText(code))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .maxLines(1);
    }
    .backgroundColor('#66000000')
    .borderRadius(12)
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .onClick((): void => {
      this.toast('预览模式参数只读，切到遥控可调');
    });
  }

  @Builder
  private previewBottomBar() {
    Row({ space: 22 }) {
      Column({ space: 4 }) {
        Circle()
          .width(44)
          .height(44)
          .fill(this.recording ? '#E5484D' : '#661A1E27')
          .stroke('#E5484D')
          .strokeWidth(2);
        Text(this.recording ? '停止' : '录像')
          .fontSize(10)
          .fontColor('#FFFFFF');
      }
      .onClick((): void => {
        void this.toggleVideo();
      });

      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(78)
          .height(78)
          .fill('#FFFFFF');
        Circle()
          .width(64)
          .height(64)
          .fill(this.shooting ? '#7EA6F5' : '#2563EB');
        Text(this.shooting ? '…' : '')
          .fontSize(18)
          .fontColor('#FFFFFF');
      }
      .onClick((): void => {
        if (this.movieMode) {
          void this.toggleVideo();
        } else {
          void this.capture();
        }
      });

      Column({ space: 4 }) {
        Circle()
          .width(44)
          .height(44)
          .fill('#661A1E27')
          .stroke('#FFFFFF')
          .strokeWidth(1);
        Text('对焦')
          .fontSize(10)
          .fontColor('#FFFFFF');
      }
      .onClick((): void => {
        const area = ((3 & 0xFF) << 24) | ((2 & 0xFF) << 16) | (0x0606);
        void FujifilmControlService.lockS1(area).then((ok: boolean): void => {
          if (!ok) this.toast('对焦指令未响应');
        });
      });
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 10 });
  }

  // ---- 遥控形态 -----------------------------------------------------------

  @Builder
  private remoteScreen() {
    Column() {
      this.topBar();
      this.identityRow();
      Scroll() {
        Column({ space: 10 }) {
          this.quickChips();
          this.remoteFinder();
          if (this.degradedReason.length > 0) {
            this.warningBanner(this.degradedReason, '#F59E0B');
          }
          if (this.warning.length > 0) {
            this.warningBanner(`相机状态：${this.warning}`, '#E5484D');
          }
          this.paramGrid();
          this.allParamsEntry();
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 8 });
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off);
      this.remoteBottomBar();
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0D1017');
  }

  @Builder
  private topBar() {
    Row({ space: 8 }) {
      Text('‹')
        .fontSize(28)
        .fontColor('#FFFFFF')
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .onClick((): void => {
          this.exitPage();
        });
      Text('相机控制')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF');
      Blank();
      Row() {
        Text('预览')
          .fontSize(12)
          .fontColor('#8A97AB')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick((): void => {
            this.toggleMode(true);
          });
        Text('遥控')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor('#2563EB')
          .borderRadius(12);
      }
      .backgroundColor('#232833')
      .borderRadius(15)
      .padding(3);
    }
    .width('100%')
    .height(58)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  private identityRow() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(this.model.length > 0 ? this.model : 'FUJIFILM')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1);
        Text(this.serial.length > 0 ? `S/N ${this.serial}` : 'Wi-Fi PTP-IP · 55740')
          .fontSize(10)
          .fontColor('#8A97AB')
          .maxLines(1);
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
      Text(this.props.length > 0 ? `参数 ${Math.min(this.props.length, 53)} 项` : '参数不可用')
        .fontSize(10)
        .fontColor(this.props.length > 0 ? '#34D399' : '#F59E0B')
        .backgroundColor('#1A1E27')
        .borderRadius(10)
        .padding({ left: 8, right: 8, top: 4, bottom: 4 });
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 2, bottom: 8 });
  }

  @Builder
  private quickChips() {
    Scroll() {
      Row({ space: 8 }) {
        this.quickChip(0xD001);
        this.quickChip(0x5004);
        this.quickChip(0xD241);
        this.quickChip(0x500C);
        this.quickChip(0x5012);
        this.quickChip(0x500A);
      }
      .padding({ left: 2, right: 2 });
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%');
  }

  @Builder
  private quickChip(code: number) {
    Row({ space: 5 }) {
      Text(this.catalogLabel(code))
        .fontSize(10)
        .fontColor('#8A97AB');
      Text(FujifilmControlService.valueText(code))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(FujifilmControlService.propOf(code) !== null ? '#FFFFFF' : '#5A6373')
        .maxLines(1);
    }
    .backgroundColor('#1A1E27')
    .borderRadius(12)
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .onClick((): void => {
      const spec = FujifilmParamCatalog.find(code);
      if (spec !== null) this.openPanel(spec);
    });
  }

  @Builder
  private remoteFinder() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.framePm !== undefined) {
        Image(this.framePm)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .opacity(0.55)
          .onClick((event: ClickEvent): void => {
            this.tapFocusRemote(event);
          });
      } else {
        Column({ space: 6 }) {
          Text('遥控模式')
            .fontSize(14)
            .fontColor('#FFFFFF');
          Text('取景已暂停，切到「预览」查看实时画面')
            .fontSize(11)
            .fontColor('#8A97AB');
        }
        .justifyContent(FlexAlign.Center);
      }
      Row({ space: 6 }) {
        Circle()
          .width(6)
          .height(6)
          .fill('#F59E0B');
        Text('遥控模式 · 不推流')
          .fontSize(10)
          .fontColor('#FFFFFF');
      }
      .backgroundColor('#99000000')
      .borderRadius(10)
      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      .position({ x: 8, y: 8 });
    }
    .width('100%')
    .height(178)
    .backgroundColor('#000000')
    .borderRadius(16)
    .clip(true);
  }

  private tapFocusRemote(event: ClickEvent): void {
    this.afFocused = false;
    const cellX = 6;
    const cellY = 6;
    const afArea = ((3 & 0xFF) << 24) | ((2 & 0xFF) << 16) |
      ((cellX & 0xFF) << 8) | (cellY & 0xFF);
    void FujifilmControlService.lockS1(afArea).then((ok: boolean): void => {
      if (!ok) this.toast('对焦指令未响应');
    });
    if (this.focusTimer >= 0) clearTimeout(this.focusTimer);
    this.focusTimer = setTimeout((): void => {
      this.focusTimer = -1;
      void FujifilmControlService.unlockS1();
    }, 700);
  }

  @Builder
  private warningBanner(text: string, color: string) {
    Row({ space: 6 }) {
      Text('!')
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor('#0D1017')
        .width(16)
        .height(16)
        .textAlign(TextAlign.Center)
        .backgroundColor(color)
        .borderRadius(8);
      Text(text)
        .fontSize(11)
        .fontColor('#FFFFFF')
        .layoutWeight(1)
        .maxLines(2);
    }
    .width('100%')
    .backgroundColor('#1A1E27')
    .borderRadius(12)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 });
  }

  @Builder
  private paramGrid() {
    Column({ space: 8 }) {
      Row() {
        Text('拍摄参数')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF');
        Blank();
        Text('刷新')
          .fontSize(11)
          .fontColor('#8A97AB')
          .onClick((): void => {
            void this.refreshProps(true);
          });
      }
      .width('100%');
      Grid() {
        ForEach(FujifilmParamCatalog.all().filter((spec: FujifilmParamSpec): boolean => spec.primary),
          (spec: FujifilmParamSpec) => {
            GridItem() {
              this.paramTile(spec);
            }
          }, (spec: FujifilmParamSpec): string => `${spec.code}`);
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(8)
      .rowsGap(8)
      .width('100%')
      .height(430);
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#1A1E27')
    .borderRadius(18)
    .attributeModifier(VividMaterial.cardNight);
  }

  @Builder
  private paramTile(spec: FujifilmParamSpec) {
    Column({ space: 3 }) {
      Row({ space: 4 }) {
        Text(spec.label)
          .fontSize(10)
          .fontColor('#8A97AB')
          .layoutWeight(1)
          .maxLines(1);
        if (FujifilmControlService.propOf(spec.code) === null) {
          Text('不可用')
            .fontSize(9)
            .fontColor('#5A6373');
        }
      }
      .width('100%');
      Text(this.paramValue(spec))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(FujifilmControlService.propOf(spec.code) !== null ? '#FFFFFF' : '#5A6373')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
    }
    .width('100%')
    .height(52)
    .padding({ left: 9, right: 9, top: 6, bottom: 6 })
    .backgroundColor('#12161F')
    .borderRadius(12)
    .border({ width: 1, color: '#2A2F3B' })
    .opacity(FujifilmControlService.propOf(spec.code) !== null ? 1 : 0.55)
    .onClick((): void => {
      this.openPanel(spec);
    });
  }

  @Builder
  private allParamsEntry() {
    Row({ space: 6 }) {
      Text('全部参数')
        .fontSize(12)
        .fontColor('#FFFFFF');
      Text(`${FujifilmParamCatalog.all().length} 项`)
        .fontSize(10)
        .fontColor('#8A97AB');
      Blank();
      Text('查看')
        .fontSize(11)
        .fontColor('#2563EB');
    }
    .width('100%')
    .backgroundColor('#1A1E27')
    .borderRadius(14)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .onClick((): void => {
      this.showAll = true;
    });
  }

  @Builder
  private remoteBottomBar() {
    Row({ space: 14 }) {
      this.zoomButton('−', 1);
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(72)
          .height(72)
          .fill('#FFFFFF');
        Circle()
          .width(58)
          .height(58)
          .fill(this.movieMode || this.recording
            ? (this.recording ? '#F08A8E' : '#E5484D')
            : (this.shooting ? '#7EA6F5' : '#2563EB'));
        Text(this.recording ? '■' : (this.movieMode ? '●' : ''))
          .fontSize(20)
          .fontColor('#FFFFFF');
      }
      .onClick((): void => {
        if (this.movieMode) {
          void this.toggleVideo();
        } else {
          void this.capture();
        }
      });
      this.zoomButton('+', 0);
      Column({ space: 2 }) {
        Text(this.movieMode ? '录像' : '拍照')
          .fontSize(10)
          .fontColor('#8A97AB');
        Text('切换')
          .fontSize(11)
          .fontColor('#FFFFFF');
      }
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor('#1A1E27')
      .borderRadius(10)
      .onClick((): void => {
        this.movieMode = !this.movieMode;
      });
    }
    .width('100%')
    .height(92)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 12, right: 12, bottom: 8 });
  }

  @Builder
  private zoomButton(label: string, direction: number) {
    Stack({ alignContent: Alignment.Center }) {
      Circle()
        .width(48)
        .height(48)
        .fill('#1A1E27')
        .stroke('#2A2F3B')
        .strokeWidth(1);
      Text(label)
        .fontSize(24)
        .fontColor('#FFFFFF');
    }
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        void this.zoomStart(direction);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        void this.zoomStop();
      }
    });
  }

  // ---- 参数底部面板 -------------------------------------------------------

  @Builder
  private paramSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick((): void => {
          this.closePanel();
        });
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(this.selectedLabel())
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF');
            Text(this.selectedMeta())
              .fontSize(10)
              .fontColor('#8A97AB');
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);
          Text('关闭')
            .fontSize(12)
            .fontColor('#8A97AB')
            .onClick((): void => {
              this.closePanel();
            });
        }
        .width('100%');

        if (this.selectedIsStep()) {
          Row({ space: 14 }) {
            Button('−')
              .width(54)
              .height(46)
              .fontSize(22)
              .backgroundColor('#232833')
              .fontColor('#FFFFFF')
              .onClick((): void => {
                void this.applyStep(0);
              });
            Text(FujifilmControlService.valueText(this.selectedCode))
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .layoutWeight(1)
              .textAlign(TextAlign.Center);
            Button('+')
              .width(54)
              .height(46)
              .fontSize(22)
              .backgroundColor('#232833')
              .fontColor('#FFFFFF')
              .onClick((): void => {
                void this.applyStep(1);
              });
          }
          .width('100%');
        }

        if (this.panelOptionsCount() > 0) {
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.panelOptions(), (option: FujifilmParamOption) => {
                this.optionRow(option);
              }, (option: FujifilmParamOption): string => `${this.selectedCode}-${option.value}`);
            }
            .width('100%');
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off);
        } else {
          Text('相机未上报该参数的候选值，只有当前值：' +
            FujifilmControlService.valueText(this.selectedCode))
            .fontSize(12)
            .fontColor('#8A97AB')
            .width('100%')
            .padding({ top: 10, bottom: 10 });
        }
      }
      .width('100%')
      .height('62%')
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor('#12161F')
      .borderRadius({ topLeft: 20, topRight: 20 });
    }
    .width('100%')
    .height('100%')
    .zIndex(20);
  }

  @Builder
  private optionRow(option: FujifilmParamOption) {
    Row() {
      Text(option.label)
        .fontSize(14)
        .fontColor(this.isSelectedOption(option) ? '#2563EB' : '#FFFFFF')
        .fontWeight(this.isSelectedOption(option) ? FontWeight.Bold : FontWeight.Normal)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      if (this.isSelectedOption(option)) {
        Text('✓')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#2563EB');
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .backgroundColor(this.isSelectedOption(option) ? '#1F2A44' : '#1A1E27')
    .borderRadius(12)
    .onClick((): void => {
      void this.applyOption(option);
    });
  }

  private isSelectedOption(option: FujifilmParamOption): boolean {
    return this.selectedValue === option.value;
  }

  // ---- 全部参数 -----------------------------------------------------------

  @Builder
  private allParamsSheet() {
    Column({ space: 8 }) {
      Row() {
        Text('全部参数')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF');
        Text(` ${Math.min(this.props.length, 53)}/${FujifilmParamCatalog.all().length}`)
          .fontSize(10)
          .fontColor('#8A97AB');
        Blank();
        Text('关闭')
          .fontSize(12)
          .fontColor('#8A97AB')
          .onClick((): void => {
            this.showAll = false;
          });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 6 });
      Scroll() {
        Column({ space: 10 }) {
          ForEach(FUJI_GROUP_ORDER, (group: string) => {
            Column({ space: 4 }) {
              Text(group)
                .fontSize(11)
                .fontColor('#8A97AB')
                .width('100%')
                .padding({ top: 4 });
              ForEach(this.specsOfGroup(group), (spec: FujifilmParamSpec) => {
                this.allParamRow(spec);
              }, (spec: FujifilmParamSpec): string => `${spec.code}`);
            }
            .width('100%');
          }, (group: string): string => group);
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 });
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off);
    }
    .width('100%')
    .height('86%')
    .backgroundColor('#12161F')
    .borderRadius({ topLeft: 20, topRight: 20 })
    .zIndex(30);
  }

  private specsOfGroup(group: string): FujifilmParamSpec[] {
    return FujifilmParamCatalog.all().filter((spec: FujifilmParamSpec): boolean => spec.group === group);
  }

  @Builder
  private allParamRow(spec: FujifilmParamSpec) {
    Row({ space: 8 }) {
      Text(spec.label)
        .fontSize(13)
        .fontColor(FujifilmControlService.propOf(spec.code) !== null ? '#FFFFFF' : '#5A6373')
        .layoutWeight(1)
        .maxLines(1);
      Text(`0x${spec.code.toString(16)}`)
        .fontSize(9)
        .fontColor('#5A6373');
      Text(this.paramValue(spec))
        .fontSize(12)
        .fontColor(FujifilmControlService.propOf(spec.code) !== null ? '#C7D0DE' : '#5A6373')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .backgroundColor('#1A1E27')
    .borderRadius(10)
    .opacity(FujifilmControlService.propOf(spec.code) !== null ? 1 : 0.6)
    .onClick((): void => {
      this.showAll = false;
      this.openPanel(spec);
    });
  }
}

