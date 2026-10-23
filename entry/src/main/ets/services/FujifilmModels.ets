/**
 * FUJIFILM 机型名归一化（识别路线的唯一入口）。
 *
 * 为什么需要这一层
 * ----------------
 * 机身名会在三条链路上以三种形态出现，且互不完全一致：
 *  - BLE 广播名：老协议是「4 字符短序列号 + 机型」（`J:BTManager.java:545-566`），
 *    RED 是整串机型（`J:BTManager.java:839-856`）；
 *  - Wi‑Fi SSID：`FUJIFILM-<机型>-<后缀>`（前缀 9 字符，`J:BTCamera.java:3383`）；
 *  - PTP DeviceInfo / 0x2A24 机型串：`GFX100 II`、`X-T5` 这类官方写法。
 * 素材表 `FujifilmModelImages.ALL` 用的是官方写法（85 款机身 + Other/Unknown），
 * 所以这里统一把三种形态映射到 `FujifilmModelImages.find()` 的 slug，再拼成
 * `fujifilm_<slug>` 的 imageKey（契约见 ROUTE_SPEC §2.3 / §3.6）。
 *
 * 为什么不直接调 `FujifilmModelImages.find()`
 * ------------------------------------------
 * 它的宽松匹配是「表里第一个被包含的名字」，于是 `GFX100II 6A0123` 会先命中
 * `GFX 100`（表里排在 `GFX100 II` 之前），机型就错了一档。这里改成
 * **精确优先 + 最长包含优先**，且在比较前剥掉厂商前缀与序列号后缀。
 * 素材表本身是自动生成的，不改它。
 *
 * 命名口径：`imageKey = 'fujifilm_' + slug`；品牌字符串恒为 `'FUJIFILM'`。
 */

import { FujifilmModelArt, FujifilmModelImages } from './FujifilmModelImages';

/** Wi‑Fi SSID 反查结果，形状与 `LumixCameraService.LumixSsidIdentity` 兼容。 */
export interface FujifilmSsidIdentity {
  model: string;
  family: string;
  imageKey: string;
}

export class FujifilmModels {
  /** 品牌字符串（会话字段 `cameraBrand` 的取值，契约 §3.1）。 */
  static readonly BRAND: string = 'FUJIFILM';
  /** imageKey 前缀；`brandForImageKey` 与卡片都按它判定。 */
  static readonly IMAGE_KEY_PREFIX: string = 'fujifilm_';
  /** 未收录机型落到素材表里的 Other 图，避免出现空图。 */
  static readonly UNKNOWN_SLUG: string = 'other';
  /** 相机 SSID 的固定前缀（9 字符，`J:BTCamera.java:3383` 的 substring(9)）。 */
  static readonly SSID_PREFIX: string = 'FUJIFILM-';
  /** 机型名展示上限，防止广播里夹带的异常长串撑破卡片。 */
  private static readonly MAX_NAME_LENGTH: number = 40;
  /** 宽松匹配时忽略过短的机型码，否则 `X10` 会命中 `X100V` 之类的名字。 */
  private static readonly MIN_LOOSE_KEY: number = 3;

  /** 只保留字母数字并大写：`GFX 100` 与 `GFX100` 因此相等。 */
  static normalize(raw: string): string {
    return FujifilmModelImages.normalize(raw);
  }

  /** 清理控制字符与多余空白，保留原始大小写（展示用）。 */
  private static clean(raw: string): string {
    const stripped = (raw || '').replace(/[\u0000-\u001F\u007F]/g, ' ').replace(/\s+/g, ' ').trim();
    return stripped.length > FujifilmModels.MAX_NAME_LENGTH
      ? stripped.substring(0, FujifilmModels.MAX_NAME_LENGTH).trim()
      : stripped;
  }

  /** 去掉 `FUJIFILM` / `FUJIFILM-` 前缀（SSID 与部分广播名都带）。 */
  private static stripVendor(raw: string): string {
    let text = raw.trim();
    const upper = text.toUpperCase();
    if (upper.indexOf('FUJIFILM') === 0) {
      text = text.substring('FUJIFILM'.length);
      while (text.length > 0 && (text.charAt(0) === '-' || text.charAt(0) === '_' || text.charAt(0) === ' ')) {
        text = text.substring(1);
      }
    }
    return text.trim();
  }

  /** 去掉末尾的「空格/连字符 + 短序列号」段：`X-T5 A1B2C` → `X-T5`。 */
  private static stripTrailingSerial(raw: string): string {
    const text = raw.trim();
    const match = text.match(/^(.*[^\s\-_])\s*[\s\-_]\s*([A-Za-z0-9]{4,10})$/);
    if (match === null) return text;
    const head = match[1].trim();
    if (head.length < 3) return text;
    // 只有剩余部分确实能识别成素材表里的机型才裁剪：
    // 否则 "instax WIDE 500AF" 会被削成 "instax WIDE"。
    return FujifilmModels.exactLookup(head) !== null ? head : text;
  }

  /** 依次尝试的候选写法（原始、去厂商前缀、去序列号）。 */
  private static variants(raw: string): string[] {
    const cleaned = FujifilmModels.clean(raw);
    const list: string[] = [];
    if (cleaned.length === 0) return list;
    list.push(cleaned);
    const vendorless = FujifilmModels.stripVendor(cleaned);
    if (vendorless.length > 0 && vendorless !== cleaned) list.push(vendorless);
    const base = vendorless.length > 0 ? vendorless : cleaned;
    const withoutSerial = FujifilmModels.stripTrailingSerial(base);
    if (withoutSerial.length > 0 && list.indexOf(withoutSerial) < 0) list.push(withoutSerial);
    return list;
  }

  /** 精确匹配（只做标点归一化）。 */
  private static exactLookup(name: string): FujifilmModelArt | null {
    const key = FujifilmModels.normalize(name);
    if (key.length === 0) return null;
    for (const art of FujifilmModelImages.ALL) {
      if (FujifilmModelImages.normalize(art.model) === key) return art;
    }
    return null;
  }

  /**
   * 机型名 → 素材条目。
   *
   * 三级策略：精确 → 最长包含（解决 `GFX100 II` 被 `GFX 100` 抢先命中）→ null。
   * 返回 null 表示素材表未收录，调用方应回退到 Other 图与原始名字。
   */
  static find(model: string): FujifilmModelArt | null {
    const candidates = FujifilmModels.variants(model);
    for (const candidate of candidates) {
      const exact = FujifilmModels.exactLookup(candidate);
      if (exact !== null) return exact;
    }
    for (const candidate of candidates) {
      const key = FujifilmModels.normalize(candidate);
      if (key.length < FujifilmModels.MIN_LOOSE_KEY) continue;
      let best: FujifilmModelArt | null = null;
      let bestLength = 0;
      for (const art of FujifilmModelImages.ALL) {
        const artKey = FujifilmModelImages.normalize(art.model);
        if (artKey.length < FujifilmModels.MIN_LOOSE_KEY) continue;
        // Other/Unknown 是兜底条目，不参与宽松匹配，否则任何名字都能命中。
        if (art.slug === FujifilmModels.UNKNOWN_SLUG || art.slug === 'unknown') continue;
        if (key.indexOf(artKey) < 0) continue;
        if (artKey.length > bestLength) {
          best = art;
          bestLength = artKey.length;
        }
      }
      if (best !== null) return best;
    }
    return null;
  }

  /** 展示名：能认出就统一成素材表的官方写法，认不出保留清洗后的原名。 */
  static displayNameOf(raw: string): string {
    const cleaned = FujifilmModels.clean(raw);
    const art = FujifilmModels.find(cleaned);
    if (art !== null) return art.model;
    const vendorless = FujifilmModels.stripVendor(cleaned);
    const withoutSerial = FujifilmModels.stripTrailingSerial(vendorless.length > 0 ? vendorless : cleaned);
    if (withoutSerial.length > 0) return withoutSerial;
    return cleaned.length > 0 ? cleaned : FujifilmModels.BRAND;
  }

  /** 素材表 slug；未收录返回 `other`。 */
  static slugOf(model: string): string {
    const art = FujifilmModels.find(model);
    return art !== null ? art.slug : FujifilmModels.UNKNOWN_SLUG;
  }

  /** 会话/卡片使用的 imageKey：`fujifilm_<slug>`。 */
  static imageKeyOf(model: string): string {
    return FujifilmModels.IMAGE_KEY_PREFIX + FujifilmModels.slugOf(model);
  }

  /** imageKey 是否属于富士线。 */
  static isFujifilmImageKey(imageKey: string): boolean {
    return (imageKey || '').toLowerCase().indexOf(FujifilmModels.IMAGE_KEY_PREFIX) === 0;
  }

  static slugFromImageKey(imageKey: string): string {
    const text = (imageKey || '').toLowerCase();
    if (!FujifilmModels.isFujifilmImageKey(text)) return '';
    return text.substring(FujifilmModels.IMAGE_KEY_PREFIX.length);
  }

  /** imageKey → 素材表里的官方机型名；认不出返回 ''。 */
  static modelFromImageKey(imageKey: string): string {
    const slug = FujifilmModels.slugFromImageKey(imageKey);
    if (slug.length === 0) return '';
    for (const art of FujifilmModelImages.ALL) {
      if (art.slug === slug) return art.model;
    }
    return '';
  }

  /** imageKey → rawfile 相对路径（`fujifilm/<slug>.png`，找不到给占位图）。 */
  static rawfileForImageKey(imageKey: string): string {
    const model = FujifilmModels.modelFromImageKey(imageKey);
    if (model.length > 0) return FujifilmModelImages.rawfileOf(model);
    return 'fujifilm/generic.png';
  }

  /** 机型名 → rawfile 相对路径（与 `FujifilmModelImages.rawfileOf` 同一张表）。 */
  static rawfileOf(model: string): string {
    const art = FujifilmModels.find(model);
    if (art !== null) return 'fujifilm/' + art.slug + '.png';
    return 'fujifilm/generic.png';
  }

  /**
   * 相机 AP 的 SSID 反查（`FUJIFILM-X-T5-1234`）。
   *
   * 只用于「手机上已连着相机热点」时的身份补齐：`FujifilmBleService` 的
   * `readWifiCredentials` 才是凭据的权威来源。SSID 里机型与后缀的分隔方式由
   * 相机决定（报告未写死），所以这里按最长可识别前缀匹配，识别失败返回 null。
   */
  static identifyWifiSsid(ssid: string): FujifilmSsidIdentity | null {
    const text = (ssid || '').replace(/^"|"$/g, '').trim();
    if (text.length === 0) return null;
    const upper = text.toUpperCase();
    if (upper.indexOf(FujifilmModels.SSID_PREFIX) !== 0) return null;
    const rest = text.substring(FujifilmModels.SSID_PREFIX.length);
    const art = FujifilmModels.find(rest);
    const model = art !== null ? art.model : FujifilmModels.displayNameOf(rest);
    if (model.length === 0) return null;
    return {
      model: model,
      family: art !== null ? art.series : 'XSeries',
      imageKey: FujifilmModels.imageKeyOf(model),
    };
  }
}
