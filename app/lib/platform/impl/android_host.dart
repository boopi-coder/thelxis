// Android host. Everything native lives behind the MethodChannel
// `io.thelxis/host` (HostChannel.kt):
//   * input   -> ThelxisAccessibilityService (gesture synthesis, text, global actions)
//   * capture -> CaptureService (foreground service, type mediaProjection)
//   * keep-alive -> PresenceService (foreground service, type specialUse)
//
// ---------------------------------------------------------------------------
// SCREEN CAPTURE CALL ORDER (Android 10-15). The core must do exactly:
//
//     await HostPlatform.instance.beforeCapture();
//     final stream = await navigator.mediaDevices.getDisplayMedia({'video': true});
//     ...
//     await HostPlatform.instance.afterCapture();   // after the last track stopped
//
// Why `beforeCapture()` does more than starting a service. flutter_webrtc
// 1.6.2 (GetUserMediaImpl.java) has no foreground service of its own:
//   1. `getDisplayMedia` shows the MediaProjection consent dialog itself unless
//      `mediaProjectionData` is already set, and the moment the dialog returns
//      it calls `MediaProjectionManager.getMediaProjection(...)`
//      (OrientationAwareScreenCapturer.startCapture).
//   2. From Android 10 `getMediaProjection` requires a running foreground
//      service of type mediaProjection, and from Android 14 that service may
//      only be started AFTER the user granted consent (otherwise startForeground
//      throws SecurityException) and BEFORE `getMediaProjection`.
// With the stock flow the service would have to exist before the consent and
// after it at the same time. The only window is between the two flutter_webrtc
// steps, so we split them: `Helper.requestCapturePermission` runs the consent
// dialog and stores the result in `mediaProjectionData`; we then start
// CaptureService and wait until it called startForeground; finally
// `getDisplayMedia` finds `mediaProjectionData` set, skips the dialog and its
// `getMediaProjection` call succeeds. The consent token is single use on
// Android 14+, which is why every capture goes through this sequence again.
//
// If the user declines, `beforeCapture()` throws CapturePermissionDenied; the
// core must NOT call getDisplayMedia then (it would open the dialog a second
// time without a foreground service and crash on Android 14+).
// ---------------------------------------------------------------------------

import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;

import '../host_platform.dart';
import 'hid_ascii.dart';
import 'hid_usage.dart';
import 'impl_log.dart';

/// Thrown by [AndroidHostPlatform.beforeCapture] when screen capture cannot
/// start (consent declined or the foreground service refused to start).
class CapturePermissionDenied implements Exception {
  const CapturePermissionDenied(this.message);
  final String message;

  @override
  String toString() => 'CapturePermissionDenied: $message';
}

const MethodChannel _channel = MethodChannel('io.thelxis/host');

/// Upper bound for the system's screen-capture consent dialog.
const Duration _consentTimeout = Duration(seconds: 120);

/// Fire-and-forget channel call: input must never block or throw.
void _send(String method, [Object? arguments]) {
  _channel.invokeMethod<void>(method, arguments).catchError((Object e) {
    implLog('channel $method failed', e);
  });
}

class AndroidHostPlatform implements HostPlatform {
  final AndroidInputInjector _input = AndroidInputInjector();
  final StreamController<void> _captureStopRequests =
      StreamController<void>.broadcast();

  bool _handlerInstalled = false;
  bool _captureActive = false;

  /// Installed lazily: `HostPlatform.instance` may be touched before the
  /// Flutter binding exists.
  void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'captureStopRequested') {
        _captureStopRequests.add(null);
      }
      return null;
    });
  }

  /// Fires when the user taps "Stop" in the screen-sharing notification. The
  /// foreground service has already stopped; the core should end capture and
  /// the session.
  Stream<void> get captureStopRequests {
    _installHandler();
    return _captureStopRequests.stream;
  }

  @override
  bool get hostSupported => true;

  @override
  bool get inputSupported => true;

  @override
  Future<PermissionStatus> permissionStatus(HostPermission permission) async {
    try {
      switch (permission) {
        case HostPermission.inputControl:
          final on = await _channel.invokeMethod<bool>(
            'isAccessibilityEnabled',
          );
          return (on ?? false)
              ? PermissionStatus.granted
              : PermissionStatus.denied;
        case HostPermission.notifications:
          final on = await _channel.invokeMethod<bool>('notificationsGranted');
          return (on ?? false)
              ? PermissionStatus.granted
              : PermissionStatus.denied;
        case HostPermission.screenCapture:
          return PermissionStatus.notRequired; // asked for each capture
      }
    } catch (e) {
      implLog('permissionStatus failed', e);
      return PermissionStatus.denied;
    }
  }

  @override
  Future<void> requestPermission(HostPermission permission) async {
    try {
      switch (permission) {
        case HostPermission.inputControl:
          await _channel.invokeMethod<void>('openAccessibilitySettings');
        case HostPermission.notifications:
          await _channel.invokeMethod<bool>('requestNotifications');
        case HostPermission.screenCapture:
          break;
      }
    } catch (e) {
      implLog('requestPermission failed', e);
    }
  }

  @override
  Future<List<HostDisplay>> displays() async {
    var width = 1080;
    var height = 1920;
    try {
      final info = await _channel.invokeMapMethod<String, Object?>(
        'displayInfo',
      );
      width = (info?['width'] as num?)?.toInt() ?? width;
      height = (info?['height'] as num?)?.toInt() ?? height;
    } catch (e) {
      implLog('displayInfo failed', e);
    }
    return [
      HostDisplay(
        id: '0',
        name: 'Screen',
        bounds: Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        pixelWidth: width,
        pixelHeight: height,
        primary: true,
      ),
    ];
  }

  @override
  Future<void> beforeCapture() async {
    _installHandler();
    if (_captureActive) return;
    // fullScreenOnly: remove the "single app" choice on Android 14+; a remote
    // desktop must show the whole screen.
    // flutter_webrtc never answers when the Activity is gone (app swiped away
    // or in the background), so bound the wait.
    final granted = await Helper.requestCapturePermission(fullScreenOnly: true)
        .timeout(_consentTimeout, onTimeout: () => false);
    if (!granted) {
      throw const CapturePermissionDenied('screen capture consent declined');
    }
    try {
      await _channel.invokeMethod<bool>('startCaptureService');
    } on PlatformException catch (e) {
      throw CapturePermissionDenied(
        'foreground service did not start: ${e.code} ${e.message ?? ''}',
      );
    }
    _captureActive = true;
  }

  @override
  Future<void> afterCapture() async {
    _captureActive = false;
    try {
      await _channel.invokeMethod<void>('stopCaptureService');
    } catch (e) {
      implLog('stopCaptureService failed', e);
    }
  }

  /// Keeps the process alive in the background while "Allow incoming" is on
  /// (foreground service, type specialUse). Safe to call repeatedly.
  Future<void> startPresence() async {
    try {
      await _channel.invokeMethod<void>('startPresence');
    } catch (e) {
      implLog('startPresence failed', e);
    }
  }

  Future<void> stopPresence() async {
    try {
      await _channel.invokeMethod<void>('stopPresence');
    } catch (e) {
      implLog('stopPresence failed', e);
    }
  }

  /// Wi-Fi multicast lock: without it Android filters incoming multicast and
  /// broadcast datagrams to save power, which breaks SSDP/UPnP replies and
  /// LAN discovery. Hold it while discovery or port mapping runs.
  Future<void> acquireMulticastLock() async {
    try {
      await _channel.invokeMethod<void>('acquireMulticastLock');
    } catch (e) {
      implLog('acquireMulticastLock failed', e);
    }
  }

  Future<void> releaseMulticastLock() async {
    try {
      await _channel.invokeMethod<void>('releaseMulticastLock');
    } catch (e) {
      implLog('releaseMulticastLock failed', e);
    }
  }

  @override
  InputInjector get input => _input;
}

class AndroidInputInjector implements InputInjector {
  /// Minimum spacing of forwarded pointer moves; the service re-throttles to
  /// the gesture rate anyway, this just keeps the platform channel quiet.
  static const Duration _moveInterval = Duration(milliseconds: 8);

  ({double x, double y})? _pendingMove;
  Timer? _moveTimer;

  final Set<int> _heldModifiers = <int>{};
  bool _caps = false;

  /// Keys whose press was delivered as text; their release is swallowed.
  final Set<int> _textKeys = <int>{};

  @override
  void mouseMove(HostDisplay display, double nx, double ny) {
    guarded('mouseMove', () {
      _pendingMove = (x: nx, y: ny);
      if (_moveTimer != null) return; // trailing edge will send the latest
      _flushMove();
      _moveTimer = Timer(_moveInterval, () {
        _moveTimer = null;
        _flushMove();
      });
    });
  }

  void _flushMove() {
    final move = _pendingMove;
    if (move == null) return;
    _pendingMove = null;
    _send('mouseMove', {'nx': move.x, 'ny': move.y});
  }

  @override
  void mouseButton(MouseButton button, bool down) {
    guarded('mouseButton', () {
      _flushMove(); // the press must happen at the latest position
      _send('mouseButton', {'button': button.index, 'down': down});
    });
  }

  @override
  void scroll(double dx, double dy) {
    guarded('scroll', () => _send('scroll', {'dx': dx, 'dy': dy}));
  }

  @override
  void key(int usbHid, bool down) {
    guarded('key', () {
      if (isHidModifier(usbHid)) {
        if (down) {
          _heldModifiers.add(usbHid);
        } else {
          _heldModifiers.remove(usbHid);
        }
        return;
      }
      if (usbHid == hidCapsLock) {
        if (down) _caps = !_caps;
        return;
      }
      if (!down) {
        // The press became text, so there is nothing to release natively.
        if (_textKeys.remove(usbHid)) return;
      } else {
        final shortcut = _heldModifiers.any(
          (m) => m != hidLeftShift && m != hidRightShift,
        );
        if (!shortcut) {
          final shift =
              _heldModifiers.contains(hidLeftShift) ||
              _heldModifiers.contains(hidRightShift);
          final ch = asciiForHid(usbHid, shift: shift, caps: _caps);
          if (ch != null) {
            _textKeys.add(usbHid);
            _send('text', {'s': ch});
            return;
          }
        }
      }
      _send('key', {'hid': usbHid, 'down': down});
    });
  }

  @override
  void text(String text) {
    guarded('text', () => _send('text', {'s': text}));
  }

  @override
  Future<void> special(SpecialAction action) async {
    try {
      await _channel.invokeMethod<bool>('special', {'action': action.name});
    } catch (e) {
      implLog('special failed', e);
    }
  }

  @override
  void releaseAll() {
    guarded('releaseAll', () {
      _moveTimer?.cancel();
      _moveTimer = null;
      _pendingMove = null;
      _heldModifiers.clear();
      _textKeys.clear();
      _send('releaseAll');
    });
  }
}
