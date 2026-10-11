import 'package:flutter/material.dart';

import '../../core/qr_code.dart';
import '../../l10n/strings.dart';

/// Renders [data] as a QR code on a white tile with a quiet zone, so it scans
/// reliably in both light and dark themes.
class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, this.size = 180});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    QrCode? qr;
    try {
      qr = QrCode.encodeText(data, ecc: QrEcc.low);
    } on ArgumentError {
      qr = null;
    }
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: qr == null
          ? const Center(child: Icon(Icons.qr_code_2_rounded, color: Colors.black26))
          : Semantics(
              label: context.s.t('share.qr'),
              child: CustomPaint(painter: _QrPainter(qr), size: Size.infinite),
            ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.qr);

  final QrCode qr;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide / qr.size;
    final paint = Paint()..color = Colors.black;
    for (var y = 0; y < qr.size; y++) {
      for (var x = 0; x < qr.size; x++) {
        if (qr.moduleAt(x, y)) {
          // A hair of overlap avoids hairline gaps between neighbours.
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.4, cell + 0.4), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.qr != qr;
}
