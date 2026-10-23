// Process version: behaviour table, radius resolution, real pixel effect and
// sidecar/undo round-trip. Every image and sidecar here is synthetic.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),cache=new Map(),storage=new Map();
const dir=fs.mkdtempSync(path.resolve('tmp/process-version-'));
const fileIo={OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4,READ_ONLY:8},
 openSync:(p,f)=>({fd:fs.openSync(p,f===8?'r':'w')}),closeSync:f=>fs.closeSync(f.fd),
 writeSync:(fd,b)=>fs.writeSync(fd,Buffer.from(b)),readSync:(fd,b)=>fs.readSync(fd,new Uint8Array(b)),
 statSync:p=>typeof p==='number'?fs.fstatSync(p):fs.statSync(p)};
function load(file){
 file=path.resolve(file);if(cache.has(file))return cache.get(file).exports;const mod={exports:{}};cache.set(file,mod);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,
  target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText,
 {module:mod,exports:mod.exports,console:{info(){},warn(){},error:console.error},Math,Number,Date,Map,Set,Promise,ArrayBuffer,
 Uint8Array,Uint8ClampedArray,Float32Array,setTimeout,clearTimeout,Observed:c=>c,Concurrent:f=>f,
 AppStorage:{get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)},require:name=>{
  if(name==='@kit.CoreFileKit')return {fileIo};
  if(name==='@kit.ArkTS')return {util:{TextEncoder:{create:()=>({encodeInto:s=>new TextEncoder().encode(s)})},
   TextDecoder:{create:()=>({decodeToString:b=>new TextDecoder().decode(b)})}}};
  if(name.startsWith('@kit.'))return {};
  if(name==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
      if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file),name+'.ets'));
 }},{filename:file});return mod.exports;
}
const {EditSession}=load(root+'/edit/models/EditSession.ets');
const {Layer}=load(root+'/edit/models/Layer.ets');
const {EditSidecar}=load(root+'/edit/utils/EditSidecar.ets');
const pv=load(root+'/edit/models/ProcessVersion.ets');
const nr=load(root+'/edit/engine/NoiseReduction.ets');
let checks=0;function ok(c,m){checks++;assert(c,m);}

// --- 1. generation values and normalisation -------------------------------
ok(pv.PROCESS_VERSION_LEGACY===1&&pv.PROCESS_VERSION_CURRENT===2,'generations are 1 (legacy) and 2 (current)');
ok(pv.normalizeProcessVersion(1)===1,'generation 1 round-trips');
ok(pv.normalizeProcessVersion(2)===2,'generation 2 round-trips');
for(const bad of [0,-1,-3,3,99,NaN,Infinity,-Infinity,1.4,2.5,0.5]){
 ok(pv.normalizeProcessVersion(bad)===1,'unknown generation '+String(bad)+' resolves to LEGACY');
}
ok(pv.isKnownProcessVersion(1)&&pv.isKnownProcessVersion(2),'both shipped generations are known');
ok(!pv.isKnownProcessVersion(3)&&!pv.isKnownProcessVersion(1.5),'unshipped and fractional generations are unknown');

// --- 2. the behaviour table ----------------------------------------------
const legacyB=pv.processBehaviors(1),currentB=pv.processBehaviors(2),unknownB=pv.processBehaviors(99);
ok(legacyB.denoiseFixedRadius===2,'LEGACY pins the denoise radius to 2');
ok(currentB.denoiseFixedRadius===0,'CURRENT derives the radius from the frame (0 = no pin)');
ok(unknownB.denoiseFixedRadius===2,'an unrecognised generation resolves to the LEGACY behaviour');
ok(JSON.stringify(Object.keys(legacyB).sort())===JSON.stringify(Object.keys(currentB).sort()),
 'both generations expose the same behaviour fields, so no field is silently generation-specific');
ok(pv.legacyPinnedBehaviors().length>0,'the pinned behaviour list is non-empty and user-visible');
ok(pv.unversionedDefectFixes().length>=3,'the deliberately unversioned defect fixes are recorded, not forgotten');

// --- 3. the table drives the radius, and the radius is clamped ------------
ok(nr.denoiseSpatialRadius(1920,1080,legacyB.denoiseFixedRadius)===2,'LEGACY radius on a preview-sized frame');
ok(nr.denoiseSpatialRadius(1920,1080,currentB.denoiseFixedRadius)===2,'CURRENT radius on a preview-sized frame');
ok(nr.denoiseSpatialRadius(6000,4000,legacyB.denoiseFixedRadius)===2,'LEGACY stays at 2 on a large export');
ok(nr.denoiseSpatialRadius(6000,4000,currentB.denoiseFixedRadius)===5,'CURRENT reaches the cap on a large export');
ok(nr.denoiseSpatialRadius(6000,4000,99)===5,'a pinned radius above the cap is clamped');
ok(nr.denoiseSpatialRadius(6000,4000,1)===2,'a pinned radius below the floor is clamped');
let mono=true,seenMin=99,seenMax=0,prev=0;
for(let L=64;L<=12000;L+=32){
 const r=nr.denoiseSpatialRadius(L,64,0);
 if(r<prev||r<2||r>5)mono=false;
 prev=r;seenMin=Math.min(seenMin,r);seenMax=Math.max(seenMax,r);
}
ok(mono,'the derived radius is monotone non-decreasing in the long edge and stays within [2,5]');
ok(seenMin===2&&seenMax===5,'the derived radius actually spans 2..5 rather than sitting at one value');

// --- 4. the version changes pixels, and only where documented -------------
// A 2560px long edge is the first size where round(2*L/2048) reaches 3, so it
// is the smallest frame that separates the two generations. The frames are
// thin strips purely to keep the check fast; the kernel only needs the rows.
function noiseFrame(w,h){
 const b=new Uint8ClampedArray(w*h*4);let s=12345;
 for(let i=0;i<b.length;i+=4){
  s=(s*1103515245+12345)&0x7fffffff;const n=(s>>16)&0xff;
  b[i]=100+(n%41)-20;b[i+1]=110+((n>>2)%41)-20;b[i+2]=120+((n>>4)%41)-20;b[i+3]=255;
 }
 return b;
}
const settings={luminance:1.0,color:0.4,detail:0.5,colorDetail:0.5};
function run(w,h,fixed){
 const src=noiseFrame(w,h),dst=new Uint8ClampedArray(src.length);
 nr.denoiseRows(src,dst,w,h,settings,0,h,false,fixed);return dst;
}
const bigW=2560,bigH=64;
ok(nr.denoiseSpatialRadius(bigW,bigH,0)!==nr.denoiseSpatialRadius(bigW,bigH,legacyB.denoiseFixedRadius),
 'the chosen frame size straddles the radius rule');
const bigLegacy=run(bigW,bigH,legacyB.denoiseFixedRadius),bigCurrent=run(bigW,bigH,currentB.denoiseFixedRadius);
let diffBytes=0;for(let i=0;i<bigLegacy.length;i++)if(bigLegacy[i]!==bigCurrent[i])diffBytes++;
ok(diffBytes>0,'the generation changes pixels on a large frame (differing bytes: '+diffBytes+')');
const smallW=1920,smallH=64;
const smallLegacy=run(smallW,smallH,legacyB.denoiseFixedRadius),smallCurrent=run(smallW,smallH,currentB.denoiseFixedRadius);
let identical=true;for(let i=0;i<smallLegacy.length;i++)if(smallLegacy[i]!==smallCurrent[i]){identical=false;break;}
ok(identical,'preview-sized frames render identically under both generations, so the preview is not disturbed');

// --- 5. sidecar and undo round-trip through the real session --------------
function fresh(){const s=new EditSession();s.layers=[new Layer('synthetic')];return s;}
const a=fresh();
ok(a.processVersion===pv.PROCESS_VERSION_CURRENT,'a fresh session starts on the current generation');
const state=a.exportAdjustmentState();
ok(JSON.parse(state).processVersion===2,'the exported adjustment state carries the generation');
const raw=path.join(dir,'shot.rw2');
ok(EditSidecar.write(raw,state,dir),'the sidecar writes');
const reopened=fresh();
ok(reopened.importAdjustmentState(EditSidecar.read(raw,dir)),'the sidecar reads back');
ok(reopened.processVersion===2,'a current photo reopens on the current generation');
const explicit=JSON.parse(state);explicit.processVersion=1;
const oldOne=fresh();
ok(oldOne.importAdjustmentState(JSON.stringify(explicit)),'an explicit legacy sidecar imports');
ok(oldOne.processVersion===1,'an explicit legacy sidecar reopens as LEGACY');
const missing=JSON.parse(state);delete missing.processVersion;
const preVersion=fresh();
ok(preVersion.importAdjustmentState(JSON.stringify(missing)),'a sidecar written before process versions imports');
ok(preVersion.processVersion===pv.PROCESS_VERSION_LEGACY,
 'a sidecar with no generation field reopens as LEGACY, so an untouched old photo does not drift');
for(const bad of [99,0,-3,'1',null,1.5,[],{}]){
 const s2=JSON.parse(state);s2.processVersion=bad;
 const t=fresh();
 if(!t.importAdjustmentState(JSON.stringify(s2))){ok(false,'a corrupt generation must not abort the import: '+JSON.stringify(bad));continue;}
 ok(t.processVersion===pv.PROCESS_VERSION_LEGACY,'corrupt generation '+JSON.stringify(bad)+' resolves to LEGACY');
}
const u=fresh();u.processVersion=pv.PROCESS_VERSION_LEGACY;u.pushUndo();
u.processVersion=pv.PROCESS_VERSION_CURRENT;u.undo();
ok(u.processVersion===pv.PROCESS_VERSION_LEGACY,'undo restores the generation, so the migration is reversible');
u.redo();ok(u.processVersion===pv.PROCESS_VERSION_CURRENT,'redo restores the migrated generation');
const r=fresh();r.processVersion=pv.PROCESS_VERSION_LEGACY;r.reset();
ok(r.processVersion===pv.PROCESS_VERSION_CURRENT,'Reset moves the photo onto the current generation');

// --- 6. the behaviour table is the single source of truth -----------------
function etsFiles(base){
 const out=[];
 (function walk(d){
  for(const e of fs.readdirSync(d,{withFileTypes:true})){
   const p=path.join(d,e.name);
   if(e.isDirectory())walk(p);else if(e.name.endsWith('.ets'))out.push(p);
  }
 })(base);
 return out;
}
const offenders=[];
for(const f of etsFiles(root)){
 if(path.basename(f)==='ProcessVersion.ets')continue;
 const src=fs.readFileSync(f,'utf8');
 if(/[=!]==\s*PROCESS_VERSION_(LEGACY|CURRENT)/.test(src)||/[=!]==\s*processVersion\b/.test(src)){
  offenders.push(path.relative(root,f));
 }
}
ok(offenders.length===0,
 'no file outside ProcessVersion.ets branches on the generation (offenders: '+(offenders.join(', ')||'none')+')');
const model=fs.readFileSync(path.join(root,'edit/models/ProcessVersion.ets'),'utf8');
ok(/denoiseFixedRadius/.test(model)&&/PROCESS_VERSION_LEGACY/.test(model),
 'the decision lives in the behaviour table in the model module');
const worker=fs.readFileSync(path.join(root,'edit/engine/ProcessWorker.ets'),'utf8');
ok(/processBehaviors\(/.test(worker)&&/denoiseFixedRadius/.test(worker),
 'the pixel worker consumes the resolved behaviour instead of a version number');
ok(!/processVersion\s*===\s*\d/.test(worker),'the pixel worker holds no version-number comparison');
const reduction=fs.readFileSync(path.join(root,'edit/engine/NoiseReduction.ets'),'utf8');
ok(/fixedRadius/.test(reduction)&&!/processVersion/.test(reduction),
 'the filter takes a resolved radius and knows nothing about generations');

console.log('PASS process version: generation normalisation, behaviour table, radius resolution and clamping');
console.log('PASS process version changes pixels only at frame sizes the rule separates, and never on previews');
console.log('PASS sidecar round-trip, legacy defaulting, corrupt-value fallback, undo/redo and Reset');
console.log('PASS single-source-of-truth: no generation branching outside the behaviour table');
console.log(checks+' checks passed');
