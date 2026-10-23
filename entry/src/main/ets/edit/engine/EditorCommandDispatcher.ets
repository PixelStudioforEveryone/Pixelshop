import {
  EditorCommandId,
  EditorCommandKind,
  editorCommandKind,
  parseEditorCommand,
} from './EditorShortcuts';

/**
 * Which keys the editor is allowed to turn into commands.
 *
 * Mirrors Lightcraft `shortcuts::keyboard_owned` (crates/ui-egui/src/shortcuts.rs
 * lines 303-328) and Compositor `ShortcutSettings.canvasEvent`
 * (UI/KeyboardShortcuts.swift lines 183-202): global shortcuts stand down while a
 * content widget owns the keyboard. Neither project lets a tool key fire inside a
 * text field, and neither lets one fire while a dialog is open.
 */
export interface EditorKeyboardContext {
  /** A text field / editor owns the keyboard. */
  inputFocused?: boolean;
  /** A dialog, menu, popup or sheet is open. */
  modalOpen?: boolean;
  /** The editing surface holds focus. */
  canvasFocused?: boolean;
  /** The editor workspace is the wide PC layout, not the phone layout. */
  desktopLayout?: boolean;
}

export enum EditorDispatchResult {
  /** No known key: let the framework handle it. */
  Ignored = 0,
  /** A known key in a context where it must be left alone. */
  Suppressed = 1,
  /** The command ran (or, for a hold command, was started or released). */
  Handled = 2,
}

/**
 * True when a global editor shortcut may run at all. The phone layout is excluded
 * so an attached keyboard on a handset cannot start PC-only commands, and so the
 * shortcuts never fight the touch gestures.
 */
export function editorCanDispatchKeys(context: EditorKeyboardContext): boolean {
  const inputFocused: boolean = context.inputFocused === true;
  const modalOpen: boolean = context.modalOpen === true;
  const canvasFocused: boolean = context.canvasFocused === true;
  const desktopLayout: boolean = context.desktopLayout === true;
  return desktopLayout && canvasFocused && !inputFocused && !modalOpen;
}

/**
 * Holds the one-shot and hold state for a single editing surface.
 *
 * Two guarantees, both of which the two open-source projects make and the previous
 * version of this editor did not have:
 *  - an auto-repeated key-down runs a one-shot command once, not once per repeat
 *    (Lightcraft acts on `pressed: true` events; Compositor's hold-to-hand tool is
 *    state based, so holding it does not stack);
 *  - a hold command is released when the key comes up, when focus is lost, when a
 *    dialog opens, when the photo changes and when the dispatcher is reset.
 *
 * State is kept in parallel arrays rather than a Map, because ArkTS does not give
 * every target a Map iterator.
 */
export class EditorCommandDispatcher {
  private readonly runCommand: (id: EditorCommandId) => void;
  private readonly endHold: (id: EditorCommandId) => void;
  private armedKeys: number[] = [];
  private heldKeys: number[] = [];
  private heldCommands: EditorCommandId[] = [];

  /**
   * @param runCommand  runs the business action for a command id.
   * @param endHold     restores the view for a hold command; receives the id that
   *                    is being released.
   */
  constructor(runCommand: (id: EditorCommandId) => void, endHold: (id: EditorCommandId) => void) {
    this.runCommand = runCommand;
    this.endHold = endHold;
  }

  /**
   * @param repeat  true for an auto-repeat key-down. A one-shot command is armed
   *                on the first press and refuses every repeat, so Ctrl+Z held
   *                down undoes one step instead of emptying the history.
   */
  dispatchKeyDown(
    keyCode: number,
    ctrl: boolean,
    shift: boolean,
    repeat: boolean,
    context: EditorKeyboardContext,
  ): EditorDispatchResult {
    const command: EditorCommandId = parseEditorCommand(keyCode, ctrl, shift);
    if (command === EditorCommandId.None) {
      return EditorDispatchResult.Ignored;
    }
    if (!editorCanDispatchKeys(context)) {
      // Nothing is armed here on purpose: a key pressed while a dialog is open or
      // while a text field has focus leaves no state behind, so the next real
      // press on the canvas still works.
      this.releaseAll();
      return EditorDispatchResult.Suppressed;
    }
    if (editorCommandKind(command) === EditorCommandKind.Hold) {
      if (this.indexOfKey(this.heldKeys, keyCode) < 0) {
        this.heldKeys.push(keyCode);
        this.heldCommands.push(command);
        this.runCommand(command);
      }
      return EditorDispatchResult.Handled;
    }
    if (this.indexOfKey(this.armedKeys, keyCode) >= 0) {
      return EditorDispatchResult.Handled;
    }
    if (this.indexOfKey(this.armedKeys, keyCode) < 0) {
      this.armedKeys.push(keyCode);
    }
    this.runCommand(command);
    return EditorDispatchResult.Handled;
  }

  /**
   * Marks the physical key as released. A one-shot command becomes armable again;
   * a hold command is ended once, whether or not the release arrives in a context
   * that would now refuse new presses.
   */
  dispatchKeyUp(keyCode: number, ctrl: boolean, shift: boolean): EditorDispatchResult {
    // Release the physical key independently of the modifiers that remain down.
    // Releasing Ctrl before Z must not leave Z armed until the next focus change.
    const armed: number = this.indexOfKey(this.armedKeys, keyCode);
    if (armed >= 0) {
      this.armedKeys.splice(armed, 1);
    }
    const held: number = this.indexOfKey(this.heldKeys, keyCode);
    if (held >= 0) {
      this.heldKeys.splice(held, 1);
      const released: EditorCommandId = this.heldCommands[held];
      this.heldCommands.splice(held, 1);
      this.endHold(released);
    }
    return armed >= 0 || held >= 0 ? EditorDispatchResult.Handled : EditorDispatchResult.Ignored;
  }

  /** True while a hold command is active on this key. */
  isHolding(keyCode: number): boolean {
    return this.indexOfKey(this.heldKeys, keyCode) >= 0;
  }

  /** True while a one-shot key is held, so its repeats are refused. */
  isArmed(keyCode: number): boolean {
    return this.indexOfKey(this.armedKeys, keyCode) >= 0;
  }

  /**
   * Releases every hold command and clears the one-shot arming. Called when focus
   * is lost, when a dialog opens, when the photo changes and on dispose, so the
   * original is never left on screen.
   */
  releaseAll(): void {
    while (this.heldCommands.length > 0) {
      const released: EditorCommandId = this.heldCommands.pop() ?? EditorCommandId.None;
      this.heldKeys.pop();
      if (released !== EditorCommandId.None) {
        this.endHold(released);
      }
    }
    this.heldKeys = [];
    this.heldCommands = [];
    this.armedKeys = [];
  }

  private indexOfKey(keys: number[], keyCode: number): number {
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] === keyCode) {
        return i;
      }
    }
    return -1;
  }
}
