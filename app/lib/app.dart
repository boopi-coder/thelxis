import 'dart:async';

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
import 'l10n/framework_localizations.dart';
import 'l10n/strings.dart';
import 'ui/dialogs/prompt_host.dart';
import 'ui/file_notice_toaster.dart';
import 'update/ui/updated_toast.dart';
import 'update/update_service.dart';
import 'ui/shell.dart';
import 'ui/shell_controller.dart';
import 'ui/theme.dart';

/// Root widget: provides the services to the tree and sets up theming,
/// navigation and the prompt overlay.
class ThelxisApp extends StatefulWidget {
  const ThelxisApp({
    super.key,
    required this.services,
    this.initialInvite,
  });

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
  void initState() {
    super.initState();
    // The updater learns it was just updated (`--updated`, or a version bump
    // since the last run) asynchronously; show the toast once when it does.
    widget.services.updates.addListener(_maybeShowUpdatedToast);
  }

  @override
  void dispose() {
    widget.services.updates.removeListener(_maybeShowUpdatedToast);
    _shell.dispose();
    super.dispose();
  }

  void _maybeShowUpdatedToast() {
    final updates = widget.services.updates;
    final version = updates.justUpdatedVersion;
    if (version == null) return;
    updates.acknowledgeUpdated();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The Scaffold lives below the navigator: use the home route's context.
      final ctx = _navigatorKey.currentState?.overlay?.context;
      if (ctx != null && ctx.mounted) showUpdatedToast(ctx, version);
    });
  }

  /// The UI language: the user's override, else Russian for `ru` system
  /// locales and English for everything else.
  static Locale effectiveLocale(String setting) {
    final system = WidgetsBinding.instance.platformDispatcher.locale;
    return Locale(resolveLanguage(setting, system).code);
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
        ChangeNotifierProvider<UpdateService>.value(value: s.updates),
      ],
      child: Consumer<AppSettings>(
        builder: (context, settings, _) {
          final locale = effectiveLocale(settings.language);
          // Session and network code has no BuildContext; keep it in step.
          S.current = S.forLocale(locale);
          return MaterialApp(
            navigatorKey: _navigatorKey,
            title: 'Thelxis',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light),
            darkTheme: buildTheme(Brightness.dark),
            themeMode: settings.themeMode,
            locale: locale,
            supportedLocales: const [Locale('en'), Locale('ru')],
            localizationsDelegates: frameworkLocalizationsDelegates,
            builder: (context, child) => PromptHost(
              navigatorKey: _navigatorKey,
              child: FileNoticeToaster(
                navigatorKey: _navigatorKey,
                child: _DesktopSync(child: child ?? const SizedBox.shrink()),
              ),
            ),
            home: const AppShell(),
          );
        },
      ),
    );
  }
}

/// Keeps the tray (tooltip, localized menu, Allow-incoming check) in step
/// with the settings and the live sessions.
class _DesktopSync extends StatefulWidget {
  const _DesktopSync({required this.child});

  final Widget child;

  @override
  State<_DesktopSync> createState() => _DesktopSyncState();
}

class _DesktopSyncState extends State<_DesktopSync> {
  SessionManager? _manager;
  AppSettings? _settings;
  DesktopIntegration? _desktop;
  String _lastTooltip = '';
  String _lastMenuKey = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _desktop = context.read<DesktopIntegration>();
    final m = context.read<SessionManager>();
    if (!identical(m, _manager)) {
      _manager?.removeListener(_update);
      _manager = m..addListener(_update);
    }
    final st = context.read<AppSettings>();
    if (!identical(st, _settings)) {
      _settings?.removeListener(_update);
      _settings = st..addListener(_update);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _manager?.removeListener(_update);
    _settings?.removeListener(_update);
    super.dispose();
  }

  Locale effectiveLocaleOf(AppSettings settings) => _ThelxisAppState.effectiveLocale(settings.language);

  void _update() {
    final desktop = _desktop;
    final settings = _settings;
    if (desktop == null || settings == null || !desktop.isDesktop) return;
    final s = S.forLocale(effectiveLocaleOf(settings));

    final live = _manager?.liveHostSessions ?? const [];
    final tooltip = live.isEmpty
        ? 'Thelxis'
        : 'Thelxis — ${s.t('banner.controlledBy', {'names': live.map((x) => x.peer.name).join(', ')})}';
    if (tooltip != _lastTooltip) {
      _lastTooltip = tooltip;
      unawaited(desktop.setTrayStatus(tooltip));
    }

    final menuKey = '${s.language.code}|${settings.allowIncoming}';
    if (menuKey != _lastMenuKey) {
      _lastMenuKey = menuKey;
      unawaited(desktop.updateTrayMenu(
        TrayMenuLabels(
          open: s.t('tray.open'),
          copyId: s.t('tray.copyId'),
          allowIncoming: s.t('tray.allowIncoming'),
          quit: s.t('tray.quit'),
        ),
        allowIncoming: settings.allowIncoming,
      ));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
