/**
 * 佳能 EOS 参数表：EDSDK 逻辑属性 ↔ PTP DevicePropCode ↔ 值编码/显示。
 *
 * 表的**上半部分**严格照抄 `report 02 §2`（EDSDK 属性 ID 是官方 App 的 UI 层
 * 编号）；**下半部分**的 PTP 码来自 libgphoto2 `camlibs/ptp2/ptp.h`（`0xD1xx`
 * = EOS 厂商属性），因为报告 02 §8 明确说「PTP 0x50xx/D1xx 在 native，Java 层
 * 不存在」。两列都随 `CanonParamSpec` 暴露给页面，控制页的「参数对照」抽屉
 * 就是拿这两列逐条核对的。
 *
 * 值编码（`CanonValueKind`）：
 *  - `u32` / `i32`：相机原始整数；
 *  - `apex8`：光圈/快门共用 EOS 的 APEX×8（报告 02 §2「光圈 APEX 定点」，
 *    快门同一口径 —— 1/125 s → log2(125)×8 ≈ 56）；
 *  - `ev8`：曝光补偿 1/8 EV 有符号。
 *
 * 显示文案：相机给了选项文本就用相机的；没给就用本文件的中文表（EDSDK 文档
 * 口径，标注「UI 文案」），再没有就显示 `#<十进制>`，绝不编造含义。
 */

/** 一个可选值。`value` 可直接回传 `setParam`。 */
export interface CanonParamOption {
  value: number;
  label: string;
}

/** 控制页参数网格的单元格。 */
export interface CanonParamSpec {
  key: string;
  panel: string;
  label: string;
  edsPropId: number;
  ptpDpc: number;
  value: number;
  display: string;
  options: CanonParamOption[];
  writable: boolean;
  group: string;
}

/** 值编码。 */
export type CanonValueKind = 'u32' | 'i32' | 'apex8' | 'ev8';

/** 静态参数定义。 */
export interface CanonPropDef {
  key: string;
  panel: string;
  group: string;
  label: string;
  /** 报告 02 §2 的 EDSDK 属性 ID。 */
  edsPropId: number;
  /** libgphoto2 `ptp.h` 的 EOS DPC。 */
  ptpDpc: number;
  kind: CanonValueKind;
  /** 静态候选值；空表示「只能等相机给列表」。 */
  numericOptions: CanonParamOption[];
  /** 相机没给描述符时是否仍认为可写（只对连续量成立）。 */
  writableHint: boolean;
}

/** 参数表的静态部分。 */
export class CanonPropCatalog {
  static readonly DEFS: CanonPropDef[] = [
    // —— 曝光 ——
    {
      key: 'mode', panel: 'exposure', group: '曝光', label: '曝光模式',
      edsPropId: 0x0400, ptpDpc: 0xD105, kind: 'u32', writableHint: false,
      numericOptions: [],
    },
    {
      key: 'shutter', panel: 'exposure', group: '曝光', label: '快门',
      edsPropId: 0x0406, ptpDpc: 0xD102, kind: 'apex8', writableHint: true,
      numericOptions: [],
    },
    {
      key: 'aperture', panel: 'exposure', group: '曝光', label: '光圈',
      edsPropId: 0x0405, ptpDpc: 0xD101, kind: 'apex8', writableHint: true,
      numericOptions: [],
    },
    {
      key: 'iso', panel: 'exposure', group: '曝光', label: 'ISO',
      edsPropId: 0x0402, ptpDpc: 0xD103, kind: 'u32', writableHint: true,
      numericOptions: [],
    },
    {
      key: 'ev', panel: 'exposure', group: '曝光', label: '曝光补偿',
      edsPropId: 0x0407, ptpDpc: 0xD104, kind: 'ev8', writableHint: true,
      numericOptions: [],
    },
    // —— 画质 ——
    {
      key: 'quality', panel: 'image', group: '画质', label: '画质',
      edsPropId: 0x0100, ptpDpc: 0xD120, kind: 'u32', writableHint: false,
      numericOptions: [],
    },
    {
      key: 'wb', panel: 'image', group: '画质', label: '白平衡',
      edsPropId: 0x0106, ptpDpc: 0xD109, kind: 'u32', writableHint: false,
      numericOptions: [],
    },
    // —— 驱动 ——
    {
      key: 'drive', panel: 'drive', group: '驱动', label: '驱动模式',
      edsPropId: 0x0401, ptpDpc: 0xD106, kind: 'u32', writableHint: false,
      numericOptions: [],
    },
    {
      key: 'bracket', panel: 'drive', group: '驱动', label: '包围曝光',
      edsPropId: 0x040A, ptpDpc: 0xD11D, kind: 'u32', writableHint: false,
      numericOptions: [],
    },
    // —— 对焦/测光 ——
    {
      key: 'focus', panel: 'focus', group: '对焦', label: '对焦模式',
      edsPropId: 0x0404, ptpDpc: 0xD108, kind: 'u32', writableHint: false,
      numericOptions: [],
    },
    {
      key: 'metering', panel: 'focus', group: '对焦', label: '测光模式',
      edsPropId: 0x0403, ptpDpc: 0xD107, kind: 'u32', writableHint: false,
      numericOptions: [],
    },
    // —— 镜头 ——
    {
      key: 'zoomSpeed', panel: 'lens', group: '镜头', label: '变焦速度',
      edsPropId: 0x0444, ptpDpc: 0xD149, kind: 'u32', writableHint: true,
      numericOptions: [],
    },
    // —— 取景（内部，也暴露出来便于核对）——
    {
      key: 'lvOutput', panel: 'internal', group: '取景', label: '取景输出',
      edsPropId: 0x0500, ptpDpc: 0xD1B0, kind: 'u32', writableHint: true,
      numericOptions: [],
    },
    {
      key: 'lvMode', panel: 'internal', group: '取景', label: '取景模式',
      edsPropId: 0x0501, ptpDpc: 0xD1B1, kind: 'u32', writableHint: true,
      numericOptions: [],
    },
  ];

  static find(key: string): CanonPropDef | null {
    for (const def of CanonPropCatalog.DEFS) if (def.key === key) return def;
    return null;
  }

  static defOfDpc(dpc: number): CanonPropDef | null {
    for (const def of CanonPropCatalog.DEFS) if (def.ptpDpc === dpc) return def;
    return null;
  }

  /** 生成连续量的候选列表（相机没给描述符时使用，标注「推断候选」。 */
  static generatedOptions(def: CanonPropDef): CanonParamOption[] {
    if (def.key === 'aperture') return CanonPropCatalog.apertureOptions();
    if (def.key === 'shutter') return CanonPropCatalog.shutterOptions();
    if (def.key === 'iso') return CanonPropCatalog.isoOptions();
    if (def.key === 'ev') return CanonPropCatalog.evOptions();
    return [];
  }

  /** 光圈 1/3 档：f/1.2 … f/32，值 = round(2·log2(F)·8)。 */
  private static apertureOptions(): CanonParamOption[] {
    const fNumbers: number[] = [
      1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1,
      8.0, 9.0, 10.0, 11.0, 13.0, 14.0, 16.0, 18.0, 20.0, 22.0, 25.0, 29.0, 32.0,
    ];
    const out: CanonParamOption[] = [];
    for (const f of fNumbers) {
      out.push({ value: Math.round(2 * Math.log2(f) * 8), label: `f/${f.toFixed(1).replace('.0', '')}` });
    }
    return out;
  }

  /** 快门 1/3 档：30 s … 1/8000 s，值 = round(log2(秒)·8)（负值 = 高速）。 */
  private static shutterOptions(): CanonParamOption[] {
    const out: CanonParamOption[] = [];
    const seconds: number[] = [30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3.2, 2.5, 2, 1.6, 1.3, 1,
      0.8, 0.6, 0.5, 0.4, 0.3, 1 / 4, 1 / 5, 1 / 6, 1 / 8, 1 / 10, 1 / 13, 1 / 15, 1 / 20,
      1 / 25, 1 / 30, 1 / 40, 1 / 50, 1 / 60, 1 / 80, 1 / 100, 1 / 125, 1 / 160, 1 / 200,
      1 / 250, 1 / 320, 1 / 400, 1 / 500, 1 / 640, 1 / 800, 1 / 1000, 1 / 1250, 1 / 1600,
      1 / 2000, 1 / 2500, 1 / 3200, 1 / 4000, 1 / 5000, 1 / 6400, 1 / 8000];
    for (const s of seconds) {
      const label: string = s >= 1 ? `${s} s` : `1/${Math.round(1 / s)} s`;
      out.push({ value: Math.round(Math.log2(s) * 8), label: label });
    }
    return out;
  }

  private static isoOptions(): CanonParamOption[] {
    const values: number[] = [0, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250,
      1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600,
      32000, 40000, 51200, 102400];
    const out: CanonParamOption[] = [];
    for (const v of values) out.push({ value: v, label: v === 0 ? '自动' : `${v}` });
    return out;
  }

  private static evOptions(): CanonParamOption[] {
    const out: CanonParamOption[] = [];
    for (let step = -40; step <= 40; step++) {
      const value: number = step; // 1/8 EV
      const ev: number = value / 8;
      const sign: string = ev > 0 ? '+' : '';
      out.push({ value: value, label: `${sign}${ev.toFixed(2).replace(/0$/, '').replace(/\.00$/, '.0')}` });
    }
    return out;
  }
}

/** 枚举参数的中文文案（EDSDK 文档口径；相机给了文本时优先相机）。 */
export class CanonPropLabels {
  static readonly WB: CanonParamOption[] = [
    { value: 0, label: '自动' }, { value: 1, label: '日光' }, { value: 2, label: '阴影' },
    { value: 3, label: '阴天' }, { value: 4, label: '钨丝灯' }, { value: 5, label: '白色荧光灯' },
    { value: 6, label: '闪光灯' }, { value: 7, label: '自定义' }, { value: 8, label: '色温' },
  ];
  static readonly MODE: CanonParamOption[] = [
    { value: 0, label: 'P 程序自动' }, { value: 1, label: 'Tv 快门优先' },
    { value: 2, label: 'Av 光圈优先' }, { value: 3, label: 'M 手动' },
    { value: 4, label: 'B 门' }, { value: 5, label: 'A-DEP' },
    { value: 6, label: '自定义 1' }, { value: 7, label: '自定义 2' },
    { value: 8, label: '自定义 3' }, { value: 9, label: '自动' },
    { value: 10, label: '创意自动' }, { value: 11, label: '短片' },
  ];
  static readonly DRIVE: CanonParamOption[] = [
    { value: 0, label: '单拍' }, { value: 1, label: '连拍' }, { value: 2, label: '自拍 10 s' },
    { value: 3, label: '自拍 2 s' }, { value: 4, label: '静音单拍' },
    { value: 5, label: '静音连拍' }, { value: 6, label: '自拍连拍' },
  ];
  static readonly METERING: CanonParamOption[] = [
    { value: 0, label: '评价测光' }, { value: 1, label: '局部测光' },
    { value: 2, label: '中央重点' }, { value: 3, label: '点测光' },
  ];
  static readonly FOCUS: CanonParamOption[] = [
    { value: 0, label: '单次 AF' }, { value: 1, label: '人工智能伺服' },
    { value: 2, label: '人工智能自动' }, { value: 3, label: '手动' },
  ];
  static readonly QUALITY: CanonParamOption[] = [
    { value: 0x00000001, label: 'JPEG 大/优' }, { value: 0x00000002, label: 'JPEG 大/普通' },
    { value: 0x00000003, label: 'JPEG 中/优' }, { value: 0x00000004, label: 'JPEG 中/普通' },
    { value: 0x00000005, label: 'JPEG 小/优' }, { value: 0x00000006, label: 'JPEG 小/普通' },
    { value: 0x00000007, label: 'RAW' }, { value: 0x00000008, label: 'RAW + JPEG 大' },
    { value: 0x00000009, label: 'RAW + JPEG 中' }, { value: 0x0000000A, label: 'RAW + JPEG 小' },
  ];

  static table(key: string): CanonParamOption[] {
    if (key === 'wb') return CanonPropLabels.WB;
    if (key === 'mode') return CanonPropLabels.MODE;
    if (key === 'drive') return CanonPropLabels.DRIVE;
    if (key === 'metering') return CanonPropLabels.METERING;
    if (key === 'focus') return CanonPropLabels.FOCUS;
    if (key === 'quality') return CanonPropLabels.QUALITY;
    return [];
  }

  static labelOf(key: string, value: number): string {
    for (const item of CanonPropLabels.table(key)) {
      if (item.value === value) return item.label;
    }
    return `#${value}`;
  }
}

/** 值格式化 + 小端读取。 */
export class CanonFormat {
  /** 已格式化展示串（页面原样显示）。 */
  static display(def: CanonPropDef, value: number, options: CanonParamOption[]): string {
    if (def.kind === 'apex8') {
      return def.key === 'aperture' ? CanonFormat.aperture(value) : CanonFormat.shutter(value);
    }
    if (def.kind === 'ev8') {
      const ev = value / 8;
      return `${ev > 0 ? '+' : ''}${ev.toFixed(1)} EV`;
    }
    for (const item of options) {
      if (item.value === value) return item.label;
    }
    return CanonPropLabels.labelOf(def.key, value);
  }

  /** 光圈：APEX 值 = value/8，F = 2^(APEX/2)。 */
  static aperture(value: number): string {
    if (value === 0 || value === 0xFFFFFFFF) return '--';
    const f = Math.pow(2, (value / 8) / 2);
    if (!Number.isFinite(f) || f <= 0) return `${value}`;
    const rounded = Math.round(f * 10) / 10;
    const text = rounded % 1 === 0 ? `${Math.round(rounded)}` : `${rounded.toFixed(1)}`;
    return `f/${text}`;
  }

  /** 快门：APEX 值 = value/8，t = 2^(-APEX)。 */
  static shutter(value: number): string {
    if (value === 0 || value === 0xFFFFFFFF) return '--';
    const seconds = Math.pow(2, -(value / 8));
    if (!Number.isFinite(seconds) || seconds <= 0) return `${value}`;
    if (seconds >= 1) {
      const rounded = Math.round(seconds * 10) / 10;
      return `${rounded} s`;
    }
    const denominator = Math.round(1 / seconds);
    if (denominator >= 2 && denominator <= 64000) return `1/${denominator} s`;
    return `${value}`;
  }

  static readU32(data: Uint8Array): number {
    if (data.length < 4) return 0;
    return new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(0, true);
  }

  static readI32(data: Uint8Array): number {
    if (data.length < 4) return 0;
    return new DataView(data.buffer, data.byteOffset, data.byteLength).getInt32(0, true);
  }

  static readU16(data: Uint8Array): number {
    if (data.length < 2) return 0;
    return new DataView(data.buffer, data.byteOffset, data.byteLength).getUint16(0, true);
  }
}
