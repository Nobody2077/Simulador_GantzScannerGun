import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Contorno del objetivo, en coordenadas de imagen.
///
/// Los puntos van de a pares: cada cuatro valores —x0, y0, x1, y1— describen un
/// segmento suelto. No se ensamblan en polígonos cerrados a propósito: para
/// dibujar una silueta alcanza con los segmentos, y armar los polígonos costaría
/// bastante más por cuadro sin que se note la diferencia.
@immutable
class Silhouette {
  const Silhouette(this.segments);

  static final Silhouette empty = Silhouette(Float32List(0));

  final Float32List segments;

  bool get isEmpty => segments.isEmpty;
}

/// Extrae el contorno de la máscara de segmentación por marching squares.
///
/// El algoritmo recorre la máscara en celdas y, para cada una, mira cuáles de
/// sus cuatro esquinas están por encima del umbral. Esa combinación determina
/// por dónde cruza el borde. Es el mismo método con el que se dibujan curvas de
/// nivel en un mapa.
class SilhouetteExtractor {
  const SilhouetteExtractor({this.threshold = 0.45, this.step = 2});

  /// Confianza mínima para considerar que un punto es parte de la persona.
  ///
  /// El modelo está entrenado para selfies, así que a distancia de trabajo la
  /// confianza cae en los bordes —hombros, brazos, pelo— antes que en el torso.
  /// Un umbral alto recorta justo esas partes y deja una silueta a medias.
  final double threshold;

  /// Tamaño de celda en píxeles de máscara.
  ///
  /// Con 1 el contorno es más fiel y cuesta cuatro veces más. Con 2 la
  /// diferencia no se percibe una vez escalado a pantalla.
  final int step;

  /// Contorno dentro de [region], expresado en coordenadas de imagen.
  ///
  /// Limitar el recorrido a la región del objetivo hace dos cosas a la vez:
  /// evita recorrer la máscara entera cada cuadro, y descarta a las demás
  /// personas del encuadre — la segmentación no distingue entre ellas, así que
  /// sin este recorte el contorno del objetivo trabado vendría con acompañantes.
  Silhouette extract({
    required List<double> confidences,
    required int maskWidth,
    required int maskHeight,
    required Size imageSize,
    required Rect region,
  }) {
    if (maskWidth <= 0 || maskHeight <= 0 || imageSize.isEmpty) {
      return Silhouette.empty;
    }

    final toMaskX = maskWidth / imageSize.width;
    final toMaskY = maskHeight / imageSize.height;
    final toImageX = imageSize.width / maskWidth;
    final toImageY = imageSize.height / maskHeight;

    final left = (region.left * toMaskX).floor().clamp(0, maskWidth - 1);
    final right = (region.right * toMaskX).ceil().clamp(0, maskWidth - 1);
    final top = (region.top * toMaskY).floor().clamp(0, maskHeight - 1);
    final bottom = (region.bottom * toMaskY).ceil().clamp(0, maskHeight - 1);
    if (right - left < step || bottom - top < step) return Silhouette.empty;

    final out = <double>[];

    void emit(double ax, double ay, double bx, double by) {
      out
        ..add(ax * toImageX)
        ..add(ay * toImageY)
        ..add(bx * toImageX)
        ..add(by * toImageY);
    }

    for (var y = top; y + step <= bottom; y += step) {
      final rowTop = y * maskWidth;
      final rowBottom = (y + step) * maskWidth;

      for (var x = left; x + step <= right; x += step) {
        final topLeft = confidences[rowTop + x] >= threshold;
        final topRight = confidences[rowTop + x + step] >= threshold;
        final bottomRight = confidences[rowBottom + x + step] >= threshold;
        final bottomLeft = confidences[rowBottom + x] >= threshold;

        final code = (topLeft ? 8 : 0) |
            (topRight ? 4 : 0) |
            (bottomRight ? 2 : 0) |
            (bottomLeft ? 1 : 0);
        // Celda entera dentro o entera fuera: no hay borde que dibujar.
        if (code == 0 || code == 15) continue;

        final half = step / 2;
        final midTopX = x + half;
        final midBottomX = x + half;
        final midLeftY = y + half;
        final midRightY = y + half;
        final xr = (x + step).toDouble();
        final yb = (y + step).toDouble();

        switch (code) {
          case 1:
          case 14:
            emit(x.toDouble(), midLeftY, midBottomX, yb);
          case 2:
          case 13:
            emit(midBottomX, yb, xr, midRightY);
          case 3:
          case 12:
            emit(x.toDouble(), midLeftY, xr, midRightY);
          case 4:
          case 11:
            emit(midTopX, y.toDouble(), xr, midRightY);
          case 6:
          case 9:
            emit(midTopX, y.toDouble(), midBottomX, yb);
          case 7:
          case 8:
            emit(x.toDouble(), midLeftY, midTopX, y.toDouble());
          // Casos ambiguos: las dos diagonales opuestas están dentro, así que
          // el borde cruza la celda dos veces.
          case 5:
            emit(x.toDouble(), midLeftY, midTopX, y.toDouble());
            emit(midBottomX, yb, xr, midRightY);
          case 10:
            emit(midTopX, y.toDouble(), xr, midRightY);
            emit(x.toDouble(), midLeftY, midBottomX, yb);
        }
      }
    }

    return Silhouette(Float32List.fromList(out));
  }
}
