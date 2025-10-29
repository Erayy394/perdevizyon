import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';
import 'dart:isolate';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart' show Vector2;

enum BlendKind { normal, multiply }

/// polygon: 4 nokta (clockwise), fotoğraf koordinatlarında.
/// opacity: 0..1
Future<File> composeCurtainIntoQuad({
  required File photoFile,
  required String curtainAssetPath,
  required List<Vector2> polygon,
  required double opacity,
  required BlendKind blend,
  required String outputPath,
}) async {
  assert(polygon.length == 4);

  // 1) Fotoğraf ve perdeyi yükle
  final photoBytes = await photoFile.readAsBytes();
  final photo = img.decodeImage(photoBytes)!;

  final assetBytes =
      (await rootBundle.load(curtainAssetPath)).buffer.asUint8List();
  final curtain = img.decodeImage(assetBytes)!;

  // 2) Poligonun bounding rect’ini hesapla
  final xs = polygon.map((p) => p.x).toList();
  final ys = polygon.map((p) => p.y).toList();
  final minX = xs.reduce(math.min).floor().clamp(0, photo.width - 1);
  final maxX = xs.reduce(math.max).ceil().clamp(0, photo.width - 1);
  final minY = ys.reduce(math.min).floor().clamp(0, photo.height - 1);
  final maxY = ys.reduce(math.max).ceil().clamp(0, photo.height - 1);
  final dstW = math.max(1, maxX - minX);
  final dstH = math.max(1, maxY - minY);

  // 3) Perdeyi bounding rect boyutuna ölçekle
  final resizedCurtain = img.copyResize(curtain,
      width: dstW, height: dstH, interpolation: img.Interpolation.average);

  // 4) Poligon maskesi yerine doğrudan nokta-içinde test kullanacağız (daha az bağımlılık)
  bool pointInTriangle(double px, double py, Vector2 a, Vector2 b, Vector2 c) {
    double sign(Vector2 p1, Vector2 p2, Vector2 p3) =>
        (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
    final p = Vector2(px, py);
    final b1 = sign(p, a, b) < 0.0;
    final b2 = sign(p, b, c) < 0.0;
    final b3 = sign(p, c, a) < 0.0;
    return (b1 == b2) && (b2 == b3);
  }
  bool pointInQuad(double px, double py, List<Vector2> quad) {
    return pointInTriangle(px, py, quad[0], quad[1], quad[2]) ||
        pointInTriangle(px, py, quad[0], quad[2], quad[3]);
  }

  // 5) Perdeyi fotoğrafa bindirme: bounding rect alanına yaz, poligon dışını maskele
  //    Basit karışımlar: Normal ve Multiply
  for (int y = 0; y < dstH; y++) {
    final py = minY + y;
    if (py < 0 || py >= photo.height) continue;

    for (int x = 0; x < dstW; x++) {
      final px = minX + x;
      if (px < 0 || px >= photo.width) continue;

      // poligon içinde mi?
      final inside = pointInQuad(px.toDouble(), py.toDouble(), polygon);
      if (!inside) continue;

      final cPix = resizedCurtain.getPixel(x, y);
      double ca = (img.getAlpha(cPix) / 255.0) * opacity; // PNG şeffaflığı * kullanıcı opaklığı

      if (ca <= 0.0) continue;

      final pr = img.getRed(photo.getPixel(px, py)) / 255.0;
      final pg = img.getGreen(photo.getPixel(px, py)) / 255.0;
      final pb = img.getBlue(photo.getPixel(px, py)) / 255.0;

      final cr = img.getRed(cPix) / 255.0;
      final cg = img.getGreen(cPix) / 255.0;
      final cb = img.getBlue(cPix) / 255.0;

      double outR, outG, outB;
      switch (blend) {
        case BlendKind.normal:
          // src over
          outR = cr * ca + pr * (1 - ca);
          outG = cg * ca + pg * (1 - ca);
          outB = cb * ca + pb * (1 - ca);
          break;
        case BlendKind.multiply:
          // multiply sonra alpha ile karıştır
          final mr = pr * cr;
          final mg = pg * cg;
          final mb = pb * cb;
          outR = mr * ca + pr * (1 - ca);
          outG = mg * ca + pg * (1 - ca);
          outB = mb * ca + pb * (1 - ca);
          break;
      }

      final outColor = img.getColor(
        (outR.clamp(0, 1) * 255).toInt(),
        (outG.clamp(0, 1) * 255).toInt(),
        (outB.clamp(0, 1) * 255).toInt(),
        255,
      );
      photo.setPixel(px, py, outColor);
    }
  }

  // 6) Kaydet
  final jpg = img.encodeJpg(photo, quality: 90);
  final outFile = File(outputPath);
  await outFile.writeAsBytes(Uint8List.fromList(jpg));
  return outFile;
}

// === HOMOGRAPHY WARP ===
class _Homography {
  // 3x3 H matrisi
  final List<double> h; // length 9, satır-major
  _Homography(this.h);

  // (x, y) -> (u, v) (projective)
  List<double> map(double x, double y) {
    final a = h;
    final den = (a[6] * x + a[7] * y + a[8]);
    final u = (a[0] * x + a[1] * y + a[2]) / den;
    final v = (a[3] * x + a[4] * y + a[5]) / den;
    return [u, v];
  }
}

/// Dört nokta (src -> dst) için 3x3 homography hesapla.
/// src: (0,0),(w,0),(w,h),(0,h) sırası, dst: kullanıcı dörtgeni (aynı saat yönüyle).
_Homography _computeHomography(List<Vector2> src, List<Vector2> dst) {
  // 8x8 A, 8x1 b (DLT’nin basit lineer formu)
  final A = List.generate(8, (_) => List<double>.filled(8, 0));
  final b = List<double>.filled(8, 0);
  for (int i = 0; i < 4; i++) {
    final x = src[i].x, y = src[i].y;
    final X = dst[i].x, Y = dst[i].y;

    // satır 2*i
    A[2 * i][0] = x;
    A[2 * i][1] = y;
    A[2 * i][2] = 1;
    A[2 * i][3] = 0;
    A[2 * i][4] = 0;
    A[2 * i][5] = 0;
    A[2 * i][6] = -x * X;
    A[2 * i][7] = -y * X;
    b[2 * i] = X;

    // satır 2*i+1
    A[2 * i + 1][0] = 0;
    A[2 * i + 1][1] = 0;
    A[2 * i + 1][2] = 0;
    A[2 * i + 1][3] = x;
    A[2 * i + 1][4] = y;
    A[2 * i + 1][5] = 1;
    A[2 * i + 1][6] = -x * Y;
    A[2 * i + 1][7] = -y * Y;
    b[2 * i + 1] = Y;
  }

  // Ax=b çöz (küçük 8x8 Gauss-Jordan)
  List<double> x = List<double>.from(b);
  // Augmented [A|b]
  final M = List.generate(8, (r) => [...A[r], x[r]]);
  for (int col = 0; col < 8; col++) {
    // pivot bul
    int piv = col;
    double best = M[piv][col].abs();
    for (int r = col + 1; r < 8; r++) {
      final v = M[r][col].abs();
      if (v > best) {
        best = v;
        piv = r;
      }
    }
    // swap
    if (piv != col) {
      final tmp = M[col];
      M[col] = M[piv];
      M[piv] = tmp;
    }
    final pv = M[col][col];
    // ölçekle
    for (int c = col; c <= 8; c++) {
      M[col][c] /= pv;
    }
    // elimine
    for (int r = 0; r < 8; r++) {
      if (r == col) continue;
      final f = M[r][col];
      for (int c = col; c <= 8; c++) {
        M[r][c] -= f * M[col][c];
      }
    }
  }
  // çözümü çıkar
  x = List<double>.generate(8, (r) => M[r][8]);

  // h = [h11 h12 h13; h21 h22 h23; h31 h32 1]
  final h = [
    x[0],
    x[1],
    x[2],
    x[3],
    x[4],
    x[5],
    x[6],
    x[7],
    1.0,
  ];
  return _Homography(h);
}

int getPixelBilinear(img.Image im, double u, double v) {
  final w = im.width, h = im.height;
  // clamp dışı -> şeffaf
  if (u < 0 || v < 0 || u >= w - 1 || v >= h - 1) {
    return img.getColor(0, 0, 0, 0);
  }
  final x = u.floor();
  final y = v.floor();
  final dx = u - x;
  final dy = v - y;

  final p00 = im.getPixel(x, y);
  final p10 = im.getPixel(x + 1, y);
  final p01 = im.getPixel(x, y + 1);
  final p11 = im.getPixel(x + 1, y + 1);

  double lerp(double a, double b, double t) => a + (b - a) * t;

  double r00 = img.getRed(p00).toDouble();
  double g00 = img.getGreen(p00).toDouble();
  double b00 = img.getBlue(p00).toDouble();
  double a00 = img.getAlpha(p00).toDouble();

  double r10 = img.getRed(p10).toDouble();
  double g10 = img.getGreen(p10).toDouble();
  double b10 = img.getBlue(p10).toDouble();
  double a10 = img.getAlpha(p10).toDouble();

  double r01 = img.getRed(p01).toDouble();
  double g01 = img.getGreen(p01).toDouble();
  double b01 = img.getBlue(p01).toDouble();
  double a01 = img.getAlpha(p01).toDouble();

  double r11 = img.getRed(p11).toDouble();
  double g11 = img.getGreen(p11).toDouble();
  double b11 = img.getBlue(p11).toDouble();
  double a11 = img.getAlpha(p11).toDouble();

  final r0 = lerp(r00, r10, dx);
  final g0 = lerp(g00, g10, dx);
  final b0 = lerp(b00, b10, dx);
  final a0 = lerp(a00, a10, dx);

  final r1 = lerp(r01, r11, dx);
  final g1 = lerp(g01, g11, dx);
  final b1 = lerp(b01, b11, dx);
  final a1 = lerp(a01, a11, dx);

  final r = lerp(r0, r1, dy).clamp(0, 255).toInt();
  final g = lerp(g0, g1, dy).clamp(0, 255).toInt();
  final b = lerp(b0, b1, dy).clamp(0, 255).toInt();
  final a = lerp(a0, a1, dy).clamp(0, 255).toInt();

  return img.getColor(r, g, b, a);
}

/// Perdeyi (src: perde PNG köşe dikdörtgeni) -> (dst: seçilen dörtgen) projective warp edip
/// fotoğrafa "src-over" (veya multiply) ile yazar.
Future<File> composeCurtainWithHomography({
  required File photoFile,
  required String curtainAssetPath,
  required List<Vector2> dstQuadPx, // fotoğraf piksel koordinatlarında 4 nokta
  required double opacity, // 0..1
  required BlendKind blend, // normal/multiply
  required String outputPath,
}) async {
  assert(dstQuadPx.length == 4);

  final photoBytes = await photoFile.readAsBytes();
  final photo = img.decodeImage(photoBytes)!;

  final assetBytes =
      (await rootBundle.load(curtainAssetPath)).buffer.asUint8List();
  final curtain = img.decodeImage(assetBytes)!;

  // src quad: perde görselinin köşeleri (0,0) (w,0) (w,h) (0,h) — saat yönü
  final src = <Vector2>[
    Vector2(0, 0),
    Vector2(curtain.width.toDouble(), 0),
    Vector2(curtain.width.toDouble(), curtain.height.toDouble()),
    Vector2(0, curtain.height.toDouble()),
  ];

  // Homography
  final H = _computeHomography(src, dstQuadPx);

  // dst bounding kutusu
  final xs = dstQuadPx.map((p) => p.x).toList();
  final ys = dstQuadPx.map((p) => p.y).toList();
  final minX = xs.reduce(math.min).floor().clamp(0, photo.width - 1);
  final maxX = xs.reduce(math.max).ceil().clamp(0, photo.width - 1);
  final minY = ys.reduce(math.min).floor().clamp(0, photo.height - 1);
  final maxY = ys.reduce(math.max).ceil().clamp(0, photo.height - 1);

  // 3x3 matris tersi (adjoint/det)
  List<double> inv(List<double> a) {
    final det = a[0] * (a[4] * a[8] - a[5] * a[7]) -
        a[1] * (a[3] * a[8] - a[5] * a[6]) +
        a[2] * (a[3] * a[7] - a[4] * a[6]);
    final id = 1.0 / det;
    return [
      (a[4] * a[8] - a[5] * a[7]) * id,
      (a[2] * a[7] - a[1] * a[8]) * id,
      (a[1] * a[5] - a[2] * a[4]) * id,
      (a[5] * a[6] - a[3] * a[8]) * id,
      (a[0] * a[8] - a[2] * a[6]) * id,
      (a[2] * a[3] - a[0] * a[5]) * id,
      (a[3] * a[7] - a[4] * a[6]) * id,
      (a[1] * a[6] - a[0] * a[7]) * id,
      (a[0] * a[4] - a[1] * a[3]) * id,
    ];
  }

  final Hin = _Homography(inv(H.h));

  // Karışım
  for (int y = minY; y <= maxY; y++) {
    for (int x = minX; x <= maxX; x++) {
      // dst (x,y) -> src (u,v)
      final uv = Hin.map(x.toDouble(), y.toDouble());
      final u = uv[0], v = uv[1];

      // perde pikseli (bilinear)
      final pix = getPixelBilinear(curtain, u, v);
      final ca = (img.getAlpha(pix) / 255.0) * opacity;
      if (ca <= 0) continue;

      final p = photo.getPixel(x, y);
      final pr = img.getRed(p) / 255.0;
      final pg = img.getGreen(p) / 255.0;
      final pb = img.getBlue(p) / 255.0;

      final cr = img.getRed(pix) / 255.0;
      final cg = img.getGreen(pix) / 255.0;
      final cb = img.getBlue(pix) / 255.0;

      double outR, outG, outB;
      if (blend == BlendKind.multiply) {
        final mr = pr * cr, mg = pg * cg, mb = pb * cb;
        outR = mr * ca + pr * (1 - ca);
        outG = mg * ca + pg * (1 - ca);
        outB = mb * ca + pb * (1 - ca);
      } else {
        outR = cr * ca + pr * (1 - ca);
        outG = cg * ca + pg * (1 - ca);
        outB = cb * ca + pb * (1 - ca);
      }

      photo.setPixelRgba(
        x,
        y,
        (outR.clamp(0, 1) * 255).toInt(),
        (outG.clamp(0, 1) * 255).toInt(),
        (outB.clamp(0, 1) * 255).toInt(),
        255,
      );
    }
  }

  final jpg = img.encodeJpg(photo, quality: 90);
  final outFile = File(outputPath);
  await outFile.writeAsBytes(jpg);
  return outFile;
}

// === FEATHER & SHADOW YARDIMCILARI ===
double _distancePointToSegment(
    double px, double py, double ax, double ay, double bx, double by) {
  final vx = bx - ax, vy = by - ay;
  final wx = px - ax, wy = py - ay;
  final c1 = vx * wx + vy * wy;
  if (c1 <= 0) return math.sqrt(wx * wx + wy * wy);
  final c2 = vx * vx + vy * vy;
  if (c2 <= c1) return math.sqrt((px - bx) * (px - bx) + (py - by) * (py - by));
  final t = c1 / c2;
  final projx = ax + t * vx, projy = ay + t * vy;
  final dx = px - projx, dy = py - projy;
  return math.sqrt(dx * dx + dy * dy);
}

double _distanceToQuadEdges(double x, double y, List<Vector2> quad) {
  double d = double.infinity;
  for (int i = 0; i < 4; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % 4];
    d = math.min(d, _distancePointToSegment(x, y, a.x, a.y, b.x, b.y));
  }
  return d;
}

double _smoothstep(double edge0, double edge1, double x) {
  final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

// --- Basit downscale (en uzun kenarı maxDim'e kırp) ---
img.Image _downscaleIfNeeded(img.Image im, {int maxDim = 1920}) {
  final w = im.width, h = im.height;
  final longSide = w > h ? w : h;
  if (longSide <= maxDim) return im;
  final scale = maxDim / longSide;
  final nw = (w * scale).round();
  final nh = (h * scale).round();
  return img.copyResize(im,
      width: nw, height: nh, interpolation: img.Interpolation.average);
}

// --- Isolate iş yükü veri modeli ---
class _WarpJob {
  final Uint8List photoBytes;
  final Uint8List curtainBytes;
  final List<double> dstQuadPx; // [x0,y0, x1,y1, x2,y2, x3,y3]
  final double opacity;
  final BlendKind blend;
  final int maxDim;
  _WarpJob(this.photoBytes, this.curtainBytes, this.dstQuadPx, this.opacity,
      this.blend, this.maxDim);
}

// Isolate entry
Future<Uint8List> _warpEntry(_WarpJob job) async {
  final photo = img.decodeImage(job.photoBytes)!;
  final curtain = img.decodeImage(job.curtainBytes)!;

  // fotoğrafı ve polygonu birlikte downscale et
  final origW = photo.width, origH = photo.height;
  final scaledPhoto = _downscaleIfNeeded(photo, maxDim: job.maxDim);
  final sx = scaledPhoto.width / origW;
  final sy = scaledPhoto.height / origH;

  final dst = <Vector2>[
    Vector2(job.dstQuadPx[0] * sx, job.dstQuadPx[1] * sy),
    Vector2(job.dstQuadPx[2] * sx, job.dstQuadPx[3] * sy),
    Vector2(job.dstQuadPx[4] * sx, job.dstQuadPx[5] * sy),
    Vector2(job.dstQuadPx[6] * sx, job.dstQuadPx[7] * sy),
  ];

  // homography warp’ı scaledPhoto üzerinde uygula
  final src = <Vector2>[
    Vector2(0, 0),
    Vector2(curtain.width.toDouble(), 0),
    Vector2(curtain.width.toDouble(), curtain.height.toDouble()),
    Vector2(0, curtain.height.toDouble()),
  ];
  final H = _computeHomography(src, dst);

  // 3x3 ters
  List<double> inv(List<double> m) {
    final a = m;
    final det = a[0] * (a[4] * a[8] - a[5] * a[7]) -
        a[1] * (a[3] * a[8] - a[5] * a[6]) +
        a[2] * (a[3] * a[7] - a[4] * a[6]);
    final id = 1.0 / det;
    return [
      (a[4] * a[8] - a[5] * a[7]) * id,
      (a[2] * a[7] - a[1] * a[8]) * id,
      (a[1] * a[5] - a[2] * a[4]) * id,
      (a[5] * a[6] - a[3] * a[8]) * id,
      (a[0] * a[8] - a[2] * a[6]) * id,
      (a[2] * a[3] - a[0] * a[5]) * id,
      (a[3] * a[7] - a[4] * a[6]) * id,
      (a[1] * a[6] - a[0] * a[7]) * id,
      (a[0] * a[4] - a[1] * a[3]) * id,
    ];
  }

  final Hin = _Homography(inv(H.h));
  // Feather yarıçapı ve gölge maskesi hazırlanışı
  final featherPx = (math.max(scaledPhoto.width, scaledPhoto.height) * 0.006)
      .clamp(8, 16)
      .toDouble();
  final dstQuad = dst;
  // SHADOW: quad içinde kenarlara yakın alanı hafif karart (feather ile)
  const shadowStrength = 0.12;
  final sxs = dst.map((p) => p.x).toList();
  final sys = dst.map((p) => p.y).toList();
  final sMinX = sxs.reduce(math.min).floor().clamp(0, scaledPhoto.width - 1);
  final sMaxX = sxs.reduce(math.max).ceil().clamp(0, scaledPhoto.width - 1);
  final sMinY = sys.reduce(math.min).floor().clamp(0, scaledPhoto.height - 1);
  final sMaxY = sys.reduce(math.max).ceil().clamp(0, scaledPhoto.height - 1);
  bool insideQuad(double px, double py) {
    double sign(Vector2 p1, Vector2 p2, Vector2 p3) =>
        (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
    final p = Vector2(px, py);
    final b1 = sign(p, dst[0], dst[1]) < 0.0;
    final b2 = sign(p, dst[1], dst[2]) < 0.0;
    final b3 = sign(p, dst[2], dst[3]) < 0.0;
    final b4 = sign(p, dst[3], dst[0]) < 0.0;
    return (b1 == b2) && (b2 == b3) && (b3 == b4);
  }
  for (int y = sMinY; y <= sMaxY; y++) {
    for (int x = sMinX; x <= sMaxX; x++) {
      if (!insideQuad(x.toDouble(), y.toDouble())) continue;
      final dist = _distanceToQuadEdges(x.toDouble(), y.toDouble(), dst);
      final ma = _smoothstep(0, featherPx, dist);
      final k = 1.0 - shadowStrength * ma;
      final p = scaledPhoto.getPixel(x, y);
      scaledPhoto.setPixelRgba(
        x, y,
        (img.getRed(p) * k).toInt(),
        (img.getGreen(p) * k).toInt(),
        (img.getBlue(p) * k).toInt(),
        img.getAlpha(p),
      );
    }
  }

  // dst bbox
  final xs = dst.map((p) => p.x).toList();
  final ys = dst.map((p) => p.y).toList();
  final minX = xs.reduce(math.min).floor().clamp(0, scaledPhoto.width - 1);
  final maxX = xs.reduce(math.max).ceil().clamp(0, scaledPhoto.width - 1);
  final minY = ys.reduce(math.min).floor().clamp(0, scaledPhoto.height - 1);
  final maxY = ys.reduce(math.max).ceil().clamp(0, scaledPhoto.height - 1);

  for (int y = minY; y <= maxY; y++) {
    for (int x = minX; x <= maxX; x++) {
      final uv = Hin.map(x.toDouble(), y.toDouble());
      final pix = getPixelBilinear(curtain, uv[0], uv[1]);
      // Feather: kenara yaklaştıkça alfa azalt
      final dist = _distanceToQuadEdges(x.toDouble(), y.toDouble(), dstQuad);
      final feather = _smoothstep(0, featherPx, dist);
      double ca = (img.getAlpha(pix) / 255.0) * job.opacity * feather;
      if (ca <= 0) continue;

      final p = scaledPhoto.getPixel(x, y);
      final pr = img.getRed(p) / 255.0;
      final pg = img.getGreen(p) / 255.0;
      final pb = img.getBlue(p) / 255.0;

      final cr = img.getRed(pix) / 255.0;
      final cg = img.getGreen(pix) / 255.0;
      final cb = img.getBlue(pix) / 255.0;

      double outR, outG, outB;
      if (job.blend == BlendKind.multiply) {
        final mr = pr * cr, mg = pg * cg, mb = pb * cb;
        outR = mr * ca + pr * (1 - ca);
        outG = mg * ca + pg * (1 - ca);
        outB = mb * ca + pb * (1 - ca);
      } else {
        outR = cr * ca + pr * (1 - ca);
        outG = cg * ca + pg * (1 - ca);
        outB = cb * ca + pb * (1 - ca);
      }

      scaledPhoto.setPixelRgba(
        x,
        y,
        (outR.clamp(0, 1) * 255).toInt(),
        (outG.clamp(0, 1) * 255).toInt(),
        (outB.clamp(0, 1) * 255).toInt(),
        255,
      );
    }
  }

  return Uint8List.fromList(img.encodeJpg(scaledPhoto, quality: 90));
}

/// Isolate üstünden homography warp (UI donmasın)
Future<File> composeCurtainWithHomographyIsolate({
  required File photoFile,
  required String curtainAssetPath,
  required List<Vector2> dstQuadPx,
  required double opacity,
  required BlendKind blend,
  required int maxDim,
  required String outputPath,
}) async {
  final photoBytes = await photoFile.readAsBytes();
  final curtainBytes =
      (await rootBundle.load(curtainAssetPath)).buffer.asUint8List();

  final flat = <double>[
    dstQuadPx[0].x,
    dstQuadPx[0].y,
    dstQuadPx[1].x,
    dstQuadPx[1].y,
    dstQuadPx[2].x,
    dstQuadPx[2].y,
    dstQuadPx[3].x,
    dstQuadPx[3].y,
  ];

  final job = _WarpJob(photoBytes, curtainBytes, flat, opacity, blend, maxDim);
  final res = await compute<_WarpJob, Uint8List>(_warpEntry, job);
  final out = File(outputPath);
  await out.writeAsBytes(res);
  return out;
}
