import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../l10n/strings.dart';
import '../../platform/host_platform.dart';
import '../../platform/impl/android_host.dart';
import '../../update/ui/update_banner.dart';
import '../../update/update_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/surface.dart';
import 'accessibility_guide.dart';
import 'host_permissions.dart';

/// One compact "Setup needed" card above the devices grid: missing OS
/// permissions and a pending update, as small rows. Draws nothing when
/// nothing is needed.
///
/// The permission rows can be closed for good (a phone used only as a viewer
/// never needs Accessibility); Settings keeps the same help reachable. See
/// [AppSettings.dismissedSetupPermissions] for when they come back.
class SetupCard extends StatefulWidget {
  const SetupCard({super.key});

  @override
  State<SetupCard> createState() => _SetupCardState();
}

class _SetupCardState extends State<SetupCard> with WidgetsBindingObserver {
  Future<HostPermissionCheck>? _check;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check = _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have just granted a permission in system settings.
    if (state == AppLifecycleState.resumed) _reload();
  }

  // A block body: setState must not be handed the Future that `=>` would return.
  void _reload() {
    setState(() {
      _check = _load();
    });
  }

  Future<HostPermissionCheck> _load() => checkHostPermissions(context.read<HostPlatform>());

  void _dismiss(List<HostPermission> missing) {
    context.read<AppSettings>().dismissSetupPermissions(missing.map((p) => p.name));
    showMessage(context, context.s.t('setup.dismissed'));
  }

  @override
  Widget build(BuildContext context) {
    final updates = context.read<UpdateService>();
    final dismissed = context.watch<AppSettings>().dismissedSetupPermissions;
    return FutureBuilder<HostPermissionCheck>(
      future: _check,
      builder: (context, snap) {
        final check = snap.data ?? const HostPermissionCheck();
        final allMissing = check.missing;
        // Hidden while every missing permission was closed before; one that
        // was never closed brings back the whole list.
        final missing = allMissing.every((p) => dismissed.contains(p.name)) ? const <HostPermission>[] : allMissing;
        return ListenableBuilder(
          listenable: updates,
          builder: (context, _) {
            final hasUpdate = UpdateBanner.hasContent(updates);
            if (missing.isEmpty && !hasUpdate) return const SizedBox.shrink();
            final s = context.s;
            final c = context.c;
            final rows = <Widget>[
              for (final m in missing)
                _PermissionRow(
                  permission: m,
                  android: context.read<HostPlatform>() is AndroidHostPlatform,
                  guide: m == HostPermission.inputControl && check.restrictedLikely
                      ? AccessibilityGuide(
                          onOpenAccessibility: () => context.read<HostPlatform>().requestPermission(m),
                          onOpenAppInfo: () => (context.read<HostPlatform>() as AndroidHostPlatform).openAppDetails(),
                          onRecheck: _reload,
                        )
                      : null,
                  onGrant: () async {
                    await context.read<HostPlatform>().requestPermission(m);
                    if (mounted) _reload();
                  },
                ),
              if (hasUpdate)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
                  child: UpdateBanner(service: updates, embedded: true),
                ),
            ];
            return Padding(
              padding: const EdgeInsets.only(bottom: Gap.l),
              child: AppCard(
                key: const ValueKey('setup-card'),
                clip: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(Gap.l, Gap.m, missing.isEmpty ? Gap.l : Gap.s, Gap.xs),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(color: Color(0xFFFF9F0A), shape: BoxShape.circle),
                          ),
                          const SizedBox(width: Gap.s),
                          Expanded(
                            child: Text(
                              s.t('setup.title'),
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: c.text),
                            ),
                          ),
                          // Closes the permission rows only; a pending update
                          // has its own close button (it skips that version).
                          if (missing.isNotEmpty)
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: IconButton(
                                key: const ValueKey('setup-dismiss'),
                                padding: EdgeInsets.zero,
                                iconSize: 16,
                                tooltip: s.t('setup.dismiss'),
                                icon: Icon(
                                  Icons.close_rounded,
                                  color: c.textSecondary,
                                  semanticLabel: s.t('setup.dismiss.a11y'),
                                ),
                                onPressed: () => _dismiss(missing),
                              ),
                            ),
                        ],
                      ),
                    ),
                    for (final (i, row) in rows.indexed) ...[
                      if (i > 0) const Hairline(indent: Gap.l),
                      row,
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.permission, required this.onGrant, required this.android, this.guide});

  final HostPermission permission;
  final VoidCallback onGrant;
  final bool android;

  /// Replaces the Grant button and the one-line hint with a step-by-step guide.
  final Widget? guide;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final c = context.c;
    final screen = permission == HostPermission.screenCapture;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.s, Gap.s),
      child: Row(
        children: [
          Icon(
            screen ? Icons.screen_share_outlined : Icons.accessibility_new_outlined,
            size: 20,
            color: c.textSecondary,
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(screen ? s.t('perm.screen') : s.t('perm.input'), style: t.bodyMedium),
                if (!screen && android && guide == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      s.t('perm.android.restricted'),
                      style: t.bodySmall?.copyWith(color: c.textSecondary),
                    ),
                  ),
                if (guide != null)
                  Padding(padding: const EdgeInsets.only(top: Gap.s, right: Gap.m, bottom: Gap.xs), child: guide),
              ],
            ),
          ),
          if (guide == null) ...[
            const SizedBox(width: Gap.s),
            TextButton(onPressed: onGrant, child: Text(s.t('perm.grant'))),
          ],
        ],
      ),
    );
  }
}
