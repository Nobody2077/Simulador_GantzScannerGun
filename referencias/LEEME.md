# Referencias visuales — HUD del scanner

Material de trabajo para diseñar REQ-6. **No son assets del producto**: no van
declaradas en `pubspec.yaml`, no se empaquetan en el APK y no se versionan.
El lenguaje visual del género se reconstruye desde cero; lo que no se usa es
nombre, logotipo, tipografía oficial ni recortes de la obra (AC-10.6).

## Cómo nombrar los archivos

Numerados, para poder referirlos desde este documento:

```
01-lockon-cerca.jpg
02-lockon-lejos.jpg
03-detalle-reticle.jpg
04-estado-busqueda.jpg
```

## Qué capturas sirven más

En orden de utilidad:

1. **El HUD trabando un objetivo**, con el cuadro lo más nítido posible. Un
   frame quieto vale más que uno espectacular pero movido.
2. **El mismo HUD en estados distintos** — buscando, adquiriendo, trabado. Es lo
   que define la animación de adquisición y qué cambia entre un estado y otro.
3. **Detalles recortados** del reticle y de la tipografía. Sirven para el grosor
   de línea, la forma de las esquinas y el peso del texto.
4. **Planos generales** que muestren la composición completa de la pantalla:
   dónde va cada bloque de información respecto del objetivo.
5. **Objetivos a distintas distancias**, para ver si el reticle escala con el
   objetivo o se mantiene fijo.

## Descripción

Completá lo que puedas. Lo que no sepas, dejalo en blanco: prefiero preguntarte
antes que inventarlo.

### Qué es lo que más te importa reproducir

<!-- Si tuvieras que quedarte con un solo elemento del HUD, ¿cuál? -->

### Qué NO querés

<!-- Elementos de la referencia que preferís dejar afuera. -->

### Por captura

<!--
01-lockon-cerca.jpg — qué mirar acá, qué te llama la atención
02-...
-->

### Movimiento

<!--
¿Qué se anima y cómo? ¿El reticle gira, pulsa, se cierra sobre el objetivo?
¿Hay líneas de barrido? ¿Algo parpadea al confirmar el lock?
-->

### Color

<!--
¿Un color dominante o varios? ¿Cambia según el estado del sistema?
-->
