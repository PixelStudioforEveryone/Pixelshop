import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { LutLibraryStore, CustomLut, saveSampleOverride, lutCacheToken, lutDisplayUri } from '../edit/models/LutLibrary';
import { applyLutStack } from '../edit/engine/WorkerCore';
import { WorkerLut } from '../edit/engine/ProcessWorker';
import { GpuShaderBridge } from '../edit/engine/GpuShaderBridge';
import { PixelMapUtils } from '../edit/utils/PixelMapUtils';
import { LutLoader } from '../edit/utils/LutLoader';
import { RecentPhotoStore } from '../services/RecentPhotoStore';

/** 碰一碰分享包结构：效果图 + LUT 数据 + 说明合并为单个 JSON 文件。 */
interface KnockLutPackage {
  pixelshopLutPackage: number;
  name: string;
  author: string;
  description: string;
  format: string;
  sharedAt: number;
  lutFileName: string;
  lutText: string;
  previewBase64: string;
}

/** Detail route shared by the LUT library and editor candidates. */
@Entry
@Component
struct LutDetailPage {
  @State private lut: CustomLut | null = null;
  @State private split: number = 0.5;
  private splitStart: number = 0.5;
  @State private previewWidth: number = 1;
  @State private sampleIndex: number = 0;
  @State private beforeMap: image.PixelMap | null = null;
  @State private afterMap: image.PixelMap | null = null;
  // 碰一碰分享：预生成的 LUT 分享包（效果图 + LUT 数据 + 说明）缓存路径。
  private knockPackagePath: string = '';
  private knockPreviewPath: string = '';
  private knockPreparing: boolean = false;
  private knockRegistered: boolean = false;
  private disposed: boolean = false;
  private knockShareCallback = (target: harmonyShare.SharableTarget): void => {
    this.onKnockShare(target);
  };

  aboutToAppear(): void {
    this.disposed = false;
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    const id = params && params['lutId'] ? params['lutId'] as string : '';
    this.lut = LutLibraryStore.find(id) ?? null;
    // Let the route paint first; LUT sampling is intentionally deferred to the
    // low-resolution preview path so opening a card never blocks navigation.
    if (this.lut) setTimeout(() => { if (this.lut) this.loadPreview(this.lut); }, 0);
  }

  onPageShow(): void {
    this.registerKnockShare();
  }

  onPageHide(): void {
    this.unregisterKnockShare();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.unregisterKnockShare();
    if (this.beforeMap) this.beforeMap.release();
    if (this.afterMap) this.afterMap.release();
    this.beforeMap = null;
    this.afterMap = null;
  }

  /** 注册碰一碰分享事件：两台手机顶部轻碰即可把当前 LUT 发给对方。 */
  private registerKnockShare(): void {
    if (this.knockRegistered) return;
    try {
      if (canIUse('SystemCapability.Collaboration.HarmonyShare')) {
        harmonyShare.on('knockShare', this.knockShareCallback);
        this.knockRegistered = true;
      }
    } catch (_error) {
      // 不支持碰一碰的设备保持静默，页面其余功能不受影响。
    }
  }

  private unregisterKnockShare(): void {
    if (!this.knockRegistered) return;
    try {
      harmonyShare.off('knockShare', this.knockShareCallback);
    } catch (_error) {
    }
    this.knockRegistered = false;
  }

  private onKnockShare(target: harmonyShare.SharableTarget): void {
    const lut = this.lut;
    if (!lut || !lut.table || this.knockPackagePath.length === 0) {
      target.clarifyNonShare({ message: 'LUT 效果图尚未生成，请稍后再碰' });
      return;
    }
    try {
      const record: systemShare.SharedRecord = {
        utd: utd.getUniformDataTypeByFilenameExtension('.json'),
        uri: fileUri.getUriFromPath(this.knockPackagePath),
        thumbnailUri: this.knockPreviewPath.length > 0
          ? fileUri.getUriFromPath(this.knockPreviewPath) : undefined,
        title: `Pixelshop LUT · ${lut.name}`,
        description: lut.author && lut.author.length > 0
          ? `${lut.author} 的 LUT` : '碰一碰分享的 Pixelshop LUT',
      };
      target.share(new systemShare.SharedData(record));
    } catch (_error) {
      target.clarifyNonShare({ message: 'LUT 分享包不可用，请重新进入本页再试' });
    }
  }

  /**
   * 预生成碰一碰分享包：单个 JSON 文件内嵌效果图（base64 JPEG）、完整
   * .cube LUT 数据和说明信息（名称/作者/描述）。指定应用直达仅支持单个
   * 非媒体文件，因此三项内容合并为一个包文件，接收端再拆开还原。
   */
  private async prepareKnockPackage(): Promise<void> {
    const lut = this.lut;
    const after = this.afterMap;
    if (!lut || !lut.table || !after || this.knockPreparing) return;
    this.knockPreparing = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const jpeg = await PixelMapUtils.encodeToJpeg(after, 86);
      if (!jpeg) return;
      const base64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(jpeg));
      // 预览文件供分享卡片缩略图使用。
      const token = lutCacheToken(lut.name);
      const previewPath = context.cacheDir + '/knock_lut_preview_' + token + '.jpg';
      const previewFile = fileIo.openSync(previewPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(previewFile.fd, jpeg);
      } finally {
        fileIo.closeSync(previewFile);
      }
      // 从已解析的 LUT 表重新生成 .cube 文本，不依赖可能已失去读取授权的原始文件。
      const table = lut.table;
      const lines: string[] = ['TITLE "' + lut.name.replace(/["\r\n]/g, ' ') + '"',
        'LUT_3D_SIZE ' + table.size.toString(),
        'DOMAIN_MIN ' + table.domainMin.join(' '),
        'DOMAIN_MAX ' + table.domainMax.join(' ')];
      for (let i = 0; i < table.values.length; i += 3) {
        lines.push(table.values[i].toFixed(7) + ' ' + table.values[i + 1].toFixed(7) + ' ' + table.values[i + 2].toFixed(7));
      }
      const packageJson: KnockLutPackage = {
        pixelshopLutPackage: 1,
        name: lut.name,
        author: lut.author ?? '',
        description: lut.description ?? '',
        format: lut.format ?? 'cube',
        sharedAt: Date.now(),
        lutFileName: token + '.cube',
        lutText: lines.join('\n') + '\n',
        previewBase64: base64,
      };
      const packagePath = context.cacheDir + '/knock_lut_' + token + '.json';
      const packageFile = fileIo.openSync(packagePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(packageFile.fd, JSON.stringify(packageJson));
      } finally {
        fileIo.closeSync(packageFile);
      }
      this.knockPackagePath = packagePath;
      this.knockPreviewPath = previewPath;
    } catch (_error) {
      // 分享包生成失败时碰一碰回调会走 clarifyNonShare 提示。
    } finally {
      this.knockPreparing = false;
    }
  }

  private lutReferenceResource(lut: CustomLut) {
    switch (lut.referenceKey ?? '') {
      case 'sunny_mint': return $r('app.media.lut_ref_sunny_mint');
      case 'japanese_cyan': return $r('app.media.lut_ref_japanese_cyan');
      case 'fresh_food': return $r('app.media.lut_ref_fresh_food');
      case 'healing_light': return $r('app.media.lut_ref_healing_light');
      case 'snow_portrait': return $r('app.media.lut_ref_snow_portrait');
      case 'seaside_portrait': return $r('app.media.lut_ref_seaside_portrait');
      case 'nc_classic_neg': return $r('app.media.lut_ref_nc_classic_neg');
      default: return null;
    }
  }
  private async loadPreview(lut: CustomLut): Promise<void> {
    if (!lut.table) {
      const context = this.getUIContext().getHostContext();
      if (!context) return;
      const loaded = await LutLoader.load(context.resourceManager, lut);
      if (!loaded || this.disposed) return;
      lut = loaded;
      this.lut = loaded;
    }
    if (!lut.table || this.disposed) return;
    let source: image.ImageSource | null = null;
    let original: image.PixelMap | null = null;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // 更换示例图: a user-chosen sample wins over the bundled reference.
      const customSample = lut.sampleUri && lut.sampleUri.length > 0 &&
        lut.sampleUri.indexOf('resource://') !== 0;
      if (customSample) original = await PixelMapUtils.loadFromUri(lut.sampleUri!, 800);
      const referenceResource = this.lutReferenceResource(lut);
      if (!original && referenceResource) {
        const referenceBytes = await context.resourceManager.getMediaContent(referenceResource);
        source = image.createImageSource(referenceBytes.buffer as ArrayBuffer);
        const referenceInfo = await source.getImageInfo();
        const referenceScale = Math.min(1, 800 / Math.max(referenceInfo.size.width, referenceInfo.size.height));
        original = await source.createPixelMap({
          editable: true, desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
          desiredSize: {
            width: Math.max(1, Math.round(referenceInfo.size.width * referenceScale)),
            height: Math.max(1, Math.round(referenceInfo.size.height * referenceScale)),
          },
        });
      }
      if (!original) {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const bytes = await context.resourceManager.getMediaContent($r('app.media.lut_sample_portrait'));
        source = image.createImageSource(bytes.buffer as ArrayBuffer);
        const info = await source.getImageInfo();
        // The detail view is a preview only. Keep the working surface small so
        // LUT sampling can complete off the UI turn; export still uses the
        // original-resolution pipeline elsewhere.
        const scale = Math.min(1, 800 / Math.max(info.size.width, info.size.height));
        const options: image.DecodingOptions = { editable: true, desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
          desiredSize: { width: Math.max(1, Math.round(info.size.width * scale)), height: Math.max(1, Math.round(info.size.height * scale)) } };
        original = await source.createPixelMap(options);
      }
      if (!original) return;
      const imageInfo = await original.getImageInfo();
      const buffer = new ArrayBuffer(imageInfo.size.width * imageInfo.size.height * 4);
      await original.readPixelsToBuffer(buffer);
      const pixels = new Uint8ClampedArray(buffer);
      const table = lut.table;
      const workerLut: WorkerLut = { enabled: true, intensity: 1, size: table.size, values: table.values,
        domainMin: table.domainMin, domainMax: table.domainMax };
      const gpuBuffer = await GpuShaderBridge.renderLutPreview(buffer, imageInfo.size.width, imageInfo.size.height, table);
      const rendered = gpuBuffer ? new Uint8ClampedArray(gpuBuffer) : pixels;
      if (!gpuBuffer) applyLutStack(rendered, [workerLut]);
      const output = await image.createPixelMap(new ArrayBuffer(rendered.byteLength), {
        editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888,
        size: { width: imageInfo.size.width, height: imageInfo.size.height },
      });
      await output.writeBufferToPixels(rendered.buffer);
      this.beforeMap = original;
      original = null;
      this.afterMap = output;
      // 效果图就绪后预生成碰一碰分享包，轻碰时无需现场编码。
      this.prepareKnockPackage();
    } catch (_error) {
      // The static sample remains visible if a device cannot decode media data.
    } finally {
      if (source) source.release();
      if (original) original.release();
    }
  }

  /** Pick a gallery image, persist it to Works and open the editor with this LUT. */
  private async choosePhotoForLut(): Promise<void> {
    const selectedLut = this.lut;
    if (!selectedLut) return;
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const result = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      if (!result.photoUris || result.photoUris.length === 0) return;
      const uri = result.photoUris[0];
      LutLibraryStore.upsert(selectedLut);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await RecentPhotoStore.add(context, uri);
      await this.getUIContext().getRouter().pushUrl({
        url: 'pages/EditorPage',
        params: { imageUri: uri, presetName: '', customPresetJson: '', lutId: selectedLut.id },
      });
    } catch (_error) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开图库' });
    }
  }

  /** The sample card / preview source: the user-chosen sample wins over the
   * bundled reference and the default portrait. */
  private sampleThumbSource(): string | Resource {
    const lut = this.lut;
    if (lut && lut.sampleUri && lut.sampleUri.length > 0 && lut.sampleUri.indexOf('resource://') !== 0) {
      return lutDisplayUri(lut.sampleUri);
    }
    return lut ? (this.lutReferenceResource(lut) ?? $r('app.media.lut_sample_portrait'))
      : $r('app.media.lut_sample_portrait');
  }

  /**
   * 更换示例图: open the gallery and replace this LUT's sample image. The
   * picked photo is copied into filesDir (picker URI grants do not survive
   * restarts), stored as a per-LUT override and applied everywhere the LUT
   * shows an effect preview (detail page, main-page cards, transfer page).
   */
  private async changeSampleImage(): Promise<void> {
    const lut = this.lut;
    if (!lut) return;
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const result = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      if (!result.photoUris || result.photoUris.length === 0) return;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!context) return;
      const loaded = await PixelMapUtils.loadFromUri(result.photoUris[0], 1280);
      if (!loaded) {
        this.getUIContext().getPromptAction().showToast({ message: '示例图无法读取' });
        return;
      }
      try {
        const jpeg = await PixelMapUtils.encodeToJpeg(loaded, 88);
        if (!jpeg) {
          this.getUIContext().getPromptAction().showToast({ message: '示例图保存失败' });
          return;
        }
        const path = context.filesDir + '/lut_sample_' + Date.now().toString(36) + '.jpg';
        const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(file.fd, jpeg);
        } finally {
          fileIo.closeSync(file);
        }
        lut.sampleUri = path;
        lut.coverUri = path;
        LutLibraryStore.upsert(lut);
        await saveSampleOverride(context, lut.id, path);
        // Main-page cards and the transfer page follow the new sample.
        AppStorage.setOrCreate('lutSampleRevision', Date.now());
        this.getUIContext().getPromptAction().showToast({ message: '示例图已更新' });
        this.loadPreview(lut);
      } finally {
        loaded.release();
      }
    } catch (_error) {
      // Cancelling the picker keeps the current sample unchanged.
    }
  }
  build() {
    Column() {
      Row() {
        Text('‹').fontSize(36).fontColor($r('app.color.vivid_text_f4f7fc')).onClick(() => { this.getUIContext().getRouter().back(); });
        Text(this.lut ? this.lut.name : 'LUT').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.vivid_text_f4f7fc')).layoutWeight(1).textAlign(TextAlign.Center);
        Blank().width(38);
      }.width('100%').height(82).padding({ left: 12, right: 12, top: 14 }).backgroundColor('#171717');
      Scroll() {
        Column() {
          if (this.lut) {
            Text(this.lut.author && this.lut.author.length > 0 ? this.lut.author : 'Pixelshop LUT')
              .fontSize(13).fontColor($r('app.color.vivid_text_b8bec7')).width('100%').margin({ top: 18, bottom: 10 });
            this.ComparePreview();
            Row() {
              Image(this.sampleThumbSource()).width(76).height(58).objectFit(ImageFit.Cover)
                .borderRadius(8).border({ width: this.sampleIndex === 0 ? 2 : 0, color: '#F5D20A' });
              Column() { Text('+').fontSize(28).fontColor($r('app.color.vivid_text_b8bec7')); }
                .width(58).height(58).justifyContent(FlexAlign.Center).borderRadius(8)
                .border({ width: 1, color: '#707070' }).margin({ left: 10 })
                .onClick(() => { this.choosePhotoForLut(); });
              Blank()
              Button('更换示例图')
                .fontSize(11).fontColor('#F5D20A').type(ButtonType.Capsule)
                .backgroundColor('rgba(245,210,10,0.14)').height(32)
                .onClick(() => { this.changeSampleImage(); })
            }.width('100%').margin({ top: 12, bottom: 14 });
            Text('基础照片调色').fontSize(13).fontColor($r('app.color.vivid_text_9298a2')).width('100%');
            Text(this.lut.description && this.lut.description.length > 0 ? this.lut.description : '将此 LUT 以非破坏性图层应用到照片。')
              .fontSize(14).fontColor($r('app.color.vivid_text_e5e7eb')).width('100%').lineHeight(22).margin({ top: 14 });
            Row() {
              Text('⚡').fontSize(13).fontColor('#F5D20A');
              Text('可将本机顶部与对方的 HarmonyOS 手机轻碰，分享此 LUT（含效果图与说明）')
                .fontSize(11).fontColor($r('app.color.vivid_text_9298a2')).layoutWeight(1).lineHeight(16)
                .margin({ left: 6 });
            }.width('100%').margin({ top: 18 }).alignItems(VerticalAlign.Top);
          } else {
            Text('LUT 不存在').fontSize(16).fontColor($r('app.color.vivid_text_e5e7eb')).margin({ top: 40 });
          }
        }.width('100%').padding({ left: 20, right: 20, bottom: 112 });
      }.layoutWeight(1).scrollBar(BarState.Off).backgroundColor('#000000');
    }.width('100%').height('100%').backgroundColor('#000000');
  }

  @Builder
  ComparePreview() {
    Stack() {
      if (this.afterMap) {
        Image(this.afterMap).width('100%').height(290).objectFit(ImageFit.Cover);
      } else {
        Image(this.lut && this.lutReferenceResource(this.lut) ? this.lutReferenceResource(this.lut) : $r('app.media.lut_sample_portrait')).width('100%').height(290).objectFit(ImageFit.Cover);
      }
      // Both images use exactly the same full-width viewport. Only the
      // original's clipping container changes as the divider moves.
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.beforeMap) {
          Image(this.beforeMap).width(this.previewWidth).height(290).objectFit(ImageFit.Cover);
        } else {
          Image(this.lut && this.lutReferenceResource(this.lut) ? this.lutReferenceResource(this.lut) : $r('app.media.lut_sample_portrait')).width(this.previewWidth).height(290)
            .objectFit(ImageFit.Cover);
        }
      }.width(this.previewWidth).height(290)
        .clip(new Rect({ width: this.previewWidth * this.split, height: 290 }))
        .position({ x: 0, y: 0 });
      Column() {
        Divider().vertical(true).height(290).strokeWidth(2).color('#FFFFFF');
        Circle().width(34).height(34).fill('#222222').stroke('#FFFFFF').strokeWidth(2)
          .position({ x: -17, y: 128 });
      }.width(2).height(290).position({ x: this.previewWidth * this.split, y: 0 })
        .hitTestBehavior(HitTestMode.None);
      Text('原图').fontSize(10).fontColor($r('app.color.vivid_text_ffffff')).position({ x: 10, y: 10 });
      Text('LUT').fontSize(10).fontColor($r('app.color.vivid_text_ffffff')).position({ x: '88%', y: 10 });
    }.width('100%').height(290).clip(true).borderRadius(12)
      .priorityGesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 1 })
        .onActionStart(() => { this.splitStart = this.split; })
        .onActionUpdate((event: GestureEvent) => {
          this.split = Math.max(0, Math.min(1, this.splitStart + event.offsetX / Math.max(1, this.previewWidth)));
        }))
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const width = Number(newArea.width);
        if (width > 0 && width !== this.previewWidth) this.previewWidth = width;
      });
  }
}



