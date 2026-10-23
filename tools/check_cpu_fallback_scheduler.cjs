// Exercise the real scheduler/worker, including a delayed CPU refinement.
// Synthetic pixels only; no device image, credentials or DCP data are read.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),cache=new Map(),storage=new Map();
const tasks=[],wait=ms=>new Promise(r=>setTimeout(r,ms));let cancellations=0,checks=0,cancelAfter=Infinity;
class TestTask {
 constructor(fn,...args){this.fn=fn;this.args=args;this.cancelled=false;}
 static isCanceled(){return ++checks>=cancelAfter;}
}
const taskpool={Task:TestTask,cancel:t=>{t.cancelled=true;cancellations++;t.reject?.(new Error('canceled'));},
 execute:async t=>{
  if(t.fn.name==='processPixels'){
   tasks.push(t);
   if(t.args[0].width>512)return new Promise((resolve,reject)=>{t.reject=reject;t.resolve=()=>resolve(t.fn(...t.args));});
  }
  return t.fn(...t.args);
 }};
const image={PixelMapFormat:{RGBA_8888:1},createPixelMap:async(bytes,opts)=>({pixels:new Uint8Array(bytes),size:opts.size,
 writeBufferToPixels:async function(b){this.pixels.set(new Uint8Array(b));},release(){this.released=true;}})};
function load(file){
 file=path.resolve(file);if(cache.has(file))return cache.get(file).exports;
 const mod={exports:{}};cache.set(file,mod);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,
  target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText,
 {exports:mod.exports,module:mod,console:{info(){},warn(){},error:console.error},Math,Date,Number,Map,Set,Promise,ArrayBuffer,
 Uint8Array,Uint8ClampedArray,Uint32Array,Float32Array,setTimeout,clearTimeout,Observed:c=>c,Concurrent:f=>f,
 AppStorage:{get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)},require:name=>{
  if(name==='@kit.ArkTS')return {taskpool};if(name==='@kit.ImageKit')return {image};
  if(name==='libvivid_gpu.so')return {default:{releaseSession:async()=>{},clearSurface:async()=>{}}};
  if(name.startsWith('@kit.'))return {};
  if(name==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
      if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file),name+'.ets'));
 }},{filename:file});return mod.exports;
}
async function until(check){for(let i=0;i<400;i++){if(check())return;await wait(5);}throw Error('Scheduler timeout');}
async function main(){
 const {EditSession}=load(root+'/edit/models/EditSession.ets'),{Layer}=load(root+'/edit/models/Layer.ets');
 const {ImageProcessor:P}=load(root+'/edit/engine/ImageProcessor.ets'),{GpuShaderBridge:G}=load(root+'/edit/engine/GpuShaderBridge.ets');
 G.gpuDisabledUntil=Infinity;
 const s=new EditSession();s.layers=[new Layer('synthetic')];s.imageWidth=1024;s.imageHeight=640;
 s.layers[0].adjustments.exposure=.2;s.sourcePixelMap={readPixelsToBuffer:async b=>new Uint8Array(b).fill(128)};
 let published=0;s.onPreviewUpdated=()=>published++;
 await P.process(s);assert.strictEqual(s.previewWidth,512,'first CPU frame must be bounded');
 await until(()=>tasks.some(t=>t.args[0].width===1024));const refinement=tasks.find(t=>t.args[0].width===1024);
 const oldPreview=s.previewPixelMap;s.layers[0].adjustments.exposure=.7;s.requestProcessing();P.process(s);
 await until(()=>s.previewPixelMap!==oldPreview);
 assert(refinement.cancelled,'new drag must interrupt the settled CPU refinement');assert.strictEqual(cancellations,1);
 assert.strictEqual(s.previewWidth,512);assert.strictEqual(tasks.filter(t=>t.args[0].width===512).at(-1).args[0].layers[0].adjustments.exposure,.7);
 const lastTasks=tasks.length;
 await until(()=>tasks.length>lastTasks&&tasks.at(-1).args[0].width===1024);
 const finalRefinement=tasks.at(-1);P.clearSourceCache(s);await wait(20);
 assert(finalRefinement.cancelled,'source replacement/close must cancel its CPU worker');assert.strictEqual(published,2,'canceled refinements must not publish or fall back on UI');
 // Real worker cancellation checkpoints: stop after one 32K-pixel band.
 const {processPixels}=load(root+'/edit/engine/ProcessWorker.ets');
 const params=tasks[0].args[0];checks=0;cancelAfter=3;
 assert.throws(()=>processPixels(params),/CPU_PREVIEW_CANCELLED/);cancelAfter=Infinity;
 console.log('PASS first 512px CPU frame, latest-value publication, cancelable full refinement, source cancellation, worker checkpoints, no main-thread retry');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
