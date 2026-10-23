import { EditSession } from '../edit/models/EditSession';
import { CropAspectRatio } from '../edit/models/ToolType';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { ToolType } from '../edit/models/ToolType';
import { VividNative, VividNumberField } from './VividNativeTheme';
import { UprightPanel } from './UprightPanel';
import { DisclosureChevron } from './DisclosureChevron';

interface AspectRatioOption {
  label: string;
  ratio: number; // 0 = freeform
}

const ASPECT_RATIOS: AspectRatioOption[] = [
  { label: '自由', ratio: 0 },
  { label: '原始', ratio: -1 },
  { label: '1:1', ratio: 1 },
  { label: '4:3', ratio: 4 / 3 },
  { label: '3:2', ratio: 3 / 2 },
  { label: '16:9', ratio: 16 / 9 },
  { label: '9:16', ratio: 9 / 16 },
];

interface GeometryControl { label: string; min: number; max: number; step: number; }
const GEOMETRY_CONTROLS: GeometryControl[] = [
  { label: '垂直', min: -100, max: 100, step: 1 },
  { label: '水平', min: -100, max: 100, step: 1 },
  { label: '旋转', min: -45, max: 45, step: 0.1 },
  { label: '长宽比', min: -100, max: 100, step: 1 },
  { label: '缩放', min: 50, max: 150, step: 1 },
  { label: '横向补正', min: -50, max: 50, step: 0.1 },
  { label: '纵向补正', min: -50, max: 50, step: 0.1 },
];

@Component
export struct CropPanel {
  @Prop externalScroll: boolean = false;
  @Consume('editSession') editSession: EditSession;
  @State private selectedRatio: number = 0;
  // 透视/拉直属于几何校正，入口从调色面板搬到这里；默认展开，进入裁剪即可看到。
  @State private uprightOpen: boolean = true;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  private geometryTimer: number = -1;

  build() {
    if (this.externalScroll) { this.CropContents(); }
    else { Scroll() { this.CropContents(); }.width('100%').height('100%').scrollBar(BarState.Off); }
  }
  @Builder
  private CropContents() {
    Column() {
      Text('裁剪')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(VividNative.textPrimary)
        .width('100%')
        .padding({ left: 12, top: 8, bottom: 4 });

      // Aspect ratio presets
      Scroll() {
        Row() {
          ForEach(ASPECT_RATIOS, (opt: AspectRatioOption) => {
            Text(opt.label)
              .fontSize(12)
              .fontColor(VividNative.textPrimary)
              .backgroundColor(Color.Transparent)
              .border({ width: this.selectedRatio === opt.ratio ? 1 : 0, color: VividNative.separator })
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(VividNative.radiusSmallButton)
              .margin({ right: 6 })
              .onClick(() => {
                this.selectedRatio = opt.ratio;
                const working = this.editSession.cropWorking;
                if (opt.ratio === -1) {
                  // Original ratio of the currently displayed image
                  const size = this.editSession.displayedPixelSize();
                  if (size[0] > 0 && size[1] > 0) {
                    this.editSession.cropAspectRatio = size[0] / size[1];
                    const fitted = this.editSession.fitWorkingRect(
                      working[0], working[1], working[2], working[3], size[0] / size[1], -1);
                    if (fitted) this.editSession.cropWorking = fitted;
                  }
                } else if (opt.ratio === 0) {
                  this.editSession.cropAspectRatio = 0;
                } else {
                  this.editSession.cropAspectRatio = opt.ratio;
                  const fitted = this.editSession.fitWorkingRect(
                    working[0], working[1], working[2], working[3], opt.ratio, -1);
                  if (fitted) this.editSession.cropWorking = fitted;
                }
                // The ratio only reshapes the working frame overlay; the
                // previewed image is unchanged, so repaint the overlay
                // without scheduling a render pass.
                AppStorage.setOrCreate('cropOverlayRevision', Date.now());
              });
          }, (opt: AspectRatioOption) => opt.label);
        }
        .padding({ left: 12, right: 12 });
      }
      .width('100%')
      .scrollBar(BarState.Off);

      Divider().color(VividNative.divider)
        .width('90%').margin({ top: 8, bottom: 8 });

      // Rotate and flip controls
      Row() {
        // Rotate 90° CW
        Column() {
          Text('↻')
            .fontSize(24)
            .fontColor(VividNative.textPrimary);
          Text('旋转')
            .fontSize(10)
            .fontColor(VividNative.textSecondary);
        }
        .width(60).height(52)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(VividNative.componentNormal)
        .borderRadius(VividNative.radiusCard)
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => {
          this.editSession.rotateCW();
          this.refreshCropPreview();
        });

        // Flip horizontal
        Column() {
          Text('⇔')
            .fontSize(22)
            .fontColor(VividNative.textPrimary);
          Text('水平翻转')
            .fontSize(10)
            .fontColor(VividNative.textSecondary);
        }
        .width(60).height(52)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(VividNative.componentNormal)
        .borderRadius(VividNative.radiusCard)
        .hoverEffect(HoverEffect.Highlight)
        .margin({ left: 8 })
        .onClick(() => {
          this.editSession.flipHorizontal();
          this.refreshCropPreview();
        });

        // Flip vertical
        Column() {
          Text('⇕')
            .fontSize(22)
            .fontColor(VividNative.textPrimary);
          Text('垂直翻转')
            .fontSize(10)
            .fontColor(VividNative.textSecondary);
        }
        .width(60).height(52)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(VividNative.componentNormal)
        .borderRadius(VividNative.radiusCard)
        .hoverEffect(HoverEffect.Highlight)
        .margin({ left: 8 })
        .onClick(() => {
          this.editSession.flipVertical();
          this.refreshCropPreview();
        });

        Blank();

        // Reset crop
        Button('重置')
          .fontSize(12)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo();
            this.editSession.resetCrop();
            this.editSession.rotation = 0;
            this.editSession.flipH = false;
            this.editSession.flipV = false;
            this.editSession.cropWorking = [0, 0, 1, 1];
            this.selectedRatio = 0;
            this.refreshCropPreview();
          });
      }
      .width('100%')
      .padding({ left: 12, right: 12 });

      Divider().color(VividNative.divider)
        .width('90%').margin({ top: 8, bottom: 8 });

      Text('几何 · 手动转换').fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor(VividNative.textPrimary).width('100%').padding(12);
      Row() {
        Checkbox().select(this.editSession.geometry[7] === 1)
          .onChange((checked: boolean) => { this.setGeometry(7, checked ? 1 : 0); });
        Text('限制裁切').fontSize(12)
          .fontColor(VividNative.textPrimary);
        Blank();
        Button('重置几何').fontSize(12)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL).onClick(() => {
          this.editSession.pushUndo();
          this.editSession.geometry = [0, 0, 0, 0, 100, 0, 0, 0];
          this.refreshCropPreview();
        });
      }.width('100%').padding({ left: 12, right: 12 });
      ForEach(GEOMETRY_CONTROLS, (control: GeometryControl, index: number) => {
        Row() {
          Text(control.label)
            .fontSize(12)
            .fontColor(VividNative.textPrimary)
            .width(48);
          Slider({ value: this.editSession.geometry[index], min: control.min, max: control.max, step: control.step })
            .layoutWeight(1)
            // This SDK's slider track resource is also blue on the emulator;
            // use equal neutral colors for both sections so no progress fill remains.
            .trackColor(this.isNightMode ? '#666666' : '#B8B8B8')
            .selectedColor(this.isNightMode ? '#666666' : '#B8B8B8')
            .blockColor('#999999')
            .blockBorderColor('#999999')
            .blockBorderWidth(1)
            .enableHapticFeedback(true)
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.Begin) this.editSession.pushUndo();
              this.setGeometry(index, value);
            });
          TextInput({ text: this.editSession.geometry[index].toFixed(control.step < 1 ? 1 : 0) })
            .width(62)
            .height(30)
            .fontSize(12)
            .textAlign(TextAlign.Center)
            // 数值只显示数字本身：日夜模式都不再有填充与描边（仍可点入编辑）。
            .attributeModifier(VividNumberField.plain)
            .onChange((text: string) => {
              const value = Number(text);
              if (text.trim().length > 0 && Number.isFinite(value)) {
                this.setGeometry(index, Math.max(control.min, Math.min(control.max, value)));
              }
            });
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 4 });
      });

      Divider().color(VividNative.divider)
        .width('90%').margin({ top: 8, bottom: 6 });

      // 透视 / 拉直：原来在调色面板的独立分区，现作为裁剪页的几何工具。
      // Upright 解算写的就是 geometry 的 g[0..2]，与上面的手动几何同一组字段。
      Row() {
        Text('透视 · 拉直').fontSize(13).fontWeight(FontWeight.Bold)
          .fontColor(VividNative.textPrimary);
        Blank();
        DisclosureChevron({ expanded: this.uprightOpen });
      }
      .width('100%')
      .height(34)
      .padding({ left: 14, right: 12 })
      .focusable(true)
      .focusBox(VividNative.focusBox())
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => { this.uprightOpen = !this.uprightOpen; });
      if (this.uprightOpen) {
        UprightPanel({ nested: true, cropEmbedded: true });
      }

      // Crop overlay instructions
      Text('拖动裁剪框边缘调整裁剪区域')
        .fontSize(11)
        .fontColor(VividNative.textSecondary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 4, bottom: 8 });

      // Apply crop button
      // 主操作：原生强调按钮（系统主题色填充/前景/按压反馈）。
      Button('应用裁剪')
        .fontSize(14)
        .type(ButtonType.Capsule)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .width('90%')
        .height(40)
        .margin({ bottom: 8 })
        .onClick(() => {
          // Fold the working frame into the session crop, then leave the
          // tool. Undo is captured once here; frame drags never touched
          // session state, so an untouched frame adds no undo entry.
          const working = this.editSession.cropWorking;
          const untouched = working[0] === 0 && working[1] === 0 && working[2] === 1 && working[3] === 1;
          console.info(`VIVID_FRAME t=${Date.now()} event=crop_apply_tap sid=${this.editSession.sessionId} working=${working.join(',')} crop=${this.editSession.cropLeft.toFixed(3)},${this.editSession.cropTop.toFixed(3)},${this.editSession.cropRight.toFixed(3)},${this.editSession.cropBottom.toFixed(3)} ratio=${this.editSession.cropAspectRatio} geo=${this.editSession.geometry.join(',')}`);
          if (!untouched) this.editSession.pushUndo();
          this.editSession.commitCropWorking();
          this.editSession.isCropping = false;
          this.editSession.setActiveTool(ToolType.ADJUST);
          // Returning to the adjustment panel keeps panel/tool/cropping state
          // in sync; before this the crop panel stayed open with a stale tool
          // so canvas touches routed to the before/after handler instead of
          // crop dragging.
          AppStorage.setOrCreate('editorPanelRequest', 0);
          this.editSession.bumpProcessing();
          this.editSession.requestProcessing();
          AppStorage.setOrCreate('cropOverlayRevision', this.editSession.processingVersion);
          ImageProcessor.process(this.editSession).then(() => {
            this.editSession.bumpProcessing();
          });
        });
    }
    .width('100%')
    .padding({ bottom: 24 })
    .backgroundColor(Color.Transparent);
  }

  private setGeometry(index: number, value: number): void {
    const next = this.editSession.geometry.slice();
    next[index] = value;
    this.editSession.geometry = next;
    if (this.geometryTimer !== -1) clearTimeout(this.geometryTimer);
    this.geometryTimer = setTimeout(() => { this.geometryTimer = -1; this.refreshCropPreview(); }, 40);
  }

  aboutToDisappear(): void {
    if (this.geometryTimer !== -1) { clearTimeout(this.geometryTimer); this.geometryTimer = -1; ImageProcessor.process(this.editSession); }
  }

  /** Repaint the imperative crop overlay and queue a fresh image preview in
   * the same turn as the button tap. */
  private refreshCropPreview(): void {
    this.editSession.isCropping = true;
    console.info(`VIVID_FRAME t=${Date.now()} event=refresh_crop_preview sid=${this.editSession.sessionId} crop=${this.editSession.cropLeft.toFixed(3)},${this.editSession.cropTop.toFixed(3)},${this.editSession.cropRight.toFixed(3)},${this.editSession.cropBottom.toFixed(3)}`);
    // Mark the request interactive so the crop preview renders on the
    // bounded 512px surface instead of a multi-second full-resolution pass;
    // the processor schedules the full-resolution refinement automatically
    // once gestures go quiet.
    this.editSession.requestProcessing();
    this.editSession.bumpProcessing();
    AppStorage.setOrCreate('cropOverlayRevision', this.editSession.processingVersion);
    ImageProcessor.process(this.editSession).then(() => {
      AppStorage.setOrCreate('cropOverlayRevision', this.editSession.processingVersion);
    });
  }
}
