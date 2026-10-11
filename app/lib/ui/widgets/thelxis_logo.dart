import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The app logo: `assets/icon/app_icon.png`, falling back to a drawn spiral
/// when the asset cannot be loaded (tests, missing bundle).
class ThelxisLogo extends StatelessWidget {
  const ThelxisLogo({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.asset(
          'assets/icon/app_icon.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stack) => _SpiralMark(size: size),
        ),
      ),
    );
  }
}

class _SpiralMark extends StatelessWidget {
  const _SpiralMark({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
      ),
      child: CustomPaint(painter: _SpiralPainter(scheme.onPrimary)),
    );
  }
}

class _SpiralPainter extends CustomPainter {
  _SpiralPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.07
      ..strokeCap = StrokeCap.round;
    final c = size.center(Offset.zero);
    final maxR = size.width * 0.36;
    final path = Path();
    for (var i = 0; i <= 240; i++) {
      final t = i / 240;
      final angle = t * 3.2 * 2 * math.pi;
      final r = maxR * t;
      final p = Offset(c.dx + r * math.cos(angle), c.dy + r * math.sin(angle));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SpiralPainter old) => old.color != color;
}
