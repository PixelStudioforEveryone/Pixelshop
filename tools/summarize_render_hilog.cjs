// Local-only hilog parsing. Output is an explicit allowlist; never raw text,
// paths, SSIDs, image names, passwords, HTTP headers or authentication data.
const fs=require('fs');const input=process.argv[2],output=process.argv[3],after=process.argv[4]||'00:00:00';
const bytes=fs.readFileSync(input),lines=bytes.toString(bytes[0]===255&&bytes[1]===254?'utf16le':'utf8').split(/\r?\n/);
const events=[];
for(const line of lines){
 if(!/VIVID_(FRAME|EDIT_PERF|RAW_PERF)/.test(line))continue;
 const time=line.match(/\b\d{2}-\d{2}\s+(\d{2}:\d{2}:\d{2}\.\d{3})/)?.[1];if(!time||time<after)continue;
 const stage=line.match(/stage=([a-z0-9-]+)/i)?.[1],event=line.match(/event=([a-z0-9_]+)/i)?.[1];
 const item={time,...(stage?{stage}:{}),...(event?{event}:{})};
 for(const k of ['ms','elapsed','queueMs','request','run','bands','max']){const v=line.match(new RegExp('\\b'+k+'=(\\d+)'));if(v)item[k]=+v[1];}
 for(const k of ['cache','classic','interactive','ok','cancelled','upload']){const v=line.match(new RegExp('\\b'+k+'=(true|false)'));if(v)item[k]=v[1]==='true';}
 const size=line.match(/\bsize=(\d+)x(\d+)/);if(size)item.size=[+size[1],+size[2]];
 const reason=line.match(/\breason=([a-z-]+)/)?.[1];
 if(['native-cooldown','readback-memory-limit','export-memory-limit','non-quarter-rotation','transform','crop','detail-viewport',
 'legacy-local-adjustments','lut-intensity','lut-missing','lut-table-or-range','pass-limit','newer-preview'].includes(reason))item.reason=reason;
 if(stage||event)events.push(item);
}
const stages={};for(const e of events)if(e.stage&&e.ms!==undefined)(stages[e.stage]??=[]).push(e.ms);
const report={after,events,stages:Object.fromEntries(Object.entries(stages).map(([k,v])=>[k,{count:v.length,min:Math.min(...v),max:Math.max(...v),mean:Math.round(v.reduce((a,b)=>a+b,0)/v.length)}]))};
fs.writeFileSync(output,JSON.stringify(report,null,2));console.log(JSON.stringify({after,stages:report.stages,recent:events.slice(-22)},null,2));
