import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../session/host_session.dart';
import '../../session/session_base.dart';
import '../../session/session_manager.dart';
import '../theme.dart';

/// Persistent red banner while this device is being controlled, with Stop.
class ControlledBanner extends StatelessWidget {
  const ControlledBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<SessionManager>();
    final live = manager.hostSessions
        .where((s) => s.phase == SessionPhase.active || s.phase == SessionPhase.reconnecting)
        .toList();
    if (live.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final names = live.map((s) => s.peer.name).join(', ');
    final controlling = live.any((s) => s.controlEnabled);
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
          child: Row(
            children: [
              Icon(Icons.screen_share_rounded, color: scheme.onErrorContainer, size: 20),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Text(
                  controlling ? 'Controlled by $names' : 'Screen visible to $names',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onErrorContainer),
                ),
              ),
              if (live.length == 1 && live.first.permissions.control)
                _PauseControl(session: live.first),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  minimumSize: const Size(0, 36),
                ),
                onPressed: manager.stopAllHostSessions,
                child: Text(live.length > 1 ? 'Stop all' : 'Stop'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PauseControl extends StatelessWidget {
  const _PauseControl({required this.session});

  final HostSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final on = session.permissions.control;
        return TextButton(
          onPressed: () => session.setControlAllowed(!on),
          child: Text(on ? 'Pause control' : 'Allow control'),
        );
      },
    );
  }
}
