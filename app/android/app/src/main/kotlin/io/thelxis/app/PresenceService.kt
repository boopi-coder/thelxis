package io.thelxis.app

import android.app.Notification
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service (type specialUse, subtype "remote-desktop-availability")
 * that keeps the process alive while "Allow incoming" is on: the app is a
 * listener (signaling WebSocket, embedded STUN/TURN, LAN discovery) and
 * Android would otherwise freeze it shortly after the screen goes off.
 *
 * It does not capture or inject anything; it only holds the process.
 */
class PresenceService : Service() {

    companion object {
        private const val CHANNEL_ID = "thelxis_presence"
        private const val NOTIFICATION_ID = 4202

        // Stopping between startForegroundService() and onStartCommand makes the
        // system crash the app, so such a stop is deferred (see CaptureService).
        @Volatile
        private var starting = false

        @Volatile
        private var running = false

        @Volatile
        private var cancelRequested = false

        /** Starts (or refreshes) the service. Must be called while the app is visible. */
        fun start(context: Context) {
            cancelRequested = false
            if (running) return
            val intent = Intent(context, PresenceService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            starting = true
        }

        fun stop(context: Context) {
            if (starting && !running) {
                cancelRequested = true
                return
            }
            context.stopService(Intent(context, PresenceService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
            starting = false
            if (cancelRequested) {
                cancelRequested = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        } catch (e: Exception) {
            // Started from the background on a release that forbids it.
            starting = false
            stopSelf()
        }
        // The Flutter engine dies with the process; there is nothing to restore.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        starting = false
        cancelRequested = false
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(): Notification {
        Notifications.ensureChannel(
            this,
            CHANNEL_ID,
            getString(R.string.presence_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        )
        val builder = Notifications.builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_thelxis)
            .setContentTitle(getString(R.string.presence_notification_title))
            .setContentText(getString(R.string.presence_notification_text))
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
        Notifications.openAppIntent(this)?.let { builder.setContentIntent(it) }
        return builder.build()
    }
}
