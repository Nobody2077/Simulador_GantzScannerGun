import 'package:flutter/widgets.dart';

/// Paleta y métricas del HUD, como objeto de datos (AC-6.4).
///
/// Los painters no llevan un solo color literal: todo sale de acá. Agregar un
/// tema nuevo no debería obligar a tocar el código de dibujo.
///
/// La regla que ordena la paleta es la separación de roles que se ve en la
/// referencia: **el cian es el chasis y el ámbar es lo que el sistema dice**.
/// Líneas, marcos, escalas y nombres de campo van en cian; los valores y las
/// alertas, en ámbar. Mezclarlos rompe la lectura de instrumento.
@immutable
class HudTheme {
  const HudTheme({
    required this.structure,
    required this.structureDim,
    required this.structureFaint,
    required this.readout,
    required this.alert,
    required this.highlight,
    required this.panelFill,
    required this.feedTint,
    required this.panel,
    required this.panelBorder,
    required this.hairline,
    required this.strokeWidth,
    required this.microSize,
    required this.labelSize,
    required this.valueSize,
    required this.alertSize,
    required this.panelTextSize,
    required this.titleSize,
    required this.statusDotSize,
    required this.inset,
  });

  /// Cian principal: líneas activas, marcos, texto de campo.
  final Color structure;

  /// Cian atenuado: estructura secundaria, escalas, divisiones.
  final Color structureDim;

  /// Cian muy tenue: marcas de fondo que dan densidad sin pedir atención.
  final Color structureFaint;

  /// Ámbar: todo valor que el sistema mide.
  final Color readout;

  /// Ámbar de alerta: fuera de rango, señal perdida.
  final Color alert;

  final Color highlight;

  /// Relleno translúcido de las fichas de datos.
  final Color panelFill;

  /// Tinte que se aplica sobre el feed de cámara, por debajo del HUD.
  ///
  /// Es lo que convierte "imagen de cámara" en "lo que ve el visor": el feed
  /// crudo se lee como una foto y el tinte lo integra al instrumento. Se tiñe
  /// solo la imagen, nunca el HUD, que tiene que seguir leyéndose por encima.
  ///
  /// Deliberadamente suave: un azul fuerte se ve espectacular en una captura y
  /// cansa a los diez minutos de uso real.
  final Color feedTint;

  /// Fondo del panel de diagnóstico de desarrollo.
  final Color panel;
  final Color panelBorder;

  /// Grosor de las líneas de estructura fina.
  final double hairline;

  /// Grosor de las líneas del objetivo.
  final double strokeWidth;

  final double microSize;
  final double labelSize;
  final double valueSize;
  final double alertSize;
  final double panelTextSize;
  final double titleSize;
  final double statusDotSize;

  /// Separación respecto de los bordes de pantalla.
  final double inset;

  /// Tema por defecto. Tamaños expresados para la referencia de 1280×720;
  /// [scaled] los lleva a la pantalla real.
  static const HudTheme scanner = HudTheme(
    structure: Color(0xFF74E2F7),
    structureDim: Color(0xFF3D9DB8),
    structureFaint: Color(0x4D3D9DB8),
    readout: Color(0xFFFFC53A),
    alert: Color(0xFFFFB01F),
    highlight: Color(0xFFEAF9FF),
    panelFill: Color(0x2E1E6E8C),
    feedTint: Color(0x3D0C4C66),
    panel: Color(0xD9061013),
    panelBorder: Color(0x2674E2F7),
    hairline: 1,
    strokeWidth: 1.8,
    microSize: 8,
    labelSize: 10.5,
    valueSize: 20,
    alertSize: 34,
    panelTextSize: 11.5,
    titleSize: 10,
    statusDotSize: 7,
    inset: 16,
  );

  /// Devuelve el tema con las métricas llevadas a la pantalla real.
  ///
  /// AC-6.9: el escalado va acotado, no lineal. Sin tope, en una tablet grande
  /// el HUD se convierte en un cartel y en un teléfono chico queda ilegible.
  HudTheme scaled(double factor) {
    // El trazo escala menos que el texto: una línea gruesa deja de leerse como
    // instrumento de precisión y pasa a parecer un marcador.
    final strokeFactor = 1 + (factor - 1) * 0.45;
    return HudTheme(
      structure: structure,
      structureDim: structureDim,
      structureFaint: structureFaint,
      readout: readout,
      alert: alert,
      highlight: highlight,
      panelFill: panelFill,
      feedTint: feedTint,
      panel: panel,
      panelBorder: panelBorder,
      hairline: hairline * strokeFactor,
      strokeWidth: strokeWidth * strokeFactor,
      microSize: microSize * factor,
      labelSize: labelSize * factor,
      valueSize: valueSize * factor,
      alertSize: alertSize * factor,
      panelTextSize: panelTextSize * factor,
      titleSize: titleSize * factor,
      statusDotSize: statusDotSize * factor,
      inset: inset * factor,
    );
  }
}

/// Factor de escala del HUD respecto de la referencia visual de 1280×720.
///
/// Se toma el lado corto porque es el que manda en apaisado, y se acota para
/// que teléfono y tablet queden ambos legibles (AC-6.8 y AC-6.9).
double hudScale(Size screen) => (screen.shortestSide / 720).clamp(0.85, 1.55);

/// Fuente monoespaciada del sistema. En Android resuelve a una mono real sin
/// necesidad de empaquetar un asset.
const String hudMonoFamily = 'monospace';

/// Construye el estilo de texto del HUD desde los tokens del tema.
TextStyle hudText({
  required Color color,
  required double size,
  double letterSpacing = 0,
  double height = 1.2,
}) =>
    TextStyle(
      color: color,
      fontSize: size,
      fontFamily: hudMonoFamily,
      letterSpacing: letterSpacing,
      height: height,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
