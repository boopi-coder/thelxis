import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../desktop/desktop_integration.dart';
import '../session/session_manager.dart';
import '../session/session_base.dart';
import '../session/viewer_session.dart';
import 'devices/command_palette.dart';
import 'devices/devices_screen.dart';
import 'home/controlled_banner.dart';
import 'home/home_screen.dart';
import 'session/session_view.dart';
import 'sessions_screen.dart';
import 'settings/settings_screen.dart';
import 'shell_controller.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/thelxis_logo.dart';

/// Main window layout: navigation rail (wide) or bottom bar (narrow), page
/// stack, the "controlled by" banner, and session tabs on desktop.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  static const _destinations = [
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.devices_other_outlined, Icons.devices_other_rounded, 'Devices'),
    (Icons.history_toggle_off_rounded, Icons.history_rounded, 'Sessions'),
    (Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final shell = context.watch<ShellController>();
    final manager = context.watch<SessionManager>();
    final desktop = context.read<DesktopIntegration>();
    final front = shell.front;
    final isDesktop = desktop.isDesktop;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => showCommandPalette(context),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => showCommandPalette(context),
      },
      child: Focus(
        autofocus: true,
        child: ValueListenableBuilder<bool>(
          valueListenable: desktop.fullScreen,
          builder: (context, fullScreen, _) {
            final immersive = fullScreen && front != null;
            return Scaffold(
              body: Column(
                children: [
                  if (!immersive) const ControlledBanner(),
                  if (!immersive && isDesktop && manager.viewerSessions.isNotEmpty)
                    SessionTabStrip(shell: shell, manager: manager),
                  Expanded(
                    child: front != null
                        ? _frontSession(front, isDesktop)
                        : _pages(context, shell),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _frontSession(ViewerSession session, bool isDesktop) {
    final view = SessionView(key: ValueKey(session.sid), session: session);
    if (isDesktop) return view;
    // Android back minimises the session instead of leaving the app.
    return Builder(
      builder: (context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) context.read<ShellController>().showPages();
        },
        child: view,
      ),
    );
  }

  Widget _pages(BuildContext context, ShellController shell) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final stack = IndexedStack(
      index: shell.page,
      children: [
        const HomeScreen(),
        DevicesScreen(active: shell.page == ShellController.pageDevices),
        const SessionsScreen(),
        const SettingsScreen(),
      ],
    );
    if (!wide) {
      return Column(
        children: [
          Expanded(child: SafeArea(bottom: false, child: stack)),
          NavigationBar(
            selectedIndex: shell.page,
            onDestinationSelected: shell.goTo,
            destinations: [
              for (final d in _destinations)
                NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3),
            ],
          ),
        ],
      );
    }
    return Row(
      children: [
        NavigationRail(
          selectedIndex: shell.page,
          onDestinationSelected: shell.goTo,
          leading: const Padding(
            padding: EdgeInsets.symmetric(vertical: Gap.l),
            child: ThelxisLogo(size: 40),
          ),
          destinations: [
            for (final d in _destinations)
              NavigationRailDestination(
                icon: Icon(d.$1),
                selectedIcon: Icon(d.$2),
                label: Text(d.$3),
              ),
          ],
        ),
        Expanded(child: stack),
      ],
    );
  }
}

/// Desktop tab strip: Home plus one tab per outgoing session.
class SessionTabStrip extends StatelessWidget {
  const SessionTabStrip({super.key, required this.shell, required this.manager});

  final ShellController shell;
  final SessionManager manager;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLowest,
      child: SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 6),
          children: [
            _Tab(
              selected: shell.front == null,
              onTap: shell.showPages,
              leading: const Icon(Icons.home_rounded, size: 18),
              label: 'Thelxis',
            ),
            for (final s in manager.viewerSessions)
              _SessionTab(
                session: s,
                selected: shell.front == s,
                onTap: () => shell.showSession(s),
                onClose: () async {
                  await s.end('user');
                  shell.sessionClosed(s);
                  WidgetsBinding.instance.addPostFrameCallback((_) => manager.dismiss(s));
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _SessionTab extends StatelessWidget {
  const _SessionTab({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final ViewerSession session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final s = context.status;
        final dot = switch (session.phase) {
          SessionPhase.active => s.good,
          SessionPhase.ended => s.bad,
          SessionPhase.reconnecting => s.bad,
          _ => s.warn,
        };
        return _Tab(
          selected: selected,
          onTap: onTap,
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(osIcon(session.peer.os), size: 18),
              Positioned(
                right: -3,
                bottom: -3,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
              ),
            ],
          ),
          label: session.peer.name,
          onClose: onClose,
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.selected,
    required this.onTap,
    required this.leading,
    required this.label,
    this.onClose,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget leading;
  final String label;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                leading,
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(label, overflow: TextOverflow.ellipsis),
                ),
                if (onClose != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: onClose,
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
