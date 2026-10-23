import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { NikonCloudImages, NikonCloudRecipe, NikonCloudStore } from '../edit/models/NikonCloudCatalog';
import { parseNp3 } from '../edit/models/NikonNp3';

/** 色彩方案详情的一行：标签 + 值。 */
interface NikonCloudDetailRow {
  label: string;
  value: string;
}

/**
 * 云创方案详情：布局沿用官方 LUT 详情页（返回栏 + 大图 + 详情区）。
 *
 * 云创方案没有原图，所以顶部只放官方效果图；下方「色彩方案详情」展示
 * 优化校准与拍摄信息。官方数据（效果图、拍摄信息）尚未同步时，界面保持
 * 完整但只有本地已知的字段，避免留出空白大图位。
 */
@Entry
@Component
struct NikonCloudDetailPage {
  @State private recipe: NikonCloudRecipe | null = null;
  @State private loading: boolean = true;
  /** 官方效果图（rawfile 解码成 PixelMap 才能稳定显示）。 */
  @State private cover: image.PixelMap | undefined = undefined;
  /** 清单没写优化校准名时，从 NP3 文件头里读出的名称（就是优化校准名）。 */
  @State private np3Name: string = '';
  private code: string = '';
  @StorageLink('vividNightMode') private isNightMode: boolean = false;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params !== null && typeof params['code'] === 'string') {
      this.code = params['code'] as string;
    }
    this.loadRecipe();
  }

  private async loadRecipe(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const items = await NikonCloudStore.load(context);
    const matched = items.find((item: NikonCloudRecipe): boolean => item.id === this.code);
    this.recipe = matched !== undefined ? matched : null;
    if (matched !== undefined && matched.np3.length > 0 &&
      (matched.pictureControl === undefined || matched.pictureControl.length === 0)) {
      // 清单里没写优化校准名时，NP3 头部的名称字段就是它。
      try {
        const raw = await context.resourceManager.getRawFileContent(matched.np3);
        this.np3Name = parseNp3(new Uint8Array(raw.buffer as ArrayBuffer)).name;
      } catch (_error) {
        this.np3Name = '';
      }
    }
    const path = this.imagePath();
    if (path.length > 0) {
      const loaded = await NikonCloudImages.load(context, path);
      this.cover = loaded !== null ? loaded : undefined;
    }
    this.loading = false;
  }

  private pageTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#172033';
  }

  private panelTextColor(): string {
    return this.isNightMode ? '#F4F7FC' : '#1B2536';
  }

  private mutedTextColor(): string {
    return this.isNightMode ? '#9BA8BC' : '#8B96A6';
  }

  private detailTitle(): string {
    const recipe = this.recipe;
    if (recipe !== null && recipe.name.length > 0) return recipe.name;
    return '云创方案';
  }

  private fileName(): string {
    const recipe = this.recipe;
    if (recipe === null || recipe.np3.length === 0) return '';
    const parts = recipe.np3.split('/');
    return parts[parts.length - 1];
  }

  /** 详情大图：优先 cover（长边 1080），退化到列表小图。 */
  private imagePath(): string {
    const recipe = this.recipe;
    if (recipe === null) return '';
    const cover = recipe.cover !== undefined ? recipe.cover : '';
    if (cover.length > 0) return cover;
    return recipe.thumb;
  }

  /** 优化校准：清单优先，其次 NP3 头部名称。 */
  private pictureControlValue(): string {
    const recipe = this.recipe;
    if (recipe === null) return '';
    const control = recipe.pictureControl !== undefined ? recipe.pictureControl : '';
    if (control.length > 0) return control;
    return this.np3Name;
  }

  /** 色彩方案详情：只列出有值的字段，官方数据未同步时自然只剩本地字段。 */
  private detailRows(): NikonCloudDetailRow[] {
    const recipe = this.recipe;
    if (recipe === null) return [];
    const rows: NikonCloudDetailRow[] = [];
    const control = this.pictureControlValue();
    if (control.length > 0) rows.push({ label: '优化校准', value: control });
    const based = recipe.based !== undefined ? recipe.based : '';
    if (based.length > 0) rows.push({ label: '基于风格', value: based });
    const creator = recipe.creator !== undefined && recipe.creator.length > 0 ? recipe.creator : '尼康云创';
    rows.push({ label: '制作者', value: creator });
    const published = recipe.published !== undefined ? recipe.published : '';
    if (published.length > 0) rows.push({ label: '发布日期', value: published });
    const file = this.fileName();
    if (file.length > 0) rows.push({ label: '滤镜文件', value: file });
    const shortUrl = recipe.shortUrl !== undefined ? recipe.shortUrl : '';
    if (shortUrl.length > 0) rows.push({ label: '官方链接', value: shortUrl });
    return rows;
  }

  /**
   * 拍摄信息：官方接口 bff/recipe/detail 需要尼康账号的 access_token 才返回
   * shooting_information（camera / lens / focal_length / place / time）。
   * 本地清单里没有这些字段时按「待同步」占位，把区块固定下来，
   * 同步脚本回填后这几行会自动变成真实值。
   */
  private shootingRows(): NikonCloudDetailRow[] {
    const recipe = this.recipe;
    if (recipe === null) return [];
    const rows: NikonCloudDetailRow[] = [];
    const push = (label: string, value: string) => {
      rows.push({ label: label, value: value.length > 0 ? value : '待同步' });
    };
    push('相机', recipe.camera !== undefined ? recipe.camera : '');
    push('镜头', recipe.lens !== undefined ? recipe.lens : '');
    push('焦距', recipe.focal !== undefined ? recipe.focal : '');
    push('快门速度', recipe.shutter !== undefined ? recipe.shutter : '');
    push('光圈', recipe.aperture !== undefined ? recipe.aperture : '');
    push('ISO 感光度', recipe.iso !== undefined ? recipe.iso : '');
    push('曝光补偿', recipe.exposureComp !== undefined ? recipe.exposureComp : '');
    push('白平衡', recipe.whiteBalance !== undefined ? recipe.whiteBalance : '');
    push('拍摄时间', recipe.time !== undefined ? recipe.time : '');
    push('拍摄地点', recipe.place !== undefined ? recipe.place : '');
    return rows;
  }

  /** 创作者写的方案说明（官方 detail / outline），没有就整块不渲染。 */
  private descriptionText(): string {
    const recipe = this.recipe;
    if (recipe === null) return '';
    return recipe.description !== undefined ? recipe.description : '';
  }

  /** 拍摄信息是否已有真实值（决定是否显示同步提示）。 */
  private hasShootingInfo(): boolean {
    const recipe = this.recipe;
    if (recipe === null) return false;
    const values: string[] = [
      recipe.camera !== undefined ? recipe.camera : '',
      recipe.lens !== undefined ? recipe.lens : '',
      recipe.focal !== undefined ? recipe.focal : '',
      recipe.shutter !== undefined ? recipe.shutter : '',
      recipe.aperture !== undefined ? recipe.aperture : '',
      recipe.iso !== undefined ? recipe.iso : '',
      recipe.place !== undefined ? recipe.place : '',
      recipe.time !== undefined ? recipe.time : '',
    ];
    return values.some((value: string) => value.length > 0);
  }

  /** 大图下方的元信息行：制作者 · 发布日期。 */
  private metaLine(): string {
    const recipe = this.recipe;
    if (recipe === null) return '';
    const parts: string[] = [];
    const creator = recipe.creator !== undefined && recipe.creator.length > 0 ? recipe.creator : '';
    if (creator.length > 0) parts.push(creator);
    const published = recipe.published !== undefined ? recipe.published : '';
    if (published.length > 0) parts.push(published);
    if (parts.length > 0) return parts.join(' · ');
    return '尼康云创';
  }

  @Builder
  EffectImage() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.cover !== undefined) {
        Image(this.cover as image.PixelMap)
          .width('100%').height(300).objectFit(ImageFit.Cover);
      } else {
        Row().width('100%').height(300)
          .linearGradient({
            angle: 135,
            colors: [['#2E3A52', 0], ['#5B6880', 1]] as [ResourceColor, number][],
          });
        Column({ space: 6 }) {
          Text('云创').fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor('rgba(255,255,255,0.78)').letterSpacing(3);
          Text('官方效果图待同步').fontSize(11).fontColor('rgba(255,255,255,0.58)');
        };
      }
    }
    .width('100%')
    .height(300)
    .clip(true)
    .borderRadius(18);
  }

  @Builder
  DetailRowCard(rows: NikonCloudDetailRow[]) {
    Column() {
      ForEach(rows, (row: NikonCloudDetailRow, index: number) => {
        Row() {
          Text(row.label)
            .fontSize(12).fontColor(this.mutedTextColor())
            .width(96);
          Text(row.value)
            .fontSize(12)
            .fontColor(row.value === '待同步' ? this.mutedTextColor() : this.panelTextColor())
            .layoutWeight(1)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ top: 7, bottom: 7 })
        .border(index < rows.length - 1 ? {
          width: { bottom: 1 },
          color: this.isNightMode ? 'rgba(255,255,255,0.06)' : 'rgba(30,45,70,0.06)',
        } : { width: 0 });
      }, (row: NikonCloudDetailRow) => row.label + ':' + row.value);
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 2, bottom: 2 })
    .borderRadius(16)
    .backgroundColor(this.isNightMode ? 'rgba(32,42,59,0.55)' : 'rgba(255,255,255,0.60)')
    .border({ width: 1, color: this.isNightMode ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.85)' });
  }

  build() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(34).fontWeight(FontWeight.Medium).fontColor(this.pageTextColor())
          .width(44).height(44).textAlign(TextAlign.Center)
          .onClick(() => { this.getUIContext().getRouter().back(); });
        Text(this.detailTitle())
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Blank().width(44);
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 6 });

      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(38).height(38).color(this.mutedTextColor());
          Text('正在读取云创方案…').fontSize(12).fontColor(this.mutedTextColor());
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
      } else if (this.recipe === null) {
        Column() {
          Text('未找到该云创方案').fontSize(14).fontColor(this.mutedTextColor());
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
      } else {
        Scroll() {
          Column() {
            this.EffectImage();
            Row() {
              Text(this.metaLine())
                .fontSize(11).fontColor(this.panelTextColor())
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1);
              Text('官方效果图')
                .fontSize(9).fontColor(this.mutedTextColor());
            }
            .width('100%').margin({ top: 8, bottom: 2 });

            Text('色彩方案详情')
              .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
              .width('100%').margin({ top: 18, bottom: 8 });
            this.DetailRowCard(this.detailRows());

            Text('拍摄信息')
              .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
              .width('100%').margin({ top: 18, bottom: 8 });
            this.DetailRowCard(this.shootingRows());

            if (!this.hasShootingInfo()) {
              Text('拍摄信息来自尼康云创方案页（接口需尼康账号，本地包不含），登录同步后这里会自动变成真实值。')
                .fontSize(10).fontColor(this.mutedTextColor())
                .lineHeight(16).width('100%').margin({ top: 10 });
            }

            if (this.descriptionText().length > 0) {
              Text('方案说明')
                .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.panelTextColor())
                .width('100%').margin({ top: 18, bottom: 8 });
              Text(this.descriptionText())
                .fontSize(12).fontColor(this.panelTextColor())
                .lineHeight(20).width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .borderRadius(16)
                .backgroundColor(this.isNightMode ? 'rgba(32,42,59,0.55)' : 'rgba(255,255,255,0.60)')
                .border({ width: 1, color: this.isNightMode ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.85)' });
            }

            Text('来自尼康云创（本地滤镜包）· 导入后可在「本机 LUT」与预设中管理')
              .fontSize(11).fontColor(this.mutedTextColor())
              .width('100%').margin({ top: 16 });
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 40 });
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      }
    }
    .width('100%')
    .height('100%')
    .safeAreaPadding({ top: 24 })
    .linearGradient({
      angle: 160,
      colors: this.isNightMode
        ? [['#05070C', 0], ['#0D1017', 1]]
        : [['#F3F6FC', 0], ['#E9EFF9', 1]],
    });
  }
}
