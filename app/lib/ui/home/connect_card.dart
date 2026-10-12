import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/address_book.dart';
import '../../net/connect_code.dart';
import '../../net/connect_target.dart';
import '../../net/scan_payload.dart';
import 'connect_by_code_dialog.dart';
import '../connect_actions.dart';
import '../shell_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/qr_scanner_page.dart';
import '../widgets/surface.dart';
import '../../l10n/strings.dart';

/// Connect field (invite link, `ID@host[:port]`, `host[:port]`, connection
/// code) with the primary action and the secondary ways to connect.
class ConnectCard extends StatefulWidget {
  const ConnectCard({super.key, this.scanQr = openQrScanner});

  /// Opens the QR scanner (Android); replaced in tests.
  final QrScanLauncher scanQr;

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

  /// A scanned invite (or offer code) is handled exactly like a pasted one,
  /// then connected right away: scanning already was the deliberate step.
  Future<void> _scan() async {
    final text = await widget.scanQr(context, const {ScanKind.invite, ScanKind.offer});
    if (text == null || !mounted) return;
    setState(() {
      _controller.text = text;
      _error = null;
    });
    await _go();
  }

  Future<void> _go({bool viewOnly = false, bool reverse = false}) async {
    // A pasted connection code goes to its own flow.
    if (looksLikeConnectionCode(_controller.text)) {
      final code = _controller.text;
      _controller.clear();
      await showConnectByCodeDialog(context, initialCode: code, scanQr: widget.scanQr);
      return;
    }
    final parsed = parseConnectInput(_controller.text);
    if (!parsed.isOk) {
      setState(() => _error = parsed.error);
      return;
    }
    await _run(parsed.target!, viewOnly: viewOnly, reverse: reverse);
  }

  Future<void> _run(
    ConnectTarget target, {
    bool viewOnly = false,
    bool reverse = false,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await runConnect(
      context,
      target,
      viewOnly: viewOnly,
      reverse: reverse,
    );
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
    final c = context.c;
    final t = Theme.of(context).textTheme;
    final recents = context.watch<AddressBook>().recents(limit: 4);
    return AppCard(
      padding: EdgeInsets.all(
        MediaQuery.sizeOf(context).width < 420 ? Gap.l : 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.t('connect.title'), style: t.titleMedium),
          const SizedBox(height: 2),
          Text(
            s.t('connect.hint'),
            style: t.bodySmall?.copyWith(color: c.textSecondary),
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
              hintText: s.t('connect.field'),
              errorText: _error,
              errorMaxLines: 3,
              prefixIcon: const Icon(Icons.link_rounded, size: 18),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (qrScanSupported)
                    IconButton(
                      key: const ValueKey('connect-scan'),
                      tooltip: s.t('scan.button'),
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                      onPressed: _busy ? null : _scan,
                    ),
                  IconButton(
                    tooltip: s.t('connect.paste'),
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    onPressed: _busy ? null : _paste,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gap.m),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _go,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      Flexible(
                        child: Text(
                          _busy
                              ? s.t('connect.connecting')
                              : s.t('connect.button'),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: Gap.xs),
              PopupMenuButton<String>(
                tooltip: s.t('connect.more'),
                enabled: !_busy,
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (v) => _go(viewOnly: v == 'view'),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'view',
                    child: Text(s.t('connect.viewOnly')),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              TextButton.icon(
                key: const ValueKey('connect-by-code'),
                onPressed: _busy
                    ? null
                    : () => showConnectByCodeDialog(context, scanQr: widget.scanQr),
                icon: const Icon(Icons.vpn_key_outlined, size: 18),
                label: Text(s.t('code.title')),
              ),
              TextButton.icon(
                key: const ValueKey('connect-reverse'),
                onPressed: _busy ? null : () => _go(reverse: true),
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: Text(s.t('connect.reverseShort')),
              ),
            ],
          ),
          if (recents.isNotEmpty) ...[
            const SizedBox(height: Gap.l),
            Text(
              s.t('connect.recent'),
              style: t.labelMedium?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: Gap.s),
            Wrap(
              spacing: Gap.s,
              runSpacing: Gap.s,
              children: [
                for (final e in recents)
                  ActionChip(
                    avatar: Icon(osIcon(e.os), size: 16),
                    label: Text(e.displayName),
                    onPressed: _busy
                        ? null
                        : () => _run(
                            ConnectTarget(id: e.id, name: e.displayName),
                          ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
