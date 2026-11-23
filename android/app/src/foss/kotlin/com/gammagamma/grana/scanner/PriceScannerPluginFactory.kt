package com.gammagamma.grana.scanner

import android.app.Activity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object PriceScannerPluginFactory {
    private const val CHANNEL_NAME = "com.gammagamma.grana/price_scanner"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCapabilities" -> result.success(
                    mapOf(
                        "isSupported" to false,
                        "activeTier" to "unsupported",
                        "llmStatus" to "unavailable",
                    ),
                )
                "detectLocationCurrency" -> result.success(emptyMap<String, Any>())
                "downloadModel" -> result.success(false)
                "disposeSession" -> result.success(null)
                else -> result.success(emptyMap<String, Any>())
            }
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean = false
}
