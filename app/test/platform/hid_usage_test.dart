import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/platform/impl/hid_ascii.dart';
import 'package:thelxis/platform/impl/hid_usage.dart';

void main() {
  group('MacModifierState', () {
    test('flags follow held modifiers, both sides share a bit', () {
      final m = MacModifierState();
      expect(m.flags, 0);
      m.apply(hidLeftShift, true);
      m.apply(hidRightShift, true);
      expect(m.flags, cgFlagShift);
      m.apply(hidLeftShift, false);
      expect(m.flags, cgFlagShift, reason: 'right shift still held');
      m.apply(hidRightShift, false);
      expect(m.flags, 0);
    });

    test('combinations', () {
      final m = MacModifierState();
      m.apply(hidLeftCtrl, true);
      m.apply(hidLeftAlt, true);
      m.apply(hidLeftGui, true);
      expect(m.flags, cgFlagControl | cgFlagAlternate | cgFlagCommand);
    });

    test('caps lock toggles on key down only', () {
      final m = MacModifierState();
      m.apply(hidCapsLock, true);
      m.apply(hidCapsLock, false);
      expect(m.flags, cgFlagAlphaShift);
      m.apply(hidCapsLock, true);
      m.apply(hidCapsLock, false);
      expect(m.flags, 0);
    });

    test('apply reports whether the key is a modifier', () {
      final m = MacModifierState();
      expect(m.apply(hidLeftShift, true), isTrue);
      expect(m.apply(0x00070004, true), isFalse);
    });

    test('clear releases everything but keeps caps lock', () {
      final m = MacModifierState()..syncCapsLock(true);
      m.apply(hidLeftCtrl, true);
      m.clear();
      expect(m.flags, cgFlagAlphaShift);
    });
  });

  group('asciiForHid', () {
    test('letters follow shift xor caps', () {
      expect(asciiForHid(0x00070004, shift: false, caps: false), 'a');
      expect(asciiForHid(0x00070004, shift: true, caps: false), 'A');
      expect(asciiForHid(0x00070004, shift: false, caps: true), 'A');
      expect(asciiForHid(0x00070004, shift: true, caps: true), 'a');
      expect(asciiForHid(0x0007001d, shift: false, caps: false), 'z');
    });

    test('digits, shifted digits and punctuation', () {
      expect(asciiForHid(0x0007001e, shift: false, caps: false), '1');
      expect(asciiForHid(0x0007001e, shift: true, caps: false), '!');
      expect(asciiForHid(0x00070027, shift: false, caps: false), '0');
      expect(asciiForHid(0x00070027, shift: true, caps: false), ')');
      expect(asciiForHid(0x0007002c, shift: false, caps: false), ' ');
      expect(asciiForHid(0x00070031, shift: false, caps: false), '\\');
      expect(asciiForHid(0x00070034, shift: false, caps: false), "'");
      expect(asciiForHid(0x00070034, shift: true, caps: false), '"');
      expect(asciiForHid(0x00070038, shift: true, caps: false), '?');
      expect(asciiForHid(0x00070033, shift: true, caps: false), ':');
    });

    test('caps lock does not shift digits or punctuation', () {
      expect(asciiForHid(0x0007001e, shift: false, caps: true), '1');
    });

    test('keypad digits; enter and non-text keys give null', () {
      expect(asciiForHid(0x00070059, shift: false, caps: false), '1');
      expect(asciiForHid(0x00070062, shift: false, caps: false), '0');
      expect(asciiForHid(0x00070063, shift: false, caps: false), '.');
      expect(asciiForHid(0x00070058, shift: false, caps: false), isNull);
      expect(asciiForHid(0x00070028, shift: false, caps: false), isNull);
      expect(asciiForHid(0x0007003a, shift: false, caps: false), isNull);
      expect(asciiForHid(0x000700e1, shift: false, caps: false), isNull);
      expect(asciiForHid(0x0007002b, shift: false, caps: false), isNull);
      expect(asciiForHid(0x0001_0082, shift: false, caps: false), isNull);
    });
  });
}
