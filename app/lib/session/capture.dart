import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/log.dart';
import '../platform/host_platform.dart';

const _log = Logger('capture');

/// Starts screen capture for a [HostDisplay].
class ScreenCapture {
  /// Whether a running capture can be restarted for another display or frame
  /// rate. Desktop can; Android cannot (each capture needs fresh user consent).
  static bool get canRetarget => !(Platform.isAndroid || Platform.isIOS);

  /// Desktop: picks the `desktopCapturer` screen source matching the display
  /// (by [HostDisplay.captureSourceId], else by index); Android: the system
  /// MediaProjection picker via `getDisplayMedia`.
  static Future<MediaStream> start(
    HostDisplay display,
    List<HostDisplay> all, {
    int fps = 30,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
    }
    final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
    if (sources.isEmpty) throw StateError('No screen sources available');
    DesktopCapturerSource? source;
    final wanted = display.captureSourceId;
    if (wanted != null) {
      for (final s in sources) {
        if (s.id == wanted) source = s;
      }
    }
    if (source == null) {
      final index = all.indexWhere((d) => d.id == display.id);
      source = sources[(index < 0 ? 0 : index).clamp(0, sources.length - 1)];
      _log.d('capture source matched by index');
    }
    return navigator.mediaDevices.getDisplayMedia({
      'video': {
        'deviceId': {'exact': source.id},
        'mandatory': {'frameRate': fps.toDouble()},
      },
      'audio': false,
    });
  }
}

/// Counts concurrent captures so the platform's capture service (Android
/// foreground service) starts with the first and stops after the last.
class CaptureRegistry {
  int _active = 0;

  int get active => _active;

  Future<void> acquire(HostPlatform platform) async {
    if (_active == 0) await platform.beforeCapture();
    _active++;
  }

  Future<void> release(HostPlatform platform) async {
    if (_active == 0) return;
    _active--;
    if (_active == 0) await platform.afterCapture();
  }
}
