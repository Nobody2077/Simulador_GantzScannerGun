import 'package:flutter_test/flutter_test.dart';
import 'package:hud_scanner/tracking/distance_estimator.dart';

void main() {
  group('DistanceEstimator', () {
    const estimator = DistanceEstimator();

    test('reproduce el ejemplo trabajado del documento de requisitos', () {
      // Imagen de 1280 px con hFOV 67° → f ≈ 967 px.
      // Un rostro de 100 px de ancho queda a ~1,45 m.
      final distance = estimator.estimate(faceWidthPx: 100, imageWidthPx: 1280);

      expect(distance, isNotNull);
      expect(distance!, closeTo(1.45, 0.02));
    });

    test('la distancia es inversamente proporcional al ancho del rostro', () {
      final near = estimator.estimate(faceWidthPx: 200, imageWidthPx: 1280)!;
      final far = estimator.estimate(faceWidthPx: 100, imageWidthPx: 1280)!;

      expect(far, closeTo(near * 2, 0.001));
    });

    test('un hFOV más ancho acerca el objetivo para el mismo bbox', () {
      // Más campo de visión significa menos píxeles por grado, así que un
      // rostro del mismo tamaño en píxeles tiene que estar más cerca.
      final narrow = estimator.estimate(
          faceWidthPx: 100, imageWidthPx: 1280, hFovDegrees: 50)!;
      final wide = estimator.estimate(
          faceWidthPx: 100, imageWidthPx: 1280, hFovDegrees: 80)!;

      expect(wide, lessThan(narrow));
    });

    test('devuelve null con entradas que no significan nada', () {
      expect(estimator.estimate(faceWidthPx: 0, imageWidthPx: 1280), isNull);
      expect(estimator.estimate(faceWidthPx: 100, imageWidthPx: 0), isNull);
    });
  });
}
