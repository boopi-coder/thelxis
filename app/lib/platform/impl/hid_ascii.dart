// HID usage -> printable character for the US layout. Only the Android host
// needs it: an AccessibilityService can insert text but cannot press keys, so
// a desktop viewer's `kd` for a letter has to become text.

const List<String> _letters = [
  'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', //
  'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
];

const String _digits = '1234567890';
const String _digitsShifted = '!@#\$%^&*()';

/// Usages 0x2c..0x38: space - = [ ] \ (non-US #) ; ' ` , . /
/// The non-US # slot (0x32) is a placeholder that is never returned.
const List<String> _punct = [
  ' ', '-', '=', '[', ']', '\\', '#', ';', "'", '`', ',', '.', '/', //
];
const List<String> _punctShifted = [
  ' ', '_', '+', '{', '}', '|', '~', ':', '"', '~', '<', '>', '?', //
];

/// Keypad usages 0x54..0x63: / * - + enter 1..9 0 .
const String _keypad = '/*-+\n1234567890.';

/// Returns the character typed by [usage], or null when the key does not
/// produce text (modifiers, function keys, arrows, ...). Caps lock only
/// affects letters.
String? asciiForHid(int usage, {required bool shift, required bool caps}) {
  if ((usage >> 16) != 0x07) return null;
  final id = usage & 0xffff;
  if (id >= 0x04 && id <= 0x1d) {
    final c = _letters[id - 0x04];
    return (shift != caps) ? c.toUpperCase() : c;
  }
  if (id >= 0x1e && id <= 0x27) {
    final i = id - 0x1e;
    return shift ? _digitsShifted[i] : _digits[i];
  }
  if (id >= 0x2c && id <= 0x38) {
    final i = id - 0x2c;
    // Real US keyboards have no non-US # key.
    if (id == 0x32) return null;
    return shift ? _punctShifted[i] : _punct[i];
  }
  if (id >= 0x54 && id <= 0x63) {
    final c = _keypad[id - 0x54];
    // Keypad Enter is a key press, not text.
    return c == '\n' ? null : c;
  }
  return null;
}
