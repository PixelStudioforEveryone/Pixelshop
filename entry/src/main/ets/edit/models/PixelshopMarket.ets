import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { CustomLut, parseLutText } from './LutLibrary';

// LUT 市场接口（与 LutPage/ProfileSection 同源服务器，分享码跨用户检索）。
const LUT_API_BASE: string = 'https://your-server.example.com/api/luts';
const LUT_UPLOAD_TOKEN: string = 'vivid-log-Kq7fXm2Rt9Lw4Zb8';

/** GET /api/luts/market 响应（搜索卡片展示用）。 */
export interface MarketLutMeta {
  code: string;
  name: string;
  author: string;
  description: string;
  updatedAt: number;
  previewBase64: string;
}

interface RawMarketMeta {
  code?: string;
  name?: string;
  author?: string;
  description?: string;
  updatedAt?: number;
  previewBase64?: string;
}

interface RawMarketFile {
  name?: string;
  cubeText?: string;
  author?: string;
  description?: string;
  previewBase64?: string;
}

function textOf(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

/** LUT 市场客户端：分享码检索、下载导入（发布随分享上传由服务器完成）。 */
export class PixelshopMarket {
  /** 按分享码检索市场 LUT 元数据；未找到返回 null，网络错误抛 Error。 */
  static async search(code: string): Promise<MarketLutMeta | null> {
    const client = http.createHttp();
    try {
      const response = await client.request(
        LUT_API_BASE + '/market?code=' + encodeURIComponent(code), {
        method: http.RequestMethod.GET,
        header: { 'X-Upload-Token': LUT_UPLOAD_TOKEN },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 30000,
      });
      if (response.responseCode === 404) return null;
      if (response.responseCode !== 200) {
        throw new Error('市场服务暂不可用（HTTP ' + response.responseCode + '）');
      }
      const raw = response.result as string;
      const parsed = JSON.parse(raw) as RawMarketMeta;
      if (!parsed || textOf(parsed.code).length === 0) return null;
      return {
        code: textOf(parsed.code),
        name: textOf(parsed.name),
        author: textOf(parsed.author),
        description: textOf(parsed.description),
        updatedAt: typeof parsed.updatedAt === 'number' ? parsed.updatedAt : 0,
        previewBase64: textOf(parsed.previewBase64),
      };
    } finally {
      client.destroy();
    }
  }

  /**
   * 下载市场 LUT 并解析为待确认条目（与官方 LUT 下载同构）：
   * cubeText 落持久目录、预览图落样片文件，调用方经 setPending
   * 交给「导入 LUT」确认弹窗。失败抛 Error。
   */
  static async fetchMarketLutForImport(context: common.UIAbilityContext,
    code: string): Promise<CustomLut> {
    const id = 'market:' + code;
    const raw = await PixelshopMarket.requestMarketFile(code);
    const cubeText = textOf(raw.cubeText);
    if (cubeText.length === 0) {
      throw new Error('市场 LUT 数据无效');
    }
    const cubePath = context.filesDir + '/lut_market_' + PixelshopMarket.safeFileName(code) + '.cube';
    const cubeFile = fileIo.openSync(cubePath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(cubeFile.fd, cubeText);
    } finally {
      fileIo.closeSync(cubeFile);
    }
    const lut = parseLutText(cubeText, cubePath);
    if (lut === null || lut.table === null) {
      throw new Error('LUT 文件解析失败');
    }
    lut.id = id;
    lut.name = textOf(raw.name).length > 0 ? textOf(raw.name) : code;
    lut.category = '人像';
    lut.author = textOf(raw.author);
    lut.description = textOf(raw.description).length > 0
      ? textOf(raw.description) : '来自 Pixelshop LUT 市场的分享。';
    lut.coverUri = 'resource://vivid_cover';
    const previewBase64 = textOf(raw.previewBase64);
    if (previewBase64.length > 0) {
      const samplePath = context.filesDir + '/lut_sample_market_' +
        PixelshopMarket.safeFileName(code) + '.jpg';
      try {
        const bytes = new util.Base64Helper().decodeSync(previewBase64);
        const sampleFile = fileIo.openSync(samplePath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(sampleFile.fd, bytes.buffer);
        } finally {
          fileIo.closeSync(sampleFile);
        }
        lut.sampleUri = samplePath;
        lut.coverUri = samplePath;
      } catch (_error) {
      }
    }
    return lut;
  }

  private static async requestMarketFile(code: string): Promise<RawMarketFile> {
    const client = http.createHttp();
    try {
      const response = await client.request(
        LUT_API_BASE + '/market/file?code=' + encodeURIComponent(code), {
        method: http.RequestMethod.GET,
        header: { 'X-Upload-Token': LUT_UPLOAD_TOKEN },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 60000,
      });
      if (response.responseCode === 404) {
        throw new Error('未找到该分享码对应的 LUT');
      }
      if (response.responseCode !== 200) {
        throw new Error('市场服务暂不可用（HTTP ' + response.responseCode + '）');
      }
      const parsed = JSON.parse(response.result as string) as RawMarketFile;
      if (!parsed) {
        throw new Error('市场 LUT 数据无效');
      }
      return parsed;
    } finally {
      client.destroy();
    }
  }

  private static safeFileName(code: string): string {
    return code.replace(/[^0-9A-Za-z_-]/g, '_');
  }
}
