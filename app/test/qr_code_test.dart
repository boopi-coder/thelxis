import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/qr_code.dart';

QrEcc _ecc(String s) => switch (s) {
      'L' => QrEcc.low,
      'M' => QrEcc.medium,
      'Q' => QrEcc.quartile,
      _ => QrEcc.high,
    };

List<String> _rows(QrCode qr) => [
      for (var y = 0; y < qr.size; y++)
        [for (var x = 0; x < qr.size; x++) qr.moduleAt(x, y) ? '1' : '0'].join(),
    ];

void main() {
  // Golden matrices produced by the reference Python `qrcode` package (byte
  // mode, every mask), so each module of our encoder is checked against an
  // independent implementation: function patterns, alignment positions,
  // Reed-Solomon blocks, masks, format and version information.
  final golden = (jsonDecode(File('test/fixtures/qr_golden.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  for (final g in golden) {
    final text = g['text'] as String;
    final label = '${text.length > 14 ? '${text.substring(0, 14)}…' : text} '
        '${g['ecc']} mask=${g['mask']} v${g['version']}';
    test('forced mask matches reference: $label', () {
      final qr = QrCode.encodeText(text, ecc: _ecc(g['ecc'] as String), mask: g['mask'] as int);
      expect(qr.version, g['version']);
      expect(_rows(qr), (g['rows'] as List).cast<String>());
    });
  }

  test('the automatically chosen mask yields a reference-identical symbol', () {
    final texts = {for (final g in golden) '${g['text']}|${g['ecc']}': g};
    for (final key in texts.keys) {
      final g = texts[key]!;
      final auto = QrCode.encodeText(g['text'] as String, ecc: _ecc(g['ecc'] as String));
      final ref = golden.firstWhere((x) =>
          x['text'] == g['text'] && x['ecc'] == g['ecc'] && x['mask'] == auto.mask);
      expect(_rows(auto), (ref['rows'] as List).cast<String>(), reason: key);
    }
  });

  test('rejects data that cannot fit', () {
    expect(() => QrCode.encodeBytes(List<int>.filled(3000, 65), ecc: QrEcc.high), throwsArgumentError);
  });
}
