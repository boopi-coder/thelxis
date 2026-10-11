import 'package:flutter/material.dart';

import '../../core/thelxis_id.dart';
import '../../session/session_base.dart';
import '../../session/viewer_session.dart';
import '../theme.dart';

/// Dimmed scrim with a spinner and message ("Connecting…", "Reconnecting…").
class BusyOverlay extends StatelessWidget {
  const BusyOverlay({super.key, required this.title, this.subtitle, this.dim = 0.55});

  final String title;
  final String? subtitle;
  final double dim;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ColoredBox(
      color: Colors.black.withValues(alpha: dim),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: Gap.l),
              Text(title, style: t.textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: Gap.xs),
                Text(
                  subtitle!,
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown after a session ended; the tab stays until the user closes it.
class EndedOverlay extends StatelessWidget {
  const EndedOverlay({super.key, required this.session, required this.onClose});

  final ViewerSession session;
  final VoidCallback onClose;

  static String describe(ViewerSession s) {
    final notice = s.notice;
    if (notice != null && notice.isNotEmpty) return notice;
    switch (s.endReason) {
      case 'denied':
        return 'The other side denied the connection.';
      case 'remote':
        return '${s.peer.name} ended the session.';
      case 'timeout':
        return 'The connection timed out.';
      case 'security':
        return 'The connection was closed because it could not be verified.';
      case 'error':
        return 'The connection failed.';
      default:
        return 'Session ended.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.78),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Container(
            margin: const EdgeInsets.all(Gap.l),
            padding: const EdgeInsets.all(Gap.xl),
            decoration: BoxDecoration(
              color: t.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link_off_rounded, size: 36, color: t.colorScheme.onSurfaceVariant),
                const SizedBox(height: Gap.m),
                Text(describe(session), style: t.textTheme.titleMedium, textAlign: TextAlign.center),
                const SizedBox(height: Gap.xl),
                FilledButton(onPressed: onClose, child: const Text('Close')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for the host's password (or offers to request access instead).
class PasswordPrompt extends StatefulWidget {
  const PasswordPrompt({super.key, required this.session});

  final ViewerSession session;

  @override
  State<PasswordPrompt> createState() => _PasswordPromptState();
}

class _PasswordPromptState extends State<PasswordPrompt> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pw = _controller.text;
    if (pw.isEmpty || _busy) return;
    setState(() => _busy = true);
    await widget.session.submitPassword(pw);
    if (!mounted) return;
    _controller.clear();
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final prompt = widget.session.authPrompt;
    if (prompt == null) return const SizedBox.shrink();
    final peer = widget.session.peer;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.7),
      child: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Container(
              margin: const EdgeInsets.all(Gap.l),
              padding: const EdgeInsets.all(Gap.xl),
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lock_outline_rounded, color: t.colorScheme.primary),
                      const SizedBox(width: Gap.m),
                      Expanded(
                        child: Text(peer.name, style: t.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.xs),
                  Text(
                    'ID ${formatThelxisId(peer.id)}',
                    style: t.textTheme.bodySmall?.copyWith(
                      color: t.colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: Gap.l),
                  if (prompt.canPassword)
                    TextField(
                      controller: _controller,
                      autofocus: true,
                      obscureText: _obscure,
                      enableSuggestions: false,
                      autocorrect: false,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        errorText: prompt.error,
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                  if (prompt.canPassword) ...[
                    const SizedBox(height: Gap.l),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Connect'),
                    ),
                  ],
                  if (prompt.canRequest) ...[
                    const SizedBox(height: Gap.s),
                    OutlinedButton(
                      onPressed: widget.session.requestAccess,
                      child: const Text('Request access instead'),
                    ),
                  ],
                  const SizedBox(height: Gap.s),
                  TextButton(
                    onPressed: () => widget.session.end('user'),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Status text for phases before the picture is available.
String phaseTitle(ViewerSession s) {
  switch (s.phase) {
    case SessionPhase.connecting:
      return 'Connecting to ${s.peer.name}…';
    case SessionPhase.authenticating:
      return 'Authorizing…';
    case SessionPhase.awaitingApproval:
      return 'Waiting for ${s.peer.name} to accept…';
    case SessionPhase.active:
      return 'Waiting for the first frame…';
    case SessionPhase.reconnecting:
      return 'Reconnecting…';
    case SessionPhase.ended:
      return 'Session ended';
  }
}
