import { EditSession } from '../edit/models/EditSession';
import { OpticsSettings } from '../edit/models/OpticsSettings';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { SliderControl } from './SliderControl';
import { DisclosureChevron } from './DisclosureChevron';
import { VividNative } from './VividNativeTheme';

/**
 * Lens corrections: distortion, lateral chromatic aberration, defringe and
 * vignetting.
 *
 * Document-level like denoise and the detail stage, because all four corrections
 * are full-frame operations.
 */
interface OpticsControl {
  key: string;
  label: string;
  lower: number;
}

/** Signed: each has a meaningful inverse. */
const LENS_CONTROLS: OpticsControl[] = [
  { key: 'distortion', label: '畸变', lower: -1 },
  { key: 'chromaticAberration', label: '横向色差', lower: -1 },
];

/** Unsigned: a fringe is suppressed, it has no negative form. */
const FRINGE_CONTROLS: OpticsControl[] = [
  { key: 'defringePurple', label: '紫边', lower: 0 },
  { key: 'defringeGreen', label: '绿边', lower: 0 },
];

/** The amount is signed; the midpoint only shapes where the falloff happens. */
const VIGNETTE_CONTROLS: OpticsControl[] = [
  { key: 'vignetteAmount', label: '暗角', lower: -1 },
  { key: 'vignetteMidpoint', label: '暗角中点', lower: 0 },
];

@Component
export struct OpticsPanel {
  @Consume('editSession') editSession: EditSession;
  @State private lensExpanded: boolean = true;
  @State private fringeExpanded: boolean = false;
  @State private vignetteExpanded: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  private timer: number = -1;

  aboutToDisappear(): void {
    if (this.timer !== -1) this.flushRender();
  }

  build() {
    Column() {
      this.GroupHeader('镜头校正', this.lensExpanded, LENS_CONTROLS, (): void => {
        this.lensExpanded = !this.lensExpanded;
      });
      if (this.lensExpanded) this.Rows(LENS_CONTROLS);
      this.GroupHeader('去边', this.fringeExpanded, FRINGE_CONTROLS, (): void => {
        this.fringeExpanded = !this.fringeExpanded;
      });
      if (this.fringeExpanded) this.Rows(FRINGE_CONTROLS);
      this.GroupHeader('暗角', this.vignetteExpanded, VIGNETTE_CONTROLS, (): void => {
        this.vignetteExpanded = !this.vignetteExpanded;
      });
      if (this.vignetteExpanded) this.Rows(VIGNETTE_CONTROLS);
    }.width('100%');
  }

  @Builder
  private Rows(controls: OpticsControl[]) {
    ForEach(controls, (control: OpticsControl) => {
      SliderControl({
        label: control.label,
        value: this.value(control.key),
        min: control.lower,
        max: 1,
        step: 0.01,
        formatValue: (v: number): string => Math.round(v * 100).toString(),
        onBegin: (): void => { this.editSession.pushUndo(); },
        onEnd: (): void => { this.flushRender(); },
        onChange: (v: number): void => {
          this.apply(control.key, v);
          this.requestRender();
        },
      });
    }, (control: OpticsControl) => control.key);
  }

  @Builder
  private GroupHeader(title: string, expanded: boolean, controls: OpticsControl[], toggle: () => void) {
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
          // Reset only the group this header belongs to, so clearing the vignette
          // does not also discard a lens correction the user just dialled in.
          if (title === '镜头校正') {
            this.editSession.optics.distortion = 0;
            this.editSession.optics.chromaticAberration = 0;
          } else if (title === '去边') {
            this.editSession.optics.defringePurple = 0;
            this.editSession.optics.defringeGreen = 0;
          } else {
            this.editSession.optics.vignetteAmount = 0;
            this.editSession.optics.vignetteMidpoint = 0.5;
          }
          this.requestRender();
        });
      Button() { DisclosureChevron({ expanded: expanded }); }
        .width(28).height(28).buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
        .focusable(true).focusBox(VividNative.focusBox())
        .onClick(toggle);
    }.height(32).width('100%').alignItems(VerticalAlign.Center).padding({ left: 14, right: 10 });
  }

  private apply(key: string, value: number): void {
    if (key === 'distortion') this.editSession.optics.distortion = value;
    else if (key === 'chromaticAberration') this.editSession.optics.chromaticAberration = value;
    else if (key === 'defringePurple') this.editSession.optics.defringePurple = value;
    else if (key === 'defringeGreen') this.editSession.optics.defringeGreen = value;
    else if (key === 'vignetteAmount') this.editSession.optics.vignetteAmount = value;
    else this.editSession.optics.vignetteMidpoint = value;
  }

  private value(key: string): number {
    if (key === 'distortion') return this.editSession.optics.distortion;
    if (key === 'chromaticAberration') return this.editSession.optics.chromaticAberration;
    if (key === 'defringePurple') return this.editSession.optics.defringePurple;
    if (key === 'defringeGreen') return this.editSession.optics.defringeGreen;
    if (key === 'vignetteAmount') return this.editSession.optics.vignetteAmount;
    return this.editSession.optics.vignetteMidpoint;
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
