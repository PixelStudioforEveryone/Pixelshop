import { ImmersiveNavigationBar, VividNavigationItem } from './ImmersiveNavigationBar';

@Component
export struct BottomToolbar {
  @Prop selectedIndex: number = -1;
  onSelect?: (index: number) => void;
  private items: VividNavigationItem[] = [
    { key: 0, label: '调色', glyph: '◫' },
    { key: 4, label: '裁剪', glyph: '⊞' },
    { key: 1, label: '图层', glyph: '▤' },
    { key: 7, label: '蒙版', glyph: '◧' },
    { key: 3, label: '预设', glyph: '◇' },
    { key: 5, label: '修复', shape: 'eraser' },
  ];

  build() {
    ImmersiveNavigationBar({
      items: this.items,
      // 面板 2 仍复用图层页（内部请求会把 2 归到 1），选中态也跟着落到「图层」。
      selectedKey: this.selectedIndex === 2 ? 1 : this.selectedIndex,
      compactLabels: true,
      onSelect: (key: number) => {
        if (this.onSelect !== undefined) this.onSelect(key);
      },
    });
  }
}
