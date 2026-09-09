# Weapon HUD Scanner

App Android en Flutter que simula el HUD de escaneo y apuntado de un arma de
ciencia ficción: reticle sobre el objetivo, distancia estimada, estados de
adquisición y pérdida de señal, sobre el feed de cámara en vivo.

**Documento de requisitos (v2.1):** https://claude.ai/code/artifact/7c2582d6-dea1-492f-b861-6e956bd14ff9

Los comentarios del código citan sus criterios de aceptación por identificador
(`AC-2.6`, `AC-4.4`, …). Al tocar código que cite uno, conviene leerlo primero.

## Decisiones ya tomadas

No hace falta volver a evaluarlas salvo que el usuario lo pida.

- **Track A — overlay 2D.** Sin motor de juego ni anclaje espacial 3D. El HUD se
  dibuja en coordenadas de pantalla con `CustomPainter`. Unity + AR Foundation
  se evaluó y se descartó.
- **Apaisado fijo**, ambos sentidos (`sensorLandscape`). Mantiene el mapeo de
  coordenadas en un solo caso.
- **Teléfono y tablet** son objetivos de primera clase: el HUD es responsivo.
- **Un solo objetivo trabado**, pero **varios mostrados** con jerarquía. La
  máquina de estados no cambió al agregar multi-objetivo. Todos los detectados
  llevan ganchos y barra en la columna; la ficha de distancia la llevan el
  trabado y los más cercanos hasta el tope del formato (3 en teléfono, 5 en
  tablet). La jerarquía la sostienen el peso de trazo, la silueta y el tamaño
  de la barra, no la ausencia de datos.
- **Sin línea guía entre ficha y objetivo.** Se probó y se quitó: con una sola
  ficha ya ensuciaba y con cinco el área útil se llenaba de cables cruzados.
  La separación respecto del gancho es la que comunica la pertenencia.
- **La cara es el ancla, el cuerpo es el encuadre.** El reticle encuadra la
  figura completa, derivada del rostro por proporción antropométrica.
- **Silueta solo al trabar.** La segmentación corre únicamente en `LOCKED`.
- **Designación técnica** (`TGT-07`), no nombres inventados: no se le pone un
  nombre falso a una persona real.
- **Cromo estructural sin datos falsos.** Las formas de la franja inferior son
  decorativas; todos los números que aparecen son mediciones reales. La única
  excepción deliberada es la barra de la columna de sujetos, que está siempre
  llena: por eso va en cian y no en ámbar, que es el color reservado a lo que
  el sistema mide. Es un dato del objetivo (`TargetReadout.vitality`) y no un
  adorno del painter, para que pueda pasar a significar algo sin rehacer el
  dibujo.
- **Copia visible en español**, identificadores internos en inglés (AC-6.3).

## Estructura

```
lib/
  main.dart              Bloqueo de orientación, tema, arranque
  scanner_page.dart      Cámara, pipeline de inferencia, composición
  tracking/
    sensor_rotation.dart Compensación de rotación del sensor
    coordinate_mapper.dart  Imagen → pantalla (cover, espejado, rotación)
    body_geometry.dart   Rostro → encuadre del cuerpo
    distance_estimator.dart Modelo pinhole
    silhouette.dart      Marching squares sobre la máscara de segmentación
    tracking_state.dart  Los cuatro estados
    target_tracker.dart  Máquina de estados, suavizado, animaciones
  hud/
    hud_theme.dart       Paleta y métricas como datos (AC-6.4)
    hud_layout.dart      Geometría compartida entre painters
    chrome_painter.dart  Marco permanente — estático, no se repinta
    hud_painter.dart     Objetivo y valores en vivo — se repinta con el tracker
    target_layer.dart    Ganchos, ficha y columna de sujetos, sobre datos
    diagnostics_panel.dart  Panel de desarrollo (AC-2.7)
  audio/
    hud_cue.dart         Transición → señal sonora (función pura)
    hud_audio.dart       Reproducción, háptica, silencio
tool/
  generate_tones.dart    Sintetiza los WAV de assets/audio/
referencias/             Material visual con derechos. NO se versiona.
```

## Invariantes que cuesta caro romper

Cada una costó una sesión de depuración o un bug reportado desde el dispositivo.

1. **El preview y el mapper usan el mismo `imageSize`.** El `SizedBox` que
   envuelve `CameraPreview` se dimensiona con el tamaño de imagen *rotado*, el
   mismo que recibe `CoordinateMapper`. Si se desacoplan, el reticle deja de
   caer sobre el objetivo.

2. **La orientación se estabiliza a apaisado.**
   `controller.value.deviceOrientation` informa cómo está sostenido el aparato,
   no cómo se muestra la interfaz. Con rotación automática libre, inclinar hacia
   vertical hacía que la imagen cambiara de proporción y el preview se ampliara
   como un zoom. Ver `stabilizeLandscape`; hay test de regresión.

3. **El formato de cámara es `ImageFormatGroup.nv21`.** Es lo que ML Kit espera
   en Android. Cambiarlo obliga a empaquetar los planos de YUV420 a mano.

4. **El HUD se repinta con el tracker, no con `setState`.** El tracker notifica
   a la tasa de refresco de pantalla y los painters lo escuchan como `repaint`.
   Meter `setState` por frame vuelve a acoplar el dibujo a la inferencia y se
   ve a tirones (AC-5.3, AC-6.6).

5. **El ticker del tracker se detiene solo** cuando no hay objetivo. Arrancarlo
   siempre significa 60 repintados por segundo frente a una pared vacía.

6. **El audio del HUD es sonido de medios.** El silencio que le corresponde es
   el volumen del canal de música, **no** `AudioManager.ringerMode`. En una
   tablet sin telefonía el modo de timbre informa silencio de forma permanente:
   consultarlo dejó la app muda por completo.

7. **El servicio de audio no se traga los errores.** Su getter `status` alimenta
   el panel de diagnóstico. Un servicio que falla en silencio no se puede
   diagnosticar desde un APK instalado.

8. **La segmentación no distingue entre personas.** El contorno se extrae solo
   dentro del encuadre del objetivo trabado; sin ese recorte vendrían los
   acompañantes pegados.

9. **El orden de la columna tiene banda muerta y las marcas, ventana de
   gracia.** Ordenar por distancia de cero en cada inferencia hacía que dos
   personas paradas a la misma distancia se intercambiaran de puesto varias
   veces por segundo; y ML Kit deja caer un rostro por un cuadro suelto cada
   tanto, lo que hacía titilar barras y ganchos. `TrackingConfig` expone
   `orderBandMeters` y `markGrace`. Hay tests de regresión para las dos.

10. **Los painters no hablan con el tracker para dibujar un objetivo.** Reciben
    `TargetReadout` ya resuelto. Es lo que permite componer contra datos
    sintéticos en `hud_mockup_test.dart`, sin cámara ni máquina de estados.

## Estado

### Hecho

| | |
|---|---|
| REQ-1 | Cámara, permisos, ciclo de vida, orientación |
| REQ-2 | Detección de rostros, mapeo de coordenadas, histéresis del lock |
| REQ-3 | Máquina de estados completa con sus umbrales |
| REQ-4 | Distancia por modelo pinhole **por objetivo**, sin calibrar (ver pendientes) |
| REQ-5 | Suavizado, interpolación, banda muerta |
| REQ-6 | Paleta, cromo, ficha de objetivo, silueta, animaciones, responsivo |
| REQ-7 | Tonos, háptica, silencio persistente |

### Pendiente

- **REQ-8 — Captura y compartir.** No empezado. Es el ítem de mayor riesgo
  técnico que queda: el plugin `camera` no compone el overlay, así que hace
  falta grabación de pantalla vía `MediaProjection` o render a textura común.
  AC-8.6 ya define el repliegue a captura fija si no da el rendimiento.
- **REQ-4 — calibración del hFOV.** Se usa 67° por defecto y la distancia se
  muestra con `~` adelante. Leer `LENS_INFO_AVAILABLE_FOCAL_LENGTHS` y
  `SENSOR_INFO_PHYSICAL_SIZE` por platform channel quita esa marca.
- **REQ-9 — medición térmica.** Falta la corrida de 10 minutos de AC-9.2.
- **iOS.** Documentado como extensión futura, no bloqueante.

### Calidad conocida

- La silueta no es completa: el modelo está entrenado para selfies y se degrada
  con la distancia. El usuario la aceptó como está ("no es perfecto pero salva").
  Si hay que mejorarla, las palancas son el umbral de confianza y el paso de
  celda de `SilhouetteExtractor`.
- El contorno se actualiza a la tasa de inferencia, no a 60 fps. Se lee como
  barrido en vivo.

## Comandos

```bash
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
flutter build apk --profile --target-platform android-arm64   # para medir
dart run tool/generate_tones.dart                             # regenera los WAV
flutter test test/hud_preview_test.dart                        # PNG en build/
flutter test test/hud_mockup_test.dart                         # ídem, multi-objetivo
```

`hud_preview_test.dart` rasteriza el HUD a PNG sin dispositivo. Sirve para
iterar la composición, **no** la tipografía: el entorno de test dibuja cajas en
lugar de glifos.

## Dispositivo de referencia

Redmi Pad 2, 4 GB de RAM. Es el piso de rendimiento de AC-9.6. Medido con
detección de rostros sola: **26,7 fps de inferencia, 4 ms de latencia, 19% de
descarte** — muy por encima de los 10-15 fps que pide REQ-9.

El usuario prueba instalando el APK release por sidecarga; no hay dispositivo
conectado a esta máquina, así que **nada se puede verificar en cámara desde
acá**. Los tests y el generador de vistas previas son la única validación local.

## Restricción de marca

El producto no usa nombre, logotipo, tipografía oficial ni assets de ninguna
obra con derechos (AC-10.6). El lenguaje visual genérico del género —reticles,
tipografía técnica, códigos de color— no está restringido. Las referencias de
`referencias/` son material de trabajo y están fuera del control de versiones.
