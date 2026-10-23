import { image } from '@kit.ImageKit';
import { taskpool } from '@kit.ArkTS';

export interface RegionPixelsResult { pixels: ArrayBuffer; width: number; height: number; }

@Concurrent
export function sampleBgraBand(input: ArrayBuffer, sourceWidth: number, sourceTop: number,
  sourceHeight: number, outputWidth: number, outputTop: number, rows: number,
  ratioX: number, ratioY: number): ArrayBuffer {
  const src = new Uint8Array(input);
  const output = new Uint8Array(outputWidth * rows * 4);
  for (let y = 0; y < rows; y++) {
    const sy = Math.max(0, Math.min(sourceHeight - 1, (outputTop + y + 0.5) * ratioY - 0.5 - sourceTop));
    const y0 = Math.floor(sy), y1 = Math.min(sourceHeight - 1, y0 + 1), fy = sy - y0;
    for (let x = 0; x < outputWidth; x++) {
      const sx = Math.max(0, Math.min(sourceWidth - 1, (x + 0.5) * ratioX - 0.5));
      const x0 = Math.floor(sx), x1 = Math.min(sourceWidth - 1, x0 + 1), fx = sx - x0;
      for (let c = 0; c < 4; c++) {
        const channel = c === 0 ? 2 : (c === 2 ? 0 : c);
        const a = src[(y0 * sourceWidth + x0) * 4 + channel] * (1 - fx) + src[(y0 * sourceWidth + x1) * 4 + channel] * fx;
        const b = src[(y1 * sourceWidth + x0) * 4 + channel] * (1 - fx) + src[(y1 * sourceWidth + x1) * 4 + channel] * fx;
        output[(y * outputWidth + x) * 4 + c] = Math.round(a * (1 - fy) + b * fy);
      }
    }
  }
  return output.buffer as ArrayBuffer;
}

/** At most one narrow source strip and a 2048px output tile are resident. */
export class RegionPixels {
  static async read(source: image.PixelMap, x: number, y: number, width: number, height: number,
    maxEdge: number, stale: () => boolean): Promise<RegionPixelsResult | null> {
    const scale = Math.min(1, Math.max(256, Math.min(2048, maxEdge)) / Math.max(width, height));
    const w = Math.max(1, Math.round(width * scale)), h = Math.max(1, Math.round(height * scale));
    const result = new Uint8Array(w * h * 4);
    const rx = width / w, ry = height / h;
    // Bound provider copies to approximately 4 MiB even on large sensors.
    const bandRows = Math.max(1, Math.min(32, Math.floor(1048576 / (width * ry))));
    for (let row = 0; row < h; row += bandRows) {
      if (stale()) return null;
      const rows = Math.min(bandRows, h - row);
      const top = Math.max(0, Math.floor((row + 0.5) * ry - 0.5));
      const bottom = Math.min(height, Math.ceil((row + rows - 0.5) * ry - 0.5) + 2);
      const bytes = new ArrayBuffer(width * (bottom - top) * 4);
      await source.readPixels({ pixels: bytes, offset: 0, stride: width * 4,
        region: { x: x, y: y + top, size: { width: width, height: bottom - top } } });
      const sampled = await taskpool.execute(new taskpool.Task(sampleBgraBand, bytes, width, top,
        bottom - top, w, row, rows, rx, ry)) as ArrayBuffer;
      if (stale()) return null;
      result.set(new Uint8Array(sampled), row * w * 4);
    }
    return { pixels: result.buffer as ArrayBuffer, width: w, height: h };
  }
}
