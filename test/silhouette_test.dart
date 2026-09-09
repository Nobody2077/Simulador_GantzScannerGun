import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hud_scanner/tracking/silhouette.dart';

/// Construye una máscara sintética donde [shape] decide qué es persona.
List<double> mask(int width, int height, bool Function(int x, int y) shape) => [
      for (var y = 0; y < height; y++)
        for (var x = 0; x < width; x++) shape(x, y) ? 1.0 : 0.0,
    ];

void main() {
  const extractor = SilhouetteExtractor(step: 2);
  const size = Size(64, 64);
  const wholeFrame = Rect.fromLTWH(0, 0, 64, 64);

  group('SilhouetteExtractor', () {
    test('una máscara vacía no produce contorno', () {
      final result = extractor.extract(
        confidences: mask(64, 64, (_, _) => false),
        maskWidth: 64,
        maskHeight: 64,
        imageSize: size,
        region: wholeFrame,
      );

      expect(result.isEmpty, isTrue);
    });

    test('una máscara enteramente llena tampoco: no hay borde', () {
      final result = extractor.extract(
        confidences: mask(64, 64, (_, _) => true),
        maskWidth: 64,
        maskHeight: 64,
        imageSize: size,
        region: wholeFrame,
      );

      expect(result.isEmpty, isTrue);
    });

    test('un bloque central produce contorno sobre su borde', () {
      final result = extractor.extract(
        confidences: mask(
            64, 64, (x, y) => x >= 20 && x < 44 && y >= 20 && y < 44),
        maskWidth: 64,
        maskHeight: 64,
        imageSize: size,
        region: wholeFrame,
      );

      expect(result.isEmpty, isFalse);
      // Cada segmento son cuatro valores: x0, y0, x1, y1.
      expect(result.segments.length % 4, 0);

      // Todo el contorno cae alrededor del bloque, no en el vacío.
      for (var i = 0; i < result.segments.length; i += 2) {
        expect(result.segments[i], inInclusiveRange(18, 46));
        expect(result.segments[i + 1], inInclusiveRange(18, 46));
      }
    });

    test('la región recorta: un objetivo fuera de ella no aporta contorno', () {
      final confidences =
          mask(64, 64, (x, y) => x >= 40 && x < 60 && y >= 40 && y < 60);

      final inside = extractor.extract(
        confidences: confidences,
        maskWidth: 64,
        maskHeight: 64,
        imageSize: size,
        region: const Rect.fromLTWH(36, 36, 28, 28),
      );
      final outside = extractor.extract(
        confidences: confidences,
        maskWidth: 64,
        maskHeight: 64,
        imageSize: size,
        region: const Rect.fromLTWH(0, 0, 20, 20),
      );

      expect(inside.isEmpty, isFalse);
      expect(outside.isEmpty, isTrue,
          reason: 'la segmentación no distingue personas; el recorte sí');
    });

    test('los puntos salen en coordenadas de imagen, no de máscara', () {
      // Máscara de 32 sobre una imagen de 64: cada celda vale el doble.
      final result = extractor.extract(
        confidences: mask(32, 32, (x, y) => x >= 8 && x < 24 && y >= 8 && y < 24),
        maskWidth: 32,
        maskHeight: 32,
        imageSize: size,
        region: wholeFrame,
      );

      expect(result.isEmpty, isFalse);
      final maxX = [
        for (var i = 0; i < result.segments.length; i += 2) result.segments[i]
      ].reduce((a, b) => a > b ? a : b);

      // El bloque llega hasta x=24 en máscara, que son 48 en imagen.
      expect(maxX, closeTo(48, 2));
    });

    test('el umbral decide qué cuenta como persona', () {
      final confidences = [
        for (var y = 0; y < 32; y++)
          for (var x = 0; x < 32; x++)
            (x >= 10 && x < 22 && y >= 10 && y < 22) ? 0.4 : 0.0,
      ];

      const strict = SilhouetteExtractor(threshold: 0.55, step: 2);
      const lenient = SilhouetteExtractor(threshold: 0.3, step: 2);

      expect(
        strict
            .extract(
              confidences: confidences,
              maskWidth: 32,
              maskHeight: 32,
              imageSize: size,
              region: wholeFrame,
            )
            .isEmpty,
        isTrue,
      );
      expect(
        lenient
            .extract(
              confidences: confidences,
              maskWidth: 32,
              maskHeight: 32,
              imageSize: size,
              region: wholeFrame,
            )
            .isEmpty,
        isFalse,
      );
    });
  });
}
