import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';
import { CustomLut, lutEffectCachePath, lutSampleBaseName } from '../models/LutLibrary';
import { PixelMapUtils } from './PixelMapUtils';
import { processPixels, ProcessParams, ProcessResult, WorkerLut } from '../engine/ProcessWorker';
import { GpuShaderBridge } from '../engine/GpuShaderBridge';

/**
 * LUT 效果图渲染（本机 LUT 页与调色面板的 LUT 弹窗共用）。
 *
 * 两条路径必须产出一模一样的图，否则同一个 LUT 在两处显示会不一致：
 *  1. 先读磁盘缓存（filesDir/<样图>_<LUT>_hq.jpg），命中直接返回；
 *  2. 未命中则按 用户样图 > 官方参考图 > 调用方给的底图 的顺序取原图，
 *     用 GPU（GpuShaderBridge.renderLutPreview）渲染，GPU 不可用时退回
 *     TaskPool 里的 CPU LUT 阶段，最后落盘缓存。
 */

/** 内置 LUT 的官方参考图（referenceKey 为空时用通用样图）。 */
export function lutReferenceResource(entry: CustomLut) {
  switch (entry.referenceKey ?? '') {
    case 'sunny_mint': return $r('app.media.lut_ref_sunny_mint');
    case 'japanese_cyan': return $r('app.media.lut_ref_japanese_cyan');
    case 'fresh_food': return $r('app.media.lut_ref_fresh_food');
    case 'healing_light': return $r('app.media.lut_ref_healing_light');
    case 'snow_portrait': return $r('app.media.lut_ref_snow_portrait');
    case 'seaside_portrait': return $r('app.media.lut_ref_seaside_portrait');
    case 'nc_classic_neg': return $r('app.media.lut_ref_nc_classic_neg');
    default: return $r('app.media.lut_sample_portrait');
  }
}

/** 效果图缓存文件：与「本机 LUT」页共用同一份。 */
export function lutPreviewCachePath(filesDir: string, entry: CustomLut): string {
  return lutEffectCachePath(filesDir, lutSampleBaseName(entry), entry.name);
}

export async function renderLutCardEffect(context: common.UIAbilityContext, entry: CustomLut,
  basePixels: Uint8ClampedArray, width: number, height: number): Promise<image.PixelMap | null> {
  const table = entry.table;
  if (table === null || table === undefined) return null;
  const cachePath = lutPreviewCachePath(context.filesDir, entry);
  try {
    if (fileIo.statSync(cachePath).size > 0) {
      const cached = await PixelMapUtils.loadFromUri(cachePath, 640);
      if (cached) return cached;
    }
  } catch (_error) {
    // 首次运行或缓存失效都继续走渲染。
  }
  let renderWidth = width;
  let renderHeight = height;
  let renderBuffer = basePixels.buffer.slice(0);
  if (entry.sampleUri && entry.sampleUri.indexOf('resource://') !== 0) {
    // 用户自定义样图优先于官方参考图。
    const sample = await PixelMapUtils.loadFromUri(entry.sampleUri, 640);
    if (!sample) return null;
    try {
      const sampleInfo = await sample.getImageInfo();
      renderWidth = sampleInfo.size.width;
      renderHeight = sampleInfo.size.height;
      renderBuffer = new ArrayBuffer(renderWidth * renderHeight * 4);
      await sample.readPixelsToBuffer(renderBuffer);
    } finally {
      sample.release();
    }
  } else if ((entry.referenceKey ?? '').length > 0) {
    let referenceSource: image.ImageSource | null = null;
    try {
      const referenceBytes = await context.resourceManager.getMediaContent(lutReferenceResource(entry));
      referenceSource = image.createImageSource(referenceBytes.buffer as ArrayBuffer);
      const referenceInfo = await referenceSource.getImageInfo();
      const referenceScale = Math.min(1, 640 / Math.max(referenceInfo.size.width, referenceInfo.size.height));
      renderWidth = Math.max(1, Math.round(referenceInfo.size.width * referenceScale));
      renderHeight = Math.max(1, Math.round(referenceInfo.size.height * referenceScale));
      const referenceMap = await referenceSource.createPixelMap({
        editable: true, desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredSize: { width: renderWidth, height: renderHeight },
      });
      renderBuffer = new ArrayBuffer(renderWidth * renderHeight * 4);
      await referenceMap.readPixelsToBuffer(renderBuffer);
      referenceMap.release();
    } catch (_error) {
      renderWidth = width;
      renderHeight = height;
      renderBuffer = basePixels.buffer.slice(0);
    } finally {
      if (referenceSource) referenceSource.release();
    }
  }
  const workerLut: WorkerLut = {
    enabled: true, intensity: 1, size: table.size,
    values: table.values, domainMin: table.domainMin, domainMax: table.domainMax,
  };
  let pixels: Uint8ClampedArray;
  const gpuBuffer = await GpuShaderBridge.renderLutPreview(renderBuffer.slice(0), renderWidth, renderHeight, table);
  if (gpuBuffer && gpuBuffer.byteLength > 0) {
    pixels = new Uint8ClampedArray(gpuBuffer);
  } else {
    const params: ProcessParams = {
      source: renderBuffer, width: renderWidth, height: renderHeight,
      layers: [], luts: [workerLut], cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
      rotation: 0, flipH: false, flipV: false, applyGeometry: false, ignoreCrop: true,
    };
    const task = new taskpool.Task(processPixels, params);
    const result = await taskpool.execute(task) as ProcessResult;
    if (!result || result.buffer.byteLength === 0) return null;
    pixels = new Uint8ClampedArray(result.buffer);
  }
  const output = await image.createPixelMap(new ArrayBuffer(pixels.byteLength), {
    editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888,
    size: { width: renderWidth, height: renderHeight },
  });
  await output.writeBufferToPixels(pixels.buffer);
  try {
    const jpeg = await PixelMapUtils.encodeToJpeg(output, 90);
    if (jpeg) {
      const file = fileIo.openSync(cachePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, jpeg);
      fileIo.closeSync(file);
    }
  } catch (_error) {
    // 缓存失败不影响内存中的效果图。
  }
  return output;
}
