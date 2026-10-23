// Included inside vivid_gpu's anonymous namespace. EGL objects are owned by
// one dedicated thread. NAPI workers only wait for that thread's completion.
#ifndef GL_RGBA16F
#define GL_RGBA16F 0x881A
#endif
#ifndef EGL_OPENGL_ES3_BIT
#define EGL_OPENGL_ES3_BIT 0x00000040
#endif
class RenderThread {
    std::mutex mutex;
    std::condition_variable wake;
    std::queue<std::function<void()>> tasks;
    bool stopping = false;
    std::thread thread;
public:
    RenderThread() : thread([this] {
        for (;;) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lock(mutex);
                wake.wait(lock, [this] { return stopping || !tasks.empty(); });
                if (stopping && tasks.empty()) return;
                task = std::move(tasks.front()); tasks.pop();
            }
            task();
        }
    }) {}
    ~RenderThread() {
        { std::lock_guard<std::mutex> lock(mutex); stopping = true; }
        wake.notify_one(); thread.join();
    }
    void call(std::function<void()> fn) {
        auto job = std::make_shared<std::packaged_task<void()>>(std::move(fn));
        auto done = job->get_future();
        { std::lock_guard<std::mutex> lock(mutex); tasks.push([job] { (*job)(); }); }
        wake.notify_one(); done.get();
    }
};

struct StackWork {
    napi_env env = nullptr;
    napi_deferred deferred = nullptr;
    napi_async_work async = nullptr;
    std::string key, surface, error;
    uint32_t width = 0, height = 0, sourceVersion = 0;
    uint32_t outputWidth = 0, outputHeight = 0;
    float uvMatrix[9] = {1,0,0,0,1,0,0,0,1};
    std::vector<uint8_t> source, output;
    std::vector<RenderWork> passes;
    // Optional depth-of-field stage. It runs after the colour/mask passes and
    // before the output geometry matrix, exactly where the CPU pipeline runs
    // bokeh, so crop/rotate still apply to the finished virtual-lens frame.
    bool bokehEnabled = false;
    bool bokehPlateOnly = false;
    std::vector<uint8_t> bokehDepth;
    uint32_t bokehDepthWidth = 0, bokehDepthHeight = 0;
    // Export tiles receive one plate rendered from the whole frame, so tile
    // boundaries cannot show a different blur from their neighbours.
    std::vector<uint8_t> bokehPlate;
    uint32_t bokehPlateWidth = 0, bokehPlateHeight = 0;
    float bokehParams[8] = {1.4f, 0.55f, 0.35f, 7.0f, 0.55f, 1.0f, 0.0f, 0.45f};
    // Maps a tile-local UV to the whole-frame UV used by the shared depth and
    // plate textures. Whole-frame preview/export leave the identity values.
    float bokehUvOffset[2] = {0.0f, 0.0f};
    float bokehUvScale[2] = {1.0f, 1.0f};
    bool release = false;
    bool clear = false;
};

static bool stringValue(napi_env env, napi_value value, std::string& out) {
    size_t size = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok) return false;
    std::vector<char> chars(size + 1);
    if (napi_get_value_string_utf8(env, value, chars.data(), chars.size(), &size) != napi_ok) return false;
    out.assign(chars.data(), size); return true;
}

static bool retainAsset(napi_env env, napi_value obj, const char* name,
    RenderWork& work, size_t index, size_t expected = 0, bool optional = false) {
    napi_value value;
    if (!getNamed(env, obj, name, &value)) return optional;
    void* data = nullptr; size_t length = 0;
    if (napi_get_arraybuffer_info(env, value, &data, &length) != napi_ok) return optional;
    if (!length || (expected && length != expected)) return false;
    std::string field = std::string(name) + "Id";
    double id = 0;
    getNumber(env, obj, field.c_str(), &id);
    if (!std::isfinite(id) || id < 0 || id > UINT32_MAX || std::floor(id) != id) return false;
    work.assetIds[index] = static_cast<uint32_t>(id);
    static VividBufferCache cache;
    work.assets[index] = cache.obtain(work.assetIds[index], static_cast<uint8_t*>(data), length);
    return true;
}

static bool parseBokehOptions(napi_env env, napi_value obj, StackWork& work) {
    napi_value value = nullptr;
    if (!getNamed(env, obj, "enabled", &value)) return true;
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok || type == napi_undefined || type == napi_null) return true;
    bool enabled = false;
    if (napi_get_value_bool(env, value, &enabled) != napi_ok || !enabled) return true;
    double number = 0;
    if (!getNumber(env, obj, "depthWidth", &number) || !std::isfinite(number) ||
        number < 1 || number > 4096) return true;
    work.bokehDepthWidth = static_cast<uint32_t>(number);
    if (!getNumber(env, obj, "depthHeight", &number) || !std::isfinite(number) ||
        number < 1 || number > 4096) return true;
    work.bokehDepthHeight = static_cast<uint32_t>(number);
    if (!copyNamedBuffer(env, obj, "depth", work.bokehDepth,
        static_cast<size_t>(work.bokehDepthWidth) * work.bokehDepthHeight)) return true;
    // A missing depth map must not make the whole colour stack fail: it simply
    // means the CPU fallback (centre-focus approximation) still owns this frame.
    work.bokehEnabled = true;
    getBool(env, obj, "plateOnly", &work.bokehPlateOnly);
    copyNumberArrayOptional(env, obj, "params", work.bokehParams, 8);
    copyNumberArrayOptional(env, obj, "uvOffset", work.bokehUvOffset, 2);
    copyNumberArrayOptional(env, obj, "uvScale", work.bokehUvScale, 2);
    if (getNumber(env, obj, "plateWidth", &number) && std::isfinite(number) &&
        number >= 1 && number <= 4096) work.bokehPlateWidth = static_cast<uint32_t>(number);
    if (getNumber(env, obj, "plateHeight", &number) && std::isfinite(number) &&
        number >= 1 && number <= 4096) work.bokehPlateHeight = static_cast<uint32_t>(number);
    if (work.bokehPlateWidth > 0 && work.bokehPlateHeight > 0) {
        const size_t bytes = static_cast<size_t>(work.bokehPlateWidth) * work.bokehPlateHeight * 4;
        if (!copyNamedBuffer(env, obj, "plate", work.bokehPlate, bytes)) {
            work.bokehPlate.clear();
            work.bokehPlateWidth = work.bokehPlateHeight = 0;
        }
    }
    return true;
}

static bool parsePass(napi_env env, napi_value obj, RenderWork& work) {
    napi_value matrix;
    void* data = nullptr; size_t length = 0;
    if (!getNamed(env, obj, "matrix", &matrix) ||
        napi_get_arraybuffer_info(env, matrix, &data, &length) != napi_ok || length != sizeof(work.matrix)) return false;
    std::memcpy(work.matrix, data, length);
    if (!retainAsset(env, obj, "toneCurve", work, 0, 1025 * 4) ||
        !retainAsset(env, obj, "redCurve", work, 1, 1025 * 4) ||
        !retainAsset(env, obj, "greenCurve", work, 2, 1025 * 4) ||
        !retainAsset(env, obj, "blueCurve", work, 3, 1025 * 4)) return false;
#define ARRAY(name, count) if (!copyNumberArrayOptional(env, obj, #name, work.name, count)) return false
    ARRAY(mixHue, 8); ARRAY(mixSaturation, 8); ARRAY(mixLuminance, 8);
    ARRAY(tonal, 4); ARRAY(whiteBalanceGain, 3);
    ARRAY(vignette, 5); ARRAY(grain, 3);
    ARRAY(denoise, 4);
    ARRAY(lutDomainMin, 3); ARRAY(lutDomainScale, 3);
    ARRAY(calibrationHue, 3); ARRAY(calibrationSaturation, 3);
    ARRAY(gradingShadowsTarget, 3); ARRAY(gradingMidtonesTarget, 3);
    ARRAY(gradingHighlightsTarget, 3); ARRAY(gradingGlobalTarget, 3);
#undef ARRAY
    double number = 0;
#define NUMBER(name) if (getNumber(env, obj, #name, &number)) work.name = static_cast<decltype(work.name)>(number)
    NUMBER(opacity); NUMBER(blendMode); NUMBER(lutIntensity); NUMBER(lutSize);
    NUMBER(maskWidth); NUMBER(maskHeight); NUMBER(maskOpacity);
    NUMBER(vibrance);
    NUMBER(exposureGain);
    NUMBER(gradingShadowsSaturation); NUMBER(gradingShadowsLuminance);
    NUMBER(gradingMidtonesSaturation); NUMBER(gradingMidtonesLuminance);
    NUMBER(gradingHighlightsSaturation); NUMBER(gradingHighlightsLuminance);
    NUMBER(gradingGlobalSaturation); NUMBER(gradingGlobalLuminance);
    NUMBER(gradingBalance); NUMBER(gradingBlending);
#undef NUMBER
    if (!std::isfinite(work.exposureGain) || work.exposureGain <= 0.0f) return false;
    for (float v : work.denoise) if (!std::isfinite(v) || v < 0 || v > 1) return false;
    getBool(env, obj, "lutEnabled", &work.lutEnabled);
    getBool(env, obj, "maskEnabled", &work.maskEnabled);
    getBool(env, obj, "gradingEnabled", &work.gradingEnabled);
    getBool(env, obj, "whiteBalanceEnabled", &work.whiteBalanceEnabled);
    getBool(env, obj, "mixerEnabled", &work.mixerEnabled);
    if (!retainAsset(env, obj, "lut", work, 4, 0, true) ||
        !retainAsset(env, obj, "mask", work, 5, 0, true)) return false;
    // 65 is the largest standard .cube size. The atlas is
    // (size*size) x size = 4225x65 for 65^3; render() below compares that width
    // with the real GL_MAX_TEXTURE_SIZE and rejects with "LUT texture limit
    // exceeded" on a 4096-limit device, which then falls back to CPU. The
    // ArkTS side packs RGBA16F (4 half-float channels, 8 bytes per texel) so
    // extended-range values are not clipped before interpolation.
    if (work.lutEnabled && (work.lutSize < 2 || work.lutSize > 65 ||
        !work.assets[4] || work.assets[4]->size() != static_cast<size_t>(work.lutSize) * work.lutSize * work.lutSize * 8)) return false;
    if (work.maskEnabled && (work.maskWidth == 0 || work.maskHeight == 0 ||
        !work.assets[5] || work.assets[5]->size() != static_cast<size_t>(work.maskWidth) * work.maskHeight)) return false;
    return true;
}

struct CachedTexture {
    GLuint id = 0;
    uint64_t hash = 0;
    uint32_t assetId = 0;
    uint32_t width = 0, height = 0;
    void update(GLenum format, uint32_t w, uint32_t h, const std::vector<uint8_t>& bytes, uint32_t revision = 0) {
        if (id && revision && revision == assetId && width == w && height == h) return;
        uint64_t next = 1469598103934665603ULL;
        if (!revision) for (uint8_t value : bytes) next = (next ^ value) * 1099511628211ULL;
        if (id && !revision && !assetId && next == hash && width == w && height == h) return;
        if (id) glDeleteTextures(1, &id);
        id = uploadTexture(format, w, h, bytes.data()); hash = next; assetId = revision; width = w; height = h;
    }
    void clear() { if (id) glDeleteTextures(1, &id); id = 0; }
};

struct PassTextures { CachedTexture curve[4], lut, mask; };

/** Link a standalone vertex/fragment pair (the bokeh stage has its own
 * uniforms and cannot reuse the fixed colour-pass program). */
static GLuint linkShaderPair(const char* vertexSource, const char* fragmentSource,
    std::string& error) {
    const GLuint vertex = compileShader(GL_VERTEX_SHADER, vertexSource, error);
    if (vertex == 0) return 0;
    const GLuint fragment = compileShader(GL_FRAGMENT_SHADER, fragmentSource, error);
    if (fragment == 0) { glDeleteShader(vertex); return 0; }
    const GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glBindAttribLocation(program, 0, "aPosition");
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint ok = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (ok == GL_TRUE) return program;
    error = "bokeh shader link failed";
    glDeleteProgram(program);
    return 0;
}

/** Small separable box blur for the quarter-res highlight prominence mask. */
static void boxBlurMask(std::vector<float>& data, int width, int height, int radius) {
    if (radius <= 0 || width <= 0 || height <= 0) return;
    std::vector<float> temp(data.size(), 0.0f);
    const int diameter = radius * 2 + 1;
    for (int y = 0; y < height; ++y) {
        const int row = y * width;
        float sum = 0.0f;
        for (int x = -radius; x <= radius; ++x) sum += data[row + std::max(0, std::min(width - 1, x))];
        for (int x = 0; x < width; ++x) {
            temp[row + x] = sum / diameter;
            const int add = std::max(0, std::min(width - 1, x + radius + 1));
            const int drop = std::max(0, std::min(width - 1, x - radius));
            sum += data[row + add] - data[row + drop];
        }
    }
    for (int x = 0; x < width; ++x) {
        float sum = 0.0f;
        for (int y = -radius; y <= radius; ++y) sum += temp[std::max(0, std::min(height - 1, y)) * width + x];
        for (int y = 0; y < height; ++y) {
            data[y * width + x] = sum / diameter;
            const int add = std::max(0, std::min(height - 1, y + radius + 1));
            const int drop = std::max(0, std::min(height - 1, y - radius));
            sum += temp[add * width + x] - temp[drop * width + x];
        }
    }
}

class GpuSession {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLConfig config = nullptr;
    EGLContext context = EGL_NO_CONTEXT;
    bool es3Context = false;
    EGLSurface pbuffer = EGL_NO_SURFACE, windowSurface = EGL_NO_SURFACE;
    OHNativeWindow* window = nullptr;
    std::string surfaceId;
    GLuint program = 0, presentProgram = 0, source = 0, output[2] = {}, framebuffer = 0;
    // Dedicated offscreen stage for the virtual lens. These are allocated only
    // after bokeh is enabled, so the ordinary colour pipeline pays no extra
    // VRAM for a feature it does not use.
    GLuint bokehProgram = 0, bokehCompositeProgram = 0;
    GLuint bokehMaskProgram = 0, bokehPointProgram = 0;
    GLuint bokehPointBuffer = 0, bokehMaskTexture = 0;
    GLuint bokehSourceTexture = 0, bokehPlateTexture = 0;
    GLuint bokehDepthTexture = 0, bokehExternalPlateTexture = 0;
    uint32_t bokehWorkWidth = 0, bokehWorkHeight = 0;
    uint32_t bokehSourceWidth = 0, bokehSourceHeight = 0;
    uint32_t bokehMaskWidth = 0, bokehMaskHeight = 0;
    // One shared noise texture, bounded to one frame rather than one per
    // layer. Amount/roughness/colour/profile changes only update uniforms.
    GLuint grainTexture = 0;
    GLuint denoiseTexture = 0;
    float denoiseCached[4] = {};
    bool denoiseValid = false;
    uint32_t grainWidth = 0, grainHeight = 0;
    float grainSize = -1.0f;
    uint32_t width = 0, height = 0, sourceVersion = 0;
    uint32_t pbWidth = 0, pbHeight = 0;
    GLint limit = 0;
    std::vector<PassTextures> textures;

    void current() {
        eglBindAPI(EGL_OPENGL_ES_API);
        if (!eglMakeCurrent(display, pbuffer, pbuffer, context)) throw std::runtime_error("eglMakeCurrent failed: " + std::to_string(eglGetError()));
    }
    void closeWindow() {
        if (windowSurface != EGL_NO_SURFACE) eglDestroySurface(display, windowSurface);
        windowSurface = EGL_NO_SURFACE;
        if (window) OH_NativeWindow_DestroyNativeWindow(window);
        window = nullptr; surfaceId.clear();
    }
    GLuint makePresent(std::string& error) {
        GLuint vs = compileShader(GL_VERTEX_SHADER,
            "attribute vec2 aPosition; uniform float uFlipY; varying vec2 uv;"
            "void main(){uv=vec2(aPosition.x*.5+.5,mix(aPosition.y*.5+.5,.5-aPosition.y*.5,uFlipY));gl_Position=vec4(aPosition,0.,1.);}", error);
        if (!vs) return 0;
        GLuint fs = compileShader(GL_FRAGMENT_SHADER,
            "precision highp float; varying vec2 uv; uniform sampler2D tex; uniform mat3 uUvMatrix;"
            "void main(){gl_FragColor=texture2D(tex,(uUvMatrix*vec3(uv,1.)).xy);}", error);
        if (!fs) { glDeleteShader(vs); return 0; }
        GLuint p = glCreateProgram(); glAttachShader(p, vs); glAttachShader(p, fs);
        glBindAttribLocation(p, 0, "aPosition"); glLinkProgram(p);
        glDeleteShader(vs); glDeleteShader(fs);
        GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
        if (!ok) { glDeleteProgram(p); error = "present shader link failed"; return 0; } return p;
    }

    /**
     * Bokeh is a full-frame spatial stage, not a colour pass. It gets its own
     * two programs and offscreen plate:
     *   1. `bokehProgram` renders a bounded-resolution background/highlight
     *      plate from the colour result and the AI depth map;
     *   2. `bokehCompositeProgram` mixes that plate back into the full-res
     *      colour result using the same depth map, so the in-focus subject
     *      keeps its original pixels.
     * The plate is bounded (long edge <= 1200) for the same reason as the CPU
     * implementation: a defocused background is low frequency. The composite
     * stays full-res, which is what preserves the subject edge.
     */
    bool makeBokehPrograms(std::string& error) {
        if (bokehProgram != 0 && bokehCompositeProgram != 0 &&
            bokehMaskProgram != 0 && bokehPointProgram != 0) return true;
        const std::string vertexPrefix = es3Context
            ? "#version 300 es\n#define attribute in\n#define varying out\n" : "";
        const std::string fragmentPrefix = es3Context
            ? "#version 300 es\nprecision highp float;\n#define varying in\n"
              "#define texture2D texture\n#define gl_FragColor fragColor\nout vec4 fragColor;\n"
            : "precision highp float;\n";
        const char* vertexSource =
            "attribute vec2 aPosition; varying vec2 uv;"
            "void main(){uv=aPosition*.5+.5;gl_Position=vec4(aPosition,0.,1.);}";
        const char* plateSource =
            "varying vec2 uv;"
            "uniform sampler2D uImage; uniform sampler2D uDepth;"
            "uniform vec2 uTexel;"
            "uniform float uAperture; uniform float uBlur; uniform float uBokeh;"
            "uniform float uDensity; uniform float uSize; uniform float uSpherical;"
            "uniform float uFocus; uniform int uShape;"
            "float polygonRadius(float ang, float sides){"
            "if(sides<0.5)return 1.0;"
            "float stepAng=6.28318530718/sides;"
            "float local=mod(ang,stepAng)-0.5*stepAng;"
            "return cos(3.14159265359/sides)/max(0.25,cos(local));}"
            "void main(){"
            "vec4 base=texture2D(uImage,uv);"
            "float depth=texture2D(uDepth,uv).r;"
            "float delta=abs(depth-uFocus);"
            "float radiusScale=max(1.0, max(1.0/uTexel.x,1.0/uTexel.y)/1000.0);"
            "float apertureFactor=pow(1.5/max(uAperture,1.2),0.40);"
            "float apertureGain=clamp(pow(8.0/max(uAperture,1.2),0.42)/2.3,0.35,2.5);"
            "float coc=clamp(delta*(1.0+0.70*1.6)*clamp(uBlur,0.0,1.0)*apertureGain,0.0,1.0);"
            "float baseRadius=(2.0+34.0*clamp(uBlur,0.0,1.0)*apertureFactor)*radiusScale*uSize;"
            "float radius=baseRadius*(0.25+1.05*coc);"
            "radius=clamp(radius,0.0,64.0);"
            "if(radius<0.9){gl_FragColor=vec4(base.rgb,1.0);return;}"
            "vec3 sum=base.rgb; float weightSum=1.0;"
            "const int TAPS=64;"
            "for(int i=0;i<TAPS;i++){"
            "float fi=float(i);"
            "float ang=fi*2.39996323;"
            "float ring=sqrt((fi+0.5)/float(TAPS));"
            "float shaped=1.0;"
            "if(uShape>0){float edge=polygonRadius(ang,float(uShape));"
            "shaped=1.0-smoothstep(edge-0.035,edge+0.035,ring);}"
            "float radial=1.0+uSpherical*0.18*cos(ang*2.0);"
            "vec2 offset=vec2(cos(ang),sin(ang))*radius*ring*radial*uTexel;"
            "vec2 sampleUv=clamp(uv+offset,vec2(0.0),vec2(1.0));"
            "vec3 colour=texture2D(uImage,sampleUv).rgb;"
            "float sampleDepth=texture2D(uDepth,sampleUv).r;"
            "float sameDepth=1.0-smoothstep(0.12,0.42,abs(sampleDepth-depth));"
            "float w=shaped*(0.55+0.45*sameDepth)*(0.55+0.45*clamp(uDensity,0.0,1.0));"
            "sum+=colour*w; weightSum+=w;}"
            "vec3 result=sum/weightSum;"
            "float lum=max(base.r,max(base.g,base.b));"
            "float highlight=smoothstep(0.66,0.96,lum)*clamp(uBokeh,0.0,1.0);"
            "if(highlight>0.001){"
            "vec3 halo=vec3(0.0); float haloWeight=0.0;"
            "for(int j=0;j<12;j++){"
            "float ang=float(j)*0.5235987756;"
            "vec2 offset=vec2(cos(ang),sin(ang))*radius*0.62*uTexel;"
            "vec3 hc=texture2D(uImage,clamp(uv+offset,vec2(0.0),vec2(1.0))).rgb;"
            "float hl=max(hc.r,max(hc.g,hc.b));"
            "float m=smoothstep(0.70,0.98,hl);"
            "halo+=hc*m; haloWeight+=m;}"
            "if(haloWeight>0.001) result=mix(result,halo/haloWeight,highlight*0.45);}"
            "gl_FragColor=vec4(clamp(result,0.0,1.0),1.0);}";
        const char* compositeSource =
            "varying vec2 uv;"
            "uniform sampler2D uImage; uniform sampler2D uPlate; uniform sampler2D uDepth;"
            "uniform float uBlur; uniform float uFocus; uniform float uAperture;"
            "uniform vec2 uUvOffset; uniform vec2 uUvScale;"
            "void main(){"
            "vec4 sharp=texture2D(uImage,uv);"
            "vec2 frameUv=uv*uUvScale+uUvOffset;"
            "vec4 plate=texture2D(uPlate,frameUv);"
            "float depth=texture2D(uDepth,frameUv).r;"
            "float delta=abs(depth-uFocus);"
            "float apertureGain=clamp(pow(8.0/max(uAperture,1.2),0.42)/2.3,0.35,2.5);"
            "float coc=clamp(delta*(1.0+0.70*1.6)*clamp(uBlur,0.0,1.0)*apertureGain,0.0,1.0);"
            "float sharpWeight=smoothstep(0.0,1.0,clamp(1.0-coc*2.6,0.0,1.0));"
            "gl_FragColor=vec4(mix(plate.rgb,sharp.rgb,sharpWeight),sharp.a);}";
        const char* maskSource =
            "varying vec2 uv; uniform sampler2D uImage;"
            "void main(){vec3 c=texture2D(uImage,uv).rgb;"
            "gl_FragColor=vec4(max(c.r,max(c.g,c.b)),0.0,0.0,1.0);}";
        const char* pointVertexSource =
            "attribute vec2 aPosition; attribute float aRadius; attribute float aIntensity;"
            "varying float vIntensity;"
            "void main(){gl_Position=vec4(aPosition*2.0-1.0,0.0,1.0);"
            "gl_PointSize=max(2.0,aRadius*2.0);vIntensity=aIntensity;}";
        const char* pointSource =
            "varying float vIntensity;"
            "uniform int uShape; uniform float uSpherical;"
            "float polygonRadius(float ang,float sides){if(sides<0.5)return 1.0;"
            "float stepAng=6.28318530718/sides;float local=mod(ang,stepAng)-0.5*stepAng;"
            "return cos(3.14159265359/sides)/max(0.25,cos(local));}"
            "void main(){vec2 p=gl_PointCoord*2.0-1.0;float r=length(p);"
            "if(r>1.0)discard;"
            "float ang=atan(p.y,p.x);float edge=polygonRadius(ang,float(uShape));"
            "edge*=1.0+uSpherical*0.12*cos(ang*2.0);"
            "if(r>edge)discard;"
            "float soft=1.0-smoothstep(0.70,1.0,r/max(edge,0.001));"
            "float rim=smoothstep(0.52,0.96,r/max(edge,0.001));"
            "vec3 tint=mix(vec3(1.0,0.93,0.84),vec3(0.84,0.93,1.0),"
            "clamp(0.5+uSpherical*0.5,0.0,1.0));"
            "gl_FragColor=vec4(tint,vIntensity*soft*(0.30+0.70*rim));}";
        const std::string vertexText = vertexPrefix + vertexSource;
        const std::string plateText = fragmentPrefix + plateSource;
        const std::string compositeText = fragmentPrefix + compositeSource;
        const std::string maskText = fragmentPrefix + maskSource;
        const std::string pointVertexText = vertexPrefix + pointVertexSource;
        const std::string pointText = fragmentPrefix + pointSource;
        bokehProgram = linkShaderPair(vertexText.c_str(), plateText.c_str(), error);
        if (bokehProgram == 0) return false;
        bokehCompositeProgram = linkShaderPair(vertexText.c_str(), compositeText.c_str(), error);
        if (bokehCompositeProgram == 0) return false;
        bokehMaskProgram = linkShaderPair(vertexText.c_str(), maskText.c_str(), error);
        if (bokehMaskProgram == 0) return false;
        bokehPointProgram = linkShaderPair(pointVertexText.c_str(), pointText.c_str(), error);
        if (bokehPointProgram == 0) return false;
        return true;
    }

    void drawFullscreen() {
        const GLfloat vertices[] = {-1.0f, -1.0f, 3.0f, -1.0f, -1.0f, 3.0f};
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
        glEnableVertexAttribArray(0);
        glDrawArrays(GL_TRIANGLES, 0, 3);
    }

    GLuint bokehWorkTexture(uint32_t width, uint32_t height, GLuint& texture,
        uint32_t& cachedWidth, uint32_t& cachedHeight) {
        if (texture == 0 || cachedWidth != width || cachedHeight != height) {
            if (texture != 0) glDeleteTextures(1, &texture);
            texture = uploadTexture(GL_RGBA, width, height, nullptr);
            cachedWidth = width; cachedHeight = height;
        }
        return texture;
    }

    /** Add the aperture-shaped highlight discs after the background plate.
     *  A tiny luminance mask is rendered on the GPU, read back once, and used
     *  to build point sprites. The expensive part (the discs) stays on the GPU;
     *  the CPU only chooses local maxima, exactly like a bloom peak pass. */
    void addBokehHighlights(StackWork& job, GLuint sourceTexture,
        uint32_t workWidth, uint32_t workHeight, GLuint plateTexture) {
        const float bokeh = job.bokehParams[2];
        if (bokeh <= 0.001f) return;
        const uint32_t maskWidth = std::max(1u, workWidth / 4);
        const uint32_t maskHeight = std::max(1u, workHeight / 4);
        if (bokehMaskTexture == 0 || bokehMaskWidth != maskWidth || bokehMaskHeight != maskHeight) {
            if (bokehMaskTexture != 0) glDeleteTextures(1, &bokehMaskTexture);
            bokehMaskTexture = uploadTexture(GL_RGBA, maskWidth, maskHeight, nullptr);
            bokehMaskWidth = maskWidth; bokehMaskHeight = maskHeight;
        }
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
            bokehMaskTexture, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return;
        glViewport(0, 0, static_cast<GLsizei>(maskWidth), static_cast<GLsizei>(maskHeight));
        glUseProgram(bokehMaskProgram);
        bindTexture(bokehMaskProgram, "uImage", 0, sourceTexture);
        drawFullscreen();
        std::vector<uint8_t> mask(static_cast<size_t>(maskWidth) * maskHeight * 4);
        glReadPixels(0, 0, static_cast<GLsizei>(maskWidth), static_cast<GLsizei>(maskHeight),
            GL_RGBA, GL_UNSIGNED_BYTE, mask.data());

        const float focus = std::max(0.0f, std::min(0.98f, job.bokehParams[7]));
        const float aperture = std::max(1.2f, job.bokehParams[0]);
        const float blur = std::max(0.0f, std::min(1.0f, job.bokehParams[1]));
        const float size = std::max(0.05f, std::min(2.0f, job.bokehParams[5]));
        const float radiusScale = std::max(1.0f,
            static_cast<float>(std::max(workWidth, workHeight)) / 1000.0f);
        const float apertureFactor = std::pow(1.4f / aperture, 0.45f);
        const float apertureGain = std::max(0.35f, std::min(2.5f,
            std::pow(8.0f / aperture, 0.42f) / 2.3f));
        const float discBase = (2.5f + 26.0f * std::max(bokeh, 0.12f)) *
            std::max(1.0f, radiusScale) * size;
        const float density = std::max(0.0f, std::min(1.0f, job.bokehParams[4]));
        std::vector<float> luminance(static_cast<size_t>(maskWidth) * maskHeight, 0.0f);
        for (size_t index = 0; index < luminance.size(); ++index) {
            luminance[index] = mask[index * 4] / 255.0f;
        }
        std::vector<float> localMean = luminance;
        boxBlurMask(localMean, static_cast<int>(maskWidth), static_cast<int>(maskHeight),
            std::max(2, static_cast<int>(std::lround(4.2f * radiusScale * 0.25f))));
        struct Peak {
            float weight;
            float x;
            float y;
            float coc;
        };
        std::vector<Peak> candidates;
        candidates.reserve(1024);
        const int neighbours[8][2] = {{-1,-1},{0,-1},{1,-1},{-1,0},{1,0},{-1,1},{0,1},{1,1}};
        for (uint32_t y = 1; y + 1 < maskHeight; ++y) {
            for (uint32_t x = 1; x + 1 < maskWidth; ++x) {
                const size_t index = static_cast<size_t>(y) * maskWidth + x;
                const float value = luminance[index];
                if (value < 0.72f) continue;
                const float prominence = std::max(0.0f, std::min(1.0f,
                    (value - localMean[index]) * 4.0f));
                if (prominence <= 0.03f) continue;
                bool peak = true;
                for (const auto& offset : neighbours) {
                    const size_t neighbour = static_cast<size_t>(y + offset[1]) * maskWidth +
                        static_cast<uint32_t>(x + offset[0]);
                    if (luminance[neighbour] > value) { peak = false; break; }
                }
                if (!peak) continue;
                const float u = (x + 0.5f) / maskWidth;
                const float v = (y + 0.5f) / maskHeight;
                const uint32_t dx = std::min(job.bokehDepthWidth - 1,
                    static_cast<uint32_t>(u * (job.bokehDepthWidth - 1)));
                const uint32_t dy = std::min(job.bokehDepthHeight - 1,
                    static_cast<uint32_t>(v * (job.bokehDepthHeight - 1)));
                const float depth = job.bokehDepth[static_cast<size_t>(dy) *
                    job.bokehDepthWidth + dx] / 255.0f;
                const float coc = std::max(0.0f, std::min(1.0f,
                    std::fabs(depth - focus) * 2.12f * blur * apertureGain));
                if (coc < 0.08f) continue;
                const float highlight = std::max(0.0f, std::min(1.0f, (value - 0.72f) / 0.28f));
                const float weight = highlight * std::min(1.0f, coc * 1.4f) *
                    std::max(prominence, 0.15f);
                if (weight <= 0.006f + 0.04f * (1.0f - density)) continue;
                candidates.push_back({weight, static_cast<float>(x), static_cast<float>(y), coc});
            }
        }
        std::sort(candidates.begin(), candidates.end(),
            [](const Peak& a, const Peak& b) { return a.weight > b.weight; });
        const int suppression = std::max(2, static_cast<int>(std::lround(7.0f * radiusScale * 0.25f)));
        const int maxPeaks = std::min(512, 80 + static_cast<int>(640.0f * density));
        std::vector<Peak> peaks;
        peaks.reserve(static_cast<size_t>(maxPeaks));
        for (const Peak& candidate : candidates) {
            if (static_cast<int>(peaks.size()) >= maxPeaks) break;
            bool blocked = false;
            for (const Peak& accepted : peaks) {
                const float dx = accepted.x - candidate.x;
                const float dy = accepted.y - candidate.y;
                if (dx * dx + dy * dy < static_cast<float>(suppression * suppression)) {
                    blocked = true;
                    break;
                }
            }
            if (!blocked) peaks.push_back(candidate);
        }
        std::vector<float> points;
        points.reserve(peaks.size() * 4);
        for (const Peak& peak : peaks) {
            float radius = discBase * apertureFactor * (0.25f + 1.05f * peak.coc);
            radius = std::max(1.0f, std::min(64.0f, radius));
            const float intensity = std::max(0.08f, std::min(0.90f, peak.weight * 2.2f));
            points.push_back((peak.x + 0.5f) / maskWidth);
            points.push_back((peak.y + 0.5f) / maskHeight);
            points.push_back(radius);
            points.push_back(intensity);
        }
        if (points.empty()) return;
        if (bokehPointBuffer == 0) glGenBuffers(1, &bokehPointBuffer);
        glBindBuffer(GL_ARRAY_BUFFER, bokehPointBuffer);
        glBufferData(GL_ARRAY_BUFFER, points.size() * sizeof(float), points.data(), GL_STREAM_DRAW);

        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
            plateTexture, 0);
        glViewport(0, 0, static_cast<GLsizei>(workWidth), static_cast<GLsizei>(workHeight));
        glUseProgram(bokehPointProgram);
        glUniform1i(glGetUniformLocation(bokehPointProgram, "uShape"),
            static_cast<GLint>(std::round(job.bokehParams[3])));
        glUniform1f(glGetUniformLocation(bokehPointProgram, "uSpherical"),
            std::max(-1.0f, std::min(1.0f, job.bokehParams[6])));
        const GLint position = glGetAttribLocation(bokehPointProgram, "aPosition");
        const GLint radius = glGetAttribLocation(bokehPointProgram, "aRadius");
        const GLint intensity = glGetAttribLocation(bokehPointProgram, "aIntensity");
        if (position < 0 || radius < 0 || intensity < 0) { glBindBuffer(GL_ARRAY_BUFFER, 0); return; }
        const GLsizei stride = static_cast<GLsizei>(4 * sizeof(float));
        glEnableVertexAttribArray(position);
        glEnableVertexAttribArray(radius);
        glEnableVertexAttribArray(intensity);
        glVertexAttribPointer(position, 2, GL_FLOAT, GL_FALSE, stride,
            reinterpret_cast<const void*>(0));
        glVertexAttribPointer(radius, 1, GL_FLOAT, GL_FALSE, stride,
            reinterpret_cast<const void*>(2 * sizeof(float)));
        glVertexAttribPointer(intensity, 1, GL_FLOAT, GL_FALSE, stride,
            reinterpret_cast<const void*>(3 * sizeof(float)));
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE);
        glDrawArrays(GL_POINTS, 0, static_cast<GLsizei>(points.size() / 4));
        glDisable(GL_BLEND);
        glDisableVertexAttribArray(position);
        glDisableVertexAttribArray(radius);
        glDisableVertexAttribArray(intensity);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }

    /** Render the plate and (unless plate-only) composite it into `last`. */
    bool applyBokeh(StackWork& job, GLuint& last, std::string& error) {
        if (!job.bokehEnabled) return true;
        if (job.bokehDepth.empty() || job.bokehDepthWidth == 0 || job.bokehDepthHeight == 0) {
            error = "bokeh depth unavailable";
            return false;
        }
        if (!makeBokehPrograms(error)) return false;

        if (bokehDepthTexture != 0) glDeleteTextures(1, &bokehDepthTexture);
        bokehDepthTexture = uploadTexture(GL_LUMINANCE, job.bokehDepthWidth,
            job.bokehDepthHeight, job.bokehDepth.data());
        if (bokehDepthTexture == 0) { error = "bokeh depth upload failed"; return false; }

        GLuint plateTexture = 0;
        if (!job.bokehPlate.empty() && job.bokehPlateWidth > 0 && job.bokehPlateHeight > 0) {
            if (bokehExternalPlateTexture != 0) glDeleteTextures(1, &bokehExternalPlateTexture);
            bokehExternalPlateTexture = uploadTexture(GL_RGBA, job.bokehPlateWidth,
                job.bokehPlateHeight, job.bokehPlate.data());
            plateTexture = bokehExternalPlateTexture;
        } else {
            uint32_t workWidth = job.width, workHeight = job.height;
            if (!job.bokehPlateOnly) {
                const float scale = std::min(1.0f, 1200.0f /
                    static_cast<float>(std::max(job.width, job.height)));
                workWidth = std::max(1u, static_cast<uint32_t>(std::round(job.width * scale)));
                workHeight = std::max(1u, static_cast<uint32_t>(std::round(job.height * scale)));
            }
            if (workWidth == 0 || workHeight == 0) { error = "invalid bokeh work size"; return false; }
            uint32_t sourceWidth = bokehSourceWidth, sourceHeight = bokehSourceHeight;
            bokehWorkTexture(workWidth, workHeight, bokehSourceTexture, sourceWidth, sourceHeight);
            bokehSourceWidth = sourceWidth; bokehSourceHeight = sourceHeight;
            bokehWorkTexture(workWidth, workHeight, bokehPlateTexture, bokehWorkWidth, bokehWorkHeight);
            if (bokehSourceTexture == 0 || bokehPlateTexture == 0) {
                error = "bokeh work texture unavailable";
                return false;
            }
            if (!job.bokehPlateOnly) {
                // Downsample the full-res colour result into the bounded plate
                // source. The same present shader is used with an identity UV
                // matrix, so no extra shader/program is needed.
                glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                    bokehSourceTexture, 0);
                if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
                    error = "bokeh downsample framebuffer incomplete";
                    return false;
                }
                glViewport(0, 0, static_cast<GLsizei>(workWidth), static_cast<GLsizei>(workHeight));
                glUseProgram(presentProgram);
                const GLfloat identity[9] = {1,0,0,0,1,0,0,0,1};
                glUniformMatrix3fv(glGetUniformLocation(presentProgram, "uUvMatrix"),
                    1, GL_FALSE, identity);
                glUniform1f(glGetUniformLocation(presentProgram, "uFlipY"), 0.0f);
                bindTexture(presentProgram, "tex", 0, last);
                drawFullscreen();
            }
            glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                bokehPlateTexture, 0);
            if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
                error = "bokeh plate framebuffer incomplete";
                return false;
            }
            glViewport(0, 0, static_cast<GLsizei>(workWidth), static_cast<GLsizei>(workHeight));
            glUseProgram(bokehProgram);
            bindTexture(bokehProgram, "uImage", 0, job.bokehPlateOnly ? last : bokehSourceTexture);
            bindTexture(bokehProgram, "uDepth", 1, bokehDepthTexture);
            glUniform2f(glGetUniformLocation(bokehProgram, "uTexel"),
                1.0f / static_cast<float>(workWidth), 1.0f / static_cast<float>(workHeight));
            glUniform1f(glGetUniformLocation(bokehProgram, "uAperture"), job.bokehParams[0]);
            glUniform1f(glGetUniformLocation(bokehProgram, "uBlur"), job.bokehParams[1]);
            glUniform1f(glGetUniformLocation(bokehProgram, "uBokeh"), job.bokehParams[2]);
            glUniform1i(glGetUniformLocation(bokehProgram, "uShape"),
                static_cast<GLint>(std::round(job.bokehParams[3])));
            glUniform1f(glGetUniformLocation(bokehProgram, "uDensity"), job.bokehParams[4]);
            glUniform1f(glGetUniformLocation(bokehProgram, "uSize"), job.bokehParams[5]);
            glUniform1f(glGetUniformLocation(bokehProgram, "uSpherical"), job.bokehParams[6]);
            glUniform1f(glGetUniformLocation(bokehProgram, "uFocus"), job.bokehParams[7]);
            drawFullscreen();
            plateTexture = bokehPlateTexture;
            if (job.bokehParams[2] > 0.001f) {
                addBokehHighlights(job, job.bokehPlateOnly ? last : bokehSourceTexture,
                    workWidth, workHeight, bokehPlateTexture);
            }
            if (job.bokehPlateOnly) { last = plateTexture; return true; }
        }

        // Composite at full/tile resolution. The target must never be the
        // texture currently bound as `uImage`, or the feedback loop is undefined.
        const GLuint target = (last == output[0]) ? output[1] : output[0];
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            error = "bokeh composite framebuffer incomplete";
            return false;
        }
        glViewport(0, 0, static_cast<GLsizei>(job.width), static_cast<GLsizei>(job.height));
        glUseProgram(bokehCompositeProgram);
        bindTexture(bokehCompositeProgram, "uImage", 0, last);
        bindTexture(bokehCompositeProgram, "uPlate", 1, plateTexture);
        bindTexture(bokehCompositeProgram, "uDepth", 2, bokehDepthTexture);
        glUniform1f(glGetUniformLocation(bokehCompositeProgram, "uBlur"), job.bokehParams[1]);
        glUniform1f(glGetUniformLocation(bokehCompositeProgram, "uFocus"), job.bokehParams[7]);
        glUniform1f(glGetUniformLocation(bokehCompositeProgram, "uAperture"), job.bokehParams[0]);
        glUniform2f(glGetUniformLocation(bokehCompositeProgram, "uUvOffset"),
            job.bokehUvOffset[0], job.bokehUvOffset[1]);
        glUniform2f(glGetUniformLocation(bokehCompositeProgram, "uUvScale"),
            job.bokehUvScale[0], job.bokehUvScale[1]);
        drawFullscreen();
        last = target;
        return true;
    }

    void bindTexture(GLuint p, const char* name, int unit, GLuint texture) {
        glActiveTexture(GL_TEXTURE0 + unit); glBindTexture(GL_TEXTURE_2D, texture);
        glUniform1i(glGetUniformLocation(p, name), unit);
    }
    void drawPass(RenderWork& work, PassTextures& cache, GLuint input) {
        const std::vector<uint8_t>* fallback[] = {&work.toneCurve, &work.redCurve, &work.greenCurve, &work.blueCurve, &work.lut, &work.mask};
        auto asset = [&](size_t index) -> const std::vector<uint8_t>& {
            return work.assets[index] ? *work.assets[index] : *fallback[index];
        };
        for (size_t i = 0; i < 4; ++i) cache.curve[i].update(GL_RGBA, 1025, 1, asset(i), work.assetIds[i]);
        if (work.lutEnabled) cache.lut.update(GL_RGBA16F, work.lutSize * work.lutSize, work.lutSize, asset(4), work.assetIds[4]);
        if (work.maskEnabled) cache.mask.update(GL_LUMINANCE, work.maskWidth, work.maskHeight, asset(5), work.assetIds[5]);
        glUseProgram(program);
        bindTexture(program, "uImage", 0, input);
        bindTexture(program, "uToneCurve", 1, cache.curve[0].id);
        bindTexture(program, "uRedCurve", 2, cache.curve[1].id);
        bindTexture(program, "uGreenCurve", 3, cache.curve[2].id);
        bindTexture(program, "uBlueCurve", 4, cache.curve[3].id);
        bindTexture(program, "uLut", 5, work.lutEnabled ? cache.lut.id : cache.curve[0].id);
        bindTexture(program, "uMask", 6, work.maskEnabled ? cache.mask.id : cache.curve[0].id);
        const GLfloat matrix[] = {
            work.matrix[0],work.matrix[5],work.matrix[10],work.matrix[15],
            work.matrix[1],work.matrix[6],work.matrix[11],work.matrix[16],
            work.matrix[2],work.matrix[7],work.matrix[12],work.matrix[17],
            work.matrix[3],work.matrix[8],work.matrix[13],work.matrix[18] };
        const GLfloat offset[] = {work.matrix[4]/255,work.matrix[9]/255,work.matrix[14]/255,work.matrix[19]/255};
        glUniformMatrix4fv(glGetUniformLocation(program, "uMatrix"), 1, GL_FALSE, matrix);
        glUniform4fv(glGetUniformLocation(program, "uOffset"), 1, offset);
#define FLOAT(field, uniform) glUniform1f(glGetUniformLocation(program, uniform), work.field)
        FLOAT(opacity,"uOpacity"); FLOAT(lutIntensity,"uLutIntensity"); FLOAT(lutSize,"uLutSize");
        FLOAT(maskOpacity,"uMaskOpacity"); FLOAT(maskEnabled,"uMaskEnabled"); FLOAT(lutEnabled,"uLutEnabled");
        FLOAT(whiteBalanceEnabled,"uWbEnabled"); FLOAT(vibrance,"uVibrance"); FLOAT(mixerEnabled,"uMixerEnabled");
        FLOAT(exposureGain,"uExposureGain");
        FLOAT(gradingEnabled,"uGradingEnabled"); FLOAT(gradingBlending,"uGradingBlending"); FLOAT(gradingBalance,"uGradingBalance");
        FLOAT(gradingShadowsSaturation,"uGradingShadowsSaturation"); FLOAT(gradingShadowsLuminance,"uGradingShadowsLuminance");
        FLOAT(gradingMidtonesSaturation,"uGradingMidtonesSaturation"); FLOAT(gradingMidtonesLuminance,"uGradingMidtonesLuminance");
        FLOAT(gradingHighlightsSaturation,"uGradingHighlightsSaturation"); FLOAT(gradingHighlightsLuminance,"uGradingHighlightsLuminance");
        FLOAT(gradingGlobalSaturation,"uGradingGlobalSaturation"); FLOAT(gradingGlobalLuminance,"uGradingGlobalLuminance");
#undef FLOAT
        glUniform1i(glGetUniformLocation(program,"uBlendMode"),work.blendMode);
#define ARRAY(field, uniform, size) glUniform##size##fv(glGetUniformLocation(program, uniform), 1, work.field)
        ARRAY(gradingShadowsTarget,"uGradingShadowsTarget",3); ARRAY(gradingMidtonesTarget,"uGradingMidtonesTarget",3);
        ARRAY(gradingHighlightsTarget,"uGradingHighlightsTarget",3); ARRAY(gradingGlobalTarget,"uGradingGlobalTarget",3);
        ARRAY(tonal,"uTonal",4); ARRAY(whiteBalanceGain,"uWbGain",3);
        ARRAY(denoise,"uDenoise",4);
        ARRAY(lutDomainMin,"uLutDomainMin",3); ARRAY(lutDomainScale,"uLutDomainScale",3);
        ARRAY(calibrationHue,"uCalibrationHue",3); ARRAY(calibrationSaturation,"uCalibrationSaturation",3);
#undef ARRAY
        glUniform1fv(glGetUniformLocation(program,"uMixHue"),8,work.mixHue);
        glUniform1fv(glGetUniformLocation(program,"uMixSaturation"),8,work.mixSaturation);
        glUniform1fv(glGetUniformLocation(program,"uMixLuminance"),8,work.mixLuminance);
        if (work.grain[0] > 0 && (!grainTexture || grainWidth != width || grainHeight != height || grainSize != work.grain[1])) {
            glDeleteTextures(1, &grainTexture);
            grainTexture = makeGrainTexture(width, height, work.grain[1]);
            grainWidth = width; grainHeight = height; grainSize = work.grain[1];
        }
        spatialUniforms(program, work, width, height, work.grain[0] > 0 ? grainTexture : cache.curve[0].id);
        glDrawArrays(GL_TRIANGLES,0,3);
    }
public:
    ~GpuSession() {
        if (context != EGL_NO_CONTEXT) {
            current(); closeWindow();
            for (auto& p : textures) { for (auto& c : p.curve) c.clear(); p.mask.clear(); p.lut.clear(); }
            glDeleteTextures(1,&source); glDeleteTextures(2,output); glDeleteFramebuffers(1,&framebuffer);
            glDeleteTextures(1,&grainTexture);
            glDeleteTextures(1,&denoiseTexture);
            glDeleteTextures(1,&bokehSourceTexture);
            glDeleteTextures(1,&bokehPlateTexture);
            glDeleteTextures(1,&bokehDepthTexture);
            glDeleteTextures(1,&bokehExternalPlateTexture);
            glDeleteTextures(1,&bokehMaskTexture);
            if (bokehPointBuffer != 0) glDeleteBuffers(1, &bokehPointBuffer);
            if (bokehProgram != 0) glDeleteProgram(bokehProgram);
            if (bokehCompositeProgram != 0) glDeleteProgram(bokehCompositeProgram);
            if (bokehMaskProgram != 0) glDeleteProgram(bokehMaskProgram);
            if (bokehPointProgram != 0) glDeleteProgram(bokehPointProgram);
            glDeleteProgram(program); glDeleteProgram(presentProgram);
            eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
            eglDestroyContext(display,context);
        }
        if (pbuffer != EGL_NO_SURFACE) eglDestroySurface(display,pbuffer);
        // EGL_DEFAULT_DISPLAY is shared with the compatibility renderer. Do
        // not terminate it while another session still owns a context.
    }
    bool render(StackWork& job) {
        if (context == EGL_NO_CONTEXT) {
            display=eglGetDisplay(EGL_DEFAULT_DISPLAY);
            if (!eglInitialize(display,nullptr,nullptr) || !eglBindAPI(EGL_OPENGL_ES_API)) { job.error="EGL unavailable"; return false; }
            const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_WINDOW_BIT|EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,
                EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
            EGLint count=0;
            // Prefer an ES3 config/context: RGBA16F LUT textures need ES3.
            // Fall back to ES2 for the rest of the pipeline, but refuse a LUT
            // job below rather than uploading a half-float atlas that the
            // context cannot represent.
            const EGLint es3Attrs[]={EGL_SURFACE_TYPE,EGL_WINDOW_BIT|EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,
                EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
            if (!eglChooseConfig(display,es3Attrs,&config,1,&count) || !count) {
                count=0;
                if (!eglChooseConfig(display,attrs,&config,1,&count) || !count) {job.error="EGL config unavailable";return false;}
            }
            const EGLint ctx[]={EGL_CONTEXT_CLIENT_VERSION,2,EGL_NONE}, ctx3[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE},
                pb[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE};
            context=eglCreateContext(display,config,EGL_NO_CONTEXT,ctx3);
            es3Context=context!=EGL_NO_CONTEXT;
            if (!es3Context) context=eglCreateContext(display,config,EGL_NO_CONTEXT,ctx);
            pbuffer=eglCreatePbufferSurface(display,config,pb);
            if (context==EGL_NO_CONTEXT || pbuffer==EGL_NO_SURFACE) {job.error="EGL context unavailable";return false;}
            current(); glGetIntegerv(GL_MAX_TEXTURE_SIZE,&limit);
            program=makeProgram(job.error);
            if (!program) return false;
            presentProgram=makePresent(job.error);
            glGenFramebuffers(1,&framebuffer);
        }
        if (job.clear) {
            if (job.surface.empty()) { job.error="clear requires a surface"; return false; }
            if (surfaceId!=job.surface || windowSurface==EGL_NO_SURFACE) {
                closeWindow(); uint64_t id=0;
                try { id=std::stoull(job.surface); } catch (...) {job.error="invalid surface id";return false;}
                if(OH_NativeWindow_CreateNativeWindowFromSurfaceId(id,&window)!=0){job.error="surface unavailable";return false;}
                windowSurface=eglCreateWindowSurface(display,config,reinterpret_cast<EGLNativeWindowType>(window),nullptr);
                if(windowSurface==EGL_NO_SURFACE){job.error="window surface unavailable";return false;}
                surfaceId=job.surface;
            }
            if(!eglMakeCurrent(display,windowSurface,windowSurface,context)){job.error="surface bind failed";return false;}
            // RenderService keeps compositing the last swapped buffer after the
            // ArkTS side stops presenting (crop/geometry disable the GPU path),
            // and component opacity does not hide a native surface layer on
            // every device. Swapping one fully transparent frame is the only
            // reliable way to uncover the CPU preview and the compare view.
            EGLint sw=0,sh=0; eglQuerySurface(display,windowSurface,EGL_WIDTH,&sw); eglQuerySurface(display,windowSurface,EGL_HEIGHT,&sh);
            glBindFramebuffer(GL_FRAMEBUFFER,0); glViewport(0,0,sw,sh);
            glClearColor(0.f,0.f,0.f,0.f); glClear(GL_COLOR_BUFFER_BIT);
            if(!eglSwapBuffers(display,windowSurface)){job.error="surface clear failed";return false;}
            current();
            return true;
        }
        current();
        for (const auto& pass : job.passes) {
            if (pass.lutEnabled && !es3Context) {job.error="16F LUT requires OpenGL ES 3";return false;}
        }
        // Readback jobs draw the final copy into the default framebuffer, so
        // the pbuffer must match the image size. Some GLES translation layers
        // (emulator DGLES) clamp or redirect glReadPixels to the draw surface;
        // rendering there first keeps readback correct on both paths.
        if (job.surface.empty() && (pbWidth != job.outputWidth || pbHeight != job.outputHeight)) {
            const EGLint scaled[]={EGL_WIDTH,static_cast<EGLint>(job.outputWidth),EGL_HEIGHT,static_cast<EGLint>(job.outputHeight),EGL_NONE};
            EGLSurface next=eglCreatePbufferSurface(display,config,scaled);
            if(next==EGL_NO_SURFACE){job.error="pbuffer unavailable";return false;}
            if(!eglMakeCurrent(display,next,next,context)){eglDestroySurface(display,next);job.error="pbuffer bind failed";return false;}
            if(pbuffer!=EGL_NO_SURFACE) eglDestroySurface(display,pbuffer);
            pbuffer=next; pbWidth=job.outputWidth; pbHeight=job.outputHeight;
        }
        if (!program || !presentProgram) {if(job.error.empty())job.error="shader unavailable";return false;}
        if (job.width>static_cast<uint32_t>(limit)||job.height>static_cast<uint32_t>(limit)) {job.error="texture limit exceeded";return false;}
        for (const auto& pass : job.passes) if (pass.lutEnabled && pass.lutSize*pass.lutSize>static_cast<uint32_t>(limit)) {job.error="LUT texture limit exceeded";return false;}
        while(glGetError()!=GL_NO_ERROR) {}
        glPixelStorei(GL_UNPACK_ALIGNMENT,1);
        if (!source || width!=job.width || height!=job.height || sourceVersion!=job.sourceVersion) {
            if (job.source.size()!=static_cast<size_t>(job.width)*job.height*4) {job.error="source upload required";return false;}
            glDeleteTextures(1,&source); glDeleteTextures(2,output);
            glDeleteTextures(1,&denoiseTexture); denoiseTexture=0; denoiseValid=false;
            width=job.width; height=job.height; sourceVersion=job.sourceVersion;
            glActiveTexture(GL_TEXTURE0);
            source=uploadTexture(GL_RGBA,width,height,job.source.data());
            output[0]=uploadTexture(GL_RGBA,width,height,nullptr); output[1]=uploadTexture(GL_RGBA,width,height,nullptr);
        }
        if (textures.size()<job.passes.size()) textures.resize(job.passes.size());
        const GLfloat vertices[]={-1,-1,3,-1,-1,3};
        glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,0,vertices); glEnableVertexAttribArray(0);
        glViewport(0,0,width,height); glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);
        GLuint last=source;
        if (job.passes.empty() || (job.passes[0].denoise[0] <= 0 && job.passes[0].denoise[1] <= 0)) {
            glDeleteTextures(1,&denoiseTexture); denoiseTexture=0; denoiseValid=false;
        }
        for(size_t i=0;i<job.passes.size();++i) {
            const bool noise = i==0 && (job.passes[i].denoise[0]>0 || job.passes[i].denoise[1]>0);
            if (noise && denoiseValid && std::memcmp(denoiseCached,job.passes[i].denoise,sizeof(denoiseCached))==0) {
                last=denoiseTexture; continue;
            }
            if (noise && !denoiseTexture) denoiseTexture=uploadTexture(GL_RGBA,width,height,nullptr);
            GLuint target=noise?denoiseTexture:output[i%2];
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,target,0);
            if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){job.error="incomplete framebuffer";return false;}
            drawPass(job.passes[i],textures[i],last); last=target;
            if (noise) { std::memcpy(denoiseCached,job.passes[i].denoise,sizeof(denoiseCached)); denoiseValid=true; }
        }
        if (glGetError()!=GL_NO_ERROR) {denoiseValid=false;job.error="GPU pass failed";return false;}
        // The virtual-lens stage deliberately runs after every colour/mask pass
        // and before readback/present. Preview and export therefore share the
        // same order, and the output geometry still samples the finished frame.
        if (job.bokehEnabled && !applyBokeh(job, last, job.error)) return false;
        if (job.surface.empty()) {
            // Copy the finished FBO texture through the identity present
            // shader into the pbuffer-sized default framebuffer and read from
            // there. No adjustment pass runs twice; some GLES translators
            // cannot read back from a bound FBO directly.
            glBindFramebuffer(GL_FRAMEBUFFER,0);
            glViewport(0,0,job.outputWidth,job.outputHeight);
            glUseProgram(presentProgram);
            glUniformMatrix3fv(glGetUniformLocation(presentProgram,"uUvMatrix"),1,GL_FALSE,job.uvMatrix);
            // glReadPixels starts at the GL bottom-left corner, so the copy
            // keeps the texture orientation instead of flipping like the
            // window present path (EGL windows are top-left origin).
            glUniform1f(glGetUniformLocation(presentProgram,"uFlipY"),0.0f);
            bindTexture(presentProgram,"tex",0,last);
            drawFullscreen();
            job.output.resize(static_cast<size_t>(job.outputWidth)*job.outputHeight*4);
            glReadPixels(0,0,job.outputWidth,job.outputHeight,GL_RGBA,GL_UNSIGNED_BYTE,job.output.data());
        } else {
            if (surfaceId!=job.surface) {
                closeWindow(); uint64_t id=0;
                try { id=std::stoull(job.surface); } catch (...) {job.error="invalid surface id";return false;}
                if(OH_NativeWindow_CreateNativeWindowFromSurfaceId(id,&window)!=0){job.error="surface unavailable";return false;}
                windowSurface=eglCreateWindowSurface(display,config,reinterpret_cast<EGLNativeWindowType>(window),nullptr);
                if(windowSurface==EGL_NO_SURFACE){job.error="window surface unavailable";return false;}
                surfaceId=job.surface;
            }
            if(!eglMakeCurrent(display,windowSurface,windowSurface,context)){job.error="surface bind failed";return false;}
            EGLint sw=0,sh=0; eglQuerySurface(display,windowSurface,EGL_WIDTH,&sw); eglQuerySurface(display,windowSurface,EGL_HEIGHT,&sh);
            glBindFramebuffer(GL_FRAMEBUFFER,0); glViewport(0,0,sw,sh);
            glUseProgram(presentProgram); glUniform1f(glGetUniformLocation(presentProgram,"uFlipY"),1.0f);
            glUniformMatrix3fv(glGetUniformLocation(presentProgram,"uUvMatrix"),1,GL_FALSE,job.uvMatrix);
            bindTexture(presentProgram,"tex",0,last);
            drawFullscreen();
            if(!eglSwapBuffers(display,windowSurface)){job.error="surface present failed";return false;}
            current();
        }
        if(glGetError()!=GL_NO_ERROR){job.error="GPU output failed";return false;} return true;
    }
};

static RenderThread& renderThread() { static RenderThread value; return value; }
static std::unordered_map<std::string,std::unique_ptr<GpuSession>>& gpuSessions() {
    static std::unordered_map<std::string,std::unique_ptr<GpuSession>>* value =
        new std::unordered_map<std::string,std::unique_ptr<GpuSession>>;
    return *value;
}
static void executeStack(napi_env,void* data) {
    auto& work=*static_cast<StackWork*>(data);
    try { renderThread().call([&work] {
        auto& sessions=gpuSessions();
        if(work.release){sessions.erase(work.key);return;}
        if(work.clear){auto found=sessions.find(work.key);if(found!=sessions.end())found->second->render(work);return;}
        auto& session=sessions[work.key];
        if(!session) session=std::make_unique<GpuSession>();
        session->render(work);
    }); } catch(const std::exception& e){work.error=e.what();}
}
static void completeStack(napi_env env,napi_status status,void* data) {
    std::unique_ptr<StackWork> work(static_cast<StackWork*>(data));
    napi_value result;
    if(status!=napi_ok||!work->error.empty()) {
        napi_value message; napi_create_string_utf8(env,work->error.c_str(),NAPI_AUTO_LENGTH,&message);
        napi_create_error(env,nullptr,message,&result); napi_reject_deferred(env,work->deferred,result);
    } else {
        void* bytes=nullptr; napi_create_arraybuffer(env,work->output.size(),&bytes,&result);
        if(!work->output.empty()) std::memcpy(bytes,work->output.data(),work->output.size());
        napi_resolve_deferred(env,work->deferred,result);
    }
    napi_delete_async_work(env,work->async);
}
static napi_value queueStack(napi_env env,StackWork* work) {
    napi_value promise,name; napi_create_promise(env,&work->deferred,&promise);
    napi_create_string_utf8(env,"VividGpuStack",NAPI_AUTO_LENGTH,&name);
    if(napi_create_async_work(env,nullptr,name,executeStack,completeStack,work,&work->async)!=napi_ok) {
        delete work; napi_throw_error(env,nullptr,"Cannot create GPU task"); return nullptr;
    }
    if(napi_queue_async_work(env,work->async)!=napi_ok) {
        napi_delete_async_work(env,work->async); delete work;
        napi_throw_error(env,nullptr,"Cannot queue GPU task"); return nullptr;
    }
    return promise;
}
static napi_value renderStack(napi_env env,napi_callback_info info) {
    napi_value args[9]; size_t argc=9;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    auto work=std::make_unique<StackWork>(); work->env=env;
    uint32_t count=0;
    if((argc!=7 && argc!=8 && argc!=9) || !stringValue(env,args[0],work->key)||!stringValue(env,args[1],work->surface)||
        napi_get_value_uint32(env,args[3],&work->width)!=napi_ok || napi_get_value_uint32(env,args[4],&work->height)!=napi_ok ||
        napi_get_value_uint32(env,args[5],&work->sourceVersion)!=napi_ok || !work->width||!work->height ||
        // 16384^2 pre-filter: the real GL_MAX_TEXTURE_SIZE check in
        // RenderThread::render stays the effective per-device guard.
        static_cast<uint64_t>(work->width)*work->height>268435456 || napi_get_array_length(env,args[6],&count)!=napi_ok || count>64) {
        napi_throw_error(env,nullptr,"Invalid GPU stack");return nullptr;
    }
    work->outputWidth=work->width; work->outputHeight=work->height;
    if(argc>=8) {
        napi_value outWidth,outHeight,matrix; void* bytes=nullptr; size_t length=0;
        if(!getNamed(env,args[7],"width",&outWidth)||!getNamed(env,args[7],"height",&outHeight)||
            !getNamed(env,args[7],"uvMatrix",&matrix)||
            napi_get_value_uint32(env,outWidth,&work->outputWidth)!=napi_ok||
            napi_get_value_uint32(env,outHeight,&work->outputHeight)!=napi_ok||
            !work->outputWidth||!work->outputHeight||
            work->outputWidth>16384||work->outputHeight>16384||
            static_cast<uint64_t>(work->outputWidth)*work->outputHeight>
                static_cast<uint64_t>(work->width)*work->height||
            napi_get_arraybuffer_info(env,matrix,&bytes,&length)!=napi_ok||length!=sizeof(work->uvMatrix)) {
            napi_throw_error(env,nullptr,"Invalid GPU output geometry");return nullptr;
        }
        std::memcpy(work->uvMatrix,bytes,length);
        for(float element:work->uvMatrix) if(!std::isfinite(element)) {
            napi_throw_error(env,nullptr,"Non-finite GPU output geometry");return nullptr;
        }
    }
    if (argc==9 && !parseBokehOptions(env, args[8], *work)) {
        napi_throw_error(env,nullptr,"Invalid GPU bokeh options");return nullptr;
    }
    if(!copyArrayBuffer(env,args[2],work->source,0,true)){napi_throw_error(env,nullptr,"Invalid source");return nullptr;}
    work->passes.resize(count);
    for(uint32_t i=0;i<count;i++) {napi_value pass;napi_get_element(env,args[6],i,&pass);
        if(!parsePass(env,pass,work->passes[i])){napi_throw_error(env,nullptr,"Invalid GPU pass");return nullptr;}}
    return queueStack(env,work.release());
}
static napi_value releaseSession(napi_env env,napi_callback_info info) {
    napi_value arg;size_t argc=1;napi_get_cb_info(env,info,&argc,&arg,nullptr,nullptr);
    auto work=new StackWork();work->env=env;work->release=true;
    if(argc!=1||!stringValue(env,arg,work->key)){delete work;return nullptr;}
    return queueStack(env,work);
}
static napi_value clearSurface(napi_env env,napi_callback_info info) {
    napi_value args[2];size_t argc=2;napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    auto work=new StackWork();work->env=env;work->clear=true;
    if(argc!=2||!stringValue(env,args[0],work->key)||!stringValue(env,args[1],work->surface)){delete work;return nullptr;}
    return queueStack(env,work);
}
