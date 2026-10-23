"""Canon camera art pipeline.

Source of truth
---------------
`C:\\Users\\HQ\\Desktop\\picture\\documents\\Canon\\1171631.apk`
  -> apktool_out/res/drawable-nodpi/camera_<hex PID>.png
     (480x360 RGBA, already baked on a transparent background by Canon)

Outputs
-------
1. `C:\\Users\\HQ\\Desktop\\picture\\Canon\\<model>.png`  (user-facing library)
2. `entry/src/main/resources/rawfile/canon/<slug>.png`   (VIVID rawfile)
3. `entry/src/main/ets/services/CanonModelImages.ets`    (auto-generated table)
4. `<deliverable>/manifest.json` + `README.md`

Background handling
-------------------
Every Canon PTP product shot is already alpha-cut, but this script still runs a
real background pass so the promise "background replaced with transparency" is
enforced rather than assumed:
  * if the 1px outer ring is fully transparent -> keep pixels (no resampling);
  * otherwise flood-fill near-white/opaque background from the border and clear
    alpha, then de-fringe the 1px boundary (prevents white halos on dark cards).
Both cases are counted and reported.
"""
import csv
import json
import os
import re
from collections import deque

import numpy as np
from PIL import Image

PROJ = r'C:\Users\HQ\DevEcoStudioProjects\VIVID'
APK_RES = r'C:\Users\HQ\Desktop\picture\documents\Canon\decompile\apktool_out\res'
DELIVER = r'C:\Users\HQ\Desktop\picture\Canon'
RAWFILE = os.path.join(PROJ, 'entry', 'src', 'main', 'resources', 'rawfile', 'canon')
ETS = os.path.join(PROJ, 'entry', 'src', 'main', 'ets', 'services', 'CanonModelImages.ets')
LIBGPHOTO = r'C:\Users\HQ\Desktop\picture\libgphoto2-master\camlibs\ptp2\library.c'

# Cosmetic fixes on top of libgphoto2's canonical names.
NAME_FIX = {
    'EOS 6d Mark II': 'EOS 6D Mark II',
    'EOS 7D MarkII': 'EOS 7D Mark II',
    'EOS 1D X MarkII': 'EOS-1D X Mark II',
    'EOS 1D X MarkIII': 'EOS-1D X Mark III',
    'EOS M50m2': 'EOS M50 Mark II',
    'EOS R6m2': 'EOS R6 Mark II',
    'EOS 5Rm2': 'EOS R5 Mark II',
    'SX 720HS': 'PowerShot SX720 HS',
    'SX 620HS': 'PowerShot SX620 HS',
    'PowerShot S110 (PTP Mode)': 'PowerShot S110',
    'Digital PowerShot SX730HS': 'PowerShot SX730 HS',
    'PowerShot Elph340HS': 'PowerShot ELPH 340 HS',
    'PowerShot ELPH 350 HS': 'PowerShot ELPH 350 HS',
    'PowerShot SX60HS': 'PowerShot SX60 HS',
    'PowerShot SX280HS': 'PowerShot SX280 HS',
    'PowerShot A3500IS': 'PowerShot A3500 IS',
    'PowerShot SX510 HS': 'PowerShot SX510 HS',
}

# Series classification (only used for grouping in the app).
def series_of(name: str) -> str:
    if name.startswith('EOS R') or name.startswith('EOS-1D') or name in ('EOS R', 'EOS RP', 'EOS R3', 'EOS R5', 'EOS R6'):
        if re.match(r'^EOS R\d', name) or name in ('EOS R', 'EOS RP'):
            return 'EOS R'
        return 'EOS'
    if name.startswith('EOS M'):
        return 'EOS M'
    if name.startswith('PowerShot') or name.startswith('SX '):
        return 'PowerShot'
    if 'IXUS' in name or 'ELPH' in name or 'Rebel' in name:
        return 'IXUS'
    if name.startswith('EOS'):
        return 'EOS'
    return 'Other'


def slug_of(model: str) -> str:
    s = model.lower()
    s = s.replace('eos-', 'eos_').replace('eos ', 'eos_')
    s = re.sub(r'[^a-z0-9]+', '_', s).strip('_')
    return s or 'unknown'


def load_pid_names() -> dict:
    text = open(LIBGPHOTO, encoding='utf-8', errors='ignore').read()
    rows = re.findall(r'\{"Canon:([^"]+)",\s*0x04a9,\s*0x([0-9a-fA-F]{4})', text)
    out = {}
    for name, pid in rows:
        out.setdefault(int(pid, 16), []).append(NAME_FIX.get(name, name))
    return out


def has_transparent_ring(a: np.ndarray) -> bool:
    ring = np.concatenate([a[0, :, 3], a[-1, :, 3], a[:, 0, 3], a[:, -1, 3]])
    return bool((ring == 0).all())


def remove_background(a: np.ndarray) -> tuple:
    """Flood-fill the outer near-white background into transparency.

    Returns (new array, removed_pixel_count). Only used for images whose border
    is not already transparent.
    """
    h, w = a.shape[:2]
    rgb = a[:, :, :3].astype(np.int16)
    alpha = a[:, :, 3]
    near_white = (rgb.min(axis=2) >= 235) & (alpha > 0)
    visited = np.zeros((h, w), dtype=bool)
    removed = 0
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if near_white[y, x] and not visited[y, x]:
                visited[y, x] = True
                q.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if near_white[y, x] and not visited[y, x]:
                visited[y, x] = True
                q.append((y, x))
    while q:
        y, x = q.popleft()
        a[y, x, 3] = 0
        removed += 1
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and near_white[ny, nx] and not visited[ny, nx]:
                visited[ny, nx] = True
                q.append((ny, nx))
    if removed:
        # De-fringe: the 1px boundary of the removed region keeps the white
        # matte in its RGB; fade its alpha so it does not look like a halo.
        edge = np.zeros((h, w), dtype=bool)
        solid = a[:, :, 3] > 0
        eroded = np.zeros((h, w), dtype=bool)
        eroded[1:-1, 1:-1] = (
            solid[1:-1, 1:-1] & solid[:-2, 1:-1] & solid[2:, 1:-1] &
            solid[1:-1, :-2] & solid[1:-1, 2:])
        edge = solid & ~eroded
        a[edge, 3] = (a[edge, 3].astype(np.int16) * 0.72).astype(np.uint8)
    return a, removed


def main() -> None:
    pid_names = load_pid_names()
    os.makedirs(DELIVER, exist_ok=True)
    os.makedirs(RAWFILE, exist_ok=True)
    shadow_dir = os.path.join(DELIVER, 'shadows')
    os.makedirs(shadow_dir, exist_ok=True)

    # Prefer the nodpi variant: one canonical 480x360 bitmap per PID.
    sources = {}
    for root, _dirs, files in os.walk(APK_RES):
        for f in files:
            m = re.match(r'^camera_([0-9a-f]{4})\.png$', f)
            if not m:
                continue
            pid = int(m.group(1), 16)
            if pid not in sources or os.path.basename(root) == 'drawable-nodpi':
                sources[pid] = os.path.join(root, f)

    records = []
    kept = fg_removed = 0
    for pid in sorted(sources):
        names = pid_names.get(pid, [])
        model = names[0] if names else 'Canon 0x%04X' % pid
        slug = slug_of(model)
        im = Image.open(sources[pid]).convert('RGBA')
        arr = np.array(im)
        removed = 0
        if has_transparent_ring(arr):
            kept += 1
        else:
            arr, removed = remove_background(arr)
            fg_removed += 1
        out_im = Image.fromarray(arr, 'RGBA')
        if out_im.width > 700:
            h = round(out_im.height * 700 / out_im.width)
            out_im = out_im.resize((700, h), Image.LANCZOS)
        deliver_name = model + '.png'
        out_im.save(os.path.join(DELIVER, deliver_name), 'PNG', optimize=True)
        out_im.save(os.path.join(RAWFILE, slug + '.png'), 'PNG', optimize=True)
        records.append({
            'pid': pid,
            'pidHex': '%04x' % pid,
            'model': model,
            'slug': slug,
            'series': series_of(model),
            'deliverable': deliver_name,
            'rawfile': 'canon/' + slug + '.png',
            'backgroundRemovedPixels': removed,
        })

    # Shadow overlays are part of the same Canon art set; keep them out of the
    # product table but deliver them for completeness.
    shadows = []
    for root, _dirs, files in os.walk(APK_RES):
        for f in sorted(files):
            m = re.match(r'^(camera_shadow_[0-9]{3})\.png$', f)
            if not m or os.path.basename(root) != 'drawable-nodpi':
                continue
            src = os.path.join(root, f)
            dst = os.path.join(shadow_dir, m.group(1) + '.png')
            Image.open(src).convert('RGBA').save(dst, 'PNG', optimize=True)
            shadows.append({'name': m.group(1), 'file': 'shadows/' + m.group(1) + '.png'})

    with open(os.path.join(DELIVER, 'manifest.json'), 'w', encoding='utf-8') as fp:
        json.dump({'source': 'Canon Camera Connect 1171631.apk',
                   'package': 'jp.co.canon.ic.cameraconnect',
                   'version': '3.4.30.17-cn',
                   'count': len(records),
                   'cameras': records,
                   'shadows': shadows}, fp, ensure_ascii=False, indent=1)

    readme = [
        '# Canon 机身素材（自动生成）',
        '',
        '来源：Canon Camera Connect `1171631.apk`（`jp.co.canon.ic.cameraconnect` '
        '3.4.30.17-cn）的 `res/drawable-nodpi/camera_<产品ID>.png`。',
        '',
        '- 共 %d 张机身图 + %d 张阴影叠加图；' % (len(records), len(shadows)),
        '- 背景已确认为透明：%d 张原图固带 alpha，%d 张经边缘泛洪去背；' % (kept, fg_removed),
        '- 文件名使用官方机型名（产品 ID 见 `manifest.json`）；',
        '- 应用内同一份像素位于 `entry/src/main/resources/rawfile/canon/<slug>.png`。',
        '',
        '未收录机型：%s' % ', '.join(r['model'] for r in records if r['model'].startswith('Canon 0x')),
    ]
    open(os.path.join(DELIVER, 'README.md'), 'w', encoding='utf-8').write('\n'.join(readme) + '\n')

    lines = []
    lines.append('/**')
    lines.append(' * Canon 机身素材表（自动生成，勿手改；生成脚本 tools/build_canon_art.py）。')
    lines.append(' * 来源：Canon Camera Connect 3.4.30.17-cn 的 drawable-nodpi/camera_<PID>.png，')
    lines.append(' * 已确认/处理为透明背景；资源位置 resources/rawfile/canon/<slug>.png。')
    lines.append(' * pid 即相机 BLE 广播厂商数据（Company ID 425）里的 usbId，也是固件清单的产品 ID。')
    lines.append(' */')
    lines.append('export interface CanonModelArt {')
    lines.append('  pid: number;')
    lines.append('  pidHex: string;')
    lines.append('  model: string;')
    lines.append('  slug: string;')
    lines.append('  series: string;')
    lines.append('}')
    lines.append('')
    lines.append('export class CanonModelImages {')
    lines.append('  static readonly ALL: CanonModelArt[] = [')
    for r in records:
        lines.append("    { pid: 0x%s, pidHex: '%s', model: '%s', slug: '%s', series: '%s' }," % (
            r['pidHex'], r['pidHex'], r['model'].replace("'", "\\'"),
            r['slug'], r['series']))
    lines.append('  ];')
    lines.append('')
    lines.append('  /** 归一化：大写、只保留字母数字（EOS R5 == EOSR5）。 */')
    lines.append('  static normalize(name: string): string {')
    lines.append("    let out = '';")
    lines.append('    const upper = (name || \'\').toUpperCase();')
    lines.append('    for (let i = 0; i < upper.length; i++) {')
    lines.append('      const ch = upper.charAt(i);')
    lines.append("      if ((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) out += ch;")
    lines.append('    }')
    lines.append('    return out;')
    lines.append('  }')
    lines.append('')
    lines.append('  /** 产品 ID -> 素材；未收录返回 null。 */')
    lines.append('  static byPid(pid: number): CanonModelArt | null {')
    lines.append('    for (const art of CanonModelImages.ALL) {')
    lines.append('      if (art.pid === pid) return art;')
    lines.append('    }')
    lines.append('    return null;')
    lines.append('  }')
    lines.append('')
    lines.append('  /** 机型名 -> 素材（精确优先，再最长包含）；未收录返回 null。 */')
    lines.append('  static find(name: string): CanonModelArt | null {')
    lines.append('    const key = CanonModelImages.normalize(name);')
    lines.append('    if (key.length === 0) return null;')
    lines.append('    for (const art of CanonModelImages.ALL) {')
    lines.append('      if (CanonModelImages.normalize(art.model) === key) return art;')
    lines.append('    }')
    lines.append('    let best: CanonModelArt | null = null;')
    lines.append('    let bestLen = 0;')
    lines.append('    for (const art of CanonModelImages.ALL) {')
    lines.append('      const artKey = CanonModelImages.normalize(art.model);')
    lines.append('      if (artKey.length < 3 || key.indexOf(artKey) < 0) continue;')
    lines.append('      if (artKey.length > bestLen) { best = art; bestLen = artKey.length; }')
    lines.append('    }')
    lines.append('    return best;')
    lines.append('  }')
    lines.append('')
    lines.append('  /** 未收录 PID 的展示名：`EOS 0x32FB` 之类，绝不伪造机型。 */')
    lines.append("  static fallbackModel(pid: number): string {")
    lines.append("    return pid > 0 ? 'Canon 0x' + pid.toString(16).toUpperCase() : 'Canon';")
    lines.append('  }')
    lines.append('}')
    open(ETS, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')

    total_mb = sum(os.path.getsize(os.path.join(RAWFILE, f)) for f in os.listdir(RAWFILE)) / 1048576.0
    print('cameras=%d shadows=%d transparent_kept=%d bg_removed=%d rawfile_MB=%.2f' % (
        len(records), len(shadows), kept, fg_removed, total_mb))
    print('unknown:', [r['model'] for r in records if r['model'].startswith('Canon 0x')])


if __name__ == '__main__':
    main()
