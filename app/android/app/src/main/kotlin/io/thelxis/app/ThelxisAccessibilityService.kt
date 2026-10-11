package io.thelxis.app

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Input injection for the Android host. Everything the remote viewer does
 * arrives here through [HostChannel]:
 *  - pointer -> gestures ([TouchSynthesizer]); right/back button -> Back
 *  - wheel   -> short swipe
 *  - txt     -> ACTION_SET_TEXT on the focused input field
 *  - keys    -> Backspace/Delete/Enter/arrows edit the focused field, Escape = Back
 *  - sp      -> global actions (Back, Home, Recents, Notifications, Power, Lock)
 *
 * The system instantiates the service; [instance] is how the channel finds it.
 * All calls arrive on the main thread.
 */
class ThelxisAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: ThelxisAccessibilityService? = null
            private set

        // USB HID usages (usage page 0x07).
        private const val HID_ENTER = 0x00070028
        private const val HID_ESCAPE = 0x00070029
        private const val HID_BACKSPACE = 0x0007002a
        private const val HID_DELETE = 0x0007004c
        private const val HID_RIGHT = 0x0007004f
        private const val HID_LEFT = 0x00070050
        private const val HID_KEYPAD_ENTER = 0x00070058
    }

    private var touch: TouchSynthesizer? = null

    // Normalized mouse position converted to pixels; the press happens here.
    private var pointerX = -1f
    private var pointerY = -1f

    // Password fields report masked text, so their content is tracked here.
    private var shadowKey: String? = null
    private var shadowText = ""

    override fun onServiceConnected() {
        super.onServiceConnected()
        touch = TouchSynthesizer(this)
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Events are subscribed only to keep the node cache fresh; nothing to do.
    }

    override fun onInterrupt() {
        touch?.releaseAll()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        teardown()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    private fun teardown() {
        if (instance === this) instance = null
        touch?.shutdown()
        touch = null
    }

    // ---- pointer -----------------------------------------------------------

    fun pointerMove(nx: Double, ny: Double) {
        val (width, height) = DisplayUtil.realSize(this)
        if (width <= 0 || height <= 0) return
        pointerX = (nx.coerceIn(0.0, 1.0) * (width - 1)).toFloat()
        pointerY = (ny.coerceIn(0.0, 1.0) * (height - 1)).toFloat()
        touch?.move(pointerX, pointerY)
    }

    /** [button]: 0 left, 1 middle, 2 right, 3 back, 4 forward (PROTOCOL.md). */
    fun pointerButton(button: Int, down: Boolean) {
        val synth = touch ?: return
        when (button) {
            0 -> {
                if (pointerX < 0f) {
                    val (width, height) = DisplayUtil.realSize(this)
                    pointerX = width / 2f
                    pointerY = height / 2f
                }
                if (down) synth.down(pointerX, pointerY) else synth.up(pointerX, pointerY)
            }
            // Touch screens have no secondary buttons; map them to Back.
            2, 3 -> if (down) performGlobalAction(GLOBAL_ACTION_BACK)
            else -> Unit
        }
    }

    fun wheel(dx: Double, dy: Double) {
        touch?.wheel(dx, dy)
    }

    fun releaseAll() {
        touch?.releaseAll()
    }

    // ---- special actions ---------------------------------------------------

    /** [action] is the SpecialAction enum name sent by Dart. Returns whether it was performed. */
    fun special(action: String): Boolean = when (action) {
        "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
        "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
        "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
        "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
        "power" -> performGlobalAction(GLOBAL_ACTION_POWER_DIALOG)
        "lock" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
            } else {
                false
            }
        else -> false // ctrlAltDel has no Android equivalent
    }

    // ---- keyboard ----------------------------------------------------------

    /** Hardware-style keys that are not plain text (those arrive through [typeText]). */
    fun key(hid: Int, down: Boolean) {
        if (!down) return
        when (hid) {
            HID_ESCAPE -> performGlobalAction(GLOBAL_ACTION_BACK)
            HID_ENTER, HID_KEYPAD_ENTER -> pressEnter()
            HID_BACKSPACE -> editFocused { f -> deleteAround(f, backward = true) }
            HID_DELETE -> editFocused { f -> deleteAround(f, backward = false) }
            HID_LEFT -> moveCaret(-1)
            HID_RIGHT -> moveCaret(1)
        }
    }

    /** Inserts [text] at the caret of the focused input field. */
    fun typeText(text: String): Boolean {
        if (text.isEmpty()) return true
        return editFocused { f ->
            val updated = f.text.substring(0, f.start) + text + f.text.substring(f.end)
            Edit(updated, f.start + text.length)
        }
    }

    private fun pressEnter() {
        withFocusedInput { node ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
            } else if (node.isMultiLine) {
                val f = readField(node)
                val updated = f.text.substring(0, f.start) + "\n" + f.text.substring(f.end)
                writeField(node, updated, f.start + 1)
            } else {
                false
            }
        }
    }

    private fun moveCaret(delta: Int) {
        withFocusedInput { node ->
            node.refresh()
            val f = readField(node)
            val caret = if (f.start != f.end) {
                if (delta < 0) f.start else f.end
            } else {
                (f.start + delta).coerceIn(0, f.text.length)
            }
            setSelection(node, caret)
        }
    }

    // ---- focused-field editing --------------------------------------------

    private class Field(val text: String, val start: Int, val end: Int)

    private class Edit(val text: String, val caret: Int)

    /** Runs [edit] against the focused input field; false if there is none. */
    private fun editFocused(edit: (Field) -> Edit?): Boolean {
        return withFocusedInput { node ->
            if (!node.isEditable) return@withFocusedInput false
            node.refresh() // the cache may lag behind rapid typing
            val result = edit(readField(node)) ?: return@withFocusedInput false
            writeField(node, result.text, result.caret)
        } ?: false
    }

    private fun deleteAround(field: Field, backward: Boolean): Edit? {
        val text = field.text
        if (field.start != field.end) {
            return Edit(text.substring(0, field.start) + text.substring(field.end), field.start)
        }
        if (backward) {
            if (field.start == 0) return null
            var from = field.start - 1
            // Remove a surrogate pair as one character.
            if (from > 0 && Character.isLowSurrogate(text[from]) &&
                Character.isHighSurrogate(text[from - 1])
            ) {
                from -= 1
            }
            return Edit(text.substring(0, from) + text.substring(field.start), from)
        }
        if (field.start >= text.length) return null
        var to = field.start + 1
        if (to < text.length && Character.isHighSurrogate(text[to - 1]) &&
            Character.isLowSurrogate(text[to])
        ) {
            to += 1
        }
        return Edit(text.substring(0, field.start) + text.substring(to), field.start)
    }

    private fun <T> withFocusedInput(block: (AccessibilityNodeInfo) -> T): T? {
        val root = rootInActiveWindow ?: return null
        try {
            val node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return null
            try {
                return block(node)
            } finally {
                recycleNode(node)
            }
        } finally {
            recycleNode(root)
        }
    }

    @Suppress("DEPRECATION")
    private fun recycleNode(node: AccessibilityNodeInfo) {
        try {
            node.recycle()
        } catch (e: IllegalStateException) {
            // Already recycled (findFocus can return the root itself).
        }
    }

    private fun readField(node: AccessibilityNodeInfo): Field {
        val text = currentText(node)
        var start = node.textSelectionStart
        var end = node.textSelectionEnd
        if (node.isPassword || start < 0 || end < 0 || start > text.length || end > text.length) {
            start = text.length
            end = start
        }
        if (start > end) {
            val swap = start
            start = end
            end = swap
        }
        return Field(text, start, end)
    }

    private fun currentText(node: AccessibilityNodeInfo): String {
        if (node.isPassword) {
            // The reported text is bullets; use what we typed. A mismatch in
            // length means the user typed locally, so start over.
            val key = "${node.windowId}/${node.viewIdResourceName}"
            val maskedLength = node.text?.length ?: 0
            if (key != shadowKey || maskedLength != shadowText.length) {
                shadowKey = key
                shadowText = ""
            }
            return shadowText
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && node.isShowingHintText) return ""
        return node.text?.toString() ?: ""
    }

    private fun writeField(node: AccessibilityNodeInfo, text: String, caret: Int): Boolean {
        val args = Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        if (ok) {
            if (node.isPassword) shadowText = text
            setSelection(node, caret)
        }
        return ok
    }

    private fun setSelection(node: AccessibilityNodeInfo, caret: Int): Boolean {
        val args = Bundle()
        args.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, caret)
        args.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, caret)
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
    }
}
