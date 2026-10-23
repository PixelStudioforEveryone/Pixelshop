import { EditSession } from '../edit/models/EditSession';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { SliderControl } from './SliderControl';
import { PointColorPanel } from './PointColorPanel';
import { DisclosureChevron } from './DisclosureChevron';
import { ColorMath } from '../edit/utils/ColorMath';
import { VividMaterial } from './VividMaterial';
import { VividNative } from './VividNativeTheme';
import { isDevelopSectionVisible } from '../edit/models/DevelopSections';

interface MixerColor {
  name: string;
  color: string;
}

const MIXER_COLORS: MixerColor[] = [
  { name: '红', color: '#E65462' }, { name: '橙', color: '#EE8A43' },
  { name: '黄', color: '#DDBB3F' }, { name: '绿', color: '#45A86C' },
  { name: '青', color: '#3AAAB2' }, { name: '蓝', color: '#4B75DF' },
  { name: '紫', color: '#825EC9' }, { name: '洋红', color: '#C554A6' },
];

@Component
export struct ColorMixerControl {
  @Consume('editSession') editSession: EditSession;
  @Prop maskContext: boolean = false;
  @Prop embedded: boolean = false;
  @Prop externalScroll: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @State private selectedColor: number = 0;
  @State private pointColorExpanded: boolean = true;
  private processTimer: number = -1;
  private processPending: boolean = false;

  build() {
    Column() {
      // 八个色相项按屏幕宽度等分（每项 layoutWeight(1)），不再放进横向 Scroll：
      // 窄屏下横向滚动只是把溢出藏起来，最后一项仍会落在屏幕外，而且间距不可控。
      this.ColorSelector();

      if (this.editSession.activeLayer) {
        SliderControl({
          label: '色相', min: -1, max: 1, step: 0.01,
          value: this.editSession.adjustmentsForContext(this.maskContext)?.getMixValue(this.selectedColor, 0) ?? 0,
          formatValue: (value: number) => value.toFixed(2),
          gradientType: 'custom',
          gradientStart: this.mixerGradient(0)[0],
          gradientMid: this.mixerGradient(0)[1],
          gradientEnd: this.mixerGradient(0)[2],
          whiteAnchor: true,
          onBegin: () => { this.editSession.pushUndo(); },
          onChange: (value: number) => { this.setValue(0, value); },
        });
        SliderControl({
          label: '饱和度', min: -1, max: 1, step: 0.01,
          value: this.editSession.adjustmentsForContext(this.maskContext)?.getMixValue(this.selectedColor, 1) ?? 0,
          formatValue: (value: number) => value.toFixed(2),
          gradientType: 'custom',
          gradientStart: this.mixerGradient(1)[0],
          gradientMid: this.mixerGradient(1)[1],
          gradientEnd: this.mixerGradient(1)[2],
          whiteAnchor: true,
          onBegin: () => { this.editSession.pushUndo(); },
          onChange: (value: number) => { this.setValue(1, value); },
        });
        SliderControl({
          label: '明亮度', min: -1, max: 1, step: 0.01,
          value: this.editSession.adjustmentsForContext(this.maskContext)?.getMixValue(this.selectedColor, 2) ?? 0,
          formatValue: (value: number) => value.toFixed(2),
          gradientType: 'custom',
          gradientStart: this.mixerGradient(2)[0],
          gradientMid: this.mixerGradient(2)[1],
          gradientEnd: this.mixerGradient(2)[2],
          whiteAnchor: true,
          onBegin: () => { this.editSession.pushUndo(); },
          onChange: (value: number) => { this.setValue(2, value); },
        });
      }

      // 点颜色已从独立分区并入混色器。它仍是整帧阶段，因此复用
      // DevelopSections 的整帧可见性规则：蒙版上下文不挂载、不泄漏。
      if (isDevelopSectionVisible('point-color', this.maskContext)) {
        this.PointColorSection();
      }
    }
    .width('100%')
    .height(this.externalScroll ? 'auto' : (this.embedded ? 250 : '100%'))
    .padding({ top: 8 })
    .attributeModifier(VividMaterial.card);
  }

  @Builder
  private ColorSelector() {
    Row() {
      ForEach(MIXER_COLORS, (item: MixerColor, index: number) => {
        Column() {
          // 色相环保持彩色（调色语义），只有“选中描边”换成系统主题强调色。
          Circle()
            .width(24)
            .height(24)
            .fill(item.color)
            .stroke(this.selectedColor === index ? VividNative.emphasize : VividNative.componentNormal)
            .strokeWidth(this.selectedColor === index ? 2.5 : 1);
          Text(item.name)
            .fontSize(9)
            // 窄屏等分后单项宽度有限：锁定单行，避免“洋红”折行把整行撑高。
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .fontColor(this.selectedColor === index ? VividNative.textPrimary : VividNative.textSecondary)
            .margin({ top: 3 });
        }
        // 等分屏幕宽度：八项各占 1/8，最右侧一项不会再被挤出屏幕。
        .layoutWeight(1)
        .focusable(true)
        .focusBox(VividNative.focusBox())
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => { this.selectedColor = index; });
      }, (item: MixerColor) => item.name);
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceEvenly)
    .padding({ left: 6, right: 6, top: 10, bottom: 4 });
  }

  @Builder
  private PointColorSection() {
    Column() {
      Divider()
        .strokeWidth(1)
        .color(VividNative.divider)
        .margin({ left: 12, right: 12, top: 6, bottom: 2 });
      Row() {
        Text('点颜色')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(VividNative.textPrimary);
        Blank();
        DisclosureChevron({ expanded: this.pointColorExpanded });
      }
      .width('100%')
      .height(34)
      .padding({ left: 14, right: 12 })
      .focusable(true)
      .focusBox(VividNative.focusBox())
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        this.pointColorExpanded = !this.pointColorExpanded;
        // 折叠分区等于离开取色界面：按钮随之消失，必须在这里退出取色，
        // 否则画布会继续吞掉下一次点按。
        if (!this.pointColorExpanded) this.editSession.cancelPointColorPick();
      });
      if (this.pointColorExpanded) {
        // nested: PointColorPanel 只保留取样计数与添加/清除按钮，标题由上面的
        // 可折叠分区头提供，避免同一个“点颜色”出现两次。
        PointColorPanel({ nested: true });
      }
    }
    .width('100%');
  }

  private setValue(axis: number, value: number): void {
    const layer = this.editSession.activeLayer;
    if (!layer) return;
    const adjustments = this.editSession.adjustmentsForContext(this.maskContext);
    if (!adjustments) return;
    adjustments.setMixValue(this.selectedColor, axis, value);
    this.editSession.requestProcessing();
    // Throttle instead of debounce so the preview follows the drag live;
    // stale pipeline runs abort themselves via processingRequestVersion.
    if (this.processPending) return;
    this.processPending = true;
    this.processTimer = setTimeout(() => {
      this.processPending = false;
      this.processTimer = -1;
      ImageProcessor.process(this.editSession);
    }, 33);
  }

  /** Gradient stops mirroring what the axis actually does to the selected colour. */
  private mixerGradient(axis: number): string[] {
    const base = MIXER_COLORS[this.selectedColor].color;
    if (axis === 0) {
      // Hue shifts ±24°, exactly like the pipeline's mixHue range.
      return [ColorMath.shiftHue(base, -24), base, ColorMath.shiftHue(base, 24)];
    }
    if (axis === 1) {
      return [ColorMath.scaleSaturation(base, 0.12), base, ColorMath.scaleSaturation(base, 1.55)];
    }
    return [ColorMath.scaleLightness(base, 0.45), base, ColorMath.scaleLightness(base, 1.55)];
  }
}

