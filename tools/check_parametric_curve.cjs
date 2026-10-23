// Parametric tone curve: identity, endpoints, monotonicity, region targeting,
// split behaviour, C1 continuity, saturation refinement. No images needed.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),cache=new Map();
function load(file){
 file=path.resolve(file);if(cache.has(file))return cache.get(file).exports;const mod={exports:{}};cache.set(file,mod);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,
  target:ts.ScriptTarget.ES2021}}).outputText,
 {module:mod,exports:mod.exports,console:{info(){},warn(){},error:console.error},Math,Number,Map,Set,
  Float32Array,Uint8Array,require:name=>{throw new Error('unexpected import '+name);}},{filename:file});
 return mod.exports;
}
const pc=load(root+'/edit/engine/ParametricCurveCore.ets');
let checks=0;function ok(c,m){checks++;assert(c,m);}
const N=pc.PARAMETRIC_LUT_SIZE;
// The table is a Float32Array, so the exact identity reference is the
// float32 rounding of i/(N-1), not the float64 value.
const ramp=i=>Math.fround(i/(N-1));
function params(over){const p=pc.parametricDefaults();Object.assign(p,over||{});return p;}
function isMonotone(lut){for(let i=1;i<lut.length;i++)if(lut[i]<lut[i-1])return false;return true;}
function isFiniteLut(lut){for(let i=0;i<lut.length;i++)if(!Number.isFinite(lut[i]))return false;return true;}
function deviation(lut){const d=new Float32Array(N);for(let i=0;i<N;i++)d[i]=lut[i]-ramp(i);return d;}
function peakIndex(d){let best=0,bi=0;for(let i=0;i<N;i++)if(d[i]>best){best=d[i];bi=i;}return bi;}
function highestSignificant(d,threshold){let hi=-1;for(let i=0;i<N;i++)if(Math.abs(d[i])>threshold)hi=i;return hi;}
/** Worst deviation from the identity, used to max out the region sweep. */
const EXTREMES=[];
for(const s of[-1,1])for(const d of[-1,1])for(const l of[-1,1])for(const h of[-1,1])
 EXTREMES.push({shadows:s,darks:d,lights:l,highlights:h});

// --- defaults and identity -------------------------------------------------
const def=pc.parametricDefaults();
ok(def.shadowSplit===0.25&&def.darkSplit===0.50&&def.lightSplit===0.75,'default splits are 0.25/0.50/0.75');
ok(def.refineSaturation===1,'refine saturation defaults to 1 (keep what the curve produces)');
ok(pc.parametricIsIdentity(def),'the default curve reports identity');
const idLut=pc.buildParametricLut(def);
let exactRamp=true;for(let i=0;i<N;i++)if(idLut[i]!==ramp(i)){exactRamp=false;break;}
ok(exactRamp,'an all-zero curve is the exact identity ramp, with no special-casing needed');
ok(!pc.parametricIsIdentity(params({shadows:0.001})),'a non-zero region amount is not identity');
ok(pc.parametricIsIdentity(params({shadows:0,splits:0.4})),'moving splits alone leaves the curve at identity');

// --- endpoints, monotonicity, no clamping ---------------------------------
let endpointsFixed=true,monotoneAlways=true,finiteAlways=true,interiorStrict=true;
for(const amount of EXTREMES){
 const lut=pc.buildParametricLut(params(amount));
 if(lut[0]!==0||lut[N-1]!==1)endpointsFixed=false;
 if(!isMonotone(lut))monotoneAlways=false;
 if(!isFiniteLut(lut))finiteAlways=false;
 for(let i=1;i<N-1;i++)if(!(lut[i]>0&&lut[i]<1))interiorStrict=false;
}
ok(endpointsFixed,'both endpoints are pinned to 0 and 1 for every extreme combination');
ok(monotoneAlways,'the curve is monotone non-decreasing for every extreme combination');
ok(finiteAlways,'no extreme combination produces a NaN or Infinity');
ok(interiorStrict,'the value bound keeps every interior entry strictly inside 0..1, so nothing clamps flat');

// --- each region moves the band it claims ---------------------------------
const lifted=pc.buildParametricLut(params({shadows:1}));
ok(lifted[32]>32/(N-1)+0.01,'a positive shadows amount lifts the shadow band');
ok(peakIndex(deviation(lifted))<128,'the largest lift from the shadows slider is in the lower half of the curve');
const deepened=pc.buildParametricLut(params({shadows:-1}));
ok(deepened[32]<32/(N-1)-0.01,'a negative shadows amount deepens the shadow band');
const bright=pc.buildParametricLut(params({highlights:1}));
ok(bright[224]>224/(N-1)+0.01,'a positive highlights amount brightens the highlight band');
ok(peakIndex(deviation(bright))>160,'the largest lift from the highlights slider is in the upper part of the curve');
const darkHigh=pc.buildParametricLut(params({highlights:-1}));
ok(darkHigh[224]<224/(N-1)-0.01,'a negative highlights amount pulls the highlight band down');

// --- splits actually move the affected range ------------------------------
const narrow=highestSignificant(deviation(pc.buildParametricLut(params({shadows:1,shadowSplit:0.25}))),0.01);
const wide=highestSignificant(deviation(pc.buildParametricLut(params({shadows:1,shadowSplit:0.55}))),0.01);
ok(narrow>=0&&wide>=0,'the shadows slider has a measurable span at both split settings');
ok(wide>narrow+20,'widening shadowSplit extends the affected range upward ('+narrow+' -> '+wide+')');

// --- C1 continuity: no hard band edges ------------------------------------
let maxSecondDifference=0;
for(const amount of EXTREMES){
 const lut=pc.buildParametricLut(params(amount));
 for(let i=2;i<N;i++){
  const second=Math.abs((lut[i]-lut[i-1])-(lut[i-1]-lut[i-2]));
  if(second>maxSecondDifference)maxSecondDifference=second;
 }
}
ok(maxSecondDifference<0.01,'the curve is C1: no step in the first difference exceeds 0.01 (measured '+
 maxSecondDifference.toFixed(6)+'), so there are no hard band edges');

// --- split clamping -------------------------------------------------------
function sameLut(a,b){for(let i=0;i<N;i++)if(a[i]!==b[i])return false;return true;}
ok(sameLut(pc.buildParametricLut(params({shadows:1,shadowSplit:0.9})),
 pc.buildParametricLut(params({shadows:1,shadowSplit:0.70}))),'an over-range shadowSplit clamps to 0.70');
ok(sameLut(pc.buildParametricLut(params({shadows:1,darks:1,darkSplit:0.05})),
 pc.buildParametricLut(params({shadows:1,darks:1,darkSplit:0.27}))),
 'a darkSplit below shadowSplit+gap clamps to the nearest legal value');
ok(isMonotone(pc.buildParametricLut(params({shadows:1,darks:1,lights:1,highlights:1,
 shadowSplit:0.9,darkSplit:0.1,lightSplit:0.2}))),'crossed splits still yield a monotone curve');

// --- slope and saturation refinement --------------------------------------
// The table is float32, so a central difference carries roughly 1e-5 of
// rounding error. Unit slope is therefore asserted to 1e-3, not exactly.
let slopeIdentity=true;
for(const x of[0.05,0.25,0.5,0.75,0.95])if(Math.abs(pc.parametricSlope(idLut,x)-1)>1e-3)slopeIdentity=false;
ok(slopeIdentity,'the identity curve has unit slope everywhere (within float32 rounding)');
let slopeBounded=true;
for(const amount of EXTREMES){
 const lut=pc.buildParametricLut(params(amount));
 for(const x of[0.1,0.3,0.5,0.7,0.9]){
  const slope=pc.parametricSlope(lut,x);
  if(!(slope>0.29&&slope<1.72))slopeBounded=false;
 }
}
ok(slopeBounded,'every extreme combination keeps the slope inside the documented 0.3..1.7 band');
// The refine factor only does anything where the curve steepens. Sampling at a
// fixed x is wrong: at a bump's own peak the slope returns to 1, so a fixed
// probe can pass without exercising the correction at all. Locate the steepest
// point instead.
function steepestX(lut){
 let best=1,bx=0.5;
 for(let i=0;i<N;i++){
  const x=i/(N-1),slope=pc.parametricSlope(lut,x);
  if(slope>best){best=slope;bx=x;}
 }
 return bx;
}
// The refinement scale is measured from a pixel's before/after saturation, not
// from the curve's slope. This matters: the curve is applied PER CHANNEL, so a
// colour can gain saturation while its luminance is outside the steep region,
// where a slope-at-luminance factor would be 1 and would do nothing.
ok(pc.parametricRefineScale(0.5,0.5,0)===1,'refinement does nothing when the curve did not change saturation');
ok(pc.parametricRefineScale(0.5,0.6,1)===1,'refinement at 1 keeps exactly what the curve produced');
ok(pc.parametricRefineScale(0.6,0.5,0)===1,'refinement never acts when the curve REDUCED saturation');
ok(pc.parametricRefineScale(0.6,0.7,0)===0.6/0.7,
 'refineSaturation 0 returns exactly satBefore/satAfter, so scaling restores the input saturation');
let refineInRange=true,refineMonotone=true,previous=1;
for(const r of[1,0.75,0.5,0.25,0]){
 const k=pc.parametricRefineScale(0.6,0.7,r);
 if(!(k>=0&&k<=1))refineInRange=false;
 if(k>previous+1e-9)refineMonotone=false;
 previous=k;
}
ok(refineInRange,'the refinement scale stays inside 0..1 for every refineSaturation setting');
ok(refineMonotone,'the refinement scale decreases as refineSaturation decreases');
ok(previous<0.99,'refineSaturation 0 pulls the curve-induced saturation change back');
ok(Number.isFinite(pc.parametricRefineScale(0.9,1,0.5)),'the refinement scale is finite at full saturation');
ok(pc.parametricRefineScale(0,0,0.5)===1,'an achromatic pixel is left alone (no division by a zero saturation)');

// --- determinism and hostile input ----------------------------------------
ok(sameLut(pc.buildParametricLut(params({shadows:0.4,darks:-0.2,lights:0.7,highlights:-0.3})),
 pc.buildParametricLut(params({shadows:0.4,darks:-0.2,lights:0.7,highlights:-0.3}))),
 'the same parameters produce a bit-identical table');
let hostileOk=true;
for(const bad of[NaN,Infinity,-Infinity,1e9,-1e9]){
 const lut=pc.buildParametricLut(params({shadows:bad,darks:bad,lights:bad,highlights:bad,
  shadowSplit:bad,darkSplit:bad,lightSplit:bad,refineSaturation:bad}));
 if(!isFiniteLut(lut)||!isMonotone(lut)||lut[0]!==0||lut[N-1]!==1)hostileOk=false;
 if(!Number.isFinite(pc.parametricRefineScale(bad,bad,bad)))hostileOk=false;
}
ok(hostileOk,'NaN and infinite parameters still produce a finite, monotone curve with fixed endpoints');

// --- anti-fake ------------------------------------------------------------
ok(!sameLut(lifted,idLut)&&!sameLut(bright,idLut),'a non-zero region amount demonstrably changes the curve');
ok(sameLut(pc.buildParametricLut(params()),idLut),'a zeroed curve is byte-identical to the identity ramp');

console.log('PASS parametric curve: exact identity, pinned endpoints, structural monotonicity, no clamping');
console.log('PASS region targeting, split movement and clamping, C1 continuity, slope, refinement scale');
console.log('PASS hostile-input safety, determinism and a non-trivial effect (not a stub)');
console.log(checks+' checks passed');
