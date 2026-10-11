import 'dart:io' show Platform;

import '../core/log.dart';

const _log = Logger('dock');

/// INTEGRATION POINT: macOS Dock icon visibility.
///
/// While the main window is hidden in the tray the Dock icon must disappear
/// (product requirement), and come back when the window is shown. The native
/// side exposes this as `MacosHostPlatform.setDockIconVisible(bool)`, which
/// does not exist yet. When it lands, replace the body below with:
///
/// ```dart
/// final p = HostPlatform.instance;
/// if (p is MacosHostPlatform) await p.setDockIconVisible(visible);
/// ```
///
/// Everything else (calling this on hide / show, only on macOS) is already
/// wired in `DesktopImpl`.
Future<void> setDockIconVisible(bool visible) async {
  if (!Platform.isMacOS) return;
  _log.d('dock icon visible=$visible (native hook not available yet)');
}
