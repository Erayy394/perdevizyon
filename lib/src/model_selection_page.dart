import 'dart:io';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Vector2;
import 'image_composer.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'image_autodetect.dart';

/// Basit model nesnesi
class CurtainModel {
  final String name;
  final String assetPath; // assets/models/... (PNG, şeffaf arka plan önerilir)
  const CurtainModel({required this.name, required this.assetPath});
}

class ModelSelectionPage extends StatefulWidget {
  final XFile imageFile;
  const ModelSelectionPage({super.key, required this.imageFile});

  @override
  State<ModelSelectionPage> createState() => _ModelSelectionPageState();
}

class _ModelSelectionPageState extends State<ModelSelectionPage> {
  /// Örnek model listesi — asset yoksa placeholder göstereceğiz.
  final models = const <CurtainModel>[
    CurtainModel(name: "Klasik Beyaz", assetPath: "assets/models/model1.png"),
    CurtainModel(name: "Zebra Gri", assetPath: "assets/models/model2.png"),
    CurtainModel(name: "Stor Krem", assetPath: "assets/models/model3.png"),
    CurtainModel(name: "Sade Siyah", assetPath: "assets/models/model4.png"),
  ];

  int selected = 0;

  // Overlay transform durumları
  Offset _offset = Offset.zero; // sürükleme
  double _scale = 1.0; // yakınlaştırma
  double _rotation = 0.0; // radyan
  double _baseScale = 1.0;
  double _baseRotation = 0.0;
  Offset _baseOffset = Offset.zero;

  // Görsel ayarları
  double _opacity = 0.9;
  bool _flipX = false;
  BlendMode _blend = BlendMode.srcOver;

  // Görsel alanı ilk yerleştirme için
  final _imageKey = GlobalKey();
  Size? _imagePaintSize;

  // Köşe seçimi ve maskeleme
  bool _quadMode = false;
  final List<Offset> _quadPoints = [];
  bool _isCompositing = false;
  File? _composited;
  final List<File> _history = [];
  int _maxHistory = 5;
  int _maxWarpDim = 1920;

  // Gerçek görüntü bilgisi ve paint rect
  ui.Image? _uiImage;
  Size? _imagePixelSize;
  Rect? _paintRectInWidget;
  bool _dragMode = false; // köşe sürükleme modu
  int? _dragIndex; // sürüklenen köşe (0..3)

  @override
  void initState() {
    super.initState();
    // Başlangıçta overlay'i merkeze al
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerOverlay());
    _loadImageInfo();
  }

  Future<void> _loadImageInfo() async {
    final bytes = await File(widget.imageFile.path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final fi = await codec.getNextFrame();
    setState(() {
      _uiImage = fi.image;
      _imagePixelSize =
          Size(fi.image.width.toDouble(), fi.image.height.toDouble());
    });
  }

  Rect _computePaintRect(Size widgetSize, Size imageSize) {
    final srcAR = imageSize.width / imageSize.height;
    final dstAR = widgetSize.width / widgetSize.height;

    double w, h;
    if (srcAR > dstAR) {
      w = widgetSize.width;
      h = w / srcAR;
    } else {
      h = widgetSize.height;
      w = h * srcAR;
    }
    final dx = (widgetSize.width - w) / 2;
    final dy = (widgetSize.height - h) / 2;
    return Rect.fromLTWH(dx, dy, w, h);
  }

  Vector2? _mapTapToImagePixel(Offset localTap) {
    if (_imagePixelSize == null || _paintRectInWidget == null) return null;
    final r = _paintRectInWidget!;
    if (!r.contains(localTap)) return null;
    final nx = (localTap.dx - r.left) / r.width;
    final ny = (localTap.dy - r.top) / r.height;
    final px = nx * _imagePixelSize!.width;
    final py = ny * _imagePixelSize!.height;
    return Vector2(px, py);
  }

  Offset _imagePixelToLocal(Vector2 px) {
    final r = _paintRectInWidget!;
    final nx = px.x / _imagePixelSize!.width;
    final ny = px.y / _imagePixelSize!.height;
    return Offset(r.left + nx * r.width, r.top + ny * r.height);
  }

  void _centerOverlay() {
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null) {
      setState(() {
        _imagePaintSize = box.size;
        _offset = Offset.zero;
        _scale = 0.8; // başlangıç boyutu
        _rotation = 0.0;
        _flipX = false;
        _blend = BlendMode.srcOver;
        _opacity = 0.9;
      });
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _baseOffset = _offset - d.focalPoint;
    _baseScale = _scale;
    _baseRotation = _rotation;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      _offset = _baseOffset + d.focalPoint;
      _scale = (_baseScale * d.scale).clamp(0.2, 6.0);
      _rotation = _baseRotation + d.rotation;
    });
  }

  void _resetTransform() => setState(() {
        _centerOverlay();
      });

  void _selectModel(int idx) => setState(() {
        selected = idx;
        _centerOverlay();
      });

  Future<T?> _withProgress<T>(Future<T> Function() task) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      return await task();
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageFile = File(widget.imageFile.path);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Model Seçimi"),
        actions: [
          IconButton(
            tooltip: "Geri al",
            onPressed: _history.isNotEmpty
                ? () {
                    setState(() {
                      _composited = _history.removeLast();
                    });
                  }
                : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: "Kaydet",
            onPressed: () async {
              try {
                final pic = _composited ?? File(widget.imageFile.path);
                final dir = await getApplicationDocumentsDirectory();
                final savePath =
                    '${dir.path}/perde_${DateTime.now().millisecondsSinceEpoch}.jpg';
                await pic.copy(savePath);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text("Kaydedildi: ${savePath.split('/').last}")),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Kaydedilemedi: $e")),
                );
              }
            },
            icon: const Icon(Icons.save_alt),
          ),
          IconButton(
            tooltip: "Paylaş",
            onPressed: () async {
              final pic = _composited ?? File(widget.imageFile.path);
              await Share.shareXFiles([XFile(pic.path)],
                  text: "Perde önizlemem");
            },
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            tooltip: _quadMode ? "Köşe modunu kapat" : "Köşeleri işaretle",
            onPressed: () {
              setState(() {
                _quadMode = !_quadMode;
                _quadPoints.clear();
                _dragMode = false;
                _composited = null;
              });
            },
            icon: Icon(_quadMode ? Icons.crop_free : Icons.crop_square),
          ),
          IconButton(
            tooltip: "Auto Detect (Beta)",
            onPressed: () async {
              setState(() {
                _quadMode = true;
                _dragMode = true;
                _quadPoints.clear();
              });
              try {
                final photo = _composited ?? File(widget.imageFile.path);
                final quad = await autoDetectWindowQuad(photo, maxDim: 1024);
                setState(() {
                  _quadPoints.addAll(quad.map((v) => Offset(v.x, v.y)));
                });
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text(
                            "Öneri hazır: gerekirse köşeleri sürükleyip düzeltin.")),
                  );
                }
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Auto Detect başarısız: $e")),
                );
              }
            },
            icon: const Icon(Icons.auto_fix_high),
          ),
          IconButton(
            tooltip: "Sıfırla",
            onPressed: _resetTransform,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          // Üst kısım: fotoğraf + overlay
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (_imagePixelSize != null) {
                  _paintRectInWidget = _computePaintRect(
                    Size(constraints.maxWidth, constraints.maxHeight),
                    _imagePixelSize!,
                  );
                }
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    // Fotoğraf
                    Center(
                      child: Container(
                        key: _imageKey,
                        constraints: const BoxConstraints.expand(),
                        child: _composited == null
                            ? Image.file(imageFile, fit: BoxFit.contain)
                            : Image.file(_composited!, fit: BoxFit.contain),
                      ),
                    ),

                    // Overlay: seçili model
                    if (models.isNotEmpty)
                      _CurtainOverlay(
                        assetPath: models[selected].assetPath,
                        opacity: _opacity,
                        flipX: _flipX,
                        blend: _blend,
                        offset: _offset,
                        scale: _scale,
                        rotation: _rotation,
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                      ),

                    // Üstte küçük bilgi etiketi
                    Positioned(
                      top: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(.9),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _quadMode
                              ? "Ekranda 4 köşeyi sırayla işaretleyin"
                              : "Sürükle: taşı  •  İki parmak: yakınlaştır/döndür",
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),

                    if (_quadMode &&
                        _imagePixelSize != null &&
                        _paintRectInWidget != null)
                      Positioned.fill(
                        child: _dragMode
                            ? Listener(
                                onPointerDown: (e) {
                                  final ptsLocal = _quadPoints
                                      .map((p) => _imagePixelToLocal(
                                          Vector2(p.dx, p.dy)))
                                      .toList();
                                  const grabR = 24.0;
                                  for (int i = 0; i < ptsLocal.length; i++) {
                                    if ((ptsLocal[i] - e.localPosition)
                                            .distance <=
                                        grabR) {
                                      setState(() => _dragIndex = i);
                                      break;
                                    }
                                  }
                                },
                                onPointerMove: (e) {
                                  if (_dragIndex != null) {
                                    final px =
                                        _mapTapToImagePixel(e.localPosition);
                                    if (px != null) {
                                      setState(() {
                                        _quadPoints[_dragIndex!] =
                                            Offset(px.x, px.y);
                                      });
                                    }
                                  }
                                },
                                onPointerUp: (_) =>
                                    setState(() => _dragIndex = null),
                                child: CustomPaint(
                                  painter: _QuadHandlesPainter(
                                    pointsLocal: _quadPoints
                                        .map((o) => _imagePixelToLocal(
                                            Vector2(o.dx, o.dy)))
                                        .toList(),
                                  ),
                                ),
                              )
                            : GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (d) {
                                  if (_quadPoints.length < 4) {
                                    final p =
                                        _mapTapToImagePixel(d.localPosition);
                                    if (p != null) {
                                      setState(() =>
                                          _quadPoints.add(Offset(p.x, p.y)));
                                    }
                                  }
                                },
                                child: CustomPaint(
                                  painter: _QuadPainter(
                                    pointsLocal: _quadPoints
                                        .map((o) => _imagePixelToLocal(
                                            Vector2(o.dx, o.dy)))
                                        .toList(),
                                  ),
                                ),
                              ),
                      ),
                  ],
                );
              },
            ),
          ),

          // Uygula (Warp) butonu: sadece köşe modu ve 4 nokta seçildiyse
          if (_quadMode)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: (_quadPoints.length == 4 &&
                              !_isCompositing &&
                              _imagePixelSize != null)
                          ? () async {
                              await _withProgress(() async {
                                setState(() => _isCompositing = true);
                                try {
                                  final tmpDir = await getTemporaryDirectory();
                                  final tmpPath =
                                      '${tmpDir.path}/perde_warp_${DateTime.now().millisecondsSinceEpoch}.jpg';
                                  final dst = _quadPoints
                                      .map((o) => Vector2(o.dx, o.dy))
                                      .toList();
                                  final prev = _composited ??
                                      File(widget.imageFile.path);
                                  if (_history.length >= _maxHistory)
                                    _history.removeAt(0);
                                  _history.add(prev);
                                  final out =
                                      await composeCurtainWithHomographyIsolate(
                                    photoFile: prev,
                                    curtainAssetPath:
                                        models[selected].assetPath,
                                    dstQuadPx: dst,
                                    opacity: _opacity,
                                    blend: _blend == BlendMode.multiply
                                        ? BlendKind.multiply
                                        : BlendKind.normal,
                                    maxDim: _maxWarpDim,
                                    outputPath: tmpPath,
                                  );
                                  setState(() {
                                    _composited = out;
                                    _quadMode = false;
                                    _quadPoints.clear();
                                  });
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text("Warp başarısız: $e")),
                                    );
                                  }
                                } finally {
                                  if (context.mounted)
                                    setState(() => _isCompositing = false);
                                }
                              });
                            }
                          : null,
                      icon: _isCompositing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.texture),
                      label: const Text("Uygula (Warp)"),
                    ),
                  ),
                ],
              ),
            ),

          // Alt panel: karusel + ayarlar
          _BottomPanel(
            theme: theme,
            models: models,
            selected: selected,
            onSelect: _selectModel,
            opacity: _opacity,
            onOpacityChanged: (v) => setState(() => _opacity = v),
            flipX: _flipX,
            onFlipX: () => setState(() => _flipX = !_flipX),
            blend: _blend,
            onBlendChanged: (bm) => setState(() => _blend = bm),
          ),
        ],
      ),
    );
  }
}

class _QuadPainter extends CustomPainter {
  final List<Offset> pointsLocal;
  _QuadPainter({required this.pointsLocal});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFFFFFFFF).withOpacity(0.85)
      ..strokeWidth = 2;

    for (final pt in pointsLocal) {
      canvas.drawCircle(pt, 6, p);
    }

    if (pointsLocal.length >= 2) {
      final lp = Paint()
        ..color = const Color(0xFFFFFFFF)
        ..strokeWidth = 2;
      for (int i = 0; i < pointsLocal.length - 1; i++) {
        canvas.drawLine(pointsLocal[i], pointsLocal[i + 1], lp);
      }
      if (pointsLocal.length == 4) {
        canvas.drawLine(pointsLocal[3], pointsLocal[0], lp);
      }
    }

    final tp = TextPainter(
      text: TextSpan(
        text: pointsLocal.length < 4
            ? "Nokta ${pointsLocal.length + 1}/4: Köşeye dokunun"
            : "Hazır: Uygula (Maskele) düğmesine basın",
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    tp.paint(canvas, const Offset(12, 12));
  }

  @override
  bool shouldRepaint(covariant _QuadPainter oldDelegate) =>
      oldDelegate.pointsLocal != pointsLocal;
}

class _QuadHandlesPainter extends CustomPainter {
  final List<Offset> pointsLocal;
  _QuadHandlesPainter({required this.pointsLocal});

  @override
  void paint(Canvas canvas, Size size) {
    final lp = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 2;
    final hp = Paint()
      ..color = const Color(0xFF4F46E5)
      ..style = PaintingStyle.fill;

    if (pointsLocal.length == 4) {
      for (int i = 0; i < 4; i++) {
        final a = pointsLocal[i];
        final b = pointsLocal[(i + 1) % 4];
        canvas.drawLine(a, b, lp);
      }
    }

    for (final pt in pointsLocal) {
      canvas.drawCircle(pt, 8, hp);
      canvas.drawCircle(pt, 10, lp);
    }

    final tp = TextPainter(
      text: const TextSpan(
        text: "Köşeleri sürükleyerek düzeltin • Ardından Uygula (Warp)",
        style: TextStyle(color: Colors.white, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    tp.paint(canvas, const Offset(12, 12));
  }

  @override
  bool shouldRepaint(covariant _QuadHandlesPainter oldDelegate) =>
      oldDelegate.pointsLocal != pointsLocal;
}

/// Overlay bileşeni: gesture + blend + flip
class _CurtainOverlay extends StatelessWidget {
  final String assetPath;
  final double opacity;
  final bool flipX;
  final BlendMode blend;
  final Offset offset;
  final double scale;
  final double rotation;
  final GestureScaleStartCallback onScaleStart;
  final GestureScaleUpdateCallback onScaleUpdate;

  const _CurtainOverlay({
    required this.assetPath,
    required this.opacity,
    required this.flipX,
    required this.blend,
    required this.offset,
    required this.scale,
    required this.rotation,
    required this.onScaleStart,
    required this.onScaleUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      assetPath,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) {
        // Asset bulunamazsa: placeholder
        return Container(
          width: 220,
          height: 160,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.indigo.withOpacity(.35),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            "Model PNG bulunamadı\n(assets/models/...)",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white),
          ),
        );
      },
    );

    // Transform zinciri: translate -> rotate -> scale -> flip(optional)
    final Matrix4 m = Matrix4.identity()
      ..translate(offset.dx, offset.dy)
      ..rotateZ(rotation)
      ..scale(scale, scale)
      ..scale(flipX ? -1.0 : 1.0, 1.0);

    final child = Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(Colors.transparent, blend),
        child: image,
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onScaleStart: onScaleStart,
      onScaleUpdate: onScaleUpdate,
      child: Transform(
        transform: m,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

/// Alt panel: yatay karusel + ayarlar
class _BottomPanel extends StatelessWidget {
  final ThemeData theme;
  final List<CurtainModel> models;
  final int selected;
  final ValueChanged<int> onSelect;

  final double opacity;
  final ValueChanged<double> onOpacityChanged;

  final bool flipX;
  final VoidCallback onFlipX;

  final BlendMode blend;
  final ValueChanged<BlendMode> onBlendChanged;

  const _BottomPanel({
    required this.theme,
    required this.models,
    required this.selected,
    required this.onSelect,
    required this.opacity,
    required this.onOpacityChanged,
    required this.flipX,
    required this.onFlipX,
    required this.blend,
    required this.onBlendChanged,
  });

  @override
  Widget build(BuildContext context) {
    final blends = <(String, BlendMode)>[
      ("Normal", BlendMode.srcOver),
      ("Multiply", BlendMode.multiply),
      ("Screen", BlendMode.screen),
      ("Overlay", BlendMode.overlay),
      ("SoftLight", BlendMode.softLight),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border:
            Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Karusel
            SizedBox(
              height: 100,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: models.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final isSel = i == selected;
                  return GestureDetector(
                    onTap: () => onSelect(i),
                    child: Container(
                      width: 120,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSel
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          width: isSel ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Image.asset(
                              models[i].assetPath,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.blur_on, size: 32),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            models[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  isSel ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 8),

            // Ayarlar: Opacity + Flip + Blend
            Row(
              children: [
                const Text("Opaklık"),
                Expanded(
                  child: Slider(
                    value: opacity,
                    onChanged: onOpacityChanged,
                    min: 0.2,
                    max: 1.0,
                  ),
                ),
                IconButton(
                  tooltip: flipX ? "Yansımayı kapat" : "Yatay çevir (ayna)",
                  onPressed: onFlipX,
                  icon: const Icon(Icons.flip),
                ),
                const SizedBox(width: 4),
                DropdownButton<BlendMode>(
                  value: blend,
                  onChanged: (v) => v != null ? onBlendChanged(v) : null,
                  items: blends
                      .map((e) => DropdownMenuItem(
                            value: e.$2,
                            child: Text(e.$1),
                          ))
                      .toList(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
