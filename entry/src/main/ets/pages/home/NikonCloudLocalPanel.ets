import { common } from '@kit.AbilityKit';
import { NikonCloudRecipe, NikonCloudStore } from '../../edit/models/NikonCloudCatalog';
import { NikonCloudThumb } from '../../components/NikonCloudThumb';

/** 风格库「云创本地」页签：内置尼康云创方案，一行两张效果图卡片。 */
@Component
export struct NikonCloudLocalPanel {
  @State private recipes: NikonCloudRecipe[] = [];
  @State private loading: boolean = true;
  @StorageLink('vividNightMode') private isNightMode: boolean = false;
  @StorageProp('windowWidth') private windowWidth: number = 390;

  aboutToAppear(): void {
    this.loadCatalog();
  }

  private async loadCatalog(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.recipes = await NikonCloudStore.load(context);
    this.loading = false;
  }

  private isDesktop(): boolean {
    return this.windowWidth >= 840;
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

  /** 两列铺卡：每行两张，滚动交给外层页面，避免嵌套滚动抢手势。 */
  private recipeRows(): NikonCloudRecipe[][] {
    const rows: NikonCloudRecipe[][] = [];
    let row: NikonCloudRecipe[] = [];
    for (const recipe of this.recipes) {
      row.push(recipe);
      if (row.length >= 2) {
        rows.push(row);
        row = [];
      }
    }
    if (row.length > 0) rows.push(row);
    return rows;
  }

  private openRecipe(recipe: NikonCloudRecipe): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/NikonCloudDetailPage',
      params: { code: recipe.id },
    });
  }

  @Builder
  RecipeCard(recipe: NikonCloudRecipe) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        NikonCloudThumb({ path: recipe.thumb, label: '云创', small: false });
        Row().width('100%').height('100%')
          .linearGradient({
            angle: 90,
            colors: [['rgba(0,0,0,0.02)', 0], ['rgba(0,0,0,0.46)', 1]] as [ResourceColor, number][],
          });
      }
      .width('100%')
      .aspectRatio(this.isDesktop() ? 1.8 : 1.5)
      .borderRadius(16)
      .clip(true);

      Text(recipe.name)
        .fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(this.panelTextColor())
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').margin({ top: 7 });
      Text(recipe.creator.length > 0 ? recipe.creator : '尼康云创')
        .fontSize(9).fontColor(this.mutedTextColor())
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').margin({ top: 2 });
    }
    .width(this.isDesktop() ? '23.5%' : '48.4%')
    .padding(8)
    .borderRadius(20)
    .backgroundColor(this.isNightMode ? 'rgba(32,42,59,0.62)' : 'rgba(255,255,255,0.52)')
    .border({ width: 1, color: this.isNightMode ? 'rgba(140,160,190,0.24)' : 'rgba(255,255,255,0.82)' })
    .shadow({ radius: 18, color: this.isNightMode ? 'rgba(0,0,0,0.28)' : 'rgba(57,70,92,0.10)', offsetY: 7 })
    .onClick(() => { this.openRecipe(recipe); });
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('云创本地')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pageTextColor());
        Blank();
        if (this.recipes.length > 0) {
          Text(this.recipes.length.toString() + ' 个方案')
            .fontSize(10).fontColor(this.mutedTextColor());
        }
      }
      .width('100%')
      .margin({ top: 6, bottom: 2 });
      Text('内置尼康云创滤镜包：点开查看官方效果图与色彩方案详情')
        .fontSize(11).fontColor(this.mutedTextColor()).width('100%');

      if (this.loading) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color(this.mutedTextColor());
          Text('正在读取云创滤镜包…').fontSize(12).fontColor(this.mutedTextColor());
        }
        .width('100%').margin({ top: 10 });
      } else if (this.recipes.length === 0) {
        Column({ space: 6 }) {
          Text('未找到本地云创滤镜包').fontSize(13).fontColor(this.pageTextColor());
          Text('请把 .NP3 滤镜包放到 rawfile/NikonCloud/np3 后重新打包')
            .fontSize(11).fontColor(this.mutedTextColor()).textAlign(TextAlign.Center);
        }
        .width('100%').padding({ top: 30, bottom: 34 });
      } else {
        ForEach(this.recipeRows(), (row: NikonCloudRecipe[], rowIndex: number) => {
          Row({ space: 10 }) {
            ForEach(row, (recipe: NikonCloudRecipe) => {
              this.RecipeCard(recipe);
            }, (recipe: NikonCloudRecipe) => recipe.id);
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)
          .alignItems(VerticalAlign.Top);
        }, (row: NikonCloudRecipe[], rowIndex: number) => 'row:' + rowIndex.toString() + ':' +
          row.map((recipe: NikonCloudRecipe): string => recipe.id).join('|'));
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: 24 });
  }
}
