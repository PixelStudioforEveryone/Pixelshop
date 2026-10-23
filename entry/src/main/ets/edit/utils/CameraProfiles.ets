import { resourceManager } from '@kit.LocalizationKit';
import { taskpool } from '@kit.ArkTS';
import { parseDcpProfile, ParsedDcpProfile } from './DcpProfileParser';
import { parseDcpProfileTask } from '../engine/DcpWorker';
import { CAMERA_PROFILE_FILES } from './CameraProfileFiles';
import { DcpProfileData, dcpInverse, dcpIlluminant } from '../engine/DcpCpu';

export class CameraProfile {
  private cachedCpuData: DcpProfileData | null = null;
  path: string = '';
  model: string = '';
  name: string = '';
  /** Cross-camera bundled profile (Pixel family) that is offered as a fixed
   * picker option instead of being matched against the RAW's camera model. */
  fixed: boolean = false;
  fields: Map<number, number[]> = new Map();
  loaded: boolean = false;

  cpuData(): DcpProfileData {
    if (this.cachedCpuData) return this.cachedCpuData;
    if (!this.loaded) CameraProfiles.loadProfile(this);
    const f=this.fields;
    const result: DcpProfileData = {
      color1:f.get(0xc621)??[],color2:f.get(0xc622)??[],
      forward1:f.get(0xc714)??[],forward2:f.get(0xc715)??[],
      illuminant1:f.get(0xc65a)?.[0]??0,illuminant2:f.get(0xc65b)?.[0]??0,
      hueDims:f.get(0xc6f9)??[],hue1:f.get(0xc6fa)??[],hue2:f.get(0xc6fb)??[],hueEncoding:f.get(0xc7a3)?.[0]??0,
      lookDims:f.get(0xc725)??[],look:f.get(0xc726)??[],lookEncoding:f.get(0xc7a4)?.[0]??0,
      curve:f.get(0xc6fc)??[],exposure:f.get(0xc7a5)?.[0]??0,
    };
    dcpInverse(result.color1);
    if(result.color2.length>0){dcpInverse(result.color2);dcpIlluminant(result.illuminant1);dcpIlluminant(result.illuminant2);}
    if(result.hueEncoding!==0&&result.hueEncoding!==1||result.lookEncoding!==0&&result.lookEncoding!==1) throw new Error('Unsupported DCP table encoding');
    for(const dims of [result.hueDims,result.lookDims]) {
      if(dims.length>0&&(dims.length!==3||dims[0]<1||dims[1]<2||dims[2]<1)) throw new Error('Unsupported DCP HSV dimensions');
    }
    if(result.hue2.length>0&&(result.hue1.length===0||result.color2.length===0))throw new Error('Unpaired HueSatMap');
    if(result.curve.length>0){
      if(result.curve.length<4||result.curve.length%2!==0)throw new Error('Invalid DCP tone curve');
      for(let i=0;i<result.curve.length;i+=2){
        if(result.curve[i]<0||result.curve[i]>1||result.curve[i+1]<0||result.curve[i+1]>1||i>0&&result.curve[i]<=result.curve[i-2])throw new Error('Invalid DCP curve point');
      }
    }
    // These fields require additional camera calibration / spectral stages.
    for(const tag of [0xc623,0xc624,0xc625,0xc626,0xcd31,0xcd32,0xcd33,0xcd34,0xcd35]) {
      if(f.has(tag))throw new Error('Unsupported color-affecting DCP field '+tag.toString(16));
    }
    if((f.get(0xc7a6)?.[0]??1)===0)console.warn('VIVID_DCP DefaultBlackRender auto is not implemented; no automatic black rendering applied');
    this.cachedCpuData = result;
    return result;
  }
}

export class CameraProfiles {
  static readonly CLASSIC_PROFILE_NAME: string = 'Pixel 经典';
  /** Bundled F-Log2C transfer profile (modified from Panasonic Vision);
   * fits Panasonic RAW files only, so selecting it is user-opt-in. */
  static readonly FLOG2_PROFILE_NAME: string = 'Pixel F-log2';
  static readonly FLOG2_PROFILE_PATH: string = 'Camera/Pixel F-log2/Pixel F-log2.dcp';
  private static profiles: CameraProfile[] = [];
  private static manager: resourceManager.ResourceManager | null = null;
  private static loaded: boolean = false;
  private static pending: Map<string, Promise<void>> = new Map();

  /**
   * Build the profile index from the bundled path list. Directory names are
   * camera models and file names carry the style ("Model Camera Style.dcp"),
   * so no DCP bytes are read here: 370+ profiles parse lazily on first use
   * instead of all at startup.
   */
  static async initialize(manager: resourceManager.ResourceManager): Promise<void> {
    if (CameraProfiles.loaded) return;
    CameraProfiles.manager = manager;
    const profiles: CameraProfile[] = [];
    for (const path of CAMERA_PROFILE_FILES) {
      const slash = path.indexOf('/');
      const rest = slash >= 0 ? path.substring(slash + 1) : path;
      const dirEnd = rest.indexOf('/');
      if (dirEnd < 0) continue;
      const model = rest.substring(0, dirEnd);
      const file = rest.substring(dirEnd + 1);
      const base = file.endsWith('.dcp') ? file.substring(0, file.length - 4) : file;
      const prefix = model + ' ';
      const profile = new CameraProfile();
      profile.path = path;
      profile.model = model;
      profile.name = base.startsWith(prefix) ? base.substring(prefix.length) : base;
      if (path === CameraProfiles.FLOG2_PROFILE_PATH) profile.fixed = true;
      profiles.push(profile);
    }
    CameraProfiles.profiles = profiles;
    CameraProfiles.loaded = true;
  }

  /** Parse a profile's DCP bytes on demand. Runs on the caller's thread. */
  static loadProfile(profile: CameraProfile): void {
    const manager = CameraProfiles.manager;
    if (!manager) throw new Error('Camera profiles not initialized');
    const bytes = manager.getRawFileContentSync(profile.path);
    const data = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    try {
      CameraProfiles.fill(profile, data);
      profile.loaded = true;
    } catch (error) {
      console.error('VIVID_DCP rejected ' + profile.path + ': ' + String(error));
      throw new Error(String(error));
    }
  }

  /** File IO and numeric table parsing are kept off the UI thread. */
  static async loadProfileAsync(profile: CameraProfile): Promise<void> {
    if (profile.loaded) return;
    const pending = CameraProfiles.pending.get(profile.path);
    if (pending) return pending;
    const request = CameraProfiles.readProfile(profile);
    CameraProfiles.pending.set(profile.path, request);
    try { await request; } finally {
      if (CameraProfiles.pending.get(profile.path) === request) CameraProfiles.pending.delete(profile.path);
    }
  }

  private static async readProfile(profile: CameraProfile): Promise<void> {
    const manager = CameraProfiles.manager;
    if (!manager) throw new Error('Camera profiles not initialized');
    const begin = Date.now();
    const bytes = await manager.getRawFileContent(profile.path);
    const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    const parsed = await taskpool.execute(new taskpool.Task(parseDcpProfileTask,
      buffer, profile.model, profile.name, profile.fixed)) as ParsedDcpProfile;
    profile.model = parsed.model;
    profile.name = parsed.name;
    profile.fields = parsed.fields;
    profile.loaded = true;
    console.info('VIVID_EDIT_PERF stage=dcp-load ms=' + (Date.now() - begin));
  }

  static matching(model: string): CameraProfile[] {
    const target = model.trim().toUpperCase();
    if (!target) return [];
    return CameraProfiles.profiles.filter((profile: CameraProfile) => {
      if (profile.fixed) return false;
      const candidate = profile.model.trim().toUpperCase();
      return candidate === target || candidate.endsWith(target) || target.endsWith(candidate);
    });
  }

  /** Resolve a fixed cross-camera profile (Pixel family) by its bundle path.
   * Unlike model-matched profiles it applies to any RAW at the user's choice. */
  static fixedProfile(path: string): CameraProfile | null {
    return CameraProfiles.profiles.find((profile: CameraProfile) =>
      profile.fixed && profile.path === path) ?? null;
  }

  static find(model: string, name: string): CameraProfile | null {
    const target = name.trim().toUpperCase();
    if (!target) return null;
    return CameraProfiles.matching(model).find((profile: CameraProfile) =>
      profile.name.trim().toUpperCase() === target) ?? null;
  }

  static cameraModel(data: ArrayBuffer): string {
    try {
      const v = new DataView(data);
      const le = v.getUint16(0, false) === 0x4949;
      if (!le && v.getUint16(0, false) !== 0x4d4d) return '';
      const offset = v.getUint32(4, le);
      let make = ''; let model = '';
      if (offset + 2 <= data.byteLength) {
        const count = v.getUint16(offset, le);
        if (count <= 4096 && offset + 2 + count * 12 <= data.byteLength) {
          for (let i = 0; i < count; i++) {
            const p = offset + 2 + i * 12;
            const tag = v.getUint16(p, le);
            if ((tag !== 0x10f && tag !== 0x110) || v.getUint16(p + 2, le) !== 2) continue;
            const n = v.getUint32(p + 4, le);
            const start = n <= 4 ? p + 8 : v.getUint32(p + 8, le);
            if (n > 256 || start + n > data.byteLength) continue;
            let text = '';
            for (let j = 0; j < n && v.getUint8(start + j) !== 0; j++) text += String.fromCharCode(v.getUint8(start + j));
            if (tag === 0x10f) make = text.trim(); else model = text.trim();
          }
        }
      }
      if (model.length > 0) {
        // EXIF Make is often verbose ("NIKON CORPORATION", "OLYMPUS IMAGING
        // CORP.") while profile folders use the brand word only ("Nikon Z 5").
        // Prefer the full Make when the Model already carries it, otherwise
        // fall back to Make's first word so the composed name stays matchable.
        const makeUpper = make.toUpperCase();
        if (makeUpper.length === 0 || model.toUpperCase().startsWith(makeUpper)) return model;
        const makeWord = make.split(' ')[0];
        if (model.toUpperCase().startsWith(makeWord.toUpperCase())) return model;
        return (makeWord + ' ' + model).trim();
      }

      // Panasonic RW2 files use a proprietary root IFD (magic 85) and often
      // omit standard 0x10f/0x110 tags.  Their MakerNote still contains the
      // NUL-separated ASCII pair "Panasonic" + camera model; use it only as a
      // model hint, never as image dimensions or pixel data.
      const needle = 'Panasonic';
      for (let start = 0; start + needle.length < data.byteLength; start++) {
        let matches = true;
        for (let j = 0; j < needle.length; j++) {
          if (v.getUint8(start + j) !== needle.charCodeAt(j)) { matches = false; break; }
        }
        if (!matches) continue;
        const parts: string[] = [];
        let cursor = start;
        for (let part = 0; part < 3 && cursor < data.byteLength; part++) {
          let text = '';
          while (cursor < data.byteLength) {
            const code = v.getUint8(cursor++);
            if (code === 0) break;
            if (code < 0x20 || code > 0x7e) { text = ''; break; }
            text += String.fromCharCode(code);
          }
          if (text.length > 1) parts.push(text);
        }
        if (parts.length >= 2 && parts[0].toUpperCase() === 'PANASONIC') return parts[0] + ' ' + parts[1];
      }
      return '';
    } catch (_) { return ''; }
  }

  private static fill(profile: CameraProfile, data: ArrayBuffer): void {
    const parsed = parseDcpProfile(data, profile.model, profile.name, profile.fixed);
    profile.model = parsed.model;
    profile.name = parsed.name;
    profile.fields = parsed.fields;
  }
}
