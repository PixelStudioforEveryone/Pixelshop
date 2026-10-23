/**
 * Local (on-device, offline) segmentation models used by the mask tool.
 *
 * Everything here is static description plus integrity data: the actual bytes
 * live in resources/rawfile/ai_masks and the licences ship next to them in
 * LICENSES.txt. Nothing in this file or in AiSegmentationService downloads,
 * uploads or inspects user content.
 *
 * Provenance
 *   subject  U^2-NetP -- network xuebinqin/U-2-Net (Apache-2.0), weights from the
 *            official danielgatis/rembg release, converted with pnnx 20260526.
 *   sky      skysegsmall -- xiongzhu666/Sky-Segmentation-and-Post-processing
 *            (MIT), author-published ncnn model.
 */

/** Which local network to run. The numeric values are the native ABI. */
export enum AiMaskKind {
  SUBJECT = 0,
  SKY = 1,
}

export interface AiMaskModelSpec {
  kind: AiMaskKind;
  key: string;
  /** Short user-facing name, e.g. 主体 / 天空. */
  label: string;
  displayName: string;
  upstream: string;
  license: string;
  /** rawfile path of the ncnn graph description. */
  paramPath: string;
  binPath: string;
  paramSha256: string;
  binSha256: string;
  paramBytes: number;
  binBytes: number;
  /** Square network input edge. */
  inputSize: number;
  /**
   * U^2-NetP is a salient-object detector: it returns the single most
   * prominent object. It is NOT a click-any-object interactive segmenter and
   * the UI must not promise that.
   */
  supportsArbitraryTarget: boolean;
  /** Honest quality note surfaced in the model info sheet. */
  qualityNote: string;
}

export const AI_MASK_MODELS: AiMaskModelSpec[] = [
  {
    kind: AiMaskKind.SUBJECT,
    key: 'subject',
    label: '主体',
    displayName: 'U^2-NetP 显著目标',
    upstream: 'github.com/xuebinqin/U-2-Net (权重: danielgatis/rembg 官方发布)',
    license: 'Apache-2.0',
    paramPath: 'ai_masks/u2netp.ncnn.param',
    binPath: 'ai_masks/u2netp.ncnn.bin',
    paramSha256: '315dbc3956dce0cf14f2821c130f1084c62ef9f4f77f3ba9a66d99c258f8e2d1',
    binSha256: '8b5eb6e2ff0cb0b32894a3d2c8ea686db79aade33270e6381336d988ad4c1096',
    paramBytes: 29635,
    binBytes: 2257156,
    inputSize: 320,
    supportsArbitraryTarget: false,
    qualityNote: '自动选出画面中最显著的一个主体；多人或前景遮挡时可能只选中最突出者，可用画笔继续增删。',
  },
  {
    kind: AiMaskKind.SKY,
    key: 'sky',
    label: '天空',
    displayName: 'skysegsmall 天空分割',
    upstream: 'github.com/xiongzhu666/Sky-Segmentation-and-Post-processing',
    license: 'MIT',
    paramPath: 'ai_masks/skysegsmall_sim-opt-fp16.param',
    binPath: 'ai_masks/skysegsmall_sim-opt-fp16.bin',
    paramSha256: '7af3523130445db42d94503558c08ce991932f843b92e4e921c99d732768895e',
    binSha256: 'ff1e18f71dc0a0cf8a56b634c59f68d296deffd015cbed27a6d5e302f991faf2',
    paramBytes: 29420,
    binBytes: 2257156,
    inputSize: 384,
    supportsArbitraryTarget: false,
    qualityNote: '作者提供的是演示级模型，对发丝、云层、建筑边缘无质量保证；纯黑白照片基本无法识别。'
      + '实测部分高亮或薄雾画面会被误判为天空，请用减去/交集修正。',
  },
];

export function aiMaskModelFor(kind: AiMaskKind): AiMaskModelSpec {
  for (let index = 0; index < AI_MASK_MODELS.length; index++) {
    if (AI_MASK_MODELS[index].kind === kind) return AI_MASK_MODELS[index];
  }
  return AI_MASK_MODELS[0];
}

/**
 * Models run at a square input edge; the caller sends a bounded proxy of the
 * source and never a full-resolution frame.
 */
export function aiMaskInputSize(kind: AiMaskKind): number {
  return aiMaskModelFor(kind).inputSize;
}
