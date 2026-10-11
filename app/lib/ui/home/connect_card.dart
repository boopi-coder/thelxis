import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/address_book.dart';
import '../../net/connect_target.dart';
import '../connect_actions.dart';
import '../shell_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Connect field (invite link, `ID@host[:port]`, `host[:port]`) with recent
/// connections as chips.
class ConnectCard extends StatefulWidget {
  const ConnectCard({super.key});

  @override
  State<ConnectCard> createState() => _ConnectCardState();
}

class _ConnectCardState extends State<ConnectCard> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final pending = context.read<ShellController>().takePendingInvite();
    if (pending != null) _controller.text = pending;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() {
      _controller.text = text;
      _error = null;
    });
  }

  Future<void> _go({bool viewOnly = false, bool reverse = false}) async {
    final parsed = parseConnectInput(_controller.text);
    if (!parsed.isOk) {
      setState(() => _error = parsed.error);
      return;
    }
    await _run(parsed.target!, viewOnly: viewOnly, reverse: reverse);
  }

  Future<void> _run(ConnectTarget target, {bool viewOnly = false, bool reverse = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await runConnect(context, target, viewOnly: viewOnly, reverse: reverse);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final recents = context.watch<AddressBook>().recents();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connect to a device', style: t.textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(
              'Paste an invite link, or type ID@address or an address.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Gap.l),
            TextField(
              controller: _controller,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _go(),
              decoration: InputDecoration(
                hintText: 'K7M2-P9XQ-4TAB-8HDE@203.0.113.5',
                errorText: _error,
                errorMaxLines: 3,
                prefixIcon: const Icon(Icons.link_rounded),
                suffixIcon: IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: _busy ? null : _paste,
                ),
              ),
            ),
            const SizedBox(height: Gap.m),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _go,
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.arrow_forward_rounded),
                    label: Text(_busy ? 'Connecting…' : 'Connect'),
                  ),
                ),
                const SizedBox(width: Gap.s),
                PopupMenuButton<String>(
                  tooltip: 'More ways to connect',
                  enabled: !_busy,
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (v) => _go(viewOnly: v == 'view', reverse: v == 'reverse'),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'view', child: Text('Connect, view only')),
                    PopupMenuItem(value: 'reverse', child: Text('Let them control this device')),
                  ],
                ),
              ],
            ),
            if (recents.isNotEmpty) ...[
              const SizedBox(height: Gap.xl),
              Text('Recent', style: t.textTheme.labelLarge),
              const SizedBox(height: Gap.s),
              Wrap(
                spacing: Gap.s,
                runSpacing: Gap.s,
                children: [
                  for (final e in recents) _RecentChip(entry: e, enabled: !_busy, onTap: () => _run(_targetOf(e))),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  ConnectTarget _targetOf(AddressBookEntry e) => ConnectTarget(id: e.id, name: e.displayName);
}

class _RecentChip extends StatelessWidget {
  const _RecentChip({required this.entry, required this.onTap, required this.enabled});

  final AddressBookEntry entry;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(osIcon(entry.os), size: 18),
      label: Text(entry.displayName),
      onPressed: enabled ? onTap : null,
    );
  }
}
