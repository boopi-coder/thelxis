import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/address_book.dart';
import '../../l10n/strings.dart';
import '../../net/connect_code.dart';
import '../../session/session_manager.dart';
import '../../session/viewer_session.dart';
import '../dialogs/prompt_dialogs.dart' show PeerCard;
import '../shell_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/qr_view.dart';

/// Codes up to this many characters are also shown as a QR code; longer ones
/// would be too dense to scan from a screen.
const int kMaxQrCodeChars = 2000;

/// The user-facing text for a [CodeException].
String codeErrorMessage(S s, CodeException e) => switch (e.error) {
      CodeError.malformed => s.t('code.error.malformed'),
      CodeError.tooLarge => s.t('code.error.tooLarge'),
      CodeError.unsupported => s.t('code.error.unsupported'),
      CodeError.expired => s.t('code.error.expired'),
      CodeError.badSignature => s.t('code.error.badSignature'),
      CodeError.mismatch => s.t('code.error.mismatch'),
    };

/// Opens "Connect by code" (PROTOCOL.md section 12). [initialCode] is a code
/// that was pasted somewhere else (the Connect field): it starts in "I have a
/// code" with the text filled in.
Future<void> showConnectByCodeDialog(BuildContext context, {String? initialCode}) {
  return showDialog<void>(
    context: context,
    builder: (_) => MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionManager>.value(value: context.read<SessionManager>()),
        ChangeNotifierProvider<AddressBook>.value(value: context.read<AddressBook>()),
        ChangeNotifierProvider<ShellController>.value(value: context.read<ShellController>()),
      ],
      child: ConnectByCodeDialog(initialCode: initialCode),
    ),
  );
}

enum _CodeMode { share, enter }

class ConnectByCodeDialog extends StatefulWidget {
  const ConnectByCodeDialog({super.key, this.initialCode});

  final String? initialCode;

  @override
  State<ConnectByCodeDialog> createState() => _ConnectByCodeDialogState();
}

class _ConnectByCodeDialogState extends State<ConnectByCodeDialog> {
  late _CodeMode _mode =
      (widget.initialCode ?? '').trimLeft().startsWith(kOfferPrefix) ? _CodeMode.enter : _CodeMode.share;
  late final TextEditingController _answer = TextEditingController();
  late final TextEditingController _offerText = TextEditingController(text: widget.initialCode ?? '');
  Timer? _tick;
  PendingCodeOffer? _offer;
  String? _answerCode;
  ViewerSession? _viewerSession;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _offer != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _answer.dispose();
    _offerText.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final manager = context.read<SessionManager>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final offer = await manager.createCodeOffer();
      if (!mounted) return;
      setState(() => _offer = offer);
    } on ConnectException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _paste(TextEditingController c) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() {
      c.text = text;
      _error = null;
    });
  }

  Future<void> _applyAnswer() async {
    final offer = _offer;
    if (offer == null) return;
    final manager = context.read<SessionManager>();
    final s = context.s;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await manager.acceptAnswerCode(offer, _answer.text);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on CodeException catch (e) {
      if (mounted) setState(() => _error = codeErrorMessage(s, e));
    } on ConnectException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _answerOffer() async {
    final manager = context.read<SessionManager>();
    final book = context.read<AddressBook>();
    final s = context.s;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final offer = await manager.readOfferCode(_offerText.text);
      if (!mounted) return;
      final known = book.byId(offer.peer.id);
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _OfferConfirmDialog(offer: offer, known: known != null && known.key == offer.key),
      );
      if (ok != true || !mounted) return;
      final r = await manager.answerOfferCode(offer);
      if (!mounted) return;
      setState(() {
        _answerCode = r.answerCode;
        _viewerSession = r.session;
      });
    } on CodeException catch (e) {
      if (mounted) setState(() => _error = codeErrorMessage(s, e));
    } on ConnectException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _done() {
    final session = _viewerSession;
    Navigator.of(context).pop();
    if (session != null) context.read<ShellController>().showSession(session);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context);
    return AlertDialog(
      title: Text(s.t('code.title')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.t('code.intro'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: Gap.m),
              if (_answerCode == null && _offer == null)
                SegmentedButton<_CodeMode>(
                  segments: [
                    ButtonSegment(
                      value: _CodeMode.share,
                      icon: const Icon(Icons.outbox_rounded),
                      label: Text(s.t('code.mode.share')),
                    ),
                    ButtonSegment(
                      value: _CodeMode.enter,
                      icon: const Icon(Icons.input_rounded),
                      label: Text(s.t('code.mode.enter')),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (v) => setState(() {
                    _mode = v.first;
                    _error = null;
                  }),
                ),
              const SizedBox(height: Gap.m),
              if (_mode == _CodeMode.share) ..._shareBody(context) else ..._enterBody(context),
              if (_error != null) ...[
                const SizedBox(height: Gap.m),
                Text(_error!, key: const ValueKey('code-error'), style: TextStyle(color: t.colorScheme.error)),
              ],
              const SizedBox(height: Gap.m),
              Text(
                s.t('code.hint.punch'),
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (_answerCode != null)
          FilledButton(key: const ValueKey('code-done'), onPressed: _done, child: Text(s.t('common.done')))
        else
          TextButton(
            onPressed: () {
              final o = _offer;
              if (o != null) unawaited(context.read<SessionManager>().discardCodeOffer(o));
              Navigator.of(context).pop();
            },
            child: Text(s.t('common.cancel')),
          ),
      ],
    );
  }

  List<Widget> _shareBody(BuildContext context) {
    final s = context.s;
    final offer = _offer;
    if (offer == null) {
      return [
        Text(s.t('code.share.hint')),
        const SizedBox(height: Gap.m),
        FilledButton.icon(
          key: const ValueKey('code-create'),
          onPressed: _busy ? null : _create,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.vpn_key_rounded),
          label: Text(_busy ? s.t('code.creating') : s.t('code.create')),
        ),
      ];
    }
    final left = offer.remaining;
    final time = left <= Duration.zero
        ? '0:00'
        : '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
    return [
      _CodeBox(
        label: s.t('code.yourCode'),
        code: offer.code,
        noun: s.t('code.noun'),
        copyKey: 'code-copy',
      ),
      const SizedBox(height: Gap.s),
      Text(
        left <= Duration.zero ? s.t('code.expired') : s.t('code.expiresIn', {'time': time}),
        key: const ValueKey('code-expiry'),
      ),
      const SizedBox(height: Gap.l),
      TextField(
        key: const ValueKey('code-answer-field'),
        controller: _answer,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        minLines: 1,
        maxLines: 3,
        decoration: InputDecoration(
          labelText: s.t('code.pasteAnswer'),
          suffixIcon: IconButton(
            tooltip: s.t('connect.paste'),
            icon: const Icon(Icons.content_paste_rounded),
            onPressed: _busy ? null : () => _paste(_answer),
          ),
        ),
      ),
      const SizedBox(height: Gap.m),
      FilledButton(
        key: const ValueKey('code-apply'),
        onPressed: _busy || left <= Duration.zero ? null : _applyAnswer,
        child: Text(s.t('code.apply')),
      ),
    ];
  }

  List<Widget> _enterBody(BuildContext context) {
    final s = context.s;
    final answer = _answerCode;
    if (answer != null) {
      return [
        _CodeBox(
          label: s.t('code.answerNoun'),
          code: answer,
          noun: s.t('code.answerNoun'),
          copyKey: 'code-answer-copy',
        ),
        const SizedBox(height: Gap.s),
        Text(s.t('code.answerReady')),
      ];
    }
    return [
      TextField(
        key: const ValueKey('code-offer-field'),
        controller: _offerText,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        minLines: 1,
        maxLines: 3,
        decoration: InputDecoration(
          labelText: s.t('code.pasteOffer'),
          suffixIcon: IconButton(
            tooltip: s.t('connect.paste'),
            icon: const Icon(Icons.content_paste_rounded),
            onPressed: _busy ? null : () => _paste(_offerText),
          ),
        ),
      ),
      const SizedBox(height: Gap.m),
      FilledButton(
        key: const ValueKey('code-answer-button'),
        onPressed: _busy ? null : _answerOffer,
        child: _busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(s.t('code.answer')),
      ),
    ];
  }
}

/// A code in a copyable box, with a QR code when it is short enough to scan.
class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.label, required this.code, required this.noun, required this.copyKey});

  final String label;
  final String code;
  final String noun;
  final String copyKey;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (code.length <= kMaxQrCodeChars) Center(child: QrView(data: code, size: 220)),
        if (code.length <= kMaxQrCodeChars) const SizedBox(height: Gap.m),
        Container(
          padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.xs, Gap.s),
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 96),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          code,
                          key: ValueKey('$copyKey-text'),
                          style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey(copyKey),
                tooltip: s.t('code.copy'),
                icon: const Icon(Icons.copy_rounded),
                onPressed: () => copyToClipboard(context, code, noun),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OfferConfirmDialog extends StatelessWidget {
  const _OfferConfirmDialog({required this.offer, required this.known});

  final OfferCode offer;
  final bool known;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context);
    return AlertDialog(
      title: Text(s.t('code.confirm.title')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PeerCard(peer: offer.peer),
            const SizedBox(height: Gap.s),
            Text(
              known ? s.t('code.confirm.known') : s.t('code.confirm.new'),
              key: const ValueKey('code-confirm-known'),
              style: t.textTheme.labelLarge?.copyWith(color: known ? context.status.good : context.status.warn),
            ),
            const SizedBox(height: Gap.m),
            Text(s.t('code.confirm.body')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(s.t('common.cancel'))),
        FilledButton(
          key: const ValueKey('code-confirm-ok'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(s.t('code.confirm.trust')),
        ),
      ],
    );
  }
}
