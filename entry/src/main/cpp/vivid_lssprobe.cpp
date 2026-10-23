// vivid_lssprobe — drive Nikon's libLsSec-jni.so from inside the app sandbox.
//
// The device's SELinux policy blocks executing arbitrary files from the `sh`
// domain (u:r:sh:s0), so the standalone probe binary could not run. The app
// domain (u:r:app:s0) may dlopen its own files, so the same sequence runs here.
//
// This is a *diagnostic*: it feeds the library the real captured session values
// and lets the native code itself resolve the shared-root index, so we can read
// back the context bytes that GenerateKey consumes.

#include <napi/native_api.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>

namespace {

typedef int (*fn_init)(void *ctx, long seed);
typedef int (*fn_1st)(void *ctx, void *out);
typedef int (*fn_3rd)(void *ctx, const void *p2, const void *p3,
                      const void *p4, void *p5);
typedef int (*fn_genkey)(void *ctx, const void *a, const void *b);
// LsSecDecipher(ctx, in, out, len): the IV is ctx+0x10 and is NOT a parameter.
// Passing an extra argument makes the call write to whatever was meant as the
// input pointer -- which crashed the app when the destination was .rodata.
typedef int (*fn_dec)(void *ctx, const void *in, void *out, unsigned short len);

std::string toHex(const unsigned char *p, int n) {
  static const char *kHex = "0123456789abcdef";
  std::string s;
  s.reserve(static_cast<size_t>(n) * 2);
  for (int i = 0; i < n; i++) {
    s.push_back(kHex[(p[i] >> 4) & 0xf]);
    s.push_back(kHex[p[i] & 0xf]);
  }
  return s;
}

std::string toText(const unsigned char *p, int n) {
  std::string s;
  for (int i = 0; i < n; i++) {
    s.push_back((p[i] >= 0x20 && p[i] < 0x7f) ? static_cast<char>(p[i]) : '.');
  }
  return s;
}

// Real captured session values (2026-10-16 20:38:23).
const unsigned char OUR_NONCE[8]   = {0x42,0xa0,0xf7,0xfe,0x92,0x4f,0x7d,0x46};
const unsigned char CAM_DEV[8]     = {0xf5,0xd2,0x58,0x5d,0x54,0xa8,0xbd,0x80};
const unsigned char CAM_NONCE[8]   = {0x05,0x33,0x0d,0x15,0x40,0xa4,0xec,0x47};
const unsigned char CLIENT_ID[8]   = {0x49,0x20,0xf2,0xf2,0x9e,0x4a,0xf8,0xc8};
const unsigned char STAGE4_NONCE[8] = {0,0,0,0,0,0,0,0};
// stage 4 frame field c: 2d33303333353100 ("-303351", the BTC pairing code)
const unsigned char STAGE4_C[8] = {0x2d,0x33,0x30,0x33,0x33,0x35,0x31,0x00};

const unsigned char CIPHER[102] = {
  0x03,0xe1,0xef,0x81,0xa5,0xb5,0xdb,0x07,0xf3,0xdd,0xea,0x24,0xd8,0x37,0x83,0xa6,
  0xe5,0x9b,0x3a,0x7c,0x63,0x1b,0xa1,0x6c,0x7f,0xee,0x51,0x8d,0x73,0x4e,0xfc,0xf3,
  0x08,0x94,0x9c,0x35,0xf3,0x28,0xc4,0x28,0xed,0x22,0xe0,0xb9,0x67,0x1c,0x3f,0xf1,
  0x04,0x8c,0x88,0xeb,0x50,0x32,0xf5,0xa3,0x2d,0xd3,0xbe,0xdc,0x1e,0x54,0x86,0x75,
  0x48,0x87,0x02,0xe7,0x48,0xb0,0xb2,0x19,0x9f,0xaa,0x21,0x2a,0x71,0x1c,0x39,0x4c,
  0xe2,0xb9,0xa3,0xd1,0x66,0xc2,0x7a,0x74,0xbd,0x11,0xd0,0xf8,0xe2,0xe4,0xac,0x03,
  0xb6,0x00,0xec,0x01,0x00,0x00
};

std::string runProbe(const std::string &libPath) {
  std::string out;
  char line[512];

  void *h = dlopen(libPath.c_str(), RTLD_NOW);
  if (h == nullptr) {
    snprintf(line, sizeof(line), "dlopen failed: %s\n", dlerror());
    return std::string(line);
  }
  out += "dlopen ok: " + libPath + "\n";

  fn_init   p_init = reinterpret_cast<fn_init>(dlsym(h, "LsSecInit"));
  fn_1st    p_1st  = reinterpret_cast<fn_1st>(dlsym(h, "LsSec1stStage"));
  fn_3rd    p_3rd  = reinterpret_cast<fn_3rd>(dlsym(h, "LsSec3rdStage"));
  fn_genkey p_gen  = reinterpret_cast<fn_genkey>(dlsym(h, "LsSecGenerateKey"));
  fn_dec    p_dec  = reinterpret_cast<fn_dec>(dlsym(h, "LsSecDecipher"));
  if (p_init == nullptr || p_1st == nullptr || p_3rd == nullptr ||
      p_gen == nullptr || p_dec == nullptr) {
    out += "dlsym failed\n";
    return out;
  }

  static unsigned char ctx[0x3000] __attribute__((aligned(64)));
  memset(ctx, 0, sizeof(ctx));

  int r = p_init(ctx, 12345);
  snprintf(line, sizeof(line), "LsSecInit        = %d\n", r);
  out += line;

  unsigned char ourNonce[8];
  memset(ourNonce, 0, sizeof(ourNonce));
  r = p_1st(ctx, ourNonce);
  snprintf(line, sizeof(line), "LsSec1stStage    = %d  nonce=%s\n", r,
           toHex(ourNonce, 8).c_str());
  out += line;

  // The parameter mapping was established by a 343-combination sweep that is no
  // longer needed (it produced one match, and 27 KB of log output destabilised
  // the app): param_2 = stage-2 field 2, param_4 = stage-2 field 3. Note this is
  // the opposite of what the smali field names (`b`/`c`) suggested.
  //
  //   LsSec3rdStage(ctx, 05330d1540a4ec47, 42a0f7fe924f7d46, f5d2585d54a8bd80)
  //     -> 0, index 4, ctx[0..7] = 04330d1542a0f7fe, payload 6de3990501fe6876
  memset(ctx, 0, sizeof(ctx));
  unsigned char genNonce[8];
  p_init(ctx, 12345);
  p_1st(ctx, genNonce);

  unsigned char out24[24];
  memset(out24, 0, sizeof(out24));
  r = p_3rd(ctx, CAM_NONCE, OUR_NONCE, CAM_DEV, out24);
  snprintf(line, sizeof(line), "LsSec3rdStage    = %d  index=%d\n", r,
           static_cast<int>(ctx[0]));
  out += line;
  out += "  ctx[0..7]      = " + toHex(ctx, 8) + "\n";
  out += "  payload        = " + toHex(out24, 8) + "\n";
  if (r != 0) {
    out += "stage3 failed\n";
    return out;
  }

  r = p_gen(ctx, STAGE4_NONCE, CLIENT_ID);
  snprintf(line, sizeof(line), "LsSecGenerateKey = %d\n", r);
  out += line;
  out += "  ctx+0x08 hash  = " + toHex(ctx + 0x08, 8) + "\n";

  // GenerateKey(a, b): `a` is the stage-4 response field b (confirmed: all
  // zeros), but `b` is `this.f11732g` in ConnectBluetoothAction and its origin
  // is not visible from the smali. Sweep every 8-byte value the capture offers
  // and report only the combinations that decrypt to a believable SSID.
  //
  // The 0x2004 block is a 1-byte header followed by 96 contiguous ciphertext
  // bytes (32 + 64). CBC chains across the whole run, so it must be decrypted
  // in ONE call -- splitting it restarts the IV at the second field and
  // produces garbage.
  struct Cand { const char *name; const unsigned char *value; };
  const unsigned char ZERO8[8] = {0,0,0,0,0,0,0,0};
  const unsigned char STAGE3_PAYLOAD[8] = {0x6d,0xe3,0x99,0x05,0x01,0xfe,0x68,0x76};
  // Stage-2 proved the field mapping: `k.b()` is the SECOND 8-byte group of the
  // frame and `k.c()` the first. Applied to the stage-4 frame
  // `04 0000000000000000 2d33303333353100`, generateKey's first argument
  // `kVar2.b()` is therefore 2d33303333353100, not the all-zero group.
  const unsigned char STAGE4_FIELD2[8] = {0x2d,0x33,0x30,0x33,0x33,0x35,0x31,0x00};
  const Cand cands[] = {
    {"zero",       ZERO8},
    {"stage4f2",   STAGE4_FIELD2},
    {"ourNonce",   OUR_NONCE},
    {"stage2b",    CAM_NONCE},
    {"stage2c",    CAM_DEV},
    {"clientId",   CLIENT_ID},
    {"stage3pay",  STAGE3_PAYLOAD},
  };
  const int kCount = static_cast<int>(sizeof(cands) / sizeof(cands[0]));

  out += "\n--- GenerateKey material sweep (a x b), 96-byte CBC ---\n";
  int readable = 0;
  for (int ia = 0; ia < kCount; ia++) {
    for (int ib = 0; ib < kCount; ib++) {
      static unsigned char sctx[0x3000] __attribute__((aligned(64)));
      memset(sctx, 0, sizeof(sctx));
      unsigned char dummy[8];
      unsigned char tmp24[24];
      p_init(sctx, 12345);
      p_1st(sctx, dummy);
      if (p_3rd(sctx, CAM_NONCE, OUR_NONCE, CAM_DEV, tmp24) != 0) {
        continue;
      }
      if (p_gen(sctx, cands[ia].value, cands[ib].value) != 0) {
        continue;
      }
      unsigned char t[96];
      memset(t, 0, sizeof(t));
      if (p_dec(sctx, CIPHER + 1, t, 96) != 0) {
        continue;
      }
      // A real SSID starts with "Z_5_" and the block is NUL-padded.
      if (t[0] == 'Z' && t[1] == '_' && t[2] == '5' && t[3] == '_') {
        readable++;
        snprintf(line, sizeof(line), "  *** SSID MATCH a=%s b=%s ***\n",
                 cands[ia].name, cands[ib].name);
        out += line;
        out += "    continuous 96  = " + toText(t, 96) + "\n";
        // The tail after the SSID still looks encrypted, so try the two payload
        // fields as independent CBC runs (each starting from IV = ctx+0x10).
        unsigned char f32[32];
        unsigned char f64[64];
        memset(f32, 0, sizeof(f32));
        memset(f64, 0, sizeof(f64));
        p_dec(sctx, CIPHER + 1, f32, 32);
        p_dec(sctx, CIPHER + 33, f64, 64);
        out += "    split 32       = " + toText(f32, 32) + "\n";
        out += "    split 64       = " + toText(f64, 64) + "\n";
      }
    }
  }
  snprintf(line, sizeof(line), "  sweep done, %d SSID match(es)\n", readable);
  out += line;

  unsigned char plain[96];
  memset(plain, 0, sizeof(plain));
  int rp = p_dec(ctx, CIPHER + 1, plain, 96);
  snprintf(line, sizeof(line), "LsSecDecipher    = %d\n", rp);
  out += line;
  out += "  text           = " + toText(plain, 96) + "\n";
  return out;
}

}  // namespace

static napi_value ProbeLss(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  char path[1024] = {0};
  size_t pathLen = 0;
  if (argc < 1 || napi_get_value_string_utf8(env, argv[0], path, sizeof(path) - 1,
                                             &pathLen) != napi_ok) {
    std::string msg = "probe: no library path supplied\n";
    napi_value result = nullptr;
    napi_create_string_utf8(env, msg.c_str(), msg.size(), &result);
    return result;
  }

  std::string report = runProbe(std::string(path));
  napi_value result = nullptr;
  napi_create_string_utf8(env, report.c_str(), report.size(), &result);
  return result;
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
    {"probeLss", nullptr, ProbeLss, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

static napi_module g_lssProbeModule = {
  1,
  0,
  nullptr,
  Init,
  "vivid_lssprobe",
  nullptr,
  nullptr,
};

extern "C" __attribute__((constructor)) void RegisterLssProbeModule(void) {
  napi_module_register(&g_lssProbeModule);
}
