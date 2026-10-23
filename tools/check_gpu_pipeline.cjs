const fs = require('fs'), vm = require('vm'), path = require('path'), assert = require('assert');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets'), modules = new Map(), storage = new Map();
let rawDecodes = 0, dcpRuns = 0;
const taskpool = {
  Task: class { static isCanceled(){return false;} constructor(fn, ...args) { this.fn = fn; this.args = args; } },
  execute: async task => {
    if (task.fn.name === 'processDcp') { dcpRuns++; return new Uint8Array(16).buffer; }
    return task.fn(...task.args);
  }
};
const nativeRaw = { decodeRw2: async () => {
  rawDecodes++;
  return {linearPixels:new Float32Array(12).buffer,pixels:new ArrayBuffer(0),width:2,height:2,sourceWidth:2,sourceHeight:2,
    cameraNeutral:[1,1,1],camToSrgb:[1,0,0,0,1,0,0,0,1],model:'fixture',blackLevel:0,whiteLevel:1,bitDepth:14,linearCameraRgb:1,dcpApplied:0,
    status:0,message:'',diagnostics:''};
}};
function load(file) {
  file = path.resolve(file); if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} }; modules.set(file,module);
  const source = fs.readFileSync(file,'utf8');
  const js = ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText;
  const context = { module, exports:module.exports, console, Math, Date, setTimeout, clearTimeout,
    // renderToBuffer() arms a cancel poll with setInterval and clears it in a
    // `finally`. Without these two globals that `finally` throws a ReferenceError,
    // which the taskpool catch turns into `{}` — and a region job may not fall back,
    // so the tile render returned null instead of pixels.
    setInterval:(fn,ms)=>setInterval(fn,ms), clearInterval:(h)=>clearInterval(h),
    ArrayBuffer,Uint8Array,Uint8ClampedArray,Uint32Array,Float32Array,Map,Set,Promise,
    Observed: c=>c, Concurrent:f=>f,
    AppStorage:{ get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v) },
    require:name=> {
      if(name==='@kit.ArkTS')return {taskpool};
      if(name.startsWith('@kit.'))return {hilog:{info(){}}};
      if(name==='libvivid_raw.so')return {default:nativeRaw};
      if(name==='libvivid_gpu.so')return {default:{releaseSession:async()=>new ArrayBuffer(0)}};
      if(name==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
      // Mask rasterisation goes through the native pixels module. With only a generic
      // `{}` here, `rasterizeLinear` threw and the mask path returned null, which is
      // why a masked region render came back as null.pixels. These stubs return
      // correctly sized planes so the composed masks stay consistent between the
      // full-frame and region renders that this suite compares.
      if(name==='libvivid_pixels.so')return {default:{
        rasterizeLinear:(w,h)=>new ArrayBuffer(w*h),
        rasterizeRadial:(w,h)=>new ArrayBuffer(w*h),
        rasterizeBrushStroke:(w,h)=>new ArrayBuffer(w*h),
        remapGeometry:(buf,w,h)=>new ArrayBuffer(w*h*4),
        composeInto(){}, invertOpacity(){}, sampleBitmap(){},
      }};
      if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file),name+'.ets'));
    }
  };
  vm.runInNewContext(js,context,{filename:file}); return module.exports;
}
const {ImageProcessor:P}=load(root+'/edit/engine/ImageProcessor.ets');
const {EditSession}=load(root+'/edit/models/EditSession.ets');
const {Layer}=load(root+'/edit/models/Layer.ets');
const {MaskLayer,MaskComponent,MaskComponentType}=load(root+'/edit/models/Mask.ets');
const {sampleBgraBand}=load(root+'/edit/utils/RegionPixels.ets');
const {RawNativeBridge}=load(root+'/edit/utils/RawNativeBridge.ets');
const {classicDcp}=load(root+'/edit/engine/DcpCpu.ets');
function source(bytes) { return {readPixelsToBuffer:async buffer=>new Uint8Array(buffer).set(bytes)}; }
async function main() {
  const w=80,h=60,pixels=new Uint8Array(w*h*4);
  for(let y=0;y<h;y++)for(let x=0;x<w;x++)pixels.set([50+x,40+y,80,255],(y*w+x)*4);
  const session=new EditSession();session.layers=[new Layer('base')];
  const base=await P.renderToBuffer(source(pixels),w,h,session,true,()=>false);
  assert.deepStrictEqual(Buffer.from(base.pixels),Buffer.from(pixels),'identity');
  const upper=new Layer('upper');session.layers[0].adjustments.exposure=.3;upper.adjustments.exposure=.3;session.layers.push(upper);
  const stacked=await P.renderToBuffer(source(pixels),w,h,session,true,()=>false);
  assert(stacked.pixels[0]>70,'second layer must consume first layer output');
  const lutValues=[];
  for(let b=0;b<2;b++)for(let g=0;g<2;g++)for(let r=0;r<2;r++)
    lutValues.push(1-r,1-g,1-b);
  session.layers=[new Layer('lut')];
  session.lutStack=[{id:'lut-test',lutId:'lut-test',name:'invert',sourceUri:'test://invert',enabled:true,intensity:1,
    lut:{id:'lut-test',name:'invert',sourceUri:'test://invert',sampleCount:8,adjustments:{},
      table:{size:2,values:lutValues,domainMin:[0,0,0],domainMax:[1,1,1]}}}];
  const lutResult=await P.renderToBuffer(source(pixels),w,h,session,true,()=>false);
  assert(lutResult.pixels[0]>180 && lutResult.pixels[1]>190 && lutResult.pixels[2]>160,'LUT stack must alter rendered pixels');
  // The zoom/detail path must render the sampled source through the same
  // graded session.  Comparing a graded ROI with the matching full frame
  // catches the old regression where the detail tile was built from the raw
  // source and therefore lost the LUT (and other adjustments).
  const detailX=20, detailY=15, detailW=40, detailH=30;
  const detailSource=new Uint8Array(detailW*detailH*4);
  for(let row=0;row<detailH;row++) detailSource.set(
    pixels.subarray(((detailY+row)*w+detailX)*4,((detailY+row)*w+detailX+detailW)*4), row*detailW*4);
  const gradedFull=lutResult;
  const gradedRegion=P.regionSnapshot(session,detailX,detailY,detailW,detailH,w,h,detailW,detailH);
  const gradedTile=await P.renderToBuffer(source(detailSource),detailW,detailH,gradedRegion,true,()=>false);
  let gradedMax=0;
  for(let row=0;row<detailH;row++)for(let col=0;col<detailW*4;col++) gradedMax=Math.max(
    gradedMax,Math.abs(gradedTile.pixels[row*detailW*4+col]-gradedFull.pixels[((detailY+row)*w+detailX)*4+col]));
  assert(gradedMax<=1,'detail tile must retain LUT grading max='+gradedMax);
  session.layers=[new Layer('masked')];
  const mask=new MaskLayer('gradient');mask.components=[new MaskComponent(MaskComponentType.LINEAR_GRADIENT)];
  mask.adjustments.exposure=.6;mask.opacity=.5;session.layers[0].maskLayers=[mask];
  session.layers[0].adjustments.vignetteAmount=-.25;
  const full=await P.renderToBuffer(source(pixels),w,h,session,true,()=>false);
  const cached=Array.from(session.maskCache.values())[0];
  await P.renderToBuffer(source(pixels),w,h,session,true,()=>false);
  assert.strictEqual(Array.from(session.maskCache.values())[0],cached,'mask cache persists across parameter snapshots');
  const x=20,y=15,rw=40,rh=30,tile=new Uint8Array(rw*rh*4);
  for(let row=0;row<rh;row++)tile.set(pixels.subarray(((y+row)*w+x)*4,((y+row)*w+x+rw)*4),row*rw*4);
  const region=P.regionSnapshot(session,x,y,rw,rh,w,h,rw,rh);
  const local=await P.renderToBuffer(source(tile),rw,rh,region,true,()=>false);
  let max=0;
  for(let row=0;row<rh;row++)for(let col=0;col<rw*4;col++)max=Math.max(max,Math.abs(local.pixels[row*rw*4+col]-full.pixels[((y+row)*w+x)*4+col]));
  assert(max<=1,'region mask/spatial parity max='+max);
  session.geometry[0]=20;assert(!P.isRegionRenderSafe(session),'geometry must decline unwarped ROI');
  const bgra=new Uint8Array([3,2,1,255,6,5,4,255]);
  assert.deepStrictEqual(Buffer.from(sampleBgraBand(bgra.buffer,2,0,1,2,0,1,1,1)),Buffer.from([1,2,3,255,4,5,6,255]),'BGRA region channels');
  const profile=classicDcp([1,0,0,0,1,0,0,0,1]);
  await RawNativeBridge.decodeRw2(new ArrayBuffer(1),512,profile,0,0,'file:1');
  await RawNativeBridge.decodeRw2(new ArrayBuffer(1),512,profile,0,0,'file:1');
  assert.strictEqual(rawDecodes,1);assert.strictEqual(dcpRuns,1);
  await RawNativeBridge.decodeRw2(new ArrayBuffer(1),512,profile,6000,0,'file:1');
  assert.strictEqual(rawDecodes,1);assert.strictEqual(dcpRuns,2);
  await RawNativeBridge.reprocessPreview('file:1',profile,6500,0);
  assert.strictEqual(rawDecodes,1,'DCP switch must reuse resident RAW dimensions');
  assert.strictEqual(dcpRuns,3);
  await RawNativeBridge.decodeRw2(new ArrayBuffer(1),512,profile,6000,0,'file:2');
  assert.strictEqual(rawDecodes,2,'source replacement invalidates RAW cache');
  assert.strictEqual(await RawNativeBridge.reprocessPreview('file:1',profile,6500,0),null,'another image cannot consume cached RAW');
  console.log('PASS identity, sequential layers, LUT application, mask cache, region+spatial parity, geometry guard, BGRA, RAW/DCP dependencies');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
