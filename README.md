# Weapon HUD Scanner

App Android en Flutter que simula el HUD de escaneo y apuntado de un arma de
ciencia ficción: reticle sobre el objetivo, distancia estimada, estados de
adquisición y pérdida de señal, sobre el feed de cámara en vivo.

Todo el procesamiento es **on-device**. Ningún cuadro de cámara ni dato
derivado sale del dispositivo, y la app funciona completamente sin red.

## Qué hace

- **Detecta rostros** con ML Kit y deriva de cada uno el encuadre del cuerpo por
  proporción antropométrica. La cara es el ancla; el cuerpo es lo que se
  encuadra.
- **Traba un objetivo** con una máquina de estados de cuatro estados
  —buscando, adquiriendo, trabado, señal perdida— con histéresis para que dos
  personas cercanas no se roben el lock. Se puede cambiar de objetivo tocando la
  pantalla, o dejando que el sistema lo pase a quien quede más centrado.
- **Estima la distancia** con un modelo pinhole a partir del ancho del rostro.
  Se muestra con `~` mientras el campo de visión de la cámara no esté calibrado,
  porque hasta entonces es una estimación y no una medición.
- **Dibuja el contorno** del objetivo trabado, extraído por marching squares
  sobre la máscara de segmentación.
- **Muestra varios sujetos** con jerarquía: todos llevan ganchos y una barra en
  la columna lateral; el trabado y los más cercanos llevan además su ficha de
  distancia.
- **Suena y vibra** al adquirir, trabar y perder el objetivo, con silencio
  persistente entre sesiones.

## Arquitectura

**Track A — overlay 2D.** Sin motor de juego y sin anclaje espacial 3D. El HUD
se dibuja en coordenadas de pantalla con `CustomPainter` sobre el
`CameraPreview`. Unity + AR Foundation se evaluó y se descartó: agrega anclaje
real y varias decenas de MB al binario para un resultado que, a las distancias
de trabajo, es prácticamente indistinguible.

Dos consecuencias que ordenan todo el código:

- **El HUD se repinta desde el tracker, no desde `setState`.** El tracker
  notifica a la tasa de refresco de pantalla y los painters lo escuchan como
  `repaint`. Eso desacopla el dibujo de la inferencia: el HUD se ve fluido
  aunque la detección corra a 12 fps.
- **Los painters no hablan con el tracker para dibujar un objetivo.** Reciben
  los datos ya resueltos, lo que permite componer el HUD contra datos
  sintéticos y rasterizarlo a PNG sin cámara ni dispositivo.

```
lib/
  scanner_page.dart      Cámara, pipeline de inferencia, composición
  tracking/              Rotación, mapeo de coordenadas, geometría, distancia,
                         contorno, máquina de estados, suavizado
  hud/                   Tema como datos, geometría, painters, diagnóstico
  audio/                 Transición → señal sonora, reproducción, háptica
tool/                    Sintetizador de los tonos WAV
```

## Estado

| | |
|---|---|
| Cámara, permisos, ciclo de vida, orientación | Hecho |
| Detección, mapeo de coordenadas, histéresis del lock | Hecho |
| Máquina de estados de tracking | Hecho |
| Distancia por modelo pinhole | Hecho, sin calibrar |
| Suavizado, interpolación, banda muerta | Hecho |
| Renderizado del HUD, responsivo teléfono y tablet | Hecho |
| Audio y háptica | Hecho |
| Captura y compartir | **Pendiente** |
| Calibración del campo de visión | Pendiente |
| Medición térmica sostenida | Pendiente |

Rendimiento medido en el dispositivo de referencia (Redmi Pad 2, 4 GB), con
detección de rostros: **26,7 fps de inferencia, 4 ms de latencia, 19 % de
descarte** — cómodamente por encima del objetivo de 10-15 fps.

La captura con el HUD compuesto es el ítem de mayor riesgo técnico que queda: el
plugin `camera` graba lo que ve el sensor, sin los widgets encima.

## Compilar

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

Android 10 (API 29) o superior, orientación apaisada. El `signingConfig` de
release todavía usa la clave de depuración: para distribuir hace falta un
keystore propio.

Dos comandos útiles que no necesitan dispositivo:

```bash
flutter test test/hud_preview_test.dart   # rasteriza el HUD a build/*.png
flutter test test/hud_mockup_test.dart    # ídem, con varios objetivos
dart run tool/generate_tones.dart         # regenera los WAV de assets/audio/
```

Los PNG sirven para iterar la composición, **no** la tipografía: el entorno de
test dibuja cajas en lugar de glifos.

## Privacidad

La detección de rostros **localiza** una cara en la imagen; no extrae una
plantilla biométrica ni identifica a nadie. Los objetivos se designan con un
código de pista (`TGT-07`), nunca con un nombre. No se persisten cuadros ni
cajas más allá de la sesión.

## Marca

El producto no usa nombre, logotipo, tipografía oficial ni assets de ninguna
obra con derechos. El lenguaje visual genérico del género —reticles, tipografía
técnica, códigos de color— se reconstruye desde cero. El material de referencia
usado durante el diseño queda fuera del control de versiones.
