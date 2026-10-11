import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/identity.dart';
import '../../core/settings.dart';
import '../../core/thelxis_id.dart';
import '../../net/connect_target.dart';
import '../../net/connectivity/connectivity.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/qr_view.dart';
import '../../l10n/strings.dart';

Future<void> showShareAccessDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => MultiProvider(
      providers: [
        Provider<Identity>.value(value: context.read<Identity>()),
        Provider<Connectivity>.value(value: context.read<Connectivity>()),
        ChangeNotifierProvider<AppSettings>.value(value: context.read<AppSettings>()),
      ],
      child: const _ShareAccessDialog(),
    ),
  );
}

class _ShareAccessDialog extends StatelessWidget {
  const _ShareAccessDialog();

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context);
    final identity = context.read<Identity>();
    final connectivity = context.read<Connectivity>();
    final name = context.read<AppSettings>().deviceName;

    return ValueListenableBuilder<ReachabilityReport>(
      valueListenable: connectivity.report,
      builder: (context, _, _) {
        final addresses = connectivity.advertisedAddresses();
        final link = buildInviteLink(id: identity.id, name: name, addresses: addresses);
        final idAt = buildIdAtAddress(identity.id, addresses.isEmpty ? null : addresses.first);
        return AlertDialog(
          title: Text(s.t('share.title')),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.t('share.intro'),
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: Gap.l),
                  Center(child: QrView(data: link, size: 200)),
                  const SizedBox(height: Gap.l),
                  _CopyRow(label: s.t('share.link'), value: link, what: s.t('share.link')),
                  const SizedBox(height: Gap.s),
                  _CopyRow(label: s.t('share.idAt'), value: idAt, what: s.t('share.idAt')),
                  const SizedBox(height: Gap.l),
                  Text(s.t('share.reachableAt'), style: t.textTheme.labelLarge),
                  const SizedBox(height: Gap.xs),
                  if (addresses.isEmpty)
                    Text(
                      s.t('share.noAddress'),
                      style: t.textTheme.bodyMedium?.copyWith(color: context.status.warn),
                    )
                  else
                    for (final a in addresses)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: SelectableText(a, style: t.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace')),
                      ),
                  const SizedBox(height: Gap.l),
                  Text(
                    s.t('share.note', {'id': formatThelxisId(identity.id)}),
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.t('common.done'))),
          ],
        );
      },
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.label, required this.value, required this.what});

  final String label;
  final String value;
  final String what;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.xs, Gap.s),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: context.s.t('common.copy'),
            icon: const Icon(Icons.copy_rounded, size: 20),
            onPressed: () => copyToClipboard(context, value, what),
          ),
        ],
      ),
    );
  }
}
