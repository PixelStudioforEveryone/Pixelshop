/**
 * 全局圆环导航：中心圆 + 四片花瓣（作品 / 相机 / LUT / 我的），整体呈四叶草。
 *
 * - 点按中心圆：四片花瓣像扇子一样顺时针展开 / 收拢（各 1 秒）；
 * - 拖动中心圆：整体移动，拖动过程中只保留中心圆；
 * - 拖到屏幕左右边缘：吸附为半隐藏的小胶囊，点按恢复；
 * - 花瓣只显示简图图标，不显示文字；当前页花瓣高亮。
 *
 * 展开动画的实现要点：花瓣的 position 固定钉在最终位置，动画只改
 * `rotate`（旋转中心指定为环心，即元素外部的一点）与 `opacity`。
 * 这样每片花瓣都是「从正上方起、顺时针扫到自己位置」，四片一起看
 * 就是扇子展开；不改布局属性，动画不会触发重新测量，最稳妥。
 *
 * 几何常量一律放在模块作用域：组件内不用 `static readonly` 与 `get`
 * 访问器，避免尺寸算成 NaN 导致整个组件静默不显示（本代码库其余组件
 * 也都是普通方法 + 字面量）。
 */
const CENTER_SIZE: number = 46;
/** 花瓣中心到环心的距离：等于中心圆半径 + 花瓣半径，四瓣与中心圆相切成四叶草。 */
const RING_RADIUS: number = 42;
const ITEM_SIZE: number = 38;
const EDGE_PAD: number = 8;
/** 展开态外接方形边长：(42 + 19) * 2 = 122。 */
const RING_SPAN: number = (RING_RADIUS + ITEM_SIZE / 2) * 2;
/** 默认停靠时外接方形离屏幕边缘的距离（右下角）。 */
const DEFAULT_MARGIN: number = 16;
/** 尺寸还没量出来时的兜底落位（顶部居中）。 */
const FALLBACK_CENTER_X: number = 195;
const FALLBACK_CENTER_Y: number = 176;
/** 拖动限位：不要顶到状态栏 / 顶栏上。 */
const MIN_CENTER_Y: number = 100;
/** 扇子展开 / 收拢时长（毫秒）。 */
const FAN_DURATION: number = 1000;

@Component
export struct RingNavigator {
  /** 0 作品 / 1 相机 / 3 LUT / -1 我的（与 Index 的 section/profile 编号一致）。 */
  @Prop activeKey: number = -99;
  /** 屏幕宽度（vp），用于默认落位与贴边吸附判断。 */
  @Prop pageWidth: number = 0;
  /** 屏幕高度（vp），用于默认落在右下角与纵向限位。 */
  @Prop pageHeight: number = 0;
  onSelect?: (key: number) => void;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  @State private centerX: number = -1;
  @State private centerY: number = -1;
  @State private expanded: boolean = true;
  @State private dragging: boolean = false;
  @State private collapsed: boolean = false;
  /** 扇面进度：1 = 完全展开，0 = 四片叠在正上方。 */
  @State private fan: number = 1;
  /** 收拢动画播完后卸掉花瓣节点，避免透明节点继续吃点击。 */
  @State private petalsMounted: boolean = true;
  private fanTimer: number = -1;
  private dragOriginX: number = 0;
  private dragOriginY: number = 0;

  /** 四个页签按四叶草均分：顶部作品、右侧相机、底部 LUT、左侧我的。 */
  private keys: number[] = [0, 1, 3, -2];

  aboutToDisappear(): void {
    if (this.fanTimer !== -1) {
      clearTimeout(this.fanTimer);
      this.fanTimer = -1;
    }
  }

  /** NaN / 非法尺寸兜底：NaN 参与任何比较都是 false，故这里能拦下来。 */
  private isUsable(value: number): boolean {
    return value > 0 && value < 100000;
  }

  /**
   * 展开态中心点 x：默认停靠屏幕右下角（由当前尺寸推导），
   * 用户拖动过（centerX>=0）之后就锁定在拖到的位置。
   */
  private centerPointX(): number {
    if (this.centerX >= 0) return this.centerX;
    if (this.isUsable(this.pageWidth)) {
      return this.pageWidth - RING_SPAN / 2 - DEFAULT_MARGIN;
    }
    return FALLBACK_CENTER_X;
  }

  /** 展开态中心点 y：默认贴右下角，尺寸没量出来时退回顶部居中。 */
  private centerPointY(): number {
    if (this.centerY >= 0) return this.centerY;
    if (this.isUsable(this.pageHeight)) {
      return this.pageHeight - RING_SPAN / 2 - DEFAULT_MARGIN;
    }
    return FALLBACK_CENTER_Y;
  }

  build() {
    // 全屏穿透层：自身与空白区域放行点击，四叶草/胶囊是其中的定位子节点。
    Stack() {
      if (this.collapsed) {
        this.CollapsedPill();
      } else {
        this.FullRing();
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.TopStart)
    .hitTestBehavior(HitTestMode.Transparent);
  }

  /** 展开态：中心圆 + 四片花瓣（拖动中只保留中心圆）。 */
  @Builder
  FullRing() {
    Stack() {
      if (this.petalsMounted && !this.dragging) {
        ForEach(this.keys, (key: number, position: number) => {
          this.RingItem(key, position);
        }, (key: number) => `${key}`);
      }
      this.CenterKnob();
    }
    .width(RING_SPAN)
    .height(RING_SPAN)
    .hitTestBehavior(HitTestMode.Transparent)
    .position({
      x: this.centerPointX() - RING_SPAN / 2,
      y: this.centerPointY() - RING_SPAN / 2,
    });
  }

  /** 中心圆：透明玻璃面，不带图标，点按开合扇面，拖动移动整组。 */
  @Builder
  CenterKnob() {
    Stack()
      .width(CENTER_SIZE)
      .height(CENTER_SIZE)
      .borderRadius(CENTER_SIZE / 2)
      .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.SYSTEM })
      .backgroundColor(this.isNightMode ? 'rgba(18,24,38,0.55)' : 'rgba(255,255,255,0.46)')
      .border({
        width: 1,
        color: this.isNightMode ? 'rgba(255,255,255,0.24)' : 'rgba(255,255,255,0.86)',
      })
      .shadow({
        radius: 14,
        color: this.isNightMode ? 'rgba(0,0,0,0.5)' : 'rgba(15,23,42,0.18)',
        offsetY: 4,
      })
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          TapGesture()
            .onAction(() => { this.toggleFan(); }),
          PanGesture({ fingers: 1, distance: 8 })
            .onActionStart(() => {
              this.dragging = true;
              this.dragOriginX = this.centerPointX();
              this.dragOriginY = this.centerPointY();
            })
            .onActionUpdate((event: GestureEvent) => {
              this.moveTo(this.dragOriginX + event.offsetX, this.dragOriginY + event.offsetY);
            })
            .onActionEnd(() => { this.dragging = false; })
        )
      );
  }

  @Builder
  RingItem(key: number, position: number) {
    Stack() {
      SymbolGlyph(this.itemSymbol(key))
        .fontSize(20)
        .fontColor([this.itemIconColor(key)]);
    }
    .width(ITEM_SIZE)
    .height(ITEM_SIZE)
    .borderRadius(ITEM_SIZE / 2)
    .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.SYSTEM })
    .backgroundColor(this.itemBackdrop(key))
    .border({ width: 1, color: this.itemBorder(key) })
    .shadow({
      radius: 10,
      color: this.isNightMode ? 'rgba(0,0,0,0.45)' : 'rgba(15,23,42,0.16)',
      offsetY: 2,
    })
    // 位置固定钉在四叶草的最终落点。
    .position({ x: this.itemLeft(position), y: this.itemTop(position) })
    // 扇面动画：绕环心旋转（中心点在元素外部），从正上方顺时针扫到位。
    .rotate({
      angle: this.itemSweep(position),
      centerX: this.pivotX(position),
      centerY: this.pivotY(position),
    })
    .opacity(this.petalOpacity())
    .onClick(() => { if (this.onSelect) this.onSelect(key); });
  }

  /** 贴边吸附态：宽度 = 中心圆半径的圆角矩形，从边缘探出一半。 */
  @Builder
  CollapsedPill() {
    Stack() {
      SymbolGlyph($r('sys.symbol.circle'))
        .fontSize(10)
        .fontColor([this.isNightMode ? Color.White : '#2B3A55']);
    }
    .width(CENTER_SIZE / 2)
    .height(CENTER_SIZE)
    .borderRadius(CENTER_SIZE / 2)
    .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.SYSTEM })
    .backgroundColor(this.isNightMode ? 'rgba(18,24,38,0.55)' : 'rgba(255,255,255,0.46)')
    .border({
      width: 1,
      color: this.isNightMode ? 'rgba(255,255,255,0.24)' : 'rgba(255,255,255,0.86)',
    })
    .shadow({
      radius: 10,
      color: this.isNightMode ? 'rgba(0,0,0,0.45)' : 'rgba(15,23,42,0.16)',
      offsetY: 3,
    })
    .position({
      x: this.pillX(),
      y: this.centerPointY() - CENTER_SIZE / 2,
    })
    .onClick(() => {
      this.collapsed = false;
      this.expanded = true;
      this.fan = 1;
      this.petalsMounted = true;
    });
  }

  // ---- 扇面几何 ----

  /** 第 position 片花瓣的最终方位角（-90° 起步，顺时针 90° 一片）。 */
  private itemAngle(position: number): number {
    return -90 + position * 90;
  }

  private itemLeft(position: number): number {
    const rad = this.itemAngle(position) * Math.PI / 180;
    return RING_SPAN / 2 + RING_RADIUS * Math.cos(rad) - ITEM_SIZE / 2;
  }

  private itemTop(position: number): number {
    const rad = this.itemAngle(position) * Math.PI / 180;
    return RING_SPAN / 2 + RING_RADIUS * Math.sin(rad) - ITEM_SIZE / 2;
  }

  /** 绕环心的旋转角：展开为 0，收拢时每片逆时针退回 position*90°（即都叠在正上方）。 */
  private itemSweep(position: number): number {
    return -(1 - this.fan) * position * 90;
  }

  /** 旋转中心（环心）在第 position 片花瓣自身坐标系里的 x 偏移。 */
  private pivotX(position: number): number {
    const rad = this.itemAngle(position) * Math.PI / 180;
    return ITEM_SIZE / 2 - RING_RADIUS * Math.cos(rad);
  }

  /** 旋转中心（环心）在第 position 片花瓣自身坐标系里的 y 偏移。 */
  private pivotY(position: number): number {
    const rad = this.itemAngle(position) * Math.PI / 180;
    return ITEM_SIZE / 2 - RING_RADIUS * Math.sin(rad);
  }

  /** 扇面合拢时四片叠在正上方，所以末段淡出，避免看到一摞圆片。 */
  private petalOpacity(): number {
    return Math.min(1, this.fan * 4);
  }

  /** 点按中心圆：展开 / 收拢扇面，各 1 秒。 */
  private toggleFan(): void {
    if (this.fanTimer !== -1) {
      clearTimeout(this.fanTimer);
      this.fanTimer = -1;
    }
    if (this.expanded) {
      // 先播收拢动画，再卸节点。
      this.expanded = false;
      this.animateFan(0);
      this.fanTimer = setTimeout(() => {
        this.petalsMounted = false;
        this.fanTimer = -1;
      }, FAN_DURATION);
      return;
    }
    // 先挂上花瓣（此时 fan=0，全部叠在正上方），下一帧再展开。
    this.petalsMounted = true;
    this.fanTimer = setTimeout(() => {
      this.expanded = true;
      this.animateFan(1);
      this.fanTimer = -1;
    }, 16);
  }

  private animateFan(target: number): void {
    this.getUIContext().animateTo({ duration: FAN_DURATION, curve: Curve.EaseOut }, () => {
      this.fan = target;
    });
  }

  // ---- 其余 ----

  private pillX(): number {
    // 吸附矩形宽 = 半径：贴左边缘时探出半个圆，贴右边缘同理。
    if (this.centerPointX() <= this.pageWidth / 2) {
      return EDGE_PAD - CENTER_SIZE / 4;
    }
    return this.pageWidth - EDGE_PAD - CENTER_SIZE / 4;
  }

  /** 限位移动：不超出屏幕，靠近左右边缘就吸附为半隐藏胶囊。 */
  private moveTo(x: number, y: number): void {
    if (!this.isUsable(this.pageWidth)) {
      this.centerX = x;
      this.centerY = y;
      return;
    }
    const half = RING_SPAN / 2;
    const clampedX = Math.max(half, Math.min(this.pageWidth - half, x));
    // 纵向限位用真实屏高：上不顶状态栏/顶栏，下不压系统导航条。
    const maxY = this.isUsable(this.pageHeight)
      ? Math.max(MIN_CENTER_Y, this.pageHeight - half - EDGE_PAD)
      : 900;
    const clampedY = Math.max(MIN_CENTER_Y, Math.min(maxY, y));
    const nearEdge = clampedX - half < EDGE_PAD ||
      clampedX + half > this.pageWidth - EDGE_PAD;
    this.centerX = clampedX;
    this.centerY = clampedY;
    this.collapsed = nearEdge;
  }

  /** 页签简图：作品=图片、相机=相机、LUT=胶片、我的=人物。 */
  private itemSymbol(key: number): Resource {
    if (key === 0) return $r('sys.symbol.picture');
    if (key === 1) return $r('sys.symbol.camera');
    if (key === 3) return $r('sys.symbol.film');
    return $r('sys.symbol.person');
  }

  private itemIsActive(key: number): boolean {
    // key -2 表示「我的」页（profile），对应 activeKey -1。
    return key === this.activeKey || (key === -2 && this.activeKey === -1);
  }

  /** 玻璃面上的底色：选中态给一层强调色，未选中只留薄薄的高光。 */
  private itemBackdrop(key: number): string {
    if (this.itemIsActive(key)) return 'rgba(59,110,246,0.88)';
    return this.isNightMode ? 'rgba(18,24,38,0.5)' : 'rgba(255,255,255,0.4)';
  }

  private itemBorder(key: number): string {
    if (this.itemIsActive(key)) return 'rgba(255,255,255,0.6)';
    return this.isNightMode ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.8)';
  }

  private itemIconColor(key: number): ResourceColor {
    if (this.itemIsActive(key)) return Color.White;
    return this.isNightMode ? Color.White : '#2B3A55';
  }
}
