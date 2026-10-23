/**
 * 服务层「详细日志」的唯一出口。
 *
 * 为什么不复用 `AppDiagnostics`：那条链路是**白名单重建** —— 它把原始文本丢掉，
 * 只保留固定字段名、枚举和数字（见 `AppDiagnostics.event`：`stage()` 认不出就
 * 直接 return，整条事件消失）。隐私上这是对的，但协议细节（走到哪一步、相机回了
 * 什么码、哪个槽位）因此全部丢失，真机复现问题时看不出链路走向。
 *
 * 本 sink 走 `AppLogStore` → 每日落盘 → 「我的 → 问题反馈 → 发送日志」上传。
 * 文本保留，但**仍然经过 `AppLogPolicy.sanitize`**（URL / 沙箱路径 / UUID /
 * MAC / SSID / 序列号会被打码，单行上限 900 字符），所以不会把敏感值带出去。
 *
 * 为什么必须限流：协议层可能每秒几十行（状态轮询、逐包收发）。内存环形缓冲只有
 * 300 行、单日文件上限 4 MB，不限流会把真正的复现现场冲掉。这里做「每秒条数上限
 * + 连续重复折叠」，并在限流发生时留一行计数，便于判断日志是否被截断。
 */
export class AppLogSink {
  private static writer: ((message: string) => void) | null = null;
  private static windowStartMs: number = 0;
  private static windowEmitted: number = 0;
  private static windowDropped: number = 0;
  private static lastLine: string = '';
  private static repeatCount: number = 0;
  /** 每秒最多落盘的行数。真机复现一轮通常在几十秒内，这个量足够画出链路。 */
  private static readonly MAX_LINES_PER_SECOND: number = 24;
  /** 连续重复的前几条照记，之后按计数折叠。 */
  private static readonly REPEAT_KEEP_FIRST: number = 4;
  /** 折叠后每隔多少条补一行计数。 */
  private static readonly REPEAT_REPORT_EVERY: number = 50;

  /** 由 EntryAbility 在 `AppLogStore.init` 之后注入，服务层不反向依赖页面模块。 */
  static install(writer: ((message: string) => void) | null): void {
    AppLogSink.writer = writer;
    AppLogSink.windowStartMs = 0;
    AppLogSink.windowEmitted = 0;
    AppLogSink.windowDropped = 0;
    AppLogSink.lastLine = '';
    AppLogSink.repeatCount = 0;
  }

  /**
   * 记录一条协议/链路日志。
   * @param tag 来源标签（如 `CTL`、`CTL_ERR`），便于在反馈日志里按来源过滤。
   * @param message 原始文本，落盘前会被 `AppLogPolicy.sanitize` 打码。
   */
  static emit(tag: string, message: string): void {
    try {
      const writer = AppLogSink.writer;
      if (writer === null) return;
      if (message.length === 0) return;
      const line = tag.length > 0 ? `${tag} ${message}` : message;
      const now = Date.now();
      if (now - AppLogSink.windowStartMs >= 1000) {
        if (AppLogSink.windowDropped > 0) {
          writer(`LOG 限流 上一秒丢弃 ${AppLogSink.windowDropped} 条（上限 ${AppLogSink.MAX_LINES_PER_SECOND}/秒）`);
        }
        AppLogSink.windowStartMs = now;
        AppLogSink.windowEmitted = 0;
        AppLogSink.windowDropped = 0;
      }
      if (line === AppLogSink.lastLine) {
        AppLogSink.repeatCount += 1;
        if (AppLogSink.repeatCount <= AppLogSink.REPEAT_KEEP_FIRST) {
          if (!AppLogSink.takeSlot()) return;
          writer(`${line} #${AppLogSink.repeatCount + 1}`);
          return;
        }
        if (AppLogSink.repeatCount % AppLogSink.REPEAT_REPORT_EVERY === 0) {
          if (!AppLogSink.takeSlot()) return;
          writer(`${line} (重复 ${AppLogSink.repeatCount + 1} 次)`);
        }
        return;
      }
      AppLogSink.lastLine = line;
      AppLogSink.repeatCount = 0;
      if (!AppLogSink.takeSlot()) return;
      writer(line);
    } catch (_error) {
      // 日志永远不能影响相机操作：任何失败都在这里吞掉。
    }
  }

  private static takeSlot(): boolean {
    if (AppLogSink.windowEmitted >= AppLogSink.MAX_LINES_PER_SECOND) {
      AppLogSink.windowDropped += 1;
      return false;
    }
    AppLogSink.windowEmitted += 1;
    return true;
  }
}
