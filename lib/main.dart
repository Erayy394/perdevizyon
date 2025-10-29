import 'package:flutter/material.dart';
import 'src/home_page.dart';
import 'src/capture_guidance_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PerdeApp());
}

class PerdeApp extends StatelessWidget {
  const PerdeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Perdeyi Evinde Gör',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        textTheme: const TextTheme(
          headlineLarge: TextStyle(fontWeight: FontWeight.w700),
          bodyMedium: TextStyle(height: 1.4),
        ),
      ),
      routes: {
        '/': (_) => const HomePage(),
        '/capture': (_) => const CaptureGuidancePage(),
      },
      initialRoute: '/',
    );
  }
}
