import { webview } from '@kit.ArkWeb';

/**
 * 尼康云创内嵌网页的「返回桥」。
 *
 * 背景：ArkUI 只把系统返回手势 / 返回键回调交给 @Entry 页面（Index），
 * 挂在「风格库 → 尼康云创」页签里的 Web 组件拿不到这个回调，于是现在的
 * 表现是：在网页里翻了几层，一划返回就直接退回桌面。
 *
 * 做法：面板挂载时把自己的 WebviewController 注册到这里，并标记「当前
 * 是否显示给用户」；Index 在 onBackPress 里先问这里能不能后退——
 *   · 网页历史还有上一页 → 网页后退一级，手势被消费；
 *   · 已经退到最初的尼康云创主页（退无可退）→ 交回系统，由系统回桌面。
 *
 * 隐藏状态（切到作品/相机页、打开「我的」）时不吞手势：visible 为 false
 * 时一律返回「不能后退」，避免在别的页面上划返回却去动一个看不见的网页。
 */
export class NikonCloudBack {
  private static controller: webview.WebviewController | null = null;
  private static visible: boolean = false;

  /** 面板挂载：登记控制器。 */
  static attach(controller: webview.WebviewController): void {
    NikonCloudBack.controller = controller;
  }

  /** 面板卸载（切走页签）：注销，保持幂等。 */
  static detach(controller: webview.WebviewController): void {
    if (NikonCloudBack.controller === controller) {
      NikonCloudBack.controller = null;
      NikonCloudBack.visible = false;
    }
  }

  /** 面板是否正显示在用户眼前，由面板按当前页签 / 子页状态同步。 */
  static setVisible(value: boolean): void {
    NikonCloudBack.visible = value;
  }

  /** 网页是否还有上一页可退。 */
  static canGoBack(): boolean {
    if (!NikonCloudBack.visible) return false;
    const controller = NikonCloudBack.controller;
    if (controller === null) return false;
    try {
      return controller.accessBackward();
    } catch (_error) {
      // Web 尚未完成初始化时该接口会抛异常，按「不可后退」处理。
      return false;
    }
  }

  /** 网页后退一级。 */
  static goBack(): void {
    const controller = NikonCloudBack.controller;
    if (controller === null) return;
    try {
      controller.backward();
    } catch (_error) {
    }
  }
}
