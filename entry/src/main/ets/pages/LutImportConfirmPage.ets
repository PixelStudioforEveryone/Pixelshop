import { CustomLut, LutLibraryStore, lutDisplayUri, upsertCustomLut } from '../edit/models/LutLibrary';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { PixelMapUtils } from '../edit/utils/PixelMapUtils';
import { AppDiagnostics } from '../services/AppDiagnostics';

/** Confirmation form shown after a LUT has been parsed and validated. */
@Entry
@Component
struct LutImportConfirmPage {
  @State private name: string = '';
  @State private author: string = '';
  @State private description: string = '';
  @State private category: string = '人像';
  @State private sampleUri: string = 'resource://vivid_cover';
  @State private saveMode: boolean = false;
  @State private saving: boolean = false;
  private pending: CustomLut | null = null;

  aboutToAppear(): void {
    this.pending = LutLibraryStore.pending();
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.saveMode = params?.['saveMode'] === true;
    if (this.pending) {
      this.name = this.pending.name;
      this.author = this.pending.author ?? '';
      this.description = this.pending.description ?? '';
      // A previously saved LUT keeps its row when re-edited; new imports
      // default to the portrait row.
      this.category = (this.pending.category ?? '') === '自然' ? '自然' : '人像';
      this.sampleUri = this.pending.sampleUri ?? 'resource://vivid_cover';
      // 官方下载的样片（CDN 原图）没拿到时，确认页要明确告诉用户：效果图会
      // 用内置通用人像渲染、不准确，建议手动换一张自己的照片。
      if (this.pending.id.indexOf('official:') === 0 &&
        (this.sampleUri.indexOf('resource://') === 0 || this.sampleUri.length === 0)) {
        setTimeout((): void => {
          this.getUIContext().getPromptAction().showToast(
            { message: '官方样片未下载成功，效果图可能不准确，建议选择一张示例图' });
        }, 350);
      }
    }
  }

  @Builder
  CategoryOption(label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.category === label ? $r('app.color.vivid_text_ffffff') : $r('app.color.vivid_text_1b2536'))
      .textAlign(TextAlign.Center)
      .height(32)
      .layoutWeight(1)
      .borderRadius(16)
      .backgroundColor(this.category === label ? '#5262EC' : $r('app.color.vivid_surface_e8ecff'))
      .onClick(() => { this.category = label; });
  }

  build() {
    Column() {
      Column() {
        Row() {
          Text(this.saveMode ? '保存 LUT' : '导入 LUT').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.vivid_text_1b2536')).layoutWeight(1);
          Text('×').fontSize(24).fontColor($r('app.color.vivid_text_5262ec')).onClick(() => {
            this.cancelImport();
          });
        }.width('100%');
        Text('确认 LUT 信息').fontSize(13).fontColor($r('app.color.vivid_text_5262ec')).width('100%').margin({ top: 8 });
        if (this.saveMode) {
          Text('仅保存手动全局调色，不包含预设使用的 LUT、裁剪和局部蒙版。')
            .fontSize(11).fontColor($r('app.color.vivid_text_7b879a')).width('100%').margin({ top: 8 });
        }
        TextInput({ text: this.name, placeholder: '名称' }).width('100%').height(44)
          .fontColor($r('app.color.vivid_text_1b2536')).placeholderColor('#7B879A').margin({ top: 18 })
          .onChange((value: string) => { this.name = value; });
        TextInput({ text: this.author, placeholder: '作者（可选）' }).width('100%').height(44)
          .fontColor($r('app.color.vivid_text_1b2536')).placeholderColor('#7B879A').margin({ top: 10 })
          .onChange((value: string) => { this.author = value; });
        TextInput({ text: this.description, placeholder: '描述（可选）' }).width('100%').height(80)
          .fontColor($r('app.color.vivid_text_1b2536')).placeholderColor('#7B879A').margin({ top: 10 })
          .onChange((value: string) => { this.description = value; });
        if (this.pending) {
          Text(`格式 ${this.pending.format ?? 'lut'} · ${this.pending.sampleCount} 个采样点`)
            .fontSize(11).fontColor($r('app.color.vivid_text_7b879a')).width('100%').margin({ top: 14 });
        }
        Text('LUT 分类').fontSize(12).fontColor($r('app.color.vivid_text_1b2536')).width('100%').margin({ top: 14 });
        Row() {
          this.CategoryOption('人像');
          this.CategoryOption('自然');
        }.width('100%').margin({ top: 8 });
        Row() {
          Image(this.sampleUri.indexOf('resource://') === 0
            ? $r('app.media.lut_sample_portrait')
            : (this.sampleUri.length > 0 ? lutDisplayUri(this.sampleUri) : $r('app.media.lut_sample_portrait')))
            .width(72).height(48).objectFit(ImageFit.Cover).borderRadius(8)
            .border({ width: 1, color: '#D7DEEA' });
          Column() {
            Text('示例图').fontSize(12).fontColor($r('app.color.vivid_text_1b2536'));
            Text('用于 LUT 卡片和预览').fontSize(10).fontColor($r('app.color.vivid_text_7b879a')).margin({ top: 4 });
          }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 });
          Button('选择示例图').fontSize(11).fontColor($r('app.color.vivid_text_5262ec')).type(ButtonType.Capsule)
            .backgroundColor($r('app.color.vivid_surface_e8ecff')).height(32).onClick(() => { this.chooseSampleImage(); });
        }.width('100%').margin({ top: 14 });
        Row() {
          Button('取消').fontSize(13).fontColor($r('app.color.vivid_text_536176')).type(ButtonType.Capsule).backgroundColor($r('app.color.vivid_surface_e3e8f0'))
            .height(40).layoutWeight(1)
            .onClick(() => { this.cancelImport(); });
          Button(this.saving ? '保存中' : '保存').fontSize(13).fontColor($r('app.color.vivid_text_ffffff')).type(ButtonType.Capsule).backgroundColor('#5262EC')
            .height(40).layoutWeight(1).margin({ left: 10 }).onClick(() => { this.save(); });
        }.width('100%').margin({ top: 18 });
      }.width('88%').padding(22).borderRadius(24).backgroundColor($r('app.color.vivid_surface_ffffff'))
        .shadow({ radius: 28, color: 'rgba(18,32,60,0.24)', offsetY: 10 }).enabled(!this.saving);
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('rgba(13,21,36,0.48)');
  }

  private async save(): Promise<void> {
    if (this.saving || !this.pending || this.name.trim().length === 0) return;
    const duplicate = LutLibraryStore.entriesSnapshot().some((item: CustomLut) =>
      item.id !== this.pending?.id && item.name === this.name.trim());
    if (duplicate) {
      this.getUIContext().getPromptAction().showToast({ message: '名称已存在，请修改后再保存' });
      return;
    }
    this.pending.name = this.name.trim();
    this.pending.author = this.author.trim();
    this.pending.description = this.description.trim();
    // The chosen category decides which home-page row (人像/自然) the card
    // is filed under; the fallback keeps legacy entries in the custom row.
    this.pending.category = this.category === '自然' ? '自然' : '人像';
    this.pending.coverUri = this.sampleUri.length > 0 ? this.sampleUri : 'resource://vivid_cover';
    this.pending.sampleUri = this.sampleUri.length > 0 ? this.sampleUri : 'resource://vivid_cover';
    this.saving = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!context) return;
      if (this.sampleUri && this.sampleUri.indexOf('resource://') !== 0 &&
        this.sampleUri.indexOf(context.filesDir + '/') !== 0) {
        const sample = await PixelMapUtils.loadFromUri(this.sampleUri, 960);
        if (!sample) throw new Error('示例图无法读取');
        try {
          const jpeg = await PixelMapUtils.encodeToJpeg(sample, 88);
          if (!jpeg) throw new Error('示例图保存失败');
          const path = context.filesDir + '/lut_sample_' + Date.now().toString(36) + '.jpg';
          const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
          try { fileIo.writeSync(file.fd, jpeg); } finally { fileIo.closeSync(file); }
          this.pending.sampleUri = path;
          this.pending.coverUri = path;
        } finally { sample.release(); }
      }
      if (this.saveMode && this.pending.table) {
        const table = this.pending.table;
        const lines: string[] = ['TITLE "' + this.name.replace(/["\r\n]/g, ' ') + '"',
          'LUT_3D_SIZE ' + table.size.toString(), 'DOMAIN_MIN 0 0 0', 'DOMAIN_MAX 1 1 1'];
        for (let i = 0; i < table.values.length; i += 3) {
          lines.push(table.values[i].toFixed(7) + ' ' + table.values[i + 1].toFixed(7) + ' ' + table.values[i + 2].toFixed(7));
        }
        const path = context.filesDir + '/lut_' + this.pending.id + '.cube';
        const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        try { fileIo.writeSync(file.fd, lines.join('\n') + '\n'); } finally { fileIo.closeSync(file); }
        this.pending.sourceUri = path;
      }
      // 写入 JSON 文件（此前整份列表塞在 preferences 的单个字符串值里：
      // 官方条目每条约 1MB，十几条即超出该值的容量而保存失败）。
      await upsertCustomLut(context, this.pending as CustomLut);
    } catch (error) {
      // 记入问题反馈：此前这里静默吞掉错误，用户只看到「保存失败」，
      // 复盘时拿不到任何错误码。
      AppDiagnostics.exception('APP', 'lut save', error);
      this.getUIContext().getPromptAction().showToast({ message: '保存 LUT 失败，请重试' });
      return;
    } finally { this.saving = false; }
    LutLibraryStore.upsert(this.pending);
    LutLibraryStore.committedImport = this.pending;
    LutLibraryStore.clearPending();
    AppStorage.setOrCreate('lutImportRevision', Date.now());
    this.getUIContext().getPromptAction().showToast({ message: this.saveMode ? '保存成功' : '导入成功，已加入本机 LUT' });
    this.getUIContext().getRouter().back();
  }

  /**
   * 取消导入：清除待确认条目；官方下载（official:<code>）还会销毁已下载的
   * .cube 与示例图，避免残留孤儿文件。saveMode 编辑已有 LUT 时不动文件。
   */
  private cancelImport(): void {
    const pending = this.pending;
    LutLibraryStore.clearPending();
    this.getUIContext().getRouter().back();
    if (pending === null || this.saveMode) return;
    if (pending.id.indexOf('official:') !== 0) return;
    this.deleteSandboxFile(pending.sourceUri);
    this.deleteSandboxFile(pending.sampleUri);
    this.deleteSandboxFile(pending.coverUri);
  }

  private deleteSandboxFile(path: string | undefined): void {
    if (path === undefined || path === null) return;
    if (path.indexOf('/data/storage/') !== 0) return;
    try {
      if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
    } catch (_error) {
    }
  }

  private async chooseSampleImage(): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const result = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      if (result.photoUris.length > 0) this.sampleUri = result.photoUris[0];
    } catch (_error) {
      // Cancelling the picker leaves the existing sample unchanged.
    }
  }
}
