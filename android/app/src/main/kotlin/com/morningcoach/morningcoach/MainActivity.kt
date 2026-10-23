package com.morningcoach.morningcoach

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.view.WindowManager

class MainActivity : FlutterActivity() {
    private var updater: ApkUpdater? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        updater = ApkUpdater(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "morningcoach/screen_awake"
        ).setMethodCallHandler { call, result ->
            if (call.method != "setEnabled") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val enabled = call.arguments as? Boolean ?: false
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            result.success(null)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "morningcoach/timer_beep"
        ).setMethodCallHandler { call, result ->
            if (call.method != "beep") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            playTimerBeep()
            result.success(null)
        }
    }

    /** A short tone at media volume when a logger countdown ends. */
    private fun playTimerBeep() {
        val tone = try {
            ToneGenerator(AudioManager.STREAM_MUSIC, BEEP_VOLUME)
        } catch (e: RuntimeException) {
            return // No audio output; the countdown still ends silently.
        }
        tone.startTone(ToneGenerator.TONE_PROP_BEEP, BEEP_MS)
        Handler(Looper.getMainLooper()).postDelayed({ tone.release() }, BEEP_MS + 100L)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        updater?.dispose()
        updater = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        visible = true
        UpdatedReceiver.dismiss(this)
    }

    override fun onPause() {
        visible = false
        super.onPause()
    }

    companion object {
        private const val BEEP_MS = 150
        private const val BEEP_VOLUME = 80

        @Volatile
        var visible = false
    }
}

