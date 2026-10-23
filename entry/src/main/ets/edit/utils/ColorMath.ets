/**
 * Small colour helpers for building gradient stops that match a base colour's
 * hue / saturation / lightness behaviour in the mixer and calibration panels.
 */
export class ColorMath {
  static hslToHex(hue: number, saturation: number, lightness: number): string {
    const rgb = ColorMath.hslToRgb(hue, Math.max(0, Math.min(1, saturation)), Math.max(0, Math.min(1, lightness)));
    return ColorMath.rgbToHex(rgb[0], rgb[1], rgb[2]);
  }

  static shiftHue(hex: string, degrees: number): string {
    const rgb = ColorMath.hexToRgb(hex);
    const hsl = ColorMath.rgbToHsl(rgb[0], rgb[1], rgb[2]);
    hsl[0] = ((hsl[0] + degrees) % 360 + 360) % 360;
    const shifted = ColorMath.hslToRgb(hsl[0], hsl[1], hsl[2]);
    return ColorMath.rgbToHex(shifted[0], shifted[1], shifted[2]);
  }

  static scaleSaturation(hex: string, factor: number): string {
    const rgb = ColorMath.hexToRgb(hex);
    const hsl = ColorMath.rgbToHsl(rgb[0], rgb[1], rgb[2]);
    hsl[1] = Math.max(0, Math.min(1, hsl[1] * factor));
    const scaled = ColorMath.hslToRgb(hsl[0], hsl[1], hsl[2]);
    return ColorMath.rgbToHex(scaled[0], scaled[1], scaled[2]);
  }

  static scaleLightness(hex: string, factor: number): string {
    const rgb = ColorMath.hexToRgb(hex);
    const hsl = ColorMath.rgbToHsl(rgb[0], rgb[1], rgb[2]);
    hsl[2] = Math.max(0, Math.min(1, hsl[2] * factor));
    const scaled = ColorMath.hslToRgb(hsl[0], hsl[1], hsl[2]);
    return ColorMath.rgbToHex(scaled[0], scaled[1], scaled[2]);
  }

  private static hexToRgb(hex: string): number[] {
    const clean = hex.replace('#', '');
    const value = parseInt(clean, 16);
    return [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff];
  }

  private static rgbToHex(red: number, green: number, blue: number): string {
    const r = Math.round(red).toString(16).padStart(2, '0');
    const g = Math.round(green).toString(16).padStart(2, '0');
    const b = Math.round(blue).toString(16).padStart(2, '0');
    return `#${r}${g}${b}`;
  }

  private static rgbToHsl(red: number, green: number, blue: number): number[] {
    const r = red / 255;
    const g = green / 255;
    const b = blue / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const lightness = (max + min) / 2;
    const delta = max - min;
    if (delta === 0) return [0, 0, lightness];
    const saturation = delta / (1 - Math.abs(2 * lightness - 1));
    let hue = 0;
    if (max === r) hue = ((g - b) / delta) % 6;
    else if (max === g) hue = (b - r) / delta + 2;
    else hue = (r - g) / delta + 4;
    hue = (hue / 6) * 360;
    return [(hue + 360) % 360, saturation, lightness];
  }

  private static hslToRgb(hue: number, saturation: number, lightness: number): number[] {
    const h = ((hue % 360) + 360) % 360 / 360;
    const c = (1 - Math.abs(2 * lightness - 1)) * saturation;
    const hp = h * 6;
    const x = c * (1 - Math.abs((hp % 2) - 1));
    let r1 = 0;
    let g1 = 0;
    let b1 = 0;
    if (hp < 1) { r1 = c; g1 = x; }
    else if (hp < 2) { r1 = x; g1 = c; }
    else if (hp < 3) { g1 = c; b1 = x; }
    else if (hp < 4) { g1 = x; b1 = c; }
    else if (hp < 5) { r1 = x; b1 = c; }
    else { r1 = c; b1 = x; }
    const m = lightness - c / 2;
    return [(r1 + m) * 255, (g1 + m) * 255, (b1 + m) * 255];
  }
}
