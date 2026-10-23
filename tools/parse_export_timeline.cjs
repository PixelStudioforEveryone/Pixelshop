// 导出归因：把设备日志里的**权威时间线**解析成一张表，区分 JPG 与 RAW。
//
// 权威来源是 `AppLogStore.add("export format=… total=… stages=…")`（见
// EditorPage.exportImage 的 finally），stages 由 markStage 逐段累计：
//   source / render / pixelmap / scale / frame / encode / gallery
// 其中 render 内部还会出现两类**互斥**的日志，必须分开看：
//   - `VIVID_EDIT_PERF stage=cpu-stages … detail=… bands=…`：**单任务串行** CPU
//     渲染（旧路径），detail 是这个任务内的整帧细节耗时；
//   - `VIVID_EDIT_PERF stage=export-bands … / export-detail …`：**分带并行**路径。
//   - `VIVID_GPU native shader export active` + `stage=export-tiled`：GPU 分块
//     导出。GPU 成功的前提是细节被绕过（buildPasses 对非 bypass 细节返回 null），
//     所以 `export-tiled` 的耗时里**不包含** detail，不能与 cpu-stages 的
//     detail 相加，也不能拿来当“带细节的导出”基线。
//
// 用法：
//   node tools/parse_export_timeline.cjs <log.txt>
//   node tools/parse_export_timeline.cjs --stdin < log.txt
//   node tools/parse_export_timeline.cjs <log.txt> --json
const fs = require('fs');

const args = process.argv.slice(2);
const asJson = args.includes('--json');
const useStdin = args.includes('--stdin');
const file = args.find((a) => !a.startsWith('--'));
if (!useStdin && !file) {
  console.error('usage: node tools/parse_export_timeline.cjs <log.txt> [--json]');
  process.exit(2);
}
const text = useStdin ? fs.readFileSync(0, 'utf8') : fs.readFileSync(file, 'utf8');

function ms(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

// hilog 行首带时间戳；导出总表按出现顺序编号即可，不需要解析日期。
const exportLines = [];
const perfLines = [];
const gpuLines = [];
for (const raw of text.split(/\r?\n/)) {
  const line = raw.trim();
  if (!line) continue;
  if (/export format=/.test(line)) {
    const m = line.match(/export format=(\S+)(.*)$/);
    if (!m) continue;
    const rest = m[2];
    const total = (rest.match(/total=(\d+)ms/) || [])[1];
    const target = (rest.match(/target=(\S+)/) || [])[1] || '';
    const quality = (rest.match(/quality=(\d+)/) || [])[1] || '';
    const stageText = (rest.match(/stages=(.*)$/) || [])[1] || '';
    const stages = [];
    for (const token of stageText.split(/\s+/)) {
      const sm = token.match(/^([a-z_]+):(\d+)ms(.*)$/);
      if (sm) stages.push({ name: sm[1], ms: ms(sm[2]), extra: (sm[3] || '').trim() });
    }
    exportLines.push({ format: m[1], quality, target, totalMs: ms(total), stages });
    continue;
  }
  if (/VIVID_EDIT_PERF stage=(cpu-stages|export-bands|export-detail|export-bands-stitch|export-bands-total|export-prep)/.test(line)) {
    perfLines.push(line);
    continue;
  }
  if (/VIVID_GPU native shader export active|stage=export-tiled|export-tiled/.test(line)) {
    gpuLines.push(line);
  }
}

function fmt(n) {
  return String(Math.round(n)).padStart(6);
}
function bar(share) {
  const width = Math.max(0, Math.min(40, Math.round(share * 40)));
  return '#'.repeat(width).padEnd(40, '.');
}

if (!exportLines.length) {
  console.error('没有找到 `export format=… total=… stages=…` 行。');
  console.error('请确认设备日志级别包含 JSAPP/AppLogStore，或用 --stdin 传入完整日志。');
  process.exit(1);
}

const report = exportLines.map((entry, index) => {
  const known = entry.stages.reduce((sum, s) => sum + s.ms, 0);
  return {
    index: index + 1,
    ...entry,
    namedMs: known,
    unaccountedMs: Math.max(0, entry.totalMs - known),
  };
});

if (asJson) {
  console.log(JSON.stringify({ exports: report, perf: perfLines, gpu: gpuLines }, null, 2));
  process.exit(0);
}

console.log(`导出时间线（${report.length} 次）`);
for (const entry of report) {
  console.log(`\n#${entry.index} format=${entry.format} quality=${entry.quality} ` +
    `target=${entry.target} total=${entry.totalMs}ms`);
  console.log('  stage      ms   share  bar');
  for (const stage of entry.stages) {
    const share = entry.totalMs > 0 ? stage.ms / entry.totalMs : 0;
    console.log(`  ${stage.name.padEnd(9)} ${fmt(stage.ms)}  ` +
      `${String(Math.round(share * 100)).padStart(4)}%  ${bar(share)}` +
      `${stage.extra ? '  ' + stage.extra : ''}`);
  }
  if (entry.unaccountedMs > 0) {
    const share = entry.unaccountedMs / entry.totalMs;
    console.log(`  ${'(other)'.padEnd(9)} ${fmt(entry.unaccountedMs)}  ` +
      `${String(Math.round(share * 100)).padStart(4)}%  ${bar(share)}` +
      '  未计入 stages 的间隔（弹窗/线程切换/GC）');
  }
}

const jpg = report.filter((r) => /jpg|jpeg/i.test(r.format));
const raw = report.filter((r) => !/jpg|jpeg/i.test(r.format));
function average(rows, key) {
  if (!rows.length) return 0;
  return rows.reduce((sum, r) => sum + key(r), 0) / rows.length;
}
if (jpg.length && raw.length) {
  console.log('\nJPG vs RAW 平均（每次导出一行，避免把不同格式混在一起）');
  console.log(`  JPG n=${jpg.length} total=${Math.round(average(jpg, (r) => r.totalMs))}ms`);
  console.log(`  ${raw[0].format} n=${raw.length} total=${Math.round(average(raw, (r) => r.totalMs))}ms`);
  const names = new Set();
  for (const row of report) for (const s of row.stages) names.add(s.name);
  for (const name of names) {
    const j = average(jpg, (r) => (r.stages.find((s) => s.name === name) || { ms: 0 }).ms);
    const o = average(raw, (r) => (r.stages.find((s) => s.name === name) || { ms: 0 }).ms);
    const delta = o - j;
    console.log(`  ${name.padEnd(9)} JPG ${fmt(j)}  ${raw[0].format} ${fmt(o)}  ` +
      `Δ ${delta >= 0 ? '+' : ''}${Math.round(delta)}ms`);
  }
}

console.log('\n渲染阶段明细（按日志顺序，需人工对齐到上面的某一次导出）');
if (!perfLines.length) {
  console.log('  （日志里没有 VIVID_EDIT_PERF 导出阶段行；确认 --keyword VIVID_ 已开启）');
} else {
  for (const line of perfLines) console.log('  ' + line.replace(/^.*?JSAPP:\s*/, ''));
}
if (gpuLines.length) {
  console.log('\nGPU 行（detail 被绕过；不要与 cpu-stages 的 detail 相加）');
  for (const line of gpuLines) console.log('  ' + line.replace(/^.*?JSAPP:\s*/, ''));
}
