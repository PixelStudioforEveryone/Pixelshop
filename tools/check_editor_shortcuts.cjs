const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const ts=require(process.env.TSDIR||'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const modules=new Map();
function load(file){
 file=path.resolve(file);if(modules.has(file))return modules.get(file).exports;
 const mod={exports:{}};modules.set(file,mod);
 const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
 vm.runInNewContext(js,{module:mod,exports:mod.exports,require:n=>load(path.resolve(path.dirname(file),n+'.ets'))},{filename:file});
 return mod.exports;
}
const {EditorKeyCodes:K,EditorCommandId:C,parseEditorCommand:parse}=load('entry/src/main/ets/edit/engine/EditorShortcuts.ets');
const {EditorCommandDispatcher:D,EditorDispatchResult:R}=load('entry/src/main/ets/edit/engine/EditorCommandDispatcher.ets');
const sdk=fs.readFileSync('D:/DevEco Studio/sdk/default/openharmony/ets/api/@ohos.multimodalInput.keyCode.d.ts','utf8');
for(const name of Object.getOwnPropertyNames(K).filter(x=>x.startsWith('KEYCODE_'))){
 const m=sdk.match(new RegExp('\\b'+name+'\\s*=\\s*(-?\\d+)\\b'));assert(m,name+' exists in SDK');assert.strictEqual(K[name],Number(m[1]),name+' SDK value');
}
const canvas={desktopLayout:true,canvasFocused:true,inputFocused:false,modalOpen:false};
let calls=[],ends=[];const d=new D(id=>calls.push(id),id=>ends.push(id));
const down=(key,ctrl=false,shift=false,repeat=false,ctx=canvas)=>d.dispatchKeyDown(key,ctrl,shift,repeat,ctx);
const up=(key,ctrl=false,shift=false)=>d.dispatchKeyUp(key,ctrl,shift);
for(const shift of [false,true])for(const key of [K.KEYCODE_EQUALS,K.KEYCODE_PLUS,K.KEYCODE_NUMPAD_ADD])assert.strictEqual(parse(key,true,shift),C.ZoomIn);
down(K.KEYCODE_Z,true);down(K.KEYCODE_Z,true,false,true);down(K.KEYCODE_Z,true,false,false);
assert.deepStrictEqual(calls,[C.Undo],'one undo per physical press even without a native repeat flag');
assert.strictEqual(up(K.KEYCODE_Z,false),R.Handled,'Ctrl released before Z still releases its state');
assert(!d.isArmed(K.KEYCODE_Z));down(K.KEYCODE_Z,true);up(K.KEYCODE_Z,true);assert.strictEqual(calls.length,2);
down(K.KEYCODE_Z,true,true);up(K.KEYCODE_Z,false,false);assert.strictEqual(calls.at(-1),C.Redo);
for(const changed of [{inputFocused:true},{modalOpen:true},{canvasFocused:false},{desktopLayout:false}]){
 const before=calls.length;assert.strictEqual(down(K.KEYCODE_Z,true,false,false,{...canvas,...changed}),R.Suppressed);assert.strictEqual(calls.length,before);
}
for(const key of [K.KEYCODE_C,K.KEYCODE_B,K.KEYCODE_MINUS,K.KEYCODE_BACKSLASH]){
 const before=calls.length;down(key,false,false,false,{...canvas,inputFocused:true});assert.strictEqual(calls.length,before,'text input keeps tool and minus keys');
}
const begin=calls.length;down(K.KEYCODE_BACKSLASH);down(K.KEYCODE_BACKSLASH,false,false,true);
assert.strictEqual(calls.length,begin+1,'original compare starts once');
up(K.KEYCODE_BACKSLASH,true,true);assert(!d.isHolding(K.KEYCODE_BACKSLASH));assert.deepStrictEqual(ends,[C.HoldOriginal]);
down(K.KEYCODE_BACKSLASH);d.releaseAll();d.releaseAll();assert.strictEqual(ends.length,2,'blur/photo reset releases hold once');
down(K.KEYCODE_BACKSLASH);down(K.KEYCODE_C,false,false,false,{...canvas,modalOpen:true});assert.strictEqual(ends.length,3,'blocked context releases pending hold');
assert.strictEqual(parse(2017,true,false),C.None,'Ctrl+A belongs to text/system');
assert.strictEqual(parse(K.KEYCODE_C,true,false),C.None,'Ctrl+C belongs to text/system');
assert.strictEqual(parse(K.KEYCODE_U,false,false),C.ToolUpright);
assert.strictEqual(parse(2036,false,false),C.None,'T must not activate the U tool');
assert.strictEqual(up(2017),R.Ignored,'unknown keyup is not swallowed');
// Execute the real canvas tool routing and the rail's existing selection code.
const source=fs.readFileSync('entry/src/main/ets/components/EditorCanvas.ets','utf8');
const layout=fs.readFileSync('entry/src/main/ets/views/TabletLayout.ets','utf8');
const shortcuts=load('entry/src/main/ets/edit/engine/EditorShortcuts.ets');
const {ToolType}=load('entry/src/main/ets/edit/models/ToolType.ets');
const railMethods=layout.slice(layout.indexOf('  private selectMode('),layout.indexOf('  private modeTitle('))+
 layout.slice(layout.indexOf('  private handlePanelRequest('),layout.lastIndexOf('\n}'));
let processed=0;
const engine={process:()=>{processed++;}};
const Rail=vm.runInNewContext(ts.transpileModule('class Rail {'+railMethods+'}\nRail;',
 {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,{ToolType,ImageProcessor:engine,AppStorage:{setOrCreate(){}}});
const rail=new Rail();let added=0,crops=0,commits=0;
const session={isCropping:false,activeTool:ToolType.ADJUST,activeMaskLayer:{id:'parent-A'},activeMaskComponent:{id:'linear-A',type:2},
 bumpProcessing(){commits++;},setActiveTool(tool){this.activeTool=tool;},enterCropMode(){this.isCropping=true;this.activeTool=ToolType.CROP;crops++;},
 selectMaskComponent(){this.activeTool=ToolType.BRUSH_MASK;},addMaskComponent(type){added++;this.activeMaskComponent={id:'brush-A',type};}};
rail.editSession=session;
const routing=source.slice(source.indexOf('  private selectTool('),source.indexOf('  private leaveActiveTool('));
const Canvas=vm.runInNewContext(ts.transpileModule('class Canvas {'+routing+'}\nCanvas;',
 {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,{...shortcuts,ToolType,MaskComponentType:{BRUSH:1},ImageProcessor:engine,
 AppStorage:{setOrCreate:(name,value)=>{if(name==='editorPanelRequest'){rail.panelRequest=value;rail.handlePanelRequest();}}}});
const c=new Canvas();c.editSession=session;
c.selectTool(shortcuts.EDITOR_TOOL_CROP);assert.strictEqual(rail.mode,'crop');assert.strictEqual(crops,1);
assert.strictEqual(session.canvasScale,1);c.selectTool(shortcuts.EDITOR_TOOL_ADJUST);
assert.strictEqual(rail.mode,'develop');assert.strictEqual(session.isCropping,false);assert.strictEqual(commits,1,'leaving crop uses existing commit');
c.selectTool(shortcuts.EDITOR_TOOL_BRUSH_MASK);assert.strictEqual(rail.mode,'mask');assert.strictEqual(added,1,'B adds a brush child to the selected gradient parent');
c.selectTool(shortcuts.EDITOR_TOOL_BRUSH_MASK);assert.strictEqual(added,1,'selecting the existing brush does not duplicate it');
assert(processed>0,'real tool routing schedules rendering');
console.log('PASS production shortcut dispatcher: SDK key codes, Ctrl+plus variants, repeat suppression, modifier release, focus/dialog isolation, hold/reset');
console.log('PASS production canvas→rail tool routing: crop inspector/commit and brush child selection');
