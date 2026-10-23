// Point-colour eyedropper: "添加颜色" must arm a canvas pick, not plant a
// default red sample; a tap must create a sample whose HSL is the tapped SOURCE
// pixel's; every cancel path must leave picking mode.
//
// Falsifiability: if PointColorPanel goes back to calling
// `pointColor.addHsl(0, 0.75, 0.5)` on the button, check 2 below (begin adds
// nothing) still passes, so the panel-side guard is asserted in
// check_point_color_integration.cjs (no addHsl/addSample call in the panel
// code). This suite proves the model half: arming adds nothing, a real pixel
// read produces exactly that pixel, and cancellation never leaves the mode
// stuck.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');
const modules = new Map(), storage = new Map();
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file).exports;
  const mod = { exports: {} }; modules.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  vm.runInNewContext(js, {
    module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, ArrayBuffer,
    Uint8Array, Uint16Array, Uint32Array, Int32Array, Uint8ClampedArray, Float32Array, DataView, Promise, Error,
    setTimeout, clearTimeout, TextEncoder, TextDecoder, Buffer, __dirname: path.dirname(file),
    Observed: (c) => c, Concurrent: (f) => f,
    AppStorage: { get: (k) => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    require: (n) => {
      if (n === 'libvivid_gpu.so') return { default: { renderStack: async () => new ArrayBuffer(0) }, GpuOutputGeometry: {} };
      if (n === 'libvivid_ai.so') return { default: { isLoaded: () => false, release: () => {}, modelInfo: () => [] } };
      if (n === '@kit.CoreFileKit') {
        return { fileIo: {
          OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 8 },
          openSync: (p, f) => ({ fd: fs.openSync(p, f === 8 ? 'r' : 'w') }),
          closeSync: (h) => fs.closeSync(typeof h === 'number' ? h : h.fd),
          writeSync: (h, b) => fs.writeSync(typeof h === 'number' ? h : h.fd, Buffer.from(b)),
          readSync: (h, b) => fs.readSync(typeof h === 'number' ? h : h.fd, new Uint8Array(b)),
          statSync: (p) => (typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p)),
        } };
      }
      if (n === '@kit.ArkTS') {
        const encoder = () => ({ encode: (t) => new Uint8Array(Buffer.from(t, 'utf8')) });
        const decoder = () => ({ decode: (b) => Buffer.from(b).toString('utf8'),
          decodeToString: (b) => Buffer.from(b).toString('utf8') });
        function TextEncoderShim() { return encoder(); }
        TextEncoderShim.create = encoder;
        function TextDecoderShim() { return decoder(); }
        TextDecoderShim.create = decoder;
        return { util: { TextEncoder: TextEncoderShim, TextDecoder: TextDecoderShim },
          taskpool: { Task: class { static isCanceled() { return false; } }, execute: async (t) => t } };
      }
      if (n === '@kit.ImageKit') return { image: { PixelMapFormat: { RGBA_8888: 3 } } };
      if (n.startsWith('@kit.')) return { hilog: { info() {}, error() {} } };
      if (n.endsWith('.so')) return { default: {} };
      return load(path.resolve(path.dirname(file), n + '.ets'));
    },
  }, { filename: file });
  return mod.exports;
}

const { PointColorSettings } = load(root + '/edit/models/PointColorSettings.ets');
const { PointColorPicker } = load(root + '/edit/models/PointColorPicker.ets');
const { EditSession } = load(root + '/edit/models/EditSession.ets');
const { ToolType } = load(root + '/edit/models/ToolType.ets');
const pc = load(root + '/edit/engine/PointColorCore.ets');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
function close(a, b, eps, msg) {
  assert(Number.isFinite(a) && Math.abs(a - b) <= eps, `${msg} (got ${a}, want ${b})`);
  checks++;
}

// --- 0. the button cannot plant a default red sample ----------------------
// This is the exact regression the issue asked to stop: a button that adds a
// colour before the user has pointed at the photo. Checked on the panel CODE
// (comments stripped) so the module's explanation of the old behaviour is
// allowed, while a real addHsl/addSample call is not. Reverting the button to
// `pointColor.addHsl(0, 0.75, 0.5)` makes these three checks fail.
const panelSource = fs.readFileSync('entry/src/main/ets/components/PointColorPanel.ets', 'utf8');
const panelCode = panelSource.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
ok(!/addHsl\(\s*0\s*,\s*0\.75\s*,\s*0\.5\s*\)/.test(panelCode),
  'the 添加颜色 button does not seed the old hard-coded red sample');
ok(!panelCode.includes('pointColor.addHsl(') && !panelCode.includes('pointColor.addSample('),
  'the panel adds nothing by itself: a sample can only come from the canvas pick');
ok(panelCode.includes('beginPointColorPick') && panelCode.includes('togglePick'),
  'the button arms/cancels the canvas eyedropper instead');

// --- a fake source PixelMap with known RGBA pixels ------------------------
// The picker must use readPixelsToBuffer (the pipeline's channel-order-safe
// path), so the fake only implements getImageInfo + readPixelsToBuffer.
const W = 4, H = 4;
const PIXELS = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    // Deliberately not a grey ramp: each pixel has a hue that a default red
    // seed or a channel swap would fail to reproduce.
    PIXELS[i] = 10 + x * 60;       // r 10,70,130,190
    PIXELS[i + 1] = 20 + y * 55;   // g 20,75,130,185
    PIXELS[i + 2] = 30 + (x + y) * 25; // b 30,55,80,105,...
    PIXELS[i + 3] = 255;
  }
}
function fakeSource(width, height, bytes, tracker) {
  return {
    rect: { width, height },
    getImageInfo: async function () {
      if (tracker) tracker.info++;
      return { size: { width: this.rect.width, height: this.rect.height } };
    },
    readPixelsToBuffer: async function (buffer) {
      if (tracker) tracker.buffers++;
      new Uint8Array(buffer).set(bytes.subarray(0, Math.min(bytes.length, buffer.byteLength)));
    },
  };
}
/** A source whose read can be released by the test, for in-flight cancels. */
function deferredSource(bytes) {
  const source = fakeSource(W, H, bytes, null);
  let release = null;
  let enteredResolve = null;
  source.entered = new Promise((resolve) => { enteredResolve = resolve; });
  source.readPixelsToBuffer = async function (buffer) {
    enteredResolve();
    await new Promise((resolve) => { release = resolve; });
    new Uint8Array(buffer).set(bytes.subarray(0, Math.min(bytes.length, buffer.byteLength)));
  };
  source.release = () => { if (release) release(); };
  return source;
}
function expectedRgb(x, y) {
  const i = (y * W + x) * 4;
  return [PIXELS[i], PIXELS[i + 1], PIXELS[i + 2]];
}
function sessionWith(source) {
  const session = new EditSession();
  session.sourcePixelMap = source;
  session.imageWidth = W;
  session.imageHeight = H;
  return session;
}

// --- 1. pixelAt: the normalized point maps to the exact pixel -------------
{
  PointColorPicker.invalidate();
  close(PointColorPicker.pixelAt(PIXELS, W, H, 0.5, 0.5)[0], expectedRgb(2, 2)[0], 0,
    'pixelAt(0.5, 0.5) picks the pixel whose area contains the point (x=2)');
  close(PointColorPicker.pixelAt(PIXELS, W, H, 0.5, 0.5)[1], expectedRgb(2, 2)[1], 0,
    'and its green channel is not the neighbour\'s');
  close(PointColorPicker.pixelAt(PIXELS, W, H, 0.5, 0.5)[2], expectedRgb(2, 2)[2], 0,
    'and its blue channel is exact too');
  // Corners are inclusive: 0 maps to the first pixel, 1 to the last.
  close(PointColorPicker.pixelAt(PIXELS, W, H, 0, 0)[0], expectedRgb(0, 0)[0], 0,
    'a point at (0,0) reads the top-left pixel');
  close(PointColorPicker.pixelAt(PIXELS, W, H, 1, 1)[0], expectedRgb(W - 1, H - 1)[0], 0,
    'a point at (1,1) is clamped onto the bottom-right pixel, not past the buffer');
  close(PointColorPicker.pixelAt(PIXELS, W, H, 0.999, 0.001)[0], expectedRgb(W - 1, 0)[0], 0,
    'a point just inside the far edge reads the last column');
  ok(PointColorPicker.pixelAt(PIXELS, W, H, 1.01, 0.5) === null,
    'a point outside the image is rejected instead of silently clamped');
  ok(PointColorPicker.pixelAt(PIXELS, W, H, 0.5, -0.01) === null,
    'a negative coordinate is rejected');
  ok(PointColorPicker.pixelAt(PIXELS, W, H, NaN, 0.5) === null, 'a non-finite coordinate is rejected');
  ok(PointColorPicker.pixelAt(PIXELS, 0, H, 0.5, 0.5) === null, 'an empty buffer geometry is rejected');
  const transparent = Uint8ClampedArray.from(PIXELS);
  transparent[3] = 0;
  ok(PointColorPicker.pixelAt(transparent, W, H, 0, 0) === null,
    'a fully transparent pixel is not turned into a black sample');
}

// --- 2. samplePixel reads the real source once and returns that pixel -----
{
  PointColorPicker.invalidate();
  const tracker = { info: 0, buffers: 0 };
  const source = fakeSource(W, H, PIXELS, tracker);
  // The rest of the suite is async (real reads, in-flight cancels); keep Node
  // alive on the promise and make a rejection fail the process loudly.
  run(source, tracker).catch((error) => { console.error(error); process.exit(1); });
}
async function run(source, tracker) {
  const center = await PointColorPicker.samplePixel(source, 0.5, 0.5);
  ok(center !== null, 'samplePixel returns a colour for an in-bounds point');
  close(center[0], expectedRgb(2, 2)[0], 0, 'the sampled red equals the source pixel');
  close(center[1], expectedRgb(2, 2)[1], 0, 'the sampled green equals the source pixel');
  close(center[2], expectedRgb(2, 2)[2], 0, 'the sampled blue equals the source pixel');
  ok(tracker.buffers === 1, 'the first sample reads the source once (' + tracker.buffers + ')');
  const again = await PointColorPicker.samplePixel(source, 0.25, 0.75);
  close(again[0], expectedRgb(1, 3)[0], 0, 'a second tap at a different point reads that point');
  ok(tracker.buffers === 1 && tracker.info === 1,
    'the source bytes are cached per PixelMap identity, so a second tap does not re-read the photo');
  ok(await PointColorPicker.samplePixel(null, 0.5, 0.5) === null, 'no source yields no colour');
  ok(await PointColorPicker.samplePixel(source, 5, 0.5) === null,
    'an out-of-image point yields no colour rather than a clamped edge colour');

  // --- 3. arming adds NOTHING; the pixel becomes the sample ----------------
  const session = sessionWith(source);
  ok(session.pointColor.samples.length === 0, 'a fresh session has no point-colour sample');
  ok(session.beginPointColorPick() === true, 'the add button can arm the picker');
  ok(session.pointColor.picking === true, 'and the session reports picking mode');
  ok(session.pointColor.samples.length === 0,
    'arming adds no sample: no default red is planted before the user taps the photo');

  // The canvas maps display → source through displayPointToSource; with an
  // identity geometry that is the same normalized point. Tap at display
  // (0.75, 0.25): source pixel x=3, y=1.
  const sourcePoint = session.displayPointToSource(0.75, 0.25);
  ok(sourcePoint !== null, 'the display point maps into source normalized coordinates');
  close(sourcePoint[0], 0.75, 1e-12, 'identity geometry keeps the x coordinate');
  close(sourcePoint[1], 0.25, 1e-12, 'identity geometry keeps the y coordinate');
  const added = await session.pickPointColorAt(sourcePoint[0], sourcePoint[1]);
  ok(added === true, 'a tap while armed adds the picked sample');
  ok(session.pointColor.picking === false, 'and exits picking mode so the next tap edits rather than samples');
  ok(session.pointColor.samples.length === 1, 'exactly one sample was added');
  const want = expectedRgb(3, 1);
  const wantHsl = pc.rgbToHsl01(want[0] / 255, want[1] / 255, want[2] / 255);
  const sample = session.pointColor.samples[0];
  close(sample.hue, wantHsl[0], 1e-12, 'the sample hue is the tapped pixel hue');
  close(sample.saturation, wantHsl[1], 1e-12, 'the sample saturation is the tapped pixel saturation');
  close(sample.luminance, wantHsl[2], 1e-12, 'the sample luminance is the tapped pixel lightness');
  // Non-vacuity: the old hard-coded seed was red at 0.75/0.5. If the picker
  // regressed to that, every assertion above would fail, but say so directly.
  const isSeed = Math.abs(sample.hue - 0) < 1e-9 &&
    Math.abs(sample.saturation - 0.75) < 1e-9 && Math.abs(sample.luminance - 0.5) < 1e-9;
  ok(!isSeed, 'the sample is not the old hard-coded red seed');
  ok(Math.abs(sample.hue - wantHsl[0]) < 1e-9 && wantHsl[0] > 0.5,
    'and it really is this bluish pixel, not any red default (' + sample.hue + ')');
  ok(session.pointColor.samples[0].hueShift === 0,
    'a freshly picked sample has no shift yet; the sliders start from the sampled colour');

  // --- 4. cancel paths -----------------------------------------------------
  // (a) button toggled again.
  ok(session.beginPointColorPick() === true, 'the picker can be re-armed');
  session.cancelPointColorPick();
  ok(session.pointColor.picking === false, 'toggling the button cancels picking');
  ok(session.pointColor.samples.length === 1, 'cancelling adds no sample');

  // (b) deleting a sample.
  session.beginPointColorPick();
  session.pointColor.removeAt(0);
  ok(session.pointColor.picking === false, 'deleting a sample leaves picking mode');
  ok(session.pointColor.samples.length === 0, 'and deletes the sample it was arming for');

  // (c) clearing the list.
  session.pointColor.addHsl(0.5, 0.5, 0.5);
  session.beginPointColorPick();
  session.pointColor.clear();
  ok(session.pointColor.picking === false, 'clearing all samples leaves picking mode');
  ok(session.pointColor.samples.length === 0, 'and empties the list');

  // (d) switching to a tool that paints/drags the image.
  session.pointColor.addHsl(0.5, 0.5, 0.5);
  session.beginPointColorPick();
  session.setActiveTool(ToolType.CROP);
  ok(session.pointColor.picking === false, 'switching to a non-adjust tool cancels picking');
  session.setActiveTool(ToolType.ADJUST);

  // (e) opening another photo.
  session.beginPointColorPick();
  session.reset();
  ok(session.pointColor.picking === false, 'a reset (new photo) cancels picking');
  ok(session.pointColor.samples.length === 0, 'and starts the new photo with no samples');

  // --- 5. a tap that misses / a failed read stays armed, adds nothing -----
  session.sourcePixelMap = source;
  session.imageWidth = W;
  session.imageHeight = H;
  session.beginPointColorPick();
  ok(await session.pickPointColorAt(1.2, 0.5) === false, 'an out-of-frame point adds no sample');
  ok(session.pointColor.picking === true, 'and keeps the picker armed so the user can tap again');
  ok(session.pointColor.samples.length === 0, 'still no sample');

  // --- 6. cancellation while the read is in flight ------------------------
  PointColorPicker.invalidate();
  const inflight = deferredSource(PIXELS);
  const raceSession = sessionWith(inflight);
  raceSession.beginPointColorPick();
  const pending = raceSession.pickPointColorAt(0.5, 0.5);
  // Wait until the pick is actually inside readPixelsToBuffer before cancelling:
  // resolving a promise the picker has not awaited yet would prove nothing.
  await inflight.entered;
  raceSession.cancelPointColorPick();           // user toggled the button off
  inflight.release();
  ok(await pending === false, 'a read that finishes after cancelling does not add a sample');
  ok(raceSession.pointColor.samples.length === 0, 'and the list is still empty');

  // --- 7. photo switch while the read is in flight ------------------------
  PointColorPicker.invalidate();
  const slowOld = deferredSource(PIXELS);
  const switchSession = sessionWith(slowOld);
  switchSession.beginPointColorPick();
  const oldPick = switchSession.pickPointColorAt(0.5, 0.5);
  const newBytes = Uint8ClampedArray.from(PIXELS);
  for (let i = 0; i < newBytes.length; i += 4) { newBytes[i] = 255; newBytes[i + 1] = 0; newBytes[i + 2] = 0; }
  switchSession.sourcePixelMap = fakeSource(W, H, newBytes, null); // the photo changed
  switchSession.processGeneration++;
  await slowOld.entered;
  slowOld.release();
  ok(await oldPick === false, 'a read that finishes after a photo switch does not publish a sample');
  ok(switchSession.pointColor.samples.length === 0,
    'so the new photo does not inherit a colour sampled from the previous one');

  // --- 8. the model object replaced while the read is in flight ------------
  PointColorPicker.invalidate();
  const staleSource = deferredSource(PIXELS);
  const undoSession = sessionWith(staleSource);
  undoSession.beginPointColorPick();
  const staleSettings = undoSession.pointColor;
  const stalePick = undoSession.pickPointColorAt(0.5, 0.5);
  await staleSource.entered;
  // Undo restores a snapshot by REPLACING the settings object; the in-flight
  // pick must not write into the orphaned one.
  undoSession.pointColor = new PointColorSettings();
  staleSource.release();
  ok(await stalePick === false, 'a read that finishes after the model was replaced adds nothing');
  ok(staleSettings.samples.length === 0, 'and the orphaned settings object is not mutated');
  ok(undoSession.pointColor.samples.length === 0, 'the live model is untouched too');

  console.log('PASS point colour picker: arming adds nothing (no default red), a tap creates a sample');
  console.log('     whose HSL is exactly the tapped SOURCE pixel, display→source mapping is used, every');
  console.log('     cancel path (button, delete, clear, tool switch, new photo) exits picking mode, and');
  console.log('     in-flight reads are dropped after a cancel, a photo switch or an undo that replaced');
  console.log('     the model object.');
  console.log(checks + ' checks passed');
}
