/**
 * On-device subject / sky segmentation for the mask tool.
 *
 * Responsibilities kept deliberately in one place:
 *   - read the model bytes from rawfile and verify them against the manifest in
 *     AiMaskModels.ets (a mismatch is reported, never ignored);
 *   - hand those bytes to the native ncnn bridge exactly once per process;
 *   - run inference off the UI thread and never leave a caller hanging;
 *   - cache the soft mask per source/model/dependency key;
 *   - let a caller invalidate in-flight work when the photo changes.
 *
 * Nothing here decodes RAW/DCP, uploads anything, or touches the image on disk:
 * the caller passes a bounded proxy of the already decoded source, so later
 * colour grading is never baked into the mask.
 */
import aiNative from 'libvivid_ai.so';
import { image } from '@kit.ImageKit';
import { resourceManager } from '@kit.LocalizationKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AiMaskKind, AiMaskModelSpec, aiMaskModelFor } from '../models/AiMaskModels';
import { RASTER_ORIGIN_SUBJECT, RASTER_ORIGIN_SKY } from '../models/Mask';

/** The raster origin recorded for a model mask, so provenance survives reload. */
export function aiMaskOrigin(kind: AiMaskKind): string {
  return kind === AiMaskKind.SKY ? RASTER_ORIGIN_SKY : RASTER_ORIGIN_SUBJECT;
}

/** Why a segmentation request could not be served. Surfaced to the user as-is. */
export enum AiMaskErrorCode {
  MODEL_MISSING = 'modelMissing',
  MODEL_CORRUPT = 'modelCorrupt',
  LOAD_FAILED = 'loadFailed',
  SEGMENT_FAILED = 'segmentFailed',
  NO_SOURCE = 'noSource',
  CANCELLED = 'cancelled',
}

export class AiMaskError extends Error {
  public code: AiMaskErrorCode;
  public detail: string;

  constructor(code: AiMaskErrorCode, message: string, detail: string = '') {
    super(message);
    this.code = code;
    this.detail = detail;
  }
}

/** A soft selection covering the whole source frame, in source-normalised space. */
export interface AiMaskRaster {
  kind: AiMaskKind;
  /** Raster width in samples (the model's own output width, e.g. 320 / 384). */
  width: number;
  /** Raster height in samples. */
  height: number;
  /** width*height single-channel alpha, 0..255. */
  alpha: Uint8Array;
  /** Manifest key of the model that produced it, for cache invalidation. */
  modelKey: string;
}

function errorText(error: Object): string {
  try {
    const message: string = (error as Error).message;
    return message !== undefined && message !== null ? message : '';
  } catch (_e) {
    return '';
  }
}

function toHex(bytes: Uint8Array): string {
  let text = '';
  for (let index = 0; index < bytes.length; index++) {
    const value = bytes[index];
    text += (value < 16 ? '0' : '') + value.toString(16);
  }
  return text;
}

/** Copy a typed array into a tightly sized ArrayBuffer for the NAPI boundary. */
function tightBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(copy).set(bytes);
  return copy;
}

export class AiSegmentationService {
  /** One in-flight load per model kind, so two taps cannot race the same decode. */
  private static loading: Map<number, Promise<AiMaskModelSpec>> = new Map<number, Promise<AiMaskModelSpec>>();
  /** Bounded soft-mask cache: a few 100-150 KB rasters, replaced on image switch. */
  private static softMasks: Map<string, AiMaskRaster> = new Map<string, AiMaskRaster>();
  private static softMaskOrder: string[] = [];
  private static readonly softMaskCapacity: number = 4;
  /** Bumped by cancelPending(); any request that observes a change reports CANCELLED. */
  private static generation: number = 0;
  private static busy: boolean = false;

  static currentGeneration(): number {
    return AiSegmentationService.generation;
  }

  /**
   * Invalidate outstanding work. Called from ImageProcessor.clearSourceCache, which is the
   * single point where every cache derived from the source pixels is dropped (photo switch,
   * source change, session teardown). An inference already running cannot be interrupted
   * inside ncnn, but its result is dropped instead of being applied to another photo.
   *
   * This matters because the soft-mask key below contains no photo identity: without this
   * call a same-sized second photo hit the first photo's cache entry and reused its mask.
   */
  static cancelPending(): void {
    AiSegmentationService.generation++;
    AiSegmentationService.softMasks.clear();
    AiSegmentationService.softMaskOrder = [];
  }

  static release(): void {
    AiSegmentationService.cancelPending();
    AiSegmentationService.busy = false;
    try {
      aiNative.release();
    } catch (_e) {
      // Releasing a model that was never loaded is not an error worth surfacing.
    }
  }

  static isBusy(): boolean {
    return AiSegmentationService.busy;
  }

  static isLoaded(kind: AiMaskKind): boolean {
    try {
      return aiNative.isLoaded(kind as number);
    } catch (_e) {
      return false;
    }
  }

  /**
   * Read and verify one model, then load it into the native cache.
   * Resolves to the manifest entry so callers can show provenance.
   */
  static async ensureLoaded(manager: resourceManager.ResourceManager,
    kind: AiMaskKind): Promise<AiMaskModelSpec> {
    const spec: AiMaskModelSpec = aiMaskModelFor(kind);
    if (AiSegmentationService.isLoaded(kind)) return spec;
    const pending = AiSegmentationService.loading.get(kind as number);
    if (pending !== undefined) return pending;
    const task = AiSegmentationService.loadVerified(manager, spec);
    AiSegmentationService.loading.set(kind as number, task);
    try {
      return await task;
    } finally {
      AiSegmentationService.loading.delete(kind as number);
    }
  }

  private static async loadVerified(manager: resourceManager.ResourceManager,
    spec: AiMaskModelSpec): Promise<AiMaskModelSpec> {
    const param = await AiSegmentationService.readVerified(
      manager, spec.paramPath, spec.paramBytes, spec.paramSha256, spec);
    const bin = await AiSegmentationService.readVerified(
      manager, spec.binPath, spec.binBytes, spec.binSha256, spec);
    try {
      await aiNative.loadModel(spec.kind as number, param, bin);
      console.info(`VIVID_PERF t=${Date.now()} event=ai_load kind=${spec.kind} ok=1 ` +
        `param=${param.byteLength} bin=${bin.byteLength} loaded=${AiSegmentationService.isLoaded(spec.kind) ? 1 : 0}`);
    } catch (error) {
      console.info(`VIVID_PERF t=${Date.now()} event=ai_load kind=${spec.kind} ok=0 ` +
        `param=${param.byteLength} bin=${bin.byteLength}`);
      const detail = errorText(error as Object);
      throw new AiMaskError(AiMaskErrorCode.LOAD_FAILED,
        `${spec.label}模型加载失败`, detail.length > 0 ? detail : 'native loadModel rejected the weights');
    }
    return spec;
  }

  private static async readVerified(manager: resourceManager.ResourceManager, path: string,
    expectedBytes: number, expectedSha256: string, spec: AiMaskModelSpec): Promise<ArrayBuffer> {
    let bytes: Uint8Array;
    try {
      bytes = await manager.getRawFileContent(path);
    } catch (error) {
      const detail = errorText(error as Object);
      throw new AiMaskError(AiMaskErrorCode.MODEL_MISSING,
        `${spec.label}模型文件缺失，无法使用该功能`, `${path} ${detail}`);
    }
    if (bytes.byteLength !== expectedBytes) {
      throw new AiMaskError(AiMaskErrorCode.MODEL_CORRUPT,
        `${spec.label}模型文件大小异常，已停止加载`,
        `${path} expected ${expectedBytes} bytes, got ${bytes.byteLength}`);
    }
    const digest = await AiSegmentationService.sha256(bytes);
    if (digest !== expectedSha256) {
      throw new AiMaskError(AiMaskErrorCode.MODEL_CORRUPT,
        `${spec.label}模型校验失败，已停止加载`,
        `${path} sha256 ${digest} != ${expectedSha256}`);
    }
    return tightBuffer(bytes);
  }

  private static async sha256(bytes: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: bytes });
    const digest = await md.digest();
    return toHex(digest.data);
  }

  /**
   * Run segmentation on a bounded proxy of the source frame.
   *
   * `pixels` is RGBA8888, `width`/`height` its dimensions; the native side
   * resizes to the network's square input, so the caller does not pre-resize.
   * Throws AiMaskError on every failure path and always settles.
   */
  static async segment(manager: resourceManager.ResourceManager, kind: AiMaskKind,
    pixels: ArrayBuffer, width: number, height: number): Promise<AiMaskRaster> {
    if (width <= 0 || height <= 0 || pixels.byteLength < width * height * 4) {
      throw new AiMaskError(AiMaskErrorCode.NO_SOURCE, '没有可用的源图像', 'empty or short source buffer');
    }
    const spec = await AiSegmentationService.ensureLoaded(manager, kind);

    const generation = AiSegmentationService.generation;
    const cached = AiSegmentationService.softMasks.get(
      AiSegmentationService.cacheKey(spec, generation, width, height));
    if (cached !== undefined) return cached;

    AiSegmentationService.busy = true;
    let header: ArrayBuffer;
    try {
      header = await aiNative.segment(kind as number, pixels, width, height);
    } catch (error) {
      const detail = errorText(error as Object);
      throw new AiMaskError(AiMaskErrorCode.SEGMENT_FAILED,
        `${spec.label}识别失败，请重试`, detail.length > 0 ? detail : 'native segment rejected the request');
    } finally {
      AiSegmentationService.busy = false;
    }
    if (generation !== AiSegmentationService.generation) {
      throw new AiMaskError(AiMaskErrorCode.CANCELLED, '已切换到其他照片，识别结果已丢弃', 'stale generation');
    }
    const raster = AiSegmentationService.parseRaster(header, kind, spec);
    {
      let maxValue = 0;
      let covered = 0;
      for (let index = 0; index < raster.alpha.length; index++) {
        const value = raster.alpha[index];
        if (value > maxValue) maxValue = value;
        if (value >= 128) covered++;
      }
      const total = Math.max(1, raster.alpha.length);
      // 边缘采样：判断“右侧少一块”是栅格本身边界空，还是合成时被裁掉。
      const edgeRow = Math.floor(raster.height / 8);
      const rowStart = edgeRow * raster.width;
      const leftEdge = [raster.alpha[rowStart], raster.alpha[rowStart + 1],
        raster.alpha[rowStart + 2], raster.alpha[rowStart + 3]].join(',');
      const rightEdge = [raster.alpha[rowStart + raster.width - 4], raster.alpha[rowStart + raster.width - 3],
        raster.alpha[rowStart + raster.width - 2], raster.alpha[rowStart + raster.width - 1]].join(',');
      console.info(`VIVID_PERF t=${Date.now()} event=ai_out kind=${kind} ` +
        `size=${raster.width}x${raster.height} max=${maxValue} cover=${Math.round(covered * 1000 / total) / 10}% ` +
        `left=[${leftEdge}] right=[${rightEdge}] loaded=${AiSegmentationService.isLoaded(kind) ? 1 : 0}`);
    }
    AiSegmentationService.cacheSoftMask(spec, generation, width, height, raster);
    return raster;
  }

  /** Convenience wrapper that reads a bounded proxy off a PixelMap first. */
  static async segmentPixelMap(manager: resourceManager.ResourceManager, kind: AiMaskKind,
    pixelMap: image.PixelMap): Promise<AiMaskRaster> {
    const info = await pixelMap.getImageInfo();
    const width = info.size.width;
    const height = info.size.height;
    if (width <= 0 || height <= 0) {
      throw new AiMaskError(AiMaskErrorCode.NO_SOURCE, '没有可用的源图像', 'pixel map has no size');
    }
    const buffer = new ArrayBuffer(width * height * 4);
    try {
      await pixelMap.readPixelsToBuffer(buffer);
    } catch (error) {
      const detail = errorText(error as Object);
      throw new AiMaskError(AiMaskErrorCode.NO_SOURCE, '无法读取源图像像素', detail);
    }
    // 诊断：把喂给模型的代理图压成 10x10 亮度图。若这里就是全黑/异常，说明是
    // 我们的输入（PixelMap 读取或缩放）有问题；若输入正常而输出 empty，才是模型问题。
    AiSegmentationService.logInputMap(buffer, width, height);
    return AiSegmentationService.segment(manager, kind, buffer, width, height);
  }

  /** 代理图的 10x10 亮度分布，仅用于诊断。 */
  private static logInputMap(buffer: ArrayBuffer, width: number, height: number): void {
    const rgba = new Uint8Array(buffer);
    const cols = 10;
    const rows = 10;
    const cw = Math.max(1, Math.floor(width / cols));
    const ch = Math.max(1, Math.floor(height / rows));
    let map = '';
    let sumAll = 0;
    let countAll = 0;
    for (let ry = 0; ry < rows; ry++) {
      for (let rx = 0; rx < cols; rx++) {
        let sum = 0;
        let count = 0;
        for (let y = ry * ch; y < Math.min(height, (ry + 1) * ch); y += 2) {
          for (let x = rx * cw; x < Math.min(width, (rx + 1) * cw); x += 2) {
            const offset = (y * width + x) * 4;
            if (offset + 2 >= rgba.length) continue;
            sum += (rgba[offset] * 299 + rgba[offset + 1] * 587 + rgba[offset + 2] * 114) / 1000;
            count++;
          }
        }
        const avg = count > 0 ? Math.round(sum / count) : -1;
        sumAll += avg * Math.max(1, count);
        countAll += Math.max(1, count);
        map += avg < 0 ? '?' : (avg >= 170 ? '#' : (avg >= 110 ? '+' : (avg >= 50 ? '.' : ' ')));
      }
      map += '/';
    }
    console.info(`VIVID_PERF t=${Date.now()} event=ai_input proxy=${width}x${height} ` +
      `mean=${countAll > 0 ? Math.round(sumAll / countAll) : -1} map=${map}`);
  }

  /** The model's own output is one byte per sample after a two-word header. */
  private static parseRaster(header: ArrayBuffer, kind: AiMaskKind,
    spec: AiMaskModelSpec): AiMaskRaster {
    if (header.byteLength < 8) {
      throw new AiMaskError(AiMaskErrorCode.SEGMENT_FAILED,
        `${spec.label}识别失败，请重试`, `native result too short: ${header.byteLength}`);
    }
    const view = new DataView(header);
    const width = view.getUint32(0, true);
    const height = view.getUint32(4, true);
    if (width <= 0 || height <= 0 || header.byteLength < 8 + width * height) {
      throw new AiMaskError(AiMaskErrorCode.SEGMENT_FAILED,
        `${spec.label}识别失败，请重试`,
        `native result header ${width}x${height} for ${header.byteLength} bytes`);
    }
    const alpha = new Uint8Array(header, 8, width * height);
    return { kind: kind, width: width, height: height, alpha: alpha, modelKey: spec.key };
  }

  /**
   * Cache identity for a soft mask.
   *
   * The generation is what keeps two same-sized photos apart, so this key is only correct
   * while `cancelPending` is called on every photo switch -- which is why that call lives in
   * `ImageProcessor.clearSourceCache` rather than in the UI. Model kind and dimensions are
   * still part of the key because both change the raster's meaning.
   */
  private static cacheKey(spec: AiMaskModelSpec, generation: number,
    width: number, height: number): string {
    return `${spec.key}:${generation}:${width}x${height}`;
  }

  private static cacheSoftMask(spec: AiMaskModelSpec, generation: number, width: number,
    height: number, raster: AiMaskRaster): void {
    const key = AiSegmentationService.cacheKey(spec, generation, width, height);
    AiSegmentationService.softMasks.set(key, raster);
    AiSegmentationService.softMaskOrder.push(key);
    while (AiSegmentationService.softMaskOrder.length > AiSegmentationService.softMaskCapacity) {
      const oldest = AiSegmentationService.softMaskOrder.shift();
      if (oldest !== undefined) AiSegmentationService.softMasks.delete(oldest);
    }
  }

  /**
   * Static model metadata for the provenance sheet. Purely descriptive; it does
   * not load anything and therefore cannot fail.
   */
  static modelInfo(): AiMaskModelSpec[] {
    return [
      aiMaskModelFor(AiMaskKind.SUBJECT),
      aiMaskModelFor(AiMaskKind.SKY),
    ];
  }
}

/** Fraction of the raster selected at half coverage or more. */
export function bitmapCoverage(alpha: Uint8Array): number {
  if (alpha.length === 0) return 0;
  let selected = 0;
  for (let index = 0; index < alpha.length; index++) {
    if (alpha[index] >= 128) selected++;
  }
  return selected / alpha.length;
}

/**
 * User-facing text for anything this module throws.
 *
 * The point is that a real failure is always described as a failure: there is
 * no path here that reports success when a model is missing, corrupt or unable
 * to run, because the callers show this string verbatim.
 */
export function aiMaskErrorMessage(error: Object): string {
  if (error instanceof AiMaskError) {
    const aiError = error as AiMaskError;
    switch (aiError.code) {
      case AiMaskErrorCode.MODEL_MISSING:
        return '模型文件缺失，该功能暂不可用（未生成任何选区）';
      case AiMaskErrorCode.MODEL_CORRUPT:
        return '模型校验未通过，已拒绝加载（未生成任何选区）';
      case AiMaskErrorCode.LOAD_FAILED:
        return '模型加载失败，该功能暂不可用（未生成任何选区）';
      case AiMaskErrorCode.NO_SOURCE:
        return '无法读取源图像像素，请重新打开照片';
      case AiMaskErrorCode.CANCELLED:
        return '已切换到其他照片，本次识别结果已丢弃';
      default:
        return aiError.message;
    }
  }
  const detail = errorText(error);
  return detail.length > 0 ? `识别失败：${detail}` : '识别失败，请重试';
}
