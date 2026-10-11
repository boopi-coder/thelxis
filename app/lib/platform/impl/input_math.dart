// Pure, OS-independent helpers shared by the input injectors. Kept free of
// dart:ffi so they are unit-testable on any host (see test/platform/).

import 'dart:ui' show Rect;

import '../host_platform.dart' show MouseButton;

/// Maps a normalized coordinate (0..1) to a pixel index in `0 .. size - 1`.
/// NaN and out-of-range input are clamped so a malformed message can never
/// move the cursor off the display.
int normalizedToPixel(double n, int size) {
  if (size <= 1 || n.isNaN) return 0;
  final c = n < 0 ? 0.0 : (n > 1 ? 1.0 : n);
  return (c * (size - 1)).round();
}

/// Absolute position of the normalized point ([nx], [ny]) on [display], in the
/// same space as [display] (Windows: virtual-desktop px; X11: root px).
({int x, int y}) displayPoint(Rect display, double nx, double ny) {
  return (
    x: display.left.round() + normalizedToPixel(nx, display.width.round()),
    y: display.top.round() + normalizedToPixel(ny, display.height.round()),
  );
}

/// Windows `SendInput` absolute coordinates (0..65535) for a point on
/// [display], normalized over [virtualScreen] (`SM_*VIRTUALSCREEN`) as
/// required by `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`.
///
/// The system maps back with `floor(abs * extent / 65536)`, so `ceil` here is
/// the value that lands exactly on the requested pixel (same trick as
/// AutoHotkey) instead of drifting by one pixel on large desktops.
({int x, int y}) windowsAbsoluteMouse(
  Rect display,
  Rect virtualScreen,
  double nx,
  double ny,
) {
  final p = displayPoint(display, nx, ny);
  return (
    x: _toAbsolute(
      p.x - virtualScreen.left.round(),
      virtualScreen.width.round(),
    ),
    y: _toAbsolute(
      p.y - virtualScreen.top.round(),
      virtualScreen.height.round(),
    ),
  );
}

int _toAbsolute(int pixel, int extent) {
  if (extent <= 0) return 0;
  final v = (pixel * 65536 + extent - 1) ~/ extent;
  return v < 0 ? 0 : (v > 65535 ? 65535 : v);
}

/// macOS global point (points, origin top-left of the main display) for a
/// normalized position on [display]. Unlike pixel APIs it keeps sub-point
/// precision and stays strictly inside the display so the cursor never lands
/// on a neighbouring one.
({double x, double y}) macGlobalPoint(Rect display, double nx, double ny) {
  double axis(double n, double origin, double extent) {
    final c = n.isNaN ? 0.0 : (n < 0 ? 0.0 : (n > 1 ? 1.0 : n));
    final max = extent > 1 ? extent - 1 : 0.0;
    return origin + c * max;
  }

  return (
    x: axis(nx, display.left, display.width),
    y: axis(ny, display.top, display.height),
  );
}

/// Accumulates fractional wheel movement and releases it in whole units.
///
/// The protocol sends logical pixels (60 px ~ one notch); every OS wants
/// integers in its own unit, so the remainder is carried to the next call
/// instead of being lost (smooth/trackpad scrolling sends tiny deltas).
class WheelAccumulator {
  WheelAccumulator(this.unitsPerPixel);

  /// OS units produced by one logical pixel, e.g. Windows 120 / 60 = 2.0,
  /// X11 notches 1 / 60, macOS pixel scrolling 1.0.
  final double unitsPerPixel;

  double _remainder = 0;

  /// Adds [pixels] and returns the whole units now due (sign preserved).
  int add(double pixels) {
    if (pixels.isNaN || pixels.isInfinite) return 0;
    final total = _remainder + pixels * unitsPerPixel;
    final whole = total.truncate();
    _remainder = total - whole;
    return whole;
  }

  void reset() => _remainder = 0;
}

/// Wheel conversion constants.
const double wheelPixelsPerNotch = 60;
const int windowsWheelDelta = 120;

/// Click counting for macOS (`kCGMouseEventClickState`): the same button
/// pressed again within [interval] and [slop] of the previous press continues
/// the multi-click sequence (2 = double, 3 = triple, ...).
class ClickTracker {
  ClickTracker({
    this.interval = const Duration(milliseconds: 400),
    this.slop = 4,
  });

  final Duration interval;

  /// Max distance (same units as the coordinates) between consecutive presses.
  final double slop;

  MouseButton? _button;
  int _count = 0;
  int _lastDownMs = 0;
  double _lastX = 0;
  double _lastY = 0;

  /// Registers a press and returns its click count (>= 1).
  int down(MouseButton button, double x, double y, int nowMs) {
    final continues =
        _button == button &&
        _count > 0 &&
        nowMs - _lastDownMs <= interval.inMilliseconds &&
        (x - _lastX).abs() <= slop &&
        (y - _lastY).abs() <= slop;
    _count = continues ? _count + 1 : 1;
    _button = button;
    _lastDownMs = nowMs;
    _lastX = x;
    _lastY = y;
    return _count;
  }

  void reset() {
    _button = null;
    _count = 0;
  }
}

/// X11 core pointer button numbers (XTest).
int x11ButtonNumber(MouseButton button) => switch (button) {
  MouseButton.left => 1,
  MouseButton.middle => 2,
  MouseButton.right => 3,
  MouseButton.back => 8,
  MouseButton.forward => 9,
};

/// X11 scroll "buttons": 4 up, 5 down, 6 left, 7 right.
const int x11ScrollUp = 4;
const int x11ScrollDown = 5;
const int x11ScrollLeft = 6;
const int x11ScrollRight = 7;

/// X11 keysym for a Unicode code point: Latin-1 keysyms equal the code point,
/// everything else uses the `0x01000000 | cp` Unicode keysym range.
/// Returns 0 for values that are not valid scalar values.
int x11KeysymForCodePoint(int cp) {
  if (cp < 0x20 || cp == 0x7f || (cp >= 0x80 && cp < 0xa0)) return 0;
  if (cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return 0;
  if (cp <= 0xff) return cp;
  return 0x01000000 | cp;
}

/// Splits [text] into chunks of at most [maxUnits] UTF-16 code units without
/// ever separating a surrogate pair.
List<List<int>> utf16Chunks(String text, int maxUnits) {
  assert(maxUnits >= 2);
  final units = text.codeUnits;
  final chunks = <List<int>>[];
  var i = 0;
  while (i < units.length) {
    var end = i + maxUnits;
    if (end >= units.length) {
      end = units.length;
    } else if (_isHighSurrogate(units[end - 1])) {
      end -= 1;
    }
    chunks.add(units.sublist(i, end));
    i = end;
  }
  return chunks;
}

bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;
