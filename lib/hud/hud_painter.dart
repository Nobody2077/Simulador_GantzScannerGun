import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../tracking/coordinate_mapper.dart';
import '../tracking/target_tracker.dart';
import '../tracking/tracking_state.dart';
import 'hud_layout.dart';
import 'hud_theme.dart';

/// Lecturas en vivo de la franja inferior. Todas salen de mediciones reales.
@immutable
class HudReadouts {
  const HudReadouts({
    required this.camera,
    required this.detecting,
    required this.resolution,
    required this.inferenceFps,
    required this.latencyMs,
  });

  final String camera;
  final bool detecting;
  final String resolution;
  final double inferenceFps;
  final int latencyMs;

  @override
  bool operator ==(Object other) =>
      other is HudReadouts &&
      other.camera == camera &&
      other.detecting == detecting &&
      other.resolution == resolution &&
      other.inferenceFps == inferenceFps &&
      other.latencyMs == latencyMs;

  @override
  int get hashCode =>
      Object.hash(camera, detecting, resolution, inferenceFps, latencyMs);
}

/// Capa de objetivo: todo lo que cambia frame a frame.
///
/// Se repinta escuchando al [TargetTracker], que notifica a la tasa de refresco
/// de pantalla. El cromo fijo lo dibuja [ChromePainter] por debajo, y no se
/// repinta nunca (AC-5.3 y AC-6.6).
class HudPainter extends CustomPainter {
  HudPainter({
    required this.tracker,
    required this.readouts,
    required this.theme,
    required this.mirror,
    this.reduceMotion = false,
  }) : super(repaint: Listenable.merge([tracker, readouts]));

  final TargetTracker tracker;

  /// Las lecturas cambian sin reconstruir el árbol, así que se leen en cada
  /// repintado en vez de capturarse al construir el painter.
  final ValueListenable<HudReadouts> readouts;

  final HudTheme theme;
  final bool mirror;

  /// AC-6.7: con movimiento reducido el HUD aparece en su estado final, sin
  /// ocultar ninguna información.
  final bool reduceMotion;

  @override
  void paint(Canvas canvas, Size size) {
    final layout = HudLayout(size, theme);

    _paintStatusIndicator(canvas, layout);
    _paintStripValues(canvas, layout);

    final imageSize = tracker.imageSize;
    if (imageSize.isEmpty) {
      _paintIdleReticle(canvas, layout);
      _paintStateLabel(canvas, layout);
      return;
    }

    final mapper = CoordinateMapper(
      imageSize: imageSize,
      canvasSize: size,
      mirror: mirror,
    );

    // Los secundarios van primero, por debajo: la jerarquía tiene que leerse
    // aunque dos objetivos se solapen.
    for (final mark in tracker.secondaryMarks) {
      final box = _visible(mapper.mapRect(mark.bodyBox), layout);
      if (box != null) _paintSecondary(canvas, layout, box, mark.id);
    }

    final body = tracker.bodyBox;
    final box = body == null ? null : _visible(mapper.mapRect(body), layout);
    if (box != null) {
      _paintSilhouette(canvas, layout, mapper);
      _paintTarget(canvas, layout, box);
    } else {
      _paintIdleReticle(canvas, layout);
    }

    _paintStateLabel(canvas, layout);
    if (tracker.outOfRange) _paintOutOfRange(canvas, layout);
  }

  /// A distancia corta el encuadre del cuerpo desborda la pantalla por abajo.
  /// En vez de recortarlo —y quedarse con dos ganchos sueltos— se apoya en el
  /// borde del área útil: los cuatro ganchos siguen ahí y el borde comunica que
  /// el objetivo sigue más allá.
  Rect? _visible(Rect box, HudLayout layout) {
    final clipped = box.intersect(layout.stage);
    return clipped.isEmpty ? null : clipped;
  }

  Color get _targetColor => switch (tracker.state) {
        TrackingState.locked => theme.structure,
        TrackingState.acquiring => theme.structureDim,
        TrackingState.lost => theme.alert,
        TrackingState.searching => theme.structureDim,
      };

  // ── objetivo ──────────────────────────────────────────────────────────────

  void _paintTarget(Canvas canvas, HudLayout layout, Rect box) {
    // En LOST el reticle queda congelado y atenuado (AC-3.5).
    final opacity = tracker.state == TrackingState.lost ? 0.5 : 1.0;
    final color = _targetColor.withValues(alpha: opacity);

    // El reticle se cierra sobre el objetivo mientras lo adquiere. Es la
    // animación que le da peso al momento de trabar: aparecer de golpe no
    // comunica que el sistema estuvo trabajando.
    final progress = reduceMotion ? 1.0 : tracker.acquireProgress;
    final spread = (1 - progress) * box.shortestSide * 0.45;

    // Con contorno disponible, los ganchos pasan a segundo plano: encuadran,
    // pero el que describe al objetivo es el contorno.
    final hasSilhouette = tracker.silhouette?.isEmpty == false;
    _paintBrackets(
      canvas,
      box.inflate(spread),
      color,
      hasSilhouette ? theme.hairline * 1.4 : theme.strokeWidth,
    );

    if (!reduceMotion && tracker.lockPulse > 0.01) {
      _paintLockPulse(canvas, box, tracker.lockPulse);
    }
    if (tracker.state.hasTarget) _paintTargetCard(canvas, layout, box, color);
  }

  /// Contorno del objetivo, trazado sobre su forma real.
  ///
  /// Es lo que separa un recuadro de vigilancia de un sistema que está viendo
  /// al objetivo. Se dibuja dos veces: un trazo ancho y translúcido que hace de
  /// halo, y uno fino y nítido encima. Sale más barato que un desenfoque real,
  /// que en gama de entrada cuesta caro.
  void _paintSilhouette(
      Canvas canvas, HudLayout layout, CoordinateMapper mapper) {
    final silhouette = tracker.silhouette;
    if (silhouette == null || silhouette.isEmpty) return;

    final points = mapper.mapPoints(silhouette.segments);

    canvas.save();
    canvas.clipRect(layout.stage);

    canvas.drawRawPoints(
      PointMode.lines,
      points,
      Paint()
        ..strokeWidth = theme.strokeWidth * 3.2
        ..strokeCap = StrokeCap.round
        ..color = theme.structure.withValues(alpha: 0.18),
    );
    canvas.drawRawPoints(
      PointMode.lines,
      points,
      Paint()
        ..strokeWidth = theme.strokeWidth * 0.9
        ..strokeCap = StrokeCap.round
        ..color = theme.highlight.withValues(alpha: 0.9),
    );

    canvas.restore();
  }

  /// Destello de confirmación: un segundo marco ámbar que se contrae sobre el
  /// objetivo y se apaga.
  void _paintLockPulse(Canvas canvas, Rect box, double pulse) {
    _paintBrackets(
      canvas,
      box.inflate(box.shortestSide * 0.14 * pulse),
      theme.readout.withValues(alpha: pulse * 0.85),
      theme.strokeWidth * 1.3,
    );
  }

  /// Marca secundaria: presente pero claramente subordinada al objetivo
  /// trabado. Traza más fina, color atenuado y solo el identificador.
  void _paintSecondary(Canvas canvas, HudLayout layout, Rect box, int id) {
    final color = theme.structureDim.withValues(alpha: 0.55);
    _paintBrackets(canvas, box, color, theme.hairline * 1.5);

    if (id < 0) return;
    final label = _text(
      'TGT-${_pad(id)}',
      hudText(color: color, size: theme.microSize),
    );
    final gap = theme.microSize * 0.5;
    label.paint(
      canvas,
      Offset(
        box.left,
        (box.top - label.height - gap).clamp(layout.stage.top, box.top),
      ),
    );
  }

  /// Ganchos angulares en las esquinas: encuadran sin tapar al objetivo, que es
  /// de lo que se trata al apuntar.
  void _paintBrackets(
      Canvas canvas, Rect box, Color color, double strokeWidth) {
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

  /// Ficha del objetivo, unida por una línea guía diagonal en vez de pegada al
  /// blanco: deja ver al objetivo y ordena la lectura.
  void _paintTargetCard(
      Canvas canvas, HudLayout layout, Rect box, Color color) {
    final designation =
        tracker.lockedId == null ? 'TGT-··' : 'TGT-${_pad(tracker.lockedId!)}';
    final distance = tracker.distanceMeters;

    final title = _text('OBJETIVO',
        hudText(
          color: theme.structureDim,
          size: theme.microSize,
          letterSpacing: theme.microSize * 0.22,
        ));
    final id = _text(designation,
        hudText(color: color, size: theme.labelSize * 1.15));
    final distanceLabel = _text('DISTANCIA',
        hudText(
          color: theme.structureDim,
          size: theme.microSize,
          letterSpacing: theme.microSize * 0.22,
        ));
    // AC-4.5 y AC-4.7: una decimal, con "~" mientras el hFOV no esté calibrado.
    final distanceValue = _text(
      distance == null
          ? '—'
          : '${tracker.calibrated ? "" : "~"}${distance.toStringAsFixed(1)} m',
      hudText(color: theme.readout, size: theme.valueSize),
    );

    final pad = theme.inset * 0.55;
    final width = [title, id, distanceLabel, distanceValue]
            .map((t) => t.width)
            .reduce((a, b) => a > b ? a : b) +
        pad * 2;
    final height = title.height +
        id.height +
        distanceLabel.height +
        distanceValue.height +
        pad * 2.6;

    // Arriba y a la derecha del objetivo, traída dentro del área útil.
    final anchor = Offset(
      box.right + theme.inset * 2.2,
      box.top - height - theme.inset,
    );
    final origin = Offset(
      anchor.dx.clamp(layout.stage.left, layout.stage.right - width),
      anchor.dy.clamp(layout.stage.top, layout.stage.bottom - height),
    );
    final card = Rect.fromLTWH(origin.dx, origin.dy, width, height);

    // Línea guía desde la esquina del objetivo hasta la ficha.
    canvas.drawLine(
      box.topRight,
      Offset(card.left, card.bottom),
      Paint()
        ..strokeWidth = theme.hairline
        ..color = color.withValues(alpha: 0.7),
    );

    canvas.drawRect(card, Paint()..color = theme.panelFill);
    canvas.drawRect(
      card,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = theme.hairline
        ..color = theme.structureDim,
    );
    // Filete de acento en el canto izquierdo.
    canvas.drawRect(
      Rect.fromLTWH(card.left, card.top, theme.hairline * 2.5, card.height),
      Paint()..color = color,
    );

    var y = card.top + pad;
    title.paint(canvas, Offset(card.left + pad, y));
    y += title.height + pad * 0.2;
    id.paint(canvas, Offset(card.left + pad, y));
    y += id.height + pad * 0.6;
    distanceLabel.paint(canvas, Offset(card.left + pad, y));
    y += distanceLabel.height + pad * 0.1;
    distanceValue.paint(canvas, Offset(card.left + pad, y));
  }

  /// Reticle de reposo: una forma abierta en el centro mientras no hay nada
  /// trabado, para que la pantalla nunca quede muerta.
  void _paintIdleReticle(Canvas canvas, HudLayout layout) {
    final stage = layout.stage;
    final center = stage.center;
    final halfWidth = stage.width * 0.14;
    final halfHeight = stage.height * 0.13;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = theme.strokeWidth
      ..color = theme.structureDim;

    // Trapecio abierto: las dos mitades no se cierran arriba ni abajo.
    for (final side in const [-1.0, 1.0]) {
      final path = Path()
        ..moveTo(center.dx + side * halfWidth * 0.35, center.dy - halfHeight)
        ..lineTo(center.dx + side * halfWidth, center.dy - halfHeight)
        ..lineTo(center.dx + side * halfWidth * 0.72, center.dy)
        ..lineTo(center.dx + side * halfWidth, center.dy + halfHeight)
        ..lineTo(center.dx + side * halfWidth * 0.35, center.dy + halfHeight);
      canvas.drawPath(path, paint);
    }
  }

  /// Estado del sistema, centrado al pie del área útil.
  ///
  /// Está en un solo lugar —no repartido entre el reticle de reposo y la
  /// franja— para que el ojo sepa siempre dónde mirarlo.
  void _paintStateLabel(Canvas canvas, HudLayout layout) {
    final locked = tracker.state == TrackingState.locked;
    final label = _text(
      tracker.state.label,
      hudText(
        color: locked ? theme.readout : theme.structureDim,
        size: theme.labelSize,
        letterSpacing: theme.labelSize * 0.24,
      ),
    );
    label.paint(
      canvas,
      Offset(
        layout.stage.center.dx - label.width / 2,
        layout.stage.bottom - label.height,
      ),
    );
  }

  /// Aviso de fuera de rango: ámbar, centrado y grande, como en la referencia.
  void _paintOutOfRange(Canvas canvas, HudLayout layout) {
    final stage = layout.stage;
    final text = _text(
      'FUERA DE RANGO',
      hudText(
        color: theme.alert,
        size: theme.alertSize,
        letterSpacing: theme.alertSize * 0.06,
      ),
    );

    final y = stage.center.dy + stage.height * 0.18;
    final x = stage.center.dx - text.width / 2;

    canvas.drawLine(
      Offset(x, y - theme.inset * 0.5),
      Offset(x + text.width, y - theme.inset * 0.5),
      Paint()
        ..strokeWidth = theme.strokeWidth * 1.6
        ..color = theme.structure,
    );
    text.paint(canvas, Offset(x, y));
  }

  /// Punto de sistema activo, apoyado en el extremo derecho de la regla
  /// superior. Va integrado en la composición y no flotando en la esquina, y
  /// dice algo real: se apaga cuando el pipeline se detiene.
  void _paintStatusIndicator(Canvas canvas, HudLayout layout) {
    final radius = theme.statusDotSize / 2;
    final center = Offset(
      layout.frame.right - layout.cornerArm - theme.inset - radius,
      layout.frame.top + theme.labelSize / 2,
    );
    final color = readouts.value.detecting ? theme.structure : theme.structureDim;

    if (readouts.value.detecting) {
      canvas.drawCircle(
        center,
        radius * 2.4,
        Paint()..color = color.withValues(alpha: 0.18),
      );
    }
    canvas.drawCircle(center, radius, Paint()..color = color);
  }

  // ── franja inferior ───────────────────────────────────────────────────────

  void _paintStripValues(Canvas canvas, HudLayout layout) {
    final left = [
      readouts.value.camera.toUpperCase(),
      readouts.value.detecting ? 'ACTIVO' : 'PAUSA',
      readouts.value.resolution,
    ];
    final right = [
      '${readouts.value.inferenceFps.toStringAsFixed(1)} FPS',
      '${readouts.value.latencyMs} MS',
      tracker.lockedId == null ? '—' : 'TGT-${_pad(tracker.lockedId!)}',
    ];

    for (var i = 0; i < 3; i++) {
      _paintValue(canvas, layout.stripRow(right: false, index: i), left[i]);
      _paintValue(canvas, layout.stripRow(right: true, index: i), right[i]);
    }
  }

  /// El valor arranca justo después de la columna de rótulos, no pegado al
  /// borde opuesto: un rótulo y su valor separados media pantalla dejan de
  /// leerse como un par.
  void _paintValue(Canvas canvas, Rect row, String value) {
    final painter = _text(
      value,
      hudText(color: theme.readout, size: theme.labelSize),
    );
    painter.paint(
      canvas,
      Offset(
        row.left + theme.microSize * 5.2,
        row.center.dy - painter.height / 2,
      ),
    );
  }

  // ── utilidades ────────────────────────────────────────────────────────────

  String _pad(int id) => (id % 100).toString().padLeft(2, '0');

  TextPainter _text(String value, TextStyle style) => TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  bool shouldRepaint(HudPainter oldDelegate) =>
      oldDelegate.theme != theme ||
      oldDelegate.mirror != mirror ||
      oldDelegate.reduceMotion != reduceMotion ||
      oldDelegate.readouts != readouts;
}
