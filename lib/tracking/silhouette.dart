import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Contorno del objetivo, en coordenadas de imagen.
///
/// Cada entrada de [contours] es una polilínea abierta o cerrada: x0, y0, x1,
/// y1, … en orden de recorrido. Se dibuja como trazo continuo.
///
/// La versión anterior guardaba los segmentos sueltos que emite marching
/// squares y los dibujaba con `PointMode.lines`, cada uno por su cuenta. El
/// comentario de entonces decía que armar las polilíneas no se iba a notar; en
/// dispositivo se nota mucho: sin juntas entre segmento y segmento el contorno
/// se lee como un rosario de rayas sobre la persona en vez de una línea.
@immutable
class Silhouette {
  const Silhouette(this.contours);

  static const Silhouette empty = Silhouette([]);

  final List<Float32List> contours;

  bool get isEmpty => contours.isEmpty;

  /// Cuántos puntos tiene el contorno completo. Alimenta el diagnóstico.
  int get pointCount =>
      contours.fold(0, (total, contour) => total + contour.length ~/ 2);
}

/// Extrae el contorno de la máscara de segmentación por marching squares.
///
/// El algoritmo recorre la máscara en celdas y, para cada una, mira cuáles de
/// sus cuatro esquinas están por encima del umbral. Esa combinación determina
/// por dónde cruza el borde. Es el mismo método con el que se dibujan curvas de
/// nivel en un mapa.
///
/// Los segmentos que salen de ahí se encadenan en polilíneas y se suavizan
/// antes de devolverlos. Las dos cosas se hacen en coordenadas de máscara, que
/// es donde los extremos caen en valores exactos y se pueden comparar sin
/// tolerancias.
class SilhouetteExtractor {
  const SilhouetteExtractor({
    this.threshold = 0.45,
    this.step = 2,
    this.smoothingPasses = 2,
    this.minContourPoints = 6,
  });

  /// Confianza mínima para considerar que un punto es parte de la persona.
  ///
  /// El modelo está entrenado para selfies, así que a distancia de trabajo la
  /// confianza cae en los bordes —hombros, brazos, pelo— antes que en el torso.
  /// Un umbral alto recorta justo esas partes y deja una silueta a medias.
  final double threshold;

  /// Tamaño de celda en píxeles de máscara.
  ///
  /// Con 1 el contorno es más fiel y cuesta cuatro veces más. Con 2 la
  /// diferencia no se percibe una vez escalado a pantalla y suavizado.
  final int step;

  /// Pasadas de suavizado de Chaikin sobre cada polilínea.
  ///
  /// La máscara viene a baja resolución, así que el contorno crudo es una
  /// escalera de escalones del tamaño de la celda. Cada pasada corta las
  /// esquinas y duplica los puntos; con dos, la escalera desaparece y el
  /// contorno sigue pegado a la forma.
  final int smoothingPasses;

  /// Polilíneas más cortas que esto se descartan.
  ///
  /// El modelo deja motas sueltas alrededor del sujeto. Como cada mota produce
  /// su propio contorno diminuto, descartarlas por longitud las quita sin tocar
  /// el contorno principal.
  final int minContourPoints;

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

    final left = (region.left * toMaskX).floor().clamp(0, maskWidth - 1);
    final right = (region.right * toMaskX).ceil().clamp(0, maskWidth - 1);
    final top = (region.top * toMaskY).floor().clamp(0, maskHeight - 1);
    final bottom = (region.bottom * toMaskY).ceil().clamp(0, maskHeight - 1);
    if (right - left < step || bottom - top < step) return Silhouette.empty;

    // Segmentos sueltos, todavía en coordenadas de máscara.
    final segments = <double>[];
    void emit(double ax, double ay, double bx, double by) {
      segments
        ..add(ax)
        ..add(ay)
        ..add(bx)
        ..add(by);
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

    if (segments.isEmpty) return Silhouette.empty;

    final toImageX = imageSize.width / maskWidth;
    final toImageY = imageSize.height / maskHeight;

    final contours = <Float32List>[];
    for (final chain in _chain(segments)) {
      if (chain.length ~/ 2 < minContourPoints) continue;

      final smoothed = _smooth(chain, smoothingPasses);
      final scaled = Float32List(smoothed.length);
      for (var i = 0; i < smoothed.length; i += 2) {
        scaled[i] = smoothed[i] * toImageX;
        scaled[i + 1] = smoothed[i + 1] * toImageY;
      }
      contours.add(scaled);
    }

    return contours.isEmpty ? Silhouette.empty : Silhouette(contours);
  }

  /// Los extremos caen en múltiplos de medio píxel de máscara, así que
  /// cuartos de píxel alcanzan para comparar sin tolerancias.
  static int _key(double x, double y) =>
      (x * 4).round() * 1000003 + (y * 4).round();

  /// Une los segmentos sueltos en polilíneas.
  ///
  /// Marching squares emite cada celda por separado, pero los extremos de
  /// celdas vecinas coinciden exactamente. Recorrer esas coincidencias
  /// reconstruye el contorno en orden, que es lo que permite dibujarlo de un
  /// trazo y suavizarlo.
  static List<List<double>> _chain(List<double> segments) {
    final count = segments.length ~/ 4;
    final adjacency = <int, List<int>>{};
    for (var i = 0; i < count; i++) {
      final o = i * 4;
      adjacency
          .putIfAbsent(_key(segments[o], segments[o + 1]), () => <int>[])
          .add(i);
      adjacency
          .putIfAbsent(_key(segments[o + 2], segments[o + 3]), () => <int>[])
          .add(i);
    }

    final used = List<bool>.filled(count, false);
    final chains = <List<double>>[];

    for (var i = 0; i < count; i++) {
      if (used[i]) continue;
      used[i] = true;
      final o = i * 4;

      // Se camina hacia los dos lados desde el segmento semilla. La cola hacia
      // atrás se acumula al revés y se da vuelta al final: insertar al frente
      // en cada paso costaría cuadrático sobre contornos largos.
      final tail = _walk(segments, adjacency, used,
          x: segments[o + 2], y: segments[o + 3]);
      final head =
          _walk(segments, adjacency, used, x: segments[o], y: segments[o + 1]);

      chains.add([
        ..._reversedPairs(head),
        segments[o],
        segments[o + 1],
        segments[o + 2],
        segments[o + 3],
        ...tail,
      ]);
    }
    return chains;
  }

  /// Sigue la cadena desde un extremo y devuelve los puntos que agrega.
  static List<double> _walk(
    List<double> segments,
    Map<int, List<int>> adjacency,
    List<bool> used, {
    required double x,
    required double y,
  }) {
    final points = <double>[];
    var currentX = x;
    var currentY = y;

    while (true) {
      final key = _key(currentX, currentY);
      final candidates = adjacency[key];
      if (candidates == null) return points;

      var next = -1;
      for (final index in candidates) {
        if (!used[index]) {
          next = index;
          break;
        }
      }
      if (next < 0) return points;

      used[next] = true;
      final o = next * 4;
      // El extremo que continúa la cadena es el que no coincide con la punta.
      final startsHere = _key(segments[o], segments[o + 1]) == key;
      currentX = startsHere ? segments[o + 2] : segments[o];
      currentY = startsHere ? segments[o + 3] : segments[o + 1];
      points
        ..add(currentX)
        ..add(currentY);
    }
  }

  static List<double> _reversedPairs(List<double> points) {
    final out = <double>[];
    for (var i = points.length - 2; i >= 0; i -= 2) {
      out
        ..add(points[i])
        ..add(points[i + 1]);
    }
    return out;
  }

  /// Suavizado de Chaikin: cada tramo se reemplaza por sus puntos a un cuarto y
  /// a tres cuartos, lo que corta las esquinas de la escalera.
  ///
  /// Los extremos quedan fijos. En un contorno cerrado el primero y el último
  /// coinciden, así que fijarlos lo deja cerrado sin tener que tratar el caso
  /// aparte.
  static List<double> _smooth(List<double> points, int passes) {
    var current = points;
    for (var pass = 0; pass < passes; pass++) {
      final count = current.length ~/ 2;
      if (count < 3) break;

      final out = <double>[current[0], current[1]];
      for (var i = 0; i < count - 1; i++) {
        final ax = current[i * 2];
        final ay = current[i * 2 + 1];
        final bx = current[(i + 1) * 2];
        final by = current[(i + 1) * 2 + 1];
        out
          ..add(ax * 0.75 + bx * 0.25)
          ..add(ay * 0.75 + by * 0.25)
          ..add(ax * 0.25 + bx * 0.75)
          ..add(ay * 0.25 + by * 0.75);
      }
      out
        ..add(current[(count - 1) * 2])
        ..add(current[(count - 1) * 2 + 1]);
      current = out;
    }
    return current;
  }
}
