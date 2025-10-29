import 'dart:math' as math;
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';

class DepthModel {
  final Interpreter _it;
  final int inW, inH;
  DepthModel._(this._it, this.inW, this.inH);

  static Future<DepthModel> load(
      {String asset = 'assets/ml/depth.tflite',
      int inputW = 256,
      int inputH = 256,
      bool useGpu = true}) async {
    final opts = InterpreterOptions();
    if (useGpu) {
      try {
        opts.addDelegate(GpuDelegateV2());
      } catch (_) {}
    }
    final it = await Interpreter.fromAsset(asset, options: opts);
    return DepthModel._(it, inputW, inputH);
  }

  Future<Float32List> inferFloat(
      {required Float32List imageCHW,
      required int outW,
      required int outH}) async {
    // CHW -> NHWC
    final nhwc = Float32List(inW * inH * 3);
    for (int c = 0; c < 3; c++) {
      for (int y = 0; y < inH; y++) {
        for (int x = 0; x < inW; x++) {
          final chwIdx = c * inH * inW + y * inW + x;
          final nhwcIdx = y * inW * 3 + x * 3 + c;
          nhwc[nhwcIdx] = imageCHW[chwIdx];
        }
      }
    }
    final input = nhwc.reshape([1, inH, inW, 3]);
    final out = List.generate(
        1,
        (_) => List.generate(
            inH, (_) => List.generate(inW, (_) => List.filled(1, 0.0))));
    _it.run(input, out);
    return bilinearUpsample(out[0], inW, inH, outW, outH);
  }

  void close() => _it.close();
}

Float32List bilinearUpsample(
    List<List<List<double>>> m, int w, int h, int W, int H) {
  final out = Float32List(W * H);
  for (int y = 0; y < H; y++) {
    final v = (y / (H - 1)) * (h - 1);
    final iy = v.floor();
    final fy = v - iy;
    for (int x = 0; x < W; x++) {
      final u = (x / (W - 1)) * (w - 1);
      final ix = u.floor();
      final fx = u - ix;
      double s = m[iy][ix][0] * (1 - fx) * (1 - fy) +
          m[iy][math.min(ix + 1, w - 1)][0] * (fx) * (1 - fy) +
          m[math.min(iy + 1, h - 1)][ix][0] * (1 - fx) * (fy) +
          m[math.min(iy + 1, h - 1)][math.min(ix + 1, w - 1)][0] * (fx * fy);
      out[y * W + x] = s.toDouble();
    }
  }
  return out;
}
