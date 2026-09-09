import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'scanner_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // AC-1.5: orientación bloqueada en apaisado, admitiendo los dos sentidos.
  // Es lo que mantiene el mapeo de coordenadas en un único caso en vez de cuatro.
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(const HudScannerApp());
}

class HudScannerApp extends StatelessWidget {
  const HudScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HUD Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      home: const ScannerPage(),
    );
  }
}
