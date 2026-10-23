/**
 * 大光圈 · 本地深度估算。
 *
 * 使用随包发布的 Depth Anything V2 Small（默认模型，不提供模型选择器），
 * 在设备本地通过 ncnn 推理。整条链路只读当前源图的代理像素，不写任何文件，
 * 也不上传图像。
 *
 * 失败时不会让面板卡在“生成中”：服务把状态写到 AppStorage，并保留空深度图，
 * 原生阶段会自动退回与 Edmund Lumen Bokeh 相同的中心对焦径向深度。
 */
import aiNative from 'libvivid_ai.so';
import { resourceManager } from '@kit.LocalizationKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BokehSettings } from '../models/BokehSettings';
import { EditSession } from '../models/EditSession';
import { ImageProcessor } from './ImageProcessor';
import { AiSegmentationService } from './AiSegmentationService';

export const BOKEH_DEPTH_STATUS = 'bokehDepthStatus';
export const BOKEH_DEPTH_BUSY = 'bokehDepthBusy';
export const BOKEH_DEPTH_VERSION = 'bokehDepthVersion';
export const BOKEH_DEPTH_MODE = 'bokehDepthMode';

/** 深度模型的静态清单；与 rawfile/depth/LICENSES.txt 中的校验值一致。 */
interface DepthModelSpec {
  label: string;
  paramPath: string;
  binPath: string;
  paramBytes: number;
  binBytes: number;
  paramSha256: string;
  binSha256: string;
  outputLongSide: number;
}

const DEPTH_MODEL: DepthModelSpec = {
  label: 'Depth Anything V2 Small',
  paramPath: 'depth/dptv2_s.param',
  binPath: 'depth/dptv2_s.bin',
  paramBytes: 35703,
  binBytes: 50592872,
  paramSha256: 'a62df265a01c961b20406be3b0b54d98c5d69beb8c9779bb4e5428c89bf895bb',
  binSha256: 'c6a58621bb28f6e2f2ef5580d11699c09e492cf7d97a4af4f643a8a8169f3197',
  outputLongSide: 384,
};

export class BokehDepthService {
  private static loading: Promise<void> | null = null;
  private static pendingSessions: Set<number> = new Set<number>();

  /** 面板初始化时调用：把上次的状态恢复成可读文案。 */
  static statusText(session: EditSession): string {
    if (session.hasBokehDepth()) {
      return `AI 深度图 ${session.bokehDepthWidth}×${session.bokehDepthHeight}（${DEPTH_MODEL.label}）`;
    }
    return '中心对焦（未生成 AI 深度图）';
  }

  static isBusy(session: EditSession): boolean {
    return BokehDepthService.pendingSessions.has(session.sessionId);
  }

  /**
   * 生成一张深度图并发布到 session。
   *
   * 同一 session 同时只跑一次；换图/重置由 `AiSegmentationService` 的代数
   * 守卫丢弃结果——深度图必须属于发起时的照片，不能落到下一张上。
   */
  static async generate(manager: resourceManager.ResourceManager,
    session: EditSession, force: boolean = false): Promise<boolean> {
    if (BokehDepthService.pendingSessions.has(session.sessionId)) return false;
    if (session.hasBokehDepth() && !force) return true;
    const source = session.sourcePixelMap;
    if (!source) {
      BokehDepthService.publishStatus('请先打开一张照片', 'center', false);
      return false;
    }
    const generation = AiSegmentationService.currentGeneration();
    const sourceKey = `${session.sessionId}:${session.imageWidth}x${session.imageHeight}`;
    BokehDepthService.pendingSessions.add(session.sessionId);
    BokehDepthService.publishStatus(`正在生成 AI 深度图（${DEPTH_MODEL.label}）…`, 'ai', true);
    try {
      const proxy = await ImageProcessor.bokehDepthProxy(session);
      if (!proxy) {
        BokehDepthService.publishStatus('无法读取源图像素：已使用中心对焦', 'center', false);
        return false;
      }
      await BokehDepthService.ensureModel(manager);
      const header: ArrayBuffer = await aiNative.estimateDepth(
        proxy.pixels, proxy.width, proxy.height, DEPTH_MODEL.outputLongSide);
      if (generation !== AiSegmentationService.currentGeneration() ||
        session.sourcePixelMap !== source) {
        // 已经切换到别的照片：结果直接丢弃，状态也交给新照片的流程重写。
        return false;
      }
      const parsed = BokehDepthService.parse(header);
      if (!parsed) {
        BokehDepthService.publishStatus('深度图格式无效：已使用中心对焦', 'center', false);
        return false;
      }
      session.setBokehDepth(parsed.depth, parsed.width, parsed.height, sourceKey);
      BokehDepthService.logStats(parsed);
      BokehDepthService.applyAutoFocus(session.bokeh, parsed.depth, parsed.width, parsed.height);
      BokehDepthService.publishStatus(
        `AI 深度图 ${parsed.width}×${parsed.height}（${DEPTH_MODEL.label}）`, 'ai', false);
      const signal = AppStorage.get<number>(BOKEH_DEPTH_VERSION) ?? 0;
      AppStorage.setOrCreate(BOKEH_DEPTH_VERSION, signal + 1);
      ImageProcessor.process(session);
      return true;
    } catch (error) {
      console.error('VIVID_BOKEH depth generation failed: ' + String(error));
      BokehDepthService.publishStatus('AI 深度生成失败：已使用中心对焦', 'center', false);
      return false;
    } finally {
      BokehDepthService.pendingSessions.delete(session.sessionId);
    }
  }

  /** 只加载/校验一次模型；并发调用共享同一个 Promise。 */
  private static async ensureModel(manager: resourceManager.ResourceManager): Promise<void> {
    if (aiNative.depthLoaded()) return;
    if (BokehDepthService.loading !== null) return BokehDepthService.loading;
    const task = (async (): Promise<void> => {
      const param = await BokehDepthService.readVerified(manager, DEPTH_MODEL.paramPath,
        DEPTH_MODEL.paramBytes, DEPTH_MODEL.paramSha256);
      const bin = await BokehDepthService.readVerified(manager, DEPTH_MODEL.binPath,
        DEPTH_MODEL.binBytes, DEPTH_MODEL.binSha256);
      await aiNative.loadDepthModel(param, bin);
    })();
    BokehDepthService.loading = task;
    try {
      await task;
    } finally {
      BokehDepthService.loading = null;
    }
  }

  private static async readVerified(manager: resourceManager.ResourceManager, path: string,
    expectedBytes: number, expectedSha256: string): Promise<ArrayBuffer> {
    const bytes = await manager.getRawFileContent(path);
    if (bytes.byteLength !== expectedBytes) {
      throw new Error(`${path}: expected ${expectedBytes} bytes, got ${bytes.byteLength}`);
    }
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: bytes });
    const digest = await md.digest();
    let text = '';
    for (let index = 0; index < digest.data.length; index++) {
      const value = digest.data[index];
      text += (value < 16 ? '0' : '') + value.toString(16);
    }
    if (text.toLowerCase() !== expectedSha256) {
      throw new Error(`${path}: sha256 mismatch`);
    }
    const copy = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(copy).set(bytes);
    return copy;
  }

  /** 诊断用：记录 8 位深度图的分布，便于确认模型没有退化成一片黑。 */
  private static logStats(parsed: BokehDepth): void {
    const histogram: number[] = new Array<number>(256).fill(0);
    for (let index = 0; index < parsed.depth.length; index++) {
      histogram[parsed.depth[index]]++;
    }
    const percentile = (fraction: number): number => {
      const target = parsed.depth.length * fraction;
      let seen = 0;
      for (let value = 0; value < 256; value++) {
        seen += histogram[value];
        if (seen >= target) return value;
      }
      return 255;
    };
    console.info(`VIVID_BOKEH depth bytes=${parsed.depth.length}` +
      ` p01=${percentile(0.01)} p10=${percentile(0.10)} p50=${percentile(0.50)}` +
      ` p90=${percentile(0.90)} p99=${percentile(0.99)}`);
  }

  private static parse(header: ArrayBuffer): BokehDepth | null {    if (!header || header.byteLength < 8) return null;
    const view = new DataView(header);
    const width = view.getUint32(0, true);
    const height = view.getUint32(4, true);
    if (width <= 0 || height <= 0 || header.byteLength < 8 + width * height) return null;
    return {
      width: width,
      height: height,
      depth: new Uint8Array(header.slice(8, 8 + width * height)),
    };
  }

  /**
   * 与参考实现一致：生成后把焦点放到画面中部主体。
   *
   * 取中心 24% 区域的深度中位数，而不是平均值——中心窗口里只要有一小块
   * 远景，平均值就会把焦点推到主体之外。
   */
  private static applyAutoFocus(bokeh: BokehSettings, depth: Uint8Array,
    width: number, height: number): void {
    const x0 = Math.floor(width * 0.38);
    const x1 = Math.ceil(width * 0.62);
    const y0 = Math.floor(height * 0.34);
    const y1 = Math.ceil(height * 0.58);
    const values: number[] = [];
    for (let y = y0; y < y1; y++) {
      for (let x = x0; x < x1; x++) {
        values.push(depth[y * width + x]);
      }
    }
    if (values.length === 0) return;
    values.sort((a: number, b: number) => a - b);
    const median = values[Math.floor(values.length / 2)] / 255;
    if (Number.isFinite(median)) {
      bokeh.focus = Math.max(0.02, Math.min(0.98, median));
    }
  }

  private static publishStatus(text: string, mode: string, busy: boolean): void {
    AppStorage.setOrCreate(BOKEH_DEPTH_STATUS, text);
    AppStorage.setOrCreate(BOKEH_DEPTH_MODE, mode);
    AppStorage.setOrCreate(BOKEH_DEPTH_BUSY, busy);
  }
}

interface BokehDepth {
  width: number;
  height: number;
  depth: Uint8Array;
}
