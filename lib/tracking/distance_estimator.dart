import 'dart:math' as math;

/// Estimación de distancia por modelo pinhole (REQ-4).
///
///     d = (W_real × f_px) / w_bbox
///     f_px = (ancho_imagen / 2) / tan(hFOV / 2)
///
/// Devuelve metros. Es una estimación, no una medición: depende de que el
/// rostro se parezca al ancho de referencia y de que el hFOV sea el real.
class DistanceEstimator {
  const DistanceEstimator({
    this.faceWidthMm = 150,
    this.fallbackHFovDegrees = 67,
  });

  /// Ancho bizigomático medio de un adulto (AC-4.2).
  final double faceWidthMm;

  /// AC-4.4: el plugin `camera` no expone el campo de visión, así que sin un
  /// platform channel que lea CameraCharacteristics se trabaja con este valor
  /// y la lectura se marca como no calibrada.
  final double fallbackHFovDegrees;

  /// Distancia en metros, o `null` si la caja es demasiado chica para que la
  /// cuenta signifique algo.
  double? estimate({
    required double faceWidthPx,
    required double imageWidthPx,
    double? hFovDegrees,
  }) {
    if (faceWidthPx <= 0 || imageWidthPx <= 0) return null;

    final fovRadians = (hFovDegrees ?? fallbackHFovDegrees) * math.pi / 180;
    final focalPx = (imageWidthPx / 2) / math.tan(fovRadians / 2);

    return (faceWidthMm * focalPx) / faceWidthPx / 1000;
  }
}
