import 'package:flutter/material.dart';

import '../../files/files.dart';
import '../../l10n/strings.dart';
import '../../session/host_session.dart';
import '../../session/session_base.dart';
import '../../session/viewer_session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Width of the file panel on desktop.
const double kFilesPanelWidth = 400;

/// The file-transfer panel of one session, or a short wait state while the
/// `files` channel is not up yet.
class SessionFilesPanel extends StatelessWidget {
  const SessionFilesPanel({super.key, required this.session, required this.onClose});

  final SessionBase session;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FileTransferEndpoint?>(
      valueListenable: session.filesListenable,
      builder: (context, endpoint, _) {
        if (endpoint == null) {
          final s = context.s;
          return Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(Gap.s),
                  child: IconButton(
                    tooltip: s.t('common.close'),
                    icon: const Icon(Icons.close_rounded),
                    onPressed: onClose,
                  ),
                ),
              ),
              Expanded(
                child: EmptyState(
                  icon: Icons.folder_off_outlined,
                  title: s.t('files.unavailable'),
                  message: s.t('files.unavailable.hint'),
                ),
              ),
            ],
          );
        }
        return FileTransferPanel(endpoint, onClose: onClose);
      },
    );
  }
}

/// Side panel (desktop) that slides over the right edge of the session view.
class SessionFilesPanelHost extends StatelessWidget {
  const SessionFilesPanelHost({super.key, required this.session, required this.onClose});

  final ViewerSession session;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.c.surface,
      elevation: 4,
      shadowColor: const Color(0x66000000),
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(Radii.card)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: kFilesPanelWidth,
        child: SessionFilesPanel(session: session, onClose: onClose),
      ),
    );
  }
}

/// Lets files be dropped on the remote picture to send them. Disabled (and
/// inert) unless the host granted `permissions.files` and the channel is up.
class SessionFilesDropTarget extends StatelessWidget {
  const SessionFilesDropTarget({super.key, required this.session, required this.child});

  final ViewerSession session;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.filesListenable]),
      builder: (context, _) {
        final endpoint = session.files;
        final enabled =
            endpoint != null && (session.permissions?.files ?? false) && !session.isEnded;
        return FileDropTarget(
          enabled: enabled,
          onFiles: (paths) {
            if (endpoint != null) sendPathsWithFeedback(context, endpoint, paths);
          },
          child: child,
        );
      },
    );
  }
}

/// Opens the panel for [session] as a dialog (wide screens, used for incoming
/// sessions on the host) or a bottom sheet (phones, and the viewer's Files
/// button there).
Future<void> showSessionFilesPanel(BuildContext context, SessionBase session) {
  final wide = MediaQuery.sizeOf(context).width >= 720;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: kFilesPanelWidth + 40,
          height: 640,
          child: SessionFilesPanel(session: session, onClose: () => Navigator.of(ctx).pop()),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * 0.8,
      child: SessionFilesPanel(session: session, onClose: () => Navigator.of(ctx).pop()),
    ),
  );
}

/// Whether the host user gets a Files button for [session]: the viewer must
/// have been granted file access and the session must be up.
bool hostCanShowFiles(HostSession session) =>
    !session.isEnded &&
    session.permissions.files &&
    (session.phase == SessionPhase.active || session.phase == SessionPhase.reconnecting);
