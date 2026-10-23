import { CustomLut, LutTable } from './LutLibrary';

/**
 * 尼康 NP3（优化校准 / 云创方案）解析。
 *
 * 文件结构：`NCP` 头 + 一串键值项，每项 `00 00 | id | 00 00 00 00 | len(1B) | value`。
 * - id=0x02：方案名（20 字节，\0 结尾）
 * - id=0x1F：色彩混合器，8 组 × 3 字节，0x80 为中性
 * - 978 字节的文件末尾多一张 256 点、每点 uint16(BE) 的自定义色调曲线
 *   （最后 514 字节 = 512 字节曲线 + 2 字节终止符）
 *
 * 因此：带曲线的方案可以按官方曲线精确还原；只有参数的方案（392 字节）
 * 只能拿混合器做近似——两者在卡片上分别标注，方便后续对着官方效果图校准。
 */
export interface Np3Look {
  name: string;
  /** 是否带官方自定义曲线。 */
  hasCurve: boolean;
  /** 256 点曲线，0..1；无曲线时为空。 */
  curve: number[];
  /** 8 组色彩混合，元素已归一为 -1..1。 */
  mixer: number[];
  bytes: number;
}

const CURVE_LEN: number = 256;
/** 0x1F 混合器 8 个色相中心（度）。 */
const MIX_HUES: number[] = [0, 45, 90, 135, 180, 225, 270, 315];
/** 近似强度上限：宁可轻，也不要出现明显偏色。 */
const HUE_STRENGTH: number = 0.05;
const SAT_STRENGTH: number = 0.30;
const LUM_STRENGTH: number = 0.08;

export function parseNp3(raw: Uint8Array): Np3Look {
  const look: Np3Look = { name: '', hasCurve: false, curve: [], mixer: [], bytes: raw.length };
  let p = 16;
  while (p + 8 <= raw.length) {
    if (raw[p] !== 0 || raw[p + 1] !== 0) {
      p += 1;
      continue;
    }
    const id = raw[p + 2];
    const len = raw[p + 7];
    if (id === 0 || len === 0 || len > 64 || p + 8 + len > raw.length) {
      p += 1;
      continue;
    }
    if (id === 0x02 && look.name.length === 0) {
      let name = '';
      for (let i = 0; i < len; i++) {
        const code = raw[p + 8 + i];
        if (code === 0) break;
        name += String.fromCharCode(code);
      }
      look.name = name;
    } else if (id === 0x1f && len >= 24) {
      const mixer: number[] = [];
      for (let i = 0; i < 24; i++) mixer.push((raw[p + 8 + i] - 128) / 128);
      look.mixer = mixer;
    }
    p += 8 + len;
  }
  // 自定义曲线：文件末尾 256 个 uint16(BE) 曲线点，之后以 0 填充收尾。
  // 从最后一个非零字节往前取 512 字节最稳（不同文件尾部补零长度不一样）。
  let end = raw.length - 1;
  while (end > 0 && raw[end] === 0) end -= 1;
  const start = end - 511;
  if (start > 0x180 && start % 2 === 0) {
    const curve: number[] = [];
    for (let i = 0; i < CURVE_LEN; i++) {
      curve.push(((raw[start + i * 2] << 8) | raw[start + i * 2 + 1]) / 32767);
    }
    // 只有单调、且从暗到亮铺满的尾部才当成曲线，避免把其它数据误读成曲线。
    // 抬黑点/压白点的方案（哑光、褪色）黑点可到 0.16、白点 0.84，所以门槛放宽。
    if (curve[0] < 0.25 && curve[CURVE_LEN - 1] > 0.8 && isMonotonic(curve)) {
      look.curve = curve;
      look.hasCurve = true;
    }
  }
  return look;
}

function isMonotonic(curve: number[]): boolean {
  for (let i = 1; i < curve.length; i++) {
    if (curve[i] + 0.001 < curve[i - 1]) return false;
  }
  return true;
}

function sampleCurve(curve: number[], x: number): number {
  const pos = Math.max(0, Math.min(1, x)) * (curve.length - 1);
  const i = Math.floor(pos);
  if (i >= curve.length - 1) return curve[curve.length - 1];
  const t = pos - i;
  return curve[i] * (1 - t) + curve[i + 1] * t;
}

/** RGB(0..1) → HSL(0..1)。 */
function rgbToHsl(r: number, g: number, b: number): number[] {
  const max = Math.max(r, Math.max(g, b));
  const min = Math.min(r, Math.min(g, b));
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h = 0;
  if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
  else if (max === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  return [h / 6, s, l];
}

/** HSL(0..1) → RGB(0..1)。 */
function hslToRgb(h: number, s: number, l: number): number[] {
  const hue = ((h % 1) + 1) % 1;
  if (s <= 0) return [l, l, l];
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const channel = (t: number): number => {
    let x = t;
    if (x < 0) x += 1;
    if (x > 1) x -= 1;
    if (x < 1 / 6) return p + (q - p) * 6 * x;
    if (x < 1 / 2) return q;
    if (x < 2 / 3) return p + (q - p) * (2 / 3 - x) * 6;
    return p;
  };
  return [channel(hue + 1 / 3), channel(hue), channel(hue - 1 / 3)];
}

/** 只有参数的方案：按 8 个色相区做轻量色相/饱和/明度近似。 */
function mixerAdjust(r: number, g: number, b: number, mixer: number[]): number[] {
  if (mixer.length < 24) return [r, g, b];
  const hsl = rgbToHsl(r, g, b);
  let hue = hsl[0];
  let sat = hsl[1];
  let lum = hsl[2];
  const deg = hue * 360;
  for (let i = 0; i < 8; i++) {
    let diff = Math.abs(deg - MIX_HUES[i]);
    if (diff > 180) diff = 360 - diff;
    if (diff >= 45) continue;
    const weight = Math.cos(diff * Math.PI / 90);
    if (weight <= 0) continue;
    hue += mixer[i * 3] * HUE_STRENGTH * weight / 360;
    sat *= 1 + mixer[i * 3 + 1] * SAT_STRENGTH * weight;
    lum *= 1 + mixer[i * 3 + 2] * LUM_STRENGTH * weight;
  }
  sat = Math.max(0, Math.min(1, sat));
  lum = Math.max(0, Math.min(1, lum));
  return hslToRgb(hue, sat, lum);
}

/** 把方案烘成 3D LUT（r 变化最快，与 .cube 顺序一致）。 */
export function bakeNikonLut(look: Np3Look, size: number): LutTable {
  const values: number[] = [];
  const last = Math.max(1, size - 1);
  for (let bi = 0; bi < size; bi++) {
    for (let gi = 0; gi < size; gi++) {
      for (let ri = 0; ri < size; ri++) {
        let r = ri / last;
        let g = gi / last;
        let b = bi / last;
        if (look.hasCurve) {
          r = sampleCurve(look.curve, r);
          g = sampleCurve(look.curve, g);
          b = sampleCurve(look.curve, b);
        } else {
          const out = mixerAdjust(r, g, b, look.mixer);
          r = out[0];
          g = out[1];
          b = out[2];
        }
        values.push(Math.max(0, Math.min(1, r)));
        values.push(Math.max(0, Math.min(1, g)));
        values.push(Math.max(0, Math.min(1, b)));
      }
    }
  }
  return { size: size, values: values, domainMin: [0, 0, 0], domainMax: [1, 1, 1] };
}

/** 云创方案 → 编辑器可直接入栈的 LUT 条目（id 以 nikon: 前缀区分来源）。 */
export function nikonCloudLut(recipeId: string, name: string, look: Np3Look, size: number): CustomLut {
  return {
    id: 'nikon:' + recipeId,
    sourceUri: 'nikon://' + recipeId,
    name: name,
    sampleCount: size * size * size,
    category: '云创',
    author: '尼康云创',
    description: look.hasCurve ? '官方曲线' : '参数近似',
    adjustments: {},
    table: bakeNikonLut(look, size),
  };
}
