// macOS host.
//
// Hot path (mouse/keyboard/scroll) = Dart FFI straight into CoreGraphics, so
// no platform-channel hop per mouse move. Permissions and System Settings
// deep links go through a tiny Swift channel (`io.thelxis/host`, registered in
// macos/Runner/MainFlutterWindow.swift) because they need CF/AppKit types.
//
// Required TCC grants: Accessibility (CGEventPost) and Screen Recording
// (capture, handled by flutter_webrtc). The App Sandbox is disabled in the
// entitlements; neither works inside the sandbox.

import 'dart:ffi';
import 'dart:ui' show Rect;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show MethodChannel;

import '../host_platform.dart';
import 'hid_usage.dart';
import 'impl_log.dart';
import 'input_math.dart';
import 'keymap/hid_to_mac_vk.dart';

// ---- CoreGraphics bindings ------------------------------------------------

final class _CGPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final class _CGSize extends Struct {
  @Double()
  external double width;
  @Double()
  external double height;
}

final class _CGRect extends Struct {
  external _CGPoint origin;
  external _CGSize size;
}

typedef _SourceCreateN = Pointer<Void> Function(Int32);
typedef _SourceCreateD = Pointer<Void> Function(int);
typedef _SourceFlagsN = Uint64 Function(Int32);
typedef _SourceFlagsD = int Function(int);
typedef _MouseEventN = Pointer<Void> Function(
  Pointer<Void>,
  Uint32,
  _CGPoint,
  Uint32,
);
typedef _MouseEventD = Pointer<Void> Function(
  Pointer<Void>,
  int,
  _CGPoint,
  int,
);
typedef _KeyEventN = Pointer<Void> Function(Pointer<Void>, Uint16, Bool);
typedef _KeyEventD = Pointer<Void> Function(Pointer<Void>, int, bool);
typedef _ScrollEventN = Pointer<Void> Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Int32,
  Int32,
  Int32,
);
typedef _ScrollEventD = Pointer<Void> Function(
  Pointer<Void>,
  int,
  int,
  int,
  int,
  int,
);
typedef _EventCreateN = Pointer<Void> Function(Pointer<Void>);
typedef _EventCreateD = Pointer<Void> Function(Pointer<Void>);
typedef _EventLocationN = _CGPoint Function(Pointer<Void>);
typedef _EventPostN = Void Function(Uint32, Pointer<Void>);
typedef _EventPostD = void Function(int, Pointer<Void>);
typedef _SetFlagsN = Void Function(Pointer<Void>, Uint64);
typedef _SetFlagsD = void Function(Pointer<Void>, int);
typedef _SetFieldN = Void Function(Pointer<Void>, Uint32, Int64);
typedef _SetFieldD = void Function(Pointer<Void>, int, int);
typedef _SetUnicodeN = Void Function(
  Pointer<Void>,
  UnsignedLong,
  Pointer<Uint16>,
);
typedef _SetUnicodeD = void Function(Pointer<Void>, int, Pointer<Uint16>);
typedef _ReleaseN = Void Function(Pointer<Void>);
typedef _ReleaseD = void Function(Pointer<Void>);
typedef _DisplayListN = Int32 Function(
  Uint32,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _DisplayListD = int Function(int, Pointer<Uint32>, Pointer<Uint32>);
typedef _DisplayBoundsN = _CGRect Function(Uint32);
typedef _DisplayIsMainN = Int32 Function(Uint32);
typedef _DisplayIsMainD = int Function(int);
typedef _DisplaySizeN = Size Function(Uint32);
typedef _DisplaySizeD = int Function(int);
typedef _DisplayModeN = Pointer<Void> Function(Uint32);
typedef _DisplayModeD = Pointer<Void> Function(int);
typedef _ModeSizeN = Size Function(Pointer<Void>);
typedef _ModeSizeD = int Function(Pointer<Void>);

/// CGEventType values.
const int _evLeftDown = 1;
const int _evLeftUp = 2;
const int _evRightDown = 3;
const int _evRightUp = 4;
const int _evMouseMoved = 5;
const int _evLeftDragged = 6;
const int _evRightDragged = 7;
const int _evOtherDown = 25;
const int _evOtherUp = 26;
const int _evOtherDragged = 27;

/// CGEventField values.
const int _fieldClickState = 1;
const int _fieldButtonNumber = 3;
const int _fieldDeltaX = 4;
const int _fieldDeltaY = 5;
const int _fieldAutorepeat = 8;

const int _hidEventTap = 0; // kCGHIDEventTap
const int _sourceHidSystemState = 1; // kCGEventSourceStateHIDSystemState
const int _scrollUnitPixel = 0; // kCGScrollEventUnitPixel

/// kVK_* codes for the lock-screen chord (Ctrl+Cmd+Q).
const int _vkControl = 0x3b;
const int _vkCommand = 0x37;
const int _vkQ = 0x0c;

/// Max UTF-16 units per synthetic keyboard event (the API documents 20).
const int _unicodeChunk = 16;

const int _maxScrollPixels = 2000;

class _CoreGraphics {
  _CoreGraphics._()
    : _cg = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
      ),
      _cf = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
      );

  static final _CoreGraphics instance = _CoreGraphics._();

  final DynamicLibrary _cg;
  final DynamicLibrary _cf;

  late final Pointer<Void> Function(int) sourceCreate = _cg
      .lookupFunction<_SourceCreateN, _SourceCreateD>('CGEventSourceCreate');
  late final int Function(int) sourceFlagsState = _cg
      .lookupFunction<_SourceFlagsN, _SourceFlagsD>('CGEventSourceFlagsState');
  late final Pointer<Void> Function(Pointer<Void>, int, _CGPoint, int)
  createMouse = _cg.lookupFunction<_MouseEventN, _MouseEventD>(
    'CGEventCreateMouseEvent',
  );
  late final Pointer<Void> Function(Pointer<Void>, int, bool) createKey = _cg
      .lookupFunction<_KeyEventN, _KeyEventD>('CGEventCreateKeyboardEvent');
  late final Pointer<Void> Function(Pointer<Void>, int, int, int, int, int)
  createScroll = _cg.lookupFunction<_ScrollEventN, _ScrollEventD>(
    'CGEventCreateScrollWheelEvent2',
  );
  late final Pointer<Void> Function(Pointer<Void>) createEvent = _cg
      .lookupFunction<_EventCreateN, _EventCreateD>('CGEventCreate');
  late final _CGPoint Function(Pointer<Void>) eventLocation = _cg
      .lookupFunction<_EventLocationN, _CGPoint Function(Pointer<Void>)>(
        'CGEventGetLocation',
      );
  late final void Function(int, Pointer<Void>) post = _cg
      .lookupFunction<_EventPostN, _EventPostD>('CGEventPost');
  late final void Function(Pointer<Void>, int) setFlags = _cg
      .lookupFunction<_SetFlagsN, _SetFlagsD>('CGEventSetFlags');
  late final void Function(Pointer<Void>, int, int) setField = _cg
      .lookupFunction<_SetFieldN, _SetFieldD>('CGEventSetIntegerValueField');
  late final void Function(Pointer<Void>, int, Pointer<Uint16>) setUnicode = _cg
      .lookupFunction<_SetUnicodeN, _SetUnicodeD>(
        'CGEventKeyboardSetUnicodeString',
      );
  late final void Function(Pointer<Void>) release = _cf
      .lookupFunction<_ReleaseN, _ReleaseD>('CFRelease');

  late final int Function(int, Pointer<Uint32>, Pointer<Uint32>) displayList =
      _cg.lookupFunction<_DisplayListN, _DisplayListD>(
        'CGGetActiveDisplayList',
      );
  late final _CGRect Function(int) displayBounds = _cg
      .lookupFunction<_DisplayBoundsN, _CGRect Function(int)>(
        'CGDisplayBounds',
      );
  late final int Function(int) displayIsMain = _cg
      .lookupFunction<_DisplayIsMainN, _DisplayIsMainD>('CGDisplayIsMain');
  late final int Function(int) displayPixelsWide = _cg
      .lookupFunction<_DisplaySizeN, _DisplaySizeD>('CGDisplayPixelsWide');
  late final int Function(int) displayPixelsHigh = _cg
      .lookupFunction<_DisplaySizeN, _DisplaySizeD>('CGDisplayPixelsHigh');
  late final Pointer<Void> Function(int) copyDisplayMode = _cg
      .lookupFunction<_DisplayModeN, _DisplayModeD>('CGDisplayCopyDisplayMode');
  late final int Function(Pointer<Void>) modePixelWidth = _cg
      .lookupFunction<_ModeSizeN, _ModeSizeD>('CGDisplayModeGetPixelWidth');
  late final int Function(Pointer<Void>) modePixelHeight = _cg
      .lookupFunction<_ModeSizeN, _ModeSizeD>('CGDisplayModeGetPixelHeight');
  late final void Function(Pointer<Void>) releaseMode = _cg
      .lookupFunction<_ReleaseN, _ReleaseD>('CGDisplayModeRelease');
}

// ---- platform -------------------------------------------------------------

class MacosHostPlatform implements HostPlatform {
  static const MethodChannel _channel = MethodChannel('io.thelxis/host');

  final MacosInputInjector _input = MacosInputInjector();

  @override
  bool get hostSupported => true;

  @override
  bool get inputSupported => true;

  @override
  Future<PermissionStatus> permissionStatus(HostPermission permission) async {
    try {
      switch (permission) {
        case HostPermission.screenCapture:
          return await _granted('screenCaptureStatus');
        case HostPermission.inputControl:
          return await _granted('accessibilityStatus');
        case HostPermission.notifications:
          return PermissionStatus.notRequired;
      }
    } catch (e) {
      implLog('permissionStatus failed', e);
      return PermissionStatus.denied;
    }
  }

  Future<PermissionStatus> _granted(String method) async {
    final ok = await _channel.invokeMethod<bool>(method) ?? false;
    return ok ? PermissionStatus.granted : PermissionStatus.denied;
  }

  /// Shows the system prompt the first time and afterwards opens the matching
  /// System Settings pane. Screen Recording usually needs an app restart
  /// after the user ticks the box; the UI should say so.
  @override
  Future<void> requestPermission(HostPermission permission) async {
    try {
      switch (permission) {
        case HostPermission.screenCapture:
          await _channel.invokeMethod<void>('requestScreenCapture');
        case HostPermission.inputControl:
          await _channel.invokeMethod<void>('requestAccessibility');
        case HostPermission.notifications:
          break;
      }
    } catch (e) {
      implLog('requestPermission failed', e);
    }
  }

  /// Main display first, remaining displays in CoreGraphics order.
  /// `captureSourceId` is the CGDirectDisplayID: flutter_webrtc's
  /// ScreenCaptureKit capturer matches `deviceId.exact` against
  /// `SCDisplay.displayID` formatted as `%u` (FlutterScreenCaptureKitCapturer.m).
  @override
  Future<List<HostDisplay>> displays() async {
    final out = <HostDisplay>[];
    try {
      final cg = _CoreGraphics.instance;
      final ids = calloc<Uint32>(16);
      final count = calloc<Uint32>();
      try {
        if (cg.displayList(16, ids, count) == 0) {
          final main = <HostDisplay>[];
          final others = <HostDisplay>[];
          for (var i = 0; i < count.value; i++) {
            final d = _describe(cg, ids[i]);
            (d.primary ? main : others).add(d);
          }
          out
            ..addAll(main)
            ..addAll(others);
        }
      } finally {
        calloc.free(ids);
        calloc.free(count);
      }
    } catch (e) {
      implLog('display enumeration failed', e);
    }
    if (out.isEmpty) {
      out.add(
        const HostDisplay(
          id: '0',
          name: 'Display 1',
          bounds: Rect.fromLTWH(0, 0, 1440, 900),
          pixelWidth: 1440,
          pixelHeight: 900,
          primary: true,
        ),
      );
    }
    // Re-number so ids are the final indices.
    return [
      for (var i = 0; i < out.length; i++)
        HostDisplay(
          id: '$i',
          name: 'Display ${i + 1}',
          bounds: out[i].bounds,
          pixelWidth: out[i].pixelWidth,
          pixelHeight: out[i].pixelHeight,
          primary: out[i].primary,
          captureSourceId: out[i].captureSourceId,
        ),
    ];
  }

  HostDisplay _describe(_CoreGraphics cg, int displayId) {
    final b = cg.displayBounds(displayId);
    var pixelW = cg.displayPixelsWide(displayId);
    var pixelH = cg.displayPixelsHigh(displayId);
    // PixelsWide/High report the logical (point) size of the current mode; the
    // display mode knows the real backing-store size on Retina panels.
    final mode = cg.copyDisplayMode(displayId);
    if (mode != nullptr) {
      try {
        final w = cg.modePixelWidth(mode);
        final h = cg.modePixelHeight(mode);
        if (w > 0 && h > 0) {
          pixelW = w;
          pixelH = h;
        }
      } finally {
        cg.releaseMode(mode);
      }
    }
    return HostDisplay(
      id: '$displayId',
      name: 'Display',
      bounds: Rect.fromLTWH(
        b.origin.x,
        b.origin.y,
        b.size.width,
        b.size.height,
      ),
      pixelWidth: pixelW,
      pixelHeight: pixelH,
      primary: cg.displayIsMain(displayId) != 0,
      captureSourceId: '$displayId',
    );
  }

  @override
  Future<void> beforeCapture() async {}

  @override
  Future<void> afterCapture() async {}

  @override
  InputInjector get input => _input;
}

// ---- injector -------------------------------------------------------------

class MacosInputInjector implements InputInjector {
  _CoreGraphics? _cgInstance;
  Pointer<Void> _source = nullptr;
  final Pointer<_CGPoint> _point = calloc<_CGPoint>();

  final MacModifierState _mods = MacModifierState();
  final ClickTracker _clicks = ClickTracker();
  final WheelAccumulator _wheelY = WheelAccumulator(1);
  final WheelAccumulator _wheelX = WheelAccumulator(1);

  final Set<int> _heldKeys = <int>{};

  /// Held mouse buttons, oldest first; the newest decides the drag type.
  final List<MouseButton> _heldButtons = <MouseButton>[];
  final Map<MouseButton, int> _clickStates = <MouseButton, int>{};

  double _x = 0;
  double _y = 0;
  bool _positionKnown = false;
  bool _capsSynced = false;

  _CoreGraphics get _cg {
    final existing = _cgInstance;
    if (existing != null) return existing;
    final cg = _CoreGraphics.instance;
    _cgInstance = cg;
    _source = cg.sourceCreate(_sourceHidSystemState);
    return cg;
  }

  void _post(Pointer<Void> event, int flags) {
    if (event == nullptr) {
      implLog('CoreGraphics returned a null event');
      return;
    }
    final cg = _cg;
    cg.setFlags(event, flags);
    cg.post(_hidEventTap, event);
    cg.release(event);
  }

  Pointer<Void> _mouseEvent(int type, double x, double y, int button) {
    _point.ref.x = x;
    _point.ref.y = y;
    return _cg.createMouse(_source, type, _point.ref, button);
  }

  void _ensurePosition() {
    if (_positionKnown) return;
    final cg = _cg;
    final probe = cg.createEvent(nullptr);
    if (probe != nullptr) {
      final p = cg.eventLocation(probe);
      _x = p.x;
      _y = p.y;
      cg.release(probe);
    }
    _positionKnown = true;
  }

  @override
  void mouseMove(HostDisplay display, double nx, double ny) {
    guarded('mouseMove', () {
      final target = macGlobalPoint(display.bounds, nx, ny);
      _ensurePosition();
      if (target.x == _x && target.y == _y) return;
      final held = _heldButtons.isEmpty ? null : _heldButtons.last;
      final type = switch (held) {
        null => _evMouseMoved,
        MouseButton.left => _evLeftDragged,
        MouseButton.right => _evRightDragged,
        _ => _evOtherDragged,
      };
      final event = _mouseEvent(type, target.x, target.y, _buttonNumber(held));
      if (event != nullptr) {
        // Apps (window drags, sliders) read the relative deltas, which
        // CGEventCreateMouseEvent leaves at zero.
        _cg.setField(event, _fieldDeltaX, (target.x - _x).round());
        _cg.setField(event, _fieldDeltaY, (target.y - _y).round());
        if (held != null && held.index >= MouseButton.back.index) {
          _cg.setField(event, _fieldButtonNumber, _buttonNumber(held));
        }
      }
      _post(event, _currentFlags());
      _x = target.x;
      _y = target.y;
    });
  }

  @override
  void mouseButton(MouseButton button, bool down) {
    guarded('mouseButton', () {
      _ensurePosition();
      final (int downType, int upType) = switch (button) {
        MouseButton.left => (_evLeftDown, _evLeftUp),
        MouseButton.right => (_evRightDown, _evRightUp),
        _ => (_evOtherDown, _evOtherUp),
      };
      final int clickState;
      if (down) {
        clickState = _clicks.down(
          button,
          _x,
          _y,
          DateTime.now().millisecondsSinceEpoch,
        );
        _clickStates[button] = clickState;
        _heldButtons
          ..remove(button)
          ..add(button);
      } else {
        clickState = _clickStates[button] ?? 1;
        _heldButtons.remove(button);
      }
      final event = _mouseEvent(
        down ? downType : upType,
        _x,
        _y,
        _buttonNumber(button),
      );
      if (event != nullptr) {
        _cg.setField(event, _fieldClickState, clickState);
        if (button.index >= MouseButton.back.index) {
          _cg.setField(event, _fieldButtonNumber, _buttonNumber(button));
        }
      }
      _post(event, _currentFlags());
    });
  }

  /// CGMouseButton numbering: 0 left, 1 right, 2 middle, 3+ extra buttons.
  int _buttonNumber(MouseButton? b) => switch (b) {
    null || MouseButton.left => 0,
    MouseButton.right => 1,
    MouseButton.middle => 2,
    MouseButton.back => 3,
    MouseButton.forward => 4,
  };

  @override
  void scroll(double dx, double dy) {
    guarded('scroll', () {
      // Quartz: positive wheel1 scrolls up, positive wheel2 scrolls left, so
      // dy > 0 (content down) and dx > 0 (content right) are both negated.
      final v = _wheelY
          .add(-dy)
          .clamp(-_maxScrollPixels, _maxScrollPixels)
          .toInt();
      final h = _wheelX
          .add(-dx)
          .clamp(-_maxScrollPixels, _maxScrollPixels)
          .toInt();
      if (v == 0 && h == 0) return;
      _post(
        _cg.createScroll(_source, _scrollUnitPixel, 2, v, h, 0),
        _currentFlags(),
      );
    });
  }

  @override
  void key(int usbHid, bool down) {
    guarded('key', () {
      final vk = hidToMacVk[usbHid];
      if (vk == null) {
        implLog('no macOS virtual key for HID usage');
        return;
      }
      _syncCapsLockOnce();
      final repeat = down && _heldKeys.contains(usbHid);
      _mods.apply(usbHid, down);
      final event = _cg.createKey(_source, vk, down);
      if (event != nullptr && repeat) _cg.setField(event, _fieldAutorepeat, 1);
      _post(event, _currentFlags());
      if (down) {
        _heldKeys.add(usbHid);
      } else {
        _heldKeys.remove(usbHid);
      }
    });
  }

  @override
  void text(String text) {
    guarded('text', () {
      final pending = StringBuffer();
      void flush() {
        if (pending.isEmpty) return;
        _typeUnicode(pending.toString());
        pending.clear();
      }

      for (final rune in text.runes) {
        if (rune == 0x0a) {
          flush();
          key(hidEnter, true);
          key(hidEnter, false);
        } else if (rune == 0x09) {
          flush();
          key(hidTab, true);
          key(hidTab, false);
        } else if (rune < 0x20 || rune == 0x7f) {
          continue;
        } else {
          pending.writeCharCode(rune);
        }
      }
      flush();
    });
  }

  void _typeUnicode(String s) {
    for (final chunk in utf16Chunks(s, _unicodeChunk)) {
      final buf = calloc<Uint16>(chunk.length);
      try {
        for (var i = 0; i < chunk.length; i++) {
          buf[i] = chunk[i];
        }
        for (final down in const [true, false]) {
          final event = _cg.createKey(_source, 0, down);
          if (event != nullptr) _cg.setUnicode(event, chunk.length, buf);
          // No modifiers: a held Cmd/Ctrl must not turn typed text into
          // shortcuts.
          _post(event, 0);
        }
      } finally {
        calloc.free(buf);
      }
    }
  }

  @override
  Future<void> special(SpecialAction action) async {
    try {
      if (action == SpecialAction.lock) {
        _lockScreen();
      }
      // ctrlAltDel has no macOS equivalent; the remaining actions are
      // Android-only.
    } catch (e) {
      implLog('special action failed', e);
    }
  }

  /// Ctrl+Cmd+Q is the system "Lock Screen" shortcut.
  void _lockScreen() {
    final cg = _cg;
    const chord = [_vkControl, _vkCommand, _vkQ];
    const flagsAfter = [
      cgFlagControl,
      cgFlagControl | cgFlagCommand,
      cgFlagControl | cgFlagCommand,
    ];
    for (var i = 0; i < chord.length; i++) {
      _post(cg.createKey(_source, chord[i], true), flagsAfter[i]);
    }
    for (var i = chord.length - 1; i >= 0; i--) {
      _post(
        cg.createKey(_source, chord[i], false),
        i == 0 ? 0 : flagsAfter[i - 1],
      );
    }
  }

  @override
  void releaseAll() {
    guarded('releaseAll', () {
      for (final usage in _heldKeys.toList()) {
        final vk = hidToMacVk[usage];
        if (vk == null) continue;
        _mods.apply(usage, false);
        _post(_cg.createKey(_source, vk, false), _currentFlags());
      }
      _heldKeys.clear();
      for (final button in _heldButtons.reversed.toList()) {
        mouseButton(button, false);
      }
      _heldButtons.clear();
      _mods.clear();
      _clicks.reset();
      _wheelX.reset();
      _wheelY.reset();
    });
  }

  int _currentFlags() => _mods.flags;

  /// Seeds the caps lock flag from the system the first time a key is sent.
  void _syncCapsLockOnce() {
    if (_capsSynced) return;
    _capsSynced = true;
    final state = _cg.sourceFlagsState(_sourceHidSystemState);
    _mods.syncCapsLock((state & cgFlagAlphaShift) != 0);
  }
}
