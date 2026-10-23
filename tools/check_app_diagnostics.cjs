// Synthetic-only regression: real app sinks and receiver validation, no user logs.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const base = 'entry/src/main/ets/';
const util = {
  TextEncoder: { create: () => new TextEncoder() },
  TextDecoder: { create: () => ({ decodeToString: input => new TextDecoder().decode(input) }) },
};
function loadSource(source, imports = {}, globals = {}) {
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021,
  }}).outputText, { module, exports: module.exports,
    require: id => imports[id] || {}, setTimeout: () => 1, clearTimeout: () => {}, ...globals });
  return module.exports;
}
const read = path => fs.readFileSync(base + path, 'utf8').replace(/\r\n/g, '\n');
const policyModule = loadSource(read('services/AppLogPolicy.ets'), { '@kit.ArkTS': { util } });
const { AppLogPolicy: Policy } = policyModule;
const { AppDiagnostics: Diagnostics } = loadSource(read('services/AppDiagnostics.ets'));
const fixtureSecret = 'fixture-sensitive-value-with-spaces';
for (const key of ['Authorization', 'token', 'password', 'SSID', 'OpenId', 'DeviceId', 'fingerprint']) {
  assert(!Policy.sanitize(`stage ${key}="${fixtureSecret} more text"`).includes(fixtureSecret), key);
}
assert(!Policy.sanitize(`Bearer ${fixtureSecret}`).includes(fixtureSecret));
assert(!Policy.sanitize('camera S5M2_SYNTHETIC Z_5_0000000 https://synthetic.invalid/private').includes('SYNTHETIC'));
assert(!Policy.sanitize('error\nline\r\nnext\u0000\ufffd').match(/[\r\n\ufffd\u0000]/));
assert(Buffer.byteLength(Policy.sanitize('中'.repeat(10000)), 'utf8') < 4096);

// Mock SDK fileIo only; exercise the actual AppLogStore implementation.
const files = new Map(), handles = new Map(); let fd = 1, failDisk = false;
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, APPEND: 4, READ_ONLY: 8 }, mkdirSync: () => {},
  listFileSync: dir => [...files.keys()].filter(k => k.startsWith(dir + '/')).map(k => k.slice(dir.length + 1)),
  openSync(path, mode) {
    if (failDisk) throw new Error('synthetic disk failure');
    if (!files.has(path)) { if (!(mode & 1)) throw new Error('not found'); files.set(path, Buffer.alloc(0)); }
    const file = { fd: fd++ }; handles.set(file.fd, { path, mode }); return file;
  },
  statSync(target) { const path = typeof target === 'number' ? handles.get(target).path : target;
    if (!files.has(path)) throw new Error('not found'); return { size: files.get(path).length }; },
  writeSync(target, data) { const h = handles.get(target); assert(h.mode & 2);
    files.set(h.path, Buffer.concat([files.get(h.path), Buffer.from(data)])); },
  readSync(target, data) { new Uint8Array(data).set(files.get(handles.get(target).path)); },
  closeSync(file) { handles.delete(file.fd); },
  unlinkSync(path) { if (!files.delete(path)) throw new Error('not found'); },
  moveFileSync(from, to) { assert(!files.has(to)); files.set(to, files.get(from)); files.delete(from); },
};
const shared = read('pages/home/HomeShared.ets');
const begin = shared.indexOf('export class AppLogStore');
const end = shared.indexOf('\n}\n', begin) + 3;
assert(begin >= 0 && end > begin);
const { AppLogStore: Store } = loadSource(shared.slice(begin, end), {}, { fileIo, util, AppLogPolicy: Policy });
Store.init('/synthetic/files');
// LumixImportPrototype 现在把 runtimeInfo/emitTrace/logError 统一走服务层出口
// AppLogSink（它再落到 AppLogStore）。这里装真实的 sink 并把 writer 接到被测
// Store 上，否则 `AppLogSink.emit` 未 install，链路日志不会落盘、断言必然失败。
const { AppLogSink } = loadSource(read('services/AppLogSink.ets'));
AppLogSink.install(line => Store.add(line));
Diagnostics.event('VIVID_BLE', 'FLOW_PHASE flow=1 phase=ble elapsedMs=0');
Diagnostics.configure(message => Store.add(message), () => Store.flushNow());
Diagnostics.event('VIVID_HTTP', 'HTTP_REQ seq=1 method=POST path=/auth headers=Content-Type=application/json ' +
  'body=json(len=120,fields=AppInfo=redacted(40)|FriendlyName=redacted(10)|Uuid=redacted(36))');
Diagnostics.event('VIVID_HTTP', 'HTTP_RES seq=1 path=/auth http=200 business=200 elapsedMs=34 bytes=120 ' + fixtureSecret);
Diagnostics.event('VIVID_HTTP', 'HTTP_REQ seq=2 method=POST path=/media/gallery/info ' +
  'headers=Authorization=present(len=80,quoted=1) body=json(len=20,fields=StartIndex=0|Limit=6|Rating=null)');
Diagnostics.event('VIVID_HTTP', 'HTTP_RES seq=2 path=/media/gallery/info http=200 business=403 elapsedMs=38 bytes=65');
Diagnostics.event('VIVID_BLE', 'FLOW_ERR flow=1 phase=session elapsedMs=50');
Diagnostics.exception('VIVID_BLE', 'flow exception', {
  name: 'TypeError', message: `Cannot read property 'byteLength' of undefined ${fixtureSecret}`,
  stack: 'TypeError\n at /private/user/LumixImportPrototype.ets:1495:7\n' + fixtureSecret,
});
Diagnostics.event('VIVID_BLE', 'unclassified raw ' + fixtureSecret);
const disk = Store.todayLogText();
assert(files.size > 0);
for (const marker of ['phase=ble', 'method=POST', 'path=/auth', 'path=/media/gallery/info', 'http=200',
  'business=403', 'authQuoted=1', 'StartIndex=0', 'Limit=6', 'event=exception', 'name=TypeError',
  'properties=byteLength', 'LumixImportPrototype:1495:7', 'phase=session']) assert(disk.includes(marker), marker);
assert(!disk.includes(fixtureSecret)); assert(!disk.includes('/private/user/'));

// Existing central logger must persist even if HiLog is unavailable.
const hilog = { info: () => { throw new Error('no system logger'); }, error: () => { throw new Error('no system logger'); } };
const { LumixImportPrototype: Import } = loadSource(read('services/LumixImportPrototype.ets'), {
  './AppDiagnostics': { AppDiagnostics: Diagnostics }, '@kit.PerformanceAnalysisKit': { hilog },
  './AppLogSink': { AppLogSink },
});
Import.httpInfo('HTTP_RES seq=99 path=/media/gallery/count http=200 business=200 bytes=40');
Import.runtimeInfo('camera candidate model=S5M2 rssi=-45');
Import.emitTrace(['ACTION_MODE status=0 evidence=CONFIRMED']);
Import.runtimeInfo('notify dcba3a74-80bc-4919-8ef4-0c9f99cc20dd len=1 raw=03');
Import.runtimeInfo('notify 00000000-0000-0000-0000-000000000000 len=1 raw=ff');
Import.logError('gallery refresh', { name: 'BusinessError', code: 2300006, message: fixtureSecret });
assert(Store.todayLogText().includes('seq=99'));
assert(Store.todayLogText().includes('model=S5M2'));
assert(Store.todayLogText().includes('code=2300006'));
assert(Store.todayLogText().includes('characteristic=AP_STATE valueHex=03 meaning=UNRESOLVED'));
assert(!Store.todayLogText().includes('valueHex=ff'));
Diagnostics.exception('APP', 'unhandled', null);

// Validate using the exact server parser, including limits, not a test reimplementation.
const server = fs.readFileSync('server/log-receiver.js', 'utf8');
const parserStart = server.indexOf('function validateLogText(text)');
const parserEnd = server.indexOf('\n}', parserStart) + 2;
const check = vm.runInNewContext(`const MAX_LINES=20000,MAX_LINE_BYTES=4096;
const LOG_LINE_RE=/^\u005cd{4}-\u005cd{2}-\u005cd{2}T\u005cd{2}:\u005cd{2}:\u005cd{2}(\.\u005cd{1,3})?Z \u005cS/;
${server.slice(parserStart, parserEnd)}; validateLogText`, { Buffer });
assert(check(Store.uploadLogText()));
const stamp = '2026-10-10T12:00:00.000Z ';
const oversized = Array.from({ length: 15000 }, (_, i) => stamp + `event=${i} ` + '中🙂'.repeat(100)).join('\n') +
  '\nnot-a-timestamp\n' + stamp + 'latest_failure business=403\n' + stamp + 'broken\ufffd\n';
const bounded = Policy.prepareUpload(oversized);
assert(Buffer.byteLength(bounded, 'utf8') <= 1024 * 1024);
assert(check(bounded)); assert(bounded.includes('latest_failure business=403'));
assert(!bounded.includes('not-a-timestamp')); assert(!bounded.includes('\ufffd'));
assert(check(Policy.prepareUpload(bounded)));
assert.strictEqual(Policy.prepareUpload('invalid only'), '');
// Line count limit independent of byte size.
assert(check(Policy.prepareUpload((stamp + 'x\n').repeat(22000))));
// Rotation overwrites the previous bounded file instead of growing the current file.
const currentPath = [...files.keys()].find(k => k.endsWith('.txt') && !k.endsWith('-prev.txt'));
files.set(currentPath, Buffer.alloc(4 * 1024 * 1024 + 1));
files.set(currentPath.replace('.txt', '-prev.txt'), Buffer.from('old'));
Store.add('rotation latest'); Store.flushNow();
assert(files.get(currentPath).length < 4096);
// Disk unavailable and diagnostic sinks throwing cannot break business code.
failDisk = true; Store.init('/synthetic/unwritable'); Store.add('memory_only');
assert(Store.uploadLogText().includes('memory_only'));
Diagnostics.configure(() => { throw new Error('sink failed'); }, () => { throw new Error('flush failed'); });
assert.doesNotThrow(() => Diagnostics.exception('APP', 'flow exception', { code: 1 }));
assert.doesNotThrow(() => Diagnostics.event('VIVID_BLE', 'FLOW_PHASE phase=ble'));
// Execute the real feedback sender without reading its credential declarations.
const profile = read('pages/home/ProfileSection.ets');
const sendStart = profile.indexOf('  private async sendLogToServer()');
const sendEnd = profile.indexOf('\n  }', sendStart) + 5;
assert(sendStart >= 0 && sendEnd > sendStart);
let requestCount = 0, destroyed = 0, responseCode = 200, shouldFail = false;
const http = { RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 0 }, createHttp: () => ({
  async request(url, options) {
    requestCount++; assert.strictEqual(options.method, 'POST');
    assert(check(Buffer.from(options.extraData).toString('utf8')));
    assert(options.extraData.byteLength <= 1024 * 1024);
    assert(!Buffer.from(options.extraData).toString('utf8').includes(fixtureSecret));
    if (shouldFail) throw { code: 2300006, message: 'synthetic offline' };
    return { responseCode };
  }, destroy: () => { destroyed++; },
}) };
const sender = loadSource(`export class TestSender {
  logSendPreviewText=''; logSending=false; logSendResult=''; feedbackExportStatus=''; logDeviceId='synthetic-test';
  // sendLogToServer 现在先查华为账号登录态（未登录直接 return，不会清空预览文本）。
  // 本套件验证的是"已登录 + 上传成功/失败"这条链路，所以桩件必须带登录态。
  logSendLoggedIn=true;
  ${profile.slice(sendStart, sendEnd).replace('private async', 'async')}
}`, {}, { AppLogPolicy: Policy, AppLogStore: { add: () => {} }, util, http,
  LOG_UPLOAD_URL: 'https://synthetic.invalid/api/logs', LOG_UPLOAD_TOKEN: 'synthetic-upload-key' }).TestSender;
(async () => {
  const page = new sender(); page.logSendPreviewText = oversized;
  await page.sendLogToServer(); assert.strictEqual(page.logSending, false);
  assert.strictEqual(page.logSendPreviewText, ''); assert(page.feedbackExportStatus.includes('日志已发送'));
  responseCode = 400; page.logSendPreviewText = bounded;
  await page.sendLogToServer(); assert(page.logSendResult.includes('400')); assert.strictEqual(page.logSending, false);
  responseCode = 429; await page.sendLogToServer(); assert(page.logSendResult.includes('20'));
  shouldFail = true; await page.sendLogToServer(); assert.strictEqual(page.logSending, false);
  page.logSendPreviewText = 'invalid-only'; const before = requestCount;
  await page.sendLogToServer(); assert.strictEqual(requestCount, before); assert.strictEqual(page.logSending, false);
  assert.strictEqual(destroyed, 5);
  console.log('PASS: app-owned diagnostics, caught exceptions, redaction, UTF-8 limits, receiver parser, disk fallback, feedback POST/success/error cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
