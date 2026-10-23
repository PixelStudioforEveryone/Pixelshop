#!/usr/bin/env node
// Geometry / crop mapping checks.
//
// The ArkTS module is transpiled in-process and evaluated, so this test runs
// the real shipped source rather than a copy of the formulas. It pins:
//   1. resolution independence of the whole geometry+display mapping,
//   2. the rotate/flip remap matching a hand-written row loop,
//   3. round trips between display, frame and source for every orientation,
//   4. auto-crop keeping every displayed corner inside the source,
//   5. the crop rectangle the crop tool commits.
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
const tsPath = 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js';
const ts = require(tsPath);

const modules = new Map();
function loadEtc(rel) {
  const file = path.resolve(root, rel);
  if (modules.has(file)) return modules.get(file);
  const source = fs.readFileSync(file, 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
    fileName: file,
  }).outputText;
  const module = { exports: {} };
  // Sibling ArkTS modules (RetouchCore -> models/RetouchSettings) are resolved
  // through the same transpiler so a test can exercise more than one file
  // without copying its formulas into the test.
  const context = vm.createContext({ module: module, exports: module.exports, console: console,
    Int32Array: Int32Array, Float32Array: Float32Array, Uint8ClampedArray: Uint8ClampedArray,
    Math: Math, Number: Number, Array: Array, Object: Object, JSON: JSON,
    require: function (name) {
      if (name.charAt(0) !== '.') throw new Error('unsupported require: ' + name);
      const sibling = path.resolve(path.dirname(file), name.endsWith('.ets') ? name : name + '.ets');
      return loadEtc(sibling);
    } });
  modules.set(file, module.exports);
  new vm.Script('(function (exports, module, require) {' + js + '\n})', { filename: file })
    .runInContext(context)(module.exports, module, context.require);
  return module.exports;
}

const G = loadEtc('entry/src/main/ets/edit/engine/GeometryMath.ets');

const failures = [];
function check(name, condition, detail) {
  if (condition) {
    console.log('  ok   ' + name);
  } else {
    console.log('  FAIL ' + name + (detail === undefined ? '' : ' :: ' + detail));
    failures.push(name);
  }
}
function close(a, b, eps) {
  return Math.abs(a - b) <= (eps === undefined ? 1e-9 : eps);
}

const dims = (over) => Object.assign({
  width: 1000, height: 500,
  cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
  rotation: 0, flipH: false, flipV: false,
}, over);

function mapFor(g, over, renderW, renderH) {
  const d = dims(over);
  return G.buildGeometryMap(g, renderW || d.width, renderH || d.height, d, {
    referenceWidth: d.width, referenceHeight: d.height,
  });
}

console.log('geometry map');
{
  // 1. Resolution independence. A perspective + straighten + auto-crop frame
  //    must send the same normalized frame point to the same normalized source
  //    point whether it is rendered at full size or as a bounded preview.
  const g = [30, -45, 8, 12, 92, 20, -18, 1];
  const full = mapFor(g, {}, 4000, 2000);
  const preview = mapFor(g, {}, 512, 256);
  check('coef px identical across resolutions', close(full.coef.px, preview.coef.px));
  check('coef py identical across resolutions', close(full.coef.py, preview.coef.py));
  check('auto-crop zoom identical across resolutions', close(full.coef.zoom, preview.coef.zoom, 1e-9),
    full.coef.zoom + ' vs ' + preview.coef.zoom);
  // `scaleInvariant` records whether render and reference dimensions match; it
  // never changes the projection itself.
  const g1 = [30, -45, 8, 12, 92, 20, -18, 1];
  check('scaleInvariant true when render equals reference',
    G.geometryCoefficientsFor(g1, { renderWidth: 4000, renderHeight: 2000,
      referenceWidth: 4000, referenceHeight: 2000 }).scaleInvariant === true);
  check('scaleInvariant false for a bounded preview',
    G.geometryCoefficientsFor(g1, { renderWidth: 512, renderHeight: 256,
      referenceWidth: 4000, referenceHeight: 2000 }).scaleInvariant === false);
  // Normalized frame point -> normalized source point must agree.
  let maxDelta = 0;
  for (let i = 0; i <= 8; i++) {
    const nx = -1 + i * 0.25;
    const a = G.sourceToFrameNormalized(full, nx, 0.3);
    const b = G.sourceToFrameNormalized(preview, nx, 0.3);
    if (!a && !b) continue;
    if (!a || !b) { maxDelta = 1e9; break; }
    maxDelta = Math.max(maxDelta,
      Math.abs(a[0] / full.width - b[0] / preview.width),
      Math.abs(a[1] / full.height - b[1] / preview.height));
  }
  // The two maps differ only by their pixel geography: source->frame returns
  // pixels, so normalizing them leaves the half-pixel centre offset of the
  // smaller render. Anything larger than half a preview pixel would be a real
  // preview/export divergence.
  const tolerance = 0.5 / Math.min(preview.width, preview.height) + 1e-9;
  check('frame->source normalized agreement', maxDelta < tolerance,
    'maxDelta=' + maxDelta + ' tolerance=' + tolerance);
}

{
  // 2. The rotate/flip remap must equal the analytic mapping that the GPU
  //    present pass, the coverage overlay and touch input all invert
  //    (frameToDisplay / displayToFrame), for all four quarter turns with all
  //    four flip combinations and with the crop on and off. A hand-written row
  //    loop used to be the reference here and it encoded the flips in crop
  //    space, so it agreed with the same wrong order in the table and could
  //    never catch it; the display transform is the real invariant.
  const crops = [
    { cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1 },
    { cropLeft: 0.21, cropTop: 0.17, cropRight: 0.83, cropBottom: 0.69 },
  ];
  function displayOracleCropPixel(map, x, y) {
    const f = G.displayToFrame(map, (x + 0.5) / map.outputWidth, (y + 0.5) / map.outputHeight);
    if (!f) return null;
    return [Math.floor(f[0] - map.left + 1e-6), Math.floor(f[1] - map.top + 1e-6)];
  }
  function tableCropPixel(map, table, x, y) {
    return [table.x[y * map.outputWidth + x], table.y[x * map.outputHeight + y]];
  }
  for (let c = 0; c < crops.length; c++) {
    for (const rotation of [0, 90, 180, 270]) {
      for (let flips = 0; flips < 4; flips++) {
        const crop = crops[c];
        const over = Object.assign({ rotation: rotation,
          flipH: !!(flips & 1), flipV: !!(flips & 2) }, crop);
        const d = dims(over);
        const map = G.buildGeometryMap(undefined, d.width, d.height, d);
        const table = G.buildFrameSampleTable(map);
        const cropWidth = map.cropWidth;
        const cropHeight = map.cropHeight;
        const swapped = rotation === 90 || rotation === 270;
        check('output size rot' + rotation + ' f' + flips + ' crop' + c,
          map.outputWidth === (swapped ? cropHeight : cropWidth) &&
          map.outputHeight === (swapped ? cropWidth : cropHeight),
          map.outputWidth + 'x' + map.outputHeight + ' crop=' + cropWidth + 'x' + cropHeight);
        let mismatch = 0;
        const seen = new Set();
        for (let y = 0; y < map.outputHeight; y++) {
          for (let x = 0; x < map.outputWidth; x++) {
            const expected = displayOracleCropPixel(map, x, y);
            const actual = tableCropPixel(map, table, x, y);
            if (!expected || actual[0] < 0 || actual[0] >= cropWidth ||
              actual[1] < 0 || actual[1] >= cropHeight ||
              actual[0] !== expected[0] || actual[1] !== expected[1]) {
              mismatch++;
              continue;
            }
            seen.add(actual[1] * cropWidth + actual[0]);
          }
        }
        check('remap matches displayToFrame rot' + rotation + ' f' + flips + ' crop' + c,
          mismatch === 0, 'mismatch=' + mismatch);
        // The crop -> output map has to stay a bijection: a hole would publish
        // a transparent pixel and a duplicate would smear one source pixel.
        check('remap is a bijection rot' + rotation + ' f' + flips + ' crop' + c,
          seen.size === map.outputWidth * map.outputHeight,
          'seen=' + seen.size + ' expected=' + (map.outputWidth * map.outputHeight));
      }
    }
  }
}

{
  // 3. Round trips. display -> source -> display must return the input wherever
  //    the source sample lands inside the frame (extreme control values can
  //    legitimately push it outside, which the renderer leaves transparent).
  const g = [14, -18, -6, 8, 104, -12, 9, 0];
  for (const rotation of [0, 90, 180, 270]) {
    for (const flipH of [false, true]) {
      for (const flipV of [false, true]) {
        const over = { rotation: rotation, flipH: flipH, flipV: flipV,
          cropLeft: 0.1, cropTop: 0.2, cropRight: 0.9, cropBottom: 0.8 };
        const map = mapFor(g, over);
        let worst = 0;
        let sampled = 0;
        for (const u of [0.35, 0.5, 0.72]) {
          for (const v of [0.4, 0.61, 0.8]) {
            const src = G.displayToSource(map, u, v);
            if (!src) continue;
            const back = G.sourceToDisplay(map, src[0], src[1]);
            if (!back) continue;
            sampled++;
            worst = Math.max(worst, Math.abs(back[0] - u), Math.abs(back[1] - v));
          }
        }
        check('display round trip rot' + rotation + ' fh' + flipH + ' fv' + flipV,
          sampled > 0 && worst < 1e-6, 'worst=' + worst + ' sampled=' + sampled);
      }
    }
  }
}

{
  // 4. Auto-crop must keep the whole displayed frame inside the source. The
  //    exact frame edge is excluded because the renderer's last source index is
  //    width-1, so a sample exactly on the border is outside by construction.
  const g = [80, 90, 25, 45, 120, 60, -60, 1];
  const map = mapFor(g, {}, 1200, 800);
  let outside = 0;
  let boundary = 0;
  const inset = 1e-6;
  for (let y = 0; y <= 10; y++) {
    for (let x = 0; x <= 10; x++) {
      const u = inset + (1 - 2 * inset) * (x / 10);
      const v = inset + (1 - 2 * inset) * (y / 10);
      const src = G.displayToSource(map, u, v);
      // A sample that lands exactly on the last source index returns null (the
      // renderer leaves that pixel transparent); that is a boundary artefact,
      // not a crop that reaches outside the frame.
      if (!src) { boundary++; continue; }
      if (src[0] < -1e-6 || src[1] < -1e-6 || src[0] > map.width - 1 + 1e-6 || src[1] > map.height - 1 + 1e-6) outside++;
    }
  }
  check('auto-crop keeps the frame inside the source', outside === 0 && boundary <= 2,
    'outside=' + outside + ' boundary=' + boundary);
  const loose = mapFor([80, 90, 25, 45, 120, 60, -60, 0], {}, 1200, 800);
  const strict = mapFor([80, 90, 25, 45, 120, 60, -60, 1], {}, 1200, 800);
  check('auto-crop only shrinks the frame', strict.coef.zoom >= 1 && loose.coef.zoom === 1,
    loose.coef.zoom + '/' + strict.coef.zoom);
}

{
  // 5. Crop-tool commit: a displayed-space point must survive
  //    display -> frame -> display, which is what the crop overlay and the
  //    retouch brush both rely on.
  const over = { rotation: 90, cropLeft: 0.25, cropTop: 0.1, cropRight: 0.75, cropBottom: 0.6 };
  const map = mapFor(undefined, over);
  const frame = G.displayToFrame(map, 0.2, 0.25);
  check('commit point inside frame', !!frame);
  const back = G.frameToDisplay(map, frame[0], frame[1]);
  check('commit point round trips through the display transform',
    !!back && Math.abs(back[0] - 0.2) < 1e-9 && Math.abs(back[1] - 0.25) < 1e-9,
    back ? back[0] + ',' + back[1] : 'null');
  check('quarter-turn size swap', map.outputWidth === map.cropHeight,
    map.outputWidth + ' vs ' + map.cropHeight);
}

{
  // 6. Identity must be a true no-op, and inactive geometry must not touch pixels.
  const map = mapFor(undefined, {});
  check('identity map is inactive', map.active === false);
  const p = G.displayToSource(map, 0.3, 0.7);
  check('identity displayToSource is exact',
    close(p[0] / map.width, 0.3, 1e-9) && close(p[1] / map.height, 0.7, 1e-9),
    p[0] + ',' + p[1]);
  const g = [0, 0, 0, 0, 100, 0, 0, 0];
  check('neutral geometry is inactive', G.geometryIsActive(g) === false);
  check('auto-crop flag alone activates geometry', G.geometryIsActive([0, 0, 0, 0, 100, 0, 0, 1]) === true);
}

{
  // 7. Perspective: sourceToFrame must be the exact analytic inverse of the
  //    sampling pass, not a look-alike. The forward direction is reproduced
  //    here straight from the frameToSource equations (`nx = cx/zoom`,
  //    `u = a*nx + b*ny`, `X = u / (1 - px*u - py*v)`) so a change to either
  //    side of the pair shows up as a numeric disagreement, and the negative
  //    control proves the projective denominator is load bearing.
  const W = 4000, H = 2400;
  const g = [35, -50, 11, 15, 88, 25, -30, 0];
  const map = G.buildGeometryMap(g, W, H, dims({ width: W, height: H }), {
    referenceWidth: W, referenceHeight: H,
  });
  const c = map.coef;
  const det = c.a * c.e - c.b * c.d;
  const ia = c.e / det, ib = -c.b / det, id = -c.d / det, ie = c.a / det;
  let worstFrame = 0, worstSource = 0, worstForward = 0, worstNaive = 0;
  let frameSamples = 0, sourceSamples = 0;
  for (let i = 0; i <= 24; i++) {
    for (let j = 0; j <= 24; j++) {
      const fx = W * i / 24, fy = H * j / 24;
      const src = G.frameToSource(map, fx, fy);
      if (src) {
        const back = G.sourceToFrame(map, src[0], src[1]);
        if (back) {
          frameSamples++;
          worstFrame = Math.max(worstFrame, Math.abs(back[0] - fx), Math.abs(back[1] - fy));
        }
      }
      const sx = W * i / 24, sy = H * j / 24;
      const fwd = G.sourceToFrame(map, sx, sy);
      if (fwd) {
        const back = G.frameToSource(map, fwd[0], fwd[1]);
        if (back) {
          sourceSamples++;
          worstSource = Math.max(worstSource, Math.abs(back[0] - sx), Math.abs(back[1] - sy));
        }
      }
      // Forward homography written out independently of GeometryMath, then
      // inverted through the shipped sourceToFrameNormalized. That entry point
      // takes normalized source coordinates and returns FRAME PIXELS, so the
      // oracle is converted with the same zoom/pixel-centre convention.
      const cx = -1 + 2 * i / 24, cy = -1 + 2 * j / 24;
      const nx = cx / c.zoom, ny = cy / c.zoom;
      const u = c.a * nx + c.b * ny, v = c.d * nx + c.e * ny;
      const den = 1 - c.px * u - c.py * v;
      const X = u / den, Y = v / den;
      const inverse = G.sourceToFrameNormalized(map, X, Y);
      const expectedX = (cx * c.zoom + 1) * W / 2 - 0.5;
      const expectedY = (cy * c.zoom + 1) * H / 2 - 0.5;
      if (inverse) {
        worstForward = Math.max(worstForward, Math.abs(inverse[0] - expectedX), Math.abs(inverse[1] - expectedY));
      }
      // Negative control: dropping the projective denominator would move the
      // point by this much, so a regression to that form cannot pass silently.
      const naiveX = ((ia * X + ib * Y) * c.zoom + 1) * W / 2 - 0.5;
      const naiveY = ((id * X + ie * Y) * c.zoom + 1) * H / 2 - 0.5;
      worstNaive = Math.max(worstNaive, Math.abs(naiveX - expectedX), Math.abs(naiveY - expectedY));
    }
  }
  check('frame->source->frame round trip is exact for perspective',
    frameSamples > 200 && worstFrame < 1e-9, 'worst=' + worstFrame + ' samples=' + frameSamples);
  check('source->frame->source round trip is exact for perspective',
    sourceSamples > 200 && worstSource < 1e-9, 'worst=' + worstSource + ' samples=' + sourceSamples);
  check('sourceToFrame inverts the sampling-pass homography exactly',
    worstForward < 1e-9, 'worst=' + worstForward + ' px');
  check('the projective denominator px*X + py*Y + 1 is load bearing',
    worstNaive > 10, 'naive variant worst error=' + worstNaive + ' px');
}

{
  // 8. Preview vs export agreement. The same session rendered at full
  //    resolution and as a bounded 1/8 preview must publish the same crop
  //    rectangle (within one preview pixel), the same output aspect and the
  //    same normalized source sampling, otherwise a slider drag would show a
  //    framing that the exported file does not reproduce.
  const g = [24, -36, 9, 14, 88, 18, -22, 1];
  const crop = { cropLeft: 0.131, cropTop: 0.17, cropRight: 0.81, cropBottom: 0.9 };
  const scale = 8;
  for (const rotation of [0, 90, 180, 270]) {
    for (let flips = 0; flips < 4; flips++) {
      const over = Object.assign({ rotation: rotation, flipH: !!(flips & 1), flipV: !!(flips & 2) }, crop);
      const full = G.buildGeometryMap(g, 4096, 2560, dims(Object.assign({ width: 4096, height: 2560 }, over)),
        { referenceWidth: 4096, referenceHeight: 2560 });
      const prev = G.buildGeometryMap(g, 512, 320, dims(Object.assign({ width: 512, height: 320 }, over)),
        { referenceWidth: 4096, referenceHeight: 2560 });
      const sameRect = Math.abs(full.left - prev.left * scale) <= scale &&
        Math.abs(full.top - prev.top * scale) <= scale &&
        Math.abs(full.cropWidth - prev.cropWidth * scale) <= scale &&
        Math.abs(full.cropHeight - prev.cropHeight * scale) <= scale;
      check('preview/export crop rect agrees rot' + rotation + ' f' + flips, sameRect,
        'full=' + full.left + ',' + full.top + ',' + full.cropWidth + ',' + full.cropHeight +
        ' preview*8=' + prev.left * scale + ',' + prev.top * scale + ',' +
        prev.cropWidth * scale + ',' + prev.cropHeight * scale);
      const fullAspect = full.outputWidth / full.outputHeight;
      const prevAspect = prev.outputWidth / prev.outputHeight;
      check('preview/export output aspect agrees rot' + rotation + ' f' + flips,
        Math.abs(fullAspect - prevAspect) < 0.01, fullAspect + ' vs ' + prevAspect);
      // The normalized sampling of a displayed point must land on the same
      // source location in both renders.
      let worst = 0;
      let sampled = 0;
      for (const u of [0.15, 0.5, 0.85]) {
        for (const v of [0.2, 0.55, 0.9]) {
          const a = G.displayToSource(full, u, v);
          const b = G.displayToSource(prev, u, v);
          if (!a || !b) continue;
          sampled++;
          worst = Math.max(worst, Math.abs(a[0] / 4096 - b[0] / 512), Math.abs(a[1] / 2560 - b[1] / 320));
        }
      }
      // One preview pixel plus the crop quantization above.
      check('preview/export source sampling agrees rot' + rotation + ' f' + flips,
        sampled > 0 && worst < 2.5 / 512, 'worst=' + worst + ' sampled=' + sampled);
    }
  }
}

{
  // 9. Retouch coordinates inside a zoom tile. The tile renderer runs the
  //    retouch pass on a downscaled window of the full-resolution source and
  //    hands it the region viewport; a mark stored in source-normalized
  //    coordinates must still edit the pixel it was placed on. This is checked
  //    by behaviour (the centroid of the changed pixels), never by re-deriving
  //    the mapping in the test.
  const R = loadEtc('entry/src/main/ets/edit/engine/RetouchCore.ets');
  const W = 256, H = 192;
  const RED = [220, 40, 40];
  const GREY = 128;
  const mark = { id: 'm', kind: 'redeye', x: 0.6, y: 0.4, radius: 0.08, feather: 0.6,
    amount: 1, sourceX: 0.6, sourceY: 0.4 };
  const blobX = mark.x * W, blobY = mark.y * H, blobR = 12;
  function sample(fx, fy) {
    if (Math.hypot(fx - blobX, fy - blobY) <= blobR) return RED;
    return [GREY, GREY, GREY];
  }
  function fill(buffer, w, h, originX, originY, step) {
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        // Same pixel-centre sampling RegionPixels.read uses for a tile.
        const colour = sample(originX + (x + 0.5) * step - 0.5, originY + (y + 0.5) * step - 0.5);
        buffer.set([colour[0], colour[1], colour[2], 255], (y * w + x) * 4);
      }
    }
    return buffer;
  }
  function centroid(pixels, before, w, h) {
    let sumX = 0, sumY = 0, count = 0;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const i = (y * w + x) * 4;
        if (Math.abs(pixels[i] - before[i]) > 4 || Math.abs(pixels[i + 1] - before[i + 1]) > 4) {
          sumX += x + 0.5; sumY += y + 0.5; count++;
        }
      }
    }
    return count > 0 ? [sumX / count, sumY / count, count] : [NaN, NaN, 0];
  }
  const full = fill(new Uint8ClampedArray(W * H * 4), W, H, 0, 0, 1);
  const fullOut = R.retouchPixels(full, W, H, [mark], []);
  const fullCentre = centroid(fullOut, full, W, H);
  check('retouch mark edits the pixel it was placed on',
    fullCentre[2] > 200 && Math.abs(fullCentre[0] - blobX) < 1.5 && Math.abs(fullCentre[1] - blobY) < 1.5,
    'centroid=' + fullCentre[0] + ',' + fullCentre[1] + ' n=' + fullCentre[2]);
  {
    // Whole frame at half scale: viewport = whole source, step 2.
    const w = W / 2, h = H / 2;
    const tile = fill(new Uint8ClampedArray(w * h * 4), w, h, 0, 0, 2);
    const out = R.retouchPixels(tile, w, h, [mark], [0, 0, 2, 2, W, H]);
    const centre = centroid(out, tile, w, h);
    check('retouch mark keeps its source pixel in a downscaled tile',
      centre[2] > 30 && Math.abs(centre[0] - blobX / 2) < 1.5 && Math.abs(centre[1] - blobY / 2) < 1.5,
      'centroid=' + centre[0] + ',' + centre[1] + ' n=' + centre[2]);
  }
  {
    // Offset window (a real zoom tile): origin (64, 32) at half scale.
    const originX = 64, originY = 32, w = 64, h = 64, step = 2;
    const tile = fill(new Uint8ClampedArray(w * h * 4), w, h, originX, originY, step);
    const out = R.retouchPixels(tile, w, h, [mark], [originX, originY, step, step, W, H]);
    const centre = centroid(out, tile, w, h);
    const expectedX = (blobX - originX) / step, expectedY = (blobY - originY) / step;
    check('retouch mark keeps its source pixel in an offset zoom tile',
      centre[2] > 30 && Math.abs(centre[0] - expectedX) < 1.5 && Math.abs(centre[1] - expectedY) < 1.5,
      'centroid=' + centre[0] + ',' + centre[1] + ' n=' + centre[2] + ' expected=' + expectedX + ',' + expectedY);
  }
  {
    // A window that does not contain the mark must not paint anything: the
    // paint loop clamps to the buffer, so a wrong mapping can never smear a
    // heal outside the tile it belongs to.
    const originX = 0, originY = 0, w = 16, h = 16, step = 4;
    const tile = fill(new Uint8ClampedArray(w * h * 4), w, h, originX, originY, step);
    const outside = R.retouchPixels(tile, w, h, [mark], [originX, originY, step, step, W, H]);
    let changed = 0;
    for (let i = 0; i < outside.length; i++) if (outside[i] !== tile[i]) changed++;
    check('retouch mark outside the rendered window changes nothing', changed === 0, 'changed=' + changed);
  }
}

console.log('');
if (failures.length === 0) {
  console.log('geometry map: all checks passed');
  process.exit(0);
}
console.log('geometry map: ' + failures.length + ' check(s) failed');
process.exit(1);
