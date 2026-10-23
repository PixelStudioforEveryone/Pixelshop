// Execute the production GpuSession shaders under local EGL; compare the final
// crop/quarter-turn/flip remap (including masks/LUTs) with the forced CPU path.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert'),cp=require('child_process');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),cache=new Map(),storage=new Map();let captured;
function load(file){
 file=path.resolve(file);if(cache.has(file))return cache.get(file).exports;
 const mod={exports:{}};cache.set(file,mod);
 const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText;
 vm.runInNewContext(js,{exports:mod.exports,module:mod,console,Math,Number,Date,Map,Set,Promise,ArrayBuffer,Uint8Array,Uint8ClampedArray,Uint32Array,Float32Array,setTimeout,clearTimeout,Observed:c=>c,Concurrent:f=>f,
 AppStorage:{get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)},require:name=>{
  if(name==='libvivid_gpu.so')return {default:{renderStack:async(...args)=>{captured=args;return new ArrayBuffer(0);}}};
  if(name==='@kit.ArkTS')return {taskpool:{Task:class{static isCanceled(){return false;}constructor(fn,...args){this.fn=fn;this.args=args;}},execute:async t=>t.fn(...t.args)}};
  if(name.startsWith('@kit.'))return {hilog:{info(){}}};
  if(name==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
      if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file),name+'.ets'));
 }},{filename:file});return mod.exports;
}
const {EditSession}=load(root+'/edit/models/EditSession.ets'),{Layer}=load(root+'/edit/models/Layer.ets');
const {MaskLayer,MaskComponent,MaskComponentType}=load(root+'/edit/models/Mask.ets');
const {ImageProcessor:P}=load(root+'/edit/engine/ImageProcessor.ets'),{GpuShaderBridge:G}=load(root+'/edit/engine/GpuShaderBridge.ets');
const dir=path.resolve('tmp/gpu-output-geometry');fs.mkdirSync(dir,{recursive:true});
const cpp=fs.readFileSync('entry/src/main/cpp/vivid_gpu.cpp','utf8'),pipeline=fs.readFileSync('entry/src/main/cpp/vivid_gpu_pipeline.inc','utf8');
function struct(source,name){const start=source.indexOf('struct '+name+' {');return source.slice(start,source.indexOf('\n};',start)+3).replace(/^\s*napi_.*$/gm,'');}
const functions=cpp.slice(cpp.indexOf('static GLuint compileShader'),cpp.indexOf('static void executeRender'));
const implementation=pipeline.slice(pipeline.indexOf('struct CachedTexture {'),pipeline.indexOf('static RenderThread& renderThread()'))
 .replace('EGL_WINDOW_BIT|EGL_PBUFFER_BIT','EGL_PBUFFER_BIT'); // Surfaceless host has no native windows.
const harness=`#include <EGL/egl.h>
#include <GLES2/gl2.h>
// The production file defines these locally; the extracted harness needs them.
#ifndef GL_RGBA16F
#define GL_RGBA16F 0x881A
#endif
#ifndef GL_HALF_FLOAT
#define GL_HALF_FLOAT 0x140B
#endif
#ifndef EGL_OPENGL_ES3_BIT
#define EGL_OPENGL_ES3_BIT 0x00000040
#endif
#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <utility>
#include <vector>
#include <memory>
#include <stdexcept>
#include <fstream>
#include <iostream>
struct OHNativeWindow{};
static int OH_NativeWindow_CreateNativeWindowFromSurfaceId(uint64_t,OHNativeWindow**){return -1;}
static void OH_NativeWindow_DestroyNativeWindow(OHNativeWindow*){}
${struct(cpp,'RenderWork')}
${functions}
${struct(pipeline,'StackWork')}
${implementation}
static uint32_t u32(std::ifstream& f){uint32_t n;f.read((char*)&n,4);return n;}
static void bytes(std::ifstream& f,std::vector<uint8_t>& v){v.resize(u32(f));f.read((char*)v.data(),v.size());}
static void array(std::ifstream& f,float* a,int n){f.read((char*)a,n*4);}
int main(int argc,char** argv){
 if(argc!=3)return 2;std::ifstream f(argv[1],std::ios::binary);StackWork job;
 job.width=u32(f);job.height=u32(f);job.outputWidth=u32(f);job.outputHeight=u32(f);array(f,job.uvMatrix,9);
 job.sourceVersion=1;bytes(f,job.source);job.passes.resize(u32(f));
 for(auto& r:job.passes){
  r.width=job.width;r.height=job.height;
  for(auto* v:{&r.toneCurve,&r.redCurve,&r.greenCurve,&r.blueCurve,&r.lut,&r.mask})bytes(f,*v);
  array(f,r.matrix,20);array(f,r.vignette,5);array(f,r.grain,3);array(f,r.denoise,4);
  array(f,r.mixHue,8);array(f,r.mixSaturation,8);array(f,r.mixLuminance,8);
  array(f,r.tonal,4);array(f,r.whiteBalanceGain,3);array(f,r.lutDomainMin,3);array(f,r.lutDomainScale,3);float exposure;array(f,&exposure,1);r.exposureGain=exposure;array(f,r.calibrationHue,3);array(f,r.calibrationSaturation,3);
  array(f,r.gradingShadowsTarget,3);array(f,r.gradingMidtonesTarget,3);array(f,r.gradingHighlightsTarget,3);array(f,r.gradingGlobalTarget,3);
  float opts[21];array(f,opts,21);
  r.whiteBalanceEnabled=opts[0];r.vibrance=opts[1];r.mixerEnabled=opts[2];r.gradingEnabled=opts[3];
  r.gradingShadowsSaturation=opts[4];r.gradingShadowsLuminance=opts[5];r.gradingMidtonesSaturation=opts[6];r.gradingMidtonesLuminance=opts[7];
  r.gradingHighlightsSaturation=opts[8];r.gradingHighlightsLuminance=opts[9];r.gradingGlobalSaturation=opts[10];r.gradingGlobalLuminance=opts[11];
  r.gradingBlending=opts[12];r.gradingBalance=opts[13];r.opacity=opts[14];r.blendMode=opts[15];r.maskEnabled=opts[16];
  r.maskOpacity=opts[17];r.lutEnabled=opts[18];r.lutSize=opts[19];r.lutIntensity=opts[20];r.maskWidth=job.width;r.maskHeight=job.height;
 }
 GpuSession session;if(!f||!session.render(job)){std::cerr<<job.error;return 3;}
 const auto first=job.output;job.source.clear();
 if(!session.render(job)||first!=job.output){std::cerr<<"resident source changed: "<<job.error;return 4;}
 std::ofstream out(argv[2],std::ios::binary);out.write((char*)job.output.data(),job.output.size());return out?0:5;
}`;
fs.writeFileSync(dir+'/test.cpp',harness);
const unix=p=>'/mnt/'+p[0].toLowerCase()+p.slice(2).replaceAll('\\','/');
function wsl(args){const r=cp.spawnSync('wsl.exe',['-e',...args],{encoding:'utf8'});assert.strictEqual(r.status,0,r.stderr||r.stdout);}
function u32(n){const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;}
function floats(values,count){if(typeof values==='number')values=[values];const b=Buffer.alloc(count*4);for(let i=0;i<count;i++)b.writeFloatLE(values?.[i]??0,i*4);return b;}
function data(buffer){const b=buffer?Buffer.from(buffer):Buffer.alloc(0);return [u32(b.length),b];}
async function main(){
 wsl(['g++','-O2',unix(dir+'/test.cpp'),'-o',unix(dir+'/test'),'-lEGL','-lGLESv2']);
 const w=80,h=48,bytes=new Uint8Array(w*h*4);for(let y=0;y<h;y++)for(let x=0;x<w;x++)bytes.set([x*3,y*5,(x*11+y*7)%256,255],(y*w+x)*4);
 let maximum=0;const results=[];
 // Output geometry of the graded frame per case, so the "original" comparison
 // can be asserted to keep it: bypassing colour must not change framing.
 const gradedGeometry=new Map();
 for(const mode of ['graded','original'])for(const crop of [false,true])for(const rotation of [0,90,180,270])for(const flips of [0,1,2,3]){
  const s=new EditSession();s.layers=[new Layer('test')];s.rotation=rotation;s.flipH=!!(flips&1);s.flipV=!!(flips&2);
  if(crop){s.cropLeft=.131;s.cropTop=.17;s.cropRight=.81;s.cropBottom=.9;}
  s.layers[0].adjustments.exposure=.1;s.layers[0].adjustments.temperature=.15;
  s.layers[0].adjustments.vignetteAmount=-.45;s.layers[0].adjustments.vignetteFeather=.7;
  s.layers[0].adjustments.grainAmount=.3;s.layers[0].adjustments.grainSize=.6;
  const mask=new MaskLayer('mask');mask.components=[new MaskComponent(MaskComponentType.LINEAR_GRADIENT)];mask.adjustments.shadows=.3;s.layers[0].maskLayers=[mask];
  const values=[];for(let b=0;b<17;b++)for(let g=0;g<17;g++)for(let r=0;r<17;r++)values.push((r/16)**.9,g/16,b/16);
  s.lutStack=[{id:'lut',lutId:'lut',name:'lut',sourceUri:'test',enabled:true,intensity:.4,lut:{id:'lut',name:'lut',sourceUri:'test',adjustments:{},sampleCount:17**3,table:{size:17,values,domainMin:[0,0,0],domainMax:[1,1,1]}}}];
  if(mode==='original'){s.layers=[];s.lutStack=[];}
  const cpu=await P.renderToBuffer({readPixelsToBuffer:async b=>new Uint8Array(b).set(bytes)},w,h,s,true,()=>false,false,bytes.buffer,true);
  captured=null;await G.renderPreview(bytes.buffer,w,h,s);assert(captured,'transformed preview must remain GPU eligible');
  const geometry=captured[7],passes=captured[6];assert.equal(geometry.width,cpu.width);assert.equal(geometry.height,cpu.height);
  const geometryKey=`${crop}-${rotation}-${flips}`;
  if(mode==='original'){
   assert.equal(passes.length,0,'comparison must use the original resident texture');
   // The compare frame bypasses colour only: crop, quarter turn and flips must
   // resolve to exactly the graded frame's output size.
   assert.deepStrictEqual([geometry.width,geometry.height],gradedGeometry.get(geometryKey),
     `before/after output geometry differs for ${geometryKey}`);
  }else gradedGeometry.set(geometryKey,[geometry.width,geometry.height]);
  const chunks=[u32(w),u32(h),u32(geometry.width),u32(geometry.height),Buffer.from(geometry.uvMatrix),...data(bytes.buffer),u32(passes.length)];
  for(const p of passes){
   for(const field of ['toneCurve','redCurve','greenCurve','blueCurve','lut','mask'])chunks.push(...data(p[field]));chunks.push(Buffer.from(p.matrix));
   chunks.push(floats(p.vignette,5),floats(p.grain,3),floats(p.denoise,4));
   for(const [field,n] of [['mixHue',8],['mixSaturation',8],['mixLuminance',8],['tonal',4],['whiteBalanceGain',3],['lutDomainMin',3],['lutDomainScale',3],['exposureGain',1],['calibrationHue',3],['calibrationSaturation',3],['gradingShadowsTarget',3],['gradingMidtonesTarget',3],['gradingHighlightsTarget',3],['gradingGlobalTarget',3]])chunks.push(floats(p[field]??(field==='lutDomainScale'?[1,1,1]:field==='exposureGain'?[1]:undefined),n));
   const opts=['whiteBalanceEnabled','vibrance','mixerEnabled','gradingEnabled','gradingShadowsSaturation','gradingShadowsLuminance','gradingMidtonesSaturation','gradingMidtonesLuminance','gradingHighlightsSaturation','gradingHighlightsLuminance','gradingGlobalSaturation','gradingGlobalLuminance','gradingBlending','gradingBalance','opacity','blendMode','maskEnabled','maskOpacity','lutEnabled','lutSize','lutIntensity'].map(k=>Number(p[k]??(k==='opacity'||k==='maskOpacity'||k==='lutIntensity'?1:0)));chunks.push(floats(opts,opts.length));
  }
  const name=`${mode}-${crop}-${rotation}-${flips}`,input=dir+'/'+name+'.bin',out=dir+'/'+name+'.rgba';fs.writeFileSync(input,Buffer.concat(chunks));
  wsl(['env','EGL_PLATFORM=surfaceless',unix(dir+'/test'),unix(input),unix(out)]);
  const actual=fs.readFileSync(out);assert.equal(actual.length,cpu.pixels.length);let max=0,sum=0;
  for(let i=0;i<actual.length;i++){const error=Math.abs(actual[i]-cpu.pixels[i]);max=Math.max(max,error);sum+=error;}
  const mean=sum/actual.length;maximum=Math.max(maximum,max);results.push({mode,crop,rotation,flips,max,mean});assert(max<=8&&mean<=1.5,`${name} CPU/GPU output mismatch ${max}, ${mean}`);
 }
 fs.writeFileSync(dir+'/results.json',JSON.stringify(results,null,2));console.log(`PASS 64 production EGL before/after crop/rotation/flip/mask/LUT cases; resident texture unchanged; max colour error=${maximum}`);
}
main().catch(e=>{console.error(e);process.exitCode=1;});
