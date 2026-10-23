/**
 * 尼康云创「拍摄信息 / 优化校准」同步脚本。
 *
 * 官方方案详情接口需要登录后的 access_token，脚本只负责取数与回填，不做登录：
 *
 *   node tools/nikon-sync-shooting.js --token <ACCESS_TOKEN> [--host global|cn] [--country cn] [--limit 5] [--dry]
 *   node tools/nikon-sync-shooting.js --refresh <REFRESH_TOKEN> [--host global|cn]   # 自动换 access_token（5 分钟有效）
 *
 * token 来自浏览器登录 https://imagingcloud.nikon.com(.cn) 后，开发者工具里
 * `bff/recipe/detail` 请求头中的 `access_token`；refresh_token 来自同一请求链上的
 * Keycloak `/protocol/openid-connect/token` 响应（有效期 1 小时）。
 *
 * 回填字段（写进 entry/src/main/resources/rawfile/NikonCloud/recipes.json）：
 *   recipe.picture_controll_name        → pictureControl
 *   recipe.picture_controll_based       → based
 *   recipe.shooting_information.camera  → camera
 *   recipe.shooting_information.lens    → lens
 *   recipe.shooting_information.focal_length → focal
 *   recipe.shooting_information.place   → place
 *   recipe.shooting_information.time    → time
 *   recipe.camera_setting.shutter_speed → shutter
 *   recipe.camera_setting.aperture      → aperture
 *   recipe.camera_setting.iso_sensitivity → iso
 *   recipe.camera_setting.exposure_compensation → exposureComp
 *   recipe.camera_setting.wb_setting    → whiteBalance
 *   recipe.detail || recipe.outline     → description
 *   detail.short_url                    → shortUrl
 *   recipe.creation_date                → published（清单缺省时）
 */
const fs = require('fs');
const path = require('path');

const HOSTS = {
  global: 'https://api.user.cwp.imagingcloud.nikon.com',
  cn: 'https://api.user.cwp.imagingcloud.nikon.com.cn',
};
/** Keycloak token 端点：access_token 只有 5 分钟，refresh_token 有 1 小时。 */
const AUTH = {
  global: 'https://auth.accounts.cld.nikon.com/auth/realms/user/protocol/openid-connect/token',
  cn: 'https://auth.accounts.cld.nikon.com.cn/auth/realms/user/protocol/openid-connect/token',
};
const CLIENT_ID = 'c0004';
const MANIFEST = path.join(__dirname, '..', 'entry', 'src', 'main', 'resources', 'rawfile', 'NikonCloud', 'recipes.json');

/** 用 refresh_token 换一个新的 access_token（有效期 5 分钟）。 */
async function refreshAccessToken(refreshToken, authUrl) {
  const body = new URLSearchParams({ grant_type: 'refresh_token', client_id: CLIENT_ID, refresh_token: refreshToken });
  const response = await fetch(authUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  const text = await response.text();
  if (!response.ok) throw new Error('刷新 token 失败 ' + response.status + ' :: ' + text.slice(0, 160));
  const payload = JSON.parse(text);
  return payload.access_token;
}

function arg(name, fallback) {
  const index = process.argv.indexOf('--' + name);
  if (index < 0) return fallback;
  const value = process.argv[index + 1];
  return value === undefined ? true : value;
}

function pick(source, key) {
  if (source === null || source === undefined) return '';
  const value = source[key];
  if (value === null || value === undefined) return '';
  return String(value).trim();
}

async function fetchDetail(apiBase, token, country, recipeId) {
  const response = await fetch(apiBase + '/bff/recipe/detail', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'access_token': token,
      'Origin': 'https://imagingcloud.nikon.com',
      'Referer': 'https://imagingcloud.nikon.com/',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36',
    },
    body: JSON.stringify({ country: country, recipeId: recipeId, filter: '', isPagination: 'false' }),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error('HTTP ' + response.status + ' :: ' + text.slice(0, 160));
  }
  try {
    return JSON.parse(text);
  } catch (_error) {
    throw new Error('响应不是 JSON :: ' + text.slice(0, 160));
  }
}

function locateRecipe(payload) {
  if (payload === null || typeof payload !== 'object') return null;
  if (payload.recipe && typeof payload.recipe === 'object') return payload.recipe;
  const data = payload.data;
  if (data && typeof data === 'object') {
    if (data.recipe && typeof data.recipe === 'object') return data.recipe;
    if (data.recipeId !== undefined || data.shooting_information !== undefined) return data;
  }
  if (payload.shooting_information !== undefined) return payload;
  return null;
}

/** 把一条官方响应里的字段合并进清单条目，返回改动的字段数。 */
function mergeRecipe(item, payload) {
  const recipe = locateRecipe(payload);
  if (!recipe) return 0;
  const shooting = recipe.shooting_information || {};
  const cameraSetting = recipe.camera_setting || {};
  const control = pick(recipe, 'picture_controll_name') || pick(recipe, 'pictureControl');
  if (control.length > 0) item.pictureControl = control;
  const fields = {
    based: pick(recipe, 'picture_controll_based'),
    camera: pick(shooting, 'camera'),
    lens: pick(shooting, 'lens'),
    focal: pick(shooting, 'focal_length'),
    place: pick(shooting, 'place'),
    time: pick(shooting, 'time'),
    shutter: pick(cameraSetting, 'shutter_speed'),
    aperture: pick(cameraSetting, 'aperture'),
    iso: pick(cameraSetting, 'iso_sensitivity'),
    exposureComp: pick(cameraSetting, 'exposure_compensation'),
    whiteBalance: pick(cameraSetting, 'wb_setting'),
    description: pick(recipe, 'detail') || pick(recipe, 'outline'),
    shortUrl: payload && typeof payload.short_url === 'string' ? payload.short_url : '',
  };
  let touched = 0;
  for (const key of Object.keys(fields)) {
    if (fields[key].length > 0 && item[key] !== fields[key]) {
      item[key] = fields[key];
      touched++;
    }
  }
  const created = pick(recipe, 'creation_date');
  if (created.length > 0 && (!item.published || item.published.length === 0)) {
    item.published = created.slice(0, 10);
    touched++;
  }
  return touched;
}

async function main() {
  const tokenArg = arg('token', process.env.NIKON_ACCESS_TOKEN || '');
  const refreshArg = arg('refresh', process.env.NIKON_REFRESH_TOKEN || '');
  const fromDirArg = String(arg('from-dir', ''));
  const country = arg('country', 'cn');
  const hostKey = String(arg('host', 'global'));
  const apiBase = HOSTS[hostKey] || HOSTS.global;
  const authUrl = String(arg('auth', AUTH[hostKey] || AUTH.global));
  const limit = Number(arg('limit', '0')) || 0;
  const dryRun = process.argv.includes('--dry');
  let token = tokenArg;
  if (!token && refreshArg) {
    token = await refreshAccessToken(String(refreshArg), authUrl);
    console.log('已用 refresh_token 换取新的 access_token');
  }
  if (!token && fromDirArg.length === 0) {
    console.error('缺少凭证：--token <access_token> / --refresh <refresh_token> / --from-dir <目录>');
    process.exit(2);
  }

  const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
  const items = Array.isArray(manifest) ? manifest : manifest.items;
  if (!Array.isArray(items)) {
    console.error('清单结构异常：找不到 items 数组');
    process.exit(2);
  }
  const targets = items.filter((item) => (item.recipeId || '').length > 0);
  if (fromDirArg.length > 0) {
    // 离线模式：把浏览器里 Save response 出来的 JSON 丢进目录，按 recipe.id 匹配回填。
    const files = fs.readdirSync(fromDirArg).filter((name) => name.toLowerCase().endsWith('.json'));
    let updated = 0;
    for (const name of files) {
      let payload = null;
      try {
        payload = JSON.parse(fs.readFileSync(path.join(fromDirArg, name), 'utf8'));
      } catch (error) {
        console.log(name + ' 不是合法 JSON，跳过');
        continue;
      }
      const recipe = locateRecipe(payload);
      const id = recipe && typeof recipe.id === 'string' ? recipe.id : '';
      const item = items.find((candidate) => candidate.recipeId === id);
      if (!item) {
        console.log(name.padEnd(44) + ' 清单里没有 ' + (id || '该方案'));
        continue;
      }
      const touched = mergeRecipe(item, payload);
      if (touched > 0) updated++;
      console.log(name.padEnd(44) + (touched > 0 ? ` 回填 ${touched} 项` : ' 已是最新'));
    }
    if (!dryRun) {
      fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
    }
    console.log(`\n完成（本地文件模式）：更新 ${updated} 条 → ${MANIFEST}`);
    return;
  }
  const resolved = limit > 0 ? targets.slice(0, limit) : targets;
  let filled = 0;
  let failed = 0;

  for (let index = 0; index < resolved.length; index++) {
    const item = resolved[index];
    process.stdout.write(`[${index + 1}/${resolved.length}] ${item.name} … `);
    try {
      const payload = await fetchDetail(apiBase, token, country, item.recipeId);
      const touched = mergeRecipe(item, payload);
      if (touched > 0) filled++;
      console.log(touched > 0 ? `回填 ${touched} 项` : '已是最新');
    } catch (error) {
      failed++;
      console.log('失败 :: ' + (error && error.message ? error.message : String(error)));
    }
    await new Promise((resolve) => setTimeout(resolve, 150));
  }

  if (dryRun) {
    console.log('\n--dry：未写盘。前 3 条示例：');
    console.log(JSON.stringify(items.slice(0, 3), null, 2));
    return;
  }
  fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
  console.log(`\n完成：更新 ${filled} 条，失败 ${failed} 条 → ${MANIFEST}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
