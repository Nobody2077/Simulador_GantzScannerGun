import 'package:flutter/foundation.dart';

import '../tracking/tracking_state.dart';

/// Señales sonoras del HUD y el asset que las produce.
enum HudCue {
  scan1('scan_1'),
  scan2('scan_2'),
  scan3('scan_3'),
  lock('lock'),
  lost('lost');

  const HudCue(this.asset);

  final String asset;
}

/// Lo que hay que emitir ante un cambio del tracker.
@immutable
class HudCueEvent {
  const HudCueEvent({this.tone, this.haptic = false});

  static const HudCueEvent none = HudCueEvent();

  final HudCue? tone;
  final bool haptic;

  bool get isEmpty => tone == null && !haptic;

  @override
  bool operator ==(Object other) =>
      other is HudCueEvent && other.tone == tone && other.haptic == haptic;

  @override
  int get hashCode => Object.hash(tone, haptic);
}

/// Traduce una transición del tracker en la señal que le corresponde (REQ-7).
///
/// Está separada del reproductor para poder fijarla con tests: las reglas que
/// importan no son "sonar", sino *cuándo no* sonar.
HudCueEvent resolveCue({
  required TrackingState previous,
  required TrackingState current,
  required int previousStep,
  required int step,
}) {
  // AC-7.2: un pulso por cada inferencia confirmada, de tono creciente. La
  // adquisición dura unos 120 ms, así que una cadencia que acelera no llegaría
  // a percibirse; lo que sí se percibe es la subida de altura.
  if (current == TrackingState.acquiring && step > 0 && step != previousStep) {
    return HudCueEvent(
      tone: switch (step.clamp(1, 3)) {
        1 => HudCue.scan1,
        2 => HudCue.scan2,
        _ => HudCue.scan3,
      },
    );
  }

  if (current == previous) return HudCueEvent.none;

  return switch (current) {
    // AC-3.6: volver de LOST no repite la adquisición, así que tampoco su
    // confirmación. Alcanza con un pulso de reenganche.
    TrackingState.locked => previous == TrackingState.lost
        ? const HudCueEvent(tone: HudCue.scan3)
        // AC-7.1: la háptica acompaña solo a la confirmación.
        : const HudCueEvent(tone: HudCue.lock, haptic: true),
    // AC-7.3: tono descendente, sin háptica.
    TrackingState.lost => const HudCueEvent(tone: HudCue.lost),
    TrackingState.searching || TrackingState.acquiring => HudCueEvent.none,
  };
}
