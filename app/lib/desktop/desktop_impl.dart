import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import '../core/log.dart';
import 'desktop_integration.dart';

const _log = Logger('desktop');

/// Window, tray icon and autostart for Windows, macOS and Linux.
///
/// Closing the window hides it to the tray so the device stays reachable; the
/// tray menu offers Show, Copy ID and Quit. Without a working tray (some
/// Linux desktops) closing minimises instead, so the app is never lost.
class DesktopImpl with WindowListener implements DesktopIntegration {
  DesktopImpl._({required this._onBeforeQuit, required this._idText});

  final Future<void> Function() _onBeforeQuit;
  final String _idText;
  final ValueNotifier<bool> _fullScreen = ValueNotifier(false);

  // Kept alive for as long as the icon should be shown (native handle).
  tray.TrayIcon? _trayIcon;
  final List<Object> _keepAlive = [];
  bool _hasTray = false;
  bool _quitting = false;

  static Future<DesktopImpl> init({
    required Future<void> Function() onBeforeQuit,
    required String idText,
    required bool launchAtStartupEnabled,
  }) async {
    final d = DesktopImpl._(onBeforeQuit: onBeforeQuit, idText: idText);
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1100, 720),
      minimumSize: Size(900, 600),
      center: true,
      title: 'Thelxis',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
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

      final menu = tray.Menu.create();
      if (menu == null) throw StateError('tray menu unavailable');
      tray.MenuItem? add(String label, VoidCallback onTap) {
        final item = tray.MenuItem.createWithLabelAndType(label, tray.MenuItemType.normal);
        if (item == null) return null;
        item.addListener((event) {
          if (event is tray.MenuItemClickedEvent) onTap();
        });
        menu.addItem(item);
        _keepAlive.add(item);
        return item;
      }

      add('Show Thelxis', () => unawaited(bringToFront()));
      add('Copy my ID', () => unawaited(Clipboard.setData(ClipboardData(text: _idText))));
      menu.addSeparator();
      add('Quit', () => unawaited(quit()));

      icon.setContextMenu(menu);
      icon.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
      icon.addListener((event) {
        if (event is tray.TrayIconClickedEvent) unawaited(bringToFront());
      });
      icon.setVisible(true);
      _trayIcon = icon;
      _keepAlive.add(menu);
      _hasTray = true;
    } on Object catch (e) {
      _log.w('system tray unavailable, closing the window will minimise it', e);
    }
  }

  Future<void> _initAutostart(bool enabled) async {
    try {
      // Same name as the Windows installer's Run value, to avoid duplicates.
      launchAtStartup.setup(appName: 'Thelxis', appPath: Platform.resolvedExecutable);
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
      await _onBeforeQuit();
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
    } else {
      unawaited(windowManager.minimize());
    }
  }

  @override
  void onWindowEnterFullScreen() => _fullScreen.value = true;

  @override
  void onWindowLeaveFullScreen() => _fullScreen.value = false;
}
