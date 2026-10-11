import 'package:flutter/material.dart';

import '../theme.dart';

/// A tappable area with a flat hover / selected wash.
///
/// This is the only place hover state lives. The wash is a [ColoredBox]-style
/// layer in its own [RepaintBoundary], and [child] is passed through
/// unchanged, so moving the mouse over a row repaints one rectangle: the
/// content is not rebuilt, not re-laid-out and not repainted (a hover that
/// rebuilt or re-composited a whole card is what made the old UI flash).
///
/// No ink splash, no highlight animation, no size change on hover.
class HoverTint extends StatefulWidget {
  const HoverTint({
    super.key,
    required this.child,
    this.onTap,
    this.onSecondaryTap,
    this.borderRadius = BorderRadius.zero,
    this.selected = false,
    this.semanticLabel,
    this.hoverBuilder,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onSecondaryTap;
  final BorderRadius borderRadius;
  final bool selected;
  final String? semanticLabel;

  /// Optional extra content shown only while hovered or focused (for example
  /// a "Connect" button). It is positioned by the caller inside a [Stack]
  /// slot that does not take part in layout, so nothing shifts on hover.
  final Widget Function(BuildContext context)? hoverBuilder;

  @override
  State<HoverTint> createState() => _HoverTintState();
}

class _HoverTintState extends State<HoverTint> {
  bool _hover = false;
  bool _focus = false;

  void _setHover(bool v) {
    if (_hover != v) setState(() => _hover = v);
  }

  void _setFocus(bool v) {
    if (_focus != v) setState(() => _focus = v);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = widget.onTap != null;
    final tint = widget.selected
        ? c.accentSoft
        : (_hover || _focus) && enabled
        ? c.hover
        : null;
    Widget content = Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: _TintLayer(color: tint, radius: widget.borderRadius),
        ),
        widget.child,
        if (widget.hoverBuilder != null && (_hover || _focus) && enabled)
          widget.hoverBuilder!(context),
      ],
    );
    content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onSecondaryTap: widget.onSecondaryTap,
      child: content,
    );
    return Semantics(
      button: enabled,
      label: widget.semanticLabel,
      container: widget.semanticLabel != null,
      // Hover comes from a plain MouseRegion: the detector's own hover
      // callback is withheld while Flutter still believes the last input was
      // touch, which would leave the first hovers on a desktop without a wash.
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: enabled ? (_) => _setHover(true) : null,
        onExit: enabled ? (_) => _setHover(false) : null,
        child: FocusableActionDetector(
          enabled: enabled,
          onShowFocusHighlight: _setFocus,
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap?.call();
                return null;
              },
            ),
          },
          child: content,
        ),
      ),
    );
  }
}

class _TintLayer extends StatelessWidget {
  const _TintLayer({required this.color, required this.radius});

  final Color? color;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, borderRadius: radius),
        ),
      ),
    );
  }
}
