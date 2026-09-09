import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

import 'audio/hud_audio.dart';
import 'hud/chrome_painter.dart';
import 'hud/diagnostics_panel.dart';
import 'hud/hud_painter.dart';
import 'hud/hud_theme.dart';
import 'tracking/coordinate_mapper.dart';
import 'tracking/sensor_rotation.dart';
import 'tracking/silhouette.dart';
import 'tracking/target_tracker.dart';
import 'tracking/tracking_state.dart';

const HudReadouts _idleReadouts = HudReadouts(
  camera: '—',
  detecting: false,
  resolution: '—',
  inferenceFps: 0,
  latencyMs: 0,
);

/// Pantalla principal: cámara, detección y HUD.
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      // AC-2.1: el trackingId es lo que sostiene la semántica de lock.
      enableTracking: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  /// Segmentación de persona, para el contorno del objetivo trabado.
  ///
  /// La máscara se pide en su tamaño nativo: viene mucho más chica que la
  /// imagen y el contorno se extrae sobre ella, así que recorrerla cuesta una
  /// fracción de lo que costaría a resolución completa.
  final SelfieSegmenter _segmenter = SelfieSegmenter(
    mode: SegmenterMode.stream,
    enableRawSizeMask: true,
  );

  static const SilhouetteExtractor _extractor = SilhouetteExtractor();

  late final TargetTracker _tracker = TargetTracker(vsync: this);
  late final HudAudio _audio = HudAudio(tracker: _tracker);

  /// Lecturas de la franja inferior. Van en un notifier propio para que se
  /// actualicen sin reconstruir el árbol de widgets (AC-6.6).
  final ValueNotifier<HudReadouts> _readouts = ValueNotifier(_idleReadouts);

  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  CameraController? _controller;
  String? _error;

  /// AC-2.3: si hay una inferencia en curso, el frame se descarta. No se encola:
  /// una cola solo acumula latencia y termina mostrando el pasado.
  bool _busy = false;

  InputImageRotation? _rotation;
  bool _hasFrame = false;

  /// Última orientación **de interfaz** conocida.
  ///
  /// La app está bloqueada en apaisado (AC-1.5), pero
  /// `controller.value.deviceOrientation` informa cómo está sostenido el
  /// aparato, no cómo se está mostrando la interfaz. Con la rotación automática
  /// libre, inclinar el dispositivo hacia vertical hacía que esa lectura pasara
  /// a retrato: la compensación giraba 90°, `rotatedSize` intercambiaba los ejes
  /// y `BoxFit.cover` ampliaba el preview para cubrir una pantalla horizontal
  /// con una imagen vertical. Eso era el zoom.
  ///
  /// Como la interfaz nunca se muestra en retrato, quedarse con la última
  /// lectura apaisada es exactamente lo que está en pantalla.
  DeviceOrientation _uiOrientation = DeviceOrientation.landscapeLeft;

  // Contadores de diagnóstico (AC-2.7).
  int _faceCount = 0;
  int _framesSeen = 0;
  int _framesProcessed = 0;
  DateTime _fpsWindowStart = DateTime.now();
  int _fpsWindowCount = 0;
  double _inferenceFps = 0;
  int _segmentationMs = 0;
  bool _showDiagnostics = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _audio.initialize();
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    _audio.dispose();
    _tracker.dispose();
    _readouts.dispose();
    _detector.close();
    _segmenter.close();
    super.dispose();
  }

  /// AC-1.6: soltar la cámara al ir a segundo plano y recuperarla al volver.
  ///
  /// Deliberadamente **no** se libera en `inactive`: ese estado también lo
  /// dispara bajar la persiana de notificaciones o abrir recientes, con la app
  /// todavía visible. Soltar la cámara ahí produce un parpadeo en cada gesto.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _stopCamera();
      case AppLifecycleState.resumed:
        // El volumen pudo haber cambiado mientras la app no estaba.
        _audio.refreshSystemAudio();
        if (_controller == null && _cameras.isNotEmpty) _initController();
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _start() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _error = 'No se encontró ninguna cámara en el dispositivo.');
        return;
      }
      // La trasera es la que se usa para apuntar; es el caso principal.
      final back = _cameras
          .indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      _cameraIndex = back == -1 ? 0 : back;
      await _initController();
    } on CameraException catch (e) {
      setState(() => _error = _describe(e));
    }
  }

  Future<void> _initController() async {
    final controller = CameraController(
      _cameras[_cameraIndex],
      ResolutionPreset.medium, // AC-1.2: ≈720p, el equilibrio del REQ-1.
      enableAudio: false,
      // Pedimos NV21 directo. Es el formato que ML Kit espera en Android, así
      // que nos ahorramos empaquetar los planos de YUV420 a mano — que es donde
      // esta arquitectura suele perder días.
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    _controller = controller;

    try {
      await controller.initialize();
      await controller.startImageStream(_onFrame);
      if (mounted) setState(() => _error = null);
    } on CameraException catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    }
  }

  Future<void> _stopCamera() async {
    final controller = _controller;
    _controller = null;
    _hasFrame = false;
    _readouts.value = _idleReadouts;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {
      // El stream ya podía estar cerrado; no es un error que valga reportar.
    }
    await controller.dispose();
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    await _stopCamera();
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    _resetCounters();
    await _initController();
  }

  void _resetCounters() {
    _framesSeen = 0;
    _framesProcessed = 0;
    _fpsWindowCount = 0;
    _faceCount = 0;
    _fpsWindowStart = DateTime.now();
  }

  Future<void> _onFrame(CameraImage image) async {
    _framesSeen++;
    if (_busy) return;
    _busy = true;
    final started = DateTime.now();

    try {
      final input = _toInputImage(image);
      if (input == null) return;

      final faces = await _detector.processImage(input);
      _framesProcessed++;
      _updateFps();

      final rotation = _rotation;
      if (rotation == null || !mounted) return;

      final imageSize = rotatedSize(image.width, image.height, rotation);
      _faceCount = faces.length;

      // El tracker se encarga del suavizado y de la máquina de estados; acá
      // solo se le pasa la medición cruda.
      _tracker.onInference(
        [
          for (final face in faces)
            RawTarget(id: face.trackingId, faceBox: face.boundingBox),
        ],
        imageSize,
      );

      // La segmentación corre solo con el objetivo trabado: es el único momento
      // en que el contorno se usa, y así el segundo modelo no pesa mientras el
      // sistema está buscando.
      if (_tracker.state == TrackingState.locked) {
        await _updateSilhouette(input, imageSize);
      }

      _readouts.value = HudReadouts(
        camera: _cameras[_cameraIndex].lensDirection == CameraLensDirection.front
            ? 'frontal'
            : 'trasera',
        detecting: true,
        resolution: '${imageSize.width.round()}×${imageSize.height.round()}',
        inferenceFps: double.parse(_inferenceFps.toStringAsFixed(1)),
        latencyMs: DateTime.now().difference(started).inMilliseconds,
      );

      if (!_hasFrame) setState(() => _hasFrame = true);
    } catch (_) {
      // Un frame fallido no debe cortar el stream.
    } finally {
      _busy = false;
    }
  }

  /// Segmenta la persona y extrae su contorno dentro del encuadre del objetivo.
  ///
  /// El recorte a la caja del objetivo no es solo una optimización: la
  /// segmentación no distingue entre personas, así que sin él el contorno del
  /// objetivo trabado vendría con los acompañantes pegados.
  Future<void> _updateSilhouette(InputImage input, Size imageSize) async {
    final body = _tracker.bodyBox;
    if (body == null) return;

    final started = DateTime.now();
    final mask = await _segmenter.processImage(input);
    if (mask == null || !mounted) {
      _tracker.onSilhouette(null);
      return;
    }

    _tracker.onSilhouette(
      _extractor.extract(
        confidences: mask.confidences,
        maskWidth: mask.width,
        maskHeight: mask.height,
        imageSize: imageSize,
        // El encuadre se ensancha antes de recortar. La caja del cuerpo sale de
        // una proporción que asume a la persona de pie y de frente; con los
        // brazos separados, o de costado, los hombros quedan fuera y el
        // contorno se cortaba contra mi propio recorte, no contra la máscara.
        region: body.inflate(body.width * 0.22),
      ),
    );
    _segmentationMs = DateTime.now().difference(started).inMilliseconds;
  }

  InputImage? _toInputImage(CameraImage image) {
    final controller = _controller;
    if (controller == null) return null;

    final rotation = _resolveRotation(_cameras[_cameraIndex], controller);
    if (rotation == null) return null;
    _rotation = rotation;

    // Con ImageFormatGroup.nv21 el plugin entrega un único plano ya empaquetado.
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        // Tamaño **sin rotar**: ML Kit aplica la rotación por su cuenta.
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  InputImageRotation? _resolveRotation(
    CameraDescription camera,
    CameraController controller,
  ) {
    if (!Platform.isAndroid) {
      return InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    }

    _uiOrientation = stabilizeLandscape(
      controller.value.deviceOrientation,
      _uiOrientation,
    );

    return InputImageRotationValue.fromRawValue(
      compensateRotation(
        sensorOrientation: camera.sensorOrientation,
        uiOrientation: _uiOrientation,
        frontFacing: camera.lensDirection == CameraLensDirection.front,
      ),
    );
  }

  void _updateFps() {
    _fpsWindowCount++;
    final elapsed = DateTime.now().difference(_fpsWindowStart);
    if (elapsed.inMilliseconds >= 1000) {
      _inferenceFps = _fpsWindowCount * 1000 / elapsed.inMilliseconds;
      _fpsWindowCount = 0;
      _fpsWindowStart = DateTime.now();
    }
  }

  String _describe(CameraException e) {
    switch (e.code) {
      case 'CameraAccessDenied':
        return 'Permiso de cámara denegado. Concedelo desde los ajustes del '
            'sistema para poder usar el escáner.';
      case 'CameraAccessDeniedWithoutPrompt':
      case 'CameraAccessRestricted':
        return 'El permiso de cámara está bloqueado a nivel del sistema. Hay '
            'que habilitarlo desde Ajustes → Aplicaciones.';
      default:
        return 'No se pudo iniciar la cámara (${e.code}). ${e.description ?? ""}';
    }
  }

  List<DiagnosticRow> _diagnosticRows() {
    final readouts = _readouts.value;
    final distance = _tracker.distanceMeters;
    final dropped = _framesSeen == 0
        ? '—'
        : '${((1 - _framesProcessed / _framesSeen) * 100).round()}%';

    return [
      DiagnosticRow('cámara', readouts.camera),
      DiagnosticRow('rotación',
          '${_rotation?.rawValue ?? "—"}° · ${_uiOrientation.name.replaceFirst("landscape", "")}'),
      DiagnosticRow('imagen', readouts.resolution),
      DiagnosticRow('inferencia',
          '${readouts.inferenceFps.toStringAsFixed(1)} fps · ${readouts.latencyMs} ms'),
      DiagnosticRow('descarte', '$dropped ($_framesProcessed/$_framesSeen)'),
      DiagnosticRow('caras',
          '$_faceCount (${_tracker.secondaryMarks.length} sec.)'),
      DiagnosticRow('estado', _tracker.state.name.toUpperCase()),
      DiagnosticRow(
        'contorno',
        _tracker.silhouette?.isEmpty == false
            ? '${_tracker.silhouette!.segments.length ~/ 4} seg · $_segmentationMs ms'
            : '—',
      ),
      DiagnosticRow(
        'distancia',
        distance == null
            ? '—'
            : '${_tracker.calibrated ? "" : "~"}'
                '${distance.toStringAsFixed(1)} m'
                '${_tracker.outOfRange ? " · fuera" : ""}',
      ),
      DiagnosticRow('lock',
          'id ${_tracker.lockedId ?? "—"} · ${_tracker.lockedForSeconds}s'),
      DiagnosticRow('audio', _audio.status),
    ];
  }

  /// AC-6.7: se respeta la reducción de movimiento del sistema.
  bool _reduceMotion = false;

  @override
  Widget build(BuildContext context) {
    final theme = HudTheme.scanner.scaled(hudScale(MediaQuery.sizeOf(context)));
    _reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraLayer(theme),
          if (_showDiagnostics)
            Positioned(
              left: theme.inset * 2.5,
              top: theme.inset * 3.4,
              child: ListenableBuilder(
                listenable: Listenable.merge([_tracker, _readouts]),
                builder: (context, _) => DiagnosticsPanel(
                  title: 'DIAGNÓSTICO',
                  rows: _diagnosticRows(),
                  theme: theme,
                ),
              ),
            ),
          _buildControls(theme),
        ],
      ),
    );
  }

  Widget _buildCameraLayer(HudTheme theme) {
    final error = _error;
    if (error != null) return _buildError(error);

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || !_hasFrame) {
      return Center(
        child: Text(
          controller == null ? 'Iniciando cámara…' : 'Esperando señal…',
          style: hudText(color: theme.structureDim, size: theme.labelSize),
        ),
      );
    }

    final imageSize = _tracker.imageSize;
    final mirror =
        _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

    return Stack(
      fit: StackFit.expand,
      children: [
        // El preview se dispone con el mismo tamaño que usa el mapper.
        // Esa coincidencia es lo que hace que el reticle caiga sobre el objetivo.
        ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: imageSize.width,
              height: imageSize.height,
              child: CameraPreview(controller),
            ),
          ),
        ),
        // Cromo fijo: se pinta una vez y no se repinta con cada frame.
        CustomPaint(painter: ChromePainter(theme: theme)),
        // Capa de objetivo: lo único que se mueve.
        CustomPaint(
          painter: HudPainter(
            tracker: _tracker,
            readouts: _readouts,
            theme: theme,
            mirror: mirror,
            reduceMotion: _reduceMotion,
          ),
        ),
      ],
    );
  }

  Widget _buildError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.5),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _start, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }

  /// Los controles viven en el borde inferior izquierdo, fuera de la franja de
  /// instrumentos, para no competir con ella.
  Widget _buildControls(HudTheme theme) {
    return Positioned(
      left: theme.inset * 2.5,
      bottom: theme.inset * 0.5,
      child: Row(
        children: [
          // AC-7.4: el silencio elegido por el usuario sobrevive a la sesión.
          ListenableBuilder(
            listenable: _audio,
            builder: (context, _) => _HudButton(
              icon: _audio.muted
                  ? Icons.volume_off_outlined
                  : _audio.systemSilent
                      ? Icons.volume_mute_outlined
                      : Icons.volume_up_outlined,
              tooltip: _audio.systemSilent
                  ? 'Volumen de medios en cero'
                  : _audio.muted
                      ? 'Activar sonido'
                      : 'Silenciar',
              theme: theme,
              onPressed: () => _audio.setMuted(!_audio.muted),
            ),
          ),
          SizedBox(width: theme.inset * 0.6),
          _HudButton(
            icon: _showDiagnostics ? Icons.speed : Icons.speed_outlined,
            tooltip: 'Diagnóstico',
            theme: theme,
            onPressed: () =>
                setState(() => _showDiagnostics = !_showDiagnostics),
          ),
          SizedBox(width: theme.inset * 0.6),
          _HudButton(
            icon: Icons.cameraswitch_outlined,
            tooltip: 'Cambiar cámara',
            theme: theme,
            onPressed: _cameras.length < 2 ? null : _switchCamera,
          ),
        ],
      ),
    );
  }
}

/// Botón discreto, en la paleta del HUD: los controles de la app no deberían
/// parecer de otro sistema que el que están operando.
class _HudButton extends StatelessWidget {
  const _HudButton({
    required this.icon,
    required this.tooltip,
    required this.theme,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final HudTheme theme;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: theme.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(theme.inset * 0.25),
          side: BorderSide(color: theme.panelBorder),
        ),
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: EdgeInsets.all(theme.inset * 0.5),
            child: Icon(
              icon,
              size: theme.labelSize * 1.7,
              color: enabled ? theme.structure : theme.structureFaint,
            ),
          ),
        ),
      ),
    );
  }
}
