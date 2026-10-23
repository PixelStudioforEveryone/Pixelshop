// Exercise the production registry and page selection code with synthetic radio identities.
const fs=require('fs'),vm=require('vm'),assert=require('assert');
const ts=require('D:/DevEco Studio/tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const data=new Map();let now=100000,writes=0;
class Clock extends Date {static now(){return now;}}
const route=model=>/(^|\s)(S5|GH5|GH6|G9)(\s|$)/.test(model)?'sync':'lab';
const store={get:async(k,d)=>data.has(k)?data.get(k):d,
 put:async(k,v)=>{await new Promise(r=>setTimeout(r,1));data.set(k,v);writes++;},flush:async()=>{}};
const source=fs.readFileSync('entry/src/main/ets/services/CameraCardRegistry.ets','utf8');
const mod={exports:{}};
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
 {module:mod,exports:mod.exports,Date:Clock,Map,Set,Promise,Number,Array,console,
 require:id=>id==='@kit.ArkData'?{preferences:{getPreferences:async()=>store}}:
 id==='./LumixCameraService'?{LumixCameraService:{panasonicRouteForModel:route,
   // CameraCardRegistry classifies the route with isCamCgiRoute(); production defines it
   // as `route === 'sync' || route === 'lumix_image'` (LumixCameraService:1127).
   isCamCgiRoute:(r)=>r==='sync'||r==='lumix_image'}}:{} });
const {CameraCardRegistry}=mod.exports;
const camera=(name,brand='Panasonic',model='S5M2',image='panasonic_s5m2',device='synthetic-address')=>
 ({deviceId:device,deviceName:name,brand,model,imageKey:image,rssi:-45,connectable:!!device});
const ap=(name,brand='Panasonic',model='S5',image='panasonic_s5')=>
 ({ssid:name,brand,model,imageKey:image,rssi:-45,bssid:'',securityType:0,family:'synthetic'});
const names=cards=>Array.from(cards,c=>c.deviceName);
const pageSource=fs.readFileSync('entry/src/main/ets/pages/home/CameraPage.ets','utf8');
function method(name){
 const re=new RegExp('  private (?:async )?'+name+'\\('),start=pageSource.search(re);
 assert(start>=0,name);const end=pageSource.indexOf('\n  }',start)+5;
 assert(end>start,name);return pageSource.slice(start,end).replace(/^  private /,'');
}
const methods=['cameraCandidateKey','selectedCameraCard','selectedCameraRemembered','refreshCameraCards','applyCameraCandidate',
 'selectCameraCandidate','cameraConnectionAvailable','primaryCameraActionAvailable','cameraRegisteredTransferAvailable',
 'cameraBleTransferReady','cameraIsReachable','rememberCameraCard','removeCameraConnection',
 'cameraCardIsSelected','cameraCardRenderKey','selectCameraCardByKey'].map(method).join('\n');
const pageModule={exports:{}};
vm.runInNewContext(ts.transpileModule(`class CameraHarness {
 cameraCards; cam={cameraState:0,cameraBrand:'Panasonic',cameraModel:'LUMIX',cameraImageKey:'',cameraBleCandidateName:'',
 cameraBleCandidateModel:'',cameraBleStatus:'未连接',cameraWifiStatus:'未连接',cameraSessionStatus:'未建立',cameraTransferInProgress:false,cameraWifiSsid:''};
 cameraBleCandidates=[];cameraBleSelectedIndex=0;cameraBleCandidateDeviceId='';cameraBleCandidateImageKey='';cameraBleCandidateBrand='Panasonic';
 cameraBleCandidateConnectable=false;cameraBleLastSeenAt=0;cameraPairingAttempted=false;cameraWifiOnlyReady=false;cameraTransport=0;syncWifiDetected=false;
 isCamCgiLineSelected=()=>route(this.cam.cameraModel)==='sync'||route(this.cam.cameraModel)==='lumix_image';
 isImageAppSelected=()=>route(this.cam.cameraModel)==='lumix_image';
 wifiConnecting=false;
 constructor(registry){this.cameraCards=registry;}
 isPtpIpCamera(){return this.cam.cameraBrand==='Nikon'||this.cam.cameraBrand==='Sony';}
 syncRouteSelected(){return this.cam.cameraBrand==='Panasonic'&&route(this.cam.cameraModel)==='sync';}
 // CameraPage's sliced methods delegate these two predicates to the camera service
 // (cam.isCamCgiLineSelected / cam.isImageAppSelected, CameraPage:1384/1394), so the
 // harness has to provide that indirection.
 camCgiRouteSelected(){return this.isCamCgiLineSelected();}
 imageAppSelected(){return this.isImageAppSelected();}
 cameraWifiConnected(){return this.cam.cameraWifiStatus==='已连接';}
 alignSelectedCameraCard(){this.alignedName=this.cam.cameraBleCandidateName;}
 brandForImageKey(key){return key.startsWith('nikon_')?'Nikon':key.startsWith('sony_')?'Sony':'Panasonic';}
 cameraImageKeyForName(){return '';}
 getUIContext(){return {getHostContext:()=>({})};}
 cameraWifiMatchesSelectedIdentity(wifi){return this.cam.cameraBleCandidateName===wifi.ssid;}
 showMessage(message){throw new Error(message);}
 stopCameraBleDiscovery(){throw new Error('must not stop another camera');}
 ${methods}
} module.exports=CameraHarness;`,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
 {module:pageModule,Date:Clock,Math,route,LumixCameraService:{isWifiOnlyModel:()=>false},
 LumixImportPrototype:{rememberedCameraName:async()=>'',clearRememberedCamera:async()=>{},removeSystemPairing:async()=>false},console});
const Page=pageModule.exports;

(async()=>{
 const r=new CameraCardRegistry(),ctx={};await r.load(ctx);
 const s5=camera('S5_100001','Panasonic','S5','panasonic_s5',''),lab=camera('S5M2_200002');
 const z5=camera('Z_5_300003','Nikon','NIKON Z 5','nikon_z5'),z8=camera('NIKON_Z_8_400004','Nikon','NIKON Z 8','nikon_z8');
 await r.remember(ctx,lab,'S1-AP-SYNTHETIC',true,now-4000);
 await r.remember(ctx,s5,s5.deviceName,false,now-3000);
 await r.remember(ctx,z5,'NIKON_Z_5_300003',false,now-2000);
 await r.remember(ctx,z8,z8.deviceName,false,now-1000);
 assert.deepStrictEqual(names(r.cards()),[z8.deviceName,z5.deviceName,s5.deviceName,lab.deviceName]);
 assert(r.cards().every(c=>!r.isOnline(c)&&!c.connectable&&c.deviceId===''),'saved identity is not a live radio');
 const reopened=new CameraCardRegistry();await reopened.load(ctx);
 assert.deepStrictEqual(names(reopened.cards()),names(r.cards()),'offline cards persist across app restart');
 assert(reopened.isBlePaired(lab));assert(!reopened.isBlePaired(s5));
 const writesBefore=writes;
 r.observeBle(lab,now);assert.strictEqual(r.key(lab),r.key(camera(lab.deviceName,lab.brand,lab.model,lab.imageKey,'rotated')));
 r.replaceWifi([ap(s5.deviceName)]);assert.deepStrictEqual(names(r.cards()).slice(0,2).sort(),[lab.deviceName,s5.deviceName].sort());
 const observed=camera('S9_500005','Panasonic','S9','panasonic_s9');now+=50;r.observeBle(observed);
 assert.strictEqual(r.cards()[0].deviceName,observed.deviceName,'newly visible camera precedes offline history');
 const order=names(r.cards());now+=50;r.observeBle(lab);assert.deepStrictEqual(names(r.cards()),order,'repeated advertisements do not reshuffle visible bodies');
 assert.strictEqual(writes,writesBefore,'scanning never writes history/last-used');assert(!r.isSaved(observed));
 r.replaceWifi([]);assert(r.cards().some(c=>c.deviceName===s5.deviceName&&!r.isOnline(c)),'successful S5 AP survives disappearance');
 r.replaceWifi([ap('NIKON_Z_5_300003','Nikon','NIKON Z 5','nikon_z5')]);r.observeBle(z5);
 assert.strictEqual(r.cards().filter(c=>r.key(c)===r.key(z5)).length,1,'BLE/AP alias maps to one saved camera');
 r.observeBle(camera('Z_5_300099','Nikon','NIKON Z 5','nikon_z5'));
 assert.strictEqual(r.cards().filter(c=>c.imageKey==='nikon_z5').length,2,'same-model serials must not merge');
 now+=13000;r.replaceWifi([]);
 assert.deepStrictEqual(names(r.cards()),[z8.deviceName,z5.deviceName,s5.deviceName,lab.deviceName]);
 assert(!r.cards().some(c=>c.deviceName===observed.deviceName),'unconnected discovery expires');
 await r.remember(ctx,lab,'S1-AP-SYNTHETIC',true,now);
 assert.strictEqual(r.cards()[0].deviceName,lab.deviceName,'successful reuse updates offline recent-use order');
 r.setConnected(z8);await r.forget(ctx,z5);
 assert(!r.cards().some(c=>c.deviceName===z5.deviceName));assert(r.hasOtherConnection(lab));assert(r.isOnline(z8),'deleting another body keeps live camera');
 await r.forget(ctx,s5);assert(r.isSaved(lab)&&r.isSaved(z8));
 const afterDelete=new CameraCardRegistry();await afterDelete.load(ctx);assert.deepStrictEqual(names(afterDelete.cards()),[lab.deviceName,z8.deviceName]);
 await Promise.all([r.remember(ctx,s5,'',false,now+1),r.remember(ctx,z5,'',false,now+2)]);
 const concurrent=new CameraCardRegistry();await concurrent.load(ctx);assert.strictEqual(concurrent.cards().length,4,'serialized persistence retains both successes');
 const encoded=data.get('connections_v1');assert(!/synthetic-address|bssid|password|token|deviceId/.test(encoded),'only identity/time are persisted');
 const migrated=new CameraCardRegistry();await migrated.migrateLegacy(ctx,camera('S1RM2_600006','Panasonic','S1RM2','panasonic_s1rii'));
 await migrated.forget(ctx,camera('S1RM2_600006','Panasonic','S1RM2','panasonic_s1rii'));
 const restart=new CameraCardRegistry();await restart.migrateLegacy(ctx,camera('S1RM2_600006','Panasonic','S1RM2','panasonic_s1rii'));
 assert(!restart.cards().some(c=>c.deviceName==='S1RM2_600006'),'legacy migration cannot resurrect deleted camera');
 const page=new Page(restart);page.refreshCameraCards();
 let labIndex=page.cameraBleCandidates.findIndex(c=>c.deviceName===lab.deviceName);page.selectCameraCandidate(labIndex);
 assert(page.selectedCameraRemembered());assert(page.primaryCameraActionAvailable(),'offline delete is enabled');
 assert(!page.cameraRegisteredTransferAvailable()&&!page.cameraConnectionAvailable(),'offline record must not enable connection/transfer');
 restart.observeBle(observed);page.refreshCameraCards();assert.strictEqual(page.cameraBleCandidates[0].deviceName,observed.deviceName);
 assert.strictEqual(page.cam.cameraBleCandidateName,lab.deviceName,'reorder must retain selected connection target');
 assert.strictEqual(page.cameraBleCandidates[page.cameraBleSelectedIndex].deviceName,lab.deviceName);
 const observedKey=restart.key(observed);const tileKey=page.cameraCardRenderKey(observed);
 page.selectCameraCardByKey(observedKey);assert.strictEqual(page.cam.cameraBleCandidateName,observed.deviceName,'tile click resolves identity after reorder');
 assert.notStrictEqual(tileKey,page.cameraCardRenderKey(observed),'selection refreshes the retained ArkUI tile');
 page.selectCameraCardByKey(restart.key(lab));
 restart.observeBle(lab);page.refreshCameraCards();assert(page.cameraRegisteredTransferAvailable(),'registered nearby Lab camera can transfer without pairing');
 page.cam.cameraTransferInProgress=true;
 page.selectCameraCandidate(page.cameraBleCandidates.findIndex(c=>c.deviceName===observed.deviceName));
 assert.strictEqual(page.cam.cameraBleCandidateName,lab.deviceName,'ongoing handshake keeps the chosen target');page.cam.cameraTransferInProgress=false;
 restart.replaceWifi([ap(s5.deviceName)]);page.refreshCameraCards();page.selectCameraCandidate(page.cameraBleCandidates.findIndex(c=>c.deviceName===s5.deviceName));
 assert(page.syncWifiDetected&&page.cameraConnectionAvailable());assert.strictEqual(page.cam.cameraBleStatus,'未连接','AP discovery must not claim Bluetooth connected');
 restart.replaceWifi([]);page.refreshCameraCards();assert(!page.syncWifiDetected&&!page.cameraConnectionAvailable());assert(page.selectedCameraRemembered());
 assert(page.cameraCardRenderKey(s5).includes(':false:'),'offline transition updates tile render identity');
 const failed=camera('Z_5_700007','Nikon','NIKON Z 5','nikon_z5');restart.observeBle(failed);page.refreshCameraCards();
 page.selectCameraCandidate(page.cameraBleCandidates.findIndex(c=>c.deviceName===failed.deviceName));assert(!page.selectedCameraRemembered(),'confirmation/failed Wi-Fi alone is not saved');
 page.cam.cameraWifiStatus='已连接';page.cam.cameraWifiSsid=failed.deviceName;await page.rememberCameraCard();assert(page.selectedCameraRemembered(),'physical Wi-Fi success persists');
 page.selectCameraCandidate(page.cameraBleCandidates.findIndex(c=>c.deviceName===lab.deviceName));
 page.showMessage=()=>{};await page.removeCameraConnection();
 assert(!restart.isSaved(lab),'actual page deletion removes only selected saved identity');
 assert(restart.isSaved(failed)&&restart.isOnline(failed),'actual page deletion does not stop another live Wi-Fi connection');
 console.log('PASS successful multi-camera persistence, offline recent-use order, BLE/Wi-Fi priority, stable selection, alias/serial isolation, delete isolation, legacy migration, concurrent writes, offline button availability and physical Wi-Fi success');
})().catch(error=>{console.error(error);process.exitCode=1;});
