// Smoke verification for the two modules whose own suites were not delivered.
// This is deliberately NOT a full suite: it establishes exports, identity,
// a non-trivial effect, alpha/finiteness and determinism, so the modules can be
// described accurately. It does NOT establish preview/export parity (nothing
// imports them yet) and it does not cover frequency separation, dehaze
// recovery quality or PatchMatch texture quality in depth.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),cache=new Map();
function load(file){
 file=path.resolve(file);if(cache.has(file))return cache.get(file).exports;const mod={exports:{}};cache.set(file,mod);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,
  target:ts.ScriptTarget.ES2021}}).outputText,
 {module:mod,exports:mod.exports,console:{info(){},warn(){},error:console.error},Math,Number,Map,Set,
  Float32Array,Int32Array,Uint8Array,Uint8ClampedArray,ArrayBuffer,
  // LocalContrastCore dispatches to libvivid_detail.so through ./NativeDetail.
  // The .so is stubbed absent, so every call still runs the ArkTS reference this
  // suite exercises; the wrapper reports itself unavailable and falls back.
  require:name=>{
   if(name.endsWith('.so'))return{default:{}};
   if(name.startsWith('.'))return load(path.resolve(path.dirname(file),name+'.ets'));
   throw new Error('unexpected import '+name);}},{filename:file});
 return mod.exports;
}
const lc=load(root+'/edit/engine/LocalContrastCore.ets');
const cf=load(root+'/edit/engine/ContentFillCore.ets');
let checks=0;function ok(c,m){checks++;assert(c,m);}
function img(w,h,fn){const b=new Uint8ClampedArray(w*h*4);for(let y=0;y<h;y++)for(let x=0;x<w;x++){
 const v=fn(x,y),i=(y*w+x)*4;b[i]=v[0];b[i+1]=v[1];b[i+2]=v[2];b[i+3]=255;}return b;}
function same(a,b){if(a.length!==b.length)return false;for(let i=0;i<a.length;i++)if(a[i]!==b[i])return false;return true;}
function finite(b){for(let i=0;i<b.length;i++)if(!Number.isFinite(b[i]))return false;return true;}
function alphaKept(src,out){for(let i=3;i<src.length;i+=4)if(src[i]!==out[i])return false;return true;}
function meanAbsDiff(a,b){let s=0;for(let i=0;i<a.length;i++)s+=Math.abs(a[i]-b[i]);return s/a.length;}

// --- LocalContrastCore ----------------------------------------------------
const W=64,H=64;
const textureImg=img(W,H,(x,y)=>((x>>1)+(y>>1))%2?[200,200,200]:[60,60,60]); // fine checkerboard
const gradientImg=img(W,H,(x,y)=>{const v=Math.round(40+175*x/(W-1));return[v,v,v];});
const lcDef=lc.localContrastDefaults();
ok(lc.localContrastIsIdentity(lcDef),'local contrast defaults report identity');
ok(lc.textureRadius(2048)>=1&&Number.isInteger(lc.textureRadius(2048)),'texture radius is an integer >= 1');
ok(lc.clarityRadius(2048)>=2&&Number.isInteger(lc.clarityRadius(2048)),'clarity radius is an integer >= 2');
ok(lc.clarityRadius(2048)>lc.textureRadius(2048),'clarity works at a coarser scale than texture');
ok(lc.clarityRadius(8192)>=lc.clarityRadius(2048)&&lc.textureRadius(8192)>=lc.textureRadius(2048),
 'radii grow with the frame long edge so preview and export agree');
ok(lc.sharpenRadiusPixels(2048,0)>=1,'sharpen radius never falls below one pixel');
const idOut=lc.applyLocalContrast(textureImg,W,H,lcDef,2048);
ok(same(idOut,textureImg),'an identity parameter set returns byte-identical pixels');
ok(same(textureImg,img(W,H,(x,y)=>((x>>1)+(y>>1))%2?[200,200,200]:[60,60,60])),'the input buffer is not mutated');
function stage(over,source){const p=Object.assign(lc.localContrastDefaults(),over);
 return{params:p,out:lc.applyLocalContrast(source||textureImg,W,H,p,2048)};}
const tex=stage({texture:0.8});
const cla=stage({clarity:0.8},gradientImg);
const cleanGradient=img(W,H,(x,y)=>{const v=Math.round(60+120*x/(W-1));return[v,v,v];});
const dhz=stage({dehaze:0.7},cleanGradient);
const shp=stage({sharpenAmount:0.9,sharpenRadius:0.5,sharpenDetail:0.4});
ok(!same(tex.out,textureImg),'texture changes a fine-detail image (not a stub)');
ok(!same(cla.out,gradientImg),'clarity changes a broad-gradient image (not a stub)');
ok(!same(dhz.out,cleanGradient),'dehaze changes an image (not a stub)');
ok(!same(shp.out,textureImg),'sharpening changes an image (not a stub)');
for(const s of[tex,cla,dhz,shp])ok(finite(s.out),'no NaN or Infinity in the output');
ok(alphaKept(textureImg,tex.out),'texture preserves alpha');
ok(alphaKept(gradientImg,cla.out),'clarity preserves alpha');
ok(alphaKept(cleanGradient,dhz.out),'dehaze preserves alpha');
ok(alphaKept(textureImg,shp.out),'sharpening preserves alpha');
// clarity must be weighted away from the extremes: a midtone step should move
// more than an equally strong step placed hard against black or white.
const midStep=img(W,H,(x)=>x<W/2?[100,100,100]:[150,150,150]);
const darkStep=img(W,H,(x)=>x<W/2?[0,0,0]:[40,40,40]);
const brightStep=img(W,H,(x)=>x<W/2?[215,215,215]:[255,255,255]);
const clarityParams=Object.assign(lc.localContrastDefaults(),{clarity:0.8});
const moveMid=meanAbsDiff(midStep,lc.applyLocalContrast(midStep,W,H,clarityParams,2048));
const moveDark=meanAbsDiff(darkStep,lc.applyLocalContrast(darkStep,W,H,clarityParams,2048));
const moveBright=meanAbsDiff(brightStep,lc.applyLocalContrast(brightStep,W,H,clarityParams,2048));
ok(moveMid>moveDark&&moveMid>moveBright,
 'clarity is midtone-weighted: an equal step moves more at midtones ('+moveMid.toFixed(3)+
 ') than at black ('+moveDark.toFixed(3)+') or white ('+moveBright.toFixed(3)+')');
// masking must protect a flat field while still sharpening an edge.
const flat=img(W,H,()=>[128,128,128]);
const maskedFlat=lc.applyLocalContrast(flat,W,H,
 Object.assign(lc.localContrastDefaults(),{sharpenAmount:1,sharpenMasking:1}),2048);
ok(meanAbsDiff(flat,maskedFlat)<0.75,'heavy masking leaves a flat field essentially untouched');
const edge=img(W,H,(x)=>x<W/2?[40,40,40]:[210,210,210]);
const sharpEdge=lc.applyLocalContrast(edge,W,H,
 Object.assign(lc.localContrastDefaults(),{sharpenAmount:1,sharpenRadius:0.5}),2048);
let before=0,after=0;
for(let y=0;y<H;y++){const i=(y*W+W/2-1)*4,j=(y*W+W/2)*4;
 before=Math.max(before,edge[j]-edge[i]);after=Math.max(after,sharpEdge[j]-sharpEdge[i]);}
ok(after>before,'sharpening increases edge contrast ('+before+' -> '+after+')');
ok(same(lc.applyLocalContrast(textureImg,W,H,Object.assign(lc.localContrastDefaults(),{texture:0.5}),2048),
 lc.applyLocalContrast(textureImg,W,H,Object.assign(lc.localContrastDefaults(),{texture:0.5}),2048)),
 'local contrast is deterministic');

// --- ContentFillCore -----------------------------------------------------
const CW=48,CH=48;
const cfDef=cf.contentFillDefaults();
ok(cfDef.patchRadius>=1&&cfDef.iterations>=1,'content fill defaults are usable');
const canvas=img(CW,CH,()=>[30,30,30]);
for(let y=8;y<16;y++)for(let x=8;x<16;x++){const i=(y*CW+x)*4;canvas[i]=250;canvas[i+1]=10;canvas[i+2]=10;}
const canvasCopy=Uint8ClampedArray.from(canvas);
const mark={centreX:0.75,centreY:0.75,radius:0.12,feather:0.3,opacity:1,sourceX:0.25,sourceY:0.25,aligned:true};
const cloned=cf.cloneStamp(canvas,CW,CH,[mark]);
ok(same(canvas,canvasCopy),'clone stamp does not mutate its input');
ok(!same(cloned,canvas),'clone stamp changes the destination');
const dc=((Math.round(0.75*CH))*CW+Math.round(0.75*CW))*4;
ok(cloned[dc]>200&&cloned[dc+1]<60,'the source pattern actually appears at the destination ('+
 cloned[dc]+','+cloned[dc+1]+','+cloned[dc+2]+')');
const noOpacity=cf.cloneStamp(canvas,CW,CH,[Object.assign({},mark,{opacity:0})]);
ok(same(noOpacity,canvas),'clone stamp at zero opacity leaves the image identical');
ok(finite(cloned)&&alphaKept(canvas,cloned),'clone stamp output is finite and keeps alpha');
// out-of-range coordinates must clamp rather than read out of bounds
const clamped=cf.cloneStamp(canvas,CW,CH,[Object.assign({},mark,{centreX:5,centreY:-3,sourceX:9,sourceY:-9})]);
ok(finite(clamped),'clone stamp clamps out-of-range coordinates without producing NaN');

const stripes=img(CW,CH,(x,y)=>((x+y)%4<2)?[180,140,90]:[70,50,30]);
const hole=new Uint8Array(CW*CH);
for(let y=18;y<30;y++)for(let x=18;x<30;x++)hole[y*CW+x]=255;
// Counting changed bytes is a poor discriminator here: the stripe texture has
// only two values, so a BETTER fill matches the original more often. Paint the
// hole with a magenta sentinel that cannot occur in the source instead, then
// require that no sentinel pixel survives.
const holeInput=Uint8ClampedArray.from(stripes);
for(let y=18;y<30;y++)for(let x=18;x<30;x++){const i=(y*CW+x)*4;holeInput[i]=255;holeInput[i+1]=0;holeInput[i+2]=255;}
const filled=cf.contentAwareFill(holeInput,CW,CH,hole,cfDef);
ok(!same(filled,holeInput),'content-aware fill changes the masked region');
ok(finite(filled)&&alphaKept(holeInput,filled),'fill output is finite and keeps alpha');
const emptyHole=new Uint8Array(CW*CH);
ok(same(cf.contentAwareFill(stripes,CW,CH,emptyHole,cfDef),stripes),'an empty mask leaves the image byte-identical');
let outsideIntact=true,sentinelLeft=0;
for(let y=0;y<CH;y++)for(let x=0;x<CW;x++){
 const i=(y*CW+x)*4,inHole=hole[y*CW+x]>0;
 if(!inHole){if(filled[i]!==holeInput[i]||filled[i+1]!==holeInput[i+1]||filled[i+2]!==holeInput[i+2])outsideIntact=false;}
 else if(filled[i]===255&&filled[i+1]===0&&filled[i+2]===255)sentinelLeft++;
}
ok(outsideIntact,'fill never touches a pixel outside the mask');
ok(sentinelLeft===0,'every one of the 144 hole pixels is genuinely replaced (no sentinel survives)');
// Distinct seed must be able to differ; identical seed must be byte-identical.
ok(same(cf.contentAwareFill(stripes,CW,CH,hole,cfDef),filled),'fill is deterministic for a fixed seed');
ok(same(cf.cloneStamp(canvas,CW,CH,[mark]),cloned),'clone stamp is deterministic');
// anti-blur: a PatchMatch result must carry texture, not a smoothed average.
let variance=0,mean=0,n=0;
for(let y=18;y<30;y++)for(let x=18;x<30;x++){const v=filled[(y*CW+x)*4];mean+=v;n++;}
mean/=n;
for(let y=18;y<30;y++)for(let x=18;x<30;x++){const v=filled[(y*CW+x)*4];variance+=(v-mean)*(v-mean);}
variance/=n;
ok(variance>400,'the filled region retains texture rather than collapsing to an average (variance '+
 variance.toFixed(1)+')');

console.log('PASS local contrast: identity, non-trivial effect, midtone weighting, masking, alpha, finiteness, determinism');
console.log('PASS content fill: clone placement, empty-mask identity, outside-mask isolation, determinism, texture retention');
console.log('NOTE this is a smoke check, not the full suite: frequency separation, dehaze recovery quality');
console.log('     and PatchMatch quality bounds are NOT established here, and nothing renders through these yet.');
console.log(checks+' checks passed');
