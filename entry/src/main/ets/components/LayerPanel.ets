import { EditSession } from '../edit/models/EditSession';
import { Layer, BlendMode } from '../edit/models/Layer';
import { MaskType, MaskComponent, MaskComponentType, MaskBlendMode } from '../edit/models/Mask';
import { ToolType } from '../edit/models/ToolType';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { VividNative } from './VividNativeTheme';

@Component
export struct LayerPanel {
  @Consume('editSession') editSession: EditSession;
  @Prop showHeader: boolean = true;
  @Prop externalScroll: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;

  build() {
    Column() {
      if (this.showHeader) {
        Row() {
          Text('图层')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(VividNative.textPrimary);

          Blank();

          // 原生次要按钮（填充/文字/圆角/按压反馈由系统按钮样式提供）。
          Button('+')
            .fontSize(18)
            .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .width(36)
            .height(36)
            .focusable(true).focusBox(VividNative.focusBox())
            .onClick(() => {
              this.editSession.addLayer();
              ImageProcessor.process(this.editSession);
            });
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 4 });
      }
      // Layer list
      List() {
        ForEach(this.editSession.layers, (layer: Layer, index: number) => {
          ListItem() {
            this.LayerRow(layer, index);
          }
        }, (layer: Layer) => layer.id);
      }
      .height(this.externalScroll ? (this.editSession.layers.length * 76 + 8) : '100%')
      .scrollBar(BarState.Off)
      .width('100%');
    }
    .width('100%')
    .height(this.externalScroll ? 'auto' : '100%')
    .backgroundColor(Color.Transparent);
  }

  @Builder
  LayerRow(layer: Layer, index: number) {
    Row() {
      // Visibility toggle
      Toggle({ type: ToggleType.Checkbox, isOn: layer.visible })
        .width(20)
        .height(20)
        .onChange((val: boolean) => {
          this.editSession.pushUndo();
          layer.visible = val;
          this.editSession.invalidateMaskCache();
          this.editSession.bumpProcessing();
          ImageProcessor.process(this.editSession);
        });

      // Layer name
      Column() {
        Text(layer.name)
          .fontSize(13)
          .fontColor(VividNative.textPrimary)
          .fontWeight(index === this.editSession.activeLayerIndex ? FontWeight.Medium : FontWeight.Regular)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });

        // Opacity slider
        Row() {
          Text('不透明度')
            .fontSize(10)
            .fontColor(VividNative.textSecondary)
            .width(56);

          Stack() {
            Slider({
              style: SliderStyle.OutSet,
              min: 0,
              max: 1,
              step: 0.01,
              value: layer.opacity,
            })
              .width('100%')
              // 使用与调色滑块一致的系统滑块令牌 + 原生触感反馈。
              .trackColor(VividNative.sliderTrack)
              .selectedColor(VividNative.emphasize)
              // Use the same circular thumb treatment as the adjustment
              // sliders; the old overlaid triangle looked like a marker.
              // 不透明度的锚点用中性灰填充，和调色滑块的强调色锚点区分开。
              // 固定中灰在日间/夜间两种底色上都能读成"灰"，不跟随主题变白。
              .blockColor('#9AA3AE')
              .blockBorderColor(VividNative.componentNormal)
              .blockBorderWidth(1)
              .blockSize({ width: 16, height: 16 })
              .enableHapticFeedback(true)
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) this.editSession.pushUndo();
              })
              .onChange((val: number) => {
                layer.opacity = val;
                this.editSession.invalidateMaskCache();
                this.editSession.bumpProcessing();
                ImageProcessor.process(this.editSession);
              });
          }
          .layoutWeight(1)
          .height(24);

          Text((layer.opacity * 100).toFixed(0) + '%')
            .fontSize(10)
            .fontColor(VividNative.textSecondary)
            .width(32)
            .textAlign(TextAlign.End);
        }
        .width('100%');
      }
      .layoutWeight(1)
      .margin({ left: 8 });

      // Mask indicator with the mask type, so masked layers read clearly in
      // the layer list instead of only showing a bare letter.
      if (layer.hasMask()) {
        Row() {
          Text('◐')
            .fontSize(10)
            .fontColor(VividNative.warning);
          Text(this.maskTypeLabel(layer))
            .fontSize(9)
            .fontColor(VividNative.warning)
            .margin({ left: 3 });
        }
        // 蒙版状态胶囊：前景=系统告警色，容器底色=系统告警容器色（低强调）。
        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
        .borderRadius(VividNative.radiusLevel8)
        .backgroundColor(VividNative.warningContainer)
        .margin({ left: 4 });

        // A completed mask remains editable. Keep this action compact so the
        // layer row does not run into the card's rounded edge.
        Button('编辑蒙版')
          .fontSize(9)
          .height(24)
          .padding({ left: 7, right: 7 })
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .margin({ left: 4 })
          .onClick(() => {
            this.editSession.activeLayerIndex = index;
            this.editSession.adjustmentScope = 1;
            layer.migrateMask();
            // Reopen the selected mask layer (or the most recently created
            // one) instead of always jumping to the first linear layer. This
            // keeps a brush layer visible after linear → brush editing.
            const maskLayer = layer.maskLayers.find((item) =>
              item.id === this.editSession.selectedMaskLayerId) ??
              layer.maskLayers[layer.maskLayers.length - 1];
            if (maskLayer) {
              this.editSession.selectedMaskLayerId = maskLayer.id;
              // Reopen the component the user was editing most recently;
              // otherwise a linear component always hid a later brush
              // subtract component when returning from the layer panel.
              const selected = maskLayer.components.find((item: MaskComponent) =>
                item.id === this.editSession.selectedMaskComponentId);
              const component = selected ?? maskLayer.components[maskLayer.components.length - 1];
              if (component) {
                this.editSession.selectedMaskComponentId = component.id;
                if (component.type === MaskComponentType.BRUSH) this.editSession.setActiveTool(ToolType.BRUSH_MASK);
                else if (component.type === MaskComponentType.LINEAR_GRADIENT) this.editSession.setActiveTool(ToolType.LINEAR_MASK);
                else this.editSession.setActiveTool(ToolType.RADIAL_MASK);
              }
            }
            AppStorage.setOrCreate('editorPanelRequest', 1);
            // Re-assert local scope after nested button dispatch so a bubbling layer-row click cannot reset it.
            setTimeout(() => { this.editSession.adjustmentScope = 1; }, 0);
          });
      }

      // Delete button (if more than 1 layer)
      if (this.editSession.layers.length > 1) {
        // 删除动作：原生文本按钮 + ButtonRole.ERROR（系统告警前景色）。
        Button('×')
          .fontSize(16)
          .buttonStyle(ButtonStyleMode.TEXTUAL).role(ButtonRole.ERROR).controlSize(ControlSize.SMALL)
          .width(28)
          .height(28)
          .onClick(() => {
            this.editSession.removeLayer(index);
            ImageProcessor.process(this.editSession);
          });
      }
    }
    .width('calc(100% - 16vp)')
    .margin({ left: 8, right: 8, bottom: 6 })
    .padding({ left: 10, right: 6, top: 6, bottom: 6 })
    .backgroundColor(Color.Transparent)
    .border({ width: 1, color: index === this.editSession.activeLayerIndex ? VividNative.separator : Color.Transparent })
    .borderRadius(VividNative.radiusClicked)
    .onClick(() => {
      this.editSession.activeLayerIndex = index;
      // Selecting a layer opens its global/basic adjustments. A mask is a
      // separate editing context entered through the mask controls, so ordinary
      // layer selection never redirects sliders to the wrong adjustment set.
      this.editSession.adjustmentScope = 0;
    });
  }

  private maskTypeLabel(layer: Layer): string {
    layer.migrateMask();
    const labels: string[] = [];
    for (const maskLayer of layer.maskLayers) {
      for (const component of maskLayer.components) {
        let label = component.type === MaskComponentType.BRUSH ? '画笔蒙版' :
          (component.type === MaskComponentType.LINEAR_GRADIENT ? '线性蒙版' : '径向蒙版');
        if (component.blendMode === MaskBlendMode.SUBTRACT) label += '（减去）';
        else if (component.blendMode === MaskBlendMode.INTERSECT) label += '（相交）';
        if (component.inverted) label += '·反相';
        if (labels.indexOf(label) < 0) labels.push(label);
      }
    }
    return labels.join(' + ');
  }
}



