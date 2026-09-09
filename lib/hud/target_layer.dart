import 'package:flutter/widgets.dart';

import 'hud_layout.dart';
import 'hud_theme.dart';

/// Designación técnica de un objetivo (AC-6.3).
///
/// Es un número de pista, no un nombre: no se le pone un nombre inventado a una
/// persona real.
String targetDesignation(int? id) =>
    id == null ? 'TGT-··' : 'TGT-${(id % 100).toString().padLeft(2, '0')}';

/// Un objetivo tal como se dibuja.
///
/// Los painters no hablan con el tracker: reciben esta lista ya resuelta. Eso
/// es lo que permite componer el HUD contra datos sintéticos —los mockups de
/// `hud_mockup_test.dart`— sin cámara y sin máquina de estados.
@immutable
class TargetReadout {
  const TargetReadout({
    required this.id,
    required this.bodyBox,
    this.distanceMeters,
    this.locked = false,
    this.calibrated = false,
    this.vitality = 1,
  });

  /// `null` cuando ML Kit no le asignó id de seguimiento.
  final int? id;

  /// Encuadre del cuerpo en coordenadas de pantalla, ya recortado al área útil.
  final Rect bodyBox;

  /// Distancia estimada, o `null` si la caja es demasiado chica para que la
  /// cuenta signifique algo.
  final double? distanceMeters;

  /// El objetivo trabado. Solo uno a la vez.
  final bool locked;

  /// AC-4.4: `false` mientras el hFOV real no esté disponible.
  final bool calibrated;

  /// Barra del sujeto, de 0 a 1.
  ///
  /// Hoy es siempre 1. Va como dato del objetivo y no como adorno del painter
  /// para que, si algún día pasa a significar algo medido, cambie el valor y no
  /// el dibujo.
  final double vitality;

  String get designation => targetDesignation(id);

  /// El mismo objetivo con otro encuadre.
  ///
  /// El tracker razona en coordenadas de imagen y el painter dibuja en
  /// coordenadas de pantalla: entre una cosa y la otra hay un mapeo y un
  /// recorte al área útil, y cada paso devuelve una caja nueva.
  TargetReadout withBodyBox(Rect box) => TargetReadout(
        id: id,
        bodyBox: box,
        distanceMeters: distanceMeters,
        locked: locked,
        calibrated: calibrated,
        vitality: vitality,
      );

  /// AC-4.5 y AC-4.7: una decimal, con "~" mientras el hFOV no esté calibrado.
  String get distanceText {
    final distance = distanceMeters;
    if (distance == null) return '—';
    return '${calibrated ? '' : '~'}${distance.toStringAsFixed(1)} m';
  }
}

/// Ordena la columna: el más cercano arriba, el más lejano abajo.
///
/// Los objetivos sin distancia estimada van al final — no se sabe dónde
/// ponerlos, y adivinar los haría saltar de puesto.
///
/// Este orden es estable frente a distancias iguales, pero **no** tiene
/// histéresis: dos sujetos casi a la misma distancia se intercambian de puesto
/// a la tasa de inferencia. La banda muerta vive en el tracker, que es quien
/// tiene memoria del orden anterior.
List<TargetReadout> orderByProximity(List<TargetReadout> targets) {
  final ordered = [...targets];
  ordered.sort((a, b) {
    final da = a.distanceMeters;
    final db = b.distanceMeters;
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return da.compareTo(db);
  });
  return ordered;
}

/// Cuántos objetivos llevan ficha de distancia a la vez.
///
/// Tres en teléfono y cinco en tablet: el tope escala con la pantalla, igual
/// que ya hace [hudScale] con la tipografía (AC-6.8). Cinco fichas en un
/// teléfono apaisado se tapan entre sí. Los objetivos que quedan fuera del tope
/// se siguen dibujando —ganchos y barra—, solo que sin rótulo.
///
/// 600 dp de lado corto es el corte habitual entre teléfono y tablet.
int labelledTargetLimit(Size screen) => screen.shortestSide >= 600 ? 5 : 3;

// ── ganchos ─────────────────────────────────────────────────────────────────

/// Ganchos angulares en las esquinas: encuadran sin tapar al objetivo, que es
/// de lo que se trata al apuntar.
void paintBrackets(Canvas canvas, Rect box, Color color, double strokeWidth) {
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..strokeCap = StrokeCap.square
    ..color = color;

  // Proporcional al lado corto, para que un objetivo lejano no termine con
  // brazos que se tocan entre sí.
  final arm = (box.shortestSide * 0.18).clamp(12.0, 72.0);
  final lip = arm * 0.28;

  for (final corner in const [
    (Alignment.topLeft, 1.0, 1.0),
    (Alignment.topRight, -1.0, 1.0),
    (Alignment.bottomLeft, 1.0, -1.0),
    (Alignment.bottomRight, -1.0, -1.0),
  ]) {
    final origin = corner.$1.inscribe(Size.zero, box).topLeft;
    final dx = corner.$2;
    final dy = corner.$3;

    // Brazo horizontal con un pequeño labio perpendicular en la punta: es lo
    // que separa un gancho de instrumento de una simple L.
    final path = Path()
      ..moveTo(origin.dx + dx * arm, origin.dy + dy * lip)
      ..lineTo(origin.dx + dx * arm, origin.dy)
      ..lineTo(origin.dx, origin.dy)
      ..lineTo(origin.dx, origin.dy + dy * arm)
      ..lineTo(origin.dx + dx * lip, origin.dy + dy * arm);
    canvas.drawPath(path, paint);
  }
}

// ── ficha ───────────────────────────────────────────────────────────────────

/// Ficha del objetivo: designación y distancia, flotando junto al sujeto.
///
/// Sin línea guía. La versión anterior unía ficha y objetivo con una diagonal;
/// con una sola ficha ya ensuciaba, y con cinco el área útil se llenaba de
/// cables cruzados. La separación respecto del gancho es la que comunica la
/// pertenencia.
///
/// [compact] es la variante de los objetivos no trabados: la misma información
/// con menos peso de trazo, para que el trabado siga siendo el que manda.
///
/// [avoid] son las fichas ya colocadas. Con varios sujetos juntos, dos fichas
/// ancladas a la misma altura se superponen y ninguna de las dos se lee;
/// devolver el rectángulo ocupado permite al llamador encadenarlas. Se coloca
/// primero la del trabado, que es la que tiene derecho a su lugar.
///
/// Devuelve el rectángulo que la ficha terminó ocupando.
Rect paintTargetCard(
  Canvas canvas,
  HudTheme theme,
  TargetReadout readout, {
  required Rect bounds,
  required Color color,
  bool compact = false,
  List<Rect> avoid = const [],
}) {
  final rows = <TextPainter>[];

  if (compact) {
    rows.add(_text(
      readout.designation,
      hudText(color: color, size: theme.labelSize * 0.95),
    ));
    rows.add(_text(
      readout.distanceText,
      hudText(color: theme.readout, size: theme.labelSize * 1.25),
    ));
  } else {
    rows.add(_text(
      'OBJETIVO',
      hudText(
        color: theme.structureDim,
        size: theme.microSize,
        letterSpacing: theme.microSize * 0.22,
      ),
    ));
    rows.add(_text(
      readout.designation,
      hudText(color: color, size: theme.labelSize * 1.15),
    ));
    rows.add(_text(
      'DISTANCIA',
      hudText(
        color: theme.structureDim,
        size: theme.microSize,
        letterSpacing: theme.microSize * 0.22,
      ),
    ));
    rows.add(_text(
      readout.distanceText,
      hudText(color: theme.readout, size: theme.valueSize),
    ));
  }

  final pad = theme.inset * (compact ? 0.38 : 0.55);
  final width =
      rows.map((r) => r.width).reduce((a, b) => a > b ? a : b) + pad * 2;
  final height =
      rows.fold<double>(0, (sum, r) => sum + r.height) + pad * (compact ? 2 : 2.6);

  // Arriba y a la derecha del sujeto, separada del gancho, traída dentro del
  // área donde la ficha puede vivir.
  final box = readout.bodyBox;
  final gap = theme.inset * (compact ? 0.9 : 1.4);
  final anchor = Offset(box.right + gap, box.top - height - gap);
  final origin = Offset(
    anchor.dx.clamp(bounds.left, (bounds.right - width).clamp(bounds.left, bounds.right)),
    anchor.dy.clamp(bounds.top, (bounds.bottom - height).clamp(bounds.top, bounds.bottom)),
  );
  final card = _placeClear(
    Rect.fromLTWH(origin.dx, origin.dy, width, height),
    bounds,
    avoid,
    theme.inset * 0.4,
  );

  canvas.drawRect(card, Paint()..color = theme.panelFill);
  canvas.drawRect(
    card,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = theme.hairline
      ..color = theme.structureDim.withValues(alpha: compact ? 0.55 : 1),
  );
  // Filete de acento en el canto izquierdo.
  canvas.drawRect(
    Rect.fromLTWH(
      card.left,
      card.top,
      theme.hairline * (compact ? 1.6 : 2.5),
      card.height,
    ),
    Paint()..color = color,
  );

  var y = card.top + pad;
  for (var i = 0; i < rows.length; i++) {
    rows[i].paint(canvas, Offset(card.left + pad, y));
    y += rows[i].height;
    // En la ficha completa el rótulo se pega a su valor y el par se separa del
    // siguiente; en la compacta no hay rótulos que agrupar.
    if (compact) {
      y += pad * 0.15;
    } else {
      y += i.isEven ? pad * 0.2 : pad * 0.6;
    }
  }

  return card;
}

/// Corre la ficha hasta encontrarle un hueco libre.
///
/// Prueba primero arriba y abajo del sitio natural —que es donde la ficha
/// sigue leyéndose como perteneciente a su sujeto— y recién después a los
/// costados. Si no hay lugar en ninguna parte, se queda donde estaba: una ficha
/// superpuesta se lee mal, pero una ficha desterrada al otro extremo de la
/// pantalla miente sobre a quién describe.
Rect _placeClear(Rect card, Rect bounds, List<Rect> avoid, double gap) {
  if (avoid.isEmpty) return card;

  bool free(Rect candidate) =>
      !avoid.any((other) => candidate.inflate(gap).overlaps(other));

  if (free(card)) return card;

  final step = card.height + gap;
  for (var ring = 1; ring <= 4; ring++) {
    for (final offset in [
      Offset(0, -step * ring),
      Offset(0, step * ring),
      Offset(-(card.width + gap) * ring, 0),
      Offset((card.width + gap) * ring, 0),
    ]) {
      final moved = card.shift(offset);
      if (bounds.contains(moved.topLeft) &&
          bounds.contains(moved.bottomRight) &&
          free(moved)) {
        return moved;
      }
    }
  }
  return card;
}

// ── columna de sujetos ──────────────────────────────────────────────────────

/// Ancho que la columna de barras reserva del área útil.
double rosterWidth(HudTheme theme) => theme.labelSize * 8.4;

/// Columna de barras de los sujetos escaneados, a la izquierda del área útil.
///
/// Va a la izquierda porque las fichas se anclan a la derecha de cada sujeto:
/// una columna a la derecha se las llevaría por delante.
///
/// El orden lo fija [orderByProximity] — el más cercano arriba —, pero el
/// tamaño lo fija el lock: la barra grande es la del objetivo trabado, esté en
/// el puesto que esté. Son dos señales distintas y no compiten.
///
/// Las barras van en cian y no en ámbar a propósito. La regla de la paleta dice
/// que el ámbar es para lo que el sistema **mide**, y esta barra no mide nada:
/// está siempre llena. Pintarla de ámbar la haría pasar por una lectura real.
void paintRoster(
  Canvas canvas,
  HudLayout layout,
  HudTheme theme,
  List<TargetReadout> ordered,
) {
  if (ordered.isEmpty) return;

  final left = layout.stage.left;
  final width = rosterWidth(theme);
  var y = layout.stage.top;

  final header = _text(
    'SUJETOS',
    hudText(
      color: theme.structureDim,
      size: theme.microSize,
      letterSpacing: theme.microSize * 0.24,
    ),
  );
  header.paint(canvas, Offset(left, y));
  y += header.height + theme.microSize * 0.45;
  canvas.drawLine(
    Offset(left, y),
    Offset(left + width, y),
    Paint()
      ..strokeWidth = theme.hairline
      ..color = theme.structureFaint,
  );
  y += theme.microSize * 0.9;

  // Se deja aire al pie para el rótulo de estado, que vive centrado ahí.
  final bottom = layout.stage.bottom - theme.labelSize * 2.4;

  for (var i = 0; i < ordered.length; i++) {
    final readout = ordered[i];
    final height = _rosterRowHeight(theme, readout.locked);
    final remaining = ordered.length - i;

    // No se encogen las filas: la altura de fila ya es el mínimo legible a
    // distancia de brazo (AC-6.9). Cuando no entran más, se corta con el
    // contador de los que quedan.
    if (y + height > bottom && remaining > 0) {
      final more = _text(
        '+$remaining',
        hudText(color: theme.structureDim, size: theme.microSize),
      );
      if (y + more.height <= bottom) more.paint(canvas, Offset(left, y));
      return;
    }

    _paintRosterRow(canvas, theme, readout, left, y, width);
    y += height + theme.microSize * 0.75;
  }
}

double _rosterRowHeight(HudTheme theme, bool locked) {
  final labelSize = locked ? theme.labelSize : theme.microSize * 1.2;
  final barHeight = locked ? theme.labelSize * 0.72 : theme.labelSize * 0.46;
  return labelSize * 1.25 + barHeight + theme.microSize * 0.35;
}

void _paintRosterRow(
  Canvas canvas,
  HudTheme theme,
  TargetReadout readout,
  double left,
  double top,
  double width,
) {
  final locked = readout.locked;
  final color = locked ? theme.structure : theme.structureDim;

  final label = _text(
    readout.designation,
    hudText(
      color: color,
      size: locked ? theme.labelSize : theme.microSize * 1.2,
      letterSpacing: theme.microSize * 0.1,
    ),
  );
  label.paint(canvas, Offset(left, top));

  final barTop = top + label.height + theme.microSize * 0.35;
  final barHeight = locked ? theme.labelSize * 0.72 : theme.labelSize * 0.46;
  // La barra del trabado ocupa el ancho completo de la columna; las demás se
  // quedan cortas, para que la jerarquía se lea de un vistazo y no por color.
  final barWidth = locked ? width : width * 0.82;
  final track = Rect.fromLTWH(left, barTop, barWidth, barHeight);

  canvas.drawRect(
    track,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = theme.hairline
      ..color = theme.structureFaint,
  );
  canvas.drawRect(
    Rect.fromLTWH(
      track.left,
      track.top,
      track.width * readout.vitality.clamp(0, 1),
      track.height,
    ),
    Paint()..color = color.withValues(alpha: locked ? 0.95 : 0.6),
  );

  if (locked) {
    // Filete de acento, el mismo recurso que usa la ficha para marcar al
    // objetivo trabado.
    canvas.drawRect(
      Rect.fromLTWH(
        track.left - theme.hairline * 3.5,
        track.top,
        theme.hairline * 2,
        track.height,
      ),
      Paint()..color = theme.readout,
    );
  }
}

TextPainter _text(String value, TextStyle style) => TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
