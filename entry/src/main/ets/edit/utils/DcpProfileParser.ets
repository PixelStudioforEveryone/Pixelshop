export interface ParsedDcpProfile { model: string; name: string; fields: Map<number, number[]>; }

/** Pure parser, usable by TaskPool and the CPU reference checks. */
export function parseDcpProfile(data: ArrayBuffer, model: string, name: string, fixed: boolean): ParsedDcpProfile {
  const result: ParsedDcpProfile = { model: model, name: name, fields: new Map() };
    const v = new DataView(data);
    const le = v.getUint16(0, false) === 0x4949;
    if (!le && v.getUint16(0, false) !== 0x4d4d) throw new Error('Invalid byte order');
    const magic = v.getUint16(2, le);
    if (magic !== 0x4352 && magic !== 42) throw new Error('Unsupported DCP container');
    const offset = v.getUint32(4, le);
    const count = v.getUint16(offset, le);
    if (count > 4096 || offset + 2 + count * 12 > data.byteLength) throw new Error('Invalid IFD');
    for (let i = 0; i < count; i++) {
      const p = offset + 2 + i * 12;
      const tag = v.getUint16(p, le), type = v.getUint16(p + 2, le), n = v.getUint32(p + 4, le);
      const size = type === 1 || type === 2 || type === 7 ? 1 : type === 3 ? 2 : type === 4 || type === 11 ? 4 : type === 5 || type === 10 ? 8 : 0;
      if (size === 0) throw new Error('Unsupported DCP field type ' + type);
      const start = size * n <= 4 ? p + 8 : v.getUint32(p + 8, le);
      if (n > 2000000 || start + n * size > data.byteLength) throw new Error('DCP field out of bounds');
      if (type === 2) {
        let text = '';
        for (let j = 0; j < n && v.getUint8(start + j) !== 0; j++) text += String.fromCharCode(v.getUint8(start + j));
        // Fixed profiles keep their picker-facing model/name from the bundle
        // path; their internal UniqueCameraModel (e.g. "Panasonic DC-S5")
        // would otherwise leak them into the model-matched picker list.
        if (tag === 0xc614 && !fixed) result.model = text;
        if (tag === 0xc6f8 && !fixed) result.name = text;
      } else {
        const values: number[] = [];
        for (let j = 0; j < n; j++) {
          const q = start + j * size;
          let value = 0;
          if (type === 1 || type === 7) value = v.getUint8(q);
          else if (type === 3) value = v.getUint16(q, le);
          else if (type === 4) value = v.getUint32(q, le);
          else if (type === 11) value = v.getFloat32(q, le);
          else {
            const denominator = type === 10 ? v.getInt32(q + 4, le) : v.getUint32(q + 4, le);
            if (denominator === 0) throw new Error('Zero rational denominator');
            value = (type === 10 ? v.getInt32(q, le) : v.getUint32(q, le)) / denominator;
          }
          if (!Number.isFinite(value)) throw new Error('Nonfinite DCP value');
          values.push(value);
        }
        result.fields.set(tag, values);
      }
    }
    for (const tag of [0xc621, 0xc622, 0xc714, 0xc715]) {
      const matrix = result.fields.get(tag);
      if (matrix && matrix.length !== 9) throw new Error('Unsupported matrix dimensions');
    }
    for (const pair of [[0xc6f9, 0xc6fa], [0xc6f9, 0xc6fb], [0xc725, 0xc726]]) {
      const table = result.fields.get(pair[1]);
      const dims = result.fields.get(pair[0]);
      if (table && (!dims || dims.length !== 3 || dims.some((n: number) => n < 1 || !Number.isInteger(n)) || table.length !== dims[0] * dims[1] * dims[2] * 3)) throw new Error('Invalid DCP table dimensions');
    }
    if (!result.model || !result.name) throw new Error('Missing profile identity');
  return result;
}
