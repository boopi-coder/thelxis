import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import '../core/log.dart';
import 'desktop_integration.dart';
import 'dock_integration.dart';

const _log = Logger('desktop');

/// Window, tray icon and autostart for Windows, macOS and Linux.
///
/// The app is tray-resident: closing the window hides it (and, on macOS, the
/// Dock icon) while the listener keeps running. The tray menu offers Open,
/// Copy ID, an Allow-incoming toggle and Quit; clicking the icon opens the
/// window. Without a working tray (some Linux desktops) closing minimises
/// instead, so the app is never lost.
class DesktopImpl with WindowListener implements DesktopIntegration {
  DesktopImpl._({
    required this.onBeforeQuit,
    required this.idText,
    required this.onToggleAllowIncoming,
  });

  final Future<void> Function() onBeforeQuit;
  final String idText;
  final Future<void> Function(bool allow) onToggleAllowIncoming;
  final ValueNotifier<bool> _fullScreen = ValueNotifier(false);

  // Kept alive for as long as the icon should be shown (native handles).
  tray.TrayIcon? _trayIcon;
  final List<Object> _keepAlive = [];
  bool _hasTray = false;
  bool _quitting = false;
  bool _allowIncoming = true;

  static Future<DesktopImpl> init({
    required Future<void> Function() onBeforeQuit,
    required String idText,
    required Future<void> Function(bool allow) onToggleAllowIncoming,
    required bool launchAtStartupEnabled,
    required bool startMinimized,
  }) async {
    final d = DesktopImpl._(
      onBeforeQuit: onBeforeQuit,
      idText: idText,
      onToggleAllowIncoming: onToggleAllowIncoming,
    );
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1100, 720),
      minimumSize: Size(900, 600),
      center: true,
      title: 'Thelxis',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (startMinimized) {
        await setDockIconVisible(false);
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    });
    await windowManager.setPreventClose(true);
    windowManager.addListener(d);
    await d._initTray();
    await d._initAutostart(launchAtStartupEnabled);
    return d;
  }

  // --- tray ----------------------------------------------------------------

  Future<void> _initTray() async {
    try {
      final icon = tray.TrayIcon.create();
      if (icon == null) throw StateError('tray unavailable');
      final isMac = Platform.isMacOS;
      final asset = isMac
          ? 'assets/icon/tray_template.png'
          : (Platform.isWindows ? 'assets/icon/tray.ico' : 'assets/icon/tray.png');
      final image = tray.ImageAsset.fromAsset(asset) ?? tray.ImageAsset.fromAsset('assets/icon/tray.png');
      if (image != null) {
        icon.icon = image;
        icon.isIconTemplate = isMac;
      }
      icon.setTooltip('Thelxis');
      icon.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
      icon.addListener((event) {
        if (event is tray.TrayIconClickedEvent || event is tray.TrayIconDoubleClickedEvent) {
          unawaited(bringToFront());
        }
      });
      icon.setVisible(true);
      _trayIcon = icon;
      _hasTray = true;
      // Default (English) menu until the app pushes localized labels.
      await updateTrayMenu(
        const TrayMenuLabels(
          open: 'Open Thelxis',
          copyId: 'Copy my ID',
          allowIncoming: 'Allow incoming connections',
          quit: 'Quit',
        ),
        allowIncoming: _allowIncoming,
      );
    } on Object catch (e) {
      _log.w('system tray unavailable, closing the window will minimise it', e);
    }
  }

  @override
  Future<void> updateTrayMenu(TrayMenuLabels labels, {required bool allowIncoming}) async {
    _allowIncoming = allowIncoming;
    final icon = _trayIcon;
    if (icon == null) return;
    try {
      final menu = tray.Menu.create();
      if (menu == null) return;
      final keep = <Object>[menu];

      tray.MenuItem? add(String label, VoidCallback onTap, {tray.MenuItemType type = tray.MenuItemType.normal}) {
        final item = tray.MenuItem.createWithLabelAndType(label, type);
        if (item == null) return null;
        item.addListener((event) {
          if (event is tray.MenuItemClickedEvent) onTap();
        });
        menu.addItem(item);
        keep.add(item);
        return item;
      }

      add(labels.open, () => unawaited(bringToFront()));
      add(labels.copyId, () => unawaited(Clipboard.setData(ClipboardData(text: idText))));
      menu.addSeparator();
      final toggle = add(
        labels.allowIncoming,
        () => unawaited(onToggleAllowIncoming(!_allowIncoming)),
        type: tray.MenuItemType.checkbox,
      );
      toggle?.state = allowIncoming ? tray.MenuItemState.checked : tray.MenuItemState.unchecked;
      menu.addSeparator();
      add(labels.quit, () => unawaited(quit()));

      icon.setContextMenu(menu);
      _keepAlive
        ..clear()
        ..addAll(keep);
    } on Object catch (e) {
      _log.w('updating the tray menu failed', e);
    }
  }

  Future<void> _initAutostart(bool enabled) async {
    try {
      // Same name as the Windows installer's Run value, to avoid duplicates.
      // `--minimized` keeps a login start out of the user's way.
      launchAtStartup.setup(
        appName: 'Thelxis',
        appPath: Platform.resolvedExecutable,
        args: const ['--minimized'],
      );
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } on Object catch (e) {
      _log.w('launch-at-startup unavailable', e);
    }
  }

  // --- DesktopIntegration ---------------------------------------------------

  @override
  bool get isDesktop => true;

  @override
  ValueListenable<bool> get fullScreen => _fullScreen;

  @override
  Future<void> setFullScreen(bool value) async {
    await windowManager.setFullScreen(value);
    _fullScreen.value = value;
  }

  @override
  Future<void> bringToFront() async {
    try {
      await setDockIconVisible(true);
      await windowManager.show();
      await windowManager.focus();
    } on Object catch (e) {
      _log.d('bringToFront failed: $e');
    }
  }

  @override
  Future<void> setLaunchAtStartup(bool enabled) async {
    try {
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } on Object catch (e) {
      _log.w('changing launch-at-startup failed', e);
    }
  }

  @override
  Future<void> setTrayStatus(String text) async {
    _trayIcon?.setTooltip(text.isEmpty ? 'Thelxis' : text);
  }

  @override
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await onBeforeQuit();
    } on Object catch (e) {
      _log.w('cleanup before quit failed', e);
    }
    windowManager.removeListener(this);
    await windowManager.setPreventClose(false);
    _keepAlive.clear();
    _trayIcon?.dispose();
    _trayIcon = null;
    await windowManager.destroy();
  }

  // --- WindowListener -------------------------------------------------------

  @override
  void onWindowClose() {
    if (_quitting) return;
    if (_hasTray) {
      unawaited(windowManager.hide());
      unawaited(setDockIconVisible(false));
    } else {
      unawaited(windowManager.minimize());
    }
  }

  @override
  void onWindowEnterFullScreen() => _fullScreen.value = true;

  @override
  void onWindowLeaveFullScreen() => _fullScreen.value = false;
}
