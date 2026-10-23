"""Measure real U^2-NetP inference time through ncnn (CPU, 4 threads).

Reports the per-call latency of the 320x320 network so the editor's background
task budget is based on a measurement rather than on the pnnx FLOP estimate.
"""
import os
import sys
import time

import numpy as np
from PIL import Image

import ncnn

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONVERTED = os.path.join(REPO, 'tmp', 'ai-mask-converter', 'out')
FIXTURES = os.path.join(REPO, 'tmp', 'ai-mask-deps', 'fixtures', 'u2net', 'U-2-Net-master')
SAMPLE = os.path.join(FIXTURES, 'test_data', 'test_images', '0002-01.jpg')
SIDE = 320
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


def build_input():
    image = Image.open(SAMPLE).convert('RGB').resize((SIDE, SIDE), Image.BILINEAR)
    array = np.asarray(image, dtype=np.float32) / 255.0
    array = array / float(array.max())
    array = (array - MEAN) / STD
    return np.ascontiguousarray(array.transpose(2, 0, 1))


def main():
    threads = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    runs = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    net = ncnn.Net()
    net.opt.use_vulkan_compute = False
    net.opt.num_threads = threads
    net.load_param(os.path.join(CONVERTED, 'u2netp.ncnn.param'))
    net.load_model(os.path.join(CONVERTED, 'u2netp.ncnn.bin'))
    nchw = build_input()

    timings = []
    for _ in range(runs):
        start = time.perf_counter()
        extractor = net.create_extractor()
        extractor.set_light_mode(True)
        extractor.input('in0', ncnn.Mat(nchw).clone())
        code, out = extractor.extract('out0')
        if code != 0:
            print('extract failed')
            return 1
        timings.append(time.perf_counter() - start)

    timings.sort()
    print('u2netp 320x320  threads=%d  runs=%d' % (threads, runs))
    print('  min=%.3fs  median=%.3fs  max=%.3fs' % (timings[0], timings[len(timings) // 2], timings[-1]))
    print('  output shape=%s' % (np.array(out).shape,))
    return 0


if __name__ == '__main__':
    sys.exit(main())
