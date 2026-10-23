/**
 * Nikon LSS authentication handshake — phone side (native "role B").
 *
 * Provenance
 * ----------
 * Everything here was reconstructed from the official SnapBridge 2.13.3
 * (com.nikon.snapbridge.cmru) pair: the native library `libLsSec-jni.so`
 * (arm64-v8a, 38640 bytes, sha256
 * 762477cad14f55495d5e4f9caec1ae2b81f2852432f5ab7cc88e963e8fd99853) for the
 * crypto, and `classes.dex` for the call sites that bind the crypto to the
 * BLE frames.
 *
 * Why this file exists at all: HarmonyOS `@ohos.security.cryptoFramework` has
 * no Blowfish, so the cipher is hand-written (see `NikonLssCrypto.ets`).
 *
 * Protocol (role B = this phone)
 * ------------------------------
 *   init(seed)                      -> state 1
 *   stage1()                        -> N_B, state 3
 *   stage3(N_A, X, MAC1)            -> MAC2, state 5
 *   generateKey(key1, key2)         -> session cipher, state 6
 *
 * where, per `LsSec3rdStage` (libLsSec-jni.so 0x6a6c):
 *   MAC1 = MAC(tbl[idx] || N_A || X)        (the camera computed this)
 *   MAC2 = MAC(tbl[idx] || X   || N_A)      (note the swap)
 *
 * `X` is the phone's own stage-1 nonce. That is not a guess: the Java call
 * site is `secret.stage3(resp.getNonce(), this.e, resp.getDeviceId())` and the
 * native contract is `Stage3rd(a1 = N_A, a2 = X, a3 = MAC1)`, with `this.e`
 * being the byte[8] the phone cached from `secret.stage1()`. Two independent
 * artifacts therefore agree, and it also explains why
 * `BleAuthenticationData` step 1 caches the nonce at all.
 *
 * The session key is `K = MAC(key1 || key2 || key3)` with
 * `key3 = ctx[0..7] = idx || N_A[1..3] || X[0..3]`, and K is then fed to a
 * *standard* Blowfish key schedule to produce the session cipher. Credential
 * fields are decrypted with that cipher in CBC mode.
 *
 * Two things are deliberately not guessed here
 * --------------------------------------------
 * 1. `key1` and `key2` are inputs. The Java layer passes
 *    `generateKey(stage4Frame.deviceId, cameraDeviceId)`, so this module takes
 *    them verbatim rather than assuming the camera sends `tbl[idx]`.
 *    `describeKey1` reports whether the value the camera actually sent equals
 *    `tbl[idx]`, which turns an open question into one line of device log.
 * 2. The CBC IV of the session cipher. Nothing in the library ever writes
 *    `ctx+16` and `LsSecInit` zeroes the context, so the IV is all zero unless
 *    a caller injects one; that is the behaviour implemented here.
 *
 * @since 2026-11
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { NikonBlowfish } from './NikonLssCrypto';

/**
 * The fixed-key MAC's Blowfish schedule, copied byte for byte from
 * `.rodata 0x2e28` (1042 entries, 8336 bytes, 8 bytes per entry: a little-
 * endian u32 followed by four zero bytes).
 *
 * The 8-byte key behind this schedule is *not* recoverable from the library —
 * every 4..56 byte window of `.rodata` was tried, in both byte orders, plus all
 * printable strings, and none of them rebuilds the first 18 P values. The
 * schedule is therefore carried verbatim and is never re-derived. This table
 * shares 0 of its 1042 entries with the standard Blowfish table.
 */
const MAC_SCHEDULE_HEX: string =
  'e813ec15ae5b6cea6ca89e354cf052074806ad72d5fdb061c7fd55e446b160be82ab18886f1c061fb9ed53020539193993d86ffc9c8b78fec51ff2358cee7883' +
  '96ea497e7c3f81ca349a316485caba9f0925c3ec4dfc20db66bcf8c7c49cfff223f8a60a1836ed575319d2d86a3e2b3cb1750ea35e90f08b79af21494db554ba' +
  '2f6933640f3e79dbfbdbda728c5e10239b8a1d2aa08d493b60ecc3783edb5e91e63ad3924763c490699d4f353a4c6b8ceceedf98921874a22c3b75f0c8a94dd8' +
  '9aeacd324cd1473fff5dd0171355ccfba4df6facd6946e6693deb1f75ba1a1e6af8d3210f58339af19c9137b45ab1745027be2c30febd204ef573e0282fba559' +
  '966d9750c75f6e485d117a620da8401e555e573efcd4cebd6eee97522e4165898f4e5731226ef4a5f113df59182dc6026cac73903cd7186c0a9c5c361262446e' +
  'f73e2142a6cde914ff8835f0de28b148f4d97681c47b135b6c94445e74699309f51809025c3dcf476826ed4698f618a25882d78a6b9ea708a5fb9553c7848225' +
  '634fad1b573d14bf9caecdb5c63d0af59e9ac886a9605a3ab2b96d6f84b6d2ea25d1e734bf097443a633db5ee75e356f184cdaef2880982af8f54f27aaeeb8d9' +
  'b7571672431d70bccdf825f1ab4d334c1f10736933fe0685cc51aa544af76e6ffaa6984bc39e8ea35823e67a63ee630010ac0464e384d9ee3d27d4fd7441b6e6' +
  '29c815b555732b191103c32d82821cbefaa06a0aa6cfad30f97ac0b01197da411ac332a5d7777520b78c649ba5f76b4ede7e8f98f410fbb008bf0f01ec880d6f' +
  '8ac457d65911d66cec091705b43a07e7db463b427d79d6f17753fb09358d77fa430e476741e322931505050a13b599a9d12ff07d4de5e72a1b6babeec3e58fb5' +
  '8cd9ffce3a031286c9ed35c361d54c65ec5384778a0b44fd85c12cde9c1649d934226dee074c363dda45157cd90bd7c03ef8ff7ae4769568a7e357745d62f204' +
  '3ea9cbbc84b88fa63b0e045775dbc341e91406b185b76900f447fe6a1d12abb2c73de10571b4bc02ba37bd268d3b3c003328905bb39bdfbbdebfe7a95ca2db5f' +
  '7713b03ca1d96145b013f0a8e026dcf598bb36a3afc61518881b1096f2eeeead2be4cc7d9122d5016612270d04febe6e8ed69d680250b014aca682bb45acdc97' +
  'd82ceafc48e1f4abad6ce58005e906d89e1a160a06608f9d7f35342cc0eb0eb503c3a792ba2e19dbeaa3d476aa9e8bf779c3a3cffd51d0bcb2fe6a84371703a2' +
  '7d098d097e5b556a0d1f18c044d6c102d451f8ad593ba6acf9f0f6910978079371db07d800eb65ea1445fc15c9d8a60196050cf1a4f5b71cdcd4ee038e61bb7c' +
  '851e700a21e918e313e21f517719484d0fa4db14db70ebcd54b14c0c1f0c3a3eaf90b08374ff445da7d0a611687f8285c403dc1c98b8fc119d13dfe2f27cdd7c' +
  '8334cf1dc38d739856d87a936ee70d0d650fac36d4529eb0ca81379e04155f31806e4dabfbec758961160a644a1e0feceed499503e14b39e7974438af265621a' +
  'd0736e87980dc594ef0172feacf1c9ed7825b08e94ffa2f2c9289426d5644fe728a399d9b62e783fe302f037f373f9f47b36b756bc2cf0533aa190dbc86ef2ad' +
  'c58f48bf94c3737bdbb4581e0325063e528ae3bc9f3e8e4140a352f0bb7b4cde51b55266854279f5aef100a4165bc082950f255d03d5b31a2387de205a8c182f' +
  '34a6c85491c44dc0a2d4834d0348376eb01ea24e21c23c8ff2a4e82f04a2fabf8431b727ec4d9b29a61beda83df739761d3ed9354ad9964862f30dc05eb2b7fc' +
  'aad2133b89320ea2a16ff8d7f03d940344d376e76c5eeb262f8b0fdac4d9cd3b0f598252e9d0e431b9487338c3575a000444c21ea8684a8eb7d32ffdd82e0476' +
  '9e53d126686c68c35aee3695297ac2630c7d859373d0bba0f45f6fd0d04bfe255a202ce303c0ced57e9932b855ff6d39f8f659e993c8bca396a2eba8e6c1e9aa' +
  '62ff40cb646f808e949404c2a56664c9b54f8cdb8cd633eeb5f1e7a93c9868fe85ecd3e61d9c7a5e28d76cfd43dc2eccca7c030a77015619a80e8c4a32223d76' +
  '9a0b6e9ff6c861424f08a7829160f5355c181fc10ff08632d6f1e6933e91bcd0a8c192cdeb8bd2942e2c34dfad9270bce7c11f136b1b97b2ddf0916ec52ee357' +
  '9424b93b3f1b9c4e8a86281ecffb5111992e4be35fde8e86429164c85b91457d2d117b864b206df92bca39c4f3c368ddfc503cda17a43178477570f629469b54' +
  '755d0c3c257d4be73e9726a7c5d375534bbef76a73b093cd6c42388cb9b93f9a2b509077157b5407316d8887c8a333f02640883088406018178c25d15e2e6485' +
  '17ae0c1a1d3056a68a40a6ebaedf615e76c61f0761afff4bc8b19f84a8dd031d32ed1e04650e7a543f355046416154c14b42f5074f99e50197944470cfff06ca' +
  '2de248df36ea2f5400b1315c5db6e50be57a5e8258e79671b096bb7ed94686479e8a408bfa2a736dab5404c9c0c96e1482655a1e822d97c5dd9c9e7f34cadcf6' +
  'c0efac61a2f3837c36c5bcf9e1934dd1b2bf8a31761738aee31d1df27aa84c10ae5e7f5e00a360a5c2a9d7571ac28895b963f75088b58ed5d3c6d19e606cc514' +
  'd579a905aa28315b3a93f01a4d29f540c8f59a8de71957ea2d9f3769b6f415b599c8882d504b0e362bf12f0bf90c2648061a385d1195dd2362b002072bcbf4f3' +
  '708875239f9e51b19a212242928ef16a9be547cd716752f8d70d7e998d4f14cd448a4aed5baee03cea8b8de65cc62978f84c10ad78e7d28fe2d6eb3abc05a25e' +
  '7699fd62468a77a8faee0313388c25728728deecc2f7d1312f66bfbec34ea214ee452308e9144da52e1eb77f478b94dca52508041063cfab4a8f7f125e354b01' +
  '883d4b4b0b558639f5513b3600c14278b46de83a5859d16d249e95aa959c2676bf54a4acaf3b032b53c029139be1f5e616ca7628ce5290bbe1285aa472b8751a' +
  'fc1ac1ce761ba2e8ef84551f27979ace80ec9a85c6ba721127f67513a647e047d6324ad290a8fd9c9020980e3b622ae91894c4c28744f86b9e81668f12a0c3fe' +
  'b06ce63b0a9ad70ef03726da7c6977042bec9a6af23e3e81ca9e6d202ab584a295f8906fea569f3be4b3eca634f4f59753cc8e9761d5986ce820e35590bdeef4' +
  '95346c718ed352c3a50517f8841d4dc193c4893d60e56a4f0dbe1448c0c9bd0c5f70a73e816d2706c1712cc12129a7f2473887f3b049471a34e7e6997568d07f' +
  'a274b68243788aa5ceb15929d98a06a5d252426e82338f82aec1cbd9a17af2147c3dff3d0080862cd688ffaec1fa8a40146fb554ad0bbeebaef8e4f42b5d0e80' +
  'f7f62436b11c30bf395c8fa965bcfd61cb1150df3341033418b6880c23f545ae825af6c4620851288f9b06922d0589a546ddca1b9b9a2b26a2b164c93fe57a47' +
  'a5859c3bfd1a35875d12c6c61fd6df72c01baa5348b384891af0d528653978ce66e651ad93e1431d4ac7e3dc3672f4ed1b6b47b052981a7bf9b23939a3d35a4b' +
  '4b051ca8d55f4988c90d551b55052644aa0e58926e9466a2c52719355485d1bf32cc1bd0f8b27ae154d58c980f0d4464d79561e4471d8c65a4b7d9c37e02fbb1' +
  'a4f62cf1b319378b529ac147cdb9ec8cbb7c1977a965d1845962299e8a424d4df5e414b2a7eedad0272a7a2ef5f79cf27398ed008eea759b716f0d6a2fa790c6' +
  '8d37b3e27476247b96d64840cb36f40b86134cd542acc3cb54687de96f139188b8a7e69d70d52ca8950b890324f30040d9364a1f9a489c4d4d2c657336b0f1bd' +
  'ac3e8d2fcbca34aa89cc9e13b57a9792f4b97ea67f40caff41e06b8f01dc8ca77047835dcaf06e07ce3166ed461b02a6986ffd82994339e5eccce79df8e94954' +
  '81845ac17041f2b3aef81d2680f66df2eeb98066d7680496eb045d13acd51786a6e88c37ac89550f4cb76f7fb2c39471e7cff42962bff4722f48314b6909efa4' +
  '1601d60aed86e1b156bc6bed5e2e690b1bdcb81d9ba78896d14493d9ccc812e86a11c2f18f82cc4f63c4ddb54604af891958dc1b0f45700d4a0162ee47963ef2' +
  'f822cea79e2781a5faba2cb0336c1882cafc34af11a91377f7ec91319ad9dcff9051ce017e135e89e36e54421630d8a7f483609c26a71ff6b325718122eba3b7' +
  '2d5470e75bbeb076bcacb3643a26a20246e40370b5d74262e7ffc3aff9c6a726b6ef19f5456efd1da52210e074c91fb9e9408834c1f17ce7944a79d287f17472' +
  'bfc85d9a99898b79555f13529287f717821b85059b675aa96c66ff79f48b87df9904484c3e3861cca0393660d7b8ea3a55cbd010ca06470c16ae9277984178da' +
  'b777e797ef8173c956a3de0c64f350e90b2f54e00896d4e60246a0974bd7fb97fa84f2062be66c3e244930f4fcc2d9949393570dad0e9c6035725ae2de775bf7' +
  '0dbb87bcf8a5e82cd1a64e93d004558c433c2996e14a5dafc13e20bbfb5ac2511fbd4ba207e414a5754ef2d0f6e314446a350f7cb5f45341c8005ae8903c0735' +
  'b4487c1d76411f840e3e25366b952d3896750a94dc7af26bd321b32c00020cc63beb8b44106486b7cae518d31acd54fd0d90713e97979922cdf948ecd567f27a' +
  '4f89bbbb25d35ad7a328b965930ac104bd126d371c16fd51163015a68918c76ca68d6749ab3a9be6c9cdb56a050852baa02344be96c8ea51ae2db0ff8526cb11' +
  'd763bc5185a068686b159fcca975a4e3faac574efa76b914920a15c421de09b2eacff4d9621ea993cfa5bf0afa6123b3f4c6568684f32cdfde24ed755d594450' +
  'c898562b22e70fa0b9ada330891eead21cf520f93ed2abb2a57b1527b616928adfea23aae4ef20bc99006d82b852a83593e6aa74a0bca025f9ba0440f60d2fe1' +
  '4ac3bfc4a688418245dd3563543f95d97a9187a8a4cac0b4d6dea497ee7bdd293227a33c2b1b249e1d6af45d5546d960cf9f428915bbe6d369fcae1141d15dbb' +
  'aa87aaffda2e36ed324902dfaac6326aa8a490669877e4fd7f78c4ea74dc2102f8352f71096850cf6c9267ad9de63a54230e2d839441646e41858b4da4e2133d' +
  '8db8071d0beae6bc1de565b07a6307578a192da7cf66f7780149ef3590e276b99fa45b0483500842ba7acf40a6f1145513c237862f600cf3b9ba0e45b2dd471d' +
  '4b699afb06aad4af36653ddbead162889d6e698c6a150793901735e11648714a82a826e5d617e70403075286cdf22348ad2f52f91f88dea9a9d9fb5081924438' +
  'd74be0f453707fce7037d95430bb392f983ffa5bfcf9af169d2239459cdc05a80b359defee2bdb4755593ca46525e8e150fbc4bb29ea560c359b088744b4ddfc' +
  'a994d923a1e66df68d584c540552f957f4a279117ae967b817c94d94431b5ea78b1089fa95a94b43ece3d707b59a5afd7afca1a242b47862b8031f680d54eda3' +
  'f4d78c687b4253fda25cad65644828de2d112217c15a9f3d7e8ff8fa09469606c01f24c5cffb6e4b382e9c6e6acf8a9e585dd9c3f94b801c37b1578fc8c956ee' +
  'e16ec6a81e9a491e5c0f93057a452920947f03271883a3460dd69799e6246198e2543e4331d1cbc74e81b6fc58c07eca3f087b9e3873748b7e75e81631af1ee5' +
  '4cbcc3ee7cf9d3d4558f7981c47db9dcd803baf2eab022fdac06d1b9305231ec756f15b62dd7dd88d6a74a466b9e4141a5dbd4babbc274ea8b66f11185e18002' +
  '2d7b692891ecbc23c26a915052f4615c79313f36235c4e3624edfea9dc8415e11e818a0d1100272aca22da0504894709b061a1f36874fdb9d09d88922e3e374a' +
  '8b99783e47bd571d584de2f36ab7bad2279f0e56a969052f0e006f6d475a724608332126c5a0867453650a958e869c3524d3d138b5c013526533b0a65a6f42b0' +
  '9da489844305fa01';

/**
 * The eight candidate 8-byte roots of the handshake, copied from
 * `.rodata 0x4ec0`. The camera picks one at random; the phone recovers which
 * one by trying all eight, so possession of this table is what makes the
 * handshake verifiable in both directions.
 */
const KEY1_TABLE_HEX: string[] = [
  '704066e40433d552',
  'ed4b8fac15f7e47b',
  '24471f118b5ea1fc',
  '05960c312b8c7f41',
  'fda588c1eba8b1f3',
  '991660561bd3d550',
  'cd32687fa9e28a30',
  '2a8fe834dec7ebf4'
];

/** One candidate from {@link KEY1_TABLE_HEX}, decoded to raw bytes. */
function key1Candidate(index: number): Uint8Array {
  const hex = KEY1_TABLE_HEX[index & 7];
  const out = new Uint8Array(8);
  for (let i = 0; i < 8; i++) {
    out[i] = parseInt(hex.substr(i * 2, 2), 16) & 0xff;
  }
  return out;
}

/** Constant-time-ish 8-byte comparison; returns true when the two match. */
function equals8(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length < 8 || b.length < 8) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < 8; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff === 0;
}

/**
 * The library's fixed-key Blowfish-CBC-MAC (`0x61bc`).
 *
 * Contract, taken from the disassembly: the chain starts at the constant
 * `01 02 03 04 05 06 07 08` used as two big-endian words, each full block is
 * XORed with the chain and then enciphered, and the result is the chain.
 * A trailing partial block is padded with `0xFF`. When the length is already a
 * multiple of eight no extra block is added. The output is the final chain.
 *
 * A zero length is undefined behaviour in the library (it would chain from
 * uninitialised stack), so callers must never pass 0.
 */
export class NikonLssMac {
  private static engine: NikonBlowfish | null = null;
  private static readonly INITIAL_CHAIN: Uint8Array = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);

  private static cipher(): NikonBlowfish {
    if (NikonLssMac.engine === null) {
      const blowfish = new NikonBlowfish();
      blowfish.loadSchedule(MAC_SCHEDULE_HEX);
      NikonLssMac.engine = blowfish;
    }
    return NikonLssMac.engine;
  }

  /** Computes the 8-byte MAC over `input`; `input` must not be empty. */
  static mac8(input: Uint8Array): Uint8Array {
    const blowfish = NikonLssMac.cipher();
    let chain: Uint8Array = NikonLssMac.INITIAL_CHAIN.slice();
    let offset = 0;
    let remaining = input.length;
    while (remaining >= 8) {
      const block = new Uint8Array(8);
      for (let i = 0; i < 8; i++) {
        block[i] = input[offset + i] ^ chain[i];
      }
      chain = blowfish.encipherBlock(block);
      offset += 8;
      remaining -= 8;
    }
    if (remaining >= 1) {
      const padded = new Uint8Array(8);
      for (let i = 0; i < 8; i++) {
        padded[i] = i < remaining ? input[offset + i] : 0xff;
      }
      const block = new Uint8Array(8);
      for (let i = 0; i < 8; i++) {
        block[i] = padded[i] ^ chain[i];
      }
      chain = blowfish.encipherBlock(block);
    }
    return chain;
  }

  /** Reads one candidate root, exposed for the layer that builds MAC inputs. */
  static candidateRoot(index: number): Uint8Array {
    return key1Candidate(index);
  }
}

/**
 * Role-B LSS authentication state machine.
 *
 * One instance drives one BLE link. Stage numbers follow the wire protocol;
 * the state guards mirror the library's own admission table, so a call made out
 * of order is refused here rather than producing a frame the camera rejects.
 */
export class NikonLssSession {
  private static readonly STATE_FRESH: number = 0;
  private static readonly STATE_INITIALIZED: number = 1;
  private static readonly STATE_STAGE1_SENT: number = 3;
  private static readonly STATE_STAGE3_SENT: number = 5;
  private static readonly STATE_KEYED: number = 6;

  private state: number = NikonLssSession.STATE_FRESH;
  private phoneNonce: Uint8Array = new Uint8Array(8);
  private derivedId: Uint8Array = new Uint8Array(8);
  private sharedIndex: number = -1;
  private sessionCipher: NikonBlowfish | null = null;
  private sessionKey: Uint8Array = new Uint8Array(0);

  /**
   * Returns a copy of the derived 8-byte session key, or null when the session
   * is not yet keyed.
   *
   * The same key protects the Wi-Fi credential block whether it is read over
   * BLE (characteristic `2004`) or over PTP (operation `0x9532`), so a caller
   * that holds the keyed session can hand the key to whichever transport reads
   * the block. A copy is returned so the internal cipher is never shared.
   */
  exportSessionKey(): Uint8Array | null {
    if (this.sessionKey.length < 8) {
      return null;
    }
    return this.sessionKey.slice();
  }

  /**
   * Decrypts `input` with a session key, using the same CBC construction as the
   * instance methods: an all-zero IV, chaining across whole 8-byte blocks.
   *
   * Returns null when the key is short or the input is empty / not a whole
   * number of blocks.
   */
  static decipherWithKey(key: Uint8Array, input: Uint8Array): Uint8Array | null {
    if (key.length < 8 || input.length === 0 || input.length % 8 !== 0) {
      return null;
    }
    const cipher = new NikonBlowfish();
    cipher.initKey(key.slice(0, 8));
    const out = new Uint8Array(input.length);
    let chain = new Uint8Array(8);
    for (let offset = 0; offset < input.length; offset += 8) {
      const block = input.slice(offset, offset + 8);
      const plain = cipher.decipherBlock(block);
      for (let i = 0; i < 8; i++) {
        out[offset + i] = plain[i] ^ chain[i];
      }
      chain = block;
    }
    return out;
  }

  /** True once a session key has been derived. */
  isKeyed(): boolean {
    return this.state === NikonLssSession.STATE_KEYED;
  }

  /** Which of the eight candidate roots the camera selected, or -1. */
  index(): number {
    return this.sharedIndex;
  }

  /**
   * Resets the session. The seed is accepted for parity with the native
   * `LsSecInit`, which seeds `srand`; this implementation draws its nonce from
   * the system CSPRNG instead, so the seed has no effect on the wire bytes.
   */
  init(seed: number): void {
    this.state = NikonLssSession.STATE_INITIALIZED;
    this.phoneNonce = new Uint8Array(8);
    this.derivedId = new Uint8Array(8);
    this.sharedIndex = -1;
    this.sessionCipher = null;
  }

  /**
   * Stage 1: draws this phone's 8-byte nonce. Returns null when called out of
   * order. The caller puts the value in the `nonce` field of the stage-1 frame
   * and must keep it until stage 3, because the camera will bind it as `X`.
   */
  stage1(): Uint8Array | null {
    if (this.state !== NikonLssSession.STATE_INITIALIZED) {
      return null;
    }
    const drawn: Uint8Array = cryptoFramework.createRandom().generateRandomSync(8).data;
    const nonce = new Uint8Array(8);
    for (let i = 0; i < 8; i++) {
      nonce[i] = drawn[i];
    }
    this.phoneNonce = nonce;
    this.state = NikonLssSession.STATE_STAGE1_SENT;
    return nonce;
  }

  /** This phone's stage-1 nonce, retained for the stage-3 frame. */
  ownNonce(): Uint8Array {
    return this.phoneNonce;
  }

  /**
   * Stage 3: recovers the camera's chosen root and answers it.
   *
   * `cameraNonce` is the stage-2 frame's `nonce` and `mac1` its `deviceId`.
   * The returned 8 bytes go into the stage-3 frame's `deviceId`; the stage-3
   * frame's `nonce` is this phone's own nonce again.
   *
   * Returns null when none of the eight roots reproduces `mac1`, which means
   * the frame was not from a camera we share a root with.
   */
  stage3(cameraNonce: Uint8Array, mac1: Uint8Array): Uint8Array | null {
    if (this.state !== NikonLssSession.STATE_STAGE1_SENT) {
      return null;
    }
    if (cameraNonce.length < 8 || mac1.length < 8) {
      return null;
    }
    let matched = -1;
    for (let i = 0; i < 8; i++) {
      const material = new Uint8Array(24);
      material.set(key1Candidate(i), 0);
      material.set(cameraNonce.slice(0, 8), 8);
      material.set(this.phoneNonce, 16);
      if (equals8(NikonLssMac.mac8(material), mac1)) {
        matched = i;
        break;
      }
    }
    if (matched < 0) {
      return null;
    }
    this.sharedIndex = matched;
    // ctx[0..7] = idx || N_A[1..3] || X[0..3], exactly as LsSec3rdStage writes it:
    // the index overwrites the first byte of N_A, and only the first four bytes
    // of X survive.
    this.derivedId[0] = matched & 0xff;
    this.derivedId[1] = cameraNonce[1];
    this.derivedId[2] = cameraNonce[2];
    this.derivedId[3] = cameraNonce[3];
    this.derivedId[4] = this.phoneNonce[0];
    this.derivedId[5] = this.phoneNonce[1];
    this.derivedId[6] = this.phoneNonce[2];
    this.derivedId[7] = this.phoneNonce[3];
    // The answer swaps the two nonces relative to the verification above.
    const material = new Uint8Array(24);
    material.set(key1Candidate(matched), 0);
    material.set(this.phoneNonce, 8);
    material.set(cameraNonce.slice(0, 8), 16);
    this.state = NikonLssSession.STATE_STAGE3_SENT;
    return NikonLssMac.mac8(material);
  }

  /**
   * Derives the session key and installs the session cipher.
   *
   * `key1` and `key2` must be the same values the camera used. On the phone
   * they are the stage-4 frame's `deviceId` and the camera device id passed
   * into the authentication call, in that order.
   */
  generateKey(key1: Uint8Array, key2: Uint8Array): boolean {
    if (this.state !== NikonLssSession.STATE_STAGE3_SENT) {
      return false;
    }
    if (!this.deriveSessionKey(key1, key2)) {
      return false;
    }
    this.state = NikonLssSession.STATE_KEYED;
    return true;
  }

  /**
   * Derives the session cipher without requiring the state machine to sit in a
   * particular step.
   *
   * This exists because the handshake never binds the device identifier: stage
   * 3 verifies against the recovered root, the camera's nonce and this phone's
   * nonce, and nothing else. Only `key2` — which the official client takes from
   * the device identifier — feeds the session key. So once a handshake has
   * succeeded, alternate `key2` values can be tried entirely locally against
   * the same credential bytes, with no further camera traffic and no dependency
   * on the camera's own session state.
   *
   * Returns false when stage 3 has not run, or when either argument is short.
   */
  deriveSessionKey(key1: Uint8Array, key2: Uint8Array): boolean {
    if (this.sharedIndex < 0) {
      return false;
    }
    if (key1.length < 8 || key2.length < 8) {
      return false;
    }
    const material = new Uint8Array(24);
    material.set(key1.slice(0, 8), 0);
    material.set(key2.slice(0, 8), 8);
    material.set(this.derivedId, 16);
    const sessionKey = NikonLssMac.mac8(material);
    const cipher = new NikonBlowfish();
    cipher.initKey(sessionKey);
    this.sessionCipher = cipher;
    this.sessionKey = sessionKey;
    return true;
  }

  /**
   * Reports whether `key1` from the stage-4 frame is the shared root the phone
   * recovered. Diagnostic only: it turns the one remaining unknown about the
   * key agreement into a single device-log line instead of a silent failure.
   */
  describeKey1(key1: Uint8Array): string {
    if (this.sharedIndex < 0) {
      return 'key1=unavailable stage3-not-run';
    }
    if (key1.length < 8) {
      return 'key1=malformed length=' + key1.length;
    }
    return equals8(key1, key1Candidate(this.sharedIndex))
      ? 'key1=shared-root index=' + this.sharedIndex
      : 'key1=other index=' + this.sharedIndex;
  }

  /**
   * CBC-encrypts whole 8-byte blocks with the session cipher.
   *
   * The library re-reads the IV on every call and never writes the final chain
   * back, so each call is an independent CBC operation starting from an
   * all-zero IV — that is why the 32-byte SSID and the 64-byte password are two
   * separate decrypts rather than one stream. The length must be a positive
   * multiple of eight.
   */
  encipher(input: Uint8Array): Uint8Array | null {
    if (this.sessionCipher === null) {
      return null;
    }
    if (input.length === 0 || input.length % 8 !== 0) {
      return null;
    }
    const cipher = this.sessionCipher;
    const out = new Uint8Array(input.length);
    let chain = new Uint8Array(8);
    for (let offset = 0; offset < input.length; offset += 8) {
      const block = new Uint8Array(8);
      for (let i = 0; i < 8; i++) {
        block[i] = input[offset + i] ^ chain[i];
      }
      chain = cipher.encipherBlock(block);
      out.set(chain, offset);
    }
    return out;
  }

  /** Decrypts whole 8-byte blocks; see {@link encipher} for the IV semantics. */
  decipher(input: Uint8Array): Uint8Array | null {
    if (this.sessionCipher === null) {
      return null;
    }
    if (input.length === 0 || input.length % 8 !== 0) {
      return null;
    }
    const cipher = this.sessionCipher;
    const out = new Uint8Array(input.length);
    let chain = new Uint8Array(8);
    for (let offset = 0; offset < input.length; offset += 8) {
      const block = input.slice(offset, offset + 8);
      const plain = cipher.decipherBlock(block);
      for (let i = 0; i < 8; i++) {
        out[offset + i] = plain[i] ^ chain[i];
      }
      chain = block;
    }
    return out;
  }
}
