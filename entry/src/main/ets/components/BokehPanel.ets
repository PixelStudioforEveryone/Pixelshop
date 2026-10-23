import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { EditSession } from '../edit/models/EditSession';
import { BokehSettings } from '../edit/models/BokehSettings';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import {
  BokehDepthService, BOKEH_DEPTH_BUSY, BOKEH_DEPTH_STATUS, BOKEH_DEPTH_VERSION,
} from '../edit/engine/BokehDepthService';
import { DesktopRawSlider } from './DesktopRawSlider';
import { VividNative } from './VividNativeTheme';

const BOKEH_REVISION = 'bokehRevision';
const BOKEH_FOCUS_PICKING = 'bokehFocusPicking';

/**
 * 大光圈模拟面板。
 *
 * 作为「调色」页的一个可折叠分区，排在「校准」之后；分区头、折叠箭头和
 * 重置按钮都由 DesktopDevelopPanel 提供。内容是文档级阶段，蒙版上下文里
 * 整个分区不出现。
 *
 * 滑杆统一使用 DesktopRawSlider，与「亮」「颜色」等分区共用同一套标签宽度、
 * 轨道起点、数值右对齐和三角锚点，避免出现第二套视觉语言。
 */
@Component
export struct BokehPanel {
  @Consume('editSession') editSession: EditSession;
  @StorageProp('vividNightMode') private night: boolean = false;
  @StorageLink(BOKEH_DEPTH_STATUS) private depthStatus: string = '';
  @StorageLink(BOKEH_DEPTH_BUSY) private depthBusy: boolean = false;
  @StorageLink(BOKEH_DEPTH_VERSION) @Watch('syncDepthPreview') private depthVersion: number = 0;
  @StorageLink(BOKEH_FOCUS_PICKING) private focusPicking: boolean = false;
  @StorageProp(BOKEH_REVISION) @Watch('syncShape') private revision: number = 0;
  @State private showDepth: boolean = false;
  @State private depthPreview: image.PixelMap | null = null;
  @State private shapeIndex: number = 0;
  @State private shapeText: string = '7 边形';
  private processTimer: number = -1;
  private processPending: boolean = false;

  aboutToAppear(): void {
    if (this.depthStatus.length === 0) {
      this.depthStatus = BokehDepthService.statusText(this.editSession);
    }
    this.syncShape();
    if (this.showDepth) this.syncDepthPreview();
    if (this.editSession.bokeh.enabled && !this.editSession.hasBokehDepth()) {
      // 侧车恢复出来的会话没有深度图（它不是持久化字段）；重新生成一次，
      // 在完成前原生阶段用中心对焦顶着。
      setTimeout(() => { this.regenerateDepth(); }, 0);
    }
  }

  aboutToDisappear(): void {
    if (this.processTimer !== -1) clearTimeout(this.processTimer);
    this.processTimer = -1;
    this.setFocusPicking(false);
    this.releaseDepthPreview();
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button(this.editSession.bokeh.enabled ? '大光圈：开' : '大光圈：关')
          .fontSize(12).height(32).layoutWeight(1)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => { this.toggleEnabled(); });
      }.width('100%');

      Text('按深度图虚化背景；高光按模拟光圈形状叠加光斑。默认模型 Depth Anything V2 Small，本地离线运行。')
        .fontSize(11).fontColor(VividNative.textSecondary).width('100%');

      if (this.editSession.bokeh.enabled) {
        DesktopRawSlider({
          label: '模拟光圈大小', controlId: 'bokeh-aperture',
          lower: 1.2, upper: 8, increment: 0.1,
          currentValue: this.editSession.bokeh.aperture,
          displayScale: 1, decimals: 1,
          onBegin: () => { this.editSession.pushUndo(); },
          onUpdate: (value: number) => {
            this.editSession.bokeh.aperture = value;
            this.commit();
          },
        });
        DesktopRawSlider({
          label: '虚化强度', controlId: 'bokeh-blur',
          lower: 0, upper: 100, increment: 1,
          currentValue: Math.round(this.editSession.bokeh.blurStrength * 100),
          displayScale: 1, decimals: 0,
          onBegin: () => { this.editSession.pushUndo(); },
          onUpdate: (value: number) => {
            this.editSession.bokeh.blurStrength = value / 100;
            this.commit();
          },
        });
        DesktopRawSlider({
          label: '光斑强度', controlId: 'bokeh-strength',
          lower: 0, upper: 100, increment: 1,
          currentValue: Math.round(this.editSession.bokeh.bokehStrength * 100),
          displayScale: 1, decimals: 0,
          onBegin: () => { this.editSession.pushUndo(); },
          onUpdate: (value: number) => {
            this.editSession.bokeh.bokehStrength = value / 100;
            this.commit();
          },
        });

        Row({ space: 8 }) {
          Text('光斑形状').fontSize(12).fontColor(VividNative.textPrimary).layoutWeight(1);
          Select(BokehSettings.shapeOptions())
            .selected(this.shapeIndex)
            .value(this.shapeText)
            .height(28)
            .width(126)
            .onSelect((index: number) => {
              this.editSession.pushUndo();
              this.editSession.bokeh.shape = BokehSettings.shapeFromIndex(index);
              this.syncShape();
              this.commit();
            });
        }.width('100%').height(32);

        DesktopRawSlider({
          label: '光斑密度', controlId: 'bokeh-density',
          lower: 0, upper: 100, increment: 1,
          currentValue: Math.round(this.editSession.bokeh.density * 100),
          displayScale: 1, decimals: 0,
          onBegin: () => { this.editSession.pushUndo(); },
          onUpdate: (value: number) => {
            this.editSession.bokeh.density = value / 100;
            this.commit();
          },
        });
        DesktopRawSlider({
          label: '光斑大小', controlId: 'bokeh-size',
          lower: 30, upper: 200, increment: 1,
          currentValue: Math.round(this.editSession.bokeh.size * 100),
          displayScale: 1, decimals: 0,
          onBegin: () => { this.editSession.pushUndo(); },
          onUpdate: (value: number) => {
            this.editSession.bokeh.size = value / 100;
            this.commit();
          },
        });
        DesktopRawSlider({
          label: '球差', controlId: 'bokeh-spherical',
          lower: -100, upper: 100, increment: 1,
          currentValue: Math.round(this.editSession.bokeh.spherical * 100),
          displayScale: 1, decimals: 0,
          onBegin: () => { this.editSession.pushUndo(); },
          onUpdate: (value: number) => {
            this.editSession.bokeh.spherical = value / 100;
            this.commit();
          },
        });

        DesktopRawSlider({
          label: '焦点深度', controlId: 'bokeh-focus',
          lower: 0, upper: 98, increment: 1,
          currentValue: Math.round(this.editSession.bokeh.focus * 100),
          displayScale: 1, decimals: 0,
          onBegin: () => { this.editSession.pushUndo(); },
          onUpdate: (value: number) => {
            this.editSession.bokeh.focus = value / 100;
            this.setFocusPicking(false);
            this.commit();
          },
        });
        Row({ space: 8 }) {
          Button(this.focusPicking ? '点击画面选择主体…' : '点选对焦主体')
            .fontSize(11).height(30).layoutWeight(1)
            .buttonStyle(this.focusPicking ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
            .controlSize(ControlSize.SMALL)
            .enabled(this.editSession.hasBokehDepth() && !this.depthBusy)
            .onClick(() => { this.setFocusPicking(!this.focusPicking); });
        }.width('100%');
        if (this.focusPicking) {
          Text('点击上方预览里的主体，焦点会落在该位置的深度上。')
            .fontSize(10).fontColor(VividNative.emphasize).width('100%');
        }

        Divider().strokeWidth(1).color(VividNative.divider).margin({ top: 2, bottom: 2 });

        Row({ space: 8 }) {
          Text('深度图预览').fontSize(12).fontColor(VividNative.textPrimary).layoutWeight(1);
          Button(this.showDepth ? '隐藏' : '显示').fontSize(11).height(28)
            .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
            .onClick(() => {
              this.showDepth = !this.showDepth;
              if (this.showDepth) this.syncDepthPreview();
              else this.releaseDepthPreview();
            });
        }.width('100%').height(30);

        if (this.showDepth) {
          if (this.depthPreview !== null) {
            Image(this.depthPreview)
              .width('100%')
              .height(112)
              .objectFit(ImageFit.Contain)
              .borderRadius(6);
          } else {
            Row() {
              Text(this.editSession.hasBokehDepth() ? '正在生成预览…' : '尚未生成 AI 深度图：当前使用中心对焦')
                .fontSize(11).fontColor(VividNative.textSecondary);
            }
            .width('100%').height(54)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(VividNative.sliderTrack)
            .borderRadius(6);
          }
        }

        Text(this.depthStatus.length > 0 ? this.depthStatus :
          BokehDepthService.statusText(this.editSession))
          .fontSize(10).fontColor(VividNative.textSecondary).width('100%');

        Row({ space: 8 }) {
          Button(this.depthBusy ? '生成中…' : '重新生成 AI 深度图')
            .fontSize(11).height(30).layoutWeight(1)
            .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .enabled(!this.depthBusy)
            .onClick(() => { this.regenerateDepth(); });
          Button('中心对焦').fontSize(11).height(30)
            .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .onClick(() => { this.useCenterFocus(); });
        }.width('100%').padding({ bottom: 2 });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  private toggleEnabled(): void {
    this.editSession.pushUndo();
    const enabled = !this.editSession.bokeh.enabled;
    this.editSession.bokeh.enabled = enabled;
    if (!enabled) this.setFocusPicking(false);
    if (enabled && !this.editSession.hasBokehDepth()) {
      // 先让中心对焦的近似结果立即可见，AI 深度在后台补上。
      this.editSession.bokeh.focus = Math.min(0.98, Math.max(0.02, this.editSession.bokeh.focus));
      this.regenerateDepth();
    }
    this.commit();
  }

  private regenerateDepth(): void {
    if (this.depthBusy) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      BokehDepthService.generate(context.resourceManager, this.editSession, true);
    } catch (error) {
      this.depthStatus = '无法访问模型资源：继续使用中心对焦';
      console.error('VIVID_BOKEH panel depth request failed: ' + String(error));
    }
  }

  private useCenterFocus(): void {
    this.editSession.pushUndo();
    this.editSession.clearBokehDepth();
    this.editSession.bokeh.focus = 0.45;
    this.setFocusPicking(false);
    this.depthStatus = '中心对焦（未生成 AI 深度图）';
    this.releaseDepthPreview();
    this.commit();
  }

  private setFocusPicking(picking: boolean): void {
    this.focusPicking = picking;
    AppStorage.setOrCreate(BOKEH_FOCUS_PICKING, picking);
  }

  private commit(): void {
    this.editSession.requestProcessing();
    AppStorage.setOrCreate(BOKEH_REVISION, Date.now());
    if (this.processPending) return;
    this.processPending = true;
    this.processTimer = setTimeout(() => {
      this.processPending = false;
      this.processTimer = -1;
      ImageProcessor.process(this.editSession);
    }, 33);
  }

  private syncShape(): void {
    this.shapeIndex = BokehSettings.shapeIndex(this.editSession.bokeh.shape);
    this.shapeText = this.editSession.bokeh.shapeLabel();
  }

  private syncDepthPreview(): void {
    if (!this.showDepth) return;
    const depth = this.editSession.bokehDepth;
    const width = this.editSession.bokehDepthWidth;
    const height = this.editSession.bokehDepthHeight;
    if (!depth || width <= 0 || height <= 0) {
      this.releaseDepthPreview();
      return;
    }
    const buffer = new ArrayBuffer(width * height * 4);
    const rgba = new Uint8Array(buffer);
    for (let index = 0; index < width * height; index++) {
      const value = depth[index];
      const offset = index * 4;
      rgba[offset] = value;
      rgba[offset + 1] = value;
      rgba[offset + 2] = value;
      rgba[offset + 3] = 255;
    }
    const options: image.InitializationOptions = {
      editable: false,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: width, height: height },
    };
    image.createPixelMap(buffer, options).then((pixelMap: image.PixelMap) => {
      this.releaseDepthPreview();
      this.depthPreview = pixelMap;
    }).catch((error: Error) => {
      console.error('VIVID_BOKEH depth preview failed: ' + String(error));
    });
  }

  private releaseDepthPreview(): void {
    if (this.depthPreview !== null) {
      try { this.depthPreview.release(); } catch (_error) { /* already released */ }
      this.depthPreview = null;
    }
  }
}
