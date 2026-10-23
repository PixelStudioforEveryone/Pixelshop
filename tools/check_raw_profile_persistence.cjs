// Production sidecar/session persistence; all files/images are synthetic.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root=path.resolve('entry/src/main/ets'),cache=new Map(),storage=new Map();
const dir=fs.mkdtempSync(path.resolve('tmp/raw-profile-state-'));
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
const {EditSession}=load(root+'/edit/models/EditSession.ets'),{Layer}=load(root+'/edit/models/Layer.ets');
const {EditSidecar}=load(root+'/edit/utils/EditSidecar.ets');
function session(profile,kelvin,tint){const s=new EditSession();s.layers=[new Layer('synthetic')];s.layers[0].adjustments.exposure=.4;
 s.rotation=90;s.cropLeft=.1;s.setRawSettings({profile,kelvin,tint});return s;}
const a=session('Panasonic DC-S5 Camera Natural',6200,-12),raw=path.join(dir,'paired.rw2'),jpg=path.join(dir,'paired.jpg');
const state=a.exportAdjustmentState();assert.strictEqual(JSON.parse(state).version,3);
assert(EditSidecar.write(raw,state,dir));const j=session('',0,0);j.setRawSettings(null);assert(EditSidecar.write(jpg,j.exportAdjustmentState(),dir));
const reopened=new EditSession();assert(reopened.importAdjustmentState(EditSidecar.read(raw,dir)));
assert.strictEqual(reopened.rawSettings.profile,a.rawSettings.profile);assert.strictEqual(reopened.rawSettings.kelvin,6200);
assert.strictEqual(reopened.rawSettings.tint,-12);assert.strictEqual(reopened.layers[0].adjustments.exposure,.4);assert.strictEqual(reopened.rotation,90);
assert.strictEqual(JSON.parse(EditSidecar.read(jpg,dir)).rawSettings,null,'same-name JPEG must not overwrite RAW settings');
assert(fs.existsSync(raw+'.xml')&&fs.existsSync(jpg+'.xml'));
const empty=session('',0,0);assert(reopened.importAdjustmentState(empty.exportAdjustmentState()));assert.strictEqual(reopened.rawSettings.profile,'','saved no-profile differs from missing settings');
const legacy=JSON.parse(state);delete legacy.rawSettings;legacy.version=2;assert(reopened.importAdjustmentState(JSON.stringify(legacy)));
assert.strictEqual(reopened.rawSettings,null,'legacy file must retain default path');assert.strictEqual(reopened.layers[0].adjustments.exposure,.4);
reopened.setRawSettings({profile:'profile',kelvin:99999,tint:-999});assert.strictEqual(reopened.rawSettings.kelvin,12000);assert.strictEqual(reopened.rawSettings.tint,-100);
reopened.setRawSettings({profile:'profile',kelvin:NaN,tint:0});assert.strictEqual(reopened.rawSettings,null);
const provider='datashare://media/Photo/synthetic';assert(EditSidecar.write(provider,state,dir));assert.strictEqual(EditSidecar.read(provider,dir),state);
const legacyUri=path.join(dir,'old.nef'),escape=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
fs.writeFileSync(path.join(dir,'old.xml'),'<vivid:state>'+escape(JSON.stringify(legacy))+'</vivid:state>');
assert.strictEqual(EditSidecar.read(legacyUri,dir),JSON.stringify(legacy));
assert(EditSidecar.write(legacyUri,state,dir));assert.strictEqual(EditSidecar.read(legacyUri,dir),state,'new per-file state must take precedence over legacy');
// Verify loading order/explicit snapshot argument in actual editor source.
const editor=fs.readFileSync(root+'/pages/EditorPage.ets','utf8');const start=editor.indexOf('async loadImage('),end=editor.indexOf('aboutToDisappear()',start),body=editor.slice(start,end);
assert(body.indexOf('restoreEditSidecar()')<body.indexOf('PixelMapUtils.loadFromUri('),'RAW settings must restore before initial decode');
assert(body.includes('}, false, rawSettings)'),'decode must receive immutable per-image settings');
reopened.setRawSettings(a.rawSettings);reopened.reset();assert.strictEqual(reopened.rawSettings,null,'switching image must reset RAW state');
// Execute the actual editor method bodies, with only OS decoding/rendering
// stubbed, to check that reopening affects pixels as well as selector text.
function section(from,to){const i=editor.indexOf(from);assert(i>=0);return editor.slice(i,editor.indexOf(to,i));}
const harness=`class EditorHarness {
 editSession=new EditSession();imageUri='';loading=false;sidecarDirectory='';fullResSource=null;
 // loadImage() gates the decode and the publish on these two page fields; without them
 // the sliced body returns before loadFromUri and the suite sees no decode at all.
 pageAlive=true;loadGeneration=0;
 fullResWidth=0;fullResHeight=0;rawSettingsSaveTimer=-1;exportInProgress=false;
 getUIContext(){return {getHostContext:()=>({resourceManager:{}}),getPromptAction:()=>({showToast(){},showDialog:async()=>{}})};}
 imageDisplayName(){return this.imageUri;}currentRawSourceKind(){return null;}
 previewMaxDimension(){return 1024;}loadRecentMaterials(){}clearDetailRender(){}applyIncomingPreset(){}
 showUnsupportedImageDialog(){}createPlaceholderImage(){}
 // loadImage() publishes export metadata (the TIFF/EXIF side of the RAW source).
 // It is not what this harness asserts, so it is stubbed rather than extracted;
 // without the stub the pasted method body throws and the whole suite aborts.
 async updateExportMetadataFromSource(){}
 ${body}
 ${section('private restoreEditSidecar()', 'private imageDisplayName()')}
 ${section('private saveEditSidecar()', 'private async loadRecentMaterials()')}
 ${section('private invalidateRawProfileSource()', 'private rawSettingsSaveTimer:')}
};module.exports=EditorHarness;`;
const decodeCalls=[],harnessModule={exports:{}};
const context={module:harnessModule,EditSession,EditSidecar,Date,Math,Number,setTimeout,clearTimeout,console:{info(){},error:console.error,warn:(...a)=>console.log('DECODE-WARN',...a)},
 AppStorage:{get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)},
 // loadImage() now also drops the AI mask cache next to clearSourceCache(); the sliced
 // body references it as a free identifier, so the harness must provide it.
 AiSegmentationService:{cancelPending(){}},
 RawPreviewLoader:{isRawFile:s=>/\.(rw2|nef)$/i.test(s)},CameraProfiles:{CLASSIC_PROFILE_NAME:'Pixel 经典',initialize:async()=>{}},
 RawSourceKind:{EMBEDDED_JPEG_PREVIEW:'embedded',NATIVE_RENDERED_RGB:'native'},rawDescriptorJson:()=>'',
 ImageProcessor:{clearSourceCache(){},clearRegionMaskCache(){},process:async()=>{}},PixelMapUtils:{
 rawPreviewSettings:()=>({profile:storage.get('selectedCameraProfile')??'',kelvin:storage.get('rawWhiteBalanceKelvin')??0,tint:storage.get('rawWhiteBalanceTint')??0}),
 loadFromUri:async(...args)=>{
  // loadFromUri has a long optional-parameter tail
  // (uri, maxDimension, onReadProgress, isCancelled, onSourceInfo, sourceNameHint,
  //  onDecodeInfo, thumbnailOnly, rawSettings). Picking one positional index couples
  // this suite to the exact argument count, so locate the settings object instead.
  decodeCalls.push(args.find(a=>a&&typeof a==='object'&&'profile' in a));
  return {getImageInfo:async()=>({size:{width:1024,height:640}})};}
 }};
vm.runInNewContext(ts.transpileModule(harness,{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,context);
async function checkEditor(){
 const C=harnessModule.exports;const first=new C();first.imageUri=raw;first.sidecarDirectory=dir;
 storage.set('selectedCameraProfile','unrelated previous image');await first.loadImage(raw);
 assert.strictEqual(decodeCalls.at(-1).profile,a.rawSettings.profile,'decoder must receive saved DCP before pixels are created');
 assert.strictEqual(decodeCalls.at(-1).kelvin,6200);assert.strictEqual(decodeCalls.at(-1).tint,-12);
 storage.set('selectedCameraProfile','Pixel F-log2');storage.set('rawWhiteBalanceKelvin',6800);storage.set('rawWhiteBalanceTint',8);
 first.invalidateRawProfileSource();await new Promise(r=>setTimeout(r,340));
 const second=new C();second.imageUri=raw;second.sidecarDirectory=dir;await second.loadImage(raw);
 assert.strictEqual(decodeCalls.at(-1).profile,'Pixel F-log2');assert.strictEqual(decodeCalls.at(-1).kelvin,6800);
 assert.strictEqual(decodeCalls.at(-1).tint,8);assert.strictEqual(storage.get('selectedCameraProfile'),'Pixel F-log2');
 const third=new C();third.imageUri=path.join(dir,'new.rw2');await third.loadImage(third.imageUri);
 assert.strictEqual(decodeCalls.at(-1).profile,'Pixel 经典','new image must not inherit previous image settings');
 const fourth=new C();fourth.imageUri=jpg;fourth.sidecarDirectory=dir;await fourth.loadImage(jpg);
 assert.strictEqual(decodeCalls.at(-1).profile,'');assert.strictEqual(fourth.editSession.rawSettings,null);
 console.log('PASS actual editor decode order, debounced RAW autosave, exit/reopen settings, independent new-image defaults and JPEG isolation');
 console.log('PASS per-image DCP/WB reopen, unchanged colour/crop, explicit no-profile, legacy migration, JPG/RAW isolation, provider fallback, validation and image-switch reset');
}
checkEditor().catch(e=>{console.error(e);process.exitCode=1;});
