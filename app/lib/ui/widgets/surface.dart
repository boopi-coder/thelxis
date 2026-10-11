import 'package:flutter/material.dart';

import '../theme.dart';

/// 1px on ordinary screens, half a logical pixel (one physical pixel) on
/// retina ones, so hairlines stay crisp instead of looking heavy.
double hairlineOf(BuildContext context) => MediaQuery.devicePixelRatioOf(context) >= 2 ? 0.5 : 1;

/// A flat card: [AppColors.surface] fill, a hairline border, radius 12. No
/// shadow, no gradient.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.radius = Radii.card,
    this.color,
    this.clip = false,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final Color? color;

  /// Clip the content to the rounded corners (lists whose rows paint a wash).
  final bool clip;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final borderRadius = BorderRadius.circular(radius);
    Widget inner = padding == null ? child : Padding(padding: padding!, child: child);
    if (clip) inner = ClipRRect(borderRadius: borderRadius, child: inner);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? c.surface,
        borderRadius: borderRadius,
        border: Border.all(color: borderColor ?? c.border, width: hairlineOf(context)),
      ),
      child: inner,
    );
  }
}

/// A hairline rule, optionally inset from the left (list separators).
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.indent = 0});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: SizedBox(
        height: hairlineOf(context),
        width: double.infinity,
        child: ColoredBox(color: context.c.border),
      ),
    );
  }
}
