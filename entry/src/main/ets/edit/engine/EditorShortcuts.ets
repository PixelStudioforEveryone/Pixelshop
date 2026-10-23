/**
 * Editor keyboard vocabulary shared by the canvas, the toolbar and the buttons.
 *
 * Why this file has no imports: the dispatcher is unit-tested off-device by
 * transpiling this source with the TypeScript compiler, so it must not pull in
 * ArkUI kits or the edit engine. The key numbers are therefore copied verbatim
 * from the SDK declaration rather than imported:
 * <sdk>/ets/api/@ohos.multimodalInput.keyCode.d.ts (enum KeyCode).
 * They are checked by tools/check_editor_shortcuts.cjs against that list.
 */
export class EditorKeyCodes {
  static readonly KEYCODE_0: number = 2000;
  static readonly KEYCODE_B: number = 2018;
  static readonly KEYCODE_C: number = 2019;
  static readonly KEYCODE_U: number = 2037;
  static readonly KEYCODE_V: number = 2038;
  static readonly KEYCODE_Z: number = 2042;
  static readonly KEYCODE_SPACE: number = 2050;
  static readonly KEYCODE_MINUS: number = 2057;
  static readonly KEYCODE_EQUALS: number = 2058;
  static readonly KEYCODE_BACKSLASH: number = 2061;
  static readonly KEYCODE_PLUS: number = 2066;
  static readonly KEYCODE_ESCAPE: number = 2070;
  static readonly KEYCODE_NUMPAD_0: number = 2103;
  static readonly KEYCODE_NUMPAD_SUBTRACT: number = 2115;
  static readonly KEYCODE_NUMPAD_ADD: number = 2116;
}

/** Every business action a key (or a button) can start. */
export enum EditorCommandId {
  None = 0,
  Undo,
  Redo,
  ZoomIn,
  ZoomOut,
  ZoomFit,
  /** Hold-to-compare: the original is shown while the key is down. */
  HoldOriginal,
  ToolAdjust,
  ToolCrop,
  ToolBrushMask,
  ToolUpright,
  /** Esc: leave the active tool, or fall back to the fit view. */
  LeaveTool,
}

/** How a command reacts to a key being held down. */
export enum EditorCommandKind {
  /** One action per press. Auto-repeat must not run it again. */
  OneShot = 0,
  /** Active between key-down and key-up; must be released safely. */
  Hold = 1,
}

const HOLD_COMMANDS: EditorCommandId[] = [EditorCommandId.HoldOriginal];

export function editorCommandKind(id: EditorCommandId): EditorCommandKind {
  for (let i = 0; i < HOLD_COMMANDS.length; i++) {
    if (HOLD_COMMANDS[i] === id) {
      return EditorCommandKind.Hold;
    }
  }
  return EditorCommandKind.OneShot;
}

/** Tool ids match ToolType's string values; the host maps them back. */
export const EDITOR_TOOL_ADJUST: string = 'adjust';
export const EDITOR_TOOL_CROP: string = 'crop';
export const EDITOR_TOOL_BRUSH_MASK: string = 'brush_mask';
export const EDITOR_TOOL_UPRIGHT: string = 'upright';

export function editorToolIdOf(id: EditorCommandId): string {
  switch (id) {
    case EditorCommandId.ToolAdjust:
      return EDITOR_TOOL_ADJUST;
    case EditorCommandId.ToolCrop:
      return EDITOR_TOOL_CROP;
    case EditorCommandId.ToolBrushMask:
      return EDITOR_TOOL_BRUSH_MASK;
    case EditorCommandId.ToolUpright:
      return EDITOR_TOOL_UPRIGHT;
    default:
      return '';
  }
}

/**
 * The command for a physical key plus its modifiers, or None when the key is
 * not ours. Nothing here claims Ctrl+A/C/V/X/F/S: those stay with the text
 * editing and system layers, which is why parse returns None for them.
 *
 * Zoom keys follow Lightcraft (`cmd:view.zoomIn` / `view.zoomOut` / `view.zoomFit`,
 * crates/ui-egui/src/menus.rs lines 81/87/88) and Compositor (KeyboardShortcuts.swift
 * "Zoom In" = Cmd+=, "Zoom Out" = Cmd+-, "Fit Canvas" = Cmd+0). Ctrl is HarmonyOS'
 * Cmd equivalent. Plain `+`/`=` and `-` as well as the numpad equivalents are all
 * accepted, because a single keyCode is not reported by every keyboard.
 */
export function parseEditorCommand(keyCode: number, ctrl: boolean, shift: boolean): EditorCommandId {
  if (ctrl) {
    if (keyCode === EditorKeyCodes.KEYCODE_Z) {
      return shift ? EditorCommandId.Redo : EditorCommandId.Undo;
    }
    // '+' is normally produced by Shift+'=' on a physical keyboard.
    if (keyCode === EditorKeyCodes.KEYCODE_PLUS || keyCode === EditorKeyCodes.KEYCODE_EQUALS ||
      keyCode === EditorKeyCodes.KEYCODE_NUMPAD_ADD) {
      return EditorCommandId.ZoomIn;
    }
    if (!shift) {
      if (keyCode === EditorKeyCodes.KEYCODE_MINUS || keyCode === EditorKeyCodes.KEYCODE_NUMPAD_SUBTRACT) {
        return EditorCommandId.ZoomOut;
      }
      if (keyCode === EditorKeyCodes.KEYCODE_0 || keyCode === EditorKeyCodes.KEYCODE_NUMPAD_0) {
        return EditorCommandId.ZoomFit;
      }
    }
    return EditorCommandId.None;
  }
  if (shift) {
    return EditorCommandId.None;
  }
  switch (keyCode) {
    case EditorKeyCodes.KEYCODE_BACKSLASH:
      // Lightcraft KEY-SHOWORIGINAL (`view.showOriginal`, menus.rs line 80).
      return EditorCommandId.HoldOriginal;
    case EditorKeyCodes.KEYCODE_V:
      return EditorCommandId.ToolAdjust;
    case EditorKeyCodes.KEYCODE_C:
      // Compositor "Crop tool" (c) / Lightcraft `panel.crop` (C).
      return EditorCommandId.ToolCrop;
    case EditorKeyCodes.KEYCODE_B:
      // Compositor "Brush tool" (b) / Lightcraft `tool.brush` (B).
      return EditorCommandId.ToolBrushMask;
    case EditorKeyCodes.KEYCODE_U:
      return EditorCommandId.ToolUpright;
    case EditorKeyCodes.KEYCODE_ESCAPE:
      // Lightcraft KEY-ESC / Compositor "Cancel current canvas operation" (Esc).
      return EditorCommandId.LeaveTool;
    default:
      return EditorCommandId.None;
  }
}

/** Short human-readable label, for logs and for the shortcut list. */
export function describeEditorCommand(id: EditorCommandId): string {
  switch (id) {
    case EditorCommandId.Undo:
      return 'Ctrl+Z 撤销';
    case EditorCommandId.Redo:
      return 'Ctrl+Shift+Z 恢复';
    case EditorCommandId.ZoomIn:
      return 'Ctrl+= 放大';
    case EditorCommandId.ZoomOut:
      return 'Ctrl+- 缩小';
    case EditorCommandId.ZoomFit:
      return 'Ctrl+0 适应窗口';
    case EditorCommandId.HoldOriginal:
      return '按住 \\ 查看原图';
    case EditorCommandId.ToolAdjust:
      return 'V 移动工具';
    case EditorCommandId.ToolCrop:
      return 'C 裁剪工具';
    case EditorCommandId.ToolBrushMask:
      return 'B 蒙版工具';
    case EditorCommandId.ToolUpright:
      return 'U 校正工具';
    case EditorCommandId.LeaveTool:
      return 'Esc 退出当前工具';
    default:
      return '';
  }
}

/** The whole shortcut list, in the order it should be documented. */
export function editorShortcutList(): EditorCommandId[] {
  const list: EditorCommandId[] = [
    EditorCommandId.Undo,
    EditorCommandId.Redo,
    EditorCommandId.ZoomIn,
    EditorCommandId.ZoomOut,
    EditorCommandId.ZoomFit,
    EditorCommandId.HoldOriginal,
    EditorCommandId.ToolAdjust,
    EditorCommandId.ToolCrop,
    EditorCommandId.ToolBrushMask,
    EditorCommandId.ToolUpright,
    EditorCommandId.LeaveTool,
  ];
  return list;
}
