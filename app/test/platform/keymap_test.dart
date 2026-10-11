import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/platform/impl/keymap/hid_to_evdev.dart';
import 'package:thelxis/platform/impl/keymap/hid_to_mac_vk.dart';
import 'package:thelxis/platform/impl/keymap/hid_to_win_scancode.dart';

// Spot values come straight from Chromium's dom_code_data.inc:
//   DOM_CODE(USB, evdev, XKB, Win, Mac, "Code", ...)
void main() {
  const keyA = 0x00070004;
  const enter = 0x00070028;
  const backspace = 0x0007002a;
  const f1 = 0x0007003a;
  const del = 0x0007004c;
  const arrowUp = 0x00070052;
  const numpadEnter = 0x00070058;
  const shiftLeft = 0x000700e1;
  const metaLeft = 0x000700e3;

  group('hidToWinScancode', () {
    test('plain keys', () {
      expect(hidToWinScancode[keyA], 0x001e);
      expect(hidToWinScancode[enter], 0x001c);
      expect(hidToWinScancode[backspace], 0x000e);
      expect(hidToWinScancode[f1], 0x003b);
      expect(hidToWinScancode[shiftLeft], 0x002a);
    });

    test('extended keys carry the 0xE0 prefix', () {
      expect(hidToWinScancode[del], 0xe053);
      expect(hidToWinScancode[arrowUp], 0xe048);
      expect(hidToWinScancode[numpadEnter], 0xe01c);
      expect(hidToWinScancode[metaLeft], 0xe05b);
    });

    test('helpers split scan code and extended flag', () {
      expect(winScanCode(0xe048), 0x48);
      expect(winScanIsExtended(0xe048), isTrue);
      expect(winScanCode(0x001e), 0x1e);
      expect(winScanIsExtended(0x001e), isFalse);
    });

    test(
      'Enter and NumpadEnter share a scan code, differ by extended flag',
      () {
        expect(
          winScanCode(hidToWinScancode[enter]!),
          winScanCode(hidToWinScancode[numpadEnter]!),
        );
        expect(winScanIsExtended(hidToWinScancode[enter]!), isFalse);
        expect(winScanIsExtended(hidToWinScancode[numpadEnter]!), isTrue);
      },
    );
  });

  group('hidToMacVk', () {
    test('matches kVK_* constants', () {
      expect(hidToMacVk[keyA], 0x00); // kVK_ANSI_A
      expect(hidToMacVk[enter], 0x24); // kVK_Return
      expect(hidToMacVk[backspace], 0x33); // kVK_Delete
      expect(hidToMacVk[f1], 0x7a); // kVK_F1
      expect(hidToMacVk[del], 0x75); // kVK_ForwardDelete
      expect(hidToMacVk[arrowUp], 0x7e); // kVK_UpArrow
      expect(hidToMacVk[numpadEnter], 0x4c); // kVK_ANSI_KeypadEnter
      expect(hidToMacVk[shiftLeft], 0x38); // kVK_Shift
      expect(hidToMacVk[metaLeft], 0x37); // kVK_Command
    });

    test('keys without a Mac key code are absent, not 0xFFFF', () {
      expect(hidToMacVk.values, isNot(contains(0xffff)));
      const printScreen = 0x00070046;
      expect(hidToMacVk.containsKey(printScreen), isFalse);
    });
  });

  group('hidToEvdev', () {
    test('matches linux/input-event-codes.h', () {
      expect(hidToEvdev[keyA], 30); // KEY_A
      expect(hidToEvdev[enter], 28); // KEY_ENTER
      expect(hidToEvdev[backspace], 14); // KEY_BACKSPACE
      expect(hidToEvdev[f1], 59); // KEY_F1
      expect(hidToEvdev[del], 111); // KEY_DELETE
      expect(hidToEvdev[arrowUp], 103); // KEY_UP
      expect(hidToEvdev[numpadEnter], 96); // KEY_KPENTER
      expect(hidToEvdev[shiftLeft], 42); // KEY_LEFTSHIFT
      expect(hidToEvdev[metaLeft], 125); // KEY_LEFTMETA
    });

    test('X11 keycode is evdev + 8', () {
      expect(evdevToX11Offset, 8);
      expect(hidToEvdev[keyA]! + evdevToX11Offset, 38); // xev: 'a' = 38
    });
  });

  test('every table has all 26 letters and 12 function keys', () {
    for (var i = 0; i < 26; i++) {
      final usage = 0x00070004 + i;
      expect(hidToWinScancode.containsKey(usage), isTrue, reason: '$usage');
      expect(hidToMacVk.containsKey(usage), isTrue, reason: '$usage');
      expect(hidToEvdev.containsKey(usage), isTrue, reason: '$usage');
    }
    for (var i = 0; i < 12; i++) {
      final usage = 0x0007003a + i;
      expect(hidToWinScancode.containsKey(usage), isTrue, reason: '$usage');
      expect(hidToMacVk.containsKey(usage), isTrue, reason: '$usage');
      expect(hidToEvdev.containsKey(usage), isTrue, reason: '$usage');
    }
  });
}
