import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart' show Vector2;

/// Downscale (performans): en uzun kenarı maxDim'e indir
img.Image _downscale(img.Image im, {int maxDim = 1024}) {
  final w = im.width, h = im.height;
  final longSide = w > h ? w : h;
  if (longSide <= maxDim) return im;
  final scale = maxDim / longSide;
  return img.copyResize(im,
      width: (w * scale).round(),
      height: (h * scale).round(),
      interpolation: img.Interpolation.average);
}

/// Basit Sobel gradyan büyüklüğü (0..255)
img.Image _sobelMag(img.Image gray) {
  final w = gray.width, h = gray.height;
  final out = img.Image(w, h);
  // Sobel çekirdekleri
  const gx = [
    [-1, 0, 1],
    [-2, 0, 2],
    [-1, 0, 1],
  ];
  const gy = [
    [-1, -2, -1],
    [0, 0, 0],
    [1, 2, 1],
  ];
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      double sx = 0, sy = 0;
      for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
          final p = gray.getPixel(x + i, y + j);
          final v = img.getRed(p); // gray
          sx += gx[j + 1][i + 1] * v;
          sy += gy[j + 1][i + 1] * v;
        }
      }
      final mag = math.min(255, (math.sqrt(sx * sx + sy * sy)).round());
      out.setPixelRgba(x, y, mag, mag, mag, 255);
    }
  }
  return out;
}

/// 1D sinyal üzerinde basit tepe (peak) bulucu.
/// minDist: iki tepe arasında minimum uzaklık (ör: 20 piksel)
List<int> _findTopPeaks(List<double> a, {int count = 2, int minDist = 20}) {
  final idx = List<int>.generate(a.length, (i) => i);
  idx.sort((i, j) => a[j].compareTo(a[i]));
  final picks = <int>[];
  for (final i in idx) {
    if (picks.length >= count) break;
    final ok = picks.every((p) => (p - i).abs() >= minDist);
    if (ok) picks.add(i);
  }
  picks.sort();
  return picks;
}

/// Basit yumuşatma (box blur 1D)
List<double> _smooth1D(List<double> x, int radius) {
  if (radius <= 0) return x;
  final n = x.length;
  final y = List<double>.filled(n, 0);
  double sum = 0;
  int win = 0;
  int left = 0;
  for (int i = 0; i < n; i++) {
    sum += x[i];
    win++;
    if (i - left > radius * 2) {
      sum -= x[left++];
      win--;
    }
    y[i] = sum / win;
  }
  return y;
}

/// Otomatik pencere dörtgeni (quad) önerisi.
/// Dönüş: Fotoğraf piksel koordinatlarında 4 köşe (saat yönüyle: sol-üst, sağ-üst, sağ-alt, sol-alt).
Future<List<Vector2>> autoDetectWindowQuad(File photoFile,
    {int maxDim = 1024}) async {
  final bytes = await photoFile.readAsBytes();
  final src = img.decodeImage(bytes)!;

  // Downscale + grayscale + blur + sobel
  final scaled = _downscale(src, maxDim: maxDim);
  final gray = img.grayscale(scaled);
  final blur = img.gaussianBlur(gray, 1); // hafif
  final mag = _sobelMag(blur);

  final w = mag.width, h = mag.height;

  // Dikey kenarlar için sütun toplamı, yatay kenarlar için satır toplamı
  final col = List<double>.filled(w, 0);
  final row = List<double>.filled(h, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final v = img.getRed(mag.getPixel(x, y)).toDouble();
      col[x] += v;
      row[y] += v;
    }
  }

  // Kenar penceresi: aşırı dış çerçeveyi atmak için %5 margin
  int marginX = (w * 0.05).round();
  int marginY = (h * 0.05).round();
  for (int i = 0; i < marginX; i++) {
    col[i] = 0;
    col[w - 1 - i] = 0;
  }
  for (int i = 0; i < marginY; i++) {
    row[i] = 0;
    row[h - 1 - i] = 0;
  }

  // Yumuşatma
  final colS = _smooth1D(col, (w * 0.02).round());
  final rowS = _smooth1D(row, (h * 0.02).round());

  // En güçlü 2 tepe (sol/sağ) ve (üst/alt)
  final xs = _findTopPeaks(colS, count: 2, minDist: (w * 0.25).round());
  final ys = _findTopPeaks(rowS, count: 2, minDist: (h * 0.25).round());
  if (xs.length < 2 || ys.length < 2) {
    // başarısızsa tüm görüntüye yakın bir dikdörtgen öner
    final def = [
      Vector2(0.15 * src.width, 0.2 * src.height),
      Vector2(0.85 * src.width, 0.2 * src.height),
      Vector2(0.85 * src.width, 0.8 * src.height),
      Vector2(0.15 * src.width, 0.8 * src.height),
    ];
    return def;
  }

  xs.sort();
  ys.sort();

  // Scaled -> orijinale scale geri dönüş
  final sx = src.width / w;
  final sy = src.height / h;

  final left = xs.first * sx;
  final right = xs.last * sx;
  final top = ys.first * sy;
  final bottom = ys.last * sy;

  return [
    Vector2(left, top),
    Vector2(right, top),
    Vector2(right, bottom),
    Vector2(left, bottom),
  ];
}
