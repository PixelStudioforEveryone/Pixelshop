// Regression: exercise the REAL export dialog method and renderer geometry.
// A cropped original must never be resized back to its uncropped dimensions
// by the dialog's default 100% selection. No UI/formula mirror is used.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const modules = new Map();
function load(file) {
  file = path.resolve(file); if (modules.has(file)) return modules.get(file).exports;
  const mod = {exports:{}}; modules.set(file,mod);
  const js = ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
  vm.runInNewContext(js,{module:mod,exports:mod.exports,console,require:n=>load(path.resolve(path.dirname(file),n+'.ets'))},{filename:file});
  return mod.exports;
}
const { buildGeometryMap } = load('entry/src/main/ets/edit/engine/GeometryMath.ets');
const page = fs.readFileSync('entry/src/main/ets/pages/EditorPage.ets','utf8');
const method = page.slice(page.indexOf('  private async openExportDialog()'),page.indexOf('  async exportImage('));
assert(method.includes('buildGeometryMap('),'dialog must share the renderer geometry');
const js = ts.transpileModule('class ReviewPage {'+method+'}\nReviewPage;', {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText;
let confirmed;
const Page = vm.runInNewContext(js,{ buildGeometryMap, setTimeout,
  ExportQualityDialog:p=>p, DialogAlignment:{Center:0},
  CustomDialogController:class{constructor(p){this.params=p;}open(){confirmed=this.params.builder;}close(){}}
});
Page.prototype.beginModal=()=>{};
Page.prototype.endModal=()=>{};
(async()=>{
  const source={width:8152,height:5432}; let count=0;
  for(const rotation of [0,90,180,270,-90])for(const crop of [[0,0,1,1],[.25,.1,.75,.9],[.333,.217,.807,.692],[.99,.99,1,1]]){
    const session={imageWidth:2048,imageHeight:1365,previewWidth:800,previewHeight:600,
      cropLeft:crop[0],cropTop:crop[1],cropRight:crop[2],cropBottom:crop[3],rotation,flipH:true,flipV:false,geometry:[]};
    const p=new Page();Object.assign(p,{exportInProgress:false,fullResWidth:source.width,fullResHeight:source.height,
      editSession:session,exportMetadata:{enabled:false},updateExportMetadataFromSource:async()=>{}});
    await p.openExportDialog();
    const map=buildGeometryMap([],source.width,source.height,{...source,...session});
    assert.strictEqual(confirmed.originalWidth,map.outputWidth,'100% width');
    assert.strictEqual(confirmed.originalHeight,map.outputHeight,'100% height'); count++;
  }
  // If original dimensions are unavailable, use the UNcropped source preview.
  const p=new Page();Object.assign(p,{exportInProgress:false,fullResWidth:0,fullResHeight:0,
    editSession:{imageWidth:1200,imageHeight:800,previewWidth:300,previewHeight:300,
      cropLeft:.25,cropTop:0,cropRight:.75,cropBottom:1,rotation:90,flipH:false,flipV:false,geometry:[]},
    exportMetadata:{enabled:false},updateExportMetadataFromSource:async()=>{}});
  await p.openExportDialog();assert.strictEqual(confirmed.originalWidth,800);assert.strictEqual(confirmed.originalHeight,600);
  // Real portrait RW2: metadata is 8152x5432, but EXIF orientation makes the
  // decoded source 5432x8152. Preview-authored crop must use that source frame.
  for(const rotation of [0,90,180,270])for(const metadata of [[8152,5432],[5432,8152]]) {
    const q=new Page();const session={imageWidth:1365,imageHeight:2048,previewWidth:1365,previewHeight:1366,
      cropLeft:0,cropTop:1/6,cropRight:1,cropBottom:5/6,rotation,flipH:false,flipV:false,geometry:[]};
    Object.assign(q,{exportInProgress:false,fullResWidth:metadata[0],fullResHeight:metadata[1],
      editSession:session,exportMetadata:{enabled:false},updateExportMetadataFromSource:async()=>{}});
    await q.openExportDialog();
    const actual=buildGeometryMap([],5432,8152,{...session,width:5432,height:8152});
    assert.strictEqual(confirmed.originalWidth,actual.outputWidth,'oriented RAW width');
    assert.strictEqual(confirmed.originalHeight,actual.outputHeight,'oriented RAW height');count++;
  }
  console.log('PASS actual export dialog/renderer dimensions: '+count+' crop/rotation/oriented RAW cases plus uncropped source fallback');
})().catch(e=>{console.error(e);process.exitCode=1;});
