import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { zlib } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CustomLut, LutLibraryStore, parseLutText, readLutText } from './LutLibrary';
import { LutBridge } from '../../pages/home/HomeShared';

/** Lumix Lab 社区 LUT 服务的域名与接口前缀（抓包还原，无需鉴权头）。 */
export const LUMIX_CDN_BASE: string = 'https://lumix-base.jpn.panasonic.com';
const LUMIX_API_BASE: string = 'https://lumix-base.jpn.panasonic.com/lutapi/v2';

/** 社区 LUT 摘要：列表、榜单与轮播共用。 */
export interface LumixLutSummary {
  code: string;
  title: string;
  downloads: number;
  genre: string;
  creatorCode: string;
  creatorName: string;
  creatorIconPath: string;
  thumbPath: string;
  thumbOriginalPath: string;
}

/** 今日制作者（creator pickup）。 */
export interface LumixFeaturedCreator {
  code: string;
  name: string;
  url: string;
  introduction: string;
  iconPath: string;
  thumbPath: string;
  thumbOriginalPath: string;
}

/** 区域榜单第 1 名的缩略信息（分区卡封面）。 */
export interface LumixRegionTop {
  region: string;
  thumbPath: string;
  thumbOriginalPath: string;
}

/** 视频LUT / 照片LUT 分区。 */
export interface LumixGenre {
  code: string;
  thumbPath: string;
  tops: LumixRegionTop[];
}

/** 社区 LUT 详情：overview / 文件名 / 下载量齐备。 */
export interface LumixLutDetail {
  code: string;
  title: string;
  overview: string;
  photoStyle: string;
  downloads: number;
  fileGrid33: string;
  fileGrid17: string;
  creatorCode: string;
  creatorName: string;
  creatorIconPath: string;
  thumbPath: string;
  thumbOriginalPath: string;
}

/** 列表页数据：items 为条目，offline 表示是否来自内置目录兜底。 */
export interface LumixLutListResult {
  items: LumixLutSummary[];
  offline: boolean;
}

/** CDN 图片完整地址。 */
export function lumixImageUrl(path: string): string {
  return LUMIX_CDN_BASE + path;
}

/** photo_style 代码 → 中文名（对齐 Lumix Lab 内置表）。 */
const PHOTO_STYLE_NAMES: Record<string, string> = {
  'STD': '标准',
  'VIVD': '生动',
  'NAT': '自然',
  'FLAT': '平直',
  'LAND': '风景画',
  'PORT': '肖像',
  'MONO': '单色',
  'LMONO': 'L.单色',
  'LMONOD': 'L.单色 D',
  'LMONOS': 'L.单色 S',
  'LEICAMONO': 'LEICA单色',
  'LCLAS': 'L.经典',
  'LCLASN': 'L.新经典',
  'LCLASG': 'L.经典 Gold',
  'CNEA2': '影院级 A2',
  'CNED2': '电影模式动态范围2',
  'CNEV2': '电影模式视频2',
  'VLOG': 'V-Log',
  '709L': 'Like709',
  'HLG': 'HLG',
  'STDHLG': '标准(HLG)',
  'MONOHLG': '单色(HLG)',
};

/** photo_style 代码 → 面向用户的格调说明。 */
const PHOTO_STYLE_DESCRIPTIONS: Record<string, string> = {
  'STD': '通用标准影调，各类场景色彩均衡、层次自然，适用性最广。',
  'VIVD': '鲜艳饱和的色彩与明快对比，适合强调色彩张力的直接出片。',
  'NAT': '接近肉眼所见的自然色调，真实还原色彩与明暗过渡。',
  'FLAT': '低对比、低饱和的平直影调，为后期调色保留最大的调整空间。',
  'LAND': '针对风光场景优化，强化蓝天与绿植的层次与通透感。',
  'PORT': '柔化肤色过渡，使人像肤质呈现细腻自然的观感。',
  'MONO': '经典黑白影调，剥离色彩后突出光影与画面结构。',
  'LMONO': '徕卡风格单色影调，深浅层次丰富，质感厚重。',
  'LMONOD': '徕卡风格单色影调（深），对比更深沉，黑白对比强烈。',
  'LMONOS': '徕卡风格单色影调（柔），影调柔和，灰阶过渡平滑。',
  'LEICAMONO': 'LEICA 单色影调，徕卡色彩科学下的黑白表现。',
  'LCLAS': '徕卡经典影调，色彩凝练、氛围沉稳。',
  'LCLASN': '徕卡新经典影调，在经典基调上更显通透与立体。',
  'LCLASG': '徕卡经典 Gold 影调，暖调氛围与温润的高光表现。',
  'CNEA2': '电影模式影院级 A2，模拟影院胶片的对比与色调。',
  'CNED2': '电影模式动态范围2，保留高光与暗部细节的宽动态影调。',
  'CNEV2': '电影模式视频2，面向视频拍摄的电影感影调。',
  'VLOG': 'V-Log 宽动态曲线，保留 12 档以上动态范围，后期空间最大。',
  '709L': 'Like709 标准 BT.709 伽马，拍摄即可直接使用，无需后期。',
  'HLG': 'HLG 高动态范围曲线，适配 HDR 显示与广播级输出。',
  'STDHLG': 'HLG 模式下的标准影调，兼顾 HDR 输出与通用观感。',
  'MONOHLG': 'HLG 模式下的单色影调，黑白画面下的高动态表现。',
};

/** photo_style 代码 → 展示名（未知代码原样返回）。 */
export function lumixPhotoStyleName(code: string): string {
  return PHOTO_STYLE_NAMES[code] ?? code;
}

/** photo_style 代码 → 说明文字（未知代码给通用描述）。 */
export function lumixPhotoStyleDescription(code: string): string {
  return PHOTO_STYLE_DESCRIPTIONS[code] ?? 'Lumix 官方为此 LUT 指定的基础照片格调。';
}

/** 官方目录全量索引：items 为可检索条目，offline 表示来自内置快照。 */
export interface LumixLutIndex {
  items: LumixLutSummary[];
  offline: boolean;
}

/** 检索排序用的中间结构（等级越小越靠前）。 */
interface RankedLut {
  item: LumixLutSummary;
  rank: number;
}

/** 官网名称归一化：小写并去掉空白，名称里的空格与大小写不参与匹配。 */
export function lumixNormalizeName(value: string): string {
  return value.toLowerCase().replace(/\s+/g, '');
}

/**
 * 官网名称匹配等级：0 完全同名 → 1 前缀 → 2 包含 → 3 制作者名 → 4 目录编码，
 * -1 表示不匹配。名称优先，所以「Daydream」不会被人气更高的制作者作品挤掉。
 */
export function lumixNameMatchRank(item: LumixLutSummary, keyword: string): number {
  const query = lumixNormalizeName(keyword);
  if (query.length === 0) return -1;
  const title = lumixNormalizeName(item.title);
  if (title.length > 0) {
    if (title === query) return 0;
    if (title.indexOf(query) === 0) return 1;
    if (title.indexOf(query) > 0) return 2;
  }
  if (lumixNormalizeName(item.creatorName).indexOf(query) >= 0) return 3;
  if (item.code.toLowerCase().indexOf(query) >= 0) return 4;
  return -1;
}

/**
 * 在官方目录里按官网名称检索：先按匹配等级、再按下载量降序，返回全部命中
 * 条目（目录只有数百条，交给调用方按需截断）。
 */
export function lumixSearchByName(pool: LumixLutSummary[], keyword: string): LumixLutSummary[] {
  const query = keyword.trim();
  if (query.length === 0) return [];
  const ranked: RankedLut[] = [];
  for (const item of pool) {
    const rank = lumixNameMatchRank(item, query);
    if (rank >= 0) ranked.push({ item: item, rank: rank });
  }
  ranked.sort((left: RankedLut, right: RankedLut): number => {
    if (left.rank !== right.rank) return left.rank - right.rank;
    return right.item.downloads - left.item.downloads;
  });
  const items: LumixLutSummary[] = [];
  for (const entry of ranked) items.push(entry.item);
  return items;
}

/** 原始 JSON 形状（抓包还原）。 */
interface RawLumixThumb {
  path?: string;
  path_original?: string;
}

interface RawLumixCreator {
  code?: string;
  name?: string;
  icon?: RawLumixThumb;
}

interface RawLumixFilterItem {
  code?: string;
  title?: string;
  download_number?: number;
  creator?: RawLumixCreator;
  thumbnail?: RawLumixThumb;
}

interface RawLumixFilterResp {
  filter?: RawLumixFilterItem[];
}

interface RawLumixTopResp {
  top?: RawLumixFilterItem[];
}

interface RawLumixCreatorResp {
  code?: string;
  name?: string;
  url?: string;
  introduction?: string;
  icon?: RawLumixThumb;
  lut_thumbnail?: RawLumixThumb;
}

interface RawLumixRegionTopItem {
  region?: string;
  thumbnail?: RawLumixThumb;
}

interface RawLumixGenreItem {
  code?: string;
  thumbnail?: RawLumixThumb;
  top?: RawLumixRegionTopItem[];
}

interface RawLumixGenresResp {
  genres?: RawLumixGenreItem[];
}

interface RawLumixFile {
  grid33?: string;
  grid17?: string;
}

interface RawLumixDetailResp {
  code?: string;
  title?: string;
  overview?: string;
  photo_style?: string;
  download_number?: number;
  file?: RawLumixFile;
  creator?: RawLumixCreator;
  thumbnail?: RawLumixThumb;
}

/** 内置目录 rawfile（lumix_community_catalog.json）形状。 */
interface EmbeddedLutItem {
  c: string;
  t: string;
  d: number;
  g: string;
  cc: string;
  cn: string;
  ci: string;
  tp: string;
  to: string;
}

interface EmbeddedRegionTop {
  r: string;
  tp: string;
  to: string;
}

interface EmbeddedGenre {
  c: string;
  tp: string;
  tops: EmbeddedRegionTop[];
}

interface EmbeddedFeatured {
  c: string;
  n: string;
  u: string;
  i: string;
  ic: string;
  tp: string;
  to: string;
}

interface EmbeddedCatalog {
  v: number;
  fetchedAt: string;
  newCodes: string[];
  genres: EmbeddedGenre[];
  featured: EmbeddedFeatured;
  luts: EmbeddedLutItem[];
}

/** 请求体形状（与抓包逐字一致）。 */
interface FilterRequestBody {
  language: string;
  limit: string;
  offset: string;
  order?: Record<string, string>;
  genre_code?: string;
  creator_code?: string;
}

interface TopRequestBody {
  genre_code: string;
  language: string;
  limit: number;
  region: string;
}

interface LutRequestBody {
  code: string;
  language: string;
}

interface CreatorRequestBody {
  code: string;
  language: string;
}

interface DownloadRequestBody {
  code: string;
  key?: string;
}

function textOf(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

function numberOrZero(value: number | undefined): number {
  return typeof value === 'number' && isFinite(value) ? value : 0;
}

function summaryFromFilterItem(item: RawLumixFilterItem, fallbackGenre: string): LumixLutSummary | null {
  const code = textOf(item.code);
  if (code.length === 0) return null;
  return {
    code: code,
    title: textOf(item.title),
    downloads: numberOrZero(item.download_number),
    genre: fallbackGenre,
    creatorCode: item.creator ? textOf(item.creator.code) : '',
    creatorName: item.creator ? textOf(item.creator.name) : '',
    creatorIconPath: item.creator && item.creator.icon ? textOf(item.creator.icon.path) : '',
    thumbPath: item.thumbnail ? textOf(item.thumbnail.path) : '',
    thumbOriginalPath: item.thumbnail ? textOf(item.thumbnail.path_original) : '',
  };
}

/** Lumix Lab 社区接口客户端：请求形状与抓包逐字一致。 */
export class LumixCommunityApi {
  private static async post(path: string, body: string, accept: string,
    expect: http.HttpDataType, readTimeout: number): Promise<string | ArrayBuffer> {
    const client = http.createHttp();
    try {
      const response = await client.request(LUMIX_API_BASE + path, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Accept': accept,
          'User-Agent': 'okhttp/4.12.0',
          // Lumix Lab 官方客户端必备头（反编译 p107j6/e.java 确认），
          // 缺失时服务器一律回 400/403。
          'lutapp-api-key': '111',
        },
        extraData: body,
        expectDataType: expect,
        connectTimeout: 8000,
        readTimeout: readTimeout,
      });
      if (response.responseCode !== 200) {
        let bodySnippet = '';
        try {
          const failResult = response.result;
          if (typeof failResult === 'string') {
            bodySnippet = failResult.substring(0, 500);
          } else if (failResult instanceof ArrayBuffer) {
            bodySnippet = new util.TextDecoder('utf-8')
              .decodeToString(new Uint8Array(failResult).slice(0, 500));
          }
        } catch (_decodeError) {
        }
        hilog.error(0x0000, 'LumixApi', 'POST %{public}s -> %{public}d body=%{public}s',
          path, response.responseCode, bodySnippet);
        if (response.responseCode === 400 || response.responseCode === 403) {
          throw new Error('Lumix 官方服务器拒绝了请求（' + response.responseCode.toString() + '），请稍后重试');
        }
        throw new Error('HTTP ' + response.responseCode.toString());
      }
      hilog.info(0x0000, 'LumixApi', 'POST %{public}s -> 200', path);
      const result = response.result;
      if (typeof result === 'string' || result instanceof ArrayBuffer) {
        return result;
      }
      throw new Error('响应格式不受支持');
    } catch (error) {
      const err = error as BusinessError;
      throw new Error(err.message !== undefined && err.message.length > 0 ? err.message : '网络错误');
    } finally {
      client.destroy();
    }
  }

  /** luts/filter：全部列表 / 新 LUT（order.key=created）。 */
  static async fetchFilter(genre: string, limit: number, offset: number,
    orderKey: string): Promise<LumixLutSummary[]> {
    const body: FilterRequestBody = {
      language: 'zh-CN',
      limit: limit.toString(),
      offset: offset.toString(),
      genre_code: genre,
    };
    if (orderKey.length > 0) {
      body.order = { 'key': orderKey, 'order': 'desc' };
    }
    const raw = await LumixCommunityApi.post('/community/luts/filter',
      JSON.stringify(body), 'application/json', http.HttpDataType.STRING, 20000) as string;
    const parsed = JSON.parse(raw) as RawLumixFilterResp;
    const items: LumixLutSummary[] = [];
    if (parsed.filter instanceof Array) {
      for (const item of parsed.filter) {
        const summary = summaryFromFilterItem(item, genre);
        if (summary !== null) items.push(summary);
      }
    }
    return items;
  }

  /** luts/top：区域 TOP10 榜单（limit 为 int，与抓包一致）。 */
  static async fetchTop(genre: string, region: string, limit: number): Promise<LumixLutSummary[]> {
    const body: TopRequestBody = {
      genre_code: genre,
      language: 'zh-CN',
      limit: limit,
      region: region,
    };
    const raw = await LumixCommunityApi.post('/community/luts/top',
      JSON.stringify(body), 'application/json', http.HttpDataType.STRING, 20000) as string;
    const parsed = JSON.parse(raw) as RawLumixTopResp;
    const items: LumixLutSummary[] = [];
    if (parsed.top instanceof Array) {
      for (const item of parsed.top) {
        const summary = summaryFromFilterItem(item, genre);
        if (summary !== null) items.push(summary);
      }
    }
    return items;
  }

  /** luts/filter + creator_code：某位制作者的全部 LUT。 */
  static async fetchCreatorLuts(creatorCode: string, limit: number,
    offset: number): Promise<LumixLutSummary[]> {
    const body: FilterRequestBody = {
      language: 'zh-CN',
      limit: limit.toString(),
      offset: offset.toString(),
      creator_code: creatorCode,
    };
    const raw = await LumixCommunityApi.post('/community/luts/filter',
      JSON.stringify(body), 'application/json', http.HttpDataType.STRING, 20000) as string;
    const parsed = JSON.parse(raw) as RawLumixFilterResp;
    const items: LumixLutSummary[] = [];
    if (parsed.filter instanceof Array) {
      for (const item of parsed.filter) {
        const summary = summaryFromFilterItem(item, '');
        if (summary !== null) items.push(summary);
      }
    }
    return items;
  }

  /** community/creator：今日制作者（pickup）。 */
  static async fetchFeatured(): Promise<LumixFeaturedCreator | null> {
    return await LumixCommunityApi.fetchCreatorByCode('pickup');
  }

  /** community/creator：按 code 查指定制作者详情。 */
  static async fetchCreatorByCode(code: string): Promise<LumixFeaturedCreator | null> {
    const body: CreatorRequestBody = { code: code, language: 'zh-CN' };
    const raw = await LumixCommunityApi.post('/community/creator',
      JSON.stringify(body), 'application/json', http.HttpDataType.STRING, 15000) as string;
    const parsed = JSON.parse(raw) as RawLumixCreatorResp;
    if (!parsed || textOf(parsed.code).length === 0) return null;
    return {
      code: textOf(parsed.code),
      name: textOf(parsed.name),
      url: textOf(parsed.url),
      introduction: textOf(parsed.introduction),
      iconPath: parsed.icon ? textOf(parsed.icon.path) : '',
      thumbPath: parsed.lut_thumbnail ? textOf(parsed.lut_thumbnail.path) : '',
      thumbOriginalPath: parsed.lut_thumbnail ? textOf(parsed.lut_thumbnail.path_original) : '',
    };
  }

  /** community/genres：分区封面与各区域榜首缩略图。 */
  static async fetchGenres(): Promise<LumixGenre[]> {
    const raw = await LumixCommunityApi.post('/community/genres', '',
      'application/json', http.HttpDataType.STRING, 15000) as string;
    const parsed = JSON.parse(raw) as RawLumixGenresResp;
    const genres: LumixGenre[] = [];
    if (parsed.genres instanceof Array) {
      for (const genre of parsed.genres) {
        const tops: LumixRegionTop[] = [];
        if (genre.top instanceof Array) {
          for (const top of genre.top) {
            tops.push({
              region: textOf(top.region),
              thumbPath: top.thumbnail ? textOf(top.thumbnail.path) : '',
              thumbOriginalPath: top.thumbnail ? textOf(top.thumbnail.path_original) : '',
            });
          }
        }
        genres.push({
          code: textOf(genre.code),
          thumbPath: genre.thumbnail ? textOf(genre.thumbnail.path) : '',
          tops: tops,
        });
      }
    }
    return genres;
  }

  /** community/lut：详情（overview / file 名 / photo_style）。 */
  static async fetchDetail(code: string): Promise<LumixLutDetail | null> {
    const body: LutRequestBody = { code: code, language: 'zh-CN' };
    const raw = await LumixCommunityApi.post('/community/lut',
      JSON.stringify(body), 'application/json', http.HttpDataType.STRING, 15000) as string;
    const parsed = JSON.parse(raw) as RawLumixDetailResp;
    if (!parsed || textOf(parsed.code).length === 0) return null;
    return {
      code: textOf(parsed.code),
      title: textOf(parsed.title),
      overview: textOf(parsed.overview),
      photoStyle: textOf(parsed.photo_style),
      downloads: numberOrZero(parsed.download_number),
      fileGrid33: parsed.file ? textOf(parsed.file.grid33) : '',
      fileGrid17: parsed.file ? textOf(parsed.file.grid17) : '',
      creatorCode: parsed.creator ? textOf(parsed.creator.code) : '',
      creatorName: parsed.creator ? textOf(parsed.creator.name) : '',
      creatorIconPath: parsed.creator && parsed.creator.icon ? textOf(parsed.creator.icon.path) : '',
      thumbPath: parsed.thumbnail ? textOf(parsed.thumbnail.path) : '',
      thumbOriginalPath: parsed.thumbnail ? textOf(parsed.thumbnail.path_original) : '',
    };
  }

  /** luts/download：下载 zip（默认 grid33，key 为空时不传，与抓包一致）。 */
  static async fetchZip(code: string, key: string): Promise<ArrayBuffer> {
    const body: DownloadRequestBody = key.length > 0 ? { code: code, key: key } : { code: code };
    return await LumixCommunityApi.post('/community/luts/download',
      JSON.stringify(body), 'application/zip', http.HttpDataType.ARRAY_BUFFER, 120000) as ArrayBuffer;
  }

  /** 下载 CDN 图片到沙箱文件（样片入库用）。 */
  static async downloadImage(url: string, destPath: string): Promise<boolean> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 30000,
      });
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
        return false;
      }
      const file = fileIo.openSync(destPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, response.result);
      } finally {
        fileIo.closeSync(file);
      }
      return true;
    } finally {
      client.destroy();
    }
  }
}

/** 内置目录（rawfile）加载与兜底查询。 */
export class LumixCatalog {
  private static cache: EmbeddedCatalog | null = null;

  static async load(context: common.UIAbilityContext): Promise<EmbeddedCatalog | null> {
    if (LumixCatalog.cache !== null) return LumixCatalog.cache;
    try {
      const raw = await context.resourceManager.getRawFileContent('lumix_community_catalog.json');
      const text = new util.TextDecoder('utf-8')
        .decodeToString(new Uint8Array(raw)).replace(/^\uFEFF/, '');
      const parsed = JSON.parse(text) as EmbeddedCatalog;
      if (parsed && parsed.luts instanceof Array) {
        LumixCatalog.cache = parsed;
        return parsed;
      }
    } catch (_error) {
    }
    return null;
  }

  private static toSummary(item: EmbeddedLutItem): LumixLutSummary {
    return {
      code: item.c,
      title: item.t,
      downloads: item.d,
      genre: item.g,
      creatorCode: item.cc,
      creatorName: item.cn,
      creatorIconPath: item.ci,
      thumbPath: item.tp,
      thumbOriginalPath: item.to,
    };
  }

  /** 内置全库（按下载量降序）。 */
  static async allSummaries(context: common.UIAbilityContext): Promise<LumixLutSummary[]> {
    const catalog = await LumixCatalog.load(context);
    if (catalog === null) return [];
    const items = catalog.luts.map((item: EmbeddedLutItem): LumixLutSummary => LumixCatalog.toSummary(item));
    items.sort((a: LumixLutSummary, b: LumixLutSummary): number => b.downloads - a.downloads);
    return items;
  }

  /** 内置分区列表（按下载量降序）。 */
  static async genreSummaries(context: common.UIAbilityContext, genre: string): Promise<LumixLutSummary[]> {
    const all = await LumixCatalog.allSummaries(context);
    return all.filter((item: LumixLutSummary): boolean => item.genre === genre);
  }

  /** 内置新 LUT（抓包时的 created 降序）。 */
  static async newSummaries(context: common.UIAbilityContext): Promise<LumixLutSummary[]> {
    const catalog = await LumixCatalog.load(context);
    if (catalog === null) return [];
    const byCode = new Map<string, LumixLutSummary>();
    for (const item of catalog.luts) byCode.set(item.c, LumixCatalog.toSummary(item));
    const items: LumixLutSummary[] = [];
    if (catalog.newCodes instanceof Array) {
      for (const code of catalog.newCodes) {
        const found = byCode.get(code);
        if (found !== undefined) items.push(found);
      }
    }
    return items;
  }

  /** 内置分区信息（封面 + 各区域榜首）。 */
  static async genres(context: common.UIAbilityContext): Promise<LumixGenre[]> {
    const catalog = await LumixCatalog.load(context);
    if (catalog === null) return [];
    return catalog.genres.map((genre: EmbeddedGenre): LumixGenre => {
      const tops = genre.tops.map((top: EmbeddedRegionTop): LumixRegionTop => {
        return { region: top.r, thumbPath: top.tp, thumbOriginalPath: top.to };
      });
      return { code: genre.c, thumbPath: genre.tp, tops: tops };
    });
  }

  /** 内置今日制作者（抓包快照兜底）。 */
  static async featured(context: common.UIAbilityContext): Promise<LumixFeaturedCreator | null> {
    const catalog = await LumixCatalog.load(context);
    if (catalog === null || !catalog.featured) return null;
    const item = catalog.featured;
    return {
      code: item.c,
      name: item.n,
      url: item.u,
      introduction: item.i,
      iconPath: item.ic,
      thumbPath: item.tp,
      thumbOriginalPath: item.to,
    };
  }

  /** 内置目录中查单个 LUT 摘要。 */
  static async findSummary(context: common.UIAbilityContext, code: string): Promise<LumixLutSummary | null> {
    const catalog = await LumixCatalog.load(context);
    if (catalog === null) return null;
    for (const item of catalog.luts) {
      if (item.c === code) return LumixCatalog.toSummary(item);
    }
    return null;
  }

  /** 内置目录中某位制作者的全部 LUT（按下载量降序）。 */
  static async creatorLuts(context: common.UIAbilityContext,
    creatorCode: string): Promise<LumixLutSummary[]> {
    const all = await LumixCatalog.allSummaries(context);
    return all.filter((item: LumixLutSummary): boolean => item.creatorCode === creatorCode);
  }
}

/** 官方 LUT 数据门面：API 优先，内置目录兜底；下载 zip → 解压 → 入自定义库。 */
export class LumixCommunityStore {
  /** 官方全量目录（名称检索用）：会话级缓存，离线兜底只缓存 1 分钟便于重连。 */
  private static indexCache: LumixLutSummary[] = [];
  private static indexOffline: boolean = true;
  private static indexCachedAt: number = 0;
  private static indexLoading: Promise<LumixLutIndex> | null = null;

  /**
   * 官方 LUT 全量目录：luts/filter 分页（50/页）拉全，供「风格库 → 官方 LUT」
   * 顶部搜索按官网名称匹配；网络失败回落内置目录快照（155 条）。
   */
  static async loadOfficialIndex(context: common.UIAbilityContext): Promise<LumixLutIndex> {
    const ttl = LumixCommunityStore.indexOffline ? 60 * 1000 : 5 * 60 * 1000;
    if (LumixCommunityStore.indexCache.length > 0 &&
      Date.now() - LumixCommunityStore.indexCachedAt < ttl) {
      return { items: LumixCommunityStore.indexCache, offline: LumixCommunityStore.indexOffline };
    }
    if (LumixCommunityStore.indexLoading !== null) return await LumixCommunityStore.indexLoading;
    const loading = LumixCommunityStore.fetchOfficialIndex(context);
    LumixCommunityStore.indexLoading = loading;
    try {
      return await loading;
    } finally {
      LumixCommunityStore.indexLoading = null;
    }
  }

  private static async fetchOfficialIndex(context: common.UIAbilityContext): Promise<LumixLutIndex> {
    try {
      const items: LumixLutSummary[] = [];
      const seen = new Set<string>();
      for (let offset = 0; offset < 400; offset += 50) {
        const page = await LumixCommunityApi.fetchFilter('', 50, offset, '');
        for (const item of page) {
          if (seen.has(item.code)) continue;
          seen.add(item.code);
          items.push(item);
        }
        if (page.length < 50) break;
      }
      if (items.length > 0) {
        items.sort((left: LumixLutSummary, right: LumixLutSummary): number =>
          right.downloads - left.downloads);
        LumixCommunityStore.indexCache = items;
        LumixCommunityStore.indexOffline = false;
        LumixCommunityStore.indexCachedAt = Date.now();
        return { items: items, offline: false };
      }
    } catch (_error) {
    }
    const fallback = await LumixCatalog.allSummaries(context);
    if (fallback.length > 0) {
      LumixCommunityStore.indexCache = fallback;
      LumixCommunityStore.indexOffline = true;
      LumixCommunityStore.indexCachedAt = Date.now();
    }
    return { items: fallback, offline: true };
  }

  /** 按官网名称检索官方目录：内置条目先出结果，网络索引到达后由调用方重跑。 */
  static searchOfficialIndex(index: LumixLutSummary[], keyword: string): LumixLutSummary[] {
    return lumixSearchByName(index, keyword);
  }

  /** 全部列表：分页拉取（limit 50 ×3），失败回落内置目录（按下载量降序）。 */
  static async loadGenreAll(context: common.UIAbilityContext, genre: string): Promise<LumixLutListResult> {
    try {
      const items: LumixLutSummary[] = [];
      for (let offset = 0; offset < 150; offset += 50) {
        const page = await LumixCommunityApi.fetchFilter(genre, 50, offset, '');
        items.push(...page);
        if (page.length < 50) break;
      }
      if (items.length > 0) return { items: items, offline: false };
    } catch (_error) {
    }
    return { items: await LumixCatalog.genreSummaries(context, genre), offline: true };
  }

  /** 区域 TOP10：luts/top 优先，失败回落内置目录下载量 TOP10（离线榜单）。 */
  static async loadTop(context: common.UIAbilityContext, genre: string,
    region: string): Promise<LumixLutListResult> {
    try {
      const items = await LumixCommunityApi.fetchTop(genre, region, 10);
      if (items.length > 0) {
        await LumixCommunityStore.enrichTopDownloads(items);
        return { items: items, offline: false };
      }
    } catch (_error) {
    }
    const all = await LumixCatalog.genreSummaries(context, genre);
    return { items: all.slice(0, 10), offline: true };
  }

  /** luts/top 响应不含下载次数字段（官方 Bean 仅 code/creator/thumbnail/title），
   * 用 community/lut 详情补齐；会话级缓存避免重复打开榜单时反复请求。 */
  private static topDownloadCache: Map<string, number> = new Map();

  private static async detailOrNull(code: string): Promise<LumixLutDetail | null> {
    try {
      return await LumixCommunityApi.fetchDetail(code);
    } catch (_error) {
      return null;
    }
  }

  private static async enrichTopDownloads(items: LumixLutSummary[]): Promise<void> {
    const missing: LumixLutSummary[] = [];
    for (const item of items) {
      const cached = LumixCommunityStore.topDownloadCache.get(item.code);
      if (cached !== undefined) {
        item.downloads = cached;
      } else {
        missing.push(item);
      }
    }
    if (missing.length === 0) return;
    const details = await Promise.all(missing.map((item: LumixLutSummary):
      Promise<LumixLutDetail | null> => LumixCommunityStore.detailOrNull(item.code)));
    for (let i = 0; i < missing.length; i++) {
      const detail = details[i];
      if (detail !== null) {
        missing[i].downloads = detail.downloads;
        LumixCommunityStore.topDownloadCache.set(missing[i].code, detail.downloads);
      }
    }
  }

  /** 新 LUT：created 降序前 6，失败回落内置目录快照。 */
  static async loadNew(context: common.UIAbilityContext): Promise<LumixLutSummary[]> {
    try {
      const items = await LumixCommunityApi.fetchFilter('', 6, 0, 'created');
      if (items.length > 0) return items;
    } catch (_error) {
    }
    return await LumixCatalog.newSummaries(context);
  }

  /** 今日制作者：API 优先，失败回落内置快照。 */
  static async loadFeatured(context: common.UIAbilityContext): Promise<LumixFeaturedCreator | null> {
    try {
      const featured = await LumixCommunityApi.fetchFeatured();
      if (featured !== null) return featured;
    } catch (_error) {
    }
    return await LumixCatalog.featured(context);
  }

  /** 分区信息：API 优先，失败回落内置目录。 */
  static async loadGenres(context: common.UIAbilityContext): Promise<LumixGenre[]> {
    try {
      const genres = await LumixCommunityApi.fetchGenres();
      if (genres.length > 0) return genres;
    } catch (_error) {
    }
    return await LumixCatalog.genres(context);
  }

  /** 制作者详情：API 优先，失败回落传入的快照（列表页/头条已带）。 */
  static async loadCreator(code: string,
    fallback: LumixFeaturedCreator | null): Promise<LumixFeaturedCreator | null> {
    try {
      const creator = await LumixCommunityApi.fetchCreatorByCode(code);
      if (creator !== null) return creator;
    } catch (_error) {
    }
    return fallback;
  }

  /** 制作者的全部 LUT：API 优先，失败回落内置目录。 */
  static async loadCreatorLuts(context: common.UIAbilityContext,
    creatorCode: string): Promise<LumixLutSummary[]> {
    try {
      const items: LumixLutSummary[] = [];
      for (let offset = 0; offset < 100; offset += 50) {
        const page = await LumixCommunityApi.fetchCreatorLuts(creatorCode, 50, offset);
        items.push(...page);
        if (page.length < 50) break;
      }
      if (items.length > 0) return items;
    } catch (_error) {
    }
    return await LumixCatalog.creatorLuts(context, creatorCode);
  }

  /** 详情：API 优先，失败用内置摘要拼最小详情（overview 为空，下载仍可用）。 */
  static async loadDetail(context: common.UIAbilityContext, code: string): Promise<LumixLutDetail | null> {
    try {
      const detail = await LumixCommunityApi.fetchDetail(code);
      if (detail !== null) return detail;
    } catch (_error) {
    }
    const summary = await LumixCatalog.findSummary(context, code);
    if (summary === null) return null;
    return {
      code: summary.code,
      title: summary.title,
      overview: '',
      photoStyle: '',
      downloads: summary.downloads,
      fileGrid33: '',
      fileGrid17: '',
      creatorCode: summary.creatorCode,
      creatorName: summary.creatorName,
      creatorIconPath: summary.creatorIconPath,
      thumbPath: summary.thumbPath,
      thumbOriginalPath: summary.thumbOriginalPath,
    };
  }

  /** 官方 LUT 是否已导入本机自定义库（以 official:<code> 为准）。 */
  static async isImported(code: string): Promise<boolean> {
    const id = 'official:' + code;
    if (LutLibraryStore.find(id) !== undefined) return true;
    if (LutBridge.ensureLutsLoaded !== null) {
      try {
        await LutBridge.ensureLutsLoaded();
      } catch (_error) {
      }
    }
    return LutLibraryStore.find(id) !== undefined;
  }

  /** 递归查找解压目录中的 .cube 文件。 */
  private static findCubeFile(dir: string): string {
    try {
      const names = fileIo.listFileSync(dir);
      for (const name of names) {
        const path = dir + '/' + name;
        const stat = fileIo.statSync(path);
        if (stat.isDirectory()) {
          const found = LumixCommunityStore.findCubeFile(path);
          if (found.length > 0) return found;
        } else if (name.toLowerCase().lastIndexOf('.cube') === name.length - 5) {
          return path;
        }
      }
    } catch (_error) {
    }
    return '';
  }

  /**
   * 下载官方 LUT 并解析为待确认条目（不直接入库）：zip → 解压 →
   * 解析 .cube → 名称/作者/描述/样片齐备。调用方将返回值经
   * LutLibraryStore.setPending 交给「导入 LUT」确认弹窗，由用户
   * 选择分类后统一走保存流程。失败抛 Error。
   */
  static async fetchOfficialLutForImport(context: common.UIAbilityContext,
    code: string): Promise<CustomLut> {
    const id = 'official:' + code;
    if (LutLibraryStore.find(id) !== undefined) {
      throw new Error('该 LUT 已在本机库中');
    }
    const detail = await LumixCommunityStore.loadDetail(context, code);
    if (detail === null) {
      throw new Error('未找到该 LUT，请稍后再试');
    }
    // 下载 zip 到沙箱缓存。
    const zipPath = context.cacheDir + '/lumix_dl_' + code + '.zip';
    const zipData = await LumixCommunityApi.fetchZip(code, '');
    const zipFile = fileIo.openSync(zipPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(zipFile.fd, zipData);
    } finally {
      fileIo.closeSync(zipFile);
    }
    // 解压到独立目录（旧目录先清理）。
    const extractDir = context.cacheDir + '/lumix_extract_' + code;
    try {
      if (fileIo.accessSync(extractDir)) fileIo.rmdirSync(extractDir);
    } catch (_error) {
    }
    fileIo.mkdirSync(extractDir);
    await zlib.unzipFile(zipPath, extractDir, { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION });
    const cubePath = LumixCommunityStore.findCubeFile(extractDir);
    if (cubePath.length === 0) {
      throw new Error('压缩包内没有可用的 .cube 文件');
    }
    // .cube 落到持久目录：确认弹窗保存后 sourceUri 需长期可读。
    const persistentCubePath = context.filesDir + '/lut_official_' + code + '.cube';
    const cubeText = readLutText(cubePath);
    const cubeFile = fileIo.openSync(persistentCubePath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(cubeFile.fd, cubeText);
    } finally {
      fileIo.closeSync(cubeFile);
    }
    const lut = parseLutText(cubeText, persistentCubePath);
    if (lut === null || lut.table === null) {
      throw new Error('LUT 文件解析失败');
    }
    lut.id = id;
    lut.name = detail.title.length > 0 ? detail.title : code;
    lut.category = '人像';
    lut.author = detail.creatorName.length > 0 ? detail.creatorName : 'Lumix Lab';
    lut.description = detail.overview.length > 0 ? detail.overview : '来自 Lumix Lab 社区的官方 LUT。';
    lut.coverUri = 'resource://vivid_cover';
    // 样片（效果应用后图）下载到持久目录，作为本机卡片与详情的示例图。
    // 优先 path_original（原图）——效果图要把 LUT 叠在这张图上，缩略图分辨率
    // 不足会让预览失真；原图失败再退缩略图。下载失败不再静默：样片缺失会让
    // 效果图退回内置通用人像（与本 LUT 无关的图），叠加效果必然失真——这是
    // 用户可直接感知的错误，必须留日志并上报，不能无声吞掉。
    if (detail.thumbOriginalPath.length > 0 || detail.thumbPath.length > 0) {
      const samplePath = context.filesDir + '/lut_sample_lumix_' + code + '.jpg';
      const candidates: string[] = [];
      if (detail.thumbOriginalPath.length > 0) candidates.push(lumixImageUrl(detail.thumbOriginalPath));
      if (detail.thumbPath.length > 0) candidates.push(lumixImageUrl(detail.thumbPath));
      let downloaded = false;
      for (const url of candidates) {
        try {
          const ok = await LumixCommunityApi.downloadImage(url, samplePath);
          if (ok) {
            lut.sampleUri = samplePath;
            lut.coverUri = samplePath;
            downloaded = true;
            break;
          }
          console.warn(`VIVID_PERF event=lut_sample_download http-fail url=${url}`);
        } catch (error) {
          console.warn(`VIVID_PERF event=lut_sample_download error url=${url} ` +
            `msg=${(error as Error).message ?? error}`);
        }
      }
      if (!downloaded) {
        console.error(`VIVID_PERF event=lut_sample_missing code=${code} ` +
          `effect preview will fall back to the bundled portrait (misleading)`);
      }
    } else {
      console.warn(`VIVID_PERF event=lut_sample_missing code=${code} reason=no-thumbnail-paths`);
    }
    return lut;
  }
}
