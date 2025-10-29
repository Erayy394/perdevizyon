import 'dart:typed_data';
import 'dart:io';
import 'package:image/image.dart' as img;

/// 0..1 normalize, CHW float32 [1,3,H,W], letterbox ile 512x512
class LetterboxResult {
  final Float32List chw; // [1,3,H,W]
  final int inW, inH; // 512,512
  final double scale;
  final double padX, padY; // input alanındaki padding
  LetterboxResult(
      this.chw, this.inW, this.inH, this.scale, this.padX, this.padY);
}

/// Foto dosyasından seg girdi (512x512 letterbox)
Future<LetterboxResult> preprocessForSegFromFile(File f,
    {int dst = 512}) async {
  final bytes = await f.readAsBytes();
  final im = img.decodeImage(bytes)!;
  final srcW = im.width, srcH = im.height;

  final rW = dst / srcW;
  final rH = dst / srcH;
  final scale = rW < rH ? rW : rH;

  final nw = (srcW * scale).round();
  final nh = (srcH * scale).round();

  // ölçekle
  final resized = img.copyResize(im,
      width: nw, height: nh, interpolation: img.Interpolation.average);

  // letterbox tuval
  final lb = img.Image(dst, dst);
  img.fill(lb, img.getColor(114, 114, 114, 255));
  final padX = ((dst - nw) / 2).round();
  final padY = ((dst - nh) / 2).round();
  img.copyInto(lb, resized, dstX: padX, dstY: padY, blend: false);

  // CHW 0..1
  final chw = Float32List(1 * 3 * dst * dst);
  int idx = 0;
  for (int c = 0; c < 3; c++) {
    for (int y = 0; y < dst; y++) {
      for (int x = 0; x < dst; x++) {
        final p = lb.getPixel(x, y);
        final v = (c == 0
                ? img.getRed(p)
                : c == 1
                    ? img.getGreen(p)
                    : img.getBlue(p)) /
            255.0;
        chw[idx++] = v.toDouble();
      }
    }
  }
  return LetterboxResult(
      chw, dst, dst, scale, padX.toDouble(), padY.toDouble());
}

/// Depth için kare resize (256x256), basit fit
Future<Float32List> preprocessForDepthFromFile(File f, {int size = 256}) async {
  final bytes = await f.readAsBytes();
  final im = img.decodeImage(bytes)!;
  final longSide = im.width > im.height ? im.width : im.height;
  final r = size / longSide;
  final nw = (im.width * r).round();
  final nh = (im.height * r).round();
  final resized = img.copyResize(im,
      width: nw, height: nh, interpolation: img.Interpolation.average);

  // kare tuvale ortala
  final canvas = img.Image(size, size);
  img.fill(canvas, img.getColor(114, 114, 114, 255));
  final offX = ((size - nw) / 2).round();
  final offY = ((size - nh) / 2).round();
  img.copyInto(canvas, resized, dstX: offX, dstY: offY, blend: false);

  // CHW float32 0..1
  final chw = Float32List(1 * 3 * size * size);
  int idx = 0;
  for (int c = 0; c < 3; c++) {
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final p = canvas.getPixel(x, y);
        final v = (c == 0
                ? img.getRed(p)
                : c == 1
                    ? img.getGreen(p)
                    : img.getBlue(p)) /
            255.0;
        chw[idx++] = v.toDouble();
      }
    }
  }
  return chw;
}
