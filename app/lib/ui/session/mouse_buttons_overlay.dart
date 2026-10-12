import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../../session/input_encoder.dart';
import '../theme.dart';
import '../widgets/surface.dart';

/// Wire numbers of the mouse buttons (PROTOCOL.md, input channel).
const int kMouseLeft = 0;
const int kMouseRight = 2;

/// Fixed pill size: the drag clamp is plain arithmetic on it, so the pill
/// never has to be measured.
const double kMouseButtonsWidth = 176;
const double kMouseButtonsHeight = 52;
const double _kGripWidth = 36;

/// Floating Left | Right mouse buttons for the Android viewer.
///
/// Pressing a button sends mouse-down at the current virtual cursor and
/// releasing sends mouse-up there, so holding one with a thumb while the
/// other finger moves the cursor is a drag / selection. The pill swallows its
/// own touches (they never reach the remote surface below) and is moved by
/// its grip handle. Place it as a [Positioned.fill] child above the picture.
class MouseButtonsOverlay extends StatefulWidget {
  const MouseButtonsOverlay({
    super.key,
    required this.encoder,
    required this.cursor,
    required this.position,
    required this.onPositionChanged,
    this.topReserve = 0,
  });

  final InputEncoder encoder;

  /// Virtual remote cursor, normalised (shared with the touch layer).
  final ValueListenable<Offset> cursor;

  /// Where the pill sits, each axis 0..1 across the room it can move in
  /// (0 = left / top edge, 1 = right / bottom edge).
  final Offset position;

  /// Called once when a drag ends, with the new position (to persist it).
  final ValueChanged<Offset> onPositionChanged;

  /// Keeps the pill clear of the top toolbar.
  final double topReserve;

  @override
  State<MouseButtonsOverlay> createState() => _MouseButtonsOverlayState();
}

class _MouseButtonsOverlayState extends State<MouseButtonsOverlay> {
  late Offset _pos = widget.position;
  bool _dragging = false;

  /// Buttons this overlay holds down, by wire number -> pointer id.
  final Map<int, int> _held = {};
  final ValueNotifier<Set<int>> _pressed = ValueNotifier(const {});

  @override
  void didUpdateWidget(MouseButtonsOverlay old) {
    super.didUpdateWidget(old);
    if (!_dragging && old.position != widget.position) _pos = widget.position;
  }

  @override
  void dispose() {
    // Never leave a button stuck down on the remote machine.
    for (final b in _held.keys.toList()) {
      _release(b);
    }
    _pressed.dispose();
    super.dispose();
  }

  void _press(int button, int pointer) {
    if (_held.containsKey(button)) return;
    _held[button] = pointer;
    _pressed.value = {..._held.keys};
    HapticFeedback.lightImpact();
    final c = widget.cursor.value;
    widget.encoder.mouseDown(button, c.dx, c.dy);
  }

  void _release(int button) {
    if (_held.remove(button) == null) return;
    if (mounted) _pressed.value = {..._held.keys};
    // Skipped when something else (view-only, session end) already released it.
    if (!widget.encoder.heldButtons.contains(button)) return;
    final c = widget.cursor.value;
    widget.encoder.mouseUp(button, c.dx, c.dy);
  }

  void _releasePointer(int button, int pointer) {
    if (_held[button] == pointer) _release(button);
  }

  /// Screen-reader activation has no press-and-hold: a plain click.
  void _click(int button) {
    final c = widget.cursor.value;
    widget.encoder.mouseDown(button, c.dx, c.dy);
    widget.encoder.mouseUp(button, c.dx, c.dy);
  }

  void _drag(DragUpdateDetails d, Size room) {
    setState(() {
      _pos = Offset(
        room.width <= 0 ? _pos.dx : (_pos.dx + d.delta.dx / room.width).clamp(0.0, 1.0),
        room.height <= 0 ? _pos.dy : (_pos.dy + d.delta.dy / room.height).clamp(0.0, 1.0),
      );
    });
  }

  void _dragEnd() {
    _dragging = false;
    widget.onPositionChanged(_pos);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.s;
    return SafeArea(
      minimum: EdgeInsets.only(top: widget.topReserve) + const EdgeInsets.all(8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final room = Size(
            (constraints.maxWidth - kMouseButtonsWidth).clamp(0.0, double.infinity),
            (constraints.maxHeight - kMouseButtonsHeight).clamp(0.0, double.infinity),
          );
          return Stack(
            children: [
              Positioned(
                left: _pos.dx * room.width,
                top: _pos.dy * room.height,
                width: kMouseButtonsWidth,
                height: kMouseButtonsHeight,
                // Opaque: every touch on the pill stops here instead of
                // reaching the remote surface underneath.
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  child: _Pill(
                    grip: Semantics(
                      label: l.t('mouse.drag'),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) => _dragging = true,
                        onPanUpdate: (d) => _drag(d, room),
                        onPanEnd: (_) => _dragEnd(),
                        onPanCancel: _dragEnd,
                        child: const SizedBox(
                          width: _kGripWidth,
                          height: kMouseButtonsHeight,
                          child: _GripIcon(),
                        ),
                      ),
                    ),
                    left: _PressButton(
                      label: l.t('mouse.left'),
                      semanticLabel: l.t('mouse.left.a11y'),
                      button: kMouseLeft,
                      pressed: _pressed,
                      onDown: _press,
                      onUp: _releasePointer,
                      onClick: () => _click(kMouseLeft),
                    ),
                    right: _PressButton(
                      label: l.t('mouse.right'),
                      semanticLabel: l.t('mouse.right.a11y'),
                      button: kMouseRight,
                      pressed: _pressed,
                      onDown: _press,
                      onUp: _releasePointer,
                      onClick: () => _click(kMouseRight),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The translucent rounded body: grip | Left | Right, hairline dividers.
class _Pill extends StatelessWidget {
  const _Pill({required this.grip, required this.left, required this.right});

  final Widget grip;
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final divider = Container(width: hairlineOf(context), color: c.border);
    return DecoratedBox(
      decoration: BoxDecoration(
        // Semi-transparent so the remote screen stays readable underneath.
        color: c.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(kMouseButtonsHeight / 2),
        border: Border.all(color: c.border, width: hairlineOf(context)),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 2))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kMouseButtonsHeight / 2),
        child: Row(
          children: [
            grip,
            divider,
            Expanded(child: left),
            divider,
            Expanded(child: right),
          ],
        ),
      ),
    );
  }
}

class _GripIcon extends StatelessWidget {
  const _GripIcon();

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.drag_indicator_rounded, size: 22, color: context.c.textMuted);
}

/// One button. Raw pointer events (not a tap recogniser) because the press
/// has to go down immediately and stay down for as long as the finger does.
class _PressButton extends StatelessWidget {
  const _PressButton({
    required this.label,
    required this.semanticLabel,
    required this.button,
    required this.pressed,
    required this.onDown,
    required this.onUp,
    required this.onClick,
  });

  final String label;
  final String semanticLabel;
  final int button;
  final ValueListenable<Set<int>> pressed;
  final void Function(int button, int pointer) onDown;
  final void Function(int button, int pointer) onUp;
  final VoidCallback onClick;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      label: semanticLabel,
      onTap: onClick,
      excludeSemantics: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => onDown(button, e.pointer),
        onPointerUp: (e) => onUp(button, e.pointer),
        onPointerCancel: (e) => onUp(button, e.pointer),
        child: ValueListenableBuilder<Set<int>>(
          valueListenable: pressed,
          builder: (context, held, _) {
            final on = held.contains(button);
            // No fade-in: the press must show on the very frame the finger
            // lands, like a physical button, or a short tap looks ignored.
            return DecoratedBox(
              key: ValueKey('mouse-button-fill-$button'),
              decoration: BoxDecoration(
                color: on ? c.accent.withValues(alpha: 0.92) : Colors.transparent,
              ),
              child: Center(
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: on ? Colors.white : c.text,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
