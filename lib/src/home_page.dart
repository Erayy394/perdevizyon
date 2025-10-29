import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'capture_guidance_page.dart';
import 'model_selection_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final tips = [
      "Pencereyi kadrajın ortasında tutun",
      "Gündüz veya yeterli ışıkta çekin",
      "Yansımaları azaltmak için biraz açı verin",
    ];

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Başlık
              Text(
                "Perdeyi evinde görün",
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                "Mevcut perde modellerini, kendi odanızda nasıl duracağını görerek seçin.",
              ),
              const SizedBox(height: 20),

              // Hero illüstrasyonu (MVP: placeholder)
              Expanded(
                child: Center(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.indigo.withOpacity(.2)),
                    ),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.window_outlined, size: 64),
                        SizedBox(height: 12),
                        Text(
                          "Pencerenizin fotoğrafını çekin veya galeriden seçin.\nBir sonraki adımda yönlendireceğiz.",
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // CTA butonları
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pushNamed(context, '/capture'),
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text("Fotoğraf Çek"),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          final picker = ImagePicker();
                          final x = await picker.pickImage(
                              source: ImageSource.gallery, imageQuality: 95);
                          if (x == null) return;
                          if (context.mounted) {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) =>
                                      ModelSelectionPage(imageFile: x)),
                            );
                          }
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Galeri açılamadı: $e")),
                          );
                        }
                      },
                      icon: const Icon(Icons.photo_outlined),
                      label: const Text("Galeriden Yükle"),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // İpuçları kartı
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.indigo.withOpacity(.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "İpuçları",
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    ...tips.map(
                      (t) => Row(
                        children: [
                          const Icon(Icons.check_circle_outline, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(t)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
