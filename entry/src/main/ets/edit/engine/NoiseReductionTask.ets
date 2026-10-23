import { DenoiseValues } from '../models/DenoiseSettings';
import { denoiseRows } from './NoiseReduction';
import { processBehaviors, PROCESS_VERSION_LEGACY } from '../models/ProcessVersion';

export interface DenoiseTaskParams {
  source: ArrayBuffer;
  width: number;
  height: number;
  settings: DenoiseValues;
  /** Algorithm generation for this photo; omitted resolves to LEGACY. */
  processVersion?: number;
}

@Concurrent
export function denoiseTask(params: DenoiseTaskParams): ArrayBuffer {
  const source = new Uint8ClampedArray(params.source);
  if (source.length !== params.width * params.height * 4) throw new Error('Invalid denoise dimensions');
  const output = new Uint8ClampedArray(source.length);
  const behaviors = processBehaviors(params.processVersion ?? PROCESS_VERSION_LEGACY);
  denoiseRows(source, output, params.width, params.height, params.settings, 0, params.height, true,
    behaviors.denoiseFixedRadius);
  return output.buffer as ArrayBuffer;
}
