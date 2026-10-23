import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { CustomLut } from './LutLibrary';
import { parseNp3, nikonCloudLut } from './NikonNp3';

/**
 * 云创本地一条方案，对应 rawfile/NikonCloud/recipes.json 的一项。
 *
 * thumb 是列表卡片用的小图（长边 720），cover 是详情页用的大图（长边 1080），
 * 都在 rawfile 里随包分发，避免联网与登录态依赖。pictureControl / creator /
 * published 来自官方书页；camera / lens / 快门 / 光圈 / ISO 就绪后补字段即可，
 * 详情页会自动多出这几行。
 */
export interface NikonCloudRecipe {
  id: string;
  name: string;
  creator: string;
  np3: string;
  bytes: number;
  thumb: string;
  cover?: string;
  pictureControl?: string;
  published?: string;
  recipeId?: string;
  camera?: string;
  lens?: string;
  focal?: string;
  shutter?: string;
  aperture?: string;
  iso?: string;
  /** 官方 shooting_information.place / time（需登录 token 才能取到）。 */
  place?: string;
  time?: string;
  /** 优化校准的基准风格（picture_controll_based，如 FLEXIBLE COLOR）。 */
  based?: string;
  /** 相机设置：camera_setting.*（快门/光圈/ISO 在这一层，不在 shooting_information）。 */
  exposureComp?: string;
  whiteBalance?: string;
  /** 创作者写的方案说明（detail 或 outline）与官方分享短链。 */
  description?: string;
  shortUrl?: string;
}

export interface NikonCloudCatalog {
  version?: number;
  bookId?: string;
  items?: NikonCloudRecipe[];
}

/** 云创滤镜包清单在 rawfile 里的路径。 */
export const NIKON_CLOUD_MANIFEST: string = 'NikonCloud/recipes.json';

/** 云创本地滤镜包：清单只读一次，列表与详情页共用同一份缓存。 */
export class NikonCloudStore {
  private static cached: NikonCloudRecipe[] = [];
  private static loaded: boolean = false;
  private static manager: resourceManager.ResourceManager | null = null;
  private static syncLoaded: boolean = false;

  /** The ability context is installed once at startup so a sidecar restore can
   *  synchronously rebuild a cloud LUT without waiting for the presets panel. */
  static attachResourceManager(manager: resourceManager.ResourceManager): void {
    NikonCloudStore.manager = manager;
  }

  static resolveLutSync(id: string, name: string): CustomLut | null {
    const manager = NikonCloudStore.manager;
    if (!manager) return null;
    const recipes = NikonCloudStore.recipesSync(manager);
    const key = id.indexOf('nikon:') === 0 ? id.substring('nikon:'.length) : id;
    const recipe = recipes.find((entry: NikonCloudRecipe): boolean => entry.id === key) ??
      recipes.find((entry: NikonCloudRecipe): boolean => entry.name === name);
    if (!recipe) return null;
    try {
      const raw = manager.getRawFileContentSync(recipe.np3);
      const look = parseNp3(raw);
      return nikonCloudLut(recipe.id, recipe.name, look, 33);
    } catch (_error) {
      return null;
    }
  }

  private static recipesSync(manager: resourceManager.ResourceManager): NikonCloudRecipe[] {
    if (NikonCloudStore.syncLoaded) return NikonCloudStore.cached;
    try {
      const raw = manager.getRawFileContentSync(NIKON_CLOUD_MANIFEST);
      const catalog = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(raw)) as NikonCloudCatalog;
      NikonCloudStore.cached = catalog.items !== undefined ? catalog.items : [];
    } catch (_error) {
      NikonCloudStore.cached = [];
    }
    NikonCloudStore.syncLoaded = true;
    return NikonCloudStore.cached;
  }

  static async load(context: common.UIAbilityContext): Promise<NikonCloudRecipe[]> {
    NikonCloudStore.attachResourceManager(context.resourceManager);
    if (NikonCloudStore.loaded) return NikonCloudStore.cached;
    try {
      const decoder = util.TextDecoder.create('utf-8');
      const catalog = JSON.parse(decoder.decodeToString(
        await context.resourceManager.getRawFileContent(NIKON_CLOUD_MANIFEST))) as NikonCloudCatalog;
      NikonCloudStore.cached = catalog.items !== undefined ? catalog.items : [];
      NikonCloudStore.loaded = true;
    } catch (_error) {
      // 清单缺失时保持空列表，让界面走空状态而不是崩溃。
      NikonCloudStore.cached = [];
    }
    return NikonCloudStore.cached;
  }

  static find(id: string): NikonCloudRecipe | undefined {
    return NikonCloudStore.cached.find((item: NikonCloudRecipe): boolean => item.id === id);
  }
}

/**
 * 云创效果图解码缓存。
 *
 * 真机上 `Image($rawfile(变量路径))` 拿不到包内图片（列表与详情都显示占位），
 * 所以统一改成：resourceManager 读 rawfile 字节 → image 解码 PixelMap →
 * 按路径缓存（超出上限先进先出释放）。列表靠 onVisibleAreaChange 懒加载，
 * 避免一次解码上百张大图。
 */
export class NikonCloudImages {
  private static cache: Map<string, image.PixelMap> = new Map();
  private static order: string[] = [];
  private static limit: number = 30;
  /** 弹层里一行两张的小图：降采样解码，108 张也能常驻。 */
  private static smallCache: Map<string, image.PixelMap> = new Map();

  static cached(path: string): image.PixelMap | undefined {
    return NikonCloudImages.cache.get(path);
  }

  static cachedSmall(path: string): image.PixelMap | undefined {
    return NikonCloudImages.smallCache.get(path);
  }

  /** 小图（长边 360），用于预设选择弹层。硬件 JPEG 解码器不支持 sampleSize，只能给 desiredSize。 */
  static async loadSmall(context: common.UIAbilityContext, path: string): Promise<image.PixelMap | null> {
    const hit = NikonCloudImages.smallCache.get(path);
    if (hit !== undefined) return hit;
    try {
      const raw = await context.resourceManager.getRawFileContent(path);
      const source = image.createImageSource(raw.buffer as ArrayBuffer);
      if (source === undefined) return null;
      const info = await source.getImageInfo();
      const width = info.size.width;
      const height = info.size.height;
      const longSide = Math.max(width, height);
      const scale = longSide > 0 ? 360 / longSide : 1;
      const targetWidth = Math.max(1, Math.round(width * (scale < 1 ? scale : 1)));
      const targetHeight = Math.max(1, Math.round(height * (scale < 1 ? scale : 1)));
      const pixelMap = await source.createPixelMap({
        desiredSize: { width: targetWidth, height: targetHeight },
      });
      await source.release();
      NikonCloudImages.smallCache.set(path, pixelMap);
      return pixelMap;
    } catch (_error) {
      return null;
    }
  }

  static async load(context: common.UIAbilityContext, path: string): Promise<image.PixelMap | null> {
    const hit = NikonCloudImages.cache.get(path);
    if (hit !== undefined) return hit;
    try {
      const raw = await context.resourceManager.getRawFileContent(path);
      const source = image.createImageSource(raw.buffer as ArrayBuffer);
      if (source === undefined) return null;
      const pixelMap = await source.createPixelMap();
      await source.release();
      NikonCloudImages.cache.set(path, pixelMap);
      NikonCloudImages.order.push(path);
      while (NikonCloudImages.order.length > NikonCloudImages.limit) {
        const oldest = NikonCloudImages.order.shift();
        if (oldest === undefined) continue;
        const evicted = NikonCloudImages.cache.get(oldest);
        if (evicted === undefined) continue;
        NikonCloudImages.cache.delete(oldest);
        await evicted.release();
      }
      return pixelMap;
    } catch (_error) {
      return null;
    }
  }
}
