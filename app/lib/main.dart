import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'app_services.dart';
import 'core/identity.dart';
import 'core/log.dart';
import 'core/system_info.dart';
import 'desktop/desktop_impl.dart';
import 'desktop/desktop_integration.dart';
import 'net/connectivity/connectivity.dart';
import 'platform/host_platform.dart';

const _log = Logger('main');

Future<void> main(List<String> args) async {
  await runZonedGuarded(() => _boot(args), (error, stack) {
    _log.e('uncaught error', error, stack);
  });
}

Future<void> _boot(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    _log.e('flutter error: ${details.exceptionAsString()}', null, details.stack);
  };

  final prefs = await SharedPreferences.getInstance();
  final identity = await Identity.loadOrCreate();
  final systemInfo = await SystemInfo.load();
  final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  late final AppServices services;
  DesktopIntegration? desktop;
  if (isDesktop) {
    desktop = await DesktopImpl.init(
      idText: identity.formattedId,
      launchAtStartupEnabled: prefs.getBool('launch_at_startup') ?? false,
      onBeforeQuit: () => services.sessions.endAll(),
    );
  }

  services = AppServices.create(
    prefs: prefs,
    identity: identity,
    systemInfo: systemInfo,
    connectivity: Connectivity.instance,
    platform: HostPlatform.instance,
    desktop: desktop,
  );

  final invite = args.where((a) => a.toLowerCase().startsWith('thelxis:')).firstOrNull;
  runApp(ThelxisApp(services: services, initialInvite: invite));
  // Networking starts after the first frame so the window appears instantly.
  unawaited(services.sessions.start());
  if (kDebugMode) _log.i('Thelxis ${systemInfo.appVersion} started, ID ${identity.formattedId}');
}
