import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Traduce coordenadas de imagen de ML Kit al espacio de pantalla.
///
/// Validado en dispositivo durante el Spike 0, en cámara trasera y frontal.
///
/// Hay tres cosas que tienen que salir bien a la vez:
///
///  1. La imagen llega rotada respecto de la pantalla. Lo resuelve [rotatedSize],
///     y el [imageSize] que recibe esta clase ya viene rotado.
///  2. El preview se recorta con `BoxFit.cover`, no se estira. Escala por el
///     lado que se queda corto y descarta el sobrante del otro.
///  3. La cámara frontal entrega la imagen espejada.
class CoordinateMapper {
  CoordinateMapper({
    required this.imageSize,
    required this.canvasSize,
    required this.mirror,
  });

  /// Tamaño de la imagen **ya rotada**, tal como la ve ML Kit.
  final Size imageSize;

  /// Tamaño del área donde se dibuja el preview.
  final Size canvasSize;

  /// `true` para la cámara frontal, que entrega la imagen espejada.
  final bool mirror;

  /// `BoxFit.cover` escala por el lado que se queda corto, de ahí el máximo.
  late final double _scale = math.max(
    canvasSize.width / imageSize.width,
    canvasSize.height / imageSize.height,
  );

  /// El sobrante se recorta por igual de los dos lados, así que el origen se
  /// desplaza la mitad.
  late final double _offsetX =
      (canvasSize.width - imageSize.width * _scale) / 2;
  late final double _offsetY =
      (canvasSize.height - imageSize.height * _scale) / 2;

  Rect mapRect(Rect box) {
    final top = box.top * _scale + _offsetY;
    final bottom = box.bottom * _scale + _offsetY;
    var left = box.left * _scale + _offsetX;
    var right = box.right * _scale + _offsetX;

    if (mirror) {
      // Al invertir el eje X, el borde izquierdo pasa a ser el derecho.
      final mirroredLeft = canvasSize.width - right;
      right = canvasSize.width - left;
      left = mirroredLeft;
    }

    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// Versión para nubes de puntos, con la misma transformación que [mapRect].
  ///
  /// Trabaja sobre `Float32List` de x,y intercalados para poder ir directo a
  /// `Canvas.drawRawPoints`: un contorno son varios miles de puntos por cuadro,
  /// y construir un `Offset` por cada uno se nota.
  Float32List mapPoints(Float32List points) {
    final out = Float32List(points.length);
    for (var i = 0; i < points.length; i += 2) {
      final x = points[i] * _scale + _offsetX;
      out[i] = mirror ? canvasSize.width - x : x;
      out[i + 1] = points[i + 1] * _scale + _offsetY;
    }
    return out;
  }
}

/// Tamaño de la imagen tal como la ve ML Kit después de aplicar [rotation].
///
/// Con 90° o 270° los ejes se intercambian; con 0° o 180° quedan igual. Pasar
/// por alto este intercambio es la causa más común de que la caja aparezca
/// desplazada o deformada.
Size rotatedSize(int rawWidth, int rawHeight, InputImageRotation rotation) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return Size(rawHeight.toDouble(), rawWidth.toDouble());
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      return Size(rawWidth.toDouble(), rawHeight.toDouble());
  }
}
