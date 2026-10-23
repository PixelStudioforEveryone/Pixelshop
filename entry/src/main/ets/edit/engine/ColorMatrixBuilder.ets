import { ColorAdjustments } from '../models/Adjustment';

const LumR = 0.2126;
const LumG = 0.7152;
const LumB = 0.0722;

/**
 * Builds a combined 4x5 color matrix from ColorAdjustments.
 * Matrix layout (row-major, 20 floats):
 *   [ a, b, c, d, e,    // R' = a*R + b*G + c*B + d*A + e
 *     f, g, h, i, j,    // G' = f*R + g*G + h*B + i*A + j
 *     k, l, m, n, o,    // B' = k*R + l*G + m*B + n*A + o
 *     p, q, r, s, t ]   // A' = p*R + q*G + r*B + s*A + t
 */
export class ColorMatrixBuilder {
  static build(adj: ColorAdjustments): Float32Array {
    let m = ColorMatrixBuilder.identity();

    // Exposure is non-affine in encoded sRGB. WorkerCore and the native
    // shader apply its gain in linear light, together with white balance.
    // With column vectors, appending on the right applies the new matrix
    // first: C * B * S * H means hue -> saturation -> brightness -> contrast.
    if (adj.contrast !== 0) {
      m = ColorMatrixBuilder.multiply(m, ColorMatrixBuilder.contrastMatrix(adj.contrast));
    }
    if (adj.brightness !== 0) {
      m = ColorMatrixBuilder.multiply(m, ColorMatrixBuilder.brightnessMatrix(adj.brightness));
    }
    if (adj.saturation !== 0) {
      m = ColorMatrixBuilder.multiply(m, ColorMatrixBuilder.saturationMatrix(adj.saturation));
    }
    if (adj.hue !== 0) {
      m = ColorMatrixBuilder.multiply(m, ColorMatrixBuilder.hueMatrix(adj.hue));
    }

    return m;
  }

  static identity(): Float32Array {
    return new Float32Array([
      1, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ]);
  }

  static contrastMatrix(value: number): Float32Array {
    const cf = 1 + value * 0.5; // [0.5..1.5]
    const t = (1 - cf) * 127.5;
    return new Float32Array([
      cf, 0, 0, 0, t,
      0, cf, 0, 0, t,
      0, 0, cf, 0, t,
      0, 0, 0, 1, 0,
    ]);
  }

  static brightnessMatrix(value: number): Float32Array {
    const b = value * 64; // [-64..+64]
    return new Float32Array([
      1, 0, 0, 0, b,
      0, 1, 0, 0, b,
      0, 0, 1, 0, b,
      0, 0, 0, 1, 0,
    ]);
  }

  static highlightsMatrix(value: number): Float32Array {
    // 左拖（负值）压暗高光、右拖提亮，与阴影/白色方向一致。
    const s = 1 + value * 0.3;
    const offset = value * 15;
    return new Float32Array([
      s, 0, 0, 0, offset,
      0, s, 0, 0, offset,
      0, 0, s, 0, offset,
      0, 0, 0, 1, 0,
    ]);
  }

  static shadowsMatrix(value: number): Float32Array {
    const s = 1 + value * 0.3;
    const offset = value * 20;
    return new Float32Array([
      s, 0, 0, 0, offset,
      0, s, 0, 0, offset,
      0, 0, s, 0, offset,
      0, 0, 0, 1, 0,
    ]);
  }

  static whitesMatrix(value: number): Float32Array {
    const s = 1 + value * 0.2;
    const offset = value * 25;
    return new Float32Array([
      s, 0, 0, 0, offset,
      0, s, 0, 0, offset,
      0, 0, s, 0, offset,
      0, 0, 0, 1, 0,
    ]);
  }

  static blacksMatrix(value: number): Float32Array {
    // 左拖（负值）压暗黑色、右拖提亮，与阴影/白色方向一致。
    const s = 1 + value * 0.2;
    const offset = value * 15;
    return new Float32Array([
      s, 0, 0, 0, offset,
      0, s, 0, 0, offset,
      0, 0, s, 0, offset,
      0, 0, 0, 1, 0,
    ]);
  }

  static saturationMatrix(value: number): Float32Array {
    const s = 1 + value; // [0..2]
    const lr = LumR;
    const lg = LumG;
    const lb = LumB;
    return new Float32Array([
      (1 - s) * lr + s, (1 - s) * lg, (1 - s) * lb, 0, 0,
      (1 - s) * lr, (1 - s) * lg + s, (1 - s) * lb, 0, 0,
      (1 - s) * lr, (1 - s) * lg, (1 - s) * lb + s, 0, 0,
      0, 0, 0, 1, 0,
    ]);
  }

  static vibranceMatrix(value: number): Float32Array {
    // Vibrance: milder saturation, affects less-saturated colors more
    const s = 1 + value * 0.5;
    const lr = LumR;
    const lg = LumG;
    const lb = LumB;
    return new Float32Array([
      (1 - s) * 0.7 * lr + s, (1 - s) * 0.7 * lg, (1 - s) * 0.7 * lb, 0, 0,
      (1 - s) * 0.7 * lr, (1 - s) * 0.7 * lg + s, (1 - s) * 0.7 * lb, 0, 0,
      (1 - s) * 0.7 * lr, (1 - s) * 0.7 * lg, (1 - s) * 0.7 * lb + s, 0, 0,
      0, 0, 0, 1, 0,
    ]);
  }

  static temperatureMatrix(value: number): Float32Array {
    // ±30% 的红/蓝通道摆幅：色温效果清晰可见（原 ±15% 在暖色预设上几乎无感）。
    const tf = value * 0.3;
    return new Float32Array([
      1 + tf, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1 - tf, 0, 0,
      0, 0, 0, 1, 0,
    ]);
  }

  static tintMatrix(value: number): Float32Array {
    // Green/magenta axis: positive (right) = green, matching the slider
    // gradient. Kept luma-neutral to first order: green gains 2x what red and
    // blue lose, so a neutral pixel does not change brightness.
    const tf = value * 0.24;
    return new Float32Array([
      1 - tf * 0.5, 0, 0, 0, 0,
      0, 1 + tf, 0, 0, 0,
      0, 0, 1 - tf * 0.5, 0, 0,
      0, 0, 0, 1, 0,
    ]);
  }

  static hueMatrix(degrees: number): Float32Array {
    const rad = (degrees * Math.PI) / 180;
    const c = Math.cos(rad);
    const s = Math.sin(rad);
    const lr = LumR;
    const lg = LumG;
    const lb = LumB;
    // Hue rotation must preserve neutral RGB and the chosen luminance.
    // Derive the green sine row from lr*Kred + lg*Kgreen + lb*Kblue=0;
    // using lr/lg/-lb here tinted every grey pixel green.
    const greenSinR = (lr * lr + lb * (1 - lr)) / lg;
    const greenSinG = lr - lb;
    const greenSinB = -(lr * (1 - lb) + lb * lb) / lg;

    return new Float32Array([
      lr + (1 - lr) * c - lr * s, lg - lg * c - lg * s, lb - lb * c + (1 - lb) * s, 0, 0,
      lr - lr * c + greenSinR * s, lg + (1 - lg) * c + greenSinG * s, lb - lb * c + greenSinB * s, 0, 0,
      lr - lr * c - (1 - lr) * s, lg - lg * c + lg * s, lb + (1 - lb) * c + lb * s, 0, 0,
      0, 0, 0, 1, 0,
    ]);
  }

  /** Multiply two 4x5 matrices: C = A * B (A applied after B) */
  static multiply(a: Float32Array, b: Float32Array): Float32Array {
    const out = new Float32Array(20);
    for (let row = 0; row < 4; row++) {
      for (let col = 0; col < 5; col++) {
        let sum = 0;
        for (let k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        if (col === 4) {
          sum += a[row * 5 + 4]; // the +e term from A
        }
        out[row * 5 + col] = sum;
      }
    }
    return out;
  }

  static isIdentity(m: Float32Array): boolean {
    const id = ColorMatrixBuilder.identity();
    for (let i = 0; i < 20; i++) {
      if (Math.abs(m[i] - id[i]) > 0.001) return false;
    }
    return true;
  }
}
