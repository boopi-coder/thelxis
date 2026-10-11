import 'package:flutter/material.dart';

import '../../core/address_book.dart';
import '../../core/format.dart';
import '../../l10n/strings.dart';
import '../../net/connect_target.dart';
import '../../net/discovery.dart';
import '../../net/net_address.dart';
import '../connect_actions.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/hover_tint.dart';
import '../widgets/surface.dart';

/// One device shown on Home: a saved one, a recent one or one that answered
/// on the local network.
class HomeDevice {
  const HomeDevice({
    required this.id,
    required this.formattedId,
    required this.name,
    required this.os,
    required this.online,
    required this.favorite,
    required this.lastSeen,
    required this.target,
  });

  final String id;
  final String formattedId;
  final String name;
  final String os;
  final bool online;
  final bool favorite;
  final DateTime? lastSeen;
  final ConnectTarget target;
}

/// Favorites first, then devices that are online now, then the most recently
/// used. Network devices that are not saved yet are included.
List<HomeDevice> homeDevices(AddressBook book, LanDiscovery lan) {
  final peers = {for (final p in lan.peers) p.id: p};
  final out = <HomeDevice>[
    for (final e in book.entries)
      HomeDevice(
        id: e.id,
        formattedId: e.formattedId,
        name: e.displayName,
        os: e.os,
        online: peers.containsKey(e.id),
        favorite: e.favorite,
        lastSeen: e.lastConnected ?? e.lastSeen,
        target: ConnectTarget(id: e.id, name: e.displayName),
      ),
  ];
  final saved = {for (final d in out) d.id};
  for (final p in peers.values) {
    if (saved.contains(p.id)) continue;
    out.add(
      HomeDevice(
        id: p.id,
        formattedId: p.formattedId,
        name: p.name,
        os: p.os,
        online: true,
        favorite: false,
        lastSeen: p.lastSeen,
        target: ConnectTarget(id: p.id, name: p.name, addresses: [NetAddress(p.host, p.port)]),
      ),
    );
  }
  int rank(HomeDevice d) => (d.favorite ? 0 : 2) + (d.online ? 0 : 1);
  out.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    final ta = a.lastSeen, tb = b.lastSeen;
    if (ta != null && tb != null) return tb.compareTo(ta);
    if (ta != null) return -1;
    if (tb != null) return 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

/// The "Devices" grid of Home: compact tiles that fill the width.
class DevicesGridSliver extends StatelessWidget {
  const DevicesGridSliver({super.key, required this.devices, required this.maxTileWidth});

  final List<HomeDevice> devices;
  final double maxTileWidth;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxTileWidth,
        mainAxisExtent: 84,
        crossAxisSpacing: Gap.m,
        mainAxisSpacing: Gap.m,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) => DeviceGridTile(device: devices[i]),
        childCount: devices.length,
      ),
    );
  }
}

/// A device tile: OS icon, name, short ID, online dot and last seen. Hovering
/// reveals a "Connect" button (placed over the tile, so nothing moves).
class DeviceGridTile extends StatelessWidget {
  const DeviceGridTile({super.key, required this.device});

  final HomeDevice device;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final c = context.c;
    final t = Theme.of(context).textTheme;
    final d = device;
    final status = d.online ? s.t('home.devices.online') : formatLastSeen(d.lastSeen, strings: s);
    return AppCard(
      clip: true,
      child: HoverTint(
        onTap: () => runConnectWithFeedback(context, d.target),
        semanticLabel: '${s.t('devices.connect')}: ${d.name}',
        hoverBuilder: (context) => Positioned(
          right: 10,
          bottom: 10,
          child: SizedBox(
            height: 28,
            child: FilledButton(
              style: context.secondaryButton.copyWith(
                minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
                padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
                backgroundColor: WidgetStatePropertyAll(c.accent),
                foregroundColor: const WidgetStatePropertyAll(Colors.white),
              ),
              onPressed: () => runConnectWithFeedback(context, d.target),
              child: Text(s.t('devices.connect')),
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(color: c.inset, borderRadius: BorderRadius.circular(Radii.control)),
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: Icon(osIcon(d.os), size: 20, color: c.textSecondary),
                ),
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Tooltip(
                            message: d.name,
                            child: Text(
                              d.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.titleSmall,
                            ),
                          ),
                        ),
                        if (d.favorite)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.star_rounded, size: 14, color: Color(0xFFFF9F0A)),
                          ),
                      ],
                    ),
                    Text(
                      d.formattedId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: c.textSecondary, fontFeatures: kTabularFigures),
                    ),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: d.online ? c.online : c.borderStrong,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodySmall?.copyWith(color: d.online ? c.success : c.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
