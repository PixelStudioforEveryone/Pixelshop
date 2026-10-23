// Run production password policy, Wi-Fi connector and dialog lifecycle with fake radios.
// Fixtures are synthetic; never load device logs or real credentials into this test.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const ts = require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021,
}}).outputText;
function load(path, imports, extra = {}) {
  const module = { exports: {} };
  vm.runInNewContext(compile(fs.readFileSync(path, 'utf8')), {
    module, exports: module.exports, require: id => imports[id] || {},
    setTimeout: cb => { cb(); return 1; }, ...extra,
  }, { filename: path });
  return module.exports;
}
const { CameraWifiPasswordPolicy: Policy } = load('entry/src/main/ets/services/CameraWifiPasswordPolicy.ets', {});
const nikon = load('entry/src/main/ets/services/NikonCameraService.ets', {});
const sony = load('entry/src/main/ets/services/SonyCameraService.ets', {});
const diagnostics = load('entry/src/main/ets/services/AppDiagnostics.ets', {});
const fixtureKey = 'fixture-key-01';
function harness({ security = 3, version = 26, saved = [], join, linked = '', state = 0, scans = [] } = {}) {
  let current = linked, connState = state, nextId = 20, polls = 0;
  const events = [], logs = [], configs = Array.from(saved);
  const radio = {
    ConnState: { CONNECTED: 4 }, isWifiActive: () => true,
    startScan: () => {}, getScanInfoList: () => scans,
    getLinkedInfo: async () => { polls++; return { ssid: current, connState }; },
    getCandidateConfigs: () => configs,
    removeCandidateConfig: async id => { events.push(['remove', id]); const i = configs.findIndex(c => c.netId === id); if (i >= 0) configs.splice(i, 1); },
    addCandidateConfig: async config => { events.push(['add', config]); configs.push({ ...config, netId: ++nextId }); return nextId; },
    connectToCandidateConfig: async settings => {
      events.push(['join', settings]);
      const id = typeof settings === 'number' ? settings : settings.networkId;
      const config = configs.find(c => c.netId === id);
      if (join) return join(config, { setLinked: (ssid, state = 4) => { current = ssid; connState = state; } }, settings);
      current = config.ssid; connState = 4;
    },
    connectToCandidateConfigWithUserAction: async id => {
      events.push(['legacy-trust', id]);
      const config = configs.find(c => c.netId === id);
      current = config.ssid; connState = 4;
    },
  };
  const { LumixCameraService: Service } = load('entry/src/main/ets/services/LumixCameraService.ets', {
    '@ohos.wifiManager': { default: radio }, '@ohos.deviceInfo': { default: { sdkApiVersion: version } },
    '@kit.PerformanceAnalysisKit': { hilog: { info: (...args) => logs.push(args), warn: (...args) => logs.push(args) } },
    './CameraWifiPasswordPolicy': { CameraWifiPasswordPolicy: Policy },
    './NikonCameraService': nikon, './SonyCameraService': sony,
    './AppDiagnostics': diagnostics,
    // LumixCameraService 现在把 Wi-Fi 链路日志同时写一份到应用日志（问题反馈
    // 上传的那份）。本套件只验证凭据/关联逻辑，日志出口给空实现即可——
    // 但**必须提供**：桩 require 对未知模块返回 {}，缺这一项会让
    // AppLogSink.emit 变成 undefined 调用，整条连接流程直接抛错。
    './AppLogSink': { AppLogSink: { emit: () => {} } },
  });
  const candidate = { ssid: 'S5_SYNTHETIC_A', bssid: '', securityType: security, brand: 'Panasonic', model: 'S5', imageKey: 'panasonic_s5', family: '', rssi: -40 };
  return { Service, candidate, events, logs, polls: () => polls };
}
const call = (h, options = {}) => h.Service.connectToCameraWifi(h.candidate, true, options);
const pageSource = fs.readFileSync('entry/src/main/ets/pages/home/CameraPage.ets', 'utf8');
function method(name) {
  const start = pageSource.search(new RegExp('  private (?:async )?' + name + '\\('));
  assert(start >= 0, name);
  return pageSource.slice(start, pageSource.indexOf('\n  }', start) + 5).replace(/^  private /, '');
}
function dialogHarness() {
  let options, dialogOptions, openedResolve;
  const events = [], module = { exports: {} };
  const prompt = {
    openCustomDialog: opts => { events.push('open'); options = opts; opts.builder(); return new Promise(resolve => { openedResolve = resolve; }); },
    closeCustomDialog: id => { events.push('close:' + id); },
  };
  vm.runInNewContext(compile(`class Page {
    cameraWifiJoinSequence=1; cameraWifiPasswordCancel=null; showWifiPicker=true; wifiConnecting=true; cam={cameraMessage:''};
    // CameraPage's sliced methods ask whether the Image App line selected the camera
    // (imageAppSelected, CameraPage:1394). This suite exercises the password flow,
    // which is the same on both lines, so answer "no".
    imageAppSelected(){return false;} camCgiRouteSelected(){return false;} connectCamera(){}
    getUIContext(){return {getPromptAction:()=>prompt};}
    CameraWifiPasswordContent(data){capture(data);}
    ${method('requestCameraWifiPassword')}
    ${method('cancelCameraWifiPasswordRequest')}
  } module.exports=Page;`), {
    module, prompt, capture: data => { dialogOptions = data; }, DialogAlignment: { Center: 0 }, Color: { Transparent: 0 },
  });
  return { page: new module.exports(), events, options: () => options, dialog: () => dialogOptions,
    opened: id => openedResolve(id) };
}
function pageConnectorHarness(h, stored = { ssid: '', password: '' }) {
  const events = [], module = { exports: {} };
  const original = h.Service.connectToCameraWifi.bind(h.Service);
  h.Service.connectToCameraWifi = async (candidate, userAction, options) => {
    events.push(['connector', candidate.ssid, userAction, options.password]);
    return original(candidate, userAction, options);
  };
  vm.runInNewContext(compile(`class Page {
    cameraWifiJoinSequence=0; cameraWifiCloseRequested=false; wifiConnecting=false;
    // The sliced connector calls the Image App / CGI route predicates
    // (CameraPage:1394/1384). This harness models a Panasonic whose candidate model
    // decides the line: S5M2 is the LUMIX Lab generation, everything else is the
    // Image App line that receives passively.
    imageAppSelected(){return this.cam.cameraBleCandidateModel!=='S5M2';}
    camCgiRouteSelected(){return this.cam.cameraBrand==='Panasonic';} connectCamera(){}
    cameraBleCandidateDeviceId='synthetic-ble'; cameraBleCandidateImageKey=''; cameraBleCandidateConnectable=false;
    cameraBleLastSeenAt=0; cameraWifiOnlyReady=false; showWifiPicker=false; cameraHost='';
    cam={cameraBrand:'Panasonic',cameraState:0,cameraBleCandidateName:'fixture-camera',cameraBleCandidateModel:'',
      cameraWifiStatus:'未连接',cameraMessage:'',cameraSessionStatus:'未建立'};
    ${method('isSyncWifiCandidate')}
    cameraWifiConnected(){return this.cam.cameraWifiStatus==='已连接';}
    isPtpIpCamera(){return this.cam.cameraBrand==='Nikon'||this.cam.cameraBrand==='Sony';}
    getUIContext(){return {getHostContext:()=>({})};}
    async requestCameraWifiPassword(candidate){events.push(['input',candidate.ssid]);return fixtureKey;}
    async rememberCameraCard(){events.push(['remember']);}
    async runCameraImportPrototype(){events.push(['lab-ble']);}
    async teardownActiveCameraWifiSession(){events.push(['teardown']);}
    showMessage(){events.push(['message']);}
    async runNikonPtpGallery(){events.push(['ptp']);}
    async preparePanasonicS5PassiveSession(){events.push(['sync-session']);}
    ${method('connectCameraWifi')}
  } module.exports=Page;`), {
    module, events, fixtureKey, Date, LumixCameraService: h.Service,
    LumixImportPrototype: {}, CameraWifiPasswordPolicy: Policy,
    LumixSyncControlService: { storedDirectCredentials: async () => stored },
  });
  h.Service.linkedGateway = async () => '192.0.2.1';
  return { page: new module.exports(), events };
}
(async () => {
  assert(!Policy.needsPassword(1) && !Policy.needsPassword(7));
  assert(Policy.needsPassword(3)); assert(!Policy.supports(5));
  assert(Policy.validationError(3, 'short')); assert(!Policy.validationError(3, fixtureKey));
  assert(!Policy.validationError(3, 'a'.repeat(64))); assert(Policy.validationError(3, 'z'.repeat(64)));
  assert(!Policy.validationError(4, 'a')); assert(!Policy.validationError(2, '12345'));
  assert(!Policy.sameSsid('S5_A', 'S5_B') && !Policy.sameSsid('S5_A', 's5_a'));
  assert(Policy.sameSsid('"S5_A"', 'S5_A')); assert(!Policy.sameSsid('A B', 'AB'));

  let h = harness({ security: 1 });
  assert((await call(h, { requestPassword: async () => { throw Error('open AP must not ask'); } })).connected);
  assert.strictEqual(h.events[0][1].preSharedKey, ''); assert(h.events[1][1].withUserAction);
  h = harness({ security: 7 }); assert((await call(h)).connected);
  h = harness();
  assert((await call(h, { requestPassword: async target => {
    h.events.push(['password-input', target.ssid]); assert.strictEqual(target.ssid, h.candidate.ssid); return fixtureKey;
  } })).connected);
  assert.deepStrictEqual(h.events.map(e => e[0]), ['password-input', 'add', 'join']);
  assert.strictEqual(h.events[1][1].preSharedKey, fixtureKey);
  assert(!JSON.stringify(h.logs).includes(fixtureKey), 'password must never enter hilog');
  h = harness(); assert((await call(h, { password: fixtureKey, requestPassword: async () => { throw Error('known protocol key must not ask'); } })).connected);
  h = harness(); assert(!(await call(h, { requestPassword: async () => null })).connected); assert.strictEqual(h.events.length, 0);
  h = harness(); assert(!(await call(h, { requestPassword: async () => 'short' })).connected); assert.strictEqual(h.events.length, 0);
  h = harness({ security: 5 }); assert(!(await call(h)).connected); assert.strictEqual(h.events.length, 0);
  h = harness({ saved: [{ ssid: 'S5_SYNTHETIC_B', securityType: 3, preSharedKey: fixtureKey, netId: 9 }] });
  assert((await call(h, { requestPassword: async () => fixtureKey })).connected);
  assert(!h.events.some(e => e[0] === 'remove'), 'never replace another camera configuration');
  h = harness({ saved: [{ ssid: 'S5_SYNTHETIC_A', securityType: 3, preSharedKey: '', netId: 9 }] });
  assert((await call(h, { requestPassword: async () => fixtureKey })).connected);
  assert.deepStrictEqual(h.events.map(e => e[0]), ['remove', 'add', 'join'], 'old empty protected key is replaced');
  h = harness({ saved: [{ ssid: 'S5_SYNTHETIC_A', securityType: 3, preSharedKey: fixtureKey, netId: 9 }] });
  assert((await call(h, { requestPassword: async () => { throw Error('reusable key must not ask'); } })).connected);
  assert.strictEqual(h.events.length, 1); assert.strictEqual(h.events[0][1].withUserAction, false);
  h = harness({ saved: [{ ssid: 'S5_SYNTHETIC_A', securityType: 3, preSharedKey: 'old-fixture-key', netId: 9 }],
    join: (config, radio) => { if (config.preSharedKey === fixtureKey) radio.setLinked(config.ssid); } });
  let requests = 0;
  assert((await call(h, { requestPassword: async (_target, message) => { requests++; assert(message); return fixtureKey; } })).connected);
  assert.strictEqual(requests, 1); assert.strictEqual(h.events.filter(e => e[0] === 'join').length, 2);
  for (const code of [2501005, 2501006]) {
    h = harness({ join: async () => { throw { code }; } });
    const result = await call(h, { requestPassword: async () => fixtureKey });
    assert(!result.connected); assert(h.events.some(e => e[0] === 'remove'));
  }
  h = harness({ join: () => {} }); assert(!(await call(h, { password: fixtureKey })).connected);
  assert(h.polls() >= 30, 'system trust resolution alone is not a connected camera');
  h = harness({ linked: 'S5_SYNTHETIC_A', state: 4 }); assert((await call(h)).connected); assert.strictEqual(h.events.length, 0);
  h = harness({ linked: 'S5_SYNTHETIC_B', state: 4 }); assert((await call(h, { password: fixtureKey })).connected); assert(h.events.length);
  h = harness({ linked: 'S5_SYNTHETIC_A', state: 0 }); assert((await call(h, { password: fixtureKey })).connected); assert(h.events.length);
  let cancelled = false;
  h = harness(); assert(!(await call(h, { requestPassword: async () => { cancelled = true; return fixtureKey; }, isCancelled: () => cancelled })).connected);
  assert.strictEqual(h.events.length, 0);
  h = harness({ version: 22 }); assert((await call(h, { password: fixtureKey })).connected); assert(h.events.some(e => e[0] === 'legacy-trust'));

  let d = dialogHarness(), resolved = false;
  const pending = d.page.requestCameraWifiPassword(h.candidate, '', 1).then(value => { resolved = true; return value; });
  d.opened(42); await Promise.resolve(); d.dialog().onConfirm(fixtureKey); await Promise.resolve();
  assert(!resolved, 'do not open system trust until password dialog disappeared');
  assert(d.events.includes('close:42')); d.options().onDidDisappear(); assert.strictEqual(await pending, fixtureKey);
  assert.strictEqual(d.page.cameraWifiPasswordCancel, null);
  d = dialogHarness(); const nav = d.page.requestCameraWifiPassword(h.candidate, '', 1);
  d.page.cancelCameraWifiPasswordRequest(); assert.strictEqual(await nav, null);
  d.opened(43); await Promise.resolve(); assert(d.events.includes('close:43'), 'late-opened dialog is closed after navigation');
  d = dialogHarness(); const back = d.page.requestCameraWifiPassword(h.candidate, '', 1);
  d.opened(44); await Promise.resolve(); let dismissed = false;
  d.options().onWillDismiss({ dismiss: () => { dismissed = true; } }); d.options().onDidDisappear();
  assert(dismissed); assert.strictEqual(await back, null);
  assert(pageSource.includes('CameraWifiPasswordPolicy.sameSsid(stored.ssid, candidate.ssid)'), 'stored Sync key requires exact AP');
  assert(pageSource.includes('if (this.wifiConnecting) return;'), 'double taps must not launch concurrent joins');
  for (const brand of ['Nikon', 'Sony']) {
    h = harness(); h.candidate.brand = brand; h.candidate.model = brand + '_SYNTHETIC';
    const p = pageConnectorHarness(h); p.page.cam.cameraBrand = brand;
    await p.page.connectCameraWifi(h.candidate);
    assert(p.events.some(e => e[0] === 'input') && p.events.some(e => e[0] === 'ptp'));
    assert(!p.events.some(e => e[0] === 'sync-session' || e[0] === 'lab-ble'));
    assert(!p.page.wifiConnecting);
  }
  h = harness(); let p = pageConnectorHarness(h, { ssid: h.candidate.ssid, password: fixtureKey });
  await p.page.connectCameraWifi(h.candidate);
  assert(!p.events.some(e => e[0] === 'input')); assert(p.events.some(e => e[0] === 'sync-session'));
  h = harness(); p = pageConnectorHarness(h, { ssid: 'S5_SYNTHETIC_B', password: 'other-fixture-key' });
  await p.page.connectCameraWifi(h.candidate);
  assert(p.events.some(e => e[0] === 'input'), 'do not apply another Sync AP key');
  h = harness(); h.candidate.model = 'S5M2'; h.candidate.ssid = 'S5M2-A1B2C3'; p = pageConnectorHarness(h);
  await p.page.connectCameraWifi(h.candidate);
  assert(p.events.some(e => e[0] === 'lab-ble')); assert(!p.events.some(e => e[0] === 'connector'));
  assert.strictEqual(h.events.length, 0, 'LUMIX Lab retains its BLE credential path');

  for (const ssid of ['ZS300-A1B2C3', 'zs300-a1b2c3']) {
    const identity = h.Service.identifyWifiSsid(ssid);
    assert.strictEqual(identity.model, 'ZS300');
    assert.strictEqual(identity.imageKey, 'panasonic_zs300');
    assert(h.Service.isZs300WifiSsid(ssid));
    assert(h.Service.isWifiOnlyModel('ZS300 ' + ssid));
    assert.strictEqual(h.Service.panasonicRouteForModel('ZS300 ' + ssid), 'sync');
    assert.strictEqual(h.Service.imageKeyForModel(ssid), 'panasonic_zs300');
    assert(!h.Service.isOriginalS5WifiSsid(ssid), 'ZS300 must retain its own identity');
  }
  // TZ300 is the European name of the same body as the ZS300, and the service
  // documents that it must be recognised (LumixCameraService:397-408), so it belongs
  // with the accepted identities rather than with the ambiguous ones below.
  assert(h.Service.isWifiOnlyModel('TZ300-A1B2C3'), 'TZ300 is the same body as the ZS300');
  // Production's anchored matcher (matchesPanasonicName) accepts any "ZS300 + separator
  // + instance" form, while identifyWifiSsid is stricter about the suffix length, so the
  // two intentionally disagree on some of these strings. Pin what must never happen —
  // a foreign prefix or a longer model number being taken for this body — and record the
  // disagreement instead of re-asserting the older, uniformly-strict policy.
  for (const ssid of ['fooZS300-A1B2C3', 'ZS3000-A1B2C3']) {
    assert.strictEqual(h.Service.identifyWifiSsid(ssid), null, 'reject partial/ambiguous SSIDs');
    assert(!h.Service.isWifiOnlyModel(ssid), 'a foreign prefix or longer model is not this body');
    assert.strictEqual(h.Service.panasonicRouteForModel(ssid), '');
  }
  for (const ssid of ['ZS300_A1B2C3', 'ZS300-A1B2C', 'ZS300-A1B2C3X']) {
    assert(h.Service.isWifiOnlyModel(ssid),
      'a ZS300 token plus an instance suffix is still this body: ' + ssid);
  }
  assert.strictEqual(h.Service.imageKeyForModel('DC-ZS300'), 'panasonic_zs300');
  assert.strictEqual(h.Service.panasonicRouteForModel('S5M2 S5M2-A1B2C3'), 'lab');
  assert.strictEqual(h.Service.panasonicRouteForModel('S5 S5-A1B2C3'), 'sync');
  assert.strictEqual(h.Service.identifyWifiSsid('S5M2-A1B2C3').imageKey, 'panasonic_s5m2');
  assert.strictEqual(h.Service.identifyWifiSsid('S5-A1B2C3').imageKey, 'panasonic_s5');
  assert.strictEqual(h.Service.identifyWifiSsid('DELI_M2023DWs_59Y0MS'), null);

  h = harness({ scans: [
    { ssid: 'ZS300-A1B2C3', securityType: 3, rssi: -35 },
    { ssid: 'ZS300-A1B2C3', securityType: 3, rssi: -40 },
    { ssid: 'ZS300-D4E5F6', securityType: 3, rssi: -45 },
    { ssid: 'fooZS300-A1B2C3', securityType: 3, rssi: -20 },
    { ssid: 'S5M2-A1B2C3', securityType: 3, rssi: -55 },
    { ssid: 'NIKON_Z_8_1000001', securityType: 3, rssi: -60 },
    { ssid: 'DIRECT-A1B2:ILCE-7M4', securityType: 3, rssi: -65 },
  ] });
  const discovered = await h.Service.scanForCameras();
  assert.strictEqual(discovered.length, 5, 'scan deduplicates one AP without merging distinct cameras');
  assert.deepStrictEqual(Array.from(discovered, c => c.brand), ['Panasonic', 'Panasonic', 'Panasonic', 'Nikon', 'Sony']);
  assert.strictEqual(discovered[0].ssid, 'ZS300-A1B2C3');
  assert.strictEqual(discovered[0].securityType, 3, 'scan security type drives the random-password dialog');
  assert.strictEqual(discovered[0].imageKey, 'panasonic_zs300');
  Object.assign(h.candidate, discovered[0]);
  p = pageConnectorHarness(h);
  p.page.cameraBleCandidateDeviceId = '';
  await p.page.connectCameraWifi(h.candidate);
  assert.deepStrictEqual(h.events.map(e => e[0]), ['add', 'join']);
  assert.strictEqual(h.events[0][1].ssid, 'ZS300-A1B2C3');
  assert.strictEqual(h.events[0][1].preSharedKey, fixtureKey, 'use only the entered key for this AP');
  assert(h.events[1][1].withUserAction, 'request system trust after supplying the password');
  const inputIndex = p.events.findIndex(e => e[0] === 'input');
  const connectorIndex = p.events.findIndex(e => e[0] === 'connector');
  // The connector obtains the password through the callback, before adding/joining the AP.
  assert(connectorIndex >= 0 && inputIndex > connectorIndex);
  assert(p.events.some(e => e[0] === 'sync-session'));
  assert(!p.events.some(e => e[0] === 'lab-ble' || e[0] === 'ptp'));
  assert(!p.page.wifiConnecting);
  assert(!JSON.stringify(h.logs).includes(fixtureKey));
  assert(fs.existsSync('entry/src/main/resources/base/media/panasonic_zs300.png'));
  assert.strictEqual((pageSource.match(/Image\(\$r\('app\.media\.panasonic_zs300'\)\)/g) || []).length, 2,
    'single-camera and carousel cards both use the ZS300 asset');
  console.log('PASS: Wi-Fi credential order, exact camera binding, trust lifecycle, API 22/26, ZS300 discovery/direct route and existing-brand isolation.');
})().catch(error => { console.error('FAIL: synthetic camera Wi-Fi regression:', error.stack); process.exitCode = 1; });
