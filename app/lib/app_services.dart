import 'dart:async';
import 'dart:io' show exit;

import 'core/address_book.dart';
import 'core/identity.dart';
import 'core/log_file.dart';
import 'core/settings.dart';
import 'core/system_info.dart';
import 'core/trusted_devices.dart';
import 'desktop/desktop_integration.dart';
import 'net/connectivity/connectivity.dart';
import 'net/discovery.dart';
import 'net/peer_identity.dart';
import 'platform/host_platform.dart';
import 'platform/session_badge.dart';
import 'session/host_credentials.dart';
import 'session/session_history.dart';
import 'session/session_manager.dart';
import 'update/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's long-lived objects, built once in `main` (or by tests with
/// fakes) and handed to the widget tree.
class AppServices {
  AppServices._({
    required this.settings,
    required this.identity,
    required this.systemInfo,
    required this.trusted,
    required this.addressBook,
    required this.credentials,
    required this.connectivity,
    required this.platform,
    required this.lan,
    required this.history,
    required this.sessions,
    required this.desktop,
    required this.badge,
    required this.updates,
  });

  final AppSettings settings;
  final Identity identity;
  final SystemInfo systemInfo;
  final TrustedDevices trusted;
  final AddressBook addressBook;
  final HostCredentials credentials;
  final Connectivity connectivity;
  final HostPlatform platform;
  final LanDiscovery lan;
  final SessionHistory history;
  final SessionManager sessions;
  final DesktopIntegration desktop;
  final SessionBadge badge;

  /// Over-the-air updates (PROTOCOL.md section 10).
  final UpdateService updates;

  /// Wires everything together. Nothing here touches the network; call
  /// `sessions.start()` afterwards.
  factory AppServices.create({
    required SharedPreferences prefs,
    required Identity identity,
    required SystemInfo systemInfo,
    required Connectivity connectivity,
    required HostPlatform platform,
    required SessionBadge badge,
    DesktopIntegration? desktop,
    UpdateService? updates,
    void Function()? exitApp,
  }) {
    final settings = AppSettings(prefs, defaultDeviceName: systemInfo.defaultDeviceName);
    final trusted = TrustedDevices(prefs);
    final addressBook = AddressBook(prefs);
    final credentials = HostCredentials(identity: identity, settings: settings);
    final history = SessionHistory(settings);
    final desk = desktop ?? NoopDesktop();
    LocalPeerInfo info() => LocalPeerInfo(
          name: settings.deviceName,
          os: systemInfo.os,
          app: systemInfo.appVersion,
        );
    late final SessionManager sessions;
    final lan = LanDiscovery(
      identity: identity,
      localInfo: info,
      signalingPort: () => sessions.listener.port == 0
          ? ThelxisPorts.signalingTcp
          : sessions.listener.port,
    );
    sessions = SessionManager(
      settings: settings,
      identity: identity,
      systemInfo: systemInfo,
      trusted: trusted,
      addressBook: addressBook,
      credentials: credentials,
      connectivity: connectivity,
      platform: platform,
      lan: lan,
      history: history,
      badge: badge,
      onAttention: () => desk.bringToFront(),
    );
    // Installing an update restarts the app, so it waits for every session to
    // end; tell the service the moment the app becomes idle.
    final updateService = updates ??
        UpdateService(
          prefs: prefs,
          isBusy: () => sessions.hasActiveSessions,
          exitApp: exitApp ?? () => unawaited(_gracefulExit(sessions, connectivity, desk)),
        );
    updateService.isBusy = () => sessions.hasActiveSessions;
    var wasBusy = false;
    sessions.addListener(() {
      final busy = sessions.hasActiveSessions;
      if (wasBusy && !busy) updateService.notifyIdle();
      wasBusy = busy;
    });

    return AppServices._(
      settings: settings,
      identity: identity,
      systemInfo: systemInfo,
      trusted: trusted,
      addressBook: addressBook,
      credentials: credentials,
      connectivity: connectivity,
      platform: platform,
      lan: lan,
      history: history,
      sessions: sessions,
      desktop: desk,
      badge: badge,
      updates: updateService,
    );
  }

  /// Quits the way the tray's Quit does: end sessions, stop the listener and
  /// the relay, tear down the tray and window, then exit the process.
  static Future<void> _gracefulExit(
    SessionManager sessions,
    Connectivity connectivity,
    DesktopIntegration desktop,
  ) async {
    try {
      await sessions.endAll();
      await sessions.listener.stop();
      await connectivity.stop();
      await desktop.quit();
    } finally {
      LogFile.instance?.flushSync();
      exit(0);
    }
  }
}
