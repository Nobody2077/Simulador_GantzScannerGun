import 'package:flutter_test/flutter_test.dart';
import 'package:hud_scanner/audio/hud_cue.dart';
import 'package:hud_scanner/tracking/tracking_state.dart';

void main() {
  HudCueEvent cue({
    required TrackingState previous,
    required TrackingState current,
    int previousStep = 0,
    int step = 0,
  }) =>
      resolveCue(
        previous: previous,
        current: current,
        previousStep: previousStep,
        step: step,
      );

  group('adquisición', () {
    test('AC-7.2: cada inferencia confirmada sube un tono', () {
      expect(
        cue(
          previous: TrackingState.searching,
          current: TrackingState.acquiring,
          step: 1,
        ).tone,
        HudCue.scan1,
      );
      expect(
        cue(
          previous: TrackingState.acquiring,
          current: TrackingState.acquiring,
          previousStep: 1,
          step: 2,
        ).tone,
        HudCue.scan2,
      );
      expect(
        cue(
          previous: TrackingState.acquiring,
          current: TrackingState.acquiring,
          previousStep: 2,
          step: 3,
        ).tone,
        HudCue.scan3,
      );
    });

    test('sin avance de paso no se repite el pulso', () {
      // El tracker notifica a 60 fps; sin este corte sonaría cada cuadro.
      expect(
        cue(
          previous: TrackingState.acquiring,
          current: TrackingState.acquiring,
          previousStep: 2,
          step: 2,
        ),
        HudCueEvent.none,
      );
    });
  });

  group('confirmación y pérdida', () {
    test('AC-7.1: trabar suena y vibra', () {
      final event = cue(
        previous: TrackingState.acquiring,
        current: TrackingState.locked,
      );

      expect(event.tone, HudCue.lock);
      expect(event.haptic, isTrue);
    });

    test('AC-7.3: perder la señal suena sin háptica', () {
      final event = cue(
        previous: TrackingState.locked,
        current: TrackingState.lost,
      );

      expect(event.tone, HudCue.lost);
      expect(event.haptic, isFalse);
    });

    test('AC-3.6: reenganchar no repite la confirmación', () {
      final event = cue(
        previous: TrackingState.lost,
        current: TrackingState.locked,
      );

      expect(event.tone, HudCue.scan3,
          reason: 'un pulso de reenganche, no la confirmación completa');
      expect(event.haptic, isFalse);
    });
  });

  group('silencios', () {
    test('permanecer en el mismo estado no emite nada', () {
      for (final state in TrackingState.values) {
        expect(cue(previous: state, current: state), HudCueEvent.none,
            reason: 'estado $state');
      }
    });

    test('volver a buscar es silencioso', () {
      // Que se agote la ventana de gracia ya se anunció al entrar en LOST.
      expect(
        cue(previous: TrackingState.lost, current: TrackingState.searching),
        HudCueEvent.none,
      );
      expect(
        cue(previous: TrackingState.acquiring, current: TrackingState.searching),
        HudCueEvent.none,
      );
    });
  });

  test('cada señal tiene su asset y no se repiten', () {
    final assets = HudCue.values.map((c) => c.asset).toList();

    expect(assets.toSet(), hasLength(assets.length));
    for (final asset in assets) {
      expect(asset, isNotEmpty);
    }
  });
}
