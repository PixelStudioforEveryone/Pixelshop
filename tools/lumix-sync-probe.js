'use strict';
/*
 * LUMIX Sync BLE pairing probe (Frida)
 *
 * Captures the full BLE pairing exchange between the official LUMIX Sync
 * app (com.panasonic.jp.lumixsync) and a Panasonic camera at three levels:
 *
 *   1. Android framework BLE API (BluetoothGatt + callbacks): the exact
 *      over-the-air operations - connect, CCCD descriptor writes,
 *      characteristic reads/writes with hex payloads, write types,
 *      statuses and timestamps.
 *   2. The app's semantic layer (I5.g T0/R0/q1/r1 = registNotify/read/
 *      write by numeric key, I5.e.A marker): the protocol sequence as the
 *      app itself drives it.
 *   3. The crypto helpers (N5.o a/c/d encoders, z5.b identity/key, N5.l
 *      identity strings): session key, MEI0 identity bytes and encoded
 *      payloads. The decoded Wi-Fi password is masked (length only); raw
 *      encoded payloads are printed because they are required to diff
 *      against the HarmonyOS implementation.
 *
 * NOTE: the log contains recoverable credential material for the camera
 * (session key + encoded Wi-Fi password). Keep it local.
 *
 * Usage (frida-server running on the Android device, or frida-gadget):
 *   frida -U -f com.panasonic.jp.lumixsync -l lumix-sync-probe.js -o sync-probe.log
 * or attach to an already-running app:
 *   frida -U -n "LUMIX Sync" -l lumix-sync-probe.js -o sync-probe.log
 *
 * Capture procedure (fresh pairing):
 *   1. On the camera, delete the registered smartphone first
 *      (menu -> Bluetooth -> delete registration) so the full first-time
 *      pairing flow including the camera-side confirmation is captured.
 *   2. Start the probe with the spawn command above.
 *   3. In the app, run the pairing/connect flow with the camera and
 *      complete it - including the camera-side confirmation - until the
 *      app joins the camera Wi-Fi.
 *   4. Stop frida and share sync-probe.log.
 */

var T0 = Date.now();
function ts() { return '+' + (Date.now() - T0) + 'ms'; }
function log(msg) { console.log('[LSP ' + ts() + '] ' + msg); }

function jhex(arr) {
  if (arr === null || arr === undefined) return 'null';
  var out = '';
  try {
    for (var i = 0; i < arr.length; i++) {
      var b = arr[i] & 0xff;
      out += (b < 16 ? '0' : '') + b.toString(16);
    }
  } catch (e) { return 'hex-err'; }
  return out;
}
function cuuid(ch) { try { return ch.getUuid().toString(); } catch (e) { return '?'; } }
function duuid(d) { try { return d.getUuid().toString(); } catch (e) { return '?'; } }
function downer(d) {
  try { var c = d.getCharacteristic(); return c ? c.getUuid().toString() : '-'; } catch (e) { return '-'; }
}
function jstr(v) { try { return v === null || v === undefined ? 'null' : String(v); } catch (e) { return '?'; } }
function keyHex(v) {
  try {
    var n = parseInt(String(v), 10) >>> 0;
    var h = n.toString(16);
    while (h.length < 8) h = '0' + h;
    return '0x' + h;
  } catch (e) { return jstr(v); }
}
function tryUse(name) { try { return Java.use(name); } catch (e) { return null; } }

/** Hook every overload; fmt(args, retVal, thisObj) runs AFTER the original. */
function hookAll(cls, name, fmt) {
  try {
    var m = cls[name];
    if (!m || !m.overloads) return 0;
    m.overloads.forEach(function (ov) {
      var saved = ov;
      ov.implementation = function () {
        var args = Array.prototype.slice.call(arguments);
        var ret = saved.apply(this, args);
        try { fmt(args, ret, this); } catch (e) { log(name + '#fmt ' + e); }
        return ret;
      };
    });
    return m.overloads.length;
  } catch (e) { log(name + '#hook ' + e); return 0; }
}

Java.perform(function () {
  log('probe attached pid=' + Process.id);

  // ---- 1. Framework: connection management --------------------------------
  var Device = Java.use('android.bluetooth.BluetoothDevice');
  hookAll(Device, 'connectGatt', function (a, r, self) {
    var cb = '?';
    for (var i = 0; i < a.length; i++) {
      if (a[i] && a[i].$className) cb = a[i].$className;
    }
    log('connectGatt device=' + self.getAddress() + ' name=' + jstr(self.getName()) +
      ' autoConnect=' + (a.length > 1 ? a[1] : '?') + ' cb=' + cb +
      (a.length > 3 ? ' transport=' + a[3] : '') + (a.length > 4 ? ' phy=' + a[4] : '') +
      ' -> ' + (r ? 'ok' : 'null'));
  });

  var Gatt = Java.use('android.bluetooth.BluetoothGatt');
  hookAll(Gatt, 'connect', function (a, r) { log('gatt.connect -> ' + r); });
  hookAll(Gatt, 'disconnect', function () { log('gatt.disconnect'); });
  hookAll(Gatt, 'close', function () { log('gatt.close'); });
  hookAll(Gatt, 'discoverServices', function (a, r) { log('gatt.discoverServices -> ' + r); });
  hookAll(Gatt, 'requestMtu', function (a, r) { log('gatt.requestMtu ' + a[0] + ' -> ' + r); });
  hookAll(Gatt, 'requestConnectionPriority', function (a, r) {
    log('gatt.requestConnectionPriority ' + a[0] + ' -> ' + r);
  });
  hookAll(Gatt, 'setCharacteristicNotification', function (a, r) {
    log('setCharacteristicNotification char=' + cuuid(a[0]) + ' enable=' + a[1] + ' -> ' + r);
  });
  hookAll(Gatt, 'readCharacteristic', function (a, r) {
    log('READ req char=' + cuuid(a[0]) + ' svc=' + (a.length > 1 && a[0] ? '' : '') + ' -> ' + r);
  });
  hookAll(Gatt, 'writeCharacteristic', function (a, r) {
    var ch = a[0];
    var val = (a.length >= 3 && a[1] !== null && a[1] !== undefined) ? a[1] : ch.getValue();
    var wt = (a.length >= 3) ? a[2] : ch.getWriteType();
    log('WRITE req char=' + cuuid(ch) + ' writeType=' + wt + ' value=' + jhex(val) + ' -> ' + r);
  });
  hookAll(Gatt, 'writeDescriptor', function (a, r) {
    var d = a[0];
    var val = (a.length >= 2 && a[1] !== null && a[1] !== undefined) ? a[1] : d.getValue();
    log('WRITE-DESC char=' + downer(d) + ' desc=' + duuid(d) + ' value=' + jhex(val) + ' -> ' + r);
  });
  hookAll(Gatt, 'readDescriptor', function (a, r) {
    log('READ-DESC char=' + downer(a[0]) + ' desc=' + duuid(a[0]) + ' -> ' + r);
  });

  // ---- 2. Callback side: subclass discovery + event hooks -----------------
  var hookedCallbacks = {};
  function hookCallbackClass(name) {
    if (hookedCallbacks[name]) return;
    hookedCallbacks[name] = true;
    var C = tryUse(name);
    if (!C) return;
    log('callback class discovered: ' + name);
    ['onServicesDiscovered', 'onConnectionStateChange', 'onCharacteristicRead',
      'onCharacteristicWrite', 'onCharacteristicChanged', 'onDescriptorWrite',
      'onDescriptorRead', 'onMtuChanged'].forEach(function (mn) {
        hookAll(C, mn, function (a, r) {
          if (mn === 'onServicesDiscovered') {
            log('CB onServicesDiscovered status=' + a[1]);
          } else if (mn === 'onConnectionStateChange') {
            log('CB onConnectionStateChange status=' + a[1] + ' newState=' + a[2]);
          } else if (mn === 'onCharacteristicRead') {
            log('CB onCharacteristicRead char=' + cuuid(a[1]) + ' status=' + a[a.length - 1] +
              ' value=' + jhex(a.length >= 4 ? a[2] : a[1].getValue()));
          } else if (mn === 'onCharacteristicWrite') {
            log('CB onCharacteristicWrite char=' + cuuid(a[1]) + ' status=' + a[2]);
          } else if (mn === 'onCharacteristicChanged') {
            log('CB onCharacteristicChanged char=' + cuuid(a[1]) +
              ' value=' + jhex(a.length >= 3 ? a[2] : a[1].getValue()));
          } else if (mn === 'onDescriptorWrite') {
            log('CB onDescriptorWrite char=' + downer(a[1]) + ' desc=' + duuid(a[1]) + ' status=' + a[2]);
          } else if (mn === 'onDescriptorRead') {
            log('CB onDescriptorRead char=' + downer(a[1]) + ' status=' + a[a.length - 1]);
          } else if (mn === 'onMtuChanged') {
            log('CB onMtuChanged mtu=' + a[1] + ' status=' + a[2]);
          }
        });
      });
  }
  var CallbackBase = Java.use('android.bluetooth.BluetoothGattCallback');
  hookAll(CallbackBase, '$init', function (a, r, self) {
    try { hookCallbackClass(self.$className); } catch (e) { }
  });

  // ---- 3. App semantic layer (obfuscated names of this APK version) -------
  var G = tryUse('I5.g');
  if (G) {
    hookAll(G, 'T0', function (a, r) { log('g.T0(' + a[0] + ') -> ' + jstr(r) + ' [registNotify]'); });
    hookAll(G, 'R0', function (a, r) { log('g.R0(' + a[0] + ') -> ' + jstr(r) + ' [read]'); });
    hookAll(G, 'q1', function (a, r) { log('g.q1(' + a[0] + ', ' + jhex(a[1]) + ') -> ' + jstr(r) + ' [write]'); });
    hookAll(G, 'r1', function (a, r) {
      log('g.r1(' + a[0] + ', ' + (a[1] === null ? 'null' : jhex(a[1])) + ') -> ' + jstr(r) + ' [queued write]');
    });
  } else { log('I5.g not found - obfuscation differs in this APK version'); }

  var E = tryUse('I5.e');
  if (E) {
    hookAll(E, 'A', function () { log('e.A() [registNotify all]'); });
  }

  var L = tryUse('N5.l');
  if (L) {
    hookAll(L, 'A', function (a, r) { log('l.A() -> ' + jstr(r) + ' [identity hex]'); });
    hookAll(L, 'y', function (a, r) { log('l.y() -> ' + jstr(r) + ' [identity dotted]'); });
  }

  var O = tryUse('N5.o');
  if (O) {
    hookAll(O, 'c', function (a, r) {
      log('o.c(name=' + jstr(a[0]) + ', key=' + keyHex(a[1]) + ', len=' + a[2] + ') -> ' + jhex(r) + ' [encode name]');
    });
    hookAll(O, 'd', function (a, r) {
      log('o.d(uuid=' + jhex(a[0]) + ', key=' + keyHex(a[1]) + ', len=' + a[2] + ') -> ' + jhex(r) + ' [encode uuid]');
    });
    hookAll(O, 'a', function (a, r) {
      log('o.a(raw=' + jhex(a[0]) + ', key=' + keyHex(a[1]) + ') -> decodedLen=' +
        (r === null ? 'null' : String(r).length) + ' [decode password]');
    });
  }

  var B = tryUse('z5.b');
  if (B) {
    hookAll(B, 'b', function (a, r) { log('z5.b.b() -> ' + jhex(r) + ' [identity bytes]'); });
    hookAll(B, 'c', function (a, r) { log('z5.b.c() -> ' + jstr(r) + ' [device name]'); });
    hookAll(B, 'e', function (a, r) { log('z5.b.e(' + jhex(a[0]) + ') -> ' + keyHex(r) + ' [key extract]'); });
  }

  log('probe ready');
});
