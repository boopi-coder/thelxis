import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../platform/host_platform.dart';
import '../../platform/impl/android_host.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'accessibility_guide.dart';
import 'host_permissions.dart';

/// The "Setup needed" permission help, reachable at any time from Settings
/// (the home card can be closed for good on a viewer-only device).
Future<void> showHostPermissionsDialog(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const _HostPermissionsDialog());
}

/// Short status label of [p], also used by the Settings row subtitle.
String hostPermissionStatusLabel(S s, HostPlatform platform, HostPermission p, PermissionStatus? status) {
  if (p == HostPermission.inputControl && !platform.inputSupported) return s.t('settings.hostPerms.unsupported');
  return switch (status) {
    PermissionStatus.granted => s.t('settings.hostPerms.granted'),
    PermissionStatus.denied => s.t('settings.hostPerms.denied'),
    // Android asks for screen capture at every connection instead of once.
    PermissionStatus.notRequired when platform is AndroidHostPlatform && p == HostPermission.screenCapture =>
      s.t('settings.hostPerms.perSession'),
    PermissionStatus.notRequired => s.t('settings.hostPerms.notRequired'),
    null => s.t('common.unknown'),
  };
}

String hostPermissionName(S s, HostPermission p) =>
    p == HostPermission.screenCapture ? s.t('settings.hostPerms.screen') : s.t('settings.hostPerms.input');

class _HostPermissionsDialog extends StatefulWidget {
  const _HostPermissionsDialog();

  @override
  State<_HostPermissionsDialog> createState() => _HostPermissionsDialogState();
}

class _HostPermissionsDialogState extends State<_HostPermissionsDialog> with WidgetsBindingObserver {
  late Future<HostPermissionCheck> _check = checkHostPermissions(context.read<HostPlatform>());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    if (!mounted) return;
    setState(() {
      _check = checkHostPermissions(context.read<HostPlatform>());
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final platform = context.read<HostPlatform>();
    return AlertDialog(
      key: const ValueKey('host-perms-dialog'),
      title: Text(s.t('settings.hostPerms')),
      content: SizedBox(
        width: 460,
        child: FutureBuilder<HostPermissionCheck>(
          future: _check,
          builder: (context, snap) {
            final check = snap.data;
            if (check == null) {
              return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in kHostPermissions)
                    _PermissionBlock(
                      permission: p,
                      status: check.status[p],
                      platform: platform,
                      onChanged: _reload,
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.t('common.done'))),
      ],
    );
  }
}

class _PermissionBlock extends StatelessWidget {
  const _PermissionBlock({
    required this.permission,
    required this.status,
    required this.platform,
    required this.onChanged,
  });

  final HostPermission permission;
  final PermissionStatus? status;
  final HostPlatform platform;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final c = context.c;
    final screen = permission == HostPermission.screenCapture;
    final denied = status == PermissionStatus.denied;
    final android = platform is AndroidHostPlatform ? platform as AndroidHostPlatform : null;
    final tone = switch (status) {
      PermissionStatus.granted => PillTone.good,
      PermissionStatus.denied => PillTone.bad,
      _ => PillTone.neutral,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                screen ? Icons.screen_share_outlined : Icons.accessibility_new_outlined,
                size: 20,
                color: c.textSecondary,
              ),
              const SizedBox(width: Gap.m),
              // A Wrap: on a phone the status moves under the name instead of
              // overflowing the dialog.
              Expanded(
                child: Wrap(
                  spacing: Gap.s,
                  runSpacing: Gap.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(hostPermissionName(s, permission), style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                    StatusPill(label: hostPermissionStatusLabel(s, platform, permission, status), tone: tone),
                  ],
                ),
              ),
            ],
          ),
          if (denied)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: Gap.s),
              child: !screen && android != null
                  // The restricted-settings walk-through: here the user came on
                  // purpose, so it is shown even when the block is not detected.
                  ? AccessibilityGuide(
                      onOpenAccessibility: () => android.requestPermission(permission),
                      onOpenAppInfo: android.openAppDetails,
                      onRecheck: onChanged,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          screen ? s.t('perm.screen') : s.t('perm.input'),
                          style: t.bodySmall?.copyWith(color: c.textSecondary),
                        ),
                        const SizedBox(height: Gap.xs),
                        TextButton(
                          key: ValueKey('host-perms-grant-${permission.name}'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () async {
                            await platform.requestPermission(permission);
                            onChanged();
                          },
                          child: Text(s.t('perm.grant')),
                        ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}
