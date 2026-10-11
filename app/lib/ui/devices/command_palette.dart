import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/address_book.dart';
import '../../core/thelxis_id.dart';
import '../../l10n/strings.dart';
import '../../net/connect_target.dart';
import '../../net/discovery.dart';
import '../../net/net_address.dart';
import '../connect_actions.dart';
import '../widgets/common.dart';

/// One selectable row in the palette.
class PaletteItem {
  const PaletteItem({required this.title, required this.subtitle, required this.icon, required this.target});

  final String title;
  final String subtitle;
  final IconData icon;
  final ConnectTarget target;
}

/// Builds the palette results for [query]: matching address-book entries and
/// LAN devices, plus a direct "Connect to …" entry when the text parses as a
/// target. Pure so it can be unit tested.
List<PaletteItem> paletteItems({
  required String query,
  required List<AddressBookEntry> entries,
  required List<DiscoveredPeer> peers,
  S? strings,
}) {
  final s = strings ?? S.current;
  final q = query.trim().toLowerCase();
  final items = <PaletteItem>[];
  final parsed = q.isEmpty || !_looksLikeTarget(query) ? null : parseConnectInput(query);
  if (parsed != null && parsed.isOk) {
    final t = parsed.target!;
    items.add(PaletteItem(
      title: s.t('palette.connectTo', {'target': query.trim()}),
      subtitle: t.hasId ? s.t('palette.verified') : s.t('palette.newDevice'),
      icon: Icons.bolt_rounded,
      target: t,
    ));
  }
  for (final e in entries) {
    final hay = '${e.displayName} ${e.name} ${e.id} ${e.formattedId} ${e.tags.join(' ')}'.toLowerCase();
    if (q.isEmpty || hay.contains(q)) {
      items.add(PaletteItem(
        title: e.displayName,
        subtitle: e.formattedId,
        icon: osIcon(e.os),
        target: ConnectTarget(id: e.id, name: e.displayName),
      ));
    }
  }
  for (final p in peers) {
    if (entries.any((e) => e.id == p.id)) continue;
    final hay = '${p.name} ${p.id} ${p.formattedId}'.toLowerCase();
    if (q.isEmpty || hay.contains(q)) {
      items.add(PaletteItem(
        title: p.name,
        subtitle: '${p.formattedId} · ${p.address} · ${s.t('devices.onNetwork')}',
        icon: osIcon(p.os),
        target: ConnectTarget(id: p.id, name: p.name, addresses: [NetAddress(p.host, p.port)]),
      ));
    }
  }
  return items;
}

/// Plain words are searches, not hosts: only address-like text (dots, colons,
/// `ID@…`, invite links) or a full Thelxis ID offers a direct connect.
bool _looksLikeTarget(String text) {
  final t = text.trim();
  return t.contains('.') || t.contains(':') || t.contains('@') || parseThelxisId(t) != null;
}

Future<void> showCommandPalette(BuildContext context) {
  final book = context.read<AddressBook>();
  final lan = context.read<LanDiscovery>();
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _CommandPalette(
      book: book,
      lan: lan,
      parentContext: context,
    ),
  );
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({required this.book, required this.lan, required this.parentContext});

  final AddressBook book;
  final LanDiscovery lan;
  final BuildContext parentContext;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final TextEditingController _controller = TextEditingController();
  int _selected = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<PaletteItem> get _items => paletteItems(
        query: _controller.text,
        entries: widget.book.entries,
        peers: widget.lan.peers,
        strings: context.s,
      );

  void _pick(PaletteItem item) {
    Navigator.of(context).pop();
    if (widget.parentContext.mounted) {
      runConnectWithFeedback(widget.parentContext, item.target);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final items = _items;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && items.isNotEmpty) {
      setState(() => _selected = (_selected + 1) % items.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && items.isNotEmpty) {
      setState(() => _selected = (_selected - 1 + items.length) % items.length);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final selected = items.isEmpty ? 0 : _selected.clamp(0, items.length - 1);
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(16, 80, 16, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Focus(
              onKeyEvent: _onKey,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  onChanged: (_) => setState(() => _selected = 0),
                  onSubmitted: (_) {
                    if (items.isNotEmpty) _pick(items[selected]);
                  },
                  decoration: InputDecoration(
                    hintText: context.s.t('palette.hint'),
                    prefixIcon: const Icon(Icons.search_rounded),
                  ),
                ),
              ),
            ),
            Flexible(
              child: items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(context.s.t('devices.noMatches')),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final it = items[i];
                        return ListTile(
                          selected: i == selected,
                          selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                          leading: Icon(it.icon),
                          title: Text(it.title, overflow: TextOverflow.ellipsis),
                          subtitle: Text(it.subtitle, overflow: TextOverflow.ellipsis),
                          onTap: () => _pick(it),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
