import { EditSession } from '../edit/models/EditSession';
import { DenoiseSettings } from '../edit/models/DenoiseSettings';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { SliderControl } from './SliderControl';
import { DisclosureChevron } from './DisclosureChevron';
import { VividNative } from './VividNativeTheme';

interface NoiseControl { key: string; label: string; min: number; }
// Camera Raw's six controls, in its order. Luminance Contrast is the one signed
// control: it can also flatten the luminance (negative) rather than only restore
// contrast, so it must not be clamped at 0.
const NOISE_CONTROLS: NoiseControl[] = [
  { key: 'luminance', label: '亮度降噪', min: 0 }, { key: 'detail', label: '亮度细节', min: 0 },
  { key: 'luminanceContrast', label: '亮度对比度', min: -1 },
  { key: 'color', label: '彩色降噪', min: 0 }, { key: 'colorDetail', label: '彩色细节', min: 0 },
  { key: 'colorSmoothness', label: '颜色平滑', min: 0 },
];

@Component
export struct DenoisePanel {
  @Consume('editSession') editSession: EditSession;
  @State private expanded: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  private timer: number = -1;

  aboutToDisappear(): void {
    if (this.timer !== -1) this.flushRender();
  }

  build() {
    Column() {
      Row() {
        Text('降噪').fontSize(12).fontWeight(FontWeight.Bold)
          .fontColor(VividNative.textPrimary);
        Blank();
        Button() { Text('重置').fontSize(10); }
          .height(26).padding({ left: 10, right: 10 })
          .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
          .focusable(true).focusBox(VividNative.focusBox())
          .onClick(() => {
            this.editSession.pushUndo(); this.editSession.denoise = new DenoiseSettings(); this.requestRender();
          });
        Button() { DisclosureChevron({ expanded: this.expanded }); }
          .width(28).height(28).buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
          .focusable(true).focusBox(VividNative.focusBox())
          .onClick(() => { this.expanded = !this.expanded; });
      }.height(32).width('100%').alignItems(VerticalAlign.Center).padding({ left: 14, right: 10 });
      if (this.expanded) {
        ForEach(NOISE_CONTROLS, (control: NoiseControl) => {
          SliderControl({ label: control.label, value: this.value(control.key), min: control.min, max: 1, step: 0.01,
            formatValue: (v: number) => Math.round(v * 100).toString(),
            onBegin: () => { this.editSession.pushUndo(); },
            onEnd: () => { this.flushRender(); },
            onChange: (v: number) => {
              if (control.key === 'luminance') this.editSession.denoise.luminance = v;
              else if (control.key === 'color') this.editSession.denoise.color = v;
              else if (control.key === 'detail') this.editSession.denoise.detail = v;
              else if (control.key === 'colorDetail') this.editSession.denoise.colorDetail = v;
              else if (control.key === 'luminanceContrast') this.editSession.denoise.luminanceContrast = v;
              else this.editSession.denoise.colorSmoothness = v;
              this.requestRender();
            },
          });
        }, (control: NoiseControl) => control.key);
      }
    }.width('100%');
  }

  private value(key: string): number {
    if (key === 'luminance') return this.editSession.denoise.luminance;
    if (key === 'color') return this.editSession.denoise.color;
    if (key === 'detail') return this.editSession.denoise.detail;
    if (key === 'colorDetail') return this.editSession.denoise.colorDetail;
    if (key === 'luminanceContrast') return this.editSession.denoise.luminanceContrast;
    return this.editSession.denoise.colorSmoothness;
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
}
