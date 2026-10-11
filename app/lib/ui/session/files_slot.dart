import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../session/viewer_session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Builds the file-transfer side panel for a session.
typedef SessionFilesPanelBuilder = Widget Function(
  BuildContext context,
  ViewerSession session,
  VoidCallback close,
);

/// Wraps the remote picture so files dropped on it can be sent.
typedef SessionDropWrapper = Widget Function(
  BuildContext context,
  ViewerSession session,
  Widget child,
);

/// INTEGRATION POINT for the file-transfer module (`lib/files`).
///
/// The session view shows [panelBuilder]'s widget in a side panel (desktop)
/// or bottom sheet (phones) when the toolbar's Files button is pressed, and
/// wraps the remote picture with [dropWrapper]. The module installs both at
/// startup (for example `SessionFilesSlot.panelBuilder = (c, s, close) =>
/// FileTransferPanel(...)`); until then a placeholder is shown.
abstract final class SessionFilesSlot {
  static SessionFilesPanelBuilder panelBuilder = _placeholderPanel;

  static SessionDropWrapper dropWrapper = (context, session, child) => child;

  static Widget _placeholderPanel(BuildContext context, ViewerSession session, VoidCallback close) {
    final s = context.s;
    return Column(
      children: [
        _PanelHeader(title: s.t('files.title'), onClose: close),
        Expanded(
          child: EmptyState(
            icon: Icons.folder_copy_outlined,
            title: s.t('files.soon.title'),
            message: s.t('files.soon.body'),
          ),
        ),
      ],
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.s, 0),
      child: Row(
        children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
          IconButton(
            tooltip: context.s.t('common.close'),
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Side panel (wide) that slides in over the right edge of the session view.
class SessionFilesPanelHost extends StatelessWidget {
  const SessionFilesPanelHost({super.key, required this.session, required this.onClose});

  final ViewerSession session;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 8,
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 380,
        child: SessionFilesSlot.panelBuilder(context, session, onClose),
      ),
    );
  }
}

/// Opens the panel as a modal bottom sheet (phones).
Future<void> showSessionFilesSheet(BuildContext context, ViewerSession session) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * 0.8,
      child: SessionFilesSlot.panelBuilder(ctx, session, () => Navigator.of(ctx).pop()),
    ),
  );
}
