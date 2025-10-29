import 'dart:async';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Vector2;
import 'dart:io';
import '../ml/seg_model.dart';
import '../ml/depth_model.dart';
import '../ml/preprocess.dart';
import '../vision/postprocess.dart';

class LiveGuidanceOverlay extends StatefulWidget {
  final bool enabled;
  final Future<File?> Function()? frameProvider;
  const LiveGuidanceOverlay(
      {super.key, required this.enabled, this.frameProvider});

  @override
  State<LiveGuidanceOverlay> createState() => _LiveGuidanceOverlayState();
}

class _LiveGuidanceOverlayState extends State<LiveGuidanceOverlay> {
  late Timer _timer;
  List<Vector2> _quad = [
    Vector2(0, 0),
    Vector2(0, 0),
    Vector2(0, 0),
    Vector2(0, 0)
  ];
  SegModel? _seg;
  DepthModel? _depth;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (!widget.enabled) return;
      if (widget.frameProvider == null) return;
      try {
        _seg ??= await SegModel.load();
      } catch (_) {}
      try {
        _depth ??= await DepthModel.load();
      } catch (_) {}
      final file = await widget.frameProvider!.call();
      if (file == null || _seg == null) return;
      try {
        final segIn = await preprocessForSegFromFile(file);
        final dets = await _seg!.infer(
            imageCHW: segIn.chw,
            origW: segIn.inW,
            origH: segIn.inH,
            confThresh: 0.3,
            iouThresh: 0.5);
        if (dets.isEmpty) return;
        final win = dets.first;
        final quad = estimateQuadFromMaskBinary(win.mask, win.maskW, win.maskH)
            .pts
            .map((p) => Vector2(p.dx, p.dy))
            .toList();
        setState(() {
          _quad = quad;
        });
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        painter: _QuadPainterOverlay(_quad),
        size: Size.infinite,
      ),
    );
  }
}

class _QuadPainterOverlay extends CustomPainter {
  final List<Vector2> quad;
  _QuadPainterOverlay(this.quad);
  @override
  void paint(Canvas canvas, Size size) {
    final lp = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    for (int i = 0; i < 4; i++) {
      final a = Offset(quad[i].x, quad[i].y);
      final b = Offset(quad[(i + 1) % 4].x, quad[(i + 1) % 4].y);
      canvas.drawLine(a, b, lp);
    }
  }

  @override
  bool shouldRepaint(covariant _QuadPainterOverlay oldDelegate) =>
      oldDelegate.quad != quad;
}
