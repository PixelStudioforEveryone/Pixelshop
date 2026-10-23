// Runs the real ArkTS models/cores against independent mask equations.
// Synthetic pixels only; never reads camera captures or user photos.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),modules=new Map(),storage=new Map();
function load(file){file=path.resolve(file);if(modules.has(file))return modules.get(file).exports;
 const mod={exports:{}};modules.set(file,mod);
 const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText;
 vm.runInNewContext(js,{module:mod,exports:mod.exports,console,Math,Number,Date,Map,Set,ArrayBuffer,Uint8Array,Uint8ClampedArray,Uint32Array,Float32Array,Promise,setTimeout,clearTimeout,Observed:c=>c,Concurrent:f=>f,
 AppStorage:{get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)},require:n=>{
  if(n==='libvivid_gpu.so')return {default:{renderStack:async()=>new ArrayBuffer(0)}};
  if(n==='@kit.ArkTS')return {taskpool:{Task:class{static isCanceled(){return false;}constructor(f,...a){this.f=f;this.a=a;}},execute:async t=>t.f(...t.a)}};
  if(n.startsWith('@kit.'))return {hilog:{info(){}}};
  if(n==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
      if(n.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file),n+'.ets'));
 }},{filename:file});return mod.exports;}
const {EditSession}=load(root+'/edit/models/EditSession.ets');
const {MaskLayer,MaskComponent,MaskComponentType:T,MaskBlendMode:O,BrushPoint,BrushStroke}=load(root+'/edit/models/Mask.ets');
const {MaskRenderer:M}=load(root+'/edit/engine/MaskRenderer.ets');
const {ImageProcessor:P}=load(root+'/edit/engine/ImageProcessor.ets');
const {rasterizeStructuredMaskCore:raster}=load(root+'/edit/engine/MaskRasterCore.ets');
const s=new EditSession();s.ensureBaseLayer();
const group=s.createMaskLayer(T.LINEAR_GRADIENT),line=group.components[0];
const rev=storage.get('maskRevision');
const radial=s.addMaskComponent(T.RADIAL_GRADIENT,O.SUBTRACT);
const brush=s.addMaskComponent(T.BRUSH,O.SUBTRACT);
assert.equal(s.layers[0].maskLayers.length,1);assert.equal(group.components.length,3);
assert.equal(s.selectedMaskLayerId,group.id);assert.equal(s.selectedMaskComponentId,brush.id);
assert.deepEqual(Array.from(group.components,c=>c.type),[T.LINEAR_GRADIENT,T.RADIAL_GRADIENT,T.BRUSH]);
assert(storage.get('maskRevision')>rev);
const originalIds=Array.from(group.components,c=>c.id);
const displayed=group.components.slice().reverse();assert.equal(displayed[0].id,brush.id);
assert.deepEqual(Array.from(group.components,c=>c.id),originalIds,'display order must never reverse composition');
s.selectMaskComponent(radial.id);s.selectMaskLayer(group.id);assert.equal(s.selectedMaskComponentId,radial.id,'group selection must not reset a child');
s.selectMaskComponent(brush.id);assert.equal(s.maskBrushMode,0,'subtract component paints positive coverage exactly once');
const stroke=new BrushStroke();stroke.flow=.35;stroke.density=.6;
for(const [x,y] of [[.15,.2],[.45,.2]]){const p=new BrushPoint();p.x=x;p.y=y;p.radius=.13;p.hardness=.45;stroke.points.push(p);}
brush.brushData.strokes=[stroke];
const w=96,h=72,a=M.renderComponent(line,w,h),b=M.renderComponent(radial,w,h),c=M.renderComponent(brush,w,h),out=M.renderMaskLayer(group,w,h);
for(let i=0;i<out.length;i++)assert.equal(out[i],Math.round(Math.round(a[i]*(255-b[i])/255)*(255-c[i])/255));
assert(out.some(v=>v>0)&&c.some(v=>v>0));
// rasterizeStructuredMaskCore now returns MaskRasterOutput {alpha, stats}; passing the
// object straight to Uint8ClampedArray yields a zero-length array, which reads as a
// mismatch. Every production caller (ImageProcessor:384, MaskRenderer:40,
// MaskRasterWorker:18) takes .alpha, so only this suite was stale.
assert.deepEqual(out,new Uint8ClampedArray(raster(P.plainMaskLayer(group),w,h).alpha),'overlay/GPU alpha/export must agree');
group.inverted=true;
const inverted=M.renderMaskLayer(group,w,h);
for(let i=0;i<out.length;i++)assert.equal(inverted[i],255-out[i],'group inverse must invert composed coverage, not each child');
group.inverted=false;radial.inverted=true;
const inversePart=M.renderComponent(radial,w,h);
for(let i=0;i<b.length;i++)assert.equal(inversePart[i],255-b[i],'component inverse must update actual alpha');
radial.inverted=false;
const restored=new EditSession();assert(restored.importAdjustmentState(s.exportAdjustmentState()));
const savedStroke=restored.layers[0].maskLayers[0].components[2].brushData.strokes[0];
assert.equal(savedStroke.flow,.35);assert.equal(savedStroke.density,.6);
assert.deepEqual(M.renderMaskLayer(restored.layers[0].maskLayers[0],w,h),out);
// Copy-and-invert must duplicate the entire parent independently, in one undo.
const copies=new EditSession();assert(copies.importAdjustmentState(s.exportAdjustmentState()));
const sourceGroup=copies.layers[0].maskLayers[0];sourceGroup.adjustments.setValue('exposure',.25);
const sourceState=copies.exportAdjustmentState();
const copyGroup=copies.duplicateMaskLayer(sourceGroup.id,true);
assert(copyGroup&&copyGroup.id!==sourceGroup.id&&copyGroup.inverted&&!sourceGroup.inverted);
assert.equal(copies.selectedMaskLayerId,copyGroup.id);assert.equal(copyGroup.components.length,3);
assert.equal(copyGroup.adjustments.getValue('exposure'),.25);
assert(copyGroup.components.every((p,i)=>p.id!==sourceGroup.components[i].id));
const copiedAlpha=M.renderMaskLayer(copyGroup,w,h);
for(let i=0;i<out.length;i++)assert.equal(copiedAlpha[i],255-out[i]);
copyGroup.adjustments.setValue('exposure',.8);copyGroup.components[2].brushData.strokes[0].points[0].x=.9;
assert.equal(sourceGroup.adjustments.getValue('exposure'),.25);
assert.equal(sourceGroup.components[2].brushData.strokes[0].points[0].x,.15);
copies.undo();assert.equal(copies.layers[0].maskLayers.length,1);
assert.equal(copies.exportAdjustmentState(),sourceState,'one undo must restore the whole copy-and-invert action');
copies.redo();assert.equal(copies.layers[0].maskLayers.length,2);
const invertedSource=copies.activeMaskLayer;
const plainCopy=copies.duplicateMaskLayer(invertedSource.id);
assert(plainCopy.inverted,'plain copy preserves inverse state');
const twiceFlipped=copies.duplicateMaskLayer(invertedSource.id,true);
assert(!twiceFlipped.inverted,'copy-and-invert toggles an already inverted source back');
assert.equal(copies.duplicateMaskLayer('missing',true),null);
s.undo();assert.equal(s.activeMaskLayer.components.length,2);s.redo();assert.equal(s.activeMaskLayer.components.length,3);
s.deleteMaskComponent(radial.id);assert.equal(s.activeMaskLayer.components.length,2);assert.equal(s.activeMaskLayer.id,group.id);
// Lightcraft's first component behavior, including deleting the original base.
for(const operation of [O.ADD,O.SUBTRACT,O.INTERSECT]){const g=new MaskLayer();const p=new MaskComponent(T.LINEAR_GRADIENT);p.blendMode=operation;g.components=[p];const bytes=M.renderMaskLayer(g,w,h);
 if(operation===O.INTERSECT)assert(bytes.every(v=>v===0));else assert.deepEqual(bytes,M.renderComponent(p,w,h));}
// Independent Lightcraft dab spacing / smooth alpha / flow / density oracle.
function reference(points,flow,density){const f=new Float32Array(w*h),r=points[0].radius*Math.min(w,h),hard=r*points[0].hardness;let prev;
 const stamp=(cx,cy)=>{for(let y=Math.max(0,Math.floor(cy-r));y<Math.min(h,Math.ceil(cy+r));y++)for(let x=Math.max(0,Math.floor(cx-r));x<Math.min(w,Math.ceil(cx+r));x++){
  const d=Math.hypot(x+.5-cx,y+.5-cy);if(d>r)continue;const t=Math.max(0,Math.min(1,(d-hard)/Math.max(1e-5,r-hard)));const alpha=d<=hard?1:1-t*t*(3-2*t);const i=y*w+x;f[i]=Math.min(density,f[i]+alpha*flow*(1-f[i]));}};
 for(const p of points){const q=[p.x*w,p.y*h];if(prev){const d=Math.hypot(q[0]-prev[0],q[1]-prev[1]);if(d<=1e-6)continue;const n=Math.ceil(d/Math.max(.5,r/4));for(let k=1;k<n;k++)stamp(prev[0]+(q[0]-prev[0])*k/n,prev[1]+(q[1]-prev[1])*k/n);}stamp(...q);prev=q;}return Uint8ClampedArray.from(f,v=>Math.round(v*255));}
assert.deepEqual(c,reference(stroke.points,.35,.6));
stroke.points.splice(1,0,stroke.points[0],stroke.points[0]);assert.deepEqual(M.renderComponent(brush,w,h),c,'holding still must not accumulate coverage');
const {retouchPixels,retouchReadBounds}=load(root+'/edit/engine/RetouchCore.ets');
const {cloneRetouchMarks}=load(root+'/edit/models/RetouchSettings.ets');
const pixels=new Uint8ClampedArray(w*h*4);for(let i=0;i<pixels.length;i+=4)pixels.set([90,100,110,199],i);
const mark={id:'test',kind:'redeye',x:.25,y:.3,radius:.06,feather:.5,amount:.8,sourceX:.7,sourceY:.6};
const eye=(Math.floor(.3*h)*w+Math.floor(.25*w))*4;pixels.set([235,40,35,199],eye);
const original=pixels.slice(),fixed=retouchPixels(pixels,w,h,[mark]);assert(fixed[eye]<100);assert.deepEqual(pixels,original);assert.equal(fixed[eye+3],199);assert.deepEqual(fixed.subarray(0,4),original.subarray(0,4));
assert.equal(cloneRetouchMarks([{...mark,radius:NaN}]).length,0);
const heal={...mark,kind:'heal'};const bounds=retouchReadBounds([heal],[10,10,40,40],w,h);assert(bounds[2]>heal.sourceX*w&&bounds[3]>heal.sourceY*h);
const tw=bounds[2]-bounds[0],th=bounds[3]-bounds[1],tile=new Uint8ClampedArray(tw*th*4);for(let y=0;y<th;y++)tile.set(pixels.subarray(((y+bounds[1])*w+bounds[0])*4,((y+bounds[1])*w+bounds[2])*4),y*tw*4);
// The viewport layout is the one ImageProcessor.regionSnapshot publishes and
// WorkerCore reads: [originX, originY, fullPixelsPerBufferPixelX,
// fullPixelsPerBufferPixelY, fullWidth, fullHeight]. This tile is a 1:1 copy of
// the region, so its pixel step is 1 鈥?the previous `tw/w` value described the
// region's fraction of the full frame, which no caller ever produces.
const whole=retouchPixels(pixels,w,h,[heal]),part=retouchPixels(tile,tw,th,[heal],[bounds[0],bounds[1],1,1,w,h]);
for(let y=12;y<38;y++)for(let x=12;x<38;x++)for(let k=0;k<4;k++)assert(Math.abs(whole[(y*w+x)*4+k]-part[((y-bounds[1])*tw+x-bounds[0])*4+k])<=1,'healed zoom must match the full frame');
const H=load(root+'/edit/engine/HistogramPresentation.ets');
const r=new Uint32Array(256),g=new Uint32Array(256),blueBins=new Uint32Array(256),l=new Uint32Array(256);
r[100]=500;g[100]=250;blueBins[100]=100;l[100]=300;r[0]=10000;
const plot=H.histogramPlot(r,g,blueBins,l);
assert.equal(plot.red[100],100);assert.equal(plot.green[100],50);assert.equal(plot.blue[100],20);
assert.equal(plot.red[0],10000/3);assert.equal(plot.peak,2000);
assert.equal(H.histogramHeight(500,2000),.5,'square-root plot must retain low-frequency detail');
assert(!plot.monochrome);assert(H.histogramPlot(g,g,g,g).monochrome);
assert.equal(H.histogramPlot(new Uint32Array(256),new Uint32Array(256),new Uint32Array(256),new Uint32Array(256)).peak,1);
for(const [x,key] of [[0,'blacks'],[25,'shadows'],[50,'exposure'],[75,'highlights'],[100,'whites']]){
 assert.equal(H.histogramToneKey(H.histogramToneIndex(x,100)),key);
}
assert.equal(H.histogramToneIndex(NaN,100),-1);
assert(Math.abs(H.histogramDragValue(.1,10,100)-.3)<1e-12);
assert.equal(H.histogramDragValue(.8,100,100),1);
assert.equal(H.histogramDragValue(-.8,-100,100),-1);
assert.equal(H.histogramDragValue(.25,NaN,100),.25);
console.log('PASS mask hierarchy/order/selection/inversion, independent copy-and-invert/atomic undo, sidecar, Lightcraft brush flow/density, CPU/GPU-alpha parity, retouch ROI parity, histogram shared scale/neutral detection/tone-region drag');
