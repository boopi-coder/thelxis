import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../installers/installer.dart' show ManualInstallReason;
import '../update_exception.dart';
import '../update_service.dart';
import 'update_links.dart';
import 'update_strings.dart';

/// Compact card for the Home screen: an update is available, downloading,
/// waiting for the end of a session, or needs a click. Hidden otherwise.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.service});

  final UpdateService service;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final view = _BannerView.of(service, UpdateStrings.of(context));
        return AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: view == null
                ? const SizedBox(key: ValueKey('hidden'), width: double.infinity)
                : Padding(
                    key: ValueKey(view.id),
                    padding: const EdgeInsets.only(bottom: Gap.m),
                    child: _BannerCard(view: view),
                  ),
          ),
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
          actions: [
            _BannerAction(t.skip, () => s.skip(version)),
            _BannerAction(t.update, s.downloadAndInstall, primary: true),
          ],
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
          actions: [
            _BannerAction(t.skip, () => s.skip(version)),
            _BannerAction(t.retry, s.downloadAndInstall, primary: true),
          ],
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

class _BannerCard extends StatelessWidget {
  const _BannerCard({required this.view});

  final _BannerView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = UpdateStrings.of(context);
    final accent = view.isError ? scheme.error : scheme.primary;
    final radius = BorderRadius.circular(18);

    return Semantics(
      container: true,
      liveRegion: true,
      label: view.title,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(accent.withValues(alpha: 0.16), scheme.surfaceContainerLow),
              scheme.surfaceContainerLow,
            ],
          ),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _LeadingBadge(icon: view.icon, spinning: view.spinning, isError: view.isError),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          view.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (view.subtitle != null) ...[
                          const SizedBox(height: Gap.xs),
                          Text(
                            view.subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (view.progress != null || view.indeterminate) ...[
                const SizedBox(height: Gap.m),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    value: view.indeterminate ? null : view.progress,
                    backgroundColor: accent.withValues(alpha: 0.14),
                  ),
                ),
              ],
              if (view.actions.isNotEmpty || view.notes != null) ...[
                const SizedBox(height: Gap.m),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: Gap.s,
                  runSpacing: Gap.xs,
                  children: [
                    if (view.notes != null)
                      TextButton(
                        onPressed: () => openUpdateLink(view.notes),
                        child: Text(strings.whatsNew),
                      ),
                    for (final action in view.actions) _buildAction(action),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAction(_BannerAction action) {
    if (action.primary) {
      return FilledButton(onPressed: action.onPressed, child: Text(action.label));
    }
    return TextButton(onPressed: action.onPressed, child: Text(action.label));
  }
}

class _LeadingBadge extends StatelessWidget {
  const _LeadingBadge({required this.icon, required this.spinning, required this.isError});

  final IconData icon;
  final bool spinning;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: isError ? null : context.brand.hero,
        color: isError ? scheme.errorContainer : null,
      ),
      child: spinning
          ? Padding(
              padding: const EdgeInsets.all(11),
              child: CircularProgressIndicator(strokeWidth: 2.4, color: context.brand.onHero),
            )
          : Icon(icon, size: 22, color: isError ? scheme.onErrorContainer : context.brand.onHero),
    );
  }
}
