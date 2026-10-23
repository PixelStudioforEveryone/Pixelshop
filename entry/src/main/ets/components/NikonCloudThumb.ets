import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { NikonCloudImages } from '../edit/models/NikonCloudCatalog';

/**
 * 云创效果图（rawfile 解码成 PixelMap 显示）。
 *
 * 为什么单独做成组件：ArkUI 的 ForEach 按 key 复用子节点，父组件状态变化不会
 * 重建卡片，所以"图片解码完成"必须由卡片自己的 @State 触发重绘。列表卡片靠
 * onVisibleAreaChange 懒加载（一屏解 8 张），预设弹层里的 onVisibleAreaChange
 * 不触发，改成 eager 直接解（sampleSize 降采样的小图，108 张常驻也就 20MB）。
 */
@Component
export struct NikonCloudThumb {
  @Prop path: string = '';
  @Prop label: string = '';
  @Prop small: boolean = false;
  @Prop eager: boolean = false;
  @State private pixelMap: image.PixelMap | undefined = undefined;
  private loading: boolean = false;

  aboutToAppear(): void {
    if (this.eager) this.loadImage();
  }

  private async loadImage(): Promise<void> {
    if (this.path.length === 0 || this.loading || this.pixelMap !== undefined) return;
    const cached = this.small ? NikonCloudImages.cachedSmall(this.path) : NikonCloudImages.cached(this.path);
    if (cached !== undefined) {
      this.pixelMap = cached;
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (context === undefined) return;
    this.loading = true;
    try {
      const loaded = this.small
        ? await NikonCloudImages.loadSmall(context, this.path)
        : await NikonCloudImages.load(context, this.path);
      if (loaded !== null) this.pixelMap = loaded;
    } catch (_error) {
      // 单张图解码失败就走占位，不影响列表。
    }
    this.loading = false;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pixelMap !== undefined) {
        Image(this.pixelMap as image.PixelMap)
          .width('100%').height('100%').objectFit(ImageFit.Cover);
      } else {
        Row().width('100%').height('100%')
          .linearGradient({
            angle: 135,
            colors: [['#2E3A52', 0], ['#5B6880', 1]] as [ResourceColor, number][],
          });
        if (this.label.length > 0) {
          Text(this.label)
            .fontSize(11).fontWeight(FontWeight.Bold)
            .fontColor('rgba(255,255,255,0.72)').letterSpacing(2);
        }
      }
    }
    .width('100%')
    .height('100%')
    // 纯展示用：不参与命中测试，否则会挡掉卡片自己的点击。
    .hitTestBehavior(HitTestMode.None)
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) this.loadImage();
    });
  }
}
