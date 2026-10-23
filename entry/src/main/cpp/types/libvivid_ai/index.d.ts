/**
 * Offline subject / sky segmentation, backed by ncnn (BSD-3-Clause).
 *
 * The module never reads the file system: the caller passes the .param and .bin
 * bytes that were read from rawfile, so packaging and hash provenance stay in
 * one place (AiMaskModels.ets / AiSegmentationService.ets).
 *
 * License and copyright of the models themselves:
 *   kind 0 SUBJECT  U^2-NetP, xuebinqin/U-2-Net, Apache-2.0
 *                   weights from the official danielgatis/rembg release
 *   kind 1 SKY      skysegsmall, xiongzhu666/Sky-Segmentation-and-Post-processing, MIT
 */

/** One model's static description. `modelInfo` performs no file or network access. */
export interface VividAiModelSpec {
  /** 0 = subject, 1 = sky. */
  kind: number;
  key: string;
  name: string;
  upstream: string;
  license: string;
  /** Square network input edge in pixels (320 for U^2-NetP, 384 for skysegsmall). */
  inputSize: number;
  inputBlob: string;
  outputBlob: string;
  /** U^2-NetP divides the [0,1] image by its global maximum; the sky net does not. */
  divideByGlobalMax: boolean;
  /**
   * U^2-NetP's reference rescales its output to the plane's own [min,max]; the
   * sky net emits a calibrated probability and is only clamped, so an empty
   * selection stays empty instead of being stretched to full coverage.
   */
  rescaleOutputToRange: boolean;
  backend: string;
}

/**
 * Load a model into a process-wide cache. Resolves once the network is ready and
 * is idempotent per kind; re-loading an already resident model is a no-op.
 */
export function loadModel(kind: number, param: ArrayBuffer, bin: ArrayBuffer): Promise<void>;

/**
 * Run segmentation on RGBA8888 pixels. Resolves to an ArrayBuffer laid out as
 * little-endian uint32 width, uint32 height, then width*height single-channel
 * alpha bytes. Subject alpha is min-max normalised (U^2-NetP normPRED); sky
 * alpha is the calibrated probability clamped to 0..255.
 */
export function segment(kind: number, rgba: ArrayBuffer, width: number, height: number): Promise<ArrayBuffer>;

/** True once this kind's network is resident and can serve `segment` without I/O. */
export function isLoaded(kind: number): boolean;

/** Static metadata for every supported model; used by the provenance screen. */
export function modelInfo(): VividAiModelSpec[];

/** Drop every cached network and its weight bytes. */
export function release(): void;

// ---------------------------------------------------------------------------
// Depth Anything V2 Small — used by the bokeh stage, not by the mask tool.
// ---------------------------------------------------------------------------

/**
 * Load the depth network from caller-supplied ncnn param/bin bytes. Idempotent;
 * the bytes are retained for the lifetime of the net.
 */
export function loadDepthModel(param: ArrayBuffer, bin: ArrayBuffer): Promise<void>;

/** True once the depth network is resident. */
export function depthLoaded(): boolean;

/**
 * Estimate a depth map from RGBA8888 pixels.
 *
 * Resolves to an ArrayBuffer laid out as little-endian uint32 width, uint32
 * height, then width*height single-channel bytes. Larger values are nearer.
 * `outputLongSide` bounds the returned sampling grid (32..512).
 */
export function estimateDepth(rgba: ArrayBuffer, width: number, height: number,
  outputLongSide: number): Promise<ArrayBuffer>;
