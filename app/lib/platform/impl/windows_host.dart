// Windows host: input via SendInput (Dart FFI through package:win32), displays
// via EnumDisplayMonitors. The runner is PerMonitorV2 DPI aware
// (windows/runner/runner.exe.manifest), so every coordinate below is in
// physical pixels of the virtual desktop.

import 'dart:ffi';
import 'dart:ui' show Rect;

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../host_platform.dart';
import 'hid_usage.dart';
import 'impl_log.dart';
import 'input_math.dart';
import 'keymap/hid_to_win_scancode.dart';

/// `TOKEN_INFORMATION_CLASS.TokenElevation`.
const int _tokenElevationClass = 20;

const int _xButton1 = 0x0001;
const int _xButton2 = 0x0002;

/// Upper bound for one wheel event so a runaway delta cannot flood the system.
const int _maxWheelUnits = windowsWheelDelta * 40;

/// Max UTF-16 units sent in one `SendInput` call for `txt` (2 events each).
const int _textBatchUnits = 128;

class WindowsHostPlatform implements HostPlatform {
  final WindowsInputInjector _input = WindowsInputInjector();

  @override
  bool get hostSupported => true;

  @override
  bool get inputSupported => true;

  @override
  Future<PermissionStatus> permissionStatus(HostPermission permission) async =>
      PermissionStatus.notRequired;

  @override
  Future<void> requestPermission(HostPermission permission) async {}

  /// Primary monitor first, then left-to-right / top-to-bottom.
  ///
  /// `captureSourceId` stays null on purpose: libwebrtc numbers screens with
  /// `EnumDisplayDevices` indices, which cannot be derived reliably from the
  /// monitor handles used here, so the core matches by list index instead.
  @override
  Future<List<HostDisplay>> displays() async {
    final monitors = <({Rect bounds, bool primary})>[];
    try {
      monitors.addAll(_enumerateMonitors());
    } catch (e) {
      implLog('EnumDisplayMonitors failed', e);
    }
    if (monitors.isEmpty) {
      monitors.add((
        bounds: Rect.fromLTWH(
          0,
          0,
          GetSystemMetrics(SM_CXSCREEN).toDouble(),
          GetSystemMetrics(SM_CYSCREEN).toDouble(),
        ),
        primary: true,
      ));
    }
    monitors.sort((a, b) {
      if (a.primary != b.primary) return a.primary ? -1 : 1;
      final byLeft = a.bounds.left.compareTo(b.bounds.left);
      return byLeft != 0 ? byLeft : a.bounds.top.compareTo(b.bounds.top);
    });
    return [
      for (var i = 0; i < monitors.length; i++)
        HostDisplay(
          id: '$i',
          name: 'Display ${i + 1}',
          bounds: monitors[i].bounds,
          pixelWidth: monitors[i].bounds.width.round(),
          pixelHeight: monitors[i].bounds.height.round(),
          primary: monitors[i].primary,
        ),
    ];
  }

  List<({Rect bounds, bool primary})> _enumerateMonitors() {
    final found = <({Rect bounds, bool primary})>[];
    final info = calloc<MONITORINFOEX>();
    // EnumDisplayMonitors invokes the callback synchronously on this thread,
    // which is what NativeCallable.isolateLocal requires.
    final callback = NativeCallable<MONITORENUMPROC>.isolateLocal((
      int hMonitor,
      int hdc,
      Pointer lpRect,
      int lParam,
    ) {
      try {
        info.ref.monitorInfo.cbSize = sizeOf<MONITORINFOEX>();
        if (GetMonitorInfo(hMonitor, info.cast<MONITORINFO>()) != 0) {
          final r = info.ref.monitorInfo.rcMonitor;
          found.add((
            bounds: Rect.fromLTRB(
              r.left.toDouble(),
              r.top.toDouble(),
              r.right.toDouble(),
              r.bottom.toDouble(),
            ),
            primary: (info.ref.monitorInfo.dwFlags & MONITORINFOF_PRIMARY) != 0,
          ));
        }
      } catch (e) {
        implLog('GetMonitorInfo failed', e);
      }
      return 1; // continue enumeration
    }, exceptionalReturn: 0);
    try {
      EnumDisplayMonitors(0, nullptr, callback.nativeFunction, 0);
    } finally {
      callback.close();
      calloc.free(info);
    }
    return found;
  }

  @override
  Future<void> beforeCapture() async {}

  @override
  Future<void> afterCapture() async {}

  @override
  InputInjector get input => _input;
}

class WindowsInputInjector implements InputInjector, InjectionReport {
  /// Scratch INPUT reused for every single-event call. The UI isolate is
  /// single-threaded, so one buffer is safe and avoids an allocation per
  /// mouse move.
  final Pointer<INPUT> _one = calloc<INPUT>();

  final WheelAccumulator _wheelY = WheelAccumulator(
    windowsWheelDelta / wheelPixelsPerNotch,
  );
  final WheelAccumulator _wheelX = WheelAccumulator(
    windowsWheelDelta / wheelPixelsPerNotch,
  );

  final Set<int> _heldKeys = <int>{};
  final Set<MouseButton> _heldButtons = <MouseButton>{};

  /// When `SendInput` last injected fewer events than asked for (secure
  /// desktop, UAC), or null after a later call went through.
  DateTime? _rejectedAt;

  /// How long a refused `SendInput` keeps counting as "blocked". It is the
  /// only signal for the secure desktop, but a viewer who stops sending input
  /// once warned would otherwise keep the warning forever.
  static const _rejectionMemory = Duration(seconds: 6);

  /// Whether this process runs elevated; resolved on first use.
  bool? _selfElevated;

  @override
  bool get injectionRejected {
    final at = _rejectedAt;
    if (at != null && DateTime.now().difference(at) < _rejectionMemory) return true;
    try {
      return _foregroundOutranksUs();
    } catch (e) {
      implLog('foreground integrity check failed', e);
      return false;
    }
  }

  /// UIPI makes `SendInput` drop events aimed at a window of a more privileged
  /// process *without* any error (the return value still says "sent"), so the
  /// only way to know is to look at who has the focus: an elevated or
  /// otherwise unopenable process while this one is not elevated.
  bool _foregroundOutranksUs() {
    final hwnd = GetForegroundWindow();
    if (hwnd == 0) return false;
    final pid = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, pid);
      if (pid.value == 0 || pid.value == GetCurrentProcessId()) return false;
      final self = _selfElevated ??= (_isElevated(GetCurrentProcess()) ?? false);
      if (self) return false;
      final process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid.value);
      // A process we cannot even query is more privileged than we are.
      if (process == 0) return true;
      try {
        return _isElevated(process) ?? true;
      } finally {
        CloseHandle(process);
      }
    } finally {
      calloc.free(pid);
    }
  }

  /// `TokenIsElevated` of [process], or null when its token cannot be read.
  bool? _isElevated(int process) {
    final token = calloc<IntPtr>();
    final value = calloc<Uint32>();
    final length = calloc<Uint32>();
    try {
      if (OpenProcessToken(process, TOKEN_QUERY, token) == 0) return null;
      try {
        final ok = GetTokenInformation(
          token.value,
          _tokenElevationClass,
          value,
          sizeOf<Uint32>(),
          length,
        );
        return ok == 0 ? null : value.value != 0;
      } finally {
        CloseHandle(token.value);
      }
    } finally {
      calloc.free(token);
      calloc.free(value);
      calloc.free(length);
    }
  }

  @override
  void mouseMove(HostDisplay display, double nx, double ny) {
    guarded('mouseMove', () {
      final virtual = Rect.fromLTWH(
        GetSystemMetrics(SM_XVIRTUALSCREEN).toDouble(),
        GetSystemMetrics(SM_YVIRTUALSCREEN).toDouble(),
        GetSystemMetrics(SM_CXVIRTUALSCREEN).toDouble(),
        GetSystemMetrics(SM_CYVIRTUALSCREEN).toDouble(),
      );
      final p = windowsAbsoluteMouse(display.bounds, virtual, nx, ny);
      _mouse(
        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
        dx: p.x,
        dy: p.y,
      );
    });
  }

  @override
  void mouseButton(MouseButton button, bool down) {
    guarded('mouseButton', () {
      final (int flags, int data) = switch (button) {
        MouseButton.left => (
          down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP,
          0,
        ),
        MouseButton.middle => (
          down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP,
          0,
        ),
        MouseButton.right => (
          down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP,
          0,
        ),
        MouseButton.back => (
          down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP,
          _xButton1,
        ),
        MouseButton.forward => (
          down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP,
          _xButton2,
        ),
      };
      _mouse(flags, data: data);
      if (down) {
        _heldButtons.add(button);
      } else {
        _heldButtons.remove(button);
      }
    });
  }

  @override
  void scroll(double dx, double dy) {
    guarded('scroll', () {
      // dy > 0 means "content moves down", i.e. the wheel turns towards the
      // user, which Windows reports as a negative delta.
      final v = _wheelY.add(-dy).clamp(-_maxWheelUnits, _maxWheelUnits).toInt();
      if (v != 0) _mouse(MOUSEEVENTF_WHEEL, data: v);
      final h = _wheelX.add(dx).clamp(-_maxWheelUnits, _maxWheelUnits).toInt();
      if (h != 0) _mouse(MOUSEEVENTF_HWHEEL, data: h);
    });
  }

  @override
  void key(int usbHid, bool down) {
    guarded('key', () {
      if (_sendKey(usbHid, down)) {
        if (down) {
          _heldKeys.add(usbHid);
        } else {
          _heldKeys.remove(usbHid);
        }
      }
    });
  }

  /// Returns false for keys with no Windows mapping.
  bool _sendKey(int usbHid, bool down) {
    final up = down ? 0 : KEYEVENTF_KEYUP;
    final p = _one;
    p.ref.type = INPUT_KEYBOARD;
    final ki = p.ref.ki;
    ki.time = 0;
    ki.dwExtraInfo = 0;
    if (usbHid == hidPause) {
      // Pause has no plain scan code (the real key sends an E1 prefix
      // sequence), so inject it by virtual key.
      ki.wVk = VK_PAUSE;
      ki.wScan = 0;
      ki.dwFlags = up;
    } else {
      final entry = hidToWinScancode[usbHid];
      if (entry == null) {
        implLog('no Windows scan code for HID usage');
        return false;
      }
      ki.wVk = 0;
      ki.wScan = winScanCode(entry);
      ki.dwFlags =
          KEYEVENTF_SCANCODE |
          (winScanIsExtended(entry) ? KEYEVENTF_EXTENDEDKEY : 0) |
          up;
    }
    _submit(p, 1);
    return true;
  }

  @override
  void text(String text) {
    guarded('text', () {
      final pending = <int>[];
      void flush() {
        if (pending.isEmpty) return;
        _typeUnicodeUnits(pending);
        pending.clear();
      }

      for (final unit in text.codeUnits) {
        if (unit == 0x0a) {
          // KEYEVENTF_UNICODE with a newline is ignored by most controls.
          flush();
          _tap(hidEnter);
        } else if (unit == 0x09) {
          flush();
          _tap(hidTab);
        } else if (unit < 0x20 || unit == 0x7f) {
          continue;
        } else {
          pending.add(unit);
          if (pending.length >= _textBatchUnits) flush();
        }
      }
      flush();
    });
  }

  void _tap(int usbHid) {
    _sendKey(usbHid, true);
    _sendKey(usbHid, false);
  }

  /// Sends each UTF-16 unit as a key-down/key-up pair of `KEYEVENTF_UNICODE`
  /// packets in a single atomic `SendInput`, so concurrent physical input
  /// cannot interleave with a surrogate pair.
  void _typeUnicodeUnits(List<int> units) {
    final count = units.length * 2;
    final buf = calloc<INPUT>(count);
    try {
      for (var i = 0; i < units.length; i++) {
        for (var phase = 0; phase < 2; phase++) {
          final input = buf[i * 2 + phase];
          input.type = INPUT_KEYBOARD;
          final ki = input.ki;
          ki.wVk = 0;
          ki.wScan = units[i];
          ki.dwFlags = KEYEVENTF_UNICODE | (phase == 0 ? 0 : KEYEVENTF_KEYUP);
          ki.time = 0;
          ki.dwExtraInfo = 0;
        }
      }
      _submit(buf, count);
    } finally {
      calloc.free(buf);
    }
  }

  @override
  Future<void> special(SpecialAction action) async {
    try {
      switch (action) {
        case SpecialAction.lock:
          if (LockWorkStation() == 0) implLog('LockWorkStation failed');
        case SpecialAction.ctrlAltDel:
          _sendSas();
        case SpecialAction.back ||
            SpecialAction.home ||
            SpecialAction.recents ||
            SpecialAction.notifications ||
            SpecialAction.power:
          break; // Android-only actions.
      }
    } catch (e) {
      implLog('special action failed', e);
    }
  }

  /// `SendSAS` only works for services or when the "Software SAS generation"
  /// policy allows it; for a normal desktop app it silently does nothing.
  void _sendSas() {
    try {
      final sas = DynamicLibrary.open('sas.dll');
      final sendSas = sas
          .lookupFunction<Void Function(Int32), void Function(int)>('SendSAS');
      sendSas(0);
    } catch (e) {
      implLog('SendSAS unavailable', e);
    }
  }

  @override
  void releaseAll() {
    guarded('releaseAll', () {
      for (final usage in _heldKeys.toList()) {
        _sendKey(usage, false);
      }
      _heldKeys.clear();
      for (final button in _heldButtons.toList()) {
        mouseButton(button, false);
      }
      _heldButtons.clear();
      _wheelX.reset();
      _wheelY.reset();
    });
  }

  void _mouse(int flags, {int dx = 0, int dy = 0, int data = 0}) {
    final p = _one;
    p.ref.type = INPUT_MOUSE;
    final mi = p.ref.mi;
    mi.dx = dx;
    mi.dy = dy;
    mi.mouseData = data;
    mi.dwFlags = flags;
    mi.time = 0;
    mi.dwExtraInfo = 0;
    _submit(p, 1);
  }

  void _submit(Pointer<INPUT> inputs, int count) {
    final sent = SendInput(count, inputs, sizeOf<INPUT>());
    _rejectedAt = sent == count ? null : DateTime.now();
    if (sent != count) {
      // Typically UIPI: the foreground window is elevated or on the secure
      // desktop (UAC / lock screen) and this process is not.
      implLog('SendInput injected $sent of $count events');
    }
  }
}
