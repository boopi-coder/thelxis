import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/thelxis_id.dart';
import '../l10n/strings.dart';
import '../session/host_session.dart';
import '../session/session_base.dart';
import '../session/session_history.dart';
import '../session/session_manager.dart';
import '../session/viewer_session.dart';
import 'session/files_slot.dart';
import 'shell_controller.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Active incoming / outgoing sessions and the local history.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Durations of live sessions advance once a second.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final manager = context.watch<SessionManager>();
    final history = context.watch<SessionHistory>();
    final shell = context.read<ShellController>();
    final hosts = manager.hostSessions;
    final viewers = manager.viewerSessions;

    return PageScroll(
      children: [
        PageTitle(s.t('sessions.title'), subtitle: s.t('sessions.subtitle')),
        SectionHeader(s.t('sessions.incoming')),
        if (hosts.isEmpty)
          Card(
            child: EmptyState(icon: Icons.shield_outlined, title: s.t('sessions.incoming.empty')),
          )
        else
          for (final s in hosts)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: _HostRow(session: s),
            ),
        SectionHeader(s.t('sessions.outgoing')),
        if (viewers.isEmpty)
          Card(
            child: EmptyState(
              icon: Icons.cast_connected_rounded,
              title: s.t('sessions.outgoing.empty'),
            ),
          )
        else
          for (final s in viewers)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: _ViewerRow(
                session: s,
                onOpen: () => shell.showSession(s),
                onClose: () async {
                  await s.end('user');
                  shell.sessionClosed(s);
                  WidgetsBinding.instance.addPostFrameCallback((_) => manager.dismiss(s));
                },
              ),
            ),
        SectionHeader(
          s.t('sessions.history'),
          trailing: history.records.isEmpty
              ? null
              : TextButton(onPressed: history.clear, child: Text(s.t('sessions.clear'))),
        ),
        if (history.records.isEmpty)
          Card(
            child: EmptyState(icon: Icons.history_rounded, title: s.t('sessions.history.empty')),
          )
        else
          Card(
            child: Column(children: [for (final r in history.records) _HistoryRow(record: r)]),
          ),
      ],
    );
  }
}

String _phaseLabel(S s, SessionPhase p) => switch (p) {
  SessionPhase.connecting => s.t('phase.connecting'),
  SessionPhase.authenticating => s.t('phase.authorizing'),
  SessionPhase.awaitingApproval => s.t('phase.awaiting'),
  SessionPhase.active => s.t('phase.active'),
  SessionPhase.reconnecting => s.t('phase.reconnecting'),
  SessionPhase.ended => s.t('phase.ended'),
};

class _HostRow extends StatelessWidget {
  const _HostRow({required this.session});

  final HostSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final t = Theme.of(context);
        final s = context.s;
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
            leading: CircleAvatar(child: Icon(osIcon(session.peer.os))),
            title: Text(session.peer.name),
            subtitle: Text(
              '${formatThelxisId(session.peer.id)}\n'
              '${_phaseLabel(s, session.phase)} · ${formatDuration(session.duration)}'
              '${session.stats.value.path.name == 'unknown' ? '' : ' · ${session.stats.value.pathLabel}'}',
            ),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hostCanShowFiles(session))
                  IconButton(
                    key: const ValueKey('host-files'),
                    tooltip: s.t('toolbar.files'),
                    icon: const Icon(Icons.folder_open_rounded),
                    onPressed: () => showSessionFilesPanel(context, session),
                  ),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(foregroundColor: t.colorScheme.error),
                  onPressed: () => session.end('user'),
                  child: Text(s.t('banner.stop')),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ViewerRow extends StatelessWidget {
  const _ViewerRow({required this.session, required this.onOpen, required this.onClose});

  final ViewerSession session;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final s = context.s;
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
            leading: CircleAvatar(child: Icon(osIcon(session.peer.os))),
            title: Text(session.peer.name),
            subtitle: Text(
              '${_phaseLabel(s, session.phase)} · ${formatDuration(session.duration)}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!session.isEnded)
                  TextButton(onPressed: onOpen, child: Text(s.t('sessions.open'))),
                TextButton(
                  onPressed: onClose,
                  child: Text(session.isEnded ? s.t('common.close') : s.t('sessions.end')),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.record});

  final SessionRecord record;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.s;
    final when = record.startedAt;
    final date =
        '${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')} '
        '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
    return ListTile(
      leading: Icon(
        record.incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
        color: t.colorScheme.onSurfaceVariant,
      ),
      title: Text(record.peerName),
      subtitle: Text(
        '${record.incoming ? s.t('sessions.incomingRow') : s.t('sessions.outgoingRow')} · $date · '
        '${formatDuration(Duration(seconds: record.durationSeconds))}',
      ),
      trailing: record.reason == 'user'
          ? null
          : Text(_reasonLabel(s, record.reason), style: t.textTheme.labelSmall),
    );
  }
}

String _reasonLabel(S s, String reason) {
  const known = {'denied', 'remote', 'timeout', 'error', 'security'};
  return known.contains(reason) ? s.t('reason.$reason') : reason;
}
