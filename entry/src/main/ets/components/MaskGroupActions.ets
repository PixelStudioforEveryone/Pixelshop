import { EditSession } from '../edit/models/EditSession';
import { MaskLayer, MaskComponentType, MaskBlendMode } from '../edit/models/Mask';
import { VividNative } from './VividNativeTheme';

/** A stable, parameterless @Builder binding for each parent's menu. */
@Component
export struct MaskGroupActions {
  @Consume('editSession') editSession: EditSession;
  @Prop groupId: string = '';
  @StorageProp('vividNightMode') private night: boolean = false;
  onRename: (group: MaskLayer) => void = () => {};
  onChange: () => void = () => {};

  build() {
    Button('⋯').fontSize(18).width(24).height(28).padding(0)
      .fontColor(VividNative.textPrimary)
      .buttonStyle(ButtonStyleMode.TEXTUAL).controlSize(ControlSize.SMALL)
      .focusable(true).focusBox(VividNative.focusBox())
      .id('raw-mask-menu-' + this.groupId)
      .bindMenu(this.ActionsMenu, { placement: Placement.BottomRight });
  }

  @Builder
  private ActionsMenu() {
    Menu() {
      ForEach(this.targetGroups(), (group: MaskLayer) => {
        MenuItem({ content: '重命名' }).onClick(() => { this.onRename(group); });
        MenuItem({ content: '复制蒙版' }).id('raw-mask-copy')
          .onClick(() => { this.editSession.duplicateMaskLayer(group.id); this.onChange(); });
        MenuItem({ content: '复制与反向' }).id('raw-mask-copy-invert')
          .onClick(() => { this.editSession.duplicateMaskLayer(group.id, true); this.onChange(); });
        MenuItem({ content: group.inverted ? '取消反向蒙版' : '反向蒙版' }).id('raw-mask-invert')
          .onClick(() => { this.editSession.pushUndo(); group.inverted = !group.inverted; this.commit(); });
        MenuItem({ content: group.visible ? '隐藏蒙版' : '显示蒙版' })
          .onClick(() => { this.editSession.pushUndo(); group.visible = !group.visible; this.commit(); });
        MenuItem({ content: '相交选区' }).bindMenu(this.IntersectMenu);
        MenuItem({ content: '删除蒙版' }).id('raw-mask-delete')
          .onClick(() => { this.editSession.deleteMaskLayer(group.id); this.onChange(); });
      }, (group: MaskLayer) => group.id);
    };
  }

  @Builder
  private IntersectMenu() {
    Menu() {
      MenuItem({ content: '画笔' }).onClick(() => { this.intersect(MaskComponentType.BRUSH); });
      MenuItem({ content: '线性渐变' }).onClick(() => { this.intersect(MaskComponentType.LINEAR_GRADIENT); });
      MenuItem({ content: '径向渐变' }).onClick(() => { this.intersect(MaskComponentType.RADIAL_GRADIENT); });
    };
  }

  private targetGroups(): MaskLayer[] {
    return (this.editSession.activeLayer?.maskLayers ?? []).filter((group: MaskLayer): boolean => group.id === this.groupId);
  }
  private intersect(type: MaskComponentType): void {
    if (this.targetGroups().length === 0) return;
    this.editSession.selectMaskLayer(this.groupId);
    this.editSession.addMaskComponent(type, MaskBlendMode.INTERSECT);
    this.onChange();
  }
  private commit(): void {
    this.editSession.invalidateLayerMaskCache(this.editSession.activeLayer?.id ?? '');
    this.editSession.bumpProcessing();
    this.onChange();
  }
}
