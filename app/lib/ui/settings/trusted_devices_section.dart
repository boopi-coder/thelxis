import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/trusted_devices.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../../l10n/strings.dart';

/// Trusted Devices list: who may connect without a password or prompt, with
/// per-device permissions and revoke.
class TrustedDevicesSection extends StatelessWidget {
  const TrustedDevicesSection({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final trusted = context.watch<TrustedDevices>();
    final devices = trusted.devices;
    final t = Theme.of(context);
    if (devices.isEmpty) {
      return EmptyState(
        icon: Icons.verified_user_outlined,
        title: s.t('trusted.empty'),
        message: s.t('trusted.empty.hint'),
      );
    }
    return Column(
      children: [
        for (final d in devices)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.s),
            child: ExpansionTile(
              shape: const Border(),
              collapsedShape: const Border(),
              leading: const Icon(Icons.verified_user_rounded),
              title: Text(d.name),
              subtitle: Text(d.formattedId),
              children: [
                SwitchListTile(
                  title: Text(s.t('trusted.control')),
                  value: d.permissions.control,
                  onChanged: (v) => trusted.updatePermissions(d.key, d.permissions.copyWith(control: v)),
                ),
                SwitchListTile(
                  title: Text(s.t('trusted.clipboard')),
                  value: d.permissions.clipboard,
                  onChanged: (v) => trusted.updatePermissions(d.key, d.permissions.copyWith(clipboard: v)),
                ),
                SwitchListTile(
                  title: Text(s.t('trusted.files')),
                  value: d.permissions.files,
                  onChanged: (v) => trusted.updatePermissions(d.key, d.permissions.copyWith(files: v)),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: Gap.m, bottom: Gap.s),
                    child: TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
                      onPressed: () async {
                        await trusted.revoke(d.key);
                        if (context.mounted) showMessage(context, s.t('trusted.revoked', {'name': d.name}));
                      },
                      icon: const Icon(Icons.block_rounded),
                      label: Text(s.t('trusted.revoke')),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
