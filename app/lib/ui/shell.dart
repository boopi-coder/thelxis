import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../desktop/desktop_integration.dart';
import '../l10n/strings.dart';
import '../session/session_manager.dart';
import '../session/session_base.dart';
import '../session/viewer_session.dart';
import '../core/settings.dart';
import '../net/connectivity/connectivity.dart';
import '../net/discovery.dart';
import 'devices/command_palette.dart';
import 'devices/devices_screen.dart';
import 'home/controlled_banner.dart';
import 'home/diagnostics_screen.dart';
import 'home/reachability.dart';
import 'home/home_screen.dart';
import 'session/session_view.dart';
import 'sessions_screen.dart';
import 'settings/settings_screen.dart';
import 'shell_controller.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/hover_tint.dart';
import 'widgets/surface.dart';
import 'widgets/thelxis_logo.dart';

/// Main window layout: navigation rail (wide) or bottom bar (narrow), page
/// stack, the "controlled by" banner, and session tabs on desktop.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'nav.home'),
    (Icons.devices_other_outlined, Icons.devices_other, 'nav.devices'),
    (Icons.cast_connected_outlined, Icons.cast_connected, 'nav.sessions'),
    (Icons.settings_outlined, Icons.settings, 'nav.settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final shell = context.watch<ShellController>();
    final manager = context.watch<SessionManager>();
    final desktop = context.read<DesktopIntegration>();
    final front = shell.front;
    final isDesktop = desktop.isDesktop;

    void go(int page) => context.read<ShellController>().goTo(page);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => showCommandPalette(context),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => showCommandPalette(context),
        // Ctrl/Cmd + 1..4 switch pages, Ctrl/Cmd + , opens Settings.
        for (final (i, key) in [
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit4,
        ].indexed) ...{
          SingleActivator(key, control: true): () => go(i),
          SingleActivator(key, meta: true): () => go(i),
        },
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () => go(ShellController.pageSettings),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () => go(ShellController.pageSettings),
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
    final s = context.s;
    final width = MediaQuery.sizeOf(context).width;
    final stack = _FadeIndexedStack(
      index: shell.page,
      children: [
        HomeScreen(active: shell.page == ShellController.pageHome),
        DevicesScreen(active: shell.page == ShellController.pageDevices),
        const SessionsScreen(),
        const SettingsScreen(),
      ],
    );
    if (width < kRailMinWidth) {
      return Column(
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  const _PhoneBar(),
                  Expanded(child: stack),
                ],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: context.c.border, width: hairlineOf(context))),
            ),
            child: NavigationBar(
              selectedIndex: shell.page,
              onDestinationSelected: shell.goTo,
              destinations: [
                for (final d in _destinations)
                  NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: s.t(d.$3)),
              ],
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        _Sidebar(
          extended: width >= kSidebarMinWidth,
          selected: shell.page,
          onSelected: shell.goTo,
        ),
        Expanded(child: stack),
      ],
    );
  }
}

/// Slim top bar of the phone layout: the logo and the app name.
class _PhoneBar extends StatelessWidget {
  const _PhoneBar();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border, width: hairlineOf(context))),
      ),
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const ThelxisLogo(size: 24),
              const SizedBox(width: 8),
              Text('Thelxis', style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// Left navigation: 220 px with labels on wide windows, a 68 px icon rail
/// (labels in tooltips) on medium ones. Flat sidebar tone, hairline on the
/// inner edge, selection = soft accent fill.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.extended, required this.selected, required this.onSelected});

  final bool extended;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    return SizedBox(
      key: const ValueKey('sidebar'),
      width: extended ? 220 : 68,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.sidebar,
          border: Border(right: BorderSide(color: c.border, width: hairlineOf(context))),
        ),
        child: SafeArea(
          right: false,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: extended ? 12 : 10, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(extended ? 8 : 0, 4, 0, 20),
                  child: extended
                      ? Row(
                          children: [
                            const ThelxisLogo(size: 32),
                            const SizedBox(width: 10),
                            Text('Thelxis', style: Theme.of(context).textTheme.titleMedium),
                          ],
                        )
                      : const Center(child: ThelxisLogo(size: 32)),
                ),
                for (final (i, d) in AppShell._destinations.indexed) ...[
                  _NavItem(
                    icon: selected == i ? d.$2 : d.$1,
                    label: s.t(d.$3),
                    selected: selected == i,
                    extended: extended,
                    onTap: () => onSelected(i),
                  ),
                  const SizedBox(height: 2),
                ],
                const Spacer(),
                _SidebarStatus(extended: extended),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.extended,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = Theme.of(context).textTheme;
    final item = HoverTint(
      onTap: onTap,
      selected: selected,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(Radii.control),
      child: SizedBox(
        height: 36,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: extended ? 10 : 0),
          child: Row(
            mainAxisAlignment: extended ? MainAxisAlignment.start : MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: selected ? c.accent : c.textSecondary),
              if (extended) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? c.accent : c.text,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return extended ? item : Tooltip(message: label, child: item);
  }
}

/// Reachability dot + a short word at the bottom of the sidebar.
class _SidebarStatus extends StatelessWidget {
  const _SidebarStatus({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final connectivity = context.read<Connectivity>();
    final gateway = context.watch<LanDiscovery>().gateways.firstOrNull?.name;
    final c = context.c;
    return ValueListenableBuilder<ReachabilityReport>(
      valueListenable: connectivity.report,
      builder: (context, report, _) {
        final summary = summarizeReachability(
          allowIncoming: settings.allowIncoming,
          report: report,
          upnpEnabled: settings.upnp,
          gatewayName: gateway,
          strings: context.s,
        );
        final dot = Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: toneDot(c, summary.tone), shape: BoxShape.circle),
        );
        void open() => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
            );
        final row = HoverTint(
          onTap: open,
          semanticLabel: summary.label,
          borderRadius: BorderRadius.circular(Radii.control),
          child: SizedBox(
            height: 36,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: extended ? 10 : 0),
              child: Row(
                mainAxisAlignment: extended ? MainAxisAlignment.start : MainAxisAlignment.center,
                children: [
                  extended ? Padding(padding: const EdgeInsets.only(left: 6, right: 2), child: dot) : dot,
                  if (extended) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        summary.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.textSecondary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
        return extended ? row : Tooltip(message: summary.label, child: row);
      },
    );
  }
}

/// IndexedStack (state of every page is kept) with a short fade when the
/// visible page changes.
class _FadeIndexedStack extends StatefulWidget {
  const _FadeIndexedStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<_FadeIndexedStack> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
    value: 1,
  );
  late final Animation<double> _opacity = CurvedAnimation(parent: _fade, curve: Curves.easeOut);

  @override
  void didUpdateWidget(_FadeIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _fade.forward(from: 0);
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: IndexedStack(index: widget.index, children: widget.children),
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
    final c = context.c;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.sidebar,
        border: Border(bottom: BorderSide(color: c.border, width: hairlineOf(context))),
      ),
      child: SizedBox(
        height: 42,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 5),
          children: [
            _Tab(
              selected: shell.front == null,
              onTap: shell.showPages,
              leading: const Icon(Icons.home_outlined, size: 18),
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
        final c = context.c;
        final dot = switch (session.phase) {
          SessionPhase.active => c.online,
          SessionPhase.ended => c.danger,
          SessionPhase.reconnecting => c.danger,
          _ => const Color(0xFFFF9F0A),
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
                  decoration: BoxDecoration(
                    color: dot,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.sidebar, width: 1.5),
                  ),
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
    final c = context.c;
    final fg = selected ? c.text : c.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? c.surface : null,
          borderRadius: BorderRadius.circular(Radii.control),
          border: selected ? Border.all(color: c.border, width: hairlineOf(context)) : null,
        ),
        child: HoverTint(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.control),
          child: Padding(
            padding: EdgeInsets.only(left: 10, right: onClose != null ? 2 : 10),
            child: IconTheme.merge(
              data: IconThemeData(color: fg),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  leading,
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: fg,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                          ),
                    ),
                  ),
                  if (onClose != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 15,
                      tooltip: context.s.t('common.close'),
                      icon: const Icon(Icons.close_rounded),
                      onPressed: onClose,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
