import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/address_book.dart';
import '../../net/connect_target.dart';
import '../../net/discovery.dart';
import '../../net/net_address.dart';
import '../../l10n/strings.dart';
import '../connect_actions.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/rows.dart';
import 'command_palette.dart';
import 'device_dialogs.dart';
import 'device_tile.dart';

/// Address book plus devices discovered on the local network.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.active});

  /// True while the page is visible: LAN discovery only broadcasts then.
  final bool active;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final TextEditingController _search = TextEditingController();
  LanDiscovery? _lan;
  bool _browsing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lan ??= context.read<LanDiscovery>();
    _syncBrowsing();
  }

  @override
  void didUpdateWidget(DevicesScreen old) {
    super.didUpdateWidget(old);
    _syncBrowsing();
  }

  void _syncBrowsing() {
    final lan = _lan;
    if (lan == null) return;
    if (widget.active && !_browsing) {
      _browsing = true;
      lan.acquireBrowsing();
    } else if (!widget.active && _browsing) {
      _browsing = false;
      lan.releaseBrowsing();
    }
  }

  @override
  void dispose() {
    if (_browsing) _lan?.releaseBrowsing();
    _search.dispose();
    super.dispose();
  }

  bool _matches(AddressBookEntry e, String q) {
    if (q.isEmpty) return true;
    final hay = [
      e.displayName,
      e.name,
      e.id,
      e.formattedId,
      ...e.tags,
      e.notes,
      ...e.addresses,
    ].join(' ').toLowerCase();
    return hay.contains(q);
  }

  bool _matchesPeer(DiscoveredPeer p, String q) =>
      q.isEmpty || '${p.name} ${p.id} ${p.formattedId} ${p.address}'.toLowerCase().contains(q);

  void _entryAction(AddressBookEntry e, DeviceAction a) {
    final book = context.read<AddressBook>();
    final target = ConnectTarget(id: e.id, name: e.displayName);
    switch (a) {
      case DeviceAction.connect:
        runConnectWithFeedback(context, target);
      case DeviceAction.viewOnly:
        runConnectWithFeedback(context, target, viewOnly: true);
      case DeviceAction.reverse:
        runConnectWithFeedback(context, target, reverse: true);
      case DeviceAction.edit:
        showEditEntryDialog(context, book, e);
      case DeviceAction.favorite:
        book.update(e.id, favorite: !e.favorite);
      case DeviceAction.remove:
        book.remove(e.id);
      case DeviceAction.addToBook:
        break;
    }
  }

  Future<void> _peerAction(DiscoveredPeer p, DeviceAction a) async {
    final book = context.read<AddressBook>();
    final target = ConnectTarget(
      id: p.id,
      name: p.name,
      addresses: [NetAddress(p.host, p.port)],
    );
    switch (a) {
      case DeviceAction.connect:
        await runConnectWithFeedback(context, target);
      case DeviceAction.viewOnly:
        await runConnectWithFeedback(context, target, viewOnly: true);
      case DeviceAction.reverse:
        await runConnectWithFeedback(context, target, reverse: true);
      case DeviceAction.addToBook:
        await book.addManual(id: p.id, name: p.name, addresses: [p.address]);
        if (mounted) showMessage(context, context.s.t('devices.added', {'name': p.name}));
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final book = context.watch<AddressBook>();
    final lan = context.watch<LanDiscovery>();
    final q = _search.text.trim().toLowerCase();
    final entries = book.entries.where((e) => _matches(e, q)).toList();
    final peers = lan.peers.where((p) => _matchesPeer(p, q)).toList();
    final onNetwork = {for (final p in lan.peers) p.id};

    return PageScroll(
      maxWidth: 960,
      children: [
        PageTitle(s.t('devices.title'), subtitle: s.t('devices.subtitle')),
        const SizedBox(height: Gap.s),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: s.t('devices.search'),
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  suffixIcon: IconButton(
                    tooltip: s.t('devices.palette'),
                    icon: const Icon(Icons.keyboard_command_key_rounded, size: 18),
                    onPressed: () => showCommandPalette(context),
                  ),
                ),
              ),
            ),
            const SizedBox(width: Gap.s),
            PopupMenuButton<String>(
              tooltip: s.t('devices.bookMenu'),
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) {
                switch (v) {
                  case 'add':
                    showAddDeviceDialog(context, book);
                  case 'import':
                    showImportDialog(context, book);
                  case 'export':
                    showExportDialog(context, book);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'add', child: Text(s.t('devices.add'))),
                PopupMenuItem(value: 'import', child: Text(s.t('devices.import'))),
                PopupMenuItem(value: 'export', child: Text(s.t('devices.export'))),
              ],
            ),
          ],
        ),
        const SizedBox(height: Gap.xl),
        SettingsGroup(
          title: s.t('devices.lan'),
          trailing: _scanButton(lan, s),
          children: [
            if (peers.isEmpty)
              EmptyState(
                compact: true,
                icon: Icons.wifi_find_rounded,
                title: s.t('devices.lan.empty'),
                message: s.t('devices.lan.empty.hint'),
              )
            else
              for (final p in peers) DeviceTile.lan(peer: p, onAction: (a) => _peerAction(p, a)),
          ],
        ),
        const SizedBox(height: Gap.xl),
        SettingsGroup(
          title: s.t('devices.book'),
          children: [
            if (entries.isEmpty)
              EmptyState(
                compact: true,
                logo: q.isEmpty,
                icon: Icons.contacts_outlined,
                title: q.isEmpty ? s.t('devices.book.empty') : s.t('devices.noMatches'),
                message: q.isEmpty ? s.t('devices.book.empty.hint') : null,
                action: q.isEmpty
                    ? FilledButton.icon(
                        style: context.secondaryButton,
                        onPressed: () => showAddDeviceDialog(context, book),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(s.t('devices.add')),
                      )
                    : null,
              )
            else
              for (final e in entries)
                DeviceTile.entry(
                  entry: e,
                  online: onNetwork.contains(e.id),
                  onAction: (a) => _entryAction(e, a),
                ),
          ],
        ),
      ],
    );
  }

  Widget _scanButton(LanDiscovery lan, S s) => TextButton.icon(
        onPressed: lan.scanNow,
        icon: const Icon(Icons.refresh_rounded, size: 16),
        label: Text(s.t('devices.scan')),
      );
}
