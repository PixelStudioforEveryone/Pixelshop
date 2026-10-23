/** CPU reference: scene-linear camera RGB -> XYZ D50 -> linear ProPhoto
 * -> HueSatMap -> exposure offset -> LookTable -> tone curve -> display sRGB.
 * No camera-model-specific transforms. Values stay floating point until encode.
 */
export interface DcpProfileData {
  classicMatrix?: number[];
  color1: number[]; color2: number[]; forward1: number[]; forward2: number[];
  illuminant1: number; illuminant2: number;
  hueDims: number[]; hue1: number[]; hue2: number[]; hueEncoding: number;
  lookDims: number[]; look: number[]; lookEncoding: number;
  curve: number[]; exposure: number;
}
export interface DcpContext {
  matrix: number[]; neutral: number[]; weight: number; temperature: number;
  hue: number[]; profile: DcpProfileData;
}
const XYZ_TO_PRO: number[] = [1.3459433,-0.2556075,-0.0511118,-0.5445989,1.5081673,0.0205351,0,0,1.2118128];
const PRO_TO_XYZ: number[] = [0.7976749,0.1351917,0.0313534,0.2880402,0.7118741,0.0000857,0,0,0.82521];
const XYZ_TO_SRGB: number[] = [3.1338561,-1.6168667,-0.4906146,-0.9787684,1.9161415,0.033454,0.0719453,-0.2289914,1.4052427];
const BRADFORD: number[] = [0.8951,0.2664,-0.1614,-0.7502,1.7135,0.0367,0.0389,-0.0685,1.0296];
const D50: number[] = [0.96422,1,0.82521];
export function dcpMul(m: number[], v: number[]): number[] {
  return [m[0]*v[0]+m[1]*v[1]+m[2]*v[2],m[3]*v[0]+m[4]*v[1]+m[5]*v[2],m[6]*v[0]+m[7]*v[1]+m[8]*v[2]];
}
function product(a: number[], b: number[]): number[] {
  const r: number[] = [];
  for (let i=0;i<3;i++) for(let j=0;j<3;j++) r.push(a[i*3]*b[j]+a[i*3+1]*b[j+3]+a[i*3+2]*b[j+6]);
  return r;
}
export function dcpInverse(m: number[]): number[] {
  if(m.length!==9) throw new Error('DCP requires a 3-channel matrix');
  const r=[m[4]*m[8]-m[5]*m[7],m[2]*m[7]-m[1]*m[8],m[1]*m[5]-m[2]*m[4],m[5]*m[6]-m[3]*m[8],m[0]*m[8]-m[2]*m[6],m[2]*m[3]-m[0]*m[5],m[3]*m[7]-m[4]*m[6],m[1]*m[6]-m[0]*m[7],m[0]*m[4]-m[1]*m[3]];
  const det=m[0]*r[0]+m[1]*r[3]+m[2]*r[6];
  if(!Number.isFinite(det)||Math.abs(det)<1e-12) throw new Error('Singular DCP matrix');
  return r.map((n: number): number=>n/det);
}
function clamp(n: number, low: number=0, high: number=1): number { return Math.max(low,Math.min(high,n)); }
export function dcpIlluminant(code: number): number {
  switch(code) {
    case 1: case 4: case 9: return 5500;
    case 2: case 14: return 4150;
    case 3: case 17: return 2856;
    case 10: case 19: case 21: return 6504;
    case 11: case 22: return 7504;
    case 12: return 6400;
    case 13: return 5050;
    case 15: return 3525;
    case 16: return 2925;
    case 18: return 4874;
    case 20: return 5503;
    case 23: return 5003;
    case 24: return 3200;
    default: throw new Error('Unsupported DCP calibration illuminant '+code);
  }
}
export function dcpWeight(k: number, a: number, b: number): number {
  if(a===b) return 1;
  return clamp((1/k-1/b)/(1/a-1/b));
}
function blend(a: number[], b: number[], w: number): number[] {
  if(b.length===0) return a.slice();
  if(a.length!==b.length) throw new Error('DCP paired data lengths differ');
  return a.map((n: number,i: number): number=>n*w+b[i]*(1-w));
}
// Planckian xy approximation, 1667–25000 K; tint is a CIE 1960 uv offset.
// Explicitly separate UI Kelvin from the file's calibration illuminants.
export function dcpWhite(k: number, tint: number=0): number[] {
  k=clamp(k,1667,25000);
  const x=k<=4000 ? -0.2661239e9/(k*k*k)-0.234358e6/(k*k)+0.8776956e3/k+0.17991 : -3.0258469e9/(k*k*k)+2.1070379e6/(k*k)+0.2226347e3/k+0.24039;
  const y=k<=2222 ? -1.1063814*x*x*x-1.3481102*x*x+2.18555832*x-0.20219683 : k<=4000 ? -0.9549476*x*x*x-1.37418593*x*x+2.09137015*x-0.16748867 : 3.081758*x*x*x-5.8733867*x*x+3.75112997*x-0.37001483;
  const den=-2*x+12*y+3, u=4*x/den, v=6*y/den-tint*0.00005;
  const xx=3*u/(2*u-8*v+4), yy=2*v/(2*u-8*v+4);
  return [xx/yy,1,(1-xx-yy)/yy];
}
function temperature(xyz: number[]): number {
  const sum=xyz[0]+xyz[1]+xyz[2], x=xyz[0]/sum, y=xyz[1]/sum;
  const u=4*x/(-2*x+12*y+3), v=6*y/(-2*x+12*y+3);
  let lo=1667, hi=25000;
  for(let i=0;i<50;i++) {
    const a=lo+(hi-lo)/3,b=hi-(hi-lo)/3;
    const wa=dcpWhite(a),wb=dcpWhite(b);
    const da=wa[0]+15+3*wa[2], db=wb[0]+15+3*wb[2];
    const ea=Math.pow(4*wa[0]/da-u,2)+Math.pow(6/da-v,2),eb=Math.pow(4*wb[0]/db-u,2)+Math.pow(6/db-v,2);
    if(ea<eb) hi=b; else lo=a;
  }
  return (lo+hi)/2;
}
export function prepareDcp(p: DcpProfileData, cameraNeutral: number[], kelvin: number=0, tint: number=0): DcpContext {
  if(cameraNeutral.length!==3 || cameraNeutral.some((n: number): boolean=>!Number.isFinite(n)||n<=0)) throw new Error('Invalid camera neutral');
  if (p.classicMatrix) {
    const cameraToXyz = product(dcpInverse(XYZ_TO_SRGB), p.classicMatrix);
    const selected = kelvin > 0 ? dcpMul(dcpInverse(cameraToXyz), dcpWhite(kelvin, tint)) : cameraNeutral.slice();
    if (selected.some((n: number): boolean => !Number.isFinite(n) || n <= 0)) throw new Error('Invalid classic white balance');
    const matrix = product(XYZ_TO_PRO, cameraToXyz).map((n: number, i: number): number => n * selected[1] / selected[i % 3]);
    return { matrix: matrix, neutral: selected, weight: 1, temperature: kelvin, hue: [], profile: p };
  }
  const dual=p.color2.length>0;
  // An unknown illuminant is valid for a single matrix: no interpolation.
  const t1=dual?dcpIlluminant(p.illuminant1):5000, t2=dual?dcpIlluminant(p.illuminant2):t1;
  let k=kelvin>0?kelvin:5000, weight=dual?dcpWeight(k,t1,t2):1;
  let cm=blend(p.color1,p.color2,weight), white: number[];
  if(kelvin<=0) {
    let converged=false;
    for(let i=0;i<80;i++) {
      cm=blend(p.color1,p.color2,weight);
      white=dcpMul(dcpInverse(cm),cameraNeutral);
      k=temperature(white);
      const next=dual?dcpWeight(k,t1,t2):1;
      // Temperature minimisation has finite precision. A 1e-8 threshold
      // could oscillate below 0.0001 K and reject otherwise valid profiles.
      if(Math.abs(next-weight)<1e-7){weight=next;converged=true;break;}
      weight=(weight+next)/2;
    }
    if(!converged) throw new Error('DCP white balance did not converge');
  }
  cm=blend(p.color1,p.color2,weight);
  let neutral=cameraNeutral.slice();
  if(kelvin>0) neutral=dcpMul(cm,dcpWhite(kelvin,tint));
  if(neutral.some((n: number): boolean=>!Number.isFinite(n)||n<=0)) throw new Error('White balance outside profile domain');
  const norm=Math.max(...neutral); neutral=neutral.map((n: number): number=>n/norm);
  let matrix: number[];
  if(p.forward1.length>0) {
    if(dual && p.forward2.length===0) throw new Error('Incomplete dual ForwardMatrix');
    matrix=blend(p.forward1,p.forward2,weight);
    const rowWhite=dcpMul(matrix,[1,1,1]);
    if(rowWhite.some((n: number): boolean=>!Number.isFinite(n)||n<=0))throw new Error('Invalid ForwardMatrix white point');
    // Native returns unbalanced linear camera RGB. Apply the selected neutral
    // exactly once here, including a user-selected Kelvin/tint.
    matrix=matrix.map((n: number,i: number): number=>n*D50[Math.floor(i/3)]/rowWhite[Math.floor(i/3)]/neutral[i%3]);
  } else {
    const inv=dcpInverse(cm); white=dcpMul(inv,neutral);
    const cone=dcpMul(BRADFORD,white),target=dcpMul(BRADFORD,D50);
    if(cone.some((n: number): boolean=>!Number.isFinite(n)||n<=0))throw new Error('Invalid camera white adaptation');
    const adapt=product(dcpInverse(BRADFORD),BRADFORD.map((n: number,i: number): number=>n*target[Math.floor(i/3)]/cone[Math.floor(i/3)]));
    matrix=product(adapt,inv);
  }
  return {matrix: product(XYZ_TO_PRO,matrix),neutral:neutral,weight:weight,temperature:k,hue:blend(p.hue1,p.hue2,weight),profile:p};
}
function encode(n: number): number { return n<=0.0031308?12.92*n:1.055*Math.pow(n,1/2.4)-0.055; }
function decode(n: number): number { return n<=0.04045?n/12.92:Math.pow((n+0.055)/1.055,2.4); }
export function dcpTable(rgb: number[], dims: number[], data: number[], encoding: number): number[] {
  if(data.length===0) return rgb;
  const max=Math.max(...rgb),min=Math.min(...rgb),delta=max-min;
  if(max<=0) return rgb;
  let hue=delta===0?0:max===rgb[0]?(rgb[1]-rgb[2])/delta:max===rgb[1]?2+(rgb[2]-rgb[0])/delta:4+(rgb[0]-rgb[1])/delta;
  hue=((hue%6)+6)%6;
  // DNG SDK RefBaselineHueSatMap: the value coordinate is sRGB-encoded before
  // the 3D lookup only for encoding=1 tables with more than one value division;
  // after the valScale multiply the value is always pinned to [0,1].
  const sat=clamp(delta/max), value=encoding===1&&dims[2]>1?encode(clamp(max)):max;
  const hh=hue*dims[0]/6, ss=sat*(dims[1]-1), vv=clamp(value)*(dims[2]-1);
  const h0=Math.floor(hh)%dims[0],s0=Math.floor(ss),v0=Math.floor(vv);
  const weights=[hh-Math.floor(hh),ss-s0,vv-v0];
  const result=[0,0,0];
  for(let z=0;z<2;z++)for(let y=0;y<2;y++)for(let x=0;x<2;x++){
    const index=((Math.min(dims[2]-1,v0+z)*dims[0]+(h0+x)%dims[0])*dims[1]+Math.min(dims[1]-1,s0+y))*3;
    const w=(x?weights[0]:1-weights[0])*(y?weights[1]:1-weights[1])*(z?weights[2]:1-weights[2]);
    for(let ch=0;ch<3;ch++)result[ch]+=data[index+ch]*w;
  }
  hue=((hue+result[0]/60)%6+6)%6;
  const s=clamp(sat*result[1]);
  const v=encoding===1?decode(clamp(value*result[2])):clamp(max*result[2]);
  const chroma=v*s,x=chroma*(1-Math.abs(hue%2-1)),m=v-chroma;
  const sector=Math.floor(hue);
  const out=sector===0?[chroma,x,0]:sector===1?[x,chroma,0]:sector===2?[0,chroma,x]:sector===3?[0,x,chroma]:sector===4?[x,0,chroma]:[chroma,0,x];
  return out.map((n: number): number=>n+m);
}
function curveAt(curve: number[], x: number): number {
  if(x<=curve[0])return curve[1];
  if(x>=curve[curve.length-2])return curve[curve.length-1];
  let lo=0,hi=curve.length/2-1;
  while(hi-lo>1){const mid=Math.floor((lo+hi)/2);if(curve[mid*2]<=x)lo=mid;else hi=mid;}
  const f=(x-curve[lo*2])/(curve[hi*2]-curve[lo*2]);
  return curve[lo*2+1]*(1-f)+curve[hi*2+1]*f;
}
export function dcpTone(rgb: number[], curve: number[]): number[] {
  if(curve.length===0)return rgb;
  const low=Math.min(...rgb),high=Math.max(...rgb),a=curveAt(curve,low),b=curveAt(curve,high);
  return rgb.map((n: number): number=>high===low?a:a+(n-low)*(b-a)/(high-low));
}
export function dcpPixel(camera: number[], context: DcpContext): number[] {
  const p=context.profile;
  let rgb=dcpMul(context.matrix,camera).map((n: number): number=>Math.max(0,n));
  rgb=dcpTable(rgb,p.hueDims,context.hue,p.hueEncoding);
  rgb=rgb.map((n: number): number=>n*Math.pow(2,p.exposure));
  rgb=dcpTable(rgb,p.lookDims,p.look,p.lookEncoding);
  rgb=dcpTone(rgb,p.curve);
  return dcpMul(XYZ_TO_SRGB,dcpMul(PRO_TO_XYZ,rgb));
}
// ---------- Optimized render path ----------
// Precomputed LUTs (tone curve, sRGB gamma, output encode) plus a
// zero-allocation scalar pixel loop. Output stays within 1/255 of
// renderDcpReference per pixel; validated offline on real S1RM2 samples
// for every bundled profile and white-balance setting.
const GAMMA_N: number = 8192;
const TONE_N: number = 16384;
const OUT_N: number = 16384;
function buildGammaEnc(): Float32Array {
  const lut = new Float32Array(GAMMA_N);
  for (let i = 0; i < GAMMA_N; i++) lut[i] = encode(i / (GAMMA_N - 1));
  return lut;
}
function buildGammaDec(): Float32Array {
  const lut = new Float32Array(GAMMA_N);
  for (let i = 0; i < GAMMA_N; i++) lut[i] = decode(i / (GAMMA_N - 1));
  return lut;
}
const gammaEnc: Float32Array = buildGammaEnc();
const gammaDec: Float32Array = buildGammaDec();
function gammaIndex(n: number): number {
  if (n <= 0) return 0;
  if (n >= 1) return GAMMA_N - 1;
  return Math.round(n * (GAMMA_N - 1));
}
function buildOutputLut(): Uint8Array {
  const lut = new Uint8Array(OUT_N);
  for (let i = 0; i < OUT_N; i++) lut[i] = Math.round(255 * encode(i / (OUT_N - 1)));
  return lut;
}
const outputLut: Uint8Array = buildOutputLut();
function outByte(n: number): number {
  if (n <= 0) return 0;
  if (n >= 1) return 255;
  return outputLut[Math.round(n * (OUT_N - 1))];
}
export class HsvTable {
  data: Float32Array;
  h: number;
  s: number;
  v: number;
  encIn: boolean;
  decOut: boolean;
  constructor(dims: number[], data: number[], encoding: number) {
    this.h = dims[0];
    this.s = dims[1];
    this.v = dims[2];
    // dcpTable parity: the value coordinate is sRGB-encoded before the 3D
    // lookup only for encoding=1 tables with more than one value division;
    // the post-lookup decode applies to every encoding=1 table.
    this.encIn = encoding === 1 && dims[2] > 1;
    this.decOut = encoding === 1;
    this.data = new Float32Array(data.length);
    for (let i = 0; i < data.length; i++) this.data[i] = data[i];
  }
}
export class RenderTables {
  m: Float32Array = new Float32Array(9);
  display: Float32Array = new Float32Array(9);
  gain: number = 1;
  tone: Float32Array | null = null;
  hue: HsvTable | null = null;
  look: HsvTable | null = null;
}

/** TaskPool transfers buffers; each band needs private backing storage. */
export function cloneDcpRenderPlan(source: RenderTables): RenderTables {
  const result = new RenderTables();
  result.m = source.m.slice(); result.display = source.display.slice();
  result.gain = source.gain; result.tone = source.tone?.slice() ?? null;
  if (source.hue) {
    result.hue = new HsvTable([source.hue.h, source.hue.s, source.hue.v], [], source.hue.decOut ? 1 : 0);
    result.hue.data = source.hue.data.slice();
  }
  if (source.look) {
    result.look = new HsvTable([source.look.h, source.look.s, source.look.v], [], source.look.decOut ? 1 : 0);
    result.look.data = source.look.data.slice();
  }
  return result;
}
let hsvR: number = 0;
let hsvG: number = 0;
let hsvB: number = 0;
function hsvStep(t: HsvTable, r: number, g: number, b: number): void {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const delta = max - min;
  if (max <= 0) { hsvR = r; hsvG = g; hsvB = b; return; }
  let hue: number;
  if (delta === 0) hue = 0;
  else if (max === r) hue = (g - b) / delta;
  else if (max === g) hue = 2 + (b - r) / delta;
  else hue = 4 + (r - g) / delta;
  hue = ((hue % 6) + 6) % 6;
  const sat = delta / max;
  const value = t.encIn ? gammaEnc[gammaIndex(max)] : max;
  const hh = hue * t.h / 6;
  const ss = sat * (t.s - 1);
  const vc = value < 0 ? 0 : value > 1 ? 1 : value;
  const vv = vc * (t.v - 1);
  const h0 = Math.floor(hh) % t.h;
  const s0 = Math.floor(ss);
  const v0 = Math.floor(vv);
  const wh = hh - Math.floor(hh);
  const ws = ss - s0;
  const wv = vv - v0;
  let dH: number = 0;
  let dS: number = 0;
  let dV: number = 0;
  const d = t.data;
  const H = t.h;
  const S = t.s;
  const sm1 = t.s - 1;
  const vm1 = t.v - 1;
  for (let z = 0; z < 2; z++) {
    const wz = z ? wv : 1 - wv;
    const vz = v0 + z > vm1 ? vm1 : v0 + z;
    for (let y = 0; y < 2; y++) {
      const wy = wz * (y ? ws : 1 - ws);
      const sy = s0 + y > sm1 ? sm1 : s0 + y;
      for (let x = 0; x < 2; x++) {
        const w = wy * (x ? wh : 1 - wh);
        const hx = (h0 + x) % H;
        const idx = ((vz * H + hx) * S + sy) * 3;
        dH += d[idx] * w;
        dS += d[idx + 1] * w;
        dV += d[idx + 2] * w;
      }
    }
  }
  hue = ((hue + dH / 60) % 6 + 6) % 6;
  let s2 = sat * dS;
  if (s2 < 0) s2 = 0;
  else if (s2 > 1) s2 = 1;
  let v2: number;
  if (t.decOut) {
    let pv = value * dV;
    if (pv < 0) pv = 0;
    else if (pv > 1) pv = 1;
    v2 = gammaDec[gammaIndex(pv)];
  } else {
    const pv = max * dV;
    v2 = pv < 0 ? 0 : pv > 1 ? 1 : pv;
  }
  const chroma = v2 * s2;
  const xx = chroma * (1 - Math.abs(hue % 2 - 1));
  const m = v2 - chroma;
  const sector = Math.floor(hue);
  if (sector === 0) { hsvR = chroma + m; hsvG = xx + m; hsvB = m; }
  else if (sector === 1) { hsvR = xx + m; hsvG = chroma + m; hsvB = m; }
  else if (sector === 2) { hsvR = m; hsvG = chroma + m; hsvB = xx + m; }
  else if (sector === 3) { hsvR = m; hsvG = xx + m; hsvB = chroma + m; }
  else if (sector === 4) { hsvR = xx + m; hsvG = m; hsvB = chroma + m; }
  else { hsvR = chroma + m; hsvG = m; hsvB = xx + m; }
}
function toneIndex(n: number): number {
  if (n <= 0) return 0;
  if (n >= 1) return TONE_N - 1;
  return Math.round(n * (TONE_N - 1));
}
function toneStep(lut: Float32Array, r: number, g: number, b: number): void {
  const low = Math.min(r, g, b);
  const high = Math.max(r, g, b);
  const a = lut[toneIndex(low)];
  const bt = lut[toneIndex(high)];
  if (high === low) { hsvR = a; hsvG = a; hsvB = a; return; }
  const k = (bt - a) / (high - low);
  hsvR = a + (r - low) * k;
  hsvG = a + (g - low) * k;
  hsvB = a + (b - low) * k;
}
function prepareRenderTables(context: DcpContext): RenderTables {
  const p = context.profile;
  const t = new RenderTables();
  for (let i = 0; i < 9; i++) t.m[i] = context.matrix[i];
  const disp = product(XYZ_TO_SRGB, PRO_TO_XYZ);
  for (let i = 0; i < 9; i++) t.display[i] = disp[i];
  t.gain = Math.pow(2, p.exposure);
  if (p.curve.length > 0) {
    const lut = new Float32Array(TONE_N);
    for (let i = 0; i < TONE_N; i++) lut[i] = curveAt(p.curve, i / (TONE_N - 1));
    t.tone = lut;
  }
  if (context.hue.length > 0 && p.hueDims.length >= 3) t.hue = new HsvTable(p.hueDims, context.hue, p.hueEncoding);
  if (p.look.length > 0 && p.lookDims.length >= 3) t.look = new HsvTable(p.lookDims, p.look, p.lookEncoding);
  return t;
}
/**
 * Build the reusable render plan once per (profile, white balance): the WB
 * matrix interpolation, HSV table blending and tone LUT. Band tasks receive
 * the plan (typed arrays, cheap taskpool clone) instead of the raw profile
 * (a 69k-element number[] that structured-clone would deep-copy per task).
 */
export function buildDcpRenderPlan(p: DcpProfileData, neutral: number[], kelvin: number, tint: number): RenderTables {
  const context = prepareDcp(p, neutral, kelvin, tint);
  return prepareRenderTables(context);
}
function renderPixels(src: Float32Array, out: Uint8Array, t: RenderTables): void {
  const m = t.m;
  const dsp = t.display;
  const gain = t.gain;
  const hue = t.hue;
  const look = t.look;
  const tone = t.tone;
  for (let i = 0, j = 0; i < src.length; i += 3, j += 4) {
    const r0 = src[i];
    const g0 = src[i + 1];
    const b0 = src[i + 2];
    if (!Number.isFinite(r0) || !Number.isFinite(g0) || !Number.isFinite(b0)) throw new Error('Nonfinite linear RGB');
    let r = m[0] * r0 + m[1] * g0 + m[2] * b0;
    let g = m[3] * r0 + m[4] * g0 + m[5] * b0;
    let b = m[6] * r0 + m[7] * g0 + m[8] * b0;
    if (r < 0) r = 0;
    if (g < 0) g = 0;
    if (b < 0) b = 0;
    if (hue !== null) { hsvStep(hue, r, g, b); r = hsvR; g = hsvG; b = hsvB; }
    r *= gain;
    g *= gain;
    b *= gain;
    if (look !== null) { hsvStep(look, r, g, b); r = hsvR; g = hsvG; b = hsvB; }
    if (tone !== null) { toneStep(tone, r, g, b); r = hsvR; g = hsvG; b = hsvB; }
    out[j] = outByte(dsp[0] * r + dsp[1] * g + dsp[2] * b);
    out[j + 1] = outByte(dsp[3] * r + dsp[4] * g + dsp[5] * b);
    out[j + 2] = outByte(dsp[6] * r + dsp[7] * g + dsp[8] * b);
    out[j + 3] = 255;
  }
}
/** Pixel loop only: applies a prebuilt render plan to `linear` (12 B/px). */
export function renderDcpPlan(linear: ArrayBuffer, tables: RenderTables): ArrayBuffer {
  if (linear.byteLength === 0 || linear.byteLength % 12 !== 0) throw new Error('Invalid linear RGB buffer');
  const src = new Float32Array(linear);
  const out = new Uint8Array(src.length / 3 * 4);
  renderPixels(src, out, tables);
  return out.buffer;
}
/** Optimized renderer: processes every pixel in `linear` (12 bytes each). */
export function renderDcpSpan(linear: ArrayBuffer, p: DcpProfileData, neutral: number[], kelvin: number, tint: number): ArrayBuffer {
  return renderDcpPlan(linear, buildDcpRenderPlan(p, neutral, kelvin, tint));
}
export function renderDcp(linear: ArrayBuffer, p: DcpProfileData, neutral: number[], kelvin: number, tint: number): ArrayBuffer {
  return renderDcpSpan(linear, p, neutral, kelvin, tint);
}
/** Pre-optimization renderer kept as the correctness reference. */
export function renderDcpReference(linear: ArrayBuffer, p: DcpProfileData, neutral: number[], kelvin: number, tint: number): ArrayBuffer {
  if(linear.byteLength===0||linear.byteLength%12!==0)throw new Error('Invalid linear RGB buffer');
  const context=prepareDcp(p,neutral,kelvin,tint),src=new Float32Array(linear);
  const out=new Uint8Array(src.length/3*4);
  if (context.hue.length === 0 && p.look.length === 0 && p.curve.length === 0) {
    // Matrix-only profiles need no per-pixel arrays, HSV lookup or tone search.
    // Retain the same ProPhoto clipping boundary as the reference pipeline.
    const m=context.matrix, display=product(XYZ_TO_SRGB,PRO_TO_XYZ), gain=Math.pow(2,p.exposure);
    for(let i=0,j=0;i<src.length;i+=3,j+=4){
      const r=src[i],g=src[i+1],b=src[i+2];
      if(!Number.isFinite(r)||!Number.isFinite(g)||!Number.isFinite(b))throw new Error('Nonfinite linear RGB');
      const pr=Math.max(0,m[0]*r+m[1]*g+m[2]*b)*gain;
      const pg=Math.max(0,m[3]*r+m[4]*g+m[5]*b)*gain;
      const pb=Math.max(0,m[6]*r+m[7]*g+m[8]*b)*gain;
      for(let ch=0;ch<3;ch++) out[j+ch]=Math.round(255*encode(clamp(display[ch*3]*pr+display[ch*3+1]*pg+display[ch*3+2]*pb)));
      out[j+3]=255;
    }
    return out.buffer;
  }
  for(let i=0,j=0;i<src.length;i+=3,j+=4){
    if(!Number.isFinite(src[i])||!Number.isFinite(src[i+1])||!Number.isFinite(src[i+2]))throw new Error('Nonfinite linear RGB');
    const rgb=dcpPixel([src[i],src[i+1],src[i+2]],context);
    for(let ch=0;ch<3;ch++)out[j+ch]=Math.round(255*encode(clamp(rgb[ch])));
    out[j+3]=255;
  }
  return out.buffer;
}

/** Classic open-source profile built from LibRaw's dcraw rgb_cam matrix.
 * forward1 = sRGB-to-XYZ(D50) composed with camToSrgb, so the XYZ/ProPhoto
 * round trip inside dcpPixel cancels exactly and the rendered output equals
 * LibRaw's own camera->sRGB conversion with no extra color transforms. */
export function classicDcp(camToSrgb: number[]): DcpProfileData {
  if(camToSrgb.length!==9||camToSrgb.some((n: number): boolean=>!Number.isFinite(n)))
    throw new Error('Invalid classic camera matrix');
  const srgbToXyz=dcpInverse(XYZ_TO_SRGB);
  const forward: number[]=[];
  for(let i=0;i<3;i++)for(let j=0;j<3;j++)
    forward.push(srgbToXyz[i*3]*camToSrgb[j]+srgbToXyz[i*3+1]*camToSrgb[j+3]+srgbToXyz[i*3+2]*camToSrgb[j+6]);
  if(forward.some((n: number): boolean=>!Number.isFinite(n)))throw new Error('Invalid classic forward matrix');
  return {classicMatrix:camToSrgb.slice(),color1:dcpInverse(forward),color2:[],forward1:forward,forward2:[],
    illuminant1:0,illuminant2:0,hueDims:[],hue1:[],hue2:[],hueEncoding:0,
    lookDims:[],look:[],lookEncoding:0,curve:[],exposure:0};
}
