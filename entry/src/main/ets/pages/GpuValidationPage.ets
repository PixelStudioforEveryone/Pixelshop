import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EditSession } from '../edit/models/EditSession';
import { Layer } from '../edit/models/Layer';
import { MaskLayer, MaskComponent, MaskComponentType } from '../edit/models/Mask';
import { LutTable, CustomLut, LutStackItem } from '../edit/models/LutLibrary';
import { GpuShaderBridge } from '../edit/engine/GpuShaderBridge';
import { ImageProcessor } from '../edit/engine/ImageProcessor';

/** Explicit developer-only entry via aa --ps vividGpuSelfTest 1. No user assets. */
@Entry
@Component
struct GpuValidationPage {
  @State status: string = 'GPU validation running';
  private controller: XComponentController = new XComponentController();
  private session: EditSession = new EditSession();
  private source: image.PixelMap | null = null;

  private lut(id: string, size: number, amount: number): LutStackItem {
    const values: number[] = [];
    for (let b = 0; b < size; b++) for (let g = 0; g < size; g++) for (let r = 0; r < size; r++) {
      values.push(Math.pow(r / (size - 1), amount), Math.pow(g / (size - 1), amount), Math.pow(b / (size - 1), amount));
    }
    const table: LutTable = { size: size, values: values, domainMin: [0, 0, 0], domainMax: [1, 1, 1] };
    const lut: CustomLut = { id: id, name: id, sourceUri: '', sampleCount: size ** 3, adjustments: {}, table: table };
    return { id: id, lutId: id, name: id, sourceUri: '', enabled: true, intensity: 0.65, lut: lut };
  }

  private async validate(surface: string): Promise<void> {
    try {
      const w = 64, h = 48;
      const bytes = new Uint8Array(w * h * 4);
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const i = (y * w + x) * 4;
        bytes[i] = Math.round(x * 255 / (w - 1)); bytes[i + 1] = Math.round(y * 255 / (h - 1));
        bytes[i + 2] = (x * 11 + y * 7) % 256; bytes[i + 3] = 255;
      }
      this.source = await image.createPixelMap(new ArrayBuffer(w * h * 4),
        { size: { width: w, height: h }, pixelFormat: image.PixelMapFormat.RGBA_8888, editable: true });
      await this.source.writeBufferToPixels(bytes.buffer as ArrayBuffer);
      let failures = 0;
      for (const test of [0, 1, 2, 3, 4, 5, 6, 7]) {
        this.session.layers = [new Layer('test')];
        this.session.lutStack = [];
        if (test === 1) this.session.lutStack = [this.lut('identity', 33, 1)];
        if (test === 2) {
          this.session.lutStack = [this.lut('lift', 17, 0.9), this.lut('dark', 33, 1.2)];
          this.session.layers[0].adjustments.mixHue[2] = 0.15;
          this.session.layers[0].adjustments.toneCurve = 0.3;
          this.session.layers[0].adjustments.exposure = 0.25;
        }
        if (test === 3) {
          const mask = new MaskLayer('gradient');
          mask.components = [new MaskComponent(MaskComponentType.LINEAR_GRADIENT)];
          mask.adjustments.exposure = 0.4; mask.opacity = 0.6;
          this.session.layers[0].maskLayers = [mask];
        }
        if (test === 4) {
          const layer = new Layer('second'); layer.opacity = 0.4; layer.adjustments.saturation = -0.3;
          this.session.layers.push(layer);
        }
        if (test === 5 || test === 7) {
          const a = this.session.layers[0].adjustments;
          a.highlights = -0.45; a.shadows = 0.4; a.whites = 0.15; a.blacks = -0.2;
          a.temperature = 0.35; a.tint = -0.25; a.vibrance = 0.4;
          a.calibrationRedHue = 0.2; a.calibrationBlueSaturation = -0.25;
        }
        if (test === 6 || test === 7) {
          const a = this.session.layers[0].adjustments;
          a.mixHue = [0.1, -0.15, 0.3, -0.1, 0.2, 0, -0.2, 0.1];
          a.mixSaturation = [0.3, -0.2, 0.1, 0, -0.1, 0.2, -0.3, 0.1];
          a.gradingShadowsHue = 215; a.gradingShadowsSaturation = 0.12;
          a.gradingHighlightsHue = 40; a.gradingHighlightsSaturation = 0.08;
        }
        if (test === 7) this.session.lutStack = [this.lut('lift', 17, 0.9), this.lut('dark', 33, 1.2)];
        // Both backends must consume identical input bytes: the PixelMap
        // roundtrip (createPixelMap → readPixelsToBuffer) reorders channels
        // on some platforms, which would poison the reference. The override
        // keeps cacheSource=false so the CPU worker path stays engaged.
        const cpu = await ImageProcessor.renderToBuffer(this.source, w, h, this.session, true,
          () => false, false, bytes.buffer as ArrayBuffer, true);
        const gpu = await GpuShaderBridge.renderPreview(bytes.buffer as ArrayBuffer, w, h, this.session);
        if (!cpu || !gpu) throw new Error('backend unavailable for case ' + test);
        const actual = new Uint8Array(gpu);
        let max = 0, sum = 0;
        for (let i = 0; i < actual.length; i++) { const error = Math.abs(actual[i] - cpu.pixels[i]); max = Math.max(max, error); sum += error; }
        const mean = sum / actual.length;
        const ok = max <= (test < 2 ? 2 : 8) && mean <= 1.5;
        if (!ok) failures++;
        // 采样像素对照：TL(0,0)=(0,0,0) TR(63,0)=(255,0,181) BL(0,47)=(0,255,73)
        // BR(63,47)=(255,255,254) CTR(32,24)=(129,130,8)，用于定位是哪一侧
        // 以及应用了哪种几何/通道变换。
        const pick = (px: Uint8ClampedArray | Uint8Array, x: number, y: number): string =>
          `(${x},${y})=[${px[(y * w + x) * 4]},${px[(y * w + x) * 4 + 1]},${px[(y * w + x) * 4 + 2]}]`;
        hilog.info(0, 'VIVID_GPU_TEST', '%{public}s',
          `case=${test} max=${max} mean=${mean.toFixed(3)} pass=${ok} ` +
          `cpuTL=${pick(cpu.pixels, 0, 0)} cpuTR=${pick(cpu.pixels, w - 1, 0)} ` +
          `cpuBL=${pick(cpu.pixels, 0, h - 1)} cpuBR=${pick(cpu.pixels, w - 1, h - 1)} ` +
          `gpuTL=${pick(actual, 0, 0)} gpuTR=${pick(actual, w - 1, 0)} ` +
          `gpuBL=${pick(actual, 0, h - 1)} gpuBR=${pick(actual, w - 1, h - 1)} ` +
          `cpuC=${pick(cpu.pixels, (w / 2) | 0, (h / 2) | 0)} gpuC=${pick(actual, (w / 2) | 0, (h / 2) | 0)}`);
      }
      // The direct-display check uses a distinctive red/top, blue/bottom
      // image, then updates parameters without supplying another source.
      this.session.layers = [new Layer('display')]; this.session.lutStack = [];
      const pattern = new Uint8Array(w * h * 4);
      for (let i = 0; i < w * h; i++) { pattern[i * 4] = i < w * h / 2 ? 255 : 0; pattern[i * 4 + 2] = i < w * h / 2 ? 0 : 255; pattern[i * 4 + 3] = 255; }
      const first = await GpuShaderBridge.present(this.session, this.session, this.source, pattern.buffer as ArrayBuffer, w, h, surface);
      const second = await GpuShaderBridge.present(this.session, this.session, this.source, null, w, h, surface);
      if (!first || !second) failures++;
      this.status = failures === 0 ? 'PASS: GPU CPU parity + resident surface' : 'FAIL: ' + failures;
      hilog.info(0, 'VIVID_GPU_TEST', '%{public}s', this.status);
    } catch (error) {
      this.status = 'FAIL: ' + String(error);
      hilog.error(0, 'VIVID_GPU_TEST', '%{public}s', this.status);
    }
  }
  aboutToDisappear(): void { GpuShaderBridge.release(this.session); if (this.source) this.source.release(); }
  build() {
    Column() {
      Text(this.status).fontSize(16).fontColor('#FFFFFF').margin({ top: 50, bottom: 20 });
      XComponent({ id: 'gpu-validation', type: XComponentType.SURFACE, controller: this.controller })
        .width(256).height(192)
        .onLoad(() => { this.validate(this.controller.getXComponentSurfaceId()); });
    }.width('100%').height('100%').backgroundColor('#000000');
  }
}
