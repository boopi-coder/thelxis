package io.thelxis.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import java.util.ArrayDeque
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Turns the mouse stream into AccessibilityService gestures.
 *
 * Android 8+: a press starts a stroke with `willContinue = true`, every move
 * (throttled to ~16 ms) is a continuation stroke, the release is a final
 * continuation with `willContinue = false`. The finger stays "down" between
 * segments, so taps, long-presses (just hold) and drags all fall out of the
 * same mechanism and a press is felt by the target app immediately.
 *
 * Android 7.x has no continued strokes: the whole drag is remembered and
 * replayed as one gesture on release (tap, long-press or swipe).
 *
 * Gestures are asynchronous and only one may be in flight, so pointer events
 * go through a small FIFO that is drained as each gesture completes. Runs on
 * the main thread only.
 */
internal class TouchSynthesizer(private val service: AccessibilityService) {

    private enum class Kind { DOWN, MOVE, UP }

    private class Op(val kind: Kind, val x: Float, val y: Float)

    private val handler = Handler(Looper.getMainLooper())
    private val queue = ArrayDeque<Op>()
    private val pumpRunnable = Runnable { pump() }

    /** Bumped by reset() so late callbacks of abandoned gestures are ignored. */
    private var generation = 0
    private var inFlight = false

    // Android 8+ continued-stroke chain.
    private var active = false
    private var stroke: GestureDescription.StrokeDescription? = null
    private var lastX = 0f
    private var lastY = 0f
    private var lastDispatchAt = 0L

    // Android 7.x fallback.
    private val legacyPoints = ArrayList<Float>()
    private var legacyDownAt = 0L

    // Wheel -> swipe.
    private var wheelInFlight = false
    private var wheelDx = 0.0
    private var wheelDy = 0.0

    /** Last known pointer position in pixels; the origin of wheel swipes. */
    var pointerX = -1f
        private set
    var pointerY = -1f
        private set

    // ---- pointer API -------------------------------------------------------

    fun down(x: Float, y: Float) {
        setPointer(x, y)
        enqueue(Op(Kind.DOWN, x, y))
    }

    fun move(x: Float, y: Float) {
        setPointer(x, y)
        if (!active && queue.isEmpty()) return // hovering: no touch to move
        // Only the latest position matters; keep the queue short.
        if (queue.peekLast()?.kind == Kind.MOVE) queue.pollLast()
        enqueue(Op(Kind.MOVE, x, y))
    }

    fun up(x: Float, y: Float) {
        setPointer(x, y)
        if (!active && queue.isEmpty()) return
        enqueue(Op(Kind.UP, x, y))
    }

    /** Lifts the finger (if down) at the last position and forgets pending wheel input. */
    fun releaseAll() {
        wheelDx = 0.0
        wheelDy = 0.0
        if (active || queue.isNotEmpty()) up(pointerX.coerceAtLeast(0f), pointerY.coerceAtLeast(0f))
    }

    /** Drops everything (service going away). */
    fun shutdown() {
        reset()
        wheelDx = 0.0
        wheelDy = 0.0
    }

    private fun setPointer(x: Float, y: Float) {
        pointerX = x
        pointerY = y
    }

    private fun enqueue(op: Op) {
        queue.addLast(op)
        if (queue.size > MAX_QUEUE) {
            // A stalled system: shed the oldest moves rather than grow without bound.
            val iter = queue.iterator()
            while (iter.hasNext() && queue.size > MAX_QUEUE) {
                if (iter.next().kind == Kind.MOVE) iter.remove()
            }
        }
        pump()
    }

    // ---- queue draining ----------------------------------------------------

    private fun pump() {
        if (inFlight) return
        val op = queue.peekFirst() ?: return
        when (op.kind) {
            Kind.DOWN -> {
                queue.pollFirst()
                begin(op)
            }
            Kind.MOVE -> {
                if (!active) {
                    queue.pollFirst() // stray move after a cancelled gesture
                    pump()
                    return
                }
                val wait = lastDispatchAt + MOVE_INTERVAL_MS - SystemClock.uptimeMillis()
                if (wait > 0) {
                    handler.removeCallbacks(pumpRunnable)
                    handler.postDelayed(pumpRunnable, wait)
                    return
                }
                queue.pollFirst()
                extend(op)
            }
            Kind.UP -> {
                queue.pollFirst()
                end(op)
            }
        }
    }

    private fun begin(op: Op) {
        if (active) reset() // a previous press never got its release
        lastX = op.x
        lastY = op.y
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val path = Path().apply { moveTo(op.x, op.y) }
            val first = GestureDescription.StrokeDescription(path, 0, FIRST_STROKE_MS, true)
            if (dispatch(first, false)) {
                active = true
                stroke = first
            } else {
                reset()
            }
        } else {
            active = true
            legacyDownAt = SystemClock.uptimeMillis()
            legacyPoints.clear()
            legacyPoints.add(op.x)
            legacyPoints.add(op.y)
        }
    }

    private fun extend(op: Op) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (op.x == lastX && op.y == lastY) {
                pump()
                return
            }
            val previous = stroke
            if (previous == null) {
                reset()
                return
            }
            val path = Path().apply {
                moveTo(lastX, lastY)
                lineTo(op.x, op.y)
            }
            val next = previous.continueStroke(path, 0, MOVE_STROKE_MS, true)
            if (dispatch(next, false)) {
                stroke = next
                lastX = op.x
                lastY = op.y
            } else {
                reset()
            }
        } else {
            if (legacyPoints.size < LEGACY_MAX_VALUES) {
                legacyPoints.add(op.x)
                legacyPoints.add(op.y)
            }
            pump()
        }
    }

    private fun end(op: Op) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val previous = stroke
            if (previous == null) {
                reset()
                return
            }
            val path = Path().apply {
                moveTo(lastX, lastY)
                if (op.x != lastX || op.y != lastY) lineTo(op.x, op.y)
            }
            val last = previous.continueStroke(path, 0, FINAL_STROKE_MS, false)
            if (!dispatch(last, true)) reset()
        } else {
            endLegacy(op)
        }
    }

    /** Android 7.x: replay the remembered press as a single gesture. */
    private fun endLegacy(op: Op) {
        legacyPoints.add(op.x)
        legacyPoints.add(op.y)
        val heldMs = SystemClock.uptimeMillis() - legacyDownAt
        val startX = legacyPoints[0]
        val startY = legacyPoints[1]
        val moved = hypot(op.x - startX, op.y - startY) > TAP_SLOP_PX
        val path = Path()
        path.moveTo(startX, startY)
        val duration: Long
        if (moved) {
            // Sub-sample long drags so the path stays small.
            val pairs = legacyPoints.size / 2
            val step = max(1, pairs / 24)
            var i = step
            while (i < pairs) {
                path.lineTo(legacyPoints[i * 2], legacyPoints[i * 2 + 1])
                i += step
            }
            path.lineTo(op.x, op.y)
            duration = heldMs.coerceIn(100L, 4000L)
        } else {
            duration = if (heldMs >= LONG_PRESS_MS) heldMs.coerceAtMost(4000L) else TAP_MS
        }
        val gesture = try {
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
                .build()
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "legacy gesture rejected", e)
            reset()
            return
        }
        if (!dispatchGesture(gesture, true)) reset()
    }

    // ---- dispatching -------------------------------------------------------

    private fun dispatch(stroke: GestureDescription.StrokeDescription, isFinal: Boolean): Boolean {
        val gesture = try {
            GestureDescription.Builder().addStroke(stroke).build()
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "gesture rejected", e)
            return false
        }
        return dispatchGesture(gesture, isFinal)
    }

    private fun dispatchGesture(gesture: GestureDescription, isFinal: Boolean): Boolean {
        val gen = generation
        inFlight = true
        lastDispatchAt = SystemClock.uptimeMillis()
        val accepted = service.dispatchGesture(
            gesture,
            object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    if (gen != generation) return
                    inFlight = false
                    if (isFinal) {
                        active = false
                        stroke = null
                    }
                    pump()
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    // A real touch or another gesture interrupted ours: the finger
                    // is up as far as Android is concerned.
                    if (gen != generation) return
                    reset()
                }
            },
            handler,
        )
        if (!accepted) inFlight = false
        return accepted
    }

    private fun reset() {
        generation++
        inFlight = false
        active = false
        stroke = null
        queue.clear()
        legacyPoints.clear()
        handler.removeCallbacks(pumpRunnable)
    }

    // ---- wheel -------------------------------------------------------------

    /**
     * Mouse wheel -> a short swipe from the pointer. [dx]/[dy] are logical
     * pixels, positive = content scrolls right/down, so the finger moves the
     * opposite way. Input arriving while a swipe is running is accumulated.
     */
    fun wheel(dx: Double, dy: Double) {
        wheelDx += dx
        wheelDy += dy
        flushWheel()
    }

    private fun flushWheel() {
        if (wheelInFlight || inFlight || active) return
        if (abs(wheelDx) < WHEEL_MIN_LOGICAL && abs(wheelDy) < WHEEL_MIN_LOGICAL) return
        val (width, height) = DisplayUtil.realSize(service)
        if (width <= 0 || height <= 0) return
        val density = service.resources.displayMetrics.density.toDouble()

        val maxX = width * WHEEL_MAX_FRACTION
        val maxY = height * WHEEL_MAX_FRACTION
        val moveX = (-wheelDx * density).coerceIn(-maxX, maxX)
        val moveY = (-wheelDy * density).coerceIn(-maxY, maxY)
        // Logical pixels actually used by this swipe; the rest stays accumulated.
        wheelDx += moveX / density
        wheelDy += moveY / density

        val originX = if (pointerX >= 0f) pointerX else width / 2f
        val originY = if (pointerY >= 0f) pointerY else height / 2f
        val (startX, endX) = fit(originX, moveX.toFloat(), width)
        val (startY, endY) = fit(originY, moveY.toFloat(), height)

        val distance = hypot((endX - startX).toDouble(), (endY - startY).toDouble())
        val duration = (WHEEL_BASE_MS + distance / 3.0).toLong().coerceIn(WHEEL_BASE_MS, WHEEL_MAX_MS)
        val path = Path()
        path.moveTo(startX, startY)
        path.lineTo(endX, endY)
        val gesture = try {
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
                .build()
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "wheel gesture rejected", e)
            return
        }
        wheelInFlight = true
        val accepted = service.dispatchGesture(
            gesture,
            object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    wheelInFlight = false
                    flushWheel()
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    wheelInFlight = false
                    wheelDx = 0.0
                    wheelDy = 0.0
                }
            },
            handler,
        )
        if (!accepted) wheelInFlight = false
    }

    /** Places a swipe of [delta] pixels starting near [start] fully inside [size]. */
    private fun fit(start: Float, delta: Float, size: Int): Pair<Float, Float> {
        val low = EDGE_MARGIN_PX
        val high = size - EDGE_MARGIN_PX
        var s = start.coerceIn(low, max(low, high))
        var e = s + delta
        if (e < low) {
            val shift = low - e
            s += shift
            e += shift
        } else if (e > high) {
            val shift = e - high
            s -= shift
            e -= shift
        }
        return Pair(min(s, size - 1f), min(e, size - 1f).coerceAtLeast(0f))
    }

    private companion object {
        const val TAG = "ThelxisTouch"

        /** Duration of the first stroke; the finger then stays down until continued. */
        const val FIRST_STROKE_MS = 20L
        const val MOVE_STROKE_MS = 16L
        const val FINAL_STROKE_MS = 20L
        const val MOVE_INTERVAL_MS = 16L
        const val MAX_QUEUE = 64

        // Android 7.x replay.
        const val TAP_MS = 50L
        const val LONG_PRESS_MS = 500L
        const val TAP_SLOP_PX = 12f
        const val LEGACY_MAX_VALUES = 800

        // Wheel swipes.
        const val WHEEL_MIN_LOGICAL = 10.0
        const val WHEEL_MAX_FRACTION = 0.45
        const val WHEEL_BASE_MS = 120L
        const val WHEEL_MAX_MS = 450L
        const val EDGE_MARGIN_PX = 8f
    }
}
