// Runs production helpers, real UI gesture methods, sidecar model and CPU/GPU
// curve table builders. Native GLES rasterization is outside this Node test.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '..'), cache = new Map();
const base = 'entry/src/main/ets/';
function load(rel) {
  const file = path.isAbsolute(rel) ? rel : path.join(root, rel);
  if (cache.has(file)) return cache.get(file).exports;
  const mod = { exports: {} }; cache.set(file, mod);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('WorkerCore.ets')) source += '\nexport { prepareCurve, smoothCurveYLocal, curveIsIdentity };';
  const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021,
    module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(js, { module: mod, exports: mod.exports, console, Math, JSON, Array, Number,
    Date, Map, Set, Object, Promise, ArrayBuffer, Uint8Array, Uint8ClampedArray, Float32Array,
    Observed: c => c, Sendable: c => c, Concurrent: c => c, AppStorage: { get() {}, setOrCreate() {} },
    setTimeout, clearTimeout, require: name => {
      if (name === 'libvivid_gpu.so') return { default: {}, __esModule: true };
      if (name.startsWith('@kit.')) return { util: { generateRandomUUID: () => 'test-' + Math.random() },
        image: {}, hilog: { info() {}, error() {}, warn() {} } };
      if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file), name + '.ets'));
    } }, { filename: file });
  return mod.exports;
}
const core = load(base + 'edit/engine/ToneCurveCore.ets');
const { CurveAnchor, ColorAdjustments, smoothCurveY } = load(base + 'edit/models/Adjustment.ets');
const { EditSession } = load(base + 'edit/models/EditSession.ets');
const { prepareCurve, smoothCurveYLocal, curveIsIdentity } = load(base + 'edit/engine/WorkerCore.ets');
const { GpuShaderBridge } = load(base + 'edit/engine/GpuShaderBridge.ets');
const processorSource = ts.createSourceFile('ImageProcessor.ts',
  fs.readFileSync(path.join(root,base+'edit/engine/ImageProcessor.ets'),'utf8'),ts.ScriptTarget.ES2021,true);
const processorClass = processorSource.statements.find(n=>ts.isClassDeclaration(n) && n.name.text==='ImageProcessor');
const pureMethods=['prepareCurve','sampleCurve','evalPreparedCurve','applyToneCurve','applyChannelCurve','clamp01'];
const processorMethods=processorClass.members.filter(n=>n.name && pureMethods.includes(n.name.getText(processorSource)));
assert.strictEqual(processorMethods.length,pureMethods.length);
const processorJs=ts.transpileModule('class ImageProcessor{'+processorMethods.map(n=>n.getText(processorSource)).join('\n')+'}\nImageProcessor;',
  {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText;
const CpuCurve=vm.runInNewContext(processorJs,{smoothCurveY,CurveAnchor,Math,Array});
const identity = () => [{ x: 0, y: 0 }, { x: .5, y: .5 }, { x: 1, y: 1 }];
const close = (a, b, eps = 1e-10) => assert(Math.abs(a - b) <= eps, `${a} != ${b}`);
let count = 0;
for (const [index, x, y, axis, expected] of [
  [0, .2, 0, core.CurveDragAxis.BOTH, [.2, 0]], [0, 0, .3, core.CurveDragAxis.BOTH, [0, .3]],
  [2, .8, 1, core.CurveDragAxis.BOTH, [.8, 1]], [2, 1, .7, core.CurveDragAxis.BOTH, [1, .7]],
  [0, 1, .8, core.CurveDragAxis.X, [.49, 0]], [2, 0, .2, core.CurveDragAxis.X, [.51, 1]],
  [1, -.5, 2, core.CurveDragAxis.BOTH, [.01, 1]],
]) {
  const before = identity(), saved = JSON.stringify(before);
  const r = core.moveCurveAnchor(before, index, x, y, axis);
  assert(r.moved); close(r.points[index].x, expected[0]); close(r.points[index].y, expected[1]);
  assert.strictEqual(JSON.stringify(before), saved); count++;
}
for (const [points, index, x, y, axis] of [
  [identity(), 0, 0, 0, -1], [identity(), 1, .5, .5, -1], [identity(), -1, .2, .3, -1],
  [identity(), 1, NaN, .3, -1], [identity(), 1, .3, Infinity, -1], [identity(), 0, .2, .3, 99],
  [[{x:0,y:0},{x:NaN,y:.4},{x:1,y:1}],1,.2,.3,-1],
  [[{x:0,y:0},{x:.5,y:.4},{x:.4,y:1}],1,.2,.3,-1],
]) { assert(!core.moveCurveAnchor(points, index, x, y, axis).moved); count++; }
const narrow = core.moveCurveAnchor([{x:0,y:0},{x:.003,y:.5},{x:.006,y:1}],1,1,.6);
assert(narrow.moved && narrow.points[1].x < .006 && narrow.points[1].x > 0); count++;
const shifted = [{x:.2,y:0},{x:.5,y:.5},{x:.8,y:1}];
for (const x of [0, .1, .2, .8, .9, 1, .50001]) {
  assert(!core.addCurveAnchor(shifted, x, .4).moved); count++;
}
assert(core.addCurveAnchor(shifted, .35, .4).moved); count++;
assert.strictEqual(core.curveHitTest(identity(),0,150,260,150),0);
assert.strictEqual(core.curveHitTest(identity(),260,0,260,150),2); count += 2;

// Extract the actual gesture methods, replacing only render/timer side effects.
const ui = fs.readFileSync(path.join(root,base+'components/ToneCurveControl.ets'),'utf8');
const from = ui.indexOf('  private curveSignature('), to = ui.indexOf('  private drawCurve(', from);
assert(from >= 0 && to > from);
const uiJs = ts.transpileModule('class Harness {\n'+ui.slice(from,to)+'\n}\nHarness;',
  {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText;
const Harness = vm.runInNewContext(uiJs, { TouchType:{Down:0,Move:1,Up:2,Cancel:3},
  MouseButton:{Left:0,Right:1},MouseAction:{Press:0,Release:1,Move:2},SourceType:{Mouse:1},
  // The curve widget publishes its scroll lock through AppStorage; without it the
  // touch handler throws a ReferenceError before the curve logic is exercised.
  AppStorage:{get(){return undefined;},setOrCreate(){}},
  ...core, CurveAnchor, Math });
function makeUI(points) {
  const h = new Harness(), adj = new ColorAdjustments(); adj.setCurvePoints(0,points);
  h.graphWidth=260;h.graphHeight=150;h.selectedChannel=0;h.selectedPoint=-1;h.draggingPoint=-1;
  h.gestureUndoPushed=false;h.gestureAxis=-1;h.curveRevision=0;h.undo=0;
  h.editSession={adjustmentsForContext:()=>adj,pushUndo:()=>h.undo++};
  h.currentPoints=()=>adj.getCurvePoints(h.selectedChannel);h.drawCurve=()=>{};h.scheduleProcess=()=>{};
  h.send=(type,x,y)=>h.handleCurveTouch({type,touches:type>=2?[]:[{x:x*260,y:(1-y)*150}]});
  return {h,adj};
}

// Context menu uses the actual pointer hit, never the previously selected point.
function right(h,x,y){h.handleCurveMouse({button:1,action:0,x:x*260,y:(1-y)*150,stopPropagation(){}});}
{
  const {h,adj}=makeUI(ColorAdjustments.defaultCurve());
  h.handleCurveMouse({button:0,action:0,x:104,y:60});
  h.handleCurveTouch({source:1,type:0,touches:[{x:104,y:60}]});
  h.handleCurveMouse({button:0,action:1,x:104,y:60});
  assert.strictEqual(adj.toneCurvePoints.length,3);assert.strictEqual(h.undo,1);
  right(h,.4,.6);assert(h.deleteContextPoint());assert.strictEqual(adj.toneCurvePoints.length,2);count++;
}
{
  const {h,adj}=makeUI(identity().map(p=>new CurveAnchor(p.x,p.y)));
  right(h,.5,.5);assert.strictEqual(h.contextPoint,1);assert(h.canDeleteContextPoint());
  assert.strictEqual(h.undo,0);assert(h.deleteContextPoint());assert.strictEqual(h.undo,1);
  assert.strictEqual(adj.getCurvePoints(0).length,2);assert(!h.deleteContextPoint());assert.strictEqual(h.undo,1);count++;
}
for(const end of [0,1]){
  const {h,adj}=makeUI(identity().map(p=>new CurveAnchor(p.x,p.y)));
  right(h,end,end);assert(h.contextPoint>=0);assert(!h.canDeleteContextPoint());assert(!h.deleteContextPoint());
  assert.strictEqual(h.undo,0);assert.strictEqual(adj.getCurvePoints(0).length,3);count++;
}
{
  const {h,adj}=makeUI(identity().map(p=>new CurveAnchor(p.x,p.y)));
  right(h,.3,.8);assert(!h.showCurvePointMenu);assert.strictEqual(h.undo,0);
  assert.strictEqual(adj.getCurvePoints(0).length,3);count++;
}
for(const change of ['channel','target','curve']){
  const {h,adj}=makeUI(identity().map(p=>new CurveAnchor(p.x,p.y)));right(h,.5,.5);
  if(change==='channel')h.selectedChannel=1;
  if(change==='target')h.editSession.adjustmentsForContext=()=>new ColorAdjustments();
  if(change==='curve')adj.getCurvePoints(0)[1].y=.6;
  assert(!h.deleteContextPoint());assert.strictEqual(h.undo,0);assert.strictEqual(adj.getCurvePoints(0).length,3);count++;
}
{
  const points=identity(),saved=JSON.stringify(points);
  assert(core.removeCurveAnchor(points,1).moved);assert.strictEqual(JSON.stringify(points),saved);
  for(const index of [-1,0,2,3,.5,NaN])assert(!core.removeCurveAnchor(points,index).moved);count++;
}
{
  const fresh=new ColorAdjustments();
  for(const channel of [0,1,2,3])assert.strictEqual(fresh.getCurvePoints(channel).length,2);
  assert(!fresh.hasAdvancedAdjustments());count++;
  const history=new EditSession();history.reset();const adj=history.activeLayer.adjustments;
  history.pushUndo();adj.setCurvePoints(0,identity().map(p=>new CurveAnchor(p.x,p.y)));
  history.pushUndo();adj.setCurvePoints(0,ColorAdjustments.defaultCurve());
  history.undo();assert.strictEqual(history.activeLayer.adjustments.toneCurvePoints.length,3);
  history.redo();assert.strictEqual(history.activeLayer.adjustments.toneCurvePoints.length,2);count++;
}
for (const [index,x,y] of [[0,0,.2],[0,.2,0],[2,1,.8],[2,.8,1]]) {
  const {h,adj}=makeUI(identity().map(p=>new CurveAnchor(p.x,p.y)));
  h.send(0,index===0?0:1,index===0?0:1); assert.strictEqual(h.undo,0);
  h.send(1,x,y);h.send(1,x,y);assert.strictEqual(h.undo,1);
  close(adj.getCurvePoints(0)[index].x,x);close(adj.getCurvePoints(0)[index].y,y);
  h.send(2);assert.strictEqual(h.draggingPoint,-1);count++;
}
{
  const {h,adj}=makeUI(identity().map(p=>new CurveAnchor(p.x,p.y)));
  h.send(0,.01,.02); h.send(1,.01,.02); assert.strictEqual(h.undo,0);
  h.send(1,.18,.02); close(adj.getCurvePoints(0)[0].x,.17); close(adj.getCurvePoints(0)[0].y,0);
  assert.strictEqual(h.undo,1); count++;
}
{
  const {h,adj}=makeUI(shifted.map(p=>new CurveAnchor(p.x,p.y)));
  h.send(0,.05,.4); h.send(1,.07,.4); h.send(2);
  assert.strictEqual(h.undo,0); assert.strictEqual(adj.getCurvePoints(0).length,3);count++;
  h.send(0,.35,.4);h.send(1,.36,.45);h.send(2);
  assert.strictEqual(h.undo,1); assert.strictEqual(adj.getCurvePoints(0).length,4);count++;
}

// Real sidecar round trip and table generation at every knot for moved endpoints.
const session=new EditSession(); session.reset();
const twoPoints=[{x:0,y:0},{x:1,y:1}];
assert(curveIsIdentity(twoPoints.map(p=>[p.x,p.y])));count++;
const cases=[shifted,[{x:0,y:.2},{x:.5,y:.55},{x:1,y:.8}],identity(),twoPoints];
for(const points of cases) for(const channel of [0,1,2,3]) {
  const anchors=points.map(p=>new CurveAnchor(p.x,p.y));
  session.activeLayer.adjustments.setCurvePoints(channel,anchors);
  const restored=new EditSession();assert(restored.importAdjustmentState(session.exportAdjustmentState()));
  const expected=points===cases[2]?ColorAdjustments.defaultCurve():anchors;
  assert.strictEqual(JSON.stringify(restored.activeLayer.adjustments.getCurvePoints(channel)),JSON.stringify(expected));
  for(const amount of [0,.4,-.4]) {
    const cpu=prepareCurve(points.map(p=>[p.x,p.y]),amount,channel!==0).samples;
    const prepared=CpuCurve.prepareCurve(anchors,amount,channel!==0);
    const gpu=new Uint8Array(GpuShaderBridge.curveBuffer(anchors,amount,channel!==0));
    assert.strictEqual(gpu.length,1025*4);
    for(let i=0;i<=1024;i++){
      close(cpu[i],((gpu[i*4]<<8)+gpu[i*4+1])/65535,1/65535);
      close(cpu[i],CpuCurve.evalPreparedCurve(prepared,i/1024));
      close(smoothCurveYLocal(points.map(p=>[p.x,p.y]),i/1024),smoothCurveY(anchors,i/1024));
    }
    count++;
  }
}
console.log(`PASS curve endpoints: ${count} cases; UI undo/constraints, sidecar and 1025-knot CPU/GPU tables`);
