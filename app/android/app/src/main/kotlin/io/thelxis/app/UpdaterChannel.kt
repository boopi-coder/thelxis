package io.thelxis.app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * Channel `io.thelxis/updater`, used by the Dart updater to hand a downloaded
 * (and already signature/SHA-256 verified) APK to the system installer.
 *
 *   canRequestInstalls()        -> bool   "install unknown apps" granted for us
 *   openInstallSettings()       -> void   opens that setting for our package
 *   installApk({path})          -> bool   true once the installer was started
 *
 * The APK must live in `<filesDir>/updates/` (path_provider's
 * getApplicationSupportDirectory() is filesDir on Android); anything else is
 * refused so a bug elsewhere can never feed an arbitrary file to the installer.
 */
class UpdaterChannel(
    private val appContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "io.thelxis/updater"

        /** Must match the <provider> in AndroidManifest.xml. */
        const val AUTHORITY = "io.thelxis.app.updates"
        private const val APK_MIME = "application/vnd.android.package-archive"
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "canRequestInstalls" -> result.success(canRequestInstalls())
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(null)
                }
                "installApk" -> result.success(installApk(call.argument<String>("path")))
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("updater_error", e.message, null)
        }
    }

    private fun canRequestInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext.packageManager.canRequestPackageInstalls()
        } else {
            true // before Android 8 it is one global "unknown sources" switch
        }

    private fun openInstallSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                .setData(Uri.fromParts("package", appContext.packageName, null))
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun installApk(path: String?): Boolean {
        if (path.isNullOrEmpty()) return false
        val apk = try {
            val updatesDir = File(appContext.filesDir, "updates").canonicalFile
            val file = File(path).canonicalFile
            val inside = file.path.startsWith(updatesDir.path + File.separator)
            if (!inside || !file.isFile || !file.name.endsWith(".apk", ignoreCase = true)) return false
            file
        } catch (e: IOException) {
            return false
        }
        return try {
            val uri = FileProvider.getUriForFile(appContext, AUTHORITY, apk)
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, APK_MIME)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: IllegalArgumentException) {
            false // path outside the FileProvider's configured roots
        }
    }
}
