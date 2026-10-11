package io.thelxis.app

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of lib/platform/impl/android_host.dart (channel `io.thelxis/host`).
 * Runs on the platform (main) thread, which is also the thread the
 * accessibility service and the services below live on.
 */
class HostChannel(
    private val appContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "io.thelxis/host"
        private const val REQ_NOTIFICATIONS = 4711

        /** Lets services push events (e.g. "Stop" tapped) to Dart. */
        @Volatile
        var current: HostChannel? = null
            private set

        // Held by the process, not by one channel instance, so a recreated
        // Activity can still release it.
        private var multicastLock: WifiManager.MulticastLock? = null
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Needed only to show the runtime-permission dialog. */
    @Volatile
    var activity: Activity? = null

    private var pendingNotificationResult: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
        current = this
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        if (current === this) current = null
        activity = null
        pendingNotificationResult?.success(false)
        pendingNotificationResult = null
        releaseMulticastLock()
    }

    /** The user pressed "Stop" in the screen-sharing notification. */
    fun emitCaptureStopRequested() {
        mainHandler.post { channel.invokeMethod("captureStopRequested", null) }
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQ_NOTIFICATIONS) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationResult?.success(granted)
        pendingNotificationResult = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            dispatch(call, result)
        } catch (e: Exception) {
            result.error("native_error", e.message, null)
        }
    }

    private fun service(): ThelxisAccessibilityService? = ThelxisAccessibilityService.instance

    private fun MethodCall.number(key: String): Number? = argument<Any>(key) as? Number

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // ---- input (fire-and-forget; silently dropped while the service is off) ----
            "mouseMove" -> {
                val nx = call.number("nx")?.toDouble() ?: 0.0
                val ny = call.number("ny")?.toDouble() ?: 0.0
                // NaN would survive coerceIn and make gesture paths invalid.
                if (nx.isFinite() && ny.isFinite()) service()?.pointerMove(nx, ny)
                result.success(null)
            }
            "mouseButton" -> {
                service()?.pointerButton(
                    call.number("button")?.toInt() ?: 0,
                    call.argument<Boolean>("down") ?: false,
                )
                result.success(null)
            }
            "scroll" -> {
                val dx = call.number("dx")?.toDouble() ?: 0.0
                val dy = call.number("dy")?.toDouble() ?: 0.0
                if (dx.isFinite() && dy.isFinite()) service()?.wheel(dx, dy)
                result.success(null)
            }
            "key" -> {
                service()?.key(
                    call.number("hid")?.toInt() ?: 0,
                    call.argument<Boolean>("down") ?: false,
                )
                result.success(null)
            }
            "text" -> {
                service()?.typeText(call.argument<String>("s") ?: "")
                result.success(null)
            }
            "special" -> {
                val action = call.argument<String>("action") ?: ""
                result.success(service()?.special(action) ?: false)
            }
            "releaseAll" -> {
                service()?.releaseAll()
                result.success(null)
            }

            // ---- permissions ----
            "isAccessibilityEnabled" -> result.success(isAccessibilityServiceEnabled())
            "openAccessibilitySettings" -> {
                val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                appContext.startActivity(intent)
                result.success(null)
            }
            "notificationsGranted" -> result.success(notificationsGranted())
            "requestNotifications" -> requestNotifications(result)

            // ---- display ----
            "displayInfo" -> {
                val (width, height) = DisplayUtil.realSize(appContext)
                result.success(
                    mapOf(
                        "width" to width,
                        "height" to height,
                        "density" to appContext.resources.displayMetrics.density.toDouble(),
                    ),
                )
            }

            // ---- foreground services ----
            "startCaptureService" -> CaptureService.start(appContext, result)
            "stopCaptureService" -> {
                CaptureService.stop(appContext)
                result.success(null)
            }
            "startPresence" -> {
                PresenceService.start(appContext)
                result.success(null)
            }
            "stopPresence" -> {
                PresenceService.stop(appContext)
                result.success(null)
            }

            // ---- Wi-Fi multicast (LAN discovery, SSDP/UPnP) ----
            "acquireMulticastLock" -> {
                result.success(acquireMulticastLock())
            }
            "releaseMulticastLock" -> {
                releaseMulticastLock()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ---- permissions -------------------------------------------------------

    /**
     * Our service is enabled when the system lists it in
     * ENABLED_ACCESSIBILITY_SERVICES (or it is already connected).
     */
    private fun isAccessibilityServiceEnabled(): Boolean {
        if (ThelxisAccessibilityService.instance != null) return true
        val enabled = Settings.Secure.getString(
            appContext.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        val self = ComponentName(appContext, ThelxisAccessibilityService::class.java)
        // Entries are flattened component names separated by ':'; the short
        // form "pkg/.Class" is expanded by unflattenFromString.
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == self }
    }

    private fun notificationsGranted(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        }
        val manager = appContext.getSystemService(NotificationManager::class.java)
        return manager?.areNotificationsEnabled() ?: true
    }

    private fun requestNotifications(result: MethodChannel.Result) {
        if (notificationsGranted()) {
            result.success(true)
            return
        }
        val host = activity
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || host == null) {
            // Before Android 13 there is no runtime prompt: send the user to the
            // app's notification settings instead.
            openNotificationSettings()
            result.success(false)
            return
        }
        pendingNotificationResult?.success(false)
        pendingNotificationResult = result
        host.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS)
    }

    private fun openNotificationSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, appContext.packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.fromParts("package", appContext.packageName, null))
        }
        appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    // ---- multicast lock ----------------------------------------------------

    private fun acquireMulticastLock(): Boolean {
        val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return false
        val lock = multicastLock ?: wifi.createMulticastLock("thelxis-multicast").also {
            it.setReferenceCounted(false)
            multicastLock = it
        }
        if (!lock.isHeld) lock.acquire()
        return lock.isHeld
    }

    private fun releaseMulticastLock() {
        val lock = multicastLock ?: return
        if (lock.isHeld) lock.release()
    }
}
