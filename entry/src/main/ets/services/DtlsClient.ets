import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogSink } from './AppLogSink';

/**
 * Minimal DTLS 1.2 client for the camera liveview stream, reverse-engineered
 * from the official APK's UDP traffic (2026-09-19 instrumentation, session
 * pid 12832): TLS_RSA_WITH_AES_128_GCM_SHA256, stateless-cookie exchange,
 * camera self-signed certificate, client sends an EMPTY certificate.
 *
 * Record layout (13B): type(1) ver(2) epoch(2) seq(6) len(2)
 * Handshake header (12B): type(1) len(3) msg_seq(2) frag_off(3) frag_len(3)
 * AEAD payload: explicit_nonce(8) + ciphertext + tag(16)
 * AAD (13B): epoch(2) seq(6) type(1) ver(2) plaintext_len(2)
 * Key block (40B): client_key(16) server_key(16) client_iv(4) server_iv(4)
 *
 * The Finished handshake message travels INSIDE the AEAD record: plaintext
 * = canonical handshake header (12B) + verify_data (12B) = 24B, hence the
 * 61-byte client Finished datagram seen in the capture (13+8+24+16).
 * HelloVerifyRequest and the first ClientHello are NOT part of the
 * handshake transcript; each transcript message is hashed with its full
 * canonical 12-byte DTLS header (frag fields zeroed, full lengths).
 */

/** DTLS content types. */
const RT_CHANGE_CIPHER_SPEC = 20;
const RT_ALERT = 21;
const RT_HANDSHAKE = 22;
const RT_APPLICATION_DATA = 23;

/** Handshake message types. */
const HS_CLIENT_HELLO = 1;
const HS_SERVER_HELLO = 2;
const HS_HELLO_VERIFY_REQUEST = 3;
const HS_CERTIFICATE = 11;
const HS_SERVER_KEY_EXCHANGE = 12;
const HS_CERTIFICATE_REQUEST = 13;
const HS_SERVER_HELLO_DONE = 14;
const HS_CLIENT_KEY_EXCHANGE = 16;
const HS_FINISHED = 20;

/** TLS_RSA_WITH_AES_128_GCM_SHA256 — the suite the camera picks (capture #003). */
const CIPHER_RSA_AES128_GCM = 0x009c;
const GCM_TAG_LEN = 16;
const GCM_EXPLICIT_NONCE_LEN = 8;

/** Hex string -> bytes (module-local helper for the constant below). */
function hexBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

/** ClientHello tail after the cookie (cipher list + compression + extensions),
 * verbatim from official capture #002 (2026-09-19): 16 suites ending with the
 * 0x00ff SCSV, then EMS/ALPN/supported_groups/status_request/signature_algorithms/
 * ec_point_formats. The camera demonstrably answers this exact byte sequence,
 * so our CH differs from the official one only in random + cookie. */
const OFFICIAL_CH_TAIL: Uint8Array = hexBytes(
  '0020cca9c02bc023c009cca8c02fc027c013ccaa009e00670033009c003c002f00ff' +
  '0100005f0017000000160000000a0010000e001d001e00170018010001010102' +
  '000500050100000000000d0030002e0807080804030503060308040805080608' +
  '09080a080b040105010601040205020602030303010302020302010202' +
  '000b00020100');

interface DtlsRecord {
  type: number;
  epoch: number;
  seq: number;
  payload: Uint8Array;
}

interface HsFragment {
  type: number;
  msgSeq: number;
  totalLen: number;
  fragOff: number;
  fragLen: number;
  body: Uint8Array;
}

interface HsEntry {
  msgSeq: number;
  type: number;
  totalLen: number;
  filled: number;
  done: boolean;
  body: Uint8Array;
}

interface ServerHelloParsed {
  random: Uint8Array;
  cipher: number;
}

export class DtlsClient {
  private sock: socket.UDPSocket;
  private host: string;
  private port: number;
  private closed: boolean = false;
  private handshakeDone: boolean = false;
  /** Epoch-0 outgoing record sequence; the Finished record opens epoch 1 at seq 0. */
  private outSeq: number = 0;
  private inbound: Uint8Array[] = [];
  private waiter: ((d: Uint8Array | null) => void) | null = null;
  private waiterTimer: number = -1;
  private hsEntries: HsEntry[] = [];
  private transcript: Uint8Array[] = [];
  private serverKeyObj: cryptoFramework.SymKey | null = null;
  private serverIv: Uint8Array = new Uint8Array(4);
  /** Anti-replay for epoch-1 records; the server Finished consumed seq 0. */
  private lastServerSeq: number = 0;
  private decCount: number = 0;
  private decFail: number = 0;
  private firstPlainLogged: boolean = false;
  public plainHandler: ((plain: Uint8Array) => void) | null = null;

  constructor(sock: socket.UDPSocket, host: string, port: number) {
    this.sock = sock;
    this.host = host;
    this.port = port;
  }

  /**
   * Drive the full handshake: ClientHello + cookie retry, server flight
   * (ServerHello/Certificate/CertificateRequest/ServerHelloDone), client
   * flight (empty Certificate + ClientKeyExchange + CCS + Finished), then
   * verify the server Finished. Throws on any failure or timeout (~12s).
   */
  async handshake(): Promise<void> {
    const deadline = Date.now() + 12000;
    const clientRandom = DtlsClient.randomBytes(32);
    let cookie: Uint8Array = new Uint8Array(0);
    let chMsgSeq = 0;
    let chBody = this.buildClientHello(clientRandom, cookie);
    // Mirror the official client (capture #000/#002): both ClientHellos use
    // record version fe ff; the fe fd record version starts with the client
    // flight after ServerHelloDone.
    let chRecord = await this.sendChRecord(chBody, chMsgSeq, 0xff);

    let chInTranscript = false;
    let haveSh = false;
    let haveShd = false;
    let serverRandom: Uint8Array | null = null;
    let serverCipher = 0;
    let certDer: Uint8Array | null = null;
    let chRetrans = 0;

    // Wait for HVR + the full server flight through ServerHelloDone.
    while (!haveShd) {
      if (Date.now() > deadline) {
        throw new Error('DTLS 握手超时（服务器无响应）');
      }
      const dgram = await this.waitForDatagram(haveSh ? 4000 : 1500);
      if (dgram === null) {
        chRetrans++;
        if (chRetrans > 6) {
          throw new Error('DTLS 握手超时（ClientHello 无响应）');
        }
        DtlsClient.log(`ch wait #${chRetrans} empty, resending identical ch`);
        await this.sendRaw(chRecord);
        continue;
      }
      DtlsClient.log(`rx dgram bytes=${dgram.length} head=${DtlsClient.hexHead(dgram, 48)}`);
      const records = DtlsClient.parseRecords(dgram);
      for (const rec of records) {
        if (rec.type === RT_ALERT) {
          throw new Error(`DTLS 握手失败：相机告警 ${DtlsClient.alertText(rec.payload)}`);
        }
        if (rec.type !== RT_HANDSHAKE || rec.epoch !== 0) {
          DtlsClient.log(`rx rec type=${rec.type} epoch=${rec.epoch} seq=${rec.seq} ` +
            `len=${rec.payload.length} (skipped)`);
          continue;
        }
        const frag = DtlsClient.parseHandshakeFragment(rec.payload);
        if (frag === null) {
          DtlsClient.log(`rx frag unparseable recSeq=${rec.seq} len=${rec.payload.length}`);
          continue;
        }
        if (frag.type === HS_HELLO_VERIFY_REQUEST) {
          const c = DtlsClient.parseCookie(frag.body);
          if (c === null) {
            continue;
          }
          cookie = c;
          chMsgSeq = 1;
          chBody = this.buildClientHello(clientRandom, cookie);
          DtlsClient.log(`hvr cookie=${cookie.length}B, resending client hello`);
          chRecord = await this.sendChRecord(chBody, chMsgSeq, 0xff);
          continue;
        }
        const done = this.feedFragment(frag);
        if (done === null) {
          continue;
        }
        DtlsClient.log(`rx hs type=${done.type} msgSeq=${done.msgSeq} len=${done.body.length}`);
        if (done.type === HS_SERVER_HELLO) {
          if (!chInTranscript) {
            this.transcriptAdd(HS_CLIENT_HELLO, chMsgSeq, chBody);
            chInTranscript = true;
          }
          const sh = DtlsClient.parseServerHello(done.body);
          serverRandom = sh.random;
          serverCipher = sh.cipher;
          this.transcriptAdd(HS_SERVER_HELLO, done.msgSeq, done.body);
          haveSh = true;
        } else if (done.type === HS_CERTIFICATE) {
          certDer = DtlsClient.parseFirstCert(done.body);
          this.transcriptAdd(HS_CERTIFICATE, done.msgSeq, done.body);
        } else if (done.type === HS_CERTIFICATE_REQUEST) {
          this.transcriptAdd(HS_CERTIFICATE_REQUEST, done.msgSeq, done.body);
        } else if (done.type === HS_SERVER_KEY_EXCHANGE) {
          throw new Error('DTLS 握手失败：意外的 ServerKeyExchange');
        } else if (done.type === HS_SERVER_HELLO_DONE) {
          this.transcriptAdd(HS_SERVER_HELLO_DONE, done.msgSeq, done.body);
          haveShd = true;
        }
      }
    }
    if (!haveSh || serverRandom === null) {
      throw new Error('DTLS 握手失败：缺少 ServerHello');
    }
    if (serverCipher !== CIPHER_RSA_AES128_GCM) {
      throw new Error(`DTLS 握手失败：未知套件 0x${serverCipher.toString(16)}`);
    }
    if (certDer === null) {
      throw new Error('DTLS 握手失败：缺少服务器证书');
    }

    // Client flight. The empty certificate is exactly the official client's
    // 3-byte 000000 body (capture #009); the camera accepted it.
    const emptyCertBody = new Uint8Array(3);
    const premaster = new Uint8Array(48);
    premaster[0] = 0xfe;
    premaster[1] = 0xfd;
    premaster.set(DtlsClient.randomBytes(46), 2);
    const spki = DtlsClient.extractSpki(certDer);
    DtlsClient.log(`cert der=${certDer.length}B spki=${spki.length}B`);
    const encrypted = await DtlsClient.rsaEncrypt(spki, premaster);
    const ckeBody = new Uint8Array(2 + encrypted.length);
    ckeBody[0] = (encrypted.length >>> 8) & 0xff;
    ckeBody[1] = encrypted.length & 0xff;
    ckeBody.set(encrypted, 2);

    const master = DtlsClient.prf(premaster, 'master secret', [clientRandom, serverRandom], 48);
    const keyBlock = DtlsClient.prf(master, 'key expansion', [serverRandom, clientRandom], 40);
    const clientKey = keyBlock.slice(0, 16);
    const serverKey = keyBlock.slice(16, 32);
    this.serverIv = keyBlock.slice(36, 40);
    this.serverKeyObj = cryptoFramework.createSymKeyGenerator('AES128')
      .convertKeySync(DtlsClient.blob(serverKey));

    this.transcriptAdd(HS_CERTIFICATE, 2, emptyCertBody);
    this.transcriptAdd(HS_CLIENT_KEY_EXCHANGE, 3, ckeBody);

    const flight: ArrayBuffer[] = [];
    flight.push(this.buildRecord(RT_HANDSHAKE, 0, this.nextOutSeq(),
      DtlsClient.wrapHandshake(HS_CERTIFICATE, 2, emptyCertBody), 0xfd));
    flight.push(this.buildRecord(RT_HANDSHAKE, 0, this.nextOutSeq(),
      DtlsClient.wrapHandshake(HS_CLIENT_KEY_EXCHANGE, 3, ckeBody), 0xfd));
    flight.push(this.buildRecord(RT_CHANGE_CIPHER_SPEC, 0, this.nextOutSeq(),
      new Uint8Array([1]), 0xfd));

    const clientVerify = DtlsClient.prf(master, 'client finished', [this.transcriptHash()], 12);
    const finPlain = DtlsClient.wrapHandshake(HS_FINISHED, 4, clientVerify);
    const finPayload = this.aeadEncrypt(clientKey, keyBlock.slice(32, 36), 1, 0, RT_HANDSHAKE, finPlain);
    flight.push(this.buildRecord(RT_HANDSHAKE, 1, 0, finPayload, 0xfd));
    this.transcriptAdd(HS_FINISHED, 4, clientVerify);
    await this.sendFlight(flight);
    DtlsClient.log(`tx client flight records=${flight.length} (cert/cke/ccs/finished)`);

    // Wait for the server CCS + encrypted Finished, then verify it.
    let verified = false;
    while (!verified) {
      if (Date.now() > deadline) {
        throw new Error('DTLS 握手超时（服务器 Finished 缺失）');
      }
      const dgram = await this.waitForDatagram(5000);
      if (dgram === null) {
        DtlsClient.log('finished wait empty, resending client flight');
        await this.sendFlight(flight);
        continue;
      }
      DtlsClient.log(`rx dgram bytes=${dgram.length} head=${DtlsClient.hexHead(dgram, 48)}`);
      const records = DtlsClient.parseRecords(dgram);
      for (const rec of records) {
        if (rec.type === RT_ALERT) {
          throw new Error(`DTLS 握手失败：相机告警 ${DtlsClient.alertText(rec.payload)}`);
        }
        if (rec.type !== RT_HANDSHAKE || rec.epoch !== 1) {
          continue; // CCS (type 20) and stragglers are skipped
        }
        const plain = this.aeadDecrypt(rec);
        if (plain.length !== 24 || plain[0] !== HS_FINISHED) {
          throw new Error('DTLS 握手失败：服务器 Finished 格式错误');
        }
        const expected = DtlsClient.prf(master, 'server finished', [this.transcriptHash()], 12);
        let ok = true;
        for (let i = 0; i < 12; i++) {
          if (plain[12 + i] !== expected[i]) {
            ok = false;
            break;
          }
        }
        if (!ok) {
          throw new Error('DTLS 握手失败：Finished 校验不匹配');
        }
        verified = true;
        break;
      }
    }

    this.handshakeDone = true;
    this.lastServerSeq = 0;
    DtlsClient.log(`handshake ok ${this.host}:${this.port} (server finished verified)`);
  }

  /**
   * Post-handshake entry point for every datagram the bound socket receives.
   * Epoch-1 application-data records are decrypted and handed to
   * plainHandler; anything else is ignored.
   */
  feedDatagram(dgram: ArrayBuffer): void {
    if (this.closed) {
      return;
    }
    const d = new Uint8Array(dgram);
    if (!this.handshakeDone) {
      this.inbound.push(d);
      const w = this.waiter;
      if (w !== null) {
        this.waiter = null;
        if (this.waiterTimer >= 0) {
          clearTimeout(this.waiterTimer);
          this.waiterTimer = -1;
        }
        const first: Uint8Array | undefined = this.inbound.shift();
        w(first === undefined ? null : first);
      }
      return;
    }
    const records = DtlsClient.parseRecords(d);
    for (const rec of records) {
      if (rec.type !== RT_APPLICATION_DATA || rec.epoch !== 1) {
        continue;
      }
      if (rec.seq <= this.lastServerSeq) {
        continue;
      }
      this.lastServerSeq = rec.seq;
      try {
        const plain = this.aeadDecrypt(rec);
        this.decCount++;
        if (!this.firstPlainLogged) {
          this.firstPlainLogged = true;
          DtlsClient.log(`first plain len=${plain.length} head=${DtlsClient.hexHead(plain, 32)}`);
        }
        if (this.plainHandler !== null && plain.length > 0) {
          this.plainHandler(plain);
        }
      } catch (error) {
        this.decFail++;
        if (this.decFail <= 3 || this.decFail % 100 === 0) {
          DtlsClient.log(`decrypt fail #${this.decFail} len=${rec.payload.length} code=` +
            `${error instanceof Error ? error.message : 'unknown'}`);
        }
      }
    }
  }

  /** Tear down; pending waits resolve with null. */
  close(): void {
    this.closed = true;
    const w = this.waiter;
    this.waiter = null;
    if (this.waiterTimer >= 0) {
      clearTimeout(this.waiterTimer);
      this.waiterTimer = -1;
    }
    if (w !== null) {
      w(null);
    }
    this.inbound = [];
  }

  /** Send one ClientHello record; returns the exact wire bytes so that
   * retransmissions are identical (same record seq, RFC 6347 §4.2.7). */
  private async sendChRecord(body: Uint8Array, msgSeq: number,
    verMinor: number): Promise<ArrayBuffer> {
    const rec = this.buildRecord(RT_HANDSHAKE, 0, this.nextOutSeq(),
      DtlsClient.wrapHandshake(HS_CLIENT_HELLO, msgSeq, body), verMinor);
    await this.sendRaw(rec);
    DtlsClient.log(`tx ch msgSeq=${msgSeq} recSeq=${this.outSeq - 1} bytes=${rec.byteLength}` +
      ` head=${DtlsClient.hexHead(new Uint8Array(rec), 32)}`);
    return rec;
  }

  private async sendFlight(flight: ArrayBuffer[]): Promise<void> {
    for (const ab of flight) {
      await this.sendRaw(ab);
    }
  }

  private async sendRaw(data: ArrayBuffer): Promise<void> {
    if (this.closed) {
      throw new Error('DTLS 握手失败：socket 已关闭');
    }
    await this.sock.send({ address: { address: this.host, port: this.port }, data: data });
  }

  private nextOutSeq(): number {
    const s = this.outSeq;
    this.outSeq++;
    return s;
  }

  private waitForDatagram(timeoutMs: number): Promise<Uint8Array | null> {
    return new Promise<Uint8Array | null>((resolve: (d: Uint8Array | null) => void) => {
      if (this.inbound.length > 0) {
        const first: Uint8Array | undefined = this.inbound.shift();
        resolve(first === undefined ? null : first);
        return;
      }
      this.waiter = resolve;
      this.waiterTimer = setTimeout(() => {
        this.waiter = null;
        this.waiterTimer = -1;
        resolve(null);
      }, timeoutMs);
    });
  }

  /** Reassemble a handshake fragment; returns the entry once fully received. */
  private feedFragment(frag: HsFragment): HsEntry | null {
    for (const e of this.hsEntries) {
      if (e.msgSeq !== frag.msgSeq) {
        continue;
      }
      if (e.done) {
        return null;
      }
      if (frag.fragOff + frag.fragLen > e.totalLen) {
        return null;
      }
      e.body.set(frag.body, frag.fragOff);
      e.filled += frag.fragLen;
      if (e.filled >= e.totalLen) {
        e.done = true;
        return e;
      }
      return null;
    }
    // totalLen 0 is valid: ServerHelloDone is an empty handshake message
    // (2026-09-19 live test: the `<= 0` guard silently dropped it and the
    // whole handshake timed out although the camera kept retransmitting).
    if (frag.totalLen < 0 || frag.totalLen > 65536 ||
      frag.fragOff + frag.fragLen > frag.totalLen) {
      return null;
    }
    const e: HsEntry = {
      msgSeq: frag.msgSeq,
      type: frag.type,
      totalLen: frag.totalLen,
      filled: 0,
      done: false,
      body: new Uint8Array(frag.totalLen)
    };
    e.body.set(frag.body, frag.fragOff);
    e.filled += frag.fragLen;
    this.hsEntries.push(e);
    if (e.filled >= e.totalLen) {
      e.done = true;
      return e;
    }
    return null;
  }

  private transcriptAdd(type: number, msgSeq: number, body: Uint8Array): void {
    this.transcript.push(DtlsClient.wrapHandshake(type, msgSeq, body));
  }

  private transcriptHash(): Uint8Array {
    const md = cryptoFramework.createMd('SHA256');
    for (const m of this.transcript) {
      md.updateSync(DtlsClient.blob(m));
    }
    const out = md.digestSync();
    return out.data;
  }

  /** AEAD-protect one record payload: explicit nonce + ciphertext + tag. */
  private aeadEncrypt(key: Uint8Array, ivSalt: Uint8Array, epoch: number, seq: number,
    type: number, plain: Uint8Array): Uint8Array {
    const explicit = new Uint8Array(GCM_EXPLICIT_NONCE_LEN);
    explicit[0] = (epoch >> 8) & 0xff;
    explicit[1] = epoch & 0xff;
    DtlsClient.writeSeq48(explicit, 2, seq);
    const nonce = DtlsClient.concat2(ivSalt, explicit);
    const aad = DtlsClient.buildAad(epoch, seq, type, plain.length);
    const keyObj = cryptoFramework.createSymKeyGenerator('AES128')
      .convertKeySync(DtlsClient.blob(key));
    const cipher = cryptoFramework.createCipher('AES128|GCM');
    const params: cryptoFramework.GcmParamsSpec = {
      iv: DtlsClient.blob(nonce),
      aad: DtlsClient.blob(aad),
      authTag: DtlsClient.blob(new Uint8Array(GCM_TAG_LEN)),
      algName: 'GcmParamsSpec'
    };
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyObj, params);
    const ctBlob = cipher.updateSync(DtlsClient.blob(plain));
    const ct = ctBlob === null ? new Uint8Array(0) : ctBlob.data;
    const tagBlob = cipher.doFinalSync(null);
    const tag = tagBlob === null ? new Uint8Array(GCM_TAG_LEN) : tagBlob.data;
    return DtlsClient.concat3(explicit, ct, tag);
  }

  /** Decrypt one epoch-1 record; throws when the GCM tag check fails. */
  private aeadDecrypt(rec: DtlsRecord): Uint8Array {
    const p = rec.payload;
    if (p.length < GCM_EXPLICIT_NONCE_LEN + GCM_TAG_LEN) {
      throw new Error('record too short');
    }
    const explicit = p.subarray(0, GCM_EXPLICIT_NONCE_LEN);
    const ct = p.slice(GCM_EXPLICIT_NONCE_LEN, p.length - GCM_TAG_LEN);
    const tag = p.slice(p.length - GCM_TAG_LEN);
    const nonce = DtlsClient.concat2(this.serverIv, explicit);
    const aad = DtlsClient.buildAad(rec.epoch, rec.seq, rec.type, ct.length);
    if (this.serverKeyObj === null) {
      throw new Error('keys not ready');
    }
    const cipher = cryptoFramework.createCipher('AES128|GCM');
    const params: cryptoFramework.GcmParamsSpec = {
      iv: DtlsClient.blob(nonce),
      aad: DtlsClient.blob(aad),
      authTag: DtlsClient.blob(tag),
      algName: 'GcmParamsSpec'
    };
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, this.serverKeyObj, params);
    const out = cipher.updateSync(DtlsClient.blob(ct));
    cipher.doFinalSync(null);
    return out === null ? new Uint8Array(0) : out.data;
  }

  private buildClientHello(random: Uint8Array, cookie: Uint8Array): Uint8Array {
    // ver(2) random(32) session_id(1) cookie(1+n) + official cipher/ext tail
    const b = new Uint8Array(2 + 32 + 1 + 1 + cookie.length + OFFICIAL_CH_TAIL.length);
    let o = 0;
    b[o++] = 0xfe;
    b[o++] = 0xfd;
    b.set(random, o);
    o += 32;
    b[o++] = 0;
    b[o++] = cookie.length;
    b.set(cookie, o);
    o += cookie.length;
    b.set(OFFICIAL_CH_TAIL, o);
    return b;
  }

  private buildRecord(type: number, epoch: number, seq: number, payload: Uint8Array,
    verMinor: number): ArrayBuffer {
    const ab = new ArrayBuffer(13 + payload.length);
    const v = new Uint8Array(ab);
    v[0] = type;
    v[1] = 0xfe;
    v[2] = verMinor;
    v[3] = (epoch >> 8) & 0xff;
    v[4] = epoch & 0xff;
    DtlsClient.writeSeq48(v, 5, seq);
    v[11] = (payload.length >> 8) & 0xff;
    v[12] = payload.length & 0xff;
    v.set(payload, 13);
    return ab;
  }

  private static parseRecords(d: Uint8Array): DtlsRecord[] {
    const out: DtlsRecord[] = [];
    let off = 0;
    while (off + 13 <= d.length) {
      const type = d[off];
      if (d[off + 1] !== 0xfe || (d[off + 2] !== 0xfd && d[off + 2] !== 0xff)) {
        break;
      }
      const epoch = (d[off + 3] << 8) | d[off + 4];
      const seq = DtlsClient.readSeq48(d, off + 5);
      const len = (d[off + 11] << 8) | d[off + 12];
      if (off + 13 + len > d.length) {
        break;
      }
      const rec: DtlsRecord = {
        type: type,
        epoch: epoch,
        seq: seq,
        payload: d.subarray(off + 13, off + 13 + len)
      };
      out.push(rec);
      off += 13 + len;
    }
    return out;
  }

  private static parseHandshakeFragment(payload: Uint8Array): HsFragment | null {
    if (payload.length < 12) {
      return null;
    }
    const fragLen = DtlsClient.u24(payload, 9);
    if (12 + fragLen > payload.length) {
      return null;
    }
    const frag: HsFragment = {
      type: payload[0],
      msgSeq: (payload[4] << 8) | payload[5],
      totalLen: DtlsClient.u24(payload, 1),
      fragOff: DtlsClient.u24(payload, 6),
      fragLen: fragLen,
      body: payload.subarray(12, 12 + fragLen)
    };
    return frag;
  }

  private static parseCookie(hvrBody: Uint8Array): Uint8Array | null {
    if (hvrBody.length < 3) {
      return null;
    }
    const len = hvrBody[2];
    if (3 + len > hvrBody.length) {
      return null;
    }
    return hvrBody.slice(3, 3 + len);
  }

  private static parseServerHello(body: Uint8Array): ServerHelloParsed {
    if (body.length < 36) {
      throw new Error('ServerHello too short');
    }
    const sidLen = body[34];
    let off = 35 + sidLen;
    if (off + 3 > body.length) {
      throw new Error('ServerHello truncated');
    }
    const parsed: ServerHelloParsed = {
      random: body.slice(2, 34),
      cipher: (body[off] << 8) | body[off + 1]
    };
    return parsed;
  }

  private static parseFirstCert(body: Uint8Array): Uint8Array {
    if (body.length < 6) {
      throw new Error('Certificate message too short');
    }
    const certLen = DtlsClient.u24(body, 3);
    if (6 + certLen > body.length) {
      throw new Error('Certificate message truncated');
    }
    return body.slice(6, 6 + certLen);
  }

  /**
   * Manual DER walk of the X.509 certificate to slice out the full
   * SubjectPublicKeyInfo TLV (what cryptoFramework convertKey expects):
   * Certificate -> tbsCertificate -> skip [0]version, serial, sigalg,
   * issuer, validity, subject -> SPKI.
   */
  private static extractSpki(cert: Uint8Array): Uint8Array {
    let t = DtlsClient.readDerTlv(cert, 0);
    if (t === null || t[0] !== 0x30) {
      throw new Error('证书 DER 解析失败（外层）');
    }
    let off = t[1];
    t = DtlsClient.readDerTlv(cert, off);
    if (t === null || t[0] !== 0x30) {
      throw new Error('证书 DER 解析失败（tbs）');
    }
    off += t[1];
    t = DtlsClient.readDerTlv(cert, off);
    if (t !== null && t[0] === 0xa0) {
      off += t[1] + t[2];
    }
    for (let i = 0; i < 5; i++) {
      t = DtlsClient.readDerTlv(cert, off);
      if (t === null) {
        throw new Error('证书 DER 解析失败（字段）');
      }
      off += t[1] + t[2];
    }
    t = DtlsClient.readDerTlv(cert, off);
    if (t === null || t[0] !== 0x30) {
      throw new Error('证书 DER 解析失败（SPKI）');
    }
    return cert.slice(off, off + t[1] + t[2]);
  }

  /** [tag, headerLen, contentLen] of the DER TLV at `off`, or null. */
  private static readDerTlv(d: Uint8Array, off: number): number[] | null {
    if (off + 2 > d.length) {
      return null;
    }
    const tag = d[off];
    let idx = off + 1;
    let len = d[idx];
    idx++;
    if ((len & 0x80) !== 0) {
      const n = len & 0x7f;
      if (n === 0 || n > 3 || idx + n > d.length) {
        return null;
      }
      len = 0;
      for (let i = 0; i < n; i++) {
        len = (len << 8) | d[idx];
        idx++;
      }
    }
    if (idx + len > d.length) {
      return null;
    }
    return [tag, idx - off, len];
  }

  /** RSA-PKCS1v1.5 encrypt the 48-byte premaster with the camera public key. */
  private static async rsaEncrypt(spki: Uint8Array, premaster: Uint8Array): Promise<Uint8Array> {
    const specs: string[] = ['RSA2048', 'RSA1024'];
    for (const spec of specs) {
      try {
        const gen = cryptoFramework.createAsyKeyGenerator(spec);
        const pair = await gen.convertKey(DtlsClient.blob(spki), null);
        const cipher = cryptoFramework.createCipher(`${spec}|PKCS1`);
        await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, pair.pubKey, null);
        const out = await cipher.doFinal(DtlsClient.blob(premaster));
        return out.data;
      } catch (_error) {
        DtlsClient.log(`rsa ${spec} failed, trying fallback`);
      }
    }
    throw new Error('DTLS 握手失败：RSA 加密预主密钥失败');
  }

  /** TLS 1.2 PRF (P_hash with SHA-256). */
  private static prf(secret: Uint8Array, label: string, seedParts: Uint8Array[],
    outLen: number): Uint8Array {
    const seed = DtlsClient.concat2(DtlsClient.ascii(label), DtlsClient.concatAll(seedParts));
    const out = new Uint8Array(outLen);
    let filled = 0;
    let a = DtlsClient.hmacSha256(secret, [seed]);
    while (filled < outLen) {
      const block = DtlsClient.hmacSha256(secret, [a, seed]);
      const n = Math.min(block.length, outLen - filled);
      out.set(block.subarray(0, n), filled);
      filled += n;
      a = DtlsClient.hmacSha256(secret, [a]);
    }
    return out;
  }

  private static hmacSha256(key: Uint8Array, parts: Uint8Array[]): Uint8Array {
    const gen = cryptoFramework.createSymKeyGenerator('HMAC');
    const symKey = gen.convertKeySync(DtlsClient.blob(key));
    const mac = cryptoFramework.createMac('SHA256');
    mac.initSync(symKey);
    for (const p of parts) {
      mac.updateSync(DtlsClient.blob(p));
    }
    return mac.doFinalSync().data;
  }

  /** Canonical DTLS handshake header (frag fields zeroed) + body. */
  private static wrapHandshake(type: number, msgSeq: number, body: Uint8Array): Uint8Array {
    const h = new Uint8Array(12 + body.length);
    h[0] = type;
    h[1] = (body.length >>> 16) & 0xff;
    h[2] = (body.length >>> 8) & 0xff;
    h[3] = body.length & 0xff;
    h[4] = (msgSeq >>> 8) & 0xff;
    h[5] = msgSeq & 0xff;
    h[9] = (body.length >>> 16) & 0xff;
    h[10] = (body.length >>> 8) & 0xff;
    h[11] = body.length & 0xff;
    h.set(body, 12);
    return h;
  }

  private static buildAad(epoch: number, seq: number, type: number, plainLen: number): Uint8Array {
    const a = new Uint8Array(13);
    a[0] = (epoch >> 8) & 0xff;
    a[1] = epoch & 0xff;
    DtlsClient.writeSeq48(a, 2, seq);
    a[8] = type;
    a[9] = 0xfe;
    a[10] = 0xfd;
    a[11] = (plainLen >> 8) & 0xff;
    a[12] = plainLen & 0xff;
    return a;
  }

  private static writeSeq48(t: Uint8Array, off: number, seq: number): void {
    const hi = Math.floor(seq / 0x100000000);
    const lo = seq - hi * 0x100000000;
    t[off] = (hi >>> 8) & 0xff;
    t[off + 1] = hi & 0xff;
    t[off + 2] = (lo >>> 24) & 0xff;
    t[off + 3] = (lo >>> 16) & 0xff;
    t[off + 4] = (lo >>> 8) & 0xff;
    t[off + 5] = lo & 0xff;
  }

  private static readSeq48(d: Uint8Array, off: number): number {
    const hi = ((d[off] << 8) | d[off + 1]) >>> 0;
    const lo = ((d[off + 2] << 24) | (d[off + 3] << 16) | (d[off + 4] << 8) | d[off + 5]) >>> 0;
    return hi * 0x100000000 + lo;
  }

  private static u24(d: Uint8Array, off: number): number {
    return ((d[off] << 16) | (d[off + 1] << 8) | d[off + 2]) >>> 0;
  }

  private static randomBytes(n: number): Uint8Array {
    return cryptoFramework.createRandom().generateRandomSync(n).data;
  }

  /** DataBlob always backed by an offset-0 array (views are copied). */
  private static blob(d: Uint8Array): cryptoFramework.DataBlob {
    if (d.byteOffset === 0 && d.byteLength === d.buffer.byteLength) {
      return { data: d };
    }
    return { data: d.slice() };
  }

  private static concat2(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  private static concat3(a: Uint8Array, b: Uint8Array, c: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length + c.length);
    out.set(a, 0);
    out.set(b, a.length);
    out.set(c, a.length + b.length);
    return out;
  }

  private static concatAll(parts: Uint8Array[]): Uint8Array {
    let total = 0;
    for (const p of parts) {
      total += p.length;
    }
    const out = new Uint8Array(total);
    let off = 0;
    for (const p of parts) {
      out.set(p, off);
      off += p.length;
    }
    return out;
  }

  private static ascii(s: string): Uint8Array {
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      out[i] = s.charCodeAt(i) & 0xff;
    }
    return out;
  }

  private static alertText(payload: Uint8Array): string {
    if (payload.length < 2) {
      return 'empty';
    }
    return `level=${payload[0]} desc=${payload[1]}`;
  }

  private static hexHead(bytes: Uint8Array, max: number): string {
    const n = Math.min(bytes.length, max);
    let s = '';
    for (let i = 0; i < n; i++) {
      const h = bytes[i].toString(16);
      s += h.length < 2 ? `0${h}` : h;
    }
    return s;
  }

  private static log(message: string): void {
    try {
      hilog.info(0x0001, 'VIVID_CTRL', '%{public}s', `dtls ${message}`);
      AppLogSink.emit('CTL', 'dtls ' + message);
    } catch (_error) {
    }
  }
}
