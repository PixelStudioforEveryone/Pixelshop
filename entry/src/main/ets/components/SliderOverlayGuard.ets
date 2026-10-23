/**
 * 调色过程中临时隐藏蒙版叠加层。
 *
 * 需求很具体：拖调色滑杆时，红色的蒙版覆盖会挡住画面，看不清调色效果，所以
 * 要在拖动期间把它藏起来，松手后再显示。
 *
 * 这个开关由**所有调色滑杆共用**的组件（SliderControl / DesktopRawSlider）在
 * onBegin/onChange 里点亮、onEnd 里熄灭，因此不需要逐个面板改造；再给一个
 * 防抖兜底：有些面板只接了 onBegin/onChange 没接 onEnd，靠超时自动熄灭，避免
 * 叠加层永久消失。
 *
 * 注意这里只是**隐藏叠加层的显示**，蒙版本身照样生效——用户要的是"看得清调色
 * 结果"，不是"临时取消蒙版"。
 */

const HIDE_KEY: string = 'maskOverlayHiddenBySlider';
/** 松手后延迟恢复的时间：连续拖两个滑杆时不会闪一下。 */
const RESTORE_DELAY: number = 700;

let hideTimer: number = -1;

/** 滑杆正在被拖动（或刚被拖过）。 */
export function noteSliderInteracting(): void {
  AppStorage.setOrCreate(HIDE_KEY, true);
  if (hideTimer >= 0) clearTimeout(hideTimer);
  hideTimer = setTimeout(() => {
    hideTimer = -1;
    AppStorage.setOrCreate(HIDE_KEY, false);
  }, RESTORE_DELAY);
}

/** 滑杆拖动结束：立即恢复叠加层。 */
export function sliderInteractingEnded(): void {
  if (hideTimer >= 0) clearTimeout(hideTimer);
  hideTimer = -1;
  AppStorage.setOrCreate(HIDE_KEY, false);
}
