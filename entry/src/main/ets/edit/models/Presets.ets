import { ColorAdjustments } from './Adjustment';

export interface PresetAdjustments {
  exposure?: number;
  contrast?: number;
  brightness?: number;
  highlights?: number;
  shadows?: number;
  whites?: number;
  blacks?: number;
  saturation?: number;
  vibrance?: number;
  temperature?: number;
  tint?: number;
  hue?: number;
}

export interface Preset {
  name: string;
  adjustments: PresetAdjustments;
}

/**
 * Built-in color adjustment presets (like Lightroom presets).
 * Each preset provides a set of non-zero adjustment values.
 */
export const PRESETS: Preset[] = [
  {
    name: 'Teal Flat-S',
    adjustments: { contrast: -0.08, saturation: -0.12, temperature: -0.18, tint: -0.05, shadows: 0.2 },
  } as Preset,
  {
    name: 'Smoky Color-S',
    adjustments: { contrast: 0.12, saturation: -0.18, highlights: -0.28, shadows: 0.18, blacks: 0.12 },
  } as Preset,
  {
    name: 'Clear-S',
    adjustments: { contrast: 0.22, vibrance: 0.24, highlights: -0.12, whites: 0.1, blacks: -0.08 },
  } as Preset,
  {
    name: 'Backlight-N',
    adjustments: { exposure: 0.12, highlights: -0.42, shadows: 0.48, contrast: -0.06 },
  } as Preset,
  {
    name: 'Filmlike-V2',
    adjustments: { contrast: 0.2, saturation: -0.14, temperature: 0.12, highlights: -0.3, shadows: 0.24 },
  } as Preset,
  {
    name: 'Everything Golden',
    adjustments: { temperature: 0.38, tint: 0.08, highlights: -0.18, vibrance: 0.28 },
  } as Preset,
  {
    name: '鲜艳',
    adjustments: { saturation: 0.3, vibrance: 0.4, contrast: 0.15 },
  } as Preset,
  {
    name: '黑白',
    adjustments: { saturation: -1.0, contrast: 0.25, brightness: 0.05 },
  } as Preset,
  {
    name: '暖色',
    adjustments: { temperature: 0.5, tint: 0.1, vibrance: 0.2 },
  } as Preset,
  {
    name: '冷色',
    adjustments: { temperature: -0.5, tint: -0.1, contrast: 0.1 },
  } as Preset,
  {
    name: '电影感',
    adjustments: { contrast: 0.25, saturation: -0.15, highlights: -0.3, shadows: 0.3, vibrance: 0.2 },
  } as Preset,
  {
    name: '清新',
    adjustments: { brightness: 0.2, saturation: 0.1, highlights: -0.1, shadows: 0.15 },
  } as Preset,
  {
    name: '怀旧',
    adjustments: { contrast: 0.1, saturation: -0.3, temperature: 0.3, tint: 0.05, highlights: -0.25 },
  } as Preset,
  {
    name: '夜景增强',
    adjustments: { exposure: 0.3, shadows: 0.5, contrast: 0.15, brightness: 0.1 },
  } as Preset,
  {
    name: '人像柔化',
    adjustments: { contrast: -0.1, brightness: 0.15, saturation: -0.1, highlights: -0.15 },
  } as Preset,
  {
    name: '戏剧效果',
    adjustments: { contrast: 0.5, saturation: 0.2, highlights: -0.4, shadows: 0.4, blacks: -0.2 },
  } as Preset,
  {
    name: '日系',
    adjustments: { exposure: 0.15, contrast: -0.1, saturation: -0.2, temperature: -0.1, highlights: -0.2 },
  } as Preset,
  {
    name: '胶片',
    adjustments: { contrast: 0.2, saturation: -0.1, temperature: 0.15, highlights: -0.2, shadows: 0.2 },
  } as Preset,
];

/**
 * Apply a preset's adjustments to a ColorAdjustments object.
 */
export function applyPreset(target: ColorAdjustments, preset: Preset): void {
  const a = preset.adjustments;
  const ALL_KEYS: string[] = [
    'exposure', 'contrast', 'brightness', 'highlights', 'shadows',
    'whites', 'blacks', 'saturation', 'vibrance', 'temperature', 'tint', 'hue',
  ];
  for (let i = 0; i < ALL_KEYS.length; i++) {
    const key = ALL_KEYS[i];
    const val = presetGet(a, key);
    if (val !== undefined) {
      target.setValue(key, val);
    }
  }
}

function presetGet(a: PresetAdjustments, key: string): number | undefined {
  if (key === 'exposure') return a.exposure;
  if (key === 'contrast') return a.contrast;
  if (key === 'brightness') return a.brightness;
  if (key === 'highlights') return a.highlights;
  if (key === 'shadows') return a.shadows;
  if (key === 'whites') return a.whites;
  if (key === 'blacks') return a.blacks;
  if (key === 'saturation') return a.saturation;
  if (key === 'vibrance') return a.vibrance;
  if (key === 'temperature') return a.temperature;
  if (key === 'tint') return a.tint;
  if (key === 'hue') return a.hue;
  return undefined;
}
