import 'dart:io';
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' show Vector2;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

import '../ml/seg_model.dart';
import '../ml/depth_model.dart';
import '../ml/preprocess.dart';
import '../ml/classes.dart';
import '../vision/postprocess.dart';
import '../image_composer.dart';
import '../vision/occlusion.dart';

SegDetection? _pickBestWindow(List<SegDetection> dets) {
  if (dets.isEmpty) return null;
  final winId = SegClasses.windowId;
  final wins = dets.where((d) => d.classId == winId).toList();
  if (wins.isNotEmpty) {
    wins.sort((a, b) => b.score.compareTo(a.score));
    return wins.first;
  }
  dets.sort((a, b) => b.score.compareTo(a.score));
  return dets.first; // fallback
}

// removed old local occluder combiner; using vision/occlusion.dart implementation

double _avgLuma(img.Image im) {
  double sum = 0;
  final n = im.width * im.height;
  for (int y = 0; y < im.height; y++) {
    for (int x = 0; x < im.width; x++) {
      final p = im.getPixel(x, y);
      final r = img.getRed(p) / 255.0;
      final g = img.getGreen(p) / 255.0;
      final b = img.getBlue(p) / 255.0;
      sum += (0.299 * r + 0.587 * g + 0.114 * b);
    }
  }
  return (sum / n).clamp(0.0, 1.0);
}

Future<File> autoPlaceCurtain({
  required File photo,
  required String modelAssetPng,
  required SegModel seg,
  required DepthModel depth,
}) async {
  final bytes = await photo.readAsBytes();
  final im = img.decodeImage(bytes)!;
  final W = im.width, H = im.height;

  // Preprocess
  final segIn = await preprocessForSegFromFile(photo); // 512
  final depthIn = await preprocessForDepthFromFile(photo); // 256

  // Infer
  final dets = await seg.infer(
    imageCHW: segIn.chw,
    origW: W,
    origH: H,
    confThresh: 0.30,
    iouThresh: 0.50,
  );
  final win = _pickBestWindow(dets);
  if (win == null) return photo; // fallback

  final quad = estimateQuadFromMaskBinary(win.mask, W, H)
      .pts
      .map((p) => Vector2(p.dx, p.dy))
      .toList();

  final depthMap = await depth.inferFloat(imageCHW: depthIn, outW: W, outH: H);
  // final zWin = medianDepth(depthMap, win.mask, W, H);

  // Occluders (SEG + DEPTH)
  final occMask = combineOccludersFromSegDepth(
    segs: dets,
    depth: depthMap,
    W: W,
    H: H,
    windowMask: win.mask,
    occluderClassIds: SegClasses.occluderIds,
    depthMargin: 0.02,
    dilateRadius: 3,
    blurRadius: 2,
  );

  // Auto tone: luma'ya göre opacity/shadow
  final luma = _avgLuma(im);
  double opacity;
  if (luma < 0.35) {
    opacity = 0.88;
  } else if (luma < 0.65) {
    opacity = 0.90;
  } else {
    opacity = 0.92;
  }

  final tmpWarp =
      '${(await getTemporaryDirectory()).path}/warp_${DateTime.now().millisecondsSinceEpoch}.jpg';
  final warped = await composeCurtainWithHomographyIsolate(
    photoFile: photo,
    curtainAssetPath: modelAssetPng,
    dstQuadPx: quad,
    opacity: opacity,
    blend: BlendKind.multiply,
    maxDim: math.max(W, H),
    outputPath: tmpWarp,
  );

  final tmpOut =
      '${(await getTemporaryDirectory()).path}/final_${DateTime.now().millisecondsSinceEpoch}.jpg';
  final out = await applyForegroundOcclusionWithMask(
    compositedFile: warped,
    originalPhoto: photo,
    fgMask: occMask,
    featherPx: (math.max(W, H) / 400).clamp(1, 6).toInt(),
    outputPath: tmpOut,
  );
  return out;
}
