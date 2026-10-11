import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/trusted_devices.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Trusted Devices list: who may connect without a password or prompt, with
/// per-device permissions and revoke.
class TrustedDevicesSection extends StatelessWidget {
  const TrustedDevicesSection({super.key});

  @override
  Widget build(BuildContext context) {
    final trusted = context.watch<TrustedDevices>();
    final devices = trusted.devices;
    final t = Theme.of(context);
    if (devices.isEmpty) {
      return const EmptyState(
        icon: Icons.verified_user_outlined,
        title: 'No trusted devices',
        message: 'Tick "Always allow this device" when accepting a request to add one.',
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
                SwitchListTile.adaptive(
                  title: const Text('May control'),
                  value: d.permissions.control,
                  onChanged: (v) => trusted.updatePermissions(d.key, d.permissions.copyWith(control: v)),
                ),
                SwitchListTile.adaptive(
                  title: const Text('May use the clipboard'),
                  value: d.permissions.clipboard,
                  onChanged: (v) => trusted.updatePermissions(d.key, d.permissions.copyWith(clipboard: v)),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: Gap.m, bottom: Gap.s),
                    child: TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
                      onPressed: () async {
                        await trusted.revoke(d.key);
                        if (context.mounted) showMessage(context, '${d.name} is no longer trusted');
                      },
                      icon: const Icon(Icons.block_rounded),
                      label: const Text('Revoke'),
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
