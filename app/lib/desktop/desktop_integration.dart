import 'package:flutter/foundation.dart';

/// Localized texts of the tray menu.
class TrayMenuLabels {
  const TrayMenuLabels({
    required this.open,
    required this.copyId,
    required this.allowIncoming,
    required this.quit,
  });

  final String open;
  final String copyId;
  final String allowIncoming;
  final String quit;
}

/// What the UI needs from the desktop shell (window, tray, autostart),
/// without importing any plugin. The real implementation lives in
/// `desktop_impl.dart` and is wired in `main.dart`; tests and Android use
/// [NoopDesktop].
abstract class DesktopIntegration {
  /// True when running on Windows, macOS or Linux.
  bool get isDesktop;

  /// Whether the main window is currently full screen.
  ValueListenable<bool> get fullScreen;

  Future<void> setFullScreen(bool value);

  /// Shows and focuses the main window (incoming request, security notice).
  Future<void> bringToFront();

  /// Enables or disables starting with the OS (hidden in the tray).
  Future<void> setLaunchAtStartup(bool enabled);

  /// Updates the tray tooltip, e.g. "Controlled by Alice".
  Future<void> setTrayStatus(String text);

  /// Rebuilds the tray menu with [labels] and the current Allow-incoming
  /// state (called when the language or the setting changes).
  Future<void> updateTrayMenu(TrayMenuLabels labels, {required bool allowIncoming});

  Future<void> quit();
}

class NoopDesktop implements DesktopIntegration {
  NoopDesktop();

  final ValueNotifier<bool> _fullScreen = ValueNotifier(false);

  @override
  bool get isDesktop => false;

  @override
  ValueListenable<bool> get fullScreen => _fullScreen;

  @override
  Future<void> setFullScreen(bool value) async {
    _fullScreen.value = value;
  }

  @override
  Future<void> bringToFront() async {}

  @override
  Future<void> setLaunchAtStartup(bool enabled) async {}

  @override
  Future<void> setTrayStatus(String text) async {}

  @override
  Future<void> updateTrayMenu(TrayMenuLabels labels, {required bool allowIncoming}) async {}

  @override
  Future<void> quit() async {}
}
