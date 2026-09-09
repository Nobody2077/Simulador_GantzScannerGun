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
  const TargetMark({
    required this.id,
    required this.bodyBox,
    this.distanceMeters,
    this.locked = false,
    this.vitality = 1,
  });

  /// Negativo cuando ML Kit no asignó un trackingId.
  final int id;
  final Rect bodyBox;

  /// Distancia estimada y suavizada, o `null` mientras la caja sea demasiado
  /// chica para que la cuenta signifique algo.
  final double? distanceMeters;

  /// El objetivo principal. Sigue habiendo uno solo.
  final bool locked;

  /// Barra del sujeto, de 0 a 1. Hoy siempre llena.
  final double vitality;
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
    this.markGrace = const Duration(milliseconds: 400),
    this.orderBandMeters = 0.35,
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

  /// Cuánto se sostiene una marca después de perderla de vista.
  ///
  /// ML Kit deja caer un rostro por un cuadro suelto cada tanto. Sin esta
  /// ventana, la columna de sujetos y sus ganchos titilan al ritmo de esos
  /// fallos. Es la misma idea de la ventana de gracia de `LOST` (AC-3.5), más
  /// corta porque acá no hay nada que re-adquirir: solo se evita el parpadeo.
  final Duration markGrace;

  /// Banda muerta del orden de la columna de sujetos, en metros.
  ///
  /// Dos personas a distancias parecidas se intercambiaban de puesto a la tasa
  /// de inferencia. Por debajo de esta diferencia el orden no cambia. Es la
  /// misma idea de AC-5.4, aplicada al orden en vez de a la posición.
  final double orderBandMeters;
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

  /// Distancia por objetivo, no solo la del trabado: es lo que ordena la
  /// columna de sujetos.
  final Map<int, double> _measuredDistance = {};
  final Map<int, double> _smoothedDistance = {};

  /// Segundos que lleva sin verse cada marca que dejó de reportarse.
  final Map<int, double> _missingSeconds = {};

  /// Orden de la columna, sostenido entre inferencias. Es lo que permite la
  /// banda muerta: sin memoria del orden anterior no hay histéresis posible.
  final List<int> _order = [];

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

  /// Distancia del objetivo trabado, que es la que va en la franja inferior.
  double? get distanceMeters {
    final key = _lockedKey;
    return key == null ? null : _smoothedDistance[key];
  }

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

  /// Todos los objetivos en cuadro, del más cercano al más lejano.
  ///
  /// El orden lo sostiene [_order] con banda muerta, así que dos sujetos a
  /// distancias parecidas no se intercambian de puesto en cada inferencia.
  ///
  /// Un id puede estar en el orden antes de tener caja suavizada —el suavizado
  /// engancha en el tick siguiente a la inferencia—; esas marcas se saltean y
  /// aparecen un cuadro después, que no se ve.
  List<TargetMark> get orderedMarks => [
        for (final id in _order)
          if (_smoothed[id] case final face?)
            TargetMark(
              id: id,
              bodyBox: BodyGeometry.fromFace(face),
              distanceMeters: _smoothedDistance[id],
              locked: id == _lockedKey,
            ),
      ];

  /// Los demás rostros en cuadro, para dibujarlos como marcas secundarias.
  List<TargetMark> get secondaryMarks =>
      orderedMarks.where((mark) => !mark.locked).toList();

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

    // La distancia se estima para todos los objetivos en cuadro, no solo para
    // el trabado: es lo que ordena la columna de sujetos. Cuesta una división
    // por rostro, así que el gasto es despreciable frente a la inferencia.
    _measuredDistance.clear();
    for (final candidate in targets) {
      final estimate = estimator.estimate(
        faceWidthPx: candidate.faceBox.width,
        imageWidthPx: imageSize.width,
        hFovDegrees: hFovDegrees,
      );
      if (estimate != null) {
        _measuredDistance[candidate.id ?? _anonymousId] = estimate;
      }
    }

    final target = _select(targets, imageSize);
    if (target == null) {
      _onTargetMissing();
      _touch();
      _reorder();
      _ensureTicking();
      return;
    }

    // AC-4.6: fuera de rango por distancia o porque el objetivo es ya demasiado
    // chico para que la estimación signifique algo.
    final distance = _measuredDistance[target.id ?? _anonymousId];
    _outOfRange = (distance != null && distance > config.maxRangeMeters) ||
        target.faceBox.width < config.minFaceWidthPx;

    _advanceState(target);
    _lostSeconds = 0;
    _touch();
    _reorder();
    _ensureTicking();
  }

  /// Anota qué marcas siguen en cuadro y cuáles empezaron a faltar.
  ///
  /// No borra nada: la marca que dejó de reportarse se sostiene su ventana de
  /// gracia y la retira [_expireMissing] desde el tick.
  void _touch() {
    for (final id in _measured.keys) {
      _missingSeconds.remove(id);
    }
    for (final id in _smoothed.keys) {
      if (!_measured.containsKey(id)) _missingSeconds.putIfAbsent(id, () => 0);
    }
  }

  /// Retira las marcas que agotaron su ventana de gracia.
  ///
  /// El objetivo trabado sobrevive: tiene la suya, más larga, y es lo que deja
  /// el reticle congelado durante LOST (AC-3.5).
  bool _expireMissing(double dt) {
    if (_missingSeconds.isEmpty) return false;

    final grace = config.markGrace.inMilliseconds / 1000;
    var changed = false;
    for (final id in _missingSeconds.keys.toList()) {
      final elapsed = _missingSeconds[id]! + dt;
      if (elapsed >= grace && id != _lockedKey) {
        _missingSeconds.remove(id);
        _smoothed.remove(id);
        _measuredDistance.remove(id);
        _smoothedDistance.remove(id);
        _order.remove(id);
        changed = true;
      } else {
        _missingSeconds[id] = elapsed;
      }
    }
    return changed;
  }

  /// Reordena la columna: el más cercano arriba, el más lejano abajo.
  ///
  /// Parte del orden anterior y solo intercambia vecinos cuando la diferencia
  /// de distancia supera [TrackingConfig.orderBandMeters]. Ordenar de cero en
  /// cada inferencia hacía saltar de puesto a dos personas paradas a la misma
  /// distancia. Los objetivos sin distancia estimada quedan al final: no se
  /// sabe dónde ponerlos, y adivinar los haría saltar igual.
  void _reorder() {
    final present = {..._smoothed.keys, ..._measured.keys};
    _order
      ..removeWhere((id) => !present.contains(id))
      ..addAll(present.where((id) => !_order.contains(id)));

    double? distanceOf(int id) => _smoothedDistance[id] ?? _measuredDistance[id];

    // Burbuja con banda: converge en pocas pasadas porque el orden ya viene
    // casi resuelto de la inferencia anterior.
    for (var pass = 0; pass < _order.length; pass++) {
      var swapped = false;
      for (var i = 0; i + 1 < _order.length; i++) {
        final a = distanceOf(_order[i]);
        final b = distanceOf(_order[i + 1]);
        final shouldSwap = a == null
            ? b != null
            : b != null && a > b + config.orderBandMeters;
        if (shouldSwap) {
          final held = _order[i];
          _order[i] = _order[i + 1];
          _order[i + 1] = held;
          swapped = true;
        }
      }
      if (!swapped) break;
    }
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

    final moved =
        _advanceSmoothing(dt) | _advanceAnimations(dt) | _expireMissing(dt);
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

    // AC-5.6: cada objetivo lleva su propio suavizado de distancia, con una
    // constante de tiempo mayor que la de la caja para que el número no
    // parpadee entre valores.
    final kd = 1 - math.exp(-dt / config.distanceTimeConstant);
    for (final entry in _measuredDistance.entries) {
      final current = _smoothedDistance[entry.key];
      if (current == null) {
        _smoothedDistance[entry.key] = entry.value;
        moved = true;
        continue;
      }
      final next = current + (entry.value - current) * kd;
      if ((next - current).abs() > 0.001) {
        _smoothedDistance[entry.key] = next;
        moved = true;
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
    _measuredDistance.clear();
    _smoothedDistance.clear();
    _missingSeconds.clear();
    _order.clear();
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
