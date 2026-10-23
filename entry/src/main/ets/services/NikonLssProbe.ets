/**
 * 诊断用：在应用沙箱内 dlopen 尼康的 `libLsSec-jni.so`，把真实抓包值喂进去。
 *
 * 为什么需要它
 * ------------
 * 设备的 SELinux 策略（`u:r:sh:s0`）不允许执行 `/data/local/tmp` 下的任意文件，
 * 所以独立探针二进制跑不起来；但**应用域可以 dlopen 自己的文件**。于是把同一个
 * 探针做成 NAPI 模块（`vivid_lssprobe`），从这里调用。
 *
 * 它解决的是什么问题
 * ------------------
 * LSS 的加密算法已经从 `libLsSec-jni.so` 完整还原（见
 * `tmp/lssec-algorithm-spec.md`），但 `LsSecGenerateKey` 要吃一个由
 * `LsSec3rdStage` 写进上下文的根值，而那个值依赖"8 个共享根里命中哪一个"，
 * 单靠抓包推不出来。原生库自己最清楚——所以让它自己穷举并打印结果。
 *
 * 这是**诊断代码**，拿到答案后应当移除。
 */

import { common } from '@kit.AbilityKit';
import lssprobe from 'libvivid_lssprobe.so';

const TAG: string = 'VIVID_LSS_PROBE';

export class NikonLssProbe {
  private static ran: boolean = false;

  /**
   * 让原生模块按库名 dlopen 并运行探针。
   *
   * 库随 `entry/libs/arm64-v8a/libLsSec-jni.so` 打包进 HAP，因此走**库名加载**
   * 而不是绝对路径：HarmonyOS 的沙箱只允许应用加载自己 `libs/` 目录里的库，
   * 放在 `filesDir` 里的副本会被 dlopen 拒绝（实测 "No error information"）。
   *
   * 只跑一次；失败不抛异常——它是诊断，不该影响配对流程。
   */
  static async run(context: common.UIAbilityContext, trace: string[]): Promise<void> {
    if (NikonLssProbe.ran) {
      return;
    }
    NikonLssProbe.ran = true;
    try {
      const report: string = lssprobe.probeLss('libLsSec-jni.so');
      for (const line of report.split('\n')) {
        if (line.length > 0) {
          console.info(`${TAG}: ${line}`);
          trace.push(`LSS probe: ${line}`);
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : JSON.stringify(error);
      console.error(`${TAG}: probe failed: ${message}`);
      trace.push(`LSS probe failed: ${message}`);
    }
  }
}
