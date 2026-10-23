import { EditSession } from '../edit/models/EditSession';
import { DisclosureChevron } from './DisclosureChevron';
import { AdjustmentCategory, ADJUSTMENT_DEFS, AdjustmentDef } from '../edit/models/Adjustment';
import { SliderControl } from './SliderControl';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { ToneCurveControl } from './ToneCurveControl';
import { ColorMixerControl } from './ColorMixerControl';
import { CalibrationPanel } from './CalibrationPanel';
import { ColorGradingPanel } from './ColorGradingPanel';
import { VividMaterial } from './VividMaterial';
import { VividNative } from './VividNativeTheme';
import { CameraProfiles, CameraProfile } from '../edit/utils/CameraProfiles';
import { PixelMapUtils } from '../edit/utils/PixelMapUtils';
import { DenoisePanel } from './DenoisePanel';
import { DetailPanel } from './DetailPanel';
import { OpticsPanel } from './OpticsPanel';
import { BlackWhitePanel } from './BlackWhitePanel';
import {
  PROCESS_VERSION_CURRENT, ProcessVersionNote, isLatestProcessVersion,
  legacyPinnedBehaviors, processVersionLabel, processVersionSummary,
} from '../edit/models/ProcessVersion';

@Component
export struct AdjustmentPanel {
  @Consume('editSession') editSession: EditSession;
  @State private sliderVersion: number = 0;
  @State private rawWhiteBalanceExpanded: boolean = false;
  @StorageLink('rawCameraModel') private rawCameraModel: string = '';
  @StorageLink('rawSourceName') private rawSourceName: string = '';
  @StorageLink('selectedCameraProfile') private selectedCameraProfile: string = '';
  @StorageLink('rawWhiteBalanceKelvin') private rawKelvin: number = 0;
  @StorageLink('rawWhiteBalanceTint') private rawTint: number = 0;
  // The parent panel owns the reset action. A revision prop lets the sliders
  // refresh their displayed values when reset is pressed from the title bar.
  @Prop @Watch('syncResetRevision') resetRevision: number = 0;
  // MaskPanel already provides the outer vertical scroller. Avoid nesting a
  // second unconstrained Scroll there: HarmonyOS can measure its layoutWeight
  // viewport above the rows, which appears as a large blank gap.
  @Prop embedded: boolean = false;
  // Desktop Camera Raw inspector reuses only the existing RAW profile action.
  @Prop profileOnly: boolean = false;
  // TabletLayout owns the outer inspector Scroll. Keep one vertical scroll
  // source so basic-adjustment rows are not measured as a zero-height nested viewport.
  @Prop externalScroll: boolean = false;
  // PC inspector mode renders every adjustment category as a vertical accordion.
  // The outer TabletLayout Scroll owns vertical movement; no category gets its
  // own page or vertical viewport.
  @Prop desktopAccordion: boolean = false;
  @State private desktopLightExpanded: boolean = true;
  @State private desktopCurveExpanded: boolean = false;
  @State private desktopColorExpanded: boolean = false;
  @State private desktopMixExpanded: boolean = false;
  @State private desktopCalibrationExpanded: boolean = false;
  @State private desktopGradingExpanded: boolean = false;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  private processTimer: number = -1;
  private processPending: boolean = false;
  private profileApplying: boolean = false;
  private profilePending: boolean = false;

  private syncResetRevision(): void {
    this.sliderVersion++;
  }

  build() {
    Column() {
      if (!this.embedded) {
        Row() {
          Text(this.profileOnly ? '配置文件' : '相机配置文件').fontSize(12)
            .fontColor(VividNative.textPrimary);
          Select([{ value: '无' }, { value: CameraProfiles.CLASSIC_PROFILE_NAME },
            { value: CameraProfiles.FLOG2_PROFILE_NAME },
            ...CameraProfiles.matching(this.rawCameraModel).map((p: CameraProfile): SelectOption => ({ value: p.name }))])
            .value(this.selectedCameraProfile || '无')
            // 原生下拉：文字色/选中项底色/下拉面底全走系统令牌，圆角用系统输入框圆角。
            .fontColor(VividNative.textPrimary)
            .selectedOptionBgColor(Color.Transparent)
            .selectedOptionFontColor(VividNative.textPrimary)
            .optionBgColor(VividNative.surfacePanel)
            .optionFontColor(VividNative.textPrimary)
            .menuBackgroundColor(VividNative.surfacePanel)
            .controlSize(ControlSize.SMALL)
            .layoutWeight(1)
            .font({ size: this.profileOnly ? 12 : 16 })
            .height(this.profileOnly ? 28 : 40)
            .borderRadius(VividNative.radiusField)
            .onSelect((index: number, value: string) => {
              this.selectedCameraProfile = index === 0 ? '' : value;
              if (value === CameraProfiles.FLOG2_PROFILE_NAME) {
                // The bundled F-Log2C profile was modified from Panasonic
                // Vision: its matrices only fit Panasonic RAW data, so warn
                // instead of letting other cameras render wrong colors.
                this.getUIContext().getPromptAction().showDialog({
                  title: CameraProfiles.FLOG2_PROFILE_NAME,
                  message: '该配置文件基于松下 Vision 修改，仅适配松下 RAW 文件；用于其他相机文件格式时可能出现色彩显示异常。',
                  buttons: [{ text: '知道了', color: VividNative.emphasize }],
                }).catch(() => {
                });
              } else if (index > 0) {
                this.getUIContext().getPromptAction().showToast({ message: '正在应用 LibRaw CPU 参考路径…' });
              }
              this.applyCameraProfile();
            });
        }.padding({ left: 14, right: 14, top: 6, bottom: this.profileOnly ? 10 : 0 }).width('100%');
        if (this.selectedCameraProfile.length > 0) {
          Text(this.rawWhiteBalanceExpanded ? '▾ RAW 白平衡' : '▸ RAW 白平衡')
            .fontSize(10).fontColor(VividNative.textPrimary)
            .padding({ left: 14, right: 14, top: 4 })
            .focusable(true).focusBox(VividNative.focusBox()).hoverEffect(HoverEffect.Highlight)
            .onClick(() => { this.rawWhiteBalanceExpanded = !this.rawWhiteBalanceExpanded; });
          if (this.rawWhiteBalanceExpanded) {
            Row() {
              Text(this.rawKelvin === 0 ? '拍摄时白平衡' : `${Math.round(this.rawKelvin)} K`).fontSize(11)
                .fontColor(VividNative.textPrimary);
              Blank();
              Button('拍摄时').fontSize(11).buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
                .onClick(() => { this.rawKelvin = 0; this.rawTint = 0; this.applyCameraProfile(); });
            }.width('100%').padding({ left: 14, right: 14 });
            Slider({ value: this.rawKelvin || 5000, min: 2000, max: 12000, step: 25 }).width('90%')
              .enableHapticFeedback(true)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.rawKelvin = value;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.applyCameraProfile();
              });
            Text(`RAW 色调 ${this.rawTint.toFixed(0)}`).fontSize(11)
              .fontColor(VividNative.textPrimary);
            Slider({ value: this.rawTint, min: -100, max: 100, step: 1 }).width('90%')
              .enableHapticFeedback(true)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.rawTint = value;
                if (this.rawKelvin === 0) this.rawKelvin = 5000;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.applyCameraProfile();
              });
          }
        }
        Divider().strokeWidth(1)
          .color(VividNative.divider)
          .margin({ top: 6, bottom: 4 });
      }

      if (!this.profileOnly) {
      if (this.desktopAccordion && !this.embedded && this.editSession.adjustmentScope === 0) {
        DenoisePanel();
        DetailPanel();
        OpticsPanel();
        BlackWhitePanel();
      }
      if (this.desktopAccordion) {
        this.DesktopSections();
      } else {
        Scroll() {
          Row() {
            this.CategoryButton('光效', AdjustmentCategory.LIGHT);
            this.CategoryButton('曲线', AdjustmentCategory.CURVE);
            this.CategoryButton('色彩', AdjustmentCategory.COLOR);
            this.CategoryButton('调色', AdjustmentCategory.MIX);
            this.CategoryButton('色准', AdjustmentCategory.CALIBRATION);
            this.CategoryButton('颜色分级', AdjustmentCategory.GRADING);
          }.padding({ left: 4, right: 12 });
        }
        .width('calc(100% - 24vp)')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .padding({ left: 10, right: 10, top: 8, bottom: 5 })
        // 分类条底色交给原生材质（VividMaterial）统一决定；不再叠加手写 rgba 覆盖它。
        .borderRadius(VividNative.radiusClicked)
        .attributeModifier(this.isNightMode ? VividMaterial.cardNight : VividMaterial.card)
        .clip(true)
        .margin({ left: 12, right: 12, top: 8 });

        if (this.embedded) {
          if (this.editSession.activeCategory === AdjustmentCategory.CURVE) {
            ToneCurveControl({ maskContext: this.embedded, embedded: true });
            // The parametric curve is a tone-curve control, so it belongs with
            // the point curve and is available per mask, exactly like it is.
            this.AdjustmentRows(AdjustmentCategory.CURVE);
          } else if (this.editSession.activeCategory === AdjustmentCategory.MIX) {
            ColorMixerControl({ maskContext: this.embedded, embedded: true });
          } else if (this.editSession.activeCategory === AdjustmentCategory.CALIBRATION) {
            CalibrationPanel({ maskContext: this.embedded, embedded: true });
          } else if (this.editSession.activeCategory === AdjustmentCategory.GRADING) {
            ColorGradingPanel({ maskContext: this.embedded, embedded: true });
          } else {
            Column() {
              this.AdjustmentRows(this.editSession.activeCategory);
            }.width('100%').padding({ bottom: 28 });
          }
        } else {
          Column() {
            if (this.editSession.activeCategory === AdjustmentCategory.CURVE) {
              ToneCurveControl({ maskContext: this.embedded, embedded: false });
              this.AdjustmentRows(AdjustmentCategory.CURVE);
            } else if (this.editSession.activeCategory === AdjustmentCategory.MIX) {
              ColorMixerControl({ maskContext: this.embedded, embedded: false });
            } else if (this.editSession.activeCategory === AdjustmentCategory.CALIBRATION) {
              CalibrationPanel({ maskContext: this.embedded, embedded: false });
              // Document-level setting: only in the global inspector, never for a mask.
              this.ProcessVersionRow();
            } else if (this.editSession.activeCategory === AdjustmentCategory.GRADING) {
              ColorGradingPanel({ maskContext: this.embedded, embedded: false });
            } else if (this.externalScroll) {
              Column() {
                this.AdjustmentRows(this.editSession.activeCategory);
              }.width('100%').padding({ bottom: 28 });
            } else {
              Scroll() {
                Column() {
                  this.AdjustmentRows(this.editSession.activeCategory);
                }.width('100%').padding({ bottom: 28 });
              }
              .layoutWeight(1).width('100%').scrollable(ScrollDirection.Vertical)
              .scrollBar(BarState.Off).edgeEffect(EdgeEffect.None);
            }
          }.layoutWeight(1).width('100%').clip(true);
        }
      }
      }
    }
    .width('100%')
    .height(this.profileOnly || this.embedded ? 'auto' : (this.desktopAccordion ? 'auto' : '100%'))
    .backgroundColor(Color.Transparent);
  }
  /** Re-decode the bounded preview immediately after the profile changes. */
  private async applyCameraProfile(): Promise<void> {
    if (this.editSession.imageUri.length === 0) return;
    if (this.profileApplying) { this.profilePending=true; return; }
    this.profileApplying = true;
    const uri = this.editSession.imageUri;
    const source = this.editSession.sourcePixelMap;
    const settings = PixelMapUtils.rawPreviewSettings();
    const begin = Date.now();
    try {
      let preview = await PixelMapUtils.reprocessRawPreview(uri, settings);
      if (this.editSession.imageUri !== uri || this.editSession.sourcePixelMap !== source) {
        if (preview) preview.release();
        return;
      }
      if (!preview) preview = await PixelMapUtils.loadFromUri(uri,
        Math.max(this.editSession.imageWidth, this.editSession.imageHeight, 1280),
        undefined, undefined, undefined, this.rawSourceName || uri, undefined, false, settings);
      if (!preview) return;
      const info = await preview.getImageInfo();
      const current = PixelMapUtils.rawPreviewSettings();
      if (this.editSession.imageUri !== uri || this.editSession.sourcePixelMap !== source ||
        current.profile !== settings.profile || current.kelvin !== settings.kelvin || current.tint !== settings.tint) {
        preview.release(); return;
      }
      // The displayed frame belongs to the old profile. It is handed to
      // clearSourceCache, which parks it until the new frame is published:
      // releasing it here would leave the canvas drawing a freed PixelMap for
      // the whole RAW re-decode, and nulling previewPixelMap would blank the
      // canvas. Both are visible defects; parking is neither.
      const previousTask = ImageProcessor.currentPreviewTask(this.editSession);
      const displayed = this.editSession.previewPixelMap;
      ImageProcessor.clearSourceCache(this.editSession);
      this.editSession.previewPixelMap = displayed;
      this.editSession.sourcePixelMap = preview;
      this.editSession.imageWidth = info.size.width;
      this.editSession.imageHeight = info.size.height;
      // Rendering/old-source cleanup must not hold the RAW profile gate. A
      // subsequent profile choice can now begin as soon as DCP pixels exist.
      ImageProcessor.process(this.editSession, true);
      previousTask.finally(() => {
        if (source && source !== this.editSession.sourcePixelMap &&
          source !== this.editSession.previewPixelMap && source !== this.editSession.beforePixelMap) {
          try { source.release(); } catch (_error) { /* already released */ }
        }
      }).catch(() => {});
      console.info(`VIVID_EDIT_PERF stage=dcp-switch ms=${Date.now() - begin}`);
    } catch (error) {
      console.error('Failed to apply camera profile: ' + String(error));
    } finally {
      this.profileApplying = false;
      if(this.profilePending){this.profilePending=false;this.applyCameraProfile();}
    }
  }

  @Builder
  private ProcessVersionRow() {
    Column() {
      Row() {
        Text('处理版本').fontSize(12).fontColor(VividNative.textPrimary).layoutWeight(1);
        Text(processVersionLabel(this.editSession.processVersion))
          .fontSize(12).fontColor(VividNative.textSecondary);
      }.width('100%').height(30).alignItems(VerticalAlign.Center);
      if (!isLatestProcessVersion(this.editSession.processVersion)) {
        Text(processVersionSummary(this.editSession.processVersion))
          .fontSize(10).fontColor(VividNative.textTertiary).width('100%');
        // State exactly what the old generation holds fixed rather than
        // implying the two are interchangeable.
        ForEach(legacyPinnedBehaviors(), (note: ProcessVersionNote) => {
          Text('· ' + note.title + '：' + note.detail)
            .fontSize(10).fontColor(VividNative.textTertiary).width('100%').margin({ top: 2 });
        }, (note: ProcessVersionNote) => note.title);
        // 原生次要按钮（ButtonStyleMode.NORMAL + ControlSize.SMALL），填充/文字色由系统主题决定。
        Button('更新到当前处理版本')
          .fontSize(12).height(30).width('100%').margin({ top: 6 })
          .buttonStyle(ButtonStyleMode.NORMAL)
          .controlSize(ControlSize.SMALL)
          .onClick(() => {
            this.editSession.pushUndo();
            this.editSession.processVersion = PROCESS_VERSION_CURRENT;
            this.editSession.requestProcessing();
            ImageProcessor.process(this.editSession);
          });
      }
    }.width('100%').alignItems(HorizontalAlign.Start);
  }

  @Builder
  private DesktopSections() {
    Column() {
      this.DesktopSectionHeader('光效', AdjustmentCategory.LIGHT);
      if (this.desktopLightExpanded) {
        Column() { this.AdjustmentRows(AdjustmentCategory.LIGHT); }
          .width('100%').padding({ left: 8, right: 8, bottom: 12 });
      }

      this.DesktopSectionHeader('曲线', AdjustmentCategory.CURVE);
      if (this.desktopCurveExpanded) {
        ToneCurveControl({ maskContext: this.embedded, embedded: true, externalScroll: true });
        this.AdjustmentRows(AdjustmentCategory.CURVE);
      }

      this.DesktopSectionHeader('色彩', AdjustmentCategory.COLOR);
      if (this.desktopColorExpanded) {
        Column() { this.AdjustmentRows(AdjustmentCategory.COLOR); }
          .width('100%').padding({ left: 8, right: 8, bottom: 12 });
      }

      this.DesktopSectionHeader('调色', AdjustmentCategory.MIX);
      if (this.desktopMixExpanded) {
        ColorMixerControl({ maskContext: this.embedded, embedded: true, externalScroll: true });
      }

      this.DesktopSectionHeader('色准', AdjustmentCategory.CALIBRATION);
      if (this.desktopCalibrationExpanded) {
        CalibrationPanel({ maskContext: this.embedded, embedded: true, externalScroll: true });
        if (!this.embedded) this.ProcessVersionRow();
      }

      this.DesktopSectionHeader('颜色分级', AdjustmentCategory.GRADING);
      if (this.desktopGradingExpanded) {
        ColorGradingPanel({ maskContext: this.embedded, embedded: true, externalScroll: true });
      }
    }.width('100%');
  }

  @Builder
  private DesktopSectionHeader(label: string, category: AdjustmentCategory) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(VividNative.textPrimary);
      Blank();
      DisclosureChevron({ expanded: this.isDesktopExpanded(category) }).margin({ left: 7, right: 7 });
    }
    .width('calc(100% - 20vp)')
    .height(38)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 12, right: 4 })
    .margin({ left: 10, right: 10, top: 5 })
    // 分区头：系统次级底色 + 系统圆角；PC 键盘焦点框与悬停高亮走原生反馈。
    .borderRadius(VividNative.radiusClicked)
    .backgroundColor(VividNative.surfaceSub)
    .focusable(true)
    .focusBox(VividNative.focusBox())
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => {
      this.toggleDesktopCategory(category);
      this.editSession.activeCategory = category;
    });
  }

  private isDesktopExpanded(category: AdjustmentCategory): boolean {
    if (category === AdjustmentCategory.LIGHT) return this.desktopLightExpanded;
    if (category === AdjustmentCategory.CURVE) return this.desktopCurveExpanded;
    if (category === AdjustmentCategory.COLOR) return this.desktopColorExpanded;
    if (category === AdjustmentCategory.MIX) return this.desktopMixExpanded;
    if (category === AdjustmentCategory.CALIBRATION) return this.desktopCalibrationExpanded;
    return this.desktopGradingExpanded;
  }

  private toggleDesktopCategory(category: AdjustmentCategory): void {
    if (category === AdjustmentCategory.LIGHT) this.desktopLightExpanded = !this.desktopLightExpanded;
    else if (category === AdjustmentCategory.CURVE) this.desktopCurveExpanded = !this.desktopCurveExpanded;
    else if (category === AdjustmentCategory.COLOR) this.desktopColorExpanded = !this.desktopColorExpanded;
    else if (category === AdjustmentCategory.MIX) this.desktopMixExpanded = !this.desktopMixExpanded;
    else if (category === AdjustmentCategory.CALIBRATION) this.desktopCalibrationExpanded = !this.desktopCalibrationExpanded;
    else this.desktopGradingExpanded = !this.desktopGradingExpanded;
  }

  @Builder
  private AdjustmentRows(category: AdjustmentCategory) {
    ForEach(
      ADJUSTMENT_DEFS.filter(d => d.category === category),
      (def: AdjustmentDef) => {
        if (this.editSession.activeLayer) {
          if (def.key === 'vignetteAmount') {
            Divider()
              .strokeWidth(1)
              .color(VividNative.divider)
              .margin({ left: 14, right: 14, top: 4, bottom: 4 });
          }
          SliderControl({
            label: def.key === 'temperature' ? '色温（K）' : def.label,
            min: def.min,
            max: def.max,
            step: def.step,
            value: (this.editSession.adjustmentsForContext(this.embedded)?.getValue(def.key) ?? 0) + this.sliderVersion * 0,
            formatValue: def.key === 'temperature' ?
              ((value: number) => `${Math.round(5000 + value * 3000)}K`) : def.format,
            gradientType: this.gradientTypeFor(def.key),
            onBegin: () => {
              this.editSession.pushUndo();
            },
            onChange: (val: number) => {
              const layer = this.editSession.activeLayer;
              if (layer) {
                const adjustments = this.editSession.adjustmentsForContext(this.embedded);
                if (!adjustments) return;
                adjustments.setValue(def.key, val);
                // Mask geometry is unchanged by colour controls, so keep the
                // cached alpha buffer while only invalidating the render.
                // Updating the public
                // processingVersion for every slider frame rebuilds the
                // scroll card and makes dragging lag.
                this.editSession.requestProcessing();
                this.scheduleProcess();
              }
            },
          });
          if (def.key === 'vignetteFeather') {
            Divider()
              .strokeWidth(1)
              .color(VividNative.divider)
              .margin({ left: 14, right: 14, top: 4, bottom: 4 });
          }
        }
      },
      (def: AdjustmentDef) => def.key
    );
    if (!this.desktopAccordion && category === AdjustmentCategory.LIGHT &&
      !this.embedded && this.editSession.adjustmentScope === 0) {
      DenoisePanel();
      DetailPanel();
      OpticsPanel();
      BlackWhitePanel();
    }
  }

  @Builder
  CategoryButton(label: string, category: AdjustmentCategory) {
    Button(label)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .type(ButtonType.Capsule)
      .height(30)
      .padding({ left: 10, right: 10 })
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .backgroundColor(Color.Transparent)
      .fontColor(VividNative.textPrimary)
      .border({ width: this.editSession.activeCategory === category ? 1 : 0, color: VividNative.separator })
      .controlSize(ControlSize.SMALL)
      .focusable(true)
      .focusBox(VividNative.focusBox())
      .onClick(() => { this.editSession.activeCategory = category; });
  }

  private scheduleProcess(): void {
    // Throttle instead of debounce: while a slider is being dragged the
    // pipeline runs every 33ms so the preview follows live; stale runs abort
    // themselves via processingRequestVersion.
    if (this.processPending) return;
    this.processPending = true;
    this.processTimer = setTimeout(() => {
      this.processPending = false;
      this.processTimer = -1;
      ImageProcessor.process(this.editSession);
    }, 33);
  }

  private gradientTypeFor(key: string): string {
    if (key === 'temperature') return 'temperature';
    if (key === 'tint') return 'tint';
    if (key === 'hue') return 'hue';
    if (key === 'saturation') return 'saturation';
    if (key === 'vibrance') return 'vibrance';
    return 'normal';
  }

}







