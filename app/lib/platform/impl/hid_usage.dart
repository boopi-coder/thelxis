// USB HID usage constants (page << 16 | id) used by the injectors, plus the
// small amount of modifier logic that is shared between them.

const int hidEnter = 0x00070028;
const int hidEscape = 0x00070029;
const int hidBackspace = 0x0007002a;
const int hidTab = 0x0007002b;
const int hidCapsLock = 0x00070039;
const int hidPause = 0x00070048;

const int hidLeftCtrl = 0x000700e0;
const int hidLeftShift = 0x000700e1;
const int hidLeftAlt = 0x000700e2;
const int hidLeftGui = 0x000700e3;
const int hidRightCtrl = 0x000700e4;
const int hidRightShift = 0x000700e5;
const int hidRightAlt = 0x000700e6;
const int hidRightGui = 0x000700e7;

/// Whether [usage] is one of the eight keyboard modifier keys.
bool isHidModifier(int usage) => usage >= hidLeftCtrl && usage <= hidRightGui;

/// `CGEventFlags` mask bits (Quartz Event Services).
const int cgFlagAlphaShift = 0x00010000; // caps lock
const int cgFlagShift = 0x00020000;
const int cgFlagControl = 0x00040000;
const int cgFlagAlternate = 0x00080000;
const int cgFlagCommand = 0x00100000;

/// The `CGEventFlags` bit toggled by a modifier [usage], or 0 for any other
/// key. Left and right variants share one bit, which is what apps test.
int macModifierFlag(int usage) => switch (usage) {
  hidLeftCtrl || hidRightCtrl => cgFlagControl,
  hidLeftShift || hidRightShift => cgFlagShift,
  hidLeftAlt || hidRightAlt => cgFlagAlternate,
  hidLeftGui || hidRightGui => cgFlagCommand,
  hidCapsLock => cgFlagAlphaShift,
  _ => 0,
};

/// Tracks which modifier keys are down so the shared `CGEventFlags` can be
/// recomputed correctly when e.g. both Shift keys are held and one is
/// released. Caps lock is a toggle, not a held key.
class MacModifierState {
  final Set<int> _held = <int>{};
  bool _capsLock = false;

  /// Seeds the caps lock state from the system at startup.
  void syncCapsLock(bool on) => _capsLock = on;

  /// Applies a key transition and returns true if [usage] is a modifier.
  bool apply(int usage, bool down) {
    if (usage == hidCapsLock) {
      if (down) _capsLock = !_capsLock;
      return true;
    }
    if (!isHidModifier(usage)) return false;
    if (down) {
      _held.add(usage);
    } else {
      _held.remove(usage);
    }
    return true;
  }

  int get flags {
    var f = _capsLock ? cgFlagAlphaShift : 0;
    for (final u in _held) {
      f |= macModifierFlag(u);
    }
    return f;
  }

  void clear() => _held.clear();
}
