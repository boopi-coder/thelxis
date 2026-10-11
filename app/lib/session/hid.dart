/// USB HID usage codes (page 0x07, `0x0007xxxx`) used by on-screen keys and
/// shortcuts. Matches `PhysicalKeyboardKey.usbHidUsage`.
abstract final class Hid {
  static const int enter = 0x70028;
  static const int escape = 0x70029;
  static const int backspace = 0x7002A;
  static const int tab = 0x7002B;
  static const int space = 0x7002C;
  static const int delete = 0x7004C;
  static const int right = 0x7004F;
  static const int left = 0x70050;
  static const int down = 0x70051;
  static const int up = 0x70052;

  static const int controlLeft = 0x700E0;
  static const int shiftLeft = 0x700E1;
  static const int altLeft = 0x700E2;
  static const int metaLeft = 0x700E3;

  static const int keyC = 0x70006;
  static const int keyL = 0x7000F;
  static const int keyR = 0x70015;
  static const int keyV = 0x70019;
  static const int keyD = 0x70007;
  static const int keyA = 0x70004;

  /// F1..F12 are consecutive, 0x70 003A to 0x70045.
  static int f(int n) {
    assert(n >= 1 && n <= 12);
    return 0x7003A + (n - 1);
  }
}
