import { EditSession } from '../edit/models/EditSession';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { DesktopRawSlider } from './DesktopRawSlider';
import { VividNative } from './VividNativeTheme';

/** One row of the panel: a label, a model field and the slider bounds. */
interface OkLChControl {
  label: string;
  key: string;
  lower: number;
  upper: number;
}

/**
 * OkLCh grading: lightness, chroma and hue in a perceptually uniform space.
 *
 * The three sliders are plain offsets in Oklab units rather than vendor-specific
 * "amounts": lightness is added to L (whose whole range is 0..1), chroma scales
 * saturation (-1 is fully grey, +1 doubles), and hue is added in turns. They are real
 * controls backed by `OkLChCore`; there is no hidden per-hue-band targeting and no
 * pretence of matching another application's implementation.
 *
 * The panel deliberately does NOT offer a "gamut warning" toggle: the engine reduces
 * chroma to stay in sRGB unconditionally, so a toggle would be a control that changes
 * nothing.
 */
const OKLCH_CONTROLS: OkLChControl[] = [
  { label: '明度', key: 'lightness', lower: -1, upper: 1 },
  { label: '饱和度', key: 'chroma', lower: -1, upper: 1 },
  { label: '色相', key: 'hue', lower: -1, upper: 1 },
];

@Component
export struct OkLChPanel {
  @Consume('editSession') editSession: EditSession;
  @StorageProp('vividNightMode') private night: boolean = false;
  @StorageProp('oklchRevision') private revision: number = 0;

  build() {
    Column({ space: 10 }) {
      Text('在感知均匀的 OkLCh 空间里调整。色相与明度在提高饱和度时保持不变；超出 sRGB 时只让饱和度让步，不做逐通道裁切。')
        .fontSize(12).fontColor(this.textColor()).width('100%');
      ForEach(OKLCH_CONTROLS, (control: OkLChControl) => {
        DesktopRawSlider({ label: control.label, controlId: 'oklch-' + control.key,
          lower: control.lower, upper: control.upper,
          currentValue: this.value(control.key),
          onUpdate: (v: number) => { this.apply(control.key, v); } });
      }, (control: OkLChControl) => control.key);
      Row({ space: 8 }) {
        Button('重置').fontSize(12).height(30)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo();
            this.editSession.oklch.reset();
            this.commit();
          });
        Text(this.status()).fontSize(11).fontColor(VividNative.textSecondary).layoutWeight(1);
      }.width('100%');
    }.id('oklch-panel-' + this.revision).width('100%').padding(20).alignItems(HorizontalAlign.Start);
  }

  private value(key: string): number {
    if (key === 'lightness') return this.editSession.oklch.lightness;
    if (key === 'chroma') return this.editSession.oklch.chroma;
    return this.editSession.oklch.hue;
  }

  private apply(key: string, v: number): void {
    if (key === 'lightness') this.editSession.oklch.lightness = v;
    else if (key === 'chroma') this.editSession.oklch.chroma = v;
    else this.editSession.oklch.hue = v;
    this.commit();
  }

  private status(): string {
    return this.editSession.oklch.isBypass() ? '未启用' : '已启用';
  }

  private commit(): void {
    this.editSession.bumpProcessing();
    AppStorage.setOrCreate('oklchRevision', Date.now());
    ImageProcessor.process(this.editSession);
  }

  private textColor(): Resource { return VividNative.textPrimary; }
}
