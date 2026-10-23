import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Preset } from './Presets';

/** A parsed 3D LUT. Values are RGB triples in the LUT's declared domain. */
export interface LutTable {
  size: number;
  values: number[];
  domainMin: number[];
  domainMax: number[];
}

/**
 * Image 组件渲染本地沙箱文件需要 file:// 前缀；resource:// 内置图、
 * file://media 图库 URI 与网络 URL 原样返回。
 */
export function lutDisplayUri(uri: string): string {
  if (uri.length === 0) return uri;
  if (uri.indexOf('resource://') === 0 || uri.indexOf('file://') === 0 ||
    uri.indexOf('http://') === 0 || uri.indexOf('https://') === 0) {
    return uri;
  }
  if (uri.indexOf('/') === 0) return 'file://' + uri;
  return uri;
}

export interface LutMetadata {
  author: string;
  description: string;
}

/** A user or bundled LUT entry shared by the library, detail page and editor. */
export interface CustomLut extends Preset {
  id: string;
  sourceUri: string;
  sampleCount: number;
  format?: string;
  category?: string;
  author?: string;
  description?: string;
  coverUri?: string;
  sampleUri?: string;
  /** LUT 市场唯一标志符（OpenID 部分随机 + 日期 + 数字，分享/检索用）。 */
  shareCode?: string;
  /** Built-in reference image media key used by LUT cards/details. */
  referenceKey?: string;
  version?: string;
  table?: LutTable | null;
}

/** Ordered LUT layer used by the non-destructive editor. */
export interface LutStackItem {
  id: string;
  lutId: string;
  name: string;
  sourceUri: string;
  enabled: boolean;
  intensity: number;
  lut: CustomLut | null;
  /** True when a persisted cloud LUT could not be rebuilt from its NP3 source. */
  lutUnavailable?: boolean;
}

/** In-process catalog. It avoids passing large LUT tables through router params. */
export class LutLibraryStore {
  private static entries: CustomLut[] = [];
  private static activeId: string = '';
  private static pendingEntry: CustomLut | null = null;
  private static nikonResolver: ((id: string, name: string) => CustomLut | null) | null = null;
  static committedImport: CustomLut | null = null;

  static setEntries(entries: CustomLut[]): void {
    LutLibraryStore.entries = entries.slice();
  }

  /**
   * A sidecar stores only id/name/sourceUri for cloud presets. Their tables are
   * baked from the bundled NP3 at runtime, so a cold start must be able to
   * rebuild one without waiting for the presets panel to mount.
   */
  static setNikonResolver(resolver: (id: string, name: string) => CustomLut | null): void {
    LutLibraryStore.nikonResolver = resolver;
  }

  static findOrRestore(id: string, name: string, sourceUri: string): CustomLut | null {
    const found = LutLibraryStore.find(id) ?? LutLibraryStore.findByName(name);
    if (found && found.table) return found;
    const cloud = id.indexOf('nikon:') === 0 || sourceUri.indexOf('nikon://') === 0;
    if (cloud && LutLibraryStore.nikonResolver) {
      const baked = LutLibraryStore.nikonResolver(id, name);
      if (baked) {
        LutLibraryStore.upsert(baked);
        return baked;
      }
    }
    return found ?? null;
  }

  static entriesSnapshot(): CustomLut[] {
    return LutLibraryStore.entries.slice();
  }

  static find(id: string): CustomLut | undefined {
    for (const item of LutLibraryStore.entries) if (item.id === id) return item;
    return undefined;
  }

  static findByName(name: string): CustomLut | undefined {
    for (const item of LutLibraryStore.entries) if (item.name === name) return item;
    return undefined;
  }

  /**
   * 写入/更新一条 LUT。**已存在的条目就地替换，位置保持不变**——LUT 加载
   * （LutLoader）与页面回填都会走这里，早期实现无条件 push 到末尾，导致
   * 选中任意 LUT 后它会跳到列表最后。只有新条目才追加到末尾。
   */
  static upsert(entry: CustomLut): void {
    const index = LutLibraryStore.entries.findIndex((item: CustomLut) => item.id === entry.id);
    if (index >= 0) {
      LutLibraryStore.entries[index] = entry;
      return;
    }
    LutLibraryStore.entries.push(entry);
  }

  static remove(id: string): void {
    LutLibraryStore.entries = LutLibraryStore.entries.filter((item: CustomLut) => item.id !== id);
  }

  static setActive(id: string): void {
    LutLibraryStore.activeId = id;
  }

  static active(): CustomLut | undefined {
    return LutLibraryStore.find(LutLibraryStore.activeId);
  }

  static setPending(entry: CustomLut): void { LutLibraryStore.pendingEntry = entry; }
  static pending(): CustomLut | null { return LutLibraryStore.pendingEntry; }
  static clearPending(): void { LutLibraryStore.pendingEntry = null; }
}

export function createLutStackItem(lut: CustomLut, intensity: number = 1): LutStackItem {
  return {
    id: 'lut-layer-' + Date.now().toString(36) + '-' + Math.random().toString(36).substring(2, 8),
    lutId: lut.id,
    name: lut.name,
    sourceUri: lut.sourceUri,
    enabled: true,
    intensity: Math.max(0, Math.min(1, intensity)),
    lut: lut,
    lutUnavailable: false,
  };
}

/** Parse a LUT from a file URI. The parser accepts text-based .cube/.vlt/.3dl/.look files. */
export function parseLutFile(uri: string): CustomLut | null {
  try {
    return parseLutText(readLutText(uri), uri);
  } catch (_error) {
    return null;
  }
}

/** File-system-safe token for LUT effect-image cache names. */
export function lutCacheToken(name: string): string {
  const token = name.replace(/[\\/:*?"<>|\r\n]+/g, '_').replace(/\s+/g, '_')
    .replace(/_+/g, '_').replace(/^_+/, '').replace(/_+$/, '');
  return token.length > 0 ? token.substring(0, 48) : 'lut';
}

/**
 * Shared effect-image cache path, named 原图名+LUT名. The main LUT page and
 * the LUT transfer page use the same scheme: a preview rendered on first
 * entry is stored once and loaded directly on every later startup, and the
 * readable name makes the file recognizable inside the app sandbox.
 * The _hq suffix versions the cache: raising the render resolution/quality
 * invalidates older low-quality files instead of serving them forever.
 */
export function lutEffectCachePath(filesDir: string, sampleBaseName: string, lutName: string): string {
  return filesDir + '/' + lutCacheToken(sampleBaseName) + '_' + lutCacheToken(lutName) + '_hq.jpg';
}

/** The pre-LUT sample image name a LUT's effect image is derived from.
 * A user-chosen sample (filesDir path) takes precedence over the bundled
 * reference asset so the effect cache re-renders with the new sample. */
export function lutSampleBaseName(entry: CustomLut): string {
  const sampleUri = entry.sampleUri ?? '';
  if (sampleUri.length > 0 && sampleUri.indexOf('resource://') !== 0) {
    const segments = sampleUri.split(/[\\/]/);
    const base = segments.length > 0 ? segments[segments.length - 1] : '';
    const clean = base.replace(/\.[^/.]+$/, '');
    if (clean.length > 0) return clean;
  }
  const referenceKey = entry.referenceKey ?? '';
  if (referenceKey.length > 0) return referenceKey;
  return 'lut_sample_portrait';
}

/**
 * LUT 库落盘：整份列表此前被序列化成**一个 preferences 字符串值**，而官方条目
 * 每条都带整张 LUT 表（33³ ≈ 1MB），十几条就把这个值撑到十几 MB、写不进去
 * （实测第 17 条起报「保存 LUT 失败」）。改为写沙箱 JSON 文件，本地 LUT 条数
 * 不再受该值的容量约束；首次读取时迁移旧 preferences 数据，已有条目不丢。
 */
const LUT_STORE_FILE: string = 'vivid_lut_library.json';
const LUT_STORE_LEGACY_NAME: string = 'vivid_lut_library';

export interface LutLibraryFileData {
  version: number;
  customLuts: CustomLut[];
  deletedBundledLuts: string[];
  sampleOverrides: Record<string, string>;
}

export class LutLibraryFileStore {
  private static cache: LutLibraryFileData | null = null;

  private static filePath(context: common.UIAbilityContext): string {
    return context.filesDir + '/' + LUT_STORE_FILE;
  }

  /** 读库（含一次性迁移）；同进程内复用缓存，避免反复读盘。 */
  static async read(context: common.UIAbilityContext): Promise<LutLibraryFileData> {
    if (LutLibraryFileStore.cache !== null) return LutLibraryFileStore.cache;
    const fromFile = LutLibraryFileStore.readFile(context);
    if (fromFile !== null) {
      LutLibraryFileStore.cache = fromFile;
      return fromFile;
    }
    const migrated = await LutLibraryFileStore.migrateLegacy(context);
    try {
      // 迁移落盘失败不应影响本次读取。
      LutLibraryFileStore.writeFile(context, migrated);
    } catch (_error) {
    }
    LutLibraryFileStore.cache = migrated;
    return migrated;
  }

  static async update(context: common.UIAbilityContext,
    mutate: (data: LutLibraryFileData) => void): Promise<void> {
    const data = await LutLibraryFileStore.read(context);
    mutate(data);
    LutLibraryFileStore.writeFile(context, data);
  }

  private static readFile(context: common.UIAbilityContext): LutLibraryFileData | null {
    try {
      const path = LutLibraryFileStore.filePath(context);
      if (!fileIo.accessSync(path)) return null;
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let text = '';
      try {
        const size = fileIo.statSync(file.fd).size;
        if (size > 0) {
          const buffer = new ArrayBuffer(size);
          const read = fileIo.readSync(file.fd, buffer);
          text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer, 0, read));
        }
      } finally {
        fileIo.closeSync(file);
      }
      if (text.trim().length === 0) return null;
      return LutLibraryFileStore.normalize(JSON.parse(text) as LutLibraryFileData);
    } catch (_error) {
      return null;
    }
  }

  private static normalize(parsed: LutLibraryFileData): LutLibraryFileData {
    const custom: CustomLut[] = parsed.customLuts instanceof Array ? parsed.customLuts : [];
    const deleted: string[] = parsed.deletedBundledLuts instanceof Array ? parsed.deletedBundledLuts : [];
    const overrides: Record<string, string> =
      parsed.sampleOverrides !== undefined && parsed.sampleOverrides !== null ? parsed.sampleOverrides : {};
    return { version: 1, customLuts: custom, deletedBundledLuts: deleted, sampleOverrides: overrides };
  }

  /** 旧数据在 preferences 的 'vivid_lut_library' 里，读取一次后改用文件。
   *  逐键容错：任何一项损坏都不影响其余项迁移。 */
  private static async migrateLegacy(context: common.UIAbilityContext): Promise<LutLibraryFileData> {
    const data: LutLibraryFileData = {
      version: 1, customLuts: [], deletedBundledLuts: [], sampleOverrides: {},
    };
    let store: preferences.Preferences | null = null;
    try {
      store = await preferences.getPreferences(context, LUT_STORE_LEGACY_NAME);
    } catch (_error) {
      return data;
    }
    try {
      const rawCustom = await store.get('customLuts', '[]');
      if (typeof rawCustom === 'string' && rawCustom.length > 0) {
        const parsed = JSON.parse(rawCustom) as CustomLut[];
        if (parsed instanceof Array) data.customLuts = parsed;
      }
    } catch (_error) {
    }
    try {
      const rawDeleted = await store.get('deletedBundledLuts', '[]');
      if (typeof rawDeleted === 'string' && rawDeleted.length > 0) {
        const parsed = JSON.parse(rawDeleted) as string[];
        if (parsed instanceof Array) data.deletedBundledLuts = parsed;
      }
    } catch (_error) {
    }
    try {
      const rawOverrides = await store.get('sampleOverrides', '{}');
      if (typeof rawOverrides === 'string' && rawOverrides.length > 0) {
        const parsed = JSON.parse(rawOverrides) as Record<string, string>;
        if (parsed !== null && parsed !== undefined) data.sampleOverrides = parsed;
      }
    } catch (_error) {
    }
    return data;
  }

  /** 写盘失败必须抛出：调用方要据此提示「保存失败」，不能静默吞掉。 */
  private static writeFile(context: common.UIAbilityContext, data: LutLibraryFileData): void {
    const path = LutLibraryFileStore.filePath(context);
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      const bytes = util.TextEncoder.create('utf-8').encode(JSON.stringify(data));
      fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
    } finally {
      fileIo.closeSync(file);
    }
  }
}

/** 本机自定义 LUT 列表（无条数上限）。 */
export async function loadCustomLuts(context: common.UIAbilityContext): Promise<CustomLut[]> {
  return (await LutLibraryFileStore.read(context)).customLuts;
}

export async function saveCustomLuts(context: common.UIAbilityContext, entries: CustomLut[]): Promise<void> {
  await LutLibraryFileStore.update(context, (data: LutLibraryFileData): void => {
    data.customLuts = entries.slice();
  });
}

/** 新增/更新一条自定义 LUT（官方 LUT 下载后的保存走这里）。 */
export async function upsertCustomLut(context: common.UIAbilityContext, entry: CustomLut): Promise<void> {
  await LutLibraryFileStore.update(context, (data: LutLibraryFileData): void => {
    data.customLuts = data.customLuts.filter((item: CustomLut) => item.id !== entry.id);
    data.customLuts.push(entry);
  });
}

export async function loadDeletedBundledLuts(context: common.UIAbilityContext): Promise<string[]> {
  return (await LutLibraryFileStore.read(context)).deletedBundledLuts;
}

export async function saveDeletedBundledLuts(context: common.UIAbilityContext, sources: string[]): Promise<void> {
  await LutLibraryFileStore.update(context, (data: LutLibraryFileData): void => {
    data.deletedBundledLuts = sources.slice();
  });
}

/**
 * Per-LUT user-chosen sample images (set from the LUT detail page's
 * 更换示例图), persisted as a lutId → file map so the choice survives
 * restarts for both bundled and custom LUTs.
 */
export async function loadSampleOverrides(context: common.UIAbilityContext): Promise<Record<string, string>> {
  return (await LutLibraryFileStore.read(context)).sampleOverrides;
}

export async function saveSampleOverride(context: common.UIAbilityContext,
  lutId: string, samplePath: string): Promise<void> {
  try {
    await LutLibraryFileStore.update(context, (data: LutLibraryFileData): void => {
      data.sampleOverrides[lutId] = samplePath;
    });
  } catch (_error) {
  }
}

/** Apply persisted sample overrides to a loaded LUT list (in place). */
export function applySampleOverrides(entries: CustomLut[], overrides: Record<string, string>): void {
  for (const entry of entries) {
    const override = overrides[entry.id];
    if (override !== undefined && override.length > 0) {
      entry.sampleUri = override;
      entry.coverUri = override;
    }
  }
}


/** Parse a text LUT while retaining the complete table for real preview/export. */
export function parseLutText(source: string, sourceUri: string): CustomLut | null {
  try {
    const lines = source.replace(/^\uFEFF/, '').split(/\r?\n/);
    let title = '';
    let size = 0;
    const format = extensionOf(sourceUri);
    let version = '';
    const domainMin: number[] = [0, 0, 0];
    const domainMax: number[] = [1, 1, 1];
    const samples: number[] = [];

    for (let index = 0; index < lines.length; index++) {
      let line = lines[index].trim();
      if (line.length === 0) continue;
      const comment = line.indexOf('#');
      if (comment >= 0) {
        const commentText = line.substring(comment + 1).trim();
        if (commentText.toLowerCase().indexOf('version') >= 0) version = commentText;
        line = line.substring(0, comment).trim();
      }
      if (line.length === 0) continue;
      const upper = line.toUpperCase();
      if (upper.indexOf('TITLE') === 0) {
        title = line.substring(5).replace(/["']/g, '').trim();
        continue;
      }
      if (upper.indexOf('LUT_3D_SIZE') === 0 || upper.indexOf('LUT_SIZE') === 0) {
        const sizeParts = line.split(/\s+/);
        const parsedSize = Number(sizeParts[1]);
        if (sizeParts.length !== 2 || !Number.isInteger(parsedSize) || parsedSize < 2 ||
          parsedSize > 128 || (size !== 0 && size !== parsedSize)) return null;
        size = parsedSize;
        continue;
      }
      if (upper.indexOf('DOMAIN_MIN') === 0) {
        const triple = parseTriple(line.substring(10));
        if (triple.length !== 3) return null;
        copyTriple(domainMin, triple);
        continue;
      }
      if (upper.indexOf('DOMAIN_MAX') === 0) {
        const triple = parseTriple(line.substring(10));
        if (triple.length !== 3) return null;
        copyTriple(domainMax, triple);
        continue;
      }
      // A shaper + 3D table needs a separate 1D sampling stage. Do not silently
      // interpret its shaper rows as the first slice of the 3D table.
      if (upper.indexOf('LUT_1D_SIZE') === 0) return null;
      if (upper.indexOf('LUT_3D_INPUT_RANGE') === 0) {
        const range = line.split(/\s+/);
        const low = Number(range[1]);
        const high = Number(range[2]);
        if (range.length !== 3 || !isFinite(low) || !isFinite(high) || high <= low) return null;
        copyTriple(domainMin, [low, low, low]);
        copyTriple(domainMax, [high, high, high]);
        continue;
      }
      if (upper.indexOf('CHANNELS') === 0) continue;
      const triple = parseTriple(line);
      if (triple.length === 3) {
        samples.push(triple[0], triple[1], triple[2]);
        if (samples.length > 128 * 128 * 128 * 3 ||
          (size > 0 && samples.length > size * size * size * 3)) return null;
      } else if (/^[+\-.\d]/.test(line) || /^(nan|inf(?:inity)?)(\s|$)/i.test(line)) {
        return null;
      }
    }

    if (samples.length < 6) return null;
    if (size <= 1) {
      const inferred = Math.round(Math.cbrt(samples.length / 3));
      size = inferred > 1 && inferred * inferred * inferred * 3 === samples.length ? inferred : 0;
    }
    if (size <= 1 || size > 128 || !Number.isInteger(size)) return null;
    const expected = size * size * size * 3;
    if (samples.length !== expected) return null;
    for (let channel = 0; channel < 3; channel++) {
      if (domainMax[channel] <= domainMin[channel]) return null;
    }

    let maximum = 1;
    for (const value of samples) maximum = Math.max(maximum, Math.abs(value));
    // Panasonic VLT text exports use 12/16-bit integer values. Normalize them
    // without changing ordinary .cube values already in [0,1].
    if (format === 'vlt' && maximum > 1) {
      const scale = maximum > 4095 ? 1 / 65535 : 1 / 4095;
      for (let index = 0; index < samples.length; index++) samples[index] = samples[index] * scale;
    }
    // CUBE floating-point outputs may legitimately exceed [0,1]. Preserve
    // them through interpolation; the pixel pipeline clamps the result.

    const fileName = safeDecode(sourceUri.split(/[\\/]/).pop() ?? 'Imported LUT');
    const cleanName = fileName.replace(/\.[^/.]+$/, '');
    const name = title.length > 0 ? title : cleanName;
    const table: LutTable = { size: size, values: samples, domainMin: domainMin, domainMax: domainMax };
    return {
      id: 'lut:' + sourceUri,
      sourceUri: sourceUri,
      sampleCount: size * size * size,
      format: format,
      version: version,
      name: name,
      adjustments: {},
      table: table,
    } as CustomLut;
  } catch (_error) {
    return null;
  }
}

/** Parse the optional sidecar metadata format used by the bundled catalog. */
export function parseLutMetadata(source: string): LutMetadata {
  let author = '';
  let description = '';
  let inDescription = false;
  const lines = source.replace(/^\uFEFF/, '').split(/\r?\n/);
  for (const raw of lines) {
    const line = raw.trim();
    if (line.length === 0) continue;
    const separator = line.indexOf('：') >= 0 ? line.indexOf('：') : line.indexOf(':');
    if (separator > 0) {
      const key = line.substring(0, separator).trim().toLowerCase();
      const value = line.substring(separator + 1).trim();
      if (key === '作者' || key === 'author') {
        author = value;
        inDescription = false;
        continue;
      }
      if (key === '描述' || key === 'description') {
        description = value;
        inDescription = true;
        continue;
      }
    }
    if (inDescription) description = description.length > 0 ? description + '\n' + line : line;
  }
  const metadata: LutMetadata = { author: author, description: description };
  return metadata;
}

/** Decode a sidecar file without exposing its contents outside the app. */
export function parseLutMetadataFile(uri: string): LutMetadata {
  try { return parseLutMetadata(readLutText(uri)); } catch (_error) {
    const metadata: LutMetadata = { author: '', description: '' };
    return metadata;
  }
}

function parseTriple(text: string): number[] {
  const parts = text.trim().split(/\s+/);
  if (parts.length !== 3) return [];
  const values: number[] = [Number(parts[0]), Number(parts[1]), Number(parts[2])];
  return values.every((value: number) => isFinite(value)) ? values : [];
}

function copyTriple(target: number[], source: number[]): void {
  if (source.length !== 3) return;
  target[0] = source[0]; target[1] = source[1]; target[2] = source[2];
}

function extensionOf(uri: string): string {
  const value = uri.toLowerCase();
  const dot = value.lastIndexOf('.');
  return dot >= 0 ? value.substring(dot + 1) : 'lut';
}

function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

function safeDecode(value: string): string {
  try { return decodeURIComponent(value); } catch (_error) { return value; }
}

/** Read the raw text of a LUT sidecar/source file (also used to re-read the
 * original .cube bytes when transferring a library LUT to a camera). */
export function readLutText(uri: string): string {
  try {
    return fileIo.readTextSync(uri);
  } catch (_error) {
    const opened = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = fileIo.statSync(opened.fd);
      const length = Math.max(0, Number(stat.size));
      const buffer = new ArrayBuffer(length);
      const read = fileIo.readSync(opened.fd, buffer, { length: length });
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer, 0, read));
    } finally {
      fileIo.closeSync(opened.fd);
    }
  }
}
