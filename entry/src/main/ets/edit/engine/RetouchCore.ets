import { RetouchMark, RETOUCH_CLONE, RETOUCH_FILL, RETOUCH_HEAL, RETOUCH_REDEYE } from '../models/RetouchSettings';
import {
  CloneMark, cloneStamp, contentAwareFill, contentFillDefaults,
} from './ContentFillCore';

function retouchSmooth(first: number, last: number, n: number): number {
  const t = Math.max(0, Math.min(1, (n - first) / Math.max(0.00001, last - first)));
  return t * t * (3 - 2 * t);
}
function retouchLinear(n: number): number {
  n /= 255; return n <= 0.04045 ? n / 12.92 : Math.pow((n + 0.055) / 1.055, 2.4);
}
function retouchEncoded(n: number): number {
  n = Math.max(0, Math.min(1, n));
  return 255 * (n <= 0.0031308 ? n * 12.92 : 1.055 * Math.pow(n, 1 / 2.4) - 0.055);
}

/** Geometry of the buffer a retouch pass runs on.
 *
 * A whole-frame render maps source-normalized coordinates with the buffer size
 * alone. A zoom tile (ImageProcessor.regionSnapshot) instead renders a
 * downscaled window of the full-resolution source and passes the six-element
 * viewport [originX, originY, fullPixelsPerBufferPixelX, fullPixelsPerBufferPixelY,
 * fullWidth, fullHeight] — the same layout WorkerCore uses for its spatial
 * effects. Retouch marks stay in source-normalized coordinates, so they must be
 * converted through the FULL-resolution frame and then divided by the pixel
 * step; treating the step as a normalized span made every mark in a detail tile
 * land at a fraction of its real position. */
export interface RetouchSpace {
  originX: number;
  originY: number;
  stepX: number;
  stepY: number;
  fullWidth: number;
  fullHeight: number;
}

export function retouchSpace(w: number, h: number, viewport: number[] = []): RetouchSpace {
  if (viewport.length !== 6) {
    return { originX: 0, originY: 0, stepX: 1, stepY: 1, fullWidth: w, fullHeight: h };
  }
  return {
    originX: viewport[0], originY: viewport[1],
    stepX: Math.max(1e-6, viewport[2]), stepY: Math.max(1e-6, viewport[3]),
    fullWidth: Math.max(1, viewport[4]), fullHeight: Math.max(1, viewport[5]),
  };
}

/** Linear-light red gate/darkening and boundary-colour healing follow
 * lightcraft pipeline/redeye.rs and spots.rs. The source stays immutable.
 * Coordinates are source-normalized, so crop/rotate never move edits. */
export function retouchPixels(source: Uint8ClampedArray, w: number, h: number,
  marks: RetouchMark[], viewport: number[] = []): Uint8ClampedArray {
  const output = new Uint8ClampedArray(source);
  const space = retouchSpace(w, h, viewport);
  const longEdge = Math.max(space.fullWidth, space.fullHeight);
  // The mark radius is a fraction of the source long edge; the tile scale is
  // uniform (RegionPixels samples both axes with one factor), so a single
  // averaged step keeps the brush round on the buffer.
  const step = Math.max(1e-6, (space.stepX + space.stepY) / 2);
  for (const mark of marks) {
    const cx = (mark.x * space.fullWidth - space.originX) / space.stepX;
    const cy = (mark.y * space.fullHeight - space.originY) / space.stepY;
    const r = Math.max(0.5, mark.radius * longEdge / step);
    const sx = (mark.sourceX * space.fullWidth - space.originX) / space.stepX;
    const sy = (mark.sourceY * space.fullHeight - space.originY) / space.stepY;
    const correction: number[] = [0, 0, 0];
    // A clone mark copies the sampled patch VERBATIM, so it is routed through the
    // verified clone stamp rather than reimplemented here. Only the coordinate
    // frame differs: the mark is stored against the full source frame, while the
    // stamp addresses the buffer it is handed, so both the centre and the radius
    // are converted through the same step/origin the heal path uses.
    if (mark.kind === RETOUCH_CLONE) {
      const cloneMark: CloneMark = {
        centreX: cx / w, centreY: cy / h,
        radius: r / Math.max(w, h),
        feather: mark.feather, opacity: mark.amount,
        sourceX: sx / w, sourceY: sy / h,
        // Each mark carries its own already-offset source (the canvas computes it),
        // so no mark should inherit the previous one's anchor.
        aligned: false,
      };
      const stamped = cloneStamp(output, w, h, [cloneMark]);
      output.set(stamped.subarray(0, output.length));
      continue;
    }
    // Fill marks are collected and handled once after this loop; see below.
    if (mark.kind === RETOUCH_FILL) continue;
    if (mark.kind === RETOUCH_HEAL) {
      let count = 0;
      for (let i = 0; i < 24; i++) {
        const a = i * Math.PI * 2 / 24;
        const dx = Math.cos(a) * r * 1.1, dy = Math.sin(a) * r * 1.1;
        const tx = Math.round(cx + dx), ty = Math.round(cy + dy);
        const px = Math.round(sx + dx), py = Math.round(sy + dy);
        if (tx < 0 || ty < 0 || tx >= w || ty >= h || px < 0 || py < 0 || px >= w || py >= h) continue;
        for (let channel = 0; channel < 3; channel++) correction[channel] +=
          retouchLinear(source[(ty * w + tx) * 4 + channel]) - retouchLinear(source[(py * w + px) * 4 + channel]);
        count++;
      }
      if (count > 0) for (let c = 0; c < 3; c++) correction[c] /= count;
    }
    for (let y = Math.max(0, Math.floor(cy - r * 1.35)); y < Math.min(h, Math.ceil(cy + r * 1.35)); y++) {
      for (let x = Math.max(0, Math.floor(cx - r * 1.35)); x < Math.min(w, Math.ceil(cx + r * 1.35)); x++) {
        const d = Math.hypot(x + 0.5 - cx, y + 0.5 - cy) / r;
        const offset = (y * w + x) * 4;
        if (mark.kind === RETOUCH_REDEYE) {
          const red = retouchLinear(output[offset]), green = retouchLinear(output[offset + 1]), blue = retouchLinear(output[offset + 2]);
          const gate = (1 - retouchSmooth(1, 1.35, d)) * retouchSmooth(0.25, 0.5,
            (red - Math.max(green, blue)) / Math.max(1e-6, red));
          const neutral = 0.5 * (green + blue) * (1 - 0.9 * mark.amount);
          output[offset] = retouchEncoded(red + (neutral - red) * gate);
          output[offset + 1] = retouchEncoded(green + (neutral - green) * gate);
          output[offset + 2] = retouchEncoded(blue + (neutral - blue) * gate);
        } else {
          const px = Math.round(sx + x - cx), py = Math.round(sy + y - cy);
          if (px < 0 || py < 0 || px >= w || py >= h) continue;
          const weight = (1 - retouchSmooth(1 - mark.feather, 1, d)) * mark.amount;
          for (let c = 0; c < 3; c++) {
            const base = retouchLinear(output[offset + c]);
            const healed = retouchLinear(source[(py * w + px) * 4 + c]) + correction[c];
            output[offset + c] = retouchEncoded(base + (healed - base) * weight);
          }
        }
      }
    }
  }
  // Content-aware fill runs ONCE for every fill mark, not once per mark: a single
  // combined hole is cheaper than N PatchMatch searches, and it is also more
  // correct, because two nearby holes solved independently can disagree about the
  // region between them. The parameters are the engine's fixed defaults rather than
  // UI controls, because there is no meaningful dial for a user to turn here.
  let holeMask: Uint8Array | null = null;
  for (const mark of marks) {
    if (mark.kind !== RETOUCH_FILL) continue;
    if (!holeMask) holeMask = new Uint8Array(w * h);
    const fx = (mark.x * space.fullWidth - space.originX) / space.stepX;
    const fy = (mark.y * space.fullHeight - space.originY) / space.stepY;
    const fr = Math.max(0.5, mark.radius * longEdge / step);
    for (let y = Math.max(0, Math.floor(fy - fr)); y < Math.min(h, Math.ceil(fy + fr)); y++) {
      for (let x = Math.max(0, Math.floor(fx - fr)); x < Math.min(w, Math.ceil(fx + fr)); x++) {
        if (Math.hypot(x + 0.5 - fx, y + 0.5 - fy) <= fr) holeMask[y * w + x] = 1;
      }
    }
  }
  if (holeMask) {
    const filled = contentAwareFill(output, w, h, holeMask, contentFillDefaults());
    output.set(filled.subarray(0, output.length));
  }
  return output;
}

/** Source and target rings needed by the visible marks, in source pixels. */
export function retouchReadBounds(marks: RetouchMark[], bounds: number[], fullW: number, fullH: number): number[] {
  let left = bounds[0], top = bounds[1], right = bounds[2], bottom = bounds[3];
  const longEdge = Math.max(fullW, fullH);
  for (const mark of marks) {
    // Heal and clone both READ from a second location, so the bounds have to cover
    // the source ring as well as the target ring. Fill reads from the rest of the
    // frame instead, so its own disc is all that can be declared here; the patch
    // search is confined to whatever buffer it is handed, which is a real
    // limitation for a tiled fill and is stated in the module header.
    if (mark.kind !== RETOUCH_HEAL && mark.kind !== RETOUCH_CLONE && mark.kind !== RETOUCH_FILL) continue;
    const x = mark.x * fullW, y = mark.y * fullH, radius = mark.radius * longEdge * 1.4 + 2;
    if (x + radius < bounds[0] || x - radius > bounds[2] || y + radius < bounds[1] || y - radius > bounds[3]) continue;
    if (mark.kind === RETOUCH_FILL) {
      left = Math.min(left, x - radius); right = Math.max(right, x + radius);
      top = Math.min(top, y - radius); bottom = Math.max(bottom, y + radius);
      continue;
    }
    const sx = mark.sourceX * fullW, sy = mark.sourceY * fullH;
    left = Math.min(left, x - radius, sx - radius); right = Math.max(right, x + radius, sx + radius);
    top = Math.min(top, y - radius, sy - radius); bottom = Math.max(bottom, y + radius, sy + radius);
  }
  return [Math.max(0, Math.floor(left)), Math.max(0, Math.floor(top)),
    Math.min(fullW, Math.ceil(right)), Math.min(fullH, Math.ceil(bottom))];
}
