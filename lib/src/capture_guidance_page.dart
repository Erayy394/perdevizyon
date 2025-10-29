import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'model_selection_page.dart';
import 'guidance/live_guidance.dart';

class CaptureGuidancePage extends StatefulWidget {
  const CaptureGuidancePage({super.key});

  @override
  State<CaptureGuidancePage> createState() => _CaptureGuidancePageState();
}

class _CaptureGuidancePageState extends State<CaptureGuidancePage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initFuture;
  bool _isBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initFuture = _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initFuture = _initCamera(); // ekrana dönünce yeniden başlat
      setState(() {});
    }
  }

  Future<void> _initCamera() async {
    try {
      // 1) Kamera izni
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        throw Exception("Kamera izni verilmedi.");
      }

      // 2) Uygun kamerayı seç
      final cams = await availableCameras();
      final backCam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );

      // 3) Controller başlat
      _controller = CameraController(
        backCam,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();

      // Otomatik odak/pozlama için küçük bir tetik
      if (_controller!.value.isInitialized &&
          _controller!.value.isPreviewPaused) {
        await _controller!.resumePreview();
      }

      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = e.toString());
      rethrow;
    }
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isBusy) return;

    setState(() => _isBusy = true);
    try {
      final file = await _controller!.takePicture();
      if (!mounted) return;
      // Çekilen görseli bir sonraki sayfaya gönder
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ModelSelectionPage(imageFile: file),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fotoğraf çekilemedi: $e")),
      );
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Çekim Rehberi")),
      body: FutureBuilder(
        future: _initFuture,
        builder: (context, snapshot) {
          if (_error != null) {
            return _ErrorView(message: _error!);
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_controller == null || !_controller!.value.isInitialized) {
            return const _ErrorView(message: "Kamera başlatılamadı.");
          }

          return Stack(
            children: [
              // Canlı kamera önizlemesi
              Positioned.fill(
                child: CameraPreview(_controller!),
              ),
              // Canlı rehber overlay (stub/mimari)
              const LiveGuidanceOverlay(enabled: true),
              // Kılavuz overlay (grid + pencere rehberi)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _GuidanceOverlayPainter(),
                  ),
                ),
              ),
              // Alt panel: ipuçları + çekim butonu
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.0),
                        Colors.black.withOpacity(0.5)
                      ],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.9),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: const [
                              Icon(Icons.light_mode, size: 18),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "Pencereyi ortalayın ve çerçevenin dört köşesini görünür yapın.",
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            FloatingActionButton.large(
                              heroTag: 'shutter',
                              onPressed: _isBusy ? null : _takePicture,
                              child: _isBusy
                                  ? const Padding(
                                      padding: EdgeInsets.all(8.0),
                                      child: CircularProgressIndicator(
                                          strokeWidth: 3),
                                    )
                                  : const Icon(Icons.camera_alt),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Sol üstte hafif açıklama kartı
              Positioned(
                left: 12,
                right: 12,
                top: 12,
                child: SafeArea(
                  bottom: false,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: const [
                        Icon(Icons.info_outline, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                "Hizalama için ızgara ve dikdörtgen kılavuzu takip edin.",
                                style: TextStyle(fontSize: 13))),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Geri dön"),
            )
          ],
        ),
      ),
    );
  }
}

/// Basit bir kılavuz painter:
/// - 3x3 ızgara (rule of thirds)
/// - Ortada pencere için dikdörtgen rehber (yuvarlatılmış kenarlı)
class _GuidanceOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.4)
      ..strokeWidth = 1;

    final boldPaint = Paint()
      ..color = Colors.white.withOpacity(0.9)
      ..strokeWidth = 2;

    // 3x3 grid
    final thirdW = size.width / 3;
    final thirdH = size.height / 3;
    for (int i = 1; i <= 2; i++) {
      // dikey
      canvas.drawLine(
          Offset(thirdW * i, 0), Offset(thirdW * i, size.height), gridPaint);
      // yatay
      canvas.drawLine(
          Offset(0, thirdH * i), Offset(size.width, thirdH * i), gridPaint);
    }

    // Ortada pencere kılavuzu: ekranın %70 genişlik, %45 yükseklik
    final guideW = size.width * 0.7;
    final guideH = size.height * 0.45;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: guideW,
      height: guideH,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
    // kenarlık
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawRRect(rrect, border);

    // Köşe işaretleri
    const corner = 22.0;
    // sol-üst
    canvas.drawLine(
        rect.topLeft, rect.topLeft + const Offset(corner, 0), boldPaint);
    canvas.drawLine(
        rect.topLeft, rect.topLeft + const Offset(0, corner), boldPaint);
    // sağ-üst
    canvas.drawLine(
        rect.topRight, rect.topRight + const Offset(-corner, 0), boldPaint);
    canvas.drawLine(
        rect.topRight, rect.topRight + const Offset(0, corner), boldPaint);
    // sol-alt
    canvas.drawLine(
        rect.bottomLeft, rect.bottomLeft + const Offset(corner, 0), boldPaint);
    canvas.drawLine(
        rect.bottomLeft, rect.bottomLeft + const Offset(0, -corner), boldPaint);
    // sağ-alt
    canvas.drawLine(rect.bottomRight,
        rect.bottomRight + const Offset(-corner, 0), boldPaint);
    canvas.drawLine(rect.bottomRight,
        rect.bottomRight + const Offset(0, -corner), boldPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
