import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/**
 * Camera Raw 风格的 XML 侧车文件。
 *
 * 新侧车保留原图扩展名，例如 photo.rw2 -> photo.rw2.xml。
 * 同名 JPG/RAW 各自保存；读取仍兼容旧 photo.xml 和 photo.xmp。
 * 编辑状态本身使用 EditSession 的稳定 JSON 快照保存，再嵌入 XML，
 * 这样后续增加参数时可以保持向后兼容，同时保留曲线锚点和蒙版笔迹。
 */
export class EditSidecar {
  private static readonly START_TAG: string = '<vivid:state>';
  private static readonly END_TAG: string = '</vivid:state>';

  static write(imageUri: string, state: string, fallbackDirectory: string = ''): boolean {
    const path = EditSidecar.sidecarPath(imageUri);
    const xml = '<?xml version="1.0" encoding="UTF-8"?>\n' +
      '<vivid:sidecar xmlns:vivid="https://vivid.panasonic.local/edit" version="1">\n' +
      '  <vivid:image>' + EditSidecar.escapeXml(imageUri) + '</vivid:image>\n' +
      '  ' + EditSidecar.START_TAG + EditSidecar.escapeXml(state) + EditSidecar.END_TAG + '\n' +
      '</vivid:sidecar>\n';
    const candidates: string[] = [];
    if (path) candidates.push(path);
    const fallback = EditSidecar.fallbackPath(imageUri, fallbackDirectory);
    if (fallback) candidates.push(fallback);
    for (let index = 0; index < candidates.length; index++) {
      if (EditSidecar.writeText(candidates[index], xml)) return true;
    }
    // 媒体库只读或 URI 不支持相邻文件时，保持图片编辑流程可用。
    return false;
  }

  static read(imageUri: string, fallbackDirectory: string = ''): string | null {
    const basePath = EditSidecar.baseImagePath(imageUri);
    const candidates: string[] = [];
    if (basePath) {
      const path = EditSidecar.imagePath(imageUri);
      if (path) { candidates.push(path + '.xml'); candidates.push(path + '.xmp'); }
      candidates.push(basePath + '.xml');
      candidates.push(basePath + '.xmp');
    }
    const fallback = EditSidecar.fallbackPath(imageUri, fallbackDirectory);
    if (fallback) candidates.push(fallback);
    for (let index = 0; index < candidates.length; index++) {
      const content = EditSidecar.readText(candidates[index]);
      if (!content) continue;
      const start = content.indexOf(EditSidecar.START_TAG);
      if (start < 0) continue;
      const valueStart = start + EditSidecar.START_TAG.length;
      const end = content.indexOf(EditSidecar.END_TAG, valueStart);
      if (end < 0) continue;
      return EditSidecar.unescapeXml(content.substring(valueStart, end));
    }
    return null;
  }

  private static writeText(path: string, content: string): boolean {
    try {
      const encoded = util.TextEncoder.create().encodeInto(content);
      const opened = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(opened.fd, encoded.buffer as ArrayBuffer);
      } finally {
        fileIo.closeSync(opened);
      }
      return true;
    } catch (_error) {
      return false;
    }
  }

  private static readText(path: string): string | null {
    try {
      const stat = fileIo.statSync(path);
      if (stat.size <= 0 || stat.size > 8 * 1024 * 1024) return null;
      const buffer = new ArrayBuffer(stat.size);
      const opened = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(opened.fd, buffer);
      } finally {
        fileIo.closeSync(opened);
      }
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
    } catch (_error) {
      return null;
    }
  }

  private static sidecarPath(imageUri: string): string | null {
    const path = EditSidecar.imagePath(imageUri);
    return path ? path + '.xml' : null;
  }

  private static fallbackPath(imageUri: string, directory: string): string | null {
    if (!directory || !imageUri) return null;
    let leaf = imageUri;
    const slash = Math.max(leaf.lastIndexOf('/'), leaf.lastIndexOf('\\'));
    if (slash >= 0) leaf = leaf.substring(slash + 1);
    const dot = leaf.lastIndexOf('.');
    if (dot > 0) leaf = leaf.substring(0, dot);
    const safeLeaf = leaf.replace(/[^A-Za-z0-9_-]/g, '_');
    let hash = 0;
    for (let index = 0; index < imageUri.length; index++) {
      hash = (hash * 31 + imageUri.charCodeAt(index)) % 2147483647;
    }
    const separator = directory.endsWith('/') || directory.endsWith('\\') ? '' : '/';
    return directory + separator + 'vivid_' + safeLeaf + '_' + Math.abs(hash).toString(16) + '.xml';
  }

  private static baseImagePath(imageUri: string): string | null {
    const path = EditSidecar.imagePath(imageUri);
    if (!path) return null;
    const slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const dot = path.lastIndexOf('.');
    return dot > slash ? path.substring(0, dot) : path;
  }

  private static imagePath(imageUri: string): string | null {
    if (!imageUri || imageUri.length === 0) return null;
    let path = imageUri;
    if (path.indexOf('file://') === 0) {
      path = path.substring('file://'.length);
    } else if (path.indexOf('://') >= 0) {
      // 无法对 datashare/content URI 写入同目录侧车文件。
      return null;
    }
    try {
      path = decodeURIComponent(path);
    } catch (_error) {
      // 路径没有转义时直接使用原值。
    }
    const query = path.indexOf('?');
    if (query >= 0) path = path.substring(0, query);
    const hash = path.indexOf('#');
    if (hash >= 0) path = path.substring(0, hash);
    return path;
  }

  private static escapeXml(value: string): string {
    return value
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&apos;');
  }

  private static unescapeXml(value: string): string {
    return value
      .replace(/&apos;/g, "'")
      .replace(/&quot;/g, '"')
      .replace(/&gt;/g, '>')
      .replace(/&lt;/g, '<')
      .replace(/&amp;/g, '&');
  }
}
