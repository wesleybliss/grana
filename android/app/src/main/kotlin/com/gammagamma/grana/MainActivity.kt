package com.gammagamma.grana

import com.gammagamma.grana.scanner.PriceScannerPluginFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PriceScannerPluginFactory.register(flutterEngine, this)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (PriceScannerPluginFactory.onRequestPermissionsResult(
                requestCode,
                permissions,
                grantResults,
            )
        ) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
