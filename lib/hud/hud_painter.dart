import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../tracking/coordinate_mapper.dart';
import '../tracking/target_tracker.dart';
import '../tracking/tracking_state.dart';
import 'hud_layout.dart';
import 'hud_theme.dart';
import 'target_layer.dart';

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

    // Los objetivos ya vienen del tracker en orden de cercanía.
    final visible = <TargetReadout>[];
    for (final mark in tracker.orderedMarks) {
      final box = _visible(mapper.mapRect(mark.bodyBox), layout);
      if (box == null) continue;
      visible.add(TargetReadout(
        id: mark.id < 0 ? null : mark.id,
        bodyBox: box,
        distanceMeters: mark.distanceMeters,
        locked: mark.locked,
        calibrated: tracker.calibrated,
        vitality: mark.vitality,
      ));
    }

    final labelled = _labelled(visible, labelledTargetLimit(size));

    // Los secundarios van primero, por debajo: la jerarquía tiene que leerse
    // aunque dos objetivos se solapen.
    for (final readout in visible) {
      if (readout.locked) continue;
      _paintSecondary(canvas, layout, readout, labelled.contains(readout.id));
    }

    final locked = visible.where((r) => r.locked).firstOrNull;
    if (locked != null) {
      _paintSilhouette(canvas, layout, mapper);
      _paintTarget(canvas, locked.bodyBox);
    } else {
      _paintIdleReticle(canvas, layout);
    }

    paintRoster(canvas, layout, theme, visible);
    _paintCards(canvas, layout, visible, labelled);

    _paintStateLabel(canvas, layout);
    if (tracker.outOfRange) _paintOutOfRange(canvas, layout);
  }

  /// Qué objetivos llevan ficha de distancia.
  ///
  /// El trabado siempre; el resto de los cupos se reparte por cercanía, que es
  /// el mismo orden de la columna. El tope lo fija el formato de pantalla
  /// (AC-6.8): los que quedan afuera conservan ganchos y barra, sin ficha.
  Set<int?> _labelled(List<TargetReadout> visible, int limit) {
    final locked = visible.where((r) => r.locked).toList();
    return {
      ...locked.map((r) => r.id),
      ...visible
          .where((r) => !r.locked)
          .take(limit - locked.length)
          .map((r) => r.id),
    };
  }

  /// Las fichas se dibujan en una pasada aparte, por encima de todo.
  ///
  /// La del trabado se coloca primero: es la que tiene derecho a su lugar, y
  /// las demás se corren para no pisarla. También se las mantiene fuera de la
  /// columna de sujetos.
  void _paintCards(
    Canvas canvas,
    HudLayout layout,
    List<TargetReadout> visible,
    Set<int?> labelled,
  ) {
    final bounds = Rect.fromLTRB(
      layout.stage.left + rosterWidth(layout, theme) + theme.inset,
      layout.stage.top,
      layout.stage.right,
      layout.stage.bottom,
    );
    final lockedColor = _targetColor.withValues(
      alpha: tracker.state == TrackingState.lost ? 0.5 : 1.0,
    );

    final occupied = <Rect>[];
    for (final readout in [
      ...visible.where((r) => r.locked),
      ...visible.where((r) => !r.locked),
    ]) {
      if (!labelled.contains(readout.id)) continue;
      // Durante ACQUIRING el objetivo todavía no tiene ficha: el reticle
      // cerrándose ya dice que el sistema está trabajando.
      if (readout.locked && !tracker.state.hasTarget) continue;

      occupied.add(paintTargetCard(
        canvas,
        theme,
        readout,
        bounds: bounds,
        color: readout.locked ? lockedColor : theme.structureDim,
        compact: !readout.locked,
        avoid: occupied,
      ));
    }
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

  void _paintTarget(Canvas canvas, Rect box) {
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
    paintBrackets(
      canvas,
      box.inflate(spread),
      color,
      hasSilhouette ? theme.hairline * 1.4 : theme.strokeWidth,
    );

    if (!reduceMotion && tracker.lockPulse > 0.01) {
      _paintLockPulse(canvas, box, tracker.lockPulse);
    }
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
    paintBrackets(
      canvas,
      box.inflate(box.shortestSide * 0.14 * pulse),
      theme.readout.withValues(alpha: pulse * 0.85),
      theme.strokeWidth * 1.3,
    );
  }

  /// Marca secundaria: presente pero claramente subordinada al objetivo
  /// trabado. Traza más fina y color atenuado.
  ///
  /// El identificador se dibuja solo cuando el objetivo **no** lleva ficha: con
  /// ficha, la designación ya está ahí y repetirla sobre el gancho la duplica.
  void _paintSecondary(
    Canvas canvas,
    HudLayout layout,
    TargetReadout readout,
    bool hasCard,
  ) {
    final box = readout.bodyBox;
    final color = theme.structureDim.withValues(alpha: 0.55);
    paintBrackets(canvas, box, color, theme.hairline * 1.5);

    if (hasCard || readout.id == null) return;
    final label = _text(
      readout.designation,
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
      tracker.lockedId == null ? '—' : targetDesignation(tracker.lockedId),
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
