/**
 * Canon 机型归一化：BLE 产品 ID / 广播名 / PTP 产品名 -> 统一身份。
 *
 * 三个来源的形态（与报告 01 §1.2、02 §1.2 对齐）：
 *  - BLE 厂商数据（Company ID 425）：`usbId`（16bit 产品 ID，等同固件清单
 *    `<item id>` 的编号体系，也是 `drawable-nodpi/camera_<hex>.png` 的后缀）；
 *  - BLE 广播名：机型名，可能带 `Canon` 前缀或尾随序列号；
 *  - PTP 属性 2（产品名）/ GATT 2a24（Model Number）：官方机型写法。
 *
 * 素材表 `CanonModelImages` 是自动生成的（`tools/build_canon_art.py`），本文件
 * 只做匹配与兜底，绝不伪造机型：未收录的产品 ID 显示 `Canon 0x32FB`。
 *
 * 命名口径：`imageKey = 'canon_' + slug`；品牌字符串恒为 `'Canon'`。
 */
import { CanonModelArt, CanonModelImages } from './CanonModelImages';

/** 识别阶段与卡片共用的身份三元组。 */
export interface CanonIdentity {
  pid: number;
  model: string;
  imageKey: string;
  series: string;
}

export class CanonModels {
  /** 品牌字符串（`CameraSessionStore.cameraBrand` 的取值）。 */
  static readonly BRAND: string = 'Canon';
  /** 图片键前缀；`CameraPage.brandForImageKey` 与卡片渲染按它判定。 */
  static readonly IMAGE_KEY_PREFIX: string = 'canon_';
  /** 广播名展示上限，防止异常长串撑破卡片。 */
  private static readonly MAX_NAME_LENGTH: number = 40;
  /** 未收录机型的通用系列名。 */
  private static readonly UNKNOWN_SERIES: string = 'Other';

  /** 只保留字母数字并大写：`EOS R5` 与 `EOSR5` 因此相等。 */
  static normalize(raw: string): string {
    return CanonModelImages.normalize(raw);
  }

  /** 清理控制字符与多余空白，保留原始大小写（展示用）。 */
  static cleanAdvertisedName(raw: string | undefined): string {
    const source = raw === undefined ? '' : raw;
    let text = source.replace(/[\u0000-\u001F\u007F]/g, ' ').replace(/\s+/g, ' ').trim();
    // 去掉厂商前缀：`Canon EOS R5` / `CANON-EOS R5` -> `EOS R5`。
    const upper = text.toUpperCase();
    if (upper.indexOf('CANON') === 0) {
      text = text.substring(5).trim();
      while (text.length > 0) {
        const head = text.charAt(0);
        if (head === '-' || head === '_' || head === ' ') {
          text = text.substring(1);
        } else {
          break;
        }
      }
    }
    // 官方广播名有时是 `EOSR5`（无空格）：仅在能命中素材表时补空格。
    const compact = CanonModelImages.find(text);
    if (compact !== null) text = compact.model;
    if (text.length > CanonModels.MAX_NAME_LENGTH) {
      text = text.substring(0, CanonModels.MAX_NAME_LENGTH).trim();
    }
    return text;
  }

  /** 产品 ID -> 图片键；未收录返回空串（页面回退到线稿占位）。 */
  static imageKeyOfPid(pid: number): string {
    const art = CanonModelImages.byPid(pid);
    return art === null ? '' : CanonModels.IMAGE_KEY_PREFIX + art.slug;
  }

  /** 机型名 -> 图片键；未收录返回空串。 */
  static imageKeyOfName(name: string): string {
    const art = CanonModelImages.find(name);
    return art === null ? '' : CanonModels.IMAGE_KEY_PREFIX + art.slug;
  }

  /** 图片键是否属于佳能（供卡片渲染与品牌反查使用）。 */
  static isCanonImageKey(key: string): boolean {
    return key.length > CanonModels.IMAGE_KEY_PREFIX.length &&
      key.indexOf(CanonModels.IMAGE_KEY_PREFIX) === 0;
  }

  /** 图片键 -> rawfile 相对路径；未知键返回空串，调用方必须判空。 */
  static rawfileForImageKey(key: string): string {
    if (!CanonModels.isCanonImageKey(key)) return '';
    const slug = key.substring(CanonModels.IMAGE_KEY_PREFIX.length);
    for (const art of CanonModelImages.ALL) {
      if (art.slug === slug) return 'canon/' + art.slug + '.png';
    }
    return '';
  }

  /**
   * 由 BLE 产品 ID + 广播名生成身份。
   *
   * 产品 ID 是权威身份（与素材表、固件清单同源）；广播名只在未收录时用于
   * 展示，以及尝试按名字再匹配一次（部分老机型广播的 usbId 为 0）。
   */
  static identityFromPid(pid: number, advertisedName: string): CanonIdentity {
    const art = pid > 0 ? CanonModelImages.byPid(pid) : null;
    if (art !== null) {
      return {
        pid: pid,
        model: art.model,
        imageKey: CanonModels.IMAGE_KEY_PREFIX + art.slug,
        series: art.series,
      };
    }
    const cleaned = CanonModels.cleanAdvertisedName(advertisedName);
    const byName = CanonModelImages.find(cleaned);
    if (byName !== null) {
      return {
        pid: byName.pid,
        model: byName.model,
        imageKey: CanonModels.IMAGE_KEY_PREFIX + byName.slug,
        series: byName.series,
      };
    }
    return {
      pid: pid,
      model: cleaned.length > 0 ? cleaned : CanonModelImages.fallbackModel(pid),
      imageKey: '',
      series: CanonModels.UNKNOWN_SERIES,
    };
  }

  /** 由 PTP 产品名 / GATT 机型串反查身份；找不到返回 null。 */
  static identityFromName(name: string): CanonIdentity | null {
    const art = CanonModelImages.find(CanonModels.cleanAdvertisedName(name));
    if (art === null) return null;
    return {
      pid: art.pid,
      model: art.model,
      imageKey: CanonModels.IMAGE_KEY_PREFIX + art.slug,
      series: art.series,
    };
  }

  /** 产品 ID 的展示名（未收录时 `Canon 0x32FB`）。 */
  static modelNameOfPid(pid: number): string {
    const art = CanonModelImages.byPid(pid);
    return art === null ? CanonModelImages.fallbackModel(pid) : art.model;
  }

  /** 固件清单/素材表共用：`%04x` 小写十六进制。 */
  static pidHex(pid: number): string {
    let hex = pid.toString(16).toLowerCase();
    while (hex.length < 4) hex = '0' + hex;
    return hex;
  }
}
