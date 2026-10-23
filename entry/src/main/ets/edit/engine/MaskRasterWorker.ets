import {
  MaskWorkerLayer,
  MaskWorkerComponent,
  MaskWorkerStroke,
  MaskWorkerPoint,
  MaskRasterOutput,
  rasterizeStructuredMaskCore,
} from './MaskRasterCore';

export { MaskWorkerLayer, MaskWorkerComponent, MaskWorkerStroke, MaskWorkerPoint, MaskRasterOutput,
  rasterizeStructuredMaskCore } from './MaskRasterCore';

/** TaskPool entrypoint; all pixel helpers live in the imported pure module.
 * Stats collection is on here because the export diagnostics need the
 * per-component breakdown; the synchronous callers leave it off. */
@Concurrent
export function rasterizeStructuredMask(layer: MaskWorkerLayer, width: number, height: number): MaskRasterOutput {
  return rasterizeStructuredMaskCore(layer, width, height, true);
}
