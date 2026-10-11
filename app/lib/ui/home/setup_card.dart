import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../platform/host_platform.dart';
import '../../update/ui/update_banner.dart';
import '../../update/update_service.dart';
import '../theme.dart';
import '../widgets/surface.dart';

/// One compact "Setup needed" card above the devices grid: missing OS
/// permissions and a pending update, as small rows. Draws nothing when
/// nothing is needed.
class SetupCard extends StatefulWidget {
  const SetupCard({super.key});

  @override
  State<SetupCard> createState() => _SetupCardState();
}

class _SetupCardState extends State<SetupCard> with WidgetsBindingObserver {
  Future<List<HostPermission>>? _missing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _missing = _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have just granted a permission in system settings.
    if (state == AppLifecycleState.resumed) setState(() => _missing = _load());
  }

  Future<List<HostPermission>> _load() async {
    final platform = context.read<HostPlatform>();
    if (!platform.hostSupported) return const [];
    final out = <HostPermission>[];
    for (final p in [HostPermission.screenCapture, HostPermission.inputControl]) {
      try {
        if (await platform.permissionStatus(p) == PermissionStatus.denied) out.add(p);
      } on Object {
        // An unavailable status check is not worth bothering the user about.
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final updates = context.read<UpdateService>();
    return FutureBuilder<List<HostPermission>>(
      future: _missing,
      builder: (context, snap) {
        final missing = snap.data ?? const <HostPermission>[];
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
                  onGrant: () async {
                    await context.read<HostPlatform>().requestPermission(m);
                    if (mounted) setState(() => _missing = _load());
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
                      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.xs),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(color: Color(0xFFFF9F0A), shape: BoxShape.circle),
                          ),
                          const SizedBox(width: Gap.s),
                          Text(
                            s.t('setup.title'),
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: c.text),
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
  const _PermissionRow({required this.permission, required this.onGrant});

  final HostPermission permission;
  final VoidCallback onGrant;

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
                if (!screen && Platform.isAndroid)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      s.t('perm.android.restricted'),
                      style: t.bodySmall?.copyWith(color: c.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Gap.s),
          TextButton(onPressed: onGrant, child: Text(s.t('perm.grant'))),
        ],
      ),
    );
  }
}
