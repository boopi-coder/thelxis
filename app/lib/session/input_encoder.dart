import 'dart:async';

import '../protocol/input_messages.dart';

/// Viewer-side producer of `input` channel messages. Coalesces mouse moves and
/// wheel deltas to at most [maxRateHz] messages per second, always delivers the
/// final position (trailing edge), and tracks held keys/buttons so they can be
/// released when focus is lost.
class InputEncoder {
  InputEncoder(this._send, {this.maxRateHz = 120, Stopwatch? clock})
      : _clock = clock ?? (Stopwatch()..start());

  final void Function(InputMessage message) _send;
  final int maxRateHz;
  final Stopwatch _clock;

  final Set<int> _keys = {};
  final Set<int> _buttons = {};

  MouseMove? _pendingMove;
  double _pendingDx = 0;
  double _pendingDy = 0;
  int _lastMoveUs = -1 << 40;
  int _lastWheelUs = -1 << 40;
  Timer? _moveTimer;
  Timer? _wheelTimer;
  double _lastX = 0.5;
  double _lastY = 0.5;

  int get _intervalUs => 1000000 ~/ maxRateHz;

  Set<int> get heldKeys => Set.unmodifiable(_keys);
  Set<int> get heldButtons => Set.unmodifiable(_buttons);
  bool get hasHeldInput => _keys.isNotEmpty || _buttons.isNotEmpty;

  void mouseMove(double x, double y) {
    _lastX = x;
    _lastY = y;
    _pendingMove = MouseMove(x, y);
    final elapsed = _clock.elapsedMicroseconds - _lastMoveUs;
    if (elapsed >= _intervalUs) {
      _flushMove();
    } else {
      _moveTimer ??= Timer(Duration(microseconds: _intervalUs - elapsed), _flushMove);
    }
  }

  void mouseDown(int button, double x, double y) {
    _flushMove();
    _flushWheel();
    _lastX = x;
    _lastY = y;
    _buttons.add(button);
    _send(MouseDown(button, x, y));
  }

  void mouseUp(int button, double x, double y) {
    _flushMove();
    _flushWheel();
    _lastX = x;
    _lastY = y;
    _buttons.remove(button);
    _send(MouseUp(button, x, y));
  }

  void wheel(double dx, double dy) {
    _pendingDx += dx;
    _pendingDy += dy;
    final elapsed = _clock.elapsedMicroseconds - _lastWheelUs;
    if (elapsed >= _intervalUs) {
      _flushWheel();
    } else {
      _wheelTimer ??= Timer(Duration(microseconds: _intervalUs - elapsed), _flushWheel);
    }
  }

  void keyDown(int code) {
    _flushMove();
    _keys.add(code);
    _send(KeyDown(code));
  }

  void keyUp(int code) {
    _flushMove();
    _keys.remove(code);
    _send(KeyUp(code));
  }

  void text(String text) {
    if (text.isEmpty) return;
    _flushMove();
    _send(TextInput(text));
  }

  void special(String action) {
    _flushMove();
    _send(SpecialInput(action));
  }

  /// Taps a key: down immediately followed by up.
  void tapKey(int code) {
    keyDown(code);
    keyUp(code);
  }

  /// Releases every held key and button (focus lost, view-only toggled, end).
  void releaseAll() {
    _flushMove();
    _flushWheel();
    for (final code in _keys.toList()) {
      _send(KeyUp(code));
    }
    _keys.clear();
    for (final b in _buttons.toList()) {
      _send(MouseUp(b, _lastX, _lastY));
    }
    _buttons.clear();
  }

  void dispose() {
    _moveTimer?.cancel();
    _wheelTimer?.cancel();
    _pendingMove = null;
  }

  void _flushMove() {
    _moveTimer?.cancel();
    _moveTimer = null;
    final m = _pendingMove;
    if (m == null) return;
    _pendingMove = null;
    _lastMoveUs = _clock.elapsedMicroseconds;
    _send(m);
  }

  void _flushWheel() {
    _wheelTimer?.cancel();
    _wheelTimer = null;
    if (_pendingDx == 0 && _pendingDy == 0) return;
    // Bound a single message so a runaway fling cannot scroll a host for ages.
    final dx = _pendingDx.clamp(-1200.0, 1200.0);
    final dy = _pendingDy.clamp(-1200.0, 1200.0);
    _pendingDx = 0;
    _pendingDy = 0;
    _lastWheelUs = _clock.elapsedMicroseconds;
    _send(Wheel(dx, dy));
  }
}
