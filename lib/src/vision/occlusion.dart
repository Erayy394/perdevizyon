import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'dart:math' as math;
import '../ml/seg_model.dart';

/// Apply foreground occlusion by restoring original pixels where mask > 0, with feather.
Future<File> applyForegroundOcclusion({
  required File compositedFile,
  required File originalPhoto,
  required List<int> occluderMask, // 0..255, flattened W*H of composited size
  required int width,
  required int height,
  required int featherPx,
  required String outputPath,
}) async {
  final comp = img.decodeImage(await compositedFile.readAsBytes())!;
  final orig = img.decodeImage(await originalPhoto.readAsBytes())!;
  final out = img.copyResize(orig, width: comp.width, height: comp.height);
  // Simple blend: out = mask*orig + (1-mask)*comp
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final idx = y * width + x;
      final m = occluderMask[idx] / 255.0;
      if (m <= 0) {
        out.setPixel(x, y, comp.getPixel(x, y));
        continue;
      }
      final po = out.getPixel(x, y);
      final pc = comp.getPixel(x, y);
      final r = (img.getRed(po) * m + img.getRed(pc) * (1 - m)).toInt();
      final g = (img.getGreen(po) * m + img.getGreen(pc) * (1 - m)).toInt();
      final b = (img.getBlue(po) * m + img.getBlue(pc) * (1 - m)).toInt();
      out.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  final bytes = img.encodeJpg(out, quality: 90);
  final f = File(outputPath);
  await f.writeAsBytes(bytes);
  return f;
}

Future<File> applyForegroundOcclusionWithMask({
  required File compositedFile,
  required File originalPhoto,
  required Uint8List fgMask, // 0..255, flattened W*H
  required int featherPx,
  required String outputPath,
}) async {
  final comp = img.decodeImage(await compositedFile.readAsBytes())!;
  final orig = img.decodeImage(await originalPhoto.readAsBytes())!;
  final w = comp.width, h = comp.height;
  final out = img.Image(w, h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final idx = y * w + x;
      final m = (idx < fgMask.length ? fgMask[idx] : 0) / 255.0;
      final po = orig.getPixel(x, y);
      final pc = comp.getPixel(x, y);
      final r = (img.getRed(po) * m + img.getRed(pc) * (1 - m)).toInt();
      final g = (img.getGreen(po) * m + img.getGreen(pc) * (1 - m)).toInt();
      final b = (img.getBlue(po) * m + img.getBlue(pc) * (1 - m)).toInt();
      out.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  final bytes = img.encodeJpg(out, quality: 90);
  final f = File(outputPath);
  await f.writeAsBytes(bytes);
  return f;
}

// ===== Occluder mask (SEG + DEPTH) =====

double _medianOfMask(Float32List depth, Uint8List mask, int W, int H) {
  final vals = <double>[];
  for (int i = 0; i < W * H; i++) {
    if (mask[i] > 0) vals.add(depth[i]);
  }
  if (vals.isEmpty) return 1.0;
  vals.sort();
  return vals[vals.length ~/ 2];
}

Uint8List _morphDilate(Uint8List m, int W, int H, {int radius = 2}) {
  final out = Uint8List.fromList(m);
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      int mx = 0;
      for (int j = -radius; j <= radius; j++) {
        for (int i = -radius; i <= radius; i++) {
          final xx = (x + i).clamp(0, W - 1);
          final yy = (y + j).clamp(0, H - 1);
          if (m[yy * W + xx] > 0) {
            mx = 255;
            j = radius + 1;
            break;
          }
        }
      }
      out[y * W + x] = math.max(out[y * W + x], mx);
    }
  }
  return out;
}

Uint8List _gaussianBlurMask(Uint8List m, int W, int H, {int radius = 2}) {
  final im = img.Image(W, H);
  for (int i = 0; i < W * H; i++) {
    im.data[i] = img.getColor(0, 0, 0, m[i]);
  }
  final b = img.gaussianBlur(im, radius);
  final out = Uint8List(W * H);
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      out[y * W + x] = img.getAlpha(b.getPixel(x, y));
    }
  }
  return out;
}

Uint8List combineOccludersFromSegDepth({
  required List<SegDetection> segs,
  required Float32List depth,
  required int W,
  required int H,
  required Uint8List windowMask,
  required List<int> occluderClassIds,
  double depthMargin = 0.02,
  int dilateRadius = 3,
  int blurRadius = 2,
}) {
  final out = Uint8List(W * H);
  final zWin = _medianOfMask(depth, windowMask, W, H);
  for (final d in segs) {
    if (!occluderClassIds.contains(d.classId)) continue;
    final zObj = _medianOfMask(depth, d.mask, W, H);
    if (zObj + depthMargin < zWin) {
      for (int i = 0; i < W * H; i++) {
        if (d.mask[i] > 0) out[i] = 255;
      }
    }
  }
  final m1 = _morphDilate(out, W, H, radius: dilateRadius);
  final m2 = _gaussianBlurMask(m1, W, H, radius: blurRadius);
  return m2;
}
