// F7 + F11 — the mask panel must not expose/write document-level optics, and the
// desktop inspector must keep its section list honest after the P1/P2/P3 moves:
// point colour is embedded in the mixer, Upright lives in the crop page, and
// OkLCh is retired.
//
// F7: DesktopDevelopPanel filtered the section list with `section.id !== 'detail'`
// only, so `optics` stayed visible while a mask was edited, OpticsControl wrote
// `session.optics.*` regardless of maskContext, and the section reset wiped the
// global lens correction from a local panel.
//
// F11: TabletLayout/PhoneLayout mount DesktopDevelopPanel, which renders
// AdjustmentPanel({profileOnly:true}); the old four "lost" groups are no longer
// all sections. Point colour sits inside the mixer, Upright sits in CropPanel,
// OkLCh is gone, and only Black & White remains a section.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const ts = require(process.env.TSDIR || 'D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve('entry/src/main/ets');

function loadPlain(file) {
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  const mod = { exports: {} };
  vm.runInNewContext(js, { module: mod, exports: mod.exports, console, Math, Number, Date, Map, Set, Array },
    { filename: file });
  return mod.exports;
}

const sections = loadPlain(root + '/edit/models/DevelopSections.ets');
const ids = sections.DEVELOP_SECTIONS.map((section) => section.id);

// ---- 1. the section list and its visibility rule (executable data) --------
for (const id of ['light', 'color', 'effects', 'curve', 'mixer', 'grading', 'detail',
  'optics', 'black-white', 'calibration']) {
  assert(ids.indexOf(id) >= 0, 'the desktop section list must contain ' + id);
}
// P1/P2/P3: these are no longer desktop sections.
for (const id of ['upright', 'point-color', 'oklch']) {
  assert(ids.indexOf(id) < 0, id + ' must no longer have an independent desktop section');
}
// point-color is embedded in the mixer; it must still be whole-frame only there.
const wholeFrame = ['detail', 'optics', 'point-color', 'black-white'];
for (const id of wholeFrame) {
  assert.strictEqual(sections.isDevelopSectionVisible(id, true), false,
    id + ' must be hidden while a mask is edited');
  assert.strictEqual(sections.isDevelopSectionVisible(id, false), true,
    id + ' must be visible for a whole-frame edit');
  assert.strictEqual(sections.isWholeFrameSection(id), true, id + ' is a whole-frame stage');
}
for (const id of ['light', 'color', 'effects', 'curve', 'mixer', 'grading', 'calibration']) {
  assert.strictEqual(sections.isDevelopSectionVisible(id, true), true,
    id + ' is mask-safe and must stay visible');
  assert.strictEqual(sections.isWholeFrameSection(id), false, id + ' is not whole-frame only');
}
// The two retired/moved entries must not keep a stale whole-frame classification.
assert.strictEqual(sections.isWholeFrameSection('upright'), false,
  'upright now belongs to the crop page, not the whole-frame develop stage list');
assert.strictEqual(sections.isWholeFrameSection('oklch'), false,
  'OkLCh is retired and must not keep a whole-frame stage entry');

// ---- 2. source structure of DesktopDevelopPanel ---------------------------
const panelPath = 'entry/src/main/ets/components/DesktopDevelopPanel.ets';
const panel = fs.readFileSync(panelPath, 'utf8');

// P1: point colour is embedded in the mixer, not a section of its own.
const mixer = fs.readFileSync('entry/src/main/ets/components/ColorMixerControl.ets', 'utf8');
assert(mixer.indexOf("import { PointColorPanel } from './PointColorPanel'") >= 0,
  'ColorMixerControl must import the point-colour panel');
assert(mixer.indexOf('PointColorPanel({ nested: true })') >= 0,
  'and mount it as a nested block inside the mixer');
assert(mixer.indexOf("isDevelopSectionVisible('point-color', this.maskContext)") >= 0,
  'with the shared whole-frame predicate, so a mask cannot mount it');
// P2: upright moved to the crop page.
const crop = fs.readFileSync('entry/src/main/ets/components/CropPanel.ets', 'utf8');
assert(crop.indexOf("import { UprightPanel } from './UprightPanel'") >= 0,
  'CropPanel must import UprightPanel');
assert(crop.indexOf('UprightPanel({ nested: true, cropEmbedded: true })') >= 0,
  'and mount it inside the crop page');
// Neither moved/retired panel may remain a desktop section.
assert(panel.indexOf('UprightPanel') < 0, 'UprightPanel must not remain in DesktopDevelopPanel');
assert(panel.indexOf('PointColorPanel') < 0, 'PointColorPanel must not remain in DesktopDevelopPanel');
assert(panel.indexOf('OkLChPanel') < 0, 'OkLChPanel must not remain in DesktopDevelopPanel');
// Black & white is the only one of the former four that is still a section.
assert(panel.indexOf("import { BlackWhitePanel } from './BlackWhitePanel'") >= 0,
  'DesktopDevelopPanel must import BlackWhitePanel');
const loopStart = panel.indexOf('ForEach(DEVELOP_SECTIONS');
assert(loopStart >= 0, 'the section loop must iterate the shared list');
const profileStart = panel.indexOf('AdjustmentPanel({ profileOnly: true');
assert(profileStart >= 0, 'the profile-only block must still exist');
const bwCall = panel.indexOf('if (!this.maskContext) BlackWhitePanel();');
assert(bwCall >= 0, 'BlackWhitePanel must be mounted in a mask-excluded section');
assert(bwCall > loopStart, 'BlackWhitePanel must be mounted from the section loop, not the profile-only branch');
assert(bwCall > profileStart, 'BlackWhitePanel must not sit inside the AdjustmentPanel profile block');

// F7: the mask filter is the shared predicate and excludes optics.
assert(panel.indexOf('isDevelopSectionVisible(section.id, this.maskContext)') > 0,
  'the section filter must use the shared mask-visibility predicate');
assert(panel.indexOf("section.id !== 'detail'") < 0,
  'the old inline filter (which let optics through) must be gone');

// F7: the optics write path is guarded while a mask is edited.
const opticsStart = panel.indexOf('private OpticsControl(');
const opticsEnd = panel.indexOf('private opticsValue(');
assert(opticsStart >= 0 && opticsEnd > opticsStart, 'OpticsControl must exist');
const opticsBody = panel.slice(opticsStart, opticsEnd);
function guardedWrite(body) {
  const guard = body.indexOf('if (this.maskContext) return;');
  const write = body.search(/this\.editSession\.optics\.\w+\s*=/);
  return guard >= 0 && write >= 0 && guard < write;
}
assert(guardedWrite(opticsBody), 'OpticsControl must refuse to write global optics in mask context');
// Anti-tautology: the check must fail when the guard is removed.
const withoutGuard = opticsBody.replace('if (this.maskContext) return;', '');
assert.strictEqual(guardedWrite(withoutGuard), false,
  'the guard check must detect a missing maskContext guard');
// And the control really does write somewhere, otherwise the guard is vacuous.
assert((opticsBody.match(/this\.editSession\.optics\.\w+\s*=/g) || []).length >= 5,
  'OpticsControl must still contain the global optics writes it guards');

// F7: resetSection must not reset global optics from a mask panel.
const resetStart = panel.indexOf('private resetSection(');
const resetEnd = panel.indexOf('private ', resetStart + 10);
const resetBody = panel.slice(resetStart, resetEnd);
const resetGuard = resetBody.indexOf('if (this.maskContext && isWholeFrameSection(sectionId)) return;');
const opticsReset = resetBody.indexOf('this.editSession.optics = new OpticsSettings()');
assert(resetGuard >= 0, 'resetSection must refuse whole-frame sections in mask context');
assert(opticsReset > resetGuard, 'the global optics reset must sit behind that guard');
assert(resetBody.indexOf("sectionId === 'black-white'") >= 0,
  'black-and-white must still have a reset handler');
const mixerResetStart = resetBody.indexOf("sectionId === 'mixer'");
const mixerResetEnd = resetBody.indexOf("sectionId === 'grading'", mixerResetStart);
assert(mixerResetStart >= 0 && mixerResetEnd > mixerResetStart,
  'the mixer reset branch must exist');
assert(resetBody.slice(mixerResetStart, mixerResetEnd).indexOf(
  'if (!this.maskContext) this.editSession.pointColor.clear()') >= 0,
  'resetting the mixer must clear its embedded point-colour samples, but only in whole-frame context');
assert(resetBody.indexOf("sectionId === 'upright'") < 0,
  'upright is no longer a desktop section and must not keep a reset handler');
assert(resetBody.indexOf("sectionId === 'oklch'") < 0,
  'OkLCh is retired and must not keep a reset handler');

// ---- 3. the layouts that motivated F11 still route through this panel -----
for (const layout of ['PhoneLayout.ets', 'TabletLayout.ets']) {
  const source = fs.readFileSync('entry/src/main/ets/views/' + layout, 'utf8');
  assert(source.indexOf('DesktopDevelopPanel()') >= 0,
    layout + ' still mounts DesktopDevelopPanel');
}

console.log('PASS develop sections: mask context hides detail/optics/point-colour/black-white;');
console.log('     point colour is embedded in the mixer behind the same whole-frame predicate, upright');
console.log('     moved to CropPanel, OkLCh was retired, and the mixer reset clears point colour.');
console.log('     Optics writes and resets are still guarded against mask context, with the guard check');
console.log('     shown to fail without the guard.');
