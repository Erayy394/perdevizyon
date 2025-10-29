import 'dart:math' as math;
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
// removed unused postprocess import
import 'classes.dart';

class SegDetection {
  final RectF box;
  final int classId;
  final double score;
  final Uint8List mask;
  final int maskW, maskH;
  SegDetection(
      this.box, this.classId, this.score, this.mask, this.maskW, this.maskH);
}

class RectF {
  final double l, t, r, b;
  RectF(this.l, this.t, this.r, this.b);
}

class SegModel {
  final Interpreter _it;
  final int inW, inH;
  final int maskH, maskW, M;

  SegModel._(this._it, this.inW, this.inH, this.maskH, this.maskW, this.M);

  static Future<SegModel> load({
    String asset = 'assets/ml/roomseg.tflite',
    int inputW = 512,
    int inputH = 512,
    int maskH = 160,
    int maskW = 160,
    int M = 32,
    bool useGpu = true,
  }) async {
    final options = InterpreterOptions();
    if (useGpu) {
      try {
        options.addDelegate(GpuDelegateV2());
      } catch (_) {}
    }
    final it = await Interpreter.fromAsset(asset, options: options);
    return SegModel._(it, inputW, inputH, maskH, maskW, M);
  }

  void dispose() => _it.close();

  Future<List<SegDetection>> infer({
    required Float32List imageCHW,
    required int origW,
    required int origH,
    double confThresh = 0.25,
    double iouThresh = 0.5,
    List<int> keepClassIds = const [],
  }) async {
    final o0shape = _it.getOutputTensor(0).shape; // [1,N,5+numClasses+M]
    final o1shape = _it.getOutputTensor(1).shape; // [1,M,h,w]
    final N = o0shape[1];
    final D = o0shape[2];
    final out0 =
        List.generate(1, (_) => List.generate(N, (_) => List.filled(D, 0.0)));
    final out1 = List.generate(
        1,
        (_) => List.generate(
            o1shape[1],
            (_) => List.generate(
                o1shape[2], (_) => List.filled(o1shape[3], 0.0))));

    final input = imageCHW.reshape([1, 3, inH, inW]);
    _it.runForMultipleInputs([input], {0: out0, 1: out1});

    final preds = <_DetRaw>[];
    final letter =
        LetterboxMapper(srcW: origW, srcH: origH, dstW: inW, dstH: inH);
    final proto = out1[0]; // [M,h,w]
    final numClasses = SegClasses.numClasses;
    for (var i = 0; i < N; i++) {
      final p = out0[0][i];
      final cx = p[0], cy = p[1], w = p[2], h = p[3];
      final obj = p[4];
      double bestProb = 0.0;
      int bestCls = -1;
      for (int c = 0; c < numClasses; c++) {
        final sc = p[5 + c];
        if (sc > bestProb) {
          bestProb = sc;
          bestCls = c;
        }
      }
      final score = obj * bestProb;
      if (score < confThresh) continue;
      final lx = cx - w / 2, ty = cy - h / 2, rx = cx + w / 2, by = cy + h / 2;
      final rectInput = RectF(lx, ty, rx, by);
      final rectOrig = letter.inputRectToSrc(rectInput);
      final coeffStart = 5 + numClasses;
      final coeff = p.sublist(coeffStart, coeffStart + M);
      preds.add(_DetRaw(rectOrig, bestCls < 0 ? 0 : bestCls, score, coeff));
    }

    final kept = _nms(preds, iouThresh);
    final dets = <SegDetection>[];
    for (final d in kept) {
      final maskFloat = Float32List(maskH * maskW);
      for (int y = 0; y < maskH; y++) {
        for (int x = 0; x < maskW; x++) {
          double s = 0;
          for (int k = 0; k < M; k++) {
            s += d.coeff[k] * proto[k][y][x];
          }
          final v = 1.0 / (1.0 + math.exp(-s));
          maskFloat[y * maskW + x] = v.toDouble();
        }
      }
      final cropped = _cropAndResizeMask(
          maskFloat, maskW, maskH, d.box, origW, origH,
          thresh: 0.5);
      dets.add(SegDetection(
          d.box, d.classId, d.score, cropped.maskBytes, cropped.w, cropped.h));
    }

    if (keepClassIds.isNotEmpty) {
      return dets.where((e) => keepClassIds.contains(e.classId)).toList();
    }
    return dets;
  }
}

class _DetRaw {
  final RectF box;
  final int classId;
  final double score;
  final List<double> coeff;
  _DetRaw(this.box, this.classId, this.score, this.coeff);
}

class LetterboxMapper {
  final int srcW, srcH, dstW, dstH;
  late final double scale;
  late final double padX, padY;
  LetterboxMapper(
      {required this.srcW,
      required this.srcH,
      required this.dstW,
      required this.dstH}) {
    final r = math.min(dstW / srcW, dstH / srcH);
    scale = r;
    final newW = srcW * r;
    final newH = srcH * r;
    padX = (dstW - newW) / 2.0;
    padY = (dstH - newH) / 2.0;
  }
  RectF inputRectToSrc(RectF r) {
    double lx = ((r.l - padX) / scale).clamp(0, srcW.toDouble());
    double rx = ((r.r - padX) / scale).clamp(0, srcW.toDouble());
    double ty = ((r.t - padY) / scale).clamp(0, srcH.toDouble());
    double by = ((r.b - padY) / scale).clamp(0, srcH.toDouble());
    return RectF(lx, ty, rx, by);
  }
}

double _iou(RectF i, RectF j) {
  final xx1 = math.max(i.l, j.l);
  final yy1 = math.max(i.t, j.t);
  final xx2 = math.min(i.r, j.r);
  final yy2 = math.min(i.b, j.b);
  final inter = math.max(0.0, xx2 - xx1) * math.max(0.0, yy2 - yy1);
  final a = (i.r - i.l) * (i.b - i.t);
  final b = (j.r - j.l) * (j.b - j.t);
  return inter / math.max(1e-6, a + b - inter);
}

List<_DetRaw> _nms(List<_DetRaw> dets, double iouThresh) {
  dets.sort((a, b) => b.score.compareTo(a.score));
  final kept = <_DetRaw>[];
  for (final d in dets) {
    bool ok = true;
    for (final k in kept) {
      if (_iou(d.box, k.box) > iouThresh) {
        ok = false;
        break;
      }
    }
    if (ok) kept.add(d);
  }
  return kept;
}

class _CroppedMask {
  final Uint8List maskBytes;
  final int w, h;
  _CroppedMask(this.maskBytes, this.w, this.h);
}

_CroppedMask _cropAndResizeMask(
    Float32List mask, int mw, int mh, RectF box, int imgW, int imgH,
    {double thresh = 0.5}) {
  final bw = (box.r - box.l).clamp(1, imgW.toDouble()).toInt();
  final bh = (box.b - box.t).clamp(1, imgH.toDouble()).toInt();
  final out = Uint8List(imgW * imgH);
  for (int y = 0; y < bh; y++) {
    for (int x = 0; x < bw; x++) {
      final u = (x / bw) * (mw - 1);
      final v = (y / bh) * (mh - 1);
      final ix = u.floor();
      final iy = v.floor();
      final idx = iy * mw + ix;
      final prob = mask[idx];
      if (prob >= thresh) {
        final px = (box.l + x).toInt();
        final py = (box.t + y).toInt();
        if (px >= 0 && py >= 0 && px < imgW && py < imgH) {
          out[py * imgW + px] = 255;
        }
      }
    }
  }
  return _CroppedMask(out, imgW, imgH);
}
