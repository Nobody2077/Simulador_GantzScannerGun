import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hud_scanner/tracking/body_geometry.dart';

void main() {
  group('BodyGeometry', () {
    test('deriva el encuadre del cuerpo con las proporciones de canon', () {
      // Alto de cara 78 px → cabeza 100 px → cuerpo 750 × 220.
      final body = BodyGeometry.fromFace(const Rect.fromLTWH(100, 50, 60, 78));

      expect(body.height, closeTo(750, 0.01));
      expect(body.width, closeTo(220, 0.01));
      expect(body.top, closeTo(28, 0.01));
    });

    test('el cuerpo queda centrado horizontalmente sobre la cara', () {
      const face = Rect.fromLTWH(100, 50, 60, 78);
      final body = BodyGeometry.fromFace(face);

      expect(body.center.dx, closeTo(face.center.dx, 0.01));
    });

    test('la corona queda por encima del borde superior de la cara', () {
      const face = Rect.fromLTWH(100, 50, 60, 78);
      final body = BodyGeometry.fromFace(face);

      expect(body.top, lessThan(face.top));
    });

    test('escala proporcionalmente: cara al doble, cuerpo al doble', () {
      final small = BodyGeometry.fromFace(const Rect.fromLTWH(0, 0, 30, 39));
      final large = BodyGeometry.fromFace(const Rect.fromLTWH(0, 0, 60, 78));

      expect(large.height, closeTo(small.height * 2, 0.01));
      expect(large.width, closeTo(small.width * 2, 0.01));
    });
  });
}
