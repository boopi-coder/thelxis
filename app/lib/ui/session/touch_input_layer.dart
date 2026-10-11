import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../session/geometry.dart';
import '../../session/touch_gestures.dart';
import '../../session/viewer_session.dart';
import 'view_controller.dart';

/// Android viewer input: Touchpad mode (relative cursor) or Direct mode
/// (touch = pointer), plus pinch-zoom and pan, and a hardware-keyboard hook.
class TouchInputLayer extends StatefulWidget {
  const TouchInputLayer({
    super.key,
    required this.session,
    required this.view,
    required this.viewport,
    required this.video,
    required this.devicePixelRatio,
    required this.mode,
    this.onActivity,
  });

  final ViewerSession session;
  final ViewController view;
  final Size viewport;
  final Size video;
  final double devicePixelRatio;
  final TouchMode mode;
  final VoidCallback? onActivity;

  @override
  State<TouchInputLayer> createState() => _TouchInputLayerState();
}

class _TouchInputLayerState extends State<TouchInputLayer> implements TouchGestureSink {
  late final TouchGestureEngine _engine;
  final FocusNode _focus = FocusNode(debugLabel: 'remote-touch');

  /// Virtual cursor in normalised remote coordinates.
  final ValueNotifier<Offset> _cursor = ValueNotifier(const Offset(0.5, 0.5));

  ViewerSession get _s => widget.session;

  ViewTransform get _transform =>
      widget.view.effective(widget.viewport, widget.video, widget.devicePixelRatio);

  @override
  void initState() {
    super.initState();
    _engine = TouchGestureEngine(sink: this, mode: widget.mode);
  }

  @override
  void didUpdateWidget(TouchInputLayer old) {
    super.didUpdateWidget(old);
    _engine.mode = widget.mode;
  }

  @override
  void dispose() {
    _engine.dispose();
    _s.encoder.releaseAll();
    _focus.dispose();
    _cursor.dispose();
    super.dispose();
  }

  Rect get _fitted => computeVideoRect(widget.viewport, widget.video);

  // --- TouchGestureSink --------------------------------------------------

  @override
  void cursorMoveBy(Offset delta) {
    if (_s.viewOnly) {
      // Nothing to control: a one-finger drag pans the zoomed picture.
      widget.view.panBy(delta / _engine.cursorGain, widget.viewport);
      return;
    }
    final fitted = _fitted;
    if (fitted.isEmpty) return;
    final scale = _transform.scale;
    final dx = delta.dx / (fitted.width * scale);
    final dy = delta.dy / (fitted.height * scale);
    final next = Offset(
      (_cursor.value.dx + dx).clamp(0.0, 1.0),
      (_cursor.value.dy + dy).clamp(0.0, 1.0),
    );
    _cursor.value = next;
    _s.encoder.mouseMove(next.dx, next.dy);
  }

  @override
  void cursorMoveTo(Offset position) {
    if (_s.viewOnly) return;
    final n = viewportToNormalized(
      point: position,
      viewport: widget.viewport,
      video: widget.video,
      transform: _transform,
      clamp: true,
    );
    if (n == null) return;
    _cursor.value = n;
    _s.encoder.mouseMove(n.dx, n.dy);
  }

  @override
  void click(int button) {
    if (_s.viewOnly) return;
    final c = _cursor.value;
    _s.encoder.mouseDown(button, c.dx, c.dy);
    _s.encoder.mouseUp(button, c.dx, c.dy);
  }

  @override
  void buttonDown(int button) {
    if (_s.viewOnly) return;
    final c = _cursor.value;
    _s.encoder.mouseDown(button, c.dx, c.dy);
  }

  @override
  void buttonUp(int button) {
    final c = _cursor.value;
    _s.encoder.mouseUp(button, c.dx, c.dy);
  }

  @override
  void scroll(Offset wheelDelta) {
    if (_s.viewOnly) {
      widget.view.panBy(-wheelDelta, widget.viewport);
      return;
    }
    _s.encoder.wheel(wheelDelta.dx, wheelDelta.dy);
  }

  @override
  void zoom(Offset focal, double factor, Offset pan) {
    widget.view
      ..zoomAt(focal, factor, widget.viewport)
      ..panBy(pan, widget.viewport);
  }

  @override
  void longPress() => HapticFeedback.mediumImpact();

  // --- raw pointer events ------------------------------------------------

  void _down(PointerDownEvent e) {
    widget.onActivity?.call();
    if (e.kind == PointerDeviceKind.mouse) return;
    _engine.pointerDown(e.pointer, e.localPosition, e.timeStamp);
  }

  void _move(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.mouse) return;
    _engine.pointerMove(e.pointer, e.localPosition, e.timeStamp);
  }

  void _up(PointerUpEvent e) {
    if (e.kind == PointerDeviceKind.mouse) return;
    _engine.pointerUp(e.pointer, e.localPosition, e.timeStamp);
  }

  void _cancel(PointerCancelEvent e) => _engine.pointerCancel(e.pointer);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Bluetooth / hardware keyboards.
    if (_s.viewOnly) return KeyEventResult.ignored;
    final code = event.physicalKey.usbHidUsage;
    if (code == 0) return KeyEventResult.ignored;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _s.encoder.keyDown(code);
    } else if (event is KeyUpEvent) {
      _s.encoder.keyUp(code);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _cancel,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.mode == TouchMode.touchpad && !_s.viewOnly)
              IgnorePointer(
                child: ListenableBuilder(
                  listenable: Listenable.merge([_cursor, widget.view]),
                  builder: (context, _) => CustomPaint(
                    painter: _CursorMarkerPainter(
                      cursor: _cursor.value,
                      fitted: _fitted,
                      transform: _transform,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Small ring showing where the touchpad cursor is, drawn immediately
/// (the real cursor in the video arrives a round trip later).
class _CursorMarkerPainter extends CustomPainter {
  _CursorMarkerPainter({
    required this.cursor,
    required this.fitted,
    required this.transform,
    required this.color,
  });

  final Offset cursor;
  final Rect fitted;
  final ViewTransform transform;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (fitted.isEmpty) return;
    final p = transform.toViewport(normalizedToPoint(cursor, fitted));
    canvas.drawCircle(
      p,
      9,
      Paint()
        ..color = color.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(p, 2.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CursorMarkerPainter old) =>
      old.cursor != cursor || old.fitted != fitted || old.transform != transform;
}
