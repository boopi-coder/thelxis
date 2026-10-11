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
import 'widgets/hover_tint.dart';
import 'widgets/rows.dart';

/// Active incoming / outgoing sessions and the local history.
class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final manager = context.watch<SessionManager>();
    final history = context.watch<SessionHistory>();
    final shell = context.read<ShellController>();
    final hosts = manager.hostSessions;
    final viewers = manager.viewerSessions;

    return PageScroll(
      maxWidth: 960,
      children: [
        PageTitle(s.t('sessions.title'), subtitle: s.t('sessions.subtitle')),
        const SizedBox(height: Gap.l),
        SettingsGroup(
          title: s.t('sessions.incoming'),
          children: [
            if (hosts.isEmpty)
              EmptyState(compact: true, icon: Icons.shield_outlined, title: s.t('sessions.incoming.empty'))
            else
              for (final h in hosts) _HostRow(session: h),
          ],
        ),
        const SizedBox(height: Gap.xl),
        SettingsGroup(
          title: s.t('sessions.outgoing'),
          children: [
            if (viewers.isEmpty)
              EmptyState(compact: true, icon: Icons.cast_connected_outlined, title: s.t('sessions.outgoing.empty'))
            else
              for (final v in viewers)
                _ViewerRow(
                  session: v,
                  onOpen: () => shell.showSession(v),
                  onClose: () async {
                    await v.end('user');
                    shell.sessionClosed(v);
                    WidgetsBinding.instance.addPostFrameCallback((_) => manager.dismiss(v));
                  },
                ),
          ],
        ),
        const SizedBox(height: Gap.xl),
        SettingsGroup(
          title: s.t('sessions.history'),
          trailing: history.records.isEmpty
              ? null
              : TextButton(onPressed: history.clear, child: Text(s.t('sessions.clear'))),
          children: [
            if (history.records.isEmpty)
              EmptyState(compact: true, icon: Icons.history_rounded, title: s.t('sessions.history.empty'))
            else
              for (final r in history.records) _HistoryRow(record: r),
          ],
        ),
      ],
    );
  }
}

/// Elapsed time of a live session; ticks once a second without rebuilding
/// anything around it.
class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.session});

  final SessionBase session;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !widget.session.isEnded) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Text(formatDuration(widget.session.duration), style: TextStyle(fontFeatures: kTabularFigures));
}

String _phaseLabel(S s, SessionPhase p) => switch (p) {
  SessionPhase.connecting => s.t('phase.connecting'),
  SessionPhase.authenticating => s.t('phase.authorizing'),
  SessionPhase.awaitingApproval => s.t('phase.awaiting'),
  SessionPhase.active => s.t('phase.active'),
  SessionPhase.reconnecting => s.t('phase.reconnecting'),
  SessionPhase.ended => s.t('phase.ended'),
};

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.os,
    required this.title,
    required this.phase,
    required this.session,
    this.detail,
    this.trailing = const [],
    this.onTap,
  });

  final String os;
  final String title;
  final String phase;
  final SessionBase session;
  final String? detail;
  final List<Widget> trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.c;
    final sub = t.bodySmall?.copyWith(color: c.textSecondary);
    return HoverTint(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 10),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(color: c.inset, borderRadius: BorderRadius.circular(Radii.control)),
              child: SizedBox(width: 36, height: 36, child: Icon(osIcon(os), size: 20, color: c.textSecondary)),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (detail != null) Text(detail!, style: sub, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Row(
                    children: [
                      Flexible(child: Text(phase, style: sub, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Text(' · ', style: sub),
                      DefaultTextStyle.merge(style: sub, child: _Elapsed(session: session)),
                    ],
                  ),
                ],
              ),
            ),
            ...trailing,
          ],
        ),
      ),
    );
  }
}

class _HostRow extends StatelessWidget {
  const _HostRow({required this.session});

  final HostSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final s = context.s;
        final path = session.stats.value.path.name == 'unknown' ? '' : ' · ${session.stats.value.pathLabel}';
        return _SessionRow(
          os: session.peer.os,
          title: session.peer.name,
          detail: formatThelxisId(session.peer.id),
          phase: '${_phaseLabel(s, session.phase)}$path',
          session: session,
          trailing: [
            if (hostCanShowFiles(session))
              IconButton(
                key: const ValueKey('host-files'),
                tooltip: s.t('toolbar.files'),
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: () => showSessionFilesPanel(context, session),
              ),
            const SizedBox(width: Gap.xs),
            FilledButton(
              style: context.dangerButton,
              onPressed: () => session.end('user'),
              child: Text(s.t('banner.stop')),
            ),
          ],
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
        return _SessionRow(
          os: session.peer.os,
          title: session.peer.name,
          phase: _phaseLabel(s, session.phase),
          session: session,
          onTap: session.isEnded ? null : onOpen,
          trailing: [
            if (!session.isEnded) TextButton(onPressed: onOpen, child: Text(s.t('sessions.open'))),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: session.isEnded ? null : context.c.danger),
              onPressed: onClose,
              child: Text(session.isEnded ? s.t('common.close') : s.t('sessions.end')),
            ),
          ],
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
    final t = Theme.of(context).textTheme;
    final c = context.c;
    final s = context.s;
    final when = record.startedAt;
    final date =
        '${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')} '
        '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 10),
      child: Row(
        children: [
          Icon(
            record.incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
            size: 18,
            color: c.textSecondary,
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(record.peerName, style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                Text(
                  '${record.incoming ? s.t('sessions.incomingRow') : s.t('sessions.outgoingRow')} · $date · '
                  '${formatDuration(Duration(seconds: record.durationSeconds))}',
                  style: t.bodySmall?.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          if (record.reason != 'user')
            Text(_reasonLabel(s, record.reason), style: t.labelSmall?.copyWith(color: c.textMuted)),
        ],
      ),
    );
  }
}

String _reasonLabel(S s, String reason) {
  const known = {'denied', 'remote', 'timeout', 'error', 'security'};
  return known.contains(reason) ? s.t('reason.$reason') : reason;
}
