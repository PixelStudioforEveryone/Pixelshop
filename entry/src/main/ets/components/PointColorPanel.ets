import { EditSession } from '../edit/models/EditSession';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { PointColorSample, MAX_POINT_COLORS, hsl01ToRgb } from '../edit/engine/PointColorCore';
import { SliderControl } from './SliderControl';
import { VividNative } from './VividNativeTheme';

/**
 * Point colour: up to 8 sampled colours, each with the shift the user dialled in.
 *
 * "添加颜色" no longer plants a default colour: it arms the canvas eyedropper,
 * the user taps the photo, and the pixel under the tap becomes the sample. The
 * colour therefore always comes from a real source pixel (PointColorPicker),
 * mapped through the same display→source geometry the brush and retouch tools
 * use.
 *
 * This panel deliberately exposes ONLY three sliders for the selected sample:
 * 色相 / 饱和度 / 明度. They drive the sample's shift fields (the ranges that
 * decide how far the shift reaches, and the sampled HSL itself, stay in the
 * model so old sidecars still load, but are no longer editable here). The
 * track of each slider is painted from the selected sample's actual colour:
 * the sample's hue sits at the centre of a full ±180° hue wheel, while the
 * saturation and luminance tracks run from grey / dark to saturated / bright.
 *
 * Tapping a sample row selects it; the sliders then edit that sample. Deleting
 * it, loading another photo, or opening the panel with no samples leaves the
 * sliders on a neutral grey ramp.
 */
/** Neutral fallback ramp: no sample selected, or the sample was removed. */
const NEUTRAL_RAMP: string = '#5B6472|#8D96A4|#D5DBE3';

@Component
export struct PointColorPanel {
  @Consume('editSession') editSession: EditSession;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  /** 嵌入混色器时由外层提供“点颜色”标题，这里只保留计数与操作按钮。 */
  @Prop nested: boolean = false;
  /** Bumped on every edit so the list re-renders: the samples are plain
   *  interfaces inside an array, so mutating one field is not deeply observable. */
  @State private revision: number = 0;
  /** Index of the sample the three sliders edit. -1 means none. */
  @State private selected: number = -1;
  // The canvas adds the sample, so the panel is told through this narrow signal
  // and can select the new entry without rebuilding the whole editor.
  @StorageProp('pointColorRevision') @Watch('onPointColorRevision') private pickRevision: number = 0;
  private timer: number = -1;
  /** Sample count seen by the last revision handler, to tell an addition from a
   *  deletion (only an addition should move the selection). */
  private lastSampleCount: number = 0;

  aboutToAppear(): void {
    this.lastSampleCount = this.editSession.pointColor.samples.length;
    this.selected = this.lastSampleCount > 0 ? 0 : -1;
  }

  aboutToDisappear(): void {
    // Leaving the mixer (or collapsing this section) must never leave the
    // canvas in picking mode: the button that cancels it is gone.
    this.editSession.cancelPointColorPick();
    if (this.timer !== -1) this.flushRender();
  }

  private onPointColorRevision(): void {
    const count = this.editSession.pointColor.samples.length;
    if (count > this.lastSampleCount) {
      // A pixel was just picked: select the new sample so the sliders below act
      // on the colour the user just tapped.
      this.selected = count - 1;
    } else if (this.selected >= count) {
      this.selected = count - 1;
    }
    this.lastSampleCount = count;
    this.revision++;
  }

  /**
   * Enter or leave the canvas eyedropper. Entering adds NOTHING; it only arms
   * the mode whose hint asks for a tap on the photo. Clicking the same button
   * again is the explicit cancel path.
   */
  private togglePick(): void {
    if (this.editSession.pointColor.picking) {
      this.editSession.cancelPointColorPick();
      return;
    }
    this.editSession.beginPointColorPick();
  }

  private removeAt(index: number): void {
    // Deleting a sample is also a way out of picking mode (the list the user
    // was sampling for has changed).
    this.editSession.cancelPointColorPick();
    this.editSession.pushUndo();
    this.editSession.pointColor.removeAt(index);
    const count = this.editSession.pointColor.samples.length;
    if (this.selected === index) {
      this.selected = count > 0 ? Math.min(index, count - 1) : -1;
    } else if (this.selected > index) {
      this.selected--;
    }
    if (this.selected >= count) this.selected = count - 1;
    this.lastSampleCount = count;
    this.commit();
  }

  private clearAll(): void {
    this.editSession.cancelPointColorPick();
    if (this.editSession.pointColor.samples.length === 0) return;
    this.editSession.pushUndo();
    this.editSession.pointColor.clear();
    this.selected = -1;
    this.lastSampleCount = 0;
    this.commit();
  }

  private commit(): void {
    // New array identity so the list and the sliders re-read their values.
    this.editSession.pointColor.samples = this.editSession.pointColor.samples.slice();
    this.revision++;
    this.requestRender();
  }

  private requestRender(): void {
    this.editSession.requestProcessing();
    if (this.timer !== -1) return;
    this.timer = setTimeout(() => { this.timer = -1; ImageProcessor.process(this.editSession); }, 33);
  }

  private flushRender(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    ImageProcessor.process(this.editSession);
  }

  /** Selected sample, or null while none is available. */
  private selectedSample(): PointColorSample | null {
    const samples = this.editSession.pointColor.samples;
    if (this.selected < 0 || this.selected >= samples.length) return null;
    return samples[this.selected];
  }

  /** The sample the UI highlights; tolerates a stale index after a photo swap. */
  private selectedIndex(): number {
    const count = this.editSession.pointColor.samples.length;
    if (count === 0) return -1;
    if (this.selected < 0 || this.selected >= count) return count - 1;
    return this.selected;
  }

  private value(key: string): number {
    const sample = this.selectedSample();
    if (!sample) return 0;
    if (key === 'hueShift') return sample.hueShift;
    if (key === 'saturationShift') return sample.saturationShift;
    return sample.luminanceShift;
  }

  private applyShift(key: string, value: number): void {
    const sample = this.selectedSample();
    if (!sample) return;
    if (key === 'hueShift') sample.hueShift = value;
    else if (key === 'saturationShift') sample.saturationShift = value;
    else sample.luminanceShift = value;
    this.commit();
  }

  private colorHex(hue: number, saturation: number, luminance: number): string {
    const rgb = hsl01ToRgb(hue, saturation, luminance);
    const hex = (component: number): string => {
      const byte = Math.max(0, Math.min(255, Math.round(component * 255)));
      const text = byte.toString(16);
      return text.length === 1 ? '0' + text : text;
    };
    return '#' + hex(rgb[0]) + hex(rgb[1]) + hex(rgb[2]);
  }

  /** A CSS-style hex swatch for the sampled colour. */
  private swatch(sample: PointColorSample): string {
    return this.colorHex(sample.hue, sample.saturation, sample.luminance);
  }

  /**
   * 色相滑槽：以该样本色相为中心，从 h-180° 到 h+180° 环绕铺满色相环。
   * Nine stops (45° apart) keep the interpolation on the wheel rather than
   * cutting across it as a two-stop red→red gradient would.
   *
   * The hue itself is exactly the sample's; saturation/lightness only get
   * legibility floors. A near-black or near-grey sample would otherwise make
   * the whole "wheel" collapse to black, which hides the mapping the track is
   * supposed to show. Achromatic samples return the neutral ramp because their
   * hue is undefined.
   */
  private hueRamp(sample: PointColorSample | null): string {
    if (!sample || sample.saturation <= 0.04) return NEUTRAL_RAMP;
    const saturation: number = Math.max(0.65, sample.saturation);
    const lightness: number = Math.max(0.4, Math.min(0.62, sample.luminance));
    const stops: string[] = [];
    for (let i = 0; i <= 8; i++) {
      // -0.5..0.5 turns around the sample hue; the centre stop is the sample.
      const offset = i / 8 - 0.5;
      stops.push(this.colorHex(sample.hue + offset, saturation, lightness));
    }
    return stops.join('|');
  }

  /** 饱和度滑槽：该样本色相下，灰（s=0）→样本色→高饱和（s=1）。 */
  private saturationRamp(sample: PointColorSample | null): string {
    if (!sample) return NEUTRAL_RAMP;
    return [
      this.colorHex(sample.hue, 0, sample.luminance),
      this.colorHex(sample.hue, sample.saturation, sample.luminance),
      this.colorHex(sample.hue, 1, sample.luminance),
    ].join('|');
  }

  /** 明度滑槽：该样本色相/饱和度下，暗（l=0）→样本色→亮（l=1）。 */
  private luminanceRamp(sample: PointColorSample | null): string {
    if (!sample) return NEUTRAL_RAMP;
    return [
      this.colorHex(sample.hue, sample.saturation, 0),
      this.colorHex(sample.hue, sample.saturation, sample.luminance),
      this.colorHex(sample.hue, sample.saturation, 1),
    ].join('|');
  }

  private textColor(): Resource {
    return VividNative.textPrimary;
  }

  private subTextColor(): Resource {
    return VividNative.textSecondary;
  }

  build() {
    Column() {
      Row() {
        if (!this.nested) {
          Text('点颜色').fontSize(12).fontWeight(FontWeight.Bold).fontColor(this.textColor());
        }
        Text('（' + this.editSession.pointColor.samples.length + '/' + MAX_POINT_COLORS + '）')
          .fontSize(10).fontColor(this.subTextColor()).margin({ left: 4 });
        Blank();
        // 取色中：按钮变成“点按图片取色”并保持高亮，再次点击即取消；未取色时
        // 显示“添加颜色”。满额（或图片还没加载）时不可用，避免进入一个点了也
        // 不会有结果的状态。
        Button() {
          Text(this.editSession.pointColor.picking ? '点按图片取色' : '添加颜色').fontSize(10);
        }
          .height(26).padding({ left: 10, right: 10 })
          .buttonStyle(this.editSession.pointColor.picking ?
            ButtonStyleMode.NORMAL : ButtonStyleMode.EMPHASIZED).controlSize(ControlSize.SMALL)
          .enabled(!this.editSession.pointColor.isFull() && this.editSession.sourcePixelMap !== null)
          .onClick((): void => { this.togglePick(); });
        Button() {
          Text('清除').fontSize(10);
        }
          .height(26).padding({ left: 10, right: 10 }).margin({ left: 6 })
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick((): void => { this.clearAll(); });
      }.width('100%').height(32).padding({ left: 14, right: 10 });

      if (this.editSession.pointColor.picking) {
        // 取色状态下最显眼的一行提示：用户点的位置才是样本的颜色来源。
        Text('请在图片上点一下要调整的颜色；再点一次「点按图片取色」可取消。')
          .fontSize(10).fontColor(VividNative.emphasize).width('100%')
          .padding({ left: 14, right: 14, bottom: 6 });
      } else if (this.editSession.pointColor.samples.length === 0) {
        Text('点「添加颜色」，然后在图片上点一下要调整的颜色；取到的颜色会显示在这里，可继续调整它的色相/饱和度/明度。')
          .fontSize(10).fontColor(this.subTextColor()).width('100%')
          .padding({ left: 14, right: 14, bottom: 6 });
      }

      ForEach(this.editSession.pointColor.samples, (sample: PointColorSample, index: number) => {
        Row() {
          // 点按样本本身选中它；删除按钮独立在外，避免误选中。
          Row() {
            Row()
              .width(18).height(18).borderRadius(VividNative.radiusLevel4)
              .backgroundColor(this.swatch(sample))
              .border({
                width: this.selectedIndex() === index ? 2 : 1,
                color: this.selectedIndex() === index ? VividNative.emphasize : VividNative.separator,
              });
            Text('颜色 ' + (index + 1)).fontSize(11)
              .fontWeight(this.selectedIndex() === index ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.textColor()).margin({ left: 8 });
            Blank();
          }
          .layoutWeight(1)
          .height('100%')
          .focusable(true)
          .focusBox(VividNative.focusBox())
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => {
            this.selected = index;
            // Force the ForEach rows to re-evaluate their selected styling.
            this.revision++;
          });
          // 删除是警告动作：用原生 ButtonRole.ERROR 拿系统的告警前景色。
          Button() {
            Text('删除').fontSize(10);
          }
            .height(24).padding({ left: 8, right: 8 })
            .buttonStyle(ButtonStyleMode.TEXTUAL).role(ButtonRole.ERROR).controlSize(ControlSize.SMALL)
            .onClick((): void => { this.removeAt(index); });
        }
        .width('100%')
        .height(32)
        .padding({ left: 8, right: 8 })
        .borderRadius(6)
        .backgroundColor(this.selectedIndex() === index ? VividNative.componentNormal : Color.Transparent);
      }, (sample: PointColorSample, index: number) => index + ':' + this.revision);

      this.Sliders();
    }.width('100%').id('point-color-' + this.pickRevision.toString());
  }

  /**
   * The only three controls left. The ramps are recomputed from the selected
   * sample on every render (switching rows changes the whole track), and fall
   * back to NEUTRAL_RAMP when no sample is selected.
   */
  @Builder
  private Sliders() {
    Column() {
      SliderControl({
        label: '色相',
        value: this.value('hueShift'),
        min: -1,
        max: 1,
        step: 0.01,
        formatValue: (v: number): string => v.toFixed(2),
        gradientType: 'ramp',
        gradientRamp: this.hueRamp(this.selectedSample()),
        whiteAnchor: true,
        onBegin: (): void => {
          if (this.selectedSample() !== null) this.editSession.pushUndo();
        },
        onEnd: (): void => { this.flushRender(); },
        onChange: (v: number): void => { this.applyShift('hueShift', v); },
      });
      SliderControl({
        label: '饱和度',
        value: this.value('saturationShift'),
        min: -1,
        max: 1,
        step: 0.01,
        formatValue: (v: number): string => v.toFixed(2),
        gradientType: 'ramp',
        gradientRamp: this.saturationRamp(this.selectedSample()),
        whiteAnchor: true,
        onBegin: (): void => {
          if (this.selectedSample() !== null) this.editSession.pushUndo();
        },
        onEnd: (): void => { this.flushRender(); },
        onChange: (v: number): void => { this.applyShift('saturationShift', v); },
      });
      SliderControl({
        label: '明度',
        value: this.value('luminanceShift'),
        min: -1,
        max: 1,
        step: 0.01,
        formatValue: (v: number): string => v.toFixed(2),
        gradientType: 'ramp',
        gradientRamp: this.luminanceRamp(this.selectedSample()),
        whiteAnchor: true,
        onBegin: (): void => {
          if (this.selectedSample() !== null) this.editSession.pushUndo();
        },
        onEnd: (): void => { this.flushRender(); },
        onChange: (v: number): void => { this.applyShift('luminanceShift', v); },
      });
    }.width('100%').padding({ top: 2, bottom: 4 });
  }
}
