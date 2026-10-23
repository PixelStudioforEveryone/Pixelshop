import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { CustomLut, LutLibraryStore, loadSampleOverrides, applySampleOverrides } from '../edit/models/LutLibrary';
import { LutLoader } from '../edit/utils/LutLoader';
import { renderLutCardEffect } from '../edit/utils/LutCardPreview';
import { VividNative } from './VividNativeTheme';

/** 效果图底图：示例人像的一张 RGBA 副本，所有 LUT 卡片共用（与「本机 LUT」页同尺寸）。 */
interface LutBaseSample {
  width: number;
  height: number;
  buffer: ArrayBuffer;
}

let baseSample: LutBaseSample | null = null;
/** 用户自定义样图覆盖，只需读一次。 */
let sampleOverrides: Record<string, string> | null = null;
/** lutId → 已渲染的效果图。 */
const lutEffectCache: Map<string, image.PixelMap> = new Map();

async function loadBaseSample(context: common.UIAbilityContext): Promise<LutBaseSample | null> {
  if (baseSample !== null) return baseSample;
  try {
    const bytes = await context.resourceManager.getMediaContent($r('app.media.lut_sample_portrait'));
    const source = image.createImageSource(bytes.buffer as ArrayBuffer);
    if (source === undefined) return null;
    const info = await source.getImageInfo();
    const scale = Math.min(1, 640 / Math.max(info.size.width, info.size.height));
    const width = Math.max(1, Math.round(info.size.width * scale));
    const height = Math.max(1, Math.round(info.size.height * scale));
    const map = await source.createPixelMap({
      editable: true,
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      desiredSize: { width: width, height: height },
    });
    await source.release();
    const buffer = new ArrayBuffer(width * height * 4);
    await map.readPixelsToBuffer(buffer);
    await map.release();
    baseSample = { width: width, height: height, buffer: buffer };
    return baseSample;
  } catch (_error) {
    return null;
  }
}

async function ensureSampleOverrides(context: common.UIAbilityContext): Promise<void> {
  if (sampleOverrides !== null) return;
  try {
    sampleOverrides = await loadSampleOverrides(context);
  } catch (_error) {
    sampleOverrides = {};
  }
}

/**
 * LUT 卡片的「本机 LUT 页面同款」效果图。
 *
 * 走的是和本机 LUT 页完全相同的管线与磁盘缓存（filesDir/<样图>_<LUT>_hq.jpg），
 * 同一张 LUT 在两处显示的永远是同一张图。结果放在组件自己的 @State 里——
 * ForEach 会按 key 复用卡片，父组件刷新不会重建子卡片。
 */
@Component
export struct LutEffectThumb {
  @Prop lutId: string = '';
  @State private pixelMap: image.PixelMap | undefined = undefined;
  @State private done: boolean = false;

  aboutToAppear(): void {
    this.loadEffect();
  }

  private async loadEffect(): Promise<void> {
    if (this.lutId.length === 0) return;
    const cached = lutEffectCache.get(this.lutId);
    if (cached !== undefined) {
      this.pixelMap = cached;
      this.done = true;
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (context === undefined) return;
    const entry = LutLibraryStore.find(this.lutId);
    if (entry === undefined) {
      this.done = true;
      return;
    }
    let usable: CustomLut = entry;
    if (entry.table === null || entry.table === undefined) {
      const loaded = await LutLoader.load(context.resourceManager, entry);
      if (loaded === null) {
        this.done = true;
        return;
      }
      usable = loaded;
    }
    await ensureSampleOverrides(context);
    applySampleOverrides([usable], sampleOverrides ?? {});
    const base = await loadBaseSample(context);
    if (base === null) {
      this.done = true;
      return;
    }
    const map = await renderLutCardEffect(context, usable, new Uint8ClampedArray(base.buffer.slice(0)),
      base.width, base.height);
    if (map !== null) {
      if (!lutEffectCache.has(this.lutId)) lutEffectCache.set(this.lutId, map);
      this.pixelMap = map;
    }
    this.done = true;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pixelMap !== undefined) {
        Image(this.pixelMap as image.PixelMap)
          .width('100%').height('100%').objectFit(ImageFit.Cover);
      } else {
        Row().width('100%').height('100%').backgroundColor(VividNative.componentNormal);
        if (!this.done) {
          LoadingProgress().width(16).height(16).color(VividNative.textSecondary);
        }
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None);
  }
}
