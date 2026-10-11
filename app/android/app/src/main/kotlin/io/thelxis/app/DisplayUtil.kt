package io.thelxis.app

import android.content.Context
import android.hardware.display.DisplayManager
import android.util.DisplayMetrics
import android.view.Display

internal object DisplayUtil {
    /**
     * Real size in pixels of the default display in its current rotation
     * (including system bars). DisplayManager works from any context, unlike
     * the WindowManager of a non-visual one.
     */
    @Suppress("DEPRECATION")
    fun realSize(context: Context): Pair<Int, Int> {
        val manager = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val display = manager.getDisplay(Display.DEFAULT_DISPLAY) ?: return Pair(0, 0)
        val metrics = DisplayMetrics()
        display.getRealMetrics(metrics)
        return Pair(metrics.widthPixels, metrics.heightPixels)
    }
}
