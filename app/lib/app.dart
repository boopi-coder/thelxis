import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_services.dart';
import 'core/address_book.dart';
import 'core/identity.dart';
import 'core/settings.dart';
import 'core/system_info.dart';
import 'core/trusted_devices.dart';
import 'desktop/desktop_integration.dart';
import 'net/connectivity/connectivity.dart';
import 'net/discovery.dart';
import 'platform/host_platform.dart';
import 'session/host_credentials.dart';
import 'session/session_history.dart';
import 'session/session_manager.dart';
import 'ui/dialogs/prompt_host.dart';
import 'ui/shell.dart';
import 'ui/shell_controller.dart';
import 'ui/theme.dart';

/// Root widget: provides the services to the tree and sets up theming,
/// navigation and the prompt overlay.
class ThelxisApp extends StatefulWidget {
  const ThelxisApp({super.key, required this.services, this.initialInvite});

  final AppServices services;

  /// A `thelxis://connect?...` link the app was launched with.
  final String? initialInvite;

  @override
  State<ThelxisApp> createState() => _ThelxisAppState();
}

class _ThelxisAppState extends State<ThelxisApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final ShellController _shell = ShellController(pendingInvite: widget.initialInvite);

  @override
  void dispose() {
    _shell.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: s),
        Provider<Identity>.value(value: s.identity),
        Provider<SystemInfo>.value(value: s.systemInfo),
        Provider<Connectivity>.value(value: s.connectivity),
        Provider<HostPlatform>.value(value: s.platform),
        Provider<DesktopIntegration>.value(value: s.desktop),
        ChangeNotifierProvider<AppSettings>.value(value: s.settings),
        ChangeNotifierProvider<SessionManager>.value(value: s.sessions),
        ChangeNotifierProvider<AddressBook>.value(value: s.addressBook),
        ChangeNotifierProvider<TrustedDevices>.value(value: s.trusted),
        ChangeNotifierProvider<HostCredentials>.value(value: s.credentials),
        ChangeNotifierProvider<LanDiscovery>.value(value: s.lan),
        ChangeNotifierProvider<SessionHistory>.value(value: s.history),
        ChangeNotifierProvider<ShellController>.value(value: _shell),
      ],
      child: Consumer<AppSettings>(
        builder: (context, settings, _) => MaterialApp(
          navigatorKey: _navigatorKey,
          title: 'Thelxis',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: settings.themeMode,
          builder: (context, child) => PromptHost(
            navigatorKey: _navigatorKey,
            child: _TrayStatusSync(child: child ?? const SizedBox.shrink()),
          ),
          home: const AppShell(),
        ),
      ),
    );
  }
}

/// Mirrors "Controlled by …" into the tray tooltip.
class _TrayStatusSync extends StatefulWidget {
  const _TrayStatusSync({required this.child});

  final Widget child;

  @override
  State<_TrayStatusSync> createState() => _TrayStatusSyncState();
}

class _TrayStatusSyncState extends State<_TrayStatusSync> {
  SessionManager? _manager;
  DesktopIntegration? _desktop;
  String _last = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _desktop = context.read<DesktopIntegration>();
    final m = context.read<SessionManager>();
    if (!identical(m, _manager)) {
      _manager?.removeListener(_update);
      _manager = m..addListener(_update);
    }
  }

  @override
  void dispose() {
    _manager?.removeListener(_update);
    super.dispose();
  }

  void _update() {
    final live = _manager?.activeHostSessions ?? const [];
    final text = live.isEmpty ? 'Thelxis' : 'Thelxis — controlled by ${live.map((s) => s.peer.name).join(', ')}';
    if (text == _last) return;
    _last = text;
    _desktop?.setTrayStatus(text);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
