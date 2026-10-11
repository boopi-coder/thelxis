package io.thelxis.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var host: HostChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Registers the generated plugins (flutter_webrtc, ...).
        super.configureFlutterEngine(flutterEngine)
        val channel = HostChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        channel.activity = this
        host = channel
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        host?.dispose()
        host = null
        // With the engine gone nothing listens or captures any more, so the
        // "available" / "screen is being shared" notifications would be a lie.
        if (!isChangingConfigurations) {
            PresenceService.stop(applicationContext)
            CaptureService.stop(applicationContext)
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        host?.onPermissionResult(requestCode, grantResults)
    }
}
