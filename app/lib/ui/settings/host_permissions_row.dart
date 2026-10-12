import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../platform/host_platform.dart';
import '../home/host_permissions.dart';
import '../home/host_permissions_dialog.dart';
import '../theme.dart';
import '../widgets/rows.dart';

/// Settings row with the current screen-capture and input-control status;
/// opens the same help as the home "Setup needed" card, which the user may
/// have closed for good.
class HostPermissionsRow extends StatefulWidget {
  const HostPermissionsRow({super.key});

  @override
  State<HostPermissionsRow> createState() => _HostPermissionsRowState();
}

class _HostPermissionsRowState extends State<HostPermissionsRow> with WidgetsBindingObserver {
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
    if (state == AppLifecycleState.resumed) _reload();
  }

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
    return FutureBuilder<HostPermissionCheck>(
      future: _check,
      builder: (context, snap) {
        final check = snap.data;
        return SettingsRow(
          key: const ValueKey('host-perms-row'),
          icon: Icons.admin_panel_settings_outlined,
          title: s.t('settings.hostPerms'),
          subtitle: check == null
              ? null
              : [
                  for (final p in kHostPermissions)
                    '${hostPermissionName(s, p)}: ${hostPermissionStatusLabel(s, platform, p, check.status[p])}',
                ].join(' · '),
          trailing: Icon(Icons.chevron_right_rounded, color: context.c.textMuted),
          onTap: () async {
            await showHostPermissionsDialog(context);
            _reload();
          },
        );
      },
    );
  }
}
