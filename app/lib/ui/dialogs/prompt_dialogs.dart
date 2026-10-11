import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/thelxis_id.dart';
import '../../net/peer_identity.dart';
import '../../protocol/models.dart';
import '../../session/prompts.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Builds the dialog for [prompt]. Dialogs only resolve their prompt; the
/// [PromptHost] closes the route when the prompt completes (by the user, a
/// timeout, or the session ending).
Widget promptDialog(Prompt<Object?> prompt) {
  switch (prompt) {
    case AcceptRequestPrompt():
      return AcceptRequestDialog(prompt: prompt);
    case ReverseOfferPrompt():
      return ReverseOfferDialog(prompt: prompt);
    case FirstContactPrompt():
      return FirstContactDialog(prompt: prompt);
    case WarningPrompt():
      return WarningDialog(prompt: prompt);
  }
}

/// Verified identity block shared by the prompts: name, OS and the ID the
/// peer cryptographically proved.
class PeerCard extends StatelessWidget {
  const PeerCard({super.key, required this.peer});

  final PeerIdentity peer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          CircleAvatar(child: Icon(osIcon(peer.os))),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(peer.name, style: t.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                Text(osLabel(peer.os), style: t.textTheme.bodySmall),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.verified_rounded, size: 14, color: context.status.good),
                    const SizedBox(width: 4),
                    Flexible(
                      child: SelectableText(
                        formatThelxisId(peer.id),
                        style: t.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "X wants to control this device": permission toggles, "Always allow this
/// device", 30 s countdown that denies automatically.
class AcceptRequestDialog extends StatefulWidget {
  const AcceptRequestDialog({super.key, required this.prompt});

  final AcceptRequestPrompt prompt;

  @override
  State<AcceptRequestDialog> createState() => _AcceptRequestDialogState();
}

class _AcceptRequestDialogState extends State<AcceptRequestDialog> {
  late bool _control = widget.prompt.proposed.control && widget.prompt.canControl;
  late bool _clipboard = widget.prompt.proposed.clipboard;
  bool _always = false;
  Timer? _timer;
  int _left = 30;

  @override
  void initState() {
    super.initState();
    _left = widget.prompt.deadline.difference(DateTime.now()).inSeconds.clamp(0, 999);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = widget.prompt.deadline.difference(DateTime.now()).inSeconds;
      if (left <= 0) {
        _finish(ApprovalResult.denied);
      } else if (mounted) {
        setState(() => _left = left);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _finish(ApprovalResult r) {
    _timer?.cancel();
    widget.prompt.resolve(r);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = widget.prompt;
    final who = p.claimedUser.isEmpty ? p.peer.name : p.claimedUser;
    return AlertDialog(
      title: Text('$who wants to connect'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PeerCard(peer: p.peer),
              if (p.claimedUser.isNotEmpty && p.claimedUser != p.peer.name)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: Text(
                    'They call themselves "${p.claimedUser}". Only the ID above is verified.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: Gap.l),
              const Text('They will be able to:'),
              const SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('See your screen'),
                value: true,
                onChanged: null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Use your mouse and keyboard'),
                subtitle: p.canControl ? null : const Text('Not available on this system'),
                value: _control,
                onChanged: p.canControl ? (v) => setState(() => _control = v) : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Share the clipboard'),
                value: _clipboard,
                onChanged: (v) => setState(() => _clipboard = v),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Always allow this device'),
                subtitle: const Text('Skips this prompt next time. Revoke it in Settings.'),
                value: _always,
                onChanged: (v) => setState(() => _always = v ?? false),
              ),
              const SizedBox(height: Gap.s),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _left / p.timeout.inSeconds,
                  minHeight: 4,
                ),
              ),
              const SizedBox(height: 4),
              Text('Denied automatically in $_left s', style: t.textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _finish(ApprovalResult.denied),
          child: const Text('Deny'),
        ),
        FilledButton(
          onPressed: () => _finish(ApprovalResult(
            accepted: true,
            alwaysAllow: _always,
            permissions: Permissions(view: true, control: _control, clipboard: _clipboard),
          )),
          child: const Text('Accept'),
        ),
      ],
    );
  }
}

/// "Bob offers you control of his computer".
class ReverseOfferDialog extends StatelessWidget {
  const ReverseOfferDialog({super.key, required this.prompt});

  final ReverseOfferPrompt prompt;

  @override
  Widget build(BuildContext context) {
    void done(bool accepted) {
      prompt.resolve(accepted);
    }

    return AlertDialog(
      title: Text('${prompt.peer.name} offers you control of their computer'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PeerCard(peer: prompt.peer),
            const SizedBox(height: Gap.m),
            const Text('You will see their screen and be able to use it. They can stop at any time.'),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => done(false), child: const Text('Decline')),
        FilledButton(onPressed: () => done(true), child: const Text('Accept')),
      ],
    );
  }
}

/// Trust on first use: confirm the ID of a device reached by bare address.
class FirstContactDialog extends StatelessWidget {
  const FirstContactDialog({super.key, required this.prompt});

  final FirstContactPrompt prompt;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    void done(bool ok) {
      prompt.resolve(ok);
    }

    return AlertDialog(
      title: const Text('Connect to a new device?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PeerCard(peer: prompt.peer),
            const SizedBox(height: Gap.m),
            Text('Found at ${prompt.address.hostPort}', style: t.textTheme.bodySmall),
            const SizedBox(height: Gap.m),
            const Text(
              'Check that this ID matches the one the owner gave you. If it does '
              'not, someone else is answering at this address.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => done(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => done(true), child: const Text('Trust and connect')),
      ],
    );
  }
}

/// Security notice: identity mismatch, failed signature.
class WarningDialog extends StatelessWidget {
  const WarningDialog({super.key, required this.prompt});

  final WarningPrompt prompt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.gpp_maybe_rounded, color: scheme.error, size: 36),
      title: Text(prompt.title),
      content: SizedBox(width: 420, child: Text(prompt.message)),
      actions: [
        FilledButton(
          onPressed: () => prompt.resolve(null),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
