// Execute the production frame compositor, including the logo loading branch.
// Verify every selection combination, rather than mirroring its renderer.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
let contexts = [], assets = [];
class Context {
  constructor() { this.texts = []; this.draws = []; contexts.push(this); }
  measureText(text) { return {width: text.length * 12}; }
  fillText(text) { this.texts.push(text); }
  drawImage(...args) { this.draws.push(args); }
  createLinearGradient() { return {addColorStop(){}}; }
  getPixelMap(x,y,width,height) { return {size:{width,height},release(){}}; }
  fillRect(){} beginPath(){} moveTo(){} lineTo(){} quadraticCurveTo(){}
  closePath(){} fill(){} stroke(){} save(){} restore(){} clip(){}
}
class Canvas { constructor(width,height){this.width=width;this.height=height;} getContext(){return new Context();} }
const logo = {getImageInfo: async()=>({size:{width:160,height:40}}),release(){}};
const kitImage = {PixelMapFormat:{RGBA_8888:1},createImageSource:()=>({createPixelMap:async()=>logo,release(){}})};
const mod = {exports:{}};
const js=ts.transpileModule(fs.readFileSync('entry/src/main/ets/edit/utils/ExportFrameRenderer.ets','utf8'),
  {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
vm.runInNewContext(js,{module:mod,exports:mod.exports,require:name=>name==='@kit.ImageKit'?{image:kitImage}:{LengthMetricsUnit:{PX:0}},
  OffscreenCanvas:Canvas,RenderingContextSettings:class{},setTimeout:fn=>{queueMicrotask(fn);return 0;}});
const {ExportFrameRenderer:Renderer}=mod.exports;
const base={getImageInfo:async()=>({size:{width:600,height:400}})};
const context={resourceManager:{getRawFileContent:async name=>{assets.push(name);return new Uint8Array([1,2,3]);}}};
const metadata={enabled:true,brand:'Panasonic',camera:'Panasonic S5',lens:'LUMIX S 20-60mm',fontSize:16,fontColor:'#111111',
  focalLength:'49 MM',aperture:'f/4.0',shutter:'1/500s',iso:'ISO100',capturedAt:'2026-10-13'};
const flags=['showCamera','showLens','showFocalLength','showAperture','showShutter','showIso','showCapturedAt'];
async function check(style,selected) {
  contexts=[];assets=[];
  const frame={...metadata,style,...selected};
  const out=await Renderer.render(base,frame,context);
  assert(out,'renderer completed');
  const actual=contexts[0].texts;
  const expected=[];
  if(selected.showCamera)expected.push('Panasonic S5');
  if(selected.showLens)expected.push(metadata.lens);
  const parameters=[];
  if(selected.showFocalLength)parameters.push('49mm');
  if(selected.showAperture)parameters.push('F4.0');
  if(selected.showShutter)parameters.push('1/500 s');
  if(selected.showIso)parameters.push('ISO 100');
  if(parameters.length)expected.push(parameters.join('  '));
  if(selected.showCapturedAt)expected.push(metadata.capturedAt);
  assert.deepStrictEqual([...actual].sort(),expected.sort(),style+' '+JSON.stringify(selected));
  assert.strictEqual(assets.length,style==='经典相框'&&selected.showCamera?1:0,'unchecked camera cannot load/draw its logo');
  if(assets.length)assert.strictEqual(assets[0],'logos/panasonic.png');
  return actual;
}
(async()=>{
  let cases=0;
  for(const style of ['经典相框','沉浸光感']) {
    await check(style,{});cases++;
    for(let mask=0;mask<128;mask++) {
      const selected={};flags.forEach((flag,index)=>{selected[flag]=!!(mask&(1<<index));});
      await check(style,selected);cases++;
    }
    await check(style,{showCamera:true,showLens:true,showIso:true});
    await check(style,{showCamera:false,showLens:false,showIso:false});cases+=2;
  }
  for(const [field,raw,expected] of [['focalLength','49','49mm'],['aperture','4.0','F4.0'],['shutter','0.5 秒','0.5 s'],
    ['iso',' 100 ','ISO 100'],['shutter','1/500 s','1/500 s']]) assert.strictEqual(Renderer.formatParameter(field,raw),expected);
  for(const field of ['focalLength','aperture','shutter','iso'])assert.strictEqual(Renderer.formatParameter(field,'  '),'');
  // The real dialog must pass the visibility choices unchanged to export.
  const page=fs.readFileSync('entry/src/main/ets/pages/EditorPage.ets','utf8');
  const method=page.slice(page.indexOf('  private frameOptions(): ExportFrameOptions'),page.indexOf('  private scheduleFramePreview(): void'));
  const Form=vm.runInNewContext(ts.transpileModule('class Form {'+method+'}\nForm;',
    {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText);
  const form=new Form();Object.assign(form,metadata,{frameEnabled:true,frameStyle:'经典相框'});
  flags.forEach((flag,index)=>{form[flag]=index%2===0;});
  const actual=form.frameOptions();flags.forEach(flag=>assert.strictEqual(actual[flag],form[flag]));
  console.log('PASS frame visibility: '+cases+' actual composition cases, formatting, and real dialog→export options');
})().catch(e=>{console.error(e);process.exitCode=1;});
