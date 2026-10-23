/**
 * 索尼相机 USB（PTP over USB）连接层。
 *
 * 为什么单独一份
 * --------------
 * 现有的 `LumixCameraService.connectUsbCamera()` 是**松下专用**：标准 PTP
 * `OpenSession` 之后还要做一次松下厂商授权（`0x9102` + `LUMIX_CONNECT_VERSION`），
 * 索尼机身不应答这一步，于是必然落到通用 catch，表现为「USB 相机握手失败」。
 * 索尼只需要标准 PTP；厂商扩展走索尼自己的 SDIO 操作码（与 PTP/IP 侧同一套，
 * 见 `SonyPtpIpContent.OP_SDIO_CONNECT` 等）。
 *
 * 本文件只做「连上 + 问清相机能干什么」，不做业务：
 *   1. 枚举带 PTP 接口的 USB 设备，挑出索尼（VID 0x054C）
 *   2. 申请权限 → 打开管道 → 选中 Still Image/PTP 接口 → claim + setInterface
 *   3. 标准 PTP `OpenSession`(0x1002)
 *   4. `GetDeviceInfo`(0x1001)，解析相机自报的能力表
 *   5. 依据 **OperationsSupported**（相机自己声明的操作集）判定该进哪个页面
 *
 * 为什么用 OperationsSupported 判定
 * ---------------------------------
 * 用户要的是「根据相机反馈的指令接入图像传输页或相机控制页」。PTP 的
 * DeviceInfo 里 `OperationsSupported` 就是相机自报的“我会哪些操作”，比按机型
 * 名硬编码可靠：同一机型不同固件、或相机当前处于 PC遥控/传输 模式，操作集
 * 会随之变化。判定规则见 `decideRoute()`；原始操作表按十六进制全量落日志，
 * 判定错了也能离线复核。
 *
 * 只读约定：除 `OpenSession` / `CloseSession` 外只发查询类操作，不改相机设置。
 *
 * @since 2026-10
 */

import usbManager from '@ohos.usbManager';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';
import { LumixCameraService } from './LumixCameraService';
import { NikonPtpIpService, NikonPtpResponse, PtpTransport } from './NikonPtpIpService';

const DOMAIN: number = 0x0001;
const TAG: string = 'VIVID_SONY_USB';

/** PTP 容器头：u32 length + u16 type + u16 code + u32 transactionId。 */
const PTP_CONTAINER_HEADER_SIZE: number = 12;
const PTP_CONTAINER_COMMAND: number = 1;
const PTP_CONTAINER_DATA: number = 2;
const PTP_CONTAINER_RESPONSE: number = 3;

/** 标准 PTP 操作。 */
const PTP_OP_GET_DEVICE_INFO: number = 0x1001;
const PTP_OP_OPEN_SESSION: number = 0x1002;
const PTP_OP_CLOSE_SESSION: number = 0x1003;
/** 索尼 SDIO 控制操作（与 PTP/IP 侧同一套码）。 */
const SONY_OP_SDIO_CONNECT: number = 0x9201;
const SONY_OP_GET_EXT_DEVICE_INFO: number = 0x9202;
const SONY_OP_GET_ALL_EXT_DEVICE_PROP_INFO: number = 0x9209;
const SONY_OP_SET_CONTENTS_TRANSFER_MODE: number = 0x9212;
const SONY_OP_GET_CAPTURED_DATE_LIST: number = 0x923B;
const SONY_OP_GET_CONTENTS_INFO_LIST: number = 0x923C;
/** 设备描述文件（DD / DID）。arg1=1 → DD_XML，arg1=2 → DID_XML。 */
const SONY_OP_GET_DEVICE_DESCRIPTION_FILE: number = 0x923A;
/** 索尼厂商会话开启（官方 USB 路径首选）。 */
const SONY_OP_SDIO_OPEN_SESSION: number = 0x9210;
/** 会话号，与 PTP/IP 侧一致。 */
const SONY_SESSION_ID: number = 1;
/**
 * 功能模式（`EnumFunctionMode`，官方 smali 已核对）：
 * 0 = REMOTE_CONTROL，1 = CONTENTS_TRANSFER，2 = REMOTE_CONTROL_WITH_TRANSFER。
 *
 * 这是「相机自报的指令」真正起作用的地方：官方 `adjustFunctionMode()` 读取 DID
 * 的 `X_ServerVersion`，`>= 4.0` 就把模式升级为 2 —— 于是**同一条会话**既能进
 * 相机控制页，也能进图片传输页；而页面本身由用户点的入口决定，不是相机决定的。
 */
const SONY_FUNCTION_MODE_REMOTE_CONTROL: number = 0;
const SONY_FUNCTION_MODE_CONTENTS_TRANSFER: number = 1;
const SONY_FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER: number = 2;
/** 官方 `adjustFunctionMode()` 的阈值（Initializer.java:58-77）。 */
const SONY_SERVER_VERSION_MODE2_THRESHOLD: number = 4.0;
/** DID 里的 ServerVersion 元素名。 */
const DID_SERVER_VERSION_KEY: string = 'ServerVersion';

/** `SDIO_SetControlDeviceA`：写属性（ISO / 光圈 / 控制权），官方 0x9205。 */
const SONY_OP_SET_CONTROL_DEVICE_A: number = 0x9205;
/** 标准 `GetObject`，USB 上索尼用它送实时取景帧与照片。 */
const PTP_OP_GET_OBJECT: number = 0x1009;
/**
 * `PROP_SONY_PRIORITY_MODE = 0xD25A`：`1` 表示「USB 主机取得控制权」。
 *
 * 公开实现（argallo/sony-camera-android, α6600 实测）在连接时夺取、断开时释放，
 * README 原话是 *releases Sony's "host has priority" flag*。不设这个，相机会把
 * 快门/属性写入当作外部干扰而拒绝。
 */
const SONY_PROP_PRIORITY_MODE: number = 0xD25A;
/**
 * 索尼的「魔数对象句柄」：`GetObject` 传这两个句柄就能拿到实时取景帧 / 照片，
 * 而不是去翻存储卡上的对象。公开实现与 libgphoto2 都用它。
 */
const SONY_LIVEVIEW_OBJECT_HANDLE: number = 0xFFFFC002;
const SONY_PHOTO_OBJECT_HANDLE: number = 0xFFFFC001;
/** 取流时要带在 data-out 阶段的图像类型（小端 u16）：0xC001 照片 / 0xC002 取景。 */
const SONY_IMAGE_TYPE_PHOTO: number = 0xC001;
const SONY_IMAGE_TYPE_LIVEVIEW: number = 0xC002;

const PTP_RESPONSE_OK: number = 0x2001;
const PTP_RESPONSE_SESSION_ALREADY_OPEN: number = 0x201E;

/** Sony Corporation 的 USB 厂商号。 */
const SONY_VENDOR_ID: number = 0x054C;
/** Still Image / PTP 接口类、子类、协议。 */
const USB_PTP_INTERFACE_CLASS: number = 0x06;
const USB_PTP_INTERFACE_SUBCLASS: number = 0x01;
const USB_PTP_INTERFACE_PROTOCOL: number = 0x01;
/** USB 端点类型 2 = bulk。 */
const USB_ENDPOINT_TYPE_BULK: number = 2;

const BULK_TIMEOUT_MS: number = 3000;
const BULK_IN_BUFFER_BYTES: number = 64 * 1024;

/** 相机自报的能力集（PTP DeviceInfo 数据集）。 */
export interface SonyUsbDeviceInfo {
  manufacturer: string;
  model: string;
  deviceVersion: string;
  serialNumber: string;
  standardVersion: number;
  vendorExtensionId: number;
  vendorExtensionVersion: number;
  functionalMode: number;
  /** 相机自报支持的操作码（16 位）。这就是路由依据。 */
  operations: number[];
  events: number[];
  properties: number[];
  captureFormats: number[];
  imageFormats: number[];
}

/** 一次 USB 探测的结果。 */
export interface SonyUsbProbe {
  ok: boolean;
  message: string;
  deviceName: string;
  vendorId: number;
  productId: number;
  info: SonyUsbDeviceInfo | null;
  /** 能否做相机控制（遥控拍摄）。 */
  controlSupported: boolean;
  /** 能否做图像传输（内容浏览/下载）。 */
  transferSupported: boolean;
  /** 'control' | 'transfer' | 'both' | 'unsupported' */
  route: string;
  /** 相机自报操作表的十六进制摘要，便于离线复核判定。 */
  operationsHex: string;
  /**
   * DID 里 `X_ServerVersion` 的数值；读不到时为 -1。
   *
   * 这是**相机自报、真正影响行为的那个值**：官方用它决定开会话时传的
   * functionMode（>= 4.0 时升级为 REMOTE_CONTROL_WITH_TRANSFER）。
   */
  serverVersion: number;
  /** 实际传给 `SDIO_OpenSession` 的 functionMode（0/1/2）。 */
  functionMode: number;
}

/** PTP 容器。 */
export interface SonyUsbContainer {
  type: number;
  code: number;
  transactionId: number;
  payload: Uint8Array;
}

/** 接口选择结果。 */
interface SonyUsbSelection {
  config: usbManager.USBConfiguration;
  iface: usbManager.USBInterface;
  bulkIn: usbManager.USBEndpoint;
  bulkOut: usbManager.USBEndpoint;
}

interface SonyPtpStringRead {
  value: string;
  nextOffset: number;
}

interface SonyPtpArrayRead {
  values: number[];
  nextOffset: number;
}

export class SonyUsbPtp {
  /** 用户意图「相机控制」对应的 functionMode。 */
  static readonly MODE_REMOTE_CONTROL: number = SONY_FUNCTION_MODE_REMOTE_CONTROL;
  /** 用户意图「图片传输」对应的 functionMode。 */
  static readonly MODE_CONTENTS_TRANSFER: number = SONY_FUNCTION_MODE_CONTENTS_TRANSFER;

  private static pipe: usbManager.USBDevicePipe | null = null;
  private static iface: usbManager.USBInterface | null = null;
  private static bulkIn: usbManager.USBEndpoint | null = null;
  private static bulkOut: usbManager.USBEndpoint | null = null;
  private static transactionId: number = 0;
  private static sessionOpen: boolean = false;
  /** 最近一次事务用的 transactionId，供 `enqueue` 取回对应响应。 */
  private static lastTransactionId: number = 0;
  /** 串行化：同一时刻只允许一个事务占用 bulk 端点。 */
  private static queueTail: Promise<void> = Promise.resolve();
  /** 建立会话时实际生效的开启操作码 / 响应码（供 `PtpTransport` 暴露）。 */
  private static openedWithOpcode: number = 0;
  private static openedWithCode: number = -1;
  /** 事务层是否已失效（传输错误后置位，避免后续调用继续等超时）。 */
  private static transportFailed: boolean = false;
  /**
   * 连续失败计数：**只有连续失败才置毒**。
   *
   * 以前 `execute` 的 catch 里直接 `transportFailed = true`，而全文没有任何复位点，
   * 于是任何一次超时（快门、取帧、CloseSession 任一条）都会把这根 USB 管道永久
   * 判死：`enqueue` 从此立刻抛 "Sony USB transport is unavailable"，而 `probe()`
   * 走裸 `transaction()` 仍能成功 —— 真机表现就是「能连上、取景还在出、快门再也
   * 没反应，且重插无效」。单帧取回失败本来只是「下一帧再试」，不该升级成毒化。
   */
  private static consecutiveFailures: number = 0;
  private static readonly MAX_CONSECUTIVE_FAILURES: number = 3;
  /** 实际生效的 functionMode（0 控制 / 1 传输 / 2 两者），-1 表示未知。 */
  private static functionMode: number = -1;
  private static transportInstance: SonyUsbTransport | null = null;

  private static log(message: string): void {
    try { hilog.info(DOMAIN, TAG, '%{public}s', message); } catch (_error) { }
    AppLogSink.emit('CTL', 'sony-usb ' + message);
  }

  static isOpen(): boolean {
    return SonyUsbPtp.pipe !== null && SonyUsbPtp.sessionOpen;
  }

  /**
   * 枚举可作为索尼相机接入的 USB 设备。
   *
   * 复用 `LumixCameraService.scanUsbCameras()`：它已经包含「有 Still Image/PTP
   * 接口即保留」的规则，并且对厂商字符串为空的机身也保留，避免漏设备。这里再
   * 按索尼 VID 或 PTP 接口过滤一次，避免把松下机身当索尼。
   */
  static listDevices(): Array<Readonly<usbManager.USBDevice>> {
    const found: Array<Readonly<usbManager.USBDevice>> = [];
    try {
      const candidates = LumixCameraService.scanUsbCameras();
      for (const device of candidates) {
        const name = `${device.manufacturerName} ${device.productName}`.toUpperCase();
        const isSony = device.vendorId === SONY_VENDOR_ID || name.indexOf('SONY') >= 0 ||
          name.indexOf('ILCE') >= 0 || name.indexOf('ZV-E') >= 0 || name.indexOf('DSC-') >= 0;
        const hasPtp = SonyUsbPtp.findSelection(device) !== null;
        if (isSony) {
          found.unshift(device);
        } else if (hasPtp) {
          // 非索尼的 PTP 机身（松下/尼康）也能被 `findSelection` 认出来，只能当
          // 兜底候选；否则「同时插着 LUMIX 与索尼」时 `connectSonyUsb` 取
          // `devices[0]` 会选中松下，随后 probe 到的是松下机身。
          found.push(device);
        }
      }
    } catch (error) {
      SonyUsbPtp.log('list-devices failed code=' + SonyUsbPtp.errorCode(error));
    }
    return found;
  }

  /** 是否有可用的索尼 USB 设备（用于 UI 判断要不要走 USB 通道）。 */
  static hasDevice(): boolean {
    return SonyUsbPtp.listDevices().length > 0;
  }

  /** 找到 Still Image/PTP 接口及其 bulk IN/OUT 端点。 */
  private static findSelection(device: Readonly<usbManager.USBDevice>): SonyUsbSelection | null {
    const configurations = device.configs || [];
    for (const config of configurations) {
      for (const candidate of config.interfaces) {
        const bulkIn = candidate.endpoints.find((endpoint: usbManager.USBEndpoint) =>
          endpoint.type === USB_ENDPOINT_TYPE_BULK &&
          endpoint.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_FROM_DEVICE);
        const bulkOut = candidate.endpoints.find((endpoint: usbManager.USBEndpoint) =>
          endpoint.type === USB_ENDPOINT_TYPE_BULK &&
          endpoint.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_TO_DEVICE);
        if (!bulkIn || !bulkOut) continue;
        const classMatches = candidate.clazz === USB_PTP_INTERFACE_CLASS &&
          (candidate.subClass === USB_PTP_INTERFACE_SUBCLASS || candidate.subClass === 0) &&
          (candidate.protocol === USB_PTP_INTERFACE_PROTOCOL || candidate.protocol === 0);
        if (classMatches) {
          return { config: config, iface: candidate, bulkIn: bulkIn, bulkOut: bulkOut };
        }
      }
    }
    return null;
  }

  /**
   * 连上并问清相机能做什么。
   *
   * 失败一律返回结构化结果而不是抛异常，调用方据此提示用户（例如相机处在
   * 存储模式、未授权、被其他软件占用）。成功后**保持会话打开**，业务页面
   * 可直接通过 `SonyUsbPtp.transaction()` 继续操作；用完必须 `close()`。
   */
  static async probe(device: Readonly<usbManager.USBDevice>,
    requestedMode: number = SONY_FUNCTION_MODE_CONTENTS_TRANSFER): Promise<SonyUsbProbe> {
    // 每次重连都是一次全新的机会：不清掉上一个会话留下的毒化标记，重插线也没用。
    SonyUsbPtp.resetFailures();
    const result: SonyUsbProbe = {
      ok: false,
      message: '',
      deviceName: device.name,
      vendorId: device.vendorId,
      productId: device.productId,
      info: null,
      controlSupported: false,
      transferSupported: false,
      route: 'unsupported',
      operationsHex: '',
      serverVersion: -1,
      functionMode: SONY_FUNCTION_MODE_CONTENTS_TRANSFER,
    };
    const selection = SonyUsbPtp.findSelection(device);
    if (selection === null) {
      result.message = '相机没有提供 PTP 接口：请把 USB 连接模式设为「PC遥控」或「电脑」，不要用「大容量存储」';
      SonyUsbPtp.log('probe no-ptp-interface');
      return result;
    }
    try {
      const granted = await SonyUsbPtp.ensureRight(device.name);
      if (!granted) {
        result.message = '未获得 USB 设备授权，请在系统弹窗中选择允许';
        SonyUsbPtp.log('probe permission-denied');
        return result;
      }
      SonyUsbPtp.pipe = usbManager.connectDevice(device as usbManager.USBDevice);
      if (!SonyUsbPtp.pipe) {
        result.message = '无法打开相机 USB 通道';
        SonyUsbPtp.log('probe pipe-failed');
        return result;
      }
      const configResult = usbManager.setConfiguration(SonyUsbPtp.pipe, selection.config);
      SonyUsbPtp.log(`probe configuration=${configResult}`);
      SonyUsbPtp.iface = selection.iface;
      SonyUsbPtp.bulkIn = selection.bulkIn;
      SonyUsbPtp.bulkOut = selection.bulkOut;
      const claimed = usbManager.claimInterface(SonyUsbPtp.pipe, selection.iface, true);
      if (claimed !== 0) {
        result.message = `无法占用相机 USB 接口（${claimed}），请关闭其他相机软件后重试`;
        SonyUsbPtp.log(`probe claim-failed code=${claimed}`);
        await SonyUsbPtp.close();
        return result;
      }
      const activated = usbManager.setInterface(SonyUsbPtp.pipe, selection.iface);
      SonyUsbPtp.log(`probe interface=${activated}`);

      // 官方 USB 顺序（Initializer.java:109-261）：
      //   0x1001 → 0x923A(1=DD) → 0x923A(2=DID) → 调整 functionMode
      //   → 0x9210(1, mode) → 0x9201(1) → 0x9201(2) → 0x9216 → 0x9202(300) → 0x9201(3)
      // 其中 0x9201/0x9216/0x9202 及其后的属性读取由 `SonyPtpIpContent` 的
      // `setupSonySession()` 负责（USB 与 PTP/IP 共用同一套），这里只做到开会话。
      //
      // 注意：官方 USB **从不发标准 OpenSession(0x1002)** —— `PtpUsbClient`
      // 强制 `mIsMtpEnabled = true`，`createOpenSessionState()` 因此总走 0x9210
      // 分支（PtpUsbClient.java:193、Initializer.java:79-97）。所以这里也只试 0x9210。
      SonyUsbPtp.transactionId = 0;
      const info = await SonyUsbPtp.getDeviceInfo();
      if (info === null) {
        result.message = '相机未返回设备信息（GetDeviceInfo 失败）：请解锁相机并选择「PC遥控/电脑」USB 模式';
        SonyUsbPtp.log('probe device-info-failed');
        return result;
      }
      result.info = info;
      result.operationsHex = SonyUsbPtp.hexList(info.operations);
      result.serverVersion = await SonyUsbPtp.readServerVersion(info);
      SonyUsbPtp.log(`device manufacturer=${SonyUsbPtp.safeText(info.manufacturer)} ` +
        `model=${SonyUsbPtp.safeText(info.model)} version=${SonyUsbPtp.safeText(info.deviceVersion)} ` +
        `vendorExt=0x${SonyUsbPtp.hex8(info.vendorExtensionId)} opsCount=${info.operations.length}`);
      SonyUsbPtp.log('device operations=' + result.operationsHex);

      // vendorExtensionId == 0xFFFFFFFF 表示相机处在标准 MTP（大容量/媒体）模式，
      // 官方据此判定 CAMERA_MTP_MODE_FAIL 并要求用户改相机 USB 设置
      // （UsbSupportedCameraManager.java:383-391）。
      if (info.vendorExtensionId === 0xFFFFFFFF) {
        result.message = '相机处于 MTP/媒体传输模式：请在相机 USB 设置里改选「PC遥控」或「电脑」后重试';
        SonyUsbPtp.log('probe mtp-mode vendorExt=ffffffff');
        await SonyUsbPtp.close();
        return result;
      }

      // `adjustFunctionMode()`（Initializer.java:58-77）：相机自报 ServerVersion
      // >= 4.0 时**升级**为 REMOTE_CONTROL_WITH_TRANSFER，这样同一条会话既能
      // 进相机控制页也能进图片传输页。它从不降级 —— 读不到或 < 4.0 就保留调用方
      // 请求的 mode，也就是用户点的那个入口。注意只有「升到 2」这一条映射，
      // 不存在 2→0/1 的修正。
      const mode = result.serverVersion >= SONY_SERVER_VERSION_MODE2_THRESHOLD ?
        SONY_FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER : requestedMode;
      result.functionMode = mode;
    SonyUsbPtp.functionMode = mode;
      SonyUsbPtp.log(`function-mode requested=${requestedMode} applied=${mode} ` +
        `serverVersion=${result.serverVersion.toFixed(2)} ` +
        `threshold=${SONY_SERVER_VERSION_MODE2_THRESHOLD.toFixed(2)}`);

      const open = await SonyUsbPtp.transaction(SONY_OP_SDIO_OPEN_SESSION, [SONY_SESSION_ID, mode]);
      const openId = SonyUsbPtp.lastTransactionId;
      const openCode = SonyUsbPtp.responseCode(open, openId);
      SonyUsbPtp.openedWithOpcode = SONY_OP_SDIO_OPEN_SESSION;
      SonyUsbPtp.openedWithCode = openCode;
      SonyUsbPtp.log(`probe sdio-open-session mode=${mode} code=0x${SonyUsbPtp.hex16(openCode)}`);
      if (openCode !== PTP_RESPONSE_OK && openCode !== PTP_RESPONSE_SESSION_ALREADY_OPEN) {
        result.message = `相机未接受 USB 会话（0x${SonyUsbPtp.hex16(openCode)}）：` +
          `请解锁相机并选择「PC遥控/电脑」USB 模式，并关闭其他相机软件`;
        await SonyUsbPtp.close();
        return result;
      }
      SonyUsbPtp.sessionOpen = true;
      SonyUsbPtp.decideRoute(result);
      SonyUsbPtp.log(`route=${result.route} control=${result.controlSupported ? 1 : 0} ` +
        `transfer=${result.transferSupported ? 1 : 0}`);
      if (result.route === 'unsupported') {
        result.message = '相机没有声明可用的遥控或传输操作，无法进入任何页面';
        await SonyUsbPtp.close();
        return result;
      }
      result.ok = true;
      result.message = `USB 已连接 · ${info.model.length > 0 ? info.model : device.productName}`;
      return result;
    } catch (error) {
      result.message = 'USB 连接异常，请重新插拔相机后重试';
      SonyUsbPtp.log('probe failed code=' + SonyUsbPtp.errorCode(error));
      await SonyUsbPtp.close();
      return result;
    }
  }

  /**
   * 依据相机自报的操作集决定路由。
   *
   * 判定用的是相机自己声明的操作码，而不是机型名：
   *   - 遥控/控制：出现索尼 SDIO 控制操作（`0x9201`/`0x9202`/`0x9209`）之一
   *   - 图像传输：出现内容清单类操作（`0x923B`/`0x923C`/`0x9212`）之一，
   *     或标准对象浏览（`0x1007`/`0x1008`）
   * 两者都有时进 control（控制页自带「图片传输」入口）；都没有则 unsupported。
   */
  private static decideRoute(result: SonyUsbProbe): void {
    const info = result.info;
    if (info === null) return;
    const has = (code: number): boolean => info.operations.indexOf(code) >= 0;
    result.controlSupported = has(SONY_OP_SDIO_CONNECT) || has(SONY_OP_GET_EXT_DEVICE_INFO) ||
      has(SONY_OP_GET_ALL_EXT_DEVICE_PROP_INFO);
    result.transferSupported = has(SONY_OP_GET_CAPTURED_DATE_LIST) ||
      has(SONY_OP_GET_CONTENTS_INFO_LIST) || has(SONY_OP_SET_CONTENTS_TRANSFER_MODE) ||
      has(0x1007) || has(0x1008);
    if (result.controlSupported && result.transferSupported) {
      result.route = 'both';
    } else if (result.controlSupported) {
      result.route = 'control';
    } else if (result.transferSupported) {
      result.route = 'transfer';
    } else {
      result.route = 'unsupported';
    }
  }

  /** `GetDeviceInfo`：读取并解析 PTP DeviceInfo 数据集。 */
  private static async getDeviceInfo(): Promise<SonyUsbDeviceInfo | null> {
    const containers = await SonyUsbPtp.transaction(PTP_OP_GET_DEVICE_INFO, []);
    const code = SonyUsbPtp.responseCode(containers, SonyUsbPtp.lastTransactionId);
    if (code !== PTP_RESPONSE_OK) {
      SonyUsbPtp.log(`get-device-info rejected code=0x${SonyUsbPtp.hex16(code)}`);
      return null;
    }
    let payload: Uint8Array | null = null;
    for (const container of containers) {
      if (container.type === PTP_CONTAINER_DATA && container.code === PTP_OP_GET_DEVICE_INFO) {
        payload = container.payload;
        break;
      }
    }
    if (payload === null) return null;
    return SonyUsbPtp.parseDeviceInfo(payload);
  }

  /**
   * 解析 DeviceInfo（PIMA 15740 数据集）。
   *
   * 布局：u16 StandardVersion / u32 VendorExtensionID / u16 VendorExtensionVersion
   * / PTPString VendorExtensionDesc / u16 FunctionalMode / 五个
   * AUINT16 数组（Operations、Events、DeviceProperties、CaptureFormats、
   * ImageFormats）/ 四个 PTPString（Manufacturer、Model、DeviceVersion、
   * SerialNumber）。数组 = u32 计数 + count×u16。
   */
  private static parseDeviceInfo(payload: Uint8Array): SonyUsbDeviceInfo | null {
    if (payload.length < 8) return null;
    const info: SonyUsbDeviceInfo = {
      manufacturer: '', model: '', deviceVersion: '', serialNumber: '',
      standardVersion: SonyUsbPtp.readLe16(payload, 0),
      vendorExtensionId: SonyUsbPtp.readLe32(payload, 2),
      vendorExtensionVersion: SonyUsbPtp.readLe16(payload, 6),
      functionalMode: 0,
      operations: [], events: [], properties: [], captureFormats: [], imageFormats: [],
    };
    let offset = 8;
    const extension = SonyUsbPtp.readPtpString(payload, offset);
    offset = extension.nextOffset;
    if (offset + 2 > payload.length) return info;
    info.functionalMode = SonyUsbPtp.readLe16(payload, offset);
    offset += 2;
    const operations = SonyUsbPtp.readArray16(payload, offset);
    offset = operations.nextOffset;
    info.operations = operations.values;
    const events = SonyUsbPtp.readArray16(payload, offset);
    offset = events.nextOffset;
    info.events = events.values;
    const properties = SonyUsbPtp.readArray16(payload, offset);
    offset = properties.nextOffset;
    info.properties = properties.values;
    const capture = SonyUsbPtp.readArray16(payload, offset);
    offset = capture.nextOffset;
    info.captureFormats = capture.values;
    const image = SonyUsbPtp.readArray16(payload, offset);
    offset = image.nextOffset;
    info.imageFormats = image.values;
    const manufacturer = SonyUsbPtp.readPtpString(payload, offset);
    offset = manufacturer.nextOffset;
    info.manufacturer = manufacturer.value;
    const model = SonyUsbPtp.readPtpString(payload, offset);
    offset = model.nextOffset;
    info.model = model.value;
    const version = SonyUsbPtp.readPtpString(payload, offset);
    offset = version.nextOffset;
    info.deviceVersion = version.value;
    const serial = SonyUsbPtp.readPtpString(payload, offset);
    info.serialNumber = serial.value;
    return info;
  }

  /**
   * 发送一个 PTP 操作并收集响应。
   *
   * 与松下路径同样的容器规则：命令容器一次 bulk 写出；响应可能跨多个 bulk 包，
   * 因此保留不完整尾部、只解析完整容器，直到拿到本事务的 RESPONSE。USB 上没有
   * PTP/IP 那 12 字节初始化握手，OpenSession 就是第一个事务。
   */
  static async transaction(operation: number, params: number[],
    dataPayload: Uint8Array | null = null): Promise<SonyUsbContainer[]> {
    const pipe = SonyUsbPtp.pipe;
    const bulkOut = SonyUsbPtp.bulkOut;
    const bulkIn = SonyUsbPtp.bulkIn;
    if (pipe === null || bulkOut === null || bulkIn === null) {
      throw new Error('Sony USB is not connected');
    }
    SonyUsbPtp.transactionId += 1;
    const transactionId = SonyUsbPtp.transactionId;
    SonyUsbPtp.lastTransactionId = transactionId;
    const command = SonyUsbPtp.commandContainer(operation, transactionId, params);
    const sent = await usbManager.bulkTransfer(pipe, bulkOut, command, BULK_TIMEOUT_MS);
    if (sent < command.length) throw new Error('PTP command transfer incomplete');
    if (dataPayload !== null) {
      // 数据输出阶段：一个 DATA 容器，其 code 字段就是操作码本身
      // （官方 TransactionExecutor.java:188 如此，不是 0）。
      const data = SonyUsbPtp.dataContainer(operation, transactionId, dataPayload);
      const dataSent = await usbManager.bulkTransfer(pipe, bulkOut, data, BULK_TIMEOUT_MS);
      if (dataSent < data.length) throw new Error('PTP data transfer incomplete');
    }

    const containers: SonyUsbContainer[] = [];
    let pending = new Uint8Array(0);
    for (let attempt = 0; attempt < 512; attempt++) {
      const buffer = new Uint8Array(BULK_IN_BUFFER_BYTES);
      const received = await usbManager.bulkTransfer(pipe, bulkIn, buffer, BULK_TIMEOUT_MS);
      if (received <= 0) throw new Error('PTP response transfer failed');
      const merged = new Uint8Array(pending.length + received);
      merged.set(pending, 0);
      merged.set(buffer.subarray(0, received), pending.length);
      const parsed = SonyUsbPtp.parseContainers(merged);
      for (const container of parsed.containers) containers.push(container);
      pending = merged.slice(parsed.consumed);
      if (SonyUsbPtp.responseCode(containers, transactionId) >= 0) return containers;
    }
    throw new Error('PTP response timeout');
  }

  private static commandContainer(operation: number, transactionId: number, params: number[]): Uint8Array {
    const packet = new Uint8Array(PTP_CONTAINER_HEADER_SIZE + params.length * 4);
    SonyUsbPtp.writeLe32(packet, 0, packet.length);
    SonyUsbPtp.writeLe16(packet, 4, PTP_CONTAINER_COMMAND);
    SonyUsbPtp.writeLe16(packet, 6, operation);
    SonyUsbPtp.writeLe32(packet, 8, transactionId);
    for (let index = 0; index < params.length; index++) {
      SonyUsbPtp.writeLe32(packet, PTP_CONTAINER_HEADER_SIZE + index * 4, params[index]);
    }
    return packet;
  }

  /** 数据输出容器：code 字段放操作码本身（官方就是这么写的）。 */
  private static dataContainer(operation: number, transactionId: number,
    payload: Uint8Array): Uint8Array {
    const packet = new Uint8Array(PTP_CONTAINER_HEADER_SIZE + payload.length);
    SonyUsbPtp.writeLe32(packet, 0, packet.length);
    SonyUsbPtp.writeLe16(packet, 4, PTP_CONTAINER_DATA);
    SonyUsbPtp.writeLe16(packet, 6, operation);
    SonyUsbPtp.writeLe32(packet, 8, transactionId);
    packet.set(payload, PTP_CONTAINER_HEADER_SIZE);
    return packet;
  }

  private static parseContainers(buffer: Uint8Array): SonyUsbContainerParse {
    const containers: SonyUsbContainer[] = [];
    let offset = 0;
    while (offset + PTP_CONTAINER_HEADER_SIZE <= buffer.length) {
      const length = SonyUsbPtp.readLe32(buffer, offset);
      if (length < PTP_CONTAINER_HEADER_SIZE || length > buffer.length - offset) break;
      containers.push({
        type: SonyUsbPtp.readLe16(buffer, offset + 4),
        code: SonyUsbPtp.readLe16(buffer, offset + 6),
        transactionId: SonyUsbPtp.readLe32(buffer, offset + 8),
        payload: buffer.slice(offset + PTP_CONTAINER_HEADER_SIZE, offset + length),
      });
      offset += length;
    }
    return { containers: containers, consumed: offset };
  }

  private static responseCode(containers: SonyUsbContainer[], transactionId: number): number {
    for (const container of containers) {
      if (container.type === PTP_CONTAINER_RESPONSE && container.transactionId === transactionId) {
        return container.code;
      }
    }
    return -1;
  }

  /** 关闭会话并释放接口；任何一步失败都不影响其余步骤。 */
  static async close(): Promise<void> {
    const pipe = SonyUsbPtp.pipe;
    // 先摘掉控制传输：取帧泵下一个循环就会看到「没有通道」而自停，不会在
    // CloseSession 之后继续往队列里塞 GetObject。
    NikonPtpIpService.attachTransport(null);
    // 复位毒化标记：否则一次超时之后这根管道就永久不可用（见 consecutiveFailures）。
    SonyUsbPtp.resetFailures();
    if (pipe !== null && SonyUsbPtp.sessionOpen) {
      // 控制权（0xD25A）由 `SonyLiveView.stop()` 在关闭取景时归还 —— 它才知道
      // 该带什么 flag，这里不重复发。
      try {
        // 走队列而不是裸 transaction：可能还有一帧在途，串行化才不会打断它。
        await SonyUsbPtp.enqueue(PTP_OP_CLOSE_SESSION, [], false);
      } catch (_error) { }
    }
    SonyUsbPtp.sessionOpen = false;
    if (pipe !== null) {
      try { if (SonyUsbPtp.iface !== null) usbManager.releaseInterface(pipe, SonyUsbPtp.iface); } catch (_error) { }
      try { usbManager.closePipe(pipe); } catch (_error) { }
    }
    SonyUsbPtp.pipe = null;
    SonyUsbPtp.iface = null;
    SonyUsbPtp.bulkIn = null;
    SonyUsbPtp.bulkOut = null;
    SonyUsbPtp.transactionId = 0;
  }

  private static async ensureRight(deviceName: string): Promise<boolean> {
    try {
      if (usbManager.hasRight(deviceName)) return true;
    } catch (_error) { }
    return await usbManager.requestRight(deviceName);
  }

  private static errorCode(error: Object): string {
    const typed = error as Error;
    return typed.message === undefined ? String(error) : typed.message;
  }

  private static readLe16(buffer: Uint8Array, offset: number): number {
    if (offset + 2 > buffer.length) return 0;
    return buffer[offset] | (buffer[offset + 1] << 8);
  }

  private static readLe32(buffer: Uint8Array, offset: number): number {
    if (offset + 4 > buffer.length) return 0;
    return (buffer[offset] | (buffer[offset + 1] << 8) |
      (buffer[offset + 2] << 16) | (buffer[offset + 3] << 24)) >>> 0;
  }

  private static writeLe16(buffer: Uint8Array, offset: number, value: number): void {
    buffer[offset] = value & 0xFF;
    buffer[offset + 1] = (value >> 8) & 0xFF;
  }

  private static writeLe32(buffer: Uint8Array, offset: number, value: number): void {
    buffer[offset] = value & 0xFF;
    buffer[offset + 1] = (value >> 8) & 0xFF;
    buffer[offset + 2] = (value >> 16) & 0xFF;
    buffer[offset + 3] = (value >> 24) & 0xFF;
  }

  private static readPtpString(buffer: Uint8Array, offset: number): SonyPtpStringRead {
    if (offset >= buffer.length) return { value: '', nextOffset: buffer.length };
    const count = buffer[offset];
    if (count === 0) return { value: '', nextOffset: offset + 1 };
    const bytes = count * 2;
    if (bytes > buffer.length - offset - 1) return { value: '', nextOffset: buffer.length };
    let value = '';
    // 第 count 个字符是结束符 NUL，不并入结果。
    for (let index = 0; index < count - 1; index++) {
      const unit = buffer[offset + 1 + index * 2] | (buffer[offset + 2 + index * 2] << 8);
      if (unit === 0) break;
      value += String.fromCharCode(unit);
    }
    return { value: value, nextOffset: offset + 1 + bytes };
  }

  private static readArray16(buffer: Uint8Array, offset: number): SonyPtpArrayRead {
    if (offset + 4 > buffer.length) return { values: [], nextOffset: buffer.length };
    const count = SonyUsbPtp.readLe32(buffer, offset);
    let cursor = offset + 4;
    const values: number[] = [];
    if (count > 0x10000) return { values: values, nextOffset: buffer.length };
    for (let index = 0; index < count; index++) {
      if (cursor + 2 > buffer.length) break;
      values.push(SonyUsbPtp.readLe16(buffer, cursor));
      cursor += 2;
    }
    return { values: values, nextOffset: cursor };
  }

  private static hex16(value: number): string {
    return (value < 0 ? '0000' : ('0000' + value.toString(16)).slice(-4));
  }

  private static hexList(values: number[]): string {
    const parts: string[] = [];
    for (const value of values) parts.push(SonyUsbPtp.hex16(value));
    return parts.join(',');
  }

  private static hex8(value: number): string {
    return ('00000000' + (value >>> 0).toString(16)).slice(-8);
  }

  private static safeText(value: string): string {
    return value.length > 0 ? value : '-';
  }

  /**
   * 读 DID（`SDIO_GetDeviceDescriptionFile` args {2}）里的 ServerVersion。
   *
   * 官方 `Initializer` 在开会话**之前**就发 0x923A 读 DD/DID，再据
   * `X_ServerVersion` 决定 functionMode，所以这个顺序必须照抄：先读 DID，
   * 再 `SDIO_OpenSession`。相机没声明 0x923A、或拒绝/超时，一律返回 -1，
   * 由调用方退回 CONTENTS_TRANSFER（官方插入时也是这个默认值）。
   */
  private static async readServerVersion(info: SonyUsbDeviceInfo): Promise<number> {
    if (info.operations.indexOf(SONY_OP_GET_DEVICE_DESCRIPTION_FILE) < 0) {
      SonyUsbPtp.log('did skipped reason=opcode-not-advertised');
      return -1;
    }
    try {
      // DD 只是走一遍官方顺序，内容不需要；失败也不影响后面。
      const dd = await SonyUsbPtp.transaction(SONY_OP_GET_DEVICE_DESCRIPTION_FILE, [1]);
      SonyUsbPtp.log(`did dd code=0x${SonyUsbPtp.hex16(
        SonyUsbPtp.responseCode(dd, SonyUsbPtp.lastTransactionId))}`);
      const did = await SonyUsbPtp.transaction(SONY_OP_GET_DEVICE_DESCRIPTION_FILE, [2]);
      const code = SonyUsbPtp.responseCode(did, SonyUsbPtp.lastTransactionId);
      let payload: Uint8Array | null = null;
      for (const container of did) {
        if (container.type === PTP_CONTAINER_DATA &&
          container.code === SONY_OP_GET_DEVICE_DESCRIPTION_FILE) {
          payload = container.payload;
          break;
        }
      }
      if (code !== PTP_RESPONSE_OK || payload === null) {
        SonyUsbPtp.log(`did did-xml failed code=0x${SonyUsbPtp.hex16(code)}`);
        return -1;
      }
      const text = SonyUsbPtp.decodeUtf8(payload);
      const version = SonyUsbPtp.parseServerVersion(text);
      SonyUsbPtp.log(`did did-xml bytes=${payload.length} serverVersion=${version.toFixed(2)}`);
      return version;
    } catch (error) {
      SonyUsbPtp.log('did error code=' + SonyUsbPtp.errorCode(error));
      return -1;
    }
  }

  /**
   * 从 DID XML 里取 ServerVersion 数值。
   *
   * 不假设标签形式（可能是 `<X_ServerVersion>4.00</X_ServerVersion>`，也可能带
   * 属性），所以只做「找到关键字 → 向后扫第一个数字」这一件事，够用且不会被
   * 命名空间/属性顺序影响。取不到返回 -1（语义上等于「比 4.0 老」）。
   */
  private static parseServerVersion(text: string): number {
    const index = text.indexOf(DID_SERVER_VERSION_KEY);
    if (index < 0) return -1;
    const from = index + DID_SERVER_VERSION_KEY.length;
    const to = Math.min(text.length, from + 64);
    let start = -1;
    for (let cursor = from; cursor < to; cursor++) {
      const code = text.charCodeAt(cursor);
      if (code >= 48 && code <= 57) {
        start = cursor;
        break;
      }
    }
    if (start < 0) return -1;
    let raw = '';
    let seenDot = false;
    for (let cursor = start; cursor < to; cursor++) {
      const code = text.charCodeAt(cursor);
      if (code >= 48 && code <= 57) {
        raw += text.charAt(cursor);
      } else if (code === 46 && !seenDot) {
        seenDot = true;
        raw += '.';
      } else {
        break;
      }
    }
    const value = Number.parseFloat(raw);
    return Number.isNaN(value) ? -1 : value;
  }

  private static decodeUtf8(payload: Uint8Array): string {
    try {
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(payload);
    } catch (_error) {
      let text = '';
      for (let index = 0; index < payload.length; index++) {
        text += String.fromCharCode(payload[index]);
      }
      return text;
    }
  }

  private static payloadWords(payload: Uint8Array): number[] {
    const words: number[] = [];
    for (let offset = 0; offset + 4 <= payload.length; offset += 4) {
      words.push(SonyUsbPtp.readLe32(payload, offset));
    }
    return words;
  }

  /** 供 `SonyUsbTransport` 读取会话开启信息（同类私有成员，跨类不可见）。 */
  static openedOpcode(): number {
    return SonyUsbPtp.openedWithOpcode;
  }

  static openedCode(): number {
    return SonyUsbPtp.openedWithCode;
  }

  static hasFailed(): boolean {
    return SonyUsbPtp.transportFailed;
  }

  /**
   * 取一帧实时取景（JPEG），没有新帧或相机拒绝时返回 null。
   *
   * 索尼在 USB 上没有独立的取景操作：`GetObject(0x1009)` 传魔数句柄
   * `0xFFFFC002`，并在 data-out 阶段带 2 字节图像类型 `0xC002`，相机就回一帧
   * JPEG。先按官方/公开实现的形状（带 data-out）发；若机身拒绝 0x2005/0x2006，
   * 再退回不带 data-out 的形式 —— 两种都在日志里留痕，便于按机型收敛。
   */
  static async fetchLiveViewFrame(): Promise<Uint8Array | null> {
    return await SonyUsbPtp.fetchObject(SONY_LIVEVIEW_OBJECT_HANDLE, SONY_IMAGE_TYPE_LIVEVIEW);
  }

  /** 取一张刚拍的照片（`0xFFFFC001`）。 */
  static async fetchPhoto(): Promise<Uint8Array | null> {
    return await SonyUsbPtp.fetchObject(SONY_PHOTO_OBJECT_HANDLE, SONY_IMAGE_TYPE_PHOTO);
  }

  private static async fetchObject(handle: number,
    imageType: number): Promise<Uint8Array | null> {
    if (!SonyUsbPtp.sessionOpen || SonyUsbPtp.transportFailed) return null;
    const payload = SonyUsbPtp.u16le(imageType);
    try {
      // 必须走队列：取帧与快门共用一条 bulk 管道，直接 `execute` 会串帧。
      const withData = await SonyUsbPtp.enqueueDataOut(PTP_OP_GET_OBJECT, [handle], payload, true);
      if (withData.code === PTP_RESPONSE_OK && withData.data.length > 0) {
        return withData.data;
      }
      if (!SonyUsbPtp.objectDataOutRefused) {
        SonyUsbPtp.objectDataOutRefused = true;
        SonyUsbPtp.log(`get-object data-out refused code=0x${SonyUsbPtp.hex16(withData.code)}` +
          ` fallback=no-data-out`);
      }
      const plain = await SonyUsbPtp.enqueue(PTP_OP_GET_OBJECT, [handle], true);
      if (plain.code === PTP_RESPONSE_OK && plain.data.length > 0) {
        return plain.data;
      }
      return null;
    } catch (error) {
      // 取流失败不毒化整条传输：实时取景是「下一帧再试」的语义。
      SonyUsbPtp.log('get-object failed code=' + SonyUsbPtp.errorCode(error));
      return null;
    }
  }

  /** data-out 形式的 GetObject 是否已被机身拒绝过（避免每帧都试两遍）。 */
  private static objectDataOutRefused: boolean = false;

  /**
   * 夺取 / 归还 USB 主机控制权（`0xD25A`，走 `SDIO_SetControlDeviceA` 0x9205）。
   *
   * **参数形状必须与自家属性写入一致**：`SonyPtpIpControl.applySetting` 对同一条
   * 0x9205 发的是 `[code, flag]`（`propertyFlag` 为 0 时才省掉 flag）。只发
   * `[0xD25A]` 会少一个参数，机身多半回 `0x2005/0x2006`；而这里「失败不致命」，
   * 真机只会表现成「偶尔快门没反应」，极难查。所以 flag 由调用方（`SonyLiveView`，
   * 它已经持有 `propertyFlag`）算好传进来，避免本文件反向依赖 `SonyLiveView`。
   *
   * 非致命：写入被拒只记录，控制页继续尝试。
   */
  static async setPriorityMode(value: number, flag: number): Promise<number> {
    if (!SonyUsbPtp.sessionOpen) return -1;
    const params: number[] = flag > 0
      ? [SONY_PROP_PRIORITY_MODE, flag]
      : [SONY_PROP_PRIORITY_MODE];
    try {
      const response = await SonyUsbPtp.enqueueDataOut(SONY_OP_SET_CONTROL_DEVICE_A,
        params, SonyUsbPtp.u16le(value));
      SonyUsbPtp.log(`priority-mode value=${value} params=[${params.join(',')}]` +
        ` code=0x${SonyUsbPtp.hex16(response.code)}`);
      return response.code;
    } catch (error) {
      SonyUsbPtp.log('priority-mode failed code=' + SonyUsbPtp.errorCode(error));
      return -1;
    }
  }

  /** 清掉毒化与连续失败计数（重连、关会话、probe 都调它）。 */
  static resetFailures(): void {
    SonyUsbPtp.transportFailed = false;
    SonyUsbPtp.consecutiveFailures = 0;
  }

  /** 当前会话的 functionMode：0 控制 / 1 传输 / 2 两者，-1 未知。 */
  static currentFunctionMode(): number {
    return SonyUsbPtp.functionMode;
  }

  /**
   * 当前会话是否受理控制类操作（`0x9207`）。
   *
   * `SDIO_ControlDevice` 只被 REMOTE_CONTROL / REMOTE_CONTROL_WITH_TRANSFER 会话
   * 受理，纯 CONTENTS_TRANSFER（mode 1）会拒绝。未知（-1）时按可用处理，交给
   * 相机自己回码，而不是由我们提前拦下。
   */
  static controlCapable(): boolean {
    const mode = SonyUsbPtp.functionMode;
    if (mode < 0) return true;
    return mode === SONY_FUNCTION_MODE_REMOTE_CONTROL ||
      mode === SONY_FUNCTION_MODE_REMOTE_CONTROL_WITH_TRANSFER;
  }

  private static u16le(value: number): Uint8Array {
    const bytes = new Uint8Array(2);
    SonyUsbPtp.writeLe16(bytes, 0, value);
    return bytes;
  }

  /** 供 `SonyPtpIpContent.openViaTransport()` 使用的传输层实例。 */
  static transport(): SonyUsbTransport {
    if (SonyUsbPtp.transportInstance === null) {
      SonyUsbPtp.transportInstance = new SonyUsbTransport();
    }
    return SonyUsbPtp.transportInstance;
  }

  /**
   * `PtpTransport.enqueue`：串行化后执行一个事务并归一化成 `NikonPtpResponse`。
   *
   * USB 的一条 bulk 管道同时承载命令与响应，并发调用必然串帧，所以这里和
   * `NikonPtpSession` 一样用一条 promise 尾链把事务排成队列。
   */
  static enqueue(op: number, params: number[], expectsData: boolean,
    _tolerateTimeout: boolean = false): Promise<NikonPtpResponse> {
    const task: Promise<NikonPtpResponse> = SonyUsbPtp.queueTail.then(
      async (): Promise<NikonPtpResponse> => {
        if (SonyUsbPtp.transportFailed) throw new Error('Sony USB transport is unavailable');
        return await SonyUsbPtp.execute(op, params, null, expectsData);
      });
    SonyUsbPtp.queueTail = task.then((): void => {}, (): void => {});
    return task;
  }

  /**
   * `PtpTransport.enqueueDataOut`：数据阶段由手机发往相机（0x9207 控制设备）。
   *
   * 第四个参数是给 `GetObject` 用的：USB 上取实时取景帧既要发 2 字节图像类型
   * （data-out），又要把相机回的对象数据读回来（data-in），`PtpTransport` 的两条
   * 原语各自只覆盖一半。默认 `false`，所以控制类操作的行为一字未变。
   */
  static enqueueDataOut(op: number, params: number[], payload: Uint8Array,
    expectsData: boolean = false): Promise<NikonPtpResponse> {
    const task: Promise<NikonPtpResponse> = SonyUsbPtp.queueTail.then(
      async (): Promise<NikonPtpResponse> => {
        if (SonyUsbPtp.transportFailed) throw new Error('Sony USB transport is unavailable');
        return await SonyUsbPtp.execute(op, params, payload, expectsData);
      });
    SonyUsbPtp.queueTail = task.then((): void => {}, (): void => {});
    return task;
  }

  private static async execute(op: number, params: number[], dataOut: Uint8Array | null,
    expectsData: boolean): Promise<NikonPtpResponse> {
    try {
      const containers = await SonyUsbPtp.transaction(op, params, dataOut);
      const id = SonyUsbPtp.lastTransactionId;
      let code = -1;
      let codeParams: number[] = [];
      let data = new Uint8Array(0);
      for (const container of containers) {
        if (container.type === PTP_CONTAINER_RESPONSE && container.transactionId === id) {
          code = container.code;
          codeParams = SonyUsbPtp.payloadWords(container.payload);
        } else if (container.type === PTP_CONTAINER_DATA && container.transactionId === id &&
          expectsData) {
          data = container.payload;
        }
      }
      SonyUsbPtp.consecutiveFailures = 0;
      return { code: code, transaction: id, params: codeParams, data: data };
    } catch (error) {
      SonyUsbPtp.consecutiveFailures += 1;
      SonyUsbPtp.log(`transaction 0x${SonyUsbPtp.hex16(op)} failed code=` +
        SonyUsbPtp.errorCode(error) + ` fails=${SonyUsbPtp.consecutiveFailures}`);
      if (SonyUsbPtp.consecutiveFailures >= SonyUsbPtp.MAX_CONSECUTIVE_FAILURES) {
        SonyUsbPtp.transportFailed = true;
      }
      throw error as Error;
    }
  }
}

/**
 * `PtpTransport` 的 USB 实现。
 *
 * 协议层（`SonyPtpIpContent`）只认这个接口，因此 USB 与 PTP/IP 共用同一套索尼
 * 操作码与流程 —— 与官方 `Initializer` 只依赖 `ITransactionExecutor` 同构。
 * 传输专属的东西（USB 无初始化握手、无探活、事件走中断端点）都不在这里暴露。
 */
export class SonyUsbTransport implements PtpTransport {
  get openOpcode(): number {
    return SonyUsbPtp.openedOpcode();
  }

  get openCode(): number {
    return SonyUsbPtp.openedCode();
  }

  get failed(): boolean {
    return SonyUsbPtp.hasFailed();
  }

  enqueue(op: number, params: number[], expectsData: boolean,
    tolerateTimeout: boolean = false): Promise<NikonPtpResponse> {
    return SonyUsbPtp.enqueue(op, params, expectsData, tolerateTimeout);
  }

  enqueueDataOut(op: number, params: number[], payload: Uint8Array): Promise<NikonPtpResponse> {
    return SonyUsbPtp.enqueueDataOut(op, params, payload);
  }
}

interface SonyUsbContainerParse {
  containers: SonyUsbContainer[];
  consumed: number;
}
