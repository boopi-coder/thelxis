import 'package:flutter/material.dart';

import '../../core/address_book.dart';
import '../../core/format.dart';
import '../../net/discovery.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../../l10n/strings.dart';

enum DeviceAction { connect, viewOnly, reverse, edit, favorite, remove, addToBook }

/// One row of the address book or the LAN list.
class DeviceTile extends StatelessWidget {
  const DeviceTile.entry({
    super.key,
    required AddressBookEntry this.entry,
    required this.online,
    required this.onAction,
  }) : peer = null;

  const DeviceTile.lan({
    super.key,
    required DiscoveredPeer this.peer,
    required this.onAction,
  })  : entry = null,
        online = true;

  final AddressBookEntry? entry;
  final DiscoveredPeer? peer;
  final bool online;
  final void Function(DeviceAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context);
    final e = entry;
    final p = peer;
    final os = e?.os ?? p!.os;
    final title = e?.displayName ?? p!.name;
    final idText = e?.formattedId ?? p!.formattedId;
    final status = e != null
        ? (online ? s.t('devices.onNetwork') : formatLastSeen(e.lastConnected ?? e.lastSeen, strings: s))
        : p!.address;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onAction(DeviceAction.connect),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: t.colorScheme.primaryContainer,
                    foregroundColor: t.colorScheme.onPrimaryContainer,
                    child: Icon(osIcon(os)),
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        color: online ? context.status.good : t.colorScheme.outline,
                        shape: BoxShape.circle,
                        border: Border.all(color: t.colorScheme.surfaceContainerLow, width: 2.5),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: Gap.l),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(title, style: t.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                        ),
                        if (e?.favorite ?? false)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFC857)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      idText,
                      style: t.textTheme.bodySmall?.copyWith(
                        color: t.colorScheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      status,
                      style: t.textTheme.bodySmall?.copyWith(
                        color: online ? context.status.good : t.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (e != null && e.tags.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final tag in e.tags)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: t.colorScheme.secondaryContainer.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(tag, style: t.textTheme.labelSmall),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: s.t('devices.connect'),
                icon: const Icon(Icons.play_arrow_rounded),
                onPressed: () => onAction(DeviceAction.connect),
              ),
              PopupMenuButton<DeviceAction>(
                tooltip: s.t('common.more'),
                onSelected: onAction,
                itemBuilder: (_) => [
                  PopupMenuItem(value: DeviceAction.viewOnly, child: Text(s.t('devices.connectViewOnly'))),
                  PopupMenuItem(value: DeviceAction.reverse, child: Text(s.t('devices.reverse'))),
                  const PopupMenuDivider(),
                  if (e != null) ...[
                    PopupMenuItem(
                      value: DeviceAction.favorite,
                      child: Text(e.favorite ? s.t('devices.unfavorite') : s.t('devices.favorite')),
                    ),
                    PopupMenuItem(value: DeviceAction.edit, child: Text(s.t('devices.edit'))),
                    PopupMenuItem(value: DeviceAction.remove, child: Text(s.t('devices.remove'))),
                  ] else
                    PopupMenuItem(value: DeviceAction.addToBook, child: Text(s.t('devices.addToBook'))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
