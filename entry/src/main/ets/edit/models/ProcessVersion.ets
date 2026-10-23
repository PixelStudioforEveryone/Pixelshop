/**
 * Process Version — pins a photo to the generation of the rendering algorithm
 * that produced its current look.
 *
 * Why this exists
 * ---------------
 * Every render setting in this app is stored as a *parameter* and re-evaluated
 * by the pipeline on every open. That is only safe while the mapping from
 * parameters to pixels never changes. When it does change — because an
 * algorithm was improved — every previously edited photo silently re-renders
 * with the new maths and the user's saved look drifts. A process version turns
 * that silent drift into an explicit, per-photo choice:
 *
 *   LEGACY  (1) replays the algorithm generation that shipped before the
 *               change, so an untouched old photo still renders exactly as it
 *               did when it was edited.
 *   CURRENT (2) uses the present algorithm generation.
 *
 * New edits and Reset get CURRENT. A sidecar written before process versions
 * existed carries no `processVersion` field, so it reads back as LEGACY — the
 * conservative direction, which is the same rule lightcraft uses
 * (`ProcessVersion::legacy()` as the serde default) and the same rule Camera
 * Raw uses when it reads an old `crs:ProcessVersion`.
 *
 * Scope of this table
 * -------------------
 * `ProcessBehaviors` is the SINGLE source of truth for every behavioural
 * difference between generations. No other file may branch on the version
 * number. That invariant is what makes the mechanism auditable: to know what a
 * version does, read this file. It is enforced by a check in
 * `tools/check_process_version.cjs`, which greps the tree for version
 * comparisons outside this module.
 *
 * Only behaviours that actually changed are listed. Bug fixes are deliberately
 * NOT versioned (see `LEGACY_PINNED_BEHAVIORS`): preserving a defect nobody
 * wants back would be worse than the drift it avoids. This file therefore
 * documents one gated behaviour today rather than inventing a longer list.
 */

/** Algorithm generation as it shipped before frame-relative denoise radii. */
export const PROCESS_VERSION_LEGACY: number = 1;
/** Algorithm generation currently produced by fresh edits. */
export const PROCESS_VERSION_CURRENT: number = 2;

/**
 * Resolved behaviour of one algorithm generation.
 *
 * Field semantics use "0 means no override" so a generation can opt out of a
 * pin without the caller needing to know which field is set.
 */
export interface ProcessBehaviors {
  /**
   * Fixed spatial radius, in pixels, for the noise-reduction bilateral kernel.
   *
   * LEGACY: 2 — the radius was a constant, so the kernel covered a *pixel*
   * sized neighbourhood. On an export much larger than the preview it was
   * tuned on, the same setting removes a smaller share of the scene than the
   * preview showed.
   *
   * CURRENT: 0, meaning "derive from the frame long edge" (see
   * `denoiseSpatialRadius` in NoiseReduction.ets). The spatial footprint is
   * then constant in scene units, which is the condition for the filter to
   * commute with the preview/export resolution change.
   *
   * This is the only behaviour gated today; it affects frames whose long edge
   * exceeds `DENOISE_REFERENCE_LONG_EDGE` (2048), i.e. large exports. Frames at
   * or below that edge resolve to radius 2 under BOTH generations, so preview
   * and interactive renders are unaffected by the process version.
   */
  denoiseFixedRadius: number;
}

/** Behaviours pinned by `PROCESS_VERSION_LEGACY`, for user-facing display. */
export interface ProcessVersionNote {
  title: string;
  detail: string;
}

/** True when a value is a generation this build knows how to replay. */
export function isKnownProcessVersion(candidate: number): boolean {
  if (typeof candidate !== 'number') return false;
  if (!Number.isInteger(candidate)) return false;
  return candidate >= PROCESS_VERSION_LEGACY && candidate <= PROCESS_VERSION_CURRENT;
}

/**
 * Coerce any incoming value to a replayable generation.
 *
 * Anything unknown, missing, fractional or out of range resolves to LEGACY.
 * This matters because the sidecar is user-editable text and may also be
 * written by an older or newer build: guessing CURRENT for a value this build
 * does not understand would re-render the photo with maths the user never saw.
 * A fractional value is treated as corrupt rather than rounded, because
 * rounding 3.4 down to a valid generation would silently accept a value this
 * build does not actually understand.
 */
export function normalizeProcessVersion(candidate: number): number {
  if (!isKnownProcessVersion(candidate)) return PROCESS_VERSION_LEGACY;
  return candidate;
}

/** Resolve the behaviour table for a generation. */
export function processBehaviors(version: number): ProcessBehaviors {
  const resolved: number = normalizeProcessVersion(version);
  if (resolved === PROCESS_VERSION_LEGACY) {
    const legacy: ProcessBehaviors = { denoiseFixedRadius: 2 };
    return legacy;
  }
  const current: ProcessBehaviors = { denoiseFixedRadius: 0 };
  return current;
}

/** Short label for the adjustment panel. */
export function processVersionLabel(version: number): string {
  return normalizeProcessVersion(version) === PROCESS_VERSION_LEGACY ? '旧版（1）' : '当前（2）';
}

/** One-line explanation shown next to the version row. */
export function processVersionSummary(version: number): string {
  if (normalizeProcessVersion(version) === PROCESS_VERSION_LEGACY) {
    return '按旧算法渲染，旧照片外观保持不变。';
  }
  return '按当前算法渲染。';
}

/** True when the photo is already on the newest generation. */
export function isLatestProcessVersion(version: number): boolean {
  return normalizeProcessVersion(version) === PROCESS_VERSION_CURRENT;
}

/** What LEGACY holds fixed, so the UI can state it rather than claim "无差别". */
export function legacyPinnedBehaviors(): ProcessVersionNote[] {
  const notes: ProcessVersionNote[] = [];
  notes.push({
    title: '降噪空间半径',
    detail: '固定 2 像素；当前版本按画面长边在 2–5 像素之间取值。仅长边超过 2048 的导出会看到差别。',
  });
  return notes;
}

/**
 * Changes that were deliberately NOT versioned because they were defect fixes,
 * recorded here so the omission is auditable rather than forgotten.
 */
export function unversionedDefectFixes(): ProcessVersionNote[] {
  const notes: ProcessVersionNote[] = [];
  notes.push({
    title: '镜像与 90° 旋转的组合顺序',
    detail: '修正了 {旋转90°, 旋转270°} × 单次翻转的采样表顺序；旧结果本身是错的，不保留。',
  });
  notes.push({
    title: '径向蒙版的坐标系',
    detail: '径向蒙版此前在显示坐标系中求解，裁切后位置偏移；旧结果本身是错的，不保留。',
  });
  notes.push({
    title: '降噪强度为 0 时的直通',
    detail: '强度为 0 时此前仍会走一遍滤波；现在为可证明的直通，像素完全不变。',
  });
  return notes;
}
