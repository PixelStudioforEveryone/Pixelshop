/**
 * 尼康 LSS（SnapBridge Low-power Service）认证所需的密码学原语。
 *
 * 来源与证据
 * ----------
 * 尼康 SnapBridge 2.13.3 (com.nikon.snapbridge.cmru) 的原生认证库
 * lib\arm64-v8a\libLsSec-jni.so（sha256 762477cad14f55495d5e4f9caec1ae2b81f2852432f5ab7cc88e963e8fd99853，
 * 38640 字节，arm64 ELF）经反汇编确认：
 *
 *   1. 该库自包含（NEEDED 仅 libc/libm/libdl，无 OpenSSL），密码学为自研实现。
 *   2. .rodata 偏移 0xd88 起有一张完整 Blowfish 常量表：1042 项，步长 8 字节
 *      （32 位小端值 + 4 字节零填充，典型的 unsigned long LP64 表）。
 *      已与教科书 Blowfish 常量逐项比对，P[0..17] 18/18、S0[0..5] 6/6、
 *      S3[255]=0x3ac372e6 全部一致，1042/1042 值槽非零 —— 即未改动的标准 Blowfish。
 *   3. 字符串常量含 "keybytes != 0" 与 "keybytes <= 56"。56 字节正是 Blowfish
 *      的最大密钥长度（448 位），进一步确证。
 *   4. 上下文（下称 ctx）总长 8408 字节，状态字在 ctx+8400；
 *      LsSecGenerateKey 由 ctx[0..7]、key1(8 字节)、key2(8 字节) 派生出
 *      ctx+64 处的 Blowfish 密钥；LsSecEncipher 要求状态 == 6。
 *
 * 下表**逐字节取自该 .so 的 .rodata**，不是转抄公开资料，因此可以保证与相机端
 * 使用的初始 P 数组 / S 盒完全一致。
 *
 * 尚未确定（勿猜）
 * ----------------
 *   - 原生核心 0x5e0c 的字节序与分组处理方式。本文件按标准 Blowfish 约定使用
 *     大端 64 位分组（big-endian）。若与相机端对不上，第一个要检查的就是这里。
 *   - 密钥派生（0x61bc / 0x5a70）与四个 stage 的语义尚未还原，不在本文件内。
 *
 * @since 2026-11
 */

import { NIKON_LSS_HASH_SCHEDULE_HEX } from './NikonLssHashTable';

/** 标准 Blowfish 初始表：前 18 项为 P 数组，随后 1024 项为 S0..S3 展平。 */
const BLOWFISH_TABLE_HEX: string =
  '243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89452821e638d01377be5466cf34e90c6cc0ac29b7c97c50dd3f84d5b5b5470917' +
  '9216d5d98979fb1bd1310ba698dfb5ac2ffd72dbd01adfb7b8e1afed6a267e96ba7c9045f12c7f9924a19947b3916cf70801f2e2858efc16636920d871574e69' +
  'a458fea3f4933d7e0d95748f728eb658718bcd5882154aee7b54a41dc25a59b59c30d5392af26013c5d1b023286085f0ca417918b8db38ef8e79dcb0603a180e' +
  '6c9e0e8bb01e8a3ed71577c1bd314b2778af2fda55605c60e65525f3aa55ab945748986263e8144055ca396a2aab10b6b4cc5c341141e8cea15486af7c72e993' +
  'b3ee1411636fbc2a2ba9c55d741831f6ce5c3e169b87931eafd6ba336c24cf5c7a325381289586773b8f48986b4bb9afc4bfe81b6628219361d809ccfb21a991' +
  '487cac605dec8032ef845d5de98575b1dc262302eb651b8823893e81d396acc50f6d6ff383f442392e0b4482a484200469c8f04a9e1f9b5e21c66842f6e96c9a' +
  '670c9c61abd388f06a51a0d2d8542f68960fa728ab5133a36eef0b6c137a3be4ba3bf0507efb2a98a1f1651d39af017666ca593e82430e888cee8619456f9fb4' +
  '7d84a5c33b8b5ebee06f75d885c12073401a449f56c16aa64ed3aa62363f77061bfedf72429b023d37d0d724d00a1248db0fead349f1c09b075372c980991b7b' +
  '25d479d8f6e8def7e3fe501ab6794c3b976ce0bd04c006bac1a94fb6409f60c45e5c9ec2196a246368fb6faf3e6c53b51339b2eb3b52ec6f6dfc511f9b30952c' +
  'cc814544af5ebd09bee3d004de334afd660f2807192e4bb3c0cba85745c8740fd20b5f39b9d3fbdb5579c0bd1a60320ad6a100c6402c7279679f25fefb1fa3cc' +
  '8ea5e9f8db3222f83c7516dffd616b152f501ec8ad0552ab323db5fafd23876053317b483e00df829e5c57bbca6f8ca01a87562edf1769dbd542a8f6287effc3' +
  'ac6732c68c4f5573695b27b0bbca58c8e1ffa35db8f011a010fa3d98fd2183b84afcb56c2dd1d35b9a53e479b6f84565d28e49bc4bfb9790e1ddf2daa4cb7e33' +
  '62fb1341cee4c6e8ef20cada36774c01d07e9efe2bf11fb495dbda4dae909198eaad8e716b93d5a0d08ed1d0afc725e08e3c5b2f8e7594b78ff6e2fbf2122b64' +
  '8888b812900df01c4fad5ea0688fc31cd1cff191b3a8c1ad2f2f2218be0e1777ea752dfe8b021fa1e5a0cc0fb56f74e818acf3d6ce89e299b4a84fe0fd13e0b7' +
  '7cc43b81d2ada8d9165fa2668095770593cc7314211a1477e6ad206577b5fa86c75442f5fb9d35cfebcdaf0c7b3e89a0d6411bd3ae1e7e4900250e2d2071b35e' +
  '226800bb57b8e0af2464369bf009b91e5563911d59dfa6aa78c14389d95a537f207d5ba202e5b9c5832603766295cfa911c819684e734a41b3472dca7b14a94a' +
  '1b5100529a532915d60f573fbc9bc6e42b60a47681e6740008ba6fb5571be91ff296ec6b2a0dd915b6636521e7b9f9b6ff34052ec585566453b02d5da99f8fa1' +
  '08ba47996e85076a4b7a70e9b5b32944db75092ec4192623ad6ea6b049a7df7d9cee60b88fedb266ecaa8c71699a17ff5664526cc2b19ee1193602a575094c29' +
  'a0591340e4183a3e3f54989a5b429d656b8fe4d699f73fd6a1d29c07efe830f54d2d38e6f0255dc14cdd20868470eb266382e9c6021ecc5e09686b3f3ebaefc9' +
  '3c9718146b6a70a1687f358452a0e286b79c5305aa5007373e07841c7fdeae5c8e7d44ec5716f2b8b03ada37f0500c0df01c1f040200b3ffae0cf51a3cb574b2' +
  '25837a58dc0921bdd19113f97ca92ff69432477322f547013ae5e58137c2dadcc8b576349af3dda7a94461460fd0030eecc8c73ea4751e41e238cd993bea0e2f' +
  '3280bba1183eb3314e548b384f6db9086f420d03f60a04bf2cb8129024977c795679b072bcaf89afde9a771fd9930810b38bae12dccf3f2e5512721f2e6b7124' +
  '501adde69f84cd877a5847187408da17bc9f9abce94b7d8cec7aec3adb851dfa63094366c464c3d2ef1c18473215d908dd433b3724c2ba1612a14d432a65c451' +
  '50940002133ae4dd71dff89e10314e5581ac77d65f11199b043556f1d7a3c76b3c11183b5924a509f28fe6ed97f1fbfa9ebabf2c1e153c6e86e34570eae96fb1' +
  '860e5e0a5a3e2ab3771fe71c4e3d06fa2965dcb999e71d0f803e89d65266c8252e4cc9789c10b36ac6150eba94e2ea78a5fc3c531e0a2df4f2f74ea7361d2b3d' +
  '1939260f19c279605223a708f71312b6ebadfe6eeac31f66e3bc4595a67bc883b17f37d1018cff28c332ddefbe6c5aa56558218568ab9802eecea50fdb2f953b' +
  '2aef7dad5b6e2f841521b62829076170ecdd4775619f151013cca830eb61bd960334fe1eaa0363cfb5735c904c70a239d59e9e0bcbaade14eecc86bc60622ca7' +
  '9cab5cabb2f3846e648b1eaf19bdf0caa02369b9655abb5040685a323c2ab4b3319ee9d5c021b8f79b540b19875fa09995f7997e623d7da8f837889a97e32d77' +
  '11ed935f166812810e358829c7e61fd696dedfa17858ba9957f584a51b2272639b83c3ff1ac24696cdb30aeb532e30548fd948e46dbc312858ebf2ef34c6ffea' +
  'fe28ed61ee7c3c735d4a14d9e864b7e342105d14203e13e045eee2b6a3aaabeadb6c4f15facb4fd0c742f442ef6abbb5654f3b1d41cd2105d81e799e86854dc7' +
  'e44b476a3d816250cf62a1f25b8d2646fc8883a0c1c7b6a37f1524c369cb749247848a0b5692b285095bbf00ad19489d1462b17423820e0058428d2a0c55f5ea' +
  '1dadf43e233f70613372f0928d937e41d65fecf16c223bdb7cde3759cbee74604085f2a7ce77326ea607808419f8509ee8efd85561d99735a969a7aac50c06c2' +
  '5a04abfc800bcadc9e447a2ec3453484fdd567050e1e9ec9db73dbd3105588cd675fda79e3674340c5c43465713e38d83d28f89ef16dff20153e21e78fb03d4a' +
  'e6e39f2bdb83adf7e93d5a68948140f7f64c261c94692934411520f77602d4f7bcf46b2ed4a20068d40824713320f46a43b7d4b7500061af1e39f62e97244546' +
  '14214f74bf8b88404d95fc1d96b591af70f4ddd366a02f45bfbc09ec03bd97857fac6dd031cb850496eb27b355fd3941da2547e6abca0a9a28507825530429f4' +
  '0a2c86dae9b66dfb68dc1462d7486900680ec0a427a18dee4f3ffea2e887ad8cb58ce0067af4d6b6aace1e7cd3375fecce78a399406b2a4220fe9e35d9f385b9' +
  'ee39d7ab3b124e8b1dc9faf74b6d185626a36631eae397b23a6efa74dd5b43326841e7f7ca7820fbfb0af54ed8feb397454056acba48952755533a3a20838d87' +
  'fe6ba9b7d096954b55a867bca1159a58cca9296399e1db33a62a4a563f3125f95ef47e1c9029317cfdf8e80204272f7080bb155c05282ce395c11548e4c66d22' +
  '48c1133fc70f86dc07f9c9ee41041f0f404779a45d886e17325f51ebd59bc0d1f2bcc18f41113564257b7834602a9c60dff8e8a31f636c1b0e12b4c202e1329e' +
  'af664fd1cad181156b2395e0333e92e13b240b62eebeb92285b2a20ee6ba0d99de720c8c2da2f728d012784595b794fd647d0862e7ccf5f05449a36f877d48fa' +
  'c39dfd27f33e8d1e0a476341992eff743a6f6eabf4f8fd37a812dc60a1ebddf8991be14cdb6e6b0dc67b55106d672c372765d43bdcd0e804f1290dc7cc00ffa3' +
  'b5390f92690fed0b667b9ffbcedb7d9ca091cf0bd9155ea3bb132f88515bad247b9479bf763bd6eb37392eb3cc1159798026e297f42e312d6842ada7c66a2b3b' +
  '12754ccc782ef11c6a124237b79251e706a1bbe64bfb63501a6b101811caedfa3d25bdd8e2e1c3c9444216590a121386d90cec6ed5abea2a64af674eda86a85f' +
  'bebfe98864e4c3fe9dbc8057f0f7c08660787bf86003604dd1fd8346f6381fb07745ae04d736fccc83426b33f01eab71b08041873c005e5f77a057bebde8ae24' +
  '55464299bf582e614e58f48ff2ddfda2f474ef388789bdc25366f9c3c8b38e74b475f25546fcd9b97aeb26618b1ddf84846a0e79915f95e2466e598e20b45770' +
  '8cd55591c902de4cb90bace1bb8205d011a862487574a99eb77f19b6e0a9dc09662d09a1c4324633e85a1f0209f0be8c4a99a0251d6efe101ab93d1d0ba5a4df' +
  'a186f20f2868f169dcb7da83573906fea1e2ce9b4fcd7f5250115e01a70683faa002b5c40de6d0279af88c27773f8641c3604c0661a806b5f0177a28c0f586e0' +
  '006058aa30dc7d6211e69ed72338ea6353c2dd94c2c21634bbcbee5690bcb6deebfc7da1ce591d766f05e4094b7c018839720a3d7c927c2486e3725f724d9db9' +
  '1ac15bb4d39eb8fced54557808fca5b5d83d7cd34dad0fc41e50ef5eb161e6f8a28514d96c51133c6fd5c7e756e14ec4362abfceddc6c837d79a323492638212' +
  '670efa8e406000e03a39ce37d3faf5cfabc277375ac52d1b5cb0679e4fa33742d382274099bc9bbed5118e9dbf0f7315d62d1c7ec700c47bb78c1b6b21a19045' +
  'b26eb1be6a366eb45748ab2fbc946e79c6a376d26549c2c8530ff8ee468dde7dd5730a1d4cd04dc62939bbdba9ba4650ac9526e8be5ee304a1fad5f06a2d519a' +
  '63ef8ce29a86ee22c089c2b843242ef6a51e03aa9cf2d0a483c061ba9be96a4d8fe51550ba645bd62826a2f9a73a3ae14ba99586ef5562e9c72fefd3f752f7da' +
  '3f046f6977fa0a5980e4a91587b086019b09e6ad3b3ee593e990fd5a9e34d7972cf0b7d9022b8b5196d5ac3a017da67dd1cf3ed67c7d2d281f9f25cfadf2b89b' +
  '5ad6b4725a88f54ce029ac71e019a5e647b0acfded93fa9be8d3c48d283b57ccf8d5662979132e28785f0191ed756055f7960e44e3d35e8c15056dd488f46dba' +
  '03a161250564f0bdc3eb9e153c9057a297271aeca93a072a1b3f6d9b1e6321f5f59c66fb26dcf3197533d928b155fdf5035634828aba3cbb28517711c20ad9f8' +
  'abcc5167ccad925f4de817513830dc8e379d58629320f991ea7a90c2fb3e7bce5121ce64774fbe32a8b6e37ec3293d4648de53696413e680a2ae0810dd6db224' +
  '69852dfd09072166b39a460a6445c0dd586cdecf1c20c8ae5bbef7dd1b588d40ccd2017f6bb4e3bbdda26a7e3a59ff453e350a44bcb4cdd572eacea8fa6484bb' +
  '8d6612aebf3c6f47d29be463542f5d9eaec2771bf64e6370740e0d8de75b1357f8721671af537d5d4040cb084eb4e2cc34d2466a0115af84e1b0042895983a1d' +
  '06b89fb4ce6ea0486f3f3b823520ab82011a1d4b277227f8611560b1e7933fdcbb3a792b344525bda08839e151ce794b2f32c9b7a01fbac9e01cc87ebcc7d1f6' +
  'cf0111c3a1e8aac71a908749d44fbd9ad0dadecbd50ada380339c32ac69136678df9317ce0b12b4ff79e59b743f5bb3af2d519ff27d9459cbf97222c15e6fc2a' +
  '0f91fc719b941525fae59361ceb69cebc2a8645912baa8d1b6c1075ee3056a0c10d25065cb03a442e0ec6e0e1698db3b4c98a0be3278e9649f1f9532e0d392df' +
  'd3a0342b8971f21e1b0a74414ba3348cc5be7120c37632d8df359f8d9b992f2ee60b6f470fe3f11de54cda541edad891ce6279cfcd3e7e6f1618b166fd2c1d05' +
  '848fd2c5f6fb2299f523f357a632762393a8353156cccd02acf081625a75ebb56e16369788d273ccde96629281b949d04c50901b71c65614e6c6c7bd327a140a' +
  '45e1d006c3f27b9ac9aa53fd62a80f00bb25bfe235bdd2f671126905b2040222b6cbcf7ccd769c2b53113ec01640e3d338abbd602547adf0ba38209cf746ce76' +
  '77afa1c52075606085cbfe4e8ae88dd87aaaf9b04cf9aa7e1948c25c02fb8a8c01c36ae4d6ebe1f990d4f869a65cdea03f09252dc208e69fb74e6132ce77e25b' +
  '578fdfe33ac372e6';

/** P 数组项数。 */
const BLOWFISH_P_COUNT: number = 18;
/** 单个 S 盒项数。 */
const BLOWFISH_S_COUNT: number = 256;
/** 四个 S 盒展平后的项数。 */
const BLOWFISH_S_TOTAL: number = BLOWFISH_S_COUNT * 4;
/** 表总项数。 */
const BLOWFISH_TABLE_COUNT: number = BLOWFISH_P_COUNT + BLOWFISH_S_TOTAL;

/** 把 1042 项的十六进制常量还原成 P/S 表，避免实例间互相污染。 */
function buildTableFromHex(hex: string): Uint32Array {
  const table = new Uint32Array(BLOWFISH_TABLE_COUNT);
  for (let i = 0; i < BLOWFISH_TABLE_COUNT; i++) {
    table[i] = parseInt(hex.slice(i * 8, i * 8 + 8), 16) >>> 0;
  }
  return table;
}

/**
 * 标准 Blowfish 分组密码。
 *
 * 只实现分组原语与密钥编排；LSS 的分阶段握手在别处驱动它。
 * 所有算术都在 32 位无符号域内，用 >>> 0 归一化。
 */
export class NikonBlowfish {
  private p: Uint32Array = new Uint32Array(BLOWFISH_P_COUNT);
  private s: Uint32Array = new Uint32Array(BLOWFISH_S_TOTAL);
  private outL: number = 0;
  private outR: number = 0;

  constructor() {
    this.resetTables();
  }

  /** 把 P 数组与 S 盒恢复成标准初值。 */
  private resetTables(): void {
    this.loadSchedule(BLOWFISH_TABLE_HEX);
  }

  /**
   * 直接载入一份**已编排好**的 P/S 状态。
   *
   * 这条路径不跑密钥编排：传进来的表本身就已经是编排结果。尼康 MAC 使用的
   * 固定密钥只以「编排后状态」的形式存在于 libLsSec-jni.so 的 .rodata
   * 0x2e28；密钥本身在该 .so 中不可恢复，因此必须整表搬运，**不能**再对它
   * 调用 initKey。
   */
  loadSchedule(hex: string): void {
    const table = buildTableFromHex(hex);
    for (let i = 0; i < BLOWFISH_P_COUNT; i++) {
      this.p[i] = table[i];
    }
    for (let i = 0; i < BLOWFISH_S_TOTAL; i++) {
      this.s[i] = table[BLOWFISH_P_COUNT + i];
    }
  }

  /** 标准 Blowfish 轮函数 F(x)。 */
  private f(x: number): number {
    const s = this.s;
    const a = s[(x >>> 24) & 0xff];
    const b = s[BLOWFISH_S_COUNT + ((x >>> 16) & 0xff)];
    const c = s[BLOWFISH_S_COUNT * 2 + ((x >>> 8) & 0xff)];
    const d = s[BLOWFISH_S_COUNT * 3 + (x & 0xff)];
    return ((((a + b) >>> 0) ^ c) + d) >>> 0;
  }

  /** 用当前 P/S 加密一个分组，结果写入 outL/outR。 */
  private encipherPair(xl: number, xr: number): void {
    const p = this.p;
    let l = xl >>> 0;
    let r = xr >>> 0;
    for (let i = 0; i < 16; i++) {
      l = (l ^ p[i]) >>> 0;
      r = (r ^ this.f(l)) >>> 0;
      const swap = l;
      l = r;
      r = swap;
    }
    const undo = l;
    l = r;
    r = undo;
    r = (r ^ p[16]) >>> 0;
    l = (l ^ p[17]) >>> 0;
    this.outL = l;
    this.outR = r;
  }

  /** 用当前 P/S 解密一个分组，结果写入 outL/outR。 */
  private decipherPair(xl: number, xr: number): void {
    const p = this.p;
    let l = xl >>> 0;
    let r = xr >>> 0;
    for (let i = 17; i >= 2; i--) {
      l = (l ^ p[i]) >>> 0;
      r = (r ^ this.f(l)) >>> 0;
      const swap = l;
      l = r;
      r = swap;
    }
    const undo = l;
    l = r;
    r = undo;
    r = (r ^ p[1]) >>> 0;
    l = (l ^ p[0]) >>> 0;
    this.outL = l;
    this.outR = r;
  }

  /**
   * 标准 Blowfish 密钥编排。
   *
   * 先恢复标准表，再把密钥字节循环异或进 P 数组（每次取 4 字节拼成一个 32 位字，
   * 大端顺序），最后用当前状态反复加密全零分组来填充 P 与四个 S 盒。
   *
   * @param key 密钥字节，长度 1..56。空密钥只恢复标准表，不做编排。
   */
  initKey(key: Uint8Array): void {
    this.resetTables();
    const keyLength = key.length;
    if (keyLength === 0) {
      return;
    }
    let j = 0;
    for (let i = 0; i < BLOWFISH_P_COUNT; i++) {
      let data = 0;
      for (let k = 0; k < 4; k++) {
        data = ((data << 8) | (key[j] & 0xff)) >>> 0;
        j = (j + 1) % keyLength;
      }
      this.p[i] = (this.p[i] ^ data) >>> 0;
    }
    let l = 0;
    let r = 0;
    for (let i = 0; i < BLOWFISH_P_COUNT; i += 2) {
      this.encipherPair(l, r);
      l = this.outL;
      r = this.outR;
      this.p[i] = l;
      this.p[i + 1] = r;
    }
    for (let i = 0; i < BLOWFISH_S_TOTAL; i += 2) {
      this.encipherPair(l, r);
      l = this.outL;
      r = this.outR;
      this.s[i] = l;
      this.s[i + 1] = r;
    }
  }

  /** 加密 8 字节分组（大端 64 位），返回新的 8 字节。 */
  encipherBlock(input: Uint8Array): Uint8Array {
    const l = ((input[0] << 24) | (input[1] << 16) | (input[2] << 8) | input[3]) >>> 0;
    const r = ((input[4] << 24) | (input[5] << 16) | (input[6] << 8) | input[7]) >>> 0;
    this.encipherPair(l, r);
    return NikonBlowfish.packPair(this.outL, this.outR);
  }

  /** 解密 8 字节分组（大端 64 位），返回新的 8 字节。 */
  decipherBlock(input: Uint8Array): Uint8Array {
    const l = ((input[0] << 24) | (input[1] << 16) | (input[2] << 8) | input[3]) >>> 0;
    const r = ((input[4] << 24) | (input[5] << 16) | (input[6] << 8) | input[7]) >>> 0;
    this.decipherPair(l, r);
    return NikonBlowfish.packPair(this.outL, this.outR);
  }

  /**
   * 加密一对 32 位字，返回 `[L, R]`。
   *
   * 这是 `libLsSec-jni.so` 里 `FUN_00105730(sched, &l, &r)` 的原生形态——
   * 原生直接在两个 32 位字上做 16 轮，而不是打包成 8 字节。LSS 的哈希就是
   * 用这种形态逐字前馈的，所以必须单独暴露，不能绕 `encipherBlock`。
   */
  encipherWords(l: number, r: number): Uint32Array {
    this.encipherPair(l, r);
    return Uint32Array.from([this.outL, this.outR]);
  }

  /** 解密一对 32 位字（`FUN_00105938`），返回 `[L, R]`。 */
  decipherWords(l: number, r: number): Uint32Array {
    this.decipherPair(l, r);
    return Uint32Array.from([this.outL, this.outR]);
  }

  private static packPair(l: number, r: number): Uint8Array {
    const out = new Uint8Array(8);
    out[0] = (l >>> 24) & 0xff;
    out[1] = (l >>> 16) & 0xff;
    out[2] = (l >>> 8) & 0xff;
    out[3] = l & 0xff;
    out[4] = (r >>> 24) & 0xff;
    out[5] = (r >>> 16) & 0xff;
    out[6] = (r >>> 8) & 0xff;
    out[7] = r & 0xff;
    return out;
  }
}

/** 大端读 32 位字——与原生 `FUN_001087ac` 一致（`p[0]<<24 | p[1]<<16 | p[2]<<8 | p[3]`）。 */
function readBe32(data: Uint8Array, offset: number): number {
  return (((data[offset] << 24) | (data[offset + 1] << 16) |
    (data[offset + 2] << 8) | data[offset + 3]) >>> 0);
}

/** 大端写 32 位字——与原生 `FUN_00108800` 一致。 */
function writeBe32(data: Uint8Array, offset: number, value: number): void {
  data[offset] = (value >>> 24) & 0xff;
  data[offset + 1] = (value >>> 16) & 0xff;
  data[offset + 2] = (value >>> 8) & 0xff;
  data[offset + 3] = value & 0xff;
}

/**
 * LSS 的分层加密：**哈希 → 密钥编排 → CBC 加解密**，三层都跑在同一个标准
 * Blowfish 分组函数上。
 *
 * 全部依据 `libLsSec-jni.so` 的反编译；完整推导见
 * `tmp/lssec-algorithm-spec.md` 与 `tmp/ghidra-*.log`。
 *
 * 此前这里是个"尚未还原、禁止猜测"的空占位——现在两个原生函数都已还原：
 *   - `FUN_001061bc` → {@link hash}
 *   - `LsSecGenerateKey`（0x6c84）→ {@link generateKey}
 *   - `FUN_00105fd4` / `FUN_00105e0c` → {@link decipher} / {@link encipher}
 */
export class NikonLssHandshake {
  /**
   * 哈希初始值：`DAT_00102e18` / `DAT_00102e20`。
   *
   * .rodata 实测字节为 `04 03 02 01 00 00 00 00` / `08 07 06 05 00 00 00 00`，
   * 即小端 64 位的 `0x01020304` / `0x05060708`——一对玩具常量。
   */
  private static readonly HASH_IV_0: number = 0x01020304;
  private static readonly HASH_IV_1: number = 0x05060708;

  private static hashEngine: NikonBlowfish | null = null;

  /**
   * 哈希专用的 Blowfish 状态：**整表搬运**那张预置调度。
   *
   * 原生里 `FUN_001061ac` 只把一个"已初始化"标志置 1，**不做任何密钥设置**，
   * 说明该状态是烘焙进二进制的常量（由重定位指向 .rodata 0x2e28）。
   * 因此这里只能 `loadSchedule`，**绝不能**改成 `initKey`——那个密钥在 .so
   * 里不可恢复。
   */
  private static engine(): NikonBlowfish {
    if (NikonLssHandshake.hashEngine === null) {
      const instance = new NikonBlowfish();
      instance.loadSchedule(NIKON_LSS_HASH_SCHEDULE_HEX);
      NikonLssHandshake.hashEngine = instance;
    }
    return NikonLssHandshake.hashEngine;
  }

  /**
   * `FUN_001061bc`：8 字节哈希。
   *
   * 每 8 字节一组：`a = BE32(blk) ^ h0`、`b = BE32(blk+4) ^ h1`，用固定调度加密后
   * 结果成为新的 `h0`/`h1`（Davies–Meyer 式前馈），最后把 `h0 ‖ h1` 大端写出。
   *
   * 尾部不足 8 字节时**用 0xFF 补齐**（不是补零，这点极易搞错）。注意
   * `GenerateKey` 的输入恒为 24 字节，走不到这个分支。
   */
  static hash(input: Uint8Array): Uint8Array {
    const engine = NikonLssHandshake.engine();
    let h0 = NikonLssHandshake.HASH_IV_0;
    let h1 = NikonLssHandshake.HASH_IV_1;
    let offset = 0;
    let remaining = input.length;
    while (remaining > 7) {
      const a = (readBe32(input, offset) ^ h0) >>> 0;
      const b = (readBe32(input, offset + 4) ^ h1) >>> 0;
      const mixed = engine.encipherWords(a, b);
      h0 = mixed[0];
      h1 = mixed[1];
      offset += 8;
      remaining -= 8;
    }
    if (remaining !== 0) {
      const tail = new Uint8Array(8);
      tail.fill(0xff);
      for (let i = 0; i < remaining; i++) {
        tail[i] = input[offset + i];
      }
      // 原生那个补齐循环是 `i < 7`，第 8 字节在源码里未初始化；这里按 0 处理并记录。
      tail[7] = 0;
      const a = (readBe32(tail, 0) ^ h0) >>> 0;
      const b = (readBe32(tail, 4) ^ h1) >>> 0;
      const mixed = engine.encipherWords(a, b);
      h0 = mixed[0];
      h1 = mixed[1];
    }
    const out = new Uint8Array(8);
    writeBe32(out, 0, h0);
    writeBe32(out, 4, h1);
    return out;
  }

  /**
   * `LsSecGenerateKey`（0x6c84）：派生会话密钥的 Blowfish 状态。
   *
   * 原生把三份 8 字节素材依次放进 `ctx+0x18 / ctx+0x20 / ctx+0x28`
   * （第三份是 `ctx[0..7]` 的副本），对前 24 字节做哈希得到 8 字节密钥，
   * 再对它跑 `LsbfsInitialize` → 状态写进 `ctx+0x40`（即返回的这个实例）。
   */
  static generateKey(a: Uint8Array, b: Uint8Array, root: Uint8Array): NikonBlowfish {
    const material = new Uint8Array(24);
    material.set(a.subarray(0, 8), 0);
    material.set(b.subarray(0, 8), 8);
    material.set(root.subarray(0, 8), 16);
    const sessionKey = NikonLssHandshake.hash(material);
    const engine = new NikonBlowfish();
    engine.initKey(sessionKey);
    return engine;
  }

  /**
   * `FUN_00105fd4`：**CBC 解密**（原生要求长度是 8 的倍数）。
   *
   * `P(i) = D(C(i)) ^ C(i-1)`，首块的 `C(-1)` 就是 `iv`。
   */
  static decipher(engine: NikonBlowfish, iv: Uint8Array,
    data: Uint8Array): Uint8Array {
    const out = new Uint8Array(data.length);
    let previousL = readBe32(iv, 0);
    let previousR = readBe32(iv, 4);
    for (let offset = 0; offset + 8 <= data.length; offset += 8) {
      const cipherL = readBe32(data, offset);
      const cipherR = readBe32(data, offset + 4);
      const plain = engine.decipherWords(cipherL, cipherR);
      writeBe32(out, offset, (plain[0] ^ previousL) >>> 0);
      writeBe32(out, offset + 4, (plain[1] ^ previousR) >>> 0);
      previousL = cipherL;
      previousR = cipherR;
    }
    return out;
  }

  /** `FUN_00105e0c`：**CBC 加密**，与 {@link decipher} 对称。 */
  static encipher(engine: NikonBlowfish, iv: Uint8Array,
    data: Uint8Array): Uint8Array {
    const out = new Uint8Array(data.length);
    let previousL = readBe32(iv, 0);
    let previousR = readBe32(iv, 4);
    for (let offset = 0; offset + 8 <= data.length; offset += 8) {
      const plainL = (readBe32(data, offset) ^ previousL) >>> 0;
      const plainR = (readBe32(data, offset + 4) ^ previousR) >>> 0;
      const cipher = engine.encipherWords(plainL, plainR);
      writeBe32(out, offset, cipher[0]);
      writeBe32(out, offset + 4, cipher[1]);
      previousL = cipher[0];
      previousR = cipher[1];
    }
    return out;
  }
}
