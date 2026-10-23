// Production ArkTS pipeline regression tests; synthetic pixels only.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),cache=new Map(),allocations=[];
const baselineRoot=path.resolve('analysis/color-audit-baseline-20261003/entry/src/main/ets');
class TrackedPixels extends Uint8ClampedArray {
 constructor(...args){super(...args);if(typeof args[0]==='number')allocations.push({kind:'scratch',bytes:this.byteLength});
  else if(ArrayBuffer.isView(args[0]))allocations.push({kind:'copy',bytes:this.byteLength});}
 static get [Symbol.species](){return Uint8ClampedArray;}
}
function load(file){
 file=path.resolve(file);if(cache.has(file))return cache.get(file).exports;
 const mod={exports:{}};cache.set(file,mod);
 const ctx={module:mod,exports:mod.exports,console,Math,Number,Date,Map,Set,Promise,ArrayBuffer,Uint8Array,setTimeout,clearTimeout,
  Uint8ClampedArray:TrackedPixels,Uint32Array,Float32Array,Observed:c=>c,Concurrent:f=>f,
  AppStorage:{get:()=>false,setOrCreate(){}},
  require:name=>{if(name==='libvivid_gpu.so')return {default:{}};
   if(name==='@kit.ArkTS')return {taskpool:{Task:class{static isCanceled(){return false;}constructor(fn,...args){this.fn=fn;this.args=args;}},execute:async()=>{throw new Error('Synthetic forced TaskPool failure');}}};
   if(name.startsWith('@kit.'))return {};
   // ImageProcessor now clears the AI segmentation cache alongside the other source-derived
   // caches, so its module graph reaches the native AI binding.
   if(name==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
   if(name.endsWith('.so'))return {default:{}};
   const target=path.resolve(path.dirname(file),name+'.ets');
   // The baseline stores edited files only; unchanged dependencies still live in the project.
   return load(!fs.existsSync(target)&&target.startsWith(baselineRoot+path.sep)?
    path.join(root,path.relative(baselineRoot,target)):target);}};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,
  target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText,ctx,{filename:file});return mod.exports;
}
const W=load(root+'/edit/engine/WorkerCore.ets'),{processPixels}=load(root+'/edit/engine/ProcessWorker.ets');
const {ColorAdjustments,CurveAnchor}=load(root+'/edit/models/Adjustment.ets');
const {ColorMatrixBuilder}=load(root+'/edit/engine/ColorMatrixBuilder.ets');
const {parseLutText}=load(root+'/edit/models/LutLibrary.ets');
const {GpuShaderBridge:G}=load(root+'/edit/engine/GpuShaderBridge.ets');
const {EditSession}=load(root+'/edit/models/EditSession.ets');
function adj(changes={}){const a=Object.assign(new ColorAdjustments(),changes);for(const k of ['toneCurvePoints','redCurvePoints','greenCurvePoints','blueCurvePoints'])a[k]=a[k].map(p=>[p.x,p.y]);return a;}
function layer(changes={},other={}){return {visible:true,opacity:1,blendMode:0,adjustments:adj(changes),maskAdjustments:adj(),mask:null,maskBuffer:null,...other};}
function params(pixels,w,h,layers,other={}){return {source:pixels.buffer,width:w,height:h,layers,luts:[],cropLeft:0,cropTop:0,cropRight:1,cropBottom:1,rotation:0,flipH:false,flipV:false,applyGeometry:false,ignoreCrop:false,...other};}
const byte=v=>Math.round(Math.max(0,Math.min(255,v)));
const linear=v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4;
const encoded=v=>Math.max(0,Math.min(1,v<=.0031308?v*12.92:1.055*v**(1/2.4)-.055));
const results=[];
function check(name,fn){fn();results.push(name);console.log('PASS '+name);}
check('linear-light exposure and joint white balance',()=>{
 for(const exposure of [-1,-.5,.5,1]){
  const a=adj({exposure});assert(W.hasAdvancedAdjustments(a));assert(W.isIdentity(W.buildMatrix(a)));
  assert(ColorMatrixBuilder.isIdentity(ColorMatrixBuilder.build(Object.assign(new ColorAdjustments(),{exposure}))));
  for(const v of [0,3,12,30,80,128,200,255]){const p=new Uint8ClampedArray([v,v,v,231]);W.applyAdvancedBand(p,a,0,4,1,1);
   const expected=byte(encoded(linear(v/255)*2**(2*exposure))*255);assert.deepStrictEqual(Array.from(p),[expected,expected,expected,231]);}
 }
 const a=adj({exposure:.5,temperature:1,tint:-.4});const p=new Uint8ClampedArray([200,150,200,255]);
 // tint is the green/magenta axis: positive = green (slider right is green).
 // This reference is written from the documented model, not by replaying the
 // implementation, so a sign or scale regression still fails here.
 const warmth=a.temperature*.22,green=a.tint*.24,gains=[Math.exp(warmth-green*.5),Math.exp(green),Math.exp(-warmth-green*.5)];
 const norm=1/(gains[0]*.2126+gains[1]*.7152+gains[2]*.0722);
 const expected=Array.from(p);for(let c=0;c<3;c++)expected[c]=byte(encoded(linear(p[c]/255)*2*gains[c]*norm)*255);
 W.applyAdvancedBand(p,a,0,4,1,1);assert.deepStrictEqual(Array.from(p),expected);
});
check('fast/general curve parity without intermediate byte rounding',()=>{
 const points=[[0,0],[.11,.02],[.31,.5],[.76,.9],[1,1]];
 for(const changes of [{toneCurvePoints:points.map(p=>new CurveAnchor(...p)),curveRed:.8,curveBlue:-.6},
  {toneCurve:.7,curveGreen:.9,exposure:.35}]){
  const fast=adj(changes),general=adj({...changes,gradingGlobalHue:123});
  const p=new Uint8ClampedArray(256*4);for(let i=0;i<256;i++)p.set([i,255-i,(i*73)%256,255],i*4);
  const q=p.slice();W.applyAdvancedBand(p,fast,0,p.length,256,1);W.applyAdvancedBand(q,general,0,q.length,256,1);
  assert.deepStrictEqual(p,q,'an inert advanced flag must not change curve output');
 }
});
check('fast/general parity covers every byte input over 125 exposure/curve combinations',()=>{
 for(const exposure of [-1,-.4,0,.35,1])for(const toneCurve of [-1,-.3,0,.5,1])for(const channel of [-1,-.6,0,.45,1]){
  const changes={exposure,toneCurve,curveRed:channel,curveGreen:-channel,curveBlue:channel*.7};
  const p=new Uint8ClampedArray(256*4);for(let i=0;i<256;i++)p.set([i,255-i,(i*73)%256,255],i*4);
  const q=p.slice();W.applyAdvancedBand(p,adj(changes),0,p.length,256,1);
  W.applyAdvancedBand(q,adj({...changes,gradingGlobalHue:123}),0,q.length,256,1);
  assert.deepStrictEqual(p,q,'256 entries enumerate all byte inputs; an inert advanced flag must be identical');
 }
});
// The baseline snapshot was a gitignored, one-off artefact created during the
// 2026-10-03 audit. It was removed from this workspace by an external cleanup
// after 2026-10-18 12:57 and cannot be recovered from git (analysis/ is
// ignored and the repository only has the initial + current commits).
// Never substitute the current builder for the baseline: that would make this
// group tautological. Skip it loudly and keep the other eleven groups running.
const baselineBuilder = path.resolve('analysis/color-audit-baseline-20261003/entry/src/main/ets/edit/engine/ColorMatrixBuilder.ets');
const baselineWorker = path.resolve('analysis/color-audit-baseline-20261003/entry/src/main/ets/edit/engine/WorkerCore.ets');
const baselineAvailable = fs.existsSync(baselineBuilder) && fs.existsSync(baselineWorker);
if (baselineAvailable) check('baseline matrix applies contrast before encoded exposure, not the reverse',()=>{
 const {ColorMatrixBuilder:Old}=load(baselineBuilder);
 const oldWorker=load(baselineWorker);
 const contrast=.4,exposure=-.5,brightness=.125,gain=2**(2*exposure),cf=1+contrast*.5;
 const changes={contrast,exposure,brightness,saturation:0,hue:0},matrix=Old.build(changes);
 assert.deepStrictEqual(Array.from(oldWorker.buildMatrix(adj(changes))),Array.from(matrix));
 const current=ColorMatrixBuilder.build(Object.assign(new ColorAdjustments(),changes));
 for(const v of [32,64,96,128,192]){
  const affine=cf*(v+brightness*64)+(1-cf)*127.5;
  assert(Math.abs(matrix[0]*v+matrix[4]-gain*affine)<1e-5);
  assert(Math.abs(current[0]*v+current[4]-affine)<1e-5);
  const pixel=new Uint8ClampedArray([v,v,v,255]);processPixels(params(pixel,1,1,[layer(changes)]));
  const expected=byte(encoded(linear(byte(affine)/255)*gain)*255);
  assert.deepStrictEqual(Array.from(pixel),[expected,expected,expected,255]);
 }
 const oldCorrect=matrix[0]*96+matrix[4];
 const reversed=cf*(96*gain+brightness*64)+(1-cf)*127.5;
 assert(Math.abs(oldCorrect-reversed)>5,'the fixture must distinguish matrix multiplication directions');
 assert.strictEqual(typeof ColorMatrixBuilder.exposureMatrix,'undefined','dead exposure helper must stay removed');
});
else console.log('SKIP baseline matrix ordering group: analysis/color-audit-baseline-20261003 is missing '+
 '(gitignored one-off snapshot, removed by an external cleanup and not recoverable from git); '+
 'this one group is NOT covered. The other groups still run.');

check('creative blue-primary hue changes red and green without requiring a blue diagonal term',()=>{
 const p=new Uint8ClampedArray([70,100,140,255]),input=p.slice();
 W.applyAdvancedBand(p,adj({calibrationBlueHue:1}),0,4,1,1);
 assert.deepStrictEqual(Array.from(p),[byte(70-140*.07),byte(100-140*.07),140,255]);
 assert.notStrictEqual(p[0],input[0]);assert.notStrictEqual(p[1],input[1]);
});
check('basic hue rotation preserves neutrals and unclipped Rec.709 luminance',()=>{
 for(const hue of [-180,-90,-30,0,30,90,180]){
  const matrix=W.buildMatrix(adj({hue})),other=ColorMatrixBuilder.hueMatrix(hue);
  assert.deepStrictEqual(Array.from(matrix),Array.from(other));
  for(const grey of [0,8,64,128,200,255]){
   const p=new Uint8ClampedArray([grey,grey,grey,219]);
   processPixels(params(p,1,1,[layer({hue})]));assert.deepStrictEqual(Array.from(p),[grey,grey,grey,219]);
  }
  const input=[.32,.43,.53],weights=[.2126,.7152,.0722];
  const output=[0,1,2].map(row=>input.reduce((n,v,c)=>n+matrix[row*5+c]*v,0));
  const luma=x=>x.reduce((n,v,c)=>n+weights[c]*v,0);
  assert(Math.abs(luma(input)-luma(output))<1e-7,'hue matrix must conserve unclipped luminance');
 }
});
const cubeRows=Array.from({length:8},(_,i)=>`${i&1} ${(i>>1)&1} ${(i>>2)&1}`).join('\n');
const cube='LUT_3D_SIZE 2\n'+cubeRows+'\n';
check('strict LUT dimensions, domains, rows and direct worker validation',()=>{
 assert(parseLutText(cube,'fixture.cube'));
 for(const text of [cube.replace('SIZE 2','SIZE 2x'),cube.replace('SIZE 2','SIZE 2.5'),
  cube.replace('SIZE 2','SIZE 129'),'DOMAIN_MIN 0 0\n'+cube,'DOMAIN_MAX 0 1 1\n'+cube,
  cube.replace('0 0 0','NaN 0 0'),cube.replace('0 0 0','0 Inf 0'),cube+'1 1 1\n',
  'LUT_1D_SIZE 2\n'+cube,cube+'0 0\n'])assert.strictEqual(parseLutText(text,'fixture.cube'),null);
 const table=parseLutText(cube,'fixture.cube').table;
 const lut={...table,enabled:true,intensity:1};
 for(const bad of [{...lut,values:lut.values.slice(1)},{...lut,intensity:NaN},{...lut,domainMax:[0,1,1]},
  {...lut,values:lut.values.map((v,i)=>i===4?Infinity:v)}]){
  assert.throws(()=>W.applyLutStack(new Uint8ClampedArray([50,80,90,255]),[bad]),/LUT/);
 }
});
check('extended LUT output blends before clipping and custom input domains stay GPU eligible',()=>{
 const extended=parseLutText('LUT_3D_SIZE 2\n'+Array(8).fill('1.5 1.5 1.5').join('\n'),'extended.cube').table;
 const p=new Uint8ClampedArray([51,51,51,255]);W.applyLutStack(p,[{...extended,enabled:true,intensity:.25}]);
 assert.deepStrictEqual(Array.from(p),[134,134,134,255]);
 const s=new EditSession();s.layers=[];
 function stack(table){return [{enabled:true,intensity:.25,lut:{table}}];}
 s.lutStack=stack(extended);const extendedPasses=G.buildPasses(s,1,1);
 assert(extendedPasses&&extendedPasses.length===1,'RGBA16F GPU atlas must preserve extended outputs');
 assert.strictEqual(extendedPasses[0].lut.byteLength,8*4*2,'a 2^3 LUT is 8 RGBA16F texels');
 const extendedHalf=new Uint16Array(extendedPasses[0].lut);
 assert.strictEqual(extendedHalf[0],0x3e00,'1.5 must encode as half-float 0x3e00, not clip to 1.0');
 assert.strictEqual(extendedHalf[3],0x3c00,'the unused alpha channel must be 1.0');
 const domain=parseLutText('DOMAIN_MIN -.2 -.1 0\nDOMAIN_MAX .8 .9 1.2\n'+cube,'domain.cube').table;
 s.lutStack=stack(domain);const passes=G.buildPasses(s,1,1);assert(passes&&passes.length===1);
 assert.deepStrictEqual(Array.from(passes[0].lutDomainMin),[-.2,-.1,0]);
 assert.deepStrictEqual(Array.from(passes[0].lutDomainScale),[1,1,1/1.2]);
 s.lutStack[0].intensity=NaN;assert.strictEqual(G.buildPasses(s,1,1),null);
 const narrow=parseLutText('DOMAIN_MIN -1e-8 -1e-8 -1e-8\nDOMAIN_MAX 1e-8 1e-8 1e-8\n'+cube,'narrow.cube').table;
 const black=new Uint8ClampedArray([0,0,0,255]);W.applyLutStack(black,[{...narrow,enabled:true,intensity:1}]);
 assert.deepStrictEqual(Array.from(black),[128,128,128,255],'a valid small domain must not be widened by an epsilon');
});
function reference(input,w,h,layers,viewport){
 const result=input.slice();
 for(const l of layers){const matrix=W.buildMatrix(l.adjustments),maskMatrix=W.buildMatrix(l.maskAdjustments);
  const base=result.slice(),adjusted=result.slice(),maskAdjusted=result.slice();
  W.applyLayerBandFull(result,{matrix:W.isIdentity(matrix)?null:matrix,hasAdvanced:W.hasAdvancedAdjustments(l.adjustments),
   adjustments:l.adjustments,maskMatrix:W.isIdentity(maskMatrix)?null:maskMatrix,maskAdjustments:l.maskAdjustments,
   hasMaskAdjustments:l.maskBuffer!==null&&(W.hasAdvancedAdjustments(l.maskAdjustments)||!W.isIdentity(maskMatrix)),
   mask:l.maskBuffer?new Uint8ClampedArray(l.maskBuffer):null,base,adjusted,maskAdjusted,opacity:l.opacity,
   blendMode:l.blendMode,width:w,height:h,viewport},0,result.length);
 }return result;
}
check('serial band output equals full-frame reference across masks, blend modes and spatial coordinates',()=>{
 const w=321,h=257,p=new Uint8ClampedArray(w*h*4),mask=new Uint8ClampedArray(w*h);
 for(let i=0;i<w*h;i++){p.set([i%256,(i*7)%256,(i*11)%256,100+i%156],i*4);mask[i]=(i*13)%256;}
 const layers=[layer({exposure:.2,shadows:.4}),layer({brightness:.1,contrast:-.3},{opacity:.63,blendMode:1,maskBuffer:mask.buffer}),
  layer({curveRed:.5,vignetteAmount:-.4,grainAmount:.3},{opacity:.7,blendMode:3,maskBuffer:mask.buffer,
    maskAdjustments:adj({temperature:.7,shadows:-.2,grainAmount:.15})})];
 const viewport=[53,24,2.2,2.4,1024,768],expected=reference(p,w,h,layers,viewport);
 const actual=new Uint8ClampedArray(processPixels(params(p,w,h,layers,{viewport})).buffer);
 assert.deepStrictEqual(actual,expected);
});
check('local legacy adjustments preserve global result and consume feather alpha once',()=>{
 const p=new Uint8ClampedArray([70,100,140,255]),mask=new Uint8ClampedArray([128]);
 const result=processPixels(params(p,1,1,[layer({brightness:.125},{maskBuffer:mask.buffer,maskAdjustments:adj({brightness:.25})})]));
 const expected=[byte(78+16*128/255),byte(108+16*128/255),byte(148+16*128/255),255];
 assert.deepStrictEqual(Array.from(new Uint8ClampedArray(result.buffer)),expected);
});
check('RGB scratch is bounded independently of image size and layer count',()=>{
 const w=400,h=300,p=new Uint8ClampedArray(w*h*4);p.fill(80);
 allocations.length=0;const out=processPixels(params(p,w,h,Array.from({length:10},()=>layer({brightness:.015}))));
 assert.strictEqual(out.buffer,p.buffer,'owned worker source should be returned without another full-frame copy');
 assert.deepStrictEqual(allocations.filter(x=>x.bytes>1024),Array(3).fill({kind:'scratch',bytes:32768*4}));
});
async function main(){
 const {ImageProcessor:P}=load(root+'/edit/engine/ImageProcessor.ets');
 const {Layer}=load(root+'/edit/models/Layer.ets'),{MaskState,MaskType}=load(root+'/edit/models/Mask.ets');
 const w=321,h=257,pixels=new Uint8ClampedArray(w*h*4);for(let i=0;i<w*h;i++)pixels.set([i%256,(i*7)%256,(i*11)%256,255],i*4);
 const s=new EditSession();s.layers=[new Layer('legacy-fallback'),new Layer('second')];s.rotation=270;
 s.cropLeft=.1;s.cropRight=.8;s.layers[0].adjustments.brightness=.13;s.layers[0].adjustments.exposure=.2;
 s.layers[0].mask=new MaskState();s.layers[0].mask.type=MaskType.LINEAR_GRADIENT;
 s.layers[0].maskAdjustments.brightness=.2;s.layers[0].maskAdjustments.temperature=.3;
 s.layers[0].migrateMask=()=>{}; // Deliberately exercise the unmigrated compatibility branch.
 s.layers[1].adjustments.curveRed=.5;s.layers[1].adjustments.shadows=.3;s.layers[1].opacity=.7;
 const expected=processPixels(P.buildWorkerParams(s,pixels.buffer.slice(0),w,h));
 const fallback=await P.renderToBuffer({readPixelsToBuffer:async b=>new Uint8Array(b).set(pixels)},w,h,s,true,()=>false,false,pixels.buffer,true);
 assert(fallback);assert.strictEqual(fallback.width,expected.width);assert.strictEqual(fallback.height,expected.height);
 assert.deepStrictEqual(Array.from(fallback.pixels),Array.from(new Uint8ClampedArray(expected.buffer)));
 results.push('main-thread forced fallback parity');console.log('PASS forced main-thread fallback matches worker including legacy local masks, curves and geometry');
 if(process.argv.includes('--large')){
 const w=9000,h=5000,p=new Uint8ClampedArray(w*h*4);p.fill(80);const layers=Array.from({length:10},()=>layer({brightness:.015}));
 allocations.length=0;const start=performance.now();const out=processPixels(params(p,w,h,layers));
 const rgbScratch=allocations.filter(x=>x.bytes>1024);assert.deepStrictEqual(rgbScratch,Array(3).fill({kind:'scratch',bytes:32768*4}));
 for(const index of [0,4*1234567,p.length-4])assert.deepStrictEqual(Array.from(new Uint8ClampedArray(out.buffer,index,4)),[90,90,90,80]);
 const measurement={pixels:w*h,layers:10,elapsedMs:Math.round(performance.now()-start),rgbaBytes:p.byteLength,
  rgbScratchBytes:rgbScratch.reduce((n,x)=>n+x.bytes,0),rssBytes:process.memoryUsage().rss};
 fs.mkdirSync('analysis',{recursive:true});fs.writeFileSync('analysis/color-large-image-20261003.json',JSON.stringify(measurement,null,2));console.log(measurement);
 }
 console.log(`PASS ${results.length} colour audit regression groups` +
  (baselineAvailable ? '' : ' (1 baseline-dependent group SKIPPED: snapshot missing, coverage reduced)'));
}
main().catch(e=>{console.error(e);process.exitCode=1;});
