import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/trusted_devices.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/rows.dart';
import '../widgets/surface.dart';
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
    final c = context.c;
    if (devices.isEmpty) {
      return EmptyState(
        compact: true,
        icon: Icons.verified_user_outlined,
        title: s.t('trusted.empty'),
        message: s.t('trusted.empty.hint'),
      );
    }
    return Column(
      children: [
        for (final d in devices)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              shape: const Border(),
              collapsedShape: const Border(),
              leading: Icon(Icons.verified_user_outlined, size: 18, color: c.textSecondary),
              title: Text(d.name, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              subtitle: Text(
                d.formattedId,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.textSecondary),
              ),
              children: [
                const Hairline(indent: 16),
                SwitchRow(
                  title: s.t('trusted.control'),
                  value: d.permissions.control,
                  onChanged: (v) => trusted.updatePermissions(d.key, d.permissions.copyWith(control: v)),
                ),
                SwitchRow(
                  title: s.t('trusted.clipboard'),
                  value: d.permissions.clipboard,
                  onChanged: (v) => trusted.updatePermissions(d.key, d.permissions.copyWith(clipboard: v)),
                ),
                SwitchRow(
                  title: s.t('trusted.files'),
                  value: d.permissions.files,
                  onChanged: (v) => trusted.updatePermissions(d.key, d.permissions.copyWith(files: v)),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: Gap.m, bottom: Gap.s),
                    child: TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: c.danger),
                      onPressed: () async {
                        await trusted.revoke(d.key);
                        if (context.mounted) showMessage(context, s.t('trusted.revoked', {'name': d.name}));
                      },
                      icon: const Icon(Icons.block_rounded, size: 18),
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
