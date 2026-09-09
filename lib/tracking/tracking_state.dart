/// Estados de tracking (REQ-3).
///
/// Son exactamente cuatro y describen el seguimiento, nada más. `OUT_OF_RANGE`
/// no está acá a propósito: es un indicador derivado de la distancia, ortogonal
/// al tracking, y puede convivir con [locked] (AC-3.8).
enum TrackingState {
  searching('BUSCANDO'),
  acquiring('ADQUIRIENDO'),
  locked('TRABADO'),
  lost('SEÑAL PERDIDA');

  const TrackingState(this.label);

  /// Copia que ve el usuario. Los identificadores internos quedan en inglés
  /// y la interfaz se muestra en español (AC-6.3).
  final String label;

  bool get hasTarget => this == locked || this == lost;
}
