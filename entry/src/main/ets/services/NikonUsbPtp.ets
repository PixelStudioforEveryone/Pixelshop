/**
 * NikonUsbPtp —— 尼康相机的 **USB(PTP) 传输层**。
 *
 * 为什么要有这一层
 * ----------------
 * 尼康线原来只有一条路：蓝牙配对 → LSS 拿 Wi‑Fi 凭据 → 拉起相机热点 → 连上去 →
 * PTP/IP。这条链路慢（要等相机开热点），而且手机没有 Wi‑Fi 时完全走不通。
 * USB 线一插就能用，带宽也比 2.4GHz 热点稳。
 *
 * 关键点：**USB 和 PTP/IP 只是两种“管道”，上面跑的操作码、数据封装、属性编码
 * 完全一样。** 这一点已经在索尼线上验证过——`SonyUsbPtp` 把
 * `enqueue` / `enqueueDataOut` 抽象成 `PtpTransport`，`NikonPtpIpService`
 * 里那套控制逻辑（档位 / EV / 光圈 / 快门 / 录像 / 取景）就能原样跑在 USB 上。
 * 所以本文件只做三件事：
 *
 *   1. 找到尼康相机（VID `0x04B0`）并申请权限、占住 PTP 接口；
 *   2. 收发 **PTP/USB 容器**（12 字节头 + 命令/数据/响应三种容器）；
 *   3. 通过 `transport()` 把这条管道交给 `NikonPtpIpService.attachTransport()`。
 *
 * 与 PTP/IP 的差异只在“外层封装”，不在“里面装什么”：
 *
 *   PTP/IP： `[len u32][type u32][payload]`，要先做 InitCommand/InitAck 握手，
 *            命令和数据是**分开的包**（OpReq / StartData / Data / EndData）。
 *   PTP/USB：`[len u32][type u16][code u16][txid u32][payload]`，没有握手，
 *            直接 OpenSession；数据阶段是独立的一个 Data 容器，跟在命令容器后面。
 *
 * 参考实现（公开代码，用于交叉核对操作码与容器封装）
 * --------------------------------------------------
 *   - michaelzoech/remoteyourcam-usb（Android + Nikon PTP over USB，最接近本文件）
 *   - gphoto/libgphoto2（`camlibs/ptp2/ptp.h`，尼康厂商操作码/属性的权威表）
 *   - dognotdog/ptpwebcam（尼康 Z 系列取景取帧）
 * 本文件里的尼康操作码则**优先采用我们自己抓包验证过的值**（见下方常量注释），
 * 公开项目只用来确认封装与流程。
 *
 * @since 2026-10
 */

import usbManager from '@ohos.usbManager';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  NikonPtpCatalogResult,
  NikonPtpGalleryItem,
  NikonPtpGalleryPage,
  NikonPtpIpService,
  NikonPtpResponse,
  PtpTransport,
} from './NikonPtpIpService';

const DOMAIN: number = 0x0001;
const TAG: string = 'VIVID_NIKON_USB';

/** PTP 容器头：u32 length + u16 type + u16 code + u32 transactionId。 */
const PTP_CONTAINER_HEADER_SIZE: number = 12;
const PTP_CONTAINER_COMMAND: number = 1;
const PTP_CONTAINER_DATA: number = 2;
const PTP_CONTAINER_RESPONSE: number = 3;
/** 单次 bulk 读的上限；一帧取景 JPEG 约 70 KB，留足余量。 */
const BULK_BUFFER_SIZE: number = 1024 * 1024;
const BULK_TIMEOUT_MS: number = 3000;
/** 收齐“响应容器”最多读几轮，防止相机不回应时死等。 */
const MAX_RECEIVE_ROUNDS: number = 8;
/** PTP 会话号，与 PTP/IP 侧一致。 */
const NIKON_SESSION_ID: number = 1;
/** 尼康的 USB 厂商 ID。 */
const NIKON_VENDOR_ID: number = 0x04B0;

/** 标准 PTP 操作。 */
const PTP_OP_GET_DEVICE_INFO: number = 0x1001;
const PTP_OP_OPEN_SESSION: number = 0x1002;
const PTP_OP_CLOSE_SESSION: number = 0x1003;
const PTP_OP_GET_STORAGE_IDS: number = 0x1004;
const PTP_OP_GET_NUM_OBJECTS: number = 0x1006;
const PTP_OP_GET_OBJECT_HANDLES: number = 0x1007;
const PTP_OP_GET_OBJECT_INFO: number = 0x1008;
const PTP_OP_GET_THUMB: number = 0x100A;
const PTP_OP_GET_PARTIAL_OBJECT: number = 0x101B;
/** 一次 `GetPartialObject` 取多少字节。USB 单次 bulk 别开太大，512 KB 折中。 */
const PARTIAL_CHUNK_BYTES: number = 512 * 1024;

/**
 * 尼康厂商操作码。**全部来自我们对官方 SnapBridge + 真机的抓包/实测**，
 * 不是从公开项目抄的（公开项目只用来确认“USB 上也用同一套码”）。
 */
const NIKON_OP_START_LIVE_VIEW: number = 0x9201;
const NIKON_OP_END_LIVE_VIEW: number = 0x9202;
const NIKON_OP_GET_LIVE_VIEW_IMAGE: number = 0x9203;
const NIKON_OP_AF_DRIVE: number = 0x9205;
const NIKON_OP_DEVICE_READY: number = 0x90C8;
/** `ChangeCameraMode`：0 = CAMERA（机身），1 = HOST（遥控端）。 */
const NIKON_OP_CHANGE_CAMERA_MODE: number = 0x90C2;
/** 录像开始/结束（无参数）。 */
const NIKON_OP_START_MOVIE_REC: number = 0x920A;
const NIKON_OP_END_MOVIE_REC: number = 0x920B;
/** `GetLiveViewImageEx`：官方全程用它取帧（载荷头布局与 0x9203 不同）。 */
const NIKON_OP_GET_LIVE_VIEW_IMAGE_EX: number = 0x9428;

/** 一个 PTP 容器。 */
export interface NikonUsbContainer {
  type: number;
  code: number;
  transactionId: number;
  payload: Uint8Array;
}

/** USB 上找到的尼康相机。 */
export interface NikonUsbDeviceInfo {
  name: string;
  vendorId: number;
  productId: number;
}

/** 探测结果：够不够走控制/传输，全看 DeviceInfo 自报的操作表。 */
export interface NikonUsbProbe {
  ok: boolean;
  message: string;
  info: NikonUsbDeviceInfo | null;
  openOpcode: number;
  openCode: number;
  model: string;
  /** `OperationsSupported` 的十六进制列表，判定错了可以离线复核。 */
  operationsHex: string[];
}

interface NikonUsbSelection {
  config: usbManager.USBConfiguration;
  iface: usbManager.USBInterface;
  bulkIn: usbManager.USBEndpoint;
  bulkOut: usbManager.USBEndpoint;
}

/**
 * `PtpTransport` 的 USB 实现。`NikonPtpIpService.attachTransport()` 收的就是它，
 * 于是档位、EV、光圈、快门、录像、取景这些逻辑一行都不用改。
 */
export class NikonUsbTransport implements PtpTransport {
  /** 建立会话时实际生效的开启操作码（USB 上是标准 0x1002）。 */
  openOpcode: number = 0;
  /** 该开启操作的响应码，-1 表示从未执行。 */
  openCode: number = -1;
  /** 事务层是否已失效。 */
  failed: boolean = false;

  enqueue(op: number, params: number[], expectsData: boolean,
    _tolerateTimeout: boolean = false): Promise<NikonPtpResponse> {
    return NikonUsbPtp.enqueue(op, params, expectsData);
  }

  enqueueDataOut(op: number, params: number[], payload: Uint8Array): Promise<NikonPtpResponse> {
    return NikonUsbPtp.enqueueDataOut(op, params, payload);
  }
}

export class NikonUsbPtp {
  private static pipe: usbManager.USBDevicePipe | null = null;
  private static iface: usbManager.USBInterface | null = null;
  private static bulkIn: usbManager.USBEndpoint | null = null;
  private static bulkOut: usbManager.USBEndpoint | null = null;
  private static transactionId: number = 0;
  private static lastTransactionId: number = 0;
  private static sessionOpen: boolean = false;
  private static transportFailed: boolean = false;
  private static transportInstance: NikonUsbTransport | null = null;
  private static queueTail: Promise<void> = Promise.resolve();
  private static openOpcode: number = 0;
  private static openCode: number = -1;
  /** 最近一次枚举出来的完整列表顺序（按卡分组、组内最新在前），供翻页取用。 */
  private static galleryRefs: NikonUsbObjectRef[] = [];

  static log(message: string): void {
    hilog.info(DOMAIN, TAG, message);
    NikonPtpIpService.log(`nikon-usb ${message}`);
  }

  static errorCode(error: Object): string {
    return String(error);
  }

  static hex16(value: number): string {
    return '0x' + (value & 0xFFFF).toString(16).toUpperCase().padStart(4, '0');
  }

  static hex32(value: number): string {
    return '0x' + (value >>> 0).toString(16).toUpperCase().padStart(8, '0');
  }

  /** 会话是否可用。 */
  static isOpen(): boolean {
    return NikonUsbPtp.pipe !== null && NikonUsbPtp.sessionOpen && !NikonUsbPtp.transportFailed;
  }

  /**
   * 枚举挂着 PTP 接口的尼康相机。
   *
   * 只按厂商 ID 过滤不够：尼康的 MTP 模式也会出现同一个 VID，但那种模式下没有
   * 批量端点组合、也没有 PTP 接口，所以仍要 `findSelection()` 验一遍。
   */
  static listDevices(): Array<Readonly<usbManager.USBDevice>> {
    const found: Array<Readonly<usbManager.USBDevice>> = [];
    try {
      const devices = usbManager.getDevices();
      for (const device of devices) {
        if (device.vendorId !== NIKON_VENDOR_ID) continue;
        if (NikonUsbPtp.findSelection(device) === null) continue;
        found.push(device);
      }
    } catch (error) {
      NikonUsbPtp.log('list-devices failed code=' + NikonUsbPtp.errorCode(error as Object));
    }
    return found;
  }

  static hasDevice(): boolean {
    return NikonUsbPtp.listDevices().length > 0;
  }

  /** 找到第一个带批量进出端点的接口（PTP 接口通常是 class 6 或厂商自定义）。 */
  private static findSelection(device: Readonly<usbManager.USBDevice>): NikonUsbSelection | null {
    for (const config of device.configs) {
      for (const candidate of config.interfaces) {
        const bulkIn = candidate.endpoints.find((endpoint: usbManager.USBEndpoint) =>
          endpoint.type === 2 &&
            endpoint.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_FROM_DEVICE);
        const bulkOut = candidate.endpoints.find((endpoint: usbManager.USBEndpoint) =>
          endpoint.type === 2 &&
            endpoint.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_TO_DEVICE);
        if (bulkIn && bulkOut) {
          return { config: config, iface: candidate, bulkIn: bulkIn, bulkOut: bulkOut };
        }
      }
    }
    return null;
  }

  private static async ensureRight(deviceName: string): Promise<boolean> {
    if (usbManager.hasRight(deviceName)) return true;
    return await usbManager.requestRight(deviceName);
  }

  /**
   * 打开 USB 会话并读一次 DeviceInfo。
   *
   * 之后不会再重复 `OpenSession`：PTP 规定同一个会话里重复开会话会被相机回
   * `SessionAlreadyOpen`，反而把已经能用的通道弄坏。
   */
  static async probe(device: Readonly<usbManager.USBDevice>): Promise<NikonUsbProbe> {
    const result: NikonUsbProbe = {
      ok: false,
      message: '',
      info: null,
      openOpcode: 0,
      openCode: -1,
      model: '',
      operationsHex: [],
    };
    NikonUsbPtp.transportFailed = false;
    const selection = NikonUsbPtp.findSelection(device);
    if (selection === null) {
      result.message = '没有可用的 PTP 批量端点';
      return result;
    }
    try {
      const granted = await NikonUsbPtp.ensureRight(device.name);
      if (!granted) {
        result.message = 'USB 权限被拒绝';
        NikonUsbPtp.log('probe permission-denied');
        return result;
      }
      NikonUsbPtp.pipe = usbManager.connectDevice(device as usbManager.USBDevice);
      if (!NikonUsbPtp.pipe) {
        result.message = '无法打开 USB 设备';
        NikonUsbPtp.log('probe pipe-failed');
        return result;
      }
      const configResult = usbManager.setConfiguration(NikonUsbPtp.pipe, selection.config);
      NikonUsbPtp.log(`probe configuration=${configResult}`);
      NikonUsbPtp.iface = selection.iface;
      NikonUsbPtp.bulkIn = selection.bulkIn;
      NikonUsbPtp.bulkOut = selection.bulkOut;
      const claimed = usbManager.claimInterface(NikonUsbPtp.pipe, selection.iface, true);
      if (claimed !== 0) {
        result.message = `占用接口失败 code=${claimed}`;
        NikonUsbPtp.log(`probe claim-failed code=${claimed}`);
        await NikonUsbPtp.close();
        return result;
      }
      const activated = usbManager.setInterface(NikonUsbPtp.pipe, selection.iface);
      NikonUsbPtp.log(`probe interface=${activated}`);
      NikonUsbPtp.transactionId = 0;
      // **标准 OpenSession。** 尼康 USB 上没有索尼那种厂商开启操作码。
      const open = await NikonUsbPtp.transaction(PTP_OP_OPEN_SESSION, [NIKON_SESSION_ID], null);
      const openCode = NikonUsbPtp.responseCode(open, NikonUsbPtp.lastTransactionId);
      NikonUsbPtp.openOpcode = PTP_OP_OPEN_SESSION;
      NikonUsbPtp.openCode = openCode;
      result.openOpcode = PTP_OP_OPEN_SESSION;
      result.openCode = openCode;
      const opened = openCode === 0x2001;
      NikonUsbPtp.log(`probe open-session code=${NikonUsbPtp.hex16(openCode)}`);
      if (!opened && openCode !== 0x201E) {
        // 0x201E = SessionAlreadyOpen：说明上一次会话还活着，可以直接用。
        result.message = `相机未接受 USB 会话（${NikonUsbPtp.hex16(openCode)}），` +
          '请确认机身菜单里的 USB 选项为 PTP/电脑遥控';
        await NikonUsbPtp.close();
        return result;
      }
      NikonUsbPtp.sessionOpen = true;
      const info = await NikonUsbPtp.getDeviceInfo();
      if (info === null) {
        result.message = '读取 DeviceInfo 失败';
        await NikonUsbPtp.close();
        return result;
      }
      result.info = {
        name: device.name,
        vendorId: device.vendorId,
        productId: device.productId,
      };
      result.model = info.model;
      result.operationsHex = info.operationsHex;
      const liveView = info.operations.indexOf(NIKON_OP_START_LIVE_VIEW) >= 0;
      NikonUsbPtp.log(`device model=${info.model} version=${info.version} ` +
        `ops=${info.operations.length} liveView=${liveView ? 1 : 0}`);
      NikonUsbPtp.log('device operations=' + info.operationsHex.join(','));
      result.ok = true;
      result.message = '已通过 USB 连接';
      return result;
    } catch (error) {
      result.message = 'USB 连接失败：' + NikonUsbPtp.errorCode(error as Object);
      NikonUsbPtp.log('probe failed code=' + NikonUsbPtp.errorCode(error as Object));
      await NikonUsbPtp.close();
      return result;
    }
  }

  private static async getDeviceInfo(): Promise<NikonUsbDeviceInfoParse | null> {
    const containers = await NikonUsbPtp.transaction(PTP_OP_GET_DEVICE_INFO, [], null);
    const code = NikonUsbPtp.responseCode(containers, NikonUsbPtp.lastTransactionId);
    if (code !== 0x2001) {
      NikonUsbPtp.log(`get-device-info rejected code=${NikonUsbPtp.hex16(code)}`);
      return null;
    }
    let payload: Uint8Array | null = null;
    for (const container of containers) {
      if (container.type === PTP_CONTAINER_DATA &&
        container.transactionId === NikonUsbPtp.lastTransactionId) {
        payload = container.payload;
      }
    }
    if (payload === null || payload.length < 8) return null;
    // DeviceInfo：StandardVersion u16 / VendorExtId u32 / VendorExtVersion u16 /
    // VendorExtDesc(string) / FunctionalMode u16 / Operations(u16[]) / ...
    let offset = 0;
    const standardVersion = NikonUsbPtp.readLe16(payload, offset);
    offset += 2;
    const vendorExtensionId = NikonUsbPtp.readLe32(payload, offset);
    offset += 4;
    const vendorExtensionVersion = NikonUsbPtp.readLe16(payload, offset);
    offset += 2;
    offset = NikonUsbPtp.skipPtpString(payload, offset);
    offset += 2; // FunctionalMode
    const operations = NikonUsbPtp.readU16Array(payload, offset);
    offset = operations.next;
    const events = NikonUsbPtp.readU16Array(payload, offset);
    offset = events.next;
    offset = NikonUsbPtp.readU16Array(payload, offset).next; // DevicePropertiesSupported
    offset = NikonUsbPtp.readU16Array(payload, offset).next; // CaptureFormats
    offset = NikonUsbPtp.readU16Array(payload, offset).next; // ImageFormats
    const manufacturer = NikonUsbPtp.readPtpString(payload, offset);
    const model = NikonUsbPtp.readPtpString(payload, manufacturer.next);
    const version = NikonUsbPtp.readPtpString(payload, model.next);
    NikonUsbPtp.log(`device standard=${standardVersion} vendorExt=${NikonUsbPtp.hex32(vendorExtensionId)} ` +
      `vendorExtVersion=${vendorExtensionVersion} manufacturer=${manufacturer.value}`);
    return {
      model: model.value,
      version: version.value,
      operations: operations.values,
      operationsHex: operations.values.map((value: number): string => NikonUsbPtp.hex16(value)),
    };
  }

  /** 一条事务：命令容器 →（可选）数据容器 → 读响应容器。 */
  private static async transaction(op: number, params: number[],
    dataOut: Uint8Array | null): Promise<NikonUsbContainer[]> {
    const pipe = NikonUsbPtp.pipe;
    const bulkOut = NikonUsbPtp.bulkOut;
    const bulkIn = NikonUsbPtp.bulkIn;
    if (pipe === null || bulkOut === null || bulkIn === null) {
      throw new Error('Nikon USB pipe is not open');
    }
    NikonUsbPtp.transactionId += 1;
    const transactionId = NikonUsbPtp.transactionId;
    NikonUsbPtp.lastTransactionId = transactionId;
    const command = NikonUsbPtp.commandContainer(op, transactionId, params);
    const sent = await usbManager.bulkTransfer(pipe, bulkOut, command, BULK_TIMEOUT_MS);
    if (sent !== command.byteLength) {
      throw new Error(`command transfer short sent=${sent}/${command.byteLength}`);
    }
    if (dataOut !== null && dataOut.length > 0) {
      const data = NikonUsbPtp.dataContainer(op, transactionId, dataOut);
      const dataSent = await usbManager.bulkTransfer(pipe, bulkOut, data, BULK_TIMEOUT_MS);
      if (dataSent !== data.byteLength) {
        throw new Error(`data transfer short sent=${dataSent}/${data.byteLength}`);
      }
    }
    const containers: NikonUsbContainer[] = [];
    // 一次 bulk 读可能只拿到半个容器（大图尤其容易），所以像索尼那条一样把
    // 已收到的字节累积起来再解析，直到响应容器齐了为止。
    let pending = new Uint8Array(0);
    for (let round = 0; round < MAX_RECEIVE_ROUNDS; round++) {
      const buffer = new Uint8Array(BULK_BUFFER_SIZE);
      const received = await usbManager.bulkTransfer(pipe, bulkIn, buffer, BULK_TIMEOUT_MS);
      if (received <= 0) continue;
      const merged = new Uint8Array(pending.length + received);
      merged.set(pending, 0);
      merged.set(buffer.subarray(0, received), pending.length);
      const parsed = NikonUsbPtp.parseContainers(merged);
      for (const container of parsed.containers) {
        containers.push(container);
      }
      pending = merged.subarray(parsed.consumed);
      if (NikonUsbPtp.responseCode(containers, transactionId) >= 0) return containers;
    }
    return containers;
  }

  private static commandContainer(op: number, transactionId: number, params: number[]): Uint8Array {
    const packet = new Uint8Array(PTP_CONTAINER_HEADER_SIZE + params.length * 4);
    NikonUsbPtp.writeLe32(packet, 0, packet.length);
    NikonUsbPtp.writeLe16(packet, 4, PTP_CONTAINER_COMMAND);
    NikonUsbPtp.writeLe16(packet, 6, op);
    NikonUsbPtp.writeLe32(packet, 8, transactionId);
    for (let index = 0; index < params.length; index++) {
      NikonUsbPtp.writeLe32(packet, PTP_CONTAINER_HEADER_SIZE + index * 4, params[index]);
    }
    return packet;
  }

  private static dataContainer(op: number, transactionId: number, payload: Uint8Array): Uint8Array {
    const packet = new Uint8Array(PTP_CONTAINER_HEADER_SIZE + payload.length);
    NikonUsbPtp.writeLe32(packet, 0, packet.length);
    NikonUsbPtp.writeLe16(packet, 4, PTP_CONTAINER_DATA);
    NikonUsbPtp.writeLe16(packet, 6, op);
    NikonUsbPtp.writeLe32(packet, 8, transactionId);
    packet.set(payload, PTP_CONTAINER_HEADER_SIZE);
    return packet;
  }

  private static parseContainers(buffer: Uint8Array): NikonUsbContainerParse {
    const containers: NikonUsbContainer[] = [];
    let offset = 0;
    while (offset + PTP_CONTAINER_HEADER_SIZE <= buffer.length) {
      const length = NikonUsbPtp.readLe32(buffer, offset);
      if (length < PTP_CONTAINER_HEADER_SIZE || length > buffer.length - offset) break;
      containers.push({
        type: NikonUsbPtp.readLe16(buffer, offset + 4),
        code: NikonUsbPtp.readLe16(buffer, offset + 6),
        transactionId: NikonUsbPtp.readLe32(buffer, offset + 8),
        payload: buffer.slice(offset + PTP_CONTAINER_HEADER_SIZE, offset + length),
      });
      offset += length;
    }
    return { containers: containers, consumed: offset };
  }

  private static responseCode(containers: NikonUsbContainer[], transactionId: number): number {
    for (const container of containers) {
      if (container.type === PTP_CONTAINER_RESPONSE && container.transactionId === transactionId) {
        return container.code;
      }
    }
    return -1;
  }

  /** 关闭会话并释放接口。异常一律吞掉：关流失败不该影响上层。 */
  static async close(): Promise<void> {
    const pipe = NikonUsbPtp.pipe;
    if (pipe !== null && NikonUsbPtp.sessionOpen) {
      try {
        await NikonUsbPtp.transaction(PTP_OP_CLOSE_SESSION, [], null);
      } catch (_error) {
      }
    }
    NikonUsbPtp.sessionOpen = false;
    if (pipe !== null) {
      try {
        if (NikonUsbPtp.iface !== null) usbManager.releaseInterface(pipe, NikonUsbPtp.iface);
      } catch (_error) {
      }
      try {
        usbManager.closePipe(pipe);
      } catch (_error) {
      }
    }
    NikonUsbPtp.pipe = null;
    NikonUsbPtp.iface = null;
    NikonUsbPtp.bulkIn = null;
    NikonUsbPtp.bulkOut = null;
    NikonUsbPtp.transactionId = 0;
    NikonUsbPtp.transportFailed = false;
    // 句柄只在本次会话内有效：重插后同一句柄可能指向别的照片，留着就是坏卡片。
    NikonUsbPtp.galleryRefs = [];
  }

  /** 供 `NikonPtpIpService.attachTransport()` 使用的传输层实例。 */
  static transport(): NikonUsbTransport {
    if (NikonUsbPtp.transportInstance === null) {
      NikonUsbPtp.transportInstance = new NikonUsbTransport();
    }
    NikonUsbPtp.transportInstance.openOpcode = NikonUsbPtp.openOpcode;
    NikonUsbPtp.transportInstance.openCode = NikonUsbPtp.openCode;
    NikonUsbPtp.transportInstance.failed = NikonUsbPtp.transportFailed;
    return NikonUsbPtp.transportInstance;
  }

  /** `PtpTransport.enqueue`：串行化后执行一条事务并归一化成 `NikonPtpResponse`。 */
  static enqueue(op: number, params: number[], expectsData: boolean,
    _tolerateTimeout: boolean = false): Promise<NikonPtpResponse> {
    const task: Promise<NikonPtpResponse> = NikonUsbPtp.queueTail.then(
      async (): Promise<NikonPtpResponse> => {
        if (NikonUsbPtp.transportFailed) throw new Error('Nikon USB transport is unavailable');
        return await NikonUsbPtp.execute(op, params, null, expectsData);
      });
    NikonUsbPtp.queueTail = task.then((): void => {
    }, (): void => {
    });
    return task;
  }

  /** `PtpTransport.enqueueDataOut`：数据阶段由手机发往相机（属性写入就是这条）。 */
  static enqueueDataOut(op: number, params: number[], payload: Uint8Array,
    expectsData: boolean = false): Promise<NikonPtpResponse> {
    const task: Promise<NikonPtpResponse> = NikonUsbPtp.queueTail.then(
      async (): Promise<NikonPtpResponse> => {
        if (NikonUsbPtp.transportFailed) throw new Error('Nikon USB transport is unavailable');
        return await NikonUsbPtp.execute(op, params, payload, expectsData);
      });
    NikonUsbPtp.queueTail = task.then((): void => {
    }, (): void => {
    });
    return task;
  }

  private static async execute(op: number, params: number[], dataOut: Uint8Array | null,
    expectsData: boolean): Promise<NikonPtpResponse> {
    let containers: NikonUsbContainer[] = [];
    try {
      containers = await NikonUsbPtp.transaction(op, params, dataOut);
    } catch (error) {
      // 拔线、相机休眠这类失败必须把传输标成失效：`activeControlTransport()` 看到
      // failed 就会回落到 PTP/IP，而不是让控制页一直往一条已经死掉的管子里发命令。
      NikonUsbPtp.transportFailed = true;
      const instance = NikonUsbPtp.transportInstance;
      if (instance !== null) {
        instance.failed = true;
      }
      NikonUsbPtp.log(`transaction ${NikonUsbPtp.hex16(op)} failed code=` +
        NikonUsbPtp.errorCode(error as Object));
      throw error as Error;
    }
    const id = NikonUsbPtp.lastTransactionId;
    let code = -1;
    let data = new Uint8Array(0);
    for (const container of containers) {
      if (container.type === PTP_CONTAINER_RESPONSE && container.transactionId === id) {
        code = container.code;
      } else if (container.type === PTP_CONTAINER_DATA && container.transactionId === id &&
        expectsData) {
        data = container.payload;
      }
    }
    return { code: code, transaction: id, params: [], data: data };
  }

  // --- 图片传输（USB） ------------------------------------------------------
  //
  // 和 PTP/IP 侧同一套操作码：`0x1004` 存储卡、`0x1007` 句柄、`0x1008` 对象信息、
  // `0x100A` 缩略图、`0x101B` 分段取原始数据。差别只是外层走 bulk 容器，而且
  // `GetPartialObject` 一次只给一段，所以下载要按 512 KB 循环。

  /** 相机上报的存储卡 ID 列表。 */
  static async getStorageIds(): Promise<number[]> {
    const response = await NikonUsbPtp.enqueue(PTP_OP_GET_STORAGE_IDS, [], true);
    if (response.code !== 0x2001) {
      NikonUsbPtp.log(`storage-ids rejected code=${NikonUsbPtp.hex16(response.code)}`);
      return [];
    }
    return NikonUsbPtp.parseU32List(response.data);
  }

  static async getObjectHandles(storageId: number): Promise<number[]> {
    const response = await NikonUsbPtp.enqueue(PTP_OP_GET_OBJECT_HANDLES, [storageId, 0, 0], true);
    if (response.code !== 0x2001) {
      NikonUsbPtp.log(`handles storage=${storageId} rejected code=${NikonUsbPtp.hex16(response.code)}`);
      return [];
    }
    return NikonUsbPtp.parseU32List(response.data)
      .filter((value: number): boolean => value !== 0);
  }

  /** ObjectInfo：只取我们界面要用的几项（名字、大小、格式）。 */
  static async getObjectInfo(handle: number): Promise<NikonUsbObjectInfo | null> {
    const response = await NikonUsbPtp.enqueue(PTP_OP_GET_OBJECT_INFO, [handle], true);
    if (response.code !== 0x2001) return null;
    const data = response.data;
    // StorageID(4) Format(2) Protection(2) CompressedSize(4) ThumbFormat(2)
    // ThumbSize(4) ThumbW(4) ThumbH(4) PixW(4) PixH(4) BitDepth(4)
    // Parent(4) Association(2) AssocDesc(4) Sequence(4) = 52 字节，之后是字符串。
    if (data.length < 52) return null;
    const fileName = NikonUsbPtp.readPtpString(data, 52);
    const captureDate = NikonUsbPtp.readPtpString(data, fileName.next);
    return {
      handle: handle,
      storageId: NikonUsbPtp.readLe32(data, 0),
      format: NikonUsbPtp.readLe16(data, 4),
      size: NikonUsbPtp.readLe32(data, 8),
      fileName: fileName.value,
      captureDate: captureDate.value,
    };
  }

  /** `0x100A`：相机自己生成的缩略图 JPEG。取不到就没缩略图（不阻塞网格）。 */
  static async getThumb(handle: number): Promise<Uint8Array | null> {
    const response = await NikonUsbPtp.enqueue(PTP_OP_GET_THUMB, [handle], true);
    if (response.code !== 0x2001 || response.data.length < 4) return null;
    return response.data;
  }

  /** `0x101B`：从 offset 起最多 length 字节。 */
  static async getPartialObject(handle: number, offset: number,
    length: number): Promise<Uint8Array> {
    const response = await NikonUsbPtp.enqueue(PTP_OP_GET_PARTIAL_OBJECT,
      [handle, offset, length], true);
    if (response.code !== 0x2001) {
      NikonUsbPtp.log(`partial handle=${handle} offset=${offset} code=${NikonUsbPtp.hex16(response.code)}`);
      return new Uint8Array(0);
    }
    return response.data;
  }

  /**
   * 枚举照片列表（与 `NikonPtpIpService.listGallery` 同形，界面无需区分传输）。
   *
   * 卡片顺序、倒序（最新在前）、每项带 `storageId` 的规则都照 PTP/IP 那条来：
   * 两张卡的句柄空间独立，同号句柄会互相覆盖缩略图。
   */
  static async listGallery(context: common.UIAbilityContext,
    limit: number = 6): Promise<NikonPtpCatalogResult> {
    if (!NikonUsbPtp.isOpen()) {
      return {
        ok: false, message: 'USB 会话未建立', host: 'usb', total: 0, items: [],
        nextHandleIndex: 0, remaining: 0,
      };
    }
    try {
      const storageIds = await NikonUsbPtp.getStorageIds();
      NikonUsbPtp.log(`storages=${storageIds.length}`);
      if (storageIds.length === 0) {
        return {
          ok: false, message: 'USB 未返回存储卡', host: 'usb', total: 0, items: [],
          nextHandleIndex: 0, remaining: 0,
        };
      }
      const cardIds: number[] = [];
      const cardHandles: number[][] = [];
      for (const storageId of storageIds) {
        const handles = await NikonUsbPtp.getObjectHandles(storageId);
        handles.sort((left: number, right: number): number => left - right);
        NikonUsbPtp.log(`card storage=${storageId} objects=${handles.length}`);
        cardIds.push(storageId);
        cardHandles.push(handles);
      }
      // 每张卡内部倒序（最新在前），卡与卡之间不交错。
      const ordered: NikonUsbObjectRef[] = [];
      for (let cardIndex = 0; cardIndex < cardIds.length; cardIndex++) {
        const descending = cardHandles[cardIndex].slice().reverse();
        for (const handle of descending) {
          ordered.push({ handle: handle, storageId: cardIds[cardIndex] });
        }
      }
      // 记住整张表的顺序，滚到底时按游标继续取，不必重新枚举存储卡。
      NikonUsbPtp.galleryRefs = ordered;
      const items: NikonPtpGalleryItem[] = [];
      const pageCount = Math.min(limit, ordered.length);
      for (let index = 0; index < pageCount; index++) {
        const ref = ordered[index];
        const info = await NikonUsbPtp.getObjectInfo(ref.handle);
        if (info === null) continue;
        const name = info.fileName.length > 0 ? info.fileName : `NIKON_${ref.handle}.JPG`;
        const thumbUri = await NikonUsbPtp.cacheThumbnail(context, ref, info);
        items.push({
          imageId: String(ref.handle),
          imageType: NikonUsbPtp.imageTypeOf(name),
          thumbnailUri: thumbUri,
          size: info.size,
          rawSize: 0,
          originalFileName: name,
          handle: ref.handle,
          storageId: ref.storageId,
        });
      }
      NikonUsbPtp.log(`gallery cards=${cardIds.length} total=${ordered.length} listed=${items.length}`);
      return {
        ok: true,
        message: `USB 会话已建立，${cardIds.length} 张存储卡共 ${ordered.length} 个对象，`
          + `已读取 ${items.length} 张缩略图`,
        host: 'usb',
        total: ordered.length,
        items: items,
        nextHandleIndex: pageCount,
        remaining: ordered.length - pageCount,
        storageIds: cardIds,
      };
    } catch (error) {
      NikonUsbPtp.log('list-gallery failed code=' + NikonUsbPtp.errorCode(error as Object));
      return {
        ok: false, message: 'USB 读取照片列表失败：' + NikonUsbPtp.errorCode(error as Object),
        host: 'usb', total: 0, items: [], nextHandleIndex: 0, remaining: 0,
      };
    }
  }

  /** 翻页：从游标处继续取一页（与 `NikonPtpIpService.fetchPageAfter` 同形）。 */
  static async fetchPageAfter(context: common.UIAbilityContext, fromIndex: number,
    count: number): Promise<NikonPtpGalleryPage> {
    if (NikonUsbPtp.galleryRefs.length === 0) {
      // 还没枚举过（例如应用重启后直接滚动）：先把整张表拉一遍再切页。
      await NikonUsbPtp.listGallery(context, count);
    }
    const total = NikonUsbPtp.galleryRefs.length;
    const start = Math.max(0, Math.min(fromIndex, total));
    const end = Math.min(start + count, total);
    const items: NikonPtpGalleryItem[] = [];
    for (let index = start; index < end; index++) {
      const ref = NikonUsbPtp.galleryRefs[index];
      const info = await NikonUsbPtp.getObjectInfo(ref.handle);
      if (info === null) continue;
      const name = info.fileName.length > 0 ? info.fileName : `NIKON_${ref.handle}.JPG`;
      const thumbUri = await NikonUsbPtp.cacheThumbnail(context, ref, info);
      items.push({
        imageId: String(ref.handle),
        imageType: NikonUsbPtp.imageTypeOf(name),
        thumbnailUri: thumbUri,
        size: info.size,
        rawSize: 0,
        originalFileName: name,
        handle: ref.handle,
        storageId: ref.storageId,
      });
    }
    NikonUsbPtp.log(`page from=${start} to=${end} items=${items.length} total=${total}`);
    return { items: items, nextHandleIndex: end, remaining: total - end };
  }

  /** 把相机缩略图落到应用目录，返回 `file://` 地址；失败返回空串。 */
  private static async cacheThumbnail(context: common.UIAbilityContext, ref: NikonUsbObjectRef,
    info: NikonUsbObjectInfo): Promise<string> {
    const bytes = await NikonUsbPtp.getThumb(ref.handle);
    if (bytes === null || bytes.length < 4) return '';
    const extension = NikonUsbPtp.extensionOf(info.fileName);
    const path = `${context.filesDir}/nikon_usb_thumb_${ref.storageId}_${ref.handle}.jpg`;
    try {
      NikonUsbPtp.removeFile(path);
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, bytes.buffer.slice(0, bytes.length));
      fileIo.closeSync(file);
    } catch (error) {
      NikonUsbPtp.log(`thumb-write failed handle=${ref.handle} code=${NikonUsbPtp.errorCode(error as Object)}`);
      return '';
    }
    NikonUsbPtp.log(`thumb handle=${ref.handle} ext=${extension} bytes=${bytes.length}`);
    return 'file://' + path;
  }

  /**
   * 下载原图到沙箱并返回 `file://` 地址（与 `NikonPtpIpService.downloadOriginal`
   * 同约定；调用方随后照旧写进媒体库并加入最近作品）。
   */
  static async downloadOriginal(context: common.UIAbilityContext, imageId: string,
    originalFileName: string, index: number,
    onProgress?: (progress: number, received: number, total: number) => void): Promise<string> {
    if (!NikonUsbPtp.isOpen()) return '';
    const handle = Number(imageId);
    if (!Number.isFinite(handle) || handle <= 0) return '';
    const info = await NikonUsbPtp.getObjectInfo(handle);
    if (info === null) {
      NikonUsbPtp.log(`download info-missing handle=${handle}`);
      return '';
    }
    const total = info.size;
    if (total <= 0) {
      NikonUsbPtp.log(`download empty handle=${handle}`);
      return '';
    }
    const name = (originalFileName.length > 0)
      ? originalFileName : `NIKON_USB_${index + 1}.${NikonUsbPtp.extensionOf(info.fileName)}`;
    const safeName = name.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_');
    const finalPath = `${context.filesDir}/nikon_usb_${index}_${safeName}`;
    const partPath = `${finalPath}.part`;
    let fd: number = -1;
    const startedAt = Date.now();
    try {
      NikonUsbPtp.removeFile(partPath);
      const part = fileIo.openSync(partPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fd = part.fd;
      let written = 0;
      while (written < total) {
        const want = Math.min(PARTIAL_CHUNK_BYTES, total - written);
        const chunk = await NikonUsbPtp.getPartialObject(handle, written, want);
        if (chunk.length === 0) break;
        fileIo.writeSync(fd, chunk.buffer.slice(0, chunk.length));
        written += chunk.length;
        if (onProgress) onProgress(Math.min(99, Math.floor((written / total) * 100)), written, total);
      }
      fileIo.closeSync(part);
      fd = -1;
      if (written < total) {
        // 半截文件绝不落盘：宁可报失败，也不要让媒体库里出现一张截断的照片。
        NikonUsbPtp.removeFile(partPath);
        NikonUsbPtp.log(`download incomplete handle=${handle} bytes=${written}/${total}`);
        return '';
      }
      NikonUsbPtp.removeFile(finalPath);
      fileIo.renameSync(partPath, finalPath);
      const seconds = Math.max((Date.now() - startedAt) / 1000, 0.001);
      NikonUsbPtp.log(`download complete file=${safeName} bytes=${written} ` +
        `seconds=${seconds.toFixed(1)} rate=${(written / 1024 / 1024 / seconds).toFixed(2)}MB/s`);
      if (onProgress) onProgress(100, written, total);
      return `file://${finalPath}`;
    } catch (error) {
      NikonUsbPtp.log(`download failed handle=${handle} code=${NikonUsbPtp.errorCode(error as Object)}`);
      return '';
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (_closeError) {
        }
      }
      NikonUsbPtp.removeFile(partPath);
    }
  }

  private static removeFile(path: string): void {
    try {
      if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
    } catch (_error) {
    }
  }

  private static extensionOf(name: string): string {
    const dot = name.lastIndexOf('.');
    if (dot < 0 || dot === name.length - 1) return 'jpg';
    return name.substring(dot + 1).toLowerCase();
  }

  /** 与 Lumix 线的约定一致：2 = RAW，1 = 视频，0 = 普通图片。 */
  private static imageTypeOf(name: string): number {
    const extension = NikonUsbPtp.extensionOf(name);
    if (extension === 'nef' || extension === 'nrw' || extension === 'dng') return 2;
    if (extension === 'mov' || extension === 'mp4' || extension === 'avi') return 1;
    return 0;
  }

  /** PTP 的「u32 个数 + 每项 u32」列表（存储卡 ID、对象句柄都是这种）。 */
  private static parseU32List(data: Uint8Array): number[] {
    const values: number[] = [];
    if (data.length < 4) return values;
    const count = NikonUsbPtp.readLe32(data, 0);
    for (let index = 0; index < count; index++) {
      const offset = 4 + index * 4;
      if (offset + 4 > data.length) break;
      values.push(NikonUsbPtp.readLe32(data, offset));
    }
    return values;
  }

  // --- 小工具 ---------------------------------------------------------------

  private static readLe16(buffer: Uint8Array, offset: number): number {
    return buffer[offset] | (buffer[offset + 1] << 8);
  }

  private static readLe32(buffer: Uint8Array, offset: number): number {
    return (buffer[offset] | (buffer[offset + 1] << 8) |
      (buffer[offset + 2] << 16) | (buffer[offset + 3] << 24)) >>> 0;
  }

  private static writeLe16(buffer: Uint8Array, offset: number, value: number): void {
    buffer[offset] = value & 0xFF;
    buffer[offset + 1] = (value >>> 8) & 0xFF;
  }

  private static writeLe32(buffer: Uint8Array, offset: number, value: number): void {
    buffer[offset] = value & 0xFF;
    buffer[offset + 1] = (value >>> 8) & 0xFF;
    buffer[offset + 2] = (value >>> 16) & 0xFF;
    buffer[offset + 3] = (value >>> 24) & 0xFF;
  }

  /** PTP 字符串：首字节是字符数（含结尾 0），UTF‑16LE。 */
  private static readPtpString(buffer: Uint8Array, offset: number): NikonUsbStringRead {
    if (offset >= buffer.length) return { value: '', next: offset };
    const count = buffer[offset];
    if (count === 0) return { value: '', next: offset + 1 };
    const chars = count - 1;
    let text = '';
    for (let index = 0; index < chars; index++) {
      const at = offset + 1 + index * 2;
      if (at + 1 >= buffer.length) break;
      text += String.fromCharCode(NikonUsbPtp.readLe16(buffer, at));
    }
    return { value: text, next: offset + 1 + chars * 2 };
  }

  private static skipPtpString(buffer: Uint8Array, offset: number): number {
    return NikonUsbPtp.readPtpString(buffer, offset).next;
  }

  /** u32 个数 + 每项 u16 的数组（PTP 的 OperationsSupported 就是这种）。 */
  private static readU16Array(buffer: Uint8Array, offset: number): NikonUsbU16ArrayRead {
    if (offset + 4 > buffer.length) return { values: [], next: offset };
    const count = NikonUsbPtp.readLe32(buffer, offset);
    const values: number[] = [];
    let cursor = offset + 4;
    for (let index = 0; index < count; index++) {
      if (cursor + 2 > buffer.length) break;
      values.push(NikonUsbPtp.readLe16(buffer, cursor));
      cursor += 2;
    }
    return { values: values, next: cursor };
  }
}

/** ObjectInfo 里我们真正要用的字段。 */
export interface NikonUsbObjectInfo {
  handle: number;
  storageId: number;
  format: number;
  size: number;
  fileName: string;
  captureDate: string;
}

/** 列表游标：句柄 + 它属于哪张卡（两张卡句柄空间独立）。 */
interface NikonUsbObjectRef {
  handle: number;
  storageId: number;
}

interface NikonUsbContainerParse {  containers: NikonUsbContainer[];
  /** 已解析掉的字节数，剩下的半截容器留给下一次读。 */
  consumed: number;
}

interface NikonUsbStringRead {
  value: string;
  next: number;
}

interface NikonUsbU16ArrayRead {
  values: number[];
  next: number;
}

interface NikonUsbDeviceInfoParse {
  model: string;
  version: string;
  operations: number[];
  operationsHex: string[];
}
