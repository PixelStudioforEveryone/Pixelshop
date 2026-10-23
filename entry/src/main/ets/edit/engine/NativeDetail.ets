/**
 * Thin ArkTS wrapper around the native detail stage (`libvivid_detail.so`).
 *
 * Why this exists: `LocalContrastCore.applyLocalContrast` measured 725 ms per
 * 512x341 preview frame on the device but only 20-47 ms on Node for the same
 * bytes, so the cost is the ArkTS interpreter, not the arithmetic. The native
 * module runs the identical pipeline from `vivid_detail_core.cpp`.
 *
 * Responsibilities, deliberately kept to these:
 *  - load the module and answer `nativeDetailReady()` once;
 *  - marshal one request and copy the result back into a Uint8ClampedArray;
 *  - log `VIVID_NATIVE_DETAIL fallback reason=...` and return null when the
 *    module is absent, the export is missing, the call throws, or the request
 *    cannot be served. The caller (`LocalContrastCore`) then runs the ArkTS
 *    implementation, so a device without this library still renders correctly.
 *
 * It contains NO algorithm: the reference stays in LocalContrastCore.ets, the
 * port stays in vivid_detail_core.cpp, and both are compared byte-for-byte by
 * tools/check_detail_native_parity.cjs.
 */
import detailNative from 'libvivid_detail.so';

/** Everything the native entry point needs, already resolved by the caller. */
export interface NativeDetailRequest {
  /** Guided-filter radius of the texture band, in pixels (`textureRadius`). */
  radiusTexture: number;
  /** Guided-filter radius of the clarity band, in pixels (`clarityRadius`). */
  radiusClarity: number;
  /** Box sigma of the sharpen low-pass, in pixels (`sharpenRadiusPixels`). */
  radiusSharpen: number;
  texture: number;
  clarity: number;
  dehaze: number;
  /** `0.3 * pow(|dehaze|, 1.3)`, precomputed here because `Math.pow` is
   *  engine-specific in the last ulp and the native side must reproduce it. */
  veil: number;
  sharpenAmount: number;
  sharpenDetail: number;
  sharpenMasking: number;
  hasHaze: boolean;
  hazeRed: number;
  hazeGreen: number;
  hazeBlue: number;
}

/** Reasons reported through `VIVID_NATIVE_DETAIL fallback reason=...`. */
const REASON_NO_MODULE: string = 'noModule';
const REASON_NO_EXPORT: string = 'noApplyExport';
const REASON_THREW: string = 'callThrew';
const REASON_NULL: string = 'nativeReturnedNull';
const REASON_SHORT_BUFFER: string = 'shortBuffer';

const reported: string[] = [];
let readyLogged: boolean = false;
let ready: boolean = false;

function moduleUsable(): boolean {
  // A build without this library, or with an older one, yields no `applyDetail`,
  // and every call must then take the ArkTS path instead of throwing per frame.
  return typeof detailNative.applyDetail === 'function';
}

/** True when the native detail stage can be called. Safe to call repeatedly. */
export function nativeDetailReady(): boolean {
  ready = moduleUsable();
  if (ready && !readyLogged) {
    readyLogged = true;
    let version: number = 0;
    try {
      version = detailNative.apiVersion();
    } catch (error) {
      version = 0;
    }
    console.info(`VIVID_NATIVE_DETAIL ready abi=${version}`);
  }
  return ready;
}

/** Log each distinct fallback reason once, so a 30 fps preview cannot flood hilog. */
function reportFallback(reason: string, detail: string = ''): void {
  const key = `${reason}|${detail}`;
  for (const seen of reported) {
    if (seen === key) return;
  }
  reported.push(key);
  console.warn(`VIVID_NATIVE_DETAIL fallback reason=${reason}` + (detail.length > 0 ? ` detail=${detail}` : ''));
}

/** Diagnostic counters for the render audit: native calls vs ArkTS fallbacks. */
export class NativeDetailStats {
  calls: number = 0;
  fallbacks: number = 0;
}

const stats: NativeDetailStats = new NativeDetailStats();

/** Snapshot of how often this process used native vs the ArkTS fallback. */
export function nativeDetailStats(): NativeDetailStats {
  const snapshot = new NativeDetailStats();
  snapshot.calls = stats.calls;
  snapshot.fallbacks = stats.fallbacks;
  return snapshot;
}

/** The underlying ArrayBuffer of a view, copied only when the view is a subrange. */
function bufferOf(rgba: Uint8ClampedArray): ArrayBuffer | null {
  if (rgba.byteOffset === 0 && rgba.byteLength === rgba.buffer.byteLength) {
    return rgba.buffer as ArrayBuffer;
  }
  // The ArkTS implementation indexes the view, not its backing store, so a
  // subarray has to be materialised before the same bytes can be handed over.
  const copy = rgba.slice();
  if (copy.byteLength === 0) return null;
  return copy.buffer as ArrayBuffer;
}

/**
 * Run the native detail stage, or return null so the caller can run the ArkTS
 * implementation. Never throws: every failure is logged and reported as null.
 */
export function nativeDetailApply(rgba: Uint8ClampedArray, width: number, height: number,
  request: NativeDetailRequest): Uint8ClampedArray | null {
  if (!nativeDetailReady()) {
    reportFallback(REASON_NO_EXPORT, REASON_NO_MODULE);
    stats.fallbacks++;
    return null;
  }
  if (width <= 0 || height <= 0) return null;
  let buffer: ArrayBuffer | null = null;
  try {
    buffer = bufferOf(rgba);
  } catch (error) {
    reportFallback(REASON_THREW, `buffer:${(error as Error).message ?? error}`);
    stats.fallbacks++;
    return null;
  }
  if (buffer === null) {
    reportFallback(REASON_SHORT_BUFFER);
    stats.fallbacks++;
    return null;
  }
  try {
    const result: ArrayBuffer | null = detailNative.applyDetail(buffer, width, height,
      request.radiusTexture, request.radiusClarity, request.radiusSharpen,
      request.texture, request.clarity, request.dehaze, request.veil,
      request.sharpenAmount, request.sharpenDetail, request.sharpenMasking,
      request.hasHaze, request.hazeRed, request.hazeGreen, request.hazeBlue);
    const bytes = width * height * 4;
    if (!result || result.byteLength !== bytes) {
      reportFallback(REASON_NULL, `bytes=${result ? result.byteLength : -1}/${bytes}`);
      stats.fallbacks++;
      return null;
    }
    stats.calls++;
    return new Uint8ClampedArray(result);
  } catch (error) {
    reportFallback(REASON_THREW, `${(error as Error).message ?? error}`);
    stats.fallbacks++;
    return null;
  }
}

/**
 * Whole-frame haze colour `[r, g, b]`, or null when native cannot serve it (the
 * caller then runs `dehazeHazeColor`'s own estimator). Used both by the detail
 * stage's internal estimate and by the magnified-tile path, which needs the
 * whole frame's colour.
 */
export function nativeDetailHazeColor(rgba: Uint8ClampedArray, width: number, height: number): number[] | null {
  if (!nativeDetailReady()) {
    reportFallback(REASON_NO_EXPORT, 'noHazeExport');
    return null;
  }
  if (width <= 0 || height <= 0) return null;
  if (rgba.byteLength < width * height * 4) {
    reportFallback(REASON_SHORT_BUFFER, 'haze');
    return null;
  }
  try {
    let buffer: ArrayBuffer | null = null;
    buffer = bufferOf(rgba);
    if (buffer === null) return null;
    const color: number[] | null = detailNative.hazeColor(buffer, width, height);
    if (!color || color.length !== 3) {
      reportFallback(REASON_NULL, 'haze');
      return null;
    }
    return color;
  } catch (error) {
    reportFallback(REASON_THREW, `haze:${(error as Error).message ?? error}`);
    return null;
  }
}
