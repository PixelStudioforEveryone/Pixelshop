/**
 * 佳能固件更新服务（版本获取 → 清单 → 下载 → .FIR 校验 → PTP 直传）。
 *
 * 依据：`documents/Canon/report/04-固件更新-版本获取与升级协议.md`（下称报告 04）。
 * 与官方 App 的差异只在**传输这一跳**：官方走 `SDK.EdsSendFiemware()` →
 * native `DS_UpdateFirmware`，报告 04 §6.1 明确该 opcode 未取得；本实现按
 * PTP 公开实现（libgphoto2 `ptp2/ptp.h` 的 `EOS_UpdateFirmware = 0x911F`）拼出
 * 「SendObjectInfo(0x100C) → SendObject(0x100D) → EOS_UpdateFirmware(0x911F)」
 * 三段，并在注释里标出这是**推断链路**，失败时页面会提示改用读卡器方式。
 *
 * 三条铁律：
 *  1. 版本比较严格按报告 04 §4（三段 parseInt，严格大于）；
 *  2. `.FIR` 头解析严格按报告 04 §5.1（含 0x37582111 分支与 6 段版本规则）；
 *  3. 不伪造成功：任何一步失败都返回 false/无效，并把 PTP 码带回页面。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { AppLogSink } from './AppLogSink';
import { CanonBleService } from './CanonBleService';
import { CanonModels } from './CanonModels';
import { CanonPtpIp } from './CanonPtpIp';
import { CameraSessionStore } from './CameraSessionStore';

const TAG: string = 'CANON_FW';
/** 官方唯一客户端拼接的清单地址（报告 04 §3.2；内测域名分支不实现）。 */
const CATALOG_URL: string = 'https://gdlp01.c-wss.com/rmds/ic/firmware/camera_urltable.xml';
/** 固件下载目录（报告 04 §5：`getFilesDir()/firm`，这里给佳能单独一层）。 */
const FIRMWARE_DIR_NAME: string = 'firm';
/** `.FIR` 特殊容器头（报告 04 §5.1）。 */
const FIR_CONTAINER_MAGIC: number = 0x37582111;
/** 下载/请求超时：官方未设置超时，这里给一个宽松上限防止永久挂起。 */
const CONNECT_TIMEOUT_MS: number = 15000;
const READ_TIMEOUT_MS: number = 600000;
/** PTP 命令超时。 */
const PTP_TIMEOUT_MS: number = 12000;
/** 上传对象格式：未定义格式（EOS 固件包按二进制对象发送）。 */
const OBJECT_FORMAT_UNDEFINED: number = 0x3000;
/** EDSDK `EdsSendFiemware` 的进度回调在官方是 0-100；这里按阶段给值。 */
const PROGRESS_AFTER_CHECKS: number = 5;
const PROGRESS_AFTER_OBJECT_INFO: number = 20;
const PROGRESS_AFTER_OBJECT_DATA: number = 95;
/** 超过该大小只提示、不阻断（EOS 固件通常 30-60 MB）。 */
const LARGE_FIRMWARE_BYTES: number = 96 * 1024 * 1024;

/** 相机侧状态：版本、机型 ID、产品 ID。 */
export interface CanonFirmwareCameraState {
  model: string;
  firmware: string;
  modelId: number;
  productIdHex: string;
  connected: boolean;
}

/** 清单里匹配到的一次更新。 */
export interface CanonFirmwareDetail {
  version: string;
  firmwareUrl: string;
  fileSize: number;
  changesUrl: string;
  eulaUrl: string;
  productIdHex: string;
}

export interface CanonFirmwareVersionState {
  current: string;
  latest: string;
  productIdHex: string;
  hasUpdate: boolean;
  detail: CanonFirmwareDetail | null;
  message: string;
}

/** 本地 `.FIR` 头解析结果（报告 04 §5.1）。 */
export interface CanonFirInfo {
  modelId: number;
  version: string;
  size: number;
  valid: boolean;
  reason: string;
}

/** 清单 `<item>` 的一行。 */
interface CanonCatalogItem {
  idHex: string;
  version: string;
  url: string;
}

/** 机型详情 XML 的字段。 */
interface CanonFirmwarePageDetail {
  firmware: string;
  fileSize: number;
  changes: string;
  eula: string;
}

/** 标准 StorageInfo 数据集的解析结果（只取固件检查需要的字段）。 */
interface CanonStorageCheck {
  storageId: number;
  access: number;
  capacity: number;
  free: number;
}

export class CanonFirmwareService {
  /** 由页面在 `aboutToAppear` 注入；服务层不反向依赖页面模块。 */
  private static filesDir: string = '';
  private static downloading: boolean = false;
  private static cancelled: boolean = false;
  /** 最近一次使用的相机主机（未连接 PTP 时的提示用）。 */
  private static lastHost: string = '';

  /** 页面初始化时调用一次（拿沙箱目录）。 */
  static configure(context: common.UIAbilityContext): void {
    CanonFirmwareService.filesDir = context.filesDir;
  }

  static log(message: string): void {
    AppLogSink.emit(TAG, message);
  }

  /**
   * 读相机状态：固件版本 = PTP 属性 7；机型 ID = 0x01000001（报告 04 §2.1）。
   *
   * 未连接 PTP/IP 时返回 `connected=false`，不抛异常——首页/固件页仍要能显示
   * 「需要先连接相机」而不是空白。
   */
  static async readCameraState(): Promise<CanonFirmwareCameraState> {
    const store: CameraSessionStore = CameraSessionStore.instance;
    let model: string = store.cameraModel.length > 0 ? store.cameraModel : 'Canon';
    let productIdHex: string = '';
    const ble = CanonBleService.current();
    if (ble !== null && ble.pid > 0) productIdHex = CanonModels.pidHex(ble.pid);
    if (productIdHex.length === 0) {
      const identity = CanonModels.identityFromName(model);
      if (identity !== null) productIdHex = CanonModels.pidHex(identity.pid);
    }
    const state: CanonFirmwareCameraState = {
      model: model, firmware: '', modelId: 0, productIdHex: productIdHex, connected: false,
    };
    if (!CanonPtpIp.isOpen()) {
      CanonFirmwareService.log('未连接 PTP/IP，无法读取固件版本');
      return state;
    }
    try {
      const firmware = await CanonFirmwareService.readPropertyString(7);
      const modelId = await CanonFirmwareService.readPropertyNumber(0x01000001);
      const productName = await CanonFirmwareService.readPropertyString(2);
      if (productName.length > 0) model = productName;
      state.model = model;
      state.firmware = firmware;
      state.modelId = modelId;
      state.connected = firmware.length > 0;
      CanonFirmwareService.log(`相机固件=${firmware} modelId=${modelId} product=${productIdHex}`);
    } catch (error) {
      CanonFirmwareService.log(`读固件状态失败: ${(error as Error).message}`);
    }
    return state;
  }

  /**
   * 拉清单并匹配产品 ID（报告 04 §3.3）。
   *
   * `<item id="3320" version="1.2.3"><url>…</url></item>`，`id` 是十六进制，
   * 与产品 ID 同源；版本严格大于当前才 `hasUpdate=true`。
   */
  static async fetchCatalog(productIdHex: string): Promise<CanonFirmwareVersionState> {
    const current: string = await CanonFirmwareService.currentVersion();
    const result: CanonFirmwareVersionState = {
      current: current, latest: '', productIdHex: productIdHex,
      hasUpdate: false, detail: null, message: '',
    };
    if (productIdHex.length === 0) {
      result.message = '没有产品 ID，无法匹配固件清单';
      return result;
    }
    const body: string = await CanonFirmwareService.httpText(CATALOG_URL);
    if (body.length === 0) {
      result.message = '固件清单下载失败（无网络或服务器不可用）';
      return result;
    }
    const items: CanonCatalogItem[] = CanonFirmwareService.parseCatalog(body);
    CanonFirmwareService.log(`清单条目=${items.length} 目标产品=${productIdHex}`);
    const target: number = CanonFirmwareService.hexToNumber(productIdHex);
    let hit: CanonCatalogItem | null = null;
    for (const item of items) {
      if (CanonFirmwareService.hexToNumber(item.idHex) !== target) continue;
      if (hit === null || CanonFirmwareService.isNewer(item.version, hit.version)) hit = item;
    }
    if (hit === null) {
      result.message = '该机型没有发布固件';
      return result;
    }
    result.latest = hit.version;
    if (!CanonFirmwareService.isNewer(hit.version, current)) {
      result.message = current.length > 0 ? '已是最新版本' : '已是最新版本（当前版本未知）';
      return result;
    }
    const detailXml: string = await CanonFirmwareService.httpText(hit.url);
    if (detailXml.length === 0) {
      result.message = '机型固件详情下载失败';
      return result;
    }
    const detail: CanonFirmwarePageDetail = CanonFirmwareService.parseDetail(detailXml);
    if (detail.firmware.length === 0) {
      result.message = '详情里没有固件下载地址';
      return result;
    }
    result.detail = {
      version: hit.version,
      firmwareUrl: detail.firmware,
      fileSize: detail.fileSize,
      changesUrl: detail.changes,
      eulaUrl: detail.eula,
      productIdHex: productIdHex,
    };
    result.hasUpdate = true;
    result.message = `发现新固件 ${hit.version}`;
    CanonFirmwareService.log(`发现更新 ${current} -> ${hit.version} size=${detail.fileSize}`);
    return result;
  }

  /**
   * 下载 `.FIR`（报告 04 §5）：流式写盘、无 Range、无校验和（与官方一致）。
   * 返回本地绝对路径；失败 throw，由页面显示原因。
   */
  static async download(detail: CanonFirmwareDetail,
    onProgress: (percent: number, received: number, total: number) => void): Promise<string> {
    if (CanonFirmwareService.filesDir.length === 0) throw new Error('固件服务未初始化');
    const dir: string = `${CanonFirmwareService.filesDir}/${FIRMWARE_DIR_NAME}/canon`;
    try {
      fileIo.mkdirSync(dir, true);
    } catch (_error) {
      // 目录已存在时忽略。
    }
    const name: string = CanonFirmwareService.fileNameOf(detail.firmwareUrl, detail.version);
    const path: string = `${dir}/${name}`;
    CanonFirmwareService.cancelled = false;
    CanonFirmwareService.downloading = true;
    const client = http.createHttp();
    let file: fileIo.File | null = null;
    let received: number = 0;
    const total: number = detail.fileSize > 0 ? detail.fileSize : 0;
    try {
      const ended: Promise<void> = new Promise<void>((resolve: () => void) => {
        client.on('dataReceive', (chunk: ArrayBuffer) => {
          if (CanonFirmwareService.cancelled) return;
          try {
            if (file === null) {
              file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY |
                fileIo.OpenMode.TRUNC);
            }
            fileIo.writeSync(file.fd, chunk);
            received += chunk.byteLength;
            onProgress(total > 0 ? Math.min(99, Math.floor(received * 100 / total)) : -1, received, total);
          } catch (error) {
            CanonFirmwareService.log(`写盘失败: ${(error as Error).message}`);
          }
        });
        client.on('dataEnd', () => { resolve(); });
      });
      const code: number = await client.requestInStream(detail.firmwareUrl, {
        method: http.RequestMethod.GET,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxRedirects: 5,
      });
      if (code < 200 || code >= 300) throw new Error(`HTTP ${code}`);
      await ended;
      if (file !== null) {
        fileIo.closeSync(file);
        file = null;
      }
    } catch (error) {
      if (file !== null) {
        try { fileIo.closeSync(file); } catch (_error) { }
      }
      CanonFirmwareService.downloading = false;
      throw new Error(`固件下载失败：${(error as Error).message}`);
    } finally {
      client.destroy();
      CanonFirmwareService.downloading = false;
    }
    if (CanonFirmwareService.cancelled) {
      try { fileIo.unlinkSync(path); } catch (_error) { }
      throw new Error('已取消下载');
    }
    if (received === 0) throw new Error('固件下载为空');
    if (total > 0 && received !== total) {
      CanonFirmwareService.log(`下载字节数与清单不一致：${received}/${total}`);
    }
    onProgress(100, received, total);
    CanonFirmwareService.log(`下载完成 ${name} bytes=${received}`);
    return path;
  }

  /**
   * 解析 `.FIR` 头（报告 04 §5.1）：
   *   4B 小端机型 ID → skip 12 → 若 0x37582111 再读 4B → 12B ASCII 版本 → 6 段规则。
   */
  static async validateFir(path: string): Promise<CanonFirInfo> {
    const info: CanonFirInfo = {
      modelId: 0, version: '', size: 0, valid: false, reason: '',
    };
    try {
      const stat = fileIo.statSync(path);
      info.size = stat.size;
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let head: Uint8Array = new Uint8Array(0);
      try {
        head = new Uint8Array(40);
        fileIo.readSync(file.fd, head.buffer as ArrayBuffer, { length: 40 });
      } finally {
        fileIo.closeSync(file);
      }
      const view: DataView = new DataView(head.buffer as ArrayBuffer);
      let offset: number = 0;
      let modelId: number = view.getUint32(0, true);
      offset = 4;
      // skip 12 bytes（报告 04 §5.1）
      offset += 12;
      if (modelId === FIR_CONTAINER_MAGIC && head.byteLength >= offset + 16) {
        modelId = view.getUint32(offset, true);
        offset += 4;
      }
      info.modelId = modelId;
      let versionRaw: string = '';
      for (let i = 0; i < 12; i++) {
        const code: number = head[offset + i];
        if (code === 0) break;
        versionRaw += String.fromCharCode(code);
      }
      info.version = CanonFirmwareService.normalizeFirVersion(versionRaw);
      const name: string = CanonFirmwareService.baseName(path);
      const dot: number = name.lastIndexOf('.');
      const ext: string = dot >= 0 ? name.substring(dot + 1).toUpperCase() : '';
      const stem: string = dot >= 0 ? name.substring(0, dot) : name;
      info.valid = info.version.length > 0 && ext === 'FIR';
      info.reason = info.valid ? '' : (ext !== 'FIR' ? '扩展名不是 FIR' : '版本串无法解析');
      if (stem.length !== 12) {
        info.reason = info.reason.length > 0 ? `${info.reason}；文件名长度 ${stem.length}（官方为 12）`
          : `文件名长度 ${stem.length}（官方为 12）`;
      }
      return info;
    } catch (error) {
      info.valid = false;
      info.reason = `读取文件失败：${(error as Error).message}`;
      return info;
    }
  }

  /**
   * 传输到相机（报告 04 §6）。
   *
   * 传输前检查：机型 ID 一致、版本更新、文件存在、卡可写、剩余空间足够；
   * 然后 SendObjectInfo → SendObject → EOS_UpdateFirmware(0x911F, handle)。
   */
  static async send(path: string, onProgress: (percent: number) => void): Promise<boolean> {
    if (!CanonPtpIp.isOpen()) {
      CanonFirmwareService.log('未连接相机，无法传输固件');
      return false;
    }
    let size: number = 0;
    try {
      size = fileIo.statSync(path).size;
    } catch (error) {
      CanonFirmwareService.log(`固件文件不存在: ${(error as Error).message}`);
      return false;
    }
    if (size <= 0) {
      CanonFirmwareService.log('固件文件为空');
      return false;
    }
    if (size > LARGE_FIRMWARE_BYTES) {
      CanonFirmwareService.log(`固件较大（${size}），上传可能超时`);
    }
    const state: CanonFirmwareCameraState = await CanonFirmwareService.readCameraState();
    const fir: CanonFirInfo = await CanonFirmwareService.validateFir(path);
    if (!fir.valid) {
      CanonFirmwareService.log(`固件头无效：${fir.reason}`);
      return false;
    }
    if (state.modelId > 0 && fir.modelId > 0 && state.modelId !== fir.modelId) {
      CanonFirmwareService.log(`机型不匹配：相机=${state.modelId} 文件=${fir.modelId}`);
      return false;
    }
    if (state.firmware.length > 0 && !CanonFirmwareService.isNewer(fir.version, state.firmware)) {
      CanonFirmwareService.log(`文件版本 ${fir.version} 不高于相机 ${state.firmware}`);
      return false;
    }
    const storage: CanonStorageCheck | null = await CanonFirmwareService.firstWritableStorage();
    if (storage === null) {
      CanonFirmwareService.log('没有可写存储卡');
      return false;
    }
    if (storage.free > 0 && storage.free < size) {
      CanonFirmwareService.log(`存储卡空间不足：${storage.free} < ${size}`);
      return false;
    }
    onProgress(PROGRESS_AFTER_CHECKS);
    CanonFirmwareService.log(`开始传输 name=${CanonFirmwareService.baseName(path)} bytes=${size}`);
    const handle: number = await CanonFirmwareService.sendObject(storage.storageId, path, size,
      (percent: number) => { onProgress(percent); }, fir);
    if (handle <= 0) {
      CanonFirmwareService.log('SendObjectInfo/SendObject 未返回对象句柄');
      return false;
    }
    onProgress(PROGRESS_AFTER_OBJECT_DATA);
    try {
      const reply = await CanonPtpIp.op(0x911F, [handle], PTP_TIMEOUT_MS);
      if (reply.code !== 0x2001) {
        CanonFirmwareService.log(`EOS_UpdateFirmware 返回 0x${reply.code.toString(16)}`);
        return false;
      }
    } catch (error) {
      CanonFirmwareService.log(`EOS_UpdateFirmware 异常: ${(error as Error).message}`);
      return false;
    }
    onProgress(100);
    CanonFirmwareService.log('固件已交给相机，等待相机重启与屏幕确认');
    return true;
  }

  static async cancel(): Promise<void> {
    CanonFirmwareService.cancelled = true;
    if (CanonFirmwareService.downloading) CanonFirmwareService.log('用户取消下载');
    // 上传阶段无法中断一条已开始的 PTP 数据阶段；置位后由页面提示等相机返回。
    return Promise.resolve();
  }

  // ------------------------------------------------------------------
  // 内部实现
  // ------------------------------------------------------------------

  /** SendObjectInfo + SendObject；返回相机分配的对象句柄。 */
  private static async sendObject(storageId: number, path: string, size: number,
    onProgress: (percent: number) => void, fir: CanonFirInfo): Promise<number> {
    const name: string = CanonFirmwareService.baseName(path);
    const info: Uint8Array = CanonFirmwareService.buildObjectInfo(storageId, name, size);
    let handle: number = 0;
    try {
      const reply = await CanonPtpIp.opOut(0x100C, [storageId, 0], info, PTP_TIMEOUT_MS);
      if (reply.code !== 0x2001) {
        CanonFirmwareService.log(`SendObjectInfo 返回 0x${reply.code.toString(16)}`);
        return 0;
      }
      // 规范：应答参数 = [StorageID, ParentObjectHandle, ObjectHandle]
      if (reply.params.length >= 3) handle = reply.params[2];
      onProgress(PROGRESS_AFTER_OBJECT_INFO);
    } catch (error) {
      CanonFirmwareService.log(`SendObjectInfo 异常: ${(error as Error).message}`);
      return 0;
    }
    let data: Uint8Array;
    try {
      data = CanonFirmwareService.readFileBytes(path, size);
    } catch (error) {
      CanonFirmwareService.log(`读固件文件失败: ${(error as Error).message}`);
      return 0;
    }
    try {
      const reply = await CanonPtpIp.opOut(0x100D, [], data, READ_TIMEOUT_MS);
      if (reply.code !== 0x2001) {
        CanonFirmwareService.log(`SendObject 返回 0x${reply.code.toString(16)}`);
        return 0;
      }
      if (handle === 0 && reply.params.length >= 1) handle = reply.params[0];
      CanonFirmwareService.log(`SendObject 完成 handle=${handle} version=${fir.version}`);
      return handle;
    } catch (error) {
      CanonFirmwareService.log(`SendObject 异常: ${(error as Error).message}`);
      return 0;
    }
  }

  /** PTP ObjectInfo 数据集（53 字节定长 + 4 个字符串）。 */
  private static buildObjectInfo(storageId: number, fileName: string, size: number): Uint8Array {
    const nameBytes: Uint8Array = CanonFirmwareService.asciiZ(fileName);
    const dateStr: string = CanonFirmwareService.ptpDate(new Date());
    const dateBytes: Uint8Array = CanonFirmwareService.asciiZ(dateStr);
    const empty: Uint8Array = new Uint8Array(1);
    const fixed: number = 52;
    const total: number = fixed + nameBytes.length + dateBytes.length + dateBytes.length + empty.length;
    const buffer: ArrayBuffer = new ArrayBuffer(total);
    const view: DataView = new DataView(buffer);
    let offset: number = 0;
    view.setUint32(offset, storageId, true); offset += 4;
    view.setUint16(offset, OBJECT_FORMAT_UNDEFINED, true); offset += 2;
    view.setUint16(offset, 0, true); offset += 2;           // ProtectionStatus
    view.setUint32(offset, size, true); offset += 4;        // ObjectCompressedSize
    view.setUint16(offset, 0, true); offset += 2;           // ThumbFormat
    view.setUint32(offset, 0, true); offset += 4;           // ThumbCompressedSize
    view.setUint32(offset, 0, true); offset += 4;           // ThumbPixWidth
    view.setUint32(offset, 0, true); offset += 4;           // ThumbPixHeight
    view.setUint32(offset, 0, true); offset += 4;           // ImagePixWidth
    view.setUint32(offset, 0, true); offset += 4;           // ImagePixHeight
    view.setUint32(offset, 0, true); offset += 4;           // ImageBitDepth
    view.setUint32(offset, 0, true); offset += 4;           // ParentObject
    view.setUint16(offset, 0, true); offset += 2;           // AssociationType
    view.setUint32(offset, 0, true); offset += 4;           // AssociationDesc
    view.setUint32(offset, 0, true); offset += 4;           // SequenceNumber
    const out: Uint8Array = new Uint8Array(buffer);
    let cursor: number = offset;
    out.set(nameBytes, cursor); cursor += nameBytes.length;
    out.set(dateBytes, cursor); cursor += dateBytes.length;
    out.set(dateBytes, cursor); cursor += dateBytes.length;
    out.set(empty, cursor);
    return out;
  }

  private static async firstWritableStorage(): Promise<CanonStorageCheck | null> {
    let ids: number[] = [];
    try {
      const reply = await CanonPtpIp.opIn(0x9101, [], PTP_TIMEOUT_MS);
      ids = CanonFirmwareService.parseUint32List(reply.data);
      if (ids.length === 0) {
        const std = await CanonPtpIp.opIn(0x1004, [], PTP_TIMEOUT_MS);
        ids = CanonFirmwareService.parseUint32List(std.data);
      }
    } catch (error) {
      CanonFirmwareService.log(`GetStorageIDs 失败: ${(error as Error).message}`);
      return null;
    }
    for (const id of ids) {
      try {
        const reply = await CanonPtpIp.opIn(0x9102, [id], PTP_TIMEOUT_MS);
        const parsed = CanonFirmwareService.parseStorageInfo(reply.data);
        if (parsed !== null && parsed.access !== 0) return parsed;
      } catch (_error) {
        // 该卷读不到就试下一个。
      }
    }
    return null;
  }

  /** 标准 StorageInfo：storageId u32, type u16, fs u16, access u16, cap u64, free u64, … */
  private static parseStorageInfo(data: Uint8Array): CanonStorageCheck | null {
    if (data.byteLength < 26) return null;
    const view: DataView = new DataView(data.buffer, data.byteOffset, data.byteLength);
    let offset: number = 0;
    const storageId: number = view.getUint32(offset, true); offset += 4;
    offset += 2;                                             // StorageType
    offset += 2;                                             // FilesystemType
    const access: number = view.getUint16(offset, true); offset += 2;
    const capacity: number = Number(view.getBigUint64(offset, true)); offset += 8;
    const free: number = Number(view.getBigUint64(offset, true));
    return { storageId: storageId, access: access, capacity: capacity, free: free };
  }

  private static parseUint32List(data: Uint8Array): number[] {
    const values: number[] = [];
    if (data.byteLength < 4) return values;
    const view: DataView = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const count: number = view.getUint32(0, true);
    const limit: number = Math.min(count, Math.floor((data.byteLength - 4) / 4));
    for (let i = 0; i < limit; i++) values.push(view.getUint32(4 + i * 4, true));
    return values;
  }

  private static async readPropertyNumber(propCode: number): Promise<number> {
    try {
      const reply = await CanonPtpIp.opIn(0x1015, [propCode], PTP_TIMEOUT_MS);
      if (reply.data.byteLength >= 4) {
        return new DataView(reply.data.buffer, reply.data.byteOffset, reply.data.byteLength)
          .getUint32(0, true);
      }
      if (reply.data.byteLength >= 2) {
        return new DataView(reply.data.buffer, reply.data.byteOffset, reply.data.byteLength)
          .getUint16(0, true);
      }
    } catch (_error) {
      // 属性不支持时返回 0，由调用方判断。
    }
    return 0;
  }

  private static async readPropertyString(propCode: number): Promise<string> {
    try {
      const reply = await CanonPtpIp.opIn(0x1015, [propCode], PTP_TIMEOUT_MS);
      if (reply.data.byteLength === 0) return '';
      let end: number = reply.data.byteLength;
      for (let i = 0; i < reply.data.byteLength; i++) {
        if (reply.data[i] === 0) { end = i; break; }
      }
      return CanonFirmwareService.utf8(reply.data.subarray(0, end));
    } catch (_error) {
      return '';
    }
  }

  private static async currentVersion(): Promise<string> {
    if (!CanonPtpIp.isOpen()) return '';
    return CanonFirmwareService.readPropertyString(7);
  }

  private static async httpText(url: string): Promise<string> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING,
        maxRedirects: 5,
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        CanonFirmwareService.log(`GET ${url} http=${response.responseCode}`);
        return '';
      }
      return typeof response.result === 'string' ? response.result : '';
    } catch (error) {
      CanonFirmwareService.log(`GET ${url} 失败: ${(error as Error).message}`);
      return '';
    } finally {
      client.destroy();
    }
  }

  private static parseCatalog(body: string): CanonCatalogItem[] {
    const items: CanonCatalogItem[] = [];
    const itemPattern: RegExp = /<item\b([^>]*)>([\s\S]*?)<\/item>/g;
    let match: RegExpExecArray | null = itemPattern.exec(body);
    while (match !== null) {
      const attrs: string = match[1];
      const inner: string = match[2];
      const idMatch: RegExpExecArray | null = /id\s*=\s*"([^"]+)"/.exec(attrs);
      const versionMatch: RegExpExecArray | null = /version\s*=\s*"([^"]+)"/.exec(attrs);
      const urlMatch: RegExpExecArray | null = /<url>\s*([^<]+?)\s*<\/url>/.exec(inner);
      if (idMatch !== null && versionMatch !== null && urlMatch !== null) {
        items.push({ idHex: idMatch[1], version: versionMatch[1], url: urlMatch[1] });
      }
      match = itemPattern.exec(body);
    }
    return items;
  }

  private static parseDetail(body: string): CanonFirmwarePageDetail {
    const firmware: string = CanonFirmwareService.tagText(body, 'firmware');
    const sizeText: string = CanonFirmwareService.tagText(body, 'filesize');
    const size: number = sizeText.length > 0 ? Number(sizeText) : 0;
    return {
      firmware: firmware,
      fileSize: Number.isFinite(size) ? size : 0,
      changes: CanonFirmwareService.tagText(body, 'changes'),
      eula: CanonFirmwareService.tagText(body, 'eula'),
    };
  }

  private static tagText(body: string, tag: string): string {
    const pattern: RegExp = new RegExp(`<${tag}\\s*>([\\s\\S]*?)<\\/${tag}>`);
    const match: RegExpExecArray | null = pattern.exec(body);
    return match === null ? '' : match[1].trim();
  }

  /** 报告 04 §4：三段 parseInt，严格大于。 */
  static isNewer(candidate: string, current: string): boolean {
    if (current.length === 0) return true;
    const a: number[] = CanonFirmwareService.versionParts(candidate);
    const b: number[] = CanonFirmwareService.versionParts(current);
    if (a.length < 3 || b.length < 3) return false;
    if (a[0] !== b[0]) return a[0] > b[0];
    if (a[1] !== b[1]) return a[1] > b[1];
    return a[2] > b[2];
  }

  private static versionParts(version: string): number[] {
    const parts: string[] = version.split('.');
    const values: number[] = [];
    for (let i = 0; i < 3; i++) {
      const raw: string = i < parts.length ? parts[i].trim() : '0';
      const value: number = parseInt(raw, 10);
      values.push(Number.isFinite(value) ? value : 0);
    }
    return values;
  }

  /** 报告 04 §5.1：6 段取前 3/后 3；前 3 为 0.0.0 时用后 3。 */
  private static normalizeFirVersion(raw: string): string {
    const text: string = raw.trim().replace(/\u0000/g, '');
    if (text.length === 0) return '';
    const parts: string[] = text.split('.');
    if (parts.length === 6) {
      const front: string = parts.slice(0, 3).join('.');
      return front === '0.0.0' ? parts.slice(3, 6).join('.') : front;
    }
    if (parts.length >= 3) return parts.slice(0, 3).join('.');
    return text;
  }

  private static hexToNumber(hex: string): number {
    const value: number = parseInt(hex, 16);
    return Number.isFinite(value) ? value : -1;
  }

  private static fileNameOf(url: string, fallbackVersion: string): string {
    const withoutQuery: string = url.split('?')[0];
    const slash: number = withoutQuery.lastIndexOf('/');
    const raw: string = slash >= 0 ? withoutQuery.substring(slash + 1) : withoutQuery;
    let name: string = '';
    try {
      name = decodeURIComponent(raw);
    } catch (_error) {
      name = raw;
    }
    if (name.length === 0) name = `EOS_${fallbackVersion}.FIR`;
    return name;
  }

  private static baseName(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  private static readFileBytes(path: string, size: number): Uint8Array {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer);
      if (read !== size) {
        return new Uint8Array(buffer.slice(0, read));
      }
      return new Uint8Array(buffer);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static asciiZ(text: string): Uint8Array {
    const bytes: Uint8Array = new Uint8Array(text.length + 1);
    for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xFF;
    bytes[text.length] = 0;
    return bytes;
  }

  private static ptpDate(date: Date): string {
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}` +
      `T${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
  }

  private static utf8(bytes: Uint8Array): string {
    let out: string = '';
    let i: number = 0;
    while (i < bytes.length) {
      const byte: number = bytes[i];
      if (byte < 0x80) { out += String.fromCharCode(byte); i += 1; continue; }
      if (byte >= 0xC0 && byte < 0xE0 && i + 1 < bytes.length) {
        out += String.fromCharCode(((byte & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
        i += 2; continue;
      }
      if (byte >= 0xE0 && byte < 0xF0 && i + 2 < bytes.length) {
        out += String.fromCharCode(((byte & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) |
          (bytes[i + 2] & 0x3F));
        i += 3; continue;
      }
      out += String.fromCharCode(byte);
      i += 1;
    }
    return out;
  }
}
