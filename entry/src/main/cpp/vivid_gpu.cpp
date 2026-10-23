#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <napi/native_api.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <utility>
#include <vector>
#include <native_window/external_window.h>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <queue>
#include <future>
#include <memory>
#include <unordered_map>
#include <functional>
#include <stdexcept>
#include "vivid_buffer_cache.h"

// The build still uses the GLES2 headers, but the LUT atlas needs the ES3
// half-float format. Keep local definitions so the file compiles without
// pulling in the GLES3 header set.
#ifndef GL_RGBA16F
#define GL_RGBA16F 0x881A
#endif
#ifndef GL_HALF_FLOAT
#define GL_HALF_FLOAT 0x140B
#endif
#ifndef EGL_OPENGL_ES3_BIT
#define EGL_OPENGL_ES3_BIT 0x00000040
#endif

namespace {

struct RenderWork {
    napi_env env = nullptr;
    napi_deferred deferred = nullptr;
    napi_async_work asyncWork = nullptr;
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> input;
    std::vector<uint8_t> toneCurve;
    std::vector<uint8_t> redCurve;
    std::vector<uint8_t> greenCurve;
    std::vector<uint8_t> blueCurve;
    // Parametric tone curve. RGB carries the curve as 16-bit RG plus an 8-bit
    // saturation-refinement factor in B, so both fit one texture.
    std::vector<uint8_t> parametricCurve;
    std::vector<uint8_t> lut;
    std::vector<uint8_t> mask;
    // Curves, LUT and alpha are immutable across parameter-only frames.
    std::shared_ptr<const std::vector<uint8_t>> assets[6];
    uint32_t assetIds[6] = {};
    uint32_t maskWidth = 0;
    uint32_t maskHeight = 0;
    bool lutEnabled = false;
    bool maskEnabled = false;
    bool parametricEnabled = false;
    float parametricRefine = 1.0f;
    float maskOpacity = 1.0f;
    float opacity = 1.0f;
    float lutIntensity = 1.0f;
    int blendMode = 0;
    float matrix[20] = {
        1.0f, 0.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f, 0.0f,
    };
    float mixHue[8] = {};
    float mixSaturation[8] = {};
    float mixLuminance[8] = {};
    float tonal[4] = {};
    float whiteBalanceGain[3] = {1.0f, 1.0f, 1.0f};
    float exposureGain = 1.0f;
    float vignette[5] = {};
    float grain[3] = {};
    float denoise[4] = {};
    float lutDomainMin[3] = {};
    float lutDomainScale[3] = {1.0f, 1.0f, 1.0f};
    bool whiteBalanceEnabled = false;
    float vibrance = 0.0f;
    float calibrationHue[3] = {};
    float calibrationSaturation[3] = {};
    bool mixerEnabled = false;
    float gradingShadowsTarget[3] = {};
    float gradingMidtonesTarget[3] = {};
    float gradingHighlightsTarget[3] = {};
    float gradingGlobalTarget[3] = {};
    float gradingShadowsSaturation = 0.0f;
    float gradingShadowsLuminance = 0.0f;
    float gradingMidtonesSaturation = 0.0f;
    float gradingMidtonesLuminance = 0.0f;
    float gradingHighlightsSaturation = 0.0f;
    float gradingHighlightsLuminance = 0.0f;
    float gradingGlobalSaturation = 0.0f;
    float gradingGlobalLuminance = 0.0f;
    float gradingBlending = 0.0f;
    float gradingBalance = 0.0f;
    bool gradingEnabled = false;
    std::vector<uint8_t> output;
    std::string error;
    uint32_t lutSize = 0;
};

static bool getNamed(napi_env env, napi_value object, const char* name, napi_value* value)
{
    return napi_get_named_property(env, object, name, value) == napi_ok;
}

static bool getNumber(napi_env env, napi_value object, const char* name, double* out)
{
    napi_value value = nullptr;
    if (!getNamed(env, object, name, &value)) return false;
    return napi_get_value_double(env, value, out) == napi_ok;
}

static bool getBool(napi_env env, napi_value object, const char* name, bool* out)
{
    napi_value value = nullptr;
    if (!getNamed(env, object, name, &value)) return false;
    return napi_get_value_bool(env, value, out) == napi_ok;
}

static bool copyArrayBuffer(napi_env env, napi_value value, std::vector<uint8_t>& out,
    size_t expected = 0, bool optional = false)
{
    bool isArrayBuffer = false;
    if (napi_is_arraybuffer(env, value, &isArrayBuffer) != napi_ok || !isArrayBuffer) {
        return optional;
    }
    void* data = nullptr;
    size_t length = 0;
    if (napi_get_arraybuffer_info(env, value, &data, &length) != napi_ok || data == nullptr) return false;
    if (expected > 0 && length < expected) return false;
    out.assign(static_cast<uint8_t*>(data), static_cast<uint8_t*>(data) + length);
    return true;
}

static bool copyNamedBuffer(napi_env env, napi_value object, const char* name,
    std::vector<uint8_t>& out, size_t expected = 0, bool optional = false)
{
    napi_value value = nullptr;
    if (!getNamed(env, object, name, &value)) return optional;
    return copyArrayBuffer(env, value, out, expected, optional);
}

static bool copyNumberArray(napi_env env, napi_value object, const char* name, float* out, size_t count)
{
    napi_value array = nullptr;
    if (!getNamed(env, object, name, &array)) return false;
    bool isArray = false;
    if (napi_is_array(env, array, &isArray) != napi_ok || !isArray) return false;
    uint32_t length = 0;
    if (napi_get_array_length(env, array, &length) != napi_ok || length < count) return false;
    for (size_t index = 0; index < count; ++index) {
        napi_value item = nullptr;
        double number = 0.0;
        if (napi_get_element(env, array, static_cast<uint32_t>(index), &item) != napi_ok ||
            napi_get_value_double(env, item, &number) != napi_ok) return false;
        out[index] = static_cast<float>(number);
    }
    return true;
}

static bool copyNumberArrayOptional(napi_env env, napi_value object, const char* name,
    float* out, size_t count)
{
    napi_value value = nullptr;
    if (!getNamed(env, object, name, &value)) return true;
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok) return false;
    if (type == napi_undefined || type == napi_null) return true;
    return copyNumberArray(env, object, name, out, count);
}

static GLuint compileShader(GLenum type, const char* source, std::string& error)
{
    const GLuint shader = glCreateShader(type);
    if (shader == 0) {
        const auto* version = glGetString(GL_VERSION);
        error = "glCreateShader failed GL=" + std::to_string(glGetError()) + " version=" +
            (version ? reinterpret_cast<const char*>(version) : "none");
        return 0;
    }
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint status = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == GL_TRUE) return shader;
    GLint length = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
    std::string log(static_cast<size_t>(std::max(1, length)), '\0');
    glGetShaderInfoLog(shader, length, nullptr, log.data());
    error = "shader compile failed: " + log;
    glDeleteShader(shader);
    return 0;
}

static GLuint makeProgram(std::string& error)
{
    static const char* vertexSource =
        "attribute vec2 aPosition;"
        "varying vec2 vUv;"
        "void main(){ vUv = aPosition * 0.5 + 0.5;"
        "gl_Position = vec4(aPosition, 0.0, 1.0); }";
    static const char* fragmentSource =
        "precision highp float;"
        "varying vec2 vUv;"
        "uniform sampler2D uImage;"
        "uniform sampler2D uToneCurve;"
        "uniform sampler2D uRedCurve;"
        "uniform sampler2D uGreenCurve;"
        "uniform sampler2D uBlueCurve;"
        "uniform sampler2D uParametricCurve;"
        "uniform float uParametricEnabled;"
        "uniform float uParametricRefine;"
        "uniform sampler2D uLut;"
        "uniform sampler2D uMask;"
        "uniform float uOpacity; uniform float uLutIntensity; uniform int uBlendMode;"
        "uniform mat4 uMatrix;"
        "uniform vec4 uOffset;"
         "uniform float uLutEnabled;"
         "uniform float uLutSize;"
         "uniform float uMaskEnabled;"
        "uniform float uMaskOpacity;"
         "uniform float uMixHue[8];"
         "uniform float uMixSaturation[8];"
         "uniform float uMixLuminance[8];"
         "uniform vec4 uTonal; uniform vec3 uWbGain; uniform float uWbEnabled; uniform float uVibrance;"
         "uniform float uExposureGain; uniform vec3 uLutDomainMin; uniform vec3 uLutDomainScale;"
         "uniform vec4 uVignette; uniform float uVignetteHighlights; uniform vec3 uGrain;"
        "uniform vec2 uFrameSize; uniform sampler2D uGrainNoise;"
        "uniform vec4 uDenoise;"
         "uniform vec3 uCalibrationHue; uniform vec3 uCalibrationSaturation; uniform float uMixerEnabled;"
         "uniform vec3 uGradingShadowsTarget;"
         "uniform vec3 uGradingMidtonesTarget;"
         "uniform vec3 uGradingHighlightsTarget;"
         "uniform vec3 uGradingGlobalTarget;"
         "uniform float uGradingShadowsSaturation;"
         "uniform float uGradingShadowsLuminance;"
         "uniform float uGradingMidtonesSaturation;"
         "uniform float uGradingMidtonesLuminance;"
         "uniform float uGradingHighlightsSaturation;"
         "uniform float uGradingHighlightsLuminance;"
         "uniform float uGradingGlobalSaturation;"
         "uniform float uGradingGlobalLuminance;"
         "uniform float uGradingBlending;"
         "uniform float uGradingBalance;"
         "uniform float uGradingEnabled;"
        "float wrap01(float value){ return fract(value + 1.0); }"
        "vec3 hslToRgb(vec3 hsl){"
        "float c=(1.0-abs(2.0*hsl.z-1.0))*hsl.y; float hp=hsl.x*6.0;"
        "float x=c*(1.0-abs(mod(hp,2.0)-1.0)); vec3 rgb;"
        "if(hp<1.0)rgb=vec3(c,x,0.0); else if(hp<2.0)rgb=vec3(x,c,0.0);"
        "else if(hp<3.0)rgb=vec3(0.0,c,x); else if(hp<4.0)rgb=vec3(0.0,x,c);"
        "else if(hp<5.0)rgb=vec3(x,0.0,c); else rgb=vec3(c,0.0,x);"
        "return rgb + vec3(hsl.z-c*0.5); }"
        "vec3 rgbToHsl(vec3 rgb){"
        "rgb=clamp(rgb,0.0,1.0);"
        "float hi=max(max(rgb.r,rgb.g),rgb.b); float lo=min(min(rgb.r,rgb.g),rgb.b);"
        "float d=hi-lo; float l=(hi+lo)*0.5; if(d<0.00001)return vec3(0.0,0.0,l);"
        "float s=d/(1.0-abs(2.0*l-1.0)); float h;"
         "if(hi==rgb.r)h=mod((rgb.g-rgb.b)/d,6.0); else if(hi==rgb.g)h=(rgb.b-rgb.r)/d+2.0;"
          "else h=(rgb.r-rgb.g)/d+4.0; return vec3(wrap01(h/6.0),s,l); }"
          // GLES 2.0 drivers (including the HarmonyOS emulator translator)
          // reject non-constant indexing of uniform arrays. Keep the eight
          // HSL channels in uniforms, but select them through constant-index
          // branches so the shader also compiles on ES 2.0 hardware.
          "float mixHueAt(float channel){if(channel<0.5)return uMixHue[0];if(channel<1.5)return uMixHue[1];if(channel<2.5)return uMixHue[2];if(channel<3.5)return uMixHue[3];if(channel<4.5)return uMixHue[4];if(channel<5.5)return uMixHue[5];if(channel<6.5)return uMixHue[6];return uMixHue[7];}"
          "float mixSaturationAt(float channel){if(channel<0.5)return uMixSaturation[0];if(channel<1.5)return uMixSaturation[1];if(channel<2.5)return uMixSaturation[2];if(channel<3.5)return uMixSaturation[3];if(channel<4.5)return uMixSaturation[4];if(channel<5.5)return uMixSaturation[5];if(channel<6.5)return uMixSaturation[6];return uMixSaturation[7];}"
          "float mixLuminanceAt(float channel){if(channel<0.5)return uMixLuminance[0];if(channel<1.5)return uMixLuminance[1];if(channel<2.5)return uMixLuminance[2];if(channel<3.5)return uMixLuminance[3];if(channel<4.5)return uMixLuminance[4];if(channel<5.5)return uMixLuminance[5];if(channel<6.5)return uMixLuminance[6];return uMixLuminance[7];}"
          "float blendedHue(float h){float p=wrap01(h)*8.0;float c=floor(p);return mix(mixHueAt(c),mixHueAt(mod(c+1.0,8.0)),fract(p));}"
          "float blendedSat(float h){float p=wrap01(h)*8.0;float c=floor(p);return mix(mixSaturationAt(c),mixSaturationAt(mod(c+1.0,8.0)),fract(p));}"
          "float blendedLum(float h){float p=wrap01(h)*8.0;float c=floor(p);return mix(mixLuminanceAt(c),mixLuminanceAt(mod(c+1.0,8.0)),fract(p));}"
          "float tonalRange(float v,float a,float w,float strength){float d=a>=0.0?(1.0-v)*a:v*a;return clamp(v+d*w*strength,0.0,1.0);}"
          "vec3 applyTonal(vec3 rgb){float lum=clamp(dot(rgb,vec3(0.2126,0.7152,0.0722)),0.0,1.0);float v=lum;"
          "v=tonalRange(v,uTonal.x,1.0-smoothstep(0.16,0.58,v),0.62);"
          "v=tonalRange(v,uTonal.y,1.0-smoothstep(0.025,0.27,v),0.78);"
          "v=tonalRange(v,uTonal.z,smoothstep(0.42,0.88,v),0.62);"
          "v=tonalRange(v,uTonal.w,smoothstep(0.72,0.985,v),0.78);"
          "return lum>0.00001?clamp(rgb*(v/lum),0.0,1.0):vec3(v);}"
          "float toLinear(float v){v=clamp(v,0.0,1.0);return v<=0.04045?v/12.92:pow((v+0.055)/1.055,2.4);}"
          "float toSrgb(float v){v=max(0.0,v);return clamp(v<=0.0031308?v*12.92:1.055*pow(v,1.0/2.4)-0.055,0.0,1.0);}"
          "vec3 applyWb(vec3 rgb){if(uWbEnabled<0.5&&uExposureGain==1.0)return rgb;"
          "vec3 gain=vec3(uExposureGain)*(uWbEnabled>0.5?uWbGain:vec3(1.0));"
          "vec3 linear=vec3(toLinear(rgb.r),toLinear(rgb.g),toLinear(rgb.b))*gain;return vec3(toSrgb(linear.r),toSrgb(linear.g),toSrgb(linear.b));}"
          "vec3 applyVibrance(vec3 rgb){if(abs(uVibrance)<0.00001)return rgb;vec3 h=rgbToHsl(rgb);"
          "h.y=clamp(uVibrance>0.0?h.y+(1.0-h.y)*uVibrance*0.80:h.y*(1.0+uVibrance*0.70),0.0,1.0);return hslToRgb(h);}"
          "vec3 applyCalibration(vec3 rgb){vec3 c=rgb;"
          "c.r+=uCalibrationSaturation.r*(rgb.r-(rgb.g+rgb.b)*0.5)*0.45;"
          "c.g+=uCalibrationSaturation.g*(rgb.g-(rgb.r+rgb.b)*0.5)*0.45;"
          "c.b+=uCalibrationSaturation.b*(rgb.b-(rgb.r+rgb.g)*0.5)*0.45;"
          "c.g+=rgb.r*uCalibrationHue.r*0.14-rgb.b*uCalibrationHue.b*0.07;"
          "c.b-=rgb.r*uCalibrationHue.r*0.14-rgb.g*uCalibrationHue.g*0.07;"
          "c.r+=rgb.g*uCalibrationHue.g*0.14-rgb.b*uCalibrationHue.b*0.07;return c;}"
          "float unpackCurve(vec4 encoded){return (encoded.r*65280.0+encoded.g*255.0)/65535.0;}"
          "float sampleCurve(sampler2D tex,float value){float p=clamp(value,0.0,1.0)*1024.0;float lo=floor(p);"
          "float a=unpackCurve(texture2D(tex,vec2((lo+0.5)/1025.0,0.5)));"
          "float b=unpackCurve(texture2D(tex,vec2((min(lo+1.0,1024.0)+0.5)/1025.0,0.5)));return mix(a,b,fract(p));}"
          "vec2 lutUv(vec3 index,float size){return vec2((index.r+index.g*size+0.5)/(size*size),(index.b+0.5)/size);}"
         "vec3 sampleLut3d(vec3 rgb){"
         "float size=max(2.0,uLutSize); vec3 p=clamp((rgb-uLutDomainMin)*uLutDomainScale,0.0,1.0)*(size-1.0);"
         "vec3 i0=floor(p); vec3 i1=min(i0+1.0,vec3(size-1.0)); vec3 f=fract(p);"
         "vec3 c000=texture2D(uLut,lutUv(vec3(i0.r,i0.g,i0.b),size)).rgb;"
         "vec3 c100=texture2D(uLut,lutUv(vec3(i1.r,i0.g,i0.b),size)).rgb;"
         "vec3 c010=texture2D(uLut,lutUv(vec3(i0.r,i1.g,i0.b),size)).rgb;"
         "vec3 c110=texture2D(uLut,lutUv(vec3(i1.r,i1.g,i0.b),size)).rgb;"
         "vec3 c001=texture2D(uLut,lutUv(vec3(i0.r,i0.g,i1.b),size)).rgb;"
         "vec3 c101=texture2D(uLut,lutUv(vec3(i1.r,i0.g,i1.b),size)).rgb;"
         "vec3 c011=texture2D(uLut,lutUv(vec3(i0.r,i1.g,i1.b),size)).rgb;"
         "vec3 c111=texture2D(uLut,lutUv(vec3(i1.r,i1.g,i1.b),size)).rgb;"
         "vec3 x00=mix(c000,c100,f.r); vec3 x10=mix(c010,c110,f.r);"
         "vec3 x01=mix(c001,c101,f.r); vec3 x11=mix(c011,c111,f.r);"
         "return mix(mix(x00,x10,f.g),mix(x01,x11,f.g),f.b); }"
         "float gradeChannel(float value,float target,float saturation,float luminance,float weight){"
         "if(weight<=0.0 || (abs(saturation)<0.00001 && abs(luminance)<0.00001))return value;"
         "float tintAmount=clamp(abs(saturation)*weight*0.62,0.0,1.0);"
         "float direction=saturation<0.0?-1.0:1.0;"
         "float tinted=value+(target-value)*tintAmount*direction;"
         "return clamp(tinted+luminance*weight*0.28,0.0,1.0); }"
         "vec3 applyGrading(vec3 rgb){"
         "if(uGradingEnabled<0.5)return rgb;"
         "float lum=clamp(dot(rgb,vec3(0.2126,0.7152,0.0722)),0.0,1.0);"
         "float sw=clamp(1.0-lum*2.0,0.0,1.0);"
         "float hw=clamp((lum-0.5)*2.0,0.0,1.0);"
         "float mw=clamp(1.0-abs(lum-0.5)*2.0,0.0,1.0);"
         "float balance=clamp(uGradingBalance,-1.0,1.0);"
         "sw=clamp(sw*(1.0-max(balance,0.0)*0.65+max(-balance,0.0)*0.65),0.0,1.0);"
         "hw=clamp(hw*(1.0+max(balance,0.0)*0.65-max(-balance,0.0)*0.65),0.0,1.0);"
         "mw=clamp(mw*(0.78+(1.0-abs(balance))*0.22),0.0,1.0);"
         "float blend=0.55+clamp(uGradingBlending,-1.0,1.0)*0.45;"
         "float w=sw*blend; rgb.r=gradeChannel(rgb.r,uGradingShadowsTarget.r,uGradingShadowsSaturation,uGradingShadowsLuminance,w);"
         "rgb.g=gradeChannel(rgb.g,uGradingShadowsTarget.g,uGradingShadowsSaturation,uGradingShadowsLuminance,w);"
         "rgb.b=gradeChannel(rgb.b,uGradingShadowsTarget.b,uGradingShadowsSaturation,uGradingShadowsLuminance,w);"
         "w=mw*blend; rgb.r=gradeChannel(rgb.r,uGradingMidtonesTarget.r,uGradingMidtonesSaturation,uGradingMidtonesLuminance,w);"
         "rgb.g=gradeChannel(rgb.g,uGradingMidtonesTarget.g,uGradingMidtonesSaturation,uGradingMidtonesLuminance,w);"
         "rgb.b=gradeChannel(rgb.b,uGradingMidtonesTarget.b,uGradingMidtonesSaturation,uGradingMidtonesLuminance,w);"
         "w=hw*blend; rgb.r=gradeChannel(rgb.r,uGradingHighlightsTarget.r,uGradingHighlightsSaturation,uGradingHighlightsLuminance,w);"
         "rgb.g=gradeChannel(rgb.g,uGradingHighlightsTarget.g,uGradingHighlightsSaturation,uGradingHighlightsLuminance,w);"
         "rgb.b=gradeChannel(rgb.b,uGradingHighlightsTarget.b,uGradingHighlightsSaturation,uGradingHighlightsLuminance,w);"
         "w=0.52*blend; rgb.r=gradeChannel(rgb.r,uGradingGlobalTarget.r,uGradingGlobalSaturation,uGradingGlobalLuminance,w);"
         "rgb.g=gradeChannel(rgb.g,uGradingGlobalTarget.g,uGradingGlobalSaturation,uGradingGlobalLuminance,w);"
         "rgb.b=gradeChannel(rgb.b,uGradingGlobalTarget.b,uGradingGlobalSaturation,uGradingGlobalLuminance,w);"
         "return rgb; }"
        // Same resolution-relative bounded log-luminance/chromaticity filter as
        // NoiseReduction.ets. The spatial Gaussian is scaled by the frame long
        // edge (denoiseSpatialRadius there), because with a pixel-sized window a
        // 2048px preview would cover ~3x more of the scene than the full-size
        // export and would therefore look far cleaner than what is exported.
        // Keep the reference 2048 and the cap 5 in sync with
        // DENOISE_REFERENCE_LONG_EDGE / DENOISE_MAX_RADIUS in NoiseReduction.ets.
        "vec3 nrLinear(vec3 c){return vec3(c.r<=0.04045?c.r/12.92:pow((c.r+0.055)/1.055,2.4),"
        "c.g<=0.04045?c.g/12.92:pow((c.g+0.055)/1.055,2.4),c.b<=0.04045?c.b/12.92:pow((c.b+0.055)/1.055,2.4));}"
        "vec3 nrEncode(vec3 c){c=clamp(c,0.,1.);return vec3(c.r<=0.0031308?12.92*c.r:1.055*pow(c.r,1./2.4)-0.055,"
        "c.g<=0.0031308?12.92*c.g:1.055*pow(c.g,1./2.4)-0.055,c.b<=0.0031308?12.92*c.b:1.055*pow(c.b,1./2.4)-0.055);}"
        "float nrRadius(){return clamp(floor(2.*max(uFrameSize.x,uFrameSize.y)/2048.+.5),2.,5.);}"
        "vec3 reduceNoise(vec3 c){vec3 rgb=nrLinear(c);vec3 luma=vec3(.2126,.7152,.0722);"
        "float light=max(.00001,dot(rgb,luma));float ly=log2(light);vec3 chroma=rgb/light;"
        "float sl=.08+.55*uDenoise.x*(1.-.8*uDenoise.z);float sc=.1+.65*uDenoise.y*(1.-.8*uDenoise.w);"
        "float radius=nrRadius();float ss=radius*.5;"
        "float sumL=0.,wl=0.,wc=0.;vec3 sumC=vec3(0.);"
        // GLES2 requires constant loop bounds, so the frame-relative window is
        // walked with break/continue over the fixed maximum span. Offsets past
        // the radius are skipped, never accumulated as zero-weight taps, so the
        // summation order stays identical to the CPU kernel and the preview keeps
        // its original 5x5 cost.
        "for(int y=-5;y<=5;y++){if(y>0&&float(y)>radius)break;if(abs(float(y))>radius)continue;"
        "for(int x=-5;x<=5;x++){if(x>0&&float(x)>radius)break;if(abs(float(x))>radius)continue;"
        "vec2 off=vec2(float(x),float(y));"
        "vec3 n=nrLinear(texture2D(uImage,vUv+off/uFrameSize).rgb);float nl=max(.00001,dot(n,luma));"
        "float ny=log2(nl),d=ny-ly;float s=exp(-.5*dot(off,off)/(ss*ss));"
        "float a=s/(1.+(d/sl)*(d/sl)),b=s/(1.+(d/sc)*(d/sc));"
        "sumL+=ny*a;wl+=a;sumC+=(n/nl)*b;wc+=b;}}"
        "float target=exp2(ly+(sumL/wl-ly)*sqrt(uDenoise.x));"
        "vec3 mixed=mix(chroma,sumC/wc,uDenoise.y*(1.-.5*uDenoise.w));"
        "return nrEncode(mixed*(target/max(.00001,dot(mixed,luma))));}"
         "void main(){"
        "if(uDenoise.x>0.||uDenoise.y>0.){vec4 n=texture2D(uImage,vUv);gl_FragColor=vec4(reduceNoise(n.rgb),n.a);return;}"
        "vec4 source=texture2D(uImage,vUv); vec4 mapped=uMatrix*source+uOffset;"
         "mapped=clamp(mapped,0.0,1.0);mapped.rgb=floor(mapped.rgb*255.0+0.5)/255.0;"
         "mapped.rgb=applyCalibration(applyVibrance(applyTonal(applyWb(mapped.rgb))));"
         "if(uMixerEnabled>0.5){vec3 hsl=rgbToHsl(mapped.rgb);"
         "hsl.x=wrap01(hsl.x+blendedHue(hsl.x)/15.0);"
         "hsl.y=clamp(hsl.y*(1.0+blendedSat(hsl.x)),0.0,1.0);"
         "hsl.z=clamp(hsl.z+blendedLum(hsl.x)*0.32,0.0,1.0); mapped.rgb=hslToRgb(hsl);}"
         "mapped.r=sampleCurve(uRedCurve,sampleCurve(uToneCurve,mapped.r));"
         "mapped.g=sampleCurve(uGreenCurve,sampleCurve(uToneCurve,mapped.g));"
         "mapped.b=sampleCurve(uBlueCurve,sampleCurve(uToneCurve,mapped.b));"
         // Parametric curve shares the tone-curve stage, exactly as on the CPU.
         // Refinement is measured from this pixel's before/after saturation, not
         // from the curve's slope at its luminance: the curve is applied per
         // channel, so a colour can gain saturation while its luminance is
         // outside the steep region, where a luminance-keyed factor would be 1
         // and would silently fail to refine it.
         "if(uParametricEnabled>0.5){"
         "vec3 parametricIn=mapped.rgb;"
         "mapped.r=sampleCurve(uParametricCurve,mapped.r);"
         "mapped.g=sampleCurve(uParametricCurve,mapped.g);"
         "mapped.b=sampleCurve(uParametricCurve,mapped.b);"
         "if(uParametricRefine<0.9999){"
         "float hiBefore=max(parametricIn.r,max(parametricIn.g,parametricIn.b));"
         "float loBefore=min(parametricIn.r,min(parametricIn.g,parametricIn.b));"
         "float satBefore=hiBefore>0.0?(hiBefore-loBefore)/hiBefore:0.0;"
         "float hiAfter=max(mapped.r,max(mapped.g,mapped.b));"
         "float loAfter=min(mapped.r,min(mapped.g,mapped.b));"
         "float satAfter=hiAfter>0.0?(hiAfter-loAfter)/hiAfter:0.0;"
         "if(satAfter>0.0001 && satAfter>satBefore){"
         "float scale=1.0+(uParametricRefine-1.0)*(satAfter-satBefore)/satAfter;"
         "float curvedLuma=dot(mapped.rgb,vec3(0.2126,0.7152,0.0722));"
         "mapped.rgb=clamp(vec3(curvedLuma)+(mapped.rgb-vec3(curvedLuma))*scale,0.0,1.0);}}}"
         "mapped.rgb=applyGrading(mapped.rgb);"
         // SpatialEffects consumes the quantised colour result on the CPU.
         // Match that boundary before vignette, then grain, then layer blend.
         "if(uVignette.x!=0.0 || uGrain.x>0.0){"
         "mapped.rgb=floor(clamp(mapped.rgb,0.0,1.0)*255.0+0.5)/255.0;"
         "if(uVignette.x!=0.0){float roundness=clamp(uVignette.z,-1.0,1.0);"
         "vec2 n=abs(vUv*2.0-1.0);float shortSide=min(uFrameSize.x,uFrameSize.y);"
         "vec2 s=n*(vec2(1.0)+max(0.0,roundness)*(uFrameSize/shortSide-vec2(1.0)));"
         "float p=2.0+max(0.0,-roundness)*6.0;float radius=pow(pow(s.x,p)+pow(s.y,p),1.0/p);"
         "float outer=0.35+clamp(uVignette.y,0.0,1.0)*0.95;"
         "float inner=outer*(1.0-0.98*clamp(uVignette.w,0.0,1.0));"
         "float t=clamp((radius-inner)/max(0.005,outer-inner),0.0,1.0);"
         "float strength=min(1.0,abs(uVignette.x))*t*t*(3.0-2.0*t);"
         "float lum=clamp(dot(mapped.rgb,vec3(0.2126,0.7152,0.0722)),0.0,1.0);"
         "if(uVignette.x<0.0){strength*=1.0-clamp(uVignetteHighlights,0.0,1.0)*smoothstep(0.52,0.98,lum);"
         "mapped.rgb*=exp2(-3.0*strength);}else mapped.rgb+=(vec3(1.0)-mapped.rgb)*strength;}"
         "if(uGrain.x>0.0){vec4 noiseBytes=texture2D(uGrainNoise,vUv);"
         "vec2 samples=vec2(noiseBytes.r*65280.0+noiseBytes.g*255.0,noiseBytes.b*65280.0+noiseBytes.a*255.0)/65535.0*2.0-1.0;"
         "float rough=clamp(uGrain.z,0.0,1.0)*0.45;float sampleNoise=mix(samples.x,samples.y,rough);"
         "float lum=clamp(dot(mapped.rgb,vec3(0.2126,0.7152,0.0722)),0.0,1.0);"
         "float amplitude=clamp(uGrain.x,0.0,1.0)*0.22*(0.3+0.7*sqrt(4.0*lum*(1.0-lum)));"
         "mapped.rgb+=vec3(sampleNoise*amplitude);}"
         "mapped.rgb=floor(clamp(mapped.rgb,0.0,1.0)*255.0+0.5)/255.0;}"
        "float alpha=uOpacity; if(uMaskEnabled>0.5)alpha*=texture2D(uMask,vUv).r*uMaskOpacity;"
        "if(uBlendMode==1)mapped.rgb=source.rgb*mapped.rgb;"
        "else if(uBlendMode==2)mapped.rgb=1.0-(1.0-source.rgb)*(1.0-mapped.rgb);"
        "else if(uBlendMode==3)mapped.rgb=mix(2.0*source.rgb*mapped.rgb,1.0-2.0*(1.0-source.rgb)*(1.0-mapped.rgb),step(vec3(0.5),source.rgb));"
        "mapped.rgb=mix(source.rgb,mapped.rgb,clamp(alpha,0.0,1.0));"
        "if(uLutEnabled>0.5)mapped.rgb=mix(mapped.rgb,sampleLut3d(mapped.rgb),uLutIntensity);"
        "gl_FragColor=vec4(clamp(mapped.rgb,0.0,1.0),source.a); }";
    const GLuint vertex = compileShader(GL_VERTEX_SHADER, vertexSource, error);
    if (vertex == 0) return 0;
    const GLuint fragment = compileShader(GL_FRAGMENT_SHADER, fragmentSource, error);
    if (fragment == 0) {
        glDeleteShader(vertex);
        return 0;
    }
    const GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glBindAttribLocation(program, 0, "aPosition");
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint status = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status == GL_TRUE) return program;
    error = "shader link failed";
    glDeleteProgram(program);
    return 0;
}

static GLuint uploadTexture(GLenum format, uint32_t width, uint32_t height, const void* data)
{
    // The LUT atlas is RGBA16F: extended-range .cube values must survive the
    // upload, and GLES3 only guarantees a 16F internal format with RGBA.
    // Halves are packed by the ArkTS side; every other texture stays RGBA8.
    const bool halfFloat = format == GL_RGBA16F;
    const GLenum externalFormat = halfFloat ? GL_RGBA : format;
    const GLenum type = halfFloat ? GL_HALF_FLOAT : GL_UNSIGNED_BYTE;
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, format, static_cast<GLsizei>(width), static_cast<GLsizei>(height),
        0, externalFormat, type, data);
    return texture;
}

// Keep the JS uint32 hash exactly, rather than use the usual sin() shader
// noise which differs across drivers and between preview/export resolutions.
static double grainHash(int32_t x, int32_t y)
{
    uint32_t n = static_cast<uint32_t>(x) * 374761393U ^ static_cast<uint32_t>(y) * 668265263U;
    n = (n ^ (n >> 13)) * 1274126177U;
    return static_cast<double>(n ^ (n >> 16)) / 4294967295.0 * 2.0 - 1.0;
}

static double grainNoise(double x, double y)
{
    const auto ix = static_cast<int32_t>(std::floor(x)), iy = static_cast<int32_t>(std::floor(y));
    const double fx = x - ix, fy = y - iy;
    const double u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy);
    const double a = grainHash(ix, iy), b = grainHash(ix + 1, iy);
    const double c = grainHash(ix, iy + 1), d = grainHash(ix + 1, iy + 1);
    return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v;
}

static GLuint makeGrainTexture(uint32_t width, uint32_t height, float grainSize)
{
    const double cell = (0.8 + std::clamp(static_cast<double>(grainSize), 0.0, 1.0) * 5.2) *
        std::max(width, height) / 1600.0;
    std::vector<uint8_t> bytes(static_cast<size_t>(width) * height * 4);
    for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
        const double gx = (x + 0.5) / cell, gy = (y + 0.5) / cell;
        const double samples[2] = {grainNoise(gx, gy), grainNoise(gx * 2.17 + 31.7, gy * 2.17 + 19.3)};
        const size_t index = (static_cast<size_t>(y) * width + x) * 4;
        for (size_t c = 0; c < 2; ++c) {
            const uint32_t packed = static_cast<uint32_t>(std::round(std::clamp((samples[c] + 1) * 0.5, 0.0, 1.0) * 65535));
            bytes[index + c * 2] = static_cast<uint8_t>(packed >> 8);
            bytes[index + c * 2 + 1] = static_cast<uint8_t>(packed & 255);
        }
    }
    const GLuint texture = uploadTexture(GL_RGBA, width, height, bytes.data());
    // Packed high/low bytes must never be interpolated separately.
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    return texture;
}

static void spatialUniforms(GLuint program, const RenderWork& work, uint32_t width, uint32_t height, GLuint noise)
{
    glUniform4fv(glGetUniformLocation(program, "uVignette"), 1, work.vignette);
    glUniform1f(glGetUniformLocation(program, "uVignetteHighlights"), work.vignette[4]);
    glUniform3fv(glGetUniformLocation(program, "uGrain"), 1, work.grain);
    glUniform2f(glGetUniformLocation(program, "uFrameSize"), width, height);
    glActiveTexture(GL_TEXTURE7); glBindTexture(GL_TEXTURE_2D, noise);
    glUniform1i(glGetUniformLocation(program, "uGrainNoise"), 7);
}

static bool renderWithGpu(RenderWork& work)
{
    const EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) { work.error = "EGL display unavailable"; return false; }
    if (eglInitialize(display, nullptr, nullptr) != EGL_TRUE) { work.error = "EGL initialize failed"; return false; }
    // EGL defaults to the platform's previously bound client API on some
    // HarmonyOS builds (often OpenVG). Bind OpenGL ES explicitly before
    // choosing an ES2 config, otherwise glCreateShader is reported as an
    // invalid call even though the EGL context was created successfully.
    if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
        work.error = "EGL OpenGL ES API unavailable";
        eglTerminate(display);
        return false;
    }
    const EGLint configAttributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLConfig config = nullptr;
    EGLint configCount = 0;
    if (eglChooseConfig(display, configAttributes, &config, 1, &configCount) != EGL_TRUE || configCount == 0) {
        work.error = "EGL config unavailable"; eglTerminate(display); return false;
    }
    const EGLint surfaceAttributes[] = {
        EGL_WIDTH, static_cast<EGLint>(work.width), EGL_HEIGHT, static_cast<EGLint>(work.height), EGL_NONE,
    };
    const EGLSurface surface = eglCreatePbufferSurface(display, config, surfaceAttributes);
    const EGLint contextAttributes[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    const EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
    if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT ||
        eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
        work.error = "EGL context unavailable";
        if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
        if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
        eglTerminate(display); return false;
    }
    if (glGetString(GL_VERSION) == nullptr) {
        work.error = "OpenGL ES context not current";
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(display, context); eglDestroySurface(display, surface); eglTerminate(display);
        return false;
    }
    // GL_RGB LUT slices and single-channel mask rows are not 4-byte aligned
    // for odd sizes (e.g. 33*3 bytes per row). The default UNPACK_ALIGNMENT
    // of 4 makes glTexImage2D skip bytes and garble those textures; tight
    // packing keeps every upload byte-exact.
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

    std::string shaderError;
    const GLuint program = makeProgram(shaderError);
    if (program == 0) {
        work.error = shaderError;
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(display, context); eglDestroySurface(display, surface); eglTerminate(display);
        return false;
    }
    const GLuint imageTexture = uploadTexture(GL_RGBA, work.width, work.height, work.input.data());
    const GLuint toneTexture = uploadTexture(GL_RGBA, 1025, 1, work.toneCurve.data());
    const GLuint redTexture = uploadTexture(GL_RGBA, 1025, 1, work.redCurve.data());
    const GLuint greenTexture = uploadTexture(GL_RGBA, 1025, 1, work.greenCurve.data());
    const GLuint blueTexture = uploadTexture(GL_RGBA, 1025, 1, work.blueCurve.data());
    // When the parametric curve is the identity the tone texture is reused, so
    // no extra upload happens on the common path.
    const GLuint parametricTexture = work.parametricEnabled
        ? uploadTexture(GL_RGBA, 1025, 1, work.parametricCurve.data()) : toneTexture;
    GLuint lutTexture = 0;
    if (work.lutEnabled) {
        lutTexture = uploadTexture(GL_RGB, static_cast<GLsizei>(work.lutSize * work.lutSize),
            static_cast<GLsizei>(work.lutSize), work.lut.data());
    }
    GLuint maskTexture = 0;
    if (work.maskEnabled) maskTexture = uploadTexture(GL_LUMINANCE, work.maskWidth, work.maskHeight, work.mask.data());
    const GLuint grainTexture = work.grain[0] > 0 ? makeGrainTexture(work.width, work.height, work.grain[1]) : toneTexture;

    GLuint outputTexture = 0;
    glGenTextures(1, &outputTexture);
    glBindTexture(GL_TEXTURE_2D, outputTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, static_cast<GLsizei>(work.width), static_cast<GLsizei>(work.height),
        0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    GLuint framebuffer = 0;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, outputTexture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        work.error = "GPU framebuffer unavailable";
    } else {
        glUseProgram(program);
        const GLfloat vertices[] = { -1.0f, -1.0f, 3.0f, -1.0f, -1.0f, 3.0f };
        glViewport(0, 0, static_cast<GLsizei>(work.width), static_cast<GLsizei>(work.height));
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
        glEnableVertexAttribArray(0);
        const GLint imageUnit = glGetUniformLocation(program, "uImage");
        const GLint toneUnit = glGetUniformLocation(program, "uToneCurve");
        const GLint redUnit = glGetUniformLocation(program, "uRedCurve");
        const GLint greenUnit = glGetUniformLocation(program, "uGreenCurve");
        const GLint blueUnit = glGetUniformLocation(program, "uBlueCurve");
        const GLint parametricUnit = glGetUniformLocation(program, "uParametricCurve");
        const GLint lutUnit = glGetUniformLocation(program, "uLut");
        const GLint lutSizeUnit = glGetUniformLocation(program, "uLutSize");
        const GLint maskUnit = glGetUniformLocation(program, "uMask");
        glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, imageTexture); glUniform1i(imageUnit, 0);
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, toneTexture); glUniform1i(toneUnit, 1);
        glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, redTexture); glUniform1i(redUnit, 2);
        glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, greenTexture); glUniform1i(greenUnit, 3);
        glActiveTexture(GL_TEXTURE4); glBindTexture(GL_TEXTURE_2D, blueTexture); glUniform1i(blueUnit, 4);
        glActiveTexture(GL_TEXTURE7); glBindTexture(GL_TEXTURE_2D, parametricTexture); glUniform1i(parametricUnit, 7);
        glUniform1f(glGetUniformLocation(program, "uParametricEnabled"), work.parametricEnabled ? 1.0f : 0.0f);
        glUniform1f(glGetUniformLocation(program, "uParametricRefine"), work.parametricRefine);
        if (lutTexture != 0) { glActiveTexture(GL_TEXTURE5); glBindTexture(GL_TEXTURE_2D, lutTexture); }
         glUniform1i(lutUnit, 5);
         glUniform1f(lutSizeUnit, static_cast<GLfloat>(work.lutSize));
        if (maskTexture != 0) { glActiveTexture(GL_TEXTURE6); glBindTexture(GL_TEXTURE_2D, maskTexture); }
        glUniform1i(maskUnit, 6);
        const GLfloat matrix4[] = {
            work.matrix[0], work.matrix[5], work.matrix[10], work.matrix[15],
            work.matrix[1], work.matrix[6], work.matrix[11], work.matrix[16],
            work.matrix[2], work.matrix[7], work.matrix[12], work.matrix[17],
            work.matrix[3], work.matrix[8], work.matrix[13], work.matrix[18],
        };
        const GLfloat offset[] = {
            work.matrix[4] / 255.0f, work.matrix[9] / 255.0f,
            work.matrix[14] / 255.0f, work.matrix[19] / 255.0f,
        };
        glUniformMatrix4fv(glGetUniformLocation(program, "uMatrix"), 1, GL_FALSE, matrix4);
        glUniform4fv(glGetUniformLocation(program, "uOffset"), 1, offset);
        glUniform1f(glGetUniformLocation(program, "uLutEnabled"), work.lutEnabled ? 1.0f : 0.0f);
        glUniform1f(glGetUniformLocation(program, "uMaskEnabled"), work.maskEnabled ? 1.0f : 0.0f);
        glUniform1f(glGetUniformLocation(program, "uMaskOpacity"), work.maskOpacity);
        glUniform1f(glGetUniformLocation(program, "uOpacity"), work.opacity);
        glUniform1f(glGetUniformLocation(program, "uLutIntensity"), work.lutIntensity);
        glUniform1i(glGetUniformLocation(program, "uBlendMode"), work.blendMode);
        glUniform1fv(glGetUniformLocation(program, "uMixHue"), 8, work.mixHue);
        glUniform1fv(glGetUniformLocation(program, "uMixSaturation"), 8, work.mixSaturation);
        glUniform1fv(glGetUniformLocation(program, "uMixLuminance"), 8, work.mixLuminance);
        glUniform3fv(glGetUniformLocation(program, "uGradingShadowsTarget"), 1, work.gradingShadowsTarget);
        glUniform3fv(glGetUniformLocation(program, "uGradingMidtonesTarget"), 1, work.gradingMidtonesTarget);
        glUniform3fv(glGetUniformLocation(program, "uGradingHighlightsTarget"), 1, work.gradingHighlightsTarget);
        glUniform3fv(glGetUniformLocation(program, "uGradingGlobalTarget"), 1, work.gradingGlobalTarget);
        glUniform1f(glGetUniformLocation(program, "uGradingShadowsSaturation"), work.gradingShadowsSaturation);
        glUniform1f(glGetUniformLocation(program, "uGradingShadowsLuminance"), work.gradingShadowsLuminance);
        glUniform1f(glGetUniformLocation(program, "uGradingMidtonesSaturation"), work.gradingMidtonesSaturation);
        glUniform1f(glGetUniformLocation(program, "uGradingMidtonesLuminance"), work.gradingMidtonesLuminance);
        glUniform1f(glGetUniformLocation(program, "uGradingHighlightsSaturation"), work.gradingHighlightsSaturation);
        glUniform1f(glGetUniformLocation(program, "uGradingHighlightsLuminance"), work.gradingHighlightsLuminance);
        glUniform1f(glGetUniformLocation(program, "uGradingGlobalSaturation"), work.gradingGlobalSaturation);
        glUniform1f(glGetUniformLocation(program, "uGradingGlobalLuminance"), work.gradingGlobalLuminance);
        glUniform1f(glGetUniformLocation(program, "uGradingBlending"), work.gradingBlending);
        glUniform1f(glGetUniformLocation(program, "uGradingBalance"), work.gradingBalance);
        glUniform1f(glGetUniformLocation(program, "uGradingEnabled"), work.gradingEnabled ? 1.0f : 0.0f);
        glUniform4fv(glGetUniformLocation(program, "uTonal"), 1, work.tonal);
        glUniform3fv(glGetUniformLocation(program, "uWbGain"), 1, work.whiteBalanceGain);
        glUniform1f(glGetUniformLocation(program, "uExposureGain"), work.exposureGain);
        glUniform3fv(glGetUniformLocation(program, "uLutDomainMin"), 1, work.lutDomainMin);
        glUniform3fv(glGetUniformLocation(program, "uLutDomainScale"), 1, work.lutDomainScale);
        glUniform1f(glGetUniformLocation(program, "uWbEnabled"), work.whiteBalanceEnabled ? 1.0f : 0.0f);
        glUniform1f(glGetUniformLocation(program, "uVibrance"), work.vibrance);
        glUniform3fv(glGetUniformLocation(program, "uCalibrationHue"), 1, work.calibrationHue);
        glUniform3fv(glGetUniformLocation(program, "uCalibrationSaturation"), 1, work.calibrationSaturation);
        glUniform1f(glGetUniformLocation(program, "uMixerEnabled"), work.mixerEnabled ? 1.0f : 0.0f);
        spatialUniforms(program, work, work.width, work.height, grainTexture);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glFinish();
        std::vector<uint8_t> bottomUp(work.input.size());
        glReadPixels(0, 0, static_cast<GLsizei>(work.width), static_cast<GLsizei>(work.height),
            GL_RGBA, GL_UNSIGNED_BYTE, bottomUp.data());
        work.output.resize(bottomUp.size());
        work.output = std::move(bottomUp);
    }
    if (maskTexture != 0) glDeleteTextures(1, &maskTexture);
    if (lutTexture != 0) glDeleteTextures(1, &lutTexture);
    if (work.grain[0] > 0) glDeleteTextures(1, &grainTexture);
    glDeleteTextures(1, &outputTexture);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &imageTexture); glDeleteTextures(1, &toneTexture);
    glDeleteTextures(1, &redTexture); glDeleteTextures(1, &greenTexture); glDeleteTextures(1, &blueTexture);
    glDeleteProgram(program);
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context); eglDestroySurface(display, surface); eglTerminate(display);
    return work.error.empty() && !work.output.empty();
}

static void executeRender(napi_env /*env*/, void* data)
{
    auto* work = static_cast<RenderWork*>(data);
    if (!renderWithGpu(*work)) {
        if (work->error.empty()) work->error = "GPU render failed";
    }
}

static void completeRender(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<RenderWork*>(data);
    if (status == napi_ok && work->error.empty() && !work->output.empty()) {
        napi_value result = nullptr;
        void* destination = nullptr;
        napi_create_arraybuffer(env, work->output.size(), &destination, &result);
        if (destination != nullptr) std::memcpy(destination, work->output.data(), work->output.size());
        napi_resolve_deferred(env, work->deferred, result);
    } else {
        napi_value message = nullptr;
        napi_create_string_utf8(env, work->error.empty() ? "GPU render cancelled" : work->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_reject_deferred(env, work->deferred, message);
    }
    napi_delete_async_work(env, work->asyncWork);
    delete work;
}

static napi_value capabilities(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value available = nullptr;
    napi_get_boolean(env, true, &available);
    napi_set_named_property(env, result, "available", available);
    napi_value renderer = nullptr;
    napi_create_string_utf8(env, "OpenGL ES 2.0", NAPI_AUTO_LENGTH, &renderer);
    napi_set_named_property(env, result, "renderer", renderer);
    napi_value backend = nullptr;
    napi_create_string_utf8(env, "EGL pbuffer shader", NAPI_AUTO_LENGTH, &backend);
    napi_set_named_property(env, result, "backend", backend);
    return result;
}

static napi_value renderRgba(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 4) return nullptr;
    bool isBuffer = false;
    if (napi_is_arraybuffer(env, args[0], &isBuffer) != napi_ok || !isBuffer) return nullptr;
    uint32_t width = 0;
    uint32_t height = 0;
    if (napi_get_value_uint32(env, args[1], &width) != napi_ok || napi_get_value_uint32(env, args[2], &height) != napi_ok ||
        width == 0 || height == 0) return nullptr;
    auto* work = new RenderWork();
    work->env = env; work->width = width; work->height = height;
    if (!copyArrayBuffer(env, args[0], work->input, static_cast<size_t>(width) * height * 4)) { delete work; return nullptr; }
    napi_value matrixValue = nullptr;
    if (!getNamed(env, args[3], "matrix", &matrixValue)) { delete work; return nullptr; }
    void* matrixData = nullptr; size_t matrixBytes = 0;
    if (napi_get_arraybuffer_info(env, matrixValue, &matrixData, &matrixBytes) != napi_ok || matrixBytes < sizeof(work->matrix)) {
        delete work; return nullptr;
    }
    std::memcpy(work->matrix, matrixData, sizeof(work->matrix));
    if (!copyNamedBuffer(env, args[3], "toneCurve", work->toneCurve, 1025 * 4) ||
        !copyNamedBuffer(env, args[3], "redCurve", work->redCurve, 1025 * 4) ||
        !copyNamedBuffer(env, args[3], "greenCurve", work->greenCurve, 1025 * 4) ||
        !copyNamedBuffer(env, args[3], "blueCurve", work->blueCurve, 1025 * 4) ||
        !copyNamedBuffer(env, args[3], "parametricCurve", work->parametricCurve, 1025 * 4) ||
        !copyNumberArray(env, args[3], "mixHue", work->mixHue, 8) ||
        !copyNumberArray(env, args[3], "mixSaturation", work->mixSaturation, 8) ||
         !copyNumberArray(env, args[3], "mixLuminance", work->mixLuminance, 8)) {
        delete work; return nullptr;
    }
    double number = 0.0;
    if (!copyNumberArrayOptional(env, args[3], "tonal", work->tonal, 4) ||
        !copyNumberArrayOptional(env, args[3], "whiteBalanceGain", work->whiteBalanceGain, 3) ||
        !copyNumberArrayOptional(env, args[3], "lutDomainMin", work->lutDomainMin, 3) ||
        !copyNumberArrayOptional(env, args[3], "lutDomainScale", work->lutDomainScale, 3) ||
        !copyNumberArrayOptional(env, args[3], "calibrationHue", work->calibrationHue, 3) ||
        !copyNumberArrayOptional(env, args[3], "calibrationSaturation", work->calibrationSaturation, 3) ||
        !copyNumberArrayOptional(env, args[3], "vignette", work->vignette, 5) ||
        !copyNumberArrayOptional(env, args[3], "grain", work->grain, 3)) {
        delete work; return nullptr;
    }
    if (getNumber(env, args[3], "exposureGain", &number)) work->exposureGain = static_cast<float>(number);
    if (!std::isfinite(work->exposureGain) || work->exposureGain <= 0.0f) { delete work; return nullptr; }
    if (getNumber(env, args[3], "vibrance", &number)) work->vibrance = static_cast<float>(number);
    getBool(env, args[3], "whiteBalanceEnabled", &work->whiteBalanceEnabled);
    getBool(env, args[3], "mixerEnabled", &work->mixerEnabled);
    getBool(env, args[3], "parametricEnabled", &work->parametricEnabled);
    if (getNumber(env, args[3], "parametricRefine", &number)) work->parametricRefine = static_cast<float>(number);
    if (!std::isfinite(work->parametricRefine)) work->parametricRefine = 1.0f;
    if (work->parametricRefine < 0.0f) work->parametricRefine = 0.0f;
    if (work->parametricRefine > 1.0f) work->parametricRefine = 1.0f;
    if (!copyNumberArrayOptional(env, args[3], "gradingShadowsTarget", work->gradingShadowsTarget, 3) ||
        !copyNumberArrayOptional(env, args[3], "gradingMidtonesTarget", work->gradingMidtonesTarget, 3) ||
        !copyNumberArrayOptional(env, args[3], "gradingHighlightsTarget", work->gradingHighlightsTarget, 3) ||
        !copyNumberArrayOptional(env, args[3], "gradingGlobalTarget", work->gradingGlobalTarget, 3)) {
        delete work; return nullptr;
    }
    if (getNumber(env, args[3], "gradingShadowsSaturation", &number)) work->gradingShadowsSaturation = static_cast<float>(number);
    if (getNumber(env, args[3], "gradingShadowsLuminance", &number)) work->gradingShadowsLuminance = static_cast<float>(number);
    if (getNumber(env, args[3], "gradingMidtonesSaturation", &number)) work->gradingMidtonesSaturation = static_cast<float>(number);
    if (getNumber(env, args[3], "gradingMidtonesLuminance", &number)) work->gradingMidtonesLuminance = static_cast<float>(number);
    if (getNumber(env, args[3], "gradingHighlightsSaturation", &number)) work->gradingHighlightsSaturation = static_cast<float>(number);
    if (getNumber(env, args[3], "gradingHighlightsLuminance", &number)) work->gradingHighlightsLuminance = static_cast<float>(number);
    if (getNumber(env, args[3], "gradingGlobalSaturation", &number)) work->gradingGlobalSaturation = static_cast<float>(number);
    if (getNumber(env, args[3], "gradingGlobalLuminance", &number)) work->gradingGlobalLuminance = static_cast<float>(number);
    if (getNumber(env, args[3], "gradingBlending", &number)) work->gradingBlending = static_cast<float>(number);
    if (getNumber(env, args[3], "gradingBalance", &number)) work->gradingBalance = static_cast<float>(number);
    getBool(env, args[3], "gradingEnabled", &work->gradingEnabled);
    copyNamedBuffer(env, args[3], "lut", work->lut, 3, true);
    copyNamedBuffer(env, args[3], "mask", work->mask, 1, true);
    if (getNumber(env, args[3], "maskWidth", &number)) work->maskWidth = static_cast<uint32_t>(number);
    if (getNumber(env, args[3], "maskHeight", &number)) work->maskHeight = static_cast<uint32_t>(number);
    if (getNumber(env, args[3], "maskOpacity", &number)) work->maskOpacity = static_cast<float>(std::clamp(number, 0.0, 1.0));
    if (getNumber(env, args[3], "lutSize", &number)) work->lutSize = static_cast<uint32_t>(number);
    getBool(env, args[3], "lutEnabled", &work->lutEnabled);
    getBool(env, args[3], "maskEnabled", &work->maskEnabled);
    const size_t lutBytes = static_cast<size_t>(work->lutSize) * work->lutSize * work->lutSize * 3;
    work->lutEnabled = work->lutEnabled && work->lutSize >= 2 && work->lut.size() >= lutBytes;
    work->maskEnabled = work->maskEnabled && work->maskWidth > 0 && work->maskHeight > 0 &&
        work->mask.size() >= static_cast<size_t>(work->maskWidth) * work->maskHeight;

    napi_value promise = nullptr;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) { delete work; return nullptr; }
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "VividGpuRender", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_async_work(env, nullptr, resourceName, executeRender, completeRender, work, &work->asyncWork) != napi_ok ||
        napi_queue_async_work(env, work->asyncWork) != napi_ok) {
        delete work; return nullptr;
    }
    return promise;
}

#include "vivid_gpu_pipeline.inc"

static napi_value init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        { "capabilities", nullptr, capabilities, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "renderRgba", nullptr, renderRgba, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "renderStack", nullptr, renderStack, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "releaseSession", nullptr, releaseSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "clearSurface", nullptr, clearSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

NAPI_MODULE_X(vivid_gpu, init, nullptr, 0)

} // namespace
