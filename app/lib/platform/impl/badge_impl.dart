// Native implementation of the mandatory "being controlled" badge. The
// windows themselves live in the per-OS runners:
//   Windows  windows/runner/session_badge.cpp  (layered Win32 popup, GDI+)
//   macOS    macos/Runner/SessionBadge.swift   (NSPanel + NSVisualEffectView)
//   Linux    linux/runner/session_badge.cc     (GTK3 toplevel, cairo)
//   Android  android/.../SessionBadgeOverlay.kt (overlay window + notification)
// This file is only the channel client.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, MissingPluginException;

import '../session_badge.dart';
import 'badge_args.dart';
import 'impl_log.dart';

SessionBadge createSessionBadge() {
  if (Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isAndroid) {
    return ChannelSessionBadge();
  }
  return _UnsupportedBadge();
}

/// Talks to the native badge over `io.thelxis/badge`.
///
/// Errors from the native side are NOT swallowed: failing to show a security
/// badge must be visible to the caller (core decides what to do). The call is
/// idempotent, so core simply calls [show] again whenever the session set
/// changes.
class ChannelSessionBadge implements SessionBadge {
  /// [tolerateMissingNative] only exists for tests of other code that touch
  /// `SessionBadge.instance` without a native runner behind it; it defaults to
  /// true exactly when running under `flutter test`. In a real build a missing
  /// native badge is a bug and surfaces as an exception.
  ChannelSessionBadge({MethodChannel? channel, bool? tolerateMissingNative})
    : _channel = channel ?? const MethodChannel(badgeChannelName),
      _tolerateMissingNative =
          tolerateMissingNative ??
          Platform.environment.containsKey('FLUTTER_TEST');

  final MethodChannel _channel;
  final bool _tolerateMissingNative;
  final StreamController<void> _stops = StreamController<void>.broadcast();
  bool _handlerInstalled = false;

  /// Installed lazily: `SessionBadge.instance` can be touched before the
  /// Flutter binding exists.
  void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler(_onNativeCall);
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method == 'stopPressed') {
      _stops.add(null);
    } else {
      implLog('unknown badge call ${call.method}');
    }
    return null;
  }

  @override
  Future<void> show(BadgeState state) =>
      _invoke('show', encodeBadgeArgs(state));

  @override
  Future<void> dismiss() => _invoke('dismiss', null);

  Future<void> _invoke(String method, Object? arguments) async {
    _installHandler();
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException catch (e) {
      if (!_tolerateMissingNative) rethrow;
      implLog('badge $method: no native implementation', e);
    }
  }

  @override
  Stream<void> get stopRequests {
    _installHandler();
    return _stops.stream;
  }
}

/// Platforms that cannot host (iOS, web, ...): nothing is ever controlled, so
/// there is nothing to show.
class _UnsupportedBadge implements SessionBadge {
  final StreamController<void> _stops = StreamController<void>.broadcast();

  @override
  Future<void> show(BadgeState state) async {}

  @override
  Future<void> dismiss() async {}

  @override
  Stream<void> get stopRequests => _stops.stream;
}
