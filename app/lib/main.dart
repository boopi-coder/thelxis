import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'app_services.dart';
import 'core/identity.dart';
import 'core/log.dart';
import 'core/log_file.dart';
import 'core/system_info.dart';
import 'desktop/desktop_impl.dart';
import 'desktop/desktop_integration.dart';
import 'net/connectivity/connectivity.dart';
import 'platform/host_platform.dart';
import 'platform/session_badge.dart';

const _log = Logger('main');

Future<void> main(List<String> args) async {
  await runZonedGuarded(() => _boot(args), (error, stack) {
    _log.e('uncaught error', error, stack);
  });
}

Future<void> _boot(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // First, so warnings from the rest of startup land in the diagnostic log.
  await LogFile.start();
  FlutterError.onError = (details) {
    _log.e('flutter error: ${details.exceptionAsString()}', null, details.stack);
  };

  final prefs = await SharedPreferences.getInstance();
  final identity = await Identity.loadOrCreate();
  final systemInfo = await SystemInfo.load();
  final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  // `--minimized`: start hidden in the tray (used for login autostart).
  // `--updated`: the OTA installer relaunched us; show the "updated" toast.
  final startMinimized = args.contains('--minimized');
  final updated = args.contains('--updated');

  late final AppServices services;
  DesktopIntegration? desktop;
  if (isDesktop) {
    desktop = await DesktopImpl.init(
      idText: identity.formattedId,
      launchAtStartupEnabled: prefs.getBool('launch_at_startup') ?? false,
      startMinimized: startMinimized,
      onBeforeQuit: () => services.sessions.endAll(),
      onToggleAllowIncoming: (allow) => services.settings.setAllowIncoming(allow),
    );
  }

  services = AppServices.create(
    prefs: prefs,
    identity: identity,
    systemInfo: systemInfo,
    connectivity: Connectivity.instance,
    platform: HostPlatform.instance,
    badge: SessionBadge.instance,
    desktop: desktop,
  );

  final invite = args.where((a) => a.toLowerCase().startsWith('thelxis:')).firstOrNull;
  runApp(ThelxisApp(services: services, initialInvite: invite));
  // Networking starts after the first frame so the window appears instantly.
  unawaited(services.sessions.start());
  unawaited(services.updates.start(updatedFlag: updated));
  unawaited(_logEnvironment(systemInfo));
}

/// Startup header for the diagnostic log; permission queries are platform
/// calls, so this runs after the first frame.
Future<void> _logEnvironment(SystemInfo info) async {
  final perms = <String, String>{};
  for (final p in [HostPermission.screenCapture, HostPermission.inputControl]) {
    try {
      perms[p.name] = (await HostPlatform.instance.permissionStatus(p)).name;
    } on Object {
      perms[p.name] = 'unknown';
    }
  }
  _log.i(environmentHeader(info, perms));
}
