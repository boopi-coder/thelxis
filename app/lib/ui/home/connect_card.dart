import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/address_book.dart';
import '../../net/connect_target.dart';
import '../connect_actions.dart';
import '../shell_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../../l10n/strings.dart';

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
    final s = context.s;
    final t = Theme.of(context);
    final recents = context.watch<AddressBook>().recents();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: t.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.cast_connected_rounded, color: t.colorScheme.onPrimaryContainer),
                ),
                const SizedBox(width: Gap.m),
                Expanded(child: Text(s.t('connect.title'), style: t.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: Gap.s),
            Text(
              s.t('connect.hint'),
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
                  tooltip: s.t('connect.paste'),
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
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _busy
                          ? const SizedBox(
                              key: ValueKey('busy'),
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_forward_rounded, key: ValueKey('go')),
                    ),
                    label: Text(_busy ? s.t('connect.connecting') : s.t('connect.button')),
                  ),
                ),
                const SizedBox(width: Gap.s),
                PopupMenuButton<String>(
                  tooltip: s.t('connect.more'),
                  enabled: !_busy,
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (v) => _go(viewOnly: v == 'view', reverse: v == 'reverse'),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'view', child: Text(s.t('connect.viewOnly'))),
                    PopupMenuItem(value: 'reverse', child: Text(s.t('connect.reverse'))),
                  ],
                ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: recents.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: Gap.xl),
                        Text(s.t('connect.recent'), style: t.textTheme.labelLarge),
                        const SizedBox(height: Gap.s),
                        Wrap(
                          spacing: Gap.s,
                          runSpacing: Gap.s,
                          children: [
                            for (final e in recents)
                              ActionChip(
                                avatar: Icon(osIcon(e.os), size: 18),
                                label: Text(e.displayName),
                                onPressed: _busy
                                    ? null
                                    : () => _run(ConnectTarget(id: e.id, name: e.displayName)),
                              ),
                          ],
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
