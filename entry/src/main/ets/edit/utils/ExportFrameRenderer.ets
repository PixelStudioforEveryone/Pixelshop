import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { LengthMetricsUnit } from '@kit.ArkUI';

export interface ExportFrameOptions {
  enabled: boolean;
  style: string;
  brand: string;
  camera: string;
  fontSize: number;
  fontColor: string;
  lens: string;
  focalLength: string;
  aperture: string;
  shutter: string;
  iso: string;
  capturedAt?: string;
  showCamera?: boolean;
  showLens?: boolean;
  showFocalLength?: boolean;
  showAperture?: boolean;
  showShutter?: boolean;
  showIso?: boolean;
  showCapturedAt?: boolean;
}

/** One proportional canvas layout for both dialog previews and saved JPEGs. */
export class ExportFrameRenderer {
  static async render(base: image.PixelMap, frame: ExportFrameOptions,
    context: common.UIAbilityContext,
    isCancelled: () => boolean = (): boolean => false): Promise<image.PixelMap | null> {
    const info = await base.getImageInfo();
    const w = info.size.width;
    const h = info.size.height;
    const immersive = frame.style === '沉浸光感';
    const side = immersive ? Math.round(w * 0.0926) : 0;
    const width = w + side * 2;
    const top = immersive ? Math.round(width * 0.032) : 0;
    const footer = Math.round(width * (immersive ? 0.072 : 0.10));
    const height = top + h + footer;
    const canvas = new OffscreenCanvas(width, height, LengthMetricsUnit.PX);
    const ctx = canvas.getContext('2d', new RenderingContextSettings(true));
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    if (immersive) {
      // Native Gaussian filtering on a bounded surface avoids a JS pixel loop
      // and keeps the blur radius proportional at preview and export sizes.
      const bgW = Math.min(640, width);
      const bgH = Math.max(1, Math.round(height * bgW / width));
      const bgCanvas = new OffscreenCanvas(bgW, bgH, LengthMetricsUnit.PX);
      const bg = bgCanvas.getContext('2d', new RenderingContextSettings(true));
      const sigma = bgW * 0.024;
      const bleed = sigma * 3;
      const cover = Math.max((bgW + bleed * 2) / w, (bgH + bleed * 2) / h);
      bg.filter = `blur(${sigma}px)`;
      bg.drawImage(base, (bgW - w * cover) / 2, (bgH - h * cover) / 2, w * cover, h * cover);
      bg.filter = 'none';
      const bgScale = bgW / width;
      const shade = bg.createLinearGradient(0, (top + h - width * 0.07) * bgScale, 0, bgH);
      shade.addColorStop(0, 'rgba(0,0,0,0)');
      shade.addColorStop(1, 'rgba(0,0,0,0.28)');
      bg.fillStyle = shade;
      bg.fillRect(0, 0, bgW, bgH);
      // Rasterize the soft shadow on the bounded backdrop, not a 60 MP canvas.
      // Full-size Gaussian shadows can block Skia for >6 seconds on device.
      bg.shadowColor = 'rgba(0,0,0,0.56)';
      bg.shadowBlur = bgW * 0.026;
      bg.shadowOffsetY = bgW * 0.01;
      ExportFrameRenderer.roundedPath(bg, side * bgScale, top * bgScale, w * bgScale, h * bgScale, w * 0.025 * bgScale);
      bg.fillStyle = '#202020';
      bg.fill();
      const backdrop = bg.getPixelMap(0, 0, bgW, bgH);
      ctx.drawImage(backdrop, 0, 0, width, height);
      backdrop.release();
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
      const radius = w * 0.025;
      ctx.save();
      ExportFrameRenderer.roundedPath(ctx, side, top, w, h, radius);
      ctx.clip();
      if (await ExportFrameRenderer.drawImageInBands(ctx, base, side, top, w, h, isCancelled)) {
        return null;
      }
      ctx.restore();
      ExportFrameRenderer.immersiveLabels(ctx, frame, width, top + h, footer);
    } else {
      ctx.fillStyle = '#FFFFFF';
      ctx.fillRect(0, 0, width, height);
      if (await ExportFrameRenderer.drawImageInBands(ctx, base, 0, 0, w, h, isCancelled)) {
        return null;
      }
      await ExportFrameRenderer.classicLabels(ctx, frame, width, h, footer, context);
    }
    if (isCancelled()) return null;
    // Give ArkUI one scheduling point before the full-size canvas is copied
    // into a PixelMap. This keeps the progress layer responsive between the
    // expensive raster stages on phone-class devices.
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    if (isCancelled()) return null;
    return ctx.getPixelMap(0, 0, width, height);
  }

  /** Draw the source image in short strips, yielding between strips. A single
   * full-resolution drawImage can block the UI for several seconds on camera
   * originals; strip rendering keeps cancel/background actions serviceable. */
  private static async drawImageInBands(ctx: OffscreenCanvasRenderingContext2D,
    base: image.PixelMap, destX: number, destY: number, destW: number, destH: number,
    isCancelled: () => boolean): Promise<boolean> {
    const info = await base.getImageInfo();
    const sourceW = info.size.width;
    const sourceH = info.size.height;
    const bandHeight = Math.max(128, Math.min(384, Math.round(destH / 16)));
    for (let top = 0; top < destH; top += bandHeight) {
      if (isCancelled()) return true;
      const currentHeight = Math.min(bandHeight, destH - top);
      const sourceTop = sourceH * top / destH;
      const sourceHeight = sourceH * currentHeight / destH;
      ctx.drawImage(base, 0, sourceTop, sourceW, sourceHeight,
        destX, destY + top, destW, currentHeight);
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
    }
    return isCancelled();
  }

  private static roundedPath(ctx: OffscreenCanvasRenderingContext2D, x: number, y: number,
    w: number, h: number, r: number): void {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
  }

  private static cameraName(frame: ExportFrameOptions): string {
    const brand = frame.brand.trim();
    let model = frame.camera.trim();
    if (model.toLowerCase().indexOf(brand.toLowerCase() + ' ') === 0) model = model.substring(brand.length).trim();
    return model;
  }

  /** Shared by the form and both frame styles; empty metadata stays empty. */
  static formatParameter(field: string, value: string): string {
    const text = value.trim();
    if (!text) return '';
    switch (field) {
      case 'focalLength': return text.replace(/\s*mm$/i, '').trim() + 'mm';
      case 'aperture': return 'F' + text.replace(/^f\s*\/?\s*/i, '');
      case 'shutter': return text.replace(/\s*(s|秒)$/i, '').trim() + ' s';
      case 'iso': return 'ISO ' + text.replace(/^iso\s*/i, '');
      default: return text;
    }
  }

  private static parameters(frame: ExportFrameOptions): string {
    const values: string[] = [];
    if (frame.showFocalLength === true && frame.focalLength.trim()) {
      values.push(ExportFrameRenderer.formatParameter('focalLength', frame.focalLength));
    }
    if (frame.showAperture === true && frame.aperture.trim()) {
      values.push(ExportFrameRenderer.formatParameter('aperture', frame.aperture));
    }
    if (frame.showShutter === true && frame.shutter.trim()) {
      values.push(ExportFrameRenderer.formatParameter('shutter', frame.shutter));
    }
    if (frame.showIso === true && frame.iso.trim()) {
      values.push(ExportFrameRenderer.formatParameter('iso', frame.iso));
    }
    return values.join('  ');
  }

  private static immersiveLabels(ctx: OffscreenCanvasRenderingContext2D, frame: ExportFrameOptions,
    width: number, y: number, footer: number): void {
    let font = width * 0.016 * Math.max(12, Math.min(28, frame.fontSize)) / 16;
    const camera = frame.showCamera === true ?
      `${frame.brand.trim()} ${ExportFrameRenderer.cameraName(frame)}`.trim() : '';
    const params = ExportFrameRenderer.parameters(frame);
    const lines: string[] = [];
    if (camera) lines.push(camera);
    if (frame.showLens === true && frame.lens.trim()) lines.push(frame.lens.trim());
    if (params) lines.push(params);
    const date = (frame.capturedAt || '').trim();
    if (frame.showCapturedAt === true && date) lines.push(date);
    if (lines.length === 0) return;
    ctx.font = `bold ${font}px HarmonyOS Sans`;
    let widest = 1;
    for (const line of lines) widest = Math.max(widest, ctx.measureText(line).width);
    font *= Math.min(1, width * 0.84 / Math.max(1, widest));
    font = Math.min(font, footer * 0.8 / lines.length);
    ctx.fillStyle = '#FFFFFF';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'center';
    for (let index = 0; index < lines.length; index++) {
      ctx.font = `${index === 0 && camera ? 'bold ' : ''}${font}px HarmonyOS Sans`;
      ctx.fillText(lines[index], width / 2, y + footer * (index + 0.5) / lines.length);
    }
  }

  private static async classicLabels(ctx: OffscreenCanvasRenderingContext2D, frame: ExportFrameOptions,
    width: number, y: number, footer: number, context: common.UIAbilityContext): Promise<void> {
    const pad = width * 0.019;
    const leftWidth = width * 0.55;
    const rightX = width * 0.715;
    const rightWidth = width - pad - rightX;
    const lens = frame.showLens === true ? frame.lens.trim() : '';
    const camera = frame.showCamera === true ? `${frame.brand.trim()} ${ExportFrameRenderer.cameraName(frame)}`.trim() : '';
    const params = ExportFrameRenderer.parameters(frame);
    const date = frame.showCapturedAt === true ? (frame.capturedAt || '').trim() : '';
    let font = width * 0.021 * Math.max(12, Math.min(28, frame.fontSize)) / 16;
    ctx.font = `bold ${font}px HarmonyOS Sans`;
    const leftRatio = leftWidth / Math.max(1, ctx.measureText(lens).width, ctx.measureText(camera).width);
    const rightRatio = rightWidth / Math.max(1, ctx.measureText(params).width, ctx.measureText(date).width);
    font *= Math.min(1, leftRatio, rightRatio);
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.font = `bold ${font}px HarmonyOS Sans`;
    ctx.fillStyle = frame.fontColor || '#111111';
    const firstY = y + footer * 0.37;
    const secondY = y + footer * 0.66;
    if (lens) ctx.fillText(lens, pad, camera ? firstY : y + footer * 0.5);
    if (params) ctx.fillText(params, rightX, date.length > 0 ? firstY : y + footer * 0.5);
    ctx.font = `${font}px HarmonyOS Sans`;
    ctx.globalAlpha = 0.58;
    if (camera) ctx.fillText(camera, pad, lens ? secondY : y + footer * 0.5);
    if (date.length > 0) ctx.fillText(date, rightX, secondY);
    ctx.globalAlpha = 1;
    const dividerX = width * 0.695;
    if ((lens || camera) && (params || date)) {
      ctx.strokeStyle = '#999999';
      ctx.lineWidth = width * 0.001;
      ctx.beginPath();
      ctx.moveTo(dividerX, y + footer * 0.24);
      ctx.lineTo(dividerX, y + footer * 0.76);
      ctx.stroke();
    }
    const logo = frame.showCamera === true ? await ExportFrameRenderer.loadLogo(frame.brand, context) : null;
    if (logo) {
      try {
        const info = await logo.getImageInfo();
        const maxW = width * 0.086;
        const maxH = footer * 0.48;
        const scale = Math.min(maxW / info.size.width, maxH / info.size.height);
        const logoW = info.size.width * scale;
        const logoH = info.size.height * scale;
        ctx.drawImage(logo, dividerX - width * 0.02 - logoW, y + (footer - logoH) / 2, logoW, logoH);
      } finally {
        logo.release();
      }
    }
  }

  private static async loadLogo(brand: string, context: common.UIAbilityContext): Promise<image.PixelMap | null> {
    const files: Record<string, string> = {
      'panasonic': 'panasonic.png', 'nikon': 'nikon.png', 'sony': 'sony.png', 'canon': 'canon.png',
      'ricoh': 'ricoh.png', 'pentax': 'pentax.png', 'fujifilm': 'fujifilm.png', 'olympus': 'olympus_blue_gold.png',
      'leica': 'leica_logo.png', 'hasselblad': 'hasselblad.png', 'dji': 'DJI.jpg', 'apple': 'apple.png', 'xmage': 'xmage.png'
    };
    const name = files[brand.trim().toLowerCase()];
    if (!name) return null;
    try {
      const data = await context.resourceManager.getRawFileContent('logos/' + name);
      const source = image.createImageSource(data.buffer as ArrayBuffer);
      try {
        return await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      } finally {
        source.release();
      }
    } catch (_error) {
      return null;
    }
  }
}
