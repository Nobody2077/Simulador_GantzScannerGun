import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:hud_scanner/tracking/coordinate_mapper.dart';

/// El mapeo de coordenadas es pura aritmética, así que se puede verificar sin
/// dispositivo. Lo que el Spike 0 comprueba en la tablet es que las *entradas*
/// (rotación, tamaño, espejado) sean las correctas; que la cuenta esté bien se
/// comprueba acá.
void main() {
  group('CoordinateMapper', () {
    test('escala uniforme cuando imagen y lienzo comparten aspect ratio', () {
      final mapper = CoordinateMapper(
        imageSize: const Size(640, 480),
        canvasSize: const Size(1280, 960),
        mirror: false,
      );

      expect(
        mapper.mapRect(const Rect.fromLTRB(100, 100, 200, 200)),
        const Rect.fromLTRB(200, 200, 400, 400),
      );
    });

    test('BoxFit.cover recorta el sobrante y mantiene el centro centrado', () {
      // Imagen 4:3 dentro de un lienzo cuadrado: sobra ancho, se recorta.
      final mapper = CoordinateMapper(
        imageSize: const Size(640, 480),
        canvasSize: const Size(640, 640),
        mirror: false,
      );

      final center = mapper.mapRect(const Rect.fromLTRB(320, 240, 320, 240));
      expect(center.left, closeTo(320, 0.001));
      expect(center.top, closeTo(320, 0.001));

      // El borde izquierdo de la imagen queda fuera del lienzo: eso es el recorte.
      final full = mapper.mapRect(const Rect.fromLTRB(0, 0, 640, 480));
      expect(full.left, lessThan(0));
      expect(full.right, greaterThan(640));
      expect(full.top, closeTo(0, 0.001));
      expect(full.bottom, closeTo(640, 0.001));
    });

    test('el espejado invierte el eje X sin deformar la caja', () {
      final mapper = CoordinateMapper(
        imageSize: const Size(640, 480),
        canvasSize: const Size(640, 480),
        mirror: true,
      );

      final mapped = mapper.mapRect(const Rect.fromLTRB(100, 100, 200, 200));

      expect(mapped, const Rect.fromLTRB(440, 100, 540, 200));
      // Un espejado que ensancha o angosta la caja es un bug clásico.
      expect(mapped.width, closeTo(100, 0.001));
      expect(mapped.height, closeTo(100, 0.001));
    });

    test('espejar dos veces devuelve la posición original', () {
      const box = Rect.fromLTRB(120, 60, 260, 300);
      const image = Size(640, 480);

      final once = CoordinateMapper(
        imageSize: image,
        canvasSize: image,
        mirror: true,
      ).mapRect(box);

      final twice = CoordinateMapper(
        imageSize: image,
        canvasSize: image,
        mirror: true,
      ).mapRect(once);

      expect(twice.left, closeTo(box.left, 0.001));
      expect(twice.right, closeTo(box.right, 0.001));
    });
  });

  group('rotatedSize', () {
    test('90° y 270° intercambian los ejes', () {
      expect(rotatedSize(640, 480, InputImageRotation.rotation90deg),
          const Size(480, 640));
      expect(rotatedSize(640, 480, InputImageRotation.rotation270deg),
          const Size(480, 640));
    });

    test('0° y 180° dejan los ejes como están', () {
      expect(rotatedSize(640, 480, InputImageRotation.rotation0deg),
          const Size(640, 480));
      expect(rotatedSize(640, 480, InputImageRotation.rotation180deg),
          const Size(640, 480));
    });
  });
}
