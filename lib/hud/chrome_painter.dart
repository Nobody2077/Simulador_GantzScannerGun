import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'hud_layout.dart';
import 'hud_theme.dart';

/// Cromo permanente del HUD: el marco que está siempre, haya objetivo o no.
///
/// Es deliberadamente estático — no escucha al tracker y solo se repinta si
/// cambia el tema o el tamaño. La densidad de la referencia sale de estas
/// formas fijas; los valores que cambian los pone [HudPainter] encima, así el
/// repintado por frame queda acotado a lo que de verdad se mueve.
///
/// Ninguna forma acá finge una lectura: son marcos, escalas y divisiones. Los
/// números salen todos de mediciones reales.
class ChromePainter extends CustomPainter {
  const ChromePainter({required this.theme});

  final HudTheme theme;

  @override
  void paint(Canvas canvas, Size size) {
    final layout = HudLayout(size, theme);

    _paintCorners(canvas, layout);
    _paintTopBar(canvas, layout);
    _paintSideScales(canvas, layout);
    _paintStrip(canvas, layout);
  }

  Paint get _structure => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = theme.hairline
    ..color = theme.structure;

  Paint get _dim => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = theme.hairline
    ..color = theme.structureDim;

  Paint get _faint => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = theme.hairline
    ..color = theme.structureFaint;

  /// Marcas de esquina: acotan la pantalla útil sin encerrarla en un rectángulo.
  void _paintCorners(Canvas canvas, HudLayout layout) {
    final frame = layout.frame;
    final arm = layout.cornerArm;
    final paint = _structure;

    // Un pequeño hueco en el vértice hace que se lean como marcas de registro
    // y no como un marco recortado.
    final gap = theme.inset * 0.35;

    for (final corner in const [
      (Alignment.topLeft, 1.0, 1.0),
      (Alignment.topRight, -1.0, 1.0),
      (Alignment.bottomLeft, 1.0, -1.0),
      (Alignment.bottomRight, -1.0, -1.0),
    ]) {
      final origin = corner.$1.inscribe(Size.zero, frame).topLeft;
      final dx = corner.$2;
      final dy = corner.$3;

      canvas.drawLine(
        origin + Offset(dx * gap, 0),
        origin + Offset(dx * arm, 0),
        paint,
      );
      canvas.drawLine(
        origin + Offset(0, dy * gap),
        origin + Offset(0, dy * arm),
        paint,
      );
    }
  }

  /// Rótulo de modo arriba al centro, con reglas a los lados y el índice de
  /// puntería justo debajo.
  void _paintTopBar(Canvas canvas, HudLayout layout) {
    final frame = layout.frame;
    final label = _text('< MODO ESCANEO >',
        hudText(
          color: theme.structure,
          size: theme.labelSize,
          letterSpacing: theme.labelSize * 0.22,
        ));

    final centerX = frame.center.dx;
    final y = frame.top;
    final halfLabel = label.width / 2;
    final gap = theme.inset;

    label.paint(canvas, Offset(centerX - halfLabel, y));

    final ruleY = y + label.height / 2;
    canvas.drawLine(Offset(frame.left + layout.cornerArm + gap, ruleY),
        Offset(centerX - halfLabel - gap, ruleY), _dim);
    canvas.drawLine(Offset(centerX + halfLabel + gap, ruleY),
        Offset(frame.right - layout.cornerArm - gap, ruleY), _dim);

    // Índice de puntería: el único elemento fijo en ámbar, porque marca dónde
    // apunta el sistema.
    final tip = Offset(centerX, y + label.height + theme.inset * 0.9);
    final half = theme.labelSize * 0.55;
    final marker = Path()
      ..moveTo(tip.dx - half, tip.dy - half)
      ..lineTo(tip.dx + half, tip.dy - half)
      ..lineTo(tip.dx, tip.dy)
      ..close();
    canvas.drawPath(marker, Paint()..color = theme.readout);
  }

  /// Escalas verticales a ambos lados, con marcas largas cada cinco.
  void _paintSideScales(Canvas canvas, HudLayout layout) {
    final stage = layout.stage;
    final top = stage.top + stage.height * 0.14;
    final bottom = stage.bottom - stage.height * 0.14;
    final step = theme.labelSize * 1.35;
    final shortTick = theme.inset * 0.35;
    final longTick = theme.inset * 0.8;

    for (final isRight in const [false, true]) {
      final x = isRight ? stage.right : stage.left;
      final direction = isRight ? -1.0 : 1.0;

      canvas.drawLine(Offset(x, top), Offset(x, bottom), _dim);

      var index = 0;
      for (var y = top; y <= bottom; y += step) {
        final length = index % 5 == 0 ? longTick : shortTick;
        canvas.drawLine(
          Offset(x, y),
          Offset(x + direction * length, y),
          index % 5 == 0 ? _dim : _faint,
        );
        index++;
      }
    }
  }

  /// Esqueleto de la franja de instrumentos: divisiones, rótulos de campo y el
  /// núcleo circular. Los valores los pone la capa de objetivo.
  void _paintStrip(Canvas canvas, HudLayout layout) {
    final strip = layout.strip;

    canvas.drawLine(strip.topLeft, strip.topRight, _dim);

    // Divisiones entre los tres bloques.
    final blockEdge = strip.width * 0.31;
    for (final x in [strip.left + blockEdge, strip.right - blockEdge]) {
      canvas.drawLine(
        Offset(x, strip.top + strip.height * 0.15),
        Offset(x, strip.bottom - strip.height * 0.15),
        _faint,
      );
    }

    const leftLabels = ['CAM', 'DET', 'RES'];
    const rightLabels = ['INF', 'LAT', 'OBJ'];

    for (var i = 0; i < 3; i++) {
      _paintFieldLabel(canvas, layout.stripRow(right: false, index: i),
          leftLabels[i]);
      _paintFieldLabel(canvas, layout.stripRow(right: true, index: i),
          rightLabels[i]);
    }

    _paintHub(canvas, layout);
  }

  void _paintFieldLabel(Canvas canvas, Rect row, String label) {
    final painter = _text(
      label,
      hudText(
        color: theme.structureDim,
        size: theme.microSize,
        letterSpacing: theme.microSize * 0.18,
      ),
    );
    painter.paint(
      canvas,
      Offset(row.left, row.center.dy - painter.height / 2),
    );
  }

  /// Núcleo circular del centro de la franja. Es una forma, no una lectura.
  void _paintHub(Canvas canvas, HudLayout layout) {
    final center = layout.stripHub;
    final radius = layout.stripHubRadius;

    canvas.drawCircle(center, radius, _dim);
    canvas.drawCircle(center, radius * 0.42, _structure);
    canvas.drawCircle(
      center,
      radius * 0.42,
      Paint()..color = theme.structure.withValues(alpha: 0.28),
    );

    // Cuatro brazos en diagonal, separados del anillo.
    for (var i = 0; i < 4; i++) {
      final angle = i * math.pi / 2 + math.pi / 4;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * (radius * 0.62),
        center + direction * (radius * 1.5),
        _faint,
      );
    }

    final caption = _text(
      'DISPOSITIVO DE ESCANEO',
      hudText(
        color: theme.structureFaint,
        size: theme.microSize,
        letterSpacing: theme.microSize * 0.2,
      ),
    );
    caption.paint(
      canvas,
      Offset(center.dx - caption.width / 2, layout.strip.bottom - caption.height),
    );
  }

  TextPainter _text(String value, TextStyle style) => TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  bool shouldRepaint(ChromePainter oldDelegate) => oldDelegate.theme != theme;
}
