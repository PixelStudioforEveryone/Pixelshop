/**
 * Upright: the reference lines the user draws plus the solve mode.
 *
 * This is NOT a render stage. The solver's output is written into the three
 * manual geometry fields the engine already has — `geometry[0]` (vertical
 * perspective), `geometry[1]` (horizontal perspective) and `geometry[2]`
 * (straighten) — so once the guides are solved there is nothing left for the
 * renderer to know about, and both the CPU and GPU geometry paths pick the result
 * up through the uniforms they already upload.
 *
 * For that reason this model stores the INPUTS (the guides and the mode) rather
 * than the solved values: re-solving is cheap and exact, and storing the inputs
 * means reopening a photo lets the user adjust or delete a guide instead of
 * being stuck with a result they can no longer inspect.
 *
 * Guides are stored in NORMALIZED source coordinates ([0,1], origin top-left)
 * with the same convention as retouch marks, so they survive a change of preview
 * resolution and can be re-drawn onto the canvas at any size.
 *
 * `UprightGuide` and `UprightMode` are imported from the engine rather than
 * redeclared. Two identically shaped but differently named interfaces are NOT
 * interchangeable in an object literal under ArkTS
 * (`arkts-no-untyped-obj-literals`), which already cost this project one failed
 * build; models importing engine types is an established pattern here
 * (Adjustment.ets and EditSession.ets both do it).
 */
import { UprightGuide, UprightMode, uprightModeFromNumber } from '../engine/UprightSolver';

/** Seed for restore. Guides are optional so a pre-Upright sidecar opens clean. */
export interface UprightValues {
  guides?: UprightGuide[];
  mode?: number;
}

/** A guide shorter than this in normalized units is a tap, not a line. */
export const UPRIGHT_MIN_GUIDE_LENGTH: number = 0.04;

@Observed
export class UprightSettings implements UprightValues {
  public guides: UprightGuide[] = [];
  public mode: number = UprightMode.FULL;

  clone(): UprightSettings {
    return UprightSettings.restore(this);
  }

  static restore(value?: UprightValues): UprightSettings {
    const result = new UprightSettings();
    if (!value) return result;
    result.mode = uprightModeFromNumber(value.mode ?? UprightMode.FULL);
    const guides = value.guides;
    if (guides && guides.length > 0) {
      const restored: UprightGuide[] = [];
      for (let i = 0; i < guides.length; i++) {
        const guide = guides[i];
        if (!guide) continue;
        if (!Number.isFinite(guide.x1) || !Number.isFinite(guide.y1) ||
          !Number.isFinite(guide.x2) || !Number.isFinite(guide.y2)) continue;
        const item: UprightGuide = {
          x1: Math.max(0, Math.min(1, guide.x1)), y1: Math.max(0, Math.min(1, guide.y1)),
          x2: Math.max(0, Math.min(1, guide.x2)), y2: Math.max(0, Math.min(1, guide.y2)),
          vertical: guide.vertical === true,
        };
        restored.push(item);
      }
      result.guides = restored;
    }
    return result;
  }

  /** True when there is nothing to solve, so the caller can skip the work. */
  hasGuides(): boolean {
    return this.guides.length > 0;
  }

  /** Drop every guide. The geometry fields are NOT touched here: clearing the
   *  guides and clearing the correction are separate decisions, and the caller
   *  re-solves so that removing the last guide restores the manual values. */
  clear(): void {
    this.guides = [];
  }

  /**
   * Whether a stroke is a usable guide.
   *
   * Exposed separately from `addGuide` so a caller can decide whether to open an
   * undo step BEFORE mutating anything. Pushing undo after the mutation would
   * snapshot the already-changed state and make the tap un-undoable.
   */
  static acceptsGuide(x1: number, y1: number, x2: number, y2: number): boolean {
    if (!Number.isFinite(x1) || !Number.isFinite(y1) ||
      !Number.isFinite(x2) || !Number.isFinite(y2)) return false;
    const dx = x2 - x1;
    const dy = y2 - y1;
    if (Math.sqrt(dx * dx + dy * dy) < UPRIGHT_MIN_GUIDE_LENGTH) return false;
    // A near-diagonal stroke is rejected rather than guessed at: a guide that is
    // 45 degrees off carries no usable constraint on either axis.
    const horizontal = Math.abs(dx);
    const vertical = Math.abs(dy);
    return horizontal > vertical * 2 || vertical > horizontal * 2;
  }

  /** Append a guide, ignoring taps and degenerate segments. Returns whether the
   *  guide was accepted, so the UI can avoid pushing an undo step for a tap. */
  addGuide(x1: number, y1: number, x2: number, y2: number): boolean {
    if (!UprightSettings.acceptsGuide(x1, y1, x2, y2)) return false;
    const dx = x2 - x1;
    const dy = y2 - y1;
    // The axis a guide is declared on is the axis it should end up parallel to,
    // so the dominant direction of the stroke decides it.
    const item: UprightGuide = {
      x1: x1, y1: y1, x2: x2, y2: y2,
      vertical: Math.abs(dy) > Math.abs(dx),
    };
    this.guides = this.guides.concat([item]);
    return true;
  }
}
