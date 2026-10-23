import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { picker, fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { parseLutText, parseLutMetadata, parseLutFile, LutLibraryStore, CustomLut, LutTable,
  lutEffectCachePath, readLutText, loadSampleOverrides, loadCustomLuts } from '../edit/models/LutLibrary';
import { LumixLutService, LumixLutSession, LumixLutSlot, LumixLutSendState, LumixLutError,
  LumixLutErrorKind, IMAGE_APP_INFO, CAPTURE_LUT_UUID, CAPTURE_LUT_FRIENDLY_NAME } from '../services/LumixLutService';
import { LumixImportPrototype } from '../services/LumixImportPrototype';
import { applyLutStack } from '../edit/engine/WorkerCore';
import { WorkerLut } from '../edit/engine/ProcessWorker';
import { GpuShaderBridge } from '../edit/engine/GpuShaderBridge';
import { PixelMapUtils } from '../edit/utils/PixelMapUtils';

/**
 * Dedicated LUT transfer route for non-S5 LUMIX bodies. It lists the bundled
 * LUT catalog one card per row; tapping 导入 opens the camera slot picker and
 * confirming streams the .cube payload into the chosen position. The page
 * owns its own LUT session and never touches the image-transfer state, so a
 * LUT import and an image transfer can coexist without interference. A failed
 * import keeps its row state and offers 重试导入, which rebuilds the LUT
 * session and streams the same LUT into the same slot again, so coming back
 * after a picture fetch can always continue the transfer.
 */

/** One bundled LUT entry as shipped in resources/rawfile/Lut/catalog.json. */
interface LutCatalogRecord {
  path: string;
  name: string;
  category: string;
  metadata: string;
}

/** A bundled or user-library LUT prepared for camera transfer. */
interface TransferableLut {
  path: string;
  name: string;
  category: string;
  author: string;
  referenceKey: string;
  /** ASCII file base name sent to the camera as the LUT name. */
  asciiName: string;
  /** Panasonic .vlt sources are converted to .cube text before sending. */
  needsConversion: boolean;
  /** True when the entry comes from the in-app custom LUT library. */
  isCustom: boolean;
  /** Parsed table used to render the effect thumbnail. */
  table: LutTable | null;
  /** Custom LUT sample image (file path / photo uri), empty for bundled. */
  sampleUri: string;
}

/** Decoded pre-LUT sample pixels used to render an effect thumbnail. */
interface PreviewSourcePixels {
  buffer: ArrayBuffer;
  width: number;
  height: number;
}

/** Loaded transfer payload for one bundled LUT. */
interface LutPayload {
  filename: string;
  bytes: ArrayBuffer;
}

/** One client-identity probe used when the camera 401s the LUT endpoints. */
interface LutIdentityCandidate {
  uuid: string;
  appInfo: string;
  friendlyName: string;
}

@Entry
@Component
struct LutTransferPage {
  @State private luts: TransferableLut[] = [];
  @State private slots: LumixLutSlot[] = [];
  @State private sessionReady: boolean = false;
  @State private connecting: boolean = false;
  @State private statusTitle: string = '正在检查相机连接…';
  @State private statusDetail: string = '';
  @State private pickerVisible: boolean = false;
  @State private pickerLutIndex: number = -1;
  @State private pickerSlotId: number = -1;
  @State private importingIndex: number = -1;
  @State private importProgress: number = 0;
  @State private importPhase: string = '';
  @State private failedIndex: number = -1;
  @State private failedSlotId: number = -1;
  @State private failedMessage: string = '';
  @State private activeTab: number = 0;
  @State private busySlotId: number = -1;
  @State private renameVisible: boolean = false;
  @State private renameSlotId: number = -1;
  @State private renameSlotName: string = '';
  @State private renameInput: string = '';
  @State private previewIds: string[] = [];
  @State private previewMaps: image.PixelMap[] = [];
  private previewLoading: boolean = false;
  private catalogLoaded: boolean = false;
  private session: LumixLutSession | null = null;

  aboutToAppear(): void {
    // Claim the camera for the LUT line: while this page is alive the
    // image-line background prewarm must not re-register its identity over
    // BLE (it would overwrite the LUT identity and leave the camera in its
    // "await ACTION_MODE" reset state, killing the Wi-Fi AP).
    LumixImportPrototype.setLutSessionActive(true);
    this.loadCatalog();
    this.refreshSession();
  }

  aboutToDisappear(): void {
    LumixImportPrototype.setLutSessionActive(false);
    for (const map of this.previewMaps) map.release();
    this.previewMaps = [];
    this.previewIds = [];
  }

  onPageShow(): void {
    // Returning from LutImportConfirmPage may have added a new custom LUT,
    // and LutDetailPage may have replaced a bundled LUT's sample image.
    if (!this.catalogLoaded) return;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.appendCustomLuts(context).then(async () => {
      await this.applySampleOverridesToBundled(context);
      this.loadLocalPreviews();
    });
  }

  /** Pull 更换示例图 overrides for the bundled rows and drop their stale
   * thumbnails so the effect previews re-render with the new sample. */
  private async applySampleOverridesToBundled(context: common.UIAbilityContext): Promise<void> {
    try {
      const overrides = await loadSampleOverrides(context);
      for (const lut of this.luts) {
        if (lut.isCustom) continue;
        const override = overrides['bundled:' + lut.path];
        const next = override !== undefined && override.length > 0 ? override : '';
        if (lut.sampleUri !== next) {
          lut.sampleUri = next;
          const index = this.previewIds.indexOf(lut.path);
          if (index >= 0) {
            const stale = this.previewMaps[index];
            this.previewIds = this.previewIds.filter((_value: string, position: number): boolean => position !== index);
            this.previewMaps = this.previewMaps.filter((_value: image.PixelMap, position: number): boolean => position !== index);
            if (stale) stale.release();
          }
        }
      }
    } catch (_error) {
    }
  }

  onBackPress(): boolean {
    if (this.importingIndex >= 0) {
      this.getUIContext().getPromptAction().showToast({ message: 'LUT 正在传输，请稍候' });
      return true;
    }
    if (this.renameVisible) {
      this.renameVisible = false;
      return true;
    }
    if (this.pickerVisible) {
      this.pickerVisible = false;
      return true;
    }
    return false;
  }

  /** Load the bundled LUT catalog plus the in-app custom LUT library. */
  private async loadCatalog(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const data = await context.resourceManager.getRawFileContent('Lut/catalog.json');
      const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(this.copyBytes(data)));
      const records = JSON.parse(text) as LutCatalogRecord[];
      const entries: TransferableLut[] = [];
      for (const record of records) {
        const path = record.path !== undefined && record.path !== null ? String(record.path) : '';
        if (path.length === 0) continue;
        const segments = path.split('/');
        const base = segments[segments.length - 1];
        const asciiName = base.replace(new RegExp('\\.[^.]+$'), '');
        // Parse the table up front so the row thumbnail can render the real
        // LUT effect instead of the untouched sample image.
        let table: LutTable | null = null;
        try {
          const lutData = await context.resourceManager.getRawFileContent(path);
          const lutSource = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(this.copyBytes(lutData)));
          const parsed = parseLutText(lutSource, path);
          table = parsed && parsed.table ? parsed.table : null;
        } catch (_tableError) {
          table = null;
        }
        const entry: TransferableLut = {
          path: path,
          name: record.name !== undefined && record.name !== null ? String(record.name) : asciiName,
          category: record.category !== undefined && record.category !== null ? String(record.category) : '',
          author: '',
          referenceKey: this.referenceKeyFor(asciiName),
          asciiName: asciiName,
          needsConversion: path.toLowerCase().lastIndexOf('.vlt') === path.length - 4,
          isCustom: false,
          table: table,
          sampleUri: '',
        };
        const metadataPath = record.metadata !== undefined && record.metadata !== null ? String(record.metadata) : '';
        if (metadataPath.length > 0) {
          try {
            const metadataData = await context.resourceManager.getRawFileContent(metadataPath);
            const metadata = parseLutMetadata(
              util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(this.copyBytes(metadataData))));
            entry.author = metadata.author;
          } catch (_error) {
            entry.author = '';
          }
        }
        entries.push(entry);
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
      this.luts = entries;
      await this.applySampleOverridesToBundled(context);
      await this.appendCustomLuts(context);
    } catch (_error) {
      this.luts = [];
    }
    this.catalogLoaded = true;
    this.loadLocalPreviews();
  }

  /** Append the in-app custom LUT library (导入 LUT 保存后的条目). */
  private async appendCustomLuts(context: common.UIAbilityContext): Promise<void> {
    try {
      const saved = await loadCustomLuts(context);
      for (const item of saved) {
        const sourceUri = item.sourceUri !== undefined && item.sourceUri !== null ? String(item.sourceUri) : '';
        if (sourceUri.length === 0) continue;
        // Skip entries already listed (page re-show after an import).
        const exists = this.luts.some((lut: TransferableLut): boolean => lut.path === sourceUri);
        if (exists) continue;
        const name = item.name !== undefined && item.name !== null && String(item.name).length > 0 ?
          String(item.name) : '自定义 LUT';
        let table = item.table !== undefined && item.table !== null ? item.table : null;
        if (!table) {
          const parsed = parseLutFile(sourceUri);
          table = parsed && parsed.table ? parsed.table : null;
        }
        const entry: TransferableLut = {
          path: sourceUri,
          name: name,
          category: '自定义',
          author: item.author !== undefined && item.author !== null ? String(item.author) : '',
          referenceKey: '',
          asciiName: this.asciiCameraName(name, 'user_lut'),
          needsConversion: false,
          isCustom: true,
          table: table,
          sampleUri: item.sampleUri !== undefined && item.sampleUri !== null ? String(item.sampleUri) : '',
        };
        this.luts = this.luts.concat([entry]);
      }
    } catch (_error) {
      // The bundled catalog stays usable when the library store is unavailable.
    }
  }

  /** ASCII-safe camera file name derived from a (possibly Chinese) LUT name. */
  private asciiCameraName(name: string, fallback: string): string {
    let ascii = '';
    for (const ch of name) {
      ascii += (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
        ch === '-' || ch === '_' ? ch : '_';
    }
    ascii = ascii.replace(/_+/g, '_').replace(/^_+/, '').replace(/_+$/, '');
    return ascii.length > 0 ? ascii.substring(0, 32) : fallback;
  }

  /** Map a bundled file base name to its preview reference image key. */
  private referenceKeyFor(asciiName: string): string {
    if (asciiName === 'sunny_mint_port') return 'sunny_mint';
    if (asciiName === 'seaside_portrait' || asciiName === 'japanese_cyan' || asciiName === 'snow_portrait' ||
      asciiName === 'healing_light' || asciiName === 'fresh_food' || asciiName === 'nc_classic_neg') {
      return asciiName;
    }
    return '';
  }

  private referenceResource(key: string) {
    switch (key) {
      case 'sunny_mint': return $r('app.media.lut_ref_sunny_mint');
      case 'japanese_cyan': return $r('app.media.lut_ref_japanese_cyan');
      case 'fresh_food': return $r('app.media.lut_ref_fresh_food');
      case 'healing_light': return $r('app.media.lut_ref_healing_light');
      case 'snow_portrait': return $r('app.media.lut_ref_snow_portrait');
      case 'seaside_portrait': return $r('app.media.lut_ref_seaside_portrait');
      case 'nc_classic_neg': return $r('app.media.lut_ref_nc_classic_neg');
      default: return $r('app.media.lut_sample_portrait');
    }
  }

  /** Row thumbnail: the LUT-rendered effect image once available. */
  private thumbFor(lut: TransferableLut): image.PixelMap | Resource {
    const index = this.previewIds.indexOf(lut.path);
    if (index >= 0 && index < this.previewMaps.length) {
      return this.previewMaps[index];
    }
    return lut.isCustom ? $r('app.media.lut_sample_portrait') : this.referenceResource(lut.referenceKey);
  }

  /**
   * Render the local LUT rows' effect thumbnails. Each image is cached under
   * filesDir as 原图名+LUT名 (shared with the main LUT page): an existing file
   * is loaded directly, otherwise it is rendered once and stored.
   */
  private async loadLocalPreviews(): Promise<void> {
    if (this.previewLoading) return;
    this.previewLoading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      for (const lut of this.luts) {
        if (this.previewIds.indexOf(lut.path) >= 0) continue;
        const map = await this.renderLocalPreview(context, lut);
        if (map) {
          this.previewIds = this.previewIds.concat([lut.path]);
          this.previewMaps = this.previewMaps.concat([map]);
        }
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
    } catch (_error) {
    } finally {
      this.previewLoading = false;
    }
  }

  /** The pre-LUT sample image name a row's effect image is derived from.
   * A user-chosen sample (更换示例图) takes precedence over the bundled
   * reference, matching lutSampleBaseName in LutLibrary. */
  private sampleBaseOf(lut: TransferableLut): string {
    if (lut.sampleUri.length > 0 && lut.sampleUri.indexOf('resource://') !== 0) {
      const segments = lut.sampleUri.split(/[\\/]/);
      const base = segments.length > 0 ? segments[segments.length - 1] : '';
      const clean = base.replace(/\.[^/.]+$/, '');
      if (clean.length > 0) return clean;
    }
    if (!lut.isCustom && lut.referenceKey.length > 0) {
      return lut.referenceKey;
    }
    return 'lut_sample_portrait';
  }

  private async renderLocalPreview(context: common.UIAbilityContext,
    lut: TransferableLut): Promise<image.PixelMap | null> {
    const table = lut.table;
    if (!table) return null;
    const cachePath = lutEffectCachePath(context.filesDir, this.sampleBaseOf(lut), lut.name);
    try {
      if (fileIo.statSync(cachePath).size > 0) {
        const cached = await PixelMapUtils.loadFromUri(cachePath, 640);
        if (cached) return cached;
      }
    } catch (_error) {
      // First run or an invalidated cache falls through to rendering.
    }
    let sourcePixels: PreviewSourcePixels | null = null;
    if (lut.sampleUri.length > 0 && lut.sampleUri.indexOf('resource://') !== 0) {
      // 更换示例图: the user-chosen sample wins over the bundled reference.
      sourcePixels = await this.pixelsFromUri(lut.sampleUri);
    }
    if (sourcePixels === null && !lut.isCustom && lut.referenceKey.length > 0) {
      sourcePixels = await this.pixelsFromResource(context, this.referenceResource(lut.referenceKey));
    }
    if (sourcePixels === null) {
      sourcePixels = await this.pixelsFromResource(context, $r('app.media.lut_sample_portrait'));
    }
    if (sourcePixels === null) return null;
    const workerLut: WorkerLut = { enabled: true, intensity: 1, size: table.size, values: table.values,
      domainMin: table.domainMin, domainMax: table.domainMax };
    let pixels: Uint8ClampedArray;
    const gpuBuffer = await GpuShaderBridge.renderLutPreview(sourcePixels.buffer.slice(0),
      sourcePixels.width, sourcePixels.height, table);
    if (gpuBuffer && gpuBuffer.byteLength > 0) {
      pixels = new Uint8ClampedArray(gpuBuffer);
    } else {
      pixels = new Uint8ClampedArray(sourcePixels.buffer);
      applyLutStack(pixels, [workerLut]);
    }
    const output = await image.createPixelMap(new ArrayBuffer(pixels.byteLength), {
      editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: sourcePixels.width, height: sourcePixels.height },
    });
    await output.writeBufferToPixels(pixels.buffer);
    try {
      const jpeg = await PixelMapUtils.encodeToJpeg(output, 90);
      if (jpeg) {
        const file = fileIo.openSync(cachePath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, jpeg);
        fileIo.closeSync(file);
      }
    } catch (_error) {
      // A cache failure must not affect the in-memory preview.
    }
    return output;
  }

  private async pixelsFromResource(context: common.UIAbilityContext,
    resource: Resource): Promise<PreviewSourcePixels | null> {
    let source: image.ImageSource | null = null;
    try {
      const bytes = await context.resourceManager.getMediaContent(resource);
      source = image.createImageSource(bytes.buffer as ArrayBuffer);
      const info = await source.getImageInfo();
      const scale = Math.min(1, 640 / Math.max(info.size.width, info.size.height));
      const width = Math.max(1, Math.round(info.size.width * scale));
      const height = Math.max(1, Math.round(info.size.height * scale));
      const map = await source.createPixelMap({
        editable: true, desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredSize: { width: width, height: height },
      });
      const buffer = new ArrayBuffer(width * height * 4);
      await map.readPixelsToBuffer(buffer);
      map.release();
      return { buffer: buffer, width: width, height: height };
    } catch (_error) {
      return null;
    } finally {
      if (source) source.release();
    }
  }

  private async pixelsFromUri(uri: string): Promise<PreviewSourcePixels | null> {
    let map: image.PixelMap | null = null;
    try {
      map = await PixelMapUtils.loadFromUri(uri, 640);
      if (!map) return null;
      const info = await map.getImageInfo();
      const buffer = new ArrayBuffer(info.size.width * info.size.height * 4);
      await map.readPixelsToBuffer(buffer);
      return { buffer: buffer, width: info.size.width, height: info.size.height };
    } catch (_error) {
      return null;
    } finally {
      if (map) map.release();
    }
  }

  /** Authenticate the LUT session and load the camera slot list. */
  private async refreshSession(): Promise<void> {
    if (this.connecting) return;
    this.connecting = true;
    this.sessionReady = false;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const imageUuid = await this.imageTransferUuid(context);
      let slotsError: LumixLutError | null = null;
      let connected = false;
      try {
        // 首选身份 = 图传线 BLE 已注册的 clientUuid + 官方 LUT AppInfo。
        // 注册槽已被占用时 registerIdentityOverBle 内部会跳过 BLE（不重注
        // 册、不断链），直接以已注册身份走 HTTP /auth（官方 LUMIX Lab 行为：
        // 首次连接注册一次，后续只确认 Wi-Fi 在线即直发指令）。
        this.session = await LumixLutService.openSessionWithIdentity(context, imageUuid, '', '');
        this.slots = await LumixLutService.fetchSlots(this.session);
        await LumixLutService.rememberIdentity(context, imageUuid);
        connected = true;
      } catch (firstError) {
        if (!(firstError instanceof LumixLutError) || firstError.code !== 401) {
          throw firstError instanceof Error ? firstError : new Error('读取相机 LUT 列表失败');
        }
        slotsError = firstError;
      }
      if (!connected) {
        // The camera hands out tokens at /auth but gates the LUT endpoints on
        // the BLE-registered client identity. The primary attempt above used
        // the image line's registered UUID with the LUT profile; fall back to
        // the image profile spelling, then the official LUT app's captured
        // identity (fresh camera without a retained link registers it).
        const candidates: LutIdentityCandidate[] = [
          { uuid: imageUuid, appInfo: IMAGE_APP_INFO, friendlyName: '' },
          { uuid: CAPTURE_LUT_UUID, appInfo: '', friendlyName: CAPTURE_LUT_FRIENDLY_NAME },
        ];
        for (const candidate of candidates) {
          if (candidate.uuid.length === 0) continue;
          try {
            this.session = await LumixLutService.openSessionWithIdentity(context, candidate.uuid,
              candidate.appInfo, candidate.friendlyName);
            this.slots = await LumixLutService.fetchSlots(this.session);
            if (candidate.uuid !== CAPTURE_LUT_UUID) {
              await LumixLutService.rememberIdentity(context, candidate.uuid);
            }
            connected = true;
            slotsError = null;
            break;
          } catch (candidateError) {
            if (!(candidateError instanceof LumixLutError) || candidateError.code !== 401) {
              throw candidateError instanceof Error ? candidateError : new Error('读取相机 LUT 列表失败');
            }
            slotsError = candidateError;
          }
        }
      }
      if (!connected) {
        if (slotsError !== null) {
          throw slotsError;
        }
        throw new Error('读取相机 LUT 列表失败');
      }
      const session = this.session;
      if (session === null) {
        throw new Error('与相机的 LUT 会话未建立');
      }
      this.sessionReady = true;
      const used = this.slots.filter((slot: LumixLutSlot): boolean => !slot.empty && this.isUserSlot(slot)).length;
      this.statusTitle = `已连接 ${session.ssid}`;
      this.statusDetail = `相机自定义 LUT 已占用 ${used}/${this.userSlotCount()} 个位置`;
    } catch (error) {
      this.session = null;
      this.slots = [];
      const message = error instanceof Error ? error.message : '连接相机失败';
      if (error instanceof LumixLutError) {
        this.statusTitle = this.titleForErrorKind(error.kind);
        if (error.code === 401) {
          this.statusDetail = `${message}；相机拒绝了 LUT 身份，可能需要官方 LUT App 的蓝牙注册（含证书凭证）后才开放 LUT 功能`;
        } else {
          this.statusDetail = `${message}；${this.hintForErrorKind(error.kind)}`;
        }
      } else {
        this.statusTitle = '连接相机失败';
        this.statusDetail = `${message}；请点击「重试」`;
      }
    } finally {
      this.connecting = false;
    }
  }

  /** Read-only image-transfer identity, offered to /auth as a fallback. */
  private async imageTransferUuid(context: common.UIAbilityContext): Promise<string> {
    try {
      return await LumixImportPrototype.persistentClientUuid(context);
    } catch (_error) {
      return '';
    }
  }

  private titleForErrorKind(kind: LumixLutErrorKind): string {
    switch (kind) {
      case 'wifi':
        return '未连接相机 Wi‑Fi';
      case 'ssid':
        return '当前 Wi‑Fi 不是相机热点';
      case 'gateway':
        return '相机网络未就绪';
      case 'auth':
        return '无法建立 LUT 会话';
      case 'slots':
        return '读取相机 LUT 列表失败';
      default:
        return '连接相机失败';
    }
  }

  private hintForErrorKind(kind: LumixLutErrorKind): string {
    switch (kind) {
      case 'wifi':
        return '请连接相机 Wi‑Fi 后点击「重试」';
      case 'ssid':
        return '请切换到相机热点后点击「重试」';
      case 'gateway':
        return '请稍候点击「重试」，或重新连接相机 Wi‑Fi';
      case 'auth':
        return '相机拒绝了 LUT 会话，请点击「重试」';
      case 'slots':
        return '请点击「重试」重新读取';
      default:
        return '请点击「重试」';
    }
  }

  /** Refresh the slot list after an import without touching the status card. */
  private async refreshSlotsQuietly(): Promise<void> {
    if (!this.session) return;
    try {
      this.slots = await LumixLutService.fetchSlots(this.session);
      if (this.sessionReady) {
        const used = this.slots.filter((slot: LumixLutSlot): boolean => !slot.empty && this.isUserSlot(slot)).length;
        this.statusDetail = `相机自定义 LUT 已占用 ${used}/${this.userSlotCount()} 个位置`;
      }
    } catch (_error) {
      // Keep the previous slot list when the refresh fails.
    }
  }

  /** Ask for confirmation, then delete the camera-side LUT via /lut/delete. */
  private requestDeleteSlot(slot: LumixLutSlot): void {
    if (!this.sessionReady || this.busySlotId >= 0 || this.importingIndex >= 0) return;
    if (!this.isUserSlot(slot) || slot.empty) return;
    this.getUIContext().getPromptAction().showDialog({
      title: '删除相机 LUT',
      message: `将删除相机位置 ${this.slotPosition(slot)} 的「${slot.lutName}」，该操作不可撤销。`,
      buttons: [
        { text: '取消', color: '#657286' },
        { text: '删除', color: '#D9534F' },
      ],
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.deleteCameraSlot(slot.lutId);
      }
    }).catch(() => {
    });
  }

  private async deleteCameraSlot(lutId: number): Promise<void> {
    const session = this.session;
    if (!session || this.busySlotId >= 0) return;
    this.busySlotId = lutId;
    const prompt = this.getUIContext().getPromptAction();
    try {
      await LumixLutService.deleteSlot(session, lutId);
      prompt.showToast({ message: `已删除相机位置 ${lutId - this.userSlotBase() + 1}` });
    } catch (error) {
      const message = error instanceof Error ? error.message : '未知错误';
      prompt.showToast({ message: `删除失败：${message}` });
    } finally {
      this.busySlotId = -1;
      this.refreshSlotsQuietly();
    }
  }

  private openRenameDialog(slot: LumixLutSlot): void {
    if (!this.sessionReady || this.busySlotId >= 0 || this.importingIndex >= 0) return;
    if (!this.isUserSlot(slot) || slot.empty) return;
    this.renameSlotId = slot.lutId;
    this.renameSlotName = slot.lutName;
    this.renameInput = slot.lutName;
    this.renameVisible = true;
  }

  private async confirmRename(): Promise<void> {
    const slotId = this.renameSlotId;
    const name = this.sanitizeCameraLutName(this.renameInput);
    if (slotId < 2 || name.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请输入有效的新名称' });
      return;
    }
    this.renameVisible = false;
    const session = this.session;
    if (!session || this.busySlotId >= 0) return;
    this.busySlotId = slotId;
    const prompt = this.getUIContext().getPromptAction();
    try {
      await LumixLutService.renameSlot(session, slotId, name);
      prompt.showToast({ message: `已重命名相机位置 ${slotId - this.userSlotBase() + 1}` });
    } catch (error) {
      const message = error instanceof Error ? error.message : '未知错误';
      prompt.showToast({ message: `重命名失败：${message}` });
    } finally {
      this.busySlotId = -1;
      this.refreshSlotsQuietly();
    }
  }

  /** Strip control chars / .cube/.vlt extension; cap at 32 chars. */
  private sanitizeCameraLutName(input: string): string {
    let name = input.replace(/[\u0000-\u001F\u007F]/g, '').trim();
    name = name.replace(/\.(cube|vlt)$/i, '');
    return name.substring(0, 32);
  }

  /** File-system-safe base name for a downloaded camera LUT. */
  private downloadFileNameFor(slot: LumixLutSlot): string {
    const base = this.sanitizeCameraLutName(slot.lutName)
      .replace(/[\\/:*?"<>|]/g, '_');
    return base.length > 0 ? base : `camera_lut_${slot.lutId}`;
  }

  /**
   * Download a camera-side LUT via /lut/file, save it into the system
   * Documents folder, then open the same import-confirm flow as the main
   * page's 导入 LUT button (LutLibraryStore.setPending + LutImportConfirmPage).
   */
  private async downloadCameraSlot(slot: LumixLutSlot): Promise<void> {
    const session = this.session;
    if (!session || this.busySlotId >= 0 || this.importingIndex >= 0) return;
    if (!this.isUserSlot(slot) || slot.empty) return;
    this.busySlotId = slot.lutId;
    const prompt = this.getUIContext().getPromptAction();
    try {
      const raw = await LumixLutService.fetchLutFile(session, slot.lutId);
      const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(raw));
      if (text.trim().startsWith('{')) {
        // A JSON envelope means /lut/file answered with an error structure
        // instead of the raw payload; its exact shape is not captured yet.
        throw new Error('相机返回的不是 LUT 文件内容（/lut/file 报文格式待校准）');
      }
      const filename = this.downloadFileNameFor(slot);
      const imported = parseLutText(text, `${filename}.cube`);
      if (!imported || !imported.table) {
        throw new Error('相机 LUT 内容解析失败');
      }
      // 诊断：S1RM2 /lut/info 名称被固件变换——若 .cube 的 TITLE 是明文
      // 名称，则以文件名为准显示（官方 App 同源路径）。
      console.info(`VIVID_LUT cube title name=${imported.name} slot=${slot.lutId} infoName=${slot.lutName}`);
      if (imported.name.trim().length === 0) {
        imported.name = slot.lutName;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = [`${filename}.cube`];
      const savePicker = new picker.DocumentViewPicker(context);
      const uris = await savePicker.save(saveOptions);
      if (!uris || uris.length === 0) {
        return;
      }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE);
      try {
        fileIo.writeSync(file.fd, raw);
      } finally {
        fileIo.closeSync(file);
      }
      for (const entry of LutLibraryStore.entriesSnapshot()) {
        if (entry.sourceUri === uris[0]) {
          prompt.showToast({ message: '该 LUT 已在库中' });
          return;
        }
      }
      imported.sourceUri = uris[0];
      imported.category = '自定义';
      imported.coverUri = 'resource://vivid_cover';
      imported.sampleUri = 'resource://vivid_cover';
      LutLibraryStore.setPending(imported);
      this.getUIContext().getRouter().pushUrl({ url: 'pages/LutImportConfirmPage' });
    } catch (error) {
      const message = error instanceof Error ? error.message : '未知错误';
      prompt.showToast({ message: `下载失败：${message}` });
    } finally {
      this.busySlotId = -1;
    }
  }

  /** 用户槽起点 LutId：从相机返回的数据动态推导（首个 lutType=3 的槽），
   *  各 Lab 机型内置库长度不同，硬编码 2 会错位（2026-09-28 S1RM2 验证
   *  布局与 S5M2 一致，但保留自适应以兼容后续机型）。 */
  private userSlotBase(): number {
    for (const slot of this.slots) {
      if (slot.lutType === 3) {
        return slot.lutId;
      }
    }
    return 2;
  }

  /** 用户槽数量（lutType=3 的槽数）。 */
  private userSlotCount(): number {
    let count = 0;
    for (const slot of this.slots) {
      if (slot.lutType === 3) {
        count += 1;
      }
    }
    return count > 0 ? count : 39;
  }

  /** 是否用户槽（类型 3；类型未知时按 LutId 起点兜底）。 */
  private isUserSlot(slot: LumixLutSlot): boolean {
    return slot.lutType === 3 || slot.lutId >= this.userSlotBase();
  }

  /** 用户槽的展示位置号（1 起）。 */
  private slotPosition(slot: LumixLutSlot): number {
    return slot.lutId - this.userSlotBase() + 1;
  }

  private openPicker(index: number): void {
    if (!this.sessionReady || this.importingIndex >= 0) return;
    this.pickerLutIndex = index;
    let preferred = -1;
    for (const slot of this.slots) {
      if (this.isUserSlot(slot) && slot.empty) {
        preferred = slot.lutId;
        break;
      }
    }
    this.pickerSlotId = preferred;
    this.pickerVisible = true;
  }

  private selectSlot(slot: LumixLutSlot): void {
    if (!this.isUserSlot(slot)) return;
    this.pickerSlotId = slot.lutId;
  }

  private async confirmImport(): Promise<void> {
    const lutIndex = this.pickerLutIndex;
    const slotId = this.pickerSlotId;
    if (lutIndex < 0 || slotId < 0) return;
    this.pickerVisible = false;
    await this.runImport(lutIndex, slotId, false);
  }

  /** Continue the last failed import: rebuild the session, resend the LUT. */
  private async retryImport(): Promise<void> {
    const index = this.failedIndex;
    const slotId = this.failedSlotId;
    if (index < 0 || slotId < 0) return;
    await this.runImport(index, slotId, true);
  }

  /**
   * Stream one bundled LUT into the chosen camera slot. With forceReauth the
   * LUT session is rebuilt first, so a retry after a broken transfer resumes
   * on a fresh session (the chunked upload restarts from the beginning
   * because the camera protocol exposes no mid-file resume).
   */
  private async runImport(index: number, slotId: number, forceReauth: boolean): Promise<void> {
    const lut = this.luts[index];
    if (!lut || this.importingIndex >= 0) return;
    if (this.failedIndex === index) {
      this.failedIndex = -1;
      this.failedSlotId = -1;
      this.failedMessage = '';
    }
    this.importingIndex = index;
    this.importProgress = 0;
    this.importPhase = '正在读取 LUT…';
    try {
      if (forceReauth || !this.session) {
        this.importPhase = '正在连接相机…';
        await this.refreshSession();
      }
      const session = this.session;
      if (!session) {
        throw new Error('与相机的 LUT 会话未建立');
      }
      const payload = await this.loadLutPayload(lut);
      this.importPhase = '正在传输…';
      await LumixLutService.sendLut(session, payload.filename, payload.bytes, slotId,
        (state: LumixLutSendState): void => {
          this.importProgress = state.totalBytes > 0 ? state.sentBytes / state.totalBytes : 0;
          this.importPhase = `传输中 ${state.chunkIndex}/${state.totalChunks} 块`;
        });
      // S1RM2 实测（2026-09-29 14:16）：/lut/send 全 200/Result=0 不代表
      // 落库——相机收完后做内容校验，17 点 .cube 被拒且目标槽位连同原有
      // LUT 一起被清空（位置 2 的 Candy color style 即因此丢失）。等落盘
      // 完成后回读槽位名，确认真的写进去了再报成功。
      this.importPhase = '正在验证落库…';
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 2200);
      });
      let landedName = '';
      try {
        const verifiedSlots = await LumixLutService.fetchSlots(session);
        for (const verified of verifiedSlots) {
          if (verified.lutId === slotId) {
            landedName = verified.lutName;
            break;
          }
        }
        this.slots = verifiedSlots;
      } catch (verifyError) {
        // 回读失败不误报传输失败：send 本身已全部 200 完成。
        landedName = payload.filename;
      }
      if (landedName.length === 0) {
        throw new Error('相机拒绝了该 LUT（内容校验未通过，槽位已被相机清空）');
      }
      this.getUIContext().getPromptAction()
        .showToast({ message: `已将「${lut.name}」导入相机位置 ${slotId - this.userSlotBase() + 1}，相机存名「${landedName}」` });
    } catch (error) {
      const message = error instanceof Error ? error.message : '未知错误';
      this.failedIndex = index;
      this.failedSlotId = slotId;
      this.failedMessage = message;
      this.getUIContext().getPromptAction().showToast({ message: `导入失败：${message}` });
      if (!forceReauth && this.session) {
        // The cached session may have gone stale mid-send; re-validate it so
        // the status card reflects the real link state.
        this.refreshSession();
      }
    } finally {
      this.importingIndex = -1;
      this.importPhase = '';
      this.importProgress = 0;
      // S1RM2 实测：最后一块的 HTTP 应答先于相机落盘（协议报告注明
      // flush 约 1.2s）。发送后立即读 /lut/info 会打断提交——2026-09-28
      // 16:18 发送全 200 但位置 2 未落库即此因。等待落盘完成再刷新。
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 2200);
      });
      this.refreshSlotsQuietly();
    }
  }

  /**
   * Read a bundled LUT as transfer bytes. .cube files stream their original
   * bytes unchanged; .vlt sources are parsed and re-serialized as standard
   * .cube text, matching what the camera's LUT endpoint accepts.
   * 上传名称保留原始名（含中文）：旧版 asciiCameraName 把中文全部替换
   * 成下划线，相机存的名称丢失中文（2026-09-28 S1RM2 名称乱码排查的
   * 上传侧根因之一）。原始名为空时才回退 ASCII 安全名。
   */
  private lutWireName(lut: TransferableLut): string {
    const raw = lut.name.trim();
    if (raw.length === 0) {
      return lut.asciiName;
    }
    // 只去除扩展名与控制字符，保留中文。
    return raw.replace(/\.[^.]+$/, '').replace(/[\u0000-\u001F\u007F]/g, '').trim();
  }

  /** 三线性重采样到 33³（相机端标准尺寸）。S1RM2 对非 33 尺寸的 .cube
   *  静默丢弃（2026-09-28 实测：65³ 全 200 但槽位不落库）。 */
  private resampleLutTable(table: LutTable, outSize: number): number[] {
    const n = table.size;
    const out = new Array<number>(outSize * outSize * outSize * 3);
    const at = (r: number, g: number, b: number, c: number): number => {
      const idx = (r * n * n + g * n + b) * 3 + c;
      return table.values[idx];
    };
    const lerp = (a: number, b: number, t: number): number => a + (b - a) * t;
    const scale = (n - 1) / (outSize - 1);
    for (let r = 0; r < outSize; r++) {
      const fr = Math.min(r * scale, n - 1);
      const r0 = Math.floor(fr);
      const r1 = Math.min(r0 + 1, n - 1);
      const tr = fr - r0;
      for (let g = 0; g < outSize; g++) {
        const fg = Math.min(g * scale, n - 1);
        const g0 = Math.floor(fg);
        const g1 = Math.min(g0 + 1, n - 1);
        const tg = fg - g0;
        for (let b = 0; b < outSize; b++) {
          const fb = Math.min(b * scale, n - 1);
          const b0 = Math.floor(fb);
          const b1 = Math.min(b0 + 1, n - 1);
          const tb = fb - b0;
          const oi = (r * outSize * outSize + g * outSize + b) * 3;
          for (let c = 0; c < 3; c++) {
            const c000 = at(r0, g0, b0, c);
            const c001 = at(r0, g0, b1, c);
            const c010 = at(r0, g1, b0, c);
            const c011 = at(r0, g1, b1, c);
            const c100 = at(r1, g0, b0, c);
            const c101 = at(r1, g0, b1, c);
            const c110 = at(r1, g1, b0, c);
            const c111 = at(r1, g1, b1, c);
            const c00 = lerp(c000, c100, tr);
            const c01 = lerp(c001, c101, tr);
            const c10 = lerp(c010, c110, tr);
            const c11 = lerp(c011, c111, tr);
            const c0 = lerp(c00, c10, tg);
            const c1 = lerp(c01, c11, tg);
            out[oi + c] = lerp(c0, c1, tb);
          }
        }
      }
    }
    return out;
  }

  /** 相机线名：仅字母/数字/连字符/空格。2026-09-28 S1RM2 实测——下划线
   *  名（"skin_optimize"/"user_lut"）被静默丢弃，纯字母数字名
   *  （"Sample LUT1"/"Candy color style"/"Smoky Color-S"）正常落库。 */
  private cameraWireName(lut: TransferableLut): string {
    const source = lut.asciiName.length > 0 ? lut.asciiName : lut.name;
    let out = '';
    for (const ch of source) {
      if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
        ch === '-' || ch === ' ') {
        out += ch;
      } else {
        out += ' ';
      }
    }
    out = out.replace(/ +/g, ' ').trim();
    return out.length > 0 ? out.substring(0, 31) : 'User Lut';
  }

  private async loadLutPayload(lut: TransferableLut): Promise<LutPayload> {
    // S1RM2 实测约束（2026-09-28）：
    //  1) 名称（send-prepare filename 与 TITLE）仅字母/数字/连字符/空格——
    //     中文与下划线被静默丢弃；
    //  2) .vlt 为相机原生格式原样直发（17³/33³ 均合规）；
    //  3) .cube 需 33³（65³ 静默丢弃，已重采样适配），合规字节原样透传。
    // 中文显示名保留在 Pixelshop 本地列表；相机菜单显示 ASCII 线名。
    const wireName = this.cameraWireName(lut);
    let text = '';
    if (lut.isCustom) {
      text = readLutText(lut.path);
    } else {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const data = await context.resourceManager.getRawFileContent(lut.path);
      const source = this.copyBytes(data);
      text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(source));
    }
    const parsed = parseLutText(text, lut.path);
    const table = parsed && parsed.table ? parsed.table : null;
    if (!table || !parsed) {
      throw new Error('LUT 解析失败，无法转换为 .cube');
    }
    // .vlt 是 Panasonic 原生推荐格式：原样透传，不转换（用户调研确认
    // Lumix 相机原生支持 .VLT；.cube 仅新机型支持且需 33³ 规格）。
    const lowerPath = lut.path.toLowerCase();
    if (lowerPath.endsWith('.vlt')) {
      console.info(`VIVID_LUT send decision=vlt raw size=${text.length} wire=${wireName}`);
      const encoded = util.TextEncoder.create('utf-8').encode(text);
      const vltPayload: LutPayload = { filename: wireName, bytes: this.copyBytes(encoded) };
      return vltPayload;
    }
    const parsedTitle = parsed.name.trim();
    const titleOk = parsedTitle.length > 0 && /^[\x20-\x7E]+$/.test(parsedTitle) &&
      parsedTitle !== 'Generated by Resolve';
    // 原样透传仅限 .cube 源且合规（33³ + 有效 ASCII TITLE）。
    const isCubeSource = lowerPath.endsWith('.cube');
    if (isCubeSource && table.size === 33 && titleOk) {
      // 合规 .cube（如相机下载的原版文件、用户自备 ASCII TITLE 文件）：
      // 原样透传，相机对自己吐出的字节最宽容。
      console.info(`VIVID_LUT send decision=raw title=${parsedTitle} size=${table.size} wire=${wireName}`);
      const encoded = util.TextEncoder.create('utf-8').encode(text);
      const direct: LutPayload = { filename: wireName, bytes: this.copyBytes(encoded) };
      return direct;
    }
    console.info(`VIVID_LUT send decision=rebuild title=${parsedTitle} size=${table.size} wire=${wireName}`);
    const outSize = 33;
    const values = table.size === outSize ? table.values : this.resampleLutTable(table, outSize);
    const lines: string[] = [
      'TITLE "' + wireName + '"',
      'LUT_3D_SIZE ' + outSize.toString(),
      'DOMAIN_MIN ' + table.domainMin[0].toFixed(6) + ' ' + table.domainMin[1].toFixed(6) + ' ' +
        table.domainMin[2].toFixed(6),
      'DOMAIN_MAX ' + table.domainMax[0].toFixed(6) + ' ' + table.domainMax[1].toFixed(6) + ' ' +
        table.domainMax[2].toFixed(6),
    ];
    for (let index = 0; index + 2 < values.length; index += 3) {
      lines.push(values[index].toFixed(6) + ' ' + values[index + 1].toFixed(6) + ' ' +
        values[index + 2].toFixed(6));
    }
    const encoded = util.TextEncoder.create('utf-8').encode(lines.join('\n') + '\n');
    const converted: LutPayload = { filename: wireName, bytes: this.copyBytes(encoded) };
    return converted;
  }

  /** Return an exact-size ArrayBuffer copy of a byte view. */
  private copyBytes(data: Uint8Array): ArrayBuffer {
    if (data.byteOffset === 0 && data.byteLength === data.buffer.byteLength) {
      return data.buffer as ArrayBuffer;
    }
    return data.slice().buffer as ArrayBuffer;
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('‹')
            .fontSize(34)
            .fontColor('#1B2536')
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
          Text('LUT 传输')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1B2536')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Blank().width(34)
        }
        .width('100%')
        .height(62)
        .padding({ left: 14, right: 14 })
        this.TabBar()
        this.StatusCard()
        Scroll() {
          Column() {
            if (this.activeTab === 0) {
              ForEach(this.luts, (lut: TransferableLut, index: number) => {
                this.LutRow(lut, index)
              }, (lut: TransferableLut) => lut.path)
            } else {
              this.CameraTabList()
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 40 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .safeAreaPadding({ top: 24 })
      if (this.pickerVisible) {
        this.SlotPickerOverlay()
      }
      if (this.renameVisible) {
        this.RenameOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .linearGradient({ angle: 160, colors: [['#F3F6FC', 0], ['#E9EFF9', 1]] })
  }

  @Builder
  TabBar() {
    Row({ space: 8 }) {
      Text('本机 LUT')
        .fontSize(12)
        .fontWeight(this.activeTab === 0 ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.activeTab === 0 ? '#316CF4' : '#7B8798')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .padding({ top: 8, bottom: 8 })
        .borderRadius(20)
        .backgroundColor(this.activeTab === 0 ? 'rgba(49,108,244,0.12)' : 'rgba(255,255,255,0.60)')
        .border({ width: 1, color: this.activeTab === 0 ? 'rgba(49,108,244,0.30)' : 'rgba(203,213,228,0.55)' })
        .onClick(() => {
          this.activeTab = 0;
        })
      Text('相机 LUT')
        .fontSize(12)
        .fontWeight(this.activeTab === 1 ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.activeTab === 1 ? '#316CF4' : '#7B8798')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .padding({ top: 8, bottom: 8 })
        .borderRadius(20)
        .backgroundColor(this.activeTab === 1 ? 'rgba(49,108,244,0.12)' : 'rgba(255,255,255,0.60)')
        .border({ width: 1, color: this.activeTab === 1 ? 'rgba(49,108,244,0.30)' : 'rgba(203,213,228,0.55)' })
        .onClick(() => {
          this.activeTab = 1;
          if (this.sessionReady) {
            this.refreshSlotsQuietly();
          }
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .margin({ top: 4 })
  }

  @Builder
  CameraTabList() {
    if (this.slots.length === 0) {
      Column() {
        Text(this.connecting ? '正在连接相机…' : '尚未读取到相机 LUT 列表')
          .fontSize(12)
          .fontColor('#A6AFBC')
        if (!this.connecting && !this.sessionReady) {
          Button('重试连接')
            .fontSize(11)
            .fontColor('#316CF4')
            .type(ButtonType.Capsule)
            .backgroundColor('rgba(49,108,244,0.12)')
            .height(30)
            .margin({ top: 10 })
            .onClick(() => {
              this.refreshSession();
            })
        }
      }
      .width('100%')
      .padding({ top: 48 })
    } else {
      ForEach(this.slots, (slot: LumixLutSlot) => {
        this.CameraSlotRow(slot)
      }, (slot: LumixLutSlot) => 'cam:' + slot.lutId.toString() + ':' + slot.lutName)
    }
  }

  @Builder
  CameraSlotRow(slot: LumixLutSlot) {
    Row() {
      Column() {
        Text(!this.isUserSlot(slot) ? slot.lutName : `位置 ${this.slotPosition(slot)}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(!this.isUserSlot(slot) ? '#A6AFBC' : '#1B2536')
        Text(!this.isUserSlot(slot) ? '相机内置 LUT，不可修改' : (slot.empty ? '空位' : `当前：${slot.lutName}`))
          .fontSize(9)
          .fontColor(!this.isUserSlot(slot) ? '#C2C9D4' : (slot.empty ? '#1E8E5A' : '#7B8798'))
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (slot.lutId >= 2 && !slot.empty) {
        if (this.busySlotId === slot.lutId) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color('#316CF4')
        } else {
          Button('下载')
            .fontSize(10)
            .fontColor('#1E8E5A')
            .type(ButtonType.Capsule)
            .backgroundColor('rgba(30,142,90,0.12)')
            .height(28)
            .padding({ left: 10, right: 10 })
            .enabled(this.busySlotId < 0 && this.importingIndex < 0)
            .onClick(() => {
              this.downloadCameraSlot(slot);
            })
          Button('重命名')
            .fontSize(10)
            .fontColor('#316CF4')
            .type(ButtonType.Capsule)
            .backgroundColor('rgba(49,108,244,0.12)')
            .height(28)
            .padding({ left: 10, right: 10 })
            .margin({ left: 6 })
            .enabled(this.busySlotId < 0 && this.importingIndex < 0)
            .onClick(() => {
              this.openRenameDialog(slot);
            })
          Button('删除')
            .fontSize(10)
            .fontColor('#D9534F')
            .type(ButtonType.Capsule)
            .backgroundColor('rgba(217,83,79,0.12)')
            .height(28)
            .padding({ left: 10, right: 10 })
            .margin({ left: 6 })
            .enabled(this.busySlotId < 0 && this.importingIndex < 0)
            .onClick(() => {
              this.requestDeleteSlot(slot);
            })
        }
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(18)
    .backgroundColor('rgba(255,255,255,0.78)')
    .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
    .margin({ bottom: 10 })
  }

  @Builder
  RenameOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(13,21,36,0.48)')
        .onClick(() => {
          this.renameVisible = false;
        })
      Column() {
        Text('重命名相机 LUT')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B2536')
          .width('100%')
        Text(this.renameSlotId >= 2 ? `位置 ${this.renameSlotId - 1} 当前名称：${this.renameSlotName}` : '输入新名称')
          .fontSize(10)
          .fontColor('#7B8798')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
        TextInput({ text: this.renameInput, placeholder: '输入新名称' })
          .fontSize(14)
          .fontColor('#1B2536')
          .height(44)
          .backgroundColor('#F3F6FC')
          .borderRadius(12)
          .margin({ top: 14 })
          .onChange((value: string) => {
            this.renameInput = value;
          })
        Text('新名称会同步显示到相机的 LUT 列表，无需 .cube 扩展名，建议使用 ASCII 字符')
          .fontSize(9)
          .fontColor('#A6AFBC')
          .width('100%')
          .margin({ top: 8 })
        Row() {
          Button('取消')
            .fontSize(13)
            .fontColor('#536176')
            .type(ButtonType.Capsule)
            .backgroundColor('#E3E8F0')
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.renameVisible = false;
            })
          Button('确认重命名')
            .fontSize(13)
            .fontColor(this.renameInput.trim().length > 0 ? '#FFFFFF' : '#A6AFBC')
            .type(ButtonType.Capsule)
            .backgroundColor(this.renameInput.trim().length > 0 ? '#316CF4' : '#D1D5DB')
            .height(40)
            .layoutWeight(1)
            .margin({ left: 10 })
            .enabled(this.renameInput.trim().length > 0)
            .onClick(() => {
              this.confirmRename();
            })
        }
        .width('100%')
        .margin({ top: 18 })
      }
      .width('82%')
      .padding(20)
      .borderRadius(24)
      .backgroundColor('#FFFFFF')
      .shadow({ radius: 28, color: 'rgba(18,32,60,0.24)', offsetY: 10 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  StatusCard() {
    Row() {
      Text(this.sessionReady ? '●' : '○')
        .fontSize(14)
        .fontColor(this.sessionReady ? '#1E8E5A' : '#A6AFBC')
      Column() {
        Text(this.connecting ? '正在连接相机…' : this.statusTitle)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B2536')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.statusDetail)
          .fontSize(10)
          .fontColor('#7B8798')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      if (!this.sessionReady && !this.connecting) {
        Button('重试')
          .fontSize(11)
          .fontColor('#316CF4')
          .type(ButtonType.Capsule)
          .backgroundColor('rgba(49,108,244,0.12)')
          .height(30)
          .onClick(() => {
            this.refreshSession();
          })
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(20)
    .backgroundColor('rgba(255,255,255,0.72)')
    .border({ width: 1, color: 'rgba(203,213,228,0.80)' })
    .margin({ left: 16, right: 16, top: 6 })
  }

  @Builder
  LutRow(lut: TransferableLut, index: number) {
    Row() {
      Image(this.thumbFor(lut))
        .width(64)
        .height(48)
        .objectFit(ImageFit.Cover)
        .borderRadius(10)
      Column() {
        Text(lut.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1B2536')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(lut.author.length > 0 ? lut.author : '未知作者')
          .fontSize(9)
          .fontColor('#7B8798')
          .margin({ top: 3 })
        Text(lut.isCustom ? '本机自定义 LUT' : (lut.needsConversion ? 'VLT 将转换为 .cube 后传输' : '内置 .cube 直接传输'))
          .fontSize(9)
          .fontColor('#A6AFBC')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
      if (this.importingIndex === index) {
        Column() {
          Progress({ value: Math.round(this.importProgress * 100), total: 100, type: ProgressType.Linear })
            .width(88)
            .height(6)
            .color('#316CF4')
          Text(this.importPhase)
            .fontSize(9)
            .fontColor('#316CF4')
            .margin({ top: 5 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.End)
        .width(110)
      } else if (this.failedIndex === index) {
        Column() {
          Text('导入失败，可重试')
            .fontSize(9)
            .fontColor('#D9534F')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('重试导入')
            .fontSize(11)
            .fontColor('#D9534F')
            .type(ButtonType.Capsule)
            .backgroundColor('rgba(217,83,79,0.12)')
            .height(30)
            .margin({ top: 5 })
            .onClick(() => {
              this.retryImport();
            })
        }
        .alignItems(HorizontalAlign.End)
        .width(110)
      } else {
        Button('导入')
          .fontSize(12)
          .fontColor(this.sessionReady && this.importingIndex < 0 ? '#316CF4' : '#A6AFBC')
          .type(ButtonType.Capsule)
          .backgroundColor(this.sessionReady && this.importingIndex < 0 ?
            'rgba(49,108,244,0.12)' : 'rgba(225,232,243,0.86)')
          .height(32)
          .enabled(this.sessionReady && this.importingIndex < 0)
          .onClick(() => {
            this.openPicker(index);
          })
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(18)
    .backgroundColor('rgba(255,255,255,0.78)')
    .border({ width: 1, color: 'rgba(203,213,228,0.55)' })
    .margin({ bottom: 10 })
  }

  @Builder
  SlotPickerOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(13,21,36,0.48)')
        .onClick(() => {
          this.pickerVisible = false;
        })
      Column() {
        Text('选择相机 LUT 位置')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B2536')
          .width('100%')
        Text(this.pickerLutIndex >= 0 && this.luts[this.pickerLutIndex] ?
          `「${this.luts[this.pickerLutIndex].name}」将写入所选位置，原内容会被覆盖` : '选择要写入的相机 LUT 位置')
          .fontSize(10)
          .fontColor('#7B8798')
          .width('100%')
          .margin({ top: 6, bottom: 12 })
        Scroll() {
          Column() {
            ForEach(this.slots, (slot: LumixLutSlot) => {
              this.SlotRow(slot)
            }, (slot: LumixLutSlot) => 'slot:' + slot.lutId.toString() + ':' + slot.lutName)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Fade)
        Row() {
          Button('取消')
            .fontSize(13)
            .fontColor('#536176')
            .type(ButtonType.Capsule)
            .backgroundColor('#E3E8F0')
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.pickerVisible = false;
            })
          Button('确认导入 LUT')
            .fontSize(13)
            .fontColor(this.pickerSlotId >= 0 ? '#FFFFFF' : '#A6AFBC')
            .type(ButtonType.Capsule)
            .backgroundColor(this.pickerSlotId >= 0 ? '#316CF4' : '#D1D5DB')
            .height(40)
            .layoutWeight(1)
            .margin({ left: 10 })
            .enabled(this.pickerSlotId >= 0)
            .onClick(() => {
              this.confirmImport();
            })
        }
        .width('100%')
        .margin({ top: 14 })
      }
      .width('88%')
      .height(520)
      .padding(20)
      .borderRadius(24)
      .backgroundColor('#FFFFFF')
      .shadow({ radius: 28, color: 'rgba(18,32,60,0.24)', offsetY: 10 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SlotRow(slot: LumixLutSlot) {
    Row() {
      Column() {
        Text(!this.isUserSlot(slot) ? slot.lutName : `位置 ${this.slotPosition(slot)}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(!this.isUserSlot(slot) ? '#A6AFBC' : '#1B2536')
        Text(!this.isUserSlot(slot) ? '相机内置 LUT，不可覆盖' :
          (slot.empty ? '空位，可直接导入' : `当前：${slot.lutName}`))
          .fontSize(9)
          .fontColor(!this.isUserSlot(slot) ? '#C2C9D4' : (slot.empty ? '#1E8E5A' : '#7B8798'))
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Blank()
      if (this.isUserSlot(slot) && this.pickerSlotId === slot.lutId) {
        Text('✓')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#316CF4')
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.isUserSlot(slot) && this.pickerSlotId === slot.lutId ?
      'rgba(49,108,244,0.10)' : 'rgba(0,0,0,0)')
    .onClick(() => {
      this.selectSlot(slot);
    })
  }
}
