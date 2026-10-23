import { EditSession } from '../edit/models/EditSession';
import { ColorAdjustments } from '../edit/models/Adjustment';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { VividNative } from './VividNativeTheme';
import { histogramPlot, histogramHeight, histogramToneIndex, histogramToneKey,
  histogramDragValue } from '../edit/engine/HistogramPresentation';

@Component
export struct HistogramOverlay {
  @Consume('editSession') editSession: EditSession;
  @Prop offsetX: number = 14;
  @Prop offsetY: number = 82;
  @Prop allowDrag: boolean = true;
  @Prop interactiveTone: boolean = true;
  @Prop chartHeight: number = 80;
  @StorageProp('vividNightMode') @Watch('onHistogramRevision') private night: boolean = false;
  @StorageProp('histogramVersion') @Watch('onHistogramRevision') histogramRevision: number = 0;
  @State private selectedRegion: number = -1;
  @State private selectedValue: number = 0;
  onOffsetChange: (x: number, y: number) => void = () => {};
  private dragX: number = 0;
  private dragY: number = 0;
  private dragBaseX: number = 0;
  private dragBaseY: number = 0;
  private dragBaseValue: number = 0;
  private dragRegion: number = -1;
  private dragChanged: boolean = false;
  private dragTarget: ColorAdjustments | null = null;
  private timer: number = -1;
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private canvasReady: boolean = false;

  build() {
    Column() {
      Canvas(this.canvasCtx).width('100%').height(Math.max(30, this.chartHeight - 20))
        .id('histogram-tone-plot').onReady(() => { this.canvasReady = true; this.renderHistogram(); })
        .onAreaChange(() => { this.renderHistogram(); })
        .onMouse((event: MouseEvent) => {
          if (!this.interactiveTone || this.dragRegion >= 0) return;
          this.selectRegion(histogramToneIndex(event.x, this.canvasCtx.width));
        })
        .onHover((hovered: boolean) => { if (!hovered && this.dragRegion < 0) this.selectRegion(-1); })
        .onTouch((event: TouchEvent) => { this.handleTouch(event); });
      Text(this.regionText()).width('100%').height(20).textAlign(TextAlign.Center).fontSize(10)
        .fontColor(VividNative.textPrimary).id('histogram-tone-readout');
    }.width('100%').height(this.chartHeight);
  }

  private regionText(): string {
    if (this.selectedRegion < 0) return this.interactiveTone ? '左右拖动分区调整明暗' : 'RGB 直方图';
    const label = ['黑色', '阴影', '曝光', '高光', '白色'][this.selectedRegion];
    const value = this.selectedValue * (this.selectedRegion === 2 ? 2 : 100);
    return label + '  ' + (value > 0 ? '+' : '') + value.toFixed(this.selectedRegion === 2 ? 2 : 0) +
      (this.selectedRegion === 2 ? ' EV' : '');
  }
  private selectRegion(index: number): void {
    if (this.selectedRegion === index) return;
    this.selectedRegion = index;
    this.selectedValue = this.editSession.activeLayer?.adjustments.getValue(histogramToneKey(index)) ?? 0;
    this.renderHistogram();
  }
  private handleTouch(event: TouchEvent): void {
    const touch = event.touches[0] ?? event.changedTouches[0];
    if (event.type === TouchType.Down && touch) {
      this.dragX = touch.x; this.dragY = touch.y;
      this.dragBaseX = this.offsetX; this.dragBaseY = this.offsetY;
      if (!this.interactiveTone) return;
      this.dragRegion = histogramToneIndex(touch.x, this.canvasCtx.width);
      this.selectRegion(this.dragRegion);
      this.dragTarget = this.editSession.activeLayer?.adjustments ?? null;
      this.dragBaseValue = this.dragTarget?.getValue(histogramToneKey(this.dragRegion)) ?? 0;
      this.dragChanged = false;
      console.info('VIVID_HIST event=begin region=' + this.dragRegion + ' x=' + this.dragX +
        ' width=' + this.canvasCtx.width + ' base=' + this.dragBaseValue);
    } else if (event.type === TouchType.Move && touch) {
      if (!this.interactiveTone) {
        if (this.allowDrag) this.onOffsetChange(Math.max(0, this.dragBaseX + touch.x - this.dragX),
          Math.max(0, this.dragBaseY + touch.y - this.dragY));
        return;
      }
      if (this.dragRegion < 0 || !this.dragTarget || this.dragTarget !== this.editSession.activeLayer?.adjustments) return;
      if (!this.dragChanged && Math.abs(touch.x - this.dragX) < 2) return;
      if (!this.dragChanged) { this.editSession.pushUndo(); this.dragChanged = true; }
      this.selectedValue = histogramDragValue(this.dragBaseValue, touch.x - this.dragX, this.canvasCtx.width);
      this.dragTarget.setValue(histogramToneKey(this.dragRegion), this.selectedValue);
      this.editSession.requestProcessing();
      if (this.timer === -1) this.timer = setTimeout(() => { this.timer = -1; ImageProcessor.process(this.editSession); }, 33);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (event.type === TouchType.Cancel && this.dragChanged && this.dragTarget === this.editSession.activeLayer?.adjustments) {
        this.dragTarget?.setValue(histogramToneKey(this.dragRegion), this.dragBaseValue);
        this.selectedValue = this.dragBaseValue;
      }
      this.finishDrag();
    }
  }
  private finishDrag(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (this.dragChanged && this.dragTarget === this.editSession.activeLayer?.adjustments) {
      console.info('VIVID_HIST event=end region=' + this.dragRegion + ' value=' + this.selectedValue);
      AppStorage.setOrCreate('toneControlRevision', (AppStorage.get<number>('toneControlRevision') ?? 0) + 1);
      ImageProcessor.process(this.editSession);
    }
    this.dragRegion = -1; this.dragTarget = null; this.dragChanged = false;
    this.renderHistogram();
  }
  aboutToDisappear(): void { this.finishDrag(); this.canvasReady = false; }
  private onHistogramRevision(): void { if (this.canvasReady) this.renderHistogram(); }
  private renderHistogram(): void {
    const ctx = this.canvasCtx, width = ctx.width, height = ctx.height;
    if (!this.canvasReady || width <= 0 || height <= 0) return;
    ctx.clearRect(0, 0, width, height);
    const h = histogramPlot(this.editSession.histogramR, this.editSession.histogramG,
      this.editSession.histogramB, this.editSession.histogramL);
    if (this.selectedRegion >= 0) {
      ctx.fillStyle = this.night ? 'rgba(255,255,255,0.08)' : 'rgba(30,70,100,0.08)';
      ctx.fillRect(width * this.selectedRegion / 5, 0, width / 5, height);
    }
    ctx.strokeStyle = this.night ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.07)'; ctx.lineWidth = 0.5;
    for (let i = 1; i < 5; i++) {
      ctx.beginPath(); ctx.moveTo(width * i / 5, 0); ctx.lineTo(width * i / 5, height); ctx.stroke();
    }
    this.drawCurve(h.luminance, h.peak, this.night ? 'rgba(170,170,170,0.20)' : 'rgba(80,80,80,0.14)', true);
    if (h.monochrome) this.drawCurve(h.green, h.peak, this.night ? '#DEDEDE' : '#555555', false);
    else {
      this.drawCurve(h.red, h.peak, this.night ? '#EF5555' : '#C93535', false);
      this.drawCurve(h.green, h.peak, this.night ? '#4BC781' : '#248A50', false);
      this.drawCurve(h.blue, h.peak, this.night ? '#5E8DFA' : '#3568CE', false);
    }
  }
  private drawCurve(data: number[], peak: number, color: string, fill: boolean): void {
    const ctx = this.canvasCtx, width = ctx.width, height = ctx.height;
    ctx.beginPath(); if (fill) ctx.moveTo(0, height - 1);
    for (let i = 0; i < 256; i++) {
      const x = i * (width - 1) / 255;
      const y = height - 2 - histogramHeight(data[i], peak) * Math.max(1, height - 8);
      if (i === 0 && !fill) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    if (fill) {
      ctx.lineTo(width - 1, height - 1); ctx.closePath(); ctx.fillStyle = color; ctx.fill();
    } else { ctx.strokeStyle = color; ctx.lineWidth = 1.25; ctx.stroke(); }
  }
}
