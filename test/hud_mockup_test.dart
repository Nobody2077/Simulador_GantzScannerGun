import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hud_scanner/hud/chrome_painter.dart';
import 'package:hud_scanner/hud/hud_layout.dart';
import 'package:hud_scanner/hud/hud_theme.dart';
import 'package:hud_scanner/hud/target_layer.dart';
import 'package:hud_scanner/tracking/body_geometry.dart';
import 'package:hud_scanner/tracking/distance_estimator.dart';

/// Mockups de la composición con varios sujetos: columna de barras a la
/// izquierda y fichas de distancia sin línea guía.
///
/// No es una prueba de regresión, igual que `hud_preview_test.dart`: es la
/// herramienta para decidir densidad y jerarquía sin compilar un APK. Dibuja
/// contra datos sintéticos, sin cámara y sin tracker, que es justamente para lo
/// que `TargetReadout` existe.
///
/// Las imágenes quedan en `build/`. Ojo: el entorno de test dibuja cajas en
/// lugar de glifos, así que el texto se lee como bloques. Sirve para juzgar
/// posición y peso, no tipografía.
void main() {
  const estimator = DistanceEstimator();

  /// Un sujeto sintético derivado de la caja del rostro, con la misma cadena
  /// que usa la app: rostro → encuadre del cuerpo, rostro → distancia.
  TargetReadout subject(
    int id,
    Rect face,
    Size canvas, {
    bool locked = false,
  }) =>
      TargetReadout(
        id: id,
        bodyBox: BodyGeometry.fromFace(face),
        distanceMeters: estimator.estimate(
          faceWidthPx: face.width,
          imageWidthPx: canvas.width,
        ),
        locked: locked,
      );

  Future<void> render(
    WidgetTester tester,
    String name,
    Size canvas,
    List<TargetReadout> subjects,
  ) async {
    final theme = HudTheme.scanner.scaled(hudScale(canvas));
    final layout = HudLayout(canvas, theme);
    final recorder = ui.PictureRecorder();
    final target = Canvas(recorder);

    // Fondo neutro en lugar del feed de cámara.
    target.drawRect(
      Offset.zero & canvas,
      Paint()..color = const Color(0xFF141C20),
    );
    ChromePainter(theme: theme).paint(target, canvas);

    final ordered = orderByProximity(subjects);
    paintRoster(target, layout, theme, ordered);

    // Las fichas no invaden la columna de barras.
    final bounds = Rect.fromLTRB(
      layout.stage.left + rosterWidth(layout, theme) + theme.inset,
      layout.stage.top,
      layout.stage.right,
      layout.stage.bottom,
    );

    // El trabado siempre lleva ficha; el resto de los cupos se reparte por
    // cercanía, que es el mismo orden de la columna.
    final limit = labelledTargetLimit(canvas);
    final lockedCount = ordered.where((r) => r.locked).length;
    final labelledIds = {
      ...ordered.where((r) => r.locked).map((r) => r.id),
      ...ordered
          .where((r) => !r.locked)
          .take(limit - lockedCount)
          .map((r) => r.id),
    };

    // Los ganchos primero, todos, y recortados al área útil.
    final visible = <TargetReadout>[];
    for (final readout in ordered) {
      final box = readout.bodyBox.intersect(layout.stage);
      if (box.isEmpty) continue;

      visible.add(readout.withBodyBox(box));
      paintBrackets(
        target,
        box,
        readout.locked
            ? theme.structure
            : theme.structureDim.withValues(alpha: 0.55),
        readout.locked ? theme.strokeWidth : theme.hairline * 1.5,
      );
    }

    // Las fichas después, la del trabado primero: es la que tiene derecho a su
    // lugar, y las demás se corren para no pisarla.
    final occupied = <Rect>[];
    for (final readout in [
      ...visible.where((r) => r.locked),
      ...visible.where((r) => !r.locked),
    ]) {
      if (!labelledIds.contains(readout.id)) continue;

      occupied.add(paintTargetCard(
        target,
        theme,
        readout,
        bounds: bounds,
        color: readout.locked ? theme.structure : theme.structureDim,
        compact: !readout.locked,
        avoid: occupied,
      ));
    }

    final picture = recorder.endRecording();

    // La rasterización necesita async real: `testWidgets` corre en una zona de
    // async falso donde el Future de toImage nunca se completa.
    await tester.runAsync(() async {
      final image =
          await picture.toImage(canvas.width.round(), canvas.height.round());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();

      Directory('build').createSync(recursive: true);
      File('build/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('mockup tablet: tres sujetos, el trabado no es el más cercano',
      (tester) async {
    const canvas = Size(1280, 720);
    await render(tester, 'mock-tablet-3', canvas, [
      // TGT-08 está más cerca que el trabado: la columna lo pone arriba, pero
      // la barra grande sigue siendo la de TGT-07.
      subject(8, const Rect.fromLTWH(250, 205, 46, 60), canvas),
      subject(7, const Rect.fromLTWH(596, 150, 38, 50), canvas, locked: true),
      subject(9, const Rect.fromLTWH(930, 178, 31, 40), canvas),
    ]);
  });

  testWidgets('mockup tablet: siete sujetos, cinco con ficha', (tester) async {
    const canvas = Size(1280, 720);
    await render(tester, 'mock-tablet-7', canvas, [
      subject(7, const Rect.fromLTWH(560, 168, 40, 52), canvas, locked: true),
      subject(8, const Rect.fromLTWH(268, 210, 46, 60), canvas),
      subject(9, const Rect.fromLTWH(880, 190, 30, 39), canvas),
      subject(10, const Rect.fromLTWH(410, 176, 26, 34), canvas),
      subject(11, const Rect.fromLTWH(724, 164, 23, 30), canvas),
      subject(12, const Rect.fromLTWH(1010, 172, 20, 26), canvas),
      subject(13, const Rect.fromLTWH(150, 182, 18, 23), canvas),
    ]);
  });

  testWidgets('mockup teléfono: cinco sujetos, tres con ficha', (tester) async {
    const canvas = Size(800, 360);
    await render(tester, 'mock-telefono-5', canvas, [
      subject(7, const Rect.fromLTWH(352, 96, 24, 31), canvas, locked: true),
      subject(8, const Rect.fromLTWH(196, 112, 30, 39), canvas),
      subject(9, const Rect.fromLTWH(548, 104, 20, 26), canvas),
      subject(10, const Rect.fromLTWH(650, 100, 17, 22), canvas),
      subject(11, const Rect.fromLTWH(280, 92, 15, 19), canvas),
    ]);
  });
}
