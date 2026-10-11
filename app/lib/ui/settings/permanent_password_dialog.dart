import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../session/host_credentials.dart';

/// Sets the permanent (unattended) password. Only the derived key is stored.
Future<void> showPermanentPasswordDialog(BuildContext context, HostCredentials credentials) {
  return showDialog<void>(
    context: context,
    builder: (_) => _PermanentPasswordDialog(credentials: credentials),
  );
}

class _PermanentPasswordDialog extends StatefulWidget {
  const _PermanentPasswordDialog({required this.credentials});

  final HostCredentials credentials;

  @override
  State<_PermanentPasswordDialog> createState() => _PermanentPasswordDialogState();
}

class _PermanentPasswordDialogState extends State<_PermanentPasswordDialog> {
  final TextEditingController _pw = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _pw.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = context.s;
    if (_pw.text.length < 8) {
      setState(() => _error = s.t('perm.pw.short'));
      return;
    }
    if (_pw.text != _confirm.text) {
      setState(() => _error = s.t('perm.pw.mismatch'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.credentials.setPermanentPassword(_pw.text);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return AlertDialog(
      title: Text(s.t('settings.permanent')),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(s.t('perm.pw.intro')),
            const SizedBox(height: 16),
            TextField(
              controller: _pw,
              obscureText: _obscure,
              autofocus: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: s.t('perm.pw.new'),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(labelText: s.t('perm.pw.repeat'), errorText: _error),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(s.t('common.cancel'))),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(s.t('common.save')),
        ),
      ],
    );
  }
}
