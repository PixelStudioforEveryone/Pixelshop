/*
 * CPU reference stage for DCP integration.
 *
 * This deliberately accepts only a caller-provided linear camera-RGB dump.
 * It never opens a PixelMap/JPEG and never claims to decode RW2. The current
 * reference applies the selected DCP ColorMatrix as a high-precision matrix
 * step and records the DCP stages that are intentionally not applied yet.
 * This makes the boundary testable before a LibRaw/Native decoder is added.
 *
 * Usage:
 *   node dcp_cpu_reference.js <dcp-json> <linear-rgb-json> <output-json>
 *
 * Input JSON:
 *   { "source": { ... }, "samples": [[r,g,b], ...] }
 * Values are normalized linear camera RGB; no clipping is performed.
 */
const fs = require('fs');

function fail(message) { console.error('ERROR: ' + message); process.exit(2); }
function finiteArray(value, length, name) {
  if (!Array.isArray(value) || value.length !== length || value.some((x) => typeof x !== 'number' || !Number.isFinite(x))) {
    fail(name + ' must contain ' + length + ' finite numbers');
  }
  return value;
}
function apply3x3(matrix, rgb) {
  return [
    matrix[0] * rgb[0] + matrix[1] * rgb[1] + matrix[2] * rgb[2],
    matrix[3] * rgb[0] + matrix[4] * rgb[1] + matrix[5] * rgb[2],
    matrix[6] * rgb[0] + matrix[7] * rgb[1] + matrix[8] * rgb[2],
  ];
}

const [dcpPath, inputPath, outputPath] = process.argv.slice(2);
if (!dcpPath || !inputPath || !outputPath) fail('usage: node dcp_cpu_reference.js <dcp-json> <linear-rgb-json> <output-json>');
const dcp = JSON.parse(fs.readFileSync(dcpPath, 'utf8'));
const input = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
const fields = dcp.parsedFields || {};
const matrix = finiteArray(fields.colorMatrix1, 9, 'DCP colorMatrix1');
if (!input || input.source?.sourceKind !== 'linear_camera_rgb') {
  fail('input source.sourceKind must be linear_camera_rgb; embedded JPEG/system RGBA is rejected');
}
if (!Array.isArray(input.samples) || input.samples.length === 0) fail('input samples must be a non-empty array');
const samples = input.samples.map((sample, index) => finiteArray(sample, 3, 'sample[' + index + ']'));
const output = {
  contract: {
    inputSourceKind: 'linear_camera_rgb',
    inputColorSpace: input.source.colorSpace || 'unknown',
    inputTransferFunction: input.source.transferFunction || 'linear',
    outputColorSpace: 'DCP ColorMatrix1 result (XYZ/reference space requires profile illuminant handling)',
    dcpApplied: true,
    stagesApplied: ['ColorMatrix1'],
    stagesNotApplied: ['black-level', 'white-level', 'white-balance', 'camera-calibration', 'forward-matrix', 'tone-curve', 'hue-sat-map', 'look-table', 'display encoding'],
    warning: 'Reference only; do not use as a complete DCP renderer or display-ready image.',
  },
  dcp: { sourceFile: dcp.sourceFile, uniqueCameraModel: fields.uniqueCameraModel || 'unknown', profileName: fields.profileName || 'unknown', matrixTag: 'ColorMatrix1' },
  samples: samples.map((rgb) => apply3x3(matrix, rgb)),
};
fs.writeFileSync(outputPath, JSON.stringify(output, null, 2), 'utf8');
console.log(outputPath + ' samples=' + output.samples.length + ' stages=ColorMatrix1');
