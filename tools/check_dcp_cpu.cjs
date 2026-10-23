const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/ohpm/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets');
function load(file){const ctx={exports:{},Math,Number,Map,Float32Array,Uint8Array,ArrayBuffer,console,require(name){if(name.includes('DcpCpu'))return engine;if(name.includes('CameraProfileFiles'))return {CAMERA_PROFILE_FILES:[]};if(name==='@kit.ArkTS')return {};if(name.includes('DcpWorker'))return {};if(name.includes('DcpProfileParser'))if(name==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
      if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file),name+'.ets'));throw Error(name);}};vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,ctx);return ctx.exports;}
const engine=load(path.join(root,'edit/engine/DcpCpu.ets'));
const parser=load(path.join(root,'edit/utils/CameraProfiles.ets'));
parser.CameraProfiles.initialize({getRawFileContentSync:p=>new Uint8Array(fs.readFileSync(p))});
const near=(a,b,e=1e-7)=>assert(Math.abs(a-b)<e,`${a} != ${b}`);
const I=[1,0,0,0,1,0,0,0,1];
const fixture={color1:I,color2:I,forward1:[],forward2:[],illuminant1:17,illuminant2:21,hueDims:[],hue1:[],hue2:[],hueEncoding:0,lookDims:[],look:[],lookEncoding:0,curve:[],exposure:0};
near(engine.dcpWeight(2856,2856,6504),1);near(engine.dcpWeight(6504,2856,6504),0);
const mid=2/(1/2856+1/6504);near(engine.dcpWeight(mid,2856,6504),.5);
for(const k of [2856,mid,6504]){
 const c=engine.prepareDcp(fixture,[1,1,1],k,0);
 const rgb=engine.dcpPixel(c.neutral,c);
 assert(Math.max(...rgb)-Math.min(...rgb)<.002,'matrix-only neutral must be neutral');
}
const identityTable=[];for(let i=0;i<8;i++)identityTable.push(0,1,1);
for(const encoding of [0,1])for(const color of [[.3,.7,.1],[.8,.2,.4],[0,0,0],[.5,.5,.5]]){
 const out=engine.dcpTable(color,[2,2,2],identityTable,encoding);out.forEach((v,i)=>near(v,color[i],1e-6));
}
const rotate=[];for(let i=0;i<8;i++)rotate.push(120,1,1);
const green=engine.dcpTable([1,0,0],[2,2,2],rotate,0);near(green[0],0);near(green[1],1);near(green[2],0);
const ordered=[];for(let v=0;v<2;v++)for(let h=0;h<2;h++)for(let s=0;s<2;s++)ordered.push(0,1,.5+v*.5);
near(engine.dcpTable([.5,0,0],[2,2,2],ordered,0)[0],.375);
const tone=engine.dcpTone([.2,.4,.6],[0,0,.5,.25,1,1]);near(tone[0],.1);near(tone[2],.4);near(tone[1],.25);
const maps={...fixture,hueDims:[2,2,2],hue1:identityTable,hue2:rotate};
const plan=engine.buildDcpRenderPlan({...maps,lookDims:[2,2,2],look:identityTable,curve:[0,0,.5,.4,1,1]},[.5,1,.65],5000,0);
const privatePlan=engine.cloneDcpRenderPlan(plan);
const transferred=structuredClone(privatePlan,{transfer:[privatePlan.m.buffer,privatePlan.display.buffer,privatePlan.tone.buffer,privatePlan.hue.data.buffer,privatePlan.look.data.buffer]});
assert(plan.m.byteLength>0&&plan.tone.byteLength>0&&plan.hue.data.byteLength>0&&plan.look.data.byteLength>0,'TaskPool band transfer must not detach cached render tables');
const linear=new Float32Array([.1,.15,.08,.4,.3,.2]);
assert.deepStrictEqual(Buffer.from(engine.renderDcpPlan(linear.buffer,plan)),Buffer.from(engine.renderDcpPlan(linear.buffer,transferred)),'private plan preserves DCP colour');
near(engine.prepareDcp(maps,[1,1,1],2856,0).hue[0],0);
near(engine.prepareDcp(maps,[1,1,1],mid,0).hue[0],60);
near(engine.prepareDcp(maps,[1,1,1],6504,0).hue[0],120);
const plain=engine.prepareDcp(fixture,[1,1,1],5000,0);
const styled=engine.prepareDcp({...fixture,lookDims:[2,2,2],look:rotate},[1,1,1],5000,0);
assert.notDeepStrictEqual(engine.dcpPixel([.4,.2,.1],plain),engine.dcpPixel([.4,.2,.1],styled),'profile LookTable must change result');
assert.throws(()=>engine.renderDcp(new Float32Array([NaN,0,0]).buffer,fixture,[1,1,1],5000,0));
// Native supplies unbalanced RGB: a sensor-neutral patch must stay gray after
// ForwardMatrix processing, and changing Kelvin must affect a fixed sample.
const forwardFixture={...fixture,color2:[],forward1:[.96422,0,0,0,1,0,0,0,.82521]};
const shotNeutral=[.5,1,.65];
const forwardContext=engine.prepareDcp(forwardFixture,shotNeutral,0,0);
const gray=engine.dcpPixel(shotNeutral.map(v=>v*.2),forwardContext);
assert(Math.max(...gray)-Math.min(...gray)<.0002,'ForwardMatrix must white-balance unbalanced sensor neutral');
const warm=engine.dcpPixel([.1,.2,.13],engine.prepareDcp(forwardFixture,shotNeutral,3000,0));
const cool=engine.dcpPixel([.1,.2,.13],engine.prepareDcp(forwardFixture,shotNeutral,7000,0));
assert(Math.max(...warm.map((v,i)=>Math.abs(v-cool[i])))>.01,'ForwardMatrix Kelvin must alter pixels');
const classic=engine.classicDcp(I), classicContext=engine.prepareDcp(classic,shotNeutral,0,0);
const classicGray=engine.dcpPixel([.1,.2,.13],classicContext);
classicGray.forEach(v=>near(v,.2,.0002));
const sample=new Float32Array(128*96*3);
for(let i=0;i<sample.length;i++)sample[i]=(i%101)/200;
const fast=new Uint8Array(engine.renderDcp(sample.buffer,classic,shotNeutral,0,0));
const encode=v=>v<=.0031308?12.92*v:1.055*Math.pow(v,1/2.4)-.055;
let maxByteError=0;
for(let i=0,j=0;i<sample.length;i+=3,j+=4){
 const rgb=engine.dcpPixel([sample[i],sample[i+1],sample[i+2]],classicContext);
 for(let ch=0;ch<3;ch++)maxByteError=Math.max(maxByteError,Math.abs(fast[j+ch]-Math.round(255*encode(Math.max(0,Math.min(1,rgb[ch]))))));
}
assert(maxByteError<=1,'matrix fast path must match reference');
console.log('PASS unbalanced neutral, ForwardMatrix Kelvin, classic white balance, fast/reference parity max='+maxByteError);
let count=0, rejected=[];const traces=[];
function walk(dir){for(const ent of fs.readdirSync(dir,{withFileTypes:true})){const file=path.join(dir,ent.name);if(ent.isDirectory())walk(file);else if(file.endsWith('.dcp')){
 const parsed=new parser.CameraProfile();parsed.path=file;parser.CameraProfiles.loadProfile(parsed);
 try{
  const p=parsed.cpuData();const t1=p.color2.length?engine.dcpIlluminant(p.illuminant1):2856,t2=p.color2.length?engine.dcpIlluminant(p.illuminant2):6504;
  const temperatures=[t1,2/(1/t1+1/t2),t2];let maxJump=0;
  for(const k of temperatures){
   const c=engine.prepareDcp(p,[.5,1,.65],k,0),next=engine.prepareDcp(p,[.5,1,.65],k+.01,0);
   for(const color of [[.1,.15,.08],[.4,.3,.2],[.01,.01,.01],[.8,.2,.1]]){
    const rgb=engine.dcpPixel(color,c),after=engine.dcpPixel(color,next);
    assert(rgb.every(Number.isFinite));maxJump=Math.max(maxJump,...rgb.map((v,i)=>Math.abs(v-after[i])));
   }
  }
  assert(maxJump<.002,`white-balance discontinuity ${file}: ${maxJump}`);
  const shot=engine.prepareDcp(p,[.5,1,.65],0,0);assert(Number.isFinite(shot.temperature));
  count++;traces.push({file,temperatures,maxJump,hue:p.hue1.length,look:p.look.length,curve:p.curve.length});
 }catch(e){rejected.push({file,error:String(e)});}
}}}
walk('entry/src/main/resources/rawfile/Camera');
fs.mkdirSync('tmp/dcp-cpu',{recursive:true});fs.writeFileSync('tmp/dcp-cpu/results.json',JSON.stringify({count,rejected,traces},null,2));
assert(count>0);assert.strictEqual(rejected.length,0,JSON.stringify(rejected.slice(0,4)));
console.log('PASS: reciprocal-temperature endpoints/midpoint, matrix-only neutral, HSV identity/encoding/order/hue rotation, film tone, profiles='+count+', finite output and WB continuity');
