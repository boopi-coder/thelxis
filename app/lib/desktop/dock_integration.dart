import 'dart:io' show Platform;

import '../platform/host_platform.dart';
import '../platform/impl/macos_host.dart';

/// macOS Dock icon visibility: while the main window is hidden in the tray the
/// Dock icon disappears (product requirement) and comes back when the window
/// is shown. Called by `DesktopImpl` on hide / show.
Future<void> setDockIconVisible(bool visible) async {
  if (!Platform.isMacOS) return;
  final platform = HostPlatform.instance;
  if (platform is MacosHostPlatform) await platform.setDockIconVisible(visible);
}
