import 'package:flutter/services.dart' show DeviceOrientation;

/// Rotación de la interfaz en grados (AC-2.2).
///
/// El sensor está montado en una orientación fija de fábrica que casi nunca
/// coincide con cómo se muestra la interfaz, y la diferencia hay que
/// declarársela a ML Kit para que vea los rostros derechos.
const Map<DeviceOrientation, int> orientationDegrees = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

/// Mantiene la orientación de interfaz dentro de las apaisadas.
///
/// La app está bloqueada en apaisado (AC-1.5), pero la cámara informa cómo está
/// sostenido el aparato, no cómo se está mostrando la interfaz. Con la rotación
/// automática libre, inclinar el dispositivo hacia vertical hacía que esa
/// lectura pasara a retrato: la compensación giraba 90°, los ejes de la imagen
/// se intercambiaban y el preview se ampliaba para cubrir la pantalla.
///
/// Como la interfaz nunca se muestra en retrato, conservar la última lectura
/// apaisada es exactamente lo que hay en pantalla.
DeviceOrientation stabilizeLandscape(
  DeviceOrientation reported,
  DeviceOrientation previous,
) =>
    reported == DeviceOrientation.landscapeLeft ||
            reported == DeviceOrientation.landscapeRight
        ? reported
        : previous;

/// Grados que hay que rotar la imagen para que ML Kit la vea derecha.
///
/// La cámara frontal compensa en sentido contrario porque su imagen viene
/// espejada.
int compensateRotation({
  required int sensorOrientation,
  required DeviceOrientation uiOrientation,
  required bool frontFacing,
}) {
  final degrees = orientationDegrees[uiOrientation] ?? 0;
  return frontFacing
      ? (sensorOrientation + degrees) % 360
      : (sensorOrientation - degrees + 360) % 360;
}
