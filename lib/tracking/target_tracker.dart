import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'body_geometry.dart';
import 'distance_estimator.dart';
import 'silhouette.dart';
import 'tracking_state.dart';

/// Medición cruda de una inferencia, en coordenadas de imagen.
@immutable
class RawTarget {
  const RawTarget({required this.id, required this.faceBox});

  final int? id;
  final Rect faceBox;
}

/// Objetivo listo para dibujar, con el encuadre del cuerpo ya suavizado.
@immutable
class TargetMark {
  const TargetMark({required this.id, required this.bodyBox});

  /// Negativo cuando ML Kit no asignó un trackingId.
  final int id;
  final Rect bodyBox;
}

/// Umbrales de tracking y suavizado, expuestos como configuración y no como
/// literales dispersos por la lógica (AC-3.9 y AC-5.2).
@immutable
class TrackingConfig {
  const TrackingConfig({
    this.inferencesToLock = 3,
    this.lostTimeout = const Duration(milliseconds: 800),
    this.boxTimeConstant = 0.07,
    this.distanceTimeConstant = 0.32,
    this.acquireTimeConstant = 0.09,
    this.lockPulseTimeConstant = 0.22,
    this.deadBandPx = 2,
    this.maxRangeMeters = 8,
    this.minFaceWidthPx = 18,
  });

  /// AC-3.3: inferencias consecutivas con el mismo id para pasar a LOCKED.
  final int inferencesToLock;

  /// AC-3.6 y AC-3.7: ventana de gracia para re-adquirir antes de volver a
  /// SEARCHING.
  final Duration lostTimeout;

  /// Constante de tiempo del suavizado de la caja, en segundos.
  ///
  /// Se usa constante de tiempo y no un alfa fijo para que el suavizado no
  /// dependa de la tasa de refresco: a 60 y a 120 Hz se siente igual.
  /// Con 0,07 s el reticle alcanza al objetivo en ~250 ms (AC-5.5).
  final double boxTimeConstant;

  /// AC-5.6: mayor que la de la caja, para que el número no parpadee.
  final double distanceTimeConstant;

  /// Cuánto tarda el reticle en cerrarse sobre el objetivo al adquirirlo.
  final double acquireTimeConstant;

  /// Cuánto dura el destello de confirmación al trabar.
  final double lockPulseTimeConstant;

  /// AC-5.4: por debajo de esto no se mueve nada, contra la micro-vibración.
  final double deadBandPx;

  /// AC-4.6: umbrales del indicador OUT_OF_RANGE.
  ///
  /// Los dos tienen que decir aproximadamente lo mismo. A 1280 px de ancho, un
  /// rostro de 18 px cae justo alrededor de los 8 m: con un piso más alto el
  /// aviso saltaba a los 3,5 m y contradecía al límite de distancia.
  final double maxRangeMeters;
  final double minFaceWidthPx;
}

/// Clave interna para los objetivos sin `trackingId`.
///
/// ML Kit los numera desde cero, así que un negativo no colisiona nunca.
const int _anonymousId = -1;

/// Sostiene los objetivos en cuadro: máquina de estados (REQ-3), suavizado
/// (REQ-5) y distancia estimada (REQ-4).
///
/// Sigue habiendo **un solo objetivo trabado** — la máquina de estados no
/// cambia. Lo que se agrega es que los demás rostros en cuadro se conservan
/// suavizados para poder dibujarlos como marcas secundarias, con la jerarquía
/// que se ve en la referencia.
///
/// Se notifica a sí mismo a la tasa de refresco de pantalla, no a la de
/// inferencia (AC-5.3). El painter lo escucha como `repaint`, así que el HUD se
/// redibuja sin reconstruir el árbol de widgets (AC-6.6).
class TargetTracker extends ChangeNotifier {
  TargetTracker({
    required TickerProvider vsync,
    this.config = const TrackingConfig(),
    this.estimator = const DistanceEstimator(),
  }) {
    // El ticker arranca recién cuando hay algo que animar y se detiene solo al
    // quedarse sin objetivo: sostener 60 repintados por segundo frente a una
    // pared vacía no le sirve a nadie y calienta el dispositivo.
    _ticker = vsync.createTicker(_onTick);
  }

  final TrackingConfig config;
  final DistanceEstimator estimator;

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  TrackingState _state = TrackingState.searching;
  int? _lockedKey;
  int _consecutive = 0;
  double _lostSeconds = 0;

  /// Mediciones de la última inferencia y sus versiones suavizadas, por id.
  final Map<int, Rect> _measured = {};
  final Map<int, Rect> _smoothed = {};

  double? _measuredDistance;
  double? _smoothedDistance;

  Size _imageSize = Size.zero;
  bool _outOfRange = false;
  bool _calibrated = false;
  DateTime? _lockedAt;

  double _acquireProgress = 0;
  double _lockPulse = 0;
  Silhouette? _silhouette;

  TrackingState get state => _state;
  Size get imageSize => _imageSize;

  /// `null` cuando no hay objetivo o cuando ML Kit no le asignó id.
  int? get lockedId {
    final key = _lockedKey;
    return key == null || key == _anonymousId ? null : key;
  }

  /// AC-3.8: derivado de la distancia, independiente del estado de tracking.
  bool get outOfRange => _outOfRange;

  /// AC-4.4: `false` mientras el hFOV real no esté disponible.
  bool get calibrated => _calibrated;

  double? get distanceMeters => _smoothedDistance;

  /// Avance del cierre del reticle sobre el objetivo, de 0 a 1.
  double get acquireProgress => _acquireProgress;

  /// Inferencias consecutivas acumuladas hacia el lock (AC-3.3).
  ///
  /// Lo consume el audio para marcar cada paso de la adquisición con su propio
  /// pulso.
  int get acquireStep => _consecutive;

  /// Destello de confirmación al trabar, de 1 a 0.
  double get lockPulse => _lockPulse;

  /// Contorno del objetivo trabado, cuando la segmentación está disponible.
  ///
  /// No se suaviza: es una medición por cuadro y el temblor propio del contorno
  /// se lee como barrido en vivo, no como error.
  Silhouette? get silhouette => _silhouette;

  /// Entrega el contorno de la inferencia de segmentación.
  ///
  /// Llega por separado del rostro porque la segmentación corre solo con el
  /// objetivo trabado, no en cada cuadro.
  void onSilhouette(Silhouette? silhouette) {
    if (_state != TrackingState.locked) return;
    _silhouette = silhouette;
    notifyListeners();
  }

  /// Encuadre del cuerpo del objetivo trabado, ya suavizado.
  Rect? get bodyBox {
    final key = _lockedKey;
    if (key == null) return null;
    final face = _smoothed[key];
    return face == null ? null : BodyGeometry.fromFace(face);
  }

  /// Los demás rostros en cuadro, para dibujarlos como marcas secundarias.
  List<TargetMark> get secondaryMarks => [
        for (final entry in _smoothed.entries)
          if (entry.key != _lockedKey)
            TargetMark(
              id: entry.key,
              bodyBox: BodyGeometry.fromFace(entry.value),
            ),
      ];

  /// Segundos que lleva sostenido el objetivo actual.
  int get lockedForSeconds => _lockedAt == null
      ? 0
      : DateTime.now().difference(_lockedAt!).inSeconds;

  /// Alimenta el tracker con el resultado de una inferencia.
  void onInference(
    List<RawTarget> targets,
    Size imageSize, {
    double? hFovDegrees,
  }) {
    _imageSize = imageSize;
    _calibrated = hFovDegrees != null;

    _measured
      ..clear()
      ..addEntries(
        targets.map((t) => MapEntry(t.id ?? _anonymousId, t.faceBox)),
      );

    final target = _select(targets, imageSize);
    if (target == null) {
      _onTargetMissing();
      _prune();
      return;
    }

    _measuredDistance = estimator.estimate(
      faceWidthPx: target.faceBox.width,
      imageWidthPx: imageSize.width,
      hFovDegrees: hFovDegrees,
    );

    // AC-4.6: fuera de rango por distancia o porque el objetivo es ya demasiado
    // chico para que la estimación signifique algo.
    final distance = _measuredDistance;
    _outOfRange = (distance != null && distance > config.maxRangeMeters) ||
        target.faceBox.width < config.minFaceWidthPx;

    _advanceState(target);
    _lostSeconds = 0;
    _prune();
    _ensureTicking();
  }

  /// Descarta los suavizados de objetivos que ya no están en cuadro.
  ///
  /// El objetivo trabado sobrevive a la poda: es lo que deja el reticle
  /// congelado durante LOST (AC-3.5).
  void _prune() {
    _smoothed.removeWhere(
      (id, _) => !_measured.containsKey(id) && id != _lockedKey,
    );
  }

  void _ensureTicking() {
    if (_ticker.isActive) return;
    _lastTick = Duration.zero;
    _ticker.start();
  }

  /// AC-2.5 y AC-2.6: sin lock previo gana el más cercano al centro; con lock,
  /// se conserva mientras ese id siga en cuadro.
  RawTarget? _select(List<RawTarget> targets, Size imageSize) {
    if (targets.isEmpty) return null;

    final locked = _lockedKey;
    if (locked != null) {
      for (final target in targets) {
        if ((target.id ?? _anonymousId) == locked) return target;
      }
    }

    final center = Offset(imageSize.width / 2, imageSize.height / 2);
    var nearest = targets.first;
    var nearestDistance = double.infinity;
    for (final target in targets) {
      final distance = (target.faceBox.center - center).distanceSquared;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = target;
      }
    }
    return nearest;
  }

  void _advanceState(RawTarget target) {
    final key = target.id ?? _anonymousId;

    switch (_state) {
      case TrackingState.searching:
        // AC-3.2
        _lockedKey = key;
        _consecutive = 1;
        _state = TrackingState.acquiring;

      case TrackingState.acquiring:
        if (key == _lockedKey) {
          _consecutive++;
          if (_consecutive >= config.inferencesToLock) {
            // AC-3.3
            _state = TrackingState.locked;
            _lockedAt = DateTime.now();
            _lockPulse = 1;
          }
        } else {
          _lockedKey = key;
          _consecutive = 1;
        }

      case TrackingState.locked:
        break; // Ya trabado: no hay nada que decidir.

      case TrackingState.lost:
        if (key == _lockedKey) {
          // AC-3.6: vuelve a LOCKED sin repetir la animación de adquisición.
          _state = TrackingState.locked;
        } else {
          _lockedKey = key;
          _consecutive = 1;
          _state = TrackingState.acquiring;
          _lockedAt = null;
          _acquireProgress = 0;
          _silhouette = null;
        }
    }
  }

  void _onTargetMissing() {
    switch (_state) {
      case TrackingState.acquiring:
        _reset(); // AC-3.4
      case TrackingState.locked:
        // AC-3.5: se conserva el último reticle conocido, congelado.
        _state = TrackingState.lost;
        _lostSeconds = 0;
        // El contorno sí se descarta: es una medición del cuadro anterior y
        // congelarlo dibujaría al objetivo donde ya no está. Los ganchos
        // vuelven a tomar su lugar.
        _silhouette = null;
      case TrackingState.lost:
      case TrackingState.searching:
        break;
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0 || dt > 0.5) return; // Descarta saltos tras una pausa.

    final previousState = _state;

    if (_state == TrackingState.lost) {
      _lostSeconds += dt;
      if (_lostSeconds >= config.lostTimeout.inMilliseconds / 1000) {
        _reset(); // AC-3.7
      }
    }

    final moved = _advanceSmoothing(dt) | _advanceAnimations(dt);
    if (moved || _state != previousState) notifyListeners();

    // Sin objetivo ni reticle que sostener, no hay nada que animar.
    if (_state == TrackingState.searching && _smoothed.isEmpty) {
      _ticker.stop();
    }
  }

  bool _advanceSmoothing(double dt) {
    var moved = false;
    final k = 1 - math.exp(-dt / config.boxTimeConstant);

    for (final entry in _measured.entries) {
      final current = _smoothed[entry.key];
      if (current == null) {
        // Primer enganche: sin arrastre desde el centro de la pantalla.
        _smoothed[entry.key] = entry.value;
        moved = true;
        continue;
      }
      final measured = entry.value;
      final next = Rect.fromLTRB(
        _approach(current.left, measured.left, k),
        _approach(current.top, measured.top, k),
        _approach(current.right, measured.right, k),
        _approach(current.bottom, measured.bottom, k),
      );
      if (next != current) {
        _smoothed[entry.key] = next;
        moved = true;
      }
    }

    final measuredDistance = _measuredDistance;
    if (measuredDistance != null) {
      final current = _smoothedDistance;
      if (current == null) {
        _smoothedDistance = measuredDistance;
        moved = true;
      } else {
        final kd = 1 - math.exp(-dt / config.distanceTimeConstant);
        final next = current + (measuredDistance - current) * kd;
        if ((next - current).abs() > 0.001) {
          _smoothedDistance = next;
          moved = true;
        }
      }
    }

    return moved;
  }

  /// Cierre del reticle y destello de confirmación.
  bool _advanceAnimations(double dt) {
    var moved = false;

    // El reticle se cierra al adquirir y queda cerrado mientras esté trabado.
    final goal = _state == TrackingState.searching ? 0.0 : 1.0;
    if ((_acquireProgress - goal).abs() > 0.002) {
      final k = 1 - math.exp(-dt / config.acquireTimeConstant);
      _acquireProgress += (goal - _acquireProgress) * k;
      moved = true;
    } else if (_acquireProgress != goal) {
      _acquireProgress = goal;
      moved = true;
    }

    if (_lockPulse > 0.002) {
      _lockPulse *= math.exp(-dt / config.lockPulseTimeConstant);
      moved = true;
    } else if (_lockPulse != 0) {
      _lockPulse = 0;
      moved = true;
    }

    return moved;
  }

  /// Acerca [current] a [target], salvo dentro de la banda muerta.
  double _approach(double current, double target, double k) {
    final delta = target - current;
    if (delta.abs() < config.deadBandPx) return current;
    return current + delta * k;
  }

  void _reset() {
    _state = TrackingState.searching;
    _lockedKey = null;
    _lockedAt = null;
    _consecutive = 0;
    _lostSeconds = 0;
    _smoothed.clear();
    _measured.clear();
    _measuredDistance = null;
    _smoothedDistance = null;
    _outOfRange = false;
    _acquireProgress = 0;
    _silhouette = null;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}
