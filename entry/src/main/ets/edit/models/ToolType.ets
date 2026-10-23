export enum ToolType {
  ADJUST = 'adjust',
  CROP = 'crop',
  BRUSH_MASK = 'brush_mask',
  LINEAR_MASK = 'linear_mask',
  RADIAL_MASK = 'radial_mask',
  HEAL = 'heal',
  RED_EYE = 'red_eye',
  /** Draw reference lines for the Upright solver. */
  UPRIGHT = 'upright',
}

export enum CropAspectRatio {
  FREEFORM = 'freeform',
  ORIGINAL = 'original',
  SQUARE = '1:1',
  RATIO_4_3 = '4:3',
  RATIO_3_2 = '3:2',
  RATIO_16_9 = '16:9',
  RATIO_9_16 = '9:16',
}
