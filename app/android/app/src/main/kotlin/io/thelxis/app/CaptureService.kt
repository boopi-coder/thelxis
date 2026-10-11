package io.thelxis.app

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground service of type mediaProjection. Android 10+ refuses
 * MediaProjectionManager.getMediaProjection() without one, and Android 14+
 * additionally requires that it is started AFTER the user granted the capture
 * consent. See the call-order note in lib/platform/impl/android_host.dart.
 */
class CaptureService : Service() {

    companion object {
        private const val ACTION_STOP = "io.thelxis.app.action.STOP_CAPTURE"
        private const val CHANNEL_ID = "thelxis_capture"
        private const val NOTIFICATION_ID = 4201
        private const val START_TIMEOUT_MS = 5000L

        @Volatile
        var running = false
            private set

        // startForegroundService() returned but onStartCommand has not run yet.
        // Stopping the service in that window makes the system crash the app
        // (ForegroundServiceDidNotStartInTimeException), so a stop is deferred.
        @Volatile
        private var starting = false

        @Volatile
        private var cancelRequested = false

        private val main = Handler(Looper.getMainLooper())
        private var pendingStart: MethodChannel.Result? = null
        private val startTimeout = Runnable {
            completePending(false, "timeout", "the foreground service did not start in time")
        }

        /** Completes [result] once the service has called startForeground(). */
        fun start(context: Context, result: MethodChannel.Result) {
            if (running) {
                result.success(true)
                return
            }
            completePending(false, "superseded", "another start request replaced this one")
            pendingStart = result
            cancelRequested = false
            try {
                val intent = Intent(context, CaptureService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                starting = true
                main.postDelayed(startTimeout, START_TIMEOUT_MS)
            } catch (e: Exception) {
                completePending(false, "start_failed", e.message)
            }
        }

        fun stop(context: Context) {
            completePending(false, "cancelled", "capture was stopped before the service started")
            if (starting && !running) {
                cancelRequested = true // onStartCommand ends the service once it is foreground
                return
            }
            context.stopService(Intent(context, CaptureService::class.java))
            // Order against a quick start() is guaranteed by the system; the
            // flags must not claim "running" for a service that is going away.
            running = false
            starting = false
        }

        // What the notification says about the live session (set by the badge
        // channel). Doubles as the indicator when the overlay badge cannot be
        // shown because "display over other apps" is not granted.
        @Volatile
        private var badgeLabel: String? = null

        @Volatile
        private var badgeSinceMs = 0L

        /**
         * Shows who is connected and a running timer in the screen-sharing
         * notification. Pass a null [label] to restore the default text.
         */
        fun updateBadge(context: Context, label: String?, sinceMs: Long) {
            badgeLabel = label
            badgeSinceMs = sinceMs
            if (!running) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            manager.notify(NOTIFICATION_ID, buildNotification(context))
        }

        @Suppress("DEPRECATION")
        private fun buildNotification(context: Context): Notification {
            Notifications.ensureChannel(
                context,
                CHANNEL_ID,
                context.getString(R.string.capture_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            )
            val stop = PendingIntent.getService(
                context,
                1,
                Intent(context, CaptureService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val label = badgeLabel
            val since = badgeSinceMs
            val builder = Notifications.builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_thelxis)
                .setContentTitle(context.getString(R.string.capture_notification_title))
                .setContentText(label ?: context.getString(R.string.capture_notification_text))
                .setCategory(Notification.CATEGORY_SERVICE)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .addAction(0, context.getString(R.string.capture_notification_stop), stop)
            if (label != null && since > 0L) {
                builder.setShowWhen(true).setWhen(since).setUsesChronometer(true)
            } else {
                builder.setShowWhen(false)
            }
            Notifications.openAppIntent(context)?.let { builder.setContentIntent(it) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
            return builder.build()
        }

        private fun completePending(ok: Boolean, code: String, message: String?) {
            main.removeCallbacks(startTimeout)
            val result = pendingStart ?: return
            pendingStart = null
            if (ok) result.success(true) else result.error(code, message, null)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // Tell Dart first so the session can end cleanly, then go away.
            HostChannel.current?.emitCaptureStopRequested()
            running = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val notification = buildNotification(this)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
            starting = false
            if (cancelRequested) {
                cancelRequested = false
                running = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            completePending(true, "", null)
        } catch (e: Exception) {
            starting = false
            // SecurityException: no consent / missing permission (Android 14+);
            // ForegroundServiceStartNotAllowedException: app is in the background.
            completePending(false, "foreground_failed", e.message)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        starting = false
        cancelRequested = false
        badgeLabel = null
        badgeSinceMs = 0L
        super.onDestroy()
    }
}
