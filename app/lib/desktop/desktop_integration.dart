import 'package:flutter/foundation.dart';

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

  /// Enables or disables starting with the OS.
  Future<void> setLaunchAtStartup(bool enabled);

  /// Updates the tray tooltip / state, e.g. "Controlled by Alice".
  Future<void> setTrayStatus(String text);

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
  Future<void> quit() async {}
}
