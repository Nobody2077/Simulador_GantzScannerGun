import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hud_scanner/tracking/target_tracker.dart';
import 'package:hud_scanner/tracking/tracking_state.dart';

/// Cubre la máquina de estados de REQ-3, la histéresis del lock de AC-2.6 y el
/// desacople entre inferencia y render de AC-5.3.
///
/// Va con `testWidgets` porque el tracker avanza con un Ticker: los tiempos
/// —la ventana de gracia de LOST— solo corren si se bombean frames.
void main() {
  const imageSize = Size(640, 480);
  const center = Rect.fromLTWH(290, 200, 60, 78);
  const offCenter = Rect.fromLTWH(20, 200, 60, 78);

  /// El tracker se dispone dentro del cuerpo del test: si su ticker sigue vivo
  /// al terminar, el framework lo reporta como animación colgada.
  Future<void> withTracker(
    Future<void> Function(TargetTracker tracker) body,
  ) async {
    final tracker = TargetTracker(vsync: const TestVSync());
    try {
      await body(tracker);
    } finally {
      tracker.dispose();
    }
  }

  /// Deja el tracker en LOCKED sobre [id] (AC-3.3: tres inferencias).
  void lockOnto(TargetTracker tracker, int id) {
    for (var i = 0; i < 3; i++) {
      tracker.onInference([RawTarget(id: id, faceBox: center)], imageSize);
    }
  }

  /// Avanza el reloj en pasos chicos: el tracker descarta saltos grandes, que
  /// es lo que hace al volver de segundo plano.
  Future<void> advance(WidgetTester tester, Duration total) async {
    const step = Duration(milliseconds: 50);
    for (var i = 0; i < total.inMilliseconds ~/ step.inMilliseconds; i++) {
      await tester.pump(step);
    }
  }

  testWidgets('arranca en SEARCHING', (tester) async {
    await withTracker((tracker) async {
      expect(tracker.state, TrackingState.searching);
    });
  });

  testWidgets('AC-3.2: la primera detección pasa a ACQUIRING', (tester) async {
    await withTracker((tracker) async {
      tracker.onInference([const RawTarget(id: 1, faceBox: center)], imageSize);

      expect(tracker.state, TrackingState.acquiring);
    });
  });

  testWidgets('AC-3.3: traba tras tres inferencias con el mismo id',
      (tester) async {
    await withTracker((tracker) async {
      lockOnto(tracker, 1);

      expect(tracker.state, TrackingState.locked);
      expect(tracker.lockedId, 1);
    });
  });

  testWidgets('AC-3.4: perder el id antes de trabar vuelve a SEARCHING',
      (tester) async {
    await withTracker((tracker) async {
      tracker.onInference([const RawTarget(id: 1, faceBox: center)], imageSize);
      tracker.onInference(const [], imageSize);

      expect(tracker.state, TrackingState.searching);
      expect(tracker.lockedId, isNull);
    });
  });

  testWidgets('AC-3.5: perder el objetivo trabado pasa a LOST', (tester) async {
    await withTracker((tracker) async {
      lockOnto(tracker, 1);
      await advance(tester, const Duration(milliseconds: 100));
      tracker.onInference(const [], imageSize);

      expect(tracker.state, TrackingState.lost);
      // El último reticle conocido se conserva congelado, no se descarta.
      expect(tracker.bodyBox, isNotNull);
    });
  });

  testWidgets('AC-3.6: re-adquirir dentro de la ventana vuelve a LOCKED',
      (tester) async {
    await withTracker((tracker) async {
      lockOnto(tracker, 1);
      tracker.onInference(const [], imageSize);
      await advance(tester, const Duration(milliseconds: 300));
      expect(tracker.state, TrackingState.lost);

      tracker.onInference([const RawTarget(id: 1, faceBox: center)], imageSize);

      expect(tracker.state, TrackingState.locked);
      expect(tracker.lockedId, 1);
    });
  });

  testWidgets('AC-3.7: agotada la ventana de gracia vuelve a SEARCHING',
      (tester) async {
    await withTracker((tracker) async {
      lockOnto(tracker, 1);
      tracker.onInference(const [], imageSize);
      await advance(tester, const Duration(milliseconds: 900));

      expect(tracker.state, TrackingState.searching);
      expect(tracker.lockedId, isNull);
      expect(tracker.bodyBox, isNull);
    });
  });

  testWidgets('AC-2.6: el lock no se lo roba un rostro más cercano al centro',
      (tester) async {
    await withTracker((tracker) async {
      lockOnto(tracker, 1);

      // El objetivo trabado se corre del centro y aparece otro justo en él.
      tracker.onInference(
        const [
          RawTarget(id: 1, faceBox: offCenter),
          RawTarget(id: 2, faceBox: center),
        ],
        imageSize,
      );

      expect(tracker.lockedId, 1);
      expect(tracker.state, TrackingState.locked);
    });
  });

  testWidgets('AC-2.5: sin lock previo gana el más cercano al centro',
      (tester) async {
    await withTracker((tracker) async {
      tracker.onInference(
        const [
          RawTarget(id: 7, faceBox: offCenter),
          RawTarget(id: 9, faceBox: center),
        ],
        imageSize,
      );

      expect(tracker.lockedId, 9);
    });
  });

  testWidgets('AC-5.3: el suavizado avanza con los ticks, no con la inferencia',
      (tester) async {
    await withTracker((tracker) async {
      lockOnto(tracker, 1);
      expect(tracker.bodyBox, isNull, reason: 'todavía no hubo ningún tick');

      await advance(tester, const Duration(milliseconds: 100));

      expect(tracker.bodyBox, isNotNull);
    });
  });

  testWidgets('los rostros no trabados quedan como marcas secundarias',
      (tester) async {
    await withTracker((tracker) async {
      for (var i = 0; i < 3; i++) {
        tracker.onInference(
          const [
            RawTarget(id: 1, faceBox: center),
            RawTarget(id: 2, faceBox: offCenter),
            RawTarget(id: 3, faceBox: Rect.fromLTWH(500, 90, 44, 57)),
          ],
          imageSize,
        );
      }
      await advance(tester, const Duration(milliseconds: 100));

      expect(tracker.lockedId, 1);
      // El trabado no se repite entre las marcas secundarias.
      expect(tracker.secondaryMarks.map((m) => m.id), unorderedEquals([2, 3]));
    });
  });

  testWidgets('un secundario que sale de cuadro deja de dibujarse',
      (tester) async {
    await withTracker((tracker) async {
      tracker.onInference(
        const [
          RawTarget(id: 1, faceBox: center),
          RawTarget(id: 2, faceBox: offCenter),
        ],
        imageSize,
      );
      await advance(tester, const Duration(milliseconds: 100));
      expect(tracker.secondaryMarks, hasLength(1));

      tracker.onInference(
        const [RawTarget(id: 1, faceBox: center)],
        imageSize,
      );
      await advance(tester, const Duration(milliseconds: 100));

      expect(tracker.secondaryMarks, isEmpty);
    });
  });

  testWidgets('el reticle se cierra al adquirir y el destello se apaga',
      (tester) async {
    await withTracker((tracker) async {
      tracker.onInference([const RawTarget(id: 1, faceBox: center)], imageSize);
      expect(tracker.acquireProgress, 0);

      lockOnto(tracker, 1);
      // El destello arranca lleno justo al trabar.
      expect(tracker.lockPulse, 1);

      await advance(tester, const Duration(milliseconds: 500));

      expect(tracker.acquireProgress, closeTo(1, 0.01));
      expect(tracker.lockPulse, lessThan(0.2));
    });
  });

  testWidgets('AC-4.6: marca fuera de rango con un objetivo diminuto',
      (tester) async {
    await withTracker((tracker) async {
      tracker.onInference(
        const [RawTarget(id: 1, faceBox: Rect.fromLTWH(300, 200, 12, 15))],
        imageSize,
      );

      expect(tracker.outOfRange, isTrue);
    });
  });

  testWidgets('AC-4.4: la lectura queda sin calibrar si no hay hFOV real',
      (tester) async {
    await withTracker((tracker) async {
      tracker.onInference([const RawTarget(id: 1, faceBox: center)], imageSize);
      expect(tracker.calibrated, isFalse);

      await advance(tester, const Duration(milliseconds: 100));
      expect(tracker.distanceMeters, isNotNull);
    });
  });
}
