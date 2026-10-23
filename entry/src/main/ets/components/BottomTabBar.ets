import { ImmersiveNavigationBar, VividNavigationItem } from './ImmersiveNavigationBar';

/** 首页常驻页签，只切换现有页面可见性。 */
@Component
export struct BottomTabBar {
  @Prop activeKey: number = -99;
  onSelect?: (key: number) => void;
  private items: VividNavigationItem[] = [
    { key: 0, label: '作品', symbol: $r('sys.symbol.picture') },
    { key: 1, label: '相机', symbol: $r('sys.symbol.camera') },
    { key: 3, label: 'LUT', symbol: $r('sys.symbol.film') },
    { key: -2, label: '我的', symbol: $r('sys.symbol.person') },
  ];

  build() {
    ImmersiveNavigationBar({
      items: this.items,
      selectedKey: this.activeKey,
      // 图标下面带中文标签（作品 / 相机 / LUT / 我的）。
      showLabels: true,
      onSelect: (key: number) => {
        if (key !== this.activeKey && this.onSelect !== undefined) this.onSelect(key);
      },
    });
  }
}
