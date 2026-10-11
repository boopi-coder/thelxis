import 'dart:async';
import 'dart:ui';

/// How a single finger drives the remote pointer on touch devices.
enum TouchMode {
  /// Finger movement moves the cursor relatively, like a laptop trackpad.
  touchpad,

  /// The cursor jumps to and follows the finger (touch = pointer).
  direct,
}

/// Receives high-level actions recognised by [TouchGestureEngine]. Positions
/// are in viewport (logical pixel) coordinates.
abstract class TouchGestureSink {
  /// Touchpad mode: move the virtual cursor by [delta] viewport pixels.
  void cursorMoveBy(Offset delta);

  /// Direct mode: put the cursor under [position].
  void cursorMoveTo(Offset position);

  /// Full click (down+up) of a wire button number at the current cursor.
  void click(int button);

  void buttonDown(int button);
  void buttonUp(int button);

  /// Wheel delta in logical pixels, already in wire direction (dy>0 = down).
  void scroll(Offset wheelDelta);

  /// Pinch zoom around [focal] by [factor], with the gesture centre having
  /// moved by [pan].
  void zoom(Offset focal, double factor, Offset pan);

  /// A long press was recognised; the left button is now held.
  void longPress();
}

/// Turns raw pointer events into trackpad/touchscreen style gestures:
/// tap = left click, two-finger tap = right click, long-press then drag =
/// drag with the left button, two-finger drag = scroll, pinch = zoom.
class TouchGestureEngine {
  TouchGestureEngine({
    required this.sink,
    this.mode = TouchMode.touchpad,
    this.naturalScroll = true,
    this.cursorGain = 1.6,
    this.scrollGain = 1.5,
    this.tapSlop = 10.0,
    this.tapTimeout = const Duration(milliseconds: 300),
    this.longPressDelay = const Duration(milliseconds: 450),
  });

  final TouchGestureSink sink;
  TouchMode mode;
  final bool naturalScroll;
  final double cursorGain;
  final double scrollGain;
  final double tapSlop;
  final Duration tapTimeout;
  final Duration longPressDelay;

  final Map<int, Offset> _pos = {};
  int? _primary;
  Offset _start = Offset.zero;
  Duration _startTime = Duration.zero;
  bool _moved = false;
  bool _longPressed = false;
  Timer? _longPressTimer;

  // Two-finger state.
  bool _two = false;
  bool _twoMoved = false;
  bool _twoZoom = false;
  bool _twoScroll = false;
  Duration _twoStartTime = Duration.zero;
  double _twoStartDistance = 0;
  double _twoLastDistance = 0;
  Offset _twoLastCentroid = Offset.zero;
  Offset _twoStartCentroid = Offset.zero;

  bool get isActive => _pos.isNotEmpty;

  void pointerDown(int id, Offset position, Duration time) {
    _pos[id] = position;
    if (_pos.length == 1) {
      _primary = id;
      _start = position;
      _startTime = time;
      _moved = false;
      _longPressed = false;
      _two = false;
      if (mode == TouchMode.direct) sink.cursorMoveTo(position);
      _longPressTimer?.cancel();
      _longPressTimer = Timer(longPressDelay, _onLongPress);
    } else if (_pos.length == 2 && !_longPressed) {
      _longPressTimer?.cancel();
      _two = true;
      _twoMoved = false;
      _twoZoom = false;
      _twoScroll = false;
      _twoStartTime = time;
      final pts = _pos.values.toList();
      _twoStartDistance = (pts[0] - pts[1]).distance;
      _twoLastDistance = _twoStartDistance;
      _twoStartCentroid = _twoLastCentroid = _centroid();
    }
  }

  void pointerMove(int id, Offset position, Duration time) {
    final previous = _pos[id];
    if (previous == null) return;
    _pos[id] = position;

    if (_two) {
      _moveTwo();
      return;
    }
    if (id != _primary || _pos.length != 1) return;

    if (!_moved && (position - _start).distance > tapSlop) {
      _moved = true;
      if (!_longPressed) _longPressTimer?.cancel();
    }
    if (mode == TouchMode.touchpad) {
      sink.cursorMoveBy((position - previous) * cursorGain);
    } else {
      sink.cursorMoveTo(position);
    }
  }

  void pointerUp(int id, Offset position, Duration time) {
    if (!_pos.containsKey(id)) return;
    _pos[id] = position;
    _longPressTimer?.cancel();

    if (_two) {
      final wasTap = !_twoMoved && time - _twoStartTime < tapTimeout;
      final centroid = _centroid();
      _pos.remove(id);
      if (_pos.length < 2) {
        _two = false;
        if (wasTap) {
          if (mode == TouchMode.direct) sink.cursorMoveTo(centroid);
          sink.click(2);
        }
        // A remaining finger must not turn into a tap or drag.
        _primary = null;
        _moved = true;
      }
      if (_pos.isEmpty) _primary = null;
      return;
    }

    _pos.remove(id);
    if (id != _primary) return;
    if (_longPressed) {
      sink.buttonUp(0);
    } else if (!_moved && time - _startTime < tapTimeout) {
      if (mode == TouchMode.direct) sink.cursorMoveTo(position);
      sink.click(0);
    }
    _primary = null;
    _longPressed = false;
  }

  void pointerCancel(int id) {
    if (_longPressed && id == _primary) sink.buttonUp(0);
    _pos.remove(id);
    _longPressTimer?.cancel();
    if (_pos.isEmpty) {
      _primary = null;
      _longPressed = false;
      _two = false;
    }
  }

  void dispose() {
    _longPressTimer?.cancel();
    if (_longPressed) sink.buttonUp(0);
    _longPressed = false;
    _pos.clear();
  }

  void _onLongPress() {
    if (_primary == null || _moved || _two || _pos.length != 1) return;
    _longPressed = true;
    sink.longPress();
    sink.buttonDown(0);
  }

  Offset _centroid() {
    var sum = Offset.zero;
    for (final p in _pos.values) {
      sum += p;
    }
    return sum / _pos.length.toDouble();
  }

  void _moveTwo() {
    if (_pos.length < 2) return;
    final pts = _pos.values.take(2).toList();
    final distance = (pts[0] - pts[1]).distance;
    final centroid = _centroid();
    final pan = centroid - _twoLastCentroid;

    if (!_twoZoom && !_twoScroll) {
      final spread = (distance - _twoStartDistance).abs();
      final travel = (centroid - _twoStartCentroid).distance;
      if (spread > 24 && spread > travel) {
        _twoZoom = true;
        _twoMoved = true;
      } else if (travel > 14) {
        _twoScroll = true;
        _twoMoved = true;
      }
    }

    if (_twoZoom) {
      final factor = _twoLastDistance > 0 ? distance / _twoLastDistance : 1.0;
      sink.zoom(centroid, factor, pan);
    } else if (_twoScroll) {
      final sign = naturalScroll ? -1.0 : 1.0;
      sink.scroll(Offset(pan.dx * sign, pan.dy * sign) * scrollGain);
    }
    _twoLastDistance = distance;
    _twoLastCentroid = centroid;
  }
}
