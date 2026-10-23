// Read-only RW2/TIFF probe. It reports container facts only; it never claims
// that the embedded JPEG is linear RAW data.
const fs = require('fs');
function probe(file) {
  const b = fs.readFileSync(file); const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const little = v.getUint8(0) === 0x49; const magic = v.getUint16(2, little);
  const typeSize = {1:1,2:1,3:2,4:4,5:8,6:1,7:1,8:2,9:4,10:8,11:4,12:8};
  const read = (p,t,n) => { const out=[]; for(let i=0;i<n;i++){const q=p+i*typeSize[t]; if(t===3)out.push(v.getUint16(q,little)); else if(t===4)out.push(v.getUint32(q,little)); else if(t===1||t===7)out.push(v.getUint8(q)); else if(t===2)out.push(String.fromCharCode(v.getUint8(q))); else if(t===11)out.push(v.getFloat32(q,little));} return out; };
  const tags = {}; const previews=[]; const seen=new Set();
  function ifd(off){ if(!off||seen.has(off)||off+2>b.length)return; seen.add(off); const n=v.getUint16(off,little); for(let i=0;i<n;i++){const p=off+2+i*12;if(p+12>b.length)break;const tag=v.getUint16(p,little),t=v.getUint16(p+2,little),cnt=v.getUint32(p+4,little),sz=typeSize[t]||1,total=sz*cnt;const pos=total<=4?p+8:v.getUint32(p+8,little); if(pos+total>b.length)continue; if([256,257,258,259,262,277,278,279,33421,33422,34675].includes(tag))tags['0x'+tag.toString(16)]=read(pos,t,Math.min(cnt,32)); if(tag===513||tag===514){const x=v.getUint32(pos,little);if(x>0&&x<b.length)previews.push({offset:x,length:tag===513?v.getUint32(p+8,little):0});} if(tag===330||tag===34665||tag===34853||tag===0x14a)for(let j=0;j<cnt;j++)ifd(v.getUint32(pos+j*4,little));} const next=v.getUint32(off+2+n*12,little);if(next)ifd(next); }
  ifd(v.getUint32(4,little));
  const modelStart = b.indexOf('Panasonic');
  const modelParts = modelStart >= 0 ? b.slice(modelStart, modelStart + 48).toString('ascii').split('\0') : [];
  const model = modelParts.filter((s) => /^[\x20-\x7e]+$/.test(s) && s.length > 1).slice(0, 2).join(' ') || 'unknown';
  function jpegSize(start) {
    for (let p = start + 2; p + 9 < b.length; p++) {
      if (b[p] !== 0xff) continue;
      const marker = b[p + 1];
      if (marker === 0xd8 || marker === 0xd9 || marker === 0x00) continue;
      if (marker >= 0xc0 && marker <= 0xc3 || marker >= 0xc5 && marker <= 0xc7 || marker >= 0xc9 && marker <= 0xcb || marker >= 0xcd && marker <= 0xcf) {
        return { width: b.readUInt16BE(p + 7), height: b.readUInt16BE(p + 5) };
      }
      if (marker === 0xda) break;
      const segmentLength = b.readUInt16BE(p + 2);
      if (!segmentLength || p + 2 + segmentLength > b.length) break;
      p += segmentLength;
    }
    return { width: null, height: null };
  }
  const jpegCandidates=[]; for(let i=0;i<b.length-1;i++){if(b[i]!==0xff||b[i+1]!==0xd8)continue;let e=b.indexOf(Buffer.from([0xff,0xd9]),i+2);if(e>0){const size=jpegSize(i);jpegCandidates.push({offset:i,length:e+2-i,width:size.width,height:size.height});}if(jpegCandidates.length>=16)break;}
  return {file,bytes:b.length,container:'TIFF/RW2',byteOrder:little?'II':'MM',tiffMagic:magic,
    modelHint:model,ifdTags:tags,metadataStatus:Object.keys(tags).length === 0 ? 'standard TIFF dimensions were not exposed by the Panasonic proprietary root IFD' : 'standard TIFF tags found',
    embeddedJpegCandidates:jpegCandidates.sort((a,c)=>c.length-a.length).slice(0,8),
    outputContract:{sourceKind:'embedded_jpeg_preview_or_system_decoder_rgba',linearCameraRgb:false,
      colorSpace:'unknown',transferFunction:'unknown for system decoder; display-rendered JPEG for fallback',dcpApplied:false}};
}
const file=process.argv[2], out=process.argv[3]; if(!file||!out){console.error('usage: node raw_probe.js <rw2> <json>');process.exit(2);} const result=probe(file);fs.mkdirSync(require('path').dirname(out),{recursive:true});fs.writeFileSync(out,JSON.stringify(result,null,2));console.log(JSON.stringify(result,null,2));
