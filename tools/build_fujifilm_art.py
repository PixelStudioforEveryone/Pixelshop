"""Copy transparent PNGs for supported FUJIFILM bodies into the VIVID rawfile tree,
resized to the size band used by the app's existing camera art (<=700 px wide),
and generate the ArkTS model->image manifest."""
import os, csv, re, json
from PIL import Image

SRC = r'C:\Users\HQ\Desktop\picture\documents\Fujifilm\apk\camera_images_png'
PROJ = r'C:\Users\HQ\DevEcoStudioProjects\VIVID'
DST = os.path.join(PROJ, 'entry', 'src', 'main', 'resources', 'rawfile', 'fujifilm')
ETS = os.path.join(PROJ, 'entry', 'src', 'main', 'ets', 'services', 'FujifilmModelImages.ets')

rows = list(csv.DictReader(open(os.path.join(PROJ, '..', '..', 'Users', 'HQ', 'Desktop', 'picture', 'documents', 'Fujifilm', 'apk', 'camera_images', 'index.csv'), encoding='utf-8-sig'))) if False else None
index_csv = r'C:\Users\HQ\Desktop\picture\documents\Fujifilm\apk\camera_images\index.csv'
rows = list(csv.DictReader(open(index_csv, encoding='utf-8-sig')))
bodies = [r for r in rows if r['category'] == '相机机身']

def slug(name: str) -> str:
    s = name.strip().lower()
    s = s.replace('fujifilm', '').strip()
    s = re.sub(r'[^a-z0-9]+', '_', s).strip('_')
    return s or 'unknown'

# one image per model: prefer the shortest file name (the base variant)
best = {}
for r in bodies:
    model = r['model'].strip()
    if not model:
        continue
    if model not in best or len(r['output']) < len(best[model]['output']):
        best[model] = r

os.makedirs(DST, exist_ok=True)
manifest = []
seen = {}
for model in sorted(best, key=lambda m: m.lower()):
    r = best[model]
    src = os.path.join(SRC, r['output'].replace('/', os.sep).replace('.jpg', '.png'))
    if not os.path.isfile(src):
        print('MISSING', model, src)
        continue
    s = slug(model)
    if s in seen:
        s = s + '_' + str(seen[s] + 1)
    seen[s] = seen.get(s, 0) + 1
    out = os.path.join(DST, s + '.png')
    im = Image.open(src).convert('RGBA')
    if im.width > 700:
        h = round(im.height * 700 / im.width)
        im = im.resize((700, h), Image.LANCZOS)
    im.save(out, 'PNG', optimize=True)
    series = r['series']
    manifest.append({'model': model, 'slug': s, 'series': series, 'file': s + '.png',
                     'codes': r['code']})

manifest.sort(key=lambda m: (m['series'], m['model'].lower()))
with open(os.path.join(DST, 'manifest.json'), 'w', encoding='utf-8') as f:
    json.dump(manifest, f, ensure_ascii=False, indent=1)

lines = []
lines.append('/**')
lines.append(' * FUJIFILM 机身素材表（自动生成，勿手改）。')
lines.append(' * 来源：XApp 2.7.0 assets 产品图，白底已抠成透明，缩放到 700px 宽。')
lines.append(' * 资源位置：resources/rawfile/fujifilm/<slug>.png')
lines.append(' */')
lines.append('export interface FujifilmModelArt {')
lines.append('  model: string;')
lines.append('  slug: string;')
lines.append('  series: string;')
lines.append('  codes: string;')
lines.append('}')
lines.append('')
lines.append('export class FujifilmModelImages {')
lines.append('  static readonly ALL: FujifilmModelArt[] = [')
for m in manifest:
    lines.append("    { model: '%s', slug: '%s', series: '%s', codes: '%s' }," % (
        m['model'].replace("'", "\\'"), m['slug'], m['series'].replace("'", "\\'"),
        m['codes'].replace("'", "\\'")[:60]))
lines.append('  ];')
lines.append('')
lines.append('  /** 归一化：大写、去掉所有非字母数字，用于宽松匹配（GFX 100 == GFX100）。 */')
lines.append('  static normalize(name: string): string {')
lines.append("    let out = '';")
lines.append('    const upper = name.toUpperCase();')
lines.append('    for (let i = 0; i < upper.length; i++) {')
lines.append("      const ch = upper.charAt(i);")
lines.append("      if ((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) out += ch;")
lines.append('    }')
lines.append('    return out;')
lines.append('  }')
lines.append('')
lines.append('  /** 机型名 -> 素材条目；找不到返回 null。 */')
lines.append('  static find(name: string): FujifilmModelArt | null {')
lines.append('    const key = FujifilmModelImages.normalize(name);')
lines.append('    if (key.length === 0) return null;')
lines.append('    for (const art of FujifilmModelImages.ALL) {')
lines.append('      if (FujifilmModelImages.normalize(art.model) === key) return art;')
lines.append('    }')
lines.append('    for (const art of FujifilmModelImages.ALL) {')
lines.append('      const artKey = FujifilmModelImages.normalize(art.model);')
lines.append('      if (artKey.length > 0 && (artKey.indexOf(key) >= 0 || key.indexOf(artKey) >= 0)) return art;')
lines.append('    }')
lines.append('    return null;')
lines.append('  }')
lines.append('')
lines.append('  /** rawfile 相对路径；找不到时回退到通用占位图。 */')
lines.append('  static rawfileOf(name: string): string {')
lines.append('    const art = FujifilmModelImages.find(name);')
lines.append("    return art !== null ? 'fujifilm/' + art.slug + '.png' : 'fujifilm/generic.png';")
lines.append('  }')
lines.append('}')
open(ETS, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')

total = sum(os.path.getsize(os.path.join(DST, f)) for f in os.listdir(DST) if f.endswith('.png'))
print('models', len(manifest), 'files', len([f for f in os.listdir(DST) if f.endswith('.png')]),
      'total MB %.1f' % (total / 1048576))
print('sample', manifest[:3])
