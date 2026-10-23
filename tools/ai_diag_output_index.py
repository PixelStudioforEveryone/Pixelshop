"""Identify which ONNX output index corresponds to the ncnn `out0` blob.

The ncnn conversion is named out0..out6 by pnnx, which is not guaranteed to
follow the ONNX graph's own output order. This diagnostic runs both runtimes on
one identical tensor and prints the agreement of ncnn out0 against every ORT
output, so the native extractor can be pointed at the right blob with evidence
rather than assumption.
"""
import os
import sys

import numpy as np
from PIL import Image

import ncnn
import onnxruntime as ort

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONVERTED = os.path.join(REPO, 'tmp', 'ai-mask-converter', 'out')
ONNX = os.path.join(REPO, 'tmp', 'ai-mask-deps', 'u2netp.onnx')
FIXTURES = os.path.join(REPO, 'tmp', 'ai-mask-deps', 'fixtures', 'u2net', 'U-2-Net-master')
SAMPLE = os.path.join(FIXTURES, 'test_data', 'test_images', 'girl.png')
SIDE = 320
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


def build_input():
    image = Image.open(SAMPLE).convert('RGB').resize((SIDE, SIDE), Image.BILINEAR)
    array = np.asarray(image, dtype=np.float32) / 255.0
    array = array / float(array.max())
    array = (array - MEAN) / STD
    return np.ascontiguousarray(array.transpose(2, 0, 1)[None, ...])


def pearson(a, b):
    a = a.ravel().astype(np.float64)
    b = b.ravel().astype(np.float64)
    a = a - a.mean()
    b = b - b.mean()
    denominator = float(np.sqrt((a * a).sum() * (b * b).sum()))
    return float((a * b).sum() / denominator) if denominator > 1e-12 else 0.0


def main():
    nchw = build_input()

    net = ncnn.Net()
    net.opt.use_vulkan_compute = False
    net.opt.use_fp16_packed = False
    net.opt.use_fp16_storage = False
    net.opt.use_fp16_arithmetic = False
    net.load_param(os.path.join(CONVERTED, 'u2netp.ncnn.param'))
    net.load_model(os.path.join(CONVERTED, 'u2netp.ncnn.bin'))
    extractor = net.create_extractor()
    extractor.set_light_mode(True)
    extractor.input('in0', ncnn.Mat(nchw[0]).clone())
    ncnn_outs = {}
    for name in ['out%d' % index for index in range(7)]:
        code, out = extractor.extract(name)
        if code == 0:
            ncnn_outs[name] = np.squeeze(np.array(out, dtype=np.float32))

    session = ort.InferenceSession(ONNX, providers=['CPUExecutionProvider'])
    input_name = session.get_inputs()[0].name
    output_names = [output.name for output in session.get_outputs()]
    ort_outs = session.run(None, {input_name: nchw})

    print('ORT input name : %s %s' % (input_name, session.get_inputs()[0].shape))
    print('ORT outputs    : %s' % output_names)
    print('ncnn outputs   : %s' % sorted(ncnn_outs.keys()))
    for name, values in ncnn_outs.items():
        print('  %s shape=%s range=[%.4f, %.4f]' % (name, values.shape, values.min(), values.max()))

    print('\nagreement of ncnn out0 with each ORT output:')
    target = ncnn_outs['out0']
    for index, values in enumerate(ort_outs):
        plane = np.squeeze(values)
        if plane.shape != target.shape:
            print('  [%d] %-12s shape %s != %s' % (index, output_names[index], plane.shape, target.shape))
            continue
        print('  [%d] %-12s corr=%.6f maxAbs=%.6f range=[%.4f, %.4f]' % (
            index, output_names[index], pearson(target, plane),
            float(np.abs(target - plane).max()), plane.min(), plane.max()))

    print('\nfull cross matrix (correlation):')
    header = 'ncnn\\ort   ' + ' '.join('%9d' % index for index in range(len(ort_outs)))
    print(header)
    for name in sorted(ncnn_outs.keys()):
        row = ['%9.4f' % pearson(ncnn_outs[name], np.squeeze(ort_outs[index])) for index in range(len(ort_outs))]
        print('%-10s ' % name + ' '.join(row))
    return 0


if __name__ == '__main__':
    sys.exit(main())
