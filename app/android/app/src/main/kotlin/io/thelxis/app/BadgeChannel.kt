package io.thelxis.app

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Channel `io.thelxis/badge` (see lib/platform/impl/badge_args.dart):
 *   show {label, stopLabel, sinceMs, controlActive, peers} / dismiss
 *   native -> Dart: stopPressed
 *
 * `show` always updates the screen-sharing notification and additionally
 * shows the overlay when the "display over other apps" permission is granted.
 */
class BadgeChannel(
    private val appContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "io.thelxis/badge"
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val overlay = SessionBadgeOverlay(appContext) {
        channel.invokeMethod("stopPressed", null)
    }

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        overlay.hide()
        CaptureService.updateBadge(appContext, null, 0L)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "show" -> {
                    val label = call.argument<String>("label") ?: ""
                    val stopLabel = call.argument<String>("stopLabel") ?: ""
                    val sinceMs = (call.argument<Any>("sinceMs") as? Number)?.toLong()
                        ?: System.currentTimeMillis()
                    val control = call.argument<Boolean>("controlActive") ?: false
                    CaptureService.updateBadge(appContext, label, sinceMs)
                    // true = overlay visible; false = only the notification shows it.
                    result.success(overlay.show(label, stopLabel, sinceMs, control))
                }
                "dismiss" -> {
                    overlay.hide()
                    CaptureService.updateBadge(appContext, null, 0L)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("badge_error", e.message, null)
        }
    }
}
