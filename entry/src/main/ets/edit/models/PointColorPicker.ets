/**
 * Point-colour eyedropper: read ONE real source pixel for a sample.
 *
 * This is deliberately the same data path the white-balance picker documents
 * (see WhiteBalancePickerCore / WhiteBalanceSampling): the caller maps the tap
 * through the shared geometry transform into SOURCE normalized coordinates
 * (`EditSession.displayPointToSource`), and the pixel is read from the decoded
 * source PixelMap — not from the graded preview thumbnail, whose coordinates
 * would need a second, approximate mapping back to the photo.
 *
 * The bytes come from `PixelMap.readPixelsToBuffer`, the same call the render
 * pipeline and the range-mask proxy use, so the RGBA channel order here is
 * byte-identical to the one the worker grades. A 1x1 `readPixels` region was
 * rejected because that provider path has a different channel order on some
 * devices (RegionPixels swaps R/B for exactly that reason), which would make a
 * sample silently the wrong colour on half the fleet.
 *
 * The read is cached per source PixelMap identity: a pick costs one decode-sized
 * read per photo, not one per tap. The cache never owns the PixelMap (the page
 * does), so it must not release it; a new photo simply fails the identity check
 * and replaces the bytes.
 */
import { image } from '@kit.ImageKit';

export class PointColorPicker {
  private static cachedSource: image.PixelMap | null = null;
  private static cachedWidth: number = 0;
  private static cachedHeight: number = 0;
  private static cachedPixels: Uint8ClampedArray | null = null;
  /** Bumped whenever the cache is dropped or a newer read starts, so a read
   *  that completes after the photo changed cannot publish stale bytes. */
  private static readGeneration: number = 0;

  /** Forget the cached source bytes; the next pick re-reads the current photo. */
  static invalidate(): void {
    PointColorPicker.cachedSource = null;
    PointColorPicker.cachedWidth = 0;
    PointColorPicker.cachedHeight = 0;
    PointColorPicker.cachedPixels = null;
    PointColorPicker.readGeneration++;
  }

  /**
   * The RGB of the pixel that a normalized SOURCE point lands on.
   *
   * `sourceX`/`sourceY` are 0..1 over the decoded source image (the output of
   * `EditSession.displayPointToSource`). Returns null when there is no source,
   * the read failed, or the point is outside the image; it never invents a
   * colour. The exact pixel is returned (no average), so a sample's hue,
   * saturation and luminance are the values at the tapped location.
   */
  static async samplePixel(source: image.PixelMap | null,
    sourceX: number, sourceY: number): Promise<number[] | null> {
    if (!source) return null;
    if (!Number.isFinite(sourceX) || !Number.isFinite(sourceY)) return null;
    if (sourceX < 0 || sourceX > 1 || sourceY < 0 || sourceY > 1) return null;
    const pixels = await PointColorPicker.ensurePixels(source);
    if (pixels === null) return null;
    return PointColorPicker.pixelAt(pixels, PointColorPicker.cachedWidth,
      PointColorPicker.cachedHeight, sourceX, sourceY);
  }

  /**
   * Read the exact pixel at a normalized point from an RGBA buffer.
   *
   * Pure and separately testable: it is the only place that decides which pixel
   * a normalized coordinate means, so a test can hand it a known buffer and
   * prove that the sample is the tapped pixel rather than a neighbour or a
   * default colour.
   */
  static pixelAt(pixels: Uint8ClampedArray, width: number, height: number,
    sourceX: number, sourceY: number): number[] | null {
    if (!pixels || width <= 0 || height <= 0) return null;
    if (!Number.isFinite(sourceX) || !Number.isFinite(sourceY)) return null;
    if (sourceX < 0 || sourceX > 1 || sourceY < 0 || sourceY > 1) return null;
    const x = Math.max(0, Math.min(width - 1, Math.floor(sourceX * width)));
    const y = Math.max(0, Math.min(height - 1, Math.floor(sourceY * height)));
    const offset = (y * width + x) * 4;
    if (offset + 3 >= pixels.length) return null;
    // A fully transparent pixel carries no colour; treating it as black would
    // plant a sample the user never pointed at.
    if (pixels[offset + 3] === 0) return null;
    return [pixels[offset], pixels[offset + 1], pixels[offset + 2]];
  }

  private static async ensurePixels(source: image.PixelMap): Promise<Uint8ClampedArray | null> {
    if (PointColorPicker.cachedSource === source && PointColorPicker.cachedPixels !== null) {
      return PointColorPicker.cachedPixels;
    }
    const generation = ++PointColorPicker.readGeneration;
    let width = 0;
    let height = 0;
    try {
      const info = await source.getImageInfo();
      width = info.size.width;
      height = info.size.height;
    } catch (_error) {
      return null;
    }
    if (width <= 0 || height <= 0) return null;
    const buffer = new ArrayBuffer(width * height * 4);
    try {
      await source.readPixelsToBuffer(buffer);
    } catch (_error) {
      return null;
    }
    // A newer read (or an explicit invalidate) superseded this one while it was
    // in flight: publishing now would associate the old photo's bytes with the
    // new PixelMap identity.
    if (generation !== PointColorPicker.readGeneration) return null;
    PointColorPicker.cachedSource = source;
    PointColorPicker.cachedWidth = width;
    PointColorPicker.cachedHeight = height;
    PointColorPicker.cachedPixels = new Uint8ClampedArray(buffer);
    return PointColorPicker.cachedPixels;
  }
}
