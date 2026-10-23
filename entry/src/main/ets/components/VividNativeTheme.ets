import { LengthMetrics } from '@kit.ArkUI';

/**
 * 共享的「鸿蒙原生」样式令牌。
 *
 * 设计约束（本轮 UI 任务）：
 * - 只使用本地 SDK 资源表里确实存在的名称。名称清单来自
 *   `<SDK>/default/openharmony/ets/build-tools/ets-loader/sysResource.js`
 *   的 `sys.color` / `sys.float` 两张表；编译期由 ets-loader 校验，写错会直接编译失败。
 * - 颜色一律用 `sys.color.*` 而非硬编码十六进制：这些资源自带日间/夜间限定，
 *   应用手动切换日/夜间时会走 `setColorMode(DARK|LIGHT)`（见 EntryAbility/Index/EditorPage），
 *   因此原生令牌与现有手动切换天然兼容，不需要为每个控件再写一份 night 分支。
 * - 圆角一律用 `sys.float.ohos_id_corner_radius_*`，保持系统控件的圆角语义。
 *
 * 明确未验证项：本机没有真机/模拟器，**具体 RGB 取值无法在本轮核对**，
 * 只能核对“资源名存在于 SDK 资源表”。设备上的实际取色需要真机/模拟器验收。
 *
 * 本文件只放两样东西：`VividNative` 令牌表 + `VividNumberField` 文本框外观。
 * 自定义容器的“按压态”没有做成共享 AttributeModifier：pressed/focused 状态回调
 * 只能靠设备验收，本轮不引入不可本地验证的机制；状态反馈统一用原生
 * ButtonStyleMode / hoverEffect / focusBox / enabled 承担。
 */
export class VividNative {
  // ---- 主题色 / 强调色 ----
  /** 系统主题强调色（Toggle/Slider/Chip/SegmentButton 的默认选中色都是它）。 */
  static readonly emphasize: Resource = $r('sys.color.ohos_id_color_emphasize');
  /** 强调色之上的前景色（选中态文字/图标）。 */
  static readonly onEmphasize: Resource = $r('sys.color.ohos_id_color_emphasize_contrary');
  /** 通用“已激活”底色。 */
  static readonly activated: Resource = $r('sys.color.ohos_id_color_activated');
  /** 控件常态底色（未选中轨道/未选中面）。 */
  static readonly componentNormal: Resource = $r('sys.color.ohos_id_color_component_normal');
  /** 控件激活底色。 */
  static readonly componentActivated: Resource = $r('sys.color.ohos_id_color_component_activated');

  // ---- 文字 ----
  static readonly textPrimary: Resource = $r('sys.color.ohos_id_color_text_primary');
  static readonly textSecondary: Resource = $r('sys.color.ohos_id_color_text_secondary');
  static readonly textTertiary: Resource = $r('sys.color.ohos_id_color_text_tertiary');
  static readonly textHint: Resource = $r('sys.color.ohos_id_color_text_hint');
  static readonly textPrimaryActivated: Resource = $r('sys.color.ohos_id_color_text_primary_activated');
  static readonly textSecondaryActivated: Resource = $r('sys.color.ohos_id_color_text_secondary_activated');

  // ---- 面板 / 卡片填充 ----
  /** 浮层面板（底部抽屉、检查器正文）的底色。 */
  static readonly surfacePanel: Resource = $r('sys.color.ohos_id_color_dialog_bg');
  /** 卡片底色。 */
  static readonly surfaceCard: Resource = $r('sys.color.ohos_id_color_card_bg');
  /** 次级底色（分组头、分区标题条）。 */
  static readonly surfaceSub: Resource = $r('sys.color.ohos_id_color_sub_background');
  /** 窗口底色。 */
  static readonly surfaceWindow: Resource = $r('sys.color.ohos_id_color_background');
  /** 普通按钮底色。 */
  static readonly buttonNormal: Resource = $r('sys.color.ohos_id_color_button_normal');
  /** 按钮/卡片描边。 */
  static readonly borderButton: Resource = $r('sys.color.button_border_color');
  /** 列表分隔线。 */
  static readonly separator: Resource = $r('sys.color.ohos_id_color_list_separator');
  /** 通用分隔线。 */
  static readonly divider: Resource = $r('sys.color.ohos_id_divider_color');

  // ---- 状态反馈 ----
  /** 按压反馈色（系统点击涟漪/高亮）。 */
  static readonly clickEffect: Resource = $r('sys.color.ohos_id_color_click_effect');
  /** 悬停反馈色（PC 鼠标悬停）。 */
  static readonly hover: Resource = $r('sys.color.ohos_id_color_hover');
  /** 键盘焦点描边。 */
  static readonly focusOutline: Resource = $r('sys.color.ohos_id_color_focused_outline');
  /** 应用主题焦点色。 */
  static readonly focusColor: Resource = $r('sys.color.app_theme_focus_color');
  static readonly warning: Resource = $r('sys.color.ohos_id_color_warning');
  static readonly alert: Resource = $r('sys.color.ohos_id_color_alert');
  /** 告警状态的容器底色（低强调），与 warning 前景成对使用。 */
  static readonly warningContainer: Resource = $r('sys.color.comp_background_warning_secondary');

  // ---- 文本框（TextInput / Select）原生参数 ----
  static readonly fieldBg: Resource = $r('sys.color.ohos_id_color_text_field_bg');
  static readonly fieldBorder: Resource = $r('sys.color.text_input_border_color');
  static readonly fieldBorderWidth: Resource = $r('sys.float.text_input_border_width');
  static readonly fieldCursor: Resource = $r('sys.color.textfield_cursor_color');
  static readonly fieldRadius: Resource = $r('sys.float.ohos_id_corner_radius_text_field');
  /** TextInput 默认高度：原生尺寸，交给系统。 */
  static readonly fieldHeight: Resource = $r('sys.float.ohos_id_textfield_height');

  // ---- Slider 原生参数（彩色渐变滑杆仍然自绘轨道，见 DesktopRawSlider/SliderControl） ----
  static readonly sliderTrack: Resource = $r('sys.color.slider_outset_and_none_track_color');
  static readonly sliderSelected: Resource = $r('sys.color.slider_color_emphasize');
  // Custom gradient tracks need a contrasting thumb in both color modes;
  // slider_color_foreground resolves to near-black on the dark emulator.
  static readonly sliderBlock: Resource = $r('sys.color.ohos_id_color_text_primary');

  // ---- 圆角（原生设计系统令牌） ----
  static readonly radiusPanel: Resource = $r('sys.float.ohos_id_corner_radius_panel');
  static readonly radiusCard: Resource = $r('sys.float.ohos_id_corner_radius_card');
  static readonly radiusDialog: Resource = $r('sys.float.ohos_id_corner_radius_dialog');
  static readonly radiusMenu: Resource = $r('sys.float.ohos_id_corner_radius_menu');
  static readonly radiusButton: Resource = $r('sys.float.ohos_id_corner_radius_button');
  static readonly radiusSmallButton: Resource = $r('sys.float.ohos_id_corner_radius_small_button');
  static readonly radiusClicked: Resource = $r('sys.float.ohos_id_corner_radius_clicked');
  static readonly radiusField: Resource = $r('sys.float.ohos_id_corner_radius_text_field');
  static readonly radiusLevel4: Resource = $r('sys.float.corner_radius_level4');
  static readonly radiusLevel8: Resource = $r('sys.float.corner_radius_level8');
  static readonly radiusLevel12: Resource = $r('sys.float.corner_radius_level12');
  static readonly radiusLevel16: Resource = $r('sys.float.corner_radius_level16');

  // ---- 禁用反馈 ----
  /** 系统禁用透明度（同 `interactive_disable`）。 */
  static readonly disabledAlpha: Resource = $r('sys.float.ohos_id_alpha_disabled');
  /** 兜底禁用透明度：资源取不到时仍能看出禁用态。 */
  static readonly disabledAlphaFallback: number = 0.4;

  // ---- 阴影 ----
  static readonly shadowSm: Resource = $r('sys.color.ohos_id_shadow_default_sm');
  static readonly shadowFloating: Resource = $r('sys.color.ohos_id_shadow_floating_md');

  /** 原生焦点框：PC 外接键盘 Tab 导航时由系统绘制。 */
  static focusBox(strokeVp: number = 2, marginVp: number = 0): FocusBoxStyle {
    return {
      margin: LengthMetrics.vp(marginVp),
      strokeWidth: LengthMetrics.vp(strokeVp),
    };
  }
}

/**
 * 数值文本框（DesktopRawSlider 的 Camera Raw 数值格子）的原生外观。
 * 保留 `InputType.Normal`：`InputType.Number` 明确不支持负号与小数点，
 * 而调色参数（-1.00 / 0.35 / 5000K）需要负号与小数，换类型会破坏功能。
 */
export class VividNumberField implements AttributeModifier<TextInputAttribute> {
  static readonly field: VividNumberField = new VividNumberField();
  /**
   * 无框无填充：调色面板只显示数值本身（用户要求去掉数值框与填充），
   * 仍然可点入编辑、保留小数点与负号的 Normal 输入类型。
   */
  static readonly plain: VividNumberField = new VividNumberField(true);

  private readonly bare: boolean = false;

  constructor(bare: boolean = false) { this.bare = bare; }

  applyNormalAttribute(instance: TextInputAttribute): void {
    if (this.bare) {
      instance
        .backgroundColor(Color.Transparent)
        .border({ width: 0 })
        .borderRadius(0)
        .fontColor(VividNative.textPrimary)
        .caretColor(VividNative.fieldCursor)
        .selectedBackgroundColor(VividNative.emphasize)
        .enterKeyType(EnterKeyType.Done)
        .hoverEffect(HoverEffect.None);
      return;
    }
    instance
      .backgroundColor(VividNative.fieldBg)
      .border({ width: 1, color: VividNative.fieldBorder })
      .borderRadius(VividNative.fieldRadius)
      .fontColor(VividNative.textPrimary)
      .caretColor(VividNative.fieldCursor)
      .selectedBackgroundColor(VividNative.emphasize)
      .enterKeyType(EnterKeyType.Done)
      .hoverEffect(HoverEffect.Highlight);
  }

  applyFocusedAttribute(instance: TextInputAttribute): void {
    if (this.bare) {
      // 聚焦也不再画框：只留光标，保持"纯数值"外观。
      instance
        .border({ width: 0 })
        .backgroundColor(Color.Transparent);
      return;
    }
    instance
      .border({ width: 2, color: VividNative.focusColor })
      .backgroundColor(VividNative.fieldBg);
  }

  applyDisabledAttribute(instance: TextInputAttribute): void {
    instance.opacity(VividNative.disabledAlphaFallback);
  }
}
