/**
 * Sony still-image parameters over PTP/IP.
 *
 * Two halves, both taken from Sony's own client:
 *
 *  - READ. Every value and every selectable-value list a panel needs is already
 *    in the `SDIO_GetAllExtDevicePropInfo` (0x9209) dump this app performs when
 *    it opens the session: `DevicePropInfoDataset.java:248-261` reads a
 *    formFlag-2 record's two `u16`-counted arrays out of the SAME record, and
 *    `SonyPtpIpContent` now keeps the ordered one (`mGetSetValues`). Nothing here
 *    issues a request.
 *
 *  - WRITE. `SDIO_SetExtDevicePropValue` (0x9205) with `[code]` — or `[code, 1]`
 *    when the vendor code version is at least 310 — and the raw value as a plain
 *    little-endian scalar of the property's own `EnumDataType`
 *    (`BasePtpManager.java:1826-1843`, `SDIO_SetExtDevicePropValue.java:8-11`,
 *    `TransactionExecutor.java:133-139`). Note this is NOT `0x1016
 *    SetDevicePropValue`: that operation does not exist in Sony's enum at all.
 *
 * Sony gates a write on the camera's own declaration, not on a table of ours:
 * `canSet` is `mIsEnable == True && mGetSet == GetSet`
 * (`ptp/remotecontrol/controller/AbstractController.java:90-93`), plus a global
 * `RemoteControlRestrictionStatus` (53860) that must read 0
 * (`AbstractSettingDialogController.java:70-84`). Both are honoured here before
 * anything is sent, so an unsupported parameter produces a log line rather than
 * a refused operation.
 */
import { NikonPtpIpService } from './NikonPtpIpService';
import { SonyPtpIpContent } from './SonyPtpIpContent';
import { SonyLiveView } from './SonyLiveView';

/** One parameter as the panel needs it. */
export class SonyParameter {
  /** Sony property code in use, or 0 when this tag has no Sony code. */
  code: number = 0;
  /** The camera's raw value, meaningless unless `known`. */
  raw: number = 0;
  /** `false` when no 0x9209 dump of this attempt carried the property. */
  known: boolean = false;
  /** The value rendered the way Sony renders it, or '--'. */
  display: string = '--';
  /** The camera's `canSet` for this property, and not globally restricted. */
  writable: boolean = false;
  /** The camera's ordered selectable values for this property. */
  options: number[] = [];
}

export class SonyPtpIpControl {
  static readonly TAG_APERTURE = 'aperture';
  static readonly TAG_SHUTTER = 'shutter';
  static readonly TAG_ISO = 'iso';
  static readonly TAG_EV = 'ev';
  static readonly TAG_MODE = 'mode';
  static readonly TAG_WB = 'wb';
  static readonly TAG_FOCUS = 'focus';
  static readonly TAG_DRIVE = 'drive';

  /** No PTP/IP session to send on. */
  static readonly FAIL_NO_SESSION = -1;
  /** The camera declares the property `Get`/`DispOnly`, so a set would be refused. */
  static readonly FAIL_NOT_WRITABLE = -2;
  /** `RemoteControlRestrictionStatus` says this body accepts no setting now. */
  static readonly FAIL_RESTRICTED = -3;
  /** The property's `EnumDataType` never appeared in a dump, so its width is unknown. */
  static readonly FAIL_UNKNOWN_WIDTH = -4;
  /** The tag has no Sony property. */
  static readonly FAIL_NO_SUCH_PARAMETER = -5;

  /** Built once, on first use — the exposure-program map is static data. */
  private static programModeMap: Map<number, string> | null = null;

  /** `EnumDevicePropCode` for a panel tag, or 0 when Sony has no code for it. */
  static parameterCodeOf(tag: string): number {
    switch (tag) {
      case 'aperture': return SonyPtpIpContent.PROP_F_NUMBER;
      case 'shutter': return SonyPtpIpContent.PROP_SHUTTER_SPEED;
      case 'iso': return SonyPtpIpContent.PROP_ISO_SENSITIVITY;
      case 'ev': return SonyPtpIpContent.PROP_EXPOSURE_BIAS_COMPENSATION;
      case 'mode': return SonyPtpIpContent.PROP_EXPOSURE_PROGRAM_MODE;
      case 'wb': return SonyPtpIpContent.PROP_WHITE_BALANCE;
      case 'quality': return SonyPtpIpControl.qualityCodeOf();
      case 'aspect': return SonyPtpIpContent.PROP_ASPECT_RATIO;
      case 'focus': return SonyPtpIpContent.PROP_FOCUS_MODE;
      case 'drive': return SonyPtpIpContent.PROP_STILL_CAPTURE_MODE;
      default: return 0;
    }
  }

  /**
   * The property Sony READS for a tag.
   *
   * Aperture is the one case where this is not simply `parameterCodeOf`: for the
   * shutter Sony reads `ExtendedShutterSpeed` whenever it can merely GET it and
   * `ShutterSpeed` otherwise — `canGet(ExtendedShutterSpeed) ? Extended : Shutter`
   * (`ShutterSpeedSettingController.java:199-204`) — and the option list travels
   * with whichever property is in force.
   */
  static displayCodeOf(tag: string): number {
    if (tag === 'shutter' &&
      SonyPtpIpContent.isPropertyEnabled(SonyPtpIpContent.PROP_EXTENDED_SHUTTER_SPEED)) {
      return SonyPtpIpContent.PROP_EXTENDED_SHUTTER_SPEED;
    }
    return SonyPtpIpControl.parameterCodeOf(tag);
  }

  /**
   * The property Sony WRITES for a tag — deliberately a different test from
   * `displayCodeOf`.
   *
   * The shutter is again the case: Sony writes `ExtendedShutterSpeed` only when
   * the camera allows a SET on it, and `ShutterSpeed` otherwise
   * (`ShutterSpeedSettingController.java:175-178`). So a body that lets us read
   * the extended property but not set it is displayed from the extended list and
   * written through the ordinary one.
   */
  static writeCodeOf(tag: string): number {
    if (tag === 'shutter' &&
      SonyPtpIpContent.propertyWritable(SonyPtpIpContent.PROP_EXTENDED_SHUTTER_SPEED)) {
      return SonyPtpIpContent.PROP_EXTENDED_SHUTTER_SPEED;
    }
    return SonyPtpIpControl.parameterCodeOf(tag);
  }

  /**
   * `RemoteControlRestrictionStatus` must read 0. Sony's dialog controller keeps
   * a setting panel open for raw 0 and dismisses every panel for anything else
   * (`AbstractSettingDialogController.java:70-84`, whose ordinal is the raw value
   * plus one). A property the camera never sent is treated as unrestricted, the
   * same way an absent record is treated as no objection elsewhere.
   */
  static restrictionAllowsSet(): boolean {
    const status = SonyPtpIpContent.propertyValue(
      SonyPtpIpContent.PROP_REMOTE_CONTROL_RESTRICTION_STATUS);
    return status === undefined ||
      status === SonyPtpIpContent.RESTRICTION_STATUS_UNRESTRICTED;
  }

  /** The camera's current state of one parameter, for the panel. */
  static parameterOf(tag: string): SonyParameter {
    const result = new SonyParameter();
    const code = SonyPtpIpControl.displayCodeOf(tag);
    result.code = code;
    if (code === 0) {
      return result;
    }
    const raw = SonyPtpIpContent.propertyValue(code);
    if (raw === undefined) {
      return result;
    }
    result.raw = raw;
    result.known = true;
    result.display = SonyPtpIpControl.formatValue(code, raw);
    // Writability is decided by the property the WRITE would use, which for the
    // shutter is not necessarily the one just read.
    result.writable = SonyPtpIpContent.propertyWritable(SonyPtpIpControl.writeCodeOf(tag)) &&
      SonyPtpIpControl.restrictionAllowsSet();
    result.options = SonyPtpIpContent.propertyOptions(code);
    return result;
  }

  /** A raw value rendered the way Sony renders it. */
  static formatValue(code: number, raw: number): string {
    if (code === SonyPtpIpContent.PROP_F_NUMBER) {
      return SonyPtpIpControl.formatFNumber(raw);
    }
    if (code === SonyPtpIpContent.PROP_SHUTTER_SPEED ||
      code === SonyPtpIpContent.PROP_EXTENDED_SHUTTER_SPEED) {
      return SonyPtpIpControl.formatShutter(raw);
    }
    if (code === SonyPtpIpContent.PROP_ISO_SENSITIVITY) {
      return SonyPtpIpControl.formatIso(raw);
    }
    if (code === SonyPtpIpContent.PROP_EXPOSURE_BIAS_COMPENSATION) {
      return SonyPtpIpControl.formatEv(raw);
    }
    if (code === SonyPtpIpContent.PROP_EXPOSURE_PROGRAM_MODE) {
      return SonyPtpIpControl.formatProgramMode(raw);
    }
    if (code === SonyPtpIpContent.PROP_WHITE_BALANCE) {
      return SonyPtpIpControl.formatWhiteBalance(raw);
    }
    if (code === SonyPtpIpContent.PROP_ASPECT_RATIO) {
      return SonyPtpIpControl.formatAspectRatio(raw);
    }
    if (code === SonyPtpIpContent.PROP_JPEG_QUALITY) {
      return SonyPtpIpControl.formatJpegQuality(raw);
    }
    if (code === SonyPtpIpContent.PROP_COMPRESSION_FILE_FORMAT) {
      return SonyPtpIpControl.formatCompressionFileFormat(raw);
    }
    if (code === SonyPtpIpContent.PROP_RAW_FILE_TYPE) {
      return SonyPtpIpControl.formatRawFileType(raw);
    }
    return `${raw}`;
  }

  /**
   * `EnumWhiteBalance` — masked to 16 bits, then an exact match
   * (`EnumWhiteBalance$EnumUnboxingLocalUtility.java:79-124`, smali mask `0xffff`
   * at `:128`). There is no high-bit companion field: the mask consumes the whole
   * value, and the `+` signs live inside the fluorescent labels themselves. Color
   * temperature is a SEPARATE property (`ColorTemperature`, 53775) that this app
   * does not yet expose.
   *
   * Sony's UI shows resource strings rather than these literals
   * (`ResIdTable.java:99-138`), so the labels here are the enum's own and read
   * only slightly differently from the app's wording.
   */
  private static formatWhiteBalance(raw: number): string {
    const value = raw & 0xFFFF;
    if (value === 0) return '--';
    if (value === 1) return '手动';
    if (value === 2) return 'AWB';
    if (value === 3) return '一键自动';
    if (value === 4) return '日光';
    if (value === 5) return '荧光灯';
    if (value === 6) return '白炽灯';
    if (value === 7) return '闪光灯';
    if (value === 0x8001) return '荧光:暖白(-1)';
    if (value === 0x8002) return '荧光:冷白(0)';
    if (value === 0x8003) return '荧光:日光白(+1)';
    if (value === 0x8004) return '荧光:日光(+2)';
    if (value === 0x8010) return '阴天';
    if (value === 0x8011) return '阴影';
    if (value === 0x8012) return '色温/滤光片';
    if (value === 0x8020) return '自定义 1';
    if (value === 0x8021) return '自定义 2';
    if (value === 0x8022) return '自定义 3';
    if (value === 0x8023) return '自定义';
    if (value === 0x8030) return '水下自动';
    return `${value}`;
  }

  /** `EnumAspectRatio` — masked to the LOW BYTE, then an exact match
   * (`EnumAspectRatio$EnumUnboxingLocalUtility.java:20-28`, smali mask `0xff`).
   * The app shows these four as literal strings (`ResIdTable.java:174-187`). */
  private static formatAspectRatio(raw: number): string {
    const value = raw & 0xFF;
    if (value === 1) return '3:2';
    if (value === 2) return '16:9';
    if (value === 3) return '4:3';
    if (value === 4) return '1:1';
    return '--';
  }

  /**
   * `EnumJPEGQuality` — masked to the low byte, then an exact match. This is the
   * still-image quality property Sony's app actually reads and writes
   * (`EnumCameraProperty.java:1446-1447`, read `:1592-1596`, candidates
   * `:1619-1633`, write `:1642-1661` to `0xD252`), NOT `CompressionSetting`
   * (0x5004): that code appears in the whole tree only as an enum constant, with
   * no property key, no menu entry and no get/set call — and the ILCE-7M4 does
   * not even report it (`sony params 0x5004:none:opt0:ro`).
   */
  private static formatJpegQuality(raw: number): string {
    const value = raw & 0xFF;
    if (value === 1) return '超精细';
    if (value === 2) return '精细';
    if (value === 3) return '标准';
    if (value === 4) return '轻量';
    return '--';
  }

  /**
   * Which property the 画质 panel drives.
   *
   * Sony splits still-image quality across three codes and this body does not
   * expose the classic combined one at all (`CompressionSetting`/0x5004 is not
   * even reported: `sony params … 0x5004:none:opt0:ro`). Measured on an
   * ILCE-7M4, `JPEGQuality` is declared read-only — and its current value is 0,
   * Sony's `Undefined` — while `AspectRatio`, the same data type with the same
   * four options, is declared writable. So the declaration is the body's
   * decision, not a parsing artefact:
   *
   *   sony params … 0xD252:0x0002/UINT8:opt4:ro:v=0
   *                0xD287:0x0002/UINT8:opt3:set:v=1
   *                0xD288:0x0002/UINT8:opt5:set:v=2
   *                0xD211:0x0002/UINT8:opt4:set:v=1 …
   *   sony set quality refused: camera does not allow a set code=53842
   *
   * The classic RAW / RAW+FINE / FINE / STD / LIGHT list the user expects is
   * `CompressionSetting`, which this body never reports, so no panel can offer
   * it. Of the two quality properties that ARE writable here, this drives
   * `RawFileType` (0xD288) — the RAW flavour list (Compression / LossLess
   * L,M,S / UnCompression) — because that is the closest thing to the expected
   * RAW series. `CompressionFileFormat` (0xD287, JPEG vs HEIF) is the next
   * fallback, and the read-only JPEG grade is the last resort so that a body
   * which allows none of them still displays something.
   */
  private static qualityCodeOf(): number {
    if (SonyPtpIpContent.propertyWritable(SonyPtpIpContent.PROP_RAW_FILE_TYPE)) {
      return SonyPtpIpContent.PROP_RAW_FILE_TYPE;
    }
    if (SonyPtpIpContent.propertyWritable(SonyPtpIpContent.PROP_COMPRESSION_FILE_FORMAT)) {
      return SonyPtpIpContent.PROP_COMPRESSION_FILE_FORMAT;
    }
    if (SonyPtpIpContent.propertyWritable(SonyPtpIpContent.PROP_JPEG_QUALITY)) {
      return SonyPtpIpContent.PROP_JPEG_QUALITY;
    }
    return SonyPtpIpContent.PROP_RAW_FILE_TYPE;
  }

  /** `EnumCompressionFileFormat` — masked to the low byte
   * (`EnumCompressionFileFormat.java:21-42`, mask at `:35`). */
  private static formatCompressionFileFormat(raw: number): string {
    const value = raw & 0xFF;
    if (value === 1) return 'JPEG';
    if (value === 2) return 'HEIF(4:2:2)';
    if (value === 3) return 'HEIF(4:2:0)';
    return '--';
  }

  /** `EnumRawFileType` — masked to the low byte (`EnumRawFileType.java:22-47`,
   * mask at `:40`). The label is suffixed with RAW because this value is the raw
   * flavour, not the still format. */
  private static formatRawFileType(raw: number): string {
    const value = raw & 0xFF;
    if (value === 1) return 'RAW 已压缩';
    if (value === 2) return 'RAW 无损 L';
    if (value === 3) return 'RAW 无损 M';
    if (value === 4) return 'RAW 无损 S';
    if (value === 5) return 'RAW 未压缩';
    if (value === 6) return 'RAW 无损';
    if (value === 7) return 'RAW 高画质压缩';
    return '--';
  }

  /**
   * `EnumExposureProgramMode` — an exact match on the FULL raw value.
   *
   * The raw value is NOT the enum ordinal: the authoritative constants come from
   * the smali static initializer (`EnumExposureProgramMode.smali` clinit
   * `:205-2060`), where `AperturePriority` is `0x00020003` and `Automatic` is
   * `0x00010002`, not 3 and 2. The earlier version of this method masked the raw
   * value to 16 bits and looked it up by ordinal, which happens to land on the
   * right letter for P/A/S/M (`0x00020003 & 0xFFFF == 3`) and is wrong for every
   * other entry — `Auto` is `0x00048000`, which masked to 0x8000 and rendered as
   * the number 32768.
   *
   * The four dial positions keep the single letters the camera shows; every other
   * entry uses Sony's own `mString` verbatim.
   */
  private static formatProgramMode(raw: number): string {
    const table = SonyPtpIpControl.programModeTable();
    const label = table.get(raw);
    return label === undefined ? (raw === 0 ? '--' : `${raw}`) : label;
  }

  /** Built once: the map is 62 entries of static data. */
  private static programModeTable(): Map<number, string> {
    if (SonyPtpIpControl.programModeMap !== null) {
      return SonyPtpIpControl.programModeMap;
    }
    const map = new Map<number, string>();
    // The four dial positions, plus P's two scene-program variants.
    map.set(0x00000000, '--');
    map.set(0x00000001, 'M');
    map.set(0x00010002, 'P');
    map.set(0x00020003, 'A');
    map.set(0x00030004, 'S');
    map.set(0x00000005, 'P');
    map.set(0x00000006, 'P');
    map.set(0x00000007, '人像');
    map.set(0x00048000, 'AUTO');
    map.set(0x00048001, 'AUTO+');
    map.set(0x00008008, 'P_A');
    map.set(0x00008009, 'P_S');
    map.set(0x00058011, '运动');
    map.set(0x00058012, '夕阳');
    map.set(0x00058013, '夜景');
    map.set(0x00058014, '风景');
    map.set(0x00058015, '微距');
    map.set(0x00058016, '手持夜景');
    map.set(0x00058017, '夜景人像');
    map.set(0x00058018, '防抖');
    map.set(0x00058019, '宠物');
    map.set(0x0005801a, '美食');
    map.set(0x0005801b, '烟花');
    map.set(0x0005801c, '高感光度');
    map.set(0x00008020, 'MR');
    map.set(0x00008030, '连续优先 AE');
    map.set(0x00008031, '远摄变焦连续优先 AE 8 张');
    map.set(0x00008032, '远摄变焦连续优先 AE 10 张');
    map.set(0x00008033, '连续优先 AE 12 张');
    map.set(0x00068040, '3D 扫描全景');
    map.set(0x00068041, '扫描全景');
    map.set(0x00078050, '视频 P');
    map.set(0x00078051, '视频 A');
    map.set(0x00078052, '视频 S');
    map.set(0x00078053, '视频 M');
    map.set(0x00078054, '视频 AUTO');
    map.set(0x00078090, '视频 F');
    map.set(0x00098059, 'S&Q 视频 P');
    map.set(0x0009805a, 'S&Q 视频 A');
    map.set(0x0009805b, 'S&Q 视频 S');
    map.set(0x0009805c, 'S&Q 视频 M');
    map.set(0x0009805d, 'S&Q 视频 AUTO');
    map.set(0x00098091, 'S&Q F');
    map.set(0x00008060, '闪光灯关闭');
    map.set(0x00008070, '照片效果');
    map.set(0x00088080, '高帧率 P');
    map.set(0x00088081, '高帧率 A');
    map.set(0x00088082, '高帧率 S');
    map.set(0x00088083, '高帧率 M');
    map.set(0x00008084, 'S&Q P');
    map.set(0x00008085, 'S&Q A');
    map.set(0x00008086, 'S&Q S');
    map.set(0x00008087, 'S&Q M');
    map.set(0x000a8088, '视频');
    map.set(0x000a8089, '照片');
    map.set(0x000b808a, 'F(视频或 S&Q)');
    map.set(0x000c8092, '间隔拍摄(视频) F');
    map.set(0x000c8093, '间隔拍摄(视频) P');
    map.set(0x000c8094, '间隔拍摄(视频) A');
    map.set(0x000c8095, '间隔拍摄(视频) S');
    map.set(0x000c8096, '间隔拍摄(视频) M');
    map.set(0x000c8097, '间隔拍摄(视频) AUTO');
    SonyPtpIpControl.programModeMap = map;
    return map;
  }

  /**
   * `EnumFNumber$EnumUnboxingLocalUtility`'s table IS the f-number times 100
   * (`:31-142`): 400 renders "4.0", 560 "5.6", 1000 "10", 9000 "90". Below 10
   * the table always shows one decimal and at 10 and above none, which is the
   * same rule as `>= 10`. The "F" prefix is the controller's, not the table's
   * (`FNumberSettingController.java:230`), and 65534/65535 are its two
   * "nothing to display" spellings.
   */
  private static formatFNumber(raw: number): string {
    const value = raw & 0xFFFF;
    if (value === 0 || value === 65534 || value === 65535) {
      return '--';
    }
    const f = value / 100;
    return f >= 10 ? `F${Math.round(f)}` : `F${f.toFixed(1)}`;
  }

  /**
   * `EnumShutterSpeed.getString$4` (`:23-40`): the low 16 bits are the
   * denominator and the high 16 the numerator. All zero is BULB, a numerator of 1
   * renders "1/denominator" (1/250 is 0x000100FA), and a denominator of 10
   * renders seconds with the numerator counting tenths (2" is 0x0014000A).
   */
  private static formatShutter(raw: number): string {
    const denominator = raw & 0xFFFF;
    const numerator = Math.floor(raw / 65536) & 0xFFFF;
    if (denominator === 0 && numerator === 0) {
      return 'BULB';
    }
    if (numerator === 1) {
      return `1/${denominator}`;
    }
    if (denominator === 10) {
      const seconds = numerator / 10;
      return seconds % 1 === 0 ? `${seconds}"` : `${seconds.toFixed(1)}"`;
    }
    return '--';
  }

  /**
   * `EnumISOSensitivity.getISOValue` (`:283-286`): the low 24 bits are the ISO
   * number and 0xFFFFFF is AUTO. The bits above that are the extension variant
   * ("Extended", "Multi Frame NR"), which this panel does not distinguish.
   */
  private static formatIso(raw: number): string {
    const value = raw & 0xFFFFFF;
    if (value === 0xFFFFFF) {
      return 'AUTO';
    }
    return `ISO${value}`;
  }

  /**
   * `EnumExposureBiasCompensation` (`:16-30`): a signed 16-bit milli-EV rendered
   * `%+.1f`, with zero spelled "±0.0".
   */
  private static formatEv(raw: number): string {
    const bits = raw & 0xFFFF;
    const signed = bits >= 0x8000 ? bits - 0x10000 : bits;
    const ev = signed / 1000;
    if (ev === 0) {
      return '±0.0';
    }
    return `${ev > 0 ? '+' : '-'}${Math.abs(ev).toFixed(1)}`;
  }

  /**
   * Sets one parameter and returns the raw response code (0x2001 on success), or
   * one of the `FAIL_*` codes when the request was never sent.
   *
   * Everything is checked before the request goes out, because Sony's own client
   * will not offer the control at all in these cases: a parameter the camera
   * marks read-only, and a body under `RemoteControlRestrictionStatus`.
   */
  static async applySetting(tag: string, raw: number): Promise<number> {
    const code = SonyPtpIpControl.writeCodeOf(tag);
    if (code === 0) {
      NikonPtpIpService.log(`sony set ${tag} refused: no property code`);
      return SonyPtpIpControl.FAIL_NO_SUCH_PARAMETER;
    }
    if (!SonyPtpIpControl.restrictionAllowsSet()) {
      NikonPtpIpService.log(`sony set ${tag} refused: RemoteControlRestrictionStatus`);
      return SonyPtpIpControl.FAIL_RESTRICTED;
    }
    if (!SonyPtpIpContent.propertyWritable(code)) {
      NikonPtpIpService.log(`sony set ${tag} refused: camera does not allow a set` +
        ` code=${code}`);
      return SonyPtpIpControl.FAIL_NOT_WRITABLE;
    }
    const payload = SonyPtpIpControl.encodeValue(code, raw);
    if (payload === null) {
      NikonPtpIpService.log(`sony set ${tag} refused: data type unknown code=${code}`);
      return SonyPtpIpControl.FAIL_UNKNOWN_WIDTH;
    }
    const session = NikonPtpIpService.currentSession();
    if (session === null) {
      NikonPtpIpService.log(`sony set ${tag} skipped: no PTP/IP session`);
      return SonyPtpIpControl.FAIL_NO_SESSION;
    }
    const flag = await SonyLiveView.propertyFlag(session);
    const params = flag > 0 ? [code, flag] : [code];
    const result = await NikonPtpIpService.sendControlData(
      SonyPtpIpContent.OP_SDIO_SET_EXT_DEVICE_PROP_VALUE, params, payload);
    NikonPtpIpService.log(`sony set ${tag} code=${code} raw=${raw}` +
      ` bytes=${payload.length} result=${result}`);
    return result;
  }

  /**
   * The value as a little-endian scalar of the property's OWN declared
   * `EnumDataType` — no padding, no array form, which is exactly what Sony's
   * serialiser emits. The width is read from the 0x9209 record rather than
   * assumed, because it is the camera's declaration to make: hard-coding two
   * bytes for the aperture would work on one body and corrupt another.
   *
   * Returns null when no dump of this attempt carried the record.
   */
  private static encodeValue(code: number, raw: number): Uint8Array | null {
    const declared = SonyPtpIpContent.propertyDataType(code);
    if (declared === undefined) {
      return null;
    }
    const base = declared & (SonyPtpIpContent.DATA_TYPE_ARRAY_FLAG - 1);
    const width = SonyPtpIpContent.dataTypeWidth(base);
    if (width <= 0 || width > 8) {
      return null;
    }
    const payload = new Uint8Array(width);
    let remaining = raw;
    for (let index = 0; index < width; index++) {
      payload[index] = remaining % 256;
      remaining = Math.floor(remaining / 256);
    }
    return payload;
  }
}
