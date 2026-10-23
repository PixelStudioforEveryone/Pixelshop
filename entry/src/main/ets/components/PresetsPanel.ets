import { EditSession } from '../edit/models/EditSession';
import { DisclosureChevron } from './DisclosureChevron';
import { PRESETS, Preset, applyPreset } from '../edit/models/Presets';
import { CustomLut, LutLibraryStore, LutStackItem, loadCustomLuts,
  loadDeletedBundledLuts } from '../edit/models/LutLibrary';
import { LutLoader } from '../edit/utils/LutLoader';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { VividNative } from './VividNativeTheme';
import { NikonCloudRecipe, NikonCloudStore } from '../edit/models/NikonCloudCatalog';
import { Np3Look, nikonCloudLut, parseNp3 } from '../edit/models/NikonNp3';
import { NikonCloudThumb } from './NikonCloudThumb';
import { LutEffectThumb } from './LutEffectThumb';
interface BundledLutDescription { path: string; name: string; category: string; metadata: string; }

/** Shared preset/LUT stack surface used by the editor. */
@Component
export struct PresetsPanel {
  @Consume('editSession') editSession: EditSession;
  @Prop externalScroll: boolean = false;
  @State private selectedName: string = '';
  @StorageProp('lutCatalogRevision') @Watch('refreshCatalog') private lutCatalogRevision: number = 0;
  @StorageProp('lutImportRevision') @Watch('refreshCatalog') private lutImportRevision: number = 0;
  @State private candidates: CustomLut[] = [];
  @State private stackRevision: number = 0;
  @State private displayedStack: LutStackItem[] = [];
  /**
   * 强度百分比文字的刷新节拍。
   *
   * displayedStack 是会话栈的快照（slice），卡片上的 `item.intensity` 只在
   * refreshStack() 时才会更新；而滑杆拖动路径不能调 refreshStack()——stackRevision
   * 变化会让 ForEach 重新 key、销毁正在拖动的滑杆节点（见 scheduleProcess 的注释）。
   * 所以百分比文字改为从会话真值读取，靠这个状态变量驱动重算：只重算 Text，
   * ForEach 的 key 不变，滑杆节点全程存活。
   */
  @State private intensityTick: number = 0;
  // The desktop inspector keeps the LUT layer body behind an explicit
  // accordion. Phone layout continues to render the body expanded.
  @State private lutStackExpanded: boolean = true;
  /** 云创预设选择弹层。 */
  @State private cloudPickerVisible: boolean = false;
  /** LUT 选择弹层（与云创预设同一套交互）。 */
  @State private lutPickerVisible: boolean = false;
  @State private cloudRecipes: NikonCloudRecipe[] = [];
  @State private cloudLoaded: boolean = false;
  private processTimer: number = -1;
  private processPending: boolean = false;
  private disposed: boolean = false;
  private selectionSerial: number = 0;
  private selections: Map<string, number> = new Map();

  aboutToAppear(): void { this.disposed = false; this.refreshStack(); this.loadCatalog(); }

  aboutToDisappear(): void {
    this.disposed = true;
    this.selections.clear();
    if (this.processTimer !== -1) clearTimeout(this.processTimer);
    this.processTimer = -1;
    this.processPending = false;
  }

  private refreshCatalog(): void { this.loadCatalog(); }
  private refreshStack(): void {
    this.displayedStack = this.editSession.lutStack.slice();
    this.stackRevision++;
  }

  /** 云创预设与普通 LUT 共用同一条图层栈，用 id 前缀区分来源。 */
  private isCloudLayer(item: LutStackItem): boolean {
    return item.lutId.indexOf('nikon:') === 0;
  }

  private lutLayers(): LutStackItem[] {
    return this.displayedStack.filter((item: LutStackItem): boolean => !this.isCloudLayer(item));
  }

  private cloudLayers(): LutStackItem[] {
    return this.displayedStack.filter((item: LutStackItem): boolean => this.isCloudLayer(item));
  }

  /** 图层在会话栈里的真实下标（Section 过滤后位置会错位，操作必须用真实下标）。 */
  private stackIndex(item: LutStackItem): number {
    return this.editSession.lutStack.findIndex((entry: LutStackItem): boolean => entry.id === item.id);
  }

  /**
   * 某张 LUT 卡片的强度百分比（0-100 的整数）。
   *
   * 从会话栈里取**真值**而不是用卡片入参 `item`——`item` 是 displayedStack 的快照，
   * 拖动滑杆时它不会更新。同时读取 intensityTick 以建立状态依赖，让拖动过程中
   * 这个数字实时重算（不触发 ForEach 重排）。
   */
  private lutPercent(item: LutStackItem): number {
    const tick: number = this.intensityTick;
    const index = this.stackIndex(item);
    const live: LutStackItem = index >= 0 && tick >= 0 ? this.editSession.lutStack[index] : item;
    return Math.round(Math.max(0, Math.min(1, live.intensity)) * 100);
  }

  private async loadCatalog(): Promise<void> {
    this.candidates = LutLibraryStore.entriesSnapshot();
    this.rebindLoadedLuts();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!context) return;
    try {
      const custom = await loadCustomLuts(context);
      for (const lut of custom) if (!LutLibraryStore.find(lut.id)?.table) LutLibraryStore.upsert(lut);
      const deleted = await loadDeletedBundledLuts(context);
      const decoder = util.TextDecoder.create('utf-8');
      const descriptions = JSON.parse(decoder.decodeToString(
        await context.resourceManager.getRawFileContent('Lut/catalog.json'))) as BundledLutDescription[];
      for (const description of descriptions) {
        const id = 'bundled:' + description.path;
        const uri = 'bundled://' + description.path;
        if (deleted.includes(uri)) { LutLibraryStore.remove(id); continue; }
        if (!LutLibraryStore.find(id)) {
          const entry: CustomLut = { id: id, sourceUri: uri, name: description.name,
            category: description.category, sampleCount: 0, adjustments: {}, table: null };
          LutLibraryStore.upsert(entry);
        }
      }
    } catch (_error) {
      // An unavailable catalog must not break already imported tables.
    }
    if (this.disposed) return;
    this.candidates = LutLibraryStore.entriesSnapshot();
    this.rebindLoadedLuts();
    // Only restored, active links need tables. Leave every other entry lazy.
    const required = this.candidates.filter((lut: CustomLut): boolean => !lut.table &&
      (this.editSession.lutStack.some((item: LutStackItem): boolean =>
        item.lutId === lut.id || item.sourceUri === lut.sourceUri) ||
        this.editSession.lutLink === lut.id || this.editSession.lutLink === lut.sourceUri));
    for (const lut of required) {
      await LutLoader.load(context.resourceManager, lut);
      if (this.disposed) return;
    }
    this.candidates = LutLibraryStore.entriesSnapshot();
    this.rebindLoadedLuts();
    await this.rehydrateCloudLayers(context);
  }

  /**
   * 云创预设的 LUT 表是运行时从 NP3 烘出来的，不落盘。重开图片后图层还在、
   * 表没了，这里按 lutId 找回对应 NP3 重新烘一次，避免出现"死图层"。
   */
  private async rehydrateCloudLayers(context: common.UIAbilityContext): Promise<void> {
    const pending = this.editSession.lutStack.filter((item: LutStackItem): boolean =>
      item.lutId.indexOf('nikon:') === 0 &&
      (item.lut === null || item.lut.table === null || item.lut.table === undefined));
    if (pending.length === 0) return;
    const recipes = await NikonCloudStore.load(context);
    let changed = false;
    for (const item of pending) {
      const recipe = recipes.find((entry: NikonCloudRecipe): boolean =>
        entry.id === item.lutId.substring('nikon:'.length));
      if (recipe === undefined) continue;
      try {
        const raw = await context.resourceManager.getRawFileContent(recipe.np3);
        const look: Np3Look = parseNp3(raw);
        const index = this.stackIndex(item);
        if (index < 0) continue;
        this.editSession.replaceLutLayer(index, nikonCloudLut(recipe.id, recipe.name, look, 33));
        changed = true;
      } catch (_error) {
        // 单个方案读不出来不影响其它图层。
      }
    }
    if (changed && !this.disposed) {
      this.refreshStack();
      ImageProcessor.process(this.editSession);
    }
  }

  private rebindLoadedLuts(): void {
    if (this.editSession.resolveLutLayers(this.candidates)) {
      this.refreshStack();
      ImageProcessor.process(this.editSession);
    }
  }

  build() {
    Column() {
      Text(this.editSession.processingVersion.toString() + ':' + this.lutCatalogRevision.toString())
        .visibility(Visibility.Hidden).width(0).height(0);
      if (this.externalScroll) {
        Column() {
          // 云创预设放最前：LUT 图层的候选网格很长，放在下面会被挤到 1600vp 之外。
          this.CloudPresetSection();
          this.LutStackSection();
        }.width('100%');
      } else {
        Scroll() {
          Column() {
            this.CloudPresetSection();
            this.LutStackSection();
          }.width('100%');
        }.layoutWeight(1).scrollBar(BarState.Off);
      }
    }
    .width('100%')
    .height(this.externalScroll ? 'auto' : '100%')
    .backgroundColor(Color.Transparent)
    .bindSheet(this.lutPickerVisible || this.cloudPickerVisible, this.PickerSheet(), {
      height: 560,
      dragBar: true,
      showClose: true,
      onDisappear: () => {
        this.lutPickerVisible = false;
        this.cloudPickerVisible = false;
      },
    });
  }

  /** 两个选择弹层共用同一个 sheet：按当前标志决定内容。 */
  @Builder
  PickerSheet() {
    Stack() {
      if (this.cloudPickerVisible) {
        this.CloudPickerSheet();
      } else {
        this.LutPickerSheet();
      }
    }
    .width('100%')
    .height('100%');
  }
  @Builder
  PresetChip(preset: Preset, index: number) {
    Column() {
      Row().width('100%').height(18).borderRadius(VividNative.radiusLevel8).linearGradient({ angle: 90,
        colors: [[this.presetColor(index), 0], [this.presetColorEnd(index), 1]] });
      Text(preset.name).fontSize(10).fontWeight(FontWeight.Medium).fontColor(VividNative.textPrimary)
        .textAlign(TextAlign.Center).maxLines(2).margin({ top: 7 });
    }.width('100%').aspectRatio(1.35).padding(7)
      // 预设卡：选中用系统卡面 + 系统主题色描边，未选中用系统卡面常态色。
      .backgroundColor(VividNative.surfaceCard)
      .borderRadius(VividNative.radiusCard).border({ width: 1, color: this.selectedName === preset.name ? VividNative.emphasize : VividNative.separator })
      .onClick(() => {
        const layer = this.editSession.activeLayer;
        if (!layer) return;
        this.editSession.pushUndo();
        this.selectedName = preset.name;
        layer.adjustments.reset();
        applyPreset(layer.adjustments, preset);
        this.editSession.bumpProcessing();
        ImageProcessor.process(this.editSession);
      });
  }

  @Builder
  LutStackSection() {
    Column() {
      Row() {
        Text('LUT 图层').fontSize(13).fontWeight(FontWeight.Bold).fontColor(VividNative.textPrimary);
        Blank();
        if (this.externalScroll) {
          DisclosureChevron({ expanded: this.lutStackExpanded }).margin({ left: 7, right: 7 })
            .onClick(() => { this.lutStackExpanded = !this.lutStackExpanded; });
        }
        Button('添加 LUT').fontSize(10).height(28)
          .buttonStyle(ButtonStyleMode.EMPHASIZED).controlSize(ControlSize.SMALL).onClick(() => { this.openLutPicker(); });
      }.width('100%').alignItems(VerticalAlign.Center).padding({ left: 14, right: 14, top: 14, bottom: 8 });
      if (!this.externalScroll || this.lutStackExpanded) {
        if (this.lutLayers().length === 0) {
          Row() {
            Text('无 LUT').fontSize(11).fontColor(VividNative.textSecondary);
          }.width('100%').padding({ left: 14, right: 14, bottom: 8 });
        } else {
          ForEach(this.lutLayers(), (item: LutStackItem, index: number) => {
            this.LutLayerCard(item, index);
          }, (item: LutStackItem) => item.id + ':' + this.stackRevision.toString());
        }
      }
    }.width('100%');
  }

  @Builder
  LutLayerCard(item: LutStackItem, order: number) {
    Column() {
      Row() {
        Text(`${order + 1}. ${item.name}`).fontSize(11).fontWeight(FontWeight.Medium).fontColor(VividNative.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
        Text(`${this.lutPercent(item)}%`)
          .fontSize(10).fontColor(VividNative.textSecondary);
        Button(item.enabled ? '停用' : '启用').fontSize(9).height(24)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo();
            this.editSession.setLutEnabled(this.stackIndex(item), !item.enabled);
            this.refreshStack();
            ImageProcessor.process(this.editSession);
          });
        Button('删除').fontSize(9).height(24)
          .buttonStyle(ButtonStyleMode.TEXTUAL).role(ButtonRole.ERROR).controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo();
            this.editSession.removeLutLayer(this.stackIndex(item));
            this.refreshStack();
            ImageProcessor.process(this.editSession);
          });
      }.width('100%');
      Slider({ style: SliderStyle.OutSet, min: 0, max: 1, step: 0.01, value: item.intensity })
        .width('100%').onChange((value: number) => {
           this.editSession.setLutIntensity(this.stackIndex(item), value);
           // 只让百分比文字重算；不改 stackRevision，滑杆节点保持存活。
           this.intensityTick++;
           this.scheduleProcess();
         });
      // LUT 选择区：卡片随 LUT 数量自适应高度、一行两个平铺
      // （原来是横向一行塞下全部 LUT，只能靠左右滑动找）。
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        this.LutCandidate('无 LUT', null, this.stackIndex(item));
        ForEach(this.catalog(), (lut: CustomLut) => { this.LutCandidate(lut.name, lut, this.stackIndex(item)); },
          (lut: CustomLut) => lut.id);
      }.width('100%').padding({ left: 5, right: 5, top: 2 });
      Row() {
        Button('↑').fontSize(12).height(24).buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .enabled(this.stackIndex(item) > 0).onClick(() => {
          this.editSession.pushUndo(); this.editSession.moveLutLayer(this.stackIndex(item), -1);
          ImageProcessor.process(this.editSession);
          this.refreshStack();
        });
        Button('↓').fontSize(12).height(24).buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .enabled(this.stackIndex(item) + 1 < this.editSession.lutStack.length).margin({ left: 6 })
          .onClick(() => {
            this.editSession.pushUndo(); this.editSession.moveLutLayer(this.stackIndex(item), 1);
            ImageProcessor.process(this.editSession);
            this.refreshStack();
          });
      }.width('100%').justifyContent(FlexAlign.End);
    }.width('94%').padding(10).margin({ bottom: 8 })
      .borderRadius(VividNative.radiusCard).backgroundColor(VividNative.surfaceCard)
      .border({ width: 1, color: VividNative.separator });
  }

  /** 云创预设区：布局与 LUT 图层一致，条目来自同一图层栈（id 以 nikon: 开头）。 */
  @Builder
  CloudPresetSection() {
    Column() {
      Row() {
        Text('云创预设').fontSize(13).fontWeight(FontWeight.Bold).fontColor(VividNative.textPrimary);
        Blank();
        Button('添加云创预设').fontSize(10).height(28)
          .buttonStyle(ButtonStyleMode.EMPHASIZED).controlSize(ControlSize.SMALL)
          .onClick(() => { this.openCloudPicker(); });
      }.width('100%').alignItems(VerticalAlign.Center).padding({ left: 14, right: 14, top: 16, bottom: 8 });
      if (this.cloudLayers().length === 0) {
        Row() {
          Text('无云创预设').fontSize(11).fontColor(VividNative.textSecondary);
        }.width('100%').padding({ left: 14, right: 14, bottom: 8 });
      } else {
        ForEach(this.cloudLayers(), (item: LutStackItem, order: number) => {
          this.CloudLayerCard(item, order);
        }, (item: LutStackItem) => item.id + ':' + this.stackRevision.toString());
      }
    }.width('100%');
  }

  @Builder
  CloudLayerCard(item: LutStackItem, order: number) {
    Column() {
      Row() {
        Text(`${order + 1}. ${item.name}`).fontSize(11).fontWeight(FontWeight.Medium).fontColor(VividNative.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
        Text(this.cloudBadge(item)).fontSize(9).fontColor(VividNative.textSecondary)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(VividNative.radiusLevel8).backgroundColor(VividNative.surfaceSub);
        Text(`${this.lutPercent(item)}%`).fontSize(10).fontColor(VividNative.textSecondary)
          .margin({ left: 6 });
      }.width('100%');
      Slider({ style: SliderStyle.OutSet, min: 0, max: 1, step: 0.01, value: item.intensity })
        .width('100%').onChange((value: number) => {
          this.editSession.setLutIntensity(this.stackIndex(item), value);
          // 与普通 LUT 卡片一致：只刷新百分比文字，不重排 ForEach。
          this.intensityTick++;
          this.scheduleProcess();
        });
      Row() {
        Button(item.enabled ? '停用' : '启用').fontSize(9).height(24)
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo();
            this.editSession.setLutEnabled(this.stackIndex(item), !item.enabled);
            this.refreshStack();
            ImageProcessor.process(this.editSession);
          });
        Blank();
        Button('删除').fontSize(9).height(24)
          .buttonStyle(ButtonStyleMode.TEXTUAL).role(ButtonRole.ERROR).controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo();
            this.editSession.removeLutLayer(this.stackIndex(item));
            this.refreshStack();
            ImageProcessor.process(this.editSession);
          });
      }.width('100%');
    }.width('94%').padding(10).margin({ bottom: 8 })
      .borderRadius(VividNative.radiusCard).backgroundColor(VividNative.surfaceCard)
      .border({ width: 1, color: VividNative.separator });
  }

  private cloudBadge(item: LutStackItem): string {
    const lut = item.lut;
    if (lut !== null) {
      const description = lut.description;
      if (description !== undefined && description.length > 0) return description;
    }
    return '云创';
  }

  private openCloudPicker(): void {
    this.cloudPickerVisible = true;
    if (!this.cloudLoaded) this.loadCloudRecipes();
  }

  private async loadCloudRecipes(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (context === undefined) return;
    this.cloudRecipes = await NikonCloudStore.load(context);
    this.cloudLoaded = true;
  }

  /** 读 NP3 → 解析 → 烘 LUT → 入图层栈（与 LUT 图层共用强度/启停/删除）。 */
  private async addCloudPreset(recipe: NikonCloudRecipe): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (context === undefined) return;
    const lutId = 'nikon:' + recipe.id;
    if (this.editSession.lutStack.some((item: LutStackItem): boolean => item.lutId === lutId)) {
      this.showToast('该云创预设已在图层里');
      return;
    }
    try {
      const raw = await context.resourceManager.getRawFileContent(recipe.np3);
      const look: Np3Look = parseNp3(raw);
      const usable = look.hasCurve ||
        look.mixer.some((value: number): boolean => Math.abs(value) > 0.004);
      if (!usable) {
        this.showToast('该方案没有可套用的曲线或参数');
        return;
      }
      const lut = nikonCloudLut(recipe.id, recipe.name, look, 33);
      this.editSession.pushUndo();
      this.editSession.addLutLayer(lut);
      this.refreshStack();
      ImageProcessor.process(this.editSession);
      this.cloudPickerVisible = false;
      this.showToast(look.hasCurve ? '已加入云创预设（官方曲线）' : '已加入云创预设（参数近似）');
    } catch (_error) {
      this.showToast('读取云创方案失败');
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      console.info(message);
    }
  }

  /** 云创方案选择弹层：一行两张，带官方效果图。 */
  @Builder
  CloudPickerSheet() {
    Column() {
      Row() {
        Text('添加云创预设').fontSize(16).fontWeight(FontWeight.Bold).fontColor(VividNative.textPrimary);
      }.width('100%').padding({ left: 4, right: 4 });
      Text(this.cloudLoaded ? this.cloudRecipes.length.toString() + ' 个方案' : '加载中…')
        .fontSize(10).fontColor(VividNative.textSecondary)
        .width('100%').padding({ left: 4, right: 4, bottom: 8 });
      Scroll() {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.cloudRecipes, (recipe: NikonCloudRecipe) => {
            this.CloudPickerCard(recipe);
          }, (recipe: NikonCloudRecipe) => recipe.id);
        }.width('100%');
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 44, bottom: 12 });
  }

  /** LUT 选择弹层：一行两张，点一张直接加到图层栈。 */
  @Builder
  LutPickerSheet() {
    Column() {
      Row() {
        Text('添加 LUT').fontSize(16).fontWeight(FontWeight.Bold).fontColor(VividNative.textPrimary);
      }.width('100%').padding({ left: 4, right: 4 });
      Text(this.catalog().length.toString() + ' 个 LUT')
        .fontSize(10).fontColor(VividNative.textSecondary)
        .width('100%').padding({ left: 4, right: 4, bottom: 10 });
      if (this.catalog().length === 0) {
        Column() {
          Text('还没有可用的 LUT').fontSize(12).fontColor(VividNative.textSecondary);
          Text('先到「本机 LUT」导入，再回来添加图层').fontSize(10).fontColor(VividNative.textSecondary)
            .margin({ top: 6 });
        }.width('100%').padding({ top: 40 }).alignItems(HorizontalAlign.Center);
      } else {
        Scroll() {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.catalog(), (lut: CustomLut) => {
              this.LutPickerCard(lut);
            }, (lut: CustomLut) => lut.id);
          }.width('100%');
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 44, bottom: 12 });
  }

  @Builder
  LutPickerCard(lut: CustomLut) {
    Column() {
      Stack() {
        LutEffectThumb({ lutId: lut.id });
        Text(lut.category !== undefined && lut.category.length > 0 ? lut.category : 'LUT')
          .fontSize(8).fontColor($r('app.color.vivid_text_ffffff')).backgroundColor('rgba(0,0,0,0.36)')
          .padding({ left: 3, right: 3, top: 2, bottom: 2 }).position({ x: 4, y: 4 });
      }
      .width('100%').aspectRatio(1.5).borderRadius(VividNative.radiusLevel8).clip(true)
        .border({ width: 1, color: VividNative.separator });
      Text(lut.name).fontSize(10).fontColor(VividNative.textSecondary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').textAlign(TextAlign.Center).margin({ top: 5 });
    }
    .width('50%')
    .padding({ left: 4, right: 4, bottom: 10 })
    .onClick(() => { this.pickLut(lut); });
  }

  @Builder
  CloudPickerCard(recipe: NikonCloudRecipe) {
    Column() {
      Stack() {
        NikonCloudThumb({ path: recipe.thumb, label: '', small: true, eager: true });
      }
      .width('100%').aspectRatio(1.5).borderRadius(VividNative.radiusLevel8).clip(true)
        .border({ width: 1, color: VividNative.separator });
      Text(recipe.name).fontSize(9).fontColor(VividNative.textSecondary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').textAlign(TextAlign.Center).margin({ top: 4 });
    }
    .width('50%')
    .padding({ left: 4, right: 4, bottom: 9 })
    .onClick(() => { this.addCloudPreset(recipe); });
  }

  @Builder
  LutCandidate(name: string, lut: CustomLut | null, index: number) {
    Column() {
      Stack() {
        if (this.editSession.previewPixelMap) {
          Image(this.editSession.previewPixelMap).width('100%').height('100%').objectFit(ImageFit.Cover);
        } else {
          // LUT 缩略图占位块：用系统控件常态色 / 次级底色，不再手写灰。
          Row().width('100%').height('100%').backgroundColor(lut ? VividNative.componentNormal : VividNative.surfaceSub);
        }
        if (lut) Text('LUT').fontSize(8).fontColor($r('app.color.vivid_text_ffffff')).backgroundColor('rgba(0,0,0,0.36)')
          .padding({ left: 3, right: 3, top: 2, bottom: 2 }).position({ x: 4, y: 4 });
      }
      .width('100%').aspectRatio(1.6).borderRadius(VividNative.radiusLevel8).clip(true)
      // 当前生效的 LUT 用系统主题色描边标出（原来是把整格填成蓝色）。
      .border({ width: this.isCurrentLut(index, lut) ? 2 : 1,
        color: this.isCurrentLut(index, lut) ? VividNative.emphasize : VividNative.separator });
      Text(name).fontSize(10)
        .fontColor(this.isCurrentLut(index, lut) ? VividNative.emphasize : VividNative.textSecondary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').textAlign(TextAlign.Center).margin({ top: 5 });
    }
    // 一行两个：每张卡固定半宽，由 Flex 换行平铺，高度随数量自适应。
    .width('50%')
    .padding({ left: 5, right: 5, bottom: 10 })
    .onClick(() => {
      this.selectLut(index, lut);
    });
  }

  /** 这一层 LUT 当前选中的条目（"无 LUT" 对应空 lutId）。 */
  private isCurrentLut(index: number, lut: CustomLut | null): boolean {
    const item = this.editSession.lutStack[index];
    if (!item) return false;
    if (lut === null) return item.lutId.length === 0;
    return item.lutId === lut.id;
  }

  private async selectLut(index: number, lut: CustomLut | null): Promise<void> {
    const item = this.editSession.lutStack[index];
    const context = this.getUIContext().getHostContext();
    if (!item || !context) return;
    const id = item.id, uri = this.editSession.imageUri, serial = ++this.selectionSerial;
    this.selections.set(id, serial);
    const loaded = lut ? await LutLoader.load(context.resourceManager, lut) : null;
    if (this.disposed || this.editSession.imageUri !== uri || this.selections.get(id) !== serial || (lut && !loaded)) return;
    const current = this.editSession.lutStack.findIndex((layer: LutStackItem): boolean => layer.id === id);
    if (current < 0) return;
    this.editSession.pushUndo();
    this.editSession.replaceLutLayer(current, loaded);
    this.candidates = LutLibraryStore.entriesSnapshot();
    this.refreshStack();
    ImageProcessor.process(this.editSession);
  }

  private openLutPicker(): void {
    this.lutPickerVisible = true;
    this.candidates = LutLibraryStore.entriesSnapshot();
  }

  /** 弹层里点一张 LUT：加载表 → 入图层栈（与云创预设同一套交互）。 */
  private async pickLut(lut: CustomLut): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (context === undefined) return;
    const uri = this.editSession.imageUri;
    const loaded = await LutLoader.load(context.resourceManager, lut);
    if (!loaded || this.disposed || this.editSession.imageUri !== uri) {
      this.showToast('读取 LUT 失败');
      return;
    }
    this.editSession.pushUndo();
    this.editSession.addLutLayer(loaded);
    this.candidates = LutLibraryStore.entriesSnapshot();
    this.refreshStack();
    ImageProcessor.process(this.editSession);
    this.lutPickerVisible = false;
    this.showToast('已加入 ' + loaded.name);
  }

  private catalog(): CustomLut[] { return this.candidates; }

  private scheduleProcess(): void {
    // LUT intensity is a gesture just like the regular adjustment sliders.
    // Keep the public stack/card refresh at ~30fps and select the bounded
    // interactive renderer instead of starting a full-size render per event.
    this.editSession.requestProcessing();
    if (this.processPending) return;
    this.processPending = true;
    this.processTimer = setTimeout(() => {
      this.processPending = false;
      this.processTimer = -1;
      // Preserve the slider node/focus throughout a drag. Re-keying every
      // 33 ms destroyed the active knob and caused visible input stutters.
      ImageProcessor.process(this.editSession);
    }, 33);
  }

  private presetList(): Preset[] {
    const list: Preset[] = PRESETS.slice();
    if (this.editSession.lutPreset && !list.some((item: Preset) => item.name === this.editSession.lutPreset?.name)) {
      list.push(this.editSession.lutPreset);
    }
    return list;
  }

  private presetColor(index: number): string {
    const colors: string[] = ['#526D83', '#796D7D', '#657C72', '#9A806A', '#596A84', '#906E6E'];
    return colors[index % colors.length];
  }

  private presetColorEnd(index: number): string {
    const colors: string[] = ['#D7B0A2', '#B7A789', '#B5C498', '#D6B98B', '#9BAFBE', '#D0A493'];
    return colors[index % colors.length];
  }
}
