import { EditSession } from '../edit/models/EditSession';
import { ImageProcessor } from '../edit/engine/ImageProcessor';
import {
  RetouchMark, RETOUCH_CLONE, RETOUCH_FILL, RETOUCH_HEAL, RETOUCH_REDEYE,
} from '../edit/models/RetouchSettings';
import { ToolType } from '../edit/models/ToolType';
import { DesktopRawSlider } from './DesktopRawSlider';
import { VividNative } from './VividNativeTheme';

/** 画笔能画的四种类型；红眼是同一次涂抹的变体，因此并入本面板，不再单列工具。 */
interface RetouchKindOption {
  kind: string;
  label: string;
}

const RETOUCH_KINDS: RetouchKindOption[] = [
  { kind: RETOUCH_HEAL, label: '修复' },
  { kind: RETOUCH_CLONE, label: '仿制' },
  { kind: RETOUCH_FILL, label: '填充' },
  { kind: RETOUCH_REDEYE, label: '红眼' },
];

@Component
export struct RetouchPanel {
  @Consume('editSession') editSession: EditSession;
  /** 平板还保留独立的「红眼」模式入口，手机端已并入类型档（默认 false）。 */
  @Prop redEye: boolean = false;
  @StorageProp('vividNightMode') private night: boolean = false;
  @StorageProp('retouchRevision') private revision: number = 0;

  /** 选中红眼时滑杆换成瞳孔大小 / 变暗。 */
  private isRedEye(): boolean {
    return this.redEye || this.editSession.retouchKind === RETOUCH_REDEYE;
  }

  /** The kind whose marks this instance lists. */
  private activeKind(): string {
    return this.editSession.retouchKind;
  }

  private kindLabel(kind: string): string {
    if (kind === RETOUCH_REDEYE) return '红眼修正';
    if (kind === RETOUCH_CLONE) return '仿制';
    if (kind === RETOUCH_FILL) return '填充';
    return '修复';
  }

  /** Fill reads no second location and has no strength dial worth showing. */
  private needsSource(): boolean {
    const kind = this.activeKind();
    return kind === RETOUCH_HEAL || kind === RETOUCH_CLONE;
  }

  private hint(): string {
    if (this.isRedEye()) return '在红色瞳孔上点击。瞳孔大小和变暗控制下一次修正。';
    const kind = this.activeKind();
    if (kind === RETOUCH_CLONE) {
      return '先选取源区域，再在目标区域涂抹：仿制会原样复制源像素，不做边界融合。';
    }
    if (kind === RETOUCH_FILL) {
      return '在要去掉的物体上涂抹，松手后用画面其余部分做内容感知填充。填充不使用源区域，也不使用不透明度。';
    }
    return '先选取干净的源区域，再在待修复区域点击或涂抹。源坐标保存到原图。';
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        ForEach(RETOUCH_KINDS, (option: RetouchKindOption) => {
          // 修复类型选择：原生按钮档位表达选中态。
          Button(option.label).fontSize(12).height(30).layoutWeight(1)
            .buttonStyle(this.editSession.retouchKind === option.kind ?
              ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .onClick(() => {
              // 先切画笔：setActiveTool 负责「红眼 ⇄ 修复」的双向同步，
              // 之后再把类型钉到用户点的那一档。
              this.editSession.setActiveTool(option.kind === RETOUCH_REDEYE ? ToolType.RED_EYE : ToolType.HEAL);
              this.editSession.retouchKind = option.kind;
              // Clear a pending source pick that only made sense for the previous
              // kind, so choosing 填充 cannot leave the canvas in "pick a source"
              // mode where a tap would silently do nothing visible.
              if (!this.needsSource()) this.editSession.pickingRetouchSource = false;
              AppStorage.setOrCreate('retouchRevision', Date.now());
            });
        }, (option: RetouchKindOption) => option.kind);
      }.width('100%');
      Text(this.hint()).fontSize(12).fontColor(this.textColor()).width('100%');
      if (this.needsSource()) {
        Button(this.editSession.pickingRetouchSource ? '点击照片选择源区域' : '选取修复源').fontSize(12).height(32)
          .buttonStyle(this.editSession.pickingRetouchSource ?
            ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .onClick(() => { this.editSession.pickingRetouchSource = !this.editSession.pickingRetouchSource; });
      }
      DesktopRawSlider({ label: this.isRedEye() ? '瞳孔大小' : '大小', controlId: 'retouch-size', lower: 0.003, upper: 0.15,
        currentValue: this.editSession.retouchSize, onUpdate: (v: number) => { this.editSession.retouchSize = v; } });
      if (!this.isRedEye()) {
        DesktopRawSlider({ label: '羽化', controlId: 'retouch-feather', lower: 0, upper: 1,
          currentValue: this.editSession.retouchFeather, onUpdate: (v: number) => { this.editSession.retouchFeather = v; } });
      }
      // Fill ignores opacity (it replaces the region outright), so showing the
      // control there would be a slider that changes nothing.
      if (this.isRedEye() || this.activeKind() !== RETOUCH_FILL) {
        DesktopRawSlider({ label: this.isRedEye() ? '变暗' : '不透明度', controlId: 'retouch-amount', lower: 0, upper: 1,
          currentValue: this.editSession.retouchAmount, onUpdate: (v: number) => { this.editSession.retouchAmount = v; } });
      }
      ForEach(this.editSession.retouchMarks.filter((mark: RetouchMark): boolean =>
        mark.kind === this.activeKind()).slice().reverse(), (mark: RetouchMark) => {
        Row() {
          Text(this.kindLabel(mark.kind) + ' ' + (this.editSession.retouchMarks.indexOf(mark) + 1))
            .fontSize(12).fontColor(this.textColor()).layoutWeight(1);
          Button('删除').fontSize(11).height(26)
            .buttonStyle(ButtonStyleMode.TEXTUAL).role(ButtonRole.ERROR).controlSize(ControlSize.SMALL)
            .onClick(() => {
              this.editSession.pushUndo();
              this.editSession.retouchMarks = this.editSession.retouchMarks.filter((m: RetouchMark): boolean => m.id !== mark.id);
              this.editSession.bumpProcessing(); AppStorage.setOrCreate('retouchRevision', Date.now());
              ImageProcessor.process(this.editSession);
            });
        }.width('100%').height(30);
      }, (mark: RetouchMark) => mark.id + ':' + this.revision);
    }.id('retouch-panel-' + this.revision).width('100%').padding(20).alignItems(HorizontalAlign.Start);
  }
  private textColor(): Resource { return VividNative.textPrimary; }
}
