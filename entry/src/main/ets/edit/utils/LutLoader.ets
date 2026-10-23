import { resourceManager } from '@kit.LocalizationKit';
import { taskpool } from '@kit.ArkTS';
import { CustomLut, LutLibraryStore } from '../models/LutLibrary';
import { parseLutBytesTask } from '../engine/LutParseWorker';

/** One selected table at a time; opening a catalog never parses its tables. */
export class LutLoader {
  private static pending: Map<string, Promise<CustomLut | null>> = new Map();

  static async load(manager: resourceManager.ResourceManager, entry: CustomLut): Promise<CustomLut | null> {
    const cached = LutLibraryStore.find(entry.id);
    if (cached?.table) return cached;
    if (entry.table) return entry;
    if (!entry.sourceUri.startsWith('bundled://')) return null;
    const pending = LutLoader.pending.get(entry.id);
    if (pending) return pending;
    const request = LutLoader.read(manager, entry);
    LutLoader.pending.set(entry.id, request);
    try { return await request; } finally {
      if (LutLoader.pending.get(entry.id) === request) LutLoader.pending.delete(entry.id);
    }
  }

  private static async read(manager: resourceManager.ResourceManager, entry: CustomLut): Promise<CustomLut | null> {
    const begin = Date.now();
    try {
      const bytes = await manager.getRawFileContent(entry.sourceUri.substring('bundled://'.length));
      const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      const parsed = await taskpool.execute(new taskpool.Task(parseLutBytesTask, buffer, entry.sourceUri)) as CustomLut | null;
      if (!parsed?.table) return null;
      const loaded: CustomLut = { id: entry.id, sourceUri: entry.sourceUri, name: entry.name,
        adjustments: entry.adjustments, table: parsed.table, sampleCount: parsed.sampleCount,
        format: parsed.format, category: entry.category, author: entry.author, description: entry.description,
        coverUri: entry.coverUri, sampleUri: entry.sampleUri, referenceKey: entry.referenceKey,
        shareCode: entry.shareCode, version: entry.version };
      // Do not resurrect a table deleted while parsing it.
      if (LutLibraryStore.find(entry.id)) LutLibraryStore.upsert(loaded);
      console.info(`VIVID_EDIT_PERF stage=lut-load ms=${Date.now() - begin} samples=${loaded.sampleCount}`);
      return loaded;
    } catch (error) {
      console.error('VIVID LUT load failed: ' + String(error));
      return null;
    }
  }
}
