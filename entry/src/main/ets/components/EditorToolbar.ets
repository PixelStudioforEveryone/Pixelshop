import { EditSession } from '../edit/models/EditSession';
import { ToolType } from '../edit/models/ToolType';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { MaskComponentType } from '../edit/models/Mask';

@Component
export struct EditorToolbar {
  @Consume('editSession') editSession: EditSession;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;

  build() {
    Scroll() {
      Row() {
        this.ToolButton('移动', ToolType.ADJUST, '✥');
        this.ToolButton('裁剪', ToolType.CROP, '⊞');
        this.ToolButton('蒙版', ToolType.BRUSH_MASK, '◉');
        this.ToolButton('校正', ToolType.UPRIGHT, '⌗');
      }
      .height(50)
      .padding({ left: 4, right: 4 });
    }
    .width(225)
    .height(50)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .backgroundColor(this.isNightMode ? 'rgba(38,40,45,0.96)' : 'rgba(255,255,255,0.96)')
    .backdropBlur(12)
    .borderRadius(28)
    .border({ width: 1, color: this.isNightMode ? '#4A4F59' : '#D5DBE5' });
  }

  @Builder
  ToolButton(label: string, tool: ToolType, icon: string) {
    Column() {
      Text(icon)
        .fontSize(16)
        .fontColor(this.editSession.activeTool === tool ? '#FFFFFF' : (this.isNightMode ? '#D5DAE3' : '#4F5B70'));

      Text(label)
        .fontSize(9)
         .fontColor(this.editSession.activeTool === tool ? '#FFFFFF' : (this.isNightMode ? '#AEB6C4' : '#6B778A'));
    }
    .width(50)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.editSession.activeTool === tool ? '#316CF4' : '#00000000')
    .onClick(() => {
      this.editSession.setActiveTool(tool);
      // When selecting crop, enable cropping mode
      if (tool === ToolType.CROP) {
        this.editSession.isCropping = true;
        this.editSession.canvasScale = 1;
        this.editSession.canvasOffsetX = 0;
        this.editSession.canvasOffsetY = 0;
        ImageProcessor.process(this.editSession);
      } else {
        this.editSession.isCropping = false;
        if (tool === ToolType.BRUSH_MASK) {
          // Open the existing mask when present; otherwise create the first
          // brush mask so the layer and controls appear immediately.
          this.editSession.adjustmentScope = 1;
          if (!this.editSession.activeMaskLayer) {
            this.editSession.createMaskLayer(MaskComponentType.BRUSH);
          }
        }
        ImageProcessor.process(this.editSession);
      }

    });
  }
}











