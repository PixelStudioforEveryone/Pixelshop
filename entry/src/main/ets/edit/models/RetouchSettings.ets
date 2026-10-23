/**
 * Kinds a mark may have.
 *
 * `heal` blends a sampled patch and matches the boundary colour; `clone` copies
 * the sampled patch verbatim, which is a genuinely different result rather than a
 * strength setting; `fill` replaces the marked region with a content-aware
 * estimate built from the rest of the frame; `redeye` gates on red.
 */
export const RETOUCH_HEAL: string = 'heal';
export const RETOUCH_CLONE: string = 'clone';
export const RETOUCH_FILL: string = 'fill';
export const RETOUCH_REDEYE: string = 'redeye';

function isRetouchKind(kind: string): boolean {
  return kind === RETOUCH_HEAL || kind === RETOUCH_CLONE ||
    kind === RETOUCH_FILL || kind === RETOUCH_REDEYE;
}

export interface RetouchMark {
  id: string;
  kind: string;
  x: number;
  y: number;
  radius: number;
  feather: number;
  amount: number;
  sourceX: number;
  sourceY: number;
}
export function cloneRetouchMarks(marks?: RetouchMark[]): RetouchMark[] {
  return (marks ?? []).filter((m: RetouchMark): boolean =>
    !!m && typeof m.id === 'string' && isRetouchKind(m.kind) && Number.isFinite(m.x) && Number.isFinite(m.y)
      && Number.isFinite(m.radius) && Number.isFinite(m.feather) && Number.isFinite(m.amount)
      && Number.isFinite(m.sourceX) && Number.isFinite(m.sourceY))
    .slice(0, 512).map((m: RetouchMark): RetouchMark => ({
      id: m.id, kind: m.kind, x: Math.max(0, Math.min(1, m.x)), y: Math.max(0, Math.min(1, m.y)),
      radius: Math.max(0.001, Math.min(0.2, m.radius)), feather: Math.max(0, Math.min(1, m.feather)),
      amount: Math.max(0, Math.min(1, m.amount)), sourceX: Math.max(0, Math.min(1, m.sourceX)),
      sourceY: Math.max(0, Math.min(1, m.sourceY)),
    }));
}
