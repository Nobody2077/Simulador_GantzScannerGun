import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hud_scanner/hud/chrome_painter.dart';
import 'package:hud_scanner/hud/hud_painter.dart';
import 'package:hud_scanner/hud/hud_theme.dart';
import 'package:hud_scanner/tracking/target_tracker.dart';

/// Genera vistas previas del HUD a PNG, sin dispositivo.
///
/// No es una prueba de regresión: es una herramienta de diseño. Permite iterar
/// sobre la composición —posiciones, jerarquía, densidad— sin tener que
/// compilar un APK y sostener la tablet frente a una cara para cada ajuste.
///
/// Las imágenes quedan en `build/`.
void main() {
  const canvas = Size(1280, 720);
  // Un objetivo a media distancia, dentro de rango.
  const face = Rect.fromLTWH(600, 150, 38, 50);
  // Uno diminuto: dispara el aviso de fuera de rango (AC-4.6).
  const distantFace = Rect.fromLTWH(640, 300, 14, 18);

  Future<void> render(
    WidgetTester tester,
    String name, {
    required void Function(TargetTracker tracker) drive,
  }) async {
    final tracker = TargetTracker(vsync: const TestVSync());
    try {
      drive(tracker);
      // Los ticks son los que mueven el suavizado a su posición final.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final theme = HudTheme.scanner.scaled(hudScale(canvas));
      final recorder = ui.PictureRecorder();
      final target = Canvas(recorder);

      // Fondo neutro en lugar del feed de cámara.
      target.drawRect(
        Offset.zero & canvas,
        Paint()..color = const Color(0xFF141C20),
      );

      ChromePainter(theme: theme).paint(target, canvas);
      HudPainter(
        tracker: tracker,
        readouts: ValueNotifier(
          const HudReadouts(
            camera: 'trasera',
            detecting: true,
            resolution: '720×480',
            inferenceFps: 26.7,
            latencyMs: 4,
          ),
        ),
        theme: theme,
        mirror: false,
      ).paint(target, canvas);

      final picture = recorder.endRecording();

      // La rasterización necesita async real: `testWidgets` corre en una zona
      // de async falso donde el Future de toImage nunca se completa.
      await tester.runAsync(() async {
        final image =
            await picture.toImage(canvas.width.round(), canvas.height.round());
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();

        Directory('build').createSync(recursive: true);
        File('build/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    } finally {
      tracker.dispose();
    }
  }

  testWidgets('vista previa: objetivo trabado', (tester) async {
    await render(tester, 'hud-trabado', drive: (tracker) {
      for (var i = 0; i < 3; i++) {
        tracker.onInference(
          const [RawTarget(id: 7, faceBox: face)],
          canvas,
        );
      }
    });
  });

  testWidgets('vista previa: sin objetivo', (tester) async {
    await render(tester, 'hud-busqueda', drive: (_) {});
  });

  testWidgets('vista previa: varios objetivos', (tester) async {
    await render(tester, 'hud-multiple', drive: (tracker) {
      for (var i = 0; i < 3; i++) {
        tracker.onInference(
          const [
            RawTarget(id: 7, faceBox: face),
            RawTarget(id: 8, faceBox: Rect.fromLTWH(300, 200, 30, 39)),
            RawTarget(id: 9, faceBox: Rect.fromLTWH(940, 175, 34, 44)),
          ],
          canvas,
        );
      }
    });
  });

  testWidgets('vista previa: fuera de rango', (tester) async {
    await render(tester, 'hud-fuera-de-rango', drive: (tracker) {
      for (var i = 0; i < 3; i++) {
        tracker.onInference(
          const [RawTarget(id: 12, faceBox: distantFace)],
          canvas,
        );
      }
    });
  });
}
