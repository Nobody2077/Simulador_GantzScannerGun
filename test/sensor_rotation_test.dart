import 'dart:ui';

import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:hud_scanner/tracking/coordinate_mapper.dart';
import 'package:hud_scanner/tracking/sensor_rotation.dart';

void main() {
  group('stabilizeLandscape', () {
    test('adopta las lecturas apaisadas', () {
      expect(
        stabilizeLandscape(
            DeviceOrientation.landscapeRight, DeviceOrientation.landscapeLeft),
        DeviceOrientation.landscapeRight,
      );
    });

    test('ignora las lecturas en retrato y conserva la anterior', () {
      // La app está bloqueada en apaisado: aunque el aparato se incline hacia
      // vertical, en pantalla sigue estando la última orientación apaisada.
      for (final portrait in const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]) {
        expect(
          stabilizeLandscape(portrait, DeviceOrientation.landscapeRight),
          DeviceOrientation.landscapeRight,
        );
      }
    });
  });

  group('compensateRotation', () {
    test('cámara trasera con sensor a 90°', () {
      expect(
        compensateRotation(
          sensorOrientation: 90,
          uiOrientation: DeviceOrientation.landscapeLeft,
          frontFacing: false,
        ),
        0,
      );
      expect(
        compensateRotation(
          sensorOrientation: 90,
          uiOrientation: DeviceOrientation.landscapeRight,
          frontFacing: false,
        ),
        180,
      );
    });

    test('la frontal compensa en sentido contrario', () {
      expect(
        compensateRotation(
          sensorOrientation: 270,
          uiOrientation: DeviceOrientation.landscapeLeft,
          frontFacing: true,
        ),
        0,
      );
    });
  });

  group('regresión: el preview no cambia de proporción al rotar', () {
    // Girar el dispositivo con la rotación automática libre ampliaba la imagen
    // como un zoom. La causa: la lectura de orientación pasaba a retrato, la
    // compensación giraba 90°, los ejes de la imagen se intercambiaban y
    // BoxFit.cover ampliaba una imagen vertical para cubrir una pantalla
    // horizontal.
    const rawWidth = 720;
    const rawHeight = 480;

    test('estabilizada en apaisado, los ejes nunca se intercambian', () {
      var ui = DeviceOrientation.landscapeLeft;

      // Una rotación completa, pasando por vertical.
      for (final reported in const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
      ]) {
        ui = stabilizeLandscape(reported, ui);
        final degrees = compensateRotation(
          sensorOrientation: 90,
          uiOrientation: ui,
          frontFacing: false,
        );
        final size = rotatedSize(
          rawWidth,
          rawHeight,
          InputImageRotationValue.fromRawValue(degrees)!,
        );

        expect(size, const Size(720, 480),
            reason: 'con $reported la imagen cambió de proporción');
      }
    });

    test('sin estabilizar, el retrato sí intercambia los ejes', () {
      // Deja constancia de la causa: es lo que hacía el código anterior.
      final degrees = compensateRotation(
        sensorOrientation: 90,
        uiOrientation: DeviceOrientation.portraitUp,
        frontFacing: false,
      );
      final size = rotatedSize(
        rawWidth,
        rawHeight,
        InputImageRotationValue.fromRawValue(degrees)!,
      );

      expect(size, const Size(480, 720));
    });
  });
}
