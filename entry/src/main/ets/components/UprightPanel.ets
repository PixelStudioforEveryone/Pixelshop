import { EditSession } from '../edit/models/EditSession';
import { ToolType } from '../edit/models/ToolType';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import { UprightMode, UprightSolution } from '../edit/engine/UprightSolver';
import { VividNative } from './VividNativeTheme';

/**
 * Upright: draw reference lines, solve the perspective and straighten from them.
 *
 * This panel does not render anything itself. A solve writes the three manual
 * geometry fields the engine already has, so both the CPU and the GPU pick the
 * result up through uniforms that were already being uploaded. That is also why
 * there is no GPU bypass here: there is no new stage to bypass.
 */
interface UprightModeOption {
  mode: number;
  label: string;
}

const UPRIGHT_MODES: UprightModeOption[] = [
  { mode: UprightMode.LEVEL, label: '水平' },
  { mode: UprightMode.PERSPECTIVE, label: '透视' },
  { mode: UprightMode.FULL, label: '完整' },
];

@Component
export struct UprightPanel {
  @Consume('editSession') editSession: EditSession;
  @StorageProp('vividNightMode') private isNightMode: boolean = false;
  // The canvas solves when a guide is drawn, so the panel has to hear about a
  // solve it did not initiate.
  @StorageProp('uprightRevision') @Watch('onUprightChanged') private uprightRevision: number = 0;
  /** 嵌入裁剪页时由外层提供“透视 · 拉直”标题。 */
  @Prop nested: boolean = false;
  /** 裁剪页内：结束参考线绘制后回到 CROP 工具，而不是普通调色工具。 */
  @Prop cropEmbedded: boolean = false;
  @State private guideMode: boolean = false;
  @State private verticalCount: number = 0;
  @State private horizontalCount: number = 0;
  @State private solvedVertical: number = 0;
  @State private solvedHorizontal: number = 0;
  @State private solvedRotation: number = 0;
  @State private residual: number = 0;

  aboutToAppear(): void {
    this.guideMode = this.editSession.activeTool === ToolType.UPRIGHT;
    // 只读解算，不写 geometry：挂载在裁剪页时不能因为打开页面就把用户的手动
    // 垂直/水平/旋转值清零。只有用户主动改模式/删线/清空才写回。
    this.refresh(false);
  }

  private onUprightChanged(): void {
    // Canvas 已经解算并写回，这里只刷新读数，避免重复写 geometry。
    this.refresh(false);
  }

  /** Solve through the session so the panel, the canvas and the tests share one
   *  code path, then publish the readout rather than implying it always worked.
   *  `apply=false` is the read-only form used on mount. */
  private refresh(apply: boolean = true): void {
    const solution: UprightSolution = this.editSession.solveUprightGuides(apply);
    this.verticalCount = solution.verticalGuides;
    this.horizontalCount = solution.horizontalGuides;
    this.solvedVertical = solution.verticalPerspective;
    this.solvedHorizontal = solution.horizontalPerspective;
    this.solvedRotation = solution.rotation;
    this.residual = solution.residual;
  }

  private applyMode(mode: number): void {
    if (this.editSession.upright.mode === mode) return;
    this.editSession.pushUndo();
    this.editSession.upright.mode = mode;
    // 没有参考线时只切换模式并刷新读数，不写 geometry：否则在裁剪页点一下
    // 模式就会把用户手动设置的垂直/水平/旋转清零。
    if (this.editSession.upright.guides.length === 0) {
      this.refresh(false);
      this.reprocess();
      return;
    }
    this.refresh();
    this.reprocess();
  }

  private removeLast(): void {
    if (this.editSession.upright.guides.length === 0) return;
    this.editSession.pushUndo();
    const kept = this.editSession.upright.guides.slice(0, this.editSession.upright.guides.length - 1);
    this.editSession.upright.guides = kept;
    this.refresh();
    this.reprocess();
  }

  private clearAll(): void {
    if (this.editSession.upright.guides.length === 0) return;
    this.editSession.pushUndo();
    this.editSession.upright.clear();
    // Re-solves to an empty solution, which writes zeros back into the three
    // geometry fields: removing the guides restores the manual values instead of
    // leaving a stale correction behind.
    this.refresh();
    this.reprocess();
  }

  private reprocess(): void {
    this.editSession.bumpProcessing();
    // 参考线/解算结果变了，画布叠加层需要按新几何重画。
    AppStorage.setOrCreate('cropOverlayRevision', Date.now());
    ImageProcessor.process(this.editSession);
  }

  private textColor(): Resource {
    return VividNative.textPrimary;
  }

  private subTextColor(): Resource {
    return VividNative.textSecondary;
  }

  build() {
    Column() {
      Row() {
        if (!this.nested) {
          Text('透视校正').fontSize(12).fontWeight(FontWeight.Bold).fontColor(this.textColor());
        }
        Blank();
        // 原生强调按钮：填充色/前景色/圆角全部由系统主题决定。
        Button() {
          Text(this.guideMode ? '完成参考线' : '绘制参考线').fontSize(10);
        }
          .height(26).padding({ left: 10, right: 10 })
          .buttonStyle(ButtonStyleMode.EMPHASIZED).controlSize(ControlSize.SMALL)
          .onClick((): void => {
            this.guideMode = !this.guideMode;
            this.editSession.setActiveTool(this.guideMode ? ToolType.UPRIGHT :
              (this.cropEmbedded ? ToolType.CROP : ToolType.ADJUST));
            AppStorage.setOrCreate('activeToolRevision', Date.now());
            // 切换工具后立刻重画叠加层：绘制参考线时显示参考线，回到裁剪时
            // 显示裁剪框，而不是等下一次触摸才刷新。
            AppStorage.setOrCreate('cropOverlayRevision', Date.now());
          });
      }.width('100%').height(32).padding({ left: 14, right: 10 });

      Row() {
        ForEach(UPRIGHT_MODES, (option: UprightModeOption) => {
          // 模式选择用原生按钮档位表达选中态（EMPHASIZED/NORMAL）。
          Button() {
            Text(option.label).fontSize(11);
          }
            .layoutWeight(1).height(28).margin({ left: 2, right: 2 })
            .buttonStyle(this.editSession.upright.mode === option.mode ?
              ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .onClick((): void => { this.applyMode(option.mode); });
        }, (option: UprightModeOption) => option.label);
      }.width('100%').padding({ left: 12, right: 12, bottom: 6 });

      Text('在画面上沿应当竖直或水平的边缘拖动画线；竖直约束垂直透视，水平约束水平透视与拉直角度。')
        .fontSize(10).fontColor(this.subTextColor()).width('100%')
        .padding({ left: 14, right: 14, bottom: 6 });

      Text('已接受参考线：竖直 ' + this.verticalCount + ' 条，水平 ' + this.horizontalCount + ' 条' +
        (this.editSession.upright.guides.length > this.verticalCount + this.horizontalCount ?
          '（' + (this.editSession.upright.guides.length - this.verticalCount - this.horizontalCount) +
          ' 条无法提供约束）' : ''))
        .fontSize(10).fontColor(this.subTextColor()).width('100%')
        .padding({ left: 14, right: 14, bottom: 4 });

      Text('垂直透视 ' + this.solvedVertical.toFixed(3) + '　水平透视 ' +
        this.solvedHorizontal.toFixed(3) + '　拉直 ' + this.solvedRotation.toFixed(1) + '°')
        .fontSize(10).fontColor(this.subTextColor()).width('100%')
        .padding({ left: 14, right: 14, bottom: 4 });

      if (this.residual > 0.02) {
        // Guides that disagree cannot all be satisfied by a two-parameter tilt.
        // Say so instead of presenting the average as if it were a clean solve.
        Text('参考线之间存在矛盾（偏差 ' + this.residual.toFixed(3) + '），已取平均；' +
          '完全消除需要单应校正。')
          // 原生告警前景色（日/夜由系统主题决定）。
          .fontSize(10).fontColor(VividNative.warning).width('100%')
          .padding({ left: 14, right: 14, bottom: 4 });
      }

      Row() {
        Button() {
          Text('移除最后一条').fontSize(10);
        }
          .layoutWeight(1).height(28).margin({ left: 2, right: 2 })
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick((): void => { this.removeLast(); });
        Button() {
          Text('清除全部').fontSize(10);
        }
          .layoutWeight(1).height(28).margin({ left: 2, right: 2 })
          .buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick((): void => { this.clearAll(); });
      }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 8 });
    }.width('100%');
  }
}
