import { CustomLut, parseLutText } from '../models/LutLibrary';
import { util } from '@kit.ArkTS';

/**
 * TaskPool 后台 LUT 文本解析入口。大尺寸 33^3/64^3 表的字符串解析在
 * 后台线程完成，避免一次性读取队列占用 UI 线程造成页面卡顿。
 */
@Concurrent
export function parseLutTextTask(source: string, uri: string): CustomLut | null {
  return parseLutText(source, uri);
}

@Concurrent
export function parseLutBytesTask(bytes: ArrayBuffer, uri: string): CustomLut | null {
  return parseLutText(util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(bytes)), uri);
}
