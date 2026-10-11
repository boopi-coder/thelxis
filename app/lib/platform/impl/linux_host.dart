// Linux host: input via X11 XTest (Dart FFI), displays via XRandR monitors.
//
// Wayland sessions cannot be injected into (v0.1): `inputSupported` is false
// there and the session falls back to view-only, while capture still works
// through libwebrtc/PipeWire (`hostSupported`).

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:ui' show Rect;

import 'package:ffi/ffi.dart';

import '../host_platform.dart';
import 'hid_usage.dart';
import 'impl_log.dart';
import 'input_math.dart';
import 'keymap/hid_to_evdev.dart';

/// True when the session is Wayland. `XDG_SESSION_TYPE` is authoritative;
/// `WAYLAND_DISPLAY` is only consulted when the former is missing.
bool isWaylandSession(Map<String, String> env) {
  final type = (env['XDG_SESSION_TYPE'] ?? '').toLowerCase();
  if (type == 'wayland') return true;
  if (type.isNotEmpty) return false;
  return (env['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
}

// ---- native signatures ----------------------------------------------------

typedef _XOpenDisplayN = Pointer<Void> Function(Pointer<Utf8>);
typedef _XOpenDisplayD = Pointer<Void> Function(Pointer<Utf8>);
typedef _DisplayIntN = Int32 Function(Pointer<Void>);
typedef _DisplayIntD = int Function(Pointer<Void>);
typedef _XSyncN = Int32 Function(Pointer<Void>, Int32);
typedef _XSyncD = int Function(Pointer<Void>, int);
typedef _XKeysymToKeycodeN = Uint8 Function(Pointer<Void>, UnsignedLong);
typedef _XKeysymToKeycodeD = int Function(Pointer<Void>, int);
typedef _XDisplayKeycodesN = Int32 Function(
  Pointer<Void>,
  Pointer<Int32>,
  Pointer<Int32>,
);
typedef _XDisplayKeycodesD = int Function(
  Pointer<Void>,
  Pointer<Int32>,
  Pointer<Int32>,
);
typedef _XGetKeyboardMappingN = Pointer<UnsignedLong> Function(
  Pointer<Void>,
  Uint8,
  Int32,
  Pointer<Int32>,
);
typedef _XGetKeyboardMappingD = Pointer<UnsignedLong> Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Int32>,
);
typedef _XChangeKeyboardMappingN = Int32 Function(
  Pointer<Void>,
  Int32,
  Int32,
  Pointer<UnsignedLong>,
  Int32,
);
typedef _XChangeKeyboardMappingD = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<UnsignedLong>,
  int,
);
typedef _XFreeN = Int32 Function(Pointer<Void>);
typedef _XFreeD = int Function(Pointer<Void>);
typedef _XDefaultRootWindowN = UnsignedLong Function(Pointer<Void>);
typedef _XDefaultRootWindowD = int Function(Pointer<Void>);
typedef _XDisplaySizeN = Int32 Function(Pointer<Void>, Int32);
typedef _XDisplaySizeD = int Function(Pointer<Void>, int);
typedef _XGetAtomNameN = Pointer<Utf8> Function(Pointer<Void>, UnsignedLong);
typedef _XGetAtomNameD = Pointer<Utf8> Function(Pointer<Void>, int);

typedef _XTestMotionN = Int32 Function(
  Pointer<Void>,
  Int32,
  Int32,
  Int32,
  UnsignedLong,
);
typedef _XTestMotionD = int Function(Pointer<Void>, int, int, int, int);
typedef _XTestButtonN = Int32 Function(
  Pointer<Void>,
  Uint32,
  Int32,
  UnsignedLong,
);
typedef _XTestButtonD = int Function(Pointer<Void>, int, int, int);
typedef _XTestQueryN = Int32 Function(
  Pointer<Void>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
);
typedef _XTestQueryD = int Function(
  Pointer<Void>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
);

typedef _XRRGetMonitorsN = Pointer<XRRMonitorInfo> Function(
  Pointer<Void>,
  UnsignedLong,
  Int32,
  Pointer<Int32>,
);
typedef _XRRGetMonitorsD = Pointer<XRRMonitorInfo> Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Int32>,
);
typedef _XRRFreeMonitorsN = Void Function(Pointer<XRRMonitorInfo>);
typedef _XRRFreeMonitorsD = void Function(Pointer<XRRMonitorInfo>);

/// `XRRMonitorInfo` from `X11/extensions/Xrandr.h`. `Atom`/`RROutput` are
/// `unsigned long`, so the layout follows the platform ABI.
final class XRRMonitorInfo extends Struct {
  @UnsignedLong()
  external int name;
  @Int32()
  external int primary;
  @Int32()
  external int automatic;
  @Int32()
  external int noutput;
  @Int32()
  external int x;
  @Int32()
  external int y;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int mwidth;
  @Int32()
  external int mheight;
  external Pointer<UnsignedLong> outputs;
}

/// Lazily bound X11 entry points. Everything is resolved on first use so the
/// app starts (and Wayland-only machines work) without libXtst/libXrandr.
class X11Connection {
  X11Connection._(this.display, this._x11, this._xtst, this._xrandr);

  final Pointer<Void> display;
  final DynamicLibrary _x11;
  final DynamicLibrary _xtst;
  final DynamicLibrary? _xrandr;

  static X11Connection? tryOpen() {
    try {
      final x11 = DynamicLibrary.open('libX11.so.6');
      final xtst = DynamicLibrary.open('libXtst.so.6');
      DynamicLibrary? xrandr;
      try {
        xrandr = DynamicLibrary.open('libXrandr.so.2');
      } catch (_) {
        xrandr = null;
      }
      final open = x11.lookupFunction<_XOpenDisplayN, _XOpenDisplayD>(
        'XOpenDisplay',
      );
      final dpy = open(nullptr);
      if (dpy == nullptr) return null;
      return X11Connection._(dpy, x11, xtst, xrandr);
    } catch (e) {
      implLog('X11 libraries unavailable', e);
      return null;
    }
  }

  late final int Function(Pointer<Void>) flush = _x11
      .lookupFunction<_DisplayIntN, _DisplayIntD>('XFlush');
  late final int Function(Pointer<Void>, int) sync = _x11
      .lookupFunction<_XSyncN, _XSyncD>('XSync');
  late final int Function(Pointer<Void>, int) keysymToKeycode = _x11
      .lookupFunction<_XKeysymToKeycodeN, _XKeysymToKeycodeD>(
        'XKeysymToKeycode',
      );
  late final int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>)
  displayKeycodes = _x11.lookupFunction<_XDisplayKeycodesN, _XDisplayKeycodesD>(
    'XDisplayKeycodes',
  );
  late final Pointer<UnsignedLong> Function(
    Pointer<Void>,
    int,
    int,
    Pointer<Int32>,
  )
  getKeyboardMapping = _x11
      .lookupFunction<_XGetKeyboardMappingN, _XGetKeyboardMappingD>(
        'XGetKeyboardMapping',
      );
  late final int Function(Pointer<Void>, int, int, Pointer<UnsignedLong>, int)
  changeKeyboardMapping = _x11
      .lookupFunction<_XChangeKeyboardMappingN, _XChangeKeyboardMappingD>(
        'XChangeKeyboardMapping',
      );
  late final int Function(Pointer<Void>) free = _x11
      .lookupFunction<_XFreeN, _XFreeD>('XFree');
  late final int Function(Pointer<Void>) defaultRootWindow = _x11
      .lookupFunction<_XDefaultRootWindowN, _XDefaultRootWindowD>(
        'XDefaultRootWindow',
      );
  late final int Function(Pointer<Void>, int) displayWidth = _x11
      .lookupFunction<_XDisplaySizeN, _XDisplaySizeD>('XDisplayWidth');
  late final int Function(Pointer<Void>, int) displayHeight = _x11
      .lookupFunction<_XDisplaySizeN, _XDisplaySizeD>('XDisplayHeight');
  late final Pointer<Utf8> Function(Pointer<Void>, int) getAtomName = _x11
      .lookupFunction<_XGetAtomNameN, _XGetAtomNameD>('XGetAtomName');

  late final int Function(Pointer<Void>, int, int, int, int) fakeMotion = _xtst
      .lookupFunction<_XTestMotionN, _XTestMotionD>('XTestFakeMotionEvent');
  late final int Function(Pointer<Void>, int, int, int) fakeButton = _xtst
      .lookupFunction<_XTestButtonN, _XTestButtonD>('XTestFakeButtonEvent');
  late final int Function(Pointer<Void>, int, int, int) fakeKey = _xtst
      .lookupFunction<_XTestButtonN, _XTestButtonD>('XTestFakeKeyEvent');
  late final int Function(
    Pointer<Void>,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>,
  )
  queryExtension = _xtst.lookupFunction<_XTestQueryN, _XTestQueryD>(
    'XTestQueryExtension',
  );

  Pointer<XRRMonitorInfo> Function(Pointer<Void>, int, int, Pointer<Int32>)?
  get getMonitors => _xrandr
      ?.lookupFunction<_XRRGetMonitorsN, _XRRGetMonitorsD>('XRRGetMonitors');
  void Function(Pointer<XRRMonitorInfo>)? get freeMonitors => _xrandr
      ?.lookupFunction<_XRRFreeMonitorsN, _XRRFreeMonitorsD>('XRRFreeMonitors');
}

// ---- platform -------------------------------------------------------------

class LinuxHostPlatform implements HostPlatform {
  LinuxHostPlatform({Map<String, String>? env})
    : _env = env ?? Platform.environment;

  final Map<String, String> _env;

  X11Connection? _x11;
  bool _x11Tried = false;
  LinuxInputInjector? _injector;

  X11Connection? get _connection {
    if (!_x11Tried) {
      _x11Tried = true;
      if ((_env['DISPLAY'] ?? '').isNotEmpty) _x11 = X11Connection.tryOpen();
    }
    return _x11;
  }

  /// Capture works on X11 and on Wayland (PipeWire portal), so any graphical
  /// session counts.
  @override
  bool get hostSupported =>
      (_env['DISPLAY'] ?? '').isNotEmpty ||
      (_env['WAYLAND_DISPLAY'] ?? '').isNotEmpty;

  @override
  bool get inputSupported {
    if (isWaylandSession(_env)) return false;
    final x = _connection;
    if (x == null) return false;
    return _hasXTest(x);
  }

  bool? _xtestPresent;
  bool _hasXTest(X11Connection x) {
    return _xtestPresent ??= () {
      final a = calloc<Int32>(4);
      try {
        return x.queryExtension(x.display, a, a + 1, a + 2, a + 3) != 0;
      } catch (e) {
        implLog('XTestQueryExtension failed', e);
        return false;
      } finally {
        calloc.free(a);
      }
    }();
  }

  @override
  Future<PermissionStatus> permissionStatus(HostPermission permission) async =>
      PermissionStatus.notRequired;

  @override
  Future<void> requestPermission(HostPermission permission) async {}

  /// Primary monitor first, then left-to-right / top-to-bottom.
  /// `captureSourceId` is left null: libwebrtc's X11 source ids are not
  /// derivable from XRandR monitor data, so the core matches by index.
  @override
  Future<List<HostDisplay>> displays() async {
    final x = _connection;
    final list = <({Rect bounds, bool primary, String? name})>[];
    if (x != null) {
      try {
        list.addAll(_xrandrMonitors(x));
      } catch (e) {
        implLog('XRRGetMonitors failed', e);
      }
      if (list.isEmpty) {
        try {
          list.add((
            bounds: Rect.fromLTWH(
              0,
              0,
              x.displayWidth(x.display, 0).toDouble(),
              x.displayHeight(x.display, 0).toDouble(),
            ),
            primary: true,
            name: null,
          ));
        } catch (e) {
          implLog('root window size failed', e);
        }
      }
    }
    if (list.isEmpty) {
      // No X connection (pure Wayland): report a placeholder so the session
      // can still start view-only; real geometry comes from the capture.
      list.add((
        bounds: const Rect.fromLTWH(0, 0, 1920, 1080),
        primary: true,
        name: null,
      ));
    }
    list.sort((a, b) {
      if (a.primary != b.primary) return a.primary ? -1 : 1;
      final byLeft = a.bounds.left.compareTo(b.bounds.left);
      return byLeft != 0 ? byLeft : a.bounds.top.compareTo(b.bounds.top);
    });
    return [
      for (var i = 0; i < list.length; i++)
        HostDisplay(
          id: '$i',
          name: list[i].name ?? 'Display ${i + 1}',
          bounds: list[i].bounds,
          pixelWidth: list[i].bounds.width.round(),
          pixelHeight: list[i].bounds.height.round(),
          primary: list[i].primary,
        ),
    ];
  }

  List<({Rect bounds, bool primary, String? name})> _xrandrMonitors(
    X11Connection x,
  ) {
    final getMonitors = x.getMonitors;
    final freeMonitors = x.freeMonitors;
    if (getMonitors == null || freeMonitors == null) return const [];
    final count = calloc<Int32>();
    try {
      final monitors = getMonitors(
        x.display,
        x.defaultRootWindow(x.display),
        1,
        count,
      );
      if (monitors == nullptr) return const [];
      try {
        final out = <({Rect bounds, bool primary, String? name})>[];
        for (var i = 0; i < count.value; i++) {
          final m = monitors[i];
          if (m.width <= 0 || m.height <= 0) continue;
          out.add((
            bounds: Rect.fromLTWH(
              m.x.toDouble(),
              m.y.toDouble(),
              m.width.toDouble(),
              m.height.toDouble(),
            ),
            primary: m.primary != 0,
            name: _atomName(x, m.name),
          ));
        }
        return out;
      } finally {
        freeMonitors(monitors);
      }
    } finally {
      calloc.free(count);
    }
  }

  String? _atomName(X11Connection x, int atom) {
    try {
      final p = x.getAtomName(x.display, atom);
      if (p == nullptr) return null;
      try {
        final s = p.toDartString();
        return s.isEmpty ? null : s;
      } finally {
        x.free(p.cast<Void>());
      }
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> beforeCapture() async {}

  @override
  Future<void> afterCapture() async {}

  @override
  InputInjector get input {
    final existing = _injector;
    if (existing != null) return existing;
    final x = inputSupported ? _connection : null;
    final created = LinuxInputInjector(x);
    _injector = created;
    return created;
  }
}

// ---- injector -------------------------------------------------------------

class LinuxInputInjector implements InputInjector {
  LinuxInputInjector(this._x);

  final X11Connection? _x;

  final WheelAccumulator _wheelY = WheelAccumulator(1 / wheelPixelsPerNotch);
  final WheelAccumulator _wheelX = WheelAccumulator(1 / wheelPixelsPerNotch);
  final Set<int> _heldKeys = <int>{};
  final Set<MouseButton> _heldButtons = <MouseButton>{};

  /// Upper bound of wheel clicks per call.
  static const int _maxNotches = 30;

  /// How long a temporarily remapped scratch keycode stays mapped after the
  /// last use, so clients have processed the KeyPress against it.
  static const Duration _remapHold = Duration(milliseconds: 80);

  int _scratchKeycode = 0;
  bool _scratchMapped = false;
  Timer? _restoreTimer;

  @override
  void mouseMove(HostDisplay display, double nx, double ny) {
    final x = _x;
    if (x == null) return;
    guarded('mouseMove', () {
      final p = displayPoint(display.bounds, nx, ny);
      x.fakeMotion(x.display, -1, p.x, p.y, 0); // -1 = current screen
      x.flush(x.display);
    });
  }

  @override
  void mouseButton(MouseButton button, bool down) {
    final x = _x;
    if (x == null) return;
    guarded('mouseButton', () {
      x.fakeButton(x.display, x11ButtonNumber(button), down ? 1 : 0, 0);
      x.flush(x.display);
      if (down) {
        _heldButtons.add(button);
      } else {
        _heldButtons.remove(button);
      }
    });
  }

  @override
  void scroll(double dx, double dy) {
    final x = _x;
    if (x == null) return;
    guarded('scroll', () {
      // dy > 0: content scrolls down = wheel button 5; dx > 0: right = 7.
      _clicks(x, _wheelY.add(dy), x11ScrollDown, x11ScrollUp);
      _clicks(x, _wheelX.add(dx), x11ScrollRight, x11ScrollLeft);
      x.flush(x.display);
    });
  }

  void _clicks(
    X11Connection x,
    int notches,
    int positiveButton,
    int negativeButton,
  ) {
    if (notches == 0) return;
    final button = notches > 0 ? positiveButton : negativeButton;
    final n = notches.abs() > _maxNotches ? _maxNotches : notches.abs();
    for (var i = 0; i < n; i++) {
      x.fakeButton(x.display, button, 1, 0);
      x.fakeButton(x.display, button, 0, 0);
    }
  }

  @override
  void key(int usbHid, bool down) {
    final x = _x;
    if (x == null) return;
    guarded('key', () {
      final evdev = hidToEvdev[usbHid];
      if (evdev == null) {
        implLog('no evdev code for HID usage');
        return;
      }
      x.fakeKey(x.display, evdev + evdevToX11Offset, down ? 1 : 0, 0);
      x.flush(x.display);
      if (down) {
        _heldKeys.add(usbHid);
      } else {
        _heldKeys.remove(usbHid);
      }
    });
  }

  @override
  void text(String text) {
    final x = _x;
    if (x == null) return;
    guarded('text', () {
      for (final rune in text.runes) {
        if (rune == 0x0a) {
          key(hidEnter, true);
          key(hidEnter, false);
        } else if (rune == 0x09) {
          key(hidTab, true);
          key(hidTab, false);
        } else {
          _typeCodePoint(x, rune);
        }
      }
      x.flush(x.display);
    });
  }

  void _typeCodePoint(X11Connection x, int codePoint) {
    final keysym = x11KeysymForCodePoint(codePoint);
    if (keysym == 0) return;
    final direct = x.keysymToKeycode(x.display, keysym);
    if (direct != 0 && _isUnshifted(x, direct, keysym)) {
      x.fakeKey(x.display, direct, 1, 0);
      x.fakeKey(x.display, direct, 0, 0);
      return;
    }
    // Not reachable without a modifier (or not mapped at all): borrow an unused
    // keycode, bind the keysym to it in every column, tap it, restore later.
    final scratch = _scratch(x);
    if (scratch == 0) return;
    _mapScratch(x, scratch, keysym);
    x.fakeKey(x.display, scratch, 1, 0);
    x.fakeKey(x.display, scratch, 0, 0);
    x.sync(x.display, 0);
    _restoreTimer?.cancel();
    _restoreTimer = Timer(
      _remapHold,
      () => guarded('restore keymap', () => _restoreScratch(x)),
    );
  }

  /// True when [keysym] is the first-column (no modifier) symbol of [keycode].
  bool _isUnshifted(X11Connection x, int keycode, int keysym) {
    final perKey = calloc<Int32>();
    try {
      final map = x.getKeyboardMapping(x.display, keycode, 1, perKey);
      if (map == nullptr) return false;
      try {
        return perKey.value > 0 && map[0] == keysym;
      } finally {
        x.free(map.cast<Void>());
      }
    } finally {
      calloc.free(perKey);
    }
  }

  /// Finds a keycode with no symbols bound, or falls back to the highest one.
  int _scratch(X11Connection x) {
    if (_scratchKeycode != 0) return _scratchKeycode;
    final minMax = calloc<Int32>(2);
    final perKey = calloc<Int32>();
    try {
      x.displayKeycodes(x.display, minMax, minMax + 1);
      final min = minMax[0];
      final max = minMax[1];
      if (max < min) return 0;
      final count = max - min + 1;
      final map = x.getKeyboardMapping(x.display, min, count, perKey);
      if (map == nullptr) return 0;
      try {
        final width = perKey.value;
        for (var kc = max; kc >= min; kc--) {
          var empty = true;
          for (var col = 0; col < width; col++) {
            if (map[(kc - min) * width + col] != 0) {
              empty = false;
              break;
            }
          }
          if (empty) return _scratchKeycode = kc;
        }
        return _scratchKeycode = max;
      } finally {
        x.free(map.cast<Void>());
      }
    } finally {
      calloc.free(minMax);
      calloc.free(perKey);
    }
  }

  void _mapScratch(X11Connection x, int keycode, int keysym) {
    const columns = 4;
    final syms = calloc<UnsignedLong>(columns);
    try {
      for (var i = 0; i < columns; i++) {
        syms[i] = keysym;
      }
      x.changeKeyboardMapping(x.display, keycode, columns, syms, 1);
      x.sync(x.display, 0);
      _scratchMapped = true;
    } finally {
      calloc.free(syms);
    }
  }

  void _restoreScratch(X11Connection x) {
    if (!_scratchMapped || _scratchKeycode == 0) return;
    const columns = 4;
    final syms = calloc<UnsignedLong>(columns); // calloc zero-fills = NoSymbol
    try {
      x.changeKeyboardMapping(x.display, _scratchKeycode, columns, syms, 1);
      x.sync(x.display, 0);
      _scratchMapped = false;
    } finally {
      calloc.free(syms);
    }
  }

  @override
  Future<void> special(SpecialAction action) async {
    // Lock/Ctrl+Alt+Del have no portable X11 equivalent; Android-only actions
    // do not apply on desktops.
  }

  @override
  void releaseAll() {
    final x = _x;
    if (x == null) return;
    guarded('releaseAll', () {
      for (final usage in _heldKeys.toList()) {
        final evdev = hidToEvdev[usage];
        if (evdev != null) x.fakeKey(x.display, evdev + evdevToX11Offset, 0, 0);
      }
      _heldKeys.clear();
      for (final button in _heldButtons.toList()) {
        x.fakeButton(x.display, x11ButtonNumber(button), 0, 0);
      }
      _heldButtons.clear();
      _wheelX.reset();
      _wheelY.reset();
      _restoreTimer?.cancel();
      _restoreScratch(x);
      x.flush(x.display);
    });
  }
}
