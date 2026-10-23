import { EditSession } from '../edit/models/EditSession';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { DesktopRawSlider } from './DesktopRawSlider';
import { VividNative } from './VividNativeTheme';

/**
 * Black-and-white conversion with a per-hue-band mixer.
 *
 * The eight sliders are real band weights in -1..1 backed by `BlackWhiteCore`; there is
 * no separate "convert to greyscale" slider doing the work, and no band is a dead control
 * (the core suite asserts that every one of the eight reaches its own hue). The on/off
 * switch is the stage's bypass: switched off, the stage costs nothing at all.
 *
 * The band list and its names come from the engine rather than being repeated here, so the
 * UI cannot offer a slider for a band the engine does not have.
 */
@Component
export struct BlackWhitePanel {
  @Consume('editSession') editSession: EditSession;
  @StorageProp('vividNightMode') private night: boolean = false;
  @StorageProp('blackWhiteRevision') private revision: number = 0;

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        // 开关态用原生按钮档位：开=EMPHASIZED（系统主题色），关=NORMAL。
        Button(this.editSession.blackWhite.enabled ? '黑白：开' : '黑白：关')
          .fontSize(12).height(32).layoutWeight(1)
          .buttonStyle(this.editSession.blackWhite.enabled ?
            ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo();
            this.editSession.blackWhite.enabled = !this.editSession.blackWhite.enabled;
            this.commit();
          });
        Button('重置').fontSize(12).height(32)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo();
            this.editSession.blackWhite.reset();
            this.commit();
          });
      }.width('100%');
      Text('切换为黑白后，用八条色相带决定每种颜色转成多亮。中性灰不受影响。')
        .fontSize(12).fontColor(this.textColor()).width('100%');
      if (this.editSession.blackWhite.enabled) {
        ForEach(this.bandIndices(), (index: number) => {
          DesktopRawSlider({ label: this.editSession.blackWhite.bandName(index),
            controlId: 'bw-band-' + index, lower: -1, upper: 1,
            currentValue: this.editSession.blackWhite.mixers[index],
            onUpdate: (v: number) => {
              this.editSession.blackWhite.setBand(index, v);
              this.commit();
            } });
        }, (index: number) => 'band-' + index);
      }
    }.id('black-white-panel-' + this.revision).width('100%').padding(20).alignItems(HorizontalAlign.Start);
  }

  private bandIndices(): number[] {
    const indices: number[] = [];
    for (let i = 0; i < this.editSession.blackWhite.bandCount(); i++) indices.push(i);
    return indices;
  }

  private commit(): void {
    this.editSession.bumpProcessing();
    AppStorage.setOrCreate('blackWhiteRevision', Date.now());
    ImageProcessor.process(this.editSession);
  }

  private textColor(): Resource { return VividNative.textPrimary; }
}
