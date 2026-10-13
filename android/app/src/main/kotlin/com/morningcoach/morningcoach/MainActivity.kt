package com.morningcoach.morningcoach

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
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
        @Volatile
        var visible = false
    }
}

