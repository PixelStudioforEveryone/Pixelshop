// Actual ArkTS models and raster/filter cores; deterministic synthetic data only.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),cache=new Map(),storage=new Map();let canceled=false,noiseTasks=0;
function load(file){
 file=path.resolve(file);if(cache.has(file))return cache.get(file).exports;
 const mod={exports:{}};cache.set(file,mod);
 const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText;
 vm.runInNewContext(js,{exports:mod.exports,module:mod,console,Math,Number,Date,Map,Set,Promise,ArrayBuffer,Uint8Array,Uint8ClampedArray,Uint32Array,Float32Array,setTimeout,clearTimeout,Observed:c=>c,Concurrent:f=>f,
 AppStorage:{get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)},require:name=>{
  if(name==='libvivid_gpu.so')return {default:{renderStack:async()=>new ArrayBuffer(0)}};
  if(name==='@kit.ArkTS')return {taskpool:{Task:class{static isCanceled(){return canceled;}constructor(fn,...args){this.fn=fn;this.args=args;}},execute:async t=>{if(t.fn.name==='denoiseTask')noiseTasks++;return t.fn(...t.args);}}};
  if(name.startsWith('@kit.'))return {hilog:{info(){}}};
  if(name==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
      if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file),name+'.ets'));
 }},{filename:file});return mod.exports;
}
const {denoiseRows,denoiseEnabled}=load(root+'/edit/engine/NoiseReduction.ets');
const {DenoiseSettings}=load(root+'/edit/models/DenoiseSettings.ets');
const {EditSession}=load(root+'/edit/models/EditSession.ets');
const {MaskLayer,MaskComponent,MaskComponentType,MaskBlendMode,BrushStroke,BrushPoint}=load(root+'/edit/models/Mask.ets');
const {MaskRenderer}=load(root+'/edit/engine/MaskRenderer.ets');
const {ImageProcessor:P}=load(root+'/edit/engine/ImageProcessor.ets');
const {GpuShaderBridge:G}=load(root+'/edit/engine/GpuShaderBridge.ets');
const {rasterizeStructuredMaskCore}=load(root+'/edit/engine/MaskRasterCore.ets');
const settings={luminance:1,color:1,detail:0,colorDetail:0};
const w=80,h=64,src=new Uint8ClampedArray(w*h*4);let seed=11;
function rnd(){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;}
for(let y=0;y<h;y++)for(let x=0;x<w;x++){
 const noise=Math.round((rnd()-.5)*18),v=(x<w/2?70:190)+noise;
 src.set([v,v,v,100+(x%155)],(y*w+x)*4);
}
const out=new Uint8ClampedArray(src.length);denoiseRows(src,out,w,h,settings,0,h);
function variance(bytes,left,right){let n=0,sum=0,square=0;for(let y=4;y<h-4;y++)for(let x=left;x<right;x++){
 const v=bytes[(y*w+x)*4];n++;sum+=v;square+=v*v;}return square/n-(sum/n)**2;}
assert(variance(out,4,34)<variance(src,4,34)*.8,'must suppress luminance noise');
let low=0,high=0;for(let y=0;y<h;y++){low+=out[(y*w+39)*4];high+=out[(y*w+40)*4];}
assert((high-low)/h>105,'must preserve a strong edge');
for(let i=3;i<src.length;i+=4)assert.equal(src[i],out[i],'alpha must survive');
const bands=new Uint8ClampedArray(src.length);
for(let y=0;y<h;y+=7)denoiseRows(src,bands,w,h,settings,y,Math.min(h,y+7));
assert.deepEqual(bands,out,'band boundaries must not add seams');
assert(!denoiseEnabled(new DenoiseSettings()));
// Identity at strength 0. A zero-strength setting must copy the source through
// untouched, otherwise "denoise off" would still soften or tint the frame.
const zeroOut=new Uint8ClampedArray(src.length);
denoiseRows(src,zeroOut,w,h,{luminance:0,color:0,detail:0,colorDetail:0},0,h);
assert.deepEqual(Buffer.from(zeroOut),Buffer.from(src),'zero-strength denoise must be an exact identity');
// A luminance-only pass preserves Cb/Cr and rebuilds RGB from the denoised
// luma, so every RGB channel legitimately shifts by the luma delta. The real
// invariant is that the chroma difference itself is untouched: if colour
// denoising leaked into a luminance-only pass, Cb/Cr would be smoothed too.
const lumOnly=new Uint8ClampedArray(src.length);
denoiseRows(src,lumOnly,w,h,{luminance:1,color:0,detail:0,colorDetail:0},0,h);
const luma=b=>0.299*b[0]+0.587*b[1]+0.114*b[2];
let maxCb=0,maxCr=0;
for(let i=0;i<src.length;i+=4){
 const yIn=luma([src[i],src[i+1],src[i+2]]),yOut=luma([lumOnly[i],lumOnly[i+1],lumOnly[i+2]]);
 maxCb=Math.max(maxCb,Math.abs((lumOnly[i+2]-yOut)-(src[i+2]-yIn)));
 maxCr=Math.max(maxCr,Math.abs((lumOnly[i]-yOut)-(src[i]-yIn)));
}
assert(maxCb<=2&&maxCr<=2,'luminance-only pass must preserve chroma, dCb='+maxCb+' dCr='+maxCr);
const detailOut=new Uint8ClampedArray(src.length);denoiseRows(src,detailOut,w,h,{...settings,detail:1},0,h);
assert(variance(detailOut,4,34)>variance(out,4,34),'detail must retain more texture');
const color=src.slice();for(let i=0;i<color.length;i+=4){color[i]=128+Math.round((rnd()-.5)*36);color[i+1]=128;color[i+2]=128-Math.round((rnd()-.5)*36);}
const colorOut=new Uint8ClampedArray(color.length);denoiseRows(color,colorOut,w,h,{...settings,luminance:0},0,h);
function chromaEnergy(b){let s=0;for(let i=0;i<b.length;i+=4)s+=(b[i]-b[i+1])**2+(b[i+2]-b[i+1])**2;return s/b.length;}
assert(chromaEnergy(colorOut)<chromaEnergy(color)*.5,'must suppress coloured speckles');
const flat=new Uint8ClampedArray(src.length);for(let i=0;i<flat.length;i+=4)flat.set([70,120,180,222],i);
const flatOut=flat.slice();denoiseRows(flat,flatOut,w,h,settings,0,h);assert.deepEqual(flatOut,flat,'flat colours must not shift');
assert.throws(()=>denoiseRows(src,src,w,h,settings,0,h),/immutable/);
canceled=true;assert.throws(()=>denoiseRows(src,out,w,h,settings,0,h,true),/CANCELLED/);canceled=false;

for(const type of [MaskComponentType.LINEAR_GRADIENT,MaskComponentType.RADIAL_GRADIENT,MaskComponentType.BRUSH]){
 for(const version of [1,2])for(const op of [MaskBlendMode.ADD,MaskBlendMode.SUBTRACT,MaskBlendMode.INTERSECT]){
  const m=new MaskLayer('mask');m.opacity=.65;m.inverted=true;
  const c=new MaskComponent(type);c.renderingVersion=version;c.opacity=.8;c.feather=.35;c.blendMode=op;c.inverted=true;
  if(type===MaskComponentType.BRUSH){const stroke=new BrushStroke();stroke.mode=2;const point=new BrushPoint();point.x=.5;point.y=.5;point.radius=.3;stroke.points=[point];c.brushData.strokes=[stroke];}
  m.components=[new MaskComponent(MaskComponentType.LINEAR_GRADIENT),c];
  // rasterizeStructuredMaskCore 现在返回 MaskRasterOutput {alpha, stats}，不再是裸 ArrayBuffer。
  // 直接把它塞进 Uint8ClampedArray 会得到长度 0 的数组（对象没有 length），从而误报
  // "UI/worker 不一致"。生产侧三处调用点（ImageProcessor:384、MaskRenderer:40、
  // MaskRasterWorker:18）都正确取了 .alpha，所以这里只是套件过期。
  const ui=MaskRenderer.renderMaskLayer(m,w,h),worker=new Uint8ClampedArray(rasterizeStructuredMaskCore(P.plainMaskLayer(m),w,h).alpha);
  assert.deepEqual(ui,worker,`UI/worker mask ${type}/${version}/${op}`);
 }
}
const brush=new MaskComponent(MaskComponentType.BRUSH),stroke=new BrushStroke(),point=new BrushPoint();
stroke.mode=2;point.x=.5;point.y=.5;point.radius=.25;stroke.points=[point];brush.brushData.strokes=[stroke];
assert(MaskRenderer.renderComponent(brush,w,h).some(v=>v>0),'first intersect stroke must seed selection');
const s=new EditSession();s.ensureBaseLayer();s.denoise=DenoiseSettings.restore(settings);
const m=new MaskLayer('saved');m.inverted=true;m.components=[new MaskComponent(MaskComponentType.LINEAR_GRADIENT)];s.layers[0].maskLayers=[m];
const saved=s.exportAdjustmentState(),restored=new EditSession();assert(restored.importAdjustmentState(saved));
assert.equal(restored.denoise.color,1);assert(restored.layers[0].maskLayers[0].inverted);
assert.equal(restored.layers[0].maskLayers[0].components[0].renderingVersion,3);
const old=JSON.parse(saved);delete old.denoise;delete old.layers[0].maskLayers[0].inverted;delete old.layers[0].maskLayers[0].components[0].renderingVersion;
assert(restored.importAdjustmentState(JSON.stringify(old)));assert(!denoiseEnabled(restored.denoise));
assert.equal(restored.layers[0].maskLayers[0].components[0].renderingVersion,1);
s.pushUndo();s.denoise.luminance=.25;s.undo();assert.equal(s.denoise.luminance,1);s.redo();assert.equal(s.denoise.luminance,.25);
const snap=P.snapshot(s);s.denoise.color=.2;assert.equal(snap.denoise.color,1,'snapshot must be immutable');

// Stable curves/mask/LUT assets keep native IDs across ordinary slider edits.
const a=G.buildPasses(s,w,h,true,true);s.layers[0].adjustments.exposure=.3;const b=G.buildPasses(s,w,h,true,true);
assert.equal(a[0].toneCurveId,b[0].toneCurveId);
assert.equal(a.at(-1).maskId,b.at(-1).maskId);
s.invalidateMaskCache();const c=G.buildPasses(s,w,h,true,true);assert.notEqual(c.at(-1).maskId,b.at(-1).maskId);
const model=DenoiseSettings.restore({luminance:NaN,color:4,detail:-1,colorDetail:Infinity});assert.equal(model.luminance,0);assert.equal(model.color,1);assert.equal(model.detail,0);assert.equal(model.colorDetail,.5);
console.log(JSON.stringify({luminanceVarianceBefore:variance(src,4,34),luminanceVarianceAfter:variance(out,4,34),edgeDifference:(high-low)/h,chromaBefore:chromaEnergy(color),chromaAfter:chromaEnergy(colorOut)}));
// A merged inspector must not let layer-row selection redirect local edits.
const contextSession=new EditSession();contextSession.ensureBaseLayer();
contextSession.createMaskLayer(MaskComponentType.LINEAR_GRADIENT);
const local=contextSession.activeMaskLayer.adjustments,global=contextSession.layers[0].adjustments;
local.exposure=.7;global.exposure=.2;contextSession.adjustmentScope=0;
contextSession.adjustmentsForContext(true).exposure=.8;
assert.equal(global.exposure,.2);assert.equal(local.exposure,.8);
local.toneCurve=.6;global.toneCurve=.3;
const curveText=fs.readFileSync(root+'/components/ToneCurveControl.ets','utf8');
const resetBody=curveText.match(/private resetCurves\(\): void \{([\s\S]*?)\n  \}/)[1];
const {ColorAdjustments}=load(root+'/edit/models/Adjustment.ets');
vm.runInNewContext('(function(){'+resetBody+'})',{ColorAdjustments}).call({
 editSession:contextSession,maskContext:true,selectedPoint:0,curveRevision:0,drawCurve(){},scheduleProcess(){}
});
assert.equal(local.toneCurve,0,'local curve reset must affect selected mask');
assert.equal(global.toneCurve,.3,'local curve reset must preserve global curve');
contextSession.layers[0].maskLayers=[];
assert.equal(contextSession.adjustmentsForContext(true),null,'missing mask must not silently write globally');
console.log('PASS denoise suppression/detail/edges/alpha/bands/cancellation, mask parity, sidecar/undo compatibility, asset revisions and merged local/global control isolation');
async function cacheRegression(){
 const session=new EditSession();session.ensureBaseLayer();session.denoise=DenoiseSettings.restore(settings);
 const pixelMap={readPixelsToBuffer:async b=>new Uint8Array(b).set(src)};
 const render=pm=>P.renderToBuffer(pm,w,h,session,true,()=>false,true,src.buffer,true);
 noiseTasks=0;await render(pixelMap);assert.equal(noiseTasks,1);
 session.layers[0].adjustments.exposure=.25;await render(pixelMap);assert.equal(noiseTasks,1,'post-colour edit must reuse denoise');
 session.denoise.detail=.8;await render(pixelMap);assert.equal(noiseTasks,2,'detail setting must invalidate stage');
 await render({...pixelMap});assert.equal(noiseTasks,3,'new decoded source must invalidate stage');
 P.clearSourceCache(session);await render(pixelMap);assert.equal(noiseTasks,4,'closing session must release stage');
 // Halo filter must match the corresponding interior of the full frame.
 const x=20,y=14,tw=30,th=25,halo=2,tile=new Uint8ClampedArray((tw+4)*(th+4)*4);
 for(let j=0;j<th+4;j++)tile.set(src.subarray(((y+j-halo)*w+x-halo)*4,((y+j-halo)*w+x+tw+halo)*4),j*(tw+4)*4);
 const filtered=tile.slice();denoiseRows(tile,filtered,tw+4,th+4,settings,0,th+4);
 for(let j=0;j<th;j++)for(let i=0;i<tw*4;i++)assert.equal(filtered[((j+2)*(tw+4)+2)*4+i],out[((y+j)*w+x)*4+i]);
 console.log('PASS CPU stage dependency reuse/invalidation/session cleanup and full-frame/halo tile parity');
}
cacheRegression().catch(error=>{console.error(error);process.exitCode=1;});
