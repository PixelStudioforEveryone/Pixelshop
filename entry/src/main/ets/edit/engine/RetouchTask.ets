import { RetouchMark } from '../models/RetouchSettings';
import { retouchPixels } from './RetouchCore';
export interface RetouchTaskParams { source: ArrayBuffer; width: number; height: number; marks: RetouchMark[]; viewport: number[]; }
@Concurrent
export function retouchTask(params: RetouchTaskParams): ArrayBuffer {
  if (params.source.byteLength !== params.width * params.height * 4) throw new Error('Invalid retouch dimensions');
  return retouchPixels(new Uint8ClampedArray(params.source), params.width, params.height, params.marks, params.viewport).buffer as ArrayBuffer;
}
