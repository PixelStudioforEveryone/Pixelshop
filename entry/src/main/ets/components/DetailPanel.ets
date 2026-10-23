import { EditSession } from '../edit/models/EditSession';
import { DetailSettings } from '../edit/models/DetailSettings';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { SliderControl } from './SliderControl';
import { DisclosureChevron } from './DisclosureChevron';
import { VividNative } from './VividNativeTheme';

/**
 * Global detail stage: texture/clarity/dehaze and sharpening.
 *
 * Document-level like denoise, because all four effects are neighbourhood
 * operations the worker applies once to the composed frame. Sits in the same
 * 细节 section as denoise, which is where Camera Raw keeps these controls.
 */
interface DetailControl {
  key: string;
  label: string;
}

/** Signed controls: each has a meaningful inverse. */
const EFFECT_CONTROLS: DetailControl[] = [
  { key: 'texture', label: '纹理' },
  { key: 'clarity', label: '清晰度' },
  { key: 'dehaze', label: '去朦胧' },
];

/** Unsigned controls: sharpening shapes an edge, it has no negative form. */
const SHARPEN_CONTROLS: DetailControl[] = [
  { key: 'sharpenAmount', label: '锐化' },
  { key: 'sharpenRadius', label: '锐化半径' },
  { key: 'sharpenDetail', label: '锐化细节' },
  { key: 'sharpenMasking', label: '锐化蒙版' },
];

@Component
export struct DetailPanel {
  @Consume('editSession') editSession: EditSession;
  @State private effectsExpanded: boolean = true;
  @State private sharpenExpanded: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  private timer: number = -1;

  aboutToDisappear(): void {
    if (this.timer !== -1) this.flushRender();
  }

  build() {
    Column() {
      this.GroupHeader('效果', this.effectsExpanded, (): void => {
        this.effectsExpanded = !this.effectsExpanded;
      });
      if (this.effectsExpanded) {
        ForEach(EFFECT_CONTROLS, (control: DetailControl) => {
          SliderControl({
            label: control.label,
            value: this.value(control.key),
            min: -1,
            max: 1,
            step: 0.01,
            formatValue: (v: number) => Math.round(v * 100).toString(),
            onBegin: (): void => { this.editSession.pushUndo(); },
            onEnd: (): void => { this.flushRender(); },
            onChange: (v: number): void => {
              this.apply(control.key, v);
              this.requestRender();
            },
          });
        }, (control: DetailControl) => control.key);
      }

      this.GroupHeader('锐化', this.sharpenExpanded, (): void => {
        this.sharpenExpanded = !this.sharpenExpanded;
      });
      if (this.sharpenExpanded) {
        ForEach(SHARPEN_CONTROLS, (control: DetailControl) => {
          SliderControl({
            label: control.label,
            value: this.value(control.key),
            min: 0,
            max: 1,
            step: 0.01,
            // Radius is shown in the pixels it actually maps to at the reference
            // long edge (1..32 px), which is how Camera Raw presents it, rather
            // than as an opaque 0..100.
            formatValue: control.key === 'sharpenRadius'
              ? (v: number): string => Math.round(Math.pow(32, v)).toString() + ' px'
              : (v: number): string => Math.round(v * 100).toString(),
            onBegin: (): void => { this.editSession.pushUndo(); },
            onEnd: (): void => { this.flushRender(); },
            onChange: (v: number): void => {
              this.apply(control.key, v);
              this.requestRender();
            },
          });
        }, (control: DetailControl) => control.key);
      }
    }.width('100%');
  }

  @Builder
  private GroupHeader(title: string, expanded: boolean, toggle: () => void) {
    Row() {
      Text(title).fontSize(12).fontWeight(FontWeight.Bold)
        .fontColor(VividNative.textPrimary);
      Blank();
      Button() {
        Text('重置').fontSize(10);
      }
        .height(26).padding({ left: 10, right: 10 })
        .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
        .focusable(true).focusBox(VividNative.focusBox())
        .onClick((): void => {
          this.editSession.pushUndo();
          this.editSession.detail = new DetailSettings();
          this.requestRender();
        });
      Button() { DisclosureChevron({ expanded: expanded }); }
        .width(28).height(28).buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
        .focusable(true).focusBox(VividNative.focusBox())
        .onClick(toggle);
    }.height(32).width('100%').alignItems(VerticalAlign.Center).padding({ left: 14, right: 10 });
  }

  private apply(key: string, value: number): void {
    if (key === 'texture') this.editSession.detail.texture = value;
    else if (key === 'clarity') this.editSession.detail.clarity = value;
    else if (key === 'dehaze') this.editSession.detail.dehaze = value;
    else if (key === 'sharpenAmount') this.editSession.detail.sharpenAmount = value;
    else if (key === 'sharpenRadius') this.editSession.detail.sharpenRadius = value;
    else if (key === 'sharpenDetail') this.editSession.detail.sharpenDetail = value;
    else this.editSession.detail.sharpenMasking = value;
  }

  private value(key: string): number {
    if (key === 'texture') return this.editSession.detail.texture;
    if (key === 'clarity') return this.editSession.detail.clarity;
    if (key === 'dehaze') return this.editSession.detail.dehaze;
    if (key === 'sharpenAmount') return this.editSession.detail.sharpenAmount;
    if (key === 'sharpenRadius') return this.editSession.detail.sharpenRadius;
    if (key === 'sharpenDetail') return this.editSession.detail.sharpenDetail;
    return this.editSession.detail.sharpenMasking;
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
