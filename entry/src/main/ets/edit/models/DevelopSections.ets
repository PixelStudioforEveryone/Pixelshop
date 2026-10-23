/**
 * Section list and visibility rules for the desktop develop inspector.
 *
 * The list lives here rather than inline in `DesktopDevelopPanel` so the rule
 * "which sections exist, and which of them belong to a whole-frame edit" is
 * data that a test can execute instead of re-parsing a build() block.
 *
 * Whole-frame-only stages must disappear while a mask is being edited:
 *   - `detail` and `optics` write document-level stages (`session.detail`,
 *     `session.optics`), not the active mask's adjustments. Showing them in the
 *     mask panel meant dragging an "optics" slider under a mask silently changed
 *     the whole photo.
 *   - `point-color`, `black-white` and `bokeh` are likewise document stages.
 *     `point-color` no longer has a section of its own: it is embedded in the
 *     mixer and gated by this same predicate, so it still disappears while a
 *     mask is edited. `bokeh` runs on uncropped source pixels before geometry,
 *     so it cannot be scoped to one mask either.
 *
 * `upright` and `oklch` are gone from the section list. Upright now lives in the
 * crop page (its geometry fields are part of cropping), and OkLCh was retired.
 */
export interface DevelopSection {
  id: string;
  title: string;
}

export const DEVELOP_SECTIONS: DevelopSection[] = [
  { id: 'light', title: '亮' },
  { id: 'color', title: '颜色' },
  { id: 'effects', title: '效果' },
  { id: 'curve', title: '曲线' },
  { id: 'mixer', title: '混色器' },
  { id: 'grading', title: '颜色分级' },
  { id: 'detail', title: '细节' },
  { id: 'optics', title: '光学' },
  { id: 'black-white', title: '黑白' },
  { id: 'calibration', title: '校准' },
  { id: 'bokeh', title: '大光圈模拟' },
];

/**
 * Stages that only make sense for the whole frame, never for one mask.
 *
 * `point-color` stays in this list even though it no longer has a section: the
 * mixer embeds the point-colour panel and uses this predicate to hide it in mask
 * context, so there is no "section gone but control still mounted" leak.
 */
const WHOLE_FRAME_ONLY: string[] = [
  'detail', 'optics', 'point-color', 'black-white', 'bokeh',
];

/** Whether a section may be shown in the current editing scope. */
export function isDevelopSectionVisible(sectionId: string, maskContext: boolean): boolean {
  if (!maskContext) return true;
  return WHOLE_FRAME_ONLY.indexOf(sectionId) < 0;
}

/** True when the section edits a document-level stage rather than a mask. */
export function isWholeFrameSection(sectionId: string): boolean {
  return WHOLE_FRAME_ONLY.indexOf(sectionId) >= 0;
}
