import { EditSession } from '../edit/models/EditSession';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { MaskComponent, MaskComponentType, RangeMaskData } from '../edit/models/Mask';
import { RangeMaskService } from '../edit/engine/RangeMaskService';
import { RangeMaskProxy } from '../edit/engine/RangeMaskCore';
import { VividNative } from './VividNativeTheme';

/**
 * 亮度范围的「选择明亮度」卡片。
 *
 * 参照 Camera Raw：滑槽是一整条 黑→白 的亮度带，中间的白点是当前选中的
 * 中心亮度，两侧的竖条把区间宽度框住；拖动白点选中心，拖两边锁范围，
 * 点应用才写回蒙版并重算。
 */
@Component
export struct MaskRangePicker {
  @Consume('editSession') editSession: EditSession;
  @StorageLink('maskRangePickerOpen') private open: boolean = false;
  @StorageProp('vividNightMode') private night: boolean = false;
  /** 中心亮度 0..100。 */
  @State private center: number = 50;
  /** 区间宽度 0..100。 */
  @State private span: number = 100;
  @StorageLink('maskRangeLuma') @Watch('onAnchorLuma') private anchorLuma: number = -1;
  /** 颜色范围模式：滑杆变色相，不再是亮度。 */
  @StorageProp('maskRangeColorMode') private colorMode: boolean = false;
  @StorageLink('maskRangeColorHue') @Watch('onAnchorHue') private anchorHue: number = -1;
  @StorageProp('maskRangeColorAt') private sampleColor: string = '#FFFFFF';
  @State private hint: string = '';
  @State private busy: boolean = false;
  private stripWidth: number = 240;
  private dragBase: number = 50;
  private spanBase: number = 100;
  private edgeBase: number = 0;
  private dragMode: string = 'center';
  private proxy: RangeMaskProxy | null = null;
  private timer: number = -1;
  private targetId: string = '';

  aboutToAppear(): void {
    this.syncFromModel();
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private rangePart(): MaskComponent | null {
    const part = this.editSession.activeMaskComponent;
    if (part !== null && part.type === MaskComponentType.RANGE && part.rangeData) return part;
    const layer = this.editSession.activeMaskLayer;
    const found = (layer?.components ?? []).find((item: MaskComponent): boolean =>
      item.type === MaskComponentType.RANGE && item.rangeData !== null);
    return found ?? null;
  }

  private syncFromModel(): void {
    const part = this.rangePart();
    if (part === null || part.rangeData === null) {
      this.open = false;
      return;
    }
    this.targetId = part.id;
    this.center = Math.round((part.rangeData.min + part.rangeData.max) * 50);
    this.span = Math.max(2, Math.round((part.rangeData.max - part.rangeData.min) * 100));
    this.hint = '';
  }

  /** 图上锚点取到的颜色：把它的色相搬到中心。 */
  private onAnchorHue(): void {
    if (!this.colorMode || this.anchorHue < 0) return;
    this.center = this.anchorHue;
    this.scheduleApply();
  }

  /** 当前中心值对应的色相颜色（用来染圆点）。 */
  private hueColor(huePct: number, sat: number = 0.85, val: number = 0.95): number[] {
    const h = ((huePct / 100 * 360) % 360 + 360) % 360;
    const c = val * sat;
    const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
    const m = val - c;
    let r = 0;
    let g = 0;
    let b = 0;
    if (h < 60) { r = c; g = x; } else if (h < 120) { r = x; g = c; }
    else if (h < 180) { g = c; b = x; } else if (h < 240) { g = x; b = c; }
    else if (h < 300) { r = x; b = c; } else { r = c; b = x; }
    return [Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255)];
  }

  /** 锚点取样到的颜色的饱和度与明度（0..1）。 */
  private sampleSV(): number[] {
    const parts = this.sampleColor.match(/\d+/g);
    if (parts === null || parts.length < 3) return [0.55, 0.85];
    const r = Number(parts[0]) / 255;
    const g = Number(parts[1]) / 255;
    const b = Number(parts[2]) / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const sat = max <= 0 ? 0 : (max - min) / max;
    return [Math.max(0.2, Math.min(1, sat + 0.15)), Math.max(0.25, max)];
  }

  private centerFill(): string {
    if (!this.colorMode) return '#FFFFFF';
    const rgb = this.hueColor(this.center);
    return `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
  }

  /** 图上锚点取到的亮度：直接搬到白点中心。 */
  private onAnchorLuma(): void {
    if (this.anchorLuma < 0) return;
    this.center = this.anchorLuma;
    this.scheduleApply();
  }

  private minPct(): number {
    return Math.max(0, Math.min(100, this.center - this.span / 2));
  }

  private maxPct(): number {
    return Math.max(0, Math.min(100, this.center + this.span / 2));
  }

  private applyWidthFrom(edgeCenter: number): void {
    // 拖动某一侧把手：宽度按「把手到中心距离 × 2」算，最小 2。
    const half = Math.abs(edgeCenter - this.center);
    this.span = Math.max(2, Math.min(100, half * 2));
  }

  /** 拖动过程中节流重算，松手再补一次。 */
  private scheduleApply(): void {
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.apply(false, false);
    }, 120);
  }

  private async ensureProxy(): Promise<RangeMaskProxy | null> {
    if (this.proxy !== null) return this.proxy;
    const session = this.editSession;
    const token = RangeMaskService.tokenFor(session);
    let proxy: RangeMaskProxy | null = RangeMaskService.cachedProxy(token);
    if (proxy === null) {
      const source = session.sourcePixelMap;
      if (!source) return null;
      proxy = await RangeMaskService.proxyFor(source, token);
    }
    this.proxy = proxy;
    return proxy;
  }

  private async apply(close: boolean, commit: boolean = true): Promise<void> {
    const part = this.rangePart();
    if (part === null || part.rangeData === null) {
      this.hint = '没有找到亮度范围蒙版';
      if (close) this.open = false;
      return;
    }
    if (this.busy) {
      if (close) this.open = false;
      return;
    }
    this.busy = true;
    try {
      const proxy = await this.ensureProxy();
      if (proxy === null) {
        this.hint = '无法读取源图';
        return;
      }
      const data: RangeMaskData = part.rangeData;
      data.min = this.minPct() / 100;
      data.max = Math.max(data.min + 0.02, this.maxPct() / 100);
      if (this.colorMode) {
        // 颜色范围：色相跟滑杆，饱和度/明度沿用锚点取样到的真实颜色。
        // 否则目标色太饱和，照片里偏灰的像素距离超过容差，筛选不出任何东西。
        const sv = this.sampleSV();
        const rgb = this.hueColor(this.center, sv[0], sv[1]);
        data.colorEnabled = true;
        data.colorR = rgb[0] / 255;
        data.colorG = rgb[1] / 255;
        data.colorB = rgb[2] / 255;
      }
      // commit=false（拖动中）只更新蒙版，不重建预览，避免黑帧。
      if (RangeMaskService.recompute(this.editSession, part.id, data, proxy, commit)) {
        this.editSession.notifyMaskRevision();
        if (commit) ImageProcessor.process(this.editSession);
        this.hint = this.colorMode
          ? `色相 ${Math.round(this.center / 100 * 360)}° 容差 ${Math.round(this.span / 2)}`
          : `亮度 ${Math.round(this.minPct())} – ${Math.round(this.maxPct())}`;
      } else {
        this.hint = '范围重算失败';
      }
    } catch (error) {
      this.hint = '范围重算出错';
    } finally {
      this.busy = false;
      if (close) this.open = false;
    }
  }

  private trackColor(): string {
    return this.night ? 'rgba(255,255,255,0.10)' : 'rgba(238,241,246,0.92)';
  }

  private textColor(): ResourceColor {
    return this.night ? '#F4F7FC' : VividNative.textPrimary as ResourceColor;
  }

  @Builder
  Handle(isLeft: boolean) {
    Row()
      .width(12)
      .height(34)
      .borderRadius(4)
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: 'rgba(20,30,50,0.16)' })
      .position({
        x: Math.max(0, Math.min(this.stripWidth - 12,
          (isLeft ? this.minPct() : this.maxPct()) / 100 * this.stripWidth - 6)),
        y: 1,
      })
      .hitTestBehavior(HitTestMode.None);
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text(this.colorMode ? '选择颜色' : '选择明亮度')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textColor());
        Blank();
        Button(this.busy ? '计算中…' : '应用')
          .fontSize(13)
          .height(28)
          .padding({ left: 14, right: 14 })
          .type(ButtonType.Capsule)
          .backgroundColor('#316CF4')
          .fontColor(Color.White)
          .onClick(() => { this.apply(true); });
      }
      .width('100%');

      // 亮度带 + 白点（中心）+ 两侧把手（范围宽度）。
      Stack({ alignContent: Alignment.TopStart }) {
        Row()
          .width('100%')
          .height(36)
          .borderRadius(6)
          .linearGradient(this.colorMode ? {
            angle: 90,
            colors: [['#FF0000', 0.0], ['#FFFF00', 0.17], ['#00FF00', 0.33],
              ['#00FFFF', 0.5], ['#0000FF', 0.67], ['#FF00FF', 0.83], ['#FF0000', 1.0]],
          } : {
            angle: 90,
            colors: [[Color.Black, 0.0], [Color.White, 1.0]],
          });

        Row()
          .width(Math.max(2, (this.maxPct() - this.minPct()) / 100 * this.stripWidth))
          .height(36)
          .border({ width: 2, color: 'rgba(255,255,255,0.9)' })
          .borderRadius(4)
          .position({ x: this.minPct() / 100 * this.stripWidth, y: 0 })
          .hitTestBehavior(HitTestMode.None);

        Row()
          .width(20)
          .height(20)
          .borderRadius(10)
          .backgroundColor(this.centerFill())
          .border({ width: 2, color: '#316CF4' })
          .position({ x: Math.max(0, Math.min(this.stripWidth - 20, this.center / 100 * this.stripWidth - 10)), y: 8 });

        this.Handle(true);
        this.Handle(false);
      }
      .width('100%')
      .height(36)
      .onAreaChange((_old: Area, now: Area) => {
        const w = Number(now.width);
        if (w > 1) this.stripWidth = w;
      })
      .gesture(PanGesture({ direction: PanDirection.Horizontal })
        .onActionStart((event: GestureEvent) => {
          // 落在左右把手附近就拖边界，否则拖中心；保证两根白杆都能拖动。
          const w = this.stripWidth > 1 ? this.stripWidth : 240;
          const x = event.fingerList.length > 0 ? event.fingerList[0].localX / w * 100 : this.center;
          const dLeft = Math.abs(x - this.minPct());
          const dRight = Math.abs(x - this.maxPct());
          if (dLeft <= 8 && dLeft <= dRight) {
            this.dragMode = 'left';
          } else if (dRight <= 8) {
            this.dragMode = 'right';
          } else {
            this.dragMode = 'center';
          }
          this.dragBase = this.center;
          this.spanBase = this.span;
          this.edgeBase = this.dragMode === 'left' ? this.minPct() : this.maxPct();
        })
        .onActionUpdate((event: GestureEvent) => {
          const w = this.stripWidth > 1 ? this.stripWidth : 240;
          const delta = (event.offsetX / w) * 100;
          if (this.dragMode === 'center') {
            this.center = Math.max(0, Math.min(100, this.dragBase + delta));
          } else {
            const edge = Math.max(0, Math.min(100, this.edgeBase + delta));
            const lower = this.dragMode === 'left' ? edge : this.minPct();
            const upper = this.dragMode === 'right' ? edge : this.maxPct();
            const lo = Math.min(lower, upper);
            const hi = Math.max(lower, upper);
            this.span = Math.max(2, hi - lo);
            this.center = (lo + hi) / 2;
          }
          this.scheduleApply();
        })
        .onActionEnd(() => { this.apply(false, true); }));

      Row() {
        Text(this.hint.length > 0 ? this.hint : `亮度 ${Math.round(this.minPct())} – ${Math.round(this.maxPct())}`)
          .fontSize(11)
          .fontColor(VividNative.textSecondary);
        Blank();
        Text(`${Math.round(this.span)} / 100`)
          .fontSize(11)
          .fontColor(VividNative.textSecondary);
      }
      .width('100%');
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 16 })
    .backgroundColor(this.night ? 'rgba(24,26,32,0.96)' : 'rgba(252,253,255,0.97)')
    .borderRadius({ topLeft: 18, topRight: 18 })
    .border({ width: 1, color: this.night ? 'rgba(255,255,255,0.10)' : 'rgba(20,30,50,0.08)' })
    .shadow({ radius: 18, color: 'rgba(20,30,50,0.18)', offsetY: -4 });
  }
}

/**
 * 图上的虚线双环锚点：拖动它到任意位置取样亮度，取样值直接驱动卡片白点。
 * 与卡片共用 AppStorage['maskRangeLuma']。
 */
@Component
export struct MaskRangeAnchor {
  @Consume('editSession') editSession: EditSession;
  @StorageLink('maskRangeLuma') private luma: number = -1;
  @StorageProp('maskRangeColorMode') private colorMode: boolean = false;
  @State private sampleColor: string = '#FFFFFF';
  /** 换蒙版时递增：锚点回到画面中心并清掉上一次的取样值。 */
  @StorageProp('maskRangeReset') @Watch('onReset') private resetTag: number = 0;

  private onReset(): void {
    this.px = 50;
    this.py = 50;
  }
  @State private px: number = 50;
  @State private py: number = 50;
  @State private dragging: boolean = false;
  private proxy: RangeMaskProxy | null = null;
  private boxW: number = 300;
  private boxH: number = 300;
  private timer: number = -1;

  private async ensureProxy(): Promise<RangeMaskProxy | null> {
    if (this.proxy !== null) return this.proxy;
    const session = this.editSession;
    const token = RangeMaskService.tokenFor(session);
    let proxy: RangeMaskProxy | null = RangeMaskService.cachedProxy(token);
    if (proxy === null) {
      const source = session.sourcePixelMap;
      if (!source) return null;
      proxy = await RangeMaskService.proxyFor(source, token);
    }
    this.proxy = proxy;
    return proxy;
  }

  private scheduleSample(): void {
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.sample();
    }, 60);
  }

  private async sample(): Promise<void> {
    const proxy = await this.ensureProxy();
    if (proxy === null) return;
    const x = Math.max(0, Math.min(proxy.width - 1, Math.round(this.px / 100 * (proxy.width - 1))));
    const y = Math.max(0, Math.min(proxy.height - 1, Math.round(this.py / 100 * (proxy.height - 1))));
    const offset = (y * proxy.width + x) * 3;
    const value = 0.2126 * proxy.rgb[offset] + 0.7152 * proxy.rgb[offset + 1] +
      0.0722 * proxy.rgb[offset + 2];
    this.luma = Math.round(value / 255 * 100);
    if (this.colorMode) {
      const r = proxy.rgb[offset];
      const g = proxy.rgb[offset + 1];
      const b = proxy.rgb[offset + 2];
      this.sampleColor = `rgb(${r},${g},${b})`;
      AppStorage.setOrCreate('maskRangeColorAt', this.sampleColor);
      AppStorage.setOrCreate('maskRangeColorHue', this.hueOf(r, g, b));
    }
  }

  /** RGB -> 色相 (0..100)。 */
  private hueOf(r: number, g: number, b: number): number {
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const delta = max - min;
    if (delta === 0) return 0;
    let h = 0;
    if (max === r) h = ((g - b) / delta) % 6;
    else if (max === g) h = (b - r) / delta + 2;
    else h = (r - g) / delta + 4;
    h = h * 60;
    if (h < 0) h += 360;
    return Math.round(h / 360 * 100);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.Center }) {
        // 外圈：加粗虚线圆环（用 Circle 描边，避免方框感）
        Circle()
          .width(44)
          .height(44)
          .fill(Color.Transparent)
          // 颜色范围时外圈直接用取样到的颜色，实时变化。
          .stroke(this.colorMode ? this.sampleColor : Color.White)
          .strokeWidth(2.6)
          .strokeDashArray([6, 5]);
        // 内圈：细虚线圆环
        Circle()
          .width(26)
          .height(26)
          .fill(Color.Transparent)
          .stroke('rgba(255,255,255,0.85)')
          .strokeWidth(1.2)
          .strokeDashArray([4, 4]);
        // 中心取样点
        Circle()
          .width(7)
          .height(7)
          .fill(this.colorMode ? this.sampleColor : Color.White)
          .stroke('rgba(20,30,50,0.6)')
          .strokeWidth(1.2);
      }
      .width(46)
      .height(46)
      .position({
        x: Math.max(0, Math.min(this.boxW - 46, this.px / 100 * this.boxW - 23)),
        y: Math.max(0, Math.min(this.boxH - 46, this.py / 100 * this.boxH - 23)),
      })
      .hitTestBehavior(HitTestMode.None);
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .onAreaChange((_old: Area, now: Area) => {
      const w = Number(now.width);
      const h = Number(now.height);
      if (w > 1) this.boxW = w;
      if (h > 1) this.boxH = h;
    })
    .gesture(PanGesture()
      .onActionStart((event: GestureEvent) => {
        this.dragging = true;
        this.px = Math.max(0, Math.min(100, event.fingerList.length > 0
          ? event.fingerList[0].localX / this.boxW * 100 : this.px));
        this.py = Math.max(0, Math.min(100, event.fingerList.length > 0
          ? event.fingerList[0].localY / this.boxH * 100 : this.py));
        this.scheduleSample();
      })
      .onActionUpdate((event: GestureEvent) => {
        if (event.fingerList.length === 0) return;
        this.px = Math.max(0, Math.min(100, event.fingerList[0].localX / this.boxW * 100));
        this.py = Math.max(0, Math.min(100, event.fingerList[0].localY / this.boxH * 100));
        this.scheduleSample();
      })
      .onActionEnd(() => {
        this.dragging = false;
        this.sample();
      }));
  }
}
