import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../platform/host_platform.dart';
import '../../protocol/control_messages.dart';
import '../../session/host_session.dart';
import '../../session/session_manager.dart';
import '../session/files_slot.dart';
import '../theme.dart';
import '../../l10n/strings.dart';

/// Persistent red banner while this device is being controlled, with Stop.
/// (The native always-on-top badge is separate and cannot be hidden.)
class ControlledBanner extends StatelessWidget {
  const ControlledBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<SessionManager>();
    final live = manager.liveHostSessions;
    final scheme = Theme.of(context).colorScheme;
    return live.isEmpty
        ? const SizedBox(width: double.infinity)
        : Material(
            color: scheme.errorContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.l,
                  vertical: Gap.s,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final x in live) _InputIssueRow(session: x),
                    _mainRow(context, manager, live),
                  ],
                ),
              ),
            ),
          );
  }

  Widget _mainRow(
    BuildContext context,
    SessionManager manager,
    List<HostSession> live,
  ) {
    final s = context.s;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(
          Icons.screen_share_rounded,
          color: scheme.onErrorContainer,
          size: 20,
        ),
        const SizedBox(width: Gap.m),
        Expanded(
          child: Text(
            live.any((x) => x.controlEnabled)
                ? s.t('banner.controlledBy', {
                    'names': live.map((x) => x.peer.name).join(', '),
                  })
                : s.t('banner.viewedBy', {
                    'names': live.map((x) => x.peer.name).join(', '),
                  }),
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: scheme.onErrorContainer),
          ),
        ),
        if (live.length == 1 && hostCanShowFiles(live.first))
          _FilesControl(session: live.first),
        if (live.length == 1 && live.first.permissions.control)
          _PauseControl(session: live.first),
        FilledButton(
          style: context.dangerButton,
          onPressed: manager.stopAllHostSessions,
          child: Text(
            live.length > 1 ? s.t('banner.stopAll') : s.t('banner.stop'),
          ),
        ),
      ],
    );
  }
}

/// Tells the person at this device why a viewer's input has no effect and what
/// to fix. The session already raised the OS prompt once; the button brings the
/// settings pane back for whoever dismissed it.
class _InputIssueRow extends StatelessWidget {
  const _InputIssueRow({required this.session});

  final HostSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final issue = session.inputIssue;
        if (issue == null) return const SizedBox.shrink();
        final key = switch (issue) {
          InputIssue.permission => defaultTargetPlatform == TargetPlatform.android
              ? 'banner.input.permission.android'
              : 'banner.input.permission.macos',
          InputIssue.blocked => 'session.input.blocked',
        };
        final scheme = Theme.of(context).colorScheme;
        final s = context.s;
        return Padding(
          key: const ValueKey('banner-input-issue'),
          padding: const EdgeInsets.only(bottom: Gap.xs),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Text(
                  s.t(key),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onErrorContainer),
                ),
              ),
              if (issue == InputIssue.permission)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onErrorContainer,
                  ),
                  onPressed: () => context
                      .read<HostPlatform>()
                      .requestPermission(HostPermission.inputControl),
                  child: Text(s.t('banner.input.openSettings')),
                ),
            ],
          ),
        );
      },
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
          style: TextButton.styleFrom(foregroundColor: context.c.danger),
          onPressed: () => session.setControlAllowed(!on),
          child: Text(
            on
                ? context.s.t('banner.pauseControl')
                : context.s.t('banner.allowControl'),
          ),
        );
      },
    );
  }
}

class _FilesControl extends StatelessWidget {
  const _FilesControl({required this.session});

  final HostSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      key: const ValueKey('banner-files'),
      tooltip: context.s.t('toolbar.files'),
      color: scheme.onErrorContainer,
      icon: const Icon(Icons.folder_open_rounded),
      onPressed: () => showSessionFilesPanel(context, session),
    );
  }
}
