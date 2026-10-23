const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const ts = require('D:/DevEco Studio/tools/ohpm/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync('entry/src/main/ets/edit/engine/SpatialEffects.ets', 'utf8');
const context = { exports: {}, Math, Uint8ClampedArray };
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, context);
const apply = context.exports.applySpatialEffects;
const base = { vignetteAmount: 0, vignetteMidpoint: .5, vignetteRoundness: 0, vignetteFeather: .8, vignetteHighlights: 0, grainAmount: 0, grainSize: .5, grainRoughness: .5 };
function pixel(adj, x, y, size = 1600, color = [120, 140, 160, 255]) {
  const p = new Uint8ClampedArray(color);
  apply(p, 0, adj, x, y, size, size);
  return Array.from(p);
}
assert.deepStrictEqual(pixel(base, 0, 0), [120, 140, 160, 255]);
const dark = { ...base, vignetteAmount: -1 };
assert(pixel(dark, 0, 0)[0] < pixel(dark, 799, 799)[0]);
assert.deepStrictEqual(pixel(dark, 0, 0), pixel(dark, 1599, 1599));
assert(pixel({ ...base, vignetteAmount: 1 }, 0, 0)[0] > 120);
assert(pixel({ ...dark, vignetteHighlights: 1 }, 0, 0, 1600, [225, 225, 225, 255])[0] >
  pixel(dark, 0, 0, 1600, [225, 225, 225, 255])[0], 'highlight protection must reduce darkening');
assert.deepStrictEqual(pixel({ ...base, vignetteAmount: 1, vignetteHighlights: 1 }, 0, 0),
  pixel({ ...base, vignetteAmount: 1, vignetteHighlights: 0 }, 0, 0), 'highlight protection must not suppress a bright vignette');
const grain = { ...base, grainAmount: .8 };
const values = new Set();
for (let y = 400; y < 420; y++) for (let x = 400; x < 420; x++) {
  const p = pixel(grain, x, y);
  values.add(p[0]);
  assert.strictEqual(p[1] - p[0], 20, 'grain must not desaturate');
  assert.strictEqual(p[3], 255);
  assert.deepStrictEqual(p, pixel(grain, x, y), 'noise must be stable');
  assert.deepStrictEqual(p, pixel(grain, (x + .5) * 2 - .5, (y + .5) * 2 - .5, 3200), 'matching image positions must agree across resolutions');
}
assert(values.size > 10, 'grain must vary spatially');
console.log('PASS: identity, vignette direction/symmetry, grain variation/color preservation/stability/resolution consistency');
