// Real scheduler with delayed native completion and two proxies of one session.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),cache=new Map(),storage=new Map();
let clockOffset=0,active=0,maxActive=0,reads=0,clears=0;
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
class TestDate extends Date { static now(){return Date.now()+clockOffset;} }
const calls=[],pending=[];
const image={PixelMapFormat:{RGBA_8888:1},createPixelMap:async(buffer,opts)=>({
 pixels:new Uint8Array(buffer),size:opts.size,released:false,
 writeBufferToPixels:async function(bytes){this.pixels.set(new Uint8Array(bytes));},
 readPixelsToBuffer:async function(bytes){new Uint8Array(bytes).set(this.pixels);},
 release(){this.released=true;}
})};
const native={releaseSession:async()=>new ArrayBuffer(0),clearSurface:async()=>{clears++;return new ArrayBuffer(0);},
 renderStack:async(key,surface,source,w,h,version,passes,geometry)=>{
   if(!surface)return new ArrayBuffer((geometry?.width??w)*(geometry?.height??h)*4);
   const call={key,w,h,uploaded:source!==null,geometry,passes};calls.push(call);
   active++;maxActive=Math.max(maxActive,active);
   await new Promise(resolve=>pending.push(resolve));active--;
   return new ArrayBuffer(0);
 }};
function load(file){
 file=path.resolve(file);if(cache.has(file))return cache.get(file).exports;
 const mod={exports:{}};cache.set(file,mod);
 const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText;
 const ctx={exports:mod.exports,module:mod,console:{info(){},warn(){},error:console.error},Math,Number,Date:TestDate,
 Map,Set,Promise,ArrayBuffer,Uint8Array,Uint8ClampedArray,Uint32Array,Float32Array,setTimeout,clearTimeout,
 Observed:c=>c,Concurrent:f=>f,AppStorage:{get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)},
 require:name=>{
  if(name==='libvivid_gpu.so')return {default:native};
  if(name==='@kit.ImageKit')return {image};
  if(name==='@kit.ArkTS')return {taskpool:{Task:class{static isCanceled(){return false;}constructor(fn,...args){this.fn=fn;this.args=args;}},execute:async t=>t.fn(...t.args)}};
  if(name.startsWith('@kit.'))return {hilog:{info(){}}};
  if(name==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
      if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file),name+'.ets'));
 }};
 vm.runInNewContext(js,ctx,{filename:file});return mod.exports;
}
const {EditSession}=load(root+'/edit/models/EditSession.ets'),{Layer}=load(root+'/edit/models/Layer.ets');
const {ImageProcessor:P}=load(root+'/edit/engine/ImageProcessor.ets');
const {GpuShaderBridge:G}=load(root+'/edit/engine/GpuShaderBridge.ets');
async function until(test){for(let i=0;i<200;i++){if(test())return;await wait(5);}throw Error('Timed out waiting for scheduler');}
async function main(){
 const s=new EditSession();s.layers=[new Layer('test')];s.imageWidth=1024;s.imageHeight=768;s.rotation=90;s.gpuSurfaceId='fixture';
 s.sourcePixelMap={readPixelsToBuffer:async b=>{reads++;new Uint8Array(b).fill(128);}};
 const a=new Proxy(s,{}),b=new Proxy(s,{}),published=[];
 s.onPreviewUpdated=()=>published.push(s.layers[0].adjustments.exposure);
 const first=P.process(a);await until(()=>calls.length===1);
 assert.strictEqual(calls[0].w,1024);assert.strictEqual(calls[0].geometry.width,768);
 s.layers[0].adjustments.exposure=.3;s.requestProcessing();const version=s.processingRequestVersion;
 P.process(b);s.layers[0].adjustments.exposure=.7;s.requestProcessing();P.process(a);
 clockOffset=1000;pending.shift()();await first;await until(()=>calls.length===2);
 assert.strictEqual(maxActive,1,'different component proxies must share one in-flight task');
 assert.strictEqual(calls[1].w,512,'queued drag must retain interactive intent after 160ms');
 assert.strictEqual(calls[1].key,calls[0].key,'native session key must be shared across proxies');
 assert.strictEqual(s.processingRequestVersion,version+1,'starting a render must not mutate user parameter version');
 assert.strictEqual(published.length,1,'completed earlier same-image frame must remain publishable');
 pending.shift()();await until(()=>calls.length===3);
 assert.strictEqual(calls[2].w,1024,'one settled refinement must restore resolution');
 pending.shift()();await until(()=>published.length===3);await wait(300);
 assert.strictEqual(calls.length,3,'no parameter change must mean no perpetual refinement loop');
 assert.strictEqual(reads,1,'proxy entry points must share the source RGBA cache');
 assert.strictEqual(published.at(-1),.7,'latest queued value must reach the display');
 // Parameters/rotation change at the same resolution, not the resident source.
 s.rotation=270;const fourth=P.process(b);await until(()=>calls.length===4);
 assert.strictEqual(calls[3].uploaded,false,'quarter-turn changes must not re-upload the source');
 pending.shift()();await fourth;
 // Hold-before must keep crop/rotation and the resident source, with no
 // grading passes and no black clear. Release restores the edited pipeline.
 s.cropLeft=.1;s.cropTop=.15;s.cropRight=.9;s.cropBottom=.85;
 const crop=P.process(a);await until(()=>calls.length===5);pending.shift()();await crop;
 const edited=calls.at(-1),preview=s.previewPixelMap;
 assert.ok(edited.passes.length>0,'fixture must have a real exposure edit');
 const held=P.setBeforePreview(b,true);await until(()=>calls.length===6);
 const original=calls.at(-1);
 assert.strictEqual(original.passes.length,0,'before must disable LUTs, masks and colour edits');
 assert.strictEqual(original.uploaded,false,'compare must reuse the resident texture');
 assert.deepStrictEqual(Array.from(new Float32Array(original.geometry.uvMatrix)),
   Array.from(new Float32Array(edited.geometry.uvMatrix)),'before and edited must use identical crop/rotation');
 assert.strictEqual(original.geometry.width,edited.geometry.width);
 assert.strictEqual(original.geometry.height,edited.geometry.height);
 assert.strictEqual(s.gpuPreviewActive,true,'before must not hide the direct surface');
 const released=P.setBeforePreview(a,false); // release while before is still running
 pending.shift()();await held;await released;await until(()=>calls.length===7);
 assert.ok(calls.at(-1).passes.length>0,'quick release must reach the latest edited state');
 assert.strictEqual(calls.at(-1).uploaded,false);
 pending.shift()();await until(()=>published.length===7);
 assert.strictEqual(s.previewPixelMap,preview,'GPU comparison must not replace the CPU preview');
 assert.strictEqual(clears,0,'comparison must never clear the surface');
 assert.strictEqual(maxActive,1,'compare and grading must share the serialized scheduler');
 await wait(260);assert.strictEqual(calls.length,7,'view-mode changes must not trigger an endless refinement');
 // Closing/switching a source invalidates the old completion instead of publishing it.
 const before=published.length;const old=P.process(a);await until(()=>calls.length===8);
 P.clearSourceCache(b);s.sourcePixelMap={readPixelsToBuffer:async()=>{}};
 pending.shift()();await old;assert.strictEqual(published.length,before,'old source generation must not publish');
 // CPU fallback must also retain geometry and keep the graded PixelMap
 // separate from the original, including cache validity after a crop change.
 G.gpuDisabledUntil=Infinity;
 const c=new EditSession();c.layers=[new Layer('cpu')];c.layers[0].adjustments.exposure=.6;
 c.imageWidth=24;c.imageHeight=16;c.rotation=270;c.flipH=true;
 c.cropLeft=.12;c.cropTop=.15;c.cropRight=.85;c.cropBottom=.88;
 const pixels=new Uint8Array(c.imageWidth*c.imageHeight*4);
 for(let i=0;i<pixels.length;i+=4)pixels.set([40+(i%71),60,80,255],i);
 c.sourcePixelMap={readPixelsToBuffer:async b=>new Uint8Array(b).set(pixels)};
 await P.process(c);const cpuEdited=c.previewPixelMap,editedSize=[c.previewWidth,c.previewHeight];
 assert(cpuEdited,'CPU edited preview must be created');
 await P.setBeforePreview(c,true);assert(P.isBeforePreviewReady(c),'CPU geometry key must retain native source dimensions');
 assert.deepStrictEqual([c.previewWidth,c.previewHeight],editedSize,'CPU comparison must preserve display size');
 assert.strictEqual(c.previewPixelMap,cpuEdited,'CPU before must not overwrite the graded frame');
 const neutral=P.snapshot(c);neutral.layers=[];neutral.lutStack=[];
 const expected=await P.renderToBuffer(c.sourcePixelMap,c.imageWidth,c.imageHeight,neutral,true,()=>false,false,pixels.buffer,true);
 assert.deepStrictEqual(Array.from(c.beforePixelMap.pixels),Array.from(expected.pixels),'CPU before must contain ungraded transformed pixels');
 assert.notDeepStrictEqual(Array.from(cpuEdited.pixels),Array.from(c.beforePixelMap.pixels));
 await P.setBeforePreview(c,false);assert(!c.showBefore);
 c.cropLeft=.2;assert.strictEqual(P.isBeforePreviewReady(c),false,'stale crop comparison must not be displayed');
 P.clearSourceCache(c);
 console.log('PASS stable session single-flight, queued interaction, latest value, one refinement, resident texture, transformed before/after, fast compare release, no surface clear, source cancellation');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
