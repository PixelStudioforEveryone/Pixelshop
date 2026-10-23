const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require('D:/DevEco Studio/tools/ohpm/node_modules/typescript/lib/typescript.js');
// GeometryTransform imports and re-exports GeometryMath, so the transpiled
// module needs a CommonJS require that can resolve sibling .ets files; without
// it this check died with "require is not defined" before asserting anything.
const modules = new Map();
function load(rel) {
 const file = path.resolve(rel);
 if (modules.has(file)) return modules.get(file);
 const module = { exports: {} };
 modules.set(file, module.exports);
 const ctx = { exports: module.exports, module, Math, Number, Object, Array, Int32Array, Float32Array,
  Uint8ClampedArray, JSON, console,
  require: name => load(path.resolve(path.dirname(file), name.replace(/^\.\//, '') + '.ets')) };
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'), {compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText, ctx, {filename:file});
 return module.exports;
}
const ctx = { exports: load('entry/src/main/ets/edit/engine/GeometryTransform.ets') };
const render = ctx.exports.transformGeometry, w=80, h=60;
const pixels = new Uint8ClampedArray(w*h*4);
for(let y=0;y<h;y++) for(let x=0;x<w;x++) pixels.set([x*3,y*4,120,255],(y*w+x)*4);
assert.strictEqual(render(pixels,w,h,[0,0,0,0,100,0,0,0]),pixels);
for(const index of [0,1,2,3,4,5,6]) {
 const g=[0,0,0,0,100,0,0,0]; g[index]+=15;
 assert.notDeepStrictEqual(render(pixels,w,h,g),pixels,`control ${index} must change pixels`);
}
const constrained=render(pixels,w,h,[20,-15,12,0,100,0,0,1]);
for(let i=3;i<constrained.length;i+=4) assert.strictEqual(constrained[i],255,'constrained crop must cover frame');
// The report is a gitignored one-off artefact, not source. If an external
// cleanup removed tmp/, rebuild it from the shipped .dcp with the project's
// own parser (tools/rebuild_dcp_report_fixture.cjs names tag 0xC715 as
// forwardMatrix2; raw JSON.stringify of the parser Map would drop it).
const dcpReport = 'tmp/dcp-report/Panasonic DC-S1RM2 Camera Standard.json';
if (!fs.existsSync(dcpReport)) {
  console.log('fixture missing; rebuilding ' + dcpReport + ' from the shipped .dcp');
  require('child_process').execFileSync(process.execPath,
    [path.resolve('tools/rebuild_dcp_report_fixture.cjs')], { stdio: 'inherit' });
}
const dcp=JSON.parse(fs.readFileSync(dcpReport,'utf8')).parsedFields;
const m=dcp.forwardMatrix2, xyz=[0,1,2].map(i=>m[i*3]+m[i*3+1]+m[i*3+2]);
const rgb=[3.1338561*xyz[0]-1.6168667*xyz[1]-.4906146*xyz[2],-.9787684*xyz[0]+1.9161415*xyz[1]+.0334540*xyz[2],.0719453*xyz[0]-.2289914*xyz[1]+1.4052427*xyz[2]];
assert(Math.max(...rgb)-Math.min(...rgb)<.002,'white-balanced neutral must remain neutral');
console.log('PASS: all seven geometry controls, identity, constrained coverage, S1RM2 ForwardMatrix neutral',rgb);
