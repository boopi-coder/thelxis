package io.thelxis.app

import android.content.Context
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.min

/**
 * The "being controlled" badge as an overlay window (TYPE_APPLICATION_OVERLAY).
 * Needs the "display over other apps" permission; without it [show] returns
 * false and the ongoing screen-sharing notification (which carries the same
 * label and a chronometer, see [CaptureService.updateBadge]) is the indicator.
 *
 * The overlay is not marked FLAG_SECURE: that would turn it into a black
 * rectangle in the viewer's picture instead of excluding it. Main thread only.
 */
internal class SessionBadgeOverlay(
    private val appContext: Context,
    private val onStop: () -> Unit,
) {
    private val windowManager = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val handler = Handler(Looper.getMainLooper())
    private val density = appContext.resources.displayMetrics.density

    private var root: LinearLayout? = null
    private var labelView: TextView? = null
    private var timerView: TextView? = null
    private var background: GradientDrawable? = null
    private var sinceMs = 0L

    private val ticker = object : Runnable {
        override fun run() {
            updateTimer()
            handler.postDelayed(this, 1000L)
        }
    }

    /** Returns false when nothing could be shown (permission missing or addView failed). */
    fun show(label: String, stopLabel: String, sinceMs: Long, controlActive: Boolean): Boolean {
        if (!Settings.canDrawOverlays(appContext)) {
            hide()
            return false
        }
        this.sinceMs = sinceMs
        if (root == null) createView()
        if (root == null) return false // addView failed (permission just revoked)
        labelView?.text = label
        applyAccent(controlActive)
        updateTimer()
        handler.removeCallbacks(ticker)
        handler.postDelayed(ticker, 1000L)
        return true
    }

    fun hide() {
        handler.removeCallbacks(ticker)
        val view = root ?: return
        root = null
        labelView = null
        timerView = null
        background = null
        try {
            windowManager.removeView(view)
        } catch (e: IllegalArgumentException) {
            // Already detached (permission revoked while shown).
        }
    }

    private fun dp(value: Int): Int = (value * density + 0.5f).toInt()

    private fun createView() {
        val bg = GradientDrawable().apply {
            cornerRadius = dp(14).toFloat()
            setColor(0xE61C1A2E.toInt())
        }
        background = bg

        val icon = ImageView(appContext).apply {
            setImageDrawable(appContext.packageManager.getApplicationIcon(appContext.packageName))
            layoutParams = LinearLayout.LayoutParams(dp(32), dp(32))
        }
        val label = TextView(appContext).apply {
            setTextColor(0xFFFFFFFF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTypeface(typeface, Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        val timer = TextView(appContext).apply {
            setTextColor(0xB3FFFFFF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            fontFeatureSettings = "tnum"
            maxLines = 1
        }
        val column = LinearLayout(appContext).apply {
            orientation = LinearLayout.VERTICAL
            addView(label)
            addView(timer)
        }
        val container = LinearLayout(appContext).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(8))
            this.background = bg
            addView(icon)
            addView(
                column,
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    marginStart = dp(10)
                    marginEnd = dp(8)
                },
            )
        }

        val screenWidth = appContext.resources.displayMetrics.widthPixels
        val params = WindowManager.LayoutParams(
            min(dp(300), screenWidth - dp(32)),
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            // Display-only: injected remote taps must never land on it (they would
            // end the session by accident) and it must not block the local user's
            // touches. Stop lives in the ongoing capture notification instead.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = dp(16)
            // Already laid out below the status bar; only a small gap is needed.
            y = dp(8)
        }

        try {
            windowManager.addView(container, params)
        } catch (e: RuntimeException) {
            // BadTokenException / SecurityException: permission revoked in the meantime.
            return
        }
        root = container
        labelView = label
        timerView = timer
    }

    @Suppress("DEPRECATION")
    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            WindowManager.LayoutParams.TYPE_PHONE
        }

    /** View-only: soft violet outline. Control allowed: strong red outline. */
    private fun applyAccent(controlActive: Boolean) {
        val color = if (controlActive) 0xFFFF5A5F.toInt() else 0x806C4CF5.toInt()
        background?.setStroke(dp(if (controlActive) 2 else 1), color)
    }

    private fun updateTimer() {
        val elapsedSeconds = ((System.currentTimeMillis() - sinceMs) / 1000L).coerceAtLeast(0L)
        val h = elapsedSeconds / 3600
        val m = (elapsedSeconds % 3600) / 60
        val s = elapsedSeconds % 60
        timerView?.text = String.format(java.util.Locale.ROOT, "%02d:%02d:%02d", h, m, s)
    }
}
