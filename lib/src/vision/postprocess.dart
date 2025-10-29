import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:vector_math/vector_math_64.dart' show Vector2;
import '../ml/seg_model.dart';

List<Vector2> estimateQuadFromMask(dynamic win) {
  if (win == null) {
    return [
      Vector2(50, 80),
      Vector2(300, 80),
      Vector2(300, 280),
      Vector2(50, 280)
    ];
  }
  return [
    Vector2(win.box.l, win.box.t),
    Vector2(win.box.r, win.box.t),
    Vector2(win.box.r, win.box.b),
    Vector2(win.box.l, win.box.b),
  ];
}

double medianDepth(Float32List depth, List<int> mask, int w, int h) {
  final vals = <double>[];
  for (int i = 0; i < w * h; i++) {
    if (mask[i] > 0) vals.add(depth[i].toDouble());
  }
  if (vals.isEmpty) return 1.0;
  vals.sort();
  return vals[vals.length ~/ 2];
}

Float32List upsampleDepth(Float32List src,
    {required int width, required int height}) {
  // Stub: return flat mid-depth for compatibility
  final out = Float32List(width * height);
  for (int i = 0; i < out.length; i++) {
    out[i] = 0.5;
  }
  return out;
}

// deprecated simple occluder combiner (kept for reference)

class Quad {
  final List<Offset> pts; // LT, RT, RB, LB
  Quad(this.pts);
}

Quad estimateQuadFromMaskBinary(Uint8List mask, int W, int H) {
  final pts = <Offset>[];
  for (int y = 0; y < H; y += 2) {
    final row = y * W;
    for (int x = 0; x < W; x += 2) {
      if (mask[row + x] > 0) pts.add(Offset(x.toDouble(), y.toDouble()));
    }
  }
  if (pts.length < 4) {
    return Quad([
      const Offset(0, 0),
      Offset(W.toDouble(), 0),
      Offset(W.toDouble(), H.toDouble()),
      Offset(0, H.toDouble())
    ]);
  }
  pts.sort(
      (a, b) => a.dx == b.dx ? a.dy.compareTo(b.dy) : a.dx.compareTo(b.dx));
  List<Offset> lower = [];
  for (final p in pts) {
    while (lower.length >= 2 &&
        _cross(lower[lower.length - 2], lower[lower.length - 1], p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  List<Offset> upper = [];
  for (final p in pts.reversed) {
    while (upper.length >= 2 &&
        _cross(upper[upper.length - 2], upper[upper.length - 1], p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  final hull = <Offset>[...lower..removeLast(), ...upper..removeLast()];
  if (hull.length < 4) {
    final minX = pts.map((p) => p.dx).reduce(math.min);
    final maxX = pts.map((p) => p.dx).reduce(math.max);
    final minY = pts.map((p) => p.dy).reduce(math.min);
    final maxY = pts.map((p) => p.dy).reduce(math.max);
    return Quad([
      Offset(minX, minY),
      Offset(maxX, minY),
      Offset(maxX, maxY),
      Offset(minX, maxY)
    ]);
  }
  double bestArea = double.infinity;
  List<Offset>? best;
  for (int i = 0; i < hull.length; i++) {
    final a = hull[i];
    final b = hull[(i + 1) % hull.length];
    final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
    final cosA = math.cos(-angle), sinA = math.sin(-angle);
    double minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
    for (final p in hull) {
      final rx = p.dx * cosA - p.dy * sinA;
      final ry = p.dx * sinA + p.dy * cosA;
      if (rx < minX) minX = rx;
      if (rx > maxX) maxX = rx;
      if (ry < minY) minY = ry;
      if (ry > maxY) maxY = ry;
    }
    final area = (maxX - minX) * (maxY - minY);
    if (area < bestArea) {
      bestArea = area;
      final corners = <Offset>[
        Offset(minX, minY),
        Offset(maxX, minY),
        Offset(maxX, maxY),
        Offset(minX, maxY),
      ].map((p) {
        final x = p.dx * math.cos(angle) - p.dy * math.sin(angle);
        final y = p.dx * math.sin(angle) + p.dy * math.cos(angle);
        return Offset(x, y);
      }).toList();
      best = _orderClockwise(corners);
    }
  }
  return Quad(best!);
}

double _cross(Offset o, Offset a, Offset b) =>
    (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

List<Offset> _orderClockwise(List<Offset> pts) {
  final cx = pts.map((p) => p.dx).reduce((a, b) => a + b) / pts.length;
  final cy = pts.map((p) => p.dy).reduce((a, b) => a + b) / pts.length;
  pts.sort((p1, p2) {
    final a1 = math.atan2(p1.dy - cy, p1.dx - cx);
    final a2 = math.atan2(p2.dy - cy, p2.dx - cx);
    return a1.compareTo(a2);
  });
  return pts;
}

// ---- Scene helpers ----

// Kareler arası quad yumuşatma
List<Offset> smoothAverage(List<Offset> prev, List<Offset> next,
    {double alpha = 0.3}) {
  if (prev.isEmpty) return next;
  return List.generate(
      4,
      (i) => Offset(
            prev[i].dx * (1 - alpha) + next[i].dx * alpha,
            prev[i].dy * (1 - alpha) + next[i].dy * alpha,
          ));
}

// Üst kenarı biraz yukarı çek (tül/pervaz için)
List<Offset> expandTop(List<Offset> quad, {double px = 4}) {
  if (quad.length != 4) return quad;
  final lt = quad[0], rt = quad[1], rb = quad[2], lb = quad[3];
  final dx = rt.dx - lt.dx, dy = rt.dy - lt.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len == 0) return quad;
  final nx = -dy / len, ny = dx / len; // üst kenarın dış normali
  return [
    Offset(lt.dx + nx * px, lt.dy + ny * px),
    Offset(rt.dx + nx * px, rt.dy + ny * px),
    rb,
    lb,
  ];
}

// Basit dilate (4-neighborhood)
Uint8List morphDilate(Uint8List mask, int W, int H, {int radius = 1}) {
  final out = Uint8List.fromList(mask);
  for (int r = 0; r < radius; r++) {
    final tmp = Uint8List.fromList(out);
    for (int y = 0; y < H; y++) {
      for (int x = 0; x < W; x++) {
        final i = y * W + x;
        if (tmp[i] > 0) continue;
        bool on = false;
        for (final d in const [
          Offset(1, 0),
          Offset(-1, 0),
          Offset(0, 1),
          Offset(0, -1)
        ]) {
          final nx = x + d.dx.toInt();
          final ny = y + d.dy.toInt();
          if (nx >= 0 && ny >= 0 && nx < W && ny < H) {
            if (tmp[ny * W + nx] > 0) {
              on = true;
              break;
            }
          }
        }
        if (on) out[i] = 255;
      }
    }
  }
  return out;
}

// Basit gaussian blur yaklaşımı: komşu ortalaması ile hafif yumuşatma
Uint8List gaussianBlurMask(Uint8List mask, int W, int H, {double sigma = 2.0}) {
  final out = Uint8List.fromList(mask);
  for (int y = 1; y < H - 1; y++) {
    for (int x = 1; x < W - 1; x++) {
      int s = 0;
      for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
          s += mask[(y + j) * W + (x + i)];
        }
      }
      out[y * W + x] = (s / 9).toInt();
    }
  }
  return out;
}

Uint8List combineOccluders({
  required List<dynamic> segs,
  required Float32List depth,
  required int W,
  required int H,
  required Uint8List windowMask,
  required List<int> occluderClassIds,
  double depthMargin = 0.02,
  int dilateRadius = 2,
  double blurSigma = 2.0,
}) {
  double medianOfMask(Uint8List m) {
    final vals = <double>[];
    for (int i = 0; i < W * H; i++) {
      if (m[i] > 0) vals.add(depth[i]);
    }
    if (vals.isEmpty) return 1.0;
    vals.sort();
    return vals[vals.length ~/ 2];
  }

  final zWin = medianOfMask(windowMask);
  final out = Uint8List(W * H);
  for (final d in segs) {
    if (!occluderClassIds.contains(d.classId)) continue;
    final zObj = medianOfMask(d.mask as Uint8List);
    if (zObj + depthMargin < zWin) {
      for (int i = 0; i < W * H; i++)
        if ((d.mask as Uint8List)[i] > 0) out[i] = 255;
    }
  }
  final m1 = morphDilate(out, W, H, radius: dilateRadius);
  final m2 = gaussianBlurMask(m1, W, H, sigma: blurSigma);
  return m2;
}
