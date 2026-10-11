import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../ui/widgets/surface.dart';
import '../installers/installer.dart' show ManualInstallReason;
import '../update_exception.dart';
import '../update_service.dart';
import 'update_links.dart';
import 'update_strings.dart';

/// Compact flat banner for the Home screen: an update is available,
/// downloading, waiting for the end of a session, or needs a click. Hidden
/// otherwise.
///
/// With [embedded] only the row is drawn (no card), for placing it inside the
/// Home "setup needed" card. An available or failed update has a close
/// button that skips that version for good (persisted by the service).
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.service, this.embedded = false});

  final UpdateService service;
  final bool embedded;

  /// Whether [service] is in a state the banner shows something for.
  static bool hasContent(UpdateService service) =>
      _BannerView.of(service, const UpdateStrings.english()) != null;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final view = _BannerView.of(service, UpdateStrings.of(context));
        if (view == null) return const SizedBox(width: double.infinity);
        final row = _BannerRow(view: view);
        if (embedded) return row;
        return Padding(
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: AppCard(padding: const EdgeInsets.all(Gap.l), child: row),
        );
      },
    );
  }
}

/// Everything the card shows for one service state.
class _BannerView {
  const _BannerView({
    required this.id,
    required this.icon,
    required this.title,
    this.subtitle,
    this.progress,
    this.indeterminate = false,
    this.spinning = false,
    this.isError = false,
    this.actions = const [],
    this.notes,
    this.onClose,
  });

  final String id;
  final IconData icon;
  final String title;
  final String? subtitle;

  /// 0..1 determinate progress bar.
  final double? progress;
  final bool indeterminate;
  final bool spinning;
  final bool isError;
  final List<_BannerAction> actions;
  final Uri? notes;

  /// Dismisses the banner for good (skips this version).
  final VoidCallback? onClose;

  static _BannerView? of(UpdateService s, UpdateStrings t) {
    final version = s.availableVersion;
    if (s.offer == null || version == null) return null;
    switch (s.state) {
      case UpdateState.idle:
      case UpdateState.upToDate:
        return null;
      case UpdateState.checking:
      case UpdateState.available:
        return _BannerView(
          id: 'available',
          icon: Icons.arrow_upward_rounded,
          title: t.availableTitle(version),
          subtitle: t.availableSubtitle,
          notes: s.notesUrl,
          onClose: () => s.skip(version),
          actions: [_BannerAction(t.update, s.downloadAndInstall, primary: true)],
        );
      case UpdateState.downloading:
        final p = s.progress;
        return _BannerView(
          id: 'downloading',
          icon: Icons.downloading_rounded,
          title: t.downloadingTitle(version),
          subtitle: p == null ? null : t.downloadProgress(p.received, p.total, p.bytesPerSecond),
          progress: p?.fraction,
          indeterminate: p == null,
          actions: [_BannerAction(t.cancel, s.cancelDownload)],
        );
      case UpdateState.verifying:
        return _BannerView(
          id: 'verifying',
          icon: Icons.verified_user_outlined,
          title: t.downloadingTitle(version),
          subtitle: t.verifying,
          indeterminate: true,
        );
      case UpdateState.ready:
        if (s.awaitingConfirmation) {
          return _BannerView(
            id: 'confirm',
            icon: Icons.system_update_alt_rounded,
            title: t.readyTitle(version),
            subtitle: t.readyConfirm,
            notes: s.notesUrl,
            actions: [_BannerAction(t.installNow, s.downloadAndInstall, primary: true)],
          );
        }
        return _BannerView(
          id: s.waitingForIdle ? 'waiting' : 'preparing',
          icon: s.waitingForIdle ? Icons.schedule_rounded : Icons.system_update_alt_rounded,
          title: t.readyTitle(version),
          subtitle: s.waitingForIdle ? t.readyWaiting : t.readyPreparing,
          indeterminate: !s.waitingForIdle,
        );
      case UpdateState.installing:
        return _BannerView(
          id: 'installing',
          icon: Icons.system_update_alt_rounded,
          title: t.installingTitle(version),
          subtitle: t.installing,
          indeterminate: true,
          spinning: true,
        );
      case UpdateState.manualInstallRequired:
        final needsRetry = s.manualReason == null || s.manualReason == ManualInstallReason.installPermission;
        return _BannerView(
          id: 'manual',
          icon: Icons.touch_app_rounded,
          title: t.manualTitle,
          subtitle: t.manualReason(s.manualReason, s.manualLocation),
          actions: [
            if (needsRetry) _BannerAction(t.continueInstall, s.downloadAndInstall, primary: true),
          ],
        );
      case UpdateState.error:
        if (s.errorPhase == UpdatePhase.check) return null; // shown in Settings
        final kind = s.error?.kind ?? UpdateErrorKind.install;
        return _BannerView(
          id: 'error',
          icon: Icons.error_outline_rounded,
          title: t.failedTitle,
          subtitle: t.errorMessage(kind),
          isError: true,
          onClose: () => s.skip(version),
          actions: [_BannerAction(t.retry, s.downloadAndInstall, primary: true)],
        );
    }
  }
}

class _BannerAction {
  const _BannerAction(this.label, this.onPressed, {this.primary = false});

  final String label;
  final VoidCallback onPressed;
  final bool primary;
}

class _BannerRow extends StatelessWidget {
  const _BannerRow({required this.view});

  final _BannerView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.c;
    final strings = UpdateStrings.of(context);
    final tint = view.isError ? c.danger : c.accent;

    final actions = <Widget>[
      if (view.notes != null)
        TextButton(onPressed: () => openUpdateLink(view.notes), child: Text(strings.whatsNew)),
      for (final action in view.actions)
        action.primary
            ? FilledButton(
                style: context.secondaryButton,
                onPressed: action.onPressed,
                child: Text(action.label),
              )
            : TextButton(onPressed: action.onPressed, child: Text(action.label)),
    ];

    return Semantics(
      container: true,
      liveRegion: true,
      label: view.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: view.spinning
                    ? Padding(
                        padding: const EdgeInsets.all(2),
                        child: CircularProgressIndicator(strokeWidth: 2, color: tint),
                      )
                    : Icon(view.icon, size: 20, color: tint),
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      view.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (view.subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          view.subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(color: c.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
              if (view.onClose != null)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    key: const ValueKey('update-dismiss'),
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    tooltip: strings.dismiss,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: view.onClose,
                  ),
                ),
            ],
          ),
          if (view.progress != null || view.indeterminate) ...[
            const SizedBox(height: Gap.m),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(minHeight: 4, value: view.indeterminate ? null : view.progress),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: Gap.s),
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: Gap.xs,
                runSpacing: Gap.xs,
                children: actions,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
