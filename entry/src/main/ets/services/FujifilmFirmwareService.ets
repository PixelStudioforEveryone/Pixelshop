/**
 * FUJIFILM 固件更新（检查 → 下载 → 推送）。
 *
 * 唯一事实来源：`Fujifilm\apk\reports\04_固件更新协议.md`（下称 04）、
 * `01_首次配对_蓝牙配对与WiFi凭据.md`（下称 01）、`data\firmware_*.{json,tsv,txt}`。
 * 协议常量一律取自 `FujifilmProtocol.ets`（FujifilmFirmware / FujifilmOp / …）；
 * 报告里有、常量文件里缺的 3 个值集中在 `FujifilmFirmwareCode` 里并注明待并入
 * （见 `docs/fujifilm/NOTES_D.md` §6）。
 *
 * 链路（04 §4.2 S01–S38）：
 *   S01  GET https://privacy.xapp.net/camera_fw/camera_fw_info.json（无鉴权/无参数）
 *   S04  按 ProductName 匹配机型（本实现用 FujifilmModels.normalize 归一化）
 *   S06  BLE 0x2A26 读机身版本串（SDK: FujifilmBleService.readFirmwareVersion）
 *        PTP 0xD22F 读相机内固件文件名（固件模式内可达，含版本×100）
 *   S17  GET <URL> 拉 .DAT（15 s connect/read，无续传：先删后写）
 *   S21  整文件 SHA-256 与 JSON.Sha256 比对，不等即删
 *   S23  BLE 写 B1307521 92 B（type=5 CameraBodyXapp / type=6 CameraBodyMediafile）
 *   S25  TCP 192.168.0.1:55740（由 FujifilmPtpIp 负责）
 *   S26  SetFunctionMode(19 = FIRMWARE_DATA_TRANSFER)
 *   S28  GetFunctionVersion(0xDF27) → S29 v>1 即 VersionError（App 太旧）
 *   S30  SetFunctionVersion(0xDF27, ≤6 次重试)
 *   S32  FmSendObjectInfo(0x9040, "FUP_FILE.DAT", size)
 *   S33  首块 1 MiB FmSendPartialObject(0x9042)
 *   S34  相机 event 49 逐块索要下一块（单块等 5 s）
 *   S36  event 50 结束（arg1=1 表示已取消）
 *   S37  Close() 会话；S38 相机自行断电重启
 *
 * 硬边界（04 §5.12 / §7.2）：
 *  - **不发断电命令**（全 App 无 DEVICE_PROP_POWER_OFF_VALUE）；native 的
 *    `0xD17B` / `XSDK_PowerOFF(0x1023)` 只在这里记日志，不作为请求发出。
 *  - **不做回滚、不做自动重试**：失败只关会话 + 删下载文件 + 返回错误码。
 *  - 相机侧准入（电量/镜头/配件/版本）由相机判定，结果经 BLE `049EC406` 回传；
 *    本实现把常见的准入码映射成中文说明（`describeCameraState`）。
 *
 * 依赖角色 A 的公共底座（ROUTE_SPEC §2）：`FujifilmPtpIp`、`FujifilmBleService`。
 * 其中 BLE 92 B 请求的写入（B1307521）与 29 B 待升级文件信息读取（20EA1FAC）
 * 不在 A 的契约里，通过 `FujifilmFirmwareBlePort` 注入（不注入即按"老机型、
 * 走通道 B"处理，见 04 §2.3）。
 */

import { http } from '@kit.NetworkKit';
import { fileIo, statfs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import wifiManager from '@ohos.wifiManager';
import {
  FujifilmBleIds, FujifilmBytes, FujifilmEvent, FujifilmFirmware, FujifilmMode, FujifilmNet,
  FujifilmOp, FujifilmProp, FujifilmResponse,
} from './FujifilmProtocol';
import { FujifilmBleService, FujifilmIdentity, FujifilmWifiCredential } from './FujifilmBleService';
import { FujifilmPtpIp, FujifilmEventFrame, FujifilmReply } from './FujifilmPtpIp';
import { FujifilmModels } from './FujifilmModels';
import { AppLogStore } from '../pages/home/HomeShared';

/** 04 §5.10：前台下载 connect/read 都是 15 s。 */
const DOWNLOAD_CONNECT_TIMEOUT_MS: number = 15000;
const DOWNLOAD_READ_TIMEOUT_MS: number = 15000;
/** 整包下载的总闸（15 s 读超时之上再给一个上限，避免静默卡死页面）。 */
const DOWNLOAD_TOTAL_TIMEOUT_MS: number = 15 * 60 * 1000;
/** 04 §2.2 / §7.2 #10：磁盘门禁硬编码 100 MiB（不看固件大小）。 */
const FREE_SPACE_LIMIT: number = 104857600;
/** 04 §5.10：BLE 等待连接/AP 就绪 60 s（FWUpdateViewModel.java:1036）。 */
const AP_READY_TIMEOUT_MS: number = 60000;
/** WiFi 关联等待上限。 */
const WIFI_JOIN_TIMEOUT_MS: number = 40000;
/** 04 §5.10：SetFunctionMode / SetFunctionVersion 的重试间隔 100 ms。 */
const RETRY_INTERVAL_MS: number = 100;
/** 04 §5.10：自动升级单块等待 60 s（AutoFWUpModel.java:268）；这里只用于收尾等 event 50。 */
const SEND_COMPLETE_TIMEOUT_MS: number = 60000;
/** 事件轮询步长（PTP-IP 事件回调 → 本地队列）。 */
const EVENT_POLL_MS: number = 50;

/** 本地错误对象形状（HarmonyOS 的 BusinessError 也满足它）。 */
interface ErrorWithCode {
  code?: number | string;
  message?: string;
}

/** 04 §5.1：camera_fw_info.json 的 8 个字段（实测全集）。 */
interface RawCameraFwInfo {
  ProductName?: string;
  FileName?: string;
  FWVersion?: number;
  FileSize?: number;
  Sha256?: string;
  URL?: string;
  UpdateInfo_EN?: string;
  UpdateInfo_JA?: string;
}

/**
 * 待并入 `FujifilmProtocol.ets` 的 3 个常量（ROUTE_SPEC 铁律 3：先在 NOTES 记录）。
 *  - 0xD22F 设备属性：04 §5.5 `FPCSH_CURRENT_BODY_FIRMWARE_FILENAME`；
 *  - 5 / 6 BLE 请求 type：04 §5.8 `FirmwareType.CameraBodyXapp / CameraBodyMediafile`。
 */
export class FujifilmFirmwareCode {
  /** 相机内当前机身固件文件名（含版本×100 与分块序号）。 */
  static readonly PROP_CURRENT_BODY_FIRMWARE_FILENAME: number = 0xD22F;
  /** FirmwareType：前台主流程（App 下载 + App 推流）。 */
  static readonly TYPE_CAMERA_BODY_XAPP: number = 5;
  /** FirmwareType：新机型通道（相机自理）。 */
  static readonly TYPE_CAMERA_BODY_MEDIAFILE: number = 6;
  /** SDK_EVENTTYPE_CAMERA_DISCONNECT：升级中收到即异常（04 §5.6）。 */
  static readonly EVENT_CAMERA_DISCONNECT: number = 7;
}

/** 云端一条固件记录（04 §5.1）。 */
export interface FujifilmFirmwareEntry {
  /** 云端 ProductName（"X-T5"、"GFX 100"，唯一匹配键）。 */
  productName: string;
  /** 服务器文件名（FWUP0030.DAT / FPUPDATE.DAT）。 */
  fileName: string;
  /** 展示/下发用版本串（"4.31"）。 */
  version: string;
  /** 数值版本（4.31），比较与 ×100 换算用。 */
  versionValue: number;
  /** 字节数。 */
  fileSize: number;
  /** 整文件 SHA-256（小写 hex，可能为空）。 */
  sha256: string;
  /** 下载直链（dl.fujifilm-x.com 或 CloudFront）。 */
  url: string;
  /** 英文更新说明（04 §5.1：只有 EN/JA，其它语言回退 EN）。 */
  updateInfoEn: string;
  updateInfoJa: string;
}

/** 检查更新的结果（任务约定结构 + 页面需要的机型/追踪）。 */
export interface FujifilmFirmwareCheck {
  /** 云端清单里是否有该机型。 */
  supported: boolean;
  /** 相机侧当前版本；读不到时为空串。 */
  currentVersion: string;
  /** 云端最新一条；没有该机型时为 null。 */
  latest: FujifilmFirmwareEntry | null;
  /** 云端版本 > 相机版本。 */
  updateAvailable: boolean;
  /** 给用户看的一句话结论 / 失败原因。 */
  notes: string;
  /** 参与匹配的相机机型名（BLE 身份优先，其次页面给的提示）。 */
  modelName: string;
  /** 关键步骤追踪（页面不显示，排查用）。 */
  trace: string[];
}

export type FujifilmFirmwareStage =
  | 'idle' | 'check' | 'catalog' | 'download' | 'ble' | 'wifi' | 'ptp'
  | 'transfer' | 'waiting' | 'done' | 'failed' | 'cancelled';

export interface FujifilmFirmwareResult {
  ok: boolean;
  cancelled: boolean;
  stage: FujifilmFirmwareStage;
  message: string;
  /** 相机侧 FirmwareUpdateState 或 PTP 响应码 / SDK 错误码；0 = 无错误。 */
  code: number;
  trace: string[];
}

/** 04 §5.4.2：BLE 20EA1FAC 的 29 B 待升级文件信息。 */
export interface FujifilmFwFileInfo {
  productName: string;
  /** 原始 ASCII 版本串（×100，如 "431"）。 */
  versionRaw: string;
  /** 数值版本（4.31）。 */
  versionValue: number;
  totalNo: number;
  seqNo: number;
  availability: boolean;
}

/**
 * BLE 固件通道端口：由角色 A 注入（A 的 `FujifilmBleService` 拥有 GATT 会话）。
 *
 * 两个动作都属于"写/读某个私有特征"，不在 ROUTE_SPEC §2.2 的契约里，
 * 因此不硬编码到 A 的类上，而是在这里留一个明确的注入点：
 *   - `writeRequest`：写 `B1307521` 92 B（04 §5.4.3）；
 *   - `readFileInformation`：读 `20EA1FAC` 29 B（04 §5.4.2），老机型不支持时返回 null。
 */
export interface FujifilmFirmwareBlePort {
  writeRequest(payload: Uint8Array): Promise<boolean>;
  readFileInformation(): Promise<Uint8Array | null>;
}

/** 版本号拆分结果（`compareVersions` 用，十进制语义）。 */
interface FujifilmVersionParts {
  valid: boolean;
  integerPart: string;
  fraction: string;
}

export class FujifilmFirmwareService {
  private static blePort: FujifilmFirmwareBlePort | null = null;

  private static cancelRequested: boolean = false;
  private static busy: boolean = false;
  /** 事件 49/50 队列（相机随时可能推，先入队再由传输循环取）。 */
  private static pendingEvents: FujifilmEventFrame[] = [];
  private static disconnectSeen: boolean = false;
  private static eventRegistered: boolean = false;
  private static ptpOpened: boolean = false;
  /** 最近一次检查结果（页面返回再进来时可直接展示）。 */
  private static lastCheck: FujifilmFirmwareCheck | null = null;

  // -------------------------------------------------------------------------
  // 注入 / 状态
  // -------------------------------------------------------------------------

  /** 注入 BLE 私有特征通道（A 实现）；传 null 撤销。 */
  static setBlePort(port: FujifilmFirmwareBlePort | null): void {
    FujifilmFirmwareService.blePort = port;
  }

  static isBusy(): boolean {
    return FujifilmFirmwareService.busy;
  }

  static lastResult(): FujifilmFirmwareCheck | null {
    return FujifilmFirmwareService.lastCheck;
  }

  /** 取消：只置标记，传输循环在下一个检查点退出（不保证相机侧回滚，04 §5.12）。 */
  static cancel(): void {
    if (!FujifilmFirmwareService.busy) return;
    FujifilmFirmwareService.cancelRequested = true;
    FujifilmFirmwareService.log('用户取消固件更新');
  }

  // -------------------------------------------------------------------------
  // 检查更新（无需相机 WiFi，只需要手机联网 + 相机 BLE）
  // -------------------------------------------------------------------------

  /**
   * 检查更新。
   *
   * @param context    应用上下文（算下载目录与剩余空间）
   * @param modelHint  页面已知的机型名（BLE 读不到身份时的兜底）
   * @param onProgress (阶段文案, 百分比)；百分比 < 0 表示该阶段没有有意义进度
   */
  static async check(context: common.UIAbilityContext, modelHint: string,
    onProgress?: (status: string, percent: number) => void): Promise<FujifilmFirmwareCheck> {
    const report = (status: string, percent: number): void => {
      if (onProgress !== undefined) onProgress(status, percent);
    };
    const trace: string[] = [];
    report('正在读取相机固件版本…', -1);

    // ① 机型 + 当前版本：BLE 0x2A26（01 §8 / 04 §5.4.1）。
    let model: string = modelHint.trim();
    let current: string = '';
    try {
      const identity: FujifilmIdentity = await FujifilmBleService.readIdentity();
      if (identity.model.length > 0) model = identity.model;
      if (identity.firmware.length > 0) current = identity.firmware;
      trace.push(`BLE 身份 model=${model} fw=${current}`);
    } catch (error) {
      trace.push(`BLE 身份读取失败 code=${FujifilmFirmwareService.errorCode(error)}`);
    }
    if (current.length === 0) {
      try {
        const version: string = await FujifilmBleService.readFirmwareVersion();
        if (version.length > 0) current = version;
        trace.push(`BLE 0x2A26 version=${version}`);
      } catch (error) {
        trace.push(`BLE 0x2A26 读取失败 code=${FujifilmFirmwareService.errorCode(error)}`);
      }
    }

    // ② PTP 0xD22F：相机内当前固件文件名（04 §0.2 路径③ / §5.5）。
    //    只有已进固件传输模式（或已连 PTP-IP）时才可达，读不到不算错误。
    const ptpVersion: string = await FujifilmFirmwareService.readPtpFirmwareVersion(trace);
    if (current.length === 0 && ptpVersion.length > 0) {
      current = ptpVersion;
      trace.push(`PTP 0xD22F 版本=${ptpVersion}`);
    }

    // ③ 元数据 JSON（04 §0.1：唯一入口，无鉴权/无参数）。
    report('正在获取云端固件清单…', -1);
    const entries: FujifilmFirmwareEntry[] = await FujifilmFirmwareService.fetchCatalog(trace);
    if (entries.length === 0) {
      const failed: FujifilmFirmwareCheck = {
        supported: false, currentVersion: current, latest: null, updateAvailable: false,
        notes: '无法获取固件清单（请确认手机已联网；连着相机热点时没有外网）',
        modelName: model, trace: trace,
      };
      FujifilmFirmwareService.lastCheck = failed;
      FujifilmFirmwareService.log(`检查失败：清单为空 trace=${trace.join(' | ')}`);
      return failed;
    }
    trace.push(`云端清单 ${entries.length} 条`);

    // ④ 机型匹配（04 §2.1：ProductName 全等；这里用归一化以兼容 "GFX 100"/"GFX100"）。
    const matched: FujifilmFirmwareEntry | null =
      FujifilmFirmwareService.matchEntry(entries, model);
    if (matched === null) {
      const unsupported: FujifilmFirmwareCheck = {
        supported: false, currentVersion: current, latest: null, updateAvailable: false,
        notes: `云端清单里没有机型「${model.length > 0 ? model : '未知'}」的固件（实测只覆盖 30 款机身）`,
        modelName: model, trace: trace,
      };
      FujifilmFirmwareService.lastCheck = unsupported;
      FujifilmFirmwareService.log(`检查：机型未收录 model=${model}`);
      return unsupported;
    }

    // ⑤ 版本比较（按段数值，见 compareVersions）。
    const newer: boolean = current.length > 0 &&
      FujifilmFirmwareService.compareVersions(matched.version, current) > 0;
    let notes: string = '';
    if (current.length === 0) {
      notes = `云端最新 ${matched.version}，但没读到相机当前版本（请先连上相机蓝牙）`;
    } else if (newer) {
      notes = `发现新固件：${current} → ${matched.version}（${FujifilmFirmwareService.sizeText(matched.fileSize)}）`;
    } else {
      notes = `已是最新版本（相机 ${current}，云端 ${matched.version}）`;
    }
    const result: FujifilmFirmwareCheck = {
      supported: true, currentVersion: current, latest: matched,
      updateAvailable: newer, notes: notes, modelName: model, trace: trace,
    };
    FujifilmFirmwareService.lastCheck = result;
    FujifilmFirmwareService.log(
      `检查完成 model=${model} current=${current} latest=${matched.version} update=${newer}`);
    return result;
  }

  /** 拉清单。04 §0.1：裸 GET，无 header / 无参数 / 无鉴权。 */
  static async fetchCatalog(trace: string[]): Promise<FujifilmFirmwareEntry[]> {
    const url: string = FujifilmFirmware.METADATA_URL;
    for (let attempt = 1; attempt <= 2; attempt++) {
      const client = http.createHttp();
      try {
        const response = await client.request(url, {
          method: http.RequestMethod.GET,
          connectTimeout: DOWNLOAD_CONNECT_TIMEOUT_MS,
          readTimeout: DOWNLOAD_READ_TIMEOUT_MS,
          expectDataType: http.HttpDataType.STRING,
          maxRedirects: 3,
        });
        const body: string = typeof response.result === 'string' ? response.result : '';
        trace.push(`GET camera_fw_info.json #${attempt} http=${response.responseCode} bytes=${body.length}`);
        if (response.responseCode >= 200 && response.responseCode < 300 && body.length > 0) {
          return FujifilmFirmwareService.parseCatalog(body, trace);
        }
      } catch (error) {
        trace.push(`GET camera_fw_info.json #${attempt} error code=${FujifilmFirmwareService.errorCode(error)}`);
      } finally {
        client.destroy();
      }
      if (attempt < 2) await FujifilmFirmwareService.delay(400 * attempt);
    }
    return [];
  }

  /** 解析 30 条数组（04 §5.1）。字段缺失/类型不对的行直接跳过，不猜。 */
  static parseCatalog(body: string, trace: string[]): FujifilmFirmwareEntry[] {
    let rows: RawCameraFwInfo[] = [];
    try {
      rows = JSON.parse(body) as RawCameraFwInfo[];
    } catch (error) {
      trace.push(`JSON 解析失败 code=${FujifilmFirmwareService.errorCode(error)}`);
      return [];
    }
    if (!Array.isArray(rows)) {
      trace.push('JSON 顶层不是数组');
      return [];
    }
    const entries: FujifilmFirmwareEntry[] = [];
    for (const row of rows) {
      const name: string = row.ProductName !== undefined ? row.ProductName : '';
      const fileName: string = row.FileName !== undefined ? row.FileName : '';
      const url: string = row.URL !== undefined ? row.URL : '';
      const value: number = row.FWVersion !== undefined ? Number(row.FWVersion) : Number.NaN;
      if (name.length === 0 || url.length === 0 || !Number.isFinite(value) || value <= 0) continue;
      entries.push({
        productName: name,
        fileName: fileName,
        version: FujifilmFirmwareService.formatVersion(value),
        versionValue: value,
        fileSize: row.FileSize !== undefined ? Number(row.FileSize) : 0,
        sha256: row.Sha256 !== undefined ? String(row.Sha256).toLowerCase() : '',
        url: url,
        updateInfoEn: row.UpdateInfo_EN !== undefined ? row.UpdateInfo_EN : '',
        updateInfoJa: row.UpdateInfo_JA !== undefined ? row.UpdateInfo_JA : '',
      });
    }
    return entries;
  }

  /**
   * ProductName 匹配。
   *
   * 04 §2.1 官方是严格 `equals`；这里多一层归一化以吸收 `GFX 100` / `GFX100`
   * 的空格差异，并额外试一次 `FujifilmModels.displayNameOf()`（去掉 BLE 名里的
   * 厂商前缀与尾部短序列号）。包含匹配**只有唯一命中才采用**，
   * 否则 `X-T5` 会同时命中 `X-T5` 与 `X-T50`。
   */
  static matchEntry(entries: FujifilmFirmwareEntry[], model: string): FujifilmFirmwareEntry | null {
    const keys: string[] = [];
    const rawKey: string = FujifilmModels.normalize(model);
    if (rawKey.length > 0) keys.push(rawKey);
    const canonicalKey: string = FujifilmModels.normalize(FujifilmModels.displayNameOf(model));
    if (canonicalKey.length > 0 && keys.indexOf(canonicalKey) < 0) keys.push(canonicalKey);
    if (keys.length === 0) return null;
    for (const key of keys) {
      for (const entry of entries) {
        if (FujifilmModels.normalize(entry.productName) === key) return entry;
      }
    }
    for (const key of keys) {
      let candidate: FujifilmFirmwareEntry | null = null;
      let ambiguous = false;
      for (const entry of entries) {
        const entryKey: string = FujifilmModels.normalize(entry.productName);
        if (entryKey.length === 0) continue;
        if (entryKey.indexOf(key) >= 0 || key.indexOf(entryKey) >= 0) {
          if (candidate !== null) {
            ambiguous = true;
            break;
          }
          candidate = entry;
        }
      }
      if (candidate !== null && !ambiguous) return candidate;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // 版本比较（04 §5.9 的坑都在这一个函数里）
  // -------------------------------------------------------------------------

  /**
   * 十进制比较：左 > 右返回 1，相等 0，左 < 右 -1。
   *
   * 对齐官方用 `BigDecimal` 做十进制版本比较的语义（04 §5.9）：
   *   - `"4.9" > "4.31"`（字典序会判反，所以不能按字符串比）；
   *   - `"4.30" == "4.3"`（小数段尾部 0 不改变数值）；
   *   - `"1.12" < "1.2"`（0.12 < 0.20，小数段要右对齐补 0 再比）。
   * ArkTS 没有 BigDecimal，这里用「整数部分按数值、小数部分右补 0 后逐位比」等价实现，
   * 不引入浮点误差，也不再有【已知偏差】。
   */
  static compareVersions(left: string, right: string): number {
    const a: FujifilmVersionParts = FujifilmFirmwareService.splitVersion(left);
    const b: FujifilmVersionParts = FujifilmFirmwareService.splitVersion(right);
    if (!a.valid || !b.valid) return 0;
    const intCmp: number = FujifilmFirmwareService.compareDigits(a.integerPart, b.integerPart);
    if (intCmp !== 0) return intCmp;
    const width: number = Math.max(a.fraction.length, b.fraction.length);
    let af: string = a.fraction;
    let bf: string = b.fraction;
    while (af.length < width) af += '0';
    while (bf.length < width) bf += '0';
    return FujifilmFirmwareService.compareDigits(af, bf);
  }

  /** 拆成整数部分与小数部分（纯数字串，去掉前导/尾随 0 由比较函数处理）。 */
  private static splitVersion(text: string): FujifilmVersionParts {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) return { valid: false, integerPart: '', fraction: '' };
    const dot: number = trimmed.indexOf('.');
    const head: string = dot >= 0 ? trimmed.substring(0, dot) : trimmed;
    const tail: string = dot >= 0 ? trimmed.substring(dot + 1) : '';
    const integerPart: string = head.replace(/[^0-9]/g, '');
    const fraction: string = tail.replace(/[^0-9]/g, '');
    if (integerPart.length === 0 && fraction.length === 0) {
      return { valid: false, integerPart: '', fraction: '' };
    }
    return { valid: true, integerPart: integerPart.length > 0 ? integerPart : '0', fraction: fraction };
  }

  /** 纯数字串的数值比较（长度优先，等长再逐位），避免 parseInt 溢出。 */
  private static compareDigits(left: string, right: string): number {
    let a: string = left;
    let b: string = right;
    while (a.length > 1 && a.charAt(0) === '0') a = a.substring(1);
    while (b.length > 1 && b.charAt(0) === '0') b = b.substring(1);
    if (a.length !== b.length) return a.length > b.length ? 1 : -1;
    if (a === b) return 0;
    return a > b ? 1 : -1;
  }

  /**
   * 版本号 → 下发/展示串，等价于 Java 的 `String.valueOf(double)`：
   * 4.31 → "4.31"、2.5 → "2.5"、2.0 → "2.0"（整数值补一位小数）。
   */
  static formatVersion(value: number): string {
    if (!Number.isFinite(value) || value <= 0) return '';
    const text: string = String(value);
    return text.indexOf('.') >= 0 ? text : text + '.0';
  }

  /** 从相机内固件文件名里取版本：`X-T5_0431_026_001.DAT` → "4.31"（04 §5.11）。 */
  static versionFromFirmwareFilename(fileName: string): string {
    if (fileName.length === 0) return '';
    const parts: string[] = fileName.split('_');
    if (parts.length >= 2) {
      const raw: string = parts[1].trim();
      if (/^[0-9]{3,4}$/.test(raw)) {
        return FujifilmFirmwareService.formatVersion(Number.parseInt(raw, 10) / 100);
      }
    }
    // 兜底：文件名里直接写 "4.31" 的形态。
    const match = /([0-9]+\.[0-9]+)/.exec(fileName);
    return match !== null ? match[1] : '';
  }

  // -------------------------------------------------------------------------
  // BLE 92 B 请求（04 §5.4.3）+ 29 B 文件信息（04 §5.4.2）
  // -------------------------------------------------------------------------

  /**
   * 构造 `B1307521` 的 92 字节请求。
   *
   * 偏移（合计 2+64+15+4+7 = 92）：
   *   0   2  type       u16 LE（5=CameraBodyXapp / 6=CameraBodyMediafile）
   *   2  64  productName UTF-8 原始字节，**无 NUL 填充**，超长截断
   *  66  15  fileName    UTF-8，超长截断
   *  81   4  fileSize    u32 LE
   *  85   7  version     ASCII（"4.31"）
   * 注意：`cameraID` **不参与序列化**（04 §3.3），productName 超 64 B 会覆盖 fileName 区
   * （官方无校验），这里提前截断避免踩坏后面的字段。
   */
  static buildBleRequest(channelType: number, productName: string, fileName: string,
    fileSize: number, version: string): Uint8Array {
    const out = new Uint8Array(FujifilmFirmware.BLE_REQUEST_BYTES);
    out[0] = channelType & 0xFF;
    out[1] = (channelType >>> 8) & 0xFF;
    const nameBytes = FujifilmFirmwareService.truncateBytes(
      util.TextEncoder.create('utf-8').encode(productName), FujifilmFirmware.BLE_NAME_FIELD);
    out.set(nameBytes, 2);
    const fileBytes = FujifilmFirmwareService.truncateBytes(
      util.TextEncoder.create('utf-8').encode(fileName), FujifilmFirmware.BLE_FILE_FIELD);
    out.set(fileBytes, 2 + FujifilmFirmware.BLE_NAME_FIELD);
    out.set(FujifilmBytes.u32(fileSize), 2 + FujifilmFirmware.BLE_NAME_FIELD + FujifilmFirmware.BLE_FILE_FIELD);
    const versionBytes = FujifilmFirmwareService.truncateBytes(
      util.TextEncoder.create('utf-8').encode(version), FujifilmFirmware.BLE_VERSION_FIELD);
    out.set(versionBytes,
      2 + FujifilmFirmware.BLE_NAME_FIELD + FujifilmFirmware.BLE_FILE_FIELD + 4);
    return out;
  }

  private static truncateBytes(source: Uint8Array, limit: number): Uint8Array {
    if (source.length <= limit) return source;
    return source.slice(0, limit);
  }

  /** 92 B 里的 fileSize 以落盘文件为准：清单缺 FileSize 时不能下发 0。 */
  private static actualSizeOf(path: string, declared: number): number {
    try {
      const stat = fileIo.statSync(path);
      if (stat.size > 0) return stat.size;
    } catch (_error) {
      // 落到清单值
    }
    return declared;
  }

  /** 解析 20EA1FAC 的 29 B（04 §5.4.2）。长度不足返回 null。 */
  static parseFwFileInformation(data: Uint8Array): FujifilmFwFileInfo | null {
    if (data.length < 29) return null;
    let name = '';
    for (let index = 0; index < 20; index++) {
      const byte: number = data[index];
      if (byte === 0) break;
      name += String.fromCharCode(byte);
    }
    let versionRaw = '';
    for (let index = 20; index < 24; index++) {
      const byte: number = data[index];
      if (byte === 0) break;
      versionRaw += String.fromCharCode(byte);
    }
    const parsed: number = Number.parseInt(versionRaw.replace(/[^0-9]/g, ''), 10);
    return {
      productName: name.trim(),
      versionRaw: versionRaw,
      versionValue: Number.isNaN(parsed) ? 0 : parsed / 100,
      totalNo: FujifilmBytes.readU16(data, 24),
      seqNo: FujifilmBytes.readU16(data, 26),
      availability: data[28] === 1,
    };
  }

  /**
   * 通道判定（04 §2.3）：
   *   availability==1 且 相机版本×100 >= 目标×100 → type=6（相机自理）
   *   否则（含老机型读不到 20EA1FAC） → type=5（App 推流，主流程）
   */
  static transferTypeFor(info: FujifilmFwFileInfo | null, targetVersion: string): number {
    if (info === null || !info.availability) return FujifilmFirmwareCode.TYPE_CAMERA_BODY_XAPP;
    // 用同一套按段比较，避免 ×100 的浮点误差（4.31*100 = 431.00000000000006）。
    const cameraVersion: string = FujifilmFirmwareService.formatVersion(info.versionValue);
    if (cameraVersion.length === 0) return FujifilmFirmwareCode.TYPE_CAMERA_BODY_XAPP;
    return FujifilmFirmwareService.compareVersions(cameraVersion, targetVersion) >= 0
      ? FujifilmFirmwareCode.TYPE_CAMERA_BODY_MEDIAFILE
      : FujifilmFirmwareCode.TYPE_CAMERA_BODY_XAPP;
  }

  // -------------------------------------------------------------------------
  // 更新主流程
  // -------------------------------------------------------------------------

  /**
   * 更新：下载 → 通知相机（BLE）→ 连相机 WiFi → PTP 推流 → 等相机写入。
   *
   * 顺序不能换：手机连着相机热点时**没有外网**（04 §2.2 "手机 Wi-Fi 已开" +
   * 01 §9.6 removeCapability(INTERNET)），所以下载必须在切 WiFi 之前完成。
   */
  static async update(context: common.UIAbilityContext, entry: FujifilmFirmwareEntry,
    cameraModelName: string,
    onProgress?: (status: string, percent: number) => void): Promise<FujifilmFirmwareResult> {
    const report = (status: string, percent: number): void => {
      if (onProgress !== undefined) onProgress(status, percent);
    };
    if (FujifilmFirmwareService.busy) {
      return FujifilmFirmwareService.result(false, false, 'failed', '已有固件更新在进行中', 0, []);
    }
    const trace: string[] = [];
    FujifilmFirmwareService.busy = true;
    FujifilmFirmwareService.cancelRequested = false;
    FujifilmFirmwareService.disconnectSeen = false;
    FujifilmFirmwareService.pendingEvents = [];
    FujifilmFirmwareService.log(`开始固件更新 model=${cameraModelName} file=${entry.fileName} ` +
      `version=${entry.version} bytes=${entry.fileSize}`);
    try {
      // ── P3 下载（04 §4.1 / S17–S21）───────────────────────────────────
      report('正在下载固件包…', 0);
      const path: string = await FujifilmFirmwareService.downloadPackage(
        context, entry, report, trace);
      if (path.length === 0) {
        return FujifilmFirmwareService.result(false, FujifilmFirmwareService.cancelRequested,
          'download', FujifilmFirmwareService.cancelRequested ? '已取消固件下载' : '固件下载失败（或校验不通过）',
          0, trace);
      }
      if (FujifilmFirmwareService.cancelRequested) {
        return FujifilmFirmwareService.result(false, true, 'cancelled', '已取消固件更新', 0, trace);
      }

      // ── S23 BLE 92 B 请求 + 拉起 AP ───────────────────────────────────
      report('正在通知相机进入固件更新模式…', -1);
      const fileInfo: FujifilmFwFileInfo | null =
        await FujifilmFirmwareService.readFileInformation(trace);
      const channelType: number = FujifilmFirmwareService.transferTypeFor(fileInfo, entry.version);
      trace.push(`传输通道 type=${channelType}${fileInfo !== null ?
        ` fileInfo(version=${fileInfo.versionValue} total=${fileInfo.totalNo} seq=${fileInfo.seqNo} available=${fileInfo.availability})` : ''}`);
      const payload: Uint8Array = FujifilmFirmwareService.buildBleRequest(
        channelType, cameraModelName.length > 0 ? cameraModelName : entry.productName,
        entry.fileName, FujifilmFirmwareService.actualSizeOf(path, entry.fileSize), entry.version);
      trace.push(`BLE 92B ${FujifilmBytes.hexBytes(payload, 24)}`);
      const wrote: boolean = await FujifilmFirmwareService.writeBleRequest(payload, trace);
      if (!wrote) {
        // 通道 B 的"开工信号"没发出去。仍然继续：launch(5) 也会把 AP 拉起来，
        // 相机若拒绝会在 SetFunctionMode / 0x9040 上明确回错。
        trace.push('BLE 92B 请求未发送（未注入 FujifilmFirmwareBlePort）');
      }
      try {
        // 01 §9.2：相机设置入口写 UpdateFirmware(5)，固件升级复用它拉起 AP。
        const launched: boolean = await FujifilmBleService.launch(
          FujifilmBleIds.LAUNCH_UPDATE_FIRMWARE);
        trace.push(`BLE launch(UpdateFirmware) = ${launched}`);
      } catch (error) {
        trace.push(`BLE launch 失败 code=${FujifilmFirmwareService.errorCode(error)}`);
      }
      report('等待相机热点就绪…', -1);
      let apReady = false;
      try {
        apReady = await FujifilmBleService.waitApReady(AP_READY_TIMEOUT_MS);
      } catch (error) {
        trace.push(`waitApReady 失败 code=${FujifilmFirmwareService.errorCode(error)}`);
      }
      trace.push(`AP_STATE launched=${apReady}`);
      if (!apReady) {
        // 不直接失败：有的机型 AP 早已起来（例如从相机设置页进来），
        // 后面 WiFi 关联成功即可继续。
        trace.push('未收到 AP_STATE=0x8001，继续尝试关联相机 WiFi');
      }
      if (FujifilmFirmwareService.cancelRequested) {
        return FujifilmFirmwareService.result(false, true, 'cancelled', '已取消固件更新', 0, trace);
      }

      // ── P4 连相机 WiFi（01 §8 / §9.4）─────────────────────────────────
      report('正在连接相机 WiFi…', -1);
      let credential: FujifilmWifiCredential = { ssid: '', passphrase: '' };
      try {
        credential = await FujifilmBleService.readWifiCredentials();
        trace.push(`WiFi 凭据 ssid=${credential.ssid.length > 0 ? credential.ssid : '空'}`);
      } catch (error) {
        // 01 §8.4：密码读失败官方直接断开 GATT；这里给出可读原因而不是通用异常。
        trace.push(`WiFi 凭据读取失败 code=${FujifilmFirmwareService.errorCode(error)}`);
        return FujifilmFirmwareService.result(false, false, 'wifi',
          '读不到相机 WiFi 凭据（蓝牙连接可能已断开，请回相机页重连）', 0, trace);
      }
      const joined: boolean = await FujifilmFirmwareService.joinCameraWifi(credential, trace);
      if (!joined) {
        return FujifilmFirmwareService.result(false, false, 'wifi',
          '无法连接相机 WiFi（请在系统弹窗里允许连接相机热点）', 0, trace);
      }

      // ── P5 PTP：进固件模式 + 推流（S25–S37）───────────────────────────
      report('正在建立相机连接…', -1);
      const connected: boolean = await FujifilmFirmwareService.openPtp(trace);
      if (!connected) {
        return FujifilmFirmwareService.result(false, false, 'ptp', '无法建立 PTP-IP 会话（55740）', 0, trace);
      }
      report('正在切换相机到固件传输模式…', -1);
      const modeResult: FujifilmFirmwareResult =
        await FujifilmFirmwareService.enterFirmwareMode(trace);
      if (!modeResult.ok) {
        FujifilmFirmwareService.log(`进固件模式失败 ${modeResult.message} code=${modeResult.code}`);
        return modeResult;
      }

      // 进模式后读一次相机内固件文件名（04 §5.5，自动升级的续传判定也用它）。
      const insideName: string = await FujifilmFirmwareService.readPtpFirmwareFilename(trace);
      if (insideName.length > 0) {
        trace.push(`相机内固件名=${insideName} 版本=${FujifilmFirmwareService.versionFromFirmwareFilename(insideName)}`);
      }

      report('正在向相机传输固件…', 0);
      const transferResult: FujifilmFirmwareResult =
        await FujifilmFirmwareService.transferFile(path, entry.fileSize, report, trace);
      if (!transferResult.ok) return transferResult;

      // ── P6 收尾（S37/S38）──────────────────────────────────────────────
      // 相机自行写入并重启。App 不发断电、不做回滚（04 §5.5 / §5.12）。
      report('传输完成，等待相机写入固件…', 100);
      FujifilmFirmwareService.log('固件传输完成；相机将自行写入并重启（App 不发送断电命令）');
      return FujifilmFirmwareService.result(true, false, 'done',
        '固件已全部发送。相机会自行写入并重启，完成后可在相机上确认版本', 0, trace);
    } catch (error) {
      const code: number = FujifilmFirmwareService.numericCode(error);
      trace.push(`更新异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      FujifilmFirmwareService.log(`固件更新异常 ${String(error)}`);
      return FujifilmFirmwareService.result(false, false, 'failed',
        `固件更新失败：${FujifilmFirmwareService.errorCode(error)}`, code, trace);
    } finally {
      FujifilmFirmwareService.finishTransfer();
      FujifilmFirmwareService.busy = false;
      FujifilmFirmwareService.log(`固件更新结束 trace=${trace.join(' | ')}`);
    }
  }

  // -------------------------------------------------------------------------
  // 下载 + 校验
  // -------------------------------------------------------------------------

  private static async downloadPackage(context: common.UIAbilityContext,
    entry: FujifilmFirmwareEntry,
    report: (status: string, percent: number) => void, trace: string[]): Promise<string> {
    const dir: string = `${context.filesDir}/fuji_firmware`;
    try {
      fileIo.mkdirSync(dir, true);
    } catch (_error) {
      // 已存在
    }
    const path: string = `${dir}/${FujifilmFirmwareService.safeFileName(entry.fileName)}`;

    // 04 §2.2：磁盘门禁硬编码 100 MiB（不看固件大小）。
    try {
      const free: number = await statfs.getFreeSize(context.filesDir);
      trace.push(`剩余空间=${free} 需要>=${FREE_SPACE_LIMIT}`);
      if (free > 0 && free < FREE_SPACE_LIMIT) {
        report('存储空间不足（至少需要 100 MB）', -1);
        return '';
      }
    } catch (error) {
      trace.push(`statfs 失败 code=${FujifilmFirmwareService.errorCode(error)}`);
    }

    // S16：本地已有完整文件（size 相同）直接复用，不重下。
    try {
      const stat = fileIo.statSync(path);
      if (stat.size === entry.fileSize && entry.fileSize > 0) {
        trace.push(`复用已下载文件 bytes=${stat.size}`);
        report('已存在完整固件包，跳过下载', 100);
        return path;
      }
    } catch (_error) {
      // 不存在
    }
    // S19：先删后写，**无断点续传**。
    try {
      fileIo.unlinkSync(path);
    } catch (_error) {
      // 本来就没有
    }

    const md = cryptoFramework.createMd('SHA256');
    let file: fileIo.File | null = null;
    let received = 0;
    let ended = false;
    const client = http.createHttp();
    try {
      const finished = new Promise<void>((resolve: () => void) => {
        client.on('dataReceive', (chunk: ArrayBuffer) => {
          try {
            if (file === null) {
              file = fileIo.openSync(path,
                fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
            }
            const view = new Uint8Array(chunk);
            fileIo.writeSync(file.fd, chunk);
            // 边下边算 SHA-256：110 MB 的包不再读第二遍。
            md.updateSync({ data: view });
            received += chunk.byteLength;
            if (entry.fileSize > 0) {
              const percent: number = Math.min(99, Math.floor(received * 100 / entry.fileSize));
              report(`正在下载固件包… ${percent}%`, percent);
            }
          } catch (error) {
            trace.push(`写盘失败 code=${FujifilmFirmwareService.errorCode(error)}`);
          }
        });
        client.on('dataEnd', () => {
          ended = true;
          resolve();
        });
      });
      const code: number = await client.requestInStream(entry.url, {
        method: http.RequestMethod.GET,
        // 04 §5.10：官方前台下载的 UA 是这一串（S3/CloudFront 不看，但保持一致）。
        header: { 'User-Agent': '13c00fcc 984546f2' },
        connectTimeout: DOWNLOAD_CONNECT_TIMEOUT_MS,
        readTimeout: DOWNLOAD_READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxRedirects: 3,
      });
      if (code < 200 || code >= 300) {
        trace.push(`固件下载 http=${code}`);
        FujifilmFirmwareService.unlinkQuietly(path);
        return '';
      }
      await Promise.race([
        finished,
        new Promise<void>((resolve: () => void) => {
          setTimeout(() => { resolve(); }, DOWNLOAD_TOTAL_TIMEOUT_MS);
        }),
      ]);
      if (!ended) trace.push(`下载未收到 dataEnd，已有 bytes=${received}`);
    } catch (error) {
      trace.push(`固件下载异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      FujifilmFirmwareService.unlinkQuietly(path);
      return '';
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_error) { }
        file = null;
      }
      client.destroy();
    }

    // S21：大小 + 整文件 SHA-256，任一不符即删（官方同样删文件）。
    if (received === 0) {
      trace.push('下载字节数为 0');
      FujifilmFirmwareService.unlinkQuietly(path);
      return '';
    }
    if (entry.fileSize > 0 && received !== entry.fileSize) {
      trace.push(`大小不符 got=${received} expect=${entry.fileSize}`);
      FujifilmFirmwareService.unlinkQuietly(path);
      return '';
    }
    if (entry.sha256.length > 0) {
      let digest = '';
      try {
        const result = md.digestSync();
        digest = FujifilmFirmwareService.toHex(result.data);
      } catch (error) {
        trace.push(`SHA-256 计算失败 code=${FujifilmFirmwareService.errorCode(error)}`);
      }
      if (digest.length > 0 && digest.toLowerCase() !== entry.sha256.toLowerCase()) {
        trace.push(`SHA-256 不符 got=${digest} expect=${entry.sha256}`);
        FujifilmFirmwareService.unlinkQuietly(path);
        return '';
      }
      trace.push(`SHA-256 ok ${digest}`);
    }
    report('固件包下载完成', 100);
    trace.push(`固件包落盘 ${path} bytes=${received}`);
    return path;
  }

  // -------------------------------------------------------------------------
  // BLE 请求 / 相机 WiFi
  // -------------------------------------------------------------------------

  private static async writeBleRequest(payload: Uint8Array, trace: string[]): Promise<boolean> {
    const port = FujifilmFirmwareService.blePort;
    if (port === null) return false;
    try {
      const ok: boolean = await port.writeRequest(payload);
      trace.push(`BLE 92B write=${ok}`);
      return ok;
    } catch (error) {
      trace.push(`BLE 92B 写入异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      return false;
    }
  }

  private static async readFileInformation(trace: string[]): Promise<FujifilmFwFileInfo | null> {
    const port = FujifilmFirmwareService.blePort;
    if (port === null) return null;
    try {
      const data: Uint8Array | null = await port.readFileInformation();
      if (data === null) {
        trace.push('20EA1FAC 不可用（老机型）');
        return null;
      }
      return FujifilmFirmwareService.parseFwFileInformation(data);
    } catch (error) {
      trace.push(`20EA1FAC 读取异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      return null;
    }
  }

  /**
   * 连相机 AP。01 §9.6：字面 SSID + BSSID + WPA2；相机热点没有外网，
   * 所以要保留系统"无互联网"确认框（showNoInternetDialog），让系统把这条
   * WiFi 当成活动路由。
   */
  private static async joinCameraWifi(credential: FujifilmWifiCredential,
    trace: string[]): Promise<boolean> {
    const target: string = FujifilmFirmwareService.normalizeSsid(credential.ssid);
    if (target.length === 0) {
      trace.push('WiFi 凭据为空，无法关联');
      return false;
    }
    try {
      if (!wifiManager.isWifiActive()) await wifiManager.enableWifi();
    } catch (error) {
      trace.push(`打开 WiFi 失败 code=${FujifilmFirmwareService.errorCode(error)}`);
    }
    const linkedNow: string = await FujifilmFirmwareService.linkedSsid();
    if (linkedNow === target) {
      trace.push(`已连接目标 WiFi ssid=${target}`);
      return true;
    }
    // 扫描拿 securityType/bssid；相机 AP 需要几十秒才出现在扫描表里。
    let scan: wifiManager.WifiScanInfo | undefined = undefined;
    for (let attempt = 0; attempt < 6 && scan === undefined; attempt++) {
      try {
        const list: wifiManager.WifiScanInfo[] = wifiManager.getScanInfoList();
        scan = list.find((item: wifiManager.WifiScanInfo): boolean =>
          FujifilmFirmwareService.normalizeSsid(item.ssid) === target);
      } catch (error) {
        trace.push(`扫描失败 code=${FujifilmFirmwareService.errorCode(error)}`);
      }
      if (scan === undefined) {
        try {
          wifiManager.startScan();
        } catch (_error) { }
        await FujifilmFirmwareService.delay(2000);
      }
    }
    const securityType: wifiManager.WifiSecurityType = scan !== undefined
      ? scan.securityType : wifiManager.WifiSecurityType.WIFI_SEC_TYPE_PSK;
    const bssid: string = scan !== undefined ? scan.bssid : '';
    trace.push(`WiFi 目标 ssid=${target} security=${securityType} found=${scan !== undefined}`);
    const config: wifiManager.WifiDeviceConfig = {
      ssid: target,
      // 01 §9.6：相机只支持 WPA2；开放网络必须留空密钥，否则 addCandidateConfig 抛 401。
      preSharedKey: securityType === wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN
        ? '' : credential.passphrase,
      securityType: securityType,
      showNoInternetDialog: true,
    };
    // 扫不到时不要塞空 BSSID（非法字段会被 addCandidateConfig 直接拒掉）。
    if (bssid.length > 0) config.bssid = bssid;
    let networkId: number = -1;
    try {
      networkId = await wifiManager.addCandidateConfig(config);
    } catch (error) {
      trace.push(`addCandidateConfig 异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      return false;
    }
    if (networkId < 0) {
      trace.push(`addCandidateConfig 被拒 code=${networkId}`);
      return false;
    }
    try {
      await wifiManager.connectToCandidateConfig({
        networkId: networkId,
        withUserAction: true,
        userActionTimeout: 30,
        addNetworkToSystem: true,
      });
      trace.push('WiFi 关联请求已发送（需用户在系统弹窗确认）');
    } catch (error) {
      trace.push(`WiFi 关联请求失败 code=${FujifilmFirmwareService.errorCode(error)}`);
      try {
        wifiManager.connectToCandidateConfig(networkId);
      } catch (_fallback) { }
    }
    const deadline: number = Date.now() + WIFI_JOIN_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (FujifilmFirmwareService.cancelRequested) return false;
      const linked: string = await FujifilmFirmwareService.linkedSsid();
      if (linked === target) {
        trace.push(`WiFi 已关联 ssid=${linked}`);
        return true;
      }
      await FujifilmFirmwareService.delay(700);
    }
    trace.push('WiFi 关联超时');
    return false;
  }

  private static async linkedSsid(): Promise<string> {
    try {
      const linked = await wifiManager.getLinkedInfo();
      return FujifilmFirmwareService.normalizeSsid(linked.ssid);
    } catch (_error) {
      return '';
    }
  }

  /** SSID 去引号/去空白（系统返回的 ssid 有时带引号）。 */
  private static normalizeSsid(value: string): string {
    return value.replace(/^"|"$/g, '').trim();
  }

  // -------------------------------------------------------------------------
  // PTP：会话、模式协商、推流
  // -------------------------------------------------------------------------

  private static async openPtp(trace: string[]): Promise<boolean> {
    try {
      await FujifilmPtpIp.connect();
      FujifilmFirmwareService.ptpOpened = true;
      FujifilmFirmwareService.registerEvents();
      trace.push('PTP-IP 会话已建立（55740）');
      return true;
    } catch (error) {
      trace.push(`PTP-IP 连接失败 code=${FujifilmFirmwareService.errorCode(error)}`);
      return false;
    }
  }

  /** 事件通道常驻监听（04 §5.6：49 索要下一块 / 50 发送结束）。 */
  private static registerEvents(): void {
    if (FujifilmFirmwareService.eventRegistered) return;
    try {
      FujifilmPtpIp.onEvent((frame: FujifilmEventFrame): void => {
        FujifilmFirmwareService.onPtpEvent(frame);
      });
      FujifilmFirmwareService.eventRegistered = true;
    } catch (error) {
      FujifilmFirmwareService.log(`事件订阅失败 ${String(error)}`);
    }
  }

  private static onPtpEvent(frame: FujifilmEventFrame): void {
    const code: number = frame.code;
    if (code === FujifilmEvent.FIRMWARE_PULL_CHUNK || code === FujifilmEvent.FIRMWARE_DONE) {
      FujifilmFirmwareService.pendingEvents.push(frame);
      if (FujifilmFirmwareService.pendingEvents.length > 32) {
        FujifilmFirmwareService.pendingEvents.shift();
      }
      return;
    }
    if (code === FujifilmFirmwareCode.EVENT_CAMERA_DISCONNECT) {
      // SDK_EVENTTYPE_CAMERA_DISCONNECT：升级中即异常（04 §5.6）。
      FujifilmFirmwareService.disconnectSeen = true;
    }
  }

  private static async waitEvent(timeoutMs: number): Promise<FujifilmEventFrame | null> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (FujifilmFirmwareService.pendingEvents.length > 0) {
        const frame = FujifilmFirmwareService.pendingEvents.shift();
        if (frame !== undefined) return frame;
      }
      if (FujifilmFirmwareService.disconnectSeen) return null;
      if (FujifilmFirmwareService.cancelRequested) return null;
      await FujifilmFirmwareService.delay(EVENT_POLL_MS);
    }
    return null;
  }

  /**
   * 进固件传输模式（S26–S30）。
   *
   * 【推断】`SetFunctionMode` / `SetFunctionVersion` 最终映射到哪个 PTP 操作码，
   * 04 §5.5 与 02 §8 都标为未知。这里按"SDK 内部用 0x5002 FunctionMode 承载
   * 功能模式、`0xFpcsh_Version*` 承载能力版本"的语义，落到标准属性读写：
   *   SetFunctionMode(n)      → SetDevicePropValue(0x5002, UINT16 n)
   *   GetFunctionVersion(p)   → GetDevicePropValue(p)（4 B，老机型 2 B）
   *   SetFunctionVersion(p,v) → SetDevicePropValue(p, UINT32 v)
   * 抓包一旦确认真实操作码，只需改这三个函数，传输循环不受影响。
   */
  private static async enterFirmwareMode(trace: string[]): Promise<FujifilmFirmwareResult> {
    const modeOk: boolean = await FujifilmFirmwareService.setFunctionMode(
      FujifilmMode.FIRMWARE_DATA_TRANSFER, trace);
    if (!modeOk) {
      return FujifilmFirmwareService.result(false, false, 'ptp',
        '相机拒绝进入固件传输模式（SetFunctionMode 0x13 失败）', 0, trace);
    }
    const cameraVersion: number = await FujifilmFirmwareService.getFunctionVersion(
      FujifilmMode.VERSION_FIRMWARE, trace);
    trace.push(`GetFunctionVersion(0xDF27)=${cameraVersion}`);
    // S29：相机版本高于 App 期望（1）说明相机比 App 新，官方判 VersionError。
    if (cameraVersion > FujifilmMode.MIN_VERSION_FIRMWARE) {
      return FujifilmFirmwareService.result(false, false, 'ptp',
        `相机固件传输版本（${cameraVersion}）高于本 App 支持的版本（${FujifilmMode.MIN_VERSION_FIRMWARE}）`,
        0, trace);
    }
    const targetVersion: number = cameraVersion > 0
      ? Math.min(cameraVersion, FujifilmMode.MIN_VERSION_FIRMWARE)
      : FujifilmMode.MIN_VERSION_FIRMWARE;
    const versionOk: boolean = await FujifilmFirmwareService.setFunctionVersion(
      FujifilmMode.VERSION_FIRMWARE, targetVersion, trace);
    if (!versionOk) {
      return FujifilmFirmwareService.result(false, false, 'ptp',
        '相机拒绝协商固件传输版本（SetFunctionVersion 0xDF27 失败）', 0, trace);
    }
    return FujifilmFirmwareService.result(true, false, 'ptp', '', 0, trace);
  }

  private static async setFunctionMode(mode: number, trace: string[]): Promise<boolean> {
    for (let attempt = 1; attempt <= FujifilmNet.FIRMWARE_RETRY; attempt++) {
      if (FujifilmFirmwareService.cancelRequested) return false;
      try {
        const reply: FujifilmReply = await FujifilmPtpIp.opDataOut(
          FujifilmOp.SET_DEVICE_PROP_VALUE, [FujifilmProp.FUNCTION_MODE],
          FujifilmBytes.u16(mode), FujifilmNet.TRANSACTION_TIMEOUT_MS);
        trace.push(`SetFunctionMode(${mode}) #${attempt} code=${FujifilmBytes.hex(reply.code)}`);
        if (reply.code === FujifilmResponse.OK) return true;
        if (!FujifilmFirmwareService.isRetryable(reply.code)) return false;
      } catch (error) {
        trace.push(`SetFunctionMode #${attempt} 异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      }
      await FujifilmFirmwareService.delay(RETRY_INTERVAL_MS);
    }
    return false;
  }

  private static async getFunctionVersion(prop: number, trace: string[]): Promise<number> {
    for (let attempt = 1; attempt <= FujifilmNet.FIRMWARE_RETRY; attempt++) {
      if (FujifilmFirmwareService.cancelRequested) return 0;
      try {
        const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
          FujifilmOp.GET_DEVICE_PROP_VALUE, [prop], FujifilmNet.TRANSACTION_TIMEOUT_MS);
        if (reply.code === FujifilmResponse.OK) {
          if (reply.data.length >= 4) return FujifilmBytes.readU32(reply.data, 0);
          if (reply.data.length >= 2) return FujifilmBytes.readU16(reply.data, 0);
          return 0;
        }
        trace.push(`GetFunctionVersion(${FujifilmBytes.hex(prop)}) #${attempt} code=${FujifilmBytes.hex(reply.code)}`);
        if (!FujifilmFirmwareService.isRetryable(reply.code)) return 0;
      } catch (error) {
        trace.push(`GetFunctionVersion #${attempt} 异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      }
      await FujifilmFirmwareService.delay(RETRY_INTERVAL_MS);
    }
    return 0;
  }

  private static async setFunctionVersion(prop: number, version: number,
    trace: string[]): Promise<boolean> {
    for (let attempt = 1; attempt <= FujifilmNet.FIRMWARE_RETRY; attempt++) {
      if (FujifilmFirmwareService.cancelRequested) return false;
      try {
        const reply: FujifilmReply = await FujifilmPtpIp.opDataOut(
          FujifilmOp.SET_DEVICE_PROP_VALUE, [prop], FujifilmBytes.u32(version),
          FujifilmNet.TRANSACTION_TIMEOUT_MS);
        trace.push(`SetFunctionVersion(${FujifilmBytes.hex(prop)},${version}) #${attempt} code=${FujifilmBytes.hex(reply.code)}`);
        if (reply.code === FujifilmResponse.OK) return true;
        if (!FujifilmFirmwareService.isRetryable(reply.code)) return false;
      } catch (error) {
        trace.push(`SetFunctionVersion #${attempt} 异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      }
      await FujifilmFirmwareService.delay(RETRY_INTERVAL_MS);
    }
    return false;
  }

  /** 读 0xD22F 得相机内固件文件名（原始串）。 */
  static async readPtpFirmwareFilename(trace: string[]): Promise<string> {
    try {
      const reply: FujifilmReply = await FujifilmPtpIp.opDataIn(
        FujifilmOp.GET_DEVICE_PROP_VALUE,
        [FujifilmFirmwareCode.PROP_CURRENT_BODY_FIRMWARE_FILENAME],
        FujifilmNet.TRANSACTION_TIMEOUT_MS);
      if (reply.code !== FujifilmResponse.OK || reply.data.length === 0) {
        trace.push(`读 0xD22F code=${FujifilmBytes.hex(reply.code)} len=${reply.data.length}`);
        return '';
      }
      const name: string = FujifilmFirmwareService.decodePtpString(reply.data);
      trace.push(`0xD22F=${name}`);
      return name;
    } catch (error) {
      trace.push(`读 0xD22F 异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      return '';
    }
  }

  /** 检查链路里的 0xD22F：只有 PTP 已连才试，失败静默。 */
  private static async readPtpFirmwareVersion(trace: string[]): Promise<string> {
    let connected = false;
    try {
      connected = FujifilmPtpIp.isConnected();
    } catch (_error) {
      connected = false;
    }
    if (!connected) return '';
    const name: string = await FujifilmFirmwareService.readPtpFirmwareFilename(trace);
    return FujifilmFirmwareService.versionFromFirmwareFilename(name);
  }

  /**
   * PTP 字符串解码。0xD22F 的编码报告未写死（native 是 `char[]`），
   * 这里按顺序尝试：标准 PTP 串（首字节字符数 + UTF-16LE）→ UTF-8 NUL 截断
   * → 裸 UTF-16LE。任一分支解出可打印串即采用。
   */
  private static decodePtpString(data: Uint8Array): string {
    if (data.length === 0) return '';
    const declared: number = data[0];
    if (declared > 0 && 1 + declared * 2 <= data.length) {
      const text = FujifilmFirmwareService.utf16le(data, 1, declared * 2);
      if (text.length > 0 && FujifilmFirmwareService.isPrintable(text)) return text;
    }
    const utf8: string = util.TextDecoder.create('utf-8').decodeToString(data);
    const trimmed: string = utf8.replace(/\0/g, '').trim();
    if (trimmed.length > 0 && FujifilmFirmwareService.isPrintable(trimmed)) return trimmed;
    const wide = FujifilmFirmwareService.utf16le(data, 0, data.length);
    return wide.trim();
  }

  private static utf16le(data: Uint8Array, offset: number, byteLength: number): string {
    let text = '';
    const end: number = Math.min(data.length, offset + byteLength);
    for (let index = offset; index + 1 < end; index += 2) {
      const code: number = data[index] | (data[index + 1] << 8);
      if (code === 0) break;
      text += String.fromCharCode(code);
    }
    return text;
  }

  private static isPrintable(text: string): boolean {
    for (let index = 0; index < text.length; index++) {
      const code: number = text.charCodeAt(index);
      if (code < 0x20 || code > 0x7E) return false;
    }
    return true;
  }

  /**
   * 推流主循环（S32–S36）。
   *
   * 时序按 04 §4.2：先发 objectInfo（对象名固定 "FUP_FILE.DAT"），紧接着发首块
   * 1 MiB（S33 不等待事件），之后每收到一次事件 49 就发下一块；事件 50 结束。
   * 单块等待 5 s（04 §5.10）；等不到不报错继续等，直到整程上限
   * （FujifilmNet.FIRMWARE_TOTAL_TIMEOUT_MS，native 侧同值）。
   */
  private static async transferFile(path: string, size: number,
    report: (status: string, percent: number) => void, trace: string[]): Promise<FujifilmFirmwareResult> {
    let file: fileIo.File | null = null;
    try {
      const stat = fileIo.statSync(path);
      const total: number = stat.size;
      if (total <= 0) {
        return FujifilmFirmwareService.result(false, false, 'transfer', '固件文件为空', 0, trace);
      }
      if (size > 0 && total !== size) {
        trace.push(`本地文件大小 ${total} 与清单 ${size} 不一致，按本地实际大小发送`);
      }
      const handle: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      file = handle;
      const started: number = Date.now();

      // S32：对象名固定 FUP_FILE.DAT（与真实文件名无关，04 §7.2 #6）。
      const objectName: string = 'FUP_FILE.DAT';
      const infoReply: FujifilmReply = await FujifilmPtpIp.opDataOut(
        FujifilmOp.FM_SEND_OBJECT_INFO, [total],
        FujifilmFirmwareService.buildObjectInfo(objectName), FujifilmNet.FIRMWARE_TOTAL_TIMEOUT_MS);
      trace.push(`FmSendObjectInfo(${total}) code=${FujifilmBytes.hex(infoReply.code)}`);
      if (infoReply.code !== FujifilmResponse.OK) {
        return FujifilmFirmwareService.result(false, false, 'transfer',
          `相机拒绝接收固件对象（FmSendObjectInfo ${FujifilmBytes.hex(infoReply.code)}）`,
          infoReply.code, trace);
      }

      let offset: number = 0;
      let done: boolean = false;
      let cancelledByCamera: boolean = false;
      let timeoutLogged: boolean = false;
      while (offset < total) {
        if (FujifilmFirmwareService.cancelRequested) {
          return FujifilmFirmwareService.result(false, true, 'cancelled',
            '已取消固件传输（相机侧不会回滚）', 0, trace);
        }
        if (FujifilmFirmwareService.disconnectSeen) {
          return FujifilmFirmwareService.result(false, false, 'transfer',
            '固件传输中相机断开连接', 0, trace);
        }
        if (Date.now() - started > FujifilmNet.FIRMWARE_TOTAL_TIMEOUT_MS) {
          return FujifilmFirmwareService.result(false, false, 'transfer',
            '固件传输超时（超过 600 s）', 0, trace);
        }
        // 首块不等待事件（S33）；之后每块都要等相机事件 49（S34）。
        if (offset > 0) {
          const frame: FujifilmEventFrame | null =
            await FujifilmFirmwareService.waitEvent(FujifilmNet.FIRMWARE_CHUNK_WAIT_MS);
          if (frame === null) {
            // 04 §7.2 #15：5 s 等不到事件不报错，继续等下一轮（相机可能在写卡）。
            if (!timeoutLogged) {
              timeoutLogged = true;
              trace.push(`等事件 49 超时（offset=${offset}），继续等待`);
            }
            continue;
          }
          if (frame.code === FujifilmEvent.FIRMWARE_DONE) {
            done = true;
            cancelledByCamera = frame.params.length > 0 && frame.params[0] === 1;
            break;
          }
          if (frame.code !== FujifilmEvent.FIRMWARE_PULL_CHUNK) continue;
        }
        const length: number = Math.min(FujifilmNet.FIRMWARE_CHUNK, total - offset);
        const chunk = new Uint8Array(length);
        const read: number = fileIo.readSync(handle.fd, chunk.buffer as ArrayBuffer,
          { offset: offset, length: length });
        if (read <= 0) {
          return FujifilmFirmwareService.result(false, false, 'transfer',
            `读取固件文件失败（offset=${offset}）`, 0, trace);
        }
        const sent: boolean = await FujifilmFirmwareService.sendChunk(
          chunk.subarray(0, read), offset, trace);
        if (!sent) {
          return FujifilmFirmwareService.result(false, false, 'transfer',
            '向相机发送固件数据块失败', 0, trace);
        }
        offset += read;
        const percent: number = Math.min(99, Math.floor(offset * 100 / total));
        report(`正在向相机传输固件… ${percent}%`, percent);
      }

      // 最后一块发完还要等 event 50（S36）。arg1=1 表示相机侧已取消。
      const finalDeadline: number = Date.now() + SEND_COMPLETE_TIMEOUT_MS;
      while (!done && Date.now() < finalDeadline) {
        const frame: FujifilmEventFrame | null = await FujifilmFirmwareService.waitEvent(
          Math.max(EVENT_POLL_MS, finalDeadline - Date.now()));
        if (frame === null) break;
        if (frame.code === FujifilmEvent.FIRMWARE_DONE) {
          done = true;
          cancelledByCamera = frame.params.length > 0 && frame.params[0] === 1;
        }
        // 仍收到事件 49：字节已经发完，忽略继续等 50。
      }
      if (!done) {
        trace.push('未收到事件 50（发送完成）');
        return FujifilmFirmwareService.result(false, false, 'waiting',
          '固件已全部发出，但没等到相机的"发送完成"事件；请在相机上确认状态', 8194, trace);
      }
      if (cancelledByCamera) {
        return FujifilmFirmwareService.result(false, true, 'cancelled',
          '相机侧终止了固件传输（事件 50 arg1=1）', 0, trace);
      }
      report('固件已发送完成', 100);
      trace.push(`固件发送完成 bytes=${offset} elapsedMs=${Date.now() - started}`);
      return FujifilmFirmwareService.result(true, false, 'done', '', 0, trace);
    } catch (error) {
      trace.push(`推流异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      return FujifilmFirmwareService.result(false, false, 'transfer',
        `固件传输异常：${FujifilmFirmwareService.errorCode(error)}`,
        FujifilmFirmwareService.numericCode(error), trace);
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_error) { }
      }
    }
  }

  /** 单块发送，仅对"忙"类响应重试 ≤5 次（04 §5.10）。 */
  private static async sendChunk(chunk: Uint8Array, offset: number,
    trace: string[]): Promise<boolean> {
    for (let attempt = 1; attempt <= FujifilmNet.FIRMWARE_RETRY; attempt++) {
      if (FujifilmFirmwareService.cancelRequested) return false;
      try {
        // 04 §5.10：native 侧 SendObject 超时 600 000 ms。
        const reply: FujifilmReply = await FujifilmPtpIp.opDataOut(
          FujifilmOp.FM_SEND_PARTIAL_OBJECT, [offset, chunk.length], chunk,
          FujifilmNet.FIRMWARE_TOTAL_TIMEOUT_MS);
        if (reply.code === FujifilmResponse.OK) return true;
        trace.push(`FmSendPartialObject offset=${offset} len=${chunk.length} #${attempt} code=${FujifilmBytes.hex(reply.code)}`);
        if (!FujifilmFirmwareService.isRetryable(reply.code)) return false;
      } catch (error) {
        trace.push(`FmSendPartialObject offset=${offset} #${attempt} 异常 code=${FujifilmFirmwareService.errorCode(error)}`);
      }
      await FujifilmFirmwareService.delay(RETRY_INTERVAL_MS);
    }
    return false;
  }

  /**
   * objectInfo 载荷：PTP 字符串（1 B 字符数 + UTF-16LE + 0x0000）。
   * 【推断】native 的 `Java_SDK_FmSendObjectInfo(hCamera, internalName, dataSize)`
   * 取的是 Java 侧字符串，线上编码只能是 PTP 标准串；若抓包证伪，只改这里。
   */
  private static buildObjectInfo(name: string): Uint8Array {
    const body: Uint8Array = FujifilmBytes.utf16z(name);
    const out = new Uint8Array(body.length + 1);
    out[0] = name.length + 1;
    out.set(body, 1);
    return out;
  }

  // -------------------------------------------------------------------------
  // 收尾 / 结果描述
  // -------------------------------------------------------------------------

  private static finishTransfer(): void {
    FujifilmFirmwareService.pendingEvents = [];
    // 监听器**故意不注销**：`FujifilmPtpIp.onEvent` 是追加式，`clearEventListeners()`
    // 会把控制页/图传页的监听一起清掉。这里注册一次就长期有效（只关心 49/50），
    // 非固件阶段的 49/50 也只会进队列、没人消费，不会影响别的页面。
    if (FujifilmFirmwareService.ptpOpened) {
      FujifilmPtpIp.close().catch((_error: Object): void => { });
      FujifilmFirmwareService.ptpOpened = false;
    }
    // S38：native 在升级末尾会碰 0xD17B（电源）/ XSDK_PowerOFF(0x1023)。
    // 官方 Java 层没有任何断电调用，这里只记录，绝不主动发送。
    FujifilmFirmwareService.log('收尾：不发送断电/重启命令（0xD17B / 0x1023 仅记录）');
  }

  private static result(ok: boolean, cancelled: boolean, stage: FujifilmFirmwareStage,
    message: string, code: number, trace: string[]): FujifilmFirmwareResult {
    return { ok: ok, cancelled: cancelled, stage: stage, message: message, code: code, trace: trace };
  }

  /**
   * 相机侧准入/结果枚举（04 §5.7.2，BLE 049EC406 回传）。
   * 目前 A 的 BLE 契约没有暴露该通知，保留完整的映射供接线后直接使用。
   */
  static describeCameraState(value: number): string {
    switch (value) {
      case 0: return '未知原因（NG_NO_REASON）';
      case 1: return '允许升级（OK）';
      case 16: return '相机忙（NG_BUSY）';
      case 32: return '机身上挂着镜头，禁止升级（NG_LENS）';
      case 48: return '机身接着配件，禁止升级（NG_ACCESSORY）';
      case 64: return '电量不足（NG_LOW_BATTERY）';
      case 65: return '电量不足，LX44 阈值（NG_LOW_BATTERY_LX44）';
      case 80: return '机型不符（NG_PRODUCT_NAME）';
      case 96: return '固件文件名不符（NG_FIRMWARE_FILE_NAME）';
      case 112: return '固件文件大小不符（NG_FIRMWARE_FILE_SIZE）';
      case 128: return '版本不允许，通常是降级被拒（NG_FIRMWARE_VERSION）';
      case 256: return '用户取消（NG_USER_CANCEL）';
      default: return `未知状态码 ${value}`;
    }
  }

  /** PTP 响应码 / SDK 错误码 → 用户能看懂的解释（04 §5.7.1）。 */
  static describeErrorCode(code: number): string {
    switch (code) {
      case 0: return '';
      case 1: return '已取消（SDK_CANCEL）';
      case -1: return '通用失败（SDK_ERROR）';
      case -2: return 'socket 打开失败（SDK_ERROR_OPEN_SOCKET）';
      case 4102: return '相机忙，稍后重试（SDK_ERRCODE_BUSY）';
      case 8193: return '通信错误（SDK_ERRCODE_COMMUNICATION）';
      case 8194: return '超时（SDK_ERRCODE_TIMEOUT）';
      case 12289: return '相机系统错误（SDK_ERRCODE_SYSTEMERROR）';
      case 12290: return '存储卡已满（SDK_ERRCODE_STORE_FULL）';
      case 12291: return '存储卡写保护（SDK_ERRCODE_PROTECT_CARD）';
      case 12293: return '存储不可用（SDK_ERRCODE_STORE_NOT_AVAILABLE）';
      case 36865: return '相机内部错误（SDK_ERRCODE_INTERNAL）';
      case FujifilmResponse.GENERAL_ERROR: return '相机返回通用错误（0x2002）';
      case FujifilmResponse.SESSION_NOT_OPEN: return '会话未打开（0x2003）';
      case FujifilmResponse.OPERATION_NOT_SUPPORTED: return '相机不支持该操作（0x2005）';
      case FujifilmResponse.PARAMETER_NOT_SUPPORTED: return '相机不支持该参数（0x2006）';
      case FujifilmResponse.DEVICE_BUSY: return '相机忙（0x2019）';
      case FujifilmResponse.TRANSACTION_CANCELLED: return '事务被取消（0x201F）';
      default: return `错误码 ${code}`;
    }
  }

  // -------------------------------------------------------------------------
  // 小工具
  // -------------------------------------------------------------------------

  static sizeText(bytes: number): string {
    if (!(bytes > 0)) return '大小未知';
    if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1)} MB`;
    if (bytes >= 1024) return `${(bytes / 1024).toFixed(0)} KB`;
    return `${bytes} B`;
  }

  private static isRetryable(code: number): boolean {
    return code === FujifilmResponse.DEVICE_BUSY || code === FujifilmResponse.FUJI_RETRY_CODE;
  }

  private static safeFileName(name: string): string {
    const cleaned: string = name.replace(/[^A-Za-z0-9._-]/g, '_');
    return cleaned.length > 0 ? cleaned : 'FUP_FILE.DAT';
  }

  private static toHex(data: Uint8Array): string {
    let text = '';
    for (let index = 0; index < data.length; index++) {
      const part: string = data[index].toString(16);
      text += part.length === 1 ? '0' + part : part;
    }
    return text;
  }

  private static unlinkQuietly(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (_error) { }
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }

  private static errorCode(error: Object): string {
    const withCode = error as ErrorWithCode;
    return withCode.code !== undefined ? String(withCode.code) : String(error);
  }

  private static numericCode(error: Object): number {
    const withCode = error as ErrorWithCode;
    if (withCode.code === undefined) return 0;
    const value: number = Number(withCode.code);
    return Number.isFinite(value) ? value : 0;
  }

  private static log(message: string): void {
    AppLogStore.add(`[FUJI] ${message}`);
  }
}
