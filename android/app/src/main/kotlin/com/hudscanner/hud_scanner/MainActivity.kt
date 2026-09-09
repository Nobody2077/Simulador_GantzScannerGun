package com.hudscanner.hud_scanner

import android.content.Context
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "audioState" -> result.success(audioState())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Estado del audio del sistema (AC-7.4).
     *
     * Los tonos del HUD son sonido de medios, así que el silencio que les
     * corresponde es el del canal de música, no el del timbre. El modo de
     * timbre gobierna llamadas y notificaciones, y en una tablet sin telefonía
     * suele informar silencio de forma permanente aunque el volumen de medios
     * esté al máximo. Se informa igual, pero solo como diagnóstico.
     */
    private fun audioState(): Map<String, Any> {
        val audio = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return mapOf("available" to false)

        return mapOf(
            "available" to true,
            "mediaVolume" to audio.getStreamVolume(AudioManager.STREAM_MUSIC),
            "maxMediaVolume" to audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            "ringerSilent" to (audio.ringerMode != AudioManager.RINGER_MODE_NORMAL),
        )
    }

    companion object {
        private const val CHANNEL = "com.hudscanner.hud_scanner/system_audio"
    }
}
