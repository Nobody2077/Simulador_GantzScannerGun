import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tracking/target_tracker.dart';
import '../tracking/tracking_state.dart';
import 'hud_cue.dart';

/// Sonido y háptica del HUD (REQ-7).
///
/// Escucha al tracker y traduce sus transiciones en tonos. Es la mitad de la
/// fantasía que la app promete: un lock-on sin sonido es medio lock-on.
class HudAudio extends ChangeNotifier {
  HudAudio({required this.tracker});

  final TargetTracker tracker;

  static const MethodChannel _system =
      MethodChannel('com.hudscanner.hud_scanner/system_audio');

  static const String _mutedKey = 'hud_audio_muted';

  final Map<String, AudioPlayer> _players = {};
  SharedPreferences? _preferences;

  bool _muted = false;
  bool _ready = false;
  int _mediaVolume = -1;
  int _maxMediaVolume = -1;
  bool _ringerSilent = false;
  String? _lastError;

  TrackingState _lastState = TrackingState.searching;
  int _lastStep = 0;

  /// Silencio elegido por el usuario, persistente entre sesiones (AC-7.4).
  bool get muted => _muted;

  /// El volumen de medios está en cero.
  ///
  /// Es el silencio que corresponde a un sonido de medios. El modo de timbre
  /// no se consulta para decidir: gobierna llamadas y notificaciones, y en una
  /// tablet sin telefonía informa silencio de forma permanente.
  bool get systemSilent => _mediaVolume == 0;

  bool get ready => _ready;

  bool get audible => _ready && !_muted && !systemSilent;

  /// Resumen del estado del audio, para el panel de diagnóstico.
  ///
  /// Un servicio que falla en silencio es un servicio imposible de diagnosticar;
  /// esto es lo que faltaba la primera vez.
  String get status {
    if (_lastError != null) return 'error: $_lastError';
    if (!_ready) return 'no iniciado';
    final volume = _maxMediaVolume > 0
        ? ' · vol $_mediaVolume/$_maxMediaVolume'
        : '';
    if (_muted) return 'silenciado$volume';
    if (systemSilent) return 'volumen en cero$volume';
    return 'activo$volume${_ringerSilent ? " · timbre en silencio" : ""}';
  }

  Future<void> initialize() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      _muted = _preferences?.getBool(_mutedKey) ?? false;
    } catch (error) {
      // Sin preferencias se arranca con el sonido activo; no es motivo para
      // quedarse sin audio.
      _muted = false;
    }

    await refreshSystemAudio();

    // AC-7.5: los assets se cargan en el arranque. Cargarlos recién al sonar
    // mete decenas de milisegundos justo donde no se pueden gastar — el tono
    // llegaría después del cambio de estado que lo dispara.
    for (final cue in HudCue.values) {
      final player = await _prepare(cue.asset);
      if (player != null) _players[cue.asset] = player;
    }

    _ready = _players.isNotEmpty;
    if (!_ready && _lastError == null) {
      _lastError = 'ningún tono pudo cargarse';
    }

    tracker.addListener(_onTrackerChanged);
    notifyListeners();
  }

  /// Carga un tono, con repliegue al reproductor normal.
  ///
  /// El modo de baja latencia usa SoundPool, que es lo que hace falta para los
  /// 80 ms de AC-7.5, pero no está disponible en todos los dispositivos. Si
  /// falla, mejor sonar tarde que no sonar.
  Future<AudioPlayer?> _prepare(String asset) async {
    for (final mode in [PlayerMode.lowLatency, PlayerMode.mediaPlayer]) {
      try {
        final player = AudioPlayer();
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setPlayerMode(mode);
        await player.setSource(AssetSource('audio/$asset.wav'));
        return player;
      } catch (error) {
        _lastError = '$asset (${mode.name}): $error';
      }
    }
    return null;
  }

  /// Vuelve a consultar el estado del audio del sistema.
  ///
  /// Conviene llamarlo al volver de segundo plano: el volumen pudo cambiar
  /// mientras la app no estaba.
  Future<void> refreshSystemAudio() async {
    try {
      final state = await _system.invokeMapMethod<String, dynamic>('audioState');
      if (state == null || state['available'] != true) return;

      _mediaVolume = (state['mediaVolume'] as num?)?.toInt() ?? -1;
      _maxMediaVolume = (state['maxMediaVolume'] as num?)?.toInt() ?? -1;
      _ringerSilent = state['ringerSilent'] as bool? ?? false;
      notifyListeners();
    } catch (_) {
      // Sin el canal nativo se asume que se puede sonar: es preferible a
      // quedarse mudo por no poder preguntar.
      _mediaVolume = -1;
    }
  }

  Future<void> setMuted(bool value) async {
    if (_muted == value) return;
    _muted = value;
    notifyListeners();

    try {
      await _preferences?.setBool(_mutedKey, value);
    } catch (_) {
      // Que no persista la preferencia no debería impedir cambiarla.
    }

    // Al reactivar el sonido se emite la confirmación: da respuesta inmediata
    // y de paso comprueba que la cadena de audio funciona.
    if (!value) {
      await refreshSystemAudio();
      await _play(HudCue.lock.asset);
    }
  }

  void _onTrackerChanged() {
    final state = tracker.state;
    final step = tracker.acquireStep;

    final cue = resolveCue(
      previous: _lastState,
      current: state,
      previousStep: _lastStep,
      step: step,
    );

    if (cue.tone != null) _play(cue.tone!.asset);
    // AC-7.6: en un dispositivo sin motor adecuado esto no hace nada, y el
    // resto de la experiencia queda igual.
    if (cue.haptic) HapticFeedback.mediumImpact();

    _lastState = state;
    _lastStep = state == TrackingState.acquiring ? step : 0;
  }

  Future<void> _play(String tone) async {
    if (!audible) return;
    final player = _players[tone];
    if (player == null) return;
    try {
      // Detener antes de soltar: en SoundPool, `stop` es lo que descarta el
      // stream anterior. Sin eso, el segundo disparo intenta reanudar un stream
      // ya terminado y no suena.
      await player.stop();
      await player.resume();
    } catch (error) {
      _lastError = '$tone: $error';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    tracker.removeListener(_onTrackerChanged);
    for (final player in _players.values) {
      player.dispose();
    }
    _players.clear();
    super.dispose();
  }
}
