import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { VividNative } from './VividNativeTheme';

export interface VividNavigationItem {
  key: number;
  label: string;
  symbol?: Resource;
  glyph?: string;
  /** 用图元绘制的图标（字形库里没有对应形状时用），目前支持 'eraser'。 */
  shape?: string;
}

const NAVIGATION_HEIGHT: number = 64;
const TOUCH_RADIUS: number = 76;

/** 系统沉浸光感交给底部 TabBar；不支持时使用模糊玻璃和点按反馈。 */
class VividNavigationGlass {
  private static light: uiMaterial.ImmersiveMaterial | undefined = undefined;
  private static night: uiMaterial.ImmersiveMaterial | undefined = undefined;

  static get(night: boolean): uiMaterial.ImmersiveMaterial | undefined {
    if (deviceInfo.sdkApiVersion < 26) return undefined;
    try {
      if (!uiMaterial.isImmersiveMaterialSupported()) return undefined;
      const cached = night ? VividNavigationGlass.night : VividNavigationGlass.light;
      if (cached !== undefined) return cached;
      const material = new uiMaterial.ImmersiveMaterial({
        // ULTRA_THIN 才是最透的一档：内容能透出来，只保留轻微折射。
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        // 染色只用来保证图标可读，透明度给足，不能让表面变成一块盖板。
        materialColor: night ? '#1A0B1018' : '#12FFFFFF',
        colorInvert: false,
        // 外层胶囊自己画投影；材质再画一层会在胶囊内部形成一圈多余阴影。
        applyShadow: false,
        interactive: true,
        lightEffect: { color: '#FFFFFFFF' },
      });
      if (night) VividNavigationGlass.night = material;
      else VividNavigationGlass.light = material;
      return material;
    } catch (_error) {
      return undefined;
    }
  }
}

class VividNavigationTabsStyle implements AttributeModifier<TabsAttribute> {
  private night: boolean;
  constructor(night: boolean) { this.night = night; }

  applyNormalAttribute(instance: TabsAttribute): void {
    if (deviceInfo.sdkApiVersion < 26) return;
    const material = VividNavigationGlass.get(this.night);
    if (material === undefined) return;
    instance.barOverlap(true).vertical(false).barFloatingStyle({
      barWidth: { smallBarWidth: '100%', mediumBarWidth: '100%', largeBarWidth: '100%' },
      barSideMargin: 0,
      barBottomMargin: 0,
      maskColor: Color.Transparent,
      maskHeight: 0,
      systemMaterial: material,
    });
  }
}

/** 在父 Column 中实际占位；浮动样式仅发生在自身范围内。 */
@Component
export struct ImmersiveNavigationBar {
  @Prop items: VividNavigationItem[] = [];
  @Prop selectedKey: number = -1;
  @Prop compactLabels: boolean = false;
  /** 是否显示页签文字。首页底部导航只留图标（label 仍用于无障碍朗读）。 */
  @Prop showLabels: boolean = true;
  onSelect: (key: number) => void = () => {};
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @State private glowX: number = 0;
  @State private glowY: number = NAVIGATION_HEIGHT / 2;
  @State private glowOpacity: number = 0;
  private nativeGlass: boolean = VividNavigationGlass.get(false) !== undefined;

  private selectedPosition(): number {
    const position = this.items.findIndex((item: VividNavigationItem): boolean => item.key === this.selectedKey);
    return position >= 0 ? position : 0;
  }

  private foreground(): string {
    return this.isNightMode ? '#FFFFFF' : '#000000';
  }

  private handleTouch(event: TouchEvent): void {
    // Up/Cancel 的 touches 可能为空，先结束光效，避免松手后光斑停留。
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseOut }, () => {
        this.glowOpacity = 0;
      });
      return;
    }
    if (event.touches.length === 0) return;
    this.glowX = event.touches[0].x;
    this.glowY = event.touches[0].y;
    if (event.type === TouchType.Down) {
      this.getUIContext().animateTo({ duration: 80, curve: Curve.EaseOut }, () => {
        this.glowOpacity = this.isNightMode ? 0.38 : 0.72;
      });
    }
  }

  /**
   * Tabs 的页签内容：点按由页签自己处理。
   *
   * 不能只靠 `Tabs.onTabBarClick`：`index` 受控、点的又是当前项时（编辑页面板
   * 关闭时 selectedKey=-1 会回落到第 0 项），该回调会成串触发；编辑页的
   * 「再点一次收起」语义于是被开→关反复抵消，表现就是点调色不弹卡片。
   */
  @Builder
  TabBarItem(item: VividNavigationItem) {
    Column() {
      this.ItemContent(item, NAVIGATION_HEIGHT);
    }
    .width('100%')
    .height(NAVIGATION_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(item.label)
    .accessibilitySelected(this.selectedKey === item.key)
    .onClick(() => { this.onSelect(item.key); });
  }

  @Builder
  ItemContent(item: VividNavigationItem, slotHeight: number) {
    // 内容块固定 44 高，由外层 Stack 在「槽位高度」里垂直居中。
    // 这里必须用显式的槽位高度而不是 '100%'：首帧布局时百分比高度拿不到父尺寸，
    // 整块会被摆到槽位底部（表现为导航栏内容偏下），点了某一项触发重排后才回正。
    Column({ space: 2 }) {
        // 图标统一放进 24 高的盒子居中，各字形行高不同也不会错位。
        Stack({ alignContent: Alignment.Center }) {
          if (item.shape === 'eraser') {
            // 橡皮擦：斜放的圆角块 + 内部一条分界，字形库里没有对应字符，用图元画。
            Stack({ alignContent: Alignment.Center }) {
              Row()
                .width(15)
                .height(9)
                .borderRadius(2.5)
                .border({ width: 1.5, color: this.foreground() });
              Row()
                .width(1.5)
                .height(9)
                .backgroundColor(this.foreground())
                .offset({ x: -2.5 });
            }
            .width('100%')
            .height(24)
            .rotate({ angle: -34 });
          } else if (item.symbol !== undefined) {
            SymbolGlyph(item.symbol)
              .fontSize(22)
              .fontColor([this.foreground()]);
          } else {
            Text(item.glyph ?? '')
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.foreground());
          }
        }
        .width('100%')
        .height(24);

        if (this.showLabels) {
          Text(item.label)
            .fontSize(this.compactLabels ? 9 : 10)
            .height(13)
            .fontWeight(this.selectedKey === item.key ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.foreground())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }

        Row()
          .width(16)
          .height(3)
          .borderRadius(2)
          .backgroundColor(this.selectedKey === item.key ? this.foreground() : Color.Transparent);
    }
    .width('100%')
    .height(slotHeight)
    .justifyContent(FlexAlign.Center);
  }
  @Builder
  FallbackGlass() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 装饰层不参与命中，按钮和页面滚动各自处理交互。
      Column()
        .width(TOUCH_RADIUS * 2)
        .height(TOUCH_RADIUS * 2)
        .radialGradient({
          center: ['50%', '50%'], radius: TOUCH_RADIUS,
          colors: [['#B3FFFFFF', 0], ['#00FFFFFF', 1]],
        })
        .position({ x: this.glowX - TOUCH_RADIUS, y: this.glowY - TOUCH_RADIUS })
        .opacity(this.glowOpacity)
        .hitTestBehavior(HitTestMode.None);
      Row() {
        ForEach(this.items, (item: VividNavigationItem) => {
          Button({ type: ButtonType.Normal, stateEffect: false }) {
            this.ItemContent(item, 56);
          }
          .layoutWeight(1)
          .height(56)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .borderRadius(24)
          .accessibilityText(item.label)
          .accessibilitySelected(this.selectedKey === item.key)
          .onClick(() => { this.onSelect(item.key); });
        }, (item: VividNavigationItem): string => `${item.key}`);
      }
      .width('100%')
      .height(NAVIGATION_HEIGHT)
      .padding({ left: 6, right: 6 })
      .alignItems(VerticalAlign.Center);
    }
    .width('100%')
    .height(NAVIGATION_HEIGHT)
    .borderRadius(NAVIGATION_HEIGHT / 2)
    .backgroundColor(this.isNightMode ? '#480B1018' : '#26FFFFFF')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: this.isNightMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
    })
    .clip(true)
    .onTouch((event: TouchEvent) => { this.handleTouch(event); })
    .shadow({ radius: 16, color: this.isNightMode ? '#40000000' : '#14111C30', offsetY: 4 });
  }

  /** 点按光斑层：叠在导航表面之上，裁剪在胶囊圆角内，不参与命中。 */
  @Builder
  GlowOverlay() {
    Column() {
      if (this.glowOpacity > 0.01) {
        Column()
          .width(TOUCH_RADIUS * 2)
          .height(TOUCH_RADIUS * 2)
          .radialGradient({
            center: ['50%', '50%'], radius: TOUCH_RADIUS,
            colors: [['#CCFFFFFF', 0], ['#00FFFFFF', 1]],
          })
          .position({ x: this.glowX - TOUCH_RADIUS, y: this.glowY - TOUCH_RADIUS })
          .opacity(this.glowOpacity);
      }
    }
    .width('100%')
    .height(NAVIGATION_HEIGHT)
    .borderRadius(NAVIGATION_HEIGHT / 2)
    .clip(true)
    .hitTestBehavior(HitTestMode.None);
  }

  build() {
    Column() {
      if (this.nativeGlass) {
        // 系统沉浸材质（含 lightEffect 光感反馈）之上再叠一层自绘光斑：
        // TabBar 的点按由 Tabs 内部消费，系统光感不一定在页签上触发，
        // 这里保证"点在哪里、哪里就有一下亮光"。
        Stack() {
          Tabs({ barPosition: BarPosition.End, index: this.selectedPosition() }) {
            ForEach(this.items, (item: VividNavigationItem) => {
              TabContent() {}.tabBar(this.TabBarItem(item));
            }, (item: VividNavigationItem): string => `${item.key}`);
          }
          .width('100%')
          .height(NAVIGATION_HEIGHT)
          .barHeight(NAVIGATION_HEIGHT)
          .barMode(BarMode.Fixed)
          .scrollable(false)
          .animationDuration(0)
          .safeAreaPadding({ top: 1, bottom: 1 })
          .barBackgroundColor(Color.Transparent)
          // 沉浸材质的浮动 bar 默认吸附在胶囊底部，上方会空出一截（内容整体偏下）。
          // 给 Tabs 底部留同样的内边距，把 bar 顶回胶囊中间。
          .padding({ bottom: 6 })
          // Tabs 自身默认底色也要透明，否则会在材质之外再盖一层。
          .backgroundColor(Color.Transparent)
          .attributeModifier(new VividNavigationTabsStyle(this.isNightMode));

          this.GlowOverlay();
        }
        .width('100%')
        .height(NAVIGATION_HEIGHT)
        // 材质画的是 Tabs 那条整宽矩形，胶囊圆角之外会露出四个灰角（日间在
        // 纯白页面上尤其明显）。这里把整条裁剪成胶囊形状，只保留胶囊本体。
        .borderRadius(NAVIGATION_HEIGHT / 2)
        .clip(true)
        // 与面板/预览卡片同一套勾勒：1px 描边 + 20 半径投影，日间纯白页面上
        // 也能看清胶囊边界。
        .border({ width: 1, color: this.isNightMode ? '#26FFFFFF' : VividNative.separator })
        .shadow({ radius: 20, color: VividNative.shadowSm, offsetY: 8 })
        .onTouch((event: TouchEvent) => { this.handleTouch(event); });
      } else {
        this.FallbackGlass();
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    .flexShrink(0);
  }
}
