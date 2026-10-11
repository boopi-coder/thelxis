import '../platform/host_platform.dart';
import '../protocol/input_messages.dart';

/// Applies viewer input messages to the host's [InputInjector] and remembers
/// what is held down so it can be released on revoke or session end
/// (PROTOCOL.md 6.3). Validates everything: input comes from the network.
class HostInputDispatcher {
  HostInputDispatcher(this._injector);

  final InputInjector _injector;
  final Set<int> _keys = {};
  final Set<int> _buttons = {};

  /// Whether the viewer currently has the control permission.
  bool enabled = false;

  /// Display that normalised coordinates refer to.
  HostDisplay? display;

  Set<int> get heldKeys => Set.unmodifiable(_keys);
  Set<int> get heldButtons => Set.unmodifiable(_buttons);

  void handle(InputMessage m) {
    final d = display;
    if (!enabled || d == null) return;
    switch (m) {
      case MouseMove(:final x, :final y):
        _move(d, x, y);
      case MouseDown(:final button, :final x, :final y):
        if (!_validButton(button)) return;
        _move(d, x, y);
        _buttons.add(button);
        _injector.mouseButton(MouseButton.values[button], true);
      case MouseUp(:final button, :final x, :final y):
        if (!_validButton(button)) return;
        _move(d, x, y);
        _buttons.remove(button);
        _injector.mouseButton(MouseButton.values[button], false);
      case Wheel(:final dx, :final dy):
        if (!dx.isFinite || !dy.isFinite) return;
        _injector.scroll(dx.clamp(-2400.0, 2400.0), dy.clamp(-2400.0, 2400.0));
      case KeyDown(:final code):
        if (!_validKey(code)) return;
        _keys.add(code);
        _injector.key(code, true);
      case KeyUp(:final code):
        if (!_validKey(code)) return;
        _keys.remove(code);
        _injector.key(code, false);
      case TextInput(:final text):
        if (text.isEmpty) return;
        _injector.text(text.length > 4096 ? text.substring(0, 4096) : text);
      case SpecialInput(:final action):
        final a = specialActionFor(action);
        if (a != null) _injector.special(a);
    }
  }

  /// Releases every key and button; call on revoke, end, or display switch.
  void releaseAll() {
    for (final k in _keys.toList()) {
      _injector.key(k, false);
    }
    for (final b in _buttons.toList()) {
      if (_validButton(b)) _injector.mouseButton(MouseButton.values[b], false);
    }
    _keys.clear();
    _buttons.clear();
    _injector.releaseAll();
  }

  void _move(HostDisplay d, double x, double y) {
    if (!x.isFinite || !y.isFinite) return;
    _injector.mouseMove(d, x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
  }

  static bool _validButton(int b) => b >= 0 && b < MouseButton.values.length;

  static bool _validKey(int c) => c > 0 && c <= 0xFFFFFF;
}

/// Wire name to [SpecialAction], or null for unknown actions.
SpecialAction? specialActionFor(String wire) {
  switch (wire) {
    case 'ctrl_alt_del':
      return SpecialAction.ctrlAltDel;
    case 'lock':
      return SpecialAction.lock;
    case 'back':
      return SpecialAction.back;
    case 'home':
      return SpecialAction.home;
    case 'recents':
      return SpecialAction.recents;
    case 'notifications':
      return SpecialAction.notifications;
    case 'power':
      return SpecialAction.power;
  }
  return null;
}
