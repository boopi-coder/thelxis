import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import 'package:url_launcher/url_launcher.dart';

import '../file_transfer_endpoint.dart';
import 'file_icons.dart';
import 'files_format.dart';
import 'files_strings.dart';
import 'pick_and_send.dart';

bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// The queue: running transfers first, then the finished ones.
class TransfersTab extends StatelessWidget {
  const TransfersTab({super.key, required this.endpoint});

  final FileTransferEndpoint endpoint;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: endpoint,
      builder: (context, _) {
        final s = FilesStrings.of(context);
        final all = endpoint.transfers;
        final running = [for (final t in all) if (t.isRunning) t];
        final finished = [for (final t in all.reversed) if (t.isFinished) t];

        if (all.isEmpty) return _EmptyTransfers(endpoint: endpoint);

        final children = <Widget>[
          if (running.isNotEmpty) _SectionHeader(title: s.sectionActive, count: running.length),
          for (final t in running)
            TransferTile(key: ValueKey('t${t.xid}'), transfer: t, onCancel: () => endpoint.cancel(t.xid)),
          if (finished.isNotEmpty)
            _SectionHeader(
              title: s.sectionFinished,
              count: finished.length,
              action: TextButton(
                onPressed: endpoint.clearFinished,
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: Text(s.clearFinished),
              ),
            ),
          for (final t in finished) TransferTile(key: ValueKey('t${t.xid}'), transfer: t),
        ];
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          children: children,
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count, this.action});

  final String title;
  final int count;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 0, 4),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(99)),
            child: Text('$count', style: monoStyle(context, size: 11)),
          ),
          const Spacer(),
          ?action,
        ],
      ),
    );
  }
}

class _EmptyTransfers extends StatelessWidget {
  const _EmptyTransfers({required this.endpoint});

  final FileTransferEndpoint endpoint;

  @override
  Widget build(BuildContext context) {
    final s = FilesStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(Icons.swap_vert_rounded, size: 40, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 20),
            Text(s.emptyTransfersTitle, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              endpoint.isHost ? s.emptyTransfersHint : s.emptyTransfersHintViewer,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 20),
            SendFilesMenuButton(endpoint: endpoint),
          ],
        ),
      ),
    );
  }
}

/// One row of the queue with progress, speed and ETA.
class TransferTile extends StatelessWidget {
  const TransferTile({super.key, required this.transfer, this.onCancel});

  final Transfer transfer;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final s = FilesStrings.of(context);
    final c = context.c;
    final t = transfer;
    final slash = t.name.lastIndexOf('/');
    final base = slash < 0 ? t.name : t.name.substring(slash + 1);
    final folder = slash < 0 ? null : t.name.substring(0, slash);

    final failed = t.status == TransferStatus.failed;
    final done = t.status == TransferStatus.completed;
    final success = c.success;
    final accent = failed ? c.danger : (done ? success : c.accent);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: c.inset,
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FileIconTile(name: base, badge: _DirectionBadge(isSend: t.isSend, color: accent)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  base,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (folder != null)
                  Text(
                    folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(context, size: 11),
                  ),
                const SizedBox(height: 8),
                if (t.status != TransferStatus.failed && t.status != TransferStatus.cancelled) ...[
                  _ProgressLine(transfer: t, color: accent),
                  const SizedBox(height: 6),
                ],
                _MetaLine(transfer: t, strings: s, successColor: success),
              ],
            ),
          ),
          _TileActions(transfer: t, onCancel: onCancel, success: success),
        ],
      ),
    );
  }
}

class _DirectionBadge extends StatelessWidget {
  const _DirectionBadge({required this.isSend, required this.color});

  final bool isSend;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        shape: BoxShape.circle,
        border: Border.all(color: scheme.surfaceContainerHigh, width: 2),
      ),
      child: Container(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(
          isSend ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
          size: 11,
          color: scheme.surface,
        ),
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.transfer, required this.color});

  final Transfer transfer;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = transfer;
    final indeterminate = t.status == TransferStatus.waiting || t.status == TransferStatus.verifying;
    final value = switch (t.status) {
      TransferStatus.queued => 0.0,
      TransferStatus.completed => 1.0,
      _ => t.progress,
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: indeterminate
          ? LinearProgressIndicator(
              minHeight: 6,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest,
            )
          : TweenAnimationBuilder<double>(
              tween: Tween<double>(end: value),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 6,
                color: color,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.transfer, required this.strings, required this.successColor});

  final Transfer transfer;
  final FilesStrings strings;
  final Color successColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = transfer;
    final s = strings;
    final muted = monoStyle(context);

    if (t.status == TransferStatus.active) {
      final parts = <String>[
        if (t.bytesPerSecond > 0) formatSpeed(t.bytesPerSecond, s),
        if (t.eta != null && t.bytesPerSecond > 0) s.left(formatEta(t.eta!, s)),
      ];
      return Row(
        children: [
          Text('${formatBytes(t.transferred, s)} / ${formatBytes(t.size, s)}', style: muted),
          if (parts.isNotEmpty) ...[
            const Spacer(),
            Flexible(child: Text(parts.join('  ·  '), style: muted, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ],
      );
    }

    final label = s.statusLabel(t);
    final Color color;
    switch (t.status) {
      case TransferStatus.failed:
        color = scheme.error;
      case TransferStatus.completed:
        color = successColor;
      default:
        color = scheme.onSurfaceVariant;
    }
    final showSize = t.size > 0 && t.status != TransferStatus.failed;
    return Row(
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color, fontSize: 12),
          ),
        ),
        if (showSize) ...[
          const SizedBox(width: 8),
          Text(formatBytes(t.size, s), style: muted),
        ],
      ],
    );
  }
}

class _TileActions extends StatelessWidget {
  const _TileActions({required this.transfer, required this.onCancel, required this.success});

  final Transfer transfer;
  final VoidCallback? onCancel;
  final Color success;

  @override
  Widget build(BuildContext context) {
    final s = FilesStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    final t = transfer;
    final children = <Widget>[];
    if (t.isRunning) {
      children.add(IconButton(
        tooltip: s.cancel,
        visualDensity: VisualDensity.compact,
        onPressed: onCancel,
        icon: const Icon(Icons.close_rounded, size: 20),
      ));
    } else {
      if (t.isCompleted && t.isReceive && t.localPath != null && _isDesktop) {
        children.add(IconButton(
          tooltip: s.showInFolder,
          visualDensity: VisualDensity.compact,
          onPressed: () => revealInFolder(context, t.localPath!),
          icon: const Icon(Icons.folder_open_rounded, size: 20),
        ));
      }
      children.add(SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: Icon(
            t.isCompleted
                ? Icons.check_circle_rounded
                : (t.status == TransferStatus.failed ? Icons.error_rounded : Icons.cancel_rounded),
            size: 20,
            color: t.isCompleted ? success : (t.status == TransferStatus.failed ? scheme.error : scheme.onSurfaceVariant),
          ),
        ),
      ));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// Opens the folder that contains [filePath] in the system file manager.
Future<void> revealInFolder(BuildContext context, String filePath) async {
  final s = FilesStrings.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  var ok = false;
  try {
    final dir = File(filePath).parent.path;
    ok = await launchUrl(Uri.file(dir, windows: Platform.isWindows), mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok) messenger?.showSnackBar(SnackBar(content: Text(s.couldNotOpenFolder)));
}
