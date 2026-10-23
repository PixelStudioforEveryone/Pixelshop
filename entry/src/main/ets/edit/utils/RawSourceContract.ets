/** Provenance contract for image data entering the editor. RGBA_8888 is only
 * a storage format; it does not imply linear light or a particular gamut. */
export enum RawSourceKind {
  SYSTEM_DECODER_RGBA = 'system_decoder_rgba',
  EMBEDDED_JPEG_PREVIEW = 'embedded_jpeg_preview',
  LINEAR_CAMERA_RGB = 'linear_camera_rgb',
  NATIVE_RENDERED_RGB = 'native_rendered_rgb',
}

export interface RawDecodeDescriptor {
  sourceKind: RawSourceKind;
  sourceUri: string;
  sourceName: string;
  actualWidth: number;
  actualHeight: number;
  actualDimensionsKnown: boolean;
  dimensionNote: string;
  outputWidth: number;
  outputHeight: number;
  bitDepth: number | null;
  colorSpace: string;
  transferFunction: string;
  processing: string;
  dcpApplied: boolean;
}

export function rawDescriptorJson(info: RawDecodeDescriptor): string {
  return JSON.stringify(info);
}
