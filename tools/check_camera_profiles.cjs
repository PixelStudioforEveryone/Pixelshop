// DCP 解析器的运行时校验：把仓库里每个 .dcp 都真解析一遍。
//
// 这个套件原本调用 `CameraProfiles.parse(...)`，但该类已不再有 `parse` 方法 —— 解析
// 搬到了 `DcpProfileParser.parseDcpProfile(data, model, name, fixed)`，由
// `CameraProfiles` 的懒加载路径调用（CameraProfiles.ets:226 / :128）。所以这里直接
// 加载并调用真实解析器，而不是维护一个不存在的方法名。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');

const root = 'entry/src/main/resources/rawfile/Camera';
const parserPath = 'entry/src/main/ets/edit/utils/DcpProfileParser.ets';
const profilesPath = 'entry/src/main/ets/edit/utils/CameraProfiles.ets';

function load(file) {
  const mod = { exports: {} };
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'),
    { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  const sandbox = { module: mod, exports: mod.exports, console, Math, Number, String, Boolean,
    Array, Object, JSON, isNaN, parseInt, parseFloat, Uint8Array, Uint16Array, Uint32Array,
    Int8Array, Int16Array, Int32Array, Float32Array, Float64Array, DataView, ArrayBuffer,
    Map, Set, Error, TextDecoder: global.TextDecoder };
  vm.runInNewContext(js, sandbox, { filename: file });
  return mod.exports;
}

const { parseDcpProfile } = load(parserPath);

// 生产侧仍然通过 CameraProfiles 的懒加载路径调用它：这个接线不能被悄悄改掉。
const profilesSource = fs.readFileSync(profilesPath, 'utf8');
assert(/parseDcpProfile\(/.test(profilesSource),
  'CameraProfiles must still route DCP parsing through parseDcpProfile');
assert(/export class CameraProfiles/.test(profilesSource), 'CameraProfiles class must still exist');

let count = 0;
const failures = [];
for (const dir of fs.readdirSync(root)) {
  const dirPath = path.join(root, dir);
  if (!fs.statSync(dirPath).isDirectory()) continue;
  for (const name of fs.readdirSync(dirPath)) {
    if (!name.endsWith('.dcp')) continue;
    const bytes = fs.readFileSync(path.join(dirPath, name));
    const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    let parsed = null;
    try {
      parsed = parseDcpProfile(buffer, '', dir, false);
    } catch (error) {
      failures.push(`${dir}/${name}: ${error && error.message ? error.message : error}`);
      continue;
    }
    if (!parsed || !parsed.model || !parsed.name) {
      failures.push(`${dir}/${name}: parser returned no model/name`);
      continue;
    }
    count++;
  }
}
if (failures.length > 0) {
  console.error('DCP parse failures (' + failures.length + '):');
  for (const line of failures.slice(0, 10)) console.error('  ' + line);
  process.exit(1);
}
assert(count > 0, 'the camera profile directory must contain at least one .dcp file');
console.log('Runtime parser passed:', count, 'profiles');
