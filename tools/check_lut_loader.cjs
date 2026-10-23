const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const cache=new Map();let parses=0,reads=0;
function load(file){
 file=path.resolve(file);if(cache.has(file))return cache.get(file).exports;
 const mod={exports:{}};cache.set(file,mod);
 const ctx={module:mod,exports:mod.exports,console,Math,Date,Map,Set,Promise,ArrayBuffer,Uint8Array,Concurrent:f=>f,
 require:name=>{
  if(name==='@kit.ArkTS')return {util:{TextDecoder:{create:()=>({decodeToString:b=>new TextDecoder().decode(b)})}},
   taskpool:{Task:class{constructor(fn,...args){this.fn=fn;this.args=args;}},execute:async task=>{parses++;return task.fn(...task.args);}}};
  if(name.startsWith('@kit.'))return {};
  if(name==='libvivid_ai.so')return {default:{isLoaded:()=>false,load:async()=>false,segment:async()=>new ArrayBuffer(0),release(){},modelInfo:()=>[]}};
      if(name.endsWith('.so'))return {default:{}};
      return load(path.resolve(path.dirname(file),name+'.ets'));
 }};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText,ctx,{filename:file});return mod.exports;
}
const {LutLibraryStore:store}=load('entry/src/main/ets/edit/models/LutLibrary.ets');
const {LutLoader}=load('entry/src/main/ets/edit/utils/LutLoader.ets');
const cube='LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n';
const manager={getRawFileContent:async path=>{reads++;await Promise.resolve();return new TextEncoder().encode(cube);}};
const entry=id=>({id,name:id,sourceUri:'bundled://'+id+'.cube',sampleCount:0,table:null,adjustments:{},category:'人像',author:'fixture',referenceKey:'sample'});
async function main(){
 const a=entry('a'),b=entry('b');store.setEntries([a,b]);assert.strictEqual(reads,0,'publishing catalog is lazy');
 const [x,y]=await Promise.all([LutLoader.load(manager,a),LutLoader.load(manager,a)]);
 assert.strictEqual(x,y);assert.strictEqual(reads,1);assert.strictEqual(parses,1);assert.strictEqual(x.table.values.length,24);
 assert.strictEqual(x.name,'a');assert.strictEqual(x.author,'fixture');assert.strictEqual(x.referenceKey,'sample');
 assert.strictEqual(await LutLoader.load(manager,a),x);assert.strictEqual(reads,1);assert.strictEqual(store.find('b').table,null,'unselected table remains lazy');
 const pending=LutLoader.load(manager,b);store.remove('b');await pending;assert.strictEqual(store.find('b'),undefined,'deleted table must not be resurrected');
 console.log('PASS lazy LUT catalog, selected worker parse, request coalescing, cache, metadata and deletion');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
