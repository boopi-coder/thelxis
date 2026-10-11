import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import 'files_strings.dart';

bool get _dropSupported {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// Lets the user drop files and folders onto [child] (desktop only; on other
/// platforms this is just [child]). While a drag hovers, a flat overlay
/// says what will happen.
///
/// Set [enabled] to false while something (a dialog, another page) covers the
/// target — desktop_drop keeps delivering events to widgets underneath.
class FileDropTarget extends StatefulWidget {
  const FileDropTarget({super.key, required this.child, required this.onFiles, this.enabled = true});

  final Widget child;

  /// Absolute paths of the dropped files and folders.
  final void Function(List<String> paths) onFiles;
  final bool enabled;

  @override
  State<FileDropTarget> createState() => _FileDropTargetState();
}

class _FileDropTargetState extends State<FileDropTarget> {
  bool _hovering = false;

  void _setHovering(bool value) {
    if (_hovering != value && mounted) setState(() => _hovering = value);
  }

  @override
  void didUpdateWidget(FileDropTarget old) {
    super.didUpdateWidget(old);
    if (!widget.enabled && _hovering) _hovering = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!_dropSupported) return widget.child;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => _setHovering(true),
      onDragExited: (_) => _setHovering(false),
      onDragDone: (details) {
        _setHovering(false);
        final paths = [for (final f in details.files) if (f.path.isNotEmpty) f.path];
        if (paths.isNotEmpty) widget.onFiles(paths);
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_hovering && widget.enabled)
            const Positioned.fill(child: IgnorePointer(child: DropOverlay(key: ValueKey('drop-overlay')))),
        ],
      ),
    );
  }
}

/// The "Drop files to send" layer: a translucent flat sheet with a dashed
/// accent outline. Public so it can be previewed.
class DropOverlay extends StatelessWidget {
  const DropOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = FilesStrings.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      label: s.dropTitle,
      child: DecoratedBox(
        decoration: BoxDecoration(color: c.surface.withValues(alpha: 0.88)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: CustomPaint(
            painter: _DashedRRectPainter(color: c.accent, radius: Radii.card),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(Radii.card),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.upload_rounded, size: 36, color: c.accent),
                    const SizedBox(height: 12),
                    Text(
                      s.dropTitle,
                      textAlign: TextAlign.center,
                      style: text.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.dropSubtitle,
                      textAlign: TextAlign.center,
                      style: text.bodySmall?.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    const dash = 10.0;
    const gap = 8.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) => old.color != color || old.radius != radius;
}
