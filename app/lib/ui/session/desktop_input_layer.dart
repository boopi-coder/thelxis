import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../session/geometry.dart';
import '../../session/mouse_buttons.dart';
import '../../session/viewer_session.dart';
import 'view_controller.dart';

/// Captures mouse, trackpad and keyboard on desktop and forwards them to the
/// remote host. Pointer positions are mapped through the letterboxed (and
/// possibly zoomed) video rectangle to normalised display coordinates.
class DesktopInputLayer extends StatefulWidget {
  const DesktopInputLayer({
    super.key,
    required this.session,
    required this.view,
    required this.viewport,
    required this.video,
    required this.devicePixelRatio,
    this.onActivity,
  });

  final ViewerSession session;
  final ViewController view;
  final Size viewport;
  final Size video;
  final double devicePixelRatio;

  /// Called with the local pointer position on every move (toolbar reveal).
  final ValueChanged<Offset>? onActivity;

  @override
  State<DesktopInputLayer> createState() => _DesktopInputLayerState();
}

class _DesktopInputLayerState extends State<DesktopInputLayer> with WidgetsBindingObserver {
  final FocusNode _focus = FocusNode(debugLabel: 'remote-input');
  final MouseButtonTracker _buttons = MouseButtonTracker();
  Offset _lastNormalized = const Offset(0.5, 0.5);

  ViewerSession get _s => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _s.encoder.releaseAll();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never leave keys held on the remote when this window loses the keyboard.
    if (state != AppLifecycleState.resumed) _s.encoder.releaseAll();
  }

  Offset? _normalize(Offset local, {bool clamp = false}) {
    final t = widget.view.effective(widget.viewport, widget.video, widget.devicePixelRatio);
    final n = viewportToNormalized(
      point: local,
      viewport: widget.viewport,
      video: widget.video,
      transform: t,
      clamp: clamp,
    );
    if (n != null) _lastNormalized = n;
    return n;
  }

  void _onMove(PointerEvent e) {
    widget.view.movePointer(e.localPosition);
    widget.onActivity?.call(e.localPosition);
    if (_s.viewOnly) return;
    final n = _normalize(e.localPosition, clamp: true);
    if (n != null) _s.encoder.mouseMove(n.dx, n.dy);
  }

  /// Buttons for which a press was actually sent, so a release is only sent
  /// for presses that started on the remote picture.
  final Set<int> _sentDown = {};

  void _syncButtons(PointerEvent e, {required bool forceUp}) {
    final changes = _buttons.update(forceUp ? 0 : e.buttons);
    if (_s.viewOnly) return;
    for (final (button, down) in changes) {
      if (down) {
        // A press on the black bars is not a press on the remote screen.
        final n = _normalize(e.localPosition);
        if (n == null) continue;
        _sentDown.add(button);
        _s.encoder.mouseDown(button, n.dx, n.dy);
      } else if (_sentDown.remove(button)) {
        final n = _normalize(e.localPosition, clamp: true) ?? _lastNormalized;
        _s.encoder.mouseUp(button, n.dx, n.dy);
      }
    }
  }

  void _onDown(PointerDownEvent e) {
    _focus.requestFocus();
    widget.view.movePointer(e.localPosition);
    _syncButtons(e, forceUp: false);
  }

  void _onButtonsChange(PointerMoveEvent e) {
    _onMove(e);
    _syncButtons(e, forceUp: false);
  }

  void _onUp(PointerEvent e) => _syncButtons(e, forceUp: true);

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || _s.viewOnly) return;
    _s.encoder.wheel(e.scrollDelta.dx, e.scrollDelta.dy);
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (_s.viewOnly) return;
    // Trackpad pan reports finger movement; wheel dy>0 scrolls content down,
    // which is what moving the fingers up does with natural scrolling.
    _s.encoder.wheel(-e.panDelta.dx, -e.panDelta.dy);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_s.viewOnly) return KeyEventResult.ignored;
    final code = event.physicalKey.usbHidUsage;
    if (code == 0) return KeyEventResult.ignored;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _s.encoder.keyDown(code);
    } else if (event is KeyUpEvent) {
      _s.encoder.keyUp(code);
    }
    // Handled so Tab and the arrow keys go to the remote, not local focus.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _s,
      builder: (context, _) {
        final capture = !_s.viewOnly && _s.hasFirstFrame;
        return Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          onFocusChange: (has) {
            if (!has) _s.encoder.releaseAll();
          },
          child: MouseRegion(
            cursor: capture ? SystemMouseCursors.none : SystemMouseCursors.basic,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerHover: _onMove,
              onPointerDown: _onDown,
              onPointerMove: _onButtonsChange,
              onPointerUp: _onUp,
              onPointerCancel: _onUp,
              onPointerSignal: _onSignal,
              onPointerPanZoomUpdate: _onPanZoomUpdate,
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}
