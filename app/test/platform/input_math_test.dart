import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/platform/host_platform.dart' show MouseButton;
import 'package:thelxis/platform/impl/input_math.dart';

int _windowsBackToPixel(int abs, int extent) => (abs * extent) ~/ 65536;

void main() {
  group('normalizedToPixel', () {
    test('endpoints and middle', () {
      expect(normalizedToPixel(0, 1920), 0);
      expect(normalizedToPixel(1, 1920), 1919);
      expect(normalizedToPixel(0.5, 1921), 960);
    });

    test('clamps and survives NaN / tiny displays', () {
      expect(normalizedToPixel(-3, 100), 0);
      expect(normalizedToPixel(7, 100), 99);
      expect(normalizedToPixel(double.nan, 100), 0);
      expect(normalizedToPixel(0.5, 1), 0);
      expect(normalizedToPixel(0.5, 0), 0);
    });
  });

  group('displayPoint', () {
    test('offsets by the display origin', () {
      final p = displayPoint(const Rect.fromLTWH(1920, 100, 1280, 1024), 0, 1);
      expect(p.x, 1920);
      expect(p.y, 100 + 1023);
    });
  });

  group('windowsAbsoluteMouse', () {
    const single = Rect.fromLTWH(0, 0, 1920, 1080);

    test('single monitor corners', () {
      final tl = windowsAbsoluteMouse(single, single, 0, 0);
      expect((tl.x, tl.y), (0, 0));
      final br = windowsAbsoluteMouse(single, single, 1, 1);
      expect(br.x, lessThanOrEqualTo(65535));
      expect(_windowsBackToPixel(br.x, 1920), 1919);
      expect(_windowsBackToPixel(br.y, 1080), 1079);
    });

    test('round-trips to the exact pixel the system will compute', () {
      for (final nx in [0.0, 0.1234, 0.5, 0.9999, 1.0]) {
        final p = windowsAbsoluteMouse(single, single, nx, nx);
        final want = normalizedToPixel(nx, 1920);
        expect(_windowsBackToPixel(p.x, 1920), want, reason: 'nx=$nx');
      }
    });

    test('secondary monitor left of the primary (negative origin)', () {
      const virtual = Rect.fromLTWH(-1920, 0, 3840, 1080);
      const left = Rect.fromLTWH(-1920, 0, 1920, 1080);
      const primary = Rect.fromLTWH(0, 0, 1920, 1080);

      final a = windowsAbsoluteMouse(left, virtual, 0, 0);
      expect(a.x, 0);

      final b = windowsAbsoluteMouse(primary, virtual, 0, 0);
      expect(_windowsBackToPixel(b.x, 3840), 1920); // pixel 0 of primary
      expect(b.x, 32768);

      final c = windowsAbsoluteMouse(left, virtual, 1, 0);
      expect(_windowsBackToPixel(c.x, 3840), 1919);
    });

    test('result is always within 0..65535', () {
      for (final n in [-1.0, 0.0, 1.0, 2.0, double.nan]) {
        final p = windowsAbsoluteMouse(single, single, n, n);
        expect(p.x, inInclusiveRange(0, 65535));
        expect(p.y, inInclusiveRange(0, 65535));
      }
    });

    test('degenerate virtual screen does not divide by zero', () {
      final p = windowsAbsoluteMouse(single, Rect.zero, 0.5, 0.5);
      expect((p.x, p.y), (0, 0));
    });
  });

  group('macGlobalPoint', () {
    test('main display and a display above-left of it', () {
      const main = Rect.fromLTWH(0, 0, 1440, 900);
      final m = macGlobalPoint(main, 0.5, 0.5);
      expect(m.x, closeTo(719.5, 1e-9));
      expect(m.y, closeTo(449.5, 1e-9));

      const other = Rect.fromLTWH(-1920, -300, 1920, 1080);
      final o = macGlobalPoint(other, 1, 1);
      expect(o.x, -1);
      expect(o.y, 779);
    });

    test('stays inside the display for out-of-range input', () {
      const d = Rect.fromLTWH(100, 50, 800, 600);
      final lo = macGlobalPoint(d, -5, double.nan);
      final hi = macGlobalPoint(d, 9, 9);
      expect(lo.x, 100);
      expect(lo.y, 50);
      expect(hi.x, 899);
      expect(hi.y, 649);
    });
  });

  group('WheelAccumulator', () {
    test('Windows: 60 px = 120 units, fractions carry over', () {
      final w = WheelAccumulator(windowsWheelDelta / wheelPixelsPerNotch);
      expect(w.add(60), 120);
      expect(w.add(-60), -120);
      expect(w.add(0.25), 0); // 0.5 unit, kept
      expect(w.add(0.25), 1); // 1.0 unit now due
      expect(w.add(30), 60);
    });

    test('X11: whole notches only', () {
      final w = WheelAccumulator(1 / wheelPixelsPerNotch);
      expect(w.add(30), 0);
      expect(w.add(30), 1); // 60 px reached
      expect(w.add(-130), -2); // remainder -10 px stays
      expect(w.add(-10), 0); // -20 px total, still under a notch
      expect(w.add(-45), -1); // -65 px total, one notch due
    });

    test('negative remainder keeps its sign', () {
      final w = WheelAccumulator(1);
      expect(w.add(-0.6), 0);
      expect(w.add(-0.6), -1);
    });

    test('ignores NaN/Infinity and reset clears the remainder', () {
      final w = WheelAccumulator(1);
      expect(w.add(double.nan), 0);
      expect(w.add(double.infinity), 0);
      expect(w.add(0.9), 0);
      w.reset();
      expect(w.add(0.9), 0);
    });
  });

  group('ClickTracker', () {
    test('double and triple click within 400 ms / 4 px', () {
      final t = ClickTracker();
      expect(t.down(MouseButton.left, 100, 100, 1000), 1);
      expect(t.down(MouseButton.left, 102, 99, 1300), 2);
      expect(t.down(MouseButton.left, 102, 99, 1600), 3);
    });

    test('resets when too slow', () {
      final t = ClickTracker();
      t.down(MouseButton.left, 0, 0, 0);
      expect(t.down(MouseButton.left, 0, 0, 401), 1);
    });

    test('boundary: exactly 400 ms continues, exactly 4 px continues', () {
      final t = ClickTracker();
      t.down(MouseButton.left, 0, 0, 0);
      expect(t.down(MouseButton.left, 4, 4, 400), 2);
    });

    test('resets when the pointer moved more than the slop', () {
      final t = ClickTracker();
      t.down(MouseButton.left, 0, 0, 0);
      expect(t.down(MouseButton.left, 5, 0, 100), 1);
    });

    test('a different button starts a new sequence', () {
      final t = ClickTracker();
      t.down(MouseButton.left, 0, 0, 0);
      expect(t.down(MouseButton.right, 0, 0, 100), 1);
      expect(t.down(MouseButton.left, 0, 0, 200), 1);
    });

    test('reset() forgets the sequence', () {
      final t = ClickTracker();
      t.down(MouseButton.left, 0, 0, 0);
      t.reset();
      expect(t.down(MouseButton.left, 0, 0, 10), 1);
    });
  });

  group('X11 helpers', () {
    test('button numbers', () {
      expect(x11ButtonNumber(MouseButton.left), 1);
      expect(x11ButtonNumber(MouseButton.middle), 2);
      expect(x11ButtonNumber(MouseButton.right), 3);
      expect(x11ButtonNumber(MouseButton.back), 8);
      expect(x11ButtonNumber(MouseButton.forward), 9);
    });

    test('keysyms: Latin-1 as is, everything else 0x01000000 | cp', () {
      expect(x11KeysymForCodePoint(0x41), 0x41);
      expect(x11KeysymForCodePoint(0xe9), 0xe9); // e acute
      expect(x11KeysymForCodePoint(0x416), 0x01000416); // Cyrillic Zhe
      expect(x11KeysymForCodePoint(0x20ac), 0x010020ac); // euro
      expect(x11KeysymForCodePoint(0x1f600), 0x0101f600); // emoji
    });

    test('keysyms: control characters and invalid scalars are rejected', () {
      expect(x11KeysymForCodePoint(0x0a), 0);
      expect(x11KeysymForCodePoint(0x7f), 0);
      expect(x11KeysymForCodePoint(0x85), 0);
      expect(x11KeysymForCodePoint(0xd800), 0);
      expect(x11KeysymForCodePoint(0x110000), 0);
    });
  });

  group('utf16Chunks', () {
    test('splits long text without breaking surrogate pairs', () {
      const emoji = '\u{1F600}'; // 2 UTF-16 units
      final text = '${'a' * 15}${emoji}b';
      final chunks = utf16Chunks(text, 16);
      expect(chunks.length, 2);
      expect(chunks[0].length, 15); // the pair would straddle the boundary
      expect(chunks[1], [0xd83d, 0xde00, 0x62]);
      expect(chunks.expand((c) => c).toList(), text.codeUnits);
    });

    test('short and empty text', () {
      expect(utf16Chunks('', 16), isEmpty);
      expect(utf16Chunks('Привет', 16), ['Привет'.codeUnits]);
    });
  });
}
