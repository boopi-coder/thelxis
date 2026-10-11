import 'dart:ui' show ImageFilter;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
/// platforms this is just [child]). While a drag hovers, a frosted overlay
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
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _hovering && widget.enabled ? const DropOverlay(key: ValueKey('drop-overlay')) : const SizedBox.shrink(key: ValueKey('drop-idle')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The frosted "Drop files to send" layer. Public so it can be previewed.
class DropOverlay extends StatefulWidget {
  const DropOverlay({super.key});

  @override
  State<DropOverlay> createState() => _DropOverlayState();
}

class _DropOverlayState extends State<DropOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = FilesStrings.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      label: s.dropTitle,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: DecoratedBox(
            decoration: BoxDecoration(color: scheme.surface.withValues(alpha: 0.62)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: CustomPaint(
                painter: _DashedRRectPainter(color: scheme.primary.withValues(alpha: 0.85), radius: 28),
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedBuilder(
                          animation: _pulse,
                          builder: (context, child) {
                            final t = Curves.easeInOut.transform(_pulse.value);
                            return Container(
                              width: 88 + 8 * t,
                              height: 88 + 8 * t,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: scheme.primaryContainer,
                                boxShadow: [
                                  BoxShadow(
                                    color: scheme.primary.withValues(alpha: 0.18 + 0.12 * t),
                                    blurRadius: 24 + 16 * t,
                                    spreadRadius: 2 + 4 * t,
                                  ),
                                ],
                              ),
                              child: Transform.translate(
                                offset: Offset(0, -3 * t),
                                child: Icon(Icons.upload_rounded, size: 44, color: scheme.onPrimaryContainer),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 22),
                        Text(
                          s.dropTitle,
                          textAlign: TextAlign.center,
                          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          s.dropSubtitle,
                          textAlign: TextAlign.center,
                          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
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
      ..strokeWidth = 2.5
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
