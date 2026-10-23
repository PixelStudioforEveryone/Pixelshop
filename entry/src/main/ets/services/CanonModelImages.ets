/**
 * Canon 机身素材表（自动生成，勿手改；生成脚本 tools/build_canon_art.py）。
 * 来源：Canon Camera Connect 3.4.30.17-cn 的 drawable-nodpi/camera_<PID>.png，
 * 已确认/处理为透明背景；资源位置 resources/rawfile/canon/<slug>.png。
 * pid 即相机 BLE 广播厂商数据（Company ID 425）里的 usbId，也是固件清单的产品 ID。
 */
export interface CanonModelArt {
  pid: number;
  pidHex: string;
  model: string;
  slug: string;
  series: string;
}

export class CanonModelImages {
  static readonly ALL: CanonModelArt[] = [
    { pid: 0x3250, pidHex: '3250', model: 'EOS 6D', slug: 'eos_6d', series: 'EOS' },
    { pid: 0x3253, pidHex: '3253', model: 'EOS 70D', slug: 'eos_70d', series: 'EOS' },
    { pid: 0x325b, pidHex: '325b', model: 'PowerShot S110', slug: 'powershot_s110', series: 'PowerShot' },
    { pid: 0x325d, pidHex: '325d', model: 'Canon 0x325D', slug: 'canon_0x325d', series: 'Other' },
    { pid: 0x325e, pidHex: '325e', model: 'Canon 0x325E', slug: 'canon_0x325e', series: 'Other' },
    { pid: 0x325f, pidHex: '325f', model: 'PowerShot SX280 HS', slug: 'powershot_sx280_hs', series: 'PowerShot' },
    { pid: 0x3261, pidHex: '3261', model: 'PowerShot A3500 IS', slug: 'powershot_a3500_is', series: 'PowerShot' },
    { pid: 0x3263, pidHex: '3263', model: 'Canon 0x3263', slug: 'canon_0x3263', series: 'Other' },
    { pid: 0x3265, pidHex: '3265', model: 'Canon 0x3265', slug: 'canon_0x3265', series: 'Other' },
    { pid: 0x3266, pidHex: '3266', model: 'Canon 0x3266', slug: 'canon_0x3266', series: 'Other' },
    { pid: 0x3268, pidHex: '3268', model: 'Digital IXUS 255HS', slug: 'digital_ixus_255hs', series: 'IXUS' },
    { pid: 0x326f, pidHex: '326f', model: 'EOS 7D Mark II', slug: 'eos_7d_mark_ii', series: 'EOS' },
    { pid: 0x3273, pidHex: '3273', model: 'EOS M2', slug: 'eos_m2', series: 'EOS M' },
    { pid: 0x3274, pidHex: '3274', model: 'PowerShot G16', slug: 'powershot_g16', series: 'PowerShot' },
    { pid: 0x3275, pidHex: '3275', model: 'PowerShot S120', slug: 'powershot_s120', series: 'PowerShot' },
    { pid: 0x3277, pidHex: '3277', model: 'PowerShot SX510 HS', slug: 'powershot_sx510_hs', series: 'PowerShot' },
    { pid: 0x3278, pidHex: '3278', model: 'Canon 0x3278', slug: 'canon_0x3278', series: 'Other' },
    { pid: 0x3279, pidHex: '3279', model: 'Canon 0x3279', slug: 'canon_0x3279', series: 'Other' },
    { pid: 0x3280, pidHex: '3280', model: 'EOS 760D', slug: 'eos_760d', series: 'EOS' },
    { pid: 0x3281, pidHex: '3281', model: 'EOS 5D Mark IV', slug: 'eos_5d_mark_iv', series: 'EOS' },
    { pid: 0x3282, pidHex: '3282', model: 'Canon 0x3282', slug: 'canon_0x3282', series: 'Other' },
    { pid: 0x3283, pidHex: '3283', model: 'Canon 0x3283', slug: 'canon_0x3283', series: 'Other' },
    { pid: 0x3285, pidHex: '3285', model: 'Canon 0x3285', slug: 'canon_0x3285', series: 'Other' },
    { pid: 0x3286, pidHex: '3286', model: 'PowerShot SX600 HS', slug: 'powershot_sx600_hs', series: 'PowerShot' },
    { pid: 0x3289, pidHex: '3289', model: 'PowerShot ELPH 340 HS', slug: 'powershot_elph_340_hs', series: 'PowerShot' },
    { pid: 0x3292, pidHex: '3292', model: 'EOS-1D X Mark II', slug: 'eos_1d_x_mark_ii', series: 'EOS' },
    { pid: 0x3294, pidHex: '3294', model: 'EOS 80D', slug: 'eos_80d', series: 'EOS' },
    { pid: 0x3295, pidHex: '3295', model: 'EOS 5DS', slug: 'eos_5ds', series: 'EOS' },
    { pid: 0x3299, pidHex: '3299', model: 'EOS M3', slug: 'eos_m3', series: 'EOS M' },
    { pid: 0x329a, pidHex: '329a', model: 'PowerShot SX60 HS', slug: 'powershot_sx60_hs', series: 'PowerShot' },
    { pid: 0x329d, pidHex: '329d', model: 'PowerShot G7 X', slug: 'powershot_g7_x', series: 'PowerShot' },
    { pid: 0x329e, pidHex: '329e', model: 'Canon 0x329E', slug: 'canon_0x329e', series: 'Other' },
    { pid: 0x329f, pidHex: '329f', model: 'PowerShot SX530 HS', slug: 'powershot_sx530_hs', series: 'PowerShot' },
    { pid: 0x32a0, pidHex: '32a0', model: 'EOS M10', slug: 'eos_m10', series: 'EOS M' },
    { pid: 0x32a1, pidHex: '32a1', model: 'EOS 750D', slug: 'eos_750d', series: 'EOS' },
    { pid: 0x32a6, pidHex: '32a6', model: 'Canon 0x32A6', slug: 'canon_0x32a6', series: 'Other' },
    { pid: 0x32a7, pidHex: '32a7', model: 'Canon 0x32A7', slug: 'canon_0x32a7', series: 'Other' },
    { pid: 0x32a8, pidHex: '32a8', model: 'PowerShot G3 X', slug: 'powershot_g3_x', series: 'PowerShot' },
    { pid: 0x32ab, pidHex: '32ab', model: 'PowerShot ELPH 350 HS', slug: 'powershot_elph_350_hs', series: 'PowerShot' },
    { pid: 0x32af, pidHex: '32af', model: 'EOS 5DS R', slug: 'eos_5ds_r', series: 'EOS' },
    { pid: 0x32b2, pidHex: '32b2', model: 'Canon 0x32B2', slug: 'canon_0x32b2', series: 'Other' },
    { pid: 0x32b3, pidHex: '32b3', model: 'PowerShot G5X', slug: 'powershot_g5x', series: 'PowerShot' },
    { pid: 0x32b4, pidHex: '32b4', model: 'EOS 1300D', slug: 'eos_1300d', series: 'EOS' },
    { pid: 0x32bb, pidHex: '32bb', model: 'EOS M5', slug: 'eos_m5', series: 'EOS M' },
    { pid: 0x32bc, pidHex: '32bc', model: 'PowerShot G7 X Mark II', slug: 'powershot_g7_x_mark_ii', series: 'PowerShot' },
    { pid: 0x32bd, pidHex: '32bd', model: 'Canon 0x32BD', slug: 'canon_0x32bd', series: 'Other' },
    { pid: 0x32be, pidHex: '32be', model: 'PowerShot SX540 HS', slug: 'powershot_sx540_hs', series: 'PowerShot' },
    { pid: 0x32bf, pidHex: '32bf', model: 'Canon 0x32BF', slug: 'canon_0x32bf', series: 'Other' },
    { pid: 0x32c0, pidHex: '32c0', model: 'Digital IXUS 180', slug: 'digital_ixus_180', series: 'IXUS' },
    { pid: 0x32c2, pidHex: '32c2', model: 'PowerShot SX720 HS', slug: 'powershot_sx720_hs', series: 'PowerShot' },
    { pid: 0x32c3, pidHex: '32c3', model: 'PowerShot SX620 HS', slug: 'powershot_sx620_hs', series: 'PowerShot' },
    { pid: 0x32c5, pidHex: '32c5', model: 'EOS M6', slug: 'eos_m6', series: 'EOS M' },
    { pid: 0x32c7, pidHex: '32c7', model: 'PowerShot G9 X Mark II', slug: 'powershot_g9_x_mark_ii', series: 'PowerShot' },
    { pid: 0x32c9, pidHex: '32c9', model: 'EOS Rebel T7i', slug: 'eos_rebel_t7i', series: 'EOS' },
    { pid: 0x32ca, pidHex: '32ca', model: 'EOS 6D Mark II', slug: 'eos_6d_mark_ii', series: 'EOS' },
    { pid: 0x32cb, pidHex: '32cb', model: 'EOS 77D', slug: 'eos_77d', series: 'EOS' },
    { pid: 0x32cc, pidHex: '32cc', model: 'EOS 200D', slug: 'eos_200d', series: 'EOS' },
    { pid: 0x32d0, pidHex: '32d0', model: 'Canon 0x32D0', slug: 'canon_0x32d0', series: 'Other' },
    { pid: 0x32d1, pidHex: '32d1', model: 'EOS M100', slug: 'eos_m100', series: 'EOS M' },
    { pid: 0x32d2, pidHex: '32d2', model: 'EOS M50', slug: 'eos_m50', series: 'EOS M' },
    { pid: 0x32d3, pidHex: '32d3', model: 'Canon 0x32D3', slug: 'canon_0x32d3', series: 'Other' },
    { pid: 0x32d5, pidHex: '32d5', model: 'Canon 0x32D5', slug: 'canon_0x32d5', series: 'Other' },
    { pid: 0x32d6, pidHex: '32d6', model: 'PowerShot SX730 HS', slug: 'powershot_sx730_hs', series: 'PowerShot' },
    { pid: 0x32d7, pidHex: '32d7', model: 'Canon 0x32D7', slug: 'canon_0x32d7', series: 'Other' },
    { pid: 0x32d9, pidHex: '32d9', model: 'EOS 4000D', slug: 'eos_4000d', series: 'EOS' },
    { pid: 0x32da, pidHex: '32da', model: 'EOS R', slug: 'eos_r', series: 'EOS R' },
    { pid: 0x32e1, pidHex: '32e1', model: 'EOS 2000D', slug: 'eos_2000d', series: 'EOS' },
    { pid: 0x32e2, pidHex: '32e2', model: 'EOS RP', slug: 'eos_rp', series: 'EOS R' },
    { pid: 0x32e4, pidHex: '32e4', model: 'PowerShot SX740 HS', slug: 'powershot_sx740_hs', series: 'PowerShot' },
    { pid: 0x32e5, pidHex: '32e5', model: 'Canon 0x32E5', slug: 'canon_0x32e5', series: 'Other' },
    { pid: 0x32e7, pidHex: '32e7', model: 'EOS M6 Mark II', slug: 'eos_m6_mark_ii', series: 'EOS M' },
    { pid: 0x32e8, pidHex: '32e8', model: 'EOS-1D X Mark III', slug: 'eos_1d_x_mark_iii', series: 'EOS' },
    { pid: 0x32e9, pidHex: '32e9', model: 'EOS 250D', slug: 'eos_250d', series: 'EOS' },
    { pid: 0x32ea, pidHex: '32ea', model: 'EOS 90D', slug: 'eos_90d', series: 'EOS' },
    { pid: 0x32ee, pidHex: '32ee', model: 'PowerShot SX70 HS', slug: 'powershot_sx70_hs', series: 'PowerShot' },
    { pid: 0x32ef, pidHex: '32ef', model: 'EOS M200', slug: 'eos_m200', series: 'EOS M' },
    { pid: 0x32f0, pidHex: '32f0', model: 'PowerShot G7 X Mark III', slug: 'powershot_g7_x_mark_iii', series: 'PowerShot' },
    { pid: 0x32f1, pidHex: '32f1', model: 'EOS Rebel T8i', slug: 'eos_rebel_t8i', series: 'EOS' },
    { pid: 0x32f4, pidHex: '32f4', model: 'EOS R5', slug: 'eos_r5', series: 'EOS R' },
    { pid: 0x32f5, pidHex: '32f5', model: 'EOS R6', slug: 'eos_r6', series: 'EOS R' },
    { pid: 0x32f7, pidHex: '32f7', model: 'EOS R7', slug: 'eos_r7', series: 'EOS R' },
    { pid: 0x32f8, pidHex: '32f8', model: 'EOS R10', slug: 'eos_r10', series: 'EOS R' },
    { pid: 0x32f9, pidHex: '32f9', model: 'EOS M50 Mark II', slug: 'eos_m50_mark_ii', series: 'EOS M' },
    { pid: 0x32fb, pidHex: '32fb', model: 'Canon 0x32FB', slug: 'canon_0x32fb', series: 'Other' },
    { pid: 0x32fc, pidHex: '32fc', model: 'EOS R3', slug: 'eos_r3', series: 'EOS R' },
    { pid: 0x3303, pidHex: '3303', model: 'EOS R5 C', slug: 'eos_r5_c', series: 'EOS R' },
    { pid: 0x330b, pidHex: '330b', model: 'EOS R6 Mark II', slug: 'eos_r6_mark_ii', series: 'EOS R' },
    { pid: 0x330c, pidHex: '330c', model: 'EOS R8', slug: 'eos_r8', series: 'EOS R' },
    { pid: 0x330d, pidHex: '330d', model: 'EOS R50', slug: 'eos_r50', series: 'EOS R' },
    { pid: 0x330e, pidHex: '330e', model: 'Canon 0x330E', slug: 'canon_0x330e', series: 'Other' },
    { pid: 0x3311, pidHex: '3311', model: 'Canon 0x3311', slug: 'canon_0x3311', series: 'Other' },
    { pid: 0x3312, pidHex: '3312', model: 'EOS R100', slug: 'eos_r100', series: 'EOS R' },
    { pid: 0x3313, pidHex: '3313', model: 'EOS R1', slug: 'eos_r1', series: 'EOS R' },
    { pid: 0x3314, pidHex: '3314', model: 'EOS R5 Mark II', slug: 'eos_r5_mark_ii', series: 'EOS R' },
    { pid: 0x3320, pidHex: '3320', model: 'EOS R50 V', slug: 'eos_r50_v', series: 'EOS R' },
  ];

  /** 归一化：大写、只保留字母数字（EOS R5 == EOSR5）。 */
  static normalize(name: string): string {
    let out = '';
    const upper = (name || '').toUpperCase();
    for (let i = 0; i < upper.length; i++) {
      const ch = upper.charAt(i);
      if ((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) out += ch;
    }
    return out;
  }

  /** 产品 ID -> 素材；未收录返回 null。 */
  static byPid(pid: number): CanonModelArt | null {
    for (const art of CanonModelImages.ALL) {
      if (art.pid === pid) return art;
    }
    return null;
  }

  /** 机型名 -> 素材（精确优先，再最长包含）；未收录返回 null。 */
  static find(name: string): CanonModelArt | null {
    const key = CanonModelImages.normalize(name);
    if (key.length === 0) return null;
    for (const art of CanonModelImages.ALL) {
      if (CanonModelImages.normalize(art.model) === key) return art;
    }
    let best: CanonModelArt | null = null;
    let bestLen = 0;
    for (const art of CanonModelImages.ALL) {
      const artKey = CanonModelImages.normalize(art.model);
      if (artKey.length < 3 || key.indexOf(artKey) < 0) continue;
      if (artKey.length > bestLen) { best = art; bestLen = artKey.length; }
    }
    return best;
  }

  /** 未收录 PID 的展示名：`EOS 0x32FB` 之类，绝不伪造机型。 */
  static fallbackModel(pid: number): string {
    return pid > 0 ? 'Canon 0x' + pid.toString(16).toUpperCase() : 'Canon';
  }
}
