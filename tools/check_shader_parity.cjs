/** Actual GLES shader vs the ArkTS CPU reference. Run from project root.
 * Needs local WSL g++, EGL and GLES2; no device or user photos are used. */
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert'),cp=require('child_process');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),cache=new Map(),storage=new Map();
let passes,readbackSession;
function load(file){
 file=path.resolve(file);if(cache.has(file))return cache.get(file).exports;
 const mod={exports:{}};cache.set(file,mod);
 const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText;
 const ctx={exports:mod.exports,module:mod,console,Math,Number,Date,Map,Set,Promise,ArrayBuffer,Uint8Array,Uint8ClampedArray,Uint32Array,Float32Array,setTimeout,clearTimeout,Observed:c=>c,Concurrent:f=>f,
 AppStorage:{get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)},require:name=>{
  if(name==='libvivid_gpu.so')return {default:{renderStack:async(...args)=>{readbackSession=args[0];passes=args[6];return new ArrayBuffer(0);}}};
  if(name==='@kit.ArkTS')return {taskpool:{Task:class{static isCanceled(){return false;}constructor(fn,...args){this.fn=fn;this.args=args;}},execute:async t=>t.fn(...t.args)}};
  if(name.startsWith('@kit.'))return {hilog:{info(){}}};
  if(name==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
      if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file),name+'.ets'));
 }};
 vm.runInNewContext(js,ctx,{filename:file});return mod.exports;
}
const {EditSession}=load(root+'/edit/models/EditSession.ets'),{Layer}=load(root+'/edit/models/Layer.ets');
const {MaskLayer,MaskComponent,MaskComponentType,MaskState,MaskType}=load(root+'/edit/models/Mask.ets');
const {ImageProcessor:P}=load(root+'/edit/engine/ImageProcessor.ets'),{GpuShaderBridge:G}=load(root+'/edit/engine/GpuShaderBridge.ets');
const dir=path.resolve('tmp/shader-parity');fs.mkdirSync(dir,{recursive:true});
const cpp=fs.readFileSync('entry/src/main/cpp/vivid_gpu.cpp','utf8');
const pipeline=fs.readFileSync('entry/src/main/cpp/vivid_gpu_pipeline.inc','utf8');
const struct=cpp.slice(cpp.indexOf('struct RenderWork {'),cpp.indexOf('\n};',cpp.indexOf('struct RenderWork {'))+3)
 .replace(/^\s*napi_.*$/gm,'');
const stackStruct=pipeline.slice(pipeline.indexOf('struct StackWork {'),pipeline.indexOf('\n};',pipeline.indexOf('struct StackWork {'))+3)
 .replace(/^\s*napi_.*$/gm,'');
const implementation=pipeline.slice(pipeline.indexOf('struct CachedTexture {'),pipeline.indexOf('static RenderThread& renderThread()'))
 .replace('EGL_WINDOW_BIT|EGL_PBUFFER_BIT','EGL_PBUFFER_BIT') // Host cannot create HarmonyOS native windows.
 .replace('if (noise) { std::memcpy','if (noise) { ++testNoiseDraws; std::memcpy');
const functions=cpp.slice(cpp.indexOf('static GLuint compileShader'),cpp.indexOf('static void executeRender'));
const harness=`#include <EGL/egl.h>
#include <GLES2/gl2.h>
// The product file defines these locally because it still includes the GLES2
// header; the extracted harness needs the same constants.
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
${struct}
${functions}
${stackStruct}
static int testNoiseDraws=0;
${implementation}
static uint32_t u32(std::ifstream& f){uint32_t n;f.read((char*)&n,4);return n;}
static void bytes(std::ifstream& f,std::vector<uint8_t>& v){v.resize(u32(f));f.read((char*)v.data(),v.size());}
static void array(std::ifstream& f,float* a,int n){f.read((char*)a,n*4);}
int main(int argc,char** argv){
 if(argc!=3)return 2;std::ifstream f(argv[1],std::ios::binary);if(!f)return 3;
 const auto w=u32(f),h=u32(f),n=u32(f);StackWork job;job.width=w;job.height=h;job.outputWidth=w;job.outputHeight=h;
 job.sourceVersion=1;bytes(f,job.source);job.passes.resize(n);
 for(uint32_t i=0;i<n;i++){
  auto& r=job.passes[i];r.width=w;r.height=h;
  for(auto* v:{&r.toneCurve,&r.redCurve,&r.greenCurve,&r.blueCurve,&r.parametricCurve,&r.lut,&r.mask})bytes(f,*v);
  array(f,r.matrix,20);array(f,r.vignette,5);array(f,r.grain,3);array(f,r.denoise,4);
  array(f,r.mixHue,8);array(f,r.mixSaturation,8);array(f,r.mixLuminance,8);
  array(f,r.tonal,4);array(f,r.whiteBalanceGain,3);array(f,r.lutDomainMin,3);array(f,r.lutDomainScale,3);float exposure;array(f,&exposure,1);r.exposureGain=exposure;array(f,r.calibrationHue,3);array(f,r.calibrationSaturation,3);
  array(f,r.gradingShadowsTarget,3);array(f,r.gradingMidtonesTarget,3);array(f,r.gradingHighlightsTarget,3);array(f,r.gradingGlobalTarget,3);
  float opts[23];array(f,opts,23);
  r.whiteBalanceEnabled=opts[0];r.vibrance=opts[1];r.mixerEnabled=opts[2];r.gradingEnabled=opts[3];
  r.gradingShadowsSaturation=opts[4];r.gradingShadowsLuminance=opts[5];r.gradingMidtonesSaturation=opts[6];r.gradingMidtonesLuminance=opts[7];
  r.gradingHighlightsSaturation=opts[8];r.gradingHighlightsLuminance=opts[9];r.gradingGlobalSaturation=opts[10];r.gradingGlobalLuminance=opts[11];
  r.gradingBlending=opts[12];r.gradingBalance=opts[13];r.opacity=opts[14];r.blendMode=opts[15];r.maskEnabled=opts[16];
  r.maskOpacity=opts[17];r.lutEnabled=opts[18];r.lutSize=opts[19];r.lutIntensity=opts[20];r.maskWidth=w;r.maskHeight=h;
  r.parametricEnabled=opts[21]>0.5f;r.parametricRefine=opts[22];
  std::vector<uint8_t>* assets[]={&r.toneCurve,&r.redCurve,&r.greenCurve,&r.blueCurve,&r.lut,&r.mask};
  for(int k=0;k<6;k++)if(!assets[k]->empty()){
   r.assets[k]=std::make_shared<const std::vector<uint8_t>>(std::move(*assets[k]));r.assetIds[k]=i*6+k+1;
  }
 }
 GpuSession session;if(!f||!session.render(job)){std::cerr<<job.error<<std::endl;return 4;}
 std::ofstream out(argv[2],std::ios::binary);out.write((char*)job.output.data(),job.output.size());
 if(!job.passes.empty()&&(job.passes[0].denoise[0]>0||job.passes[0].denoise[1]>0)){
  auto originalSource=job.source,originalOutput=job.output;job.source.clear();
  if(testNoiseDraws!=1||!session.render(job)||testNoiseDraws!=1||job.output!=originalOutput)return 6;
  if(job.passes.size()>1){
   job.passes.back().matrix[4]+=15;
   if(!session.render(job)||testNoiseDraws!=1||job.output==originalOutput)return 7;
  }
  job.passes[0].denoise[2]+=0.1f;
  if(!session.render(job)||testNoiseDraws!=2)return 8;
  job.sourceVersion++;job.source=originalSource;
  if(!session.render(job)||testNoiseDraws!=3)return 9;
 }
 return out?0:5;
}`;
fs.writeFileSync(dir+'/test.cpp',harness);
// --- The harness must execute every stage production makes MANDATORY --------
// `vivid_gpu.cpp` parses its per-pass buffers inside a `||` chain: if a required
// buffer is missing the entire pass is rejected. The harness hand-writes its own
// unpacking, and it simply did not read `parametricCurve`, while `parametricEnabled`
// defaults to false in RenderWork. The parametric curve was therefore NEVER executed
// by this suite even though the production GLSL implements it and the CPU/GPU
// refinement formula is asserted to match -- the suite could not see the one stage it
// was supposed to be the evidence for.
// The required set is derived from the production parser instead of being listed here,
// so adding a required buffer (or a gating flag) without marshalling it fails loudly.
const requiredBlock=cpp.slice(cpp.indexOf('if (!copyNamedBuffer'),cpp.indexOf('copyNumberArray(env, args[3], "mixHue"'));
const requiredBuffers=[...requiredBlock.matchAll(/copyNamedBuffer\(env, args\[3\], "([a-zA-Z]+)"/g)].map(m=>m[1]);
assert(requiredBuffers.length>=5,'must derive the production parser\'s required buffer list, got '+requiredBuffers.length);
const harnessFields=harness.slice(harness.indexOf('for(auto* v:{'),harness.indexOf('std::vector<uint8_t>* assets[]'));
for(const field of requiredBuffers)assert(harnessFields.includes('&r.'+field),'the GLES harness must read required buffer "'+field+'" or that stage is never executed');
const selfSource=fs.readFileSync(__filename,'utf8');
// lastIndexOf, not indexOf: this guard's own source contains the same anchors, and it
// sits earlier in the file than the marshalling it is inspecting.
const marshalStart=selfSource.lastIndexOf('for(const field of [');
const marshalList=selfSource.slice(marshalStart,selfSource.indexOf('chunks.push',marshalStart));
assert(marshalStart>=0&&marshalList.includes("'toneCurve'"),'must locate the real per-pass marshalling list');
for(const field of requiredBuffers)assert(marshalList.includes("'"+field+"'"),'the marshalling must write required buffer "'+field+'"');
// Gating flags are optional to the parser, so a missing one does not fail the pass --
// it silently disables a shader branch. Guard those too.
const flags=[...cpp.matchAll(/getBool\(env, args\[3\], "([a-zA-Z]+)"/g)].map(m=>m[1]);
assert(flags.length>=3,'must derive the shader gating flags from the production parser, got '+flags.length);
const optStart=selfSource.lastIndexOf('const opt=[');
const optBlock=selfSource.slice(optStart,selfSource.indexOf('.map(k=>Number(p[k]',optStart));
assert(optStart>=0&&optBlock.includes("'whiteBalanceEnabled'"),'must locate the real gating-flag list');
for(const flag of flags)assert(optBlock.includes("'"+flag+"'"),'the marshalling must carry gating flag "'+flag+'" or that shader branch is never taken here');
assert(flags.includes('parametricEnabled'),'and the parametric branch is one of them, which is the specific hole this guard closes');
console.log('guarded: required buffers ['+requiredBuffers.join(', ')+'] and gating flags ['+flags.join(', ')+']');
const unix=p=>'/mnt/'+p[0].toLowerCase()+p.slice(2).replaceAll('\\','/');
function wsl(args){const r=cp.spawnSync('wsl.exe',['-e',...args],{encoding:'utf8'});
 // The EGL/GLESv2 harness needs WSL plus a C++ toolchain. When the host cannot
 // provide them this is an environment limitation, not a parity failure, so it
 // must be reported distinctly instead of masquerading as a failed assertion.
 if(r.error||r.status===null){console.log('SKIP check_shader_parity: WSL/unix toolchain unavailable ('+(r.error?r.error.code:'no status')+')');process.exit(2);}
 assert.strictEqual(r.status,0,r.stderr||r.stdout);}
function u32(n){const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;}
function floats(values,count){if(typeof values==='number')values=[values];const b=Buffer.alloc(count*4);for(let i=0;i<count;i++)b.writeFloatLE(values?.[i]??0,i*4);return b;}
function data(buffer){const b=buffer?Buffer.from(buffer):Buffer.alloc(0);return [u32(b.length),b];}
function lut(id,size,gamma,low=0,high=1){const values=[];for(let b=0;b<size;b++)for(let g=0;g<size;g++)for(let r=0;r<size;r++)values.push(low+(high-low)*(r/(size-1))**gamma,low+(high-low)*(g/(size-1))**gamma,low+(high-low)*(b/(size-1))**gamma);
return {id,lutId:id,name:id,sourceUri:'test',enabled:true,intensity:.65,lut:{id,name:id,sourceUri:'test',adjustments:{},sampleCount:size**3,table:{size,values,domainMin:[0,0,0],domainMax:[1,1,1]}}};}
async function main(){
 wsl(['g++','-O2',unix(dir+'/test.cpp'),'-o',unix(dir+'/test'),'-lEGL','-lGLESv2']);
 const w=64,h=48,bytes=new Uint8Array(w*h*4);for(let y=0;y<h;y++)for(let x=0;x<w;x++)bytes.set([Math.round(x*255/(w-1)),Math.round(y*255/(h-1)),(x*11+y*7)%256,255],(y*w+x)*4);
 const results=[];
 const tests=['identity','noise-luminance','noise-color','noise-combination','noise-mask-lut','tonal','wb-vibrance','calibration','hsl','grading','two-luts','mask-combination','all',
  'vignette-dark','vignette-light','vignette-rectangle','vignette-circle','grain','grain-small','grain-rough','spatial-masked-luts',
  'exposure-dark','exposure-light','exposure-wb-tonal','matrix-exposure','point-curves','scalar-curves','domain-lut',
  'lut-33','lut-65','lut-33-extended','lut-65-extended',
  'exposure-contrast-minus','exposure-contrast-plus','exposure-wb-minus','exposure-wb-plus',
  ...['linear','radial'].flatMap(type=>[.25,.5,.9].map(opacity=>'feather-'+type+'-'+opacity)),
  'feather-alpha-linear','feather-alpha-radial','legacy-feather-migrated',
  ...['Red','Green','Blue'].flatMap(c=>['Hue','Saturation'].map(k=>'primary-'+c+k)),
  ...[1,2,3].map(b=>'blend-'+b),...Array.from({length:16},(_,i)=>'combination-'+i)];
 for(const test of tests){
  const s=new EditSession();s.layers=[new Layer('test')];s.lutStack=[];const a=s.layers[0].adjustments;
  const source=bytes.slice();let analyticMask=false;
  if(test.startsWith('noise-')){
   s.denoise.luminance=test==='noise-color'?0:.75;s.denoise.color=test==='noise-luminance'?0:.8;
   s.denoise.detail=.35;s.denoise.colorDetail=.45;
   if(test==='noise-mask-lut'){
    a.exposure=.3;a.contrast=.15;s.lutStack=[lut('noise-lut',17,.87)];
    const m=new MaskLayer('noise');m.inverted=true;m.opacity=.7;m.adjustments.shadows=.25;
    m.components=[new MaskComponent(MaskComponentType.RADIAL_GRADIENT)];s.layers[0].maskLayers=[m];
   }
  }
  if(test==='tonal'||test==='all'){a.highlights=-.45;a.shadows=.4;a.whites=.15;a.blacks=-.2;}
  if(test==='wb-vibrance'||test==='all'){a.temperature=.35;a.tint=-.25;a.vibrance=.4;}
  if(test==='calibration'||test==='all'){a.calibrationRedHue=.2;a.calibrationBlueSaturation=-.25;}
  if(test==='hsl'||test==='all'){a.mixHue=[.1,-.15,.3,-.1,.2,0,-.2,.1];a.mixSaturation=[.3,-.2,.1,0,-.1,.2,-.3,.1];}
  if(test==='grading'||test==='all'){a.gradingShadowsHue=215;a.gradingShadowsSaturation=.12;a.gradingHighlightsHue=40;a.gradingHighlightsSaturation=.08;}
  if(test==='two-luts'||test==='all'||test==='mask-combination')s.lutStack=[lut('lift',17,.9),lut('dark',33,1.2)];
  if(test==='mask-combination'){const m=new MaskLayer('mask');m.components=[new MaskComponent(MaskComponentType.LINEAR_GRADIENT)];m.adjustments.temperature=.4;m.adjustments.shadows=.3;m.opacity=.6;s.layers[0].maskLayers=[m];}
  if(test==='exposure-dark')a.exposure=-1;
  if(test==='exposure-light')a.exposure=1;
  if(test==='exposure-wb-tonal'){a.exposure=.65;a.temperature=-.8;a.tint=.5;a.shadows=.65;a.highlights=-.7;}
  if(test==='matrix-exposure'){a.exposure=-.25;a.contrast=.4;a.brightness=.15;a.saturation=-.3;a.hue=35;}
  if(test.startsWith('exposure-contrast-')){a.exposure=test.endsWith('minus')?-.65:.65;a.contrast=.7;a.brightness=.2;}
  if(test.startsWith('exposure-wb-')){a.exposure=test.endsWith('minus')?-.65:.65;a.temperature=.8;a.tint=-.6;}
  if(test.startsWith('feather-')){
   analyticMask=test.startsWith('feather-alpha-');const radial=test.includes('radial');
   const m=new MaskLayer('feather');const component=new MaskComponent(radial?MaskComponentType.RADIAL_GRADIENT:MaskComponentType.LINEAR_GRADIENT);
   component.feather=.4;component.opacity=.7;m.components=[component];m.opacity=analyticMask?.8:Number(test.split('-').at(-1));
   if(analyticMask){
    a.brightness=.125;s.layers[0].opacity=.6;m.adjustments.brightness=.25;
    for(let i=0;i<w*h;i++)source.set([70,100,140,255],i*4);
   }else{a.exposure=.3;a.contrast=.25;m.adjustments.exposure=-.4;m.adjustments.temperature=.6;m.adjustments.shadows=.45;}
   s.layers[0].maskLayers=[m];
  }
  if(test==='legacy-feather-migrated'){
   a.brightness=.125;a.exposure=.2;s.layers[0].mask=new MaskState();s.layers[0].mask.type=MaskType.LINEAR_GRADIENT;
   s.layers[0].mask.feather=.3;s.layers[0].maskAdjustments.brightness=.25;
  }
  if(test==='point-curves'){
   a.setCurvePoints(0,[[0,0],[.13,.025],[.36,.55],[.81,.92],[1,1]].map(p=>new (load(root+'/edit/models/Adjustment.ets').CurveAnchor)(...p)));
   a.setCurvePoints(1,[[0,0],[.23,.39],[.8,.65],[1,1]].map(p=>new (load(root+'/edit/models/Adjustment.ets').CurveAnchor)(...p)));a.exposure=.3;
  }
  if(test==='scalar-curves'){a.toneCurve=.9;a.curveRed=-.8;a.curveGreen=.55;a.curveBlue=.4;}
  if(test==='domain-lut'){const item=lut('domain',17,.82);item.lut.table.domainMin=[-.2,-.1,0];item.lut.table.domainMax=[.8,.9,1.2];s.lutStack=[item];}
  // 65^3 is the largest standard .cube. Its RGBA16F atlas is 4225x65, so this
  // case only reaches the GPU when the bridge's 65 limit and the renderer's
  // GL_MAX_TEXTURE_SIZE check both pass. (The user's P2216531 preset is a 33^3
  // NP3 bake, so this case proves the 65 ceiling independently of that photo.)
  if(test==='lut-33')s.lutStack=[lut('cube33',33,1.1)];
  if(test==='lut-65')s.lutStack=[lut('cube65',65,.9)];
  // Extended-range tables are the reason the atlas moved to RGBA16F: a .cube
  // may legitimately contain values below 0 or above 1, and RGB8 would clip
  // them before the shader's interpolation. These cases prove the half-float
  // path against the CPU reference without widening the parity tolerance.
  if(test==='lut-33-extended')s.lutStack=[lut('cube33x',33,1.1,-.2,1.2)];
  if(test==='lut-65-extended')s.lutStack=[lut('cube65x',65,.9,-.15,1.15)];
  if(test.startsWith('primary-'))a['calibration'+test.slice(8)]=test.endsWith('Hue')?.8:-.8;
  if(test.startsWith('blend-')){a.exposure=.3;a.shadows=.2;s.layers[0].opacity=.6;s.layers[0].blendMode=Number(test.slice(6));}
  if(test.startsWith('combination-')){
   let seed=Number(test.slice(12))+12345;const rnd=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;};
   for(const key of ['exposure','contrast','brightness','saturation','vibrance','temperature','tint','shadows','highlights','blacks','whites',
    'toneCurve','curveRed','curveGreen','curveBlue','calibrationRedHue','calibrationGreenHue','calibrationBlueHue',
    'calibrationRedSaturation','calibrationGreenSaturation','calibrationBlueSaturation'])a[key]=(rnd()-.5)*.8;
   a.hue=(rnd()-.5)*60;
   for(const key of ['mixHue','mixSaturation','mixLuminance'])a[key]=Array.from({length:8},()=>((rnd()-.5)*.6));
   for(const band of ['Shadows','Midtones','Highlights','Global']){a['grading'+band+'Hue']=rnd()*360;a['grading'+band+'Saturation']=rnd()*.3;a['grading'+band+'Luminance']=(rnd()-.5)*.4;}
   a.gradingBlending=rnd()*2-1;a.gradingBalance=rnd()*2-1;s.layers[0].opacity=.5+rnd()*.5;
   const m=new MaskLayer('combined-mask');m.components=[new MaskComponent(MaskComponentType.LINEAR_GRADIENT)];
   m.adjustments.exposure=(rnd()-.5)*.8;m.adjustments.temperature=(rnd()-.5)*.8;m.opacity=.65;s.layers[0].maskLayers=[m];
   s.lutStack=[lut('combo-light',17,.95),lut('combo-dark',17,1.05)];
  }
  if(test.startsWith('vignette-')){
   a.vignetteAmount=test==='vignette-light'?.65:-.65;a.vignetteMidpoint=.45;a.vignetteFeather=.8;a.vignetteHighlights=.6;
   a.vignetteRoundness=test==='vignette-rectangle'?-.7:test==='vignette-circle'?.9:0;
  }
  if(test.startsWith('grain')){a.grainAmount=.8;a.grainSize=test==='grain-small'?.1:.6;a.grainRoughness=test==='grain-rough'?.95:.3;}
  if(test==='spatial-masked-luts'){
   a.grainAmount=.4;a.grainSize=.7;a.grainRoughness=.6;a.vignetteAmount=-.5;a.vignetteFeather=.65;a.temperature=.35;a.exposure=.2;
   const m=new MaskLayer('spatial');m.components=[new MaskComponent(MaskComponentType.LINEAR_GRADIENT)];
   m.adjustments.vignetteAmount=.4;m.adjustments.grainAmount=.3;m.adjustments.grainSize=.7;m.opacity=.6;s.layers[0].maskLayers=[m];
   s.lutStack=[lut('spatial-light',17,.9),lut('spatial-dark',33,1.2)];
  }
  const cpu=await P.renderToBuffer({readPixelsToBuffer:async b=>new Uint8Array(b).set(source)},w,h,s,true,()=>false,false,source.buffer,true);
  passes=null;readbackSession=null;await G.renderExport(source.buffer,w,h,s);
  // The export API intentionally declines identity-only work; test that separately via the preview path.
  if(test==='identity'){assert.strictEqual(passes,null);await G.renderPreview(source.buffer,w,h,s);}
  else assert.strictEqual(readbackSession,'vivid-export','must use the actual export pass builder: '+test);
  assert(passes,'common controls must remain GPU eligible: '+test);
  const maskPasses=passes.filter(p=>p.maskEnabled);
  const fractionalMaskPixels=maskPasses.reduce((n,p)=>n+new Uint8Array(p.mask).filter(v=>v>0&&v<255).length,0);
  if(test.startsWith('feather-')||test==='legacy-feather-migrated')assert(fractionalMaskPixels>100,'fixture must exercise fractional feather alpha');
  const chunks=[u32(w),u32(h),u32(passes.length),...data(source.buffer)];
  for(const p of passes){
   for(const field of ['toneCurve','redCurve','greenCurve','blueCurve','parametricCurve','lut','mask'])chunks.push(...data(p[field]));
   chunks.push(Buffer.from(p.matrix));
   chunks.push(floats(p.vignette,5),floats(p.grain,3),floats(p.denoise,4));
   for(const [field,n] of [['mixHue',8],['mixSaturation',8],['mixLuminance',8],['tonal',4],['whiteBalanceGain',3],['lutDomainMin',3],['lutDomainScale',3],['exposureGain',1],['calibrationHue',3],['calibrationSaturation',3],['gradingShadowsTarget',3],['gradingMidtonesTarget',3],['gradingHighlightsTarget',3],['gradingGlobalTarget',3]])chunks.push(floats(p[field]??(field==='lutDomainScale'?[1,1,1]:field==='exposureGain'?[1]:undefined),n));
   const opt=['whiteBalanceEnabled','vibrance','mixerEnabled','gradingEnabled','gradingShadowsSaturation','gradingShadowsLuminance','gradingMidtonesSaturation','gradingMidtonesLuminance','gradingHighlightsSaturation','gradingHighlightsLuminance','gradingGlobalSaturation','gradingGlobalLuminance','gradingBlending','gradingBalance','opacity','blendMode','maskEnabled','maskOpacity','lutEnabled','lutSize','lutIntensity','parametricEnabled','parametricRefine'].map(k=>Number(p[k]??(k==='opacity'||k==='maskOpacity'||k==='lutIntensity'||k==='parametricRefine'?1:0)));
   chunks.push(floats(opt,opt.length));
  }
  const input=dir+'/'+test+'.bin',out=dir+'/'+test+'.rgba';fs.writeFileSync(input,Buffer.concat(chunks));
  wsl(['env','EGL_PLATFORM=surfaceless',unix(dir+'/test'),unix(input),unix(out)]);
  const actual=fs.readFileSync(out);let max=0,sum=0;for(let i=0;i<actual.length;i++){const error=Math.abs(actual[i]-cpu.pixels[i]);max=Math.max(max,error);sum+=error;}
  if(analyticMask){
   assert.strictEqual(maskPasses.length,1);const mask=new Uint8Array(maskPasses[0].mask);
   const base=[75,105,145];let distinguishSquared=0;
   for(let i=0;i<w*h;i++)for(let c=0;c<3;c++){
    const alpha=mask[i]/255,expected=Math.round(base[c]+16*.6*alpha);
    assert.strictEqual(cpu.pixels[i*4+c],expected,'CPU must apply mask alpha once');
    assert(Math.abs(actual[i*4+c]-expected)<=1,'native export must apply mask alpha once');
    if(Math.abs(expected-Math.round(base[c]+16*.6*alpha*alpha))>=2)distinguishSquared++;
   }
   assert(distinguishSquared>100,'fixture must reject the previous squared-alpha behaviour');
  }
  const mean=sum/actual.length;results.push({test,path:readbackSession,passes:passes.length,fractionalMaskPixels,max,mean});console.log({test,path:readbackSession,max,mean});
  assert(max<=8&&mean<=1.5,'CPU/GPU parity failed: '+test);
  if(test.startsWith('exposure-contrast-')||test.startsWith('exposure-wb-')||test.startsWith('feather-'))assert(max<=2,'targeted export regression failed: '+test);
 }
 const legacy=new EditSession();legacy.layers=[new Layer('deliberately-unmigrated')];legacy.layers[0].migrateMask=()=>{};
 legacy.layers[0].mask=new MaskState();legacy.layers[0].mask.type=MaskType.LINEAR_GRADIENT;legacy.layers[0].maskAdjustments.brightness=.25;
 passes=null;assert.strictEqual(await G.renderExport(bytes.buffer,w,h,legacy),null);assert.strictEqual(passes,null);
 console.log('PASS unmigrated legacy local adjustments explicitly decline GPU instead of using incorrect mask semantics');
 // The parametric tone curve is implemented ONLY in the single-pass shader inside
 // vivid_gpu.cpp. The pipeline this process actually runs -- the multi-pass stack renderer
 // in vivid_gpu_pipeline.inc -- contains no parametric code at all: no uniform, no texture,
 // no sampling. This was invisible until the harness was made to read parametricCurve and a
 // case was fed through it; with the curve then active the GPU frame omitted it completely
 // and differed from the CPU by up to 14 8-bit levels (the exact displacement the curve
 // applies at input 224). The bridge must decline rather than publish that frame.
 const parametricSession=new EditSession();parametricSession.layers=[new Layer('parametric-curve')];
 const pa=parametricSession.layers[0].adjustments;
 pa.parametricHighlights=.55;pa.parametricLights=-.3;pa.parametricDarks=.45;pa.parametricShadows=-.2;
 passes=null;assert.strictEqual(await G.renderExport(bytes.buffer,w,h,parametricSession),null,
  'an active parametric curve must decline the GPU: the pipeline in use cannot render it');
 assert.strictEqual(passes,null,'no pass may be built for an active parametric curve');
 assert.strictEqual(await G.renderPreview(bytes.buffer,w,h,parametricSession),null,
  'and the preview/readback path must decline it too');
 // The other direction: a moved split or refinement slider is the identity while every
 // region amount is zero, so it must NOT cost the GPU. Asserting only the decline would let
 // an over-broad guard pass while quietly disabling the resident pipeline for these.
 const inertSession=new EditSession();inertSession.layers=[new Layer('parametric-inert')];
 const ia=inertSession.layers[0].adjustments;
 ia.exposure=.3;
 ia.parametricShadowSplit=.12;ia.parametricDarkSplit=.62;ia.parametricLightSplit=.88;
 ia.parametricRefineSaturation=0;
 passes=null;const inert=await G.renderExport(bytes.buffer,w,h,inertSession);
 assert.notStrictEqual(inert,null,'a moved split or refinement slider is the identity and must stay GPU eligible');
 assert(passes&&passes.length===1,'and must still build its pass');
 console.log('PASS an active parametric curve declines GPU (the running pipeline has no implementation of it),');
 console.log('     while a moved split or refinement slider alone does not');
 // A local (masked) adjustment carrying the curve must decline too, since optionsFor is
 // called for mask layers as well.
 const localSession=new EditSession();localSession.layers=[new Layer('parametric-local')];
 const lm=new MaskLayer('parametric-local');lm.components=[new MaskComponent(MaskComponentType.LINEAR_GRADIENT)];
 lm.adjustments.parametricDarks=.5;lm.opacity=.6;localSession.layers[0].maskLayers=[lm];
 passes=null;assert.strictEqual(await G.renderExport(bytes.buffer,w,h,localSession),null,
  'and a parametric curve carried by a masked local adjustment must also decline');
 console.log('PASS a parametric curve on a masked local adjustment declines GPU as well');
  // The detail stage (texture/clarity/dehaze/sharpen) is a full-frame
  // neighbourhood operation with no shader implementation. The running native
  // path must decline it so the CPU renders those pixels rather than emitting a
  // frame that silently omits them. Both directions are asserted: a decline that
  // also fired on a bypassed stage would be a performance regression, not a fix.
  const detailSession=new EditSession();detailSession.layers=[new Layer('detail-stage')];
  detailSession.layers[0].adjustments.brightness=.2;detailSession.detail.clarity=.8;
  passes=null;assert.strictEqual(await G.renderExport(bytes.buffer,w,h,detailSession),null,
   'an active detail stage must decline the GPU');
  assert.strictEqual(passes,null);
  detailSession.detail.clarity=0;
  passes=null;const detailBypass=await G.renderExport(bytes.buffer,w,h,detailSession);
  assert.notStrictEqual(detailBypass,null,'a bypassed detail stage must remain GPU eligible');
  assert(passes&&passes.length===1,'a bypassed detail stage must still build its pass');
  console.log('PASS an active detail stage declines the running native GPU path and a bypassed one does not');
   // The optics stage has no shader implementation either, so an active one must
   // decline and a bypassed one must stay eligible. EVERY amount is asserted on its
   // own: a field missing from the bypass predicate would silently render
   // uncorrected pixels while the UI showed the slider as set.
   const opticsFields=['distortion','vignetteAmount','chromaticAberration','defringePurple','defringeGreen'];
   for(const field of opticsFields){
    const oneField=new EditSession();oneField.layers=[new Layer('optics-'+field)];
    oneField.layers[0].adjustments.brightness=.2;oneField.optics[field]=.5;
    passes=null;assert.strictEqual(await G.renderExport(bytes.buffer,w,h,oneField),null,
     'an active optics stage ('+field+') must decline the GPU');
    assert.strictEqual(passes,null,'no pass may be built while '+field+' is active');
   }
   const opticsSession=new EditSession();opticsSession.layers=[new Layer('optics-stage')];
   opticsSession.layers[0].adjustments.brightness=.2;opticsSession.optics.distortion=.6;
   passes=null;assert.strictEqual(await G.renderExport(bytes.buffer,w,h,opticsSession),null,
    'an active optics stage must decline the GPU');
   opticsSession.optics.distortion=0;
   // The midpoint only shapes where the falloff happens, so with the depth at zero
   // it must NOT be treated as a reason to leave the GPU.
   opticsSession.optics.vignetteMidpoint=.9;
   passes=null;const opticsBypass=await G.renderExport(bytes.buffer,w,h,opticsSession);
   assert.notStrictEqual(opticsBypass,null,'a bypassed optics stage must remain GPU eligible');
   assert(passes&&passes.length===1,'a bypassed optics stage must still build its pass');
   console.log('PASS an active optics stage declines the running native GPU path, each of its five amounts');
   console.log('     independently, and a bypassed one (including a midpoint-only change) does not');
   // Point colour has no shader implementation either, so an active shift must
   // decline. Each of the three shifts is asserted on its own, and a colour that has
   // been SAMPLED but not yet shifted must NOT decline -- adding a swatch is not yet
   // an image change, and treating it as one would drop the preview to the CPU path
   // for no visible reason.
   const pointColorFields=['hueShift','saturationShift','luminanceShift'];
   for(const field of pointColorFields){
    const colourSession=new EditSession();colourSession.layers=[new Layer('pc-'+field)];
    colourSession.layers[0].adjustments.brightness=.2;
    colourSession.pointColor.addHsl(.1,.6,.5);
    colourSession.pointColor.samples[0][field]=.5;
    passes=null;assert.strictEqual(await G.renderExport(bytes.buffer,w,h,colourSession),null,
     'an active point colour ('+field+') must decline the GPU');
    assert.strictEqual(passes,null,'no pass may be built while '+field+' is active');
   }
   const pcBypassSession=new EditSession();pcBypassSession.layers=[new Layer('pc-sampled')];
   pcBypassSession.layers[0].adjustments.brightness=.2;
   pcBypassSession.pointColor.addHsl(.1,.6,.5);
   passes=null;const pcBypass=await G.renderExport(bytes.buffer,w,h,pcBypassSession);
   assert.notStrictEqual(pcBypass,null,'a sampled but unshifted point colour must remain GPU eligible');
   assert(passes&&passes.length===1,'and must still build its pass');
   console.log('PASS an active point colour declines the running native GPU path for each of its three');
   console.log('     shifts, while a colour that was sampled but not yet shifted does not');
   // OkLCh is retired: legacy non-zero fields must be an exact no-op, so unlike
   // the old active stage they must NOT decline the GPU. Each field is asserted
   // on its own to prove the model -- not the shader -- is what makes it inert.
   const oklchFields=['lightness','chroma','hue'];
   for(const field of oklchFields){
    const gradeSession=new EditSession();gradeSession.layers=[new Layer('oklch-'+field)];
    gradeSession.layers[0].adjustments.brightness=.2;
    gradeSession.oklch[field]=.4;
    assert.strictEqual(gradeSession.oklch.isBypass(),true,
     'legacy OkLCh '+field+' values must report bypass');
    passes=null;const retiredGrade=await G.renderExport(bytes.buffer,w,h,gradeSession);
    assert.notStrictEqual(retiredGrade,null,
     'a retired OkLCh grade ('+field+') must stay GPU eligible instead of declining');
    assert(passes&&passes.length===1,'and must still build its pass');
   }
   const okBypassSession=new EditSession();okBypassSession.layers=[new Layer('oklch-bypass')];
   okBypassSession.layers[0].adjustments.brightness=.2;
   passes=null;const okBypass=await G.renderExport(bytes.buffer,w,h,okBypassSession);
   assert.notStrictEqual(okBypass,null,'a bypassed OkLCh stage must remain GPU eligible');
   assert(passes&&passes.length===1,'and must still build its pass');
   // The retired stage must not sneak back in through a legacy sidecar value.
   okBypassSession.oklch.chroma=-1;
   passes=null;const legacyGrade=await G.renderExport(bytes.buffer,w,h,okBypassSession);
   assert.notStrictEqual(legacyGrade,null,
    'a non-zero legacy OkLCh value must still be a no-op and must not decline the GPU');
   assert(passes&&passes.length===1,'and still builds the GPU pass');
   console.log('PASS the retired OkLCh stage never declines the GPU, even with legacy non-zero values,');
   // The black-and-white conversion has no shader implementation either. Weights set on a
   // switched-off conversion must NOT decline: the weights are inert until the stage is on,
   // so treating them as a change would drop the preview to the CPU path for no reason.
   const bwSession=new EditSession();bwSession.layers=[new Layer('black-white')];
   bwSession.layers[0].adjustments.brightness=.2;
   bwSession.blackWhite.enabled=true;
   passes=null;assert.strictEqual(await G.renderExport(bytes.buffer,w,h,bwSession),null,
    'an enabled black-and-white conversion must decline the GPU');
   assert.strictEqual(passes,null,'no pass may be built while the conversion is on');
   const bwOffSession=new EditSession();bwOffSession.layers=[new Layer('black-white-off')];
   bwOffSession.layers[0].adjustments.brightness=.2;
   bwOffSession.blackWhite.mixers[0]=.5;
   passes=null;const bwOff=await G.renderExport(bytes.buffer,w,h,bwOffSession);
   assert.notStrictEqual(bwOff,null,'mixer weights set on a switched-off conversion must remain GPU eligible');
   assert(passes&&passes.length===1,'and must still build its pass');
   console.log('PASS an enabled black-and-white conversion declines the running native GPU path, while');
   console.log('     mixer weights set on a switched-off conversion do not');
   // Upright is deliberately NOT a render stage: a solve writes geometry[0..2],
   // which the GPU already uploads as uniforms. So unlike optics and detail it must
   // NOT decline. Asserting the positive here is what proves no new stage is being
   // silently skipped -- a decline would have been the wrong fix and would have
   // halved the resolution every time a user levelled a horizon.
   const uprightSession=new EditSession();uprightSession.layers=[new Layer('upright-stage')];
   uprightSession.layers[0].adjustments.brightness=.2;
   uprightSession.imageWidth=w;uprightSession.imageHeight=h;
   uprightSession.upright.addGuide(.30,.90,.40,.10);
   uprightSession.upright.addGuide(.70,.90,.60,.10);
   const uprightSolution=uprightSession.solveUprightGuides();
   assert(uprightSolution.verticalPerspective!==0,
    'the upright solve must actually produce a correction for this test to mean anything');
   assert.strictEqual(uprightSession.geometry[0],uprightSolution.verticalPerspective*160,
    'and must have written it into the geometry the GPU uploads');
   passes=null;const uprightGpu=await G.renderExport(bytes.buffer,w,h,uprightSession);
   assert.notStrictEqual(uprightGpu,null,'Upright must NOT decline the GPU: it writes geometry fields '+ 
    'the GPU already uploads rather than adding a stage');
   assert(passes&&passes.length===1,'and must still build its pass');
   console.log('PASS Upright does NOT decline the running native GPU path, because a solve writes the');
   console.log('     geometry uniforms the GPU already uploads instead of adding a stage');
 fs.writeFileSync(dir+'/results.json',JSON.stringify(results,null,2));console.log('PASS production GpuSession export pipeline and CPU/GPU image parity');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
