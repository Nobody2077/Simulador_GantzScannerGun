// Genera los tonos del HUD como WAV mono de 16 bits.
//
// Se sintetizan en vez de usar samples de terceros: quedan exactamente como los
// queremos, pesan unos pocos KB y no arrastran licencias de nadie.
//
// Correr con:  dart run tool/generate_tones.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const int sampleRate = 44100;

void main() {
  final directory = Directory('assets/audio')..createSync(recursive: true);

  // Barrido de adquisición: tres pulsos de tono creciente, uno por inferencia
  // confirmada. La subida de altura es lo que se percibe como "está por
  // cerrar", que es lo que pide AC-7.2.
  for (var step = 0; step < 3; step++) {
    final base = 760.0 * math.pow(1.22, step);
    write(
      '${directory.path}/scan_${step + 1}.wav',
      render(
        durationMs: 55,
        amplitude: 0.32,
        frequency: (t) => base,
        envelope: percussive(attackMs: 3, decayMs: 52),
      ),
    );
  }

  // Confirmación de lock: chirp ascendente corto y brillante, con una quinta
  // por encima para darle cuerpo.
  write(
    '${directory.path}/lock.wav',
    render(
      durationMs: 130,
      amplitude: 0.42,
      frequency: (t) => 620 + 780 * t,
      harmonic: 1.5,
      harmonicMix: 0.35,
      envelope: percussive(attackMs: 4, decayMs: 126),
    ),
  );

  // Señal perdida: caída larga, sin brillo. Tiene que leerse como algo que se
  // apaga, no como un aviso de error.
  write(
    '${directory.path}/lost.wav',
    render(
      durationMs: 260,
      amplitude: 0.30,
      frequency: (t) => 620 - 340 * t,
      envelope: percussive(attackMs: 8, decayMs: 252),
    ),
  );

  stdout.writeln('Tonos escritos en ${directory.path}');
}

/// Envolvente percusiva: ataque rápido y caída exponencial.
double Function(double) percussive({
  required double attackMs,
  required double decayMs,
}) {
  return (elapsedMs) {
    if (elapsedMs < attackMs) return elapsedMs / attackMs;
    final decayed = (elapsedMs - attackMs) / decayMs;
    return math.exp(-4.2 * decayed);
  };
}

/// Sintetiza una onda con frecuencia variable en el tiempo.
///
/// [frequency] recibe el avance normalizado de 0 a 1 y devuelve hercios. La
/// fase se integra en vez de calcularse por muestra, que es lo que evita los
/// chasquidos al barrer la frecuencia.
Int16List render({
  required int durationMs,
  required double amplitude,
  required double Function(double progress) frequency,
  required double Function(double elapsedMs) envelope,
  double harmonic = 0,
  double harmonicMix = 0,
}) {
  final total = (sampleRate * durationMs / 1000).round();
  final samples = Int16List(total);
  var phase = 0.0;
  var harmonicPhase = 0.0;

  for (var i = 0; i < total; i++) {
    final progress = i / total;
    final hz = frequency(progress);
    phase += 2 * math.pi * hz / sampleRate;
    harmonicPhase += 2 * math.pi * hz * harmonic / sampleRate;

    var value = math.sin(phase);
    if (harmonic > 0) {
      value = value * (1 - harmonicMix) + math.sin(harmonicPhase) * harmonicMix;
    }

    final gain = amplitude * envelope(i * 1000 / sampleRate);
    samples[i] = (value * gain * 32767).clamp(-32768, 32767).round();
  }

  return samples;
}

/// Escribe un WAV PCM mono de 16 bits.
void write(String path, Int16List samples) {
  final dataBytes = samples.lengthInBytes;
  final header = BytesBuilder();

  void ascii(String text) => header.add(text.codeUnits);
  void uint32(int value) =>
      header.add(Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little));
  void uint16(int value) =>
      header.add(Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little));

  ascii('RIFF');
  uint32(36 + dataBytes);
  ascii('WAVE');
  ascii('fmt ');
  uint32(16); // tamaño del bloque fmt
  uint16(1); // PCM sin comprimir
  uint16(1); // mono
  uint32(sampleRate);
  uint32(sampleRate * 2); // bytes por segundo
  uint16(2); // alineación de bloque
  uint16(16); // bits por muestra
  ascii('data');
  uint32(dataBytes);
  header.add(samples.buffer.asUint8List());

  File(path).writeAsBytesSync(header.takeBytes());
}
