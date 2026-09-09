import 'dart:ui';

/// Deriva el encuadre de la figura completa a partir del rostro detectado.
///
/// La cara sigue siendo el ancla —es lo que ML Kit sabe seguir con un id
/// estable, y es la referencia de escala del cálculo de distancia—, pero el
/// reticle tiene que encuadrar el cuerpo: un rectángulo ajustado a la cara se
/// lee como videovigilancia, no como un sistema de apuntado.
///
/// Todo esto es proporción antropométrica, no medición. Es una estimación que
/// asume una persona de pie y de frente; sentada o muy escorzada, el encuadre
/// queda largo. El costo es cero inferencia adicional, que es exactamente por
/// qué se eligió este camino frente a un segundo modelo de pose.
abstract final class BodyGeometry {
  /// La caja de ML Kit cubre la cara, no el cráneo completo: su alto ronda
  /// 0,78 de la altura de la cabeza.
  static const double faceBoxToHeadHeight = 1 / 0.78;

  /// Un adulto de pie mide entre 7 y 8 cabezas. 7,5 es el valor de canon.
  static const double headsPerBody = 7.5;

  /// Ancho de hombros: algo más de dos cabezas.
  static const double headsPerShoulderWidth = 2.2;

  /// Cuánta cabeza queda por encima del borde superior de la caja del rostro.
  static const double crownAboveFace = 0.22;

  /// Encuadre del cuerpo, en el mismo espacio de coordenadas que [face].
  ///
  /// Puede salirse del cuadro por abajo, y está bien que así sea: a distancia
  /// de trabajo una persona no entra entera en la imagen.
  static Rect fromFace(Rect face) {
    final headHeight = face.height * faceBoxToHeadHeight;
    final bodyHeight = headHeight * headsPerBody;
    final bodyWidth = headHeight * headsPerShoulderWidth;
    final top = face.top - headHeight * crownAboveFace;

    return Rect.fromLTWH(
      face.center.dx - bodyWidth / 2,
      top,
      bodyWidth,
      bodyHeight,
    );
  }
}
