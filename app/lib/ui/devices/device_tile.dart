import 'package:flutter/material.dart';

import '../../core/address_book.dart';
import '../../core/format.dart';
import '../../net/discovery.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/hover_tint.dart';
import '../../l10n/strings.dart';

enum DeviceAction { connect, viewOnly, reverse, edit, favorite, remove, addToBook }

/// One row of the address book or the LAN list: OS icon with an online dot,
/// name, ID and status, and the actions at the right. A tap connects.
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
    final t = Theme.of(context).textTheme;
    final c = context.c;
    final e = entry;
    final p = peer;
    final os = e?.os ?? p!.os;
    final title = e?.displayName ?? p!.name;
    final idText = e?.formattedId ?? p!.formattedId;
    final status = e != null
        ? (online ? s.t('devices.onNetwork') : formatLastSeen(e.lastConnected ?? e.lastSeen, strings: s))
        : p!.address;
    return HoverTint(
      onTap: () => onAction(DeviceAction.connect),
      semanticLabel: title,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 10),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(color: c.inset, borderRadius: BorderRadius.circular(Radii.control)),
                  child: SizedBox(width: 36, height: 36, child: Icon(osIcon(os), size: 20, color: c.textSecondary)),
                ),
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: online ? c.online : c.borderStrong,
                      shape: BoxShape.circle,
                      border: Border.all(color: c.surface, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Tooltip(
                          message: title,
                          child: Text(title, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      if (e?.favorite ?? false)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.star_rounded, size: 14, color: Color(0xFFFF9F0A)),
                        ),
                    ],
                  ),
                  Text(
                    '$idText  ·  $status',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: c.textSecondary, fontFeatures: kTabularFigures),
                  ),
                  if (e != null && e.tags.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final tag in e.tags)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: c.inset,
                              borderRadius: BorderRadius.circular(Radii.pill),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                              child: Text(tag, style: t.labelSmall?.copyWith(color: c.textSecondary)),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: s.t('devices.connect'),
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: () => onAction(DeviceAction.connect),
            ),
            PopupMenuButton<DeviceAction>(
              tooltip: s.t('common.more'),
              icon: const Icon(Icons.more_horiz_rounded),
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
    );
  }
}
