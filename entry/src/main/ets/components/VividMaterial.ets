import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { VividNative } from './VividNativeTheme';

/** Shared native material; retain a frosted surface on older systems/devices. */
export class VividMaterial implements AttributeModifier<CommonAttribute> {
  static readonly card: VividMaterial = new VividMaterial(false, false);
  static readonly cardNight: VividMaterial = new VividMaterial(false, true);
  static readonly navigation: VividMaterial = new VividMaterial(true, false);
  static readonly navigationNight: VividMaterial = new VividMaterial(true, true);
  readonly material: uiMaterial.ImmersiveMaterial | undefined = undefined;

  private navigation: boolean;
  private night: boolean;

  constructor(navigation: boolean, night: boolean = false) {
    this.navigation = navigation;
    this.night = night;
    if (deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported()) {
      this.material = new uiMaterial.ImmersiveMaterial({
        style: navigation ? uiMaterial.ImmersiveStyle.THIN : uiMaterial.ImmersiveStyle.REGULAR,
        // The light tint relies on backdrop sampling to look dark; when the
        // compositor paints the material flat (PC/desktop windows) it shows
        // near-white. Night variants carry a dark tint so the surface stays
        // dark under white text in every rendering mode.
        materialColor: night ? '#B80E1320' : '#12EAF1FF',
        applyShadow: true,
        // Keep API 26's interactive highlight/refraction animation enabled.
        // Child controls still own their gesture events; the material only
        // supplies the surface feedback and does not alter their layout.
        interactive: true,
      });
    }
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    if (this.material && deviceInfo.sdkApiVersion >= 26) {
      // API 26 owns the filter, refraction, highlight and shadow as one
      // surface. Keeping this in a modifier lets every adjustment card use
      // the same material without duplicating SDK guards in each panel.
      instance.systemMaterial(this.material);
      return;
    }
    // 非 API 26 或无原生材质时的兜底：填充/描边/阴影改用系统资源令牌，
    // 日夜由应用 colorMode 统一决定（手动切换会 setColorMode，令牌随之变化）。
    if (this.night) {
      instance.backgroundColor(VividNative.surfacePanel)
        .backgroundBlurStyle(this.navigation ? BlurStyle.Thin : BlurStyle.Regular,
          { colorMode: ThemeColorMode.SYSTEM })
        .border({ width: 1, color: VividNative.focusOutline })
        .shadow({ radius: 20, color: VividNative.shadowFloating, offsetY: 6 });
      return;
    }
    instance.backgroundColor(VividNative.surfaceCard)
      .backgroundBlurStyle(this.navigation ? BlurStyle.Thin : BlurStyle.Regular,
        { colorMode: ThemeColorMode.SYSTEM })
      .border({ width: 1, color: VividNative.separator })
      .shadow({ radius: 20, color: VividNative.shadowSm, offsetY: 6 });
  }
}

/** Slider uses native preset material and its system-managed particle animation. */
export class VividSliderMaterial implements AttributeModifier<SliderAttribute> {
  applyNormalAttribute(instance: SliderAttribute): void {
    const material = VividMaterial.navigation.material;
    if (deviceInfo.sdkApiVersion >= 26 && material) instance.systemMaterial(material);
  }
}

export class VividFloatingTabs implements AttributeModifier<TabsAttribute> {
  private bottomMargin: number = 40;
  private night: boolean = false;

  constructor(bottomMargin: number = 40, night: boolean = false) {
    this.bottomMargin = bottomMargin;
    this.night = night;
  }

  applyNormalAttribute(instance: TabsAttribute): void {
    if (deviceInfo.sdkApiVersion >= 26) {
      instance.barOverlap(true).vertical(false).barFloatingStyle({
        barSideMargin: 18, barBottomMargin: this.bottomMargin,
        // Do not add the API 26 floating-tab mask below the bar. On dark
        // surfaces that default mask renders as a bright white glow over the
        // transparent system navigation area.
        maskColor: '#00000000', maskHeight: 0,
        systemMaterial: this.night ? VividMaterial.navigationNight.material : VividMaterial.navigation.material
      });
    }
  }
}
