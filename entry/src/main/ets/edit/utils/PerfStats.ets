import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 可开关的调试统计：记录滑块回调耗时、像素读取/后台任务耗时、
 * 任务队列状态、被丢弃任务数、PixelMap 创建数。默认关闭；
 * AppStorage.setOrCreate('vividPerfStats', true) 开启，每 20 次任务
 * 汇总输出一次到 HiLog（domain 0x0001, tag VIVID_PERF）。
 */
export class PerfStats {
  private static enabled: boolean = false;
  private static phaseAccumMs: Map<string, number> = new Map();
  private static phaseCounts: Map<string, number> = new Map();
  private static discardedRuns: number = 0;
  private static stalePublishes: number = 0;
  private static queuedRuns: number = 0;
  private static pixelMapCreates: number = 0;
  private static runCounter: number = 0;
  private static lastDumpRuns: number = 0;
  private static sliderCallbackMs: number = 0;
  private static sliderCallbackCount: number = 0;

  static refreshEnabled(): void {
    PerfStats.enabled = (AppStorage.get<boolean>('vividPerfStats') ?? false) === true;
  }

  static isEnabled(): boolean {
    return PerfStats.enabled;
  }

  /** 记录一个命名的耗时阶段（readPixels / worker / geometry / publish…）。 */
  static recordPhase(name: string, elapsedMs: number): void {
    if (!PerfStats.enabled) return;
    PerfStats.phaseAccumMs.set(name, (PerfStats.phaseAccumMs.get(name) ?? 0) + elapsedMs);
    PerfStats.phaseCounts.set(name, (PerfStats.phaseCounts.get(name) ?? 0) + 1);
  }

  static recordSliderCallback(elapsedMs: number): void {
    if (!PerfStats.enabled) return;
    PerfStats.sliderCallbackMs += elapsedMs;
    PerfStats.sliderCallbackCount++;
  }

  static recordDiscardedRun(): void {
    if (PerfStats.enabled) PerfStats.discardedRuns++;
  }

  static recordStalePublish(): void {
    if (PerfStats.enabled) PerfStats.stalePublishes++;
  }

  static recordQueued(): void {
    if (PerfStats.enabled) PerfStats.queuedRuns++;
  }

  static recordPixelMapCreate(): void {
    if (PerfStats.enabled) PerfStats.pixelMapCreates++;
  }

  /** 每次任务完成时调用；累计 20 次后输出一次汇总。 */
  static tick(): void {
    if (!PerfStats.enabled) return;
    PerfStats.runCounter++;
    if (PerfStats.runCounter - PerfStats.lastDumpRuns < 20) return;
    PerfStats.lastDumpRuns = PerfStats.runCounter;
    PerfStats.dump();
  }

  static summary(): string {
    let phases = '';
    PerfStats.phaseAccumMs.forEach((ms: number, name: string) => {
      const count = PerfStats.phaseCounts.get(name) ?? 0;
      const avg = count > 0 ? (ms / count).toFixed(1) : '0';
      phases += `${name}=${avg}ms(n=${count}) `;
    });
    const sliderAvg = PerfStats.sliderCallbackCount > 0 ?
      (PerfStats.sliderCallbackMs / PerfStats.sliderCallbackCount).toFixed(2) : '0';
    return `VIVID_PERF runs=${PerfStats.runCounter} discarded=${PerfStats.discardedRuns} ` +
      `stalePublish=${PerfStats.stalePublishes} queued=${PerfStats.queuedRuns} ` +
      `pixelMapCreates=${PerfStats.pixelMapCreates} sliderCallbackAvg=${sliderAvg}ms | ${phases}`;
  }

  static dump(): void {
    if (!PerfStats.enabled) return;
    try {
      hilog.info(0x0001, 'VIVID_PERF', '%{public}s', PerfStats.summary());
    } catch (_error) {
      console.info(PerfStats.summary());
    }
  }
}
