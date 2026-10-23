/**
 * Small ArkTS boundary for the optional LibRaw Native module.
 *
 * The Native function receives the complete RW2 bytes and always returns a
 * bounded preview.  It never replaces the platform decoder or the embedded
 * JPEG fallback; callers decide whether a matching DCP is available.
 */
import rawNative from 'libvivid_raw.so';
import { taskpool } from '@kit.ArkTS';
import { DcpProfileData, RenderTables, classicDcp, buildDcpRenderPlan, cloneDcpRenderPlan } from '../engine/DcpCpu';
import { processDcp } from '../engine/DcpWorker';

export enum RawDecodeStatus {
  Ok = 0,
  UnsupportedCamera = 1,
  Corrupt = 2,
  UnsupportedCompression = 3,
  OutOfMemory = 4,
  UnsupportedCfa = 5,
  Unknown = 6,
}

/** Structured LibRaw failure; a null return still means "cancelled". */
export interface RawDecodeFailure {
  status: RawDecodeStatus;
  message: string;
  diagnostics: string;
}

export function rawDecodeStatusLabel(status: RawDecodeStatus): string {
  switch (status) {
    case RawDecodeStatus.UnsupportedCamera: return 'UNSUPPORTED_CAMERA';
    case RawDecodeStatus.Corrupt: return 'INCOMPLETE_OR_CORRUPT';
    case RawDecodeStatus.UnsupportedCompression: return 'UNSUPPORTED_COMPRESSION';
    case RawDecodeStatus.OutOfMemory: return 'OUT_OF_MEMORY';
    case RawDecodeStatus.UnsupportedCfa: return 'UNSUPPORTED_CFA';
    default: return 'UNKNOWN';
  }
}

export interface NativeRawDecodeResult {
  pixels: ArrayBuffer;
  linearPixels: ArrayBuffer;
  cameraNeutral: number[];
  camToSrgb: number[];
  width: number;
  height: number;
  sourceWidth: number;
  sourceHeight: number;
  model: string;
  blackLevel: number;
  whiteLevel: number;
  bitDepth: number;
  linearCameraRgb: number;
  dcpApplied: number;
  status: number;
  message: string;
  diagnostics: string;
}

export class RawNativeBridge {
  private static linearKey: string = '';
  private static linear: NativeRawDecodeResult | null = null;
  private static linearSource: string = '';
  private static linearDimension: number = 0;
  private static plans: Map<string, RenderTables> = new Map();
  private static readonly DCP_CACHE_MAX: number = 3;
  private static dcpPixels: Map<string, ArrayBuffer> = new Map();
  private static profileSignatures: Map<DcpProfileData, string> = new Map();
  private static profileSerial: number = 0;
  private static pending: Map<string, Promise<NativeRawDecodeResult>> = new Map();
  private static generation: number = 0;

  static clearCache(): void {
    // A decode can still be in flight when an editor page is left. Invalidate
    // that generation so a late result cannot repopulate the next image's
    // linear/DCP cache or become visible after the session was disposed.
    RawNativeBridge.generation++;
    RawNativeBridge.linearKey = ''; RawNativeBridge.linear = null;
    RawNativeBridge.linearSource = ''; RawNativeBridge.plans.clear();
    RawNativeBridge.dcpPixels.clear();
    RawNativeBridge.profileSignatures.clear();
    RawNativeBridge.pending.clear();
  }

  static hasCachedPreview(sourceKey: string): boolean {
    return RawNativeBridge.linear !== null && RawNativeBridge.linearSource === sourceKey &&
      RawNativeBridge.linearDimension > 0;
  }

  static async reprocessPreview(sourceKey: string, profile: DcpProfileData | null,
    kelvin: number, tint: number): Promise<NativeRawDecodeResult | RawDecodeFailure | null> {
    if (!RawNativeBridge.hasCachedPreview(sourceKey)) return null;
    // The exact original dimension avoids a 1280-vs-screen-size cache miss.
    return RawNativeBridge.decodeRw2(new ArrayBuffer(0), RawNativeBridge.linearDimension,
      profile, kelvin, tint, sourceKey);
  }

  static async decodeRw2(data: ArrayBuffer, maxDimension: number,
    profile: DcpProfileData | null, kelvin: number=0, tint: number=0, sourceKey: string = ''): Promise<NativeRawDecodeResult | RawDecodeFailure | null> {
    const generation = RawNativeBridge.generation;
    const begin = Date.now();
    try {
      const options: Record<string, Object> = {};
      if (maxDimension > 0) options.maxDimension = maxDimension;
      const key = sourceKey.length > 0 ? sourceKey + ':' + maxDimension : '';
      let result = key && key === RawNativeBridge.linearKey ? RawNativeBridge.linear : null;
      const linearHit = result !== null;
      if (!result) {
        let pending = key ? RawNativeBridge.pending.get(key) : undefined;
        if (!pending) {
          pending = rawNative.decodeRw2(data, options) as Promise<NativeRawDecodeResult>;
          if (key) RawNativeBridge.pending.set(key, pending);
        }
        try { result = await pending; } finally {
          if (key && RawNativeBridge.pending.get(key) === pending) RawNativeBridge.pending.delete(key);
        }
      }
      if (generation !== RawNativeBridge.generation) return null;
      console.info(`VIVID_RAW_PERF stage=native ms=${Date.now()-begin} cache=${linearHit} max=${maxDimension}`);
      if (!result) {
        return { status: RawDecodeStatus.Unknown, message: 'native decode returned no result', diagnostics: '' };
      }
      if (result.status !== RawDecodeStatus.Ok) {
        const failure: RawDecodeFailure = {
          status: result.status,
          message: result.message.length > 0 ? result.message : 'LibRaw decode failed',
          diagnostics: result.diagnostics,
        };
        console.error(`VIVID_RAW_FAIL status=${failure.status} (${rawDecodeStatusLabel(failure.status)}) msg=${failure.message} ${failure.diagnostics}`);
        return failure;
      }
      if (!result.linearPixels || result.width <= 0 || result.height <= 0) {
        const failure: RawDecodeFailure = {
          status: RawDecodeStatus.Unknown,
          message: 'invalid native result',
          diagnostics: `size=${result.width}x${result.height} status=${result.status}`,
        };
        console.error(`VIVID_RAW_FAIL status=${failure.status} (UNKNOWN) msg=${failure.message} ${failure.diagnostics}`);
        return failure;
      }
      if (result.linearCameraRgb !== 1) throw new Error('Native RAW contract mismatch: unbalanced camera RGB required');
      if(result.linearPixels.byteLength!==result.width*result.height*12)throw new Error('Invalid Native linear RGB length');
      // A null profile requests the open-source classic rendering: build it
      // from the per-camera matrix LibRaw derived for this exact file.
      let active: DcpProfileData | null = profile;
      if (active === null) {
        const matrix = result.camToSrgb;
        if (!matrix || matrix.length !== 9 || !matrix.some((n: number): boolean => n !== 0)) {
          const failure: RawDecodeFailure = {
            status: RawDecodeStatus.Unknown,
            message: 'camera color matrix unavailable for classic rendering',
            diagnostics: `model=${result.model}`,
          };
          console.error(`VIVID_RAW_FAIL status=${failure.status} (UNKNOWN) msg=${failure.message} ${failure.diagnostics}`);
          return failure;
        }
        active = classicDcp(matrix);
      }
      // Bound retained linear camera RGB to 64 MiB; full-size export buffers
      // remain transient. Post-grading parameters are deliberately not keys.
      const cacheable = key.length > 0 && result.linearPixels.byteLength <= 64 * 1024 * 1024;
      if (cacheable) {
        if (RawNativeBridge.linearKey !== key) { RawNativeBridge.plans.clear(); RawNativeBridge.dcpPixels.clear(); }
        RawNativeBridge.linearKey = key; RawNativeBridge.linear = result;
        RawNativeBridge.linearSource = sourceKey; RawNativeBridge.linearDimension = maxDimension;
      }
      let signature = RawNativeBridge.profileSignatures.get(active);
      if (!signature) {
        // A cheap content signature: file profiles are cached by identity
        // (cpuData()), while classic profiles are rebuilt per call and only
        // carry a matrix. Stringifying a 69k-entry look table per render
        // would cost far more than the render plan itself.
        if (active.classicMatrix) {
          signature = 'classic:' + active.classicMatrix.join(',') + ':' + active.exposure;
        } else {
          RawNativeBridge.profileSerial++;
          signature = 'dcp:' + RawNativeBridge.profileSerial;
        }
        if (RawNativeBridge.profileSignatures.size > 4) RawNativeBridge.profileSignatures.clear();
        RawNativeBridge.profileSignatures.set(active, signature);
      }
      const dcpKey = key + ':' + signature + ':' + kelvin + ':' + tint;
      let pixels: ArrayBuffer;
      const hit: ArrayBuffer | undefined = cacheable ? RawNativeBridge.dcpPixels.get(dcpKey) : undefined;
      if (hit !== undefined) {
        pixels = hit;
        // Refresh recency so the least recently used frame is evicted first.
        RawNativeBridge.dcpPixels.delete(dcpKey);
        RawNativeBridge.dcpPixels.set(dcpKey, pixels);
      } else {
        const dcpBegin = Date.now();
        const width = result.width, height = result.height;
        let plan = cacheable ? RawNativeBridge.plans.get(dcpKey) : undefined;
        if (!plan) {
          plan = buildDcpRenderPlan(active, result.cameraNeutral, kelvin, tint);
          if (cacheable) {
            if (RawNativeBridge.plans.size >= 4) RawNativeBridge.plans.clear();
            RawNativeBridge.plans.set(dcpKey, plan);
          }
        }
        // Build interpolation/tone tables once, then copy their typed storage
        // per task so TaskPool cannot detach another band's or cache's plan.
        // Band-parallel rendering for every large frame: a single-task
        // full-size DCP pass takes 30s+ on a 24MP export and blocks the
        // whole batch pipeline behind one worker.
        const bands = height >= 512 ? 4 : 1;
        if (bands === 1) {
          // Always hand the worker a private copy: the pending map can share
          // one decode result between callers, and a transferable original
          // would detach it for everyone else.
          const linear = result.linearPixels.slice(0);
          pixels = await taskpool.execute(new taskpool.Task(processDcp, linear,
            cloneDcpRenderPlan(plan))) as ArrayBuffer;
        } else {
          const rowsPer = Math.ceil(height / bands);
          const running: Array<Promise<Object>> = [];
          for (let b = 0; b < bands; b++) {
            const y0 = b * rowsPer;
            if (y0 >= height) break;
            const rows = Math.min(rowsPer, height - y0);
            const band = result.linearPixels.slice(y0 * width * 12, (y0 + rows) * width * 12);
            running.push(taskpool.execute(new taskpool.Task(processDcp, band,
              cloneDcpRenderPlan(plan))));
          }
          const stitched = new Uint8Array(width * height * 4);
          let y0 = 0;
          for (let b = 0; b < running.length; b++) {
            const rows = Math.min(rowsPer, height - y0);
            const bandOut = await running[b] as ArrayBuffer;
            stitched.set(new Uint8Array(bandOut), y0 * width * 4);
            y0 += rows;
          }
          pixels = stitched.buffer as ArrayBuffer;
        }
        if (generation !== RawNativeBridge.generation) return null;
        console.info(`VIVID_RAW_PERF stage=dcp ms=${Date.now()-dcpBegin} classic=${profile === null} size=${result.width}x${result.height} bands=${bands}`);
        if (cacheable) {
          RawNativeBridge.dcpPixels.set(dcpKey, bands === 1 ? pixels.slice(0) : pixels);
          while (RawNativeBridge.dcpPixels.size > RawNativeBridge.DCP_CACHE_MAX) {
            let oldest: string | null = null;
            for (const k of RawNativeBridge.dcpPixels.keys()) { oldest = k; break; }
            if (oldest === null) break;
            RawNativeBridge.dcpPixels.delete(oldest);
          }
        }
      }
      return {
        // ImageSource may retain or transfer the input buffer. Cached frames
        // need a private copy to stay reusable; transient export buffers are
        // handed over directly to skip a ~100MB main-thread duplicate.
        pixels: cacheable ? pixels.slice(0) : pixels, linearPixels: new ArrayBuffer(0), cameraNeutral: result.cameraNeutral.slice(),
        camToSrgb: result.camToSrgb.slice(),
        width: result.width, height: result.height, sourceWidth: result.sourceWidth, sourceHeight: result.sourceHeight,
        model: result.model, blackLevel: result.blackLevel, whiteLevel: result.whiteLevel,
        bitDepth: result.bitDepth, linearCameraRgb: result.linearCameraRgb, dcpApplied: 1,
        status: RawDecodeStatus.Ok, message: '', diagnostics: '',
      };
    } catch (error) {
      const text = String(error);
      console.error(`VIVID_RAW_FAIL status=${RawDecodeStatus.Unknown} (UNKNOWN) msg=${text} js-exception`);
      return { status: RawDecodeStatus.Unknown, message: text, diagnostics: 'js-exception' };
    }
  }
}
