import { CameraSessionStore } from './CameraSessionStore';
import { SonyCameraService } from './SonyCameraService';
import { NikonPtpIpService } from './NikonPtpIpService';
import { FujifilmNet } from './FujifilmProtocol';

/**
 * 相机控制页（pages/CameraControlPage）的机型线适配层。
 *
 * 为什么需要它
 * ------------
 * 相机控制页原本只为松下的两条协议线而写：Lab 线（remote/* + DTLS 取景，
 * LumixControlService）与 Sync 线（cam.cgi + X-SESSION_ID，
 * LumixSyncControlService）。两者的机型、参数域与状态值都直接来自松下
 * 服务。索尼线（共享 ISO 15740 PTP/IP 传输，见 NikonPtpIpService）与它们
 * 无关：没有 get-setting 参数域，也没有 getstate 状态回读，只有实时取景
 * （0x9201 / 0x9203 / 0x9202）与快门（0x9207）。
 *
 * 尼康线走的是同一条 ISO 15740 PTP/IP 传输（同一个 NikonPtpIpService 单例），
 * 因此控制面与索尼线同构：实时取景 + 快门，没有参数读取通道。它复用松下
 * Lab 线的页面布局与索尼线的按钮面（预览/控制切换、拍摄、录像、取景框点击），
 * 只在「哪些面板有数据」和「身份行」两处与它们不同。
 *
 * 把品牌判断散落在页面里会让每加一条机型线都要改页面布局代码，所以这里
 * 集中三件事：
 *
 *  1. 由 AppStorage 'controlProtocol' 判定当前是哪条线（lab / sync / sony /
 *     nikon）；
 *  2. 哪些参数面板在该线上有数据。没有数据的面板在页面里仍然占位，只是
 *     灰显且不可点（用户要求「没有的参数不可用」，不是隐藏）；
 *  3. 身份回填值（机型名 + 传输方式）。索尼/尼康的机型名是识别阶段写入
 *     CameraSessionStore 的 cameraModel，端口复用各自服务里的 PTP/IP 端口
 *     常量 —— 不新造任何协议常量。
 *
 * 松下两条线在本模块引入前后的行为完全一致：supportsPanel 对非索尼线恒为
 * true，identityLine 只在页面判定为索尼线时才被读取。尼康线的加入同样不改
 * 变它们：supportsPanel 只在协议为 sony / nikon 时才可能返回 false。
 */
export class CameraControlBrand {
  /** AppStorage 'controlProtocol' 的取值；'lab' 也是缺省值。 */
  static readonly PROTOCOL_LAB: string = 'lab';
  static readonly PROTOCOL_SYNC: string = 'sync';
  static readonly PROTOCOL_SONY: string = 'sony';
  static readonly PROTOCOL_NIKON: string = 'nikon';
  static readonly PROTOCOL_FUJIFILM: string = 'fujifilm';

  /** 参数面板无数据时的占位文案（可见但不可用，不是隐藏）。 */
  static readonly UNAVAILABLE_VALUE: string = '不可用';

  /**
   * 索尼线上没有读取通道的参数面板。
   *
   * 这份清单来自代码事实而不是猜测：页面上每个面板都必须有一个取值来源。
   * 索尼线现在有八个参数具备通道——光圈 / 快门 / ISO / 曝光补偿 / 曝光程序模式 /
   * 白平衡 / 画质 / 比例：取值、可选值与「能不能写」都来自相机在
   * `SDIO_GetAllExtDevicePropInfo` (0x9209) 里自己声明的记录，写回走
   * `SDIO_SetExtDevicePropValue` (0x9205)（见 `SonyPtpIpControl`）。
   *
   * 注意「列出来」不等于「一定可调」：真机 ILCE-7M4 的 0x9209 记录里
   * `ExposureProgramMode(20494)` 是 `opt0:ro`（机身上拨盘控制，遥控侧只读），
   * 所以 `mode` 面板会显示当前档位但点不动——这是相机的声明，不是我们的限制。
   * 白平衡 `0x5005:opt15:set` 与画质 / 比例同理按记录决定可写性。
   *
   * `lut`（照片风格）与 `settings` 仍按「不可用」渲染：位置与布局与松下一致，
   * 值显示为「不可用」，点击无效，不会抛异常。
   */
  private static readonly SONY_UNAVAILABLE_PANELS: string[] = [
    'lut', 'settings'
  ];

  /**
   * 尼康线上没有读取通道的参数面板。
   *
   * 与索尼线不同，尼康线当前**没有**把参数域接到页面上：`NikonPtpIpService`
   * 里确实有 `readProperty` / `writeProperty`（`PROP_APERTURE 0x5007`、
   * `PROP_WHITE_BALANCE 0x5005`、`PROP_EXPOSURE_MODE 0x500E`、`PROP_ISO 0x500F`、
   * `PROP_EXPOSURE_COMPENSATION 0x5010`、`PROP_SHUTTER_SPEED 0xD100`），但每个
   * 属性的取值编码（光圈是 f×100？快门是分数还是毫秒？）与可选值集合都还没有
   * 经过真机核对，也没有 `SDIO_GetAllExtDevicePropInfo` 那样由机身自述的记录表
   * 可依赖；而 28 款支持机型里只有 8 款（Z 50 / Z 5 / Z fc / Z 30 / Z f / ZR /
   * Z5II / Z50II）支持 BLE 参数遥控。
   *
   * 因此在机身自述数据可用之前，这些面板按既有的「可见但不可用」约定渲染，
   * 而不是用一个未经核实的映射去显示可能错误的数值。实时取景（0x9201 /
   * 0x9203 / 0x9202）与快门（0x9207）是这条线真正具备的通道，对应页面上的
   * 取景框、预览/控制切换与「拍摄」按钮。
   */
  private static readonly NIKON_UNAVAILABLE_PANELS: string[] = [
    'lut', 'quality', 'aspect', 'settings',
    'mode', 'ev', 'shutter', 'aperture', 'iso', 'wb',
    'metering', 'lvsize'
  ];

  static isSonyProtocol(protocol: string | undefined): boolean {
    return protocol === CameraControlBrand.PROTOCOL_SONY;
  }

  static isNikonProtocol(protocol: string | undefined): boolean {
    return protocol === CameraControlBrand.PROTOCOL_NIKON;
  }

  /**
   * 富士线：自己的 PTP-IP 变体（12 字节包头、私有端口 55740/55741/55742，
   * 不是 ISO 15740 的 15740）。判断只认 `PROTOCOL_FUJIFILM`，
   * 不影响索尼/尼康共用标准传输的判定（`isPtpIpProtocol`）。
   */
  static isFujifilmProtocol(protocol: string | undefined): boolean {
    return protocol === CameraControlBrand.PROTOCOL_FUJIFILM;
  }

  static isSyncProtocol(protocol: string | undefined): boolean {
    return protocol === CameraControlBrand.PROTOCOL_SYNC;
  }

  /**
   * 共享 ISO 15740 PTP/IP 传输的机型线（索尼 / 尼康）。
   *
   * 页面用这个判断「按钮面按 PTP/IP 线渲染」（预览/控制切换 + 芯片式参数条），
   * 而 `isSonyProtocol` 保持只表示索尼：两者的**页面形态**相同，但底层服务调用
   * 不同（SonyLiveView / SonyPtpIpControl 对 NikonPtpIpService），
   * 不能用一个标志同时表达两件事。
   */
  static isPtpIpProtocol(protocol: string | undefined): boolean {
    return CameraControlBrand.isSonyProtocol(protocol) ||
      CameraControlBrand.isNikonProtocol(protocol);
  }

  /** 该机型线上这个参数面板是否有数据可用。 */
  static supportsPanel(protocol: string | undefined, panel: string): boolean {
    if (CameraControlBrand.isSonyProtocol(protocol)) {
      return CameraControlBrand.SONY_UNAVAILABLE_PANELS.indexOf(panel) < 0;
    }
    if (CameraControlBrand.isNikonProtocol(protocol)) {
      return CameraControlBrand.NIKON_UNAVAILABLE_PANELS.indexOf(panel) < 0;
    }
    return true;
  }

  /** 页面顶部的身份行：机型 + 传输方式。索尼/尼康机型由识别阶段回填。 */
  static identityLine(protocol: string | undefined): string {
    const model = CameraSessionStore.instance.cameraModel;
    if (CameraControlBrand.isSonyProtocol(protocol)) {
      const name = model.length > 0 ? model : 'SONY';
      return `${name} · 索尼 PTP/IP 端口 ${SonyCameraService.PTPIP_PORT}`;
    }
    if (CameraControlBrand.isNikonProtocol(protocol)) {
      const name = model.length > 0 ? model : 'NIKON';
      return `${name} · 尼康 PTP/IP 端口 ${NikonPtpIpService.PORT}`;
    }
    if (CameraControlBrand.isFujifilmProtocol(protocol)) {
      const name = model.length > 0 ? model : 'FUJIFILM';
      return `${name} · 富士 PTP-IP 控制 ${FujifilmNet.PORT_CONTROL} / 取景 ${FujifilmNet.PORT_LIVEVIEW} / 事件 ${FujifilmNet.PORT_EVENT}`;
    }
    if (CameraControlBrand.isSyncProtocol(protocol)) {
      return `${model} · LUMIX Sync (cam.cgi)`;
    }
    return `${model} · LUMIX Lab (remote REST)`;
  }
}
