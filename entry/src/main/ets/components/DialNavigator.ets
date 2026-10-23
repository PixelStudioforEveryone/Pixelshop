import { VividNative } from './VividNativeTheme';

/**
 * 环形工具导航：中心圆 + 六等分按钮环。
 *
 * - 点按中心圆：展开 / 收起按钮环；
 * - 拖动中心圆：整体移动，拖动过程中只保留中心圆；
 * - 拖到屏幕边缘：收缩为一个宽度等于中心圆半径的圆角矩形，点按恢复；
 * - 回调契约与原 BottomToolbar 完全一致（index 走 togglePanel）。
 */
@Component
export struct DialNavigator {
  @Prop selectedIndex: number = -1;
  @Prop pageWidth: number = 0;
  @Prop pageHeight: number = 0;
  // 页面尺寸异步量出后经这里通知组件落位；@Watch 只能挂在状态变量上。
  @Prop @Watch('ensurePlaced') placeWatch: number = 0;
  onSelect?: (index: number) => void;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @State private centerX: number = -1;
  @State private centerY: number = -1;
  @State private expanded: boolean = true;
  @State private dragging: boolean = false;
  @State private collapsed: boolean = false;
  private dragOriginX: number = 0;
  private dragOriginY: number = 0;

  // 中心圆直径 / 半径；环半径与按钮直径由此推导。
  private static readonly CENTER_SIZE: number = 56;
  private static readonly RING_RADIUS: number = 86;
  private static readonly ITEM_SIZE: number = 46;
  private static readonly EDGE_PAD: number = 10;
  /** 中心圆命中区向外扩的边长：视觉圆 56，命中区 80，拖动/点按更容易按中。 */
  private static readonly HIT_EXPAND: number = 12;

  private get centerRadius(): number {
    return DialNavigator.CENTER_SIZE / 2;
  }

  private get dialSpan(): number {
    // 展开时整个控件的外接方形边长。
    return (DialNavigator.RING_RADIUS + DialNavigator.ITEM_SIZE / 2) * 2;
  }

  private tools: ToolEntry[] = [
    { index: 0, icon: '◫', label: '调色' },
    { index: 4, icon: '⊞', label: '裁剪' },
    { index: 1, icon: '▤', label: '图层' },
    { index: 3, icon: '◇', label: '预设' },
    { index: 5, icon: '▱', label: '修复' },
    { index: 6, icon: '◉', label: '红眼' },
  ];

  /** 页面尺寸到位后钉到右下角；用户拖过（centerX>=0）就不再动。 */
  private ensurePlaced(): void {
    if (this.centerX >= 0 || this.pageWidth <= 0 || this.pageHeight <= 0) return;
    this.centerX = this.pageWidth - this.dialSpan / 2 - DialNavigator.EDGE_PAD;
    this.centerY = this.pageHeight - this.dialSpan / 2 - DialNavigator.EDGE_PAD;
  }

  build() {
    if (this.collapsed) {
      this.CollapsedPill();
    } else {
      this.FullDial();
    }
  }

  /** 展开态：中心圆 + 六个环形按钮（拖动中只保留中心圆）。 */
  @Builder
  FullDial() {
    Stack() {
      if (this.expanded && !this.dragging) {
        ForEach(this.tools, (tool: ToolEntry, position: number) => {
          this.RingItem(tool, position);
        }, (tool: ToolEntry) => `${tool.index}`);
      }
      this.CenterKnob();
    }
    .width(this.dialSpan)
    .height(this.dialSpan)
    .hitTestBehavior(HitTestMode.Transparent)
    .position({ x: this.effectiveX() - this.dialSpan / 2, y: this.effectiveY() - this.dialSpan / 2 });
  }

  /** 页面尺寸是异步量出来的，首次构建时可能还是 0：默认钉在右下角。 */
  private effectiveX(): number {
    if (this.centerX >= 0) return this.centerX;
    return this.pageWidth > 0 ? this.pageWidth - this.dialSpan / 2 - DialNavigator.EDGE_PAD : 0;
  }

  private effectiveY(): number {
    if (this.centerY >= 0) return this.centerY;
    return this.pageHeight > 0 ? this.pageHeight - this.dialSpan / 2 - DialNavigator.EDGE_PAD : 0;
  }

  @Builder
  CenterKnob() {
    Column() {
      Text(this.expanded ? '−' : '+')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White);
    }
    .width(DialNavigator.CENTER_SIZE)
    .height(DialNavigator.CENTER_SIZE)
    .borderRadius(this.centerRadius)
    .backgroundColor(this.isNightMode ? '#334155' : VividNative.emphasize)
    .shadow({ radius: 12, color: VividNative.shadowSm, offsetY: 4 })
    // 可点/可拖的命中区比可见圆大一圈：手指按上去总有半截在圆内，避免"看着
    // 按到了却点不中"。视觉尺寸不变，只扩命中范围。
    .responseRegion({
      x: -DialNavigator.HIT_EXPAND,
      y: -DialNavigator.HIT_EXPAND,
      width: DialNavigator.CENTER_SIZE + DialNavigator.HIT_EXPAND * 2,
      height: DialNavigator.CENTER_SIZE + DialNavigator.HIT_EXPAND * 2,
    })
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture()
          .onAction(() => { this.expanded = !this.expanded; }),
        PanGesture({ fingers: 1, distance: 8 })
          .onActionStart(() => {
            this.dragging = true;
            this.dragOriginX = this.effectiveX();
            this.dragOriginY = this.effectiveY();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.moveTo(this.dragOriginX + event.offsetX, this.dragOriginY + event.offsetY);
          })
          .onActionEnd(() => { this.dragging = false; })
      )
    );
  }

  @Builder
  RingItem(tool: ToolEntry, position: number) {
    Column() {
      Text(tool.icon).fontSize(17).fontWeight(FontWeight.Medium)
        .fontColor(this.selectedColor(tool.index));
      Text(tool.label).fontSize(8).fontWeight(FontWeight.Medium)
        .fontColor(this.selectedColor(tool.index)).maxLines(1).margin({ top: 1 });
    }
    .width(DialNavigator.ITEM_SIZE)
    .height(DialNavigator.ITEM_SIZE)
    .justifyContent(FlexAlign.Center)
    .borderRadius(DialNavigator.ITEM_SIZE / 2)
    .backgroundColor(this.isSelected(tool.index)
      ? VividNative.emphasize
      : (this.isNightMode ? '#1E293BE6' : '#FFFFFFF0'))
    .border({ width: 1, color: this.isNightMode ? '#334155' : VividNative.separator })
    .shadow({ radius: 8, color: VividNative.shadowSm, offsetY: 2 })
    // -90° 起步（正上方），六等分顺时针排布。
    .position({
      x: this.dialSpan / 2 + DialNavigator.RING_RADIUS *
        Math.cos((-90 + position * 60) * Math.PI / 180) - DialNavigator.ITEM_SIZE / 2,
      y: this.dialSpan / 2 + DialNavigator.RING_RADIUS *
        Math.sin((-90 + position * 60) * Math.PI / 180) - DialNavigator.ITEM_SIZE / 2,
    })
    .onClick(() => { if (this.onSelect) this.onSelect(tool.index); });
  }

  /** 贴边收缩态：宽度 = 中心圆半径的圆角矩形，从边缘探出。 */
  @Builder
  CollapsedPill() {
    Column() {
      Text('⋯').fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor(Color.White);
    }
    .width(this.centerRadius)
    .height(DialNavigator.CENTER_SIZE)
    .borderRadius(this.centerRadius)
    .backgroundColor(this.isNightMode ? '#334155' : VividNative.emphasize)
    .shadow({ radius: 10, color: VividNative.shadowSm, offsetY: 3 })
    .position({ x: this.pillX(), y: this.effectiveY() - DialNavigator.CENTER_SIZE / 2 })
    .onClick(() => {
      this.collapsed = false;
      this.expanded = true;
      this.centerX = this.effectiveX();
      this.centerY = this.effectiveY();
      this.moveTo(this.centerX, this.centerY);
    });
  }

  private pillX(): number {
    // 收缩矩形宽 = 半径：贴左边缘时探出半个圆，贴右边缘同理。
    if (this.effectiveX() <= this.pageWidth / 2) {
      return DialNavigator.EDGE_PAD - this.centerRadius / 2;
    }
    return this.pageWidth - DialNavigator.EDGE_PAD - this.centerRadius / 2;
  }

  /** 限位移动：外接框一旦越过屏幕边缘就进入收缩态。 */
  private moveTo(x: number, y: number): void {
    if (this.pageWidth <= 0 || this.pageHeight <= 0) {
      this.centerX = x;
      this.centerY = y;
      return;
    }
    const half = this.dialSpan / 2;
    const clampedX = Math.max(half, Math.min(this.pageWidth - half, x));
    const clampedY = Math.max(half, Math.min(this.pageHeight - half, y));
    const overEdge = clampedX - half < DialNavigator.EDGE_PAD ||
      clampedX + half > this.pageWidth - DialNavigator.EDGE_PAD;
    this.centerX = clampedX;
    this.centerY = clampedY;
    this.collapsed = overEdge;
  }

  /** 图层与蒙版在环上合成一项：面板 1 与 2 共用同一格。 */
  private isSelected(index: number): boolean {
    return this.selectedIndex === index || (index === 1 && this.selectedIndex === 2);
  }

  private selectedColor(index: number): Resource | Color {
    if (this.isSelected(index)) return Color.White;
    return this.isNightMode ? Color.White : VividNative.textPrimary;
  }
}

interface ToolEntry {
  index: number;
  icon: string;
  label: string;
}
