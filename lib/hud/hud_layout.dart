import 'dart:ui';

import 'hud_theme.dart';

/// Geometría compartida del HUD.
///
/// El cromo permanente y la capa de objetivo se dibujan en painters distintos
/// —uno estático, otro que se repinta con el tracker— y necesitan coincidir en
/// dónde está cada cosa. Esta clase es la única fuente de esas posiciones.
///
/// Todo se deriva del tamaño del lienzo, sin una sola coordenada absoluta: es
/// lo que hace que la misma composición funcione en teléfono y en tablet
/// (AC-6.8).
class HudLayout {
  HudLayout(this.size, this.theme);

  final Size size;
  final HudTheme theme;

  /// Marco general, separado de los bordes físicos de la pantalla.
  late final Rect frame = Rect.fromLTRB(
    theme.inset,
    theme.inset,
    size.width - theme.inset,
    size.height - theme.inset,
  );

  /// Longitud del brazo de las marcas de esquina.
  late final double cornerArm = theme.inset * 2.4;

  late final double stripHeight =
      (size.height * 0.15).clamp(58.0, 118.0).toDouble();

  /// Franja de instrumentos inferior.
  late final Rect strip = Rect.fromLTRB(
    frame.left,
    frame.bottom - stripHeight,
    frame.right,
    frame.bottom,
  );

  /// Área donde vive el objetivo, por encima de la franja.
  late final Rect stage = Rect.fromLTRB(
    frame.left,
    frame.top + theme.labelSize * 2.6,
    frame.right,
    strip.top - theme.inset * 0.6,
  );

  late final double _stripPad = stripHeight * 0.12;
  late final double _blockWidth = strip.width * 0.29;

  /// Fila [index] (0 a 2) del bloque izquierdo o derecho de la franja.
  ///
  /// Los rótulos los dibuja el cromo y los valores la capa de objetivo, así que
  /// ambos tienen que resolver la misma caja.
  Rect stripRow({required bool right, required int index}) {
    final rowHeight = (strip.height - _stripPad * 2) / 3;
    return Rect.fromLTWH(
      right ? strip.right - _blockWidth : strip.left,
      strip.top + _stripPad + index * rowHeight,
      _blockWidth,
      rowHeight,
    );
  }

  /// Centro del elemento circular de la franja.
  late final Offset stripHub = Offset(strip.center.dx, strip.center.dy);

  late final double stripHubRadius = stripHeight * 0.22;
}
